// GitRunner.swift — "Onboard to a Codebase", milestone M2 (package format, git).
//
// The one place the onboarding feature shells out to git. Every call runs off
// the main actor (a detached Task around a synchronous Process), has a timeout
// that kills the child on expiry, captures stdout and stderr, and throws a
// `StudioError` carrying the stderr tail on a non-zero exit. The binary comes
// from `xcrun --find git`: a bare stat of /usr/bin/git pops the Command Line
// Tools dialog on Macs without them (ARCHITECTURE.md sections 3 and 14).
//
// Token handling (private clones): the token lives only in the child's
// environment (`GIT_TOKEN`) and is read by a GIT_ASKPASS helper script written
// to a private temp dir and deleted afterwards. It is never written to disk,
// never logged, and `-c credential.helper=` keeps the osxkeychain helper from
// prompting or persisting it.
import Foundation

/// One commit as `log` reports it.
struct GitCommit: Equatable, Sendable {
    let sha: String
    let author: String
    /// ISO 8601 author date, e.g. "2025-01-04T10:00:00Z" or "...+01:00".
    let dateISO: String
    let subject: String
}

/// One blamed line as `blame` reports it (`line` is the 1-based line in the
/// blamed revision).
struct GitBlameLine: Equatable, Sendable {
    let line: Int
    let author: String
    let sha: String
    let dateISO: String
}

struct GitRunner: Sendable {

    /// Seconds a single git (or git | tar) invocation may take before it is
    /// killed. Clones of large repositories are the reason the default is long.
    var timeout: TimeInterval = 600

    init(timeout: TimeInterval = 600) {
        self.timeout = timeout
    }

    // MARK: Locating git

    private static var cachedGitURL: URL?
    private static let locateLock = NSLock()

    static let missingToolsMessage =
        "Git is not available. Walkthrough Studio uses the git shipped with Apple's Command Line Tools; "
        + "install them with `xcode-select --install` (or install Xcode) and try again."

    /// The git binary `xcrun --find git` reports, cached per launch. Falls back
    /// to /usr/bin/git only when xcrun itself succeeded but printed nothing
    /// usable; when xcrun fails the Command Line Tools are missing and the
    /// error says so. Synchronous: call it from a background context.
    static func locateGit() throws -> URL {
        locateLock.lock()
        let cached = cachedGitURL
        locateLock.unlock()
        if let cached { return cached }

        let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        let result: Output
        do {
            result = try execute(
                executable: xcrun,
                arguments: ["--find", "git"],
                directory: nil,
                environment: baseEnvironment(),
                timeout: 60
            )
        } catch {
            throw StudioError(missingToolsMessage + " (xcrun did not run: \(error.localizedDescription))")
        }
        guard result.status == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw StudioError(missingToolsMessage + (detail.isEmpty ? "" : " (xcrun: \(detail))"))
        }

