// AgentTranscript.swift — "Onboard to a Codebase", milestone M6 (LLM runtime).
//
// `units/<id>/transcript.jsonl`: the append-only record of one unit's conversation,
// and the only thing resume reads (ARCHITECTURE 4.6). One line per history append
// plus one per request, flushed before the next request goes out, so a session
// killed between any two bytes resumes at a turn boundary rather than losing the
// unit.
//
// Deviation from 4.6 point 2, deliberate: that line says the request entry stores
// the "full body". It stores the envelope and the body's hash instead. The body
// *is* the history, and the history is already recorded losslessly by the message
// entries — writing it again every turn makes the file quadratic in turn count
// (a 40-turn unit over a 100 KB dossier would write 4 MB to say nothing new).
// Everything the audit needs that is not in the history — model, effort, stream,
// max_tokens, the tool names, the system prefix hash, the redacted header names —
// is recorded, and the hash proves which bytes were sent.

import Foundation

/// One line of transcript.jsonl.
///
/// A discriminated record rather than an enum with associated values: JSONL is read
/// by a Python skill and by eye as often as by this decoder, and `{"kind": "reply"}`
/// is legible in both places where a Swift enum's encoding would not be.
struct TranscriptEntry: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// A request about to be sent.
        case request
        /// An assistant turn, with how it ended and what it cost.
        case reply
        /// A user turn appended to history: the instructions, tool results, a nudge.
        case user
        /// A notice worth keeping next to the conversation that produced it.
        case note
        /// The unit ended, with its summary.
        case finish
    }

    var kind: Kind
    var ts: Date = OnboardingJSON.now()
    var turn: Int = 0
    var message: AgentMessage? = nil
    var model: String? = nil
    var promptName: String? = nil
    var stream: Bool? = nil
    var maxTokens: Int? = nil
    var effort: String? = nil
    var toolNames: [String]? = nil
    /// SHA-256 of the system blocks, so a cache miss caused by an edited prefix is
    /// provable after the fact rather than guessed at.
    var systemHash: String? = nil
    var bodyHash: String? = nil
    /// Header *names* only. The values include the API key and are never written
    /// anywhere, by anything.
    var headersRedacted: [String]? = nil
    var stopReason: String? = nil
    var usage: OnboardingUsage? = nil
    var ms: Int? = nil
    var text: String? = nil

    init(kind: Kind) {
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case kind, ts, turn, message, model, promptName, stream, maxTokens, effort
        case toolNames, systemHash, bodyHash, headersRedacted, stopReason, usage, ms, text
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(Kind.self, forKey: .kind) ?? .note
        ts = try c.decodeIfPresent(Date.self, forKey: .ts) ?? Date(timeIntervalSince1970: 0)
        turn = try c.decodeIfPresent(Int.self, forKey: .turn) ?? 0
        message = try c.decodeIfPresent(AgentMessage.self, forKey: .message)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        promptName = try c.decodeIfPresent(String.self, forKey: .promptName)
        stream = try c.decodeIfPresent(Bool.self, forKey: .stream)
        maxTokens = try c.decodeIfPresent(Int.self, forKey: .maxTokens)
        effort = try c.decodeIfPresent(String.self, forKey: .effort)
        toolNames = try c.decodeIfPresent([String].self, forKey: .toolNames)
        systemHash = try c.decodeIfPresent(String.self, forKey: .systemHash)
        bodyHash = try c.decodeIfPresent(String.self, forKey: .bodyHash)
        headersRedacted = try c.decodeIfPresent([String].self, forKey: .headersRedacted)
        stopReason = try c.decodeIfPresent(String.self, forKey: .stopReason)
        usage = try c.decodeIfPresent(OnboardingUsage.self, forKey: .usage)
        ms = try c.decodeIfPresent(Int.self, forKey: .ms)
        text = try c.decodeIfPresent(String.self, forKey: .text)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(ts, forKey: .ts)
        try c.encode(turn, forKey: .turn)
        try c.encodeIfPresent(message, forKey: .message)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encodeIfPresent(promptName, forKey: .promptName)
        try c.encodeIfPresent(stream, forKey: .stream)
        try c.encodeIfPresent(maxTokens, forKey: .maxTokens)
        try c.encodeIfPresent(effort, forKey: .effort)
        try c.encodeIfPresent(toolNames, forKey: .toolNames)
        try c.encodeIfPresent(systemHash, forKey: .systemHash)
        try c.encodeIfPresent(bodyHash, forKey: .bodyHash)
        try c.encodeIfPresent(headersRedacted, forKey: .headersRedacted)
        try c.encodeIfPresent(stopReason, forKey: .stopReason)
        try c.encodeIfPresent(usage, forKey: .usage)
        try c.encodeIfPresent(ms, forKey: .ms)
        try c.encodeIfPresent(text, forKey: .text)
    }
}

/// A tool call recorded in history whose result was never recorded.
struct PendingToolUse: Equatable, Sendable {
    var id: String
    var name: String
    var input: [String: JSONValue]
}

