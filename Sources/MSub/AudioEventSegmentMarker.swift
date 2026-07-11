import Foundation

struct AudioEventPresetRule {
    let eventScale: Double
    let nonSpeechScale: Double
    let margin: Double
    let speechMax: Double
    let repetition: Double
    let lowSpeechEvent: Double
}

struct AudioEventPreviewStats {
    let total: Int
    let flagged: Int
    let scored: Int
    let averageSpeech: Double?
    let averageRepetition: Double?

    var hasScores: Bool {
        scored > 0 || averageSpeech != nil || averageRepetition != nil
    }
}

struct AudioEventMarkResult: Equatable {
    let label: String?
    let score: Double?
    let flagged: Bool
}

enum AudioEventSegmentMarker {
    static func statistics(in segments: [SubtitleSegment]) -> AudioEventPreviewStats {
        let scoredSegments = segments.filter { segment in
            !segment.audioLabels.isEmpty || segment.audioScore != nil || segment.speechScore != nil || segment.repetitionScore != nil
        }
        let speechScores = segments.compactMap(\.speechScore)
        let repetitionScores = segments.compactMap(\.repetitionScore)
        return AudioEventPreviewStats(
            total: segments.count,
            flagged: segments.filter(\.flagged).count,
            scored: scoredSegments.count,
            averageSpeech: average(speechScores),
            averageRepetition: average(repetitionScores)
        )
    }

    static func mark(
        segment: SubtitleSegment,
        filterType: AudioEventFilterType,
        preset: AudioEventFilterPreset,
        threshold rawThreshold: Double,
        lowSpeechLabel: String = "Low speech probability",
        repetitionLabel: String = "Repetition"
    ) -> AudioEventMarkResult {
        let threshold = clampedProbability(rawThreshold)
        let rule = presetRule(preset)
        let eventThreshold = clampedProbability(threshold * rule.eventScale)
        let nonSpeechThreshold = clampedProbability(threshold * rule.nonSpeechScale)
        let nonLexicalMatch = scoreMatchingLabels(segment.audioLabels, terms: nonLexicalTerms)
        let nonSpeechMatch = scoreMatchingLabels(segment.audioLabels, terms: nonSpeechTerms)
        let speechMatch = scoreMatchingLabels(segment.audioLabels, terms: speechTerms)
        let speechScore = segment.speechScore ?? speechMatch.score
        let repetitionScore = segment.repetitionScore ?? 0
        let topLabel = segment.audioLabels.first?.label ?? nonLexicalMatch.label ?? nonSpeechMatch.label
        let topScore = segment.audioLabels.first?.score ?? max(nonLexicalMatch.score, nonSpeechMatch.score)
        let bestIsSpeech = topLabel.map { labelMatches($0, terms: speechTerms) } ?? false

        let directNonLexical = hasRule(filterType, .nonLexical)
            && nonLexicalMatch.label != nil
            && nonLexicalMatch.score >= eventThreshold
            && nonLexicalMatch.score >= speechScore + rule.margin
        let directNonSpeech = hasRule(filterType, .nonSpeech)
            && nonSpeechMatch.label != nil
            && nonSpeechMatch.score >= nonSpeechThreshold
            && speechScore <= rule.speechMax
            && nonSpeechMatch.score >= speechScore + rule.margin
        let lowSpeechEvent = hasRule(filterType, .lowSpeech)
            && speechScore <= rule.speechMax
            && (filterType == .lowSpeech || (!bestIsSpeech && topScore >= rule.lowSpeechEvent))
        let repeatedNonLexical = hasRule(filterType, .repetition)
            && repetitionScore >= rule.repetition
            && (
                nonLexicalMatch.score >= max(0.16, threshold * 0.55)
                || nonSpeechMatch.score >= max(0.16, threshold * 0.55)
                || speechScore <= rule.speechMax
            )

        if directNonLexical {
            return AudioEventMarkResult(label: nonLexicalMatch.label, score: nonLexicalMatch.score, flagged: true)
        }
        if directNonSpeech {
            return AudioEventMarkResult(label: nonSpeechMatch.label, score: nonSpeechMatch.score, flagged: true)
        }
        if lowSpeechEvent {
            let label = bestIsSpeech ? lowSpeechLabel : (topLabel ?? lowSpeechLabel)
            return AudioEventMarkResult(label: label, score: 1.0 - speechScore, flagged: true)
        }
        if repeatedNonLexical {
            return AudioEventMarkResult(
                label: nonLexicalMatch.label ?? nonSpeechMatch.label ?? repetitionLabel,
                score: max(repetitionScore, nonLexicalMatch.score, nonSpeechMatch.score),
                flagged: true
            )
        }
        return AudioEventMarkResult(label: nil, score: nil, flagged: false)
    }

