import SwiftUI
import AVKit

/// AppKit AVPlayerView wrapped for SwiftUI. We deliberately avoid SwiftUI's
/// `VideoPlayer` — instantiating its generic class metadata aborts at runtime
/// on some macOS builds (_AVKit_SwiftUI getSuperclassMetadata fatalError).
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }
}

/// The Steps & Copy tab: player + step re-timing + tutorialSteps fields.
struct StepEditorView: View {
    @ObservedObject var vm: StudioViewModel

    var body: some View {
        HSplitView {
            playerPane
                .frame(minWidth: 380)
            editorPane
                .frame(minWidth: 400)
        }
    }

    private var playerPane: some View {
        VStack(spacing: 12) {
            PlayerView(player: vm.player)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 8) {
                if let id = vm.selectedStepID {
                    Button {
                        vm.setFrameToPlayhead(stepID: id)
                    } label: {
                        Label("Use This Frame as Screenshot", systemImage: "camera.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.coral)
                    .help("Set the frame under the playhead as the selected step's screenshot")
                    Button("Set Step Start Here") { vm.setStartToPlayhead(stepID: id) }
                        .help("Move the selected step's start to the playhead")
                }
                Button("Split Step Here") { vm.addStepAtPlayhead() }
                    .help("Split the step under the playhead into two")
                if let id = vm.selectedStepID {
                    Button(role: .destructive) {
                        vm.removeStep(id: id)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .help("Delete the selected step (its time merges into the previous step)")
                }
            }
            .disabled(vm.isBusy)
        }
        .padding(12)
    }

    @ViewBuilder
    private var editorPane: some View {
        if let id = vm.selectedStepID, let binding = vm.binding(for: id) {
            StepForm(vm: vm, step: binding)
        } else {
            ContentUnavailableView(
                "No step selected",
                systemImage: "rectangle.split.3x1",
                description: Text("Select a step in the sidebar, or run Detect Steps.")
            )
        }
    }
}

private struct StepForm: View {
    @ObservedObject var vm: StudioViewModel
    @Binding var step: WalkthroughStep

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Chosen frame
                VStack(alignment: .leading, spacing: 6) {
                    Text("Chosen frame — \(StudioViewModel.formatTime(step.frameTime))")
                        .font(.headline)
                    if let image = vm.thumbnails[step.id] {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .onTapGesture { vm.seek(to: step.frameTime) }
                    }
                    Text("Scrub the player to a clean frame (no transitions or toasts), then press “Use This Frame as Screenshot” under the player.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                // Timing
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Start").gridColumnAlignment(.trailing)
                        Text(StudioViewModel.formatTime(step.startTime)).monospacedDigit()
                        Text("End")
                        Text(StudioViewModel.formatTime(step.endTime)).monospacedDigit()
                        Text("Length")
                        Text(StudioViewModel.formatTime(step.duration)).monospacedDigit()
                    }
                    .font(.callout)
                }

                Divider()

                // tutorialSteps contract fields
                Text("Onboarding copy (tutorialSteps)")
                    .font(.headline)

                Grid(alignment: .topLeading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Text("Slug").gridColumnAlignment(.trailing).foregroundStyle(.secondary)
                        TextField("me", text: $step.slug)
                    }
                    GridRow {
                        Text("Area").foregroundStyle(.secondary)
                        TextField("Content → Me", text: $step.area)
                    }
                    GridRow {
                        Text("Title").foregroundStyle(.secondary)
                        TextField("Make it yours", text: $step.title)
                    }
                    GridRow {
                        Text("Body").foregroundStyle(.secondary)
                        TextEditor(text: $step.body)
                            .font(.body)
                            .frame(minHeight: 60)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                    }
                    GridRow {
                        Text("Alt").foregroundStyle(.secondary)
                        TextField("Accessibility description of the screenshot", text: $step.alt)
                    }
                }
                .textFieldStyle(.roundedBorder)

                Toggle("Include in tutorial export (Output B)", isOn: $step.includeInTutorial)
                Toggle("Include in branded export (Output C)", isOn: $step.includeInBranded)

                Divider()

                Text("Raw transcript for this step")
                    .font(.headline)
                // Brand.warm is a fixed light background, so the text color must
                // be fixed-dark too — system .primary turns white in dark mode.
                Text(step.transcript.isEmpty ? "No transcript yet — run Transcribe in the toolbar." : step.transcript)
                    .font(.callout)
                    .foregroundStyle(step.transcript.isEmpty ? Brand.faded : Brand.charcoal)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Brand.warm, in: RoundedRectangle(cornerRadius: 8))
            }
            .padding(16)
        }
    }
}
