import AppKit
import SwiftUI

struct TimelineZoomSlider: NSViewRepresentable {
    @Binding var value: Double
    @Binding var isDragging: Bool
    let range: ClosedRange<Double>
    let step: Double

    private final class TrackingSlider: NSSlider {
        var onTrackingBegan: (() -> Void)?
        var onTrackingEnded: (() -> Void)?

        override func mouseDown(with event: NSEvent) {
            onTrackingBegan?()
            super.mouseDown(with: event)
            onTrackingEnded?()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSlider {
        let slider = TrackingSlider(
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
        slider.onTrackingBegan = {
            context.coordinator.parent.isDragging = true
        }
        slider.onTrackingEnded = {
            context.coordinator.parent.isDragging = false
        }
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        if let slider = slider as? TrackingSlider {
            slider.onTrackingBegan = {
                context.coordinator.parent.isDragging = true
            }
            slider.onTrackingEnded = {
                context.coordinator.parent.isDragging = false
            }
        }
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
        guard step > 0 else { return clamp(rawValue, bounds.lower, bounds.upper) }
        let steppedValue = (rawValue / step).rounded() * step
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

struct PlaybackZoomableTimeline: View {
    let cuesRevision: UUID
    let cueIndex: SubtitleCueIndex
    let overlaps: TimelineOverlapMap
    @Binding var cues: [SubtitleCue]
    @Binding var selectedCueID: SubtitleCue.ID?
    @Binding var highlightTerm: String?
    let findTerm: String?
    var findMarkers = TimelineMarkerSet.empty
    var highlightMarkers = TimelineMarkerSet.empty

    let waveform: WaveformSamples
    let duration: Double
    @Binding var zoom: Double
    let zoomRange: ClosedRange<Double>
    let playback: PlaybackController
    let centerRequest: TimelineCenterRequest?
    @Binding var isSliderZooming: Bool
    let activeSpeakerName: String?
    let speakerColors: [String: String]
    let language: AppLanguage
    let onSeek: (Double) -> Void
    let onScrub: (Double) -> Void
    let onCueTimingEditBegan: () -> Void
    let onCueTimingEditEnded: () -> Void
    let cueActions: TimelineCueActions

    var body: some View {
        ZoomableTimeline(
            cuesRevision: cuesRevision,
            cueIndex: cueIndex,
            overlaps: overlaps,
            cues: $cues,
            selectedCueID: $selectedCueID,
            highlightTerm: $highlightTerm,
            findTerm: findTerm,
            findMarkers: findMarkers,
            highlightMarkers: highlightMarkers,
            waveform: waveform,
            duration: duration,
            zoom: $zoom,
            zoomRange: zoomRange,
            currentTime: playback.currentTime,
            centerRequest: centerRequest,
            isSliderZooming: $isSliderZooming,
            activeSpeakerName: activeSpeakerName,
            speakerColors: speakerColors,
            language: language,
            onSeek: onSeek,
            onScrub: onScrub,
            onCueTimingEditBegan: onCueTimingEditBegan,
            onCueTimingEditEnded: onCueTimingEditEnded,
            cueActions: cueActions
        )
    }
}

struct PlaybackCompactTimelineStrip: View {
    let cuesRevision: UUID
    let cues: [SubtitleCue]
    @Binding var selectedCueID: SubtitleCue.ID?
    @Binding var highlightTerm: String?
    let findTerm: String?
    var findMarkers = TimelineMarkerSet.empty
    var highlightMarkers = TimelineMarkerSet.empty
    let waveform: WaveformSamples
    let duration: Double
    let playback: PlaybackController
    let activeSpeakerName: String?
    let onSeek: (Double) -> Void

    var body: some View {
        CompactTimelineStrip(
            cuesRevision: cuesRevision,
            cues: cues,
            selectedCueID: $selectedCueID,
            highlightTerm: $highlightTerm,
            findTerm: findTerm,
            findMarkers: findMarkers,
            highlightMarkers: highlightMarkers,
            waveform: waveform,
            duration: duration,
            currentTime: playback.currentTime,
            activeSpeakerName: activeSpeakerName,
            onSeek: onSeek
        )
    }
}

struct ZoomableTimeline: View {
    let cuesRevision: UUID
    let cueIndex: SubtitleCueIndex
    let overlaps: TimelineOverlapMap
    @Binding var cues: [SubtitleCue]
    @Binding var selectedCueID: SubtitleCue.ID?
    @Binding var highlightTerm: String?
    let findTerm: String?
    var findMarkers = TimelineMarkerSet.empty
    var highlightMarkers = TimelineMarkerSet.empty

    let waveform: WaveformSamples
    let duration: Double
    @Binding var zoom: Double
    let zoomRange: ClosedRange<Double>
    let currentTime: Double
    let centerRequest: TimelineCenterRequest?
    @Binding var isSliderZooming: Bool
    let activeSpeakerName: String?
    let speakerColors: [String: String]
    let language: AppLanguage
    let onSeek: (Double) -> Void
    let onScrub: (Double) -> Void
    let onCueTimingEditBegan: () -> Void
    let onCueTimingEditEnded: () -> Void
    let cueActions: TimelineCueActions

    @State private var isHandleDragging = false
    @State private var scrollPosition = ScrollPosition()
    @State private var visibleContentOffsetX: CGFloat = 0
    @State private var visibleFractionRange: ClosedRange<Double> = 0...1
    @State private var magnifySession: ZoomAnchorSession?
    @State private var sliderZoomSession: ZoomAnchorSession?
    @State private var sliderZoomCleanupTask: Task<Void, Never>?

    private struct ZoomAnchorSession: Equatable {
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
                    cuesRevision: cuesRevision,
                    cueIndex: cueIndex,
                    overlaps: overlaps,
                    cues: $cues,
                    selectedCueID: $selectedCueID,
                    isHandleDragging: $isHandleDragging,
                    highlightTerm: $highlightTerm,
                    findTerm: findTerm,
                    findMarkers: findMarkers,
                    highlightMarkers: highlightMarkers,
                    waveform: waveform,
                    duration: duration,
                    zoom: zoom,
                    currentTime: currentTime,
                    activeSpeakerName: activeSpeakerName,
                    speakerColors: speakerColors,
                    language: language,
                    visibleFractionRange: effectiveVisibleRange,
                    onSeek: onSeek,
                    onScrub: onScrub,
                    onCueTimingEditBegan: onCueTimingEditBegan,
                    onCueTimingEditEnded: onCueTimingEditEnded,
                    cueActions: cueActions
                )
                .frame(width: contentWidth, height: proxy.size.height)
            }
            .scrollDisabled(isHandleDragging || magnifySession != nil || sliderZoomSession != nil)
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
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                max(0, geometry.visibleRect.minX)
            } action: { _, newValue in
                visibleContentOffsetX = newValue
            }
            .onChange(of: centerRequest) { _, request in
                guard magnifySession == nil,
                      sliderZoomSession == nil else { return }
                centerOnSelectedCue(viewport: viewportWidth, content: contentWidth, animated: true, cueID: request?.cueID)
            }
            .onChange(of: zoom) { oldZoom, newZoom in
                guard magnifySession == nil else { return }
                if isSliderZooming || sliderZoomSession != nil {
                    let session = sliderZoomSession ?? makePlayheadZoomSession(viewport: viewportWidth, baselineZoom: oldZoom)
                    sliderZoomSession = session
                    anchorZoomSession(session, newZoom: newZoom)
                }
            }
            .onChange(of: isSliderZooming) { _, newValue in
                if newValue {
                    sliderZoomCleanupTask?.cancel()
                    sliderZoomSession = makePlayheadZoomSession(viewport: viewportWidth, baselineZoom: zoom)
                } else {
                    scheduleSliderZoomSessionCleanup()
                }
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
            withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { scroll() }
        } else {
            DispatchQueue.main.async { scroll() }
        }
    }

    private func makePlayheadZoomSession(viewport: CGFloat, baselineZoom: Double) -> ZoomAnchorSession {
        let safeViewport = max(viewport, 1)
        let anchorFraction = min(max(currentTime / max(duration, 0.001), 0), 1)
        let contentWidth = max(safeViewport, safeViewport * baselineZoom)
        let playheadScreenX = CGFloat(anchorFraction) * contentWidth - visibleContentOffsetX
        return ZoomAnchorSession(
            baselineZoom: baselineZoom,
            anchorFraction: anchorFraction,
            anchorScreenX: min(max(0, playheadScreenX), safeViewport),
            viewportWidth: safeViewport
        )
    }

    private func anchorZoomSession(_ session: ZoomAnchorSession, newZoom: Double) {
        let newContentWidth = max(session.viewportWidth, session.viewportWidth * newZoom)
        let target = CGFloat(session.anchorFraction) * newContentWidth - session.anchorScreenX
        let maxOffset = max(0, newContentWidth - session.viewportWidth)
        let clamped = min(max(0, target), maxOffset)
        visibleContentOffsetX = clamped
        scrollPosition.scrollTo(x: clamped)
    }

    private func scheduleSliderZoomSessionCleanup() {
        let session = sliderZoomSession
        sliderZoomCleanupTask?.cancel()
        sliderZoomCleanupTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled,
                  !isSliderZooming,
                  sliderZoomSession == session else { return }
            sliderZoomSession = nil
        }
    }

