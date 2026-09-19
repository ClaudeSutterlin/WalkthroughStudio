// RepoAcquisition.swift — "Onboard to a Codebase", milestone M2 (package format, git).
//
// Turns what the user pointed at (a GitHub URL or a local clone) into the two
// repository directories of an onboarding package (ARCHITECTURE.md sections
// 2.1 and 3):
//   <package>/repo-git   full-history clone, URL sources only (mining runs here)
//   <package>/repo       `git archive <sha> | tar -x` snapshot every tool reads
// A local clone is never modified: no worktree is registered in it, `status`
// runs with optional locks off, and only `archive`/`show`/`log`/`blame` read
// from it. Dirty or shallow local clones produce notices, not failures.
import Foundation

/// Where the repository comes from.
enum RepoSource {
    /// A clone URL (https://github.com/org/repo.git, or anything git accepts).
    case url(String)
    /// A folder inside a local clone (the top level is resolved with git).
    case local(URL)
}

/// The outcome of `RepoAcquisition.acquire`.
struct AcquiredRepo: Equatable {
    /// Full sha the package is pinned at (`manifest.headSHA`).
    let headSHA: String
    /// The user's own clone (top level) for `.local`; nil for `.url`.
    let localClone: URL?
    /// `<package>/repo-git` for `.url`; nil for `.local`.
    let repoGit: URL?
    /// `<package>/repo`: the pinned snapshot every tool reads.
    let repoDir: URL
    /// Human-readable caveats (dirty tree, shallow clone); empty when clean.
    let notices: [String]

    /// The repository `git show`/`log`/`blame` should run in.
    var historyRepo: URL { localClone ?? repoGit ?? repoDir }
}

struct RepoAcquisition {

    static let cloneDirName = "repo-git"
    static let snapshotDirName = "repo"

    static let dirtyNotice = "Uncommitted changes are not part of the package"
    static let shallowNotice = "Shallow clone: history mining is limited; run git fetch --unshallow"
    static let needsTokenNotice = "This repository needs a GitHub token; add one in Settings"

    /// Acquire `source` into `store.root`, pinned at `pinnedSHA` (nil = HEAD of
    /// the default branch, or the local clone's HEAD). `progress` receives
    /// short stage messages. Only `store.root` is used (the store's other
    /// duties belong to PackageStore).
    static func acquire(
        _ source: RepoSource,
        into store: PackageStore,
        pinnedSHA: String?,
        token: String?,
        progress: @escaping (String) -> Void
    ) async throws -> AcquiredRepo {
        let git = GitRunner()
        let root = store.root
        let snapshot = root.appendingPathComponent(snapshotDirName, isDirectory: true)
        var notices: [String] = []

        switch source {
        case .url(let rawURL):
            let url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else { throw StudioError("Repository URL is empty") }
            let cloneDir = root.appendingPathComponent(cloneDirName, isDirectory: true)

            var reopened = false
            if FileManager.default.fileExists(atPath: cloneDir.appendingPathComponent(".git").path) {
                progress("Fetching \(url)…")
                do {
                    try await git.fetch(repo: cloneDir, token: token)
                } catch {
                    throw authAware(error, token: token)
                }
                reopened = true
            } else {
                if FileManager.default.fileExists(atPath: cloneDir.path) {
                    try FileManager.default.removeItem(at: cloneDir)
                }
                progress("Cloning \(url)…")
                do {
                    try await git.clone(url: url, to: cloneDir, token: token)
                } catch {
                    throw authAware(error, token: token)
                }
            }

            progress("Resolving revision…")
            let sha: String
            if let pinnedSHA {
                sha = try await git.revParse(pinnedSHA, in: cloneDir)
            } else if reopened {
                // `git fetch` never moves the clone's own HEAD, so an unpinned
                // reopen must read the remote's default branch (section 3:
                // "sha is the default branch head"), not the sha the package was
                // first cloned at. Older clones may lack origin/HEAD; then the
                // local HEAD is the best answer available.
                do {
                    sha = try await git.revParse("refs/remotes/origin/HEAD", in: cloneDir)
                } catch {
                    sha = try await git.revParse("HEAD", in: cloneDir)
                }
            } else {
                // Fresh clone: HEAD is the default branch head.
                sha = try await git.revParse("HEAD", in: cloneDir)
            }
            if try await git.isShallow(repo: cloneDir) {
                notices.append(shallowNotice)
            }

            progress("Extracting \(sha.prefix(7)) into repo/…")
            try resetDirectory(snapshot)
            try await git.archive(sha: sha, from: cloneDir, into: snapshot)

            return AcquiredRepo(
                headSHA: sha, localClone: nil, repoGit: cloneDir, repoDir: snapshot, notices: notices
            )

        case .local(let folder):
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue else {
                throw StudioError("\(folder.path) is not a folder")
            }
            progress("Inspecting \(folder.lastPathComponent)…")
            let topLevelText: String
            do {
                topLevelText = try await git.run(["rev-parse", "--show-toplevel"], in: folder)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                throw StudioError("\(folder.path) is not inside a git repository (\(error.localizedDescription))")
            }
            guard !topLevelText.isEmpty else {
                throw StudioError("\(folder.path) is not inside a git repository")
            }
            let clone = URL(fileURLWithPath: topLevelText, isDirectory: true)

            if try await git.isDirty(repo: clone) {
                notices.append(dirtyNotice)
            }
            if try await git.isShallow(repo: clone) {
                notices.append(shallowNotice)
            }

            let sha = try await git.revParse(pinnedSHA ?? "HEAD", in: clone)
            progress("Extracting \(sha.prefix(7)) into repo/…")
            try resetDirectory(snapshot)
            try await git.archive(sha: sha, from: clone, into: snapshot)

            return AcquiredRepo(
                headSHA: sha, localClone: clone, repoGit: nil, repoDir: snapshot, notices: notices
            )
        }
    }

    /// Remove and recreate a directory owned by the package.
    private static func resetDirectory(_ dir: URL) throws {
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// A clone/fetch failure that looks like missing credentials, without a
    /// token, becomes the Settings notice; anything else passes through.
    private static func authAware(_ error: Error, token: String?) -> Error {
        let message = (error as? StudioError)?.message ?? error.localizedDescription
        if (token ?? "").isEmpty, GitRunner.looksLikeAuthFailure(message) {
            return StudioError(needsTokenNotice + " (" + GitRunner.tail(message, maxLines: 3, maxCharacters: 300) + ")")
        }
        return error
    }
}
