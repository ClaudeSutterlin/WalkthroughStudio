// SSEParser.swift — "Onboard to a Codebase", milestone M6 (LLM runtime).
//
// Two halves of streaming, kept apart on purpose:
//
//   SSEParser                  bytes  -> events        (framing, no API knowledge)
//   MessageStreamAccumulator   events -> MessagesResponse  (API, no byte handling)
//
// Both are value types a probe can drive with no network. `sseParseProbe` feeds the
// same recorded stream at a hundred different chunk boundaries and asserts the
// assembled response is identical every time, because that is the failure mode
// that does not show up in a happy-path test: a stream is delivered in whatever
// chunks the network felt like, and every one of our seams has to survive a split
// in the middle of a line, in the middle of a UTF-8 character, and between the CR
// and the LF of one line ending.

import Foundation

/// One server-sent event: a name and its data payload.
struct SSEEvent: Equatable, Sendable {
    /// The `event:` field, or "message" when the stream omitted it (per the SSE spec).
    var name: String
    /// Every `data:` line of the event, joined with newlines.
    var data: String

    init(name: String, data: String) {
        self.name = name
        self.data = data
    }

    /// The payload parsed as a JSON object, or nil if it is not one.
    var json: [String: JSONValue]? {
        guard let bytes = data.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: bytes) else { return nil }
        return value.objectValue
    }
}

/// Incremental SSE framing: feed byte chunks, take whole events.
///
/// Line splitting happens on *bytes*, not on a decoded string, and that is the
/// point. A chunk can end in the middle of a multi-byte character, and decoding a
/// chunk at a time would turn that character into a replacement glyph inside a
/// JSON string — a silent corruption. In UTF-8, 0x0A and 0x0D never appear inside
/// a multi-byte sequence (continuation bytes are all >= 0x80), so splitting on
/// them is safe and each complete line decodes cleanly.
struct SSEParser {
    /// Bytes of the line being read.
    private var lineBytes = Data()
    /// Data fields of the event being assembled.
    private var pendingData: [String] = []
    /// The `event:` field of the event being assembled.
    private var pendingName: String? = nil
    /// Set after a CR, so a LF arriving next — possibly in the next chunk — is
    /// treated as the other half of one CRLF rather than as a second line break.
    private var swallowLineFeed = false

    init() {}

    mutating func feed(_ data: Data) -> [SSEEvent] {
        var events: [SSEEvent] = []
        for byte in data {
            if swallowLineFeed {
                swallowLineFeed = false
                if byte == 0x0A { continue }
            }
            switch byte {
            case 0x0A:
                if let event = endOfLine() { events.append(event) }
            case 0x0D:
                swallowLineFeed = true
                if let event = endOfLine() { events.append(event) }
            default:
                lineBytes.append(byte)
            }
        }
        return events
    }

    mutating func feed(_ text: String) -> [SSEEvent] {
        feed(Data(text.utf8))
    }

    /// Flush whatever is buffered when the connection closes.
    ///
    /// The SSE spec says to discard an event that was never terminated by a blank
    /// line. We dispatch it instead: a server that closes right after
    /// `data: {"type":"message_stop"}` has told us everything, and the accumulator
    /// parses the payload anyway, so a genuinely truncated one is ignored there
    /// rather than lost here.
    mutating func finish() -> [SSEEvent] {
        var events: [SSEEvent] = []
        if !lineBytes.isEmpty, let event = endOfLine() { events.append(event) }
        if let event = dispatch() { events.append(event) }
        return events
    }

    private mutating func endOfLine() -> SSEEvent? {
        let line = String(decoding: lineBytes, as: UTF8.self)
        lineBytes.removeAll(keepingCapacity: true)
        return process(line)
    }

    private mutating func process(_ line: String) -> SSEEvent? {
        if line.isEmpty { return dispatch() }
        // A line starting with a colon is a comment. Anthropic's streams use them
        // as keepalives, so this is the common case on a slow turn, not an oddity.
        if line.hasPrefix(":") { return nil }
        let (field, value) = SSEParser.split(line)
        switch field {
        case "event": pendingName = value
        case "data": pendingData.append(value)
        default: break   // `id`, `retry`, and anything new: ignored by design
        }
        return nil
    }

