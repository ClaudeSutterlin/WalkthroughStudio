import Foundation

/// How much of the series a run produces (ARCHITECTURE "Scope", decided 2026-09-19:
/// scope is what to produce, not a cap on how hard to look).
enum SeriesScope: String, Codable, CaseIterable, Sendable {
    /// One trace video of at most 60 s: what the selftest and a first look render.
    case smoke
    /// The overview and the top three traces.
    case preview
    /// The ten series videos, a trace video per traced path, a confessional per subsystem.
    case complete
}

/// One video the series will contain, and where its script comes from.
struct SeriesItem: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// Written from the packet's trace (`TraceScript`), no model.
        case trace(pathId: String, cut: TraceScript.Cut)
        /// Written from the subsystem's landmine and risk facts, no model.
        case confessional(subsystem: String)
        /// Written by the script planner unit.
        case planned
    }

    var videoId: String
    var title: String
    /// One of `VideoScript.kinds`.
    var kind: String
    var source: Source
    var budgetSeconds: Double
    /// What a planner aims for, inside the budget.
    var targetSeconds: Double
}

/// The video list for a scope, the two deterministic script kinds, and the loop that
/// brings an over-budget script under its budget.
enum SeriesPlanner {

    /// ON-6.1's ten, in viewing order, with the id each gets under `videos/`.
    static let series: [(kind: String, id: String, title: String)] = [
        ("overview", "overview", "Architecture overview"),
        ("domain", "domain", "The domain model"),
        ("codeTour", "code-tour", "A tour of the code"),
        ("devEnv", "dev-env", "From clone to green tests"),
        ("deploy", "deploy", "Deploy and rollback"),
        ("data", "data", "The data layer"),
        ("observability", "observability", "Observability"),
        ("security", "security", "Security"),
        ("integrations", "integrations", "Integrations"),
        ("migrations", "migrations", "Half-finished migrations"),
    ]

    static let smokeBudgetSeconds: Double = 60
    static let videoBudgetSeconds: Double = 900
    /// Fact kinds a confessional is made of: what is fragile, and what could go wrong.
    static let confessionalKinds: Set<String> = ["landmine", "risk"]
    /// Below this many facts a subsystem's fragility fits in the other videos.
    static let confessionalMinimumFacts = 2
    static let confessionalMaximumFacts = 8

    // MARK: - The list

    static func plan(packet: ResearchPacket, scope: SeriesScope) -> [SeriesItem] {
        let traced = packet.paths.paths
            .filter { $0.isTraced && packet.traces[$0.id] != nil }
            .sorted { $0.rank < $1.rank }

        func traceItem(_ path: PacketPaths.CriticalPath, cut: TraceScript.Cut,
                       budget: Double) -> SeriesItem {
            SeriesItem(videoId: TraceScript.videoID(pathId: path.id),
                       title: "Critical path: " + TraceScript.shortTitle(path.title),
                       kind: "trace", source: .trace(pathId: path.id, cut: cut),
                       budgetSeconds: budget, targetSeconds: budget)
        }
        func plannedItem(_ entry: (kind: String, id: String, title: String)) -> SeriesItem {
            SeriesItem(videoId: entry.id, title: entry.title, kind: entry.kind, source: .planned,
                       budgetSeconds: videoBudgetSeconds, targetSeconds: 600)
        }

        switch scope {
        case .smoke:
            guard let first = traced.first else { return [] }
            return [traceItem(first, cut: .hops, budget: smokeBudgetSeconds)]
        case .preview:
            return [plannedItem(series[0])]
                + traced.prefix(3).map { traceItem($0, cut: .full, budget: videoBudgetSeconds) }
        case .complete:
            var items = series.map { plannedItem($0) }
            items += traced.map { traceItem($0, cut: .full, budget: videoBudgetSeconds) }
            for subsystem in subsystems(packet) {
                items.append(SeriesItem(
                    videoId: confessionalID(subsystem.dir),
                    title: "What only the code knows: \(subsystem.dir)",
                    kind: "confessional", source: .confessional(subsystem: subsystem.dir),
                    budgetSeconds: videoBudgetSeconds, targetSeconds: 300))
            }
            return items
        }
    }

