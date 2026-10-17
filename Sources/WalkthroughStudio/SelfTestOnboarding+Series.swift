// SelfTestOnboarding+Series — Onboard to a Codebase, milestone M9 (video scripts and the series).
//
//   scriptInvariantsProbe    the fixture smoke script fits 60 s and validates; over budget, a
//                            dangling anchor, a refuted fact, a missing tldr, a highlight outside
//                            the window, a missing hop and a headless table are each rejected
//   scriptPlannerProbe       emit_script rejects once with the error list, accepts the fix; a
//                            second rejection ends the unit with no video and a notice
//   seriesSmokeProbe         smoke scope renders exactly one video, and its timing files pass
//                            the section 6 invariants
//   traceVideoChaptersProbe  the hop chapters are the hop list; each one's interval names the
//                            hop's anchor (ON-5.4)
//   regenerateOneProbe       regenerating one video leaves every other video's files and
//                            manifest entry as they were (ON-6.6)
//
// The series probes work on a copy of the fixture package (`series-package.onboarding`),
// so fixturePackageProbe's one-video package stays what the earlier probes assert.

import Foundation
import AppKit

extension SelfTest {

    static let seriesTraceID = "order-creation"
    static var seriesVideoID: String { TraceScript.videoID(pathId: seriesTraceID) }

    /// Where `seriesSmokeProbe` leaves the package the two probes after it read.
    static func seriesPackageURL(_ ctx: OnboardingProbeContext) -> URL {
        ctx.outDir.appendingPathComponent("series-package.onboarding", isDirectory: true)
    }

    static func seriesOptions() -> VideoAssembler.Options {
        var options = VideoAssembler.Options()
        options.size = FixturePackage.frameSize
        options.narratorName = "tone"
        return options
    }

    static func seriesFacts(_ packet: ResearchPacket) -> [String: PacketFact] {
        Dictionary(packet.facts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// The smoke script exactly as the runner would render it: written, then tightened.
    static func smokeScript(packet: ResearchPacket, store: PackageStore, repo: URL)
        async throws -> (raw: VideoScript, tight: SeriesPlanner.Tightened, rules: ScriptValidator.Rules) {
        guard let trace = packet.traces[seriesTraceID] else {
            throw StudioError("the fixture packet has no \(seriesTraceID) trace")
        }
        let source = PinnedSource(sha: packet.headSHA, repo: repo, snapshotRoot: store.url("code"))
        let raw = await TraceScript.make(trace: trace, packet: packet, source: source, cut: .hops,
                                         budgetSeconds: SeriesPlanner.smokeBudgetSeconds)
        var rules = ScriptValidator.Rules.series(budgetSeconds: SeriesPlanner.smokeBudgetSeconds,
                                                 facts: seriesFacts(packet))
        rules.traceHops = trace.hops.count
        let tight = SeriesPlanner.tighten(raw, budget: SeriesPlanner.smokeBudgetSeconds, rules: rules)
        return (raw, tight, rules)
    }

    /// Every file under a package directory, with its modification date.
    static func modificationDates(_ store: PackageStore, _ directory: String) -> [String: Date] {
        // Resolved: /tmp is a symlink on macOS, and the enumerator may hand back either form.
        let root = store.url(directory).resolvingSymlinksInPath()
        var out: [String: Date] = [:]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys:
                                                            [.contentModificationDateKey, .isRegularFileKey]) else {
            return out
        }
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let date = values?.contentModificationDate else { continue }
            let path = url.resolvingSymlinksInPath().path
            guard path.hasPrefix(root.path) else { continue }
            out[String(path.dropFirst(root.path.count))] = date
        }
        return out
    }

    // MARK: - scriptInvariantsProbe

