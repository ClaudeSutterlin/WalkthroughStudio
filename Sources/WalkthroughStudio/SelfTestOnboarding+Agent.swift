// SelfTestOnboarding+Agent.swift — probes for milestone M6 (the LLM runtime).
//
// Five probes, no network and no key:
//   sseParseProbe     the stream survives every chunk boundary
//   toolLoopProbe     one turn, two tools, verbatim history, one user message back
//   agentResumeProbe  all five resume outcomes, and a real round trip through disk
//   backoffProbe      what is retried, how long it waits, when the breaker opens
//   spendMeterProbe   the arithmetic, the unpriced model, and a cap that binds
//
// Everything above the transport runs here exactly as it runs against the real API,
// which is the whole reason the transport is a protocol (D9).

import Foundation

extension SelfTest {

    // MARK: - Fixture builders

    /// One SSE record.
    static func sseRecord(_ name: String, _ payload: [String: JSONValue]) -> String {
        let data = (try? MessagesRequest.canonicalJSON(.object(payload))) ?? Data()
        return "event: \(name)\ndata: \(String(decoding: data, as: UTF8.self))\n\n"
    }

    /// A non-streaming reply body.
    static func agentReplyBody(
        id: String = "msg_probe",
        model: String = "claude-opus-5",
        stopReason: String,
        content: [JSONValue],
        usage: [String: JSONValue] = ["input_tokens": .number(1000), "output_tokens": .number(200)]
    ) -> JSONValue {
        .object([
            "id": .string(id),
            "type": .string("message"),
            "role": .string("assistant"),
            "model": .string(model),
            "content": .array(content),
            "stop_reason": .string(stopReason),
            "usage": .object(usage),
        ])
    }

    static func thinkingBlock(_ text: String, signature: String) -> JSONValue {
        .object(["type": .string("thinking"), "thinking": .string(text),
                 "signature": .string(signature)])
    }

    static func textBlock(_ text: String) -> JSONValue {
        .object(["type": .string("text"), "text": .string(text)])
    }

    static func toolUseBlock(id: String, name: String, input: [String: JSONValue]) -> JSONValue {
        .object(["type": .string("tool_use"), "id": .string(id), "name": .string(name),
                 "input": .object(input)])
    }

    /// The two tools the probes declare besides `finish`. Named out of alphabetical
    /// order on purpose: the request must sort them, or the cacheable prefix moves.
    static var probeToolSpecs: [ToolSpec] {
        [
            ToolSpec(name: "read_file", description: "Read a file.",
                     inputSchema: ToolSpec.schema(["path": ToolSpec.property("string", "Path.")],
                                                  required: ["path"])),
            ToolSpec(name: "grep", description: "Search.",
                     inputSchema: ToolSpec.schema(["pattern": ToolSpec.property("string", "Pattern.")],
                                                  required: ["pattern"])),
            FinishTool.spec,
        ]
    }

    static let probeAPIKey = "sk-ant-FAKE-must-never-be-logged-0000"

    static func agentConfig(
        unitId: String = "probe-unit",
        promptName: String = "probe",
        stream: Bool = false,
        maxTurns: Int = 8,
        contextCapTokens: Int = 0
    ) -> AgentRunConfig {
        var config = AgentRunConfig(unitId: unitId, promptName: promptName, model: "claude-opus-5")
        config.system = [
            MessagesRequest.SystemBlock("You map a directory of a repository."),
            MessagesRequest.SystemBlock("Cite every claim with an anchor.", cacheControl: true),
        ]
        config.effort = .low
        config.maxTokens = 16000
        config.stream = stream
        config.maxTurns = maxTurns
        config.contextCapTokens = contextCapTokens
        return config
    }

    static func probeEndpoint() throws -> URL {
        guard let url = AgentEndpoint.messages(baseURL: "") else {
            throw StudioError("could not build the messages endpoint")
        }
        return url
    }

    // MARK: - sseParseProbe

    /// A recorded turn, assembled at every chunk size, must come out identical.
    ///
    /// This is the probe for the bug class that a happy-path test cannot see. The
    /// network delivers a stream in whatever pieces it feels like: a split in the
    /// middle of a line, in the middle of a multi-byte character, and between the
    /// CR and the LF of one line ending. All three are silent — the first loses a
    /// field, the second corrupts a character inside a JSON string, the third
    /// invents a blank line and dispatches an event early.
    static func sseParseProbe(_ ctx: OnboardingProbeContext) async throws {
        let stream = SelfTest.probeStreamSSE(closeToolBlock: true)
        let reference = try SelfTest.assembleStream(stream, chunkSize: 0)

        var checked = 0
        for size in [1, 2, 3, 5, 7, 11, 13, 29, 64, 97, 512, 0] {
            let got = try SelfTest.assembleStream(stream, chunkSize: size)
            checked += 1
            guard got.content == reference.content,
                  got.incompleteBlocks == reference.incompleteBlocks,
                  got.stopReason == reference.stopReason,
                  got.usage == reference.usage,
                  got.id == reference.id else {
                throw StudioError("sseParseProbe: chunk size \(size) assembled a different "
                                  + "response than the whole-stream baseline")
            }
        }

        // The content itself.
        guard reference.content.count == 3 else {
            throw StudioError("sseParseProbe: expected 3 blocks, got \(reference.content.count)")
        }
        guard reference.content[0].raw["signature"]?.stringValue == "sig-probe-1" else {
            throw StudioError("sseParseProbe: the thinking signature did not survive "
                              + "(\(reference.content[0].raw["signature"]?.stringValue ?? "nil")) "
                              + "— a replayed thinking block without it is rejected by the API")
        }
        let thinking = reference.content[0].raw["thinking"]?.stringValue ?? ""
        guard thinking == "I will read the repository — café ☕ first." else {
            throw StudioError("sseParseProbe: multi-byte thinking text came back as \(thinking)")
        }
        guard reference.content[1].text == "Reading orders_repo.py" else {
            throw StudioError("sseParseProbe: text block came back as "
                              + "\(reference.content[1].text ?? "nil")")
        }
        guard let use = reference.content[2].toolUse,
              use.name == "read_file",
              use.input["path"]?.stringValue == "src/repo/orders_repo.py",
              use.input["endLine"]?.numberValue == 40 else {
            throw StudioError("sseParseProbe: the tool input did not reassemble from its "
                              + "input_json_delta pieces")
        }

        // Usage: message_start carries input and cache, message_delta carries only
        // output. Overwriting wholesale would make every streamed turn look free.
        guard reference.usage == APIUsage(inputTokens: 1200, outputTokens: 412,
                                          cacheReadTokens: 9000, cacheWriteTokens: 0) else {
            throw StudioError("sseParseProbe: usage merged to \(reference.usage)")
        }

        // CRLF line endings, and the same stream cut off mid-input.
        let crlf = stream.replacingOccurrences(of: "\n", with: "\r\n")
        let fromCRLF = try SelfTest.assembleStream(crlf, chunkSize: 3)
        guard fromCRLF.content == reference.content, fromCRLF.usage == reference.usage else {
            throw StudioError("sseParseProbe: CRLF framing assembled a different response")
        }

        let cutOff = SelfTest.probeStreamSSE(closeToolBlock: false, truncateToolJSON: true)
        let truncated = try SelfTest.assembleStream(cutOff, chunkSize: 5)
        guard truncated.incompleteBlocks == [2] else {
            throw StudioError("sseParseProbe: a tool call cut off at the output limit was not "
                              + "marked incomplete (incomplete = \(truncated.incompleteBlocks))")
        }
        guard truncated.toolUses.isEmpty, truncated.assistantTurn.content.count == 2 else {
            throw StudioError("sseParseProbe: an incomplete tool call survived into the "
                              + "assistant turn; a half-written call must never be replayed")
        }

        // An error event stops the turn rather than returning a half response.
        var errored = false
        do {
            _ = try SelfTest.assembleStream(
                SelfTest.sseRecord("error", [
                    "type": .string("error"),
                    "error": .object(["type": .string("overloaded_error"),
                                      "message": .string("Overloaded")]),
                ]), chunkSize: 4)
        } catch let error as MessagesAPIError {
            errored = error.type == "overloaded_error"
        } catch {
            throw StudioError("sseParseProbe: an error event threw \(type(of: error)) "
                              + "instead of a MessagesAPIError: \(error.localizedDescription)")
        }
        guard errored else {
            throw StudioError("sseParseProbe: an error event did not throw an overloaded_error")
        }

        print("selftest: sseParseProbe OK (\(checked) chunk sizes identical, CRLF included; "
              + "signature, multi-byte text and split tool JSON intact; a cut-off call dropped)")
    }

