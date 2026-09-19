// PackageStore.swift — "Onboard to a Codebase", milestone M2 (package format).
//
// The on-disk package `<RepoName>.onboarding/` (ARCHITECTURE.md 2.1) is the
// only source of truth for a run and must be re-openable mid-run, so every
// write here is atomic (temp file in the same directory, then rename). The
// store is a plain final class, not an actor: callers keep it thread-confined
// (the coordinator on the main actor, or one background task per unit).

import Foundation
import CryptoKit

final class PackageStore {
    /// The package root, `<outputDir>/<RepoName>.onboarding`.
    let root: URL

    /// Directories created on open (2.1). `repo-git/` is created by the
    /// acquire unit only when the source is a URL.
    static let layout: [String] = [
        "packet", "repo", "dossier", "facts", "units", "diagrams", "docs",
        "traces", "videos", "index", "hub", "review", "chat",
    ]

    static let packageExtension = "onboarding"

    private let fileManager = FileManager.default

    /// Opens (or creates) the package at `root` and makes sure the layout exists.
    init(root: URL) throws {
        self.root = root.standardizedFileURL
        try fileManager.createDirectory(at: self.root, withIntermediateDirectories: true)
        for name in PackageStore.layout {
            try fileManager.createDirectory(
                at: self.root.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    // MARK: Paths

    /// `<outputDir>/<RepoName>.onboarding`; the repo name is sanitized to a
    /// single path component.
    static func packageURL(outputDir: URL, repoName: String) -> URL {
        let name = sanitizedRepoName(repoName)
        return outputDir.appendingPathComponent("\(name).\(packageExtension)", isDirectory: true)
    }

    /// "https://github.com/acme/orders.git" -> "orders"; "/Users/me/src/orders/" -> "orders".
    static func repoName(fromSource source: String) -> String {
        var trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        if trimmed.hasSuffix(".git") { trimmed.removeLast(4) }
        let last = trimmed.split(separator: "/").last.map(String.init) ?? trimmed
        // SSH form: git@github.com:acme/orders
        let afterColon = last.split(separator: ":").last.map(String.init) ?? last
        return sanitizedRepoName(afterColon)
    }

    /// Keeps letters, digits, "-", "_" and "."; everything else becomes "-".
    static func sanitizedRepoName(_ name: String) -> String {
        var out = ""
        for ch in name {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" || ch == "." {
                out.append(ch)
            } else {
                out.append("-")
            }
        }
        while out.hasPrefix(".") || out.hasPrefix("-") { out.removeFirst() }
        while out.hasSuffix(".") || out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "Repository" : out
    }

    /// Default output folder (OnboardSheet lets the user change it).
    static var defaultOutputDirectory: URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return documents.appendingPathComponent("Onboarding", isDirectory: true)
    }

    /// Absolute URL for a package-relative path ("videos/arch-overview/script.json").
    func url(_ relativePath: String) -> URL {
        var path = relativePath
        while path.hasPrefix("/") { path.removeFirst() }
        return root.appendingPathComponent(path)
    }

    func exists(_ relativePath: String) -> Bool {
        fileManager.fileExists(atPath: url(relativePath).path)
    }

    /// Names in a package-relative directory (hidden files included; empty
    /// when the directory does not exist).
    func listing(_ relativeDirectory: String) -> [String] {
        (try? fileManager.contentsOfDirectory(atPath: url(relativeDirectory).path))?.sorted() ?? []
    }

    // MARK: Reading and writing

    func readData(_ relativePath: String) throws -> Data {
        let target = url(relativePath)
        guard fileManager.fileExists(atPath: target.path) else {
            throw StudioError("PackageStore: \(relativePath) is missing from \(root.lastPathComponent)")
        }
        return try Data(contentsOf: target)
    }

    func readString(_ relativePath: String) throws -> String {
        guard let text = String(data: try readData(relativePath), encoding: .utf8) else {
            throw StudioError("PackageStore: \(relativePath) is not UTF-8")
        }
        return text
    }

    /// Writes to a hidden temp file in the destination's directory, then
    /// renames over the destination (POSIX rename is atomic on the same
    /// volume), so a crash mid-write never leaves a torn file behind.
    func writeAtomically(_ data: Data, to relativePath: String) throws {
        let destination = url(relativePath)
        let directory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let tempName = ".\(destination.lastPathComponent).tmp-\(UUID().uuidString)"
        let temp = directory.appendingPathComponent(tempName)
        do {
            try data.write(to: temp)
        } catch {
            try? fileManager.removeItem(at: temp)
            throw StudioError("PackageStore: could not write \(relativePath): \(error.localizedDescription)")
        }

        let status = rename(temp.path, destination.path)
        if status != 0 {
            let reason = String(cString: strerror(errno))
            try? fileManager.removeItem(at: temp)
            throw StudioError("PackageStore: could not replace \(relativePath): \(reason)")
        }
    }

    func writeAtomically(_ text: String, to relativePath: String) throws {
        try writeAtomically(Data(text.utf8), to: relativePath)
    }

    /// Encodes with OnboardingJSON and writes atomically.
    func writeJSON<T: Encodable>(_ value: T, to relativePath: String) throws {
        let data = try OnboardingJSON.encoder().encode(value)
        try writeAtomically(data, to: relativePath)
    }

    func readJSON<T: Decodable>(_ type: T.Type, from relativePath: String) throws -> T {
        let data = try readData(relativePath)
        do {
            return try OnboardingJSON.decoder().decode(type, from: data)
        } catch {
            throw StudioError("PackageStore: \(relativePath) did not decode as \(type): \(error.localizedDescription)")
        }
    }

    func removeItem(_ relativePath: String) throws {
        let target = url(relativePath)
        if fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
    }

    // MARK: Manifest and checkpoint

    var hasManifest: Bool { exists(OnboardingManifest.fileName) }

    func readManifest() throws -> OnboardingManifest {
        try readJSON(OnboardingManifest.self, from: OnboardingManifest.fileName)
    }

    func writeManifest(_ manifest: OnboardingManifest) throws {
        try writeJSON(manifest, to: OnboardingManifest.fileName)
    }

    var hasWorkPlan: Bool { exists(WorkPlan.fileName) }

    func readWorkPlan() throws -> WorkPlan {
        try readJSON(WorkPlan.self, from: WorkPlan.fileName)
    }

    func writeWorkPlan(_ plan: WorkPlan) throws {
        try writeJSON(plan, to: WorkPlan.fileName)
    }

    // MARK: Content hashes

    /// Lowercase hex SHA-256 (inputsHash / outputHash / audio cache keys).
    func sha256(of data: Data) -> String {
        PackageStore.sha256Hex(data)
    }

    func sha256(of text: String) -> String {
        PackageStore.sha256Hex(Data(text.utf8))
    }

    /// Hash of a file inside the package; empty string when it does not exist.
    func sha256(ofFileAt relativePath: String) throws -> String {
        guard exists(relativePath) else { return "" }
        return sha256(of: try readData(relativePath))
    }

    /// One hash over several files in order (a unit's inputsHash).
    func sha256(ofFilesAt relativePaths: [String]) throws -> String {
        var combined = Data()
        for path in relativePaths {
            combined.append(Data(path.utf8))
            combined.append(0)
            if exists(path) { combined.append(try readData(path)) }
            combined.append(0)
        }
        return sha256(of: combined)
    }

    static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        var hex = ""
        hex.reserveCapacity(64)
        for byte in digest {
            hex += String(format: "%02x", byte)
        }
        return hex
    }
}
