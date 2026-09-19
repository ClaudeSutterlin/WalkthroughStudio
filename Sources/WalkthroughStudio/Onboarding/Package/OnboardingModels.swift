// OnboardingModels.swift — "Onboard to a Codebase", milestone M2 (package format).
//
// The Codable records that live at the root of an onboarding package:
// manifest.json (OnboardingManifest, ARCHITECTURE.md 2.3), checkpoint.json
// (WorkPlan / WorkUnit, 2.4), plus the notice and stage enums the pipeline and
// the UI share. Every type has an EXPLICIT init(from:) and encode(to:), never
// synthesized Codable: unknown keys are ignored, a missing optional decodes as
// nil, a missing non-optional falls back to its default (the BrandTheme lesson
// in CLAUDE.md: a decode-only key silently breaks synthesized encoding).
// All JSON goes through OnboardingJSON so dates are ISO 8601 and keys are sorted.

import Foundation

// MARK: - Shared JSON configuration

enum OnboardingJSON {
    /// Pretty, sorted, ISO 8601 dates. Used for every *.json in a package.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, valueEncoder in
            var container = valueEncoder.singleValueContainer()
            try container.encode(OnboardingJSON.iso8601String(from: date))
        }
        return encoder
    }

    /// Single-line variant for JSONL files (facts, build-log records).
    static func lineEncoder() -> JSONEncoder {
        let compact = OnboardingJSON.encoder()
        compact.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return compact
    }

    /// Accepts ISO 8601 with or without fractional seconds (other producers,
    /// e.g. a Python skill, tend to write fractions).
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { valueDecoder in
            let container = try valueDecoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = OnboardingJSON.date(fromISO8601: raw) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO 8601 date: \(raw)")
            }
            return date
        }
        return decoder
    }

    static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    static func date(fromISO8601 raw: String) -> Date? {
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: raw) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: raw)
    }

    /// `Date()` truncated to whole seconds, so a freshly created record
    /// round-trips through ISO 8601 as an equal value.
    static func now() -> Date {
        Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    }
}

// MARK: - Enums

enum OnboardingStatus: String, Codable, CaseIterable {
    case planning, running, paused, complete, partial, failed
}

enum DeliverableKind: String, Codable, CaseIterable {
    case video, doc, diagram, trace, hub
}

enum DeliverableStatus: String, Codable, CaseIterable {
    case pending, built, stale, accepted, fix, rejected
}

enum WorkUnitStatus: String, Codable, CaseIterable {
    case pending, running, done, failed, skipped
}

/// Pipeline stages in order; FleetProgressView and the hub show the current one.
enum OnboardingStage: String, Codable, CaseIterable, Comparable {
    case acquire, survey, research, verify, synthesize, project, render, hub, complete

    var label: String {
        switch self {
        case .acquire: return "Acquiring repository"
        case .survey: return "Surveying"
        case .research: return "Researching"
        case .verify: return "Verifying facts"
        case .synthesize: return "Synthesizing"
        case .project: return "Projecting diagrams and registers"
        case .render: return "Rendering videos"
        case .hub: return "Building the hub"
        case .complete: return "Complete"
        }
    }

    /// 0-based position in the pipeline.
    var ordinal: Int { OnboardingStage.allCases.firstIndex(of: self) ?? 0 }

    static func < (lhs: OnboardingStage, rhs: OnboardingStage) -> Bool { lhs.ordinal < rhs.ordinal }
}

// MARK: - Token usage (shared by manifest.spent, WorkUnit.usage and byModel)

struct OnboardingUsage: Codable, Equatable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheWriteTokens: Int = 0
    var usd: Double = 0

    init() {}

    init(inputTokens: Int, outputTokens: Int, cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0, usd: Double = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.usd = usd
    }

    private enum CodingKeys: String, CodingKey {
        case inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, usd
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        cacheReadTokens = try c.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0
        cacheWriteTokens = try c.decodeIfPresent(Int.self, forKey: .cacheWriteTokens) ?? 0
        usd = try c.decodeIfPresent(Double.self, forKey: .usd) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(inputTokens, forKey: .inputTokens)
        try c.encode(outputTokens, forKey: .outputTokens)
        try c.encode(cacheReadTokens, forKey: .cacheReadTokens)
        try c.encode(cacheWriteTokens, forKey: .cacheWriteTokens)
        try c.encode(usd, forKey: .usd)
    }

    mutating func add(_ other: OnboardingUsage) {
        inputTokens += other.inputTokens
        outputTokens += other.outputTokens
        cacheReadTokens += other.cacheReadTokens
        cacheWriteTokens += other.cacheWriteTokens
        usd += other.usd
    }
}

