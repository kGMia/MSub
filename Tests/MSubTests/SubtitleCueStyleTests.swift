import XCTest
@testable import MSub

final class SubtitleCueStyleTests: XCTestCase {
    func testTranslationStyleKeepsSourceAlignmentAndPersistence() throws {
        var cue = SubtitleCue(index: 1, start: 1, end: 3, text: "", confidence: 0.9, speaker: "A",
                              words: [.init(text: "你好", start: 1.1, end: 2)])
        cue.setBilingual(.init(source: "你好", translation: "Hello\nworld", translationFirst: true))
        let styled = SubtitleCueStyle.applying(.toggleTag("b"), to: cue, scope: .translation)
        XCTAssertEqual(styled.bilingualText?.source, "你好")
        XCTAssertEqual(styled.bilingualText?.translation, "<b>Hello\nworld</b>")
        XCTAssertEqual(styled.text, "<b>Hello\nworld</b>\n你好")
        XCTAssertEqual(styled.words, cue.words)
        XCTAssertEqual(styled.id, cue.id)
        XCTAssertEqual(styled.start, cue.start)
        XCTAssertEqual(styled.end, cue.end)
        XCTAssertEqual(styled.confidence, cue.confidence)
        XCTAssertEqual(styled.speaker, cue.speaker)
        let restored = try JSONDecoder().decode(SubtitleCue.self, from: JSONEncoder().encode(styled))
        XCTAssertEqual(restored, styled)
        XCTAssertEqual(SubtitleCueStyle.applying(.clear, to: styled, scope: .translation), cue)
    }

    func testMixedLanesToggleTogetherAndEmptyTranslationStaysEmpty() {
        var cue = SubtitleCue(index: 1, start: 0, end: 1, text: "")
        cue.setBilingual(.init(source: "<i>原文</i>", translation: "translation"))
        let styled = SubtitleCueStyle.applying(.toggleTag("i"), to: cue)
        XCTAssertEqual(styled.bilingualText?.source, "<i>原文</i>")
        XCTAssertEqual(styled.bilingualText?.translation, "<i>translation</i>")
        XCTAssertTrue(SubtitleCueStyle.hasTag("i", in: styled, scope: .all))
        let toggled = SubtitleCueStyle.applying(.toggleTag("i"), to: styled)
        XCTAssertEqual(toggled.bilingualText?.source, "原文")
        XCTAssertEqual(toggled.bilingualText?.translation, "translation")
        cue.setBilingual(.init(source: "原文", translation: ""))
        XCTAssertEqual(SubtitleCueStyle.applying(.toggleTag("b"), to: cue, scope: .translation), cue)
        XCTAssertEqual(SubtitleCueStyle.applying(.color("#FF0000"), to: cue).bilingualText?.translation, "")
        cue.setBilingual(.init(source: "<b>一</b>\n<b>二</b>", translation: "one two"))
        let mergedStyle = SubtitleCueStyle.applying(.toggleTag("b"), to: cue, scope: .source)
        XCTAssertEqual(mergedStyle.bilingualText?.source, "<b><b>一</b>\n<b>二</b></b>")
        XCTAssertEqual(SubtitleCueStyle.applying(.toggleTag("b"), to: mergedStyle, scope: .source), cue)
    }

    func testSpeakerRecolorKeepsBothLanesAndPlainTextStaysPlain() {
        var cue = SubtitleCue(index: 1, start: 0, end: 1, text: "")
        cue.setBilingual(.init(source: "<font color=\"#000000\">原文</font>", translation: "<u>translation</u>"))
        let styled = SubtitleCueStyle.applying(.color("#FF0000"), to: cue)
        XCTAssertEqual(styled.bilingualText?.source, "<font color=\"#FF0000\">原文</font>")
        XCTAssertEqual(styled.bilingualText?.translation, "<font color=\"#FF0000\"><u>translation</u></font>")
        XCTAssertEqual(SubtitleCueStyle.applying(.color("#FF0000"), to: styled), styled)
        let sourceCleared = SubtitleCueStyle.applying(.clear, to: styled, scope: .source)
        XCTAssertEqual(sourceCleared.bilingualText?.source, "原文")
        XCTAssertEqual(sourceCleared.bilingualText?.translation, styled.bilingualText?.translation)
        let plain = SubtitleCue(index: 1, start: 0, end: 1, text: "你好\nHello")
        XCTAssertEqual(SubtitleCueStyle.applying(.toggleTag("b"), to: plain, scope: .translation), plain)
        XCTAssertNil(SubtitleCueStyle.applying(.toggleTag("b"), to: plain).bilingualText)
    }
}
