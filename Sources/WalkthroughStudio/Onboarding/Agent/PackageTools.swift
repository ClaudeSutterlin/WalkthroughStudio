// PackageTools.swift — "Onboard to a Codebase", milestone M7 (playback chat).
//
// The playback agent's tools (ARCHITECTURE 4.3, "Chat tools"). Read-only over the
// repository at the pinned commit and over the package itself, with two exceptions
// that write nothing the viewer did not see happen: `flag_contradiction` appends to
// `review/flags.json` (ON-9.6), and `seek_video` records a proposal the viewer has
// to click (ON-9.7) — the app never moves the video on the model's say-so.
//
// Every tool answers with the anchors it read, in the package's one grammar, so a
// reply can cite exactly the lines the tool returned and the chips resolve.
//
// Where the code comes from: a package that carries a pinned checkout (`repo/`,
// or the clone the user pointed the run at) is read with `git show <sha>:<path>`,
// which can never return a working-tree edit (ON-8.3, ON-9.3). A package without
// one — an imported packet, the selftest fixture — still carries every file its
// findings cite, at the pinned commit, in `code/<path>.json`; the tools read those
// and say plainly that nothing else travelled with the package, instead of
// pretending a missing file is empty.

import Foundation

// MARK: - The code at the pinned commit

struct PinnedSource: Sendable {
    let sha: String
    /// A git checkout that contains `sha`, or nil to read only the package's
    /// `code/` snapshot.
    let repo: URL?
    let snapshotRoot: URL
    let git: GitRunner

    var sha7: String { String(sha.prefix(7)) }

    init(sha: String, repo: URL?, snapshotRoot: URL, git: GitRunner = GitRunner()) {
        self.sha = sha
        self.repo = repo
        self.snapshotRoot = snapshotRoot
        self.git = git
    }

    /// The source for an open package: an explicit checkout when the caller has
    /// one, else the package's pinned worktree when it is a git checkout (the
    /// layout creates an empty `repo/`, so its existence proves nothing), else the
    /// snapshot alone.
    static func forPackage(_ store: PackageStore, manifest: OnboardingManifest,
                           repo: URL? = nil) -> PinnedSource {
        var checkout = repo
        if checkout == nil {
            let clone = store.url(manifest.localClone.isEmpty ? "repo" : manifest.localClone)
            if FileManager.default.fileExists(atPath: clone.appendingPathComponent(".git").path) {
                checkout = clone
            }
        }
        return PinnedSource(sha: manifest.headSHA, repo: checkout, snapshotRoot: store.url("code"))
    }

    /// The file's lines at the pinned commit, or nil when it is not there.
    ///
    /// A trailing newline does not make a phantom empty last line: line numbers
    /// here must match the `#L` numbers every anchor in the package uses.
    func lines(of path: String) async -> [String]? {
        var text: String? = nil
        if let repo, !sha.isEmpty {
            text = try? await git.show(sha: sha, path: path, repo: repo)
        }
        if text == nil {
            text = snapshotText(path)
        }
        guard let text else { return nil }
        var lines = text.components(separatedBy: "\n")
        if lines.count > 1, lines.last == "" { lines.removeLast() }
        return lines
    }

    /// Every file path at the pinned commit (or in the snapshot), sorted.
    func paths() async -> [String] {
        if let repo, !sha.isEmpty,
           let listing = try? await git.run(["ls-tree", "-r", "--name-only", sha], in: repo) {
            return listing.split(separator: "\n").map(String.init).sorted()
        }
        let index = snapshotRoot.appendingPathComponent("index.json")
        guard let data = try? Data(contentsOf: index),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let paths = value.objectValue?["paths"]?.arrayValue else { return [] }
        return paths.compactMap { $0.stringValue }.sorted()
    }

    /// True when only the snapshot is available, so a tool can say why a file it
    /// was asked for is missing.
    var isSnapshotOnly: Bool { repo == nil }

    private func snapshotText(_ path: String) -> String? {
        let url = snapshotRoot.appendingPathComponent(path + ".json")
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let lines = value.objectValue?["lines"]?.arrayValue else { return nil }
        return lines.map { $0.stringValue ?? "" }.joined(separator: "\n")
    }
}

