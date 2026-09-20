// PacketModels.swift — "Onboard to a Codebase", milestone M2 (Research Packet contract).
//
// The Codable records of a Research Packet (docs/onboarding/PACKET.md; the
// normative JSON Schemas live in .claude/skills/onboarding-research/schema/),
// plus PacketReader, which loads a packet directory into a ResearchPacket.
// The reader is deliberately a *reader*, not a validator: anchors stay raw
// strings, enum-like fields stay strings and dates are parsed leniently, so a
// malformed anchor or an unknown fact kind reaches PacketValidator and is
// reported next to everything else instead of aborting the load. Only what
// makes a record unreadable throws: a missing required file, invalid JSON, a
// missing schema-required key, or a value of the wrong JSON type.
//
// Every type has an EXPLICIT init(from:) and encode(to:), never synthesized
// Codable (the OnboardingModels convention): unknown keys are ignored, missing
// optionals decode as nil, optional arrays and objects default to empty.
// Fields the schema marks optional are Optional here; required ones are not.

import Foundation

// MARK: - Free-form JSON

/// A generic JSON value for `Fact.attributes` and any other free-form object.
indirect enum JSONValue: Codable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Double.self) {
            self = .number(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
            return
        }
        if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
            return
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .number(let value):
            // Integral values print as integers ("3", not "3.0") so a
            // re-encoded packet reads like the producer wrote it.
            if value.isFinite, value == value.rounded(.towardZero), let integer = Int(exactly: value) {
                try container.encode(integer)
            } else {
                try container.encode(value)
            }
        case .string(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }

    // MARK: Convenience accessors

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

// MARK: - Dates

/// Lenient ISO 8601 handling for the packet's `date-time` fields. Producers
/// vary (git's `%cI` with an offset, Python's `isoformat()` with six
/// fractional digits, a hand-written value without a zone), and a date the
/// reader cannot parse should be the only reason a timestamp fails.
enum PacketDate {
    static func parse(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let date = OnboardingJSON.date(fromISO8601: trimmed) { return date }
        if let date = OnboardingJSON.date(fromISO8601: trimFraction(trimmed)) { return date }
        // No zone designator at all: assume UTC.
        if !hasZoneDesignator(trimmed) {
            if let date = OnboardingJSON.date(fromISO8601: trimmed + "Z") { return date }
            if let date = OnboardingJSON.date(fromISO8601: trimFraction(trimmed) + "Z") { return date }
        }
        return nil
    }

    static func string(from date: Date) -> String {
        OnboardingJSON.iso8601String(from: date)
    }

    /// "…:00.123456+00:00" -> "…:00.123+00:00" (ISO8601DateFormatter reads at most three digits).
    private static func trimFraction(_ raw: String) -> String {
        guard let tIndex = raw.firstIndex(where: { $0 == "T" || $0 == "t" }),
              let dot = raw[tIndex...].firstIndex(of: ".") else { return raw }
        var end = raw.index(after: dot)
        while end < raw.endIndex, raw[end].isNumber {
            end = raw.index(after: end)
        }
        let digits = raw[raw.index(after: dot)..<end]
        guard digits.count > 3 else { return raw }
        return String(raw[..<raw.index(after: dot)]) + String(digits.prefix(3)) + String(raw[end...])
    }

    private static func hasZoneDesignator(_ raw: String) -> Bool {
        guard let tIndex = raw.firstIndex(where: { $0 == "T" || $0 == "t" }) else { return false }
        let timePart = raw[raw.index(after: tIndex)...]
        if timePart.hasSuffix("Z") || timePart.hasSuffix("z") { return true }
        return timePart.contains("+") || timePart.contains("-")
    }
}

// MARK: - packet.json

struct PacketManifest: Codable, Equatable {
    static let currentVersion = 1
    static let fileName = "packet.json"
    /// Allowed `scope` values.
    static let scopes: [String] = ["smoke", "preview", "complete"]

    var version: Int = PacketManifest.currentVersion
    var producer = Producer()
    var repo = Repo()
    /// "smoke", "preview" or "complete" (kept as a string so an unknown value
    /// reaches the validator).
    var scope: String = "complete"
    /// One paragraph a stranger could read first (schema: at least 40 characters).
    var summary: String = ""
    var counts = Counts()
    var briefing: String? = nil

    init() {}

    private enum CodingKeys: String, CodingKey {
        case version, producer, repo, scope, summary, counts, briefing
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        producer = try c.decode(Producer.self, forKey: .producer)
        repo = try c.decode(Repo.self, forKey: .repo)
        scope = try c.decode(String.self, forKey: .scope)
        summary = try c.decode(String.self, forKey: .summary)
        counts = try c.decode(Counts.self, forKey: .counts)
        briefing = try c.decodeIfPresent(String.self, forKey: .briefing)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(producer, forKey: .producer)
        try c.encode(repo, forKey: .repo)
        try c.encode(scope, forKey: .scope)
        try c.encode(summary, forKey: .summary)
        try c.encode(counts, forKey: .counts)
        try c.encodeIfPresent(briefing, forKey: .briefing)
    }

    struct Producer: Codable, Equatable {
        /// "claude-code-skill", "walkthrough-studio-fleet", ...
        var name: String = ""
        var version: String = ""
        var model: String? = nil
        var startedAt: Date = OnboardingJSON.now()
        var finishedAt: Date = OnboardingJSON.now()
        var notes: String? = nil

        init() {}

        init(name: String, version: String, model: String? = nil, startedAt: Date, finishedAt: Date, notes: String? = nil) {
            self.name = name
            self.version = version
            self.model = model
            self.startedAt = startedAt
            self.finishedAt = finishedAt
            self.notes = notes
        }

        private enum CodingKeys: String, CodingKey {
            case name, version, model, startedAt, finishedAt, notes
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            version = try c.decode(String.self, forKey: .version)
            model = try c.decodeIfPresent(String.self, forKey: .model)
            startedAt = try PacketModelsDecoding.date(from: c, forKey: .startedAt)
            finishedAt = try PacketModelsDecoding.date(from: c, forKey: .finishedAt)
            notes = try c.decodeIfPresent(String.self, forKey: .notes)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(version, forKey: .version)
            try c.encodeIfPresent(model, forKey: .model)
            try c.encode(PacketDate.string(from: startedAt), forKey: .startedAt)
            try c.encode(PacketDate.string(from: finishedAt), forKey: .finishedAt)
            try c.encodeIfPresent(notes, forKey: .notes)
        }
    }

    struct Repo: Codable, Equatable {
        var url: String? = nil
        /// 40 lowercase hex characters; every `code:` anchor's sha7 must prefix it.
        var headSHA: String = ""
        var defaultBranch: String? = nil
        var localPath: String? = nil
        var name: String? = nil

        init() {}

        init(url: String? = nil, headSHA: String, defaultBranch: String? = nil, localPath: String? = nil, name: String? = nil) {
            self.url = url
            self.headSHA = headSHA
            self.defaultBranch = defaultBranch
            self.localPath = localPath
            self.name = name
        }

        private enum CodingKeys: String, CodingKey {
            case url, headSHA, defaultBranch, localPath, name
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            url = try c.decodeIfPresent(String.self, forKey: .url)
            headSHA = try c.decode(String.self, forKey: .headSHA)
            defaultBranch = try c.decodeIfPresent(String.self, forKey: .defaultBranch)
            localPath = try c.decodeIfPresent(String.self, forKey: .localPath)
            name = try c.decodeIfPresent(String.self, forKey: .name)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(url, forKey: .url)
            try c.encode(headSHA, forKey: .headSHA)
            try c.encodeIfPresent(defaultBranch, forKey: .defaultBranch)
            try c.encodeIfPresent(localPath, forKey: .localPath)
            try c.encodeIfPresent(name, forKey: .name)
        }
    }

    struct Counts: Codable, Equatable {
        var facts: Int = 0
        var verified: Int = 0
        var refuted: Int = 0
        var unknown: Int? = nil
        var traces: Int = 0
        var unreadDirs: Int = 0

        init() {}

        init(facts: Int, verified: Int, refuted: Int, unknown: Int? = nil, traces: Int, unreadDirs: Int) {
            self.facts = facts
            self.verified = verified
            self.refuted = refuted
            self.unknown = unknown
            self.traces = traces
            self.unreadDirs = unreadDirs
        }

        private enum CodingKeys: String, CodingKey {
            case facts, verified, refuted, unknown, traces, unreadDirs
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            facts = try c.decode(Int.self, forKey: .facts)
            verified = try c.decode(Int.self, forKey: .verified)
            refuted = try c.decode(Int.self, forKey: .refuted)
            unknown = try c.decodeIfPresent(Int.self, forKey: .unknown)
            traces = try c.decode(Int.self, forKey: .traces)
            unreadDirs = try c.decode(Int.self, forKey: .unreadDirs)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(facts, forKey: .facts)
            try c.encode(verified, forKey: .verified)
            try c.encode(refuted, forKey: .refuted)
            try c.encodeIfPresent(unknown, forKey: .unknown)
            try c.encode(traces, forKey: .traces)
            try c.encode(unreadDirs, forKey: .unreadDirs)
        }
    }
}

// MARK: - inventory.json

struct PacketInventory: Codable, Equatable {
    static let fileName = "inventory.json"

    var version: Int = PacketManifest.currentVersion
    var headSHA: String = ""
    var totalFiles: Int = 0
    var totalBytes: Int? = nil
    var topLevel: [TopLevelEntry] = []
    /// File count by extension or language name.
    var languages: [String: Int] = [:]
    var entryPoints: [EntryPoint] = []
    /// Anchor strings (`code:` expected; the validator checks).
    var manifests: [String] = []
    var ci: [String] = []
    var infra: [String] = []
    var docs: [String] = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case version, headSHA, totalFiles, totalBytes, topLevel, languages
        case entryPoints, manifests, ci, infra, docs
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        headSHA = try c.decode(String.self, forKey: .headSHA)
        totalFiles = try c.decode(Int.self, forKey: .totalFiles)
        totalBytes = try c.decodeIfPresent(Int.self, forKey: .totalBytes)
        topLevel = try c.decode([TopLevelEntry].self, forKey: .topLevel)
        languages = try c.decode([String: Int].self, forKey: .languages)
        entryPoints = try c.decode([EntryPoint].self, forKey: .entryPoints)
        manifests = try c.decode([String].self, forKey: .manifests)
        ci = try c.decode([String].self, forKey: .ci)
        infra = try c.decode([String].self, forKey: .infra)
        docs = try c.decode([String].self, forKey: .docs)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(headSHA, forKey: .headSHA)
        try c.encode(totalFiles, forKey: .totalFiles)
        try c.encodeIfPresent(totalBytes, forKey: .totalBytes)
        try c.encode(topLevel, forKey: .topLevel)
        try c.encode(languages, forKey: .languages)
        try c.encode(entryPoints, forKey: .entryPoints)
        try c.encode(manifests, forKey: .manifests)
        try c.encode(ci, forKey: .ci)
        try c.encode(infra, forKey: .infra)
        try c.encode(docs, forKey: .docs)
    }

    /// The directory paths ("src/", ".", ...) as coverage.json must list them.
    var topLevelPaths: [String] { topLevel.map { $0.path } }

    struct TopLevelEntry: Codable, Equatable {
        /// Directory path with a trailing slash, or "." for root files.
        var path: String
        var files: Int
        var bytes: Int? = nil
        var languages: [String: Int]? = nil
        var generated: Bool
        var reason: String? = nil

        init(path: String, files: Int, bytes: Int? = nil, languages: [String: Int]? = nil, generated: Bool, reason: String? = nil) {
            self.path = path
            self.files = files
            self.bytes = bytes
            self.languages = languages
            self.generated = generated
            self.reason = reason
        }

        private enum CodingKeys: String, CodingKey {
            case path, files, bytes, languages, generated, reason
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decode(String.self, forKey: .path)
            files = try c.decode(Int.self, forKey: .files)
            bytes = try c.decodeIfPresent(Int.self, forKey: .bytes)
            languages = try c.decodeIfPresent([String: Int].self, forKey: .languages)
            generated = try c.decode(Bool.self, forKey: .generated)
            reason = try c.decodeIfPresent(String.self, forKey: .reason)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(path, forKey: .path)
            try c.encode(files, forKey: .files)
            try c.encodeIfPresent(bytes, forKey: .bytes)
            try c.encodeIfPresent(languages, forKey: .languages)
            try c.encode(generated, forKey: .generated)
            try c.encodeIfPresent(reason, forKey: .reason)
        }
    }

    struct EntryPoint: Codable, Equatable {
        /// Allowed `kind` values.
        static let kinds: [String] = ["main", "httpRoute", "cli", "job", "worker", "test", "build", "ci", "infra", "other"]

        /// Anchor string (`code:` expected).
        var anchor: String
        var kind: String
        var note: String? = nil

        init(anchor: String, kind: String, note: String? = nil) {
            self.anchor = anchor
            self.kind = kind
            self.note = note
        }

        private enum CodingKeys: String, CodingKey { case anchor, kind, note }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            anchor = try c.decode(String.self, forKey: .anchor)
            kind = try c.decode(String.self, forKey: .kind)
            note = try c.decodeIfPresent(String.self, forKey: .note)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(anchor, forKey: .anchor)
            try c.encode(kind, forKey: .kind)
            try c.encodeIfPresent(note, forKey: .note)
        }
    }
}