// MARK: - manifest.json

struct OnboardingManifest: Codable, Equatable {
    static let currentVersion = 1
    static let fileName = "manifest.json"

    var version: Int = OnboardingManifest.currentVersion
    /// Remote URL the package was made from; empty for a purely local clone.
    var repoURL: String = ""
    /// "repo" (the package's own pinned checkout) or the absolute path of the
    /// user's clone when they supplied one.
    var localClone: String = "repo"
    var headSHA: String = ""
    var defaultBranch: String = "main"
    var createdAt: Date = OnboardingJSON.now()
    /// D18: "complete" is the default and means everything the evidence supports.
    var scope: String = "complete"
    var models = Models()
    var narration = Narration()
    var budget = Budget()
    var spent = Spend()
    var status: OnboardingStatus = .planning
    var unproduced: [String] = []
    var coverage = Coverage()
    var deliverables: [Deliverable] = []
    var edges: [Edge] = []
    /// Who wrote the Research Packet this package was built from (section 15).
    var producer: Producer? = nil
    /// Optional project briefing (PDF/markdown) that grounds generated copy.
    var briefingPath: String? = nil

    init() {}

    private enum CodingKeys: String, CodingKey {
        case version, repoURL, localClone, headSHA, defaultBranch, createdAt, scope
        case models, narration, budget, spent, status, unproduced, coverage
        case deliverables, edges, producer, briefingPath
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = OnboardingManifest()
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? d.version
        repoURL = try c.decodeIfPresent(String.self, forKey: .repoURL) ?? d.repoURL
        localClone = try c.decodeIfPresent(String.self, forKey: .localClone) ?? d.localClone
        headSHA = try c.decodeIfPresent(String.self, forKey: .headSHA) ?? d.headSHA
        defaultBranch = try c.decodeIfPresent(String.self, forKey: .defaultBranch) ?? d.defaultBranch
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? d.createdAt
        scope = try c.decodeIfPresent(String.self, forKey: .scope) ?? d.scope
        models = try c.decodeIfPresent(Models.self, forKey: .models) ?? d.models
        narration = try c.decodeIfPresent(Narration.self, forKey: .narration) ?? d.narration
        budget = try c.decodeIfPresent(Budget.self, forKey: .budget) ?? d.budget
        spent = try c.decodeIfPresent(Spend.self, forKey: .spent) ?? d.spent
        status = try c.decodeIfPresent(OnboardingStatus.self, forKey: .status) ?? d.status
        unproduced = try c.decodeIfPresent([String].self, forKey: .unproduced) ?? d.unproduced
        coverage = try c.decodeIfPresent(Coverage.self, forKey: .coverage) ?? d.coverage
        deliverables = try c.decodeIfPresent([Deliverable].self, forKey: .deliverables) ?? d.deliverables
        edges = try c.decodeIfPresent([Edge].self, forKey: .edges) ?? d.edges
        producer = try c.decodeIfPresent(Producer.self, forKey: .producer)
        briefingPath = try c.decodeIfPresent(String.self, forKey: .briefingPath)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(repoURL, forKey: .repoURL)
        try c.encode(localClone, forKey: .localClone)
        try c.encode(headSHA, forKey: .headSHA)
        try c.encode(defaultBranch, forKey: .defaultBranch)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(scope, forKey: .scope)
        try c.encode(models, forKey: .models)
        try c.encode(narration, forKey: .narration)
        try c.encode(budget, forKey: .budget)
        try c.encode(spent, forKey: .spent)
        try c.encode(status, forKey: .status)
        try c.encode(unproduced, forKey: .unproduced)
        try c.encode(coverage, forKey: .coverage)
        try c.encode(deliverables, forKey: .deliverables)
        try c.encode(edges, forKey: .edges)
        try c.encodeIfPresent(producer, forKey: .producer)
        try c.encodeIfPresent(briefingPath, forKey: .briefingPath)
    }

    /// Deliverable by id, e.g. "video:arch-overview".
    func deliverable(id: String) -> Deliverable? {
        deliverables.first(where: { $0.id == id })
    }

    // MARK: Nested records

