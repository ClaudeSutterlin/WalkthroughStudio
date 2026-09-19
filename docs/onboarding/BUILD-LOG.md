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
| M0 Planning docs (user stories, architecture, build log) | verified | n/a (docs) | S1 |
| M1 Fixture repo, selftest scaffold, stills writer | planned | fixtureRepoProbe, stillsWriterProbe | |
| M2 Package format, anchors, store, git | planned | anchorRoundTripProbe, manifestRoundTripProbe, packageStoreProbe, gitRunnerProbe | |
| M3 Player shell on a generated fixture package | planned | fixturePackageProbe, coderefsLookupProbe, linkRouterProbe, markdownLiteProbe, backlinkIndexProbe, onboardSheetProbe, playerStageProbe | |
| M4 Narration, scene renderer, transcript, code-ref map | planned | timelineMathProbe, codeSceneProbe, sceneKindsProbe, transcriptMapProbe, videoBuildProbe, audioCacheProbe | |
| M5 LLM runtime (tool loop, SSE, retries, spend, resume) | planned | sseParseProbe, toolLoopProbe, agentResumeProbe, backoffProbe, spendMeterProbe | |
| M6 Playback chat agent | planned | chatContextProbe, citationParserProbe, chatToolLoopProbe, contradictionFlagProbe, chatPanelProbe | |
| M7 Fleet runtime and deterministic survey units | planned | checkpointResumeProbe, gitMiningProbe, buildRunnerProbe, toolSandboxProbe, orphanFactProbe, fleetProgressProbe | |
| M8 Research fleet (plan, map, lens, verify, rank, trace) | planned | fleetSmokeProbe, verifierRejectProbe, traceConcernsProbe, spendCapProbe | |
| M9 Diagrams and registers | planned | diagramLinksProbe, diagramRenderProbe, registerLinksProbe, landminesDocProbe, traceMermaidProbe | |
| M10 Video scripts and the series | planned | scriptInvariantsProbe, traceVideoChaptersProbe, regenerateOneProbe, seriesSmokeProbe | |
| M11 Hub, cross-links, search, export | planned | hubLinkProbe, searchIndexProbe, hubExportProbe, hubViewProbe | |
| M12 Review, staleness, end-to-end smoke, hardening | planned | smokeEndToEndProbe, stalenessProbe, reviewStateProbe, secretLeakProbe | |

The table above was rewritten once in S1, after the architecture was synthesized,
to match ARCHITECTURE.md section 11 (player before fleet). It replaces the
provisional twelve rows drafted earlier in the same session. No later rewrite of
the milestone list is allowed without an entry explaining it.

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