    /// Feeds `text` through the parser and accumulator in `chunkSize`-byte pieces
    /// (0 = one piece), exactly as `AgentRun.send` does.
    static func assembleStream(_ text: String, chunkSize: Int) throws -> MessagesResponse {
        var parser = SSEParser()
        var accumulator = MessageStreamAccumulator()
        let bytes = Data(text.utf8)
        if chunkSize <= 0 {
            for event in parser.feed(bytes) { try accumulator.apply(event) }
        } else {
            var start = bytes.startIndex
            while start < bytes.endIndex {
                let end = bytes.index(start, offsetBy: chunkSize, limitedBy: bytes.endIndex)
                    ?? bytes.endIndex
                for event in parser.feed(bytes[start..<end]) { try accumulator.apply(event) }
                start = end
            }
        }
        for event in parser.finish() { try accumulator.apply(event) }
        return try accumulator.finalize()
    }

    /// A realistic streamed turn: thinking with a signature, text, a tool call whose
    /// JSON arrives in three pieces, a ping, a comment keepalive, and usage split
    /// across `message_start` and `message_delta`.
    static func probeStreamSSE(closeToolBlock: Bool, truncateToolJSON: Bool = false) -> String {
        var out = ""
        out += SelfTest.sseRecord("message_start", [
            "type": .string("message_start"),
            "message": .object([
                "id": .string("msg_stream_probe"),
                "model": .string("claude-opus-5"),
                "content": .array([]),
                "usage": .object([
                    "input_tokens": .number(1200),
                    "output_tokens": .number(1),
                    "cache_read_input_tokens": .number(9000),
                    "cache_creation_input_tokens": .number(0),
                ]),
            ]),
        ])
        out += SelfTest.sseRecord("content_block_start", [
            "type": .string("content_block_start"), "index": .number(0),
            "content_block": .object(["type": .string("thinking"), "thinking": .string("")]),
        ])
        for piece in ["I will read the repository ", "— café ☕ first."] {
            out += SelfTest.sseRecord("content_block_delta", [
                "type": .string("content_block_delta"), "index": .number(0),
                "delta": .object(["type": .string("thinking_delta"), "thinking": .string(piece)]),
            ])
        }
        out += SelfTest.sseRecord("content_block_delta", [
            "type": .string("content_block_delta"), "index": .number(0),
            "delta": .object(["type": .string("signature_delta"),
                              "signature": .string("sig-probe-1")]),
        ])
        out += SelfTest.sseRecord("content_block_stop", [
            "type": .string("content_block_stop"), "index": .number(0),
        ])
        out += SelfTest.sseRecord("ping", ["type": .string("ping")])
        out += ": keepalive\n\n"
        out += SelfTest.sseRecord("content_block_start", [
            "type": .string("content_block_start"), "index": .number(1),
            "content_block": .object(["type": .string("text"), "text": .string("")]),
        ])
        out += SelfTest.sseRecord("content_block_delta", [
            "type": .string("content_block_delta"), "index": .number(1),
            "delta": .object(["type": .string("text_delta"),
                              "text": .string("Reading orders_repo.py")]),
        ])
        out += SelfTest.sseRecord("content_block_stop", [
            "type": .string("content_block_stop"), "index": .number(1),
        ])
        out += SelfTest.sseRecord("content_block_start", [
            "type": .string("content_block_start"), "index": .number(2),
            "content_block": .object(["type": .string("tool_use"), "id": .string("toolu_probe_1"),
                                      "name": .string("read_file"), "input": .object([:])]),
        ])
        let pieces = truncateToolJSON
            ? ["{\"pa", "th\": \"src/repo/orders_repo.py\""]
            : ["{\"pa", "th\": \"src/repo/orders_repo.py\"", ", \"startLine\": 1, \"endLine\": 40}"]
        for piece in pieces {
            out += SelfTest.sseRecord("content_block_delta", [
                "type": .string("content_block_delta"), "index": .number(2),
                "delta": .object(["type": .string("input_json_delta"),
                                  "partial_json": .string(piece)]),
            ])
        }
        if closeToolBlock {
            out += SelfTest.sseRecord("content_block_stop", [
                "type": .string("content_block_stop"), "index": .number(2),
            ])
        }
        out += SelfTest.sseRecord("message_delta", [
            "type": .string("message_delta"),
            "delta": .object(["stop_reason": .string("tool_use"), "stop_sequence": .null]),
            "usage": .object(["output_tokens": .number(412)]),
        ])
        out += SelfTest.sseRecord("message_stop", ["type": .string("message_stop")])
        return out
    }
}

// MARK: - Probe helpers that need their own identity

/// Records which tools ran, and whether they ran at the same time.
///
/// The overlap is the point. "Runs every tool_use block concurrently" is easy to
/// write and easy to lose — a `for` loop with an `await` inside reads almost the
/// same and is serial, and nothing fails, the unit is just N times slower. Each
/// tool holds for a moment so a serial implementation can only ever reach a peak
/// of one.
actor ProbeToolRecorder {
    private(set) var calls: [String] = []
    private(set) var concurrentPeak = 0
    private var active = 0

    func begin(_ name: String) {
        calls.append(name)
        active += 1
        concurrentPeak = max(concurrentPeak, active)
    }

    func end() {
        active -= 1
    }
}

/// A transport that always fails the way a dead network fails.
struct FailingTransport: MessagesTransport {
    var error: MessagesAPIError

    init(error: MessagesAPIError = MessagesAPIError(status: 0, type: "urlerror_-1009",
                                                    message: "The Internet connection appears to be offline.",
                                                    isTransport: true)) {
        self.error = error
    }

    func send(_ request: TransportRequest) async throws -> TransportReply { throw error }
    func stream(_ request: TransportRequest) async throws -> TransportStream { throw error }
}

/// Records every sleep the retry ladder asked for, instead of sleeping.
actor SleepLog {
    private(set) var waits: [Double] = []

    func record(_ seconds: Double) {
        waits.append(seconds)
    }

    /// An `AgentSleep` that logs and returns at once.
    nonisolated func sleeper() -> AgentSleep {
        { [self] seconds in await self.record(seconds) }
    }
}

extension SelfTest {

    // MARK: - toolLoopProbe

