import SwiftUI

/// "Capture a Website": base URL + a description of the video you want, and
/// the agent does the rest — browses, records, writes, narrates. The briefing
/// (optional, shared with the rest of the project) guides tone and focus.
struct WebCaptureSheet: View {
    @ObservedObject var vm: StudioViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var urlText = ""
    @State private var goalText = ""
    @State private var viewport: CaptureViewport = .desktop
    // Loaded lazily in .task — a Keychain read in the initializer could block
    // the whole app behind an access prompt (see SettingsView).
    @State private var hasAnthropicKey: Bool?

    private static let goalPlaceholder = "e.g. A step-by-step tutorial of the onboarding flow: signing up, setting up a profile, and creating the first project."

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Text("Capture a Website")
                    .font(.custom("Georgia", size: 30))
                    .foregroundStyle(Brand.charcoal)
                Text("Give Claude a URL and describe the video you want. It browses the site, records every step with a live cursor, then writes and narrates the walkthrough.")
                    .font(.callout)
                    .foregroundStyle(Brand.muted)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 4)

            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Website address")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Brand.charcoal)
                    TextField("https://your-product.com", text: $urlText)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("What should the video show?")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Brand.charcoal)
                    TextEditor(text: $goalText)
                        .font(.body)
                        .foregroundColor(Brand.charcoal)
                        .frame(minHeight: 76)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(.white, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Brand.faded.opacity(0.4)))
                        .overlay(alignment: .topLeading) {
                            if goalText.isEmpty {
                                Text(Self.goalPlaceholder)
                                    .foregroundStyle(.tertiary)
                                    .padding(.top, 9)
                                    .padding(.leading, 9)
                                    .allowsHitTesting(false)
                            }
                        }
                    Text("Include anything the agent needs: which flow to walk through, test credentials for a demo account, what to skip.")
                        .font(.caption)
                        .foregroundStyle(Brand.muted)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Record as")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Brand.charcoal)
                    Picker("", selection: $viewport) {
                        ForEach(CaptureViewport.allCases) { preset in
                            Text(preset.label).tag(preset)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 340)
                    Text(viewport == .iphone
                         ? "Mobile viewport with a pristine iPhone status bar baked in — App Store exports included."
                         : "Full desktop browser — best for web-app tours (framed 16:9 video + tutorial exports).")
                        .font(.caption)
                        .foregroundStyle(Brand.faded)
                }

                HStack(spacing: 8) {
                    Image(systemName: vm.briefingURL == nil ? "doc.text" : "doc.text.fill")
                        .foregroundStyle(vm.briefingURL == nil ? Brand.faded : Brand.coral)
                    if let briefing = vm.briefingURL {
                        Text("Briefing: \(briefing.lastPathComponent) — guides the narration and copy.")
                            .font(.caption)
                            .foregroundStyle(Brand.muted)
                        Button("Remove") { vm.removeBriefing() }
                            .controlSize(.small)
                    } else {
                        Text("Optional: attach a briefing to guide tone and focus.")
                            .font(.caption)
                            .foregroundStyle(Brand.muted)
                        Button("Attach…") { vm.attachBriefing() }
                            .controlSize(.small)
                    }
                }

                if hasAnthropicKey == false {
                    Label("Web capture needs an Anthropic API key — the agent explores the site by looking at it with Claude. Add one in Settings (⌘,) first.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.faded.opacity(0.35)))

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Start Capture") { start() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.coral)
                    .disabled(!canStart)
                    .help(canStart
                          ? "Open the site and record the walkthrough"
                          : "Enter a website address and a description first (and add an Anthropic key in Settings)")
            }
        }
        .padding(28)
        .frame(width: 600)
        .background(Brand.cream)
        .environment(\.colorScheme, .light)
        .task {
            hasAnthropicKey = await Task.detached {
                !Keychain.anthropicKey.isEmpty
            }.value
        }
    }

    private var canStart: Bool {
        Self.normalizedURL(from: urlText) != nil
            && !goalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasAnthropicKey == true
            && !vm.isBusy
    }

    private func start() {
        guard let url = Self.normalizedURL(from: urlText) else { return }
        let goal = goalText.trimmingCharacters(in: .whitespacesAndNewlines)
        dismiss()
        vm.captureFromWeb(config: .init(url: url, goal: goal, viewport: viewport))
    }

    /// Forgiving URL entry: "example.com/tour" works, https is assumed, and
    /// obvious non-URLs return nil so the Start button stays off.
    static func normalizedURL(from text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, host.contains(".") || host == "localhost"
        else { return nil }
        return url
    }
}
