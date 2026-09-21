import Foundation

/// Small read-only accessors the projectors need, kept out of `PacketModels` so the
/// packet types stay a faithful decoding of the on-disk contract and nothing else.
extension ResearchPacket {

    /// The seven-character form used in every `code:` anchor.
    var sha7: String { String(headSHA.prefix(7)) }

    /// Facts of one kind that may appear in a deliverable.
    ///
    /// PACKET.md section 4: content uses `verified` and `unknown` facts and never
    /// `refuted` ones. A `proposed` fact has no verdict yet, so it has not earned a
    /// place either; `proposedFacts` counts what was held back, because a producer
    /// that skipped verification deserves to be told why its research went missing
    /// rather than to find empty registers.
    func usableFacts(kind: String? = nil) -> [PacketFact] {
        guard let kind else { return usableFacts }
        return usableFacts.filter { $0.kind == kind }
    }

    var proposedFacts: [PacketFact] {
        facts.filter { $0.status == "proposed" }
    }

    func anchors(of fact: PacketFact) -> [String] {
        fact.evidence.map { $0.anchor }
    }

    /// The anchor a chip should point at: the first that names code, else the first at all.
    func primaryAnchor(_ fact: PacketFact) -> String? {
        let all = anchors(of: fact)
        return all.first { $0.hasPrefix("code:") } ?? all.first
    }
}

extension JSONValue {
    /// The value as a Foundation object, for writing through JSONSerialization into the
    /// `.links.json` sidecars. `null` becomes `NSNull` so it survives serialization.
    var jsonObject: Any {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() && abs(n) < 9.007199254740992e15 ? Int(n) : n
        case .bool(let b): return b
        case .null: return NSNull()
        case .array(let a): return a.map { $0.jsonObject }
        case .object(let o): return o.mapValues { $0.jsonObject }
        }
    }
}
