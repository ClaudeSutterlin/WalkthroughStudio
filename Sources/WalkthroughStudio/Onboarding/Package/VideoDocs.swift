import Foundation

// The three timing files every onboarding video carries (ARCHITECTURE.md section 6):
// transcript.json, coderefs.json and chapters.json. One builder writes all three (D8)
// and nothing here recognizes speech — every time is derived from the timeline the
// assembler already produced.
//
// The player, the captions, the companion card and the chat context all read these, so
// the invariants matter more than the shapes: segments tile the timeline with no gaps,
// intervals cover [0, duration], and a segment and the interval on screen while it is
// spoken share a `shotId` — so "what was being said when this line was highlighted" is
// a join, not a time search.
//
// Decoding is tolerant (`decodeIfPresent` with defaults) because a package outlives the
// build that wrote it; encoding is explicit because a decode-only key silently breaks
// synthesis (CLAUDE.md, BrandTheme).

// MARK: - Transcript

struct WordTiming: Codable, Equatable {
    /// The word as spoken, without surrounding whitespace.
    var w: String
    /// Seconds from the start of the video.
    var s: Double
    var e: Double

    init(w: String, s: Double, e: Double) {
        self.w = w
        self.s = s
        self.e = e
    }

    private enum CodingKeys: String, CodingKey { case w, s, e }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        w = try c.decodeIfPresent(String.self, forKey: .w) ?? ""
        s = try c.decodeIfPresent(Double.self, forKey: .s) ?? 0
        e = try c.decodeIfPresent(Double.self, forKey: .e) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(w, forKey: .w)
        try c.encode(s, forKey: .s)
        try c.encode(e, forKey: .e)
    }
}

struct TranscriptSegment: Codable, Equatable, Identifiable {
    /// `seg-0007`, stable across a rebuild of the same script.
    var id: String
    var sceneId: String
    var shotId: String
    var start: Double
    var end: Double
    /// One sentence, as `Captions.splitSentences` cut it. Never empty — an empty segment
    /// would become a blank caption cue.
    var text: String
    /// Present exactly when `timingSource == "provider-words"`.
    var words: [WordTiming]? = nil

    init(id: String, sceneId: String, shotId: String, start: Double, end: Double,
         text: String, words: [WordTiming]? = nil) {
        self.id = id
        self.sceneId = sceneId
        self.shotId = shotId
        self.start = start
        self.end = end
        self.text = text
        self.words = words
    }

    private enum CodingKeys: String, CodingKey { case id, sceneId, shotId, start, end, text, words }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        sceneId = try c.decodeIfPresent(String.self, forKey: .sceneId) ?? ""
        shotId = try c.decodeIfPresent(String.self, forKey: .shotId) ?? ""
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        end = try c.decodeIfPresent(Double.self, forKey: .end) ?? 0
        text = try c.decodeIfPresent(String.self, forKey: .text) ?? ""
        words = try c.decodeIfPresent([WordTiming].self, forKey: .words)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(sceneId, forKey: .sceneId)
        try c.encode(shotId, forKey: .shotId)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(words, forKey: .words)
    }

    /// The words spoken by time `t`, for the "(in progress: ...)" marker the chat
    /// context puts on the segment the viewer is hearing.
    func spoken(by t: Double) -> String {
        guard let words else { return t >= end ? text : "" }
        return words.filter { $0.e <= t }.map { $0.w }.joined(separator: " ")
    }
}

struct ChapterMarker: Codable, Equatable, Identifiable {
    /// The scene id: `s02`.
    var id: String
    var title: String
    var start: Double
    var end: Double
    /// The register section this chapter narrates, when there is one.
    var docAnchor: String? = nil
    var anchors: [String] = []

    init(id: String, title: String, start: Double, end: Double,
         docAnchor: String? = nil, anchors: [String] = []) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.docAnchor = docAnchor
        self.anchors = anchors
    }

    private enum CodingKeys: String, CodingKey { case id, title, start, end, docAnchor, anchors }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        end = try c.decodeIfPresent(Double.self, forKey: .end) ?? 0
        docAnchor = try c.decodeIfPresent(String.self, forKey: .docAnchor)
        anchors = try c.decodeIfPresent([String].self, forKey: .anchors) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encodeIfPresent(docAnchor, forKey: .docAnchor)
        try c.encode(anchors, forKey: .anchors)
    }
}

struct TranscriptDoc: Codable, Equatable {
    static let fileName = "transcript.json"
    /// Allowed `timingSource` values. `provider-words` means ElevenLabs returned a
    /// character alignment; `sentence-estimate` means times were distributed by
    /// character count across the measured clip.
    static let timingSources: [String] = ["provider-words", "sentence-estimate"]