// MARK: - The tools

struct PackageTools: AgentTools, @unchecked Sendable {
    // `@unchecked`: `PackageStore` is a class with no mutable state of its own past
    // init, and every write in here goes through the `ReviewFiles` actor.

    static let readFileMaxLines = 400
    static let readFileDefaultLines = 200
    static let grepMaxResults = 200
    static let searchMaxResults = 12

    let store: PackageStore
    let source: PinnedSource
    let router: LinkRouter
    let review: ReviewFiles
    /// Usable and refuted facts by id. Refuted ones are returned marked as such:
    /// a viewer asking about a claim the verifier rejected deserves to hear that.
    let facts: [String: PacketFact]

    init(store: PackageStore, source: PinnedSource, router: LinkRouter, review: ReviewFiles,
         facts: [String: PacketFact]) {
        self.store = store
        self.source = source
        self.router = router
        self.review = review
        self.facts = facts
    }

    // MARK: Declarations

    static let names: [String] = [
        "flag_contradiction", "get_diagram", "get_doc_section", "get_transcript_range", "grep",
        "list_dir", "read_fact", "read_file", "search_package", "seek_video",
    ]

    var specs: [ToolSpec] { PackageTools.specs }

    static var specs: [ToolSpec] {
        let string = { (description: String) in ToolSpec.property("string", description) }
        let number = { (description: String) in ToolSpec.property("number", description) }
        // Strict tools require every property in `required`; an optional value is a
        // nullable type instead of an absent key.
        let optionalInt = { (description: String) -> JSONValue in
            .object(["type": .array([.string("integer"), .string("null")]),
                     "description": .string(description)])
        }
        let optionalString = { (description: String) -> JSONValue in
            .object(["type": .array([.string("string"), .string("null")]),
                     "description": .string(description)])
        }
        return [
            ToolSpec(
                name: "read_file",
                description: "Read a file of the repository at the pinned commit. Returns numbered "
                    + "lines under a header naming the exact code: anchor to cite. At most "
                    + "\(readFileMaxLines) lines per call; the default is the first \(readFileDefaultLines).",
                inputSchema: ToolSpec.schema([
                    "path": string("Repository-relative path, e.g. src/api/orders_handler.py."),
                    "startLine": optionalInt("First line, 1-based; null for 1."),
                    "endLine": optionalInt("Last line, inclusive; null for a default window."),
                ], required: ["path", "startLine", "endLine"])),
            ToolSpec(
                name: "list_dir",
                description: "List a directory of the repository at the pinned commit.",
                inputSchema: ToolSpec.schema([
                    "path": string("Repository-relative directory; \".\" for the root."),
                    "depth": optionalInt("1 or 2; null for 1."),
                ], required: ["path", "depth"])),
            ToolSpec(
                name: "grep",
                description: "Search the repository at the pinned commit with a regular expression. "
                    + "Returns path:line: text, at most \(grepMaxResults) matches.",
                inputSchema: ToolSpec.schema([
                    "pattern": string("Extended regular expression."),
                    "glob": optionalString("Only paths matching this glob, e.g. src/**/*.py; null for all."),
                    "maxResults": optionalInt("Null for \(grepMaxResults)."),
                ], required: ["pattern", "glob", "maxResults"])),
            ToolSpec(
                name: "search_package",
                description: "Search this onboarding package: document paragraphs and every video's "
                    + "narration. Returns the doc: and video: anchors where the topic is covered.",
                inputSchema: ToolSpec.schema([
                    "query": string("A few words."),
                ], required: ["query"])),
            ToolSpec(
                name: "get_doc_section",
                description: "Read one section of a package document by its heading slug.",
                inputSchema: ToolSpec.schema([
                    "docId": string("The document id, e.g. architecture."),
                    "slug": string("The heading slug, e.g. entry-points."),
                ], required: ["docId", "slug"])),
            ToolSpec(
                name: "get_transcript_range",
                description: "The narration of a video between two times, with a video: anchor per "
                    + "sentence. Anything after the viewer's current time has not been narrated yet.",
                inputSchema: ToolSpec.schema([
                    "videoId": string("The video id."),
                    "fromT": number("Start, in seconds."),
                    "toT": number("End, in seconds."),
                ], required: ["videoId", "fromT", "toT"])),
            ToolSpec(
                name: "get_diagram",
                description: "A package diagram's Mermaid source and the anchor behind each node.",
                inputSchema: ToolSpec.schema([
                    "diagramId": string("The diagram id, e.g. c4-container."),
                ], required: ["diagramId"])),
            ToolSpec(
                name: "read_fact",
                description: "One research fact by id: its claim, status and evidence with excerpts.",
                inputSchema: ToolSpec.schema([
                    "id": string("The fact id, e.g. F-map-src-002."),
                ], required: ["id"])),
            ToolSpec(
                name: "flag_contradiction",
                description: "Record that the narration says something the code contradicts, for the "
                    + "package author to fix. Call it only after reading the code that contradicts it.",
                inputSchema: ToolSpec.schema([
                    "videoId": string("The video id."),
                    "t": number("The time, in seconds, of the narration that is wrong."),
                    "anchor": string("The code: anchor that contradicts it."),
                    "claim": string("What the narration claims."),
                    "reason": string("What the code shows instead."),
                ], required: ["videoId", "t", "anchor", "claim", "reason"])),
            ToolSpec(
                name: "seek_video",
                description: "Propose jumping the video to the moment that answers the question. The "
                    + "viewer sees a Jump button; the video does not move unless they click it.",
                inputSchema: ToolSpec.schema([
                    "t": number("The time to jump to, in seconds."),
                    "why": string("One short phrase for the button, e.g. where the retry loop is shown."),
                ], required: ["t", "why"])),
        ]
    }

