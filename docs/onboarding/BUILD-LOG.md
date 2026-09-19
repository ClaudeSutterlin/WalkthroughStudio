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
| M0 Planning docs | verified | n/a (docs) | S1 |
| M1 Fixture repo + feature selftest scaffold | planned | | |
| M2 Package format + manifest + anchors | planned | | |
| M3 Research fleet runtime (tool-use loop, artifact store, resume) | planned | | |
| M4 Git mining + build/test runner units | planned | | |
| M5 Architecture map + diagrams | planned | | |
| M6 Registers | planned | | |
| M7 Critical path traces | planned | | |
| M8 Video script generation | planned | | |
| M9 Scene renderer + narration + transcript + coderefs | planned | | |
| M10 Hub + code view + cross-links | planned | | |
| M11 Playback chat agent | planned | | |
| M12 Review, staleness, export | planned | | |

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
- docs/onboarding/USER-STORIES.md: 12 epics, stable story IDs, acceptance criteria.
- docs/onboarding/ARCHITECTURE.md: synthesized from three independent design
  proposals judged under feasibility, experience and risk lenses, with a
  completeness critic pass. Contains the package format, fleet runtime, video
  generation, transcript and coderef formats, player, playback agent, milestones.
- docs/onboarding/BUILD-LOG.md: this file.
Verified:
- not verified: no code written this session by design (the human asked to pause
  before coding to switch effort level).
Broke / learned:
- Nothing built. The repo's existing `run()` single-flight gate and the
  `autoPipelineCore()` pattern must be respected by the fleet runner (see
  CLAUDE.md); nesting `run()` was a real bug once.
Limits hit:
- none.
Next:
1. Read ARCHITECTURE.md "Milestones" and start M1: `scripts/make-fixture-repo.sh`
   plus `--selftest-onboarding` entry point in SelfTest.swift that currently only
   asserts the fixture exists and the package directory is created.
2. Then M2: `OnboardingPackage` types and the anchor scheme, with a probe that
   round-trips `manifest.json`.
