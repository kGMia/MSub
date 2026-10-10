import XCTest
@testable import MSub

final class SubtitleCueSplitTests: XCTestCase {
    func testBilingualBoundariesPreserveIdentityOrderAndStyle() throws {
        var cue = SubtitleCue(index: 3, start: 1, end: 5, text: "", confidence: 0.8, speaker: "A")
        cue.setBilingual(.init(source: "<b>你好世界</b>", translation: "<font color=\"#ff0000\">Hello world</font>", translationFirst: true))
        let (a, b) = try XCTUnwrap(SubtitleCueSplit.split(cue, at: 3, sourceOffset: 2, translationOffset: 6))
        XCTAssertEqual(a.id, cue.id)
        XCTAssertNotEqual(b.id, cue.id)
        XCTAssertEqual(a.start, 1)
        XCTAssertEqual(a.end, b.start)
        XCTAssertEqual(b.end, 5)
        XCTAssertEqual(b.index, 4)
        XCTAssertEqual(a.bilingualText?.source, "<b>你好</b>")
        XCTAssertEqual(b.bilingualText?.source, "<b>世界</b>")
        XCTAssertEqual(a.bilingualText?.translation, "<font color=\"#ff0000\">Hello </font>")
        XCTAssertEqual(b.bilingualText?.translation, "<font color=\"#ff0000\">world</font>")
        XCTAssertEqual(b.bilingualText?.translationFirst, true)
        XCTAssertEqual(a.speaker, "A")
        XCTAssertEqual(b.confidence, 0.8)
        XCTAssertNil(SubtitleCueSplit.split(cue, at: 3, sourceOffset: 2))
    }

    func testEmptyTranslationAndUnicodeBoundaries() throws {
        var cue = SubtitleCue(index: 1, start: 0, end: 2, text: "")
        cue.setBilingual(.init(source: "👨‍👩‍👧‍👦e\u{301}好", translation: ""))
        let (a, b) = try XCTUnwrap(SubtitleCueSplit.split(cue, at: 1, sourceOffset: 1))
        XCTAssertEqual(a.bilingualText?.source, "👨‍👩‍👧‍👦")
        XCTAssertEqual(b.bilingualText?.source, "e\u{301}好")
        XCTAssertEqual(b.bilingualText?.translation, "")
        let formatted = try XCTUnwrap(SubtitleCueSplit.FormattedText("<b>A<i>👩🏽‍💻B</i></b>"))
        let parts = try XCTUnwrap(formatted.split(at: 2))
        XCTAssertEqual(SubtitleCueSplit.FormattedText(parts.0)?.plain, "A👩🏽‍💻")
        XCTAssertEqual(SubtitleCueSplit.FormattedText(parts.1)?.plain, "B")
        let combining = try XCTUnwrap(SubtitleCueSplit.FormattedText("<b>e</b>\u{301}x"))
        let combinedParts = try XCTUnwrap(combining.split(at: 1))
        XCTAssertEqual(SubtitleCueSplit.FormattedText(combinedParts.0)?.plain, "e\u{301}")
        XCTAssertEqual(SubtitleCueSplit.FormattedText(combinedParts.1)?.plain, "x")
    }

    func testInvalidTimesOffsetsEmptyResultsAndMarkupAreRejected() {
        let cue = SubtitleCue(index: 1, start: 1, end: 2, text: "AB")
        for time in [Double.nan, .infinity, 0, 1, 1.02, 1.99, 2, 3] {
            XCTAssertNil(SubtitleCueSplit.split(cue, at: time, sourceOffset: 1))
        }
        for offset in [-1, 0, 2, 3] {
            XCTAssertNil(SubtitleCueSplit.split(cue, at: 1.5, sourceOffset: offset))
        }
        for text in ["<b>AB", "<b>A</i>B", "<ruby>AB</ruby>", "{\\i1}AB"] {
            XCTAssertNil(SubtitleCueSplit.FormattedText(text))
        }
        XCTAssertNotNil(SubtitleCueSplit.split(cue, at: 1.05, sourceOffset: 1))
        XCTAssertNotNil(SubtitleCueSplit.split(cue, at: 1.95, sourceOffset: 1))
    }

    func testWordSuggestionAndAlignmentOnlyWhenMatchingBoundary() throws {
        var cue = SubtitleCue(index: 1, start: 0, end: 3, text: "one two", words: [
            .init(text: "one", start: 0.2, end: 1), .init(text: "two", start: 2, end: 2.8)
        ])
        XCTAssertEqual(SubtitleCueSplit.suggestedSourceOffset(cue, at: 1.5), 3)
        let (a, b) = try XCTUnwrap(SubtitleCueSplit.split(cue, at: 1.5, sourceOffset: 3))
        XCTAssertEqual(a.words?.map(\.text), ["one"])
        XCTAssertEqual(b.words?.map(\.text), ["two"])
        let different = try XCTUnwrap(SubtitleCueSplit.split(cue, at: 1.5, sourceOffset: 2))
        XCTAssertNil(different.0.words)
        XCTAssertNil(different.1.words)
        XCTAssertNil(SubtitleCueSplit.suggestedSourceOffset(cue, at: 0.5))
        cue.words?.removeLast()
        XCTAssertNil(SubtitleCueSplit.suggestedSourceOffset(cue, at: 1.5))
        cue.words = [.init(text: "one", start: .nan, end: 1)]
        XCTAssertNil(SubtitleCueSplit.suggestedSourceOffset(cue, at: 1.5))
    }

    func testWholeTranslationCanStayOnEitherSideWithoutGuessing() throws {
        var cue = SubtitleCue(index: 1, start: 0, end: 2, text: "")
        cue.setBilingual(.init(source: "你好", translation: "Hello"))
        let first = try XCTUnwrap(SubtitleCueSplit.split(cue, at: 1, sourceOffset: 1, translationOffset: 5))
        XCTAssertEqual(first.0.bilingualText?.translation, "Hello")
        XCTAssertEqual(first.1.bilingualText?.translation, "")
        let second = try XCTUnwrap(SubtitleCueSplit.split(cue, at: 1, sourceOffset: 1, translationOffset: 0))
        XCTAssertEqual(second.0.bilingualText?.translation, "")
        XCTAssertEqual(second.1.bilingualText?.translation, "Hello")
    }
}
