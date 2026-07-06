import Foundation
import AppKit
import AVFoundation
import SwiftUI

/// Headless smoke test of the non-AI pipeline (scene detection, frame
/// extraction, branded rendering, exports). Run with:
///   WalkthroughStudio --selftest <video> <outputDir>
@MainActor
enum SelfTest {
    static func run(videoURL: URL, outDir: URL) async throws {
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // 0. UI probe: build the studio's player pane offscreen. This forces the
        // AVKit representable's class metadata to instantiate — the exact thing
        // that crashed with SwiftUI's VideoPlayer overlay on macOS 26.1.
        try await uiProbe(videoURL: videoURL)

        // 0.5. LLM JSON-array extraction (no network — pure parsing)
        try jsonExtractionProbe()

        // 0.6. Transcript-based segmentation (pure logic — no speech recognition)
        try transcriptRefinementProbe()

        // 0.62. Device detection from recording dimensions
        try deviceDetectionProbe()

        // 0.65. Status-bar crop: top band must be removed, orientation correct
        try cropTopProbe()

        // 0.66. Clean status bar: band replaced by background + island drawn
        try cleanStatusBarProbe(outDir: outDir)

        // 0.7. PDF briefing text extraction
        try briefingProbe(outDir: outDir)

        // 0.8. New Project sheet renders on-brand even under dark appearance
        try await newProjectSheetProbe(outDir: outDir)

        // 0.85. Video export sheet renders on-brand even under dark appearance
        try await exportSheetProbe(outDir: outDir)

        // 0.9. Processing screen renders on-brand even under dark appearance
        try await processingViewProbe(outDir: outDir)

        // 1. Scene detection
        let detector = SceneDetector()
        let detected = try await detector.detect(videoURL: videoURL) { _ in }
        print("selftest: detected \(detected.count) steps: \(detected.map { "\($0.start)-\($0.end) frame@\($0.settledFrameTime)" })")
        guard detected.count >= 2 else { throw StudioError("Expected >= 2 detected scenes, got \(detected.count)") }

        var steps: [WalkthroughStep] = detected.enumerated().map { index, scene in
            var step = WalkthroughStep(startTime: scene.start, endTime: scene.end, frameTime: scene.settledFrameTime)
            step.slug = "step-\(index + 1)"
            step.area = "Area \(index + 1)"
            step.title = "Step \(index + 1)"
            step.body = "Body copy for step \(index + 1)."
            step.alt = "Screenshot of step \(index + 1)."
            step.headline = "Step <span class=\"accent\">\(index + 1)</span><br>headline"
            step.subheadline = "Supporting sentence for step \(index + 1)."
            return step
        }

        // 2. Frame extraction + tutorial PNG export
        for step in steps {
            let cg = try await VideoService.extractFrame(videoURL: videoURL, at: step.frameTime)
            guard let png = Exporters.pngData(from: cg) else { throw StudioError("PNG encode failed") }
            try png.write(to: outDir.appendingPathComponent("\(step.resolvedSlug).png"))
        }

        // 3. tutorialSteps payloads
        try Exporters.tutorialStepsTS(steps: steps)
            .write(to: outDir.appendingPathComponent("tutorialSteps.ts"), atomically: true, encoding: .utf8)
        try Exporters.tutorialStepsJSON(steps: steps)
            .write(to: outDir.appendingPathComponent("tutorialSteps.json"), atomically: true, encoding: .utf8)

        // 4. Branded slide rendering at both App Store sizes (first step only, for speed)
        let renderer = BrandedRenderer()
        let firstStep = steps[0]
        let frame = try await VideoService.extractFrame(videoURL: videoURL, at: firstStep.frameTime)
        guard let framePNG = Exporters.pngData(from: frame) else { throw StudioError("frame PNG failed") }
        for size in ExportSize.appStore {
            let html = SlideTemplate.html(
                width: size.width,
                height: size.height,
                headlineHTML: firstStep.headline,
                subHTML: firstStep.subheadline,
                screenshotDataURL: Exporters.dataURL(png: framePNG),
                placeholderLabel: firstStep.displayName
            )
            let image = try await renderer.render(html: html, pixelWidth: size.width, pixelHeight: size.height)
            guard let png = Exporters.pngData(from: image, pixelWidth: size.width, pixelHeight: size.height) else {
                throw StudioError("slide PNG encode failed")
            }
            let path = outDir.appendingPathComponent("slide-\(size.dir).png")
            try png.write(to: path)

            // Verify exact pixel dimensions
            guard let rep = NSBitmapImageRep(data: png) else { throw StudioError("could not re-read slide PNG") }
            guard rep.pixelsWide == size.width, rep.pixelsHigh == size.height else {
                throw StudioError("slide \(size.dir) is \(rep.pixelsWide)x\(rep.pixelsHigh), expected \(size.width)x\(size.height)")
            }
            print("selftest: slide \(size.dir) OK (\(rep.pixelsWide)x\(rep.pixelsHigh))")
        }

        // 4.5. Theme injection: render a slide with a custom navy theme and
        // verify the background pixel changed — proves {{THEME_CSS}} plumbing
        // works end to end (and that custom templates would inherit it).
        var navyTheme = BrandTheme()
        navyTheme.backgroundMode = "color"
        navyTheme.backgroundColor = "#0A2540"
        navyTheme.headlineColor = "#FFFFFF"
        navyTheme.wordmarkText = "Acme"
        let themedHTML = SlideTemplate.html(
            width: 1290, height: 2796,
            headlineHTML: "Themed", subHTML: "Navy background",
            screenshotDataURL: Exporters.dataURL(png: framePNG),
            placeholderLabel: "Themed",
            theme: navyTheme
        )
        let themedImage = try await renderer.render(html: themedHTML, pixelWidth: 1290, pixelHeight: 2796)
        guard let themedPNG = Exporters.pngData(from: themedImage, pixelWidth: 1290, pixelHeight: 2796) else {
            throw StudioError("themed slide PNG encode failed")
        }
        try themedPNG.write(to: outDir.appendingPathComponent("slide-themed.png"))
        if let themedCG = Exporters.cgImage(from: themedImage, pixelWidth: 1290, pixelHeight: 2796) {
            let corner = pixel(themedCG, x: 30, y: 30)
            guard corner.b > corner.r + 20, corner.b > 40, corner.r < 60 else {
                throw StudioError(String(format: "themed slide corner rgb(%d,%d,%d) — theme CSS not applied", corner.r, corner.g, corner.b))
            }
        }
        print("selftest: themed slide OK (custom background applied via THEME_CSS)")

        // 4.6. Stacked 16:9 frame background (landscape/computer recordings):
        // text banner on top, wide device below — verify the device area is
        // dark (bezel/empty screen) and the banner area is background.
        let stackedLayout = VideoFrameLayout(device: .computer, videoAspect: 16.0 / 9.0)
        let stackedHTML = stackedLayout.templateHTML(
            headlineHTML: "A quick <span class=\"accent\">tour</span>",
            subHTML: "Everything in two minutes."
        )
        let stackedImage = try await renderer.render(html: stackedHTML, pixelWidth: 1920, pixelHeight: 1080)
        if let png = Exporters.pngData(from: stackedImage, pixelWidth: 1920, pixelHeight: 1080) {
            try? png.write(to: outDir.appendingPathComponent("frame-stacked.png"))
        }
        if let stackedCG = Exporters.cgImage(from: stackedImage, pixelWidth: 1920, pixelHeight: 1080) {
            let device = pixel(stackedCG, x: Int(stackedLayout.phoneRect.midX), y: Int(stackedLayout.phoneRect.midY))
            guard device.r < 80, device.g < 80, device.b < 80 else {
                throw StudioError("stacked frame device area rgb(\(device.r),\(device.g),\(device.b)) — device not drawn where the compositor expects it")
            }
            let banner = pixel(stackedCG, x: 60, y: 60)
            guard banner.r > 215 else {
                throw StudioError("stacked frame banner area rgb(\(banner.r),\(banner.g),\(banner.b)) — background missing")
            }
        }
        print("selftest: stacked 16:9 frame OK (landscape layout renders, device where expected)")

        // 5. SRT generation
        for index in steps.indices { steps[index].script = "Narration for step \(index + 1). It has two sentences." }
        let srt = VideoService.srt(steps: steps, narrationDurations: [:])
        guard srt.contains("-->") else { throw StudioError("SRT generation produced no cues") }
        try srt.write(to: outDir.appendingPathComponent("captions.srt"), atomically: true, encoding: .utf8)

        // 6. Narrated video assembly with a synthesized sine-wave "narration" clip
        let toneURL = outDir.appendingPathComponent("tone.wav")
        try Self.sineWAV(duration: 1.5).write(to: toneURL)
        let narratedURL = outDir.appendingPathComponent("narrated.mp4")
        try await VideoService.assembleNarratedVideo(
            videoURL: videoURL,
            segments: steps.map { .init(sourceStart: $0.startTime, duration: $0.duration, narrationURL: toneURL) },
            keepOriginalAudio: false,
            outputURL: narratedURL
        )
        let size = ((try? FileManager.default.attributesOfItem(atPath: narratedURL.path))?[.size] as? Int) ?? 0
        guard size > 10_000 else { throw StudioError("narrated.mp4 looks empty") }

        // 6.5. Trimmed export: 2s kept per step → total ≈ steps × 2s, proving
        // the "advance scenes with the narration" timeline math.
        let trimmedURL = outDir.appendingPathComponent("trimmed.mp4")
        try await VideoService.assembleNarratedVideo(
            videoURL: videoURL,
            segments: steps.map { .init(sourceStart: $0.startTime, duration: 2.0, narrationURL: toneURL) },
            keepOriginalAudio: false,
            outputURL: trimmedURL
        )
        let trimmedDuration = try await AVURLAsset(url: trimmedURL).load(.duration).seconds
        let expected = Double(steps.count) * 2.0
        guard abs(trimmedDuration - expected) < 0.5 else {
            throw StudioError(String(format: "trimmed export is %.2fs, expected ~%.1fs", trimmedDuration, expected))
        }
        print("selftest: trimmed.mp4 OK (\(String(format: "%.1f", trimmedDuration))s for \(steps.count) steps)")

        // 7. Verify the narration audio track spans the whole timeline. The
        // gap bug (missing empty segments) truncated the track after the first
        // clip; a contiguous track's duration matches the video's. This is a
        // metadata check — no audio decode (which is unreliable headless).
        let narratedAsset = AVURLAsset(url: narratedURL)
        guard let exportedAudio = try await narratedAsset.loadTracks(withMediaType: .audio).first else {
            throw StudioError("exported narrated.mp4 has no audio track")
        }
        let audioRange = try await exportedAudio.load(.timeRange)
        let audioDuration = audioRange.start.seconds + audioRange.duration.seconds
        // The final trailing-silence segment is legitimately trimmed by the
        // exporter, so the track ends at the last real audio — not the video's
        // end. The gap bug instead truncated the track right after the FIRST
        // clip, so requiring the track to reach past the last clip's start
        // proves every post-gap clip survived.
        if let lastClipStart = steps.map(\.startTime).max() {
            guard audioDuration > lastClipStart + 0.3 else {
                throw StudioError(String(format: "narration track spans only %.2fs but the last clip starts at %.2fs — clips after a gap were dropped (gap bug)", audioDuration, lastClipStart))
            }
        }
        print("selftest: narrated.mp4 OK (\(size) bytes; audio reaches \(String(format: "%.1f", audioDuration))s, last clip at \(String(format: "%.1f", steps.map(\.startTime).max() ?? 0))s)")

        // 8. 16:9 branded frame: per-step text segments, exported and verified
        // by sampling pixels — a cream-ish corner (background visible) and a
        // saturated screen sample (the recording composited in). Catches
        // layout/orientation regressions and broken instruction tiling.
        var framing = try await VideoFraming.make(
            slides: steps.enumerated().map { index, step in
                .init(
                    start: step.startTime,
                    headlineHTML: "Step <span class=\"accent\">\(index + 1)</span>",
                    subHTML: "Subhead for step \(index + 1)"
                )
            }
        )
        // Exercise the default "clean status bar" treatment in the compositor.
        if let overlay = StatusBarStyler.overlay(
            width: Int(framing.screenRect.width),
            bandHeight: Int(framing.screenRect.height * BrandTheme.statusBarCropFraction),
            white: false
        ) {
            framing.statusBar = .clean(fraction: BrandTheme.statusBarCropFraction, overlay: overlay)
        }
        guard framing.segments.count == steps.count else {
            throw StudioError("expected \(steps.count) frame segments, got \(framing.segments.count)")
        }
        let framedURL = outDir.appendingPathComponent("framed.mp4")
        try await VideoService.assembleNarratedVideo(
            videoURL: videoURL,
            segments: steps.map { .init(sourceStart: $0.startTime, duration: $0.duration, narrationURL: toneURL) },
            keepOriginalAudio: false,
            framing: framing,
            outputURL: framedURL
        )
        let firstFrame = try await VideoService.extractFrame(videoURL: framedURL, at: 1.0)
        guard firstFrame.width == 1920, firstFrame.height == 1080 else {
            throw StudioError("framed video is \(firstFrame.width)x\(firstFrame.height), expected 1920x1080")
        }
        // Top-left corner should be the warm cream background (R>G>B, all high).
        let corner = pixel(firstFrame, x: 60, y: 60)
        guard corner.r > 230, corner.g > 215, corner.b > 195, corner.r >= corner.b else {
            throw StudioError(String(format: "framed corner not cream (rgb %d,%d,%d) — background missing", corner.r, corner.g, corner.b))
        }
        // The recording (synthetic test video) has a saturated background; a
        // strong channel spread proves the video is composited in. Sample BELOW
        // the status-bar band (the band now carries the clean bar).
        let sc = framing.screenRect
        let bandH = sc.height * BrandTheme.statusBarCropFraction
        let inScreen = pixel(firstFrame, x: Int(sc.midX), y: Int(sc.minY + bandH + 40))
        let spread = max(inScreen.r, inScreen.g, inScreen.b) - min(inScreen.r, inScreen.g, inScreen.b)
        guard spread > 50 else {
            throw StudioError(String(format: "framed screen shows no recording (rgb %d,%d,%d, spread %d) — compositing failed", inScreen.r, inScreen.g, inScreen.b, spread))
        }
        // Clean-bar checks: the band edge continues the scene's background
        // (strip replication), and the Dynamic Island pill is drawn at centre.
        let bandEdge = pixel(firstFrame, x: Int(sc.minX + 50), y: Int(sc.minY + bandH * 0.4))
        let edgeSpread = max(bandEdge.r, bandEdge.g, bandEdge.b) - min(bandEdge.r, bandEdge.g, bandEdge.b)
        guard edgeSpread > 50 else {
            throw StudioError(String(format: "status-bar band edge rgb(%d,%d,%d) — background not extended over the band", bandEdge.r, bandEdge.g, bandEdge.b))
        }
        let islandCenterY = sc.minY + sc.width * 0.0292 + sc.width * 0.0955 / 2
        let island = pixel(firstFrame, x: Int(sc.midX), y: Int(islandCenterY))
        guard island.r < 70, island.g < 70, island.b < 70 else {
            throw StudioError(String(format: "island pixel rgb(%d,%d,%d) — clean bar overlay not drawn on the video", island.r, island.g, island.b))
        }
        // Repeat the checks inside the LAST step's segment — proves the later
        // per-step instructions render too (background + video), not just the first.
        if let lastStep = steps.last, steps.count > 1 {
            let lateFrame = try await VideoService.extractFrame(videoURL: framedURL, at: lastStep.startTime + 0.5)
            let lateCorner = pixel(lateFrame, x: 60, y: 60)
            guard lateCorner.r > 230, lateCorner.g > 215, lateCorner.b > 195 else {
                throw StudioError(String(format: "late segment corner not cream (rgb %d,%d,%d) — per-step background missing", lateCorner.r, lateCorner.g, lateCorner.b))
            }
            let lateIn = pixel(lateFrame, x: Int(sc.midX), y: Int(sc.minY + bandH + 40))
            let lateSpread = max(lateIn.r, lateIn.g, lateIn.b) - min(lateIn.r, lateIn.g, lateIn.b)
            guard lateSpread > 50 else {
                throw StudioError(String(format: "late segment screen shows no recording (rgb %d,%d,%d) — compositing broke after a text switch", lateIn.r, lateIn.g, lateIn.b))
            }
        }
        print("selftest: framed.mp4 OK (1920x1080; \(framing.segments.count) text segments; recording composited into device)")
    }

