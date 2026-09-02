import AppKit
import AVFoundation
import CryptoKit
import Darwin
import SwiftUI

final class WaveformSamples: Equatable, @unchecked Sendable {
    let values: [CGFloat]

    init(_ values: [CGFloat]) {
        self.values = values
    }

    static func == (lhs: WaveformSamples, rhs: WaveformSamples) -> Bool {
        lhs === rhs
    }
}

struct WaveformCanvas: View, Equatable {
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

/// Resolves a media URL to one whose video stream AVPlayer can render. For
/// directly-playable containers (mp4/mov/…) it returns the original. For
/// containers AVFoundation can't demux (MKV, AVI, WMV…) it tries a fast
/// stream-copy remux into an MP4 — that's usually a few seconds even for hour-
/// long files because no decoding happens. If the copy fails (incompatible
/// codec or stream layout), it falls back to `AudioSource.resolve` so audio
/// playback still works end-to-end.
enum VideoSource {
    private static let cache = VideoRemuxCache()
    private static let maxAutomaticRemuxBytes: Int64 = 256 * 1024 * 1024
    private static let directlyPlayableExtensions: Set<String> = [
        "mp4", "mov", "m4v", "qt", "3gp", "3g2",
        "m4a", "mp3", "wav", "aac", "aiff", "aif", "flac", "caf"
    ]

    /// Result of a resolution attempt, so callers can distinguish "we got a
    /// playable video" from "we only got audio" without comparing URLs.
    enum Resolution {
        case directly(URL)            // original URL is already playable
        case remuxed(URL)             // ffmpeg produced a new playable file
        case audioOnly(URL)           // remux failed; audio-only fallback
        case unavailable(URL)         // nothing worked; original returned as-is

        var url: URL {
            switch self {
            case .directly(let u), .remuxed(let u), .audioOnly(let u), .unavailable(let u):
                return u
            }
        }

        var hasVideo: Bool {
            switch self {
            case .directly, .remuxed: return true
            case .audioOnly, .unavailable: return false
            }
        }
    }

    static func resolve(_ url: URL) async -> Resolution {
        await resolve(url, maxRemuxBytes: nil)
    }

    static func resolveForAutomaticPreview(_ url: URL) async -> Resolution {
        await resolve(url, maxRemuxBytes: maxAutomaticRemuxBytes)
    }

    private static func resolve(_ url: URL, maxRemuxBytes: Int64?) async -> Resolution {
        let ext = url.pathExtension.lowercased()
        if directlyPlayableExtensions.contains(ext) {
            return .directly(url)
        }
        if let maxRemuxBytes,
           let sourceBytes = sourceFileSize(url),
           sourceBytes > maxRemuxBytes {
            let audio = await AudioSource.resolve(url)
            return audio == url ? .unavailable(url) : .audioOnly(audio)
        }
        if let remuxed = await cache.remuxed(for: url) {
            return .remuxed(remuxed)
        }
        let audio = await AudioSource.resolve(url)
        return audio == url ? .unavailable(url) : .audioOnly(audio)
    }

    private static func sourceFileSize(_ url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return values?.fileSize.map(Int64.init)
    }

    /// Convenience for call sites that only need the resolved URL — preserves
    /// the old `AudioSource.resolve` signature so PlaybackController and the
    /// waveform path can stay terse.
    static func resolveURL(_ url: URL) async -> URL {
        await resolve(url).url
    }

