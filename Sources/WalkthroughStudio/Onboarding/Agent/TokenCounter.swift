// TokenCounter.swift — "Onboard to a Codebase", milestone M6 (LLM runtime).
//
// Two things need a token count and neither can afford to be wrong in the same
// direction:
//
//  * The context cap (ARCHITECTURE 4.6 point 5). At 80% of a unit's cap the unit is
//    told to finish and a continuation unit is spawned. Under-counting here means
//    the API rejects a turn the unit thought it had room for and the unit dies with
//    its findings unwritten; the estimator is therefore deliberately pessimistic.
//  * The cacheable-prefix check (ARCHITECTURE 4.2). A prefix shorter than the
//    model's minimum is never cached, so every request pays full price for the
//    dossier. That check wants a real number when one is available.
//
// Hence two implementations behind one protocol: `count_tokens` when the endpoint
// has it, and four-characters-per-token when it does not (a gateway, an offline
// selftest). The estimator is never silently substituted — the caller asks for one
// or the other.

import Foundation

protocol TokenCounting: Sendable {
    /// Input tokens the request would be billed for, or nil if it cannot be known.
    func count(_ request: MessagesRequest) async -> Int?
}

/// Four characters per token over the canonical request body.
///
/// Crude on purpose and biased high: the body includes JSON punctuation the
/// tokenizer compresses well, so this over-counts English prose by roughly a
/// quarter, which is the safe direction for a cap.
struct EstimatingTokenCounter: TokenCounting {
    var charactersPerToken: Double = 4

    init(charactersPerToken: Double = 4) {
        self.charactersPerToken = charactersPerToken
    }

    func count(_ request: MessagesRequest) async -> Int? {
        EstimatingTokenCounter.estimate(request, charactersPerToken: charactersPerToken)
    }

    static func estimate(_ request: MessagesRequest, charactersPerToken: Double = 4) -> Int {
        guard let body = try? request.body() else { return 0 }
        return estimate(bytes: body.count, charactersPerToken: charactersPerToken)
    }

    static func estimate(bytes: Int, charactersPerToken: Double = 4) -> Int {
        guard charactersPerToken > 0 else { return bytes }
        return Int((Double(bytes) / charactersPerToken).rounded(.up))
    }

    static func estimate(text: String, charactersPerToken: Double = 4) -> Int {
        estimate(bytes: text.utf8.count, charactersPerToken: charactersPerToken)
    }
}

/// `POST /v1/messages/count_tokens`.
struct RemoteTokenCounter: TokenCounting {
    var transport: MessagesTransport
    var apiKey: String
    var endpoint: URL
    /// What to fall back to when the endpoint does not implement the route — most
    /// gateways do not, and a 404 there must not fail a run.
    var fallback = EstimatingTokenCounter()

    init(transport: MessagesTransport, apiKey: String, endpoint: URL) {
        self.transport = transport
        self.apiKey = apiKey
        self.endpoint = endpoint
    }

    func count(_ request: MessagesRequest) async -> Int? {
        // count_tokens takes the same body minus the sampling fields.
        var counting = request
        counting.stream = false
        counting.maxTokens = 1
        guard let body = try? MessagesRequest.canonicalJSON(RemoteTokenCounter.strip(counting.wire)) else {
            return await fallback.count(request)
        }
        let call = TransportRequest(
            endpoint: endpoint,
            headers: AgentHeaders.standard(apiKey: apiKey, betas: []),
            body: body,
            stream: false,
            timeout: 60,
            promptName: "count_tokens:\(request.promptName)",
            turn: request.messages.count,
            bodyHash: PackageStore.sha256Hex(body))
        do {
            let reply = try await transport.send(call)
            guard reply.status == 200,
                  let value = try? JSONDecoder().decode(JSONValue.self, from: reply.body),
                  let tokens = value.objectValue?["input_tokens"]?.numberValue else {
                return await fallback.count(request)
            }
            return Int(tokens)
        } catch {
            return await fallback.count(request)
        }
    }

    /// Removes the fields count_tokens rejects.
    static func strip(_ wire: JSONValue) -> JSONValue {
        guard var object = wire.objectValue else { return wire }
        for key in ["max_tokens", "stream", "output_config", "fallbacks"] {
            object.removeValue(forKey: key)
        }
        return .object(object)
    }
}

/// The endpoints, derived from the one base URL the user configures.
enum AgentEndpoint {
    static func messages(baseURL: String) -> URL? {
        AnthropicClient.messagesEndpoint(baseURL: baseURL)
    }

    static func countTokens(baseURL: String) -> URL? {
        messages(baseURL: baseURL)?.appendingPathComponent("count_tokens")
    }
}

/// The request headers, in one place so there is one place that handles the key.
enum AgentHeaders {
    static func standard(apiKey: String, betas: [String]) -> [String: String] {
        var headers = [
            "x-api-key": apiKey,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        ]
        if !betas.isEmpty {
            headers["anthropic-beta"] = betas.joined(separator: ",")
        }
        return headers
    }

    /// Header *names* for the transcript. The values are never recorded anywhere:
    /// one of them is the key, and a transcript is a file in a package a user may
    /// well zip up and send to someone.
    static func redactedNames(_ headers: [String: String]) -> [String] {
        headers.keys.sorted()
    }
}
