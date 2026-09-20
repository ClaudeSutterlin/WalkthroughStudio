// PacketValidator.swift — "Onboard to a Codebase", milestone M2 (Research Packet contract).
//
// The Swift twin of the reference validator
// `.claude/skills/onboarding-research/scripts/validate_packet.py`
// (docs/onboarding/PACKET.md section 7, ARCHITECTURE.md 15.2). It applies the
// cross-file rules the JSON Schemas cannot express, in the same order and with
// the same "where" strings and message wording, so a producer that fixed every
// line the Python tool printed sees the same report on import:
//
//   0. the enum, range, length and required-key constraints of the schemas
//      themselves (`checkSchemaConstraints`), because the app is the only gate
//      for a packet that never ran through validate_packet.py
//   1. required files and headSHA agreement between files
//   2. every anchor parses (Anchor.parse) and resolves: code: anchors are
//      pinned to a prefix of repo.headSHA and, when a repository is given, the
//      file exists at that sha with the line range inside it (directories via
//      ls-tree, commits via rev-parse); cmd: anchors need commands/<unit>/<n>.txt;
//      fact: and trace: anchors need their targets; video:/doc:/diagram:
//      anchors outside drafts/ are only a warning
//   3. facts: evidence non-empty, refuted needs a refuting verdict with
//      evidence, verified without a confirming verdict warns, dataEntity facts
//      should carry attributes.pii / rows / retention
//   4. paths and traces: every ranked path (traced != false) has a trace, hops
//      are numbered 1..n, the ten concerns are present, present/absent carry
//      evidence, factIds are known
//   5. coverage: every inventory directory listed, unknown directories are
//      errors, levels agree with facts and filesRead
//   6. completeness gates: zero facts, a "SUMMARY PENDING" summary or nothing
//      at level mapped are errors (a survey skeleton is not a packet)
//   7. packet.json counts versus computed counts (warnings)
//   8. [[anchor]] citations in drafts/*.md
//
// Known wording exceptions to "the same message wording" above, both
// deliberate: the no-repository warning says "no repository given" where the
// Python tool says "no --repo given" (the app has no such flag), and a
// malformed anchor carries `Anchor.parse`'s own reason inside
// "malformed anchor (<reason>)" rather than the Python Anchor class's.
// Schema rules that are still NOT enforced here are listed on
// `checkSchemaConstraints`; the chief one is `additionalProperties: false`,
// since the models ignore unknown keys by design.
//
// Anchor resolution goes through `PacketAnchorResolver`, which caches every
// git answer per (sha, path) so a 200-fact packet costs a few dozen git
// processes, not hundreds. The models come from PacketModels.swift; this file
// reads their fields through the small `PacketFields` helpers so an optional
// versus non-optional field in the models compiles either way.

import Foundation

// MARK: - Report

/// One validator finding. Encodes as {"where": ..., "message": ...} like the
/// Python report (`where` is a Swift keyword, hence the trailing underscore).
struct PacketIssue: Codable, Equatable {
    let where_: String
    let message: String

    init(_ where_: String, _ message: String) {
        self.where_ = where_
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case where_ = "where"
        case message
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        where_ = try c.decodeIfPresent(String.self, forKey: .where_) ?? ""
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(where_, forKey: .where_)
        try c.encode(message, forKey: .message)
    }
}

/// The report `validate_packet.py --json` writes and the import sheet shows:
/// errors reject the packet, warnings are listed, stats feed the hub.
struct PacketValidationReport: Codable {
    var errors: [PacketIssue] = []
    var warnings: [PacketIssue] = []
    /// Flattened counters: "facts", "traces", "paths", "anchors.code",
    /// "coverage.mapped", "status.verified", "kind.risk", ...
    var stats: [String: Int] = [:]

    var ok: Bool { errors.isEmpty }

    init() {}

    private enum CodingKeys: String, CodingKey { case errors, warnings, stats, ok }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        errors = try c.decodeIfPresent([PacketIssue].self, forKey: .errors) ?? []
        warnings = try c.decodeIfPresent([PacketIssue].self, forKey: .warnings) ?? []
        stats = try c.decodeIfPresent([String: Int].self, forKey: .stats) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(errors, forKey: .errors)
        try c.encode(warnings, forKey: .warnings)
        try c.encode(stats, forKey: .stats)
        try c.encode(ok, forKey: .ok)
    }

    mutating func error(_ where_: String, _ message: String) {
        errors.append(PacketIssue(where_, message))
    }

    mutating func warn(_ where_: String, _ message: String) {
        warnings.append(PacketIssue(where_, message))
    }

    /// "PACKET OK: 0 errors, 3 warnings" / "PACKET INVALID: 2 errors, 1 warnings"
    /// (the Python wording, kept verbatim so scripts can grep either tool).
    var summaryLine: String {
        "\(ok ? "PACKET OK" : "PACKET INVALID"): \(errors.count) errors, \(warnings.count) warnings"
    }

    /// `stats   {"anchors.code": 12, "facts": 40}` with sorted keys, like
    /// `json.dumps(stats, sort_keys=True)`.
    var statsLine: String {
        let body = stats.keys.sorted().map { key in
            "\"\(key)\": \(stats[key] ?? 0)"
        }.joined(separator: ", ")
        return "stats   {\(body)}"
    }

    /// The console form `--validate-packet` prints: every error, every
    /// warning, the stats line, then the summary line.
    var consoleLines: [String] {
        var lines: [String] = []
        for issue in errors { lines.append("ERROR   \(issue.where_): \(issue.message)") }
        for issue in warnings { lines.append("warning \(issue.where_): \(issue.message)") }
        lines.append(statsLine)
        lines.append(summaryLine)
        return lines
    }
}

