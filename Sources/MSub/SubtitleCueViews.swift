import AppKit
import SwiftUI

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

struct SpeakerBadge: View {
    let speaker: String?
    let language: AppLanguage

    var body: some View {
        Label(displayName, systemImage: speaker == nil ? "person.crop.circle" : "person.crop.circle.fill")
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(badgeFill, in: Capsule())
            .overlay(Capsule().stroke(.quaternary, lineWidth: 0.7))
            .foregroundStyle(speaker == nil ? .secondary : .primary)
    }

    private var displayName: String {
        speaker ?? Copy.text("editor.speaker.none", language: language)
    }

    private var badgeFill: some ShapeStyle {
        speaker == nil ? AnyShapeStyle(.quinary) : AnyShapeStyle(.thinMaterial)
    }
}

struct SubtitleBatchEditSheet: View {
    let cues: [SubtitleCue]
    let speakerColors: [String: String]
    let speakerNames: [String]
    let language: AppLanguage
    let isCurrent: Bool
    let apply: (SubtitleBatchEdit.Operation) -> Void
    @State private var mode = "time"
    @State private var seconds = 0.0
    @State private var speaker = ""
    @State private var style = "b"
    @State private var scope: SubtitleCueStyle.Scope = .all
    @State private var color = Color.yellow
    @Environment(\.dismiss) private var dismiss

    private func t(_ key: String) -> String { Copy.text(key, language: language) }

    private var operation: SubtitleBatchEdit.Operation {
        switch mode {
        case "time": return .shift(seconds)
        case "speaker": return .speaker(speaker)
        default:
            switch style {
            case "clear": return .clearStyle(scope)
            case "color":
                let rgb = NSColor(color).usingColorSpace(.sRGB) ?? .systemYellow
                let hex = String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                                 Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
                return .color(hex, scope)
            default: return .addTag(style, scope)
            }
        }
    }

