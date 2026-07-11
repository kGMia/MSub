import Foundation
import Observation

@MainActor
@Observable
final class TranscriptionSettings {
    private static let persistedSettingsKey = "msub.transcriptionSettings.v1"
    private static let customPresetsKey = "msub.customRecognitionPresets.v1"
    private static let mimoDefaultMaxTokens = 256
    private static let mimoDefaultTemperature = 0.0
    private static let mimoDefaultTopP = 0.95
    private static let mimoDefaultTopK = 0
    private static let megaDefaultMaxTokens = 512
    private static let megaDefaultTemperature = 0.0
    private static let megaDefaultTopP = 1.0
    private static let megaDefaultTopK = 0

    var model = ""
    var asrEngine: ASREngine = .fireredasr2
    var modelCatalog: [ASRModelInfo] = []
    var format: OutputFormat = .srt
    var recognitionLanguage: RecognitionLanguage = .auto
    var senseVoiceUseITN = true
    var senseVoiceRichInfo = false
    var mimoMaxTokens = 256
    var mimoTemperature = 0.0
    var mimoTopP = 0.95
    var mimoTopK = 0
    var segmentMode: SegmentMode = .vad
    var vadEngine: VADEngine = .pyannoteMLX
    var vadCatalog: [VADModelInfo] = []
    var vadThreshold = -38.0
    var fireRedVADThreshold = 0.4
    var fireRedVADSmoothWindow = 5
    var vadMaxSegment = 5.0
    var vadSilence = 0.28
    var vadSearch = 0.75
    var vadMinSpeech = 0.2
    var vadPadding = 0.20
    var vadMinSegment = 0.8
    var chunkSeconds = 20.0
    var audioEventFilter = false
    var audioEventModel = ""
    var audioEventModelAvailable = false
    var audioEventThreshold = 0.45
    var audioEventFilterType: AudioEventFilterType = .repetition
    var audioEventPreset: AudioEventFilterPreset = .balanced
    var beamSize = 3
    var minConfidence = 0.0
    var lineChars = 18
    var softmaxSmoothing = 1.25
    var lengthPenalty = 0.6
    var eosPenalty = 1.0
    var decodeMaxLen = 0
    var diarizeSpeakers = false
    var alignWords = false
    var punctuate = false
    var denoise = false
    var asrContext = ""
    var speakerLabelingEngine: SpeakerLabelingEngine = .acoustic
    var speakerClusteringMethod: SpeakerClusteringMethod = .spectral
    var speakerRecognitionModel = ""
    var speakerRecognitionModelAvailable = false
    var speakerDiarizationCoreMLModel = ""
    var speakerDiarizationCoreMLModelAvailable = false
    var speakerClusterThreshold = 0.45
    var diarizationSpeakerCount = 0
    var emotionModel = ""
    var emotionModelAvailable = false
    var timelineSpeakerMarkersEnabled = true
    var waveformResolution: WaveformResolution = .high
    var appleSpeechFastResults = false
    var appleSpeechEtiquetteFilter = false
    var customPresets: [CustomRecognitionPreset] = []

    @ObservationIgnored private var pendingSaveTask: Task<Void, Never>?

    init() {
        loadCustomPresets()
        beginObservingForPersistence()
    }

    func apply(config: AppConfig) {
        modelCatalog = config.models ?? []
        vadCatalog = config.vadEngines ?? []
        asrEngine = sanitizedASREngine(config.defaultASREngine ?? .fireredasr2)
        vadEngine = sanitizedVADEngine(config.defaultVADEngine ?? .pyannoteMLX)
        model = config.defaultModel
        emotionModel = config.defaultEmotionModel ?? "mlx-community/emotion2vec-plus-large-mlx"
        emotionModelAvailable = config.emotionModelAvailable ?? false
        audioEventModel = config.defaultAudioEventModel ?? "panns-cnn14-16k-mlx"
        audioEventModelAvailable = config.audioEventModelAvailable ?? false
        speakerLabelingEngine = config.defaultSpeakerLabelingEngine ?? .acoustic
        speakerClusteringMethod = sanitizedSpeakerClusteringMethod(config.defaultSpeakerClusteringMethod ?? .spectral)
        speakerRecognitionModel = config.defaultSpeakerRecognitionModel ?? "iic/speech_eres2netv2_sv_zh-cn_16k-common"
        speakerRecognitionModelAvailable = config.speakerRecognitionModelAvailable ?? false
        speakerDiarizationCoreMLModel = config.localSpeakerDiarizationCoreMLModel ?? ""
        speakerDiarizationCoreMLModelAvailable = config.speakerDiarizationCoreMLModelAvailable ?? false
        if !restorePersistedSettings() {
            applyModelSpecificDefaults()
        }
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
        if lowercasedModel.contains("mega-asr")
            || lowercasedModel.contains("mega_asr")
            || lowercasedModel.contains("qwen3-asr") {
            return .mega
        }
        return .fireredasr2
    }

