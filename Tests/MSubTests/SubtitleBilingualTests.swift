import XCTest
@testable import MSub

final class SubtitleBilingualTests: XCTestCase {
    func testRepeatedTranslationUsesSourceAndProtectsConcurrentEdits() {
        var cue = SubtitleCue(index: 1, start: 1, end: 2, text: "你好")
        cue.setBilingual(.init(source: "你好", translation: "Hello"))
        XCTAssertEqual(cue.translationSourceText, "你好")
        let updated = SubtitleTranslationEdits.apply(snapshot: [cue], translated: ["こんにちは"], current: [cue], mode: .bilingual)
        XCTAssertEqual(updated[0].text, "你好\nこんにちは")
        var edited = cue
        edited.text = "My edit"
        XCTAssertEqual(SubtitleTranslationEdits.apply(snapshot: [cue], translated: ["New"], current: [edited], mode: .bilingual), [edited])
        XCTAssertEqual(edited.bilingualText, nil)
        let inserted = SubtitleCue(index: 2, start: 3, end: 4, text: "Inserted")
        let reordered = SubtitleTranslationEdits.apply(snapshot: [cue], translated: ["New"], current: [inserted, cue], mode: .bilingual)
        XCTAssertEqual(reordered[0], inserted)
        XCTAssertEqual(reordered[1].bilingualText?.translation, "New")
    }

    func testDraftAndJSONRoundTripAndLegacyDecoding() throws {
        var cue = SubtitleCue(index: 1, start: 1, end: 2, text: "original")
        cue.setBilingual(.init(source: " first\nsecond ", translation: "訳文", translationFirst: true))
        let decoded = try JSONDecoder().decode(SubtitleCue.self, from: JSONEncoder().encode(cue))
        XCTAssertEqual(decoded, cue)
        let imported = SubtitleDocument.parse(SubtitleDocument.serialize([cue], format: .json), format: .json)
        XCTAssertEqual(imported.first?.bilingualText, cue.bilingualText)
        XCTAssertEqual(imported.first?.text, cue.text)
        let old = "{\"segments\":[{\"index\":1,\"start\":0,\"end\":1,\"text\":\"first\\nsecond\"}],\"text\":\"first\\nsecond\"}"
        XCTAssertEqual(SubtitleDocument.parse(old, format: .json).first?.bilingualText, nil)
    }

    func testSingleLanguageExportPreservesTimingAndFallsBackForUntranslatedCues() {
        var cue = SubtitleCue(index: 1, start: 1, end: 2, text: "原文", words: [.init(text: "原文", start: 1, end: 2)])
        cue.setBilingual(.init(source: "原文", translation: "Translation"))
        let plain = SubtitleCue(index: 2, start: 3, end: 4, text: "Not translated")
        let result = SubtitleDocument.monolingualCues([cue, plain], translated: true)
        XCTAssertEqual(result.map(\.text), ["Translation", "Not translated"])
        XCTAssertEqual(result[0].id, cue.id)
        XCTAssertEqual(result[0].start, cue.start)
        XCTAssertEqual(result[0].end, cue.end)
        XCTAssertEqual(result[0].words, nil)
        XCTAssertEqual(result[0].bilingualText, nil)
        XCTAssertEqual(SubtitleDocument.monolingualCues([cue], translated: false)[0].words, cue.words)
        XCTAssertEqual(cue.text, "原文\nTranslation")
    }
}
