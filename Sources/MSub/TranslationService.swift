import Foundation
@preconcurrency import Translation

/// Output behavior when translating a whole subtitle file.
enum TranslationOutputMode: String, CaseIterable, Identifiable {
    case replace
    case bilingual

    var id: String { rawValue }
}

/// A common target language identifier the user can pick.
struct TranslationLanguageChoice: Identifiable, Hashable {
    let id: String
    let language: Locale.Language

    init(_ identifier: String) {
        self.id = identifier
        self.language = Locale.Language(identifier: identifier)
    }

    var localizedTitle: String {
        Locale.current.localizedString(forIdentifier: id) ?? id
    }

    static let common: [TranslationLanguageChoice] = [
        TranslationLanguageChoice("zh-Hans"),
        TranslationLanguageChoice("zh-Hant"),
        TranslationLanguageChoice("en"),
        TranslationLanguageChoice("ja"),
        TranslationLanguageChoice("ko"),
        TranslationLanguageChoice("es"),
        TranslationLanguageChoice("fr"),
        TranslationLanguageChoice("de"),
        TranslationLanguageChoice("it"),
        TranslationLanguageChoice("pt"),
        TranslationLanguageChoice("ru"),
        TranslationLanguageChoice("ar"),
        TranslationLanguageChoice("hi"),
        TranslationLanguageChoice("id"),
        TranslationLanguageChoice("th"),
        TranslationLanguageChoice("vi")
    ]
}

/// Describes a pending translation request. The view layer uses this to set up
/// a `translationTask(_:action:)` configuration; once the session is delivered
/// the task closure calls back to perform the actual work.
struct TranslationJob: Identifiable, Equatable {
    enum Scope: Equatable {
        case wholeSlot(slotID: FileSlot.ID, mode: TranslationOutputMode)
        case cues(slotID: FileSlot.ID, cueIDs: Set<SubtitleCue.ID>, mode: TranslationOutputMode)
    }

    let id = UUID()
    let scope: Scope
    let source: Locale.Language?
    let target: Locale.Language

    static func == (lhs: TranslationJob, rhs: TranslationJob) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
@Observable
final class TranslationUndoCoordinator {
    var restoreHandler: ((UUID, [SubtitleCue]) -> Void)?

    func restore(slotID: UUID, cues: [SubtitleCue]) {
        restoreHandler?(slotID, cues)
    }
}

enum TranslationUtility {
    /// Translates an array of strings preserving order. Empty strings are
    /// returned untouched without contacting the session.
    @MainActor
    static func translateBatch(
        _ sources: [String],
        using session: TranslationSession
    ) async throws -> [String] {
        var results = sources
        for (index, text) in sources.enumerated() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let response = try await session.translate(text)
            results[index] = response.targetText
        }
        return results
    }

    static func combine(original: String, translated: String, mode: TranslationOutputMode) -> String {
        switch mode {
        case .replace:
            return translated
        case .bilingual:
            let originalTrimmed = original.trimmingCharacters(in: .whitespacesAndNewlines)
            let translatedTrimmed = translated.trimmingCharacters(in: .whitespacesAndNewlines)
            if originalTrimmed.isEmpty { return translatedTrimmed }
            if translatedTrimmed.isEmpty { return original }
            if originalTrimmed == translatedTrimmed { return original }
            return "\(original)\n\(translated)"
        }
    }
}
