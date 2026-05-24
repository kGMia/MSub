import AppKit
import AVFoundation
import CryptoKit
import NaturalLanguage
import SwiftUI

struct SubtitleCue: Identifiable, Codable, Equatable {
    var id = UUID()
    var index: Int
    var start: Double
    var end: Double
    var text: String
    var confidence: Double?

    var duration: Double {
        max(0, end - start)
    }
}

enum SubtitleDocument {
    static func parse(_ text: String, format: OutputFormat) -> [SubtitleCue] {
        switch format {
        case .srt, .vtt:
            parseTimedText(text)
        case .json:
            parseJSON(text)
        case .txt:
            []
        }
    }

    static func serialize(_ cues: [SubtitleCue], format: OutputFormat) -> String {
        let normalized = normalize(cues)
        switch format {
        case .srt:
            return normalized.map { cue in
                """
                \(cue.index)
                \(formatSRTTime(cue.start)) --> \(formatSRTTime(cue.end))
                \(cue.text.trimmingCharacters(in: .whitespacesAndNewlines))
                """
            }
            .joined(separator: "\n\n") + (normalized.isEmpty ? "" : "\n")

        case .vtt:
            let body = normalized.map { cue in
                """
                \(cue.index)
                \(formatVTTTime(cue.start)) --> \(formatVTTTime(cue.end))
                \(cue.text.trimmingCharacters(in: .whitespacesAndNewlines))
                """
            }
            .joined(separator: "\n\n")
            return "WEBVTT\n\n" + body + (normalized.isEmpty ? "" : "\n")

        case .txt:
            return normalized.map(\.text).joined(separator: "\n")

        case .json:
            let payload = SubtitleJSONPayload(
                text: normalized.map(\.text).joined(separator: "\n"),
                segments: normalized.map {
                    SubtitleJSONSegment(
                        index: $0.index,
                        start: $0.start,
                        end: $0.end,
                        text: $0.text,
                        confidence: $0.confidence
                    )
                }
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            guard let data = try? encoder.encode(payload),
                  let string = String(data: data, encoding: .utf8) else {
                return "{}\n"
            }
            return string + "\n"
        }
    }

    static func normalize(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        cues.sorted {
            if $0.start == $1.start {
                return $0.index < $1.index
            }
            return $0.start < $1.start
        }
        .enumerated()
        .map { offset, cue in
            var copy = cue
            copy.index = offset + 1
            copy.start = max(0, copy.start)
            copy.end = max(copy.start + 0.05, copy.end)
            return copy
        }
    }

    static func displayTime(_ seconds: Double) -> String {
        let safe = max(0, seconds)
        let minutes = Int(safe) / 60
        let remainder = safe - Double(minutes * 60)
        return String(format: "%02d:%05.2f", minutes, remainder)
    }

    private static func parseTimedText(_ text: String) -> [SubtitleCue] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalized.components(separatedBy: "\n\n")
        var cues: [SubtitleCue] = []

        for block in blocks {
            var lines = block
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            guard !lines.isEmpty else { continue }
            if lines.first?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "WEBVTT" {
                continue
            }
            if Int(lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") != nil {
                lines.removeFirst()
            }
            guard let timeIndex = lines.firstIndex(where: { $0.contains("-->") }) else {
                continue
            }
            let timeLine = lines[timeIndex]
            let parts = timeLine.components(separatedBy: "-->")
            guard parts.count >= 2,
                  let start = parseTime(parts[0]),
                  let end = parseTime(parts[1]) else {
                continue
            }
            let textLines = lines.dropFirst(timeIndex + 1)
            let cueText = textLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cueText.isEmpty else { continue }
            cues.append(
                SubtitleCue(
                    index: cues.count + 1,
                    start: start,
                    end: max(start + 0.05, end),
                    text: cueText
                )
            )
        }
        return cues
    }

    private static func parseJSON(_ text: String) -> [SubtitleCue] {
        guard let data = text.data(using: .utf8),
              let payload = try? JSONDecoder().decode(SubtitleJSONPayload.self, from: data) else {
            return []
        }
        return payload.segments.map {
            SubtitleCue(
                index: $0.index,
                start: $0.start,
                end: $0.end,
                text: $0.text,
                confidence: $0.confidence
            )
        }
    }

    private static func parseTime(_ raw: String) -> Double? {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .first?
            .replacingOccurrences(of: ",", with: ".") ?? ""
        let parts = cleaned.split(separator: ":").map(String.init)
        guard let last = parts.last, let seconds = Double(last) else { return nil }
        if parts.count == 3 {
            guard let hours = Double(parts[0]), let minutes = Double(parts[1]) else { return nil }
            return hours * 3600 + minutes * 60 + seconds
        }
        if parts.count == 2 {
            guard let minutes = Double(parts[0]) else { return nil }
            return minutes * 60 + seconds
        }
        return seconds
    }

    private static func formatSRTTime(_ seconds: Double) -> String {
        let parts = timeParts(seconds)
        return String(format: "%02d:%02d:%02d,%03d", parts.hours, parts.minutes, parts.seconds, parts.milliseconds)
    }

    private static func formatVTTTime(_ seconds: Double) -> String {
        let parts = timeParts(seconds)
        return String(format: "%02d:%02d:%02d.%03d", parts.hours, parts.minutes, parts.seconds, parts.milliseconds)
    }

    private static func timeParts(_ seconds: Double) -> (hours: Int, minutes: Int, seconds: Int, milliseconds: Int) {
        let safe = max(0, seconds)
        let totalMilliseconds = Int((safe * 1000).rounded())
        let hours = totalMilliseconds / 3_600_000
        let minutes = (totalMilliseconds % 3_600_000) / 60_000
        let wholeSeconds = (totalMilliseconds % 60_000) / 1000
        let milliseconds = totalMilliseconds % 1000
        return (hours, minutes, wholeSeconds, milliseconds)
    }
}

private struct SubtitleJSONPayload: Codable {
    var text: String
    var segments: [SubtitleJSONSegment]
}

private struct SubtitleJSONSegment: Codable {
    var index: Int
    var start: Double
    var end: Double
    var text: String
    var confidence: Double?
}

struct SubtitleTermFrequency: Identifiable, Equatable, Sendable {
    let term: String
    let count: Int

    var id: String { term }
}

enum SubtitleTextStats {
    static func topTerms(in text: String, limit: Int = 8) -> [SubtitleTermFrequency] {
        let cleanText = stripMarkup(from: text)
        var counts: [String: Int] = [:]
        for token in tokenize(cleanText) where !stopWords.contains(token) {
            counts[token, default: 0] += 1
        }
        return counts
            .map { SubtitleTermFrequency(term: $0.key, count: $0.value) }
            .sorted {
                if $0.count == $1.count {
                    return $0.term < $1.term
                }
                return $0.count > $1.count
            }
            .prefix(limit)
            .map { $0 }
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "that", "this", "with", "you", "your", "are", "was", "were",
        "have", "has", "had", "not", "but", "from", "can", "will", "just", "about",
        "what", "when", "where", "which", "there", "their", "they", "them", "then",
        "than", "into", "onto", "also", "very", "more", "most", "some", "such", "only",
        "been", "being", "does", "did", "done", "too", "all", "our", "out", "who",
        "一个", "这个", "那个", "就是", "然后", "因为", "所以", "但是", "如果", "还是",
        "没有", "不是", "什么", "现在", "一下", "可以", "我们", "你们", "他们", "的话",
        "以及", "或者", "这里", "那里", "这样", "这种", "这些", "那些", "已经", "进行",
        "する", "いる", "ある", "これ", "それ", "ため", "よう", "こと", "もの", "さん",
        "です", "ます", "した", "して", "から", "まで", "では", "でも", "そして", "しかし"
    ]

    private static func tokenize(_ text: String) -> [String] {
        let naturalTokens = naturalLanguageTokens(in: text)
        if !naturalTokens.isEmpty {
            return naturalTokens
        }

        return fallbackTokens(in: text)
    }

    private static func stripMarkup(from text: String) -> String {
        text.replacingOccurrences(
            of: #"</?(?:b|i|u|font)\b[^>]*>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private static func naturalLanguageTokens(in text: String) -> [String] {
        let language = dominantLanguage(in: text)
        let tokenizerTokens = tokenizerTerms(in: text, language: language)
        let taggerTokens = taggerTerms(in: text, language: language)
        if taggerTokens.count >= tokenizerTokens.count / 2 {
            return taggerTokens
        }
        return tokenizerTokens
    }

    private static func dominantLanguage(in text: String) -> NLLanguage? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(4_000)))
        return recognizer.dominantLanguage
    }

    private static func tokenizerTerms(in text: String, language: NLLanguage?) -> [String] {
        let tokenizer = NLTokenizer(unit: .word)
        if let language {
            tokenizer.setLanguage(language)
        }
        tokenizer.string = text
        var tokens: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let token = normalizedToken(String(text[range]))
            if shouldKeepToken(token) {
                tokens.append(token)
            }
            return true
        }
        return tokens
    }

    private static func taggerTerms(in text: String, language: NLLanguage?) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        tagger.string = text
        if let language {
            tagger.setLanguage(language, range: text.startIndex..<text.endIndex)
        }

        var tokens: [String] = []
        let options: NLTagger.Options = [.omitWhitespace, .omitPunctuation, .joinNames]
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .lexicalClass,
            options: options
        ) { tag, range in
            let rawToken = String(text[range])
            guard shouldKeepLexicalClass(tag, token: rawToken) else { return true }
            let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue
            let token = normalizedToken(lemma?.isEmpty == false ? lemma! : rawToken)
            if shouldKeepToken(token) {
                tokens.append(token)
            }
            return true
        }
        return tokens
    }

    private static func shouldKeepLexicalClass(_ tag: NLTag?, token: String) -> Bool {
        if token.unicodeScalars.contains(where: { isHan($0) || isKana($0) || isHangul($0) }) {
            return true
        }
        guard let tag else { return true }
        switch tag {
        case .noun, .verb, .adjective, .adverb, .personalName, .placeName, .organizationName:
            return true
        default:
            return false
        }
    }

    private static func fallbackTokens(in text: String) -> [String] {
        var tokens: [String] = []
        var asciiBuffer = ""
        var hanBuffer = ""

        func flushASCII() {
            let token = asciiBuffer.lowercased()
            if token.count > 1 {
                tokens.append(token)
            }
            asciiBuffer = ""
        }

        func flushHan() {
            let characters = Array(hanBuffer)
            if characters.count == 2 {
                tokens.append(String(characters))
            } else if characters.count > 2 {
                for index in 0..<(characters.count - 1) {
                    tokens.append(String(characters[index...(index + 1)]))
                }
            }
            hanBuffer = ""
        }

        for scalar in text.unicodeScalars {
            if isHan(scalar) {
                flushASCII()
                hanBuffer.append(String(scalar))
            } else if isASCIIWord(scalar) {
                flushHan()
                asciiBuffer.append(String(scalar))
            } else {
                flushASCII()
                flushHan()
            }
        }
        flushASCII()
        flushHan()

        return tokens
    }

    private static func normalizedToken(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
            .lowercased()
    }

    private static func shouldKeepToken(_ token: String) -> Bool {
        guard token.count > 1 else { return false }
        if token.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }) {
            return false
        }
        return token.unicodeScalars.contains { scalar in
            isASCIIWord(scalar) || isHan(scalar) || isKana(scalar) || isHangul(scalar)
        }
    }

    private static func isASCIIWord(_ scalar: Unicode.Scalar) -> Bool {
        (65...90).contains(Int(scalar.value))
            || (97...122).contains(Int(scalar.value))
            || (48...57).contains(Int(scalar.value))
    }

    private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x4E00...0x9FFF).contains(value)
            || (0x3400...0x4DBF).contains(value)
            || (0x20000...0x2A6DF).contains(value)
            || (0x2A700...0x2B73F).contains(value)
            || (0x2B740...0x2B81F).contains(value)
            || (0x2B820...0x2CEAF).contains(value)
    }

    private static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0x3040...0x309F).contains(value)
            || (0x30A0...0x30FF).contains(value)
            || (0x31F0...0x31FF).contains(value)
    }

    private static func isHangul(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return (0xAC00...0xD7AF).contains(value)
            || (0x1100...0x11FF).contains(value)
            || (0x3130...0x318F).contains(value)
    }
}

extension FileSlot {
    var editableSubtitleText: String {
        if !cues.isEmpty {
            SubtitleDocument.serialize(cues, format: outputFormat)
        } else {
            previewText
        }
    }

    var hasEditableSubtitle: Bool {
        if !cues.isEmpty {
            return true
        }
        return !previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var selectedCueStart: Double? {
        guard let selectedCueID,
              let cue = cues.first(where: { $0.id == selectedCueID }) else {
            return nil
        }
        return cue.start
    }
}

// MARK: - Shared playback controller

@MainActor
final class PlaybackController: ObservableObject {
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var hasVideo: Bool = false

    nonisolated let player = AVPlayer()

    nonisolated(unsafe) private var timeObserverToken: Any?
    private var rateObservation: NSKeyValueObservation?
    private var currentURL: URL?
    private var playbackEndTime: Double?

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        attachObservers()
    }

