import AppKit
import AVFoundation
import NaturalLanguage
import SwiftUI
import UniformTypeIdentifiers

struct SubtitleWord: Codable, Equatable, Sendable {
    var text: String
    var start: Double
    var end: Double
}

struct SubtitleBilingualText: Codable, Equatable, Sendable {
    var source: String
    var translation: String
    var translationFirst = false

    var combined: String {
        let first = translationFirst ? translation : source
        let second = translationFirst ? source : translation
        if first.isEmpty { return second }
        if second.isEmpty || first == second { return first }
        return first + "\n" + second
    }
}

struct SubtitleCue: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var index: Int
    var start: Double
    var end: Double
    var text: String {
        didSet {
            // Generic find/style edits operate on the visible text.
            // Do not silently retain an obsolete source/translation mapping.
            if let bilingual, bilingual.combined != text { self.bilingual = nil }
        }
    }
    var confidence: Double?
    var speaker: String?
    var words: [SubtitleWord]?
    var bilingual: SubtitleBilingualText?

    var bilingualText: SubtitleBilingualText? {
        guard let bilingual, bilingual.combined == text else { return nil }
        return bilingual
    }

    var translationSourceText: String { bilingualText?.source ?? text }

    mutating func setBilingual(_ value: SubtitleBilingualText) {
        text = value.combined
        bilingual = value
    }

    var duration: Double {
        max(0, end - start)
    }

    func duplicatedAfterEnd() -> SubtitleCue {
        var copy = self
        copy.id = UUID()
        copy.index = index + 1
        copy.start = max(0, end)
        copy.end = copy.start + max(0.5, duration)
        copy.bilingual = bilingualText
        // The new interval has not been aligned to speech.
        copy.words = nil
        return copy
    }
}

/// Compare just the edited scalars before writing through a collection binding.
/// The caller has already applied snapping and media/minimum-duration limits.
enum SubtitleCueTimingUpdate {
    static func updated(_ cue: SubtitleCue, start: Double, end: Double) -> SubtitleCue? {
        guard start.isFinite, end.isFinite,
              cue.start != start || cue.end != end else { return nil }
        var result = cue
        result.start = start
        result.end = end
        return result
    }
}

struct SubtitleCueIndex {
    var positions: [UUID: Int] = [:]
    var maximumEnd = 0.001
    var speakers: [String] = []
    var speechSeconds = 0.0
    private var starts: [Double] = []
    private var prefixEnds: [Double] = []
    private var ordered = true

    init(_ cues: [SubtitleCue]) {
        positions.reserveCapacity(cues.count)
        var seen: Set<String> = []
        for (index, cue) in cues.enumerated() {
            if !cue.start.isFinite || !cue.end.isFinite || cue.end < cue.start
                || (starts.last.map { $0 > cue.start } ?? false) { ordered = false }
            starts.append(cue.start)
            prefixEnds.append(max(prefixEnds.last ?? -.infinity, cue.end))
            if cue.duration.isFinite { speechSeconds += cue.duration }
            if positions[cue.id] == nil { positions[cue.id] = index }
            if cue.end.isFinite { maximumEnd = max(maximumEnd, cue.end) }
            let speaker = cue.speaker?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !speaker.isEmpty, seen.insert(speaker).inserted { speakers.append(speaker) }
        }
    }

    func visibleRange(lower: Double, upper: Double) -> Range<Int> {
        guard ordered, lower.isFinite, upper.isFinite, lower <= upper else { return 0..<starts.count }
        func firstIndex(_ values: [Double], after value: Double, inclusive: Bool) -> Int {
            var low = 0, high = values.count
            while low < high {
                let middle = low + (high - low) / 2
                if inclusive ? values[middle] < value : values[middle] <= value { low = middle + 1 }
                else { high = middle }
            }
            return low
        }
        let start = firstIndex(prefixEnds, after: lower, inclusive: true)
        let end = firstIndex(starts, after: upper, inclusive: false)
        return min(start, end)..<end
    }
}

/// Memoization only: this cache does not publish UI state while a body is read.
/// All access stays on the editor's main actor; each revision is scanned once.
@MainActor
final class SubtitleCueIndexCache {
    private var revision: UUID?
    private var index = SubtitleCueIndex([])

    func value(for cues: [SubtitleCue], revision: UUID) -> SubtitleCueIndex {
        if self.revision != revision {
            index = SubtitleCueIndex(cues)
            self.revision = revision
        }
        return index
    }
}

enum SubtitleCueStyle {
    enum Scope: String, CaseIterable, Identifiable {
        case all, source, translation
        var id: String { rawValue }
        var titleKey: String { "editor.findScope.\(rawValue)" }
    }

    enum Operation {
        case toggleTag(String), color(String), clear
    }

    static func texts(in cue: SubtitleCue, scope: Scope) -> [String] {
        if let pair = cue.bilingualText {
            switch scope {
            case .all: return [pair.source, pair.translation]
            case .source: return [pair.source]
            case .translation: return [pair.translation]
            }
        }
        return scope == .translation ? [] : [cue.text]
    }

    static func hasTag(_ tag: String, in cue: SubtitleCue, scope: Scope) -> Bool {
        let fields = texts(in: cue, scope: scope).filter { !$0.isEmpty }
        return !fields.isEmpty && fields.allSatisfy { unwrappedMarkupText($0, tag: tag) != nil }
    }

    static func hasColor(in cue: SubtitleCue, scope: Scope) -> Bool {
        let fields = texts(in: cue, scope: scope).filter { !$0.isEmpty }
        return !fields.isEmpty && fields.allSatisfy { unwrappedFontText($0) != nil }
    }

    static func applying(_ operation: Operation, to cue: SubtitleCue, scope: Scope = .all) -> SubtitleCue {
        let removeTag: Bool
        if case let .toggleTag(tag) = operation {
            removeTag = hasTag(tag, in: cue, scope: scope)
        } else { removeTag = false }
        func transform(_ text: String) -> String {
            guard !text.isEmpty else { return text }
            switch operation {
            case let .toggleTag(tag):
                let body = unwrappedMarkupText(text, tag: tag)
                // Mixed lanes become uniformly styled; already styled lanes are not wrapped twice.
                return removeTag ? (body ?? text) : (body == nil ? "<\(tag)>\(text)</\(tag)>" : text)
            case let .color(hex): return fontColoredText(text, hex: hex)
            case .clear: return clearMarkup(in: text)
            }
        }
        var result = cue
        if var pair = cue.bilingualText {
            if scope != .translation { pair.source = transform(pair.source) }
            if scope != .source { pair.translation = transform(pair.translation) }
            result.setBilingual(pair)
        } else if scope != .translation {
            result.text = transform(cue.text)
        }
        // Styling leaves speech content and word alignment intact.
        return result
    }

    static func clearMarkup(in text: String) -> String {
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

    static func fontMarkupRemoved(from text: String) -> String {
        text.replacingOccurrences(
            of: #"<font\b[^>]*>"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        .replacingOccurrences(
            of: "</font>",
            with: "",
            options: [.caseInsensitive]
        )
    }

    static func fontColoredText(_ text: String, hex: String) -> String {
        let body = fontMarkupRemoved(from: text).trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? "" : "<font color=\"\(hex)\">\(body)</font>"
    }

    static func unwrappedMarkupText(_ text: String, tag: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        guard lower.hasPrefix(open), lower.hasSuffix(close) else { return nil }
        guard hasSingleOuterWrapper(trimmed, tag: tag) else { return nil }
        let start = trimmed.index(trimmed.startIndex, offsetBy: open.count)
        let end = trimmed.index(trimmed.endIndex, offsetBy: -close.count)
        guard start <= end else { return nil }
        return String(trimmed[start..<end])
    }

    static func unwrappedFontText(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard lower.hasPrefix("<font "), lower.hasSuffix("</font>"),
              let openEnd = trimmed.firstIndex(of: ">") else {
            return nil
        }
        guard hasSingleOuterWrapper(trimmed, tag: "font") else { return nil }
        let start = trimmed.index(after: openEnd)
        let end = trimmed.index(trimmed.endIndex, offsetBy: -"</font>".count)
        guard start <= end else { return nil }
        return String(trimmed[start..<end])
    }

    private static func hasSingleOuterWrapper(_ text: String, tag: String) -> Bool {
        // Adjacent wrappers (e.g. after merging cues) are not one outer wrapper.
        let name = NSRegularExpression.escapedPattern(for: tag)
        guard let regex = try? NSRegularExpression(pattern: "</?\(name)(?:\\s[^>]*)?>", options: .caseInsensitive) else { return false }
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        var depth = 0
        for match in regex.matches(in: text, range: fullRange) {
            guard let range = Range(match.range, in: text) else { return false }
            depth += text[range].hasPrefix("</") ? -1 : 1
            if depth < 0 || (depth == 0 && NSMaxRange(match.range) != fullRange.length) { return false }
        }
        return depth == 0
    }
}

enum SubtitleCueMerge {
    /// Merge adjacent rows without inferring languages from plain text or
    /// discarding distinct speaker attribution. Keep the first cue's identity.
    static func merged(_ first: SubtitleCue, _ second: SubtitleCue) -> SubtitleCue? {
        guard first.id != second.id,
              first.start.isFinite, first.end.isFinite, second.start.isFinite, second.end.isFinite,
              first.start >= 0, second.start >= first.start,
              first.end > first.start, second.end > second.start,
              speaker(first.speaker) == speaker(second.speaker) else { return nil }
        var result = first
        result.end = max(first.end, second.end)
        switch (first.bilingualText, second.bilingualText) {
        case let (.some(a), .some(b)):
            result.setBilingual(.init(source: joined(a.source, b.source),
                                      translation: joined(a.translation, b.translation),
                                      translationFirst: a.translationFirst))
        case (nil, nil):
            result.text = joined(first.text, second.text)
        default:
            return nil
        }
        if let a = first.confidence, let b = second.confidence, a.isFinite, b.isFinite {
            result.confidence = min(a, b)
        } else { result.confidence = nil }
        // Partial word timing must not masquerade as a complete alignment.
        if let a = first.words, !a.isEmpty, let b = second.words, !b.isEmpty {
            let words = (a + b).sorted { $0.start < $1.start }
            result.words = words.allSatisfy {
                $0.start.isFinite && $0.end.isFinite && $0.start >= result.start
                    && $0.end >= $0.start && $0.end <= result.end
            } ? words : nil
        } else { result.words = nil }
        return result
    }

