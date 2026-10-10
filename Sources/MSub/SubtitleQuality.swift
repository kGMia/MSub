import SwiftUI

struct SubtitleQualityIssue: Identifiable, Equatable, Sendable {
    enum Kind: String, CaseIterable, Sendable { case invalidTime, overlap, short, fast, longLine }
    let cueID: UUID
    let index: Int
    let kind: Kind
    var id: String { "\(cueID)-\(kind.rawValue)" }
}

enum SubtitleQuality {
    /// Stateless entry point for callers that do not keep a document cache.
    static func inspect(_ cues: [SubtitleCue], minimumDuration: Double,
                        maximumCPS: Double, maximumLineLength: Int) -> [SubtitleQualityIssue] {
        var cache = SubtitleQualityCache()
        return cache.inspect(cues, minimumDuration: minimumDuration,
                             maximumCPS: maximumCPS, maximumLineLength: maximumLineLength)
    }
}

struct SubtitleQualityCache: Sendable {
    private struct TextMetrics: Sendable {
        let text: String
        let characters: Int
        let longestLine: Int

        init(_ raw: String) {
            text = raw
            let plain = raw.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
            characters = plain.filter { !$0.isWhitespace }.count
            longestLine = plain.split(separator: "\n").map(\.count).max() ?? 0
        }
    }
    private var metrics: [UUID: TextMetrics] = [:]
    private(set) var parsedTextCount = 0
    var retainedTextCount: Int { metrics.count }

    mutating func inspect(_ cues: [SubtitleCue], minimumDuration: Double,
                          maximumCPS: Double, maximumLineLength: Int) -> [SubtitleQualityIssue] {
        guard !Task.isCancelled else { return [] }
        func precedes(_ a: SubtitleCue, _ b: SubtitleCue) -> Bool {
            let lhs = a.start.isFinite ? a.start : .infinity
            let rhs = b.start.isFinite ? b.start : .infinity
            return lhs == rhs ? a.index < b.index : lhs < rhs
        }
        // Normalized documents are already sorted. Still accept unordered inputs
        // and recompute overlaps globally, since an earlier cue can enclose many others.
        let sorted = zip(cues, cues.dropFirst()).allSatisfy { !precedes($1, $0) }
        let ordered = sorted ? cues : cues.sorted(by: precedes)
        var issues: [SubtitleQualityIssue] = []
        var nextMetrics: [UUID: TextMetrics] = [:]
        nextMetrics.reserveCapacity(cues.count)
        var parsed = 0
        var previousEnd = 0.0
        for cue in ordered {
            if Task.isCancelled { return [] }
            func append(_ kind: SubtitleQualityIssue.Kind) {
                issues.append(.init(cueID: cue.id, index: cue.index, kind: kind))
            }
            guard cue.start.isFinite, cue.end.isFinite, cue.start >= 0, cue.end > cue.start else {
                append(.invalidTime)
                continue
            }
            if cue.start < previousEnd - 0.001 { append(.overlap) }
            previousEnd = max(previousEnd, cue.end)
            let value: TextMetrics
            if let cached = metrics[cue.id], cached.text == cue.text {
                value = cached
            } else {
                value = TextMetrics(cue.text)
                parsed += 1
            }
            nextMetrics[cue.id] = value
            if value.characters > 0, cue.duration < minimumDuration { append(.short) }
            if Double(value.characters) / cue.duration > maximumCPS { append(.fast) }
            if value.longestLine > maximumLineLength { append(.longLine) }
        }
        guard !Task.isCancelled else { return [] }
        metrics = nextMetrics // Deleted cues cannot accumulate in the cache.
        parsedTextCount = parsed
        return issues
    }
}

