import Foundation

/// Mermaid diagrams projected from a validated Research Packet, plus the `.links.json`
/// sidecar that makes every node clickable. Mirrors `diagram_*` in
/// `project_packet.py`; `projectorParityProbe` diffs the output against the golden
/// projection.
///
/// The `.mmd` files carry no theme directive on purpose: they stay portable, so a user
/// can paste one into any Mermaid tool, and the brand tokens come from BrandTheme at
/// render time. A theme directive inside the file made Mermaid mark the element
/// processed and emit no SVG at all.
enum DiagramProjector {

    struct Diagram {
        let id: String
        let mermaid: String
        /// Node ids in the order the builder emitted them. `HubProjector` walks the
        /// backlink index in this order so the result is the same on every run.
        let nodeOrder: [String]
        let links: [String: Any]     // the .links.json sidecar
    }

    static func all(for packet: ResearchPacket) -> [Diagram] {
        [c4Context(packet), c4Container(packet), erd(packet), deployment(packet)]
    }

    // MARK: - edges from evidence

    /// File-to-file edges taken from consecutive hops of every trace. Hop sequences are
    /// recorded call evidence, unlike the optional `imports` attribute that most
    /// producers leave empty.
    ///
    /// A trace walks down into callees and back out again, so consecutive pairs contain
    /// return hops too; drawing those gives arrows that point backwards (repo -> handler).
    /// A caller is always seen before its callee, so an edge is kept only when it runs
    /// from an earlier first appearance to a later one.
    static func traceEdges(_ packet: ResearchPacket) -> [Edge: Set<String>] {
        var edges: [Edge: Set<String>] = [:]
        for pathID in packet.traces.keys.sorted() {
            guard let trace = packet.traces[pathID] else { continue }
            var first: [String: Int] = [:]
            for hop in trace.hops {
                if let path = ProjectionSupport.codePath(hop.anchor), first[path] == nil {
                    first[path] = hop.n
                }
            }
            for (a, b) in zip(trace.hops, trace.hops.dropFirst()) {
                guard let pa = ProjectionSupport.codePath(a.anchor),
                      let pb = ProjectionSupport.codePath(b.anchor),
                      pa != pb,
                      (first[pa] ?? 0) < (first[pb] ?? 0) else { continue }
                edges[Edge(from: pa, to: pb), default: []].insert(pathID)
            }
        }
        return edges
    }

    struct Edge: Hashable {
        let from: String
        let to: String
    }

    // MARK: - C4 context

    static func c4Context(_ packet: ResearchPacket) -> Diagram {
        let name = packet.manifest.repo.name ?? "system"
        var lines = ["graph LR", "  system[\"\(ProjectionSupport.mermaidLabel(name))\"]"]
        var nodes = OrderedJSONObject()
        var edges: [String: Any] = [:]
        nodes["system"] = [
            "anchor": "code:./@\(packet.sha7)",
            "owner": NSNull(),
            "factIds": Array(packet.usableFacts(kind: "component").prefix(8).map { $0.id }),
        ]
        var seen = Set<String>()
        for fact in packet.usableFacts(kind: "integration") {
            let label = (fact.attributes["target"]?.stringValue) ?? fact.subject
            let nid = ProjectionSupport.mermaidID("ext_" + label)
            guard !seen.contains(nid) else { continue }
            seen.insert(nid)
            let proto = fact.attributes["protocol"]?.stringValue
                ?? fact.attributes["transport"]?.stringValue ?? "calls"
            lines.append("  \(nid)[\"\(ProjectionSupport.mermaidLabel(label))\"]")
            lines.append("  system -->|\"\(ProjectionSupport.mermaidLabel(proto))\"| \(nid)")
            let anchor = packet.primaryAnchor(fact)
            nodes[nid] = ["anchor": anchor ?? NSNull(), "owner": NSNull(), "factIds": [fact.id]]
            edges["system->\(nid)"] = ["protocol": proto, "contract": anchor ?? NSNull(), "factIds": [fact.id]]
        }
        lines.append("  classDef sys fill:#DA4F45,stroke:#1A1612,color:#FFFBF5;")
        lines.append("  class system sys;")
        return Diagram(
            id: "c4-context",
            mermaid: lines.joined(separator: "\n") + "\n",
            nodeOrder: nodes.keys,
            links: ["version": 1, "diagramId": "c4-context", "nodes": nodes.object, "edges": edges])
    }

    // MARK: - C4 container