    /// One unit, end to end: two tools in one turn, then `finish`.
    static func toolLoopProbe(_ ctx: OnboardingProbeContext) async throws {
        let store = try PackageStore(root: ctx.scratch.appendingPathComponent("agent-pkg",
                                                                              isDirectory: true))
        let transcript = AgentTranscript(store: store, unitId: "probe-unit")
        let recorder = ProbeToolRecorder()
        let tools = ClosureTools(specs: SelfTest.probeToolSpecs) { name, input, _ in
            await recorder.begin(name)
            // Long enough that two concurrent calls must overlap, short enough that
            // the probe does not notice.
            try? await Task.sleep(nanoseconds: 30_000_000)
            await recorder.end()
            switch name {
            case "read_file":
                return ToolOutcome("  1 | import os\n  2 | DB = os.environ[\"DB\"]")
            case "grep":
                return ToolOutcome.error("pattern missing: \(input["pattern"]?.stringValue ?? "")")
            case FinishTool.name:
                return ToolOutcome("{\"ok\": true}", endsUnit: true, outputs: ["facts/probe-unit.jsonl"])
            default:
                return ToolOutcome.error("unknown tool \(name)")
            }
        }

        // Turn 0: thinking + text + two tool calls. Turn 1: finish.
        var turn0 = FixtureTransport.Recording(promptName: "probe", turn: 0)
        turn0.body = SelfTest.agentReplyBody(stopReason: "tool_use", content: [
            SelfTest.thinkingBlock("Two files to check.", signature: "sig-loop-1"),
            SelfTest.textBlock("Checking both."),
            SelfTest.toolUseBlock(id: "toolu_a", name: "read_file",
                                  input: ["path": .string("src/service/orders.py")]),
            SelfTest.toolUseBlock(id: "toolu_b", name: "grep", input: ["pattern": .string("")]),
        ], usage: ["input_tokens": .number(1000), "output_tokens": .number(250),
                   "cache_creation_input_tokens": .number(4000)])
        var turn1 = FixtureTransport.Recording(promptName: "probe", turn: 1)
        turn1.body = SelfTest.agentReplyBody(stopReason: "tool_use", content: [
            SelfTest.toolUseBlock(id: "toolu_c", name: FinishTool.name, input: [
                "summary": .string("Orders flow through service into repo."),
                "coverage": .object([
                    "readPaths": .array([.string("src/service/orders.py")]),
                    "unreadDirs": .array([.string("vendor/generated")]),
                    "skipped": .array([]),
                ]),
            ]),
        ], usage: ["input_tokens": .number(200), "output_tokens": .number(90),
                   "cache_read_input_tokens": .number(4000)])
        let transport = FixtureTransport(recordings: [turn0, turn1])

        let meter = SpendMeter()
        let endpoint = try SelfTest.probeEndpoint()
        let run = AgentRun(
            config: SelfTest.agentConfig(),
            transport: transport,
            tools: tools,
            apiKey: SelfTest.probeAPIKey,
            endpoint: endpoint,
            meter: meter,
            breaker: CircuitBreaker(),
            transcript: transcript,
            sleep: { _ in })
        let outcome = try await run.run(instructions: .user("Map src/service."))

        // 1. It finished, with the summary from the finish call.
        guard case .finished(let summary) = outcome.ending,
              summary == "Orders flow through service into repo." else {
            throw StudioError("toolLoopProbe: ended \(outcome.ending) instead of finished "
                              + "with the summary from the finish call")
        }
        guard outcome.turns == 2, outcome.toolCalls == 3 else {
            throw StudioError("toolLoopProbe: \(outcome.turns) turn(s) and "
                              + "\(outcome.toolCalls) tool call(s); expected 2 and 3")
        }
        guard outcome.outputs == ["facts/probe-unit.jsonl"] else {
            throw StudioError("toolLoopProbe: outputs \(outcome.outputs) did not reach the outcome")
        }

        // 2. The two tools of one turn ran at the same time.
        let peak = await recorder.concurrentPeak
        let calls = await recorder.calls
        guard peak == 2 else {
            throw StudioError("toolLoopProbe: peak concurrency was \(peak); the two tool calls "
                              + "of one turn ran serially (calls: \(calls.joined(separator: ", ")))")
        }

        // 3. History: user, assistant, one user with BOTH results, assistant, user.
        guard outcome.history.count == 5 else {
            throw StudioError("toolLoopProbe: history has \(outcome.history.count) messages; "
                              + "expected 5")
        }
        let results = outcome.history[2]
        guard results.role == .user, results.content.count == 2,
              results.content.allSatisfy({ $0.type == "tool_result" }) else {
            throw StudioError("toolLoopProbe: both tool results must come back in ONE user "
                              + "message; got \(results.content.count) block(s) with role "
                              + "\(results.role.rawValue)")
        }
        guard results.content[0].raw["tool_use_id"]?.stringValue == "toolu_a",
              results.content[1].raw["tool_use_id"]?.stringValue == "toolu_b" else {
            throw StudioError("toolLoopProbe: tool results came back out of call order")
        }
        // A failing tool is reported, never dropped: a tool_use with no result is
        // rejected by the API on the next request.
        guard results.content[1].raw["is_error"]?.boolValue == true else {
            throw StudioError("toolLoopProbe: the failing tool's result was not marked is_error")
        }
        guard results.content[0].raw["is_error"] == nil else {
            throw StudioError("toolLoopProbe: a successful tool result carried is_error")
        }

        // 4. The second request echoes the assistant turn verbatim, signature and all.
        let sent = await transport.sent
        guard sent.count == 2 else {
            throw StudioError("toolLoopProbe: \(sent.count) request(s) reached the transport")
        }
        let second = try SelfTest.requestJSON(sent[1])
        guard let messages = second["messages"]?.arrayValue, messages.count == 3,
              let assistant = messages[1].objectValue,
              let blocks = assistant["content"]?.arrayValue,
              let thinking = blocks.first?.objectValue,
              thinking["type"]?.stringValue == "thinking",
              thinking["signature"]?.stringValue == "sig-loop-1" else {
            throw StudioError("toolLoopProbe: the replayed assistant turn lost its thinking "
                              + "block or its signature — the API rejects that on the next turn")
        }

        // 5. The moving cache breakpoint sits on the last block of the newest user
        //    message, and nowhere else in the conversation.
        guard let lastUser = messages[2].objectValue,
              let userBlocks = lastUser["content"]?.arrayValue,
              let lastBlock = userBlocks.last?.objectValue,
              lastBlock["cache_control"]?.objectValue?["type"]?.stringValue == "ephemeral" else {
            throw StudioError("toolLoopProbe: the newest user message's last block carries no "
                              + "cache breakpoint; every turn would re-read the whole prefix")
        }
        guard userBlocks.count < 2
                || userBlocks[0].objectValue?["cache_control"] == nil else {
            throw StudioError("toolLoopProbe: a cache breakpoint landed on a block that is not "
                              + "the last of the newest user message")
        }
        guard messages[0].objectValue?["content"]?.arrayValue?.first?
                .objectValue?["cache_control"] == nil else {
            throw StudioError("toolLoopProbe: the breakpoint was persisted into history instead "
                              + "of being applied per request; it can no longer move forward")
        }

        // 6. Request shape: tools sorted, adaptive thinking, auto tool choice, and
        //    none of the sampling fields the architecture forbids.
        guard let toolNames = second["tools"]?.arrayValue?
                .compactMap({ $0.objectValue?["name"]?.stringValue }) else {
            throw StudioError("toolLoopProbe: the request declared no tools")
        }
        guard toolNames == toolNames.sorted() else {
            throw StudioError("toolLoopProbe: tools were sent as \(toolNames), not sorted; "
                              + "an unstable prefix misses the cache on every request")
        }
        guard second["thinking"]?.objectValue?["type"]?.stringValue == "adaptive",
              second["tool_choice"]?.objectValue?["type"]?.stringValue == "auto",
              second["output_config"]?.objectValue?["effort"]?.stringValue == "low",
              second["temperature"] == nil, second["top_p"] == nil,
              second["thinking"]?.objectValue?["budget_tokens"] == nil else {
            throw StudioError("toolLoopProbe: request shape wrong — expected adaptive thinking, "
                              + "auto tool choice, effort low, and no temperature/top_p/budget")
        }

        // 7. Spend and cache accounting reached the meter.
        let spent = await meter.total
        guard spent.inputTokens == 1200, spent.outputTokens == 340,
              spent.cacheWriteTokens == 4000, spent.cacheReadTokens == 4000,
              spent.usd > 0 else {
            throw StudioError("toolLoopProbe: the meter recorded \(spent)")
        }

        // 8. The transcript is complete, in order, and contains no header value.
        let entries = transcript.entries()
        let kinds = entries.map { $0.kind.rawValue }
        guard kinds == ["user", "request", "reply", "user", "request", "reply", "user", "finish"] else {
            throw StudioError("toolLoopProbe: transcript kinds were \(kinds.joined(separator: ", "))")
        }
        let raw = try store.readString(transcript.relativePath)
        guard !raw.contains(SelfTest.probeAPIKey), !raw.contains("x-api-key\":\"sk-") else {
            throw StudioError("toolLoopProbe: the API key reached units/probe-unit/transcript.jsonl")
        }
        guard entries.first(where: { $0.kind == .request })?.headersRedacted?
                .contains("x-api-key") == true else {
            throw StudioError("toolLoopProbe: the request entry did not record its header names")
        }

        // 9. The same loop over a streamed turn: the SSE path ends a unit too.
        try await SelfTest.streamedFinishCheck(ctx)

        // 10. Every other stop reason.
        try await SelfTest.stopReasonChecks(ctx)

        print("selftest: toolLoopProbe OK (2 turns, 3 tool calls at peak concurrency 2, both "
              + "results in one user message, thinking replayed with its signature, breakpoint "
              + "on the newest user block only, key absent from the transcript)")
    }

