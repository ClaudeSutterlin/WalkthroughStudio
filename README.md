# Walkthrough Studio

> 🤖 **This is an AI-generated project.** The entire app was designed and
> written by Claude (Anthropic) pair-programming with a human, from a one-page
> spec to the code, tests, and docs you're reading. It's also built to be
> **extended by AI**: [CLAUDE.md](CLAUDE.md) is the onboarding guide for the
> next contributor's coding agent — the build/verify loop, the architecture,
> the environment landmines, and a reviewed backlog. Point your agent at it.

A native macOS app (SwiftUI) that turns **one recorded product walkthrough**
into three polished, on-brand deliverables:

- **A — Narrated video**: the recording with a clean ElevenLabs voice-over
  replacing the original narration, exported as H.264 `.mp4` + `.srt` captions.
- **B — Step screenshots + copy**: one clean frame per step with title/body in
  your product's voice, exported as slug-named PNGs plus a copy-paste-ready
  `tutorialSteps` payload for a web tutorial page.
- **C — Branded App Store screenshots**: each screen wrapped in a branded
  marketing frame (device mockup, warm gradient, wordmark, serif headline) at
  the App Store sizes for the recording's device (iPhone or iPad).

## Build & run

```sh
git clone https://github.com/ClaudeSutterlin/WalkthroughStudio.git
cd WalkthroughStudio
./build-app.sh
open "build/Walkthrough Studio.app"
```

Or open `Package.swift` in Xcode and run the `WalkthroughStudio` scheme.
(`swift run` also works — the binary embeds its Info.plist — but the `.app`
bundle is the reliable path for the speech-recognition permission prompt.)

Requires macOS 14+, Xcode 15+. No third-party dependencies.

## No recording? Capture a website

**Capture a Website…** (on the start screen, the New Project sheet, and the
Project menu) builds the recording for you. Give it a base URL and describe
the video you want — e.g. *"a step-by-step tutorial of the onboarding flow"* —
and a Claude vision agent drives a real browser:

1. It loads the page, looks at a screenshot plus an inventory of everything
   clickable, and plans the tour (grouped into steps, each with draft
   narration).
2. Every click, scroll, and keystroke is rendered into a synthetic screen
   recording with an animated cursor and click pulses. Mobile captures
   (the **iPhone** preset, 1170×2532 with a pristine baked-in status bar) look
   like a phone; **Desktop** records a full 2560×1600 browser viewport.
3. When the tour is covered, the narration scripts and all step copy are
   written *from the step screenshots* (plus the agent's notes and your
   briefing), the ElevenLabs voice-over is synthesized, and you land on the
   normal review screen — same editing, same three exports.

The agent stays on the site you point it at, uses placeholder data in forms
(put test credentials in the description if a flow needs a login), avoids
destructive actions, and treats page text as content to document — not as
instructions. Watching it work: the processing screen shows the live page as
it browses. Requires an Anthropic API key.

## Workflow (wizard)

1. **New Project** — drop in a `.mov`/`.mp4` screen recording, an optional
   project briefing (PDF, Word, Markdown, text…) that grounds every word the
   AI writes, and pick what it was recorded on (auto-detect / iPhone / iPad /
   computer — this drives the device bezel, status-bar cleanup, and App Store
   sizes). The pipeline then runs automatically: scene detection → on-device
   transcription → transcript-aware step refinement → Claude drafts
   titles/body/alt/slide headlines → Claude polishes narration scripts →
   ElevenLabs synthesizes the voice-over. Stages that need a missing API key
   are skipped with a banner explaining what to do.
2. **Review** — one card per step: frame, title, body, narration script
   (play / re-record per step), and slide headline/subhead — all editable
   inline. **Run AI** re-drafts everything from the transcript after edits.
3. **Export** — three buttons at the bottom:
   - **Export Video…** opens a sheet: as-recorded or framed 16:9 (1920×1080
     branded canvas whose headline/subhead follow each step), pacing and
     audio options, and the destination — `.mp4` + `.srt` captions.
   - **Tutorial Steps…** — slug-named PNGs + `tutorialSteps.ts`/`.json`/`.md`
     for `public/pilot/`.
   - **App Store Shots…** — both sizes for the recording's device (iPhone
     6.9″/6.5″, iPad 13″/12.9″), each screen in the branded frame.

**Status-bar cleanup:** by default exports replace the recording's status bar
with Apple's pristine marketing bar (9:41, full signal/battery, Dynamic Island
on iPhone) by extending the app's own background over the band — layout
untouched, notification banners scrubbed. Crop-it-off and as-recorded modes
are available in the frame design editor.