    deinit {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
        }
    }

    func load(_ url: URL) async {
        if currentURL == url { return }
        currentURL = url
        currentTime = 0
        duration = 0
        hasVideo = false
        playbackEndTime = nil
        player.pause()
        player.replaceCurrentItem(with: nil)

        // For containers AVFoundation can't natively play (MKV, etc.) the player
        // would stall or stop early. Resolve to a clean extraction up front
        // so playback always traverses the full audio.
        let playbackURL = await AudioSource.resolve(url)
        guard currentURL == url else { return }

        let asset = AVURLAsset(url: playbackURL)
        let keys = ["duration", "tracks", "playable"]
        let item = AVPlayerItem(asset: asset, automaticallyLoadedAssetKeys: keys)
        
        player.replaceCurrentItem(with: item)

        do {
            let loadedDuration = try await asset.load(.duration)
            let seconds = loadedDuration.seconds
            if seconds.isFinite, seconds > 0 {
                duration = seconds
            }
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            hasVideo = !videoTracks.isEmpty
        } catch {
            print("PlaybackController: Failed to load asset metadata: \(error)")
        }
    }

    func seek(to seconds: Double, pause: Bool = false) {
        let target = max(0, seconds.isFinite ? seconds : 0)
        let clamped = duration > 0 ? min(target, duration) : target
        currentTime = clamped
        if pause {
            playbackEndTime = nil
            player.pause()
        }
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func scrub(to seconds: Double) {
        let target = max(0, seconds.isFinite ? seconds : 0)
        let clamped = duration > 0 ? min(target, duration) : target
        currentTime = clamped
        playbackEndTime = nil
        player.pause()
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        let tolerance = CMTime(seconds: 0.08, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    func togglePlayPause() {
        if player.timeControlStatus == .playing {
            playbackEndTime = nil
            player.pause()
        } else {
            playbackEndTime = nil
            player.play()
        }
    }

    func playRange(start: Double, end: Double) {
        guard end > start else { return }
        playbackEndTime = end
        seek(to: start, pause: false)
        player.play()
    }

    private func attachObservers() {
        let interval = CMTime(seconds: 1.0 / 15.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            MainActor.assumeIsolated {
                guard let self else { return }
                if seconds.isFinite {
                    self.currentTime = max(0, seconds)
                }
                if let endTime = self.playbackEndTime, seconds >= endTime {
                    self.seek(to: endTime, pause: true)
                }
            }
        }
        rateObservation = player.observe(\.rate, options: [.initial, .new]) { [weak self] player, _ in
            let playing = player.rate != 0
            Task { @MainActor in
                self?.isPlaying = playing
            }
        }
    }
}

struct SubtitleEditorPanel: View {
    @Binding var slot: FileSlot
    @Binding var selectedFrequentTerm: String?
    let language: AppLanguage
    @ObservedObject var playback: PlaybackController

    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var backend: BackendService
    @EnvironmentObject private var settings: TranscriptionSettings

    @State private var waveform = WaveformSamples([])
    @State private var isLoadingWaveform = false
    @State private var timelineZoom = 1.0
    @State private var findText = ""
    @State private var replacementText = ""
    @State private var matchCase = false
    @State private var findStatus = ""
    @State private var isFindReplaceExpanded = false
    @State private var isTimelineExpanded = false
    @State private var styleColor = Color.yellow
    @State private var selectedTextRange: NSRange?
    @State private var waveformSourceKey: String?
    @State private var previewSyncTask: Task<Void, Never>?
    @State private var termStatsTask: Task<Void, Never>?
    @State private var waveformReloadTask: Task<Void, Never>?
    @State private var transcribingCueID: SubtitleCue.ID?
    @State private var transcribeError: String?

    private static let waveformResolutionSteps = [720, 1_440, 2_880, 5_760, 11_520, 23_040, 46_080, 92_160, 131_072, 262_144, 524_288, 1_048_576]

    private var duration: Double {
        let cueEnd = slot.cues.map(\.end).max() ?? 0.001
        return max(slot.duration, cueEnd + 1.0)
    }

    private var selectedCueIndex: Int? {
        guard let selectedCueID = slot.selectedCueID else { return nil }
        return slot.cues.firstIndex(where: { $0.id == selectedCueID })
    }

    private var maxTimelineZoom: Double {
        max(8.0, ceil(duration / 4.0))
    }

    private var activeFindHighlightTerm: String? {
        guard isFindReplaceExpanded else { return nil }
        let trimmed = findText.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var waveformTargetSamples: Int {
        let zoom = max(timelineZoom, 1.0)
        let visibleSeconds = max(1.0, duration / zoom)
        let visibleTarget: Double
        if visibleSeconds <= 15 {
            visibleTarget = 1_600
        } else if visibleSeconds <= 60 {
            visibleTarget = 1_200
        } else if visibleSeconds <= 300 {
            visibleTarget = 900
        } else {
            visibleTarget = 720
        }
        let desired = Int(visibleTarget * zoom)
        return Self.waveformResolutionSteps.first { $0 >= desired } ?? Self.waveformResolutionSteps.last ?? 720
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if slot.cues.isEmpty {
                ContentUnavailableView(
                    Copy.text("editor.empty", language: language),
                    systemImage: "captions.bubble",
                    description: Text(Copy.text("editor.empty.help", language: language))
                )
                .frame(maxWidth: .infinity, minHeight: 280)
            } else {
                timelinePanel

                HStack(alignment: .top, spacing: 18) {
                    subtitleBlocks
                        .frame(minWidth: 240, maxWidth: .infinity)

                    VStack(spacing: 10) {
                        selectedCueEditor
                        findReplaceBar
                    }
                    .frame(width: 235)
                }
                .padding(.trailing, 6)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: slot.url) {
            await loadWaveformIfNeeded()
        }
        .onChange(of: isTimelineExpanded) { _, newValue in
            guard newValue else { return }
            scheduleWaveformReload(debounce: false)
        }
        .onChange(of: waveformTargetSamples) { _, _ in
            guard isTimelineExpanded else { return }
            scheduleWaveformReload(debounce: true)
        }
        .onChange(of: slot.cues.count) { _, newValue in
            if newValue == 0 {
                waveformReloadTask?.cancel()
                waveform = WaveformSamples([])
                waveformSourceKey = nil
                slot.selectedCueID = nil
            } else if isTimelineExpanded {
                ensureSelectedCueIsValid()
                scheduleWaveformReload(debounce: false)
            } else {
                ensureSelectedCueIsValid()
            }
        }
        .onChange(of: slot.selectedCueID) { _, newValue in
            guard let newValue,
                  let cue = slot.cues.first(where: { $0.id == newValue }) else { return }
            selectedTextRange = nil
            playback.seek(to: cue.start, pause: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .msubDeleteSelectedCueRequested)) { _ in
            guard let cueID = slot.selectedCueID else { return }
            deleteCue(cueID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .msubDuplicateSelectedCueRequested)) { _ in
            guard let cueID = slot.selectedCueID else { return }
            duplicateCue(cueID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .msubInsertCueBeforeRequested)) { _ in
            guard let cueID = slot.selectedCueID else { return }
            insertCue(before: cueID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .msubInsertCueAfterRequested)) { _ in
            guard let cueID = slot.selectedCueID else { return }
            insertCue(after: cueID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .msubResetSelectedCueRequested)) { _ in
            guard let cueID = slot.selectedCueID, canResetCue(cueID) else { return }
            resetCue(cueID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .msubToggleTimelineRequested)) { _ in
            withAnimation(.easeInOut(duration: 0.18)) {
                isTimelineExpanded.toggle()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .msubZoomTimelineInRequested)) { _ in
            guard isTimelineExpanded else { return }
            timelineZoom = min(maxTimelineZoom, timelineZoom + 0.5)
        }
        .onReceive(NotificationCenter.default.publisher(for: .msubZoomTimelineOutRequested)) { _ in
            guard isTimelineExpanded else { return }
            timelineZoom = max(1.0, timelineZoom - 0.5)
        }
        .onDisappear {
            previewSyncTask?.cancel()
            termStatsTask?.cancel()
            waveformReloadTask?.cancel()
            syncPreviewText(for: slot.cues)
        }
    }

    private var timecodeLabel: String {
        let current = SubtitleDocument.displayTime(playback.currentTime)
        let total = SubtitleDocument.displayTime(duration)
        return "\(current) / \(total)"
    }

    private func scheduleCueTimingSync(for cues: [SubtitleCue]) {
        previewSyncTask?.cancel()
        previewSyncTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            let normalized = SubtitleDocument.normalize(cues)
            if slot.cues.map(\.id) == cues.map(\.id), normalized != slot.cues {
                slot.cues = normalized
            }
            syncPreviewText(for: normalized)
        }
    }

    private func schedulePreviewTextSync(for cues: [SubtitleCue]) {
        previewSyncTask?.cancel()
        previewSyncTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled else { return }
            syncPreviewText(for: cues)
        }
    }

    private func syncPreviewText(for cues: [SubtitleCue]) {
        slot.previewText = SubtitleDocument.serialize(cues, format: slot.outputFormat)
    }

    private func ensureSelectedCueIsValid() {
        guard let selectedCueID = slot.selectedCueID else { return }
        if !slot.cues.contains(where: { $0.id == selectedCueID }) {
            slot.selectedCueID = slot.cues.first?.id
        }
    }

    private func scheduleTermStatsSync(for cues: [SubtitleCue]) {
        let text = cues.map(\.text).joined(separator: " ")
        termStatsTask?.cancel()
        termStatsTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            let terms = await Task.detached(priority: .utility) {
                SubtitleTextStats.topTerms(in: text, limit: 8)
            }.value
            guard !Task.isCancelled else { return }
            slot.frequentTerms = terms
        }
    }

    private var timelinePanel: some View {
        VStack(alignment: .leading, spacing: isTimelineExpanded ? 8 : 6) {
            HStack {
                Label(Copy.text("editor.timeline", language: language), systemImage: "waveform")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if isLoadingWaveform {
                    ProgressView()
                        .controlSize(.small)
                }
                if !isTimelineExpanded {
                    Button {
                        playback.togglePlayPause()
                    } label: {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.borderless)
                    .help(Copy.text(playback.isPlaying ? "editor.pause" : "editor.play", language: language))
                }
                Text(timecodeLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isTimelineExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isTimelineExpanded ? "chevron.up.circle" : "chevron.down.circle")
                }
                .buttonStyle(.borderless)
                .help(Copy.text(isTimelineExpanded ? "editor.collapseTimeline" : "editor.expandTimeline", language: language))
            }

            if isTimelineExpanded {
                HStack(spacing: 8) {
                    Button {
                        timelineZoom = max(1.0, timelineZoom - 0.5)
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .help(Copy.text("editor.zoomOut", language: language))

                    TimelineZoomSlider(value: $timelineZoom, range: 1...maxTimelineZoom, step: 0.5)
                    .frame(maxWidth: 210)
                    .accessibilityLabel(Copy.text("editor.zoom", language: language))
                    .help(Copy.text("editor.zoom", language: language))

                    Text(String(format: "%.1fx", timelineZoom))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 38, alignment: .trailing)

                    Button {
                        timelineZoom = min(maxTimelineZoom, timelineZoom + 0.5)
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .help(Copy.text("editor.zoomIn", language: language))

                    Spacer(minLength: 8)

                    Button {
                        playSelectedCue()
                    } label: {
                        Image(systemName: "play.rectangle")
                    }
                    .buttonStyle(.borderless)
                    .disabled(selectedCueIndex == nil)
                    .help(Copy.text("editor.playCurrent.help", language: language))

                    Button {
                        playback.togglePlayPause()
                    } label: {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.borderless)
                    .help(Copy.text(playback.isPlaying ? "editor.pause" : "editor.play", language: language))
                }

                ZoomableTimeline(
                    cues: $slot.cues,
                    selectedCueID: $slot.selectedCueID,
                    highlightTerm: $selectedFrequentTerm,
                    findTerm: activeFindHighlightTerm,
                    waveform: waveform,
                    duration: duration,
                    zoom: $timelineZoom,
                    zoomRange: 1...maxTimelineZoom,
                    currentTime: playback.currentTime,
                    language: language,
                    onSeek: { time in
                        playback.seek(to: time, pause: true)
                    },
                    onScrub: { time in
                        playback.scrub(to: time)
                    },
                    cueActions: timelineCueActions
                )
                .frame(height: 128)
            } else {
                CompactTimelineStrip(
                    cues: slot.cues,
                    selectedCueID: $slot.selectedCueID,
                    highlightTerm: $selectedFrequentTerm,
                    findTerm: activeFindHighlightTerm,
                    waveform: waveform,
                    duration: duration,
                    currentTime: playback.currentTime,
                    onSeek: { time in
                        playback.seek(to: time, pause: true)
                    }
                )
                .frame(height: 34)
            }
        }
        .padding(isTimelineExpanded ? 12 : 10)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10))
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: maxTimelineZoom) { _, newValue in
            timelineZoom = min(timelineZoom, newValue)
        }
    }

    private var subtitleBlocks: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach($slot.cues) { $cue in
                        SubtitleCueBlockRow(
                            cue: $cue,
                            isSelected: cue.id == slot.selectedCueID,
                            canReset: canResetCue(cue.id),
                            select: { slot.selectedCueID = cue.id },
                            reset: { resetCue(cue.id) },
                            duplicate: { duplicateCue(cue.id) },
                            insertBefore: { insertCue(before: cue.id) },
                            insertAfter: { insertCue(after: cue.id) },
                            closeGap: { closeGap(around: cue.id) },
                            delete: { deleteCue(cue.id) },
                            language: language
                        )
                        .id(cue.id)
                    }
                }
                .padding(2)
            }
            .frame(minHeight: 300, maxHeight: 520)
            .padding(2)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10))
            .onChange(of: slot.selectedCueID) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    private var findReplaceBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isFindReplaceExpanded.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Label(Copy.text("editor.findReplace", language: language), systemImage: "magnifyingglass")
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 8)
                    if !findText.isEmpty || !findStatus.isEmpty {
                        Text(findStatusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Image(systemName: isFindReplaceExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isFindReplaceExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    TextField(Copy.text("editor.find", language: language), text: $findText)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 8) {
                        Button {
                            findNext()
                        } label: {
                            Label(Copy.text("editor.findNext", language: language), systemImage: "arrow.down")
                        }
                        .labelStyle(.iconOnly)
                        .disabled(findText.isEmpty)
                        .help(Copy.text("editor.findNext.help", language: language))

                        Toggle(Copy.text("editor.matchCase", language: language), isOn: $matchCase)
                            .toggleStyle(.checkbox)
                            .font(.caption)
                            .fixedSize()

                        Spacer(minLength: 0)
                    }

                    TextField(Copy.text("editor.replace", language: language), text: $replacementText)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: 8) {
                        Button {
                            replaceCurrent()
                        } label: {
                            Label(Copy.text("editor.replaceCurrent", language: language), systemImage: "arrow.right.to.line")
                        }
                        .labelStyle(.iconOnly)
                        .disabled(findText.isEmpty)
                        .help(Copy.text("editor.replaceCurrent.help", language: language))

                        Button {
                            replaceAll()
                        } label: {
                            Label(Copy.text("editor.replaceAll", language: language), systemImage: "text.badge.checkmark")
                        }
                        .labelStyle(.iconOnly)
                        .disabled(findText.isEmpty)
                        .help(Copy.text("editor.replaceAll.help", language: language))

                        Spacer(minLength: 8)
                    }

                    Text(findStatusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .controlSize(.small)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10))
        .onChange(of: findText) { _, _ in
            findStatus = ""
        }
        .onChange(of: matchCase) { _, _ in
            findStatus = ""
        }
    }

    private var findStatusText: String {
        if !findStatus.isEmpty {
            return findStatus
        }
        guard !findText.isEmpty else {
            return Copy.text("editor.findHint", language: language)
        }
        return String(format: Copy.text("editor.findCount", language: language), occurrenceCount())
    }

    @ViewBuilder
    private var selectedCueEditor: some View {
        if let selectedCueIndex, slot.cues.indices.contains(selectedCueIndex) {
            VStack(alignment: .leading, spacing: 10) {
                Text(Copy.text("editor.selected", language: language))
                    .font(.subheadline.weight(.semibold))

                HStack(spacing: 6) {
                    Button {
                        selectPreviousCue()
                    } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 24)
                    }
                    .disabled(selectedCueIndex <= 0)
                    .help(Copy.text("editor.previous", language: language))

                    Button {
                        selectNextCue()
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 24)
                    }
                    .disabled(selectedCueIndex >= slot.cues.count - 1)
                    .help(Copy.text("editor.next", language: language))

                    Button {
                        insertCueAfterSelection()
                    } label: {
                        Image(systemName: "plus.rectangle.on.rectangle")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 24)
                    }
                    .help(Copy.text("editor.addAfter.help", language: language))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                let selectedCueID = slot.cues[selectedCueIndex].id
                SelectableTextEditor(text: cueTextBinding(for: selectedCueID), selection: $selectedTextRange) {}
                    .frame(height: 156)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))

                compactNumberField(
                    Copy.text("editor.start", language: language),
                    value: cueStartBinding(for: selectedCueID)
                )
                compactNumberField(
                    Copy.text("editor.end", language: language),
                    value: cueEndBinding(for: selectedCueID)
                )

                HStack {
                    Text(Copy.text("editor.duration", language: language))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.2fs", slot.cues[selectedCueIndex].duration))
                        .font(.caption.monospacedDigit().bold())
                }

                subtitleStyleControls

                reTranscribeCueButton(cueID: selectedCueID, cueIsEmpty: slot.cues[selectedCueIndex].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    resetSelectedCue()
                } label: {
                    Label(Copy.text("editor.resetCue", language: language), systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canResetSelectedCue)
                .help(Copy.text("editor.resetCue.help", language: language))
            }
            .padding(12)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(Copy.text("editor.selected", language: language))
                    .font(.subheadline.weight(.semibold))
                Text(Copy.text("editor.selectHelp", language: language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    @ViewBuilder
    private func reTranscribeCueButton(cueID: SubtitleCue.ID, cueIsEmpty: Bool) -> some View {
        let isBusy = transcribingCueID == cueID
        VStack(alignment: .leading, spacing: 4) {
            Button {
                Task { await reTranscribeSelectedCue() }
            } label: {
                if isBusy {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text(Copy.text("editor.transcribingCue", language: language))
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    Label(
                        Copy.text(
                            cueIsEmpty ? "editor.recognizeCue" : "editor.reRecognizeCue",
                            language: language
                        ),
                        systemImage: "waveform.and.mic"
                    )
                    .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(transcribingCueID != nil)
            .help(Copy.text("editor.recognizeCue.help", language: language))

            if let transcribeError, !isBusy {
                Text(String(format: Copy.text("editor.recognizeCue.failed", language: language), transcribeError))
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var subtitleStyleControls: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(Copy.text("editor.style", language: language))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                Button {
                    toggleMarkupTag("b")
                } label: {
                    Image(systemName: "bold")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.bordered)
                .tint(hasOuterMarkupTag("b") ? .accentColor : nil)
                .help(Copy.text("editor.style.bold.help", language: language))

                Button {
                    toggleMarkupTag("i")
                } label: {
                    Image(systemName: "italic")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.bordered)
                .tint(hasOuterMarkupTag("i") ? .accentColor : nil)
                .help(Copy.text("editor.style.italic.help", language: language))

                Button {
                    toggleMarkupTag("u")
                } label: {
                    Image(systemName: "underline")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.bordered)
                .tint(hasOuterMarkupTag("u") ? .accentColor : nil)
                .help(Copy.text("editor.style.underline.help", language: language))

                ColorPicker("", selection: $styleColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 30)
                    .help(Copy.text("editor.style.color.help", language: language))

                Button {
                    applyCueColor(styleColor)
                } label: {
                    Image(systemName: "paintpalette")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.bordered)
                .tint(hasOuterFontColor ? .accentColor : nil)
                .help(Copy.text("editor.style.applyColor.help", language: language))

                Button {
                    clearCueStyle()
                } label: {
                    Image(systemName: "eraser")
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.bordered)
                .help(Copy.text("editor.style.clear.help", language: language))
            }
            .controlSize(.small)
        }
    }

    private func compactNumberField(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField(title, value: value, format: .number.precision(.fractionLength(2)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .font(.caption.monospacedDigit())
        }
    }

    private func cueStartBinding(for cueID: SubtitleCue.ID) -> Binding<Double> {
        Binding(
            get: {
                guard let index = cueIndex(for: cueID) else { return 0 }
                return slot.cues[index].start
            },
            set: { newValue in
                guard let index = cueIndex(for: cueID) else { return }
                slot.cues[index].start = max(0, min(newValue, slot.cues[index].end - 0.05))
                scheduleCueTimingSync(for: slot.cues)
            }
        )
    }

    private func cueTextBinding(for cueID: SubtitleCue.ID) -> Binding<String> {
        Binding(
            get: {
                guard let index = cueIndex(for: cueID) else { return "" }
                return slot.cues[index].text
            },
            set: { newValue in
                guard let index = cueIndex(for: cueID) else { return }
                slot.cues[index].text = newValue
                schedulePreviewTextSync(for: slot.cues)
                scheduleTermStatsSync(for: slot.cues)
            }
        )
    }

    private func cueEndBinding(for cueID: SubtitleCue.ID) -> Binding<Double> {
        Binding(
            get: {
                guard let index = cueIndex(for: cueID) else { return 0 }
                return slot.cues[index].end
            },
            set: { newValue in
                guard let index = cueIndex(for: cueID) else { return }
                let upper = duration > 0 ? duration : newValue
                slot.cues[index].end = max(slot.cues[index].start + 0.05, min(upper, newValue))
                scheduleCueTimingSync(for: slot.cues)
            }
        )
    }

    private func scheduleWaveformReload(debounce: Bool) {
        waveformReloadTask?.cancel()
        waveformReloadTask = Task { @MainActor in
            if debounce {
                try? await Task.sleep(for: .milliseconds(140))
                guard !Task.isCancelled else { return }
            }
            await loadWaveformIfNeeded()
        }
    }

    private func loadWaveformIfNeeded() async {
        let sourceKey = "\(slot.url.standardizedFileURL.path)#\(slot.duration)"
        // Load even when the timeline is collapsed — the compact strip also displays
        // the waveform, and loading early means expand-to-detail is instant.
        guard !slot.cues.isEmpty else {
            waveform = WaveformSamples([])
            waveformSourceKey = nil
            isLoadingWaveform = false
            return
        }
        let targetSamples = waveformTargetSamples
        guard waveformSourceKey != sourceKey || waveform.values.count < targetSamples else { return }
        guard !isLoadingWaveform else { return }
        isLoadingWaveform = true
        // Containers AVAssetReader can't fully demux (e.g., MKV) would yield a
        // truncated waveform. Route through AudioSource so unsupported sources
        // are transparently transcoded to a clean m4a before sampling.
        let audioURL = await AudioSource.resolve(slot.url)
        let values = await WaveformLoader.samples(for: audioURL, targetSamples: targetSamples)
        guard !Task.isCancelled else {
            isLoadingWaveform = false
            return
        }
        waveform = WaveformSamples(values)
        waveformSourceKey = sourceKey
        let needsHigherResolution = waveformTargetSamples > targetSamples
        isLoadingWaveform = false
        if needsHigherResolution {
            scheduleWaveformReload(debounce: true)
        }
    }

    private func selectPreviousCue() {
        guard let selectedCueIndex, selectedCueIndex > 0 else { return }
        slot.selectedCueID = slot.cues[selectedCueIndex - 1].id
    }

    private func selectNextCue() {
        guard let selectedCueIndex, selectedCueIndex < slot.cues.count - 1 else { return }
        slot.selectedCueID = slot.cues[selectedCueIndex + 1].id
    }

    private func insertCueAfterSelection() {
        if let selectedCueID = slot.selectedCueID {
            insertCue(after: selectedCueID)
        } else {
            insertCue(at: slot.cues.count, start: 0, end: 2, text: "")
        }
    }

    private var canResetSelectedCue: Bool {
        guard let selectedCueIndex,
              let original = originalCue(for: slot.cues[selectedCueIndex].id) else { return false }
        let current = slot.cues[selectedCueIndex]
        return current.start != original.start
            || current.end != original.end
            || current.text != original.text
            || current.confidence != original.confidence
    }

    private var timelineCueActions: TimelineCueActions {
        TimelineCueActions(
            canReset: { canResetCue($0) },
            reset: { resetCue($0) },
            duplicate: { duplicateCue($0) },
            insertBefore: { insertCue(before: $0) },
            insertAfter: { insertCue(after: $0) },
            closeGap: { closeGap(around: $0) },
            delete: { deleteCue($0) }
        )
    }

    private func canResetCue(_ cueID: SubtitleCue.ID) -> Bool {
        guard let index = cueIndex(for: cueID),
              let original = originalCue(for: cueID) else { return false }
        let current = slot.cues[index]
        return current.start != original.start
            || current.end != original.end
            || current.text != original.text
            || current.confidence != original.confidence
    }

    private func originalCue(for cueID: SubtitleCue.ID) -> SubtitleCue? {
        slot.originalCues.first { $0.id == cueID }
    }

    private func cueIndex(for cueID: SubtitleCue.ID) -> Int? {
        slot.cues.firstIndex { $0.id == cueID }
    }

    private func resetSelectedCue() {
        guard let selectedCueID = slot.selectedCueID else { return }
        resetCue(selectedCueID)
    }

    private func reTranscribeSelectedCue() async {
        guard let selectedCueIndex,
              slot.cues.indices.contains(selectedCueIndex) else { return }
        let cue = slot.cues[selectedCueIndex]
        let cueID = cue.id
        guard transcribingCueID == nil else { return }

        transcribingCueID = cueID
        transcribeError = nil
        defer { if transcribingCueID == cueID { transcribingCueID = nil } }

        let isReady = await backend.ensureRunning(timeout: 25.0)
        api.baseURL = backend.baseURL
        guard isReady else {
            transcribeError = backend.message
            return
        }

        guard let clipURL = await extractCueClip(start: cue.start, end: cue.end) else {
            transcribeError = "Audio clip extraction failed"
            return
        }
        defer { try? FileManager.default.removeItem(at: clipURL) }

        do {
            let created = try await api.createJob(fileURL: clipURL, settings: settings)
            while !Task.isCancelled {
                let status = try await api.jobStatus(id: created.id)
                if status.status == "done" { break }
                if status.status == "error" {
                    throw NSError(
                        domain: "MSub.CueTranscribe",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: status.error ?? "Job failed"]
                    )
                }
                if status.status == "cancelled" { return }
                try await Task.sleep(for: .milliseconds(700))
            }
            let output = try await api.fetchOutput(jobID: created.id)
            guard let text = String(data: output.data, encoding: .utf8) else { return }
            let cuesFromClip = SubtitleDocument.parse(text, format: slot.outputFormat)
            let combined: String
            if cuesFromClip.isEmpty {
                combined = text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                combined = cuesFromClip
                    .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
            }
            guard let updatedIndex = slot.cues.firstIndex(where: { $0.id == cueID }) else { return }
            slot.cues[updatedIndex].text = combined
            schedulePreviewTextSync(for: slot.cues)
            scheduleTermStatsSync(for: slot.cues)
        } catch {
            transcribeError = error.localizedDescription
        }
    }

    private func extractCueClip(start: Double, end: Double) async -> URL? {
        let audioURL = await AudioSource.resolve(slot.url)

        let cachesDir: URL
        if let base = try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            cachesDir = base.appendingPathComponent("MSub-cue-clips", isDirectory: true)
        } else {
            cachesDir = FileManager.default.temporaryDirectory.appendingPathComponent("MSub-cue-clips", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: cachesDir, withIntermediateDirectories: true)
        let dest = cachesDir.appendingPathComponent("\(UUID().uuidString).m4a")

        // A small margin so the model has audio context at each edge.
        let margin: Double = 0.2
        let safeStart = max(0, start - margin)
        let safeDuration = max(0.4, (end - start) + margin * 2)

        if let result = await clipViaAVFoundation(
            source: audioURL,
            dest: dest,
            startSeconds: safeStart,
            durationSeconds: safeDuration
        ) {
            return result
        }
        // AVF failed (likely because AudioSource fell back to the original URL of
        // an unsupported container). Try ffmpeg directly on the source.
        if let result = await FFmpegRunner.extractAudio(
            from: slot.url,
            to: dest,
            start: safeStart,
            duration: safeDuration
        ) {
            return result
        }
        try? FileManager.default.removeItem(at: dest)
        return nil
    }

    private func clipViaAVFoundation(
        source: URL,
        dest: URL,
        startSeconds: Double,
        durationSeconds: Double
    ) async -> URL? {
        let asset = AVURLAsset(url: source)
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            return nil
        }
        try? FileManager.default.removeItem(at: dest)
        exportSession.timeRange = CMTimeRange(
            start: CMTime(seconds: startSeconds, preferredTimescale: 600),
            duration: CMTime(seconds: durationSeconds, preferredTimescale: 600)
        )

        do {
            try await exportSession.export(to: dest, as: .m4a)
        } catch {
            try? FileManager.default.removeItem(at: dest)
            return nil
        }

        if FileManager.default.fileExists(atPath: dest.path) {
            return dest
        }
        try? FileManager.default.removeItem(at: dest)
        return nil
    }

    private func resetCue(_ cueID: SubtitleCue.ID) {
        guard let selectedCueIndex = cueIndex(for: cueID),
              let original = originalCue(for: cueID) else { return }
        previewSyncTask?.cancel()
        slot.cues[selectedCueIndex].start = original.start
        slot.cues[selectedCueIndex].end = original.end
        slot.cues[selectedCueIndex].text = original.text
        slot.cues[selectedCueIndex].confidence = original.confidence
        slot.cues = SubtitleDocument.normalize(slot.cues)
        slot.selectedCueID = original.id
        scheduleCueTimingSync(for: slot.cues)
        scheduleTermStatsSync(for: slot.cues)
    }

    private func duplicateCue(_ cueID: SubtitleCue.ID) {
        guard let index = cueIndex(for: cueID) else { return }
        let source = slot.cues[index]
        let start = source.end
        let end = start + max(0.5, source.duration)
        insertCue(at: index + 1, start: start, end: end, text: source.text, confidence: source.confidence)
    }

    private func insertCue(before cueID: SubtitleCue.ID) {
        guard let index = cueIndex(for: cueID) else { return }
        let current = slot.cues[index]
        let previousEnd = index > 0 ? slot.cues[index - 1].end : nil
        let end = current.start
        let start = max(previousEnd ?? max(0, end - 2.0), end - 2.0)
        let safeEnd = max(start + 0.05, end)
        insertCue(at: index, start: start, end: safeEnd, text: "")
    }

    private func insertCue(after cueID: SubtitleCue.ID) {
        guard let index = cueIndex(for: cueID) else { return }
        let current = slot.cues[index]
        let next = index + 1 < slot.cues.count ? slot.cues[index + 1] : nil
        let start = current.end
        let defaultEnd = start + 2.0
        let end: Double
        if let next, next.start > start + 0.2 {
            end = min(defaultEnd, next.start - 0.05)
        } else {
            end = defaultEnd
        }
        insertCue(at: index + 1, start: start, end: end, text: "")
    }

    private func insertCue(
        at insertionIndex: Int,
        start: Double,
        end: Double,
        text: String,
        confidence: Double? = nil
    ) {
        previewSyncTask?.cancel()
        let cue = SubtitleCue(
            index: insertionIndex + 1,
            start: max(0, start),
            end: max(max(0, start) + 0.05, end),
            text: text,
            confidence: confidence
        )
        let safeIndex = min(max(0, insertionIndex), slot.cues.count)
        slot.cues.insert(cue, at: safeIndex)
        slot.cues = SubtitleDocument.normalize(slot.cues)
        slot.selectedCueID = cue.id
        scheduleCueTimingSync(for: slot.cues)
        scheduleTermStatsSync(for: slot.cues)
    }

    private func closeGap(around cueID: SubtitleCue.ID) {
        guard let index = cueIndex(for: cueID) else { return }
        previewSyncTask?.cancel()
        if index > 0 {
            slot.cues[index].start = slot.cues[index - 1].end
        }
        if index + 1 < slot.cues.count {
            slot.cues[index].end = slot.cues[index + 1].start
        }
        if slot.cues[index].end <= slot.cues[index].start + 0.05 {
            slot.cues[index].end = slot.cues[index].start + 0.05
        }
        slot.cues = SubtitleDocument.normalize(slot.cues)
        slot.selectedCueID = cueID
        scheduleCueTimingSync(for: slot.cues)
    }

    private func deleteCue(_ cueID: SubtitleCue.ID) {
        guard let index = cueIndex(for: cueID) else { return }
        previewSyncTask?.cancel()
        slot.cues.remove(at: index)
        slot.cues = SubtitleDocument.normalize(slot.cues)
        if slot.cues.isEmpty {
            slot.selectedCueID = nil
        } else {
            let nextIndex = min(index, slot.cues.count - 1)
            slot.selectedCueID = slot.cues[nextIndex].id
        }
        scheduleCueTimingSync(for: slot.cues)
        scheduleTermStatsSync(for: slot.cues)
    }

    private func findNext() {
        guard !findText.isEmpty, !slot.cues.isEmpty else { return }
        let startIndex = selectedCueIndex.map { $0 + 1 } ?? 0
        for offset in 0..<slot.cues.count {
            let index = (startIndex + offset) % slot.cues.count
            if containsMatch(slot.cues[index].text) {
                slot.selectedCueID = slot.cues[index].id
                findStatus = String(format: Copy.text("editor.findSelected", language: language), slot.cues[index].index)
                return
            }
        }
        findStatus = Copy.text("editor.findNoMatch", language: language)
        NSSound.beep()
    }

    private func replaceCurrent() {
        guard !findText.isEmpty else { return }
        guard let selectedCueIndex else {
            findNext()
            return
        }
        if replaceFirst(in: &slot.cues[selectedCueIndex].text) {
            schedulePreviewTextSync(for: slot.cues)
            scheduleTermStatsSync(for: slot.cues)
            findStatus = String(format: Copy.text("editor.replaceOneCount", language: language), 1)
            return
        }
        findNext()
    }

    private func replaceAll() {
        guard !findText.isEmpty else { return }
        var total = 0
        for index in slot.cues.indices {
            total += replaceAllMatches(in: &slot.cues[index].text)
        }
        if total > 0 {
            schedulePreviewTextSync(for: slot.cues)
            scheduleTermStatsSync(for: slot.cues)
        }
        findStatus = String(format: Copy.text("editor.replaceAllCount", language: language), total)
        if total == 0 {
            NSSound.beep()
        }
    }

    private func occurrenceCount() -> Int {
        guard !findText.isEmpty else { return 0 }
        return slot.cues.reduce(0) { count, cue in
            count + ranges(in: cue.text).count
        }
    }

    private func containsMatch(_ text: String) -> Bool {
        text.range(of: findText, options: searchOptions) != nil
    }

    private func replaceFirst(in text: inout String) -> Bool {
        guard let range = text.range(of: findText, options: searchOptions) else { return false }
        text.replaceSubrange(range, with: replacementText)
        return true
    }

    private func replaceAllMatches(in text: inout String) -> Int {
        var count = 0
        var searchStartOffset = 0
        while searchStartOffset <= text.count {
            let start = text.index(text.startIndex, offsetBy: searchStartOffset)
            guard let range = text.range(
                of: findText,
                options: searchOptions,
                range: start..<text.endIndex
            ) else {
                break
            }
            let offset = text.distance(from: text.startIndex, to: range.lowerBound)
            text.replaceSubrange(range, with: replacementText)
            count += 1
            searchStartOffset = min(text.count, offset + replacementText.count)
        }
        return count
    }

    private func ranges(in text: String) -> [Range<String.Index>] {
        guard !findText.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: findText, options: searchOptions, range: searchRange) {
            ranges.append(range)
            searchRange = range.upperBound..<text.endIndex
        }
        return ranges
    }

    private var searchOptions: String.CompareOptions {
        matchCase ? [] : [.caseInsensitive, .diacriticInsensitive]
    }

    private func playSelectedCue() {
        guard let selectedCueIndex else { return }
        let cue = slot.cues[selectedCueIndex]
        playback.playRange(start: cue.start, end: cue.end)
    }

    private func toggleMarkupTag(_ tag: String) {
        guard let selectedCueIndex else { return }
        var text = slot.cues[selectedCueIndex].text
        guard !text.isEmpty else { return }

        if var selection = activeStyleSelection(in: text) {
            if unwrapSelectedMarkup(tag, in: &text, selection: &selection)
                || unwrapImmediateMarkup(tag, in: &text, selection: &selection) {
                commitStyleText(text, selection: selection)
                return
            }
            wrapSelection(tag: tag, in: &text, selection: &selection)
            commitStyleText(text, selection: selection)
            return
        }

        if let unwrapped = unwrappedMarkupText(text, tag: tag) {
            commitStyleText(unwrapped, selection: nil)
        } else {
            commitStyleText("<\(tag)>\(text)</\(tag)>", selection: nil)
        }
    }

    private func applyCueColor(_ color: Color) {
        guard let selectedCueIndex else { return }
        var text = slot.cues[selectedCueIndex].text
        guard !text.isEmpty else { return }

        if var selection = activeStyleSelection(in: text) {
            if unwrapSelectedFont(in: &text, selection: &selection)
                || unwrapImmediateFont(in: &text, selection: &selection) {
                commitStyleText(text, selection: selection)
                return
            }
            wrapSelection(opening: "<font color=\"\(hexString(for: color))\">", closing: "</font>", in: &text, selection: &selection)
            commitStyleText(text, selection: selection)
            return
        }

        if let unwrapped = unwrappedFontText(text) {
            commitStyleText(unwrapped, selection: nil)
        } else {
            commitStyleText("<font color=\"\(hexString(for: color))\">\(text)</font>", selection: nil)
        }
    }

    private func clearCueStyle() {
        guard let selectedCueIndex else { return }
        var text = slot.cues[selectedCueIndex].text
        guard !text.isEmpty else { return }

        if var selection = activeStyleSelection(in: text) {
            while unwrapAnyImmediateStyle(in: &text, selection: &selection) {}
            guard let range = Range(selection, in: text) else {
                commitStyleText(text, selection: selection)
                return
            }
            let selectedText = String(text[range])
            let cleared = clearMarkup(in: selectedText)
            text.replaceSubrange(range, with: cleared)
            selection.length = cleared.utf16.count
            commitStyleText(text, selection: selection)
            return
        }

        commitStyleText(clearMarkup(in: text), selection: nil)
    }

    private func commitStyleText(_ text: String, selection: NSRange?) {
        guard let selectedCueIndex else { return }
        slot.cues[selectedCueIndex].text = text
        selectedTextRange = selection
        schedulePreviewTextSync(for: slot.cues)
        scheduleTermStatsSync(for: slot.cues)
    }

    private func activeStyleSelection(in text: String) -> NSRange? {
        guard let selectedTextRange,
              selectedTextRange.length > 0,
              NSMaxRange(selectedTextRange) <= text.utf16.count else {
            return nil
        }
        return selectedTextRange
    }

    private func wrapSelection(tag: String, in text: inout String, selection: inout NSRange) {
        wrapSelection(opening: "<\(tag)>", closing: "</\(tag)>", in: &text, selection: &selection)
    }

    private func wrapSelection(opening: String, closing: String, in text: inout String, selection: inout NSRange) {
        guard let range = Range(selection, in: text) else { return }
        let selectedText = String(text[range])
        text.replaceSubrange(range, with: "\(opening)\(selectedText)\(closing)")
        selection.location += opening.utf16.count
    }

    private func unwrapSelectedMarkup(_ tag: String, in text: inout String, selection: inout NSRange) -> Bool {
        guard let range = Range(selection, in: text),
              let unwrapped = unwrappedMarkupText(String(text[range]), tag: tag) else {
            return false
        }
        text.replaceSubrange(range, with: unwrapped)
        selection.length = unwrapped.utf16.count
        return true
    }

    private func unwrapImmediateMarkup(_ tag: String, in text: inout String, selection: inout NSRange) -> Bool {
        guard let range = Range(selection, in: text),
              let wrapper = markupWrapper(around: range, in: text, tag: tag) else {
            return false
        }
        removeWrapper(wrapper, from: &text, selection: &selection)
        return true
    }

    private func unwrapSelectedFont(in text: inout String, selection: inout NSRange) -> Bool {
        guard let range = Range(selection, in: text),
              let unwrapped = unwrappedFontText(String(text[range])) else {
            return false
        }
        text.replaceSubrange(range, with: unwrapped)
        selection.length = unwrapped.utf16.count
        return true
    }

    private func unwrapImmediateFont(in text: inout String, selection: inout NSRange) -> Bool {
        guard let range = Range(selection, in: text),
              let wrapper = fontWrapper(around: range, in: text) else {
            return false
        }
        removeWrapper(wrapper, from: &text, selection: &selection)
        return true
    }

    private func unwrapAnyImmediateStyle(in text: inout String, selection: inout NSRange) -> Bool {
        if unwrapImmediateFont(in: &text, selection: &selection) {
            return true
        }
        for tag in ["b", "i", "u"] {
            if unwrapImmediateMarkup(tag, in: &text, selection: &selection) {
                return true
            }
        }
        return false
    }

    private struct StyleWrapper {
        let opening: Range<String.Index>
        let closing: Range<String.Index>
        let openingLength: Int
    }

    private func removeWrapper(_ wrapper: StyleWrapper, from text: inout String, selection: inout NSRange) {
        text.removeSubrange(wrapper.closing)
        text.removeSubrange(wrapper.opening)
        selection.location = max(0, selection.location - wrapper.openingLength)
    }

    private func markupWrapper(around range: Range<String.Index>, in text: String, tag: String) -> StyleWrapper? {
        let openingText = "<\(tag)>"
        let closingText = "</\(tag)>"
        guard let openingStart = text.index(range.lowerBound, offsetBy: -openingText.count, limitedBy: text.startIndex),
              let closingEnd = text.index(range.upperBound, offsetBy: closingText.count, limitedBy: text.endIndex) else {
            return nil
        }

        let opening = openingStart..<range.lowerBound
        let closing = range.upperBound..<closingEnd
        guard String(text[opening]).caseInsensitiveCompare(openingText) == .orderedSame,
              String(text[closing]).caseInsensitiveCompare(closingText) == .orderedSame else {
            return nil
        }
        return StyleWrapper(opening: opening, closing: closing, openingLength: openingText.utf16.count)
    }

    private func fontWrapper(around range: Range<String.Index>, in text: String) -> StyleWrapper? {
        let prefix = text[..<range.lowerBound]
        guard let openingStart = prefix.range(of: "<font", options: [.caseInsensitive, .backwards])?.lowerBound,
              let openingEnd = text[openingStart..<range.lowerBound].lastIndex(of: ">"),
              text.index(after: openingEnd) == range.lowerBound,
              let closingEnd = text.index(range.upperBound, offsetBy: "</font>".count, limitedBy: text.endIndex) else {
            return nil
        }

        let opening = openingStart..<range.lowerBound
        let closing = range.upperBound..<closingEnd
        guard String(text[closing]).caseInsensitiveCompare("</font>") == .orderedSame else {
            return nil
        }
        return StyleWrapper(opening: opening, closing: closing, openingLength: String(text[opening]).utf16.count)
    }

    private func clearMarkup(in text: String) -> String {
        var text = text.replacingOccurrences(
            of: #"<font\b[^>]*>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        for tag in ["b", "i", "u", "font"] {
            text = text.replacingOccurrences(
                of: "</\(tag)>",
                with: "",
                options: [.caseInsensitive]
            )
            text = text.replacingOccurrences(
                of: "<\(tag)>",
                with: "",
                options: [.caseInsensitive]
            )
        }
        return text
    }

    private func hasOuterMarkupTag(_ tag: String) -> Bool {
        guard let selectedCueIndex else { return false }
        let text = slot.cues[selectedCueIndex].text
        if let selection = activeStyleSelection(in: text),
           let range = Range(selection, in: text) {
            return unwrappedMarkupText(String(text[range]), tag: tag) != nil
                || markupWrapper(around: range, in: text, tag: tag) != nil
        }
        return unwrappedMarkupText(text, tag: tag) != nil
    }

    private var hasOuterFontColor: Bool {
        guard let selectedCueIndex else { return false }
        let text = slot.cues[selectedCueIndex].text
        if let selection = activeStyleSelection(in: text),
           let range = Range(selection, in: text) {
            return unwrappedFontText(String(text[range])) != nil
                || fontWrapper(around: range, in: text) != nil
        }
        return unwrappedFontText(text) != nil
    }

    private func unwrappedMarkupText(_ text: String, tag: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        guard lower.hasPrefix(open), lower.hasSuffix(close) else { return nil }
        let start = trimmed.index(trimmed.startIndex, offsetBy: open.count)
        let end = trimmed.index(trimmed.endIndex, offsetBy: -close.count)
        guard start <= end else { return nil }
        return String(trimmed[start..<end])
    }

    private func unwrappedFontText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("<font "), lower.hasSuffix("</font>"),
              let openEnd = trimmed.firstIndex(of: ">") else {
            return nil
        }
        let start = trimmed.index(after: openEnd)
        let end = trimmed.index(trimmed.endIndex, offsetBy: -"</font>".count)
        guard start <= end else { return nil }
        return String(trimmed[start..<end])
    }

    private func hexString(for color: Color) -> String {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? .systemYellow
        let red = Int((nsColor.redComponent * 255).rounded())
        let green = Int((nsColor.greenComponent * 255).rounded())
        let blue = Int((nsColor.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}

private struct TimelineZoomSlider: NSViewRepresentable {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(
            value: normalizedValue(for: value),
            minValue: 0,
            maxValue: 1,
            target: context.coordinator,
            action: #selector(Coordinator.valueChanged(_:))
        )
        slider.isContinuous = true
        slider.numberOfTickMarks = 0
        slider.allowsTickMarkValuesOnly = false
        slider.controlSize = .small
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        let normalized = normalizedValue(for: value)
        if abs(slider.doubleValue - normalized) > 0.0001 {
            slider.doubleValue = normalized
        }
    }

    private func normalizedValue(for rawValue: Double) -> Double {
        let bounds = sanitizedBounds
        guard bounds.upper > bounds.lower else { return 0 }
        let clampedValue = clamp(rawValue, bounds.lower, bounds.upper)
        return clamp(log(clampedValue / bounds.lower) / log(bounds.upper / bounds.lower), 0, 1)
    }

    private func value(for normalized: Double) -> Double {
        let bounds = sanitizedBounds
        guard bounds.upper > bounds.lower else { return bounds.lower }
        let rawValue = bounds.lower * pow(bounds.upper / bounds.lower, clamp(normalized, 0, 1))
        let steppedValue = (rawValue / max(step, 0.0001)).rounded() * max(step, 0.0001)
        return clamp(steppedValue, bounds.lower, bounds.upper)
    }

    private var sanitizedBounds: (lower: Double, upper: Double) {
        let lower = max(0.0001, min(range.lowerBound, range.upperBound))
        let upper = max(lower, max(range.lowerBound, range.upperBound))
        return (lower, upper)
    }

    private func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        min(max(value, lower), upper)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: TimelineZoomSlider

        init(parent: TimelineZoomSlider) {
            self.parent = parent
        }

        @objc func valueChanged(_ sender: NSSlider) {
            parent.value = parent.value(for: sender.doubleValue)
        }
    }
}

private struct ZoomableTimeline: View {
    @Binding var cues: [SubtitleCue]
    @Binding var selectedCueID: SubtitleCue.ID?
    @Binding var highlightTerm: String?
    let findTerm: String?

    let waveform: WaveformSamples
    let duration: Double
    @Binding var zoom: Double
    let zoomRange: ClosedRange<Double>
    let currentTime: Double
    let language: AppLanguage
    let onSeek: (Double) -> Void
    let onScrub: (Double) -> Void
    let cueActions: TimelineCueActions

    @State private var isHandleDragging = false
    @State private var scrollPosition = ScrollPosition()
    @State private var visibleFractionRange: ClosedRange<Double> = 0...1
    @State private var magnifySession: MagnifySession?

    private struct MagnifySession: Equatable {
        let baselineZoom: Double
        let anchorFraction: Double
        let anchorScreenX: CGFloat
        let viewportWidth: CGFloat
    }

    var body: some View {
        GeometryReader { proxy in
            let viewportWidth = proxy.size.width
            let contentWidth = max(viewportWidth, viewportWidth * zoom)
            let initialVisibleRange = 0...min(1, 1 / max(zoom, 1))
            let effectiveVisibleRange = visibleFractionRange == 0...1 && zoom > 1 ? initialVisibleRange : visibleFractionRange

            ScrollView(.horizontal, showsIndicators: true) {
                WaveformTimelineEditor(
                    cues: $cues,
                    selectedCueID: $selectedCueID,
                    isHandleDragging: $isHandleDragging,
                    highlightTerm: $highlightTerm,
                    findTerm: findTerm,
                    waveform: waveform,
                    duration: duration,
                    zoom: zoom,
                    currentTime: currentTime,
                    language: language,
                    visibleFractionRange: effectiveVisibleRange,
                    onSeek: onSeek,
                    onScrub: onScrub,
                    cueActions: cueActions
                )
                .frame(width: contentWidth, height: proxy.size.height)
            }
            .scrollDisabled(isHandleDragging || magnifySession != nil)
            .scrollPosition($scrollPosition)
            .gesture(makeMagnifyGesture(viewport: viewportWidth))
            .onScrollGeometryChange(for: ClosedRange<Double>.self) { geometry in
                let contentWidth = max(geometry.contentSize.width, 1)
                let visibleRect = geometry.visibleRect
                let lower = quantizedFraction(Double(visibleRect.minX / contentWidth))
                let upper = max(lower, quantizedFraction(Double(visibleRect.maxX / contentWidth)))
                return lower...upper
            } action: { oldValue, newValue in
                guard abs(newValue.lowerBound - oldValue.lowerBound) > 0.0002
                    || abs(newValue.upperBound - oldValue.upperBound) > 0.0002 else { return }
                visibleFractionRange = newValue
            }
            .onChange(of: selectedCueID) { _, newValue in
                guard magnifySession == nil else { return }
                centerOnSelectedCue(viewport: viewportWidth, content: contentWidth, animated: true, cueID: newValue)
            }
            .onChange(of: zoom) { _, newZoom in
                guard magnifySession == nil else { return }
                // Anchor on the currently visible center rather than re-centering on
                // the selected cue — slider / keyboard zoom should preserve the
                // point of interest the user is looking at, not warp the view.
                anchorOnVisibleCenter(viewport: viewportWidth, newZoom: newZoom)
            }
            .onAppear {
                centerOnSelectedCue(viewport: viewportWidth, content: contentWidth, animated: false, cueID: selectedCueID)
            }
            .onChange(of: viewportWidth) { _, _ in
                centerOnSelectedCue(viewport: viewportWidth, content: contentWidth, animated: false, cueID: selectedCueID)
            }
        }
    }

    private func centerOnSelectedCue(viewport: CGFloat, content: CGFloat, animated: Bool, cueID: SubtitleCue.ID?) {
        guard let cueID,
              let cue = cues.first(where: { $0.id == cueID }) else { return }
        let cueCenterX = xPosition((cue.start + cue.end) / 2, width: content)
        let target = max(0, min(content - viewport, cueCenterX - viewport / 2))
        let scroll = {
            scrollPosition.scrollTo(x: target)
        }
        if animated {
            withAnimation(.easeInOut(duration: 0.22)) { scroll() }
        } else {
            DispatchQueue.main.async { scroll() }
        }
    }

    /// Adjusts `scrollPosition` so the timeline coordinate currently at the
    /// viewport's midpoint stays at the viewport's midpoint after `newZoom`
    /// takes effect. Skips re-centering on the selected cue, which would have
    /// looked like a jump immediately after the slider finished dragging.
    private func anchorOnVisibleCenter(viewport: CGFloat, newZoom: Double) {
        let centerFraction = (visibleFractionRange.lowerBound + visibleFractionRange.upperBound) / 2
        let newContentWidth = max(viewport, viewport * newZoom)
        let target = centerFraction * newContentWidth - viewport / 2
        let maxOffset = max(0, newContentWidth - viewport)
        let clamped = min(max(0, target), maxOffset)
        DispatchQueue.main.async {
            scrollPosition.scrollTo(x: clamped)
        }
    }

    private func makeMagnifyGesture(viewport: CGFloat) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                let safeViewport = max(viewport, 1)
                let session: MagnifySession
                if let existing = magnifySession {
                    session = existing
                } else {
                    let startX = max(0, min(safeViewport, value.startLocation.x))
                    let visibleSpan = max(0, visibleFractionRange.upperBound - visibleFractionRange.lowerBound)
                    let anchor = visibleFractionRange.lowerBound + (startX / safeViewport) * visibleSpan
                    let created = MagnifySession(
                        baselineZoom: zoom,
                        anchorFraction: min(1, max(0, anchor)),
                        anchorScreenX: startX,
                        viewportWidth: safeViewport
                    )
                    magnifySession = created
                    session = created
                }

                let proposed = session.baselineZoom * Double(value.magnification)
                let newZoom = min(zoomRange.upperBound, max(zoomRange.lowerBound, proposed))
                zoom = newZoom

                let newContentWidth = max(session.viewportWidth, session.viewportWidth * newZoom)
                let target = session.anchorFraction * newContentWidth - session.anchorScreenX
                let maxOffset = max(0, newContentWidth - session.viewportWidth)
                scrollPosition.scrollTo(x: min(max(0, target), maxOffset))
            }
            .onEnded { _ in
                magnifySession = nil
            }
    }

    private func xPosition(_ seconds: Double, width: CGFloat) -> CGFloat {
        CGFloat(max(0, min(seconds / max(duration, 0.001), 1))) * width
    }

    private func quantizedFraction(_ value: Double) -> Double {
        let clamped = max(0, min(1, value))
        return (clamped * 10_000).rounded() / 10_000
    }
}

