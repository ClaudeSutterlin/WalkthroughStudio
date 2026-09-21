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
    static func readingOrder(hub: HubIndex, manifest: OnboardingManifest) -> [HubIndex.Item] {
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

    private func persistBookmarks() {
        guard let store else { return }
        do {
            try store.writeJSON(bookmarks, to: "review/bookmarks.json")
        } catch {
            note("Could not save your bookmarks", error)
        }
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
