// SelfTestOnboarding — Onboard to a Codebase, milestone M1.
//
// Headless selftest runner for the onboarding feature:
//   WalkthroughStudio --selftest-onboarding <fixtureRepo> <outDir> [--probe <name>]
// The fixture repository comes from scripts/make-fixture-repo.sh. Probes live in
// `extension SelfTest`, take an `OnboardingProbeContext`, print
// "selftest: <name> OK (<detail>)" and throw `StudioError("<name>: <observed>")`.
// Later milestones add probes to the list in `runOnboarding` (ARCHITECTURE.md
// section 9 and 15.6).
import Foundation
import AVFoundation
import CoreGraphics

/// Everything a probe needs. `scratch` is a fresh temp directory per run.
struct OnboardingProbeContext {
    let fixtureRepo: URL
    let outDir: URL
    let scratch: URL
}

/// Shape of every onboarding probe (main-actor, like `SelfTest` itself).
typealias OnboardingProbe = @MainActor (OnboardingProbeContext) async throws -> Void

/// Facts baked into scripts/make-fixture-repo.sh (deterministic dates/authors).
enum FixtureRepoFacts {
    static let headSHA = "fb63e78744ce026d810547afbb62c0a08ce2040a"
    static let commitCount = 12
    static let authorCounts: [String: Int] = ["Ada Lovelace": 8, "Grace Hopper": 4]
    static let hotspotPath = "src/repo/orders_repo.py"
    static let hotspotCommitCount = 6
    static let untouchedDeployDate = "2025-01-04"
    static let files: [String] = [
        "README.md",
        "requirements.txt",
        "src/api/orders_handler.py",
        "src/auth/authz.py",
        "src/service/orders.py",
        "src/repo/orders_repo.py",
        "db/schema.sql",
        "db/migrations/001_orders.sql",
        "db/migrations/002_split_addresses.sql",
        ".github/workflows/ci.yml",
        "deploy/deploy.sh",
        "tests/test_orders.sh",
        "config/settings.example",
        "templates/email.tmpl",
        "vendor/generated/client_pb2.py",
    ]
}

extension SelfTest {

    // MARK: Runner

