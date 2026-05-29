import Foundation

enum ASREngine: String, CaseIterable, Codable, Identifiable {
    case auto
    case fireredasr2
    case sensevoice
    case mimo

    var id: String { rawValue }

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
    case ja
    case ko
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

struct AppConfig: Decodable {
    let defaultModel: String
    let defaultOutputDir: String
    let defaultASREngine: ASREngine?
    let models: [ASRModelInfo]?
    let defaultVADEngine: VADEngine?
    let vadEngines: [VADModelInfo]?
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
    let output: String?
}

enum OutputFormat: String, CaseIterable, Identifiable {
    case srt
    case vtt
    case txt
    case json

    var id: String { rawValue }
    var title: String { rawValue.uppercased() }
}

enum SegmentMode: String, CaseIterable, Identifiable {
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
