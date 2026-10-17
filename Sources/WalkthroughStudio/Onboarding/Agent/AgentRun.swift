// AgentRun.swift — "Onboard to a Codebase", milestone M6 (LLM runtime).
//
// The tool-use loop (ARCHITECTURE 4.2 and 4.6). One instance runs one unit: build a
// request, send it through the transport, append the assistant turn to history,
// branch on the stop reason, run tools, repeat until `finish`.
//
// Four rules here are not negotiable, and each one is in the code because getting
// it wrong is silent rather than loud:
//
//  1. **History is append-only and echoed verbatim.** Thinking blocks go back with
//     their signatures; nothing is rewritten, summarized or re-ordered. The moving
//     cache breakpoint is applied when the request is built, never stored.
//  2. **Every tool_use gets a tool_result, in one user message.** A missing result
//     is rejected by the API; a result in its own message breaks the pairing.
//  3. **Nothing is persisted before it is real.** A cancelled or failed turn
//     appends nothing, so resume never replays a turn the API did not complete.
//  4. **An unrecognized stop reason is handled, not assumed.** `.other` ends the
//     turn with a notice rather than being mistaken for success.
//
// Every one of them runs under `FixtureTransport` in the selftest, which is the
// only reason they can be asserted at all without a key.

import Foundation

/// Everything one unit's conversation needs, fixed for its lifetime.
struct AgentRunConfig: Sendable {
    var unitId: String
    /// Fixture key and transcript label (D9). Stable across turns.
    var promptName: String
    var model: String
    /// Role prompt, package conventions, dossier — in that order. The last block
    /// carrying `cacheControl` gets the ephemeral breakpoint.
    var system: [MessagesRequest.SystemBlock] = []
    var effort: AgentEffort? = nil
    var outputFormat: JSONValue? = nil
    var maxTokens: Int = 16000
    var stream: Bool = false
    var maxTurns: Int = 40
    /// Input-token budget for this unit. At 80% the unit is told to finish and the
    /// scheduler spawns `<id>-cont<n>`. Zero disables the check.
    var contextCapTokens: Int = 0
    var betas: [String] = []
    var serverSideFallback: Bool = false
    /// Idle timeout between stream events; `timeoutInterval` restarts on each byte.
    var streamIdleTimeout: Double = 120
    var requestTimeout: Double = 300

    init(unitId: String, promptName: String, model: String) {
        self.unitId = unitId
        self.promptName = promptName
        self.model = model
    }

    /// `stream: true` for every unit over the non-streaming ceiling, and for chat
    /// (ARCHITECTURE 4.2). Derived rather than set by hand so the two cannot drift.
    static func streams(maxTokens: Int) -> Bool { maxTokens > 16000 }
}

/// How a unit's conversation ended, and what it produced on the way.
struct AgentOutcome: Sendable, Equatable {
    enum Ending: Equatable, Sendable {
        /// `finish` was called. The only ending that means the unit did its job.
        case finished(summary: String)
        /// The model stopped talking without calling `finish`. A result, but an
        /// incomplete one: there is no coverage report, so the gap is untracked.
        case endTurn
        /// `stop_reason: refusal`. Marked failed with reason `refused`, no retry
        /// (ARCHITECTURE 4.2): a blind retry of a refusal spends money to be
        /// refused again.
        case refused(String)
        case turnLimit
        case capReached
        case breakerTripped
    }

    var ending: Ending
    var history: [AgentMessage]
    /// Joined text of the assistant's `text` blocks across the run.
    var text: String
    var usage = OnboardingUsage()
    var turns: Int = 0
    var toolCalls: Int = 0
    var outputs: [String] = []
    var notices: [String] = []
    /// The unit was told to finish because it neared its context cap. The scheduler
    /// reads this to spawn a continuation seeded with the finish summary.
    var contextCapHit: Bool = false

    var succeeded: Bool {
        switch ending {
        case .finished, .endTurn: return true
        default: return false
        }
    }
}

/// Thrown inside the retry ladder when the circuit breaker opens, so `run` can turn
/// it into an outcome that still carries the history and the spend.
struct AgentBreakerOpen: Error, Equatable {
    var message: String = CircuitBreaker.trippedNotice
}