    /// A streaming unit that calls `finish` — AgentRun's SSE path, end to end.
    static func streamedFinishCheck(_ ctx: OnboardingProbeContext) async throws {
        var sse = SelfTest.sseRecord("message_start", [
            "type": .string("message_start"),
            "message": .object([
                "id": .string("msg_stream_finish"), "model": .string("claude-opus-5"),
                "content": .array([]),
                "usage": .object(["input_tokens": .number(80), "output_tokens": .number(1)]),
            ]),
        ])
        sse += SelfTest.sseRecord("content_block_start", [
            "type": .string("content_block_start"), "index": .number(0),
            "content_block": .object(["type": .string("tool_use"), "id": .string("toolu_fin"),
                                      "name": .string(FinishTool.name), "input": .object([:])]),
        ])
        let json = "{\"summary\": \"streamed\", \"coverage\": {\"readPaths\": [], "
            + "\"unreadDirs\": [], \"skipped\": []}}"
        for piece in SelfTest.split(json, every: 9) {
            sse += SelfTest.sseRecord("content_block_delta", [
                "type": .string("content_block_delta"), "index": .number(0),
                "delta": .object(["type": .string("input_json_delta"), "partial_json": .string(piece)]),
            ])
        }
        sse += SelfTest.sseRecord("content_block_stop", [
            "type": .string("content_block_stop"), "index": .number(0),
        ])
        sse += SelfTest.sseRecord("message_delta", [
            "type": .string("message_delta"),
            "delta": .object(["stop_reason": .string("tool_use")]),
            "usage": .object(["output_tokens": .number(60)]),
        ])
        sse += SelfTest.sseRecord("message_stop", ["type": .string("message_stop")])

        var recording = FixtureTransport.Recording(promptName: "probe-stream", turn: 0)
        recording.sse = sse
        recording.chunkBytes = 7      // a split every seven bytes, through the real path
        let transport = FixtureTransport(recordings: [recording])

        var config = SelfTest.agentConfig(unitId: "probe-stream", promptName: "probe-stream",
                                          stream: true)
        config.maxTokens = 32000
        let tools = ClosureTools(specs: [FinishTool.spec]) { _, _, _ in
            ToolOutcome("{\"ok\": true}", endsUnit: true)
        }
        let endpoint = try SelfTest.probeEndpoint()
        let run = AgentRun(
            config: config,
            transport: transport,
            tools: tools,
            apiKey: SelfTest.probeAPIKey,
            endpoint: endpoint,
            meter: SpendMeter(),
            breaker: CircuitBreaker(),
            sleep: { _ in })
        let outcome = try await run.run(instructions: .user("Stream a finish."))
        guard case .finished(let summary) = outcome.ending, summary == "streamed" else {
            throw StudioError("toolLoopProbe: the streamed turn ended \(outcome.ending)")
        }
        guard outcome.usage.outputTokens == 60, outcome.usage.inputTokens == 80 else {
            throw StudioError("toolLoopProbe: streamed usage came out as \(outcome.usage)")
        }
    }

