import XCTest
@testable import MSub

final class SubtitleTimingWriteTests: XCTestCase {
    func testRepeatedSnappedPositionWritesOnceAndPreservesMetadata() {
        var cue = SubtitleCue(index: 1, start: 1, end: 2, text: "", confidence: 0.8, speaker: "A")
        cue.setBilingual(.init(source: "Hello", translation: "你好"))
        cue.words = [.init(text: "Hello", start: 1, end: 2)]
        let before = cue
        var writes = 0
        for _ in 0..<100 {
            if let updated = SubtitleCueTimingUpdate.updated(cue, start: 3, end: 4) {
                cue = updated
                writes += 1
            }
        }
        XCTAssertEqual(writes, 1)
        XCTAssertEqual(cue.id, before.id)
        XCTAssertEqual(cue.text, before.text)
        XCTAssertEqual(cue.words, before.words)
        XCTAssertEqual(cue.bilingual, before.bilingual)
        XCTAssertEqual(cue.confidence, before.confidence)
        XCTAssertEqual(cue.speaker, before.speaker)
        XCTAssertEqual(cue.start, 3)
        XCTAssertEqual(cue.end, 4)
    }

    func testUnchangedHandleAndFinitePrecisionUpdates() {
        let cue = SubtitleCue(index: 1, start: 1, end: 2, text: "x")
        XCTAssertNil(SubtitleCueTimingUpdate.updated(cue, start: 1, end: 2))
        XCTAssertEqual(SubtitleCueTimingUpdate.updated(cue, start: 1.nextUp, end: 2)?.start, 1.nextUp)
        XCTAssertEqual(SubtitleCueTimingUpdate.updated(cue, start: 1, end: 2.nextUp)?.end, 2.nextUp)
        XCTAssertNil(SubtitleCueTimingUpdate.updated(cue, start: .nan, end: 2))
        XCTAssertNil(SubtitleCueTimingUpdate.updated(cue, start: 1, end: .infinity))
    }

    func testNormalizationFastPathAndFallbackMatchOriginal() {
        let ordered = (0..<1000).map {
            SubtitleCue(index: $0 + 1, start: Double($0), end: Double($0 + 1), text: "x")
        }
        XCTAssertNil(SubtitleDocument.normalizedIfNeeded(ordered))
        XCTAssertNil(SubtitleDocument.normalizedIfNeeded([]))
        var reordered = ordered
        reordered.swapAt(0, 50)
        var invalid = Array(ordered.prefix(3))
        invalid[0].start = -1
        invalid[1].end = invalid[1].start
        invalid[2].index = 20
        var tied = Array(ordered.prefix(3))
        tied[0].start = 1
        tied[0].index = 3
        tied[1].index = 1
        for cues in [reordered, invalid, tied] {
            let normalized = SubtitleDocument.normalizedIfNeeded(cues)
            XCTAssertEqual(normalized, SubtitleDocument.normalize(cues))
            XCTAssertNil(SubtitleDocument.normalizedIfNeeded(normalized!))
        }
    }

    func testTimeOnlyUpdateCanBeRestoredWithoutChangingOtherCue() {
        let a = SubtitleCue(index: 1, start: 0, end: 1, text: "a")
        let b = SubtitleCue(index: 2, start: 1, end: 2, text: "b")
        let original = [a, b]
        var cues = original
        cues[0] = SubtitleCueTimingUpdate.updated(a, start: 2, end: 3)!
        cues = SubtitleDocument.normalizedIfNeeded(cues) ?? cues
        XCTAssertEqual(cues.map(\.id), [b.id, a.id])
        XCTAssertEqual(cues[0].start, b.start)
        XCTAssertEqual(cues[0].text, b.text)
        XCTAssertEqual(cues[1].index, 2)
        cues = original
        XCTAssertNil(SubtitleCueTimingUpdate.updated(cues[0], start: 0, end: 1))
        XCTAssertNil(SubtitleDocument.normalizedIfNeeded(cues))
    }
}
