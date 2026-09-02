import Foundation

enum ASREngine: String, CaseIterable, Codable, Identifiable {
    case auto
    case fireredasr2
    case sensevoice
    case mimo
    case mega
    case qwen3
    case funasr
    case apple

    var id: String { rawValue }

    var isLocal: Bool { self == .apple }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = ASREngine(rawValue: value) ?? .auto
    }
}

enum RecognitionLanguage: String, CaseIterable, Codable, Identifiable {
    case auto
    case zh
    case en
    case yue
    case ar
    case de
    case fr
    case es
    case pt
    case indonesian = "id"
    case it
    case ja
    case ko
    case ru
    case th
    case vi
    case tr
    case hi
    case ms
    case nl
    case sv
    case da
    case fi
    case pl
    case cs
    case fil
    case fa
    case el
    case ro
    case hu
    case mk
    case nospeech

    var id: String { rawValue }
}

enum VADEngine: String, CaseIterable, Codable, Identifiable {
    case auto
    case firered
    case pyannoteMLX = "pyannote_mlx"
    case energy

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = VADEngine(rawValue: value) ?? .auto
    }
}

enum SpeakerLabelingEngine: String, CaseIterable, Codable, Identifiable {
    case acoustic
    case coreml
    case pyannote
    case eres2netv2

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = SpeakerLabelingEngine(rawValue: value) ?? .acoustic
    }
}

enum SpeakerClusteringMethod: String, CaseIterable, Codable, Identifiable {
    case auto
    case spectral
    case incremental

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = SpeakerClusteringMethod(rawValue: value) ?? .auto
    }
}

enum AudioEventFilterType: String, CaseIterable, Codable, Identifiable {
    case all
    case nonLexical = "non_lexical"
    case nonSpeech = "non_speech"
    case repetition
    case lowSpeech = "low_speech"

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = AudioEventFilterType(rawValue: value) ?? .repetition
    }
}

enum AudioEventFilterPreset: String, CaseIterable, Codable, Identifiable {
    case balanced
    case strict
    case broad

    var id: String { rawValue }

    var defaultThreshold: Double {
        switch self {
        case .balanced: 0.45
        case .strict: 0.58
        case .broad: 0.34
        }
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = AudioEventFilterPreset(rawValue: value) ?? .balanced
    }
}

struct AppConfig: Decodable {
    let defaultModel: String
    let defaultOutputDir: String
    let defaultASREngine: ASREngine?
    let models: [ASRModelInfo]?
    let defaultVADEngine: VADEngine?
    let vadEngines: [VADModelInfo]?
    let defaultEmotionModel: String?
    let localEmotionModel: String?
    let emotionModelAvailable: Bool?
    let defaultAudioEventModel: String?
    let localAudioEventModel: String?
    let audioEventModelAvailable: Bool?
    let defaultSpeakerLabelingEngine: SpeakerLabelingEngine?
    let defaultSpeakerClusteringMethod: SpeakerClusteringMethod?
    let defaultSpeakerRecognitionModel: String?
    let localSpeakerRecognitionModel: String?
    let speakerRecognitionModelAvailable: Bool?
    let localSpeakerDiarizationCoreMLModel: String?
    let speakerDiarizationCoreMLModelAvailable: Bool?
}

struct ASRModelInfo: Decodable, Identifiable {
    let engine: ASREngine
    let title: String
    let defaultModel: String
    let localModel: String
    let localModelAvailable: Bool
    let supports: [String]

    var id: ASREngine { engine }
}

struct VADModelInfo: Decodable, Identifiable {
    let engine: VADEngine
    let title: String
    let defaultModel: String?
    let localModel: String?
    let localModelAvailable: Bool
    let supports: [String]

    var id: VADEngine { engine }
}

struct SegmentPreview: Decodable {
    let id: String?
    let previewId: String?
    let settingsKey: String?
    let duration: Double
    let count: Int
    let segments: [SubtitleSegment]
    let mediaInfo: MediaInfo?
}

struct AudioEventLabelScore: Codable, Equatable, Identifiable {
    let label: String
    let score: Double?

    var id: String { label }
}

struct SubtitleSegment: Codable, Identifiable, Equatable {
    let index: Int
    let start: Double
    let end: Double
    let duration: Double
    var audioLabel: String?
    var audioScore: Double?
    var audioLabels: [AudioEventLabelScore] = []
    var speechScore: Double?
    var repetitionScore: Double?
    var flagged: Bool = false

    var id: Int { index }

    init(
        index: Int,
        start: Double,
        end: Double,
        duration: Double,
        audioLabel: String? = nil,
        audioScore: Double? = nil,
        audioLabels: [AudioEventLabelScore] = [],
        speechScore: Double? = nil,
        repetitionScore: Double? = nil,
        flagged: Bool = false
    ) {
        self.index = index
        self.start = start
        self.end = end
        self.duration = duration
        self.audioLabel = audioLabel
        self.audioScore = audioScore
        self.audioLabels = audioLabels
        self.speechScore = speechScore
        self.repetitionScore = repetitionScore
        self.flagged = flagged
    }

