import AppKit
import AVFoundation
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

extension FileSlot {
    var editableSubtitleText: String {
        if !cues.isEmpty {
            SubtitleDocument.serialize(cues, format: outputFormat)
        } else {
            previewText
        }
    }

    var hasEditableSubtitle: Bool {
        !editableSubtitleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        player.pause()
        player.replaceCurrentItem(with: item)

        let loadedDuration = (try? await asset.load(.duration)) ?? .zero
        let seconds = loadedDuration.seconds
        if seconds.isFinite, seconds > 0 {
            duration = seconds
        }
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        hasVideo = !videoTracks.isEmpty
    }

    func seek(to seconds: Double, pause: Bool = false) {
        let target = max(0, seconds.isFinite ? seconds : 0)
        let clamped = duration > 0 ? min(target, duration) : target
        currentTime = clamped
        if pause { player.pause() }
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlayPause() {
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    private func attachObservers() {
        let interval = CMTime(seconds: 1.0 / 30.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
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
    let language: AppLanguage
    @ObservedObject var playback: PlaybackController

    @State private var waveform: [CGFloat] = []
    @State private var isLoadingWaveform = false
    @State private var timelineZoom = 1.0

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
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label(Copy.text("editor.timeline", language: language), systemImage: "waveform")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        if isLoadingWaveform {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(timecodeLabel)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        Button {
                            timelineZoom = max(1.0, timelineZoom - 0.5)
                        } label: {
                            Image(systemName: "minus.magnifyingglass")
                        }
                        .buttonStyle(.borderless)
                        .help(Copy.text("editor.zoomOut", language: language))

                        Slider(value: $timelineZoom, in: 1...maxTimelineZoom, step: 0.5) {
                            Text(Copy.text("editor.zoom", language: language))
                        }
                        .frame(maxWidth: 210)

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
                        waveform: waveform,
                        duration: duration,
                        zoom: timelineZoom,
                        currentTime: playback.currentTime,
                        language: language,
                        onSeek: { time in
                            playback.seek(to: time, pause: true)
                        }
                    )
                    .frame(height: 118)
                }
                .padding(12)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
                .onChange(of: maxTimelineZoom) { _, newValue in
                    timelineZoom = min(timelineZoom, newValue)
                }

                HStack(alignment: .top, spacing: 12) {
                    subtitleBlocks
                        .frame(minWidth: 300)

                    selectedCueEditor
                        .frame(width: 250)
                }
            }
        }
        .task(id: slot.url) {
            await loadWaveform()
        }
        .onChange(of: slot.selectedCueID) { _, newValue in
            guard let newValue,
                  let cue = slot.cues.first(where: { $0.id == newValue }) else { return }
            playback.seek(to: cue.start, pause: true)
        }
        .onChange(of: slot.cues) { _, newValue in
            let normalized = SubtitleDocument.normalize(newValue)
            if normalized.map(\.id) == newValue.map(\.id),
               zip(normalized, newValue).allSatisfy({ lhs, rhs in
                   lhs.index == rhs.index && lhs.start == rhs.start && lhs.end == rhs.end
               }) {
                slot.previewText = SubtitleDocument.serialize(newValue, format: slot.outputFormat)
            } else {
                slot.cues = normalized
                slot.previewText = SubtitleDocument.serialize(normalized, format: slot.outputFormat)
            }
        }
    }

    private var timecodeLabel: String {
        let current = SubtitleDocument.displayTime(playback.currentTime)
        let total = SubtitleDocument.displayTime(duration)
        return "\(current) / \(total)"
    }