actor SubtitleQualityScanner {
    private var cache = SubtitleQualityCache()

    func inspect(_ cues: [SubtitleCue], minimumDuration: Double,
                 maximumCPS: Double, maximumLineLength: Int) -> [SubtitleQualityIssue] {
        cache.inspect(cues, minimumDuration: minimumDuration,
                      maximumCPS: maximumCPS, maximumLineLength: maximumLineLength)
    }
}

/// A resolved finding leaves a gap in the review sequence. The next command
/// visits the successor rather than skipping it or seeking during text editing.
struct SubtitleQualityNavigation {
    var focusedID: String?
    private(set) var nextIndex = 0
    private var nextID: String?

    static func filtered(_ issues: [SubtitleQualityIssue], kind: SubtitleQualityIssue.Kind?) -> [SubtitleQualityIssue] {
        guard let kind else { return issues }
        return issues.filter { $0.kind == kind }
    }

    func destination(in issues: [SubtitleQualityIssue], forward: Bool) -> SubtitleQualityIssue? {
        let index: Int
        if let focusedID, let current = issues.firstIndex(where: { $0.id == focusedID }) {
            index = current + (forward ? 1 : -1)
        } else {
            index = forward ? nextIndex : min(nextIndex, issues.count) - 1
        }
        return issues.indices.contains(index) ? issues[index] : nil
    }

    mutating func focus(_ issue: SubtitleQualityIssue) {
        focusedID = issue.id
        nextID = nil
        nextIndex = 0
    }

    mutating func follow(cueID: UUID?, in issues: [SubtitleQualityIssue]) {
        if let focusedID, issues.contains(where: { $0.id == focusedID && $0.cueID == cueID }) { return }
        focusedID = issues.first(where: { $0.cueID == cueID })?.id
        nextID = nil
        nextIndex = 0
    }

    mutating func reconcile(previous: [SubtitleQualityIssue], current: [SubtitleQualityIssue]) {
        if let focusedID, current.contains(where: { $0.id == focusedID }) { return }
        if focusedID == nil, let nextID, let index = current.firstIndex(where: { $0.id == nextID }) {
            nextIndex = index
            return
        }
        guard let anchorID = focusedID ?? nextID, let oldIndex = previous.firstIndex(where: { $0.id == anchorID }) else {
            nextIndex = min(nextIndex, current.count)
            return
        }
        self.focusedID = nil
        let positions = Dictionary(uniqueKeysWithValues: current.enumerated().map { ($0.element.id, $0.offset) })
        if let successor = previous.dropFirst(oldIndex + 1).compactMap({ positions[$0.id] }).first {
            nextIndex = successor
            nextID = current[successor].id
        } else if previous.prefix(oldIndex).contains(where: { positions[$0.id] != nil }) {
            nextIndex = current.count
            nextID = nil
        } else {
            nextIndex = 0
            nextID = current.first?.id
        }
    }

    static let pageSize = 50
    static func pageRange(page: Int, count: Int) -> Range<Int> {
        let safeCount = max(0, count)
        let last = max(0, (safeCount - 1) / pageSize)
        let start = min(max(0, page), last) * pageSize
        return start..<min(start + pageSize, safeCount)
    }
}

struct SubtitleQualityPanel: View {
    let cues: [SubtitleCue]
    let cuesRevision: UUID
    let selectedCueID: UUID?
    let language: AppLanguage
    let select: (UUID) -> Void
    @State private var expanded = false
    @State private var issues: [SubtitleQualityIssue] = []
    @State private var filter: SubtitleQualityIssue.Kind?
    @State private var navigation = SubtitleQualityNavigation()
    @State private var page = 0
    @State private var showThresholds = false
    @State private var completedRequest: Request?
    @State private var scanner = SubtitleQualityScanner()
    @AppStorage("msub.quality.maximumCPS") private var maximumCPS = 12.0
    @AppStorage("msub.quality.minimumDuration") private var minimumDuration = 0.6
    @AppStorage("msub.quality.maximumLineLength") private var maximumLineLength = 40

