import Foundation

/// Plans, writes and renders a series into a package, and regenerates one video of it.
///
/// Three script sources meet here: traces and confessionals are written from the packet
/// with no model (`TraceScript`, `SeriesPlanner.confessionalScript`), the ten series
/// videos by the planner unit. Whatever wrote a script, it is held to the same series
/// rules before it renders, and a deterministic script over its budget goes through the
/// tighten loop once rather than being clamped (ARCHITECTURE risk 6).
///
/// Every video touches only `videos/<id>/` and its own manifest entry, which is what
/// makes ON-6.6 true: regenerating one video leaves every other video's files alone.
@MainActor
final class SeriesRunner {

    struct VideoResult {
        var item: SeriesItem
        var built: VideoAssembler.Built?
        /// What the tighten loop cut, for the build log.
        var tightened: [String] = []
        var notices: [String] = []
    }

    struct Result {
        var videos: [VideoResult] = []
        var notices: [String] = []

        var built: [VideoResult] { videos.filter { $0.built != nil } }
    }

    /// Writes a planned (model-authored) video's script. Nil when no model is set up,
    /// in which case planned videos are skipped with a notice and the rest still render.
    typealias Planner = (SeriesItem) async -> ScriptPlanOutcome

    let store: PackageStore
    let repo: URL?
    let narrator: Narrating
    var options: VideoAssembler.Options
    let git: GitRunner
    let planner: Planner?

    init(store: PackageStore, repo: URL?, narrator: Narrating,
         options: VideoAssembler.Options = VideoAssembler.Options(),
         git: GitRunner = GitRunner(), planner: Planner? = nil) {
        self.store = store
        self.repo = repo
        self.narrator = narrator
        self.options = options
        self.git = git
        self.planner = planner
    }

    // MARK: - The series

    func run(scope: SeriesScope) async throws -> Result {
        let packet = try PacketReader.load(store.url("packet"))
        var result = Result()
        let items = SeriesPlanner.plan(packet: packet, scope: scope)
        if items.isEmpty {
            result.notices.append("No video could be planned at \(scope.rawValue) scope: the packet "
                                  + "has no traced path to walk.")
        }
        for item in items {
            let video = await build(item, packet: packet)
            result.notices.append(contentsOf: video.notices)
            result.videos.append(video)
        }
        return result
    }

