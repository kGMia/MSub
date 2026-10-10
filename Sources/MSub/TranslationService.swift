import Foundation
@preconcurrency import Translation

/// Output behavior when translating a whole subtitle file.
enum TranslationOutputMode: String, CaseIterable, Identifiable {
    case replace
    case bilingual

    var id: String { rawValue }
}

/// Apply delayed results by identity, leaving edits made during translation intact.
enum SubtitleTranslationEdits {
    static func apply(snapshot: [SubtitleCue], translated: [String], current: [SubtitleCue],
                      mode: TranslationOutputMode) -> [SubtitleCue] {
        let results = Dictionary(zip(snapshot, translated).map { ($0.0.id, ($0.0, $0.1)) },
                                 uniquingKeysWith: { first, _ in first })
        return current.map { cue in
            guard let (original, translation) = results[cue.id], original == cue else { return cue }
            var updated = cue
            switch mode {
            case .replace:
                updated.bilingual = nil
                updated.text = translation
            case .bilingual:
                updated.setBilingual(.init(source: original.translationSourceText, translation: translation,
                                            translationFirst: original.bilingualText?.translationFirst ?? false))
            }
            return updated
        }
    }
}

/// A common target language identifier the user can pick.
struct TranslationLanguageChoice: Identifiable, Hashable {
    let id: String
    let language: Locale.Language?

    init(_ identifier: String) {
        self.id = identifier
        self.language = Locale.Language(identifier: identifier)
    }

    private init(id: String, language: Locale.Language?) {
        self.id = id
        self.language = language
    }

    var isAutomatic: Bool {
        language == nil
    }

    var localizedTitle: String {
        Locale.current.localizedString(forIdentifier: id) ?? id
    }

    static let automatic = TranslationLanguageChoice(id: "auto", language: nil)

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

    static let sourceChoices: [TranslationLanguageChoice] = [.automatic] + common
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
    private static let contextualBatchMaxCues = 24
    private static let contextualBatchMaxCharacters = 3_600

    /// Translates an array of strings preserving order. Empty strings are
    /// returned untouched without contacting the session.
    @MainActor
    static func translateBatch(
        _ sources: [String],
        using session: TranslationSession,
        contextual: Bool = false
    ) async throws -> [String] {
        if contextual {
            return await translateContextualBatch(sources, using: session)
        }
        return await translateIndividually(sources, using: session)
    }

    @MainActor
    private static func translateIndividually(
        _ sources: [String],
        using session: TranslationSession
    ) async -> [String] {
        var results = sources
        for (index, text) in sources.enumerated() {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            do {
                let response = try await session.translate(text)
                results[index] = response.targetText
            } catch {
                continue
            }
        }
        return results
    }

    @MainActor
    private static func translateContextualBatch(
        _ sources: [String],
        using session: TranslationSession
    ) async -> [String] {
        var results = sources
        for group in contextualGroups(for: sources) {
            let packet = makeContextualPacket(sources: sources, indices: group)
            do {
                let response = try await session.translate(packet)
                let parsed = parseContextualPacket(response.targetText)
                let missing = apply(parsed: parsed, to: &results, indices: group)
                if !missing.isEmpty {
                    let recovered = await translateMissingIndividually(
                        missing,
                        sources: sources,
                        using: session
                    )
                    for (index, translated) in recovered {
                        results[index] = translated
                    }
                }
            } catch {
                let recovered = await translateMissingIndividually(
                    group,
                    sources: sources,
                    using: session
                )
                for (index, translated) in recovered {
                    results[index] = translated
                }
            }
        }
        return results
    }

    private static func contextualGroups(for sources: [String]) -> [[Int]] {
        var groups: [[Int]] = []
        var current: [Int] = []
        var characterCount = 0
        for index in sources.indices {
            let trimmed = sources[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let nextCount = characterCount + trimmed.count + 12
            if !current.isEmpty,
               (current.count >= contextualBatchMaxCues || nextCount > contextualBatchMaxCharacters) {
                groups.append(current)
                current = []
                characterCount = 0
            }
            current.append(index)
            characterCount += trimmed.count + 12
        }
        if !current.isEmpty {
            groups.append(current)
        }
        return groups
    }

    private static func makeContextualPacket(sources: [String], indices: [Int]) -> String {
        indices.enumerated().map { offset, sourceIndex in
            let marker = String(format: "#%03d:", offset + 1)
            let text = sources[sourceIndex]
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(marker) \(text)"
        }
        .joined(separator: "\n")
    }

    private static func parseContextualPacket(_ text: String) -> [Int: String] {
        var parsed: [Int: String] = [:]
        var currentNumber: Int?
        let pattern = #"^\s*(?:#|＃)?\s*(\d{1,4})\s*[:：.)、-]?\s*(.*)$"#
        let regex = try? NSRegularExpression(pattern: pattern)
        for line in text.components(separatedBy: .newlines) {
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let match = regex?.firstMatch(in: line, range: range),
               let numberRange = Range(match.range(at: 1), in: line),
               let number = Int(line[numberRange]) {
                let body: String
                if let bodyRange = Range(match.range(at: 2), in: line) {
                    body = String(line[bodyRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    body = ""
                }
                parsed[number] = body
                currentNumber = number
            } else if let currentNumber {
                let continuation = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !continuation.isEmpty else { continue }
                let existing = parsed[currentNumber] ?? ""
                parsed[currentNumber] = existing.isEmpty ? continuation : "\(existing)\n\(continuation)"
            }
        }
        return parsed
    }

    @MainActor
    private static func translateMissingIndividually(
        _ indices: [Int],
        sources: [String],
        using session: TranslationSession
    ) async -> [Int: String] {
        var recovered: [Int: String] = [:]
        for index in indices {
            let text = sources[index].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            do {
                let response = try await session.translate(sources[index])
                recovered[index] = response.targetText
            } catch {
                continue
            }
        }
        return recovered
    }

    private static func apply(
        parsed: [Int: String],
        to results: inout [String],
        indices: [Int]
    ) -> [Int] {
        var missing: [Int] = []
        for (offset, sourceIndex) in indices.enumerated() {
            let markerNumber = offset + 1
            guard let translated = parsed[markerNumber]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !translated.isEmpty else {
                missing.append(sourceIndex)
                continue
            }
            results[sourceIndex] = translated
        }
        return missing
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
