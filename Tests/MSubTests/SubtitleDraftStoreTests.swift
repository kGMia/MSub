import XCTest
@testable import MSub

@MainActor
final class SubtitleDraftStoreTests: XCTestCase {
    func testFlushPersistsLatestEditsAndRestoresWithoutJobState() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "session.json")
        var slot = FileSlot(url: URL(fileURLWithPath: "/missing/source.mp4"))
        slot.cues = [SubtitleCue(index: 1, start: 1, end: 2, text: "before")]
        slot.originalCues = slot.cues
        slot.speakerColors = ["Speaker 1": "#FF0000"]
        slot.jobID = "old-job"
        slot.processingState = .transcribing
        let store = SubtitleDraftStore(file: file)
        store.schedule([SubtitleDraft(slot)])
        slot.cues[0].text = "after"
        store.flush([SubtitleDraft(slot)])
        let recovered = SubtitleDraftStore(file: file)
        let document = try XCTUnwrap(recovered.resumeRecovery().first)
        let restored = document.restoredSlot()
        XCTAssertEqual(restored.cues[0].text, "after")
        XCTAssertEqual(restored.originalCues[0].text, "before")
        XCTAssertEqual(restored.speakerColors, slot.speakerColors)
        XCTAssertNil(restored.jobID)
        XCTAssertEqual(restored.processingState, .idle)
    }

    func testFailedRecognitionPreservesPreviousEditingDraft() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "session.json")
        var slot = FileSlot(url: URL(fileURLWithPath: "/missing/source.mp4"))
        slot.cues = [SubtitleCue(index: 1, start: 0, end: 1, text: "manual edit")]
        let store = SubtitleDraftStore(file: file)
        store.schedule([SubtitleDraft(slot)])
        slot.cues = []
        slot.processingState = .transcribing
        store.schedule([SubtitleDraft(slot)])
        slot.processingState = .failed
        store.flush([SubtitleDraft(slot)])
        XCTAssertEqual(SubtitleDraftStore(file: file).recoverable.first?.cues.first?.text, "manual edit")
    }

    func testPendingRecoveryAndCorruptArchiveAreNotOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "session.json")
        let store = SubtitleDraftStore(file: file)
        store.flush([SubtitleDraft(FileSlot(url: URL(fileURLWithPath: "/missing/source.mp4")))])
        let original = try Data(contentsOf: file)
        let recovering = SubtitleDraftStore(file: file)
        recovering.schedule([])
        recovering.flush([])
        XCTAssertEqual(try Data(contentsOf: file), original)
        let corrupt = Data("not JSON".utf8)
        try corrupt.write(to: file)
        let invalid = SubtitleDraftStore(file: file)
        invalid.flush([])
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
        XCTAssertNotNil(invalid.error)
    }
}
