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
        /// Shots that degraded rather than failed — an unrenderable diagram, a missing
        /// source file. Empty for a healthy fixture build, and the probe asserts that.
        var notices: [String] = []
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
        // The assembler writes script.json itself, after validating it against the
        // package — a script that names something the package lacks never gets saved
        // as if it were buildable.
        let video = try await renderVideo(script: script, narrator: narrator, repo: repo,
                                          into: store, git: git)

        try updateManifest(in: store, script: script, transcript: video.transcript,
                           projection: projection)

        return Built(store: store, script: script, transcript: video.transcript,
                     coderefs: video.coderefs, projection: projection,
                     codeFiles: code.written.count, notices: video.notices)
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

    /// Everything about turning a script into a video lives in `VideoAssembler`; this
    /// only says which script, at what size. When the fixture and the real path render
    /// differently, the fixture stops being evidence.
    static func renderVideo(script: VideoScript, narrator: Narrating, repo: URL?,
                            into store: PackageStore,
                            git: GitRunner = GitRunner()) async throws -> VideoAssembler.Built {
        var options = VideoAssembler.Options()
        options.size = frameSize
        options.narratorName = "tone"
        return try await VideoAssembler.build(script: script, into: store, repo: repo,
                                              narrator: narrator, options: options, git: git)
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