// MARK: - Field helpers

/// Small accessors that accept a field whether the packet models declare it
/// optional or not (a `String` promotes to `String?`, an `[T]` to `[T]?`),
/// so the validator, the importer and the probes read the models the same way.
enum PacketFields {
    static func text(_ value: String?) -> String { value ?? "" }

    static func list<T>(_ value: [T]?) -> [T] { value ?? [] }

    static func count(_ value: Int?) -> Int { value ?? 0 }

    static func flag(_ value: Bool?, default fallback: Bool) -> Bool { value ?? fallback }

    /// The wire string of an anchor field, whether the model keeps it as the
    /// raw `String` or as an already parsed `Anchor`. Empty for nil.
    static func anchorText(_ value: Any?) -> String {
        if let anchor = value as? Anchor { return anchor.string }
        if let text = value as? String { return text }
        return ""
    }

    /// A date field kept either as `Date` or as an ISO 8601 `String`.
    static func date(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let text = value as? String { return OnboardingJSON.date(fromISO8601: text) }
        return nil
    }

    static func isFullSHA(_ sha: String) -> Bool {
        guard sha.count == 40 else { return false }
        for scalar in sha.unicodeScalars {
            let isDigit = scalar.value >= 48 && scalar.value <= 57
            let isLowerHex = scalar.value >= 97 && scalar.value <= 102
            if !(isDigit || isLowerHex) { return false }
        }
        return true
    }
}

// MARK: - Anchor resolution against the repository

/// git access at the packet's pinned sha, memoized per (sha, path) and per
/// commit so repeated anchors (a hotspot file cited by twenty facts) cost one
/// process each. Used from one validation run at a time; not thread-safe.
final class PacketAnchorResolver {
    let repo: URL
    let head: String
    private let git: GitRunner

    private var lineCounts: [String: Int] = [:]
    private var missingFiles: Set<String> = []
    private var directories: [String: Bool] = [:]
    private var commits: [String: Bool] = [:]
    /// Number of git processes spawned so far (the probe watches this stay small).
    private(set) var gitCalls = 0

    init(repo: URL, head: String, git: GitRunner) {
        self.repo = repo
        self.head = head
        self.git = git
    }

    /// Lines in `path` at `head`, or nil when the file is not in that tree.
    func lineCount(path: String) async -> Int? {
        let key = head + ":" + path
        if let known = lineCounts[key] { return known }
        if missingFiles.contains(key) { return nil }
        gitCalls += 1
        if let count = try? await git.lineCount(sha: head, path: path, repo: repo) {
            lineCounts[key] = count
            return count
        }
        missingFiles.insert(key)
        return nil
    }

    /// True when `path` is a directory (a tree) at `head`. Directory-only, like
    /// the reference validator's `git ls-tree -d`: a file path with a trailing
    /// slash must NOT resolve, or the app would import a packet Python rejects.
    func directoryExists(path: String) async -> Bool {
        var trimmed = path
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        let key = head + ":" + trimmed + "/"
        if let known = directories[key] { return known }
        gitCalls += 1
        let exists = (try? await git.treeExists(sha: head, path: trimmed, repo: repo)) ?? false
        directories[key] = exists
        return exists
    }

    /// True when `sha` (full or abbreviated) names a commit in the repository.
    func hasCommit(_ sha: String) async -> Bool {
        if let known = commits[sha] { return known }
        gitCalls += 1
        let exists = (try? await git.revParse(sha, in: repo)) != nil
        commits[sha] = exists
        return exists
    }
}

// MARK: - Validator

struct PacketValidator {
    let packet: ResearchPacket
    /// A checkout containing `packet.manifest.repo.headSHA`; nil parses
    /// anchors without resolving code: and commit: anchors (reported as a warning).
    let repo: URL?
    let git: GitRunner

    // The schema's own lists live on the models (in schema order, which the
    // enum messages need); these are aliases so they cannot drift apart.

    /// The ten concern keys every trace carries (PACKET.md section 5).
    static let concernKeys: [String] = PacketTrace.concernKeys

    static let coverageLevels: [String] = PacketCoverage.levels

    static let factKinds: Set<String> = Set(PacketFact.kinds)

    static let factStatuses: Set<String> = Set(PacketFact.statuses)

    static let scopes: Set<String> = Set(PacketManifest.scopes)

    init(packet: ResearchPacket, repo: URL?, git: GitRunner) {
        self.packet = packet
        self.repo = repo
        self.git = git
    }

    func validate() async throws -> PacketValidationReport {
        let run = PacketValidationRun(packet: packet, repo: repo, git: git)
        return try await run.run()
    }
}

