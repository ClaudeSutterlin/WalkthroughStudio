import Foundation

/// The written registers, projected from a validated Research Packet. Mirrors
/// `build_registers` and `build_trace_docs` in `project_packet.py`; every string here
/// is parity-checked against the golden projection.
///
/// Nothing in this file asks a model anything. A register is a deterministic view of
/// the fact store: refuted facts never appear, unknown ones are hedged, and every
/// claim carries the id of the fact it came from plus the anchor that proves it.
enum RegisterProjector {

    struct Register {
        let id: String
        let title: String
        let order: Int
        let markdown: String
    }

    // MARK: - shared line shapes

    static func cite(_ fact: PacketFact) -> String { "[[fact:\(fact.id)]]" }

    static func registerLines(_ packet: ResearchPacket, _ facts: [PacketFact],
                              limit: Int? = nil, showKind: Bool = false) -> [String] {
        let slice = limit.map { Array(facts.prefix($0)) } ?? facts
        return slice.map { fact in
            let prefix = showKind ? "**\(fact.kind)** " : ""
            let hedge = fact.status == "unknown" ? "Possibly: " : ""
            var line = "- \(prefix)\(hedge)\(fact.claim) \(cite(fact))"
            if let anchor = packet.primaryAnchor(fact) { line += " [[\(anchor)]]" }
            return line
        }
    }

    static func frontMatter(id: String, title: String, order: Int,
                            evidenceUnits: Set<String>, minutes: Int) -> String {
        let units = evidenceUnits.sorted().prefix(12).joined(separator: ", ")
        return """
        ---
        id: \(id)
        title: \(title)
        minutes: \(minutes)
        evidence: [\(units)]
        order: \(order)
        ---


        """
    }

    // MARK: - all registers