    private struct Request: Equatable, Sendable {
        let revision: UUID
        let cps: Double
        let duration: Double
        let lineLength: Int
        let expanded: Bool
    }

    private var request: Request {
        Request(revision: cuesRevision, cps: maximumCPS, duration: minimumDuration,
                lineLength: maximumLineLength, expanded: expanded)
    }

    var body: some View {
        let currentRequest = request
        let checking = completedRequest != currentRequest
        let visible = SubtitleQualityNavigation.filtered(issues, kind: filter)
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Picker(text("quality.filter"), selection: $filter) {
                        Text(text("quality.all")).tag(SubtitleQualityIssue.Kind?.none)
                        ForEach(SubtitleQualityIssue.Kind.allCases, id: \.self) { kind in
                            Text(text("quality." + kind.rawValue)).tag(Optional(kind))
                        }
                    }
                    .labelsHidden()
                    Spacer(minLength: 0)
                    Button { showThresholds.toggle() } label: {
                        Label(text("quality.thresholds"), systemImage: "slider.horizontal.3").labelStyle(.iconOnly)
                    }
                    .help(text("quality.thresholds"))
                    .popover(isPresented: $showThresholds) { thresholds }
                }
                if checking {
                    Text(text("quality.checking")).foregroundStyle(.secondary)
                } else if issues.isEmpty {
                    Text(text("quality.clear")).foregroundStyle(.secondary)
                } else if visible.isEmpty {
                    Text(text("quality.filterEmpty")).foregroundStyle(.secondary)
                } else {
                    reviewControls(visible)
                    issueList(visible)
                    Text(String(format: text("quality.filteredCount"), visible.count, issues.count))
                        .foregroundStyle(.secondary)
                    if visible.count > SubtitleQualityNavigation.pageSize {
                        Picker(text("quality.page"), selection: $page) {
                            ForEach(0..<((visible.count - 1) / SubtitleQualityNavigation.pageSize + 1), id: \.self) { number in
                                Text(String(format: text("quality.pageNumber"), number + 1)).tag(number)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }
            }
            .font(.caption)
            .msubCompactActions()
            .padding(.top, 6)
        } label: {
            Label(text("quality.title"), systemImage: "checklist")
                .font(.caption.weight(.semibold))
        }
        .padding(10)
        .msubPanel(cornerRadius: 8)
        .onChange(of: filter) { _, _ in
            let filtered = SubtitleQualityNavigation.filtered(issues, kind: filter)
            navigation = SubtitleQualityNavigation()
            navigation.follow(cueID: selectedCueID, in: filtered)
            revealFocused(in: filtered)
        }
        .onChange(of: selectedCueID) { _, cueID in
            let filtered = SubtitleQualityNavigation.filtered(issues, kind: filter)
            navigation.follow(cueID: cueID, in: filtered)
            revealFocused(in: filtered)
        }
        .task(id: currentRequest) {
            guard currentRequest.expanded, completedRequest != currentRequest else { return }
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            let snapshot = cues
            let scanner = scanner
            let task = Task.detached(priority: .utility) {
                await scanner.inspect(snapshot, minimumDuration: currentRequest.duration,
                                      maximumCPS: currentRequest.cps, maximumLineLength: currentRequest.lineLength)
            }
            let findings = await withTaskCancellationHandler {
                await task.value
            } onCancel: { task.cancel() }
            guard !Task.isCancelled else { return }
            let previous = SubtitleQualityNavigation.filtered(issues, kind: filter)
            let updated = SubtitleQualityNavigation.filtered(findings, kind: filter)
            if completedRequest == nil {
                navigation.follow(cueID: selectedCueID, in: updated)
            } else {
                navigation.reconcile(previous: previous, current: updated)
            }
            issues = findings
            completedRequest = currentRequest
            revealFocused(in: updated)
        }
    }