    var effectiveVADEngine: VADEngine {
        guard segmentMode == .vad else { return .energy }
        if vadEngine != .auto {
            return vadEngine
        }
        return preferredVADEngine()
    }

    var isSenseVoiceActive: Bool {
        effectiveASREngine == .sensevoice
    }

    var isMiMoActive: Bool {
        effectiveASREngine == .mimo
    }

    var isMegaASRActive: Bool {
        effectiveASREngine == .mega
    }

    var usesQwenGenerationControls: Bool {
        isMiMoActive || isMegaASRActive
    }

    var generationMaxTokensRange: ClosedRange<Int> {
        isMegaASRActive ? 1...8192 : 1...4096
    }

    var isFireRedVADActive: Bool {
        segmentMode == .vad && effectiveVADEngine == .firered
    }

    var currentModelInfo: ASRModelInfo? {
        modelCatalog.first { $0.engine == effectiveASREngine }
    }

    var currentVADInfo: VADModelInfo? {
        vadCatalog.first { $0.engine == effectiveVADEngine }
    }

    var supportedRecognitionLanguages: [RecognitionLanguage] {
        switch effectiveASREngine {
        case .sensevoice:
            return [.auto, .zh, .en, .yue, .ja, .ko, .nospeech]
        case .mimo:
            return [.zh, .en]
        case .mega:
            return [
                .auto,
                .zh,
                .en,
                .yue,
                .ar,
                .de,
                .fr,
                .es,
                .pt,
                .indonesian,
                .it,
                .ko,
                .ru,
                .th,
                .vi,
                .ja,
                .tr,
                .hi,
                .ms,
                .nl,
                .sv,
                .da,
                .fi,
                .pl,
                .cs,
                .fil,
                .fa,
                .el,
                .ro,
                .hu,
                .mk,
            ]
        case .apple:
            return [.zh, .en, .yue, .ja, .ko]
        case .fireredasr2, .auto:
            return [.auto]
        }
    }

    var usesBackendRecognition: Bool {
        !effectiveASREngine.isLocal
    }

    var usesFireRedDecodingControls: Bool {
        effectiveASREngine == .fireredasr2
    }

    var usesSenseVoiceRichInfo: Bool {
        usesBackendRecognition
    }

    func selectASREngine(_ engine: ASREngine) {
        asrEngine = sanitizedASREngine(engine)
        applyDefaultModelForSelectedEngine()
        applyModelSpecificDefaults()
    }

    func modelPathDidChange() {
        if asrEngine == .auto {
            applyModelSpecificDefaults()
        }
    }

    func applyDefaultModelForSelectedEngine() {
        if asrEngine == .apple {
            model = ""
            return
        }
        guard asrEngine != .auto,
              let modelInfo = modelCatalog.first(where: { $0.engine == asrEngine }) else {
            return
        }
        model = modelInfo.defaultModel
    }

