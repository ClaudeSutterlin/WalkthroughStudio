import Foundation

/// `index/anchors.json`: every anchor, and every deliverable that cites it.
///
/// This is what lets the code view answer "where is this file covered?" — the question
/// that makes a package feel like one surface rather than three. `HubProjector` writes
/// it; this reads it.
struct BacklinkIndex: Equatable {
    static let fileName = "index/anchors.json"

    struct Reference: Codable, Equatable, Hashable {
        /// "doc", "diagram", "trace" or "video".
        var kind: String
        /// The citing deliverable, as an anchor-shaped reference: `diagram:erd#orders`,
        /// `doc:tech-debt`, `trace:order-creation`, `video:architecture#t=272.4`.
        var ref: String
        /// What to show on the chip: the deliverable's id.
        var label: String

        init(kind: String, ref: String, label: String) {
            self.kind = kind
            self.ref = ref
            self.label = label
        }

        private enum CodingKeys: String, CodingKey { case kind, ref, label }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
            ref = try c.decodeIfPresent(String.self, forKey: .ref) ?? ""
            label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(kind, forKey: .kind)
            try c.encode(ref, forKey: .ref)
            try c.encode(label, forKey: .label)
        }
    }

    private(set) var byAnchor: [String: [Reference]]
    /// Repository path -> every anchor in the index that names it, whatever its line
    /// range. Built once on load: the code view asks per file, and the index keys carry
    /// ranges, so an exact-key lookup would find almost nothing.
    private(set) var anchorsByPath: [String: [String]]

    init(byAnchor: [String: [Reference]]) {
        self.byAnchor = byAnchor
        var paths: [String: [String]] = [:]
        for anchor in byAnchor.keys.sorted() {
            guard let path = ProjectionSupport.codePath(anchor) else { continue }
            paths[path, default: []].append(anchor)
        }
        self.anchorsByPath = paths
    }

    static func load(from store: PackageStore) throws -> BacklinkIndex {
        guard store.exists(fileName) else { return BacklinkIndex(byAnchor: [:]) }
        let data = try store.readData(fileName)
        let decoded = try OnboardingJSON.decoder().decode([String: [Reference]].self, from: data)
        return BacklinkIndex(byAnchor: decoded)
    }

    /// The deliverables citing exactly this anchor.
    func references(for anchor: String) -> [Reference] {
        byAnchor[anchor] ?? []
    }

    /// The deliverables citing any anchor that names this file, de-duplicated by `ref`
    /// and ordered as the index orders them — diagrams, then registers, then traces.
    func references(forPath path: String) -> [Reference] {
        var seen = Set<String>()
        var out: [Reference] = []
        for anchor in anchorsByPath[path] ?? [] {
            for reference in byAnchor[anchor] ?? [] where seen.insert(reference.ref).inserted {
                out.append(reference)
            }
        }
        return out
    }

    /// Paths the index knows about at all — the code view's "covered files" listing.
    var coveredPaths: [String] { anchorsByPath.keys.sorted() }

    var anchorCount: Int { byAnchor.count }
}
