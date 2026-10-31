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
            [.init(start: 0, end: 20), .init(start: 20, end: 40), .init(start: 40, end: 60)])

        let cycle = [Float](repeating: 0, count: 45) + [Float](repeating: 1, count: 155)
        let probabilities = Array(repeating: cycle, count: 25).flatMap { $0 }
        let padded: [FireRedSpeechRange] = (0..<25).map { index in
            let start = Double(index * 2000 + 360) / 1000
            let end = min(50.0, Double(index * 2000 + 2130) / 1000)
            return FireRedSpeechRange(start: start, end: end)
        }
        XCTAssertEqual(FireRedVADSegmentation.ranges(probabilities: probabilities, duration: 50, options: defaults), padded)
        var short = defaults
        short.maxSegment = 3; short.minSegment = 0.8; short.padding = 0
        let expected: [FireRedSpeechRange] = (0..<25).map { index in
            let start = Double(index * 2000 + 460) / 1000
            let end = min(49.99, Double(index * 2000 + 2030) / 1000)
            return FireRedSpeechRange(start: start, end: end)
        }
        XCTAssertEqual(FireRedVADSegmentation.ranges(probabilities: probabilities, duration: 50, options: short), expected)
    }

    func testSustainedValleyAndFlatFallback() {
        var values = [Float](repeating: 1, count: 200)
        values[30] = 0
        for index in 120..<150 { values[index] = 0.1 }
        XCTAssertEqual(FireRedVADSegmentation.lowProbabilityCut(values, lo: 0, hi: 200, target: 2,
            windowStart: 0, windowEnd: 2), 1.35)
        XCTAssertEqual(FireRedVADSegmentation.lowProbabilityCut([Float](repeating: 1, count: 200),
            lo: 0, hi: 200, target: 2, windowStart: 0, windowEnd: 2), 2)
    }

    func testShortRepliesSurvivePaddingAndMerge() {
        var values = [Float](repeating: 0, count: 120)
        for i in 10..<35 { values[i] = 1 }
        for i in 85..<110 { values[i] = 1 }
        var options = FireRedVADOptions()
        options.smoothWindow = 1
        XCTAssertEqual(FireRedVADSegmentation.ranges(probabilities: values, duration: 1.2, options: options),
                       [.init(start: 0, end: 0.45), .init(start: 0.75, end: 1.2)])
        XCTAssertEqual(FireRedVADSegmentation.silenceBoundaries(values, threshold: 0.4, minimumFrames: 30), [0.6])
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
