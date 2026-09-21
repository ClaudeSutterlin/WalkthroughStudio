// SelfTestOnboarding+Views — Onboard to a Codebase, milestone M4.
//
//   onboardSheetProbe — the pre-run sheet renders under DARK appearance and stays
//     brand cream, and its validation rejects a non-git target with a readable message.
//   playerStageProbe  — the three-pane window and the AVPlayerView stage instantiate
//     on a real package without crashing, and the stage restores the video at the
//     same t after a trip into the code.
//
// These two share `snapshot(_:)`. SelfTest.swift already carries four copies of the
// offscreen harness (CLAUDE.md lists it as duplication to consolidate opportunistically);
// this is the consolidated one, and the older four can move onto it when they are next
// touched.

import SwiftUI
import AppKit
import AVFoundation

extension SelfTest {

    /// Render a SwiftUI view offscreen and return its pixels.
    ///
    /// Dark appearance by default: every branded surface pins the light colour scheme,
    /// and the failure that keeps happening is one that forgot to, which only shows up
    /// for a reader whose Mac is in dark mode.
    static func snapshot<V: View>(_ view: V, size: CGSize, named name: String, into outDir: URL,
                                  appearance: NSAppearance.Name = .darkAqua,
                                  settle: Double = 0.4) async throws -> CGImage {
        let hosting = NSHostingView(rootView: view)
        hosting.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw StudioError("\(name): could not snapshot the view")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        window.contentView = nil

        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: outDir.appendingPathComponent("\(name).png"))
        }
        guard let image = rep.cgImage else {
            throw StudioError("\(name): the snapshot has no image")
        }
        return image
    }

    /// Cream is 0xFFFBF5; anything near it passes, a dark-mode window background does not.
    static func assertBrandCream(_ image: CGImage, x: Int, y: Int, what: String) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        let cx = min(max(0, x), rep.pixelsWide - 1)
        let cy = min(max(0, y), rep.pixelsHigh - 1)
        guard let colour = rep.colorAt(x: cx, y: cy) else {
            throw StudioError("\(what): no pixel at \(x),\(y)")
        }
        let r = Int(colour.redComponent * 255), g = Int(colour.greenComponent * 255)
        let b = Int(colour.blueComponent * 255)
        guard r > 220, g > 210, b > 190 else {
            throw StudioError(String(format: "%@ is rgb(%d,%d,%d) at %d,%d under dark appearance "
                                     + "— expected brand cream", what, r, g, b, x, y))
        }
    }

    // MARK: - onboardSheetProbe

    static func onboardSheetProbe(_ ctx: OnboardingProbeContext) async throws {
        let vm = OnboardingViewModel()
        let image = try await SelfTest.snapshot(OnboardSheet(vm: vm), size: CGSize(width: 640, height: 720),
                                                named: "onboard-sheet", into: ctx.outDir)
        // `colorAt` is top-left origin (CLAUDE.md landmine 6): 12,12 is the top-left corner.
        try SelfTest.assertBrandCream(image, x: 12, y: 12, what: "the onboard sheet's corner")

        // The window before a package is open is the other thing a first run sees.
        let empty = try await SelfTest.snapshot(EmptyPackageView(vm: vm),
                                                size: CGSize(width: 900, height: 560),
                                                named: "onboard-empty", into: ctx.outDir)
        try SelfTest.assertBrandCream(empty, x: 12, y: 12, what: "the empty-package view's corner")

        // ON-1.1: a non-git target is rejected with a message, not accepted silently.
        let notARepo = ctx.scratch.appendingPathComponent("not-a-repo", isDirectory: true)
        try FileManager.default.createDirectory(at: notARepo, withIntermediateDirectories: true)
        guard let complaint = OnboardSheetValidation.problem(
                packet: notARepo.path, repo: notARepo.path, output: ctx.outDir.path) else {
            throw StudioError("onboardSheetProbe: a folder with no packet.json was accepted")
        }
        guard complaint.contains("packet.json") else {
            throw StudioError("onboardSheetProbe: the complaint about a non-packet folder was "
                              + "\"\(complaint)\", which does not say what is missing")
        }
        guard OnboardSheetValidation.problem(packet: "", repo: "", output: "") != nil else {
            throw StudioError("onboardSheetProbe: an empty form was accepted")
        }
        guard let gitComplaint = OnboardSheetValidation.repositoryProblem(
                repo: notARepo.path, output: ctx.outDir.path), gitComplaint.contains(".git") else {
            throw StudioError("onboardSheetProbe: a folder that is not a git clone was accepted "
                              + "as a repository, or the refusal did not say why")
        }
        // The fixture packet with the fixture repo is the case that must pass.
        let packet = try SelfTest.fixturePacketURL()
        if let wrong = OnboardSheetValidation.problem(packet: packet.path, repo: ctx.fixtureRepo.path,
                                                     output: ctx.outDir.path) {
            throw StudioError("onboardSheetProbe: the fixture packet and repo were rejected: \(wrong)")
        }
        print("selftest: onboardSheetProbe OK (cream under dark appearance; a non-git target is "
              + "refused by name, the fixture packet is accepted)")
    }

    // MARK: - playerStageProbe

    static func playerStageProbe(_ ctx: OnboardingProbeContext) async throws {
        let root = SelfTest.fixturePackageURL(ctx)
        guard FileManager.default.fileExists(atPath: root.path) else {
            throw StudioError("playerStageProbe: run fixturePackageProbe first — \(root.path) is not there")
        }
        let vm = OnboardingViewModel()
        await vm.open(packageAt: root)
        guard vm.isLoaded else {
            throw StudioError("playerStageProbe: the package did not open: "
                              + (vm.notices.first?.message ?? "no notice"))
        }
        guard vm.items.count == vm.hub.items.count + 1, vm.items.first?.kind == "video" else {
            throw StudioError("playerStageProbe: the navigator shows \(vm.items.count) items for "
                              + "\(vm.hub.items.count) projected plus one video, starting with "
                              + "\(vm.items.first?.kind ?? "nothing")")
        }
        guard vm.items.map({ $0.order }) == Array(1...vm.items.count) else {
            throw StudioError("playerStageProbe: the reading order is not numbered 1..n")
        }

        // The player: AVPlayerView, not SwiftUI's VideoPlayer, which SIGABRTs at first
        // render on this SDK. Instantiating it here is the point of the probe.
        await vm.play(videoID: FixturePackage.videoID)
        vm.player.pause()
        guard case .video(let id) = vm.stage, id == FixturePackage.videoID else {
            throw StudioError("playerStageProbe: the stage did not become the video")
        }
        guard vm.transcript.segments.count >= 8, !vm.coderefs.intervals.isEmpty else {
            throw StudioError("playerStageProbe: the video's timing files did not load")
        }

        // ON-8.7: clicking into code docks the player, and Back returns to the same t.
        let codeInterval = vm.coderefs.intervals.first { $0.sceneType == "code" }
        guard let codeInterval, let anchor = codeInterval.primaryAnchor else {
            throw StudioError("playerStageProbe: the fixture video has no code shot to click")
        }
        let moment = (codeInterval.start + codeInterval.end) / 2
        vm.seek(to: moment)
        vm.open(anchor: anchor)
        guard case .hub = vm.stage else {
            throw StudioError("playerStageProbe: a code chip did not move the stage to the hub")
        }
        guard vm.pendingAnchor == anchor else {
            throw StudioError("playerStageProbe: the hub was not asked to open \(anchor)")
        }
        vm.backToVideo()
        guard case .video = vm.stage else {
            throw StudioError("playerStageProbe: Back to video did not restore the player")
        }
        guard abs(vm.clock.t - moment) < 0.5 else {
            throw StudioError(String(format: "playerStageProbe: Back to video returned at %.2fs, "
                                     + "not the %.2fs the viewer left", vm.clock.t, moment))
        }

        // The clock resolves what is on screen at that moment.
        guard vm.clock.interval?.shotId == codeInterval.shotId else {
            throw StudioError("playerStageProbe: at \(moment)s the companion card shows "
                              + "\(vm.clock.interval?.shotId ?? "nothing"), not \(codeInterval.shotId)")
        }

        // Chapter stepping, which the strip and `[` `]` share.
        vm.seek(to: 0)
        vm.step(chapters: 1)
        guard let second = vm.transcript.chapters.dropFirst().first,
              abs(vm.clock.t - second.start) < 0.01 else {
            throw StudioError("playerStageProbe: stepping forward a chapter landed at \(vm.clock.t)")
        }

        // A bookmark records the moment and the anchor on screen (ON-9.5).
        vm.seek(to: moment)
        vm.addBookmark(note: "why is this a string comparison?")
        guard let bookmark = vm.bookmarks.last, bookmark.anchor == anchor,
              abs(bookmark.t - moment) < 0.5 else {
            throw StudioError("playerStageProbe: the bookmark did not record the moment and its anchor")
        }
        guard let store = vm.store, store.exists("review/bookmarks.json") else {
            throw StudioError("playerStageProbe: the bookmark was not persisted")
        }

        // And the whole window renders, cream, under dark appearance.
        let image = try await SelfTest.snapshot(OnboardingRootView(),
                                                size: CGSize(width: 1280, height: 800),
                                                named: "onboarding-window", into: ctx.outDir)
        try SelfTest.assertBrandCream(image, x: 12, y: 12, what: "the onboarding window's corner")

        print("selftest: playerStageProbe OK (\(vm.items.count) navigator items; the player "
              + "docks and returns at the same t; the window is cream under dark appearance)")
    }
}
