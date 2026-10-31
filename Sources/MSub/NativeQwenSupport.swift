import AVFoundation
import Foundation

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

/// Owns AVFoundation state on a separate actor. Only owned Float arrays cross
/// the boundary; a caller may keep at most one read ahead of the GPU decoder.
actor NativeQwenAudioSource {
    nonisolated let ranges: [Range<Int>]
    private let reader: NativeQwenPCMReader

    init(audioURL: URL, segments: [SubtitleSegment]) throws {
        let reader = try NativeQwenPCMReader(audioURL: audioURL, segments: segments)
        self.reader = reader
        self.ranges = reader.ranges
    }

    func samples(in range: Range<Int>) throws -> [Float] {
        try Task.checkCancellation()
        return try reader.samples(in: range)
    }
}

/// A suspicion signal for a single bounded audio retry, not permission to delete
/// repeated speech. Keep equivalent to Python qwen_repetition.has_phrase_loop.
enum NativeQwenRepetition {
    static func hasPhraseLoop(_ text: String) -> Bool {
        let chars = Array(String(text.suffix(8192)).lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }.suffix(4096))
        let maximum = min(80, chars.count / 4)
        guard maximum >= 4 else { return false }
        for width in 4...maximum {
            var run = 0
            let needed = max(3 * width, 24 - width)
            for index in width..<chars.count {
                run = chars[index] == chars[index - width] ? run + 1 : 0
                if run >= needed { return true }
            }
        }
        return false
    }

    static func acceptsRetry(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !hasPhraseLoop(text)
    }
}
