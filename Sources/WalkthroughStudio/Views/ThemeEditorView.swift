import SwiftUI
import UniformTypeIdentifiers

/// Simple design editor for the branded frames (App Store slides + 16:9 video
/// wrapper): colors, background, wordmark/logo, headline font. The full escape
/// hatch — editing the HTML/CSS templates directly — lives behind the
/// "Edit HTML Templates…" button, which ships a Claude Code guide alongside.
struct ThemeEditorView: View {
    @ObservedObject var vm: StudioViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Text") {
                colorRow("Headline", \.headlineColor)
                colorRow("Accent", \.accentColor)
                colorRow("Subheadline", \.subColor)
                TextField("Headline font (CSS font-family)", text: binding(\.headlineFontCSS))
                Text("Any font installed on this Mac, e.g. `\"Avenir Next\", sans-serif`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Background") {
                Picker("Style", selection: binding(\.backgroundMode)) {
                    Text("Default gradient").tag("brand")
                    Text("Solid color").tag("color")
                    Text("Image").tag("image")
                }
                if vm.theme.backgroundMode == "color" {
                    colorRow("Color", \.backgroundColor)
                }
                if vm.theme.backgroundMode == "image" {
                    imageRow(
                        label: "Image",
                        path: \.backgroundImagePath,
                        hint: "Scaled to fill each frame (both portrait slides and the 16:9 canvas)."
                    )
                }
            }

            Section("Device") {
                colorRow("Bezel", \.bezelColor)
                if vm.deviceKind.statusBarFraction > 0 {
                    Picker("Status bar", selection: binding(\.statusBarMode)) {
                        Text("Clean (9:41, full battery)").tag("clean")
                        Text("Crop it off").tag("crop")
                        Text("As recorded").tag("off")
                    }
                    Text(statusBarHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Status-bar cleanup doesn't apply to \(vm.deviceKind.label) recordings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Wordmark") {
                Toggle("Show wordmark", isOn: binding(\.showWordmark))
                if vm.theme.showWordmark {
                    TextField("Name", text: binding(\.wordmarkText))
                    imageRow(
                        label: "Logo",
                        path: \.logoImagePath,
                        hint: "Optional — replaces the coral voice-bars icon."
                    )
                }
            }

            Section {
                Button("Reset to default design") {
                    vm.theme = BrandTheme()
                }
                .disabled(vm.theme.isDefault)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Changes apply to the App Store slides and the framed 16:9 video, previews and exports alike, and are saved with the project.")
                    Text("Want full control? The frames are plain HTML + CSS — use **Edit HTML Templates…** to get the files plus a guide for redesigning them with Claude Code.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Button {
                    vm.editTemplatesInFinder()
                } label: {
                    Label("Edit HTML Templates…", systemImage: "chevron.left.forwardslash.chevron.right")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 560)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private var statusBarHint: String {
        switch vm.theme.statusBarMode {
        case "clean":
            return "Replaces the recording's status bar with Apple's pristine marketing bar (9:41, full signal and battery) — the layout stays untouched, and the red screen-recording indicator never ships."
        case "crop":
            return "Cuts the top ≈7% off entirely. Note: this changes the visible aspect, so the sides get slightly cropped too."
        default:
            return "Ships frames exactly as recorded — including the clock, battery level, and any recording indicator."
        }
    }

    // MARK: Row builders

    private func colorRow(_ label: String, _ keyPath: WritableKeyPath<BrandTheme, String>) -> some View {
        ColorPicker(
            label,
            selection: Binding(
                get: { Color(hexString: vm.theme[keyPath: keyPath]) },
                set: { vm.theme[keyPath: keyPath] = $0.hexString }
            ),
            supportsOpacity: false
        )
    }

    @ViewBuilder
    private func imageRow(label: String, path: WritableKeyPath<BrandTheme, String>, hint: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            if vm.theme[keyPath: path].isEmpty {
                Button("Choose…") { chooseImage(for: path) }
            } else {
                Text(URL(fileURLWithPath: vm.theme[keyPath: path]).lastPathComponent)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    vm.theme[keyPath: path] = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .help("Remove")
            }
        }
        Text(hint)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<BrandTheme, T>) -> Binding<T> {
        Binding(
            get: { vm.theme[keyPath: keyPath] },
            set: { vm.theme[keyPath: keyPath] = $0 }
        )
    }

    private func chooseImage(for keyPath: WritableKeyPath<BrandTheme, String>) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .webP]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            vm.theme[keyPath: keyPath] = url.path
        }
    }
}
