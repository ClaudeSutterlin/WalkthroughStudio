import Foundation
import SwiftUI
import AVFoundation
import AVKit
import AppKit
import UniformTypeIdentifiers

@MainActor
final class StudioViewModel: ObservableObject {

    // MARK: State

    @Published var videoURL: URL?
    @Published var steps: [WalkthroughStep] = []
    @Published var transcript: [TranscriptSegment] = []
    @Published var selectedStepID: UUID?

    @Published var busyMessage: String?
    @Published var progress: Double?
    @Published var statusMessage: String = ""
    @Published var errorMessage: String?

    /// Wizard mode: false = simple review flow, true = the full tabbed studio.
    @Published var showAdvanced = false
    /// True while the initial automatic pipeline runs — the UI shows the
    /// branded processing screen and blocks editing until the first pass lands.
    @Published var isProcessingPipeline = false
    /// Gentle guidance shown on the review screen (missing key, silent video, …).
    @Published var pipelineNotice: String?

    /// Narrated-video export: wrap the recording in the branded 16:9 frame.
    /// The frame's headline/subhead come from each step's slide copy.
    @Published var frameVideo16x9 = false
    /// Cut each narrated step to its narration length so scenes advance with
    /// the voice-over instead of rolling silently.
    @Published var trimQuietStretches = true
    /// The video export sheet (format + options + destination).
    @Published var showVideoExportSheet = false
    /// Most recent export target — the status bar renders it as a clickable link.
    @Published var lastExportURL: URL?

    /// The "Capture a Website" sheet (URL + goal → agent-driven recording).
    @Published var showWebCaptureSheet = false
    /// Freshest page image while a web capture runs — the processing screen
    /// shows it so the user can watch the agent browse.
    @Published var captureLiveImage: NSImage?

    /// Project briefing (PDF): its text guides every content-generating prompt.
    @Published var briefingURL: URL?
    @Published var briefingText: String = ""

    /// Design tokens for the branded frames (slides + 16:9 video wrapper).
    @Published var theme = BrandTheme()
    @Published var showThemeEditor = false

    /// What the recording was captured on. Drives bezel geometry, status-bar
    /// treatment, App Store sizes; "computer" disables the App Store export.
    @Published var deviceKind: DeviceKind = .iphone
    /// Oriented pixel size of the recording.
    private(set) var videoNaturalSize = CGSize(width: 1206, height: 2622)

    var videoAspect: CGFloat {
        guard videoNaturalSize.height > 0 else { return VideoFrameLayout.screenAspect }
        return videoNaturalSize.width / videoNaturalSize.height
    }

    /// The recording size the slide's screen slot should assume — when the
    /// crop status-bar mode is on, the top band is gone, so the visible
    /// aspect is shorter.
    var statusBarAdjustedVideoSize: CGSize {
        let fraction = deviceKind.statusBarFraction
        if theme.statusBarMode == "crop", fraction > 0 {
            return CGSize(width: videoNaturalSize.width, height: videoNaturalSize.height * (1 - fraction))
        }
        return videoNaturalSize
    }

    /// Small sidebar thumbnails, keyed by step id.
    @Published var thumbnails: [UUID: NSImage] = [:]
    /// Synthesized narration audio (WAV), keyed by step id.
    @Published var narrationAudio: [UUID: URL] = [:]
    @Published var narrationDurations: [UUID: Double] = [:]

    let player = AVPlayer()
    private(set) var videoDuration: Double = 0

    private var audioPlayer: AVAudioPlayer?
    /// Cache of full-res frame PNG data URLs for the branded preview, keyed by step id + frame time.
    private var frameDataURLCache: [String: String] = [:]

    var selectedStep: WalkthroughStep? {
        steps.first { $0.id == selectedStepID }
    }

    var isBusy: Bool { busyMessage != nil }

    func binding(for stepID: UUID) -> Binding<WalkthroughStep>? {
        // Resolve by id on EVERY access — SwiftUI holds bindings across view
        // updates, so a captured index goes stale (and crashes) the moment a
        // split/refine/delete reshuffles the array.
        guard let snapshot = steps.first(where: { $0.id == stepID }) else { return nil }
        return Binding(
            get: { self.steps.first(where: { $0.id == stepID }) ?? snapshot },
            set: { newValue in
                guard let index = self.steps.firstIndex(where: { $0.id == stepID }) else { return }
                self.steps[index] = newValue
            }
        )
    }

    // MARK: Busy wrapper

    private func run(_ message: String, _ work: @escaping () async throws -> Void) {
        guard busyMessage == nil else { return }
        busyMessage = message
        progress = nil
        Task {
            do {
                try await work()
            } catch {
                self.errorMessage = error.localizedDescription
            }
            self.busyMessage = nil
            self.progress = nil
        }
    }

    // MARK: Import

    /// `device` nil = auto-detect from the recording's aspect ratio.
    func importVideo(url: URL, device: DeviceKind? = nil) {
        run("Importing recording…") {
            try await self.adoptVideo(url: url, device: device)
            self.statusMessage = "Imported \(url.lastPathComponent) (\(Self.formatTime(self.videoDuration)))."
            // Continue straight into the pipeline INSIDE this run() call —
            // nesting a second run() here would let the outer epilogue clear
            // the busy state and reopen the single-flight guard mid-pipeline.
            self.isProcessingPipeline = true
            defer { self.isProcessingPipeline = false }
            try await self.autoPipelineCore()
        }
    }

