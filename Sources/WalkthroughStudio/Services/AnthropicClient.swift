import Foundation

/// Thin client for the Anthropic Messages API.
struct AnthropicClient {
    var apiKey: String
    var model: String

    init(apiKey: String, model: String = Defaults.string(SettingsKeys.anthropicModel, Defaults.anthropicModel)) {
        self.apiKey = apiKey
        self.model = model
    }

    func complete(system: String, user: String, maxTokens: Int = 16000) async throws -> String {
        guard !apiKey.isEmpty else {
            throw StudioError("No Anthropic API key. Add one in Settings (it's stored in the Keychain).")
        }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 120
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "system": system,
            "messages": [["role": "user", "content": user]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw StudioError("No response from Anthropic.") }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]

        guard http.statusCode == 200 else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(http.statusCode)"
            throw StudioError("Anthropic API error: \(message)")
        }
        guard let content = json?["content"] as? [[String: Any]] else {
            throw StudioError("Unexpected Anthropic response shape.")
        }
        if let stopReason = json?["stop_reason"] as? String, stopReason == "max_tokens" {
            throw StudioError("Claude's reply was cut off at the token limit before finishing. Try again, or split the work (fewer steps / shorter transcripts).")
        }
        return content.compactMap { $0["text"] as? String }.joined()
    }

    /// Ask for a JSON array, with one corrective retry if the reply can't be parsed.
    func completeJSONArray(system: String, user: String, maxTokens: Int = 16000) async throws -> [[String: Any]] {
        let first = try await complete(system: system, user: user, maxTokens: maxTokens)
        do {
            return try Self.extractJSONArray(from: first)
        } catch {
            let retryUser = user + "\n\nIMPORTANT: Your previous reply could not be parsed. Reply with ONLY the raw JSON array — no prose, no code fences, no explanations."
            let second = try await complete(system: system, user: retryUser, maxTokens: maxTokens)
            return try Self.extractJSONArray(from: second)
        }
    }

    /// Extract a JSON array from an LLM reply that may be wrapped in prose or
    /// code fences. Scans for balanced top-level brackets (string- and
    /// escape-aware) so a stray "]" inside prose or a string doesn't break it.
    static func extractJSONArray(from text: String) throws -> [[String: Any]] {
        var candidates: [String] = []
        let chars = Array(text)
        var depth = 0
        var inString = false
        var escaped = false
        var start: Int?

        for (index, char) in chars.enumerated() {
            if inString {
                if escaped {
                    escaped = false
                } else if char == "\\" {
                    escaped = true
                } else if char == "\"" {
                    inString = false
                }
                continue
            }
            switch char {
            case "\"":
                inString = true
            case "[":
                if depth == 0 { start = index }
                depth += 1
            case "]":
                if depth > 0 {
                    depth -= 1
                    if depth == 0, let s = start {
                        candidates.append(String(chars[s...index]))
                        start = nil
                    }
                }
            default:
                break
            }
        }

        // Prefer the largest parseable candidate.
        for candidate in candidates.sorted(by: { $0.count > $1.count }) {
            if let data = candidate.data(using: .utf8),
               let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
                return array
            }
        }
        let snippet = String(text.prefix(200)).replacingOccurrences(of: "\n", with: " ")
        throw StudioError("The model reply did not contain a parseable JSON array. Reply began: \"\(snippet)…\"")
    }
}

/// The LLM prompts: script cleanup (Output A) and step copy / headlines (Outputs B & C).
enum CopyService {

    private static let voiceSystem = """
    You write product copy for recorded software walkthroughs. Unless the project briefing says \
    otherwise, the voice is warm, plain, encouraging, second person, no jargon, never patronizing. \
    Infer the product's name and purpose from the briefing and the transcript — never invent \
    features the recording doesn't show.
    """

    /// System prompt, optionally extended with the attached project briefing.
    /// The briefing is authoritative: it wins over the generic defaults above.
    private static func system(briefing: String) -> String {
        guard !briefing.isEmpty else { return voiceSystem }
        return voiceSystem + """


        PROJECT BRIEFING — the user attached this document to guide everything you write. \
        Follow its instructions, terminology, product names, phrasing, and messaging priorities. \
        Where it conflicts with the general guidance above, the briefing wins.

        <briefing>
        \(briefing)
        </briefing>
        """
    }

