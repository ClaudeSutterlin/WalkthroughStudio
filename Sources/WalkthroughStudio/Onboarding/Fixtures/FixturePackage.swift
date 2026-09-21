import Foundation
import AVFoundation
import CoreGraphics

/// Builds a complete, playable onboarding package from the checked-in fixture packet
/// and a handwritten script — no network, no API key, no model.
///
/// It exists so the player can be built and demonstrated before any of the generating
/// machinery is: the package it produces has every file the player reads (projected
/// deliverables, a real mp4 with a real audio track, the three timing files, the
/// backlink index, the cited sources at the pinned commit), so a bug in the player is a
/// bug in the player rather than a missing input.
///
/// The scenes are drawn from the fixture repository's actual findings, and every anchor
/// in the script resolves — `linkRouterProbe` walks them, and a fixture whose links
/// dangled would teach the player to tolerate dangling links.
enum FixturePackage {

    static let videoID = "architecture"
    /// 1280x720: the player's stage at its minimum width, and small enough that the
    /// probe's render is a second rather than a minute.
    static let frameSize = CGSize(width: 1280, height: 720)

    struct Built {
        var store: PackageStore
        var script: VideoScript
        var transcript: TranscriptDoc
        var coderefs: CodeRefMap
        var projection: PackageProjector.Result
        var codeFiles: Int
    }

    /// Imports the packet, projects every deliverable, renders the video and writes the
    /// timing files. `repo` is a checkout at the packet's head SHA (the fixture repo
    /// from `scripts/make-fixture-repo.sh`).
    @discardableResult
    static func make(packet packetURL: URL, repo: URL, into root: URL,
                     narrator: Narrating = ToneNarrator(),
                     git: GitRunner = GitRunner()) async throws -> Built {
        let store = try PackageStore(root: root)
        try await PacketImporter.importPacket(at: packetURL, into: store, repo: repo, git: git)
        let packet = try PacketReader.load(store.url("packet"))

        let projection = try PackageProjector.project(packet: packet, into: store)
        let code = try await PackageProjector.emitCode(packet: packet, into: store,
                                                       repo: repo, git: git)
        LinkRouter.invalidateCache(for: store.root)

        let script = FixturePackage.script(sha: packet.sha7)
        try store.writeJSON(script, to: "videos/\(videoID)/\(VideoScript.fileName)")

        let video = try await renderVideo(script: script, narrator: narrator, into: store)

        try updateManifest(in: store, script: script, transcript: video.transcript,
                           projection: projection)

        return Built(store: store, script: script, transcript: video.transcript,
                     coderefs: video.coderefs, projection: projection,
                     codeFiles: code.written.count)
    }

    // MARK: - The script

