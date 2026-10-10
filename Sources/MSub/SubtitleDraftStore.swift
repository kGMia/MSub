import Foundation
import SwiftUI

/// Observe persisted inputs without comparing subtitle text and word arrays on
/// each SwiftUI refresh. Cue revisions include nested value-type edits.
struct SubtitleDraftChangeToken: Equatable {
    let fileID: UUID
    let url: URL
    let cuesRevision: UUID
    let originalCuesRevision: UUID
    let speakerColors: [String: String]
    let selectedCueID: UUID?
    let duration: Double
    let outputFormat: String
    let preservePreviousContent: Bool

    init(_ slot: FileSlot) {
        fileID = slot.id
        url = slot.url
        cuesRevision = slot.cuesRevision
        originalCuesRevision = slot.originalCuesRevision
        speakerColors = slot.speakerColors
        selectedCueID = slot.selectedCueID
        duration = slot.duration.isFinite ? slot.duration : 0
        outputFormat = slot.outputFormat.rawValue
        preservePreviousContent = SubtitleDraft.shouldPreserveContent(slot)
    }
}

/// Editing drafts are independent of exported subtitle files and backend jobs.
struct SubtitleDraft: Codable, Equatable, Sendable {
    var fileID: UUID
    var preservePreviousContent: Bool
    var url: URL
    var cues: [SubtitleCue]
    var originalCues: [SubtitleCue]
    var speakerColors: [String: String]
    var selectedCueID: UUID?
    var duration: Double
    var outputFormat: String

    init(_ slot: FileSlot) {
        fileID = slot.id
        preservePreviousContent = Self.shouldPreserveContent(slot)
        url = slot.url
        cues = slot.cues
        originalCues = slot.originalCues
        speakerColors = slot.speakerColors
        selectedCueID = slot.selectedCueID
        duration = slot.duration.isFinite ? slot.duration : 0
        outputFormat = slot.outputFormat.rawValue
    }

    static func shouldPreserveContent(_ slot: FileSlot) -> Bool {
        slot.cues.isEmpty &&
            (slot.processingState == .transcribing || slot.processingState == .failed || slot.processingState == .cancelled)
    }

    private enum CodingKeys: String, CodingKey {
        case fileID, preservePreviousContent, url, cues, originalCues, speakerColors, selectedCueID, duration, outputFormat
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fileID = try values.decodeIfPresent(UUID.self, forKey: .fileID) ?? UUID()
        preservePreviousContent = try values.decodeIfPresent(Bool.self, forKey: .preservePreviousContent) ?? false
        url = try values.decode(URL.self, forKey: .url)
        cues = try values.decode([SubtitleCue].self, forKey: .cues)
        originalCues = try values.decode([SubtitleCue].self, forKey: .originalCues)
        speakerColors = try values.decode([String: String].self, forKey: .speakerColors)
        selectedCueID = try values.decodeIfPresent(UUID.self, forKey: .selectedCueID)
        duration = try values.decode(Double.self, forKey: .duration)
        outputFormat = try values.decode(String.self, forKey: .outputFormat)
    }

    @MainActor func restoredSlot() -> FileSlot {
        // Reuse Powerbox bookmarks already managed by the app. A missing media
        // file must not prevent recovering the user's subtitle text.
        let usable = FolderAuthorizationStore.shared.resolveFileForAccess(path: url.path) ?? url
        var slot = FileSlot(url: usable)
        slot.cues = cues
        slot.originalCues = originalCues
        slot.speakerColors = speakerColors
        slot.selectedCueID = cues.contains(where: { $0.id == selectedCueID }) ? selectedCueID : cues.first?.id
        slot.duration = duration
        slot.outputFormat = OutputFormat(rawValue: outputFormat) ?? .srt
        slot.previewText = SubtitleDocument.serialize(cues, format: slot.outputFormat)
        // Never restore a running job, temporary preview path, or stale backend ID.
        return slot
    }
}

@MainActor @Observable
final class SubtitleDraftStore {
    private struct Archive: Codable, Sendable {
        var version = 1
        var savedAt = Date()
        var documents: [SubtitleDraft]
    }

    private(set) var recoverable: [SubtitleDraft] = []
    private(set) var savedAt: Date?
    private(set) var error: String?
    private(set) var isSaving = false
    private var pending: [SubtitleDraft]?
    private var latest: [SubtitleDraft] = []
    private var debounce: Task<Void, Never>?
    private var revision = 0
    private var recoveryPending = false
    private var readableArchive = true
    private let file: URL
    private let io = DispatchQueue(label: "MSub.subtitle-drafts", qos: .utility)

