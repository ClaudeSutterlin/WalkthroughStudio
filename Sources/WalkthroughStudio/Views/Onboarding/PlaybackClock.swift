import Foundation
import AVFoundation
import Combine

/// The one clock everything on screen reads: the caption line, the chapter strip, the
/// companion's "on screen now" card and (later) the chat context.
///
/// A single periodic observer at 4 Hz rather than each view polling the player. 250 ms
/// is fast enough that a chip changes the moment the picture does and slow enough that
/// a two-hour video does not spend the afternoon re-rendering a sidebar.
@MainActor
final class PlaybackClock: ObservableObject {

    static let tick = 0.25

    @Published private(set) var t: Double = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var interval: CodeRefInterval?
    @Published private(set) var segment: TranscriptSegment?
    @Published private(set) var chapter: ChapterMarker?

    // `deinit` is nonisolated and must still hand the time observer back, so these two
    // are the only stored properties outside the actor. Both are touched on the main
    // thread everywhere else.
    private nonisolated(unsafe) weak var player: AVPlayer?
    private nonisolated(unsafe) var observer: Any?
    private var rateObservation: NSKeyValueObservation?
    private var transcript = TranscriptDoc()
    private var coderefs = CodeRefMap()

    deinit {
        // `removeTimeObserver` has to happen before the player goes, and a deinit
        // cannot hop to the main actor, so the token is released on the player itself.
        if let observer, let player { player.removeTimeObserver(observer) }
    }

    /// Start (or restart) the clock on `player`, resolving against this video's files.
    func attach(to player: AVPlayer, transcript: TranscriptDoc, coderefs: CodeRefMap) {
        detach()
        self.player = player
        self.transcript = transcript
        self.coderefs = coderefs
        let interval = CMTime(seconds: PlaybackClock.tick, preferredTimescale: 600)
        observer = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = time.seconds
            Task { @MainActor in self?.update(to: seconds) }
        }
        rateObservation = player.observe(\.rate, options: [.initial, .new]) { [weak self] observed, _ in
            let rate = observed.rate
            Task { @MainActor in self?.isPlaying = rate != 0 }
        }
        update(to: player.currentTime().seconds)
    }

    func detach() {
        if let observer, let player { player.removeTimeObserver(observer) }
        observer = nil
        rateObservation = nil
        player = nil
    }

    /// Re-resolve everything that depends on the time. Called on every tick and after a
    /// seek, so it must stay cheap: two binary searches and a comparison.
    func update(to seconds: Double) {
        guard seconds.isFinite else { return }
        t = max(0, seconds)
        let found = coderefs.lookup(t)
        if found?.shotId != interval?.shotId { interval = found }
        let line = transcript.segment(at: t)
        if line?.id != segment?.id { segment = line }
        let mark = transcript.chapter(at: t)
        if mark?.id != chapter?.id { chapter = mark }
    }

    /// The fraction of the video played, for the chapter strip's fill.
    var progress: Double {
        transcript.duration > 0 ? min(1, t / transcript.duration) : 0
    }

    var chapters: [ChapterMarker] { transcript.chapters }
    var duration: Double { transcript.duration }

    /// `4:32`, the form every caption and chip uses.
    static func timecode(_ seconds: Double) -> String {
        let whole = Int(max(0, seconds))
        return whole >= 3600
            ? String(format: "%d:%02d:%02d", whole / 3600, (whole % 3600) / 60, whole % 60)
            : String(format: "%d:%02d", whole / 60, whole % 60)
    }
}
