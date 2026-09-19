// BuildLog.swift — "Onboard to a Codebase", milestone M2 (package format).
//
// The package's two machine-written logs (ARCHITECTURE.md 4.7 and D13):
// build-log.md (append-only, human readable: session boundaries, unit start
// and finish lines, notices, cap hits, resume points) and build-log.jsonl
// (one record per API request with token usage and cost). Both are appended
// to across sessions, never rewritten. Nothing that looks like a key or an
// auth header is written: every line passes through `redact`.

import Foundation

/// One line of build-log.jsonl: one API request.
struct BuildLogRecord: Codable, Equatable {
    var ts: Date
    var unitId: String
    var model: String
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheWriteTokens: Int
    var usd: Double
    var stopReason: String?
    /// Wall time of the request in milliseconds.
    var ms: Int
    var streaming: Bool

    init(
        ts: Date = OnboardingJSON.now(),
        unitId: String,
        model: String,
        inputTokens: Int = 0,
        outputTokens: Int = 0,
        cacheReadTokens: Int = 0,
        cacheWriteTokens: Int = 0,
        usd: Double = 0,
        stopReason: String? = nil,
        ms: Int = 0,
        streaming: Bool = false
    ) {
        self.ts = ts
        self.unitId = unitId
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.usd = usd
        self.stopReason = stopReason
        self.ms = ms
        self.streaming = streaming
    }

    private enum CodingKeys: String, CodingKey {
        case ts, unitId, model, inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens
        case usd, stopReason, ms, streaming
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ts = try c.decodeIfPresent(Date.self, forKey: .ts) ?? Date(timeIntervalSince1970: 0)
        unitId = try c.decodeIfPresent(String.self, forKey: .unitId) ?? ""
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        cacheReadTokens = try c.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0
        cacheWriteTokens = try c.decodeIfPresent(Int.self, forKey: .cacheWriteTokens) ?? 0
        usd = try c.decodeIfPresent(Double.self, forKey: .usd) ?? 0
        stopReason = try c.decodeIfPresent(String.self, forKey: .stopReason)
        ms = try c.decodeIfPresent(Int.self, forKey: .ms) ?? 0
        streaming = try c.decodeIfPresent(Bool.self, forKey: .streaming) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ts, forKey: .ts)
        try c.encode(unitId, forKey: .unitId)
        try c.encode(model, forKey: .model)
        try c.encode(inputTokens, forKey: .inputTokens)
        try c.encode(outputTokens, forKey: .outputTokens)
        try c.encode(cacheReadTokens, forKey: .cacheReadTokens)
        try c.encode(cacheWriteTokens, forKey: .cacheWriteTokens)
        try c.encode(usd, forKey: .usd)
        try c.encodeIfPresent(stopReason, forKey: .stopReason)
        try c.encode(ms, forKey: .ms)
        try c.encode(streaming, forKey: .streaming)
    }

    /// The same numbers as an OnboardingUsage, for manifest.spent.
    var usage: OnboardingUsage {
        OnboardingUsage(
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheReadTokens: cacheReadTokens,
            cacheWriteTokens: cacheWriteTokens,
            usd: usd
        )
    }
}

struct BuildLog {
    static let markdownFileName = "build-log.md"
    static let recordsFileName = "build-log.jsonl"

    let store: PackageStore

    init(store: PackageStore) {
        self.store = store
    }

    /// Writes the `## Session <uuid> <ISO date>` boundary that resume reads.
    func beginSession(id: UUID, at date: Date = Date()) {
        let stamp = OnboardingJSON.iso8601String(from: date)
        let header = "\n## Session \(id.uuidString) \(stamp)\n"
        append(header, to: BuildLog.markdownFileName)
    }

    /// Appends one human-readable line (a timestamp is added; keys are redacted).
    func appendMarkdown(_ line: String) {
        let stamp = OnboardingJSON.iso8601String(from: Date())
        let clean = BuildLog.redact(line).trimmingCharacters(in: .newlines)
        append("- \(stamp) \(clean)\n", to: BuildLog.markdownFileName)
    }

    /// Appends one JSON line for an API request.
    func appendRecord(_ record: BuildLogRecord) {
        var safe = record
        safe.unitId = BuildLog.redact(record.unitId)
        safe.model = BuildLog.redact(record.model)
        safe.stopReason = record.stopReason.map { BuildLog.redact($0) }
        do {
            let data = try OnboardingJSON.lineEncoder().encode(safe)
            guard var line = String(data: data, encoding: .utf8) else { return }
            line = line.replacingOccurrences(of: "\n", with: " ")
            append(line + "\n", to: BuildLog.recordsFileName)
        } catch {
            BuildLog.warn("could not encode a build-log record: \(error.localizedDescription)")
        }
    }

    /// Every record currently in build-log.jsonl (malformed lines are skipped).
    func records() -> [BuildLogRecord] {
        guard let text = try? store.readString(BuildLog.recordsFileName) else { return [] }
        let decoder = OnboardingJSON.decoder()
        var out: [BuildLogRecord] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if let record = try? decoder.decode(BuildLogRecord.self, from: Data(line.utf8)) {
                out.append(record)
            }
        }
        return out
    }

    // MARK: Redaction

    private static let secretPatterns: [NSRegularExpression] = {
        let sources = [
            // Prefixed API keys and tokens: sk-..., sk-ant-..., xi-..., ghp_..., github_pat_...
            "(?i)\\b(sk|xi|ghp|gho|ghu|ghs|github_pat)[-_][A-Za-z0-9_-]{6,}",
            // Header-shaped leaks: x-api-key: ..., Authorization: Bearer ...
            "(?i)\\b(x-api-key|xi-api-key|authorization|api[_-]?key|secret)(\\s*[:=]\\s*)\\S+",
            "(?i)\\bbearer\\s+[A-Za-z0-9._-]{8,}",
        ]
        return sources.compactMap { try? NSRegularExpression(pattern: $0, options: []) }
    }()

    /// Replaces anything that looks like a key or auth header value with [redacted].
    static func redact(_ text: String) -> String {
        var out = text
        for (index, regex) in secretPatterns.enumerated() {
            let range = NSRange(out.startIndex..<out.endIndex, in: out)
            let template = index == 1 ? "$1$2[redacted]" : "[redacted]"
            out = regex.stringByReplacingMatches(in: out, options: [], range: range, withTemplate: template)
        }
        return out
    }

    // MARK: Append

    private func append(_ text: String, to fileName: String) {
        let target = store.url(fileName)
        let data = Data(text.utf8)
        do {
            if !FileManager.default.fileExists(atPath: target.path) {
                try data.write(to: target)
                return
            }
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            BuildLog.warn("could not append to \(fileName): \(error.localizedDescription)")
        }
    }

    private static func warn(_ message: String) {
        let line = "buildlog: \(message)\n"
        try? FileHandle.standardError.write(contentsOf: Data(line.utf8))
    }
}
