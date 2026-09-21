// SelfTestOnboarding+Projection — Onboard to a Codebase, milestone M8.
//
//   projectorParityProbe — run the Swift projectors over the checked-in fixture
//     packet and diff every file against the golden projection that
//     `.claude/skills/onboarding-research/scripts/project_packet.py` produced from
//     the same packet.
//
// Two implementations of one contract will drift; the only question is whether a
// build says so or a reader discovers it. Markdown and Mermaid are compared byte
// for byte. JSON is compared as values, because key order inside a JSON object is
// not meaningful and the two languages order them differently — array order still
// is, and is checked.
//
// Derived files the golden deliberately omits (every `docs/*.html` but the
// `tech-debt.html` sample, and the whole `code/` tree) are projected anyway and
// simply have nothing to diff against.

import Foundation

extension SelfTest {

    /// Anything checked in beside the fixture packet, found the two ways a `.copy`'d
    /// directory is addressable: as a named resource and as a path under `resourceURL`.
    /// `contains` names a file that must exist inside a directory resource.
    static func fixtureResourceURL(named name: String, contains: String? = nil) throws -> URL {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let direct = Bundle.module.url(forResource: name, withExtension: nil,
                                          subdirectory: FixturePacketFacts.bundleSubdirectory) {
            candidates.append(direct)
        }
        if let resources = Bundle.module.resourceURL {
            candidates.append(resources
                .appendingPathComponent(FixturePacketFacts.bundleSubdirectory, isDirectory: true)
                .appendingPathComponent(name))
        }
        for candidate in candidates {
            guard fileManager.fileExists(atPath: candidate.path) else { continue }
            if let contains,
               !fileManager.fileExists(atPath: candidate.appendingPathComponent(contains).path) { continue }
            return candidate.standardizedFileURL
        }
        let looked = candidates.map { $0.path }.joined(separator: ", ")
        throw StudioError(
            "\(name) not found in the app bundle: expected under "
            + "\(FixturePacketFacts.bundleSubdirectory)/ (Package.swift copies OnboardingResources). "
            + "Looked at: " + (looked.isEmpty ? "(no bundle resource URL)" : looked))
    }

    /// The golden projection inside the resource bundle, beside the fixture packet.
    static func goldenProjectionURL() throws -> URL {
        try SelfTest.fixtureResourceURL(named: "fixture-repo.golden", contains: "hub/index.json")
    }

    // MARK: - projectorParityProbe

