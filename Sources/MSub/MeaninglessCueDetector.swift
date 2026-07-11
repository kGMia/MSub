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
    private static let japaneseLooseScalars = Set("あぁえぇうぅおぉんはへふほハヘフホー〜".unicodeScalars)

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
        text
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "\u{3000}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isSymbolsOnly(_ text: String) -> Bool {
        !text.unicodeScalars.contains { isLexicalScalar($0) }
    }

    private static func isLargeRepetition(_ text: String) -> Bool {
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
        let groups = japaneseLexicalGroups(in: text)
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
        return compact.unicodeScalars.allSatisfy { japaneseLooseScalars.contains($0) }
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
