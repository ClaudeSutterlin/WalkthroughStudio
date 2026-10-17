// MessagesAPI.swift — "Onboard to a Codebase", milestone M6 (LLM runtime).
//
// The wire model for `POST /v1/messages`, per D1: a native Swift tool-use loop
// over raw HTTP. There is no official Anthropic Swift SDK, and the rejected
// alternatives (a Claude Code CLI subprocess, Managed Agents) could not use the
// Keychain key or the gateway endpoint this app already promises, nor run under a
// fixture transport in the headless selftest.
//
// One rule shapes every type here: **an assistant turn goes back to the API
// verbatim.** A thinking block carries a `signature` the server verifies, and a
// block type this build has never heard of (a server tool call, a search result)
// still has to survive the round trip untouched. So `ContentBlock` is the raw JSON
// object with typed accessors over the top, not a closed enum of the blocks we
// happen to know about today. Everything that *is* modelled — request fields,
// usage, stop reasons — is modelled exactly, because that is what the loop
// branches on.
//
// Nothing in this file touches the network (see Transport.swift) or decides
// anything about a turn (see AgentRun.swift). It is the shape of the bytes.

import Foundation

// MARK: - Content blocks

/// One content block, kept as its own JSON object.
///
/// `raw` is the whole block: `{"type": "text", "text": "…"}`,
/// `{"type": "thinking", "thinking": "…", "signature": "…"}`,
/// `{"type": "tool_use", "id": "toolu_…", "name": "read_file", "input": {…}}`.
/// Re-encoding a block produces the same object the API sent, which is what the
/// preserved-thinking rule (ARCHITECTURE 4.2) requires.
struct ContentBlock: Codable, Equatable, Sendable {
    var raw: [String: JSONValue]

    init(raw: [String: JSONValue]) {
        self.raw = raw
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        raw = try container.decode([String: JSONValue].self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }

    // MARK: Accessors

    var type: String { raw["type"]?.stringValue ?? "" }

    /// The text of a `text` block. Nil for every other type, so joining the text of
    /// a turn never accidentally includes a thinking block's contents.
    var text: String? {
        guard type == "text" else { return nil }
        return raw["text"]?.stringValue
    }

    var thinkingText: String? {
        guard type == "thinking" else { return nil }
        return raw["thinking"]?.stringValue
    }

    var isThinking: Bool { type == "thinking" || type == "redacted_thinking" }
    var isToolUse: Bool { type == "tool_use" }

    /// A tool call, or nil if this is not one. The input is the parsed object —
    /// tool inputs are read through JSONSerialization/Codable and never
    /// string-matched (ARCHITECTURE 4.2).
    var toolUse: (id: String, name: String, input: [String: JSONValue])? {
        guard type == "tool_use",
              let id = raw["id"]?.stringValue,
              let name = raw["name"]?.stringValue else { return nil }
        return (id, name, raw["input"]?.objectValue ?? [:])
    }

    // MARK: Constructors

    static func text(_ value: String) -> ContentBlock {
        ContentBlock(raw: ["type": .string("text"), "text": .string(value)])
    }

    static func toolCall(id: String, name: String, input: [String: JSONValue]) -> ContentBlock {
        ContentBlock(raw: [
            "type": .string("tool_use"),
            "id": .string(id),
            "name": .string(name),
            "input": .object(input),
        ])
    }

    /// A tool result. `is_error: true` is emitted only when the tool failed —
    /// a failing tool reports the failure to the model and is never dropped,
    /// because a tool_use block with no matching result is a protocol error.
    static func toolResult(toolUseId: String, content: String, isError: Bool = false) -> ContentBlock {
        var raw: [String: JSONValue] = [
            "type": .string("tool_result"),
            "tool_use_id": .string(toolUseId),
            "content": .array([.object(["type": .string("text"), "text": .string(content)])]),
        ]
        if isError { raw["is_error"] = .bool(true) }
        return ContentBlock(raw: raw)
    }

    /// A copy carrying a cache breakpoint. Applied when a request is built, never
    /// stored in history: the breakpoint moves forward every turn, and a stored
    /// annotation would pin it to the turn that first wrote it.
    func withCacheControl() -> ContentBlock {
        var copy = self
        copy.raw["cache_control"] = .object(["type": .string("ephemeral")])
        return copy
    }
}

// MARK: - Messages

struct AgentMessage: Codable, Equatable, Sendable {
    enum Role: String, Codable { case user, assistant }

