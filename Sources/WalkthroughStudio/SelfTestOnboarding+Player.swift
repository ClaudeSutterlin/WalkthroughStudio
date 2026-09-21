// SelfTestOnboarding+Player — Onboard to a Codebase, milestone M4.
//
//   fixturePackageProbe   — FixturePackage.make produces every file the player reads,
//                           and the timing files obey section 6's invariants.
//   coderefsLookupProbe   — lookup(t) returns the right shot at, between and outside
//                           the interval boundaries.
//   linkRouterProbe       — every anchor in the package resolves; a broken one is
//                           reported by kind.
//   backlinkIndexProbe    — "where is this file covered?" answers from the index.
//
// The first probe builds the package the other three read, so they run in this order
// and share `ctx.outDir/fixture-package`.

import Foundation
import AVFoundation

extension SelfTest {

    /// Where `fixturePackageProbe` leaves the package it built.
    static func fixturePackageURL(_ ctx: OnboardingProbeContext) -> URL {
        ctx.outDir.appendingPathComponent("fixture-package.onboarding", isDirectory: true)
    }

    // MARK: - fixturePackageProbe

    static func fixturePackageProbe(_ ctx: OnboardingProbeContext) async throws {
        let packetURL = try SelfTest.fixturePacketURL()
        let root = SelfTest.fixturePackageURL(ctx)
        try? FileManager.default.removeItem(at: root)

        let built = try await FixturePackage.make(packet: packetURL, repo: ctx.fixtureRepo, into: root)
        let store = built.store
        let folder = "videos/\(FixturePackage.videoID)"

        // 1. Every file the player opens is there.
        let required = [
            "manifest.json", "hub/index.json", "index/anchors.json", "code/index.json",
            "docs/architecture.md", "docs/architecture.html", "docs/tech-debt.html",
            "diagrams/c4-container.mmd", "diagrams/c4-container.links.json",
            "traces/order-creation.md", "traces/order-creation.html", "traces/order-creation.mmd",
            "\(folder)/script.json", "\(folder)/video.mp4", "\(folder)/transcript.json",
            "\(folder)/coderefs.json", "\(folder)/chapters.json",
            "\(folder)/captions.srt", "\(folder)/captions.vtt", "\(folder)/chapters.vtt",
        ]
        let absent = required.filter { !store.exists($0) }
        guard absent.isEmpty else {
            throw StudioError("fixturePackageProbe: the package is missing \(absent.count) file(s): "
                              + absent.prefix(6).joined(separator: ", "))
        }
        guard built.codeFiles == FixtureRepoFacts.files.count else {
            throw StudioError("fixturePackageProbe: \(built.codeFiles) cited source(s) travelled with the "
                              + "package, expected all \(FixtureRepoFacts.files.count)")
        }

        // 2. The mp4 is playable, as long as the transcript says, and carries narration.
        let asset = AVURLAsset(url: store.url("\(folder)/video.mp4"))
        let duration = try await asset.load(.duration).seconds
        let transcript = built.transcript
        guard abs(duration - transcript.duration) < 0.25 else {
            throw StudioError(String(format: "fixturePackageProbe: video is %.2fs but the transcript says %.2fs",
                                     duration, transcript.duration))
        }
        guard let audio = try await asset.loadTracks(withMediaType: .audio).first else {
            throw StudioError("fixturePackageProbe: the video has no audio track — the narration was dropped")
        }
        let audioRange = try await audio.load(.timeRange)
        let audioEnd = audioRange.start.seconds + audioRange.duration.seconds
        let lastShotStart = built.coderefs.intervals.last?.start ?? 0
        guard audioEnd > lastShotStart else {
            throw StudioError(String(format: "fixturePackageProbe: narration ends at %.2fs but the last shot "
                                     + "starts at %.2fs — a post-gap clip was dropped", audioEnd, lastShotStart))
        }

        // 3. Section 6's invariants. These are why the companion card and the captions
        //    can never disagree about what was on screen.
        try SelfTest.assertTimingInvariants(transcript: transcript, coderefs: built.coderefs)

        // 4. Cue counts equal segment counts, by construction rather than by luck.
        let srt = try store.readString("\(folder)/captions.srt")
        let cues = srt.components(separatedBy: " --> ").count - 1
        guard cues == transcript.segments.count else {
            throw StudioError("fixturePackageProbe: captions.srt has \(cues) cue(s) for "
                              + "\(transcript.segments.count) segment(s)")
        }

        // 5. The manifest describes what was built.
        let manifest = try store.readManifest()
        guard manifest.headSHA == FixtureRepoFacts.headSHA else {
            throw StudioError("fixturePackageProbe: manifest pins \(manifest.headSHA), "
                              + "fixture HEAD is \(FixtureRepoFacts.headSHA)")
        }
        let videoDeliverables = manifest.deliverables.filter { $0.kind == .video }
        guard videoDeliverables.count == 1, manifest.deliverables.count >= 20 else {
            throw StudioError("fixturePackageProbe: manifest lists \(manifest.deliverables.count) deliverable(s) "
                              + "with \(videoDeliverables.count) video(s); expected one video and 20 or more in total")
        }

        print(String(format: "selftest: fixturePackageProbe OK (%.2fs video, %d shots, %d segments, "
                     + "%d chapters, %d deliverables, %d sources)",
                     transcript.duration, built.coderefs.intervals.count, transcript.segments.count,
                     transcript.chapters.count, manifest.deliverables.count, built.codeFiles))
    }

