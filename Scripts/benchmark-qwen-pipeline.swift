import Foundation
import MLX

// Standalone DTOs only; the runner compiles the actual production service files.
struct SubtitleSegment: Sendable { let index: Int; let start: Double; let end: Double; let duration: Double }
struct SubtitleCue: Sendable { let index: Int; let start: Double; let end: Double; let text: String; let confidence: Double?; let speaker: String? }
actor PipelineRecorder {
    let started = ProcessInfo.processInfo.systemUptime
    var firstCue: Double?
    var events: [String] = []
    func cue(_ cue: SubtitleCue) {
        if firstCue == nil { firstCue = ProcessInfo.processInfo.systemUptime - started }
        events.append("cue")
    }
    func progress(_ value: Double) { events.append(value == 1 ? "complete" : "progress") }
    func checkpoint(cancel: Bool) throws {
        if cancel && firstCue != nil { throw CancellationError() }
    }
}
@main struct PipelineProbe {
    static func main() async throws {
        let model = URL(fileURLWithPath: CommandLine.arguments[1])
        let audio = URL(fileURLWithPath: CommandLine.arguments[2])
        let segments = [(0.0, 6.0), (6.0, 16.0), (16.0, 21.0)].enumerated().map {
            SubtitleSegment(index: $0.offset + 1, start: $0.element.0, end: $0.element.1, duration: $0.element.1 - $0.element.0)
        }
        func run(_ batch: Bool, optimized: Bool = true, cancel: Bool = false) async throws -> ([SubtitleCue], Double, Double) {
            let recorder = PipelineRecorder()
            let start = ProcessInfo.processInfo.systemUptime
            let cues = try await NativeQwenService.shared.transcribe(audioURL: audio, segments: segments,
                timeOffset: 12, options: .init(modelDirectory: model, language: "ja", context: "", maxTokens: 128,
                    lineCharacters: 30, batchEncodingEnabled: batch, optimizedDecodingEnabled: optimized),
                checkpoint: { try await recorder.checkpoint(cancel: cancel) },
                onProgress: { await recorder.progress($0) }, onCue: { await recorder.cue($0) })
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            let events = await recorder.events
            precondition(events == ["cue", "progress", "cue", "progress", "cue", "complete"], "live callback ordering")
            precondition(cues.map(\.start) == [12,18,28] && cues.map(\.end) == [18,28,33], "absolute timing")
            return (cues, elapsed, await recorder.firstCue ?? -1)
        }
        var rows: [[String: Any]] = []
        let reference = try await run(false, optimized: false) // cold load excluded from warm comparisons
        rows.append(["mode":"cold-single", "seconds":reference.1, "firstCueSeconds":reference.2])
        for batch in [false, true] {
            let warmup = try await run(batch)
            precondition(warmup.0.map(\.text) == reference.0.map(\.text))
        }
        for (batch, optimized) in [(false, true), (false, false), (true, true), (false, false), (false, true), (true, true)] {
            let result = try await run(batch, optimized: optimized)
            let equal = result.0.map(\.text) == reference.0.map(\.text)
            precondition(equal, "batch text mismatch")
            rows.append(["mode":batch ? "warm-pair" : optimized ? "warm-optimized-single" : "warm-reference", "seconds":result.1,
                         "firstCueSeconds":result.2, "textEqual":equal])
        }
        do { _ = try await run(true, cancel: true); fatalError("expected cancellation") }
        catch is CancellationError { }
        let resumed = try await run(true)
        precondition(resumed.0.map(\.text) == reference.0.map(\.text), "resume stale features")
        let empty = try await NativeQwenService.shared.transcribe(audioURL: audio, segments: [], timeOffset: 12,
            options: .init(modelDirectory:model,language:"ja",context:"",maxTokens:128,lineCharacters:30,batchEncodingEnabled:true),
            checkpoint:{},onProgress:{_ in})
        precondition(empty.isEmpty)
        for language: String? in ["ja", nil] {
            for limit in [1, 32] {
                var texts: [[String]] = []
                for optimized in [false, true] {
                    let cues = try await NativeQwenService.shared.transcribe(audioURL: audio, segments: [segments[0]], timeOffset: 0,
                        options: .init(modelDirectory: model, language: language, context: "日本語の会話", maxTokens: limit,
                            lineCharacters: 30, optimizedDecodingEnabled: optimized), checkpoint: {}, onProgress: { _ in })
                    texts.append(cues.map(\.text))
                }
                precondition(texts[0] == texts[1], "language/context/token-limit parity")
            }
        }
        await NativeQwenService.shared.release()
        let report: [String:Any] = ["runs":rows, "oddTailTimingAndLiveCallbacks":true,
            "checkpointCancellationAndRetry":true,"emptySegments":true,"autoLanguageContextAndTokenLimits":true,"peakMLXBytes":Memory.peakMemory]
        print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
    }
}