// MARK: - history.json

struct PacketHistory: Codable, Equatable {
    static let fileName = "history.json"
    /// Keys the schema requires in `messageKeywords` (wip and hack are optional).
    static let requiredMessageKeywords: [String] = ["revert", "hotfix", "fix", "todo", "fixme"]

    var version: Int = PacketManifest.currentVersion
    var headSHA: String = ""
    var commits: Int = 0
    var firstCommit: String? = nil
    var lastCommit: String? = nil
    var shallow: Bool? = nil
    var authors: [Author] = []
    var hotspots: [Hotspot] = []
    var ownership: [Ownership] = []
    var stale: [StaleFile] = []
    var parallel: [ParallelPair] = []
    /// revert, hotfix, fix, todo, fixme (required) plus wip, hack (optional).
    var messageKeywords: [String: Int] = [:]
    var notableCommits: [NotableCommit] = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case version, headSHA, commits, firstCommit, lastCommit, shallow, authors
        case hotspots, ownership, stale, parallel, messageKeywords, notableCommits
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        headSHA = try c.decode(String.self, forKey: .headSHA)
        commits = try c.decode(Int.self, forKey: .commits)
        firstCommit = try c.decodeIfPresent(String.self, forKey: .firstCommit)
        lastCommit = try c.decodeIfPresent(String.self, forKey: .lastCommit)
        shallow = try c.decodeIfPresent(Bool.self, forKey: .shallow)
        authors = try c.decode([Author].self, forKey: .authors)
        hotspots = try c.decode([Hotspot].self, forKey: .hotspots)
        ownership = try c.decode([Ownership].self, forKey: .ownership)
        stale = try c.decode([StaleFile].self, forKey: .stale)
        parallel = try c.decode([ParallelPair].self, forKey: .parallel)
        messageKeywords = try c.decode([String: Int].self, forKey: .messageKeywords)
        notableCommits = try c.decodeIfPresent([NotableCommit].self, forKey: .notableCommits) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(headSHA, forKey: .headSHA)
        try c.encode(commits, forKey: .commits)
        try c.encodeIfPresent(firstCommit, forKey: .firstCommit)
        try c.encodeIfPresent(lastCommit, forKey: .lastCommit)
        try c.encodeIfPresent(shallow, forKey: .shallow)
        try c.encode(authors, forKey: .authors)
        try c.encode(hotspots, forKey: .hotspots)
        try c.encode(ownership, forKey: .ownership)
        try c.encode(stale, forKey: .stale)
        try c.encode(parallel, forKey: .parallel)
        try c.encode(messageKeywords, forKey: .messageKeywords)
        try c.encode(notableCommits, forKey: .notableCommits)
    }

    struct Author: Codable, Equatable {
        var name: String
        var commits: Int
        /// 0...1 share of all commits.
        var share: Double

        init(name: String, commits: Int, share: Double) {
            self.name = name
            self.commits = commits
            self.share = share
        }

        private enum CodingKeys: String, CodingKey { case name, commits, share }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            commits = try c.decode(Int.self, forKey: .commits)
            share = try c.decode(Double.self, forKey: .share)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(commits, forKey: .commits)
            try c.encode(share, forKey: .share)
        }
    }

    struct Hotspot: Codable, Equatable {
        var path: String
        var commits: Int
        var lastTouched: String
        var authors: Int? = nil

        init(path: String, commits: Int, lastTouched: String, authors: Int? = nil) {
            self.path = path
            self.commits = commits
            self.lastTouched = lastTouched
            self.authors = authors
        }

        private enum CodingKeys: String, CodingKey { case path, commits, lastTouched, authors }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decode(String.self, forKey: .path)
            commits = try c.decode(Int.self, forKey: .commits)
            lastTouched = try c.decode(String.self, forKey: .lastTouched)
            authors = try c.decodeIfPresent(Int.self, forKey: .authors)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(path, forKey: .path)
            try c.encode(commits, forKey: .commits)
            try c.encode(lastTouched, forKey: .lastTouched)
            try c.encodeIfPresent(authors, forKey: .authors)
        }
    }

    struct Ownership: Codable, Equatable {
        var dir: String
        var commits: Int? = nil
        var authors: [Share] = []
        /// Smallest number of authors covering 50 percent of the directory's commits.
        var busFactor: Int

        init(dir: String, commits: Int? = nil, authors: [Share], busFactor: Int) {
            self.dir = dir
            self.commits = commits
            self.authors = authors
            self.busFactor = busFactor
        }

        private enum CodingKeys: String, CodingKey { case dir, commits, authors, busFactor }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            dir = try c.decode(String.self, forKey: .dir)
            commits = try c.decodeIfPresent(Int.self, forKey: .commits)
            authors = try c.decode([Share].self, forKey: .authors)
            busFactor = try c.decode(Int.self, forKey: .busFactor)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(dir, forKey: .dir)
            try c.encodeIfPresent(commits, forKey: .commits)
            try c.encode(authors, forKey: .authors)
            try c.encode(busFactor, forKey: .busFactor)
        }

        struct Share: Codable, Equatable {
            var name: String
            var share: Double
            var commits: Int? = nil

            init(name: String, share: Double, commits: Int? = nil) {
                self.name = name
                self.share = share
                self.commits = commits
            }

            private enum CodingKeys: String, CodingKey { case name, share, commits }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                name = try c.decode(String.self, forKey: .name)
                share = try c.decode(Double.self, forKey: .share)
                commits = try c.decodeIfPresent(Int.self, forKey: .commits)
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(name, forKey: .name)
                try c.encode(share, forKey: .share)
                try c.encodeIfPresent(commits, forKey: .commits)
            }
        }
    }

    struct StaleFile: Codable, Equatable {
        var path: String
        var lastTouched: String
        var days: Int? = nil

        init(path: String, lastTouched: String, days: Int? = nil) {
            self.path = path
            self.lastTouched = lastTouched
            self.days = days
        }

        private enum CodingKeys: String, CodingKey { case path, lastTouched, days }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decode(String.self, forKey: .path)
            lastTouched = try c.decode(String.self, forKey: .lastTouched)
            days = try c.decodeIfPresent(Int.self, forKey: .days)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(path, forKey: .path)
            try c.encode(lastTouched, forKey: .lastTouched)
            try c.encodeIfPresent(days, forKey: .days)
        }
    }

    /// Two implementations of the same thing; `a` and `b` are `code:` anchors.
    struct ParallelPair: Codable, Equatable {
        var a: String
        var b: String
        var reason: String

        init(a: String, b: String, reason: String) {
            self.a = a
            self.b = b
            self.reason = reason
        }

        private enum CodingKeys: String, CodingKey { case a, b, reason }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            a = try c.decode(String.self, forKey: .a)
            b = try c.decode(String.self, forKey: .b)
            reason = try c.decode(String.self, forKey: .reason)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(a, forKey: .a)
            try c.encode(b, forKey: .b)
            try c.encode(reason, forKey: .reason)
        }
    }

    struct NotableCommit: Codable, Equatable {
        /// `commit:` anchor string.
        var anchor: String
        var subject: String? = nil
        var author: String? = nil
        var date: String? = nil
        var why: String

        init(anchor: String, subject: String? = nil, author: String? = nil, date: String? = nil, why: String) {
            self.anchor = anchor
            self.subject = subject
            self.author = author
            self.date = date
            self.why = why
        }

        private enum CodingKeys: String, CodingKey { case anchor, subject, author, date, why }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            anchor = try c.decode(String.self, forKey: .anchor)
            subject = try c.decodeIfPresent(String.self, forKey: .subject)
            author = try c.decodeIfPresent(String.self, forKey: .author)
            date = try c.decodeIfPresent(String.self, forKey: .date)
            why = try c.decode(String.self, forKey: .why)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(anchor, forKey: .anchor)
            try c.encodeIfPresent(subject, forKey: .subject)
            try c.encodeIfPresent(author, forKey: .author)
            try c.encodeIfPresent(date, forKey: .date)
            try c.encode(why, forKey: .why)
        }
    }
}

