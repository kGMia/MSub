import XCTest
@testable import MSub

@MainActor
final class TimelineRenderingTests: XCTestCase {
    func testSweepMatchesPairwiseCoverageAndMultiplicity() {
        let cues = (0..<50).map { i in
            SubtitleCue(index: i, start: Double(i % 17), end: Double(i % 17 + i % 9 + 1), text: "x")
        }
        let map = TimelineOverlapMap(Array(cues.reversed()))
        for time in stride(from: 0.25, through: 26.0, by: 0.5) {
            var pairs = 0
            for i in cues.indices {
                for j in (i + 1)..<cues.count {
                    if max(cues[i].start, cues[j].start) <= time && time < min(cues[i].end, cues[j].end) { pairs += 1 }
                }
            }
            XCTAssertEqual(map.spans.first { $0.start <= time && time < $0.end }?.pairs ?? 0, pairs)
        }
        XCTAssertTrue(zip(map.spans, map.spans.dropFirst()).allSatisfy { $0.end <= $1.start })
    }

    func testTouchingAndInvalidIntervalsDoNotCreateFalseOverlap() {
        let cues = [
            SubtitleCue(index: 1, start: 0, end: 1, text: "a"),
            SubtitleCue(index: 2, start: 1, end: 2, text: "b"),
            SubtitleCue(index: 3, start: 1, end: 1, text: "empty"),
            SubtitleCue(index: 4, start: .nan, end: 2, text: "invalid")
        ]
        XCTAssertTrue(TimelineOverlapMap(cues).spans.isEmpty)
        let nested = TimelineOverlapMap(cues.prefix(2).map { cue in
            var changed = cue
            changed.end = 3
            return changed
        })
        XCTAssertEqual(nested.spans.count, 1)
        XCTAssertEqual(nested.spans[0].start, 1)
        XCTAssertEqual(nested.spans[0].end, 3)
        XCTAssertTrue(nested.visible(lower: 3, upper: 5).isEmpty)
    }

    func testDenseOverlapHasBoundedSpanCountAndPreservesFillStrength() {
        let cues = (0..<1000).map { SubtitleCue(index: $0, start: 1, end: 2, text: "x") }
        let map = TimelineOverlapMap(cues)
        XCTAssertEqual(map.spans.count, 1)
        XCTAssertEqual(map.spans[0].pairs, 499500)
        XCTAssertEqual(map.spans[0].fillOpacity, 1)
        let pair = TimelineOverlapMap(Array(cues.prefix(2)))
        XCTAssertEqual(pair.spans[0].fillOpacity, 1 - (1 - 0.42))
    }

    func testMarkersAreIndexedAndInvalidateWithSearchOrTiming() {
        var cue = SubtitleCue(index: 1, start: 4, end: 6, text: "Hello hello")
        let cache = SubtitleSearchCache()
        let revision = UUID()
        let search = SubtitleTextSearch(query: "hello", replacement: "", matchCase: false, scope: .all)
        let first = cache.value(cues: [cue], revision: revision, search: search)
        XCTAssertEqual(first.markers, cache.value(cues: [cue], revision: revision, search: search).markers)
        XCTAssertEqual(first.markers.time(for: cue.id), 5)
        XCTAssertEqual(first.markers.visible(lower: 5, upper: 5).count, 1)
        XCTAssertTrue(first.markers.visible(lower: 6, upper: 7).isEmpty)
        cue.start = 6
        cue.end = 8
        let changed = cache.value(cues: [cue], revision: UUID(), search: search)
        XCTAssertEqual(changed.markers.time(for: cue.id), 7)
        XCTAssertNotEqual(changed.markers, first.markers)
        XCTAssertNil(changed.markers.time(for: UUID()))
    }

    func testFrequentTermHighlightRetainsCombinedTextSemantics() {
        var cue = SubtitleCue(index: 1, start: 0, end: 1, text: "")
        cue.setBilingual(.init(source: "Hello", translation: "World"))
        let cache = SubtitleSearchCache()
        let revision = UUID()
        let search = SubtitleTextSearch(query: "Hello\nWorld", replacement: "", matchCase: false, scope: .all)
        XCTAssertTrue(cache.value(cues: [cue], revision: revision, search: search).markers.dots.isEmpty)
        XCTAssertEqual(cache.value(cues: [cue], revision: revision, search: search, literalHighlight: true).markers.dots.count, 1)
    }
}