/// One pass over a packet. A class so the anchor checker can update the
/// report and counters from every section without threading state through.
private final class PacketValidationRun {
    private let packet: ResearchPacket
    private let repo: URL?
    private let git: GitRunner
    private let head: String
    private var resolver: PacketAnchorResolver?

    private var report = PacketValidationReport()
    private var factIDs: Set<String> = []
    private var anchorsByKind: [String: Int] = [:]
    private var unresolved = 0
    private var kindCounts: [String: Int] = [:]
    private var statusCounts: [String: Int] = [:]
    private var verifiers: Set<String> = []
    /// Top-level directory ("src/" or ".") -> (facts citing code under it, of which verified).
    private var factsByDir: [String: (facts: Int, verified: Int)] = [:]

    init(packet: ResearchPacket, repo: URL?, git: GitRunner) {
        self.packet = packet
        self.repo = repo
        self.git = git
        self.head = packet.manifest.repo.headSHA.lowercased()
    }

    func run() async throws -> PacketValidationReport {
        await checkManifestAndHeads()
        checkSchemaConstraints()
        collectFactIDs()
        await checkFacts()
        await checkInventoryHistoryDependencies()
        await checkDecisionsAndGlossary()
        let pathIDs = await checkPathsAndTraces()
        let coverageByLevel = checkCoverage(pathIDs: pathIDs)
        checkCounts()
        await checkDrafts()
        checkCompleteness()
        fillStats(pathIDs: pathIDs, coverageByLevel: coverageByLevel)
        return report
    }

    // MARK: 1. Files and headSHA

    private func checkManifestAndHeads() async {
        let manifest = packet.manifest
        if manifest.version != 1 {
            report.error("packet.json:version", "unsupported packet version \(manifest.version); this app reads version 1")
        }
        if !PacketValidator.scopes.contains(manifest.scope) {
            report.error("packet.json:scope", "scope must be smoke, preview or complete (got \"\(manifest.scope)\")")
        }
        if manifest.summary.count < 40 {
            report.error("packet.json:summary", "summary must be at least 40 characters (one paragraph a stranger could read first)")
        }

        if let repo {
            if !PacketFields.isFullSHA(head) {
                report.error("packet.json:repo/headSHA", "not a 40-hex sha")
            } else {
                let candidate = PacketAnchorResolver(repo: repo, head: head, git: git)
                if await candidate.hasCommit(head) {
                    resolver = candidate
                } else {
                    report.error("packet.json:repo/headSHA", "commit \(head) not found in \(repo.path)")
                }
            }
        } else {
            if !PacketFields.isFullSHA(head) {
                report.error("packet.json:repo/headSHA", "not a 40-hex sha")
            }
            // Deliberately NOT the Python wording ("no --repo given: ..."):
            // the app has no --repo flag to name. Same `where`, same meaning.
            report.warn("validator", "no repository given: code: and commit: anchors are parsed but not resolved")
        }

        checkHead(packet.inventory.headSHA, file: "inventory")
        checkHead(packet.history.headSHA, file: "history")
        checkHead(packet.paths.headSHA, file: "paths")
        checkHead(packet.coverage.headSHA, file: "coverage")
        if let dependencies = packet.dependencies {
            checkHead(dependencies.headSHA, file: "dependencies")
        } else {
            report.warn("dependencies.json", "optional file absent")
        }
        if let decisions = packet.decisions {
            checkHead(decisions.headSHA, file: "decisions")
        } else {
            report.warn("decisions.json", "optional file absent")
        }
        if let glossary = packet.glossary {
            checkHead(glossary.headSHA, file: "glossary")
        } else {
            report.warn("glossary.json", "optional file absent")
        }
    }

    /// A file that names a headSHA must name the manifest's.
    private func checkHead(_ sha: String?, file: String) {
        let text = PacketFields.text(sha).lowercased()
        if !text.isEmpty, text != head {
            report.error("\(file).json:headSHA", "does not match packet.json repo.headSHA")
        }
    }

    // MARK: 1b. Schema constraints

