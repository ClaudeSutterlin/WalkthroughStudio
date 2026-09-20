# Onboard to a Codebase: architecture and build plan

Status: planning complete and revised on 2026-09-19 after the human's decisions (section 15); build started at M1. This document is the hand-off for the
AI builder sessions that implement the feature. Read it with USER-STORIES.md
(what to build and how to accept it) and BUILD-LOG.md (where the build is).

How this document was produced: three independent architecture proposals were
written from different angles (reuse-first, agent-first, experience-first),
scored by three judges (feasibility against this codebase, onboarding-engineer
experience, risk and cost), synthesized into one design, and then reviewed by a
completeness critic. Every judge finding marked fatal is closed in the design
below, and the critic's findings are listed in section 11 with their resolution.

Rules for builders:
- Milestone order is build order. M3 (player on a fixture package) precedes all
  fleet code on purpose. Do not reorder without a BUILD-LOG entry saying why.
- The package directory layout (section 2) and the anchor grammar (2.2) are the
  contract between milestones. Change them only in M2, before consumers exist.
- Before coding M5 or M6, re-read the claude-api skill (raw HTTP shapes in its
  curl reference) and verify every request field named in section 4.2; the API
  drifts and this document is a snapshot as of 2026-09-19.
- Every milestone ends with its probes green in `--selftest-onboarding`, the
  existing `--selftest` still green, the output folder inspected by eye, and a
  BUILD-LOG entry. This Linux planning environment cannot compile Swift; a
  session that cannot run the selftest records "not verified".

## Executive summary

The final architecture takes the experience-first proposal as its base (the weighted winner at 8.0 feasibility, 8.5 experience, 7.0 risk) and grafts the agent-first proposal's evidence discipline and the reuse-first proposal's shared timeline math onto it. "Onboard to a Codebase" becomes a second SwiftUI scene, Window("Onboarding"), opened from the app's first CommandMenu through the openWindow environment action and driven by an OnboardingViewModel that never touches StudioViewModel.run(), so the walkthrough studio stays usable during a multi-hour run. Everything the feature produces lives in one self-contained package directory whose contract is a single Anchor grammar (code:path@sha7#La-Lb, video:id#t=, doc:id#slug, diagram:id#node, trace:id#hopN, fact:id) plus a [[anchor]] citation syntax; every cross-link in docs, diagrams, transcripts, chat replies and the hub is that one string, resolved by one LinkRouter and validated by one probe. The research fleet is a native Swift tool-use loop over the extended raw-HTTP AnthropicClient (typed content blocks, strict tools, hand-rolled SSE, prompt caching, typed retries with backoff) behind an LLMTransport seam whose fixture implementation replays recorded turns, so the headless selftest never touches the network. Research agents cannot write prose directly: they emit Facts with Evidence through an emit_fact tool that rejects anchors that do not resolve at the pinned SHA and stores the cited excerpt at read time; verifier units refute with counter-evidence, and registers, diagrams, traces and video scripts are projections of the fact store plus a composer pass whose claims must cite facts. Videos are manufactured, never recorded: an agent-authored script of scenes and shots is rendered per shot to 1920x1080 stills through BrandedRenderer, narrated per shot through a Narrating protocol (ElevenLabs with-timestamps when the tier allows, a ToneNarrator offline), written to a silent stills MP4 by a new AVAssetWriter-based StillsVideoWriter, and muxed by the unchanged VideoService.assembleNarratedVideo using timeline math extracted from exportNarratedVideo into VideoService.timeline so both paths share one regression guard. transcript.json, coderefs.json, chapters.json, captions.srt, captions.vtt and a separate chapters.vtt are written by one TranscriptBuilder from the same shot timeline, so narration segments and on-screen intervals share a shotId and cannot disagree, and timingSource records whether word timing came from the provider or from the sentence estimate. The player is a three-pane window (hub navigator, stage, companion) in which the AppKit PlayerView's periodic time observer drives an "On screen now" card, any chip click docks the video as a mini-player and "Back to video" returns to the same t, and CodeView is NSTextView-backed and reads files at the pinned SHA. The playback agent's request has a cache-stable prefix (rules, package digest, this video's chapters, tools) and a volatile block at time t containing the narrated-so-far segments, the on-screen interval with the highlighted source inlined, the shot's facts with evidence, and the coming-up sentences marked as not yet narrated; replies stream over SSE and cite with [[anchor]] chips. Resumability is per unit and per turn: checkpoint.json is rewritten atomically after every unit state change, agent transcripts are appended per turn, facts are appended inside the tool call, audio and stills are content-hashed, and WorkUnit.inputsHash gives staleness for free. Cost is bounded by a SpendMeter that prices every response, a run-level cap that ends the run as partial with a coverage report, depth presets with a smoke depth that fits one session, and two model-scoped prompt caches sized above the 1024-token minimum. The build order puts the player and cross-links on a generated fixture package before any fleet code (StillsVideoWriter moves into M1 to make that possible), and the milestone table in BUILD-LOG.md is renumbered once, in the first coding session, to match this document. The fatal flaws named by the judges are closed: durations come from AVURLAsset rather than WAV header math, code panels render per shot rather than as 11,000-pixel snapshots, the menu opens the window through openWindow rather than NotificationCenter, the terminate guard matches any --selftest* flag, chapters live in their own chapters.vtt, the trailing pad extends the last sentence instead of emitting blank cues, build and test execution is opt-in, and replayed emit_fact calls dedupe on (unitId, toolUseId). Bundling mermaid.min.js is the only dependency question, and a DiagramRendering protocol with a native SVG fallback keeps the diagram milestone buildable while the human decides.

## Contents

1. Components
2. Package data model (layout, anchor grammar, manifest, checkpoint, facts, scripts, sidecars)
3. Repository acquisition and survey
4. Fleet orchestration and resume
5. Video generation
6. Transcript and code-ref map
7. The interactive player
8. The playback agent
9. Verify loop for this feature
10. Decisions (ADR style)
11. Milestones (build order)
12. Risks
13. Third-party asks and open questions for the human
14. Critic findings and resolutions
15. Human decisions of 2026-09-19 and the Research Packet contract

## 0. Shape of the feature

One menu command, one package directory, one anchor grammar. The user picks a GitHub URL or a local clone in an OnboardSheet; a fleet of native Swift agents researches the pinned checkout and writes typed Facts; deterministic projectors and composer passes turn the fact store into diagrams, registers, traces and video scripts; a video pipeline renders stills, synthesizes narration, muxes MP4s and writes timestamped transcripts and code-ref maps; a three-pane window plays the package with a time-aware chat agent. Every stage writes to `<RepoName>.onboarding/` and can be resumed from it.

Path convention for this document: paths that start with `Sources/`, `scripts/`, `docs/` or `Support/` are relative to the repository root. New code goes under `Sources/WalkthroughStudio/Onboarding/` (model, runtime, units, projectors, video, chat) and `Sources/WalkthroughStudio/Views/Onboarding/` (SwiftUI). Existing files are extended in place.

## 1. Components