    /// Sample a pixel using top-left coordinates. NSBitmapImageRep.colorAt
    /// handles the image's orientation so we don't fight CGContext flips.
    nonisolated private static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int) {
        let rep = NSBitmapImageRep(cgImage: image)
        let cx = min(max(0, x), rep.pixelsWide - 1)
        let cy = min(max(0, y), rep.pixelsHigh - 1)
        guard let color = rep.colorAt(x: cx, y: cy)?.usingColorSpace(.deviceRGB) else { return (0, 0, 0) }
        return (Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
    }

    /// One visual step covering the whole video, but the narration has a clear
    /// intro spiel, a demo section, and a wrap-up separated by pauses — the
    /// refinement must split it into three steps at those pauses.
    private static func transcriptRefinementProbe() throws {
        let vm = StudioViewModel()
        vm.steps = [WalkthroughStep(startTime: 0, endTime: 20, frameTime: 5)]
        vm.transcript = [
            TranscriptSegment(start: 0.5, end: 4.0, text: "Today I'm going to walk you through a demo of the app."),
            TranscriptSegment(start: 6.0, end: 12.0, text: "First, open the Talk tab and pick a phrase."),
            TranscriptSegment(start: 13.5, end: 18.0, text: "And that's the whole flow — thanks for watching!"),
        ]
        let added = vm.refineStepsWithTranscript()
        guard added == 2, vm.steps.count == 3 else {
            throw StudioError("transcript refinement made \(added) splits (\(vm.steps.count) steps), expected 2 (intro + outro)")
        }
        // Boundaries should sit just before the next speech block (6.0 and 13.5).
        guard abs(vm.steps[1].startTime - 5.85) < 0.2, abs(vm.steps[2].startTime - 13.35) < 0.2 else {
            throw StudioError("transcript refinement boundaries at \(vm.steps[1].startTime), \(vm.steps[2].startTime) — expected ~5.85 and ~13.35")
        }
        // Transcript must be reassigned so the intro step owns the intro line.
        guard vm.steps[0].transcript.contains("Today I'm going"),
              vm.steps[2].transcript.contains("thanks for watching") else {
            throw StudioError("transcript reassignment after refinement failed")
        }
        print("selftest: transcript refinement probe OK (intro + outro split)")
    }

    /// Render the New Project sheet offscreen under DARK appearance and verify
    /// the background stays brand-cream — guards against system-color regressions
    /// like the dark-card-on-cream bug.
    private static func newProjectSheetProbe(outDir: URL) async throws {
        let vm = StudioViewModel()
        let hosting = NSHostingView(rootView: NewProjectSheet(vm: vm))
        hosting.frame = NSRect(x: 0, y: 0, width: 640, height: 470)
        let window = NSWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: 640, height: 470),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua) // worst case
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 400_000_000)

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw StudioError("could not snapshot the New Project sheet")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        window.contentView = nil

        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: outDir.appendingPathComponent("new-project-sheet.png"))
        }
        guard let cg = rep.cgImage else { throw StudioError("sheet snapshot has no image") }
        let corner = pixel(cg, x: 12, y: 12)
        guard corner.r > 220, corner.g > 210, corner.b > 190 else {
            throw StudioError(String(format: "New Project sheet corner is rgb(%d,%d,%d) under dark appearance — expected brand cream", corner.r, corner.g, corner.b))
        }
        print("selftest: New Project sheet probe OK (cream under dark appearance)")
    }

    /// Render the video export sheet offscreen under DARK appearance: it must
    /// stay brand-cream and suggest a name/folder from the loaded video.
    private static func exportSheetProbe(outDir: URL) async throws {
        let vm = StudioViewModel()
        vm.videoURL = URL(fileURLWithPath: "/tmp/demo-recording.mov")
        vm.frameVideo16x9 = true
        guard vm.suggestedVideoExportName == "demo-recording-framed" else {
            throw StudioError("suggested export name was \(vm.suggestedVideoExportName)")
        }
        vm.frameVideo16x9 = false
        guard vm.suggestedVideoExportName == "demo-recording-narrated",
              vm.suggestedVideoExportDirectory.path.hasSuffix("tmp") || !Defaults.string(SettingsKeys.lastVideoExportDir, "").isEmpty else {
            throw StudioError("suggested export defaults broken: \(vm.suggestedVideoExportName) in \(vm.suggestedVideoExportDirectory.path)")
        }

        let hosting = NSHostingView(rootView: ExportVideoSheet(vm: vm))
        hosting.frame = NSRect(x: 0, y: 0, width: 560, height: 620)
        let window = NSWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: 560, height: 620),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua) // worst case
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 400_000_000)

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw StudioError("could not snapshot the export sheet")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        window.contentView = nil

        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: outDir.appendingPathComponent("export-sheet.png"))
        }
        guard let cg = rep.cgImage else { throw StudioError("export sheet snapshot has no image") }
        let corner = pixel(cg, x: 12, y: 12)
        guard corner.r > 220, corner.g > 210, corner.b > 190 else {
            throw StudioError(String(format: "export sheet corner is rgb(%d,%d,%d) under dark appearance — expected brand cream", corner.r, corner.g, corner.b))
        }
        print("selftest: export sheet probe OK (cream under dark appearance, suggested names)")
    }

    private static func deviceDetectionProbe() throws {
        let cases: [(Int, Int, DeviceKind)] = [
            (1179, 2556, .iphone),   // iPhone 15 Pro portrait
            (1206, 2622, .iphone),   // iPhone 16 Pro Max portrait
            (2048, 2732, .ipad),     // iPad Pro 12.9 portrait
            (2732, 2048, .ipad),     // iPad Pro 12.9 landscape
            (2360, 1640, .ipad),     // iPad Air landscape
            (3456, 2234, .computer), // MacBook Pro 16
            (1920, 1080, .computer), // 16:9 screen capture
        ]
        for (w, h, expected) in cases {
            let got = DeviceKind.detect(width: w, height: h)
            guard got == expected else {
                throw StudioError("device detection: \(w)x\(h) → \(got.rawValue), expected \(expected.rawValue)")
            }
        }
        // Landscape/stacked 16:9 layout must keep the device inside the canvas,
        // below the text band.
        let mac = VideoFrameLayout(device: .computer, videoAspect: 16.0 / 9.0)
        guard mac.phoneRect.maxX <= VideoFrameLayout.canvas.width,
              mac.phoneRect.maxY <= VideoFrameLayout.canvas.height,
              mac.phoneRect.minY >= 200,
              mac.textAlign == "center" else {
            throw StudioError("stacked layout out of bounds: \(mac.phoneRect)")
        }
        // Portrait iPad layout still side-by-side and in bounds.
        let pad = VideoFrameLayout(device: .ipad, videoAspect: 3.0 / 4.0)
        guard pad.phoneRect.maxX <= VideoFrameLayout.canvas.width,
              pad.textAlign == "left",
              pad.textRect.width > 300 else {
            throw StudioError("ipad side-by-side layout broken: \(pad.phoneRect), text \(pad.textRect)")
        }
        print("selftest: device detection + layout probe OK (iphone/ipad/computer)")
    }

    /// A 100x100 image, top 20 rows red, rest blue: cropping 20% off the top
    /// must leave an all-blue image (also pins down CGImage.cropping's origin).
    private static func cropTopProbe() throws {
        let size = 100
        guard let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw StudioError("crop probe: no context") }
        // CGContext drawing is bottom-left origin: the TOP band is high y.
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 80, width: size, height: 20))
        guard let image = ctx.makeImage() else { throw StudioError("crop probe: no image") }

        let cropped = Exporters.cropTop(image, fraction: 0.2)
        guard cropped.height == 80 else {
            throw StudioError("cropTop height \(cropped.height), expected 80")
        }
        let top = pixel(cropped, x: 50, y: 2)      // top row of the cropped image
        guard top.b > 200, top.r < 60 else {
            throw StudioError("cropTop removed the wrong edge — top pixel rgb(\(top.r),\(top.g),\(top.b)), expected blue")
        }
        print("selftest: cropTop probe OK (status-bar band removed from the top)")
    }

    /// 300x600 image: top 10% red (a "messy status bar"), rest white. Cleaning
    /// must repaint the band white (background extended) and draw the black
    /// island pill at the top centre — layout untouched (dimensions equal).
    private static func cleanStatusBarProbe(outDir: URL) throws {
        let w = 300, h = 600
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw StudioError("clean probe: no context") }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: h - 60, width: w, height: 60)) // top band (bottom-left coords)
        // Full-width blue stripe just below the band: real app content that
        // must NOT be mistaken for a floating banner.
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: h - 80, width: w, height: 10)) // rows 70–80 top-left
        guard let image = ctx.makeImage() else { throw StudioError("clean probe: no image") }

        let cleaned = StatusBarStyler.cleanStill(image, fraction: 0.1)
        guard cleaned.width == w, cleaned.height == h else {
            throw StudioError("cleanStill changed dimensions (\(cleaned.width)x\(cleaned.height))")
        }
        if let png = Exporters.pngData(from: cleaned) {
            try? png.write(to: outDir.appendingPathComponent("clean-statusbar.png"))
        }
        // Band background must now be white (was red)…
        let edge = pixel(cleaned, x: 12, y: 20)
        guard edge.r > 220, edge.g > 220, edge.b > 220 else {
            throw StudioError("clean band edge rgb(\(edge.r),\(edge.g),\(edge.b)) — background not extended")
        }
        // …with the black Dynamic Island pill at top centre…
        let island = pixel(cleaned, x: w / 2, y: 18)
        guard island.r < 60, island.g < 60, island.b < 60 else {
            throw StudioError("island pixel rgb(\(island.r),\(island.g),\(island.b)) — pill not drawn")
        }
        // …and the content below the band untouched — including the full-width
        // stripe, which must not trigger the banner heuristic.
        let below = pixel(cleaned, x: w / 2, y: 300)
        guard below.r > 220, below.g > 220, below.b > 220 else {
            throw StudioError("content below the band changed — rgb(\(below.r),\(below.g),\(below.b))")
        }
        let stripe = pixel(cleaned, x: w / 2, y: 75)
        guard stripe.b > 200, stripe.r < 60 else {
            throw StudioError("full-width stripe repainted (rgb(\(stripe.r),\(stripe.g),\(stripe.b))) — banner false positive")
        }

        // Second pass: a gray notification banner (inset from the edges, gray
        // system material) overlapping the bar and reaching below the band.
        // The clean pass must repaint past it, not just the band.
        guard let ctx2 = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw StudioError("clean probe: no banner context") }
        ctx2.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx2.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx2.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx2.fill(CGRect(x: 0, y: h - 60, width: w, height: 60))
        ctx2.setFillColor(CGColor(red: 0.61, green: 0.59, blue: 0.57, alpha: 1))
        ctx2.fill(CGRect(x: 20, y: h - 170, width: w - 40, height: 140)) // banner rows 30–170
        guard let bannered = ctx2.makeImage() else { throw StudioError("clean probe: no banner image") }

        let cleanedBanner = StatusBarStyler.cleanStill(bannered, fraction: 0.1)
        if let png = Exporters.pngData(from: cleanedBanner) {
            try? png.write(to: outDir.appendingPathComponent("clean-statusbar-banner.png"))
        }
        // The banner body below the band must be gone (white background again)…
        let bannerMid = pixel(cleanedBanner, x: w / 2, y: 120)
        guard bannerMid.r > 220, bannerMid.g > 220, bannerMid.b > 220 else {
            throw StudioError("banner remnant at rgb(\(bannerMid.r),\(bannerMid.g),\(bannerMid.b)) — mask not extended past it")
        }
        // …while content well below stays untouched.
        let bannerBelow = pixel(cleanedBanner, x: w / 2, y: 300)
        guard bannerBelow.r > 220, bannerBelow.g > 220, bannerBelow.b > 220 else {
            throw StudioError("banner pass changed content below — rgb(\(bannerBelow.r),\(bannerBelow.g),\(bannerBelow.b))")
        }
        print("selftest: clean status bar probe OK (band repainted, island drawn, banner removed, layout intact)")
    }

    /// Render the pipeline processing screen offscreen under DARK appearance
    /// and verify the backdrop stays brand-warm.
    private static func processingViewProbe(outDir: URL) async throws {
        let vm = StudioViewModel()
        vm.busyMessage = "Drafting step copy with Claude…"
        vm.statusMessage = "Step 2 of 5"
        vm.progress = 0.4

        let hosting = NSHostingView(rootView: ProcessingView(vm: vm))
        hosting.frame = NSRect(x: 0, y: 0, width: 900, height: 620)
        let window = NSWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 620),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 400_000_000)

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw StudioError("could not snapshot the processing view")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        window.orderOut(nil)
        window.contentView = nil

        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: outDir.appendingPathComponent("processing-view.png"))
        }
        guard let cg = rep.cgImage else { throw StudioError("processing snapshot has no image") }
        let corner = pixel(cg, x: 12, y: 12)
        guard corner.r > 215, corner.g > 200, corner.b > 180 else {
            throw StudioError(String(format: "processing view corner is rgb(%d,%d,%d) under dark appearance — expected brand warm", corner.r, corner.g, corner.b))
        }
        print("selftest: processing view probe OK (brand backdrop under dark appearance)")
    }

    /// Write a small real PDF with Core Graphics, then extract its text via
    /// the Briefing service — proves PDFKit extraction works end to end.
    private static func briefingProbe(outDir: URL) throws {
        let pdfURL = outDir.appendingPathComponent("briefing.pdf")
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw StudioError("could not create a PDF context")
        }
        ctx.beginPDFPage(nil)
        let text = NSAttributedString(
            string: "Always call users members. Keep the tone joyful and specific.",
            attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black]
        )
        let line = CTLineCreateWithAttributedString(text)
        ctx.textPosition = CGPoint(x: 72, y: 700)
        CTLineDraw(line, ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        try (data as Data).write(to: pdfURL)

        let extracted = try Briefing.extractText(from: pdfURL)
        guard extracted.contains("members"), extracted.contains("joyful") else {
            throw StudioError("briefing extraction lost the text: \(extracted.prefix(120))")
        }

        // Markdown (plain-text path)
        let mdURL = outDir.appendingPathComponent("briefing.md")
        try "# Voice\n\nAlways **joyful**, always call users members.".write(to: mdURL, atomically: true, encoding: .utf8)
        guard try Briefing.extractText(from: mdURL).contains("joyful") else {
            throw StudioError("markdown briefing extraction failed")
        }

        // UTF-16 text (exercises the encoding fallback)
        let txtURL = outDir.appendingPathComponent("briefing.txt")
        try "Tone: joyful and specific.".write(to: txtURL, atomically: true, encoding: .utf16)
        guard try Briefing.extractText(from: txtURL).contains("joyful") else {
            throw StudioError("utf16 text briefing extraction failed")
        }

        // RTF (NSAttributedString import path)
        let rtfURL = outDir.appendingPathComponent("briefing.rtf")
        let attributed = NSAttributedString(string: "Keep the tone joyful. Users are members.")
        let rtfData = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        try rtfData.write(to: rtfURL)
        guard try Briefing.extractText(from: rtfURL).contains("joyful") else {
            throw StudioError("rtf briefing extraction failed")
        }

        print("selftest: briefing extraction probe OK (pdf, md, utf16 txt, rtf)")
    }

    private static func jsonExtractionProbe() throws {
        // Fenced + prose-wrapped, with brackets inside strings
        let fenced = """
        Here are the results:
        ```json
        [{"id": "a", "script": "Tap [Save] to finish."}, {"id": "b", "script": "Done!"}]
        ```
        Let me know if you'd like changes [I can revise].
        """
        let parsed = try AnthropicClient.extractJSONArray(from: fenced)
        guard parsed.count == 2, parsed[0]["script"] as? String == "Tap [Save] to finish." else {
            throw StudioError("JSON extraction failed on fenced reply: \(parsed)")
        }

        // Escaped quotes inside strings
        let escaped = #"[{"id": "x", "title": "Say \"hello\" [now]"}]"#
        guard try AnthropicClient.extractJSONArray(from: escaped).count == 1 else {
            throw StudioError("JSON extraction failed on escaped quotes")
        }

        // Truncated reply must throw, not return garbage
        let truncated = #"[{"id": "a", "script": "This reply was cut o"#
        if (try? AnthropicClient.extractJSONArray(from: truncated)) != nil {
            throw StudioError("JSON extraction should reject a truncated array")
        }
        print("selftest: JSON extraction probe OK")
    }

    private static func uiProbe(videoURL: URL) async throws {
        let vm = StudioViewModel()
        vm.player.replaceCurrentItem(with: AVPlayerItem(asset: AVURLAsset(url: videoURL)))
        let hosting = NSHostingView(
            rootView: StepEditorView(vm: vm).frame(width: 900, height: 600)
        )
        let window = NSWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 300_000_000)
        window.orderOut(nil)
        window.contentView = nil
        print("selftest: studio UI probe OK (player pane instantiated)")
    }

    private static func sineWAV(duration: Double, sampleRate: Int = 44100) -> Data {
        let count = Int(duration * Double(sampleRate))
        var pcm = Data(capacity: count * 2)
        for i in 0..<count {
            let sample = Int16(8000 * sin(2.0 * .pi * 440.0 * Double(i) / Double(sampleRate)))
            var little = sample.littleEndian
            withUnsafeBytes(of: &little) { pcm.append(contentsOf: $0) }
        }
        return ElevenLabsClient.wavData(fromPCM: pcm, sampleRate: sampleRate, channels: 1, bitsPerSample: 16)
    }
}