    /// ARCHITECTURE.md section 6, asserted rather than assumed.
    static func assertTimingInvariants(transcript: TranscriptDoc, coderefs: CodeRefMap) throws {
        guard let firstSegment = transcript.segments.first,
              let lastSegment = transcript.segments.last else {
            throw StudioError("timing: the transcript has no segments")
        }
        guard firstSegment.start == 0 else {
            throw StudioError(String(format: "timing: the first segment starts at %.3fs, not 0", firstSegment.start))
        }
        for (a, b) in zip(transcript.segments, transcript.segments.dropFirst()) {
            guard abs(a.end - b.start) < 0.001 else {
                throw StudioError(String(format: "timing: %@ ends at %.3fs but %@ starts at %.3fs — segments must tile",
                                         a.id, a.end, b.id, b.start))
            }
        }
        guard abs(lastSegment.end - transcript.duration) < 0.25 else {
            throw StudioError(String(format: "timing: the last segment ends at %.3fs, the video at %.3fs",
                                     lastSegment.end, transcript.duration))
        }
        if let empty = transcript.segments.first(where: { $0.text.isEmpty }) {
            throw StudioError("timing: segment \(empty.id) has no text — that is a blank caption cue")
        }
        let chapterIDs = Set(transcript.chapters.map { $0.id })
        if let orphan = transcript.segments.first(where: { !chapterIDs.contains($0.sceneId) }) {
            throw StudioError("timing: segment \(orphan.id) names scene \(orphan.sceneId), which is not a chapter")
        }
        let wordsExpected = transcript.timingSource == "provider-words"
        if let wrong = transcript.segments.first(where: { ($0.words != nil) != wordsExpected }) {
            throw StudioError("timing: segment \(wrong.id) \(wrong.words == nil ? "has no" : "has") word timings, "
                              + "but timingSource is \(transcript.timingSource)")
        }

        guard let firstInterval = coderefs.intervals.first,
              let lastInterval = coderefs.intervals.last else {
            throw StudioError("timing: the code-ref map has no intervals")
        }
        guard firstInterval.start == 0 else {
            throw StudioError(String(format: "timing: the first interval starts at %.3fs, not 0", firstInterval.start))
        }
        for (a, b) in zip(coderefs.intervals, coderefs.intervals.dropFirst()) {
            guard abs(a.end - b.start) < 0.001 else {
                throw StudioError(String(format: "timing: interval %@ ends at %.3fs but %@ starts at %.3fs",
                                         a.shotId, a.end, b.shotId, b.start))
            }
        }
        guard abs(lastInterval.end - transcript.duration) < 0.25 else {
            throw StudioError(String(format: "timing: the intervals end at %.3fs, the video at %.3fs",
                                     lastInterval.end, transcript.duration))
        }
        // The join the player relies on: every segment's shot is an interval.
        let shotIDs = Set(coderefs.intervals.map { $0.shotId })
        if let orphan = transcript.segments.first(where: { !shotIDs.contains($0.shotId) }) {
            throw StudioError("timing: segment \(orphan.id) names shot \(orphan.shotId), which has no interval")
        }
    }

    // MARK: - coderefsLookupProbe