    var version: Int = PacketManifest.currentVersion
    var videoId: String = ""
    var sha: String = ""
    var duration: Double = 0
    var timingSource: String = "sentence-estimate"
    var summary: String = ""
    var chapters: [ChapterMarker] = []
    var segments: [TranscriptSegment] = []

    init() {}

    init(videoId: String, sha: String, duration: Double, timingSource: String, summary: String,
         chapters: [ChapterMarker], segments: [TranscriptSegment]) {
        self.videoId = videoId
        self.sha = sha
        self.duration = duration
        self.timingSource = timingSource
        self.summary = summary
        self.chapters = chapters
        self.segments = segments
    }

    private enum CodingKeys: String, CodingKey {
        case version, videoId, sha, duration, timingSource, summary, chapters, segments
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? PacketManifest.currentVersion
        videoId = try c.decodeIfPresent(String.self, forKey: .videoId) ?? ""
        sha = try c.decodeIfPresent(String.self, forKey: .sha) ?? ""
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        timingSource = try c.decodeIfPresent(String.self, forKey: .timingSource) ?? "sentence-estimate"
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        chapters = try c.decodeIfPresent([ChapterMarker].self, forKey: .chapters) ?? []
        segments = try c.decodeIfPresent([TranscriptSegment].self, forKey: .segments) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(videoId, forKey: .videoId)
        try c.encode(sha, forKey: .sha)
        try c.encode(duration, forKey: .duration)
        try c.encode(timingSource, forKey: .timingSource)
        try c.encode(summary, forKey: .summary)
        try c.encode(chapters, forKey: .chapters)
        try c.encode(segments, forKey: .segments)
    }

    /// The caption line on screen at `t`. Segments tile the timeline, so this is the
    /// last segment that has started.
    func segment(at t: Double) -> TranscriptSegment? {
        VideoDocs.last(in: segments, startingAtOrBefore: t, start: { $0.start })
    }

    func chapter(at t: Double) -> ChapterMarker? {
        VideoDocs.last(in: chapters, startingAtOrBefore: t, start: { $0.start })
    }

    /// Everything narrated up to `t`, which is what the playback agent is allowed to
    /// treat as already said.
    func segments(endingAtOrBefore t: Double) -> [TranscriptSegment] {
        segments.filter { $0.end <= t }
    }
}

// MARK: - Code-ref map

struct CodeRefHighlight: Codable, Equatable {
    /// The narrower `code:` anchor inside the interval's range that is banded on screen.
    var anchor: String
    var callout: String = ""

    init(anchor: String, callout: String = "") {
        self.anchor = anchor
        self.callout = callout
    }

    private enum CodingKeys: String, CodingKey { case anchor, callout }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        anchor = try c.decodeIfPresent(String.self, forKey: .anchor) ?? ""
        callout = try c.decodeIfPresent(String.self, forKey: .callout) ?? ""
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(anchor, forKey: .anchor)
        try c.encode(callout, forKey: .callout)
    }
}

struct CodeRefInterval: Codable, Equatable, Identifiable {
    /// Allowed `sceneType` values; the renderer has one template per kind.
    static let sceneTypes: [String] = ["title", "code", "diagram", "terminal", "table", "card"]

    var start: Double
    var end: Double
    var sceneId: String
    var shotId: String
    var sceneType: String
    var anchors: [String] = []
    var highlight: CodeRefHighlight? = nil
    /// First and last source line on screen, for a code scene.
    var visibleLines: [Int]? = nil
    /// The diagram id a `diagram` scene shows, and the nodes it focuses.
    var diagram: String? = nil
    var focusNodes: [String]? = nil
    /// The `cmd:` anchor a `terminal` scene replays.
    var cmd: String? = nil
    var factIds: [String] = []

    /// The shot is the identity: one interval per shot, and the transcript's segments
    /// carry the same `shotId`.
    var id: String { shotId }

    init(start: Double, end: Double, sceneId: String, shotId: String, sceneType: String,
         anchors: [String] = [], highlight: CodeRefHighlight? = nil, visibleLines: [Int]? = nil,
         diagram: String? = nil, focusNodes: [String]? = nil, cmd: String? = nil,
         factIds: [String] = []) {
        self.start = start
        self.end = end
        self.sceneId = sceneId
        self.shotId = shotId
        self.sceneType = sceneType
        self.anchors = anchors
        self.highlight = highlight
        self.visibleLines = visibleLines
        self.diagram = diagram
        self.focusNodes = focusNodes
        self.cmd = cmd
        self.factIds = factIds
    }