private struct TimelineDotsCanvas: View {
    let cues: [SubtitleCue]
    let term: String
    let duration: Double
    let topY: CGFloat
    let baseDiameter: CGFloat
    let emphasizedDiameter: CGFloat
    let baseColor: Color
    let emphasizedColor: Color
    let emphasizedCueID: SubtitleCue.ID?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                // Base dots — drawn in Canvas (cheap, many)
                Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, size in
                    var basePath = Path()
                    for cue in cues where cue.text.localizedCaseInsensitiveContains(term) {
                        if cue.id == emphasizedCueID { continue }
                        let mid = (cue.start + cue.end) / 2
                        let x = CGFloat(max(0, min(mid / max(duration, 0.001), 1))) * size.width
                        let rect = CGRect(
                            x: x - baseDiameter / 2,
                            y: topY,
                            width: baseDiameter,
                            height: baseDiameter
                        )
                        basePath.addEllipse(in: rect)
                    }
                    context.fill(basePath, with: .color(baseColor))
                }

                // Emphasized dot — a real SwiftUI view so position changes animate.
                if let emphasizedCue {
                    let mid = (emphasizedCue.start + emphasizedCue.end) / 2
                    let x = CGFloat(max(0, min(mid / max(duration, 0.001), 1))) * proxy.size.width
                    ZStack {
                        Circle()
                            .fill(emphasizedColor.opacity(0.35))
                            .frame(width: emphasizedDiameter + 4, height: emphasizedDiameter + 4)
                        Circle()
                            .fill(emphasizedColor)
                            .frame(width: emphasizedDiameter, height: emphasizedDiameter)
                            .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1))
                    }
                    .position(x: x, y: topY + emphasizedDiameter / 2)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.75), value: emphasizedCueID)
        }
    }

    private var emphasizedCue: SubtitleCue? {
        guard let id = emphasizedCueID else { return nil }
        return cues.first { $0.id == id }
    }
}

