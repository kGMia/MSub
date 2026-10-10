import XCTest
@testable import MSub

final class SubtitleCueMergeTests: XCTestCase {
    func testBilingualMergePreservesFieldsOrderIdentityAndTiming() throws {
        var first = SubtitleCue(index: 2, start: 1, end: 2, text: "", confidence: 0.9, speaker: "A")
        first.setBilingual(.init(source: "你好\n", translation: "Hello", translationFirst: true))
        var second = SubtitleCue(index: 3, start: 3, end: 4, text: "", confidence: 0.7, speaker: "A")
        second.setBilingual(.init(source: "世界", translation: "World"))
        let merged = try XCTUnwrap(SubtitleCueMerge.merged(first, second))
        XCTAssertEqual(merged.id, first.id)
        XCTAssertEqual(merged.start, 1)
        XCTAssertEqual(merged.end, 4)
        XCTAssertEqual(merged.confidence, 0.7)
        XCTAssertEqual(merged.bilingualText?.source, "你好\n世界")
        XCTAssertEqual(merged.bilingualText?.translation, "Hello\nWorld")
        XCTAssertEqual(merged.text, "Hello\nWorld\n你好\n世界")
        XCTAssertEqual(first.end, 2)
        XCTAssertEqual(second.text, "世界\nWorld")
    }

    func testPlainMergePreservesCompleteWordTimesAndClearsPartialAlignment() throws {
        let first = SubtitleCue(index: 1, start: 0, end: 2, text: "one", words: [.init(text: "one", start: 0.2, end: 1)])
        var second = SubtitleCue(index: 2, start: 1.5, end: 3, text: "two", words: [.init(text: "two", start: 2, end: 2.5)])
        let merged = try XCTUnwrap(SubtitleCueMerge.merged(first, second))
        XCTAssertEqual(merged.text, "one\ntwo")
        XCTAssertEqual(merged.end, 3)
        XCTAssertEqual(merged.words, first.words! + second.words!)
        second.words = nil
        XCTAssertNil(SubtitleCueMerge.merged(first, second)?.words)
    }

    func testIncompatibleOrInvalidCuesAreNotMerged() {
        let first = SubtitleCue(index: 1, start: 1, end: 2, text: "First", speaker: "A")
        var second = SubtitleCue(index: 2, start: 2, end: 3, text: "Second", speaker: "B")
        XCTAssertNil(SubtitleCueMerge.merged(first, second))
        second.speaker = "A"
        second.setBilingual(.init(source: "Second", translation: "第二"))
        XCTAssertNil(SubtitleCueMerge.merged(first, second))
        second.bilingual = nil
        second.start = .nan
        XCTAssertNil(SubtitleCueMerge.merged(first, second))
        XCTAssertNil(SubtitleCueMerge.merged(first, first))
    }
}
