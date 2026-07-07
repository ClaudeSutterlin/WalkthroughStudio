import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss

    // Loaded lazily in .task — NOT in the initializer. SwiftUI builds the
    // Settings scene at app launch, and a synchronous Keychain read here would
    // block the whole app for minutes if an access prompt can't be answered.
    @State private var anthropicKey = ""
    @State private var elevenKey = ""
    @State private var keysLoaded = false

    @AppStorage(SettingsKeys.anthropicModel) private var anthropicModel = Defaults.anthropicModel
    @AppStorage(SettingsKeys.anthropicBaseURL) private var anthropicBaseURL = ""
    @AppStorage(SettingsKeys.anthropicModelOverride) private var anthropicModelOverride = ""
    @AppStorage(SettingsKeys.elevenVoiceID) private var voiceID = Defaults.elevenVoiceID
    @AppStorage(SettingsKeys.elevenModelID) private var elevenModelID = ""
    @AppStorage(SettingsKeys.transcribeLocale) private var locale = Defaults.transcribeLocale

    @State private var voices: [ElevenLabsClient.Voice] = []
    @State private var voicesMessage = ""
    @State private var keychainWarning = ""

    var body: some View {
        Form {
            Section("Anthropic (script cleanup + step copy)") {
                SecureField("API key", text: $anthropicKey)
                    .onChange(of: anthropicKey) { _, newValue in
                        guard keysLoaded else { return }
                        save(newValue, account: Keychain.anthropicAccount)
                    }
                Picker("Model", selection: $anthropicModel) {
                    ForEach(Defaults.anthropicModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }
                Text("Keys are stored in the macOS Keychain, never on disk.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !keychainWarning.isEmpty {
                    Label(keychainWarning, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                TextField("Custom API endpoint (blank = api.anthropic.com)", text: $anthropicBaseURL)
                Text("Route Claude requests through an Anthropic-compatible gateway (e.g. an AWS Bedrock proxy). The app calls `<base>/v1/messages` with the standard Messages API shape and your key as `x-api-key`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Model ID override (blank = use the picker above)", text: $anthropicModelOverride)
                Text("Gateways often need their own model IDs — on Bedrock, Claude models take an `anthropic.` prefix (e.g. `anthropic.claude-sonnet-5`).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("ElevenLabs (voice-over)") {
                SecureField("API key", text: $elevenKey)
                    .onChange(of: elevenKey) { _, newValue in
                        guard keysLoaded else { return }
                        save(newValue, account: Keychain.elevenLabsAccount)
                    }
                HStack {
                    TextField("Voice ID", text: $voiceID)
                    Button("Fetch Voices") { fetchVoices() }
                        .disabled(elevenKey.isEmpty)
                }
                if !voices.isEmpty {
                    Picker("Voice", selection: $voiceID) {
                        ForEach(voices) { voice in
                            Text("\(voice.name) (\(voice.category))").tag(voice.id)
                        }
                    }
                }
                if !voicesMessage.isEmpty {
                    Text(voicesMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                TextField("Model ID override (blank = auto-select recommended)", text: $elevenModelID)
                Text("Default voice is “Rachel”, a neutral, warm stock narrator from the Voice Library. The TTS model is discovered from ElevenLabs' models API at run time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Transcription") {
                TextField("Locale", text: $locale)
                Text("On-device Apple Speech recognition. en-US by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 480)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .padding(.bottom, 8)
        .task {
            // Read the Keychain only when the pane is actually shown — off the
            // launch path — so an access prompt can never block app startup.
            guard !keysLoaded else { return }
            anthropicKey = Keychain.anthropicKey
            elevenKey = Keychain.elevenLabsKey
            keysLoaded = true
        }
    }

    private func save(_ value: String, account: String) {
        keychainWarning = Keychain.set(value, account: account)
            ? ""
            : "The Keychain rejected the write — this key is NOT saved. Unlock the keychain and re-paste it."
    }

    private func fetchVoices() {
        voicesMessage = "Fetching voices…"
        let client = ElevenLabsClient(apiKey: elevenKey)
        Task {
            do {
                let fetched = try await client.voices()
                await MainActor.run {
                    voices = fetched
                    voicesMessage = "\(fetched.count) voices available."
                }
            } catch {
                await MainActor.run {
                    voicesMessage = error.localizedDescription
                }
            }
        }
    }
}