    private var subtitleBlocks: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach($slot.cues) { $cue in
                        SubtitleCueBlockRow(
                            cue: $cue,
                            isSelected: cue.id == slot.selectedCueID,
                            select: { slot.selectedCueID = cue.id }
                        )
                        .id(cue.id)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 300, maxHeight: 520)
            .onChange(of: slot.selectedCueID) { _, newValue in
                guard let newValue else { return }
                withAnimation(.easeInOut(duration: 0.18)) {
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private var selectedCueEditor: some View {
        if let selectedCueIndex {
            VStack(alignment: .leading, spacing: 10) {
                Text(Copy.text("editor.selected", language: language))
                    .font(.subheadline.weight(.semibold))

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Button {
                            selectPreviousCue()
                        } label: {
                            Label(Copy.text("editor.previous", language: language), systemImage: "chevron.up")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(selectedCueIndex <= 0)

                        Button {
                            selectNextCue()
                        } label: {
                            Label(Copy.text("editor.next", language: language), systemImage: "chevron.down")
                                .frame(maxWidth: .infinity)
                        }
                        .disabled(selectedCueIndex >= slot.cues.count - 1)
                    }

                    Button {
                        insertCueAfterSelection()
                    } label: {
                        Label(Copy.text("editor.addAfter", language: language), systemImage: "plus.rectangle.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .help(Copy.text("editor.addAfter.help", language: language))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                SelectableTextEditor(text: $slot.cues[selectedCueIndex].text) {}
                    .frame(height: 118)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))

                compactNumberField(
                    Copy.text("editor.start", language: language),
                    value: $slot.cues[selectedCueIndex].start
                )
                compactNumberField(
                    Copy.text("editor.end", language: language),
                    value: $slot.cues[selectedCueIndex].end
                )

                HStack {
                    Text(Copy.text("editor.duration", language: language))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.2fs", slot.cues[selectedCueIndex].duration))
                        .font(.caption.monospacedDigit().bold())
                }

                Text(Copy.text("editor.dragHelp", language: language))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
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

    private func loadWaveform() async {
        isLoadingWaveform = true
        defer { isLoadingWaveform = false }
        waveform = await WaveformLoader.samples(for: slot.url, targetSamples: 720)
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
        let insertionIndex = selectedCueIndex.map { $0 + 1 } ?? slot.cues.count
        let previous = insertionIndex > 0 ? slot.cues[insertionIndex - 1] : nil
        let next = insertionIndex < slot.cues.count ? slot.cues[insertionIndex] : nil
        let start = previous?.end ?? 0
        let defaultEnd = start + 2.0
        let end: Double
        if let next, next.start > start + 0.2 {
            end = min(defaultEnd, next.start - 0.05)
        } else {
            end = defaultEnd
        }
        let cue = SubtitleCue(index: insertionIndex + 1, start: start, end: end, text: "")
        slot.cues.insert(cue, at: insertionIndex)
        slot.cues = SubtitleDocument.normalize(slot.cues)
        slot.selectedCueID = cue.id
    }
}

private struct ZoomableTimeline: View {
    @Binding var cues: [SubtitleCue]
    @Binding var selectedCueID: SubtitleCue.ID?

    let waveform: [CGFloat]
    let duration: Double
    let zoom: Double
    let currentTime: Double
    let language: AppLanguage
    let onSeek: (Double) -> Void

    @State private var isHandleDragging = false
    @State private var scrollPosition = ScrollPosition()

    var body: some View {
        GeometryReader { proxy in
            let viewportWidth = proxy.size.width
            let contentWidth = max(viewportWidth, viewportWidth * zoom)

            ScrollView(.horizontal, showsIndicators: true) {
                WaveformTimelineEditor(
                    cues: $cues,
                    selectedCueID: $selectedCueID,
                    isHandleDragging: $isHandleDragging,
                    waveform: waveform,
                    duration: duration,
                    currentTime: currentTime,
                    language: language,
                    onSeek: onSeek
                )
                .frame(width: contentWidth, height: proxy.size.height)
            }
            .scrollDisabled(isHandleDragging)
            .scrollPosition($scrollPosition)
            .onChange(of: selectedCueID) { _, newValue in
                centerOnSelectedCue(viewport: viewportWidth, content: contentWidth, animated: true, cueID: newValue)
            }
            .onChange(of: zoom) { _, _ in
                centerOnSelectedCue(viewport: viewportWidth, content: contentWidth, animated: true, cueID: selectedCueID)
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

    private func xPosition(_ seconds: Double, width: CGFloat) -> CGFloat {
        CGFloat(max(0, min(seconds / max(duration, 0.001), 1))) * width
    }
}

private struct WaveformTimelineEditor: View {
    @Binding var cues: [SubtitleCue]
    @Binding var selectedCueID: SubtitleCue.ID?
    @Binding var isHandleDragging: Bool

    let waveform: [CGFloat]
    let duration: Double
    let currentTime: Double
    let language: AppLanguage
    let onSeek: (Double) -> Void

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

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height

            ZStack(alignment: .topLeading) {
                background
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { location in
                        let seconds = clamp(Double(location.x / max(width, 1)) * duration, 0, duration)
                        onSeek(seconds)
                    }

                WaveformShape(samples: waveform)
                    .foregroundStyle(Color.accentColor.opacity(0.38))
                    .padding(.vertical, 14)
                    .allowsHitTesting(false)

                ForEach(cues) { cue in
                    cueBlock(cue: cue, width: width)
                }

                ForEach($cues) { $cue in
                    handles(cue: $cue, width: width)
                }

                if duration > 0 {
                    playbackCursor(width: width, height: height)
                }
            }
            .overlay(alignment: .bottomLeading) {
                Text(Copy.text("editor.timelineHelp", language: language))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 5)
                    .allowsHitTesting(false)
            }
        }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color(nsColor: .textBackgroundColor))
    }

    private func cueBlock(cue: SubtitleCue, width: CGFloat) -> some View {
        let startX = xPosition(cue.start, width: width)
        let endX = xPosition(cue.end, width: width)
        let cueWidth = max(2, endX - startX)
        let selected = cue.id == selectedCueID

        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(selected ? Color.accentColor.opacity(0.28) : Color.teal.opacity(0.22))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(
                            selected ? Color.accentColor : Color.teal.opacity(0.55),
                            lineWidth: selected ? 1.6 : 0.8
                        )
                )
            Text("\(cue.index)")
                .font(.caption2.monospacedDigit().bold())
                .foregroundStyle(selected ? .primary : .secondary)
                .padding(.leading, 5)
                .lineLimit(1)
        }
        .frame(width: cueWidth, height: cueHeight)
        .offset(x: startX, y: cueTopOffset)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedCueID = cue.id
        }
        .help(cueTooltip(cue))
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
                    let target = session.initialStart + delta
                    cue.wrappedValue.start = max(0, min(target, cue.wrappedValue.end - 0.05))
                case .end:
                    let target = session.initialEnd + delta
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

    private func playbackCursor(width: CGFloat, height: CGFloat) -> some View {
        let cursorX = xPosition(currentTime, width: width)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.red.opacity(0.9))
                .frame(width: 1.5, height: height - 6)
                .offset(x: cursorX - 0.75, y: 3)
            PlaybackCursorHead()
                .fill(Color.red)
                .frame(width: 9, height: 7)
                .offset(x: cursorX - 4.5, y: 0)
        }
        .allowsHitTesting(false)
    }