private struct CompactTimelineStrip: View {
    let cues: [SubtitleCue]
    @Binding var selectedCueID: SubtitleCue.ID?
    @Binding var highlightTerm: String?
    let findTerm: String?
    let waveform: WaveformSamples
    let duration: Double
    let currentTime: Double
    let onSeek: (Double) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color(nsColor: .textBackgroundColor))

                ZStack {
                    WaveformCanvas(
                        samples: waveform,
                        visibleFractionRange: 0...1,
                        color: Color.accentColor.opacity(0.28),
                        verticalPadding: 6,
                        minimumBarWidth: 2
                    )
                        .equatable()
                        .id(ObjectIdentifier(waveform))
                        .transition(.opacity)
                }
                .animation(.easeInOut(duration: 0.3), value: ObjectIdentifier(waveform))
                .allowsHitTesting(false)

                if cues.count > 240 {
                    compactDensityCanvas(width: width, height: height)
                        .allowsHitTesting(false)
                } else {
                    compactCueCanvas(width: width, height: height)
                        .allowsHitTesting(false)
                }

                if let term = activeHighlightTerm {
                    TimelineDotsCanvas(
                        cues: cues,
                        term: term,
                        duration: duration,
                        topY: 3,
                        baseDiameter: 6,
                        emphasizedDiameter: 6,
                        baseColor: .yellow,
                        emphasizedColor: .yellow,
                        emphasizedCueID: nil
                    )
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }

                if let term = activeFindTerm {
                    TimelineDotsCanvas(
                        cues: cues,
                        term: term,
                        duration: duration,
                        topY: 3,
                        baseDiameter: 6,
                        emphasizedDiameter: 10,
                        baseColor: .green,
                        emphasizedColor: .green,
                        emphasizedCueID: selectedCueID
                    )
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }

                if duration > 0 {
                    Rectangle()
                        .fill(Color.red.opacity(0.85))
                        .frame(width: 1.5, height: height - 6)
                        .offset(x: xPosition(currentTime, width: width))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture(coordinateSpace: .local)
                    .onEnded { value in
                        let seconds = clamp(Double(value.location.x / max(width, 1)) * duration, 0, duration)
                        if let cue = cue(at: seconds) {
                            selectedCueID = cue.id
                        } else {
                            onSeek(seconds)
                        }
                    }
            )
            .animation(.easeInOut(duration: 0.22), value: highlightTerm)
            .animation(.easeInOut(duration: 0.22), value: findTerm)
        }
    }

    private var activeHighlightTerm: String? {
        guard let term = highlightTerm, !term.isEmpty else { return nil }
        return term
    }

    private var activeFindTerm: String? {
        guard let term = findTerm, !term.isEmpty else { return nil }
        return term
    }

    private func cue(at seconds: Double) -> SubtitleCue? {
        cues.last { cue in
            seconds >= cue.start && seconds <= cue.end
        }
    }

    private func compactCueCanvas(width: CGFloat, height: CGFloat) -> some View {
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, _ in
            for cue in cues {
                let selected = cue.id == selectedCueID
                let blockHeight = selected ? height - 10 : height - 16
                let startX = xPosition(cue.start, width: width)
                let endX = xPosition(cue.end, width: width)
                let rect = CGRect(
                    x: startX,
                    y: (height - blockHeight) / 2,
                    width: max(2, endX - startX),
                    height: blockHeight
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 2),
                    with: .color(selected ? Color.accentColor.opacity(0.55) : Color.teal.opacity(0.28))
                )
            }
        }
    }

    private func compactDensityCanvas(width: CGFloat, height: CGFloat) -> some View {
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, _ in
            let binCount = max(20, min(180, Int(width / 4)))
            var deltas = [Int](repeating: 0, count: binCount + 1)
            var selectedBin: Int?

            for cue in cues {
                let lower = max(0, min(binCount - 1, Int((cue.start / max(duration, 0.001)) * Double(binCount))))
                let upper = max(lower, min(binCount - 1, Int(ceil((cue.end / max(duration, 0.001)) * Double(binCount)))))
                deltas[lower] += 1
                if upper + 1 < deltas.count {
                    deltas[upper + 1] -= 1
                }
                if cue.id == selectedCueID {
                    selectedBin = lower
                }
            }

            var bins = [Int](repeating: 0, count: binCount)
            var runningCount = 0
            for index in 0..<binCount {
                runningCount += deltas[index]
                bins[index] = runningCount
            }
            let maxCount = max(bins.max() ?? 1, 1)
            let binWidth = width / CGFloat(binCount)
            for (index, count) in bins.enumerated() where count > 0 {
                let intensity = min(1.0, Double(count) / Double(maxCount))
                let blockHeight = (height - 10) * (0.3 + 0.6 * intensity)
                let rect = CGRect(
                    x: CGFloat(index) * binWidth,
                    y: (height - blockHeight) / 2,
                    width: max(1, binWidth * 0.82),
                    height: blockHeight
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 2),
                    with: .color(Color.teal.opacity(0.18 + 0.32 * intensity))
                )
            }

            if let selectedBin {
                let rect = CGRect(
                    x: CGFloat(selectedBin) * binWidth,
                    y: 4,
                    width: max(2, binWidth),
                    height: height - 8
                )
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(Color.accentColor.opacity(0.5)))
            }
        }
    }

    private func xPosition(_ seconds: Double, width: CGFloat) -> CGFloat {
        CGFloat(max(0, min(seconds / max(duration, 0.001), 1))) * width
    }

    private func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        if upper <= lower { return lower }
        return min(max(value, lower), upper)
    }
}

