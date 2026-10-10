import AVFoundation
import XCTest
@testable import MSub

final class NativeAudioPreparationReuseTests: XCTestCase {
    private func writePCM(_ url: URL, rate: Double = 16000) throws -> [Float] {
        let values = (0..<1200).map { Float($0 % 129 - 64) / 128 }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(values.count))!
        buffer.frameLength = buffer.frameCapacity
        for i in values.indices { buffer.floatChannelData![0][i] = values[i] }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return values
    }

    private func segment(_ range: Range<Int>) -> SubtitleSegment {
        .init(index: 1, start: Double(range.lowerBound) / 16000,
              end: Double(range.upperBound) / 16000, duration: Double(range.count) / 16000)
    }

    func testPCMReusePreservesSequentialOverlappingAndReversedRanges() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let values = try writePCM(url)
        let ranges = [400..<800, 0..<160, 160..<400, 780..<1200]
        let reader = try NativeQwenPCMReader(audioURL: url, segments: ranges.map(segment))
        XCTAssertEqual(reader.ranges, ranges)
        var retained: [[Float]] = []
        for range in reader.ranges { retained.append(try reader.samples(in: range)) }
        // Earlier results must still own their samples after the buffer is reused.
        for (index, range) in ranges.enumerated() { XCTAssertEqual(retained[index], Array(values[range])) }
        XCTAssertEqual(try reader.samples(in: ranges[0]), retained[0])
    }

    func testPCMPlanRejectsInvalidFormatAndLateInvalidSegment() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try writePCM(url, rate: 8000)
        XCTAssertThrowsError(try NativeQwenPCMReader(audioURL: url, segments: [segment(0..<160)]))
        _ = try writePCM(url)
        XCTAssertThrowsError(try NativeQwenPCMReader(audioURL: url, segments: [segment(0..<160), segment(160..<16000)]))
        let reader = try NativeQwenPCMReader(audioURL: url, segments: [segment(0..<160)])
        XCTAssertThrowsError(try reader.samples(in: 0..<161))
        XCTAssertThrowsError(try reader.samples(in: 1200..<1210))
    }

    private func cmvn(mean: Float = 0) -> Data {
        var data = Data([0, 66, 70, 77, 32, 4]) // Kaldi binary FM matrix
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        append(Int32(2)); data.append(4); append(Int32(81))
        let values = [Float](repeating: mean, count: 80) + [1]
            + [Float](repeating: mean * mean + 1, count: 80) + [0]
        for value in values { append(value.bitPattern) }
        return data
    }

    func testFilterbankReuseMatchesFreshFeaturesAndReloadsSameSizeContent() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).ark")
        defer { try? FileManager.default.removeItem(at: url) }
        try cmvn().write(to: url)
        let cache = FireRedFilterbankCache()
        let first = try cache.value(cmvn: url)
        XCTAssertTrue(first === (try cache.value(cmvn: url)))
        let samples = (0..<560).map { Int16($0 % 101 - 50) }
        let expected = try samples.withUnsafeBufferPointer { try FireRedFilterbank(cmvn: url).features($0, frames: 2) }
        let reused = try samples.withUnsafeBufferPointer { try first.features($0, frames: 2) }
        XCTAssertEqual(reused, expected)
        let date = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]!
        try cmvn(mean: 1).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        let changed = try cache.value(cmvn: url)
        XCTAssertTrue(first !== changed)
        let updated = try samples.withUnsafeBufferPointer { try changed.features($0, frames: 2) }
        for i in updated.indices { XCTAssertEqual(updated[i], expected[i] - 1, accuracy: 0.00001) }
    }

    func testFilterbankCacheDoesNotHideMissingOrCorruptCMVN() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID()).ark")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = FireRedFilterbankCache()
        try cmvn().write(to: url)
        _ = try cache.value(cmvn: url)
        try Data([0, 66, 70]).write(to: url)
        XCTAssertThrowsError(try cache.value(cmvn: url))
        try FileManager.default.removeItem(at: url)
        XCTAssertThrowsError(try cache.value(cmvn: url))
        try cmvn(mean: 2).write(to: url)
        let recovered = try cache.value(cmvn: url)
        XCTAssertTrue(recovered === (try cache.value(cmvn: url)))
    }
}
