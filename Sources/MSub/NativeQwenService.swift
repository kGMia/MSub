import AVFoundation
import Foundation
import Metal
import MLX
@preconcurrency import MLXAudioSTT

/// Keep the successful location, not a cached validation result. Each request
/// still asks Metal to open the library before it can enter MLX.
enum NativeMLXLibrarySearch {
    static func find(
        preferred: URL?,
        candidates: () -> [URL],
        load: (URL) -> Bool
    ) -> URL? {
        var visited = Set<URL>()
        func attempt(_ candidate: URL) -> URL? {
            let url = candidate.standardizedFileURL
            guard visited.insert(url).inserted else { return nil }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory),
                  !directory.boolValue else { return nil }
            return load(url) ? url : nil
        }
        if let preferred, let result = attempt(preferred) { return result }
        for candidate in candidates() {
            if let result = attempt(candidate) { return result }
        }
        return nil
    }
}

/// Exclusive wall-clock stages for one native ASR attempt. Checkpoint waits are
/// separate from decoding; UI callback time is deliberately left unassigned.
struct NativeQwenDiagnostics: Sendable {
    enum Stage: String, Sendable {
        case preparation = "nativePreparation"
        case modelLoading
        case decoding = "recognition"
        case checkpoint = "nativeCheckpoint"
        case postprocessing
    }
    enum Outcome: Sendable { case running, completed, cancelled, failed }
    enum ModelCache: String, Sendable { case hit, miss }
    struct Snapshot: Sendable {
        let stages: [String: Double]
        let modelCache: ModelCache?
        let completedSegments: Int
        let totalSegments: Int
        let stage: Stage?
        let outcome: Outcome
    }

    private var stages: [String: Double] = [:]
    private var activeStage: Stage?
    private var startedAt: TimeInterval?
    private var terminal: Snapshot?
    var modelCache: ModelCache?
    var completedSegments = 0
    let totalSegments: Int

    init(totalSegments: Int) { self.totalSegments = totalSegments }

    mutating func transition(to stage: Stage?, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard terminal == nil else { return }
        if let activeStage, let startedAt {
            stages[activeStage.rawValue, default: 0] += max(0, now - startedAt)
        }
        activeStage = stage
        startedAt = stage == nil ? nil : now
    }

    func snapshot(stage: Stage?) -> Snapshot {
        terminal ?? Snapshot(stages: stages, modelCache: modelCache,
                             completedSegments: completedSegments, totalSegments: totalSegments,
                             stage: stage, outcome: .running)
    }

    mutating func finish(_ outcome: Outcome, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Snapshot {
        if let terminal { return terminal }
        transition(to: nil, at: now)
        let result = Snapshot(stages: stages, modelCache: modelCache,
                              completedSegments: completedSegments, totalSegments: totalSegments,
                              stage: nil, outcome: outcome)
        terminal = result
        return result
    }
}

/// Request-local and confined to the Qwen actor. Only copied Float samples
/// cross a decode await; the reusable AVFoundation buffer never does.
final class NativeQwenPCMReader {
    private let audio: AVAudioFile
    private let buffer: AVAudioPCMBuffer
    let ranges: [Range<Int>]

    init(audioURL: URL, segments: [SubtitleSegment]) throws {
        let audio = try AVAudioFile(forReading: audioURL)
        guard audio.processingFormat.sampleRate == 16000,
              audio.processingFormat.channelCount == 1 else { throw NativeQwenService.Failure.invalidAudio }
        let duration = Double(audio.length) / 16000
        var ranges: [Range<Int>] = []
        ranges.reserveCapacity(segments.count)
        for segment in segments {
            try Task.checkCancellation()
            ranges.append(try NativeQwenService.sampleRange(start: segment.start, end: segment.end, duration: duration))
        }
        // Every range has already passed the 30-second limit. Memory is bounded
        // by the longest segment, not the duration of the whole recording.
        guard let capacity = ranges.map(\.count).max(),
              let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat,
                                            frameCapacity: AVAudioFrameCount(capacity)) else {
            throw NativeQwenService.Failure.invalidAudio
        }
        self.audio = audio
        self.buffer = buffer
        self.ranges = ranges
    }