    /// The enum, range, length and required-key constraints the JSON Schemas
    /// state, checked here because the app is the only gate for a packet that
    /// never went through `validate_packet.py` (PACKET.md section 7, rule 1).
    /// Locations and wording follow what `jsonschema` produces through the
    /// Python tool's `validate_schema`, i.e. `<file>:<path/with/slashes>` and
    /// "'x' is not one of ['a', 'b']", so the two reports line up line for line.
    ///
    /// Not enforced here (see the file header): `additionalProperties: false`
    /// — the models ignore unknown keys on purpose, so an extra key imports
    /// and only the Python tool objects; the anchor `pattern`s, which
    /// `Anchor.parse` covers more strictly; `required` keys other than
    /// messageKeywords, whose absence the models' non-optional fields already
    /// turn into a decode failure; and the numeric `minimum: 0` counters.
    private func checkSchemaConstraints() {
        // facts.jsonl — one object per line, numbered like the file.
        for (index, fact) in packet.facts.enumerated() {
            let at = "facts.jsonl:\(packet.factLine(at: index))"
            if !PacketValidationRun.matchesIDPattern(fact.id) {
                report.error("\(at):id", PacketValidationRun.patternMessage(fact.id, PacketValidationRun.idPattern))
            }
            if !PacketFact.kinds.contains(fact.kind) {
                report.error("\(at):kind", PacketValidationRun.enumMessage(fact.kind, PacketFact.kinds))
            }
            if !PacketFact.statuses.contains(fact.status) {
                report.error("\(at):status", PacketValidationRun.enumMessage(fact.status, PacketFact.statuses))
            }
            if fact.claim.count < 10 {
                report.error("\(at):claim", PacketValidationRun.lengthMessage(fact.claim, tooLong: false))
            } else if fact.claim.count > 600 {
                report.error("\(at):claim", PacketValidationRun.lengthMessage(fact.claim, tooLong: true))
            }
            if fact.confidence < 0 {
                report.error("\(at):confidence", "\(fact.confidence) is less than the minimum of 0")
            } else if fact.confidence > 1 {
                report.error("\(at):confidence", "\(fact.confidence) is greater than the maximum of 1")
            }
            for (j, verdict) in fact.verdicts.enumerated() where !PacketFact.Verdict.verdicts.contains(verdict.verdict) {
                report.error("\(at):verdicts/\(j)/verdict",
                             PacketValidationRun.enumMessage(verdict.verdict, PacketFact.Verdict.verdicts))
            }
        }

        // inventory.json
        for (j, entry) in packet.inventory.entryPoints.enumerated() {
            if !PacketInventory.EntryPoint.kinds.contains(entry.kind) {
                report.error("inventory.json:entryPoints/\(j)/kind",
                             PacketValidationRun.enumMessage(entry.kind, PacketInventory.EntryPoint.kinds))
            }
        }

        // history.json — the five keyword buckets every packet must report.
        for key in PacketHistory.requiredMessageKeywords where packet.history.messageKeywords[key] == nil {
            report.error("history.json:messageKeywords", "'\(key)' is a required property")
        }

        // dependencies.json
        if let dependencies = packet.dependencies {
            for (j, dependency) in dependencies.dependencies.enumerated() {
                if !PacketDependencies.Dependency.ecosystems.contains(dependency.ecosystem) {
                    report.error("dependencies.json:dependencies/\(j)/ecosystem",
                                 PacketValidationRun.enumMessage(dependency.ecosystem,
                                                                 PacketDependencies.Dependency.ecosystems))
                }
                if case .list(let cves) = dependency.cves {
                    for (k, cve) in cves.enumerated() where !PacketCVE.severities.contains(cve.severity) {
                        report.error("dependencies.json:dependencies/\(j)/cves/\(k)/severity",
                                     PacketValidationRun.enumMessage(cve.severity, PacketCVE.severities))
                    }
                }
            }
        }

        // coverage.json
        for (j, directory) in packet.coverage.directories.enumerated() {
            if !PacketCoverage.levels.contains(directory.level) {
                report.error("coverage.json:directories/\(j)/level",
                             PacketValidationRun.enumMessage(directory.level, PacketCoverage.levels))
            }
        }
        for (j, check) in packet.coverage.checks.enumerated() {
            if !PacketCoverage.checkNames.contains(check.check) {
                report.error("coverage.json:checks/\(j)/check",
                             PacketValidationRun.enumMessage(check.check, PacketCoverage.checkNames))
            }
            if !PacketCoverage.checkStatuses.contains(check.status) {
                report.error("coverage.json:checks/\(j)/status",
                             PacketValidationRun.enumMessage(check.status, PacketCoverage.checkStatuses))
            }
        }

        // traces/*.json
        for traceID in packet.traces.keys.sorted() {
            guard let trace = packet.traces[traceID] else { continue }
            if trace.hops.isEmpty {
                report.error("traces/\(traceID).json:hops", "[] is too short")
            }
            for key in PacketTrace.concernKeys {
                guard let concern = trace.concerns[key] else { continue }  // missing: reported as a cross-file rule
                if !PacketConcern.statuses.contains(concern.status) {
                    report.error("traces/\(traceID).json:concerns/\(key)/status",
                                 PacketValidationRun.enumMessage(concern.status, PacketConcern.statuses))
                }
            }
        }
    }

    /// The id pattern shared by fact, path, decision and term ids.
    private static let idPattern = "^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$"

    /// `^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$` without a regex engine.
    private static func matchesIDPattern(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 128 else { return false }
        for (offset, character) in text.enumerated() {
            let isAlphanumeric = character.isASCII && (character.isLetter || character.isNumber)
            if offset == 0 {
                if !isAlphanumeric { return false }
            } else if !(isAlphanumeric || character == "_" || character == "." || character == ":" || character == "-") {
                return false
            }
        }
        return true
    }

    /// "'x' is not one of ['a', 'b']" — jsonschema's wording, so a producer
    /// can grep either tool's report for the same line.
    private static func enumMessage(_ value: String, _ allowed: [String]) -> String {
        let list = allowed.map { "'\($0)'" }.joined(separator: ", ")
        return truncate("'\(value)' is not one of [\(list)]")
    }

    private static func patternMessage(_ value: String, _ pattern: String) -> String {
        truncate("'\(value)' does not match '\(pattern)'")
    }

    private static func lengthMessage(_ value: String, tooLong: Bool) -> String {
        truncate("'\(value)' is too \(tooLong ? "long" : "short")")
    }

