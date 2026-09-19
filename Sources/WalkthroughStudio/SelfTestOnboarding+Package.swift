// SelfTestOnboarding+Package.swift — "Onboard to a Codebase", milestone M2.
//
// Probes for the package format: Anchor grammar (string, URL and JSON forms),
// the manifest/checkpoint Codable contract (explicit encode/decode, unknown
// keys ignored, missing optionals nil), PackageStore's layout and atomic
// writes, BuildLog appends across instances, and SHA-256. Called by the
// runner in SelfTestOnboarding.swift as anchorRoundTripProbe,
// manifestRoundTripProbe and packageStoreProbe. No network, no Mac-only UI.

import Foundation

extension SelfTest {

    // MARK: - anchorRoundTripProbe

    static func anchorRoundTripProbe(_ ctx: OnboardingProbeContext) async throws {
        struct Case {
            let string: String
            let expected: Anchor
        }
        let fullSHA = "fb63e78744ce026d810547afbb62c0a08ce2040a"
        let cases: [Case] = [
            Case(string: "code:src/api/orders_handler.py@fb63e78#L1-L3",
                 expected: .code(path: "src/api/orders_handler.py", sha7: "fb63e78", lines: 1...3)),
            // "@" inside the path: only the LAST "@" followed by hex is the sha separator.
            Case(string: "code:src/pkg@v2/a.swift@fb63e78#L1-L3",
                 expected: .code(path: "src/pkg@v2/a.swift", sha7: "fb63e78", lines: 1...3)),
            // "#" inside the path: the fragment is the first "#" AFTER the sha.
            Case(string: "code:docs/notes#1.md@fb63e78#L5",
                 expected: .code(path: "docs/notes#1.md", sha7: "fb63e78", lines: 5...5)),
            // Directory anchor.
            Case(string: "code:src/repo/@fb63e78",
                 expected: .code(path: "src/repo/", sha7: "fb63e78", lines: nil)),
            // Unpinned whole file, and unpinned single line.
            Case(string: "code:src/auth/authz.py",
                 expected: .code(path: "src/auth/authz.py", sha7: nil, lines: nil)),
            Case(string: "code:src/auth/authz.py#L5",
                 expected: .code(path: "src/auth/authz.py", sha7: nil, lines: 5...5)),
            // Full 40-character sha.
            Case(string: "code:db/schema.sql@\(fullSHA)",
                 expected: .code(path: "db/schema.sql", sha7: fullSHA, lines: nil)),
            Case(string: "video:arch-overview#t=12.5",
                 expected: .video(id: "arch-overview", seconds: 12.5, chapter: nil)),
            Case(string: "video:arch-overview#t=90",
                 expected: .video(id: "arch-overview", seconds: 90, chapter: nil)),
            Case(string: "video:tech-debt#c=s02",
                 expected: .video(id: "tech-debt", seconds: nil, chapter: "s02")),
            Case(string: "video:arch-overview",
                 expected: .video(id: "arch-overview", seconds: nil, chapter: nil)),
            Case(string: "doc:tech-debt#ranked-items",
                 expected: .doc(id: "tech-debt", slug: "ranked-items")),
            Case(string: "diagram:arch#OrdersRepo",
                 expected: .diagram(id: "arch", node: "OrdersRepo")),
            Case(string: "trace:create-order#hop3",
                 expected: .trace(id: "create-order", hop: 3)),
            Case(string: "fact:F-map-src-repo-003",
                 expected: .fact(id: "F-map-src-repo-003")),
            Case(string: "commit:\(fullSHA)",
                 expected: .commit(sha: fullSHA)),
            Case(string: "cmd:buildtest/1",
                 expected: .cmd(unit: "buildtest", n: 1)),
            Case(string: "issue:42",
                 expected: .issue(n: 42)),
            Case(string: "url:https://example.com/advisory?id=1#sec",
                 expected: .url("https://example.com/advisory?id=1#sec")),
        ]

        for c in cases {
            guard let parsed = Anchor(string: c.string) else {
                throw StudioError("anchorRoundTripProbe: '\(c.string)' failed to parse")
            }
            guard parsed == c.expected else {
                throw StudioError("anchorRoundTripProbe: '\(c.string)' parsed as \(parsed.string) (\(parsed)), expected \(c.expected.string)")
            }
            guard parsed.string == c.string else {
                throw StudioError("anchorRoundTripProbe: '\(c.string)' re-serialized as '\(parsed.string)'")
            }
            // URL form both ways: Anchor -> URL -> Anchor, and the URL string through init?(string:).
            let url = parsed.url
            guard url.absoluteString != "\(Anchor.scheme)://invalid" else {
                throw StudioError("anchorRoundTripProbe: '\(c.string)' has no URL form")
            }
            guard let fromURL = Anchor(url: url), fromURL == parsed else {
                throw StudioError("anchorRoundTripProbe: URL '\(url.absoluteString)' for '\(c.string)' did not round-trip (got \(Anchor(url: url)?.string ?? "nil"))")
            }
            guard let fromURLString = Anchor(string: url.absoluteString), fromURLString == parsed else {
                throw StudioError("anchorRoundTripProbe: URL string '\(url.absoluteString)' not accepted by init?(string:)")
            }
        }

        // Specific URL shapes from ARCHITECTURE.md 2.2.
        let codeURL = Anchor.code(path: "src/a.py", sha7: "fb63e78", lines: 12...30).url.absoluteString
        guard codeURL == "walkthrough://code/src/a.py?sha=fb63e78&L=12-30" else {
            throw StudioError("anchorRoundTripProbe: code URL form is \(codeURL)")
        }
        let chapterURL = Anchor.video(id: "v1", seconds: nil, chapter: "s02").url.absoluteString
        guard chapterURL == "walkthrough://video/v1?c=s02" else {
            throw StudioError("anchorRoundTripProbe: chapter URL form is \(chapterURL)")
        }
        let traceURL = Anchor.trace(id: "create-order", hop: 3).url.absoluteString
        guard traceURL == "walkthrough://trace/create-order#hop3" else {
            throw StudioError("anchorRoundTripProbe: trace URL form is \(traceURL)")
        }

        // Canonicalization: a degenerate range prints as a single line.
        guard Anchor(string: "code:a.py@fb63e78#L5-L5")?.string == "code:a.py@fb63e78#L5" else {
            throw StudioError("anchorRoundTripProbe: L5-L5 did not canonicalize to L5")
        }
        guard let dir = Anchor(string: "code:src/repo/@fb63e78"), dir.isDirectory else {
            throw StudioError("anchorRoundTripProbe: directory anchor not recognized as a directory")
        }

        // Codable: a single string per anchor, both directions, through OnboardingJSON.
        let expectedAll = cases.map { $0.expected }
        let encoded = try OnboardingJSON.encoder().encode(expectedAll)
        let encodedText = String(data: encoded, encoding: .utf8) ?? ""
        guard encodedText.contains("\"code:src/pkg@v2/a.swift@fb63e78#L1-L3\"") else {
            throw StudioError("anchorRoundTripProbe: anchors did not encode as plain strings: \(encodedText.prefix(200))")
        }
        let decoded = try OnboardingJSON.decoder().decode([Anchor].self, from: encoded)
        guard decoded == expectedAll else {
            throw StudioError("anchorRoundTripProbe: JSON round-trip changed \(decoded.count) anchors")
        }
        var decodeRejected = false
        do {
            _ = try OnboardingJSON.decoder().decode([Anchor].self, from: Data("[\"code:../x@fb63e78\"]".utf8))
        } catch is DecodingError {
            decodeRejected = true
        }
        guard decodeRejected else {
            throw StudioError("anchorRoundTripProbe: decoding a malformed anchor did not throw a DecodingError")
        }

        // Malformed strings must be rejected, with a reason from parse(_:).
        let malformed: [String] = [
            "code:../etc/passwd@fb63e78",            // parent traversal
            "code:/abs/path.py@fb63e78",             // absolute path
            "code:src/repo/@fb63e78#L1-L3",          // directory with a fragment
            "code:src/a.py@fb63e78#L10-L3",          // end before start
            "code:@fb63e78",                         // empty path
            "code:src/a.py@fb63e78#L0",              // lines are 1-based
            "video:v1#t=abc",                        // seconds not a number
            "trace:create-order#hopz",               // hop not a number
            "commit:xyz",                            // not hex
            "issue:0",                               // issues start at 1
            "url:ftp://example.com/x",               // not http(s)
            "doc:tech-debt",                         // slug required
            "bogus:thing",                           // unknown kind
            "",                                      // empty
        ]
        for bad in malformed {
            if let accepted = Anchor(string: bad) {
                throw StudioError("anchorRoundTripProbe: malformed '\(bad)' was accepted as \(accepted.string)")
            }
            var reason = ""
            do {
                _ = try Anchor.parse(bad)
            } catch let error as StudioError {
                reason = error.message
            }
            guard reason.hasPrefix("anchor") else {
                throw StudioError("anchorRoundTripProbe: parse('\(bad)') did not throw a StudioError reason (got '\(reason)')")
            }
        }

        print("selftest: anchorRoundTripProbe OK (\(cases.count) anchors round-trip as string, URL and JSON; \(malformed.count) malformed rejected)")
    }

