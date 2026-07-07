import SwiftUI
import UniformTypeIdentifiers

enum StudioTab: String, CaseIterable, Identifiable {
    case steps = "Steps & Copy"
    case narration = "Narration"
    case branded = "Branded"
    case export = "Export"
    var id: String { rawValue }
}

struct ContentView: View {
    @StateObject private var vm = StudioViewModel()
    @State private var tab: StudioTab = .steps
    @State private var showSettings = false

    var body: some View {
        Group {
            if vm.videoURL == nil {
                ImportView(vm: vm)
            } else if vm.isProcessingPipeline {
                ProcessingView(vm: vm)
            } else if vm.showAdvanced {
                studio
            } else {
                review
            }
        }
        .safeAreaInset(edge: .bottom) { statusBar }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $vm.showThemeEditor) { ThemeEditorView(vm: vm) }
        .sheet(isPresented: $vm.showVideoExportSheet) { ExportVideoSheet(vm: vm) }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { vm.errorMessage != nil },
                set: { if !$0 { vm.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { vm.errorMessage = nil }
        } message: {
            Text(vm.errorMessage ?? "")
        }
    }

    private var review: some View {
        NavigationStack {
            ReviewView(vm: vm)
                .navigationTitle("Review")
                .toolbar {
                    ToolbarItemGroup {
                        Button {
                            vm.runAIStages()
                        } label: {
                            Label("Run AI", systemImage: "sparkles")
                                .labelStyle(.titleAndIcon)
                        }
                        .help("Re-draft copy, narration scripts, and voice-over from the transcript")
                        .disabled(vm.isBusy || vm.steps.isEmpty)

                        Button {
                            vm.showAdvanced = true
                        } label: {
                            Label("Advanced", systemImage: "slider.horizontal.3")
                                .labelStyle(.titleAndIcon)
                        }
                        .help("Frame-by-frame step editing, narration tools, and slide preview — for corrections")

                        projectMenu
                        settingsButton
                    }
                }
        }
    }

