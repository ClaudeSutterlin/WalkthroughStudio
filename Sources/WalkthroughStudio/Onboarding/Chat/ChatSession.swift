// ChatSession.swift — "Onboard to a Codebase", milestone M7 (playback chat).
//
// One conversation about one video (ARCHITECTURE 8): the history the model sees,
// the rows the panel shows, and the log on disk, kept in step.
//
// The log is the source of truth. `chat/<videoId>/<sessionId>.jsonl` holds one line
// per answered question with every message that question added, thinking blocks
// included and unchanged, so a reopened package resumes the same conversation and
// the prompt cache still matches it. The panel's rows are *derived* from the log,
// never kept beside it: a row that is not in the log is a row the next launch
// would silently lose.
//
// What is not logged: a question that never got an answer. A thrown error, the
// spend cap or the circuit breaker leaves the log untouched and puts the question
// back in the input, because a question in the history with no reply after it is a
// malformed conversation the next request would be rejected for.

import Foundation

/// One line of a chat log.
struct ChatLogEntry: Codable, Equatable {
    /// "turn" for an answered question, "summary" for the opening line of a
    /// session that rolled over.
    var kind: String
    var t: Double
    /// The viewer's words, or the summary text.
    var question: String
    var at: Date = OnboardingJSON.now()
    /// Every message this question added: the user turn first.
    var messages: [AgentMessage] = []
    var ending: String = ""
    var notices: [String] = []
    var usd: Double = 0

    init(kind: String, t: Double, question: String, messages: [AgentMessage] = [],
         ending: String = "", notices: [String] = [], usd: Double = 0) {
        self.kind = kind
        self.t = t
        self.question = question
        self.messages = messages
        self.ending = ending
        self.notices = notices
        self.usd = usd
    }

    private enum CodingKeys: String, CodingKey { case kind, t, question, at, messages, ending, notices, usd }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? "turn"
        t = try c.decodeIfPresent(Double.self, forKey: .t) ?? 0
        question = try c.decodeIfPresent(String.self, forKey: .question) ?? ""
        at = try c.decodeIfPresent(Date.self, forKey: .at) ?? OnboardingJSON.now()
        messages = try c.decodeIfPresent([AgentMessage].self, forKey: .messages) ?? []
        ending = try c.decodeIfPresent(String.self, forKey: .ending) ?? ""
        notices = try c.decodeIfPresent([String].self, forKey: .notices) ?? []
        usd = try c.decodeIfPresent(Double.self, forKey: .usd) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(t, forKey: .t)
        try c.encode(question, forKey: .question)
        try c.encode(at, forKey: .at)
        try c.encode(messages, forKey: .messages)
        try c.encode(ending, forKey: .ending)
        try c.encode(notices, forKey: .notices)
        try c.encode(usd, forKey: .usd)
    }
}

/// A row of the chat panel.
struct ChatItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case question(String, t: Double)
        case answer(CitationParser.Parsed)
        /// "reading src/api/orders_handler.py" — one per tool call.
        case tool(String)
        /// A `seek_video` proposal. The video moves only when the viewer clicks.
        case jump(t: Double, why: String)
        /// A `flag_contradiction` the tool recorded.
        case flag(claim: String, reason: String, anchor: String)
        case notice(String)
    }

    var id: String
    var kind: Kind
}

@MainActor
final class ChatSession: ObservableObject {

    /// How a question reaches the API. Built when a question is asked, not when the
    /// session is: production reads the key from the Keychain, and reading the
    /// Keychain while a view is being built can freeze the app (CLAUDE.md, landmine 5).
    struct Backend {
        var transport: MessagesTransport
        var apiKey: String
        var sleep: AgentSleep = agentRealSleep
    }
    typealias BackendFactory = @MainActor () throws -> Backend

    static func liveBackend() throws -> Backend {
        let key = Keychain.anthropicKey
        guard !key.isEmpty else {
            throw StudioError("Add your Anthropic API key in Settings to ask about this video.")
        }
        return Backend(transport: URLSessionTransport(), apiKey: key)
    }

    // MARK: State

    /// The persisted conversation, as rows.
    @Published private(set) var items: [ChatItem] = []
    /// The answer being written right now, as rows.
    @Published private(set) var live: [ChatItem] = []
    @Published private(set) var isAnswering = false
    /// The input box. A question that fails comes back here.
    @Published var draft = ""
    @Published private(set) var spentUSD: Double = 0
    @Published private(set) var sessionId: String