    var role: Role
    var content: [ContentBlock]

    init(role: Role, content: [ContentBlock]) {
        self.role = role
        self.content = content
    }

    static func user(_ text: String) -> AgentMessage {
        AgentMessage(role: .user, content: [.text(text)])
    }

    private enum CodingKeys: String, CodingKey { case role, content }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        role = try c.decodeIfPresent(Role.self, forKey: .role) ?? .user
        content = try c.decodeIfPresent([ContentBlock].self, forKey: .content) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(role, forKey: .role)
        try c.encode(content, forKey: .content)
    }

    var wire: JSONValue {
        .object(["role": .string(role.rawValue), "content": .array(content.map { .object($0.raw) })])
    }
}

// MARK: - Tools

/// A tool as the request declares it. `strict: true` with
/// `additionalProperties: false` and an explicit `required` list is the contract
/// that lets the loop trust an input's shape (ARCHITECTURE 4.2).
struct ToolSpec: Equatable, Sendable {
    var name: String
    var description: String
    /// The JSON Schema object for the tool's input.
    var inputSchema: [String: JSONValue]
    var strict: Bool = true

    init(name: String, description: String, inputSchema: [String: JSONValue], strict: Bool = true) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.strict = strict
    }

    /// A schema for an object tool input: every property required, nothing extra.
    static func schema(_ properties: [String: JSONValue], required: [String]) -> [String: JSONValue] {
        [
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
            "additionalProperties": .bool(false),
        ]
    }

    static func property(_ type: String, _ description: String) -> JSONValue {
        .object(["type": .string(type), "description": .string(description)])
    }

    var wire: JSONValue {
        var object: [String: JSONValue] = [
            "name": .string(name),
            "description": .string(description),
            "input_schema": .object(inputSchema),
        ]
        if strict { object["strict"] = .bool(true) }
        return .object(object)
    }
}

/// `output_config.effort` (ARCHITECTURE 4.2): xhigh for plan, rank-paths and
/// trace; high for compose and script; medium for the playback chat (latency);
/// low for map, lens and verify.
enum AgentEffort: String, Codable, Sendable, CaseIterable {
    case low, medium, high, xhigh
}

// MARK: - Request

/// Everything one `POST /v1/messages` needs.
///
/// `promptName` is not sent: it keys the fixture recordings (D9), so a prompt
/// gets its own replay directory and a turn index within it.
struct MessagesRequest: Equatable, Sendable {
    var promptName: String
    var model: String
    /// System blocks in order: role prompt, package conventions, dossier. The last
    /// one carrying `cacheControl` gets the ephemeral breakpoint.
    var system: [SystemBlock] = []
    var messages: [AgentMessage] = []
    var tools: [ToolSpec] = []
    var maxTokens: Int = 16000
    var stream: Bool = false
    /// `{"type": "adaptive"}` on every request; never `budget_tokens`, never
    /// `temperature` or `top_p` (ARCHITECTURE 4.2).
    var adaptiveThinking: Bool = true
    var effort: AgentEffort? = nil
    /// `output_config.format` — a JSON schema for the units that must return
    /// structured output. Nil in gateway-compat mode, where the schema is
    /// described in the prompt instead and the reply is parsed out of the text.
    var outputFormat: JSONValue? = nil
    /// Marks the last content block of the newest user message with a cache
    /// breakpoint. The breakpoint moves forward each turn; nothing is persisted.
    var cacheLastUserBlock: Bool = true
    /// `anthropic-beta` values. Only ever non-empty on api.anthropic.com with
    /// gateway-compat off (ARCHITECTURE 4.2).
    var betas: [String] = []
    /// `"fallbacks": "default"`, which rides with the server-side-fallback beta.
    var serverSideFallback: Bool = false