    /// `validate_schema` writes `err.message[:300]`; do the same so a long
    /// claim does not flood the report.
    private static func truncate(_ message: String) -> String {
        message.count <= 300 ? message : String(message.prefix(300))
    }

    // MARK: 2. Anchors

    /// Parses and resolves one anchor. `raw` is the wire string (an already
    /// parsed `Anchor` is accepted too). Returns the anchor when it parsed,
    /// even if resolution failed, so callers can still bucket it.
    @discardableResult
    private func checkAnchor(_ raw: Any?, at where_: String, allow: Set<String>? = nil) async -> Anchor? {
        let anchor: Anchor
        if let parsed = raw as? Anchor {
            anchor = parsed
        } else if let text = raw as? String {
            do {
                anchor = try Anchor.parse(text)
            } catch let error as StudioError {
                report.error(where_, "\(PacketValidationRun.parseProblem(error.message, raw: text)): \(text)")
                return nil
            } catch {
                report.error(where_, "malformed anchor: \(text)")
                return nil
            }
        } else {
            report.error(where_, "anchor is not a string")
            return nil
        }

        let text = anchor.string
        if let allow, !allow.contains(anchor.kind) {
            report.error(where_, "anchor kind \(anchor.kind) not allowed here: \(text)")
            return nil
        }
        anchorsByKind[anchor.kind, default: 0] += 1

        switch anchor {
        case .code(let path, let sha7, let lines):
            guard let sha7 else {
                report.error(where_, "code anchor without @sha7 (packets must pin every code anchor): \(text)")
                return anchor
            }
            // `Anchor.parse` accepts A-F in a sha, the reference validator's
            // CODE_RE does not: there an upper-case sha7 never reads as a
            // pinned anchor at all and the anchor falls through to the
            // unpinned pattern. Same verdict, same wording, here.
            if sha7 != sha7.lowercased() {
                report.error(where_, "code anchor without @sha7 (packets must pin every code anchor): \(text)")
                return anchor
            }
            if !head.isEmpty, !head.hasPrefix(sha7) {
                report.error(where_, "sha7 \(sha7) is not a prefix of headSHA: \(text)")
                return anchor
            }
            guard let resolver else {
                unresolved += 1
                return anchor
            }
            if anchor.isDirectory {
                if !(await resolver.directoryExists(path: path)) {
                    report.error(where_, "directory not found at headSHA: \(text)")
                }
            } else {
                guard let count = await resolver.lineCount(path: path) else {
                    report.error(where_, "file not found at headSHA: \(text)")
                    return anchor
                }
                if let lines, lines.lowerBound < 1 || lines.upperBound > count {
                    report.error(where_, "line range L\(lines.lowerBound)-L\(lines.upperBound) outside file of \(count) lines: \(text)")
                }
            }
        case .commit(let sha):
            guard let resolver else {
                unresolved += 1
                return anchor
            }
            if !(await resolver.hasCommit(sha)) {
                report.error(where_, "commit not found: \(text)")
            }
        case .fact(let id):
            if !factIDs.contains(id) {
                report.error(where_, "unknown fact id: \(text)")
            }
        case .trace(let id, let hop):
            guard let trace = packet.traces[id] else {
                report.error(where_, "unknown trace: \(text)")
                return anchor
            }
            if hop > PacketFields.list(trace.hops).count {
                report.error(where_, "hop beyond trace length: \(text)")
            }
        case .cmd(let unit, let n):
            let file = packet.commandOutputURL(unit: unit, n: n)
            if !FileManager.default.fileExists(atPath: file.path) {
                report.error(where_, "command output file missing for \(text) (expected commands/<unit>/<n>.txt)")
            }
        case .video, .doc, .diagram:
            report.warn(where_, "\(anchor.kind) anchor in a packet is only meaningful inside drafts/: \(text)")
        case .issue, .url:
            break
        }
        return anchor
    }

    /// "anchor 'x': empty path" -> "malformed anchor (empty path)"; other
    /// messages are kept whole.
    private static func parseProblem(_ message: String, raw: String) -> String {
        let prefix = "anchor '\(raw)': "
        if message.hasPrefix(prefix) {
            return "malformed anchor (\(message.dropFirst(prefix.count)))"
        }
        return "malformed anchor (\(message))"
    }

    /// "src/repo/orders_repo.py" -> "src/"; "README.md" -> "." (the inventory's
    /// spelling of top-level directories and root files).
    private static func topLevelDirectory(of path: String) -> String {
        guard let slash = path.firstIndex(of: "/") else { return "." }
        return String(path[path.startIndex..<slash]) + "/"
    }

    // MARK: 3. Facts

    private func collectFactIDs() {
        for (index, fact) in packet.facts.enumerated() {
            // The REAL facts.jsonl line, not the index among the non-blank
            // lines: a blank line would otherwise shift every message below it
            // out of step with the reference validator's numbering.
            let line = packet.factLine(at: index)
            if factIDs.contains(fact.id) {
                report.error("facts.jsonl:\(line)", "duplicate fact id \(fact.id)")
            } else {
                factIDs.insert(fact.id)
            }
        }
    }

