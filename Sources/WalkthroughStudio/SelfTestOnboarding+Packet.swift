// SelfTestOnboarding+Packet.swift — "Onboard to a Codebase", milestone M2/M3.
//
// Two probes for the Research Packet contract (docs/onboarding/PACKET.md):
//
//   packetValidateProbe — the checked-in fixture packet validates against the
//     fixture repository with zero errors; a deliberately broken copy (one
//     dangling evidence anchor, one fact with no evidence, one deleted trace
//     of a ranked path) is rejected with those three errors; and importing the
//     good packet fills <package>/packet/ and records the producer.
//   fixturePacketProbe — the packet actually carries the findings the fixture
//     repository was built to contain (ARCHITECTURE.md 15.3): the hotspot, the
//     PII column, the unapplied migration, the missing rollback, the ancient
//     pinned dependency, bus factor 1 everywhere, generated code flagged,
//     and an idempotency gap on the traced order path.
//
// Both read the packet from Bundle.module (Package.swift copies
// OnboardingResources verbatim); neither touches the network.

import Foundation

/// What the fixture packet promises, the way `FixtureRepoFacts` states what
/// the fixture repository promises. Checked in by M3 at
/// `Sources/WalkthroughStudio/OnboardingResources/fixtures/fixture-repo.packet/`.
enum FixturePacketFacts {
    static let directoryName = "fixture-repo.packet"
    static let bundleSubdirectory = "OnboardingResources/fixtures"

    // These spellings ARE the contract between the producer skill and the
    // content half: a packet that names the same findings differently is a
    // packet the projectors cannot read. If a regenerated packet disagrees
    // with one of them, change the packet (or this constant, deliberately) —
    // do not loosen the probe until it passes.
    static let hotspotSubject = "orders_repo.py"
    static let piiEntity = "users"
    static let migrationClaim = "002"
    static let rollbackSubject = "deploy.sh"
    static let dependencyName = "requests"
    static let dependencyVersion = "2.19.0"
    static let generatedDir = "vendor/"
    static let tracedEntryFile = "orders_handler.py"
}

extension SelfTest {

    // MARK: - Locating the fixture packet