    func applyModelSpecificDefaults() {
        let supportedLanguages = supportedRecognitionLanguages
        if !supportedLanguages.contains(recognitionLanguage) {
            recognitionLanguage = supportedLanguages.first ?? .auto
        }

        switch effectiveASREngine {
        case .sensevoice:
            senseVoiceUseITN = true
        case .mimo:
            mimoTemperature = Self.mimoDefaultTemperature
            mimoTopP = Self.mimoDefaultTopP
            mimoTopK = Self.mimoDefaultTopK
            if mimoMaxTokens < 1 {
                mimoMaxTokens = Self.mimoDefaultMaxTokens
            }
        case .mega:
            mimoTemperature = Self.megaDefaultTemperature
            mimoTopP = Self.megaDefaultTopP
            mimoTopK = Self.megaDefaultTopK
            if mimoMaxTokens < 1 || mimoMaxTokens == Self.mimoDefaultMaxTokens || mimoMaxTokens == 8192 {
                mimoMaxTokens = Self.megaDefaultMaxTokens
            }
        case .apple:
            senseVoiceRichInfo = false
            diarizeSpeakers = false
        case .fireredasr2, .auto:
            break
        }
    }

    func resetRecognitionDefaults() {
        segmentMode = .vad
        vadEngine = sanitizedVADEngine(.pyannoteMLX)
        recognitionLanguage = .auto
        senseVoiceUseITN = true
        senseVoiceRichInfo = false
        if effectiveASREngine == .mega {
            mimoMaxTokens = Self.megaDefaultMaxTokens
            mimoTemperature = Self.megaDefaultTemperature
            mimoTopP = Self.megaDefaultTopP
            mimoTopK = Self.megaDefaultTopK
        } else {
            mimoMaxTokens = Self.mimoDefaultMaxTokens
            mimoTemperature = Self.mimoDefaultTemperature
            mimoTopP = Self.mimoDefaultTopP
            mimoTopK = Self.mimoDefaultTopK
        }
        vadThreshold = -38.0
        fireRedVADThreshold = 0.4
        fireRedVADSmoothWindow = 5
        vadMaxSegment = 5.0
        vadSilence = 0.28
        vadSearch = 0.75
        vadMinSpeech = 0.2
        vadPadding = 0.20
        vadMinSegment = 0.8
        chunkSeconds = 20.0
        audioEventFilter = false
        audioEventThreshold = 0.45
        audioEventFilterType = .repetition
        audioEventPreset = .balanced
        beamSize = 3
        minConfidence = 0.0
        lineChars = 18
        softmaxSmoothing = 1.25
        lengthPenalty = 0.6
        eosPenalty = 1.0
        decodeMaxLen = 0
        diarizeSpeakers = false
        alignWords = false
        punctuate = false
        denoise = false
        speakerLabelingEngine = .acoustic
        speakerClusteringMethod = .spectral
        speakerClusterThreshold = 0.82
        diarizationSpeakerCount = 0
    }

    var recognitionPresetSnapshot: RecognitionPresetSnapshot {
        RecognitionPresetSnapshot(settings: self)
    }

    func builtInPresetSnapshot(_ preset: RecognitionPreset) -> RecognitionPresetSnapshot {
        var snapshot = RecognitionPresetSnapshot.defaults(for: effectiveASREngine)
        snapshot.applyBuiltInPreset(preset, engine: effectiveASREngine)
        snapshot.vadEngine = sanitizedVADEngine(snapshot.vadEngine)
        snapshot.speakerClusteringMethod = sanitizedSpeakerClusteringMethod(snapshot.speakerClusteringMethod)
        return snapshot
    }