    struct Models: Codable, Equatable {
        var planner: String = "claude-opus-5"
        var worker: String = "claude-sonnet-5"
        /// Gateway model id that replaces both when non-empty (see SettingsKeys.anthropicModelOverride).
        var `override`: String = ""

        init() {}

        private enum CodingKeys: String, CodingKey { case planner, worker, `override` }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Models()
            planner = try c.decodeIfPresent(String.self, forKey: .planner) ?? d.planner
            worker = try c.decodeIfPresent(String.self, forKey: .worker) ?? d.worker
            `override` = try c.decodeIfPresent(String.self, forKey: .override) ?? d.override
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(planner, forKey: .planner)
            try c.encode(worker, forKey: .worker)
            try c.encode(`override`, forKey: .override)
        }
    }

    struct Narration: Codable, Equatable {
        var voiceID: String = Defaults.elevenVoiceID
        var modelID: String = ""
        /// "provider-words" (ElevenLabs alignment) or "sentence-estimate".
        var timingSource: String = "sentence-estimate"

        init() {}

        private enum CodingKeys: String, CodingKey { case voiceID, modelID, timingSource }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Narration()
            voiceID = try c.decodeIfPresent(String.self, forKey: .voiceID) ?? d.voiceID
            modelID = try c.decodeIfPresent(String.self, forKey: .modelID) ?? d.modelID
            timingSource = try c.decodeIfPresent(String.self, forKey: .timingSource) ?? d.timingSource
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(voiceID, forKey: .voiceID)
            try c.encode(modelID, forKey: .modelID)
            try c.encode(timingSource, forKey: .timingSource)
        }
    }

    struct Budget: Codable, Equatable {
        /// nil = no spend cap (D18).
        var capUSD: Double? = nil

        init() {}
        init(capUSD: Double?) { self.capUSD = capUSD }

        private enum CodingKeys: String, CodingKey { case capUSD }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            capUSD = try c.decodeIfPresent(Double.self, forKey: .capUSD)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(capUSD, forKey: .capUSD)
        }
    }

    struct Spend: Codable, Equatable {
        var inputTokens: Int = 0
        var outputTokens: Int = 0
        var cacheReadTokens: Int = 0
        var cacheWriteTokens: Int = 0
        var usd: Double = 0
        var byModel: [String: OnboardingUsage] = [:]

        init() {}

        private enum CodingKeys: String, CodingKey {
            case inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, usd, byModel
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
            outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
            cacheReadTokens = try c.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0
            cacheWriteTokens = try c.decodeIfPresent(Int.self, forKey: .cacheWriteTokens) ?? 0
            usd = try c.decodeIfPresent(Double.self, forKey: .usd) ?? 0
            byModel = try c.decodeIfPresent([String: OnboardingUsage].self, forKey: .byModel) ?? [:]
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(inputTokens, forKey: .inputTokens)
            try c.encode(outputTokens, forKey: .outputTokens)
            try c.encode(cacheReadTokens, forKey: .cacheReadTokens)
            try c.encode(cacheWriteTokens, forKey: .cacheWriteTokens)
            try c.encode(usd, forKey: .usd)
            try c.encode(byModel, forKey: .byModel)
        }

        /// Adds one request's usage to the totals and to its model's bucket.
        mutating func add(_ usage: OnboardingUsage, model: String) {
            inputTokens += usage.inputTokens
            outputTokens += usage.outputTokens
            cacheReadTokens += usage.cacheReadTokens
            cacheWriteTokens += usage.cacheWriteTokens
            usd += usage.usd
            var bucket = byModel[model] ?? OnboardingUsage()
            bucket.add(usage)
            byModel[model] = bucket
        }
    }

    struct Coverage: Codable, Equatable {
        var unreadDirs: [UnreadDir] = []
        var skippedChecks: [SkippedCheck] = []

        init() {}

        private enum CodingKeys: String, CodingKey { case unreadDirs, skippedChecks }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            unreadDirs = try c.decodeIfPresent([UnreadDir].self, forKey: .unreadDirs) ?? []
            skippedChecks = try c.decodeIfPresent([SkippedCheck].self, forKey: .skippedChecks) ?? []
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(unreadDirs, forKey: .unreadDirs)
            try c.encode(skippedChecks, forKey: .skippedChecks)
        }

        struct UnreadDir: Codable, Equatable {
            var path: String
            var reason: String

            init(path: String, reason: String) {
                self.path = path
                self.reason = reason
            }

            private enum CodingKeys: String, CodingKey { case path, reason }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
                reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(path, forKey: .path)
                try c.encode(reason, forKey: .reason)
            }
        }

        struct SkippedCheck: Codable, Equatable {
            var check: String
            var reason: String

            init(check: String, reason: String) {
                self.check = check
                self.reason = reason
            }

            private enum CodingKeys: String, CodingKey { case check, reason }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                check = try c.decodeIfPresent(String.self, forKey: .check) ?? ""
                reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(check, forKey: .check)
                try c.encode(reason, forKey: .reason)
            }
        }
    }

    struct Deliverable: Codable, Equatable, Identifiable {
        /// "video:arch-overview", "doc:tech-debt", ... (kind prefix + slug).
        var id: String
        var kind: DeliverableKind
        var title: String = ""
        /// Package-relative directory or file, e.g. "videos/arch-overview".
        var path: String = ""
        /// Docs: words / 220; videos: duration / 60.
        var minutes: Double = 0
        /// Recommended viewing order (1-based).
        var order: Int = 0
        var status: DeliverableStatus = .pending
        /// sha256 over the inputs this deliverable was built from (staleness).
        var inputsHash: String = ""
        var producedBy: String = ""

        init(id: String, kind: DeliverableKind, title: String = "", path: String = "") {
            self.id = id
            self.kind = kind
            self.title = title
            self.path = path
        }

        private enum CodingKeys: String, CodingKey {
            case id, kind, title, path, minutes, order, status, inputsHash, producedBy
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            kind = try c.decodeIfPresent(DeliverableKind.self, forKey: .kind) ?? .doc
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
            minutes = try c.decodeIfPresent(Double.self, forKey: .minutes) ?? 0
            order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
            status = try c.decodeIfPresent(DeliverableStatus.self, forKey: .status) ?? .pending
            inputsHash = try c.decodeIfPresent(String.self, forKey: .inputsHash) ?? ""
            producedBy = try c.decodeIfPresent(String.self, forKey: .producedBy) ?? ""
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(kind, forKey: .kind)
            try c.encode(title, forKey: .title)
            try c.encode(path, forKey: .path)
            try c.encode(minutes, forKey: .minutes)
            try c.encode(order, forKey: .order)
            try c.encode(status, forKey: .status)
            try c.encode(inputsHash, forKey: .inputsHash)
            try c.encode(producedBy, forKey: .producedBy)
        }
    }

    /// A dependency edge: `from` is an anchor string (usually `fact:<id>`),
    /// `to` is a deliverable id. Kept as strings because deliverable ids share
    /// the kind prefix but are not anchors (no slug/fragment).
    struct Edge: Codable, Equatable, Hashable {
        var from: String
        var to: String

        init(from: String, to: String) {
            self.from = from
            self.to = to
        }

        private enum CodingKeys: String, CodingKey { case from, to }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            from = try c.decodeIfPresent(String.self, forKey: .from) ?? ""
            to = try c.decodeIfPresent(String.self, forKey: .to) ?? ""
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(from, forKey: .from)
            try c.encode(to, forKey: .to)
        }
    }

    struct Producer: Codable, Equatable {
        /// "claude-code-skill", "walkthrough-studio-fleet", ...
        var name: String
        var version: String = ""
        var model: String? = nil
        var finishedAt: Date? = nil

        init(name: String, version: String = "", model: String? = nil, finishedAt: Date? = nil) {
            self.name = name
            self.version = version
            self.model = model
            self.finishedAt = finishedAt
        }

        private enum CodingKeys: String, CodingKey { case name, version, model, finishedAt }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            version = try c.decodeIfPresent(String.self, forKey: .version) ?? ""
            model = try c.decodeIfPresent(String.self, forKey: .model)
            finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(version, forKey: .version)
            try c.encodeIfPresent(model, forKey: .model)
            try c.encodeIfPresent(finishedAt, forKey: .finishedAt)
        }
    }
}