    /// Load a recording and reset all per-project state — shared by manual
    /// import and the web-capture pipeline. `device` nil = auto-detect.
    private func adoptVideo(url: URL, device: DeviceKind?) async throws {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        if let track = try await asset.loadTracks(withMediaType: .video).first {
            let natural = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let oriented = natural.applying(transform)
            videoNaturalSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
        }
        deviceKind = device ?? DeviceKind.detect(
            width: Int(videoNaturalSize.width),
            height: Int(videoNaturalSize.height)
        )
        videoURL = url
        videoDuration = duration
        steps = []
        transcript = []
        thumbnails = [:]
        narrationAudio = [:]
        narrationDurations = [:]
        frameDataURLCache = [:]
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        showAdvanced = false
        pipelineNotice = nil
        lastExportURL = nil
    }

    // MARK: Web capture (URL + goal → agent-recorded project)

    /// Everything the Capture a Website sheet collects.
    struct WebCaptureConfig {
        var url: URL
        var goal: String
        var viewport: CaptureViewport
    }

    /// Drive the capture agent over the site, record the browsing session as
    /// a movie, then run the capture-flavored pipeline (steps come from the
    /// agent's own marks; scripts/copy are written FROM the step screenshots).
    func captureFromWeb(config: WebCaptureConfig) {
        run("Preparing the capture browser…") {
            self.isProcessingPipeline = true
            defer {
                self.isProcessingPipeline = false
                self.captureLiveImage = nil
            }
            guard !Keychain.anthropicKey.isEmpty else {
                throw StudioError("Web capture needs an Anthropic API key — the agent explores the site by looking at it with Claude. Add a key in Settings, then try again.")
            }
            let client = AnthropicClient(apiKey: Keychain.anthropicKey)
            let explorer = ClaudeExplorer(client: client, briefing: self.briefingText)
            try await self.runWebCaptureCore(config: config, explorer: explorer)
        }
    }

    /// The capture pipeline body (must run inside an enclosing `run()`; the
    /// explorer is injected so the selftest can drive it without the network).
    func runWebCaptureCore(config: WebCaptureConfig, explorer: CaptureExploring) async throws {
        busyMessage = "Exploring \(config.url.host ?? config.url.absoluteString)…"

        // Application Support, not tmp: the movie IS the project's recording —
        // a saved .walkstudio.json references it by path, and a purged temp
        // file would orphan the project on reopen.
        let capturesDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Walkthrough Studio/Captures", isDirectory: true)
        try FileManager.default.createDirectory(at: capturesDir, withIntermediateDirectories: true)
        let baseName = (config.url.host ?? "capture").replacingOccurrences(of: ".", with: "-")
        let movieURL = capturesDir.appendingPathComponent("\(baseName)-\(Int(Date().timeIntervalSince1970)).mov")

        // Status-bar glyph overlays are AppKit drawing — built here on the
        // main actor, consumed inside the recorder actor.
        let viewport = config.viewport
        var barLight: CGImage?
        var barDark: CGImage?
        if viewport.statusBarBandHeight > 0 {
            let width = Int(viewport.pixelSize.width)
            barLight = StatusBarStyler.overlay(width: width, bandHeight: viewport.statusBarBandHeight, white: false, device: .iphone)
            barDark = StatusBarStyler.overlay(width: width, bandHeight: viewport.statusBarBandHeight, white: true, device: .iphone)
        }

        let session = WebCaptureSession(viewport: viewport)
        defer { session.close() }
        let recorder = try CaptureRecorder(
            outputURL: movieURL,
            viewport: viewport,
            barOverlayLight: barLight,
            barOverlayDark: barDark
        )
        let driver = CaptureDriver(session: session, recorder: recorder, explorer: explorer) { [weak self] message, image in
            guard let self else { return }
            self.statusMessage = message
            if let image {
                self.captureLiveImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            }
        }
        let result = try await driver.run(startURL: config.url, goal: config.goal, movieURL: movieURL)

        busyMessage = "Assembling the recording…"
        try await adoptVideo(url: movieURL, device: viewport.deviceKind)
        // The capture bakes its own pristine status bar into the footage
        // (iPhone) or has none (desktop) — don't re-clean it downstream.
        theme.statusBarMode = "off"
        steps = result.walkthroughSteps()
        selectedStepID = steps.first?.id
        statusMessage = "Captured \(steps.count) steps from \(config.url.host ?? "the site")."
        await refreshAllThumbnails()

        busyMessage = "Writing narration & copy from the screenshots…"
        do {
            let client = AnthropicClient(apiKey: Keychain.anthropicKey)
            let content = try await CaptureCopywriter.write(
                client: client,
                steps: steps,
                logs: result.steps,
                goal: config.goal,
                briefing: briefingText
            )
            for index in steps.indices {
                guard let c = content[steps[index].id] else { continue }
                steps[index].script = c.script
                steps[index].slug = c.slug
                steps[index].area = c.area
                steps[index].title = c.title.isEmpty ? steps[index].title : c.title
                steps[index].body = c.body
                steps[index].alt = c.alt
                steps[index].headline = c.headline
                steps[index].subheadline = c.subheadline
            }
        } catch {
            pipelineNotice = "The steps are captured, but writing the narration didn't finish (\(error.localizedDescription)) — press Run AI to retry."
        }

        if result.endedEarly, pipelineNotice == nil {
            pipelineNotice = "The capture ended before the agent finished the tour — \(result.finishReason) Review what was recorded below."
        }
        if Keychain.elevenLabsKey.isEmpty {
            if pipelineNotice == nil {
                pipelineNotice = "Add an ElevenLabs API key in Settings to generate the voice-over."
            }
        } else if steps.contains(where: { !$0.script.isEmpty }) {
            busyMessage = "Synthesizing voice-over (ElevenLabs)…"
            try await synthesizeCore(stepIDs: nil)
        }
        statusMessage = "Review the captured steps below — edit anything, then export."
    }

