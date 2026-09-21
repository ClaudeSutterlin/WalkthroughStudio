import Foundation

/// A narrated code walk, before anything is rendered: scenes, shots, what each shot
/// shows and what the narrator says over it.
///
/// This is the only handwritten artifact in an onboarding package — M9 has a model
/// write it from the packet, but its shape is fixed here so the renderer, the assembler
/// and the transcript builder never have to care which produced it. Every anchor in it
/// is checked against the package before a frame is drawn (`ScriptValidator`), because
/// a dangling anchor discovered after a twelve-minute render is a wasted render.
struct VideoScript: Codable, Equatable {
    static let fileName = "script.json"

    var version: Int = PacketManifest.currentVersion
    /// `architecture`, `trace-order-creation`. Also the folder under `videos/`.
    var id: String = ""
    var title: String = ""
    /// One paragraph; becomes the transcript's summary and the chat context's header.
    var summary: String = ""
    /// The commit every anchor in the script is pinned to.
    var sha: String = ""
    var scenes: [Scene] = []

    init() {}

    init(id: String, title: String, summary: String, sha: String, scenes: [Scene]) {
        self.id = id
        self.title = title
        self.summary = summary
        self.sha = sha
        self.scenes = scenes
    }

    private enum CodingKeys: String, CodingKey { case version, id, title, summary, sha, scenes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? PacketManifest.currentVersion
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        sha = try c.decodeIfPresent(String.self, forKey: .sha) ?? ""
        scenes = try c.decodeIfPresent([Scene].self, forKey: .scenes) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(summary, forKey: .summary)
        try c.encode(sha, forKey: .sha)
        try c.encode(scenes, forKey: .scenes)
    }

    /// Every shot, in playing order, paired with the scene it belongs to.
    var shots: [(scene: Scene, shot: Shot)] {
        scenes.flatMap { scene in scene.shots.map { (scene, $0) } }
    }

    /// Every anchor the script names — what `ScriptValidator` and `linkRouterProbe` walk.
    var allAnchors: [String] {
        var out: [String] = []
        for scene in scenes {
            if let docAnchor = scene.docAnchor { out.append(docAnchor) }
            for shot in scene.shots {
                out.append(contentsOf: shot.anchors)
                if let highlight = shot.highlight { out.append(highlight.anchor) }
                if let cmd = shot.cmd { out.append(cmd) }
            }
        }
        return out
    }

    // MARK: - Scene

    struct Scene: Codable, Equatable, Identifiable {
        /// `s02`. Becomes the chapter id, so it is stable across a rebuild.
        var id: String
        var title: String
        /// The register section this scene narrates, for the "read the doc" chip.
        var docAnchor: String? = nil
        var shots: [Shot] = []

        init(id: String, title: String, docAnchor: String? = nil, shots: [Shot]) {
            self.id = id
            self.title = title
            self.docAnchor = docAnchor
            self.shots = shots
        }

        private enum CodingKeys: String, CodingKey { case id, title, docAnchor, shots }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            docAnchor = try c.decodeIfPresent(String.self, forKey: .docAnchor)
            shots = try c.decodeIfPresent([Shot].self, forKey: .shots) ?? []
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(title, forKey: .title)
            try c.encodeIfPresent(docAnchor, forKey: .docAnchor)
            try c.encode(shots, forKey: .shots)
        }
    }

    // MARK: - Shot

    /// One rendered still and the narration spoken over it. A shot is the unit of
    /// caching: change its narration or its anchors and only this shot re-renders.
    struct Shot: Codable, Equatable, Identifiable {
        /// `s02a`, prefixed by its scene so the join with the transcript is readable.
        var id: String
        /// One of `CodeRefInterval.sceneTypes`.
        var sceneType: String
        /// What the narrator says. Split into sentences for captions.
        var narration: String
        var anchors: [String] = []
        var highlight: CodeRefHighlight? = nil
        var visibleLines: [Int]? = nil
        var diagram: String? = nil
        var focusNodes: [String]? = nil
        var cmd: String? = nil
        var factIds: [String] = []
        /// Headline drawn on the still, when the scene type shows one.
        var caption: String = ""
        /// Extra seconds held after the narration ends, so a shot change never lands on
        /// the last syllable. Attributed to the shot's final sentence, never left as a
        /// gap — a gap would become a blank caption.
        var pad: Double = 0.6

        init(id: String, sceneType: String, narration: String, anchors: [String] = [],
             highlight: CodeRefHighlight? = nil, visibleLines: [Int]? = nil,
             diagram: String? = nil, focusNodes: [String]? = nil, cmd: String? = nil,
             factIds: [String] = [], caption: String = "", pad: Double = 0.6) {
            self.id = id
            self.sceneType = sceneType
            self.narration = narration
            self.anchors = anchors
            self.highlight = highlight
            self.visibleLines = visibleLines
            self.diagram = diagram
            self.focusNodes = focusNodes
            self.cmd = cmd
            self.factIds = factIds
            self.caption = caption
            self.pad = pad
        }

        private enum CodingKeys: String, CodingKey {
            case id, sceneType, narration, anchors, highlight, visibleLines, diagram,
                 focusNodes, cmd, factIds, caption, pad
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            sceneType = try c.decodeIfPresent(String.self, forKey: .sceneType) ?? "card"
            narration = try c.decodeIfPresent(String.self, forKey: .narration) ?? ""
            anchors = try c.decodeIfPresent([String].self, forKey: .anchors) ?? []
            highlight = try c.decodeIfPresent(CodeRefHighlight.self, forKey: .highlight)
            visibleLines = try c.decodeIfPresent([Int].self, forKey: .visibleLines)
            diagram = try c.decodeIfPresent(String.self, forKey: .diagram)
            focusNodes = try c.decodeIfPresent([String].self, forKey: .focusNodes)
            cmd = try c.decodeIfPresent(String.self, forKey: .cmd)
            factIds = try c.decodeIfPresent([String].self, forKey: .factIds) ?? []
            caption = try c.decodeIfPresent(String.self, forKey: .caption) ?? ""
            pad = try c.decodeIfPresent(Double.self, forKey: .pad) ?? 0.6
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(sceneType, forKey: .sceneType)
            try c.encode(narration, forKey: .narration)
            try c.encode(anchors, forKey: .anchors)
            try c.encodeIfPresent(highlight, forKey: .highlight)
            try c.encodeIfPresent(visibleLines, forKey: .visibleLines)
            try c.encodeIfPresent(diagram, forKey: .diagram)
            try c.encodeIfPresent(focusNodes, forKey: .focusNodes)
            try c.encodeIfPresent(cmd, forKey: .cmd)
            try c.encode(factIds, forKey: .factIds)
            try c.encode(caption, forKey: .caption)
            try c.encode(pad, forKey: .pad)
        }
    }
}
