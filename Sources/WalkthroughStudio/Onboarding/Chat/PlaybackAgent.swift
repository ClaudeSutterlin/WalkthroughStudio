// PlaybackAgent.swift — "Onboard to a Codebase", milestone M7 (playback chat).
//
// Assembles what the playback agent knows when the viewer asks at time t
// (ARCHITECTURE 8, ON-9.1). The request has a fixed shape so the prompt cache does
// the work a context window would otherwise pay for:
//
//   tools        the PackageTools list, sorted, strict          frozen
//   system 1     role, citation grammar and anchor rules        frozen
//   system 2     the package digest                             frozen
//   system 3     this video: summary, chapters, top facts       frozen   <- breakpoint
//   messages     earlier questions and answers, verbatim        append-only
//   user turn    narrated_so_far, on_screen, coming_up,         new each question
//                viewer_question
//
// Everything above the new user turn is byte-identical from one question to the
// next (`chatContextProbe` asserts it), so a follow-up re-reads only its own turn.
//
// The two rules the context exists to enforce: the agent knows what has been said
// and what is on screen, and it knows what has *not* been said yet. "Coming up" is
// marked as not narrated so an answer can say "that is in the next chapter" rather
// than spoil it or contradict it.

import Foundation

/// What the user turn for one question contains, as data. The text the model reads
/// is `text`; the rest is what a probe asserts and what the panel shows in its
/// "the assistant can see" footer.
struct PlaybackContext: Equatable, Sendable {
    var t: Double
    var chapterId: String?
    var shotId: String?
    var sceneType: String?
    /// Every segment whose `end <= t`, in order.
    var narratedIds: [String] = []
    /// The suffix of `narratedIds` rendered verbatim (at most 40).
    var verbatimIds: [String] = []
    /// The segment playing at `t`, when one is mid-sentence.
    var inProgressId: String?
    /// The next segments, marked not yet narrated.
    var comingUpIds: [String] = []
    var intervalAnchors: [String] = []
    /// The source inlined for the shot: its path and 1-based line range.
    var inlinedPath: String?
    var inlinedLines: ClosedRange<Int>?
    var factIds: [String] = []
    var text: String = ""
}

struct PlaybackAgent: @unchecked Sendable {
    // `@unchecked`: `PackageStore` is a class whose only state is its root URL.

    static let verbatimSegments = 40
    static let contextLines = 20
    static let comingUpCount = 2
    static let maxShotFacts = 8
    static let maxTopFacts = 12
    /// A session rolls over after this many questions (ARCHITECTURE 8).
    static let questionsPerSession = 30
    static let maxTokens = 8000
    static let promptName = "playback-chat"

    let store: PackageStore
    let videoId: String
    let repoName: String
    let headSHA: String
    let transcript: TranscriptDoc
    let coderefs: CodeRefMap
    /// Verified and unknown facts only: what an answer may lean on.
    let usableFacts: [PacketFact]
    /// Every fact the tools may describe, refuted ones included (marked as such).
    let describableFacts: [String: PacketFact]
    let source: PinnedSource
    let settings: AgentRuntimeSettings
    let system: [MessagesRequest.SystemBlock]

    // MARK: - Loading