    /// Run every onboarding probe (or only the one named by `--probe`).
    static func runOnboarding(fixtureRepo: URL, outDir: URL, only: String?) async throws {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("onboarding-selftest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let ctx = OnboardingProbeContext(fixtureRepo: fixtureRepo, outDir: outDir, scratch: scratch)

        // Order matters: later probes may rely on earlier ones having produced
        // files in outDir (e.g. the stills mp4).
        let all: [(name: String, run: OnboardingProbe)] = [
            ("fixtureRepoProbe", { probeCtx in try await Self.fixtureRepoProbe(probeCtx) }),
            ("stillsWriterProbe", { probeCtx in try await Self.stillsWriterProbe(probeCtx) }),
            ("anchorRoundTripProbe", { probeCtx in try await Self.anchorRoundTripProbe(probeCtx) }),
            ("manifestRoundTripProbe", { probeCtx in try await Self.manifestRoundTripProbe(probeCtx) }),
            ("packageStoreProbe", { probeCtx in try await Self.packageStoreProbe(probeCtx) }),
            ("gitRunnerProbe", { probeCtx in try await Self.gitRunnerProbe(probeCtx) }),
            ("packetValidateProbe", { probeCtx in try await Self.packetValidateProbe(probeCtx) }),
            ("fixturePacketProbe", { probeCtx in try await Self.fixturePacketProbe(probeCtx) }),
            ("markdownLiteProbe", { probeCtx in try await Self.markdownLiteProbe(probeCtx) }),
            ("projectorParityProbe", { probeCtx in try await Self.projectorParityProbe(probeCtx) }),
        ]

        let selected: [(name: String, run: OnboardingProbe)]
        if let only {
            selected = all.filter { $0.name == only }
            if selected.isEmpty {
                let names = all.map { $0.name }.joined(separator: ", ")
                throw StudioError("unknown probe \"\(only)\" — known probes: \(names)")
            }
        } else {
            selected = all
        }

        print("selftest-onboarding: fixture \(fixtureRepo.path)")
        print("selftest-onboarding: out \(outDir.path)")
        print("selftest-onboarding: scratch \(scratch.path)")
        for (index, probe) in selected.enumerated() {
            print("selftest-onboarding: [\(index + 1)/\(selected.count)] \(probe.name) ...")
            do {
                try await probe.run(ctx)
            } catch {
                print("selftest-onboarding: \(probe.name) FAILED — scratch kept at \(scratch.path)")
                throw error
            }
        }
        try? FileManager.default.removeItem(at: scratch)
        print("selftest-onboarding: \(selected.count) probe(s) passed")
    }

    // MARK: fixtureRepoProbe

    /// The fixture repo is exactly what make-fixture-repo.sh promises. Every
    /// later probe (git mining, hotspots, secrets, staleness) assumes these facts.
    static func fixtureRepoProbe(_ ctx: OnboardingProbeContext) async throws {
        let repo = ctx.fixtureRepo
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repo.path, isDirectory: &isDir), isDir.boolValue else {
            throw StudioError("fixtureRepoProbe: \(repo.path) is not a directory (run scripts/make-fixture-repo.sh)")
        }

        let head = try SelfTestSupport.runGit(["rev-parse", "HEAD"], in: repo)
        guard head == FixtureRepoFacts.headSHA else {
            throw StudioError("fixtureRepoProbe: HEAD is \(head), expected \(FixtureRepoFacts.headSHA) — fixture not deterministic or stale")
        }

        let countText = try SelfTestSupport.runGit(["rev-list", "--count", "HEAD"], in: repo)
        guard Int(countText) == FixtureRepoFacts.commitCount else {
            throw StudioError("fixtureRepoProbe: rev-list --count HEAD is \(countText), expected \(FixtureRepoFacts.commitCount)")
        }

        // shortlog lines look like "     8\tAda Lovelace".
        let shortlog = try SelfTestSupport.runGit(["shortlog", "-sn", "--no-merges", "HEAD"], in: repo)
        var seen: [String: Int] = [:]
        for line in shortlog.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            guard let first = parts.first, let count = Int(first) else { continue }
            let name = parts.dropFirst().joined(separator: " ")
            seen[name] = count
        }
        for (author, expected) in FixtureRepoFacts.authorCounts {
            guard seen[author] == expected else {
                let observed = seen[author].map { String($0) } ?? "missing"
                throw StudioError("fixtureRepoProbe: shortlog for \(author) is \(observed), expected \(expected) (shortlog: \(shortlog.replacingOccurrences(of: "\n", with: " | ")))")
            }
        }

        var missing: [String] = []
        for relative in FixtureRepoFacts.files {
            if !FileManager.default.fileExists(atPath: repo.appendingPathComponent(relative).path) {
                missing.append(relative)
            }
        }
        guard missing.isEmpty else {
            throw StudioError("fixtureRepoProbe: missing files \(missing.joined(separator: ", "))")
        }

        let schema = try String(contentsOf: repo.appendingPathComponent("db/schema.sql"), encoding: .utf8)
        guard schema.contains("email") else {
            throw StudioError("fixtureRepoProbe: db/schema.sql does not mention \"email\"")
        }
        let requirements = try String(contentsOf: repo.appendingPathComponent("requirements.txt"), encoding: .utf8)
        guard requirements.contains("requests==2.19.0") else {
            throw StudioError("fixtureRepoProbe: requirements.txt does not pin requests==2.19.0")
        }
        let template = try String(contentsOf: repo.appendingPathComponent("templates/email.tmpl"), encoding: .utf8)
        guard template.contains("{{ user.name }}") else {
            throw StudioError("fixtureRepoProbe: templates/email.tmpl lacks the {{ user.name }} placeholder")
        }