        var path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty || !FileManager.default.isExecutableFile(atPath: path) {
            path = "/usr/bin/git"
        }
        let url = URL(fileURLWithPath: path)
        locateLock.lock()
        cachedGitURL = url
        locateLock.unlock()
        return url
    }

    // MARK: Core runner

    /// Captured result of one child process.
    struct Output: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Run `git <args>` in `repo` (nil = inherit the current directory) and
    /// return stdout verbatim (not trimmed: `show` needs the exact bytes).
    /// Throws `StudioError` with the stderr tail on a non-zero exit.
    @discardableResult
    func run(_ args: [String], in repo: URL?, extraEnvironment: [String: String] = [:]) async throws -> String {
        let output = try await runCapturing(args, in: repo, extraEnvironment: extraEnvironment)
        guard output.status == 0 else {
            throw GitRunner.failure(args: args, output: output)
        }
        return output.stdout
    }

    /// Like `run` but returns the full `Output` without judging the exit status.
    func runCapturing(_ args: [String], in repo: URL?, extraEnvironment: [String: String] = [:]) async throws -> Output {
        let timeout = self.timeout
        var environment = GitRunner.baseEnvironment()
        for (key, value) in extraEnvironment { environment[key] = value }
        let env = environment
        return try await Task.detached(priority: .userInitiated) { () throws -> Output in
            let git = try GitRunner.locateGit()
            return try GitRunner.execute(
                executable: git,
                arguments: args,
                directory: repo,
                environment: env,
                timeout: timeout
            )
        }.value
    }

    /// Trimmed single-line convenience for `run`.
    private func runTrimmed(_ args: [String], in repo: URL?) async throws -> String {
        try await run(args, in: repo).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The environment every child gets: never block on a credential or
    /// terminal prompt, never take optional locks (so `status` in a user's
    /// repository does not rewrite their index), stable English messages.
    static func baseEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment["LC_ALL"] = "C"
        environment.removeValue(forKey: "GIT_ASKPASS")
        environment.removeValue(forKey: "SSH_ASKPASS")
        environment.removeValue(forKey: "GIT_TOKEN")
        return environment
    }

    /// A readable failure: the git subcommand, the exit status and the last
    /// lines of stderr (or stdout when stderr is empty).
    static func failure(args: [String], output: Output) -> StudioError {
        let command = "git " + args.joined(separator: " ")
        var detail = tail(output.stderr)
        if detail.isEmpty { detail = tail(output.stdout) }
        return StudioError("\(command) exited \(output.status)" + (detail.isEmpty ? "" : ": \(detail)"))
    }

    /// The last `maxLines` non-empty lines of `text`, capped in length.
    static func tail(_ text: String, maxLines: Int = 20, maxCharacters: Int = 2000) -> String {
        let lines = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let kept = lines.suffix(maxLines).joined(separator: "\n")
        if kept.count > maxCharacters {
            return String(kept.suffix(maxCharacters))
        }
        return kept
    }

    // MARK: Synchronous process plumbing (background threads only)

    /// One child process whose stderr (and, unless redirected, stdout) is
    /// drained on background queues while the caller waits with a deadline.
    private final class Child {
        let process = Process()
        private let finished = DispatchSemaphore(value: 0)
        private let drained = DispatchGroup()
        private let lock = NSLock()
        private var outData = Data()
        private var errData = Data()
        private var outPipe: Pipe?
        private let errPipe = Pipe()
        let label: String

        init(executable: URL, arguments: [String], directory: URL?, environment: [String: String], captureStdout: Bool) {
            label = executable.lastPathComponent + " " + arguments.prefix(3).joined(separator: " ")
            process.executableURL = executable
            process.arguments = arguments
            if let directory { process.currentDirectoryURL = directory }
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            if captureStdout {
                let pipe = Pipe()
                outPipe = pipe
                process.standardOutput = pipe
            }
            process.standardError = errPipe
            let finished = self.finished
            process.terminationHandler = { _ in finished.signal() }
        }

        /// Wire this child's stdout into `other`'s stdin (call before `start`).
        func pipeStdout(into other: Child) {
            let pipe = Pipe()
            outPipe = nil
            process.standardOutput = pipe
            other.process.standardInput = pipe
        }

        func start() throws {
            do {
                try process.run()
            } catch {
                throw StudioError("could not launch \(label): \(error.localizedDescription)")
            }
            if let outPipe {
                drain(outPipe) { [self] data in
                    self.lock.lock(); self.outData = data; self.lock.unlock()
                }
            }
            drain(errPipe) { [self] data in
                self.lock.lock(); self.errData = data; self.lock.unlock()
            }
        }

        private func drain(_ pipe: Pipe, _ store: @escaping (Data) -> Void) {
            drained.enter()
            let handle = pipe.fileHandleForReading
            let group = drained
            DispatchQueue.global(qos: .utility).async {
                let data = handle.readDataToEndOfFile()
                store(data)
                group.leave()
            }
        }

        /// Wait until the child exits or `deadline` passes. On timeout the
        /// child is killed and false is returned. Either way the pipes are
        /// fully drained on return.
        func wait(until deadline: DispatchTime) -> Bool {
            let completed = finished.wait(timeout: deadline) == .success
            if !completed {
                killNow()
                _ = finished.wait(timeout: .now() + 5)
            }
            // Bounded: a grandchild (git-remote-https) that inherited the pipe
            // may outlive a killed git for a moment; never hang on it.
            _ = drained.wait(timeout: .now() + 30)
            return completed
        }

        func killNow() {
            guard process.isRunning else { return }
            kill(process.processIdentifier, SIGKILL)
        }

        var stdoutText: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: outData, as: UTF8.self)
        }

        var stderrText: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: errData, as: UTF8.self)
        }
    }

    /// Run one process to completion (or kill it at `timeout`). Blocking:
    /// only ever called from a detached task or a background queue.
    private static func execute(
        executable: URL,
        arguments: [String],
        directory: URL?,
        environment: [String: String],
        timeout: TimeInterval
    ) throws -> Output {
        let child = Child(
            executable: executable, arguments: arguments, directory: directory,
            environment: environment, captureStdout: true
        )
        try child.start()
        let deadline = DispatchTime.now() + timeout
        guard child.wait(until: deadline) else {
            throw StudioError("\(child.label) timed out after \(Int(timeout)) s and was killed")
        }
        return Output(status: child.process.terminationStatus, stdout: child.stdoutText, stderr: child.stderrText)
    }

    // MARK: Queries

    /// Full 40-character sha of `ref` (a branch, tag, sha or sha prefix).
    func revParse(_ ref: String, in repo: URL) async throws -> String {
        let sha = try await runTrimmed(["rev-parse", "--verify", ref + "^{commit}"], in: repo)
        guard sha.count == 40 else {
            throw StudioError("git rev-parse \(ref): unexpected output \"\(sha)\"")
        }
        return sha
    }

    func isShallow(repo: URL) async throws -> Bool {
        let text = try await runTrimmed(["rev-parse", "--is-shallow-repository"], in: repo)
        return text == "true"
    }

    /// True when `git status --porcelain` lists anything (modified, staged
    /// or untracked): none of it would be part of an archive of HEAD.
    func isDirty(repo: URL) async throws -> Bool {
        let text = try await runTrimmed(["status", "--porcelain"], in: repo)
        return !text.isEmpty
    }

    /// The file contents at `sha:path`, verbatim.
    func show(sha: String, path: String, repo: URL) async throws -> String {
        try await run(["show", sha + ":" + path], in: repo)
    }

    /// Number of lines in the file at `sha:path` (a final line without a
    /// trailing newline counts as a line; the empty file has 0).
    func lineCount(sha: String, path: String, repo: URL) async throws -> Int {
        GitRunner.countLines(try await show(sha: sha, path: path, repo: repo))
    }

    /// The line-counting rule `lineCount` uses (shared with the probe).
    static func countLines(_ text: String) -> Int {
        if text.isEmpty { return 0 }
        var count = 0
        for character in text.utf8 where character == UInt8(ascii: "\n") { count += 1 }
        if text.utf8.last != UInt8(ascii: "\n") { count += 1 }
        return count
    }

    /// Commits reaching `ref` (newest first), optionally only those touching
    /// `path`, at most `limit` (0 = no limit).
    func log(path: String?, limit: Int, repo: URL, ref: String = "HEAD") async throws -> [GitCommit] {
        // %x1f = ASCII unit separator between fields; %x1e = record separator
        // so a subject containing anything odd cannot split a record.
        var args = ["log", "--no-color", "--format=%H%x1f%an%x1f%aI%x1f%s%x1e", "--no-show-signature"]
        if limit > 0 { args.append("-n"); args.append(String(limit)) }
        args.append(ref)
        if let path { args.append("--"); args.append(path) }
        let text = try await run(args, in: repo)

        var commits: [GitCommit] = []
        for record in text.split(separator: "\u{1e}", omittingEmptySubsequences: true) {
            let fields = record.split(separator: "\u{1f}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 4 else { continue }
            let sha = fields[0].trimmingCharacters(in: .whitespacesAndNewlines)
            guard sha.count == 40 else { continue }
            commits.append(GitCommit(
                sha: sha,
                author: fields[1],
                dateISO: fields[2],
                subject: fields[3].trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }
        return commits
    }

    /// Blame of `path` lines `startLine...endLine` (1-based, inclusive) at `ref`.
    func blame(path: String, startLine: Int, endLine: Int, repo: URL, ref: String = "HEAD") async throws -> [GitBlameLine] {
        guard startLine >= 1, endLine >= startLine else {
            throw StudioError("git blame \(path): invalid line range \(startLine)-\(endLine)")
        }
        let text = try await run(
            ["blame", "--line-porcelain", "-L", "\(startLine),\(endLine)", ref, "--", path],
            in: repo
        )
        return GitRunner.parseLinePorcelain(text)
    }

    /// Parse `git blame --line-porcelain`: each line starts with a header
    /// "<sha40> <origLine> <finalLine>[ <count>]", then "key value" lines,
    /// then the content line prefixed by a tab.
    static func parseLinePorcelain(_ text: String) -> [GitBlameLine] {
        var result: [GitBlameLine] = []
        var sha = ""
        var finalLine = 0
        var author = ""
        var authorTime: Int?
        var authorTZ = "+0000"
        var inEntry = false

        func flush() {
            guard inEntry, !sha.isEmpty else { return }
            result.append(GitBlameLine(
                line: finalLine,
                author: author,
                sha: sha,
                dateISO: isoDate(epoch: authorTime, tz: authorTZ)
            ))
            inEntry = false
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("\t") {
                // Content line closes the entry.
                flush()
                continue
            }
            if !inEntry {
                let parts = line.split(separator: " ")
                if parts.count >= 3, parts[0].count == 40, isHex(parts[0]), let finalLineNumber = Int(parts[2]) {
                    sha = String(parts[0])
                    finalLine = finalLineNumber
                    author = ""
                    authorTime = nil
                    authorTZ = "+0000"
                    inEntry = true
                }
                continue
            }
            if line.hasPrefix("author ") {
                author = String(line.dropFirst("author ".count))
            } else if line.hasPrefix("author-time ") {
                authorTime = Int(line.dropFirst("author-time ".count).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("author-tz ") {
                authorTZ = line.dropFirst("author-tz ".count).trimmingCharacters(in: .whitespaces)
            }
        }
        flush()
        return result
    }

    private static func isHex(_ s: Substring) -> Bool {
        for c in s.utf8 {
            let isDigit = c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")
            let isLower = c >= UInt8(ascii: "a") && c <= UInt8(ascii: "f")
            let isUpper = c >= UInt8(ascii: "A") && c <= UInt8(ascii: "F")
            if !(isDigit || isLower || isUpper) { return false }
        }
        return !s.isEmpty
    }

    /// "1735984800" + "+0000" -> "2025-01-04T10:00:00Z"; other zones keep
    /// their offset ("+01:00"). Unknown epoch -> "".
    static func isoDate(epoch: Int?, tz: String) -> String {
        guard let epoch else { return "" }
        var seconds = 0
        let digits = tz.filter { $0.isNumber }
        if digits.count == 4, let hh = Int(digits.prefix(2)), let mm = Int(digits.suffix(2)) {
            seconds = hh * 3600 + mm * 60
            if tz.hasPrefix("-") { seconds = -seconds }
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: seconds) ?? TimeZone(secondsFromGMT: 0)!
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(epoch)))
    }

    /// Every file path under `path` (nil = whole tree) at `sha`, recursively,
    /// in git's own order.
    func lsTree(sha: String, path: String? = nil, repo: URL) async throws -> [String] {
        var args = ["ls-tree", "-r", "--name-only", "-z", sha]
        if let path, !path.isEmpty { args.append("--"); args.append(path) }
        let text = try await run(args, in: repo)
        return text.split(separator: "\u{0}", omittingEmptySubsequences: true).map(String.init)
    }

    /// Paths of every worktree registered with `repo` (the main one first).
    func worktreeList(repo: URL) async throws -> [String] {
        let text = try await run(["worktree", "list", "--porcelain"], in: repo)
        var paths: [String] = []
        for line in text.split(separator: "\n") where line.hasPrefix("worktree ") {
            paths.append(String(line.dropFirst("worktree ".count)))
        }
        return paths
    }

    // MARK: Clone and fetch (token aware)

    /// `git clone <url> <dir>` with full history. With a token the child gets
    /// a GIT_ASKPASS helper that answers git's prompts from `GIT_TOKEN`, set
    /// only in the child's environment; the helper is deleted afterwards and
    /// the token never appears in errors.
    func clone(url: String, to dir: URL, token: String?) async throws {
        try FileManager.default.createDirectory(
            at: dir.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try await runWithToken(
            ["-c", "credential.helper=", "clone", "--no-local", "--", url, dir.path],
            in: nil, token: token
        )
    }

    /// `git fetch` inside an existing clone (used when a package is reopened
    /// and `repo-git/` is already there).
    func fetch(repo: URL, token: String?) async throws {
        try await runWithToken(
            ["-c", "credential.helper=", "fetch", "--tags", "--prune", "origin"],
            in: repo, token: token
        )
    }

    private func runWithToken(_ args: [String], in repo: URL?, token: String?) async throws {
        guard let token, !token.isEmpty else {
            try await run(args, in: repo)
            return
        }
        let helper = try GitRunner.writeAskpassHelper()
        defer { try? FileManager.default.removeItem(at: helper.deletingLastPathComponent()) }
        let extra: [String: String] = [
            "GIT_ASKPASS": helper.path,
            "GIT_TOKEN": token,
            // git also honours SSH_ASKPASS for https prompts on some setups;
            // point it at the same helper so nothing falls back to a terminal.
            "SSH_ASKPASS": helper.path,
        ]
        let output = try await runCapturing(args, in: repo, extraEnvironment: extra)
        guard output.status == 0 else {
            let scrubbed = Output(
                status: output.status,
                stdout: output.stdout.replacingOccurrences(of: token, with: "<token>"),
                stderr: output.stderr.replacingOccurrences(of: token, with: "<token>")
            )
            throw GitRunner.failure(args: args, output: scrubbed)
        }
    }

    /// Writes the GIT_ASKPASS helper into a fresh 0700 temp directory and
    /// returns the script URL. The script echoes a fixed username for the
    /// username prompt and `$GIT_TOKEN` for everything else; the token itself
    /// is not in the file.
    static func writeAskpassHelper() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("walkthrough-askpass-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let script = dir.appendingPathComponent("askpass.sh")
        let body = """
        #!/bin/sh
        # Walkthrough Studio GIT_ASKPASS helper. Answers git's credential prompts
        # from the GIT_TOKEN environment variable; the token is never stored here.
        case "$1" in
          *sername*) printf '%s\\n' "x-access-token" ;;
          *) printf '%s\\n' "$GIT_TOKEN" ;;
        esac

        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }

    /// True when a failed clone/fetch looks like an authentication problem
    /// (the notice for it belongs to RepoAcquisition).
    static func looksLikeAuthFailure(_ message: String) -> Bool {
        let lower = message.lowercased()
        return lower.contains("authentication failed")
            || lower.contains("could not read username")
            || lower.contains("could not read password")
            || lower.contains("terminal prompts disabled")
            || lower.contains("repository not found")
            || lower.contains("http 401")
            || lower.contains("http 403")
            || lower.contains("permission denied")
    }

    // MARK: Archive

    /// `git archive <sha> | tar -x` into `dir`. Two processes joined by a Pipe;
    /// both stderr streams are captured and either non-zero exit throws.
    /// Unlike a worktree this registers nothing in the source repository.
    func archive(sha: String, from repo: URL, into dir: URL) async throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let timeout = self.timeout
        let environment = GitRunner.baseEnvironment()
        try await Task.detached(priority: .userInitiated) { () throws -> Void in
            let git = try GitRunner.locateGit()
            let producer = Child(
                executable: git,
                arguments: ["archive", "--format=tar", sha],
                directory: repo, environment: environment, captureStdout: false
            )
            let consumer = Child(
                executable: URL(fileURLWithPath: "/usr/bin/tar"),
                arguments: ["-x", "-f", "-", "-C", dir.path],
                directory: nil, environment: environment, captureStdout: true
            )
            producer.pipeStdout(into: consumer)

            // Start the reader first so the writer never blocks on a full pipe
            // with nobody draining it.
            try consumer.start()
            do {
                try producer.start()
            } catch {
                consumer.killNow()
                _ = consumer.wait(until: .now() + 5)
                throw error
            }

            let deadline = DispatchTime.now() + timeout
            let producerDone = producer.wait(until: deadline)
            let consumerDone = consumer.wait(until: deadline)
            guard producerDone, consumerDone else {
                producer.killNow()
                consumer.killNow()
                throw StudioError("git archive \(sha) | tar -x timed out after \(Int(timeout)) s and was killed")
            }
            if producer.process.terminationStatus != 0 {
                throw GitRunner.failure(
                    args: ["archive", "--format=tar", sha],
                    output: Output(status: producer.process.terminationStatus, stdout: "", stderr: producer.stderrText)
                )
            }
            if consumer.process.terminationStatus != 0 {
                let detail = GitRunner.tail(consumer.stderrText)
                throw StudioError("tar -x (git archive \(sha)) exited \(consumer.process.terminationStatus)"
                                  + (detail.isEmpty ? "" : ": \(detail)"))
            }
            // Some tar builds materialise git's pax global header as a file.
            let paxHeader = dir.appendingPathComponent("pax_global_header")
            if FileManager.default.fileExists(atPath: paxHeader.path) {
                try? FileManager.default.removeItem(at: paxHeader)
            }
        }.value
    }
}
