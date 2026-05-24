import AppKit
import AVFoundation
import AVKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var api: APIClient
    @EnvironmentObject private var backend: BackendService
    @EnvironmentObject private var settings: TranscriptionSettings
    @EnvironmentObject private var recentFiles: RecentFilesStore

    @AppStorage("huz.uiLanguage") private var languageRaw = AppLanguage.zh.rawValue

    @StateObject private var playback = PlaybackController()

    @State private var files: [FileSlot] = []
    @State private var activeIndex: Int = 0
    @State private var isProcessing = false
    @State private var isSaving = false
    @State private var isDropTargeted = false
    @State private var errorMessage: String?
    @State private var connectionState: ConnectionState = .unknown
    @State private var selectedPreset: RecognitionPreset = .balanced
    @State private var detailTab: DetailTab = .segments
    @State private var processingTask: Task<Void, Never>?
    @State private var selectedFrequentTerm: String?
    @State private var chipScrollEdges = ChipScrollEdges(leading: false, trailing: false)
    @State private var isCapturingFrame = false

    private var language: AppLanguage {
        AppLanguage(rawValue: languageRaw) ?? .zh
    }

    private var activeSlot: FileSlot? {
        guard files.indices.contains(activeIndex) else { return nil }
        return files[activeIndex]
    }

    private var hasFiles: Bool { !files.isEmpty }

    private var canRun: Bool {
        hasFiles && !isProcessing && !isSaving
    }

    private var statusLine: String {
        if let slot = activeSlot {
            return [t(slot.statusKey), slot.statusDetail].filter { !$0.isEmpty }.joined(separator: " · ")
        }
        return t("status.ready")
    }

    private var processingSummary: String? {
        guard files.count > 1 else { return nil }
        let done = files.filter { $0.processingState == .done }.count
        let failed = files.filter { $0.processingState == .failed }.count
        return String(format: t("file.summary"), done, files.count, failed)
    }

    private var canSaveAll: Bool {
        files.contains { $0.hasEditableSubtitle } && !isSaving
    }

    private var aggregateProgress: Double {
        guard isProcessing, !files.isEmpty else {
            return activeSlot?.progress ?? 0
        }
        let total = files.reduce(0.0) { partial, slot in
            switch slot.processingState {
            case .done: partial + 1
            case .previewing, .transcribing: partial + slot.progress
            default: partial
            }
        }
        return total / Double(files.count)
    }

    private var stats: SegmentStats {
        SegmentStats(segments: activeSlot?.segments ?? [], duration: activeSlot?.duration ?? 0)
    }

    private static let subtitleExtensions = ["srt", "vtt", "json", "txt"]

    var body: some View {
        NavigationSplitView {
            settingsPanel
                .navigationSplitViewColumnWidth(min: 260, ideal: 285, max: 320)
        } detail: {
            detailColumn
        }
        .navigationTitle(t("app.title"))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                connectionBadge
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await loadConfig() }
                } label: {
                    Label(t("backend.check"), systemImage: "dot.radiowaves.left.and.right")
                }
                .help(t("backend.check"))

                Button {
                    Task { await toggleBackend() }
                } label: {
                    Label(t(backend.isRunning ? "backend.stop" : "backend.start"),
                          systemImage: backend.isRunning ? "stop.circle" : "play.circle")
                }
                .help(t(backend.isRunning ? "backend.stop" : "backend.start"))

                Button {
                    Task { await previewAll() }
                } label: {
                    Label(t("action.preview"), systemImage: "waveform.path.ecg")
                }
                .disabled(!canRun)
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .confirmationAction) {
                transcribeButton
            }
        }
        .task {
            await loadConfig()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            backend.stop()
        }
        .alert(t("error.title"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(t("button.ok"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: .msubOpenFilesRequested)) { _ in
            chooseFiles()
        }
        .onReceive(NotificationCenter.default.publisher(for: .msubOpenRecentFileRequested)) { notification in
            guard let url = notification.object as? URL else { return }
            addFiles([url])
        }
        .onReceive(NotificationCenter.default.publisher(for: .msubImportSubtitleRequested)) { _ in
            importSubtitleForActiveFile()
        }
        .onReceive(NotificationCenter.default.publisher(for: .msubTranscribeRequested)) { _ in
            guard canRun else { return }
            Task { await transcribeAll() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .msubPreviewRequested)) { _ in
            guard canRun else { return }
            Task { await previewAll() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .msubStopRequested)) { _ in
            if isProcessing { cancelProcessing() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .msubSaveAllRequested)) { _ in
            Task { await saveAllOutputs() }
        }
        .onChange(of: activeIndex) { _, _ in
            selectedFrequentTerm = nil
        }
    }

    // MARK: - Detail column

    private var detailColumn: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 12) {
                    if hasFiles {
                        fileHeaderBar
                    }
                    compactWorkArea
                    detailTabContent
                }
                .padding(14)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(minWidth: 440)
        .background(.background)
    }

    @ViewBuilder
    private var compactWorkArea: some View {
        if hasFiles {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 10) {
                        if let slot = activeSlot {
                            previewView(for: slot)
                        }
                    }
                    .frame(width: 350, alignment: .topLeading)
                    .layoutPriority(1)

                    VStack(spacing: 10) {
                        if let slot = activeSlot {
                            mediaInfoCard(slot, fixedHeight: PreviewCardMetrics.height)
                        }
                    }
                    .frame(minWidth: 135, maxWidth: .infinity, alignment: .top)
                    .layoutPriority(0)
                }

                VStack(spacing: 12) {
                    if let slot = activeSlot {
                        previewView(for: slot)
                    }
                    if let slot = activeSlot {
                        mediaInfoCard(slot)
                    }
                }
            }
        } else {
            fileDropBox
        }
    }

    private func mediaInfoCard(_ slot: FileSlot, fixedHeight: CGFloat? = nil) -> some View {
        let terms = slot.frequentTerms

        return VStack(alignment: .leading, spacing: 8) {
            Label(t("media.info"), systemImage: "info.circle")
                .font(.subheadline.weight(.semibold))

            Divider()

            compactInfoRow(t("media.name"), value: slot.url.lastPathComponent)
            compactInfoRow(t("media.duration"), value: mediaDurationText(slot))
            compactInfoRow(t("media.size"), value: fileSizeText(slot.url))
            compactInfoRow(t("media.resolution"), value: resolutionText(slot.mediaInfo))
            compactInfoRow(t("media.frameRate"), value: frameRateText(slot.mediaInfo?.frameRate))
            compactInfoRow(t("media.videoCodec"), value: slot.mediaInfo?.videoCodec ?? t("media.noVideo"))
            compactInfoRow(t("media.audio"), value: audioText(slot.mediaInfo))
            compactInfoRow(t("media.bitRate"), value: bitRateText(slot.mediaInfo?.bitRate))

            if !terms.isEmpty {
                Divider()
                    .padding(.vertical, 2)
                Text(t("media.frequentTerms"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                GeometryReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(terms) { term in
                                frequentTermPill(term)
                            }
                        }
                        .padding(.vertical, 1)
                        .frame(minWidth: proxy.size.width, alignment: .leading)
                    }
                }
                .frame(height: 24)
                .clipped()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: fixedHeight, alignment: .topLeading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
    }

    private func frequentTermPill(_ term: SubtitleTermFrequency) -> some View {
        let isSelected = selectedFrequentTerm == term.term
        let tint: Color = isSelected ? .yellow : .secondary
        return Button {
            if isSelected {
                selectedFrequentTerm = nil
            } else {
                selectedFrequentTerm = term.term
            }
        } label: {
            Text("\(term.term) \(term.count)")
                .font(.caption2.monospacedDigit())
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    isSelected ? AnyShapeStyle(Color.yellow.opacity(0.32)) : AnyShapeStyle(.quinary),
                    in: Capsule()
                )
                .overlay(
                    Capsule().stroke(tint.opacity(isSelected ? 0.55 : 0), lineWidth: 1)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(term.term)
        .contextMenu {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(term.term, forType: .string)
            } label: {
                Label(t("action.copy"), systemImage: "doc.on.doc")
            }
        }
    }

    private func compactInfoRow(_ title: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func fileSizeText(_ url: URL) -> String {
        guard let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber else {
            return "-"
        }
        return ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file)
    }

    private func mediaDurationText(_ slot: FileSlot) -> String {
        let duration = slot.mediaInfo?.duration ?? slot.duration
        guard duration.isFinite, duration > 0 else { return "-" }
        return SubtitleDocument.displayTime(duration)
    }

    private func resolutionText(_ info: MediaInfo?) -> String {
        guard let width = info?.width, let height = info?.height, width > 0, height > 0 else {
            return "-"
        }
        return "\(width) x \(height)"
    }

    private func frameRateText(_ value: Double?) -> String {
        guard let value, value.isFinite, value > 0 else { return "-" }
        return String(format: "%.2f fps", value)
    }

    private func audioText(_ info: MediaInfo?) -> String {
        guard let info else { return "-" }
        var parts: [String] = []
        if let audioCodec = info.audioCodec, !audioCodec.isEmpty {
            parts.append(audioCodec)
        }
        if let sampleRate = info.sampleRate, sampleRate > 0 {
            parts.append(String(format: "%.1f kHz", Double(sampleRate) / 1000.0))
        }
        if let channels = info.channels, channels > 0 {
            parts.append(String(format: t("media.channels"), channels))
        }
        return parts.isEmpty ? "-" : parts.joined(separator: " · ")
    }

    private func bitRateText(_ value: Int64?) -> String {
        guard let value, value > 0 else { return "-" }
        if value >= 1_000_000 {
            return String(format: "%.1f Mbps", Double(value) / 1_000_000.0)
        }
        return String(format: "%.0f kbps", Double(value) / 1000.0)
    }

    @ViewBuilder
    private var detailTabContent: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                Picker("", selection: $detailTab) {
                    ForEach(DetailTab.allCases) { tab in
                        Text(tabTitle(tab)).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch detailTab {
                case .segments:
                    segmentsPanel
                case .output:
                    outputPanel
                }
            }
        }
    }

    private func previewKind(_ url: URL) -> MediaPreviewKind {
        MediaPreviewKind(url: url)
    }

    @ViewBuilder
    private func previewView(for slot: FileSlot) -> some View {
        let subtitleText = subtitleOverlayText(for: slot, at: playback.currentTime)
        let canCaptureFrame = isVideoSlot(slot)
        switch previewKind(slot.url) {
        case .player:
            MediaPreviewCard(
                url: slot.url,
                title: t("preview.title"),
                subtitleText: subtitleText,
                canCaptureFrame: canCaptureFrame,
                isCapturingFrame: isCapturingFrame,
                captureHelp: t("action.captureFrame.help"),
                playback: playback
            ) {
                Task { await captureFrameForActiveSlot() }
            }
        case .thumbnail:
            // Containers without a native video preview still need their audio
            // wired into the timeline playback controller (which routes through
            // AudioSource / ffmpeg so the audio is always playable).
            UnsupportedMediaPreview(
                url: slot.url,
                title: t("preview.title"),
                language: language,
                subtitleText: subtitleText,
                canCaptureFrame: canCaptureFrame,
                isCapturingFrame: isCapturingFrame,
                captureHelp: t("action.captureFrame.help")
            ) {
                Task { await captureFrameForActiveSlot() }
            }
                .task(id: slot.url) {
                    await playback.load(slot.url)
                }
        case .none:
            EmptyView()
        }
    }

    private func isVideoSlot(_ slot: FileSlot) -> Bool {
        if MediaPreviewKind.isVideoURL(slot.url) {
            return true
        }
        guard let info = slot.mediaInfo else { return false }
        if let codec = info.videoCodec, !codec.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return (info.width ?? 0) > 0 && (info.height ?? 0) > 0
    }

    private func subtitleOverlayText(for slot: FileSlot, at seconds: Double) -> String? {
        guard seconds.isFinite else { return nil }
        guard let cue = slot.cues.first(where: { seconds >= $0.start && seconds <= $0.end }) else {
            return nil
        }
        let text = VideoFrameCapture.cleanSubtitleText(cue.text)
        return text.isEmpty ? nil : text
    }

    private func captureFrameForActiveSlot() async {
        guard !isCapturingFrame, files.indices.contains(activeIndex) else { return }
        let index = activeIndex
        let slot = files[index]
        guard isVideoSlot(slot) else { return }

        let seconds = playback.currentTime
        let subtitleText = subtitleOverlayText(for: slot, at: seconds)
        isCapturingFrame = true
        update(at: index) {
            $0.statusKey = "status.capturingFrame"
            $0.statusDetail = SubtitleDocument.displayTime(seconds)
        }
        defer { isCapturingFrame = false }

        do {
            let destination = try await VideoFrameCapture.capture(
                source: slot.url,
                at: seconds,
                subtitleText: subtitleText
            )
            if let refreshedIndex = files.firstIndex(where: { $0.id == slot.id }) {
                update(at: refreshedIndex) {
                    $0.statusKey = "status.screenshotSaved"
                    $0.statusDetail = destination.lastPathComponent
                }
            }
        } catch {
            if let refreshedIndex = files.firstIndex(where: { $0.id == slot.id }) {
                update(at: refreshedIndex) {
                    $0.statusKey = "status.failed"
                    $0.statusDetail = error.localizedDescription
                }
            }
            errorMessage = String(format: t("error.screenshotFailed"), error.localizedDescription)
        }
    }

    // MARK: - Toolbar / status

    private var connectionBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(connectionState.color)
                .frame(width: 8, height: 8)
            Text(connectionState.title(language: language))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: statusSystemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(statusTint)
                    .frame(width: 22, height: 22)
                    .background(statusTint.opacity(0.15), in: Circle())

                Text(statusLine)
                    .font(.callout)
                    .lineLimit(2)

                Spacer(minLength: 8)

                if isProcessing {
                    Button {
                        cancelProcessing()
                    } label: {
                        Label(t("action.stop"), systemImage: "stop.circle")
                    }
                    .buttonStyle(.borderless)
                    .tint(.red)
                }

                if isProcessing || isSaving {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            ProgressView(value: min(max(aggregateProgress, 0), 1))
                .progressViewStyle(.linear)
                .tint(statusTint)

            if let processingSummary {
                Text(processingSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let slot = activeSlot, let lastOutputPath = slot.lastOutputPath {
                Text(lastOutputPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            } else if !backend.lastLog.isEmpty {
                Text(backend.lastLog)
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
    }

    private var statusSystemImage: String {
        let key = activeSlot?.statusKey ?? "status.ready"
        switch key {
        case "status.done", "status.saved", "status.savedAll", "status.copied": return "checkmark.circle.fill"
        case "status.failed", "status.previewFailed": return "exclamationmark.triangle.fill"
        case "status.cancelled": return "minus.circle.fill"
        case "status.transcribing", "status.detecting", "status.loading", "status.starting", "status.saving":
            return "waveform"
        default: return "circle.dotted"
        }
    }

    private var statusTint: Color {
        let key = activeSlot?.statusKey ?? "status.ready"
        switch key {
        case "status.done", "status.saved", "status.savedAll", "status.copied": return .green
        case "status.failed", "status.previewFailed": return .red
        case "status.cancelled": return .orange
        case "status.transcribing", "status.detecting", "status.loading", "status.starting", "status.saving":
            return .teal
        default: return .secondary
        }
    }

    // MARK: - Settings sidebar

    private var settingsPanel: some View {
        Form {
            Section(t("input.section")) {
                stackedField(t("settings.model"), help: t("help.model")) {
                    TextField("", text: $settings.model)
                        .textFieldStyle(.roundedBorder)
                }

                stackedField(t("settings.format"), help: t("help.format")) {
                    Picker("", selection: $settings.format) {
                        ForEach(OutputFormat.allCases) { format in
                            Text(format.title).tag(format)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                stackedField(t("settings.mode"), help: t("help.mode")) {
                    Picker("", selection: $settings.segmentMode) {
                        ForEach(SegmentMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }

            Section(t("settings.segmentation")) {
                stackedField(t("settings.preset"), help: t("help.preset")) {
                    Picker("", selection: $selectedPreset) {
                        ForEach(RecognitionPreset.allCases) { preset in
                            Text(presetTitle(preset)).tag(preset)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }

                Text(presetHelp(selectedPreset))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    selectedPreset = .balanced
                    settings.resetRecognitionDefaults()
                } label: {
                    Label(t("preset.reset"), systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)

                numericField(t("settings.threshold"), value: $settings.vadThreshold, suffix: "dB", help: t("help.threshold"))
                numericField(t("settings.maxSegment"), value: $settings.vadMaxSegment, suffix: "s", help: t("help.maxSegment"))
                numericField(t("settings.silence"), value: $settings.vadSilence, suffix: "s", help: t("help.silence"))

                DisclosureGroup(t("settings.advanced")) {
                    numericField(t("settings.search"), value: $settings.vadSearch, suffix: "s", help: t("help.search"))
                    numericField(t("settings.minSpeech"), value: $settings.vadMinSpeech, suffix: "s", help: t("help.minSpeech"))
                    numericField(t("settings.padding"), value: $settings.vadPadding, suffix: "s", help: t("help.padding"))
                    numericField(t("settings.minSegment"), value: $settings.vadMinSegment, suffix: "s", help: t("help.minSegment"))
                    numericField(t("settings.fixedChunk"), value: $settings.chunkSeconds, suffix: "s", help: t("help.fixedChunk"))
                }
            }

            Section(t("settings.recognition")) {
                stepperField(t("settings.beam"), value: $settings.beamSize, in: 1...8, help: t("help.beam"))
                numericField(t("settings.confidence"), value: $settings.minConfidence, suffix: "", help: t("help.confidence"))
                stepperField(t("settings.lineChars"), value: $settings.lineChars, in: 0...80, help: t("help.lineChars"))

                DisclosureGroup(t("settings.decoding")) {
                    numericField(t("settings.softmaxSmoothing"), value: $settings.softmaxSmoothing, suffix: "", help: t("help.softmaxSmoothing"))
                    numericField(t("settings.lengthPenalty"), value: $settings.lengthPenalty, suffix: "", help: t("help.lengthPenalty"))
                    numericField(t("settings.eosPenalty"), value: $settings.eosPenalty, suffix: "", help: t("help.eosPenalty"))
                    stepperField(t("settings.decodeMaxLen"), value: $settings.decodeMaxLen, in: 0...512, help: t("help.decodeMaxLen"))

                    Text(t("help.unsupportedDecoding"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: selectedPreset) { _, newValue in
            settings.applyPreset(newValue)
        }
    }

    // MARK: - File drop hero

    private var fileHeaderBar: some View {
        HStack(spacing: 8) {
            fileChipsRow
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                chooseFiles()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.borderless)
            .help(t("file.add"))

            Button {
                clearFiles()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .disabled(files.isEmpty || isProcessing || isSaving)
            .help(t("file.clearAll"))

            statusCapsule
                .layoutPriority(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: Capsule())
        .animation(.spring(response: 0.55, dampingFraction: 0.82), value: compactStatusText)
        .animation(.spring(response: 0.55, dampingFraction: 0.82), value: isProcessing)
    }

    private var statusCapsule: some View {
        HStack(spacing: 6) {
            Image(systemName: statusSystemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusTint)
                .contentTransition(.symbolEffect(.replace))

            Text(compactStatusText)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.opacity)

            if isProcessing {
                Button {
                    cancelProcessing()
                } label: {
                    Image(systemName: "stop.circle")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
                .help(t("action.stop"))
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(statusTint.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(statusTint.opacity(0.22), lineWidth: 0.8))
        .clipShape(Capsule())
        .geometryGroup()
        .fixedSize(horizontal: true, vertical: true)
        .animation(.spring(response: 0.55, dampingFraction: 0.82), value: compactStatusText)
        .animation(.spring(response: 0.55, dampingFraction: 0.82), value: isProcessing)
        .animation(.spring(response: 0.55, dampingFraction: 0.82), value: statusSystemImage)
        .animation(.spring(response: 0.55, dampingFraction: 0.82), value: statusTint)
        .help(statusHelpText)
    }

    private var compactStatusText: String {
        guard let slot = activeSlot else { return t("status.ready") }
        let base = t(slot.statusKey)
        let detail = slot.statusDetail
        if detail.isEmpty { return base }
        if isShortDetail(detail) {
            return "\(base) · \(detail)"
        }
        return base
    }

    private func isShortDetail(_ detail: String) -> Bool {
        guard detail.count <= 16 else { return false }
        if detail.contains("/") && (detail.contains(".") || detail.contains(" ")) {
            return false
        }
        return true
    }

    private var statusHelpText: String {
        var lines = [statusLine]
        if let processingSummary {
            lines.append(processingSummary)
        }
        if let slot = activeSlot, let lastOutputPath = slot.lastOutputPath {
            lines.append(lastOutputPath)
        } else if !backend.lastLog.isEmpty {
            lines.append(backend.lastLog)
        }
        return lines.joined(separator: "\n")
    }

    private var fileDropBox: some View {
        let hasFile = hasFiles
        let iconName = hasFile ? "checkmark.seal.fill" : "tray.and.arrow.down"
        let iconColor: Color = hasFile ? .teal : .secondary
        let title: String = {
            if files.count == 0 { return t("input.drop") }
            if files.count == 1 { return files[0].url.lastPathComponent }
            return "\(files.count) \(filesCountLabel(files.count))"
        }()
        let subtitle: String = {
            if files.count == 0 { return t("input.none") }
            if files.count == 1 { return files[0].url.deletingLastPathComponent().path }
            return files.map(\.url.lastPathComponent).prefix(3).joined(separator: " · ")
        }()

        return HStack(spacing: 14) {
            Image(systemName: iconName)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 52, height: 52)
                .background(iconColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                chooseFiles()
            } label: {
                Label(t("input.choose"), systemImage: "folder")
            }
            .controlSize(.regular)
            .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    isDropTargeted ? Color.teal : Color.clear,
                    style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture {
            if !hasFile { chooseFiles() }
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)
        .animation(.easeInOut(duration: 0.15), value: isDropTargeted)
    }

    private func filesCountLabel(_ count: Int) -> String {
        language == .zh ? "个文件" : (count == 1 ? "file" : "files")
    }

    // MARK: - File chips strip

    private var fileChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(files.enumerated()), id: \.element.id) { index, _ in
                    fileChip(index: index)
                        .transition(
                            .asymmetric(
                                insertion: .scale(scale: 0.7).combined(with: .opacity),
                                removal: .scale(scale: 0.6).combined(with: .opacity)
                            )
                        )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .animation(.spring(response: 0.45, dampingFraction: 0.82), value: files.map(\.id))
        }
        .onScrollGeometryChange(for: ChipScrollEdges.self) { geometry in
            let visible = geometry.visibleRect
            let contentWidth = geometry.contentSize.width
            return ChipScrollEdges(
                leading: visible.minX > 0.5,
                trailing: visible.maxX < contentWidth - 0.5
            )
        } action: { _, newValue in
            chipScrollEdges = newValue
        }
        .mask(chipFadeMask)
        .animation(.easeInOut(duration: 0.2), value: chipScrollEdges)
    }

    private var chipFadeMask: some View {
        let leading = chipScrollEdges.leading
        let trailing = chipScrollEdges.trailing
        return LinearGradient(
            stops: [
                .init(color: .clear, location: leading ? 0 : -0.001),
                .init(color: .black, location: leading ? 0.06 : 0),
                .init(color: .black, location: trailing ? 0.94 : 1),
                .init(color: .clear, location: trailing ? 1 : 1.001)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func fileChip(index: Int) -> some View {
        let slot = files[index]
        let isActive = index == activeIndex
        return FileChipView(
            slot: slot,
            isActive: isActive,
            iconName: chipIcon(slot.processingState),
            iconColor: chipColor(slot.processingState),
            removeHelp: t("file.remove"),
            statusHelp: [t(slot.statusKey), slot.statusDetail].filter { !$0.isEmpty }.joined(separator: " · "),
            onSelect: { activeIndex = index },
            onRemove: { remove(at: index) }
        )
    }

    private func chipIcon(_ state: FileSlot.ProcessingState) -> String {
        switch state {
        case .idle: return "circle"
        case .previewing, .transcribing: return "waveform"
        case .done: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        case .cancelled: return "minus.circle"
        }
    }

    private func chipColor(_ state: FileSlot.ProcessingState) -> Color {
        switch state {
        case .idle: return .secondary
        case .previewing, .transcribing: return .teal
        case .done: return .green
        case .failed: return .red
        case .cancelled: return .orange
        }
    }

    // MARK: - Segments panel

    private var segmentsPanel: some View {
        let segments = activeSlot?.segments ?? []
        let duration = activeSlot?.duration ?? 0
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(t("segments.title"))
                    .font(.headline)
                Spacer()
                Text(segments.isEmpty ? t("segments.noPreview") : "\(segments.count) \(t("segments.count"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TimelineView(segments: segments, duration: duration)
                .frame(height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            SegmentStatsView(stats: stats, language: language)

            if segments.isEmpty {
                ContentUnavailableView(
                    t("segments.empty"),
                    systemImage: "waveform",
                    description: Text(t("action.preview"))
                )
                .frame(maxWidth: .infinity, minHeight: 260)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(segments) { segment in
                            HStack {
                                Text("#\(segment.index)")
                                    .font(.caption.monospacedDigit().bold())
                                    .frame(width: 44, alignment: .leading)
                                    .foregroundStyle(.secondary)
                                Text(timeRange(segment))
                                    .font(.caption.monospacedDigit())
                                Spacer()
                                Text("\(segment.duration, specifier: "%.2f")s")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 220, maxHeight: 420)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Output panel

    private var outputPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(t("output.title"))
                    .font(.headline)
                Spacer()
                Button {
                    importSubtitleForActiveFile()
                } label: {
                    Label(t("action.importSubtitle"), systemImage: "text.badge.plus")
                }
                .labelStyle(.iconOnly)
                .disabled(activeSlot == nil || isSaving || isProcessing)
                .help(t("help.importSubtitle"))

                Button {
                    copyOutput()
                } label: {
                    Label(t("action.copy"), systemImage: "doc.on.doc")
                }
                .labelStyle(.iconOnly)
                .disabled(activeSlot?.hasEditableSubtitle != true)
                .help(t("action.copy"))

                Button {
                    Task { await saveOutput() }
                } label: {
                    Label(t("action.save"), systemImage: "square.and.arrow.down")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderedProminent)
                .disabled(activeSlot?.hasEditableSubtitle != true || isSaving)
                .help(t("action.save"))

                Button {
                    Task { await saveAllOutputs() }
                } label: {
                    Label(t("action.saveAll"), systemImage: "square.and.arrow.down.on.square")
                }
                .labelStyle(.iconOnly)
                .disabled(!canSaveAll)
                .help(t("help.saveAll"))
            }

            if files.indices.contains(activeIndex), !files[activeIndex].cues.isEmpty {
                let slotID = files[activeIndex].id
                SubtitleEditorPanel(
                    slot: fileSlotBinding(for: slotID),
                    selectedFrequentTerm: $selectedFrequentTerm,
                    language: language,
                    playback: playback
                )
                .id(slotID)
            } else {
                ContentUnavailableView(
                    t("output.placeholder"),
                    systemImage: "captions.bubble",
                    description: Text(t("input.choose"))
                )
                .frame(maxWidth: .infinity, minHeight: 300)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
    }

    private func fileSlotBinding(for id: FileSlot.ID) -> Binding<FileSlot> {
        Binding(
            get: {
                files.first { $0.id == id } ?? FileSlot(url: URL(fileURLWithPath: "/dev/null"))
            },
            set: { newValue in
                guard let index = files.firstIndex(where: { $0.id == id }) else { return }
                files[index] = newValue
            }
        )
    }

    // MARK: - Helpers

    private func presetTitle(_ preset: RecognitionPreset) -> String {
        t("preset.\(preset.rawValue)")
    }

    private func presetHelp(_ preset: RecognitionPreset) -> String {
        t("preset.\(preset.rawValue).help")
    }

    private func tabTitle(_ tab: DetailTab) -> String {
        switch tab {
        case .segments: t("tab.segments")
        case .output: t("tab.output")
        }
    }

    private func numericField(_ title: String, value: Binding<Double>, suffix: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            parameterLabel(title, help: help)
            HStack(spacing: 6) {
                TextField(title, value: value, format: .number.precision(.fractionLength(2)))
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .labelsHidden()
                if !suffix.isEmpty {
                    Text(suffix)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 22, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stepperField(_ title: String, value: Binding<Int>, in range: ClosedRange<Int>, help: String) -> some View {
        HStack(spacing: 6) {
            parameterLabel(title, help: help)
            Spacer(minLength: 4)
            Text("\(value.wrappedValue)")
                .font(.caption.monospacedDigit().bold())
                .frame(minWidth: 26, alignment: .trailing)
                .contentTransition(.numericText())
                .animation(.smooth(duration: 0.18), value: value.wrappedValue)
            Stepper("", value: value, in: range)
                .labelsHidden()
                .controlSize(.mini)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stackedField<Content: View>(_ title: String, help: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            parameterLabel(title, help: help)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func parameterLabel(_ title: String, help: String?) -> some View {
        HStack(spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
            if let help, !help.isEmpty {
                ParameterHelpIcon(help: help)
            }
        }
        .frame(height: 16)
    }

    private var transcribeButton: some View {
        Button {
            Task { await transcribeAll() }
        } label: {
            Label(t("action.transcribe"), systemImage: "captions.bubble")
                .labelStyle(.titleAndIcon)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
        }
        .glassEffect(.regular.tint(.accentColor).interactive())
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .keyboardShortcut(.return, modifiers: [.command])
        .disabled(!canRun)
        .help(t("action.transcribe"))
    }

    // MARK: - File handling

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.movie, .audio, .mpeg4Movie, .quickTimeMovie]
        if panel.runModal() == .OK {
            addFiles(panel.urls)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await loadURL(from: provider) {
                    urls.append(url)
                }
            }
            if !urls.isEmpty {
                addFiles(urls)
            }
        }
        return true
    }

    private func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: UTType.fileURL.identifier) { data, _ in
                if let data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func addFiles(_ urls: [URL]) {
        var selectedIndex: Int?
        for url in urls {
            let normalized = url.standardizedFileURL
            recentFiles.add(normalized)
            if let existingIndex = files.firstIndex(where: { $0.url.standardizedFileURL == normalized }) {
                selectedIndex = existingIndex
                if files[existingIndex].mediaInfo == nil {
                    loadMediaInfo(for: normalized, slotID: files[existingIndex].id)
                }
                if files[existingIndex].hasEditableSubtitle == false {
                    importSidecarSubtitle(for: normalized, slotID: files[existingIndex].id)
                }
                continue
            }
            let slot = FileSlot(url: normalized)
            files.append(slot)
            selectedIndex = files.count - 1
            loadMediaInfo(for: normalized, slotID: slot.id)
            importSidecarSubtitle(for: normalized, slotID: slot.id)
        }
        if let selectedIndex {
            activeIndex = selectedIndex
            if files.indices.contains(selectedIndex), files[selectedIndex].hasEditableSubtitle {
                detailTab = .output
            }
        } else if files.indices.contains(activeIndex) == false {
            activeIndex = files.isEmpty ? 0 : files.count - 1
        }
    }

    private func importSubtitleForActiveFile() {
        guard !isProcessing else {
            errorMessage = t("error.importWhileProcessing")
            return
        }
        guard files.indices.contains(activeIndex) else {
            errorMessage = t("error.noActiveFile")
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = subtitleContentTypes()
        panel.title = t("action.importSubtitle")
        panel.prompt = t("action.importSubtitle")
        if panel.runModal() == .OK, let url = panel.url {
            let slotID = files[activeIndex].id
            Task {
                await importSubtitle(from: url, slotID: slotID, automatic: false)
            }
        }
    }

    private func importSidecarSubtitle(for mediaURL: URL, slotID: UUID) {
        guard let subtitleURL = sidecarSubtitleURL(for: mediaURL) else { return }
        Task {
            await importSubtitle(from: subtitleURL, slotID: slotID, automatic: true)
        }
    }

    private func sidecarSubtitleURL(for mediaURL: URL) -> URL? {
        let base = mediaURL.deletingPathExtension()
        for ext in Self.subtitleExtensions {
            let candidate = base.appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: mediaURL.deletingLastPathComponent().path) else {
            return nil
        }
        let wantedBase = mediaURL.deletingPathExtension().lastPathComponent.lowercased()
        for name in names {
            let url = mediaURL.deletingLastPathComponent().appendingPathComponent(name)
            let matchesBase = url.deletingPathExtension().lastPathComponent.lowercased() == wantedBase
            let matchesExt = Self.subtitleExtensions.contains(url.pathExtension.lowercased())
            if matchesBase && matchesExt {
                return url
            }
        }
        return nil
    }

    private func importSubtitle(from subtitleURL: URL, slotID: UUID, automatic: Bool) async {
        guard files.contains(where: { $0.id == slotID }) else { return }
        guard let format = outputFormat(forSubtitleURL: subtitleURL) else {
            if !automatic {
                errorMessage = t("error.unsupportedSubtitle")
            }
            return
        }

        do {
            var encoding = String.Encoding.utf8
            let text = try String(contentsOf: subtitleURL, usedEncoding: &encoding)
            let cues = SubtitleDocument.parse(text, format: format)
            if format != .txt && cues.isEmpty {
                throw NSError(
                    domain: "MSub.SubtitleImport",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: t("error.subtitleNoTimedCues")]
                )
            }
            if !cues.isEmpty,
               let mediaDuration = await mediaDurationForSubtitleValidation(slotID: slotID) {
                let maxEnd = cues.map(\.end).max() ?? 0
                if maxEnd > mediaDuration + 0.05 {
                    throw NSError(
                        domain: "MSub.SubtitleImport",
                        code: 2,
                        userInfo: [
                            NSLocalizedDescriptionKey: String(
                                format: t("error.subtitleTimeExceedsDuration"),
                                SubtitleDocument.displayTime(maxEnd),
                                SubtitleDocument.displayTime(mediaDuration)
                            )
                        ]
                    )
                }
            }
            guard let refreshedIndex = files.firstIndex(where: { $0.id == slotID }) else { return }
            update(at: refreshedIndex) {
                $0.outputFormat = format
            }
            installSubtitleText(text, at: refreshedIndex, format: format, parsedCues: cues)
            update(at: refreshedIndex) {
                $0.outputFormat = format
                $0.statusKey = automatic ? "status.subtitleAutoImported" : "status.subtitleImported"
                $0.statusDetail = subtitleURL.lastPathComponent
                if $0.processingState == .idle || $0.processingState == .failed {
                    $0.processingState = .done
                }
                $0.progress = max($0.progress, 1)
            }
            if refreshedIndex == activeIndex {
                detailTab = .output
            }
        } catch {
            if automatic, let index = files.firstIndex(where: { $0.id == slotID }) {
                update(at: index) {
                    $0.statusKey = "status.subtitleImportSkipped"
                    $0.statusDetail = error.localizedDescription
                }
            } else {
                errorMessage = String(format: t("error.subtitleImportFailed"), error.localizedDescription)
            }
        }
    }

    /// Returns the media's duration for subtitle bounds validation, or `nil` when
    /// the container is too opaque for AVFoundation to surface a duration (e.g.,
    /// some MKVs). Callers should treat `nil` as "skip the bounds check" so the
    /// subtitle can still be imported.
    private func mediaDurationForSubtitleValidation(slotID: UUID) async -> Double? {
        guard let index = files.firstIndex(where: { $0.id == slotID }) else {
            return nil
        }
        let slot = files[index]
        if let duration = slot.mediaInfo?.duration, duration.isFinite, duration > 0 {
            return duration
        }
        if slot.duration.isFinite, slot.duration > 0 {
            return slot.duration
        }

        let asset = AVURLAsset(url: slot.url)
        let loadedDuration = try? await asset.load(.duration)
        let seconds = loadedDuration?.seconds ?? 0
        guard seconds.isFinite, seconds > 0 else {
            return nil
        }
        if let refreshedIndex = files.firstIndex(where: { $0.id == slotID }) {
            update(at: refreshedIndex) {
                $0.duration = max($0.duration, seconds)
            }
        }
        return seconds
    }

    private func outputFormat(forSubtitleURL url: URL) -> OutputFormat? {
        OutputFormat(rawValue: url.pathExtension.lowercased())
    }

    private func subtitleContentTypes() -> [UTType] {
        Self.subtitleExtensions.map { ext in
            UTType(filenameExtension: ext) ?? .plainText
        }
    }

    private func loadMediaInfo(for url: URL, slotID: UUID) {
        Task {
            let info = await LocalMediaInfoLoader.info(for: url)
            guard let info else { return }
            await MainActor.run {
                guard let index = files.firstIndex(where: { $0.id == slotID }) else { return }
                files[index].mediaInfo = info
                if files[index].duration <= 0, let duration = info.duration {
                    files[index].duration = duration
                }
            }
        }
    }

    private func remove(at index: Int) {
        guard files.indices.contains(index) else { return }
        files.remove(at: index)
        if activeIndex >= files.count {
            activeIndex = max(0, files.count - 1)
        }
        if files.isEmpty {
            detailTab = .segments
            playback.player.pause()
        }
    }

    private func clearFiles() {
        guard !isProcessing else { return }
        files.removeAll()
        activeIndex = 0
        detailTab = .segments
        playback.player.pause()
    }

    private func update(at index: Int, _ block: (inout FileSlot) -> Void) {
        guard files.indices.contains(index) else { return }
        block(&files[index])
    }

    // MARK: - Backend

    private func toggleBackend() async {
        if backend.isRunning {
            backend.stop()
            connectionState = .disconnected
            return
        }

        guard await ensureBackendReady(timeout: 25.0) else { return }
        await loadConfig()
    }

    private func loadConfig() async {
        do {
            let isReady = await backend.ensureRunning(timeout: 25.0)
            api.baseURL = backend.baseURL
            guard isReady else {
                connectionState = .disconnected
                return
            }
            let config = try await api.fetchConfig()
            settings.apply(config: config)
            connectionState = .connected
        } catch {
            connectionState = .disconnected
        }
    }

    private func ensureBackendReady(timeout: TimeInterval = 25.0) async -> Bool {
        let isReady = await backend.ensureRunning(timeout: timeout)
        api.baseURL = backend.baseURL
        connectionState = isReady ? .connected : .disconnected
        return isReady
    }

    // MARK: - Sequential processing

    private func previewAll() async {
        guard hasFiles else { return }
        guard await ensureBackendReady() else {
            errorMessage = backend.message
            return
        }
        isProcessing = true
        processingTask = Task { @MainActor in
            for index in files.indices {
                if Task.isCancelled { break }
                await preview(at: index)
            }
            isProcessing = false
        }
        await processingTask?.value
    }

    private func transcribeAll() async {
        guard hasFiles else { return }
        guard await ensureBackendReady() else {
            errorMessage = backend.message
            return
        }
        detailTab = .output
        isProcessing = true
        processingTask = Task { @MainActor in
            for index in files.indices {
                if Task.isCancelled { break }
                await transcribe(at: index)
            }
            isProcessing = false
        }
        await processingTask?.value
    }

    private func cancelProcessing() {
        for slot in files {
            if let jobID = slot.jobID {
                Task { try? await api.cancelJob(id: jobID) }
            }
        }
        processingTask?.cancel()
        processingTask = nil
        for index in files.indices {
            switch files[index].processingState {
            case .previewing, .transcribing:
                files[index].processingState = .cancelled
                files[index].statusKey = "status.cancelled"
                files[index].statusDetail = ""
            default:
                break
            }
        }
        isProcessing = false
    }

    private func preview(at index: Int) async {
        guard files.indices.contains(index) else { return }
        activeIndex = index
        let url = files[index].url
        update(at: index) {
            $0.processingState = .previewing
            $0.statusKey = "status.detecting"
            $0.statusDetail = url.lastPathComponent
            $0.progress = 0
        }
        do {
            let payload = try await api.preview(fileURL: url, settings: settings)
            update(at: index) {
                $0.duration = payload.duration
                $0.mediaInfo = payload.mediaInfo ?? $0.mediaInfo
                $0.segments = payload.segments
                $0.statusKey = "status.previewReady"
                $0.statusDetail = "\(payload.count) \(t("segments.count"))"
                $0.processingState = .done
                $0.progress = 1
            }
        } catch {
            update(at: index) {
                $0.statusKey = "status.previewFailed"
                $0.statusDetail = error.localizedDescription
                $0.processingState = .failed
                $0.progress = 0
            }
        }
    }

    private func transcribe(at index: Int) async {
        guard files.indices.contains(index) else { return }
        activeIndex = index
        let url = files[index].url
        update(at: index) {
            $0.processingState = .transcribing
            $0.previewText = ""
            $0.cues = []
            $0.originalCues = []
            $0.selectedCueID = nil
            $0.jobID = nil
            $0.lastOutputPath = nil
            $0.outputFormat = settings.format
            $0.progress = 0
            $0.statusKey = "status.starting"
            $0.statusDetail = url.lastPathComponent
        }
        do {
            let created = try await api.createJob(fileURL: url, settings: settings)
            update(at: index) { $0.jobID = created.id }
            try await poll(jobID: created.id, fileIndex: index)
        } catch {
            if Task.isCancelled {
                update(at: index) {
                    $0.processingState = .cancelled
                    $0.statusKey = "status.cancelled"
                    $0.statusDetail = ""
                }
            } else {
                update(at: index) {
                    $0.processingState = .failed
                    $0.statusKey = "status.failed"
                    $0.statusDetail = error.localizedDescription
                }
            }
        }
    }

    private func poll(jobID: String, fileIndex: Int) async throws {
        while !Task.isCancelled {
            let job = try await api.jobStatus(id: jobID)
            let total = max(job.total ?? 0, 0)
            let current = max(job.current ?? 0, 0)
            let progress = total > 0 ? Double(current) / Double(total) : 0

            update(at: fileIndex) {
                $0.progress = progress
                if job.status == "running", total > 0 {
                    $0.statusKey = "status.transcribing"
                    $0.statusDetail = "\(current) / \(total)"
                } else if job.status == "running" {
                    $0.statusKey = "status.loading"
                    $0.statusDetail = ""
                } else {
                    $0.statusKey = "status.starting"
                    $0.statusDetail = job.progressText ?? job.status
                }
                if let preview = job.preview, !preview.isEmpty {
                    $0.previewText = preview
                }
                if let output = job.output {
                    $0.lastOutputPath = output
                }
            }

            if job.status == "done" {
                if files.indices.contains(fileIndex) {
                    let format = files[fileIndex].outputFormat
                    if let output = try? await api.fetchOutput(jobID: jobID),
                       let text = String(data: output.data, encoding: .utf8) {
                        installSubtitleText(text, at: fileIndex, format: format)
                    }
                }
                update(at: fileIndex) {
                    $0.progress = 1
                    $0.statusKey = "status.done"
                    $0.statusDetail = "\(job.cueCount ?? 0) cues"
                    $0.processingState = .done
                }
                return
            }
            if job.status == "cancelled" {
                update(at: fileIndex) {
                    $0.processingState = .cancelled
                    $0.statusKey = "status.cancelled"
                    $0.statusDetail = ""
                    $0.progress = 0
                }
                return
            }
            if job.status == "error" {
                throw NSError(domain: "MSub.Job", code: 2, userInfo: [NSLocalizedDescriptionKey: job.error ?? "Job failed"])
            }
            try await Task.sleep(for: .seconds(1))
        }
    }

    // MARK: - Save / copy

    private func saveOutput() async {
        guard let slot = activeSlot, slot.hasEditableSubtitle else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            update(at: activeIndex) {
                $0.statusKey = "status.saving"
                $0.statusDetail = ""
            }
            let panel = NSSavePanel()
            panel.nameFieldStringValue = suggestedOutputFilename(for: slot, fallback: "subtitle.\(slot.outputFormat.rawValue)")
            panel.allowedContentTypes = [contentType(for: slot.outputFormat)]
            if panel.runModal() == .OK, let url = panel.url {
                try subtitleData(for: slot).write(to: url)
                update(at: activeIndex) {
                    $0.statusKey = "status.saved"
                    $0.statusDetail = url.lastPathComponent
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveAllOutputs() async {
        let targets = files.enumerated().filter { _, slot in
            slot.hasEditableSubtitle
        }
        guard !targets.isEmpty else { return }

        isSaving = true
        defer { isSaving = false }

        var failures: [String] = []
        for (index, slot) in targets {
            do {
                update(at: index) {
                    $0.statusKey = "status.saving"
                    $0.statusDetail = ""
                }
                let destination = slot.url
                    .deletingPathExtension()
                    .appendingPathExtension(slot.outputFormat.rawValue)
                try subtitleData(for: slot).write(to: destination)
                update(at: index) {
                    $0.statusKey = "status.saved"
                    $0.statusDetail = destination.lastPathComponent
                    $0.lastOutputPath = destination.path
                }
            } catch {
                failures.append(slot.url.lastPathComponent)
                update(at: index) {
                    $0.statusKey = "status.failed"
                    $0.statusDetail = error.localizedDescription
                    $0.processingState = .failed
                }
            }
        }

        if !failures.isEmpty {
            errorMessage = String(format: t("error.saveAllFailed"), failures.joined(separator: ", "))
        } else if files.indices.contains(activeIndex) {
            update(at: activeIndex) {
                $0.statusKey = "status.savedAll"
                $0.statusDetail = t("status.sameDirectory")
            }
        }
    }

    private func copyOutput() {
        guard let slot = activeSlot, slot.hasEditableSubtitle else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(slot.editableSubtitleText, forType: .string)
        update(at: activeIndex) {
            $0.statusKey = "status.copied"
            $0.statusDetail = ""
        }
    }

    private func contentType(for format: OutputFormat) -> UTType {
        switch format {
        case .srt:
            UTType(filenameExtension: "srt") ?? .plainText
        case .vtt:
            UTType(filenameExtension: "vtt") ?? .plainText
        case .txt:
            .plainText
        case .json:
            .json
        }
    }

    private func suggestedOutputFilename(for slot: FileSlot, fallback: String) -> String {
        let sourceBase = slot.url.deletingPathExtension().lastPathComponent
        let ext = slot.outputFormat.rawValue
        if sourceBase.isEmpty {
            return fallback.isEmpty ? "subtitle.\(ext)" : fallback
        }
        return "\(sourceBase).\(ext)"
    }

    private func subtitleData(for slot: FileSlot) -> Data {
        Data(slot.editableSubtitleText.utf8)
    }

    private func installSubtitleText(_ text: String, at index: Int, format: OutputFormat, parsedCues: [SubtitleCue]? = nil) {
        let cues = parsedCues ?? SubtitleDocument.parse(text, format: format)
        let termsSource = cues.isEmpty ? text : cues.map(\.text).joined(separator: " ")
        let frequentTerms = SubtitleTextStats.topTerms(in: termsSource, limit: 8)
        update(at: index) {
            $0.outputFormat = format
            $0.previewText = cues.isEmpty ? text : SubtitleDocument.serialize(cues, format: format)
            $0.cues = cues
            $0.originalCues = cues
            $0.frequentTerms = frequentTerms
            $0.selectedCueID = cues.first?.id
            if !$0.cues.isEmpty {
                $0.duration = max($0.duration, $0.cues.map(\.end).max() ?? 0)
            }
            if $0.segments.isEmpty {
                $0.segments = $0.cues.map {
                    SubtitleSegment(index: $0.index, start: $0.start, end: $0.end, duration: $0.duration)
                }
            }
        }
    }

    private func timeRange(_ segment: SubtitleSegment) -> String {
        "\(timeString(segment.start)) -> \(timeString(segment.end))"
    }

    private func timeString(_ seconds: Double) -> String {
        let minutes = Int(seconds) / 60
        let remainder = seconds - Double(minutes * 60)
        return String(format: "%02d:%05.2f", minutes, remainder)
    }

    private func t(_ key: String) -> String {
        Copy.text(key, language: language)
    }
}

private struct ChipScrollEdges: Equatable {
    var leading: Bool
    var trailing: Bool
}

private struct FileChipView: View {
    let slot: FileSlot
    let isActive: Bool
    let iconName: String
    let iconColor: Color
    let removeHelp: String
    let statusHelp: String
    let onSelect: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: iconName)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(iconColor)
            Text(slot.url.lastPathComponent)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180, alignment: .leading)
            if case .previewing = slot.processingState {
                ProgressView()
                    .controlSize(.mini)
            } else if case .transcribing = slot.processingState {
                ProgressView()
                    .controlSize(.mini)
            }
            if isHovering {
                Button {
                    onRemove()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                        .padding(2)
                }
                .buttonStyle(.plain)
                .help(removeHelp)
                .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            isActive ? AnyShapeStyle(Color.teal.opacity(0.16)) : AnyShapeStyle(.quinary),
            in: Capsule()
        )
        .overlay(
            Capsule().stroke(isActive ? Color.teal : Color.clear, lineWidth: 1.2)
        )
        .contentShape(Capsule())
        .onTapGesture {
            onSelect()
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.18)) {
                isHovering = hovering
            }
        }
        .help(statusHelp)
    }
}

private struct ParameterHelpIcon: View {
    let help: String
    @State private var isHovering = false
    @State private var isPresented = false
    @State private var dismissTask: Task<Void, Never>?

    var body: some View {
        Button {
            dismissTask?.cancel()
            isPresented.toggle()
        } label: {
            Image(systemName: "questionmark.circle")
                .font(.caption2)
                .foregroundStyle(isPresented || isHovering ? .primary : .tertiary)
                .frame(width: 16, height: 16)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering in
            isHovering = hovering
            dismissTask?.cancel()
            if hovering {
                isPresented = true
            } else {
                dismissTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(180))
                    if !isHovering {
                        isPresented = false
                    }
                }
            }
        }
        .popover(isPresented: $isPresented, arrowEdge: .top) {
            Text(help)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(width: 280, alignment: .leading)
        }
        .accessibilityLabel(Text(help))
    }
}

// MARK: - Supporting types

struct FileSlot: Identifiable {
    let id = UUID()
    var url: URL
    var segments: [SubtitleSegment] = []
    var cues: [SubtitleCue] = []
    var originalCues: [SubtitleCue] = []
    var frequentTerms: [SubtitleTermFrequency] = []
    var selectedCueID: SubtitleCue.ID?
    var mediaInfo: MediaInfo?
    var duration: Double = 0
    var previewText: String = ""
    var jobID: String?
    var lastOutputPath: String?
    var outputFormat: OutputFormat = .srt
    var progress: Double = 0
    var statusKey: String = "status.ready"
    var statusDetail: String = ""
    var processingState: ProcessingState = .idle

    enum ProcessingState: Equatable {
        case idle
        case previewing
        case transcribing
        case done
        case failed
        case cancelled
    }
}

private enum DetailTab: String, CaseIterable, Identifiable {
    case segments
    case output

    var id: String { rawValue }
}

private enum ConnectionState {
    case unknown
    case connected
    case disconnected

    var color: Color {
        switch self {
        case .unknown: .secondary
        case .connected: .green
        case .disconnected: .red
        }
    }

    func title(language: AppLanguage) -> String {
        switch self {
        case .unknown:
            Copy.text("backend.check", language: language)
        case .connected:
            Copy.text("backend.connected", language: language)
        case .disconnected:
            Copy.text("backend.disconnected", language: language)
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var rowSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var cursorX: CGFloat = 0
        var cursorY: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if cursorX > 0, cursorX + spacing + size.width > maxWidth {
                cursorY += rowHeight + rowSpacing
                cursorX = 0
                rowHeight = 0
            }
            if cursorX > 0 {
                cursorX += spacing
            }
            cursorX += size.width
            rowHeight = max(rowHeight, size.height)
            usedWidth = max(usedWidth, cursorX)
        }

        return CGSize(width: proposal.width ?? usedWidth, height: cursorY + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var cursorX: CGFloat = 0
        var cursorY: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if cursorX > 0, cursorX + spacing + size.width > maxWidth {
                cursorY += rowHeight + rowSpacing
                cursorX = 0
                rowHeight = 0
            }
            if cursorX > 0 {
                cursorX += spacing
            }
            subview.place(
                at: CGPoint(x: bounds.minX + cursorX, y: bounds.minY + cursorY),
                proposal: ProposedViewSize(size)
            )
            cursorX += size.width
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private enum LocalMediaInfoLoader {
    static func info(for url: URL) async -> MediaInfo? {
        await Task.detached(priority: .utility) {
            await loadInfo(for: url)
        }
        .value
    }

    private static func loadInfo(for url: URL) async -> MediaInfo? {
        let asset = AVURLAsset(url: url)
        let durationTime = (try? await asset.load(.duration)) ?? .zero
        let duration = durationTime.seconds.isFinite && durationTime.seconds > 0 ? durationTime.seconds : nil

        var info = MediaInfo(duration: duration)
        if let duration, let size = fileSize(url), duration > 0 {
            info.bitRate = Int64((Double(size) * 8.0 / duration).rounded())
        }

        if let videoTrack = (try? await asset.loadTracks(withMediaType: .video))?.first {
            let naturalSize = (try? await videoTrack.load(.naturalSize)) ?? .zero
            let transform = (try? await videoTrack.load(.preferredTransform)) ?? .identity
            let transformedSize = naturalSize.applying(transform)
            let width = Int(abs(transformedSize.width).rounded())
            let height = Int(abs(transformedSize.height).rounded())
            if width > 0, height > 0 {
                info.width = width
                info.height = height
            }
            let frameRate = (try? await videoTrack.load(.nominalFrameRate)) ?? 0
            if frameRate > 0 {
                info.frameRate = Double(frameRate)
            }
            if let description = ((try? await videoTrack.load(.formatDescriptions)) ?? []).first {
                info.videoCodec = codecName(description)
            }
        }

        if let audioTrack = (try? await asset.loadTracks(withMediaType: .audio))?.first,
           let description = ((try? await audioTrack.load(.formatDescriptions)) ?? []).first {
            info.audioCodec = codecName(description)
            if let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                if streamDescription.mSampleRate > 0 {
                    info.sampleRate = Int(streamDescription.mSampleRate.rounded())
                }
                if streamDescription.mChannelsPerFrame > 0 {
                    info.channels = Int(streamDescription.mChannelsPerFrame)
                }
            }
        }

        return info
    }

    private static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    private static func codecName(_ description: CMFormatDescription) -> String {
        let subtype = CMFormatDescriptionGetMediaSubType(description)
        let bytes = [
            UInt8((subtype >> 24) & 0xff),
            UInt8((subtype >> 16) & 0xff),
            UInt8((subtype >> 8) & 0xff),
            UInt8(subtype & 0xff)
        ]
        return String(bytes: bytes, encoding: .macOSRoman)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "\(subtype)"
    }
}

private struct SegmentStats {
    let count: Int
    let averageDuration: Double
    let maxDuration: Double
    let speechRatio: Double

    init(segments: [SubtitleSegment], duration: Double) {
        count = segments.count
        let durations = segments.map(\.duration)
        let speechSeconds = durations.reduce(0, +)
        averageDuration = count > 0 ? speechSeconds / Double(count) : 0
        maxDuration = durations.max() ?? 0
        speechRatio = duration > 0 ? speechSeconds / duration : 0
    }
}

private struct SegmentStatsView: View {
    let stats: SegmentStats
    let language: AppLanguage

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
            GridRow {
                stat(Copy.text("segments.avg", language: language), String(format: "%.2fs", stats.averageDuration))
                stat(Copy.text("segments.max", language: language), String(format: "%.2fs", stats.maxDuration))
                stat(Copy.text("segments.speech", language: language), String(format: "%.0f%%", stats.speechRatio * 100))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 10))
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().bold())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TimelineView: View {
    let segments: [SubtitleSegment]
    let duration: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quinary)
                ForEach(segments) { segment in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.teal)
                        .frame(
                            width: max(2, proxy.size.width * segment.duration / max(duration, 0.001)),
                            height: 28
                        )
                        .offset(x: proxy.size.width * segment.start / max(duration, 0.001))
                }
            }
        }
    }
}

extension Notification.Name {
    static let msubOpenFilesRequested = Notification.Name("MSubOpenFilesRequested")
    static let msubOpenRecentFileRequested = Notification.Name("MSubOpenRecentFileRequested")
    static let msubImportSubtitleRequested = Notification.Name("MSubImportSubtitleRequested")
    static let msubTranscribeRequested = Notification.Name("MSubTranscribeRequested")
    static let msubPreviewRequested = Notification.Name("MSubPreviewRequested")
    static let msubStopRequested = Notification.Name("MSubStopRequested")
    static let msubSaveAllRequested = Notification.Name("MSubSaveAllRequested")
    static let msubDeleteSelectedCueRequested = Notification.Name("MSubDeleteSelectedCueRequested")
    static let msubDuplicateSelectedCueRequested = Notification.Name("MSubDuplicateSelectedCueRequested")
    static let msubInsertCueBeforeRequested = Notification.Name("MSubInsertCueBeforeRequested")
    static let msubInsertCueAfterRequested = Notification.Name("MSubInsertCueAfterRequested")
    static let msubResetSelectedCueRequested = Notification.Name("MSubResetSelectedCueRequested")
    static let msubZoomTimelineInRequested = Notification.Name("MSubZoomTimelineInRequested")
    static let msubZoomTimelineOutRequested = Notification.Name("MSubZoomTimelineOutRequested")
    static let msubToggleTimelineRequested = Notification.Name("MSubToggleTimelineRequested")
}

@MainActor
final class RecentFilesStore: ObservableObject {
    @Published private(set) var urls: [URL] = []

    private let key = "msub.recentFiles"
    private let limit = 12

    init() {
        load()
    }

    func add(_ url: URL) {
        let normalized = url.standardizedFileURL
        urls.removeAll { $0.standardizedFileURL == normalized }
        urls.insert(normalized, at: 0)
        if urls.count > limit {
            urls = Array(urls.prefix(limit))
        }
        save()
    }

    func clear() {
        urls = []
        save()
    }

    private func load() {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        urls = paths.map { URL(fileURLWithPath: $0).standardizedFileURL }
    }

    private func save() {
        UserDefaults.standard.set(urls.map(\.path), forKey: key)
    }
}

// MARK: - Media preview

private enum MediaPreviewKind {
    case player
    case thumbnail
    case none

    init(url: URL) {
        let ext = url.pathExtension.lowercased()
        if MediaPreviewKind.playerExtensions.contains(ext) {
            self = .player
        } else if MediaPreviewKind.thumbnailExtensions.contains(ext) {
            self = .thumbnail
        } else {
            self = .none
        }
    }

    private static let playerExtensions: Set<String> = [
        "mp4", "mov", "m4v", "qt", "3gp", "3g2",
        "m4a", "mp3", "wav", "aac", "aiff", "flac", "caf"
    ]

    private static let thumbnailExtensions: Set<String> = [
        "mkv", "avi", "webm", "flv", "wmv",
        "mpg", "mpeg", "ts", "mts", "m2ts",
        "vob", "ogv", "ogg", "rm", "rmvb", "asf", "divx"
    ]

    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "qt", "3gp", "3g2",
        "mkv", "avi", "webm", "flv", "wmv",
        "mpg", "mpeg", "ts", "mts", "m2ts",
        "vob", "ogv", "rm", "rmvb", "asf", "divx"
    ]

    static func isVideoURL(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }
}

private enum PreviewCardMetrics {
    static let height: CGFloat = 296
    static let cornerRadius: CGFloat = 14
    static let shadowColor = Color.black.opacity(0.16)
}

private struct UnsupportedMediaPreview: View {
    let url: URL
    let title: String
    let language: AppLanguage
    let subtitleText: String?
    let canCaptureFrame: Bool
    let isCapturingFrame: Bool
    let captureHelp: String
    let onCaptureFrame: () -> Void

    @State private var cover: NSImage?
    @State private var filmstrip: [NSImage] = []
    @State private var selectedFrameIndex: Int?
    @State private var isLoadingCover = true

    private static let filmstripFractions: [Double] = [0.1, 0.3, 0.5, 0.7, 0.9]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "film")
                    .foregroundStyle(.teal)
                Text(title)
                    .font(.headline)
                Spacer()
                if canCaptureFrame {
                    CaptureFrameButton(
                        isCapturing: isCapturingFrame,
                        help: captureHelp,
                        action: onCaptureFrame
                    )
                }
                Text(url.pathExtension.uppercased())
                    .font(.caption2.monospaced().weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                    .help(Copy.text("preview.unsupported", language: language))
            }

            coverSurface
                .frame(maxWidth: .infinity)
                .frame(height: filmstrip.isEmpty ? 230 : 196)

            if !filmstrip.isEmpty {
                filmstripRow
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: PreviewCardMetrics.height, alignment: .topLeading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: PreviewCardMetrics.cornerRadius))
        .clipShape(RoundedRectangle(cornerRadius: PreviewCardMetrics.cornerRadius))
        .shadow(color: PreviewCardMetrics.shadowColor, radius: 9, x: 0, y: 4)
        .task(id: url) {
            await reloadPreview()
        }
    }

    private var coverSurface: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottom) {
                Color.clear
                if let cover {
                    Image(nsImage: cover)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .transition(.opacity)
                    PreviewSubtitleOverlay(text: subtitleText)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                        .allowsHitTesting(false)
                } else if isLoadingCover {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.title3)
                            .foregroundStyle(.yellow)
                        Text(Copy.text("preview.unsupported", language: language))
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.center)
                        Text(Copy.text("preview.transcribeStillSupported", language: language))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(10)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .animation(.easeInOut(duration: 0.25), value: cover)
    }

    private var filmstripRow: some View {
        HStack(spacing: 4) {
            ForEach(0..<filmstrip.count, id: \.self) { idx in
                let isSelected = idx == selectedFrameIndex
                // Use a clear sizing rectangle that owns the actual frame, and
                // overlay the image. `.aspectRatio(.fill)` directly on Image
                // ignores `.frame(maxWidth: .infinity)` and falls back to the
                // NSImage's native pixel size when given an unbounded width
                // proposal, which would blow past the column's 350pt allotment.
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .overlay(
                        Image(nsImage: filmstrip[idx])
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 4))
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedFrameIndex = idx
                            cover = filmstrip[idx]
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func reloadPreview() async {
        cover = nil
        filmstrip = []
        selectedFrameIndex = nil
        isLoadingCover = true

        let duration = await assetDurationSeconds()

        // Cover first — at ~10% in, or 3s if duration is unknown.
        let coverTime = duration > 0 ? duration * 0.1 : 3.0
        let coverImage: NSImage?
        if let primary = await frame(at: coverTime, width: 720) {
            coverImage = primary
        } else {
            coverImage = await quickLookCover()
        }
        await MainActor.run {
            cover = coverImage
            isLoadingCover = false
        }

        // Filmstrip — extract a few frames in parallel. Skip for very short
        // clips where overlapping fractions would just produce the same frame.
        guard duration > 4 else { return }
        let times = Self.filmstripFractions.map { $0 * duration }
        let strip = await loadFilmstrip(times: times)
        guard !strip.isEmpty else { return }
        await MainActor.run {
            filmstrip = strip
        }
    }

    private func loadFilmstrip(times: [Double]) async -> [NSImage] {
        await withTaskGroup(of: (Int, NSImage?).self) { group in
            for (idx, time) in times.enumerated() {
                group.addTask {
                    if let frameURL = await FFmpegRunner.extractFrame(from: url, at: time, width: 320),
                       let image = NSImage(contentsOf: frameURL) {
                        try? FileManager.default.removeItem(at: frameURL)
                        return (idx, image)
                    }
                    return (idx, nil)
                }
            }
            var collected: [(Int, NSImage)] = []
            for await result in group {
                if let image = result.1 {
                    collected.append((result.0, image))
                }
            }
            return collected.sorted(by: { $0.0 < $1.0 }).map(\.1)
        }
    }

    private func frame(at seconds: Double, width: Int) async -> NSImage? {
        guard let frameURL = await FFmpegRunner.extractFrame(from: url, at: seconds, width: width) else {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: frameURL) }
        return NSImage(contentsOf: frameURL)
    }

    private func quickLookCover() async -> NSImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 600, height: 338),
            scale: scale,
            representationTypes: .thumbnail
        )
        if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            return rep.nsImage
        }
        return nil
    }

    private func assetDurationSeconds() async -> Double {
        let asset = AVURLAsset(url: url)
        if let cmTime = try? await asset.load(.duration) {
            let seconds = cmTime.seconds
            if seconds.isFinite, seconds > 0 {
                return seconds
            }
        }
        // AVF couldn't probe the container (typical for MKV/AVI). Ask ffmpeg
        // to extract the Duration line from its own banner.
        if let probed = await FFmpegRunner.probeDuration(of: url), probed > 0 {
            return probed
        }
        return 0
    }
}

private struct AVPlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

private struct CaptureFrameButton: View {
    let isCapturing: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if isCapturing {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "camera.viewfinder")
                    .frame(width: 18, height: 18)
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(isCapturing)
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct PreviewSubtitleOverlay: View {
    let text: String?

    var body: some View {
        if let text, !text.isEmpty {
            Text(text)
                .font(.system(size: 16, weight: .semibold))
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.95), radius: 1, x: 0, y: 1)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.black.opacity(0.48), in: RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: .infinity)
        }
    }
}

private struct MediaPreviewCard: View {
    static let cardHeight: CGFloat = PreviewCardMetrics.height

    let url: URL
    let title: String
    let subtitleText: String?
    let canCaptureFrame: Bool
    let isCapturingFrame: Bool
    let captureHelp: String
    @ObservedObject var playback: PlaybackController
    let onCaptureFrame: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: playback.hasVideo ? "play.rectangle" : "waveform")
                    .foregroundStyle(.teal)
                Text(title)
                    .font(.headline)
                Spacer()
                if canCaptureFrame {
                    CaptureFrameButton(
                        isCapturing: isCapturingFrame,
                        help: captureHelp,
                        action: onCaptureFrame
                    )
                }
            }

            ZStack(alignment: .bottom) {
                AVPlayerViewRepresentable(player: playback.player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if playback.hasVideo {
                    PreviewSubtitleOverlay(text: subtitleText)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: playback.hasVideo ? 238 : 80)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: PreviewCardMetrics.height, alignment: .topLeading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: PreviewCardMetrics.cornerRadius))
        .clipShape(RoundedRectangle(cornerRadius: PreviewCardMetrics.cornerRadius))
        .shadow(color: PreviewCardMetrics.shadowColor, radius: 9, x: 0, y: 4)
        .task(id: url) {
            await playback.load(url)
        }
        .onDisappear {
            playback.player.pause()
        }
    }
}

private enum VideoFrameCapture {
    static func capture(source: URL, at seconds: Double, subtitleText: String?) async throws -> URL {
        let avFrame = await frameViaAVFoundation(source: source, seconds: seconds)
        let frame: NSImage?
        if let avFrame {
            frame = avFrame
        } else {
            frame = await frameViaFFmpeg(source: source, seconds: seconds)
        }
        guard let frame else {
            throw error("Could not decode a video frame at the current time.")
        }

        let cleanSubtitle = subtitleText.flatMap { text -> String? in
            let cleaned = cleanSubtitleText(text)
            return cleaned.isEmpty ? nil : cleaned
        }
        let data = try renderPNG(frame: frame, subtitleText: cleanSubtitle)
        let destination = uniqueDestination(for: source, seconds: seconds)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    static func cleanSubtitleText(_ raw: String) -> String {
        raw
            .replacingOccurrences(
                of: #"</?(?:b|i|u|font)\b[^>]*>"#,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func frameViaAVFoundation(source: URL, seconds: Double) async -> NSImage? {
        let asset = AVURLAsset(url: source)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty else {
            return nil
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.08, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.08, preferredTimescale: 600)

        let time = CMTime(seconds: max(0, seconds.isFinite ? seconds : 0), preferredTimescale: 600)
        do {
            let cgImage = try await generator.image(at: time).image
            return NSImage(
                cgImage: cgImage,
                size: NSSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
            )
        } catch {
            return nil
        }
    }

    private static func frameViaFFmpeg(source: URL, seconds: Double) async -> NSImage? {
        guard let frameURL = await FFmpegRunner.extractFrame(from: source, at: seconds, width: nil) else {
            return nil
        }
        defer { try? FileManager.default.removeItem(at: frameURL) }
        return NSImage(contentsOf: frameURL)
    }

    private static func renderPNG(frame: NSImage, subtitleText: String?) throws -> Data {
        guard let cgImage = frame.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw error("Could not prepare the captured frame for saving.")
        }
        let pixelWidth = cgImage.width
        let pixelHeight = cgImage.height
        let width = CGFloat(pixelWidth)
        let height = CGFloat(pixelHeight)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
            throw error("Could not create the image canvas.")
        }

        let previousContext = NSGraphicsContext.current
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        NSGraphicsContext.saveGraphicsState()
        defer {
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.current = previousContext
        }

        let canvasSize = NSSize(width: width, height: height)
        frame.draw(in: NSRect(origin: .zero, size: canvasSize))
        if let subtitleText {
            drawSubtitle(subtitleText, canvasSize: canvasSize)
        }

        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw error("Could not encode the captured frame as PNG.")
        }
        return data
    }

    private static func drawSubtitle(_ text: String, canvasSize: NSSize) {
        let width = canvasSize.width
        let height = canvasSize.height
        let fontSize = min(max(width * 0.036, 18), 64)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let maxTextWidth = width * 0.84
        let measured = attributed.boundingRect(
            with: NSSize(width: maxTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )

        let textWidth = min(maxTextWidth, ceil(measured.width) + 4)
        let textHeight = min(height * 0.32, ceil(measured.height) + 4)
        let paddingX = max(12, fontSize * 0.45)
        let paddingY = max(7, fontSize * 0.24)
        let bottom = max(18, height * 0.055)
        let textRect = NSRect(
            x: (width - textWidth) / 2,
            y: bottom + paddingY,
            width: textWidth,
            height: textHeight
        )
        let backgroundRect = textRect.insetBy(dx: -paddingX, dy: -paddingY)
        let background = NSBezierPath(
            roundedRect: backgroundRect,
            xRadius: max(6, fontSize * 0.18),
            yRadius: max(6, fontSize * 0.18)
        )
        NSColor.black.withAlphaComponent(0.42).setFill()
        background.fill()
        attributed.draw(in: textRect)
    }

    private static func uniqueDestination(for source: URL, seconds: Double) -> URL {
        let directory = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        let safeBase = base.isEmpty ? "frame" : base
        let time = filenameTimecode(seconds)
        var candidate = directory
            .appendingPathComponent("\(safeBase)_\(time)")
            .appendingPathExtension("png")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(safeBase)_\(time)-\(counter)")
                .appendingPathExtension("png")
            counter += 1
        }
        return candidate
    }

    private static func filenameTimecode(_ seconds: Double) -> String {
        let totalMilliseconds = Int((max(0, seconds.isFinite ? seconds : 0) * 1000).rounded())
        let milliseconds = totalMilliseconds % 1000
        let totalSeconds = totalMilliseconds / 1000
        let second = totalSeconds % 60
        let minute = (totalSeconds / 60) % 60
        let hour = totalSeconds / 3600
        return String(format: "%02d-%02d-%02d-%03d", hour, minute, second, milliseconds)
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "MSub.VideoFrameCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