    init(file: URL? = nil) {
        self.file = file ?? URL.applicationSupportDirectory
            .appending(path: "MSub/EditingDrafts/session.json")
        do {
            if FileManager.default.fileExists(atPath: self.file.path) {
                let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: self.file))
                guard archive.version == 1 else { throw CocoaError(.fileReadUnknown) }
                recoverable = archive.documents
                latest = archive.documents
                recoveryPending = !recoverable.isEmpty
            }
        } catch {
            // Preserve unreadable/newer drafts rather than replacing them silently.
            self.error = error.localizedDescription
            readableArchive = false
        }
    }

    func resumeRecovery() -> [SubtitleDraft] {
        recoveryPending = false
        let documents = recoverable
        recoverable = []
        return documents
    }

    func dismissRecovery() {
        recoveryPending = false
        recoverable = []
        if let pending { schedule(pending) }
    }

    func schedule(_ documents: [SubtitleDraft]) {
        guard readableArchive else { return }
        let documents = preservingInFlightEdits(documents)
        latest = documents
        pending = documents
        // Starting a new session doesn't overwrite the prior draft before the
        // user has had a chance to recover or dismiss it.
        guard !recoveryPending else { return }
        debounce?.cancel()
        revision += 1
        isSaving = true
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.enqueueSave(documents, revision: self.revision)
        }
    }

    private func enqueueSave(_ documents: [SubtitleDraft], revision: Int) {
        let file = file
        let archive = Archive(documents: documents)
        io.async { [weak self] in
            let failure: String?
            do { try Self.write(archive, to: file); failure = nil }
            catch { failure = error.localizedDescription }
            Task { @MainActor [weak self] in
                guard let self, self.revision == revision else { return }
                self.error = failure
                self.isSaving = false
                if failure == nil { self.savedAt = archive.savedAt }
            }
        }
    }

    /// Termination/disappearance drains queued writes, then persists the newest
    /// snapshot synchronously, so an older asynchronous save cannot win the race.
    func flush(_ documents: [SubtitleDraft]) {
        guard readableArchive, !recoveryPending else { return }
        debounce?.cancel()
        revision += 1
        let documents = preservingInFlightEdits(documents)
        latest = documents
        do {
            try io.sync { try Self.write(Archive(documents: documents), to: file) }
            savedAt = Date()
            error = nil
        } catch { self.error = error.localizedDescription }
        isSaving = false
    }

    private func preservingInFlightEdits(_ documents: [SubtitleDraft]) -> [SubtitleDraft] {
        let prior = Dictionary(uniqueKeysWithValues: latest.map { ($0.fileID, $0) })
        return documents.map { document in
            guard document.preservePreviousContent, document.cues.isEmpty,
                  let previous = prior[document.fileID], !previous.cues.isEmpty else { return document }
            return previous
        }
    }

    nonisolated private static func write(_ archive: Archive, to file: URL) throws {
        let data = try JSONEncoder().encode(archive)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
    }
}

/// Exposes only the active workspace's draft actions to the macOS File menu.
struct SubtitleDraftActions {
    let store: SubtitleDraftStore
    let canRestore: Bool
    let restore: @MainActor () -> Void
}

private struct SubtitleDraftActionsKey: FocusedValueKey {
    typealias Value = SubtitleDraftActions
}

extension FocusedValues {
    var subtitleDraftActions: SubtitleDraftActions? {
        get { self[SubtitleDraftActionsKey.self] }
        set { self[SubtitleDraftActionsKey.self] = newValue }
    }
}

struct SubtitleDraftMenuCommands: Commands {
    @FocusedValue(\.subtitleDraftActions) private var actions
    @AppStorage("huz.uiLanguage") private var languageRaw = AppLanguage.systemDefault.rawValue
    private var language: AppLanguage { AppLanguage(rawValue: languageRaw) ?? .systemDefault }

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Menu(text("draft.menu")) {
                if let store = actions?.store {
                    if !store.recoverable.isEmpty {
                        Text(text("draft.recovery"))
                    } else if let error = store.error {
                        Text(text("draft.failed"))
                        Text(error)
                    } else if store.isSaving {
                        Text(text("draft.saving"))
                    } else if let date = store.savedAt {
                        Text(text("draft.saved"))
                        Text(date, style: .time)
                    } else {
                        Text(text("draft.none"))
                    }
                }
                Divider()
                Button(text("draft.restore")) { actions?.restore() }
                    .disabled(actions?.canRestore != true || actions?.store.recoverable.isEmpty != false)
                Button(text("draft.dismiss")) { actions?.store.dismissRecovery() }
                    .disabled(actions?.store.recoverable.isEmpty != false)
            }
            .disabled(actions == nil)
        }
    }

    private func text(_ key: String) -> String { Copy.text(key, language: language) }
}