    /// Reads everything a conversation about `videoId` needs. A package without a
    /// packet (hand-assembled, or one whose packet was deleted) still chats, with no
    /// facts in context.
    static func load(store: PackageStore, videoId: String, settings: AgentRuntimeSettings,
                     repo: URL? = nil) throws -> PlaybackAgent {
        let folder = "videos/\(videoId)"
        let transcript = try OnboardingJSON.decoder().decode(
            TranscriptDoc.self, from: try store.readData("\(folder)/\(TranscriptDoc.fileName)"))
        let coderefs = try OnboardingJSON.decoder().decode(
            CodeRefMap.self, from: try store.readData("\(folder)/\(CodeRefMap.fileName)"))
        let manifest = store.hasManifest ? try store.readManifest() : OnboardingManifest()
        let hub = (try? HubIndex.load(from: store)) ?? HubIndex()
        let packet = try? PacketReader.load(store.url("packet"))
        let facts = packet?.facts ?? []

        let headSHA = !manifest.headSHA.isEmpty ? manifest.headSHA
            : (!transcript.sha.isEmpty ? transcript.sha : hub.repo.headSHA)
        var pinned = manifest
        pinned.headSHA = headSHA
        let source = PinnedSource.forPackage(store, manifest: pinned, repo: repo)
        let repoName = hub.repo.name ?? PackageStore.repoName(fromSource: manifest.repoURL)

        var describable: [String: PacketFact] = [:]
        for fact in facts where fact.status != "proposed" && describable[fact.id] == nil {
            describable[fact.id] = fact
        }
        let usable = facts.filter { $0.status == "verified" || $0.status == "unknown" }

        let partial = PlaybackAgent(
            store: store, videoId: videoId, repoName: repoName, headSHA: headSHA,
            transcript: transcript, coderefs: coderefs, usableFacts: usable,
            describableFacts: describable, source: source, settings: settings, system: [])
        let system = [
            MessagesRequest.SystemBlock(partial.roleBlock()),
            MessagesRequest.SystemBlock(PlaybackAgent.digestBlock(store: store, hub: hub,
                                                                  manifest: manifest, headSHA: headSHA)),
            MessagesRequest.SystemBlock(partial.videoBlock(), cacheControl: true),
        ]
        return PlaybackAgent(
            store: store, videoId: videoId, repoName: repoName, headSHA: headSHA,
            transcript: transcript, coderefs: coderefs, usableFacts: usable,
            describableFacts: describable, source: source, settings: settings, system: system)
    }

    /// The tools this conversation runs, writing flags through `review`.
    func tools(review: ReviewFiles) -> PackageTools {
        let router = LinkRouter(store: store, headSHA: headSHA, factIDs: Set(describableFacts.keys))
        return PackageTools(store: store, source: source, router: router, review: review,
                            facts: describableFacts)
    }

    // MARK: - Request

    /// The run configuration for the `n`th question of a session (1-based). The
    /// prompt name carries `n` because each question is its own run, and a fixture
    /// recording is keyed by prompt name and per-run turn.
    func config(question n: Int) -> AgentRunConfig {
        var config = AgentRunConfig(unitId: "chat-\(videoId)", promptName: "\(PlaybackAgent.promptName)-q\(n)",
                                    model: settings.model)
        config.system = system
        config.effort = .medium
        config.maxTokens = PlaybackAgent.maxTokens
        // Chat always streams, whatever the token ceiling: the viewer is watching
        // the answer arrive (ARCHITECTURE 4.2).
        config.stream = true
        config.maxTurns = 12
        config.betas = settings.betas
        config.serverSideFallback = settings.serverSideFallback
        return config
    }

    /// The request the next question sends, and the context it was built from.
    /// `earlier` is the summary a rolled-over session carries into its first turn.
    func buildRequest(t: Double, question: String, history: [AgentMessage],
                      earlier: String? = nil) async -> (request: MessagesRequest, context: PlaybackContext) {
        let (turn, context) = await userTurn(t: t, question: question, earlier: earlier)
        let questionNumber = history.filter { $0.role == .user && PlaybackAgent.isQuestionTurn($0) }.count + 1
        let request = AgentRun.request(config: config(question: questionNumber),
                                       history: history + [turn], tools: PackageTools.specs)
        return (request, context)
    }

    /// The new user turn: one text block of context, one with the question. Two
    /// blocks so the moving cache breakpoint lands on the question and the context
    /// above it is cached with the rest of the turn on the next follow-up.
    func userTurn(t: Double, question: String, earlier: String? = nil) async -> (AgentMessage, PlaybackContext) {
        var context = await self.context(at: t)
        var blocks: [ContentBlock] = []
        if let earlier, !earlier.isEmpty {
            blocks.append(.text("<earlier_conversation>\n\(earlier)\n</earlier_conversation>"))
        }
        blocks.append(.text(context.text))
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        blocks.append(.text("<viewer_question>\n\(asked)\n</viewer_question>"))
        context.text += "\n<viewer_question>\n\(asked)\n</viewer_question>"
        return (AgentMessage(role: .user, content: blocks), context)
    }

