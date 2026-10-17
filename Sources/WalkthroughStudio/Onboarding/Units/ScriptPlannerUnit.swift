// ScriptPlannerUnit.swift — "Onboard to a Codebase", milestone M9 (video scripts).
//
// The planner writes one series video's script (ARCHITECTURE 4.3 "script" unit,
// effort high). It reads the package with the chat's read tools and hands the script
// in through `emit_script`, which runs `ScriptValidator` with the series rules before
// anything is accepted. That is the only way a script leaves the unit: a model cannot
// end the unit with a script the renderer would refuse.
//
// One rejection is allowed (section 5): the first invalid script comes back as an
// `is_error` tool result listing every error, and the model gets one more try. A
// second invalid script ends the unit as failed with a notice, so one stubborn video
// never stalls the rest of the series.

import Foundation

/// What a planner run produced.
struct ScriptPlanOutcome: Sendable {
    var script: VideoScript?
    var attempts: Int
    var notices: [String] = []
    var ending: AgentOutcome.Ending?
    var usage = OnboardingUsage()

    var succeeded: Bool { script != nil }
}

/// The state `emit_script` keeps across the unit's turns.
actor ScriptAttempts {
    private(set) var attempts = 0
    private(set) var accepted: VideoScript?
    private(set) var lastErrors: [String] = []
    private(set) var failed = false

    static let maxAttempts = 2

    /// Records one submission. Returns true when the unit should end.
    func record(_ script: VideoScript, report: ScriptValidator.Report) -> Bool {
        attempts += 1
        if report.ok {
            accepted = script
            return true
        }
        lastErrors = report.errors.map { $0.description }
        if attempts >= ScriptAttempts.maxAttempts { failed = true }
        return failed
    }

    /// A submission that did not even decode still spends an attempt: "send me the
    /// whole thing again" is the same correction either way.
    func recordUnreadable(_ reason: String) -> Bool {
        attempts += 1
        lastErrors = [reason]
        if attempts >= ScriptAttempts.maxAttempts { failed = true }
        return failed
    }
}

/// The planner's tools: the package read tools, and `emit_script`.
struct ScriptPlannerTools: AgentTools, @unchecked Sendable {
    // `@unchecked`: `PackageStore` and `LinkRouter` are read-only here, and the only
    // mutable state is inside the `ScriptAttempts` actor.

    /// No `flag_contradiction`, `seek_video` or `get_transcript_range`: the planner is
    /// writing the video, not watching one.
    static let readTools: Set<String> = [
        "get_diagram", "get_doc_section", "grep", "list_dir", "read_fact", "read_file", "search_package",
    ]
    static let emitName = "emit_script"

    let package: AgentTools
    let item: SeriesItem
    let router: LinkRouter
    let rules: ScriptValidator.Rules
    let attempts: ScriptAttempts

    static var emitSpec: ToolSpec {
        ToolSpec(
            name: emitName,
            description: "Hand in the finished script. It is validated at once: every anchor must "
                + "resolve, the first scene must be a tldr card, the total must fit the budget and no "
                + "refuted fact may be cited. An invalid script comes back with every error listed; "
                + "fix all of them and send the whole script again. A second invalid script ends the "
                + "unit without a video.",
            // Not strict: a whole script is a deep, mostly optional shape, and the
            // validator below is the real contract.
            inputSchema: [
                "type": .string("object"),
                "properties": .object([
                    "script": .object([
                        "type": .string("object"),
                        "description": .string("The whole VideoScript, in the shape the system prompt shows."),
                    ]),
                ]),
                "required": .array([.string("script")]),
            ],
            strict: false)
    }

    var specs: [ToolSpec] {
        package.specs.filter { ScriptPlannerTools.readTools.contains($0.name) } + [ScriptPlannerTools.emitSpec]
    }

    func run(name: String, input: [String: JSONValue], toolUseId: String) async -> ToolOutcome {
        if name == ScriptPlannerTools.emitName { return await emit(input) }
        guard ScriptPlannerTools.readTools.contains(name) else {
            return .error("There is no tool named \(name). The tools are: "
                          + (ScriptPlannerTools.readTools.sorted() + [ScriptPlannerTools.emitName])
                            .joined(separator: ", ") + ".")
        }
        return await package.run(name: name, input: input, toolUseId: toolUseId)
    }

    private func emit(_ input: [String: JSONValue]) async -> ToolOutcome {
        guard var script = ScriptPlannerTools.decode(input["script"]) else {
            let reason = "emit_script needs {\"script\": {...}} holding the whole script as JSON"
            let ends = await attempts.recordUnreadable(reason)
            return ToolOutcome(ends ? "Rejected again: \(reason). The unit ends without a video."
                                    : "Rejected: \(reason).", isError: true, endsUnit: ends)
        }
        // Ours, not the model's: the id is the folder and the kind is the plan.
        script.id = item.videoId
        script.kind = item.kind
        if script.targetSeconds == nil { script.targetSeconds = item.targetSeconds }

        let report = ScriptValidator.validate(script, router: router, rules: rules)
        let ends = await attempts.record(script, report: report)
        if report.ok {
            return ToolOutcome("Accepted: \(report.summary).", endsUnit: true)
        }
        let list = report.errors.map { "- \($0.description)" }.joined(separator: "\n")
        if ends {
            return ToolOutcome("Rejected again with \(report.errors.count) error(s):\n\(list)\n"
                               + "The unit ends without a video.", isError: true, endsUnit: true)
        }
        return .error("Rejected with \(report.errors.count) error(s). Fix every one and call "
                      + "emit_script again with the whole script:\n\(list)")
    }