    // MARK: - manifestRoundTripProbe

    static func manifestRoundTripProbe(_ ctx: OnboardingProbeContext) async throws {
        let probeDir = ctx.outDir.appendingPathComponent("package-probe", isDirectory: true)
        try FileManager.default.createDirectory(at: probeDir, withIntermediateDirectories: true)
        let encoder = OnboardingJSON.encoder()
        let decoder = OnboardingJSON.decoder()

        // 1. A populated manifest survives encode -> decode unchanged.
        var manifest = OnboardingManifest()
        manifest.repoURL = "https://github.com/example/fixture-repo"
        manifest.headSHA = "fb63e78744ce026d810547afbb62c0a08ce2040a"
        manifest.createdAt = Date(timeIntervalSince1970: 1_790_000_000)
        manifest.models.planner = "claude-opus-5"
        manifest.models.worker = "claude-sonnet-5"
        manifest.narration.timingSource = "provider-words"
        manifest.budget.capUSD = 25
        manifest.spent.add(OnboardingUsage(inputTokens: 1200, outputTokens: 300, cacheReadTokens: 800, cacheWriteTokens: 100, usd: 0.0123), model: "claude-sonnet-5")
        manifest.status = .running
        manifest.unproduced = ["video:deploy"]
        manifest.coverage.unreadDirs = [OnboardingManifest.Coverage.UnreadDir(path: "vendor/", reason: "generated")]
        manifest.coverage.skippedChecks = [OnboardingManifest.Coverage.SkippedCheck(check: "build", reason: "runBuild off")]
        var video = OnboardingManifest.Deliverable(id: "video:arch-overview", kind: .video, title: "Architecture overview", path: "videos/arch-overview")
        video.minutes = 11
        video.order = 2
        video.status = .built
        video.inputsHash = "abc"
        video.producedBy = "compose-arch"
        manifest.deliverables = [video, OnboardingManifest.Deliverable(id: "doc:tech-debt", kind: .doc, title: "Tech debt", path: "docs/tech-debt.md")]
        manifest.edges = [OnboardingManifest.Edge(from: "fact:F-map-src-7", to: "doc:tech-debt")]
        manifest.producer = OnboardingManifest.Producer(name: "claude-code-skill", version: "1.0", model: "claude-opus-5", finishedAt: Date(timeIntervalSince1970: 1_790_000_100))
        manifest.briefingPath = "/tmp/briefing.pdf"

        let encoded = try encoder.encode(manifest)
        try encoded.write(to: probeDir.appendingPathComponent("manifest.json"))
        let text = String(data: encoded, encoding: .utf8) ?? ""
        guard text.contains("\"createdAt\" : \"2026-09-21T14:13:20Z\"") else {
            throw StudioError("manifestRoundTripProbe: createdAt not ISO 8601 UTC in \(text.prefix(300))")
        }
        guard text.contains("\"version\" : 1"), text.contains("\"status\" : \"running\""), text.contains("\"capUSD\" : 25") else {
            throw StudioError("manifestRoundTripProbe: expected keys missing from encoded manifest")
        }
        let decodedManifest = try decoder.decode(OnboardingManifest.self, from: encoded)
        guard decodedManifest == manifest else {
            throw StudioError("manifestRoundTripProbe: decoded manifest differs (headSHA \(decodedManifest.headSHA), \(decodedManifest.deliverables.count) deliverables, spent \(decodedManifest.spent.usd))")
        }
        guard decodedManifest.spent.byModel["claude-sonnet-5"]?.inputTokens == 1200 else {
            throw StudioError("manifestRoundTripProbe: spent.byModel lost")
        }

        // 2. Unknown keys are ignored (and dropped on re-encode), missing
        // optionals decode as nil, missing non-optionals take defaults.
        let legacy = """
        {
          "version": 1,
          "repoURL": "https://github.com/example/fixture-repo",
          "headSHA": "fb63e78744ce026d810547afbb62c0a08ce2040a",
          "createdAt": "2026-09-19T09:41:00.250Z",
          "depth": "standard",
          "futureFlag": {"nested": [1, 2, 3]},
          "budget": {},
          "status": "partial",
          "deliverables": [
            { "id": "video:arch-overview", "kind": "video", "title": "Arch", "path": "videos/arch-overview",
              "minutes": 11, "order": 2, "status": "pending", "inputsHash": "", "producedBy": "", "extra": true }
          ]
        }
        """
        let lenient = try decoder.decode(OnboardingManifest.self, from: Data(legacy.utf8))
        guard lenient.producer == nil, lenient.briefingPath == nil, lenient.budget.capUSD == nil else {
            throw StudioError("manifestRoundTripProbe: missing optionals did not decode as nil (producer \(String(describing: lenient.producer)), briefing \(String(describing: lenient.briefingPath)), cap \(String(describing: lenient.budget.capUSD)))")
        }
        guard lenient.status == .partial, lenient.scope == "complete", lenient.localClone == "repo", lenient.defaultBranch == "main" else {
            throw StudioError("manifestRoundTripProbe: defaults not applied (scope \(lenient.scope), clone \(lenient.localClone))")
        }
        guard abs(lenient.createdAt.timeIntervalSince1970 - 1_789_810_860.25) < 0.01 else {
            throw StudioError("manifestRoundTripProbe: fractional-second ISO date decoded as \(lenient.createdAt.timeIntervalSince1970)")
        }
        guard lenient.deliverables.count == 1, lenient.deliverables[0].kind == .video, lenient.deliverables[0].minutes == 11 else {
            throw StudioError("manifestRoundTripProbe: deliverables decoded as \(lenient.deliverables)")
        }
        let reencodedData = try encoder.encode(lenient)
        let reencoded = String(data: reencodedData, encoding: .utf8) ?? ""
        guard !reencoded.contains("depth"), !reencoded.contains("futureFlag"), !reencoded.contains("\"extra\""),
              !reencoded.contains("producer"), !reencoded.contains("briefingPath") else {
            throw StudioError("manifestRoundTripProbe: unknown or nil keys leaked into re-encoded manifest")
        }

        // 3. checkpoint.json (WorkPlan) from ARCHITECTURE.md 2.4, with nulls.
        let planJSON = """
        { "version": 1, "sessionId": "6BA7B810-9DAD-11D1-80B4-00C04FD430C8", "units": [
          { "id": "map-src-api", "kind": "map", "role": "worker", "inputs": ["inventory"], "params": { "dir": "src/api" },
            "status": "running", "attempt": 1, "maxTurns": 40,
            "inputsHash": "deadbeef", "outputHash": "", "outputs": ["facts/map-src-api.jsonl"],
            "usage": { "inputTokens": 10, "outputTokens": 5, "cacheReadTokens": 0, "usd": 0.001 },
            "startedAt": "2026-09-19T09:41:00Z", "finishedAt": null, "error": null } ] }
        """
        let plan = try decoder.decode(WorkPlan.self, from: Data(planJSON.utf8))
        guard plan.sessionId.uuidString == "6BA7B810-9DAD-11D1-80B4-00C04FD430C8", plan.units.count == 1 else {
            throw StudioError("manifestRoundTripProbe: WorkPlan decoded \(plan.units.count) units, session \(plan.sessionId)")
        }
        let unit = plan.units[0]
        guard unit.id == "map-src-api", unit.status == .running, unit.params["dir"] == "src/api",
              unit.usage.inputTokens == 10, unit.usage.cacheWriteTokens == 0,
              unit.startedAt != nil, unit.finishedAt == nil, unit.error == nil else {
            throw StudioError("manifestRoundTripProbe: WorkUnit fields wrong: \(unit)")
        }
        let planAgain = try decoder.decode(WorkPlan.self, from: encoder.encode(plan))
        guard planAgain == plan else {
            throw StudioError("manifestRoundTripProbe: WorkPlan did not round-trip")
        }
        try encoder.encode(plan).write(to: probeDir.appendingPathComponent("checkpoint.json"))

        // 4. Notices and stages.
        let notice = OnboardingNotice(message: "Build skipped (runBuild off)", retryUnitId: "buildtest")
        let noticeAgain = try decoder.decode(OnboardingNotice.self, from: encoder.encode(notice))
        guard noticeAgain == notice else {
            throw StudioError("manifestRoundTripProbe: notice did not round-trip")
        }
        let bareNotice = try decoder.decode(OnboardingNotice.self, from: Data("{\"message\": \"hi\"}".utf8))
        guard bareNotice.retryUnitId == nil, !bareNotice.id.isEmpty else {
            throw StudioError("manifestRoundTripProbe: bare notice decoded wrong")
        }
        let stages = try decoder.decode([OnboardingStage].self, from: encoder.encode(OnboardingStage.allCases))
        guard stages == OnboardingStage.allCases, OnboardingStage.acquire < OnboardingStage.complete,
              OnboardingStage.allCases.first == .acquire, OnboardingStage.allCases.last == .complete else {
            throw StudioError("manifestRoundTripProbe: stage order broken: \(stages)")
        }

        print("selftest: manifestRoundTripProbe OK (manifest, checkpoint, notice and stages round-trip; unknown keys ignored; missing optionals nil)")
    }

