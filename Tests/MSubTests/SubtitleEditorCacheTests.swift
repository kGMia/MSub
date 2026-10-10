import XCTest
@testable import MSub

@MainActor
final class SubtitleEditorCacheTests: XCTestCase {
    func testFileSlotRevisionsTrackNestedEditsAndValueCopies() {
        var slot = FileSlot(url: URL(fileURLWithPath: "/tmp/editor-cache.wav"))
        slot.cues = [.init(index: 1, start: 0, end: 2, text: "A")]
        let first = slot.cuesRevision
        let copied = slot
        _ = slot.cues[0].text
        slot.selectedCueID = slot.cues[0].id
        XCTAssertEqual(slot.cuesRevision, first)
        slot.cues[0].text = "B"
        XCTAssertNotEqual(slot.cuesRevision, first)
        XCTAssertEqual(copied.cues[0].text, "A")
        XCTAssertEqual(copied.cuesRevision, first)
        let textEdit = slot.cuesRevision
        slot.cues[0].words = [.init(text: "B", start: 0, end: 1)]
        XCTAssertNotEqual(slot.cuesRevision, textEdit)
        let wordsEdit = slot.cuesRevision
        slot.cues[0].words?[0].end = 1.5
        XCTAssertNotEqual(slot.cuesRevision, wordsEdit)
        slot.originalCues = slot.cues
        let originalRevision = slot.originalCuesRevision
        slot.originalCues[0].speaker = "A"
        XCTAssertNotEqual(slot.originalCuesRevision, originalRevision)
        let beforeUndo = slot.cuesRevision
        slot.cues = copied.cues
        XCTAssertNotEqual(slot.cuesRevision, beforeUndo)
        XCTAssertEqual(slot.cues, copied.cues)
    }

    func testIndexRefreshesForSameCountReplacementAndSpeakerChanges() {
        let a = SubtitleCue(index: 1, start: 0, end: 3, text: "A", speaker: " A ")
        var b = SubtitleCue(index: 2, start: 3, end: 5, text: "B", speaker: "A")
        let cache = SubtitleCueIndexCache()
        let first = cache.value(for: [a, b], revision: UUID())
        XCTAssertEqual(first.positions[b.id], 1)
        XCTAssertEqual(first.speakers, ["A"])
        XCTAssertEqual(first.maximumEnd, 5)
        b.speaker = "B"
        b.end = .nan
        let second = cache.value(for: [b, a], revision: UUID())
        XCTAssertEqual(second.positions[b.id], 0)
        XCTAssertEqual(second.maximumEnd, 3)
        XCTAssertEqual(second.speakers, ["B", "A"])
        let replacement = SubtitleCue(index: 1, start: 0, end: 8, text: "New")
        let third = cache.value(for: [replacement, a], revision: UUID())
        XCTAssertNil(third.positions[b.id])
        XCTAssertEqual(third.maximumEnd, 8)
    }

    func testTextMetricsReuseAcrossThresholdAndTimingEditsAndPruneDeletedCues() {
        var cache = SubtitleQualityCache()
        var cues = (0..<1000).map { SubtitleCue(index: $0 + 1, start: Double($0 * 2), end: Double($0 * 2 + 1), text: "<b>字幕测试</b>") }
        _ = cache.inspect(cues, minimumDuration: 0.6, maximumCPS: 12, maximumLineLength: 40)
        XCTAssertEqual(cache.parsedTextCount, 1000)
        cues[500].end += 0.1
        _ = cache.inspect(cues, minimumDuration: 0.8, maximumCPS: 10, maximumLineLength: 20)
        XCTAssertEqual(cache.parsedTextCount, 0)
        cues[500].text = "Changed text"
        _ = cache.inspect(cues, minimumDuration: 0.8, maximumCPS: 10, maximumLineLength: 20)
        XCTAssertEqual(cache.parsedTextCount, 1)
        cues.removeFirst(900)
        _ = cache.inspect(cues, minimumDuration: 0.8, maximumCPS: 10, maximumLineLength: 20)
        XCTAssertEqual(cache.retainedTextCount, 100)
        _ = cache.inspect([], minimumDuration: 0.8, maximumCPS: 10, maximumLineLength: 20)
        XCTAssertEqual(cache.retainedTextCount, 0)
    }

    func testCachedScanRecomputesNonlocalOverlapAndAcceptsUnsortedInput() {
        var cache = SubtitleQualityCache()
        var cues = [
            SubtitleCue(index: 1, start: 0, end: 1, text: "A"),
            SubtitleCue(index: 2, start: 2, end: 3, text: "B"),
            SubtitleCue(index: 3, start: 4, end: 5, text: "C")
        ]
        XCTAssertTrue(cache.inspect(cues, minimumDuration: 0.6, maximumCPS: 12, maximumLineLength: 40).isEmpty)
        cues[0].end = 10
        let findings = cache.inspect(Array(cues.reversed()), minimumDuration: 0.6, maximumCPS: 12, maximumLineLength: 40)
        XCTAssertEqual(findings.map(\.cueID), [cues[1].id, cues[2].id])
        XCTAssertTrue(findings.allSatisfy { $0.kind == .overlap })
        XCTAssertEqual(cache.parsedTextCount, 0)
        cues[0].end = 1
        XCTAssertTrue(cache.inspect(cues, minimumDuration: 0.6, maximumCPS: 12, maximumLineLength: 40).isEmpty)
    }

    func testCancelledScanDoesNotReplaceRetainedMetrics() async {
        let task = Task.detached {
            var cache = SubtitleQualityCache()
            let cue = SubtitleCue(index: 1, start: 0, end: 1, text: "A")
            _ = cache.inspect([cue], minimumDuration: 0.6, maximumCPS: 12, maximumLineLength: 40)
            withUnsafeCurrentTask { $0?.cancel() }
            let findings = cache.inspect([], minimumDuration: 0.6, maximumCPS: 12, maximumLineLength: 40)
            return (findings.isEmpty, cache.retainedTextCount)
        }
        let result = await task.value
        XCTAssertTrue(result.0)
        XCTAssertEqual(result.1, 1)
    }
}
