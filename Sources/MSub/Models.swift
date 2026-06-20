import Foundation

enum ASREngine: String, CaseIterable, Codable, Identifiable {
    case auto
    case fireredasr2
    case sensevoice
    case mimo
    case mega
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
    case energy

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = VADEngine(rawValue: value) ?? .auto
    }
}

enum SpeakerLabelingEngine: String, CaseIterable, Codable, Identifiable {
    case pyannote
    case eres2netv2

    var id: String { rawValue }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = SpeakerLabelingEngine(rawValue: value) ?? .pyannote
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
    let defaultSpeakerLabelingEngine: SpeakerLabelingEngine?
    let defaultSpeakerClusteringMethod: SpeakerClusteringMethod?
    let defaultSpeakerRecognitionModel: String?
    let localSpeakerRecognitionModel: String?
    let speakerRecognitionModelAvailable: Bool?
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

struct SubtitleSegment: Decodable, Identifiable {
    let index: Int
    let start: Double
    let end: Double
    let duration: Double

    var id: Int { index }
}

struct JobCreated: Decodable {
    let id: String
}

struct JobStatus: Decodable {
    let id: String
    let status: String
    let current: Int?
    let total: Int?
    let progressText: String?
    let cueCount: Int?
    let preview: String?
    let error: String?
    let errorTrace: String?
    let output: String?
    let pauseRequested: Bool?
}

enum OutputFormat: String, CaseIterable, Codable, Identifiable {
    case srt
    case vtt
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