**Design customization:** Project ▸ Customize Frame Design… edits the branded
frames' colors, background (color or image), wordmark/logo, and headline font —
applied live to slide previews and every export, and saved with the project.
For full redesigns, Project ▸ Edit HTML Templates… copies the frame templates
(plain HTML/CSS with a small placeholder contract) plus a `CUSTOMIZING.md`
Claude Code guide into Application Support; the app prefers your edited copies
automatically.

**Advanced mode** (toolbar) opens the full tabbed studio for corrections:
frame-by-frame step re-timing, split/merge at the playhead, per-step frame
picking, the live branded-slide preview, and the raw export tab. "Done"
returns to the review screen.

Projects (steps, timings, copy, transcript) save/load as `.walkstudio.json`
via the toolbar Project menu.

## Settings (⌘, or the gear)

A first-run setup screen collects both API keys (skippable — the pipeline
degrades gracefully and explains what's missing). Everything is editable
later in Settings:

- **Anthropic API key** + model (`claude-sonnet-5` default, `claude-opus-4-8`
  for best quality). An optional **custom endpoint** routes Claude requests
  through any Anthropic-compatible gateway (e.g. an AWS Bedrock proxy) — the
  app calls `<base>/v1/messages` with the standard Messages API shape; blank
  means `api.anthropic.com`. A free-text **model ID override** covers gateway
  model naming (Bedrock uses an `anthropic.` prefix).
- **ElevenLabs API key**, voice id (defaults to "Rachel", a neutral warm stock
  narrator from the Voice Library), and an optional model override — by default
  the current recommended high-quality TTS model is discovered from the
  ElevenLabs models API at run time.
- Transcription locale.

API keys are stored in the macOS **Keychain**, never on disk.

## Architecture notes

- `StudioViewModel` owns the single source of truth: an ordered list of
  `WalkthroughStep`s (timestamp, frame, transcript, copy). All three outputs
  derive from it.
- `SceneDetector` — frame sampling + 64-bit dHash, rising-edge boundaries,
  "settled frame" selection (lowest local motion) per step.
- `SpeechTranscriber` — chunked on-device `SFSpeechRecognizer` behind a
  `Transcribing` protocol, so WhisperKit can be swapped in later without
  touching the rest of the app.
- `BrandedRenderer` — offscreen WKWebView rendering the **verbatim** HTML/CSS
  template from the web pipeline (`Resources/slide-template.html`), snapshotted
  and normalized to exact App Store pixel sizes.
- `VideoService` — `AVAssetImageGenerator` frame extraction,
  `AVMutableComposition` audio swap (narration clips clamped so they never
  overlap), `AVAssetExportSession` H.264 export, SRT generation.
- ElevenLabs audio is requested as raw PCM and wrapped in a WAV container so
  AVFoundation composites it without an intermediate re-encode.
- Web capture: `WebCaptureSession` (offscreen WKWebView + injected-JS element
  inventory and actions) is driven by `CaptureDriver`, which asks a
  `CaptureExploring` implementation (`ClaudeExplorer` — vision over the
  Messages API) for one JSON decision per turn and renders every action into
  a movie via `CaptureRecorder` (AVAssetWriter, animated cursor, optional
  baked-in iPhone status bar). Steps are seeded from the agent's own step
  marks — no scene detection needed — and `CaptureCopywriter` writes scripts
  + copy from the per-step screenshots.

## Testing

A hidden headless self-test exercises the whole pipeline (scene detection,
layout/geometry probes, branded renders, narrated + framed exports, and the
web-capture stack against a local HTML fixture with a scripted agent) without
touching the network:

```sh
swift build
swift scripts/make-test-video.swift /tmp/test-walkthrough.mov   # synthetic 3-scene recording
./.build/debug/WalkthroughStudio --selftest /tmp/test-walkthrough.mov /tmp/selftest-out
```

It prints one `selftest: … OK` line per probe and ends with `SELFTEST PASS`,
dumping the rendered PNGs/videos into the output folder for eyeballing.

## Extending it (with your AI)

Read [CLAUDE.md](CLAUDE.md) — or better, have your coding agent read it. It
documents the selftest-driven verify loop, where each subsystem lives, the
macOS/AVFoundation gotchas that already cost debugging time once, and a
code-reviewed backlog of known limitations that make good first tasks. The
branded frames are plain HTML/CSS with a small placeholder contract:
**Project ▸ Edit HTML Templates…** in the app materializes editable copies
plus a CUSTOMIZING.md guide written for exactly that workflow.

## Non-goals (per spec)

- Doesn't drive the iOS Simulator (that's the Fastlane/Maestro pipeline).
- Doesn't render the destination web tutorial page — it only produces its content.
- Lives in its own repo; not part of the web app.

## License

MIT — see [LICENSE](LICENSE).
