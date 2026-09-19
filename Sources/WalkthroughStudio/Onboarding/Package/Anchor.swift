// Anchor.swift — "Onboard to a Codebase", milestone M2 (package format).
//
// The one anchor grammar used by every citation in an onboarding package:
// the string form (`code:src/a.py@fb63e78#L1-L3`) is the wire format in JSON
// files, markdown links, diagram sidecars and chat replies; the URL form
// (`walkthrough://code/src/a.py?sha=fb63e78&L=1-3`) drives the in-app router
// and link chips. Grammar: docs/onboarding/ARCHITECTURE.md section 2.2 and
// docs/onboarding/PACKET.md section 3. Resolution against a package (does the
// file exist at that sha, is the node in the diagram) is LinkRouter's job, not
// this type's: Anchor only knows syntax.

import Foundation

enum Anchor: Hashable, Codable {
    /// A file (or, with a trailing "/" on the path, a directory) at the pinned
    /// commit. `sha7` is 7 to 40 hex characters as written; nil when the anchor
    /// was not pinned. `lines` is nil for the whole file.
    case code(path: String, sha7: String?, lines: ClosedRange<Int>?)
    /// A moment (`seconds`) or a chapter start (`chapter`) in a video; both nil
    /// means the video itself.
    case video(id: String, seconds: Double?, chapter: String?)
    /// A `##` section of a document, by its heading slug.
    case doc(id: String, slug: String)
    /// A node in a Mermaid diagram, by its node id.
    case diagram(id: String, node: String)
    /// Hop n (1-based) of a trace.
    case trace(id: String, hop: Int)
    /// A Fact record.
    case fact(id: String)
    /// A commit in the mined history.
    case commit(sha: String)
    /// Captured command output `units/<unit>/cmd/<n>.txt` (or `commands/<unit>/<n>.txt` in a packet).
    case cmd(unit: String, n: Int)
    /// A GitHub issue or pull request number.
    case issue(n: Int)
    /// An external http(s) page.
    case url(String)

    /// The in-app URL scheme (WKURLSchemeHandler and chips).
    static let scheme = "walkthrough"

    // MARK: Construction

    /// Parses the string grammar (or a `walkthrough://` URL string); nil when malformed.
    init?(string: String) {
        guard let parsed = try? Anchor.parse(string) else { return nil }
        self = parsed
    }

    /// Parses the `walkthrough://` URL form. A plain http(s) URL becomes `.url`.
    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let scheme = (components.scheme ?? "").lowercased()
        if scheme != Anchor.scheme {
            if scheme == "http" || scheme == "https", let external = try? Anchor.parse("url:" + url.absoluteString) {
                self = external
                return
            }
            return nil
        }

        let kind = (components.host ?? "").lowercased()
        var path = components.path
        if path.hasPrefix("/") { path.removeFirst() }
        let queryItems = components.queryItems ?? []
        let fragment = components.fragment ?? ""

        var candidate: String
        switch kind {
        case "code":
            candidate = "code:" + path
            if let sha = Anchor.queryValue("sha", in: queryItems), !sha.isEmpty {
                candidate += "@" + sha
            }
            if let lines = Anchor.queryValue("L", in: queryItems), !lines.isEmpty {
                // "12-30" -> "#L12-L30", "12" -> "#L12"
                let parts = lines.split(separator: "-", omittingEmptySubsequences: false)
                if parts.count == 2 {
                    candidate += "#L\(parts[0])-L\(parts[1])"
                } else {
                    candidate += "#L\(lines)"
                }
            }
        case "video":
            candidate = "video:" + path
            if let t = Anchor.queryValue("t", in: queryItems) {
                candidate += "#t=" + t
            } else if let c = Anchor.queryValue("c", in: queryItems) {
                candidate += "#c=" + c
            }
        case "doc":
            candidate = "doc:" + path + "#" + fragment
        case "diagram":
            candidate = "diagram:" + path + "#" + fragment
        case "trace":
            candidate = "trace:" + path + "#" + fragment
        case "fact":
            candidate = "fact:" + path
        case "commit":
            candidate = "commit:" + path
        case "cmd":
            candidate = "cmd:" + path
        case "issue":
            candidate = "issue:" + path
        default:
            return nil
        }