    // MARK: - Confessionals (ON-6.5)

    /// Top-level directories with enough usable landmine and risk facts to fill a
    /// confessional, in inventory order. A fact belongs to the directory of its first
    /// `code:` evidence; generated directories and the root are not subsystems.
    static func subsystems(_ packet: ResearchPacket) -> [(dir: String, facts: [PacketFact])] {
        var byDir: [String: [PacketFact]] = [:]
        for fact in packet.usableFacts where confessionalKinds.contains(fact.kind) {
            guard let path = codeEvidence(fact).flatMap({ ProjectionSupport.codePath($0) }),
                  let dir = topLevelDir(path) else { continue }
            byDir[dir, default: []].append(fact)
        }
        let generated = Set(packet.inventory.topLevel.filter { $0.generated }.map { $0.path })
        var order = packet.inventory.topLevelPaths.filter { $0 != "." && !generated.contains($0) }
        for dir in byDir.keys.sorted() where !order.contains(dir) && !generated.contains(dir) {
            order.append(dir)
        }
        return order.compactMap { dir in
            guard let facts = byDir[dir], facts.count >= confessionalMinimumFacts else { return nil }
            return (dir: dir, facts: facts)
        }
    }

    static func confessionalID(_ dir: String) -> String {
        let slug = dir.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(slug).split(separator: "-").joined(separator: "-")
        return "confessional-" + (collapsed.isEmpty ? "root" : collapsed)
    }

    /// `src/api/x.py` → `src/`. A file at the root has no subsystem.
    static func topLevelDir(_ path: String) -> String? {
        let parts = path.split(separator: "/")
        guard parts.count > 1 else { return nil }
        return String(parts[0]) + "/"
    }

    static func codeEvidence(_ fact: PacketFact) -> String? {
        fact.evidence.first { $0.anchor.hasPrefix("code:") }?.anchor
    }