    // MARK: - packageStoreProbe

    static func packageStoreProbe(_ ctx: OnboardingProbeContext) async throws {
        let outputDir = ctx.scratch.appendingPathComponent("store-probe", isDirectory: true)
        let packageURL = PackageStore.packageURL(outputDir: outputDir, repoName: "fixture-repo")
        guard packageURL.lastPathComponent == "fixture-repo.onboarding" else {
            throw StudioError("packageStoreProbe: packageURL gave \(packageURL.path)")
        }
        guard PackageStore.repoName(fromSource: "https://github.com/acme/Orders.git") == "Orders",
              PackageStore.repoName(fromSource: "git@github.com:acme/orders") == "orders",
              PackageStore.repoName(fromSource: "/Users/me/src/orders/") == "orders",
              PackageStore.sanitizedRepoName("../weird name") == "weird-name" else {
            throw StudioError("packageStoreProbe: repo name derivation wrong: \(PackageStore.repoName(fromSource: "git@github.com:acme/orders")), \(PackageStore.sanitizedRepoName("../weird name"))")
        }

        // 1. Layout.
        let store = try PackageStore(root: packageURL)
        var isDir: ObjCBool = false
        for name in PackageStore.layout {
            let path = store.url(name).path
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                throw StudioError("packageStoreProbe: layout directory missing: \(name)")
            }
        }
        guard PackageStore.layout.count == 13 else {
            throw StudioError("packageStoreProbe: layout has \(PackageStore.layout.count) directories, expected 13")
        }