    private static func speaker(_ name: String?) -> String {
        (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func joined(_ first: String, _ second: String) -> String {
        if first.isEmpty { return second }
        if second.isEmpty { return first }
        return first + (first.hasSuffix("\n") || second.hasPrefix("\n") ? "" : "\n") + second
    }
}

enum SubtitleCueSplit {
    /// Visible character boundaries, with supported subtitle markup balanced on both sides.
    struct FormattedText {
        private struct Tag {
            let name: String
            let opening: String
        }
        private struct Span {
            let text: String
            let tags: [Tag]
        }
        private var spans: [Span] = []
        let plain: String

        init?(_ raw: String) {
            // Tokenize tags in UTF-16 so a combining mark immediately after a
            // closing tag cannot become part of the tag's final ">" grapheme.
            guard !raw.contains("{\\"),
                  let regex = try? NSRegularExpression(pattern: "<[^>]*>") else { return nil }
            let text = raw as NSString
            var stack: [Tag] = []
            var cursor = 0
            var visible = ""
            for match in regex.matches(in: raw, range: NSRange(location: 0, length: text.length)) {
                let fragment = text.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
                if !fragment.isEmpty {
                    spans.append(Span(text: fragment, tags: stack))
                    visible += fragment
                }
                let token = text.substring(with: match.range)
                let lower = token.lowercased()
                if ["<b>", "<i>", "<u>"].contains(lower) {
                    stack.append(Tag(name: String(lower.dropFirst().dropLast()), opening: token))
                } else if lower.hasPrefix("<font ") {
                    stack.append(Tag(name: "font", opening: token))
                } else if ["</b>", "</i>", "</u>", "</font>"].contains(lower) {
                    let name = String(lower.dropFirst(2).dropLast())
                    guard stack.last?.name == name else { return nil }
                    stack.removeLast()
                } else {
                    // Do not silently corrupt unsupported formatting.
                    return nil
                }
                cursor = NSMaxRange(match.range)
            }
            guard stack.isEmpty else { return nil }
            let tail = text.substring(from: cursor)
            if !tail.isEmpty {
                spans.append(Span(text: tail, tags: []))
                visible += tail
            }
            plain = visible
        }

        func split(at offset: Int) -> (String, String)? {
            guard (0...plain.count).contains(offset) else { return nil }
            // Use the full visible string's grapheme boundary even when a combining
            // character spans two styled runs. Never cut an emoji or surrogate pair.
            let boundary = plain.index(plain.startIndex, offsetBy: offset)
            var remaining = plain[..<boundary].utf16.count
            var left = "", right = ""
            for span in spans {
                let nsText = span.text as NSString
                let count = min(remaining, nsText.length)
                func wrapped(_ text: String) -> String {
                    guard !text.isEmpty else { return "" }
                    return span.tags.map(\.opening).joined() + text
                        + span.tags.reversed().map { "</\($0.name)>" }.joined()
                }
                left += wrapped(nsText.substring(to: count))
                right += wrapped(nsText.substring(from: count))
                remaining -= count
            }
            return (left, right)
        }
    }

    static func canSplit(_ cue: SubtitleCue, at time: Double) -> Bool {
        cue.start.isFinite && cue.end.isFinite && time.isFinite && cue.start >= 0
            && time >= cue.start + 0.05 && time <= cue.end - 0.05
    }

    /// Suggest only when the complete word alignment maps exactly to the source
    /// (apart from whitespace) and no word crosses the playhead.
    static func suggestedSourceOffset(_ cue: SubtitleCue, at time: Double) -> Int? {
        guard canSplit(cue, at: time), let words = cue.words, !words.isEmpty,
              let source = FormattedText(cue.translationSourceText) else { return nil }
        let text = source.plain
        var cursor = text.startIndex
        var boundary = cursor
        var previousEnd = cue.start
        for word in words {
            let token = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty, word.start.isFinite, word.end.isFinite,
                  word.start >= previousEnd, word.end >= word.start, word.end <= cue.end,
                  !(word.start < time && word.end > time),
                  let range = text.range(of: token, range: cursor..<text.endIndex),
                  text[cursor..<range.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            if word.end <= time { boundary = range.upperBound }
            cursor = range.upperBound
            previousEnd = word.end
        }
        guard text[cursor...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.indices.contains(boundary) || boundary == text.endIndex else { return nil }
        return text.distance(from: text.startIndex, to: boundary)
    }

    static func split(_ cue: SubtitleCue, at time: Double, sourceOffset: Int,
                      translationOffset: Int? = nil) -> (SubtitleCue, SubtitleCue)? {
        guard canSplit(cue, at: time),
              let source = FormattedText(cue.translationSourceText),
              let a = source.split(at: sourceOffset) else { return nil }
        var first = cue, second = cue
        first.end = time
        second.id = UUID()
        second.index = cue.index + 1
        second.start = time
        if let pair = cue.bilingualText {
            guard let translation = FormattedText(pair.translation),
                  let offset = translationOffset ?? (translation.plain.isEmpty ? 0 : nil),
                  let b = translation.split(at: offset) else { return nil }
            first.setBilingual(.init(source: a.0, translation: b.0, translationFirst: pair.translationFirst))
            second.setBilingual(.init(source: a.1, translation: b.1, translationFirst: pair.translationFirst))
        } else {
            first.text = a.0
            second.text = a.1
        }
        guard [first, second].allSatisfy({ cue in
            !(FormattedText(cue.text)?.plain ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else { return nil }
        first.words = nil
        second.words = nil
        if suggestedSourceOffset(cue, at: time) == sourceOffset, let words = cue.words {
            let before = words.filter { $0.end <= time }
            let after = words.filter { $0.end > time }
            first.words = before.isEmpty ? nil : before
            second.words = after.isEmpty ? nil : after
        }
        return (first, second)
    }
}

enum SubtitleBatchEdit {
    enum Operation {
        case shift(Double)
        case speaker(String)
        case addTag(String, SubtitleCueStyle.Scope)
        case color(String, SubtitleCueStyle.Scope)
        case clearStyle(SubtitleCueStyle.Scope)
    }

    /// Validate the entire selection before returning any changes. Never clamp
    /// negative times independently, which would silently alter cue durations.
    static func applying(_ operation: Operation, to cues: [SubtitleCue],
                         speakerColors: [String: String] = [:]) -> [SubtitleCue]? {
        var result: [SubtitleCue] = []
        for original in cues {
            var cue = original
            switch operation {
            case let .shift(delta):
                guard delta.isFinite, original.start.isFinite, original.end.isFinite,
                      original.start >= 0, original.end > original.start,
                      (original.start + delta).isFinite, (original.end + delta).isFinite,
                      original.start + delta >= 0,
                      original.end + delta > original.start + delta else { return nil }
                if delta == 0 { result.append(cue); continue }
                cue.start += delta
                cue.end += delta
                if let words = original.words {
                    if words.allSatisfy({ $0.start.isFinite && $0.end.isFinite
                        && $0.start >= original.start && $0.end >= $0.start && $0.end <= original.end }) {
                        cue.words = words.map { .init(text: $0.text, start: $0.start + delta, end: $0.end + delta) }
                    } else { cue.words = nil }
                }
            case let .speaker(raw):
                let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                cue.speaker = name.isEmpty ? nil : name
                if let color = speakerColors[name], !name.isEmpty {
                    cue = SubtitleCueStyle.applying(.color(color), to: cue)
                }
            case let .addTag(tag, scope):
                guard ["b", "i", "u"].contains(tag) else { return nil }
                // Mixed selections become uniformly styled instead of inverting
                // each cue separately. Already styled fields remain unchanged.
                if !SubtitleCueStyle.hasTag(tag, in: cue, scope: scope) {
                    cue = SubtitleCueStyle.applying(.toggleTag(tag), to: cue, scope: scope)
                }
            case let .color(hex, scope):
                cue = SubtitleCueStyle.applying(.color(hex), to: cue, scope: scope)
            case let .clearStyle(scope):
                cue = SubtitleCueStyle.applying(.clear, to: cue, scope: scope)
            }
            result.append(cue)
        }
        return result
    }

    static func replacing(_ originals: [SubtitleCue], with replacements: [SubtitleCue],
                          in current: [SubtitleCue]) -> [SubtitleCue]? {
        guard originals.count == replacements.count,
              Set(originals.map(\.id)).count == originals.count,
              Set(current.map(\.id)).count == current.count,
              zip(originals, replacements).allSatisfy({ $0.id == $1.id }) else { return nil }
        let byID = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0) })
        guard originals.allSatisfy({ byID[$0.id] == $0 }) else { return nil }
        let updates = Dictionary(uniqueKeysWithValues: replacements.map { ($0.id, $0) })
        return current.map { updates[$0.id] ?? $0 }
    }
}

private struct SubtitleBatchRequest: Identifiable {
    let id = UUID()
    let fileID: UUID
    let cues: [SubtitleCue]
    let speakerColors: [String: String]
}

private struct SubtitleSplitRequest: Identifiable {
    let id = UUID()
    let fileURL: URL
    let cue: SubtitleCue
    let time: Double
}

enum SubtitleSearchScope: String, CaseIterable, Identifiable {
    case all, source, translation
    var id: String { rawValue }
    var titleKey: String { "editor.findScope.\(rawValue)" }
}

struct SubtitleTextSearch {
    let query: String
    let replacement: String
    let matchCase: Bool
    let scope: SubtitleSearchScope

    private func ranges(in text: String) -> [Range<String.Index>] {
        guard !query.isEmpty else { return [] }
        var result: [Range<String.Index>] = []
        var remaining = text.startIndex..<text.endIndex
        let options: String.CompareOptions = matchCase ? [] : [.caseInsensitive, .diacriticInsensitive]
        while let range = text.range(of: query, options: options, range: remaining), range.lowerBound < range.upperBound {
            result.append(range)
            remaining = range.upperBound..<text.endIndex
        }
        return result
    }

    func count(in cue: SubtitleCue) -> Int {
        guard let pair = cue.bilingualText else {
            return scope == .translation ? 0 : ranges(in: cue.text).count
        }
        return (scope == .translation ? 0 : ranges(in: pair.source).count)
            + (scope == .source ? 0 : ranges(in: pair.translation).count)
    }

    func replacing(in cue: SubtitleCue, all: Bool) -> (cue: SubtitleCue, count: Int) {
        var remaining = all ? Int.max : 1
        var total = 0
        func replace(_ text: String) -> String {
            guard remaining > 0 else { return text }
            let matches = ranges(in: text).prefix(remaining)
            guard !matches.isEmpty else { return text }
            // Build from original slices, preserving Unicode indices and never
            // searching newly inserted replacement text.
            var output = ""
            var cursor = text.startIndex
            for range in matches {
                output += text[cursor..<range.lowerBound]
                output += replacement
                cursor = range.upperBound
            }
            output += text[cursor...]
            remaining -= matches.count
            total += matches.count
            return output
        }
        var result = cue
        if var pair = cue.bilingualText {
            let originalSource = pair.source
            if pair.translationFirst {
                if scope != .source { pair.translation = replace(pair.translation) }
                if scope != .translation { pair.source = replace(pair.source) }
            } else {
                if scope != .translation { pair.source = replace(pair.source) }
                if scope != .source { pair.translation = replace(pair.translation) }
            }
            result.setBilingual(pair)
            if pair.source != originalSource { result.words = nil }
        } else if scope != .translation {
            result.text = replace(cue.text)
            if result.text != cue.text { result.words = nil }
        }
        return total == 0 ? (cue, 0) : (result, total)
    }
}

/// Immutable gesture snapshot. Equal-distance ties retain document/edge order.
struct TimelineSnapIndex: Sendable {
    struct Edge: Sendable {
        let time: Double
        let order: Int
    }
    private let edges: [Edge]

    init(times: [Double]) {
        var sorted: [Edge] = []
        sorted.reserveCapacity(times.count)
        for (order, time) in times.enumerated() where time.isFinite {
            sorted.append(Edge(time: time, order: order))
        }
        sorted.sort { $0.time == $1.time ? $0.order < $1.order : $0.time < $1.time }
        var unique: [Edge] = []
        for edge in sorted where unique.last?.time != edge.time { unique.append(edge) }
        edges = unique
    }

    init(cues: [SubtitleCue], excluding cueID: UUID) {
        self.init(times: cues.filter { $0.id != cueID }.flatMap { [$0.start, $0.end] })
    }

    private func nearest(to target: Double) -> Edge? {
        guard target.isFinite, !edges.isEmpty else { return nil }
        var low = 0, high = edges.count
        while low < high {
            let middle = low + (high - low) / 2
            if edges[middle].time < target { low = middle + 1 } else { high = middle }
        }
        if low == 0 { return edges[0] }
        if low == edges.count { return edges[low - 1] }
        let left = edges[low - 1], right = edges[low]
        let a = abs(left.time - target), b = abs(right.time - target)
        return a == b ? (left.order < right.order ? left : right) : (a < b ? left : right)
    }

    func snappedTime(_ target: Double, threshold: Double) -> Double? {
        guard let edge = nearest(to: target), abs(edge.time - target) <= threshold else { return nil }
        return edge.time
    }

    func snappedStart(start: Double, end: Double, threshold: Double) -> Double? {
        let first = nearest(to: start), last = nearest(to: end)
        var candidate = first
        var movingEnd = false
        if let last {
            let a = first.map { abs($0.time - start) } ?? .infinity
            let b = abs(last.time - end)
            if b < a || (b == a && last.order < (first?.order ?? Int.max)) {
                candidate = last
                movingEnd = true
            }
        }
        guard let candidate,
              abs(candidate.time - (movingEnd ? end : start)) <= threshold else { return nil }
        return movingEnd ? candidate.time - (end - start) : candidate.time
    }
}

struct TimelineDensityBins: Sendable {
    let id = UUID()
    let counts: [Int]
    let speakerCounts: [Int]
    let maximum: Int

    init(cues: [SubtitleCue], duration: Double, binCount: Int, speaker: String?) {
        let count = max(1, binCount)
        var deltas = [Int](repeating: 0, count: count + 1)
        var speakerDeltas = deltas
        let duration = duration.isFinite ? max(duration, 0.001) : 0.001
        func bin(_ time: Double, roundUp: Bool) -> Int {
            // Clamp before conversion: very large finite timestamps can overflow Int.
            let scaled = min(Double(count - 1), max(0, (time / duration) * Double(count)))
            return Int(roundUp ? ceil(scaled) : scaled)
        }
        for cue in cues where cue.start.isFinite && cue.end.isFinite {
            let lower = bin(cue.start, roundUp: false)
            let upper = max(lower, bin(cue.end, roundUp: true))
            deltas[lower] += 1
            deltas[upper + 1] -= 1
            let name = cue.speaker?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if let speaker, !name.isEmpty, name == speaker {
                speakerDeltas[lower] += 1
                speakerDeltas[upper + 1] -= 1
            }
        }
        var running = 0, speaking = 0
        var counts: [Int] = [], speakerCounts: [Int] = []
        for index in 0..<count {
            running += deltas[index]
            speaking += speakerDeltas[index]
            counts.append(running)
            speakerCounts.append(speaking)
        }
        self.counts = counts
        self.speakerCounts = speakerCounts
        maximum = max(counts.max() ?? 1, 1)
    }
}

/// One density resolution per mounted canvas; playback/selection do not invalidate it.
@MainActor
final class TimelineDensityCache {
    private struct Key: Equatable {
        let revision: UUID
        let duration: Double
        let binCount: Int
        let speaker: String?
    }
    private var key: Key?
    private var bins: TimelineDensityBins?

    func value(cues: [SubtitleCue], revision: UUID, duration: Double,
               binCount: Int, speaker: String?) -> TimelineDensityBins {
        let next = Key(revision: revision, duration: duration.isFinite ? duration : 0,
                       binCount: binCount, speaker: speaker)
        if key == next, let bins { return bins }
        let result = TimelineDensityBins(cues: cues, duration: duration, binCount: binCount, speaker: speaker)
        bins = result
        key = next
        return result
    }
}

struct TimelineMarkerSet: Equatable, Sendable {
    struct Dot: Sendable { let cueID: UUID; let time: Double }
    let id = UUID()
    let dots: [Dot]
    private let timesByID: [UUID: Double]
    static let empty = TimelineMarkerSet([])

    init(_ cues: [SubtitleCue]) {
        dots = cues.compactMap { cue in
            let time = cue.start / 2 + cue.end / 2
            return time.isFinite ? Dot(cueID: cue.id, time: time) : nil
        }.sorted { $0.time < $1.time }
        timesByID = Dictionary(dots.map { ($0.cueID, $0.time) }, uniquingKeysWith: { first, _ in first })
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func time(for cueID: UUID) -> Double? { timesByID[cueID] }

    func visible(lower: Double, upper: Double) -> ArraySlice<Dot> {
        guard lower.isFinite, upper.isFinite, lower <= upper else { return dots[...] }
        var low = 0, high = dots.count
        while low < high {
            let mid = low + (high - low) / 2
            if dots[mid].time < lower { low = mid + 1 } else { high = mid }
        }
        let start = low
        high = dots.count
        while low < high {
            let mid = low + (high - low) / 2
            if dots[mid].time <= upper { low = mid + 1 } else { high = mid }
        }
        return dots[start..<low]
    }
}

struct TimelineOverlapMap: Sendable {
    struct Span: Equatable, Sendable {
        let start: Double
        let end: Double
        let pairs: Int
        // Equivalent fill opacity to layering one 0.42-opacity rectangle per pair.
        var fillOpacity: Double { 1 - pow(1 - 0.42, Double(pairs)) }
        var strokeOpacity: Double { 1 - pow(1 - 0.85, Double(pairs)) }
    }
    let spans: [Span]

    init(_ cues: [SubtitleCue]) {
        var events: [(time: Double, delta: Int)] = []
        events.reserveCapacity(cues.count * 2)
        for cue in cues where cue.start.isFinite && cue.end.isFinite && cue.end > cue.start {
            events.append((cue.start, 1))
            events.append((cue.end, -1))
        }
        events.sort { $0.time < $1.time }
        var result: [Span] = []
        var active = 0, index = 0
        var previous = events.first?.time ?? 0
        while index < events.count {
            let time = events[index].time
            if active >= 2, previous < time {
                result.append(Span(start: previous, end: time, pairs: active * (active - 1) / 2))
            }
            // Process equal-time boundaries together: touching cues don't overlap.
            while index < events.count, events[index].time == time {
                active += events[index].delta
                index += 1
            }
            previous = time
        }
        spans = result
    }

    func visible(lower: Double, upper: Double) -> ArraySlice<Span> {
        guard lower.isFinite, upper.isFinite, lower <= upper else { return spans[...] }
        var low = 0, high = spans.count
        while low < high {
            let mid = low + (high - low) / 2
            if spans[mid].end <= lower { low = mid + 1 } else { high = mid }
        }
        let start = low
        high = spans.count
        while low < high {
            let mid = low + (high - low) / 2
            if spans[mid].start < upper { low = mid + 1 } else { high = mid }
        }
        return spans[start..<low]
    }
}

@MainActor
final class TimelineOverlapCache {
    private var revision: UUID?
    private var result = TimelineOverlapMap([])
    func value(cues: [SubtitleCue], revision: UUID) -> TimelineOverlapMap {
        if self.revision != revision {
            result = TimelineOverlapMap(cues)
            self.revision = revision
        }
        return result
    }
}

@MainActor
final class SubtitleSearchCache {
    struct Key: Equatable {
        let revision: UUID
        let query: String
        let matchCase: Bool
        let scope: SubtitleSearchScope
        let literalHighlight: Bool
    }
    struct Result {
        var count = 0
        var indices: [Int] = []
        var cues: [SubtitleCue] = []
        var markers = TimelineMarkerSet.empty
    }
    private var key: Key?
    private var result = Result()

    func value(cues: [SubtitleCue], revision: UUID, search: SubtitleTextSearch, literalHighlight: Bool = false) -> Result {
        let requested = Key(revision: revision, query: search.query, matchCase: search.matchCase, scope: search.scope, literalHighlight: literalHighlight)
        guard key != requested else { return result }
        var updated = Result()
        if !search.query.isEmpty {
            for (index, cue) in cues.enumerated() {
                let count = literalHighlight ? (cue.text.localizedCaseInsensitiveContains(search.query) ? 1 : 0) : search.count(in: cue)
                if count > 0 {
                    updated.count += count
                    updated.indices.append(index)
                    updated.cues.append(cue)
                }
            }
        }
        updated.markers = updated.cues.isEmpty ? .empty : TimelineMarkerSet(updated.cues)
        key = requested
        result = updated
        return result
    }
}

struct TimelineCenterRequest: Equatable {
    let cueID: SubtitleCue.ID
    let token = UUID()
}

enum TimingAdjustmentMode: String, CaseIterable, Identifiable {
    case shift
    case closeGaps
    case calibrate

    var id: String { rawValue }
}

/// Two corresponding subtitle/media times define one positive affine mapping.
/// Transform word timings with cues; never repair invalid output by clipping it.
struct SubtitleTimingCalibration: Equatable {
    var sourceFirst = 0.0
    var targetFirst = 0.0
    var sourceLast = 60.0
    var targetLast = 60.0

    enum Failure: String, Error {
        case anchors = "timing.calibration.invalidAnchors"
        case cue = "timing.calibration.invalidCue"
        case result = "timing.calibration.invalidResult"
    }

    var scale: Double? {
        let values = [sourceFirst, targetFirst, sourceLast, targetLast]
        guard values.allSatisfy({ $0.isFinite && $0 >= 0 }),
              sourceLast - sourceFirst >= 0.001, targetLast - targetFirst >= 0.001 else { return nil }
        let value = (targetLast - targetFirst) / (sourceLast - sourceFirst)
        return value.isFinite && value > 0 ? value : nil
    }

    func applying(to cues: [SubtitleCue]) throws -> [SubtitleCue] {
        guard let scale else { throw Failure.anchors }
        func map(_ time: Double) throws -> Double {
            guard time.isFinite, time >= 0, time < Double(Int.max / 1000 - 1) else { throw Failure.cue }
            let mapped = targetFirst + (time - sourceFirst) * scale
            guard mapped.isFinite, mapped >= 0, mapped < Double(Int.max / 1000 - 1) else { throw Failure.result }
            return (mapped * 1000).rounded() / 1000
        }
        return try cues.map { cue in
            guard cue.end > cue.start else { throw Failure.cue }
            var result = cue
            result.start = try map(cue.start)
            result.end = try map(cue.end)
            // Export normalization enforces 50 ms. Reject shorter results so
            // the preview and exported timing cannot silently diverge.
            guard result.end - result.start >= 0.05 - 1e-9 else { throw Failure.result }
            result.words = try cue.words?.map { word in
                guard word.end >= word.start else { throw Failure.cue }
                return try SubtitleWord(text: word.text, start: map(word.start), end: map(word.end))
            }
            return result
        }
    }
}

private struct SubtitleUndoSnapshot: Equatable {
    let cues: [SubtitleCue]
    let selectedCueID: SubtitleCue.ID?
    let speakerColors: [String: String]
    let batchCueIDs: Set<SubtitleCue.ID>
}

@Observable
private final class SubtitleUndoController {
    var restoreHandler: ((SubtitleUndoSnapshot, String) -> Void)?

    func restore(_ snapshot: SubtitleUndoSnapshot, actionName: String) {
        restoreHandler?(snapshot, actionName)
    }
}

/// Per-editor memoization; serialization is independent of playback/selection.
@MainActor
final class SubtitlePreviewCache {
    private struct Key: Equatable {
        let fileID: UUID
        let revision: UUID
        let format: OutputFormat
    }
    private var key: Key?
    private var text = ""

    func value(cues: [SubtitleCue], fileID: UUID, revision: UUID, format: OutputFormat) -> String {
        let next = Key(fileID: fileID, revision: revision, format: format)
        if key == next { return text }
        text = SubtitleDocument.serialize(cues, format: format)
        key = next
        return text
    }
}

enum SubtitleDocument {
    static func monolingualCues(_ cues: [SubtitleCue], translated: Bool) -> [SubtitleCue] {
        cues.map { cue in
            guard let pair = cue.bilingualText else { return cue }
            var result = cue
            result.bilingual = nil
            let hasTranslation = !pair.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            result.text = translated && hasTranslation ? pair.translation : pair.source
            if translated && hasTranslation { result.words = nil }
            return result
        }
    }

    static func parse(_ text: String, format: OutputFormat) -> [SubtitleCue] {
        switch format {
        case .srt, .vtt:
            parseTimedText(text)
        case .ass:
            parseASS(text)
        case .json:
            parseJSON(text)
        case .txt:
            []
        }
    }

    static func serialize(_ cues: [SubtitleCue], format: OutputFormat) -> String {
        let normalized = normalizedIfNeeded(cues) ?? cues
        switch format {
        case .srt:
            return normalized.map { cue in
                """
                \(cue.index)
                \(formatSRTTime(cue.start)) --> \(formatSRTTime(cue.end))
                \(displayText(for: cue))
                """
            }
            .joined(separator: "\n\n") + (normalized.isEmpty ? "" : "\n")

        case .vtt:
            let body = normalized.map { cue in
                """
                \(cue.index)
                \(formatVTTTime(cue.start)) --> \(formatVTTTime(cue.end))
                \(displayText(for: cue))
                """
            }
            .joined(separator: "\n\n")
            return "WEBVTT\n\n" + body + (normalized.isEmpty ? "" : "\n")

        case .ass:
            let events = normalized.map { cue in
                let name = (normalizedSpeakerName(cue.speaker) ?? "")
                    .replacingOccurrences(of: ",", with: " ")
                let text = cue.text
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "\n", with: "\\N")
                return "Dialogue: 0,\(formatASSTime(cue.start)),\(formatASSTime(cue.end)),Default,\(name),0,0,0,,\(text)"
            }
            return assHeader + events.joined(separator: "\n") + (normalized.isEmpty ? "" : "\n")

        case .txt:
            return normalized.map { displayText(for: $0) }.joined(separator: "\n")

        case .json:
            let payload = SubtitleJSONPayload(
                text: normalized.map { displayText(for: $0) }.joined(separator: "\n"),
                segments: normalized.map {
                    SubtitleJSONSegment(
                        index: $0.index,
                        start: $0.start,
                        end: $0.end,
                        text: $0.text,
                        confidence: $0.confidence,
                        speaker: normalizedSpeakerName($0.speaker),
                        words: $0.words,
                        bilingual: $0.bilingualText
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

    /// Normalized timing/order can be checked without comparing text or word arrays.
    static func normalizedIfNeeded(_ cues: [SubtitleCue]) -> [SubtitleCue]? {
        var previousStart = -Double.infinity
        for (offset, cue) in cues.enumerated() {
            guard cue.start.isFinite, cue.end.isFinite, cue.index == offset + 1,
                  cue.start >= 0, cue.start >= previousStart, cue.end >= cue.start + 0.05 else {
                return normalize(cues)
            }
            previousStart = cue.start
        }
        return nil
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

    static func normalizedSpeakerName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    static func displayText(for cue: SubtitleCue) -> String {
        displayText(text: cue.text, speaker: cue.speaker)
    }

    static func displayText(text rawText: String, speaker rawSpeaker: String?) -> String {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let speaker = normalizedSpeakerName(rawSpeaker) else {
            return text
        }
        return text.isEmpty ? "\(speaker):" : "\(speaker): \(text)"
    }

    static func normalizedCueTextForMatching(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
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
            let speakerSplit = splitSpeakerPrefix(from: cueText)
            cues.append(
                SubtitleCue(
                    index: cues.count + 1,
                    start: start,
                    end: max(start + 0.05, end),
                    text: speakerSplit.text,
                    speaker: speakerSplit.speaker
                )
            )
        }
        return cues
    }

    private static let assHeader = """
    [Script Info]
    ; Generated by MSub
    ScriptType: v4.00+
    WrapStyle: 0
    ScaledBorderAndShadow: yes
    PlayResX: 1920
    PlayResY: 1080

    [V4+ Styles]
    Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
    Style: Default,Arial,72,&H00FFFFFF,&H00FFFFFF,&H00000000,&H7F000000,0,0,0,0,100,100,0,0,1,3,1,2,60,60,50,1

    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

    """

    private static func parseASS(_ text: String) -> [SubtitleCue] {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard line.lowercased().hasPrefix("dialogue:") else { continue }
            let body = String(line.dropFirst("dialogue:".count))
            // Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
            let fields = body
                .split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false)
                .map(String.init)
            guard fields.count == 10,
                  let start = parseASSTime(fields[1]),
                  let end = parseASSTime(fields[2]) else {
                continue
            }
            let name = normalizedSpeakerName(fields[4].trimmingCharacters(in: .whitespaces))
            let rawText = removingASSOverrideTags(
                fields[9]
                    .replacingOccurrences(of: "\\N", with: "\n")
                    .replacingOccurrences(of: "\\n", with: "\n")
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !rawText.isEmpty else { continue }
            let split = splitSpeakerPrefix(from: rawText)
            let speaker = name ?? split.speaker
            // Avoid double speaker labels when both the Name field and a
            // "Speaker: text" prefix carry the same value.
            let cueText = (name == nil || split.speaker == name) ? split.text : rawText
            cues.append(
                SubtitleCue(
                    index: cues.count + 1,
                    start: start,
                    end: max(start + 0.05, end),
                    text: cueText,
                    speaker: speaker
                )
            )
        }
        return cues
    }

    private static func removingASSOverrideTags(_ text: String) -> String {
        var result = ""
        var depth = 0
        for character in text {
            if character == "{" {
                depth += 1
                continue
            }
            if character == "}", depth > 0 {
                depth -= 1
                continue
            }
            if depth == 0 {
                result.append(character)
            }
        }
        return result
    }

    private static func parseASSTime(_ raw: String) -> Double? {
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else {
            return nil
        }
        return hours * 3600 + minutes * 60 + seconds
    }

    private static func formatASSTime(_ seconds: Double) -> String {
        let totalCentiseconds = max(0, Int((seconds * 100).rounded()))
        let hours = totalCentiseconds / 360000
        let minutes = (totalCentiseconds % 360000) / 6000
        let secs = (totalCentiseconds % 6000) / 100
        let centiseconds = totalCentiseconds % 100
        return String(format: "%d:%02d:%02d.%02d", hours, minutes, secs, centiseconds)
    }

    private static func parseJSON(_ text: String) -> [SubtitleCue] {
        guard let data = text.data(using: .utf8),
              let payload = try? JSONDecoder().decode(SubtitleJSONPayload.self, from: data) else {
            return []
        }
        return payload.segments.map {
            let speaker = normalizedSpeakerName($0.speaker)
            let isBilingual = $0.bilingual?.combined == $0.text
            let speakerSplit = speaker == nil && !isBilingual ? splitSpeakerPrefix(from: $0.text) : (speaker: nil, text: $0.text)
            return SubtitleCue(
                index: $0.index,
                start: $0.start,
                end: $0.end,
                text: speakerSplit.text,
                confidence: $0.confidence,
                speaker: speaker ?? speakerSplit.speaker,
                words: $0.words,
                bilingual: $0.bilingual
            )
        }
    }

    private static func splitSpeakerPrefix(from raw: String) -> (speaker: String?, text: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return (nil, "") }

        if let voice = splitWebVTTSpeaker(from: text) {
            return voice
        }

        if let bracketed = splitBracketedSpeaker(from: text) {
            return bracketed
        }

        let firstLineEnd = text.firstIndex(of: "\n") ?? text.endIndex
        let firstLine = text[..<firstLineEnd]
        guard let colon = firstLine.firstIndex(where: { $0 == ":" || $0 == "：" }) else {
            let candidate = String(firstLine).trimmingCharacters(in: .whitespacesAndNewlines)
            if firstLineEnd < text.endIndex, isExplicitSpeakerLabel(candidate) {
                let remainder = String(text[text.index(after: firstLineEnd)...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !remainder.isEmpty {
                    return (normalizedSpeakerName(candidate), remainder)
                }
            }
            return (nil, text)
        }

        let candidate = String(firstLine[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedCandidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "-–— \t"))
        guard isPlausibleSpeakerLabel(cleanedCandidate) else {
            return (nil, text)
        }

        let afterColon = String(firstLine[firstLine.index(after: colon)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remainder: String
        if firstLineEnd < text.endIndex {
            remainder = String(text[text.index(after: firstLineEnd)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            remainder = ""
        }
        let body = [afterColon, remainder]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        return (normalizedSpeakerName(cleanedCandidate), body)
    }

    private static func splitWebVTTSpeaker(from text: String) -> (speaker: String?, text: String)? {
        guard text.lowercased().hasPrefix("<v ") else { return nil }
        guard let tagEnd = text.firstIndex(of: ">") else { return nil }
        let rawSpeaker = String(text[text.index(text.startIndex, offsetBy: 3)..<tagEnd])
            .split(separator: ".")
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let speaker = normalizedSpeakerName(rawSpeaker),
              isPlausibleSpeakerLabel(speaker) else { return nil }
        var body = String(text[text.index(after: tagEnd)...])
            .replacingOccurrences(of: "</v>", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("<") {
            body = body.replacingOccurrences(of: #"^<[^>]+>"#, with: "", options: [.regularExpression])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return (speaker, body)
    }

    private static func splitBracketedSpeaker(from text: String) -> (speaker: String?, text: String)? {
        guard let first = text.first, first == "[" || first == "【" || first == "(" || first == "（" else {
            return nil
        }
        let closing: Character = switch first {
        case "[": "]"
        case "【": "】"
        case "(": ")"
        default: "）"
        }
        guard let closeIndex = text.firstIndex(of: closing) else { return nil }
        let candidate = String(text[text.index(after: text.startIndex)..<closeIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isKnownAudioEventLabel(candidate) else { return nil }
        guard isPlausibleSpeakerLabel(candidate) else { return nil }
        let body = String(text[text.index(after: closeIndex)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return (normalizedSpeakerName(candidate), body)
    }

    private static func isPlausibleSpeakerLabel(_ label: String) -> Bool {
        guard (1...40).contains(label.count) else { return false }
        let lowered = label.lowercased()
        guard lowered != "http", lowered != "https" else { return false }
        guard !isKnownAudioEventLabel(label) else { return false }
        let allowed = CharacterSet.letters
            .union(.decimalDigits)
            .union(CharacterSet(charactersIn: " _.-"))
        guard label.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
        if label.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) {
            return true
        }
        return label.count <= 12
            && label.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
    }

    private static func isExplicitSpeakerLabel(_ label: String) -> Bool {
        guard isPlausibleSpeakerLabel(label) else { return false }
        let lower = label.lowercased()
        return lower.contains("speaker")
            || lower.contains("spk")
            || lower.contains("发言人")
            || lower.contains("說話者")
            || lower.contains("說話人")
            || lower.contains("说话人")
            || lower.contains("讲话人")
            || lower.contains("話者")
    }

    private static func isKnownAudioEventLabel(_ label: String) -> Bool {
        let normalized = label
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
        let compact = normalized
            .split(separator: " ")
            .joined()
        return [
            "speech",
            "applause",
            "clapping",
            "bgm",
            "music",
            "laughter",
            "laugh",
            "cry",
            "crying",
            "sneeze",
            "sneezing",
            "breath",
            "breathing",
            "cough",
            "coughing",
            "noise"
        ].contains(compact)
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
    var speaker: String?
    var words: [SubtitleWord]?
    var bilingual: SubtitleBilingualText?
}

struct SubtitleTermFrequency: Identifiable, Equatable, Sendable {
    let term: String
    let count: Int

    var id: String { term }
}

struct SubtitleEmotionFrequency: Identifiable, Equatable, Sendable {
    let emoji: String
    let count: Int
    let ratio: Double

    var id: String { emoji }
}

enum SubtitleEmotionStats {
    static let emojiSet: Set<String> = [
        "\u{1F60A}", // 😊 happy
        "\u{1F622}", // 😢 sad
        "\u{1F620}", // 😠 angry
        "\u{1F610}", // 😐 neutral
        "\u{1F628}", // 😨 fearful
        "\u{1F922}", // 🤢 disgusted
        "\u{1F62E}", // 😮 surprised
        "\u{1F3AD}"  // 🎭 other
    ]

    static func leadingEmotionEmoji(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first else { return nil }
        let candidate = String(first)
        return emojiSet.contains(candidate) ? candidate : nil
    }

    static func frequencies(in cues: [SubtitleCue]) -> [SubtitleEmotionFrequency] {
        var counts: [String: Int] = [:]
        var matched = 0
        for cue in cues {
            if Task.isCancelled { return [] }
            guard let emoji = leadingEmotionEmoji(in: cue.text) else { continue }
            counts[emoji, default: 0] += 1
            matched += 1
        }
        guard matched > 0 else { return [] }
        let total = Double(matched)
        return counts
            .map { SubtitleEmotionFrequency(emoji: $0.key, count: $0.value, ratio: Double($0.value) / total) }
            .sorted {
                if $0.count == $1.count {
                    return $0.emoji < $1.emoji
                }
                return $0.count > $1.count
            }
    }
}

enum SubtitleTextStats {
    private static let maxAnalyzedCharacters = 60_000

    static func topTerms(in cues: [SubtitleCue], limit: Int = 8) -> [SubtitleTermFrequency] {
        topTerms(in: sampledCueText(cues, maxCharacters: maxAnalyzedCharacters), limit: limit)
    }

    static func topTerms(in text: String, limit: Int = 8) -> [SubtitleTermFrequency] {
        let cleanText = stripMarkup(from: sampledText(text, maxCharacters: maxAnalyzedCharacters))
        var counts: [String: Int] = [:]
        for token in tokenize(cleanText) where !stopWords.contains(token) {
            if Task.isCancelled { return [] }
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

    private static func sampledCueText(_ cues: [SubtitleCue], maxCharacters: Int) -> String {
        guard !cues.isEmpty, maxCharacters > 0 else { return "" }
        var totalCharacters = 0
        for cue in cues {
            if Task.isCancelled { return "" }
            totalCharacters += cue.text.count + 1
            if totalCharacters > maxCharacters {
                break
            }
        }
        if totalCharacters <= maxCharacters {
            return cues.map(\.text).joined(separator: " ")
        }

        let perSection = max(1, maxCharacters / 3)
        let sections = [
            cues.prefix(max(1, cues.count / 5)),
            cues.dropFirst(max(0, cues.count / 2 - cues.count / 10)).prefix(max(1, cues.count / 5)),
            cues.suffix(max(1, cues.count / 5))
        ]

        var result = ""
        result.reserveCapacity(maxCharacters)
        for section in sections {
            var sectionCharacters = 0
            for cue in section {
                if Task.isCancelled { return "" }
                appendSample(
                    cue.text,
                    to: &result,
                    sectionCharacters: &sectionCharacters,
                    sectionLimit: perSection,
                    globalLimit: maxCharacters
                )
                if result.count >= maxCharacters { return result }
            }
        }
        return result
    }

    private static func appendSample(
        _ text: String,
        to result: inout String,
        sectionCharacters: inout Int,
        sectionLimit: Int,
        globalLimit: Int
    ) {
        guard sectionLimit > 0, globalLimit > 0, !text.isEmpty else { return }
        let separatorLength = result.isEmpty ? 0 : 1
        let remainingGlobal = max(0, globalLimit - result.count - separatorLength)
        let remainingSection = max(0, sectionLimit - sectionCharacters - separatorLength)
        let take = min(text.count, remainingGlobal, remainingSection)
        guard take > 0 else { return }
        if !result.isEmpty {
            result.append(" ")
            sectionCharacters += 1
        }
        result.append(String(text.prefix(take)))
        sectionCharacters += take
    }

    private static func sampledText(_ text: String, maxCharacters: Int) -> String {
        guard maxCharacters > 0, text.count > maxCharacters else { return text }
        let chunk = max(1, maxCharacters / 3)
        let prefixText = text.prefix(chunk)
        let suffixText = text.suffix(chunk)
        let middleOffset = max(0, text.count / 2 - chunk / 2)
        let middleStart = text.index(text.startIndex, offsetBy: middleOffset)
        let middleEnd = text.index(middleStart, offsetBy: min(chunk, text.distance(from: middleStart, to: text.endIndex)))
        return "\(prefixText) \(text[middleStart..<middleEnd]) \(suffixText)"
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
        guard !Task.isCancelled else { return [] }
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
        guard !Task.isCancelled else { return [] }
        let language = dominantLanguage(in: text)
        let tokenizerTokens = tokenizerTerms(in: text, language: language)
        guard !Task.isCancelled else { return [] }
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
            if Task.isCancelled { return false }
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
            if Task.isCancelled { return false }
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

/// Playback-only ranges: padding never changes the saved subtitle timestamps.
struct SubtitleReviewRange: Equatable {
    let cueID: SubtitleCue.ID
    let start: Double
    let end: Double

    static func plan(cues: [SubtitleCue], selectedID: SubtitleCue.ID, padding: Double,
                     duration: Double, advance: Bool) -> [Self] {
        guard let index = cues.firstIndex(where: { $0.id == selectedID }) else { return [] }
        let context = padding.isFinite ? min(2, max(0, padding)) : 0
        let limit = duration.isFinite && duration > 0 ? duration : Double.greatestFiniteMagnitude
        let candidates = advance ? Array(cues[index...]) : [cues[index]]
        return candidates.compactMap { cue in
            guard cue.start.isFinite, cue.end.isFinite, cue.start >= 0,
                  cue.end > cue.start, cue.start < limit else { return nil }
            let start = max(0, cue.start - context)
            let end = min(limit, cue.end + context)
            guard end.isFinite, end > start else { return nil }
            return Self(cueID: cue.id, start: start, end: end)
        }
    }
}

// MARK: - Shared playback controller

@MainActor
@Observable
final class PlaybackController {
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying: Bool = false
    private(set) var hasVideo: Bool = false

    nonisolated let player = AVPlayer()

    @ObservationIgnored nonisolated(unsafe) private var timeObserverToken: Any?
    @ObservationIgnored nonisolated(unsafe) private var rateObservation: NSKeyValueObservation?
    @ObservationIgnored nonisolated(unsafe) private var endObserverToken: (any NSObjectProtocol)?
    private var currentURL: URL?
    private var playbackEndTime: Double?
    private var loopStartTime: Double?
    private(set) var isLooping = false
    private(set) var activeReviewCueID: SubtitleCue.ID?
    private var reviewRanges: [SubtitleReviewRange] = []
    private var reviewIndex = 0
    private var rangeSeekInFlight = false
    private var rangeGeneration = UUID()
    private var directSeekGeneration = UUID()
    private var directSeekInFlight = false
    var isReviewing: Bool { activeReviewCueID != nil }

    private func clearRangePlayback() {
        directSeekGeneration = UUID()
        directSeekInFlight = false
        playbackEndTime = nil
        loopStartTime = nil
        isLooping = false
        activeReviewCueID = nil
        reviewRanges = []
        reviewIndex = 0
        rangeSeekInFlight = false
        rangeGeneration = UUID()
    }

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        attachObservers()
    }

    deinit {
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
        }
        if let endObserverToken { NotificationCenter.default.removeObserver(endObserverToken) }
        rateObservation?.invalidate()
        rateObservation = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    func load(_ url: URL) async {
        if currentURL == url { return }
        currentURL = url
        currentTime = 0
        duration = 0
        hasVideo = false
        clearRangePlayback()
        player.pause()
        player.replaceCurrentItem(with: nil)

        // For containers AVFoundation can't natively play (MKV, etc.) the player
        // would stall or stop early. Resolve to a clean extraction up front
        // so playback always traverses the full audio. We deliberately route
        // through `AudioSource` (audio-only) here instead of `VideoSource`:
        // making audio loading depend on the slower video remux would block
        // the timeline while ffmpeg runs. The video-aware upgrade happens
        // separately in the preview layer when (and only when) a remuxed file
        // is genuinely playable.
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
        clearRangePlayback()
        if pause {
            player.pause()
        }
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        seekPlayer(to: time, tolerance: .zero)
    }

    func scrub(to seconds: Double) {
        let target = max(0, seconds.isFinite ? seconds : 0)
        let clamped = duration > 0 ? min(target, duration) : target
        currentTime = clamped
        clearRangePlayback()
        player.pause()
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        let tolerance = CMTime(seconds: 0.08, preferredTimescale: 600)
        seekPlayer(to: time, tolerance: tolerance)
    }

    private func seekPlayer(to time: CMTime, tolerance: CMTime) {
        let generation = UUID()
        directSeekGeneration = generation
        directSeekInFlight = player.currentItem != nil
        player.currentItem?.cancelPendingSeeks()
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.directSeekGeneration == generation else { return }
                self.directSeekInFlight = false
            }
        }
    }

    func togglePlayPause() {
        if player.timeControlStatus == .playing || playbackEndTime != nil {
            clearRangePlayback()
            player.pause()
        } else {
            clearRangePlayback()
            player.play()
        }
    }

    func playRange(start: Double, end: Double, loop: Bool = false) {
        guard start.isFinite, end.isFinite else { return }
        let lower = max(0, start)
        let upper = duration > 0 ? min(end, duration) : end
        guard upper > lower else { return }
        clearRangePlayback()
        beginRange(start: lower, end: upper, loop: loop)
    }

    func playReview(cues: [SubtitleCue], selectedID: SubtitleCue.ID, padding: Double,
                    advance: Bool, loop: Bool = false) {
        let plan = SubtitleReviewRange.plan(cues: cues, selectedID: selectedID,
                                           padding: padding, duration: duration, advance: advance && !loop)
        guard let first = plan.first else { return }
        clearRangePlayback()
        reviewRanges = plan
        activeReviewCueID = first.cueID
        beginRange(start: first.start, end: first.end, loop: loop)
    }

    private func beginRange(start: Double, end: Double, loop: Bool) {
        playbackEndTime = end
        loopStartTime = loop ? start : nil
        isLooping = loop
        rangeSeekInFlight = true
        rangeGeneration = UUID()
        let generation = rangeGeneration
        currentTime = start
        player.pause()
        player.seek(to: CMTime(seconds: start, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.rangeGeneration == generation else { return }
                self.rangeSeekInFlight = false
                if finished { self.player.play() }
                else { self.clearRangePlayback() }
            }
        }
    }

    private func finishRange(at end: Double) {
        guard !rangeSeekInFlight else { return }
        if let start = loopStartTime {
            beginRange(start: start, end: end, loop: true)
        } else if reviewIndex + 1 < reviewRanges.count {
            reviewIndex += 1
            let next = reviewRanges[reviewIndex]
            activeReviewCueID = next.cueID
            beginRange(start: next.start, end: next.end, loop: false)
        } else {
            seek(to: end, pause: true)
        }
    }

    private func attachObservers() {
        let interval = CMTime(seconds: 1.0 / 20.0, preferredTimescale: CMTimeScale(NSEC_PER_SEC))
        timeObserverToken = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            let seconds = time.seconds
            MainActor.assumeIsolated {
                guard let self, !self.rangeSeekInFlight, !self.directSeekInFlight else { return }
                if seconds.isFinite {
                    self.currentTime = max(0, seconds)
                }
                if let endTime = self.playbackEndTime, seconds >= endTime {
                    self.finishRange(at: endTime)
                }
            }
        }
        endObserverToken = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let endedItemID = (notification.object as? AVPlayerItem).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let endedItemID,
                      endedItemID == self.player.currentItem.map(ObjectIdentifier.init),
                      let end = self.playbackEndTime else { return }
                self.finishRange(at: end)
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
    let playback: PlaybackController
    var onTranslateCue: ((SubtitleCue.ID, TranslationLanguageChoice, TranslationOutputMode) -> Void)? = nil
    @State private var inlineTranslationLanguage: TranslationLanguageChoice = .common[2]
    @AppStorage("msub.review.padding") private var reviewPadding = 0.25
    @AppStorage("msub.review.advance") private var reviewAutoAdvance = false

    @Environment(APIClient.self) private var api
    @Environment(BackendService.self) private var backend
    @Environment(TranscriptionSettings.self) private var settings
    @Environment(\.undoManager) private var undoManager

    @State private var undoController = SubtitleUndoController()
    @State private var previewCache = SubtitlePreviewCache()
    @State private var waveform = WaveformSamples([])
    @State private var isLoadingWaveform = false
    @State private var timelineZoom = 1.0
    @State private var isTimelineZoomSliderDragging = false
    @State private var timelineCenterRequest: TimelineCenterRequest?
    @State private var timelineCueDragUndoSnapshot: SubtitleUndoSnapshot?
    @State private var textEditUndoBurst: (cueID: SubtitleCue.ID, lastEdit: Date)?
    @State private var isTimingAdjustmentPresented = false
    @State private var splitRequest: SubtitleSplitRequest?
    @State private var isBatchSelecting = false
    @State private var batchCueIDs: Set<SubtitleCue.ID> = []
    @State private var batchRequest: SubtitleBatchRequest?
    @State private var timingAdjustmentMode: TimingAdjustmentMode = .shift
    @State private var timingShiftSeconds = 0.0
    @State private var timingGapSeconds = 0.0
    @State private var findText = ""
    @State private var replacementText = ""
    @State private var findScope: SubtitleSearchScope = .all
    @State private var matchCase = false
    @State private var findStatus = ""
    @State private var isFindReplaceExpanded = false
    @SceneStorage("ui.isTimelineExpanded") private var isTimelineExpanded = false
    @State private var styleColor = Color.yellow
    @State private var styleScope: SubtitleCueStyle.Scope = .all
    @State private var speakerStyleColor = Color.yellow
    @State private var selectedTextRange: NSRange?
    @State private var waveformSourceKey: String?
    @State private var previewSyncTask: Task<Void, Never>?
    @State private var termStatsTask: Task<Void, Never>?
    @State private var waveformReloadTask: Task<Void, Never>?
    @State private var cueListScrollTask: Task<Void, Never>?
    @State private var transcribingCueID: SubtitleCue.ID?
    @State private var transcribeError: String?
    @State private var editingSpeakerCueID: SubtitleCue.ID?
    @State private var speakerEditOriginalName: String?
    @State private var speakerEditText = ""
    @State private var editorColumnHeight: CGFloat = 300
    @State private var cachedOriginalCuesByID: [SubtitleCue.ID: SubtitleCue] = [:]
    @State private var cachedSpeakerColorsByName: [String: Color] = [:]
    @State private var cueIndexCache = SubtitleCueIndexCache()
    @State private var searchCache = SubtitleSearchCache()
    @State private var highlightCache = SubtitleSearchCache()
    @State private var overlapCache = TimelineOverlapCache()
    @FocusState private var isSpeakerEditorFocused: Bool
    @FocusState private var isSubtitleListFocused: Bool
    @FocusState private var isFindFieldFocused: Bool

    private static let waveformResolutionSteps = [180, 360, 720, 1_440, 2_880, 5_760, 11_520, 23_040, 46_080, 92_160, 131_072, 262_144, 524_288, 1_048_576]

    private var duration: Double {
        max(slot.duration, cueIndexData.maximumEnd + 1.0)
    }

    private var cueIndexData: SubtitleCueIndex {
        cueIndexCache.value(for: slot.cues, revision: slot.cuesRevision)
    }

    nonisolated private static func joinedCueText(_ cues: [SubtitleCue]) -> String {
        var characterCount = 0
        for cue in cues {
            characterCount += cue.text.count + 1
        }
        var text = ""
        text.reserveCapacity(characterCount)
        for cue in cues {
            if !text.isEmpty {
                text.append(" ")
            }
            text.append(cue.text)
        }
        return text
    }

    private var selectedCueIndex: Int? {
        guard let selectedCueID = slot.selectedCueID else { return nil }
        return cueIndex(for: selectedCueID)
    }

    private var maxTimelineZoom: Double {
        max(8.0, ceil(duration / 4.0))
    }

    private var activeFindHighlightTerm: String? {
        guard isFindReplaceExpanded else { return nil }
        return findText.isEmpty ? nil : findText
    }

    private var speakerNames: [String] {
        cueIndexData.speakers
    }

    private var activeTimelineSpeakerName: String? {
        guard settings.timelineSpeakerMarkersEnabled, let editingSpeakerCueID else { return nil }
        if let speaker = speakerEditOriginalName {
            return speaker
        }
        if let index = slot.cues.firstIndex(where: { $0.id == editingSpeakerCueID }),
           let speaker = SubtitleDocument.normalizedSpeakerName(slot.cues[index].speaker) {
            return speaker
        }
        return SubtitleDocument.normalizedSpeakerName(speakerEditText)
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
        let desired = Int(visibleTarget * zoom * settings.waveformResolution.targetMultiplier)
        return Self.waveformResolutionSteps.first { $0 >= desired } ?? Self.waveformResolutionSteps.last ?? 720
    }

    private var editorLayout: some View {
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
                        .frame(height: max(300, editorColumnHeight), alignment: .top)

                    VStack(spacing: 10) {
                        selectedCueEditor
                        findReplaceBar
                        SubtitleQualityPanel(cues: slot.cues, cuesRevision: slot.cuesRevision,
                                             selectedCueID: slot.selectedCueID, language: language) { cueID in
                            if cueID == slot.selectedCueID, let cue = slot.cues.first(where: { $0.id == cueID }) {
                                playback.seek(to: cue.start, pause: true)
                            }
                            slot.selectedCueID = cueID
                            timelineCenterRequest = TimelineCenterRequest(cueID: cueID)
                        }
                        .id(slot.id)
                    }
                    .frame(width: 320)
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: EditorColumnHeightPreferenceKey.self, value: proxy.size.height)
                        }
                    }
                }
                .padding(.trailing, 6)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .onPreferenceChange(EditorColumnHeightPreferenceKey.self) { newValue in
                    guard newValue.isFinite, newValue > 0 else { return }
                    editorColumnHeight = newValue
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var editorWithStateUpdates: some View {
        editorLayout
        .task(id: slot.url) {
            await loadWaveformIfNeeded()
        }
        .onAppear {
            configureUndoController()
            refreshSlotCaches()
            scheduleTermStatsSync(for: slot.cues)
        }
        .onChange(of: slotCacheSignal) { _, _ in
            refreshSlotCaches()
        }
        .onChange(of: isTimelineExpanded) { _, newValue in
            guard newValue else { return }
            scheduleWaveformReload(debounce: false)
        }
        .onChange(of: waveformTargetSamples) { _, _ in
            guard isTimelineExpanded else { return }
            scheduleWaveformReload(debounce: true)
        }
        .onChange(of: settings.waveformResolution) { _, _ in
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
        .onChange(of: slot.outputFormat) { _, _ in
            syncPreviewText()
        }
        .onChange(of: slot.cuesRevision) { _, _ in
            scheduleTermStatsSync(for: slot.cues)
            if playback.isReviewing { playback.seek(to: playback.currentTime, pause: true) }
            if !batchCueIDs.isEmpty {
                batchCueIDs.formIntersection(Set(slot.cues.map(\.id)))
            }
        }
        .onChange(of: slot.id) { _, _ in
            isBatchSelecting = false
            batchCueIDs = []
            batchRequest = nil
        }
        .onChange(of: playback.activeReviewCueID) { _, cueID in
            guard let cueID, slot.cues.contains(where: { $0.id == cueID }) else { return }
            slot.selectedCueID = cueID
            timelineCenterRequest = TimelineCenterRequest(cueID: cueID)
        }
        .onChange(of: slot.selectedCueID) { _, newValue in
            if let editingSpeakerCueID {
                commitSpeakerEdit(for: editingSpeakerCueID)
            }
            guard let newValue,
                  let cue = slot.cues.first(where: { $0.id == newValue }) else { return }
            selectedTextRange = nil
            guard playback.activeReviewCueID != newValue else { return }
            playback.seek(to: cue.start, pause: true)
        }
    }

    private var editorWithCueCommands: some View {
        editorWithStateUpdates
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
    }

    private var editorWithTimelineCommands: some View {
        editorWithCueCommands
        .onReceive(NotificationCenter.default.publisher(for: .msubAdjustTimingRequested)) { _ in
            guard !slot.cues.isEmpty else { return }
            isTimingAdjustmentPresented = true
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
        .onReceive(NotificationCenter.default.publisher(for: .msubFocusFindFieldRequested)) { _ in
            withAnimation(.easeInOut(duration: 0.18)) {
                isFindReplaceExpanded = true
            }
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(40))
                isFindFieldFocused = true
            }
        }
    }

    var body: some View {
        editorWithTimelineCommands
        .onDisappear(perform: finishEditorSession)
        .sheet(item: $batchRequest) { request in
            SubtitleBatchEditSheet(cues: request.cues, speakerColors: request.speakerColors, speakerNames: speakerNames,
                                   language: language, isCurrent: batchRequestIsCurrent(request)) { operation in
                applyBatchEdit(request, operation: operation)
            }
        }
        .sheet(item: $splitRequest) { request in
            SubtitleSplitSheet(cue: request.cue, time: request.time, language: language,
                               isCurrent: slot.url == request.fileURL
                                   && slot.cues.contains(request.cue) && transcribingCueID == nil) { source, translation in
                applySplit(request, sourceOffset: source, translationOffset: translation)
            }
        }
        .sheet(isPresented: $isTimingAdjustmentPresented) {
            TimingAdjustmentSheet(
                language: language,
                cueCount: slot.cues.count,
                mode: $timingAdjustmentMode,
                shiftSeconds: $timingShiftSeconds,
                gapSeconds: $timingGapSeconds,
                apply: applyTimingAdjustment,
                cues: slot.cues,
                calibrate: applyTimingCalibration
            )
        }
    }

    private func finishEditorSession() {
        if playback.isLooping || playback.isReviewing { playback.seek(to: playback.currentTime, pause: true) }
        if let editingSpeakerCueID {
            commitSpeakerEdit(for: editingSpeakerCueID)
        }
        previewSyncTask?.cancel()
        termStatsTask?.cancel()
        waveformReloadTask?.cancel()
        syncPreviewText()
    }

    private func configureUndoController() {
        undoController.restoreHandler = { snapshot, actionName in
            restoreUndoSnapshot(snapshot, actionName: actionName)
        }
    }

    private func makeUndoSnapshot() -> SubtitleUndoSnapshot {
        SubtitleUndoSnapshot(
            cues: slot.cues,
            selectedCueID: slot.selectedCueID,
            speakerColors: slot.speakerColors,
            batchCueIDs: batchCueIDs
        )
    }

    /// Full-array snapshots get expensive with thousands of cues, so cap the
    /// undo stack; NSUndoManager drops the oldest entries beyond this depth.
    private static let maxUndoLevels = 80

    private func registerUndo(_ actionNameKey: String, before snapshot: SubtitleUndoSnapshot? = nil) {
        guard let undoManager else { return }
        // Any registration ends the current text-editing burst so a later
        // keystroke starts a fresh undo step instead of merging across it.
        if actionNameKey != "undo.editSubtitle" {
            textEditUndoBurst = nil
        }
        undoManager.levelsOfUndo = Self.maxUndoLevels
        let snapshot = snapshot ?? makeUndoSnapshot()
        undoManager.registerUndo(withTarget: undoController) { controller in
            controller.restore(snapshot, actionName: actionNameKey)
        }
        undoManager.setActionName(Copy.text(actionNameKey, language: language))
    }

    private func restoreUndoSnapshot(_ snapshot: SubtitleUndoSnapshot, actionName: String) {
        let redoSnapshot = makeUndoSnapshot()
        applyUndoSnapshot(snapshot)
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: undoController) { controller in
            controller.restore(redoSnapshot, actionName: actionName)
        }
        undoManager.setActionName(Copy.text(actionName, language: language))
    }

    private func applyUndoSnapshot(_ snapshot: SubtitleUndoSnapshot) {
        previewSyncTask?.cancel()
        termStatsTask?.cancel()
        timelineCueDragUndoSnapshot = nil
        textEditUndoBurst = nil
        slot.cues = snapshot.cues
        batchCueIDs = snapshot.batchCueIDs.intersection(Set(snapshot.cues.map(\.id)))
        isBatchSelecting = !batchCueIDs.isEmpty
        slot.speakerColors = snapshot.speakerColors
        if let selectedCueID = snapshot.selectedCueID,
           snapshot.cues.contains(where: { $0.id == selectedCueID }) {
            slot.selectedCueID = selectedCueID
        } else {
            slot.selectedCueID = snapshot.cues.first?.id
        }
        selectedTextRange = nil
        syncPreviewText()
    }

    private func registerTimelineCueDragUndoIfNeeded() {
        previewSyncTask?.cancel()
        if timelineCueDragUndoSnapshot == nil {
            timelineCueDragUndoSnapshot = makeUndoSnapshot()
        }
    }

    private func finishTimelineCueDragUndo() {
        guard let snapshot = timelineCueDragUndoSnapshot else { return }
        timelineCueDragUndoSnapshot = nil
        // Merely selecting a handle must not add an undo entry.
        if snapshot.cues != slot.cues {
            registerUndo("undo.adjustTiming", before: snapshot)
        }
        scheduleCueTimingSync(for: slot.cues)
    }

    private var timecodeLabel: String {
        let current = SubtitleDocument.displayTime(playback.currentTime)
        let total = SubtitleDocument.displayTime(duration)
        return "\(current) / \(total)"
    }

    private func scheduleCueTimingSync(for cues: [SubtitleCue]) {
        previewSyncTask?.cancel()
        let fileID = slot.id
        let revision = slot.cuesRevision
        previewSyncTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
            guard !Task.isCancelled, slot.id == fileID, slot.cuesRevision == revision else { return }
            if let normalized = SubtitleDocument.normalizedIfNeeded(cues) { slot.cues = normalized }
            syncPreviewText()
        }
    }

    private func schedulePreviewTextSync() {
        previewSyncTask?.cancel()
        let fileID = slot.id
        let revision = slot.cuesRevision
        previewSyncTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(220)) } catch { return }
            guard !Task.isCancelled, slot.id == fileID, slot.cuesRevision == revision else { return }
            syncPreviewText()
        }
    }

    private func syncPreviewText() {
        let text = previewCache.value(cues: slot.cues, fileID: slot.id,
                                      revision: slot.cuesRevision, format: slot.outputFormat)
        if slot.previewText != text { slot.previewText = text }
    }

    private func ensureSelectedCueIsValid() {
        guard let selectedCueID = slot.selectedCueID else { return }
        if !slot.cues.contains(where: { $0.id == selectedCueID }) {
            slot.selectedCueID = slot.cues.first?.id
        }
    }

    private func scheduleTermStatsSync(for cues: [SubtitleCue]) {
        termStatsTask?.cancel()
        let fileID = slot.id
        let revision = slot.cuesRevision
        termStatsTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            guard !Task.isCancelled, slot.id == fileID, slot.cuesRevision == revision else { return }
            let worker = Task.detached(priority: .utility) { () -> ([SubtitleTermFrequency], [SubtitleEmotionFrequency]) in
                guard !Task.isCancelled else { return ([], []) }
                let terms = SubtitleTextStats.topTerms(in: cues, limit: 8)
                guard !Task.isCancelled else { return ([], []) }
                return (terms, SubtitleEmotionStats.frequencies(in: cues))
            }
            let (terms, emotions) = await withTaskCancellationHandler {
                await worker.value
            } onCancel: { worker.cancel() }
            guard !Task.isCancelled, slot.id == fileID, slot.cuesRevision == revision else { return }
            slot.frequentTerms = terms
            slot.emotionFrequencies = emotions
        }
    }

    private var timelinePanel: some View {
        VStack(alignment: .leading, spacing: isTimelineExpanded ? 8 : 6) {
            HStack {
                Label(Copy.text("editor.timeline", language: language), systemImage: "waveform")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if isLoadingWaveform {
                    MSubSpinner()
                        .controlSize(.small)
                }
                if !isTimelineExpanded {
                    Button {
                        playback.togglePlayPause()
                    } label: {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    }
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
                .help(Copy.text(isTimelineExpanded ? "editor.collapseTimeline" : "editor.expandTimeline", language: language))
            }

            if isTimelineExpanded {
                HStack(spacing: 8) {
                    Button {
                        timelineZoom = max(1.0, timelineZoom - 0.5)
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .help(Copy.text("editor.zoomOut", language: language))

                    TimelineZoomSlider(
                        value: $timelineZoom,
                        isDragging: $isTimelineZoomSliderDragging,
                        range: 1...maxTimelineZoom,
                        step: 0
                    )
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
                    .help(Copy.text("editor.zoomIn", language: language))

                    Spacer(minLength: 8)

                    Button {
                        playSelectedCue()
                    } label: {
                        Image(systemName: "play.rectangle")
                    }
                    .disabled(selectedCueIndex == nil)
                    .help(Copy.text("editor.playCurrent.help", language: language))

                    Button {
                        insertCueAtPlayhead()
                    } label: {
                        Image(systemName: "plus.rectangle")
                    }
                    .accessibilityLabel(Copy.text("editor.addAtPlayhead", language: language))
                    .help(Copy.text("editor.addAtPlayhead.help", language: language))

                    Button {
                        playback.togglePlayPause()
                    } label: {
                        Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    }
                    .help(Copy.text(playback.isPlaying ? "editor.pause" : "editor.play", language: language))
                }

                PlaybackZoomableTimeline(
                    cuesRevision: slot.cuesRevision,
                    cueIndex: cueIndexData,
                    overlaps: overlapCache.value(cues: slot.cues, revision: slot.cuesRevision),
                    cues: $slot.cues,
                    selectedCueID: $slot.selectedCueID,
                    highlightTerm: $selectedFrequentTerm,
                    findTerm: activeFindHighlightTerm,
                    findMarkers: activeFindHighlightTerm == nil ? .empty : searchResults.markers,
                    highlightMarkers: highlightMarkers,
                    waveform: waveform,
                    duration: duration,
                    zoom: $timelineZoom,
                    zoomRange: 1...maxTimelineZoom,
                    playback: playback,
                    centerRequest: timelineCenterRequest,
                    isSliderZooming: $isTimelineZoomSliderDragging,
                    activeSpeakerName: activeTimelineSpeakerName,
                    speakerColors: settings.timelineSpeakerMarkersEnabled ? slot.speakerColors : [:],
                    language: language,
                    onSeek: { time in
                        playback.seek(to: time, pause: true)
                    },
                    onScrub: { time in
                        playback.scrub(to: time)
                    },
                    onCueTimingEditBegan: registerTimelineCueDragUndoIfNeeded,
                    onCueTimingEditEnded: finishTimelineCueDragUndo,
                    cueActions: timelineCueActions
                )
                .frame(height: 128)
            } else {
                PlaybackCompactTimelineStrip(
                    cuesRevision: slot.cuesRevision,
                    cues: slot.cues,
                    selectedCueID: $slot.selectedCueID,
                    highlightTerm: $selectedFrequentTerm,
                    findTerm: activeFindHighlightTerm,
                    findMarkers: activeFindHighlightTerm == nil ? .empty : searchResults.markers,
                    highlightMarkers: highlightMarkers,
                    waveform: waveform,
                    duration: duration,
                    playback: playback,
                    activeSpeakerName: activeTimelineSpeakerName,
                    onSeek: { time in
                        playback.seek(to: time, pause: true)
                    }
                )
                .frame(height: 34)
            }
        }
        .msubCompactActions()
        .padding(isTimelineExpanded ? 12 : 10)
        .msubPanel(cornerRadius: 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: maxTimelineZoom) { _, newValue in
            timelineZoom = min(timelineZoom, newValue)
        }
    }

    private var subtitleBlocks: some View {
        let selectedCueID = slot.selectedCueID
        let originalCuesByID = cachedOriginalCuesByID
        let speakerColorsByName = cachedSpeakerColorsByName
        let canCycleSpeakers = !speakerNames.isEmpty

        return VStack(spacing: 8) {
            batchSelectionBar
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(slot.cues) { cue in
                            let originalCue = originalCuesByID[cue.id]
                            HStack(alignment: .top, spacing: 6) {
                                if isBatchSelecting {
                                    Toggle(String(format: Copy.text("editor.batch.selectCue", language: language), cue.index),
                                           isOn: Binding(get: { batchCueIDs.contains(cue.id) }, set: { selected in
                                               if selected { batchCueIDs.insert(cue.id) }
                                               else { batchCueIDs.remove(cue.id) }
                                           }))
                                        .toggleStyle(.checkbox)
                                        .labelsHidden()
                                        .padding(.top, 12)
                                }
                                SubtitleCueBlockRow(
                                    cue: cue,
                                    isSelected: cue.id == selectedCueID,
                                    canReset: canResetCue(cue, original: originalCue),
                                    select: { selectCueFromBlock(cue.id) },
                                    reset: { resetCue(cue.id) },
                                    duplicate: { duplicateCue(cue.id) },
                                    insertBefore: { insertCue(before: cue.id) },
                                    insertAfter: { insertCue(after: cue.id) },
                                    closeGap: { closeGap(around: cue.id) },
                                    delete: { deleteCue(cue.id) },
                                    deleteMatching: { deleteMatchingCues(referenceCueID: cue.id) },
                                    language: language,
                                    speakerColor: speakerColor(forCue: cue, colorCache: speakerColorsByName),
                                    cycleSpeaker: canCycleSpeakers ? { cycleSpeaker(for: cue.id) } : nil
                                )
                            }
                            .id(cue.id)
                        }
                    }
                    .padding(2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(2)
                .msubPanel(cornerRadius: 10)
                .focusable()
                .focusEffectDisabled()
                .focused($isSubtitleListFocused)
                .onKeyPress(phases: .down) { press in
                    let cmd = press.modifiers.contains(.command)
                    let shift = press.modifiers.contains(.shift)
                    switch press.key {
                    case KeyEquivalent("a") where cmd && isBatchSelecting:
                        batchCueIDs = Set(slot.cues.map(\.id))
                        return .handled
                    case .escape where isBatchSelecting:
                        isBatchSelecting = false
                        batchCueIDs = []
                        return .handled
                    case .upArrow:
                        cmd ? selectBoundaryCue(first: true) : selectAdjacentCue(offset: -1)
                        return .handled
                    case .downArrow:
                        cmd ? selectBoundaryCue(first: false) : selectAdjacentCue(offset: 1)
                        return .handled
                    case .leftArrow:
                        if cmd {
                            jumpToAdjacentCue(offset: -1)
                        } else {
                            seekRelative(shift ? -5.0 : -1.0)
                        }
                        return .handled
                    case .rightArrow:
                        if cmd {
                            jumpToAdjacentCue(offset: 1)
                        } else {
                            seekRelative(shift ? 5.0 : 1.0)
                        }
                        return .handled
                    case .home:
                        selectBoundaryCue(first: true)
                        return .handled
                    case .end:
                        selectBoundaryCue(first: false)
                        return .handled
                    case .space:
                        playback.togglePlayPause()
                        return .handled
                    case KeyEquivalent("k") where cmd:
                        insertCueAfterSelection()
                        return .handled
                    case KeyEquivalent(";") where cmd:
                        setSelectedCueStartToPlayhead()
                        return .handled
                    case KeyEquivalent("'") where cmd:
                        setSelectedCueEndToPlayhead()
                        return .handled
                    default:
                        return .ignored
                    }
                }
                .onChange(of: slot.selectedCueID) { _, newValue in
                    guard let newValue else { return }
                    scheduleCueListScroll(to: newValue, proxy: proxy, initial: false)
                }
                .onAppear {
                    guard let selectedID = slot.selectedCueID else { return }
                    scheduleCueListScroll(to: selectedID, proxy: proxy, initial: true)
                }
                .onDisappear {
                    cueListScrollTask?.cancel()
                    cueListScrollTask = nil
                }
            }
        }
    }

    private var batchSelectionBar: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $isBatchSelecting) {
                Label(Copy.text("editor.batch.select", language: language), systemImage: "checklist")
            }
            .toggleStyle(.button)
            .onChange(of: isBatchSelecting) { _, enabled in
                if !enabled { batchCueIDs = [] }
            }
            Spacer(minLength: 0)
            if isBatchSelecting {
                Text(String(format: Copy.text("editor.batch.count", language: language), batchCueIDs.count))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Menu {
                    Button(Copy.text("editor.batch.all", language: language)) { batchCueIDs = Set(slot.cues.map(\.id)) }
                    Button(Copy.text("editor.batch.none", language: language)) { batchCueIDs = [] }
                } label: {
                    Label(Copy.text("editor.batch.select", language: language), systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .fixedSize()
                Button {
                    let cues = slot.cues.filter { batchCueIDs.contains($0.id) }
                    guard !cues.isEmpty, transcribingCueID == nil else { return }
                    playback.seek(to: playback.currentTime, pause: true)
                    batchRequest = .init(fileID: slot.id, cues: cues, speakerColors: slot.speakerColors)
                } label: {
                    Label(Copy.text("editor.batch.title", language: language), systemImage: "slider.horizontal.3")
                        .labelStyle(.iconOnly)
                }
                .help(Copy.text("editor.batch.title", language: language))
                .disabled(batchCueIDs.isEmpty || transcribingCueID != nil)
            }
        }
        .msubCompactActions()
    }

    private func batchRequestIsCurrent(_ request: SubtitleBatchRequest) -> Bool {
        slot.id == request.fileID && transcribingCueID == nil && slot.speakerColors == request.speakerColors
            && SubtitleBatchEdit.replacing(request.cues, with: request.cues, in: slot.cues) != nil
    }

    private func applyBatchEdit(_ request: SubtitleBatchRequest, operation: SubtitleBatchEdit.Operation) {
        guard batchRequestIsCurrent(request),
              let changed = SubtitleBatchEdit.applying(operation, to: request.cues, speakerColors: request.speakerColors),
              changed != request.cues,
              let cues = SubtitleBatchEdit.replacing(request.cues, with: changed, in: slot.cues) else { return }
        let snapshot = makeUndoSnapshot()
        previewSyncTask?.cancel()
        textEditUndoBurst = nil
        selectedTextRange = nil
        slot.cues = SubtitleDocument.normalize(cues)
        registerUndo("undo.batchEdit", before: snapshot)
        scheduleCueTimingSync(for: slot.cues)
    }

    private func scheduleCueListScroll(to cueID: SubtitleCue.ID, proxy: ScrollViewProxy, initial: Bool) {
        cueListScrollTask?.cancel()
        let delay: Duration = initial
            ? .milliseconds(80)
            : (slot.cues.count > 600 ? .milliseconds(45) : .zero)
        cueListScrollTask = Task { @MainActor in
            if delay != .zero {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
            }
            withAnimation(.easeInOut(duration: initial ? 0.18 : 0.16)) {
                proxy.scrollTo(cueID, anchor: .center)
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
                    Picker(Copy.text("editor.findScope", language: language), selection: $findScope) {
                        ForEach(SubtitleSearchScope.allCases) { scope in
                            Text(Copy.text(scope.titleKey, language: language)).tag(scope)
                        }
                    }
                    .pickerStyle(.menu)
                    .help(Copy.text("editor.findScope.help", language: language))

                    TextField(Copy.text("editor.find", language: language), text: $findText)
                        .textFieldStyle(.roundedBorder)
                        .focused($isFindFieldFocused)

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
        .msubCompactActions()
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .msubPanel(cornerRadius: 10)
        .onChange(of: findText) { _, _ in
            findStatus = ""
        }
        .onChange(of: matchCase) { _, _ in
            findStatus = ""
        }
        .onChange(of: findScope) { _, _ in
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

    private func reviewPlaybackControls(cue: SubtitleCue) -> some View {
        HStack(spacing: 8) {
            Group {
                Button {
                    if playback.isReviewing || playback.isLooping {
                        playback.seek(to: playback.currentTime, pause: true)
                    } else {
                        playback.playReview(cues: slot.cues, selectedID: cue.id,
                                            padding: reviewPadding, advance: reviewAutoAdvance)
                    }
                } label: {
                    Label(Copy.text(playback.isReviewing || playback.isLooping ? "review.stop" : "review.play", language: language),
                          systemImage: playback.isReviewing || playback.isLooping ? "stop.fill" : "play.fill")
                }
                Button {
                    playback.playReview(cues: slot.cues, selectedID: cue.id,
                                        padding: reviewPadding, advance: false, loop: true)
                } label: {
                    Label(Copy.text("review.loop", language: language), systemImage: "repeat.1")
                }
                .disabled(playback.isLooping)
            }
            .disabled(!cue.start.isFinite || !cue.end.isFinite || cue.start < 0 || cue.end <= cue.start)
            Menu {
                Picker(Copy.text("review.padding", language: language), selection: $reviewPadding) {
                    ForEach([0.0, 0.25, 0.5, 1.0], id: \.self) { value in
                        Text(value, format: .number.precision(.fractionLength(0...2))).tag(value)
                    }
                }
                .pickerStyle(.menu)
                Toggle(Copy.text("review.advance", language: language), isOn: $reviewAutoAdvance)
            } label: {
                Label(Copy.text("review.options", language: language), systemImage: "slider.horizontal.3")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel(Copy.text("review.options", language: language))
            .help(Copy.text("review.options", language: language) + "\n" + Copy.text("review.help", language: language))
            Spacer(minLength: 0)
        }
        .msubCompactActions()
    }

    @ViewBuilder
    private var selectedCueEditor: some View {
        if let selectedCueIndex, slot.cues.indices.contains(selectedCueIndex) {
            VStack(alignment: .leading, spacing: 10) {
                let selectedCue = slot.cues[selectedCueIndex]
                let selectedCueID = selectedCue.id
                HStack(spacing: 8) {
                    Text(Copy.text("editor.selected", language: language))
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    CueStatusBadges(
                        cue: selectedCue,
                        canReset: canResetCue(selectedCueID),
                        language: language,
                        showsSpeaker: false,
                        onReset: { resetSelectedCue() },
                        editedFields: editedFields(for: selectedCueID)
                    )
                }

                reviewPlaybackControls(cue: selectedCue)

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

                speakerControls(cueID: selectedCueID, cue: selectedCue)

                bilingualCueEditor(cue: selectedCue)

                if let onTranslateCue {
                    HStack(spacing: 6) {
                        Image(systemName: "character.bubble")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Picker("", selection: $inlineTranslationLanguage) {
                            ForEach(TranslationLanguageChoice.common) { choice in
                                Text(choice.localizedTitle).tag(choice)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .controlSize(.mini)
                        .fixedSize()
                        Button {
                            onTranslateCue(selectedCueID, inlineTranslationLanguage, .replace)
                        } label: {
                            Text(Copy.text("translation.translateAndReplace", language: language))
                                .font(.caption)
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                        .help(Copy.text("translation.translateAndReplace.help", language: language))

                        Button {
                            onTranslateCue(selectedCueID, inlineTranslationLanguage, .bilingual)
                        } label: {
                            Text(Copy.text("translation.translateAndCoexist", language: language))
                                .font(.caption)
                                .frame(maxWidth: .infinity)
                        }
                        .controlSize(.small)
                        .buttonStyle(.bordered)
                        .help(Copy.text("translation.translateAndCoexist.help", language: language))
                    }
                }

                HStack(spacing: 8) {
                    compactNumberField(
                        Copy.text("editor.start", language: language),
                        value: cueStartBinding(for: selectedCueID)
                    )
                    .frame(maxWidth: .infinity)

                    compactNumberField(
                        Copy.text("editor.end", language: language),
                        value: cueEndBinding(for: selectedCueID)
                    )
                    .frame(maxWidth: .infinity)
                }

                HStack {
                    Text(Copy.text("editor.duration", language: language))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.2fs", slot.cues[selectedCueIndex].duration))
                        .font(.caption.monospacedDigit().bold())
                    Spacer()
                    Text(Copy.text("editor.speechRate", language: language))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(speechRateText(for: slot.cues[selectedCueIndex]))
                        .font(.caption.monospacedDigit().bold())
                }

                subtitleStyleControls

                reTranscribeCueButton(cueID: selectedCueID, cueIsEmpty: slot.cues[selectedCueIndex].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
            .msubPanel(cornerRadius: 10)
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
            .msubPanel(cornerRadius: 10)
        }
    }

    private func speakerControls(cueID: SubtitleCue.ID, cue: SubtitleCue) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if editingSpeakerCueID == cueID {
                HStack(spacing: 6) {
                    Image(systemName: "person.crop.circle.fill")
                        .foregroundStyle(.secondary)
                    TextField(Copy.text("editor.speaker.rename", language: language), text: $speakerEditText)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(width: 104)
                        .focused($isSpeakerEditorFocused)
                        .onSubmit {
                            commitSpeakerEdit(for: cueID)
                        }

                    Spacer(minLength: 14)
                    speakerEditColorControls(cueID: cueID)
                }

                let candidates = speakerCandidateNames()
                if !candidates.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(candidates, id: \.self) { speaker in
                                Button {
                                    chooseSpeakerCandidate(speaker, for: cueID)
                                } label: {
                                    Text(speaker)
                                        .font(.caption.weight(.medium))
                                        .lineLimit(1)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(.thinMaterial, in: Capsule())
                                        .overlay(Capsule().stroke(.quaternary, lineWidth: 0.7))
                                }
                                .buttonStyle(.plain)
                                .help(Copy.text("editor.speaker.merge.help", language: language))
                            }
                        }
                        .padding(.vertical, 1)
                    }
                    .frame(height: 28)
                }
            } else {
                HStack(spacing: 6) {
                    Button {
                        beginSpeakerEdit(cueID)
                    } label: {
                        SpeakerBadge(speaker: SubtitleDocument.normalizedSpeakerName(cue.speaker), language: language)
                    }
                    .buttonStyle(.plain)
                    .help(Copy.text("editor.speaker.edit.help", language: language))
                    .contextMenu {
                        speakerAssignmentMenuContent(cueID: cueID)
                    }

                    Spacer(minLength: 4)

                    Menu {
                        speakerAssignmentMenuContent(cueID: cueID)
                    } label: {
                        Image(systemName: "person.crop.circle.badge.plus")
                            .frame(width: 24, height: 24)
                    }
                    .menuStyle(.button)
                    .controlSize(.small)
                    .help(Copy.text("editor.speaker.change.help", language: language))
                }
            }
        }
    }

    private func speakerEditColorControls(cueID: SubtitleCue.ID) -> some View {
        HStack(spacing: 6) {
            ColorPicker("", selection: $speakerStyleColor, supportsOpacity: false)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 30)
                .help(Copy.text("editor.speaker.color.help", language: language))

            Button {
                applySpeakerColor(speakerStyleColor, for: cueID)
            } label: {
                Image(systemName: "paintpalette")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(activeSpeakerNameForColor(cueID) == nil)
            .help(Copy.text("editor.speaker.applyColor.help", language: language))

            Button {
                commitSpeakerEdit(for: cueID)
            } label: {
                Image(systemName: "checkmark")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(Copy.text("editor.speaker.apply.help", language: language))

            Button {
                cancelSpeakerEdit()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help(Copy.text("editor.speaker.cancel.help", language: language))
        }
        .fixedSize()
    }

    @ViewBuilder
    private func speakerAssignmentMenuContent(cueID: SubtitleCue.ID) -> some View {
        Button {
            assignSpeaker(nil, to: cueID)
        } label: {
            Label(Copy.text("editor.speaker.clear", language: language), systemImage: "xmark.circle")
        }

        if !speakerNames.isEmpty {
            Divider()
            ForEach(speakerNames, id: \.self) { speaker in
                Button {
                    assignSpeaker(speaker, to: cueID)
                } label: {
                    Label(speaker, systemImage: "person.crop.circle")
                }
            }
        }

        Divider()

        Button {
            assignSpeaker(nextSpeakerName(), to: cueID)
        } label: {
            Label(Copy.text("editor.speaker.new", language: language), systemImage: "plus")
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
                        MSubSpinner()
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
            HStack {
                Text(Copy.text("editor.style", language: language))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let selectedCueIndex, slot.cues[selectedCueIndex].bilingualText != nil {
                    Picker(Copy.text("editor.style.scope", language: language), selection: $styleScope) {
                        ForEach(SubtitleCueStyle.Scope.allCases) { scope in
                            Text(Copy.text(scope.titleKey, language: language)).tag(scope)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .msubCompactActions()
                    .help(Copy.text("editor.style.scope.help", language: language))
                }
            }

            HStack(spacing: 6) {
                Button {
                    toggleMarkupTag("b")
                } label: {
                    Image(systemName: "bold")
                        .frame(maxWidth: .infinity, minHeight: 14)
                }
                .tint(hasOuterMarkupTag("b") ? .accentColor : nil)
                .help(Copy.text("editor.style.bold.help", language: language))

                Button {
                    toggleMarkupTag("i")
                } label: {
                    Image(systemName: "italic")
                        .frame(maxWidth: .infinity, minHeight: 14)
                }
                .tint(hasOuterMarkupTag("i") ? .accentColor : nil)
                .help(Copy.text("editor.style.italic.help", language: language))

                Button {
                    toggleMarkupTag("u")
                } label: {
                    Image(systemName: "underline")
                        .frame(maxWidth: .infinity, minHeight: 14)
                }
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
                        .frame(maxWidth: .infinity, minHeight: 14)
                }
                .tint(hasOuterFontColor ? .accentColor : nil)
                .help(Copy.text("editor.style.applyColor.help", language: language))

                Button {
                    clearCueStyle()
                } label: {
                    Image(systemName: "eraser")
                        .frame(maxWidth: .infinity, minHeight: 14)
                }
                .help(Copy.text("editor.style.clear.help", language: language))
            }
            .msubCompactActions()
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

    private func speechRateText(for cue: SubtitleCue) -> String {
        let units = lexicalUnitCount(in: cue.text)
        let rate = cue.duration > 0 ? Double(units) / cue.duration : 0
        return String(format: Copy.text("editor.speechRate.value", language: language), rate)
    }

    private func lexicalUnitCount(in text: String) -> Int {
        var count = 0
        var isInsideWord = false
        func flushWord() {
            if isInsideWord {
                count += 1
                isInsideWord = false
            }
        }

        for scalar in fontMarkupRemoved(from: text).unicodeScalars {
            if isHanScalar(scalar) {
                flushWord()
                count += 1
            } else if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) {
                isInsideWord = true
            } else {
                flushWord()
            }
        }
        flushWord()
        return count
    }

    private func isHanScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0x2A700...0x2B73F, 0x2B740...0x2B81F, 0x2B820...0x2CEAF, 0xF900...0xFAFF:
            return true
        default:
            return false
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
                let bounded = max(0, min(newValue, slot.cues[index].end - 0.05))
                guard bounded != slot.cues[index].start else { return }
                let snapshot = makeUndoSnapshot()
                slot.cues[index].start = bounded
                registerUndo("undo.adjustTiming", before: snapshot)
                scheduleCueTimingSync(for: slot.cues)
            }
        )
    }

    @ViewBuilder
    private func bilingualCueEditor(cue: SubtitleCue) -> some View {
        HStack {
            Text(Copy.text(cue.bilingualText == nil ? "bilingual.text" : "bilingual.title", language: language))
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            Menu {
                Button(Copy.text("editor.split.title", language: language)) {
                    presentSplit(cue)
                }
                .disabled(!SubtitleCueSplit.canSplit(cue, at: playback.currentTime) || transcribingCueID != nil)
                .help(Copy.text("editor.split.menuHelp", language: language))
                Divider()
                Button(Copy.text("editor.mergeNext", language: language)) { mergeWithNext(cue.id) }
                    .disabled(mergeCandidate(for: cue.id) == nil || transcribingCueID != nil)
            } label: {
                Label(Copy.text("editor.cueActions", language: language), systemImage: "ellipsis.circle")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(Copy.text("editor.cueActions", language: language))
            Menu {
                if let pair = cue.bilingualText {
                    Button(Copy.text("bilingual.reverse", language: language)) {
                        var changed = pair
                        changed.translationFirst.toggle()
                        updateBilingual(cueID: cue.id, value: changed, typing: false)
                    }
                } else {
                    Button(Copy.text("bilingual.enable", language: language)) {
                        updateBilingual(cueID: cue.id, value: .init(source: cue.text, translation: ""), typing: false)
                    }
                }
                Divider()
                Button(Copy.text("bilingual.exportSource", language: language)) { exportBilingualLane(translated: false) }
                Button(Copy.text("bilingual.exportTranslation", language: language)) { exportBilingualLane(translated: true) }
            } label: {
                Label(Copy.text("bilingual.title", language: language), systemImage: "character.bubble")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        if cue.bilingualText != nil {
            Text(Copy.text("bilingual.source", language: language)).font(.caption)
            TextEditor(text: bilingualBinding(cueID: cue.id, source: true))
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(height: 76)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary).allowsHitTesting(false))
                .accessibilityLabel(Copy.text("bilingual.source", language: language))
            Text(Copy.text("bilingual.translation", language: language)).font(.caption)
            TextEditor(text: bilingualBinding(cueID: cue.id, source: false))
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(height: 76)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary).allowsHitTesting(false))
                .accessibilityLabel(Copy.text("bilingual.translation", language: language))
            Text(Copy.text("bilingual.help", language: language))
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            SelectableTextEditor(text: cueTextBinding(for: cue.id), selection: $selectedTextRange) {}
                .frame(height: 118)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
        }
    }

    private func bilingualBinding(cueID: SubtitleCue.ID, source: Bool) -> Binding<String> {
        Binding {
            guard let index = cueIndex(for: cueID), let pair = slot.cues[index].bilingualText else { return "" }
            return source ? pair.source : pair.translation
        } set: { text in
            guard let index = cueIndex(for: cueID), var pair = slot.cues[index].bilingualText else { return }
            if source { pair.source = text } else { pair.translation = text }
            updateBilingual(cueID: cueID, value: pair, typing: true)
        }
    }

    private func updateBilingual(cueID: SubtitleCue.ID, value: SubtitleBilingualText, typing: Bool) {
        guard let index = cueIndex(for: cueID), slot.cues[index].bilingualText != value else { return }
        let now = Date()
        let continues = typing && (textEditUndoBurst.map { $0.cueID == cueID && now.timeIntervalSince($0.lastEdit) < 2 } ?? false)
        let snapshot = continues ? nil : makeUndoSnapshot()
        slot.cues[index].setBilingual(value)
        selectedTextRange = nil
        if let snapshot { registerUndo("undo.editSubtitle", before: snapshot) }
        textEditUndoBurst = typing ? (cueID: cueID, lastEdit: now) : nil
        schedulePreviewTextSync()
    }

    private func exportBilingualLane(translated: Bool) {
        let format = slot.outputFormat
        let cues = SubtitleDocument.monolingualCues(slot.cues, translated: translated)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = slot.url.deletingPathExtension().lastPathComponent
            + (translated ? ".translation." : ".source.") + format.rawValue
        panel.allowedContentTypes = [UTType(filenameExtension: format.rawValue) ?? .plainText]
        panel.canCreateDirectories = true
        panel.message = Copy.text("bilingual.exportHelp", language: language)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try SubtitleDocument.serialize(cues, format: format).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func cueTextBinding(for cueID: SubtitleCue.ID) -> Binding<String> {
        Binding(
            get: {
                guard let index = cueIndex(for: cueID) else { return "" }
                return slot.cues[index].text
            },
            set: { newValue in
                guard let index = cueIndex(for: cueID) else { return }
                guard newValue != slot.cues[index].text else { return }
                // Coalesce per-keystroke edits: snapshotting and registering
                // undo for every character is the main typing hotspot with
                // large cue lists, and floods the undo stack with one-char
                // steps. One registration per editing burst restores to the
                // pre-burst text, like a standard text editor.
                let now = Date()
                let continuesBurst = textEditUndoBurst.map {
                    $0.cueID == cueID && now.timeIntervalSince($0.lastEdit) < 2.0
                } ?? false
                if continuesBurst {
                    slot.cues[index].text = newValue
                } else {
                    let snapshot = makeUndoSnapshot()
                    slot.cues[index].text = newValue
                    registerUndo("undo.editSubtitle", before: snapshot)
                }
                textEditUndoBurst = (cueID: cueID, lastEdit: now)
                schedulePreviewTextSync()
            }
        )
    }

    private func assignSpeaker(_ speaker: String?, to cueID: SubtitleCue.ID, shouldRegisterUndo: Bool = true) {
        guard let index = cueIndex(for: cueID) else { return }
        let snapshot = makeUndoSnapshot()
        let normalized = SubtitleDocument.normalizedSpeakerName(speaker)
        var didChange = false
        if SubtitleDocument.normalizedSpeakerName(slot.cues[index].speaker) != normalized {
            slot.cues[index].speaker = normalized
            didChange = true
        }
        if applyStoredSpeakerColor(toCueAt: index) {
            didChange = true
        }
        if didChange {
            if shouldRegisterUndo {
                registerUndo("undo.editSpeaker", before: snapshot)
            }
            schedulePreviewTextSync()
        }
    }

    private func renameSpeaker(_ oldSpeaker: String, to newSpeaker: String?) {
        guard let old = SubtitleDocument.normalizedSpeakerName(oldSpeaker) else { return }
        let snapshot = makeUndoSnapshot()
        let normalizedNew = SubtitleDocument.normalizedSpeakerName(newSpeaker)
        let oldColor = slot.speakerColors[old]
        let targetColor: String?
        if let normalizedNew {
            if let existingColor = slot.speakerColors[normalizedNew] {
                targetColor = existingColor
            } else if let oldColor {
                slot.speakerColors[normalizedNew] = oldColor
                targetColor = oldColor
            } else {
                targetColor = nil
            }
        } else {
            targetColor = nil
        }
        if old != normalizedNew {
            slot.speakerColors.removeValue(forKey: old)
        }
        var didChange = false
        var originalIndexByID: [SubtitleCue.ID: Int] = [:]
        for (index, original) in slot.originalCues.enumerated() {
            originalIndexByID[original.id] = index
        }
        for index in slot.cues.indices {
            guard SubtitleDocument.normalizedSpeakerName(slot.cues[index].speaker) == old else { continue }
            slot.cues[index].speaker = normalizedNew
            if let targetColor {
                slot.cues[index] = SubtitleCueStyle.applying(.color(targetColor), to: slot.cues[index])
            }
            didChange = true
            // Mirror global speaker rename / recolor in originalCues so it isn't
            // treated as a per-cue edit by canResetCue / editedFields.
            if let originalIndex = originalIndexByID[slot.cues[index].id] {
                if SubtitleDocument.normalizedSpeakerName(slot.originalCues[originalIndex].speaker) == old {
                    slot.originalCues[originalIndex].speaker = normalizedNew
                }
                if let targetColor {
                    let updatedOriginal = SubtitleCueStyle.applying(.color(targetColor), to: slot.originalCues[originalIndex])
                    if updatedOriginal != slot.originalCues[originalIndex] {
                        slot.originalCues[originalIndex] = updatedOriginal
                    }
                }
            }
        }
        if snapshot != makeUndoSnapshot() {
            registerUndo("undo.editSpeaker", before: snapshot)
        }
        if didChange {
            schedulePreviewTextSync()
        }
    }

    private func beginSpeakerEdit(_ cueID: SubtitleCue.ID) {
        guard let index = cueIndex(for: cueID) else { return }
        let speaker = SubtitleDocument.normalizedSpeakerName(slot.cues[index].speaker)
        speakerEditOriginalName = speaker
        speakerEditText = speaker ?? ""
        if let speaker,
           let hex = slot.speakerColors[speaker],
           let color = color(fromHex: hex) {
            speakerStyleColor = color
        }
        editingSpeakerCueID = cueID
        Task { @MainActor in
            isSpeakerEditorFocused = true
        }
    }

    private func activeSpeakerNameForColor(_ cueID: SubtitleCue.ID) -> String? {
        if let speaker = speakerEditOriginalName {
            return speaker
        }
        if let index = cueIndex(for: cueID),
           let speaker = SubtitleDocument.normalizedSpeakerName(slot.cues[index].speaker) {
            return speaker
        }
        return SubtitleDocument.normalizedSpeakerName(speakerEditText)
    }

    private func applySpeakerColor(_ color: Color, for cueID: SubtitleCue.ID) {
        let snapshot = makeUndoSnapshot()
        var targetSpeaker = activeSpeakerNameForColor(cueID)
        if speakerEditOriginalName == nil,
           let typedSpeaker = SubtitleDocument.normalizedSpeakerName(speakerEditText),
           cueIndex(for: cueID) != nil {
            assignSpeaker(typedSpeaker, to: cueID, shouldRegisterUndo: false)
            speakerEditOriginalName = typedSpeaker
            targetSpeaker = typedSpeaker
        }
        guard let targetSpeaker else { return }

        let hex = hexString(for: color)
        slot.speakerColors[targetSpeaker] = hex
        var didChange = false
        var originalIndexByID: [SubtitleCue.ID: Int] = [:]
        for (index, original) in slot.originalCues.enumerated() {
            originalIndexByID[original.id] = index
        }
        for index in slot.cues.indices {
            guard SubtitleDocument.normalizedSpeakerName(slot.cues[index].speaker) == targetSpeaker else { continue }
            let updated = SubtitleCueStyle.applying(.color(hex), to: slot.cues[index])
            if updated != slot.cues[index] {
                slot.cues[index] = updated
                didChange = true
            }
            // Mirror the global speaker-color change in originalCues so it isn't
            // detected as a per-cue edit by canResetCue / editedFields.
            if let originalIndex = originalIndexByID[slot.cues[index].id] {
                let updatedOriginal = SubtitleCueStyle.applying(.color(hex), to: slot.originalCues[originalIndex])
                if updatedOriginal != slot.originalCues[originalIndex] {
                    slot.originalCues[originalIndex] = updatedOriginal
                }
            }
        }
        if snapshot != makeUndoSnapshot() {
            registerUndo("undo.editSpeaker", before: snapshot)
        }
        if didChange {
            schedulePreviewTextSync()
        }
    }

    private func commitSpeakerEdit(for cueID: SubtitleCue.ID) {
        guard editingSpeakerCueID == cueID else { return }
        let newSpeaker = SubtitleDocument.normalizedSpeakerName(speakerEditText)
        if let original = speakerEditOriginalName {
            renameSpeaker(original, to: newSpeaker)
        } else {
            assignSpeaker(newSpeaker, to: cueID)
        }
        cancelSpeakerEdit()
    }

    private func cancelSpeakerEdit() {
        editingSpeakerCueID = nil
        speakerEditOriginalName = nil
        speakerEditText = ""
        isSpeakerEditorFocused = false
    }

    private func chooseSpeakerCandidate(_ speaker: String, for cueID: SubtitleCue.ID) {
        if let original = speakerEditOriginalName {
            renameSpeaker(original, to: speaker)
        } else {
            assignSpeaker(speaker, to: cueID)
        }
        cancelSpeakerEdit()
    }

    private func speakerCandidateNames() -> [String] {
        return speakerNames.filter { speaker in
            speaker != speakerEditOriginalName
        }
    }

    private func applyStoredSpeakerColor(toCueAt index: Int) -> Bool {
        guard slot.cues.indices.contains(index),
              let speaker = SubtitleDocument.normalizedSpeakerName(slot.cues[index].speaker),
              let hex = slot.speakerColors[speaker] else {
            return false
        }
        let cueID = slot.cues[index].id
        let updated = SubtitleCueStyle.applying(.color(hex), to: slot.cues[index])
        let changedCue = updated != slot.cues[index]
        if changedCue {
            slot.cues[index] = updated
        }
        if let originalIndex = slot.originalCues.firstIndex(where: { $0.id == cueID }) {
            let updatedOriginal = SubtitleCueStyle.applying(.color(hex), to: slot.originalCues[originalIndex])
            if updatedOriginal != slot.originalCues[originalIndex] {
                slot.originalCues[originalIndex] = updatedOriginal
            }
        }
        return changedCue
    }

    private func nextSpeakerName() -> String {
        var number = max(1, speakerNames.count + 1)
        var candidate = String(format: Copy.text("editor.speaker.newName", language: language), number)
        while speakerNames.contains(candidate) {
            number += 1
            candidate = String(format: Copy.text("editor.speaker.newName", language: language), number)
        }
        return candidate
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
                let bounded = max(slot.cues[index].start + 0.05, min(upper, newValue))
                guard bounded != slot.cues[index].end else { return }
                let snapshot = makeUndoSnapshot()
                slot.cues[index].end = bounded
                registerUndo("undo.adjustTiming", before: snapshot)
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
        let targetSamples = isTimelineExpanded ? waveformTargetSamples : min(waveformTargetSamples, 720)
        let sourceKey = "\(slot.url.standardizedFileURL.path)#\(slot.duration)#\(targetSamples)"
        // The collapsed timeline only needs a lightweight strip. Full-resolution
        // waveform loading is deferred until the user expands the editor, which
        // prevents long videos from keeping CPU busy right after transcription.
        guard !slot.cues.isEmpty else {
            waveform = WaveformSamples([])
            waveformSourceKey = nil
            isLoadingWaveform = false
            return
        }
        guard waveformSourceKey != sourceKey || waveform.values.count < targetSamples else { return }
        guard !isLoadingWaveform else { return }
        isLoadingWaveform = true
        // Containers AVAssetReader can't fully demux (e.g., MKV) would yield a
        // truncated waveform. Route through AudioSource so unsupported sources
        // are transparently transcoded to a clean m4a before sampling.
        let audioURL = await AudioSource.resolve(slot.url)
        let needsFreshPreview = waveformSourceKey != sourceKey || waveform.values.isEmpty
        if needsFreshPreview {
            let previewSamples = min(targetSamples, 720)
            let previewValues = await WaveformLoader.samples(for: audioURL, targetSamples: previewSamples)
            guard !Task.isCancelled else {
                isLoadingWaveform = false
                return
            }
            waveform = WaveformSamples(previewValues)
            waveformSourceKey = sourceKey
            if previewSamples >= targetSamples {
                isLoadingWaveform = false
                return
            }
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else {
                isLoadingWaveform = false
                return
            }
        }
        let values = await WaveformLoader.samples(for: audioURL, targetSamples: targetSamples)
        guard !Task.isCancelled else {
            isLoadingWaveform = false
            return
        }
        waveform = WaveformSamples(values)
        waveformSourceKey = sourceKey
        let needsHigherResolution = isTimelineExpanded && waveformTargetSamples > targetSamples
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

    private func selectCueFromBlock(_ cueID: SubtitleCue.ID) {
        slot.selectedCueID = cueID
        timelineCenterRequest = TimelineCenterRequest(cueID: cueID)
        isSubtitleListFocused = true
    }

    private func selectAdjacentCue(offset: Int) {
        guard !slot.cues.isEmpty else { return }
        let current = selectedCueIndex ?? (offset > 0 ? -1 : slot.cues.count)
        let target = max(0, min(slot.cues.count - 1, current + offset))
        guard target != selectedCueIndex else { return }
        selectCueFromBlock(slot.cues[target].id)
    }

    private func selectBoundaryCue(first: Bool) {
        guard let cue = first ? slot.cues.first : slot.cues.last else { return }
        selectCueFromBlock(cue.id)
    }

    private func jumpToAdjacentCue(offset: Int) {
        guard !slot.cues.isEmpty else { return }
        let current = selectedCueIndex ?? (offset > 0 ? -1 : slot.cues.count)
        let target = max(0, min(slot.cues.count - 1, current + offset))
        let cue = slot.cues[target]
        selectCueFromBlock(cue.id)
        playback.seek(to: cue.start)
    }

    private func seekRelative(_ deltaSeconds: Double) {
        let target = max(0, playback.currentTime + deltaSeconds)
        let clamped = duration > 0 ? min(target, duration) : target
        playback.seek(to: clamped)
    }

    private func setSelectedCueStartToPlayhead() {
        guard let index = selectedCueIndex else { return }
        let cueID = slot.cues[index].id
        cueStartBinding(for: cueID).wrappedValue = playback.currentTime
    }

    private func setSelectedCueEndToPlayhead() {
        guard let index = selectedCueIndex else { return }
        let cueID = slot.cues[index].id
        cueEndBinding(for: cueID).wrappedValue = playback.currentTime
    }

    private func insertCueAfterSelection() {
        if let selectedCueID = slot.selectedCueID {
            insertCue(after: selectedCueID)
        } else {
            insertCue(at: slot.cues.count, start: 0, end: 2, text: "")
        }
    }

    private func insertCueAtPlayhead() {
        let timelineDuration = max(duration, 0.05)
        let start = min(max(0, playback.currentTime), max(0, timelineDuration - 0.05))
        let insertionIndex = slot.cues.firstIndex { $0.start > start } ?? slot.cues.count
        let next = insertionIndex < slot.cues.count ? slot.cues[insertionIndex] : nil
        var end = min(start + 2.0, max(start + 0.05, timelineDuration))
        if let next, next.start > start + 0.2 {
            end = min(end, next.start - 0.05)
        }
        insertCue(at: insertionIndex, start: start, end: max(start + 0.05, end), text: "")
    }

    private var canResetSelectedCue: Bool {
        guard let selectedCueIndex,
              let original = originalCue(for: slot.cues[selectedCueIndex].id) else { return false }
        let current = slot.cues[selectedCueIndex]
        return current.start != original.start
            || current.end != original.end
            || current.text != original.text
            || current.confidence != original.confidence
            || SubtitleDocument.normalizedSpeakerName(current.speaker) != SubtitleDocument.normalizedSpeakerName(original.speaker)
    }

    private var timelineCueActions: TimelineCueActions {
        TimelineCueActions(
            canReset: { canResetCue($0) },
            reset: { resetCue($0) },
            duplicate: { duplicateCue($0) },
            insertBefore: { insertCue(before: $0) },
            insertAfter: { insertCue(after: $0) },
            closeGap: { closeGap(around: $0) },
            delete: { deleteCue($0) },
            deleteMatching: { deleteMatchingCues(referenceCueID: $0) }
        )
    }

    private func applyTimingAdjustment() {
        switch timingAdjustmentMode {
        case .shift:
            shiftAllCues(by: timingShiftSeconds)
        case .closeGaps:
            closeAllGaps(targetGap: timingGapSeconds)
        case .calibrate:
            break // The sheet supplies its validated two-point mapping separately.
        }
    }

    private func applyTimingCalibration(_ calibration: SubtitleTimingCalibration) {
        guard let adjusted = try? calibration.applying(to: slot.cues), adjusted != slot.cues else { return }
        let snapshot = makeUndoSnapshot()
        previewSyncTask?.cancel()
        playback.seek(to: playback.currentTime, pause: true)
        slot.cues = adjusted
        registerUndo("undo.adjustTiming", before: snapshot)
        syncPreviewText()
    }

    private func shiftAllCues(by seconds: Double) {
        guard !slot.cues.isEmpty, seconds.isFinite else { return }
        let earliestStart = slot.cues.map(\.start).min() ?? 0
        let safeOffset = max(seconds, -earliestStart)
        guard abs(safeOffset) > 0.0001 else { return }
        let snapshot = makeUndoSnapshot()
        previewSyncTask?.cancel()
        slot.cues = SubtitleDocument.normalize(slot.cues.map { cue in
            var copy = cue
            copy.start += safeOffset
            copy.end += safeOffset
            return copy
        })
        registerUndo("undo.adjustTiming", before: snapshot)
        syncPreviewText()
    }

    private func closeAllGaps(targetGap rawGap: Double) {
        guard !slot.cues.isEmpty else { return }
        let targetGap = max(0, rawGap.isFinite ? rawGap : 0)
        let snapshot = makeUndoSnapshot()
        previewSyncTask?.cancel()
        let normalized = SubtitleDocument.normalize(slot.cues)
        var adjusted: [SubtitleCue] = []
        var previousEnd: Double?
        for var cue in normalized {
            let cueDuration = max(0.05, cue.end - cue.start)
            if let previousEnd {
                let desiredStart = previousEnd + targetGap
                if cue.start > desiredStart {
                    cue.start = desiredStart
                    cue.end = desiredStart + cueDuration
                }
            }
            cue.end = max(cue.start + 0.05, cue.end)
            adjusted.append(cue)
            previousEnd = cue.end
        }
        slot.cues = SubtitleDocument.normalize(adjusted)
        if snapshot != makeUndoSnapshot() {
            registerUndo("undo.adjustTiming", before: snapshot)
        }
        syncPreviewText()
    }

    private func canResetCue(_ cueID: SubtitleCue.ID) -> Bool {
        guard let index = cueIndex(for: cueID),
              let original = originalCue(for: cueID) else { return false }
        return canResetCue(slot.cues[index], original: original)
    }

    private func canResetCue(_ current: SubtitleCue, original: SubtitleCue?) -> Bool {
        guard let original else { return false }
        return current.start != original.start
            || current.end != original.end
            || current.text != original.text
            || current.confidence != original.confidence
            || SubtitleDocument.normalizedSpeakerName(current.speaker) != SubtitleDocument.normalizedSpeakerName(original.speaker)
    }

    private func refreshSlotCaches() {
        cachedOriginalCuesByID = Dictionary(
            slot.originalCues.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        cachedSpeakerColorsByName = slot.speakerColors.compactMapValues { TimelineSpeakerColor.color(fromHex: $0) }
    }

    private struct SlotCacheSignal: Equatable {
        let fileID: UUID
        let originalRevision: UUID
        let speakerColors: [String: String]
    }

    private var slotCacheSignal: SlotCacheSignal {
        SlotCacheSignal(
            fileID: slot.id,
            originalRevision: slot.originalCuesRevision,
            speakerColors: slot.speakerColors
        )
    }

    private func editedFields(for cueID: SubtitleCue.ID) -> CueStatusBadges.EditedFields {
        guard let index = cueIndex(for: cueID),
              let original = originalCue(for: cueID) else { return .init() }
        let current = slot.cues[index]
        return CueStatusBadges.EditedFields(
            text: current.text != original.text,
            time: current.start != original.start || current.end != original.end,
            speaker: SubtitleDocument.normalizedSpeakerName(current.speaker) != SubtitleDocument.normalizedSpeakerName(original.speaker)
        )
    }

    private func speakerColor(forCue cue: SubtitleCue) -> Color? {
        speakerColor(forCue: cue, colorCache: slot.speakerColors.compactMapValues { TimelineSpeakerColor.color(fromHex: $0) })
    }

    private func speakerColor(forCue cue: SubtitleCue, colorCache: [String: Color]) -> Color? {
        guard let speaker = SubtitleDocument.normalizedSpeakerName(cue.speaker),
              let color = colorCache[speaker] else {
            return nil
        }
        return color
    }

    private func cycleSpeaker(for cueID: SubtitleCue.ID) {
        guard let index = cueIndex(for: cueID) else { return }
        let speakers = speakerNames
        guard !speakers.isEmpty else { return }
        let current = SubtitleDocument.normalizedSpeakerName(slot.cues[index].speaker)
        let next: String
        if let current, let pos = speakers.firstIndex(of: current) {
            next = speakers[(pos + 1) % speakers.count]
        } else {
            next = speakers[0]
        }
        assignSpeaker(next, to: cueID)
    }

    private func originalCue(for cueID: SubtitleCue.ID) -> SubtitleCue? {
        slot.originalCues.first { $0.id == cueID }
    }

    private func cueIndex(for cueID: SubtitleCue.ID) -> Int? {
        cueIndexData.positions[cueID]
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

        guard let cueClip = await extractCueClip(start: cue.start, end: cue.end) else {
            transcribeError = "Audio clip extraction failed"
            return
        }
        defer { try? FileManager.default.removeItem(at: cueClip.url) }

        do {
            if settings.effectiveASREngine.isLocal {
                let cues = try await AppleSpeechService.transcribe(
                    url: cueClip.url,
                    locale: appleSpeechLocale(for: settings.recognitionLanguage),
                    timeOffset: 0,
                    fastResults: settings.appleSpeechFastResults,
                    etiquetteFilter: settings.appleSpeechEtiquetteFilter
                )
                let text = SubtitleDocument.serialize(cues, format: slot.outputFormat)
                applyRetranscribedCueOutput(text, cueID: cueID)
                return
            }

            if settings.canUseNativeQwen, let directory = settings.nativeQwenModelDirectory {
                do {
                    let options = NativeQwenService.Options(
                        modelDirectory: directory,
                        language: settings.recognitionLanguage == .auto ? nil : settings.recognitionLanguage.rawValue,
                        context: settings.asrContext, maxTokens: settings.mimoMaxTokens,
                        lineCharacters: settings.lineChars
                    )
                    let cues = try await NativeQwenService.shared.transcribeClip(audioURL: cueClip.url, options: options)
                    try Task.checkCancellation()
                    applyRetranscribedCueOutput(SubtitleDocument.serialize(cues, format: slot.outputFormat), cueID: cueID)
                    await NativeQwenService.shared.release()
                    return
                } catch {
                    await NativeQwenService.shared.release()
                    try Task.checkCancellation()
                    if error is CancellationError { throw error }
                    AppLog.api.error("Native cue fallback: \(error.localizedDescription, privacy: .public)")
                }
            }
            let isReady = await backend.ensureRunning(timeout: 25.0)
            api.baseURL = backend.baseURL
            guard isReady else {
                transcribeError = backend.message
                return
            }
            let text = try await transcribeCueClip(cueClip)
            applyRetranscribedCueOutput(text, cueID: cueID)
        } catch {
            transcribeError = error.localizedDescription
        }
    }

    private func transcribeCueClip(_ cueClip: (url: URL, duration: Double)) async throws -> String {
        let duration = max(0.05, cueClip.duration)
        let cueChunkSeconds = max(0.4, min(duration, max(settings.vadMaxSegment, 0.8)))
        let fixedOverrides = [
            ("segment_mode", SegmentMode.fixed.rawValue),
            ("chunk_seconds", String(format: "%.3f", cueChunkSeconds)),
            ("diarize_speakers", "false")
        ]

        do {
            return try await runCueTranscriptionJob(
                fileURL: cueClip.url,
                fieldOverrides: fixedOverrides
            )
        } catch {
            guard !Task.isCancelled else { throw error }
            return try await runCueTranscriptionJob(fileURL: cueClip.url)
        }
    }

    private func runCueTranscriptionJob(
        fileURL: URL,
        fieldOverrides: [(String, String)] = []
    ) async throws -> String {
        let created = try await api.createJob(
            fileURL: fileURL,
            settings: settings,
            fieldOverrides: fieldOverrides
        )
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
            if status.status == "cancelled" { throw CancellationError() }
            try await Task.sleep(for: .milliseconds(700))
        }
        let output = try await api.fetchOutput(jobID: created.id)
        return String(data: output.data, encoding: .utf8) ?? ""
    }

    private func applyRetranscribedCueOutput(_ text: String, cueID: SubtitleCue.ID) {
        let cuesFromClip = SubtitleDocument.parse(text, format: slot.outputFormat)
        let parsedSpeakers = cuesFromClip.compactMap { SubtitleDocument.normalizedSpeakerName($0.speaker) }
        let uniqueParsedSpeakers = parsedSpeakers.reduce(into: [String]()) { speakers, speaker in
            if !speakers.contains(speaker) {
                speakers.append(speaker)
            }
        }
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
        let snapshot = makeUndoSnapshot()
        slot.cues[updatedIndex].text = combined
        if uniqueParsedSpeakers.count == 1 {
            slot.cues[updatedIndex].speaker = uniqueParsedSpeakers.first
            _ = applyStoredSpeakerColor(toCueAt: updatedIndex)
        }
        if snapshot != makeUndoSnapshot() {
            registerUndo("undo.editSubtitle", before: snapshot)
        }
        schedulePreviewTextSync()
    }

    private func extractCueClip(start: Double, end: Double) async -> (url: URL, duration: Double)? {
        // Crop the original media before any whole-file compatibility conversion.
        let margin: Double = 0.2
        let safeStart = max(0, start - margin)
        let safeDuration = max(0.4, end + margin - safeStart)
        do {
            let pcm = try await NativeAudioExporter.shared.extract(
                source: slot.url, start: safeStart, duration: safeDuration)
            return (pcm.url, pcm.duration)
        } catch {
            if Task.isCancelled || error is CancellationError { return nil }
        }
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

        if let result = await clipViaAVFoundation(
            source: audioURL,
            dest: dest,
            startSeconds: safeStart,
            durationSeconds: safeDuration
        ) {
            return (result, await FFmpegRunner.probeDuration(of: result) ?? safeDuration)
        }
        // AVF failed (likely because AudioSource fell back to the original URL of
        // an unsupported container). Try ffmpeg directly on the source.
        if let result = await FFmpegRunner.extractAudio(
            from: slot.url,
            to: dest,
            start: safeStart,
            duration: safeDuration
        ) {
            return (result, await FFmpegRunner.probeDuration(of: result) ?? safeDuration)
        }
        try? FileManager.default.removeItem(at: dest)
        return nil
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
        let snapshot = makeUndoSnapshot()
        previewSyncTask?.cancel()
        slot.cues[selectedCueIndex].start = original.start
        slot.cues[selectedCueIndex].end = original.end
        slot.cues[selectedCueIndex].text = original.text
        slot.cues[selectedCueIndex].bilingual = original.bilingualText
        slot.cues[selectedCueIndex].confidence = original.confidence
        slot.cues[selectedCueIndex].speaker = original.speaker
        slot.cues = SubtitleDocument.normalize(slot.cues)
        slot.selectedCueID = original.id
        if snapshot != makeUndoSnapshot() {
            registerUndo("undo.resetCue", before: snapshot)
        }
        scheduleCueTimingSync(for: slot.cues)
    }

    private func presentSplit(_ cue: SubtitleCue) {
        let time = playback.currentTime
        guard transcribingCueID == nil, SubtitleCueSplit.canSplit(cue, at: time) else { return }
        playback.seek(to: time, pause: true)
        splitRequest = .init(fileURL: slot.url, cue: cue, time: time)
    }

    private func applySplit(_ request: SubtitleSplitRequest, sourceOffset: Int, translationOffset: Int?) {
        guard slot.url == request.fileURL, transcribingCueID == nil,
              let index = cueIndex(for: request.cue.id), slot.cues[index] == request.cue,
              let (first, second) = SubtitleCueSplit.split(request.cue, at: request.time,
                  sourceOffset: sourceOffset, translationOffset: translationOffset) else { return }
        let snapshot = makeUndoSnapshot()
        previewSyncTask?.cancel()
        selectedTextRange = nil
        textEditUndoBurst = nil
        slot.cues.replaceSubrange(index...index, with: [first, second])
        slot.cues = SubtitleDocument.normalize(slot.cues)
        slot.selectedCueID = first.id
        registerUndo("undo.splitCue", before: snapshot)
        scheduleCueTimingSync(for: slot.cues)
    }

    private func mergeCandidate(for cueID: SubtitleCue.ID) -> SubtitleCue? {
        guard let index = cueIndex(for: cueID), slot.cues.indices.contains(index + 1) else { return nil }
        return SubtitleCueMerge.merged(slot.cues[index], slot.cues[index + 1])
    }

    private func mergeWithNext(_ cueID: SubtitleCue.ID) {
        guard transcribingCueID == nil, let index = cueIndex(for: cueID),
              let merged = mergeCandidate(for: cueID) else { return }
        let snapshot = makeUndoSnapshot()
        previewSyncTask?.cancel()
        selectedTextRange = nil
        textEditUndoBurst = nil
        slot.cues[index] = merged
        slot.cues.remove(at: index + 1)
        slot.cues = SubtitleDocument.normalize(slot.cues)
        slot.selectedCueID = merged.id
        registerUndo("undo.mergeCues", before: snapshot)
        scheduleCueTimingSync(for: slot.cues)
    }

    private func duplicateCue(_ cueID: SubtitleCue.ID) {
        guard let index = cueIndex(for: cueID) else { return }
        insertCue(slot.cues[index].duplicatedAfterEnd(), at: index + 1)
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
        confidence: Double? = nil,
        speaker: String? = nil
    ) {
        var cue = SubtitleCue(
            index: insertionIndex + 1,
            start: max(0, start),
            end: max(max(0, start) + 0.05, end),
            text: text,
            confidence: confidence,
            speaker: speaker
        )
        if let speaker = SubtitleDocument.normalizedSpeakerName(speaker),
           let hex = slot.speakerColors[speaker] {
            cue.text = fontColoredText(cue.text, hex: hex)
        }
        insertCue(cue, at: insertionIndex)
    }

    private func insertCue(_ cue: SubtitleCue, at insertionIndex: Int) {
        let snapshot = makeUndoSnapshot()
        previewSyncTask?.cancel()
        selectedTextRange = nil
        textEditUndoBurst = nil
        let safeIndex = min(max(0, insertionIndex), slot.cues.count)
        slot.cues.insert(cue, at: safeIndex)
        slot.cues = SubtitleDocument.normalize(slot.cues)
        slot.selectedCueID = cue.id
        registerUndo("undo.insertCue", before: snapshot)
        scheduleCueTimingSync(for: slot.cues)
    }

    private func closeGap(around cueID: SubtitleCue.ID) {
        guard let index = cueIndex(for: cueID) else { return }
        let snapshot = makeUndoSnapshot()
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
        if snapshot != makeUndoSnapshot() {
            registerUndo("undo.adjustTiming", before: snapshot)
        }
        scheduleCueTimingSync(for: slot.cues)
    }

    private func deleteCue(_ cueID: SubtitleCue.ID) {
        guard let index = cueIndex(for: cueID) else { return }
        let snapshot = makeUndoSnapshot()
        previewSyncTask?.cancel()
        slot.cues.remove(at: index)
        slot.cues = SubtitleDocument.normalize(slot.cues)
        if slot.cues.isEmpty {
            slot.selectedCueID = nil
        } else {
            let nextIndex = min(index, slot.cues.count - 1)
            slot.selectedCueID = slot.cues[nextIndex].id
        }
        registerUndo("undo.deleteCue", before: snapshot)
        scheduleCueTimingSync(for: slot.cues)
    }

    private func deleteMatchingCues(referenceCueID: SubtitleCue.ID) {
        guard let referenceIndex = cueIndex(for: referenceCueID) else { return }
        let targetText = SubtitleDocument.normalizedCueTextForMatching(SubtitleDocument.displayText(for: slot.cues[referenceIndex]))
        guard !targetText.isEmpty else { return }
        let matchingIDs = Set(
            slot.cues
                .filter { SubtitleDocument.normalizedCueTextForMatching(SubtitleDocument.displayText(for: $0)) == targetText }
                .map(\.id)
        )
        guard !matchingIDs.isEmpty else { return }
        let snapshot = makeUndoSnapshot()
        let selectedID = slot.selectedCueID
        previewSyncTask?.cancel()
        slot.cues.removeAll { matchingIDs.contains($0.id) }
        slot.cues = SubtitleDocument.normalize(slot.cues)
        if slot.cues.isEmpty {
            slot.selectedCueID = nil
        } else if let selectedID, !matchingIDs.contains(selectedID), slot.cues.contains(where: { $0.id == selectedID }) {
            slot.selectedCueID = selectedID
        } else {
            let nextIndex = min(referenceIndex, slot.cues.count - 1)
            slot.selectedCueID = slot.cues[nextIndex].id
        }
        registerUndo("undo.deleteMatchingCues", before: snapshot)
        scheduleCueTimingSync(for: slot.cues)
    }

    private func findNext() {
        guard !findText.isEmpty, !slot.cues.isEmpty else { return }
        let startIndex = selectedCueIndex.map { $0 + 1 } ?? 0
        if let index = searchResults.indices.first(where: { $0 >= startIndex }) ?? searchResults.indices.first {
            slot.selectedCueID = slot.cues[index].id
            findStatus = String(format: Copy.text("editor.findSelected", language: language), slot.cues[index].index)
            return
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
        let snapshot = makeUndoSnapshot()
        let result = textSearch.replacing(in: slot.cues[selectedCueIndex], all: false)
        if result.count > 0 {
            if result.cue != slot.cues[selectedCueIndex] {
                slot.cues[selectedCueIndex] = result.cue
                selectedTextRange = nil
                registerUndo("undo.replaceText", before: snapshot)
            }
            schedulePreviewTextSync()
            findStatus = String(format: Copy.text("editor.replaceOneCount", language: language), 1)
            return
        }
        findNext()
    }

    private func replaceAll() {
        guard !findText.isEmpty else { return }
        let snapshot = makeUndoSnapshot()
        var total = 0
        for index in slot.cues.indices {
            let result = textSearch.replacing(in: slot.cues[index], all: true)
            total += result.count
            slot.cues[index] = result.cue
        }
        if total > 0, snapshot != makeUndoSnapshot() {
            selectedTextRange = nil
            registerUndo("undo.replaceText", before: snapshot)
            schedulePreviewTextSync()
        }
        findStatus = String(format: Copy.text("editor.replaceAllCount", language: language), total)
        if total == 0 {
            NSSound.beep()
        }
    }

    private var textSearch: SubtitleTextSearch {
        SubtitleTextSearch(query: findText, replacement: replacementText, matchCase: matchCase, scope: findScope)
    }

    private var highlightMarkers: TimelineMarkerSet {
        let search = SubtitleTextSearch(query: selectedFrequentTerm ?? "", replacement: "", matchCase: false, scope: .all)
        return highlightCache.value(cues: slot.cues, revision: slot.cuesRevision,
                                    search: search, literalHighlight: true).markers
    }

    private var searchResults: SubtitleSearchCache.Result {
        searchCache.value(cues: slot.cues, revision: slot.cuesRevision, search: textSearch)
    }

    private func occurrenceCount() -> Int {
        searchResults.count
    }

    private func playSelectedCue() {
        guard let selectedCueIndex else { return }
        let cue = slot.cues[selectedCueIndex]
        playback.playRange(start: cue.start, end: cue.end)
    }

    private func toggleMarkupTag(_ tag: String) {
        guard let selectedCueIndex else { return }
        if slot.cues[selectedCueIndex].bilingualText != nil {
            commitBilingualStyle(.toggleTag(tag))
            return
        }
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
        if slot.cues[selectedCueIndex].bilingualText != nil {
            commitBilingualStyle(.color(hexString(for: color)))
            return
        }
        var text = slot.cues[selectedCueIndex].text
        guard !text.isEmpty else { return }
        let hex = hexString(for: color)

        if var selection = activeStyleSelection(in: text) {
            while unwrapImmediateFont(in: &text, selection: &selection) {}
            guard let range = Range(selection, in: text) else { return }
            let selectedText = fontMarkupRemoved(from: String(text[range]))
            let colored = fontColoredText(selectedText, hex: hex)
            text.replaceSubrange(range, with: colored)
            commitStyleText(text, selection: nil)
            return
        }

        commitStyleText(fontColoredText(text, hex: hex), selection: nil)
    }

    private func clearCueStyle() {
        guard let selectedCueIndex else { return }
        if slot.cues[selectedCueIndex].bilingualText != nil {
            commitBilingualStyle(.clear)
            return
        }
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

    private func commitBilingualStyle(_ operation: SubtitleCueStyle.Operation) {
        guard let selectedCueIndex else { return }
        let current = slot.cues[selectedCueIndex]
        let updated = SubtitleCueStyle.applying(operation, to: current, scope: styleScope)
        guard updated != current else { return }
        let snapshot = makeUndoSnapshot()
        slot.cues[selectedCueIndex] = updated
        selectedTextRange = nil
        registerUndo("undo.styleSubtitle", before: snapshot)
        schedulePreviewTextSync()
    }

    private func commitStyleText(_ text: String, selection: NSRange?) {
        guard let selectedCueIndex else { return }
        guard text != slot.cues[selectedCueIndex].text else { return }
        let snapshot = makeUndoSnapshot()
        slot.cues[selectedCueIndex].text = text
        selectedTextRange = selection
        registerUndo("undo.styleSubtitle", before: snapshot)
        schedulePreviewTextSync()
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
        SubtitleCueStyle.clearMarkup(in: text)
    }

    private func fontMarkupRemoved(from text: String) -> String {
        SubtitleCueStyle.fontMarkupRemoved(from: text)
    }

    private func fontColoredText(_ text: String, hex: String) -> String {
        SubtitleCueStyle.fontColoredText(text, hex: hex)
    }

    private func hasOuterMarkupTag(_ tag: String) -> Bool {
        guard let selectedCueIndex else { return false }
        if slot.cues[selectedCueIndex].bilingualText != nil {
            return SubtitleCueStyle.hasTag(tag, in: slot.cues[selectedCueIndex], scope: styleScope)
        }
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
        if slot.cues[selectedCueIndex].bilingualText != nil {
            return SubtitleCueStyle.hasColor(in: slot.cues[selectedCueIndex], scope: styleScope)
        }
        let text = slot.cues[selectedCueIndex].text
        if let selection = activeStyleSelection(in: text),
           let range = Range(selection, in: text) {
            return unwrappedFontText(String(text[range])) != nil
                || fontWrapper(around: range, in: text) != nil
        }
        return unwrappedFontText(text) != nil
    }

    private func unwrappedMarkupText(_ text: String, tag: String) -> String? {
        SubtitleCueStyle.unwrappedMarkupText(text, tag: tag)
    }

    private func unwrappedFontText(_ text: String) -> String? {
        SubtitleCueStyle.unwrappedFontText(text)
    }

    private func hexString(for color: Color) -> String {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? .systemYellow
        let red = Int((nsColor.redComponent * 255).rounded())
        let green = Int((nsColor.greenComponent * 255).rounded())
        let blue = Int((nsColor.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }

    private func color(fromHex raw: String) -> Color? {
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

private struct EditorColumnHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 300

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