    static func scriptInvariantsProbe(_ ctx: OnboardingProbeContext) async throws {
        let store = try SelfTest.chatStore(ctx, probe: "scriptInvariantsProbe")
        let packet = try PacketReader.load(store.url("packet"))
        let router = LinkRouter(store: store, headSHA: packet.headSHA)
        let sha7 = packet.sha7

        // 1. Smoke scope plans exactly one video: the top-ranked traced path, hops only.
        let plan = SeriesPlanner.plan(packet: packet, scope: .smoke)
        guard plan.count == 1, let item = plan.first,
              item.source == .trace(pathId: seriesTraceID, cut: .hops),
              item.budgetSeconds == 60 else {
            throw StudioError("scriptInvariantsProbe: smoke plans \(plan.map { $0.videoId }), expected only "
                              + "\(seriesVideoID) at 60 s")
        }

        // 2. The fixture smoke script: written long, tightened under 60 s, and valid.
        let (raw, tight, rules) = try await SelfTest.smokeScript(packet: packet, store: store,
                                                                 repo: ctx.fixtureRepo)
        let rawReport = ScriptValidator.validate(raw, router: router, rules: rules)
        guard rawReport.estimatedSeconds > 60 else {
            throw StudioError(String(format: "scriptInvariantsProbe: the untightened trace already runs %.0fs, "
                                     + "so the tighten loop was never exercised", rawReport.estimatedSeconds))
        }
        guard rawReport.errors.contains(where: { $0.at == raw.id && $0.message.contains("budget") }) else {
            throw StudioError("scriptInvariantsProbe: a script over its budget was not rejected: "
                              + ScriptValidator.message(for: rawReport))
        }
        let good = tight.script
        let report = ScriptValidator.validate(good, router: router, rules: rules)
        guard tight.fits, report.ok, report.estimatedSeconds <= 60 else {
            throw StudioError(String(format: "scriptInvariantsProbe: the tightened smoke script runs %.1fs: ",
                                     report.estimatedSeconds) + ScriptValidator.message(for: report))
        }
        guard report.warnings.isEmpty else {
            throw StudioError("scriptInvariantsProbe: the smoke script warns: "
                              + report.warnings.map { $0.description }.joined(separator: "; "))
        }
        // Tightening cut words, never hops, and never left a line ending mid-word.
        let hopScenes = good.scenes.filter { $0.traceHop != nil }
        guard hopScenes.count == packet.traces[seriesTraceID]?.hops.count,
              good.shots.allSatisfy({ ".!?\")".contains($0.shot.narration.last ?? " ") }) else {
            throw StudioError("scriptInvariantsProbe: tightening lost a hop or left an unterminated line: "
                              + good.shots.map { $0.shot.narration }.joined(separator: " | "))
        }
        if let card = good.shots.first(where: { $0.shot.sceneType == "card" }),
           ToneNarrator().estimatedDuration(of: card.shot.narration) + card.shot.pad < 4 {
            throw StudioError("scriptInvariantsProbe: the tldr card is held under 4 s")
        }

        // 3. Each way a planned script goes wrong is caught, by place and by reason.
        func expect(_ name: String, _ script: VideoScript, at place: String?, _ needle: String) throws {
            let bad = ScriptValidator.validate(script, router: router, rules: rules)
            guard bad.errors.contains(where: { (place == nil || $0.at == place) && $0.message.contains(needle) })
            else {
                throw StudioError("scriptInvariantsProbe: \(name) was not rejected (looked for \"\(needle)\""
                                  + (place.map { " at \($0)" } ?? "") + "); got: " + ScriptValidator.message(for: bad))
            }
        }
        func shotIndex(_ sceneID: String) -> Int {
            good.scenes.firstIndex { $0.id == sceneID } ?? 1
        }

        var dangling = good
        dangling.scenes[shotIndex("h01")].shots[0].anchors.append("code:src/api/nope.py@\(sha7)#L1-L2")
        try expect("a dangling anchor", dangling, at: "h01a", "nope.py")

        guard let refuted = packet.facts.first(where: { $0.status == "refuted" })?.id else {
            throw StudioError("scriptInvariantsProbe: the fixture packet has no refuted fact to cite")
        }
        var lying = good
        lying.scenes[shotIndex("h02")].shots[0].factIds.append(refuted)
        try expect("a refuted fact", lying, at: "h02a", "refuted")

        var headless = good
        headless.scenes.removeFirst()
        try expect("a missing tldr", headless, at: "h01", "tldr")

        var untitled = good
        untitled.scenes[0].variant = "chapter"
        try expect("a first card that is not a tldr", untitled, at: "s01", "tldr")

        var offscreen = good
        let h03 = shotIndex("h03")
        guard case .code(_, _, let lines?)? = Anchor(string: good.scenes[h03].shots[0].highlight?.anchor ?? "") else {
            throw StudioError("scriptInvariantsProbe: hop 3's highlight names no line range")
        }
        offscreen.scenes[h03].shots[0].visibleLines = [lines.upperBound + 2, lines.upperBound + 30]
        try expect("a highlight outside the window", offscreen, at: "h03a", "outside the panel")

        var tall = good
        tall.scenes[h03].shots[0].visibleLines = [1, 60]
        try expect("a window over 40 lines", tall, at: "h03a", "40-line")

        var skipped = good
        skipped.scenes.remove(at: shotIndex("h05"))
        try expect("a trace video missing a hop", skipped, at: good.id, "one scene per hop")

        var rushed = good
        rushed.scenes[0].shots[0].narration = "Orders."
        rushed.scenes[0].shots[0].pad = 0.6
        try expect("a card held under 4 s", rushed, at: "s01a", "4s on screen")

        var rambling = good
        rambling.scenes[0].shots[0].narration = String(repeating: "This sentence keeps the tldr going. ", count: 20)
        try expect("a tldr over 30 s", rambling, at: "s01a", "30s or less")

        // 4. The full trace cut: map, concern table and confessional, under 900 s.
        guard let trace = packet.traces[seriesTraceID] else { return }
        let source = PinnedSource(sha: packet.headSHA, repo: ctx.fixtureRepo, snapshotRoot: store.url("code"))
        var fullRules = ScriptValidator.Rules.series(facts: SelfTest.seriesFacts(packet))
        fullRules.traceHops = trace.hops.count
        let full = SeriesPlanner.tighten(
            await TraceScript.make(trace: trace, packet: packet, source: source, cut: .full, budgetSeconds: 900),
            budget: 900, rules: fullRules).script
        let fullReport = ScriptValidator.validate(full, router: router, rules: fullRules)
        let kinds = Set(full.shots.map { $0.shot.sceneType })
        guard fullReport.ok, kinds.isSuperset(of: ["card", "code", "diagram", "table"]),
              full.scenes.last?.variant == "confessional",
              (6...14).contains(full.scenes.count) else {
            throw StudioError("scriptInvariantsProbe: the full trace script (\(full.scenes.count) scenes, "
                              + "kinds \(kinds.sorted())) — " + ScriptValidator.message(for: fullReport))
        }
        var tableless = full
        if let concerns = tableless.scenes.firstIndex(where: { $0.id == "concerns" }) {
            tableless.scenes[concerns].shots[0].table = []
        }
        let noHeader = ScriptValidator.validate(tableless, router: router, rules: fullRules)
        guard noHeader.errors.contains(where: { $0.at == "concernsa" && $0.message.contains("header") }) else {
            throw StudioError("scriptInvariantsProbe: a table with no header row was not rejected")
        }

        // 5. Confessionals: one per subsystem with enough fragility, each valid.
        let subsystems = SeriesPlanner.subsystems(packet)
        guard subsystems.contains(where: { $0.dir == "src/" }),
              !subsystems.contains(where: { $0.dir == "vendor/" || $0.dir == "." }) else {
            throw StudioError("scriptInvariantsProbe: subsystems \(subsystems.map { $0.dir }) — expected src/ "
                              + "and never the generated vendor/ or the root")
        }
        for subsystem in subsystems {
            let script = await SeriesPlanner.confessionalScript(subsystem: subsystem.dir, facts: subsystem.facts,
                                                                packet: packet, source: source)
            let seriesRules = ScriptValidator.Rules.series(facts: SelfTest.seriesFacts(packet))
            let fitted = SeriesPlanner.tighten(script, budget: 900, rules: seriesRules).script
            let confessional = ScriptValidator.validate(fitted, router: router, rules: seriesRules)
            guard confessional.ok else {
                throw StudioError("scriptInvariantsProbe: the \(subsystem.dir) confessional — "
                                  + ScriptValidator.message(for: confessional))
            }
        }

        // 6. Complete scope: the ten, a trace per traced path, a confessional per subsystem.
        let complete = SeriesPlanner.plan(packet: packet, scope: .complete)
        let traced = packet.paths.paths.filter { $0.isTraced && packet.traces[$0.id] != nil }.count
        guard complete.count == SeriesPlanner.series.count + traced + subsystems.count,
              Set(complete.map { $0.videoId }).count == complete.count else {
            throw StudioError("scriptInvariantsProbe: complete scope plans \(complete.count) videos "
                              + "(\(complete.map { $0.videoId })), expected 10 + \(traced) + \(subsystems.count), "
                              + "all distinct")
        }

        print(String(format: "selftest: scriptInvariantsProbe OK (smoke %.0fs -> %.1fs in %d cuts; nine ways to "
                     + "break a script each rejected; full trace %d scenes; %d confessional(s); complete "
                     + "scope %d videos)", rawReport.estimatedSeconds, report.estimatedSeconds,
                     tight.steps.count, full.scenes.count, subsystems.count, complete.count))
    }