    /// A tldr card, one code scene per fact (landmines first), and the card that says
    /// what to read before changing anything here. Every claim is a usable fact's own
    /// claim, at its own evidence.
    static func confessionalScript(subsystem dir: String, facts: [PacketFact], packet: ResearchPacket,
                                   source: PinnedSource) async -> VideoScript {
        let ranked = facts.filter { $0.kind == "landmine" } + facts.filter { $0.kind != "landmine" }
        let chosen = Array(ranked.prefix(confessionalMaximumFacts))
        var scenes: [VideoScript.Scene] = []

        let count = TraceScript.spelled(chosen.count)
        scenes.append(VideoScript.Scene(
            id: "s01", title: "TL;DR", variant: "tldr",
            shots: [VideoScript.Shot(
                id: "s01a", sceneType: "card",
                narration: "What only the code knows about \(dir): \(count) things that are fragile, "
                    + "each shown at the line that proves it.",
                factIds: chosen.prefix(3).map { $0.id },
                caption: "What only the code knows: \(dir)",
                bullets: chosen.prefix(4).map {
                    NarrationFit.capped(NarrationFit.firstClause($0.claim, minWords: 5), words: 12)
                })]))

        for (index, fact) in chosen.enumerated() {
            guard let anchor = codeEvidence(fact) else { continue }
            let path = ProjectionSupport.codePath(anchor) ?? ""
            // Not a ternary: `await` cannot sit to the right of `?:`.
            var lines: [String]? = nil
            if !path.isEmpty { lines = await source.lines(of: path) }
            let sceneID = String(format: "c%02d", index + 1)
            let narration = NarrationFit.sentences(fact.claim).prefix(2).joined(separator: " ")
            let subject = NarrationFit.capped(fact.subject, words: 6)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            scenes.append(VideoScript.Scene(
                id: sceneID, title: subject.isEmpty ? TraceScript.fileName(path) : subject,
                shots: [VideoScript.Shot(
                    id: "\(sceneID)a", sceneType: "code",
                    narration: NarrationFit.terminated(narration),
                    anchors: [anchor, "fact:\(fact.id)"],
                    highlight: CodeRefHighlight(anchor: anchor, callout: fact.kind == "landmine"
                                                ? "landmine" : "risk"),
                    visibleLines: TraceScript.window(for: anchor, totalLines: lines?.count),
                    factIds: [fact.id],
                    caption: TraceScript.fileName(path))]))
        }

        let subjects = chosen.prefix(3).map {
            NarrationFit.capped($0.subject, words: 5).trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        scenes.append(VideoScript.Scene(
            id: "scares", title: "What scares me", variant: "confessional",
            shots: [VideoScript.Shot(
                id: "scaresa", sceneType: "card",
                narration: "None of this is written down anywhere but the code. Before you change "
                    + "anything in \(dir), read \(TraceScript.listed(subjects)) first.",
                caption: "What scares me")]))

        return VideoScript(
            id: confessionalID(dir), title: "What only the code knows: \(dir)",
            summary: "The fragile parts of \(dir), from the research facts the verifiers let stand: "
                + "\(count) landmines and risks, each at its evidence.",
            sha: packet.sha7, kind: "confessional", targetSeconds: 300, scenes: scenes)
    }

    // MARK: - The tighten loop

    struct Tightened {
        var script: VideoScript
        /// What was cut, in order, for the build log.
        var steps: [String]
        var estimatedSeconds: Double
        var fits: Bool
    }

    /// Brings a script under `budget` one step at a time: the longest line loses its
    /// tail first (sentence, then clause, then words), and only when no line can lose
    /// anything more does a `droppable` scene go, last first.
    ///
    /// Cards are held for `cardMinSeconds` by raising their pad rather than padding
    /// their words, and that hold counts toward the budget — a script that fits only
    /// because its cards flash past does not fit. The tldr is shortened first whenever
    /// it is over its own 30 s, whatever the total.
    static func tighten(_ script: VideoScript, budget: Double,
                        narrator: ToneNarrator = ToneNarrator(),
                        rules: ScriptValidator.Rules = .series(facts: nil),
                        droppable: Set<String> = []) -> Tightened {
        var script = script
        var steps: [String] = []
        let cardMinimum = rules.cardMinSeconds ?? 0

        func holdCards() {
            for s in script.scenes.indices {
                for k in script.scenes[s].shots.indices where script.scenes[s].shots[k].sceneType == "card" {
                    let spoken = narrator.estimatedDuration(of: script.scenes[s].shots[k].narration)
                    let pad = script.scenes[s].shots[k].pad
                    script.scenes[s].shots[k].pad = max(pad, cardMinimum - spoken)
                }
            }
        }
        func estimate() -> Double {
            script.shots.reduce(0) { $0 + narrator.estimatedDuration(of: $1.shot.narration) + max(0, $1.shot.pad) }
        }
        func shorten(scene s: Int, shot k: Int) -> Bool {
            let old = script.scenes[s].shots[k].narration
            guard let new = NarrationFit.shorter(old) else { return false }
            script.scenes[s].shots[k].narration = new
            steps.append("\(script.scenes[s].shots[k].id): \(NarrationFit.words(old)) → "
                         + "\(NarrationFit.words(new)) words")
            return true
        }

        for _ in 0..<500 {
            holdCards()
            if rules.requireTLDR, !script.scenes.isEmpty, !script.scenes[0].shots.isEmpty,
               narrator.estimatedDuration(of: script.scenes[0].shots[0].narration) > rules.tldrMaxSeconds,
               shorten(scene: 0, shot: 0) {
                continue
            }
            if estimate() <= budget { break }

            // The longest line that can still lose something.
            var candidates: [(s: Int, k: Int, seconds: Double)] = []
            for s in script.scenes.indices {
                for k in script.scenes[s].shots.indices {
                    candidates.append((s, k, narrator.estimatedDuration(of: script.scenes[s].shots[k].narration)))
                }
            }
            candidates.sort { $0.seconds > $1.seconds }
            if candidates.contains(where: { shorten(scene: $0.s, shot: $0.k) }) { continue }

            guard let drop = script.scenes.lastIndex(where: { droppable.contains($0.id) }) else { break }
            steps.append("dropped scene \(script.scenes[drop].id)")
            script.scenes.remove(at: drop)
        }
        holdCards()
        let seconds = estimate()
        return Tightened(script: script, steps: steps, estimatedSeconds: seconds, fits: seconds <= budget)
    }
}