| Component | Status | Files | Responsibility |
|---|---|---|---|
| Onboarding scene + command | new | `Sources/WalkthroughStudio/WalkthroughStudioApp.swift`, `Sources/WalkthroughStudio/Views/Onboarding/OnboardingCommands.swift` | `Window("Onboarding", id: "onboarding") { OnboardingRootView() }` added beside the WindowGroup; `struct OnboardingCommands: Commands` with `@Environment(\.openWindow)` adds `CommandGroup(after: .newItem) { Button("Onboard to a Codebase...") }` in the File menu (Cmd-Shift-O; ON-1.1) that calls `openWindow(id: "onboarding")` and sets `OnboardingCoordinator.shared.pendingRequest = .newPackage`. ContentView's ImportView gets a third button and `projectMenu` an entry that call the same coordinator. No NotificationCenter bridge. |
| OnboardingCoordinator | new | `Sources/WalkthroughStudio/Onboarding/OnboardingCoordinator.swift` | Process-wide `@MainActor final class` holding the open `OnboardingViewModel` instances keyed by package URL, the recents list (`SettingsKeys.onboardingRecentPackages`), and `pendingRequest` consumed by OnboardingRootView on appear. |
| OnboardingViewModel | new | `Sources/WalkthroughStudio/Views/Onboarding/OnboardingViewModel.swift` | `@MainActor final class OnboardingViewModel: ObservableObject, BusyReporting`. Owns the `PackageStore`, the `FleetScheduler` task handle (`Task<Void, Never>?`), `stage: OnboardingStage`, `units: [WorkUnitRow]`, `notices: [OnboardingNotice]`, `spend: SpendSummary`, plus the `busyMessage/progress/statusMessage/errorMessage/lastExportURL` quartet. `start(request:)`, `pause()`, `resume()`, `cancel()`, `open(packageURL:)`, `regenerate(deliverableId:)`. Never calls `StudioViewModel.run()`. |
| BusyReporting + BusyStatusBar | extended | `Sources/WalkthroughStudio/Views/BusyStatusBar.swift`, `Sources/WalkthroughStudio/Views/ContentView.swift`, `Sources/WalkthroughStudio/StudioViewModel.swift` | `protocol BusyReporting: ObservableObject { busyMessage, progress, statusMessage, lastExportURL }`; `struct BusyStatusBar<R: BusyReporting>: View` extracted from `ContentView.statusBar`; StudioViewModel conforms; ContentView and OnboardingRootView both use it. |
| OnboardSheet | new | `Sources/WalkthroughStudio/Views/Onboarding/OnboardSheet.swift` | Modelled on NewProjectSheet (560 wide, Brand.cream, `.environment(\.colorScheme, .light)`): URL field or folder DropZone (`DropZone` becomes internal in M3; it is `private` in ContentView.swift today), optional commit SHA override, optional briefing file (reusing `Briefing.extractText`, stored as `manifest.briefingPath`, ON-2.9), output folder, depth picker (smoke, quick, standard, exhaustive), "Run the repository's build and tests" checkbox (default off, with a plain warning), spend cap, voice, pre-run estimate. Validates with `GitRunner.revParse` before enabling Start. |
| FleetProgressView | new | `Sources/WalkthroughStudio/Views/Onboarding/FleetProgressView.swift` | ProcessingView's backdrop (warm gradient, orbs, white card, Georgia title, VoiceBarsMark) with a dashboard card: stage rows from `OnboardingStage`, unit rows (kind, status, current tool call text, attempts), artifact counts, tokens and USD, Pause and checkpoint, Resume, Cancel, Open package so far. Dark-appearance probe. |
| OnboardingRootView + panes | new | `Sources/WalkthroughStudio/Views/Onboarding/OnboardingRootView.swift`, `HubNavigatorView.swift`, `StageView.swift`, `VideoPane.swift`, `PlaybackClock.swift`, `CodeView.swift`, `DocView.swift`, `DiagramView.swift`, `CompanionPanel.swift`, `ChatPanel.swift`, `PackageReviewView.swift`, `WalkthroughSchemeHandler.swift` | Three-pane NavigationSplitView (min 1280x800). See section 7. |
| Research Packet contract + validator | new | `docs/onboarding/PACKET.md`, `.claude/skills/onboarding-research/schema/*.json` (normative), `.claude/skills/onboarding-research/scripts/validate_packet.py` and `survey_repo.py` (with thin wrappers `scripts/validate-packet.py`, `scripts/survey-repo.py`), `Sources/WalkthroughStudio/Onboarding/Packet/PacketModels.swift`, `PacketValidator.swift`, `PacketImporter.swift` | The boundary between research and content (section 15). JSON Schemas are the normative contract; the Python validator is the reference implementation used by producers on any machine; `PacketValidator` is the Swift port the app runs on import (schema shape, anchor grammar, anchor resolution against `repo/` at the packet's SHA, orphan facts, coverage completeness). `PacketImporter` copies a validated packet into `<package>/packet/`, records `manifest.producer`, and pends every content unit. `--validate-packet <dir> <repo>` is a headless flag. |
| Research Packet producer skill | new | `.claude/skills/onboarding-research/SKILL.md` and its `templates/` | A Claude Code skill that, run inside any repository checkout, produces a Research Packet with the same fact, evidence, trace and coverage semantics as the in-app fleet. It is the first producer; the in-app fleet (M11) is the second. Its own test is the fixture repo. |
| Package model + Anchor | new | `Sources/WalkthroughStudio/Onboarding/Package/OnboardingModels.swift`, `Anchor.swift`, `PackageStore.swift`, `BuildLog.swift`, `FactStore.swift`, `BacklinkIndex.swift` | All Codable types with explicit `encode(to:)` and a leading `version` field (BrandTheme lesson). PackageStore does atomic writes (write `.tmp`, rename), directory layout, content hashes, open-time validation (repo/ matches headSHA, referenced files exist). BuildLog appends `build-log.md` lines and `build-log.jsonl` records. FactStore appends JSONL, dedupes on id, rebuilds `facts/index.json`. |
| GitRunner + RepoAcquisition | new | `Sources/WalkthroughStudio/Onboarding/Package/GitRunner.swift`, `RepoAcquisition.swift`, `Sources/WalkthroughStudio/Services/Keychain.swift` | `Process("/usr/bin/git")` off-main with timeouts: `clone` (full history into `repo-git/`), `worktree add repo/ <sha>`, `rev-parse`, `log --numstat`, `blame --line-porcelain`, `show <sha>:<path>`, `ls-tree`. Token from `Keychain.githubToken` (new account `github-token`) passed through a `GIT_ASKPASS` helper script in a private temp dir that echoes an environment variable; never on disk, never logged. Detects a missing git binary with a readable error. |
| Messages API client | extended | `Sources/WalkthroughStudio/Services/AnthropicClient.swift`, `Sources/WalkthroughStudio/Services/AnthropicMessages.swift`, `Sources/WalkthroughStudio/Services/SSEParser.swift`, `Sources/WalkthroughStudio/Services/LLMTransport.swift` | `complete`/`completeJSONArray`/`extractJSONArray` untouched (CopyService and jsonExtractionProbe depend on them). New: `MessagesRequest`, `MessagesResponse`, `ContentBlock` (text, tool_use, tool_result, thinking, redacted_thinking, unknown passthrough), `Message`, `ToolDefinition`, `StreamEvent`; `endpoint(path:)` generalizing `messagesEndpoint` for `/v1/messages`, `/v1/messages/count_tokens`, `/v1/models`; `AnthropicAPIError { status, type, message, retryAfter }`; `protocol LLMTransport { send, stream }` with `URLSessionTransport` and `FixtureTransport` (record and replay). `endpointProbe` cases stay green and gain the two new paths. |
| Agent runtime | new | `Sources/WalkthroughStudio/Onboarding/Agent/AgentRun.swift`, `RateLimiter.swift`, `SpendMeter.swift`, `ToolSchemas.swift`, `RepoTools.swift`, `PackageTools.swift` | `actor AgentRun`: one conversation per WorkUnit, append-only history persisted per turn, the tool loop, stop-reason branching, context cap and continuation handoff. `actor RateLimiter` (semaphore, jittered backoff, retry-after, circuit breaker). `actor SpendMeter` (usage to USD priced from the response's `model` field, which can differ from the requested model when server-side fallback routes a refusal; cap). Playback chat requests are metered too, logged with unitId `chat:<videoId>`, and the chat pane refuses with a notice once the cap is reached. Tools in section 4. |
| Fleet scheduler + work plan | new | `Sources/WalkthroughStudio/Onboarding/Fleet/FleetScheduler.swift`, `WorkPlan.swift`, `Depth.swift`, `Notices.swift` | DAG of `WorkUnit`s, TaskGroup bounded per lane (LLM 4, TTS 2, render 1), checkpoint after every state change, cancellation via `Task.cancel()` checked between turns, budget stop, `[OnboardingNotice]`. |
| Survey units (no LLM) | new | `Sources/WalkthroughStudio/Onboarding/Units/AcquireUnit.swift`, `InventoryUnit.swift`, `GitMiningUnit.swift`, `DependencyUnit.swift`, `BuildTestUnit.swift` | Deterministic Swift: tree and language inventory, dossier build (reuses `Briefing.extractText(from:maxCharacters:)`, a new parameter defaulting to today's 20,000-character cap so CopyService is unchanged; InventoryUnit passes nil), git mining (hotspots, ownership per directory, staleness, parallel implementations), manifest parsing (package.json, requirements.txt, pyproject, go.mod, Package.swift, Gemfile, pom.xml, Cargo.toml), opt-in build and test runner (allow-listed commands detected from manifests and CI, temp copy, 10 minute timeout, exit status and log tail stored). |
| Research units (LLM) | new | `Sources/WalkthroughStudio/Onboarding/Units/PlanUnit.swift`, `MapUnit.swift`, `LensUnit.swift`, `VerifyUnit.swift`, `RankPathsUnit.swift`, `TraceUnit.swift`, `DecisionUnits.swift` (ADR, debt, confessional), `ScriptPlannerUnit.swift`, `ComposeDocUnit.swift`, `Sources/WalkthroughStudio/Resources/OnboardingPrompts/*.md` | Role prompt + tool subset + max turns + context cap + post-validator per kind. Prompts live in a `.copy` resource folder so FixtureTransport keys line up with prompt names. |
| Projectors | new | `Sources/WalkthroughStudio/Onboarding/Projectors/DiagramProjector.swift`, `RegisterProjector.swift`, `TraceProjector.swift`, `HubProjector.swift`, `ScriptValidator.swift`, `MarkdownLite.swift` | Facts to Mermaid + links.json; facts to markdown with front matter (composer prose validated for `[[fact:...]]` citations); trace.json to trace.mmd and trace.md; manifest to hub/index.json and hub/index.html; script invariants. `MarkdownLite` is a hand-rolled markdown to HTML converter (headings with stable slugs, lists, tables, fenced code, links, front matter). |
| DiagramRendering | new | `Sources/WalkthroughStudio/Onboarding/Projectors/DiagramRendering.swift`, `NativeDiagramRenderer.swift`, `MermaidJSDiagramRenderer.swift`, `Sources/WalkthroughStudio/Resources/diagram-template.html` | `protocol DiagramRendering { func render(mmd: String, links: DiagramLinks) async throws -> (svg: String, png: CGImage) }`. `NativeDiagramRenderer` lays out the subset the projectors emit (boxes, grouped containers, arrows with labels, ER tables, sequence lifelines) and emits SVG with `id="<nodeId>"` on every node. `MermaidJSDiagramRenderer` (only if the human approves bundling mermaid.min.js) renders in WKWebView and extracts the SVG via `evaluateJavaScript`. Both preserve node ids, so the same probe covers both. |
| Narrating | extended | `Sources/WalkthroughStudio/Services/Narrator.swift`, `Sources/WalkthroughStudio/Services/ElevenLabsClient.swift`, `Sources/WalkthroughStudio/Onboarding/Video/AudioCache.swift` | `protocol Narrating { func narrate(_ text: String, context: NarrationContext) async throws -> NarrationClip }` where `NarrationClip { wav: Data, alignment: [CharTiming]? }`. `ElevenLabsNarrator` adds `synthesizeWithTimestamps` (POST `/v1/text-to-speech/{voice}/with-timestamps`, JSON body with `text`, `model_id`, `previous_text`, `next_text`; response `audio_base64` + `alignment.characters/character_start_times_seconds/character_end_times_seconds`) through the existing format ladder and `wavData`/`decodeToWAV`, falling back to `synthesizeWAV`. `ToneNarrator` = `SelfTest.sineWAV` made internal, duration words/2.5, synthetic alignment. `workingFormat` moves behind an actor; TTS calls run on a lane of 2. AudioCache keys WAVs by SHA-256(text + voice + model). |
| Scene renderer + templates | extended | `Sources/WalkthroughStudio/Onboarding/Video/SceneRenderer.swift`, `SyntaxTokenizer.swift`, `Sources/WalkthroughStudio/Services/Template.swift`, `Sources/WalkthroughStudio/Services/BrandedRenderer.swift`, `Sources/WalkthroughStudio/Services/BrandTheme.swift`, `Sources/WalkthroughStudio/Resources/scene-card-template.html`, `scene-code-template.html`, `scene-diagram-template.html`, `scene-terminal-template.html`, `scene-table-template.html`, `doc-template.html`, `hub-template.html` | `Template.render(name:values:rawKeys:)` is one single-pass substitution engine that HTML-escapes every value except keys listed in `rawKeys`, and escapes `{{` in escaped values (a Go or Jinja template in the target repo must survive). BrandedRenderer gains `renderReady(html:pixelWidth:pixelHeight:readyJS:)` (polls `window.__wsReady === true` up to 3 s instead of the fixed 400 ms) and `PersistentRenderer` (one WKWebView, template loaded once, `evaluateJavaScript` swaps content, snapshot). New templates are registered in `TemplateStore.templateNames` and documented in `customizingGuide`. BrandTheme gains code tokens (`codeBackground`, `codeForeground`, `codeFontCSS`, `syntaxKeyword`, `syntaxString`, `syntaxComment`, `lineHighlight`) added to `init(from:)`, `encode(to:)` and `css()`. |
| StillsVideoWriter + timeline | extended | `Sources/WalkthroughStudio/Services/StillsVideoWriter.swift`, `Sources/WalkthroughStudio/Services/VideoService.swift`, `Sources/WalkthroughStudio/StudioViewModel.swift`, `Sources/WalkthroughStudio/Onboarding/Video/VideoAssembler.swift`, `Captions.swift`, `TranscriptBuilder.swift` | `StillsVideoWriter.write(frames: [(image: CGImage, hold: Double)], size: CGSize, fps: Int, to: URL)` ported from `scripts/make-test-video.swift`. `VideoService.timeline(steps:durations:policy:) -> Timeline` extracted from `exportNarratedVideo(to:)` lines 675-696 and used by both paths. `Captions.srt/vtt/chaptersVTT` (splitSentences, timestamp, wrap made internal). TranscriptBuilder in section 6. |
| Playback agent | new | `Sources/WalkthroughStudio/Onboarding/Chat/PlaybackAgent.swift`, `ChatSession.swift`, `CitationParser.swift` | Section 8. |
| Review, staleness, export | new | `Sources/WalkthroughStudio/Onboarding/Review.swift`, `Staleness.swift`, `HubExporter.swift`, `Sources/WalkthroughStudio/Resources/OnboardingHub/hub.css`, `hub.js` | review/status.json state machine, staleness from `WorkUnit.inputsHash` plus manifest fact edges, regenerate-one for any deliverable kind, `restore(factId:note:)` that appends a reviewer verdict line to `facts/<unit>.jsonl` and re-pends dependents exactly like a correction (ON-10.3), static site export (excludes `units/`, `chat/`, `repo-git/`). |
| Settings + Keychain | extended | `Sources/WalkthroughStudio/Views/SettingsView.swift`, `Sources/WalkthroughStudio/Views/SetupSheet.swift`, `Sources/WalkthroughStudio/Models.swift`, `Sources/WalkthroughStudio/Services/Keychain.swift` | New `SettingsKeys`: `onboardingOutputDir`, `onboardingPlannerModel` (default `claude-opus-5`), `onboardingWorkerModel` (default `claude-sonnet-5`), `onboardingEffort`, `onboardingMaxParallel` (4), `onboardingSpendCapUSD` (25), `onboardingDepth`, `onboardingRunBuild` (false), `onboardingGatewayCompat`, `onboardingRecordFixtures`, `onboardingEditorCommand`, `onboardingRecentPackages`. `Defaults.anthropicModels` gains `claude-opus-5`. GitHub token SecureField loaded in `.task`, never in an initializer. |
| Selftest for the feature | extended | `Sources/WalkthroughStudio/WalkthroughStudioApp.swift`, `Sources/WalkthroughStudio/SelfTest.swift`, `Sources/WalkthroughStudio/SelfTestSupport.swift`, `Sources/WalkthroughStudio/SelfTestOnboarding.swift`, `Sources/WalkthroughStudio/Onboarding/Fixtures/FixturePackage.swift`, `scripts/make-fixture-repo.sh`, `Sources/WalkthroughStudio/Resources/OnboardingFixtures/`, `Package.swift` | `--selftest-onboarding <fixtureRepo> <outDir> [--probe <name>]`; `applicationShouldTerminateAfterLastWindowClosed` returns false when any argument `hasPrefix("--selftest")`; `SelfTestSupport` holds `pixel(in:x:y:)` (top-left sampling, CLAUDE.md landmine 6), `sineWAV`, and `runProcess`/`runGit` (concurrent pipe drains, timeout); the planned `snapshot(view:size:appearance:)` that would replace the five duplicated NSHostingView harnesses (newProjectSheetProbe, setupSheetProbe, exportSheetProbe, processingViewProbe, uiProbe) is DEFERRED until the onboarding sheet probes need it (S2 review) and does not exist yet; `SelfTestOnboarding.swift` is `extension SelfTest { static func runOnboarding(fixtureRepo:outDir:only:) }` in its own file so sessions read only what they need. `Package.swift` adds one `.copy("OnboardingResources")` rule for `Sources/WalkthroughStudio/OnboardingResources/{hub,fixtures,prompts}` (a sibling of `Resources/`, so no path is covered by two rules; `.process` would flatten directories). |
| Planning docs | extended | `docs/onboarding/ARCHITECTURE.md`, `docs/onboarding/BUILD-LOG.md`, `docs/onboarding/USER-STORIES.md`, `CLAUDE.md`, `README.md` | ARCHITECTURE.md is this document. BUILD-LOG milestone table rewritten once to section 9's list. CLAUDE.md verify loop gains the onboarding invocation. |

## 2. Package data model

#### 2.1 Directory layout

Package root: `<onboardingOutputDir>/<RepoName>.onboarding/` (the user picks the folder in OnboardSheet; the default is `~/Documents/Onboarding`). The package is the only source of truth and is re-openable mid-run.

```
<RepoName>.onboarding/
  manifest.json              OnboardingManifest (section 2.3)
  checkpoint.json            WorkPlan (section 2.4), rewritten atomically on every unit state change
  build-log.md               append-only, human readable
  build-log.jsonl            one JSON object per API request (section 4.7)
  repo-git/                  git clone with full history (mining); absent when the user supplied a local clone
  repo/                      git worktree pinned at headSHA; all tools and the code view read here only
  dossier/                   module-map.json, readme-digest.md, docs/*.md (in-repo documents via Briefing.extractText, no cap)
  packet/                    the Research Packet (section 15): packet.json, facts.jsonl, traces/, inventory.json,
                             history.json, dependencies.json, paths.json, decisions.json, glossary.json, coverage.json,
                             drafts/. Written by whichever producer made it; the in-app fleet writes here too.
  facts/<unitId>.jsonl       in-app fleet only: append-only Fact lines as they are emitted, merged into packet/facts.jsonl
                             at unit completion; facts/index.json (id -> file, line) rebuilt on open
  units/<unitId>/            transcript.jsonl (append-only agent history), result.json, cmd/<n>.txt
  diagrams/<id>.mmd          Mermaid source; <id>.links.json; <id>.svg (node ids preserved); <id>.png
  docs/<docId>.md            markdown with front matter; docs/<docId>.html rendered by MarkdownLite
  traces/<traceId>/          trace.json, trace.mmd, trace.md
  videos/<videoId>/          script.json, audio/<shotId>-<hash>.wav, audio/<shotId>-<hash>.align.json,
                             frames/<shotHash>.png, stills.mp4, video.mp4, captions.srt, captions.vtt,
                             chapters.vtt, chapters.json, transcript.json, coderefs.json
  index/anchors.json         backlinks: anchor string -> [{kind, ref, label}]
  index/search.json          transcript sentences, doc paragraphs, anchors (for Cmd-K)
  hub/index.json             manifest projection with recommended order and minutes
  hub/index.html             rendered from hub-template.html; hub/assets/hub.css, hub.js
  review/status.json         per deliverable accept | fix | regenerate + note
  review/flags.json          contradictions raised by the playback agent
  review/bookmarks.json      {videoId, t, note}
  review/progress.json       read and watched state per deliverable
  review/rejected.json       refuted facts with the refuting evidence
  chat/<videoId>/<sessionId>.jsonl   playback conversations (append-only)
```

#### 2.2 Anchor grammar

One `enum Anchor: Codable, Hashable` in `Anchor.swift` with `init?(string:)`, `var string: String`, `var url: URL` and `static func parse(_:)`. The string form is the wire format in every JSON file, markdown link, diagram sidecar and chat citation.

| Form | Meaning | Parsing rule |
|---|---|---|
| `code:<path>@<sha7>#L<a>-L<b>` | file range at the pinned commit; `#L<a>` one line; no fragment = whole file; a trailing `/` on the path = directory | path is everything before the last `@` that is followed by 7 to 40 hex characters; fragment is everything after the first `#` after that |
| `video:<videoId>#t=<seconds>` or `video:<videoId>#c=<chapterId>` | a moment or a chapter start | seconds is a decimal; chapter resolves to `chapters.json[id].start` |
| `doc:<docId>#<slug>` | a `##` section; slug generated by MarkdownLite from the heading text | stable across regeneration because it is derived from the heading |
| `diagram:<diagramId>#<nodeId>` | a node in a .mmd; nodeId is the Mermaid node id | |
| `trace:<traceId>#hop<n>` | hop n of a trace | |
| `fact:<factId>` | a Fact record | |
| `commit:<sha>` | a commit in repo-git | |
| `cmd:<unitId>/<n>` | captured command output `units/<unitId>/cmd/<n>.txt` | |
| `issue:<n>` | a GitHub issue or pull request fetched by the optional IssuesUnit (`units/issues/result.json`) | only when the unit ran |
| `url:<https url>` | an external page cited by a lens agent through the server-side web search tool (evidence excerpt stored) | only when not behind a gateway |

In-app URL form (WKURLSchemeHandler and chips): `walkthrough://code/<path>?sha=<sha7>&L=<a>-<b>`, `walkthrough://video/<id>?t=<s>` or `?c=<chapterId>`, `walkthrough://doc/<id>#<slug>`, `walkthrough://diagram/<id>#<node>`, `walkthrough://trace/<id>#hop<n>`, `walkthrough://fact/<id>`, `walkthrough://cmd/<unit>/<n>`.

Citation syntax (agent replies, composer prose, doc chips): `[[<anchor>]]` or `[[<anchor>|<label>]]`. `CitationParser` turns them into chips; unresolvable anchors render as plain text with a warning glyph.

Resolution rules (`LinkRouter.resolve(_:) throws -> Destination`): `code:` resolves only against `git show <sha>:<path>` in `repo/` and the line range must exist; `sha7` must be a prefix of `manifest.headSHA` (so every anchor is self-validating against the package); `video:` requires the id in `manifest.deliverables` and `t <= duration + 0.5`; `doc:` requires the slug in `docs/<id>.html`; `diagram:` requires the node in `<id>.links.json`; `fact:` requires the id in `facts/index.json`. `emit_fact`, `emit_artifact`, the projectors and `hubLinkProbe` all call the same resolver.

#### 2.3 manifest.json (`OnboardingManifest`, version 1)

```
{ "version": 1, "repoURL": "...", "localClone": "repo", "headSHA": "<40 hex>", "defaultBranch": "main",
  "createdAt": "<ISO8601>", "depth": "smoke|quick|standard|exhaustive",
  "models": { "planner": "claude-opus-5", "worker": "claude-sonnet-5", "override": "" },
  "narration": { "voiceID": "...", "modelID": "eleven_v3", "timingSource": "provider-words|sentence-estimate" },
  "budget": { "capUSD": 25.0 },
  "spent": { "inputTokens": 0, "outputTokens": 0, "cacheReadTokens": 0, "cacheWriteTokens": 0, "usd": 0.0, "byModel": { "<model>": {...} } },
  "status": "planning|running|paused|complete|partial|failed",
  "unproduced": ["<deliverableId>"],
  "coverage": { "unreadDirs": [{ "path": "vendor/", "reason": "generated" }], "skippedChecks": [{ "check": "build", "reason": "runBuild off" }] },
  "deliverables": [ { "id": "video:arch-overview", "kind": "video|doc|diagram|trace|hub", "title": "...", "path": "videos/arch-overview", "minutes": 11, "order": 2, "status": "pending|built|stale|accepted|fix|rejected", "inputsHash": "<sha256>", "producedBy": "<unitId>" } ],
  "edges": [ { "from": "fact:F-map-src-7", "to": "doc:tech-debt" } ] }
```

Minutes: docs `words / 220`, videos `duration / 60`. `edges` are written by every projector and composer (each cited fact becomes an edge) and drive staleness.

#### 2.4 checkpoint.json (`WorkPlan`)

```
{ "version": 1, "sessionId": "<uuid>", "units": [
  { "id": "map-src-api", "kind": "map", "role": "worker", "inputs": ["inventory"], "params": { "dir": "src/api" },
    "status": "pending|running|done|failed|skipped", "attempt": 1, "maxTurns": 40,
    "inputsHash": "<sha256 of input outputs>", "outputHash": "<sha256 of outputs>", "outputs": ["facts/map-src-api.jsonl"],
    "usage": { "inputTokens": 0, "outputTokens": 0, "cacheReadTokens": 0, "usd": 0.0 },
    "startedAt": "...", "finishedAt": "...", "error": null } ] }
```

#### 2.5 Fact (`facts/<unitId>.jsonl`, one per line)

```
{ "id": "F-<unitId>-<toolUseId>", "kind": "component|interface|endpoint|dependency|dataEntity|dataField|flowHop|decision|risk|owner|hotspot|testCoverage|migration|config|integration|deployStep|incidentPattern|term|landmine|metric|buildResult",
  "subject": "src/api/orders_handler.py", "claim": "one sentence",
  "attributes": { ... kind specific, e.g. dataEntity: { "table": "users", "pii": true, "rows": "unknown", "retention": "unknown" } },
  "evidence": [ { "anchor": "code:src/api/orders_handler.py@ab12cd9#L12-L30", "excerpt": "<= 40 lines captured by read_file", "note": "..." } ],
  "confidence": 0.8, "producedBy": "map-src-api",
  "verdicts": [ { "verifier": "verify-03", "verdict": "confirmed|refuted|unknown", "reason": "...", "evidence": [...] } ],
  "status": "proposed|verified|refuted|unknown" }
```

`evidence` must be non-empty and every anchor must resolve, or `emit_fact` returns `is_error: true` with the reasons. `id` is derived from the unit id and the `tool_use` id so a replayed turn cannot duplicate a fact. Command evidence uses `cmd:` anchors.

#### 2.6 videos/<id>/script.json (`VideoScript`)

```
{ "version": 1, "videoId": "trace-checkout", "kind": "overview|domain|codeTour|devEnv|deploy|data|observability|security|integrations|migrations|trace|confessional",
  "title": "Critical path: Checkout", "summary": "one paragraph for the hub and the agent", "targetSeconds": 720,
  "scenes": [
    { "id": "s01", "type": "card", "variant": "tldr", "title": "TL;DR", "docAnchor": "doc:traces-checkout#summary",
      "shots": [ { "id": "s01a", "narration": "In the next twelve minutes ...", "onScreen": { "type": "card", "variant": "tldr", "title": "...", "bullets": ["..."] }, "factIds": [] } ] },
    { "id": "s02", "type": "code", "title": "Entry: POST /checkout", "docAnchor": "doc:traces-checkout#entry", "traceHop": 1,
      "shots": [ { "id": "s02a", "narration": "...", "onScreen": { "type": "code", "anchor": "code:src/api/checkout.py@ab12cd9#L30-L70", "highlight": [40, 58], "callout": "authz happens here, not in middleware" }, "factIds": ["F-trace-checkout-toolu_01"] } ] },
    { "id": "s03", "type": "diagram", "shots": [ { "id": "s03a", "narration": "...", "onScreen": { "type": "diagram", "diagram": "trace-checkout", "focusNodes": ["handler", "orders_repo"] }, "factIds": [] } ] },
    { "id": "s04", "type": "terminal", "shots": [ { "id": "s04a", "narration": "...", "onScreen": { "type": "terminal", "cmd": "cmd:buildtest/1", "highlightLines": [12, 14] }, "factIds": [] } ] },
    { "id": "s05", "type": "table", "shots": [ { "id": "s05a", "narration": "...", "onScreen": { "type": "table", "title": "...", "columns": ["..."], "rows": [["..."]] }, "factIds": [] } ] },
    { "id": "s09", "type": "card", "variant": "confessional", "title": "What scares me", "shots": [ ... ] } ] }
```

`ScreenState` is a Swift enum with exactly five cases (`card` with variants tldr, chapter, confessional; `code`; `diagram`; `terminal`; `table`), matching ON-6.3. Invariants enforced by `ScriptValidator` before any rendering: first scene is a `card` with variant `tldr` whose narration is at most 75 words (30 s at 2.5 words per second); projected total (words / 2.5 plus 0.6 s per shot plus card minimums) at most 900 s; every anchor resolves; `highlight` lies inside the anchor's range and the window is at most 40 lines; every scene has a `docAnchor` when a doc covers it; every `factId` exists and is not refuted; trace videos have one scene per hop with `traceHop` set.

#### 2.7 transcript.json, coderefs.json, chapters.json

Specified in section 6.

#### 2.8 Diagram sidecar (`diagrams/<id>.links.json`)

```
{ "version": 1, "diagramId": "c4-container", "nodes": { "api": { "anchor": "code:src/api/@ab12cd9", "owner": "Ada Lovelace (68% of commits)", "factIds": ["..."] } },
  "edges": { "api->db": { "protocol": "SQL over TCP", "contract": "code:db/schema.sql@ab12cd9", "factIds": ["..."] } } }
```

ERD nodes carry `attributes: { rows, retention, pii }` each `"unknown"` or a value with evidence.

#### 2.9 Doc front matter (`docs/<docId>.md`)

```
---
id: tech-debt
title: Technical debt register
minutes: 9
evidence: [map-src-api, gitmine, verify-03]
video: video:tech-debt#c=s01
order: 7
---
## Ranked items {video: video:tech-debt#c=s02} {code: code:src/repo/orders_repo.py@ab12cd9#L1-L40}
```

MarkdownLite reads the `{video: ...}` and `{code: ...}` heading suffixes into chips and strips them from the rendered heading; the slug is computed from the heading text without the suffixes. Ordering: the composer writes `code:` suffixes only, because docs are composed before scripts exist. Scripts then carry `docAnchor` values pointing at those slugs, and after the transcript unit a deterministic backlink pass in `HubProjector` injects the `video:` chips into the rendered HTML (and rewrites the markdown suffixes) from `chapters.json`. `LinkRouter` accepts `video:<id>#c=<chapterId>` while scripting when the chapter id exists in `script.json`, before `video.mp4` exists. Every `##` section carries a `video:` and at least one `code:` when applicable once the backlink pass has run (ON-4.11).

#### 2.10 Review files

`review/status.json`: `{ "<deliverableId>": { "state": "accept|fix|regenerate", "note": "...", "at": "..." } }`. `review/flags.json`: `[ { "videoId", "t", "segmentId", "anchor", "claim", "reason", "at" } ]`. `review/progress.json`: `{ "<deliverableId>": { "watchedSeconds": 272.4, "read": true } }`.

## 3. Repository acquisition and survey

1. `AcquireUnit`: runs `xcrun --find git` (a bare file-exists check on /usr/bin/git triggers the Command Line Tools dialog on Macs without them) and fails with a readable notice when absent. For a URL, `git clone <url> repo-git/` (token via GIT_ASKPASS for private repos; a failure without a token yields the notice "This repository needs a GitHub token; add one in Settings"), then `git worktree add ../repo <sha>` where sha is the default branch head (or the sha the user pasted). For a local folder, `repo-git/` is skipped, `manifest.localClone` holds the absolute path, and `repo/` is populated with `git archive <sha> | tar -x` (never a worktree, which would register itself in the user's `.git/worktrees`); `git show`, `log` and `blame` run with `-C <localClone>`. `git status --porcelain` and `git rev-parse --is-shallow-repository` are checked and a dirty tree or shallow clone produces a notice and a `coverage.skippedChecks` entry (uncommitted changes are not part of the package; history mining is limited on shallow clones). Clones run with `-c credential.helper=` so the system osxkeychain helper never prompts or persists the token. `manifest.headSHA` is recorded and `repo/` is read-only for every tool.
2. `InventoryUnit`: file tree with sizes, language stats by extension, entry point candidates (main files, route registrations, CLI entry points, Dockerfiles, CI workflows, infra folders), manifests. Writes `dossier/module-map.json` and `dossier/readme-digest.md` (README, CONTRIBUTING, docs/ folder digests, existing ADRs, CLAUDE.md-like files), and seeds `component` facts with directory anchors.
3. `GitMiningUnit`: `git log --numstat --format=...` over the full history: churn per file and directory, author share per directory (bus factor = smallest author set covering 50 percent of commits), files untouched for more than 365 days, same-basename files in two trees (parallel implementations), commit message keywords (revert, hotfix, fix, TODO, FIXME markers from grep). Emits `hotspot`, `owner`, `incidentPattern` facts with `commit:` and `code:` anchors and writes `units/gitmine/result.json` tables.
4. `DependencyUnit`: parses manifests into `dependency` facts (name, version, manifest anchor, license from the manifest or lockfile when present; EOL and CVE status is filled by the dependencies lens agent from model knowledge with explicit `"unknown"` allowed and never invented).
5. `IssuesUnit` (optional, M7): when the repository is on GitHub and a token or public access is available, fetches `GET /repos/{owner}/{repo}/issues?state=all` paginated (issues and pull requests, capped at 500), caches to `units/issues/result.json`, and emits `incidentPattern` facts with `issue:<n>` anchors; when unavailable it writes a `coverage.skippedChecks` entry instead of silence.
6. `BuildTestUnit` (only when `onboardingRunBuild` is on for this run): detects commands (`swift build`, `swift test`, `npm test`, `pytest`, `go test ./...`, `make test`, CI workflow steps), copies `repo/` to a temp directory, runs each with a 10 minute timeout and no elevated privileges, stores `units/buildtest/cmd/<n>.txt` (command, exit code, last 200 lines) and emits `buildResult` and `testCoverage` facts. When off or when nothing is detected, it emits an explicit `buildResult` fact with `status: "could-not-run"` and the reason, which the dev-environment video shows as a terminal card.

## 4. Fleet orchestration and resume

#### 4.1 Runtime choice

A native Swift manual tool-use loop over `POST /v1/messages` (raw HTTP), running inside the app process as actors. Rejected: a Claude Code CLI subprocess (needs a separate install and login, cannot use the Keychain key or the gateway settings the app already promises, no per-request usage, unstubbable offline, no per-turn checkpoint); Managed Agents (would upload the repository to a hosted sandbox, unavailable through gateways, state off the user's disk, unstubbable offline). The manual loop is a few hundred lines because the tool set is small and local, and every byte of it runs under FixtureTransport in the selftest.

#### 4.2 Request shape (`MessagesRequest`)

| Field | Rule |
|---|---|
| `model` | planner units: `SettingsKeys.onboardingPlannerModel` (default `claude-opus-5`); reader units: `onboardingWorkerModel` (default `claude-sonnet-5`); `anthropicModelOverride`, when set, replaces both (gateway ids are opaque; never derive capabilities from the string) |
| `system` | array of text blocks in this order: role prompt, package conventions (anchor grammar, citation rules, "the code wins over the README"), the repo dossier (module map, README digest, survey summary, optional user briefing) with `cache_control: {type: "ephemeral"}` on the last dossier block |
| `messages` | first user message = the unit's instructions and parameters; then the append-only tool loop; a second `cache_control` breakpoint sits on the last content block of the newest user message and moves forward each turn |
| `tools` | sorted by name, each with `strict: true`, `input_schema` with `additionalProperties: false` and `required`; `tool_choice: {type: "auto"}` always (Fable-class overrides reject any/tool), instructions name the expected tool |
| `thinking` | `{type: "adaptive"}` on every request; never `budget_tokens`, never `temperature` or `top_p` |
| `output_config` | `effort`: `xhigh` for plan, rank-paths and trace units; `high` for compose and script; `medium` for the playback chat (latency); `low` for map, lens and verify units. `format`: a JSON schema (`output_config.format`, verify the exact key names against the claude-api skill before coding) for ScriptPlannerUnit, RankPathsUnit and table-producing compose units; in gateway-compat mode the schema is described in the prompt and the reply is parsed with `extractJSONObject` (sibling of `extractJSONArray`) |
| `max_tokens` | 16000 non-streaming (readers), 32000 streaming (plan, trace, compose, script), 8000 streaming (playback chat) |
| streaming | `stream: true` for every unit whose max_tokens exceeds 16000 and for chat; SSE parsed by `SSEParser` (events `message_start`, `content_block_start`, `content_block_delta` with `text_delta`, `input_json_delta`, `thinking_delta`, `signature_delta`, `content_block_stop`, `message_delta` with `stop_reason` and `usage`, `message_stop`, `ping`, `error`); idle timeout 120 s between events, non-streaming `timeoutInterval` 300 s |
| betas | only when `anthropicBaseURL` is blank and `onboardingGatewayCompat` is off: `anthropic-beta: server-side-fallback-2026-07-01` with `"fallbacks": "default"` on requests whose model is `claude-opus-5` or `claude-fable-5-1`. No compaction, context-editing or task-budget betas in v1 (context growth is handled client-side so behavior is identical on gateways) |
| headers | `x-api-key`, `anthropic-version: 2023-06-01`, `content-type: application/json`; headers are never written to any file |

Prompt caches are model-scoped: the planner and worker models warm two separate caches. The dossier plus tools plus system must exceed the cacheable minimum (1024 tokens on Sonnet 5, 512 on Opus 5); `FleetScheduler` checks the prefix once at run start with `POST /v1/messages/count_tokens` (4 characters per token estimate on gateways that lack it) and pads the dossier with the module map when short. `usage.cache_read_input_tokens` is logged per request and a `cacheHitRate` per model is shown in FleetProgressView so a zero-hit regression is visible.

Stop reasons: `end_turn` finishes the turn; `tool_use` runs every tool_use block concurrently and returns all `tool_result` blocks in ONE user message (`is_error: true` for failures, never dropped); `max_tokens` keeps the response's complete blocks (thinking and text), drops an incomplete tool_use block (the incomplete block is never written to transcript.jsonl, so the replayed history is exactly what the API produced minus the unfinished block), and appends a user text block "Your reply was cut off at the output limit. Continue; if you were about to call a tool, call it now."; `refusal` (check before reading content; `stop_details` may be null) marks the unit `failed` with reason `refused` and a notice, no blind retry; `pause_turn` re-sends the same history unchanged. Assistant content including thinking blocks is echoed back verbatim; history is append-only (preserved-thinking rule); tool inputs are parsed with JSONSerialization, never string-matched.

#### 4.3 Tools

Research tools (`RepoTools`, all confined to `repo/` and the package; a path outside is `is_error`). The dependencies lens additionally receives the server-side `web_search_20260209` tool with `allowed_domains` limited to advisory and registry sources when `anthropicBaseURL` is blank, citing fetched pages with `url:` anchors; behind a gateway EOL and CVE fields stay `unknown` and `coverage.skippedChecks` says so.

| Tool | Input | Returns |
|---|---|---|
| `list_dir` | `path`, `depth` (max 2) | entries with sizes and kinds |
| `read_file` | `path`, `startLine`, `endLine` (at most 400 lines per call, default first 200) | numbered lines under a header `code:<path>@<sha7>#L<a>-L<b>`; records the excerpt in the unit's evidence cache so `emit_fact` can attach it |
| `grep` | `pattern`, `glob`, `maxResults` (200) | `path:line: text` |
| `git_log` | `path`, `limit` (100) | `commit:` anchors with author, date, subject, files |
| `git_blame` | `path`, `startLine`, `endLine` | per-line author, date, `commit:` |
| `git_show` | `sha`, `path` | file at sha or the commit diff (truncated at 400 lines) |
| `read_command_output` | `cmd` (`cmd:` anchor) | stored output |
| `read_facts` | `kinds`, `subject` | facts JSON |
| `emit_fact` | Fact JSON (strict schema) | `{"id": ...}` or `is_error` with every validation failure |
| `emit_artifact` | `kind` (`script`, `docSection`, `diagramHint`, `trace`), `id`, `payload` | written path, or `is_error` listing unresolved anchors |
| `finish` | `summary`, `coverage { readPaths, unreadDirs, skipped }` | ends the unit |

Chat tools (`PackageTools`): `read_file`, `list_dir`, `grep`, `search_package(query)`, `get_doc_section(docId, slug)`, `get_transcript_range(videoId, fromT, toT)`, `get_diagram(diagramId)`, `read_fact(id)`, `flag_contradiction(videoId, t, anchor, claim, reason)` (appends to `review/flags.json`), `seek_video(t, why)` (records a proposal only; the app never seeks without a click).

#### 4.4 Unit graph

| Unit kind | LLM | Inputs | Outputs |
|---|---|---|---|
| acquire | none | request | repo/, manifest.headSHA |
| inventory, gitmine, deps, buildtest | none | repo/ | dossier/, facts, units/<id>/result.json |
| plan | planner | dossier, survey facts | directories to map, candidate critical paths, video list sized by depth (appended to checkpoint.json) |
| map[dir] | worker, fan-out per top-level directory or 40-file cluster | dir | facts |
| lens[kind] | worker (data, deps, deploy, observability, integrations, glossary) or planner (security, testTruth, migrations, landmines) | facts + tools | facts |
| verify[batch] | worker, one per 25 facts (two independent verifiers per batch at standard and exhaustive depth) | facts | verdicts (must cite counter-evidence to refute); at smoke and quick one refuting verdict rejects; at standard and above both must refute, a split sets `unknown` and lists the fact in review/rejected.json under `disputed` |
| rank-paths | planner | verified facts | `traces/index.json` ranked paths with entry anchors and rationale |
| trace[path] | planner, fan-out | path + tools | `traces/<id>/trace.json` (ordered hops with anchor and call site; the ten concerns each `present|absent|unknown` with evidence; `scaresMe`) |
| adr, debt, confessional[subsystem] | planner | facts | `decision` and `risk` facts, doc seeds |
| diagram[kind] | none (projector) with an optional planner pass for grouping hints | facts | `.mmd`, `.links.json`, `.svg`, `.png` |
| compose[doc] | planner (tables: worker) | facts, diagrams | `docs/<id>.md` whose claims cite `[[fact:...]]`; a validator rejects uncited claims and refuted citations once, then accepts with hedged wording for `unknown` facts |
| script[video] | planner | deliverable, facts, diagrams, traces | `videos/<id>/script.json` validated by ScriptValidator (one re-prompt with the error list) |
| narrate, render, assemble, transcript[video] | none | script, audio | video files |
| index, hub | none | everything | `index/`, `hub/` |

Scope and the coverage tracker (`Scope.swift`, replaces the earlier `Depth.swift`; decided 2026-09-19: depth is not a cap). A run is `complete` by default: every top-level directory is mapped, every path the ranker supports with evidence is traced, every register and every series video is produced, confessionals for every subsystem. `smoke` exists for the selftest and `preview` (3 paths, 4 videos) for a fast first look; neither is the default. The spend cap is off by default and, when set, ends the run as `partial` with the coverage report. What the user watches instead is the coverage tracker: `coverage.json` (section 15.4) with a level per directory (unread, inventoried, mapped, verified, traced), files read over files present, facts and verified facts per component, candidate paths versus traced paths, and deliverables produced versus planned. FleetProgressView and the hub render it as a coverage map so blind spots are visible during and after the run, whichever producer made the packet. The presets below now describe the smoke and preview scopes only; `complete` produces everything the evidence supports. Diagram kinds are `enum DiagramKind { c4Context, c4Container, c4Component(container), erd, deployment }` (DiagramProjector). Register doc ids are `architecture, adrs, ownership, dependencies, tech-debt, incident-patterns, operational-scorecard, test-truth, data-inventory, security-posture, glossary, landmines`, plus `coverage-report` on every run.
- smoke: diagrams [c4Container]; docs [landmines]; 1 trace; 1 video of at most 60 s; hub.
- preview: diagrams [c4Context, c4Container, erd]; docs [architecture, ownership, tech-debt, landmines]; 3 paths; 4 videos.
- complete (default): every diagram kind with c4Component for every container that owns a critical path; all 12 docs; every ranked path with evidence (no fixed count); the 10 series videos plus one trace video per path; confessionals for every subsystem; two independent verifiers per fact batch.
`diagramLinksProbe` and `registerLinksProbe` assert one file per kind and id required at the depth under test.

#### 4.5 Scheduling, limits, cost

`FleetScheduler` pulls units whose inputs are `done`, runs them in a `TaskGroup` bounded per lane (`onboardingMaxParallel` LLM units, 2 TTS, 1 render because BrandedRenderer is MainActor and not reentrant). `RateLimiter`: per request retry on 429, 529, 5xx and URLError with jittered exponential backoff honoring `retry-after`, at most 6 attempts; per unit at most 3 attempts then `failed` with a notice and dependents `skipped`; a circuit breaker pauses the fleet after 5 consecutive transport failures with the notice "Paused: API unreachable, Resume when ready". `SpendMeter` prices every response from a per-model table in `Defaults` (input, output, cache write at 1.25x input, cache read at 0.1x input; editable) into `manifest.spent`; the cap is optional and off by default (decided 2026-09-19); when set, at `capUSD` the scheduler stops issuing units, lets in-flight units finish, sets `manifest.status = "partial"`, fills `unproduced`, and writes `docs/coverage-report.md`. A pre-run estimate (file count and total bytes to planned units to token estimate) is shown in OnboardSheet.

#### 4.6 Checkpoint and resume rules

1. `checkpoint.json` is rewritten atomically (temp file plus rename) after every unit state change; `manifest.json` after every deliverable change.
2. `units/<id>/transcript.jsonl` gets one line per event: request sent (redacted headers, full body), response received (full content including thinking blocks), tool results computed. The next request is not sent until the previous line is flushed.
3. `emit_fact` appends to `facts/<unitId>.jsonl` inside the tool call, so a session killed mid-unit keeps every fact found so far; ids are `F-<unitId>-<toolUseId>` and FactStore ignores a duplicate id.
4. Resume on open: units `done` are skipped when `inputsHash` still matches; units `running` become `pending`; a unit whose transcript ends with an assistant turn containing tool_use blocks without results re-executes those tools (read-only tools are deterministic; `emit_fact` and `emit_artifact` are idempotent by id; command outputs are cached by `(unitId, toolUseId)` and never re-run) and continues; a unit whose transcript ends with a complete user turn re-sends it.
5. Context growth: each unit has a context cap (measured with `count_tokens` when available, else 4 characters per token); at 80 percent of the cap the unit receives a user text block "Call finish now with your summary and coverage" and the scheduler spawns a continuation unit `<id>-cont<n>` seeded with the finish summary and the unread list. `read_file` is capped at 400 lines and tool results are truncated with an explicit marker "truncated: request a narrower range".
6. Cancel and Pause: the scheduler's Task is cancelled; `AgentRun` cancels the in-flight `URLSessionDataTask` immediately, drops the partial assistant turn (never persisted), and sets the unit `pending` so the resume rule re-sends the last complete user turn; the checkpoint is written; the app may quit. `SpendMeter` also refuses to start a turn when spent plus the estimated turn cost exceeds the cap, so the cap is not overshot by a long streaming turn. Opening a package whose manifest status is `running` with no live session offers Resume.
7. Staleness: `inputsHash` is the SHA-256 of the unit's input outputs; editing a script, correcting a fact or regenerating a unit changes downstream hashes and re-pends those units on the next run; `manifest.edges` lets the review UI mark dependent deliverables `stale` immediately.

#### 4.7 Two build logs

`docs/onboarding/BUILD-LOG.md` (in the repository) is the builder's log: one entry per session in the existing template, verified probe names, limits hit with exact resume points, Next list; the milestone table is the only status dashboard. `<package>/build-log.md` is machine-written by `BuildLog`: session boundaries (`## Session <uuid> <ISO date>`), one line per unit start and finish with attempts and usage, notices, cap hits, resume points, never keys or headers. `<package>/build-log.jsonl` has one record per API request: `{ts, unitId, model, inputTokens, outputTokens, cacheReadTokens, cacheWriteTokens, usd, stopReason, ms, streaming}`.

#### 4.8 Fixture seams

`FixtureTransport` replays recordings from `Resources/OnboardingFixtures/<promptName>/<turn>.json` keyed by (prompt name, turn index); each recording stores the hash of the request it was recorded against and a mismatch logs a warning rather than failing, so prompt edits do not break the selftest until the fixtures are re-recorded. `onboardingRecordFixtures` makes `URLSessionTransport` write recordings in the same layout during a real run so a builder can refresh them on the Mac. `ToneNarrator` is the Narrating fixture. `Transcribing` is unused by this feature (timestamps never come from ASR) but keeps its protocol for the existing pipeline.

## 5. Video generation

There is no recording. The unit of rendering is a SHOT (one narration paragraph of 1 to 4 sentences plus one ScreenState); a SCENE is a chapter made of shots; a VIDEO is 6 to 14 scenes capped at 900 s.

Scene types and templates:
- `card` (`scene-card-template.html`): variants `tldr` (title, 3 to 5 bullets, chapter list with minutes; scene 1, narration at most 30 s), `chapter` (title card), `confessional` (charcoal card with the fragility statements). Card shots hold at least 4 s.
- `code` (`scene-code-template.html`): file path and `@sha7` chip in the header, line numbers, a window of at most 40 lines, the highlighted range as a coral band with a right-margin callout, other lines dimmed; syntax spans from `SyntaxTokenizer` (keywords, strings, comments, numbers for Swift, Python, TypeScript, JavaScript, Go, Rust, Java, Kotlin, Ruby, C, C++, C#, SQL, shell, YAML, JSON; unknown languages render plain). Consecutive shots in one file move the window and highlight; hard cuts only in v1 (no tall panels, no tweens).
- `diagram` (`scene-diagram-template.html`): the SVG from DiagramRendering inlined with `focusNodes` emphasized and others muted.
- `terminal` (`scene-terminal-template.html`): command, exit status and log tail from `cmd:` output in a dark panel with highlighted lines.
- `table` (`scene-table-template.html`): a table from the script (register excerpts, concern matrices).
Every template shares the chrome: video title, chapter name, progress rail, the current anchor string in the footer, `{{THEME_CSS}}` and the wordmark, cream background, Georgia headings.

Pipeline per video, every step resumable by content hash:
1. `ScriptPlannerUnit` writes `script.json`; `ScriptValidator` rejects once with the error list, then the unit is `failed` with a notice.
2. Narrate: for each shot, `AudioCache` looks up SHA-256(narration + voiceID + modelID); on a miss `Narrating.narrate` runs with `previous_text` and `next_text` for prosody, and the WAV plus `.align.json` are written. Duration is measured exactly as `StudioViewModel.synthesizeCore` does, `AVURLAsset(url:).load(.duration)`, never from WAV header arithmetic (the MP3 fallback path writes WAVs through AVAudioFile whose chunk layout differs from `wavData`).
3. Timeline: `VideoService.timeline(steps:durations:policy:)` is extracted from `exportNarratedVideo(to:)` (StudioViewModel.swift lines 685 to 697). `TimelinePolicy.walkthrough` reproduces today's rule, keep = min(step.duration, max(narration + beat 1.0, 2.0)) with trim per setting. `TimelinePolicy.onboarding` has no source-duration clamp: hold = max(narration + beat 0.6, minimum 2.0, card minimum 4.0 for card shots). The shots are passed in as `WalkthroughStep`s with `slug` = shotId, `title` = scene title, `script` = narration and placeholder times; the function returns the realized `Timeline` (segments with absolute start and hold) and the onboarding pipeline builds every downstream file from that return value, never from the placeholder times. If the total exceeds 900 s after synthesis, the planner is re-invoked once with the overage and the longest shots; only changed shots re-synthesize.
4. Stills: `SceneRenderer` renders each distinct ScreenState (cache `frames/<shotHash>.png`, hash of ScreenState + theme + template hash) through `BrandedRenderer.renderReady` or `PersistentRenderer` at exactly 1920x1080, normalized with `Exporters.cgImage(from:pixelWidth:pixelHeight:)`.
5. `StillsVideoWriter.write` produces `stills.mp4` (H.264, 1920x1080, 30 fps nominal, presentation times on the 600 timescale): the shot's frame is appended at the shot start and every 0.5 s of its hold, plus one final frame 1.0 s after the last hold so the asset is never shorter than the segment sum (the clamp at `VideoService.swift:78-80` must never trigger).
6. `VideoService.assembleNarratedVideo(videoURL: stills.mp4, segments: timeline.segments, keepOriginalAudio: false, framing: nil, outputURL: video.mp4)` unchanged; narration stays contiguous through the existing `insertEmptyTimeRange` discipline.
7. `TranscriptBuilder` writes transcript.json, coderefs.json, chapters.json, captions.srt (`Captions.srt`), captions.vtt and chapters.vtt (`Captions.vtt`, `Captions.chaptersVTT`, `WEBVTT` header, dot timestamps). No MP4 chapter atoms.
8. Verification: `VideoService.extractFrame` at each chapter start plus 0.25 s (the export re-encodes the sparse stills track, so the exact cut time may still show the previous still) is pixel-checked against a per-scene-type signature (card: cream corner and coral accent; code: monospace region non-blank and a coral highlight pixel; terminal: dark panel; diagram: node pixel), and a frame at total minus 0.1 s must match the last scene. `SceneDetector.detect` is consulted only at chapter starts where the scene type changes; two consecutive code stills sharing the chrome are near-identical to a 9x8 dHash and will not raise a boundary, which is expected.

Throughput: a 12 minute video is roughly 60 shots; with PersistentRenderer about 0.2 s per still, TTS on a lane of 2, and one export, a video renders in a few minutes; the smoke video (8 shots, 60 s) keeps the selftest under two minutes.

## 6. Transcript and code-ref map

Producer: `TranscriptBuilder.build(script:timeline:clips:) -> (transcript: TranscriptDoc, coderefs: CodeRefMap, chapters: [ChapterMarker])`. For each shot: absolute start from the timeline; sentences from `Captions.splitSentences` (the existing `. ! ?` rule). With a provider alignment, characters fold into words (whitespace boundaries) and words into sentences, offset by the shot start (`timingSource: "provider-words"`, `words` populated). Without one, sentence times are distributed proportionally by character count across the measured clip duration with a 0.8 s floor (`timingSource: "sentence-estimate"`), the rule already in `VideoService.srt`. The shot's trailing pad is attributed to its last sentence so segments tile the timeline; there are no empty-text segments and therefore no blank caption cues. Chapters are the scene starts.

```
transcript.json
{ "version": 1, "videoId": "trace-checkout", "sha": "ab12cd9", "duration": 731.8, "timingSource": "provider-words|sentence-estimate",
  "summary": "...", "chapters": [ { "id": "s02", "title": "Entry: POST /checkout", "start": 31.2, "end": 142.9, "docAnchor": "doc:traces-checkout#entry", "anchors": ["code:src/api/checkout.py@ab12cd9#L30-L70"] } ],
  "segments": [ { "id": "seg-0007", "sceneId": "s02", "shotId": "s02a", "start": 31.20, "end": 36.84, "text": "The request lands in checkout_handler.", "words": [ { "w": "The", "s": 31.20, "e": 31.31 } ] } ] }

coderefs.json
{ "version": 1, "videoId": "trace-checkout", "sha": "ab12cd9",
  "intervals": [ { "start": 31.20, "end": 52.01, "sceneId": "s02", "shotId": "s02a", "sceneType": "code",
      "anchors": ["code:src/api/checkout.py@ab12cd9#L30-L70"], "highlight": { "anchor": "code:src/api/checkout.py@ab12cd9#L40-L58", "callout": "..." }, "visibleLines": [30, 70], "factIds": ["..."] },
    { "start": 143.0, "end": 171.5, "sceneId": "s03", "shotId": "s03a", "sceneType": "diagram", "diagram": "trace-checkout", "focusNodes": ["handler", "orders_repo"], "anchors": ["diagram:trace-checkout#handler"], "factIds": [] },
    { "start": 171.5, "end": 190.0, "sceneId": "s04", "shotId": "s04a", "sceneType": "terminal", "cmd": "cmd:buildtest/1", "anchors": ["cmd:buildtest/1"], "factIds": [] } ] }

chapters.json  = the chapters array alone (player chapter strip and hub read it without parsing the transcript)
```

Invariants (all asserted by `transcriptMapProbe`): segments sorted and contiguous (`segments[i].end == segments[i+1].start` within 1 ms); `segments.last.end` within 250 ms of the mp4 audio track's time range; every segment's `sceneId` is a chapter; `words` present iff `timingSource == "provider-words"`; intervals contiguous and covering `[0, duration]`; every anchor resolves at the SHA; `highlight` inside the interval's anchor range; `visibleLines` contains the highlight; SRT and VTT cue counts equal the segment count with monotonic times. Segments and intervals share `shotId`, so "what was being said when this line was highlighted" is a join, not a time search. `lookup(t)` is a binary search over intervals used by captions, the companion card and the chat context. `index/anchors.json` is rebuilt from every coderefs.json, doc and diagram sidecar after each unit.

## 7. The interactive player

Window: `OnboardingRootView` in `Window("Onboarding", id: "onboarding")`, a three-column `NavigationSplitView` (min 1280x800) pinned to `.environment(\.colorScheme, .light)` on `Brand.cream`, with `BusyStatusBar` at the bottom and the notices banner (list version of `ReviewView.noticeBanner`: Brand.soft, coral info icon, inline Retry per notice).

Left, `HubNavigatorView`: the recommended order as a numbered list from `hub/index.json` (Start here, Architecture overview 11 min, ...), grouped Videos, Traces, Docs, Diagrams, Registers, Review; each row shows minutes, a status dot from `review/progress.json` (unwatched, percent, done) and a review badge from `review/status.json`. While a run is active the top of the sidebar hosts FleetProgressView's compact summary and the Pause and Resume buttons; the full dashboard is a sheet.

Center, `StageView`: one of VideoPane, CodeView, DocView, DiagramView, or PackageReviewView, with its own navigation stack so Back restores the previous stage state including the video's t. `VideoPane` hosts `PlayerView` (AVPlayerView; never SwiftUI VideoPlayer) over an `AVPlayer` for `video.mp4`, a chapter strip from `chapters.json` (proportional segments, current chapter filled coral, click seeks with `seek(to:)`), and one live caption line from `transcript.json`. `PlaybackClock` wraps `addPeriodicTimeObserver(forInterval: 0.25 s)` and publishes `t`, the current segment and the current interval. `CodeView` is NSTextView-backed (line numbers, coral band on the range, native find, selection) and loads content through `GitRunner.show(sha:path:)`, never the working tree; its header reads `checkout.py @ ab12cd9, on screen at 4:32 in Critical path: Checkout` and a "Where is this covered?" strip lists every `video:#t`, `doc:#slug`, `diagram:#node` and `trace:#hop` that cites the file from `index/anchors.json`; "Open in editor" runs `onboardingEditorCommand` (default `open -a` on the file in `repo/`; VS Code users set `code --goto {path}:{line}`). `DocView` and `DiagramView` are one `NSViewRepresentable` WKWebView with `WalkthroughSchemeHandler` (a `WKURLSchemeHandler` for `walkthrough://`) and a `WKUserContentController` bridge; docs are MarkdownLite output in `doc-template.html` where each `##` header shows "Watch 3:12 in Architecture overview" and code chips; diagrams are the SVG with node click handlers reading `links.json`, hover shows path and owner.

Right, `CompanionPanel`: the "On screen now" card re-resolves `coderefs.lookup(t)` every tick (scene type icon, `src/api/checkout.py @ ab12cd9`, "Lines 40-58 highlighted", the callout, the last completed sentence, all as chips), the chat transcript (`ChatPanel`), and tabs for Bookmarks and Flags.

Moment to moment: at 4:32 the viewer clicks the `L40-58` chip; the video docks to a 320 px mini-player at the top of the companion (still playing, still on the clock), the stage becomes CodeView at line 40 with the band on 40-58, and "Back to video" (or Escape) restores the full player at the same t. A doc header chip seeks the video; a diagram node opens the code; a trace hop list is its video's chapter list, so clicking hop 4 seeks and opens the code side by side ("Follow along" split mode, available for every code scene: the on-screen file opens automatically at each shot change). Typing in the chat pauses the video (a Resume pill appears); Cmd-B bookmarks {videoId, t, note}; Cmd-K opens search over `index/search.json`; J, K, L transport; `[` and `]` previous and next chapter; C toggles captions; `?` focuses chat; Cmd-[ Back. Read and watched state persists to `review/progress.json` on every chapter change.

Static export (`HubExporter`): copies `hub/`, `docs/*.html`, `diagrams/*.svg`, `videos/*/{video.mp4, captions.vtt, chapters.vtt, transcript.json, coderefs.json, chapters.json}` and a rendered `code/<path>.html` per cited file, with `hub.js` resolving the same anchor grammar to relative URLs and `<video>` with `<track kind="subtitles">` and `<track kind="chapters">`; chat is omitted with a note. `units/`, `chat/`, `repo-git/` and `repo/` are excluded by default.

## 8. The playback agent

Model and mode: `onboardingPlannerModel` (default `claude-opus-5`), `thinking: {type: "adaptive"}`, `output_config.effort: "medium"`, streaming SSE, `max_tokens` 8000, `tool_choice` auto, `fallbacks: "default"` when not behind a gateway. One conversation per video per package, persisted append-only to `chat/<videoId>/<sessionId>.jsonl` with thinking blocks replayed unchanged; a new session starts after 30 questions (the old one is summarized into the first user turn of the new one; simple compaction, never keep-tail).

Request at time t (`PlaybackAgent.buildRequest(t:question:history:)`), stable prefix first:
1. `tools`: the PackageTools list in section 4.3, sorted by name, strict.
2. `system` blocks with one `cache_control` breakpoint after block 3: (1) the role ("You are the onboarding companion for <repo> at <sha>. You answer while the viewer watches. Cite every claim about code or the package with [[anchor]]. Never assert what you have not read or what the narration has not said. When the answer lies later in the video, say so and offer the chapter. When code you read contradicts the narration, say so plainly and call flag_contradiction."), the citation grammar and the anchor rules; (2) the package digest: deliverable list with ids, titles and one-line summaries, headSHA, module map; (3) this video's `summary`, its full chapter list with start times and doc anchors, and the top facts for its subject (claim + evidence anchors).
3. `messages`: the history so far, then the new user turn in this order: `<narrated_so_far>` with all segments whose `end <= t`, the last 40 verbatim as `[mm:ss] text`, earlier ones collapsed into one line per chapter (scene title plus first sentence), and the current segment marked `(in progress: <words with e <= t>)` when word timing exists; `<on_screen t="272.4" chapter="s02" shot="s02a">` with the interval's scene type, anchors, highlight and callout PLUS the actual source of the highlighted range with 20 lines of context read via `git show` at the SHA (diagram scenes inline the `.mmd` and the focused nodes' links; terminal scenes inline the command output excerpt), and the shot's facts as `id, claim, evidence anchors, excerpt, status`; `<coming_up>` with the next 2 segments marked "not yet narrated"; `<viewer_question>`. Everything before the question is either frozen or monotonically growing, so follow-ups hit the cache.

Answering: short first (2 to 6 sentences), detail after; every code claim carries a `[[code:...]]` citation to lines on screen or read this turn; package references use `[[doc:...]]`, `[[diagram:...]]`, `[[video:...#t=...]]`, `[[fact:...]]`; `CitationParser` resolves each citation as the stream arrives and renders chips (unresolvable ones become plain text with a warning glyph); tool calls appear as small "reading src/..." rows; `seek_video` proposals appear as a Jump chip; `flag_contradiction` appends to `review/flags.json` and shows an amber card. `chatContextProbe` asserts the assembled request for the fixture video at three times (before the first code shot, inside a code shot, after the last chapter): the exact segment ids, the interval's anchors, the inlined code lines and the coming-up ids.

## 9. Verify loop for this feature

```
swift build
scripts/make-fixture-repo.sh /tmp/fixture-repo
./.build/debug/WalkthroughStudio --selftest-onboarding /tmp/fixture-repo /tmp/onboarding-out            # all probes
./.build/debug/WalkthroughStudio --selftest-onboarding /tmp/fixture-repo /tmp/onboarding-out --probe transcriptMapProbe
```

Probes print `selftest: <name> OK (<detail>)` and throw `StudioError` with the observed value on failure; the run ends with `SELFTEST PASS` or `SELFTEST FAIL: ...`. The existing `--selftest` must keep passing after every milestone (the timeline extraction and SelfTestSupport refactor touch it). `/tmp/onboarding-out` holds PNG, MP4, HTML and JSON dumps that must be looked at; several rendering bugs only show there.

`scripts/make-fixture-repo.sh <dir>` builds a deterministic repository (fixed `GIT_AUTHOR_NAME`, `GIT_AUTHOR_DATE`, `GIT_COMMITTER_DATE`, so the head SHA is stable): two authors (Ada Lovelace, 8 commits; Grace Hopper, 4 commits), `src/api/orders_handler.py` (entry, calls authz), `src/auth/authz.py`, `src/service/orders.py`, `src/repo/orders_repo.py` (touched in 6 commits, the hotspot), `db/schema.sql` (users with an email column, orders), `db/migrations/001_orders.sql`, `db/migrations/002_split_addresses.sql` (referenced by a TODO, not applied in schema.sql), `.github/workflows/ci.yml`, `deploy/deploy.sh` (untouched since commit 1), `requirements.txt` pinning `requests==2.19.0`, `tests/test_orders.sh` printing `PASS`, `README.md`, `config/settings.example` with `FAKE_SECRET=sk-test-fixture-0001`, and `templates/email.tmpl` containing `{{ user.name }}` to exercise placeholder escaping. `fixtureRepoProbe` asserts these facts before anything else runs. `FixturePackage.make(at:)` writes a package for the player milestone from this repo: `script.json` (one card, two code shots, one diagram, one terminal shot), `stills.mp4` and `video.mp4` produced by `StillsVideoWriter` and `ToneNarrator` through the real pipeline, `transcript.json`, `coderefs.json`, one doc, one `.mmd` with `.links.json`, `index/anchors.json`.
## 10. Decisions

### D1. Native Swift tool-use loop over raw HTTP
Decision: research agents and the playback agent run as a manual Messages API loop (`AgentRun` actor) over the extended `AnthropicClient`, in process.
Alternatives: Claude Code CLI subprocess; Managed Agents; SDK tool runner (none exists for Swift).
Why: only the in-process loop honors every hard constraint at once: Keychain-only keys, the gateway base URL and model override already promised in Settings, no third-party Swift packages, a fixture transport for the network-free selftest, per-request usage for the spend cap, and per-turn checkpointing into the package directory.
Consequences: SSE parsing, retries, tool batching and stop-reason handling are new code with edge cases; fixtures must be recorded from real streams early (M5 record mode).

### D2. Fact store with evidence is the source of truth; deliverables are projections
Decision: agents cannot write deliverable prose; they call `emit_fact` (evidence required, anchors validated at the SHA, excerpt captured at read time). Verifiers refute with counter-evidence. Projectors and composer passes produce diagrams, registers, traces and scripts from facts, and composer claims must cite `[[fact:...]]`.
Alternatives: thin prompt-plus-schema units emitting artifacts directly (reuse-first); prose validated only for anchor resolution (experience-first).
Why: anchor resolution alone does not stop confident nonsense; the fact store makes every claim traceable, makes refutation effective (rejected facts cannot reach prose), and gives the review UI, the chat agent and staleness one graph to work from.
Consequences: more units and one extra composer stage per document; to avoid sparse or stilted docs, `unknown` facts are allowed with hedged wording and only `refuted` facts are excluded.

### D3. A separate Window scene and a Commands menu that opens it
Decision: `Window("Onboarding", id: "onboarding")` plus `OnboardingCommands: Commands` using `@Environment(\.openWindow)`, placed in the File menu with `CommandGroup(after: .newItem)`; ImportView and projectMenu call the same coordinator. The window shows one package at a time; `OnboardingCoordinator` keeps every opened `OnboardingViewModel` alive so a running fleet continues when the user switches packages, and switching while a run is active shows a notice rather than a modal.
Alternatives: a fifth branch in `ContentView.body`; a NotificationCenter post to the ContentView-owned view model.
Why: a mode branch would make the app's only window show the fleet dashboard for hours; a notification has no receiver until the window exists. `openWindow` works from a Commands struct on the package's macOS 14 floor.
Consequences: the app's first menu-bar command and first multi-window state; the new views need their own dark-appearance probes; `BusyStatusBar` is extracted so both windows share the status bar.

### D4. Player before fleet, and a one-time milestone renumber
Decision: build the three-pane player, LinkRouter and backlink index against a generated fixture package (M3) before any LLM code, moving `StillsVideoWriter` into M1 so the fixture package has a real MP4. Rewrite the BUILD-LOG milestone table once to this document's list in the first coding session.
Alternatives: fleet first (agent-first order, first demoable UX at M9); keep the old table and run milestones out of numeric order.
Why: the headline UX is the riskiest part and every later milestone only has to populate files whose readers already exist; a table that cites a phantom ARCHITECTURE.md and disagrees with the build order would mislead every future session.
Consequences: M1 and M2 keep their meaning from the S1 Next list; M3 onward are renumbered; USER-STORIES milestone references are filled in from the new list.

### D5. One anchor grammar, one citation syntax, one resolver
Decision: `Anchor` string forms for code, video, doc, diagram, trace, fact, commit and command; `walkthrough://` URL form for WKWebView; `[[anchor|label]]` citations; `LinkRouter.resolve` used by tools, projectors, the UI and `hubLinkProbe`.
Alternatives: per-deliverable link formats; `ob://` scheme; prose-only citations.
Why: cross-linking the three surfaces is the product; a single machine-checkable string is what makes "every link resolves" a probe rather than a hope.
Consequences: paths containing `@` or `#` need the last-`@`-followed-by-hex rule (covered by `anchorRoundTripProbe`).

### D6. Videos are manufactured from stills through the existing muxer
Decision: `StillsVideoWriter` (AVAssetWriter port of `scripts/make-test-video.swift`) produces a silent `stills.mp4`; `VideoService.assembleNarratedVideo` is called unchanged with `framing: nil`; timeline math is extracted from `exportNarratedVideo(to:)` into `VideoService.timeline(steps:durations:policy:)` used by both paths.
Alternatives: a `FrameCompositor` mode sourcing per-segment images; per-frame WKWebView snapshots; a new composition builder.
Why: `assembleNarratedVideo` only needs a video track and already keeps narration contiguous; sharing the timeline function means the existing selftest steps 6-8 guard the new path and captions, chapters, transcript, coderefs and the stills MP4 all derive from one computation.
Consequences: the stills asset must be at least as long as the segment sum (tail frame) because the muxer clamps silently; the 30 fps framed path (`FrameCompositor`) is not used for onboarding videos.

### D7. Per-shot rendering with a content-hash cache; no tall panels or tweens in v1
Decision: each shot renders one exact 1920x1080 still (window of at most 40 lines); consecutive shots in a file are hard cuts.
Alternatives: render a tall panel (up to 400 lines) once and crop and tween with Core Image (experience-first).
Why: an 11,000 pixel tall retina WKWebView snapshot is an unverified WebKit assumption and a 340 MB buffer; per-shot rendering with `PersistentRenderer` is fast enough and deterministic for pixel probes.
Consequences: less motion in code walks; revisit after the first real videos.

### D8. Timestamps are derived, never recognized; one builder writes every timing file
Decision: `TranscriptBuilder` folds ElevenLabs character alignment into words and sentences, or falls back to the sentence estimate with `timingSource` recorded, and writes transcript.json, coderefs.json, chapters.json, captions.srt, captions.vtt and a separate chapters.vtt from one shot timeline; the trailing pad extends the last sentence.
Alternatives: ASR over the synthesized WAV; separate writers per file; chapter cues inside captions.vtt; empty pad segments.
Why: the narration text is known before synthesis; separate writers drift; a WebVTT file has one kind; blank cues show up in players.
Consequences: word timing quality depends on the ElevenLabs tier; sentence granularity is the floor.

### D9. Fixture seams at the transport and narrator level, keyed by prompt name and turn, with record mode
Decision: `LLMTransport` (`URLSessionTransport`, `FixtureTransport`) and `Narrating` (`ElevenLabsNarrator`, `ToneNarrator`); recordings keyed by (prompt name, turn) with a request-hash drift warning; `onboardingRecordFixtures` writes recordings during real runs.
Alternatives: a `Researching` protocol above the loop (skips the loop in tests); request-hash keys (break on every prompt edit).
Why: the loop, tool batching, `is_error`, continuation and checkpointing are exactly what must be exercised offline; prompt edits must not break the selftest until fixtures are refreshed.
Consequences: fixtures need periodic re-recording on the Mac; the build log records when.

### D10. Model split and effort per role, two caches
Decision: planner, tracer, composer, script and chat units on `claude-opus-5`; map, lens and verify units on `claude-sonnet-5`; effort xhigh for plan, rank and trace, high for compose, script and chat, low for readers; `anthropicModelOverride` replaces both on gateways.
Alternatives: one model everywhere; Fable 5.1 for planning.
Why: readers are tool-heavy and numerous; planning and tracing need the strongest reasoning; both are user-overridable. Caches are model-scoped, so the dossier prefix is sized above 1024 tokens and cache reads are logged per model.
Consequences: two warm-up costs; a cache-hit rate per model is shown so regressions are visible.

### D11. Client-side context management; betas only for server-side fallback and only off gateway
Decision: per-unit context caps, capped tool results, and continuation units seeded with a finish summary; the only beta in v1 is `server-side-fallback-2026-07-01` with `fallbacks: "default"` on Opus 5 requests when `anthropicBaseURL` is blank.
Alternatives: compaction (`compact-2026-01-12`), context editing, task budgets.
Why: behavior must be identical through the gateway the app already supports; the client-side scheme is simple, append-only safe and testable offline.
Consequences: slightly higher token spend on very long reading units; server-side features can be added as an optimization later.

### D12. Executing the target repository's build and tests is opt-in per run (confirmed by the human 2026-09-19)
Decision: `onboardingRunBuild` defaults to off; OnboardSheet shows a checkbox with a plain warning; commands run in a temp copy with a timeout and no privileges; when off, the dev-environment and test-truth deliverables report "could not run" with the reason.
Alternatives: on by default with an allow-list.
Why: the app is unsandboxed and signed with hardened runtime; an allow-list derived from the repo's own manifests is not a security boundary.
Consequences: first runs on unknown repositories produce weaker test-truth data unless the user opts in.

### D13. The package directory is the only source of truth; two build logs
Decision: everything is written under `<RepoName>.onboarding/` with atomic writes; the repository's `docs/onboarding/BUILD-LOG.md` is the builder's per-session log and the package's `build-log.md` and `build-log.jsonl` are machine-written per run.
Alternatives: a `.walkstudio.json`-style single document; one log.
Why: a multi-session build and a multi-hour run both need re-openable state on disk; the two logs answer different questions (what was built and verified versus what the fleet did and spent).
Consequences: `WalkthroughProject` stays untouched; secrets are never written anywhere in the package (probed by grepping for the fixture token).

### D14. Native syntax tokenizer; Mermaid bundled for diagrams (decided 2026-09-19)
Decision: `SyntaxTokenizer` is hand-rolled. Diagrams render through `MermaidJSDiagramRenderer` over a bundled, pinned `mermaid.min.js` (11.4.1, MIT, sha256 a43bc1afd446f9c4cc66ac5dd45d02e8d65e26fc5344ec0ef787f88d6ddb6f9e, at `Sources/WalkthroughStudio/OnboardingResources/hub/vendor/mermaid.min.js` (the `OnboardingResources/` folder has its own `.copy` rule in Package.swift so directory structure survives and no rule overlaps `.process("Resources")`)). The human approved the bundle; the `NativeDiagramRenderer` fallback is dropped and `DiagramRendering` keeps one implementation. `.mmd` source is the editable form.
Alternatives: highlight.js; Mermaid only.
Why: README and CLAUDE.md promise no third-party dependencies; bundled JavaScript is third-party code even if not a SwiftPM dependency; the diagram milestone must be buildable regardless of the answer.
Consequences: the no-third-party rule in README and CLAUDE.md gets a documented exception for this one JavaScript resource; probes assert node ids in the SVG and a node pixel.

### D15. Durations from AVURLAsset, chapters as sidecars, review state per user
Decision: clip durations use `AVURLAsset(url:).load(.duration)` as `synthesizeCore` does; chapters are `chapters.json` plus `chapters.vtt`, no MP4 chapter atoms; `review/status.json`, `flags.json`, `bookmarks.json`, `progress.json` are plain JSON files.
Why: the MP3 fallback writes WAVs through AVAudioFile, so header arithmetic is wrong there; MP4 chapter tracks are effort without a consumer; plain files keep the static export and the app in sync.
Consequences: none beyond the small AVFoundation call per clip.

## 11. Milestones (build order)

Build order equals milestone number. Every milestone ends with its probes green in `--selftest-onboarding`, the existing `--selftest` still green, the output folder inspected, and a BUILD-LOG entry. Sessions are estimates for an AI builder that will hit context limits; a milestone may span several entries.

### M0. Planning docs (S1 done; S2 closes it)
Goal: write `docs/onboarding/ARCHITECTURE.md` from this design; rewrite the BUILD-LOG milestone table to this list (one-time renumber, recorded in the S2 entry); fill the USER-STORIES milestone references; add the onboarding verify loop to CLAUDE.md.
Files: `docs/onboarding/ARCHITECTURE.md`, `docs/onboarding/BUILD-LOG.md`, `docs/onboarding/USER-STORIES.md`, `CLAUDE.md`.
Probe: n/a (docs).
Demo: a stranger can read ARCHITECTURE.md and start M1.
Sessions: 1.

### M1. Fixture repo, selftest scaffold, stills writer
Goal: the feature's headless entry point exists and can write a video with no source recording.
Files: `scripts/make-fixture-repo.sh`; `Sources/WalkthroughStudio/WalkthroughStudioApp.swift` (`--selftest-onboarding <fixtureRepo> <outDir> [--probe <name>]`, terminate guard `hasPrefix("--selftest")`); `Sources/WalkthroughStudio/SelfTestSupport.swift` (`pixel(in:x:y:)`, `sineWAV`, `runProcess`, `runGit`; `snapshot(view:size:appearance:)` and the migration of the NSHostingView harnesses in SelfTest.swift are deferred to the milestone that adds onboarding sheet probes, see BUILD-LOG S2); `Sources/WalkthroughStudio/SelfTestOnboarding.swift`; `Sources/WalkthroughStudio/Services/StillsVideoWriter.swift`.
Probes: `fixtureRepoProbe` (head sha stable, 12 commits, author counts 8 and 4, known paths, `users.email` in schema.sql, PASS from tests/test_orders.sh); `stillsWriterProbe` (three solid-color frames with holds 2, 3, 4 s produce a 1920x1080 mp4 of 10 s within 0.1 s, `extractFrame` at 1, 4 and 8 s returns each color, then `assembleNarratedVideo` over it with `sineWAV` narration has an audio track reaching past the last segment start).
Demo: `SELFTEST PASS` on the fixture; a stills mp4 in the output folder.
Sessions: 1 to 2.

### M2. Package format, anchors, store, git
Goal: the on-disk contract is fixed so every later session writes the same files.
Files: `Sources/WalkthroughStudio/Onboarding/Package/OnboardingModels.swift`, `Anchor.swift`, `PackageStore.swift`, `BuildLog.swift`, `FactStore.swift`, `GitRunner.swift`, `RepoAcquisition.swift`; `Sources/WalkthroughStudio/Services/Keychain.swift` (`githubTokenAccount`); `Sources/WalkthroughStudio/Models.swift` (SettingsKeys).
Probes: `anchorRoundTripProbe` (14 cases incl. a path containing `@` and `#`, directory anchors, `#c=` chapters, URL form both ways, three malformed strings rejected); `manifestRoundTripProbe` (encode then decode with an unknown extra key and a legacy key, explicit `encode(to:)` preserved); `packageStoreProbe` (layout created, atomic write survives a simulated failure mid-write, build-log.md and build-log.jsonl appended across two opens, FactStore rejects a fact without evidence and dedupes an id); `gitRunnerProbe` (worktree at the fixture sha, `show` returns file text that differs from a modified working tree, `log` and `blame` match the scripted author counts).
Demo: a `fixture.onboarding/` folder with manifest, checkpoint, repo/ and a build log.
Sessions: 1 to 2.

### M3. Player shell on a generated fixture package
Goal: the headline UX is real before any LLM code: window, menu, three panes, clock, code view, doc view, link router, backlinks.
Files: `Sources/WalkthroughStudio/Onboarding/Fixtures/FixturePackage.swift`; `Sources/WalkthroughStudio/Services/Narrator.swift` (`Narrating`, `ToneNarrator` only); `Sources/WalkthroughStudio/Onboarding/OnboardingCoordinator.swift`; `Sources/WalkthroughStudio/Views/Onboarding/OnboardingCommands.swift`, `OnboardingViewModel.swift`, `OnboardSheet.swift`, `OnboardingRootView.swift`, `HubNavigatorView.swift`, `StageView.swift`, `VideoPane.swift`, `PlaybackClock.swift`, `CodeView.swift`, `DocView.swift`, `DiagramView.swift` (SVG display), `CompanionPanel.swift`, `WalkthroughSchemeHandler.swift`; `Sources/WalkthroughStudio/Views/BusyStatusBar.swift`; `Sources/WalkthroughStudio/Onboarding/Projectors/MarkdownLite.swift`; `Sources/WalkthroughStudio/Onboarding/Package/BacklinkIndex.swift`, `LinkRouter.swift`; `Sources/WalkthroughStudio/Resources/doc-template.html`; `Sources/WalkthroughStudio/WalkthroughStudioApp.swift` (Window scene), `Views/ContentView.swift` (button, menu entry, BusyStatusBar).
Probes: `fixturePackageProbe` (FixturePackage.make writes script, video.mp4 via ToneNarrator, transcript, coderefs, doc, mmd, links, anchors index); `coderefsLookupProbe` (lookup at t = 1, 12.5 and end returns the expected shotId and anchors); `linkRouterProbe` (every anchor in the fixture package resolves; one deliberately broken anchor is reported by kind); `markdownLiteProbe` (slugs stable, heading chips extracted, fenced code escaped, table rendered); `backlinkIndexProbe`; `onboardSheetProbe` and `playerStageProbe` (dark appearance snapshot, cream corner, PlayerView instantiated without crash).
Demo: open the fixture package, play the 20 s video, click the code chip, see the file at the sha with the band, Back to video at the same t.
Sessions: 2 to 3.

### M4. Narration, scene renderer, transcript and code-ref map
Goal: a real script becomes a chaptered video with captions and both timing files, offline and online.
Files: `Sources/WalkthroughStudio/Services/ElevenLabsClient.swift` (with-timestamps), `Narrator.swift` (`ElevenLabsNarrator`), `Template.swift`, `BrandedRenderer.swift` (`renderReady`, `PersistentRenderer`), `BrandTheme.swift` (code tokens, templateNames, customizingGuide), `VideoService.swift` (`timeline`, `Captions` helpers made internal), `Sources/WalkthroughStudio/StudioViewModel.swift` (`exportNarratedVideo` uses `VideoService.timeline`); `Sources/WalkthroughStudio/Onboarding/Video/AudioCache.swift`, `SceneRenderer.swift`, `SyntaxTokenizer.swift`, `VideoAssembler.swift`, `Captions.swift`, `TranscriptBuilder.swift`, `ScriptValidator.swift`; `Sources/WalkthroughStudio/Resources/scene-*.html`; `Sources/WalkthroughStudio/Views/ThemeEditorView.swift` (Code and Diagrams section).
Probes: `timelineMathProbe` (added to the existing `--selftest`: walkthrough policy reproduces the old remap for three steps); `codeSceneProbe` (coral band pixel at the highlight row, monospace region non-blank, `{{ user.name }}` from the fixture template survives escaping, `<` escaped); `sceneKindsProbe` (one still per kind pixel-checked: cream card, dark terminal, diagram node, table header); `transcriptMapProbe` (all invariants of section 6 on the fixture script with ToneNarrator alignment and again with the sentence estimate); `videoBuildProbe` (mp4 duration equals the hold sum within 0.25 s, audio track spans past the last shot start, frame at each chapter start has that scene's signature, SceneDetector boundaries within 0.5 s, TL;DR frame within the first 30 s); `audioCacheProbe` (editing one shot's narration re-synthesizes and re-renders only that shot; other files keep their modification dates).
Demo: the fixture script rendered end to end, watchable in the M3 player with chapters and captions.
Sessions: 3.

### M5. LLM runtime
Goal: multi-turn, tools, streaming, retries, spend accounting and per-turn persistence, all replayable offline.
Files: `Sources/WalkthroughStudio/Services/AnthropicMessages.swift`, `SSEParser.swift`, `LLMTransport.swift`, `AnthropicClient.swift` (`endpoint(path:)`, `AnthropicAPIError`); `Sources/WalkthroughStudio/Onboarding/Agent/AgentRun.swift`, `RateLimiter.swift`, `SpendMeter.swift`, `ToolSchemas.swift`; `Sources/WalkthroughStudio/Resources/OnboardingFixtures/`.
Probes: `sseParseProbe` (a recorded stream with text, thinking, input_json_delta across chunk boundaries, message_delta usage, an error event); `toolLoopProbe` (FixtureTransport returns two tool_use blocks in one message; both run concurrently; one user message carries both results; an `is_error` path; a max_tokens continuation; a refusal marks failed); `agentResumeProbe` (kill after an assistant tool_use turn, resume re-executes the tools and finishes with no duplicate turns in transcript.jsonl); `backoffProbe` (429 with retry-after honored, 529 backoff, circuit breaker after 5 failures); `spendMeterProbe` (usage priced per model, cache reads counted, cap reached sets partial).
Demo: a scripted agent conversation replayed from fixtures with a build-log.jsonl showing usage per request.
Sessions: 2.

### M6. Playback chat agent
Goal: ask a question at time t and get a cited, streamed answer grounded in the transcript, the on-screen code and the facts.
Files: `Sources/WalkthroughStudio/Onboarding/Chat/PlaybackAgent.swift`, `ChatSession.swift`, `CitationParser.swift`; `Sources/WalkthroughStudio/Onboarding/Agent/PackageTools.swift`; `Sources/WalkthroughStudio/Views/Onboarding/ChatPanel.swift`, `CompanionPanel.swift` (chat, bookmarks, flags tabs).
Probes: `chatContextProbe` (request at three times on the fixture video: segment ids, interval anchors, inlined code lines, facts, coming-up ids, stable prefix bytes identical across the three); `citationParserProbe` (valid forms, labels, unresolvable anchors flagged, nested brackets); `chatToolLoopProbe` (fixture reply asks read_file and gets sha-pinned content); `contradictionFlagProbe` (flag written to review/flags.json); `chatPanelProbe` (dark appearance).
Demo: pause at 4:32 in the fixture video, ask "what does that function do", get an answer with clickable chips.
Sessions: 2.

### M7. Fleet runtime and deterministic survey units
Goal: a resumable, budgeted DAG runner with the no-LLM units and the research tools.
Files: `Sources/WalkthroughStudio/Onboarding/Fleet/FleetScheduler.swift`, `WorkPlan.swift`, `Depth.swift`, `Notices.swift`; `Sources/WalkthroughStudio/Onboarding/Agent/RepoTools.swift`; `Sources/WalkthroughStudio/Onboarding/Units/AcquireUnit.swift`, `InventoryUnit.swift`, `GitMiningUnit.swift`, `DependencyUnit.swift`, `BuildTestUnit.swift`; `Sources/WalkthroughStudio/Views/Onboarding/FleetProgressView.swift`; `Sources/WalkthroughStudio/Views/SettingsView.swift`, `SetupSheet.swift` (Onboarding section, GitHub token).
Probes: `checkpointResumeProbe` (smoke plan with FixtureTransport, cancel after unit 3, resume: units 1 to 3 not re-run, session boundary in build-log.md); `gitMiningProbe` (hotspot, ownership and staleness tables equal the scripted fixture values); `buildRunnerProbe` (opt-in on: PASS captured with exit 0; opt-in off: could-not-run fact; timeout path); `toolSandboxProbe` (read outside repo/ refused, 400-line cap enforced, read_file header carries the anchor); `orphanFactProbe` (zero facts without evidence, emit_fact rejects an unresolvable anchor, replayed tool_use id does not duplicate); `fleetProgressProbe` (dark appearance).
Demo: point the sheet at the fixture, watch the dashboard run the survey units, pause, quit, reopen, resume.
Sessions: 2 to 3.

### M8. Research fleet
Goal: facts for the whole fixture from planner, mappers, lenses, verifiers, ranker and tracers.
Files: `Sources/WalkthroughStudio/Onboarding/Units/PlanUnit.swift`, `MapUnit.swift`, `LensUnit.swift`, `VerifyUnit.swift`, `RankPathsUnit.swift`, `TraceUnit.swift`, `DecisionUnits.swift`; `Sources/WalkthroughStudio/Resources/OnboardingPrompts/*.md`; fixture recordings.
Probes: `fleetSmokeProbe` (smoke depth with fixtures produces facts covering every fixture source path, coverage lists `vendor/` as unread); `verifierRejectProbe` (a scripted refuted fact lands in review/rejected.json and in no projector input); `traceConcernsProbe` (the fixture orders path is found; all ten concerns have a status with evidence; `absent` for idempotency with the evidence anchor of the handler); `spendCapProbe` (fixture usage exceeds the cap; status partial; unproduced list; coverage-report.md written).
Demo: `facts/` and `traces/` for the fixture; a real run on a small public repo at quick depth on the Mac (human).
Sessions: 3.

### M9. Diagrams and registers
Goal: every visual and written deliverable projected from facts with resolving links.
Files: `Sources/WalkthroughStudio/Onboarding/Projectors/DiagramProjector.swift`, `DiagramRendering.swift`, `NativeDiagramRenderer.swift`, `MermaidJSDiagramRenderer.swift` (only if approved), `RegisterProjector.swift`, `TraceProjector.swift`; `Sources/WalkthroughStudio/Onboarding/Units/ComposeDocUnit.swift`; `Sources/WalkthroughStudio/Resources/diagram-template.html`; `Sources/WalkthroughStudio/Services/BrandedRenderer.swift` (SVG extraction via evaluateJavaScript when Mermaid is used).
Probes: `diagramLinksProbe` (every node id in each .mmd has a links.json anchor that resolves; ERD nodes carry rows, retention, pii); `diagramRenderProbe` (SVG text contains the fixture node ids; a pixel inside a known node is non-background; passes on the native renderer and, if bundled, on Mermaid); `registerLinksProbe` (each `##` has video: and code: chips that resolve; front matter lists evidence units; the composer's uncited claim is rejected once then accepted with a citation); `landminesDocProbe` (verify-loop-first structure and numbered gotchas present); `traceMermaidProbe` (trace.mmd participants equal hop anchors).
Demo: C4 container diagram, ERD and the landmines doc for the fixture, clickable in the hub.
Sessions: 2 to 3.

### M10. Video scripts and the series
Goal: the planner writes valid scripts for every video kind and the whole series renders through M4.
Files: `Sources/WalkthroughStudio/Onboarding/Units/ScriptPlannerUnit.swift`; `Sources/WalkthroughStudio/Onboarding/Video/SeriesPlanner.swift` (video list by depth, confessionals per subsystem, over-budget tighten loop); `ScriptValidator.swift` extensions.
Probes: `scriptInvariantsProbe` (over budget, dangling anchor, refuted fact, missing tldr, highlight outside window each rejected; the fixture smoke script accepted at 60 s or less); `traceVideoChaptersProbe` (chapter list equals the hop list; each chapter's interval names the hop anchor); `regenerateOneProbe` (regenerate one video; other videos' files keep their modification dates); `seriesSmokeProbe` (smoke depth renders exactly one video and its transcript and coderefs pass `transcriptMapProbe`).
Demo: the fixture trace video with TL;DR card, code shots, diagram shot, terminal shot and confessional.
Sessions: 2.

### M11. Hub, cross-links, search, export
Goal: the package is one surface and can leave the app.
Files: `Sources/WalkthroughStudio/Onboarding/Projectors/HubProjector.swift`; `Sources/WalkthroughStudio/Onboarding/HubExporter.swift`; `Sources/WalkthroughStudio/Resources/hub-template.html`, `Resources/OnboardingHub/hub.css`, `hub.js`; `Sources/WalkthroughStudio/Views/Onboarding/HubNavigatorView.swift` (order, minutes, progress), `StageView.swift` (Follow along split, keyboard transport, Cmd-K search, mini-player docking), `CodeView.swift` (backlinks strip, Open in editor).
Probes: `hubLinkProbe` (walk every anchor in hub, docs, diagrams, transcripts, coderefs and chat fixtures; zero dangling); `searchIndexProbe` (a transcript sentence and a doc paragraph found with the right target); `hubExportProbe` (exported folder: every href and src exists, VTT tracks referenced, no units/ or chat/ files); `hubViewProbe` (dark appearance).
Demo: recommended order with minutes and status; doc section to chapter to code and back; static folder opens in a browser.
Sessions: 2.

### M12. Review, staleness, end-to-end smoke, hardening
Goal: the package author can accept, fix and regenerate; corrections propagate; the whole pipeline is proven offline and then live.
Files: `Sources/WalkthroughStudio/Onboarding/Review.swift`, `Staleness.swift`; `Sources/WalkthroughStudio/Views/Onboarding/PackageReviewView.swift`; `Sources/WalkthroughStudio/Views/Onboarding/OnboardSheet.swift` (cost estimate); docs updates (`CLAUDE.md`, `README.md`, `docs/onboarding/*`).
Probes: `smokeEndToEndProbe` (point at the fixture at smoke depth with FixtureTransport and ToneNarrator; manifest.status complete; one of each deliverable and a hub; a second run performs zero LLM calls and zero renders); `stalenessProbe` (correct one fact; exactly the dependent deliverables go stale via edges and inputsHash); `reviewStateProbe` (status.json round trip and hub badge); `secretLeakProbe` (grep the whole package and both build logs for the fixture token string and the x-api-key header name; zero hits).
Demo: full smoke package in under two minutes; then the human runs standard depth on a real repository with real keys, records throughput, cache hit rate and cost in the BUILD-LOG, and re-records fixtures.
Sessions: 2, plus one live-run session on the Mac.

Total: roughly 25 to 30 builder sessions. The order can be compressed only by merging M5 and M6 (same session budget) or M9 and M10; never by moving M3 later.

## 12. Risks, ranked

1. Grounding drift (anchors that resolve but do not support the claim). Mitigation: evidence excerpts captured at read time, verifier units that must cite counter-evidence, projectors that exclude refuted facts, composer citation validation, `orphanFactProbe`, and the playback agent's `flag_contradiction` surfacing mistakes during viewing. Residual risk is visible in review/flags.json and the coverage report rather than hidden.
2. Cost and wall time on real repositories (tens of units, millions of input tokens at standard depth). Mitigation: prompt caching verified per model in build-log.jsonl, reader units on the worker model at low effort, capped tool results, depth presets with a pre-run estimate, the spend cap ending the run as partial, and first live runs at smoke or quick depth only.
3. New raw-HTTP surface (SSE parsing, tool batching, continuation, refusal mid-stream, preserved-thinking rules). Mitigation: record mode in M5 so fixtures come from real streams, `sseParseProbe` and `toolLoopProbe` written from those recordings, append-only history everywhere, and an `AnthropicAPIError` taxonomy with a most-specific-first retry chain.
4. Gateway differences (a Bedrock-style proxy may reject streaming, cache_control, strict tools or structured outputs). Mitigation: no betas except server-side fallback and none through a gateway, `onboardingGatewayCompat` degrading to non-streaming with a 300 s timeout and prompt-described JSON parsed by `extractJSONObject`, a probe request at run start, and a notice rather than a failed run.
5. WebKit throughput and stability across hundreds of offscreen renders. Mitigation: `PersistentRenderer` with a readiness signal, `frames/<shotHash>.png` cache, render lane of 1, retry on WebContent process death (BrandedRenderer already surfaces it), per-shot 1920x1080 renders only.
6. Timeline desync (any consumer computing its own timeline, or the muxer's silent clamp). Mitigation: one `VideoService.timeline` shared with the existing export, one `TranscriptBuilder` writing every timing file, the tail frame in `StillsVideoWriter`, and `transcriptMapProbe` plus `videoBuildProbe` as regression guards; an over-budget script is a hard error with one tighten round, never a clamp.
7. Bundled JavaScript approval (mermaid.min.js). Mitigation: `DiagramRendering` protocol with a native SVG renderer that the probes accept; the .mmd source ships either way; the decision only changes diagram fidelity, not the milestone plan.
8. Running an unknown repository's build and tests on the user's Mac from an unsandboxed app. Mitigation: opt-in per run with a plain warning, temp copy, 10 minute timeout, no privileges, and explicit could-not-run facts when off.
9. ElevenLabs alignment availability and rate limits. Mitigation: sentence-estimate fallback with `timingSource` recorded and a softer caption highlight in that mode, TTS lane of 2, the format ladder reused, `workingFormat` behind an actor, and content-hashed audio so retries never re-spend.
10. Context growth inside reader agents on large directories. Mitigation: 400-line read cap, truncation markers, per-unit context caps with continuation units, 40-file clusters for mapping.
11. Builder sessions exceeding context. Mitigation: milestones with one probe each and stable file names, `SelfTestOnboarding.swift` separate from `SelfTest.swift`, the package formats fixed in M2, and the BUILD-LOG template's exact resume points; this Linux session cannot compile Swift, so every entry must say "not verified" until the selftest runs on the Mac.
12. Fixture drift as prompts evolve. Mitigation: fixtures keyed by prompt name and turn with a request-hash warning, record mode, and a BUILD-LOG note whenever fixtures are re-recorded.
13. Private repository token handling through GIT_ASKPASS under hardened runtime. Mitigation: human verification on the signed .app in M7, `secretLeakProbe`, and the token never leaving the Keychain cache except into the helper's environment.
14. First multi-window and menu-bar code in the app (Window scene, Commands, openWindow). Mitigation: dark-appearance probes for every new view, the coordinator holding pending requests so the menu works before the window exists, and the existing single-flight gate left untouched.
15. Long playback conversations (a 15 minute video is about 250 segments). Mitigation: last 40 segments verbatim plus chapter summaries, a new session after 30 questions with simple compaction, and a cache-stable prefix.

## 13. Third-party asks and open questions for the human

Asks:
- Approve or decline bundling mermaid.min.js (MIT, about 3 MB) as a JavaScript resource loaded offline by WKWebView. It is not a SwiftPM dependency but it is third-party code, which README and CLAUDE.md currently rule out. With approval, MermaidJSDiagramRenderer renders the same .mmd the projectors emit with full Mermaid fidelity; without it, NativeDiagramRenderer draws the subset (boxes, containers, arrows, ER tables, sequence lifelines) as SVG at lower polish. The milestone plan is unchanged either way.
- highlight.js is NOT requested: a native SyntaxTokenizer covers about 16 languages, is deterministic for pixel probes, and is legible at video size. Revisit only if the look is unacceptable.
- Confirm the ElevenLabs plan supports the /v1/text-to-speech/{voice}/with-timestamps endpoint and a PCM output format for the chosen voice and model (eleven_v3 preferred). Otherwise transcripts use sentence-estimate timing, recorded in the manifest.
- Private repositories need a GitHub personal access token stored in the Keychain under the new github-token account; public repositories and local clones need nothing. The Xcode Command Line Tools git binary must be present on the Mac (the sheet detects its absence).
- Decide whether the fleet may execute the target repository's detected build and test commands on the user's Mac (temp copy, 10 minute timeout, no privileges). The design defaults this to off per run; the dev-environment and test-truth deliverables then report could-not-run.
- Confirm the model split and defaults: claude-opus-5 for planning, tracing, composing, scripting and the playback chat; claude-sonnet-5 for reader, lens and verifier units; both overridable in Settings and replaced by anthropicModelOverride on gateways. Note that claude-opus-5 is not in the current picker list (claude-sonnet-5, claude-opus-4-8) and will be added.

Open questions that change the build materially:
- Mermaid: approve bundling mermaid.min.js as a resource, or keep the native SVG renderer only? This decides diagram fidelity in M9 and whether diagram scenes in videos look like Mermaid output.
- Build and test execution: is opt-in per run (default off) the right default, or should it be off entirely for the first release? This decides how much the dev-environment and test-truth videos can show on unknown repositories.
- Default package location: ~/Documents/Onboarding/<Repo>.onboarding (proposed, user-visible, easy to export) versus next to the clone versus Application Support. This decides what the OnboardSheet asks and what the export story assumes.
- Depth and spend defaults: is standard (6 critical paths, the 10 series videos, confessionals for up to 6 subsystems) the right default with a 25 USD cap, or should the default be quick (3 paths, 4 videos) with a lower cap for first runs? This changes the pre-run estimate and the first live-run plan in M12.
- Milestone renumbering: this design keeps M1 and M2 from the BUILD-LOG and renumbers M3 onward so the player is built before the fleet; confirm this one-time rewrite of the milestone table is acceptable, since the log's rules forbid rewriting history elsewhere.

## 14. Critic findings and resolutions

A completeness critic reviewed the synthesized design against the feature brief
and the code. Every finding is listed with what was done. "Patched" means the
text above was changed in this document; "at Mx" means a builder check that
belongs to that milestone.

### Missing versus the brief

| Finding | Resolution |
|---|---|
| Diagram kinds never enumerated (C4 context, container, component, ERD, deployment) | Patched: `DiagramKind` enum and per-depth diagram lists in section 4.4; probes assert one file per required kind. |
| Register ids never enumerated; operational scorecard absent | Patched: twelve register ids plus coverage-report listed per depth in section 4.4. |
| Issue mining (ON-4.6) had no data source | Patched: optional `IssuesUnit` over the GitHub REST issues endpoint with `issue:` anchors, degrading to a coverage entry (section 3). |
| Dependency EOL and CVE status came from model knowledge only | Patched: the dependencies lens gets the server-side web search tool with allowed domains when not behind a gateway, citing `url:` anchors; otherwise `unknown` and a coverage entry (section 4.3). |
| Doc-to-chapter chips required video ids before scripts existed | Patched: compose first with stable slugs, scripts carry `docAnchor`, HubProjector injects `video:` chips after the transcript unit, LinkRouter accepts `#c=` against script.json (section 2.9). |
| Briefing (ON-2.9) referenced but had no input | Patched: OnboardSheet briefing picker and `manifest.briefingPath` (section 1). |
| Dirty working tree and shallow clones unhandled | Patched: status and shallow checks with notices and coverage entries; local clones use `git archive`, not a worktree (section 3). |
| Chat spend and fallback-model pricing unaccounted | Patched: SpendMeter prices from the response model, meters chat with `chat:<videoId>` rows, refuses at the cap (section 4.5). |
| No way to rescue a refuted fact (ON-10.3) | Patched: `Review.restore(factId:note:)` appends a verdict and re-pends dependents (section 1). |
| Pause and cap took effect only between turns | Patched: in-flight request cancelled, partial turn dropped, cap checked before each turn (section 4.6). |
| `Briefing.extractText` is capped at 20,000 characters | Patched: new `maxCharacters` parameter with the old default (section 3). |
| `DropZone` is private to ContentView.swift | Patched: made internal in M3 (section 1). |
| One window versus view models keyed by package | Patched: one window, coordinator keeps runs alive across switches, notice when switching during a run (D3). |

### Contradictions

| Finding | Resolution |
|---|---|
| Chat effort high in 4.2 versus medium in 8 | Patched: medium. |
| Chat max_tokens 32000 versus 8000 | Patched: 8000 streaming for chat. |
| ON-1.1 says File menu; design had a top-level Onboard menu | Patched: `CommandGroup(after: .newItem)` in the File menu; ON-1.1 unchanged. |
| ON-11.4 named a `Researching` protocol the design rejects | USER-STORIES amended: `LLMTransport` and `Narrating` seams. |
| ON-2.5 said majority refutation; design had one verifier per batch | Patched: two independent verifiers at standard and above, split verdicts become `unknown` and `disputed` (section 4.4); USER-STORIES amended. |
| ON-2.2 was P0 while build and test execution defaults to off (D12) | USER-STORIES amended: ON-2.2 is P1 and reads "when I opt in"; D12 stands (the app is unsandboxed). |
| videoBuildProbe used SceneDetector across same-file code cuts | Patched: per-scene-type pixel signatures at chapter start plus 0.25 s; SceneDetector only where the scene type changes (section 5). |
| Timeline step 3 was circular (hold from a function that needs step durations) | Patched: `TimelinePolicy.onboarding` has no source clamp; steps are built from the returned timeline (section 5). |
| Four versus five NSHostingView harnesses | Patched: five, named. |
| BUILD-LOG cited ARCHITECTURE.md before it existed | The file is written in the same session (S1) that cites it; the S1 entry records that it was drafted after the milestone table. |
| Append-only history versus dropped incomplete tool_use | Patched: the incomplete block is never persisted, so replay equals what the API produced (section 4.2). |
| ON-9.1 said "package manifest"; design sends a digest | USER-STORIES amended to the digest. |

### Unverified claims, each with the milestone that checks it

| Claim | Check |
|---|---|
| ElevenLabs with-timestamps request and response field names, output formats, tier gating | M4: read the ElevenLabs reference, record one real response as the fixture before writing the folding code; sentence estimate is the default until then. |
| Structured outputs (`output_config.format`) coexisting with a tool loop in one request | M5: verify in the claude-api skill or one live call; fallback is a strict `emit_artifact` tool as the final action. |
| SSE event inventory (thinking_delta, signature_delta, input_json_delta, ping, error) | M5: write `sseParseProbe` from a stream recorded in record mode, not from memory. |
| Gateway acceptance of count_tokens, array system with cache_control, strict, adaptive thinking, effort | M7: the run-start probe sends each optional field separately and records acceptance in manifest.json to auto-set `onboardingGatewayCompat`. |
| `@Environment(\.openWindow)` inside a `Commands` conformer on the macOS 14 floor | M3: `swift build`; fallback resolves openWindow from a hidden view via the coordinator. |
| `extractFrame` at exact cut times on a re-encoded sparse stills track | Patched to chapter start plus 0.25 s; M4 probe also samples total minus 0.1 s. |
| `git worktree add` on a user's clone leaves registrations behind | Patched to `git archive` for local clones; M2 probe checks `git worktree list` is untouched. |
| osxkeychain credential helper preempting GIT_ASKPASS | Patched: `-c credential.helper=` on clone; M7 human check on the signed app. |
| `/usr/bin/git` shim pops the CLT dialog | Patched: `xcrun --find git`. |
| PersistentRenderer snapshot scale on Retina and readiness on JS mutation | M4: `codeSceneProbe` asserts 1920 pixels wide after normalization and that `__wsReady` polling works without a navigation. |
| Overlapping SwiftPM resource rules (`.process("Resources")` plus `.copy` subfolders) | M1: `swift build`; fallback is a separate `OnboardingResources/` folder with one `.copy`. |
| Last still held for its full duration by every player | M1 `stillsWriterProbe` extracts a frame at total minus 0.1 s. |
| BrandedRenderer is MainActor and not reentrant | M4: check the declaration; keep the render lane at 1 regardless. |
| Model prices used by SpendMeter | M5: re-read the claude-api skill's model table at coding time; the table in `Defaults` is editable. |

### User-story gaps

Twelve behaviors implied by the design had no story. They were added to
USER-STORIES.md as ON-1.8 to ON-1.10, ON-8.7 to ON-8.9, ON-9.8, ON-9.9,
ON-10.4, ON-11.6, ON-12.4 and ON-12.5, and mapped to milestones there.

## 15. Human decisions of 2026-09-19 and the Research Packet contract

The human decided four things after reading sections 1 to 14. Each is recorded
here as an ADR, and the milestone list in section 11 is superseded by 15.6.

### D16. Mermaid is bundled
See D14. `mermaid.min.js` 11.4.1 is vendored as a resource with its hash in the
build log. Diagram scenes in videos and the hub render real Mermaid output.

### D17. Build and test execution stays optional per run
D12 stands as written: off by default, a checkbox with a plain warning, a
temporary copy, a timeout, no privileges, explicit could-not-run facts when off.

### D18. Depth is not a cap; the user watches progress and coverage
The former depth presets no longer bound the work. `complete` is the default
scope and means everything the evidence supports. The spend cap is optional.
The product surface that replaces the knob is the coverage tracker:
`packet/coverage.json` (15.4) rendered as a coverage map in FleetProgressView
during a run and in the hub afterwards. A producer that is not the in-app fleet
reports the same file, so the hub can always answer "what did the research not
read".

### D19. Research and content are separated by a Research Packet contract
Decision: the boundary between research and everything downstream is a
directory format, the Research Packet, with JSON Schemas as the normative
contract. Any tool can produce one: a coding agent working inside the target
repository (Claude Code with the skill shipped in this repo, which has far
better context on a project it has been working in than a cold fleet), the
in-app fleet, or a human editing JSON. The app validates a packet and builds
every deliverable from it: projectors, composer, video scripts, narration,
rendering, hub, chat. Nothing downstream of the packet knows or cares which
producer wrote it.

Alternatives: keep the fleet as the only producer (the earlier design); expose
the fleet's tool loop to external tools over a socket.

Why: the human's coding tools already hold deep project context and can run
the repository's own build and tests in their own sandbox; the packet lets that
knowledge flow into the package without re-deriving it. It also makes the two
halves testable apart: a checked-in fixture packet drives every content
milestone offline, and a producer is tested by validating its output.

Consequences: the in-app fleet moves to M11 and becomes the second producer;
the first useful release is "import a packet, get the package". The fleet
writes the same format, so the fact store semantics (evidence required,
anchors resolve, verifier verdicts, refuted facts excluded) are enforced at the
packet boundary by `PacketValidator` and not only inside the fleet. The
`facts/<unitId>.jsonl` files stay as the fleet's append-only working store and
are merged into `packet/facts.jsonl`.

### 15.1 Packet layout

```
<name>.packet/                       (or <package>/packet/ once imported)
  packet.json          PacketManifest: version, producer {name, version, model, startedAt, finishedAt},
                       repo {url, headSHA, defaultBranch, localPath}, scope, summary (one paragraph),
                       counts {facts, verified, refuted, traces, unreadDirs}
  inventory.json       tree summary: top-level dirs with file counts, languages by extension, entry point
                       candidates, manifests, CI files, infra files, docs files, generated dirs
  history.json         git mining tables: hotspots [{path, commits, lastTouched}], ownership per directory
                       [{dir, authors [{name, share}], busFactor}], stale [{path, lastTouched}],
                       parallel [{a, b, reason}], messageKeywords {revert, hotfix, fix, todo, fixme}
  dependencies.json    [{name, version, manifest anchor, license, eol, cves [{id, severity, url}] | "unknown"}]
  facts.jsonl          one Fact per line (2.5), evidence required, ids unique, status in
                       proposed | verified | refuted | unknown, verdicts inline
  paths.json           ranked critical paths [{id, title, entry anchor, rank, rationale, businessImpact}]
  traces/<pathId>.json ordered hops [{n, anchor, callSite, summary}], the ten concerns each
                       {status: present | absent | unknown, evidence [anchors]}, scaresMe [string]
  decisions.json       ADR seeds [{id, title, decision, alternatives, consequences, evidence}]
  glossary.json        [{term, definition, definedAt anchor}]
  coverage.json        15.4
  commands/<unit>/<n>.txt  optional: captured command output referenced by cmd:<unit>/<n> anchors
  drafts/              optional: docs/<docId>.md narrative drafts, scripts/<videoId>.json script drafts,
                       diagrams/<id>.mmd hand-drawn diagrams; the app treats drafts as proposals the
                       composer may keep, and validates their anchors like everything else
```

Every anchor uses the grammar in 2.2 and must resolve against the repository at
`packet.json.repo.headSHA`. Producers that cannot run git (a human) still write
`code:` anchors; the validator resolves them.

### 15.2 Validation rules (`validate_packet.py` and `PacketValidator`)

1. Every file present parses and matches its JSON Schema in
   `.claude/skills/onboarding-research/schema/` (kept with the skill so the
   skill folder is self-contained wherever it is installed).
2. Every anchor string parses; every `code:` anchor's `sha7` is a prefix of
   `repo.headSHA`; the path exists at that SHA and the line range is inside the
   file (checked with `git show <sha>:<path>` when a repository is given, else
   reported as unchecked).
3. Every fact has at least one evidence record; every evidence anchor resolves;
   `refuted` facts carry at least one refuting verdict with evidence.
4. Every trace hop anchor resolves; every one of the ten concerns is present
   with a status; every `paths.json` entry has a trace file.
5. Every `coverage.json` directory entry corresponds to an inventory directory;
   levels are consistent (a `traced` directory has facts).
6. Fact ids referenced from traces, decisions and drafts exist.
7. Completeness gates: zero facts, a placeholder summary, or no directory at
   level `mapped` or above are errors; a survey skeleton is not a packet.
8. The report lists errors (reject), warnings (accept, shown in the hub) and
   statistics (facts by kind and status, coverage by level). Exit code 0 only
   with zero errors.

### 15.3 Producers

- **Claude Code skill** (`.claude/skills/onboarding-research/`, M3). Run inside
  a checkout of the target repository. It performs the survey with git and the
  shell, fans research out to sub-agents per directory and per lens, runs
  verifiers, ranks and traces critical paths, writes the packet, and runs the
  validator before finishing. It records `producer.name = "claude-code-skill"`.
  Its acceptance test is the fixture repo: the produced packet validates with
  zero errors and covers the known facts (hotspot, bus factor, PII column,
  unapplied migration, idempotency gap, no rollback, old pinned dependency; `vendor/` never above `inventoried`).
- **In-app fleet** (M11). Writes the same layout into `<package>/packet/`,
  `producer.name = "walkthrough-studio-fleet"`.
- **Anything else** that passes the validator.

### 15.4 coverage.json

```
{ "version": 1, "headSHA": "...", "generatedAt": "...",
  "directories": [ { "path": "src/repo/", "files": 1, "filesRead": 1, "level": "traced",
                     "facts": 7, "verified": 6, "reason": null },
                   { "path": "vendor/", "files": 1, "filesRead": 0, "level": "unread", "facts": 0, "verified": 0,
                     "reason": "generated" } ],
  "paths": { "candidates": 4, "traced": 2, "untraced": [ { "id": "list-orders", "reason": "no evidence of external caller" } ] },
  "checks": [ { "check": "build", "status": "skipped", "reason": "runBuild off" },
              { "check": "tests", "status": "ran", "anchor": "cmd:buildtest/1" } ],
  "deliverablesPlanned": 24, "deliverablesProduced": 0 }
```

Levels, in order: `unread`, `inventoried` (listed only), `mapped` (facts
exist), `verified` (facts have verdicts), `traced` (a critical path passes
through it). The tracker in the UI shows each directory as a bar segmented by
level with files read over files present, and the untraced candidate list with
reasons.

### 15.5 Import flow in the app

`File > Onboard to a Codebase...` opens the OnboardSheet with two tabs:
"Research it here" (the fleet, M11) and "Import a Research Packet" (M2 onward).
Import asks for the packet folder and, when `repo.localPath` is absent or
stale, clones `repo.url` at `repo.headSHA`. It runs `PacketValidator`, shows
the report (errors block import, warnings are listed), copies the packet into
the new package, writes `manifest.producer`, and pends the content units:
diagrams, registers, traces, scripts, narration, render, transcript, hub. From
there the pipeline is exactly sections 5 to 8.

### 15.6 Milestones, revised (supersedes section 11's order; probes carry over)

| Milestone | Goal | Notes |
|---|---|---|
| M0 | Planning docs | done |
| M1 | Fixture repo, selftest scaffold, stills writer | `scripts/make-fixture-repo.sh` done and verified deterministic on Linux; Swift parts written, not compiled here |
| M2 | Package format, anchors, git, and the Research Packet contract | adds `PACKET.md`, the skill's `schema/*.json`, `validate_packet.py`, `survey_repo.py`, `PacketModels`, `PacketValidator`, `PacketImporter`, `--validate-packet`; probes `anchorRoundTripProbe`, `manifestRoundTripProbe`, `packageStoreProbe`, `gitRunnerProbe`, `packetValidateProbe` (the fixture packet validates; a packet with a dangling anchor, an orphan fact and a missing trace is rejected with those three errors) |
| M3 | Claude Code producer skill and the fixture packet | the skill under `.claude/skills/onboarding-research/`; the packet it produces for the fixture repo is checked in under `Sources/WalkthroughStudio/OnboardingResources/fixtures/fixture-repo.packet/` and validates with zero errors; `fixturePacketProbe` asserts the known facts are present |
| M4 | Player shell on the fixture package | as the old M3, with `FixturePackage.make` building from the M3 packet plus a hand-written script |
| M5 | Narration, scene renderer, transcript, code-ref map | as the old M4 |
| M6 | LLM runtime | as the old M5 |
| M7 | Playback chat agent | as the old M6 |
| M8 | Projectors: Mermaid diagrams, registers, traces from the packet | as the old M9, Mermaid only, plus the coverage map card in the hub |
| M9 | Video scripts and the series | as the old M10 |
| M10 | Hub, cross-links, search, export, coverage tracker | as the old M11 plus the tracker |
| M11 | In-app research fleet, the second producer | the old M7 and M8 merged: fleet runtime, survey units, research units, progress and coverage tracker live in FleetProgressView; writes `packet/` |
| M12 | Review, staleness, end-to-end smoke, hardening | as the old M12; `smokeEndToEndProbe` runs the import path on the fixture packet and, separately, the fleet path with fixtures |

The build log's milestone table follows this list from S2 onward.