    var body: some View {
        let result = SubtitleBatchEdit.applying(operation, to: cues, speakerColors: speakerColors)
        let changed = result.map { values in zip(cues, values).filter { $0 != $1 }.map { $1 } } ?? []
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(t("editor.batch.title")).font(.headline)
                Spacer()
                Text(String(format: t("editor.batch.count"), cues.count)).foregroundStyle(.secondary)
            }
            Picker(t("editor.batch.operation"), selection: $mode) {
                ForEach(["time", "speaker", "style"], id: \.self) { key in
                    Text(t("editor.batch." + key)).tag(key)
                }
            }
            .pickerStyle(.segmented)
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    switch mode {
                    case "time":
                        LabeledContent(t("editor.batch.seconds")) {
                            TextField(t("editor.batch.seconds"), value: $seconds, format: .number.precision(.fractionLength(3)))
                                .textFieldStyle(.roundedBorder).frame(width: 130).monospacedDigit()
                        }
                        Text(t("editor.batch.timeHelp")).font(.caption).foregroundStyle(.secondary)
                    case "speaker":
                        HStack {
                            TextField(t("editor.batch.speaker"), text: $speaker).textFieldStyle(.roundedBorder)
                            Menu(t("editor.batch.existing")) {
                                ForEach(speakerNames, id: \.self) { name in
                                    Button(name) { speaker = name }
                                }
                            }
                            .fixedSize()
                        }
                        Text(t("editor.batch.speakerHelp")).font(.caption).foregroundStyle(.secondary)
                    default:
                        Picker(t("editor.batch.style"), selection: $style) {
                            ForEach(["b", "i", "u", "color", "clear"], id: \.self) { key in
                                Text(t("editor.batch.style." + key)).tag(key)
                            }
                        }
                        Picker(t("editor.style.scope"), selection: $scope) {
                            ForEach(SubtitleCueStyle.Scope.allCases) { scope in
                                Text(t(scope.titleKey)).tag(scope)
                            }
                        }
                        if style == "color" {
                            ColorPicker(t("editor.batch.style.color"), selection: $color, supportsOpacity: false)
                        }
                        Text(t("editor.batch.styleHelp")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
            if !isCurrent {
                Text(t("editor.batch.stale")).foregroundStyle(.orange)
            } else if result == nil {
                Text(t("editor.batch.invalidTime")).foregroundStyle(.red)
            }
            Text(String(format: t("editor.batch.preview"), changed.count)).font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(changed.prefix(5)) { cue in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("#\(cue.index)").font(.caption.monospacedDigit())
                                    Text(cue.speaker ?? t("editor.speaker.none")).font(.caption)
                                    Spacer()
                                    Text(SubtitleDocument.displayTime(cue.start) + " → " + SubtitleDocument.displayTime(cue.end))
                                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                }
                                StyledSubtitleText(cue.text)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button(t("button.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(t("button.apply")) {
                    guard isCurrent, result != nil, !changed.isEmpty else { return }
                    apply(operation)
                    dismiss()
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(!isCurrent || result == nil || changed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 560, height: 560)
    }
}

struct SubtitleSplitSheet: View {
    let cue: SubtitleCue
    let time: Double
    let language: AppLanguage
    let isCurrent: Bool
    let apply: (Int, Int?) -> Void
    private let source: SubtitleCueSplit.FormattedText?
    private let translation: SubtitleCueSplit.FormattedText?
    @State private var sourceOffset: Int?
    @State private var translationOffset: Int?
    @Environment(\.dismiss) private var dismiss

    init(cue: SubtitleCue, time: Double, language: AppLanguage, isCurrent: Bool,
         apply: @escaping (Int, Int?) -> Void) {
        self.cue = cue
        self.time = time
        self.language = language
        self.isCurrent = isCurrent
        self.apply = apply
        source = .init(cue.translationSourceText)
        translation = cue.bilingualText.flatMap { .init($0.translation) }
        _sourceOffset = State(initialValue: source?.plain.isEmpty == true ? 0
            : SubtitleCueSplit.suggestedSourceOffset(cue, at: time))
        _translationOffset = State(initialValue: translation?.plain.isEmpty == true ? 0 : nil)
    }

    private func t(_ key: String) -> String { Copy.text(key, language: language) }

    private var preview: (SubtitleCue, SubtitleCue)? {
        guard let sourceOffset else { return nil }
        return SubtitleCueSplit.split(cue, at: time, sourceOffset: sourceOffset,
                                     translationOffset: translationOffset)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("editor.split.title")).font(.headline)
            Text(t("editor.split.help"))
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent(t("editor.split.time"), value: SubtitleDocument.displayTime(time))
                .monospacedDigit()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let source, cue.bilingualText == nil || translation != nil {
                        boundaryControl(source, title: t("bilingual.source"), offset: $sourceOffset)
                        if let translation {
                            boundaryControl(translation, title: t("bilingual.translation"), offset: $translationOffset)
                        }
                        if let (first, second) = preview {
                            HStack(alignment: .top, spacing: 12) {
                                previewCard(first, title: t("editor.split.first"))
                                previewCard(second, title: t("editor.split.second"))
                            }
                        } else {
                            Text(t("editor.split.choose"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text(t("editor.split.markup"))
                            .foregroundStyle(.secondary)
                    }
                    if !isCurrent {
                        Text(t("editor.split.stale")).foregroundStyle(.orange)
                    }
                }
            }
            HStack {
                Spacer()
                Button(t("button.cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(t("editor.split.apply")) {
                    guard isCurrent, preview != nil, let sourceOffset else { return }
                    apply(sourceOffset, translationOffset)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isCurrent || preview == nil)
            }
            .controlSize(.regular)
        }
        .padding(20)
        .frame(width: 600, height: cue.bilingualText == nil ? 480 : 620)
    }

    private func boundaryControl(_ text: SubtitleCueSplit.FormattedText, title: String,
                                 offset: Binding<Int?>) -> some View {
        let count = text.plain.count
        let value = Binding<Int>(get: { offset.wrappedValue ?? 0 }, set: { offset.wrappedValue = $0 })
        let position = text.plain.index(text.plain.startIndex, offsetBy: min(count, max(0, value.wrappedValue)))
        return GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if count == 0 {
                    Text(t("editor.split.empty")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("\(String(text.plain[..<position]))\(Text(" │ ").foregroundStyle(Color(nsColor: .controlAccentColor)).bold())\(String(text.plain[position...]))")
                    HStack {
                        Slider(value: Binding(get: { Double(value.wrappedValue) },
                                              set: { value.wrappedValue = Int($0.rounded()) }),
                               in: 0...Double(count), step: 1)
                            .accessibilityLabel(title)
                            .accessibilityValue("\(value.wrappedValue) / \(count)")
                        Stepper("\(value.wrappedValue) / \(count)", value: value, in: 0...count)
                            .monospacedDigit().fixedSize()
                            .accessibilityLabel(title + " " + t("editor.split.position"))
                        if offset.wrappedValue == nil {
                            Button(t("editor.split.usePosition")) { offset.wrappedValue = value.wrappedValue }
                        }
                    }
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    private func previewCard(_ cue: SubtitleCue, title: String) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.caption.weight(.semibold))
                Text(SubtitleDocument.displayTime(cue.start) + " → " + SubtitleDocument.displayTime(cue.end))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                StyledSubtitleText(cue.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }
}

struct TimingAdjustmentSheet: View {
    let language: AppLanguage
    let cueCount: Int
    @Binding var mode: TimingAdjustmentMode
    @Binding var shiftSeconds: Double
    @Binding var gapSeconds: Double
    let apply: () -> Void
    let cues: [SubtitleCue]
    let calibrate: (SubtitleTimingCalibration) -> Void
    @State private var calibration = SubtitleTimingCalibration()

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let preview = calibrationPreview
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Copy.text("timing.title", language: language))
                    .font(.headline)
                Text(String(format: Copy.text("timing.cueCount", language: language), cueCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Picker("", selection: $mode) {
                Text(Copy.text("timing.mode.shift", language: language)).tag(TimingAdjustmentMode.shift)
                Text(Copy.text("timing.mode.closeGaps", language: language)).tag(TimingAdjustmentMode.closeGaps)
                Text(Copy.text("timing.mode.calibrate", language: language)).tag(TimingAdjustmentMode.calibrate)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    switch mode {
                    case .shift:
                        secondsControl(
                            titleKey: "timing.shift.seconds",
                            helpKey: "timing.shift.help",
                            value: $shiftSeconds,
                            range: -86_400...86_400
                        )
                    case .closeGaps:
                        secondsControl(
                            titleKey: "timing.gap.seconds",
                            helpKey: "timing.gap.help",
                            value: $gapSeconds,
                            range: 0...60
                        )
                    case .calibrate:
                        calibrationControls(preview: preview)
                    }
                }
                .padding(.vertical, 4)
            }

            HStack {
                Spacer()
                Button(Copy.text("button.cancel", language: language)) {
                    dismiss()
                }
                Button(Copy.text("button.apply", language: language)) {
                    if mode == .calibrate { calibrate(calibration) }
                    else { apply() }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(cueCount == 0 || (mode == .calibrate && (try? preview.get()) == nil))
            }
        }
        .padding(20)
        .frame(width: mode == .calibrate ? 540 : 380)
        .onAppear {
            let valid = cues.filter { $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }
            if let first = valid.map(\.start).min(), let last = valid.map(\.end).max() {
                calibration = .init(sourceFirst: first, targetFirst: first, sourceLast: last, targetLast: last)
            }
        }
    }

    private var calibrationPreview: Result<[SubtitleCue], SubtitleTimingCalibration.Failure> {
        guard mode == .calibrate else { return .success([]) }
        do { return .success(try calibration.applying(to: cues)) }
        catch let error as SubtitleTimingCalibration.Failure { return .failure(error) }
        catch { return .failure(.result) }
    }

    private func calibrationControls(preview: Result<[SubtitleCue], SubtitleTimingCalibration.Failure>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Copy.text("timing.calibration.help", language: language))
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Color.clear.frame(width: 1, height: 1)
                    Text(Copy.text("timing.calibration.source", language: language))
                    Text(Copy.text("timing.calibration.target", language: language))
                }
                calibrationRow("timing.calibration.first", source: $calibration.sourceFirst, target: $calibration.targetFirst)
                calibrationRow("timing.calibration.last", source: $calibration.sourceLast, target: $calibration.targetLast)
            }
            .font(.caption)
            switch preview {
            case .failure(let error):
                Label(Copy.text(error.rawValue, language: language), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .success(let adjusted):
                if let scale = calibration.scale {
                    HStack {
                        Text(Copy.text("timing.calibration.scale", language: language))
                        Text(scale, format: .percent.precision(.fractionLength(3))).monospacedDigit()
                    }.font(.caption)
                }
                Text(Copy.text("timing.calibration.preview", language: language)).font(.caption.bold())
                ForEach(previewIndices(count: adjusted.count), id: \.self) { index in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("#\(cues[index].index) · \(cues[index].text.replacingOccurrences(of: "\n", with: " "))")
                            .lineLimit(1)
                        Text("\(rangeText(cues[index])) → \(rangeText(adjusted[index]))")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }.font(.caption)
                }
            }
            Text(Copy.text("timing.calibration.scope", language: language))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func calibrationRow(_ key: String, source: Binding<Double>, target: Binding<Double>) -> some View {
        GridRow {
            Text(Copy.text(key, language: language))
            TextField(Copy.text("timing.calibration.source", language: language), value: source,
                      format: .number.precision(.fractionLength(0...3)))
                .textFieldStyle(.roundedBorder)
            TextField(Copy.text("timing.calibration.target", language: language), value: target,
                      format: .number.precision(.fractionLength(0...3)))
                .textFieldStyle(.roundedBorder)
        }
    }

    private func previewIndices(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        return Array(Set([0, count / 2, count - 1])).sorted()
    }

    private func rangeText(_ cue: SubtitleCue) -> String {
        String(format: "%.3f–%.3f s", cue.start, cue.end)
    }

    private func secondsControl(
        titleKey: String,
        helpKey: String,
        value: Binding<Double>,
        range: ClosedRange<Double>
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Copy.text(titleKey, language: language))
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 8) {
                TextField("", value: value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 96)
                Stepper("", value: value, in: range, step: 0.1)
                    .labelsHidden()
                Text("s")
                    .foregroundStyle(.secondary)
            }
            Text(Copy.text(helpKey, language: language))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct CueStatusBadges: View {
    struct EditedFields: Equatable {
        var text: Bool = false
        var time: Bool = false
        var speaker: Bool = false
    }

    let cue: SubtitleCue
    let canReset: Bool
    let language: AppLanguage
    var showsSpeaker: Bool = true
    var onReset: (() -> Void)? = nil
    var editedFields: EditedFields = .init()
    var speakerColor: Color? = nil
    var onCycleSpeaker: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 4) {
            if canReset {
                if let onReset {
                    EditedResetBadge(language: language, fields: editedFields, onReset: onReset)
                } else {
                    iconBadge(
                        systemImage: "pencil",
                        title: Copy.text("cue.edited", language: language),
                        tint: .accentColor
                    )
                }
            }
            if isEmptyText {
                iconBadge(
                    systemImage: "text.badge.xmark",
                    title: Copy.text("cue.empty", language: language),
                    tint: .red
                )
            }
            if showsSpeaker, let speaker {
                speakerBadge(speaker)
            }
            if isLowConfidence {
                iconBadge(
                    systemImage: "questionmark.circle.fill",
                    title: Copy.text("cue.lowConfidence", language: language),
                    tint: .orange
                )
            }
        }
        .animation(.easeInOut(duration: 0.12), value: canReset)
        .animation(.easeInOut(duration: 0.12), value: cue.text)
        .animation(.easeInOut(duration: 0.12), value: cue.confidence)
        .animation(.easeInOut(duration: 0.12), value: cue.speaker)
    }

