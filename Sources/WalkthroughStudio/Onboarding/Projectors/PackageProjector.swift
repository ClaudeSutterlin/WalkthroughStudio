import Foundation

/// Turns a validated Research Packet into the onboarding package's deliverables.
/// The Swift half of the contract in `docs/onboarding/PACKET.md`: facts in, files out,
/// no model involved. `project_packet.py` is the reference implementation and
/// `projectorParityProbe` holds this to it.
///
/// Writes, relative to the package root:
///
///     diagrams/<id>.mmd, <id>.links.json      Mermaid source plus the node/edge sidecar
///     docs/<docId>.md, .html                  registers with front matter and heading anchors
///     traces/<pathId>.mmd, .md, .html         sequence diagram and prose per critical path
///     hub/index.json                          recommended order, minutes, coverage summary
///     index/anchors.json                      backlinks: anchor -> the deliverables citing it
///     code/<path>.json, code/index.json       (optional) cited sources at the pinned commit
enum PackageProjector {

    struct Result {
        var diagramIDs: [String] = []
        var registerIDs: [String] = []
        var traceIDs: [String] = []
        var hubItems = 0
        var totalMinutes = 0
        var backlinkedAnchors = 0
        /// Refuted fact ids that reached a deliverable. Always empty — the projectors
        /// only ever read usable facts — and checked anyway, because "a refuted claim
        /// never reaches a reader" is the promise the whole packet contract rests on.
        var refutedLeaks: [String] = []
        /// Facts still awaiting a verdict, which every deliverable held back. A producer
        /// that skipped the verifier pass deserves to be told why its research went
        /// missing rather than to find empty registers.
        var proposedFactCount = 0

        var summaryLine: String {
            "\(diagramIDs.count) diagrams, \(registerIDs.count) registers, \(traceIDs.count) traces, "
            + "\(hubItems) hub items (\(totalMinutes) min), \(backlinkedAnchors) backlinked anchors"
        }
    }

    // MARK: - projection

    static func project(packet: ResearchPacket, into store: PackageStore) throws -> Result {
        var result = Result()

        let diagrams = DiagramProjector.all(for: packet)
        for diagram in diagrams {
            try store.writeAtomically(diagram.mermaid, to: "diagrams/\(diagram.id).mmd")
            try store.writeAtomically(try ProjectionSupport.encodeJSON(diagram.links),
                                      to: "diagrams/\(diagram.id).links.json")
            result.diagramIDs.append(diagram.id)
        }

        let registers = RegisterProjector.all(for: packet)
        for register in registers {
            try store.writeAtomically(register.markdown, to: "docs/\(register.id).md")
            try store.writeAtomically(MarkdownLite.toHTML(register.markdown),
                                      to: "docs/\(register.id).html")
            result.registerIDs.append(register.id)
        }

        var traceDocuments: [(pathID: String, markdown: String)] = []
        for pathID in packet.traces.keys.sorted() {
            guard let trace = packet.traces[pathID] else { continue }
            let markdown = RegisterProjector.traceDocument(trace)
            try store.writeAtomically(markdown, to: "traces/\(pathID).md")
            try store.writeAtomically(MarkdownLite.toHTML(markdown), to: "traces/\(pathID).html")
            try store.writeAtomically(DiagramProjector.traceDiagram(trace),
                                      to: "traces/\(pathID).mmd")
            traceDocuments.append((pathID, markdown))
            result.traceIDs.append(pathID)
        }

        let hub = HubProjector.index(packet: packet, registers: registers, diagrams: diagrams)
        try store.writeAtomically(try ProjectionSupport.encodeJSON(hub), to: "hub/index.json")
        result.hubItems = (hub["items"] as? [[String: Any]])?.count ?? 0
        result.totalMinutes = (hub["totalMinutes"] as? Int) ?? 0

        let backlinks = HubProjector.backlinks(packet: packet, registers: registers,
                                               diagrams: diagrams, traceDocuments: traceDocuments)
        try store.writeAtomically(try ProjectionSupport.encodeJSON(backlinks), to: "index/anchors.json")
        result.backlinkedAnchors = backlinks.count

        let prose = registers.map { $0.markdown } + traceDocuments.map { $0.markdown }
        result.refutedLeaks = packet.facts
            .filter { $0.status == "refuted" }
            .map { $0.id }
            .filter { id in prose.contains { $0.contains(id) } }
        result.proposedFactCount = packet.proposedFacts.count

        return result
    }

    // MARK: - cited sources

    /// Every file any deliverable cites, at the pinned commit, as JSON the hub reads.
    /// The app's code view can call `GitRunner.show` directly, but a package shared as a
    /// folder has no checkout beside it, so the bytes have to travel with it.
    ///
    /// A path git cannot produce is reported, not fatal: a fact may cite a file that a
    /// later commit deleted, and losing every other source over it would be worse.
    struct CodeEmission {
        var written: [String] = []
        var missing: [String] = []
    }

    static func emitCode(packet: ResearchPacket, into store: PackageStore,
                         repo: URL, git: GitRunner = GitRunner()) async throws -> CodeEmission {
        var result = CodeEmission()
        var wanted = Set<String>()
        for fact in packet.usableFacts() {
            for anchor in packet.anchors(of: fact) {
                if let path = ProjectionSupport.codePath(anchor), !path.hasSuffix("/") {
                    wanted.insert(path)
                }
            }
        }
        for trace in packet.traces.values {
            for hop in trace.hops {
                if let path = ProjectionSupport.codePath(hop.anchor), !path.hasSuffix("/") {
                    wanted.insert(path)
                }
            }
        }

        for path in wanted.sorted() {
            let text: String
            do {
                text = try await git.show(sha: packet.headSHA, path: path, repo: repo)
            } catch {
                result.missing.append(path)
                continue
            }
            let payload: [String: Any] = [
                "path": path,
                "sha": packet.sha7,
                "lines": text.components(separatedBy: "\n"),
            ]
            try store.writeAtomically(try ProjectionSupport.encodeJSON(payload),
                                      to: "code/\(path).json")
            result.written.append(path)
        }

        // A container node carries a directory anchor, so the hub needs to know which
        // files travelled with the package in order to show a listing instead of a 404.
        let listing: [String: Any] = ["version": 1, "sha": packet.sha7, "paths": result.written]
        try store.writeAtomically(try ProjectionSupport.encodeJSON(listing), to: "code/index.json")
        return result
    }
}