    // MARK: Automatic pipeline (import → review)

    /// Re-run the automatic pipeline on the already-imported recording.
    func runAutoPipeline() {
        guard videoURL != nil else { return }
        isProcessingPipeline = true
        run("Detecting steps…") {
            // Clears on every exit — completion, thrown error, anything.
            defer { self.isProcessingPipeline = false }
            try await self.autoPipelineCore()
        }
    }

    /// Detect → transcribe → draft copy → polish scripts → synthesize voice-over.
    /// AI stages degrade gracefully when a key is missing or the video is silent;
    /// the review screen explains what was skipped via `pipelineNotice`.
    /// Must run inside an enclosing `run()` (it keeps `busyMessage` current).
    private func autoPipelineCore() async throws {
        busyMessage = "Detecting steps…"
        try await detectStepsCore()
        busyMessage = "Transcribing narration (on-device)…"
        do {
            try await transcribeCore()
        } catch {
            pipelineNotice = "Transcription didn't work (\(error.localizedDescription)) — you can type narration on the cards below."
        }
        progress = nil
        // Second segmentation signal: narration pauses catch boundaries the
        // visuals can't (spoken intro/outro over an unchanged screen).
        let refined = refineStepsWithTranscript()
        if refined > 0 {
            statusMessage = "Added \(refined) step\(refined == 1 ? "" : "s") from narration pauses."
            await refreshAllThumbnails()
        }
        try await aiStagesCore()
        statusMessage = "Review the steps below — edit anything, then export."
    }

    /// Re-runs just the AI stages (copy, scripts, voice-over).
    func runAIStages() {
        guard !steps.isEmpty else { return }
        run("Running AI…") {
            try await self.aiStagesCore()
            self.statusMessage = "AI pass complete — review and edit below."
        }
    }

    private func aiStagesCore() async throws {
        let hasMaterial = steps.contains { !$0.transcript.isEmpty || !$0.script.isEmpty }
        guard hasMaterial else {
            pipelineNotice = "No narration was found in the recording — type a script on each card (or re-record with narration), then press Run AI."
            return
        }
        guard !Keychain.anthropicKey.isEmpty else {
            pipelineNotice = "Add your Anthropic API key in Settings, then press Run AI to draft copy and narration."
            return
        }
        pipelineNotice = nil
        busyMessage = "Drafting step copy with Claude…"
        try await generateCopyCore()
        busyMessage = "Polishing narration scripts with Claude…"
        try await polishScriptsCore()
        if Keychain.elevenLabsKey.isEmpty {
            pipelineNotice = "Add an ElevenLabs API key in Settings to generate the voice-over."
        } else if steps.contains(where: { !$0.script.isEmpty }) {
            busyMessage = "Synthesizing voice-over (ElevenLabs)…"
            try await synthesizeCore(stepIDs: nil)
        }
    }

    // MARK: Steps (detect / add / remove / re-time)

    func detectSteps() {
        guard videoURL != nil else { return }
        run("Detecting steps (scene changes)…") {
            try await self.detectStepsCore()
        }
    }

    private func detectStepsCore() async throws {
        guard let videoURL else { return }
        let detector = SceneDetector()
        let detected = try await detector.detect(videoURL: videoURL) { fraction in
            Task { @MainActor in self.progress = fraction }
        }
        steps = detected.enumerated().map { index, scene in
            WalkthroughStep(
                startTime: scene.start,
                endTime: scene.end,
                frameTime: scene.settledFrameTime,
                slug: "step-\(index + 1)"
            )
        }
        // The new steps have fresh ids — anything keyed by the old ids is now
        // orphaned and would silently pass the "narration exists" export guard.
        narrationAudio = [:]
        narrationDurations = [:]
        frameDataURLCache = [:]
        assignTranscriptsToSteps()
        selectedStepID = steps.first?.id
        statusMessage = "Detected \(steps.count) steps."
        progress = nil
        await refreshAllThumbnails()
    }

    func addStepAtPlayhead() {
        guard videoURL != nil else { return }
        let time = player.currentTime().seconds
        guard time.isFinite, time >= 0 else { return }

        if let newID = splitStep(at: time) {
            selectedStepID = newID
            assignTranscriptsToSteps()
            if let index = steps.firstIndex(where: { $0.id == newID }), index > 0 {
                refreshThumbnail(for: steps[index - 1].id)
            }
            refreshThumbnail(for: newID)
        } else if steps.isEmpty {
            let step = WalkthroughStep(startTime: 0, endTime: videoDuration, frameTime: min(time, videoDuration))
            steps = [step]
            selectedStepID = step.id
            assignTranscriptsToSteps()
            refreshThumbnail(for: step.id)
        }
        statusMessage = "Added a step boundary at \(Self.formatTime(time))."
    }