    private var isEmptyText: Bool {
        cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isLowConfidence: Bool {
        guard let confidence = cue.confidence else { return false }
        return confidence < SubtitleConfidence.lowThreshold
    }

    private var speaker: String? {
        SubtitleDocument.normalizedSpeakerName(cue.speaker)
    }

    private func iconBadge(systemImage: String, title: String, tint: Color) -> some View {
        Image(systemName: systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: 18, height: 18)
            .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            .help(title)
            .accessibilityLabel(title)
            .transition(.scale.combined(with: .opacity))
    }

    private func speakerBadge(_ speaker: String) -> some View {
        let title = String(format: Copy.text("cue.speakerAssigned", language: language), speaker)
        let helpText = onCycleSpeaker != nil
            ? "\(title) — \(Copy.text("cue.speaker.cycleHint", language: language))"
            : title
        let background: AnyShapeStyle = speakerColor.map { AnyShapeStyle($0.opacity(0.18)) } ?? AnyShapeStyle(.quaternary)
        let content = Label(speaker, systemImage: "person.crop.circle.fill")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 74, alignment: .leading)
            .padding(.horizontal, 5)
            .frame(height: 18)
            .background(background, in: RoundedRectangle(cornerRadius: 4))

        return Group {
            if let onCycleSpeaker {
                Button(action: onCycleSpeaker) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
        .help(helpText)
        .accessibilityLabel(helpText)
        .transition(.scale.combined(with: .opacity))
    }
}

private struct EditedResetBadge: View {
    let language: AppLanguage
    let fields: CueStatusBadges.EditedFields
    let onReset: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "pencil")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.accentColor)
            if isHovered {
                if fields.text {
                    fieldChip(Copy.text("editor.edited.text", language: language))
                }
                if fields.time {
                    fieldChip(Copy.text("editor.edited.time", language: language))
                }
                if fields.speaker {
                    fieldChip(Copy.text("editor.edited.speaker", language: language))
                }
                Divider()
                    .frame(height: 10)
                Button(action: onReset) {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .help(Copy.text("editor.resetCue.help", language: language))
                .accessibilityLabel(Copy.text("editor.resetCue", language: language))
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 5)
        .frame(height: 18)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
        .help(Copy.text("cue.edited", language: language))
        .accessibilityLabel(Copy.text("cue.edited", language: language))
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.18)) {
                isHovered = hovering
            }
        }
    }

    private func fieldChip(_ title: String) -> some View {
        Text(title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(Color.accentColor)
            .lineLimit(1)
            .fixedSize()
            .transition(.opacity.combined(with: .move(edge: .trailing)))
    }
}