    /// The fixture packet inside the resource bundle. Two lookups, because a
    /// `.copy`'d directory is addressable both as a named resource and as a
    /// plain path under `resourceURL`.
    static func fixturePacketURL() throws -> URL {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let direct = Bundle.module.url(
            forResource: FixturePacketFacts.directoryName,
            withExtension: nil,
            subdirectory: FixturePacketFacts.bundleSubdirectory
        ) {
            candidates.append(direct)
        }
        if let resources = Bundle.module.resourceURL {
            candidates.append(
                resources
                    .appendingPathComponent(FixturePacketFacts.bundleSubdirectory, isDirectory: true)
                    .appendingPathComponent(FixturePacketFacts.directoryName, isDirectory: true)
            )
        }
        for candidate in candidates {
            var isDirectory: ObjCBool = false
            let exists = fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory)
            if exists, isDirectory.boolValue,
               fileManager.fileExists(atPath: candidate.appendingPathComponent("packet.json").path) {
                return candidate.standardizedFileURL
            }
        }
        let looked = candidates.map { $0.path }.joined(separator: ", ")
        throw StudioError(
            "fixture packet not found in the app bundle: expected "
            + "\(FixturePacketFacts.bundleSubdirectory)/\(FixturePacketFacts.directoryName)/packet.json "
            + "(checked in by milestone M3; Package.swift copies OnboardingResources). Looked at: "
            + (looked.isEmpty ? "(no bundle resource URL)" : looked)
        )
    }

    // MARK: - packetValidateProbe

    static func packetValidateProbe(_ ctx: OnboardingProbeContext) async throws {
        let fileManager = FileManager.default
        let git = GitRunner()
        let good = try SelfTest.fixturePacketURL()

        // 1. The fixture packet validates against the fixture repository.
        let packet = try PacketReader.load(good)
        guard packet.headSHA == FixtureRepoFacts.headSHA else {
            throw StudioError("packetValidateProbe: packet.json pins \(packet.headSHA), fixture HEAD is \(FixtureRepoFacts.headSHA)")
        }
        let report = try await PacketValidator(packet: packet, repo: ctx.fixtureRepo, git: git).validate()
        guard report.ok else {
            let lines = report.errors.prefix(5).map { "\($0.where_): \($0.message)" }.joined(separator: "\n  ")
            throw StudioError("packetValidateProbe: the fixture packet has \(report.errors.count) error(s):\n  \(lines)")
        }
        guard (report.stats["facts"] ?? 0) > 0, (report.stats["traces"] ?? 0) > 0 else {
            throw StudioError("packetValidateProbe: stats say \(report.stats["facts"] ?? 0) facts and \(report.stats["traces"] ?? 0) traces")
        }

        // 2. A broken copy is rejected with exactly the three failures the
        //    contract exists to catch.
        let broken = ctx.scratch.appendingPathComponent("broken.packet", isDirectory: true)
        try? fileManager.removeItem(at: broken)
        try fileManager.copyItem(at: good, to: broken)
        // copyItem preserves the bundle's modes; the copy has to be editable.
        SelfTest.makeWritable(broken)

        let danglingAnchor = try SelfTest.breakFirstEvidenceAnchor(in: broken, packet: packet)
        let orphanID = try SelfTest.appendOrphanFact(to: broken)
        let deletedTrace = try SelfTest.deleteRankedTrace(in: broken, packet: packet)

        let brokenPacket = try PacketReader.load(broken)
        let brokenReport = try await PacketValidator(packet: brokenPacket, repo: ctx.fixtureRepo, git: git).validate()
        let messages = brokenReport.errors.map { "\($0.where_): \($0.message)" }
        let listing = messages.joined(separator: "\n  ")
        guard brokenReport.errors.count >= 3 else {
            throw StudioError("packetValidateProbe: the broken packet produced \(brokenReport.errors.count) error(s), expected at least 3:\n  \(listing)")
        }
        guard messages.contains(where: { $0.contains("outside file") || $0.contains("not found") }) else {
            throw StudioError("packetValidateProbe: no dangling-anchor error for \(danglingAnchor):\n  \(listing)")
        }
        guard messages.contains(where: { $0.contains("no evidence") }) else {
            throw StudioError("packetValidateProbe: no missing-evidence error for \(orphanID):\n  \(listing)")
        }
        guard messages.contains(where: { $0.contains("has no traces/") }) else {
            throw StudioError("packetValidateProbe: no missing-trace error for \(deletedTrace):\n  \(listing)")
        }

        // 3. Importing the good packet fills the package; importing the broken
        //    one throws and writes nothing.
        let packageRoot = ctx.scratch.appendingPathComponent("import-pkg", isDirectory: true)
        let store = try PackageStore(root: packageRoot)
        let importReport = try await PacketImporter.importPacket(at: good, into: store, repo: ctx.fixtureRepo, git: git)
        guard importReport.ok else {
            throw StudioError("packetValidateProbe: import reported \(importReport.errors.count) error(s)")
        }
        guard store.exists("packet/facts.jsonl"), store.exists("packet/packet.json") else {
            throw StudioError("packetValidateProbe: \(packageRoot.path)/packet/ is missing facts.jsonl or packet.json after import (listing: \(store.listing("packet")))")
        }
        let manifest = try store.readManifest()
        guard manifest.producer?.name == packet.manifest.producer.name, !packet.manifest.producer.name.isEmpty else {
            throw StudioError("packetValidateProbe: manifest.producer.name is \(manifest.producer?.name ?? "nil"), expected \(packet.manifest.producer.name)")
        }
        guard manifest.headSHA == packet.headSHA else {
            throw StudioError("packetValidateProbe: manifest.headSHA is \(manifest.headSHA), expected \(packet.headSHA)")
        }

        let rejectedRoot = ctx.scratch.appendingPathComponent("import-rejected", isDirectory: true)
        let rejectedStore = try PackageStore(root: rejectedRoot)
        var rejection = ""
        do {
            _ = try await PacketImporter.importPacket(at: broken, into: rejectedStore, repo: ctx.fixtureRepo, git: git)
        } catch let error as StudioError {
            rejection = error.message
        }
        guard !rejection.isEmpty else {
            throw StudioError("packetValidateProbe: importing the broken packet did not throw")
        }
        guard !rejectedStore.exists("packet/facts.jsonl"), !rejectedStore.hasManifest else {
            throw StudioError("packetValidateProbe: a rejected import still wrote into \(rejectedRoot.path)")
        }

        // Keep the report next to the other probe output for eyeballing.
        let probeDir = ctx.outDir.appendingPathComponent("packet-probe", isDirectory: true)
        try fileManager.createDirectory(at: probeDir, withIntermediateDirectories: true)
        try OnboardingJSON.encoder().encode(report).write(to: probeDir.appendingPathComponent("fixture-report.json"))
        try OnboardingJSON.encoder().encode(brokenReport).write(to: probeDir.appendingPathComponent("broken-report.json"))

        print("selftest: packetValidateProbe OK (fixture packet: \(report.stats["facts"] ?? 0) facts, \(report.stats["traces"] ?? 0) traces, 0 errors, \(report.warnings.count) warnings; broken copy rejected with \(brokenReport.errors.count) errors; imported into \(packageRoot.lastPathComponent))")
    }

    // MARK: Breaking a copy of the packet

    /// Points the first fact's first evidence anchor at a line range past the
    /// end of its file (or, when that anchor is not a pinned file anchor, at a
    /// file that does not exist). Returns the anchor it wrote.
    static func breakFirstEvidenceAnchor(in root: URL, packet: ResearchPacket) throws -> String {
        let factsURL = root.appendingPathComponent(PacketFact.fileName)
        let text = try String(contentsOf: factsURL, encoding: .utf8)
        var lines = text.components(separatedBy: "\n")
        guard let index = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw StudioError("packetValidateProbe: \(PacketFact.fileName) has no fact lines to break")
        }
        guard var object = try JSONSerialization.jsonObject(with: Data(lines[index].utf8)) as? [String: Any],
              var evidence = object["evidence"] as? [Any], !evidence.isEmpty,
              var first = evidence[0] as? [String: Any],
              let rawAnchor = first["anchor"] as? String else {
            throw StudioError("packetValidateProbe: the first fact line has no evidence[0].anchor to break")
        }

        var dangling = "code:no/such/file/anywhere.py@" + String(packet.headSHA.prefix(7))
        if let parsed = Anchor(string: rawAnchor), case .code(let path, let pinned, _) = parsed,
           let sha = pinned, !path.hasSuffix("/") {
            dangling = Anchor.code(path: path, sha7: sha, lines: 900_000...900_100).string
        }
        first["anchor"] = dangling
        evidence[0] = first
        object["evidence"] = evidence

        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        lines[index] = String(decoding: data, as: UTF8.self)
        let rewritten = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n") + "\n"
        try Data(rewritten.utf8).write(to: factsURL)
        return dangling
    }

    /// Appends a fact with an empty `evidence` array. Returns its id.
    static func appendOrphanFact(to root: URL) throws -> String {
        let factsURL = root.appendingPathComponent(PacketFact.fileName)
        let id = "F-selftest-orphan-001"
        let orphan: [String: Any] = [
            "id": id,
            "kind": "risk",
            "subject": "selftest",
            "claim": "Injected by packetValidateProbe: a fact that cites nothing at all.",
            "attributes": [String: Any](),
            "evidence": [Any](),
            "confidence": 0.5,
            "producedBy": "packetValidateProbe",
            "verdicts": [Any](),
            "status": "proposed",
        ]
        let data = try JSONSerialization.data(withJSONObject: orphan, options: [.sortedKeys, .withoutEscapingSlashes])
        var text = try String(contentsOf: factsURL, encoding: .utf8)
        if !text.isEmpty, !text.hasSuffix("\n") { text += "\n" }
        text += String(decoding: data, as: UTF8.self) + "\n"
        try Data(text.utf8).write(to: factsURL)
        return id
    }

    /// Deletes the trace file of a ranked, traced path. Returns the path id.
    static func deleteRankedTrace(in root: URL, packet: ResearchPacket) throws -> String {
        guard let victim = packet.paths.paths.first(where: { $0.isTraced && packet.traces[$0.id] != nil }) else {
            throw StudioError("packetValidateProbe: paths.json has no ranked path with a trace file to delete")
        }
        let traces = root.appendingPathComponent(PacketTrace.directoryName, isDirectory: true)
        try FileManager.default.removeItem(at: traces.appendingPathComponent("\(victim.id).json"))
        return victim.id
    }

    // MARK: - fixturePacketProbe

    /// The known findings of the fixture repository survive into the packet in
    /// a shape the content half can actually read (kind, subject, attributes,
    /// concerns), not only as prose.
    static func fixturePacketProbe(_ ctx: OnboardingProbeContext) async throws {
        let root = try SelfTest.fixturePacketURL()
        let packet = try PacketReader.load(root)

        // 1. The hotspot is a first-class fact.
        guard packet.facts.contains(where: { $0.kind == "hotspot" && $0.subject.contains(FixturePacketFacts.hotspotSubject) }) else {
            throw StudioError("fixturePacketProbe: no hotspot fact about \(FixturePacketFacts.hotspotSubject) (kinds seen: \(SelfTest.sortedCounts(packet.facts.map { $0.kind })))")
        }

        // 2. The users table is a dataEntity carrying attributes.pii == true.
        let piiFacts = packet.facts.filter {
            $0.kind == "dataEntity" && $0.subject.lowercased().contains(FixturePacketFacts.piiEntity)
        }
        guard !piiFacts.isEmpty else {
            throw StudioError("fixturePacketProbe: no dataEntity fact whose subject names \(FixturePacketFacts.piiEntity)")
        }
        guard piiFacts.contains(where: { SelfTest.isTrue($0.attributes["pii"]) }) else {
            let seen = piiFacts.map { "\($0.id) pii=\(SelfTest.describe($0.attributes["pii"]))" }.joined(separator: ", ")
            throw StudioError("fixturePacketProbe: no \(FixturePacketFacts.piiEntity) dataEntity fact with attributes.pii == true (\(seen))")
        }

        // 3. Migration 002 is recorded as not applied.
        guard packet.facts.contains(where: { fact in
            let claim = fact.claim.lowercased()
            return fact.claim.contains(FixturePacketFacts.migrationClaim)
                && (claim.contains("migration") || claim.contains("applied"))
        }) else {
            throw StudioError("fixturePacketProbe: no fact whose claim mentions migration \(FixturePacketFacts.migrationClaim)")
        }

        // 4. The deploy script has no rollback.
        guard packet.facts.contains(where: {
            $0.subject.contains(FixturePacketFacts.rollbackSubject) && $0.claim.lowercased().contains("rollback")
        }) else {
            throw StudioError("fixturePacketProbe: no fact about \(FixturePacketFacts.rollbackSubject) mentioning rollback")
        }

        // 5. The ancient pinned dependency is flagged (CVEs or end-of-life).
        guard let dependencies = packet.dependencies else {
            throw StudioError("fixturePacketProbe: the packet has no dependencies.json")
        }
        guard let requests = dependencies.dependencies.first(where: { $0.name.lowercased() == FixturePacketFacts.dependencyName }) else {
            let names = dependencies.dependencies.map { $0.name }.joined(separator: ", ")
            throw StudioError("fixturePacketProbe: dependencies.json has no \(FixturePacketFacts.dependencyName) entry (has: \(names))")
        }
        guard requests.version == FixturePacketFacts.dependencyVersion else {
            throw StudioError("fixturePacketProbe: \(FixturePacketFacts.dependencyName) is pinned at \(requests.version), expected \(FixturePacketFacts.dependencyVersion)")
        }
        let cveCount = requests.cves.cves.count
        guard cveCount > 0 || requests.eol == "end-of-life" else {
            throw StudioError("fixturePacketProbe: \(FixturePacketFacts.dependencyName) \(requests.version) is neither CVE-flagged nor end-of-life (cves: \(requests.cves.isUnknown ? "unknown" : "[]"), eol: \(requests.eol))")
        }

        // 6. Every directory is owned by one person. Not over-specified: the
        //    fixture has two authors, and busFactor is the smallest number of
        //    authors covering 50 percent of a directory's commits — with two
        //    authors one of them always reaches 50 percent, so 1 is the only
        //    correct answer for every directory in this repository.
        let ownership = packet.history.ownership
        guard !ownership.isEmpty else {
            throw StudioError("fixturePacketProbe: history.json has no ownership entries")
        }
        if let shared = ownership.first(where: { $0.busFactor != 1 }) {
            throw StudioError("fixturePacketProbe: ownership of \(shared.dir) has busFactor \(shared.busFactor), expected 1")
        }

        // 7. Generated code is flagged as generated, and its coverage is honest.
        //    Reading vendor/ is allowed and produced a real finding here (protoc
        //    output nothing imports), so the level is whatever the evidence
        //    supports; what must hold is that inventory marks it generated with a
        //    reason and that coverage does not claim more than was read.
        guard let vendorInventory = packet.inventory.topLevel.first(where: { $0.path == FixturePacketFacts.generatedDir }) else {
            let paths = packet.inventory.topLevel.map { $0.path }.joined(separator: ", ")
            throw StudioError("fixturePacketProbe: inventory.json has no \(FixturePacketFacts.generatedDir) entry (has: \(paths))")
        }
        guard vendorInventory.generated else {
            throw StudioError("fixturePacketProbe: \(FixturePacketFacts.generatedDir) is not flagged generated in inventory.json")
        }
        guard let reason = vendorInventory.reason, !reason.isEmpty else {
            throw StudioError("fixturePacketProbe: \(FixturePacketFacts.generatedDir) is flagged generated with no reason")
        }
        guard let vendor = packet.coverage.directories.first(where: { $0.path == FixturePacketFacts.generatedDir }) else {
            let paths = packet.coverage.directories.map { $0.path }.joined(separator: ", ")
            throw StudioError("fixturePacketProbe: coverage.json has no \(FixturePacketFacts.generatedDir) entry (has: \(paths))")
        }
        if vendor.filesRead == 0 && vendor.level != "unread" {
            throw StudioError("fixturePacketProbe: \(FixturePacketFacts.generatedDir) read no files but sits at level \(vendor.level)")
        }
        if vendor.level == "unread" && vendor.reason == nil {
            throw StudioError("fixturePacketProbe: \(FixturePacketFacts.generatedDir) is unread with no reason")
        }

        // 8. The traced order path reports the idempotency gap as a finding.
        var idempotencyTrace: String?
        for id in packet.traces.keys.sorted() {
            guard let trace = packet.traces[id] else { continue }
            guard trace.concerns["idempotency"]?.status == "absent" else { continue }
            guard let entry = Anchor(string: trace.entry), case .code(let path, _, _) = entry,
                  path.contains(FixturePacketFacts.tracedEntryFile) else { continue }
            idempotencyTrace = id
            break
        }
        guard let idempotencyTrace else {
            let seen = packet.traces.keys.sorted().map { id in
                "\(id): idempotency=\(packet.traces[id]?.concerns["idempotency"]?.status ?? "missing"), entry=\(packet.traces[id]?.entry ?? "")"
            }.joined(separator: "; ")
            throw StudioError("fixturePacketProbe: no trace entered at \(FixturePacketFacts.tracedEntryFile) reports idempotency absent (\(seen))")
        }

        print("selftest: fixturePacketProbe OK (\(packet.facts.count) facts, \(packet.traces.count) traces; hotspot, users.pii, migration \(FixturePacketFacts.migrationClaim), \(FixturePacketFacts.rollbackSubject) rollback, \(FixturePacketFacts.dependencyName) \(requests.version), busFactor 1 x\(ownership.count), \(FixturePacketFacts.generatedDir) \(vendor.level), idempotency absent in \(idempotencyTrace))")
    }

    // MARK: Small helpers

    /// Gives the owner write permission on every file and directory under
    /// `root` (a packet copied out of a read-only app bundle keeps the
    /// bundle's modes, and this probe has to edit and delete inside the copy).
    static func makeWritable(_ root: URL) {
        let fileManager = FileManager.default
        var targets: [URL] = [root]
        if let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: []) {
            for case let url as URL in enumerator { targets.append(url) }
        }
        for url in targets {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { continue }
            let mode = isDirectory.boolValue ? 0o755 : 0o644
            try? fileManager.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
    }

    /// True for JSON `true`, and for the strings "true" / "yes" a producer may
    /// have written instead.
    nonisolated static func isTrue(_ value: JSONValue?) -> Bool {
        guard let value else { return false }
        if let flag = value.boolValue { return flag }
        if let text = value.stringValue {
            let lowered = text.lowercased()
            return lowered == "true" || lowered == "yes"
        }
        return false
    }

    /// Short description of a free-form attribute for failure messages.
    nonisolated static func describe(_ value: JSONValue?) -> String {
        guard let value else { return "missing" }
        if let flag = value.boolValue { return String(flag) }
        if let text = value.stringValue { return "\"\(text)\"" }
        if let number = value.numberValue { return String(number) }
        if value.isNull { return "null" }
        return "(object)"
    }

    /// "hotspot x3, risk x2" — for messages that list what was actually found.
    nonisolated static func sortedCounts(_ values: [String]) -> String {
        var counts: [String: Int] = [:]
        for value in values { counts[value, default: 0] += 1 }
        return counts.keys.sorted().map { "\($0) x\(counts[$0] ?? 0)" }.joined(separator: ", ")
    }
}