    /// The script from the tool input: an object, or a JSON string holding one.
    static func decode(_ value: JSONValue?) -> VideoScript? {
        guard let value else { return nil }
        let data: Data?
        if let text = value.stringValue {
            data = text.data(using: .utf8)
        } else if value.objectValue != nil {
            data = try? MessagesRequest.canonicalJSON(value)
        } else {
            data = nil
        }
        guard let data, let script = try? JSONDecoder().decode(VideoScript.self, from: data),
              !script.scenes.isEmpty else { return nil }
        return script
    }
}

/// One series video's planner unit.
struct ScriptPlannerUnit {
    static let promptName = "script-planner"
    static let maxTokens = 32000

    let store: PackageStore
    let packet: ResearchPacket
    let settings: AgentRuntimeSettings
    let source: PinnedSource
    let repoName: String

    // MARK: - Request shape

    func config(for item: SeriesItem) -> AgentRunConfig {
        var config = AgentRunConfig(unitId: "script-\(item.videoId)",
                                    promptName: "\(ScriptPlannerUnit.promptName)-\(item.videoId)",
                                    model: settings.model)
        config.system = system()
        config.effort = .high
        config.maxTokens = ScriptPlannerUnit.maxTokens
        config.stream = AgentRunConfig.streams(maxTokens: ScriptPlannerUnit.maxTokens)
        config.maxTurns = 30
        config.betas = settings.betas
        config.serverSideFallback = settings.serverSideFallback
        return config
    }

    func system() -> [MessagesRequest.SystemBlock] {
        [
            MessagesRequest.SystemBlock(ScriptPlannerUnit.roleBlock(repoName: repoName, sha7: packet.sha7)),
            MessagesRequest.SystemBlock(digestBlock(), cacheControl: true),
        ]
    }

    static func roleBlock(repoName: String, sha7: String) -> String {
        """
        You write the script for one narrated code-walk video about \(repoName) at \(sha7). \
        Nothing is recorded: every shot is a still rendered from what the script names, \
        narrated by a voice reading your words. A viewer new to the codebase watches it to \
        learn; every sentence must be true of the code at \(sha7) and backed by a fact or a \
        line you read.

        Shape. A video is 6 to 14 scenes. Scene 1 is a card with variant "tldr": one shot, \
        narration of at most 75 words saying what the video covers, plus 3 to 5 short \
        bullets. Each scene is a chapter; each shot is one still and 1 to 4 sentences of \
        narration. Narration is spoken: plain sentences, no markdown, no lists, no anchors.

        Shot kinds (sceneType):
        - "code": anchors includes a code:<path>@\(sha7)#L<a>-L<b> anchor; highlight names \
        the lines being talked about, with a callout of a few words; visibleLines [first, last] \
        is at most 40 lines and contains the highlight. Read the file first: line numbers you \
        have not seen are wrong.
        - "diagram": diagram is a package diagram id (get_diagram lists its nodes); focusNodes \
        names nodes to emphasize.
        - "table": table is a header row then body rows; the second column is a verdict \
        (present, partial, absent) when there is one.
        - "card": a claim on screen. variant "chapter" for a title card, "confessional" for \
        the closing "what scares me" card. A card is held at least 4 s.
        - "terminal": cmd is a cmd:<unit>/<n> anchor of recorded output.

        Facts. factIds lists the research facts a shot's narration rests on. Cite only facts \
        whose status is verified or unknown; a refuted fact is wrong and must not be narrated \
        as true. Prefer a fact's own evidence anchor as the shot's code anchor.

        Budget. The runtime is words / 2.5 seconds plus 0.6 s per shot, and cards at least \
        4 s. Stay inside the budget the request gives; aim for the target.

        Hand in the whole script with emit_script. It is validated at once and comes back \
        with every error if it is wrong; fix all of them and send it again. A second invalid \
        script ends the unit without a video.

        The script JSON:
        {"title": "...", "summary": "one paragraph", "sha": "\(sha7)", "scenes": [
          {"id": "s01", "title": "TL;DR", "variant": "tldr", "shots": [
            {"id": "s01a", "sceneType": "card", "narration": "...", "bullets": ["..."], "factIds": []}]},
          {"id": "s02", "title": "...", "docAnchor": "doc:<id>#<slug>", "shots": [
            {"id": "s02a", "sceneType": "code", "narration": "...",
             "anchors": ["code:<path>@\(sha7)#L10-L40"],
             "highlight": {"anchor": "code:<path>@\(sha7)#L18-L22", "callout": "..."},
             "visibleLines": [10, 40], "factIds": ["F-..."], "caption": "..."}]}]}
        Shot ids start with their scene id.
        """
    }