    /// Split the step containing `time` into two. The second piece gets fresh
    /// identity and empty copy (it's a new step the AI/user will fill in).
    /// Returns the new (second) step's id, or nil if `time` isn't strictly
    /// inside a step.
    @discardableResult
    func splitStep(at time: Double) -> UUID? {
        guard let index = steps.firstIndex(where: { $0.startTime + 0.3 < time && time < $0.endTime - 0.3 }) else {
            return nil
        }
        var first = steps[index]
        var second = first
        first.endTime = time
        if !(first.startTime...first.endTime).contains(first.frameTime) {
            first.frameTime = first.startTime + first.duration / 2
        }
        second.id = UUID()
        second.startTime = time
        second.frameTime = min(time + 0.5, second.endTime)
        second.slug = ""
        second.area = ""
        second.title = ""
        second.body = ""
        second.alt = ""
        second.transcript = ""
        second.script = ""
        second.headline = ""
        second.subheadline = ""
        steps[index] = first
        steps.insert(second, at: index + 1)
        return second.id
    }

    /// Transcript-aware segmentation: split steps at long narration pauses that
    /// visual detection can't see — the classic case being a spoken intro
    /// ("Today I'm going to walk you through…") over the same screen the demo
    /// then starts on. Head and tail steps split at their first/last pause;
    /// middle steps (already visually segmented) only at very long pauses.
    /// Returns how many new steps were created.
    @discardableResult
    func refineStepsWithTranscript() -> Int {
        guard !transcript.isEmpty, !steps.isEmpty else { return 0 }
        let speech = transcript.sorted { $0.start < $1.start }
        let pauseThreshold = 1.2      // seconds of silence that mark a boundary
        let midPauseThreshold = 2.0   // middle steps need a much longer pause
        let minPiece = 2.0            // both halves of a split must be ≥ this

        var boundaries: [Double] = []
        for (index, step) in steps.enumerated() {
            // Silences between consecutive speech blocks, fully inside this step
            // and far enough from its edges that both pieces stay meaningful.
            var pauses: [(cut: Double, length: Double)] = []
            for i in 1..<speech.count {
                let silenceStart = speech[i - 1].end
                let silenceEnd = speech[i].start
                let length = silenceEnd - silenceStart
                guard length >= pauseThreshold else { continue }
                guard silenceStart > step.startTime + minPiece,
                      silenceEnd < step.endTime - minPiece else { continue }
                // Cut just before the next speech block so the new step's
                // narration lines up with its start.
                pauses.append((cut: silenceEnd - 0.15, length: length))
            }
            guard !pauses.isEmpty else { continue }

            if index == 0 {
                boundaries.append(pauses[0].cut)               // intro spiel
            }
            if index == steps.count - 1 {
                boundaries.append(pauses[pauses.count - 1].cut) // wrap-up
            }
            if index > 0 && index < steps.count - 1 {
                for pause in pauses where pause.length >= midPauseThreshold {
                    boundaries.append(pause.cut)
                }
            }
        }

        // Dedupe boundaries that landed close together (e.g. a single-step video
        // where the intro and outro rules picked the same pause).
        var applied = 0
        var lastCut = -Double.greatestFiniteMagnitude
        for cut in Set(boundaries).sorted() {
            guard cut - lastCut > 1.5 else { continue }
            if splitStep(at: cut) != nil {
                applied += 1
                lastCut = cut
            }
        }
        if applied > 0 {
            assignTranscriptsToSteps()
        }
        return applied
    }

    func removeStep(id: UUID) {
        guard let index = steps.firstIndex(where: { $0.id == id }) else { return }
        let removed = steps[index]
        steps.remove(at: index)
        // Merge the freed time range into the previous (or next) step.
        if index > 0 {
            steps[index - 1].endTime = removed.endTime
        } else if !steps.isEmpty {
            steps[0].startTime = removed.startTime
        }
        thumbnails[id] = nil
        narrationAudio[id] = nil
        narrationDurations[id] = nil
        assignTranscriptsToSteps()
        if selectedStepID == id { selectedStepID = steps.first?.id }
    }

    func setFrameToPlayhead(stepID: UUID) {
        guard let index = steps.firstIndex(where: { $0.id == stepID }) else { return }
        let time = player.currentTime().seconds
        steps[index].frameTime = min(max(time, 0), videoDuration)
        refreshThumbnail(for: stepID)
    }

    func setStartToPlayhead(stepID: UUID) {
        guard let index = steps.firstIndex(where: { $0.id == stepID }) else { return }
        let time = player.currentTime().seconds
        // Clamp between the previous step's start (it absorbs the moved
        // boundary and must keep a positive duration) and our own end.
        let lowerBound = index > 0 ? steps[index - 1].startTime + 0.1 : 0
        steps[index].startTime = min(max(time, lowerBound), steps[index].endTime - 0.1)
        if index > 0 { steps[index - 1].endTime = steps[index].startTime }
        assignTranscriptsToSteps()
    }

