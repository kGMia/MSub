import AppKit
import AVFoundation
import AVKit
import QuickLook
import QuickLookThumbnailing
import SwiftUI
import Translation
import UniformTypeIdentifiers

private struct ASRModelProfile {
    let speed: String
    let quality: String
    let scenario: String
}

struct ContentView: View {
    @Environment(APIClient.self) private var api
    @Environment(BackendService.self) private var backend
    @Environment(TranscriptionSettings.self) private var settings
    @Environment(RecentFilesStore.self) private var recentFiles

    @AppStorage("huz.uiLanguage") private var languageRaw = AppLanguage.systemDefault.rawValue

    @State private var playback = PlaybackController()

    @State private var files: [FileSlot] = []
    @State private var activeIndex: Int = 0
    @State private var isProcessing = false
    @State private var isProcessingPaused = false
    @State private var isPauseResumeRequestInFlight = false
    @State private var isSaving = false
    @State private var isDropTargeted = false
    @State private var errorMessage: String?
    @State private var connectionState: ConnectionState = .unknown
    @State private var isSaveCustomPresetSheetPresented = false
    @State private var customPresetName = ""
    @State private var failureDetails: FailureDetails?
    @SceneStorage("ui.detailTab") private var detailTab: DetailTab = .segments
    @State private var processingTask: Task<Void, Never>?
    @State private var selectedFrequentTerm: String?
    @State private var chipScrollEdges = ChipScrollEdges(leading: false, trailing: false)
    @State private var chipsAvailableWidth: CGFloat = 0
    @State private var isCapturingFrame = false
    @State private var isClippingVideo = false
    @State private var quickLookURL: URL?
    @State private var isBackendStatusPopoverPresented = false
    @State private var backendStatusBadgeFrame: CGRect = .zero
    @State private var isStatusDetailHovered = false
    @State private var statusDetailDismissTask: Task<Void, Never>?
    @State private var processingStartedAt: Date?
    @State private var cueListSelection: Set<SubtitleCue.ID> = []
    @State private var cueListColumnCustomization = TableColumnCustomization<SubtitleCue>()
    @State private var isCueListTimingAdjustmentPresented = false
    @State private var cueListTimingMode: TimingAdjustmentMode = .shift
    @State private var cueListTimingShiftSeconds: Double = 0.0
    @State private var cueListTimingGapSeconds: Double = 0.0
    @State private var cueListTimingTargetIDs: Set<SubtitleCue.ID> = []
    @State private var translationJob: TranslationJob?
    @State private var translationConfiguration: TranslationSession.Configuration?
    @State private var isTranslationSheetPresented = false
    @State private var translationSheetSlotID: FileSlot.ID?
    @State private var translationSheetCueIDs: Set<SubtitleCue.ID> = []
    @State private var translationSourceLanguage: TranslationLanguageChoice = .automatic
    @State private var translationTargetLanguage: TranslationLanguageChoice = .common[2]
    @State private var translationMode: TranslationOutputMode = .replace
    @State private var translationErrorMessage: String?
    @State private var isTranslating = false
    @State private var translationUndo = TranslationUndoCoordinator()
    @State private var pendingSidecarAuthorizationURL: URL?
    @Environment(\.undoManager) private var undoManager
    @FocusState private var focusedMediaNameSlotID: UUID?

    private var language: AppLanguage {
        AppLanguage(rawValue: languageRaw) ?? .systemDefault
    }

    private var activeSlot: FileSlot? {
        guard files.indices.contains(activeIndex) else { return nil }
        return files[activeIndex]
    }

    private var activeSelectedCueID: SubtitleCue.ID? {
        activeSlot?.selectedCueID
    }

    private var hasFiles: Bool { !files.isEmpty }

    private var canRun: Bool {
        hasFiles && !isProcessing && !isSaving && !isClippingVideo
    }

    private var activeFailureDetails: FailureDetails? {
        guard let slot = activeSlot else { return nil }
        return failureDetails(for: slot)
    }

    private var pauseResumeLabelKey: String {
        isProcessingPaused ? "action.resume" : "action.pause"
    }

    private var pauseResumeSystemImage: String {
        isProcessingPaused ? "play.circle.fill" : "pause.circle"
    }

    private var pauseResumeTint: Color {
        isProcessingPaused ? .green : .orange
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
        files.contains { $0.hasEditableSubtitle } && !isSaving && !isClippingVideo
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
        let slot = activeSlot
        return SegmentStats(segments: slot?.segments ?? [], duration: timelineDuration(for: slot))
    }

    private var activeClipRangeBinding: Binding<MediaClipRange?> {
        Binding {
            guard files.indices.contains(activeIndex) else { return nil }
            return files[activeIndex].clipRange
        } set: { newValue in
            guard files.indices.contains(activeIndex) else { return }
            let duration = timelineDuration(for: files[activeIndex])
            files[activeIndex].clipRange = newValue?.normalized(in: duration)
        }
    }

    private static let subtitleExtensions = ["srt", "vtt", "json", "txt"]
    private static let unsavedCustomPresetTag = "custom:unsaved"
    private static let builtInPresetTagPrefix = "builtin:"
    private static let savedCustomPresetTagPrefix = "custom:"
    private let visibleASREngines: [ASREngine] = [.fireredasr2, .sensevoice, .mimo, .mega, .apple]
    private let visibleVADEngines: [VADEngine] = [.firered, .energy]
    private let visibleSpeakerClusteringMethods: [SpeakerClusteringMethod] = [.spectral, .incremental]
    private let visibleAudioEventFilterTypes: [AudioEventFilterType] = [.all, .nonLexical, .nonSpeech, .repetition, .lowSpeech]
    private let visibleAudioEventFilterPresets: [AudioEventFilterPreset] = [.balanced, .strict, .broad]

    private func percentageText(_ ratio: Double) -> String {
        localizedPercentageText(ratio, language: language)
    }

    var body: some View {
        content
            .quickLookPreview($quickLookURL)
    }