@MainActor
struct TimelineCueActions {
    let canReset: @MainActor (SubtitleCue.ID) -> Bool
    let reset: @MainActor (SubtitleCue.ID) -> Void
    let duplicate: @MainActor (SubtitleCue.ID) -> Void
    let insertBefore: @MainActor (SubtitleCue.ID) -> Void
    let insertAfter: @MainActor (SubtitleCue.ID) -> Void
    let closeGap: @MainActor (SubtitleCue.ID) -> Void
    let delete: @MainActor (SubtitleCue.ID) -> Void
}

@MainActor
@ViewBuilder
private func cueContextMenu(for cue: SubtitleCue, language: AppLanguage, actions: TimelineCueActions) -> some View {
    Button {
        actions.reset(cue.id)
    } label: {
        Label(Copy.text("editor.resetCue", language: language), systemImage: "arrow.counterclockwise")
    }
    .disabled(!actions.canReset(cue.id))

    Button {
        actions.duplicate(cue.id)
    } label: {
        Label(Copy.text("editor.duplicateCue", language: language), systemImage: "plus.square.on.square")
    }

    Divider()

    Button {
        actions.insertBefore(cue.id)
    } label: {
        Label(Copy.text("editor.addBefore", language: language), systemImage: "arrow.up.to.line.compact")
    }

    Button {
        actions.insertAfter(cue.id)
    } label: {
        Label(Copy.text("editor.addAfter", language: language), systemImage: "arrow.down.to.line.compact")
    }

    Button {
        actions.closeGap(cue.id)
    } label: {
        Label(Copy.text("editor.closeGap", language: language), systemImage: "arrow.left.and.right")
    }

    Divider()

    Button(role: .destructive) {
        actions.delete(cue.id)
    } label: {
        Label(Copy.text("editor.deleteCue", language: language), systemImage: "trash")
    }
}

private struct WaveformTimelineEditor: View {
    @Binding var cues: [SubtitleCue]
    @Binding var selectedCueID: SubtitleCue.ID?
    @Binding var isHandleDragging: Bool
    @Binding var highlightTerm: String?
    let findTerm: String?

    let waveform: WaveformSamples
    let duration: Double
    let zoom: Double
    let currentTime: Double
    let language: AppLanguage
    let visibleFractionRange: ClosedRange<Double>
    let onSeek: (Double) -> Void
    let onScrub: (Double) -> Void
    let cueActions: TimelineCueActions

    @State private var dragSession: HandleDragSession?

    private struct HandleDragSession {
        let cueID: SubtitleCue.ID
        let edge: Edge
        let initialStart: Double
        let initialEnd: Double
    }

    private enum Edge { case start, end }

    // Layout constants
    private let cueTopOffset: CGFloat = 22
    private let cueHeight: CGFloat = 64
    private let handleHitWidth: CGFloat = 16
    private let handleVisualWidth: CGFloat = 5
    private let handleHitHeightExtra: CGFloat = 12
    private let cursorDragHeight: CGFloat = 20
    private let rulerHeight: CGFloat = 22
    private let waveformBottomGap: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let detailedCues = shouldRenderDetailedCues(width: width)
            let visibleCueRange = detailedCues ? visibleCueRange() : cues.indices

