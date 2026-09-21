import Foundation

/// Resolves the one anchor grammar (D5) against one package: given
/// `code:src/api/orders_handler.py@fb63e78#L12-L18`, say which file the player should
/// open, at which lines, and whether it is actually there.
///
/// Every chip in every deliverable routes through here, so "links never dangle"
/// (ON-8.3) is this type's job. `linkRouterProbe` walks every anchor in the fixture
/// package and asserts each one resolves, then breaks one deliberately and asserts the
/// failure names the right kind.
struct LinkRouter {

    let store: PackageStore
    /// The commit every `code:` anchor in this package must be pinned to.
    let headSHA: String
    /// Fact ids the package carries, for `fact:` anchors. Empty means "do not check" —
    /// a package projected without its packet still routes everything else.
    let factIDs: Set<String>

    init(store: PackageStore, headSHA: String, factIDs: Set<String> = []) {
        self.store = store
        self.headSHA = headSHA
        self.factIDs = factIDs
    }

    var sha7: String { String(headSHA.prefix(7)) }

    // MARK: - Destinations

    enum Destination: Equatable {
        /// Open the code view on `path` at the pinned commit, banding `lines`.
        case code(path: String, lines: ClosedRange<Int>?)
        /// Open a rendered page in the hub web view, scrolled to `fragment`.
        case page(path: String, fragment: String?)
        /// Open the diagram, focusing a node.
        case diagram(id: String, node: String?)
        /// Seek the player. `chapter` wins over `seconds` when both are present.
        case video(id: String, seconds: Double?, chapter: String?)
        /// Show the fact's evidence card.
        case fact(id: String)
        /// Show the commit. Needs git, so the player opens it through `GitRunner`.
        case commit(sha: String)
        /// Show a recorded command's output.
        case command(unit: String, n: Int)
        /// An issue in the repository's tracker. The number alone does not name a host,
        /// so the player builds the URL from the manifest's remote.
        case issue(number: Int)
        /// Leaves the app.
        case external(URL)
    }

    struct Failure: Equatable, CustomStringConvertible {
        let anchor: String
        /// The anchor's kind, so a report can group failures by what broke.
        let kind: String
        let reason: String

        var description: String { "\(anchor) (\(kind)): \(reason)" }
    }

    // MARK: - Resolution

    /// Resolve an anchor, or a bare deliverable reference.
    ///
    /// Two grammars arrive here and only one is the packet's. An *evidence* anchor must
    /// carry its fragment — `doc:tech-debt#ranked-by-severity` names a claim's home, and
    /// `PacketValidator` rejects one without a section, because a citation that points
    /// at a whole document has not really cited anything. A *deliverable id* is the
    /// other thing: `doc:tech-debt` is what `hub/index.json` and `manifest.deliverables`
    /// call the document itself, and clicking it in the navigator means "open this",
    /// not "open a section of this". Rather than loosen `Anchor` and lose the packet
    /// check, the bare form is recognized here and opened at the top.
    func resolve(_ raw: String) -> Result<Destination, Failure> {
        do {
            return resolve(try Anchor.parse(raw))
        } catch {
            if let bare = LinkRouter.bareDeliverable(raw) {
                return resolve(bare).mapError {
                    Failure(anchor: raw, kind: $0.kind, reason: $0.reason)
                }
            }
            let kind = raw.split(separator: ":", maxSplits: 1).first.map(String.init) ?? "?"
            return .failure(Failure(anchor: raw, kind: kind,
                                    reason: "not a valid anchor: \(error.localizedDescription)"))
        }
    }

    /// `doc:tech-debt`, `diagram:erd`, `trace:order-creation`, `video:architecture` —
    /// a deliverable named with no fragment, as the hub index and the manifest name it.
    /// The empty slug, empty node, hop 0 and nil time each mean "the whole thing", which
    /// is what `resolve(_:)` already does with them.
    static func bareDeliverable(_ raw: String) -> Anchor? {
        guard let colon = raw.firstIndex(of: ":") else { return nil }
        let kind = String(raw[raw.startIndex..<colon])
        let id = String(raw[raw.index(after: colon)...])
        guard !id.isEmpty, !id.contains("#"), !id.contains(" ") else { return nil }
        switch kind {
        case "doc": return .doc(id: id, slug: "")
        case "diagram": return .diagram(id: id, node: "")
        case "trace": return .trace(id: id, hop: 0)
        case "video": return .video(id: id, seconds: nil, chapter: nil)
        default: return nil
        }
    }