    static func projectorParityProbe(_ ctx: OnboardingProbeContext) async throws {
        let packetURL = try SelfTest.fixturePacketURL()
        let goldenURL = try SelfTest.goldenProjectionURL()
        let packet = try PacketReader.load(packetURL)

        let packageURL = ctx.outDir.appendingPathComponent("projection", isDirectory: true)
        try? FileManager.default.removeItem(at: packageURL)
        let store = try PackageStore(root: packageURL)
        let result = try PackageProjector.project(packet: packet, into: store)

        // 1. Everything the golden holds must exist here and match.
        let goldenFiles = try SelfTest.relativeFiles(under: goldenURL)
            .filter { $0 != "README.md" }
            .sorted()
        guard !goldenFiles.isEmpty else {
            throw StudioError("projectorParityProbe: the golden projection at \(goldenURL.path) is empty")
        }

        var differing: [String] = []
        var missing: [String] = []
        for relative in goldenFiles {
            let mine = packageURL.appendingPathComponent(relative)
            guard let produced = try? Data(contentsOf: mine) else {
                missing.append(relative)
                continue
            }
            let expected = try Data(contentsOf: goldenURL.appendingPathComponent(relative))
            if relative.hasSuffix(".json") {
                if let detail = try SelfTest.jsonDifference(produced: produced, expected: expected, at: relative) {
                    differing.append(detail)
                }
            } else if produced != expected {
                differing.append(SelfTest.textDifference(produced: produced, expected: expected, at: relative))
            }
        }
        guard missing.isEmpty else {
            throw StudioError("projectorParityProbe: the Swift projectors did not produce "
                              + "\(missing.count) file(s) the reference does: \(missing.prefix(6).joined(separator: ", "))")
        }
        guard differing.isEmpty else {
            throw StudioError("projectorParityProbe: \(differing.count) file(s) differ from the golden "
                              + "projection:\n  " + differing.prefix(4).joined(separator: "\n  "))
        }

        // 2. The derived files the golden omits are still produced, for every doc and trace.
        for register in result.registerIDs where !store.exists("docs/\(register).html") {
            throw StudioError("projectorParityProbe: docs/\(register).html was not written")
        }
        for pathID in result.traceIDs {
            for suffix in ["md", "html", "mmd"] where !store.exists("traces/\(pathID).\(suffix)") {
                throw StudioError("projectorParityProbe: traces/\(pathID).\(suffix) was not written")
            }
        }

        // 3. The promise the packet contract rests on: no refuted claim reaches a reader.
        guard result.refutedLeaks.isEmpty else {
            throw StudioError("projectorParityProbe: refuted fact(s) reached a deliverable: "
                              + result.refutedLeaks.joined(separator: ", "))
        }

        // 4. Cited sources travel with the package, so a shared folder needs no checkout.
        let code = try await PackageProjector.emitCode(packet: packet, into: store, repo: ctx.fixtureRepo)
        guard code.missing.isEmpty else {
            throw StudioError("projectorParityProbe: git could not produce \(code.missing.count) cited "
                              + "file(s) at \(packet.sha7): \(code.missing.prefix(4).joined(separator: ", "))")
        }
        guard code.written.count >= 8 else {
            throw StudioError("projectorParityProbe: only \(code.written.count) cited source file(s) emitted; "
                              + "the fixture cites most of its fifteen files")
        }
        let listing = try store.readData("code/index.json")
        guard let parsed = try JSONSerialization.jsonObject(with: listing) as? [String: Any],
              let paths = parsed["paths"] as? [String], paths.count == code.written.count else {
            throw StudioError("projectorParityProbe: code/index.json does not list the \(code.written.count) files written")
        }

        print("selftest: projectorParityProbe OK (\(goldenFiles.count) golden files identical; "
              + "\(result.summaryLine); \(code.written.count) sources"
              + (result.proposedFactCount > 0 ? "; \(result.proposedFactCount) proposed fact(s) held back" : "")
              + ")")
    }

    // MARK: - markdownLiteProbe

    /// The converter against an adversarial corpus whose expectations were computed by
    /// the reference implementation (`scripts/make-markdown-cases.py`).
    ///
    /// The golden projection only exercises the fixture packet's friendly prose, and
    /// every case in this corpus is a shape that once produced different output on the
    /// two sides: a `#` inside a path, a `.` component pathlib drops, an unclosed
    /// emphasis run, a heading chip whose value is only whitespace.
    static func markdownLiteProbe(_ ctx: OnboardingProbeContext) async throws {
        let url = try SelfTest.fixtureResourceURL(named: "markdown-lite-cases.json")
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let labels = root["labels"] as? [[String: String]],
              let inline = root["inline"] as? [[String: String]],
              let blocks = root["blocks"] as? [[String: String]] else {
            throw StudioError("markdownLiteProbe: \(url.lastPathComponent) is not the expected shape")
        }
        guard labels.count >= 200, inline.count >= 120, blocks.count >= 120 else {
            throw StudioError("markdownLiteProbe: the corpus shrank to \(labels.count)/\(inline.count)/"
                              + "\(blocks.count) cases; regenerate it rather than trimming it")
        }

        func check(_ name: String, _ cases: [[String: String]], _ inputKey: String,
                   _ expectedKey: String, _ transform: (String) -> String) throws {
            for entry in cases {
                guard let input = entry[inputKey], let expected = entry[expectedKey] else {
                    throw StudioError("markdownLiteProbe: a \(name) case is missing \(inputKey)/\(expectedKey)")
                }
                let produced = transform(input)
                guard produced != expected else { continue }
                throw StudioError("markdownLiteProbe: \(name) differs from the reference\n"
                                  + "      input:    \(SelfTest.visible(input))\n"
                                  + "      swift:    \(SelfTest.visible(produced))\n"
                                  + "      python:   \(SelfTest.visible(expected))")
            }
        }

        try check("anchorLabel", labels, "anchor", "label") { MarkdownLite.anchorLabel($0) }
        try check("inlineHTML", inline, "text", "html") { MarkdownLite.inlineHTML($0) }
        try check("toHTML", blocks, "markdown", "html") { MarkdownLite.toHTML($0) }

        print("selftest: markdownLiteProbe OK (\(labels.count) labels, \(inline.count) inline, "
              + "\(blocks.count) documents match the reference converter)")
    }