    /// A five-scene walk through the order path, every claim taken from a fact the
    /// packet carries and every anchor pinned to `sha`.
    static func script(sha: String) -> VideoScript {
        VideoScript(
            id: videoID,
            title: "Start here: the order service",
            summary: "A fifteen-file Python order service: two HTTP handlers, an authorization "
                + "module that checks a header against a constant, a service that sums line items, "
                + "and a repository that opens a connection per request and never closes it. "
                + "Five minutes on what it does and where it bites.",
            sha: sha,
            scenes: [
                VideoScript.Scene(
                    id: "s01", title: "What this is",
                    docAnchor: "doc:architecture#architecture",
                    shots: [
                        VideoScript.Shot(
                            id: "s01a", sceneType: "title",
                            narration: "This is a fifteen file Python order service. "
                                + "Two handlers, one authorization module, one service, one repository.",
                            anchors: ["code:README.md@\(sha)"],
                            caption: "The order service")
                    ]),
                VideoScript.Scene(
                    id: "s02", title: "Creating an order",
                    docAnchor: "doc:architecture#entry-points",
                    shots: [
                        VideoScript.Shot(
                            id: "s02a", sceneType: "code",
                            narration: "Creating an order starts here. The handler takes the user id "
                                + "straight out of the request body and passes it down.",
                            anchors: ["code:src/api/orders_handler.py@\(sha)#L6-L11"],
                            highlight: CodeRefHighlight(
                                anchor: "code:src/api/orders_handler.py@\(sha)#L6-L11",
                                callout: "user_id comes from the body, not from the caller's identity"),
                            visibleLines: [1, 30],
                            caption: "handle_create_order")
                    ]),
                VideoScript.Scene(
                    id: "s03", title: "The authorization that isn't",
                    docAnchor: "doc:security-posture#findings",
                    shots: [
                        VideoScript.Shot(
                            id: "s03a", sceneType: "code",
                            narration: "Authorization is three lines. It compares a header to a string. "
                                + "Reading an order needs no credential at all.",
                            anchors: ["code:src/auth/authz.py@\(sha)#L8-L10"],
                            highlight: CodeRefHighlight(
                                anchor: "code:src/auth/authz.py@\(sha)#L8-L10",
                                callout: "a string comparison is the whole check"),
                            visibleLines: [1, 12],
                            caption: "require_user")
                    ]),
                VideoScript.Scene(
                    id: "s04", title: "Where the connections go",
                    docAnchor: "doc:tech-debt#ranked-by-severity",
                    shots: [
                        VideoScript.Shot(
                            id: "s04a", sceneType: "code",
                            narration: "The repository opens a connection in its initializer and never "
                                + "closes it. Every request leaks one.",
                            anchors: ["code:src/repo/orders_repo.py@\(sha)#L7-L9"],
                            highlight: CodeRefHighlight(
                                anchor: "code:src/repo/orders_repo.py@\(sha)#L7-L9",
                                callout: "no close, no pool, no context manager"),
                            visibleLines: [1, 20],
                            caption: "OrdersRepo.__init__")
                    ]),
                VideoScript.Scene(
                    id: "s05", title: "The shape of it",
                    docAnchor: "doc:architecture#containers",
                    shots: [
                        VideoScript.Shot(
                            id: "s05a", sceneType: "diagram",
                            narration: "Four source directories, one database, and a deploy script "
                                + "that never runs a migration.",
                            anchors: ["diagram:c4-container#d_src_repo"],
                            diagram: "c4-container",
                            focusNodes: ["d_src_api", "d_src_repo", "d_db"],
                            caption: "Containers")
                    ]),
            ])
    }

    // MARK: - Rendering

    struct RenderedVideo {
        var transcript: TranscriptDoc
        var coderefs: CodeRefMap
        var duration: Double
    }

    /// Narrate every shot, lay them end to end, write the stills track, mux the audio in
    /// and write the three timing files beside the mp4.
    static func renderVideo(script: VideoScript, narrator: Narrating,
                            into store: PackageStore) async throws -> RenderedVideo {
        let folder = "videos/\(script.id)"
        let audioDir = store.url("\(folder)/audio")
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)

        var clips: [String: NarrationClip] = [:]
        var narrationURLs: [String: URL] = [:]
        for (_, shot) in script.shots {
            let url = audioDir.appendingPathComponent("\(shot.id).wav")
            clips[shot.id] = try await narrator.synthesize(shot.narration, to: url)
            narrationURLs[shot.id] = url
        }

        let timeline = TranscriptBuilder.timeline(for: script, clips: clips)
        let output = try TranscriptBuilder.build(script: script, timeline: timeline)

        // Stills: one frame per shot, held for the shot's whole slice. The colours are
        // distinct per scene type so a probe can pixel-check which shot a frame belongs
        // to; M5's SceneRenderer replaces this with the real templates.
        var frames: [(image: CGImage, hold: Double)] = []
        for (entry, pair) in zip(timeline, script.shots) {
            frames.append((StillsVideoWriter.solidFrame(color: colour(forSceneType: pair.shot.sceneType),
                                                        size: frameSize),
                           entry.duration))
        }
        let stills = store.url("\(folder)/stills.mp4")
        try await StillsVideoWriter.write(frames: frames, size: frameSize, to: stills)

        // The muxer needs contiguous audio segments; the timeline already tiles, and
        // every shot has a clip, so there is no gap to fill.
        let segments = timeline.map { entry in
            VideoService.ExportSegment(sourceStart: entry.start, duration: entry.duration,
                                       narrationURL: narrationURLs[entry.shotID])
        }
        let videoURL = store.url("\(folder)/video.mp4")
        try await VideoService.assembleNarratedVideo(
            videoURL: stills, segments: segments, keepOriginalAudio: false, outputURL: videoURL)

