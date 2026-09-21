import Foundation

/// One builder writes every timing file (D8): the transcript, the code-ref map and the
/// chapter list all come from the same walk over the script and the measured clips, so
/// a caption, the companion card and the chat context can never disagree about what was
/// on screen at a moment.
///
/// Nothing here recognizes speech. Times are derived from the audio each shot actually
/// produced — with the provider's word alignment when there is one, otherwise by
/// distributing each shot's sentences across its measured clip.
enum TranscriptBuilder {

    /// What one shot cost on the timeline, after rendering and narration.
    struct ShotTiming: Equatable {
        let sceneID: String
        let shotID: String
        /// Absolute seconds from the start of the video.
        let start: Double
        /// Narration length plus the shot's pad: the whole slice the shot occupies.
        let duration: Double
        /// Narration length alone, which is what sentence times are distributed across.
        let clipDuration: Double
        /// Provider word alignment, relative to the clip.
        let words: [WordTiming]?

        init(sceneID: String, shotID: String, start: Double, duration: Double,
             clipDuration: Double, words: [WordTiming]? = nil) {
            self.sceneID = sceneID
            self.shotID = shotID
            self.start = start
            self.duration = duration
            self.clipDuration = clipDuration
            self.words = words
        }

        var end: Double { start + duration }
    }

    struct Output: Equatable {
        var transcript: TranscriptDoc
        var coderefs: CodeRefMap
        var chapters: [ChapterMarker]
    }

    /// Lay the shots end to end: each starts where the one before ended.
    static func timeline(for script: VideoScript, clips: [String: NarrationClip]) -> [ShotTiming] {
        var out: [ShotTiming] = []
        var cursor = 0.0
        for (scene, shot) in script.shots {
            let clip = clips[shot.id]
            let clipDuration = clip?.duration ?? ToneNarrator().estimatedDuration(of: shot.narration)
            let duration = clipDuration + max(0, shot.pad)
            out.append(ShotTiming(sceneID: scene.id, shotID: shot.id, start: cursor,
                                  duration: duration, clipDuration: clipDuration,
                                  words: clip?.words))
            cursor += duration
        }
        return out
    }

    static func build(script: VideoScript, timeline: [ShotTiming]) throws -> Output {
        guard !timeline.isEmpty else {
            throw StudioError("TranscriptBuilder: \(script.id) has no shots.")
        }
        var byShot: [String: ShotTiming] = [:]
        for entry in timeline { byShot[entry.shotID] = entry }

        var segments: [TranscriptSegment] = []
        var intervals: [CodeRefInterval] = []
        var index = 0
        var usesProviderWords = false

        for (scene, shot) in script.shots {
            guard let timing = byShot[shot.id] else {
                throw StudioError("TranscriptBuilder: no timing for shot \(shot.id) of \(script.id).")
            }
            if timing.words != nil { usesProviderWords = true }

            for piece in sentenceTimes(shot: shot, timing: timing) {
                index += 1
                segments.append(TranscriptSegment(
                    id: String(format: "seg-%04d", index),
                    sceneId: scene.id, shotId: shot.id,
                    start: piece.start, end: piece.end, text: piece.text, words: piece.words))
            }

            intervals.append(CodeRefInterval(
                start: timing.start, end: timing.end, sceneId: scene.id, shotId: shot.id,
                sceneType: shot.sceneType, anchors: shot.anchors, highlight: shot.highlight,
                visibleLines: shot.visibleLines, diagram: shot.diagram,
                focusNodes: shot.focusNodes, cmd: shot.cmd, factIds: shot.factIds))
        }

        // A shot whose narration is empty produces no segment; the transcript would then
        // have a hole where that shot plays. Give the gap to the previous segment rather
        // than emitting an empty caption.
        segments = tile(segments, to: timeline.last!.end)

        let duration = timeline.last!.end
        var chapters: [ChapterMarker] = []
        for scene in script.scenes {
            let shotIDs = Set(scene.shots.map { $0.id })
            let owned = timeline.filter { shotIDs.contains($0.shotID) }
            guard let first = owned.first, let last = owned.last else { continue }
            var anchors: [String] = []
            for shot in scene.shots {
                for anchor in shot.anchors where !anchors.contains(anchor) { anchors.append(anchor) }
            }
            chapters.append(ChapterMarker(id: scene.id, title: scene.title,
                                          start: first.start, end: last.end,
                                          docAnchor: scene.docAnchor, anchors: anchors))
        }

        let transcript = TranscriptDoc(
            videoId: script.id, sha: script.sha, duration: duration,
            timingSource: usesProviderWords ? "provider-words" : "sentence-estimate",
            summary: script.summary, chapters: chapters, segments: segments)
        let coderefs = CodeRefMap(videoId: script.id, sha: script.sha, intervals: intervals)
        return Output(transcript: transcript, coderefs: coderefs, chapters: chapters)
    }