    /// The stop reasons that are not `tool_use`: a reply cut off at the output
    /// limit, a refusal, and a value this build has never seen.
    ///
    /// Each one is a branch that only runs when something goes wrong in
    /// production, which is exactly why it is asserted here instead.
    static func stopReasonChecks(_ ctx: OnboardingProbeContext) async throws {
        let endpoint = try SelfTest.probeEndpoint()
        func makeRun(_ name: String, _ recordings: [FixtureTransport.Recording])
            -> (AgentRun, FixtureTransport) {
            let transport = FixtureTransport(recordings: recordings)
            let run = AgentRun(
                config: SelfTest.agentConfig(unitId: name, promptName: name),
                transport: transport,
                tools: ClosureTools(specs: [FinishTool.spec]) { toolName, _, _ in
                    toolName == FinishTool.name
                        ? ToolOutcome("{}", endsUnit: true)
                        : ToolOutcome("ok")
                },
                apiKey: SelfTest.probeAPIKey,
                endpoint: endpoint,
                meter: SpendMeter(),
                breaker: CircuitBreaker(),
                sleep: { _ in })
            return (run, transport)
        }

        // 1. max_tokens with a tool call cut in half. The half-written call is
        //    dropped from history (it is not a call the model made) and the nudge
        //    the architecture specifies is appended verbatim.
        var cutOff = FixtureTransport.Recording(promptName: "cutoff", turn: 0)
        cutOff.body = SelfTest.agentReplyBody(stopReason: "max_tokens", content: [
            SelfTest.textBlock("I will read the repository"),
            // No `input` at all: the output limit landed inside the arguments.
            .object(["type": .string("tool_use"), "id": .string("toolu_half"),
                     "name": .string("read_file")]),
        ])
        var afterNudge = FixtureTransport.Recording(promptName: "cutoff", turn: 1)
        afterNudge.body = SelfTest.agentReplyBody(stopReason: "tool_use", content: [
            SelfTest.toolUseBlock(id: "toolu_fin2", name: FinishTool.name, input: [
                "summary": .string("continued after the limit"),
                "coverage": .object(["readPaths": .array([]), "unreadDirs": .array([]),
                                     "skipped": .array([])]),
            ]),
        ])
        let (cutRun, cutTransport) = makeRun("cutoff", [cutOff, afterNudge])
        let cutOutcome = try await cutRun.run(instructions: .user("Read it."))
        guard case .finished = cutOutcome.ending else {
            throw StudioError("toolLoopProbe: a cut-off reply ended \(cutOutcome.ending)")
        }
        guard cutOutcome.history.count == 5,
              cutOutcome.history[1].content.count == 1,
              cutOutcome.history[1].content[0].type == "text" else {
            throw StudioError("toolLoopProbe: the half-written tool call was replayed to the API "
                              + "(assistant turn has \(cutOutcome.history[1].content.count) blocks)")
        }
        guard cutOutcome.history[2].content.first?.text == AgentRun.continuePrompt else {
            throw StudioError("toolLoopProbe: the output-limit nudge was not appended")
        }
        guard cutOutcome.notices.contains(where: { $0.contains("cut off at the output limit") }),
              await cutTransport.sent.count == 2 else {
            throw StudioError("toolLoopProbe: a cut-off reply left no notice, or took the wrong "
                              + "number of requests")
        }

        // 2. A refusal fails the unit with no retry. `stop_details` is null here on
        //    purpose: it may be, and reading it before checking the stop reason is
        //    the mistake this asserts against.
        var refused = FixtureTransport.Recording(promptName: "refusal", turn: 0)
        refused.body = .object([
            "id": .string("msg_refusal"),
            "type": .string("message"),
            "role": .string("assistant"),
            "model": .string("claude-opus-5"),
            "content": .array([SelfTest.textBlock("I can't help with that.")]),
            "stop_reason": .string("refusal"),
            "stop_details": .null,
            "usage": .object(["input_tokens": .number(10), "output_tokens": .number(8)]),
        ])
        let (refusalRun, refusalTransport) = makeRun("refusal", [refused])
        let refusalOutcome = try await refusalRun.run(instructions: .user("Do something off limits."))
        guard case .refused(let reason) = refusalOutcome.ending,
              reason == "I can't help with that." else {
            throw StudioError("toolLoopProbe: a refusal ended \(refusalOutcome.ending)")
        }
        guard await refusalTransport.sent.count == 1 else {
            throw StudioError("toolLoopProbe: a refusal was retried; it will be refused again")
        }
        guard !refusalOutcome.succeeded else {
            throw StudioError("toolLoopProbe: a refusal counted as a successful unit")
        }

        // 3. A stop reason this build does not know ends the turn with a notice,
        //    rather than being mistaken for success or looped on.
        var strange = FixtureTransport.Recording(promptName: "strange", turn: 0)
        strange.body = SelfTest.agentReplyBody(stopReason: "something_new_2027",
                                               content: [SelfTest.textBlock("hmm")])
        let (strangeRun, strangeTransport) = makeRun("strange", [strange])
        let strangeOutcome = try await strangeRun.run(instructions: .user("Hello."))
        guard case .unrecognized("something_new_2027") = strangeOutcome.ending,
              !strangeOutcome.succeeded,
              strangeOutcome.notices.contains(where: { $0.contains("something_new_2027") }),
              await strangeTransport.sent.count == 1 else {
            throw StudioError("toolLoopProbe: an unknown stop reason ended "
                              + "\(strangeOutcome.ending) with notices \(strangeOutcome.notices)")
        }
    }

    /// The request body a probe assertion wants to read.
    static func requestJSON(_ request: TransportRequest) throws -> [String: JSONValue] {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: request.body),
              let object = value.objectValue else {
            throw StudioError("a request body was not a JSON object")
        }
        return object
    }

    static func split(_ text: String, every size: Int) -> [String] {
        var out: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if current.count >= size {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }
}

extension SelfTest {

    // MARK: - agentResumeProbe