    /// A user turn that carries a viewer question (rather than tool results or a
    /// continue nudge).
    static func isQuestionTurn(_ message: AgentMessage) -> Bool {
        message.content.contains { $0.text?.hasPrefix("<viewer_question>") == true }
    }

    /// The question a user turn carried, without its tags.
    static func question(in message: AgentMessage) -> String? {
        guard let block = message.content.last(where: { $0.text?.hasPrefix("<viewer_question>") == true }),
              var text = block.text else { return nil }
        text = text.replacingOccurrences(of: "<viewer_question>", with: "")
            .replacingOccurrences(of: "</viewer_question>", with: "")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - System blocks

    func roleBlock() -> String {
        let sha7 = String(headSHA.prefix(7))
        return """
        You are the onboarding companion for \(repoName) at \(sha7). You answer while the viewer \
        watches. Cite every claim about code or the package with [[anchor]]. Never assert what you \
        have not read or what the narration has not said. When the answer lies later in the video, \
        say so and offer the chapter. When code you read contradicts the narration, say so plainly \
        and call flag_contradiction.

        Answer short first: two to six sentences that answer the question, then detail only if it \
        helps. The viewer is mid-video; they want to get back to it.

        Citations. One grammar: [[anchor]] or [[anchor|label]]. Each one becomes a button that \
        opens what it names, so cite only what resolves:
        - code:<path>@\(sha7)#L<a>-L<b> for lines of the repository at the pinned commit. Cite \
        lines that are on screen (the on_screen block shows them) or that a tool returned this \
        turn. read_file's header names the exact anchor to copy.
        - doc:<id>#<slug> for a section of a package document.
        - diagram:<id> or diagram:<id>#<node> for a diagram or one node of it.
        - video:<id>#t=<seconds> for a moment in a video.
        - fact:<id> for a research fact. A fact marked refuted was rejected by the verifier: \
        never repeat it as true.
        Never invent a line range: an anchor to lines you have not seen is a wrong answer with \
        a button on it.

        What you are given each turn: narrated_so_far is what the viewer has heard. on_screen \
        is the shot at the viewer's current time, with its source and the facts behind it. \
        coming_up is narration the viewer has NOT heard yet; you may say a topic is coming up, \
        but do not present its content as already explained. Earlier questions in this \
        conversation are above the newest one.

        Tools read the repository at \(sha7) and this package. Use them when the answer is not \
        on screen. seek_video only proposes a jump; the video moves only if the viewer clicks. \
        flag_contradiction records a correction for the package author; call it only after \
        reading the code that contradicts the narration.
        """
    }

    /// Deliverables, the pinned commit and the module map: what the package is,
    /// so "is there a doc about X" needs no tool call.
    static func digestBlock(store: PackageStore, hub: HubIndex, manifest: OnboardingManifest,
                            headSHA: String) -> String {
        var out = "<package_digest>\n"
        out += "repository: \(hub.repo.display)\n"
        out += "headSHA: \(headSHA)\n"
        if !hub.summary.isEmpty { out += "summary: \(firstSentence(hub.summary))\n" }
        out += "deliverables (cite them by id):\n"
        for item in OnboardingViewModel.readingOrder(hub: hub, manifest: manifest) {
            var line = "- \(item.id) (\(item.kind), \(item.minutes) min): \(item.title)"
            if item.kind == "video", let id = item.id.split(separator: ":").last.map(String.init),
               let doc = try? OnboardingJSON.decoder().decode(
                   TranscriptDoc.self, from: store.readData("videos/\(id)/\(TranscriptDoc.fileName)")),
               !doc.summary.isEmpty {
                line += " — " + firstSentence(doc.summary)
            }
            out += line + "\n"
        }
        let directories = hub.coverage.directories
        if !directories.isEmpty {
            out += "module map (directory, research coverage, files read of files):\n"
            for directory in directories {
                out += "- \(directory.path)/ \(directory.level) \(directory.filesRead)/\(directory.files)"
                if let reason = directory.reason, !reason.isEmpty { out += " (\(reason))" }
                out += "\n"
            }
        }
        out += "</package_digest>"
        return out
    }

    func videoBlock() -> String {
        var out = "<video id=\"\(videoId)\" duration=\"\(PlaybackAgent.timecode(transcript.duration))\">\n"
        out += "summary: \(transcript.summary)\n"
        out += "chapters:\n"
        for chapter in transcript.chapters {
            var line = "- [\(PlaybackAgent.timecode(chapter.start))] \(chapter.id) \(chapter.title) "
                + "[[video:\(videoId)#t=\(PackageTools.seconds(chapter.start))]]"
            if let doc = chapter.docAnchor, !doc.isEmpty { line += " narrates [[\(doc)]]" }
            out += line + "\n"
        }
        let top = topFacts()
        if !top.isEmpty {
            out += "top facts for this video's subject:\n"
            for fact in top {
                let anchors = fact.evidence.map { "[[\($0.anchor)]]" }.joined(separator: " ")
                out += "- \(fact.id) (\(fact.status)): \(fact.claim) \(anchors)\n"
            }
        }
        out += "</video>"
        return out
    }

    /// The facts behind the shots, three per shot in video order, deduplicated.
    func topFacts() -> [PacketFact] {
        var seen = Set<String>()
        var out: [PacketFact] = []
        for interval in coderefs.intervals {
            for fact in shotFacts(interval).prefix(3) where !seen.contains(fact.id) {
                seen.insert(fact.id)
                out.append(fact)
                if out.count == PlaybackAgent.maxTopFacts { return out }
            }
        }
        return out
    }

    // MARK: - The context at t

    func context(at t: Double) async -> PlaybackContext {
        var context = PlaybackContext(t: t)
        let segments = transcript.segments
        let chapter = transcript.chapter(at: t)
        let interval = coderefs.lookup(t)
        context.chapterId = chapter?.id ?? interval?.sceneId
        context.shotId = interval?.shotId
        context.sceneType = interval?.sceneType

        // narrated_so_far
        let narrated = segments.filter { $0.end <= t }
        context.narratedIds = narrated.map { $0.id }
        let verbatim = Array(narrated.suffix(PlaybackAgent.verbatimSegments))
        context.verbatimIds = verbatim.map { $0.id }
        let collapsed = narrated.dropLast(verbatim.count)
        let current = segments.first { $0.start <= t && t < $0.end }
        context.inProgressId = current?.id

        var text = "<narrated_so_far>\n"
        var collapsedScenes: [String] = []
        for segment in collapsed where !collapsedScenes.contains(segment.sceneId) {
            collapsedScenes.append(segment.sceneId)
            let title = transcript.chapters.first { $0.id == segment.sceneId }?.title ?? segment.sceneId
            text += "[\(PlaybackAgent.timecode(segment.start))] \(title): \(segment.text) (chapter summarized)\n"
        }
        for segment in verbatim {
            text += "[\(PlaybackAgent.timecode(segment.start))] \(segment.text)\n"
        }
        if let current {
            if current.words != nil {
                text += "[\(PlaybackAgent.timecode(current.start))] (in progress: \(current.spoken(by: t)))\n"
            } else {
                text += "[\(PlaybackAgent.timecode(current.start))] (in progress)\n"
            }
        }
        if narrated.isEmpty && current == nil { text += "(nothing yet)\n" }
        text += "</narrated_so_far>\n"

        // on_screen
        if let interval {
            text += await onScreen(interval, t: t, into: &context)
        } else {
            text += "<on_screen t=\"\(PackageTools.seconds(t))\">\n(nothing: the video has not started)\n</on_screen>\n"
        }

        // coming_up
        let upcoming = segments.filter { $0.start > t }.prefix(PlaybackAgent.comingUpCount)
        context.comingUpIds = upcoming.map { $0.id }
        text += "<coming_up>\n"
        if upcoming.isEmpty { text += "(the narration is over)\n" }
        for segment in upcoming {
            text += "[\(PlaybackAgent.timecode(segment.start))] (not yet narrated) \(segment.text)\n"
        }
        text += "</coming_up>"
        context.text = text
        return context
    }

    private func onScreen(_ interval: CodeRefInterval, t: Double,
                          into context: inout PlaybackContext) async -> String {
        context.intervalAnchors = interval.anchors
        var out = "<on_screen t=\"\(PackageTools.seconds(t))\" chapter=\"\(interval.sceneId)\" "
            + "shot=\"\(interval.shotId)\">\n"
        out += "scene: \(interval.sceneType)\n"
        if !interval.anchors.isEmpty {
            out += "anchors: " + interval.anchors.map { "[[\($0)]]" }.joined(separator: " ") + "\n"
        }
        if let highlight = interval.highlight {
            out += "highlight: [[\(highlight.anchor)]]"
            if !highlight.callout.isEmpty { out += " callout: \(highlight.callout)" }
            out += "\n"
        }

        switch interval.sceneType {
        case "diagram":
            out += diagramExcerpt(interval)
        case "terminal":
            out += terminalExcerpt(interval)
        default:
            if let found = await inlinedSource(interval) {
                let (path, range, lines) = found
                context.inlinedPath = path
                context.inlinedLines = range
                out += "source [[code:\(path)@\(source.sha7)#L\(range.lowerBound)-L\(range.upperBound)]] "
                    + "(\(lines.count) lines in the file):\n"
                out += PackageTools.numbered(lines, from: range.lowerBound, to: range.upperBound) + "\n"
            }
        }

        let facts = shotFacts(interval)
        context.factIds = facts.map { $0.id }
        if !facts.isEmpty {
            out += "facts behind this shot:\n"
            for fact in facts {
                out += "- \(fact.id) (\(fact.status)): \(fact.claim)\n"
                for evidence in fact.evidence {
                    out += "  evidence [[\(evidence.anchor)]]"
                    if let excerpt = evidence.excerpt?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !excerpt.isEmpty {
                        let short = excerpt.split(separator: "\n").prefix(4).joined(separator: " / ")
                        out += " excerpt: \(short)"
                    }
                    out += "\n"
                }
            }
        }
        out += "</on_screen>\n"
        return out
    }

    /// The highlighted range (or the first code anchor's, or the visible lines) with
    /// 20 lines either side, read at the pinned commit.
    func inlinedSource(_ interval: CodeRefInterval) async -> (String, ClosedRange<Int>, [String])? {
        let candidates = [interval.highlight?.anchor].compactMap { $0 }
            + interval.anchors.filter { $0.hasPrefix("code:") }
        for raw in candidates {
            guard case .code(let path, _, let range)? = Anchor(string: raw),
                  let lines = await source.lines(of: path), !lines.isEmpty else { continue }
            let core: ClosedRange<Int>
            if let range {
                core = range
            } else if let visible = interval.visibleLines, visible.count == 2 {
                core = max(1, visible[0])...max(visible[0], visible[1])
            } else {
                core = 1...min(lines.count, 40)
            }
            let low = max(1, core.lowerBound - PlaybackAgent.contextLines)
            let high = min(lines.count, core.upperBound + PlaybackAgent.contextLines)
            guard low <= high else { continue }
            return (path, low...high, lines)
        }
        return nil
    }

    private func diagramExcerpt(_ interval: CodeRefInterval) -> String {
        guard let id = interval.diagram, !id.isEmpty, !id.contains("/"),
              let source = try? store.readString("diagrams/\(id).mmd") else { return "" }
        var out = "diagram [[diagram:\(id)]]:\n```mermaid\n\(source.trimmingCharacters(in: .newlines))\n```\n"
        let focus = interval.focusNodes ?? []
        guard !focus.isEmpty else { return out }
        var nodes: [String: JSONValue] = [:]
        if let data = try? store.readData("diagrams/\(id).links.json"),
           let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
            nodes = value.objectValue?["nodes"]?.objectValue ?? [:]
        }
        out += "focused nodes:\n"
        for node in focus {
            out += "- [[diagram:\(id)#\(node)]]"
            if let link = nodes[node], let data = try? MessagesRequest.canonicalJSON(link) {
                out += " " + String(decoding: data, as: UTF8.self)
            }
            out += "\n"
        }
        return out
    }