    // MARK: - Sentence timing

    private struct Piece {
        let text: String
        let start: Double
        let end: Double
        let words: [WordTiming]?
    }

    /// Cut a shot's narration into sentences and give each one a slice of the shot.
    ///
    /// With a provider alignment, a sentence takes the times of the words it contains.
    /// Without one, sentences are distributed by character count across the *measured*
    /// clip — the rule `VideoService.srt` already uses — with a floor so a three-word
    /// sentence is still readable. The floor can over-subscribe a short shot, so the
    /// slices are normalized afterwards: tiling the timeline is the harder invariant,
    /// and a caption 40 ms under the floor is invisible while a gap is not.
    ///
    /// The shot's trailing pad belongs to the last sentence, so the next shot's first
    /// caption appears exactly when the picture changes.
    private static func sentenceTimes(shot: VideoScript.Shot, timing: ShotTiming) -> [Piece] {
        let sentences = VideoService.splitSentences(shot.narration)
        guard !sentences.isEmpty else { return [] }

        if let words = timing.words, !words.isEmpty {
            return alignedPieces(sentences: sentences, words: words, timing: timing)
        }

        let totalCharacters = sentences.reduce(0) { $0 + $1.count }
        var lengths: [Double] = sentences.map { sentence in
            let share = totalCharacters > 0 ? Double(sentence.count) / Double(totalCharacters) : 1.0
            return max(ToneNarrator.minimumSeconds, timing.clipDuration * share)
        }
        let raised = lengths.reduce(0, +)
        if raised > 0, raised != timing.duration {
            let scale = timing.duration / raised
            lengths = lengths.map { $0 * scale }
        }

        var out: [Piece] = []
        var cursor = timing.start
        for (i, sentence) in sentences.enumerated() {
            let end = i == sentences.count - 1 ? timing.end : cursor + lengths[i]
            out.append(Piece(text: sentence, start: cursor, end: end, words: nil))
            cursor = end
        }
        return out
    }

    /// Fold the provider's words into the sentences they belong to, in order. A word the
    /// splitter dropped (punctuation the aligner kept) still advances the cursor, so a
    /// mismatch shortens a sentence rather than desyncing everything after it.
    private static func alignedPieces(sentences: [String], words: [WordTiming],
                                      timing: ShotTiming) -> [Piece] {
        var out: [Piece] = []
        var cursor = 0
        var startTime = timing.start
        for (i, sentence) in sentences.enumerated() {
            let count = sentence.split(whereSeparator: { $0.isWhitespace }).count
            let slice = Array(words[cursor..<min(words.count, cursor + count)])
            cursor = min(words.count, cursor + count)
            let shifted = slice.map { WordTiming(w: $0.w, s: $0.s + timing.start, e: $0.e + timing.start) }
            let end = i == sentences.count - 1
                ? timing.end
                : (shifted.last.map { $0.e } ?? startTime + ToneNarrator.minimumSeconds)
            out.append(Piece(text: sentence, start: startTime, end: max(end, startTime),
                             words: shifted.isEmpty ? nil : shifted))
            startTime = max(end, startTime)
        }
        return out
    }

    /// Close any gap the shot walk left, so `segments[i].end == segments[i+1].start`, the
    /// first starts at 0 and the last ends with the video. Asserted by
    /// `transcriptMapProbe`.
    ///
    /// Gaps come from shots with no narration — a title card held in silence. The
    /// neighbouring segment absorbs the silence rather than an empty segment filling it:
    /// an empty segment is a blank caption cue, and a hole makes `segment(at:)` return
    /// nil so the caption line flickers off mid-video. Extending a real line is the
    /// least visible of the three.
    private static func tile(_ segments: [TranscriptSegment], to duration: Double) -> [TranscriptSegment] {
        guard !segments.isEmpty else { return segments }
        var out = segments
        out[0].start = 0
        for i in 0..<(out.count - 1) where out[i].end != out[i + 1].start {
            out[i].end = out[i + 1].start
        }
        out[out.count - 1].end = duration
        return out
    }
}