    private func makeMagnifyGesture(viewport: CGFloat) -> some Gesture {
        MagnifyGesture(minimumScaleDelta: 0.01)
            .onChanged { value in
                let safeViewport = max(viewport, 1)
                let session: ZoomAnchorSession
                if let existing = magnifySession {
                    session = existing
                } else {
                    let startX = max(0, min(safeViewport, value.startLocation.x))
                    let visibleSpan = max(0, visibleFractionRange.upperBound - visibleFractionRange.lowerBound)
                    let anchor = visibleFractionRange.lowerBound + (startX / safeViewport) * visibleSpan
                    let created = ZoomAnchorSession(
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
                anchorZoomSession(session, newZoom: newZoom)
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

private struct TimelineDotsCanvas: View, Equatable {
    let markers: TimelineMarkerSet
    var visibleFractionRange: ClosedRange<Double> = 0...1
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
                    let padding = Double(max(baseDiameter, emphasizedDiameter) + 4) / Double(max(size.width, 1)) * duration
                    let lower = visibleFractionRange.lowerBound <= 0 ? -Double.greatestFiniteMagnitude : visibleFractionRange.lowerBound * duration - padding
                    let upper = visibleFractionRange.upperBound >= 1 ? Double.greatestFiniteMagnitude : visibleFractionRange.upperBound * duration + padding
                    for dot in markers.visible(lower: lower, upper: upper) {
                        if dot.cueID == emphasizedCueID { continue }
                        let x = CGFloat(max(0, min(dot.time / max(duration, 0.001), 1))) * size.width
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
                if let id = emphasizedCueID, let time = markers.time(for: id) {
                    let x = CGFloat(max(0, min(time / max(duration, 0.001), 1))) * proxy.size.width
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
}

private struct CueDensityCanvas: View, Equatable {
    enum Layout: Equatable, Sendable {
        case compact(height: CGFloat)
        case expanded(top: CGFloat, height: CGFloat)
    }

    let cuesRevision: UUID
    let cues: [SubtitleCue]
    let duration: Double
    let width: CGFloat
    let activeSpeakerName: String?
    let layout: Layout

    @State private var cache = TimelineDensityCache()

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.cuesRevision == rhs.cuesRevision && lhs.duration == rhs.duration
            && lhs.width == rhs.width && lhs.activeSpeakerName == rhs.activeSpeakerName
            && lhs.layout == rhs.layout
    }

    var body: some View {
        let data = cache.value(cues: cues, revision: cuesRevision, duration: duration,
                               binCount: densityBinCount, speaker: activeSpeakerName)
        return Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, _ in
            let bins = data.counts
            let binCount = bins.count
            let maxCount = data.maximum
            let binWidth = width / CGFloat(binCount)
            for (index, count) in bins.enumerated() where count > 0 {
                let intensity = min(1.0, Double(count) / Double(maxCount))
                let rect = densityRect(index: index, binWidth: binWidth, intensity: intensity)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: 2),
                    with: .color(Color.teal.opacity(baseOpacity + opacityRange * intensity))
                )
            }

            if activeSpeakerName != nil {
                for index in 0..<binCount {
                    guard data.speakerCounts[index] > 0 else { continue }
                    context.fill(
                        Path(roundedRect: speakerRect(index: index, binWidth: binWidth), cornerRadius: 2),
                        with: .color(Color.teal.opacity(0.34))
                    )
                }
            }
        }
    }

    var densityBinCount: Int {
        switch layout {
        case .compact:
            return max(20, min(180, Int(width / 4)))
        case .expanded:
            return max(24, min(260, Int(width / 3)))
        }
    }

    private var baseOpacity: Double {
        switch layout {
        case .compact: return 0.18
        case .expanded: return 0.18
        }
    }

    private var opacityRange: Double {
        switch layout {
        case .compact: return 0.32
        case .expanded: return 0.36
        }
    }

    private func densityRect(index: Int, binWidth: CGFloat, intensity: Double) -> CGRect {
        switch layout {
        case .compact(let height):
            let blockHeight = (height - 10) * (0.3 + 0.6 * intensity)
            return CGRect(
                x: CGFloat(index) * binWidth,
                y: (height - blockHeight) / 2,
                width: max(1, binWidth * 0.82),
                height: blockHeight
            )
        case .expanded(let top, let height):
            let blockHeight = height * (0.35 + 0.55 * intensity)
            return CGRect(
                x: CGFloat(index) * binWidth,
                y: top + (height - blockHeight) / 2,
                width: max(1, binWidth * 0.82),
                height: blockHeight
            )
        }
    }

    private func speakerRect(index: Int, binWidth: CGFloat) -> CGRect {
        switch layout {
        case .compact(let height):
            return CGRect(
                x: CGFloat(index) * binWidth,
                y: 4,
                width: max(1, binWidth * 0.82),
                height: height - 8
            )
        case .expanded(let top, let height):
            return CGRect(
                x: CGFloat(index) * binWidth,
                y: top,
                width: max(1, binWidth * 0.82),
                height: height
            )
        }
    }

}

private struct CompactTimelineStrip: View {
    let cuesRevision: UUID
    let cues: [SubtitleCue]
    @Binding var selectedCueID: SubtitleCue.ID?
    @Binding var highlightTerm: String?
    let findTerm: String?
    var findMarkers = TimelineMarkerSet.empty
    var highlightMarkers = TimelineMarkerSet.empty
    let waveform: WaveformSamples
    let duration: Double
    let currentTime: Double
    let activeSpeakerName: String?
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
                    if let selectedCue {
                        compactSelectedDensityOverlay(cue: selectedCue, width: width, height: height)
                            .allowsHitTesting(false)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .center))
                                .animation(.spring(response: 0.28, dampingFraction: 0.88)))
                    }
                } else {
                    compactCueCanvas(width: width, height: height)
                        .allowsHitTesting(false)
                }