/// Where a unit should pick up.
enum AgentResume: Equatable, Sendable {
    /// Nothing usable recorded: start from the unit's instructions.
    case fresh
    /// The last recorded turn is the user's: send it again, unchanged.
    case resend(history: [AgentMessage])
    /// The last recorded turn is the assistant's and its tool calls have no
    /// results: run exactly those tools and carry on. Safe because the read-only
    /// tools are deterministic, `emit_fact` and `emit_artifact` are idempotent by
    /// id, and command output is cached by (unitId, toolUseId) and never re-run.
    case reexecuteTools(history: [AgentMessage], pending: [PendingToolUse])
    /// The last recorded turn is the assistant's with nothing pending — a session
    /// that died between an assistant turn and the user turn that answers it.
    /// Nudge and continue.
    ///
    /// Note what this case is *not*: finished. An assistant turn with no tool calls
    /// and no recorded `finish` is a unit that stopped talking, not a unit that
    /// reported its coverage. Treating it as complete would invent coverage data
    /// nobody produced, which is the one failure this whole packet contract exists
    /// to prevent.
    case continueTurn(history: [AgentMessage])
    /// The unit called `finish`; there is nothing to resume.
    case finished(history: [AgentMessage], summary: String)

    var history: [AgentMessage] {
        switch self {
        case .fresh: return []
        case .resend(let history): return history
        case .reexecuteTools(let history, _): return history
        case .continueTurn(let history): return history
        case .finished(let history, _): return history
        }
    }
}

/// Reads and appends one unit's transcript.
struct AgentTranscript {
    let store: PackageStore
    let unitId: String

    init(store: PackageStore, unitId: String) {
        self.store = store
        self.unitId = unitId
    }

    var relativePath: String { "units/\(unitId)/transcript.jsonl" }

    /// Appends one line and returns only once it is on disk.
    ///
    /// The flush is the contract (ARCHITECTURE 4.6 point 2): the next request is not
    /// sent until this line is written, so there is no state the API knows about
    /// and the transcript does not.
    func append(_ entry: TranscriptEntry) throws {
        var safe = entry
        safe.text = entry.text.map { BuildLog.redact($0) }
        let data = try OnboardingJSON.lineEncoder().encode(safe)
        guard var line = String(data: data, encoding: .utf8) else {
            throw StudioError("Could not encode a transcript entry for unit \(unitId).")
        }
        line = line.replacingOccurrences(of: "\n", with: " ") + "\n"
        let target = store.url(relativePath)
        let directory = target.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bytes = Data(line.utf8)
        if !FileManager.default.fileExists(atPath: target.path) {
            try bytes.write(to: target)
            return
        }
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: bytes)
        try handle.synchronize()
    }

    /// Every entry on disk. A malformed line is skipped with a warning rather than
    /// failing the read: one corrupt line (a half-written record from a hard kill)
    /// must not cost the forty turns before it.
    func entries() -> [TranscriptEntry] {
        guard let text = try? store.readString(relativePath) else { return [] }
        let decoder = OnboardingJSON.decoder()
        var out: [TranscriptEntry] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { continue }
            if let entry = try? decoder.decode(TranscriptEntry.self, from: data) {
                out.append(entry)
            } else {
                BuildLog.warn("skipped a malformed transcript line in \(relativePath)")
            }
        }
        return out
    }

    func resumePlan() -> AgentResume {
        AgentTranscript.plan(from: entries())
    }

    /// The resume rules of ARCHITECTURE 4.6 point 4, as one function over the
    /// recorded entries, so `agentResumeProbe` can assert all five outcomes without
    /// a transport, a key or a package.
    static func plan(from entries: [TranscriptEntry]) -> AgentResume {
        var history: [AgentMessage] = []
        var finishSummary: String? = nil
        for entry in entries {
            switch entry.kind {
            case .user, .reply:
                if let message = entry.message { history.append(message) }
            case .finish:
                finishSummary = entry.text ?? ""
            case .request, .note:
                break
            }
        }
        if let finishSummary {
            return .finished(history: history, summary: finishSummary)
        }
        guard let last = history.last else { return .fresh }
        if last.role == .user {
            return .resend(history: history)
        }
        let answered = AgentTranscript.answeredToolUseIds(history)
        let pending = last.content.compactMap { $0.toolUse }
            .filter { !answered.contains($0.id) }
            .map { PendingToolUse(id: $0.id, name: $0.name, input: $0.input) }
        if pending.isEmpty {
            return .continueTurn(history: history)
        }
        return .reexecuteTools(history: history, pending: pending)
    }

    /// Every `tool_use_id` that some later user turn answered.
    ///
    /// Checked rather than assumed: a crash between writing the assistant turn and
    /// writing the tool results is the ordinary case, but a crash *during* the user
    /// turn's own append is also possible, and re-running a tool whose result is
    /// already recorded would duplicate its side effects.
    static func answeredToolUseIds(_ history: [AgentMessage]) -> Set<String> {
        var out: Set<String> = []
        for message in history where message.role == .user {
            for block in message.content where block.type == "tool_result" {
                if let id = block.raw["tool_use_id"]?.stringValue { out.insert(id) }
            }
        }
        return out
    }
}