    static func c4Container(_ packet: ResearchPacket) -> Diagram {
        var lines = ["graph TD"]
        var nodes = OrderedJSONObject()
        var linkEdges: [String: Any] = [:]
        var owners: [String: PacketHistory.Ownership] = [:]
        for o in packet.history.ownership { owners[o.dir] = o }
        let dirs = packet.inventory.topLevel.filter { !$0.generated }
        let dirPaths = Set(dirs.map { $0.path })

        var factsByDir: [String: [String]] = [:]
        for fact in packet.usableFacts() {
            for anchor in packet.anchors(of: fact) {
                if let path = ProjectionSupport.codePath(anchor) {
                    factsByDir[ProjectionSupport.topDir(path), default: []].append(fact.id)
                }
            }
        }

        /// src/api/orders_handler.py -> src/api/ ; db/schema.sql -> db/ ; README.md -> .
        func containerOf(_ path: String) -> String {
            let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if parts.count >= 3, dirPaths.contains(parts[0] + "/") {
                return parts[0] + "/" + parts[1] + "/"
            }
            return ProjectionSupport.topDir(path)
        }

        struct ContainerMeta {
            var files: Int?
            var parent: String?
        }
        var containers: [String: ContainerMeta] = [:]
        for d in dirs { containers[d.path] = ContainerMeta(files: d.files, parent: nil) }
        let edges = traceEdges(packet)
        for edge in edges.keys {
            for path in [edge.from, edge.to] {
                let c = containerOf(path)
                if containers[c] == nil {
                    containers[c] = ContainerMeta(files: nil, parent: ProjectionSupport.topDir(path))
                }
            }
        }

        // A parent that is itself an edge endpoint (db/ holds schema.sql) cannot become a
        // bare subgraph, or the edge points at a group id and Mermaid invents a phantom node.
        var endpoints = Set<String>()
        for edge in edges.keys {
            endpoints.insert(containerOf(edge.from))
            endpoints.insert(containerOf(edge.to))
        }
        var children: [String: [String]] = [:]
        for (c, meta) in containers {
            guard let parent = meta.parent, dirPaths.contains(parent), parent != c,
                  !endpoints.contains(parent) else { continue }
            children[parent, default: []].append(c)
        }
        children = children.filter { $0.value.count > 1 }   // one child in a box is noise

        func nodeLine(_ path: String, indent: String) -> String {
            let nid = ProjectionSupport.mermaidID("d_" + path)
            let own = owners[path] ?? owners[ProjectionSupport.topDir(path)]
            var bits = [ProjectionSupport.mermaidLabel(path)]
            if let files = containers[path]?.files { bits.append("\(files) files") }
            if let author = own?.authors.first {
                bits.append("\(ProjectionSupport.mermaidLabel(author.name)) \(Int((author.share * 100).rounded()))%")
            }
            nodes[nid] = [
                "anchor": path == "." ? "code:./@\(packet.sha7)" : "code:\(path)@\(packet.sha7)",
                "owner": own?.authors.first?.name ?? NSNull(),
                "factIds": Array((factsByDir[path] ?? factsByDir[ProjectionSupport.topDir(path)] ?? []).prefix(8)),
            ]
            return "\(indent)\(nid)[\"\(bits.joined(separator: "<br/>"))\"]"
        }

        var emitted = Set<String>()
        for parent in children.keys.sorted() {
            let gid = ProjectionSupport.mermaidID("g_" + parent)
            // A subgraph label must stay one short line; multi-line labels collide with children.
            lines.append("  subgraph \(gid)[\"\(ProjectionSupport.mermaidLabel(parent))\"]")
            for child in children[parent]!.sorted() {
                lines.append(nodeLine(child, indent: "    "))
                emitted.insert(child)
            }
            lines.append("  end")
            emitted.insert(parent)
        }
        for path in containers.keys.sorted() where !emitted.contains(path) && children[path] == nil {
            lines.append(nodeLine(path, indent: "  "))
            emitted.insert(path)
        }

        var drawn = Set<Edge>()
        for edge in edges.keys.sorted(by: { ($0.from, $0.to) < ($1.from, $1.to) }) {
            let traces = edges[edge]!
            let ca = containerOf(edge.from), cb = containerOf(edge.to)
            guard ca != cb else { continue }
            let src = ProjectionSupport.mermaidID("d_" + ca)
            let dst = ProjectionSupport.mermaidID("d_" + cb)
            let key = Edge(from: src, to: dst)
            guard !drawn.contains(key), nodes[src] != nil, nodes[dst] != nil else { continue }
            drawn.insert(key)
            let label = traces.count == 1 ? traces.sorted()[0] : "\(traces.count) paths"
            lines.append("  \(src) -->|\"\(ProjectionSupport.mermaidLabel(label))\"| \(dst)")
            linkEdges["\(src)->\(dst)"] = [
                "protocol": "call",
                "contract": "code:\(edge.to)@\(packet.sha7)",
                "factIds": [String](),
                "traces": traces.sorted(),
            ]
        }
        if drawn.isEmpty {
            lines.append("  %% no trace crossed a container boundary, so no call edges are drawn")
        }

        let hotPaths = packet.history.hotspots.prefix(3).map { $0.path }
        let hotNodes = Set(hotPaths.map { ProjectionSupport.mermaidID("d_" + containerOf($0)) })
            .intersection(Set(nodes.keys)).sorted()
        lines.append("  classDef hot stroke:#DA4F45,stroke-width:3px;")
        if !hotNodes.isEmpty { lines.append("  class " + hotNodes.joined(separator: ",") + " hot;") }

        return Diagram(
            id: "c4-container",
            mermaid: lines.joined(separator: "\n") + "\n",
            nodeOrder: nodes.keys,
            links: ["version": 1, "diagramId": "c4-container", "nodes": nodes.object, "edges": linkEdges])
    }