actor AgentRun {
    private let config: AgentRunConfig
    private let transport: MessagesTransport
    private let tools: AgentTools
    private let apiKey: String
    private let endpoint: URL
    private let limiter: RateLimiter
    private let breaker: CircuitBreaker
    private let meter: SpendMeter
    private let transcript: AgentTranscript?
    private let counter: TokenCounting
    private let sleep: AgentSleep
    private let jitter: @Sendable () -> Double

    /// Requests sent in this run. The fixture key: a retry is the same turn.
    private var requestIndex = 0

    init(
        config: AgentRunConfig,
        transport: MessagesTransport,
        tools: AgentTools,
        apiKey: String,
        endpoint: URL,
        meter: SpendMeter,
        breaker: CircuitBreaker,
        limiter: RateLimiter = RateLimiter(),
        transcript: AgentTranscript? = nil,
        counter: TokenCounting = EstimatingTokenCounter(),
        sleep: AgentSleep = agentRealSleep,
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }
    ) {
        self.config = config
        self.transport = transport
        self.tools = tools
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.meter = meter
        self.breaker = breaker
        self.limiter = limiter
        self.transcript = transcript
        self.counter = counter
        self.sleep = sleep
        self.jitter = jitter
    }

    // MARK: - The loop

    /// Runs the unit to an ending.
    ///
    /// `resume` comes from the unit's transcript (`AgentTranscript.resumePlan`);
    /// `.fresh` starts from `instructions`.
    func run(instructions: AgentMessage, resume: AgentResume = .fresh) async throws -> AgentOutcome {
        var state = State()

        switch resume {
        case .finished(let history, let summary):
            state.history = history
            return outcome(.finished(summary: summary), state)
        case .fresh:
            state.history = [instructions]
            try record(.user, message: instructions, state: state)
        case .resend(let history):
            state.history = history
        case .continueTurn(let history):
            state.history = history
            let nudge = AgentMessage.user(AgentRun.continuePrompt)
            state.history.append(nudge)
            try record(.user, message: nudge, state: state)
        case .reexecuteTools(let history, let pending):
            state.history = history
            let replayed = await runTools(pending, into: &state)
            state.history.append(replayed)
            try record(.user, message: replayed, state: state)
        }

        // The pending tool a resume re-ran may have been `finish` itself — a unit
        // killed between its finish call and its finish line. Sending another
        // request now would pay for a turn to be told again that it is over.
        if let summary = state.finishSummary {
            try finishNote(summary, state: state)
            return outcome(.finished(summary: summary), state)
        }

        while state.turns < config.maxTurns {
            try Task.checkCancellation()

            // The request is built first so it can be measured, then possibly
            // rebuilt once with the finish nudge appended.
            var request = buildRequest(state.history)
            let measured = await counter.count(request) ?? 0
            if shouldNudgeToFinish(measured: measured, state: state) {
                state.contextCapHit = true
                state.nudgedToFinish = true
                let nudge = AgentMessage.user(AgentRun.finishPrompt)
                state.history.append(nudge)
                try record(.user, message: nudge, state: state)
                state.notices.append("context cap neared at ~\(measured) input tokens; "
                                     + "the unit was asked to finish")
                request = buildRequest(state.history)
            }

            let mayStart = await meter.mayStartTurn(
                model: config.model,
                estimatedInputTokens: measured,
                estimatedOutputTokens: config.maxTokens)
            if !mayStart {
                state.notices.append("spend cap reached before turn \(state.turns + 1); the unit stopped")
                try? note(state.notices.last ?? "", state: state)
                return outcome(.capReached, state)
            }

            // Zero-based, matching the fixture key and the request entry, so a
            // transcript's request and its reply carry the same `turn`.
            let turnIndex = state.turns
            let started = Date()
            let response: MessagesResponse
            do {
                response = try await perform(request)
            } catch let open as AgentBreakerOpen {
                state.notices.append(open.message)
                try? note(open.message, state: state)
                return outcome(.breakerTripped, state)
            }
            state.turns += 1

            let priced = await meter.record(model: config.model, usage: response.usage)
            state.usage.add(priced)
            let elapsed = Int(Date().timeIntervalSince(started) * 1000)

            // Refusal is checked before the content is read: `stop_details` may be
            // null even here, and nothing in the reply is worth acting on.
            if case .refusal = response.stopReason {
                let reason = AgentRun.refusalReason(response)
                try record(.reply, message: response.assistantTurn, state: state,
                           turn: turnIndex, stopReason: response.stopReason,
                           usage: priced, ms: elapsed)
                state.history.append(response.assistantTurn)
                state.notices.append("refused: \(reason)")
                try? note("refused: \(reason)", state: state)
                return outcome(.refused(reason), state)
            }

            // `pause_turn` re-sends the same history unchanged (ARCHITECTURE 4.2).
            // Nothing is appended: our tools are local, so there is no server-side
            // tool state the partial turn is carrying, and leaving history alone
            // keeps the request byte-identical and the prompt cache warm.
            if case .pauseTurn = response.stopReason {
                // Recorded as a note, not a reply: `plan` rebuilds history from the
                // reply and user entries, and an empty assistant turn written there
                // would come back as an invalid message on resume.
                try? note("pause_turn after \(elapsed)ms; the same history was re-sent", state: state)
                continue
            }

            try record(.reply, message: response.assistantTurn, state: state,
                       turn: turnIndex, stopReason: response.stopReason,
                       usage: priced, ms: elapsed)
            state.history.append(response.assistantTurn)
            state.text += response.joinedText

            let calls = response.toolUses.map {
                PendingToolUse(id: $0.id, name: $0.name, input: $0.input)
            }

            switch response.stopReason {
            case .toolUse where !calls.isEmpty:
                let results = await runTools(calls, into: &state)
                state.history.append(results)
                try record(.user, message: results, state: state, turn: turnIndex)
                if let summary = state.finishSummary {
                    try finishNote(summary, state: state)
                    return outcome(.finished(summary: summary), state)
                }

            case .toolUse:
                // `tool_use` with nothing callable: every tool_use block was cut
                // off mid-input and dropped. Treated exactly like max_tokens —
                // without this the loop would re-send an unchanged history and
                // spend its whole turn budget learning nothing.
                state.notices.append("a tool call was cut off at the output limit on turn \(state.turns)")
                try appendCutOffNudge(&state, turn: turnIndex)

            case .maxTokens:
                state.notices.append("the reply was cut off at the output limit on turn \(state.turns)")
                try appendCutOffNudge(&state, turn: turnIndex)

            case .endTurn, .stopSequence:
                return outcome(.endTurn, state)

            case .other(let raw):
                // A stop reason this build does not know. Ending the turn is the
                // conservative read: looping on it could spend the whole budget.
                state.notices.append("unrecognized stop reason \"\(raw)\"; the turn was ended")
                try? note(state.notices.last ?? "", state: state)
                return outcome(.endTurn, state)

            case .missing:
                state.notices.append("the reply carried no stop reason; the turn was ended")
                try? note(state.notices.last ?? "", state: state)
                return outcome(.endTurn, state)

            case .refusal, .pauseTurn:
                break   // handled above
            }
        }

        state.notices.append("the turn limit of \(config.maxTurns) was reached without a finish call")
        try? note(state.notices.last ?? "", state: state)
        return outcome(.turnLimit, state)
    }

    // MARK: - Turn state

    /// Mutable state of one run, in one place so `outcome` cannot forget a field.
    private struct State {
        var history: [AgentMessage] = []
        var text = ""
        var usage = OnboardingUsage()
        var turns = 0
        var toolCalls = 0
        var outputs: [String] = []
        var notices: [String] = []
        var contextCapHit = false
        var nudgedToFinish = false
        /// Set when a tool reports `endsUnit`.
        var finishSummary: String? = nil
    }

    private func outcome(_ ending: AgentOutcome.Ending, _ state: State) -> AgentOutcome {
        var out = AgentOutcome(ending: ending, history: state.history, text: state.text)
        out.usage = state.usage
        out.turns = state.turns
        out.toolCalls = state.toolCalls
        out.outputs = state.outputs
        out.notices = state.notices
        out.contextCapHit = state.contextCapHit
        return out
    }

    // MARK: - Requests

    private func buildRequest(_ history: [AgentMessage]) -> MessagesRequest {
        var request = MessagesRequest(promptName: config.promptName,
                                      model: config.model,
                                      maxTokens: config.maxTokens,
                                      stream: config.stream)
        request.system = config.system
        request.messages = history
        request.tools = tools.specs
        request.effort = config.effort
        request.outputFormat = config.outputFormat
        request.betas = config.betas
        request.serverSideFallback = config.serverSideFallback
        return request
    }

    /// Sends one request, retrying per the policy. Returns the parsed reply.
    private func perform(_ request: MessagesRequest) async throws -> MessagesResponse {
        let turn = requestIndex
        requestIndex += 1
        let body = try request.body()
        let headers = AgentHeaders.standard(apiKey: apiKey, betas: request.betas)
        try recordRequest(request, turn: turn, headers: headers, bodyHash: PackageStore.sha256Hex(body))

        var attempt = 0
        while true {
            try Task.checkCancellation()
            if await breaker.isTripped { throw AgentBreakerOpen() }
            attempt += 1
            let call = TransportRequest(
                endpoint: endpoint,
                headers: headers,
                body: body,
                stream: request.stream,
                timeout: request.stream ? config.streamIdleTimeout : config.requestTimeout,
                promptName: request.promptName,
                turn: turn,
                bodyHash: PackageStore.sha256Hex(body))
            do {
                let response = try await send(call, streaming: request.stream)
                await breaker.recordReachable()
                return response
            } catch let error as MessagesAPIError {
                if error.isTransport {
                    let tripped = await breaker.recordTransportFailure()
                    if tripped { throw AgentBreakerOpen() }
                } else {
                    // The server answered. The API is up, whatever it said.
                    await breaker.recordReachable()
                }
                guard limiter.shouldRetry(error, afterAttempt: attempt) else { throw error }
                let wait = limiter.delay(afterAttempt: attempt,
                                         retryAfter: error.retryAfter,
                                         jitter: jitter())
                try? note("attempt \(attempt) failed (\(error.description)); retrying in "
                          + String(format: "%.1f", wait) + "s", state: nil)
                // `self.` is not decoration: Foundation exports a global `sleep`.
                try await self.sleep(wait)
            }
        }
    }

    private func send(_ call: TransportRequest, streaming: Bool) async throws -> MessagesResponse {
        if !streaming {
            let reply = try await transport.send(call)
            guard reply.status == 200 else {
                throw MessagesAPIError.parse(status: reply.status, data: reply.body, headers: reply.headers)
            }
            return try MessagesResponse.parse(reply.body)
        }
        let stream = try await transport.stream(call)
        guard stream.status == 200 else {
            // A failed streaming request answers with an ordinary error body.
            var body = Data()
            for try await chunk in stream.chunks { body.append(chunk) }
            throw MessagesAPIError.parse(status: stream.status, data: body, headers: stream.headers)
        }
        var parser = SSEParser()
        var accumulator = MessageStreamAccumulator()
        for try await chunk in stream.chunks {
            for event in parser.feed(chunk) {
                try accumulator.apply(event)
            }
        }
        for event in parser.finish() {
            try accumulator.apply(event)
        }
        return try accumulator.finalize()
    }

    // MARK: - Tools

    /// Runs every call of one turn concurrently and returns the single user message
    /// that answers them.
    ///
    /// Results come back in the order the calls were made. Not required by the API,
    /// but a transcript where the third result answers the first call is unreadable
    /// by the person debugging a unit at 1am, and that person is the whole audience
    /// for a transcript.
    private func runTools(_ calls: [PendingToolUse], into state: inout State) async -> AgentMessage {
        guard !calls.isEmpty else { return AgentMessage(role: .user, content: []) }
        let tools = self.tools
        var results = [ToolOutcome?](repeating: nil, count: calls.count)
        await withTaskGroup(of: (Int, ToolOutcome).self) { group in
            for (index, call) in calls.enumerated() {
                group.addTask {
                    let outcome = await tools.run(name: call.name, input: call.input, toolUseId: call.id)
                    return (index, outcome)
                }
            }
            for await (index, outcome) in group {
                results[index] = outcome
            }
        }

        var blocks: [ContentBlock] = []
        for (index, call) in calls.enumerated() {
            let outcome = results[index] ?? ToolOutcome.error("The tool produced no result.")
            state.toolCalls += 1
            state.outputs.append(contentsOf: outcome.outputs)
            if outcome.endsUnit, state.finishSummary == nil {
                state.finishSummary = FinishTool.summary(from: call.input)
            }
            blocks.append(.toolResult(toolUseId: call.id,
                                      content: outcome.content,
                                      isError: outcome.isError))
        }
        return AgentMessage(role: .user, content: blocks)
    }

    // MARK: - Nudges

    /// The exact words of ARCHITECTURE 4.2.
    static let continuePrompt = "Your reply was cut off at the output limit. Continue; if you "
        + "were about to call a tool, call it now."
    static let finishPrompt = "Call finish now with your summary and coverage"

    private func appendCutOffNudge(_ state: inout State, turn: Int) throws {
        let nudge = AgentMessage.user(AgentRun.continuePrompt)
        state.history.append(nudge)
        try record(.user, message: nudge, state: state, turn: turn)
    }

    private func shouldNudgeToFinish(measured: Int, state: State) -> Bool {
        guard config.contextCapTokens > 0, !state.nudgedToFinish, measured > 0 else { return false }
        return Double(measured) >= Double(config.contextCapTokens) * 0.8
    }

    /// `stop_details.reason` when there is one, and a usable sentence when there is
    /// not — `stop_details` may be absent or null on a refusal.
    static func refusalReason(_ response: MessagesResponse) -> String {
        if let details = response.stopDetails?.objectValue {
            if let reason = details["reason"]?.stringValue, !reason.isEmpty { return reason }
            if let message = details["message"]?.stringValue, !message.isEmpty { return message }
        }
        let text = response.joinedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "the model declined to answer and gave no reason" : text
    }

    // MARK: - Transcript

    private func record(
        _ kind: TranscriptEntry.Kind,
        message: AgentMessage,
        state: State,
        turn: Int? = nil,
        stopReason: StopReason? = nil,
        usage: OnboardingUsage? = nil,
        ms: Int? = nil
    ) throws {
        guard let transcript else { return }
        var entry = TranscriptEntry(kind: kind)
        entry.turn = turn ?? state.turns
        entry.message = message
        entry.model = config.model
        entry.promptName = config.promptName
        entry.stopReason = stopReason?.wireValue
        entry.usage = usage
        entry.ms = ms
        try transcript.append(entry)
    }

    private func recordRequest(
        _ request: MessagesRequest,
        turn: Int,
        headers: [String: String],
        bodyHash: String
    ) throws {
        guard let transcript else { return }
        var entry = TranscriptEntry(kind: .request)
        entry.turn = turn
        entry.model = request.model
        entry.promptName = request.promptName
        entry.stream = request.stream
        entry.maxTokens = request.maxTokens
        entry.effort = request.effort?.rawValue
        entry.toolNames = request.tools.map { $0.name }.sorted()
        entry.systemHash = PackageStore.sha256Hex(
            Data(request.system.map { $0.text }.joined(separator: "\u{1E}").utf8))
        entry.bodyHash = bodyHash
        entry.headersRedacted = AgentHeaders.redactedNames(headers)
        try transcript.append(entry)
    }

    private func note(_ text: String, state: State?) throws {
        guard let transcript else { return }
        var entry = TranscriptEntry(kind: .note)
        entry.turn = state?.turns ?? 0
        entry.text = text
        try transcript.append(entry)
    }

    private func finishNote(_ summary: String, state: State) throws {
        guard let transcript else { return }
        var entry = TranscriptEntry(kind: .finish)
        entry.turn = state.turns
        entry.text = summary
        try transcript.append(entry)
    }
}