    struct SystemBlock: Equatable, Sendable {
        var text: String
        var cacheControl: Bool = false

        init(_ text: String, cacheControl: Bool = false) {
            self.text = text
            self.cacheControl = cacheControl
        }
    }

    init(promptName: String, model: String, maxTokens: Int = 16000, stream: Bool = false) {
        self.promptName = promptName
        self.model = model
        self.maxTokens = maxTokens
        self.stream = stream
    }

    /// The request body as JSON.
    ///
    /// Tools are sorted by name so the cacheable prefix is byte-stable across runs
    /// — an unsorted tool array would miss the cache on every request for no other
    /// reason (ARCHITECTURE 4.2).
    var wire: JSONValue {
        var object: [String: JSONValue] = [
            "model": .string(model),
            "max_tokens": .number(Double(maxTokens)),
            "messages": .array(messagesWire),
        ]
        if !system.isEmpty {
            object["system"] = .array(systemWire)
        }
        if !tools.isEmpty {
            object["tools"] = .array(tools.sorted { $0.name < $1.name }.map { $0.wire })
            // Always `auto`: Fable-class models reject `any` and `tool`, and the
            // instructions name the tool the unit is expected to call instead.
            object["tool_choice"] = .object(["type": .string("auto")])
        }
        if adaptiveThinking {
            object["thinking"] = .object(["type": .string("adaptive")])
        }
        var outputConfig: [String: JSONValue] = [:]
        if let effort { outputConfig["effort"] = .string(effort.rawValue) }
        if let outputFormat { outputConfig["format"] = outputFormat }
        if !outputConfig.isEmpty {
            object["output_config"] = .object(outputConfig)
        }
        if stream { object["stream"] = .bool(true) }
        if serverSideFallback { object["fallbacks"] = .string("default") }
        return .object(object)
    }

    private var systemWire: [JSONValue] {
        system.map { block in
            var object: [String: JSONValue] = ["type": .string("text"), "text": .string(block.text)]
            if block.cacheControl {
                object["cache_control"] = .object(["type": .string("ephemeral")])
            }
            return .object(object)
        }
    }

    /// History, with the moving cache breakpoint applied to the last content block
    /// of the newest user message.
    private var messagesWire: [JSONValue] {
        guard cacheLastUserBlock,
              let index = messages.lastIndex(where: { $0.role == .user }),
              !messages[index].content.isEmpty else {
            return messages.map { $0.wire }
        }
        var copy = messages
        let last = copy[index].content.count - 1
        copy[index].content[last] = copy[index].content[last].withCacheControl()
        return copy.map { $0.wire }
    }

    func body() throws -> Data {
        try MessagesRequest.canonicalJSON(wire)
    }

    /// SHA-256 of the canonical body. A fixture records the hash of the request it
    /// was recorded against; a mismatch warns rather than fails, so editing a
    /// prompt does not break the selftest until the fixtures are re-recorded (D9).
    func bodyHash() -> String {
        guard let data = try? body() else { return "" }
        return PackageStore.sha256Hex(data)
    }

