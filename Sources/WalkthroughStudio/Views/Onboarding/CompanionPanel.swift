import SwiftUI

/// The right pane. Today: the "on screen now" card, the docked mini-player and
/// bookmarks. M7 adds the chat transcript under them, which is why this is native —
/// a streaming conversation with tool rows does not belong in the package's web view.
struct CompanionPanel: View {
    @ObservedObject var vm: OnboardingViewModel
    @ObservedObject var clock: PlaybackClock

    @State private var bookmarkNote = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if vm.isDocked {
                    MiniPlayer(vm: vm, clock: clock)
                }
                onScreenCard
                coveredCard
                bookmarksCard
            }
            .padding(16)
        }
        .background(Brand.cream)
    }

    // MARK: On screen now

    /// Re-resolved on every tick from `coderefs.lookup(t)`: what the picture is showing,
    /// as chips that open it. This is the card that makes a video a door into the code
    /// rather than a thing you watch and then go looking.
    @ViewBuilder
    private var onScreenCard: some View {
        card("On screen now") {
            if let interval = clock.interval {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: CompanionPanel.icon(forSceneType: interval.sceneType))
                            .foregroundStyle(Brand.coral)
                        Text(interval.sceneType)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Brand.muted)
                        Spacer()
                        Text(PlaybackClock.timecode(interval.start))
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(Brand.muted)
                    }
                    if let highlight = interval.highlight, !highlight.callout.isEmpty {
                        Text(highlight.callout)
                            .font(.callout)
                            .foregroundStyle(Brand.charcoal)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(CompanionPanel.chipAnchors(of: interval), id: \.self) { anchor in
                        chip(anchor)
                    }
                    if let text = clock.segment?.text {
                        Text(text)
                            .font(.caption)
                            .foregroundStyle(Brand.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if case .hub = vm.stage {
                Text("Open a video to follow the narration alongside the code.")
                    .font(.caption)
                    .foregroundStyle(Brand.muted)
            } else {
                Text("Nothing is on screen yet.")
                    .font(.caption)
                    .foregroundStyle(Brand.muted)
            }
        }
    }

    private func chip(_ anchor: String) -> some View {
        Button {
            vm.open(anchor: anchor)
        } label: {
            Text(MarkdownLite.anchorLabel(anchor))
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Brand.soft)
                .foregroundStyle(Brand.charcoal)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(anchor)
    }

    // MARK: Where this is covered

    /// The backlink index, asked about whatever the stage is showing: every deliverable
    /// that cites this file. It is the answer that turns three artifacts into one
    /// surface (ON-8.2) — and it is why the index is built at projection time rather
    /// than searched for at read time.
    @ViewBuilder
    private var coveredCard: some View {
        if let path = coveredPath {
            card("Where \(path.split(separator: "/").last.map(String.init) ?? path) is covered") {
                let references = vm.backlinks.references(forPath: path)
                if references.isEmpty {
                    Text("Nothing else in this package cites \(path).")
                        .font(.caption)
                        .foregroundStyle(Brand.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(references, id: \.ref) { reference in
                            Button {
                                vm.open(anchor: reference.ref)
                            } label: {
                                HStack(spacing: 6) {
                                    Text(reference.kind)
                                        .font(.caption2)
                                        .foregroundStyle(Brand.muted)
                                        .frame(width: 48, alignment: .leading)
                                    Text(reference.label)
                                        .font(.caption)
                                        .foregroundStyle(Brand.coral)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                            .buttonStyle(.plain)
                            .help(reference.ref)
                        }
                    }
                }
            }
        }
    }

    /// The file the reader is looking at: the one the hub has open, or the one the
    /// current shot is highlighting.
    private var coveredPath: String? {
        if case .hub = vm.stage, let anchor = vm.hubAnchor,
           let path = ProjectionSupport.codePath(anchor) {
            return path
        }
        if let anchor = clock.interval?.primaryAnchor {
            return ProjectionSupport.codePath(anchor)
        }
        return nil
    }

    // MARK: Bookmarks

    @ViewBuilder
    private var bookmarksCard: some View {
        card("Bookmarks") {
            VStack(alignment: .leading, spacing: 8) {
                if vm.bookmarks.isEmpty {
                    Text("⌘B marks the moment you are watching, with a note. Your questions become a review list.")
                        .font(.caption)
                        .foregroundStyle(Brand.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(vm.bookmarks) { bookmark in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Button(PlaybackClock.timecode(bookmark.t)) {
                            vm.open(anchor: "video:\(bookmark.videoID)#t=\(String(format: "%.1f", bookmark.t))")
                        }
                        .buttonStyle(.link)
                        .font(.system(.caption, design: .monospaced))
                        Text(bookmark.note.isEmpty ? "(no note)" : bookmark.note)
                            .font(.caption)
                            .foregroundStyle(Brand.charcoal)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button {
                            vm.removeBookmark(bookmark)
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(Brand.muted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if vm.currentVideoID != nil {
                    HStack(spacing: 6) {
                        TextField("Note for this moment", text: $bookmarkNote)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                            .onSubmit(addBookmark)
                        Button("Mark", action: addBookmark)
                            .font(.caption)
                    }
                }
            }
        }
    }

    private func addBookmark() {
        vm.addBookmark(note: bookmarkNote.trimmingCharacters(in: .whitespacesAndNewlines))
        bookmarkNote = ""
    }

    // MARK: Chrome

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Brand.muted)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Brand.soft.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    /// Everything on screen that can be opened: the shot's anchors, plus the
    /// highlighted range when it is narrower than them. De-duplicated, because a shot
    /// whose highlight is its whole anchor would otherwise show the chip twice.
    static func chipAnchors(of interval: CodeRefInterval) -> [String] {
        var out: [String] = []
        for anchor in interval.anchors where !out.contains(anchor) { out.append(anchor) }
        if let highlight = interval.highlight?.anchor, !out.contains(highlight) { out.append(highlight) }
        return out
    }

    static func icon(forSceneType type: String) -> String {
        switch type {
        case "code": return "curlybraces"
        case "diagram": return "point.3.connected.trianglepath.dotted"
        case "terminal": return "terminal"
        case "table": return "tablecells"
        case "title": return "text.aligncenter"
        default: return "rectangle"
        }
    }
}
