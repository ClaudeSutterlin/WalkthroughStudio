import SwiftUI
import AVFoundation

/// The player stage: the video, a chapter strip cut to the real chapter boundaries, and
/// one caption line.
///
/// `PlayerView` (AppKit `AVPlayerView`) rather than SwiftUI's `VideoPlayer`, which
/// SIGABRTs at first render on this SDK — landmine 1 in CLAUDE.md. Do not switch back.
struct VideoPane: View {
    @ObservedObject var vm: OnboardingViewModel
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        VStack(spacing: 0) {
            PlayerView(player: vm.player)
                .background(Brand.charcoal)
                .frame(minHeight: 260)
            chapterStrip
            captionLine
        }
        .background(Brand.cream)
    }

    // MARK: Chapter strip

    /// Proportional segments, the current one filled coral, a click seeks. The widths
    /// come from the chapters' own times, so a two-second title card is two seconds
    /// wide — a strip of equal buttons would lie about where you are.
    private var chapterStrip: some View {
        GeometryReader { geometry in
            HStack(spacing: 2) {
                ForEach(clock.chapters) { chapter in
                    Button {
                        vm.seek(to: chapter.start)
                    } label: {
                        Text(chapter.title)
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .padding(.horizontal, 6)
                            .frame(width: width(of: chapter, in: geometry.size.width), height: 26,
                                   alignment: .leading)
                            .background(chapter.id == clock.chapter?.id ? Brand.coral : Brand.soft)
                            .foregroundStyle(chapter.id == clock.chapter?.id ? Brand.cream : Brand.charcoal)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help("\(chapter.title) — \(PlaybackClock.timecode(chapter.start))")
                }
            }
        }
        .frame(height: 26)
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private func width(of chapter: ChapterMarker, in total: CGFloat) -> CGFloat {
        guard clock.duration > 0, total > 0 else { return 40 }
        let gaps = CGFloat(max(0, clock.chapters.count - 1)) * 2
        let share = (chapter.end - chapter.start) / clock.duration
        return max(28, (total - gaps) * share)
    }

    // MARK: Caption

    @ViewBuilder
    private var captionLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(PlaybackClock.timecode(clock.t))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Brand.muted)
                .frame(width: 46, alignment: .trailing)
            if vm.showCaptions {
                Text(clock.segment?.text ?? " ")
                    .font(.callout)
                    .foregroundStyle(Brand.charcoal)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Spacer()
            }
            if let chapter = clock.chapter, let anchor = chapter.docAnchor {
                Button("Read the section") { vm.open(anchor: anchor) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 46, alignment: .top)
    }
}

/// The 320 px mini-player the video docks into when the viewer clicks into code or a
/// document. It keeps playing on the same clock, which is what makes "Back to video"
/// return to the moment rather than to the start (ON-8.7).
struct MiniPlayer: View {
    @ObservedObject var vm: OnboardingViewModel
    @ObservedObject var clock: PlaybackClock

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PlayerView(player: vm.player)
                .frame(height: 180)
                .background(Brand.charcoal)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack(spacing: 8) {
                Button {
                    vm.backToVideo()
                } label: {
                    Label("Back to video", systemImage: "arrow.uturn.left")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Brand.coral)
                Spacer()
                Text(PlaybackClock.timecode(clock.t))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Brand.muted)
            }
            if let text = clock.segment?.text {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(Brand.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