// MARK: - checkpoint.json

struct WorkPlan: Codable, Equatable {
    static let currentVersion = 1
    static let fileName = "checkpoint.json"

    var version: Int = WorkPlan.currentVersion
    var sessionId: UUID = UUID()
    var units: [WorkUnit] = []

    init() {}

    init(sessionId: UUID, units: [WorkUnit]) {
        self.sessionId = sessionId
        self.units = units
    }

    private enum CodingKeys: String, CodingKey { case version, sessionId, units }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? WorkPlan.currentVersion
        if let raw = try c.decodeIfPresent(String.self, forKey: .sessionId), let parsed = UUID(uuidString: raw) {
            sessionId = parsed
        } else {
            sessionId = UUID()
        }
        units = try c.decodeIfPresent([WorkUnit].self, forKey: .units) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(sessionId.uuidString, forKey: .sessionId)
        try c.encode(units, forKey: .units)
    }

    func unit(id: String) -> WorkUnit? {
        units.first(where: { $0.id == id })
    }

    /// Replaces the unit with the same id, or appends it.
    mutating func upsert(_ unit: WorkUnit) {
        if let index = units.firstIndex(where: { $0.id == unit.id }) {
            units[index] = unit
        } else {
            units.append(unit)
        }
    }
}

struct WorkUnit: Codable, Equatable, Identifiable {
    var id: String
    /// "acquire", "inventory", "gitmine", "map", "lens", "verify", "trace", ...
    var kind: String
    /// "planner" or "worker" (which model runs it), "deterministic" for no-LLM units.
    var role: String = "worker"
    /// Ids of the units whose outputs this one reads.
    var inputs: [String] = []
    var params: [String: String] = [:]
    var status: WorkUnitStatus = .pending
    var attempt: Int = 0
    var maxTurns: Int = 40
    /// sha256 of the inputs' outputs at the time this unit ran (resume/staleness).
    var inputsHash: String = ""
    /// sha256 of this unit's outputs when it finished.
    var outputHash: String = ""
    /// Package-relative paths this unit wrote.
    var outputs: [String] = []
    var usage = OnboardingUsage()
    var startedAt: Date? = nil
    var finishedAt: Date? = nil
    var error: String? = nil

