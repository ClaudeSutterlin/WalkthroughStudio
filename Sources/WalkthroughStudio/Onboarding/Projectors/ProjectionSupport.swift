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

    static func minutes(forWordCount words: Int) -> Int {
        max(1, Int((Double(words) / Double(wordsPerMinute)).rounded()))
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
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
