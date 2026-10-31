import Foundation

enum MeaninglessCueReason: String, CaseIterable {
    case empty
    case symbols
    case repetition
    case interjection
}

struct MeaninglessCueClassification: Equatable {
    let reason: MeaninglessCueReason?

    var isMeaningless: Bool {
        reason != nil
    }
}

enum MeaninglessCueDetector {
    private static let englishFillers: Set<String> = [
        "ah", "aah", "ahh", "uh", "uhh", "um", "umm", "hm", "hmm",
        "mm", "mmm", "oh", "ooh", "eh", "er", "err", "huh",
        "ha", "hah", "haha"
    ]
    private static let chineseFillerScalars = Set("啊呀哦噢喔嗯呃额哎唉诶欸哈呵嘿哼".unicodeScalars)
    private static let japaneseFillers: Set<String> = [
        "あ", "ああ", "あー", "え", "ええ", "えー", "う", "うん",
        "うーん", "お", "おお", "ん", "まあ", "まー", "は", "はは",
        "ははは", "はぁ", "へ", "へへ", "へぇ", "ふ", "ふふ", "ふう",
        "ほ", "ほほ", "む", "あの", "えっと"
    ]
    // Whole-cue candidates, not arbitrary strings made from "filler" kana.
    // In this editing workflow standalone/repeated あう is intentionally included.
    private static let japaneseVocalUnits: [(head: [Character], tail: Set<Character>)] = {
        let extensions = Set("ーっぁぃぅぇぉ")
        let heads = ["うん", "わー", "わあ", "わぁ", "わっ", "うわー", "うわあ", "うわぁ", "うわっ", "あう", "うあ", "んあ", "んん", "あの", "えっと", "ええと", "そのお", "ふむ",
                     "あぁ", "あぅ", "うぅ", "おぉ", "えぇ", "んぅ", "うむ", "んふ",
                     "あー", "えー", "うー", "おー", "んー", "あっ", "えっ", "うっ", "おっ", "んっ",
                     "はぁ", "はあ", "ふぅ", "ふう", "へぇ", "へえ"]
        var units = heads.map { (Array($0), extensions) }
        for (head, sound) in [("あは", "は"), ("うふ", "ふ"), ("えへ", "へ"),
                              ("おほ", "ほ"), ("あひ", "ひ"), ("うひ", "ひ"),
                              ("はは", "は"), ("へへ", "へ"), ("ふふ", "ふ"), ("ほほ", "ほ")] {
            units.append((Array(head), extensions.union(Set(sound))))
        }
        return units
    }()

    private static let vocalUnitsByFirstCharacter = Dictionary(grouping: japaneseVocalUnits) { $0.head[0] }
    private static let markupPattern = try! NSRegularExpression(pattern: "<[^>]+>")

    static func isMeaningless(_ rawText: String) -> Bool {
        classification(for: rawText).isMeaningless
    }

    static func classification(for rawText: String) -> MeaninglessCueClassification {
        let text = normalizedText(rawText)
        if text.isEmpty {
            return MeaninglessCueClassification(reason: .empty)
        }
        if isSymbolsOnly(text) {
            return MeaninglessCueClassification(reason: .symbols)
        }
        if isLargeRepetition(text) {
            return MeaninglessCueClassification(reason: .repetition)
        }
        if isOnlyInterjections(text) {
            return MeaninglessCueClassification(reason: .interjection)
        }
        return MeaninglessCueClassification(reason: nil)
    }