    static func canonicalJSON(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

// MARK: - Response

/// `usage` from a reply. Separate from `OnboardingUsage` because this is the wire
/// shape (snake_case, no cost) and that one is the package's accounting shape.
struct APIUsage: Equatable, Sendable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheWriteTokens: Int = 0

    init() {}

    init(inputTokens: Int, outputTokens: Int, cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
    }

    init(json: [String: JSONValue]) {
        inputTokens = APIUsage.int(json["input_tokens"])
        outputTokens = APIUsage.int(json["output_tokens"])
        cacheReadTokens = APIUsage.int(json["cache_read_input_tokens"])
        cacheWriteTokens = APIUsage.int(json["cache_creation_input_tokens"])
    }

    private static func int(_ value: JSONValue?) -> Int {
        guard let number = value?.numberValue, number.isFinite else { return 0 }
        return Int(number)
    }

    /// Merge a later `usage` over this one, field by field, keeping what the later
    /// one does not mention.
    ///
    /// This is the whole reason streaming usage is fiddly: `message_start` carries
    /// the input and cache numbers and `output_tokens: 1`, and `message_delta`
    /// carries the real `output_tokens` and nothing else. Overwriting wholesale
    /// loses the input tokens (so every streamed request looks free); ignoring the
    /// delta loses the output tokens. Non-zero fields win.
    mutating func merge(_ other: APIUsage) {
        if other.inputTokens != 0 { inputTokens = other.inputTokens }
        if other.outputTokens != 0 { outputTokens = other.outputTokens }
        if other.cacheReadTokens != 0 { cacheReadTokens = other.cacheReadTokens }
        if other.cacheWriteTokens != 0 { cacheWriteTokens = other.cacheWriteTokens }
    }

    /// Billable input: fresh tokens plus cache writes plus cache reads. Used for
    /// the cache hit rate shown in FleetProgressView.
    var totalInput: Int { inputTokens + cacheReadTokens + cacheWriteTokens }
}

/// Why a turn ended. Parsed, not string-matched at the call sites, so a new value
/// from the API lands in `.other` and is handled rather than mistaken for success.
enum StopReason: Equatable, Sendable {
    case endTurn
    case toolUse
    case maxTokens
    case stopSequence
    case refusal
    case pauseTurn
    case other(String)
    case missing

    init(_ raw: String?) {
        guard let raw else {
            self = .missing
            return
        }
        switch raw {
        case "end_turn": self = .endTurn
        case "tool_use": self = .toolUse
        case "max_tokens": self = .maxTokens
        case "stop_sequence": self = .stopSequence
        case "refusal": self = .refusal
        case "pause_turn": self = .pauseTurn
        default: self = .other(raw)
        }
    }

    var wireValue: String? {
        switch self {
        case .endTurn: return "end_turn"
        case .toolUse: return "tool_use"
        case .maxTokens: return "max_tokens"
        case .stopSequence: return "stop_sequence"
        case .refusal: return "refusal"
        case .pauseTurn: return "pause_turn"
        case .other(let value): return value
        case .missing: return nil
        }
    }
}

struct MessagesResponse: Equatable, Sendable {
    var id: String = ""
    var model: String = ""
    var content: [ContentBlock] = []
    var stopReason: StopReason = .missing
    /// `stop_details` may be absent or null even when `stop_reason` is `refusal`,
    /// so nothing here may be read before the stop reason itself is checked.
    var stopDetails: JSONValue? = nil
    var usage = APIUsage()
    /// Indices into `content` whose JSON never finished — a `tool_use` block cut
    /// off at the output limit. These blocks are dropped from history rather than
    /// replayed, because a half-written input is not a call the model made.
    var incompleteBlocks: [Int] = []

    /// The assistant turn to append to history: every complete block, in order.
    var assistantTurn: AgentMessage {
        let kept = content.enumerated()
            .filter { !incompleteBlocks.contains($0.offset) }
            .map { $0.element }
        return AgentMessage(role: .assistant, content: kept)
    }

    var toolUses: [(id: String, name: String, input: [String: JSONValue])] {
        content.enumerated()
            .filter { !incompleteBlocks.contains($0.offset) }
            .compactMap { $0.element.toolUse }
    }

    /// Every `text` block joined — what a unit's summary or a chat reply reads.
    var joinedText: String {
        content.compactMap { $0.text }.joined()
    }

    /// Decode a non-streaming reply body.
    static func parse(_ data: Data) throws -> MessagesResponse {
        let decoder = JSONDecoder()
        let value = try decoder.decode(JSONValue.self, from: data)
        guard let object = value.objectValue else {
            throw StudioError("The API reply was not a JSON object.")
        }
        return try parse(object: object)
    }

