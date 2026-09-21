import Foundation

/// `hub/index.json`: the recommended reading order with minutes, plus the coverage
/// summary. `HubProjector` writes it, the hub web view reads it, and the native
/// navigator reads it too — one order, shown in two places, never two orders.
struct HubIndex: Codable, Equatable {
    static let fileName = "hub/index.json"

    var version: Int = PacketManifest.currentVersion
    var summary: String = ""
    var totalMinutes: Int = 0
    var items: [Item] = []
    var repo = Repo()
    var coverage = Coverage()

    init() {}

    private enum CodingKeys: String, CodingKey {
        case version, summary, totalMinutes, items, repo, coverage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? PacketManifest.currentVersion
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        totalMinutes = try c.decodeIfPresent(Int.self, forKey: .totalMinutes) ?? 0
        items = try c.decodeIfPresent([Item].self, forKey: .items) ?? []
        repo = try c.decodeIfPresent(Repo.self, forKey: .repo) ?? Repo()
        coverage = try c.decodeIfPresent(Coverage.self, forKey: .coverage) ?? Coverage()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(summary, forKey: .summary)
        try c.encode(totalMinutes, forKey: .totalMinutes)
        try c.encode(items, forKey: .items)
        try c.encode(repo, forKey: .repo)
        try c.encode(coverage, forKey: .coverage)
    }

    static func load(from store: PackageStore) throws -> HubIndex {
        try OnboardingJSON.decoder().decode(HubIndex.self, from: try store.readData(fileName))
    }

    /// The items a reader works through, grouped the way the navigator lists them.
    func items(ofKind kind: String) -> [Item] { items.filter { $0.kind == kind } }

    struct Item: Codable, Equatable, Identifiable {
        /// The anchor-shaped id: `doc:tech-debt`, `video:architecture`, `trace:...`.
        var id: String = ""
        /// "doc", "diagram", "trace" or "video".
        var kind: String = ""
        var title: String = ""
        /// Package-relative.
        var path: String = ""
        var minutes: Int = 0
        var order: Int = 0

        init() {}

        private enum CodingKeys: String, CodingKey { case id, kind, title, path, minutes, order }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
            kind = try c.decodeIfPresent(String.self, forKey: .kind) ?? ""
            title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
            path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
            minutes = try c.decodeIfPresent(Int.self, forKey: .minutes) ?? 0
            order = try c.decodeIfPresent(Int.self, forKey: .order) ?? 0
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(kind, forKey: .kind)
            try c.encode(title, forKey: .title)
            try c.encode(path, forKey: .path)
            try c.encode(minutes, forKey: .minutes)
            try c.encode(order, forKey: .order)
        }
    }

    /// Republished from `packet.json`, so the navigator can name the commit without
    /// opening the packet.
    struct Repo: Codable, Equatable {
        var name: String? = nil
        var url: String? = nil
        var headSHA: String = ""
        var defaultBranch: String? = nil

        init() {}

        private enum CodingKeys: String, CodingKey { case name, url, headSHA, defaultBranch }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decodeIfPresent(String.self, forKey: .name)
            url = try c.decodeIfPresent(String.self, forKey: .url)
            headSHA = try c.decodeIfPresent(String.self, forKey: .headSHA) ?? ""
            defaultBranch = try c.decodeIfPresent(String.self, forKey: .defaultBranch)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(name, forKey: .name)
            try c.encodeIfPresent(url, forKey: .url)
            try c.encode(headSHA, forKey: .headSHA)
            try c.encodeIfPresent(defaultBranch, forKey: .defaultBranch)
        }

        var display: String {
            let label = name ?? url ?? "repository"
            return headSHA.isEmpty ? label : "\(label) @ \(headSHA.prefix(7))"
        }
    }

    /// Only what the navigator's coverage strip shows; the hub reads the rest of
    /// `coverage.json` itself.
    struct Coverage: Codable, Equatable {
        var directories: [Directory] = []
        var counts: [String: Int] = [:]

        init() {}

        private enum CodingKeys: String, CodingKey { case directories, counts }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            directories = try c.decodeIfPresent([Directory].self, forKey: .directories) ?? []
            counts = try c.decodeIfPresent([String: Int].self, forKey: .counts) ?? [:]
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(directories, forKey: .directories)
            try c.encode(counts, forKey: .counts)
        }

        struct Directory: Codable, Equatable, Identifiable {
            var path: String = ""
            var level: String = "unread"
            var files: Int = 0
            var filesRead: Int = 0
            var reason: String? = nil

            var id: String { path }

            init() {}

            private enum CodingKeys: String, CodingKey { case path, level, files, filesRead, reason }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
                level = try c.decodeIfPresent(String.self, forKey: .level) ?? "unread"
                files = try c.decodeIfPresent(Int.self, forKey: .files) ?? 0
                filesRead = try c.decodeIfPresent(Int.self, forKey: .filesRead) ?? 0
                reason = try c.decodeIfPresent(String.self, forKey: .reason)
            }

            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(path, forKey: .path)
                try c.encode(level, forKey: .level)
                try c.encode(files, forKey: .files)
                try c.encode(filesRead, forKey: .filesRead)
                try c.encodeIfPresent(reason, forKey: .reason)
            }

            /// 0...1, for the navigator's bar.
            var fraction: Double { files > 0 ? min(1, Double(filesRead) / Double(files)) : 0 }
        }
    }
}