// MARK: - dependencies.json

struct PacketCVE: Codable, Equatable {
    /// Allowed `severity` values.
    static let severities: [String] = ["critical", "high", "medium", "low", "unknown"]

    var id: String
    var severity: String
    var url: String? = nil
    var note: String? = nil

    init(id: String, severity: String, url: String? = nil, note: String? = nil) {
        self.id = id
        self.severity = severity
        self.url = url
        self.note = note
    }

    private enum CodingKeys: String, CodingKey { case id, severity, url, note }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        severity = try c.decode(String.self, forKey: .severity)
        url = try c.decodeIfPresent(String.self, forKey: .url)
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(severity, forKey: .severity)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(note, forKey: .note)
    }
}

/// `cves` is polymorphic: the string "unknown" or an array of CVE records.
enum PacketCVEs: Codable, Equatable {
    case unknown
    case list([PacketCVE])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            guard text == "unknown" else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "cves must be the string \"unknown\" or an array, got \"\(text)\""
                )
            }
            self = .unknown
            return
        }
        self = .list(try container.decode([PacketCVE].self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .unknown:
            try container.encode("unknown")
        case .list(let cves):
            try container.encode(cves)
        }
    }

    /// The listed CVEs; empty for `.unknown`.
    var cves: [PacketCVE] {
        if case .list(let cves) = self { return cves }
        return []
    }

    var isUnknown: Bool {
        if case .unknown = self { return true }
        return false
    }
}

struct PacketDependencies: Codable, Equatable {
    static let fileName = "dependencies.json"

    var version: Int = PacketManifest.currentVersion
    var headSHA: String = ""
    var dependencies: [Dependency] = []

    init() {}