// Keep action closures outside these value-only leaves so menus always receive
// current callbacks, while unrelated row/playback changes skip formatting work.
private struct SubtitleCueRowTime: View, Equatable {
    let index: Int
    let start: Double
    let end: Double
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("#\(index)")
                .font(.caption.monospacedDigit().bold())
                .foregroundStyle(isSelected ? .primary : .secondary)
            Text("\(SubtitleDocument.displayTime(start)) -> \(SubtitleDocument.displayTime(end))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

private struct SubtitleCueRowDuration: View, Equatable {
    let duration: Double

    var body: some View {
        Text(String(format: "%.2fs", duration))
            .font(.caption.monospacedDigit())
            .foregroundStyle(.tertiary)
    }
}

private struct SubtitleCueRowText: View, Equatable {
    let text: String
    let speaker: String?

    var body: some View {
        StyledSubtitleText(SubtitleDocument.displayText(text: text, speaker: speaker), font: .body, lineLimit: nil)
            .equatable()
    }
}

struct SubtitleCueBlockRow: View {
    let cue: SubtitleCue
    let isSelected: Bool
    let canReset: Bool
    let select: () -> Void
    let reset: () -> Void
    let duplicate: () -> Void
    let insertBefore: () -> Void
    let insertAfter: () -> Void
    let closeGap: () -> Void
    let delete: () -> Void
    let deleteMatching: () -> Void
    let language: AppLanguage
    var speakerColor: Color? = nil
    var cycleSpeaker: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SubtitleCueRowTime(index: cue.index, start: cue.start, end: cue.end, isSelected: isSelected)
                    .equatable()
                Spacer()
                CueStatusBadges(
                    cue: cue,
                    canReset: canReset,
                    language: language,
                    speakerColor: speakerColor,
                    onCycleSpeaker: cycleSpeaker
                )
                SubtitleCueRowDuration(duration: cue.duration)
                    .equatable()
            }

            SubtitleCueRowText(text: cue.text, speaker: cue.speaker)
                .equatable()
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
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
                deleteMatching()
            } label: {
                Label(Copy.text("editor.deleteMatchingCues", language: language), systemImage: "trash.slash")
            }

            Button(role: .destructive) {
                delete()
            } label: {
                Label(Copy.text("editor.deleteCue", language: language), systemImage: "trash")
            }
        }
    }

    private var rowBackground: Color {
        isSelected ? Color.accentColor.opacity(0.14) : Color(nsColor: .controlBackgroundColor)
    }

}

enum SubtitleConfidence {
    static let lowThreshold: Double = 0.6
}

struct SelectableTextEditor: NSViewRepresentable {
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
        textView.allowsUndo = false
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

        @objc func undo(_ sender: Any?) {
            guard let undoManager = window?.undoManager, undoManager.canUndo else {
                NSSound.beep()
                return
            }
            undoManager.undo()
        }

        @objc func redo(_ sender: Any?) {
            guard let undoManager = window?.undoManager, undoManager.canRedo else {
                NSSound.beep()
                return
            }
            undoManager.redo()
        }
    }
}