            ZStack(alignment: .topLeading) {
                background
                    .contentShape(Rectangle())

                ZStack {
                    WaveformCanvas(
                        samples: waveform,
                        visibleFractionRange: visibleFractionRange,
                        color: Color.accentColor.opacity(0.38),
                        verticalPadding: 14,
                        minimumBarWidth: 2,
                        bottomPadding: rulerHeight + waveformBottomGap
                    )
                        .equatable()
                        .id(ObjectIdentifier(waveform))
                        .transition(.opacity)
                }
                .animation(.easeInOut(duration: 0.3), value: ObjectIdentifier(waveform))
                .allowsHitTesting(false)

                TimeRulerCanvas(
                    duration: duration,
                    visibleFractionRange: visibleFractionRange,
                    language: language
                )
                .equatable()
                .frame(width: width, height: rulerHeight)
                .offset(y: height - rulerHeight)
                .allowsHitTesting(false)

                if detailedCues {
                    cueBlocksCanvas(width: width, cueRange: visibleCueRange)
                        .allowsHitTesting(false)
                    cueOverlapCanvas(width: width, cueRange: visibleCueRange)
                        .allowsHitTesting(false)
                    cueHitOverlays(width: width, cueRange: visibleCueRange)
                } else {
                    cueDensityCanvas(width: width)
                        .allowsHitTesting(false)
                }

                if detailedCues, let selectedCue {
                    selectedCueOverlay(cue: selectedCue, width: width)
                }

                if detailedCues, let selectedCueBinding {
                    handles(cue: selectedCueBinding, width: width)
                }

                if let term = activeHighlightTerm {
                    TimelineDotsCanvas(
                        cues: cues,
                        term: term,
                        duration: duration,
                        topY: 6,
                        baseDiameter: 7,
                        emphasizedDiameter: 7,
                        baseColor: .yellow,
                        emphasizedColor: .yellow,
                        emphasizedCueID: nil
                    )
                    .frame(width: width)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }

                if let term = activeFindTerm {
                    TimelineDotsCanvas(
                        cues: cues,
                        term: term,
                        duration: duration,
                        topY: 6,
                        baseDiameter: 7,
                        emphasizedDiameter: 11,
                        baseColor: .green,
                        emphasizedColor: .green,
                        emphasizedCueID: selectedCueID
                    )
                    .frame(width: width)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }

                if duration > 0 {
                    playbackCursor(width: width, height: height)
                        .allowsHitTesting(false)
                    cursorDragLayer(width: width)
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                SpatialTapGesture(coordinateSpace: .local)
                    .onEnded { value in
                        handleTimelineTap(at: value.location, width: width, height: height)
                    }
            )
            .animation(.easeInOut(duration: 0.22), value: highlightTerm)
            .animation(.easeInOut(duration: 0.22), value: findTerm)
        }
    }

    private var activeHighlightTerm: String? {
        guard let term = highlightTerm, !term.isEmpty else { return nil }
        return term
    }

    private var activeFindTerm: String? {
        guard let term = findTerm, !term.isEmpty else { return nil }
        return term
    }

    private func shouldRenderDetailedCues(width: CGFloat) -> Bool {
        guard !cues.isEmpty else { return true }
        if cues.count <= 180 { return true }
        let speechSeconds = cues.reduce(0.0) { $0 + max(0, $1.duration) }
        let averagePixelWidth = CGFloat(speechSeconds / max(duration, 0.001)) * width / CGFloat(cues.count)
        return averagePixelWidth >= 5.0
    }

    private func visibleCueRange() -> Range<Array<SubtitleCue>.Index> {
        guard !cues.isEmpty else { return cues.indices }
        let visibleStart = visibleFractionRange.lowerBound * duration
        let visibleEnd = visibleFractionRange.upperBound * duration
        let padding = max(1.0, (visibleEnd - visibleStart) * 0.15)
        let lowerTime = max(0, visibleStart - padding)
        let upperTime = min(max(duration, visibleEnd), visibleEnd + padding)

        var lower = cues.startIndex
        var upper = cues.endIndex
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if cues[middle].end < lowerTime {
                lower = middle + 1
            } else {
                upper = middle
            }
        }

        var end = lower
        while end < cues.endIndex, cues[end].start <= upperTime {
            end += 1
        }
        return lower..<end
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(nsColor: .textBackgroundColor))
    }

    private var selectedCue: SubtitleCue? {
        guard let selectedCueID else { return nil }
        return cues.first { $0.id == selectedCueID }
    }

    private var selectedCueBinding: Binding<SubtitleCue>? {
        guard let selectedCueID,
              let index = cues.firstIndex(where: { $0.id == selectedCueID }) else {
            return nil
        }
        return $cues[index]
    }

    private func cueBlocksCanvas(width: CGFloat, cueRange: Range<Array<SubtitleCue>.Index>) -> some View {
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, _ in
            for cue in cues[cueRange] {
                let selected = cue.id == selectedCueID
                let startX = xPosition(cue.start, width: width)
                let endX = xPosition(cue.end, width: width)
                let cueWidth = max(2, endX - startX)
                let rect = CGRect(x: startX, y: cueTopOffset, width: cueWidth, height: cueHeight)
                let path = Path(roundedRect: rect, cornerRadius: 5)
                context.fill(path, with: .color(selected ? Color.accentColor.opacity(0.28) : Color.teal.opacity(0.22)))
                context.stroke(
                    path,
                    with: .color(selected ? Color.accentColor : Color.teal.opacity(0.55)),
                    lineWidth: selected ? 1.6 : 0.8
                )
            }
        }
    }

    /// Renders red translucent rectangles wherever two cues overlap in time, so the
    /// user can immediately see conflicting timings while dragging.
    private func cueOverlapCanvas(width: CGFloat, cueRange: Range<Array<SubtitleCue>.Index>) -> some View {
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, _ in
            let visible = Array(cues[cueRange])
            guard visible.count > 1 else { return }
            for i in 0..<visible.count {
                for j in (i + 1)..<visible.count {
                    let lower = max(visible[i].start, visible[j].start)
                    let upper = min(visible[i].end, visible[j].end)
                    guard lower < upper else { continue }
                    let startX = xPosition(lower, width: width)
                    let endX = xPosition(upper, width: width)
                    let rect = CGRect(
                        x: startX,
                        y: cueTopOffset,
                        width: max(2, endX - startX),
                        height: cueHeight
                    )
                    let path = Path(roundedRect: rect, cornerRadius: 3)
                    context.fill(path, with: .color(.red.opacity(0.42)))
                    context.stroke(path, with: .color(.red.opacity(0.85)), lineWidth: 1)
                }
            }
        }
    }

    private func cueDensityCanvas(width: CGFloat) -> some View {
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, _ in
            let binCount = max(24, min(260, Int(width / 3)))
            var deltas = [Int](repeating: 0, count: binCount + 1)
            var selectedBin: Int?

            for cue in cues {
                let lower = max(0, min(binCount - 1, Int((cue.start / max(duration, 0.001)) * Double(binCount))))
                let upper = max(lower, min(binCount - 1, Int(ceil((cue.end / max(duration, 0.001)) * Double(binCount)))))
                deltas[lower] += 1
                if upper + 1 < deltas.count {
                    deltas[upper + 1] -= 1
                }
                if cue.id == selectedCueID {
                    selectedBin = lower
                }
            }

            var bins = [Int](repeating: 0, count: binCount)
            var runningCount = 0
            for index in 0..<binCount {
                runningCount += deltas[index]
                bins[index] = runningCount
            }
            let maxCount = max(bins.max() ?? 1, 1)
            let binWidth = width / CGFloat(binCount)
            for (index, count) in bins.enumerated() where count > 0 {
                let intensity = min(1.0, Double(count) / Double(maxCount))
                let blockHeight = cueHeight * (0.35 + 0.55 * intensity)
                let rect = CGRect(
                    x: CGFloat(index) * binWidth,
                    y: cueTopOffset + (cueHeight - blockHeight) / 2,
                    width: max(1, binWidth * 0.82),
                    height: blockHeight
                )
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 2),
                    with: .color(Color.teal.opacity(0.18 + 0.36 * intensity))
                )
            }

            if let selectedBin {
                let rect = CGRect(
                    x: CGFloat(selectedBin) * binWidth,
                    y: cueTopOffset,
                    width: max(2, binWidth),
                    height: cueHeight
                )
                context.stroke(Path(roundedRect: rect, cornerRadius: 3), with: .color(Color.accentColor), lineWidth: 1.4)
            }
        }
    }

    private func selectedCueOverlay(cue: SubtitleCue, width: CGFloat) -> some View {
        let startX = xPosition(cue.start, width: width)
        let endX = xPosition(cue.end, width: width)
        let cueWidth = max(2, endX - startX)
        let hitWidth = max(24, cueWidth)
        let hitOffset = max(0, startX - (hitWidth - cueWidth) / 2)

        return ZStack(alignment: .leading) {
            Color.white.opacity(0.001)
                .frame(width: hitWidth, height: cueHeight)

            RoundedRectangle(cornerRadius: 5)
                .fill(Color.accentColor.opacity(0.28))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(
                            Color.accentColor,
                            lineWidth: 1.6
                        )
                )
            Text("\(cue.index)")
                .font(.caption2.monospacedDigit().bold())
                .foregroundStyle(.primary)
                .padding(.leading, 5)
                .lineLimit(1)
        }
        .frame(width: hitWidth, height: cueHeight, alignment: .leading)
        .contentShape(Rectangle())
        .offset(x: hitOffset, y: cueTopOffset)
        .zIndex(3)
        .help(cueTooltip(cue))
        .contextMenu {
            cueContextMenu(for: cue, language: language, actions: cueActions)
        }
    }

    private func cueHitOverlays(width: CGFloat, cueRange: Range<Array<SubtitleCue>.Index>) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(cues[cueRange]) { cue in
                let startX = xPosition(cue.start, width: width)
                let endX = xPosition(cue.end, width: width)
                let blockWidth = max(2, endX - startX)
                Color.white.opacity(0.001)
                    .frame(width: blockWidth, height: cueHeight)
                    .contentShape(Rectangle())
                    .offset(x: startX, y: cueTopOffset)
                    .help(cueTooltip(cue))
                    .onTapGesture {
                        selectedCueID = cue.id
                    }
                    .contextMenu {
                        cueContextMenu(for: cue, language: language, actions: cueActions)
                    }
            }
        }
        .zIndex(2)
    }

    private func handles(cue: Binding<SubtitleCue>, width: CGFloat) -> some View {
        let startX = xPosition(cue.wrappedValue.start, width: width)
        let endX = xPosition(cue.wrappedValue.end, width: width)
        let selected = cue.wrappedValue.id == selectedCueID
        let handleHitHeight = cueHeight + handleHitHeightExtra
        let handleYOffset = cueTopOffset - handleHitHeightExtra / 2

        return ZStack(alignment: .topLeading) {
            handleHitArea(selected: selected)
                .frame(width: handleHitWidth, height: handleHitHeight)
                .offset(x: startX - handleHitWidth / 2, y: handleYOffset)
                .gesture(handleDragGesture(for: cue, edge: .start, width: width))
                .help(Copy.text("editor.handleStart.help", language: language))

            handleHitArea(selected: selected)
                .frame(width: handleHitWidth, height: handleHitHeight)
                .offset(x: endX - handleHitWidth / 2, y: handleYOffset)
                .gesture(handleDragGesture(for: cue, edge: .end, width: width))
                .help(Copy.text("editor.handleEnd.help", language: language))
        }
        // Sit above both cueHitOverlays (z=2) and selectedCueOverlay (z=3) so the
        // handle's hit area (which straddles the cue boundary) isn't swallowed by
        // an adjacent cue's overlay.
        .zIndex(4)
    }

    private func handleHitArea(selected: Bool) -> some View {
        ZStack {
            Color.white.opacity(0.001)
            Capsule()
                .fill(Color.accentColor.opacity(selected ? 0.95 : 0.7))
                .frame(width: handleVisualWidth, height: cueHeight)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    private func handleDragGesture(for cue: Binding<SubtitleCue>, edge: Edge, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                isHandleDragging = true
                if dragSession?.cueID != cue.wrappedValue.id || dragSession?.edge != edge {
                    selectedCueID = cue.wrappedValue.id
                    dragSession = HandleDragSession(
                        cueID: cue.wrappedValue.id,
                        edge: edge,
                        initialStart: cue.wrappedValue.start,
                        initialEnd: cue.wrappedValue.end
                    )
                }
                guard let session = dragSession else { return }
                let delta = Double(value.translation.width / max(width, 1)) * duration
                switch edge {
                case .start:
                    var target = session.initialStart + delta
                    target = snappedTime(target, excluding: cue.wrappedValue.id, width: width)
                    cue.wrappedValue.start = max(0, min(target, cue.wrappedValue.end - 0.05))
                case .end:
                    var target = session.initialEnd + delta
                    target = snappedTime(target, excluding: cue.wrappedValue.id, width: width)
                    let upper = duration > 0 ? duration : target
                    cue.wrappedValue.end = max(cue.wrappedValue.start + 0.05, min(upper, target))
                }
            }
            .onEnded { _ in
                dragSession = nil
                isHandleDragging = false
                cues = SubtitleDocument.normalize(cues)
            }
    }

    /// Returns `target` snapped to the nearest other cue edge within ~5px on screen.
    /// Threshold scales with zoom (since seconds-per-pixel changes), so the "stickiness"
    /// always feels the same visually.
    private func snappedTime(_ target: Double, excluding cueID: SubtitleCue.ID, width: CGFloat) -> Double {
        let snapPixels: CGFloat = 5
        let secondsPerPixel = duration / Double(max(width, 1))
        let threshold = secondsPerPixel * Double(snapPixels)
        var bestEdge: Double?
        var bestDistance: Double = .infinity
        for other in cues where other.id != cueID {
            for edge in [other.start, other.end] {
                let dist = abs(edge - target)
                if dist < bestDistance {
                    bestDistance = dist
                    bestEdge = edge
                }
            }
        }
        if let bestEdge, bestDistance <= threshold {
            return bestEdge
        }
        return target
    }

    private func playbackCursor(width: CGFloat, height: CGFloat) -> some View {
        let cursorX = xPosition(currentTime, width: width)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.red.opacity(0.9))
                .frame(width: 1.5, height: max(1, height - rulerHeight - 4))
                .offset(x: cursorX - 0.75, y: 3)
            PlaybackCursorHead()
                .fill(Color.red)
                .frame(width: 11, height: 8)
                .offset(x: cursorX - 5.5, y: 0)
        }
    }

    private func cursorDragLayer(width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: width, height: cursorDragHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        isHandleDragging = true
                        onScrub(time(atX: value.location.x, width: width))
                    }
                    .onEnded { value in
                        isHandleDragging = false
                        onSeek(time(atX: value.location.x, width: width))
                    }
            )
            .help(Copy.text("editor.cursorDrag.help", language: language))
    }

    private func cueTooltip(_ cue: SubtitleCue) -> String {
        let times = "\(SubtitleDocument.displayTime(cue.start)) → \(SubtitleDocument.displayTime(cue.end))"
        let preview = cue.text.replacingOccurrences(of: "\n", with: " ")
        return "#\(cue.index)  \(times)\n\(preview)"
    }

    private func handleTimelineTap(at location: CGPoint, width: CGFloat, height: CGFloat) {
        let seconds = time(atX: location.x, width: width)
        if location.y <= cursorDragHeight {
            return
        }
        if location.y >= height - rulerHeight {
            onSeek(seconds)
            return
        }
        if let cue = cue(at: seconds) {
            selectedCueID = cue.id
        } else {
            onSeek(seconds)
        }
    }

    private func time(atX x: CGFloat, width: CGFloat) -> Double {
        clamp(Double(x / max(width, 1)) * duration, 0, duration)
    }

    private func cue(at seconds: Double) -> SubtitleCue? {
        cues.last { cue in
            seconds >= cue.start && seconds <= cue.end
        }
    }

    private func xPosition(_ seconds: Double, width: CGFloat) -> CGFloat {
        CGFloat(max(0, min(seconds / max(duration, 0.001), 1))) * width
    }

    private func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        if upper <= lower { return lower }
        return min(max(value, lower), upper)
    }
}

private struct PlaybackCursorHead: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

private struct TimeRulerCanvas: View, Equatable {
    nonisolated let duration: Double
    nonisolated let visibleFractionRange: ClosedRange<Double>
    nonisolated let language: AppLanguage

    private let intervals: [Double] = [1, 5, 10, 30, 60, 120, 300, 600, 1800, 3600]
    private let minimumMajorTickSpacing: CGFloat = 72

    nonisolated static func == (lhs: TimeRulerCanvas, rhs: TimeRulerCanvas) -> Bool {
        lhs.duration == rhs.duration
            && lhs.visibleFractionRange == rhs.visibleFractionRange
            && lhs.language == rhs.language
    }