                if activeHighlightTerm != nil {
                    TimelineDotsCanvas(
                        markers: highlightMarkers,
                        duration: duration,
                        topY: 3,
                        baseDiameter: 6,
                        emphasizedDiameter: 6,
                        baseColor: .yellow,
                        emphasizedColor: .yellow,
                        emphasizedCueID: nil
                    )
                    .equatable()
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }

                if activeFindTerm != nil {
                    TimelineDotsCanvas(
                        markers: findMarkers,
                        duration: duration,
                        topY: 3,
                        baseDiameter: 6,
                        emphasizedDiameter: 10,
                        baseColor: .green,
                        emphasizedColor: .green,
                        emphasizedCueID: selectedCueID
                    )
                    .equatable()
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

    private var selectedCue: SubtitleCue? {
        guard let selectedCueID else { return nil }
        return cues.first { $0.id == selectedCueID }
    }

    private func compactCueCanvas(width: CGFloat, height: CGFloat) -> some View {
        Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, _ in
            for cue in cues {
                let selected = cue.id == selectedCueID
                let speakerMatched = speakerMatchesActive(cue)
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
                    with: .color(compactCueFillColor(selected: selected, speakerMatched: speakerMatched))
                )
            }
        }
    }

    private func compactDensityCanvas(width: CGFloat, height: CGFloat) -> some View {
        CueDensityCanvas(
            cuesRevision: cuesRevision,
            cues: cues,
            duration: duration,
            width: width,
            activeSpeakerName: activeSpeakerName,
            layout: .compact(height: height)
        )
        .equatable()
    }

    private func compactSelectedDensityOverlay(cue: SubtitleCue, width: CGFloat, height: CGFloat) -> some View {
        let binCount = max(20, min(180, Int(width / 4)))
        let lower = max(0, min(binCount - 1, Int((cue.start / max(duration, 0.001)) * Double(binCount))))
        let binWidth = width / CGFloat(binCount)
        return RoundedRectangle(cornerRadius: 2)
            .fill(Color.accentColor.opacity(0.5))
            .frame(width: max(2, binWidth), height: height - 8)
            .offset(x: CGFloat(lower) * binWidth, y: 4)
            .animation(.spring(response: 0.28, dampingFraction: 0.88), value: cue.id)
    }

    private func xPosition(_ seconds: Double, width: CGFloat) -> CGFloat {
        CGFloat(max(0, min(seconds / max(duration, 0.001), 1))) * width
    }

    private func compactCueFillColor(selected: Bool, speakerMatched: Bool) -> Color {
        if selected {
            return Color.accentColor.opacity(speakerMatched ? 0.68 : 0.55)
        }
        return Color.teal.opacity(speakerMatched ? 0.42 : 0.28)
    }

    private func speakerMatchesActive(_ cue: SubtitleCue) -> Bool {
        guard let activeSpeakerName else { return false }
        return SubtitleDocument.normalizedSpeakerName(cue.speaker) == activeSpeakerName
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
    let deleteMatching: @MainActor (SubtitleCue.ID) -> Void
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
        actions.deleteMatching(cue.id)
    } label: {
        Label(Copy.text("editor.deleteMatchingCues", language: language), systemImage: "trash.slash")
    }

    Button(role: .destructive) {
        actions.delete(cue.id)
    } label: {
        Label(Copy.text("editor.deleteCue", language: language), systemImage: "trash")
    }
}