    // MARK: - scriptPlannerProbe

    /// A planned overview: tldr, four code scenes on the fixture's real lines, confessional.
    static func plannedOverview(sha7: String) -> VideoScript {
        func code(_ scene: String, _ title: String, _ anchor: String, _ narration: String,
                  _ facts: [String]) -> VideoScript.Scene {
            VideoScript.Scene(id: scene, title: title, shots: [
                VideoScript.Shot(id: "\(scene)a", sceneType: "code", narration: narration,
                                 anchors: [anchor], highlight: CodeRefHighlight(anchor: anchor, callout: title),
                                 factIds: facts, caption: title),
            ])
        }
        return VideoScript(
            id: "overview", title: "Architecture overview",
            summary: "Four directories and one database: how a request moves through the order service.",
            sha: sha7, scenes: [
                VideoScript.Scene(id: "s01", title: "TL;DR", variant: "tldr", shots: [
                    VideoScript.Shot(id: "s01a", sceneType: "card",
                                     narration: "A small Python order service in four layers: a handler, an "
                                        + "authorization check, a service and a repository. Here is how a "
                                        + "request moves through them, and where it bites.",
                                     caption: "Architecture overview",
                                     bullets: ["Handler, authz, service, repository",
                                               "One Postgres database", "No framework binds the routes"]),
                ]),
                code("s02", "The handler", "code:src/api/orders_handler.py@\(sha7)#L6-L11",
                     "Every request starts in a plain function that reads the body directly.",
                     ["F-map-src-005"]),
                code("s03", "Authorization", "code:src/auth/authz.py@\(sha7)#L8-L10",
                     "Authorization compares a header with a value from the same request.",
                     ["F-map-src-013"]),
                code("s04", "The service", "code:src/service/orders.py@\(sha7)#L9-L11",
                     "The service sums the items and hands the total to the repository.",
                     ["F-map-src-018"]),
                code("s05", "The repository", "code:src/repo/orders_repo.py@\(sha7)#L11-L18",
                     "The repository retries an insert with no idempotency key.",
                     ["F-lens-landmines-glossary-002"]),
                VideoScript.Scene(id: "s06", title: "What scares me", variant: "confessional", shots: [
                    VideoScript.Shot(id: "s06a", sceneType: "card",
                                     narration: "A retry after a successful commit books a second order, and "
                                        + "nothing in the code would tell you.",
                                     caption: "What scares me"),
                ]),
            ])
    }

