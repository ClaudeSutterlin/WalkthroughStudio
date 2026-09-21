import Foundation

/// `hub/index.json` — the recommended reading order with minutes and a coverage
/// summary — and `index/anchors.json`, the backlink index that lets the code view
/// answer "where is this file covered?".
///
/// Mirrors `build_hub` and `build_backlinks` in `project_packet.py`.
enum HubProjector {

    /// Registers that earn a place in the reading order, after the architecture
    /// narrative (which is always first) and the diagrams and traces. `coverage-report`
    /// is produced but deliberately left out: it is a status page about the research,
    /// not something to read on the way in.
    static let hubRegisterOrder = [
        "ownership", "adrs", "dependencies", "tech-debt", "test-truth", "data-inventory",
        "security-posture", "observability", "incident-patterns", "glossary", "landmines",
        "operational-scorecard",
    ]

    static let hubDiagramOrder = ["c4-context", "c4-container", "erd", "deployment"]

    // MARK: - hub/index.json

    static func index(packet: ResearchPacket,
                      registers: [RegisterProjector.Register],
                      diagrams: [DiagramProjector.Diagram]) -> [String: Any] {
        var items: [[String: Any]] = []
        var order = 1
        items.append([
            "id": "doc:architecture", "kind": "doc",
            "title": "Start here: architecture narrative",
            "path": "docs/architecture.md", "minutes": 4, "order": order,
        ])

        let diagramIDs = Set(diagrams.map { $0.id })
        for did in hubDiagramOrder where diagramIDs.contains(did) {
            order += 1
            items.append([
                "id": "diagram:\(did)", "kind": "diagram",
                "title": did.replacingOccurrences(of: "-", with: " "),
                "path": "diagrams/\(did).mmd", "minutes": 2, "order": order,
            ])
        }

        for pathID in packet.traces.keys.sorted() {
            guard let trace = packet.traces[pathID] else { continue }
            order += 1
            items.append([
                "id": "trace:\(pathID)", "kind": "trace", "title": trace.title,
                "path": "traces/\(pathID).md", "minutes": 5, "order": order,
            ])
        }

        var byID: [String: RegisterProjector.Register] = [:]
        for register in registers { byID[register.id] = register }
        for did in hubRegisterOrder {
            guard let register = byID[did] else { continue }
            order += 1
            // The whole document, front matter included — what `build_hub` measures.
            let minutes = ProjectionSupport.minutes(
                forWordCount: ProjectionSupport.wordCount(register.markdown))
            items.append([
                "id": "doc:\(did)", "kind": "doc", "title": register.title,
                "path": "docs/\(did).md", "minutes": minutes, "order": order,
            ])
        }

        let raw = rawPacketJSON(packet)
        let totalMinutes = items.reduce(0) { total, item in total + (item["minutes"] as? Int ?? 0) }
        return [
            "version": 1,
            "repo": raw.repo,
            "producer": raw.producer,
            "summary": packet.manifest.summary,
            "totalMinutes": totalMinutes,
            "items": items,
            "coverage": [
                "directories": raw.directories,
                "paths": raw.paths,
                "checks": raw.checks,
                "counts": raw.counts,
            ],
        ]
    }

    // MARK: - index/anchors.json

    /// anchor -> every deliverable that cites it, de-duplicated by reference, in the
    /// order a reader meets them: diagrams, then registers, then traces.
    static func backlinks(packet: ResearchPacket,
                          registers: [RegisterProjector.Register],
                          diagrams: [DiagramProjector.Diagram],
                          traceDocuments: [(pathID: String, markdown: String)]) -> [String: Any] {
        var order: [String] = []
        var index: [String: [[String: String]]] = [:]

        func record(_ anchor: String, _ entry: [String: String]) {
            if index[anchor] == nil {
                index[anchor] = []
                order.append(anchor)
            }
            guard !index[anchor]!.contains(where: { $0["ref"] == entry["ref"] }) else { return }
            index[anchor]!.append(entry)
        }

        for diagram in diagrams {
            guard let nodes = diagram.links["nodes"] as? [String: Any] else { continue }
            for nodeID in diagram.nodeOrder {
                guard let node = nodes[nodeID] as? [String: Any],
                      let anchor = node["anchor"] as? String, !anchor.isEmpty else { continue }
                record(anchor, ["kind": "diagram", "ref": "diagram:\(diagram.id)#\(nodeID)",
                                "label": diagram.id])
            }
        }
        for register in registers {
            for anchor in MarkdownLite.citedAnchors(in: register.markdown, kindPrefix: "code:") {
                record(anchor, ["kind": "doc", "ref": "doc:\(register.id)", "label": register.id])
            }
        }
        for trace in traceDocuments {
            for anchor in MarkdownLite.citedAnchors(in: trace.markdown, kindPrefix: "code:") {
                record(anchor, ["kind": "trace", "ref": "trace:\(trace.pathID)", "label": trace.pathID])
            }
        }

        var out: [String: Any] = [:]
        for anchor in order { out[anchor] = index[anchor]! }
        return out
    }

    // MARK: - pass-through blocks

    /// The hub republishes `packet.json` and `coverage.json` sub-objects verbatim rather
    /// than re-encoding the decoded models, because the packet is the record: a date the
    /// producer wrote as `2025-02-06T10:00:00+00:00` should reach the reader that way,
    /// not reformatted by a round trip through `Date`, and a field a future schema adds
    /// should travel even though this build knows nothing about it.
    ///
    /// A packet assembled in memory has no files to read, so each block falls back to
    /// encoding the model it came from.
    struct RawBlocks {
        var repo: Any
        var producer: Any
        var counts: Any
        var directories: Any
        var paths: Any
        var checks: Any
    }

    static func rawPacketJSON(_ packet: ResearchPacket) -> RawBlocks {
        let manifest = object(at: packet.root.appendingPathComponent(PacketManifest.fileName))
        let coverage = object(at: packet.root.appendingPathComponent(PacketCoverage.fileName))
        return RawBlocks(
            repo: pick(manifest, "repo", else: encoded(packet.manifest.repo)),
            producer: pick(manifest, "producer", else: encoded(packet.manifest.producer)),
            counts: pick(manifest, "counts", else: encoded(packet.manifest.counts)),
            directories: pick(coverage, "directories", else: encoded(packet.coverage.directories)),
            paths: pick(coverage, "paths", else: encoded(packet.coverage.paths)),
            checks: pick(coverage, "checks", else: encoded(packet.coverage.checks)))
    }

    /// One key of a parsed file, or the fallback. Written out rather than as
    /// `object?[key] ?? fallback`: optional chaining on a dictionary subscript yields a
    /// double optional, and `??` would then return the *inner* nil for a file that
    /// parsed but lacks the key — silently publishing null instead of the model.
    private static func pick(_ object: [String: Any]?, _ key: String, else fallback: Any) -> Any {
        guard let object, let value = object[key] else { return fallback }
        return value
    }

    private static func object(at url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parsed
    }

    private static func encoded<T: Encodable>(_ value: T) -> Any {
        guard let data = try? OnboardingJSON.encoder().encode(value),
              let parsed = try? JSONSerialization.jsonObject(with: data) else { return NSNull() }
        return parsed
    }
}
