import Foundation

/// Checks a video script against the package before a single frame is drawn.
///
/// A dangling anchor found after a twelve-minute render is a wasted render, and a shot
/// that silently renders an empty panel is worse: it ships. Everything here is cheap —
/// file existence, anchor resolution, id shape — and it runs on every build.
enum ScriptValidator {

    struct Problem: Equatable, CustomStringConvertible {
        /// The shot or scene it belongs to, for a message that names a place.
        var at: String
        var message: String
        /// A warning does not stop the render; an error does.
        var isError: Bool

        var description: String { "\(at): \(message)" }
    }

    struct Report: Equatable {
        var problems: [Problem] = []
        /// Seconds the script is expected to run, from the narrator's own estimate.
        var estimatedSeconds: Double = 0
        var shotCount: Int = 0

        var errors: [Problem] { problems.filter { $0.isError } }
        var warnings: [Problem] { problems.filter { !$0.isError } }
        var ok: Bool { errors.isEmpty }

        var summary: String {
            let minutes = Int((estimatedSeconds / 60).rounded())
            return "\(shotCount) shots, about \(max(1, minutes)) min, "
                + "\(errors.count) error(s), \(warnings.count) warning(s)"
        }
    }

    /// `narrator` supplies the runtime estimate, so the number matches what will
    /// actually be synthesized rather than a second guess at speaking rate.
    static func validate(_ script: VideoScript, router: LinkRouter,
                         narrator: ToneNarrator = ToneNarrator()) -> Report {
        var report = Report()
        var problems: [Problem] = []

        if script.id.isEmpty { problems.append(Problem(at: "script", message: "has no id", isError: true)) }
        if script.title.isEmpty {
            problems.append(Problem(at: script.id, message: "has no title", isError: true))
        }
        if script.sha.isEmpty {
            problems.append(Problem(at: script.id, message: "is not pinned to a commit", isError: true))
        } else if script.sha != router.sha7 {
            problems.append(Problem(at: script.id,
                                    message: "is pinned to \(script.sha) but the package is at \(router.sha7)",
                                    isError: true))
        }
        if script.scenes.isEmpty {
            problems.append(Problem(at: script.id, message: "has no scenes", isError: true))
        }

        var sceneIDs = Set<String>()
        var shotIDs = Set<String>()
        for scene in script.scenes {
            if !sceneIDs.insert(scene.id).inserted {
                problems.append(Problem(at: scene.id, message: "is a duplicate scene id", isError: true))
            }
            if scene.title.isEmpty {
                problems.append(Problem(at: scene.id, message: "has no title, so its chapter has no name",
                                        isError: true))
            }
            if scene.shots.isEmpty {
                problems.append(Problem(at: scene.id, message: "has no shots", isError: true))
            }
            if let docAnchor = scene.docAnchor {
                problems.append(contentsOf: check(docAnchor, at: scene.id, router: router))
            }

            for shot in scene.shots {
                if !shotIDs.insert(shot.id).inserted {
                    problems.append(Problem(at: shot.id, message: "is a duplicate shot id", isError: true))
                }
                // The join between the transcript and the code-ref map is by shot id, and
                // a reader debugging a desync should be able to see which scene it is in.
                if !shot.id.hasPrefix(scene.id) {
                    problems.append(Problem(at: shot.id,
                                            message: "does not start with its scene id (\(scene.id))",
                                            isError: false))
                }
                if !CodeRefInterval.sceneTypes.contains(shot.sceneType) {
                    problems.append(Problem(at: shot.id,
                                            message: "has an unknown scene type \"\(shot.sceneType)\"; "
                                                + "known: \(CodeRefInterval.sceneTypes.joined(separator: ", "))",
                                            isError: true))
                }
                if shot.narration.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   shot.sceneType != "title" {
                    problems.append(Problem(at: shot.id,
                                            message: "has no narration, so it plays as silence",
                                            isError: false))
                }
                if shot.pad < 0 {
                    problems.append(Problem(at: shot.id, message: "has a negative pad", isError: true))
                }

                for anchor in shot.anchors {
                    problems.append(contentsOf: check(anchor, at: shot.id, router: router))
                }
                if let highlight = shot.highlight {
                    problems.append(contentsOf: check(highlight.anchor, at: shot.id, router: router))
                    problems.append(contentsOf: checkHighlight(highlight.anchor, shot: shot))
                }
                if let cmd = shot.cmd {
                    problems.append(contentsOf: check(cmd, at: shot.id, router: router))
                }
                problems.append(contentsOf: checkKind(shot, at: shot.id, router: router))

                report.shotCount += 1
                report.estimatedSeconds += narrator.estimatedDuration(of: shot.narration) + max(0, shot.pad)
            }
        }

        report.problems = problems
        return report
    }

