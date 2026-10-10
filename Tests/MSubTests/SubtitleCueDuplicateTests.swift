import XCTest
@testable import MSub

final class SubtitleCueDuplicateTests: XCTestCase {
    func testBilingualCopySurvivesPersistenceAndIndependentEditing() throws {
        var source = SubtitleCue(index: 2, start: 1, end: 3, text: "", confidence: 0.9, speaker: "A",
                                 words: [.init(text: "你好", start: 1.2, end: 2.5)])
        source.setBilingual(.init(source: "<font color=\"#FF0000\">你好</font>",
                                  translation: "Hello\nworld", translationFirst: true))
        let copy = source.duplicatedAfterEnd()
        XCTAssertNotEqual(copy.id, source.id)
        XCTAssertEqual(copy.index, 3)
        XCTAssertEqual(copy.start, 3)
        XCTAssertEqual(copy.end, 5)
        XCTAssertEqual(copy.text, source.text)
        XCTAssertEqual(copy.bilingualText, source.bilingualText)
        XCTAssertEqual(copy.speaker, source.speaker)
        XCTAssertEqual(copy.confidence, source.confidence)
        XCTAssertNil(copy.words)
        XCTAssertEqual(source.words?.count, 1)

        var restored = try JSONDecoder().decode(SubtitleCue.self, from: JSONEncoder().encode(copy))
        XCTAssertEqual(restored, copy)
        var fields = try XCTUnwrap(restored.bilingualText)
        fields.translation = "Hi"
        restored.setBilingual(fields)
        XCTAssertEqual(restored.translationSourceText, source.translationSourceText)
        XCTAssertEqual(restored.text, "Hi\n" + source.translationSourceText)
        XCTAssertEqual(source.bilingualText?.translation, "Hello\nworld")
    }

    func testPlainCopyKeepsTextAndMinimumDurationWithoutInventingLanguages() {
        let source = SubtitleCue(index: 1, start: 0, end: 0.1, text: "你好\nHello")
        let copy = source.duplicatedAfterEnd()
        XCTAssertEqual(copy.text, source.text)
        XCTAssertEqual(copy.start, 0.1)
        XCTAssertEqual(copy.end, 0.6)
        XCTAssertNil(copy.bilingualText)
        XCTAssertNil(copy.words)
    }
}