    private enum CodingKeys: String, CodingKey { case version, headSHA, dependencies }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        headSHA = try c.decode(String.self, forKey: .headSHA)
        dependencies = try c.decode([Dependency].self, forKey: .dependencies)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(headSHA, forKey: .headSHA)
        try c.encode(dependencies, forKey: .dependencies)
    }

    struct Dependency: Codable, Equatable {
        /// Allowed `ecosystem` values.
        static let ecosystems: [String] = [
            "pypi", "npm", "swiftpm", "cargo", "go", "maven", "rubygems", "nuget", "composer", "system", "other",
        ]

        var name: String
        var version: String
        /// `code:` anchor of the manifest that declares it.
        var manifest: String
        var ecosystem: String
        /// SPDX id, or "unknown".
        var license: String
        /// "supported", "end-of-life", "unknown", or a date.
        var eol: String
        var cves: PacketCVEs
        var direct: Bool? = nil
        var note: String? = nil
        /// Anchor strings.
        var evidence: [String] = []

        init(name: String, version: String, manifest: String, ecosystem: String, license: String, eol: String,
             cves: PacketCVEs, direct: Bool? = nil, note: String? = nil, evidence: [String] = []) {
            self.name = name
            self.version = version
            self.manifest = manifest
            self.ecosystem = ecosystem
            self.license = license
            self.eol = eol
            self.cves = cves
            self.direct = direct
            self.note = note
            self.evidence = evidence
        }

        private enum CodingKeys: String, CodingKey {
            case name, version, manifest, ecosystem, license, eol, cves, direct, note, evidence
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            version = try c.decode(String.self, forKey: .version)
            manifest = try c.decode(String.self, forKey: .manifest)
            ecosystem = try c.decode(String.self, forKey: .ecosystem)
            license = try c.decode(String.self, forKey: .license)
            eol = try c.decode(String.self, forKey: .eol)
            cves = try c.decode(PacketCVEs.self, forKey: .cves)
            direct = try c.decodeIfPresent(Bool.self, forKey: .direct)
            note = try c.decodeIfPresent(String.self, forKey: .note)
            evidence = try c.decodeIfPresent([String].self, forKey: .evidence) ?? []
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(version, forKey: .version)
            try c.encode(manifest, forKey: .manifest)
            try c.encode(ecosystem, forKey: .ecosystem)
            try c.encode(license, forKey: .license)
            try c.encode(eol, forKey: .eol)
            try c.encode(cves, forKey: .cves)
            try c.encodeIfPresent(direct, forKey: .direct)
            try c.encodeIfPresent(note, forKey: .note)
            try c.encode(evidence, forKey: .evidence)
        }
    }
}

// MARK: - facts.jsonl

/// One line of facts.jsonl (PACKET.md section 4).
struct PacketFact: Codable, Equatable, Identifiable {
    static let fileName = "facts.jsonl"
    /// Allowed `kind` values, in schema order.
    static let kinds: [String] = [
        "component", "interface", "endpoint", "dependency", "dataEntity", "dataField", "flowHop",
        "decision", "risk", "owner", "hotspot", "testCoverage", "migration", "config", "integration",
        "deployStep", "incidentPattern", "term", "landmine", "metric", "buildResult", "security",
        "observability",
    ]
    /// Allowed `status` values.
    static let statuses: [String] = ["proposed", "verified", "refuted", "unknown"]
    /// `attributes` keys every dataEntity fact should carry (a value or "unknown").
    static let dataEntityAttributeKeys: [String] = ["pii", "rows", "retention"]

    var id: String = ""
    var kind: String = ""
    /// The path, symbol, table or concept the claim is about.
    var subject: String = ""
    /// One sentence (schema: 10 to 600 characters).
    var claim: String = ""
    var attributes: [String: JSONValue] = [:]
    var evidence: [Evidence] = []
    /// 0...1
    var confidence: Double = 0
    var producedBy: String = ""
    var verdicts: [Verdict] = []
    /// proposed, verified, refuted or unknown.
    var status: String = "proposed"
    var tags: [String]? = nil

    init() {}

    init(id: String, kind: String, subject: String, claim: String, attributes: [String: JSONValue] = [:],
         evidence: [Evidence], confidence: Double, producedBy: String, verdicts: [Verdict] = [],
         status: String, tags: [String]? = nil) {
        self.id = id
        self.kind = kind
        self.subject = subject
        self.claim = claim
        self.attributes = attributes
        self.evidence = evidence
        self.confidence = confidence
        self.producedBy = producedBy
        self.verdicts = verdicts
        self.status = status
        self.tags = tags
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, subject, claim, attributes, evidence, confidence, producedBy, verdicts, status, tags
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decode(String.self, forKey: .kind)
        subject = try c.decode(String.self, forKey: .subject)
        claim = try c.decode(String.self, forKey: .claim)
        attributes = try c.decodeIfPresent([String: JSONValue].self, forKey: .attributes) ?? [:]
        evidence = try c.decode([Evidence].self, forKey: .evidence)
        confidence = try c.decode(Double.self, forKey: .confidence)
        producedBy = try c.decode(String.self, forKey: .producedBy)
        verdicts = try c.decodeIfPresent([Verdict].self, forKey: .verdicts) ?? []
        status = try c.decode(String.self, forKey: .status)
        tags = try c.decodeIfPresent([String].self, forKey: .tags)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(subject, forKey: .subject)
        try c.encode(claim, forKey: .claim)
        try c.encode(attributes, forKey: .attributes)
        try c.encode(evidence, forKey: .evidence)
        try c.encode(confidence, forKey: .confidence)
        try c.encode(producedBy, forKey: .producedBy)
        try c.encode(verdicts, forKey: .verdicts)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(tags, forKey: .tags)
    }

    struct Evidence: Codable, Equatable {
        /// Anchor string.
        var anchor: String
        /// The text the producer actually read (up to about 40 lines).
        var excerpt: String? = nil
        var note: String? = nil

        init(anchor: String, excerpt: String? = nil, note: String? = nil) {
            self.anchor = anchor
            self.excerpt = excerpt
            self.note = note
        }

        private enum CodingKeys: String, CodingKey { case anchor, excerpt, note }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            anchor = try c.decode(String.self, forKey: .anchor)
            excerpt = try c.decodeIfPresent(String.self, forKey: .excerpt)
            note = try c.decodeIfPresent(String.self, forKey: .note)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(anchor, forKey: .anchor)
            try c.encodeIfPresent(excerpt, forKey: .excerpt)
            try c.encodeIfPresent(note, forKey: .note)
        }
    }

    struct Verdict: Codable, Equatable {
        /// Allowed `verdict` values.
        static let verdicts: [String] = ["confirmed", "refuted", "unknown"]

        var verifier: String
        /// confirmed, refuted or unknown.
        var verdict: String
        var reason: String
        /// Anchor strings (counter-evidence for a refuting verdict).
        var evidence: [String] = []

        init(verifier: String, verdict: String, reason: String, evidence: [String] = []) {
            self.verifier = verifier
            self.verdict = verdict
            self.reason = reason
            self.evidence = evidence
        }

        private enum CodingKeys: String, CodingKey { case verifier, verdict, reason, evidence }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            verifier = try c.decode(String.self, forKey: .verifier)
            verdict = try c.decode(String.self, forKey: .verdict)
            reason = try c.decode(String.self, forKey: .reason)
            evidence = try c.decodeIfPresent([String].self, forKey: .evidence) ?? []
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(verifier, forKey: .verifier)
            try c.encode(verdict, forKey: .verdict)
            try c.encode(reason, forKey: .reason)
            try c.encode(evidence, forKey: .evidence)
        }
    }
}

// MARK: - paths.json

struct PacketPaths: Codable, Equatable {
    static let fileName = "paths.json"

    var version: Int = PacketManifest.currentVersion
    var headSHA: String = ""
    var candidates: Int? = nil
    var paths: [CriticalPath] = []
    var untraced: [Untraced] = []

    init() {}

