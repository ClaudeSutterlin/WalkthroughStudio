import SwiftUI

/// The wizard's review screen: one card per step with everything the AI
/// produced, editable inline. Advanced (frame-by-frame) editing lives behind
/// the toolbar's Advanced button for the rare correction cases.
struct ReviewView: View {
    @ObservedObject var vm: StudioViewModel

    var body: some View {
        VStack(spacing: 0) {
            if let notice = vm.pipelineNotice, !vm.isBusy {
                noticeBanner(notice)
            }

            if vm.steps.isEmpty {
                if vm.isBusy {
                    Spacer()
                    VStack(spacing: 12) {
                        ProgressView()
                        Text(vm.busyMessage ?? "Working…")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                } else {
                    ContentUnavailableView(
                        "No steps detected",
                        systemImage: "rectangle.split.3x1",
                        description: Text("The recording didn't have clear screen changes. Use Advanced to add steps at the playhead.")
                    )
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 14) {
                        ForEach(Array(vm.steps.enumerated()), id: \.element.id) { index, step in
                            if let binding = vm.binding(for: step.id) {
                                ReviewCard(vm: vm, step: binding, index: index)
                            }
                        }
                    }
                    .padding(16)
                }
                .background(Brand.cream.opacity(0.6))
            }

            Divider()
            exportBar
        }
    }

    private func noticeBanner(_ notice: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Brand.coral)
            Text(notice)
                .font(.callout)
            Spacer()
            SettingsLink {
                Text("Open Settings")
            }
            Button("Run AI") { vm.runAIStages() }
                .disabled(vm.steps.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Brand.soft)
    }

    private var exportBar: some View {
        HStack(spacing: 10) {
            Text("\(vm.steps.count) steps")
                .foregroundStyle(.secondary)
                .font(.callout)
            Spacer()

            Button {
                vm.exportNarratedVideo()
            } label: {
                Label("Export Video…", systemImage: "film")
            }
            .disabled(vm.narrationAudio.isEmpty)
            .help(vm.narrationAudio.isEmpty
                  ? "Generate the voice-over first (scripts + ElevenLabs key needed)"
                  : "Choose format (as recorded or framed 16:9), options, and destination")

            Button {
                vm.exportTutorial()
            } label: {
                Label("Tutorial Steps…", systemImage: "list.bullet.rectangle")
            }
            .help("Export slug-named PNGs + the tutorialSteps payload for the pilot page")

            Button {
                vm.exportBranded()
            } label: {
                Label("App Store Shots…", systemImage: vm.deviceKind.symbolName)
            }
            .buttonStyle(.borderedProminent)
            .tint(Brand.coral)
            .disabled(!vm.deviceKind.supportsAppStoreExport)
            .help(vm.deviceKind.supportsAppStoreExport
                  ? "Render every step in the LiveAgain frame at both App Store sizes"
                  : "App Store screenshots are iPhone/iPad only — not available for \(vm.deviceKind.label) recordings")
        }
        .disabled(vm.isBusy)
        .padding(12)
        .background(.bar)
    }
}

// MARK: - Step card

private struct ReviewCard: View {
    @ObservedObject var vm: StudioViewModel
    @Binding var step: WalkthroughStep
    let index: Int

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Frame
            VStack(spacing: 6) {
                if let image = vm.thumbnails[step.id] {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 132)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Brand.soft)
                        .frame(width: 132, height: 132)
                        .overlay { Image(systemName: "photo").foregroundStyle(Brand.faded) }
                }
                Text("Step \(index + 1) · \(StudioViewModel.formatTime(step.startTime))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // Copy + narration + slide
            VStack(alignment: .leading, spacing: 10) {
                TextField("Area (e.g. Content → Me)", text: $step.area)
                    .textFieldStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextField("Title", text: $step.title)
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))

                editor(text: $step.body, placeholder: "1–2 sentences of onboarding copy.", minHeight: 44)

                // Narration
                HStack(spacing: 8) {
                    Label("Narration", systemImage: "waveform")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let duration = vm.narrationDurations[step.id] {
                        Button {
                            vm.playNarration(stepID: step.id)
                        } label: {
                            Label(String(format: "Play (%.1fs)", duration), systemImage: "play.circle.fill")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Brand.coral)
                        .font(.caption)
                    }
                    Button(vm.narrationAudio[step.id] == nil ? "Generate Voice" : "Re-record Voice") {
                        vm.synthesizeVoiceover(stepIDs: [step.id])
                    }
                    .controlSize(.small)
                    .disabled(vm.isBusy || step.script.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                editor(text: $step.script, placeholder: "Voice-over script for this step.", minHeight: 44)

                // App Store slide
                Label("App Store slide", systemImage: "iphone")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Headline (<br> breaks lines, <span class=\"accent\"> for coral)", text: $step.headline)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                TextField("Subhead", text: $step.subheadline)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(.quaternary)
        )
    }

    private func editor(text: Binding<String>, placeholder: String, minHeight: CGFloat) -> some View {
        // Fixed-light background → fixed-dark text (system color goes white in dark mode).
        TextEditor(text: text)
            .font(.body)
            .foregroundColor(Brand.charcoal)
            .frame(minHeight: minHeight)
            .scrollContentBackground(.hidden)
            .padding(4)
            .background(Brand.warm, in: RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 9)
                        .padding(.leading, 9)
                        .allowsHitTesting(false)
                }
            }
    }
}