    // MARK: Dispatch

    func run(name: String, input: [String: JSONValue], toolUseId: String) async -> ToolOutcome {
        switch name {
        case "read_file": return await readFile(input)
        case "list_dir": return await listDir(input)
        case "grep": return await grep(input)
        case "search_package": return searchPackage(input)
        case "get_doc_section": return docSection(input)
        case "get_transcript_range": return transcriptRange(input)
        case "get_diagram": return diagram(input)
        case "read_fact": return readFact(input)
        case "flag_contradiction": return await flagContradiction(input)
        case "seek_video": return seekVideo(input)
        default:
            return .error("There is no tool named \(name). The tools are: "
                          + PackageTools.names.joined(separator: ", ") + ".")
        }
    }

    // MARK: Repository

    /// A repository-relative path, or nil for one that would leave the repository.
    static func cleanPath(_ raw: String?) -> String? {
        guard var path = raw?.trimmingCharacters(in: .whitespaces) else { return nil }
        while path.hasPrefix("./") { path.removeFirst(2) }
        if path == "." || path.isEmpty { return "" }
        guard !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("\\") else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !parts.contains(where: { $0 == ".." }) else { return nil }
        return parts.joined(separator: "/")
    }

    static let outsideRepo = "That path is outside the repository. Paths are relative to the "
        + "repository root, e.g. src/api/orders_handler.py."

    private func readFile(_ input: [String: JSONValue]) async -> ToolOutcome {
        guard let path = PackageTools.cleanPath(input["path"]?.stringValue), !path.isEmpty else {
            return .error(PackageTools.outsideRepo)
        }
        guard let lines = await source.lines(of: path) else {
            return .error(await missingFileMessage(path))
        }
        let total = lines.count
        let requestedStart = PackageTools.int(input["startLine"]) ?? 1
        let start = min(max(1, requestedStart), max(1, total))
        let defaultEnd = start + PackageTools.readFileDefaultLines - 1
        let requestedEnd = PackageTools.int(input["endLine"]) ?? defaultEnd
        let end = min(total, max(start, min(requestedEnd, start + PackageTools.readFileMaxLines - 1)))
        guard total > 0 else {
            return ToolOutcome("code:\(path)@\(source.sha7)\n(the file is empty)")
        }
        var out = "code:\(path)@\(source.sha7)#L\(start)-L\(end)  (\(total) lines in the file)\n"
        out += PackageTools.numbered(lines, from: start, to: end)
        if end < total {
            out += "\n… lines \(end + 1)-\(total) not shown: call read_file with startLine \(end + 1)."
        }
        if requestedEnd - start + 1 > PackageTools.readFileMaxLines {
            out += "\n(at most \(PackageTools.readFileMaxLines) lines per call)"
        }
        return ToolOutcome(out)
    }