    func samples(in range: Range<Int>) throws -> [Float] {
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= Int(audio.length),
              range.count <= Int(buffer.frameCapacity) else { throw NativeQwenService.Failure.invalidSegment }
        if audio.framePosition != AVAudioFramePosition(range.lowerBound) {
            audio.framePosition = AVAudioFramePosition(range.lowerBound)
        }
        var samples: [Float] = []
        samples.reserveCapacity(range.count)
        while samples.count < range.count {
            try Task.checkCancellation()
            buffer.frameLength = 0
            try audio.read(into: buffer, frameCount: AVAudioFrameCount(range.count - samples.count))
            guard buffer.frameLength > 0, let channel = buffer.floatChannelData?[0] else {
                throw NativeQwenService.Failure.invalidAudio
            }
            samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }
        return samples
    }
}

/// ASR consumes the exact prepared PCM/VAD timeline off the main actor,
/// using either native preparation or the Python fallback, one bounded segment at a time.
actor NativeQwenService {
    static let shared = NativeQwenService()
    private var model: Qwen3ASRModel?
    private var modelPath: String?
    private var runtimeLibraryURL: URL?
    private var busy = false

    struct Options: Sendable {
        let modelDirectory: URL
        let language: String?
        let context: String
        let maxTokens: Int
        let lineCharacters: Int
    }

    enum Failure: LocalizedError {
        case busy, invalidAudio, invalidSegment, missingResult, runtimeUnavailable
        var errorDescription: String? {
            switch self {
            case .busy: "Native Qwen is already processing audio."
            case .invalidAudio: "Native Qwen requires the preview's 16 kHz mono audio."
            case .invalidSegment: "Invalid or oversized native Qwen segment (maximum 30 seconds)."
            case .missingResult: "Native Qwen did not return a completed transcript."
            case .runtimeUnavailable: "Native MLX requires a Metal device and compiled MLX shaders. Build the app with Xcode and the Metal Toolchain."
            }
        }
    }

    func release() {
        guard !busy, model != nil else { return }
        model = nil
        modelPath = nil
        Memory.clearCache()
    }

    func transcribe(
        audioURL: URL,
        segments: [SubtitleSegment],
        timeOffset: Double,
        options: Options,
        checkpoint: @escaping @Sendable () async throws -> Void,
        onProgress: @escaping @Sendable (Double) async -> Void,
        onDiagnostics: @escaping @Sendable (NativeQwenDiagnostics.Snapshot) async -> Void = { _ in }
    ) async throws -> [SubtitleCue] {
        guard !busy else { throw Failure.busy }
        busy = true
        defer { busy = false }
        var diagnostics = NativeQwenDiagnostics(totalSegments: segments.count)
        diagnostics.transition(to: .preparation)
        do {
            let cues = try await transcribePreparedAudio(
                audioURL: audioURL, segments: segments, timeOffset: timeOffset, options: options,
                checkpoint: checkpoint, onProgress: onProgress, onDiagnostics: onDiagnostics,
                diagnostics: &diagnostics)
            try Task.checkCancellation()
            await onDiagnostics(diagnostics.finish(.completed))
            return cues
        } catch {
            await onDiagnostics(diagnostics.finish(error is CancellationError || Task.isCancelled ? .cancelled : .failed))
            throw error
        }
    }

    private func publishDiagnostics(
        _ diagnostics: inout NativeQwenDiagnostics,
        nextStage: NativeQwenDiagnostics.Stage?,
        callback: @Sendable (NativeQwenDiagnostics.Snapshot) async -> Void
    ) async {
        diagnostics.transition(to: nil)
        await callback(diagnostics.snapshot(stage: nextStage))
        diagnostics.transition(to: nextStage)
    }

    private func transcribePreparedAudio(
        audioURL: URL,
        segments: [SubtitleSegment],
        timeOffset: Double,
        options: Options,
        checkpoint: @escaping @Sendable () async throws -> Void,
        onProgress: @escaping @Sendable (Double) async -> Void,
        onDiagnostics: @escaping @Sendable (NativeQwenDiagnostics.Snapshot) async -> Void,
        diagnostics: inout NativeQwenDiagnostics
    ) async throws -> [SubtitleCue] {
        try Task.checkCancellation()
        guard timeOffset.isFinite else { throw Failure.invalidSegment }
        // Empty VAD output is silence: do not load ASR or invent a full-file cue.
        guard !segments.isEmpty else { return [] }
        let pcm = try NativeQwenPCMReader(audioURL: audioURL, segments: segments)
        runtimeLibraryURL = try Self.checkRuntime(preferredLibrary: runtimeLibraryURL)
        let needsModel = modelPath != options.modelDirectory.path || model == nil
        diagnostics.modelCache = needsModel ? .miss : .hit
        if needsModel {
            await publishDiagnostics(&diagnostics, nextStage: .modelLoading, callback: onDiagnostics)
            try Task.checkCancellation()
            let configURL = options.modelDirectory.appending(path: "config.json")
            let config = try JSONSerialization.jsonObject(with: Data(contentsOf: configURL)) as? [String: Any]
            guard config?["model_type"] as? String == "qwen3_asr" else {
                throw Failure.missingResult
            }
            model = nil
            modelPath = nil
            Memory.clearCache()
            // Upstream generates tokenizer.json if absent. Use a writable staging
            // directory so installed model bundles and user weights stay untouched.
            let staging = FileManager.default.temporaryDirectory.appending(path: "msub-qwen-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            for source in try FileManager.default.contentsOfDirectory(at: options.modelDirectory, includingPropertiesForKeys: nil) {
                try FileManager.default.createSymbolicLink(at: staging.appending(path: source.lastPathComponent), withDestinationURL: source)
            }
            model = try await Qwen3ASRModel.fromModelDirectory(staging)
            modelPath = options.modelDirectory.path
        }
        try Task.checkCancellation()
        guard model != nil else { throw Failure.missingResult }
        await publishDiagnostics(&diagnostics, nextStage: .checkpoint, callback: onDiagnostics)
        var cues: [SubtitleCue] = []
        cues.reserveCapacity(segments.count)
        for (index, range) in pcm.ranges.enumerated() {
            diagnostics.transition(to: .checkpoint)
            try await checkpoint()
            try Task.checkCancellation()
            diagnostics.transition(to: .preparation)
            let samples = try pcm.samples(in: range)
            // Capture only Sendable values. MLX model/arrays remain inside this
            // actor, including while the uncancelled task drains a segment.
            diagnostics.transition(to: .decoding)
            let decode = Task { [self] in
                try await decodeSegment(samples: samples, options: options)
            }
            let finalText = try await decode.value
            try Task.checkCancellation()
            diagnostics.transition(to: .postprocessing)
            let text = Self.wrap(finalText.trimmingCharacters(in: .whitespacesAndNewlines), limit: options.lineCharacters)
            if !text.isEmpty {
                cues.append(SubtitleCue(
                    index: cues.count + 1,
                    start: Double(range.lowerBound) / 16000 + timeOffset,
                    end: Double(range.upperBound) / 16000 + timeOffset,
                    text: text, confidence: nil, speaker: nil
                ))
            }
            diagnostics.completedSegments = index + 1
            diagnostics.transition(to: nil)
            await onProgress(Double(index + 1) / Double(segments.count))
            await publishDiagnostics(&diagnostics, nextStage: .checkpoint, callback: onDiagnostics)
        }
        return cues
    }

    private func decodeSegment(samples: [Float], options: Options) async throws -> String {
        guard let model else { throw Failure.missingResult }
        let input = MLXArray(samples)
        var finalText: String?
        for try await event in model.generateStream(
            audio: input, maxTokens: max(1, min(options.maxTokens, 8192)),
            temperature: 0, context: options.context, language: options.language,
            chunkDuration: 30, minChunkDuration: 0
        ) {
            if case .result(let result) = event { finalText = result.text }
        }
        guard let finalText else { throw Failure.missingResult }
        return finalText
    }

    /// Cue re-recognition can use AVFoundation directly, without a Python job.
    /// The bounded clip has its own zero-based timeline; the editor keeps the
    /// original cue's timing and replaces only the recognized text.
    func transcribeClip(audioURL: URL, options: Options) async throws -> [SubtitleCue] {
        guard !busy else { throw Failure.busy }
        try Task.checkCancellation()
        let input = try AVAudioFile(forReading: audioURL)
        let duration = Double(input.length) / input.processingFormat.sampleRate
        _ = try Self.sampleRange(start: 0, end: duration, duration: duration)
        if input.processingFormat.sampleRate == 16000, input.processingFormat.channelCount == 1 {
            return try await transcribe(
                audioURL: audioURL,
                segments: [SubtitleSegment(index: 1, start: 0, end: duration, duration: duration)],
                timeOffset: 0, options: options,
                checkpoint: { try Task.checkCancellation() }, onProgress: { _ in })
        }
        guard let source = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(input.length)),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: input.processingFormat, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(ceil(duration * 16000) + 1024)) else {
            throw Failure.invalidAudio
        }
        try input.read(into: source)
        let inputSource = ConversionInput(source)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, status in
            inputSource.next(status)
        }
        if let conversionError { throw conversionError }
        guard status != .error, output.frameLength > 0 else { throw Failure.invalidAudio }
        let wav = FileManager.default.temporaryDirectory.appending(path: "msub-native-cue-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        do {
            let writer = try AVAudioFile(forWriting: wav, settings: format.settings)
            try writer.write(from: output)
        }
        let convertedDuration = Double(output.frameLength) / 16000
        return try await transcribe(
            audioURL: wav,
            segments: [SubtitleSegment(index: 1, start: 0, end: convertedDuration, duration: convertedDuration)],
            timeOffset: 0, options: options,
            checkpoint: { try Task.checkCancellation() }, onProgress: { _ in }
        )
    }

    /// Owns the buffer exclusively after reading. The converter receives it at
    /// most once; neither the caller nor a second callback can mutate it.
    private final class ConversionInput: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer: AVAudioPCMBuffer?

        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }

        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            lock.lock()
            defer { lock.unlock() }
            guard let buffer else {
                status.pointee = .endOfStream
                return nil
            }
            self.buffer = nil
            status.pointee = .haveData
            return buffer
        }
    }

    nonisolated static func sampleRange(start: Double, end: Double, duration: Double) throws -> Range<Int> {
        guard start.isFinite, end.isFinite, duration.isFinite,
              duration < Double(Int.max / 16000),
              start >= 0, end > start, end - start <= 30.001,
              start < duration, end <= duration + 0.05 else { throw Failure.invalidSegment }
        let lower = Int((start * 16000).rounded())
        let upper = Int((min(end, duration) * 16000).rounded())
        guard upper > lower else { throw Failure.invalidSegment }
        return lower..<upper
    }

    /// MLX aborts rather than throws when its default metallib is absent. Check
    /// the packaged resources before the first MLX call so fallback stays safe.
    nonisolated static func checkRuntime(preferredLibrary: URL? = nil) throws -> URL {
        guard let device = MTLCreateSystemDefaultDevice() else { throw Failure.runtimeUnavailable }
        let library = NativeMLXLibrarySearch.find(preferred: preferredLibrary, candidates: {
            let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent()
            let bundles = Bundle.allBundles
            let roots = [Bundle.main.bundleURL, Bundle.main.resourceURL, executableDirectory].compactMap { $0 }
                + bundles.compactMap(\.resourceURL)
                + bundles.compactMap { $0.executableURL?.deletingLastPathComponent() }
            return roots.flatMap { root in
                ["mlx.metallib", "Resources/mlx.metallib", "Resources/default.metallib",
                 "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib",
                 "mlx-swift_Cmlx.bundle/default.metallib"].map { root.appending(path: $0) }
            }
        }, load: { (try? device.makeLibrary(URL: $0)) != nil })
        guard let library else {
            throw Failure.runtimeUnavailable
        }
        return library
    }

    nonisolated static func wrap(_ text: String, limit: Int) -> String {
        guard limit > 0 else { return text }
        // Preserve words in space-separated scripts; split CJK at Characters,
        // never UTF-16 offsets (which can cut emoji or combining sequences).
        return text.components(separatedBy: .newlines).map { paragraph in
            var lines: [String] = []
            var line = ""
            let tokens = paragraph.contains(" ") ? paragraph.split(separator: " ").map(String.init) : paragraph.map(String.init)
            let separator = paragraph.contains(" ") ? " " : ""
            for token in tokens {
                if !line.isEmpty && line.count + separator.count + token.count > limit {
                    lines.append(line)
                    line = ""
                }
                if !line.isEmpty { line += separator }
                line += token
            }
            if !line.isEmpty { lines.append(line) }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n")
    }
}