    /// Returns a previously-cached remuxed MP4 for `source` if one exists on
    /// disk, without ever triggering a new remux. Synchronous so capture-frame
    /// and Quick Look paths can opportunistically prefer the already-playable
    /// file without paying any extraction cost. Returns nil when no cache
    /// entry exists yet.
    static func cachedURL(for source: URL) -> URL? {
        VideoRemuxCache.cachedURL(for: source)
    }
}

private actor VideoRemuxCache {
    private var inflight: [String: Task<URL?, Never>] = [:]

    func remuxed(for source: URL) async -> URL? {
        let key = Self.identifier(for: source)
        let dest = Self.destinationURL(for: key)

        if FileManager.default.fileExists(atPath: dest.path) {
            if await Self.isUsable(dest) {
                return dest
            }
            NSLog("[MSub] Discarding unusable cached remux at %@", dest.path)
            try? FileManager.default.removeItem(at: dest)
        }
        if let task = inflight[key] {
            return await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
        }
        let task = Task<URL?, Never>(priority: .utility) {
            // Probe the source codec before remuxing so HEVC streams get the
            // `hvc1` tag — without it the copied MP4 carries the raw `hev1`
            // tag and AVPlayer refuses to show video (audio still works).
            guard !Task.isCancelled else { return nil }
            let codec = await FFmpegRunner.probeVideoCodec(of: source)
            guard !Task.isCancelled else { return nil }
            guard let produced = await FFmpegRunner.remuxToMP4(
                from: source, to: dest, videoCodec: codec
            ) else {
                return nil
            }
            // Same playability gate the cache hit path uses — otherwise the
            // very first remux of a file whose codec tag AVPlayer can't read
            // would slip through and present a "video player" with no image.
            if await Self.isUsable(produced) {
                return produced
            }
            NSLog("[MSub] Remuxed MP4 at %@ is not playable; discarding.", produced.path)
            try? FileManager.default.removeItem(at: produced)
            return nil
        }
        inflight[key] = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        inflight[key] = nil
        return result
    }

    /// Synchronous accessor for the cached file path, used by capture-frame
    /// and Quick Look paths that want the remuxed MP4 only if it already
    /// exists. Never triggers extraction.
    nonisolated static func cachedURL(for source: URL) -> URL? {
        let key = identifier(for: source)
        let dest = destinationURL(for: key)
        return FileManager.default.fileExists(atPath: dest.path) ? dest : nil
    }

    /// A remuxed MP4 only counts as "usable" if AVFoundation will actually
    /// render its video on the player surface. Stream-copy can produce an MP4
    /// whose codec tag (e.g. raw `hev1` instead of `hvc1`) or pixel format
    /// AVPlayer refuses — we don't want to flip the UI into a "video" preview
    /// in that case, because the user would see only audio with a black frame.
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
        let isPlayable = (try? await asset.load(.isPlayable)) ?? false
        guard isPlayable else { return false }
        guard let videoTrack = (try? await asset.loadTracks(withMediaType: .video))?.first else {
            return false
        }
        let trackPlayable = (try? await videoTrack.load(.isPlayable)) ?? false
        guard trackPlayable else { return false }
        if let size = try? await videoTrack.load(.naturalSize),
           size.width > 0, size.height > 0 {
            return true
        }
        return false
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
        let dir = base.appendingPathComponent("MSub-remuxed-video-v1", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(identifier).mp4")
    }
}

/// Background sweeper that keeps the on-disk media caches from growing
/// unbounded. Each extracted/remuxed file is ~the size of the source's
/// audio (or full video) track, so over many sessions these directories can
/// silently consume gigabytes of caches.
///
/// Eviction is least-recently-used by `contentAccessDate` (falling back to
/// `contentModificationDate`). We run on app launch from a background task;
/// per-write pruning is intentionally skipped to keep extraction paths simple.
enum MediaCachePruner {
    /// Conservative defaults — large enough that frequently-revisited files
    /// stay hot, small enough to bound disk usage to a few GB total.
    static let videoCacheLimit: Int64 = 5 * 1024 * 1024 * 1024  // 5 GB
    static let audioCacheLimit: Int64 = 1 * 1024 * 1024 * 1024  // 1 GB

    static func enforceLimitsInBackground() {
        Task.detached(priority: .utility) {
            enforceLimitsNow()
        }
    }

    static func enforceLimitsNow() {
        prune(directoryName: "MSub-remuxed-video-v1", maxBytes: videoCacheLimit)
        prune(directoryName: "MSub-extracted-audio-v2", maxBytes: audioCacheLimit)
    }

    static func removeTransientCaches() {
        removeCacheDirectory(named: "MSub-cue-clips")
        removeCacheDirectory(named: "MSub-selected-ranges")
    }