    private mutating func dispatch() -> SSEEvent? {
        let name = pendingName
        let data = pendingData
        pendingName = nil
        pendingData = []
        guard !data.isEmpty else { return nil }
        return SSEEvent(name: name ?? "message", data: data.joined(separator: "\n"))
    }

    /// `field: value`, with exactly one optional space after the colon removed.
    /// A line with no colon is a field with an empty value.
    static func split(_ line: String) -> (field: String, value: String) {
        guard let colon = line.firstIndex(of: ":") else { return (line, "") }
        let field = String(line[line.startIndex..<colon])
        var rest = line[line.index(after: colon)...]
        if rest.first == " " { rest = rest.dropFirst() }
        return (field, String(rest))
    }
}

/// What a streaming turn produces as it arrives, for a UI that shows the reply
/// being written (the playback chat in M7). The research units ignore these and
/// read the finished response.
enum StreamDelta: Equatable, Sendable {
    case text(String)
    case thinking(String)
    case toolStarted(id: String, name: String)
    case stopped(StopReason)
}

/// Applies SSE events to build a `MessagesResponse`.
///
/// Mutating and order-dependent, like the protocol it mirrors. Unknown event names
/// and unknown delta types are ignored rather than rejected: a new block type must
/// still round-trip (the verbatim rule), and the loop only ever branches on the
/// stop reason and on tool calls.
struct MessageStreamAccumulator {
    private var response = MessagesResponse()
    /// Accumulated `input_json_delta` text per block index.
    private var partialJSON: [Int: String] = [:]
    /// Block indices that have seen `content_block_stop`.
    private var closed: Set<Int> = []
    /// Block indices that started life as a `tool_use`.
    private var toolBlocks: Set<Int> = []
    private var sawMessageStop = false

    init() {}

    /// Apply one event. Throws only for an `error` event — the one case where the
    /// server has told us the turn is not going to happen.
    @discardableResult
    mutating func apply(_ event: SSEEvent) throws -> StreamDelta? {
        guard let object = event.json else { return nil }
        // The payload's own `type` is authoritative; the `event:` name repeats it,
        // and a proxy that rewrites event names (some do) must not change meaning.
        let type = object["type"]?.stringValue ?? event.name
        switch type {
        case "message_start":
            if let message = object["message"]?.objectValue {
                response.id = message["id"]?.stringValue ?? response.id
                response.model = message["model"]?.stringValue ?? response.model
                response.usage.merge(APIUsage(json: message["usage"]?.objectValue ?? [:]))
            }
            return nil

        case "content_block_start":
            guard let index = intValue(object["index"]),
                  let raw = object["content_block"]?.objectValue else { return nil }
            let block = ContentBlock(raw: raw)
            place(block, at: index)
            if block.isToolUse {
                toolBlocks.insert(index)
                partialJSON[index] = ""
                if let use = block.toolUse {
                    return .toolStarted(id: use.id, name: use.name)
                }
                // `id` and `name` arrive with the block start; if they did not,
                // there is nothing to announce but the block is still accumulated.
                return nil
            }
            return nil

        case "content_block_delta":
            guard let index = intValue(object["index"]),
                  let delta = object["delta"]?.objectValue else { return nil }
            return applyDelta(delta, at: index)

        case "content_block_stop":
            guard let index = intValue(object["index"]) else { return nil }
            closed.insert(index)
            closeToolInput(at: index)
            return nil

        case "message_delta":
            if let delta = object["delta"]?.objectValue {
                if let reason = delta["stop_reason"]?.stringValue {
                    response.stopReason = StopReason(reason)
                }
                if let details = delta["stop_details"] {
                    response.stopDetails = details
                }
            }
            if let usage = object["usage"]?.objectValue {
                response.usage.merge(APIUsage(json: usage))
            }
            return nil

        case "message_stop":
            sawMessageStop = true
            return .stopped(response.stopReason)

        case "ping":
            return nil

        case "error":
            let error = object["error"]?.objectValue ?? [:]
            throw MessagesAPIError(
                status: 200,
                type: error["type"]?.stringValue ?? "stream_error",
                message: error["message"]?.stringValue ?? "The stream reported an error.")

        default:
            return nil
        }
    }

