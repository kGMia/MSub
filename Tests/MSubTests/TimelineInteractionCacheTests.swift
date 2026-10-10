import XCTest
@testable import MSub

@MainActor
final class TimelineInteractionCacheTests: XCTestCase {
    func testSnapIndexMatchesLinearHandleAndMoveSearch() {
        let cues = (0..<200).map {
            SubtitleCue(index: $0, start: Double(($0 * 37) % 101),
                        end: Double(($0 * 37) % 101) + Double($0 % 7), text: "x")
        }
        let excluded = cues[23].id
        let index = TimelineSnapIndex(cues: cues, excluding: excluded)
        let edges = cues.filter { $0.id != excluded }.flatMap { [$0.start, $0.end] }
        for start in stride(from: -1.0, through: 109.0, by: 0.25) {
            for threshold in [0.0, 0.125, 0.5, 5.0] {
                let end = start + 2.5
                var handle: Double?, move: Double?
                var handleDistance = Double.infinity, moveDistance = Double.infinity
                for edge in edges {
                    let a = abs(edge - start), b = abs(edge - end)
                    if a < handleDistance { handleDistance = a; handle = edge }
                    if a < moveDistance { moveDistance = a; move = edge }
                    if b < moveDistance { moveDistance = b; move = edge - (end - start) }
                }
                XCTAssertEqual(index.snappedTime(start, threshold: threshold), handleDistance <= threshold ? handle : nil)
                XCTAssertEqual(index.snappedStart(start: start, end: end, threshold: threshold), moveDistance <= threshold ? move : nil)
            }
        }
    }

    func testSnapTiesExclusionAndNewGestureSnapshot() {
        var cues = [SubtitleCue(index: 1, start: 6, end: 8, text: "first"),
                    SubtitleCue(index: 2, start: 4, end: 6, text: "second"),
                    SubtitleCue(index: 3, start: 5, end: 7, text: "dragged")]
        let original = TimelineSnapIndex(cues: cues, excluding: cues[2].id)
        XCTAssertEqual(original.snappedTime(5, threshold: 1), 6)
        XCTAssertNil(original.snappedTime(5, threshold: 0.99))
        XCTAssertEqual(original.snappedStart(start: 5, end: 7, threshold: 1), 6)
        cues[0].start = 20
        XCTAssertEqual(original.snappedTime(5, threshold: 1), 6)
        XCTAssertEqual(TimelineSnapIndex(cues: cues, excluding: cues[2].id).snappedTime(5, threshold: 1), 4)
        let invalid = TimelineSnapIndex(times: [.nan, .infinity, -.infinity])
        XCTAssertNil(invalid.snappedTime(0, threshold: 5))
        XCTAssertNil(original.snappedTime(.nan, threshold: 5))
        XCTAssertNil(TimelineSnapIndex(times: []).snappedStart(start: 0, end: 1, threshold: 5))
    }

    func testDensityMatchesExistingInclusiveBinCoverage() {
        var cues = (0..<400).map {
            SubtitleCue(index: $0, start: Double(($0 * 11) % 120) - 10,
                        end: Double(($0 * 11) % 120) + Double($0 % 8), text: "x")
        }
        for i in cues.indices { cues[i].speaker = i.isMultiple(of: 3) ? " A \n" : "B" }
        for count in [20, 37, 180, 260] {
            let data = TimelineDensityBins(cues: cues, duration: 100, binCount: count, speaker: "A")
            var reference = [Int](repeating: 0, count: count)
            var speakers = reference
            for cue in cues {
                let lower = max(0, min(count - 1, Int(cue.start / 100 * Double(count))))
                let upper = max(lower, min(count - 1, Int(ceil(cue.end / 100 * Double(count)))))
                for i in lower...upper {
                    reference[i] += 1
                    if cue.speaker?.trimmingCharacters(in: .whitespacesAndNewlines) == "A" { speakers[i] += 1 }
                }
            }
            XCTAssertEqual(data.counts, reference)
            XCTAssertEqual(data.speakerCounts, speakers)
            XCTAssertEqual(data.maximum, reference.max())
        }
    }

    func testDensityCacheReuseAndAllInvalidators() {
        let cache = TimelineDensityCache(), revision = UUID()
        var cues = [SubtitleCue(index: 1, start: 0, end: 1, text: "x")]
        cues[0].speaker = "A"
        let initial = cache.value(cues: cues, revision: revision, duration: 10, binCount: 20, speaker: nil)
        XCTAssertEqual(cache.value(cues: cues, revision: revision, duration: 10, binCount: 20, speaker: nil).id, initial.id)
        let speaker = cache.value(cues: cues, revision: revision, duration: 10, binCount: 20, speaker: "A")
        XCTAssertNotEqual(speaker.id, initial.id)
        XCTAssertEqual(speaker.counts, initial.counts)
        XCTAssertEqual(speaker.speakerCounts, speaker.counts)
        let resized = cache.value(cues: cues, revision: revision, duration: 10, binCount: 21, speaker: "A")
        XCTAssertNotEqual(resized.id, speaker.id)
        let duration = cache.value(cues: cues, revision: revision, duration: 20, binCount: 21, speaker: "A")
        XCTAssertNotEqual(duration.id, resized.id)
        cues[0].end = 9
        let edited = cache.value(cues: cues, revision: UUID(), duration: 20, binCount: 21, speaker: "A")
        XCTAssertNotEqual(edited.id, duration.id)
        XCTAssertNotEqual(edited.counts, duration.counts)
    }

    func testDensityHandlesInvalidAndExtremeTimes() {
        let cues = [SubtitleCue(index: 1, start: .nan, end: 1, text: "invalid"),
                    SubtitleCue(index: 2, start: 1, end: .infinity, text: "invalid"),
                    SubtitleCue(index: 3, start: -.greatestFiniteMagnitude, end: .greatestFiniteMagnitude, text: "wide")]
        let data = TimelineDensityBins(cues: cues, duration: 0, binCount: 20, speaker: nil)
        XCTAssertEqual(data.counts, [Int](repeating: 1, count: 20))
        XCTAssertEqual(data.speakerCounts, [Int](repeating: 0, count: 20))
        XCTAssertEqual(TimelineDensityBins(cues: [], duration: .nan, binCount: 20, speaker: nil).maximum, 1)
    }
}