struct WaveformTimelineEditor: View {
    let cuesRevision: UUID
    let cueIndex: SubtitleCueIndex
    let overlaps: TimelineOverlapMap
    @Binding var cues: [SubtitleCue]
    @Binding var selectedCueID: SubtitleCue.ID?
    @Binding var isHandleDragging: Bool
    @Binding var highlightTerm: String?
    let findTerm: String?
    var findMarkers = TimelineMarkerSet.empty
    var highlightMarkers = TimelineMarkerSet.empty

    let waveform: WaveformSamples
    let duration: Double
    let zoom: Double
    let currentTime: Double
    let activeSpeakerName: String?
    let speakerColors: [String: String]
    let language: AppLanguage
    let visibleFractionRange: ClosedRange<Double>
    let onSeek: (Double) -> Void
    let onScrub: (Double) -> Void
    let onCueTimingEditBegan: () -> Void
    let onCueTimingEditEnded: () -> Void
    let cueActions: TimelineCueActions

    @State private var dragSession: HandleDragSession?
    @State private var moveSession: CueMoveSession?
    @State private var hoveredCueID: SubtitleCue.ID?

    private struct HandleDragSession {
        let cueID: SubtitleCue.ID
        let edge: Edge
        let snapIndex: TimelineSnapIndex
        let wordIndex: TimelineSnapIndex
        let initialStart: Double
        let initialEnd: Double
        var isSnapped: Bool = false
    }

    private struct CueMoveSession {
        let cueID: SubtitleCue.ID
        let snapIndex: TimelineSnapIndex
        let initialStart: Double
        let initialEnd: Double
        var isSnapped: Bool = false
    }

    private enum Edge { case start, end }

    // Layout constants
    private let cueTopOffset: CGFloat = 22
    private let cueHeight: CGFloat = 64
    private let handleHitWidth: CGFloat = 16
    private let handleVisualWidth: CGFloat = 5
    private let handleHitHeightExtra: CGFloat = 12
    private let moveHandleHitHeight: CGFloat = 22
    private let moveHandleVisualWidth: CGFloat = 34
    private let moveHandleVisualHeight: CGFloat = 4
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