    private static func prune(directoryName: String, maxBytes: Int64) {
        guard let cachesDir = try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else { return }
        let dir = cachesDir.appendingPathComponent(directoryName, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return
        }

        let resourceKeys: Set<URLResourceKey> = [
            .fileSizeKey, .contentAccessDateKey, .contentModificationDateKey
        ]
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return }

        struct Entry {
            let url: URL
            let size: Int64
            let lastUsed: Date
        }
        let entries: [Entry] = items.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: resourceKeys),
                  let size = values.fileSize else { return nil }
            let lastUsed = values.contentAccessDate
                ?? values.contentModificationDate
                ?? .distantPast
            return Entry(url: url, size: Int64(size), lastUsed: lastUsed)
        }

        var total = entries.reduce(0) { $0 + $1.size }
        guard total > maxBytes else { return }
        // Oldest first. Stop once we're under the cap.
        let sorted = entries.sorted { $0.lastUsed < $1.lastUsed }
        var removedCount = 0
        var removedBytes: Int64 = 0
        for entry in sorted {
            guard total > maxBytes else { break }
            do {
                try FileManager.default.removeItem(at: entry.url)
                total -= entry.size
                removedCount += 1
                removedBytes += entry.size
            } catch {
                NSLog(
                    "[MSub] Cache prune failed for %@: %@",
                    entry.url.lastPathComponent, "\(error)"
                )
            }
        }
        if removedCount > 0 {
            NSLog(
                "[MSub] Pruned %d files (%lld bytes) from %@",
                removedCount, removedBytes, directoryName
            )
        }
    }

    private static func removeCacheDirectory(named directoryName: String) {
        for base in cacheBaseDirectories() {
            let dir = base.appendingPathComponent(directoryName, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private static func cacheBaseDirectories() -> [URL] {
        var directories: [URL] = []
        if let cachesDir = try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            directories.append(cachesDir)
        }
        directories.append(FileManager.default.temporaryDirectory)
        return directories
    }
}

enum MediaProcessingCleanup {
    static func cleanupAfterLaunch() {
        MediaCachePruner.removeTransientCaches()
        MediaCachePruner.enforceLimitsInBackground()
    }

    static func cleanupBeforeTerminate() {
        FFmpegRunner.terminateActiveProcesses()
        MediaCachePruner.removeTransientCaches()
        MediaCachePruner.enforceLimitsNow()
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
            return await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
        }
        let task = Task<URL?, Never>(priority: .utility) {
            guard !Task.isCancelled else { return nil }
            return await Self.performExtraction(from: source, to: dest)
        }
        inflight[key] = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
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

    static func terminateActiveProcesses() {
        FFmpegProcessRegistry.shared.terminateAll()
    }

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

        var args: [String] = ["-y", "-nostdin", "-loglevel", "error", "-fflags", "+genpts"]
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
            "-map", "0:a:0",
            "-vn",
            "-af", "aresample=async=1000:first_pts=0",
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
        let waiter = ProcessExitWaiter()
        waiter.install(on: process)

        do {
            try process.run()
        } catch {
            NSLog("[MSub] FFmpeg launch failed for %@: %@", source.lastPathComponent, "\(error)")
            return nil
        }

        FFmpegProcessRegistry.shared.register(process)
        await waitForManagedProcess(process, waiter: waiter)
        FFmpegProcessRegistry.shared.unregister(process)
        process.terminationHandler = nil

        let elapsed = Date().timeIntervalSince(started)
        let exitCode = process.terminationStatus
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: dest)
            return nil
        }
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

    /// Stream-copies the video and audio of `source` into an MP4 at `dest`.
    /// No decoding/encoding happens — this is the fast path that turns an MKV/
    /// AVI whose codecs AVFoundation already supports into a container it can
    /// actually play. Returns nil when the source's codecs aren't compatible
    /// with the MP4 container (or any other ffmpeg error). Callers should
    /// treat nil as "fall back to filmstrip preview" rather than retrying with
    /// a costly transcode.
    ///
    /// `videoCodec` is the lowercase codec name from `probeVideoCodec` (e.g.
    /// `"hevc"`, `"h264"`). When supplied for HEVC we add `-tag:v hvc1` so
    /// the resulting MP4 carries the FOURCC AVPlayer/QuickTime accept —
    /// without the retag, copied HEVC streams keep the raw `hev1` tag and
    /// the player will show audio only, even though the file is structurally
    /// valid.
    static func remuxToMP4(
        from source: URL,
        to dest: URL,
        videoCodec: String? = nil
    ) async -> URL? {
        guard binary != nil else { return nil }
        try? FileManager.default.removeItem(at: dest)
        var args: [String] = [
            "-y", "-nostdin", "-loglevel", "error",
            "-i", source.path,
            "-map", "0:v:0?",
            "-map", "0:a:0?",
            "-c", "copy"
        ]
        if let videoCodec, ["hevc", "h265"].contains(videoCodec) {
            args.append(contentsOf: ["-tag:v", "hvc1"])
        }
        args.append(contentsOf: [
            "-movflags", "+faststart",
            "-avoid_negative_ts", "make_zero",
            dest.path
        ])
        if await runFFmpeg(args, source: source, dest: dest, operation: "video remux") {
            return dest
        }
        return nil
    }

    /// Reads the primary video codec name from ffmpeg's banner output. Returns
    /// a lowercased token like `"h264"`, `"hevc"`, `"vp9"`, or nil when the
    /// source has no video stream / probing fails. Cost is one short ffmpeg
    /// process (~0.3–0.8s) — we run it once per container in the remux path
    /// to decide whether HEVC retagging is needed.
    static func probeVideoCodec(of source: URL) async -> String? {
        guard let binary else { return nil }
        let process = Process()
        process.executableURL = binary
        process.arguments = ["-nostdin", "-hide_banner", "-i", source.path]
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        let waiter = ProcessExitWaiter()
        waiter.install(on: process)
        do {
            try process.run()
        } catch {
            return nil
        }
        FFmpegProcessRegistry.shared.register(process)
        await waitForManagedProcess(process, waiter: waiter)
        FFmpegProcessRegistry.shared.unregister(process)
        process.terminationHandler = nil
        guard !Task.isCancelled else { return nil }
        let data = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return parseFFmpegVideoCodec(text)
    }

    static func clipMedia(
        from source: URL,
        to dest: URL,
        start: Double,
        duration: Double
    ) async -> URL? {
        guard binary != nil else { return nil }
        let safeStart = String(format: "%.3f", max(0, start))
        let safeDuration = String(format: "%.3f", max(0.05, duration))
        let accurateDest: URL
        if ["mp4", "m4v", "mov"].contains(dest.pathExtension.lowercased()) {
            accurateDest = dest
        } else {
            accurateDest = dest.deletingPathExtension().appendingPathExtension("mp4")
        }

        try? FileManager.default.removeItem(at: accurateDest)
        let reencodeArgs = [
            "-y", "-nostdin", "-loglevel", "error",
            "-ss", safeStart,
            "-i", source.path,
            "-t", safeDuration,
            "-map", "0:v:0?",
            "-map", "0:a?",
            "-c:v", "libx264",
            "-preset", "veryfast",
            "-crf", "20",
            "-c:a", "aac",
            "-b:a", "192k",
            "-movflags", "+faststart",
            accurateDest.path
        ]
        if await runFFmpeg(reencodeArgs, source: source, dest: accurateDest, operation: "media clip") {
            return accurateDest
        }

        try? FileManager.default.removeItem(at: dest)
        let copyArgs = [
            "-y", "-nostdin", "-loglevel", "error",
            "-ss", safeStart,
            "-i", source.path,
            "-t", safeDuration,
            "-map", "0:v?",
            "-map", "0:a?",
            "-map", "0:s?",
            "-c", "copy",
            "-avoid_negative_ts", "make_zero",
            dest.path
        ]
        if await runFFmpeg(copyArgs, source: source, dest: dest, operation: "media clip copy") {
            return dest
        }
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
        let waiter = ProcessExitWaiter()
        waiter.install(on: process)
        do {
            try process.run()
        } catch {
            return nil
        }
        FFmpegProcessRegistry.shared.register(process)
        await waitForManagedProcess(process, waiter: waiter)
        FFmpegProcessRegistry.shared.unregister(process)
        process.terminationHandler = nil
        guard !Task.isCancelled else { return nil }
        let data = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return parseFFmpegDuration(text)
    }

    /// Pulls the first video stream's codec name out of ffmpeg's banner.
    /// Matches lines like `Stream #0:0(eng): Video: hevc (Main 10), …` and
    /// returns `"hevc"`. Returns nil when there is no video stream line.
    private static func parseFFmpegVideoCodec(_ output: String) -> String? {
        let pattern = #"Stream\s*#\d+:\d+(?:\([^)]*\))?(?:\[[^\]]*\])?\s*:\s*Video:\s*([A-Za-z0-9_]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              match.numberOfRanges >= 2,
              let codecRange = Range(match.range(at: 1), in: output) else {
            return nil
        }
        return String(output[codecRange]).lowercased()
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

    private static func runFFmpeg(
        _ arguments: [String],
        source: URL,
        dest: URL,
        operation: String
    ) async -> Bool {
        guard let binary else { return false }
        NSLog("[MSub] FFmpeg %@ starting on %@", operation, source.lastPathComponent)
        let started = Date()
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = Pipe()
        let waiter = ProcessExitWaiter()
        waiter.install(on: process)
        do {
            try process.run()
        } catch {
            NSLog("[MSub] FFmpeg %@ launch failed for %@: %@", operation, source.lastPathComponent, "\(error)")
            return false
        }

        FFmpegProcessRegistry.shared.register(process)
        await waitForManagedProcess(process, waiter: waiter)
        FFmpegProcessRegistry.shared.unregister(process)
        process.terminationHandler = nil

        let elapsed = Date().timeIntervalSince(started)
        let exitCode = process.terminationStatus
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: dest)
            return false
        }
        guard exitCode == 0, FileManager.default.fileExists(atPath: dest.path) else {
            let data = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
            let text = (String(data: data, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            NSLog(
                "[MSub] FFmpeg %@ exit %d on %@ in %.2fs: %@",
                operation, Int(exitCode), source.lastPathComponent, elapsed, text
            )
            try? FileManager.default.removeItem(at: dest)
            return false
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.int64Value ?? 0
        NSLog(
            "[MSub] FFmpeg %@ ok on %@ in %.2fs → %lld bytes at %@",
            operation, source.lastPathComponent, elapsed, size, dest.path
        )
        return true
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
        let waiter = ProcessExitWaiter()
        waiter.install(on: process)
        do {
            try process.run()
        } catch {
            return nil
        }
        FFmpegProcessRegistry.shared.register(process)
        await waitForManagedProcess(process, waiter: waiter)
        FFmpegProcessRegistry.shared.unregister(process)
        process.terminationHandler = nil
        guard !Task.isCancelled else {
            try? FileManager.default.removeItem(at: dest)
            return nil
        }
        if process.terminationStatus == 0, FileManager.default.fileExists(atPath: dest.path) {
            return dest
        }
        try? FileManager.default.removeItem(at: dest)
        return nil
    }

    private static func waitForManagedProcess(_ process: Process, waiter: ProcessExitWaiter) async {
        let box = ManagedProcessBox(process)
        await withTaskCancellationHandler {
            await waiter.wait()
        } onCancel: {
            FFmpegProcessRegistry.shared.terminate(box.process)
        }
    }
}

private final class ManagedProcessBox: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }
}

