import Foundation

/// The narration seam. One protocol, two implementations: `ToneNarrator` needs no
/// network and is what the selftest and the fixture package use; `ElevenLabsNarrator`
/// (M5) wraps `ElevenLabsClient` and returns the provider's word alignment.
///
/// Everything downstream — the assembler, the transcript builder, the caption writer —
/// reads the *measured* duration this returns rather than an estimate, so a video built
/// offline and a video built online have the same timing code (D8: timestamps are
/// derived, never recognized).
protocol Narrating: Sendable {
    /// Synthesizes `text` into `url` (a WAV AVFoundation can read) and returns what it
    /// actually produced.
    func synthesize(_ text: String, to url: URL) async throws -> NarrationClip
}

struct NarrationClip: Equatable {
    /// Measured length of the written audio, in seconds.
    var duration: Double
    /// Per-word times from the provider, relative to the clip. Nil when the narrator
    /// cannot align, which is what makes the transcript fall back to the sentence
    /// estimate and sets `timingSource: "sentence-estimate"`.
    var words: [WordTiming]? = nil

    init(duration: Double, words: [WordTiming]? = nil) {
        self.duration = duration
        self.words = words
    }
}

/// An offline narrator: a 440 Hz tone as long as the text would take to speak.
///
/// It exists so the whole video pipeline — stills, mux, captions, chapters, the player —
/// can be built and probed with no API key and no network. The tone is audible on
/// purpose: a silent placeholder hides a dropped clip, and a dropped clip is exactly the
/// failure the muxer's contiguous-audio rule is there to prevent.
struct ToneNarrator: Narrating {
    /// 150 words per minute, the middle of an explainer read.
    static let wordsPerSecond: Double = 2.5
    /// Even a three-word line needs long enough to be seen as a caption.
    static let minimumSeconds: Double = 0.8
    static let sampleRate = 44100

    var wordsPerSecond: Double = ToneNarrator.wordsPerSecond
    var minimumSeconds: Double = ToneNarrator.minimumSeconds
    /// Hz. Distinct per instance so a probe can tell two clips apart by pitch.
    var frequency: Double = 440

    init(wordsPerSecond: Double = ToneNarrator.wordsPerSecond,
         minimumSeconds: Double = ToneNarrator.minimumSeconds,
         frequency: Double = 440) {
        self.wordsPerSecond = wordsPerSecond
        self.minimumSeconds = minimumSeconds
        self.frequency = frequency
    }

    /// The length this narrator will produce for a line, without writing it — the
    /// script validator uses it to estimate a video's runtime before anything renders.
    func estimatedDuration(of text: String) -> Double {
        let words = text.split(whereSeparator: { $0.isWhitespace }).count
        return max(minimumSeconds, Double(words) / wordsPerSecond)
    }

    func synthesize(_ text: String, to url: URL) async throws -> NarrationClip {
        let duration = estimatedDuration(of: text)
        let count = Int(duration * Double(ToneNarrator.sampleRate))
        var pcm = Data(capacity: count * 2)
        for i in 0..<count {
            let value = sin(2.0 * .pi * frequency * Double(i) / Double(ToneNarrator.sampleRate))
            var sample = Int16(8000 * value).littleEndian
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
        }
        let wav = ElevenLabsClient.wavData(fromPCM: pcm, sampleRate: ToneNarrator.sampleRate,
                                           channels: 1, bitsPerSample: 16)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try wav.write(to: url)
        // The measured duration is the sample count, not the request: a rounding
        // difference here would drift the timeline shot by shot.
        return NarrationClip(duration: Double(count) / Double(ToneNarrator.sampleRate), words: nil)
    }
}