    enum CodingKeys: String, CodingKey {
        case index
        case start
        case end
        case duration
        case audioLabel = "audio_label"
        case audioScore = "audio_score"
        case audioLabels = "audio_labels"
        case speechScore = "speech_score"
        case repetitionScore = "repetition_score"
        case flagged
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = try container.decode(Int.self, forKey: .index)
        start = try container.decode(Double.self, forKey: .start)
        end = try container.decode(Double.self, forKey: .end)
        duration = try container.decodeIfPresent(Double.self, forKey: .duration) ?? max(0, end - start)
        audioLabel = try container.decodeIfPresent(String.self, forKey: .audioLabel)
        audioScore = try container.decodeIfPresent(Double.self, forKey: .audioScore)
        audioLabels = try container.decodeIfPresent([AudioEventLabelScore].self, forKey: .audioLabels) ?? []
        speechScore = try container.decodeIfPresent(Double.self, forKey: .speechScore)
        repetitionScore = try container.decodeIfPresent(Double.self, forKey: .repetitionScore)
        flagged = try container.decodeIfPresent(Bool.self, forKey: .flagged) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(index, forKey: .index)
        try container.encode(start, forKey: .start)
        try container.encode(end, forKey: .end)
        try container.encode(duration, forKey: .duration)
        try container.encodeIfPresent(audioLabel, forKey: .audioLabel)
        try container.encodeIfPresent(audioScore, forKey: .audioScore)
        if !audioLabels.isEmpty {
            try container.encode(audioLabels, forKey: .audioLabels)
        }
        try container.encodeIfPresent(speechScore, forKey: .speechScore)
        try container.encodeIfPresent(repetitionScore, forKey: .repetitionScore)
        try container.encode(flagged, forKey: .flagged)
    }

    func reindexed(_ newIndex: Int) -> SubtitleSegment {
        SubtitleSegment(
            index: newIndex,
            start: start,
            end: end,
            duration: duration,
            audioLabel: audioLabel,
            audioScore: audioScore,
            audioLabels: audioLabels,
            speechScore: speechScore,
            repetitionScore: repetitionScore,
            flagged: flagged
        )
    }

    func withFlagged(_ isFlagged: Bool) -> SubtitleSegment {
        SubtitleSegment(
            index: index,
            start: start,
            end: end,
            duration: duration,
            audioLabel: audioLabel,
            audioScore: audioScore,
            audioLabels: audioLabels,
            speechScore: speechScore,
            repetitionScore: repetitionScore,
            flagged: isFlagged
        )
    }

    func withAudioEventMarker(label: String?, score: Double?, flagged isFlagged: Bool) -> SubtitleSegment {
        SubtitleSegment(
            index: index,
            start: start,
            end: end,
            duration: duration,
            audioLabel: label,
            audioScore: score,
            audioLabels: audioLabels,
            speechScore: speechScore,
            repetitionScore: repetitionScore,
            flagged: isFlagged
        )
    }
}

struct JobCreated: Decodable {
    let id: String
}

struct JobStatus: Decodable {
    let id: String
    let status: String
    let current: Int?
    let fractionalCurrent: Double?
    let total: Int?
    let phaseProgress: Double?
    let progressText: String?
    let cueCount: Int?
    let preview: String?
    let previewId: String?
    let settingsKey: String?
    let duration: Double?
    let count: Int?
    let segments: [SubtitleSegment]?
    let mediaInfo: MediaInfo?
    let error: String?
    let errorTrace: String?
    let output: String?
    let pauseRequested: Bool?
}

enum OutputFormat: String, CaseIterable, Codable, Identifiable {
    case srt
    case vtt
    case ass
    case txt
    case json

    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
}

enum SegmentMode: String, CaseIterable, Codable, Identifiable {
    case vad
    case fixed

    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
}

struct DownloadedOutput {
    let data: Data
    let filename: String
}

struct ManagedModelList: Decodable {
    let modelsDir: String
    let models: [ManagedModel]
}

struct ManagedModel: Decodable, Identifiable, Equatable {
    let name: String
    let repo: String?
    let feature: String
    let installed: Bool
    let sizeBytes: Int64
    let downloadable: Bool
    let downloadStatus: String?
    let downloadError: String?
    let downloadedBytes: Int64?
    let totalBytes: Int64?

    var id: String { name }
    var isDownloading: Bool { downloadStatus == "downloading" }

    var downloadFraction: Double? {
        guard isDownloading,
              let downloadedBytes,
              let totalBytes,
              totalBytes > 0 else { return nil }
        return min(1.0, Double(downloadedBytes) / Double(totalBytes))
    }
}

struct MediaInfo: Decodable, Equatable {
    var duration: Double? = nil
    var formatName: String? = nil
    var bitRate: Int64? = nil
    var videoCodec: String? = nil
    var width: Int? = nil
    var height: Int? = nil
    var frameRate: Double? = nil
    var videoBitRate: Int64? = nil
    var audioCodec: String? = nil
    var sampleRate: Int? = nil
    var channels: Int? = nil
    var audioBitRate: Int64? = nil
}
