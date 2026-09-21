import Foundation

/// Narration, cached by the content that produced it.
///
/// Rebuilding a twelve-minute walk to fix one sentence should re-synthesize one
/// sentence. The key is a hash of everything that could change the audio — the text,
/// the voice, the model, the narrator — so a shot whose narration did not change keeps
/// its clip and, with it, its word alignment.
///
/// It is also the staleness record the walkthrough side never had (CLAUDE.md lists
/// "no staleness tracking between scripts and synthesized audio" as a known limitation):
/// an entry whose hash no longer matches the script is, by definition, stale.
struct AudioCache {

    let store: PackageStore
    let videoID: String

    var directory: String { "videos/\(videoID)/audio" }
    var indexPath: String { "\(directory)/index.json" }

    init(store: PackageStore, videoID: String) {
        self.store = store
        self.videoID = videoID
    }

    // MARK: - Index

    struct Entry: Codable, Equatable {
        var shotID: String
        /// sha256 over the text and the voice settings that produced this clip.
        var hash: String
        var duration: Double
        var words: [WordTiming]? = nil
        var file: String

        init(shotID: String, hash: String, duration: Double, words: [WordTiming]?, file: String) {
            self.shotID = shotID
            self.hash = hash
            self.duration = duration
            self.words = words
            self.file = file
        }

        private enum CodingKeys: String, CodingKey { case shotID, hash, duration, words, file }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            shotID = try c.decodeIfPresent(String.self, forKey: .shotID) ?? ""
            hash = try c.decodeIfPresent(String.self, forKey: .hash) ?? ""
            duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
            words = try c.decodeIfPresent([WordTiming].self, forKey: .words)
            file = try c.decodeIfPresent(String.self, forKey: .file) ?? ""
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(shotID, forKey: .shotID)
            try c.encode(hash, forKey: .hash)
            try c.encode(duration, forKey: .duration)
            try c.encodeIfPresent(words, forKey: .words)
            try c.encode(file, forKey: .file)
        }
    }

    func index() -> [String: Entry] {
        guard let entries = try? store.readJSON([Entry].self, from: indexPath) else { return [:] }
        return Dictionary(entries.map { ($0.shotID, $0) }, uniquingKeysWith: { _, second in second })
    }

    func write(index: [String: Entry]) throws {
        try store.writeJSON(index.values.sorted { $0.shotID < $1.shotID }, to: indexPath)
    }

    /// Everything that would change the audio. The narrator's own name is in here so
    /// switching from the offline tone to a real voice re-synthesizes rather than
    /// playing yesterday's beeps under today's script.
    func key(for shot: VideoScript.Shot, voice: String, model: String, narrator: String) -> String {
        store.sha256(of: [narrator, voice, model, shot.narration].joined(separator: "\u{1F}"))
    }

    // MARK: - Synthesis

    struct Result {
        var clip: NarrationClip
        var url: URL
        /// True when the cached clip was reused rather than re-synthesized.
        var reused: Bool
    }

    /// The clip for one shot, synthesizing it only if the key changed or the file is gone.
    func clip(for shot: VideoScript.Shot, voice: String, model: String,
              narrator: Narrating, narratorName: String) async throws -> Result {
        let wanted = key(for: shot, voice: voice, model: model, narrator: narratorName)
        let relative = "\(directory)/\(shot.id).wav"
        var entries = index()

        if let entry = entries[shot.id], entry.hash == wanted, store.exists(relative) {
            return Result(clip: NarrationClip(duration: entry.duration, words: entry.words),
                          url: store.url(relative), reused: true)
        }

        let url = store.url(relative)
        let clip = try await narrator.synthesize(shot.narration, to: url)
        entries[shot.id] = Entry(shotID: shot.id, hash: wanted, duration: clip.duration,
                                 words: clip.words, file: relative)
        try write(index: entries)
        return Result(clip: clip, url: url, reused: false)
    }

    /// Clips for shots the script no longer has. Called after a rebuild, so a renamed
    /// shot does not leave its audio behind forever.
    @discardableResult
    func prune(keeping shotIDs: Set<String>) throws -> [String] {
        var entries = index()
        let gone = entries.keys.filter { !shotIDs.contains($0) }
        for shotID in gone {
            if let entry = entries[shotID], store.exists(entry.file) {
                try? store.removeItem(entry.file)
            }
            entries[shotID] = nil
        }
        if !gone.isEmpty { try write(index: entries) }
        return gone.sorted()
    }

    /// Shots whose narration has changed since their clip was made — what a review pane
    /// shows as "this caption no longer matches its audio".
    func stale(in script: VideoScript, voice: String, model: String,
               narratorName: String) -> [String] {
        let entries = index()
        return script.shots.compactMap { _, shot in
            let wanted = key(for: shot, voice: voice, model: model, narrator: narratorName)
            guard let entry = entries[shot.id] else { return shot.id }
            return entry.hash == wanted ? nil : shot.id
        }
    }
}