        // 2. Atomic writes: create, overwrite, nested directory, no temp files left.
        try store.writeAtomically(Data("first".utf8), to: "index/anchors.json")
        try store.writeAtomically(Data("second".utf8), to: "index/anchors.json")
        try store.writeAtomically("nested", to: "videos/arch-overview/script.json")
        let overwritten = try store.readString("index/anchors.json")
        guard overwritten == "second" else {
            throw StudioError("packageStoreProbe: overwrite did not replace content: \(overwritten)")
        }
        let nested = try store.readString("videos/arch-overview/script.json")
        guard nested == "nested" else {
            throw StudioError("packageStoreProbe: nested write failed")
        }
        let indexListing = store.listing("index")
        guard indexListing == ["anchors.json"] else {
            throw StudioError("packageStoreProbe: index/ contains \(indexListing) after atomic writes (temp file left behind?)")
        }
        let videoListing = store.listing("videos/arch-overview")
        guard !videoListing.contains(where: { $0.contains(".tmp") }) else {
            throw StudioError("packageStoreProbe: temp file left behind: \(videoListing)")
        }
        var missingMessage = ""
        do {
            _ = try store.readData("index/missing.json")
        } catch let error as StudioError {
            missingMessage = error.message
        }
        guard missingMessage.contains("index/missing.json") else {
            throw StudioError("packageStoreProbe: reading a missing file gave '\(missingMessage)', expected a StudioError naming the path")
        }