    /// `   7 | text` — the width matches the line count so columns line up.
    static func numbered(_ lines: [String], from start: Int, to end: Int) -> String {
        guard start <= end, start >= 1, end <= lines.count else { return "" }
        let width = String(end).count
        return (start...end).map { number in
            let label = String(number)
            return String(repeating: " ", count: max(0, width - label.count)) + label
                + " | " + lines[number - 1]
        }.joined(separator: "\n")
    }

    private func missingFileMessage(_ path: String) async -> String {
        let all = await source.paths()
        let directory = path.split(separator: "/").dropLast().joined(separator: "/")
        let siblings = all.filter {
            directory.isEmpty ? !$0.contains("/") : $0.hasPrefix(directory + "/")
        }.prefix(12)
        var message = "\(path) is not in the repository at \(source.sha7)."
        if source.isSnapshotOnly {
            message += " This package carries only the files its findings cite."
        }
        if !siblings.isEmpty {
            message += " Files there: " + siblings.joined(separator: ", ") + "."
        } else if !all.isEmpty {
            message += " Call list_dir to see what there is."
        }
        return message
    }

    private func listDir(_ input: [String: JSONValue]) async -> ToolOutcome {
        guard let path = PackageTools.cleanPath(input["path"]?.stringValue) else {
            return .error(PackageTools.outsideRepo)
        }
        let depth = min(2, max(1, PackageTools.int(input["depth"]) ?? 1))
        let prefix = path.isEmpty ? "" : path + "/"
        var entries: [String] = []
        for file in await source.paths() where file.hasPrefix(prefix) {
            let rest = file.dropFirst(prefix.count).split(separator: "/").map(String.init)
            guard !rest.isEmpty else { continue }
            let shown = rest.prefix(depth)
            let entry = shown.joined(separator: "/") + (rest.count > depth ? "/" : "")
            if !entries.contains(entry) { entries.append(entry) }
            // The directories on the way down are entries too, at depth 2.
            if depth == 2, rest.count > 1, !entries.contains(rest[0] + "/") {
                entries.append(rest[0] + "/")
            }
        }
        guard !entries.isEmpty else {
            return .error("\(path.isEmpty ? "The repository" : path) has no entries at \(source.sha7)"
                          + (source.isSnapshotOnly ? " in this package (it carries only cited files)." : "."))
        }
        let anchor = "code:\(path.isEmpty ? "./" : prefix)@\(source.sha7)"
        let note = source.isSnapshotOnly ? "\n(only the files this package's findings cite travelled with it)" : ""
        return ToolOutcome(anchor + "\n" + entries.sorted().joined(separator: "\n") + note)
    }