                ZStack(alignment: .topLeading) {
                    if detailedCues {
                        ZStack(alignment: .topLeading) {
                            cueBlocksCanvas(width: width, cueRange: visibleCueRange)
                                .allowsHitTesting(false)
                            cueOverlapCanvas(width: width)
                                .allowsHitTesting(false)
                            cueHitOverlays(width: width, cueRange: visibleCueRange)

                            if let selectedCue {
                                selectedCueOverlay(cue: selectedCue, width: width)
                                    .animation(.spring(response: 0.28, dampingFraction: 0.88), value: selectedCueID)
                                    .phaseAnimator([false, true], trigger: selectedCueID) { content, lifted in
                                        content.scaleEffect(x: 1, y: lifted ? 1.045 : 1)
                                    } animation: { lifted in
                                        .spring(response: lifted ? 0.18 : 0.28, dampingFraction: 0.78)
                                    }
                                    .transition(.scale(scale: 0.94).combined(with: .opacity)
                                        .animation(.spring(response: 0.28, dampingFraction: 0.88)))
                            }

                            if let selectedCueBinding {
                                handles(cue: selectedCueBinding, width: width)
                                    .animation(.spring(response: 0.28, dampingFraction: 0.88), value: selectedCueID)
                            }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .center)))
                    } else {
                        cueDensityCanvas(width: width)
                            .allowsHitTesting(false)
                            .transition(.opacity.combined(with: .scale(scale: 0.995, anchor: .center)))
                        if let selectedCue {
                            densitySelectedCueOverlay(cue: selectedCue, width: width)
                                .allowsHitTesting(false)
                                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .center))
                                .animation(.spring(response: 0.28, dampingFraction: 0.88)))
                        }
                    }
                }
                .animation(.easeInOut(duration: 0.22), value: detailedCues)

                if activeHighlightTerm != nil {
                    TimelineDotsCanvas(
                        markers: highlightMarkers,
                        visibleFractionRange: visibleFractionRange,
                        duration: duration,
                        topY: 6,
                        baseDiameter: 7,
                        emphasizedDiameter: 7,
                        baseColor: .yellow,
                        emphasizedColor: .yellow,
                        emphasizedCueID: nil
                    )
                    .equatable()
                    .frame(width: width)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }

                if activeFindTerm != nil {
                    TimelineDotsCanvas(
                        markers: findMarkers,
                        visibleFractionRange: visibleFractionRange,
                        duration: duration,
                        topY: 6,
                        baseDiameter: 7,
                        emphasizedDiameter: 11,
                        baseColor: .green,
                        emphasizedColor: .green,
                        emphasizedCueID: selectedCueID
                    )
                    .equatable()
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
        let speechSeconds = cueIndex.speechSeconds
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

        return cueIndex.visibleRange(lower: lowerTime, upper: upperTime)
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
            var lowConfidenceMarker: GraphicsContext.ResolvedText?
            for cue in cues[cueRange] {
                let selected = cue.id == selectedCueID
                let hovered = !selected && cue.id == hoveredCueID
                let speakerMatched = speakerMatchesActive(cue)
                let startX = xPosition(cue.start, width: width)
                let endX = xPosition(cue.end, width: width)
                let cueWidth = max(2, endX - startX)
                let rect = CGRect(x: startX, y: cueTopOffset, width: cueWidth, height: cueHeight)
                let path = Path(roundedRect: rect, cornerRadius: 5)
                context.fill(path, with: .color(cueFillColor(selected: selected, speakerMatched: speakerMatched, hovered: hovered)))
                context.stroke(
                    path,
                    with: .color(cueStrokeColor(selected: selected, speakerMatched: speakerMatched)),
                    lineWidth: selected ? 1.6 : 0.8
                )
                if !selected, let lineColor = speakerColor(for: cue) {
                    let lineRect = CGRect(
                        x: rect.minX + 3,
                        y: rect.maxY - 5,
                        width: max(0, rect.width - 6),
                        height: 3
                    )
                    context.fill(
                        Path(roundedRect: lineRect, cornerRadius: 1.5),
                        with: .color(lineColor.opacity(0.9))
                    )
                }
                if let confidence = cue.confidence,
                   confidence < SubtitleConfidence.lowThreshold,
                   cueWidth >= 12 {
                    if lowConfidenceMarker == nil {
                        lowConfidenceMarker = context.resolve(
                            Text("?")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.orange)
                        )
                    }
                    if let marker = lowConfidenceMarker {
                        context.draw(
                            marker,
                            at: CGPoint(x: rect.minX + 7, y: rect.minY + 8)
                        )
                    }
                }
            }
        }
    }

    /// Disjoint sweep-line spans preserve overlap intensity without drawing all
    /// intersecting cue pairs again for every playback frame.
    private func cueOverlapCanvas(width: CGFloat) -> some View {
        let visibleStart = visibleFractionRange.lowerBound * duration
        let visibleEnd = visibleFractionRange.upperBound * duration
        let padding = max(1.0, (visibleEnd - visibleStart) * 0.15)
        let lower = max(0, visibleStart - padding)
        let upper = min(max(duration, visibleEnd), visibleEnd + padding)
        let spans = overlaps.visible(lower: lower, upper: upper)
        return Canvas(opaque: false, colorMode: .nonLinear, rendersAsynchronously: true) { context, _ in
            for span in spans {
                let startX = xPosition(max(lower, span.start), width: width)
                let endX = xPosition(min(upper, span.end), width: width)
                let rect = CGRect(x: startX, y: cueTopOffset, width: max(2, endX - startX), height: cueHeight)
                let path = Path(roundedRect: rect, cornerRadius: 3)
                context.fill(path, with: .color(.red.opacity(span.fillOpacity)))
                context.stroke(path, with: .color(.red.opacity(span.strokeOpacity)), lineWidth: 1)
            }
        }
    }

    private func cueDensityCanvas(width: CGFloat) -> some View {
        CueDensityCanvas(
            cuesRevision: cuesRevision,
            cues: cues,
            duration: duration,
            width: width,
            activeSpeakerName: activeSpeakerName,
            layout: .expanded(top: cueTopOffset, height: cueHeight)
        )
        .equatable()
    }

    private func densitySelectedCueOverlay(cue: SubtitleCue, width: CGFloat) -> some View {
        let binCount = max(24, min(260, Int(width / 3)))
        let lower = max(0, min(binCount - 1, Int((cue.start / max(duration, 0.001)) * Double(binCount))))
        let binWidth = width / CGFloat(binCount)
        return RoundedRectangle(cornerRadius: 3)
            .stroke(Color.accentColor, lineWidth: 1.4)
            .frame(width: max(2, binWidth), height: cueHeight)
            .offset(x: CGFloat(lower) * binWidth, y: cueTopOffset)
            .animation(.spring(response: 0.28, dampingFraction: 0.88), value: cue.id)
    }

    private func selectedCueOverlay(cue: SubtitleCue, width: CGFloat) -> some View {
        let startX = xPosition(cue.start, width: width)
        let endX = xPosition(cue.end, width: width)
        let cueWidth = max(2, endX - startX)
        let hitWidth = max(24, cueWidth)
        let hitOffset = max(0, startX - (hitWidth - cueWidth) / 2)
        let visualOffset = startX - hitOffset
        let moving = moveSession?.cueID == cue.id

        return ZStack(alignment: .leading) {
            Color.white.opacity(0.001)
                .frame(width: hitWidth, height: cueHeight)

            RoundedRectangle(cornerRadius: 5)
                .fill(Color.accentColor.opacity(0.28))
                .frame(width: cueWidth, height: cueHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(
                            Color.accentColor,
                            lineWidth: 1.6
                        )
                )
                .offset(x: visualOffset)
            if let lineColor = speakerColor(for: cue) {
                Capsule()
                    .fill(lineColor.opacity(0.92))
                    .frame(width: max(0, cueWidth - 6), height: 3)
                    .offset(x: visualOffset + 3, y: cueHeight / 2 - 6)
            }
            wordTickMarks(for: cue, startX: startX, endX: endX, width: width)
                .offset(x: visualOffset - startX)
            Text("\(cue.index)")
                .font(.caption2.monospacedDigit().bold())
                .foregroundStyle(.secondary)
                .padding(.leading, visualOffset + 5)
                .lineLimit(1)
        }
        .frame(width: hitWidth, height: cueHeight, alignment: .leading)
        .contentShape(Rectangle())
        .offset(y: moving ? -2 : 0)
        .offset(x: hitOffset, y: cueTopOffset)
        .zIndex(3)
        .shadow(
            color: Color.black.opacity(moving ? 0.22 : 0),
            radius: moving ? 9 : 0,
            x: 0,
            y: moving ? 6 : 0
        )
        .shadow(
            color: Color.accentColor.opacity(moving ? 0.28 : 0),
            radius: moving ? 7 : 0
        )
        .help(cueTooltip(cue))
        .contextMenu {
            cueContextMenu(for: cue, language: language, actions: cueActions)
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.74), value: moving)
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
                    .onHover { hovering in
                        if hovering {
                            hoveredCueID = cue.id
                        } else if hoveredCueID == cue.id {
                            hoveredCueID = nil
                        }
                    }
                    .onTapGesture {
                        // Animate the selection layers, not the entire editor transaction.
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
        let cueWidth = max(2, endX - startX)
        let moveHitWidth = max(1, cueWidth)
        let moveHitX = startX
        let moveHitY = cueTopOffset - moveHandleHitHeight / 2 + 4
        let activeID = dragSession?.cueID
        let activeEdge = dragSession?.edge
        let startDragging = activeID == cue.wrappedValue.id && activeEdge == .start
        let endDragging = activeID == cue.wrappedValue.id && activeEdge == .end
        let moving = moveSession?.cueID == cue.wrappedValue.id

        return ZStack(alignment: .topLeading) {
            moveHandleArea(blockWidth: cueWidth, dragging: moving)
                .frame(width: moveHitWidth, height: moveHandleHitHeight)
                .offset(x: moveHitX, y: moveHitY)
                .gesture(moveCueGesture(for: cue, width: width))
                .help(Copy.text("editor.moveCue.help", language: language))

            handleHitArea(selected: selected, dragging: startDragging)
                .frame(width: handleHitWidth, height: handleHitHeight)
                .offset(x: startX - handleHitWidth / 2, y: handleYOffset)
                .gesture(handleDragGesture(for: cue, edge: .start, width: width))
                .help(Copy.text("editor.handleStart.help", language: language))

            handleHitArea(selected: selected, dragging: endDragging)
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

    private func moveHandleArea(blockWidth: CGFloat, dragging: Bool) -> some View {
        let horizontalInset = blockWidth >= 4 ? min(6, max(1, blockWidth * 0.18)) : 0
        let availableWidth = max(0, blockWidth - horizontalInset * 2)
        let minimumPreferredWidth = min(10, availableWidth)
        let restingWidth = min(
            moveHandleVisualWidth,
            max(minimumPreferredWidth, blockWidth * 0.42),
            availableWidth
        )
        let draggingWidth = min(
            moveHandleVisualWidth + 12,
            max(restingWidth, blockWidth * 0.52),
            availableWidth
        )
        return ZStack {
            Color.white.opacity(0.001)
            Capsule()
                .fill(Color.accentColor.opacity(dragging ? 1.0 : 0.82))
                .frame(
                    width: dragging ? draggingWidth : restingWidth,
                    height: dragging ? moveHandleVisualHeight + 1 : moveHandleVisualHeight
                )
                .shadow(color: .accentColor.opacity(dragging ? 0.45 : 0), radius: dragging ? 5 : 0)
                .shadow(color: .black.opacity(dragging ? 0.16 : 0), radius: dragging ? 4 : 0, y: dragging ? 2 : 0)
        }
        .contentShape(Rectangle())
        .animation(.spring(response: 0.2, dampingFraction: 0.72), value: dragging)
        .onHover { hovering in
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
    }

    private func handleHitArea(selected: Bool, dragging: Bool) -> some View {
        ZStack {
            Color.white.opacity(0.001)
            Capsule()
                .fill(Color.accentColor.opacity(dragging ? 1.0 : (selected ? 0.95 : 0.7)))
                .frame(width: dragging ? handleVisualWidth + 2 : handleVisualWidth, height: cueHeight)
                .shadow(color: .accentColor.opacity(dragging ? 0.55 : 0), radius: dragging ? 4 : 0)
        }
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: dragging)
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
                var noAnimation = Transaction()
                noAnimation.animation = nil
                noAnimation.disablesAnimations = true
                withTransaction(noAnimation) {
                    isHandleDragging = true
                    if dragSession?.cueID != cue.wrappedValue.id || dragSession?.edge != edge {
                        onCueTimingEditBegan()
                        selectedCueID = cue.wrappedValue.id
                        dragSession = HandleDragSession(
                            cueID: cue.wrappedValue.id,
                            edge: edge,
                            snapIndex: TimelineSnapIndex(cues: cues, excluding: cue.wrappedValue.id),
                            wordIndex: TimelineSnapIndex(times: wordBoundaryTimes(for: cue.wrappedValue)),
                            initialStart: cue.wrappedValue.start,
                            initialEnd: cue.wrappedValue.end
                        )
                    }
                    guard let session = dragSession else { return }
                    let delta = Double(value.translation.width / max(width, 1)) * duration
                    let rawTarget: Double
                    switch edge {
                    case .start:
                        rawTarget = session.initialStart + delta
                    case .end:
                        rawTarget = session.initialEnd + delta
                    }
                    let snapResult = snappedTime(
                        rawTarget,
                        index: session.snapIndex,
                        width: width,
                        words: session.wordIndex
                    )
                    if snapResult.didSnap && !session.isSnapped {
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    }
                    dragSession?.isSnapped = snapResult.didSnap
                    let current = cue.wrappedValue
                    let start: Double, end: Double
                    switch edge {
                    case .start:
                        start = max(0, min(snapResult.time, current.end - 0.05))
                        end = current.end
                    case .end:
                        let upper = duration > 0 ? duration : snapResult.time
                        start = current.start
                        end = max(current.start + 0.05, min(upper, snapResult.time))
                    }
                    if let updated = SubtitleCueTimingUpdate.updated(current, start: start, end: end) {
                        cue.wrappedValue = updated
                    }
                }
            }
            .onEnded { _ in
                dragSession = nil
                isHandleDragging = false
                if let normalized = SubtitleDocument.normalizedIfNeeded(cues) { cues = normalized }
                onCueTimingEditEnded()
            }
    }

    private func moveCueGesture(for cue: Binding<SubtitleCue>, width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if moveSession?.cueID != cue.wrappedValue.id {
                    onCueTimingEditBegan()
                    selectedCueID = cue.wrappedValue.id
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.74)) {
                        moveSession = CueMoveSession(
                            cueID: cue.wrappedValue.id,
                            snapIndex: TimelineSnapIndex(cues: cues, excluding: cue.wrappedValue.id),
                            initialStart: cue.wrappedValue.start,
                            initialEnd: cue.wrappedValue.end
                        )
                    }
                }

                var noAnimation = Transaction()
                noAnimation.animation = nil
                noAnimation.disablesAnimations = true
                withTransaction(noAnimation) {
                    isHandleDragging = true
                    guard let session = moveSession else { return }
                    let cueDuration = max(0.05, session.initialEnd - session.initialStart)
                    let delta = Double(value.translation.width / max(width, 1)) * duration
                    let upperStart = max(0, duration - cueDuration)
                    let rawStart = clamp(session.initialStart + delta, 0, upperStart)
                    let snapResult = snappedCueMove(
                        start: rawStart,
                        end: rawStart + cueDuration,
                        index: session.snapIndex,
                        width: width
                    )
                    if snapResult.didSnap && !session.isSnapped {
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    }
                    moveSession?.isSnapped = snapResult.didSnap
                    if let updated = SubtitleCueTimingUpdate.updated(
                        cue.wrappedValue, start: snapResult.start, end: snapResult.end
                    ) {
                        cue.wrappedValue = updated
                    }
                }
            }
            .onEnded { _ in
                withAnimation(.spring(response: 0.22, dampingFraction: 0.78)) {
                    moveSession = nil
                }
                isHandleDragging = false
                if let normalized = SubtitleDocument.normalizedIfNeeded(cues) { cues = normalized }
                onCueTimingEditEnded()
            }
    }

    /// Returns `target` snapped to the nearest other cue edge within ~5px on screen,
    /// plus a flag indicating whether the snap engaged. Caller is responsible for firing
    /// haptic only on the snap-engagement transition.
    ///
    /// Indexed word-level timestamps of the dragged cue act as a
    /// secondary snap target with a tighter threshold: cue edges always win,
    /// so the existing cue-block snapping behavior is unchanged.
    private func snappedTime(
        _ target: Double,
        index: TimelineSnapIndex,
        width: CGFloat,
        words: TimelineSnapIndex
    ) -> (time: Double, didSnap: Bool) {
        let secondsPerPixel = duration / Double(max(width, 1))
        if let edge = index.snappedTime(target, threshold: secondsPerPixel * 5) {
            return (edge, true)
        }
        if let word = words.snappedTime(target, threshold: secondsPerPixel * 4) {
            return (word, true)
        }
        return (target, false)
    }

    private func wordBoundaryTimes(for cue: SubtitleCue) -> [Double] {
        guard let words = cue.words, !words.isEmpty else { return [] }
        var times: Set<Double> = []
        for word in words {
            times.insert(word.start)
            times.insert(word.end)
        }
        return times.filter(\.isFinite).sorted()
    }

    /// Thin tick marks at word starts inside the selected cue block. Rendered
    /// with a single Canvas (no per-word views) and skipped entirely when the
    /// zoom level would make ticks denser than ~6 px apart.
    @ViewBuilder
    private func wordTickMarks(for cue: SubtitleCue, startX: CGFloat, endX: CGFloat, width: CGFloat) -> some View {
        let boundaries = interiorWordTickTimes(for: cue)
        let cueWidth = max(2, endX - startX)
        if !boundaries.isEmpty, cueWidth / CGFloat(boundaries.count + 1) >= 6 {
            Canvas { context, size in
                for time in boundaries {
                    let x = xPosition(time, width: width) - startX
                    guard x > 2, x < cueWidth - 2 else { continue }
                    let tick = CGRect(x: x - 0.5, y: size.height * 0.3, width: 1, height: size.height * 0.4)
                    context.fill(Path(tick), with: .color(Color.accentColor.opacity(0.55)))
                }
            }
            .frame(width: cueWidth, height: cueHeight)
            .offset(x: startX)
            .allowsHitTesting(false)
        }
    }

    private func interiorWordTickTimes(for cue: SubtitleCue) -> [Double] {
        guard let words = cue.words, words.count > 1 else { return [] }
        return words.dropFirst().map(\.start)
    }

    private func snappedCueMove(
        start: Double,
        end: Double,
        index: TimelineSnapIndex,
        width: CGFloat
    ) -> (start: Double, end: Double, didSnap: Bool) {
        let cueDuration = max(0.05, end - start)
        let upperStart = max(0, duration - cueDuration)
        let clampedStart = clamp(start, 0, upperStart)
        let clampedEnd = clampedStart + cueDuration
        let snapPixels: CGFloat = 5
        let secondsPerPixel = duration / Double(max(width, 1))
        let threshold = secondsPerPixel * Double(snapPixels)
        if let bestStart = index.snappedStart(start: clampedStart, end: clampedEnd, threshold: threshold) {
            let snappedStart = clamp(bestStart, 0, upperStart)
            return (snappedStart, snappedStart + cueDuration, true)
        }
        return (clampedStart, clampedEnd, false)
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

    private func cueFillColor(selected: Bool, speakerMatched: Bool, hovered: Bool = false) -> Color {
        if selected {
            return Color.accentColor.opacity(speakerMatched ? 0.36 : 0.28)
        }
        let base = speakerMatched ? 0.34 : 0.22
        let hoverBoost = hovered ? 0.16 : 0.0
        return Color.teal.opacity(base + hoverBoost)
    }

    private func cueStrokeColor(selected: Bool, speakerMatched: Bool) -> Color {
        if selected {
            return Color.accentColor
        }
        return Color.teal.opacity(speakerMatched ? 0.75 : 0.55)
    }

    private func speakerMatchesActive(_ cue: SubtitleCue) -> Bool {
        guard let activeSpeakerName else { return false }
        return SubtitleDocument.normalizedSpeakerName(cue.speaker) == activeSpeakerName
    }

    private func speakerColor(for cue: SubtitleCue) -> Color? {
        guard let speaker = SubtitleDocument.normalizedSpeakerName(cue.speaker),
              let hex = speakerColors[speaker] else {
            return nil
        }
        return TimelineSpeakerColor.color(fromHex: hex)
    }

    private func clamp(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        if upper <= lower { return lower }
        return min(max(value, lower), upper)
    }
}

enum TimelineSpeakerColor {
    static func color(fromHex raw: String) -> Color? {
        let hex = raw.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
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