        // 3. Manifest and checkpoint through the store.
        var manifest = OnboardingManifest()
        manifest.headSHA = "fb63e78744ce026d810547afbb62c0a08ce2040a"
        manifest.repoURL = "https://github.com/example/fixture-repo"
        guard !store.hasManifest else { throw StudioError("packageStoreProbe: manifest present before write") }
        try store.writeManifest(manifest)
        let manifestBack = try store.readManifest()
        guard store.hasManifest, manifestBack == manifest else {
            throw StudioError("packageStoreProbe: manifest did not round-trip through the store")
        }
        var plan = WorkPlan()
        plan.upsert(WorkUnit(id: "inventory", kind: "inventory", role: "deterministic"))
        plan.upsert(WorkUnit(id: "map-src-api", kind: "map", inputs: ["inventory"], params: ["dir": "src/api"]))
        try store.writeWorkPlan(plan)
        let planBack = try store.readWorkPlan()
        guard planBack == plan, store.listing("").contains("checkpoint.json") else {
            throw StudioError("packageStoreProbe: checkpoint did not round-trip")
        }

        // 4. Build logs grow across two BuildLog instances (two sessions).
        let sessionA = UUID()
        let sessionB = UUID()
        let logA = BuildLog(store: store)
        logA.beginSession(id: sessionA)
        logA.appendMarkdown("unit inventory started (attempt 1)")
        logA.appendMarkdown("config/settings.example contains FAKE_SECRET=sk-test-fixture-0001 and Authorization: Bearer abcdefghijklmnop")
        logA.appendRecord(BuildLogRecord(unitId: "map-src-api", model: "claude-sonnet-5", inputTokens: 1200, outputTokens: 300, cacheReadTokens: 800, cacheWriteTokens: 100, usd: 0.0123, stopReason: "end_turn", ms: 4200, streaming: true))