    static func parse(object: [String: JSONValue]) throws -> MessagesResponse {
        var out = MessagesResponse()
        out.id = object["id"]?.stringValue ?? ""
        out.model = object["model"]?.stringValue ?? ""
        out.stopReason = StopReason(object["stop_reason"]?.stringValue)
        out.stopDetails = object["stop_details"]
        out.usage = APIUsage(json: object["usage"]?.objectValue ?? [:])
        guard let blocks = object["content"]?.arrayValue else {
            throw StudioError("The API reply had no content array.")
        }
        for (index, block) in blocks.enumerated() {
            guard let raw = block.objectValue else {
                throw StudioError("Content block \(index) was not a JSON object.")
            }
            let parsed = ContentBlock(raw: raw)
            // A tool_use block with no `input` at all is the output limit cutting
            // the call in half. The API will not hand back malformed JSON, so this
            // is belt-and-braces for the non-streaming path; the streaming path
            // detects it properly, by the partial JSON failing to parse.
            if parsed.isToolUse, raw["input"] == nil {
                out.incompleteBlocks.append(index)
            }
            out.content.append(parsed)
        }
        return out
    }
}

// MARK: - Errors

/// A failed request, in the shape the retry policy reads.
///
/// `isTransport` separates "the connection broke" from "the server answered with
/// an error", because the first is always worth retrying and the second only
/// sometimes is.
struct MessagesAPIError: Error, Equatable, CustomStringConvertible {
    var status: Int
    /// The API's `error.type`: `rate_limit_error`, `overloaded_error`,
    /// `invalid_request_error`, `authentication_error`, …
    var type: String
    var message: String
    /// Seconds from the `retry-after` header, when the server sent one.
    var retryAfter: Double? = nil
    var isTransport: Bool = false

    init(status: Int, type: String, message: String, retryAfter: Double? = nil, isTransport: Bool = false) {
        self.status = status
        self.type = type
        self.message = message
        self.retryAfter = retryAfter
        self.isTransport = isTransport
    }

    /// Parse an error body. Falls back to the status code when the body is not the
    /// documented shape — a gateway's own 502 page, for instance.
    static func parse(status: Int, data: Data, headers: [String: String]) -> MessagesAPIError {
        let retryAfter = MessagesAPIError.retryAfterSeconds(headers)
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let error = value.objectValue?["error"]?.objectValue else {
            let body = String(data: data.prefix(400), encoding: .utf8) ?? ""
            return MessagesAPIError(
                status: status,
                type: "http_\(status)",
                message: body.isEmpty ? "HTTP \(status)" : body,
                retryAfter: retryAfter)
        }
        return MessagesAPIError(
            status: status,
            type: error["type"]?.stringValue ?? "http_\(status)",
            message: error["message"]?.stringValue ?? "HTTP \(status)",
            retryAfter: retryAfter)
    }

    /// `retry-after` as seconds. The header is case-insensitive and may be a
    /// delta-seconds integer or an HTTP date; both are honored, and anything else
    /// is ignored so the backoff ladder takes over.
    static func retryAfterSeconds(_ headers: [String: String]) -> Double? {
        guard let raw = headers.first(where: { $0.key.lowercased() == "retry-after" })?.value else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if let seconds = Double(trimmed), seconds >= 0 { return seconds }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: trimmed) {
            return max(0, date.timeIntervalSinceNow)
        }
        return nil
    }

    var description: String {
        isTransport ? "transport: \(message)" : "HTTP \(status) \(type): \(message)"
    }

    /// What the user is shown. API error messages are safe to surface — they never
    /// contain the key, which is why the key is never logged from anywhere else.
    var userFacing: String {
        switch type {
        case "authentication_error":
            return "Anthropic rejected the API key. Check it in Settings (it's stored in the Keychain)."
        case "rate_limit_error":
            return "Rate limited by Anthropic. The run backs off and retries automatically."
        default:
            return "Anthropic API error: \(message)"
        }
    }
}
