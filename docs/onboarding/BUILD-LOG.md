# Onboard to a Codebase: build log

This log is the memory of the build. Every session that touches the feature appends
one entry, most recent LAST, using the template below. A fresh session reads the
last two entries, the "Next" list, and ARCHITECTURE.md before doing anything.

Rules:
- Append, never rewrite history. Corrections go in a new entry.
- Record what was VERIFIED (selftest probe name, or "not verified"), not only what
  was written.
- Record every limit hit (context, session, API, disk) and the exact resume point.
- Every entry ends with a "Next" list that a stranger could execute.
- Keep the milestone table below current. It is the only status dashboard.

## Milestone status

Milestones are defined in ARCHITECTURE.md. Status: `planned`, `in-progress`,
`built` (compiles, not probed), `verified` (selftest probe passes), `blocked`.

| Milestone | Status | Probe | Last session |
|---|---|---|---|
| M0 Planning docs (user stories, architecture, build log) | verified | n/a (docs) | S2 |
| M1 Fixture repo, selftest scaffold, stills writer | built (not compiled) | fixtureRepoProbe, stillsWriterProbe | S2 |
| M2 Package format, anchors, git, Research Packet contract | in-progress (Swift half built, not compiled; packet half: Python contract done, Swift pending) | anchorRoundTripProbe, manifestRoundTripProbe, packageStoreProbe, gitRunnerProbe, packetValidateProbe | S2 |
| M3 Claude Code producer skill and the fixture packet | in-progress | fixturePacketProbe (plus scripts/validate-packet.py with zero errors) | S2 |
| M4 Player shell on the fixture package | planned | fixturePackageProbe, coderefsLookupProbe, linkRouterProbe, markdownLiteProbe, backlinkIndexProbe, onboardSheetProbe, playerStageProbe | |
| M5 Narration, scene renderer, transcript, code-ref map | planned | timelineMathProbe, codeSceneProbe, sceneKindsProbe, transcriptMapProbe, videoBuildProbe, audioCacheProbe | |
| M6 LLM runtime (tool loop, SSE, retries, spend, resume) | planned | sseParseProbe, toolLoopProbe, agentResumeProbe, backoffProbe, spendMeterProbe | |
| M7 Playback chat agent | planned | chatContextProbe, citationParserProbe, chatToolLoopProbe, contradictionFlagProbe, chatPanelProbe | |
| M8 Projectors: Mermaid diagrams, registers, traces | planned | diagramLinksProbe, diagramRenderProbe, registerLinksProbe, landminesDocProbe, traceMermaidProbe, coverageCardProbe | |
| M9 Video scripts and the series | planned | scriptInvariantsProbe, traceVideoChaptersProbe, regenerateOneProbe, seriesSmokeProbe | |
| M10 Hub, cross-links, search, export, coverage tracker | planned | hubLinkProbe, searchIndexProbe, hubExportProbe, hubViewProbe, coverageTrackerProbe | |
| M11 In-app research fleet (second producer) | planned | checkpointResumeProbe, gitMiningProbe, buildRunnerProbe, toolSandboxProbe, orphanFactProbe, fleetProgressProbe, fleetSmokeProbe, verifierRejectProbe, traceConcernsProbe, spendCapProbe | |
| M12 Review, staleness, end-to-end smoke, hardening | planned | smokeEndToEndProbe, stalenessProbe, reviewStateProbe, secretLeakProbe | |

The table was rewritten in S1 (synthesized order) and again in S2 (the human's
decision to separate research from content behind a Research Packet contract
moved the in-app fleet to M11 and added the producer skill as M3). Both
rewrites are recorded in their entries. No further rewrite without an entry.

## Entry template

```
### S<n>: <date> — <one-line summary>
Milestone(s): M<x>
Built:
- <file or type>: <what>
Verified:
- <probe name> PASS | not verified: <why>
Broke / learned:
- <landmine, with the fix or the workaround>
Limits hit:
- <context | session | API | disk>: <where it stopped, exact resume point>
Next:
1. <concrete step a stranger could execute>
```

## Entries

### S1: 2026-09-19 — Planning: user stories, architecture, build log
Milestone(s): M0
Built:
- docs/onboarding/USER-STORIES.md: 12 epics, 83 stories with stable IDs and
  acceptance criteria, a story-to-milestone map; twelve stories were added and
  five amended after the critic pass (see ARCHITECTURE.md section 14).
- docs/onboarding/ARCHITECTURE.md: synthesized from three independent design
  proposals judged under feasibility, experience and risk lenses, then reviewed
  by a completeness critic whose 51 findings are resolved in its section 14.
  Contains the package format, fleet runtime, video generation, transcript and
  coderef formats, player, playback agent, decisions, milestones, risks.
  Correction: the milestone table and this entry cited the file before it was
  written; it was drafted last in this session and committed with this entry.
- docs/onboarding/BUILD-LOG.md: this file.
Verified:
- not verified: no code written this session by design (the human asked to pause
  before coding to switch effort level).
Broke / learned:
- Nothing built. The fleet must never call `StudioViewModel.run()`; it gets its
  own `OnboardingViewModel` and its own `Window` scene (ARCHITECTURE.md D3).
- Any new headless flag must extend `applicationShouldTerminateAfterLastWindowClosed`
  (it matches the literal `--selftest` today) or the first offscreen render
  window closing kills the run. Do this in M1 before any render probe.
- The milestone table was provisional when first written and was rewritten once
  in this session to the synthesized order (player before fleet). Recorded here
  so the "append, never rewrite" rule has its one documented exception.
Limits hit:
- The design workflow ran fourteen agents over about ninety minutes; no context
  limit was hit in this session. The next session starts cold from these docs.
