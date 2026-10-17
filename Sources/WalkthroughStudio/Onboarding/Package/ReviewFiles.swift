// ReviewFiles.swift — "Onboard to a Codebase", milestone M7 (playback chat).
//
// `review/flags.json` and `review/status.json` (ARCHITECTURE 2.10): what the
// playback agent noticed while the viewer watched, and what the package author
// decided to do about it (ON-9.6, ON-9.9).
//
// Both files are read-modify-write, and two writers can reach them at once: the
// agent's tools run concurrently within a turn (two `flag_contradiction` calls in
// one reply is an ordinary case), and the companion's Flags tab clears and promotes
// from the main actor. One actor owns both files so neither ever loses a write.
// M12's review UI extends this file rather than adding a second writer.

import Foundation

/// One contradiction the agent raised: the narration said `claim`, the code at
/// `anchor` says otherwise, for `reason`.
struct ContradictionFlag: Codable, Equatable, Identifiable, Sendable {
    var id: String = UUID().uuidString
    var videoId: String
    var t: Double
    /// The narration segment playing at `t`, when there is one.
    var segmentId: String?
    var anchor: String
    var claim: String
    var reason: String
    var at: Date = OnboardingJSON.now()

    init(videoId: String, t: Double, segmentId: String?, anchor: String, claim: String, reason: String) {
        self.videoId = videoId
        self.t = t
        self.segmentId = segmentId
        self.anchor = anchor
        self.claim = claim
        self.reason = reason
    }

    private enum CodingKeys: String, CodingKey { case id, videoId, t, segmentId, anchor, claim, reason, at }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        videoId = try c.decodeIfPresent(String.self, forKey: .videoId) ?? ""
        t = try c.decodeIfPresent(Double.self, forKey: .t) ?? 0
        segmentId = try c.decodeIfPresent(String.self, forKey: .segmentId)
        anchor = try c.decodeIfPresent(String.self, forKey: .anchor) ?? ""
        claim = try c.decodeIfPresent(String.self, forKey: .claim) ?? ""
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        at = try c.decodeIfPresent(Date.self, forKey: .at) ?? OnboardingJSON.now()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(videoId, forKey: .videoId)
        try c.encode(t, forKey: .t)
        try c.encodeIfPresent(segmentId, forKey: .segmentId)
        try c.encode(anchor, forKey: .anchor)
        try c.encode(claim, forKey: .claim)
        try c.encode(reason, forKey: .reason)
        try c.encode(at, forKey: .at)
    }
}

/// One deliverable's review decision in `review/status.json`.
struct ReviewStatusEntry: Codable, Equatable, Sendable {
    /// accept, fix or regenerate.
    var state: String
    var note: String
    var at: Date = OnboardingJSON.now()

    static let states: [String] = ["accept", "fix", "regenerate"]

    init(state: String, note: String) {
        self.state = state
        self.note = note
    }

    private enum CodingKeys: String, CodingKey { case state, note, at }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decodeIfPresent(String.self, forKey: .state) ?? "fix"
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        at = try c.decodeIfPresent(Date.self, forKey: .at) ?? OnboardingJSON.now()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(state, forKey: .state)
        try c.encode(note, forKey: .note)
        try c.encode(at, forKey: .at)
    }
}

actor ReviewFiles {
    static let flagsPath = "review/flags.json"
    static let statusPath = "review/status.json"

    private let store: PackageStore

    init(store: PackageStore) {
        self.store = store
    }

    // MARK: Flags

    func flags() -> [ContradictionFlag] {
        (try? store.readJSON([ContradictionFlag].self, from: ReviewFiles.flagsPath)) ?? []
    }

    /// Appends one flag. A flag identical to one already recorded (same video,
    /// anchor and claim) is not added twice: a viewer who asks the same question
    /// twice should not hand the author the same correction twice.
    @discardableResult
    func append(_ flag: ContradictionFlag) throws -> ContradictionFlag {
        var all = flags()
        if let existing = all.first(where: {
            $0.videoId == flag.videoId && $0.anchor == flag.anchor && $0.claim == flag.claim
        }) {
            return existing
        }
        all.append(flag)
        try store.writeJSON(all, to: ReviewFiles.flagsPath)
        return flag
    }

    func removeFlag(id: String) throws {
        var all = flags()
        all.removeAll { $0.id == id }
        try store.writeJSON(all, to: ReviewFiles.flagsPath)
    }

    // MARK: Status

    func status() -> [String: ReviewStatusEntry] {
        (try? store.readJSON([String: ReviewStatusEntry].self, from: ReviewFiles.statusPath)) ?? [:]
    }

    /// Turns something noticed while watching into a review item on the deliverable
    /// (ON-9.9). A second item on the same deliverable is appended to its note
    /// rather than replacing the first: the file holds one decision per
    /// deliverable, and the author needs every reason behind it.
    @discardableResult
    func promote(deliverableId: String, state: String = "fix", note: String) throws -> ReviewStatusEntry {
        var all = status()
        var entry = all[deliverableId] ?? ReviewStatusEntry(state: state, note: "")
        entry.state = state
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, !entry.note.contains(trimmed) {
            entry.note = entry.note.isEmpty ? trimmed : entry.note + "\n" + trimmed
        }
        entry.at = OnboardingJSON.now()
        all[deliverableId] = entry
        try store.writeJSON(all, to: ReviewFiles.statusPath)
        return entry
    }
}