    private var projectMenu: some View {
        Menu {
            Button("Save Project…") { vm.saveProject() }
            Button("Open Project…") { vm.openProject() }
            Divider()
            if let briefing = vm.briefingURL {
                Text("Briefing: \(briefing.lastPathComponent)")
                Button("Replace Briefing…") { vm.attachBriefing() }
                Button("Remove Briefing") { vm.removeBriefing() }
            } else {
                Button("Attach Project Briefing…") { vm.attachBriefing() }
            }
            Divider()
            Button("Customize Frame Design…") { vm.showThemeEditor = true }
            Button("Edit HTML Templates…") { vm.editTemplatesInFinder() }
            Divider()
            Button("Import New Recording…") { pickVideo() }
        } label: {
            Label("Project", systemImage: vm.briefingURL == nil ? "folder" : "folder.fill")
                .labelStyle(.titleAndIcon)
        }
        .help("Save/open a project, attach a briefing (PDF, Word, Markdown, text…) to guide all generated copy, or import a new recording")
    }

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Label("Settings", systemImage: "gearshape")
                .labelStyle(.titleAndIcon)
        }
        .help("API keys, voice, and transcription settings")
    }

    private var studio: some View {
        NavigationSplitView {
            StepSidebar(vm: vm)
                .navigationSplitViewColumnWidth(min: 240, ideal: 280)
        } detail: {
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    ForEach(StudioTab.allCases) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider()

                switch tab {
                case .steps: StepEditorView(vm: vm)
                case .narration: NarrationView(vm: vm)
                case .branded: BrandedView(vm: vm)
                case .export: ExportView(vm: vm)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    vm.showAdvanced = false
                } label: {
                    Label("Done", systemImage: "checkmark.circle")
                        .labelStyle(.titleAndIcon)
                }
                .help("Back to the review screen")

                Button {
                    vm.detectSteps()
                } label: {
                    Label("Detect Steps", systemImage: "rectangle.split.3x1")
                        .labelStyle(.titleAndIcon)
                }
                .help("Scan the recording for screen changes and rebuild the step list (replaces current steps)")
                .disabled(vm.isBusy)

                Button {
                    vm.transcribe()
                } label: {
                    Label("Transcribe", systemImage: "waveform")
                        .labelStyle(.titleAndIcon)
                }
                .help("Transcribe the recording's narration on-device and assign it to steps")
                .disabled(vm.isBusy)

                Button {
                    vm.generateCopy()
                } label: {
                    Label("Generate Copy", systemImage: "sparkles")
                        .labelStyle(.titleAndIcon)
                }
                .help("Have Claude draft titles, body copy, alt text, and slide headlines from the transcripts")
                .disabled(vm.isBusy || vm.steps.isEmpty)

                projectMenu
                settingsButton
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if let busy = vm.busyMessage {
                if let progress = vm.progress {
                    ProgressView(value: progress)
                        .frame(width: 160)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                Text(busy)
                    .font(.callout)
            } else {
                Text(vm.statusMessage.isEmpty ? "Ready" : vm.statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let exportURL = vm.lastExportURL {
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([exportURL])
                    } label: {
                        Label(exportURL.lastPathComponent, systemImage: "arrow.up.forward.square")
                            .font(.callout)
                            .foregroundStyle(Brand.coral)
                            .underline()
                    }
                    .buttonStyle(.plain)
                    .help("Reveal in Finder")
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func pickVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            vm.importVideo(url: url)
        }
    }
}

// MARK: - Import (empty state)

struct ImportView: View {
    @ObservedObject var vm: StudioViewModel
    @State private var showNewProject = false
    @State private var showSetup = false

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "film.stack")
                .font(.system(size: 52))
                .foregroundStyle(Brand.coral)
            Text("Walkthrough Studio")
                .font(.custom("Georgia", size: 38))
                .foregroundStyle(Brand.charcoal)
            Text("Turn one screen recording into a narrated video, onboarding steps, and App Store screenshots.")
                .multilineTextAlignment(.center)
                .foregroundStyle(Brand.muted)

            HStack(spacing: 12) {
                Button("New Project…") { showNewProject = true }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.coral)
                Button("Open Saved Project…") { vm.openProject() }
                    .controlSize(.large)
            }
            .padding(.top, 6)

            if let busy = vm.busyMessage {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy)
                        .foregroundStyle(Brand.muted)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.cream)
        .environment(\.colorScheme, .light)
        .sheet(isPresented: $showNewProject) {
            NewProjectSheet(vm: vm)
        }
        .sheet(isPresented: $showSetup, onDismiss: {
            // Setup done (or skipped) → straight into the first project.
            if vm.videoURL == nil && !vm.isBusy { showNewProject = true }
        }) {
            SetupSheet(vm: vm)
        }
        .task {
            if !Defaults.bool(SettingsKeys.didCompleteSetup) {
                // Off the main thread: this read can trigger a one-time macOS
                // access prompt while migrating keys from a pre-rename build.
                let hasKeys = await Task.detached {
                    !Keychain.anthropicKey.isEmpty || !Keychain.elevenLabsKey.isEmpty
                }.value
                if hasKeys {
                    // Keys already exist (e.g. migrated) — nothing to set up.
                    UserDefaults.standard.set(true, forKey: SettingsKeys.didCompleteSetup)
                } else {
                    showSetup = true
                    return
                }
            }
            if vm.videoURL == nil && !vm.isBusy {
                showNewProject = true
            }
        }
    }
}

// MARK: - New Project modal

