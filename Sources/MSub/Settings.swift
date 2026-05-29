import Foundation

@MainActor
final class TranscriptionSettings: ObservableObject {
    @Published var model = ""
    @Published var asrEngine: ASREngine = .auto
    @Published var modelCatalog: [ASRModelInfo] = []
    @Published var format: OutputFormat = .srt
    @Published var recognitionLanguage: RecognitionLanguage = .auto
    @Published var senseVoiceUseITN = true
    @Published var senseVoiceRichInfo = false
    @Published var mimoMaxTokens = 256
    @Published var mimoTemperature = 0.0
    @Published var mimoTopP = 0.95
    @Published var mimoTopK = 0
    @Published var segmentMode: SegmentMode = .vad
    @Published var vadEngine: VADEngine = .firered
    @Published var vadCatalog: [VADModelInfo] = []
    @Published var vadThreshold = -38.0
    @Published var fireRedVADThreshold = 0.4
    @Published var fireRedVADSmoothWindow = 5
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
        modelCatalog = config.models ?? []
        vadCatalog = config.vadEngines ?? []
        asrEngine = .auto
        vadEngine = config.defaultVADEngine ?? .firered
        model = config.defaultModel
    }

    var effectiveASREngine: ASREngine {
        if asrEngine != .auto {
            return asrEngine
        }
        let lowercasedModel = model.lowercased()
        if lowercasedModel.contains("sensevoice") {
            return .sensevoice
        }
        if lowercasedModel.contains("mimo") {
            return .mimo
        }
        return .fireredasr2
    }

    var isSenseVoiceActive: Bool {
        effectiveASREngine == .sensevoice
    }

    var isMiMoActive: Bool {
        effectiveASREngine == .mimo
    }

    var isFireRedVADActive: Bool {
        segmentMode == .vad && vadEngine != .energy
    }

    func applyDefaultModelForSelectedEngine() {
        guard asrEngine != .auto,
              let modelInfo = modelCatalog.first(where: { $0.engine == asrEngine }) else {
            return
        }
        model = modelInfo.defaultModel
    }

    func resetRecognitionDefaults() {
        recognitionLanguage = .auto
        senseVoiceUseITN = true
        senseVoiceRichInfo = false
        mimoMaxTokens = 256
        mimoTemperature = 0.0
        mimoTopP = 0.95
        mimoTopK = 0
        vadThreshold = -38.0
        fireRedVADThreshold = 0.4
        fireRedVADSmoothWindow = 5
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
            applyEnginePreset(.balanced)
            return
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
        applyEnginePreset(preset)
    }

    private func applyEnginePreset(_ preset: RecognitionPreset) {
        switch effectiveASREngine {
        case .mimo:
            mimoTemperature = 0.0
            mimoTopP = 0.95
            mimoTopK = 0
            switch preset {
            case .balanced:
                mimoMaxTokens = 256
            case .dialogue:
                mimoMaxTokens = 256
            case .lowVoice:
                mimoMaxTokens = 320
            case .noisy:
                mimoMaxTokens = 256
            case .fastCut:
                mimoMaxTokens = 192
            case .sensitive:
                mimoMaxTokens = 320
            }
        case .sensevoice:
            senseVoiceUseITN = true
        case .fireredasr2, .auto:
            break
        }
    }

    func formFields(includeOutput: Bool) -> [(String, String)] {
        var fields: [(String, String)] = [
            ("model", model),
            ("asr_engine", asrEngine.rawValue),
            ("language", recognitionLanguage.rawValue),
            ("use_itn", senseVoiceUseITN ? "true" : "false"),
            ("sensevoice_rich_info", senseVoiceRichInfo ? "true" : "false"),
            ("segment_mode", segmentMode.rawValue),
            ("vad_engine", vadEngine.rawValue),
            ("vad_threshold_db", "\(vadThreshold)"),
            ("firered_vad_threshold", "\(fireRedVADThreshold)"),
            ("firered_vad_smooth_window", "\(fireRedVADSmoothWindow)"),
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
                ("mimo_max_tokens", "\(mimoMaxTokens)"),
                ("mimo_temperature", "\(mimoTemperature)"),
                ("mimo_top_p", "\(mimoTopP)"),
                ("mimo_top_k", "\(mimoTopK)"),
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