    private func terminalExcerpt(_ interval: CodeRefInterval) -> String {
        guard let raw = interval.cmd ?? interval.anchors.first(where: { $0.hasPrefix("cmd:") }),
              let output = store.commandOutput(raw) else { return "" }
        let lines = output.components(separatedBy: "\n")
        var out = "command output [[\(raw)]]:\n```\n" + lines.prefix(60).joined(separator: "\n") + "\n```\n"
        if lines.count > 60 { out += "(\(lines.count - 60) more lines)\n" }
        return out
    }

    /// The facts behind a shot: those it names, then usable facts whose evidence
    /// overlaps its code, closest match first. Refuted and proposed facts never
    /// appear: the on-screen block is what an answer may treat as established.
    func shotFacts(_ interval: CodeRefInterval) -> [PacketFact] {
        var out: [PacketFact] = []
        var seen = Set<String>()
        let byId = Dictionary(usableFacts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in interval.factIds {
            if let fact = byId[id], !seen.contains(id) {
                seen.insert(id)
                out.append(fact)
            }
        }

        var targets: [(path: String, range: ClosedRange<Int>?)] = []
        for raw in [interval.highlight?.anchor].compactMap({ $0 }) + interval.anchors {
            if case .code(let path, _, let range)? = Anchor(string: raw),
               !targets.contains(where: { $0.path == path && $0.range == range }) {
                targets.append((path, range))
            }
        }
        guard !targets.isEmpty else { return Array(out.prefix(PlaybackAgent.maxShotFacts)) }

        var scored: [(fact: PacketFact, score: Double)] = []
        for fact in usableFacts where !seen.contains(fact.id) {
            var best = 0.0
            for evidence in fact.evidence {
                guard case .code(let path, _, let range)? = Anchor(string: evidence.anchor) else { continue }
                for target in targets where target.path == path {
                    best = max(best, PlaybackAgent.overlap(range, target.range))
                }
            }
            if best > 0 { scored.append((fact, best)) }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.fact.id < $1.fact.id }
        out += scored.map { $0.fact }
        return Array(out.prefix(PlaybackAgent.maxShotFacts))
    }

    /// Jaccard overlap of two line ranges; a missing range means the whole file and
    /// scores a weak 0.1 against anything in it.
    static func overlap(_ a: ClosedRange<Int>?, _ b: ClosedRange<Int>?) -> Double {
        guard let a, let b else { return 0.1 }
        let low = max(a.lowerBound, b.lowerBound)
        let high = min(a.upperBound, b.upperBound)
        guard low <= high else { return 0 }
        let intersection = Double(high - low + 1)
        let union = Double(max(a.upperBound, b.upperBound) - min(a.lowerBound, b.lowerBound) + 1)
        return intersection / union
    }

    // MARK: - Formatting

    /// `m:ss`, or `h:mm:ss` past an hour. Nonisolated on purpose: tools and probes
    /// format times off the main actor.
    static func timecode(_ t: Double) -> String {
        let total = max(0, Int(t.isFinite ? t : 0))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, seconds) }
        return String(format: "%02d:%02d", minutes, seconds)
    }

    static func firstSentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let end = trimmed.range(of: ". ") { return String(trimmed[..<end.lowerBound]) + "." }
        return trimmed
    }
}
