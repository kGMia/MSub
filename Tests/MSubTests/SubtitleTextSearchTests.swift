import XCTest
@testable import MSub

final class SubtitleTextSearchTests: XCTestCase {
    func testTranslationOnlyPreservesOriginalAndWordTimes() {
        var cue = SubtitleCue(index: 1, start: 1, end: 2, text: "", words: [.init(text: "你好", start: 1, end: 2)])
        cue.setBilingual(.init(source: "你好", translation: "Hello hello", translationFirst: true))
        let search = SubtitleTextSearch(query: "hello", replacement: "Hi", matchCase: false, scope: .translation)
        XCTAssertEqual(search.count(in: cue), 2)
        let result = search.replacing(in: cue, all: true)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.cue.bilingualText?.source, "你好")
        XCTAssertEqual(result.cue.bilingualText?.translation, "Hi Hi")
        XCTAssertEqual(result.cue.bilingualText?.translationFirst, true)
        XCTAssertEqual(result.cue.words, cue.words)
        XCTAssertEqual(result.cue.start, cue.start)
        XCTAssertEqual(result.cue.id, cue.id)
        let plain = SubtitleCue(index: 2, start: 2, end: 3, text: "hello")
        XCTAssertEqual(search.count(in: plain), 0)
        XCTAssertEqual(search.replacing(in: plain, all: true).cue, plain)
    }

    func testFirstFollowsDisplayOrderAndSourceEditsClearWordTimes() {
        var cue = SubtitleCue(index: 1, start: 0, end: 1, text: "", words: [.init(text: "same", start: 0, end: 1)])
        cue.setBilingual(.init(source: "same", translation: "same", translationFirst: true))
        let search = SubtitleTextSearch(query: "same", replacement: "new", matchCase: true, scope: .all)
        let first = search.replacing(in: cue, all: false)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.cue.bilingualText?.source, "same")
        XCTAssertEqual(first.cue.bilingualText?.translation, "new")
        XCTAssertEqual(first.cue.words, cue.words)
        let all = search.replacing(in: cue, all: true)
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.cue.bilingualText?.source, "new")
        XCTAssertNil(all.cue.words)
        let source = SubtitleTextSearch(query: "same", replacement: "only source", matchCase: true, scope: .source)
        XCTAssertEqual(source.replacing(in: cue, all: true).cue.bilingualText?.translation, "same")
    }

    func testUnicodeAndInsertedTextAreNotResearched() {
        let cue = SubtitleCue(index: 1, start: 0, end: 1, text: "café CAFE 👩🏽‍💻 👩🏽‍💻")
        let accent = SubtitleTextSearch(query: "cafe", replacement: "cafe cafe", matchCase: false, scope: .all)
        XCTAssertEqual(accent.replacing(in: cue, all: true).count, 2)
        XCTAssertEqual(accent.replacing(in: cue, all: true).cue.text, "cafe cafe cafe cafe 👩🏽‍💻 👩🏽‍💻")
        let emoji = SubtitleTextSearch(query: "👩🏽‍💻", replacement: "", matchCase: true, scope: .all)
        XCTAssertEqual(emoji.replacing(in: cue, all: true).cue.text, "café CAFE  ")
        XCTAssertEqual(SubtitleTextSearch(query: "CAFE", replacement: "x", matchCase: true, scope: .all).count(in: cue), 1)
    }

    func testEmptyQueryAndCrossFieldMatchAreNoOps() {
        var cue = SubtitleCue(index: 1, start: 0, end: 1, text: "")
        cue.setBilingual(.init(source: "first", translation: "second"))
        for query in ["", "first\nsecond"] {
            let search = SubtitleTextSearch(query: query, replacement: "x", matchCase: true, scope: .all)
            XCTAssertEqual(search.count(in: cue), 0)
            XCTAssertEqual(search.replacing(in: cue, all: true).cue, cue)
        }
    }
}