        guard let parsed = try? Anchor.parse(candidate) else { return nil }
        self = parsed
    }

    /// Parses the string grammar and explains a rejection with a `StudioError`.
    static func parse(_ raw: String) throws -> Anchor {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { throw StudioError("anchor: empty string") }

        let lowered = s.lowercased()
        if lowered.hasPrefix(Anchor.scheme + "://") {
            guard let url = URL(string: s), let anchor = Anchor(url: url) else {
                throw StudioError("anchor '\(s)': unparseable \(Anchor.scheme):// URL")
            }
            return anchor
        }
        // A bare external URL is the `url:` kind (so `Anchor(string: anchor.url.absoluteString)`
        // round-trips for external anchors too).
        if lowered.hasPrefix("https://") || lowered.hasPrefix("http://") {
            return try parse("url:" + s)
        }

        guard let colon = s.firstIndex(of: ":") else {
            throw StudioError("anchor '\(s)': missing kind prefix (code:, video:, doc:, ...)")
        }
        let kind = String(s[s.startIndex..<colon])
        let rest = String(s[s.index(after: colon)...])

        switch kind {
        case "code":
            return try parseCode(rest, original: s)
        case "video":
            return try parseVideo(rest, original: s)
        case "doc":
            let (id, fragment) = try splitRequiredFragment(rest, original: s, what: "slug")
            return .doc(id: id, slug: fragment)
        case "diagram":
            let (id, fragment) = try splitRequiredFragment(rest, original: s, what: "node id")
            return .diagram(id: id, node: fragment)
        case "trace":
            let (id, fragment) = try splitRequiredFragment(rest, original: s, what: "hop")
            guard fragment.hasPrefix("hop"), let hop = Int(fragment.dropFirst(3)), hop >= 1 else {
                throw StudioError("anchor '\(s)': trace fragment must be #hop<n> with n >= 1")
            }
            return .trace(id: id, hop: hop)
        case "fact":
            guard !rest.isEmpty, !containsWhitespace(rest) else {
                throw StudioError("anchor '\(s)': fact id must be non-empty without whitespace")
            }
            return .fact(id: rest)
        case "commit":
            guard isHex(rest, minLength: 7, maxLength: 40) else {
                throw StudioError("anchor '\(s)': commit sha must be 7 to 40 hex characters")
            }
            return .commit(sha: rest)
        case "cmd":
            guard let slash = rest.lastIndex(of: "/") else {
                throw StudioError("anchor '\(s)': cmd needs <unit>/<n>")
            }
            let unit = String(rest[rest.startIndex..<slash])
            let number = String(rest[rest.index(after: slash)...])
            guard !unit.isEmpty, !containsWhitespace(unit), let n = Int(number), n >= 0 else {
                throw StudioError("anchor '\(s)': cmd needs a non-empty unit id and a non-negative integer")
            }
            return .cmd(unit: unit, n: n)
        case "issue":
            guard let n = Int(rest), n >= 1 else {
                throw StudioError("anchor '\(s)': issue number must be a positive integer")
            }
            return .issue(n: n)
        case "url":
            let lower = rest.lowercased()
            guard lower.hasPrefix("https://") || lower.hasPrefix("http://"), URL(string: rest) != nil else {
                throw StudioError("anchor '\(s)': url must be an absolute http(s) URL")
            }
            return .url(rest)
        default:
            throw StudioError("anchor '\(s)': unknown kind '\(kind)'")
        }
    }

    // MARK: String form (the wire format)

    var string: String {
        switch self {
        case .code(let path, let sha7, let lines):
            var s = "code:" + path
            if let sha7 = sha7 { s += "@" + sha7 }
            if let lines = lines { s += "#" + Anchor.lineFragment(lines) }
            return s
        case .video(let id, let seconds, let chapter):
            var s = "video:" + id
            if let seconds = seconds {
                s += "#t=" + Anchor.formatSeconds(seconds)
            } else if let chapter = chapter {
                s += "#c=" + chapter
            }
            return s
        case .doc(let id, let slug):
            return "doc:\(id)#\(slug)"
        case .diagram(let id, let node):
            return "diagram:\(id)#\(node)"
        case .trace(let id, let hop):
            return "trace:\(id)#hop\(hop)"
        case .fact(let id):
            return "fact:" + id
        case .commit(let sha):
            return "commit:" + sha
        case .cmd(let unit, let n):
            return "cmd:\(unit)/\(n)"
        case .issue(let n):
            return "issue:\(n)"
        case .url(let s):
            return "url:" + s
        }
    }

    /// The kind prefix ("code", "video", ...), useful for grouping and icons.
    var kind: String {
        switch self {
        case .code: return "code"
        case .video: return "video"
        case .doc: return "doc"
        case .diagram: return "diagram"
        case .trace: return "trace"
        case .fact: return "fact"
        case .commit: return "commit"
        case .cmd: return "cmd"
        case .issue: return "issue"
        case .url: return "url"
        }
    }

    /// True for a `code:` anchor whose path names a directory (trailing "/").
    var isDirectory: Bool {
        if case .code(let path, _, _) = self { return path.hasSuffix("/") }
        return false
    }

    // MARK: URL form (in-app router)

    /// `walkthrough://<kind>/<id>...` per ARCHITECTURE.md 2.2; external `.url`
    /// anchors return the external URL itself.
    var url: URL {
        let fallback = URL(string: "\(Anchor.scheme)://invalid")!
        var components = URLComponents()
        components.scheme = Anchor.scheme

        switch self {
        case .code(let path, let sha7, let lines):
            components.host = "code"
            components.path = "/" + path
            var items: [URLQueryItem] = []
            if let sha7 = sha7 { items.append(URLQueryItem(name: "sha", value: sha7)) }
            if let lines = lines {
                let value = lines.lowerBound == lines.upperBound
                    ? "\(lines.lowerBound)"
                    : "\(lines.lowerBound)-\(lines.upperBound)"
                items.append(URLQueryItem(name: "L", value: value))
            }
            if !items.isEmpty { components.queryItems = items }
        case .video(let id, let seconds, let chapter):
            components.host = "video"
            components.path = "/" + id
            if let seconds = seconds {
                components.queryItems = [URLQueryItem(name: "t", value: Anchor.formatSeconds(seconds))]
            } else if let chapter = chapter {
                components.queryItems = [URLQueryItem(name: "c", value: chapter)]
            }
        case .doc(let id, let slug):
            components.host = "doc"
            components.path = "/" + id
            components.fragment = slug
        case .diagram(let id, let node):
            components.host = "diagram"
            components.path = "/" + id
            components.fragment = node
        case .trace(let id, let hop):
            components.host = "trace"
            components.path = "/" + id
            components.fragment = "hop\(hop)"
        case .fact(let id):
            components.host = "fact"
            components.path = "/" + id
        case .commit(let sha):
            components.host = "commit"
            components.path = "/" + sha
        case .cmd(let unit, let n):
            components.host = "cmd"
            components.path = "/\(unit)/\(n)"
        case .issue(let n):
            components.host = "issue"
            components.path = "/\(n)"
        case .url(let external):
            return URL(string: external) ?? fallback
        }
        return components.url ?? fallback
    }

    // MARK: Codable (a single string)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        do {
            self = try Anchor.parse(raw)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Malformed anchor '\(raw)': \(error.localizedDescription)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }

    // MARK: Parsing helpers

    /// `code:` — the path is everything before the LAST "@" that is followed by
    /// 7 to 40 hex characters (up to a "#" or the end); the fragment is what
    /// follows the first "#" after that sha. Paths may contain "@" and "#".
    /// Unpinned anchors (no sha) accept only a trailing "#L<a>[-L<b>]" fragment.
    private static func parseCode(_ rest: String, original: String) throws -> Anchor {
        let chars = Array(rest)
        var path = rest
        var sha: String? = nil
        var fragment: String? = nil

        var i = chars.count - 1
        while i >= 0 {
            if chars[i] == "@" {
                var j = i + 1
                while j < chars.count && chars[j] != "#" { j += 1 }
                let candidate = String(chars[(i + 1)..<j])
                if isHex(candidate, minLength: 7, maxLength: 40) {
                    path = String(chars[0..<i])
                    sha = candidate
                    if j < chars.count {
                        fragment = String(chars[(j + 1)...])
                    }
                    break
                }
            }
            i -= 1
        }

        if sha == nil, let hash = rest.lastIndex(of: "#") {
            let trailing = String(rest[rest.index(after: hash)...])
            if (try? parseLines(trailing, original: original)) != nil {
                path = String(rest[rest.startIndex..<hash])
                fragment = trailing
            }
        }

        try validatePath(path, original: original)

        var lines: ClosedRange<Int>? = nil
        if let fragment = fragment {
            guard !path.hasSuffix("/") else {
                throw StudioError("anchor '\(original)': directory anchors take no fragment")
            }
            lines = try parseLines(fragment, original: original)
        }
        return .code(path: path, sha7: sha, lines: lines)
    }

    private static func parseVideo(_ rest: String, original: String) throws -> Anchor {
        guard let hash = rest.firstIndex(of: "#") else {
            guard !rest.isEmpty, !containsWhitespace(rest) else {
                throw StudioError("anchor '\(original)': video id must be non-empty without whitespace")
            }
            return .video(id: rest, seconds: nil, chapter: nil)
        }
        let id = String(rest[rest.startIndex..<hash])
        let fragment = String(rest[rest.index(after: hash)...])
        guard !id.isEmpty, !containsWhitespace(id) else {
            throw StudioError("anchor '\(original)': video id must be non-empty without whitespace")
        }
        if fragment.hasPrefix("t=") {
            let value = String(fragment.dropFirst(2))
            guard let seconds = Double(value), seconds.isFinite, seconds >= 0 else {
                throw StudioError("anchor '\(original)': #t= needs a non-negative decimal number of seconds")
            }
            return .video(id: id, seconds: seconds, chapter: nil)
        }
        if fragment.hasPrefix("c=") {
            let chapter = String(fragment.dropFirst(2))
            guard !chapter.isEmpty, !containsWhitespace(chapter) else {
                throw StudioError("anchor '\(original)': #c= needs a chapter id")
            }
            return .video(id: id, seconds: nil, chapter: chapter)
        }
        throw StudioError("anchor '\(original)': video fragment must be #t=<seconds> or #c=<chapterId>")
    }

    /// `<id>#<fragment>` where both halves are required and non-empty.
    private static func splitRequiredFragment(_ rest: String, original: String, what: String) throws -> (String, String) {
        guard let hash = rest.firstIndex(of: "#") else {
            throw StudioError("anchor '\(original)': missing #<\(what)>")
        }
        let id = String(rest[rest.startIndex..<hash])
        let fragment = String(rest[rest.index(after: hash)...])
        guard !id.isEmpty, !containsWhitespace(id) else {
            throw StudioError("anchor '\(original)': id must be non-empty without whitespace")
        }
        guard !fragment.isEmpty, !containsWhitespace(fragment) else {
            throw StudioError("anchor '\(original)': \(what) must be non-empty without whitespace")
        }
        return (id, fragment)
    }

    /// "L12" -> 12...12, "L12-L30" -> 12...30. Lines are 1-based; end >= start.
    private static func parseLines(_ fragment: String, original: String) throws -> ClosedRange<Int> {
        guard fragment.hasPrefix("L") else {
            throw StudioError("anchor '\(original)': code fragment must be #L<a> or #L<a>-L<b>")
        }
        let body = fragment.dropFirst()
        let parts = body.split(separator: "-", omittingEmptySubsequences: false)
        if parts.count == 1 {
            guard let a = Int(parts[0]), a >= 1 else {
                throw StudioError("anchor '\(original)': line number must be a positive integer")
            }
            return a...a
        }
        if parts.count == 2 {
            guard let a = Int(parts[0]), a >= 1 else {
                throw StudioError("anchor '\(original)': start line must be a positive integer")
            }
            guard parts[1].hasPrefix("L"), let b = Int(parts[1].dropFirst()) else {
                throw StudioError("anchor '\(original)': range end must be L<b>")
            }
            guard b >= a else {
                throw StudioError("anchor '\(original)': range end L\(b) is before start L\(a)")
            }
            return a...b
        }
        throw StudioError("anchor '\(original)': code fragment must be #L<a> or #L<a>-L<b>")
    }

    private static func validatePath(_ path: String, original: String) throws {
        guard !path.isEmpty else {
            throw StudioError("anchor '\(original)': empty path")
        }
        guard !path.hasPrefix("/") else {
            throw StudioError("anchor '\(original)': path must be relative (no leading /)")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains("..") else {
            throw StudioError("anchor '\(original)': path must not contain '..'")
        }
        guard !path.contains("\n"), !path.contains("\r") else {
            throw StudioError("anchor '\(original)': path must not contain line breaks")
        }
    }

    private static func isHex(_ s: String, minLength: Int, maxLength: Int) -> Bool {
        guard s.count >= minLength, s.count <= maxLength else { return false }
        let digits = "0123456789abcdefABCDEF"
        for ch in s where !digits.contains(ch) { return false }
        return true
    }

    private static func containsWhitespace(_ s: String) -> Bool {
        s.unicodeScalars.contains { CharacterSet.whitespacesAndNewlines.contains($0) }
    }

    private static func queryValue(_ name: String, in items: [URLQueryItem]) -> String? {
        items.first(where: { $0.name == name })?.value
    }

    /// 5...5 -> "L5"; 1...3 -> "L1-L3".
    static func lineFragment(_ lines: ClosedRange<Int>) -> String {
        lines.lowerBound == lines.upperBound
            ? "L\(lines.lowerBound)"
            : "L\(lines.lowerBound)-L\(lines.upperBound)"
    }

    /// Whole seconds print without a fraction ("12"), others as the shortest
    /// round-tripping decimal ("12.5").
    static func formatSeconds(_ seconds: Double) -> String {
        if seconds == seconds.rounded(.towardZero), abs(seconds) < 1e12 {
            return String(Int(seconds))
        }
        return String(seconds)
    }
}

extension Anchor: CustomStringConvertible {
    var description: String { string }
}
