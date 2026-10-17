// AgentSettings.swift — "Onboard to a Codebase", milestone M7 (playback chat).
//
// The request-shaping rules of ARCHITECTURE 4.2 that depend on where the app is
// pointed, read from Settings in one place: which model, which endpoint, whether
// the server-side-fallback beta may ride along, and the spend cap. The playback
// chat is the first caller; the fleet (M11) is the second, and both must make the
// same gateway decision or one of them will send a beta a Bedrock proxy rejects.
//
// A value type, built once per conversation or run, so a probe can construct one
// by hand and never touch UserDefaults or the Keychain.

import Foundation

struct AgentRuntimeSettings: Equatable, Sendable {
    enum Role: Sendable { case planner, worker }

    var model: String
    var endpoint: URL
    /// True when requests go anywhere but api.anthropic.com, or the user turned
    /// gateway-compat on. Behind a gateway: no betas, no output schema.
    var behindGateway: Bool
    var spendCapUSD: Double?

    /// The models that take `fallbacks: "default"` (ARCHITECTURE 4.2, D11).
    static let fallbackModels: Set<String> = ["claude-opus-5", "claude-fable-5-1"]
    static let fallbackBeta = "server-side-fallback-2026-07-01"

    var betas: [String] {
        guard !behindGateway, AgentRuntimeSettings.fallbackModels.contains(model) else { return [] }
        return [AgentRuntimeSettings.fallbackBeta]
    }

    var serverSideFallback: Bool { !betas.isEmpty }

    /// Reads Settings. Returns nil when the endpoint the user typed is not a URL,
    /// which the caller reports rather than silently sending to the default host.
    static func current(role: Role) -> AgentRuntimeSettings? {
        let baseURL = Defaults.string(SettingsKeys.anthropicBaseURL, "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let endpoint = AgentEndpoint.messages(baseURL: baseURL) else { return nil }
        let override = Defaults.string(SettingsKeys.anthropicModelOverride, "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let model: String
        if !override.isEmpty {
            // Gateway ids are opaque; nothing is derived from the string.
            model = override
        } else {
            switch role {
            case .planner:
                model = Defaults.string(SettingsKeys.onboardingPlannerModel, Defaults.onboardingPlannerModel)
            case .worker:
                model = Defaults.string(SettingsKeys.onboardingWorkerModel, Defaults.onboardingWorkerModel)
            }
        }
        let cap = Defaults.double(SettingsKeys.onboardingSpendCapUSD, 0)
        return AgentRuntimeSettings(
            model: model,
            endpoint: endpoint,
            behindGateway: !baseURL.isEmpty || Defaults.bool(SettingsKeys.onboardingGatewayCompat),
            spendCapUSD: cap > 0 ? cap : nil)
    }
}