    static func scriptJSON(_ script: VideoScript) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(script))
    }

    static func scriptPlannerProbe(_ ctx: OnboardingProbeContext) async throws {
        let store = try SelfTest.chatStore(ctx, probe: "scriptPlannerProbe")
        let packet = try PacketReader.load(store.url("packet"))
        let sha7 = packet.sha7
        let unit = ScriptPlannerUnit(
            store: store, packet: packet, settings: try SelfTest.chatSettings(),
            source: PinnedSource(sha: packet.headSHA, repo: ctx.fixtureRepo, snapshotRoot: store.url("code")),
            repoName: "fixture-repo")
        let items = SeriesPlanner.plan(packet: packet, scope: .complete)
        guard let overview = items.first(where: { $0.videoId == "overview" }),
              let domain = items.first(where: { $0.videoId == "domain" }) else {
            throw StudioError("scriptPlannerProbe: complete scope did not plan overview and domain")
        }

        let good = SelfTest.plannedOverview(sha7: sha7)
        guard ScriptValidator.validate(good, router: LinkRouter(store: store, headSHA: packet.headSHA),
                                       rules: .series(facts: SelfTest.seriesFacts(packet))).ok else {
            throw StudioError("scriptPlannerProbe: the probe's own planned script does not validate")
        }
        // Three things wrong at once: no tldr, a dangling anchor, a refuted fact.
        var bad = good
        bad.scenes.removeFirst()
        bad.scenes[0].shots[0].anchors.append("code:src/api/gone.py@\(sha7)#L1-L3")
        bad.scenes[1].shots[0].factIds.append("F-map-src-001")

        func emit(_ prompt: String, turn: Int, _ script: VideoScript) throws -> FixtureTransport.Recording {
            SelfTest.chatRecording(prompt, turn: turn, sse: SelfTest.chatSSE(
                text: turn == 0 ? "Here is the script." : "Fixed.",
                tools: [(id: "toolu_script_\(prompt.count)_\(turn)", name: ScriptPlannerTools.emitName,
                         input: ["script": try SelfTest.scriptJSON(script)])],
                stopReason: "tool_use"))
        }
        let transport = FixtureTransport(recordings: [
            try emit("script-planner-overview", turn: 0, bad),
            try emit("script-planner-overview", turn: 1, good),
            try emit("script-planner-domain", turn: 0, bad),
            try emit("script-planner-domain", turn: 1, bad),
        ])

        // 1. Rejected once with every error listed, then accepted.
        let accepted = await unit.run(overview, transport: transport, apiKey: SelfTest.probeAPIKey,
                                      meter: SpendMeter(), breaker: CircuitBreaker(), sleep: { _ in })
        guard let script = accepted.script, accepted.attempts == 2, script.id == "overview",
              script.kind == "overview", script.scenes.count == good.scenes.count else {
            throw StudioError("scriptPlannerProbe: the overview unit ended with \(accepted.attempts) attempt(s), "
                              + "script \(accepted.script?.id ?? "none"); notices \(accepted.notices)")
        }
        let sent = await transport.sent
        guard sent.count == 2 else {
            throw StudioError("scriptPlannerProbe: the overview unit sent \(sent.count) request(s), expected 2")
        }
        let second = try SelfTest.requestJSON(sent[1])
        let result = second["messages"]?.arrayValue?.last?.objectValue?["content"]?.arrayValue?.first?.objectValue
        let resultText = result?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue
            ?? result?["content"]?.stringValue ?? ""
        guard result?["is_error"]?.boolValue == true,
              resultText.contains("tldr"), resultText.contains("gone.py"), resultText.contains("refuted") else {
            throw StudioError("scriptPlannerProbe: the first rejection did not list all three errors: "
                              + resultText.prefix(400))
        }
        let firstBody = try SelfTest.requestJSON(sent[0])
        let toolNames = Set(firstBody["tools"]?.arrayValue?.compactMap { $0.objectValue?["name"]?.stringValue } ?? [])
        guard toolNames == ScriptPlannerTools.readTools.union([ScriptPlannerTools.emitName]),
              firstBody["output_config"]?.objectValue?["effort"]?.stringValue == "high" else {
            throw StudioError("scriptPlannerProbe: the planner declared \(toolNames.sorted()) at effort "
                              + "\(firstBody["output_config"]?.objectValue?["effort"]?.stringValue ?? "none")")
        }

        // 2. Rejected twice: the unit ends with no script and says why.
        let refused = await unit.run(domain, transport: transport, apiKey: SelfTest.probeAPIKey,
                                     meter: SpendMeter(), breaker: CircuitBreaker(), sleep: { _ in })
        guard refused.script == nil, refused.attempts == 2,
              refused.notices.contains(where: { $0.contains("rejected twice") }),
              await transport.sent.count == 4 else {
            throw StudioError("scriptPlannerProbe: a twice-rejected unit ended with \(refused.attempts) "
                              + "attempt(s), script \(refused.script?.id ?? "none"), notices \(refused.notices)")
        }

        print("selftest: scriptPlannerProbe OK (rejected once with tldr, anchor and refuted-fact errors, "
              + "then accepted; a second rejection ends the unit with a notice; effort high, read tools only)")
    }

    // MARK: - seriesSmokeProbe

    static func seriesSmokeProbe(_ ctx: OnboardingProbeContext) async throws {
        let fixture = SelfTest.fixturePackageURL(ctx)
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            throw StudioError("seriesSmokeProbe: run fixturePackageProbe first — \(fixture.path) is not there")
        }
        let root = SelfTest.seriesPackageURL(ctx)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.copyItem(at: fixture, to: root)
        let store = try PackageStore(root: root)
        LinkRouter.invalidateCache(for: store.root)
        let videosBefore = Set(store.listing("videos"))
        let deliverablesBefore = try store.readManifest().deliverables

        let runner = SeriesRunner(store: store, repo: ctx.fixtureRepo, narrator: ToneNarrator(),
                                  options: SelfTest.seriesOptions())
        let result = try await runner.run(scope: .smoke)

        // 1. Exactly one video, the trace, and nothing degraded on the way.
        guard result.videos.count == 1, result.built.count == 1,
              let video = result.built.first, let built = video.built,
              video.item.videoId == seriesVideoID else {
            throw StudioError("seriesSmokeProbe: smoke built \(result.built.map { $0.item.videoId }) of "
                              + "\(result.videos.count) planned; notices: \(result.notices)")
        }
        guard result.notices.isEmpty else {
            throw StudioError("seriesSmokeProbe: the smoke video degraded:\n      "
                              + result.notices.prefix(4).joined(separator: "\n      "))
        }
        let videosAfter = Set(store.listing("videos"))
        guard videosAfter.subtracting(videosBefore) == [seriesVideoID], videosBefore.isSubset(of: videosAfter) else {
            throw StudioError("seriesSmokeProbe: videos/ went from \(videosBefore.sorted()) to \(videosAfter.sorted())")
        }

        // 2. At most a minute (the stills writer's tail hold is the only slack).
        guard built.duration <= 61.5 else {
            throw StudioError(String(format: "seriesSmokeProbe: the smoke video runs %.1fs, over 60 s", built.duration))
        }

        // 3. The timing files on disk obey section 6, read back the way the player reads them.
        let folder = "videos/\(seriesVideoID)"
        let transcript = try OnboardingJSON.decoder().decode(
            TranscriptDoc.self, from: try store.readData("\(folder)/\(TranscriptDoc.fileName)"))
        let coderefs = try OnboardingJSON.decoder().decode(
            CodeRefMap.self, from: try store.readData("\(folder)/\(CodeRefMap.fileName)"))
        try SelfTest.assertTimingInvariants(transcript: transcript, coderefs: coderefs)
        for file in ["video.mp4", "script.json", "chapters.json", "captions.srt", "captions.vtt", "chapters.vtt"]
        where !store.exists("\(folder)/\(file)") {
            throw StudioError("seriesSmokeProbe: \(folder)/\(file) was not written")
        }

        // 4. The manifest gained exactly that video, and lost nothing.
        let deliverablesAfter = try store.readManifest().deliverables
        guard deliverablesAfter.count == deliverablesBefore.count + 1,
              deliverablesBefore.allSatisfy({ before in deliverablesAfter.contains(before) }),
              let entry = deliverablesAfter.first(where: { $0.id == "video:\(seriesVideoID)" }),
              entry.status == .built, entry.path == "\(folder)/video.mp4", !entry.inputsHash.isEmpty else {
            throw StudioError("seriesSmokeProbe: the manifest's deliverables did not gain exactly the trace video")
        }

        // 5. The new card kinds, rendered to look at: the tldr from this video, and the
        //    concern table and confessional from the full cut.
        let packet = try PacketReader.load(store.url("packet"))
        let script = try store.readJSON(VideoScript.self, from: "\(folder)/\(VideoScript.fileName)")
        var stills: [(name: String, shot: VideoScript.Shot, scene: VideoScript.Scene, script: VideoScript)] = []
        if let tldr = script.scenes.first, let shot = tldr.shots.first { stills.append(("tldr", shot, tldr, script)) }
        if let trace = packet.traces[seriesTraceID] {
            let source = PinnedSource(sha: packet.headSHA, repo: ctx.fixtureRepo, snapshotRoot: store.url("code"))
            let full = await TraceScript.make(trace: trace, packet: packet, source: source, cut: .full,
                                              budgetSeconds: 900)
            for id in ["concerns", "scares"] {
                if let scene = full.scenes.first(where: { $0.id == id }), let shot = scene.shots.first {
                    stills.append((id, shot, scene, full))
                }
            }
        }
        let renderer = BrandedRenderer()
        let size = FixturePackage.frameSize
        var darkness: [String: Double] = [:]
        for still in stills {
            var diagrams: [String: String] = [:]
            var notices: [String] = []
            var input = try await VideoAssembler.sceneInput(
                for: still.shot, scene: still.scene, script: still.script, store: store, repo: ctx.fixtureRepo,
                git: GitRunner(), options: SelfTest.seriesOptions(), diagrams: &diagrams, notices: &notices,
                chapters: still.name == "tldr" ? transcript.chapters : [])
            input.size = size
            let html = try SceneRenderer.html(for: input)
            let unfilled = SelfTest.unfilledSlots(html)
            guard unfilled.isEmpty, notices.isEmpty else {
                throw StudioError("seriesSmokeProbe: the \(still.name) still left \(unfilled) unfilled, notices \(notices)")
            }
            let image = try await renderer.render(html: html, pixelWidth: Int(size.width),
                                                  pixelHeight: Int(size.height))
            guard let cg = SelfTest.cgImage(image) else {
                throw StudioError("seriesSmokeProbe: the \(still.name) still did not rasterize")
            }
            try? Exporters.pngData(from: image, pixelWidth: Int(size.width), pixelHeight: Int(size.height))?
                .write(to: ctx.outDir.appendingPathComponent("series-\(still.name).png"))
            darkness[still.name] = SelfTest.imageStats(cg).darkFraction
        }
        // The confessional is the one charcoal card; the tldr and the table stay cream.
        guard (darkness["scares"] ?? 0) > 0.6, (darkness["tldr"] ?? 1) < 0.10,
              (darkness["concerns"] ?? 1) < 0.10 else {
            throw StudioError("seriesSmokeProbe: dark fractions \(darkness) — the confessional should be "
                              + "charcoal and the tldr and table cream")
        }

        print(String(format: "selftest: seriesSmokeProbe OK (one video, %@, %.1fs, %d shots; timing "
                     + "invariants hold; manifest +1; series-tldr/concerns/scares.png written)",
                     seriesVideoID, built.duration, built.shotCount))
    }

    // MARK: - traceVideoChaptersProbe

    static func traceVideoChaptersProbe(_ ctx: OnboardingProbeContext) async throws {
        let root = SelfTest.seriesPackageURL(ctx)
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw StudioError("traceVideoChaptersProbe: run seriesSmokeProbe first — \(root.path) is not there")
        }
        let store = try PackageStore(root: root)
        let folder = "videos/\(seriesVideoID)"
        let packet = try PacketReader.load(store.url("packet"))
        guard let trace = packet.traces[seriesTraceID] else {
            throw StudioError("traceVideoChaptersProbe: the packet has no \(seriesTraceID) trace")
        }
        let script = try store.readJSON(VideoScript.self, from: "\(folder)/\(VideoScript.fileName)")
        let transcript = try OnboardingJSON.decoder().decode(
            TranscriptDoc.self, from: try store.readData("\(folder)/\(TranscriptDoc.fileName)"))
        let coderefs = try OnboardingJSON.decoder().decode(
            CodeRefMap.self, from: try store.readData("\(folder)/\(CodeRefMap.fileName)"))

        // 1. The chapters are the scenes, and the hop chapters are the hop list, in order.
        guard transcript.chapters.map({ $0.id }) == script.scenes.map({ $0.id }) else {
            throw StudioError("traceVideoChaptersProbe: chapters \(transcript.chapters.map { $0.id }) are not the "
                              + "scenes \(script.scenes.map { $0.id })")
        }
        let hopChapters = script.scenes.compactMap { scene in scene.traceHop.map { (scene.id, $0) } }
        guard hopChapters.map({ $0.1 }) == trace.hops.map({ $0.n }),
              hopChapters.map({ $0.0 }) == trace.hops.map({ TraceScript.hopSceneID($0.n) }) else {
            throw StudioError("traceVideoChaptersProbe: hop chapters \(hopChapters) are not hops "
                              + "\(trace.hops.map { $0.n })")
        }
        // Framing chapters: only the tldr, before the hops, at smoke scope.
        let framing = script.scenes.filter { $0.traceHop == nil }.map { $0.id }
        guard framing == ["s01"] else {
            throw StudioError("traceVideoChaptersProbe: framing chapters \(framing), expected only the tldr")
        }

        // 2. Each hop chapter's interval names the hop's anchor and its trace anchor, and
        //    bands the hop's lines.
        for hop in trace.hops {
            let sceneID = TraceScript.hopSceneID(hop.n)
            let intervals = coderefs.intervals.filter { $0.sceneId == sceneID }
            guard let chapter = transcript.chapters.first(where: { $0.id == sceneID }),
                  chapter.end > chapter.start, !intervals.isEmpty else {
                throw StudioError("traceVideoChaptersProbe: hop \(hop.n) has no chapter or no interval")
            }
            for interval in intervals {
                guard interval.anchors.contains(hop.anchor),
                      interval.anchors.contains("trace:\(seriesTraceID)#hop\(hop.n)"),
                      interval.highlight?.anchor == hop.anchor, interval.sceneType == "code" else {
                    throw StudioError("traceVideoChaptersProbe: hop \(hop.n)'s interval names \(interval.anchors) "
                                      + "highlighting \(interval.highlight?.anchor ?? "nothing"); expected \(hop.anchor)")
                }
                guard interval.start >= chapter.start - 0.001, interval.end <= chapter.end + 0.001 else {
                    throw StudioError("traceVideoChaptersProbe: hop \(hop.n)'s interval lies outside its chapter")
                }
            }
        }

        // 3. The chapter track carries every hop, so a player's chapter menu lists them.
        let vtt = try store.readString("\(folder)/chapters.vtt")
        for scene in script.scenes where scene.traceHop != nil && !vtt.contains(scene.title) {
            throw StudioError("traceVideoChaptersProbe: chapters.vtt has no cue for \(scene.title)")
        }

        print("selftest: traceVideoChaptersProbe OK (\(trace.hops.count) hop chapters equal the hop list; "
              + "each interval names its hop anchor and bands its lines)")
    }

    // MARK: - regenerateOneProbe

    static func regenerateOneProbe(_ ctx: OnboardingProbeContext) async throws {
        let root = SelfTest.seriesPackageURL(ctx)
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw StudioError("regenerateOneProbe: run seriesSmokeProbe first — \(root.path) is not there")
        }
        let store = try PackageStore(root: root)
        let folder = "videos/\(seriesVideoID)"
        let otherFolder = "videos/\(FixturePackage.videoID)"
        let runner = SeriesRunner(store: store, repo: ctx.fixtureRepo, narrator: ToneNarrator(),
                                  options: SelfTest.seriesOptions())

        let othersBefore = SelfTest.modificationDates(store, otherFolder)
        let traceBefore = SelfTest.modificationDates(store, folder)
        let manifestBefore = try store.readManifest()
        guard !othersBefore.isEmpty, traceBefore["/video.mp4"] != nil else {
            throw StudioError("regenerateOneProbe: the series package has no videos to compare")
        }
        let original = try store.readJSON(VideoScript.self, from: "\(folder)/\(VideoScript.fileName)")
        guard let h03 = original.scenes.firstIndex(where: { $0.id == "h03" }) else {
            throw StudioError("regenerateOneProbe: the trace script has no h03 scene to edit")
        }

        // 1. An edit that breaks the script is refused before anything is written.
        var broken = original
        broken.scenes[h03].shots[0].anchors.append("code:src/nowhere.py@\(original.sha)#L1-L2")
        try store.writeJSON(broken, to: "\(folder)/\(VideoScript.fileName)")
        do {
            _ = try await runner.regenerate(videoId: seriesVideoID)
            throw StudioError("regenerateOneProbe: a script with a dangling anchor was regenerated")
        } catch let error as StudioError where !error.message.hasPrefix("regenerateOneProbe") {
            // Expected.
        }
        let afterRefusal = SelfTest.modificationDates(store, folder).filter { $0.key != "/script.json" }
        guard afterRefusal == traceBefore.filter({ $0.key != "/script.json" }) else {
            throw StudioError("regenerateOneProbe: a refused regenerate still wrote files")
        }

        // 2. One edited sentence: one shot re-narrated, the rest reused.
        var edited = original
        let newLine = "OrderService builds its own repository, so nothing can be swapped in for a test."
        edited.scenes[h03].shots[0].narration = newLine
        try store.writeJSON(edited, to: "\(folder)/\(VideoScript.fileName)")
        let built = try await runner.regenerate(videoId: seriesVideoID)
        guard built.shotCount == original.shots.count, built.reusedClips == built.shotCount - 1 else {
            throw StudioError("regenerateOneProbe: \(built.reusedClips) of \(built.shotCount) clips were reused; "
                              + "an edit to one shot should re-narrate one")
        }
        guard built.transcript.segments.contains(where: { $0.text.contains("swapped in for a test") }) else {
            throw StudioError("regenerateOneProbe: the regenerated transcript does not carry the edited line")
        }
        try SelfTest.assertTimingInvariants(transcript: built.transcript, coderefs: built.coderefs)
        let traceAfter = SelfTest.modificationDates(store, folder)
        guard let mp4Before = traceBefore["/video.mp4"], let mp4After = traceAfter["/video.mp4"], mp4After > mp4Before else {
            throw StudioError("regenerateOneProbe: the regenerated video's mp4 was not rewritten")
        }

        // 3. Every other video's files are exactly as they were.
        let othersAfter = SelfTest.modificationDates(store, otherFolder)
        guard othersAfter == othersBefore else {
            let changed = othersAfter.filter { othersBefore[$0.key] != $0.value }.keys.sorted()
            throw StudioError("regenerateOneProbe: regenerating \(seriesVideoID) touched \(otherFolder): "
                              + changed.prefix(5).joined(separator: ", "))
        }

        // 4. And so is every other manifest entry; this one's inputs hash moved.
        let manifestAfter = try store.readManifest()
        let id = "video:\(seriesVideoID)"
        guard manifestAfter.deliverables.filter({ $0.id != id }) == manifestBefore.deliverables.filter({ $0.id != id }),
              let before = manifestBefore.deliverables.first(where: { $0.id == id }),
              let after = manifestAfter.deliverables.first(where: { $0.id == id }),
              after.inputsHash != before.inputsHash, after.order == before.order else {
            throw StudioError("regenerateOneProbe: the manifest changed beyond this video's own entry")
        }

        print("selftest: regenerateOneProbe OK (a broken edit refused with nothing written; one edited "
              + "sentence re-narrated \(built.shotCount - built.reusedClips) of \(built.shotCount) shots; "
              + "\(othersBefore.count) files of \(FixturePackage.videoID) and every other manifest entry untouched)")
    }
}