    static func all(for packet: ResearchPacket) -> [Register] {
        var out: [Register] = []

        func add(_ id: String, _ title: String, _ order: Int, _ bodyFacts: [PacketFact], _ body: String) {
            let minutes = ProjectionSupport.minutes(forWordCount: ProjectionSupport.wordCount(body))
            let units = Set(bodyFacts.map { $0.producedBy.isEmpty ? "?" : $0.producedBy })
            out.append(Register(id: id, title: title, order: order,
                                markdown: frontMatter(id: id, title: title, order: order,
                                                      evidenceUnits: units, minutes: minutes) + body))
        }

        let joined: ([String]) -> String = { $0.joined(separator: "\n") }

        // architecture narrative
        let comps = packet.usableFacts(kind: "component")
        let ifaces = packet.usableFacts(kind: "interface")
        let eps = packet.usableFacts(kind: "endpoint")
        var body = "# Architecture\n\n\(packet.manifest.summary)\n\n"
        body += "## Containers {code: code:./@\(packet.sha7)}\n\n"
            + joined(registerLines(packet, comps)) + "\n\n"
        let entryLines = joined(registerLines(packet, eps))
        body += "## Entry points\n\n" + (entryLines.isEmpty ? "- None found." : entryLines) + "\n\n"
        body += "## Interfaces\n\n" + joined(registerLines(packet, ifaces, limit: 20)) + "\n"
        add("architecture", "Architecture narrative", 2, comps + ifaces + eps, body)

        // ownership and bus factor
        var rows = ["| Directory | Commits | Top author | Share | Bus factor |", "|---|---|---|---|---|"]
        for o in packet.history.ownership {
            let author = o.authors.first
            let commits = o.commits.map(String.init) ?? "?"
            let share = ProjectionSupport.pyRound((author?.share ?? 0) * 100)
            rows.append("| `\(o.dir)` | \(commits) | \(author?.name ?? "?") | \(share)% | \(o.busFactor) |")
        }
        body = "# Ownership and bus factor\n\n## Per directory\n\n" + joined(rows) + "\n\n"
        body += "## What the history says\n\n"
            + joined(registerLines(packet, packet.usableFacts(kind: "owner")
                                   + packet.usableFacts(kind: "hotspot"))) + "\n"
        add("ownership", "Ownership and bus factor", 4, packet.usableFacts(kind: "owner"), body)

        // architecture decisions
        var parts = ["# Architecture decisions\n"]
        for d in packet.decisions?.decisions ?? [] {
            parts.append("## \(d.title)\n")
            parts.append("**Decision.** \(d.decision)\n")
            if let alternatives = d.alternatives, !alternatives.isEmpty {
                parts.append("**Alternatives.** " + alternatives.joined(separator: "; ") + "\n")
            }
            parts.append("**Consequences.** \(d.consequences)\n")
            if let wouldRepeat = d.wouldRepeat {
                parts.append("**Would repeat.** \(wouldRepeat ? "yes" : "no")\n")
            }
            parts.append("**Evidence.** " + d.evidence.map { "[[\($0)]]" }.joined(separator: " ") + "\n")
        }
        add("adrs", "Architecture decisions", 5, packet.usableFacts(kind: "decision"), joined(parts))

        // dependency register
        rows = ["| Package | Version | License | End of life | Known CVEs |", "|---|---|---|---|---|"]
        for d in packet.dependencies?.dependencies ?? [] {
            let cveText: String
            switch d.cves {
            case .unknown: cveText = "unknown"
            case .list(let list):
                cveText = list.isEmpty ? "none found" : list.map { $0.id }.joined(separator: ", ")
            }
            rows.append("| `\(d.name)` | \(d.version) | \(d.license) | \(d.eol) | \(cveText) |")
        }
        body = "# Dependency register\n\n## Declared dependencies\n\n" + joined(rows) + "\n\n"
        body += "## Findings\n\n" + joined(registerLines(packet, packet.usableFacts(kind: "dependency"))) + "\n"
        add("dependencies", "Dependency register", 6, packet.usableFacts(kind: "dependency"), body)

        // technical debt, ranked by severity then id
        let severityRank = ["critical": 0, "high": 1, "medium": 2, "low": 3]
        let debt = (packet.usableFacts(kind: "risk") + packet.usableFacts(kind: "landmine"))
            .sorted { a, b in
                let ra = severityRank[(a.attributes["severity"]?.stringValue ?? "").lowercased()] ?? 4
                let rb = severityRank[(b.attributes["severity"]?.stringValue ?? "").lowercased()] ?? 4
                return ra == rb ? a.id < b.id : ra < rb
            }
        body = "# Technical debt register\n\n## Ranked by severity\n\n"
            + joined(registerLines(packet, debt, showKind: true)) + "\n"
        add("tech-debt", "Technical debt register", 7, debt, body)

        // test truth
        body = "# Test truth\n\n## What the tests actually cover\n\n"
            + joined(registerLines(packet, packet.usableFacts(kind: "testCoverage"))) + "\n\n"
        let checks = packet.coverage.checks
        if checks.isEmpty {
            body += "## Checks run during research\n\nNo build or test command was executed; the producer reported none.\n"
        } else {
            body += "## Checks run during research\n\n" + joined(checks.map { c in
                "- `\(c.check)`: \(c.status)" + (c.reason.map { " (\($0))" } ?? "")
            }) + "\n"
        }
        add("test-truth", "Test truth", 8, packet.usableFacts(kind: "testCoverage"), body)

        // data inventory
        body = "# Data inventory\n\n## Entities\n\n"
            + joined(registerLines(packet, packet.usableFacts(kind: "dataEntity"))) + "\n\n"
        body += "## Fields\n\n" + joined(registerLines(packet, packet.usableFacts(kind: "dataField"))) + "\n\n"
        body += "## Migrations\n\n" + joined(registerLines(packet, packet.usableFacts(kind: "migration"))) + "\n"
        add("data-inventory", "Data inventory", 9, packet.usableFacts(kind: "dataEntity"), body)

        // security posture
        body = "# Security posture\n\n## Findings\n\n"
            + joined(registerLines(packet, packet.usableFacts(kind: "security"))) + "\n\n"
        body += "## Configuration\n\n" + joined(registerLines(packet, packet.usableFacts(kind: "config"))) + "\n"
        add("security-posture", "Security posture", 10, packet.usableFacts(kind: "security"), body)

        // observability
        let obs = joined(registerLines(packet, packet.usableFacts(kind: "observability")))
        body = "# Observability\n\n## What is visible in production\n\n"
            + (obs.isEmpty ? "- Nothing was found." : obs) + "\n"
        add("observability", "Observability", 11, packet.usableFacts(kind: "observability"), body)

        // incident patterns
        let incidents = joined(registerLines(packet, packet.usableFacts(kind: "incidentPattern")))
        body = "# Incident patterns\n\n## From commit history and markers\n\n"
            + (incidents.isEmpty ? "- Nothing was found." : incidents) + "\n\n"
        let notable = packet.history.notableCommits
        if !notable.isEmpty {
            body += "## Notable commits\n\n" + joined(notable.map { n in
                "- \(n.subject ?? "") (\(n.author ?? "?"), \(n.date ?? "?")) [[\(n.anchor)]]"
            }) + "\n"
        }
        add("incident-patterns", "Incident patterns", 12, packet.usableFacts(kind: "incidentPattern"), body)

        // glossary
        body = "# Glossary\n\n" + joined((packet.glossary?.terms ?? []).map { t in
            "- **\(t.term)**: \(t.definition)" + (t.definedAt.map { " [[\($0)]]" } ?? "")
        }) + "\n"
        add("glossary", "Glossary", 13, [], body)

        // landmines, in the style of this repository's CLAUDE.md: verify loop first
        let landmines = packet.usableFacts(kind: "landmine")
        body = "# Landmines\n\n## Verify loop\n\n"
        let ran = checks.filter { $0.status == "ran" }
        if ran.isEmpty {
            body += "The producer ran no build or test command, so nothing below was confirmed by execution.\n\n"
        } else {
            body += "The producer ran: " + ran.map { "`\($0.check)`" }.joined(separator: ", ") + ".\n\n"
        }
        body += "## Numbered gotchas\n\n"
        for (index, fact) in landmines.enumerated() {
            body += "\(index + 1). \(fact.claim) \(cite(fact))"
                + (packet.primaryAnchor(fact).map { " [[\($0)]]" } ?? "") + "\n"
        }
        add("landmines", "Landmines", 14, landmines, body)

        // operational scorecard, written whatever the run status
        let coverage = packet.coverage
        let tracedOrVerified = coverage.directories.filter { $0.level == "traced" || $0.level == "verified" }.count
        rows = ["| Measure | Value |", "|---|---|",
                "| Facts | \(packet.facts.count) |",
                "| Verified | \(packet.facts.filter { $0.status == "verified" }.count) |",
                "| Refuted (excluded from every register) | \(packet.facts.filter { $0.status == "refuted" }.count) |",
                "| Critical paths traced | \(packet.traces.count) of \(coverage.paths.candidates) candidates |",
                "| Directories at level traced or verified | \(tracedOrVerified) of \(coverage.directories.count) |",
                "| Commits mined | \(packet.history.commits) |"]
        body = "# Operational scorecard\n\n## Coverage of this research\n\n" + joined(rows) + "\n\n"
        body += "## What was not read\n\n"
        let unread = coverage.directories.filter { $0.level == "unread" || $0.level == "inventoried" }
        let unreadLines = joined(unread.map { d in
            "- `\(d.path)`: \(d.level)" + (d.reason.map { ", \($0)" } ?? "")
        })
        body += (unreadLines.isEmpty ? "- Every directory was read." : unreadLines) + "\n\n"
        if !coverage.paths.untraced.isEmpty {
            body += "## Candidate paths not traced\n\n" + joined(coverage.paths.untraced.map {
                "- `\($0.id)`: \($0.reason)"
            }) + "\n"
        }
        add("operational-scorecard", "Operational scorecard", 15, [], body)
        add("coverage-report", "Coverage report", 16, [], body)

        return out
    }

    // MARK: - trace documents

    static func traceDocument(_ trace: PacketTrace) -> String {
        var parts = ["# \(trace.title)\n", "**Scenario.** \(trace.scenario)\n", "## Hops\n"]
        for hop in trace.hops {
            parts.append("\(hop.n). \(hop.summary) [[\(hop.anchor)]]")
        }
        parts.append("\n## The ten concerns\n")
        parts.append("| Concern | Status | Evidence |")
        parts.append("|---|---|---|")
        for key in PacketTrace.concernKeys {
            guard let concern = trace.concerns[key] else { continue }
            let evidence = concern.evidence.prefix(3).map { "[[\($0)]]" }.joined(separator: " ")
            parts.append("| \(key) | **\(concern.status)** | \(evidence.isEmpty ? "none" : evidence) |")
        }
        parts.append("\n## What scares me\n")
        for line in trace.scaresMe { parts.append("- \(line)") }
        return parts.joined(separator: "\n") + "\n"
    }
}
