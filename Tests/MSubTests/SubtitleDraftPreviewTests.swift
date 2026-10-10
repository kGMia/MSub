import XCTest
@testable import MSub

@MainActor
final class SubtitleDraftPreviewTests: XCTestCase {
    func testDraftTokenTracksPersistedInputsAndNestedEdits() {
        var slot = FileSlot(url: URL(fileURLWithPath: "/tmp/draft.mp4"))
        slot.cues = [.init(index: 1, start: 0, end: 2, text: "Hello", words: [.init(text: "Hello", start: 0, end: 2)])]
        slot.originalCues = slot.cues
        var previous = SubtitleDraftChangeToken(slot)
        func check(_ slot: FileSlot) {
            let next = SubtitleDraftChangeToken(slot)
            XCTAssertNotEqual(next, previous)
            previous = next
        }
        slot.cues[0].words?[0].end = 1.5; check(slot)
        slot.cues[0].text = "New"; check(slot)
        slot.cues[0].start = 0.5; check(slot)
        slot.originalCues[0].text = "Original"; check(slot)
        slot.speakerColors["A"] = "#FF0000"; check(slot)
        slot.selectedCueID = slot.cues[0].id; check(slot)
        slot.duration = 10; check(slot)
        slot.outputFormat = .json; check(slot)
        slot.url = URL(fileURLWithPath: "/tmp/renamed.mp4"); check(slot)
        let copy = slot
        XCTAssertEqual(SubtitleDraftChangeToken(copy), previous)
        slot.cues = []; check(slot)
    }

    func testDraftTokenIgnoresTransientProgressButKeepsRecoveryProtection() {
        var slot = FileSlot(url: URL(fileURLWithPath: "/tmp/draft.mp4"))
        let initial = SubtitleDraftChangeToken(slot)
        slot.progress = 0.5
        slot.previewText = "Transient preview"
        slot.jobID = "job"
        slot.selectedCueID = nil
        slot.processingState = .previewing
        slot.duration = .nan
        XCTAssertEqual(SubtitleDraftChangeToken(slot), initial)
        slot.processingState = .transcribing
        let protected = SubtitleDraftChangeToken(slot)
        XCTAssertNotEqual(protected, initial)
        for state in [FileSlot.ProcessingState.transcribing, .failed, .cancelled] {
            slot.processingState = state
            XCTAssertEqual(SubtitleDraftChangeToken(slot), protected)
            XCTAssertTrue(SubtitleDraft(slot).preservePreviousContent)
        }
        slot.cues = [.init(index: 1, start: 0, end: 1, text: "Retained")]
        XCTAssertEqual(SubtitleDraftChangeToken(slot).preservePreviousContent, false)
        XCTAssertEqual(SubtitleDraft(slot).preservePreviousContent, false)
        let withContent = SubtitleDraftChangeToken(slot)
        slot.processingState = .done
        XCTAssertEqual(SubtitleDraftChangeToken(slot), withContent)
    }

    func testPreviewCacheInvalidatesForEditsFormatAndDocument() {
        let cache = SubtitlePreviewCache()
        let file = UUID()
        var revision = UUID()
        var cues = [SubtitleCue(index: 1, start: 1, end: 2, text: "Hello")]
        let first = cache.value(cues: cues, fileID: file, revision: revision, format: .srt)
        XCTAssertEqual(first, "1\n00:00:01,000 --> 00:00:02,000\nHello\n")
        XCTAssertEqual(cache.value(cues: cues, fileID: file, revision: revision, format: .srt), first)
        cues[0].text = "Edited"; revision = UUID()
        XCTAssertTrue(cache.value(cues: cues, fileID: file, revision: revision, format: .srt).contains("Edited"))
        XCTAssertEqual(cache.value(cues: cues, fileID: file, revision: revision, format: .txt), "Edited")
        cues[0].speaker = " A "; revision = UUID()
        XCTAssertEqual(cache.value(cues: cues, fileID: file, revision: revision, format: .txt), "A: Edited")
        XCTAssertEqual(cache.value(cues: [], fileID: UUID(), revision: revision, format: .txt), "")
        XCTAssertEqual(cache.value(cues: cues, fileID: file, revision: revision, format: .txt), "A: Edited")
    }

    func testAllExportFormatsPreserveNormalizationAndBilingualMetadata() {
        var bilingual = SubtitleCue(index: 7, start: 1, end: 2, text: "", speaker: "Speaker A",
                                    words: [.init(text: "原文", start: 1, end: 2)])
        bilingual.setBilingual(.init(source: "<b>原文</b>", translation: "Translation 👋"))
        let early = SubtitleCue(index: 10, start: -1, end: 0, text: " first\nline ")
        let late = SubtitleCue(index: 11, start: 4, end: 4, text: "last")
        for cues in [[], [bilingual], [late, bilingual, early], SubtitleDocument.normalize([late, bilingual, early])] {
            for format in OutputFormat.allCases {
                XCTAssertEqual(SubtitleDocument.serialize(cues, format: format),
                               SubtitleDocument.serialize(SubtitleDocument.normalize(cues), format: format))
            }
        }
        let json = SubtitleDocument.serialize([bilingual], format: .json)
        let restored = SubtitleDocument.parse(json, format: .json)
        XCTAssertEqual(restored.first?.bilingual, bilingual.bilingual)
        XCTAssertEqual(restored.first?.words, bilingual.words)
        XCTAssertEqual(restored.first?.speaker, "Speaker A")
    }
}
