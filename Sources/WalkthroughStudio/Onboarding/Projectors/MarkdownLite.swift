import Foundation

/// The small markdown subset the onboarding package speaks, plus the `[[anchor]]`
/// citation grammar that turns a claim's evidence into a clickable chip.
///
/// Mirrors `esc`, `anchor_label`, `inline_html` and `markdown_to_html` in
/// `.claude/skills/onboarding-research/scripts/project_packet.py`, character for
/// character — `projectorParityProbe` diffs the HTML against the golden projection.
///
/// Deliberately small: headings with stable slugs, lists, tables, fenced code,
/// paragraphs and heading chips. Anything richer belongs in the packet, not in a
/// markdown dialect nobody can predict. This is not a general markdown renderer and
/// must not grow into one: the hub trusts it to produce safe HTML from packet prose,
/// and every feature added here is another way for a producer's text to escape
/// escaping.
enum MarkdownLite {

    // MARK: - escaping

    /// HTML-escapes the four characters that can break out of text or an attribute.
    /// `'` is not escaped because every attribute this file writes is double-quoted,
    /// which is also what the Python reference does.
    static func esc(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(ch)
            }
        }
        return out
    }

    // MARK: - chip captions

    /// A chip caption a reader can scan: file name plus line range, not the whole path.
    static func anchorLabel(_ anchor: String) -> String {
        if let code = parseCodeAnchor(anchor) {
            let trimmedPath = trimTrailingSlashes(code.path)
            let name = lastPathComponent(trimmedPath)
            let display = name.isEmpty ? code.path : name
            if let a = code.lineA {
                var span = "L\(a)"
                if let b = code.lineB, b != a { span += "-\(b)" }
                return "\(display) \(span)"
            }
            return display
        }
        // Any other anchor kind: "video ONB-intro", "doc tech-debt", ...
        let kind: String
        let rest: String
        if let colon = anchor.firstIndex(of: ":") {
            kind = String(anchor[anchor.startIndex..<colon])
            rest = String(anchor[anchor.index(after: colon)...])
        } else {
            kind = anchor
            rest = ""
        }
        let head = rest.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return "\(kind) \(String(head.prefix(28)))"
    }

    /// `code:<path>@<sha>[#L<a>[-L<b>]]`, parsed the way the reference `CODE_RE` does.
    /// Deliberately not routed through `Anchor`: the label has to be produced for a
    /// malformed anchor too, and `Anchor` refuses those.
    private struct CodeAnchor {
        let path: String
        let lineA: Int?
        let lineB: Int?
    }

    /// `.+` in the reference regex is greedy, so it claims the longest path that still
    /// leaves a valid sha (and an optional line span) to the end of the string. Walking
    /// `@` from the right reproduces that backtracking. A `#` earlier in the anchor is
    /// part of the path, not a malformed fragment — an earlier version bailed out on one
    /// and mislabelled every chip for a path containing a hash.
    private static func parseCodeAnchor(_ anchor: String) -> CodeAnchor? {
        guard anchor.hasPrefix("code:") else { return nil }
        let body = Array(anchor.dropFirst("code:".count))
        var at = body.count
        while true {
            guard let next = body[body.startIndex..<at].lastIndex(of: "@") else { return nil }
            at = next
            let path = String(body[0..<at])
            let rest = Array(body[(at + 1)...])
            guard !path.isEmpty else { continue }
            if isSHA(rest) {
                return CodeAnchor(path: path, lineA: nil, lineB: nil)
            }
            if let hash = rest.firstIndex(of: "#"),
               isSHA(Array(rest[0..<hash])),
               let lines = parseLineFragment(String(rest[(hash + 1)...])) {
                return CodeAnchor(path: path, lineA: lines.0, lineB: lines.1)
            }
        }
    }

    /// `[0-9a-f]{7,40}` — lowercase hex only, as every anchor the contract accepts.
    private static func isSHA(_ characters: [Character]) -> Bool {
        (7...40).contains(characters.count)
            && characters.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
    }

    private static func parseLineFragment(_ fragment: String) -> (Int, Int?)? {
        guard fragment.hasPrefix("L") else { return nil }
        let rest = String(fragment.dropFirst())
        let halves = rest.components(separatedBy: "-L")
        guard halves.count <= 2, let a = Int(halves[0]), !halves[0].isEmpty,
              halves[0].allSatisfy({ $0.isNumber }) else { return nil }
        if halves.count == 1 { return (a, nil) }
        guard let b = Int(halves[1]), halves[1].allSatisfy({ $0.isNumber }), !halves[1].isEmpty else { return nil }
        return (a, b)
    }

    private static func trimTrailingSlashes(_ path: String) -> String {
        var s = path
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// `Path(...).name`: Python's pathlib drops empty and `.` components while parsing
    /// and keeps `..`, so `src/.` is named `src` and `a/..` is named `..`.
    private static func lastPathComponent(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true)
            .last(where: { $0 != "." })
            .map(String.init) ?? ""
    }

    // MARK: - inline

    /// Inline markdown plus the `[[anchor]]` / `[[anchor|label]]` citation grammar,
    /// which becomes a chip the hub can route. Escaping happens first so a claim
    /// containing `<` cannot inject markup.
    static func inlineHTML(_ text: String) -> String {
        var out = esc(text)
        out = replacePairs(out, delimiter: "**", open: "<strong>", close: "</strong>")
        out = replacePairs(out, delimiter: "`", open: "<code>", close: "</code>")
        return replaceCitations(out)
    }

    /// `**bold**` and `` `code` ``: a delimited run containing none of the delimiter's
    /// characters, matching the reference regexes `\*\*([^*]+)\*\*` and `` `([^`]+)` ``.
    private static func replacePairs(_ text: String, delimiter: String, open: String, close: String) -> String {
        let forbidden = delimiter.first!
        let chars = Array(text)
        let d = Array(delimiter)
        var out = ""
        var i = 0
        while i < chars.count {
            guard matches(chars, at: i, d) else {
                out.append(chars[i])
                i += 1
                continue
            }
            var j = i + d.count
            var body: [Character] = []
            var closed = false
            while j < chars.count {
                if matches(chars, at: j, d), !body.isEmpty {
                    closed = true
                    break
                }
                if chars[j] == forbidden { break }       // [^*]+ / [^`]+ cannot span a lone delimiter
                body.append(chars[j])
                j += 1
            }
            if closed {
                out += open + String(body) + close
                i = j + d.count
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }

    private static func matches(_ chars: [Character], at index: Int, _ needle: [Character]) -> Bool {
        guard index + needle.count <= chars.count else { return false }
        for (offset, ch) in needle.enumerated() where chars[index + offset] != ch { return false }
        return true
    }

    /// A `[[anchor]]` / `[[anchor|label]]` citation and where it sits in the text.
    struct Citation {
        let anchor: String
        let label: String?
        /// Offsets into the character array that was scanned, `[[` through `]]`.
        let range: Range<Int>
    }

    /// Every citation in the text, in order. Mirrors
    /// `CITATION = \[\[([^\]|]+)(?:\|([^\]]+))?\]\]`: the anchor may contain neither
    /// `]` nor `|`, the label may contain no `]`, and both must be non-empty.
    ///
    /// Two callers share this: the chip renderer, which runs over escaped text, and the
    /// backlink index, which runs over raw markdown. Escaping never touches `[`, `]` or
    /// `|`, so one scanner serves both.
    static func scanCitations(_ chars: [Character]) -> [Citation] {
        var out: [Citation] = []
        var i = 0
        while i < chars.count {
            guard chars[i] == "[", i + 1 < chars.count, chars[i + 1] == "[" else {
                i += 1
                continue
            }
            var j = i + 2
            var anchor: [Character] = []
            while j < chars.count, chars[j] != "]", chars[j] != "|" {
                anchor.append(chars[j])
                j += 1
            }
            var label: String? = nil
            if j < chars.count, chars[j] == "|" {
                j += 1
                var labelChars: [Character] = []
                while j < chars.count, chars[j] != "]" {
                    labelChars.append(chars[j])
                    j += 1
                }
                if labelChars.isEmpty {                 // (?:\|([^\]]+))? needs one character
                    i += 1
                    continue
                }
                label = String(labelChars)
            }
            guard !anchor.isEmpty, j + 1 < chars.count, chars[j] == "]", chars[j + 1] == "]" else {
                i += 1
                continue
            }
            out.append(Citation(anchor: String(anchor), label: label, range: i..<(j + 2)))
            i = j + 2
        }
        return out
    }

    /// The anchors cited without a label, which is the form the registers write and the
    /// backlink index looks for.
    static func citedAnchors(in text: String, kindPrefix: String) -> [String] {
        scanCitations(Array(text))
            .filter { $0.label == nil && $0.anchor.hasPrefix(kindPrefix) }
            .map { $0.anchor }
    }

    private static func replaceCitations(_ text: String) -> String {
        let chars = Array(text)
        let found = scanCitations(chars)
        guard !found.isEmpty else { return text }
        var out = ""
        var cursor = 0
        for citation in found {
            out += String(chars[cursor..<citation.range.lowerBound])
            out += chip(anchor: citation.anchor, label: citation.label)
            cursor = citation.range.upperBound
        }
        out += String(chars[cursor...])
        return out
    }

    /// The reference escapes the anchor again here, on text `esc` has already run over.
    /// Kept as-is: anchors are repository paths and ids, and diverging would change the
    /// `data-anchor` the hub routes on.
    static func chip(anchor: String, label: String?) -> String {
        let caption = label ?? anchorLabel(anchor)
        return "<a class=\"chip\" href=\"#\" data-anchor=\"\(esc(anchor))\" "
            + "title=\"\(esc(anchor))\">\(esc(caption))</a>"
    }

    // MARK: - block

    static func toHTML(_ markdown: String) -> String {
        var lines = markdown.components(separatedBy: "\n")
        if let first = lines.first, first.trimmed == "---" {           // strip front matter
            let end = (1..<lines.count).first { lines[$0].trimmed == "---" } ?? 0
            lines = Array(lines[(end + 1)...])
        }
        var html: [String] = []
        var i = 0
        while i < lines.count {
            let stripped = lines[i].trimmed
            if stripped.isEmpty {
                i += 1
                continue
            }
            if stripped.hasPrefix("```") {
                i += 1
                var block: [String] = []
                while i < lines.count, !lines[i].trimmed.hasPrefix("```") {
                    block.append(lines[i])
                    i += 1
                }
                i += 1
                html.append("<pre><code>" + esc(block.joined(separator: "\n")) + "</code></pre>")
                continue
            }
            if stripped.hasPrefix("#") {
                html.append(headingHTML(stripped))
                i += 1
                continue
            }
            if stripped.hasPrefix("|") {
                var rows: [[String]] = []
                while i < lines.count, lines[i].trimmed.hasPrefix("|") {
                    rows.append(tableRow(lines[i].trimmed))
                    i += 1
                }
                html.append(tableHTML(rows))
                continue
            }
            if listMarker(stripped) != nil {
                let ordered = isOrderedMarker(stripped)
                var items: [String] = []
                while i < lines.count, let marker = listMarker(lines[i].trimmed) {
                    items.append(String(lines[i].trimmed.dropFirst(marker)))
                    i += 1
                }
                let tag = ordered ? "ol" : "ul"
                html.append("<\(tag)>" + items.map { "<li>\(inlineHTML($0))</li>" }.joined() + "</\(tag)>")
                continue
            }
            var para: [String] = []
            while i < lines.count {
                let s = lines[i].trimmed
                if s.isEmpty || s.hasPrefix("#") || s.hasPrefix("|") || s.hasPrefix("```") || listMarker(s) != nil {
                    break
                }
                para.append(s)
                i += 1
            }
            html.append("<p>" + inlineHTML(para.joined(separator: " ")) + "</p>")
        }
        return html.joined(separator: "\n")
    }

    private static func headingHTML(_ stripped: String) -> String {
        let level = stripped.prefix(while: { $0 == "#" }).count
        let raw = String(stripped.dropFirst(level)).trimmed
        let (text, chips) = splitHeadingChips(raw)
        let chipHTML = chips.map { chip -> String in
            let anchor = chip.0 + ":" + chip.1.trimmed
            return "<a class=\"chip\" href=\"#\" data-anchor=\"\(esc(anchor))\">\(esc(anchorLabel(anchor)))</a>"
        }.joined()
        return "<h\(level) id=\"\(ProjectionSupport.slugify(text))\">\(inlineHTML(text))"
            + "<span class=\"heading-chips\">\(chipHTML)</span></h\(level)>"
    }

    /// `## Hops {code: src/a.py@abc1234}` -> the heading text and its trailing chips.
    /// Mirrors `HEADING_CHIP = \{(video|code|doc|diagram|trace):\s*([^}]+)\}`: findall,
    /// then sub the matches away and trim what is left.
    static func splitHeadingChips(_ text: String) -> (String, [(String, String)]) {
        let kinds = ["video", "code", "doc", "diagram", "trace"]
        let chars = Array(text)
        var chips: [(String, String)] = []
        var remainder = ""
        var i = 0
        while i < chars.count {
            guard chars[i] == "{" else {
                remainder.append(chars[i])
                i += 1
                continue
            }
            guard let close = (i..<chars.count).first(where: { chars[$0] == "}" }), close > i + 1 else {
                remainder.append(chars[i])
                i += 1
                continue
            }
            let inner = String(chars[(i + 1)..<close])
            guard let colon = inner.firstIndex(of: ":"),
                  kinds.contains(String(inner[inner.startIndex..<colon])) else {
                remainder.append(chars[i])
                i += 1
                continue
            }
            let kind = String(inner[inner.startIndex..<colon])
            var value = String(inner[inner.index(after: colon)...])
            while let f = value.first, f.isWhitespace { value.removeFirst() }   // \s* after the colon
            guard !value.isEmpty, !value.contains("}") else {
                remainder.append(chars[i])
                i += 1
                continue
            }
            chips.append((kind, value))
            i = close + 1
        }
        return (remainder.trimmed, chips)
    }

    /// `| a | b |` -> ["a", "b"]. Python strips every leading and trailing pipe before
    /// splitting, so a trailing `|` does not produce a phantom empty cell.
    private static func tableRow(_ line: String) -> [String] {
        var s = line
        while s.hasPrefix("|") { s.removeFirst() }
        while s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmed }
    }

    private static func tableHTML(_ rows: [[String]]) -> String {
        var head: [String]? = nil
        var body = rows
        if rows.count >= 2, isSeparatorRow(rows[1]) {
            head = rows[0]
            body = Array(rows[2...])
        }
        var table = "<table>"
        if let head {
            table += "<thead><tr>" + head.map { "<th>\(inlineHTML($0))</th>" }.joined() + "</tr></thead>"
        }
        table += "<tbody>"
        for row in body {
            table += "<tr>" + row.map { "<td>\(inlineHTML($0))</td>" }.joined() + "</tr>"
        }
        return table + "</tbody></table>"
    }

    /// `|---|:--|` : the joined cells contain nothing but hyphens, colons and spaces.
    private static func isSeparatorRow(_ row: [String]) -> Bool {
        row.joined().allSatisfy { $0 == "-" || $0 == ":" || $0 == " " }
    }

    /// The length of a leading `- `, `* ` or `12. ` marker, or nil when the line is not
    /// a list item. `^([-*]|\d+\.)\s`.
    private static func listMarker(_ stripped: String) -> Int? {
        let chars = Array(stripped)
        guard !chars.isEmpty else { return nil }
        if chars[0] == "-" || chars[0] == "*" {
            return chars.count > 1 && chars[1].isWhitespace ? 2 : nil
        }
        var i = 0
        while i < chars.count, chars[i].isNumber { i += 1 }
        guard i > 0, i < chars.count, chars[i] == ".",
              i + 1 < chars.count, chars[i + 1].isWhitespace else { return nil }
        return i + 2
    }

    private static func isOrderedMarker(_ stripped: String) -> Bool {
        guard let first = stripped.first else { return false }
        return first.isNumber
    }
}

private extension String {
    /// Python's `str.strip()`: every kind of surrounding whitespace, `\r` included, so a
    /// packet written on Windows parses the same as one written anywhere else.
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