    private static func normalizedText(_ text: String) -> String {
        let compatible = text.precomposedStringWithCompatibilityMapping
        // Compile markup matching once, rather than on every visible table row.
        let plain = compatible.contains("<") ? markupPattern.stringByReplacingMatches(
            in: compatible, range: NSRange(compatible.startIndex..., in: compatible), withTemplate: " ") : compatible
        return plain.replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\u{3000}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isSymbolsOnly(_ text: String) -> Bool {
        !text.unicodeScalars.contains { isLexicalScalar($0) }
    }

    private static func isLargeRepetition(_ text: String) -> Bool {
        // Repeated Japanese words can be meaningful (はいはいはい / まだまだまだ).
        // Vocal repetitions are handled by the Japanese rules below.
        guard !text.unicodeScalars.contains(where: isKana) else { return false }
        let characters = lexicalCharacters(in: text)
        guard characters.count >= 4 else { return false }
        let maxUnitLength = min(4, characters.count / 2)
        guard maxUnitLength >= 1 else { return false }

        for unitLength in 1...maxUnitLength {
            let minimumRepeats = unitLength == 1 ? 4 : 3
            guard characters.count / unitLength >= minimumRepeats,
                  characters.count % unitLength == 0 else {
                continue
            }
            var matches = true
            for index in characters.indices where characters[index] != characters[index % unitLength] {
                matches = false
                break
            }
            if matches {
                return true
            }
        }
        return false
    }

    private static func lexicalCharacters(in text: String) -> [Character] {
        let folded = text
            .folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        return Array(folded).filter { character in
            character.unicodeScalars.contains { isLexicalScalar($0) }
        }
    }

    private static func isOnlyInterjections(_ text: String) -> Bool {
        isOnlyEnglishFillers(text)
            || isOnlyChineseFillers(text)
            || isOnlyJapaneseFillers(text)
    }

    private static func isOnlyEnglishFillers(_ text: String) -> Bool {
        let folded = text
            .folding(options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        guard !folded.unicodeScalars.contains(where: { isLexicalScalar($0) && !isASCIILetter($0) }) else {
            return false
        }
        let tokens = folded.split { character in
            !character.unicodeScalars.allSatisfy { isASCIILetter($0) }
        }
        guard !tokens.isEmpty else { return false }
        return tokens.allSatisfy { token in
            englishFillers.contains(normalizedEnglishFiller(String(token)))
        }
    }

    private static func normalizedEnglishFiller(_ token: String) -> String {
        var result = ""
        var previous: Character?
        var runLength = 0
        for character in token {
            if character == previous {
                runLength += 1
            } else {
                previous = character
                runLength = 1
            }
            if runLength <= 2 {
                result.append(character)
            }
        }
        return result
    }

    private static func isOnlyChineseFillers(_ text: String) -> Bool {
        let lexicalScalars = text.unicodeScalars.filter { isLexicalScalar($0) }
        guard !lexicalScalars.isEmpty,
              lexicalScalars.allSatisfy({ isCJK($0) }) else {
            return false
        }
        return lexicalScalars.allSatisfy { chineseFillerScalars.contains($0) }
    }

    private static func isOnlyJapaneseFillers(_ text: String) -> Bool {
        // ICU's reverse Hiragana-Katakana transform expands ー into vowels.
        // Map letters directly so vocal-length marks retain their meaning.
        let hiragana = String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            (0x30A1...0x30F6).contains(scalar.value) ? Unicode.Scalar(scalar.value - 0x60)! : scalar
        }))
        let groups = japaneseLexicalGroups(in: hiragana)
        guard !groups.isEmpty else { return false }
        return groups.allSatisfy { isJapaneseFillerGroup($0) }
    }

    private static func japaneseLexicalGroups(in text: String) -> [String] {
        var groups: [String] = []
        var current = ""
        for scalar in text.unicodeScalars {
            if isKana(scalar) || isJapaneseLongSound(scalar) {
                current.unicodeScalars.append(scalar)
            } else if isLexicalScalar(scalar) {
                return []
            } else if !current.isEmpty {
                groups.append(current)
                current = ""
            }
        }
        if !current.isEmpty {
            groups.append(current)
        }
        return groups
    }

    private static func isJapaneseFillerGroup(_ group: String) -> Bool {
        let compact = group
            .folding(options: [.widthInsensitive], locale: Locale(identifier: "ja_JP"))
            .replacingOccurrences(of: "〜", with: "ー")
        if japaneseFillers.contains(compact) {
            return true
        }
        let scalars = compact.unicodeScalars
        if let first = scalars.first, "あえうおん".unicodeScalars.contains(first),
           scalars.allSatisfy({ $0 == first }) { return true }
        // Segment recognized units without a nested repeated regex: long rejected
        // kana strings must not cause exponential backtracking on the editor thread.
        let characters = Array(compact)
        var reachable = Array(repeating: false, count: characters.count + 1)
        reachable[characters.count] = true
        for start in characters.indices.reversed() {
            for unit in vocalUnitsByFirstCharacter[characters[start]] ?? [] {
                var end = start + unit.head.count
                guard end <= characters.count,
                      characters[start..<end].elementsEqual(unit.head) else { continue }
                if reachable[end] { reachable[start] = true; break }
                while end < characters.count, unit.tail.contains(characters[end]) {
                    end += 1
                    if reachable[end] { reachable[start] = true; break }
                }
                if reachable[start] { break }
            }
        }
        return reachable[0]
    }

    private static func isLexicalScalar(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar)
            || isCJK(scalar)
            || isKana(scalar)
            || isHangul(scalar)
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value))
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        (0x3400...0x4DBF).contains(scalar.value)
            || (0x4E00...0x9FFF).contains(scalar.value)
            || (0xF900...0xFAFF).contains(scalar.value)
    }

    private static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        (0x3040...0x309F).contains(scalar.value)
            || (0x30A0...0x30FF).contains(scalar.value)
    }

    private static func isHangul(_ scalar: Unicode.Scalar) -> Bool {
        (0xAC00...0xD7AF).contains(scalar.value)
            || (0x1100...0x11FF).contains(scalar.value)
            || (0x3130...0x318F).contains(scalar.value)
    }

    private static func isJapaneseLongSound(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 0x30FC || scalar.value == 0x301C
    }
}
