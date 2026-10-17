// CitationParser.swift — "Onboard to a Codebase", milestone M7 (playback chat).
//
// Turns a chat reply into runs of text and citation chips (ON-9.2). The grammar is
// the package's own `[[anchor]]` / `[[anchor|label]]` (D5: one citation syntax, one
// resolver), so the scan itself is `MarkdownLite.scanCitations` — the same scanner
// the registers and the backlink index use. What this file adds is what a *stream*
// needs and a finished document does not:
//
//  - **A citation that has not finished arriving is held back.** A reply streams in
//    pieces, and `[[code:src/a.p` is either the start of a chip or two brackets the
//    model meant literally; showing it as text and then snapping it into a chip a
//    moment later makes the transcript jump. `parse(_:final:)` keeps an unterminated
//    `[[` out of the runs until the stream says it is over.
//  - **Every citation is resolved as it is parsed.** A chip that opens nothing is a
//    worse answer than plain text, so an unresolvable anchor becomes text with a
//    warning glyph instead of a dead button.
//  - **A literal bracket next to a citation is not part of its anchor.** The scanner
//    mirrors the Python regex byte for byte, so `[[[code:a]]]` reads as the anchor
//    `[code:a`; here the stray `[` goes back to the text before the chip and the `]`
//    after it stays text, which is what the model meant.

import Foundation

enum CitationParser {

    /// One run of a reply, in order.
    enum Run: Equatable, Sendable {
        case text(String)
        /// `resolved` is false when the anchor is malformed or names nothing in the
        /// package; the view shows it as plain text with a warning glyph.
        case citation(anchor: String, label: String, resolved: Bool)
    }

    struct Parsed: Equatable, Sendable {
        var runs: [Run] = []
        /// Text held back because it might be the start of a citation. Empty once
        /// the stream is final.
        var pending: String = ""

        var citations: [(anchor: String, resolved: Bool)] {
            runs.compactMap {
                if case .citation(let anchor, _, let resolved) = $0 { return (anchor, resolved) }
                return nil
            }
        }

        /// The reply with chips replaced by their labels — what a copy or a summary
        /// of the turn reads.
        var plainText: String {
            runs.map {
                switch $0 {
                case .text(let text): return text
                case .citation(_, let label, _): return label
                }
            }.joined()
        }
    }

    /// Parse `text`. `resolve` answers whether an anchor opens something; the view
    /// model passes the package's `LinkRouter`, a probe passes a set.
    ///
    /// With `final: false` an unterminated `[[` at the end is returned in `pending`
    /// instead of as text. A `[[` that is clearly not going to become a citation (a
    /// newline inside it, or more than `maxAnchorLength` characters without a close)
    /// is released as text even mid-stream, so a model that writes `[[` literally
    /// does not freeze the rest of its reply.
    static func parse(_ text: String, final: Bool = true,
                      resolve: (String) -> Bool) -> Parsed {
        var chars = Array(text)
        var held: [Character] = []
        if !final, let cut = unterminatedOpen(in: chars) {
            held = Array(chars[cut...])
            chars = Array(chars[..<cut])
        }

        var parsed = Parsed()
        var buffer = ""
        func flush() {
            if !buffer.isEmpty { parsed.runs.append(.text(buffer)) }
            buffer = ""
        }

        var cursor = 0
        for citation in MarkdownLite.scanCitations(chars) {
            buffer += String(chars[cursor..<citation.range.lowerBound])
            var anchor = citation.anchor.trimmingCharacters(in: .whitespaces)
            // `[[[code:a]]]`: the scanner's anchor starts with the literal bracket.
            while anchor.hasPrefix("[") {
                buffer += "["
                anchor.removeFirst()
            }
            guard !anchor.isEmpty else {
                buffer += String(chars[citation.range])
                cursor = citation.range.upperBound
                continue
            }
            flush()
            let label = citation.label ?? MarkdownLite.anchorLabel(anchor)
            let resolved = Anchor(string: anchor) != nil && resolve(anchor)
            parsed.runs.append(.citation(anchor: anchor, label: label, resolved: resolved))
            cursor = citation.range.upperBound
        }
        buffer += String(chars[cursor...])
        flush()
        parsed.pending = String(held)
        return parsed
    }

    /// An anchor longer than this without its `]]` is not an anchor: the longest
    /// real ones are a deep path, a 40-character sha and a line range.
    static let maxAnchorLength = 400

    /// Where the last `[[` that has no `]]` after it begins, if that `[[` could
    /// still become a citation. A single trailing `[` counts too: it may be the
    /// first half of `[[`.
    static func unterminatedOpen(in chars: [Character]) -> Int? {
        guard !chars.isEmpty else { return nil }
        var index = chars.count - 1
        while index >= 0 {
            if chars[index] == "]", index > 0, chars[index - 1] == "]" { return nil }
            if chars[index] == "[" {
                // Walk back over a run of brackets so `[[[` is held from its first.
                var start = index
                while start > 0, chars[start - 1] == "[" { start -= 1 }
                let tail = chars[start...]
                if tail.count > maxAnchorLength || tail.contains("\n") { return nil }
                if chars.count - start == 1 || tail.starts(with: ["[", "["]) { return start }
                return nil
            }
            if chars[index] == "\n" { return nil }
            index -= 1
        }
        return nil
    }
}