    private enum CodingKeys: String, CodingKey {
        case start, end, sceneId, shotId, sceneType, anchors, highlight, visibleLines,
             diagram, focusNodes, cmd, factIds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decodeIfPresent(Double.self, forKey: .start) ?? 0
        end = try c.decodeIfPresent(Double.self, forKey: .end) ?? 0
        sceneId = try c.decodeIfPresent(String.self, forKey: .sceneId) ?? ""
        shotId = try c.decodeIfPresent(String.self, forKey: .shotId) ?? ""
        sceneType = try c.decodeIfPresent(String.self, forKey: .sceneType) ?? "card"
        anchors = try c.decodeIfPresent([String].self, forKey: .anchors) ?? []
        highlight = try c.decodeIfPresent(CodeRefHighlight.self, forKey: .highlight)
        visibleLines = try c.decodeIfPresent([Int].self, forKey: .visibleLines)
        diagram = try c.decodeIfPresent(String.self, forKey: .diagram)
        focusNodes = try c.decodeIfPresent([String].self, forKey: .focusNodes)
        cmd = try c.decodeIfPresent(String.self, forKey: .cmd)
        factIds = try c.decodeIfPresent([String].self, forKey: .factIds) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(start, forKey: .start)
        try c.encode(end, forKey: .end)
        try c.encode(sceneId, forKey: .sceneId)
        try c.encode(shotId, forKey: .shotId)
        try c.encode(sceneType, forKey: .sceneType)
        try c.encode(anchors, forKey: .anchors)
        try c.encodeIfPresent(highlight, forKey: .highlight)
        try c.encodeIfPresent(visibleLines, forKey: .visibleLines)
        try c.encodeIfPresent(diagram, forKey: .diagram)
        try c.encodeIfPresent(focusNodes, forKey: .focusNodes)
        try c.encodeIfPresent(cmd, forKey: .cmd)
        try c.encode(factIds, forKey: .factIds)
    }

    /// The anchor a click on the companion card should open: the highlight if there is
    /// one, else the first `code:` anchor, else the first anchor.
    var primaryAnchor: String? {
        highlight?.anchor ?? anchors.first(where: { $0.hasPrefix("code:") }) ?? anchors.first
    }
}

struct CodeRefMap: Codable, Equatable {
    static let fileName = "coderefs.json"

    var version: Int = PacketManifest.currentVersion
    var videoId: String = ""
    var sha: String = ""
    /// Sorted by `start` and contiguous over `[0, duration]`.
    var intervals: [CodeRefInterval] = []

    init() {}

    init(videoId: String, sha: String, intervals: [CodeRefInterval]) {
        self.videoId = videoId
        self.sha = sha
        self.intervals = intervals
    }

    private enum CodingKeys: String, CodingKey { case version, videoId, sha, intervals }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? PacketManifest.currentVersion
        videoId = try c.decodeIfPresent(String.self, forKey: .videoId) ?? ""
        sha = try c.decodeIfPresent(String.self, forKey: .sha) ?? ""
        intervals = try c.decodeIfPresent([CodeRefInterval].self, forKey: .intervals) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(videoId, forKey: .videoId)
        try c.encode(sha, forKey: .sha)
        try c.encode(intervals, forKey: .intervals)
    }

    /// What is on screen at `t`. Binary search, because the companion card re-resolves
    /// this four times a second for the whole length of a video.
    ///
    /// `t` at an exact boundary belongs to the interval that is *starting*, matching the
    /// player: seeking to a chapter start shows that chapter, not the end of the one
    /// before.
    func lookup(_ t: Double) -> CodeRefInterval? {
        VideoDocs.last(in: intervals, startingAtOrBefore: t, start: { $0.start })
    }

    /// Every interval overlapping `[from, to)`, in order — what "Follow along" needs to
    /// know which files to open as the video runs through a chapter.
    func intervals(from: Double, to: Double) -> [CodeRefInterval] {
        intervals.filter { $0.start < to && $0.end > from }
    }
}

// MARK: - Shared lookup

enum VideoDocs {
    /// The last element whose `start <= t`, or nil when `t` precedes the first (or the
    /// list is empty). `t` past the end returns the last element, because a player
    /// sitting on the final frame is still "in" the last shot.
    ///
    /// The list must be sorted by start; both producers write it that way and
    /// `transcriptMapProbe` asserts it.
    static func last<T>(in items: [T], startingAtOrBefore t: Double,
                        start: (T) -> Double) -> T? {
        guard let first = items.first, start(first) <= t else { return nil }
        var low = 0
        var high = items.count - 1
        var found = 0
        while low <= high {
            let mid = (low + high) / 2
            if start(items[mid]) <= t {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return items[found]
    }
}