    static func roundedScore(_ value: Double) -> Double {
        (value * 10_000).rounded() / 10_000
    }

    private static func presetRule(_ preset: AudioEventFilterPreset) -> AudioEventPresetRule {
        switch preset {
        case .strict:
            AudioEventPresetRule(
                eventScale: 1.22,
                nonSpeechScale: 1.08,
                margin: 0.12,
                speechMax: 0.18,
                repetition: 0.72,
                lowSpeechEvent: 0.52
            )
        case .balanced:
            AudioEventPresetRule(
                eventScale: 1.0,
                nonSpeechScale: 0.9,
                margin: 0.06,
                speechMax: 0.32,
                repetition: 0.58,
                lowSpeechEvent: 0.38
            )
        case .broad:
            AudioEventPresetRule(
                eventScale: 0.78,
                nonSpeechScale: 0.72,
                margin: -0.02,
                speechMax: 0.48,
                repetition: 0.46,
                lowSpeechEvent: 0.28
            )
        }
    }

    private static func hasRule(_ selected: AudioEventFilterType, _ rule: AudioEventFilterType) -> Bool {
        selected == .all || selected == rule
    }

    private static func scoreMatchingLabels(
        _ labels: [AudioEventLabelScore],
        terms: [String]
    ) -> (label: String?, score: Double) {
        var bestLabel: String?
        var bestScore = 0.0
        for item in labels where labelMatches(item.label, terms: terms) {
            let score = item.score ?? 0
            if score > bestScore || bestLabel == nil {
                bestLabel = item.label
                bestScore = score
            }
        }
        return (bestLabel, bestScore)
    }

    private static func labelMatches(_ label: String, terms: [String]) -> Bool {
        let normalized = label
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return terms.contains { normalized.contains($0) }
    }

    private static func clampedProbability(_ value: Double) -> Double {
        min(1.0, max(0.0, value))
    }

    private static func average(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static let nonLexicalTerms = [
        "laughter",
        "laugh",
        "giggle",
        "snicker",
        "chuckle",
        "scream",
        "screaming",
        "shout",
        "yell",
        "wail",
        "moan",
        "groan",
        "crying",
        "sob",
        "whimper",
        "sigh",
        "gasp",
        "breath",
        "breathing",
        "pant",
        "cough",
        "sneeze",
        "throat clearing",
    ]

    private static let nonSpeechTerms = [
        "music",
        "musical instrument",
        "singing bowl",
        "applause",
        "clapping",
        "cheering",
        "crowd",
        "noise",
        "white noise",
        "static",
        "silence",
        "vehicle",
        "engine",
        "door",
        "keyboard",
        "typing",
        "click",
        "beep",
        "alarm",
        "ringtone",
        "telephone",
        "footstep",
        "rustle",
        "wind",
        "rain",
        "thunder",
        "water",
    ]

    private static let speechTerms = [
        "speech",
        "conversation",
        "narration",
        "monologue",
        "dialogue",
        "talking",
    ]
}