    func apply(snapshot: RecognitionPresetSnapshot) {
        segmentMode = snapshot.segmentMode
        vadEngine = sanitizedVADEngine(snapshot.vadEngine)
        recognitionLanguage = snapshot.recognitionLanguage
        senseVoiceUseITN = snapshot.senseVoiceUseITN
        senseVoiceRichInfo = snapshot.senseVoiceRichInfo
        mimoMaxTokens = snapshot.mimoMaxTokens
        mimoTemperature = snapshot.mimoTemperature
        mimoTopP = snapshot.mimoTopP
        mimoTopK = snapshot.mimoTopK
        vadThreshold = snapshot.vadThreshold
        fireRedVADThreshold = snapshot.fireRedVADThreshold
        fireRedVADSmoothWindow = snapshot.fireRedVADSmoothWindow
        vadMaxSegment = snapshot.vadMaxSegment
        vadSilence = snapshot.vadSilence
        vadSearch = snapshot.vadSearch
        vadMinSpeech = snapshot.vadMinSpeech
        vadPadding = abs(snapshot.vadPadding - 0.12) < 0.0001 ? 0.20 : snapshot.vadPadding
        vadMinSegment = snapshot.vadMinSegment
        chunkSeconds = snapshot.chunkSeconds
        audioEventFilter = snapshot.audioEventFilter ?? false
        audioEventThreshold = snapshot.audioEventThreshold ?? 0.45
        audioEventFilterType = snapshot.audioEventFilterType ?? .all
        audioEventPreset = snapshot.audioEventPreset ?? .balanced
        beamSize = snapshot.beamSize
        minConfidence = snapshot.minConfidence
        lineChars = snapshot.lineChars
        softmaxSmoothing = snapshot.softmaxSmoothing
        lengthPenalty = snapshot.lengthPenalty
        eosPenalty = snapshot.eosPenalty
        decodeMaxLen = snapshot.decodeMaxLen
        diarizeSpeakers = snapshot.diarizeSpeakers
        speakerLabelingEngine = snapshot.speakerLabelingEngine
        speakerClusteringMethod = sanitizedSpeakerClusteringMethod(snapshot.speakerClusteringMethod)
        speakerClusterThreshold = snapshot.speakerClusterThreshold
        diarizationSpeakerCount = snapshot.diarizationSpeakerCount
        applyModelSpecificDefaults()
    }