    func seek(to seconds: Double) {
        player.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    // MARK: Thumbnails / frames

    func refreshThumbnail(for stepID: UUID) {
        guard let videoURL, let step = steps.first(where: { $0.id == stepID }) else { return }
        let time = step.frameTime
        Task {
            if let cg = try? await VideoService.extractFrame(videoURL: videoURL, at: time, maxDimension: 480) {
                self.thumbnails[stepID] = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
    }

    func refreshAllThumbnails() async {
        guard let videoURL else { return }
        for step in steps {
            if let cg = try? await VideoService.extractFrame(videoURL: videoURL, at: step.frameTime, maxDimension: 480) {
                thumbnails[step.id] = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
        }
    }

    /// Apply the theme's status-bar treatment to a still frame. Computers have
    /// no phone-style status bar, so they always pass through untouched.
    func applyStatusBarTreatment(_ image: CGImage) -> CGImage {
        let fraction = deviceKind.statusBarFraction
        guard fraction > 0 else { return image }
        switch theme.statusBarMode {
        case "crop":
            return Exporters.cropTop(image, fraction: fraction)
        case "clean":
            return StatusBarStyler.cleanStill(image, fraction: fraction, device: deviceKind)
        default:
            return image
        }
    }

    /// Full-res frame PNG as a data URL for the branded slide (cached per frame
    /// time + status-bar mode). The bar is cleaned/cropped per the theme.
    func frameDataURL(for step: WalkthroughStep) async -> String? {
        guard let videoURL else { return nil }
        let key = "\(step.id.uuidString)@\(step.frameTime)|bar:\(theme.statusBarMode)|dev:\(deviceKind.rawValue)"
        if let cached = frameDataURLCache[key] { return cached }
        guard var cg = try? await VideoService.extractFrame(videoURL: videoURL, at: step.frameTime) else { return nil }
        cg = applyStatusBarTreatment(cg)
        guard let png = Exporters.pngData(from: cg) else { return nil }
        let url = Exporters.dataURL(png: png)
        frameDataURLCache[key] = url
        return url
    }

    // MARK: Transcription

    func transcribe() {
        guard videoURL != nil else { return }
        run("Transcribing narration (on-device)…") {
            try await self.transcribeCore()
        }
    }

    private func transcribeCore() async throws {
        guard let videoURL else { return }
        let locale = Defaults.string(SettingsKeys.transcribeLocale, Defaults.transcribeLocale)
        let transcriber = SpeechTranscriber()
        let segments = try await transcriber.transcribe(videoURL: videoURL, localeID: locale) { fraction, message in
            Task { @MainActor in
                self.progress = fraction
                self.statusMessage = message
            }
        }
        transcript = segments
        assignTranscriptsToSteps()
        statusMessage = segments.isEmpty
            ? "No speech found in the recording."
            : "Transcribed \(segments.count) phrases and assigned them to steps."
    }

    func assignTranscriptsToSteps() {
        guard !transcript.isEmpty else { return }
        for index in steps.indices {
            let step = steps[index]
            let overlapping = transcript.filter { segment in
                segment.end > step.startTime && segment.start < step.endTime
            }
            steps[index].transcript = overlapping.map(\.text).joined(separator: " ")
        }
    }

    // MARK: LLM copy (Output B & C fields)

    func generateCopy() {
        guard !steps.isEmpty else { return }
        run("Drafting step copy with Claude…") {
            try await self.generateCopyCore()
            self.statusMessage = "Drafted titles, body copy, and slide headlines — review and edit before export."
        }
    }

    private func generateCopyCore() async throws {
        let client = AnthropicClient(apiKey: Keychain.anthropicKey)
        let copy = try await CopyService.generateStepCopy(client: client, steps: steps, briefing: briefingText)
        for index in steps.indices {
            guard let c = copy[steps[index].id] else { continue }
            steps[index].slug = c.slug
            steps[index].area = c.area
            steps[index].title = c.title
            steps[index].body = c.body
            steps[index].alt = c.alt
            steps[index].headline = c.headline
            steps[index].subheadline = c.subheadline
        }
    }

    func polishScripts() {
        let candidates = steps.filter { !$0.transcript.isEmpty || !$0.script.isEmpty }
        guard !candidates.isEmpty else {
            errorMessage = "No transcripts or draft scripts yet. Transcribe the recording or type a script per step first."
            return
        }
        run("Polishing narration scripts with Claude…") {
            try await self.polishScriptsCore()
            self.statusMessage = "Polished narration scripts — review them, then synthesize the voice-over."
        }
    }

    private func polishScriptsCore() async throws {
        // Needs at least one step with material, but the model gets the FULL
        // ordered list so intro/outro positions are true and a silent intro or
        // wrap-up step still gets a script written for it.
        guard steps.contains(where: { !$0.transcript.isEmpty || !$0.script.isEmpty }) else { return }
        let client = AnthropicClient(apiKey: Keychain.anthropicKey)
        let polished = try await CopyService.polishScripts(client: client, steps: steps, briefing: briefingText)
        for index in steps.indices {
            if let script = polished[steps[index].id],
               !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                steps[index].script = script
            }
        }
    }

    // MARK: Voice-over (Output A)

    private var audioDirectory: URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("walkthrough-studio-audio")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func synthesizeVoiceover(stepIDs: [UUID]? = nil) {
        let targets = synthesisTargets(stepIDs: stepIDs)
        guard !targets.isEmpty else {
            errorMessage = "No narration scripts to synthesize. Write or polish scripts first."
            return
        }
        run("Synthesizing voice-over (ElevenLabs)…") {
            try await self.synthesizeCore(stepIDs: stepIDs)
        }
    }

    private func synthesisTargets(stepIDs: [UUID]?) -> [WalkthroughStep] {
        steps.filter { step in
            guard !step.script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            if let stepIDs { return stepIDs.contains(step.id) }
            return true
        }
    }

    private func synthesizeCore(stepIDs: [UUID]?) async throws {
        let targets = synthesisTargets(stepIDs: stepIDs)
        guard !targets.isEmpty else { return }
        let voiceID = Defaults.string(SettingsKeys.elevenVoiceID, Defaults.elevenVoiceID)
        let configuredModel = Defaults.string(SettingsKeys.elevenModelID, "")
        let client = ElevenLabsClient(apiKey: Keychain.elevenLabsKey)
        let modelID = configuredModel.isEmpty ? try await client.recommendedModelID() : configuredModel
        for (index, step) in targets.enumerated() {
            progress = Double(index) / Double(targets.count)
            statusMessage = "Synthesizing \(index + 1) of \(targets.count): \(step.displayName)"
            let wav = try await client.synthesizeWAV(text: step.script, voiceID: voiceID, modelID: modelID)
            let url = audioDirectory.appendingPathComponent("\(step.id.uuidString).wav")
            try wav.write(to: url)
            narrationAudio[step.id] = url
            let audioAsset = AVURLAsset(url: url)
            narrationDurations[step.id] = try await audioAsset.load(.duration).seconds
        }
        progress = nil
        statusMessage = "Voice-over ready (model \(modelID))."
    }

    func playNarration(stepID: UUID) {
        guard let url = narrationAudio[stepID] else { return }
        audioPlayer = try? AVAudioPlayer(contentsOf: url)
        audioPlayer?.play()
    }

    func stopNarration() {
        audioPlayer?.stop()
    }

    /// Opens the export sheet (format, pacing, audio, destination in one place).
    func exportNarratedVideo() {
        guard videoURL != nil else { return }
        guard !narrationAudio.isEmpty else {
            errorMessage = "No synthesized narration yet. Synthesize the voice-over first."
            return
        }
        showVideoExportSheet = true
    }

    /// Suggested file name (no extension) for the current format.
    var suggestedVideoExportName: String {
        let base = videoURL?.deletingPathExtension().lastPathComponent ?? "walkthrough"
        return base + (frameVideo16x9 ? "-framed" : "-narrated")
    }

    /// Last-used export folder, falling back to the recording's folder.
    var suggestedVideoExportDirectory: URL {
        let saved = Defaults.string(SettingsKeys.lastVideoExportDir, "")
        var isDir: ObjCBool = false
        if !saved.isEmpty, FileManager.default.fileExists(atPath: saved, isDirectory: &isDir), isDir.boolValue {
            return URL(fileURLWithPath: saved)
        }
        if let videoURL { return videoURL.deletingLastPathComponent() }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    func exportNarratedVideo(to outputURL: URL) {
        guard let videoURL else { return }
        guard !narrationAudio.isEmpty else {
            errorMessage = "No synthesized narration yet. Synthesize the voice-over first."
            return
        }
        guard outputURL.standardizedFileURL != videoURL.standardizedFileURL else {
            errorMessage = "That would overwrite the original recording — pick a different name or folder."
            return
        }
        UserDefaults.standard.set(
            outputURL.deletingLastPathComponent().path,
            forKey: SettingsKeys.lastVideoExportDir
        )

        let keepOriginal = Defaults.bool(SettingsKeys.keepOriginalAudio)
        let wantsFrame = frameVideo16x9
        let trim = trimQuietStretches

        // Build the output timeline. With trimming on, a step with narration is
        // cut to its narration length (+ a beat) so the video advances with the
        // voice-over instead of rolling silently; steps without narration keep
        // their full footage. Everything downstream (frame text, captions) uses
        // the REMAPPED starts.
        let ordered = steps.sorted { $0.startTime < $1.startTime }
        var segments: [VideoService.ExportSegment] = []
        var remapped: [WalkthroughStep] = []
        var cursor = 0.0

        // Footage before the first step (if the user re-timed step 1) stays.
        if let first = ordered.first, first.startTime > 0.25 {
            segments.append(.init(sourceStart: 0, duration: first.startTime, narrationURL: nil))
            cursor += first.startTime
        }
        for step in ordered {
            let narrationURL = narrationAudio[step.id]
            var keep = step.duration
            if trim, let narrationDuration = narrationDurations[step.id] {
                keep = min(step.duration, max(narrationDuration + 1.0, 2.0))
            }
            segments.append(.init(sourceStart: step.startTime, duration: keep, narrationURL: narrationURL))
            var moved = step
            moved.startTime = cursor
            moved.endTime = cursor + keep
            remapped.append(moved)
            cursor += keep
        }

        let srtText = VideoService.srt(steps: remapped, narrationDurations: narrationDurations)

        // The frame's text follows the steps: each step's App Store slide
        // headline/subhead, falling back to its title/body — at remapped times.
        let slides = remapped.map { step -> VideoFraming.Slide in
            let headline = step.headline.isEmpty
                ? (step.title.isEmpty ? "See it in action" : step.title)
                : step.headline
            let sub = step.subheadline.isEmpty ? step.body : step.subheadline
            return VideoFraming.Slide(start: step.startTime, headlineHTML: headline, subHTML: sub)
        }

        run(wantsFrame ? "Exporting framed 16:9 video…" : "Exporting narrated video…") {
            var framing: VideoFraming?
            if wantsFrame {
                var made = try await VideoFraming.make(
                    slides: slides,
                    theme: self.theme,
                    device: self.deviceKind,
                    videoAspect: self.videoAspect
                ) { done, total in
                    self.busyMessage = "Rendering branded frames (\(done)/\(total))…"
                }
                // Status-bar treatment for the composited video (none on Macs).
                let barFraction = self.deviceKind.statusBarFraction
                if barFraction > 0 {
                    switch self.theme.statusBarMode {
                    case "crop":
                        made.statusBar = .crop(barFraction)
                    case "clean":
                        // Bar color follows the app's top background (from frame 0).
                        let firstFrame = try? await VideoService.extractFrame(videoURL: videoURL, at: 0.1)
                        let white = firstFrame.map {
                            StatusBarStyler.isDarkBelowBand($0, fraction: barFraction)
                        } ?? false
                        let bandHeight = Int(made.screenRect.height * barFraction)
                        if let overlay = StatusBarStyler.overlay(
                            width: Int(made.screenRect.width), bandHeight: bandHeight,
                            white: white, device: self.deviceKind
                        ) {
                            made.statusBar = .clean(fraction: barFraction, overlay: overlay)
                        } else {
                            // Degrade loudly, not silently — the user asked for clean.
                            self.pipelineNotice = "Couldn't build the clean status bar for the framed video — it exported as recorded."
                        }
                    default:
                        break
                    }
                }
                framing = made
                self.busyMessage = "Compositing the framed 16:9 video…"
            }
            try await VideoService.assembleNarratedVideo(
                videoURL: videoURL,
                segments: segments,
                keepOriginalAudio: keepOriginal,
                framing: framing,
                outputURL: outputURL
            )
            let srtURL = outputURL.deletingPathExtension().appendingPathExtension("srt")
            try srtText.write(to: srtURL, atomically: true, encoding: .utf8)
            self.lastExportURL = outputURL
            self.statusMessage = wantsFrame
                ? "Exported the framed 16:9 video (1920×1080) + .srt captions:"
                : "Exported the narrated video + .srt captions:"
        }
    }

    // MARK: Output B export

    func exportTutorial() {
        guard videoURL != nil else { return }
        let included = steps.filter(\.includeInTutorial)
        guard !included.isEmpty else {
            errorMessage = "No steps are included in the tutorial export."
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for the tutorial PNGs + tutorialSteps payload."
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        run("Exporting tutorial steps…") {
            guard let videoURL = self.videoURL else { return }
            // Slugs name the PNGs AND the payload ids — a collision (two steps
            // resolving to the same slug) would silently overwrite one image
            // while the payload references both. Dedupe once, use everywhere.
            var used = Set<String>()
            let deduped = self.steps.map { step -> WalkthroughStep in
                var copy = step
                var slug = step.resolvedSlug
                if used.contains(slug) {
                    var n = 2
                    while used.contains("\(slug)-\(n)") { n += 1 }
                    slug = "\(slug)-\(n)"
                }
                used.insert(slug)
                copy.slug = slug
                return copy
            }
            let included = deduped.filter(\.includeInTutorial)
            for (index, step) in included.enumerated() {
                self.progress = Double(index) / Double(included.count)
                var cg = try await VideoService.extractFrame(videoURL: videoURL, at: step.frameTime)
                cg = self.applyStatusBarTreatment(cg)
                guard let png = Exporters.pngData(from: cg) else {
                    throw StudioError("Couldn't encode the PNG for “\(step.displayName)” — the payload would reference a missing image.")
                }
                try png.write(to: directory.appendingPathComponent("\(step.resolvedSlug).png"))
            }
            try Exporters.tutorialStepsTS(steps: deduped)
                .write(to: directory.appendingPathComponent("tutorialSteps.ts"), atomically: true, encoding: .utf8)
            try Exporters.tutorialStepsJSON(steps: deduped)
                .write(to: directory.appendingPathComponent("tutorialSteps.json"), atomically: true, encoding: .utf8)
            try Exporters.tutorialMarkdown(steps: deduped)
                .write(to: directory.appendingPathComponent("walkthrough.md"), atomically: true, encoding: .utf8)
            self.lastExportURL = directory
            self.statusMessage = "Exported \(included.count) PNGs + tutorialSteps.ts (drop the PNGs into public/pilot/):"
        }
    }

    // MARK: Output C export

    func exportBranded() {
        guard deviceKind.supportsAppStoreExport else {
            errorMessage = "App Store screenshots are only for iPhone and iPad recordings — App Store Connect doesn't take \(deviceKind.label) screenshots. The 16:9 framed video and tutorial exports still work."
            return
        }
        let included = steps.filter(\.includeInBranded)
        guard !included.isEmpty else {
            errorMessage = "No steps are included in the branded export."
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"
        panel.message = "Choose a folder for the App Store PNGs (6.9-inch/ and 6.5-inch/ subfolders)."
        guard panel.runModal() == .OK, let directory = panel.url else { return }

        run("Rendering branded App Store screenshots…") {
            let renderer = BrandedRenderer()
            let sizes = ExportSize.appStore(for: self.deviceKind)
            let total = included.count * sizes.count
            var done = 0
            for size in sizes {
                let sizeDir = directory.appendingPathComponent(size.dir)
                try FileManager.default.createDirectory(at: sizeDir, withIntermediateDirectories: true)
                for (index, step) in included.enumerated() {
                    self.statusMessage = "Rendering \(step.displayName) at \(size.width)x\(size.height)"
                    let screenshot = await self.frameDataURL(for: step)
                    let html = SlideTemplate.html(
                        width: size.width,
                        height: size.height,
                        headlineHTML: step.headline.isEmpty ? step.title : step.headline,
                        subHTML: step.subheadline.isEmpty ? step.body : step.subheadline,
                        screenshotDataURL: screenshot,
                        placeholderLabel: step.displayName,
                        theme: self.theme,
                        device: self.deviceKind,
                        videoSize: self.statusBarAdjustedVideoSize
                    )
                    let image = try await renderer.render(html: html, pixelWidth: size.width, pixelHeight: size.height)
                    guard let png = Exporters.pngData(from: image, pixelWidth: size.width, pixelHeight: size.height) else {
                        throw StudioError("Could not encode the slide PNG.")
                    }
                    let name = String(format: "%02d-%@.png", index + 1, step.resolvedSlug)
                    try png.write(to: sizeDir.appendingPathComponent(name))
                    done += 1
                    self.progress = Double(done) / Double(total)
                }
            }
            self.lastExportURL = directory
            self.statusMessage = "Exported \(included.count) slides at both App Store sizes:"
        }
    }

    // MARK: Project briefing

    func attachBriefing() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Briefing.contentTypes
        panel.allowsMultipleSelection = false
        panel.message = "Choose a briefing (PDF, Word, Markdown, RTF, HTML, or plain text) — its content will guide all generated copy and narration."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if attachBriefing(url: url) {
            statusMessage = "Attached briefing \(url.lastPathComponent) (\(briefingText.count) characters) — press Run AI to regenerate with it."
        }
    }

    /// Attach a briefing from a known URL (used by the New Project screen and
    /// drag-drop). Returns false (and surfaces the error) if the PDF is unreadable.
    @discardableResult
    func attachBriefing(url: URL) -> Bool {
        do {
            briefingText = try Briefing.extractText(from: url)
            briefingURL = url
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func removeBriefing() {
        briefingURL = nil
        briefingText = ""
        statusMessage = "Removed the project briefing."
    }

    /// Copy the frame templates + Claude Code guide into Application Support
    /// and reveal them — the escape hatch for full HTML/CSS redesigns.
    func editTemplatesInFinder() {
        do {
            let dir = try TemplateStore.materializeForEditing()
            NSWorkspace.shared.activateFileViewerSelecting([dir.appendingPathComponent("CUSTOMIZING.md")])
            statusMessage = "Templates ready — see CUSTOMIZING.md for the Claude Code guide. The app uses your edited copies automatically."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: Project save / load

    func saveProject() {
        guard let videoURL else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = videoURL.deletingPathExtension().lastPathComponent + ".walkstudio.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            var project = WalkthroughProject(videoPath: videoURL.path, steps: steps, transcript: transcript)
            project.briefingPath = briefingURL?.path
            project.theme = theme.isDefault ? nil : theme
            project.deviceKind = deviceKind
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(project).write(to: url)
            statusMessage = "Saved project to \(url.lastPathComponent)."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run("Opening project…") {
            let data = try Data(contentsOf: url)
            let project = try JSONDecoder().decode(WalkthroughProject.self, from: data)
            let videoURL = URL(fileURLWithPath: project.videoPath)
            guard FileManager.default.fileExists(atPath: videoURL.path) else {
                throw StudioError("The recording at \(project.videoPath) no longer exists.")
            }
            let asset = AVURLAsset(url: videoURL)
            self.videoDuration = try await asset.load(.duration).seconds
            self.videoURL = videoURL
            self.steps = project.steps
            self.transcript = project.transcript
            self.narrationAudio = [:]
            self.narrationDurations = [:]
            self.frameDataURLCache = [:]
            self.player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            self.selectedStepID = self.steps.first?.id
            self.theme = project.theme ?? BrandTheme()
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                let natural = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let oriented = natural.applying(transform)
                self.videoNaturalSize = CGSize(width: abs(oriented.width), height: abs(oriented.height))
            }
            self.deviceKind = project.deviceKind ?? DeviceKind.detect(
                width: Int(self.videoNaturalSize.width),
                height: Int(self.videoNaturalSize.height)
            )
            if let briefingPath = project.briefingPath {
                let briefingFile = URL(fileURLWithPath: briefingPath)
                if let text = try? Briefing.extractText(from: briefingFile) {
                    self.briefingURL = briefingFile
                    self.briefingText = text
                } else {
                    self.pipelineNotice = "The project's briefing PDF (\(briefingFile.lastPathComponent)) couldn't be read — re-attach it from the Project menu."
                }
            } else {
                // No briefing in THIS project — clear any leftover from the
                // previous one, or its text keeps grounding the AI prompts.
                self.briefingURL = nil
                self.briefingText = ""
            }
            self.statusMessage = "Opened \(url.lastPathComponent) (\(self.steps.count) steps)."
            await self.refreshAllThumbnails()
        }
    }

    // MARK: Helpers

    static func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = Int(seconds)
        let fraction = Int((seconds - Double(total)) * 10)
        return String(format: "%d:%02d.%d", total / 60, total % 60, fraction)
    }
}
