// SelfTestOnboarding+Chat — Onboard to a Codebase, milestone M7 (the playback chat).
//
//   chatContextProbe      — the request for the fixture video at three times (before the
//     first code shot, inside one, after the last chapter): the exact narrated, in-progress
//     and coming-up segment ids, the shot's anchors, the inlined source lines, the shot's
//     facts (no refuted ones), and a cacheable prefix that is byte-identical across all
//     three and across a follow-up.
//   citationParserProbe   — `[[anchor]]` and `[[anchor|label]]` become chips, unresolvable
//     ones become warned text, and a citation still streaming in is held back.
//   chatToolLoopProbe     — a question whose answer needs read_file: the tool returns the
//     file at the pinned commit (not a working-tree edit), the log persists every message,
//     a reopened session resumes with the same history, a failed question is not logged,
//     and a session rolls over after 30 questions.
//   contradictionFlagProbe — flag_contradiction appends one flag to review/flags.json with
//     the segment it concerns, rejects an anchor that does not resolve, shows as an amber
//     card next to a Jump chip, and a flag can be promoted to review/status.json.
//   chatPanelProbe        — the chat and the companion's Flags tab render cream under dark
//     appearance, with the amber flag card visible.
//
// Every request runs through `FixtureTransport`: no key, no network.

import SwiftUI
import AppKit

extension SelfTest {

    static let chatSHA7 = String(FixtureRepoFacts.headSHA.prefix(7))

    static func chatSettings(behindGateway: Bool = false) throws -> AgentRuntimeSettings {
        AgentRuntimeSettings(model: "claude-opus-5", endpoint: try SelfTest.probeEndpoint(),
                             behindGateway: behindGateway, spendCapUSD: nil)
    }