    /// Control characters spelled out, so a failure message shows what actually differs.
    static func visible(_ text: String) -> String {
        var out = ""
        for ch in text.prefix(180) {
            switch ch {
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default: out.append(ch)
            }
        }
        return out
    }

    // MARK: - diffing

    /// Every file under `root`, as paths relative to it, skipping dotfiles.
    static func relativeFiles(under root: URL) throws -> [String] {
        let base = root.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [String] = []
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(base + "/") else { continue }
            let relative = String(path.dropFirst(base.count + 1))
            guard !relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { continue }
            out.append(relative)
        }
        return out
    }

    /// The first line that differs, with both sides, which is what a reader needs to see.
    static func textDifference(produced: Data, expected: Data, at relative: String) -> String {
        let mine = String(decoding: produced, as: UTF8.self).components(separatedBy: "\n")
        let theirs = String(decoding: expected, as: UTF8.self).components(separatedBy: "\n")
        for index in 0..<max(mine.count, theirs.count) {
            let a = index < mine.count ? mine[index] : "(end of file)"
            let b = index < theirs.count ? theirs[index] : "(end of file)"
            if a != b {
                return "\(relative) line \(index + 1):\n      swift: \(a.prefix(160))\n      python: \(b.prefix(160))"
            }
        }
        return "\(relative): same lines, different bytes (line endings?)"
    }

    /// Compares two JSON documents as values. Object key order is not meaningful and the
    /// two languages emit it differently; array order is meaningful and is compared.
    static func jsonDifference(produced: Data, expected: Data, at relative: String) throws -> String? {
        let mine = try JSONSerialization.jsonObject(with: produced)
        let theirs = try JSONSerialization.jsonObject(with: expected)
        guard let diff = SelfTest.firstJSONDifference(mine, theirs, at: "") else { return nil }
        return "\(relative) at \(diff.location):\n      swift: \(diff.mine)\n      python: \(diff.theirs)"
    }

    struct JSONDifference {
        let location: String
        let mine: String
        let theirs: String
    }

    static func firstJSONDifference(_ a: Any, _ b: Any, at location: String) -> JSONDifference? {
        let here = location.isEmpty ? "(root)" : location
        switch (a, b) {
        case let (x as [String: Any], y as [String: Any]):
            for key in Set(x.keys).union(y.keys).sorted() {
                guard let xv = x[key] else {
                    return JSONDifference(location: "\(here).\(key)", mine: "(absent)", theirs: describe(y[key]!))
                }
                guard let yv = y[key] else {
                    return JSONDifference(location: "\(here).\(key)", mine: describe(xv), theirs: "(absent)")
                }
                if let inner = firstJSONDifference(xv, yv, at: location.isEmpty ? key : "\(location).\(key)") {
                    return inner
                }
            }
            return nil
        case let (x as [Any], y as [Any]):
            if x.count != y.count {
                return JSONDifference(location: here, mine: "\(x.count) element(s)", theirs: "\(y.count) element(s)")
            }
            for index in 0..<x.count {
                if let inner = firstJSONDifference(x[index], y[index], at: "\(location)[\(index)]") {
                    return inner
                }
            }
            return nil
        default:
            guard describe(a) != describe(b) else { return nil }
            return JSONDifference(location: here, mine: describe(a), theirs: describe(b))
        }
    }

    /// A stable rendering for comparison and for the failure message. Numbers go through
    /// `NSNumber`, so `2` written by Swift and `2` written by Python compare equal even
    /// though one arrives as Int and the other as Double.
    static func describe(_ value: Any) -> String {
        switch value {
        case is NSNull: return "null"
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "true" : "false" }
            let double = number.doubleValue
            return double == double.rounded() && abs(double) < 1e15
                ? String(Int64(double)) : String(double)
        case let string as String: return "\"\(string.prefix(160))\""
        default: return String(describing: value).prefix(160).description
        }
    }
}