    static func coderefsLookupProbe(_ ctx: OnboardingProbeContext) async throws {
        let store = try PackageStore(root: SelfTest.fixturePackageURL(ctx))
        let folder = "videos/\(FixturePackage.videoID)"
        let coderefs = try OnboardingJSON.decoder().decode(
            CodeRefMap.self, from: try store.readData("\(folder)/coderefs.json"))
        guard coderefs.intervals.count >= 5 else {
            throw StudioError("coderefsLookupProbe: only \(coderefs.intervals.count) interval(s)")
        }

        // Before the first frame there is nothing on screen.
        guard coderefs.lookup(-0.5) == nil else {
            throw StudioError("coderefsLookupProbe: a negative time resolved to a shot")
        }
        // Every interval answers at its start, its middle and just before its end.
        for interval in coderefs.intervals {
            let middle = (interval.start + interval.end) / 2
            let beforeEnd = interval.end - 0.001
            for (label, t) in [("start", interval.start), ("middle", middle), ("end-", beforeEnd)] {
                guard let found = coderefs.lookup(t), found.shotId == interval.shotId else {
                    let got = coderefs.lookup(t)?.shotId ?? "nothing"
                    throw StudioError(String(format: "coderefsLookupProbe: at the %@ of %@ (%.3fs) the map "
                                             + "returned %@", label, interval.shotId, t, got))
                }
            }
        }
        // A boundary belongs to the shot that is starting, matching what a viewer sees
        // after seeking to a chapter.
        if coderefs.intervals.count >= 2 {
            let second = coderefs.intervals[1]
            guard coderefs.lookup(second.start)?.shotId == second.shotId else {
                throw StudioError("coderefsLookupProbe: the boundary at \(second.start) resolved to the "
                                  + "previous shot, not \(second.shotId)")
            }
        }
        // Past the end the player is parked on the last frame, still in the last shot.
        let last = coderefs.intervals[coderefs.intervals.count - 1]
        guard coderefs.lookup(last.end + 30)?.shotId == last.shotId else {
            throw StudioError("coderefsLookupProbe: a time past the end did not resolve to the last shot")
        }

        // The companion card's chip: a code shot offers the highlighted range.
        guard let codeShot = coderefs.intervals.first(where: { $0.sceneType == "code" }),
              let primary = codeShot.primaryAnchor,
              case .code(_, _, let lines)? = try? Anchor.parse(primary),
              lines != nil else {
            throw StudioError("coderefsLookupProbe: no code shot offers a line-ranged anchor to click")
        }

        // "Follow along" asks which files to open across a chapter.
        let spanning = coderefs.intervals(from: 0, to: last.end)
        guard spanning.count == coderefs.intervals.count else {
            throw StudioError("coderefsLookupProbe: a full-length window returned \(spanning.count) of "
                              + "\(coderefs.intervals.count) intervals")
        }

        print("selftest: coderefsLookupProbe OK (\(coderefs.intervals.count) intervals; boundaries, "
              + "overruns and the click target all resolve)")
    }

    // MARK: - linkRouterProbe