    /// All five resume outcomes, then a real round trip through a file on disk.
    ///
    /// Resume is the feature that makes a run survive a closed laptop, and it is
    /// the one that cannot be checked by using the app: you would have to kill it
    /// at exactly the right moment. So the rules are one pure function over the
    /// recorded entries, and this is where every branch of it is walked.
    static func agentResumeProbe(_ ctx: OnboardingProbeContext) async throws {
        func user(_ text: String) -> TranscriptEntry {
            var entry = TranscriptEntry(kind: .user)
            entry.message = .user(text)
            return entry
        }
        func assistant(_ blocks: [ContentBlock]) -> TranscriptEntry {
            var entry = TranscriptEntry(kind: .reply)
            entry.message = AgentMessage(role: .assistant, content: blocks)
            return entry
        }
        func toolResults(_ ids: [String]) -> TranscriptEntry {
            var entry = TranscriptEntry(kind: .user)
            entry.message = AgentMessage(
                role: .user,
                content: ids.map { .toolResult(toolUseId: $0, content: "ok") })
            return entry
        }
        let call = ContentBlock.toolCall(id: "toolu_1", name: "read_file",
                                        input: ["path": .string("README.md")])
        let call2 = ContentBlock.toolCall(id: "toolu_2", name: "grep",
                                         input: ["pattern": .string("TODO")])

        // 1. Nothing recorded.
        guard AgentTranscript.plan(from: []) == .fresh else {
            throw StudioError("agentResumeProbe: an empty transcript did not plan .fresh")
        }

        // 2. Notes and requests alone are not history: a session that died after
        //    writing its request line has nothing to resume from.
        var requestOnly = TranscriptEntry(kind: .request)
        requestOnly.bodyHash = "abc"
        var noteOnly = TranscriptEntry(kind: .note)
        noteOnly.text = "attempt 1 failed"
        guard AgentTranscript.plan(from: [requestOnly, noteOnly]) == .fresh else {
            throw StudioError("agentResumeProbe: request and note entries were mistaken for history")
        }

        // 3. Ends with a user turn: send it again, unchanged.
        let afterUser = AgentTranscript.plan(from: [user("Map src/"), assistant([.text("ok")]),
                                                    toolResults(["toolu_0"])])
        guard case .resend(let resendHistory) = afterUser, resendHistory.count == 3 else {
            throw StudioError("agentResumeProbe: a transcript ending in a user turn planned "
                              + "\(afterUser) instead of .resend")
        }

        // 4. Ends with an assistant turn whose calls have no results: re-run exactly
        //    those, in order.
        let pendingPlan = AgentTranscript.plan(from: [user("Map src/"),
                                                      assistant([.text("looking"), call, call2])])
        guard case .reexecuteTools(let history, let pending) = pendingPlan,
              history.count == 2,
              pending.map({ $0.id }) == ["toolu_1", "toolu_2"],
              pending[0].name == "read_file",
              pending[0].input["path"]?.stringValue == "README.md" else {
            throw StudioError("agentResumeProbe: unanswered tool calls planned \(pendingPlan) "
                              + "instead of .reexecuteTools with both calls")
        }

        // 5. A crash *during* the results append: the answered call is not re-run.
        //    Re-running a tool whose result is already recorded would double its
        //    side effects, and `emit_fact` has side effects.
        let partlyAnswered = AgentTranscript.plan(from: [
            user("Map src/"), assistant([call, call2]), toolResults(["toolu_1"]),
            assistant([call2]),
        ])
        guard case .reexecuteTools(_, let stillPending) = partlyAnswered,
              stillPending.map({ $0.id }) == ["toolu_2"] else {
            throw StudioError("agentResumeProbe: an already-answered tool call was queued for "
                              + "re-execution (\(partlyAnswered))")
        }

        // 6. Ends with an assistant turn and nothing pending: nudge and continue.
        //    Explicitly NOT "finished" — a unit that stopped talking without calling
        //    finish has filed no coverage, and inventing one is the failure the
        //    whole packet contract exists to prevent.
        let dangling = AgentTranscript.plan(from: [user("Map src/"),
                                                   assistant([.text("half a thought")])])
        guard case .continueTurn(let continued) = dangling, continued.count == 2 else {
            throw StudioError("agentResumeProbe: a dangling assistant turn planned \(dangling) "
                              + "instead of .continueTurn")
        }

        // 7. A recorded finish ends it, wherever it appears.
        var finish = TranscriptEntry(kind: .finish)
        finish.text = "mapped src/, did not read vendor/"
        let done = AgentTranscript.plan(from: [user("Map src/"), assistant([call]),
                                                toolResults(["toolu_1"]), finish])
        guard case .finished(_, let summary) = done, summary == "mapped src/, did not read vendor/" else {
            throw StudioError("agentResumeProbe: a recorded finish planned \(done)")
        }

        // 8. Round trip through disk, then resume a half-finished unit for real.
        let store = try PackageStore(root: ctx.scratch.appendingPathComponent("resume-pkg",
                                                                              isDirectory: true))
        let transcript = AgentTranscript(store: store, unitId: "resume-unit")
        try transcript.append(user("Map src/"))
        try transcript.append(assistant([.text("reading"), call]))
        let reread = transcript.resumePlan()
        guard case .reexecuteTools(let readHistory, let readPending) = reread,
              readHistory.count == 2, readPending.map({ $0.id }) == ["toolu_1"] else {
            throw StudioError("agentResumeProbe: the plan read back from disk was \(reread)")
        }

        var next = FixtureTransport.Recording(promptName: "resume", turn: 0)
        next.body = SelfTest.agentReplyBody(stopReason: "tool_use", content: [
            SelfTest.toolUseBlock(id: "toolu_fin", name: FinishTool.name, input: [
                "summary": .string("resumed and finished"),
                "coverage": .object(["readPaths": .array([]), "unreadDirs": .array([]),
                                     "skipped": .array([])]),
            ]),
        ])
        let transport = FixtureTransport(recordings: [next])
        let ranTools = ProbeToolRecorder()
        let tools = ClosureTools(specs: SelfTest.probeToolSpecs) { name, _, _ in
            await ranTools.begin(name)
            await ranTools.end()
            if name == FinishTool.name { return ToolOutcome("{}", endsUnit: true) }
            return ToolOutcome("re-read")
        }
        let endpoint = try SelfTest.probeEndpoint()
        let run = AgentRun(
            config: SelfTest.agentConfig(unitId: "resume-unit", promptName: "resume"),
            transport: transport,
            tools: tools,
            apiKey: SelfTest.probeAPIKey,
            endpoint: endpoint,
            meter: SpendMeter(),
            breaker: CircuitBreaker(),
            transcript: transcript,
            sleep: { _ in })
        let outcome = try await run.run(instructions: .user("Map src/"), resume: reread)

        guard case .finished(let resumedSummary) = outcome.ending,
              resumedSummary == "resumed and finished" else {
            throw StudioError("agentResumeProbe: the resumed unit ended \(outcome.ending)")
        }
        let calls = await ranTools.calls
        guard calls == ["read_file", FinishTool.name] else {
            throw StudioError("agentResumeProbe: the resumed unit ran \(calls.joined(separator: ", "))"
                              + "; expected the pending read_file, then finish")
        }
        // Exactly one request: resume re-ran the tool rather than re-asking the
        // model for a call it had already made (and already been billed for).
        let sent = await transport.sent
        guard sent.count == 1 else {
            throw StudioError("agentResumeProbe: resume sent \(sent.count) requests; the pending "
                              + "tool should have been re-run locally, not re-requested")
        }
        // And the replayed result reached history before the new turn.
        guard outcome.history.count == 5, outcome.history[2].role == .user,
              outcome.history[2].content.first?.raw["tool_use_id"]?.stringValue == "toolu_1" else {
            throw StudioError("agentResumeProbe: the re-executed tool's result is not in history")
        }

        print("selftest: agentResumeProbe OK (fresh, resend, re-execute, partly-answered, "
              + "continue and finished all planned correctly; a resumed unit re-ran its one "
              + "pending tool and finished in a single request)")
    }

    // MARK: - backoffProbe