    private func cueTooltip(_ cue: SubtitleCue) -> String {
        let times = "\(SubtitleDocument.displayTime(cue.start)) → \(SubtitleDocument.displayTime(cue.end))"
        let preview = cue.text.replacingOccurrences(of: "\n", with: " ")
        return "#\(cue.index)  \(times)\n\(preview)"
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

private struct SubtitleCueBlockRow: View {
    @Binding var cue: SubtitleCue
    let isSelected: Bool
    let select: () -> Void

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

            SelectableTextEditor(text: $cue.text, onActivate: select)
                .frame(minHeight: 48, maxHeight: 84)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
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
    let onActivate: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onActivate: onActivate)
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
        context.coordinator.onActivate = onActivate
        if textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
        }
        if let activatingTextView = textView as? ActivatingTextView {
            activatingTextView.onActivate = onActivate
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onActivate: () -> Void

        init(text: Binding<String>, onActivate: @escaping () -> Void) {
            self.text = text
            self.onActivate = onActivate
        }

        func textDidBeginEditing(_ notification: Notification) {
            onActivate()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
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

private enum WaveformLoader {
    static func samples(for url: URL, targetSamples: Int) async -> [CGFloat] {
        await Task.detached(priority: .utility) {
            await readSamples(for: url, targetSamples: targetSamples)
        }
        .value
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
                var offset = 0
                while offset < floats.count {
                    var sum: Float = 0
                    for channel in 0..<channelCount where offset + channel < floats.count {
                        sum += abs(floats[offset + channel])
                    }
                    let amplitude = sum / Float(channelCount)
                    let bin = min(bins.count - 1, frameIndex / binSize)
                    bins[bin] = max(bins[bin], amplitude)
                    frameIndex += 1
                    offset += channelCount
                }
            }
        }

        reader.cancelReading()
        let peak = max(bins.max() ?? 0, 0.0001)
        return bins.map { CGFloat(min(1, $0 / peak)) }
    }
}
