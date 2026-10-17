// SpendMeter.swift — "Onboard to a Codebase", milestone M6 (LLM runtime).
//
// What a run costs (ARCHITECTURE 4.5). The cap is off by default — the human's
// decision of 2026-09-19 was that depth is not a cap and the coverage tracker, not
// a budget, is what you watch. When a cap *is* set it has to hold, which is why
// `SpendMeter` refuses to start a turn whose estimate would cross it rather than
// noticing afterwards: one streaming planner turn can cost more than the headroom
// it started with.
//
// The prices are an estimate and the code says so everywhere it can. Two rules keep
// an estimate from becoming a lie:
//
//  1. An unpriced model is priced as the *most expensive* row in the table, and its
//     name is collected. A missing price must never read as free — with a cap set,
//     a zero price would quietly disable the cap, which is the one thing a cap
//     exists to prevent.
//  2. Cache writes and cache reads are priced as multiples of the input rate, not
//     ignored. A dossier cached once and read forty times is most of a run's input
//     tokens; counting those at the full rate overstates a run by several times,
//     and counting them at zero understates the first turn.

import Foundation

/// Per-million-token prices for one model.
struct ModelPrice: Sendable, Equatable {
    var inputPerMTok: Double
    var outputPerMTok: Double
    /// Writing the cache costs more than the same tokens fresh.
    var cacheWriteMultiplier: Double = 1.25
    /// Reading it costs a fraction.
    var cacheReadMultiplier: Double = 0.1

    init(input: Double, output: Double, cacheWriteMultiplier: Double = 1.25, cacheReadMultiplier: Double = 0.1) {
        self.inputPerMTok = input
        self.outputPerMTok = output
        self.cacheWriteMultiplier = cacheWriteMultiplier
        self.cacheReadMultiplier = cacheReadMultiplier
    }

    func usd(_ usage: APIUsage) -> Double {
        let million = 1_000_000.0
        let input = Double(usage.inputTokens) * inputPerMTok / million
        let output = Double(usage.outputTokens) * outputPerMTok / million
        let cacheWrite = Double(usage.cacheWriteTokens) * inputPerMTok * cacheWriteMultiplier / million
        let cacheRead = Double(usage.cacheReadTokens) * inputPerMTok * cacheReadMultiplier / million
        return input + output + cacheWrite + cacheRead
    }

    /// Cost of a turn we have not made yet, for the cap check and the pre-run
    /// estimate in OnboardSheet. Cache reads are assumed, not cache writes: by the
    /// time a cap matters the prefix has been cached for many turns.
    func estimate(inputTokens: Int, outputTokens: Int, cachedInputTokens: Int = 0) -> Double {
        usd(APIUsage(inputTokens: inputTokens,
                     outputTokens: outputTokens,
                     cacheReadTokens: cachedInputTokens))
    }

    var maxRate: Double { max(inputPerMTok, outputPerMTok) }
}

/// The price table, with the UserDefaults override the architecture calls for.
enum PriceTable {

    /// Defaults by model family. **These are an estimate**, kept as the published
    /// per-class rates rather than per-id guesses, and every cost this app reports
    /// is labelled as one. A gateway bills its own rates; override the table with
    /// `SettingsKeys.onboardingPriceTable` (JSON: `{"<model>": [input, output]}`)
    /// when the numbers need to be right.
    static let fallback: [String: ModelPrice] = [
        "claude-opus-5": ModelPrice(input: 15, output: 75),
        "claude-opus-4-8": ModelPrice(input: 15, output: 75),
        "claude-fable-5-1": ModelPrice(input: 15, output: 75),
        "claude-sonnet-5": ModelPrice(input: 3, output: 15),
        "claude-sonnet-5-5": ModelPrice(input: 3, output: 15),
        "claude-haiku-5-5": ModelPrice(input: 0.8, output: 4),
    ]

    /// The table in force: the defaults, with any override merged over them.
    static func current() -> [String: ModelPrice] {
        var table = fallback
        for (model, price) in overrides() {
            table[model] = price
        }
        return table
    }

    /// `{"anthropic.claude-sonnet-5": [3, 15]}` from UserDefaults. A malformed
    /// entry is skipped with a warning; a malformed table must not zero a run's
    /// accounting.
    static func overrides() -> [String: ModelPrice] {
        let raw = Defaults.string(SettingsKeys.onboardingPriceTable, "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let data = raw.data(using: .utf8) else { return [:] }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let object = value.objectValue else {
            BuildLog.warn("the onboarding price table is not a JSON object; using the defaults")
            return [:]
        }
        var out: [String: ModelPrice] = [:]
        for (model, entry) in object {
            guard let pair = entry.arrayValue, pair.count >= 2,
                  let input = pair[0].numberValue, let output = pair[1].numberValue,
                  input >= 0, output >= 0 else {
                BuildLog.warn("price table entry for \(model) is not [input, output]; ignored")
                continue
            }
            out[model] = ModelPrice(input: input, output: output)
        }
        return out
    }

