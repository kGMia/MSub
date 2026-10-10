import AVFoundation
import XCTest
@testable import MSub

final class NativeAudioExporterTests: XCTestCase {
    @MainActor
    func testStereoResamplingAndCropTiming() async throws {
        let source = try makeSource()
        defer { try? FileManager.default.removeItem(at: source) }
        let output = try await NativeAudioExporter.shared.extract(source: source, start: 0.25, duration: 2)
        defer { try? FileManager.default.removeItem(at: output.url) }
        XCTAssertEqual(output.duration, 2)
        let audio = try AVAudioFile(forReading: output.url)
        XCTAssertEqual(audio.processingFormat.sampleRate, 16000)
        XCTAssertEqual(audio.processingFormat.channelCount, 1)
        XCTAssertEqual(audio.length, 32000)
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 32000))
        try audio.read(into: pcm)
        let samples = try XCTUnwrap(pcm.floatChannelData?[0])
        // Source speech-like pulse is at 1...2 seconds; crop moves it to .75...1.75.
        XCTAssertEqual(samples[8000], 0, accuracy: 0.01)
        XCTAssertGreaterThan(abs(samples[16000]), 0.15)
        XCTAssertEqual(samples[30400], 0, accuracy: 0.01)
    }

    @MainActor
    func testWaveformPreservesPulseBoundariesAcrossResolutions() async throws {
        let source = try makeSource()
        defer { try? FileManager.default.removeItem(at: source) }
        // 300 bins divide the three-second fixture exactly; the lower-resolution
        // request also exercises peak-preserving downsampling from the cache.
        for count in [300, 150] {
            let samples = await WaveformLoader.samples(for: source, targetSamples: count)
            XCTAssertEqual(samples.count, count)
            guard samples.count == count else { return }
            XCTAssertEqual(samples[count / 6], 0, accuracy: 0.01)
            XCTAssertGreaterThan(samples[count / 2], 0.99)
            XCTAssertEqual(samples[count * 5 / 6], 0, accuracy: 0.01)
            XCTAssertTrue(samples.allSatisfy { $0.isFinite && (0...1).contains($0) })
        }
    }

    @MainActor
    func testTailClampAndCancellation() async throws {
        let source = try makeSource()
        defer { try? FileManager.default.removeItem(at: source) }
        let output = try await NativeAudioExporter.shared.extract(source: source, start: 2.5, duration: 4)
        defer { try? FileManager.default.removeItem(at: output.url) }
        XCTAssertEqual(output.duration, 0.5, accuracy: 1.0 / 16000)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await NativeAudioExporter.shared.extract(source: source, start: 0, duration: 1)
        }
        do { _ = try await task.value; XCTFail("Cancelled export succeeded") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    private func makeSource() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "msub-export-test-\(UUID().uuidString).wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 132300))
        buffer.frameLength = 132300
        for channel in 0..<2 {
            let samples = try XCTUnwrap(buffer.floatChannelData?[channel])
            for index in 0..<132300 { samples[index] = (44100..<88200).contains(index) ? 0.25 : 0 }
        }
        let writer = try AVAudioFile(forWriting: url, settings: format.settings)
        try writer.write(from: buffer)
        return url
    }
}