    func resolve(_ anchor: Anchor) -> Result<Destination, Failure> {
        func fail(_ reason: String) -> Result<Destination, Failure> {
            .failure(Failure(anchor: anchor.string, kind: anchor.kind, reason: reason))
        }

        switch anchor {
        case .code(let path, let sha, let lines):
            if let sha, sha != sha7, !headSHA.hasPrefix(sha) {
                return fail("pinned to \(sha) but this package is at \(sha7)")
            }
            // A directory anchor (a container node) has no file; the hub shows a listing.
            guard !anchor.isDirectory else {
                return .success(.code(path: path, lines: nil))
            }
            guard codePaths.contains(path) else {
                return fail("no source for \(path) travelled with the package "
                            + "(code/index.json lists \(codePaths.count) file(s))")
            }
            return .success(.code(path: path, lines: lines))

        case .doc(let id, let slug):
            // A register or a trace document: both render to the same kind of page, and
            // the grammar does not distinguish them, so look for either.
            for relative in ["docs/\(id).html", "traces/\(id).html"] where store.exists(relative) {
                if !slug.isEmpty, let html = try? store.readString(relative),
                   !html.contains("id=\"\(slug)\"") {
                    return fail("\(relative) has no section with the id \"\(slug)\"")
                }
                return .success(.page(path: relative, fragment: slug.isEmpty ? nil : slug))
            }
            return fail("neither docs/\(id).html nor traces/\(id).html is in the package")

        case .diagram(let id, let node):
            let source = "diagrams/\(id).mmd"
            let traceSource = "traces/\(id).mmd"
            let found = store.exists(source) ? source : (store.exists(traceSource) ? traceSource : nil)
            guard found != nil else {
                return fail("neither \(source) nor \(traceSource) is in the package")
            }
            if !node.isEmpty, let nodes = diagramNodes(id), !nodes.contains(node) {
                return fail("\(id) has no node \"\(node)\" (it has \(nodes.count))")
            }
            return .success(.diagram(id: id, node: node.isEmpty ? nil : node))

        case .trace(let id, let hop):
            guard store.exists("traces/\(id).md") else {
                return fail("traces/\(id).md is not in the package")
            }
            if hop > 0, let markdown = try? store.readString("traces/\(id).md"),
               !markdown.contains("\n\(hop). ") {
                return fail("the trace document has no hop \(hop)")
            }
            return .success(.page(path: "traces/\(id).html", fragment: hop > 0 ? "hops" : nil))

        case .video(let id, let seconds, let chapter):
            guard store.exists("videos/\(id)/video.mp4") else {
                return fail("videos/\(id)/video.mp4 is not in the package")
            }
            if let chapter, !chapter.isEmpty {
                guard let chapters = videoChapters(id) else {
                    return fail("videos/\(id)/chapters.json is missing, so #c=\(chapter) cannot be checked")
                }
                guard chapters.contains(where: { $0.id == chapter }) else {
                    return fail("video \(id) has no chapter \"\(chapter)\"")
                }
            }
            if let seconds, let duration = videoDuration(id), seconds > duration + 0.25 {
                return fail("t=\(Anchor.formatSeconds(seconds)) is past the end of a "
                            + "\(Anchor.formatSeconds(duration)) video")
            }
            return .success(.video(id: id, seconds: seconds, chapter: chapter))

        case .fact(let id):
            guard factIDs.isEmpty || factIDs.contains(id) else {
                return fail("no fact with that id is in the package's fact store")
            }
            return .success(.fact(id: id))

        case .commit(let sha):
            return .success(.commit(sha: sha))

        case .cmd(let unit, let n):
            return .success(.command(unit: unit, n: n))

        case .issue(let n):
            return .success(.issue(number: n))

        case .url:
            return .success(.external(anchor.url))
        }
    }

    /// Resolves many anchors and returns only what failed — the shape a probe, and the
    /// package review pane, both want.
    func audit(_ anchors: [String]) -> [Failure] {
        var seen = Set<String>()
        var failures: [Failure] = []
        for raw in anchors where seen.insert(raw).inserted {
            if case .failure(let failure) = resolve(raw) { failures.append(failure) }
        }
        return failures
    }

    // MARK: - Package lookups, read once

    /// `code/index.json` lists the sources that travelled with the package.
    private var codePaths: Set<String> {
        if let cached = LinkRouter.codePathCache.value(for: store.root) { return cached }
        var paths = Set<String>()
        if let data = try? store.readData("code/index.json"),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let listed = object["paths"] as? [String] {
            paths = Set(listed)
        }
        LinkRouter.codePathCache.set(paths, for: store.root)
        return paths
    }

    private func diagramNodes(_ id: String) -> Set<String>? {
        for relative in ["diagrams/\(id).links.json", "traces/\(id).links.json"] {
            guard let data = try? store.readData(relative),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let nodes = object["nodes"] as? [String: Any] else { continue }
            return Set(nodes.keys)
        }
        return nil          // no sidecar: cannot check the node, so do not fail on it
    }

    private func videoChapters(_ id: String) -> [ChapterMarker]? {
        guard let data = try? store.readData("videos/\(id)/chapters.json") else { return nil }
        return try? OnboardingJSON.decoder().decode([ChapterMarker].self, from: data)
    }

    private func videoDuration(_ id: String) -> Double? {
        guard let data = try? store.readData("videos/\(id)/transcript.json"),
              let transcript = try? OnboardingJSON.decoder().decode(TranscriptDoc.self, from: data)
        else { return nil }
        return transcript.duration
    }

    /// `code/index.json` is read once per package and then held: every chip in every
    /// document routes through `resolve`, and re-reading a file per chip turned a
    /// document open into hundreds of syscalls.
    private final class PathCache: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [URL: Set<String>] = [:]

        func value(for root: URL) -> Set<String>? {
            lock.lock()
            defer { lock.unlock() }
            return storage[root]
        }

        func set(_ paths: Set<String>, for root: URL) {
            lock.lock()
            defer { lock.unlock() }
            storage[root] = paths
        }

        func forget(_ root: URL) {
            lock.lock()
            defer { lock.unlock() }
            storage[root] = nil
        }
    }

    private static let codePathCache = PathCache()

    /// Called after a projection rewrites `code/`, so the next resolve sees the new list.
    static func invalidateCache(for root: URL) {
        codePathCache.forget(root)
    }
}
