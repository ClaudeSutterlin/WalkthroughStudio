// SelfTestOnboarding+Git — "Onboard to a Codebase", milestone M2 (package format, git).
//
// `gitRunnerProbe`: exercises GitRunner and RepoAcquisition against the
// deterministic fixture repository (scripts/make-fixture-repo.sh) and asserts
// the facts in `FixtureRepoFacts`. Runs from `runOnboarding` in
// SelfTestOnboarding.swift; select it alone with `--probe gitRunnerProbe`.
import Foundation

extension SelfTest {

    // MARK: gitRunnerProbe

    static func gitRunnerProbe(_ ctx: OnboardingProbeContext) async throws {
        let git = GitRunner()
        let repo = ctx.fixtureRepo

        // 1. rev-parse, shallow, dirty
        let head = try await git.revParse("HEAD", in: repo)
        guard head == FixtureRepoFacts.headSHA else {
            throw StudioError("gitRunnerProbe: revParse(HEAD) is \(head), expected \(FixtureRepoFacts.headSHA)")
        }
        let shallow = try await git.isShallow(repo: repo)
        guard shallow == false else {
            throw StudioError("gitRunnerProbe: isShallow is true for the fixture")
        }
        let dirty = try await git.isDirty(repo: repo)
        guard dirty == false else {
            throw StudioError("gitRunnerProbe: isDirty is true for the fixture (status --porcelain not empty)")
        }

        // 2. show + lineCount agree on the hotspot file
        let hotspot = FixtureRepoFacts.hotspotPath
        let contents = try await git.show(sha: head, path: hotspot, repo: repo)
        let lines = try await git.lineCount(sha: head, path: hotspot, repo: repo)
        guard lines > 20 else {
            throw StudioError("gitRunnerProbe: lineCount(\(hotspot)) is \(lines), expected > 20")
        }
        var counted = contents.components(separatedBy: "\n").count
        if contents.hasSuffix("\n") { counted -= 1 }
        if contents.isEmpty { counted = 0 }
        guard counted == lines else {
            throw StudioError("gitRunnerProbe: lineCount(\(hotspot)) is \(lines) but show() has \(counted) lines")
        }
        guard contents.contains("class OrdersRepo") else {
            throw StudioError("gitRunnerProbe: show(\(hotspot)) does not contain \"class OrdersRepo\"")
        }

        // 3. log: 12 commits, Ada 8 / Grace 4, ISO dates, hotspot touched 6 times
        let commits = try await git.log(path: nil, limit: 100, repo: repo)
        guard commits.count == FixtureRepoFacts.commitCount else {
            throw StudioError("gitRunnerProbe: log(limit: 100) returned \(commits.count) commits, expected \(FixtureRepoFacts.commitCount)")
        }
        var authorCounts: [String: Int] = [:]
        for commit in commits { authorCounts[commit.author, default: 0] += 1 }
        for (author, expected) in FixtureRepoFacts.authorCounts {
            guard authorCounts[author] == expected else {
                let observed = authorCounts[author].map { String($0) } ?? "missing"
                throw StudioError("gitRunnerProbe: log author count for \(author) is \(observed), expected \(expected) (seen: \(authorCounts))")
            }
        }
        guard let newest = commits.first, newest.sha == head else {
            throw StudioError("gitRunnerProbe: log's first commit is \(commits.first?.sha ?? "none"), expected HEAD \(head)")
        }
        guard newest.dateISO.hasPrefix("2025-02-06T"), !newest.subject.isEmpty else {
            throw StudioError("gitRunnerProbe: HEAD commit date/subject look wrong: \(newest.dateISO) / \(newest.subject)")
        }
        let hotspotCommits = try await git.log(path: hotspot, limit: 100, repo: repo)
        guard hotspotCommits.count == FixtureRepoFacts.hotspotCommitCount else {
            throw StudioError("gitRunnerProbe: log(path: \(hotspot)) returned \(hotspotCommits.count) commits, expected \(FixtureRepoFacts.hotspotCommitCount)")
        }
        let limited = try await git.log(path: nil, limit: 3, repo: repo)
        guard limited.count == 3 else {
            throw StudioError("gitRunnerProbe: log(limit: 3) returned \(limited.count) commits")
        }

        // 4. blame: schema.sql lines 1-3 are Ada's, from commit 1
        let blame = try await git.blame(path: "db/schema.sql", startLine: 1, endLine: 3, repo: repo)
        guard blame.count == 3 else {
            throw StudioError("gitRunnerProbe: blame(db/schema.sql 1-3) returned \(blame.count) lines, expected 3")
        }
        for (index, blamed) in blame.enumerated() {
            guard blamed.line == index + 1 else {
                throw StudioError("gitRunnerProbe: blame line \(index) reports line number \(blamed.line), expected \(index + 1)")
            }
            guard blamed.author == "Ada Lovelace" else {
                throw StudioError("gitRunnerProbe: blame line \(blamed.line) author is \"\(blamed.author)\", expected Ada Lovelace")
            }
            guard blamed.sha.count == 40 else {
                throw StudioError("gitRunnerProbe: blame line \(blamed.line) sha is \"\(blamed.sha)\", expected 40 hex")
            }
            guard blamed.dateISO.hasPrefix("2025-01-04T") else {
                throw StudioError("gitRunnerProbe: blame line \(blamed.line) date is \"\(blamed.dateISO)\", expected 2025-01-04 (commit 1)")
            }
        }

        // 5. archive HEAD and compare with ls-tree; the fixture's worktree list
        //    must be unchanged (archive registers nothing, unlike worktree add).
        let worktreesBefore = try await git.worktreeList(repo: repo)
        guard worktreesBefore.count == 1 else {
            throw StudioError("gitRunnerProbe: fixture has \(worktreesBefore.count) worktrees before archive, expected 1: \(worktreesBefore)")
        }
        let archiveDir = ctx.scratch.appendingPathComponent("archive", isDirectory: true)
        try await git.archive(sha: head, from: repo, into: archiveDir)
        let tracked = Set(try await git.lsTree(sha: head, repo: repo))
        let extracted = Set(relativeFiles(under: archiveDir))
        guard tracked == extracted else {
            let missing = tracked.subtracting(extracted).sorted()
            let extra = extracted.subtracting(tracked).sorted()
            throw StudioError("gitRunnerProbe: archive differs from ls-tree — missing \(missing), extra \(extra)")
        }
        guard tracked.count == FixtureRepoFacts.files.count else {
            throw StudioError("gitRunnerProbe: ls-tree lists \(tracked.count) files, expected \(FixtureRepoFacts.files.count)")
        }
        let subtree = try await git.lsTree(sha: head, path: "db", repo: repo)
        guard subtree.count == 3, subtree.contains("db/schema.sql") else {
            throw StudioError("gitRunnerProbe: lsTree(path: db) returned \(subtree), expected schema + 2 migrations")
        }
        let worktreesAfter = try await git.worktreeList(repo: repo)
        guard worktreesAfter == worktreesBefore else {
            throw StudioError("gitRunnerProbe: worktree list changed after archive: \(worktreesBefore) -> \(worktreesAfter)")
        }

        // 6. RepoAcquisition on the local fixture: snapshot in <pkg>/repo, no notices.
        let store = try PackageStore(root: ctx.scratch.appendingPathComponent("pkg", isDirectory: true))
        var stages: [String] = []
        let acquired = try await RepoAcquisition.acquire(
            .local(repo), into: store, pinnedSHA: nil, token: nil
        ) { stage in stages.append(stage) }
        guard acquired.headSHA == head else {
            throw StudioError("gitRunnerProbe: acquire(.local) headSHA is \(acquired.headSHA), expected \(head)")
        }
        let expectedRepoDir = store.root.appendingPathComponent(RepoAcquisition.snapshotDirName, isDirectory: true)
        guard acquired.repoDir.standardizedFileURL.path == expectedRepoDir.standardizedFileURL.path else {
            throw StudioError("gitRunnerProbe: acquire(.local) repoDir is \(acquired.repoDir.path), expected \(expectedRepoDir.path)")
        }
        guard FileManager.default.fileExists(atPath: acquired.repoDir.appendingPathComponent("db/schema.sql").path) else {
            throw StudioError("gitRunnerProbe: acquire(.local) repoDir lacks db/schema.sql")
        }
        guard acquired.notices.isEmpty else {
            throw StudioError("gitRunnerProbe: acquire(.local) produced notices for a clean fixture: \(acquired.notices)")
        }
        guard acquired.localClone != nil, acquired.repoGit == nil else {
            throw StudioError("gitRunnerProbe: acquire(.local) should set localClone and leave repoGit nil")
        }
        guard !FileManager.default.fileExists(atPath: store.root.appendingPathComponent(RepoAcquisition.cloneDirName).path) else {
            throw StudioError("gitRunnerProbe: acquire(.local) must not create repo-git/")
        }
        guard !stages.isEmpty else {
            throw StudioError("gitRunnerProbe: acquire(.local) reported no progress stages")
        }
        let worktreesFinal = try await git.worktreeList(repo: repo)
        guard worktreesFinal == worktreesBefore else {
            throw StudioError("gitRunnerProbe: worktree list changed after acquire: \(worktreesFinal)")
        }

        // 7. A pinned older sha must be honoured too.
        let oldest = commits[commits.count - 1]
        let pinned = try await RepoAcquisition.acquire(
            .local(repo), into: store, pinnedSHA: String(oldest.sha.prefix(12)), token: nil
        ) { _ in }
        guard pinned.headSHA == oldest.sha else {
            throw StudioError("gitRunnerProbe: pinned acquire resolved \(pinned.headSHA), expected \(oldest.sha)")
        }
        guard !FileManager.default.fileExists(atPath: pinned.repoDir.appendingPathComponent("templates/email.tmpl").path) else {
            throw StudioError("gitRunnerProbe: pinned acquire at commit 1 still contains templates/email.tmpl (added later)")
        }

        print("selftest: gitRunnerProbe OK (HEAD \(head.prefix(7)), \(commits.count) commits, Ada 8 / Grace 4, \(lines) lines in \(hotspot), blame 1-3 Ada, archive == ls-tree (\(tracked.count) files), 1 worktree, acquire(.local) clean)")
    }

    /// Every regular file under `root` as a "/"-joined path relative to it.
    private static func relativeFiles(under root: URL) -> [String] {
        var result: [String] = []
        let base = root.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return result }
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            var path = fileURL.standardizedFileURL.path
            if path.hasPrefix(base) { path = String(path.dropFirst(base.count)) }
            if path.hasPrefix("/") { path.removeFirst() }
            result.append(path)
        }
        return result
    }
}
