import Foundation
import AVFoundation
import CoreGraphics

/// Script in, video out: validate, narrate, render every shot, mux, and write the three
/// timing files beside the mp4.
///
/// One place owns the order of those steps, because the order is where the bugs are.
/// The audio is synthesized first so the timeline is laid out from measured clip
/// lengths rather than estimates; the mp4's own duration is measured afterwards and the
/// timing files are stretched to it, so a caption never ends before the video does
/// (the desync CLAUDE.md lists as a known limitation of the walkthrough path).
@MainActor
enum VideoAssembler {

    struct Options {
        var size = CGSize(width: 1920, height: 1080)
        var voiceID = ""
        var modelID = ""
        /// Named in the audio cache key, so switching narrators re-synthesizes rather
        /// than playing yesterday's voice under today's script.
        var narratorName = "tone"
        var theme = BrandTheme()
        /// Diagrams are rendered once per video and reused across shots.
        var renderDiagrams = true

        init() {}
    }

    struct Built {
        var transcript: TranscriptDoc
        var coderefs: CodeRefMap
        var duration: Double
        var shotCount: Int
        var reusedClips: Int
        var prunedClips: [String]
        /// Things that degraded rather than failed — the house rule for a pipeline
        /// stage, so one unrenderable diagram never costs a twelve-minute walk.
        var notices: [String] = []
    }

    static func build(script: VideoScript, into store: PackageStore, repo: URL?,
                      narrator: Narrating, options: Options = Options(),
                      git: GitRunner = GitRunner()) async throws -> Built {
        var notices: [String] = []
        let folder = "videos/\(script.id)"

        // 1. Refuse a script that names something the package does not have, before
        //    anything expensive happens.
        let router = LinkRouter(store: store, headSHA: script.sha)
        let report = ScriptValidator.validate(script, router: router)
        guard report.ok else {
            throw StudioError("VideoAssembler: \(ScriptValidator.message(for: report))")
        }
        notices.append(contentsOf: report.warnings.map { $0.description })

        // 2. Narration, cached by content.
        let cache = AudioCache(store: store, videoID: script.id)
        var clips: [String: NarrationClip] = [:]
        var narrationURLs: [String: URL] = [:]
        var reused = 0
        for (_, shot) in script.shots {
            let result = try await cache.clip(for: shot, voice: options.voiceID,
                                              model: options.modelID, narrator: narrator,
                                              narratorName: options.narratorName)
            clips[shot.id] = result.clip
            narrationURLs[shot.id] = result.url
            if result.reused { reused += 1 }
        }
        let pruned = try cache.prune(keeping: Set(script.shots.map { $0.shot.id }))

        // 3. The timeline, from measured clips.
        let timeline = TranscriptBuilder.timeline(for: script, clips: clips)
        let output = try TranscriptBuilder.build(script: script, timeline: timeline)

        // 4. One rendered still per shot.
        let renderer = BrandedRenderer()
        var diagrams: [String: String] = [:]
        var frames: [(image: CGImage, hold: Double)] = []
        for (entry, pair) in zip(timeline, script.shots) {
            var input = try await sceneInput(for: pair.shot, scene: pair.scene, script: script,
                                             store: store, repo: repo, git: git,
                                             options: options, diagrams: &diagrams,
                                             notices: &notices)
            input.size = options.size
            let html = try SceneRenderer.html(for: input)
            let image = try await renderer.render(html: html,
                                                  pixelWidth: Int(options.size.width.rounded()),
                                                  pixelHeight: Int(options.size.height.rounded()))
            guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                throw StudioError("VideoAssembler: shot \(pair.shot.id) did not rasterize.")
            }
            frames.append((cg, entry.duration))
        }

        // 5. Stills track, then the mux. The segments tile, so there is no gap for
        //    `assembleNarratedVideo` to have to fill with silence.
        let stills = store.url("\(folder)/stills.mp4")
        try await StillsVideoWriter.write(frames: frames, size: options.size, to: stills)
        let segments = timeline.map { entry in
            VideoService.ExportSegment(sourceStart: entry.start, duration: entry.duration,
                                       narrationURL: narrationURLs[entry.shotID])
        }
        let videoURL = store.url("\(folder)/video.mp4")
        try await VideoService.assembleNarratedVideo(videoURL: stills, segments: segments,
                                                     keepOriginalAudio: false, outputURL: videoURL)

        // 6. The mp4 is the authority on duration; the timing files follow it.
        let measured = try await AVURLAsset(url: videoURL).load(.duration).seconds
        var transcript = output.transcript
        var coderefs = output.coderefs
        if measured.isFinite, measured > 0, abs(measured - transcript.duration) > 0.01 {
            transcript = VideoAssembler.retimed(transcript, to: measured)
            coderefs = VideoAssembler.retimed(coderefs, to: measured)
        }
        try store.writeJSON(transcript, to: "\(folder)/\(TranscriptDoc.fileName)")
        try store.writeJSON(coderefs, to: "\(folder)/\(CodeRefMap.fileName)")
        try store.writeJSON(transcript.chapters, to: "\(folder)/chapters.json")
        try store.writeAtomically(VideoDocsCaptions.srt(transcript), to: "\(folder)/captions.srt")
        try store.writeAtomically(VideoDocsCaptions.vtt(transcript), to: "\(folder)/captions.vtt")
        try store.writeAtomically(VideoDocsCaptions.chaptersVTT(transcript), to: "\(folder)/chapters.vtt")
        try store.writeJSON(script, to: "\(folder)/\(VideoScript.fileName)")

