import Foundation

struct AppConfig: Decodable {
    let defaultModel: String
    let defaultOutputDir: String
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