    func saveCustomPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let preset = CustomRecognitionPreset(
            id: UUID(),
            name: trimmed,
            snapshot: recognitionPresetSnapshot
        )
        customPresets.append(preset)
        saveCustomPresets()
    }

    func renameCustomPreset(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = customPresets.firstIndex(where: { $0.id == id }) else {
            return
        }
        customPresets[index].name = trimmed
        saveCustomPresets()
    }

    func deleteCustomPreset(id: UUID) {
        customPresets.removeAll { $0.id == id }
        saveCustomPresets()
    }

    func applyCustomPreset(id: UUID) {
        guard let preset = customPresets.first(where: { $0.id == id }) else { return }
        apply(snapshot: preset.snapshot)
    }

    private func loadCustomPresets() {
        guard let data = UserDefaults.standard.data(forKey: Self.customPresetsKey),
              let presets = try? JSONDecoder().decode([CustomRecognitionPreset].self, from: data) else {
            customPresets = []
            return
        }
        customPresets = presets
    }

    private func saveCustomPresets() {
        guard let data = try? JSONEncoder().encode(customPresets) else { return }
        UserDefaults.standard.set(data, forKey: Self.customPresetsKey)
    }

    private func sanitizedASREngine(_ engine: ASREngine) -> ASREngine {
        engine == .auto ? .fireredasr2 : engine
    }

    private func sanitizedVADEngine(_ engine: VADEngine) -> VADEngine {
        if engine == .auto {
            return preferredVADEngine()
        }
        if engine == .firered {
            if let fireRed = vadCatalog.first(where: { $0.engine == .firered }),
               !fireRed.localModelAvailable {
                return preferredVADEngine(excluding: .firered)
            }
            return engine
        }
        if engine == .pyannoteMLX,
           let pyannote = vadCatalog.first(where: { $0.engine == .pyannoteMLX }),
           !pyannote.localModelAvailable {
            return preferredVADEngine(excluding: .pyannoteMLX)
        }
        return engine
    }

    private func preferredVADEngine(excluding excluded: VADEngine? = nil) -> VADEngine {
        for engine in [VADEngine.pyannoteMLX, .firered, .energy] where engine != excluded {
            if engine == .energy {
                return .energy
            }
            if let info = vadCatalog.first(where: { $0.engine == engine }) {
                if info.localModelAvailable {
                    return engine
                }
            }
        }
        return .energy
    }

    private func sanitizedSpeakerClusteringMethod(_ method: SpeakerClusteringMethod) -> SpeakerClusteringMethod {
        method == .auto ? .spectral : method
    }

    func savePersistedSettings() {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        performImmediateSave()
    }

    private func performImmediateSave() {
        let snapshot = PersistedTranscriptionSettings(settings: self)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: Self.persistedSettingsKey)
    }

    private func scheduleDebouncedSave() {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled, let self else { return }
            self.performImmediateSave()
        }
    }

    private func beginObservingForPersistence() {
        withObservationTracking {
            _ = PersistedTranscriptionSettings(settings: self)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scheduleDebouncedSave()
                self.beginObservingForPersistence()
            }
        }
    }

    @discardableResult
    func restorePersistedSettings() -> Bool {
        guard let data = UserDefaults.standard.data(forKey: Self.persistedSettingsKey),
              let snapshot = try? JSONDecoder().decode(PersistedTranscriptionSettings.self, from: data) else {
            return false
        }
        format = snapshot.format
        asrEngine = sanitizedASREngine(snapshot.asrEngine)
        let restoredModel = snapshot.model.trimmingCharacters(in: .whitespacesAndNewlines)
        model = restoredModel.isEmpty ? model : restoredModel
        recognitionLanguage = snapshot.recognitionLanguage
        senseVoiceUseITN = snapshot.senseVoiceUseITN
        senseVoiceRichInfo = snapshot.senseVoiceRichInfo
        mimoMaxTokens = snapshot.mimoMaxTokens
        mimoTemperature = snapshot.mimoTemperature
        mimoTopP = snapshot.mimoTopP
        mimoTopK = snapshot.mimoTopK
        segmentMode = snapshot.segmentMode
        vadEngine = sanitizedVADEngine(snapshot.vadEngine)
        vadThreshold = snapshot.vadThreshold
        fireRedVADThreshold = snapshot.fireRedVADThreshold
        fireRedVADSmoothWindow = snapshot.fireRedVADSmoothWindow
        vadMaxSegment = snapshot.vadMaxSegment
        vadSilence = snapshot.vadSilence
        vadSearch = snapshot.vadSearch
        vadMinSpeech = snapshot.vadMinSpeech
        vadPadding = abs(snapshot.vadPadding - 0.12) < 0.0001 ? 0.20 : snapshot.vadPadding
        vadMinSegment = snapshot.vadMinSegment
        chunkSeconds = snapshot.chunkSeconds
        audioEventFilter = snapshot.audioEventFilter ?? false
        if let audioEventModel = snapshot.audioEventModel?.trimmingCharacters(in: .whitespacesAndNewlines),
           !audioEventModel.isEmpty {
            self.audioEventModel = audioEventModel
        }
        audioEventThreshold = snapshot.audioEventThreshold ?? 0.45
        audioEventFilterType = snapshot.audioEventFilterType ?? .all
        audioEventPreset = snapshot.audioEventPreset ?? .balanced
        beamSize = snapshot.beamSize
        minConfidence = snapshot.minConfidence
        lineChars = snapshot.lineChars
        softmaxSmoothing = snapshot.softmaxSmoothing
        lengthPenalty = snapshot.lengthPenalty
        eosPenalty = snapshot.eosPenalty
        decodeMaxLen = snapshot.decodeMaxLen
        diarizeSpeakers = snapshot.diarizeSpeakers
        alignWords = snapshot.alignWords ?? false
        punctuate = snapshot.punctuate ?? false
        denoise = snapshot.denoise ?? false
        asrContext = snapshot.asrContext ?? ""
        speakerLabelingEngine = snapshot.speakerLabelingEngine
        speakerClusteringMethod = sanitizedSpeakerClusteringMethod(snapshot.speakerClusteringMethod)
        speakerRecognitionModel = snapshot.speakerRecognitionModel.isEmpty ? speakerRecognitionModel : snapshot.speakerRecognitionModel
        speakerClusterThreshold = snapshot.speakerClusterThreshold
        diarizationSpeakerCount = snapshot.diarizationSpeakerCount
        emotionModel = snapshot.emotionModel.isEmpty ? emotionModel : snapshot.emotionModel
        timelineSpeakerMarkersEnabled = snapshot.timelineSpeakerMarkersEnabled
        waveformResolution = snapshot.waveformResolution
        appleSpeechFastResults = snapshot.appleSpeechFastResults
        appleSpeechEtiquetteFilter = snapshot.appleSpeechEtiquetteFilter
        applyModelSpecificDefaults()
        return true
    }

    func applyPreset(_ preset: RecognitionPreset) {
        apply(snapshot: builtInPresetSnapshot(preset))
    }

    func formFields(includeOutput: Bool) -> [(String, String)] {
        var fields: [(String, String)] = [
            ("model", submittedModel),
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
            ("audio_event_filter", audioEventFilter ? "true" : "false"),
            ("audio_event_model", audioEventModel.trimmingCharacters(in: .whitespacesAndNewlines)),
            ("audio_event_threshold", "\(audioEventThreshold)"),
            ("audio_event_filter_type", audioEventFilterType.rawValue),
            ("audio_event_preset", audioEventPreset.rawValue),
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
                ("emotion_model", emotionModel),
                ("asr_context", asrContext.trimmingCharacters(in: .whitespacesAndNewlines)),
                ("align_words", alignWords ? "true" : "false"),
                ("punctuate", punctuate ? "true" : "false"),
                ("denoise", denoise ? "true" : "false"),
                ("diarize_speakers", diarizeSpeakers ? "true" : "false"),
                ("speaker_labeling_engine", speakerLabelingEngine.rawValue),
                ("speaker_recognition_model", speakerRecognitionModel),
                ("speaker_diarization_coreml_model", speakerDiarizationCoreMLModel),
                ("speaker_cluster_threshold", "\(speakerClusterThreshold)"),
                ("speaker_clustering_method", speakerClusteringMethod.rawValue),
                ("diarization_num_speakers", "\(diarizationSpeakerCount)")
            ])
        }

        return fields
    }

    private var submittedModel: String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return trimmed
        }
        return currentModelInfo?.defaultModel ?? trimmed
    }
}