    var body: some View {
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, size in
            drawRuler(in: &context, size: size)
        }
    }

    private func drawRuler(in context: inout GraphicsContext, size: CGSize) {
        guard duration > 0, size.width > 1 else { return }
        let width = max(size.width, 1)
        let height = max(size.height, 1)
        let startTime = max(0, visibleFractionRange.lowerBound * duration)
        let endTime = min(duration, max(startTime, visibleFractionRange.upperBound * duration))
        let interval = tickInterval(width: width)
        let firstTick = ceil(startTime / interval) * interval
        let baselineY = height - 5
        let textY = max(9, height - 17)

        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: baselineY))
        baseline.addLine(to: CGPoint(x: width, y: baselineY))
        context.stroke(baseline, with: .color(Color.secondary.opacity(0.28)), lineWidth: 0.8)

        var tick = firstTick
        var renderedTicks = 0
        while tick <= endTime + 0.001, renderedTicks < 240 {
            let x = CGFloat(tick / max(duration, 0.001)) * width
            var path = Path()
            path.move(to: CGPoint(x: x, y: baselineY))
            path.addLine(to: CGPoint(x: x, y: 4))
            context.stroke(path, with: .color(Color.secondary.opacity(0.45)), lineWidth: 0.8)

            let label = Text(SubtitleDocument.displayTime(tick))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            context.draw(label, at: CGPoint(x: x + 3, y: textY), anchor: .leading)
            renderedTicks += 1
            tick += interval
        }
    }

    private func tickInterval(width: CGFloat) -> Double {
        let pixelsPerSecond = width / CGFloat(max(duration, 0.001))
        for interval in intervals where CGFloat(interval) * pixelsPerSecond >= minimumMajorTickSpacing {
            return interval
        }
        return intervals.last ?? 120
    }
}

private struct StyledSubtitleText: View, Equatable {
    nonisolated let text: String
    nonisolated let font: Font
    nonisolated let lineLimit: Int?

    init(_ text: String, font: Font = .body, lineLimit: Int? = nil) {
        self.text = text
        self.font = font
        self.lineLimit = lineLimit
    }

    var body: some View {
        Text(SubtitleMarkupRenderer.attributedString(from: text))
            .font(font)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: true)
    }

    nonisolated static func == (lhs: StyledSubtitleText, rhs: StyledSubtitleText) -> Bool {
        lhs.text == rhs.text && lhs.lineLimit == rhs.lineLimit
    }
}

private enum SubtitleMarkupRenderer {
    private struct StyleState {
        var boldDepth = 0
        var italicDepth = 0
        var underlineDepth = 0
        var colorStack: [Color] = []

        var isBold: Bool { boldDepth > 0 }
        var isItalic: Bool { italicDepth > 0 }
        var isUnderlined: Bool { underlineDepth > 0 }
        var color: Color? { colorStack.last }
    }

    private struct Fragment {
        let text: String
        let style: StyleState
    }

    static func attributedString(from raw: String) -> AttributedString {
        var result = AttributedString()
        for fragment in fragments(from: raw) {
            result += attributedFragment(fragment)
        }
        return result
    }

    private static func fragments(from raw: String) -> [Fragment] {
        var fragments: [Fragment] = []
        var state = StyleState()
        var cursor = raw.startIndex
        var textStart = raw.startIndex

        func appendText(until end: String.Index) {
            guard textStart < end else { return }
            fragments.append(Fragment(text: String(raw[textStart..<end]), style: state))
        }

        while cursor < raw.endIndex {
            guard raw[cursor] == "<",
                  let tagEnd = raw[cursor...].firstIndex(of: ">") else {
                cursor = raw.index(after: cursor)
                continue
            }

            let tag = String(raw[cursor...tagEnd])
            var nextState = state
            if apply(tag, to: &nextState) {
                appendText(until: cursor)
                state = nextState
                cursor = raw.index(after: tagEnd)
                textStart = cursor
            } else {
                cursor = raw.index(after: cursor)
            }
        }

        appendText(until: raw.endIndex)
        return fragments
    }

    private static func attributedFragment(_ fragment: Fragment) -> AttributedString {
        var attributed = AttributedString(fragment.text)
        var intents = InlinePresentationIntent()
        if fragment.style.isBold {
            intents.insert(.stronglyEmphasized)
        }
        if fragment.style.isItalic {
            intents.insert(.emphasized)
        }
        if !intents.isEmpty {
            attributed.inlinePresentationIntent = intents
        }
        if fragment.style.isUnderlined {
            attributed.underlineStyle = .single
        }
        if let color = fragment.style.color {
            attributed.foregroundColor = color
        }
        return attributed
    }

    private static func apply(_ tag: String, to state: inout StyleState) -> Bool {
        let lower = tag.lowercased()
        switch lower {
        case "<b>":
            state.boldDepth += 1
            return true
        case "</b>":
            state.boldDepth = max(0, state.boldDepth - 1)
            return true
        case "<i>":
            state.italicDepth += 1
            return true
        case "</i>":
            state.italicDepth = max(0, state.italicDepth - 1)
            return true
        case "<u>":
            state.underlineDepth += 1
            return true
        case "</u>":
            state.underlineDepth = max(0, state.underlineDepth - 1)
            return true
        case "</font>":
            if !state.colorStack.isEmpty {
                state.colorStack.removeLast()
            }
            return true
        default:
            guard lower.hasPrefix("<font"),
                  let color = fontColor(from: tag) else {
                return false
            }
            state.colorStack.append(color)
            return true
        }
    }

    private static func fontColor(from tag: String) -> Color? {
        guard let regex = try? NSRegularExpression(pattern: #"(?i)color\s*=\s*["']?([^"'\s>]+)"#) else {
            return nil
        }
        let nsRange = NSRange(tag.startIndex..<tag.endIndex, in: tag)
        guard let match = regex.firstMatch(in: tag, range: nsRange),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: tag) else {
            return nil
        }
        return color(from: String(tag[valueRange]))
    }

    private static func color(from raw: String) -> Color? {
        let value = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        let named: [String: Color] = [
            "white": .white,
            "black": .black,
            "red": .red,
            "green": .green,
            "blue": .blue,
            "yellow": .yellow,
            "cyan": .cyan,
            "magenta": .purple
        ]
        if let color = named[value.lowercased()] {
            return color
        }

        let hex = value.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let expanded: String
        if hex.count == 3 {
            expanded = hex.map { "\($0)\($0)" }.joined()
        } else {
            expanded = hex
        }
        guard expanded.count == 6,
              let rgb = Int(expanded, radix: 16) else {
            return nil
        }
        return Color(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}

private struct SubtitleCueBlockRow: View {
    @Binding var cue: SubtitleCue
    let isSelected: Bool
    let canReset: Bool
    let select: () -> Void
    let reset: () -> Void
    let duplicate: () -> Void
    let insertBefore: () -> Void
    let insertAfter: () -> Void
    let closeGap: () -> Void
    let delete: () -> Void
    let language: AppLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("#\(cue.index)")
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(isSelected ? .primary : .secondary)
                Text(timeRange)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Text(durationText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            StyledSubtitleText(cue.text, font: .body, lineLimit: 3)
                .equatable()
                .textSelection(.enabled)
                .frame(minHeight: 48, maxHeight: 84, alignment: .topLeading)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .contentShape(RoundedRectangle(cornerRadius: 6))
                .onTapGesture(perform: select)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                    lineWidth: isSelected ? 1.2 : 0.6
                )
            )
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture(perform: select)
        .contextMenu {
            Button {
                reset()
            } label: {
                Label(Copy.text("editor.resetCue", language: language), systemImage: "arrow.counterclockwise")
            }
            .disabled(!canReset)

            Button {
                duplicate()
            } label: {
                Label(Copy.text("editor.duplicateCue", language: language), systemImage: "plus.square.on.square")
            }

            Divider()

            Button {
                insertBefore()
            } label: {
                Label(Copy.text("editor.addBefore", language: language), systemImage: "arrow.up.to.line.compact")
            }

            Button {
                insertAfter()
            } label: {
                Label(Copy.text("editor.addAfter", language: language), systemImage: "arrow.down.to.line.compact")
            }

            Button {
                closeGap()
            } label: {
                Label(Copy.text("editor.closeGap", language: language), systemImage: "arrow.left.and.right")
            }

            Divider()

            Button(role: .destructive) {
                delete()
            } label: {
                Label(Copy.text("editor.deleteCue", language: language), systemImage: "trash")
            }
        }
    }

    private var timeRange: String {
        "\(SubtitleDocument.displayTime(cue.start)) -> \(SubtitleDocument.displayTime(cue.end))"
    }

    private var durationText: String {
        String(format: "%.2fs", cue.duration)
    }

    private var rowBackground: Color {
        isSelected ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor)
    }
}

private struct SelectableTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange?
    let onActivate: () -> Void

    init(
        text: Binding<String>,
        selection: Binding<NSRange?> = .constant(nil),
        onActivate: @escaping () -> Void
    ) {
        _text = text
        _selection = selection
        self.onActivate = onActivate
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, selection: $selection, onActivate: onActivate)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder

        let textView = ActivatingTextView()
        textView.onActivate = onActivate
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .preferredFont(forTextStyle: .body)
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        context.coordinator.selection = $selection
        context.coordinator.onActivate = onActivate
        if let activatingTextView = textView as? ActivatingTextView {
            activatingTextView.onActivate = onActivate
        }
        // Bail out while an input method (Chinese, Japanese, etc.) is composing —
        // touching `string` or `selectedRange` would cancel the composition.
        if textView.hasMarkedText() { return }

        // Suppress delegate writes back to the SwiftUI binding while we mutate
        // the text view programmatically. Without this guard, setting `string`
        // or `setSelectedRange` synchronously triggers the delegate, which would
        // try to write SwiftUI state mid-update.
        context.coordinator.isApplyingUpdate = true
        defer { context.coordinator.isApplyingUpdate = false }

        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            if let selection, NSMaxRange(selection) <= textView.string.utf16.count {
                textView.setSelectedRange(selection)
            } else {
                restoreSelection(selectedRanges, in: textView)
            }
        } else if let selection,
                  NSMaxRange(selection) <= textView.string.utf16.count,
                  textView.selectedRange() != selection {
            textView.setSelectedRange(selection)
        }
    }

    private func restoreSelection(_ ranges: [NSValue], in textView: NSTextView) {
        let textLength = textView.string.utf16.count
        let validRanges: [NSValue] = ranges.compactMap { value in
            let range = value.rangeValue
            guard NSMaxRange(range) <= textLength else { return nil }
            return value
        }
        if validRanges.isEmpty {
            textView.setSelectedRange(NSRange(location: textLength, length: 0))
        } else {
            textView.selectedRanges = validRanges
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var selection: Binding<NSRange?>
        var onActivate: () -> Void
        var isApplyingUpdate = false

        init(text: Binding<String>, selection: Binding<NSRange?>, onActivate: @escaping () -> Void) {
            self.text = text
            self.selection = selection
            self.onActivate = onActivate
        }

        func textDidBeginEditing(_ notification: Notification) {
            onActivate()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            // Don't propagate intermediate IME composition states upward —
            // the final string will be delivered once the user picks a candidate.
            if textView.hasMarkedText() { return }
            if isApplyingUpdate { return }
            if text.wrappedValue != textView.string {
                text.wrappedValue = textView.string
            }
            updateSelection(from: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            if textView.hasMarkedText() { return }
            // Ignore selection callbacks driven by our own setSelectedRange — they would
            // try to write back into the SwiftUI binding mid view-update.
            if isApplyingUpdate { return }
            updateSelection(from: textView)
        }

        private func updateSelection(from textView: NSTextView) {
            let range = textView.selectedRange()
            let newValue: NSRange?
            if range.length > 0 {
                newValue = range
            } else if textView.window?.firstResponder === textView {
                newValue = nil
            } else {
                return
            }
            if selection.wrappedValue != newValue {
                selection.wrappedValue = newValue
            }
        }
    }

    final class ActivatingTextView: NSTextView {
        var onActivate: (() -> Void)?

        override func mouseDown(with event: NSEvent) {
            onActivate?()
            super.mouseDown(with: event)
        }

        override func becomeFirstResponder() -> Bool {
            onActivate?()
            return super.becomeFirstResponder()
        }
    }
}

final class WaveformSamples: Equatable, @unchecked Sendable {
    let values: [CGFloat]

    init(_ values: [CGFloat]) {
        self.values = values
    }

    static func == (lhs: WaveformSamples, rhs: WaveformSamples) -> Bool {
        lhs === rhs
    }
}

private struct WaveformCanvas: View, Equatable {
    nonisolated let samples: WaveformSamples
    nonisolated let visibleFractionRange: ClosedRange<Double>
    nonisolated let color: Color
    nonisolated let verticalPadding: CGFloat
    nonisolated let minimumBarWidth: CGFloat
    nonisolated let bottomPadding: CGFloat

    init(
        samples: WaveformSamples,
        visibleFractionRange: ClosedRange<Double>,
        color: Color,
        verticalPadding: CGFloat,
        minimumBarWidth: CGFloat,
        bottomPadding: CGFloat? = nil
    ) {
        self.samples = samples
        self.visibleFractionRange = visibleFractionRange
        self.color = color
        self.verticalPadding = verticalPadding
        self.minimumBarWidth = minimumBarWidth
        self.bottomPadding = bottomPadding ?? verticalPadding
    }

    nonisolated static func == (lhs: WaveformCanvas, rhs: WaveformCanvas) -> Bool {
        lhs.samples === rhs.samples
            && lhs.visibleFractionRange == rhs.visibleFractionRange
            && lhs.color == rhs.color
            && lhs.verticalPadding == rhs.verticalPadding
            && lhs.minimumBarWidth == rhs.minimumBarWidth
            && lhs.bottomPadding == rhs.bottomPadding
    }

    var body: some View {
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, size in
            drawWaveform(in: &context, size: size)
        }
    }

    private func drawWaveform(in context: inout GraphicsContext, size: CGSize) {
        let rect = CGRect(
            x: 0,
            y: verticalPadding,
            width: max(1, size.width),
            height: max(1, size.height - verticalPadding - bottomPadding)
        )
        let values = samples.values
        guard !values.isEmpty else {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            context.stroke(path, with: .color(color.opacity(0.7)), lineWidth: 1)
            return
        }

        let sampleCount = values.count
        let lowerFraction = max(0, min(1, visibleFractionRange.lowerBound))
        let upperFraction = max(lowerFraction, min(1, visibleFractionRange.upperBound))
        let nativeStep = rect.width / CGFloat(max(sampleCount, 1))
        let strideSize = max(1, Int(ceil(minimumBarWidth / max(nativeStep, 0.001))))
        let lowerIndex = max(0, Int(floor(lowerFraction * Double(sampleCount))) - strideSize)
        let upperIndex = min(sampleCount - 1, Int(ceil(upperFraction * Double(sampleCount))) + strideSize)
        guard lowerIndex <= upperIndex else { return }

        let fillShading = GraphicsContext.Shading.color(color)

        var index = lowerIndex
        while index <= upperIndex {
            let nextIndex = min(upperIndex + 1, index + strideSize)
            var peak: CGFloat = 0
            var i = index
            while i < nextIndex {
                let v = values[i]
                if v > peak { peak = v }
                i += 1
            }
            if peak > 1 { peak = 1 }
            let barHeight = max(1, rect.height * peak)
            let x = rect.minX + CGFloat(index) * nativeStep
            let barWidth = max(1, CGFloat(nextIndex - index) * nativeStep * 0.72)
            let barRect = CGRect(
                x: x,
                y: rect.midY - barHeight / 2,
                width: barWidth,
                height: barHeight
            )
            context.fill(Path(roundedRect: barRect, cornerRadius: 1), with: fillShading)
            index = nextIndex
        }
    }
}

private struct WaveformShape: Shape {
    let samples: [CGFloat]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard !samples.isEmpty else {
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }

        let step = rect.width / CGFloat(samples.count)
        for (index, sample) in samples.enumerated() {
            let amplitude = min(max(sample, 0), 1)
            let height = max(1, rect.height * amplitude)
            let x = rect.minX + CGFloat(index) * step
            let y = rect.midY - height / 2
            path.addRoundedRect(
                in: CGRect(x: x, y: y, width: max(1, step * 0.7), height: height),
                cornerSize: CGSize(width: 1, height: 1)
            )
        }
        return path
    }
}