    private var thresholds: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text("quality.thresholds")).font(.headline)
            Stepper(value: $maximumCPS, in: 4...40, step: 1) {
                Text("\(text("quality.cps")): \(Int(maximumCPS))")
            }
            Stepper(value: $minimumDuration, in: 0.1...3, step: 0.1) {
                Text("\(text("quality.duration")): \(minimumDuration.formatted(.number.precision(.fractionLength(1)))) s")
            }
            Stepper(value: $maximumLineLength, in: 10...100, step: 2) {
                Text("\(text("quality.lineLength")): \(maximumLineLength)")
            }
            Text(text("quality.advisory")).font(.caption).foregroundStyle(.secondary)
        }
        .padding(16).frame(width: 280).controlSize(.small)
    }

    private func reviewControls(_ visible: [SubtitleQualityIssue]) -> some View {
        HStack(spacing: 6) {
            Button { navigate(in: visible, forward: false) } label: {
                Label(text("quality.previous"), systemImage: "chevron.up").labelStyle(.iconOnly)
            }
            .help(text("quality.previous"))
            .disabled(navigation.destination(in: visible, forward: false) == nil)
            Button { navigate(in: visible, forward: true) } label: {
                Label(text("quality.next"), systemImage: "chevron.down").labelStyle(.iconOnly)
            }
            .help(text("quality.next"))
            .disabled(navigation.destination(in: visible, forward: true) == nil)
            Spacer(minLength: 0)
            if let index = visible.firstIndex(where: { $0.id == navigation.focusedID }) {
                Text("\(index + 1) / \(visible.count)").monospacedDigit().foregroundStyle(.secondary)
            } else {
                Text(text("quality.ready")).foregroundStyle(.secondary)
            }
        }
    }

    private func issueList(_ visible: [SubtitleQualityIssue]) -> some View {
        let range = SubtitleQualityNavigation.pageRange(page: page, count: visible.count)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(visible[range])) { issue in
                        Button { activate(issue, in: visible) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: issue.id == navigation.focusedID ? "arrow.right.circle.fill" : "circle")
                                    .foregroundStyle(issue.id == navigation.focusedID ? Color(nsColor: .controlAccentColor) : .secondary)
                                Text("#\(issue.index) · \(text("quality." + issue.kind.rawValue))")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(6)
                            .background(issue.id == navigation.focusedID ? Color(nsColor: .controlAccentColor).opacity(0.12) : .clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(issue.id == navigation.focusedID ? .isSelected : [])
                        .id(issue.id)
                    }
                }
            }
            .frame(maxHeight: 180)
            .onChange(of: navigation.focusedID) { _, id in
                if let id { withAnimation(.easeInOut(duration: 0.18)) { proxy.scrollTo(id, anchor: .center) } }
            }
            .onChange(of: page) { _, _ in
                if let focused = visible[range].first(where: { $0.id == navigation.focusedID }) {
                    proxy.scrollTo(focused.id, anchor: .center)
                } else if let first = visible[range].first { proxy.scrollTo(first.id, anchor: .top) }
            }
        }
    }

    private func revealFocused(in visible: [SubtitleQualityIssue]) {
        if let index = visible.firstIndex(where: { $0.id == navigation.focusedID }) {
            page = index / SubtitleQualityNavigation.pageSize
        } else {
            page = min(page, max(0, (visible.count - 1) / SubtitleQualityNavigation.pageSize))
        }
    }

    private func activate(_ issue: SubtitleQualityIssue, in visible: [SubtitleQualityIssue]) {
        guard cues.contains(where: { $0.id == issue.cueID }) else { return }
        navigation.focus(issue)
        revealFocused(in: visible)
        select(issue.cueID)
    }

    private func navigate(in visible: [SubtitleQualityIssue], forward: Bool) {
        guard let issue = navigation.destination(in: visible, forward: forward) else { return }
        activate(issue, in: visible)
    }

    private func text(_ key: String) -> String { Copy.text(key, language: language) }
}