    let agent: PlaybackAgent
    let review: ReviewFiles
    private let router: LinkRouter
    private let tools: PackageTools
    private let meter: SpendMeter
    private let breaker = CircuitBreaker()
    private let backend: BackendFactory
    private(set) var entries: [ChatLogEntry] = []
    private(set) var history: [AgentMessage] = []
    /// Called after a turn recorded a flag, so the companion's Flags tab refreshes.
    var onFlagsChanged: (@MainActor () -> Void)?

    // Live-stream bookkeeping. `committed` is the text of request turns that
    // finished; `pending` is the turn being streamed, thrown away on a retry.
    private var committed = ""
    private var pending = ""
    private var liveTools: [String] = []
    private var liveTurn = -1

    var questionCount: Int { entries.filter { $0.kind == "turn" }.count }

    init(agent: PlaybackAgent, review: ReviewFiles, backend: @escaping BackendFactory = ChatSession.liveBackend) {
        self.agent = agent
        self.review = review
        self.backend = backend
        self.tools = agent.tools(review: review)
        self.router = LinkRouter(store: agent.store, headSHA: agent.headSHA,
                                 factIDs: Set(agent.describableFacts.keys))
        self.meter = SpendMeter(capUSD: agent.settings.spendCapUSD)
        let ids = ChatSession.sessionIDs(store: agent.store, videoId: agent.videoId)
        self.sessionId = ids.last ?? ChatSession.sessionID(number: 1)
        self.entries = ChatSession.readLog(store: agent.store, path: logPath)
        self.history = entries.flatMap { $0.messages }
        self.spentUSD = entries.reduce(0) { $0 + $1.usd }
        rebuildItems()
    }

    // MARK: Files

    var logPath: String { "chat/\(agent.videoId)/\(sessionId).jsonl" }

    static func sessionID(number: Int) -> String { String(format: "session-%03d", number) }

    static func sessionIDs(store: PackageStore, videoId: String) -> [String] {
        store.listing("chat/\(videoId)")
            .filter { $0.hasSuffix(".jsonl") }
            .map { String($0.dropLast(6)) }
            .sorted()
    }

    static func readLog(store: PackageStore, path: String) -> [ChatLogEntry] {
        guard let text = try? store.readString(path) else { return [] }
        let decoder = OnboardingJSON.decoder()
        return text.split(separator: "\n").compactMap {
            try? decoder.decode(ChatLogEntry.self, from: Data($0.utf8))
        }
    }