    private enum CodingKeys: String, CodingKey { case version, headSHA, candidates, paths, untraced }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        headSHA = try c.decode(String.self, forKey: .headSHA)
        candidates = try c.decodeIfPresent(Int.self, forKey: .candidates)
        paths = try c.decode([CriticalPath].self, forKey: .paths)
        untraced = try c.decodeIfPresent([Untraced].self, forKey: .untraced) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(headSHA, forKey: .headSHA)
        try c.encodeIfPresent(candidates, forKey: .candidates)
        try c.encode(paths, forKey: .paths)
        try c.encode(untraced, forKey: .untraced)
    }

    struct CriticalPath: Codable, Equatable, Identifiable {
        var id: String
        var title: String
        /// `code:` anchor of the entry point.
        var entry: String
        /// 1-based rank.
        var rank: Int
        var rationale: String
        var businessImpact: String? = nil
        var factIds: [String]? = nil
        /// nil means traced (the validator treats a missing flag as true, like the reference).
        var traced: Bool? = nil

        init(id: String, title: String, entry: String, rank: Int, rationale: String,
             businessImpact: String? = nil, factIds: [String]? = nil, traced: Bool? = nil) {
            self.id = id
            self.title = title
            self.entry = entry
            self.rank = rank
            self.rationale = rationale
            self.businessImpact = businessImpact
            self.factIds = factIds
            self.traced = traced
        }

        private enum CodingKeys: String, CodingKey {
            case id, title, entry, rank, rationale, businessImpact, factIds, traced
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            title = try c.decode(String.self, forKey: .title)
            entry = try c.decode(String.self, forKey: .entry)
            rank = try c.decode(Int.self, forKey: .rank)
            rationale = try c.decode(String.self, forKey: .rationale)
            businessImpact = try c.decodeIfPresent(String.self, forKey: .businessImpact)
            factIds = try c.decodeIfPresent([String].self, forKey: .factIds)
            traced = try c.decodeIfPresent(Bool.self, forKey: .traced)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(title, forKey: .title)
            try c.encode(entry, forKey: .entry)
            try c.encode(rank, forKey: .rank)
            try c.encode(rationale, forKey: .rationale)
            try c.encodeIfPresent(businessImpact, forKey: .businessImpact)
            try c.encodeIfPresent(factIds, forKey: .factIds)
            try c.encodeIfPresent(traced, forKey: .traced)
        }

        /// `traced` with the reference validator's default (true when absent).
        var isTraced: Bool { traced ?? true }
    }

    struct Untraced: Codable, Equatable, Identifiable {
        var id: String
        var title: String? = nil
        var reason: String

        init(id: String, title: String? = nil, reason: String) {
            self.id = id
            self.title = title
            self.reason = reason
        }

        private enum CodingKeys: String, CodingKey { case id, title, reason }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            title = try c.decodeIfPresent(String.self, forKey: .title)
            reason = try c.decode(String.self, forKey: .reason)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(title, forKey: .title)
            try c.encode(reason, forKey: .reason)
        }
    }
}

// MARK: - traces/<pathId>.json

/// One of the ten concerns of a trace (PACKET.md section 5).
struct PacketConcern: Codable, Equatable {
    /// Allowed `status` values.
    static let statuses: [String] = ["present", "absent", "unknown"]

    /// present, absent or unknown.
    var status: String
    /// Anchor strings; required when status is present or absent.
    var evidence: [String]
    var note: String? = nil

    init(status: String, evidence: [String], note: String? = nil) {
        self.status = status
        self.evidence = evidence
        self.note = note
    }

    private enum CodingKeys: String, CodingKey { case status, evidence, note }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = try c.decode(String.self, forKey: .status)
        evidence = try c.decode([String].self, forKey: .evidence)
        note = try c.decodeIfPresent(String.self, forKey: .note)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(status, forKey: .status)
        try c.encode(evidence, forKey: .evidence)
        try c.encodeIfPresent(note, forKey: .note)
    }
}

struct PacketTrace: Codable, Equatable {
    static let directoryName = "traces"
    /// The ten concern keys every trace must carry, in the canonical order.
    static let concernKeys: [String] = [
        "entry", "authorization", "validation", "businessLogic", "persistence",
        "sideEffects", "failureHandling", "idempotency", "timeoutsRetries", "logging",
    ]

    var version: Int = PacketManifest.currentVersion
    var pathId: String = ""
    var title: String = ""
    /// `code:` anchor of the entry point.
    var entry: String = ""
    /// The one concrete request or event being followed.
    var scenario: String = ""
    var hops: [Hop] = []
    /// Keyed by concern name (see `concernKeys`).
    var concerns: [String: PacketConcern] = [:]
    /// Plain sentences; non-empty in a valid packet.
    var scaresMe: [String] = []
    var factIds: [String]? = nil

    init() {}

    private enum CodingKeys: String, CodingKey {
        case version, pathId, title, entry, scenario, hops, concerns, scaresMe, factIds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        pathId = try c.decode(String.self, forKey: .pathId)
        title = try c.decode(String.self, forKey: .title)
        entry = try c.decode(String.self, forKey: .entry)
        scenario = try c.decode(String.self, forKey: .scenario)
        hops = try c.decode([Hop].self, forKey: .hops)
        concerns = try c.decode([String: PacketConcern].self, forKey: .concerns)
        scaresMe = try c.decode([String].self, forKey: .scaresMe)
        factIds = try c.decodeIfPresent([String].self, forKey: .factIds)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(pathId, forKey: .pathId)
        try c.encode(title, forKey: .title)
        try c.encode(entry, forKey: .entry)
        try c.encode(scenario, forKey: .scenario)
        try c.encode(hops, forKey: .hops)
        try c.encode(concerns, forKey: .concerns)
        try c.encode(scaresMe, forKey: .scaresMe)
        try c.encodeIfPresent(factIds, forKey: .factIds)
    }

    /// Concern names from `concernKeys` that this trace does not carry.
    var missingConcernKeys: [String] {
        PacketTrace.concernKeys.filter { concerns[$0] == nil }
    }

    struct Hop: Codable, Equatable {
        /// 1-based, in call order.
        var n: Int
        /// `code:` anchor of the code this hop lands in.
        var anchor: String
        /// `code:` anchor of the call that reaches it, when known.
        var callSite: String? = nil
        var summary: String
        var factIds: [String]? = nil

        init(n: Int, anchor: String, callSite: String? = nil, summary: String, factIds: [String]? = nil) {
            self.n = n
            self.anchor = anchor
            self.callSite = callSite
            self.summary = summary
            self.factIds = factIds
        }

        private enum CodingKeys: String, CodingKey { case n, anchor, callSite, summary, factIds }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            n = try c.decode(Int.self, forKey: .n)
            anchor = try c.decode(String.self, forKey: .anchor)
            callSite = try c.decodeIfPresent(String.self, forKey: .callSite)
            summary = try c.decode(String.self, forKey: .summary)
            factIds = try c.decodeIfPresent([String].self, forKey: .factIds)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(n, forKey: .n)
            try c.encode(anchor, forKey: .anchor)
            try c.encodeIfPresent(callSite, forKey: .callSite)
            try c.encode(summary, forKey: .summary)
            try c.encodeIfPresent(factIds, forKey: .factIds)
        }
    }
}

// MARK: - decisions.json

struct PacketDecisions: Codable, Equatable {
    static let fileName = "decisions.json"

    var version: Int = PacketManifest.currentVersion
    var headSHA: String = ""
    var decisions: [Decision] = []

    init() {}

