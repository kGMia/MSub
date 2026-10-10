import Foundation
import XCTest
@testable import MSub

final class NativeQwenServiceTests: XCTestCase {
    func testSegmentBoundsPreserveSpeechTimeline() throws {
        let range = try NativeQwenService.sampleRange(start: 1.25, end: 3.5, duration: 10)
        XCTAssertEqual(range, 20000..<56000)
        // Preview duration is rounded to milliseconds; clamp only the tail.
        XCTAssertEqual(try NativeQwenService.sampleRange(start: 9, end: 10.001, duration: 10), 144000..<160000)
    }

    func testRejectsUnsafeAndOversizedSegments() {
        for (start, end) in [(Double.nan, 2.0), (0, Double.infinity), (-1, 2), (3, 2), (0, 31), (11, 12)] {
            XCTAssertThrowsError(try NativeQwenService.sampleRange(start: start, end: end, duration: 10))
        }
    }

    func testWrapPreservesWordsAndGraphemeClusters() {
        XCTAssertEqual(NativeQwenService.wrap("Hello world again", limit: 11), "Hello world\nagain")
        XCTAssertEqual(NativeQwenService.wrap("你好👨‍👩‍👧‍👦世界", limit: 3), "你好👨‍👩‍👧‍👦\n世界")
    }

    @MainActor
    func testUnsupportedOptionsRetainPythonPipeline() {
        let previous = UserDefaults.standard.object(forKey: "msub.nativeQwen.enabled")
        defer { UserDefaults.standard.set(previous, forKey: "msub.nativeQwen.enabled") }
        let settings = TranscriptionSettings()
        settings.asrEngine = .qwen3
        settings.nativeQwenEnabled = true
        settings.mimoTopP = 1
        XCTAssertTrue(settings.canUseNativeQwen)
        settings.alignWords = true
        XCTAssertFalse(settings.canUseNativeQwen)
        settings.alignWords = false
        settings.mimoTemperature = 0.7
        XCTAssertFalse(settings.canUseNativeQwen)
    }

    @MainActor
    func testSilenceDoesNotLoadModelOrGPU() async throws {
        let options = NativeQwenService.Options(modelDirectory: URL(fileURLWithPath: "/missing"), language: nil, context: "", maxTokens: 128, lineCharacters: 18)
        let cues = try await NativeQwenService.shared.transcribe(
            audioURL: URL(fileURLWithPath: "/missing.wav"), segments: [], timeOffset: 0,
            options: options, checkpoint: {}, onProgress: { _ in }
        )
        XCTAssertTrue(cues.isEmpty)
        await NativeQwenService.shared.release()
    }

    @MainActor
    func testCancelledRequestDoesNotLoadModel() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            let options = NativeQwenService.Options(modelDirectory: URL(fileURLWithPath: "/missing"), language: nil, context: "", maxTokens: 128, lineCharacters: 18)
            return try await NativeQwenService.shared.transcribe(
                audioURL: URL(fileURLWithPath: "/missing.wav"), segments: [], timeOffset: 0,
                options: options, checkpoint: {}, onProgress: { _ in }
            )
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled request returned success")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    @MainActor
    func testLocalModelSmoke() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let model = environment["MSUB_NATIVE_TEST_MODEL"],
              let wav = environment["MSUB_NATIVE_TEST_AUDIO"] else {
            throw XCTSkip("Set MSUB_NATIVE_TEST_MODEL and MSUB_NATIVE_TEST_AUDIO for real MLX inference.")
        }
        let options = NativeQwenService.Options(modelDirectory: URL(fileURLWithPath: model), language: "Chinese", context: "", maxTokens: 128, lineCharacters: 18)
        do {
            let cues = try await NativeQwenService.shared.transcribe(
                audioURL: URL(fileURLWithPath: wav),
                segments: [SubtitleSegment(index: 1, start: 0, end: 5, duration: 5)],
                timeOffset: 12, options: options, checkpoint: { try Task.checkCancellation() }, onProgress: { _ in }
            )
            XCTAssertFalse(cues.isEmpty)
            XCTAssertEqual(cues.first?.start, 12)
            XCTAssertEqual(cues.last?.end, 17)
            print("NATIVE_QWEN_SMOKE: \(SubtitleDocument.serialize(cues, format: .srt))")

            // A second file reuses the same model with its own timeline offset.
            let repeated = try await NativeQwenService.shared.transcribe(
                audioURL: URL(fileURLWithPath: wav),
                segments: [SubtitleSegment(index: 1, start: 0, end: 5, duration: 5)],
                timeOffset: 0, options: options, checkpoint: {}, onProgress: { _ in }
            )
            XCTAssertEqual(repeated.first?.start, 0)
            XCTAssertEqual(repeated.last?.end, 5)
            XCTAssertEqual(repeated.map(\.text), cues.map(\.text))

            // Cancel after the warm model enters a segment. Awaiting the task
            // must drain decoding, leave no partial result, and permit reuse.
            let (began, signal) = AsyncStream<Void>.makeStream()
            let cancelling = Task {
                defer { signal.finish() }
                return try await NativeQwenService.shared.transcribe(
                    audioURL: URL(fileURLWithPath: wav),
                    segments: [SubtitleSegment(index: 1, start: 0, end: 5, duration: 5)],
                    timeOffset: 0, options: options,
                    checkpoint: { signal.yield(()); signal.finish() }, onProgress: { _ in }
                )
            }
            for await _ in began { break }
            try await Task.sleep(for: .milliseconds(100))
            cancelling.cancel()
            do {
                _ = try await cancelling.value
                XCTFail("Cancelled decode published a result")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            let recovered = try await NativeQwenService.shared.transcribe(
                audioURL: URL(fileURLWithPath: wav),
                segments: [SubtitleSegment(index: 1, start: 0, end: 5, duration: 5)],
                timeOffset: 12, options: options, checkpoint: {}, onProgress: { _ in }
            )
            XCTAssertEqual(recovered.map(\.text), cues.map(\.text))
            XCTAssertEqual(recovered.first?.start, 12)
            print("NATIVE_QWEN_REUSE_AND_CANCEL: passed")
            let clipURL = URL(fileURLWithPath: environment["MSUB_NATIVE_TEST_CLIP"] ?? wav)
            let clipCues = try await NativeQwenService.shared.transcribeClip(audioURL: clipURL, options: options)
            XCTAssertFalse(clipCues.isEmpty)
            XCTAssertEqual(clipCues.first?.start, 0)
            XCTAssertEqual(clipCues.last?.end ?? 0, 5, accuracy: 0.1)
            print("NATIVE_QWEN_CLIP: passed")
            let nativePCM = try await NativeAudioExporter.shared.extract(source: clipURL, start: 0, duration: 5)
            defer { try? FileManager.default.removeItem(at: nativePCM.url) }
            let nativeCues = try await NativeQwenService.shared.transcribeClip(audioURL: nativePCM.url, options: options)
            XCTAssertFalse(nativeCues.isEmpty)
            XCTAssertEqual(nativeCues.last?.end ?? 0, 5, accuracy: 0.1)
            print("NATIVE_PCM_TO_QWEN: passed")
            await NativeQwenService.shared.release()
        } catch {
            await NativeQwenService.shared.release()
            throw error
        }
    }
}