struct CustomRecognitionPreset: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var snapshot: RecognitionPresetSnapshot
}

struct RecognitionPresetSnapshot: Codable, Equatable {
    var segmentMode: SegmentMode
    var vadEngine: VADEngine
    var recognitionLanguage: RecognitionLanguage
    var senseVoiceUseITN: Bool
    var senseVoiceRichInfo: Bool
    var mimoMaxTokens: Int
    var mimoTemperature: Double
    var mimoTopP: Double
    var mimoTopK: Int
    var vadThreshold: Double
    var fireRedVADThreshold: Double
    var fireRedVADSmoothWindow: Int
    var vadMaxSegment: Double
    var vadSilence: Double
    var vadSearch: Double
    var vadMinSpeech: Double
    var vadPadding: Double
    var vadMinSegment: Double
    var chunkSeconds: Double
    var audioEventFilter: Bool?
    var audioEventThreshold: Double?
    var audioEventFilterType: AudioEventFilterType?
    var audioEventPreset: AudioEventFilterPreset?
    var beamSize: Int
    var minConfidence: Double
    var lineChars: Int
    var softmaxSmoothing: Double
    var lengthPenalty: Double
    var eosPenalty: Double
    var decodeMaxLen: Int
    var diarizeSpeakers: Bool
    var speakerLabelingEngine: SpeakerLabelingEngine
    var speakerClusteringMethod: SpeakerClusteringMethod
    var speakerClusterThreshold: Double
    var diarizationSpeakerCount: Int

    @MainActor
    init(settings: TranscriptionSettings) {
        segmentMode = settings.segmentMode
        vadEngine = settings.vadEngine
        recognitionLanguage = settings.recognitionLanguage
        senseVoiceUseITN = settings.senseVoiceUseITN
        senseVoiceRichInfo = settings.senseVoiceRichInfo
        mimoMaxTokens = settings.mimoMaxTokens
        mimoTemperature = settings.mimoTemperature
        mimoTopP = settings.mimoTopP
        mimoTopK = settings.mimoTopK
        vadThreshold = settings.vadThreshold
        fireRedVADThreshold = settings.fireRedVADThreshold
        fireRedVADSmoothWindow = settings.fireRedVADSmoothWindow
        vadMaxSegment = settings.vadMaxSegment
        vadSilence = settings.vadSilence
        vadSearch = settings.vadSearch
        vadMinSpeech = settings.vadMinSpeech
        vadPadding = settings.vadPadding
        vadMinSegment = settings.vadMinSegment
        chunkSeconds = settings.chunkSeconds
        audioEventFilter = settings.audioEventFilter
        audioEventThreshold = settings.audioEventThreshold
        audioEventFilterType = settings.audioEventFilterType
        audioEventPreset = settings.audioEventPreset
        beamSize = settings.beamSize
        minConfidence = settings.minConfidence
        lineChars = settings.lineChars
        softmaxSmoothing = settings.softmaxSmoothing
        lengthPenalty = settings.lengthPenalty
        eosPenalty = settings.eosPenalty
        decodeMaxLen = settings.decodeMaxLen
        diarizeSpeakers = settings.diarizeSpeakers
        speakerLabelingEngine = settings.speakerLabelingEngine
        speakerClusteringMethod = settings.speakerClusteringMethod
        speakerClusterThreshold = settings.speakerClusterThreshold
        diarizationSpeakerCount = settings.diarizationSpeakerCount
    }