    private func checkFacts() async {
        for (index, fact) in packet.facts.enumerated() {
            let line = packet.factLine(at: index)
            let where_ = "facts.jsonl:\(line)(\(fact.id))"
            kindCounts[fact.kind, default: 0] += 1
            statusCounts[fact.status, default: 0] += 1
            // `kind` and `status` are enum constraints; they are reported by
            // `checkSchemaConstraints` at the schema's own location
            // (facts.jsonl:<n>:kind), not here.

            let evidence = PacketFields.list(fact.evidence)
            if evidence.isEmpty {
                report.error(where_, "fact has no evidence")
            }
            for (j, record) in evidence.enumerated() {
                let anchor = await checkAnchor(record.anchor, at: "\(where_):evidence[\(j)]")
                if let anchor, case .code(let path, _, _) = anchor {
                    let top = PacketValidationRun.topLevelDirectory(of: path)
                    var bucket = factsByDir[top] ?? (facts: 0, verified: 0)
                    bucket.facts += 1
                    if fact.status == "verified" { bucket.verified += 1 }
                    factsByDir[top] = bucket
                }
            }

            let verdicts = PacketFields.list(fact.verdicts)
            for verdict in verdicts {
                verifiers.insert(verdict.verifier)
                for (j, anchor) in PacketFields.list(verdict.evidence).enumerated() {
                    await checkAnchor(anchor, at: "\(where_):verdict[\(verdict.verifier)].evidence[\(j)]")
                }
            }

            switch fact.status {
            case "refuted":
                let refuting = verdicts.contains { verdict in
                    verdict.verdict == "refuted" && !PacketFields.list(verdict.evidence).isEmpty
                }
                if !refuting {
                    report.error(where_, "refuted fact needs a refuting verdict that cites counter-evidence")
                }
            case "verified":
                if !verdicts.contains(where: { $0.verdict == "confirmed" }) {
                    report.warn(where_, "verified fact has no confirming verdict")
                }
            case "proposed":
                if !verdicts.isEmpty {
                    report.warn(where_, "fact has verdicts but status is still proposed")
                }
            default:
                break
            }

            if fact.kind == "dataEntity" {
                // A key written as JSON null counts as present ("unknown" in
                // another spelling), exactly like the Python `k not in attrs`.
                for key in PacketFact.dataEntityAttributeKeys where fact.attributes[key] == nil {
                    report.warn(where_, "dataEntity fact lacks attributes.\(key) (use \"unknown\" rather than omitting)")
                }
            }
        }
    }

    // MARK: Inventory, history, dependencies

    private func checkInventoryHistoryDependencies() async {
        let inventory = packet.inventory
        let codeOnly: Set<String> = ["code"]
        for (j, anchor) in PacketFields.list(inventory.manifests).enumerated() {
            await checkAnchor(anchor, at: "inventory.json:manifests[\(j)]", allow: codeOnly)
        }
        for (j, anchor) in PacketFields.list(inventory.ci).enumerated() {
            await checkAnchor(anchor, at: "inventory.json:ci[\(j)]", allow: codeOnly)
        }
        for (j, anchor) in PacketFields.list(inventory.infra).enumerated() {
            await checkAnchor(anchor, at: "inventory.json:infra[\(j)]", allow: codeOnly)
        }
        for (j, anchor) in PacketFields.list(inventory.docs).enumerated() {
            await checkAnchor(anchor, at: "inventory.json:docs[\(j)]", allow: codeOnly)
        }
        for (j, entry) in PacketFields.list(inventory.entryPoints).enumerated() {
            await checkAnchor(entry.anchor, at: "inventory.json:entryPoints[\(j)]", allow: codeOnly)
        }

        let history = packet.history
        for (j, pair) in PacketFields.list(history.parallel).enumerated() {
            await checkAnchor(pair.a, at: "history.json:parallel[\(j)].a", allow: codeOnly)
            await checkAnchor(pair.b, at: "history.json:parallel[\(j)].b", allow: codeOnly)
        }
        for (j, commit) in PacketFields.list(history.notableCommits).enumerated() {
            await checkAnchor(commit.anchor, at: "history.json:notableCommits[\(j)]", allow: ["commit"])
        }

        guard let dependencies = packet.dependencies else { return }
        for (j, dependency) in PacketFields.list(dependencies.dependencies).enumerated() {
            await checkAnchor(dependency.manifest, at: "dependencies.json:[\(j)].manifest", allow: codeOnly)
            let evidence = PacketFields.list(dependency.evidence)
            for (k, anchor) in evidence.enumerated() {
                await checkAnchor(anchor, at: "dependencies.json:[\(j)].evidence[\(k)]")
            }
            if case .list(let cves) = dependency.cves, !cves.isEmpty {
                let evidenceHasURL = evidence.contains { PacketFields.anchorText($0).hasPrefix("url:") }
                let cveHasURL = cves.contains { !PacketFields.text($0.url).isEmpty }
                if !(evidenceHasURL || cveHasURL) {
                    report.warn("dependencies.json:[\(j)](\(dependency.name))",
                                "CVE ids listed without any url: evidence; treat as model memory until a source is cited")
                }
                for cve in cves {
                    let url = PacketFields.text(cve.url)
                    if !url.isEmpty, !url.hasPrefix("http") {
                        report.error("dependencies.json:[\(j)].cves", "cve url is not http(s): \(url)")
                    }
                }
            }
        }
    }

