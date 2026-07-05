import SwiftUI

/// The video export modal: format (as-recorded vs framed 16:9), pacing, audio,
/// and destination in one place — options used to hide in a toolbar popover and
/// were easy to forget.
struct ExportVideoSheet: View {
    @ObservedObject var vm: StudioViewModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKeys.keepOriginalAudio) private var keepOriginalAudio = false

    @State private var fileName = ""
    @State private var directory = URL(fileURLWithPath: NSHomeDirectory())

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 6) {
                Text("Export Video")
                    .font(.custom("Georgia", size: 28))
                    .foregroundStyle(Brand.charcoal)
                Text("The new voice-over is mixed in either way. Captions (.srt) land next to the video.")
                    .font(.callout)
                    .foregroundStyle(Brand.muted)
            }
            .padding(.top, 4)

            // Format
            HStack(spacing: 14) {
                FormatCard(
                    icon: vm.deviceKind.symbolName,
                    title: "As recorded",
                    caption: "The original \(vm.deviceKind.label) recording with the new narration swapped in.",
                    selected: !vm.frameVideo16x9
                ) { setFormat(framed: false) }
                FormatCard(
                    icon: "rectangle.inset.filled",
                    title: "Framed 16:9",
                    caption: "1920×1080 branded frame around the recording — each step shows its slide copy. For YouTube, decks, the pilot hero.",
                    selected: vm.frameVideo16x9
                ) { setFormat(framed: true) }
            }

            // Options
            VStack(alignment: .leading, spacing: 12) {
                Toggle(isOn: $vm.trimQuietStretches) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Advance scenes with the narration")
                            .foregroundStyle(Brand.charcoal)
                        Text("Cuts each step to its voice-over length (plus a beat) so the video doesn't roll silently between steps.")
                            .font(.caption)
                            .foregroundStyle(Brand.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Toggle(isOn: $keepOriginalAudio) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep original audio underneath")
                            .foregroundStyle(Brand.charcoal)
                        Text("Mixes the recording's own sound quietly under the narration.")
                            .font(.caption)
                            .foregroundStyle(Brand.muted)
                    }
                }
            }
            .toggleStyle(.checkbox)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Brand.faded.opacity(0.35)))

            // Destination
            VStack(alignment: .leading, spacing: 8) {
                Text("Save as")
                    .font(.headline)
                    .foregroundStyle(Brand.charcoal)
                HStack(spacing: 6) {
                    TextField("File name", text: $fileName)
                        .textFieldStyle(.roundedBorder)
                    Text(".mp4 + .srt")
                        .font(.callout)
                        .foregroundStyle(Brand.muted)
                }
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .foregroundStyle(Brand.coral)
                    Text(displayPath)
                        .font(.callout)
                        .foregroundStyle(Brand.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…") { chooseDirectory() }
                        .controlSize(.small)
                }
                if fileExists {
                    Label("A video with this name is already there — it will be replaced.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Export") { export() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.coral)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(26)
        .frame(width: 560)
        .background(Brand.cream)
        .environment(\.colorScheme, .light)
        .onAppear {
            fileName = vm.suggestedVideoExportName
            directory = vm.suggestedVideoExportDirectory
        }
    }

    private var trimmedName: String {
        var name = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(".mp4") { name = String(name.dropLast(4)) }
        return name
    }

    private var outputURL: URL {
        directory.appendingPathComponent(trimmedName + ".mp4")
    }

    private var fileExists: Bool {
        !trimmedName.isEmpty && FileManager.default.fileExists(atPath: outputURL.path)
    }

    private var displayPath: String {
        directory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    /// Switch format; if the name is still the suggestion for the old format,
    /// follow along with the new suffix.
    private func setFormat(framed: Bool) {
        let wasDefault = trimmedName == vm.suggestedVideoExportName
        vm.frameVideo16x9 = framed
        if wasDefault || trimmedName.isEmpty {
            fileName = vm.suggestedVideoExportName
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        if panel.runModal() == .OK, let url = panel.url {
            directory = url
        }
    }

    private func export() {
        guard !trimmedName.isEmpty else { return }
        let target = outputURL
        dismiss()
        vm.exportNarratedVideo(to: target)
    }
}

/// A selectable format card — coral outline when chosen.
private struct FormatCard: View {
    let icon: String
    let title: String
    let caption: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 30))
                    .foregroundStyle(selected ? Brand.coral : Brand.faded)
                    .frame(height: 36)
                Text(title)
                    .font(.headline)
                    .foregroundStyle(Brand.charcoal)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(Brand.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(selected ? Brand.coral.opacity(0.08) : Color.white.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(selected ? Brand.coral : Brand.faded.opacity(0.4), lineWidth: selected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}