    static func defaults(for engine: ASREngine) -> RecognitionPresetSnapshot {
        var snapshot = RecognitionPresetSnapshot()
        snapshot.applyEnginePreset(.balanced, engine: engine)
        return snapshot
    }

    private init() {
        segmentMode = .vad
        vadEngine = .pyannoteMLX
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
        vadPadding = 0.20
        vadMinSegment = 0.8
        chunkSeconds = 20.0
        audioEventFilter = false
        audioEventThreshold = 0.45
        audioEventFilterType = .repetition
        audioEventPreset = .balanced
        beamSize = 3
        minConfidence = 0.0
        lineChars = 18
        softmaxSmoothing = 1.25
        lengthPenalty = 0.6
        eosPenalty = 1.0
        decodeMaxLen = 0
        diarizeSpeakers = false
        speakerLabelingEngine = .acoustic
        speakerClusteringMethod = .spectral
        speakerClusterThreshold = 0.82
        diarizationSpeakerCount = 0
    }

    mutating func applyBuiltInPreset(_ preset: RecognitionPreset, engine: ASREngine) {
        switch preset {
        case .balanced:
            break
        case .dialogue:
            vadThreshold = -39.0
            fireRedVADThreshold = 0.38
            fireRedVADSmoothWindow = 3
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
            fireRedVADThreshold = 0.3
            fireRedVADSmoothWindow = 7
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
            fireRedVADThreshold = 0.58
            fireRedVADSmoothWindow = 7
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
            fireRedVADThreshold = 0.46
            fireRedVADSmoothWindow = 3
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
            vadThreshold = -41.0
            fireRedVADThreshold = 0.34
            fireRedVADSmoothWindow = 7
            vadMaxSegment = 7.5
            vadSilence = 0.32
            vadSearch = 1.1
            vadMinSpeech = 0.12
            vadPadding = 0.22
            vadMinSegment = 0.7
            beamSize = 4
            minConfidence = 0.0
            lineChars = 18
            softmaxSmoothing = 1.25
            lengthPenalty = 0.6
            eosPenalty = 1.0
        }
        applyEnginePreset(preset, engine: engine)
    }

    private mutating func applyEnginePreset(_ preset: RecognitionPreset, engine: ASREngine) {
        switch engine {
        case .mimo:
            mimoTemperature = 0.0
            mimoTopP = 0.95
            mimoTopK = 0
            switch preset {
            case .balanced, .dialogue, .noisy:
                mimoMaxTokens = 256
            case .lowVoice, .sensitive:
                mimoMaxTokens = 320
            case .fastCut:
                mimoMaxTokens = 192
            }
        case .sensevoice:
            senseVoiceUseITN = true
        case .mega:
            mimoMaxTokens = 512
            mimoTemperature = 0.0
            mimoTopP = 1.0
            mimoTopK = 0
        case .fireredasr2, .auto, .apple:
            break
        }
    }
}

