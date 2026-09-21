import SwiftUI
import AppKit

/// The onboarding window: navigator, stage, companion.
///
/// Pinned to the light colour scheme on `Brand.cream`, like every other branded surface
/// in this app — the package's own HTML is light, and a stage that flips to dark under
/// a system setting while the web view beside it stays cream looks broken.
struct OnboardingRootView: View {
    @StateObject private var vm = OnboardingViewModel()

    var body: some View {
        Group {
            if vm.isLoaded {
                loaded
            } else {
                EmptyPackageView(vm: vm)
            }
        }
        .frame(minWidth: 1280, minHeight: 800)
        .background(Brand.cream)
        .environment(\.colorScheme, .light)
        .sheet(isPresented: $vm.showOnboardSheet) {
            OnboardSheet(vm: vm)
        }
    }

    private var loaded: some View {
        VStack(spacing: 0) {
            HSplitView {
                HubNavigatorView(vm: vm)
                    .frame(minWidth: 240, idealWidth: 290, maxWidth: 380)
                StageView(vm: vm)
                    .frame(minWidth: 520)
                CompanionPanel(vm: vm, clock: vm.clock)
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)
            }
            noticeBanner
            statusBar
        }
        .focusable()
        .onKeyPress(.escape) {
            guard vm.isDocked else { return .ignored }
            vm.backToVideo()
            return .handled
        }
        .onKeyPress { press in handleKey(press.characters) }
    }

    // MARK: Chrome

    @ViewBuilder
    private var noticeBanner: some View {
        if !vm.notices.isEmpty {
            VStack(spacing: 0) {
                ForEach(vm.notices) { notice in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "info.circle.fill").foregroundStyle(Brand.coral)
                        Text(notice.message)
                            .font(.caption)
                            .foregroundStyle(Brand.charcoal)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Dismiss") { vm.dismiss(notice) }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.soft)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if vm.isBusy {
                ProgressView().controlSize(.small)
                Text(vm.busyMessage).font(.caption).foregroundStyle(Brand.muted)
            } else {
                Text(vm.packageName).font(.caption).foregroundStyle(Brand.muted)
            }
            Spacer()
            if case .video = vm.stage {
                Text("J K L  transport   [ ]  chapter   C  captions   ⌘B  bookmark")
                    .font(.caption2)
                    .foregroundStyle(Brand.muted)
            }
            Button("Open another…") { vm.showOnboardSheet = true }
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Brand.cream)
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: Transport keys

    /// J K L, `[` `]` and C — the shortcuts an editor expects, because an onboarding
    /// video is scrubbed far more than it is watched straight through. Matched on the
    /// characters rather than the key, so a layout that puts `[` somewhere else still
    /// steps chapters.
    func handleKey(_ characters: String) -> KeyPress.Result {
        switch characters.lowercased() {
        case "k": vm.togglePlayPause()
        case "j": vm.seek(to: vm.clock.t - 5)
        case "l": vm.seek(to: vm.clock.t + 5)
        case "[": vm.step(chapters: -1)
        case "]": vm.step(chapters: 1)
        case "c": vm.showCaptions.toggle()
        default: return .ignored
        }
        return .handled
    }
}

/// The centre pane: the player, or the package's hub in a web view (D20).
struct StageView: View {
    @ObservedObject var vm: OnboardingViewModel

    var body: some View {
        ZStack {
            if let store = vm.store {
                HubWebView(vm: vm, packageRoot: store.root)
                    // A scheme handler is bound to its configuration, so a different
                    // package needs a different web view, not the same one reloaded.
                    .id(store.root.path)
                    .opacity(isVideo ? 0 : 1)
                    .allowsHitTesting(!isVideo)
            }
            if isVideo {
                VideoPane(vm: vm, clock: vm.clock)
            }
        }
        .background(Brand.cream)
    }

    /// The web view is kept alive behind the player rather than torn down: rebuilding it
    /// means reloading the hub, re-rendering Mermaid and losing the reader's scroll
    /// position every time they glance at a video.
    private var isVideo: Bool {
        if case .video = vm.stage { return true }
        return false
    }
}

/// Before a package is open: recents, and the two ways in.
struct EmptyPackageView: View {
    @ObservedObject var vm: OnboardingViewModel
    @State private var recents: [URL] = OnboardingViewModel.recentPackages()

    var body: some View {
        VStack(spacing: 18) {
            Text("Onboard to a Codebase")
                .font(.custom("Georgia", size: 32))
                .foregroundStyle(Brand.charcoal)
            Text("Point the app at a repository and a fleet of research agents produces the "
                 + "package: diagrams, registers, traced critical paths and narrated code walks, "
                 + "every claim carrying the evidence it came from.")
                .font(.callout)
                .foregroundStyle(Brand.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)

            HStack(spacing: 12) {
                Button("Onboard to a Codebase…") { vm.showOnboardSheet = true }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.coral)
                Button("Open a Package…") { chooseFolder() }
            }

            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Brand.muted)
                    ForEach(recents, id: \.path) { url in
                        Button(url.lastPathComponent) {
                            Task { @MainActor in await vm.open(packageAt: url) }
                        }
                        .buttonStyle(.link)
                        .help(url.path)
                    }
                }
                .padding(.top, 10)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.cream)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose an .onboarding package folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            await vm.open(packageAt: url)
            recents = OnboardingViewModel.recentPackages()
        }
    }
}
