import XCTest
@testable import MSub

@MainActor
final class SubtitleSearchTimelineCacheTests: XCTestCase {
    func testSharedSearchRespectsScopeCaseAndRevision() {
        var cue = SubtitleCue(index: 1, start: 0, end: 2, text: "")
        cue.setBilingual(.init(source: "Hello hello", translation: "hello"))
        let cache = SubtitleSearchCache()
        let revision = UUID()
        let all = SubtitleTextSearch(query: "hello", replacement: "", matchCase: false, scope: .all)
        XCTAssertEqual(cache.value(cues: [cue], revision: revision, search: all).count, 3)
        let translated = SubtitleTextSearch(query: "hello", replacement: "", matchCase: false, scope: .translation)
        XCTAssertEqual(cache.value(cues: [cue], revision: revision, search: translated).count, 1)
        let exact = SubtitleTextSearch(query: "hello", replacement: "", matchCase: true, scope: .source)
        XCTAssertEqual(cache.value(cues: [cue], revision: revision, search: exact).count, 1)
        cue.start = 1
        let moved = cache.value(cues: [cue], revision: UUID(), search: all)
        XCTAssertEqual(moved.cues.first?.start, 1)
        XCTAssertEqual(moved.indices, [0])
        cue.text = "Goodbye"
        XCTAssertEqual(cache.value(cues: [cue], revision: UUID(), search: all).count, 0)
    }

    func testSearchReplacementAndEmptyQueryDoNotChangeMatchSemantics() {
        let cues = [SubtitleCue(index: 1, start: 0, end: 1, text: "é👩🏽‍💻 é")]
        let cache = SubtitleSearchCache()
        let revision = UUID()
        let a = SubtitleTextSearch(query: "e", replacement: "a", matchCase: false, scope: .all)
        let b = SubtitleTextSearch(query: "e", replacement: "b", matchCase: false, scope: .all)
        XCTAssertEqual(cache.value(cues: cues, revision: revision, search: a).count, 2)
        XCTAssertEqual(cache.value(cues: cues, revision: revision, search: b).count, 2)
        let empty = SubtitleTextSearch(query: "", replacement: "", matchCase: false, scope: .all)
        XCTAssertTrue(cache.value(cues: cues, revision: revision, search: empty).cues.isEmpty)
    }

    func testVisibleRangeKeepsEnclosingCuesAndInclusiveBoundaries() {
        let cues = [
            SubtitleCue(index: 1, start: 0, end: 100, text: "long"),
            SubtitleCue(index: 2, start: 1, end: 2, text: "short"),
            SubtitleCue(index: 3, start: 3, end: 4, text: "short"),
            SubtitleCue(index: 4, start: 50, end: 51, text: "short")
        ]
        let index = SubtitleCueIndex(cues)
        XCTAssertEqual(index.visibleRange(lower: 60, upper: 65), 0..<4)
        XCTAssertEqual(index.visibleRange(lower: 100, upper: 100), 0..<4)
        XCTAssertEqual(index.visibleRange(lower: 101, upper: 110), 4..<4)
        XCTAssertEqual(SubtitleCueIndex(Array(cues.reversed())).visibleRange(lower: 60, upper: 65), 0..<4)
    }

    func testVisibleRangesCoverEveryIntersectionAcrossWindows() {
        let cues = (0..<1000).map { i in
            SubtitleCue(index: i + 1, start: Double(i), end: Double(i + (i % 13 == 0 ? 200 : 2)), text: "a")
        }
        let index = SubtitleCueIndex(cues)
        for start in stride(from: 0, through: 1200, by: 17) {
            let lower = Double(start), upper = lower + 12
            let range = index.visibleRange(lower: lower, upper: upper)
            for i in cues.indices where cues[i].end >= lower && cues[i].start <= upper {
                XCTAssertTrue(range.contains(i))
            }
        }
        XCTAssertEqual(SubtitleCueIndex([]).visibleRange(lower: 0, upper: 10), 0..<0)
    }

    func testCancelledTextStatsReturnNoPartialResults() async {
        let worker = Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            let cues = [SubtitleCue(index: 1, start: 0, end: 1, text: "😊 subtitles subtitles")]
            return (SubtitleTextStats.topTerms(in: cues), SubtitleEmotionStats.frequencies(in: cues))
        }
        let result = await worker.value
        XCTAssertTrue(result.0.isEmpty)
        XCTAssertTrue(result.1.isEmpty)
    }
}