private struct PersistedTranscriptionSettings: Codable {
    var format: OutputFormat
    var asrEngine: ASREngine
    var model: String
    var recognitionLanguage: RecognitionLanguage
    var senseVoiceUseITN: Bool
    var senseVoiceRichInfo: Bool
    var mimoMaxTokens: Int
    var mimoTemperature: Double
    var mimoTopP: Double
    var mimoTopK: Int
    var segmentMode: SegmentMode
    var vadEngine: VADEngine
    var vadThreshold: Double
    var fireRedVADThreshold: Double
    var fireRedVADSmoothWindow: Int
    var vadMaxSegment: Double
    var vadSilence: Double
    var vadSearch: Double
    var vadMinSpeech: Double
    var vadPadding: Double
    var vadMinSegment: Double
    var chunkSeconds: Double
    var audioEventFilter: Bool?
    var audioEventModel: String?
    var audioEventThreshold: Double?
    var audioEventFilterType: AudioEventFilterType?
    var audioEventPreset: AudioEventFilterPreset?
    var beamSize: Int
    var minConfidence: Double
    var lineChars: Int
    var softmaxSmoothing: Double
    var lengthPenalty: Double
    var eosPenalty: Double
    var decodeMaxLen: Int
    var diarizeSpeakers: Bool
    var alignWords: Bool?
    var punctuate: Bool?
    var denoise: Bool?
    var asrContext: String?
    var speakerLabelingEngine: SpeakerLabelingEngine
    var speakerClusteringMethod: SpeakerClusteringMethod
    var speakerRecognitionModel: String
    var speakerClusterThreshold: Double
    var diarizationSpeakerCount: Int
    var emotionModel: String
    var timelineSpeakerMarkersEnabled: Bool
    var waveformResolution: WaveformResolution
    var appleSpeechFastResults: Bool
    var appleSpeechEtiquetteFilter: Bool

    @MainActor
    init(settings: TranscriptionSettings) {
        format = settings.format
        asrEngine = settings.asrEngine
        model = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        recognitionLanguage = settings.recognitionLanguage
        senseVoiceUseITN = settings.senseVoiceUseITN
        senseVoiceRichInfo = settings.senseVoiceRichInfo
        mimoMaxTokens = settings.mimoMaxTokens
        mimoTemperature = settings.mimoTemperature
        mimoTopP = settings.mimoTopP
        mimoTopK = settings.mimoTopK
        segmentMode = settings.segmentMode
        vadEngine = settings.vadEngine
        vadThreshold = settings.vadThreshold
        fireRedVADThreshold = settings.fireRedVADThreshold
        fireRedVADSmoothWindow = settings.fireRedVADSmoothWindow
        vadMaxSegment = settings.vadMaxSegment
        vadSilence = settings.vadSilence
        vadSearch = settings.vadSearch
        vadMinSpeech = settings.vadMinSpeech
        vadPadding = settings.vadPadding
        vadMinSegment = settings.vadMinSegment
        chunkSeconds = settings.chunkSeconds
        audioEventFilter = settings.audioEventFilter
        audioEventModel = settings.audioEventModel.trimmingCharacters(in: .whitespacesAndNewlines)
        audioEventThreshold = settings.audioEventThreshold
        audioEventFilterType = settings.audioEventFilterType
        audioEventPreset = settings.audioEventPreset
        beamSize = settings.beamSize
        minConfidence = settings.minConfidence
        lineChars = settings.lineChars
        softmaxSmoothing = settings.softmaxSmoothing
        lengthPenalty = settings.lengthPenalty
        eosPenalty = settings.eosPenalty
        decodeMaxLen = settings.decodeMaxLen
        diarizeSpeakers = settings.diarizeSpeakers
        alignWords = settings.alignWords
        punctuate = settings.punctuate
        denoise = settings.denoise
        asrContext = settings.asrContext
        speakerLabelingEngine = settings.speakerLabelingEngine
        speakerClusteringMethod = settings.speakerClusteringMethod
        speakerRecognitionModel = settings.speakerRecognitionModel
        speakerClusterThreshold = settings.speakerClusterThreshold
        diarizationSpeakerCount = settings.diarizationSpeakerCount
        emotionModel = settings.emotionModel
        timelineSpeakerMarkersEnabled = settings.timelineSpeakerMarkersEnabled
        waveformResolution = settings.waveformResolution
        appleSpeechFastResults = settings.appleSpeechFastResults
        appleSpeechEtiquetteFilter = settings.appleSpeechEtiquetteFilter
    }
}

enum WaveformResolution: String, CaseIterable, Codable, Identifiable {
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
