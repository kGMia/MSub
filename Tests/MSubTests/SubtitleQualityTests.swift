import XCTest
@testable import MSub

final class SubtitleQualityTests: XCTestCase {
    func testChecksNestedOverlapsAndIgnoresMarkupForReadingSpeed() {
        let cues = [
            SubtitleCue(index: 1, start: 0, end: 10, text: "<b>正常</b>"),
            SubtitleCue(index: 2, start: 1, end: 2, text: "正常"),
            SubtitleCue(index: 3, start: 3, end: 3.2, text: String(repeating: "字", count: 50)),
            SubtitleCue(index: 4, start: .nan, end: 4, text: "invalid")
        ]
        let issues = SubtitleQuality.inspect(cues, minimumDuration: 0.6, maximumCPS: 12, maximumLineLength: 40)
        XCTAssertFalse(issues.contains { $0.cueID == cues[0].id })
        XCTAssertTrue(issues.contains { $0.cueID == cues[2].id && $0.kind == .overlap })
        XCTAssertEqual(Set(issues.map { $0.kind.rawValue }), Set(["overlap", "short", "fast", "longLine", "invalidTime"]))
    }

    func testNavigationVisitsEveryIssueIncludingMultipleFindingsOnOneCue() throws {
        let cue = UUID()
        let issues: [SubtitleQualityIssue] = [
            .init(cueID: cue, index: 1, kind: .short),
            .init(cueID: cue, index: 1, kind: .fast),
            .init(cueID: UUID(), index: 2, kind: .overlap)
        ]
        var navigation = SubtitleQualityNavigation()
        XCTAssertNil(navigation.destination(in: issues, forward: false))
        XCTAssertEqual(navigation.destination(in: issues, forward: true)?.id, issues[0].id)
        navigation.focus(issues[0])
        XCTAssertEqual(navigation.destination(in: issues, forward: true)?.id, issues[1].id)
        navigation.focus(issues[1])
        navigation.follow(cueID: cue, in: issues)
        XCTAssertEqual(navigation.focusedID, issues[1].id)
        navigation.focus(issues[2])
        XCTAssertNil(navigation.destination(in: issues, forward: true))
        XCTAssertEqual(navigation.destination(in: issues, forward: false)?.id, issues[1].id)
    }

    func testResolvedIssueDoesNotSkipSuccessorAcrossRepeatedChecks() {
        let issues = (1...4).map { SubtitleQualityIssue(cueID: UUID(), index: $0, kind: .fast) }
        var navigation = SubtitleQualityNavigation()
        navigation.focus(issues[1])
        let afterFix = [issues[0], issues[2], issues[3]]
        navigation.reconcile(previous: issues, current: afterFix)
        XCTAssertNil(navigation.focusedID)
        XCTAssertEqual(navigation.destination(in: afterFix, forward: true)?.id, issues[2].id)
        let afterEarlierFix = [issues[2], issues[3]]
        navigation.reconcile(previous: afterFix, current: afterEarlierFix)
        XCTAssertEqual(navigation.destination(in: afterEarlierFix, forward: true)?.id, issues[2].id)
        navigation.reconcile(previous: afterEarlierFix, current: [issues[3]])
        XCTAssertEqual(navigation.destination(in: [issues[3]], forward: true)?.id, issues[3].id)
        navigation.reconcile(previous: [issues[3]], current: [])
        XCTAssertNil(navigation.destination(in: [], forward: true))
    }

    func testStableIssueIdentitySurvivesRenumberingAndFinalFixHasNoWrap() {
        let first = SubtitleQualityIssue(cueID: UUID(), index: 1, kind: .short)
        let last = SubtitleQualityIssue(cueID: UUID(), index: 2, kind: .longLine)
        var navigation = SubtitleQualityNavigation()
        navigation.focus(last)
        let renumbered = SubtitleQualityIssue(cueID: last.cueID, index: 15, kind: last.kind)
        navigation.reconcile(previous: [first, last], current: [first, renumbered])
        XCTAssertEqual(navigation.focusedID, last.id)
        navigation.reconcile(previous: [first, renumbered], current: [first])
        XCTAssertNil(navigation.destination(in: [first], forward: true))
        XCTAssertEqual(navigation.destination(in: [first], forward: false)?.id, first.id)
    }

    func testFilteringAndExternalSelectionStayWithinVisibleFindings() {
        let cue = UUID()
        let issues: [SubtitleQualityIssue] = [
            .init(cueID: cue, index: 1, kind: .short),
            .init(cueID: cue, index: 1, kind: .fast),
            .init(cueID: UUID(), index: 2, kind: .fast)
        ]
        let fast = SubtitleQualityNavigation.filtered(issues, kind: .fast)
        XCTAssertEqual(fast.map(\.id), [issues[1].id, issues[2].id])
        XCTAssertEqual(SubtitleQualityNavigation.filtered(issues, kind: nil), issues)
        XCTAssertTrue(SubtitleQualityNavigation.filtered(issues, kind: .invalidTime).isEmpty)
        var navigation = SubtitleQualityNavigation()
        navigation.follow(cueID: cue, in: fast)
        XCTAssertEqual(navigation.focusedID, issues[1].id)
        navigation.follow(cueID: UUID(), in: fast)
        XCTAssertNil(navigation.focusedID)
        XCTAssertEqual(navigation.destination(in: fast, forward: true)?.id, issues[1].id)
    }

    func testPagingIncludesFindingsBeyondOneHundredAndClampsAfterDeletion() {
        let ranges = (0..<3).map { SubtitleQualityNavigation.pageRange(page: $0, count: 123) }
        XCTAssertEqual(ranges.flatMap { Array($0) }, Array(0..<123))
        XCTAssertEqual(SubtitleQualityNavigation.pageRange(page: 8, count: 12), 0..<12)
        XCTAssertEqual(SubtitleQualityNavigation.pageRange(page: -1, count: 123), 0..<50)
        XCTAssertEqual(SubtitleQualityNavigation.pageRange(page: 3, count: 0), 0..<0)
        let issues = (0..<123).map { SubtitleQualityIssue(cueID: UUID(), index: $0, kind: .fast) }
        var navigation = SubtitleQualityNavigation()
        navigation.focus(issues[99])
        XCTAssertEqual(navigation.destination(in: issues, forward: true)?.id, issues[100].id)
    }

}