    // MARK: Decisions and glossary

    private func checkDecisionsAndGlossary() async {
        if let decisions = packet.decisions {
            for (j, decision) in PacketFields.list(decisions.decisions).enumerated() {
                for (k, anchor) in PacketFields.list(decision.evidence).enumerated() {
                    await checkAnchor(anchor, at: "decisions.json:[\(j)].evidence[\(k)]")
                }
                for factID in PacketFields.list(decision.factIds) where !factIDs.contains(factID) {
                    report.error("decisions.json:[\(j)]", "unknown factId \(factID)")
                }
            }
        }
        if let glossary = packet.glossary {
            for (j, term) in PacketFields.list(glossary.terms).enumerated() {
                let definedAt = PacketFields.anchorText(term.definedAt)
                if !definedAt.isEmpty {
                    await checkAnchor(definedAt, at: "glossary.json:[\(j)].definedAt", allow: ["code"])
                }
                for factID in PacketFields.list(term.factIds) where !factIDs.contains(factID) {
                    report.error("glossary.json:[\(j)]", "unknown factId \(factID)")
                }
            }
        }
    }

    // MARK: 4. Paths and traces

    /// Returns the ids ranked in paths.json.
    private func checkPathsAndTraces() async -> Set<String> {
        var pathIDs: Set<String> = []
        for (j, path) in PacketFields.list(packet.paths.paths).enumerated() {
            pathIDs.insert(path.id)
            await checkAnchor(path.entry, at: "paths.json:[\(j)].entry", allow: ["code"])
            for factID in PacketFields.list(path.factIds) where !factIDs.contains(factID) {
                report.error("paths.json:[\(j)]", "unknown factId \(factID)")
            }
            if PacketFields.flag(path.traced, default: true), packet.traces[path.id] == nil {
                report.error("paths.json:[\(j)]", "path \(path.id) has no traces/\(path.id).json")
            }
        }

        for traceID in packet.traces.keys.sorted() {
            guard let trace = packet.traces[traceID] else { continue }
            let where_ = "traces/\(traceID).json"
            let pathID = PacketFields.text(trace.pathId)
            if !pathID.isEmpty, pathID != traceID {
                report.error(where_, "pathId \(pathID) does not match file name")
            }
            if !pathIDs.contains(traceID) {
                report.warn(where_, "trace has no entry in paths.json")
            }
            await checkAnchor(trace.entry, at: "\(where_):entry", allow: ["code"])

            let hops = PacketFields.list(trace.hops)
            for (j, hop) in hops.enumerated() {
                if hop.n != j + 1 {
                    report.error("\(where_):hops[\(j)]", "hop numbers must be 1..n in order (got \(hop.n))")
                }
                await checkAnchor(hop.anchor, at: "\(where_):hops[\(j)].anchor", allow: ["code"])
                let callSite = PacketFields.anchorText(hop.callSite)
                if !callSite.isEmpty {
                    await checkAnchor(callSite, at: "\(where_):hops[\(j)].callSite", allow: ["code"])
                }
                for factID in PacketFields.list(hop.factIds) where !factIDs.contains(factID) {
                    report.error("\(where_):hops[\(j)]", "unknown factId \(factID)")
                }
            }

            for key in PacketValidator.concernKeys {
                guard let concern = trace.concerns[key] else {
                    report.error("\(where_):concerns", "missing concern \(key)")
                    continue
                }
                // An unknown status is a schema constraint, reported by
                // `checkSchemaConstraints` at concerns/<key>/status.
                let evidence = PacketFields.list(concern.evidence)
                if concern.status == "present" || concern.status == "absent", evidence.isEmpty {
                    report.error("\(where_):concerns.\(key)", "status \(concern.status) requires evidence anchors")
                }
                for (k, anchor) in evidence.enumerated() {
                    await checkAnchor(anchor, at: "\(where_):concerns.\(key).evidence[\(k)]")
                }
            }
            if PacketFields.list(trace.scaresMe).isEmpty {
                report.error("\(where_):scaresMe", "scaresMe must list at least one sentence")
            }
            for factID in PacketFields.list(trace.factIds) where !factIDs.contains(factID) {
                report.error(where_, "unknown factId \(factID)")
            }
        }
        return pathIDs
    }

    // MARK: 5. Coverage