    private enum CodingKeys: String, CodingKey { case version, headSHA, decisions }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        headSHA = try c.decode(String.self, forKey: .headSHA)
        decisions = try c.decode([Decision].self, forKey: .decisions)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(headSHA, forKey: .headSHA)
        try c.encode(decisions, forKey: .decisions)
    }

    /// A retroactive architecture decision record.
    struct Decision: Codable, Equatable, Identifiable {
        var id: String
        var title: String
        var decision: String
        var alternatives: [String]? = nil
        var consequences: String
        var wouldRepeat: Bool? = nil
        /// Anchor strings; at least one in a valid packet.
        var evidence: [String]
        var factIds: [String]? = nil

        init(id: String, title: String, decision: String, alternatives: [String]? = nil, consequences: String,
             wouldRepeat: Bool? = nil, evidence: [String], factIds: [String]? = nil) {
            self.id = id
            self.title = title
            self.decision = decision
            self.alternatives = alternatives
            self.consequences = consequences
            self.wouldRepeat = wouldRepeat
            self.evidence = evidence
            self.factIds = factIds
        }

        private enum CodingKeys: String, CodingKey {
            case id, title, decision, alternatives, consequences, wouldRepeat, evidence, factIds
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            title = try c.decode(String.self, forKey: .title)
            decision = try c.decode(String.self, forKey: .decision)
            alternatives = try c.decodeIfPresent([String].self, forKey: .alternatives)
            consequences = try c.decode(String.self, forKey: .consequences)
            wouldRepeat = try c.decodeIfPresent(Bool.self, forKey: .wouldRepeat)
            evidence = try c.decode([String].self, forKey: .evidence)
            factIds = try c.decodeIfPresent([String].self, forKey: .factIds)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(title, forKey: .title)
            try c.encode(decision, forKey: .decision)
            try c.encodeIfPresent(alternatives, forKey: .alternatives)
            try c.encode(consequences, forKey: .consequences)
            try c.encodeIfPresent(wouldRepeat, forKey: .wouldRepeat)
            try c.encode(evidence, forKey: .evidence)
            try c.encodeIfPresent(factIds, forKey: .factIds)
        }
    }
}

// MARK: - glossary.json

struct PacketGlossary: Codable, Equatable {
    static let fileName = "glossary.json"

    var version: Int = PacketManifest.currentVersion
    var headSHA: String = ""
    var terms: [Term] = []

    init() {}

    private enum CodingKeys: String, CodingKey { case version, headSHA, terms }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        headSHA = try c.decode(String.self, forKey: .headSHA)
        terms = try c.decode([Term].self, forKey: .terms)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(headSHA, forKey: .headSHA)
        try c.encode(terms, forKey: .terms)
    }

    struct Term: Codable, Equatable {
        var term: String
        var definition: String
        /// `code:` anchor where the term is defined, when known.
        var definedAt: String? = nil
        var factIds: [String]? = nil

        init(term: String, definition: String, definedAt: String? = nil, factIds: [String]? = nil) {
            self.term = term
            self.definition = definition
            self.definedAt = definedAt
            self.factIds = factIds
        }

        private enum CodingKeys: String, CodingKey { case term, definition, definedAt, factIds }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            term = try c.decode(String.self, forKey: .term)
            definition = try c.decode(String.self, forKey: .definition)
            definedAt = try c.decodeIfPresent(String.self, forKey: .definedAt)
            factIds = try c.decodeIfPresent([String].self, forKey: .factIds)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(term, forKey: .term)
            try c.encode(definition, forKey: .definition)
            try c.encodeIfPresent(definedAt, forKey: .definedAt)
            try c.encodeIfPresent(factIds, forKey: .factIds)
        }
    }
}

// MARK: - coverage.json

struct PacketCoverage: Codable, Equatable {
    static let fileName = "coverage.json"
    /// Coverage levels in ascending order (PACKET.md section 6).
    static let levels: [String] = ["unread", "inventoried", "mapped", "verified", "traced"]
    /// Allowed `checks[].check` values.
    static let checkNames: [String] = [
        "build", "tests", "lint", "typecheck", "secretScan", "dependencyAudit", "issues", "other",
    ]
    /// Allowed `checks[].status` values.
    static let checkStatuses: [String] = ["ran", "skipped", "failed"]

    var version: Int = PacketManifest.currentVersion
    var headSHA: String = ""
    var generatedAt: Date = OnboardingJSON.now()
    var directories: [Directory] = []
    var paths = PathsSummary()
    var checks: [Check] = []
    var deliverablesPlanned: Int? = nil
    var deliverablesProduced: Int? = nil

    init() {}

    private enum CodingKeys: String, CodingKey {
        case version, headSHA, generatedAt, directories, paths, checks, deliverablesPlanned, deliverablesProduced
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        headSHA = try c.decode(String.self, forKey: .headSHA)
        generatedAt = try PacketModelsDecoding.date(from: c, forKey: .generatedAt)
        directories = try c.decode([Directory].self, forKey: .directories)
        paths = try c.decode(PathsSummary.self, forKey: .paths)
        checks = try c.decode([Check].self, forKey: .checks)
        deliverablesPlanned = try c.decodeIfPresent(Int.self, forKey: .deliverablesPlanned)
        deliverablesProduced = try c.decodeIfPresent(Int.self, forKey: .deliverablesProduced)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(headSHA, forKey: .headSHA)
        try c.encode(PacketDate.string(from: generatedAt), forKey: .generatedAt)
        try c.encode(directories, forKey: .directories)
        try c.encode(paths, forKey: .paths)
        try c.encode(checks, forKey: .checks)
        try c.encodeIfPresent(deliverablesPlanned, forKey: .deliverablesPlanned)
        try c.encodeIfPresent(deliverablesProduced, forKey: .deliverablesProduced)
    }

    /// Position of a level in `levels`; nil for an unknown level string.
    static func levelIndex(_ level: String) -> Int? {
        levels.firstIndex(of: level)
    }

    struct Directory: Codable, Equatable {
        /// Same form as inventory.topLevel[].path ("src/", ".").
        var path: String
        var files: Int
        var filesRead: Int
        /// unread, inventoried, mapped, verified or traced.
        var level: String
        var facts: Int
        var verified: Int
        /// Required in spirit for `unread` directories.
        var reason: String? = nil

        init(path: String, files: Int, filesRead: Int, level: String, facts: Int, verified: Int, reason: String? = nil) {
            self.path = path
            self.files = files
            self.filesRead = filesRead
            self.level = level
            self.facts = facts
            self.verified = verified
            self.reason = reason
        }

