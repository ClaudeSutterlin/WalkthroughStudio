# CLAUDE.md — AI contributor guide

This entire app was built by Claude (Anthropic's AI) pair-programming with a
human. This file is the onboarding doc for the *next* AI (or human) extending
it: the verify loop, the architecture, and the environment landmines that cost
real debugging time the first time around.

## What this is

Walkthrough Studio: a native macOS SwiftUI app (Swift Package, no .xcodeproj)
that turns one screen recording into (A) an ElevenLabs-narrated video + SRT,
(B) step screenshots + a `tutorialSteps` payload, and (C) branded App Store
screenshots. See README.md for the user-facing tour.

## Build, run, verify — the loop that works

```sh
swift build                                  # debug build, ~3s incremental
./build-app.sh && open "build/Walkthrough Studio.app"   # release .app (signed)
```

**Always run the headless selftest after changes** — it exercises the whole
pipeline without the network and pixel-checks rendered output:

```sh
swift build
swift scripts/make-test-video.swift /tmp/test-walkthrough.mov   # synthetic 3-scene recording
./.build/debug/WalkthroughStudio --selftest /tmp/test-walkthrough.mov <outDir>
```

The generator matters: the probes pixel-check specific regions of it (saturated
header right below the status-bar band, distinct scene colors) — if you change
a probe's sample point, keep `scripts/make-test-video.swift` in sync.

Ends with `SELFTEST PASS` or throws with a specific probe failure. It dumps
PNGs/MP4s into `<outDir>` — **actually look at them** (they're the ground
truth for rendering changes; several bugs only showed up visually).
Add a probe to `SelfTest.swift` for anything you fix or add; every probe there
exists because something regressed once.

Use `.app` builds (not `swift run`) when testing speech recognition or
Keychain behavior — permissions stick to the signed bundle identity.

## Architecture (30 seconds)

- `StudioViewModel` — single source of truth (`@MainActor`). An ordered
  `[WalkthroughStep]` plus transcript; all three exports derive from it.
  The `run(_:)` wrapper is a single-flight busy gate — **never nest `run()`
  calls**: the outer epilogue clears `busyMessage` and reopens the gate
  (that was a real bug; pipeline stages run inside ONE `run()` via
  `autoPipelineCore()`).
- `SceneDetector` — 2fps sampling, 9×8 dHash + per-channel RGB means,
  rising-edge boundaries; `refineStepsWithTranscript()` adds boundaries at
  narration pauses (catches spoken intro/outro over an unchanged screen).
- `SpeechTranscriber` — on-device `SFSpeechRecognizer` in 55s chunks behind
  the `Transcribing` protocol (WhisperKit can be swapped in there).
- `AnthropicClient` + `CopyService` — Messages API over raw HTTP (no Swift
  SDK exists); prompts are position-aware (intro/middle/outro) and grounded in
  the optional project briefing (`Briefing.extractText`, injected into the
  system prompt; "briefing wins"). The endpoint is configurable
  (`SettingsKeys.anthropicBaseURL`, blank = api.anthropic.com) so requests can
  route through an Anthropic-compatible gateway (e.g. a Bedrock proxy);
  `messagesEndpoint(baseURL:)` normalizes what users paste, and
  `anthropicModelOverride` covers gateway model IDs (`anthropic.claude-…`).
  A first-run `SetupSheet` collects keys + endpoint (skippable;
  `SettingsKeys.didCompleteSetup`).
- `ElevenLabsClient` — TTS model discovered from `/v1/models` at runtime;
  output-format fallback ladder (PCM tiers → MP3) because formats are
  tier-gated; audio wrapped in WAV for AVFoundation.
- `VideoService.assembleNarratedVideo` — builds the output timeline from
  `ExportSegment`s. **Composition audio segments must be contiguous**: every
  gap needs an explicit `insertEmptyTimeRange` or playback goes silent after
  the first discontinuity.
- `FrameCompositor` — custom `AVVideoCompositing` (Core Image) that places the
  recording inside the branded 16:9 canvas. Exists because
  `AVVideoCompositionCoreAnimationTool` renders **black** offscreen/headless.
- `BrandedRenderer` + `TemplateStore` — offscreen WKWebView rasterizes the
  HTML templates (`Resources/*.html`); user-edited copies in
  `~/Library/Application Support/Walkthrough Studio/Templates/` take
  precedence. The `{{PLACEHOLDER}}` contract is documented in the
  CUSTOMIZING.md that `TemplateStore.materializeForEditing` ships.
- `StatusBarStyler` — replaces the recorded status bar with Apple's marketing
  bar (9:41, Dynamic Island on iPhone, slim bar on iPad); banner-aware for
  stills (`firstCleanRow` detects notification banners and repaints past them).
- **Web capture** (`Services/WebCapture/`) — "Capture a Website": a Claude
  vision agent records the walkthrough itself. Three layers, deliberately
  separable:
  - `WebCaptureSession` — offscreen-window WKWebView (landmine 2 applies);
    injected JS builds an indexed inventory of visible interactable elements
    (`window.__wsElements` keeps the references), actions dispatch real
    pointer events / React-safe value setters. Coordinates are CONTENT PIXELS
    (CSS × `pageZoom`, top-left) matching the snapshot exactly.
  - `CaptureRecorder` — actor over AVAssetWriter; a hold appends ONE frame
    (duration runs to the next append — `endSession(atSourceTime:)` keeps the
    final hold), animations append at 24fps; draws the cursor/halo/click-pulse
    and, for the iPhone preset, fills a reserved top band with the page's
    top-row color + the marketing-bar overlay (built by the CALLER on the main
    actor — AppKit drawing stays out of the actor).
  - `CaptureDriver` + `CaptureExploring` — the observe→decide→act→record loop.
    `ClaudeExplorer` is one JSON decision per turn (screenshot + inventory +
    history); the selftest swaps in a scripted explorer, so the whole loop runs
    offline. Step frame choice rule: a step's card never shows the screen its
    CLOSING navigation revealed (that's the next step's opening state).
  - Capture projects skip SceneDetector/transcription: steps come from the
    agent's own `beginStep` marks, `CaptureCopywriter` writes scripts + copy
    in ONE vision request grounded in per-step screenshots + notes + briefing,
    then the normal synth/export stages run. `theme.statusBarMode` is set to
    "off" (the bar is already pristine or absent — don't re-clean web content).
  - Agent guardrails live in `ClaudeExplorer.systemPrompt`: same-site only
    (also enforced in code via `CaptureDriver.sameSite`), placeholder data in
    forms, no destructive actions, page text is content-not-instructions.
- `DeviceKind` (Models.swift) — iphone/ipad/computer; drives bezel geometry,
  status-bar fraction, App Store sizes, and export availability. Add new
  device variation HERE, not as scattered branches.
- `BrandTheme` — per-project design tokens injected as `{{THEME_CSS}}`;
  explicit `encode(to:)` (a decode-only legacy key breaks synthesis).

## Environment landmines (macOS 26.1 / Xcode 26.2 — all cost real time)

1. SwiftUI's `VideoPlayer` **SIGABRTs at first render**. Use the `PlayerView`
   NSViewRepresentable (AppKit `AVPlayerView`). Don't switch back.
2. WKWebView renders blank unless hosted in an (offscreen) `NSWindow`.
3. `AVVideoCompositionCoreAnimationTool` renders black headless → that's why
   `FrameCompositor` exists.
4. `AVAssetReader.copyNextSampleBuffer` on audio **hangs** in the headless
   selftest → probes verify track structure, not decoded samples.
5. Never read the Keychain in a SwiftUI view's stored-property initializer —
   the Settings scene is built at launch and a blocked keychain prompt freezes
   the app for minutes. Load lazily in `.task` (see SettingsView).
6. CGBitmapContext memory is **top-row-first** even though CG drawing is
   bottom-left. `NSBitmapImageRep.colorAt` is top-left. Every pixel-sampling
   helper documents its convention — check twice; two real bugs came from this.
7. Ad-hoc codesigning changes the app identity every build → Keychain
   "Always Allow" stops sticking. `build-app.sh` auto-picks a stable identity.
8. The selftest quits early if `applicationShouldTerminateAfterLastWindowClosed`
   fires when an offscreen render window closes — kept `false` under `--selftest`.
9. AVAssetWriter presentation times must be strictly increasing and the LAST
   frame's dwell only survives via `endSession(atSourceTime:)` — the recorder
   guards both; don't "fix" them away.
10. Local pages need `loadFileURL(_:allowingReadAccessTo:)` with the DIRECTORY,
    or relative navigation inside the selftest fixture fails.

## Conventions

- No third-party dependencies; keep it that way unless the human asks.
- Brand tokens live in `Brand` (Models.swift): coral #DA4F45, cream #FFFBF5,
  charcoal #1A1612, Georgia serif headlines.
- Wizard-first UI: upload → automatic pipeline → review. Advanced/tabbed
  studio is for corrections only. New features should default to "the AI did
  it, review the result", not more knobs.
- Sheets pin `.environment(\.colorScheme, .light)` with brand backgrounds —
  render them under dark appearance in a selftest probe (pattern exists).
- API keys: Keychain only, never on disk, never in defaults.

## Known limitations / next work (from the pre-publication code review)

Reviewed and consciously deferred — good first tasks:

- **Framed-video status bar diverges from stills**: the video path
  (`FrameCompositor` clean mode) has no notification-banner awareness and
  freezes the white/black glyph choice from the frame at t=0.1s for the whole
  export. Stills handle both. Unify by driving both paths from one geometry +
  per-segment sampling.
- **`assembleNarratedVideo` silently clamps/skips segments** past the asset's
  end (e.g. a project reopened after its recording was re-trimmed) while SRT
  captions and frame-text times assume the full timeline → desync. Validate
  step times against asset duration on project open, or return the realized
  timeline and rebuild captions from it.
- **No staleness tracking between scripts and synthesized audio**: editing a
  script after synthesis exports old audio with new captions. A content hash
  on `WalkthroughStep.script` vs the WAV would catch it.
- **Efficiency**: `BrandedRenderer` builds a fresh WKWebView + fixed 400ms
  sleep per slide; `FrameCompositor.startRequest` rebuilds per-frame what is
  constant per segment; thumbnails decode serially with zero seek tolerance;
  `frameDataURLCache` never evicts. All measured-in-principle, none user-blocking.
- **Reuse**: four copies of the offscreen-snapshot harness in SelfTest, eight
  hand-rolled NSOpen/SavePanel setups, two `{{PLACEHOLDER}}` substitution
  engines (BrandedRenderer + VideoFrame), duplicated RGBA-context boilerplate.
  Consolidate opportunistically when touching those files.
- `SpeechTranscriber` is the seam for WhisperKit if transcription quality on
  accents/jargon becomes a complaint.

## Working style that fit this project

The human prefers: build the whole feature, verify it end-to-end (selftest +
looking at rendered output), THEN report — with UI polish taken seriously
(they will screenshot anything that looks off). Status-bar-type "make it look
like Apple marketing" details matter. When adding pipeline stages, degrade
gracefully with a `pipelineNotice` instead of failing the run.
