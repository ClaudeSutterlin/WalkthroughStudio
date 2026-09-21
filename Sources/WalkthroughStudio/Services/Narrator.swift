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

/// The real narrator: ElevenLabs, asking for the character alignment the timing files
/// want and degrading to an estimate when the account's plan does not offer it.
///
/// `timingSource` in the transcript records which one a package got, so a caption that
/// drifts can be explained rather than guessed at.
struct ElevenLabsNarrator: Narrating {
    var client: ElevenLabsClient
    var voiceID: String
    var modelID: String
    /// Called when alignment was unavailable, so the pipeline can post a notice instead
    /// of failing (the house rule for a degraded stage).
    var onDegraded: (@Sendable (String) -> Void)?

    init(client: ElevenLabsClient, voiceID: String, modelID: String,
         onDegraded: (@Sendable (String) -> Void)? = nil) {
        self.client = client
        self.voiceID = voiceID
        self.modelID = modelID
        self.onDegraded = onDegraded
    }

    func synthesize(_ text: String, to url: URL) async throws -> NarrationClip {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if let alignment = try await client.synthesizeWithAlignment(
            text: text, voiceID: voiceID, modelID: modelID) {
            try alignment.wav.write(to: url)
            let duration = ElevenLabsNarrator.wavDuration(alignment.wav)
            guard alignment.hasTimings else {
                onDegraded?("the narration API returned no word timings for this line")
                return NarrationClip(duration: duration, words: nil)
            }
            let words = ElevenLabsNarrator.words(fromCharacters: alignment.characters,
                                                 starts: alignment.starts, ends: alignment.ends)
            return NarrationClip(duration: duration, words: words.isEmpty ? nil : words)
        }
        // No timestamps on this plan: synthesize normally and let the sentence estimate
        // carry the timing.
        let wav = try await client.synthesizeWAV(text: text, voiceID: voiceID, modelID: modelID)
        try wav.write(to: url)
        onDegraded?("this plan has no word-timestamps endpoint; caption times are estimated")
        return NarrationClip(duration: ElevenLabsNarrator.wavDuration(wav), words: nil)
    }

    /// Fold per-character times into words on whitespace boundaries.
    ///
    /// Pure, so a probe can check it without a network: the provider returns one entry
    /// per character including the spaces, and a word's time is its first character's
    /// start to its last character's end.
    static func words(fromCharacters characters: [String], starts: [Double],
                      ends: [Double]) -> [WordTiming] {
        let count = min(characters.count, min(starts.count, ends.count))
        var out: [WordTiming] = []
        var buffer = ""
        var start = 0.0
        var end = 0.0

        func flush() {
            guard !buffer.isEmpty else { return }
            out.append(WordTiming(w: buffer, s: start, e: max(end, start)))
            buffer = ""
        }

        for index in 0..<count {
            let piece = characters[index]
            if piece.isEmpty || piece.allSatisfy({ $0.isWhitespace }) {
                flush()
                continue
            }
            if buffer.isEmpty { start = starts[index] }
            buffer += piece
            end = ends[index]
        }
        flush()
        return out
    }

    /// Length of a PCM WAV from its own header, rather than from what was asked for:
    /// the timeline is laid out from what the file actually contains.
    static func wavDuration(_ wav: Data) -> Double {
        guard wav.count > 44 else { return 0 }
        func uint32(at offset: Int) -> UInt32 {
            var value: UInt32 = 0
            for i in 0..<4 { value |= UInt32(wav[wav.startIndex + offset + i]) << (8 * UInt32(i)) }
            return value
        }
        func uint16(at offset: Int) -> UInt16 {
            UInt16(wav[wav.startIndex + offset]) | (UInt16(wav[wav.startIndex + offset + 1]) << 8)
        }
        // Walk the chunks rather than assuming a 44-byte header: a WAV with a LIST
        // chunk before `data` would otherwise measure long by however big that is.
        var offset = 12
        let sampleRate = Int(uint32(at: 24))
        let channels = Int(uint16(at: 22))
        let bits = Int(uint16(at: 34))
        while offset + 8 <= wav.count {
            let id = String(decoding: wav[(wav.startIndex + offset)..<(wav.startIndex + offset + 4)],
                            as: UTF8.self)
            let size = Int(uint32(at: offset + 4))
            if id == "data" {
                let bytesPerFrame = max(1, channels * bits / 8)
                return sampleRate > 0 ? Double(size / bytesPerFrame) / Double(sampleRate) : 0
            }
            offset += 8 + size + (size % 2)
        }
        return 0
    }
}