    // MARK: - Individual checks

    private static func check(_ anchor: String, at place: String, router: LinkRouter) -> [Problem] {
        if case .failure(let failure) = router.resolve(anchor) {
            return [Problem(at: place, message: "\(failure.reason) (\(anchor))", isError: true)]
        }
        return []
    }

    /// The highlight must sit inside what the panel shows, or the band lands off screen
    /// and the shot points at nothing.
    private static func checkHighlight(_ anchor: String, shot: VideoScript.Shot) -> [Problem] {
        guard let parsed = try? Anchor.parse(anchor),
              case .code(_, _, let lines) = parsed, let lines else {
            return [Problem(at: shot.id,
                            message: "the highlight anchor names no line range, so nothing is banded",
                            isError: false)]
        }
        guard let visible = shot.visibleLines, visible.count >= 2 else { return [] }
        guard visible[0] <= lines.lowerBound, lines.upperBound <= visible[1] else {
            return [Problem(at: shot.id,
                            message: "highlights lines \(lines.lowerBound)-\(lines.upperBound) but shows "
                                + "\(visible[0])-\(visible[1]), so the band falls outside the panel",
                            isError: true)]
        }
        return []
    }

    /// What each scene kind needs in order to render something other than an empty panel.
    private static func checkKind(_ shot: VideoScript.Shot, at place: String,
                                  router: LinkRouter) -> [Problem] {
        switch shot.sceneType {
        case "code":
            let hasCode = shot.anchors.contains { $0.hasPrefix("code:") }
                || (shot.highlight?.anchor.hasPrefix("code:") ?? false)
            guard hasCode else {
                return [Problem(at: place, message: "is a code scene with no code: anchor to show",
                                isError: true)]
            }
            if let visible = shot.visibleLines, visible.count >= 2, visible[0] > visible[1] {
                return [Problem(at: place,
                                message: "visibleLines runs backwards (\(visible[0]) to \(visible[1]))",
                                isError: true)]
            }
        case "diagram":
            guard let diagram = shot.diagram, !diagram.isEmpty else {
                return [Problem(at: place, message: "is a diagram scene that names no diagram",
                                isError: true)]
            }
            for node in shot.focusNodes ?? [] {
                if case .failure(let failure) = router.resolve("diagram:\(diagram)#\(node)") {
                    return [Problem(at: place, message: failure.reason, isError: true)]
                }
            }
        case "terminal":
            guard shot.cmd != nil else {
                return [Problem(at: place, message: "is a terminal scene with no cmd: anchor to replay",
                                isError: true)]
            }
        default:
            break
        }
        return []
    }

    /// "3 error(s): s02a: … ; s03a: …" — the shape the pipeline notice and the probe both use.
    static func message(for report: Report) -> String {
        guard !report.ok else { return report.summary }
        let shown = report.errors.prefix(3).map { $0.description }
        var detail = shown.joined(separator: "; ")
        if report.errors.count > shown.count { detail += "; and \(report.errors.count - shown.count) more" }
        return "the script has \(report.errors.count) error(s): \(detail)"
    }
}