struct NewProjectSheet: View {
    @ObservedObject var vm: StudioViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var video: URL?
    @State private var briefing: URL?
    @State private var deviceChoice: String = "auto"

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("New Project")
                    .font(.custom("Georgia", size: 32))
                    .foregroundStyle(Brand.charcoal)
                Text("Drop in your files. The briefing shapes every word the AI writes — from the first pass.")
                    .font(.callout)
                    .foregroundStyle(Brand.muted)
            }
            .padding(.top, 4)

            HStack(alignment: .top, spacing: 16) {
                DropZone(
                    icon: "film",
                    title: "Recording",
                    badge: "Required",
                    badgeColor: Brand.coral,
                    emptyHint: "Drop a screen recording\n(.mov or .mp4)",
                    extensions: ["mov", "mp4", "m4v"],
                    contentTypes: [.movie, .mpeg4Movie, .quickTimeMovie],
                    url: $video
                )
                DropZone(
                    icon: "doc.text",
                    title: "Briefing",
                    badge: "Optional",
                    badgeColor: Brand.faded,
                    emptyHint: "Drop tone & messaging guidance\n(PDF, Word, Markdown, text…)",
                    extensions: Briefing.allExtensions,
                    contentTypes: Briefing.contentTypes,
                    url: $briefing
                )
            }

            HStack(spacing: 10) {
                Text("Recorded on")
                    .font(.callout)
                    .foregroundStyle(Brand.muted)
                Picker("", selection: $deviceChoice) {
                    Text("Auto-detect").tag("auto")
                    ForEach(DeviceKind.allCases) { kind in
                        Text(kind.label).tag(kind.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)
            }
            Text(deviceChoice == "computer"
                 ? "Computer recordings get the framed 16:9 video and tutorial exports — App Store screenshots are iPhone/iPad only."
                 : "Device sets the frame style, status-bar cleanup, and App Store sizes. Auto-detect reads the recording's shape.")
                .font(.caption)
                .foregroundStyle(Brand.faded)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create Project") { create() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.coral)
                    .disabled(video == nil || vm.isBusy)
                    .help(video == nil ? "Add a recording first" : "Import and run the pipeline — grounded in the briefing from the start")
            }
        }
        .padding(28)
        .frame(width: 640)
        .background(Brand.cream)
        .environment(\.colorScheme, .light)
    }

    private func create() {
        guard let video else { return }
        // Attach the briefing FIRST so the pipeline's AI stages are grounded in
        // it from the very first generation pass.
        if let briefing {
            guard vm.attachBriefing(url: briefing) else { return } // unreadable PDF: stay here, show the error
        }
        vm.importVideo(url: video, device: DeviceKind(rawValue: deviceChoice))
        dismiss()
    }
}

/// A drag-and-drop file well: dashed outline while empty, coral highlight while
/// a drag hovers, filename + checkmark once filled.
private struct DropZone: View {
    let icon: String
    let title: String
    let badge: String
    let badgeColor: Color
    let emptyHint: String
    let extensions: [String]
    let contentTypes: [UTType]
    @Binding var url: URL?
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Brand.charcoal)
                Text(badge)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(badge == "Required" ? Brand.coral : Brand.muted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(badgeColor.opacity(0.14)))
            }

            VStack(spacing: 12) {
                if let url {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Brand.coral)
                    Text(url.lastPathComponent)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Brand.charcoal)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .truncationMode(.middle)
                        .padding(.horizontal, 12)
                    Button("Remove") { self.url = nil }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(Brand.muted)
                        .underline()
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 34))
                        .foregroundStyle(targeted ? Brand.coral : Brand.faded)
                    Text(emptyHint)
                        .font(.callout)
                        .foregroundStyle(Brand.muted)
                        .multilineTextAlignment(.center)
                    Button("Choose…") { choose() }
                        .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 180)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(targeted ? Brand.soft : .white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(
                        targeted ? Brand.coral : (url == nil ? Brand.faded.opacity(0.55) : Brand.coral.opacity(0.45)),
                        style: StrokeStyle(lineWidth: 1.6, dash: url == nil ? [7, 5] : [])
                    )
            )
            .animation(.easeOut(duration: 0.15), value: targeted)
            .dropDestination(for: URL.self) { urls, _ in
                guard let dropped = urls.first(where: { extensions.contains($0.pathExtension.lowercased()) }) else {
                    return false
                }
                url = dropped
                return true
            } isTargeted: {
                targeted = $0
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = contentTypes
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let picked = panel.url {
            url = picked
        }
    }
}

// MARK: - Sidebar

struct StepSidebar: View {
    @ObservedObject var vm: StudioViewModel

    var body: some View {
        List(selection: $vm.selectedStepID) {
            Section("Steps (\(vm.steps.count))") {
                ForEach(vm.steps) { step in
                    HStack(spacing: 10) {
                        thumbnail(for: step)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(step.displayName)
                                .font(.callout)
                                .lineLimit(1)
                            Text("\(StudioViewModel.formatTime(step.startTime)) – \(StudioViewModel.formatTime(step.endTime))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(step.id)
                    .contextMenu {
                        Button("Delete Step", role: .destructive) {
                            vm.removeStep(id: step.id)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .onChange(of: vm.selectedStepID) { _, newValue in
            if let id = newValue, let step = vm.steps.first(where: { $0.id == id }) {
                vm.seek(to: step.frameTime)
            }
        }
    }

    @ViewBuilder
    private func thumbnail(for step: WalkthroughStep) -> some View {
        if let image = vm.thumbnails[step.id] {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            RoundedRectangle(cornerRadius: 6)
                .fill(Brand.soft)
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(Brand.faded)
                }
        }
    }
}
