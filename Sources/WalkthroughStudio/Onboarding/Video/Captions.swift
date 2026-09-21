import Foundation

/// Caption and chapter sidecars, written from the transcript and nothing else.
///
/// The existing walkthrough path builds SRT from steps and narration durations, which
/// is why a script edited after synthesis can ship old audio with new captions
/// (CLAUDE.md, known limitations). Here the transcript is the single source: one cue
/// per segment, in the order and at the times the player will actually scrub, so the
/// cue count equals the segment count by construction rather than by luck.
enum VideoDocsCaptions {

    /// SubRip. Cue numbering is 1-based and times use a comma before the milliseconds.
    static func srt(_ transcript: TranscriptDoc) -> String {
        var out = ""
        for (index, segment) in transcript.segments.enumerated() {
            out += "\(index + 1)\n"
            out += "\(timecode(segment.start, separator: ",")) --> \(timecode(segment.end, separator: ","))\n"
            out += segment.text + "\n\n"
        }
        return out
    }

    /// WebVTT, which is what a `<track kind="subtitles">` in the static export reads.
    static func vtt(_ transcript: TranscriptDoc) -> String {
        var out = "WEBVTT\n\n"
        for segment in transcript.segments {
            out += "\(segment.id)\n"
            out += "\(timecode(segment.start, separator: ".")) --> \(timecode(segment.end, separator: "."))\n"
            out += segment.text + "\n\n"
        }
        return out
    }

    /// A chapter track: same format, the chapter title as the cue text.
    static func chaptersVTT(_ transcript: TranscriptDoc) -> String {
        var out = "WEBVTT\n\n"
        for chapter in transcript.chapters {
            out += "\(chapter.id)\n"
            out += "\(timecode(chapter.start, separator: ".")) --> \(timecode(chapter.end, separator: "."))\n"
            out += chapter.title + "\n\n"
        }
        return out
    }

    /// `HH:MM:SS,mmm` or `HH:MM:SS.mmm`. A negative time clamps to zero rather than
    /// producing a cue no player will accept.
    static func timecode(_ seconds: Double, separator: String) -> String {
        let clamped = max(0, seconds)
        let whole = Int(clamped)
        let milliseconds = Int(((clamped - Double(whole)) * 1000).rounded())
        // Rounding 59.9996 up must carry into the seconds, not print ":60.000".
        let carried = whole + (milliseconds == 1000 ? 1 : 0)
        let ms = milliseconds == 1000 ? 0 : milliseconds
        return String(format: "%02d:%02d:%02d%@%03d",
                      carried / 3600, (carried % 3600) / 60, carried % 60, separator, ms)
    }
}