private final class ProcessExitWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var didExit = false
    private var continuation: CheckedContinuation<Void, Never>?

    func install(on process: Process) {
        process.terminationHandler = { [weak self] _ in
            self?.signal()
        }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if didExit {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    private func signal() {
        lock.lock()
        didExit = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

private final class FFmpegProcessRegistry: @unchecked Sendable {
    static let shared = FFmpegProcessRegistry()

    private let lock = NSLock()
    private var processes: [pid_t: Process] = [:]

    func register(_ process: Process) {
        guard process.isRunning else { return }
        lock.lock()
        processes[process.processIdentifier] = process
        lock.unlock()
    }

    func unregister(_ process: Process) {
        let pid = process.processIdentifier
        lock.lock()
        processes.removeValue(forKey: pid)
        lock.unlock()
    }

    func terminate(_ process: Process) {
        terminate(process, wait: false)
    }

    func terminateAll() {
        lock.lock()
        let running = Array(processes.values)
        processes.removeAll()
        lock.unlock()

        for process in running {
            terminate(process, wait: true)
        }
    }

    private func terminate(_ process: Process, wait: Bool) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        guard wait else { return }
        let deadline = Date().addingTimeInterval(1.5)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            kill(pid, SIGKILL)
            process.waitUntilExit()
        }
    }
}

enum WaveformLoader {
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
        while !Task.isCancelled,
              let sampleBuffer = output.copyNextSampleBuffer(),
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
        if Task.isCancelled {
            return []
        }
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

            // Disk layer: decoded waveforms persist across sessions, so
            // reopening a file shows its waveform without re-decoding audio.
            if let diskSamples = loadFromDisk(key: key, targetSamples: targetSamples) {
                entries[key] = Entry(samples: diskSamples, sampleCount: diskSamples.count, lastAccess: Date())
                trimIfNeeded()
                return downsample(diskSamples, targetSamples: targetSamples)
            }

            let samples = await WaveformLoader.readSamples(for: url, targetSamples: targetSamples)
            guard !samples.isEmpty else { return [] }

            if let cached = entries[key], cached.sampleCount > samples.count {
                entries[key] = Entry(samples: cached.samples, sampleCount: cached.sampleCount, lastAccess: Date())
                return downsample(cached.samples, targetSamples: targetSamples)
            }

            entries[key] = Entry(samples: samples, sampleCount: samples.count, lastAccess: Date())
            trimIfNeeded()
            storeToDisk(key: key, samples: samples)
            return samples
        }

        private static let diskCacheURL: URL? = {
            guard let base = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first else { return nil }
            let dir = base.appendingPathComponent("MSub/WaveformCache", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }()
        private let maxDiskCacheFiles = 50

        private func diskCacheFile(forKey key: String) -> URL? {
            guard let dir = Self.diskCacheURL else { return nil }
            let digest = SHA256.hash(data: Data(key.utf8))
            let name = digest.map { String(format: "%02x", $0) }.joined()
            return dir.appendingPathComponent(name + ".wave")
        }

        private func loadFromDisk(key: String, targetSamples: Int) -> [CGFloat]? {
            guard let file = diskCacheFile(forKey: key),
                  let data = try? Data(contentsOf: file),
                  data.count >= targetSamples * MemoryLayout<Float32>.size,
                  data.count % MemoryLayout<Float32>.size == 0 else { return nil }
            let floats = data.withUnsafeBytes { Array($0.bindMemory(to: Float32.self)) }
            return floats.map { CGFloat($0) }
        }

        private func storeToDisk(key: String, samples: [CGFloat]) {
            guard samples.count >= 720, let file = diskCacheFile(forKey: key) else { return }
            if let existingSize = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
               existingSize >= samples.count * MemoryLayout<Float32>.size {
                return
            }
            let floats = samples.map { Float32($0) }
            let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
            try? data.write(to: file, options: .atomic)
            trimDiskCacheIfNeeded()
        }

        private func trimDiskCacheIfNeeded() {
            guard let dir = Self.diskCacheURL,
                  let files = try? FileManager.default.contentsOfDirectory(
                      at: dir,
                      includingPropertiesForKeys: [.contentModificationDateKey],
                      options: .skipsHiddenFiles
                  ),
                  files.count > maxDiskCacheFiles else { return }
            let sorted = files.sorted { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return lhsDate < rhsDate
            }
            for file in sorted.prefix(files.count - maxDiskCacheFiles) {
                try? FileManager.default.removeItem(at: file)
            }
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