    /// One planned item: write its script, hold it to the series rules, render it.
    /// Never throws: a video that cannot be made is a notice, and the series goes on.
    func build(_ item: SeriesItem, packet: ResearchPacket) async -> VideoResult {
        var video = VideoResult(item: item)
        let source = pinnedSource(packet: packet)
        let facts = Dictionary(packet.facts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var rules = ScriptValidator.Rules.series(budgetSeconds: item.budgetSeconds, facts: facts)

        var script: VideoScript
        var droppable: Set<String> = []
        switch item.source {
        case .trace(let pathId, let cut):
            guard let trace = packet.traces[pathId] else {
                video.notices.append("\(item.videoId): the packet has no trace for \(pathId)")
                return video
            }
            script = await TraceScript.make(trace: trace, packet: packet, source: source,
                                            cut: cut, budgetSeconds: item.budgetSeconds)
            rules.traceHops = trace.hops.count
            // The framing scenes go before a hop does: a trace video without its hops
            // is not a trace video.
            droppable = ["scares", "concerns", "map"]
        case .confessional(let dir):
            guard let subsystem = SeriesPlanner.subsystems(packet).first(where: { $0.dir == dir }) else {
                video.notices.append("\(item.videoId): \(dir) has no usable landmine or risk facts left")
                return video
            }
            script = await SeriesPlanner.confessionalScript(subsystem: dir, facts: subsystem.facts,
                                                            packet: packet, source: source)
        case .planned:
            guard let planner else {
                video.notices.append("\(item.videoId): \(item.title) needs the script planner, and no "
                                     + "model is set up; the video was skipped")
                return video
            }
            let planned = await planner(item)
            video.notices.append(contentsOf: planned.notices)
            guard let accepted = planned.script else { return video }
            script = accepted
        }

        // A deterministic script that runs long is tightened once, here, before the
        // validator sees it. A planned one was already held to the budget by
        // emit_script, so it passes through unchanged.
        let tightened = SeriesPlanner.tighten(script, budget: item.budgetSeconds, rules: rules,
                                              droppable: droppable)
        script = tightened.script
        video.tightened = tightened.steps

        let router = LinkRouter(store: store, headSHA: packet.headSHA)
        let report = ScriptValidator.validate(script, router: router, rules: rules)
        guard report.ok else {
            video.notices.append("\(item.videoId): \(ScriptValidator.message(for: report)); the video was "
                                 + "not made")
            return video
        }
        // Warnings come back once, from the assembler, which validates again.

        do {
            var options = self.options
            options.rules = rules
            let built = try await VideoAssembler.build(script: script, into: store, repo: repo,
                                                       narrator: narrator, options: options, git: git)
            video.built = built
            video.notices.append(contentsOf: built.notices.map { "\(item.videoId): \($0)" })
            try recordDeliverable(script: script, built: built,
                                  producedBy: item.source == .planned ? "ScriptPlannerUnit" : "SeriesPlanner")
        } catch {
            let reason = (error as? StudioError)?.message ?? error.localizedDescription
            video.notices.append("\(item.videoId): did not render (\(reason))")
        }
        return video
    }

    // MARK: - Regenerating one video (ON-6.6)

    /// Re-renders `videos/<id>/` from its `script.json`, as edited. Only that folder and
    /// that video's manifest entry change; unchanged shots keep their audio.
    ///
    /// Throws when the edited script does not validate: the author asked for this one
    /// video, so they need the reason, not a notice in a list.
    func regenerate(videoId: String) async throws -> VideoAssembler.Built {
        let path = "videos/\(videoId)/\(VideoScript.fileName)"
        guard store.exists(path) else {
            throw StudioError("There is no script for \(videoId) to regenerate (\(path) is missing).")
        }
        var script = try store.readJSON(VideoScript.self, from: path)
        script.id = videoId

        let facts = VideoAssembler.packetFacts(in: store)
        var rules = ScriptValidator.Rules()
        rules.facts = facts
        if script.kind == "trace", let packet = try? PacketReader.load(store.url("packet")),
           let pathId = script.id.hasPrefix("trace-") ? String(script.id.dropFirst(6)) : nil,
           let trace = packet.traces[pathId] {
            rules.traceHops = trace.hops.count
        }
        var options = self.options
        options.rules = rules
        let built = try await VideoAssembler.build(script: script, into: store, repo: repo,
                                                   narrator: narrator, options: options, git: git)
        try recordDeliverable(script: script, built: built, producedBy: "regenerate")
        return built
    }

    // MARK: - Manifest

    /// Adds or replaces this video's deliverable and leaves every other entry as it was.
    func recordDeliverable(script: VideoScript, built: VideoAssembler.Built, producedBy: String) throws {
        var manifest = try store.readManifest()
        let id = "video:\(script.id)"
        var deliverable = manifest.deliverables.first { $0.id == id }
            ?? OnboardingManifest.Deliverable(id: id, kind: .video)
        deliverable.title = script.title
        deliverable.path = "videos/\(script.id)/video.mp4"
        deliverable.minutes = built.duration / 60
        deliverable.status = .built
        deliverable.producedBy = producedBy
        deliverable.inputsHash = (try? store.sha256(ofFileAt: "videos/\(script.id)/\(VideoScript.fileName)")) ?? ""
        if let index = manifest.deliverables.firstIndex(where: { $0.id == id }) {
            manifest.deliverables[index] = deliverable
        } else {
            deliverable.order = (manifest.deliverables.map { $0.order }.max() ?? 0) + 1
            manifest.deliverables.append(deliverable)
        }
        try store.writeManifest(manifest)
    }

    private func pinnedSource(packet: ResearchPacket) -> PinnedSource {
        var manifest = (try? store.readManifest()) ?? OnboardingManifest()
        if manifest.headSHA.isEmpty { manifest.headSHA = packet.headSHA }
        return PinnedSource.forPackage(store, manifest: manifest, repo: repo)
    }
}