    static func chatStore(_ ctx: OnboardingProbeContext, probe: String) throws -> PackageStore {
        let root = SelfTest.fixturePackageURL(ctx)
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw StudioError("\(probe): run fixturePackageProbe first — \(root.path) is not there")
        }
        return try PackageStore(root: root)
    }

    /// A streamed reply: optional thinking, optional text, then tool calls.
    static func chatSSE(thinking: String? = nil, text: String? = nil,
                        tools: [(id: String, name: String, input: [String: JSONValue])] = [],
                        stopReason: String) -> String {
        var out = SelfTest.sseRecord("message_start", [
            "type": .string("message_start"),
            "message": .object([
                "id": .string("msg_chat_probe"),
                "model": .string("claude-opus-5"),
                "content": .array([]),
                "usage": .object(["input_tokens": .number(900), "output_tokens": .number(1),
                                  "cache_read_input_tokens": .number(4000),
                                  "cache_creation_input_tokens": .number(0)]),
            ]),
        ])
        var index = 0
        func block(_ start: JSONValue, deltas: [JSONValue]) {
            out += SelfTest.sseRecord("content_block_start", [
                "type": .string("content_block_start"), "index": .number(Double(index)),
                "content_block": start,
            ])
            for delta in deltas {
                out += SelfTest.sseRecord("content_block_delta", [
                    "type": .string("content_block_delta"), "index": .number(Double(index)),
                    "delta": delta,
                ])
            }
            out += SelfTest.sseRecord("content_block_stop", [
                "type": .string("content_block_stop"), "index": .number(Double(index)),
            ])
            index += 1
        }
        if let thinking {
            block(.object(["type": .string("thinking"), "thinking": .string("")]), deltas: [
                .object(["type": .string("thinking_delta"), "thinking": .string(thinking)]),
                .object(["type": .string("signature_delta"), "signature": .string("sig-chat-probe")]),
            ])
        }
        if let text {
            // Split mid-citation, so the stream path holds a half-arrived chip back.
            let cut = text.index(text.startIndex, offsetBy: text.count / 2)
            block(.object(["type": .string("text"), "text": .string("")]), deltas: [
                .object(["type": .string("text_delta"), "text": .string(String(text[..<cut]))]),
                .object(["type": .string("text_delta"), "text": .string(String(text[cut...]))]),
            ])
        }
        for tool in tools {
            let json = (try? MessagesRequest.canonicalJSON(.object(tool.input)))
                .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
            block(.object(["type": .string("tool_use"), "id": .string(tool.id),
                           "name": .string(tool.name), "input": .object([:])]), deltas: [
                .object(["type": .string("input_json_delta"), "partial_json": .string(json)]),
            ])
        }
        out += SelfTest.sseRecord("message_delta", [
            "type": .string("message_delta"),
            "delta": .object(["stop_reason": .string(stopReason), "stop_sequence": .null]),
            "usage": .object(["output_tokens": .number(120)]),
        ])
        out += SelfTest.sseRecord("message_stop", ["type": .string("message_stop")])
        return out
    }

    static func chatRecording(_ promptName: String, turn: Int, sse: String) -> FixtureTransport.Recording {
        var recording = FixtureTransport.Recording(promptName: promptName, turn: turn)
        recording.sse = sse
        recording.chunkBytes = 11
        return recording
    }

    static func chatBackend(_ transport: FixtureTransport) -> ChatSession.BackendFactory {
        { ChatSession.Backend(transport: transport, apiKey: SelfTest.probeAPIKey, sleep: { _ in }) }
    }

    /// A JSON value with every `cache_control` removed, so a turn sent once as the
    /// newest (with the moving breakpoint) compares equal to the same turn later.
    static func withoutCacheControl(_ value: JSONValue) -> JSONValue {
        if var object = value.objectValue {
            object["cache_control"] = nil
            return .object(object.mapValues { withoutCacheControl($0) })
        }
        if let array = value.arrayValue {
            return .array(array.map { withoutCacheControl($0) })
        }
        return value
    }

    static func bodyJSON(_ request: MessagesRequest) throws -> [String: JSONValue] {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: try request.body()),
              let object = value.objectValue else {
            throw StudioError("the request body is not a JSON object")
        }
        return object
    }

    // MARK: - chatContextProbe

    static func chatContextProbe(_ ctx: OnboardingProbeContext) async throws {
        let store = try SelfTest.chatStore(ctx, probe: "chatContextProbe")
        let agent = try PlaybackAgent.load(store: store, videoId: FixturePackage.videoID,
                                           settings: try SelfTest.chatSettings())
        let transcript = agent.transcript
        let intervals = agent.coderefs.intervals
        guard let title = intervals.first(where: { $0.shotId == "s01a" }),
              let code = intervals.first(where: { $0.shotId == "s02a" }),
              intervals.last?.shotId == "s05a" else {
            throw StudioError("chatContextProbe: the fixture video's shots are not s01a…s05a")
        }
        let times: [(label: String, t: Double)] = [
            ("before the first code shot", (title.start + title.end) / 2),
            ("inside a code shot", (code.start + code.end) / 2),
            ("after the last chapter", transcript.duration + 1),
        ]

        var bodies: [[String: JSONValue]] = []
        var contexts: [PlaybackContext] = []
        for (label, t) in times {
            let (request, context) = await agent.buildRequest(t: t, question: "What am I looking at?",
                                                              history: [])
            contexts.append(context)
            bodies.append(try SelfTest.bodyJSON(request))

            // The segments, computed here from first principles.
            let narrated = transcript.segments.filter { $0.end <= t }.map { $0.id }
            let inProgress = transcript.segments.first { $0.start <= t && t < $0.end }?.id
            let coming = transcript.segments.filter { $0.start > t }.prefix(2).map { $0.id }
            guard context.narratedIds == narrated, context.inProgressId == inProgress,
                  context.comingUpIds == Array(coming),
                  context.verbatimIds == Array(narrated.suffix(PlaybackAgent.verbatimSegments)) else {
                throw StudioError("chatContextProbe: \(label) (t=\(t)) the context has narrated "
                                  + "\(context.narratedIds), in progress \(context.inProgressId ?? "none"), "
                                  + "coming up \(context.comingUpIds); expected \(narrated), "
                                  + "\(inProgress ?? "none"), \(coming)")
            }
            guard let interval = agent.coderefs.lookup(t), context.shotId == interval.shotId,
                  context.intervalAnchors == interval.anchors else {
                throw StudioError("chatContextProbe: \(label) the on-screen shot is \(context.shotId ?? "none") "
                                  + "with anchors \(context.intervalAnchors)")
            }
            // Coming-up narration is marked as not yet heard, and is not in narrated_so_far.
            for id in coming {
                guard let segment = transcript.segments.first(where: { $0.id == id }),
                      context.text.contains("(not yet narrated) \(segment.text)") else {
                    throw StudioError("chatContextProbe: \(label) coming-up \(id) is not marked not yet narrated")
                }
            }
            guard let narratedBlock = context.text.components(separatedBy: "</narrated_so_far>").first else {
                throw StudioError("chatContextProbe: \(label) has no narrated_so_far block")
            }
            for id in coming {
                if let segment = transcript.segments.first(where: { $0.id == id }),
                   narratedBlock.contains(segment.text) {
                    throw StudioError("chatContextProbe: \(label) narrated_so_far contains \(id), "
                                      + "which the viewer has not heard")
                }
            }
            guard context.text.contains("<on_screen t=\"\(PackageTools.seconds(t))\""),
                  context.text.contains("<coming_up>"),
                  context.text.hasSuffix("</viewer_question>") else {
                throw StudioError("chatContextProbe: \(label) the user turn is missing a section")
            }
        }

        // Before the first code shot: only the title shot's narration can have been heard.
        let before = contexts[0]
        let titleIds = Set(transcript.segments.filter { $0.shotId == "s01a" }.map { $0.id })
        guard before.narratedIds.allSatisfy({ titleIds.contains($0) }) else {
            throw StudioError("chatContextProbe: before the first code shot, narrated \(before.narratedIds)")
        }

        // Inside the code shot: its anchor, the highlighted source with 20 lines of
        // context, read at the pinned commit, and its facts.
        let inside = contexts[1]
        let anchor = "code:src/api/orders_handler.py@\(SelfTest.chatSHA7)#L6-L11"
        guard inside.shotId == "s02a", inside.intervalAnchors == [anchor] else {
            throw StudioError("chatContextProbe: inside the code shot the anchors are \(inside.intervalAnchors)")
        }
        guard let lines = await agent.source.lines(of: "src/api/orders_handler.py"), lines.count >= 11 else {
            throw StudioError("chatContextProbe: the pinned source of orders_handler.py did not load")
        }
        let expected = 1...min(lines.count, 11 + PlaybackAgent.contextLines)
        guard inside.inlinedPath == "src/api/orders_handler.py", inside.inlinedLines == expected else {
            throw StudioError("chatContextProbe: inlined \(inside.inlinedPath ?? "nothing") "
                              + "\(String(describing: inside.inlinedLines)), expected \(expected)")
        }
        let numbered = PackageTools.numbered(lines, from: expected.lowerBound, to: expected.upperBound)
        guard inside.text.contains(numbered), inside.text.contains(lines[5]) else {
            throw StudioError("chatContextProbe: the inlined source is not the file's lines \(expected)")
        }
        guard inside.factIds.first == "F-map-src-002", !inside.factIds.contains("F-map-src-001"),
              inside.factIds.count <= PlaybackAgent.maxShotFacts else {
            throw StudioError("chatContextProbe: the code shot's facts are \(inside.factIds); expected "
                              + "F-map-src-002 first and never the refuted F-map-src-001")
        }
        let usable = Set(agent.usableFacts.map { $0.id })
        guard inside.factIds.allSatisfy({ usable.contains($0) }) else {
            throw StudioError("chatContextProbe: a proposed or refuted fact reached the on-screen block")
        }

        // After the last chapter: everything heard, nothing coming, the diagram inlined.
        let after = contexts[2]
        guard after.narratedIds == transcript.segments.map({ $0.id }), after.inProgressId == nil,
              after.comingUpIds.isEmpty, after.text.contains("(the narration is over)") else {
            throw StudioError("chatContextProbe: after the last chapter the context is "
                              + "\(after.narratedIds.count) narrated, coming up \(after.comingUpIds)")
        }
        guard after.text.contains("```mermaid"), after.text.contains("[[diagram:c4-container#d_db]]") else {
            throw StudioError("chatContextProbe: the diagram shot did not inline its source and focus nodes")
        }

        // The cacheable prefix: tools, system and every request setting identical
        // across all three times.
        let prefixKeys = ["model", "max_tokens", "stream", "thinking", "output_config", "system",
                          "tools", "tool_choice", "fallbacks"]
        func prefixBytes(_ body: [String: JSONValue]) throws -> Data {
            var object: [String: JSONValue] = [:]
            for key in prefixKeys { object[key] = body[key] ?? .null }
            return try MessagesRequest.canonicalJSON(.object(object))
        }
        let first = try prefixBytes(bodies[0])
        for (index, body) in bodies.enumerated() {
            if try prefixBytes(body) != first {
                throw StudioError("chatContextProbe: the request prefix at \(times[index].label) differs "
                                  + "from the first; follow-ups would miss the cache")
            }
        }
        let body = bodies[0]
        guard body["stream"]?.boolValue == true, body["max_tokens"]?.numberValue == 8000,
              body["thinking"]?.objectValue?["type"]?.stringValue == "adaptive",
              body["output_config"]?.objectValue?["effort"]?.stringValue == "medium",
              body["fallbacks"]?.stringValue == "default",
              body["tool_choice"]?.objectValue?["type"]?.stringValue == "auto" else {
            throw StudioError("chatContextProbe: the request settings are not ARCHITECTURE 8's")
        }
        let system = body["system"]?.arrayValue ?? []
        guard system.count == 3, system[2].objectValue?["cache_control"] != nil,
              system[0].objectValue?["cache_control"] == nil, system[1].objectValue?["cache_control"] == nil,
              system[1].objectValue?["text"]?.stringValue?.contains(FixtureRepoFacts.headSHA) == true,
              system[2].objectValue?["text"]?.stringValue?.contains("[[video:\(FixturePackage.videoID)#t=") == true else {
            throw StudioError("chatContextProbe: the system blocks are not role, digest, video with "
                              + "the breakpoint after the third")
        }
        let toolNames = (body["tools"]?.arrayValue ?? []).compactMap { $0.objectValue?["name"]?.stringValue }
        guard toolNames == PackageTools.names, toolNames == toolNames.sorted() else {
            throw StudioError("chatContextProbe: the tools are \(toolNames)")
        }

        // A follow-up re-sends the first turn unchanged.
        let (turn, _) = await agent.userTurn(t: times[1].t, question: "What am I looking at?")
        let reply = AgentMessage(role: .assistant, content: [.text("The order handler.")])
        let (followUp, _) = await agent.buildRequest(t: times[1].t + 1, question: "And then?",
                                                     history: [turn, reply])
        let followBody = try SelfTest.bodyJSON(followUp)
        guard try prefixBytes(followBody) == first,
              let sent = followBody["messages"]?.arrayValue, sent.count == 3,
              let original = bodies[1]["messages"]?.arrayValue?.first,
              SelfTest.withoutCacheControl(sent[0]) == SelfTest.withoutCacheControl(original),
              followUp.promptName == "\(PlaybackAgent.promptName)-q2" else {
            throw StudioError("chatContextProbe: a follow-up did not re-send the first turn unchanged")
        }

        // Behind a gateway: no fallbacks field, no beta header.
        let gateway = try PlaybackAgent.load(store: store, videoId: FixturePackage.videoID,
                                             settings: try SelfTest.chatSettings(behindGateway: true))
        let (gatewayRequest, _) = await gateway.buildRequest(t: 1, question: "Hi", history: [])
        guard try SelfTest.bodyJSON(gatewayRequest)["fallbacks"] == nil, gatewayRequest.betas.isEmpty else {
            throw StudioError("chatContextProbe: a gateway request carried the fallback beta")
        }

        try? inside.text.write(to: ctx.outDir.appendingPathComponent("chat-context-inside.txt"),
                               atomically: true, encoding: .utf8)
        print("selftest: chatContextProbe OK (3 times: segments, shot, inlined L\(expected.lowerBound)-"
              + "L\(expected.upperBound), \(inside.factIds.count) facts, identical prefix)")
    }

    // MARK: - citationParserProbe

    static func citationParserProbe(_ ctx: OnboardingProbeContext) async throws {
        let code = "code:src/api/orders_handler.py@\(SelfTest.chatSHA7)#L6-L11"
        let reply = "It reads the body [[\(code)]] and the doc says so [[doc:architecture#entry-points|the entry points]]."
        let parsed = CitationParser.parse(reply, resolve: { _ in true })
        guard parsed.runs == [
            .text("It reads the body "),
            .citation(anchor: code, label: MarkdownLite.anchorLabel(code), resolved: true),
            .text(" and the doc says so "),
            .citation(anchor: "doc:architecture#entry-points", label: "the entry points", resolved: true),
            .text("."),
        ], parsed.pending.isEmpty else {
            throw StudioError("citationParserProbe: parsed \(parsed.runs)")
        }

        // Unresolvable: the router says no, or the anchor is not an anchor.
        let dead = CitationParser.parse("See [[\(code)]] and [[nonsense here]].", resolve: { _ in false })
        guard dead.citations.count == 2, dead.citations.allSatisfy({ !$0.resolved }) else {
            throw StudioError("citationParserProbe: unresolvable citations came out \(dead.citations)")
        }
        let malformed = CitationParser.parse("[[not an anchor]]", resolve: { _ in true })
        guard malformed.citations.count == 1, malformed.citations[0].resolved == false else {
            throw StudioError("citationParserProbe: a malformed anchor resolved")
        }

        // A literal bracket beside a citation stays text.
        let bracketed = CitationParser.parse("[[[doc:architecture#containers]]]", resolve: { _ in true })
        guard bracketed.citations.map({ $0.anchor }) == ["doc:architecture#containers"],
              bracketed.plainText.hasPrefix("["), bracketed.plainText.hasSuffix("]") else {
            throw StudioError("citationParserProbe: [[[anchor]]] parsed as \(bracketed.runs)")
        }

        // Streaming: a half-arrived citation is held back, then becomes a chip.
        let partial = CitationParser.parse("Look at [[code:src/a.p", final: false, resolve: { _ in true })
        guard partial.runs == [.text("Look at ")], partial.pending == "[[code:src/a.p" else {
            throw StudioError("citationParserProbe: a streaming citation was not held back: "
                              + "\(partial.runs) pending \(partial.pending)")
        }
        let lone = CitationParser.parse("Look at [", final: false, resolve: { _ in true })
        guard lone.pending == "[" else {
            throw StudioError("citationParserProbe: a trailing [ was not held back")
        }
        let literal = CitationParser.parse("a [[b\nc", final: false, resolve: { _ in true })
        guard literal.pending.isEmpty, literal.plainText == "a [[b\nc" else {
            throw StudioError("citationParserProbe: a [[ with a newline after it froze the stream")
        }
        // Every prefix of a streamed reply shows no raw `[[`, and the final parse
        // equals the whole-text parse.
        var streamed = ""
        for character in reply {
            streamed.append(character)
            let step = CitationParser.parse(streamed, final: false, resolve: { _ in true })
            for run in step.runs {
                if case .text(let text) = run, text.contains("[[") {
                    throw StudioError("citationParserProbe: mid-stream text showed a raw [[: \(text)")
                }
            }
        }
        guard CitationParser.parse(streamed, final: true, resolve: { _ in true }) == parsed else {
            throw StudioError("citationParserProbe: the streamed parse differs from the whole one")
        }
        print("selftest: citationParserProbe OK (chips, labels, dead anchors, held-back stream)")
    }

    // MARK: - chatToolLoopProbe

    static func chatToolLoopProbe(_ ctx: OnboardingProbeContext) async throws {
        let store = try SelfTest.chatStore(ctx, probe: "chatToolLoopProbe")
        try? store.removeItem("chat")

        // A checkout at the pinned commit with an uncommitted edit: the tool must
        // return the commit, not the working tree (ON-9.3).
        let checkout = ctx.scratch.appendingPathComponent("chat-checkout", isDirectory: true)
        try? FileManager.default.removeItem(at: checkout)
        try FileManager.default.copyItem(at: ctx.fixtureRepo, to: checkout)
        let edited = checkout.appendingPathComponent("src/api/orders_handler.py")
        let pinned = try String(contentsOf: edited, encoding: .utf8)
        try ("# a local edit that is not committed\n" + pinned).write(to: edited, atomically: true, encoding: .utf8)

        let agent = try PlaybackAgent.load(store: store, videoId: FixturePackage.videoID,
                                           settings: try SelfTest.chatSettings(), repo: checkout)
        guard agent.source.repo != nil else {
            throw StudioError("chatToolLoopProbe: the checkout was not used as the source")
        }
        let anchor = "code:src/api/orders_handler.py@\(SelfTest.chatSHA7)#L6-L11"
        let transport = FixtureTransport(recordings: [
            SelfTest.chatRecording("playback-chat-q1", turn: 0, sse: SelfTest.chatSSE(
                text: "Let me read the handler.",
                tools: [(id: "toolu_chat_1", name: "read_file",
                         input: ["path": .string("src/api/orders_handler.py"),
                                 "startLine": .number(6), "endLine": .number(11)])],
                stopReason: "tool_use")),
            SelfTest.chatRecording("playback-chat-q1", turn: 1, sse: SelfTest.chatSSE(
                thinking: "The header names the anchor.",
                text: "It takes user_id from the request body [[\(anchor)]].",
                stopReason: "end_turn")),
            SelfTest.chatRecording("playback-chat-q2", turn: 0, sse: SelfTest.chatSSE(
                text: "The service sums the line items.", stopReason: "end_turn")),
        ])
        let review = ReviewFiles(store: store)
        let session = ChatSession(agent: agent, review: review, backend: SelfTest.chatBackend(transport))
        let code = agent.coderefs.intervals.first { $0.shotId == "s02a" }
        let t = code.map { ($0.start + $0.end) / 2 } ?? 10

        await session.ask("Where does user_id come from?", at: t)
        let sent = await transport.sent
        guard sent.count == 2 else {
            throw StudioError("chatToolLoopProbe: \(sent.count) request(s) were sent, expected 2 "
                              + "(question, then tool result); items \(session.items)")
        }
        let second = try SelfTest.requestJSON(sent[1])
        let toolResult = second["messages"]?.arrayValue?.last?.objectValue?["content"]?.arrayValue?
            .first?.objectValue
        let resultText = toolResult?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue ?? ""
        let pinnedLines = pinned.components(separatedBy: "\n")
        guard toolResult?["type"]?.stringValue == "tool_result",
              resultText.hasPrefix("code:src/api/orders_handler.py@\(SelfTest.chatSHA7)#L6-L11"),
              resultText.contains(" 6 | " + pinnedLines[5]),
              !resultText.contains("a local edit") else {
            throw StudioError("chatToolLoopProbe: read_file returned \(resultText.prefix(200)) — "
                              + "expected the pinned lines 6-11")
        }

        // The rows: question, tool row, answer with a resolved chip.
        let kinds = session.items.map { $0.kind }
        guard case .question? = kinds.first,
              kinds.contains(.tool("reading src/api/orders_handler.py lines 6-11")),
              kinds.contains(where: {
                  if case .answer(let parsed) = $0 {
                      return parsed.citations.contains { $0.anchor == anchor && $0.resolved }
                  }
                  return false
              }) else {
            throw StudioError("chatToolLoopProbe: the panel rows are \(kinds)")
        }

        // The log holds every message, thinking included, and a reopened session
        // resumes the same conversation.
        let log = ChatSession.readLog(store: store, path: session.logPath)
        guard log.count == 1, log[0].messages.count == 4,
              log[0].messages[3].content.contains(where: { $0.isThinking }) else {
            throw StudioError("chatToolLoopProbe: the log has \(log.count) entries with "
                              + "\(log.first?.messages.count ?? 0) messages, expected 1 with 4")
        }
        let reopened = ChatSession(agent: agent, review: review, backend: SelfTest.chatBackend(transport))
        guard reopened.history == session.history, reopened.items == session.items,
              reopened.sessionId == ChatSession.sessionID(number: 1) else {
            throw StudioError("chatToolLoopProbe: a reopened session did not resume the conversation")
        }

        // A follow-up sends the whole history first, unchanged.
        await reopened.ask("And the total?", at: t + 2)
        let third = try SelfTest.requestJSON(await transport.sent[2])
        let messages = third["messages"]?.arrayValue ?? []
        let history = try reopened.history.prefix(4).map { message -> JSONValue in
            let data = try MessagesRequest.canonicalJSON(message.wire)
            return try JSONDecoder().decode(JSONValue.self, from: data)
        }
        guard messages.count == 5,
              Array(messages.prefix(4)).map(SelfTest.withoutCacheControl) == history.map(SelfTest.withoutCacheControl) else {
            throw StudioError("chatToolLoopProbe: the follow-up sent \(messages.count) messages; "
                              + "the history was not replayed verbatim")
        }

        // A question that fails is not logged and comes back to the input.
        var bad = FixtureTransport.Recording(promptName: "playback-chat-q3", turn: 0, status: 400)
        bad.body = .object(["type": .string("error"), "error": .object([
            "type": .string("invalid_request_error"), "message": .string("probe: rejected")])])
        await transport.add(bad)
        await reopened.ask("Will this fail?", at: t + 3)
        guard reopened.questionCount == 2, reopened.draft == "Will this fail?",
              case .notice? = reopened.items.last?.kind,
              ChatSession.readLog(store: store, path: reopened.logPath).count == 2 else {
            throw StudioError("chatToolLoopProbe: a failed question was logged or lost")
        }

        // After 30 questions the session rolls over, carrying a summary.
        try? store.removeItem("chat")
        let filler = (1...PlaybackAgent.questionsPerSession).map { n in
            ChatLogEntry(kind: "turn", t: Double(n), question: "Question \(n)?", messages: [
                .user("<viewer_question>\nQuestion \(n)?\n</viewer_question>"),
                AgentMessage(role: .assistant, content: [.text("Answer \(n). More detail.")]),
            ], ending: "end_turn")
        }
        let encoder = OnboardingJSON.lineEncoder()
        let lines = try filler.map { String(decoding: try encoder.encode($0), as: UTF8.self) }
        try store.writeAtomically(lines.joined(separator: "\n") + "\n",
                                  to: "chat/\(FixturePackage.videoID)/\(ChatSession.sessionID(number: 1)).jsonl")
        let rollTransport = FixtureTransport(recordings: [
            SelfTest.chatRecording("playback-chat-q1", turn: 0, sse: SelfTest.chatSSE(
                text: "Fresh session.", stopReason: "end_turn")),
        ])
        let full = ChatSession(agent: agent, review: review, backend: SelfTest.chatBackend(rollTransport))
        guard full.questionCount == PlaybackAgent.questionsPerSession else {
            throw StudioError("chatToolLoopProbe: the filler log loaded \(full.questionCount) questions")
        }
        await full.ask("Question 31?", at: 31)
        let rolled = try SelfTest.requestJSON(await rollTransport.sent[0])
        let firstTurn = rolled["messages"]?.arrayValue?.first?.objectValue?["content"]?.arrayValue?
            .first?.objectValue?["text"]?.stringValue ?? ""
        guard full.sessionId == ChatSession.sessionID(number: 2),
              rolled["messages"]?.arrayValue?.count == 1,
              firstTurn.hasPrefix("<earlier_conversation>"),
              firstTurn.contains("Q: Question 30? A: Answer 30."),
              ChatSession.readLog(store: store, path: full.logPath).map({ $0.kind }) == ["summary", "turn"] else {
            throw StudioError("chatToolLoopProbe: the session did not roll over after "
                              + "\(PlaybackAgent.questionsPerSession) questions (now \(full.sessionId))")
        }
        try? store.removeItem("chat")
        print("selftest: chatToolLoopProbe OK (pinned read_file, logged + resumed, failure not logged, "
              + "rollover at \(PlaybackAgent.questionsPerSession))")
    }

    // MARK: - contradictionFlagProbe

    static func contradictionFlagProbe(_ ctx: OnboardingProbeContext) async throws {
        let store = try SelfTest.chatStore(ctx, probe: "contradictionFlagProbe")
        try? store.removeItem("chat")
        try? store.removeItem(ReviewFiles.flagsPath)
        try? store.removeItem(ReviewFiles.statusPath)

        let agent = try PlaybackAgent.load(store: store, videoId: FixturePackage.videoID,
                                           settings: try SelfTest.chatSettings())
        guard let repoShot = agent.coderefs.intervals.first(where: { $0.shotId == "s04a" }) else {
            throw StudioError("contradictionFlagProbe: the fixture has no s04a shot")
        }
        let t = (repoShot.start + repoShot.end) / 2
        let anchor = "code:src/repo/orders_repo.py@\(SelfTest.chatSHA7)#L7-L9"
        let claim = "The repository closes its connection after every request."
        let reason = "Lines 7-9 open a connection in __init__ and nothing closes it."
        let transport = FixtureTransport(recordings: [
            SelfTest.chatRecording("playback-chat-q1", turn: 0, sse: SelfTest.chatSSE(
                text: "That is not what the code does.",
                tools: [
                    (id: "toolu_flag_1", name: "flag_contradiction",
                     input: ["videoId": .string(FixturePackage.videoID), "t": .number(t),
                             "anchor": .string(anchor), "claim": .string(claim), "reason": .string(reason)]),
                    (id: "toolu_seek_1", name: "seek_video",
                     input: ["t": .number(repoShot.start), "why": .string("where the connection opens")]),
                ],
                stopReason: "tool_use")),
            SelfTest.chatRecording("playback-chat-q1", turn: 1, sse: SelfTest.chatSSE(
                text: "The narration is wrong here: nothing closes it [[\(anchor)]].",
                stopReason: "end_turn")),
        ])
        let review = ReviewFiles(store: store)
        let session = ChatSession(agent: agent, review: review, backend: SelfTest.chatBackend(transport))
        var refreshed = false
        session.onFlagsChanged = { refreshed = true }
        await session.ask("Does it close the connection?", at: t)

        let flags = await review.flags()
        guard flags.count == 1, let flag = flags.first, flag.anchor == anchor, flag.claim == claim,
              flag.videoId == FixturePackage.videoID,
              flag.segmentId == agent.transcript.segment(at: t)?.id, flag.segmentId != nil else {
            throw StudioError("contradictionFlagProbe: review/flags.json holds \(flags)")
        }
        guard refreshed else {
            throw StudioError("contradictionFlagProbe: the Flags tab was not told to refresh")
        }
        let kinds = session.items.map { $0.kind }
        guard kinds.contains(.flag(claim: claim, reason: reason, anchor: anchor)),
              kinds.contains(.jump(t: repoShot.start, why: "where the connection opens")) else {
            throw StudioError("contradictionFlagProbe: the panel rows are \(kinds)")
        }

        // The same flag twice is recorded once; an anchor that opens nothing is refused.
        try await review.append(ContradictionFlag(videoId: flag.videoId, t: flag.t, segmentId: flag.segmentId,
                                                  anchor: flag.anchor, claim: flag.claim, reason: flag.reason))
        let tools = agent.tools(review: review)
        let refused = await tools.run(name: "flag_contradiction", input: [
            "videoId": .string(FixturePackage.videoID), "t": .number(t),
            "anchor": .string("code:src/nope.py@\(SelfTest.chatSHA7)#L1-L2"),
            "claim": .string("x"), "reason": .string("y"),
        ], toolUseId: "toolu_bad")
        guard refused.isError, await review.flags().count == 1 else {
            throw StudioError("contradictionFlagProbe: a duplicate or dangling flag was recorded")
        }
        guard case .tool = ChatSession.row(for: "flag_contradiction", input: [:], failed: true) else {
            throw StudioError("contradictionFlagProbe: a refused flag would still show as a card")
        }

        // Promote to the review list with a note, then clear.
        try await review.promote(deliverableId: "video:\(FixturePackage.videoID)", note: "first")
        try await review.promote(deliverableId: "video:\(FixturePackage.videoID)", note: "second")
        let status = await review.status()["video:\(FixturePackage.videoID)"]
        guard status?.state == "fix", status?.note == "first\nsecond" else {
            throw StudioError("contradictionFlagProbe: review/status.json holds \(String(describing: status))")
        }
        try await review.removeFlag(id: flag.id)
        guard await review.flags().isEmpty else {
            throw StudioError("contradictionFlagProbe: clearing the flag left it in flags.json")
        }
        // Put it back for chatPanelProbe's Flags tab.
        try await review.append(flag)
        print("selftest: contradictionFlagProbe OK (one flag at \(flag.segmentId ?? "?"), amber card + "
              + "jump chip, duplicate and dangling refused, promoted to status.json)")
    }

    // MARK: - chatPanelProbe

    static func chatPanelProbe(_ ctx: OnboardingProbeContext) async throws {
        let root = SelfTest.fixturePackageURL(ctx)
        let vm = OnboardingViewModel()
        await vm.open(packageAt: root)
        await vm.play(videoID: FixturePackage.videoID)
        vm.player.pause()
        guard let store = vm.store, vm.chat != nil else {
            throw StudioError("chatPanelProbe: playing the video did not start a chat: "
                              + (vm.notices.last?.message ?? "no notice"))
        }
        guard vm.flags.count == 1 else {
            throw StudioError("chatPanelProbe: the Flags tab shows \(vm.flags.count) flag(s), expected the "
                              + "one contradictionFlagProbe left")
        }

        // The panel over contradictionFlagProbe's conversation.
        let agent = try PlaybackAgent.load(store: store, videoId: FixturePackage.videoID,
                                           settings: try SelfTest.chatSettings())
        let session = ChatSession(agent: agent, review: ReviewFiles(store: store),
                                  backend: SelfTest.chatBackend(FixtureTransport()))
        guard session.items.contains(where: { if case .flag = $0.kind { return true } else { return false } }) else {
            throw StudioError("chatPanelProbe: run contradictionFlagProbe first — no flag in the conversation")
        }
        let size = CGSize(width: 360, height: 640)
        let image = try await SelfTest.snapshot(ChatPanel(vm: vm, session: session), size: size,
                                                named: "chat-panel", into: ctx.outDir)
        try SelfTest.assertBrandCream(image, x: 3, y: 3, what: "the chat panel's corner")
        try SelfTest.assertBrandCream(image, x: 3, y: Int(image.height) - 3, what: "the chat input's corner")
        guard SelfTest.containsAmber(image) else {
            throw StudioError("chatPanelProbe: no amber flag card in chat-panel.png")
        }

        vm.companionTab = .flags
        let flagsImage = try await SelfTest.snapshot(CompanionPanel(vm: vm, clock: vm.clock),
                                                     size: CGSize(width: 340, height: 720),
                                                     named: "companion-flags", into: ctx.outDir)
        try SelfTest.assertBrandCream(flagsImage, x: 3, y: 3, what: "the companion's Flags tab")

        let before = vm.chatFocusRequest
        vm.focusChat()
        guard vm.companionTab == .chat, vm.chatFocusRequest == before + 1 else {
            throw StudioError("chatPanelProbe: ? did not switch to the chat and focus it")
        }
        let chatImage = try await SelfTest.snapshot(CompanionPanel(vm: vm, clock: vm.clock),
                                                    size: CGSize(width: 340, height: 720),
                                                    named: "companion-chat", into: ctx.outDir)
        try SelfTest.assertBrandCream(chatImage, x: 3, y: 3, what: "the companion's Chat tab")
        try? store.removeItem("chat")
        print("selftest: chatPanelProbe OK (chat and companion tabs cream under dark appearance, amber card)")
    }

    /// Any pixel close to the flag card's amber stroke.
    static func containsAmber(_ image: CGImage) -> Bool {
        let rep = NSBitmapImageRep(cgImage: image)
        for y in stride(from: 0, to: rep.pixelsHigh, by: 1) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                guard let colour = rep.colorAt(x: x, y: y) else { continue }
                let r = colour.redComponent * 255, g = colour.greenComponent * 255, b = colour.blueComponent * 255
                if r > 215, g > 140, g < 205, b < 110 { return true }
            }
        }
        return false
    }
}