        return Built(transcript: transcript, coderefs: coderefs, duration: transcript.duration,
                     shotCount: timeline.count, reusedClips: reused, prunedClips: pruned,
                     notices: notices)
    }

    /// `StillsVideoWriter` appends a trailing hold so the asset is never shorter than
    /// the sum of the shots, which makes the mp4 slightly longer than the timeline.
    /// Rather than let the last caption end before the video does — the desync
    /// CLAUDE.md lists as a known limitation of the walkthrough path — the final
    /// segment, chapter and interval stretch to the measured end.
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

    // MARK: - Gathering what a shot shows

    /// Reads whatever the shot's kind needs: the source at the pinned commit for code,
    /// a rendered diagram for a diagram, the recorded output for a terminal.
    ///
    /// Anything missing degrades to a notice. A shot that cannot find its source still
    /// renders — as a card carrying its narration — because a hole in the middle of a
    /// walk is worse than a plainer frame.
    static func sceneInput(for shot: VideoScript.Shot, scene: VideoScript.Scene,
                           script: VideoScript, store: PackageStore, repo: URL?,
                           git: GitRunner, options: Options,
                           diagrams: inout [String: String],
                           notices: inout [String]) async throws -> SceneRenderer.Input {
        var input = SceneRenderer.Input(shot: shot, scene: scene, sha7: script.sha,
                                        theme: options.theme, size: options.size)
        input.subtitle = script.summary

        switch shot.sceneType {
        case "code":
            let anchor = shot.highlight?.anchor ?? shot.anchors.first { $0.hasPrefix("code:") }
            guard let anchor, let path = ProjectionSupport.codePath(anchor) else {
                notices.append("\(shot.id): no code anchor, so it renders as a card")
                input.shot.sceneType = "card"
                return input
            }
            input.path = path
            if let text = try? await source(at: path, sha: script.sha, store: store,
                                            repo: repo, git: git) {
                input.sourceLines = text.components(separatedBy: "\n")
                // A trailing newline is not a line, and shown as one it looks like the
                // file ends in a blank.
                if input.sourceLines.last == "" { input.sourceLines.removeLast() }
            } else {
                notices.append("\(shot.id): \(path) is not in the package at \(script.sha); "
                               + "the shot renders as a card")
                input.shot.sceneType = "card"
            }

        case "diagram":
            guard options.renderDiagrams, let id = shot.diagram, !id.isEmpty else {
                input.shot.sceneType = "card"
                return input
            }
            if diagrams[id] == nil {
                for relative in ["diagrams/\(id).mmd", "traces/\(id).mmd"] where store.exists(relative) {
                    do {
                        let source = try store.readString(relative)
                        diagrams[id] = try await MermaidRenderer().render(mermaid: source,
                                                                          theme: options.theme)
                    } catch {
                        let reason = (error as? StudioError)?.message ?? error.localizedDescription
                        notices.append("\(shot.id): the \(id) diagram did not render (\(reason))")
                    }
                    break
                }
            }
            if let svg = diagrams[id] {
                input.diagramSVG = MermaidRenderer.focus(svg, nodes: shot.focusNodes ?? [])
            } else {
                input.shot.sceneType = "card"
            }

        case "terminal":
            if let cmd = shot.cmd, let recorded = try? store.readString("units/\(cmd).txt") {
                input.terminal = terminalLines(recorded)
            } else {
                notices.append("\(shot.id): no recorded output for \(shot.cmd ?? "its command")")
                input.shot.sceneType = "card"
            }

        default:
            break
        }

        if input.shot.sceneType == "card" || input.shot.sceneType == "title" {
            input.claim = shot.narration
            input.kicker = scene.title
            input.evidence = shot.anchors
        }
        return input
    }

    /// The file at the pinned commit: from the package's own copy when it travelled
    /// with it, otherwise from the checkout. A package shared as a folder has no git
    /// beside it, which is why `code/` exists.
    static func source(at path: String, sha: String, store: PackageStore,
                       repo: URL?, git: GitRunner) async throws -> String {
        let relative = "code/\(path).json"
        if store.exists(relative),
           let data = try? store.readData(relative),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let lines = object["lines"] as? [String] {
            return lines.joined(separator: "\n")
        }
        guard let repo else {
            throw StudioError("no copy of \(path) in the package and no checkout to read it from")
        }
        return try await git.show(sha: sha, path: path, repo: repo)
    }

    /// `$ cmd` lines are commands, lines a recorder marked with `!` are problems, the
    /// rest is output.
    static func terminalLines(_ recorded: String) -> [SceneRenderer.TerminalLine] {
        recorded.components(separatedBy: "\n").map { line in
            if line.hasPrefix("$ ") {
                return SceneRenderer.TerminalLine(kind: .command, text: String(line.dropFirst(2)))
            }
            if line.hasPrefix("! ") {
                return SceneRenderer.TerminalLine(kind: .problem, text: String(line.dropFirst(2)))
            }
            return SceneRenderer.TerminalLine(kind: .output, text: line)
        }
    }
}