Next:
1. Read ARCHITECTURE.md sections 2, 9 and 11, then USER-STORIES.md epic 11.
2. Start M1: `scripts/make-fixture-repo.sh` (deterministic two-author repo
   described in ARCHITECTURE.md section 9), the `--selftest-onboarding` flag,
   the terminate-guard prefix change, `SelfTestSupport.swift`,
   `SelfTestOnboarding.swift`, and `StillsVideoWriter.swift`.
3. Run both selftests on the Mac, look at the stills mp4, append entry S2.
4. Ask the human the section 13 questions (Mermaid bundling, build/test opt-in,
   package location, depth and spend defaults) before M7 and M9 need answers.

### S2: 2026-09-19 — Build start: decisions, packet contract, skill, M1/M2 Swift, fixture packet research
Milestone(s): M0 (revision), M1, M2, M3
Built:
- Architecture D16 to D19 (Mermaid bundled, build/test opt-in, no depth cap plus
  coverage tracker, Research Packet contract) and the revised milestone order
  (ARCHITECTURE.md section 15); USER-STORIES epic 13; PACKET.md.
- .claude/skills/onboarding-research/: SKILL.md, schema/*.json (10 schemas),
  scripts/survey_repo.py, validate_packet.py, assemble_packet.py, templates/
  (mapper, lens, verifier, ranker, tracer). Wrappers scripts/validate-packet.py
  and scripts/survey-repo.py.
- scripts/make-fixture-repo.sh (deterministic, head fb63e78744ce026d810547afbb62c0a08ce2040a).
- Sources/WalkthroughStudio/OnboardingResources/hub/vendor/mermaid.min.js 11.4.1
  (sha256 a43bc1af...6f9e) plus license; Package.swift `.copy("OnboardingResources")`.
- Swift, M1: Services/StillsVideoWriter.swift, SelfTestSupport.swift,
  SelfTestOnboarding.swift (runner, fixtureRepoProbe, stillsWriterProbe),
  WalkthroughStudioApp.swift (`--selftest-onboarding`, `hasPrefix("--selftest")`
  guard), SelfTest.swift (sineWAV made internal).
- Swift, M2 non-packet half: Onboarding/Package/Anchor.swift,
  OnboardingModels.swift, PackageStore.swift, BuildLog.swift, GitRunner.swift,
  RepoAcquisition.swift, Services/Keychain.swift (githubToken account),
  SelfTestOnboarding+Package.swift, SelfTestOnboarding+Git.swift (four probes).
  About 3,700 lines written by three agents without a compiler; the read-through
  review and fix pass is recorded below when it lands.
- Fixture packet research (M3): 4 mapper units and 5 lens units produced 213
  facts, all 254 anchors resolving at the pinned SHA, no secret leaked; 30
  glossary terms; dependencies filled with url: evidence.
Verified:
- scripts/make-fixture-repo.sh: two runs give the same head SHA; probe facts
  (6 touches of orders_repo.py, deploy.sh dated 2025-01-04, email in schema,
  tests print PASS) checked by hand on Linux.
- survey_repo.py: byte-identical output across two runs on the fixture.
- validate_packet.py: rejects a survey skeleton (no facts, placeholder summary,
  nothing mapped); accepts the early packet with 0 errors apart from the pending
  summary. Not yet a Swift probe.
- not verified: every Swift file (no toolchain in this Linux session).
Broke / learned:
- `git shortlog` with no revision reads stdin and hangs when stdin is not a
  terminal; always pass HEAD. Fixed in make-fixture-repo.sh.
- Fixed commit dates: use git's raw `<epoch> +0000` format; a formatted
  YYYY-MM-DD overflowed past January 31.
- `.process("Resources")` and a `.copy` of a subfolder overlap; onboarding assets
  moved to a sibling `OnboardingResources/` with one `.copy` rule (unverified
  until `swift build` on the Mac).
- A mapper read vendor/ despite the instruction; coverage reports it honestly
  (`inventoried`, 1/1 read). Generated directories nobody opened stay `unread`.
- CVE ids from a lens need url: evidence; the validator now warns otherwise.
- Workflow scripts have no filesystem access: unit outputs are merged by
  assemble_packet.py outside the workflow (scratchpad/split_units.py splits the
  journal into the units/ layout).
Limits hit:
- Session usage limit at about 12:50 UTC (reset 16:40 UTC) killed 22 agents:
  Swift workflow wf_132b805e-587 finished 3 of 6 (writers done; both reviewers
  and the fixer failed); packet workflow wf_31862102-df9 finished 9 of 28
  (mappers and lenses done; all 18 verifiers and the ranker failed; tracers and
  decisions never started). WIP checkpoints of the Swift were pushed as
  commits a9e74c3 through b79c9a4. Resume point: `Workflow({scriptPath,
  resumeFromRunId})` for each run, which replays completed agents from cache;
  resumed at 18:41 UTC.
Next:
1. When the packet workflow finishes: scratchpad/split_units.py <journal> units/;
   assemble_packet.py --packet <survey copy> --units units/ --repo <fixture>
   --model claude-fable-5-1; fix validator errors; copy into
   Sources/WalkthroughStudio/OnboardingResources/fixtures/fixture-repo.packet/.
2. When the Swift review and fix finish: commit, then a workflow for the packet
   half of M2 (PacketModels, PacketValidator, PacketImporter, `--validate-packet`,
   packetValidateProbe, fixturePacketProbe) mirroring validate_packet.py rules.
3. On the Mac: `swift build`; fix compile errors; `scripts/make-fixture-repo.sh
   /tmp/fixture-repo`; `./.build/debug/WalkthroughStudio --selftest-onboarding
   /tmp/fixture-repo /tmp/onboarding-out`; then the existing `--selftest`; look
   at stills-probe.mp4.
