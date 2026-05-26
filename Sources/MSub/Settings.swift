import Foundation

@MainActor
final class TranscriptionSettings: ObservableObject {
    @Published var model = ""
    @Published var format: OutputFormat = .srt
    @Published var segmentMode: SegmentMode = .vad
    @Published var vadThreshold = -38.0
    @Published var vadMaxSegment = 5.0
    @Published var vadSilence = 0.28
    @Published var vadSearch = 0.75
    @Published var vadMinSpeech = 0.2
    @Published var vadPadding = 0.12
    @Published var vadMinSegment = 0.8
    @Published var chunkSeconds = 20.0
    @Published var beamSize = 3
    @Published var minConfidence = 0.0
    @Published var lineChars = 18
    @Published var softmaxSmoothing = 1.25
    @Published var lengthPenalty = 0.6
    @Published var eosPenalty = 1.0
    @Published var decodeMaxLen = 0
    @Published var diarizeSpeakers = false
    @Published var diarizationSpeakerCount = 0
    @Published var timelineSpeakerMarkersEnabled = true
    @Published var waveformResolution: WaveformResolution = .high

    func apply(config: AppConfig) {
        model = config.defaultModel
    }

    func resetRecognitionDefaults() {
        vadThreshold = -38.0
        vadMaxSegment = 5.0
        vadSilence = 0.28
        vadSearch = 0.75
        vadMinSpeech = 0.2
        vadPadding = 0.12
        vadMinSegment = 0.8
        chunkSeconds = 20.0
        beamSize = 3
        minConfidence = 0.0
        lineChars = 18
        softmaxSmoothing = 1.25
        lengthPenalty = 0.6
        eosPenalty = 1.0
        decodeMaxLen = 0
        diarizeSpeakers = false
        diarizationSpeakerCount = 0
    }

    func applyPreset(_ preset: RecognitionPreset) {
        switch preset {
        case .balanced:
            resetRecognitionDefaults()
        case .dialogue:
            vadThreshold = -39.0
            vadMaxSegment = 4.2
            vadSilence = 0.2
            vadSearch = 0.8
            vadMinSpeech = 0.14
            vadPadding = 0.08
            vadMinSegment = 0.5
            beamSize = 3
            minConfidence = 0.0
            lineChars = 16
        case .lowVoice:
            vadThreshold = -44.0
            vadMaxSegment = 5.0
            vadSilence = 0.34
            vadSearch = 1.0
            vadMinSpeech = 0.1
            vadPadding = 0.16
            vadMinSegment = 0.55
            beamSize = 4
            minConfidence = 0.0
            lineChars = 18
        case .noisy:
            vadThreshold = -32.0
            vadMaxSegment = 4.5
            vadSilence = 0.24
            vadSearch = 0.7
            vadMinSpeech = 0.25
            vadPadding = 0.08
            vadMinSegment = 0.7
            beamSize = 3
            minConfidence = 0.15
            lineChars = 16
        case .fastCut:
            vadThreshold = -37.0
            vadMaxSegment = 3.5
            vadSilence = 0.16
            vadSearch = 0.6
            vadMinSpeech = 0.1
            vadPadding = 0.06
            vadMinSegment = 0.4
            beamSize = 3
            minConfidence = 0.0
            lineChars = 14
        case .sensitive:
            vadThreshold = -42.0
            vadMaxSegment = 5.0
            vadSilence = 0.22
            vadSearch = 0.9
            vadMinSpeech = 0.12
            vadPadding = 0.08
            vadMinSegment = 0.45
            lineChars = 16
        }
    }

    func formFields(includeOutput: Bool) -> [(String, String)] {
        var fields: [(String, String)] = [
            ("model", model),
            ("segment_mode", segmentMode.rawValue),
            ("vad_threshold_db", "\(vadThreshold)"),
            ("vad_max_segment_seconds", "\(vadMaxSegment)"),
            ("vad_min_silence_seconds", "\(vadSilence)"),
            ("vad_split_search_seconds", "\(vadSearch)"),
            ("vad_min_speech_seconds", "\(vadMinSpeech)"),
            ("vad_padding_seconds", "\(vadPadding)"),
            ("vad_min_segment_seconds", "\(vadMinSegment)"),
            ("chunk_seconds", "\(chunkSeconds)")
        ]

        if includeOutput {
            fields.append(contentsOf: [
                ("fmt", format.rawValue),
                ("beam_size", "\(beamSize)"),
                ("min_confidence", "\(minConfidence)"),
                ("max_chars_per_line", "\(lineChars)"),
                ("softmax_smoothing", "\(softmaxSmoothing)"),
                ("length_penalty", "\(lengthPenalty)"),
                ("eos_penalty", "\(eosPenalty)"),
                ("decode_max_len", "\(decodeMaxLen)"),
                ("diarize_speakers", diarizeSpeakers ? "true" : "false"),
                ("diarization_num_speakers", "\(diarizationSpeakerCount)")
            ])
        }

        return fields
    }
}

enum WaveformResolution: String, CaseIterable, Identifiable {
    case high
    case medium
    case low

    var id: String { rawValue }

    var targetMultiplier: Double {
        switch self {
        case .high: 1.0
        case .medium: 0.5
        case .low: 0.25
        }
    }
}

enum RecognitionPreset: String, CaseIterable, Identifiable {
    case balanced
    case dialogue
    case lowVoice
    case noisy
    case fastCut
    case sensitive

    var id: String { rawValue }
}