        private enum CodingKeys: String, CodingKey { case path, files, filesRead, level, facts, verified, reason }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decode(String.self, forKey: .path)
            files = try c.decode(Int.self, forKey: .files)
            filesRead = try c.decode(Int.self, forKey: .filesRead)
            level = try c.decode(String.self, forKey: .level)
            facts = try c.decode(Int.self, forKey: .facts)
            verified = try c.decode(Int.self, forKey: .verified)
            reason = try c.decodeIfPresent(String.self, forKey: .reason)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(path, forKey: .path)
            try c.encode(files, forKey: .files)
            try c.encode(filesRead, forKey: .filesRead)
            try c.encode(level, forKey: .level)
            try c.encode(facts, forKey: .facts)
            try c.encode(verified, forKey: .verified)
            try c.encodeIfPresent(reason, forKey: .reason)
        }
    }

    struct PathsSummary: Codable, Equatable {
        var candidates: Int = 0
        var traced: Int = 0
        var untraced: [Untraced] = []

        init() {}

        init(candidates: Int, traced: Int, untraced: [Untraced]) {
            self.candidates = candidates
            self.traced = traced
            self.untraced = untraced
        }

        private enum CodingKeys: String, CodingKey { case candidates, traced, untraced }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            candidates = try c.decode(Int.self, forKey: .candidates)
            traced = try c.decode(Int.self, forKey: .traced)
            untraced = try c.decode([Untraced].self, forKey: .untraced)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(candidates, forKey: .candidates)
            try c.encode(traced, forKey: .traced)
            try c.encode(untraced, forKey: .untraced)
        }

        struct Untraced: Codable, Equatable, Identifiable {
            var id: String
            var reason: String

            init(id: String, reason: String) {
                self.id = id
                self.reason = reason
            }

            private enum CodingKeys: String, CodingKey { case id, reason }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = try c.decode(String.self, forKey: .id)
                reason = try c.decode(String.self, forKey: .reason)
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(id, forKey: .id)
                try c.encode(reason, forKey: .reason)
            }
        }
    }

    struct Check: Codable, Equatable {
        /// build, tests, lint, typecheck, secretScan, dependencyAudit, issues or other.
        var check: String
        /// ran, skipped or failed.
        var status: String
        var reason: String? = nil
        /// `cmd:` anchor of the captured output, when it ran.
        var anchor: String? = nil
        var note: String? = nil

        init(check: String, status: String, reason: String? = nil, anchor: String? = nil, note: String? = nil) {
            self.check = check
            self.status = status
            self.reason = reason
            self.anchor = anchor
            self.note = note
        }

        private enum CodingKeys: String, CodingKey { case check, status, reason, anchor, note }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            check = try c.decode(String.self, forKey: .check)
            status = try c.decode(String.self, forKey: .status)
            reason = try c.decodeIfPresent(String.self, forKey: .reason)
            anchor = try c.decodeIfPresent(String.self, forKey: .anchor)
            note = try c.decodeIfPresent(String.self, forKey: .note)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(check, forKey: .check)
            try c.encode(status, forKey: .status)
            try c.encodeIfPresent(reason, forKey: .reason)
            try c.encodeIfPresent(anchor, forKey: .anchor)
            try c.encodeIfPresent(note, forKey: .note)
        }
    }
}

// MARK: - Decoding helpers shared by the records above

enum PacketModelsDecoding {
    /// Decodes a `date-time` field written as a string, leniently (PacketDate).
    static func date<K: CodingKey>(from container: KeyedDecodingContainer<K>, forKey key: K) throws -> Date {
        let raw = try container.decode(String.self, forKey: key)
        guard let date = PacketDate.parse(raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: key,
                in: container,
                debugDescription: "not an ISO 8601 date-time: \"\(raw)\""
            )
        }
        return date
    }
}

// MARK: - The loaded packet

/// A Research Packet loaded from disk. Optional files are nil when absent;
/// `traces` is keyed by file stem (`traces/<stem>.json`), which a valid packet
/// keeps equal to `pathId`.
struct ResearchPacket {
    let root: URL
    let manifest: PacketManifest
    let inventory: PacketInventory
    let history: PacketHistory
    let dependencies: PacketDependencies?
    let facts: [PacketFact]
    /// Fact id -> the 1-based line of facts.jsonl it was read from (the FIRST
    /// line carrying that id, as the reference validator records it), so a
    /// message can name the line a reader would open rather than the fact's
    /// index among the non-blank lines. Empty for a packet built in memory.
    let factSourceLines: [String: Int]
    /// The 1-based facts.jsonl line each entry of `facts` was read from,
    /// parallel to `facts` (blank lines are skipped but still counted, as the
    /// reference validator counts them). Empty for a packet built in memory;
    /// the validator then falls back to the array index.
    let factLines: [Int]
    let paths: PacketPaths
    let traces: [String: PacketTrace]
    let decisions: PacketDecisions?
    let glossary: PacketGlossary?
    let coverage: PacketCoverage
    /// Every `drafts/**/*.md`, sorted by path.
    let draftMarkdownFiles: [URL]

    init(root: URL, manifest: PacketManifest, inventory: PacketInventory, history: PacketHistory,
         dependencies: PacketDependencies?, facts: [PacketFact], paths: PacketPaths,
         traces: [String: PacketTrace], decisions: PacketDecisions?, glossary: PacketGlossary?,
         coverage: PacketCoverage, draftMarkdownFiles: [URL], factSourceLines: [String: Int] = [:],
         factLines: [Int] = []) {
        self.root = root
        self.manifest = manifest
        self.inventory = inventory
        self.history = history
        self.dependencies = dependencies
        self.facts = facts
        self.factSourceLines = factSourceLines
        self.factLines = factLines
        self.paths = paths
        self.traces = traces
        self.decisions = decisions
        self.glossary = glossary
        self.coverage = coverage
        self.draftMarkdownFiles = draftMarkdownFiles
    }

    /// `packet.json.repo.headSHA`, the commit every `code:` anchor is pinned to.
    var headSHA: String { manifest.repo.headSHA }

    /// All fact ids, duplicates included (the validator reports duplicates).
    var factIDs: [String] { facts.map { $0.id } }

    /// The first fact with that id.
    func fact(id: String) -> PacketFact? {
        facts.first(where: { $0.id == id })
    }

    /// The 1-based facts.jsonl line a fact was read from, when the packet came
    /// from disk; nil for a packet built in memory or an unknown id.
    func sourceLine(ofFact id: String) -> Int? {
        factSourceLines[id]
    }

    /// The facts.jsonl line `facts[index]` was read from, falling back to
    /// `index + 1` for a packet built in memory. Messages about a fact use
    /// this rather than `sourceLine(ofFact:)`, which holds the FIRST line
    /// carrying an id and so would point a duplicate-id error at the original.
    func factLine(at index: Int) -> Int {
        factLines.indices.contains(index) ? factLines[index] : index + 1
    }

    /// Facts content may use: verified and unknown, never refuted or proposed.
    var usableFacts: [PacketFact] {
        facts.filter { $0.status == "verified" || $0.status == "unknown" }
    }

    /// Absolute URL of `commands/<unit>/<n>.txt` for a `cmd:` anchor.
    func commandOutputURL(unit: String, n: Int) -> URL {
        root.appendingPathComponent("commands", isDirectory: true)
            .appendingPathComponent(unit, isDirectory: true)
            .appendingPathComponent("\(n).txt")
    }
}

// MARK: - Reader

enum PacketReader {
    static let requiredFiles: [String] = [
        PacketManifest.fileName, PacketInventory.fileName, PacketHistory.fileName,
        PacketFact.fileName, PacketPaths.fileName, PacketCoverage.fileName,
    ]
    static let optionalFiles: [String] = [
        PacketDependencies.fileName, PacketDecisions.fileName, PacketGlossary.fileName,
    ]
    static let draftsDirectoryName = "drafts"
    static let commandsDirectoryName = "commands"

    /// Loads every file of the packet at `root`. Throws `StudioError("<file>: <reason>")`
    /// when a required file is missing or any present file does not decode.
    static func load(_ root: URL) throws -> ResearchPacket {
        let root = root.standardizedFileURL
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw StudioError("\(root.lastPathComponent): packet directory not found at \(root.path)")
        }

        let manifest = try readRequired(PacketManifest.self, PacketManifest.fileName, in: root)
        let inventory = try readRequired(PacketInventory.self, PacketInventory.fileName, in: root)
        let history = try readRequired(PacketHistory.self, PacketHistory.fileName, in: root)
        let dependencies = try readOptional(PacketDependencies.self, PacketDependencies.fileName, in: root)
        let factLines = try readFactLines(in: root)
        let facts = factLines.map { $0.fact }
        let paths = try readRequired(PacketPaths.self, PacketPaths.fileName, in: root)
        let traces = try readTraces(in: root)
        let decisions = try readOptional(PacketDecisions.self, PacketDecisions.fileName, in: root)
        let glossary = try readOptional(PacketGlossary.self, PacketGlossary.fileName, in: root)
        let coverage = try readRequired(PacketCoverage.self, PacketCoverage.fileName, in: root)
        let drafts = listDraftMarkdown(in: root)

