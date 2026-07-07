import SwiftUI

/// First-run setup: collect the API keys (and, optionally, a custom
/// Anthropic-compatible endpoint such as a Bedrock gateway) before the first
/// project. Everything here is also editable later in Settings (⌘,); the
/// pipeline degrades gracefully when a key is missing, so skipping is fine.
struct SetupSheet: View {
    @ObservedObject var vm: StudioViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var anthropicKey = ""
    @State private var elevenKey = ""
    @State private var showAdvanced = false
    @State private var keychainWarning = ""

    @AppStorage(SettingsKeys.anthropicBaseURL) private var anthropicBaseURL = ""
    @AppStorage(SettingsKeys.anthropicModelOverride) private var modelOverride = ""

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 8) {
                Text("Set Up Walkthrough Studio")
                    .font(.custom("Georgia", size: 30))
                    .foregroundStyle(Brand.charcoal)
                Text("Two keys power the automatic pipeline. Both are stored in the macOS Keychain — never on disk — and you can add or change them any time in Settings.")
                    .font(.callout)
                    .foregroundStyle(Brand.muted)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 4)

            VStack(alignment: .leading, spacing: 16) {
                keyField(
                    title: "Anthropic API key",
                    caption: "Claude drafts the step copy, slide headlines, and narration scripts.",
                    text: $anthropicKey
                )
                keyField(
                    title: "ElevenLabs API key",
                    caption: "Synthesizes the professional voice-over. Skip it to export without narration.",
                    text: $elevenKey
                )

                DisclosureGroup(isExpanded: $showAdvanced) {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("https://api.anthropic.com", text: $anthropicBaseURL)
                            .textFieldStyle(.roundedBorder)
                        Text("Leave blank for the standard Anthropic API. To route Claude requests through an Anthropic-compatible gateway (e.g. an AWS Bedrock proxy), paste its base URL — the app calls `<base>/v1/messages` with the same request shape.")
                            .font(.caption)
                            .foregroundStyle(Brand.muted)
                            .fixedSize(horizontal: false, vertical: true)
                        TextField("Model ID override (blank = use the Settings picker)", text: $modelOverride)
                            .textFieldStyle(.roundedBorder)
                        Text("Gateways often need their own model IDs — on Bedrock, Claude models take an `anthropic.` prefix (e.g. `anthropic.claude-sonnet-5`).")
                            .font(.caption)
                            .foregroundStyle(Brand.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Custom endpoint (Bedrock gateway)")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Brand.charcoal)
                }

                if !keychainWarning.isEmpty {
                    Label(keychainWarning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Brand.faded.opacity(0.35)))

            HStack {
                Button("Skip for Now") { finish(savingKeys: false) }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Get Started") { finish(savingKeys: true) }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .tint(Brand.coral)
            }
        }
        .padding(28)
        .frame(width: 560)
        .background(Brand.cream)
        .environment(\.colorScheme, .light)
    }

    private func keyField(title: String, caption: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.callout.weight(.medium))
                .foregroundStyle(Brand.charcoal)
            SecureField("Paste your key…", text: text)
                .textFieldStyle(.roundedBorder)
            Text(caption)
                .font(.caption)
                .foregroundStyle(Brand.muted)
        }
    }

    private func finish(savingKeys: Bool) {
        if savingKeys {
            var failed = false
            let anthropic = anthropicKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let eleven = elevenKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !anthropic.isEmpty { failed = !Keychain.set(anthropic, account: Keychain.anthropicAccount) || failed }
            if !eleven.isEmpty { failed = !Keychain.set(eleven, account: Keychain.elevenLabsAccount) || failed }
            if failed {
                keychainWarning = "The Keychain rejected the write — the key was NOT saved. Unlock the keychain and try again."
                return // stay on the sheet so the user can retry
            }
        }
        UserDefaults.standard.set(true, forKey: SettingsKeys.didCompleteSetup)
        dismiss()
    }
}