    /// What is retried, how long it waits, and when the fleet gives up.
    static func backoffProbe(_ ctx: OnboardingProbeContext) async throws {
        let limiter = RateLimiter()

        // 1. The ladder doubles and caps, and the jitter is a +/-25% band.
        let mid = limiter.ladder(jitter: 0.5)
        guard mid == [1, 2, 4, 8, 16] else {
            throw StudioError("backoffProbe: the mid-jitter ladder is \(mid); expected 1,2,4,8,16")
        }
        guard limiter.delay(afterAttempt: 6, retryAfter: nil, jitter: 0.5) == 32,
              limiter.delay(afterAttempt: 9, retryAfter: nil, jitter: 0.5) == 32 else {
            throw StudioError("backoffProbe: the ladder is not capped at \(limiter.maxDelay)s")
        }
        let low = limiter.delay(afterAttempt: 1, retryAfter: nil, jitter: 0)
        let high = limiter.delay(afterAttempt: 1, retryAfter: nil, jitter: 1)
        guard abs(low - 0.75) < 1e-9, abs(high - 1.25) < 1e-9,
              limiter.delay(afterAttempt: 1, retryAfter: nil, jitter: -5) == low,
              limiter.delay(afterAttempt: 1, retryAfter: nil, jitter: 9) == high else {
            throw StudioError("backoffProbe: the jitter band is \(low)...\(high); expected "
                              + "0.75...1.25 with out-of-range jitter clamped")
        }

        // 2. retry-after is a floor, never a ceiling. Waiting less than the server
        //    asked for is how a client earns a longer ban.
        guard limiter.delay(afterAttempt: 1, retryAfter: 10, jitter: 0.5) == 10,
              limiter.delay(afterAttempt: 3, retryAfter: 0.2, jitter: 0.5) == 4,
              limiter.delay(afterAttempt: 1, retryAfter: 1000, jitter: 0.5) == limiter.maxRetryAfter else {
            throw StudioError("backoffProbe: retry-after is not honored as a floor")
        }

        // 3. What is retryable.
        func apiError(_ status: Int, type: String = "error", retryAfter: Double? = nil) -> MessagesAPIError {
            MessagesAPIError(status: status, type: type, message: "m", retryAfter: retryAfter)
        }
        let transportError = MessagesAPIError(status: 0, type: "urlerror_-1009", message: "offline",
                                              isTransport: true)
        for status in [429, 500, 502, 503, 529] {
            guard limiter.shouldRetry(apiError(status), afterAttempt: 1) else {
                throw StudioError("backoffProbe: HTTP \(status) was not retried")
            }
        }
        for status in [400, 401, 403, 404, 413, 422] {
            guard !limiter.shouldRetry(apiError(status), afterAttempt: 1) else {
                throw StudioError("backoffProbe: HTTP \(status) was retried; the server decided "
                                  + "that on purpose and will decide it again")
            }
        }
        guard limiter.shouldRetry(transportError, afterAttempt: 1),
              limiter.shouldRetry(apiError(429), afterAttempt: 5),
              !limiter.shouldRetry(apiError(429), afterAttempt: 6),
              !limiter.shouldRetry(apiError(429, retryAfter: 3600), afterAttempt: 1) else {
            throw StudioError("backoffProbe: the attempt budget or the retry-after limit is wrong")
        }

        // 4. `retry-after` off the wire, as an integer and as an HTTP date.
        guard MessagesAPIError.retryAfterSeconds(["Retry-After": "7"]) == 7,
              MessagesAPIError.retryAfterSeconds(["retry-after": " 7 "]) == 7,
              MessagesAPIError.retryAfterSeconds(["x": "7"]) == nil,
              MessagesAPIError.retryAfterSeconds(["Retry-After": "not a number"]) == nil else {
            throw StudioError("backoffProbe: retry-after header parsing is wrong")
        }

        // 5. End to end: 429 with retry-after, then a 500, then success. One
        //    request from the loop's point of view, three attempts, two waits.
        var rateLimited = FixtureTransport.Recording(promptName: "retry", turn: 0, status: 429)
        rateLimited.headers = ["retry-after": "2"]
        rateLimited.body = .object(["error": .object(["type": .string("rate_limit_error"),
                                                      "message": .string("slow down")])])
        var serverError = FixtureTransport.Recording(promptName: "retry", turn: 0, status: 500)
        serverError.body = .object(["error": .object(["type": .string("api_error"),
                                                       "message": .string("oops")])])
        var success = FixtureTransport.Recording(promptName: "retry", turn: 0)
        success.body = SelfTest.agentReplyBody(stopReason: "end_turn",
                                               content: [SelfTest.textBlock("recovered")])
        let transport = FixtureTransport(recordings: [rateLimited, serverError, success])
        let log = SleepLog()
        let endpoint = try SelfTest.probeEndpoint()
        let run = AgentRun(
            config: SelfTest.agentConfig(unitId: "retry", promptName: "retry"),
            transport: transport,
            tools: ClosureTools(specs: [FinishTool.spec]) { _, _, _ in ToolOutcome("{}") },
            apiKey: SelfTest.probeAPIKey,
            endpoint: endpoint,
            meter: SpendMeter(),
            breaker: CircuitBreaker(),
            sleep: log.sleeper(),
            jitter: { 0.5 })
        let outcome = try await run.run(instructions: .user("Say something."))
        guard case .endTurn = outcome.ending, outcome.text == "recovered" else {
            throw StudioError("backoffProbe: the retried turn ended \(outcome.ending) "
                              + "with text \"\(outcome.text)\"")
        }
        let attempts = await transport.sent.count
        let waits = await log.waits
        guard attempts == 3 else {
            throw StudioError("backoffProbe: \(attempts) attempt(s) reached the transport; expected 3")
        }
        guard waits.count == 2, abs(waits[0] - 2) < 1e-9, abs(waits[1] - 2) < 1e-9 else {
            throw StudioError("backoffProbe: waited \(waits); expected the server's 2s then the "
                              + "ladder's 2s for attempt 2")
        }
        // Every attempt replayed the same turn, so a retry never costs a new turn.
        let sent = await transport.sent
        guard Set(sent.map { $0.turn }) == [0], Set(sent.map { $0.bodyHash }).count == 1 else {
            throw StudioError("backoffProbe: a retry changed the request; it must be byte-identical")
        }

        // 6. A 400 is not retried, and the error reaches the caller intact.
        var badRequest = FixtureTransport.Recording(promptName: "bad", turn: 0, status: 400)
        badRequest.body = .object(["error": .object([
            "type": .string("invalid_request_error"),
            "message": .string("max_tokens: must be <= 64000"),
        ])])
        let badTransport = FixtureTransport(recordings: [badRequest])
        let badRun = AgentRun(
            config: SelfTest.agentConfig(unitId: "bad", promptName: "bad"),
            transport: badTransport,
            tools: ClosureTools(specs: [FinishTool.spec]) { _, _, _ in ToolOutcome("{}") },
            apiKey: SelfTest.probeAPIKey,
            endpoint: endpoint,
            meter: SpendMeter(),
            breaker: CircuitBreaker(),
            sleep: { _ in })
        var raised: MessagesAPIError? = nil
        do {
            _ = try await badRun.run(instructions: .user("Break it."))
        } catch let error as MessagesAPIError {
            raised = error
        } catch {
            throw StudioError("backoffProbe: a 400 threw \(type(of: error))")
        }
        guard let raised, raised.status == 400, raised.type == "invalid_request_error",
              raised.message.contains("max_tokens") else {
            throw StudioError("backoffProbe: the 400 did not surface as itself (\(String(describing: raised)))")
        }
        guard await badTransport.sent.count == 1 else {
            throw StudioError("backoffProbe: a 400 was retried")
        }

        // 7. The breaker opens after five consecutive transport failures, and a
        //    unit that hits it ends paused rather than throwing away its history.
        let breaker = CircuitBreaker(threshold: 5)
        let pausedRun = AgentRun(
            config: SelfTest.agentConfig(unitId: "offline", promptName: "offline"),
            transport: FailingTransport(),
            tools: ClosureTools(specs: [FinishTool.spec]) { _, _, _ in ToolOutcome("{}") },
            apiKey: SelfTest.probeAPIKey,
            endpoint: endpoint,
            meter: SpendMeter(),
            breaker: breaker,
            sleep: { _ in })
        let pausedOutcome = try await pausedRun.run(instructions: .user("Anyone there?"))
        guard case .breakerTripped = pausedOutcome.ending else {
            throw StudioError("backoffProbe: five transport failures ended \(pausedOutcome.ending) "
                              + "instead of tripping the breaker")
        }
        guard await breaker.isTripped, pausedOutcome.notices.contains(CircuitBreaker.trippedNotice),
              pausedOutcome.history.count == 1 else {
            throw StudioError("backoffProbe: the breaker did not open with its notice, or the "
                              + "unit lost its history on the way out")
        }

        // 8. A server error does NOT open the breaker: a busy account is not an
        //    outage, and pausing the fleet on 429s would stop every run at scale.
        let quietBreaker = CircuitBreaker(threshold: 5)
        for _ in 0..<10 { await quietBreaker.recordReachable() }
        var quietTripped = await quietBreaker.isTripped
        guard !quietTripped else {
            throw StudioError("backoffProbe: reachable replies tripped the breaker")
        }
        for _ in 0..<4 { _ = await quietBreaker.recordTransportFailure() }
        await quietBreaker.recordReachable()
        for _ in 0..<4 { _ = await quietBreaker.recordTransportFailure() }
        quietTripped = await quietBreaker.isTripped
        guard !quietTripped else {
            throw StudioError("backoffProbe: the failure count did not reset on a reachable reply")
        }

        print("selftest: backoffProbe OK (ladder 1,2,4,8,16 capped at 32 with a ±25% band; "
              + "retry-after honored as a floor; 429/5xx/transport retried and 4xx not; a "
              + "429→500→200 turn took 3 identical attempts and 2 waits; the breaker opens "
              + "on 5 transport failures and resets on any reply)")
    }

    // MARK: - spendMeterProbe

