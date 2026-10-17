import Foundation
import AVFoundation
import SwiftUI

/// Everything the onboarding window shows, in one `@MainActor` object — the same shape
/// as `StudioViewModel` for the walkthrough side, and for the same reason: three panes
/// that must agree about what is on screen cannot each keep their own copy.
///
/// It owns the package, the player and the clock. The centre pane's web view and the
/// native chrome both route through `open(anchor:)`, so a chip in a document, a node in
/// a diagram and a chapter in the strip all take the same path.
@MainActor
final class OnboardingViewModel: ObservableObject {

    // MARK: Package

    @Published private(set) var store: PackageStore?
    @Published private(set) var hub = HubIndex()
    @Published private(set) var manifest = OnboardingManifest()
    @Published private(set) var backlinks = BacklinkIndex(byAnchor: [:])
    @Published private(set) var packageName = ""
    /// The reading order the navigator shows: the hub index, with this package's videos
    /// in front of it.
    ///
    /// `hub/index.json` is what the *projectors* make from the packet, and a packet
    /// contains no videos — those are produced afterwards, from a script. Merging here
    /// rather than rewriting the projected file keeps one producer per file: the hub
    /// index stays exactly what `HubProjector` wrote, and the window shows both halves.
    @Published private(set) var items: [HubIndex.Item] = []

    // MARK: Stage

    @Published var stage: PlayerStage = .hub
    /// The anchor the hub should open next. The web view watches this and calls
    /// `walkthroughHub.route`; it is a request, not a record of where the hub is.
    @Published var pendingAnchor: String?
    /// Where the hub says it is, reported back over the bridge.
    @Published private(set) var hubAnchor: String?
    @Published private(set) var hubTitle = ""
    @Published private(set) var hubCanGoBack = false

    /// True while the video keeps playing in the companion's 320 px mini-player because
    /// the viewer clicked into code or a document (ON-8.7).
    @Published private(set) var isDocked = false
    /// Where the viewer left the video, so "Back to video" returns to the moment rather
    /// than to the start.
    @Published private(set) var dockedVideoID: String?

    // MARK: Playback

    let player = AVPlayer()
    let clock = PlaybackClock()
    @Published private(set) var transcript = TranscriptDoc()
    @Published private(set) var coderefs = CodeRefMap()
    @Published var showCaptions = true

    // MARK: Review

    @Published private(set) var bookmarks: [OnboardingBookmark] = []
    /// What the playback agent flagged (ON-9.6), from `review/flags.json`.
    @Published private(set) var flags: [ContradictionFlag] = []
    private var review: ReviewFiles?

    // MARK: Chat

    @Published var companionTab: CompanionTab = .chat
    /// The conversation about the video on the stage (or the last one played).
    @Published private(set) var chat: ChatSession?
    /// Bumped to ask the chat input for focus ("?").
    @Published private(set) var chatFocusRequest = 0
    /// True when typing a question paused the video, so the panel offers Resume.
    @Published private(set) var pausedForChat = false
    /// One conversation per video, kept while the package is open.
    private var chats: [String: ChatSession] = [:]

    // MARK: Status

    @Published private(set) var busyMessage = ""
    @Published var notices: [OnboardingNotice] = []
    @Published var showOnboardSheet = false

    var isBusy: Bool { !busyMessage.isEmpty }
    var isLoaded: Bool { store != nil }

    /// The router for the open package, or nil before one is open.
    var router: LinkRouter? {
        guard let store else { return nil }
        return LinkRouter(store: store, headSHA: manifest.headSHA)
    }

    // MARK: - Opening a package

