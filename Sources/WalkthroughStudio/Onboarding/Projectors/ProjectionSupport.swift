import Foundation

/// Shared helpers for the projectors (M8). These mirror, function for function, the
/// reference implementation in
/// `.claude/skills/onboarding-research/scripts/project_packet.py`, the way
/// `PacketValidator` mirrors `validate_packet.py`. `projectorParityProbe` diffs this
/// output against the checked-in golden projection, so any divergence here is a test
/// failure rather than a discovery months later.
enum ProjectionSupport {

    static let wordsPerMinute = 220

    /// Lowercase, non-alphanumerics to single hyphens, trimmed. Heading slugs must stay
    /// stable across regeneration: a doc anchor (`doc:tech-debt#ranked-by-severity`)
    /// that moves is a dangling link in every deliverable that cites it.
    static func slugify(_ text: String) -> String {
        var out = ""
        var lastWasHyphen = false
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber {
                out.append(ch)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                out.append("-")
                lastWasHyphen = true
            }
        }
        while out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "section" : out
    }

    /// A Mermaid-safe node id, stable across runs.
    static func mermaidID(_ text: String) -> String {
        var out = ""
        var lastWasUnderscore = false
        for ch in text {
            if ch.isLetter || ch.isNumber, ch.isASCII {
                out.append(ch)
                lastWasUnderscore = false
            } else if !lastWasUnderscore {
                out.append("_")
                lastWasUnderscore = true
            }
        }
        while out.hasPrefix("_") { out.removeFirst() }
        while out.hasSuffix("_") { out.removeLast() }
        let clipped = String(out.prefix(48))
        return clipped.isEmpty ? "n" : clipped
    }

    /// Mermaid parses a label as markdown, so a backtick raises "Unsupported markdown:
    /// codespan" and renders that text instead of the label. Quotes and brackets end the
    /// label early. Producers write all three.
    static func mermaidLabel(_ text: String) -> String {
        var s = text.replacingOccurrences(of: "`", with: "")
        s = s.replacingOccurrences(of: "\n", with: " ")
        s = s.replacingOccurrences(of: "\"", with: "'")
        s = s.replacingOccurrences(of: "[", with: "(")
        s = s.replacingOccurrences(of: "]", with: ")")
        return s.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// Truncate on a word boundary. Cutting mid-word ("deploy/de") reads as a bug.
    static func clip(_ text: String, _ limit: Int) -> String {
        let collapsed = text.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        guard collapsed.count > limit else { return collapsed }
        let head = String(collapsed.prefix(limit))
        var cut = head
        if let lastSpace = head.lastIndex(of: " ") { cut = String(head[head.startIndex..<lastSpace]) }
        if cut.isEmpty { cut = head }
        while let last = cut.last, " ,;:.".contains(last) { cut.removeLast() }
        return cut + "..."
    }

    /// The repository-relative path of a `code:` anchor, or nil for any other kind.
    static func codePath(_ anchor: String?) -> String? {
        guard let anchor, let parsed = Anchor(string: anchor), case .code(let path, _, _) = parsed else { return nil }
        return path
    }

    /// `src/api/handler.py` -> `src/`; a root file -> `.`
    static func topDir(_ path: String) -> String {
        guard let slash = path.firstIndex(of: "/") else { return "." }
        return String(path[path.startIndex...slash])
    }

    /// Python's `round()` is banker's rounding (half to even) and Swift's `.rounded()`
    /// is not, so a half value would silently break parity between the two projectors.
    static func pyRound(_ value: Double) -> Int {
        Int(value.rounded(.toNearestOrEven))
    }

    static func minutes(forWordCount words: Int) -> Int {
        max(1, pyRound(Double(words) / Double(wordsPerMinute)))
    }

    /// Python's `str.split()` with no argument: runs of any whitespace, empties dropped.
    /// Minutes in every front matter come from this, so a narrower definition would make
    /// the two projectors disagree on reading time.
    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// Deterministic JSON: sorted keys and pretty printing, so a diff against the golden
    /// projection shows real changes rather than dictionary ordering.
    static func encodeJSON(_ value: Any) throws -> Data {
        var data = try JSONSerialization.data(
            withJSONObject: value,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)   // trailing newline, as json.dump + "\n" writes
        return data
    }
}

/// A JSON object that remembers the order keys were first inserted.
///
/// Python dictionaries preserve insertion order, and `build_backlinks` walks
/// `links["nodes"]` in that order to build each anchor's backlink list — a JSON *array*,
/// where order is meaningful. A Swift `[String: Any]` would hand the same nodes back in
/// a different order on every run, so two nodes of one diagram sharing an anchor would
/// produce a list that diffs against the golden projection at random.
struct OrderedJSONObject {
    private(set) var keys: [String] = []
    private var values: [String: Any] = [:]

    init() {}

    subscript(key: String) -> Any? {
        get { values[key] }
        set {
            if let newValue {
                if values[key] == nil { keys.append(key) }
                values[key] = newValue
            } else {
                values[key] = nil
                keys.removeAll { $0 == key }
            }
        }
    }

    var isEmpty: Bool { keys.isEmpty }

    /// The plain dictionary, for JSONSerialization. Key order is not meaningful in a
    /// JSON object, so nothing is lost here — only `keys` carries the order.
    var object: [String: Any] { values }

    /// Key/value pairs in insertion order.
    var ordered: [(key: String, value: Any)] { keys.map { ($0, values[$0]!) } }
}