        // The mp4 is the authority on duration: the timing files must agree with what a
        // player will actually scrub, not with what the builder intended.
        let measured = try await AVURLAsset(url: videoURL).load(.duration).seconds
        var transcript = output.transcript
        var coderefs = output.coderefs
        if measured.isFinite, measured > 0, abs(measured - transcript.duration) > 0.01 {
            transcript = retimed(transcript, to: measured)
            coderefs = retimed(coderefs, to: measured)
        }

        try store.writeJSON(transcript, to: "\(folder)/\(TranscriptDoc.fileName)")
        try store.writeJSON(coderefs, to: "\(folder)/\(CodeRefMap.fileName)")
        try store.writeJSON(transcript.chapters, to: "\(folder)/chapters.json")
        try store.writeAtomically(VideoDocsCaptions.srt(transcript), to: "\(folder)/captions.srt")
        try store.writeAtomically(VideoDocsCaptions.vtt(transcript), to: "\(folder)/captions.vtt")
        try store.writeAtomically(VideoDocsCaptions.chaptersVTT(transcript), to: "\(folder)/chapters.vtt")

        return RenderedVideo(transcript: transcript, coderefs: coderefs, duration: transcript.duration)
    }

    /// `StillsVideoWriter` appends a trailing hold so the asset is never shorter than
    /// the sum of the shots, which makes the mp4 a little longer than the timeline.
    /// Rather than let the last caption end before the video does — the desync CLAUDE.md
    /// lists as a known limitation of the walkthrough path — the final segment and the
    /// final interval are stretched to the measured end.
    static func retimed(_ transcript: TranscriptDoc, to duration: Double) -> TranscriptDoc {
        var out = transcript
        out.duration = duration
        if !out.segments.isEmpty { out.segments[out.segments.count - 1].end = duration }
        if !out.chapters.isEmpty { out.chapters[out.chapters.count - 1].end = duration }
        return out
    }

    static func retimed(_ coderefs: CodeRefMap, to duration: Double) -> CodeRefMap {
        var out = coderefs
        if !out.intervals.isEmpty { out.intervals[out.intervals.count - 1].end = duration }
        return out
    }

    /// Distinct per scene type, from the brand palette, so a probe can tell from one
    /// pixel which kind of shot a frame is.
    static func colour(forSceneType type: String) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        switch type {
        case "title":    return (0.855, 0.310, 0.271)   // coral   #DA4F45
        case "code":     return (0.102, 0.086, 0.071)   // charcoal #1A1612
        case "diagram":  return (1.000, 0.984, 0.961)   // cream   #FFFBF5
        case "terminal": return (0.000, 0.000, 0.000)
        case "table":    return (1.000, 0.690, 0.533)   // peach   #FFB088
        default:         return (0.600, 0.600, 0.600)
        }
    }

    // MARK: - Manifest

    static func updateManifest(in store: PackageStore, script: VideoScript,
                               transcript: TranscriptDoc,
                               projection: PackageProjector.Result) throws {
        var manifest = try store.readManifest()
        manifest.status = .complete
        manifest.narration.timingSource = transcript.timingSource
        manifest.narration.modelID = "tone"

        var deliverables: [OnboardingManifest.Deliverable] = []
        var order = 0
        func add(_ id: String, _ kind: DeliverableKind, _ title: String, _ path: String,
                 _ minutes: Double) {
            order += 1
            var deliverable = OnboardingManifest.Deliverable(id: id, kind: kind,
                                                             title: title, path: path)
            deliverable.minutes = minutes
            deliverable.order = order
            deliverable.status = .built
            deliverable.producedBy = "FixturePackage"
            deliverables.append(deliverable)
        }

        add("video:\(script.id)", .video, script.title,
            "videos/\(script.id)/video.mp4", transcript.duration / 60)
        for id in projection.diagramIDs {
            add("diagram:\(id)", .diagram, id.replacingOccurrences(of: "-", with: " "),
                "diagrams/\(id).mmd", 2)
        }
        for id in projection.registerIDs {
            add("doc:\(id)", .doc, id.replacingOccurrences(of: "-", with: " "), "docs/\(id).md", 3)
        }
        for id in projection.traceIDs {
            add("trace:\(id)", .trace, id.replacingOccurrences(of: "-", with: " "),
                "traces/\(id).md", 5)
        }
        manifest.deliverables = deliverables
        try store.writeManifest(manifest)
    }
}