        let hotspotCount = try SelfTestSupport.runGit(
            ["rev-list", "--count", "HEAD", "--", FixtureRepoFacts.hotspotPath], in: repo
        )
        guard Int(hotspotCount) == FixtureRepoFacts.hotspotCommitCount else {
            throw StudioError("fixtureRepoProbe: \(FixtureRepoFacts.hotspotPath) touched in \(hotspotCount) commits, expected \(FixtureRepoFacts.hotspotCommitCount)")
        }
        let deployDate = try SelfTestSupport.runGit(
            ["log", "-1", "--format=%as", "--", "deploy/deploy.sh"], in: repo
        )
        guard deployDate == FixtureRepoFacts.untouchedDeployDate else {
            throw StudioError("fixtureRepoProbe: deploy/deploy.sh last touched \(deployDate), expected \(FixtureRepoFacts.untouchedDeployDate)")
        }

        // The fixture's own test must run and pass (the build/test opt-in path
        // will shell out to it later).
        let test = try SelfTestSupport.runProcess("/bin/bash", ["tests/test_orders.sh"], in: repo)
        guard test.status == 0 else {
            throw StudioError("fixtureRepoProbe: tests/test_orders.sh exited \(test.status): \(test.stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        guard test.stdout.contains("PASS") else {
            throw StudioError("fixtureRepoProbe: tests/test_orders.sh did not print PASS (stdout: \(test.stdout.trimmingCharacters(in: .whitespacesAndNewlines)))")
        }

        print("selftest: fixtureRepoProbe OK (HEAD \(head.prefix(7)), \(countText) commits, Ada 8 / Grace 4, \(FixtureRepoFacts.files.count) files, tests PASS)")
    }

    // MARK: stillsWriterProbe

