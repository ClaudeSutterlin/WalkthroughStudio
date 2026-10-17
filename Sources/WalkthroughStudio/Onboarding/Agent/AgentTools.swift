// AgentTools.swift — "Onboard to a Codebase", milestone M6 (LLM runtime).
//
// The tool seam. The loop in AgentRun.swift knows this protocol and nothing else
// about tools, so the research tools (`RepoTools`, M11), the chat tools
// (`PackageTools`, M7) and a probe's three-line stub are interchangeable.
//
// `run` cannot throw, and that is the point. A tool_use block without a matching
// tool_result is a protocol error — the next request is rejected — so a failure has
// to become a `tool_result` with `is_error: true` and be sent, never dropped. Making
// the signature non-throwing means a tool author cannot accidentally drop one; the
// error has to be turned into something the model can read and recover from.

import Foundation

/// What a tool hands back to the loop.
struct ToolOutcome: Sendable, Equatable {
    /// The text the model sees. For a failure, say what was wrong *and* what would
    /// work — "path outside the repository; paths are relative to the repo root"
    /// gets a corrected call, "error" gets the same call again.
    var content: String
    var isError: Bool = false
    /// Set by `finish`: the unit is over, whatever else this turn contained.
    var endsUnit: Bool = false
    /// Package-relative paths this call wrote, for the unit's `outputs`.
    var outputs: [String] = []

    init(_ content: String, isError: Bool = false, endsUnit: Bool = false, outputs: [String] = []) {
        self.content = content
        self.isError = isError
        self.endsUnit = endsUnit
        self.outputs = outputs
    }

    static func error(_ message: String) -> ToolOutcome {
        ToolOutcome(message, isError: true)
    }

    /// A result truncated to a line budget, with the marker the prompts teach the
    /// model to act on. An unmarked truncation is worse than a short answer: the
    /// model reasons confidently about a file whose second half it never saw.
    static func truncated(_ text: String, maxLines: Int) -> ToolOutcome {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > maxLines else { return ToolOutcome(text) }
        let kept = lines.prefix(maxLines).joined(separator: "\n")
        return ToolOutcome(kept + "\n… truncated at \(maxLines) lines of \(lines.count): "
                           + "request a narrower range.")
    }
}

protocol AgentTools: Sendable {
    /// Declared tools. The request sorts them by name; the order here is only what
    /// a prompt lists.
    var specs: [ToolSpec] { get }

    func run(name: String, input: [String: JSONValue], toolUseId: String) async -> ToolOutcome
}

/// The tool every research unit ends with (ARCHITECTURE 4.3). Declared here
/// because the loop needs to recognize it and because "what did you not read" is
/// the single most valuable field in the whole packet: a unit that reports its own
/// blind spots turns an unknown into a tracked gap.
enum FinishTool {
    static let name = "finish"

    static var spec: ToolSpec {
        ToolSpec(
            name: name,
            description: "End this unit. Call it exactly once, last. `summary` is what you "
                + "found, in prose. `coverage` is what you read and what you did not: be "
                + "honest, an unread directory that is listed is a tracked gap and an "
                + "unread directory that is hidden is a wrong answer later.",
            inputSchema: ToolSpec.schema([
                "summary": ToolSpec.property("string", "What you found, in prose."),
                "coverage": .object([
                    "type": .string("object"),
                    "description": .string("What this unit covered."),
                    "properties": .object([
                        "readPaths": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("Repository-relative paths you read."),
                        ]),
                        "unreadDirs": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("Directories in scope you did not read."),
                        ]),
                        "skipped": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("Checks you could not make, and why."),
                        ]),
                    ]),
                    "required": .array([.string("readPaths"), .string("unreadDirs"), .string("skipped")]),
                    "additionalProperties": .bool(false),
                ]),
            ], required: ["summary", "coverage"])
        )
    }

    /// The summary from a `finish` call, for the unit's result and for the
    /// continuation unit's seed when the context cap is reached.
    static func summary(from input: [String: JSONValue]) -> String {
        input["summary"]?.stringValue ?? ""
    }
}

/// Tools backed by a closure. What the probes use, and the shortest possible proof
/// that the loop makes no assumptions about where a tool's answer comes from.
struct ClosureTools: AgentTools {
    var specs: [ToolSpec]
    var handler: @Sendable (String, [String: JSONValue], String) async -> ToolOutcome

    init(specs: [ToolSpec],
         handler: @escaping @Sendable (String, [String: JSONValue], String) async -> ToolOutcome) {
        self.specs = specs
        self.handler = handler
    }

    func run(name: String, input: [String: JSONValue], toolUseId: String) async -> ToolOutcome {
        await handler(name, input, toolUseId)
    }
}