    func open(packageAt root: URL) async {
        busyMessage = "Opening \(root.lastPathComponent)…"
        defer { busyMessage = "" }
        do {
            let store = try PackageStore(root: root)
            guard store.exists(HubIndex.fileName) else {
                throw StudioError("\(root.lastPathComponent) has no hub/index.json — it is not a "
                                  + "finished onboarding package.")
            }
            self.store = store
            self.hub = try HubIndex.load(from: store)
            self.manifest = store.hasManifest ? try store.readManifest() : OnboardingManifest()
            self.backlinks = try BacklinkIndex.load(from: store)
            self.packageName = root.deletingPathExtension().lastPathComponent
            self.bookmarks = (try? store.readJSON([OnboardingBookmark].self, from: "review/bookmarks.json")) ?? []
            self.review = ReviewFiles(store: store)
            self.chats = [:]
            self.chat = nil
            await reloadFlags()
            self.items = OnboardingViewModel.readingOrder(hub: hub, manifest: manifest)
            LinkRouter.invalidateCache(for: store.root)
            OnboardingViewModel.remember(root)
            if let first = items.first { open(anchor: first.id) }
        } catch {
            note("Could not open the package", error)
        }
    }

    /// Videos first — they are the way in — then the projected order, renumbered so the
    /// navigator's numbers run 1..n without a gap.
    /// Nonisolated: the playback agent's package digest lists the same order.
    nonisolated static func readingOrder(hub: HubIndex, manifest: OnboardingManifest) -> [HubIndex.Item] {
        var out: [HubIndex.Item] = []
        for deliverable in manifest.deliverables where deliverable.kind == .video {
            var item = HubIndex.Item()
            item.id = deliverable.id
            item.kind = "video"
            item.title = deliverable.title
            item.path = deliverable.path
            item.minutes = max(1, Int(deliverable.minutes.rounded()))
            out.append(item)
        }
        out.append(contentsOf: hub.items)
        for index in out.indices { out[index].order = index + 1 }
        return out
    }