    /// Per-step narration cleanup: raw transcript → polished voice-over script.
    static func polishScripts(client: AnthropicClient, steps: [WalkthroughStep], briefing: String = "") async throws -> [UUID: String] {
        let payload = steps.enumerated().map { index, step -> [String: Any] in
            [
                "id": step.id.uuidString,
                "position": position(index, of: steps.count),
                "durationSeconds": Int(step.duration.rounded()),
                "rawTranscript": step.transcript.isEmpty ? step.script : step.transcript,
            ]
        }
        let user = """
        Below are the steps of a recorded product walkthrough, in order, each with its raw spoken \
        transcript (or a draft script) and how many seconds of video that step covers.

        Together they form ONE complete walkthrough video with a beginning, a middle, and an end:
        - The "intro" step is the video's opening. Its narration must welcome the viewer and set up \
          what they're about to see (e.g. "Today I'll walk you through…"). If the transcript contains \
          the presenter's own introduction, KEEP its intent and polish it — never cut it as filler. \
          If there is no spoken intro, write a short welcoming one.
        - "middle" steps narrate what's happening on screen at that moment.
        - The "outro" step closes the video: a brief, encouraging send-off (and keep any thanks or \
          recap the presenter spoke). If there is no spoken outro, write a short closing line.

        Rewrite each step into a polished narration script for a professional voice-over:
        - Remove filler ("um", false starts, repeated words, tangents).
        - Keep the meaning; tighten to the product voice — warm, plain, encouraging (the briefing wins).
        - Aim for roughly 2.5 words per second of the step's duration so the narration fits, \
          and never more than that.
        - If a "middle" step has an empty transcript, reply with an empty script for it — do not \
          invent narration for a screen you can't see. The intro and outro should always get a script.
        - Plain text only: no stage directions, no markdown, no quotes around the text.

        Reply with ONLY a JSON array: [{"id": "<same id>", "script": "<polished narration>"}]

        Steps:
        \(jsonString(payload))
        """
        let array = try await client.completeJSONArray(system: system(briefing: briefing), user: user)
        var out: [UUID: String] = [:]
        for item in array {
            if let idString = item["id"] as? String, let id = UUID(uuidString: idString),
               let script = item["script"] as? String {
                out[id] = script.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return out
    }

    struct StepCopy {
        var slug: String
        var area: String
        var title: String
        var body: String
        var alt: String
        var headline: String
        var subheadline: String
    }

    /// Per-step onboarding copy (tutorialSteps contract) + App Store headline/subhead.
    static func generateStepCopy(client: AnthropicClient, steps: [WalkthroughStep], briefing: String = "") async throws -> [UUID: StepCopy] {
        let payload = steps.enumerated().map { index, step -> [String: Any] in
            [
                "id": step.id.uuidString,
                "position": position(index, of: steps.count),
                "transcript": step.transcript,
                "existingTitle": step.title,
                "existingArea": step.area,
            ]
        }
        let user = """
        Below are the steps of a recorded walkthrough of an app, in order, each with \
        the transcript of what was said while that screen was shown.

        Together they form ONE complete walkthrough video with a beginning, a middle, and an end. \
        Write the copy to match each step's position:
        - The "intro" step welcomes the viewer: its title/headline should introduce the product and \
          the tour (e.g. "Welcome to <the product's name>"), not describe a feature.
        - "middle" steps describe the screen being shown.
        - The "outro" step closes the tour: a warm send-off ("You're all set") rather than a \
          feature description.

        For each step produce:
        - "slug": a short stable kebab-case slug (e.g. "me", "voice", "talk") — one or two words.
        - "area": the tab/area label, e.g. "Content → Me" (infer from the transcript; keep it short).
        - "title": a short, warm title (2–5 words), e.g. "Make it yours".
        - "body": 1–2 sentences in the product voice explaining what to do on this screen.
        - "alt": a plain accessibility description of what the screenshot shows.
        - "headline": an App Store slide headline — short and emotional, 3–8 words. You may use \
          "<br>" for line breaks and wrap ONE emphasized word or phrase in \
          "<span class=\\"accent\\">…</span>".
        - "sub": one supporting sentence for the slide (max ~90 characters).

        Reply with ONLY a JSON array of objects:
        [{"id": "<same id>", "slug": "...", "area": "...", "title": "...", "body": "...", "alt": "...", "headline": "...", "sub": "..."}]

        Steps:
        \(jsonString(payload))
        """
        let array = try await client.completeJSONArray(system: system(briefing: briefing), user: user)
        var out: [UUID: StepCopy] = [:]
        for item in array {
            guard let idString = item["id"] as? String, let id = UUID(uuidString: idString) else { continue }
            out[id] = StepCopy(
                slug: item["slug"] as? String ?? "",
                area: item["area"] as? String ?? "",
                title: item["title"] as? String ?? "",
                body: item["body"] as? String ?? "",
                alt: item["alt"] as? String ?? "",
                headline: item["headline"] as? String ?? "",
                subheadline: item["sub"] as? String ?? ""
            )
        }
        return out
    }

    private static func position(_ index: Int, of count: Int) -> String {
        if index == 0 { return "intro" }
        if index == count - 1 { return "outro" }
        return "middle"
    }

    private static func jsonString(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]),
              let string = String(data: data, encoding: .utf8) else { return "[]" }
        return string
    }
}