    /// The arithmetic, the unpriced model, the cache hit rate, and a cap that binds.
    static func spendMeterProbe(_ ctx: OnboardingProbeContext) async throws {
        let table: [String: ModelPrice] = [
            "claude-opus-5": ModelPrice(input: 15, output: 75),
            "claude-sonnet-5": ModelPrice(input: 3, output: 15),
            "claude-haiku-5-5": ModelPrice(input: 0.8, output: 4),
        ]

        // 1. A turn with cache reads: input, output, and reads at a tenth of input.
        let turn = APIUsage(inputTokens: 1200, outputTokens: 412, cacheReadTokens: 9000)
        let opus = ModelPrice(input: 15, output: 75)
        let expected = 1200 * 15.0 / 1e6 + 412 * 75.0 / 1e6 + 9000 * 15.0 * 0.1 / 1e6
        guard abs(opus.usd(turn) - expected) < 1e-12 else {
            throw StudioError("spendMeterProbe: a turn priced \(opus.usd(turn)), expected \(expected)")
        }
        // A cache write costs more than the same tokens fresh, and both are counted.
        let firstTurn = APIUsage(inputTokens: 500, outputTokens: 300, cacheWriteTokens: 9000)
        let sonnet = ModelPrice(input: 3, output: 15)
        let expectedFirst = 500 * 3.0 / 1e6 + 300 * 15.0 / 1e6 + 9000 * 3.0 * 1.25 / 1e6
        guard abs(sonnet.usd(firstTurn) - expectedFirst) < 1e-12 else {
            throw StudioError("spendMeterProbe: the first turn priced \(sonnet.usd(firstTurn)), "
                              + "expected \(expectedFirst)")
        }
        // And a cache write is genuinely dearer than the same tokens sent fresh —
        // the multiplier is applied, not ignored.
        let sameTokensFresh = sonnet.usd(APIUsage(inputTokens: 9500, outputTokens: 300))
        guard sonnet.usd(firstTurn) > sameTokensFresh else {
            throw StudioError("spendMeterProbe: 9000 cache-write tokens priced no higher than "
                              + "the same tokens fresh (\(sonnet.usd(firstTurn)) vs \(sameTokensFresh))")
        }

        // 2. Gateway ids are matched leniently for pricing only, longest key first.
        guard PriceTable.price(for: "claude-opus-5", table: table).matched,
              PriceTable.price(for: "anthropic.claude-sonnet-5-v2:0", table: table)
                .price.inputPerMTok == 3,
              PriceTable.price(for: "us.anthropic.claude-haiku-5-5", table: table)
                .price.inputPerMTok == 0.8 else {
            throw StudioError("spendMeterProbe: a gateway model id did not match its family")
        }

        // 3. An unknown model is priced at the table's worst case, not at zero.
        //    A missing price that read as free would silently disable the cap.
        let unknown = PriceTable.price(for: "some-new-model", table: table)
        guard !unknown.matched,
              unknown.price.inputPerMTok == 15, unknown.price.outputPerMTok == 75 else {
            throw StudioError("spendMeterProbe: an unknown model priced \(unknown.price); "
                              + "expected the table's highest rates")
        }
        let meter = SpendMeter(table: table)
        _ = await meter.record(model: "some-new-model", usage: turn)
        guard await meter.unpricedModels.contains("some-new-model"),
              await meter.total.usd > 0 else {
            throw StudioError("spendMeterProbe: an unpriced model was neither charged nor reported")
        }

        // 4. Totals, per-model totals and the cache hit rate.
        let tracked = SpendMeter(table: table)
        _ = await tracked.record(model: "claude-opus-5", usage: firstTurn)
        _ = await tracked.record(model: "claude-opus-5", usage: turn)
        _ = await tracked.record(model: "claude-sonnet-5", usage: turn)
        let total = await tracked.total
        guard total.inputTokens == 2900, total.outputTokens == 1124,
              total.cacheReadTokens == 18000, total.cacheWriteTokens == 9000 else {
            throw StudioError("spendMeterProbe: totals came out as \(total)")
        }
        let byModel = await tracked.byModel
        guard byModel.count == 2, byModel["claude-opus-5"]?.inputTokens == 1700 else {
            throw StudioError("spendMeterProbe: per-model totals are wrong (\(byModel))")
        }
        let rate = await tracked.cacheHitRate(model: "claude-opus-5")
        let wantRate = 9000.0 / (1700.0 + 9000.0 + 9000.0)
        guard abs(rate - wantRate) < 1e-9 else {
            throw StudioError("spendMeterProbe: cache hit rate \(rate), expected \(wantRate)")
        }

        // 5. The cap is checked before a turn starts, not after it is paid for.
        let capped = SpendMeter(capUSD: 0.001, table: table)
        guard await capped.mayStartTurn(model: "claude-opus-5", estimatedInputTokens: 10,
                                        estimatedOutputTokens: 10) else {
            throw StudioError("spendMeterProbe: a tiny turn was refused under a $0.001 cap")
        }
        let bigTurnAllowed = await capped.mayStartTurn(model: "claude-opus-5",
                                                       estimatedInputTokens: 200_000,
                                                       estimatedOutputTokens: 32_000)
        guard !bigTurnAllowed else {
            throw StudioError("spendMeterProbe: a turn costing more than the whole cap was "
                              + "allowed to start; a cap enforced after the fact is always overshot")
        }
        // No cap is the default, and it allows anything.
        let uncapped = SpendMeter(table: table)
        guard await uncapped.capUSD == nil,
              await uncapped.mayStartTurn(model: "claude-opus-5", estimatedInputTokens: 2_000_000,
                                          estimatedOutputTokens: 64_000) else {
            throw StudioError("spendMeterProbe: the default meter is not uncapped")
        }
        // A resumed run counts what the earlier session spent.
        let resumed = SpendMeter(capUSD: 1, table: table)
        var earlier = OnboardingUsage()
        earlier.usd = 0.99
        await resumed.resume(from: earlier, byModel: ["claude-opus-5": earlier])
        let afterResumeAllowed = await resumed.mayStartTurn(model: "claude-opus-5",
                                                            estimatedInputTokens: 100_000,
                                                            estimatedOutputTokens: 16_000)
        guard !afterResumeAllowed else {
            throw StudioError("spendMeterProbe: a resumed run ignored what the earlier session spent")
        }

        // 6. A unit stops at the cap with its history and its spend intact.
        var reply = FixtureTransport.Recording(promptName: "capped", turn: 0)
        reply.body = SelfTest.agentReplyBody(stopReason: "end_turn",
                                             content: [SelfTest.textBlock("never sent")])
        let transport = FixtureTransport(recordings: [reply])
        let endpoint = try SelfTest.probeEndpoint()
        let run = AgentRun(
            config: SelfTest.agentConfig(unitId: "capped", promptName: "capped"),
            transport: transport,
            tools: ClosureTools(specs: [FinishTool.spec]) { _, _, _ in ToolOutcome("{}") },
            apiKey: SelfTest.probeAPIKey,
            endpoint: endpoint,
            meter: SpendMeter(capUSD: 0.000001, table: table),
            breaker: CircuitBreaker(),
            sleep: { _ in })
        let outcome = try await run.run(instructions: .user("Spend money."))
        guard case .capReached = outcome.ending else {
            throw StudioError("spendMeterProbe: a unit under a spent cap ended \(outcome.ending)")
        }
        guard await transport.sent.isEmpty else {
            throw StudioError("spendMeterProbe: a request went out after the cap was reached")
        }
        guard outcome.history.count == 1, outcome.turns == 0 else {
            throw StudioError("spendMeterProbe: the capped unit lost its history")
        }

        // 7. A cost is only ever shown as an estimate.
        guard SpendMeter.format(1.4159) == "$1.42 (estimated)" else {
            throw StudioError("spendMeterProbe: a cost was formatted as \(SpendMeter.format(1.4159))")
        }

        print("selftest: spendMeterProbe OK (cache writes at 1.25x and reads at 0.1x input; "
              + "gateway ids matched by family; an unpriced model billed at the worst rate and "
              + "reported; the cap refuses a turn before it is sent)")
    }
}