    /// The price for a model id, and whether it was actually found.
    ///
    /// Gateway ids are opaque and are never parsed for capabilities, but they are
    /// *matched* leniently for pricing only: "anthropic.claude-sonnet-5-v2:0" on a
    /// Bedrock proxy should bill at the Sonnet rate rather than at the table's
    /// worst row. A match is a table key appearing anywhere in the id.
    static func price(for model: String, table: [String: ModelPrice] = PriceTable.current())
        -> (price: ModelPrice, matched: Bool) {
        if let exact = table[model] { return (exact, true) }
        let lowered = model.lowercased()
        // Longest key first, so "claude-sonnet-5-5" wins over "claude-sonnet-5";
        // the name breaks length ties, because Swift's sort is not stable and a
        // price that depends on dictionary order is a cost report that changes
        // between runs for no reason.
        let keys = table.keys.sorted { ($0.count, $0) > ($1.count, $1) }
        for key in keys where lowered.contains(key.lowercased()) {
            if let price = table[key] { return (price, true) }
        }
        return (worstCase(table), false)
    }

    /// The worst case the table knows: the highest input rate and the highest
    /// output rate, which need not come from the same row.
    ///
    /// Built field by field rather than picked as a row, for two reasons. It is
    /// deterministic (picking "the max row" is arbitrary among ties, and Swift's
    /// sort is not stable), and it is the actual upper bound — a table whose
    /// priciest input and priciest output sit on different models would otherwise
    /// under-price an unknown one, and under-pricing is how a cap stops binding.
    static func worstCase(_ table: [String: ModelPrice] = PriceTable.current()) -> ModelPrice {
        guard !table.isEmpty else { return ModelPrice(input: 15, output: 75) }
        let input = table.values.map { $0.inputPerMTok }.max() ?? 15
        let output = table.values.map { $0.outputPerMTok }.max() ?? 75
        let cacheWrite = table.values.map { $0.cacheWriteMultiplier }.max() ?? 1.25
        let cacheRead = table.values.map { $0.cacheReadMultiplier }.max() ?? 0.1
        return ModelPrice(input: input, output: output,
                          cacheWriteMultiplier: cacheWrite, cacheReadMultiplier: cacheRead)
    }
}

/// Per-run accounting: totals, per-model totals, the cache hit rate the progress
/// view shows, and the optional cap.
actor SpendMeter {
    private let table: [String: ModelPrice]
    private(set) var total = OnboardingUsage()
    private(set) var byModel: [String: OnboardingUsage] = [:]
    /// Models that had no price. Reported once, so a cost figure is never presented
    /// as exact when part of it was guessed.
    private(set) var unpricedModels: Set<String> = []
    /// Nil means no cap, which is the default.
    private(set) var capUSD: Double?
    private(set) var capReached = false

    init(capUSD: Double? = nil, table: [String: ModelPrice] = PriceTable.current()) {
        self.capUSD = capUSD.flatMap { $0 > 0 ? $0 : nil }
        self.table = table
    }

    /// Price a reply and add it to the totals. Returns the priced usage, which is
    /// what goes into the unit, the manifest and build-log.jsonl.
    @discardableResult
    func record(model: String, usage: APIUsage) -> OnboardingUsage {
        let (price, matched) = PriceTable.price(for: model, table: table)
        if !matched {
            if unpricedModels.insert(model).inserted {
                BuildLog.warn("no price for model \"\(model)\"; billed at the table's highest rate "
                              + "so the cap still binds — set \(SettingsKeys.onboardingPriceTable) to fix it")
            }
        }
        let priced = OnboardingUsage(
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens,
            cacheReadTokens: usage.cacheReadTokens,
            cacheWriteTokens: usage.cacheWriteTokens,
            usd: price.usd(usage))
        total.add(priced)
        byModel[model, default: OnboardingUsage()].add(priced)
        if let capUSD, total.usd >= capUSD { capReached = true }
        return priced
    }

    /// Whether a turn may start.
    ///
    /// The estimate is checked *before* the request, not after: a 32k-token
    /// streaming turn can cost more than the headroom it began with, so a cap
    /// enforced only on the way out is a cap that is always overshot.
    func mayStartTurn(model: String, estimatedInputTokens: Int, estimatedOutputTokens: Int) -> Bool {
        guard let capUSD else { return true }
        if capReached { return false }
        let (price, _) = PriceTable.price(for: model, table: table)
        let estimate = price.estimate(inputTokens: estimatedInputTokens,
                                      outputTokens: estimatedOutputTokens)
        return total.usd + estimate <= capUSD
    }

    func setCap(_ usd: Double?) {
        capUSD = usd.flatMap { $0 > 0 ? $0 : nil }
        if let capUSD { capReached = total.usd >= capUSD } else { capReached = false }
    }

    /// Cache reads over all input tokens, per model. A zero here is a regression —
    /// the cacheable prefix stopped being byte-stable — and it is invisible without
    /// being shown (ARCHITECTURE 4.2).
    func cacheHitRate(model: String) -> Double {
        guard let usage = byModel[model] else { return 0 }
        let all = usage.inputTokens + usage.cacheReadTokens + usage.cacheWriteTokens
        guard all > 0 else { return 0 }
        return Double(usage.cacheReadTokens) / Double(all)
    }

    /// Seed the meter from a package that has been run before, so a resumed run's
    /// cap accounts for what the earlier session already spent.
    func resume(from usage: OnboardingUsage, byModel existing: [String: OnboardingUsage]) {
        total = usage
        byModel = existing
        if let capUSD { capReached = total.usd >= capUSD }
    }

    /// "$1.42 (estimated)" — the only form a cost is ever shown in.
    static func format(_ usd: Double) -> String {
        String(format: "$%.2f (estimated)", usd)
    }
}