    /// What the package holds, so the planner can cite it without searching first.
    func digestBlock() -> String {
        var out = "Package at \(packet.sha7).\n"
        let docs = store.listing("docs").filter { $0.hasSuffix(".md") }
            .map { String($0.dropLast(3)) }.sorted()
        if !docs.isEmpty { out += "Documents (doc:<id>#<slug>): " + docs.joined(separator: ", ") + "\n" }
        let diagrams = store.listing("diagrams").filter { $0.hasSuffix(".mmd") }
            .map { String($0.dropLast(4)) }.sorted()
        if !diagrams.isEmpty { out += "Diagrams: " + diagrams.joined(separator: ", ") + "\n" }
        if !packet.traces.isEmpty {
            out += "Traces (trace:<id>#hop<n>): " + packet.traces.keys.sorted().joined(separator: ", ") + "\n"
        }
        let dirs = packet.inventory.topLevel.map { "\($0.path) (\($0.files) files\($0.generated ? ", generated" : ""))" }
        if !dirs.isEmpty { out += "Top level: " + dirs.joined(separator: ", ") + "\n" }
        return out
    }

    /// The fact kinds each series video draws on first. The planner can read any fact
    /// with read_fact; these are the ones put in front of it.
    static let factKinds: [String: [String]] = [
        "overview": ["component", "interface", "endpoint", "decision", "dependency"],
        "domain": ["dataEntity", "term", "dataField"],
        "codeTour": ["component", "interface", "hotspot", "owner"],
        "devEnv": ["config", "testCoverage", "dependency"],
        "deploy": ["deployStep", "config"],
        "data": ["dataEntity", "dataField", "migration"],
        "observability": ["observability", "incidentPattern"],
        "security": ["security"],
        "integrations": ["integration", "dependency"],
        "migrations": ["migration"],
    ]
    static let factsShown = 60

    func instructions(for item: SeriesItem) -> AgentMessage {
        let kinds = Set(ScriptPlannerUnit.factKinds[item.kind] ?? [])
        let relevant = packet.usableFacts.filter { kinds.isEmpty || kinds.contains($0.kind) }
            .prefix(ScriptPlannerUnit.factsShown)
        var text = "Write the \"\(item.title)\" video (kind \(item.kind)).\n"
        text += String(format: "Budget: %.0f s at most; aim for about %.0f s.\n",
                       item.budgetSeconds, item.targetSeconds)
        if relevant.isEmpty {
            text += "No facts of the kinds this video usually draws on were found; read the code and "
                + "say plainly what is not there.\n"
        } else {
            text += "Facts to draw on (all usable):\n"
            for fact in relevant {
                let anchor = fact.evidence.first?.anchor ?? ""
                text += "- \(fact.id) [\(fact.kind)] \(fact.claim) — \(anchor)\n"
            }
        }
        text += "Read what you need, then call emit_script once with the whole script."
        return .user(text)
    }

    // MARK: - Running

    func run(_ item: SeriesItem, transport: MessagesTransport, apiKey: String,
             meter: SpendMeter, breaker: CircuitBreaker,
             transcript: AgentTranscript? = nil,
             sleep: AgentSleep = agentRealSleep) async -> ScriptPlanOutcome {
        let facts = Dictionary(packet.facts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let describable = facts.filter { $0.value.status != "proposed" }
        let router = LinkRouter(store: store, headSHA: packet.headSHA, factIDs: Set(describable.keys))
        let package = PackageTools(store: store, source: source, router: router,
                                   review: ReviewFiles(store: store), facts: describable)
        let attempts = ScriptAttempts()
        let tools = ScriptPlannerTools(
            package: package, item: item, router: router,
            rules: .series(budgetSeconds: item.budgetSeconds, facts: facts),
            attempts: attempts)

        let run = AgentRun(config: config(for: item), transport: transport, tools: tools,
                           apiKey: apiKey, endpoint: settings.endpoint, meter: meter,
                           breaker: breaker, transcript: transcript, sleep: sleep)
        var outcome = ScriptPlanOutcome(script: nil, attempts: 0)
        do {
            let agent = try await run.run(instructions: instructions(for: item))
            outcome.ending = agent.ending
            outcome.usage = agent.usage
            outcome.notices.append(contentsOf: agent.notices)
        } catch {
            let reason = (error as? StudioError)?.message ?? error.localizedDescription
            outcome.notices.append("\(item.videoId): the script planner could not run (\(reason))")
        }
        outcome.attempts = await attempts.attempts
        outcome.script = await attempts.accepted
        if outcome.script == nil {
            if await attempts.failed {
                let errors = await attempts.lastErrors
                outcome.notices.append("\(item.videoId): the planner's script was rejected twice; the video "
                                       + "was not made. Last errors: " + errors.prefix(3).joined(separator: "; "))
            } else if let ending = outcome.ending {
                outcome.notices.append("\(item.videoId): the planner ended (\(ending)) without handing in a script")
            }
        }
        return outcome
    }
}