    /// Returns the directory count per level.
    private func checkCoverage(pathIDs: Set<String>) -> [String: Int] {
        let inventoryDirs = Set(PacketFields.list(packet.inventory.topLevel).map { $0.path })
        var seen: Set<String> = []
        var byLevel: [String: Int] = [:]
        let researched: Set<String> = ["mapped", "verified", "traced"]

        for (j, directory) in PacketFields.list(packet.coverage.directories).enumerated() {
            let where_ = "coverage.json:directories[\(j)](\(directory.path))"
            seen.insert(directory.path)
            let level = directory.level
            byLevel[level, default: 0] += 1
            // An unknown level is a schema constraint, reported by
            // `checkSchemaConstraints` at coverage.json:directories/<j>/level.
            if !inventoryDirs.isEmpty, !inventoryDirs.contains(directory.path) {
                report.error(where_, "directory is not in inventory.topLevel")
            }
            let facts = PacketFields.count(directory.facts)
            let files = PacketFields.count(directory.files)
            let filesRead = PacketFields.count(directory.filesRead)
            if researched.contains(level), facts == 0 {
                report.error(where_, "level \(level) but facts == 0")
            }
            if level == "unread", filesRead > 0 {
                report.error(where_, "level unread but filesRead > 0")
            }
            if level == "unread", PacketFields.text(directory.reason).isEmpty {
                report.warn(where_, "unread directory without a reason")
            }
            if filesRead > files {
                report.error(where_, "filesRead exceeds files")
            }
            let actual = factsByDir[directory.path]?.facts ?? 0
            if researched.contains(level), actual == 0, facts > 0 {
                report.warn(where_, "coverage claims facts but no fact cites code under this directory")
            }
        }
        for missing in inventoryDirs.subtracting(seen).sorted() {
            report.error("coverage.json:directories", "inventory directory \(missing) missing from coverage")
        }

        let claimedTraced = PacketFields.count(packet.coverage.paths.traced)
        if claimedTraced != packet.traces.count {
            report.warn("coverage.json:paths.traced", "says \(claimedTraced) but \(packet.traces.count) trace files exist")
        }
        return byLevel
    }

    // MARK: 7. Counts

    private func checkCounts() {
        let counts = packet.manifest.counts
        let unreadDirs = PacketFields.list(packet.coverage.directories).filter { $0.level == "unread" }.count
        let computed: [(key: String, claimed: Int, actual: Int)] = [
            ("facts", PacketFields.count(counts.facts), packet.facts.count),
            ("verified", PacketFields.count(counts.verified), statusCounts["verified"] ?? 0),
            ("refuted", PacketFields.count(counts.refuted), statusCounts["refuted"] ?? 0),
            ("traces", PacketFields.count(counts.traces), packet.traces.count),
            ("unreadDirs", PacketFields.count(counts.unreadDirs), unreadDirs),
        ]
        for entry in computed where entry.claimed != entry.actual {
            report.warn("packet.json:counts.\(entry.key)", "says \(entry.claimed) but computed \(entry.actual)")
        }
    }

    // MARK: 8. Drafts

    private func checkDrafts() async {
        let draftsDir = packet.root.appendingPathComponent("drafts", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: draftsDir.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }
        report.stats["drafts"] = PacketValidationRun.regularFileCount(under: draftsDir)

        guard let regex = try? NSRegularExpression(pattern: "\\[\\[([^\\]|]+)(?:\\|[^\\]]*)?\\]\\]") else { return }
        let base = draftsDir.standardizedFileURL.path + "/"
        for file in packet.draftMarkdownFiles.sorted(by: { $0.path < $1.path }) {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            var relative = file.standardizedFileURL.path
            if relative.hasPrefix(base) { relative = String(relative.dropFirst(base.count)) }
            let where_ = "drafts/\(relative)"
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            for match in regex.matches(in: text, range: range) {
                guard match.numberOfRanges > 1, let anchorRange = Range(match.range(at: 1), in: text) else { continue }
                await checkAnchor(String(text[anchorRange]), at: where_)
            }
        }
    }

    private static func regularFileCount(under root: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: []
        ) else { return 0 }
        var count = 0
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true { count += 1 }
        }
        return count
    }

    // MARK: 6. Completeness gates

    private func checkCompleteness() {
        if packet.facts.isEmpty {
            report.error("facts.jsonl", "packet has no facts; a packet must carry the research, not only the survey")
        }
        if packet.manifest.summary.hasPrefix("SUMMARY PENDING") {
            report.error("packet.json:summary", "placeholder summary left by survey_repo.py")
        }
        let directories = PacketFields.list(packet.coverage.directories)
        if !directories.isEmpty, directories.allSatisfy({ $0.level == "unread" || $0.level == "inventoried" }) {
            report.error("coverage.json", "no directory reached level mapped; nothing was researched")
        }
        if PacketFields.list(packet.paths.paths).isEmpty, packet.manifest.scope != "smoke" {
            report.warn("paths.json", "no critical paths ranked")
        }
        if packet.manifest.scope == "complete" {
            if packet.decisions == nil { report.warn("decisions.json", "complete scope without this file") }
            if packet.glossary == nil { report.warn("glossary.json", "complete scope without this file") }
        }
    }

    // MARK: Stats

    private func fillStats(pathIDs: Set<String>, coverageByLevel: [String: Int]) {
        report.stats["facts"] = packet.facts.count
        report.stats["traces"] = packet.traces.count
        report.stats["paths"] = pathIDs.count
        report.stats["directories"] = PacketFields.list(packet.inventory.topLevel).count
        report.stats["verifiers"] = verifiers.count
        report.stats["anchorsUnresolved"] = unresolved
        for (kind, count) in anchorsByKind { report.stats["anchors.\(kind)"] = count }
        for (level, count) in coverageByLevel { report.stats["coverage.\(level)"] = count }
        for (status, count) in statusCounts { report.stats["status.\(status)"] = count }
        for (kind, count) in kindCounts { report.stats["kind.\(kind)"] = count }
        if let resolver { report.stats["gitCalls"] = resolver.gitCalls }
    }
}
