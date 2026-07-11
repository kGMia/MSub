import XCTest
@testable import MSub

final class AudioEventSegmentMarkerTests: XCTestCase {
    func testMarksDirectNonLexicalVoice() {
        let segment = makeSegment(
            labels: [
                .init(label: "Laughter", score: 0.72),
                .init(label: "Speech", score: 0.18),
            ],
            speechScore: 0.18
        )

        let result = AudioEventSegmentMarker.mark(
            segment: segment,
            filterType: .nonLexical,
            preset: .balanced,
            threshold: 0.45
        )

        XCTAssertTrue(result.flagged)
        XCTAssertEqual(result.label, "Laughter")
        XCTAssertEqual(result.score ?? 0, 0.72, accuracy: 0.0001)
    }

    func testKeepsSpeechDominantSegment() {
        let segment = makeSegment(
            labels: [
                .init(label: "Speech", score: 0.82),
                .init(label: "Laughter", score: 0.52),
            ],
            speechScore: 0.82
        )

        let result = AudioEventSegmentMarker.mark(
            segment: segment,
            filterType: .all,
            preset: .balanced,
            threshold: 0.45
        )

        XCTAssertFalse(result.flagged)
        XCTAssertNil(result.label)
    }

    func testMarksNonSpeechWhenSpeechIsLow() {
        let segment = makeSegment(
            labels: [
                .init(label: "Applause", score: 0.62),
                .init(label: "Speech", score: 0.12),
            ],
            speechScore: 0.12
        )

        let result = AudioEventSegmentMarker.mark(
            segment: segment,
            filterType: .nonSpeech,
            preset: .balanced,
            threshold: 0.45
        )

        XCTAssertTrue(result.flagged)
        XCTAssertEqual(result.label, "Applause")
    }

    func testMarksLowSpeechEventWithCustomLabel() {
        let segment = makeSegment(
            labels: [
                .init(label: "Speech", score: 0.1),
            ],
            speechScore: 0.1
        )

        let result = AudioEventSegmentMarker.mark(
            segment: segment,
            filterType: .lowSpeech,
            preset: .balanced,
            threshold: 0.45,
            lowSpeechLabel: "低语音概率"
        )

        XCTAssertTrue(result.flagged)
        XCTAssertEqual(result.label, "低语音概率")
        XCTAssertEqual(result.score ?? 0, 0.9, accuracy: 0.0001)
    }

    func testMarksRepetitionWhenSpeechIsWeak() {
        let segment = makeSegment(
            labels: [
                .init(label: "Speech", score: 0.2),
            ],
            speechScore: 0.2,
            repetitionScore: 0.66
        )

        let result = AudioEventSegmentMarker.mark(
            segment: segment,
            filterType: .repetition,
            preset: .balanced,
            threshold: 0.45,
            repetitionLabel: "重复"
        )

        XCTAssertTrue(result.flagged)
        XCTAssertEqual(result.label, "重复")
        XCTAssertEqual(result.score ?? 0, 0.66, accuracy: 0.0001)
    }

    func testStrictPresetAvoidsBorderlineRepetition() {
        let segment = makeSegment(
            labels: [
                .init(label: "Speech", score: 0.2),
            ],
            speechScore: 0.2,
            repetitionScore: 0.66
        )

        let result = AudioEventSegmentMarker.mark(
            segment: segment,
            filterType: .repetition,
            preset: .strict,
            threshold: 0.58
        )

        XCTAssertFalse(result.flagged)
    }

    func testStatisticsCountsScoredAndFlaggedSegments() {
        let segments = [
            makeSegment(
                labels: [.init(label: "Speech", score: 0.7)],
                speechScore: 0.7,
                repetitionScore: 0.1,
                flagged: false
            ),
            makeSegment(
                labels: [.init(label: "Laughter", score: 0.8)],
                speechScore: 0.2,
                repetitionScore: 0.7,
                flagged: true
            ),
            makeSegment(index: 3, flagged: false),
        ]

        let stats = AudioEventSegmentMarker.statistics(in: segments)

        XCTAssertEqual(stats.total, 3)
        XCTAssertEqual(stats.scored, 2)
        XCTAssertEqual(stats.flagged, 1)
        XCTAssertEqual(stats.averageSpeech ?? 0, 0.45, accuracy: 0.0001)
        XCTAssertEqual(stats.averageRepetition ?? 0, 0.4, accuracy: 0.0001)
    }

    func testRoundedScoreUsesBackendPrecision() {
        XCTAssertEqual(AudioEventSegmentMarker.roundedScore(0.123456), 0.1235, accuracy: 0.0001)
    }

    private func makeSegment(
        index: Int = 1,
        labels: [AudioEventLabelScore] = [],
        speechScore: Double? = nil,
        repetitionScore: Double? = nil,
        flagged: Bool = false
    ) -> SubtitleSegment {
        SubtitleSegment(
            index: index,
            start: Double(index - 1),
            end: Double(index),
            duration: 1,
            audioLabels: labels,
            speechScore: speechScore,
            repetitionScore: repetitionScore,
            flagged: flagged
        )
    }
}