    private var content: some View {
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
        .overlay(alignment: .topLeading) {
            backendStatusPopoverOverlay
        }
        .animation(.snappy(duration: 0.18), value: isBackendStatusPopoverPresented)
        .onAppear {
            configureTranslationUndo()
        }
        .task {
            await loadConfig()
        }
        .onDisappear {
            processingTask?.cancel()
            processingTask = nil
            statusDetailDismissTask?.cancel()
            statusDetailDismissTask = nil
        }
        .modifier(MSubCommandsModifier(
            detailTab: $detailTab,
            onWillTerminate: { backend.stop(waitForExit: true) }
        ))
        .alert(t("error.title"), isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button(t("button.ok"), role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .alert(t("translation.errorTitle"), isPresented: Binding(get: { translationErrorMessage != nil }, set: { if !$0 { translationErrorMessage = nil } })) {
            Button(t("button.ok"), role: .cancel) {}
        } message: {
            Text(translationErrorMessage ?? "")
        }
        .alert(
            t("sandbox.sidecarPrompt.title"),
            isPresented: sidecarPromptBinding,
            presenting: pendingSidecarAuthorizationURL,
            actions: sidecarPromptActions,
            message: sidecarPromptMessage
        )

        .translationTask(translationConfiguration) { session in
            await runTranslation(session: session)
        }
        .sheet(isPresented: $isTranslationSheetPresented) {
            TranslationSheet(
                language: language,
                sourceLanguage: $translationSourceLanguage,
                targetLanguage: $translationTargetLanguage,
                mode: $translationMode,
                isWholeSlot: translationSheetCueIDs.isEmpty,
                onCancel: { isTranslationSheetPresented = false },
                onConfirm: {
                    isTranslationSheetPresented = false
                    startTranslationFromSheet()
                }
            )
        }
        .sheet(isPresented: $isSaveCustomPresetSheetPresented) {
            SaveCustomPresetSheet(
                language: language,
                name: $customPresetName,
                onCancel: {
                    customPresetName = ""
                    isSaveCustomPresetSheetPresented = false
                },
                onSave: {
                    settings.saveCustomPreset(named: customPresetName)
                    customPresetName = ""
                    isSaveCustomPresetSheetPresented = false
                }
            )
        }
        .sheet(item: $failureDetails) { details in
            FailureDetailsSheet(
                language: language,
                details: details,
                onCopy: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(details.exportText, forType: .string)
                },
                onExport: {
                    exportFailureLog(details)
                },
                onClose: {
                    failureDetails = nil
                }
            )
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
        .onReceive(NotificationCenter.default.publisher(for: .msubTranslateRequested)) { _ in
            translateActiveSubtitle()
        }
        .onReceive(NotificationCenter.default.publisher(for: .msubAuthorizeSidecarFolderRequested)) { _ in
            authorizeSidecarFolderForActive()
        }
        .onReceive(NotificationCenter.default.publisher(for: .msubSaveAllRequested)) { _ in
            Task { await saveAllOutputs() }
        }
        .onAppear {
            syncCueListSelectionFromActiveCue(activeSelectedCueID)
        }
        .onChange(of: activeIndex) { _, _ in
            selectedFrequentTerm = nil
            syncCueListSelectionFromActiveCue(activeSelectedCueID)
        }
        .onChange(of: activeSelectedCueID) { _, newValue in
            syncCueListSelectionFromActiveCue(newValue)
        }
        .onChange(of: cueListSelection) { _, newValue in
            syncActiveCueFromCueListSelection(newValue)
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
                    .frame(minWidth: 280, idealWidth: 310, maxWidth: 380, alignment: .topLeading)
                    .layoutPriority(1)

                    VStack(spacing: 10) {
                        if let slot = activeSlot {
                            mediaInfoCard(slot, fixedHeight: PreviewCardMetrics.height)
                        }
                    }
                    .frame(minWidth: 95, maxWidth: .infinity, alignment: .top)
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
        let emotions = slot.emotionFrequencies
        let hasChips = !terms.isEmpty || !emotions.isEmpty

        return VStack(alignment: .leading, spacing: 6) {
            Label(t("media.info"), systemImage: "info.circle")
                .font(.subheadline.weight(.semibold))

            Divider()

            editableFileNameRow(slot)
            VStack(alignment: .leading, spacing: 3) {
                compactInfoRow(t("media.duration"), value: mediaDurationText(slot))
                compactInfoRow(t("media.size"), value: fileSizeText(for: slot))
                compactInfoRow(t("media.resolution"), value: resolutionText(slot.mediaInfo))
                compactInfoRow(t("media.frameRate"), value: frameRateText(slot.mediaInfo?.frameRate))
                compactInfoRow(t("media.videoCodec"), value: slot.mediaInfo?.videoCodec ?? t("media.noVideo"))
                compactInfoRow(t("media.audio"), value: audioText(slot.mediaInfo))
                compactInfoRow(t("media.bitRate"), value: bitRateText(slot.mediaInfo?.bitRate))
            }

            if hasChips {
                Divider()
                    .padding(.top, 2)

                if !emotions.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(t("media.emotionStats"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        emotionStackedBar(emotions)
                            .frame(minHeight: 28, maxHeight: 36)
                    }
                }

                if !terms.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(t("media.frequentTerms"))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(terms) { term in
                                    frequentTermPill(term)
                                }
                            }
                            .padding(.vertical, 1)
                        }
                        .frame(height: 26)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: fixedHeight, alignment: .topLeading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
    }

    private func emotionStackedBar(_ emotions: [SubtitleEmotionFrequency]) -> some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 3
            let available = max(0, proxy.size.width - CGFloat(max(emotions.count - 1, 0)) * spacing)
            let minWidth: CGFloat = 28
            let raw = emotions.map { max(minWidth, available * CGFloat($0.ratio)) }
            let total = raw.reduce(0, +)
            let scale: CGFloat = (total > available && total > 0) ? available / total : 1
            HStack(spacing: spacing) {
                ForEach(emotions.indices, id: \.self) { index in
                    emotionBarSegment(emotions[index], width: raw[index] * scale)
                }
            }
        }
    }

    private func emotionBarSegment(_ emotion: SubtitleEmotionFrequency, width: CGFloat) -> some View {
        let isSelected = selectedFrequentTerm == emotion.emoji
        let percent = percentageText(emotion.ratio)
        let color = emotionColor(emotion.emoji)
        return Button {
            if isSelected {
                selectedFrequentTerm = nil
            } else {
                selectedFrequentTerm = emotion.emoji
            }
        } label: {
            HStack(spacing: 4) {
                Text(emotion.emoji)
                    .font(.callout)
                if width > 56 {
                    Text(percent)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                color.opacity(isSelected ? 0.95 : 0.7),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(color, lineWidth: isSelected ? 2 : 0)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .frame(width: width)
        .help("\(emotion.emoji) \(emotion.count) (\(percent))")
    }

    private func emotionColor(_ emoji: String) -> Color {
        switch emoji {
        case "\u{1F60A}": return .yellow      // 😊 happy
        case "\u{1F622}": return .blue        // 😢 sad
        case "\u{1F620}": return .red         // 😠 angry
        case "\u{1F610}": return .gray        // 😐 neutral
        case "\u{1F628}": return .purple      // 😨 fearful
        case "\u{1F922}": return .green       // 🤢 disgusted
        case "\u{1F62E}": return .orange      // 😮 surprised
        case "\u{1F3AD}": return .pink        // 🎭 other
        default: return .secondary
        }
    }

    private func chipSectionTitle(hasEmotions: Bool, hasTerms: Bool) -> String {
        switch (hasEmotions, hasTerms) {
        case (true, true):
            return t("media.emotionAndTerms")
        case (true, false):
            return t("media.emotionStats")
        default:
            return t("media.frequentTerms")
        }
    }

    private func emotionRatioPill(_ emotion: SubtitleEmotionFrequency) -> some View {
        let isSelected = selectedFrequentTerm == emotion.emoji
        let percent = percentageText(emotion.ratio)
        return Button {
            if isSelected {
                selectedFrequentTerm = nil
            } else {
                selectedFrequentTerm = emotion.emoji
            }
        } label: {
            HStack(spacing: 3) {
                Text(emotion.emoji)
                    .font(.caption2)
                Text(percent)
                    .font(.caption2.monospacedDigit())
            }
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                isSelected ? AnyShapeStyle(Color.orange.opacity(0.32)) : AnyShapeStyle(Color.orange.opacity(0.12)),
                in: Capsule()
            )
            .overlay(
                Capsule().stroke(Color.orange.opacity(isSelected ? 0.6 : 0.18), lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("\(emotion.emoji) \(emotion.count) (\(percent))")
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
        HStack(spacing: 6) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 6)
            Text(value)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func editableFileNameRow(_ slot: FileSlot) -> some View {
        HStack(spacing: 8) {
            Text(t("media.name"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)

            TextField(t("media.name"), text: fileNameBinding(for: slot.id))
                .font(.caption.monospacedDigit())
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .lineLimit(1)
                .truncationMode(.middle)
                .focused($focusedMediaNameSlotID, equals: slot.id)
                .disabled(isProcessing || isSaving || isClippingVideo)
                .help(t("media.rename.help"))
                .onSubmit {
                    commitFileRename(for: slot.id)
                }
                .onChange(of: focusedMediaNameSlotID) { oldValue, newValue in
                    if oldValue == slot.id, newValue != slot.id {
                        commitFileRename(for: slot.id)
                    }
                }
                .frame(maxWidth: .infinity)
        }
    }

    private func fileNameBinding(for slotID: UUID) -> Binding<String> {
        Binding {
            guard let index = files.firstIndex(where: { $0.id == slotID }) else { return "" }
            return files[index].fileNameDraft ?? files[index].url.lastPathComponent
        } set: { newValue in
            guard let index = files.firstIndex(where: { $0.id == slotID }) else { return }
            files[index].fileNameDraft = newValue
        }
    }

    private func fileSizeText(for slot: FileSlot) -> String {
        guard let bytes = slot.fileSizeBytes else { return "-" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
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

                Group {
                    switch detailTab {
                    case .segments:
                        segmentsPanel
                    case .output:
                        outputPanel
                    case .cueList:
                        cueListPanel
                    }
                }
                .transition(.opacity.animation(.easeOut(duration: 0.12)))
            }
        }
    }

    private func previewKind(_ url: URL) -> MediaPreviewKind {
        MediaPreviewKind(url: url)
    }

    @ViewBuilder
    private func previewView(for slot: FileSlot) -> some View {
        let canCaptureFrame = isVideoSlot(slot)
        switch previewKind(slot.url) {
        case .player:
            MediaPreviewCard(
                url: slot.url,
                title: t("preview.title"),
                cues: slot.cues,
                canCaptureFrame: canCaptureFrame,
                isCapturingFrame: isCapturingFrame,
                captureHelp: t("action.captureFrame.help"),
                nativePreviewHelp: t("action.nativePreview.help"),
                playback: playback,
                onCaptureFrame: {
                    Task { await captureFrameForActiveSlot() }
                },
                onNativePreview: {
                    openNativePreview(slot.url)
                }
            )
        case .thumbnail:
            // Containers AVFoundation can't demux. Try a fast stream-copy
            // remux on the fly: when it succeeds we promote the preview to a
            // full AVPlayer card; when it doesn't (incompatible codec) we
            // keep the filmstrip-based preview. Either way audio routes
            // through AudioSource/ffmpeg so the timeline always plays.
            AdaptiveThumbnailMediaPreview(
                url: slot.url,
                title: t("preview.title"),
                language: language,
                cues: slot.cues,
                canCaptureFrame: canCaptureFrame,
                isCapturingFrame: isCapturingFrame,
                captureHelp: t("action.captureFrame.help"),
                nativePreviewHelp: t("action.nativePreview.help"),
                playback: playback,
                onCaptureFrame: {
                    Task { await captureFrameForActiveSlot() }
                },
                onNativePreview: { previewURL in
                    openNativePreview(previewURL)
                }
            )
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

    private func captureFrameForActiveSlot() async {
        guard !isCapturingFrame, files.indices.contains(activeIndex) else { return }
        let index = activeIndex
        let slot = files[index]
        guard isVideoSlot(slot) else { return }

        let seconds = playback.currentTime
        let subtitleText = previewSubtitleText(for: slot.cues, at: seconds)
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

    private func openNativePreview(_ url: URL) {
        quickLookURL = url
    }

    // MARK: - Toolbar / status

    private var backendStatusPopoverOverlay: some View {
        GeometryReader { proxy in
            if isBackendStatusPopoverPresented {
                let popoverWidth: CGFloat = 320
                let margin: CGFloat = 12
                let rootFrame = proxy.frame(in: .global)
                let hasAnchor = !backendStatusBadgeFrame.isEmpty
                let desiredLeft = hasAnchor
                    ? backendStatusBadgeFrame.minX - rootFrame.minX
                    : margin
                let maxLeft = max(margin, proxy.size.width - popoverWidth - margin)
                let left = min(max(desiredLeft, margin), maxLeft)
                let desiredTop = hasAnchor
                    ? backendStatusBadgeFrame.maxY - rootFrame.minY + 8
                    : margin
                let top = max(margin, desiredTop)

                backendStatusPopover
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16))
                    .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
                    .frame(width: popoverWidth, alignment: .leading)
                    .offset(x: left, y: top)
                    .transition(.scale(scale: 0.98, anchor: .top).combined(with: .opacity))
                    .zIndex(20)
            }
        }
        .allowsHitTesting(isBackendStatusPopoverPresented)
    }

    private var connectionBadge: some View {
        Button {
            isBackendStatusPopoverPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(connectionState.color)
                    .frame(width: 8, height: 8)
                Text(connectionBadgeTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .contentShape(Capsule())
            .animation(.easeInOut(duration: 0.25), value: connectionState)
        }
        .buttonStyle(.plain)
        .help(t("backend.status"))
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .global)
        } action: { newFrame in
            if !newFrame.isEmpty {
                backendStatusBadgeFrame = newFrame
            }
        }
    }

    private var connectionBadgeTitle: String {
        connectionState.title(language: language)
    }

    private var backendStatusPopover: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .fill(connectionState.color)
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 3) {
                    Text(t("backend.status"))
                        .font(.headline)
                    Text(connectionState.title(language: language))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .contentTransition(.opacity)
                }

                Spacer(minLength: 8)
            }
            .animation(.easeInOut(duration: 0.25), value: connectionState)

            Divider()

            backendDetailRow(t("backend.process"), backend.isRunning ? t("backend.running") : t("backend.stopped"))
            backendDetailRow(t("backend.connection"), connectionState.title(language: language))
            backendDetailRow(t("backend.endpoint"), backend.baseURL.absoluteString)
            if backend.isRunning {
                SwiftUI.TimelineView(.periodic(from: .now, by: 1.5)) { _ in
                    backendDetailRow(t("backend.memory"), formattedMemoryUsage())
                }
            }
            if isProcessing {
                backendDetailRow(t("backend.progress"), progressPercentText)
                ProgressView(value: min(max(aggregateProgress, 0), 1))
                    .tint(.teal)
            }

            if !backend.message.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(t("backend.message"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(backend.message)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !backend.lastLog.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(t("backend.lastLog"))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(backend.lastLog)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 10) {
                Button {
                    Task { await loadConfig() }
                } label: {
                    Label(t("backend.check"), systemImage: "dot.radiowaves.left.and.right")
                }

                Spacer(minLength: 8)

                Button {
                    Task { await toggleBackend() }
                } label: {
                    Label(
                        t(backend.isRunning ? "backend.stop" : "backend.start"),
                        systemImage: backend.isRunning ? "stop.circle" : "play.circle"
                    )
                }
                .tint(backend.isRunning ? .red : .accentColor)
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }

    private func backendDetailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func formattedMemoryUsage() -> String {
        guard let bytes = backend.memoryUsageBytes() else { return "—" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .memory
        return formatter.string(fromByteCount: Int64(bytes))
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
                        togglePauseProcessing()
                    } label: {
                        Label(t(pauseResumeLabelKey), systemImage: pauseResumeSystemImage)
                    }
                    .buttonStyle(.borderless)
                    .tint(pauseResumeTint)
                    .disabled(isPauseResumeRequestInFlight)
                }

                if isProcessing || isSaving {
                    ProgressView()
                        .controlSize(.small)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isProcessing || isSaving)

            ProgressView(value: min(max(aggregateProgress, 0), 1))
                .progressViewStyle(.linear)
                .tint(statusTint)
                .animation(.easeInOut(duration: 0.25), value: aggregateProgress)
                .animation(.easeInOut(duration: 0.25), value: statusTint)

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

            if let details = activeFailureDetails {
                HStack(spacing: 8) {
                    Button {
                        failureDetails = details
                    } label: {
                        Label(t("failure.showDetails"), systemImage: "doc.text.magnifyingglass")
                    }

                    Button {
                        exportFailureLog(details)
                    } label: {
                        Label(t("failure.exportLog"), systemImage: "square.and.arrow.down")
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
    }

    private var statusSystemImage: String {
        let key = activeSlot?.statusKey ?? "status.ready"
        switch key {
        case "status.done", "status.saved", "status.savedAll", "status.copied", "status.renamed", "status.videoClipped": return "checkmark.circle.fill"
        case "status.failed", "status.previewFailed": return "exclamationmark.triangle.fill"
        case "status.cancelled": return "minus.circle.fill"
        case "status.paused": return "pause.circle.fill"
        case "status.pausePending": return "hourglass.circle.fill"
        case "status.transcribing", "status.detecting", "status.loading", "status.starting", "status.saving", "status.clippingMedia", "status.videoClipping":
            return "waveform"
        default: return "circle.dotted"
        }
    }

    private var statusTint: Color {
        let key = activeSlot?.statusKey ?? "status.ready"
        switch key {
        case "status.done", "status.saved", "status.savedAll", "status.copied", "status.renamed", "status.videoClipped": return .green
        case "status.failed", "status.previewFailed": return .red
        case "status.cancelled", "status.paused", "status.pausePending": return .orange
        case "status.transcribing", "status.detecting", "status.loading", "status.starting", "status.saving", "status.clippingMedia", "status.videoClipping":
            return .teal
        default: return .secondary
        }
    }

    // MARK: - Settings sidebar

    private var settingsPanel: some View {
        @Bindable var settings = settings
        return Form {
            Section(t("input.section")) {
                stackedField(t("settings.asrEngine"), help: t("help.asrEngine")) {
                    Picker("", selection: $settings.asrEngine) {
                        ForEach(visibleASREngines) { engine in
                            Text(asrEngineTitle(engine)).tag(engine)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .onChange(of: settings.asrEngine) { _, newValue in
                        settings.selectASREngine(newValue)
                    }
                }
                modelProfileStrip(for: settings.effectiveASREngine)

                if settings.effectiveASREngine != .apple {
                    stackedField(t("settings.model"), help: modelHelpText()) {
                        HStack(spacing: 6) {
                            TextField("", text: $settings.model)
                                .textFieldStyle(.roundedBorder)
                                .onChange(of: settings.model) { _, _ in
                                    settings.modelPathDidChange()
                                }
                            Button {
                                chooseASRModelDirectory()
                            } label: {
                                Image(systemName: "folder")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help(t("action.chooseModelFolder"))

                            Button {
                                resetASRModelToDefault()
                            } label: {
                                Image(systemName: "arrow.counterclockwise")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(settings.currentModelInfo == nil)
                            .help(t("model.useDefault"))
                        }
                    }
                    if let info = settings.currentModelInfo {
                        modelStatusCard(info)
                    }
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
                    HStack(spacing: 8) {
                        Picker("", selection: presetSelectionBinding) {
                            Text(t("preset.custom"))
                                .tag(Self.unsavedCustomPresetTag)
                            ForEach(RecognitionPreset.allCases) { preset in
                                Text(presetTitle(preset))
                                    .tag(builtInPresetTag(preset))
                            }
                            if !settings.customPresets.isEmpty {
                                ForEach(settings.customPresets) { preset in
                                    Text(preset.name)
                                        .tag(savedCustomPresetTag(preset.id))
                                }
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)

                        if isUnsavedCustomPreset {
                            Button {
                                customPresetName = ""
                                isSaveCustomPresetSheetPresented = true
                            } label: {
                                Image(systemName: "plus")
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help(t("preset.saveCustom"))
                        }
                    }
                }

                Text(currentPresetHelpText())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                stackedField(t("settings.vadEngine"), help: vadEngineHelpText()) {
                    Picker("", selection: $settings.vadEngine) {
                        ForEach(visibleVADEngines) { engine in
                            Text(vadEngineTitle(engine)).tag(engine)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                if let status = vadStatusText() {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Toggle(isOn: $settings.audioEventFilter) {
                    parameterLabel(t("settings.audioEventFilter"), help: t("help.audioEventFilter"))
                }
                .toggleStyle(.switch)
                if settings.audioEventFilter {
                    stackedField(t("settings.audioEventFilterType"), help: t("help.audioEventFilterType")) {
                        Picker("", selection: $settings.audioEventFilterType) {
                            ForEach(visibleAudioEventFilterTypes) { type in
                                Text(audioEventFilterTypeTitle(type)).tag(type)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    stackedField(t("settings.audioEventPreset"), help: t("help.audioEventPreset")) {
                        Picker("", selection: $settings.audioEventPreset) {
                            ForEach(visibleAudioEventFilterPresets) { preset in
                                Text(audioEventFilterPresetTitle(preset)).tag(preset)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .onChange(of: settings.audioEventPreset) { _, newValue in
                            settings.audioEventThreshold = newValue.defaultThreshold
                        }
                    }
                    numericField(t("settings.audioEventThreshold"), value: $settings.audioEventThreshold, suffix: "", help: t("help.audioEventThreshold"))
                }

                Button {
                    settings.resetRecognitionDefaults()
                } label: {
                    Label(t("preset.reset"), systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.small)

                if settings.isFireRedVADActive {
                    numericField(t("settings.fireRedVADThreshold"), value: $settings.fireRedVADThreshold, suffix: "", help: t("help.fireRedVADThreshold"))
                    stepperField(t("settings.fireRedVADSmoothWindow"), value: $settings.fireRedVADSmoothWindow, in: 1...31, help: t("help.fireRedVADSmoothWindow"))
                } else {
                    numericField(t("settings.threshold"), value: $settings.vadThreshold, suffix: "dB", help: t("help.threshold"))
                }
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
                if settings.isSenseVoiceActive {
                    stackedField(t("settings.recognitionLanguage"), help: t("help.recognitionLanguage")) {
                        Picker("", selection: $settings.recognitionLanguage) {
                            ForEach(settings.supportedRecognitionLanguages) { option in
                                Text(recognitionLanguageTitle(option)).tag(option)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }

                    Toggle(isOn: $settings.senseVoiceUseITN) {
                        parameterLabel(t("settings.useITN"), help: t("help.useITN"))
                    }
                    .toggleStyle(.switch)
                } else if settings.usesQwenGenerationControls {
                    stackedField(t("settings.recognitionLanguage"), help: t("help.recognitionLanguage")) {
                        Picker("", selection: $settings.recognitionLanguage) {
                            ForEach(settings.supportedRecognitionLanguages) { option in
                                Text(recognitionLanguageTitle(option)).tag(option)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }

                    stepperField(t("settings.mimoMaxTokens"), value: $settings.mimoMaxTokens, in: settings.generationMaxTokensRange, help: t("help.mimoMaxTokens"))
                    numericField(t("settings.mimoTemperature"), value: $settings.mimoTemperature, suffix: "", help: t("help.mimoTemperature"))
                    numericField(t("settings.mimoTopP"), value: $settings.mimoTopP, suffix: "", help: t("help.mimoTopP"))
                    stepperField(t("settings.mimoTopK"), value: $settings.mimoTopK, in: 0...1000, help: t("help.mimoTopK"))
                } else if settings.effectiveASREngine == .apple {
                    stackedField(t("settings.recognitionLanguage"), help: t("help.recognitionLanguage")) {
                        Picker("", selection: $settings.recognitionLanguage) {
                            ForEach(settings.supportedRecognitionLanguages) { option in
                                Text(recognitionLanguageTitle(option)).tag(option)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }

                    Toggle(isOn: $settings.appleSpeechFastResults) {
                        parameterLabel(t("settings.appleSpeechFast"), help: t("help.appleSpeechFast"))
                    }
                    .toggleStyle(.switch)

                    Toggle(isOn: $settings.appleSpeechEtiquetteFilter) {
                        parameterLabel(t("settings.appleSpeechEtiquette"), help: t("help.appleSpeechEtiquette"))
                    }
                    .toggleStyle(.switch)
                } else {
                    stepperField(t("settings.beam"), value: $settings.beamSize, in: 1...8, help: t("help.beam"))
                }

                if settings.usesBackendRecognition {
                    numericField(t("settings.confidence"), value: $settings.minConfidence, suffix: "", help: t("help.confidence"))
                    stepperField(t("settings.lineChars"), value: $settings.lineChars, in: 0...80, help: t("help.lineChars"))
                }
                if settings.usesSenseVoiceRichInfo {
                    Toggle(isOn: $settings.senseVoiceRichInfo) {
                        parameterLabel(t("settings.senseVoiceRichInfo"), help: t("help.senseVoiceRichInfo"))
                    }
                    .toggleStyle(.switch)
                    if settings.senseVoiceRichInfo && !settings.isSenseVoiceActive {
                        stackedField(t("settings.emotionModel"), help: t("help.emotionModel")) {
                            HStack(spacing: 8) {
                                TextField("", text: $settings.emotionModel)
                                    .textFieldStyle(.roundedBorder)
                                Button {
                                    chooseEmotionModelDirectory()
                                } label: {
                                    Image(systemName: "folder")
                                }
                                .buttonStyle(.bordered)
                                .help(t("action.chooseModelFolder"))
                                Button {
                                    useRemoteEmotionModel()
                                } label: {
                                    Image(systemName: "icloud.and.arrow.down")
                                }
                                .buttonStyle(.bordered)
                                .help(t("action.useRemoteModel"))
                            }
                        }
                        Text(settings.emotionModelAvailable ? t("model.localAvailable") : t("emotion.remote"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if settings.usesBackendRecognition {
                    Toggle(isOn: $settings.diarizeSpeakers) {
                        parameterLabel(t("settings.diarizeSpeakers"), help: t("help.diarizeSpeakers"))
                    }
                    .toggleStyle(.switch)
                }
                if settings.diarizeSpeakers {
                    stackedField(t("settings.speakerLabelingEngine"), help: t("help.speakerLabelingEngine")) {
                        Picker("", selection: $settings.speakerLabelingEngine) {
                            ForEach(SpeakerLabelingEngine.allCases) { engine in
                                Text(speakerLabelingEngineTitle(engine)).tag(engine)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    if settings.speakerLabelingEngine == .eres2netv2 {
                        stackedField(t("settings.speakerRecognitionModel"), help: t("help.speakerRecognitionModel")) {
                            HStack(alignment: .center, spacing: 8) {
                                TextField("", text: $settings.speakerRecognitionModel)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(height: 22)
                                Button {
                                    chooseSpeakerRecognitionModelDirectory()
                                } label: {
                                    Image(systemName: "folder")
                                        .frame(width: 14, height: 14)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                                .frame(height: 22)
                                .help(t("action.chooseModelFolder"))
                                Button {
                                    useRemoteSpeakerRecognitionModel()
                                } label: {
                                    Image(systemName: "icloud.and.arrow.down")
                                        .frame(width: 14, height: 14)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.regular)
                                .frame(height: 22)
                                .help(t("action.useRemoteModel"))
                            }
                        }
                        Text(settings.speakerRecognitionModelAvailable ? t("model.localAvailable") : t("speakerRecognition.remote"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        stackedField(t("settings.speakerClusteringMethod"), help: t("help.speakerClusteringMethod")) {
                            Picker("", selection: $settings.speakerClusteringMethod) {
                                ForEach(visibleSpeakerClusteringMethods) { method in
                                    Text(speakerClusteringMethodTitle(method)).tag(method)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                        }
                        numericField(t("settings.speakerClusterThreshold"), value: $settings.speakerClusterThreshold, suffix: "", help: t("help.speakerClusterThreshold"))
                    }
                    stepperField(t("settings.speakerCount"), value: $settings.diarizationSpeakerCount, in: 0...12, help: t("help.speakerCount"))
                }

                if settings.usesFireRedDecodingControls {
                    DisclosureGroup(t("settings.decoding")) {
                        numericField(t("settings.softmaxSmoothing"), value: $settings.softmaxSmoothing, suffix: "", help: t("help.softmaxSmoothing"))
                        numericField(t("settings.lengthPenalty"), value: $settings.lengthPenalty, suffix: "", help: t("help.lengthPenalty"))
                        numericField(t("settings.eosPenalty"), value: $settings.eosPenalty, suffix: "", help: t("help.eosPenalty"))
                        stepperField(t("settings.decodeMaxLen"), value: $settings.decodeMaxLen, in: 0...512, help: t("help.decodeMaxLen"))

                    }
                }
            }

            Section(t("settings.timeline")) {
                Toggle(isOn: $settings.timelineSpeakerMarkersEnabled) {
                    parameterLabel(t("settings.timelineSpeakerMarkers"), help: t("help.timelineSpeakerMarkers"))
                }
                .toggleStyle(.switch)

                stackedField(t("settings.waveformResolution"), help: t("help.waveformResolution")) {
                    Picker("", selection: $settings.waveformResolution) {
                        ForEach(WaveformResolution.allCases) { resolution in
                            Text(t("settings.waveformResolution.\(resolution.rawValue)")).tag(resolution)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                }
            }
        }
        .formStyle(.grouped)
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
            .accessibilityLabel(t("file.add"))

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
            .accessibilityLabel(t("file.clearAll"))

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
        statusCapsuleContent(expanded: false)
            .onHover { hovering in
                setStatusDetailHovered(hovering)
            }
            .help(statusHelpText)
            .popover(isPresented: $isStatusDetailHovered, arrowEdge: .top) {
                statusCapsuleExpandedBody
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .frame(width: 240, alignment: .leading)
                    .onHover { hovering in
                        setStatusDetailHovered(hovering)
                    }
            }
            .animation(.spring(response: 0.55, dampingFraction: 0.82), value: compactStatusText)
            .animation(.spring(response: 0.55, dampingFraction: 0.82), value: isProcessing)
            .animation(.spring(response: 0.55, dampingFraction: 0.82), value: statusSystemImage)
            .animation(.spring(response: 0.55, dampingFraction: 0.82), value: statusTint)
            .animation(.easeOut(duration: 0.25), value: aggregateProgress)
    }

    private func setStatusDetailHovered(_ hovering: Bool) {
        statusDetailDismissTask?.cancel()
        statusDetailDismissTask = nil
        if hovering {
            isStatusDetailHovered = true
        } else {
            statusDetailDismissTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled else { return }
                isStatusDetailHovered = false
            }
        }
    }

    @ViewBuilder
    private func statusCapsuleContent(expanded: Bool) -> some View {
        if expanded {
            statusCapsuleExpandedBody
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .frame(width: 240, alignment: .leading)
                .background(statusTint.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 18))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(statusTint.opacity(0.35), lineWidth: 1.0))
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .geometryGroup()
        } else {
            statusCapsuleCompactBody
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(statusTint.opacity(0.12), in: Capsule())
                .overlay(Capsule().stroke(statusTint.opacity(0.22), lineWidth: 0.8))
                .clipShape(Capsule())
                .geometryGroup()
        }
    }

    private var statusCapsuleCompactBody: some View {
        HStack(spacing: 6) {
            Image(systemName: statusSystemImage)
                .font(Font.caption.weight(.semibold))
                .foregroundStyle(statusTint)
                .contentTransition(.symbolEffect(.replace))

            Text(compactStatusText)
                .font(Font.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.opacity)

            if isProcessing {
                ProgressView(value: min(max(aggregateProgress, 0), 1))
                    .progressViewStyle(.linear)
                    .tint(statusTint)
                    .frame(width: 36)
                    .transition(.opacity)

                Text(progressPercentText)
                    .font(Font.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(statusTint)
                    .contentTransition(.numericText(value: aggregateProgress))
                    .transition(.opacity)

                Button {
                    togglePauseProcessing()
                } label: {
                    Image(systemName: pauseResumeSystemImage)
                        .font(Font.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(pauseResumeTint)
                .disabled(isPauseResumeRequestInFlight)
                .help(t(pauseResumeLabelKey))
                .transition(.scale.combined(with: .opacity))
            }
        }
    }

    private var statusCapsuleExpandedBody: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: statusSystemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(statusTint)
                    .contentTransition(.symbolEffect(.replace))

                Text(compactStatusText)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 6)

                if isProcessing {
                    Button {
                        togglePauseProcessing()
                    } label: {
                        Image(systemName: pauseResumeSystemImage)
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(pauseResumeTint)
                    .disabled(isPauseResumeRequestInFlight)
                    .help(t(pauseResumeLabelKey))
                }
            }

            if let slot = activeSlot {
                Text(slot.url.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if isProcessing {
                HStack(spacing: 8) {
                    ProgressView(value: min(max(aggregateProgress, 0), 1))
                        .progressViewStyle(.linear)
                        .tint(statusTint)

                    Text(progressPercentText)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(statusTint)
                        .contentTransition(.numericText(value: aggregateProgress))
                        .frame(minWidth: 34, alignment: .trailing)
                }
            }

            if hasAnyStatusBadge {
                HStack(spacing: 6) {
                    if let remaining = estimatedRemainingText {
                        statusCapsuleDetail(
                            icon: "clock.fill",
                            value: remaining,
                            helpText: t("status.detail.remaining")
                        )
                    }
                    if let slot = activeSlot, slot.chunkTotal > 0 {
                        statusCapsuleDetail(
                            icon: "square.stack.3d.up.fill",
                            value: "\(slot.chunkCurrent)/\(slot.chunkTotal)",
                            helpText: t("status.detail.chunks")
                        )
                    }
                    if files.count > 1 {
                        let done = files.filter { $0.processingState == .done }.count
                        statusCapsuleDetail(
                            icon: "doc.on.doc.fill",
                            value: "\(done)/\(files.count)",
                            helpText: t("status.detail.files")
                        )
                    }
                    if let slot = activeSlot, !slot.segments.isEmpty {
                        statusCapsuleDetail(
                            icon: "text.quote",
                            value: "\(slot.segments.count)",
                            helpText: t("status.detail.segments")
                        )
                    }
                    Spacer(minLength: 0)
                }
            }

            if let details = activeFailureDetails {
                HStack(spacing: 8) {
                    Button {
                        failureDetails = details
                    } label: {
                        Label(t("failure.showDetails"), systemImage: "doc.text.magnifyingglass")
                    }

                    Button {
                        exportFailureLog(details)
                    } label: {
                        Label(t("failure.exportLog"), systemImage: "square.and.arrow.down")
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
        }
    }

    private var hasAnyStatusBadge: Bool {
        if estimatedRemainingText != nil { return true }
        if let slot = activeSlot, slot.chunkTotal > 0 { return true }
        if files.count > 1 { return true }
        if let slot = activeSlot, !slot.segments.isEmpty { return true }
        return false
    }

    private func statusCapsuleDetail(icon: String, value: String, helpText: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(statusTint.opacity(0.14), in: Capsule())
        .help(helpText)
        .transition(.scale(scale: 0.7).combined(with: .opacity))
    }

    private var progressPercentText: String {
        percentageText(aggregateProgress)
    }

    private var estimatedRemainingText: String? {
        guard isProcessing, !isProcessingPaused, let processingStartedAt else { return nil }
        let progress = min(max(aggregateProgress, 0), 0.999)
        guard progress > 0.025 else { return t("status.remaining.calculating") }
        let elapsed = Date().timeIntervalSince(processingStartedAt)
        guard elapsed >= 4 else { return t("status.remaining.calculating") }
        let remaining = elapsed * (1 - progress) / progress
        guard remaining.isFinite, remaining > 0 else { return nil }
        return "~\(compactDurationText(remaining))"
    }

    private func compactDurationText(_ seconds: TimeInterval) -> String {
        let totalSeconds = max(1, Int(ceil(seconds)))
        let secondUnit = t("duration.secondShort")
        let minuteUnit = t("duration.minuteShort")
        let hourUnit = t("duration.hourShort")
        let dayUnit = t("duration.dayShort")
        if totalSeconds < 60 {
            return "\(totalSeconds)\(secondUnit)"
        }
        let totalMinutes = totalSeconds / 60
        let remainingSeconds = totalSeconds % 60
        if totalMinutes < 60 {
            if remainingSeconds == 0 {
                return "\(totalMinutes)\(minuteUnit)"
            }
            return "\(totalMinutes)\(minuteUnit) \(remainingSeconds)\(secondUnit)"
        }
        let totalHours = totalMinutes / 60
        let remainingMinutes = totalMinutes % 60
        if totalHours < 24 {
            if remainingMinutes == 0 {
                return "\(totalHours)\(hourUnit)"
            }
            return "\(totalHours)\(hourUnit) \(remainingMinutes)\(minuteUnit)"
        }
        let days = totalHours / 24
        let remainingHours = totalHours % 24
        if remainingHours == 0 {
            return "\(days)\(dayUnit)"
        }
        return "\(days)\(dayUnit) \(remainingHours)\(hourUnit)"
    }

    private var compactStatusText: String {
        guard let slot = activeSlot else { return t("status.ready") }
        return t(slot.statusKey)
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
            if files.count == 0 { return t("input.supportedFormats") }
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
        .dropDestination(for: URL.self) { urls, _ in
            addFiles(urls)
            return true
        } isTargeted: { hovering in
            isDropTargeted = hovering
        }
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
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            chipsAvailableWidth = width
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

    private var chipNameMaxWidth: CGFloat {
        let count = max(1, files.count)
        guard chipsAvailableWidth > 0 else { return 200 }
        let perChipBudget = (chipsAvailableWidth - 20 + 8) / CGFloat(count) - 50
        return min(max(perChipBudget, 70), 260)
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
        let targetID = slot.id
        return FileChipView(
            slot: slot,
            isActive: isActive,
            iconName: chipIcon(slot.processingState),
            iconColor: chipColor(slot.processingState),
            nameMaxWidth: chipNameMaxWidth,
            removeHelp: t("file.remove"),
            statusHelp: [t(slot.statusKey), slot.statusDetail].filter { !$0.isEmpty }.joined(separator: " · "),
            showInFinderLabel: t("file.showInFinder"),
            openWithDefaultLabel: t("file.openWithDefault"),
            onSelect: { activeIndex = index },
            onRemove: { remove(at: index) },
            onReorder: { draggedID in moveChip(from: draggedID, to: targetID) }
        )
    }

    private func moveChip(from sourceID: UUID, to targetID: UUID) {
        guard let fromIdx = files.firstIndex(where: { $0.id == sourceID }),
              let toIdx = files.firstIndex(where: { $0.id == targetID }),
              fromIdx != toIdx else { return }
        let activeID = files.indices.contains(activeIndex) ? files[activeIndex].id : nil
        withAnimation(.spring(response: 0.45, dampingFraction: 0.82)) {
            let item = files.remove(at: fromIdx)
            files.insert(item, at: toIdx)
            if let activeID, let newIdx = files.firstIndex(where: { $0.id == activeID }) {
                activeIndex = newIdx
            }
        }
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
        let slot = activeSlot
        let segments = slot?.segments ?? []
        let duration = timelineDuration(for: slot)
        let clipRange = slot.flatMap { normalizedClipRange(for: $0) }
        let flaggedSegmentCount = segments.filter(\.flagged).count
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(t("segments.title"))
                    .font(.headline)
                Spacer()
                if flaggedSegmentCount > 0 {
                    Button(role: .destructive) {
                        deleteFlaggedSegments()
                    } label: {
                        Label(
                            String(format: t("segments.deleteMarked"), flaggedSegmentCount),
                            systemImage: "trash"
                        )
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(isProcessing)
                    .help(t("segments.deleteMarked.help"))
                }
                Text(segments.isEmpty ? t("segments.noPreview") : "\(segments.count) \(t("segments.count"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TimelineView(
                segments: segments,
                duration: duration,
                clipRange: activeClipRangeBinding,
                language: language,
                isEnabled: !isProcessing
            )
                .frame(height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .help(t("segments.keepRange.help"))

            clipRangeRow(clipRange)

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
                                    .foregroundStyle(segment.flagged ? .orange : .secondary)
                                Text(timeRange(segment))
                                    .font(.caption.monospacedDigit())
                                let labelText = segmentLabelText(segment)
                                if !labelText.isEmpty {
                                    Text(labelText)
                                        .font(.caption2)
                                        .foregroundStyle(segment.flagged ? .orange : .secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text("\(segment.duration, specifier: "%.2f")s")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                Button {
                                    toggleSegmentFlag(segment)
                                } label: {
                                    Image(systemName: segment.flagged ? "flag.fill" : "flag")
                                        .frame(width: 16, height: 16)
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                                .help(segment.flagged ? t("segments.unmark") : t("segments.mark"))
                                Button {
                                    previewSegment(segment)
                                } label: {
                                    Image(systemName: "play.circle")
                                        .frame(width: 16, height: 16)
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                                .help(t("segments.previewSegment"))
                                Button(role: .destructive) {
                                    deleteSegment(segment)
                                } label: {
                                    Image(systemName: "trash")
                                        .frame(width: 16, height: 16)
                                }
                                .buttonStyle(.borderless)
                                .controlSize(.small)
                                .disabled(isProcessing || segments.count <= 1)
                                .help(t("segments.delete"))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(segment.flagged ? Color.orange.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                            .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(RoundedRectangle(cornerRadius: 6))
                            .onTapGesture {
                                previewSegment(segment)
                            }
                            .help(t("segments.tapToPlay"))
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 340, idealHeight: 560, maxHeight: 760)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
    }

    private func segmentLabelText(_ segment: SubtitleSegment) -> String {
        guard let label = segment.audioLabel, !label.isEmpty else {
            return segment.flagged ? t("segments.marked") : ""
        }
        if label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "speech" {
            return segment.flagged ? t("segments.marked") : ""
        }
        if let score = segment.audioScore {
            return "\(label) \(Int((score * 100).rounded()))%"
        }
        return label
    }

    private func previewSegment(_ segment: SubtitleSegment) {
        playback.playRange(start: segment.start, end: segment.end)
    }

    private func toggleSegmentFlag(_ segment: SubtitleSegment) {
        guard files.indices.contains(activeIndex),
              let segmentIndex = files[activeIndex].segments.firstIndex(where: { $0.id == segment.id }) else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            files[activeIndex].segments[segmentIndex] = files[activeIndex].segments[segmentIndex]
                .withFlagged(!files[activeIndex].segments[segmentIndex].flagged)
        }
        syncPreviewSegmentsForActiveSlot()
    }

    private func deleteSegment(_ segment: SubtitleSegment) {
        guard files.indices.contains(activeIndex),
              files[activeIndex].segments.count > 1 else { return }
        withAnimation(.easeInOut(duration: 0.16)) {
            files[activeIndex].segments.removeAll { $0.id == segment.id }
            files[activeIndex].segments = reindexedSegments(files[activeIndex].segments)
            files[activeIndex].statusDetail = "\(files[activeIndex].segments.count) \(t("segments.count"))"
        }
        syncPreviewSegmentsForActiveSlot()
    }

    private func deleteFlaggedSegments() {
        guard files.indices.contains(activeIndex) else { return }
        let flaggedCount = files[activeIndex].segments.filter(\.flagged).count
        guard flaggedCount > 0 else { return }
        guard files[activeIndex].segments.count > flaggedCount else {
            errorMessage = t("segments.deleteMarked.emptyError")
            return
        }
        withAnimation(.easeInOut(duration: 0.18)) {
            files[activeIndex].segments.removeAll(where: \.flagged)
            files[activeIndex].segments = reindexedSegments(files[activeIndex].segments)
            files[activeIndex].statusDetail = "\(files[activeIndex].segments.count) \(t("segments.count"))"
        }
        syncPreviewSegmentsForActiveSlot()
    }

    private func reindexedSegments(_ segments: [SubtitleSegment]) -> [SubtitleSegment] {
        segments.enumerated().map { offset, segment in
            segment.reindexed(offset + 1)
        }
    }

    private func syncPreviewSegmentsForActiveSlot() {
        guard files.indices.contains(activeIndex),
              let previewID = files[activeIndex].previewID else { return }
        let segments = files[activeIndex].segments
        let timeOffset = files[activeIndex].previewTimeOffset
        Task {
            do {
                try await api.updatePreviewSegments(
                    previewID: previewID,
                    segments: segments,
                    timeOffset: timeOffset
                )
            } catch {
                AppLog.api.error("updatePreviewSegments failed: \(error.localizedDescription, privacy: .public)")
                errorMessage = error.localizedDescription
            }
        }
    }

    private func clipRangeRow(_ clipRange: MediaClipRange?) -> some View {
        HStack(spacing: 8) {
            Label(t("segments.keepRange"), systemImage: "scissors")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(clipRangeSummary(clipRange))
                .font(.caption.monospacedDigit())
                .foregroundStyle(clipRange == nil ? .secondary : .primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if clipRange != nil {
                if let slot = activeSlot, isVideoSlot(slot) {
                    Button {
                        Task { await clipActiveVideoToSelectedRange() }
                    } label: {
                        if isClippingVideo {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label(t("segments.clipVideo"), systemImage: "film")
                        }
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(isProcessing || isSaving || isClippingVideo)
                    .help(t("segments.clipVideo.help"))
                }
                Button {
                    clearClipRangeForActiveSlot()
                } label: {
                    Label(t("segments.clearClip"), systemImage: "xmark.circle")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(isProcessing)
                .help(t("segments.clearClip"))
            }
        }
        .padding(.horizontal, 2)
    }

    // MARK: - Output panel

    private var outputPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(t("output.title"))
                    .font(.headline)
                Spacer()
                Button {
                    translateActiveSubtitle()
                } label: {
                    Label(t("translation.translate"), systemImage: "character.bubble")
                }
                .labelStyle(.iconOnly)
                .disabled(activeSlot?.hasEditableSubtitle != true || isTranslating || isProcessing)
                .help(t("translation.translateAllHelp"))

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
                    playback: playback,
                    onTranslateCue: { cueID, choice, mode in
                        translateCues(in: slotID, cueIDs: [cueID], to: choice, mode: mode)
                    }
                )
                .id(slotID)
            } else if let slot = activeSlot,
                      !slot.previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                TextEditor(text: .constant(slot.previewText))
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: .infinity, minHeight: 300)
                    .accessibilityLabel(t("output.title"))
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

    // MARK: - Cue list panel

    private static let cueListNewlineSentinel = "⏎"

    private var cueListPanel: some View {
        let slot = activeSlot
        let segments = slot?.segments ?? []
        let duration = timelineDuration(for: slot)
        let highlightedRanges: [TimelineHighlightRange] = slot?.cues
            .filter { cueListSelection.contains($0.id) }
            .map { TimelineHighlightRange(start: $0.start, end: $0.end) }
            ?? []

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(t("tab.cueList"))
                    .font(.headline)
                Spacer()
                if let slot, !slot.cues.isEmpty {
                    Text("\(slot.cues.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Button {
                    if let slot { presentTranslationSheet(forSlot: slot.id) }
                } label: {
                    Image(systemName: "character.bubble")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(slot?.hasEditableSubtitle != true || isTranslating)
                .help(t("translation.translateAllHelp"))
                .accessibilityLabel(t("translation.translateAllHelp"))

                Button {
                    playback.togglePlayPause()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 18, height: 18)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .help(t(playback.isPlaying ? "editor.pause" : "editor.play"))
                .disabled(slot == nil)
                .accessibilityLabel(t(playback.isPlaying ? "editor.pause" : "editor.play"))

                if !cueListSelection.isEmpty {
                    Button(role: .destructive) {
                        deleteCuesFromActiveCueList(cueListSelection)
                    } label: {
                        Label(t("cueList.delete"), systemImage: "trash")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderless)
                    .help(t("cueList.delete"))
                }
            }

            PlaybackTimelineView(
                segments: segments,
                duration: duration,
                clipRange: activeClipRangeBinding,
                language: language,
                isEnabled: !isProcessing,
                playback: playback,
                allowsClipSelection: false,
                onSeek: { seconds in
                    playback.seek(to: seconds)
                },
                highlightedRanges: highlightedRanges
            )
            .frame(height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if let slot, !slot.cues.isEmpty {
                cueListTable(for: slot)
            } else {
                ContentUnavailableView(
                    t("segments.empty"),
                    systemImage: "captions.bubble",
                    description: Text(t("action.preview"))
                )
                .frame(maxWidth: .infinity, minHeight: 260)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14))
        .sheet(isPresented: $isCueListTimingAdjustmentPresented) {
            TimingAdjustmentSheet(
                language: language,
                cueCount: cueListTimingTargetIDs.count,
                mode: $cueListTimingMode,
                shiftSeconds: $cueListTimingShiftSeconds,
                gapSeconds: $cueListTimingGapSeconds,
                apply: applyCueListTimingAdjustment
            )
        }
    }

    private func cueListTable(for slot: FileSlot) -> some View {
        let frameRate = slot.mediaInfo?.frameRate ?? 0
        return Table(slot.cues, selection: $cueListSelection, columnCustomization: $cueListColumnCustomization) {
            TableColumn(t("cueList.index")) { cue in
                Text("\(cue.index)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .width(min: 24, ideal: 28, max: 44)
            .customizationID("index")

            TableColumn(t("cueList.start")) { cue in
                Text(SubtitleDocument.displayTime(cue.start))
                    .font(.caption.monospacedDigit())
            }
            .width(min: 50, ideal: 58, max: 80)
            .customizationID("start")

            TableColumn(t("cueList.end")) { cue in
                Text(SubtitleDocument.displayTime(cue.end))
                    .font(.caption.monospacedDigit())
            }
            .width(min: 50, ideal: 58, max: 80)
            .customizationID("end")

            TableColumn(t("cueList.duration")) { cue in
                Text(String(format: "%.2fs", cue.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .width(min: 42, ideal: 50, max: 70)
            .customizationID("duration")

            TableColumn(t("cueList.rate")) { cue in
                Text(cueSpeechRate(cue))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .width(min: 46, ideal: 54, max: 80)
            .customizationID("rate")

            TableColumn(t("cueList.speaker")) { cue in
                TextField("", text: cueSpeakerBinding(for: cue.id))
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .lineLimit(1)
                    .disabled(isProcessing || isSaving || isClippingVideo)
            }
            .width(min: 60, ideal: 80, max: 140)
            .customizationID("speaker")

            TableColumn(t("cueList.content")) { cue in
                TextField("", text: cueTextDisplayBinding(for: cue.id))
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .disabled(isProcessing || isSaving || isClippingVideo)
            }
            .customizationID("content")

            TableColumn("\(t("cueList.start"))F") { cue in
                Text(cueFrameNumber(cue.start, frameRate: frameRate))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .width(min: 40, ideal: 50, max: 72)
            .customizationID("startFrame")
            .defaultVisibility(.hidden)

            TableColumn("\(t("cueList.end"))F") { cue in
                Text(cueFrameNumber(cue.end, frameRate: frameRate))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .width(min: 40, ideal: 50, max: 72)
            .customizationID("endFrame")
            .defaultVisibility(.hidden)
        }
        .frame(minHeight: 640, idealHeight: 780, maxHeight: 1120)
        .contextMenu(forSelectionType: SubtitleCue.ID.self) { ids in
            cueListContextMenu(for: ids)
        }
    }

    @ViewBuilder
    private func cueListContextMenu(for ids: Set<SubtitleCue.ID>) -> some View {
        if ids.isEmpty {
            Text(t("cueList.emptySelection"))
        } else {
            let anchorID = anchorCueID(in: ids)

            if ids.count == 1, let onlyID = ids.first {
                Button {
                    jumpToCueInOutputTab(onlyID)
                } label: {
                    Label(t("cueList.jumpTo"), systemImage: "arrow.right.circle")
                }

                Divider()
            }

            Button {
                insertCueRelativeToAnchor(anchorID, position: .before)
            } label: {
                Label(t("editor.addBefore"), systemImage: "arrow.up.to.line.compact")
            }
            .disabled(anchorID == nil)

            Button {
                insertCueRelativeToAnchor(anchorID, position: .after)
            } label: {
                Label(t("editor.addAfter"), systemImage: "arrow.down.to.line.compact")
            }
            .disabled(anchorID == nil)

            Divider()

            Button {
                presentCueListTimingAdjustment(for: ids)
            } label: {
                Label(
                    ids.count > 1 ? "\(t("menu.adjustTiming")) (\(ids.count))" : t("menu.adjustTiming"),
                    systemImage: "clock.arrow.2.circlepath"
                )
            }

            Menu {
                ForEach(TranslationLanguageChoice.common) { choice in
                    Button(choice.localizedTitle) {
                        if let slot = activeSlot {
                            translateCues(in: slot.id, cueIDs: ids, to: choice)
                        }
                    }
                }
            } label: {
                Label(
                    ids.count > 1 ? "\(t("translation.translate")) (\(ids.count))" : t("translation.translate"),
                    systemImage: "character.bubble"
                )
            }

            Divider()

            Button(role: .destructive) {
                deleteCuesFromActiveCueList(ids)
            } label: {
                Label(
                    ids.count > 1 ? "\(t("cueList.delete")) (\(ids.count))" : t("cueList.delete"),
                    systemImage: "trash"
                )
            }
        }
    }

    private enum CueInsertPosition { case before, after }

    private func jumpToCueInOutputTab(_ cueID: SubtitleCue.ID) {
        guard files.indices.contains(activeIndex),
              files[activeIndex].cues.contains(where: { $0.id == cueID }) else { return }
        files[activeIndex].selectedCueID = cueID
        detailTab = .output
    }

    private func anchorCueID(in ids: Set<SubtitleCue.ID>) -> SubtitleCue.ID? {
        guard files.indices.contains(activeIndex) else { return nil }
        let cues = files[activeIndex].cues
        let firstIndex = cues.indices.first { ids.contains(cues[$0].id) }
        return firstIndex.map { cues[$0].id }
    }

    private func syncCueListSelectionFromActiveCue(_ cueID: SubtitleCue.ID?) {
        guard files.indices.contains(activeIndex) else {
            if !cueListSelection.isEmpty {
                cueListSelection = []
            }
            return
        }
        guard let cueID,
              files[activeIndex].cues.contains(where: { $0.id == cueID }) else {
            if !cueListSelection.isEmpty {
                cueListSelection = []
            }
            return
        }
        if cueListSelection.contains(cueID) {
            return
        }
        cueListSelection = [cueID]
    }

    private func syncActiveCueFromCueListSelection(_ selection: Set<SubtitleCue.ID>) {
        guard files.indices.contains(activeIndex) else {
            if !cueListSelection.isEmpty {
                cueListSelection = []
            }
            return
        }

        let validIDs = Set(files[activeIndex].cues.map(\.id))
        let cleanedSelection = selection.intersection(validIDs)
        if cleanedSelection != selection {
            cueListSelection = cleanedSelection
            return
        }

        guard let cueID = anchorCueID(in: cleanedSelection) else {
            if files[activeIndex].selectedCueID != nil {
                files[activeIndex].selectedCueID = nil
            }
            return
        }
        if files[activeIndex].selectedCueID != cueID {
            files[activeIndex].selectedCueID = cueID
        }
    }

    private func insertCueRelativeToAnchor(_ anchorID: SubtitleCue.ID?, position: CueInsertPosition) {
        guard files.indices.contains(activeIndex), let anchorID,
              let anchorIdx = files[activeIndex].cues.firstIndex(where: { $0.id == anchorID })
        else { return }
        let anchorCue = files[activeIndex].cues[anchorIdx]
        let defaultDuration = max(anchorCue.duration, 1.0)
        let newStart: Double
        let newEnd: Double
        let insertIdx: Int
        switch position {
        case .before:
            newStart = max(0, anchorCue.start - defaultDuration)
            newEnd = anchorCue.start
            insertIdx = anchorIdx
        case .after:
            newStart = anchorCue.end
            newEnd = anchorCue.end + defaultDuration
            insertIdx = anchorIdx + 1
        }
        let newCue = SubtitleCue(
            index: 0,
            start: newStart,
            end: newEnd,
            text: "",
            confidence: nil,
            speaker: anchorCue.speaker
        )
        files[activeIndex].cues.insert(newCue, at: insertIdx)
        for offset in files[activeIndex].cues.indices {
            files[activeIndex].cues[offset].index = offset + 1
        }
        files[activeIndex].selectedCueID = newCue.id
        cueListSelection = [newCue.id]
    }

    private func presentCueListTimingAdjustment(for ids: Set<SubtitleCue.ID>) {
        cueListTimingTargetIDs = ids
        cueListTimingMode = .shift
        cueListTimingShiftSeconds = 0
        cueListTimingGapSeconds = 0
        isCueListTimingAdjustmentPresented = true
    }

    private func applyCueListTimingAdjustment() {
        guard files.indices.contains(activeIndex), !cueListTimingTargetIDs.isEmpty else { return }
        switch cueListTimingMode {
        case .shift:
            shiftSelectedCues(by: cueListTimingShiftSeconds, ids: cueListTimingTargetIDs)
        case .closeGaps:
            closeGapsAmongSelectedCues(targetGap: cueListTimingGapSeconds, ids: cueListTimingTargetIDs)
        }
    }

    private func shiftSelectedCues(by seconds: Double, ids: Set<SubtitleCue.ID>) {
        guard seconds.isFinite, abs(seconds) > 0.0001, files.indices.contains(activeIndex) else { return }
        let targets = files[activeIndex].cues.filter { ids.contains($0.id) }
        let earliestStart = targets.map(\.start).min() ?? 0
        let safeOffset = max(seconds, -earliestStart)
        guard abs(safeOffset) > 0.0001 else { return }
        for offset in files[activeIndex].cues.indices where ids.contains(files[activeIndex].cues[offset].id) {
            files[activeIndex].cues[offset].start += safeOffset
            files[activeIndex].cues[offset].end += safeOffset
        }
    }

    private func closeGapsAmongSelectedCues(targetGap rawGap: Double, ids: Set<SubtitleCue.ID>) {
        guard files.indices.contains(activeIndex) else { return }
        let targetGap = max(0, rawGap.isFinite ? rawGap : 0)
        var previousEnd: Double?
        for offset in files[activeIndex].cues.indices where ids.contains(files[activeIndex].cues[offset].id) {
            let cueDuration = max(0.05, files[activeIndex].cues[offset].end - files[activeIndex].cues[offset].start)
            if let previousEnd {
                let desiredStart = previousEnd + targetGap
                if files[activeIndex].cues[offset].start > desiredStart {
                    files[activeIndex].cues[offset].start = desiredStart
                    files[activeIndex].cues[offset].end = desiredStart + cueDuration
                }
            }
            files[activeIndex].cues[offset].end = max(files[activeIndex].cues[offset].start + 0.05, files[activeIndex].cues[offset].end)
            previousEnd = files[activeIndex].cues[offset].end
        }
    }

    private func cueFrameNumber(_ seconds: Double, frameRate: Double) -> String {
        let rate = frameRate > 0 ? frameRate : 30.0
        return "\(Int((seconds * rate).rounded()))"
    }

    private func cueSpeechRate(_ cue: SubtitleCue) -> String {
        guard cue.duration > 0.05 else { return "-" }
        let chars = cue.text.trimmingCharacters(in: .whitespacesAndNewlines).count
        guard chars > 0 else { return "-" }
        let rate = Double(chars) / cue.duration
        return String(format: "%.1f", rate)
    }

    private func cueSpeakerBinding(for cueID: SubtitleCue.ID) -> Binding<String> {
        Binding {
            guard files.indices.contains(activeIndex),
                  let cue = files[activeIndex].cues.first(where: { $0.id == cueID }) else {
                return ""
            }
            return cue.speaker ?? ""
        } set: { newValue in
            guard files.indices.contains(activeIndex),
                  let idx = files[activeIndex].cues.firstIndex(where: { $0.id == cueID }) else { return }
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            files[activeIndex].cues[idx].speaker = trimmed.isEmpty ? nil : newValue
        }
    }

    private func cueTextDisplayBinding(for cueID: SubtitleCue.ID) -> Binding<String> {
        Binding {
            guard files.indices.contains(activeIndex),
                  let cue = files[activeIndex].cues.first(where: { $0.id == cueID }) else {
                return ""
            }
            return cue.text.replacingOccurrences(of: "\n", with: Self.cueListNewlineSentinel)
        } set: { newValue in
            guard files.indices.contains(activeIndex),
                  let idx = files[activeIndex].cues.firstIndex(where: { $0.id == cueID }) else { return }
            files[activeIndex].cues[idx].text = newValue.replacingOccurrences(of: Self.cueListNewlineSentinel, with: "\n")
        }
    }

    private func deleteCuesFromActiveCueList(_ ids: Set<SubtitleCue.ID>) {
        guard files.indices.contains(activeIndex) else { return }
        files[activeIndex].cues.removeAll { ids.contains($0.id) }
        for offset in files[activeIndex].cues.indices {
            files[activeIndex].cues[offset].index = offset + 1
        }
        cueListSelection.subtract(ids)
        if let selectedID = files[activeIndex].selectedCueID, ids.contains(selectedID) {
            files[activeIndex].selectedCueID = nil
        }
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

    private var presetSelectionBinding: Binding<String> {
        Binding {
            currentPresetTag() ?? Self.unsavedCustomPresetTag
        } set: { tag in
            applyPresetTag(tag)
        }
    }

    private var isUnsavedCustomPreset: Bool {
        currentPresetTag() == nil
    }

    private func builtInPresetTag(_ preset: RecognitionPreset) -> String {
        Self.builtInPresetTagPrefix + preset.rawValue
    }

    private func savedCustomPresetTag(_ id: UUID) -> String {
        Self.savedCustomPresetTagPrefix + id.uuidString
    }

    private func currentPresetTag() -> String? {
        let snapshot = settings.recognitionPresetSnapshot
        if let builtIn = RecognitionPreset.allCases.first(where: { settings.builtInPresetSnapshot($0) == snapshot }) {
            return builtInPresetTag(builtIn)
        }
        if let custom = settings.customPresets.first(where: { $0.snapshot == snapshot }) {
            return savedCustomPresetTag(custom.id)
        }
        return nil
    }

    private func applyPresetTag(_ tag: String) {
        guard tag != Self.unsavedCustomPresetTag else { return }
        if tag.hasPrefix(Self.builtInPresetTagPrefix) {
            let rawValue = String(tag.dropFirst(Self.builtInPresetTagPrefix.count))
            if let preset = RecognitionPreset(rawValue: rawValue) {
                settings.applyPreset(preset)
            }
            return
        }
        if tag.hasPrefix(Self.savedCustomPresetTagPrefix) {
            let rawValue = String(tag.dropFirst(Self.savedCustomPresetTagPrefix.count))
            if let id = UUID(uuidString: rawValue) {
                settings.applyCustomPreset(id: id)
            }
        }
    }

    private func currentPresetHelpText() -> String {
        guard let tag = currentPresetTag() else {
            return t("preset.custom.help")
        }
        if tag.hasPrefix(Self.builtInPresetTagPrefix) {
            let rawValue = String(tag.dropFirst(Self.builtInPresetTagPrefix.count))
            if let preset = RecognitionPreset(rawValue: rawValue) {
                return presetHelp(preset)
            }
        }
        return t("preset.custom.savedHelp")
    }

    private func asrEngineTitle(_ engine: ASREngine) -> String {
        t("settings.asrEngine.\(engine.rawValue)")
    }

    private func modelHelpText() -> String {
        t("help.model")
    }

    private func modelStatusText() -> String? {
        guard let info = settings.currentModelInfo else { return nil }
        let availability = info.localModelAvailable ? t("model.localAvailable") : t("model.localMissing")
        let supports = info.supports.map(supportTitle).joined(separator: t("list.separator"))
        return String(format: t("model.status"), info.title, availability, supports)
    }

    private func modelProfileStrip(for engine: ASREngine) -> some View {
        let profile = modelProfile(for: engine)
        let columns = [GridItem(.adaptive(minimum: 100), spacing: 6, alignment: .leading)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
            modelProfileChip(
                title: t("model.profile.speed"),
                value: profile.speed,
                systemImage: "bolt.fill",
                tint: .orange
            )
            modelProfileChip(
                title: t("model.profile.quality"),
                value: profile.quality,
                systemImage: "sparkles",
                tint: .blue
            )
            modelProfileChip(
                title: t("model.profile.scenario"),
                value: profile.scenario,
                systemImage: "scope",
                tint: .purple
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func modelProfileChip(title: String, value: String, systemImage: String, tint: Color) -> some View {
        Label {
            Text("\(title) \(value)")
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(tint.opacity(0.1), in: Capsule())
        .help("\(title) \(value)")
    }

    private func modelProfile(for engine: ASREngine) -> ASRModelProfile {
        switch engine {
        case .auto:
            return modelProfile(for: settings.effectiveASREngine == .auto ? .fireredasr2 : settings.effectiveASREngine)
        case .fireredasr2:
            return ASRModelProfile(
                speed: t("model.profile.speed.medium"),
                quality: t("model.profile.quality.high"),
                scenario: t("model.profile.scenario.fireredasr2")
            )
        case .sensevoice:
            return ASRModelProfile(
                speed: t("model.profile.speed.fast"),
                quality: t("model.profile.quality.good"),
                scenario: t("model.profile.scenario.sensevoice")
            )
        case .mimo:
            return ASRModelProfile(
                speed: t("model.profile.speed.slow"),
                quality: t("model.profile.quality.high"),
                scenario: t("model.profile.scenario.mimo")
            )
        case .mega:
            return ASRModelProfile(
                speed: t("model.profile.speed.slow"),
                quality: t("model.profile.quality.veryHigh"),
                scenario: t("model.profile.scenario.mega")
            )
        case .apple:
            return ASRModelProfile(
                speed: t("model.profile.speed.veryFast"),
                quality: t("model.profile.quality.good"),
                scenario: t("model.profile.scenario.apple")
            )
        }
    }

    private func modelStatusCard(_ info: ASRModelInfo) -> some View {
        let supports = info.supports.map(supportTitle)
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Label(info.title, systemImage: "cube")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                modelAvailabilityBadge(isAvailable: info.localModelAvailable)
            }

            compactStatusRow(
                title: t("model.selectedPath"),
                value: selectedModelPathDescription(for: info)
            )
            if !info.localModel.isEmpty {
                compactStatusRow(
                    title: t("model.localPath"),
                    value: info.localModel
                )
            }
            if !supports.isEmpty {
                Text("\(t("model.supportedControls")) \(supports.joined(separator: t("list.separator")))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
    }

    private func modelAvailabilityBadge(isAvailable: Bool) -> some View {
        Label(
            isAvailable ? t("model.localAvailable") : t("model.localMissing"),
            systemImage: isAvailable ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
        )
        .font(.caption2.weight(.medium))
        .foregroundStyle(isAvailable ? .green : .orange)
        .labelStyle(.titleAndIcon)
        .lineLimit(1)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background((isAvailable ? Color.green : Color.orange).opacity(0.12), in: Capsule())
    }

    private func compactStatusRow(title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption2.monospaced())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(value)
        }
    }

    private func selectedModelPathDescription(for info: ASRModelInfo) -> String {
        let trimmed = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return t("model.notRequired") }
        if trimmed == info.defaultModel {
            return "\(t("model.default")): \(trimmed)"
        }
        return trimmed
    }

    private func supportTitle(_ support: String) -> String {
        let key = "model.support.\(support)"
        let localized = t(key)
        if localized != key {
            return localized
        }
        return support.replacingOccurrences(of: "_", with: " ")
    }

    private func recognitionLanguageTitle(_ option: RecognitionLanguage) -> String {
        t("settings.recognitionLanguage.\(option.rawValue)")
    }

    private func vadEngineTitle(_ engine: VADEngine) -> String {
        t("settings.vadEngine.\(engine.rawValue)")
    }

    private func audioEventFilterTypeTitle(_ type: AudioEventFilterType) -> String {
        t("settings.audioEventFilterType.\(type.rawValue)")
    }

    private func audioEventFilterPresetTitle(_ preset: AudioEventFilterPreset) -> String {
        t("settings.audioEventPreset.\(preset.rawValue)")
    }

    private func speakerLabelingEngineTitle(_ engine: SpeakerLabelingEngine) -> String {
        t("settings.speakerLabelingEngine.\(engine.rawValue)")
    }

    private func speakerClusteringMethodTitle(_ method: SpeakerClusteringMethod) -> String {
        t("settings.speakerClusteringMethod.\(method.rawValue)")
    }

    private func vadEngineHelpText() -> String {
        let key = "help.vadEngine.\(settings.effectiveVADEngine.rawValue)"
        let localized = t(key)
        return localized == key ? t("help.vadEngine") : localized
    }

    private func vadStatusText() -> String? {
        guard settings.segmentMode == .vad else {
            return t("vad.status.fixed")
        }
        if settings.effectiveVADEngine == .firered,
           let info = settings.currentVADInfo,
           !info.localModelAvailable {
            return t("vad.status.fireredMissing")
        }
        if let info = settings.currentVADInfo {
            let availability = info.localModelAvailable ? t("model.localAvailable") : t("model.localMissing")
            return String(format: t("vad.status"), info.title, availability)
        }
        return nil
    }

    private func tabTitle(_ tab: DetailTab) -> String {
        switch tab {
        case .segments: t("tab.segments")
        case .output: t("tab.output")
        case .cueList: t("tab.cueList")
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
        let clampedValue = Binding<Int>(
            get: {
                min(max(value.wrappedValue, range.lowerBound), range.upperBound)
            },
            set: { newValue in
                value.wrappedValue = min(max(newValue, range.lowerBound), range.upperBound)
            }
        )
        return HStack(spacing: 6) {
            parameterLabel(title, help: help)
            Spacer(minLength: 4)
            TextField("", value: clampedValue, format: .number)
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .labelsHidden()
                .frame(width: 64)
                .contentTransition(.numericText())
                .animation(.smooth(duration: 0.18), value: value.wrappedValue)
            Stepper("", value: clampedValue, in: range)
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
            if isProcessing {
                cancelProcessing()
            } else {
                Task { await transcribeAll() }
            }
        } label: {
            Label(
                t(isProcessing ? "action.stop" : "action.transcribe"),
                systemImage: isProcessing ? "stop.circle" : "captions.bubble"
            )
                .labelStyle(.titleAndIcon)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .contentTransition(.symbolEffect(.replace))
        }
        .glassEffect(.regular.tint(isProcessing ? .red : .accentColor).interactive())
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(!isProcessing && !canRun)
        .help(t(isProcessing ? "action.stop" : "action.transcribe"))
        .accessibilityLabel(t(isProcessing ? "action.stop" : "action.transcribe"))
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

    // MARK: - Translation

    func presentTranslationSheet(forSlot slotID: FileSlot.ID, cueIDs: Set<SubtitleCue.ID> = []) {
        translationSheetSlotID = slotID
        translationSheetCueIDs = cueIDs
        isTranslationSheetPresented = true
    }

    func translateActiveSubtitle() {
        guard let slot = activeSlot, slot.hasEditableSubtitle else { return }
        presentTranslationSheet(forSlot: slot.id)
    }

    func translateCues(in slotID: FileSlot.ID, cueIDs: Set<SubtitleCue.ID>, to target: TranslationLanguageChoice, mode: TranslationOutputMode = .replace) {
        guard !cueIDs.isEmpty else { return }
        guard let targetLanguage = target.language else { return }
        translationTargetLanguage = target
        startTranslation(
            job: TranslationJob(
                scope: .cues(slotID: slotID, cueIDs: cueIDs, mode: mode),
                source: nil,
                target: targetLanguage
            )
        )
    }

    private func startTranslationFromSheet() {
        guard let slotID = translationSheetSlotID else { return }
        guard let targetLanguage = translationTargetLanguage.language else { return }
        let scope: TranslationJob.Scope
        if translationSheetCueIDs.isEmpty {
            scope = .wholeSlot(slotID: slotID, mode: translationMode)
        } else {
            scope = .cues(slotID: slotID, cueIDs: translationSheetCueIDs, mode: translationMode)
        }
        startTranslation(
            job: TranslationJob(
                scope: scope,
                source: translationSourceLanguage.language,
                target: targetLanguage
            )
        )
    }

    private func startTranslation(job: TranslationJob) {
        translationJob = job
        let newConfig = TranslationSession.Configuration(source: job.source, target: job.target)
        if translationConfiguration == newConfig {
            translationConfiguration?.invalidate()
        } else {
            translationConfiguration = newConfig
        }
    }

    @MainActor
    private func runTranslation(session: TranslationSession) async {
        guard let job = translationJob else { return }
        translationJob = nil
        isTranslating = true
        defer { isTranslating = false }
        do {
            switch job.scope {
            case .wholeSlot(let slotID, let mode):
                try await translateWholeSlot(slotID: slotID, mode: mode, session: session)
            case .cues(let slotID, let cueIDs, let mode):
                try await translateCues(slotID: slotID, cueIDs: cueIDs, mode: mode, session: session)
            }
        } catch {
            translationErrorMessage = error.localizedDescription
        }
    }

    private func translateWholeSlot(slotID: FileSlot.ID, mode: TranslationOutputMode, session: TranslationSession) async throws {
        guard let index = files.firstIndex(where: { $0.id == slotID }) else { return }
        let originals = files[index].cues.map(\.text)
        let translated = try await TranslationUtility.translateBatch(originals, using: session, contextual: true)
        guard files.indices.contains(index), files[index].id == slotID else { return }
        applyTranslation(originals: originals, translated: translated, to: index, mode: mode, restrictTo: nil)
    }

    private func translateCues(slotID: FileSlot.ID, cueIDs: Set<SubtitleCue.ID>, mode: TranslationOutputMode, session: TranslationSession) async throws {
        guard let index = files.firstIndex(where: { $0.id == slotID }) else { return }
        let allCues = files[index].cues
        let targetIndices = allCues.enumerated().compactMap { offset, cue in
            cueIDs.contains(cue.id) ? offset : nil
        }
        guard !targetIndices.isEmpty else { return }
        let originals = targetIndices.map { allCues[$0].text }
        let translated = try await TranslationUtility.translateBatch(originals, using: session)
        guard files.indices.contains(index), files[index].id == slotID else { return }
        applyTranslation(originals: originals, translated: translated, to: index, mode: mode, restrictTo: targetIndices)
    }

    private func applyTranslation(
        originals: [String],
        translated: [String],
        to fileIndex: Int,
        mode: TranslationOutputMode,
        restrictTo cueIndices: [Int]?
    ) {
        let slotID = files[fileIndex].id
        let beforeCues = files[fileIndex].cues
        update(at: fileIndex) { slot in
            if let cueIndices {
                for (offset, cueIndex) in cueIndices.enumerated() {
                    guard slot.cues.indices.contains(cueIndex), offset < translated.count else { continue }
                    slot.cues[cueIndex].text = TranslationUtility.combine(
                        original: originals[offset],
                        translated: translated[offset],
                        mode: mode
                    )
                }
            } else {
                for index in slot.cues.indices where index < translated.count {
                    slot.cues[index].text = TranslationUtility.combine(
                        original: originals[index],
                        translated: translated[index],
                        mode: mode
                    )
                }
            }
            slot.previewText = SubtitleDocument.serialize(slot.cues, format: slot.outputFormat)
        }
        registerTranslationUndoStep(slotID: slotID, cues: beforeCues)
    }

    private func configureTranslationUndo() {
        translationUndo.restoreHandler = { slotID, restoredCues in
            self.applyTranslationSnapshot(slotID: slotID, cues: restoredCues)
        }
    }

    private func applyTranslationSnapshot(slotID: UUID, cues: [SubtitleCue]) {
        guard let index = files.firstIndex(where: { $0.id == slotID }) else { return }
        let currentCues = files[index].cues
        update(at: index) { slot in
            slot.cues = cues
            slot.previewText = SubtitleDocument.serialize(cues, format: slot.outputFormat)
        }
        registerTranslationUndoStep(slotID: slotID, cues: currentCues)
    }

    private func registerTranslationUndoStep(slotID: UUID, cues: [SubtitleCue]) {
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: translationUndo) { coordinator in
            coordinator.restore(slotID: slotID, cues: cues)
        }
        undoManager.setActionName(t("undo.translate"))
    }

    // MARK: - Sandbox folder authorization

    private func authorizeSidecarFolderForActive() {
        let initialURL = activeSlot?.url
        let granted = FolderAuthorizationStore.shared.promptForFolderAuthorization(
            initialURL: initialURL,
            message: t("sandbox.authorizeFolder.message"),
            prompt: t("sandbox.authorizeFolder.prompt")
        )
        guard granted, let slot = activeSlot, !slot.hasEditableSubtitle else { return }
        importSidecarSubtitle(for: slot.url, slotID: slot.id)
    }

    private func addFiles(_ urls: [URL]) {
        var selectedIndex: Int?
        for url in urls {
            let normalized = url.standardizedFileURL
            // Under App Sandbox, access granted by Powerbox doesn't persist across
            // launches. If a stored security-scoped bookmark exists for this URL,
            // resolve it to re-establish read access for the rest of the session.
            let usableURL = FolderAuthorizationStore.shared.resolveFileForAccess(path: normalized.path) ?? normalized
            recentFiles.add(usableURL)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: usableURL.path)[.size] as? NSNumber)?.int64Value
            if let existingIndex = files.firstIndex(where: { $0.url.standardizedFileURL == usableURL.standardizedFileURL }) {
                selectedIndex = existingIndex
                if files[existingIndex].fileSizeBytes == nil {
                    files[existingIndex].fileSizeBytes = bytes
                }
                if files[existingIndex].mediaInfo == nil {
                    loadMediaInfo(for: usableURL, slotID: files[existingIndex].id)
                }
                if files[existingIndex].hasEditableSubtitle == false {
                    importSidecarSubtitle(for: usableURL, slotID: files[existingIndex].id)
                }
                continue
            }
            var slot = FileSlot(url: usableURL)
            slot.fileSizeBytes = bytes
            files.append(slot)
            selectedIndex = files.count - 1
            loadMediaInfo(for: usableURL, slotID: slot.id)
            importSidecarSubtitle(for: usableURL, slotID: slot.id)
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

    private func commitFileRename(for slotID: UUID) {
        guard let index = files.firstIndex(where: { $0.id == slotID }) else { return }
        let oldURL = files[index].url
        let originalName = oldURL.lastPathComponent
        var newName = (files[index].fileNameDraft ?? originalName)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !newName.isEmpty, !newName.contains("/"), !newName.contains("\0") else {
            files[index].fileNameDraft = originalName
            errorMessage = t("error.invalidFileName")
            return
        }

        if newName.contains(":") {
            newName = newName.replacingOccurrences(of: ":", with: "-")
        }
        if newName.first == "." {
            newName = "_" + String(newName.dropFirst())
        }
        if (newName as NSString).pathExtension.isEmpty, !oldURL.pathExtension.isEmpty {
            newName += ".\(oldURL.pathExtension)"
        }

        let newURL = oldURL.deletingLastPathComponent()
            .appendingPathComponent(newName)
            .standardizedFileURL
        guard newURL != oldURL.standardizedFileURL else {
            files[index].fileNameDraft = nil
            return
        }
        guard !FileManager.default.fileExists(atPath: newURL.path) else {
            files[index].fileNameDraft = originalName
            errorMessage = String(format: t("error.fileExists"), newURL.lastPathComponent)
            return
        }

        do {
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            recentFiles.replace(oldURL, with: newURL)
            files[index].url = newURL
            files[index].fileNameDraft = nil
            files[index].mediaInfo = nil
            files[index].statusKey = "status.renamed"
            files[index].statusDetail = newURL.lastPathComponent
            loadMediaInfo(for: newURL, slotID: slotID)
        } catch {
            files[index].fileNameDraft = originalName
            errorMessage = String(format: t("error.renameFailed"), error.localizedDescription)
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
        if let subtitleURL = sidecarSubtitleURL(for: mediaURL) {
            Task {
                await importSubtitle(from: subtitleURL, slotID: slotID, automatic: true)
            }
            return
        }
        maybePromptSidecarAuthorization(for: mediaURL)
    }

    private func maybePromptSidecarAuthorization(for mediaURL: URL) {
        let folderURL = mediaURL.deletingLastPathComponent()
        let store = FolderAuthorizationStore.shared
        guard !store.isFolderAuthorized(folderURL) else { return }
        guard !store.wasDeclined(folderPath: folderURL.standardizedFileURL.path) else { return }
        guard pendingSidecarAuthorizationURL == nil else { return }
        pendingSidecarAuthorizationURL = mediaURL
    }

    private var sidecarPromptBinding: Binding<Bool> {
        Binding(
            get: { pendingSidecarAuthorizationURL != nil },
            set: { if !$0 { pendingSidecarAuthorizationURL = nil } }
        )
    }

    @ViewBuilder
    private func sidecarPromptActions(for url: URL) -> some View {
        Button(t("sandbox.sidecarPrompt.authorize")) {
            handleSidecarAuthorizationAccept(for: url)
        }
        Button(t("sandbox.sidecarPrompt.skip"), role: .cancel) {
            handleSidecarAuthorizationDecline(for: url)
        }
    }

    private func sidecarPromptMessage(for url: URL) -> Text {
        let folderName = url.deletingLastPathComponent().lastPathComponent
        let template = t("sandbox.sidecarPrompt.message")
        return Text(String(format: template, folderName))
    }

    private func handleSidecarAuthorizationAccept(for url: URL) {
        let folderPath = url.deletingLastPathComponent().standardizedFileURL.path
        FolderAuthorizationStore.shared.clearDecline(folderPath: folderPath)
        pendingSidecarAuthorizationURL = nil
        let granted = FolderAuthorizationStore.shared.promptForFolderAuthorization(
            initialURL: url,
            message: t("sandbox.authorizeFolder.message"),
            prompt: t("sandbox.authorizeFolder.prompt")
        )
        guard granted, let slot = files.first(where: { $0.url == url }) else { return }
        importSidecarSubtitle(for: url, slotID: slot.id)
    }

    private func handleSidecarAuthorizationDecline(for url: URL) {
        let folderPath = url.deletingLastPathComponent().standardizedFileURL.path
        FolderAuthorizationStore.shared.recordDecline(folderPath: folderPath)
        pendingSidecarAuthorizationURL = nil
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

    private func chooseASRModelDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = t("action.chooseModelFolder")
        panel.message = t("model.chooseASR.message")
        if panel.runModal() == .OK, let url = panel.url {
            settings.model = url.path
            settings.modelPathDidChange()
        }
    }

    private func resetASRModelToDefault() {
        if settings.asrEngine == .auto, let info = settings.currentModelInfo {
            settings.model = info.defaultModel
        } else {
            settings.applyDefaultModelForSelectedEngine()
        }
        settings.modelPathDidChange()
    }

    private func chooseEmotionModelDirectory() {
        guard let modelURL = chooseAuxiliaryModelDirectory(
            expectedDirectoryName: "emotion2vec_plus_base",
            message: t("model.chooseEmotion.message")
        ) else {
            return
        }
        settings.emotionModel = modelURL.path
        settings.emotionModelAvailable = isNonEmptyDirectory(modelURL)
        backend.rememberEmotionModelDirectory(modelURL)
        restartBackendAfterAuxiliaryModelChange()
    }

    private func useRemoteEmotionModel() {
        settings.emotionModel = "emotion2vec/emotion2vec_plus_base"
        settings.emotionModelAvailable = false
        backend.useRemoteEmotionModelDownload()
        restartBackendAfterAuxiliaryModelChange()
    }

    private func chooseSpeakerRecognitionModelDirectory() {
        guard let modelURL = chooseAuxiliaryModelDirectory(
            expectedDirectoryName: "speech_eres2netv2_sv_zh-cn_16k-common",
            message: t("model.chooseSpeaker.message")
        ) else {
            return
        }
        settings.speakerRecognitionModel = modelURL.path
        settings.speakerRecognitionModelAvailable = isNonEmptyDirectory(modelURL)
        backend.rememberSpeakerRecognitionModelDirectory(modelURL)
        restartBackendAfterAuxiliaryModelChange()
    }

    private func useRemoteSpeakerRecognitionModel() {
        settings.speakerRecognitionModel = "iic/speech_eres2netv2_sv_zh-cn_16k-common"
        settings.speakerRecognitionModelAvailable = false
        backend.useRemoteSpeakerRecognitionModelDownload()
        restartBackendAfterAuxiliaryModelChange()
    }

    private func chooseAuxiliaryModelDirectory(
        expectedDirectoryName: String,
        message: String
    ) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = t("action.chooseModelFolder")

        guard panel.runModal() == .OK, let selectedURL = panel.url else {
            return nil
        }

        let selectedDirectory = selectedURL.standardizedFileURL
        FolderAuthorizationStore.shared.authorizeFolder(selectedDirectory)
        let direct = selectedDirectory
        let nested = selectedDirectory.appending(path: expectedDirectoryName)
        return isNonEmptyDirectory(nested) ? nested.standardizedFileURL : direct
    }

    private func restartBackendAfterAuxiliaryModelChange() {
        guard backend.isRunning else { return }
        backend.stop(waitForExit: true)
        connectionState = .disconnected
    }

    private func isNonEmptyDirectory(_ url: URL) -> Bool {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              let contents = try? FileManager.default.contentsOfDirectory(
                  at: url,
                  includingPropertiesForKeys: nil
              ) else {
            return false
        }
        return !contents.isEmpty
    }

    // MARK: - Sequential processing

    private func previewAll() async {
        guard hasFiles, !isProcessing else { return }
        isProcessing = true
        processingStartedAt = Date()
        guard await ensureBackendReady() else {
            if isProcessing {
                errorMessage = backend.message
                isProcessing = false
                processingStartedAt = nil
            }
            return
        }
        guard isProcessing else {
            return
        }
        let task = Task { @MainActor in
            defer {
                isProcessing = false
                isProcessingPaused = false
                processingStartedAt = nil
                processingTask = nil
            }
            for index in files.indices {
                if Task.isCancelled { break }
                await waitWhileProcessingPaused()
                if Task.isCancelled { break }
                await preview(at: index)
            }
        }
        processingTask = task
        await task.value
    }

    private func transcribeAll() async {
        guard hasFiles, !isProcessing else { return }
        isProcessing = true
        processingStartedAt = Date()
        if !settings.effectiveASREngine.isLocal {
            guard await ensureBackendReady() else {
                if isProcessing {
                    errorMessage = backend.message
                    isProcessing = false
                    processingStartedAt = nil
                }
                return
            }
        }
        guard isProcessing else {
            return
        }
        detailTab = .output
        let totalCount = files.count
        let language = self.language
        let task = Task { @MainActor in
            defer {
                isProcessing = false
                isProcessingPaused = false
                processingStartedAt = nil
                processingTask = nil
            }
            for index in files.indices {
                if Task.isCancelled { break }
                await waitWhileProcessingPaused()
                if Task.isCancelled { break }
                await transcribe(at: index)
            }
            if !Task.isCancelled {
                let failures = files.reduce(0) { acc, slot in
                    if case .failed = slot.processingState { return acc + 1 }
                    return acc
                }
                NotificationsService.postTranscriptionComplete(
                    language: language,
                    fileCount: totalCount,
                    failureCount: failures
                )
            }
        }
        processingTask = task
        await task.value
    }

    private func togglePauseProcessing() {
        guard isProcessing else { return }
        Task {
            if isProcessingPaused {
                await resumeProcessing()
            } else {
                await pauseProcessing()
            }
        }
    }

    private func pauseProcessing() async {
        guard isProcessing, !isPauseResumeRequestInFlight else { return }
        isPauseResumeRequestInFlight = true
        defer { isPauseResumeRequestInFlight = false }
        isProcessingPaused = true

        for index in files.indices {
            switch files[index].processingState {
            case .previewing, .transcribing:
                files[index].statusKey = "status.pausePending"
                if files[index].statusDetail.isEmpty {
                    files[index].statusDetail = files[index].url.lastPathComponent
                }
            default:
                break
            }
        }

        for jobID in files.compactMap(\.jobID) {
            do {
                try await api.pauseJob(id: jobID)
            } catch {
                AppLog.api.error("pauseJob failed for \(jobID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func resumeProcessing() async {
        guard isProcessing, !isPauseResumeRequestInFlight else { return }
        isPauseResumeRequestInFlight = true
        defer { isPauseResumeRequestInFlight = false }
        isProcessingPaused = false

        for jobID in files.compactMap(\.jobID) {
            do {
                try await api.resumeJob(id: jobID)
            } catch {
                AppLog.api.error("resumeJob failed for \(jobID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        for index in files.indices {
            if files[index].statusKey == "status.paused" || files[index].statusKey == "status.pausePending" {
                switch files[index].processingState {
                case .previewing:
                    files[index].statusKey = "status.detecting"
                case .transcribing:
                    files[index].statusKey = "status.transcribing"
                default:
                    break
                }
            }
        }
    }

    private func waitWhileProcessingPaused() async {
        var didMarkPaused = false
        while isProcessingPaused && !Task.isCancelled {
            if !didMarkPaused {
                for index in files.indices {
                    switch files[index].processingState {
                    case .previewing, .transcribing:
                        files[index].statusKey = "status.paused"
                        if files[index].statusDetail.isEmpty {
                            files[index].statusDetail = files[index].url.lastPathComponent
                        }
                    default:
                        break
                    }
                }
                didMarkPaused = true
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func cancelProcessing() {
        isProcessingPaused = false
        for slot in files {
            if let jobID = slot.jobID {
                Task {
                    do {
                        try await api.cancelJob(id: jobID)
                    } catch {
                        AppLog.api.error("cancelJob failed for \(jobID, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    }
                }
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
        processingStartedAt = nil
    }

    private func preparedMediaInput(for slot: FileSlot, clipRange: MediaClipRange?) async throws -> PreparedMediaInput {
        try await MediaClipExporter.prepare(
            source: slot.url,
            clipRange: clipRange,
            failureMessage: t("error.clipFailed")
        )
    }

    private func previewReuseKey(for slot: FileSlot, clipRange: MediaClipRange?) -> String {
        let fields = settings.formFields(includeOutput: false)
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "\u{1f}")
        let clip = clipRange.map { "\($0.start)-\($0.end)" } ?? "full"
        let attributes = try? FileManager.default.attributesOfItem(atPath: slot.url.path)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return [
            slot.url.standardizedFileURL.path,
            "\(modified)",
            clip,
            fields
        ].joined(separator: "\u{1e}")
    }

    private func reusablePreviewID(for slot: FileSlot, clipRange: MediaClipRange?) -> String? {
        guard !settings.effectiveASREngine.isLocal,
              let previewID = slot.previewID,
              slot.previewSettingsKey == previewReuseKey(for: slot, clipRange: clipRange) else {
            return nil
        }
        return previewID
    }

    private func preview(at index: Int) async {
        guard files.indices.contains(index) else { return }
        activeIndex = index
        let slot = files[index]
        let url = slot.url
        let clipRange = processingClipRange(for: slot)
        let reuseKey = previewReuseKey(for: slot, clipRange: clipRange)
        let displayDuration = timelineDuration(for: slot)
        update(at: index) {
            $0.processingState = .previewing
            $0.statusKey = clipRange == nil ? "status.detecting" : "status.clippingMedia"
            $0.statusDetail = clipRange.map { clipRangeSummary($0) } ?? url.lastPathComponent
            $0.progress = 0
            $0.chunkCurrent = 0
            $0.chunkTotal = 0
            $0.jobID = nil
            $0.failureMessage = nil
            $0.failureTrace = nil
            $0.failureLogText = nil
            $0.failureLogFilename = nil
            $0.failureJobID = nil
        }
        do {
            let preparedInput = try await preparedMediaInput(for: slot, clipRange: clipRange)
            defer { preparedInput.cleanup() }
            if clipRange != nil {
                update(at: index) {
                    $0.statusKey = "status.detecting"
                    $0.statusDetail = clipRange.map { clipRangeSummary($0) } ?? url.lastPathComponent
                }
            }
            update(at: index) {
                $0.progress = max($0.progress, 0.02)
                $0.statusKey = "status.detecting"
            }
            let created = try await api.createPreviewJob(fileURL: preparedInput.uploadURL, settings: settings)
            update(at: index) {
                $0.jobID = created.id
                $0.progress = max($0.progress, 0.02)
                $0.statusKey = "status.detecting"
            }
            try await pollPreview(
                jobID: created.id,
                fileIndex: index,
                timeOffset: preparedInput.timeOffset,
                reuseKey: reuseKey,
                displayDuration: displayDuration,
                clipRange: preparedInput.clipRange
            )
        } catch {
            if Task.isCancelled {
                update(at: index) {
                    $0.processingState = .cancelled
                    $0.statusKey = "status.cancelled"
                    $0.statusDetail = ""
                }
            } else {
                let existingDetails = files.indices.contains(index) ? failureDetails(for: files[index]) : nil
                let details = existingDetails ?? recordFailureDetails(
                    fileIndex: index,
                    jobID: files.indices.contains(index) ? files[index].jobID : nil,
                    message: error.localizedDescription,
                    trace: nil,
                    logText: nil,
                    logFilename: nil
                )
                update(at: index) {
                    $0.statusKey = "status.previewFailed"
                    $0.statusDetail = error.localizedDescription
                    $0.processingState = .failed
                    $0.progress = 0
                    $0.previewID = nil
                    $0.previewSettingsKey = nil
                }
                failureDetails = details
            }
        }
    }

    private func transcribe(at index: Int) async {
        guard files.indices.contains(index) else { return }
        activeIndex = index
        let slot = files[index]
        let url = slot.url
        let clipRange = processingClipRange(for: slot)
        let reusablePreviewID = reusablePreviewID(for: slot, clipRange: clipRange)
        let reusablePreviewTimeOffset = slot.previewTimeOffset
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
            $0.statusKey = clipRange == nil ? "status.starting" : "status.clippingMedia"
            $0.statusDetail = clipRange.map { clipRangeSummary($0) } ?? url.lastPathComponent
            $0.failureMessage = nil
            $0.failureTrace = nil
            $0.failureLogText = nil
            $0.failureLogFilename = nil
            $0.failureJobID = nil
        }
        do {
            if let reusablePreviewID, !settings.effectiveASREngine.isLocal {
                update(at: index) {
                    $0.statusKey = "status.starting"
                    $0.statusDetail = t("status.reusingPreview")
                }
                do {
                    let created = try await api.createJobFromPreview(previewID: reusablePreviewID, settings: settings)
                    update(at: index) { $0.jobID = created.id }
                    try await poll(jobID: created.id, fileIndex: index, timeOffset: reusablePreviewTimeOffset)
                    return
                } catch {
                    update(at: index) {
                        $0.previewID = nil
                        $0.previewSettingsKey = nil
                        $0.statusDetail = url.lastPathComponent
                    }
                }
            }
            let preparedInput = try await preparedMediaInput(for: slot, clipRange: clipRange)
            defer { preparedInput.cleanup() }
            if clipRange != nil {
                update(at: index) {
                    $0.statusKey = "status.starting"
                    $0.statusDetail = clipRange.map { clipRangeSummary($0) } ?? url.lastPathComponent
                }
            }
            if settings.effectiveASREngine.isLocal {
                try await transcribeWithAppleSpeech(
                    fileIndex: index,
                    audioURL: preparedInput.uploadURL,
                    timeOffset: preparedInput.timeOffset
                )
                return
            }
            let created = try await api.createJob(fileURL: preparedInput.uploadURL, settings: settings)
            update(at: index) { $0.jobID = created.id }
            try await poll(jobID: created.id, fileIndex: index, timeOffset: preparedInput.timeOffset)
        } catch {
            if Task.isCancelled {
                update(at: index) {
                    $0.processingState = .cancelled
                    $0.statusKey = "status.cancelled"
                    $0.statusDetail = ""
                }
            } else {
                let existingDetails = files.indices.contains(index) ? failureDetails(for: files[index]) : nil
                let details = existingDetails ?? recordFailureDetails(
                    fileIndex: index,
                    jobID: files.indices.contains(index) ? files[index].jobID : nil,
                    message: error.localizedDescription,
                    trace: nil,
                    logText: nil,
                    logFilename: nil
                )
                update(at: index) {
                    $0.processingState = .failed
                    $0.statusKey = "status.failed"
                    $0.statusDetail = error.localizedDescription
                }
                failureDetails = details
            }
        }
    }

    private func transcribeWithAppleSpeech(
        fileIndex: Int,
        audioURL: URL,
        timeOffset: Double
    ) async throws {
        let preferredLocale = appleSpeechLocale(for: settings.recognitionLanguage)
        update(at: fileIndex) {
            $0.statusKey = "status.transcribing"
            $0.statusDetail = ""
            $0.progress = 0
        }
        let cues = try await AppleSpeechService.transcribe(
            url: audioURL,
            locale: preferredLocale,
            timeOffset: timeOffset,
            fastResults: settings.appleSpeechFastResults,
            etiquetteFilter: settings.appleSpeechEtiquetteFilter
        ) { progress in
            Task { @MainActor in
                self.update(at: fileIndex) {
                    $0.progress = progress
                }
            }
        }
        if Task.isCancelled {
            update(at: fileIndex) {
                $0.processingState = .cancelled
                $0.statusKey = "status.cancelled"
                $0.statusDetail = ""
            }
            return
        }
        guard files.indices.contains(fileIndex) else { return }
        let format = files[fileIndex].outputFormat
        let serialized = SubtitleDocument.serialize(cues, format: format)
        installSubtitleText(serialized, at: fileIndex, format: format, parsedCues: cues, timeOffset: 0)
        update(at: fileIndex) {
            $0.progress = 1
            $0.statusKey = "status.done"
            $0.statusDetail = "\(cues.count) cues"
            $0.processingState = .done
        }
    }

    private func appleSpeechLocale(for language: RecognitionLanguage) -> Locale {
        switch language {
        case .auto, .nospeech: return Locale.current
        case .zh: return Locale(identifier: "zh-CN")
        case .en: return Locale(identifier: "en-US")
        case .yue: return Locale(identifier: "zh-HK")
        case .ja: return Locale(identifier: "ja-JP")
        case .ko: return Locale(identifier: "ko-KR")
        default: return Locale.current
        }
    }

    private func pollPreview(
        jobID: String,
        fileIndex: Int,
        timeOffset: Double,
        reuseKey: String,
        displayDuration: Double,
        clipRange: MediaClipRange?
    ) async throws {
        while !Task.isCancelled {
            let job = try await api.jobStatus(id: jobID)
            let total = max(job.total ?? 100, 1)
            let current = max(job.current ?? 0, 0)
            let progress = min(max(Double(current) / Double(total), 0), 0.99)
            let progressText = job.progressText ?? ""

            update(at: fileIndex) {
                $0.progress = progress
                $0.chunkCurrent = 0
                $0.chunkTotal = 0
                if job.status == "paused" {
                    $0.statusKey = "status.paused"
                    $0.statusDetail = progressText
                } else if job.pauseRequested == true {
                    $0.statusKey = "status.pausePending"
                    $0.statusDetail = progressText
                } else if job.status == "queued" || job.status == "waiting" {
                    $0.statusKey = "status.starting"
                    $0.statusDetail = progressText.isEmpty ? job.status : progressText
                } else {
                    $0.statusKey = progressText.localizedCaseInsensitiveContains("loading")
                        ? "status.loading"
                        : "status.detecting"
                    $0.statusDetail = progressText
                }
            }

            if job.status == "done" {
                guard let payloadSegments = job.segments else {
                    throw NSError(
                        domain: "MSub.Preview",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: t("status.previewFailed")]
                    )
                }
                let segments = shiftedSegments(payloadSegments, by: timeOffset)
                update(at: fileIndex) {
                    $0.duration = clipRange == nil
                        ? max($0.duration, job.duration ?? 0)
                        : max($0.duration, displayDuration, clipRange?.end ?? 0, segments.map(\.end).max() ?? 0)
                    if clipRange == nil {
                        $0.mediaInfo = job.mediaInfo ?? $0.mediaInfo
                    }
                    $0.segments = segments
                    $0.previewID = job.previewId ?? job.id
                    $0.previewSettingsKey = job.settingsKey ?? reuseKey
                    $0.previewTimeOffset = timeOffset
                    $0.statusKey = "status.previewReady"
                    $0.statusDetail = "\(job.count ?? segments.count) \(t("segments.count"))"
                    $0.processingState = .done
                    $0.progress = 1
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
                let message = job.error ?? t("status.previewFailed")
                let log = try? await api.fetchJobLog(jobID: jobID)
                let logText = log.flatMap { String(data: $0.data, encoding: .utf8) }
                let details = recordFailureDetails(
                    fileIndex: fileIndex,
                    jobID: jobID,
                    message: message,
                    trace: job.errorTrace,
                    logText: logText,
                    logFilename: log?.filename
                )
                failureDetails = details
                throw JobFailureError(message: message)
            }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    private func poll(jobID: String, fileIndex: Int, timeOffset: Double) async throws {
        while !Task.isCancelled {
            let job = try await api.jobStatus(id: jobID)
            let total = max(job.total ?? 0, 0)
            let current = max(job.current ?? 0, 0)
            let fractionalCurrent = min(max(job.fractionalCurrent ?? Double(current), 0), Double(max(total, 0)))
            let progress = total > 0 ? fractionalCurrent / Double(total) : 0

            update(at: fileIndex) {
                $0.progress = progress
                $0.chunkCurrent = current
                $0.chunkTotal = total
                if job.status == "paused" {
                    $0.statusKey = "status.paused"
                    $0.statusDetail = job.progressText ?? ""
                } else if job.pauseRequested == true {
                    $0.statusKey = "status.pausePending"
                    $0.statusDetail = job.progressText ?? ""
                } else if job.status == "running", total > 0 {
                    $0.statusKey = "status.transcribing"
                    $0.statusDetail = job.progressText ?? "\(current) / \(total)"
                } else if job.status == "running" {
                    let progressText = job.progressText ?? ""
                    $0.statusKey = progressText == "Loading model" ? "status.loading" : "status.transcribing"
                    $0.statusDetail = progressText
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
                var installedCueCount: Int?
                if files.indices.contains(fileIndex) {
                    let format = files[fileIndex].outputFormat
                    let downloadedText: String?
                    do {
                        let output = try await api.fetchOutput(jobID: jobID)
                        downloadedText = String(data: output.data, encoding: .utf8)
                    } catch {
                        downloadedText = nil
                    }
                    if let text = downloadedText ?? job.preview, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        installSubtitleText(text, at: fileIndex, format: format, timeOffset: timeOffset)
                        if files.indices.contains(fileIndex) {
                            installedCueCount = files[fileIndex].cues.count
                        }
                    }
                }
                update(at: fileIndex) {
                    $0.progress = 1
                    $0.statusKey = "status.done"
                    $0.statusDetail = "\(installedCueCount ?? job.cueCount ?? 0) cues"
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
                let message = job.error ?? t("error.jobFailed")
                let log = try? await api.fetchJobLog(jobID: jobID)
                let logText = log.flatMap { String(data: $0.data, encoding: .utf8) }
                let details = recordFailureDetails(
                    fileIndex: fileIndex,
                    jobID: jobID,
                    message: message,
                    trace: job.errorTrace,
                    logText: logText,
                    logFilename: log?.filename
                )
                failureDetails = details
                throw JobFailureError(message: message)
            }
            try await Task.sleep(for: .seconds(1))
        }
    }

    @discardableResult
    private func recordFailureDetails(
        fileIndex: Int,
        jobID: String?,
        message: String,
        trace: String?,
        logText: String?,
        logFilename: String?
    ) -> FailureDetails {
        let fileName = files.indices.contains(fileIndex) ? files[fileIndex].url.lastPathComponent : t("failure.unknownFile")
        let details = FailureDetails(
            fileName: fileName,
            jobID: jobID,
            message: message,
            trace: trace,
            logText: logText,
            logFilename: logFilename
        )
        update(at: fileIndex) {
            $0.failureMessage = message
            $0.failureTrace = trace
            $0.failureLogText = logText
            $0.failureLogFilename = details.defaultLogFilename
            $0.failureJobID = jobID
        }
        return details
    }

    private func failureDetails(for slot: FileSlot) -> FailureDetails? {
        guard let message = slot.failureMessage, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return FailureDetails(
            fileName: slot.url.lastPathComponent,
            jobID: slot.failureJobID,
            message: message,
            trace: slot.failureTrace,
            logText: slot.failureLogText,
            logFilename: slot.failureLogFilename
        )
    }

    private func exportFailureLog(_ details: FailureDetails) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = details.defaultLogFilename
        panel.message = t("failure.exportPrompt")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try details.exportText.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = String(format: t("error.exportLogFailed"), error.localizedDescription)
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

    private func installSubtitleText(
        _ text: String,
        at index: Int,
        format: OutputFormat,
        parsedCues: [SubtitleCue]? = nil,
        timeOffset: Double = 0
    ) {
        let parsed = parsedCues ?? SubtitleDocument.parse(text, format: format)
        let cues = offsetCues(parsed, by: timeOffset)
        let termsSource = cues.isEmpty ? text : cues.map(\.text).joined(separator: " ")
        let frequentTerms = SubtitleTextStats.topTerms(in: termsSource, limit: 8)
        let emotionFrequencies = SubtitleEmotionStats.frequencies(in: cues)
        update(at: index) {
            $0.outputFormat = format
            $0.previewText = cues.isEmpty ? text : SubtitleDocument.serialize(cues, format: format)
            $0.cues = cues
            $0.originalCues = cues
            $0.frequentTerms = frequentTerms
            $0.emotionFrequencies = emotionFrequencies
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

    private func offsetCues(_ cues: [SubtitleCue], by offset: Double) -> [SubtitleCue] {
        guard offset > 0, !cues.isEmpty else { return cues }
        return cues.map {
            var cue = $0
            cue.start += offset
            cue.end += offset
            return cue
        }
    }

    private func timeRange(_ segment: SubtitleSegment) -> String {
        "\(timeString(segment.start)) -> \(timeString(segment.end))"
    }

    private func timelineDuration(for slot: FileSlot?) -> Double {
        guard let slot else { return 0 }
        var candidates: [Double] = [slot.duration]
        if let duration = slot.mediaInfo?.duration {
            candidates.append(duration)
        }
        if let clipRange = slot.clipRange {
            candidates.append(clipRange.end)
        }
        if let segmentEnd = slot.segments.map(\.end).max() {
            candidates.append(segmentEnd)
        }
        if let cueEnd = slot.cues.map(\.end).max() {
            candidates.append(cueEnd)
        }
        return candidates
            .filter { $0.isFinite && $0 > 0 }
            .max() ?? 0
    }

    private func normalizedClipRange(for slot: FileSlot) -> MediaClipRange? {
        slot.clipRange?.normalized(in: timelineDuration(for: slot))
    }

    private func processingClipRange(for slot: FileSlot) -> MediaClipRange? {
        let duration = timelineDuration(for: slot)
        guard let range = slot.clipRange?.normalized(in: duration),
              !range.coversFullDuration(duration: duration) else {
            return nil
        }
        return range
    }

    private func clearClipRangeForActiveSlot() {
        guard files.indices.contains(activeIndex) else { return }
        files[activeIndex].clipRange = nil
    }

    private func clipActiveVideoToSelectedRange() async {
        guard !isClippingVideo,
              files.indices.contains(activeIndex) else { return }
        let index = activeIndex
        let slot = files[index]
        guard isVideoSlot(slot),
              let range = processingClipRange(for: slot) else { return }

        guard FFmpegRunner.isAvailable else {
            errorMessage = t("error.ffmpegUnavailable")
            return
        }

        let destination = clippedMediaDestination(for: slot.url, range: range)
        isClippingVideo = true
        update(at: index) {
            $0.statusKey = "status.videoClipping"
            $0.statusDetail = clipRangeSummary(range)
            $0.progress = 0
        }
        defer { isClippingVideo = false }

        guard let clippedURL = await FFmpegRunner.clipMedia(
            from: slot.url,
            to: destination,
            start: range.start,
            duration: range.duration
        ) else {
            guard let refreshedIndex = files.firstIndex(where: { $0.id == slot.id }) else { return }
            update(at: refreshedIndex) {
                $0.statusKey = "status.failed"
                $0.statusDetail = t("error.videoClipFailed")
                $0.progress = 0
            }
            errorMessage = t("error.videoClipFailed")
            return
        }

        guard let refreshedIndex = files.firstIndex(where: { $0.id == slot.id }) else { return }
        let updatedSegments = clippedSegments(from: slot.segments, keeping: range)
        let updatedCues = clippedCues(from: slot.cues, keeping: range)
        let updatedOriginalCues = clippedCues(from: slot.originalCues, keeping: range)
        recentFiles.add(clippedURL)
        update(at: refreshedIndex) {
            $0.url = clippedURL.standardizedFileURL
            $0.fileNameDraft = nil
            $0.clipRange = nil
            $0.segments = updatedSegments
            $0.cues = updatedCues
            $0.originalCues = updatedOriginalCues
            $0.previewText = updatedCues.isEmpty ? "" : SubtitleDocument.serialize(updatedCues, format: $0.outputFormat)
            $0.selectedCueID = updatedCues.first?.id
            $0.mediaInfo = nil
            $0.duration = range.duration
            $0.statusKey = "status.videoClipped"
            $0.statusDetail = clippedURL.lastPathComponent
            $0.progress = 1
            $0.processingState = .done
        }
        loadMediaInfo(for: clippedURL, slotID: slot.id)
    }

    private func clipRangeSummary(_ range: MediaClipRange?) -> String {
        guard let range else { return t("segments.keepRange.none") }
        return String(
            format: t("segments.keepRange.value"),
            SubtitleDocument.displayTime(range.start),
            SubtitleDocument.displayTime(range.end)
        )
    }

    private func clippedMediaDestination(for source: URL, range: MediaClipRange) -> URL {
        let directory = source.deletingLastPathComponent()
        let stem = source.deletingPathExtension().lastPathComponent
        let safeStem = stem.isEmpty ? "clip" : stem
        let suffix = "clip_\(fileTimeToken(range.start))-\(fileTimeToken(range.end))"
        let candidate = directory
            .appendingPathComponent("\(safeStem)_\(suffix)")
            .appendingPathExtension("mp4")
        return uniqueFileURL(candidate)
    }

    private func uniqueFileURL(_ candidate: URL) -> URL {
        let directory = candidate.deletingLastPathComponent()
        let stem = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var url = candidate
        var counter = 2
        while FileManager.default.fileExists(atPath: url.path) {
            let name = "\(stem)-\(counter)"
            url = directory.appendingPathComponent(name)
            if !ext.isEmpty {
                url = url.appendingPathExtension(ext)
            }
            counter += 1
        }
        return url
    }

    private func fileTimeToken(_ seconds: Double) -> String {
        let safe = max(0, seconds)
        let whole = Int(safe)
        let centiseconds = Int(((safe - Double(whole)) * 100).rounded())
        let hours = whole / 3600
        let minutes = (whole % 3600) / 60
        let secs = whole % 60
        return String(format: "%02d%02d%02d%02d", hours, minutes, secs, min(centiseconds, 99))
    }

    private func clippedSegments(from segments: [SubtitleSegment], keeping range: MediaClipRange) -> [SubtitleSegment] {
        let clipped: [SubtitleSegment] = segments.compactMap { segment -> SubtitleSegment? in
            let start = max(segment.start, range.start)
            let end = min(segment.end, range.end)
            guard end - start > 0.05 else { return nil }
            return SubtitleSegment(
                index: 0,
                start: start - range.start,
                end: end - range.start,
                duration: end - start,
                audioLabel: segment.audioLabel,
                audioScore: segment.audioScore,
                speechScore: segment.speechScore,
                repetitionScore: segment.repetitionScore,
                flagged: segment.flagged
            )
        }
        return clipped
        .enumerated()
        .map { offset, segment in
            segment.reindexed(offset + 1)
        }
    }

    private func clippedCues(from cues: [SubtitleCue], keeping range: MediaClipRange) -> [SubtitleCue] {
        let clipped = cues.compactMap { cue -> SubtitleCue? in
            let start = max(cue.start, range.start)
            let end = min(cue.end, range.end)
            guard end - start > 0.05 else { return nil }
            var copy = cue
            copy.start = start - range.start
            copy.end = end - range.start
            return copy
        }
        return SubtitleDocument.normalize(clipped)
    }

    private func shiftedSegments(_ segments: [SubtitleSegment], by offset: Double) -> [SubtitleSegment] {
        guard offset > 0 else { return segments }
        return segments.map {
            SubtitleSegment(
                index: $0.index,
                start: $0.start + offset,
                end: $0.end + offset,
                duration: $0.duration,
                audioLabel: $0.audioLabel,
                audioScore: $0.audioScore,
                speechScore: $0.speechScore,
                repetitionScore: $0.repetitionScore,
                flagged: $0.flagged
            )
        }
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

private struct SaveCustomPresetSheet: View {
    let language: AppLanguage
    @Binding var name: String
    var onCancel: () -> Void
    var onSave: () -> Void

    @FocusState private var isNameFocused: Bool

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("preset.saveTitle"))
                .font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                Text(t("preset.name"))
                    .font(.callout.weight(.medium))
                TextField(t("preset.namePlaceholder"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .focused($isNameFocused)
            }

            HStack {
                Spacer()
                Button(t("button.cancel")) {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button(t("button.save")) {
                    name = trimmedName
                    onSave()
                }
                .disabled(trimmedName.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            isNameFocused = true
        }
    }

    private func t(_ key: String) -> String {
        Copy.text(key, language: language)
    }
}

private struct FailureDetailsSheet: View {
    let language: AppLanguage
    let details: FailureDetails
    var onCopy: () -> Void
    var onExport: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 4) {
                    Text(t("failure.title"))
                        .font(.headline)
                    Text(details.fileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(t("failure.message"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(details.message)
                    .font(.callout)
                    .textSelection(.enabled)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let trace = details.trace, !trace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        failureTextBlock(title: t("failure.trace"), text: trace)
                    }
                    if let logText = details.logText, !logText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        failureTextBlock(title: t("failure.log"), text: logText)
                    } else {
                        Text(t("failure.noLog"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 220, maxHeight: 360)

            HStack {
                Button {
                    onCopy()
                } label: {
                    Label(t("failure.copyDetails"), systemImage: "doc.on.doc")
                }

                Button {
                    onExport()
                } label: {
                    Label(t("failure.exportLog"), systemImage: "square.and.arrow.down")
                }

                Spacer()

                Button(t("button.close")) {
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 640)
    }

    private func failureTextBlock(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
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
    let nameMaxWidth: CGFloat
    let removeHelp: String
    let statusHelp: String
    let showInFinderLabel: String
    let openWithDefaultLabel: String
    let onSelect: () -> Void
    let onRemove: () -> Void
    let onReorder: (UUID) -> Void

    @State private var isHovering = false
    @State private var isDropTarget = false

    private var isActivelyProcessing: Bool {
        slot.processingState == .transcribing || slot.processingState == .previewing
    }

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Image(systemName: iconName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(iconColor)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.variableColor.iterative, isActive: isActivelyProcessing)
                    .opacity(isHovering ? 0 : 1)
                    .scaleEffect(isHovering ? 0.6 : 1)
                Button {
                    onRemove()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(removeHelp)
                .accessibilityLabel(removeHelp)
                .opacity(isHovering ? 1 : 0)
                .scaleEffect(isHovering ? 1 : 0.6)
                .allowsHitTesting(isHovering)
            }
            .frame(width: 14, height: 14)

            Text(slot.url.lastPathComponent)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .fixedSize(horizontal: isHovering, vertical: false)
                .frame(maxWidth: isHovering ? nil : nameMaxWidth, alignment: .leading)

            if isActivelyProcessing {
                ProgressView()
                    .controlSize(.mini)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .frame(minHeight: 16)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            isActive ? AnyShapeStyle(Color.teal.opacity(0.16)) : AnyShapeStyle(.quinary),
            in: Capsule()
        )
        .overlay(
            Capsule().stroke(
                isDropTarget ? Color.teal.opacity(0.7) : (isActive ? Color.teal : Color.clear),
                lineWidth: isDropTarget ? 1.6 : 1.2
            )
        )
        .scaleEffect(isDropTarget ? 1.04 : 1)
        .geometryGroup()
        .animation(.easeInOut(duration: 0.18), value: isDropTarget)
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: nameMaxWidth)
        .contentShape(Capsule())
        .onTapGesture {
            onSelect()
        }
        .onHover { hovering in
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                isHovering = hovering
            }
        }
        .help(statusHelp)
        .contextMenu {
            Button(showInFinderLabel) {
                NSWorkspace.shared.activateFileViewerSelecting([slot.url])
            }
            Button(openWithDefaultLabel) {
                NSWorkspace.shared.open(slot.url)
            }
            Divider()
            Button(role: .destructive) {
                onRemove()
            } label: {
                Text(removeHelp)
            }
        }
        .onDrag {
            let provider = NSItemProvider()
            let payload = fileChipDragPrefix + slot.id.uuidString
            let data = Data(payload.utf8)
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.utf8PlainText.identifier,
                visibility: .ownProcess
            ) { completion in
                completion(data, nil)
                return nil
            }
            return provider
        } preview: {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(iconColor)
                Text(slot.url.lastPathComponent)
                    .font(.caption)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
        }
        .onDrop(of: [UTType.utf8PlainText], delegate: FileChipDropDelegate(
            targetID: slot.id,
            onReorder: onReorder,
            isDropTarget: $isDropTarget
        ))
    }
}

private let fileChipDragPrefix = "msub-chip:"

private struct FileChipDropDelegate: DropDelegate {
    let targetID: UUID
    let onReorder: (UUID) -> Void
    @Binding var isDropTarget: Bool

    private static let acceptedTypes: [UTType] = [.utf8PlainText]

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: Self.acceptedTypes)
    }

    func dropEntered(info: DropInfo) {
        isDropTarget = true
    }

    func dropExited(info: DropInfo) {
        isDropTarget = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        isDropTarget = false
        let providers = info.itemProviders(for: Self.acceptedTypes)
        guard let provider = providers.first else { return false }
        let targetID = self.targetID
        let reorder = UncheckedSendableBox(value: onReorder)
        _ = provider.loadDataRepresentation(
            forTypeIdentifier: UTType.utf8PlainText.identifier
        ) { data, _ in
            guard let data,
                  let raw = String(data: data, encoding: .utf8),
                  raw.hasPrefix(fileChipDragPrefix),
                  let draggedID = UUID(uuidString: String(raw.dropFirst(fileChipDragPrefix.count))),
                  draggedID != targetID else {
                return
            }
            Task { @MainActor in
                reorder.value(draggedID)
            }
        }
        return true
    }
}

private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
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

struct MediaClipRange: Equatable {
    var start: Double
    var end: Double

    var duration: Double {
        max(0, end - start)
    }

    func normalized(in duration: Double, minimumDuration: Double = 0.25) -> MediaClipRange? {
        guard duration.isFinite, duration > 0 else { return nil }
        var lower = min(start, end)
        var upper = max(start, end)
        lower = min(max(0, lower), duration)
        upper = min(max(0, upper), duration)

        if upper - lower < minimumDuration {
            let midpoint = min(max((lower + upper) / 2, 0), duration)
            lower = max(0, midpoint - minimumDuration / 2)
            upper = min(duration, lower + minimumDuration)
            lower = max(0, upper - minimumDuration)
        }

        guard upper > lower else { return nil }
        return MediaClipRange(start: lower, end: upper)
    }

    func coversFullDuration(duration: Double) -> Bool {
        guard duration.isFinite, duration > 0 else { return false }
        return start <= 0.05 && end >= duration - 0.05
    }
}

private struct PreparedMediaInput {
    let uploadURL: URL
    let clipRange: MediaClipRange?
    let timeOffset: Double
    let cleanupURL: URL?

    func cleanup() {
        if let cleanupURL {
            try? FileManager.default.removeItem(at: cleanupURL)
        }
    }
}

private enum MediaClipExporter {
    static func prepare(
        source: URL,
        clipRange: MediaClipRange?,
        failureMessage: String
    ) async throws -> PreparedMediaInput {
        guard let clipRange else {
            return PreparedMediaInput(uploadURL: source, clipRange: nil, timeOffset: 0, cleanupURL: nil)
        }

        let dest = temporaryDestination(for: source)
        if let result = await exportViaAVFoundation(
            source: source,
            dest: dest,
            startSeconds: clipRange.start,
            durationSeconds: clipRange.duration
        ) {
            return PreparedMediaInput(uploadURL: result, clipRange: clipRange, timeOffset: clipRange.start, cleanupURL: result)
        }

        if let result = await FFmpegRunner.extractAudio(
            from: source,
            to: dest,
            start: clipRange.start,
            duration: clipRange.duration
        ) {
            return PreparedMediaInput(uploadURL: result, clipRange: clipRange, timeOffset: clipRange.start, cleanupURL: result)
        }

        let resolvedAudio = await AudioSource.resolve(source)
        if resolvedAudio.standardizedFileURL != source.standardizedFileURL,
           let result = await exportViaAVFoundation(
            source: resolvedAudio,
            dest: dest,
            startSeconds: clipRange.start,
            durationSeconds: clipRange.duration
           ) {
            return PreparedMediaInput(uploadURL: result, clipRange: clipRange, timeOffset: clipRange.start, cleanupURL: result)
        }

        try? FileManager.default.removeItem(at: dest)
        throw NSError(domain: "MSub.MediaClip", code: 1, userInfo: [NSLocalizedDescriptionKey: failureMessage])
    }

    private static func temporaryDestination(for source: URL) -> URL {
        let base: URL
        if let cachesDir = try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            base = cachesDir
        } else {
            base = FileManager.default.temporaryDirectory
        }
        let dir = base.appendingPathComponent("MSub-selected-ranges", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stem = source.deletingPathExtension().lastPathComponent
        let safeStem = stem.isEmpty ? "clip" : stem
        return dir.appendingPathComponent("\(safeStem)-\(UUID().uuidString)").appendingPathExtension("m4a")
    }

    private static func exportViaAVFoundation(
        source: URL,
        dest: URL,
        startSeconds: Double,
        durationSeconds: Double
    ) async -> URL? {
        let asset = AVURLAsset(url: source)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio),
              !tracks.isEmpty,
              let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            return nil
        }

        try? FileManager.default.removeItem(at: dest)
        exportSession.timeRange = CMTimeRange(
            start: CMTime(seconds: max(0, startSeconds), preferredTimescale: 600),
            duration: CMTime(seconds: max(0.05, durationSeconds), preferredTimescale: 600)
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
}

struct FileSlot: Identifiable {
    let id = UUID()
    var url: URL
    var fileNameDraft: String?
    var clipRange: MediaClipRange?
    var segments: [SubtitleSegment] = []
    var cues: [SubtitleCue] = []
    var originalCues: [SubtitleCue] = []
    var speakerColors: [String: String] = [:]
    var frequentTerms: [SubtitleTermFrequency] = []
    var emotionFrequencies: [SubtitleEmotionFrequency] = []
    var selectedCueID: SubtitleCue.ID?
    var mediaInfo: MediaInfo?
    var duration: Double = 0
    var previewID: String?
    var previewSettingsKey: String?
    var previewTimeOffset: Double = 0
    var previewText: String = ""
    var jobID: String?
    var lastOutputPath: String?
    var outputFormat: OutputFormat = .srt
    var progress: Double = 0
    var chunkCurrent: Int = 0
    var chunkTotal: Int = 0
    var statusKey: String = "status.ready"
    var statusDetail: String = ""
    var failureMessage: String?
    var failureTrace: String?
    var failureLogText: String?
    var failureLogFilename: String?
    var failureJobID: String?
    var processingState: ProcessingState = .idle
    var fileSizeBytes: Int64?

    enum ProcessingState: Equatable {
        case idle
        case previewing
        case transcribing
        case done
        case failed
        case cancelled
    }
}

private struct FailureDetails: Identifiable {
    let id = UUID()
    var fileName: String
    var jobID: String?
    var message: String
    var trace: String?
    var logText: String?
    var logFilename: String?

    var defaultLogFilename: String {
        if let logFilename, !logFilename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return logFilename
        }
        let stem = fileName.isEmpty
            ? "MSub"
            : URL(fileURLWithPath: fileName).deletingPathExtension().lastPathComponent
        return "\(stem)-MSub-failure.log"
    }

    var exportText: String {
        var parts = [
            "MSub failure report",
            "File: \(fileName)",
            "Job: \(jobID ?? "-")",
            "",
            "Message:",
            message
        ]
        if let trace, !trace.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts += ["", "Trace:", trace]
        }
        if let logText, !logText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts += ["", "Job log:", logText]
        }
        return parts.joined(separator: "\n")
    }
}

private struct JobFailureError: LocalizedError {
    var message: String

    var errorDescription: String? {
        message
    }
}

private enum DetailTab: String, CaseIterable, Identifiable {
    case segments
    case output
    case cueList

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

private func localizedPercentageText(_ ratio: Double, language: AppLanguage) -> String {
    let clamped = min(max(ratio, 0), 1)
    return clamped.formatted(
        .percent
            .precision(.fractionLength(0))
            .locale(language.locale)
    )
}

private struct SegmentStatsView: View {
    let stats: SegmentStats
    let language: AppLanguage

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
            GridRow {
                stat(Copy.text("segments.avg", language: language), String(format: "%.2fs", stats.averageDuration))
                stat(Copy.text("segments.max", language: language), String(format: "%.2fs", stats.maxDuration))
                stat(Copy.text("segments.speech", language: language), localizedPercentageText(stats.speechRatio, language: language))
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

struct TimelineHighlightRange: Hashable {
    let start: Double
    let end: Double
}

struct PlaybackTimelineView: View {
    let segments: [SubtitleSegment]
    let duration: Double
    @Binding var clipRange: MediaClipRange?
    let language: AppLanguage
    let isEnabled: Bool
    let playback: PlaybackController
    var allowsClipSelection: Bool = false
    var onSeek: ((Double) -> Void)? = nil
    var highlightedRanges: [TimelineHighlightRange] = []

    var body: some View {
        TimelineView(
            segments: segments,
            duration: duration,
            clipRange: $clipRange,
            language: language,
            isEnabled: isEnabled,
            currentTime: playback.currentTime,
            allowsClipSelection: allowsClipSelection,
            onSeek: onSeek,
            highlightedRanges: highlightedRanges
        )
    }
}

struct TimelineView: View {
    let segments: [SubtitleSegment]
    let duration: Double
    @Binding var clipRange: MediaClipRange?
    let language: AppLanguage
    let isEnabled: Bool
    var currentTime: Double? = nil
    var allowsClipSelection: Bool = true
    var onSeek: ((Double) -> Void)? = nil
    var highlightedRanges: [TimelineHighlightRange] = []

    @State private var selectionAnchorTime: Double?
    @State private var handleDragBase: MediaClipRange?

    private let minimumClipDuration = 0.25

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let height = max(proxy.size.height, 1)
            if allowsClipSelection {
                clipSelectionBody(width: width, height: height)
            } else {
                seekBody(width: width, height: height)
            }
        }
    }

    private func clipSelectionBody(width: CGFloat, height: CGFloat) -> some View {
        let selectedRange = clipRange?.normalized(in: duration, minimumDuration: minimumClipDuration)
        return timelineLayer(width: width, height: height, selectedRange: selectedRange)
            .gesture(selectionGesture(width: width))
            .allowsHitTesting(isEnabled && duration > 0)
            .accessibilityLabel(Text(Copy.text("segments.keepRange", language: language)))
    }

    private func seekBody(width: CGFloat, height: CGFloat) -> some View {
        timelineLayer(width: width, height: height, selectedRange: nil)
            .gesture(seekGesture(width: width))
            .allowsHitTesting(isEnabled && duration > 0)
    }

    private func timelineLayer(width: CGFloat, height: CGFloat, selectedRange: MediaClipRange?) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 6)
                .fill(.quinary)

            if let selectedRange {
                selectionOverlay(selectedRange, width: width, height: height)
            }

            ForEach(segments) { segment in
                let startX = xPosition(segment.start, width: width)
                let endX = xPosition(segment.end, width: width)
                let barHeight = min(30, max(20, height - 22))
                RoundedRectangle(cornerRadius: 2)
                    .fill(.teal.opacity(segmentOpacity(segment, selectedRange: selectedRange)))
                    .frame(
                        width: max(2, endX - startX),
                        height: barHeight
                    )
                    .offset(x: startX, y: (height - barHeight) / 2)
            }

            ForEach(highlightedRanges, id: \.self) { range in
                let startX = xPosition(range.start, width: width)
                let endX = xPosition(range.end, width: width)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.accentColor.opacity(0.32))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.accentColor.opacity(0.85), lineWidth: 1)
                    )
                    .frame(width: max(2, endX - startX), height: height)
                    .offset(x: startX)
            }

            if let selectedRange {
                clipHandle(edge: .start, range: selectedRange, width: width, height: height)
                clipHandle(edge: .end, range: selectedRange, width: width, height: height)
            }

            if let currentTime, duration > 0, currentTime >= 0, currentTime <= duration {
                playbackCursor(currentTime: currentTime, width: width, height: height)
            }
        }
        .contentShape(Rectangle())
    }

    private func seekGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard isEnabled, duration > 0, let onSeek else { return }
                let seekTime = time(for: value.location.x, width: width)
                onSeek(seekTime)
            }
    }

    private func playbackCursor(currentTime: Double, width: CGFloat, height: CGFloat) -> some View {
        let x = xPosition(currentTime, width: width)
        return ZStack(alignment: .top) {
            Capsule()
                .fill(Color.accentColor)
                .frame(width: 2, height: height)
                .offset(x: max(-1, min(width - 1, x - 1)))
            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)
                .offset(x: max(-3, min(width - 3, x - 3)), y: -2)
        }
        .allowsHitTesting(false)
    }

    private func selectionOverlay(_ range: MediaClipRange, width: CGFloat, height: CGFloat) -> some View {
        let startX = xPosition(range.start, width: width)
        let endX = xPosition(range.end, width: width)
        let selectionWidth = max(2, endX - startX)
        return ZStack(alignment: .leading) {
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.55)
                .frame(width: max(0, startX), height: height)
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(0.55)
                .frame(width: max(0, width - endX), height: height)
                .offset(x: endX)
            RoundedRectangle(cornerRadius: 6)
                .fill(
                    LinearGradient(
                        colors: [.teal.opacity(0.20), .teal.opacity(0.10)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: selectionWidth, height: height)
                .offset(x: startX)
            RoundedRectangle(cornerRadius: 6)
                .stroke(.teal.opacity(0.9), lineWidth: 1.5)
                .shadow(color: .teal.opacity(0.35), radius: 3)
                .frame(width: selectionWidth, height: max(0, height - 1))
                .offset(x: startX)
        }
    }

    private func clipHandle(edge: ClipHandleEdge, range: MediaClipRange, width: CGFloat, height: CGFloat) -> some View {
        let handleWidth: CGFloat = 10
        let handleHeight = max(34, height - 12)
        let rawX = xPosition(edge == .start ? range.start : range.end, width: width) - handleWidth / 2
        let clampedX = min(max(0, rawX), max(0, width - handleWidth))
        let isDragging = handleDragBase != nil
        return Capsule()
            .fill(.white.opacity(0.96))
            .overlay(Capsule().stroke(.teal.opacity(0.95), lineWidth: 1.2))
            .overlay(
                VStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { _ in
                        Capsule()
                            .fill(.teal.opacity(0.55))
                            .frame(width: 3, height: 1.5)
                    }
                }
            )
            .frame(width: handleWidth, height: handleHeight)
            .shadow(color: .black.opacity(isDragging ? 0.22 : 0.14), radius: isDragging ? 4 : 2, x: 0, y: 1)
            .scaleEffect(isDragging ? 1.08 : 1)
            .animation(.easeOut(duration: 0.15), value: isDragging)
            .offset(x: clampedX, y: (height - handleHeight) / 2)
            .gesture(handleGesture(edge: edge, width: width))
            .accessibilityLabel(Text(Copy.text("segments.keepRange", language: language)))
    }

    private func selectionGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                guard isEnabled, duration > 0 else { return }
                let anchor = selectionAnchorTime ?? time(for: value.startLocation.x, width: width)
                selectionAnchorTime = anchor
                let current = time(for: value.location.x, width: width)
                clipRange = MediaClipRange(start: anchor, end: current)
                    .normalized(in: duration, minimumDuration: minimumClipDuration)
            }
            .onEnded { value in
                guard isEnabled, duration > 0 else {
                    selectionAnchorTime = nil
                    return
                }
                let anchor = selectionAnchorTime ?? time(for: value.startLocation.x, width: width)
                let current = time(for: value.location.x, width: width)
                clipRange = MediaClipRange(start: anchor, end: current)
                    .normalized(in: duration, minimumDuration: minimumClipDuration)
                selectionAnchorTime = nil
            }
    }

    private func handleGesture(edge: ClipHandleEdge, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard isEnabled, duration > 0 else { return }
                let base = handleDragBase
                    ?? clipRange?.normalized(in: duration, minimumDuration: minimumClipDuration)
                    ?? MediaClipRange(start: 0, end: duration)
                if handleDragBase == nil {
                    handleDragBase = base
                    NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
                }
                let delta = Double(value.translation.width / max(width, 1)) * duration
                let nextRange: MediaClipRange
                switch edge {
                case .start:
                    nextRange = MediaClipRange(start: min(base.start + delta, base.end - minimumClipDuration), end: base.end)
                case .end:
                    nextRange = MediaClipRange(start: base.start, end: max(base.end + delta, base.start + minimumClipDuration))
                }
                clipRange = nextRange.normalized(in: duration, minimumDuration: minimumClipDuration)
            }
            .onEnded { _ in
                if handleDragBase != nil {
                    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                }
                handleDragBase = nil
            }
    }

    private func xPosition(_ seconds: Double, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        let fraction = min(max(seconds / duration, 0), 1)
        return CGFloat(fraction) * width
    }

    private func time(for x: CGFloat, width: CGFloat) -> Double {
        guard duration > 0 else { return 0 }
        let fraction = min(max(x / max(width, 1), 0), 1)
        return Double(fraction) * duration
    }

    private func segmentOpacity(_ segment: SubtitleSegment, selectedRange: MediaClipRange?) -> Double {
        guard let selectedRange else { return 1 }
        return segment.end >= selectedRange.start && segment.start <= selectedRange.end ? 1 : 0.24
    }
}

private enum ClipHandleEdge {
    case start
    case end
}

private struct MSubCommandsModifier: ViewModifier {
    @Binding var detailTab: DetailTab
    let onWillTerminate: () -> Void

    func body(content: Content) -> some View {
        content
            .task {
                let stream = NotificationCenter.default.notifications(named: NSApplication.willTerminateNotification)
                for await _ in stream {
                    onWillTerminate()
                    break
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .msubShowSegmentsTabRequested)) { _ in
                detailTab = .segments
            }
            .onReceive(NotificationCenter.default.publisher(for: .msubShowOutputTabRequested)) { _ in
                detailTab = .output
            }
            .onReceive(NotificationCenter.default.publisher(for: .msubShowCueListTabRequested)) { _ in
                detailTab = .cueList
            }
            .onReceive(NotificationCenter.default.publisher(for: .msubFindInSubtitlesRequested)) { _ in
                detailTab = .output
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(60))
                    NotificationCenter.default.post(name: .msubFocusFindFieldRequested, object: nil)
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
    static let msubTranslateRequested = Notification.Name("MSubTranslateRequested")
    static let msubAuthorizeSidecarFolderRequested = Notification.Name("MSubAuthorizeSidecarFolderRequested")
    static let msubSaveAllRequested = Notification.Name("MSubSaveAllRequested")
    static let msubDeleteSelectedCueRequested = Notification.Name("MSubDeleteSelectedCueRequested")
    static let msubDuplicateSelectedCueRequested = Notification.Name("MSubDuplicateSelectedCueRequested")
    static let msubInsertCueBeforeRequested = Notification.Name("MSubInsertCueBeforeRequested")
    static let msubInsertCueAfterRequested = Notification.Name("MSubInsertCueAfterRequested")
    static let msubResetSelectedCueRequested = Notification.Name("MSubResetSelectedCueRequested")
    static let msubAdjustTimingRequested = Notification.Name("MSubAdjustTimingRequested")
    static let msubZoomTimelineInRequested = Notification.Name("MSubZoomTimelineInRequested")
    static let msubZoomTimelineOutRequested = Notification.Name("MSubZoomTimelineOutRequested")
    static let msubToggleTimelineRequested = Notification.Name("MSubToggleTimelineRequested")
    static let msubFindInSubtitlesRequested = Notification.Name("MSubFindInSubtitlesRequested")
    static let msubFocusFindFieldRequested = Notification.Name("MSubFocusFindFieldRequested")
    static let msubShowSegmentsTabRequested = Notification.Name("MSubShowSegmentsTabRequested")
    static let msubShowOutputTabRequested = Notification.Name("MSubShowOutputTabRequested")
    static let msubShowCueListTabRequested = Notification.Name("MSubShowCueListTabRequested")
}

@MainActor
@Observable
final class RecentFilesStore {
    private(set) var urls: [URL] = []

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
        FolderAuthorizationStore.shared.storeFileBookmark(for: normalized)
        NSDocumentController.shared.noteNewRecentDocumentURL(normalized)
    }

    func replace(_ oldURL: URL, with newURL: URL) {
        let oldNormalized = oldURL.standardizedFileURL
        let newNormalized = newURL.standardizedFileURL
        urls.removeAll {
            $0.standardizedFileURL == oldNormalized || $0.standardizedFileURL == newNormalized
        }
        urls.insert(newNormalized, at: 0)
        if urls.count > limit {
            urls = Array(urls.prefix(limit))
        }
        save()
        FolderAuthorizationStore.shared.removeFileBookmark(path: oldNormalized.path)
        FolderAuthorizationStore.shared.storeFileBookmark(for: newNormalized)
        NSDocumentController.shared.noteNewRecentDocumentURL(newNormalized)
    }

    func clear() {
        for url in urls {
            FolderAuthorizationStore.shared.removeFileBookmark(path: url.path)
        }
        urls = []
        save()
        NSDocumentController.shared.clearRecentDocuments(nil)
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
}

/// Preview for containers AVFoundation can't natively play (MKV, AVI, …).
///
/// We always render the audio + filmstrip preview first. For modestly-sized
/// files we also try a bounded background remux; large sources stay on the
/// filmstrip path so opening them cannot silently write multi-GB caches.
private struct AdaptiveThumbnailMediaPreview: View {
    let url: URL
    let title: String
    let language: AppLanguage
    let cues: [SubtitleCue]
    let canCaptureFrame: Bool
    let isCapturingFrame: Bool
    let captureHelp: String
    let nativePreviewHelp: String
    let playback: PlaybackController
    let onCaptureFrame: () -> Void
    let onNativePreview: (URL) -> Void

    @State private var playableURL: URL?

    var body: some View {
        Group {
            if let playableURL {
                MediaPreviewCard(
                    url: playableURL,
                    title: title,
                    cues: cues,
                    canCaptureFrame: canCaptureFrame,
                    isCapturingFrame: isCapturingFrame,
                    captureHelp: captureHelp,
                    nativePreviewHelp: nativePreviewHelp,
                    playback: playback,
                    onCaptureFrame: onCaptureFrame,
                    // Hand Quick Look the remuxed MP4 — the original
                    // container often isn't playable by QuickLook's bundled
                    // plugins, but the freshly-remuxed MP4 always is.
                    onNativePreview: { onNativePreview(playableURL) }
                )
            } else {
                UnsupportedMediaPreview(
                    url: url,
                    title: title,
                    language: language,
                    cues: cues,
                    canCaptureFrame: canCaptureFrame,
                    isCapturingFrame: isCapturingFrame,
                    captureHelp: captureHelp,
                    nativePreviewHelp: nativePreviewHelp,
                    playback: playback,
                    onCaptureFrame: onCaptureFrame,
                    onNativePreview: onNativePreview
                )
            }
        }
        .task(id: url) {
            playableURL = nil
            let resolution = await VideoSource.resolveForAutomaticPreview(url)
            guard !Task.isCancelled else { return }
            // Only flip if the remux actually produced a new, playable file.
            // `.directly` shouldn't happen here (this branch is for the
            // thumbnail-only extension list) but if it did, the file is
            // already playable so we'd upgrade. `.audioOnly` / `.unavailable`
            // leave us on the filmstrip — same UX as before this feature.
            switch resolution {
            case .remuxed(let resolvedURL), .directly(let resolvedURL):
                // Carry the user's listening position across the upgrade so
                // we don't yank them back to t=0 when video kicks in.
                // PlaybackController.load resets currentTime, so we capture
                // the existing state first, perform the reload, then seek
                // back and restore the play/pause state.
                let resumeTime = playback.currentTime
                let wasPlaying = playback.isPlaying
                await playback.load(resolvedURL)
                guard !Task.isCancelled else { return }
                if resumeTime > 0 {
                    playback.seek(to: resumeTime, pause: !wasPlaying)
                }
                if wasPlaying && !playback.isPlaying {
                    playback.togglePlayPause()
                }
                playableURL = resolvedURL
            case .audioOnly, .unavailable:
                playableURL = nil
            }
        }
    }
}

private struct UnsupportedMediaPreview: View {
    let url: URL
    let title: String
    let language: AppLanguage
    let cues: [SubtitleCue]
    let canCaptureFrame: Bool
    let isCapturingFrame: Bool
    let captureHelp: String
    let nativePreviewHelp: String
    let playback: PlaybackController
    let onCaptureFrame: () -> Void
    let onNativePreview: (URL) -> Void

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
                NativePreviewButton(help: nativePreviewHelp) {
                    onNativePreview(nativePreviewURL())
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
        .task(id: url) {
            await reloadPreview()
        }
    }

    private func nativePreviewURL() -> URL {
        guard let cover,
              let previewURL = NativePreviewImageStore.write(image: cover, sourceURL: url) else {
            return url
        }
        return previewURL
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
                    PlaybackSubtitleOverlay(cues: cues, playback: playback)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
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
            .overlay(alignment: .leading) {
                if filmstrip.count > 1 {
                    glassPageButton(systemName: "chevron.left", action: showPreviousFrame)
                        .padding(.leading, 10)
                }
            }
            .overlay(alignment: .trailing) {
                if filmstrip.count > 1 {
                    glassPageButton(systemName: "chevron.right", action: showNextFrame)
                        .padding(.trailing, 10)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .animation(.easeInOut(duration: 0.25), value: cover)
    }

    private func glassPageButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
    }

    private func showPreviousFrame() {
        guard !filmstrip.isEmpty else { return }
        let current = selectedFrameIndex ?? 0
        let next = (current - 1 + filmstrip.count) % filmstrip.count
        withAnimation(.easeInOut(duration: 0.2)) {
            selectedFrameIndex = next
            cover = filmstrip[next]
        }
    }

    private func showNextFrame() {
        guard !filmstrip.isEmpty else { return }
        let current = selectedFrameIndex ?? -1
        let next = (current + 1) % filmstrip.count
        withAnimation(.easeInOut(duration: 0.2)) {
            selectedFrameIndex = next
            cover = filmstrip[next]
        }
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
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8))
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
        await playback.load(url)
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

private struct NativePreviewButton: View {
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "eye")
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .help(help)
        .accessibilityLabel(help)
    }
}

private enum NativePreviewImageStore {
    static func write(image: NSImage, sourceURL: URL) -> URL? {
        guard let data = pngData(for: image) else { return nil }
        let base = sourceURL.deletingPathExtension().lastPathComponent
        let safeBase = base.isEmpty ? "preview" : base
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("MSub-native-preview-\(safeBase)-\(UUID().uuidString)")
            .appendingPathExtension("png")
        do {
            try data.write(to: destination, options: .atomic)
            return destination
        } catch {
            return nil
        }
    }

    private static func pngData(for image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return representation.representation(using: .png, properties: [:])
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

private func previewSubtitleText(for cues: [SubtitleCue], at seconds: Double) -> String? {
    guard seconds.isFinite else { return nil }
    guard let cue = cues.first(where: { seconds >= $0.start && seconds <= $0.end }) else {
        return nil
    }
    let text = VideoFrameCapture.cleanSubtitleText(SubtitleDocument.displayText(for: cue))
    return text.isEmpty ? nil : text
}

private struct PlaybackSubtitleOverlay: View {
    let cues: [SubtitleCue]
    let playback: PlaybackController

    var body: some View {
        PreviewSubtitleOverlay(text: previewSubtitleText(for: cues, at: playback.currentTime))
            .allowsHitTesting(false)
    }
}

private struct MediaPreviewCard: View {
    static let cardHeight: CGFloat = PreviewCardMetrics.height

    let url: URL
    let title: String
    let cues: [SubtitleCue]
    let canCaptureFrame: Bool
    let isCapturingFrame: Bool
    let captureHelp: String
    let nativePreviewHelp: String
    let playback: PlaybackController
    let onCaptureFrame: () -> Void
    let onNativePreview: () -> Void

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
                NativePreviewButton(help: nativePreviewHelp, action: onNativePreview)
            }

            ZStack(alignment: .bottom) {
                AVPlayerViewRepresentable(player: playback.player)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if playback.hasVideo {
                    PlaybackSubtitleOverlay(cues: cues, playback: playback)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                }
            }
            .frame(height: playback.hasVideo ? 238 : 80)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: PreviewCardMetrics.height, alignment: .topLeading)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: PreviewCardMetrics.cornerRadius))
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
        // If we already remuxed this container for playback, use the MP4 —
        // AVFoundation succeeds on it where it would just fail on the
        // original MKV/AVI/WMV and force us into the slower ffmpeg path.
        let assetURL = VideoSource.cachedURL(for: source) ?? source
        let asset = AVURLAsset(url: assetURL)
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