    private func appendToLog(_ entry: ChatLogEntry) throws {
        let data = try OnboardingJSON.lineEncoder().encode(entry)
        let line = String(decoding: data, as: UTF8.self) + "\n"
        let target = agent.store.url(logPath)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let bytes = Data(line.utf8)
        guard FileManager.default.fileExists(atPath: target.path) else {
            try bytes.write(to: target)
            return
        }
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: bytes)
    }

    // MARK: Asking

    /// Asks `question` at video time `t` and waits for the whole answer.
    func ask(_ question: String, at t: Double) async {
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty, !isAnswering else { return }
        isAnswering = true
        draft = ""
        defer {
            isAnswering = false
            live = []
        }

        if questionCount >= PlaybackAgent.questionsPerSession {
            rollOver()
        }
        let earlier = history.isEmpty ? entries.last(where: { $0.kind == "summary" })?.question : nil

        let backend: Backend
        do {
            backend = try self.backend()
        } catch {
            fail(asked, notice: ChatSession.describe(error))
            return
        }

        let (turn, _) = await agent.userTurn(t: t, question: asked, earlier: earlier)
        let number = questionCount + 1
        let sent = history + [turn]

        var captured: AsyncStream<AgentStreamEvent>.Continuation?
        let stream = AsyncStream<AgentStreamEvent> { captured = $0 }
        let continuation = captured
        let observer: AgentStreamObserver = { event in continuation?.yield(event) }
        let consumer = Task { @MainActor [weak self] in
            for await event in stream { self?.apply(event) }
        }
        committed = ""
        pending = ""
        liveTools = []
        liveTurn = -1
        live = [ChatItem(id: "live-q", kind: .question(asked, t: t))]

        let run = AgentRun(
            config: agent.config(question: number),
            transport: backend.transport,
            tools: tools,
            apiKey: backend.apiKey,
            endpoint: agent.settings.endpoint,
            meter: meter,
            breaker: breaker,
            sleep: backend.sleep,
            observer: observer)

        let outcome: AgentOutcome
        do {
            outcome = try await run.run(instructions: turn, resume: .resend(history: sent))
        } catch {
            continuation?.finish()
            await consumer.value
            fail(asked, notice: ChatSession.describe(error))
            return
        }
        continuation?.finish()
        await consumer.value

        let before = spentUSD
        spentUSD = await meter.total.usd

        switch outcome.ending {
        case .capReached:
            fail(asked, notice: "This chat reached its spend cap of "
                 + SpendMeter.format(agent.settings.spendCapUSD ?? 0)
                 + ". Raise it in Settings to keep asking.")
            return
        case .breakerTripped:
            fail(asked, notice: outcome.notices.last ?? CircuitBreaker.trippedNotice)
            return
        default:
            break
        }

        var notices: [String] = []
        if case .refused(let reason) = outcome.ending {
            notices.append("The assistant declined to answer: \(reason)")
        }
        if case .unrecognized = outcome.ending, let last = outcome.notices.last {
            notices.append("The answer may be incomplete: \(last)")
        }
        if case .turnLimit = outcome.ending {
            notices.append("The answer stopped after too many tool calls. Ask a narrower question.")
        }

        let added = Array(outcome.history.dropFirst(history.count))
        let entry = ChatLogEntry(kind: "turn", t: t, question: asked, messages: added,
                                 ending: ChatSession.endingName(outcome.ending), notices: notices,
                                 usd: max(0, spentUSD - before))
        do {
            try appendToLog(entry)
        } catch {
            notices.append("This answer could not be saved: \(error.localizedDescription)")
        }
        entries.append(entry)
        history = outcome.history
        rebuildItems()
        if outcome.outputs.contains(ReviewFiles.flagsPath) { onFlagsChanged?() }
    }

    private func fail(_ question: String, notice: String) {
        draft = question
        items.append(ChatItem(id: "notice-\(UUID().uuidString)", kind: .notice(notice)))
    }

    static func describe(_ error: Error) -> String {
        if let error = error as? StudioError { return error.message }
        if let error = error as? MessagesAPIError { return "The API answered \(error.description)" }
        if error is AgentBreakerOpen { return CircuitBreaker.trippedNotice }
        return error.localizedDescription
    }

    static func endingName(_ ending: AgentOutcome.Ending) -> String {
        switch ending {
        case .finished: return "finished"
        case .endTurn: return "end_turn"
        case .refused: return "refused"
        case .turnLimit: return "turn_limit"
        case .capReached: return "cap_reached"
        case .breakerTripped: return "breaker_tripped"
        case .unrecognized(let raw): return raw.isEmpty ? "missing" : raw
        }
    }

    // MARK: Rollover

    /// Starts the next session with the old one summarized into its first turn
    /// (ARCHITECTURE 8: simple compaction, never keep-tail). The summary is built
    /// here, from the log, not by the model: it costs nothing and cannot fail.
    private func rollOver() {
        let summary = ChatSession.summary(of: entries)
        let next = (ChatSession.sessionIDs(store: agent.store, videoId: agent.videoId).count) + 1
        sessionId = ChatSession.sessionID(number: max(next, 2))
        let opening = ChatLogEntry(kind: "summary", t: entries.last?.t ?? 0, question: summary)
        entries = [opening]
        history = []
        try? appendToLog(opening)
        rebuildItems()
    }

    static func summary(of entries: [ChatLogEntry]) -> String {
        var lines = ["The viewer asked \(entries.filter { $0.kind == "turn" }.count) earlier question(s) "
                     + "about this video. Each, with the first sentence of its answer:"]
        for entry in entries {
            if entry.kind == "summary" {
                lines.append(entry.question)
                continue
            }
            let answer = entry.messages.filter { $0.role == .assistant }
                .flatMap { $0.content.compactMap { $0.text } }
                .joined(separator: " ")
            let plain = CitationParser.parse(answer, resolve: { _ in true }).plainText
            lines.append("- [\(PlaybackAgent.timecode(entry.t))] Q: \(entry.question) A: "
                         + PlaybackAgent.firstSentence(plain))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Rows

    func resolves(_ anchor: String) -> Bool {
        if case .success = router.resolve(anchor) { return true }
        return false
    }

    private func rebuildItems() {
        items = ChatSession.items(from: entries, resolve: { self.resolves($0) })
    }

    static func items(from entries: [ChatLogEntry], resolve: (String) -> Bool) -> [ChatItem] {
        var out: [ChatItem] = []
        for (index, entry) in entries.enumerated() {
            if entry.kind == "summary" {
                out.append(ChatItem(id: "\(index)-summary", kind: .notice(
                    "Earlier questions were summarized to start a fresh conversation.")))
                continue
            }
            out.append(ChatItem(id: "\(index)-q", kind: .question(entry.question, t: entry.t)))
            var failedCalls = Set<String>()
            for message in entry.messages where message.role == .user {
                for block in message.content where block.type == "tool_result" {
                    if block.raw["is_error"]?.boolValue == true,
                       let id = block.raw["tool_use_id"]?.stringValue {
                        failedCalls.insert(id)
                    }
                }
            }
            var n = 0
            for message in entry.messages where message.role == .assistant {
                for block in message.content {
                    n += 1
                    let id = "\(index)-\(n)"
                    if let text = block.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        out.append(ChatItem(id: id, kind: .answer(CitationParser.parse(text, resolve: resolve))))
                    } else if let call = block.toolUse {
                        out.append(ChatItem(id: id, kind: row(for: call.name, input: call.input,
                                                               failed: failedCalls.contains(call.id))))
                    }
                }
            }
            for (k, notice) in entry.notices.enumerated() {
                out.append(ChatItem(id: "\(index)-notice-\(k)", kind: .notice(notice)))
            }
        }
        return out
    }

    /// The row a tool call shows as. A flag or jump the tool rejected shows as the
    /// plain row it was, not as a card that promises something that did not happen.
    static func row(for name: String, input: [String: JSONValue], failed: Bool) -> ChatItem.Kind {
        let string = { (key: String) in input[key]?.stringValue ?? "" }
        switch name {
        case "seek_video" where !failed:
            return .jump(t: input["t"]?.numberValue ?? 0, why: string("why"))
        case "flag_contradiction" where !failed:
            return .flag(claim: string("claim"), reason: string("reason"), anchor: string("anchor"))
        default:
            return .tool(toolLabel(name, input: input))
        }
    }

    static func toolLabel(_ name: String, input: [String: JSONValue]) -> String {
        let string = { (key: String) in input[key]?.stringValue ?? "" }
        switch name {
        case "read_file":
            var label = "reading \(string("path"))"
            if let start = PackageTools.int(input["startLine"]), let end = PackageTools.int(input["endLine"]) {
                label += " lines \(start)-\(end)"
            }
            return label
        case "list_dir":
            let path = string("path")
            return "listing \(path.isEmpty || path == "." ? "the repository root" : path)"
        case "grep": return "searching the code for \u{201C}\(string("pattern"))\u{201D}"
        case "search_package": return "searching the package for \u{201C}\(string("query"))\u{201D}"
        case "get_doc_section": return "reading doc:\(string("docId"))#\(string("slug"))"
        case "get_transcript_range":
            let from = input["fromT"]?.numberValue ?? 0
            let to = input["toT"]?.numberValue ?? 0
            return "reading the narration \(PlaybackAgent.timecode(from))-\(PlaybackAgent.timecode(to))"
        case "get_diagram": return "reading diagram:\(string("diagramId"))"
        case "read_fact": return "reading fact \(string("id"))"
        case "flag_contradiction": return "flagging a contradiction"
        case "seek_video": return "proposing a jump"
        default: return name
        }
    }

    /// Before the input of a call has arrived, all a row can say is which tool.
    static func startedLabel(_ name: String) -> String {
        switch name {
        case "read_file": return "reading a file"
        case "list_dir": return "listing a directory"
        case "grep": return "searching the code"
        case "search_package": return "searching the package"
        case "get_doc_section": return "reading a document"
        case "get_transcript_range": return "reading the narration"
        case "get_diagram": return "reading a diagram"
        case "read_fact": return "reading a fact"
        case "flag_contradiction": return "flagging a contradiction"
        case "seek_video": return "proposing a jump"
        default: return name
        }
    }

    // MARK: Streaming

    private func apply(_ event: AgentStreamEvent) {
        switch event {
        case .attempt(let turn, let attempt):
            if attempt > 1 {
                // A retry streams the turn again from its first byte.
                pending = ""
            } else if turn != liveTurn {
                if !pending.isEmpty { committed += (committed.isEmpty ? "" : "\n\n") + pending }
                pending = ""
            }
            liveTurn = turn
        case .delta(.text(let piece)):
            pending += piece
        case .delta(.toolStarted(_, let name)):
            liveTools.append(ChatSession.startedLabel(name))
        case .delta(.thinking), .delta(.stopped):
            return
        }
        var rows = live.filter { if case .question = $0.kind { return true } else { return false } }
        let text = committed.isEmpty ? pending : (pending.isEmpty ? committed : committed + "\n\n" + pending)
        if !text.isEmpty {
            rows.append(ChatItem(id: "live-a", kind: .answer(
                CitationParser.parse(text, final: false, resolve: { self.resolves($0) }))))
        }
        for (k, label) in liveTools.enumerated() {
            rows.append(ChatItem(id: "live-t\(k)", kind: .tool(label)))
        }
        live = rows
    }
}