        let logB = BuildLog(store: store)
        logB.beginSession(id: sessionB)
        logB.appendMarkdown("resumed after cancel; units 1 to 3 kept")
        logB.appendRecord(BuildLogRecord(unitId: "map-src-api", model: "claude-sonnet-5", inputTokens: 900, outputTokens: 120, usd: 0.005, stopReason: "tool_use", ms: 1800, streaming: false))

        let markdown = try store.readString(BuildLog.markdownFileName)
        let sessionLines = markdown.split(separator: "\n").filter { $0.hasPrefix("## Session ") }
        guard sessionLines.count == 2,
              markdown.contains("## Session \(sessionA.uuidString) "),
              markdown.contains("## Session \(sessionB.uuidString) "),
              markdown.contains("unit inventory started"), markdown.contains("resumed after cancel") else {
            throw StudioError("packageStoreProbe: build-log.md has \(sessionLines.count) session headers:\n\(markdown)")
        }
        guard !markdown.contains("sk-test-fixture-0001"), !markdown.contains("abcdefghijklmnop"), markdown.contains("[redacted]") else {
            throw StudioError("packageStoreProbe: build-log.md leaked a key:\n\(markdown)")
        }
        let jsonl = try store.readString(BuildLog.recordsFileName)
        let recordLines = jsonl.split(separator: "\n", omittingEmptySubsequences: true)
        guard recordLines.count == 2 else {
            throw StudioError("packageStoreProbe: build-log.jsonl has \(recordLines.count) lines:\n\(jsonl)")
        }
        let records = logB.records()
        guard records.count == 2, records[0].inputTokens == 1200, records[0].streaming, records[1].stopReason == "tool_use",
              abs(records[0].usd - 0.0123) < 1e-9, records[1].cacheWriteTokens == 0 else {
            throw StudioError("packageStoreProbe: build-log.jsonl records decoded wrong: \(records)")
        }
        guard recordLines[0].contains("\"ts\":\"") else {
            throw StudioError("packageStoreProbe: jsonl record is not compact with an ISO ts: \(recordLines[0])")
        }

        // 5. SHA-256 against a known digest.
        let known = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        let digest = store.sha256(of: Data("abc".utf8))
        guard digest == known else {
            throw StudioError("packageStoreProbe: sha256(\"abc\") = \(digest)")
        }
        let fileDigest = try store.sha256(ofFileAt: "index/anchors.json")
        let missingDigest = try store.sha256(ofFileAt: "index/nope.json")
        guard store.sha256(of: "abc") == known, fileDigest == store.sha256(of: "second"), missingDigest == "" else {
            throw StudioError("packageStoreProbe: sha256 convenience overloads disagree")
        }

        // 6. Reopening the same root is a no-op on existing content.
        let reopened = try PackageStore(root: packageURL)
        let reopenedContent = try reopened.readString("index/anchors.json")
        guard reopenedContent == "second", reopened.hasManifest else {
            throw StudioError("packageStoreProbe: reopening the package lost content")
        }

        // Leave a copy of the logs in outDir for eyeballing.
        let probeDir = ctx.outDir.appendingPathComponent("package-probe", isDirectory: true)
        try FileManager.default.createDirectory(at: probeDir, withIntermediateDirectories: true)
        try Data(markdown.utf8).write(to: probeDir.appendingPathComponent("build-log.md"))
        try Data(jsonl.utf8).write(to: probeDir.appendingPathComponent("build-log.jsonl"))

        print("selftest: packageStoreProbe OK (13 dirs, atomic overwrite without temp files, 2 sessions in both logs, keys redacted, sha256 matches)")
    }
}
