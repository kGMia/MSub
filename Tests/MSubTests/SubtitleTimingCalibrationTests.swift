import XCTest
@testable import MSub

final class SubtitleTimingCalibrationTests: XCTestCase {
    func testMapsBothAnchorsAndWordTimesPreservingContent() throws {
        let mapping = SubtitleTimingCalibration(sourceFirst: 1, targetFirst: 2, sourceLast: 11, targetLast: 14)
        let cue = SubtitleCue(index: 7, start: 1, end: 11, text: "Hello", confidence: 0.9,
                              speaker: "Speaker 2", words: [.init(text: "Hello", start: 1.5, end: 2)])
        let result = try mapping.applying(to: [cue])[0]
        XCTAssertEqual(result.start, 2)
        XCTAssertEqual(result.end, 14)
        XCTAssertEqual(result.words?.first?.start, 2.6)
        XCTAssertEqual(result.words?.first?.end, 3.2)
        XCTAssertEqual(result.id, cue.id)
        XCTAssertEqual(result.index, cue.index)
        XCTAssertEqual(result.text, cue.text)
        XCTAssertEqual(result.speaker, cue.speaker)
        XCTAssertEqual(result.confidence, cue.confidence)
    }

    func testRejectsInvalidAnchorsAndNegativeOrCollapsedResults() {
        let cues = [SubtitleCue(index: 1, start: 1, end: 2, text: "One")]
        let reversed = SubtitleTimingCalibration(sourceFirst: 10, targetFirst: 0, sourceLast: 1, targetLast: 5)
        XCTAssertThrowsError(try reversed.applying(to: cues))
        let negative = SubtitleTimingCalibration(sourceFirst: 5, targetFirst: 1, sourceLast: 15, targetLast: 11)
        XCTAssertThrowsError(try negative.applying(to: cues))
        let collapsed = SubtitleTimingCalibration(sourceFirst: 0, targetFirst: 0, sourceLast: 10000, targetLast: 0.001)
        XCTAssertThrowsError(try collapsed.applying(to: cues))
        let tooShort = SubtitleTimingCalibration(sourceFirst: 0, targetFirst: 0, sourceLast: 100, targetLast: 1)
        XCTAssertThrowsError(try tooShort.applying(to: cues))
        var invalid = SubtitleTimingCalibration()
        invalid.targetLast = .infinity
        XCTAssertThrowsError(try invalid.applying(to: cues))
        let corrupt = SubtitleCue(index: 2, start: 2, end: 3, text: "Invalid word",
                                  words: [.init(text: "word", start: .nan, end: 3)])
        XCTAssertThrowsError(try SubtitleTimingCalibration().applying(to: [cues[0], corrupt]))
    }
}
