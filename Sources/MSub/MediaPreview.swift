import AppKit
import AVFoundation
import AVKit
import QuickLook
import QuickLookThumbnailing
import SwiftUI

// MARK: - Media preview

enum MediaPreviewKind {
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

enum PreviewCardMetrics {
    static let height: CGFloat = 296
    static let cornerRadius: CGFloat = 14
}

/// Preview for containers AVFoundation can't natively play (MKV, AVI, …).
///
/// We always render the audio + filmstrip preview first. For modestly-sized
/// files we also try a bounded background remux; large sources stay on the
/// filmstrip path so opening them cannot silently write multi-GB caches.
struct AdaptiveThumbnailMediaPreview: View {
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
        guard !Task.isCancelled else { return }
        cover = nil
        filmstrip = []
        selectedFrameIndex = nil
        isLoadingCover = true

        let duration = await assetDurationSeconds()
        guard !Task.isCancelled else { return }

        // Cover first — at ~10% in, or 3s if duration is unknown.
        let coverTime = duration > 0 ? duration * 0.1 : 3.0
        let coverImage: NSImage?
        if let primary = await frame(at: coverTime, width: 720) {
            coverImage = primary
        } else {
            coverImage = await quickLookCover()
        }
        guard !Task.isCancelled else { return }
        await MainActor.run {
            cover = coverImage
            isLoadingCover = false
        }

        // Filmstrip — extract a few frames with bounded concurrency. Skip for
        // very short clips where overlapping fractions would just produce the
        // same frame.
        guard duration > 4 else { return }
        let times = Self.filmstripFractions.map { $0 * duration }
        let strip = await loadFilmstrip(times: times)
        guard !Task.isCancelled else { return }
        guard !strip.isEmpty else { return }
        await MainActor.run {
            filmstrip = strip
        }
    }

    private func loadFilmstrip(times: [Double]) async -> [NSImage] {
        let indexedTimes = Array(times.enumerated())
        guard !indexedTimes.isEmpty else { return [] }
        let sourceURL = url
        let maxConcurrentExtractions = min(2, indexedTimes.count)
        return await withTaskGroup(of: (Int, NSImage?).self) { group in
            var nextIndex = 0

            func addNextExtraction() {
                guard nextIndex < indexedTimes.count else { return }
                let (idx, time) = indexedTimes[nextIndex]
                nextIndex += 1
                group.addTask(priority: .utility) {
                    guard !Task.isCancelled else { return (idx, nil) }
                    if let frameURL = await FFmpegRunner.extractFrame(from: sourceURL, at: time, width: 320),
                       let image = NSImage(contentsOf: frameURL) {
                        try? FileManager.default.removeItem(at: frameURL)
                        return (idx, image)
                    }
                    return (idx, nil)
                }
            }

            for _ in 0..<maxConcurrentExtractions {
                addNextExtraction()
            }

            var collected: [(Int, NSImage)] = []
            while let result = await group.next() {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }
                if let image = result.1 {
                    collected.append((result.0, image))
                }
                addNextExtraction()
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

func previewSubtitleText(for cues: [SubtitleCue], at seconds: Double) -> String? {
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

struct MediaPreviewCard: View {
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

enum VideoFrameCapture {
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