    // MARK: - ERD

    static func erd(_ packet: ResearchPacket) -> Diagram {
        var lines = ["erDiagram"]
        var nodes = OrderedJSONObject()
        var edges: [String: Any] = [:]
        let entities = packet.usableFacts(kind: "dataEntity").filter {
            !($0.attributes["columns"]?.arrayValue?.isEmpty ?? true)
        }
        let fields = packet.usableFacts(kind: "dataField")

        for fact in entities {
            let table = String(fact.subject.split(separator: " ").last ?? "").split(separator: ".").last.map(String.init)
                ?? fact.subject
            let nid = ProjectionSupport.mermaidID(table).uppercased()
            let columns = fact.attributes["columns"]?.arrayValue ?? []
            lines.append("  \(nid) {")
            for column in columns {
                guard let cname = column.stringValue else { continue }
                let field = fields.first { $0.subject.hasSuffix("\(table).\(cname)") }
                let rawType = (field?.attributes["type"]?.stringValue ?? "")
                    .trimmingCharacters(in: .whitespaces)
                // Mermaid ERD types cannot carry parentheses: NUMERIC(10,2) would render as
                // NUMERIC_10_2_. Keep the base type and move the precision into the comment.
                let head = String(rawType.prefix(while: { $0 != "(" }))
                let base = head.filter { $0.isLetter || $0.isNumber || $0 == "_" }
                let detail = rawType.count > head.count
                    ? String(rawType.dropFirst(head.count)).trimmingCharacters(in: .whitespaces) : ""
                let isPII = field?.attributes["pii"]?.boolValue == true
                let comment = [isPII ? "PII" : "", detail].filter { !$0.isEmpty }.joined(separator: " ")
                lines.append("    \(base.isEmpty ? "unknown" : base) \(cname) \"\(comment)\"")
            }
            lines.append("  }")
            nodes[nid] = [
                "anchor": packet.primaryAnchor(fact) ?? NSNull(),
                "owner": NSNull(),
                "factIds": [fact.id] + fields.filter { $0.subject.contains("\(table).") }.map { $0.id },
                "attributes": [
                    "rows": fact.attributes["rows"]?.jsonObject ?? "unknown",
                    "retention": fact.attributes["retention"]?.jsonObject ?? "unknown",
                    "pii": fact.attributes["pii"]?.jsonObject ?? "unknown",
                    "piiNote": fact.attributes["piiNote"]?.jsonObject ?? NSNull(),
                ],
            ]
        }

        for fact in entities {
            let table = String(fact.subject.split(separator: " ").last ?? "").split(separator: ".").last.map(String.init)
                ?? fact.subject
            let nid = ProjectionSupport.mermaidID(table).uppercased()
            for fk in fact.attributes["foreignKeys"]?.arrayValue ?? [] {
                guard let raw = fk.stringValue else { continue }
                let cleaned = raw.replacingOccurrences(of: "->", with: " ")
                    .replacingOccurrences(of: "references", with: " ")
                let candidates = cleaned.split(whereSeparator: { " .(".contains($0) }).map(String.init)
                for candidate in candidates {
                    let other = ProjectionSupport.mermaidID(candidate).uppercased()
                    if nodes[other] != nil, other != nid {
                        lines.append("  \(other) ||--o{ \(nid) : has")
                        edges["\(other)->\(nid)"] = [
                            "protocol": "foreign key",
                            "contract": packet.primaryAnchor(fact) ?? NSNull(),
                            "factIds": [fact.id],
                        ]
                        break
                    }
                }
            }
        }
        return Diagram(
            id: "erd",
            mermaid: lines.joined(separator: "\n") + "\n",
            nodeOrder: nodes.keys,
            links: ["version": 1, "diagramId": "erd", "nodes": nodes.object, "edges": edges])
    }

    // MARK: - deployment

