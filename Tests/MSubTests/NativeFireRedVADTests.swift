import XCTest
@testable import MSub

final class NativeFireRedVADTests: XCTestCase {
    // Expected boundaries captured from cli.py's complete FireRedVAD cleanup
    // pipeline, including low-probability splitting and short-segment merging.
    func testPythonBoundaryFixtures() {
        let defaults = FireRedVADOptions()
        XCTAssertEqual(FireRedVADSegmentation.ranges(
            probabilities: Array(repeating: 0, count: 600), duration: 6, options: defaults), [])
        XCTAssertEqual(FireRedVADSegmentation.ranges(
            probabilities: Array(repeating: 1, count: 6000), duration: 60, options: defaults),
            [.init(start: 0, end: 18), .init(start: 18, end: 36),
             .init(start: 36, end: 54), .init(start: 54, end: 60)])

        let cycle = [Float](repeating: 0, count: 45) + [Float](repeating: 1, count: 155)
        let probabilities = Array(repeating: cycle, count: 25).flatMap { $0 }
        XCTAssertEqual(FireRedVADSegmentation.ranges(probabilities: probabilities, duration: 50, options: defaults),
                       [.init(start: 0.36, end: 18.13), .init(start: 18.36, end: 36.13),
                        .init(start: 36.36, end: 50)])
        var short = defaults
        short.maxSegment = 3; short.minSegment = 0.8; short.padding = 0
        let expected: [FireRedSpeechRange] = (0..<25).map { index in
            let start = Double(index * 2000 + 460) / 1000
            let end = min(49.99, Double(index * 2000 + 2030) / 1000)
            return FireRedSpeechRange(start: start, end: end)
        }
        XCTAssertEqual(FireRedVADSegmentation.ranges(probabilities: probabilities, duration: 50, options: short), expected)
    }

    func testInvalidOptionsAndProbabilitiesAreRejected() {
        var options = FireRedVADOptions()
        options.smoothWindow = Int.max
        XCTAssertFalse(options.isSupported)
        XCTAssertEqual(FireRedVADSegmentation.ranges(probabilities: [1, 1], duration: 1, options: options), [])
        options = FireRedVADOptions(); options.minSpeech = .infinity
        XCTAssertFalse(options.isSupported)
        options = FireRedVADOptions(); options.maxSegment = 0.00001
        XCTAssertFalse(options.isSupported)
        options = FireRedVADOptions(); options.threshold = .nan
        XCTAssertFalse(options.isSupported)
        XCTAssertEqual(FireRedVADSegmentation.ranges(probabilities: [.nan], duration: 1,
                                                    options: FireRedVADOptions()), [])
    }

    func testTruncatedCMVNIsRejected() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([0, 66, 68, 77, 32]).write(to: url)
        XCTAssertThrowsError(try FireRedFilterbank(cmvn: url))
    }
}