    static func linkRouterProbe(_ ctx: OnboardingProbeContext) async throws {
        let store = try PackageStore(root: SelfTest.fixturePackageURL(ctx))
        let packet = try PacketReader.load(store.url("packet"))
        let router = LinkRouter(store: store, headSHA: FixtureRepoFacts.headSHA,
                                factIDs: Set(packet.factIDs))

        // Every anchor the package names, from every direction a reader can arrive.
        let script = try OnboardingJSON.decoder().decode(
            VideoScript.self, from: try store.readData("videos/\(FixturePackage.videoID)/script.json"))
        let index = try BacklinkIndex.load(from: store)
        let coderefs = try OnboardingJSON.decoder().decode(
            CodeRefMap.self, from: try store.readData("videos/\(FixturePackage.videoID)/coderefs.json"))

        var anchors = script.allAnchors
        anchors += Array(index.byAnchor.keys)
        anchors += coderefs.intervals.flatMap { $0.anchors }
        anchors += packet.traces.values.flatMap { $0.hops.map { $0.anchor } }
        anchors += packet.facts.filter { $0.status != "refuted" }.flatMap { $0.evidence.map { $0.anchor } }

        let failures = router.audit(anchors)
        guard failures.isEmpty else {
            let shown = failures.prefix(4).map { $0.description }.joined(separator: "\n      ")
            throw StudioError("linkRouterProbe: \(failures.count) of \(Set(anchors).count) anchor(s) dangle:\n"
                              + "      " + shown)
        }

        // Each kind routes to the destination the player expects.
        guard case .success(.code(let path, let lines)) =
                router.resolve("code:src/auth/authz.py@\(FixtureRepoFacts.headSHA.prefix(7))#L8-L10"),
              path == "src/auth/authz.py", lines == 8...10 else {
            throw StudioError("linkRouterProbe: a code anchor did not route to its file and range")
        }
        guard case .success(.page(let docPath, let fragment)) = router.resolve("doc:architecture#entry-points"),
              docPath == "docs/architecture.html", fragment == "entry-points" else {
            throw StudioError("linkRouterProbe: a doc anchor did not route to its page and section")
        }
        guard case .success(.diagram(let diagramID, let node)) = router.resolve("diagram:c4-container#d_src_repo"),
              diagramID == "c4-container", node == "d_src_repo" else {
            throw StudioError("linkRouterProbe: a diagram anchor did not route to its node")
        }

        // And a broken one is reported by kind, not swallowed.
        let broken: [(String, String)] = [
            ("code:src/api/nope.py@\(FixtureRepoFacts.headSHA.prefix(7))#L1-L2", "code"),
            ("doc:not-a-register#top", "doc"),
            ("diagram:c4-container#no_such_node", "diagram"),
            ("trace:order-creation#hop999", "trace"),
            ("fact:F-does-not-exist", "fact"),
        ]
        for (anchor, kind) in broken {
            guard case .failure(let failure) = router.resolve(anchor) else {
                throw StudioError("linkRouterProbe: \(anchor) resolved, but nothing in the package matches it")
            }
            guard failure.kind == kind else {
                throw StudioError("linkRouterProbe: \(anchor) failed as kind \(failure.kind), expected \(kind)")
            }
        }
        // A right-looking anchor pinned to the wrong commit is a dangling link too.
        guard case .failure(let stale) = router.resolve("code:src/auth/authz.py@0000000#L8-L10"),
              stale.reason.contains("0000000") else {
            throw StudioError("linkRouterProbe: an anchor pinned to another commit was accepted")
        }

        print("selftest: linkRouterProbe OK (\(Set(anchors).count) anchors resolve; "
              + "\(broken.count + 1) broken ones reported by kind)")
    }

    // MARK: - backlinkIndexProbe

    static func backlinkIndexProbe(_ ctx: OnboardingProbeContext) async throws {
        let store = try PackageStore(root: SelfTest.fixturePackageURL(ctx))
        let index = try BacklinkIndex.load(from: store)
        guard index.anchorCount >= 100 else {
            throw StudioError("backlinkIndexProbe: the index has \(index.anchorCount) anchor(s); "
                              + "the fixture packet cites far more")
        }

        // The question the code view asks: where is this file covered? Anchors carry
        // line ranges, so an exact-key lookup would find almost nothing — the probe
        // exists because that is the easy way to get this wrong.
        let hotspot = FixtureRepoFacts.hotspotPath
        let references = index.references(forPath: hotspot)
        guard references.count >= 2 else {
            throw StudioError("backlinkIndexProbe: \(hotspot) is covered by \(references.count) deliverable(s); "
                              + "it is the fixture's hotspot and appears in a trace and a register")
        }
        guard Set(references.map { $0.ref }).count == references.count else {
            throw StudioError("backlinkIndexProbe: \(hotspot) has duplicate references — the de-duplication failed")
        }
        let kinds = Set(references.map { $0.kind })
        guard kinds.contains("trace") || kinds.contains("doc") else {
            throw StudioError("backlinkIndexProbe: \(hotspot) is cited only by \(kinds.sorted().joined(separator: ", "))")
        }
        // Every reference points at something the router can open.
        let router = LinkRouter(store: store, headSHA: FixtureRepoFacts.headSHA)
        let unreachable = router.audit(references.map { $0.ref })
        guard unreachable.isEmpty else {
            throw StudioError("backlinkIndexProbe: \(unreachable.count) backlink(s) from \(hotspot) do not "
                              + "resolve: \(unreachable.prefix(3).map { $0.description }.joined(separator: "; "))")
        }
        // Every path the index knows is a path whose source travelled with the package.
        let missing = index.coveredPaths.filter { path in
            !path.hasSuffix("/") && !store.exists("code/\(path).json")
        }
        guard missing.isEmpty else {
            throw StudioError("backlinkIndexProbe: \(missing.count) covered path(s) have no source in the "
                              + "package: \(missing.prefix(4).joined(separator: ", "))")
        }

        print("selftest: backlinkIndexProbe OK (\(index.anchorCount) anchors, \(index.coveredPaths.count) "
              + "covered paths; \(hotspot) cited by \(references.count) deliverables)")
    }
}