    /// Package folders opened before, newest first — the recents list of ON-1.8.
    nonisolated static func recentPackages() -> [URL] {
        (UserDefaults.standard.array(forKey: SettingsKeys.onboardingRecents) as? [String] ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    nonisolated static func remember(_ root: URL) {
        var paths = (UserDefaults.standard.array(forKey: SettingsKeys.onboardingRecents) as? [String] ?? [])
        paths.removeAll { $0 == root.path }
        paths.insert(root.path, at: 0)
        UserDefaults.standard.set(Array(paths.prefix(10)), forKey: SettingsKeys.onboardingRecents)
    }

    /// Import a Research Packet, project every deliverable from it and open the result
    /// (ON-1.8 and the import flow of ARCHITECTURE.md 15.5).
    ///
    /// Validation comes first and nothing is written when it fails: a packet with a
    /// dangling anchor is rejected with the reason, not half-imported.
    func buildPackage(fromPacketAt packetURL: URL, repo: URL, outputDir: URL,
                      briefing: URL? = nil) async {
        busyMessage = "Validating \(packetURL.lastPathComponent)…"
        defer { busyMessage = "" }
        do {
            let name = PackageStore.repoName(fromSource: repo.path)
            let root = PackageStore.packageURL(outputDir: outputDir, repoName: name)
            let store = try PackageStore(root: root)
            let git = GitRunner()
            try await PacketImporter.importPacket(at: packetURL, into: store, repo: repo, git: git)

            busyMessage = "Building the deliverables…"
            let packet = try PacketReader.load(store.url("packet"))
            let projection = try PackageProjector.project(packet: packet, into: store)
            let code = try await PackageProjector.emitCode(packet: packet, into: store,
                                                           repo: repo, git: git)
            LinkRouter.invalidateCache(for: store.root)

            if !code.missing.isEmpty {
                notices.append(OnboardingNotice(
                    message: "\(code.missing.count) cited file(s) are not at the pinned commit and "
                        + "did not travel with the package: \(code.missing.prefix(3).joined(separator: ", "))"))
            }
            if projection.proposedFactCount > 0 {
                notices.append(OnboardingNotice(
                    message: "\(projection.proposedFactCount) fact(s) were never verified and were "
                        + "left out of every deliverable. Run the packet's verifier units to include them."))
            }
            if var manifest = try? store.readManifest() {
                manifest.briefingPath = briefing?.path
                try? store.writeManifest(manifest)
            }
            await open(packageAt: root)
        } catch {
            note("That packet was not imported", error)
        }
    }

    // MARK: - Routing

    /// The one entry point for every link in the window. A `video:` anchor takes the
    /// stage and seeks; everything else goes to the hub web view, docking the player if
    /// it was playing so the viewer never loses the moment (ON-8.7).
    func open(anchor: String) {
        guard let router else { return }
        switch router.resolve(anchor) {
        case .failure(let failure):
            note("That link does not resolve", StudioError(failure.description))
        case .success(let destination):
            switch destination {
            case .video(let id, let seconds, let chapter):
                Task { await play(videoID: id, seconds: seconds, chapter: chapter) }
            default:
                // Leaving a video always docks it, playing or paused: the point is to
                // keep the moment, and a viewer who paused to read the code is exactly
                // the one who wants "Back to video" waiting for them (ON-8.7).
                if case .video(let id) = stage {
                    dockedVideoID = id
                    isDocked = true
                }
                stage = .hub
                pendingAnchor = anchor
            }
        }
    }

    /// Called by the web view when the hub has navigated itself (a chip, a diagram node,
    /// its own Back button).
    func hubDidNavigate(anchor: String, title: String, canGoBack: Bool) {
        hubAnchor = anchor
        hubTitle = title
        hubCanGoBack = canGoBack
        if pendingAnchor == anchor { pendingAnchor = nil }
    }

    // MARK: - Playback

    func play(videoID: String, seconds: Double? = nil, chapter: String? = nil) async {
        guard let store else { return }
        let folder = "videos/\(videoID)"
        guard store.exists("\(folder)/video.mp4") else {
            note("That video is not in this package", StudioError("\(folder)/video.mp4 is missing"))
            return
        }
        if case .video(let current) = stage, current == videoID {
            // Already on screen: this is a seek, not a load.
        } else {
            do {
                transcript = try OnboardingJSON.decoder().decode(
                    TranscriptDoc.self, from: try store.readData("\(folder)/\(TranscriptDoc.fileName)"))
                coderefs = try OnboardingJSON.decoder().decode(
                    CodeRefMap.self, from: try store.readData("\(folder)/\(CodeRefMap.fileName)"))
            } catch {
                note("That video has no timing files", error)
                return
            }
            player.replaceCurrentItem(with: AVPlayerItem(url: store.url("\(folder)/video.mp4")))
            clock.attach(to: player, transcript: transcript, coderefs: coderefs)
            openChat(videoID: videoID)
        }
        stage = .video(videoID)
        isDocked = false
        dockedVideoID = nil

        var target = seconds
        if let chapter, let mark = transcript.chapters.first(where: { $0.id == chapter }) {
            target = mark.start
        }
        if let target { seek(to: target) }
        player.play()
    }

    func seek(to seconds: Double) {
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        clock.update(to: max(0, seconds))
    }

    func togglePlayPause() {
        clock.isPlaying ? player.pause() : player.play()
    }

    /// Escape, or the "Back to video" button: the full player returns at the same t,
    /// because the clock never stopped.
    func backToVideo() {
        guard let id = dockedVideoID ?? currentVideoID else { return }
        stage = .video(id)
        isDocked = false
        dockedVideoID = nil
    }

    var currentVideoID: String? {
        if case .video(let id) = stage { return id }
        return transcript.videoId.isEmpty ? nil : transcript.videoId
    }

    /// Previous / next chapter, for `[` and `]`.
    func step(chapters delta: Int) {
        let marks = transcript.chapters
        guard !marks.isEmpty else { return }
        let index = marks.lastIndex(where: { $0.start <= clock.t + 0.01 }) ?? 0
        let target = min(marks.count - 1, max(0, index + delta))
        // Stepping back from inside a chapter restarts it first, as every player does.
        if delta < 0, clock.t - marks[index].start > 2, index == target + 1 {
            seek(to: marks[index].start)
        } else {
            seek(to: marks[target].start)
        }
    }

    // MARK: - Review

    func addBookmark(note text: String = "") {
        guard let id = currentVideoID else { return }
        bookmarks.append(OnboardingBookmark(videoID: id, t: clock.t, note: text,
                                            anchor: clock.interval?.primaryAnchor))
        persistBookmarks()
    }

    func removeBookmark(_ bookmark: OnboardingBookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        persistBookmarks()
    }

    func reloadFlags() async {
        guard let review else { return }
        flags = await review.flags()
    }

    func clearFlag(_ flag: ContradictionFlag) {
        guard let review else { return }
        Task {
            do {
                try await review.removeFlag(id: flag.id)
            } catch {
                note("Could not clear that flag", error)
            }
            await reloadFlags()
        }
    }

    /// A flag becomes a review item on its video in `review/status.json` (ON-9.9),
    /// and leaves the Flags list: it is the author's to act on now.
    func promoteFlag(_ flag: ContradictionFlag, note text: String) {
        guard let review else { return }
        var line = "[\(PlaybackAgent.timecode(flag.t))] The narration says \"\(flag.claim)\"; "
            + "[[\(flag.anchor)]] shows: \(flag.reason)"
        let extra = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { line += " Note: \(extra)" }
        Task {
            do {
                try await review.promote(deliverableId: "video:\(flag.videoId)", note: line)
                try await review.removeFlag(id: flag.id)
            } catch {
                note("Could not add that flag to the review list", error)
            }
            await reloadFlags()
        }
    }

    /// A bookmark becomes a review item too; the bookmark itself stays, because it
    /// is the viewer's way back to the moment.
    func promoteBookmark(_ bookmark: OnboardingBookmark, note text: String) {
        guard let review else { return }
        var line = "[\(PlaybackAgent.timecode(bookmark.t))] "
        let combined = [bookmark.note, text.trimmingCharacters(in: .whitespacesAndNewlines)]
            .filter { !$0.isEmpty }.joined(separator: " ")
        line += combined.isEmpty ? "Marked for review." : combined
        if let anchor = bookmark.anchor { line += " [[\(anchor)]]" }
        Task {
            do {
                try await review.promote(deliverableId: "video:\(bookmark.videoID)", note: line)
                notices.append(OnboardingNotice(message: "Added to the review list for video:\(bookmark.videoID)."))
            } catch {
                note("Could not add that bookmark to the review list", error)
            }
        }
    }

    private func persistBookmarks() {
        guard let store else { return }
        do {
            try store.writeJSON(bookmarks, to: "review/bookmarks.json")
        } catch {
            note("Could not save your bookmarks", error)
        }
    }

    // MARK: - Chat

    /// Starts (or returns to) the conversation about `videoID`. A chat that cannot
    /// start degrades to a notice; the video still plays.
    func openChat(videoID: String) {
        if let existing = chats[videoID] {
            chat = existing
            return
        }
        guard let store, let review else { return }
        guard let settings = AgentRuntimeSettings.current(role: .planner) else {
            notices.append(OnboardingNotice(message: "The chat is off: the API endpoint in Settings "
                                            + "is not a URL."))
            chat = nil
            return
        }
        do {
            let agent = try PlaybackAgent.load(store: store, videoId: videoID, settings: settings)
            let session = ChatSession(agent: agent, review: review)
            session.onFlagsChanged = { [weak self] in
                Task { await self?.reloadFlags() }
            }
            chats[videoID] = session
            chat = session
        } catch {
            note("The chat for this video could not start", error)
            chat = nil
        }
    }

    /// "?": the chat tab, with the cursor in the input.
    func focusChat() {
        companionTab = .chat
        chatFocusRequest += 1
    }

    /// Typing a question pauses the video (ON-9.4): an answer about a moment that
    /// has scrolled past is an answer to a different question.
    func pauseForTyping() {
        guard clock.isPlaying else { return }
        player.pause()
        pausedForChat = true
    }

    func resumeAfterChat() {
        pausedForChat = false
        player.play()
    }

    func ask(_ question: String) {
        guard let chat else { return }
        let t = clock.t
        Task { await chat.ask(question, at: t) }
    }

    // MARK: - Regenerating a video (ON-6.6)

    /// Re-renders the video on stage from its `videos/<id>/script.json`, as the author
    /// edited it, and nothing else in the package. Shots whose narration did not change
    /// keep their audio, so fixing one sentence re-synthesizes one sentence.
    func regenerateCurrentVideo() async {
        guard let store, let videoID = currentVideoID, busyMessage.isEmpty else { return }
        busyMessage = "Regenerating \(videoID)…"
        defer { busyMessage = "" }
        let resumeAt = clock.t
        do {
            let narrator = try OnboardingViewModel.narrator(for: manifest)
            var options = VideoAssembler.Options()
            options.voiceID = manifest.narration.voiceID
            options.modelID = manifest.narration.modelID
            options.narratorName = manifest.narration.modelID == "tone" ? "tone" : "elevenlabs"
            // The mp4 is about to be replaced under the player.
            player.pause()
            player.replaceCurrentItem(with: nil)
            let runner = SeriesRunner(store: store, repo: nil, narrator: narrator, options: options)
            let built = try await runner.regenerate(videoId: videoID)
            for notice in built.notices {
                notices.append(OnboardingNotice(message: "\(videoID): \(notice)"))
            }
            manifest = try store.readManifest()
            items = OnboardingViewModel.readingOrder(hub: hub, manifest: manifest)
            // The chat read the old transcript; the next question starts from the new one.
            chats[videoID] = nil
            stage = .hub
            await play(videoID: videoID, seconds: min(resumeAt, built.duration))
        } catch {
            note("That video was not regenerated", error)
        }
    }

    /// The voice the package was built with: the offline tone for a fixture package,
    /// ElevenLabs otherwise. Read from the Keychain here, on a click, never while a view
    /// is being built (CLAUDE.md landmine 5).
    static func narrator(for manifest: OnboardingManifest) throws -> Narrating {
        if manifest.narration.modelID == "tone" || manifest.narration.modelID.isEmpty {
            return ToneNarrator()
        }
        let key = Keychain.elevenLabsKey
        guard !key.isEmpty else {
            throw StudioError("this package was narrated with ElevenLabs; add your ElevenLabs key in "
                              + "Settings to regenerate it")
        }
        return ElevenLabsNarrator(client: ElevenLabsClient(apiKey: key),
                                  voiceID: manifest.narration.voiceID,
                                  modelID: manifest.narration.modelID)
    }

    // MARK: - Notices

    /// The feature degrades with a notice rather than failing the window, the way the
    /// walkthrough pipeline uses `pipelineNotice`.
    func note(_ headline: String, _ error: Error) {
        let detail = (error as? StudioError)?.message ?? error.localizedDescription
        notices.append(OnboardingNotice(message: "\(headline): \(detail)"))
    }

    func dismiss(_ notice: OnboardingNotice) {
        notices.removeAll { $0.id == notice.id }
    }
}

/// The companion's lower half.
enum CompanionTab: String, CaseIterable, Identifiable {
    case chat = "Chat"
    case bookmarks = "Bookmarks"
    case flags = "Flags"

    var id: String { rawValue }
}

/// Which pane owns the centre of the onboarding window.
///
/// Declared outside `OnboardingViewModel`: a type nested in a `@MainActor` type inherits
/// that isolation, and an isolated `==` cannot satisfy `Equatable`'s nonisolated
/// requirement.
enum PlayerStage: Equatable {
    /// The hub web view is showing a document, a diagram, a trace or a file.
    case hub
    /// The player has the stage.
    case video(String)
}

/// A moment worth coming back to, with the anchor that was on screen (ON-9.5). Outside
/// the view model for the same reason as `PlayerStage`: it is `Codable`.
struct OnboardingBookmark: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var videoID: String
    var t: Double
    var note: String
    var anchor: String?

    private enum CodingKeys: String, CodingKey { case id, videoID, t, note, anchor }

    init(videoID: String, t: Double, note: String, anchor: String? = nil) {
        self.videoID = videoID
        self.t = t
        self.note = note
        self.anchor = anchor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        videoID = try c.decodeIfPresent(String.self, forKey: .videoID) ?? ""
        t = try c.decodeIfPresent(Double.self, forKey: .t) ?? 0
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        anchor = try c.decodeIfPresent(String.self, forKey: .anchor)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(videoID, forKey: .videoID)
        try c.encode(t, forKey: .t)
        try c.encode(note, forKey: .note)
        try c.encodeIfPresent(anchor, forKey: .anchor)
    }
}