    init(id: String, kind: String, role: String = "worker", inputs: [String] = [], params: [String: String] = [:]) {
        self.id = id
        self.kind = kind
        self.role = role
        self.inputs = inputs
        self.params = params
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, role, inputs, params, status, attempt, maxTurns
        case inputsHash, outputHash, outputs, usage, startedAt, finishedAt, error
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? "worker"
        inputs = try c.decodeIfPresent([String].self, forKey: .inputs) ?? []
        params = try c.decodeIfPresent([String: String].self, forKey: .params) ?? [:]
        status = try c.decodeIfPresent(WorkUnitStatus.self, forKey: .status) ?? .pending
        attempt = try c.decodeIfPresent(Int.self, forKey: .attempt) ?? 0
        maxTurns = try c.decodeIfPresent(Int.self, forKey: .maxTurns) ?? 40
        inputsHash = try c.decodeIfPresent(String.self, forKey: .inputsHash) ?? ""
        outputHash = try c.decodeIfPresent(String.self, forKey: .outputHash) ?? ""
        outputs = try c.decodeIfPresent([String].self, forKey: .outputs) ?? []
        usage = try c.decodeIfPresent(OnboardingUsage.self, forKey: .usage) ?? OnboardingUsage()
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try c.decodeIfPresent(Date.self, forKey: .finishedAt)
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(kind, forKey: .kind)
        try c.encode(role, forKey: .role)
        try c.encode(inputs, forKey: .inputs)
        try c.encode(params, forKey: .params)
        try c.encode(status, forKey: .status)
        try c.encode(attempt, forKey: .attempt)
        try c.encode(maxTurns, forKey: .maxTurns)
        try c.encode(inputsHash, forKey: .inputsHash)
        try c.encode(outputHash, forKey: .outputHash)
        try c.encode(outputs, forKey: .outputs)
        try c.encode(usage, forKey: .usage)
        try c.encodeIfPresent(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(finishedAt, forKey: .finishedAt)
        try c.encodeIfPresent(error, forKey: .error)
    }
}

// MARK: - Notices (the onboarding counterpart of pipelineNotice)

struct OnboardingNotice: Codable, Equatable, Hashable, Identifiable {
    var id: String = UUID().uuidString
    var message: String
    /// Unit that can be re-run to clear this notice, when there is one.
    var retryUnitId: String? = nil

    init(message: String, retryUnitId: String? = nil) {
        self.message = message
        self.retryUnitId = retryUnitId
    }

    private enum CodingKeys: String, CodingKey { case id, message, retryUnitId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        retryUnitId = try c.decodeIfPresent(String.self, forKey: .retryUnitId)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(message, forKey: .message)
        try c.encodeIfPresent(retryUnitId, forKey: .retryUnitId)
    }
}