/// Resolves a media URL to a URL that AVFoundation can fully play and read.
/// For natively-supported containers it returns the original URL untouched.
/// For containers AVFoundation only partially understands (MKV, AVI, WMV…) it
/// transcodes the audio track to an m4a sitting in the caches directory once,
/// then re-uses that file for both playback and waveform sampling.
enum AudioSource {
    private static let cache = AudioExtractionCache()
    private static let directlyPlayableExtensions: Set<String> = [
        "mp4", "mov", "m4v", "qt", "3gp", "3g2",
        "m4a", "mp3", "wav", "aac", "aiff", "aif", "flac", "caf"
    ]

    static func resolve(_ url: URL) async -> URL {
        let ext = url.pathExtension.lowercased()
        if directlyPlayableExtensions.contains(ext) {
            return url
        }
        if let extracted = await cache.extracted(for: url) {
            return extracted
        }
        return url
    }
}

private actor AudioExtractionCache {
    private var inflight: [String: Task<URL?, Never>] = [:]

    func extracted(for source: URL) async -> URL? {
        let key = Self.identifier(for: source)
        let dest = Self.destinationURL(for: key)

        if FileManager.default.fileExists(atPath: dest.path) {
            if await Self.isUsable(dest) {
                return dest
            }
            // Stale extraction from a previous build (e.g. partial AVFoundation
            // output from before ffmpeg was wired in). Discard and re-extract.
            NSLog("[MSub] Discarding unusable cached extraction at %@", dest.path)
            try? FileManager.default.removeItem(at: dest)
        }
        if let task = inflight[key] {
            return await task.value
        }
        let task = Task<URL?, Never> {
            await Self.performExtraction(from: source, to: dest)
        }
        inflight[key] = task
        let result = await task.value
        inflight[key] = nil
        return result
    }

    /// A previously-cached extraction is considered usable only if AVFoundation
    /// can read a positive duration from it — that filters out empty/partial
    /// outputs left over from earlier failed runs.
    private static func isUsable(_ url: URL) async -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value,
              size > 1024 else {
            return false
        }
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration),
              duration.seconds.isFinite,
              duration.seconds > 0.3 else {
            return false
        }
        return true
    }

    private static func identifier(for url: URL) -> String {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        let size = values?.fileSize ?? 0
        let input = "\(url.standardizedFileURL.path)#\(modified)#\(size)"
        let digest = SHA256.hash(data: Data(input.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func destinationURL(for identifier: String) -> URL {
        let base: URL
        if let dir = try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            base = dir
        } else {
            base = FileManager.default.temporaryDirectory
        }
        // Bump this suffix whenever the extraction pipeline changes so prior
        // partial/incompatible outputs are sidestepped automatically.
        let dir = base.appendingPathComponent("MSub-extracted-audio-v2", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(identifier).m4a")
    }

    private static func performExtraction(from source: URL, to dest: URL) async -> URL? {
        // We only reach this for containers that aren't on the directly-playable
        // list — meaning AVFoundation will almost certainly log noisy FFR_* errors
        // before giving up. Prefer ffmpeg whenever it's available so we skip that
        // failed AVF round-trip entirely.
        if FFmpegRunner.isAvailable,
           let url = await FFmpegRunner.extractAudio(from: source, to: dest) {
            return url
        }

        // ffmpeg isn't around or its conversion failed — fall back to AVFoundation
        // (some non-listed extensions like .ogg still demux fine through AVF).
        let asset = AVURLAsset(url: source)
        if let _ = try? await asset.loadTracks(withMediaType: .audio).first,
           let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
           ) {
            try? FileManager.default.removeItem(at: dest)
            do {
                try await exportSession.export(to: dest, as: .m4a)
                if FileManager.default.fileExists(atPath: dest.path) {
                    return dest
                }
            } catch {
                try? FileManager.default.removeItem(at: dest)
            }
        }

        return nil
    }
}

/// Locates and invokes ffmpeg so we can handle containers AVFoundation can't read
/// (MKV, AVI, etc.). Search order:
///   1. `ffmpeg` binary copied into the app bundle's Resources
///   2. Common system locations (Homebrew, MacPorts, /usr)
/// If nothing is found, every call returns nil and the AVFoundation path remains
/// the only audio source.
enum FFmpegRunner {
    private static let searchPaths = [
        "/opt/homebrew/bin/ffmpeg",
        "/usr/local/bin/ffmpeg",
        "/opt/local/bin/ffmpeg",
        "/usr/bin/ffmpeg"
    ]

    static let binary: URL? = {
        let resolved = locateBinary()
        if let resolved {
            NSLog("[MSub] FFmpeg located at: %@", resolved.path)
        } else {
            NSLog("[MSub] FFmpeg not found in bundle or system search paths")
        }
        return resolved
    }()

    private static func locateBinary() -> URL? {
        if let bundled = Bundle.main.url(forResource: "ffmpeg", withExtension: nil) {
            let path = bundled.path
            if !FileManager.default.isExecutableFile(atPath: path) {
                // Xcode sometimes strips the execute bit when copying resources.
                // In a dev build the bundle is writable, so try to fix it in place.
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            }
            if FileManager.default.isExecutableFile(atPath: path) {
                return bundled
            } else {
                NSLog("[MSub] FFmpeg bundled at %@ is not executable; run `chmod +x` on the source file before building.", path)
            }
        }
        for path in searchPaths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    static var isAvailable: Bool { binary != nil }

    /// Extracts the audio track of `source` to `dest` as AAC-in-m4a. When `start`
    /// and `duration` are provided, only that slice is exported.
    static func extractAudio(
        from source: URL,
        to dest: URL,
        start: Double? = nil,
        duration: Double? = nil
    ) async -> URL? {
        guard let binary else { return nil }
        try? FileManager.default.removeItem(at: dest)

        var args: [String] = ["-y", "-nostdin", "-loglevel", "error"]
        if let start {
            args.append("-ss")
            args.append(String(format: "%.3f", max(0, start)))
        }
        if let duration {
            args.append("-t")
            args.append(String(format: "%.3f", max(0.05, duration)))
        }
        args.append(contentsOf: [
            "-i", source.path,
            "-vn",
            "-c:a", "aac",
            "-b:a", "192k",
            "-ar", "44100",
            "-movflags", "+faststart",
            dest.path
        ])

        let rangeNote: String
        if let start, let duration {
            rangeNote = String(format: " (range %.2fs+%.2fs)", start, duration)
        } else {
            rangeNote = ""
        }
        NSLog("[MSub] FFmpeg starting on %@%@", source.lastPathComponent, rangeNote)

        let started = Date()
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()  // discard; prevents inherited stdout

        do {
            try process.run()
        } catch {
            NSLog("[MSub] FFmpeg launch failed for %@: %@", source.lastPathComponent, "\(error)")
            return nil
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in cont.resume() }
        }

        let elapsed = Date().timeIntervalSince(started)
        let exitCode = process.terminationStatus
        if exitCode != 0 {
            let data = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
            let text = (String(data: data, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            NSLog(
                "[MSub] FFmpeg exit %d on %@ in %.2fs: %@",
                Int(exitCode), source.lastPathComponent, elapsed, text
            )
            try? FileManager.default.removeItem(at: dest)
            return nil
        }

        if FileManager.default.fileExists(atPath: dest.path) {
            let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? 0
            NSLog(
                "[MSub] FFmpeg ok on %@ in %.2fs → %lld bytes at %@",
                source.lastPathComponent, elapsed, size, dest.path
            )
            return dest
        }
        NSLog(
            "[MSub] FFmpeg exited 0 but produced no file for %@ in %.2fs",
            source.lastPathComponent, elapsed
        )
        return nil
    }

    /// Probes the source for its duration in seconds. Useful for containers
    /// AVFoundation refuses to parse (MKV, AVI…). Returns nil on failure.
    static func probeDuration(of source: URL) async -> Double? {
        guard let binary else { return nil }
        let process = Process()
        process.executableURL = binary
        // `-i` without an output file prints stream info to stderr and exits
        // non-zero. That's expected — we only care about the printed Duration.
        process.arguments = ["-nostdin", "-hide_banner", "-i", source.path]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in cont.resume() }
        }
        let data = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return parseFFmpegDuration(text)
    }

    private static func parseFFmpegDuration(_ output: String) -> Double? {
        let pattern = #"Duration:\s*(\d{1,2}):(\d{2}):(\d{2})\.(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              match.numberOfRanges >= 5,
              let hRange = Range(match.range(at: 1), in: output),
              let mRange = Range(match.range(at: 2), in: output),
              let sRange = Range(match.range(at: 3), in: output),
              let csRange = Range(match.range(at: 4), in: output) else {
            return nil
        }
        let hStr = output[hRange]
        let mStr = output[mRange]
        let sStr = output[sRange]
        let csStr = output[csRange]
        guard let h = Int(hStr), let m = Int(mStr), let s = Int(sStr), let cs = Int(csStr) else {
            return nil
        }
        let fractional = Double(cs) / pow(10.0, Double(csStr.count))
        let total = Double(h * 3600 + m * 60 + s) + fractional
        return total > 0 ? total : nil
    }

    /// Decodes a single video frame from `source` at `seconds` into a JPEG
    /// written into the temporary directory. Caller is responsible for deleting
    /// the returned file once the image is loaded.
    static func extractFrame(
        from source: URL,
        at seconds: Double,
        width: Int? = 640
    ) async -> URL? {
        guard let binary else { return nil }
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("MSub-frame-\(UUID().uuidString).jpg")

        // `-ss` before `-i` enables fast seeking (key-frame accurate),
        // which is what we want for thumbnail-style frame grabs.
        var args: [String] = [
            "-y", "-nostdin", "-loglevel", "error",
            "-ss", String(format: "%.3f", max(0, seconds)),
            "-i", source.path,
            "-frames:v", "1"
        ]
        if let width {
            args.append(contentsOf: ["-vf", "scale=\(width):-2"])
        }
        args.append(contentsOf: ["-q:v", "4", dest.path])

        let process = Process()
        process.executableURL = binary
        process.arguments = args
        process.standardError = Pipe()
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in cont.resume() }
        }
        if process.terminationStatus == 0, FileManager.default.fileExists(atPath: dest.path) {
            return dest
        }
        try? FileManager.default.removeItem(at: dest)
        return nil
    }
}

private enum WaveformLoader {
    private static let cache = WaveformCache()

    static func samples(for url: URL, targetSamples: Int) async -> [CGFloat] {
        let safeTargetSamples = max(1, targetSamples)
        return await cache.samples(for: url, targetSamples: safeTargetSamples)
    }

    private static func readSamples(for url: URL, targetSamples: Int) async -> [CGFloat] {
        let asset = AVURLAsset(url: url)
        guard let track = (try? await asset.loadTracks(withMediaType: .audio))?.first,
              let reader = try? AVAssetReader(asset: asset) else {
            return []
        }

        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsNonInterleaved: false
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return [] }
        reader.add(output)

        let formatDescriptions = (try? await track.load(.formatDescriptions)) ?? []
        let audioDescription = formatDescriptions.first
        let streamDescription = audioDescription.flatMap {
            CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee
        }
        let sampleRate = streamDescription?.mSampleRate ?? 16_000
        let channelCount = max(1, Int(streamDescription?.mChannelsPerFrame ?? 1))
        let duration = (try? await asset.load(.duration)) ?? .zero
        let estimatedFrames = max(1, Int(CMTimeGetSeconds(duration) * sampleRate))
        let binSize = max(1, estimatedFrames / max(1, targetSamples))
        // Sample only a sparse subset of frames per bin to find the peak — for typical
        // bin sizes (thousands of frames each), 32 samples per bin is a faithful peak
        // estimate at a fraction of the CPU cost.
        let samplesPerBin = 32
        let frameStride = max(1, binSize / samplesPerBin)
        var bins = [Float](repeating: 0, count: max(1, targetSamples))

        guard reader.startReading() else { return [] }

        var frameIndex = 0
        while let sampleBuffer = output.copyNextSampleBuffer(),
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
            let length = CMBlockBufferGetDataLength(blockBuffer)
            guard length > 0 else { continue }
            var data = Data(count: length)
            let copyResult = data.withUnsafeMutableBytes { buffer in
                CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: length,
                    destination: buffer.baseAddress!
                )
            }
            guard copyResult == noErr else { continue }
            data.withUnsafeBytes { rawBuffer in
                let floats = rawBuffer.bindMemory(to: Float.self)
                let chunkFrames = floats.count / max(channelCount, 1)
                // Align the first frame to sample in this chunk to the global stride grid.
                let strideRemainder = frameIndex % frameStride
                var localFrame = strideRemainder == 0 ? 0 : (frameStride - strideRemainder)
                while localFrame < chunkFrames {
                    let offset = localFrame * channelCount
                    var sum: Float = 0
                    for channel in 0..<channelCount where offset + channel < floats.count {
                        sum += abs(floats[offset + channel])
                    }
                    let amplitude = sum / Float(channelCount)
                    let globalFrame = frameIndex + localFrame
                    let bin = min(bins.count - 1, globalFrame / binSize)
                    if amplitude > bins[bin] { bins[bin] = amplitude }
                    localFrame += frameStride
                }
                frameIndex += chunkFrames
            }
        }

        reader.cancelReading()
        let peak = max(bins.max() ?? 0, 0.0001)
        return bins.map { CGFloat(min(1, $0 / peak)) }
    }

    private actor WaveformCache {
        private struct Entry {
            let samples: [CGFloat]
            let sampleCount: Int
            let lastAccess: Date
        }

        private var entries: [String: Entry] = [:]
        // Allow a few high-resolution waveforms (~1M samples each) to coexist
        // in the cache so deep zooms stay instant after the first read.
        private let maxCachedSamples = 5_000_000

        func samples(for url: URL, targetSamples: Int) async -> [CGFloat] {
            let key = cacheKey(for: url)
            if let cached = entries[key], cached.sampleCount >= targetSamples {
                entries[key] = Entry(samples: cached.samples, sampleCount: cached.sampleCount, lastAccess: Date())
                return downsample(cached.samples, targetSamples: targetSamples)
            }

            let samples = await Task.detached(priority: .userInitiated) {
                await WaveformLoader.readSamples(for: url, targetSamples: targetSamples)
            }.value
            guard !samples.isEmpty else { return [] }

            if let cached = entries[key], cached.sampleCount > samples.count {
                entries[key] = Entry(samples: cached.samples, sampleCount: cached.sampleCount, lastAccess: Date())
                return downsample(cached.samples, targetSamples: targetSamples)
            }

            entries[key] = Entry(samples: samples, sampleCount: samples.count, lastAccess: Date())
            trimIfNeeded()
            return samples
        }

        private func cacheKey(for url: URL) -> String {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            let size = values?.fileSize ?? 0
            return "\(url.standardizedFileURL.path)#\(modified)#\(size)"
        }

        private func trimIfNeeded() {
            var totalSamples = entries.values.reduce(0) { $0 + $1.sampleCount }
            guard totalSamples > maxCachedSamples else { return }
            let sortedKeys = entries.sorted { $0.value.lastAccess < $1.value.lastAccess }.map(\.key)
            for key in sortedKeys where totalSamples > maxCachedSamples {
                if let removed = entries.removeValue(forKey: key) {
                    totalSamples -= removed.sampleCount
                }
            }
        }

        private func downsample(_ samples: [CGFloat], targetSamples: Int) -> [CGFloat] {
            guard targetSamples > 0, samples.count > targetSamples else { return samples }
            let sourceCount = samples.count
            let scale = Double(sourceCount) / Double(targetSamples)
            return (0..<targetSamples).map { index in
                let lower = Int(floor(Double(index) * scale))
                let upper = min(sourceCount, max(lower + 1, Int(ceil(Double(index + 1) * scale))))
                var peak: CGFloat = 0
                for sampleIndex in lower..<upper {
                    peak = max(peak, samples[sampleIndex])
                }
                return peak
            }
        }
    }
}