    private mutating func applyDelta(_ delta: [String: JSONValue], at index: Int) -> StreamDelta? {
        guard index >= 0, index < response.content.count else { return nil }
        let kind = delta["type"]?.stringValue ?? ""
        switch kind {
        case "text_delta":
            let piece = delta["text"]?.stringValue ?? ""
            append(piece, toKey: "text", at: index)
            return piece.isEmpty ? nil : .text(piece)
        case "thinking_delta":
            let piece = delta["thinking"]?.stringValue ?? ""
            append(piece, toKey: "thinking", at: index)
            return piece.isEmpty ? nil : .thinking(piece)
        case "signature_delta":
            // The signature is what makes a replayed thinking block acceptable to
            // the server, so it is appended, not replaced: it arrives in pieces
            // like everything else.
            append(delta["signature"]?.stringValue ?? "", toKey: "signature", at: index)
            return nil
        case "input_json_delta":
            partialJSON[index, default: ""] += delta["partial_json"]?.stringValue ?? ""
            return nil
        default:
            return nil
        }
    }

    private mutating func append(_ piece: String, toKey key: String, at index: Int) {
        guard !piece.isEmpty, index >= 0, index < response.content.count else { return }
        let existing = response.content[index].raw[key]?.stringValue ?? ""
        response.content[index].raw[key] = .string(existing + piece)
    }

    /// Grow the content array so a block can be written at its own index, however
    /// the events arrive.
    private mutating func place(_ block: ContentBlock, at index: Int) {
        guard index >= 0, index < 4096 else { return }
        while response.content.count <= index {
            response.content.append(ContentBlock(raw: ["type": .string("text"), "text": .string("")]))
        }
        response.content[index] = block
    }

    /// Turn a finished block's accumulated `partial_json` into its `input`.
    ///
    /// An empty accumulation is a tool called with no arguments — `{}` — which is
    /// legitimate. Anything that is non-empty and does not parse is a call the
    /// output limit cut in half; the block is marked incomplete so the loop drops
    /// it from history instead of replaying a half-written call.
    private mutating func closeToolInput(at index: Int) {
        guard toolBlocks.contains(index), index >= 0, index < response.content.count else { return }
        let accumulated = partialJSON[index] ?? ""
        let trimmed = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            response.content[index].raw["input"] = .object([:])
            return
        }
        guard let bytes = trimmed.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: bytes),
              let object = value.objectValue else {
            markIncomplete(index)
            return
        }
        response.content[index].raw["input"] = .object(object)
    }

    private mutating func markIncomplete(_ index: Int) {
        if !response.incompleteBlocks.contains(index) {
            response.incompleteBlocks.append(index)
            response.incompleteBlocks.sort()
        }
    }

    /// The finished response.
    ///
    /// A tool_use block the stream never closed is incomplete, whatever its
    /// accumulated JSON looks like: without `content_block_stop` we cannot know the
    /// arguments were all sent, and a plausible-looking half-call is worse than no
    /// call. Text and thinking blocks are kept even when truncated — they are real
    /// content the model produced, and the max_tokens rule replays them.
    mutating func finalize() throws -> MessagesResponse {
        for index in toolBlocks.sorted() where !closed.contains(index) {
            markIncomplete(index)
        }
        if response.content.isEmpty, !sawMessageStop {
            throw StudioError("The stream ended before any content arrived.")
        }
        return response
    }

    /// What has been assembled so far, for a cancelled or timed-out stream.
    var partial: MessagesResponse { response }

    private func intValue(_ value: JSONValue?) -> Int? {
        guard let number = value?.numberValue, number.isFinite else { return nil }
        return Int(number)
    }
}
