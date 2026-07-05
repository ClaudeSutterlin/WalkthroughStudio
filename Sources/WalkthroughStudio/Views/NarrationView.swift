import SwiftUI

/// The Narration tab (Output A): per-step scripts → polish → synthesize → export.
struct NarrationView: View {
    @ObservedObject var vm: StudioViewModel
    @AppStorage(SettingsKeys.keepOriginalAudio) private var keepOriginalAudio = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    vm.polishScripts()
                } label: {
                    Label("Polish Scripts with Claude", systemImage: "sparkles")
                }
                .help("Clean up raw transcripts into voice-over scripts (removes filler, tightens tone)")

                Button {
                    vm.synthesizeVoiceover()
                } label: {
                    Label("Synthesize All", systemImage: "speaker.wave.2")
                }
                .help("Generate the ElevenLabs voice-over for every step with a script")

                Toggle("Keep original audio", isOn: $keepOriginalAudio)
                    .toggleStyle(.checkbox)
                    .help("Mix the recording's original audio under the new narration")

                Spacer()

                Button {
                    vm.exportNarratedVideo()
                } label: {
                    Label("Export Video…", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.coral)
                .help("Choose format (as recorded or framed 16:9), options, and destination")
            }
            .disabled(vm.isBusy)
            .padding(12)

            Divider()

            List {
                ForEach(vm.steps) { step in
                    if let binding = vm.binding(for: step.id) {
                        NarrationRow(vm: vm, step: binding)
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

private struct NarrationRow: View {
    @ObservedObject var vm: StudioViewModel
    @Binding var step: WalkthroughStep

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(step.displayName)
                    .font(.headline)
                Text("\(StudioViewModel.formatTime(step.startTime)) – \(StudioViewModel.formatTime(step.endTime))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()

                if vm.narrationAudio[step.id] != nil {
                    Label(
                        durationLabel,
                        systemImage: "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.green)
                    Button {
                        vm.playNarration(stepID: step.id)
                    } label: {
                        Image(systemName: "play.circle")
                    }
                    .help("Preview this step's narration")
                }

                Button("Synthesize") {
                    vm.synthesizeVoiceover(stepIDs: [step.id])
                }
                .controlSize(.small)
                .disabled(vm.isBusy || step.script.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if !step.transcript.isEmpty {
                Text("Raw: \(step.transcript)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            TextEditor(text: $step.script)
                .font(.body)
                .frame(minHeight: 56)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .overlay(alignment: .topLeading) {
                    if step.script.isEmpty {
                        Text("Narration script for this step — type it, or transcribe + polish.")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 8)
                            .padding(.leading, 6)
                            .allowsHitTesting(false)
                    }
                }

            if fitWarning {
                Label(
                    "This script is likely longer than the step (\(Int(step.duration))s at a ~2.5 words/sec speaking pace). It will be trimmed if it overlaps the next step.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 8)
    }

    private var durationLabel: String {
        if let duration = vm.narrationDurations[step.id] {
            return String(format: "%.1fs audio", duration)
        }
        return "audio ready"
    }

    private var fitWarning: Bool {
        let words = step.script.split(separator: " ").count
        guard words > 0, step.duration > 0 else { return false }
        return Double(words) / 2.5 > step.duration + 2.0
    }
}