    private func grep(_ input: [String: JSONValue]) async -> ToolOutcome {
        guard let pattern = input["pattern"]?.stringValue, !pattern.isEmpty else {
            return .error("pattern is empty. Pass an extended regular expression, e.g. def handle_.")
        }
        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: pattern)
        } catch {
            return .error("\(pattern) is not a valid regular expression; escape ( [ { . * + ? with \\.")
        }
        let glob = input["glob"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let limit = min(PackageTools.grepMaxResults, max(1, PackageTools.int(input["maxResults"])
                                                        ?? PackageTools.grepMaxResults))
        var hits: [String] = []
        var truncated = false
        search: for path in await source.paths() {
            if let glob, !PackageTools.matches(glob: glob, path: path) { continue }
            guard let lines = await source.lines(of: path) else { continue }
            for (index, line) in lines.enumerated() {
                let range = NSRange(line.startIndex..<line.endIndex, in: line)
                guard regex.firstMatch(in: line, range: range) != nil else { continue }
                if hits.count == limit {
                    truncated = true
                    break search
                }
                hits.append("\(path):\(index + 1): \(ProjectionSupport.clip(line, 200))")
            }
        }
        guard !hits.isEmpty else {
            return ToolOutcome("No matches for \(pattern)" + (glob.map { " in \($0)" } ?? "")
                               + " at \(source.sha7).")
        }
        var out = "Matches at \(source.sha7) (cite as code:<path>@\(source.sha7)#L<line>):\n"
            + hits.joined(separator: "\n")
        if truncated { out += "\n… more matches not shown: narrow the pattern or the glob." }
        return ToolOutcome(out)
    }

    /// `fnmatch` with `**` treated as "any number of directories", which is what
    /// the model means by `src/**/*.py`.
    static func matches(glob: String, path: String) -> Bool {
        if fnmatch(glob, path, 0) == 0 { return true }
        if glob.contains("**/") {
            let collapsed = glob.replacingOccurrences(of: "**/", with: "")
            if fnmatch(collapsed, path, 0) == 0 { return true }
            let anyDepth = glob.replacingOccurrences(of: "**/", with: "*/")
            if fnmatch(anyDepth, path, 0) == 0 { return true }
        }
        if !glob.contains("/") {
            // A bare *.py matches at any depth.
            return fnmatch(glob, (path as NSString).lastPathComponent, 0) == 0
        }
        return false
    }

    // MARK: Package

    private func searchPackage(_ input: [String: JSONValue]) -> ToolOutcome {
        let terms = (input["query"]?.stringValue ?? "")
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" })
            .map(String.init)
            .filter { $0.count > 1 }
        guard !terms.isEmpty else { return .error("query is empty; pass a few words.") }

        var scored: [(score: Int, line: String)] = []
        func consider(_ text: String, anchor: String) {
            let lower = text.lowercased()
            let score = terms.filter { lower.contains($0) }.count
            guard score > 0 else { return }
            scored.append((score, "[[\(anchor)]] \(ProjectionSupport.clip(PackageTools.plain(text), 220))"))
        }

        for name in store.listing("docs") where name.hasSuffix(".md") {
            let id = String(name.dropLast(3))
            guard let text = try? store.readString("docs/\(name)") else { continue }
            for section in PackageTools.sections(of: text) {
                for paragraph in section.body.components(separatedBy: "\n")
                    where !paragraph.trimmingCharacters(in: .whitespaces).isEmpty {
                    consider(section.title + " " + paragraph, anchor: "doc:\(id)#\(section.slug)")
                }
            }
        }
        for videoID in store.listing("videos") {
            guard let transcript = try? store.readJSON(TranscriptDoc.self,
                                                       from: "videos/\(videoID)/\(TranscriptDoc.fileName)")
            else { continue }
            for segment in transcript.segments {
                consider(segment.text, anchor: "video:\(videoID)#t=\(PackageTools.seconds(segment.start))")
            }
        }
        guard !scored.isEmpty else {
            return ToolOutcome("Nothing in this package mentions \(terms.joined(separator: " ")).")
        }
        // Stable: equal scores keep document order, so the same query gives the
        // same answer and the prompt cache sees the same bytes.
        let best = scored.enumerated()
            .sorted { $0.element.score != $1.element.score ? $0.element.score > $1.element.score
                                                            : $0.offset < $1.offset }
            .prefix(PackageTools.searchMaxResults)
            .map { $0.element.line }
        return ToolOutcome(best.joined(separator: "\n"))
    }

    /// A document's sections: the heading's text with its chips stripped, the slug
    /// the hub routes to, and the lines up to the next heading of the same or a
    /// higher level. Front matter is skipped.
    static func sections(of markdown: String) -> [(title: String, slug: String, level: Int, body: String)] {
        var lines = markdown.components(separatedBy: "\n")
        if lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") {
            lines = Array(lines[(close + 1)...])
        }
        var out: [(title: String, slug: String, level: Int, body: String)] = []
        var current: (title: String, slug: String, level: Int, body: [String])? = nil
        var inFence = false
        for line in lines {
            if line.hasPrefix("```") { inFence.toggle() }
            let level = inFence ? 0 : line.prefix(while: { $0 == "#" }).count
            if level > 0, level <= 6, line.dropFirst(level).hasPrefix(" ") {
                if let section = current {
                    out.append((section.title, section.slug, section.level,
                                section.body.joined(separator: "\n")))
                }
                let heading = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                let title = MarkdownLite.splitHeadingChips(heading).0
                current = (title, ProjectionSupport.slugify(title), level, [])
            } else {
                current?.body.append(line)
            }
        }
        if let section = current {
            out.append((section.title, section.slug, section.level, section.body.joined(separator: "\n")))
        }
        return out
    }

    private func docSection(_ input: [String: JSONValue]) -> ToolOutcome {
        let id = input["docId"]?.stringValue ?? ""
        let slug = input["slug"]?.stringValue ?? ""
        guard !id.isEmpty, !id.contains("/"), let text = try? store.readString("docs/\(id).md") else {
            let ids = store.listing("docs").filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) }
            return .error("There is no document \(id). Documents: \(ids.joined(separator: ", ")).")
        }
        let all = PackageTools.sections(of: text)
        guard let index = all.firstIndex(where: { $0.slug == slug }) else {
            return .error("doc:\(id) has no section \(slug). Sections: "
                          + all.map { $0.slug }.joined(separator: ", ") + ".")
        }
        let section = all[index]
        var body = section.body
        // Subsections belong to their section.
        for next in all[(index + 1)...] {
            guard next.level > section.level else { break }
            body += "\n" + String(repeating: "#", count: next.level) + " " + next.title + "\n" + next.body
        }
        let result = ToolOutcome.truncated("doc:\(id)#\(slug)\n# \(section.title)\n"
                                           + body.trimmingCharacters(in: .whitespacesAndNewlines),
                                           maxLines: PackageTools.readFileMaxLines)
        return result
    }

    private func transcriptRange(_ input: [String: JSONValue]) -> ToolOutcome {
        let id = input["videoId"]?.stringValue ?? ""
        guard !id.isEmpty, !id.contains("/"),
              let transcript = try? store.readJSON(TranscriptDoc.self,
                                                   from: "videos/\(id)/\(TranscriptDoc.fileName)") else {
            return .error("There is no video \(id). Videos: \(store.listing("videos").joined(separator: ", ")).")
        }
        let from = input["fromT"]?.numberValue ?? 0
        let to = input["toT"]?.numberValue ?? transcript.duration
        let picked = transcript.segments.filter { $0.end > min(from, to) && $0.start <= max(from, to) }
        guard !picked.isEmpty else {
            return ToolOutcome("No narration between \(PlaybackAgent.timecode(from)) and "
                               + "\(PlaybackAgent.timecode(to)); the video is "
                               + "\(PlaybackAgent.timecode(transcript.duration)) long.")
        }
        let lines = picked.prefix(80).map {
            "[\(PlaybackAgent.timecode($0.start))] \($0.text) [[video:\(id)#t=\(PackageTools.seconds($0.start))]]"
        }
        var out = lines.joined(separator: "\n")
        if picked.count > 80 { out += "\n… \(picked.count - 80) more sentences: ask for a narrower range." }
        return ToolOutcome(out)
    }

    private func diagram(_ input: [String: JSONValue]) -> ToolOutcome {
        let id = input["diagramId"]?.stringValue ?? ""
        guard !id.isEmpty, !id.contains("/"), let source = try? store.readString("diagrams/\(id).mmd") else {
            let ids = store.listing("diagrams").filter { $0.hasSuffix(".mmd") }.map { String($0.dropLast(4)) }
            return .error("There is no diagram \(id). Diagrams: \(ids.joined(separator: ", ")).")
        }
        var out = "diagram:\(id)\n```mermaid\n\(source.trimmingCharacters(in: .newlines))\n```"
        if let links = try? store.readString("diagrams/\(id).links.json") {
            out += "\nNode anchors (diagram:\(id)#<node> cites a node):\n" + links
        }
        return .truncated(out, maxLines: PackageTools.readFileMaxLines)
    }

    private func readFact(_ input: [String: JSONValue]) -> ToolOutcome {
        let id = input["id"]?.stringValue ?? ""
        guard let fact = facts[id] else {
            return .error("There is no fact \(id). Fact ids look like F-map-src-002; search_package "
                          + "finds the documents that cite them.")
        }
        return ToolOutcome(PackageTools.describe(fact))
    }

    /// A fact as the agent reads it: what is claimed, how sure the research is, and
    /// what was actually read to support it.
    static func describe(_ fact: PacketFact) -> String {
        var out = "fact:\(fact.id) (\(fact.kind), \(fact.status)"
        if fact.status == "refuted" { out += " — the verifier rejected this claim; do not repeat it as true" }
        out += ")\n\(fact.claim)\n"
        for evidence in fact.evidence {
            out += "evidence [[\(evidence.anchor)]]"
            if let note = evidence.note, !note.isEmpty { out += " — \(note)" }
            out += "\n"
            if let excerpt = evidence.excerpt, !excerpt.isEmpty {
                out += excerpt.split(separator: "\n", omittingEmptySubsequences: false)
                    .prefix(20).map { "    " + $0 }.joined(separator: "\n") + "\n"
            }
        }
        return out.trimmingCharacters(in: .newlines)
    }

    // MARK: Review

    private func flagContradiction(_ input: [String: JSONValue]) async -> ToolOutcome {
        let videoID = input["videoId"]?.stringValue ?? ""
        let anchor = (input["anchor"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces)
        let claim = input["claim"]?.stringValue ?? ""
        let reason = input["reason"]?.stringValue ?? ""
        let t = max(0, input["t"]?.numberValue ?? 0)
        guard !claim.isEmpty, !reason.isEmpty else {
            return .error("claim and reason are both required: what the narration says, and what the code shows.")
        }
        // A flag the author cannot open is a flag the author cannot act on.
        if case .failure(let failure) = router.resolve(anchor) {
            return .error("The anchor \(anchor) does not resolve (\(failure.reason)). Cite the lines "
                          + "you read, as read_file's header names them.")
        }
        let transcript = try? store.readJSON(TranscriptDoc.self,
                                             from: "videos/\(videoID)/\(TranscriptDoc.fileName)")
        guard let transcript else {
            return .error("There is no video \(videoID).")
        }
        let flag = ContradictionFlag(videoId: videoID, t: t, segmentId: transcript.segment(at: t)?.id,
                                     anchor: anchor, claim: claim, reason: reason)
        do {
            let recorded = try await review.append(flag)
            return ToolOutcome("Flag \(recorded.id) recorded in review/flags.json for the package author. "
                               + "Tell the viewer plainly what the narration gets wrong.",
                               outputs: [ReviewFiles.flagsPath])
        } catch {
            return .error("The flag could not be saved: \(error.localizedDescription). Tell the viewer anyway.")
        }
    }

    private func seekVideo(_ input: [String: JSONValue]) -> ToolOutcome {
        let t = input["t"]?.numberValue ?? -1
        guard t >= 0 else { return .error("t must be a time in seconds, 0 or more.") }
        return ToolOutcome("The viewer now sees a Jump to \(PlaybackAgent.timecode(t)) button. The video "
                           + "has not moved; do not say that it has.")
    }

    // MARK: Helpers

    static func int(_ value: JSONValue?) -> Int? {
        guard let number = value?.numberValue, number.isFinite else { return nil }
        return Int(number)
    }

    /// `12.5` and `12` both read as written, the way `video:` anchors spell seconds.
    static func seconds(_ t: Double) -> String {
        let rounded = (t * 10).rounded() / 10
        return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
    }

    /// Markdown bullets and citations stripped, for a search snippet.
    static func plain(_ text: String) -> String {
        var out = text.trimmingCharacters(in: .whitespaces)
        while out.hasPrefix("-") || out.hasPrefix("*") || out.hasPrefix("#") {
            out = String(out.dropFirst()).trimmingCharacters(in: .whitespaces)
        }
        return out
    }
}
