import Foundation
import XCTest
@testable import MSub

final class NativeQwenStreamingTests: XCTestCase {
    /// Opt-in integration check: two short segments, no full-video transcription.
    func testCompletedCuesArriveBeforeFinalProgress() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let model = environment["MSUB_TEST_QWEN_MODEL"],
              let wav = environment["MSUB_TEST_QWEN_AUDIO"] else {
            throw XCTSkip("Set model and mono16k audio (at least 10 s of speech) for local Metal check")
        }
        let recorder = Recorder()
        let result = try await NativeQwenService.shared.transcribe(
            audioURL: URL(fileURLWithPath: wav),
            segments: [SubtitleSegment(index: 1, start: 0, end: 5, duration: 5),
                       SubtitleSegment(index: 2, start: 5, end: 10, duration: 5)],
            timeOffset: 12,
            options: .init(modelDirectory: URL(fileURLWithPath: model), language: "ja",
                           context: "", maxTokens: 32, lineCharacters: 30),
            checkpoint: {}, onProgress: { await recorder.progress($0) },
            onCue: { await recorder.cue($0) })
        await NativeQwenService.shared.release()
        let events = await recorder.events
        XCTAssertEqual(events, ["cue", "progress", "cue", "complete"])
        XCTAssertEqual(result.map(\.start), [12, 17])
    }

    private actor Recorder {
        var events: [String] = []
        func cue(_ cue: SubtitleCue) { events.append("cue") }
        func progress(_ value: Double) { events.append(value == 1 ? "complete" : "progress") }
    }
}
