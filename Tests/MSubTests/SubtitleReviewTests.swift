import XCTest
@testable import MSub

final class SubtitleReviewTests: XCTestCase {
    func testContextClampsAtMediaEdgesWithoutChangingCues() {
        let cues = [SubtitleCue(index: 1, start: 0.1, end: 1, text: "First"),
                    SubtitleCue(index: 2, start: 9, end: 10, text: "Last")]
        let plan = SubtitleReviewRange.plan(cues: cues, selectedID: cues[0].id,
                                           padding: 0.5, duration: 10, advance: true)
        XCTAssertEqual(plan, [.init(cueID: cues[0].id, start: 0, end: 1.5),
                              .init(cueID: cues[1].id, start: 8.5, end: 10)])
        XCTAssertEqual(cues[0].start, 0.1)
        XCTAssertEqual(cues[1].end, 10)
    }

    func testStartsFromSelectionAndSkipsInvalidOrOutOfMediaCues() {
        let cues = [SubtitleCue(index: 1, start: 0, end: 1, text: "Before"),
                    SubtitleCue(index: 2, start: 2, end: 3, text: "Selected"),
                    SubtitleCue(index: 3, start: .nan, end: 4, text: "Invalid"),
                    SubtitleCue(index: 4, start: 7, end: 6, text: "Reversed"),
                    SubtitleCue(index: 5, start: 8, end: 9, text: "Next"),
                    SubtitleCue(index: 6, start: 10, end: 11, text: "Beyond")]
        let plan = SubtitleReviewRange.plan(cues: cues, selectedID: cues[1].id,
                                           padding: 0, duration: 10, advance: true)
        XCTAssertEqual(plan.map(\.cueID), [cues[1].id, cues[4].id])
        let single = SubtitleReviewRange.plan(cues: cues, selectedID: cues[1].id,
                                             padding: .nan, duration: 10, advance: false)
        XCTAssertEqual(single, [.init(cueID: cues[1].id, start: 2, end: 3)])
        XCTAssertEqual(SubtitleReviewRange.plan(cues: cues, selectedID: UUID(), padding: 0,
                                               duration: 10, advance: true), [])
    }
}