    /// Three solid stills (red 2 s, green 3 s, blue 4 s) become a 10.0 s mp4
    /// (9 s of holds + 1 s trailing); frames at known times carry the expected
    /// colour; and the existing narrated-video muxer accepts the stills track
    /// as if it were a recording with a contiguous narration track.
    static func stillsWriterProbe(_ ctx: OnboardingProbeContext) async throws {
        let size = CGSize(width: 1920, height: 1080)
        let holds: [Double] = [2, 3, 4]
        let frames: [(image: CGImage, hold: Double)] = [
            (StillsVideoWriter.solidFrame(color: (r: 1, g: 0, b: 0), size: size), holds[0]),
            (StillsVideoWriter.solidFrame(color: (r: 0, g: 1, b: 0), size: size), holds[1]),
            (StillsVideoWriter.solidFrame(color: (r: 0, g: 0, b: 1), size: size), holds[2]),
        ]
        let stillsURL = ctx.outDir.appendingPathComponent("stills-probe.mp4")
        try await StillsVideoWriter.write(frames: frames, size: size, fps: 30, to: stillsURL)

        let holdSum = holds.reduce(0, +)                      // 9.0
        let expectedDuration = holdSum + StillsVideoWriter.trailingHold // 10.0
        let duration = try await AVURLAsset(url: stillsURL).load(.duration).seconds
        guard abs(duration - expectedDuration) < 0.1 else {
            throw StudioError(String(format: "stillsWriterProbe: stills-probe.mp4 is %.3fs, expected %.1fs", duration, expectedDuration))
        }

        // (time, expected dominant channel index: 0 = r, 1 = g, 2 = b)
        let expectations: [(time: Double, channel: Int, label: String)] = [
            (1.0, 0, "red"),
            (4.25, 1, "green"),
            (8.0, 2, "blue"),
            (9.9, 2, "blue (trailing hold)"),
        ]
        for expectation in expectations {
            let frame = try await VideoService.extractFrame(videoURL: stillsURL, at: expectation.time)
            guard frame.width == 1920, frame.height == 1080 else {
                throw StudioError("stillsWriterProbe: frame at \(expectation.time)s is \(frame.width)x\(frame.height), expected 1920x1080")
            }
            let rgb = SelfTestSupport.pixel(in: frame, x: 960, y: 540)
            guard dominantChannel(rgb) == expectation.channel else {
                throw StudioError(String(format: "stillsWriterProbe: frame at %.2fs is rgb(%d,%d,%d), expected ", expectation.time, rgb.r, rgb.g, rgb.b) + expectation.label)
            }
        }

        // Feed the stills through the real muxer: one segment per hold, the
        // tone narration on every segment (like the walkthrough selftest) so a
        // dropped post-gap clip would show up as a short audio track.
        let toneURL = ctx.scratch.appendingPathComponent("tone.wav")
        try SelfTestSupport.sineWAV(seconds: 1.5).write(to: toneURL)
        var segments: [VideoService.ExportSegment] = []
        var start = 0.0
        for hold in holds {
            segments.append(VideoService.ExportSegment(sourceStart: start, duration: hold, narrationURL: toneURL))
            start += hold
        }
        let narratedURL = ctx.outDir.appendingPathComponent("stills-probe-narrated.mp4")
        try await VideoService.assembleNarratedVideo(
            videoURL: stillsURL,
            segments: segments,
            keepOriginalAudio: false,
            outputURL: narratedURL
        )

        let narratedAsset = AVURLAsset(url: narratedURL)
        let narratedDuration = try await narratedAsset.load(.duration).seconds
        guard abs(narratedDuration - holdSum) < 0.5 else {
            throw StudioError(String(format: "stillsWriterProbe: narrated output is %.2fs, expected ~%.1fs (segment clamp triggered?)", narratedDuration, holdSum))
        }
        guard let audioTrack = try await narratedAsset.loadTracks(withMediaType: .audio).first else {
            throw StudioError("stillsWriterProbe: narrated output has no audio track")
        }
        let audioRange = try await audioTrack.load(.timeRange)
        let audioEnd = audioRange.start.seconds + audioRange.duration.seconds
        let lastSegmentStart = segments.map(\.sourceStart).max() ?? 0
        guard audioEnd > lastSegmentStart + 0.3 else {
            throw StudioError(String(format: "stillsWriterProbe: narration track ends at %.2fs but the last segment starts at %.2fs — post-gap clips dropped", audioEnd, lastSegmentStart))
        }
        // The sparse stills track must survive the export re-encode.
        let lateFrame = try await VideoService.extractFrame(videoURL: narratedURL, at: 7.0)
        let lateRGB = SelfTestSupport.pixel(in: lateFrame, x: 960, y: 540)
        guard dominantChannel(lateRGB) == 2 else {
            throw StudioError(String(format: "stillsWriterProbe: narrated frame at 7.0s is rgb(%d,%d,%d), expected blue", lateRGB.r, lateRGB.g, lateRGB.b))
        }

        print("selftest: stillsWriterProbe OK (\(String(format: "%.2f", duration))s stills, 4 frames colour-checked; narrated \(String(format: "%.2f", narratedDuration))s, audio reaches \(String(format: "%.2f", audioEnd))s)")
    }

    /// Index of the dominant channel (0 r, 1 g, 2 b) when it is clearly
    /// dominant (> 170 with the others < 90); -1 otherwise. Tolerant of the
    /// small shifts H.264 colour conversion introduces.
    nonisolated static func dominantChannel(_ rgb: (r: Int, g: Int, b: Int)) -> Int {
        let values = [rgb.r, rgb.g, rgb.b]
        for index in 0..<3 {
            let others = values.enumerated().filter { $0.offset != index }.map(\.element)
            if values[index] > 170, others.allSatisfy({ $0 < 90 }) {
                return index
            }
        }
        return -1
    }
}
