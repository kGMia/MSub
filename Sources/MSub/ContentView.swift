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
                            previewView(for: slot.url)
                        }
                    }
                    .frame(width: 350, alignment: .topLeading)
                    .layoutPriority(1)

                    VStack(spacing: 10) {
                        if let slot = activeSlot {
                            mediaInfoCard(slot)
                        }
                    }
                    .frame(minWidth: 135, maxWidth: .infinity, alignment: .top)
                    .layoutPriority(0)
                }

                VStack(spacing: 12) {
                    if let slot = activeSlot {
                        previewView(for: slot.url)
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

    private func mediaInfoCard(_ slot: FileSlot) -> some View {
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
                                Text("\(term.term) \(term.count)")
                                    .font(.caption2.monospacedDigit())
                                    .lineLimit(1)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 4)
                                    .background(.quinary, in: Capsule())
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
        .frame(minHeight: MediaPreviewCard.cardHeight, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
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
    private func previewView(for url: URL) -> some View {
        switch previewKind(url) {
        case .player:
            MediaPreviewCard(url: url, title: t("preview.title"), playback: playback)
        case .thumbnail:
            UnsupportedMediaPreview(url: url, title: t("preview.title"), language: language)
        case .none:
            EmptyView()
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
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: Capsule())
    }

    private var statusCapsule: some View {
        HStack(spacing: 6) {
            Image(systemName: statusSystemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusTint)

            Text(statusLine)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)

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
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(maxWidth: 148, alignment: .trailing)
        .background(statusTint.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(statusTint.opacity(0.22), lineWidth: 0.8))
        .help(statusHelpText)
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
                ForEach(files.indices, id: \.self) { index in
                    fileChip(index: index)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity)
    }

    private func fileChip(index: Int) -> some View {
        let slot = files[index]
        let isActive = index == activeIndex
        return HStack(spacing: 6) {
            Image(systemName: chipIcon(slot.processingState))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(chipColor(slot.processingState))
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
            Button {
                remove(at: index)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(2)
            }
            .buttonStyle(.plain)
            .help(t("file.remove"))
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
            activeIndex = index
        }
        .help([t(slot.statusKey), slot.statusDetail].filter { !$0.isEmpty }.joined(separator: " · "))
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
                SubtitleEditorPanel(slot: fileSlotBinding(for: slotID), language: language, playback: playback)
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
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                parameterLabel(title, help: help)
                Spacer()
                Text("\(value.wrappedValue)")
                    .font(.caption.monospacedDigit().bold())
            }
            Stepper("", value: value, in: range)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stackedField<Content: View>(_ title: String, help: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            parameterLabel(title, help: help)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func parameterLabel(_ title: String, help: String?) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: false, vertical: true)
            if let help, !help.isEmpty {
                ParameterHelpIcon(help: help)
            }
        }
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
            if !cues.isEmpty {
                let mediaDuration = try await mediaDurationForSubtitleValidation(slotID: slotID)
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

    private func mediaDurationForSubtitleValidation(slotID: UUID) async throws -> Double {
        guard let index = files.firstIndex(where: { $0.id == slotID }) else {
            throw NSError(
                domain: "MSub.SubtitleImport",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: t("error.noActiveFile")]
            )
        }
        let slot = files[index]
        if let duration = slot.mediaInfo?.duration, duration.isFinite, duration > 0 {
            return duration
        }

        let asset = AVURLAsset(url: slot.url)
        let loadedDuration = try? await asset.load(.duration)
        let seconds = loadedDuration?.seconds ?? 0
        guard seconds.isFinite, seconds > 0 else {
            throw NSError(
                domain: "MSub.SubtitleImport",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: t("error.mediaDurationUnavailable")]
            )
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
                .frame(width: 22, height: 22)
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
}

private struct UnsupportedMediaPreview: View {
    let url: URL
    let title: String
    let language: AppLanguage

    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "film")
                    .foregroundStyle(.teal)
                Text(title)
                    .font(.headline)
                Spacer()
            }

            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(.black.opacity(0.85))
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title3)
                        .foregroundStyle(.yellow)
                    Text(Copy.text("preview.unsupported", language: language))
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                    Text(url.pathExtension.uppercased())
                        .font(.caption.monospaced())
                        .foregroundStyle(.white.opacity(0.7))
                    Text(Copy.text("preview.transcribeStillSupported", language: language))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                        .multilineTextAlignment(.center)
                }
                .padding(10)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                .padding(12)
            }
            .frame(height: 238)
        }
        .padding(12)
        .frame(minHeight: MediaPreviewCard.cardHeight, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
        .task(id: url) {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        thumbnail = nil
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 600, height: 338),
            scale: scale,
            representationTypes: .thumbnail
        )
        do {
            let rep = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            thumbnail = rep.nsImage
        } catch {
            thumbnail = nil
        }
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

private struct MediaPreviewCard: View {
    static let cardHeight: CGFloat = 296

    let url: URL
    let title: String
    @ObservedObject var playback: PlaybackController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: playback.hasVideo ? "play.rectangle" : "waveform")
                    .foregroundStyle(.teal)
                Text(title)
                    .font(.headline)
                Spacer()
            }

            AVPlayerViewRepresentable(player: playback.player)
                .frame(height: playback.hasVideo ? 238 : 80)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(12)
        .frame(minHeight: Self.cardHeight, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
        .task(id: url) {
            await playback.load(url)
        }
        .onDisappear {
            playback.player.pause()
        }
    }
}