    /// How code reaches production. Built from the deploy trace's ordered hops when one
    /// exists; deployStep findings are never chained with arrows, because most of them are
    /// observations ("CI is not a gate") and an arrow between them would assert a sequence
    /// the evidence does not support.
    static func deployment(_ packet: ResearchPacket) -> Diagram {
        var lines = ["graph LR"]
        var nodes = OrderedJSONObject()
        var edges: [String: Any] = [:]
        let deployTrace = packet.traces.keys.sorted().compactMap { packet.traces[$0] }.first {
            $0.pathId.contains("deploy") || $0.title.lowercased().contains("deploy")
        }
        if let trace = deployTrace {
            var previous: String?
            for hop in trace.hops {
                let nid = "h\(hop.n)"
                let path = ProjectionSupport.codePath(hop.anchor) ?? "?"
                let name = (path as NSString).lastPathComponent
                let label = "\(ProjectionSupport.mermaidLabel(name))<br/>"
                    + ProjectionSupport.mermaidLabel(ProjectionSupport.clip(hop.summary, 64))
                lines.append("  \(nid)[\"\(label)\"]")
                nodes[nid] = ["anchor": hop.anchor, "owner": NSNull(), "factIds": hop.factIds ?? []]
                if let previous {
                    lines.append("  \(previous) --> \(nid)")
                    edges["\(previous)->\(nid)"] = [
                        "protocol": "then", "contract": hop.anchor, "factIds": hop.factIds ?? [],
                    ]
                }
                previous = nid
            }
            // Things the deploy path does NOT touch are the finding worth drawing.
            for fact in packet.usableFacts(kind: "deployStep") {
                let claim = fact.claim.lowercased()
                guard claim.contains("ci"), claim.contains("not") || claim.contains("never") else { continue }
                let nid = ProjectionSupport.mermaidID("ci_" + fact.id)
                lines.append("  \(nid)[\"CI<br/>\(ProjectionSupport.mermaidLabel(ProjectionSupport.clip(fact.claim, 60)))\"]")
                lines.append("  \(nid) -.->|\"does not deploy\"| h1")
                nodes[nid] = ["anchor": packet.primaryAnchor(fact) ?? NSNull(), "owner": NSNull(), "factIds": [fact.id]]
                edges["\(nid)->h1"] = [
                    "protocol": "no link", "contract": packet.primaryAnchor(fact) ?? NSNull(), "factIds": [fact.id],
                ]
                lines.append("  classDef gap stroke:#DA4F45,stroke-width:3px,stroke-dasharray:4 3;")
                lines.append("  class \(nid) gap;")
                break
            }
        } else {
            let steps = packet.usableFacts(kind: "deployStep")
            if steps.isEmpty {
                lines.append("  none[\"No deploy steps were found\"]")
                nodes["none"] = ["anchor": NSNull(), "owner": NSNull(), "factIds": [String]()]
            }
            for (index, fact) in steps.prefix(10).enumerated() {
                let nid = "s\(index + 1)"
                lines.append("  \(nid)[\"\(ProjectionSupport.mermaidLabel(ProjectionSupport.clip(fact.claim, 70)))\"]")
                nodes[nid] = ["anchor": packet.primaryAnchor(fact) ?? NSNull(), "owner": NSNull(), "factIds": [fact.id]]
            }
        }
        return Diagram(
            id: "deployment",
            mermaid: lines.joined(separator: "\n") + "\n",
            nodeOrder: nodes.keys,
            links: ["version": 1, "diagramId": "deployment", "nodes": nodes.object, "edges": edges])
    }

    // MARK: - per-trace sequence diagram

    /// A sequence diagram whose participants are the files the hops touch.
    static func traceDiagram(_ trace: PacketTrace) -> String {
        var lines = ["sequenceDiagram", "  autonumber"]
        var participants: [String: String] = [:]
        var order: [String] = []
        for hop in trace.hops {
            let path = ProjectionSupport.codePath(hop.anchor) ?? "?"
            let name = (path as NSString).lastPathComponent
            let pid = ProjectionSupport.mermaidID(name)
            if participants[pid] == nil {
                participants[pid] = path
                order.append(pid)
                lines.append("  participant \(pid) as \(ProjectionSupport.mermaidLabel(name))")
            }
        }
        var previous: String?
        for hop in trace.hops {
            let path = ProjectionSupport.codePath(hop.anchor) ?? "?"
            let pid = ProjectionSupport.mermaidID((path as NSString).lastPathComponent)
            let summary = ProjectionSupport.mermaidLabel(ProjectionSupport.clip(hop.summary, 70))
            if let previous, previous != pid {
                lines.append("  \(previous)->>\(pid): \(summary)")
            } else {
                lines.append("  Note over \(pid): \(summary)")
            }
            previous = pid
        }
        for key in PacketTrace.concernKeys {
            guard trace.concerns[key]?.status == "absent" else { continue }
            let target = order.first ?? "x"
            lines.append("  Note over \(target): MISSING \(ProjectionSupport.mermaidLabel(key))")
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
