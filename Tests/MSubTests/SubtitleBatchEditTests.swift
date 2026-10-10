import XCTest
@testable import MSub

final class SubtitleBatchEditTests: XCTestCase {
    func testShiftPreservesDurationIdentityAndWordTimesAndRejectsWholeInvalidBatch() throws {
        let a = SubtitleCue(index: 1, start: 1, end: 3, text: "one", words: [.init(text: "one", start: 1.2, end: 2.5)])
        let b = SubtitleCue(index: 2, start: 5, end: 7, text: "two")
        let shifted = try XCTUnwrap(SubtitleBatchEdit.applying(.shift(0.5), to: [a, b]))
        XCTAssertEqual(shifted.map(\.id), [a.id, b.id])
        XCTAssertEqual(shifted.map(\.duration), [2, 2])
        XCTAssertEqual(shifted[0].words?.first?.start, 1.7)
        XCTAssertEqual(shifted[0].words?.first?.end, 3)
        XCTAssertEqual(shifted[1].start, 5.5)
        XCTAssertNil(SubtitleBatchEdit.applying(.shift(-2), to: [a, b]))
        XCTAssertNil(SubtitleBatchEdit.applying(.shift(.nan), to: [a, b]))
        XCTAssertNil(SubtitleBatchEdit.applying(.shift(.infinity), to: [a]))
        XCTAssertEqual(a.start, 1)
        XCTAssertEqual(SubtitleBatchEdit.applying(.shift(0), to: [a, b]), [a, b])
    }

    func testMixedStylesAddUniformlyAndRespectIndependentLanguages() throws {
        var a = SubtitleCue(index: 1, start: 0, end: 1, text: "")
        a.setBilingual(.init(source: "<b>原文</b>", translation: "Translation", translationFirst: true))
        let b = SubtitleCue(index: 2, start: 1, end: 2, text: "Plain")
        let changed = try XCTUnwrap(SubtitleBatchEdit.applying(.addTag("b", .all), to: [a, b]))
        XCTAssertEqual(changed[0].bilingualText?.source, "<b>原文</b>")
        XCTAssertEqual(changed[0].bilingualText?.translation, "<b>Translation</b>")
        XCTAssertEqual(changed[0].bilingualText?.translationFirst, true)
        XCTAssertEqual(changed[1].text, "<b>Plain</b>")
        XCTAssertEqual(SubtitleBatchEdit.applying(.addTag("b", .all), to: changed), changed)
        let cleared = try XCTUnwrap(SubtitleBatchEdit.applying(.clearStyle(.translation), to: changed))
        XCTAssertEqual(cleared[0].bilingualText?.source, "<b>原文</b>")
        XCTAssertEqual(cleared[0].bilingualText?.translation, "Translation")
        XCTAssertEqual(cleared[1], changed[1])
    }

    func testSpeakerAssignmentPreservesBilingualMetadataAndUsesStoredColor() throws {
        var a = SubtitleCue(index: 1, start: 0, end: 1, text: "", words: [.init(text: "原文", start: 0, end: 1)])
        a.setBilingual(.init(source: "原文", translation: "", translationFirst: true))
        let assigned = try XCTUnwrap(SubtitleBatchEdit.applying(.speaker(" A \n"), to: [a], speakerColors: ["A": "#FF0000"]))[0]
        XCTAssertEqual(assigned.speaker, "A")
        XCTAssertEqual(assigned.bilingualText?.source, "<font color=\"#FF0000\">原文</font>")
        XCTAssertEqual(assigned.bilingualText?.translation, "")
        XCTAssertEqual(assigned.words, a.words)
        XCTAssertEqual(assigned.id, a.id)
        let cleared = try XCTUnwrap(SubtitleBatchEdit.applying(.speaker("  "), to: [assigned]))[0]
        XCTAssertNil(cleared.speaker)
        XCTAssertEqual(cleared.text, assigned.text)
    }

    func testStaleSelectionIsRejectedAndUnselectedEditsArePreserved() throws {
        let a = SubtitleCue(index: 1, start: 0, end: 1, text: "a")
        var b = SubtitleCue(index: 2, start: 1, end: 2, text: "b")
        let updates = try XCTUnwrap(SubtitleBatchEdit.applying(.speaker("A"), to: [a]))
        b.text = "Unselected edit"
        let result = try XCTUnwrap(SubtitleBatchEdit.replacing([a], with: updates, in: [a, b]))
        XCTAssertEqual(result[1], b)
        XCTAssertEqual(result[0].speaker, "A")
        var edited = a
        edited.text = "Selected edit"
        XCTAssertNil(SubtitleBatchEdit.replacing([a], with: updates, in: [edited, b]))
        XCTAssertNil(SubtitleBatchEdit.replacing([a], with: updates, in: [b]))
        XCTAssertNil(SubtitleBatchEdit.replacing([a], with: [b], in: [a, b]))
        XCTAssertNil(SubtitleBatchEdit.replacing([a], with: updates, in: [a, a]))
    }

    func testInvalidWordMetadataClearsOnlyOnActualTimeShift() throws {
        let cue = SubtitleCue(index: 1, start: 1, end: 2, text: "a", words: [.init(text: "a", start: 0, end: 4)])
        XCTAssertEqual(SubtitleBatchEdit.applying(.shift(0), to: [cue]), [cue])
        let shifted = try XCTUnwrap(SubtitleBatchEdit.applying(.shift(1), to: [cue]))[0]
        XCTAssertNil(shifted.words)
        XCTAssertEqual(shifted.text, cue.text)
        XCTAssertEqual(shifted.start, 2)
        XCTAssertEqual(shifted.end, 3)
    }
}