        return ResearchPacket(
            root: root,
            manifest: manifest,
            inventory: inventory,
            history: history,
            dependencies: dependencies,
            facts: facts,
            paths: paths,
            traces: traces,
            decisions: decisions,
            glossary: glossary,
            coverage: coverage,
            draftMarkdownFiles: drafts,
            factSourceLines: PacketReader.sourceLines(of: factLines),
            factLines: factLines.map { $0.line }
        )
    }

    // MARK: Single files

    /// Reads and decodes `<root>/<name>`; "file missing" when it does not exist.
    static func readRequired<T: Decodable>(_ type: T.Type, _ name: String, in root: URL) throws -> T {
        let url = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StudioError("\(name): file missing")
        }
        return try decode(type, from: try readData(url, name: name), file: name)
    }

    /// nil when `<root>/<name>` does not exist; throws when it exists but does not decode.
    static func readOptional<T: Decodable>(_ type: T.Type, _ name: String, in root: URL) throws -> T? {
        let url = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decode(type, from: try readData(url, name: name), file: name)
    }

    /// One fact and the 1-based line of facts.jsonl it was read from.
    struct FactLine {
        let line: Int
        let fact: PacketFact
    }

    /// facts.jsonl: one Fact per line; blank lines are skipped; a bad line is
    /// reported as "facts.jsonl:<line>: <reason>" with a 1-based line number.
    static func readFacts(in root: URL) throws -> [PacketFact] {
        try readFactLines(in: root).map { $0.fact }
    }

    /// `readFacts` keeping each fact's line number (the reference validator
    /// numbers its fact messages the same way).
    static func readFactLines(in root: URL) throws -> [FactLine] {
        let name = PacketFact.fileName
        let url = root.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StudioError("\(name): file missing")
        }
        let data = try readData(url, name: name)
        guard let text = String(data: data, encoding: .utf8) else {
            throw StudioError("\(name): not UTF-8")
        }
        return try parseFactLines(text, file: name)
    }

    /// The JSONL parser behind `readFacts`, exposed so probes can feed text directly.
    static func parseFacts(_ text: String, file: String = PacketFact.fileName) throws -> [PacketFact] {
        try parseFactLines(text, file: file).map { $0.fact }
    }

    /// The JSONL parser proper: blank lines are skipped but still counted, so
    /// `line` is the line a reader would open in the file.
    static func parseFactLines(_ text: String, file: String = PacketFact.fileName) throws -> [FactLine] {
        var facts: [FactLine] = []
        let decoder = OnboardingJSON.decoder()
        var lineNumber = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lineNumber += 1
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            do {
                let fact = try decoder.decode(PacketFact.self, from: Data(line.utf8))
                facts.append(FactLine(line: lineNumber, fact: fact))
            } catch {
                throw StudioError("\(file):\(lineNumber): \(describe(error))")
            }
        }
        return facts
    }

    /// Fact id -> its first line, for `ResearchPacket.factSourceLines`
    /// (a duplicate id keeps the line of the first occurrence, as the
    /// reference validator does).
    static func sourceLines(of factLines: [FactLine]) -> [String: Int] {
        var lines: [String: Int] = [:]
        for entry in factLines where lines[entry.fact.id] == nil {
            lines[entry.fact.id] = entry.line
        }
        return lines
    }

    /// traces/*.json keyed by file stem, sorted by name; absent directory = no traces.
    static func readTraces(in root: URL) throws -> [String: PacketTrace] {
        let fileManager = FileManager.default
        let directory = root.appendingPathComponent(PacketTrace.directoryName, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return [:]
        }
        let names = (try? fileManager.contentsOfDirectory(atPath: directory.path))?.sorted() ?? []
        var traces: [String: PacketTrace] = [:]
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let relative = "\(PacketTrace.directoryName)/\(name)"
            let stem = String(name.dropLast(".json".count))
            let data = try readData(directory.appendingPathComponent(name), name: relative)
            traces[stem] = try decode(PacketTrace.self, from: data, file: relative)
        }
        return traces
    }

    /// Every `drafts/**/*.md`, sorted by path; empty when there is no drafts directory.
    static func listDraftMarkdown(in root: URL) -> [URL] {
        let fileManager = FileManager.default
        let directory = root.appendingPathComponent(draftsDirectoryName, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [URL] = []
        while let item = enumerator.nextObject() as? URL {
            guard item.pathExtension.lowercased() == "md" else { continue }
            let values = try? item.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == false { continue }
            found.append(item.standardizedFileURL)
        }
        return found.sorted { $0.path < $1.path }
    }

    // MARK: Decoding and error text

    static func readData(_ url: URL, name: String) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw StudioError("\(name): could not read: \(error.localizedDescription)")
        }
    }

    /// Decodes with OnboardingJSON and rewraps any failure as
    /// `StudioError("<file>: <reason>")` in the reference validator's wording.
    static func decode<T: Decodable>(_ type: T.Type, from data: Data, file: String) throws -> T {
        do {
            return try OnboardingJSON.decoder().decode(type, from: data)
        } catch {
            throw StudioError("\(file): \(describe(error))")
        }
    }

    /// Human-readable reason for a decode failure: "invalid JSON: ...",
    /// "missing required key 'headSHA' at repo", "wrong type at counts/facts: ...".
    static func describe(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else {
            return error.localizedDescription
        }
        switch decodingError {
        case .keyNotFound(let key, let context):
            let location = pathText(context.codingPath)
            return "missing required key '\(key.stringValue)'" + (location.isEmpty ? "" : " at \(location)")
        case .typeMismatch(_, let context):
            let location = pathText(context.codingPath)
            return "wrong type" + (location.isEmpty ? "" : " at \(location)") + ": \(context.debugDescription)"
        case .valueNotFound(let type, let context):
            let location = pathText(context.codingPath)
            return "null where \(type) was expected" + (location.isEmpty ? "" : " at \(location)")
        case .dataCorrupted(let context):
            let location = pathText(context.codingPath)
            if location.isEmpty, context.underlyingError != nil {
                // JSONDecoder reports a syntax error as dataCorrupted at the root.
                return "invalid JSON: \(context.debugDescription)"
            }
            return (location.isEmpty ? "" : "at \(location): ") + context.debugDescription
        @unknown default:
            return decodingError.localizedDescription
        }
    }

    /// Splits a reader error of the shape `<file>: <reason>` into its parts,
    /// but only when the prefix names a location this reader produces
    /// (a required or optional file, `traces/<id>.json`, or `facts.jsonl:<n>`).
    /// A caller printing a report can then say `ERROR   facts.jsonl: file missing`
    /// like the reference validator instead of naming the packet directory.
    /// Returns nil for any other message, so the caller keeps its own wording.
    static func splitFileReason(_ text: String) -> (file: String, reason: String)? {
        guard let separator = text.range(of: ": ") else { return nil }
        let file = String(text[text.startIndex..<separator.lowerBound])
        let reason = String(text[separator.upperBound...])
        guard !reason.isEmpty, isKnownLocation(file) else { return nil }
        return (file, reason)
    }

    /// True for the `where` strings `load` puts in front of a failure.
    static func isKnownLocation(_ file: String) -> Bool {
        if requiredFiles.contains(file) || optionalFiles.contains(file) { return true }
        if file.hasPrefix(PacketTrace.directoryName + "/"), file.hasSuffix(".json") { return true }
        let factsPrefix = PacketFact.fileName + ":"
        if file.hasPrefix(factsPrefix) {
            let line = file.dropFirst(factsPrefix.count)
            return !line.isEmpty && line.allSatisfy { $0.isNumber }
        }
        return false
    }

    /// "repo/headSHA", "topLevel/[2]/path" in the reference validator's slash style.
    static func pathText(_ codingPath: [CodingKey]) -> String {
        codingPath.map { key -> String in
            if let index = key.intValue { return "[\(index)]" }
            return key.stringValue
        }.joined(separator: "/")
    }
}
