// PacketImporter.swift — "Onboard to a Codebase", milestone M2 (Research Packet contract).
//
// The import half of ARCHITECTURE.md 15.5: point the app at a
// `<name>.packet/` directory, validate it against the repository it was
// researched from, and, only when the report has zero errors, copy the whole
// packet into `<package>/packet/` and record who produced it in the package
// manifest. Warnings never block an import; the sheet lists them and the hub
// shows them later.
//
// Two invariants the rest of the pipeline relies on:
//   * Nothing is written when validation fails. A rejected packet must leave
//     the package exactly as it was, so a failed import can be retried against
//     a corrected packet without first cleaning up a half-copied directory.
//   * The copy replaces `packet/` atomically enough: the new tree is staged
//     next to it and moved into place, so a crash mid-copy cannot leave a
//     packet that is half one producer's and half another's. For the same
//     reason the new manifest VALUE is built before the copy begins, so the
//     only step left after packet/ changes is one atomic manifest write.

import Foundation

enum PacketImporter {

    /// Where a packet lives inside a package (PackageStore.layout's "packet").
    static let packetDirectoryName = "packet"

    /// Validates the packet at `root` and, when it has no errors, copies it
    /// into `store` and updates `manifest.producer`.
    ///
    /// - Parameters:
    ///   - root: the `<name>.packet` directory.
    ///   - store: the package that receives it.
    ///   - repo: a checkout containing `packet.json`'s `repo.headSHA`; nil
    ///     validates anchor grammar only (reported as a warning).
    ///   - git: the runner used to resolve `code:` and `commit:` anchors.
    /// - Returns: the validation report (always, when the import succeeded).
    /// - Throws: `StudioError` when the packet cannot be read, when the report
    ///   has errors (nothing is written in that case), or when the copy fails.
    @discardableResult
    static func importPacket(
        at root: URL,
        into store: PackageStore,
        repo: URL?,
        git: GitRunner
    ) async throws -> PacketValidationReport {
        let packet = try PacketReader.load(root)
        let validator = PacketValidator(packet: packet, repo: repo, git: git)
        let report = try await validator.validate()
        guard report.ok else {
            throw StudioError(rejectionMessage(for: report, root: packet.root))
        }
        // Build the new manifest value BEFORE replacing packet/: a throw from
        // reading the old manifest must not leave a package whose packet/ is
        // the new producer's while manifest.producer still names the old one.
        // What remains is the manifest write, which PackageStore does atomically.
        let manifest = try PacketImporter.manifest(for: packet, in: store)
        try copyPacket(from: packet.root, into: store)
        try store.writeManifest(manifest)
        return report
    }

    /// "….packet was not imported: 2 errors (facts.jsonl:3(F-1): fact has no
    /// evidence; …)" — the first few errors inline, the rest counted.
    static func rejectionMessage(for report: PacketValidationReport, root: URL) -> String {
        let shown = report.errors.prefix(3).map { "\($0.where_): \($0.message)" }
        var detail = shown.joined(separator: "; ")
        if report.errors.count > shown.count {
            detail += "; and \(report.errors.count - shown.count) more"
        }
        let plural = report.errors.count == 1 ? "error" : "errors"
        return "\(root.lastPathComponent) was not imported: \(report.errors.count) \(plural) (\(detail))"
    }

    // MARK: Copying

    /// Replaces `<store.root>/packet/` with a copy of the packet at `source`.
    /// Copying a packet that already *is* the package's own `packet/` is a no-op.
    static func copyPacket(from source: URL, into store: PackageStore) throws {
        let fileManager = FileManager.default
        let from = source.standardizedFileURL
        let destination = store.url(packetDirectoryName).standardizedFileURL
        if from.path == destination.path { return }

        let staging = store.root.appendingPathComponent(
            ".\(packetDirectoryName).import-\(UUID().uuidString)", isDirectory: true
        )
        try? fileManager.removeItem(at: staging)
        do {
            try fileManager.copyItem(at: from, to: staging)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw StudioError("PacketImporter: could not copy \(from.path) into the package: \(error.localizedDescription)")
        }
        do {
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw StudioError("PacketImporter: could not replace \(destination.path): \(error.localizedDescription)")
        }
    }

    // MARK: Manifest

    /// Records the packet's producer in `manifest.json`, creating a minimal
    /// manifest when the package does not have one yet.
    static func updateManifest(in store: PackageStore, from packet: ResearchPacket) throws {
        try store.writeManifest(try PacketImporter.manifest(for: packet, in: store))
    }

    /// The manifest the package should carry after importing `packet`: the
    /// package's existing one with the producer recorded, or a minimal new one.
    /// Pure apart from reading the current manifest — nothing is written, so a
    /// caller can build the value before it starts replacing files.
    /// Fields the package already knows (its own head sha, remote, branch) are
    /// left alone; empty ones are filled from `packet.json`.
    static func manifest(for packet: ResearchPacket, in store: PackageStore) throws -> OnboardingManifest {
        var manifest: OnboardingManifest
        if store.hasManifest {
            manifest = try store.readManifest()
        } else {
            manifest = OnboardingManifest()
            manifest.status = .planning
            manifest.scope = packet.manifest.scope
            if let branch = packet.manifest.repo.defaultBranch, !branch.isEmpty {
                manifest.defaultBranch = branch
            }
        }
        if manifest.headSHA.isEmpty {
            manifest.headSHA = packet.manifest.repo.headSHA
        }
        if manifest.repoURL.isEmpty, let url = packet.manifest.repo.url {
            manifest.repoURL = url
        }

        let producer = packet.manifest.producer
        manifest.producer = OnboardingManifest.Producer(
            name: producer.name,
            version: producer.version,
            model: producer.model,
            finishedAt: producer.finishedAt
        )
        return manifest
    }
}
