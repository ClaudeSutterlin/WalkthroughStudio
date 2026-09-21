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
| M1 Fixture repo, selftest scaffold, stills writer | verified on the Mac | fixtureRepoProbe, stillsWriterProbe | S3 |
| M2 Package format, anchors, git, Research Packet contract | verified on the Mac | anchorRoundTripProbe, manifestRoundTripProbe, packageStoreProbe, gitRunnerProbe, packetValidateProbe | S3 |
| M3 Claude Code producer skill and the fixture packet | verified, standalone and via fixturePacketProbe on the Mac | fixturePacketProbe (plus scripts/validate-packet.py with zero errors) | S2 |
| M4 Player shell on the fixture package | planned | fixturePackageProbe, coderefsLookupProbe, linkRouterProbe, backlinkIndexProbe, onboardSheetProbe, playerStageProbe (markdownLiteProbe landed early, in M8) | |
| M5 Narration, scene renderer, transcript, code-ref map | planned | timelineMathProbe, codeSceneProbe, sceneKindsProbe, transcriptMapProbe, videoBuildProbe, audioCacheProbe | |
| M6 LLM runtime (tool loop, SSE, retries, spend, resume) | planned | sseParseProbe, toolLoopProbe, agentResumeProbe, backoffProbe, spendMeterProbe | |
| M7 Playback chat agent | planned | chatContextProbe, citationParserProbe, chatToolLoopProbe, contradictionFlagProbe, chatPanelProbe | |
| M8 Projectors: Mermaid diagrams, registers, traces | Python verified; Swift port complete, parity probe written, not yet compiled | markdownLiteProbe, projectorParityProbe (these supersede the six planned per-deliverable probes: one diffs every projected file against the golden projection, the other holds the converter to an adversarial corpus) | S5 |
| M9 Video scripts and the series | planned | scriptInvariantsProbe, traceVideoChaptersProbe, regenerateOneProbe, seriesSmokeProbe | |
| M10 Hub, cross-links, search, export, coverage tracker | hub built and driven in a browser; Swift wiring pending | hubLinkProbe, searchIndexProbe, hubExportProbe, hubViewProbe, coverageTrackerProbe | |
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
- Swift, M2 packet half: Onboarding/Packet/PacketModels.swift (every packet
  record plus `ResearchPacket` and `PacketReader`), PacketValidator.swift (the
  Swift twin of validate_packet.py: schema constraints, anchor resolution
  through `PacketAnchorResolver`, the cross-file rules, completeness gates,
  `PacketValidationReport` with the Python console wording),
  PacketImporter.swift, `--validate-packet <packetDir> <repoDir>` in
  WalkthroughStudioApp.swift, and SelfTestOnboarding+Packet.swift with
  `packetValidateProbe` (M2) and `fixturePacketProbe` (M3), both registered in
  `SelfTestOnboarding.runOnboarding`. `GitRunner.treeExists` added for it.
  About 2,900 lines, again written without a compiler; the review and fix pass
  is recorded below.
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
- Swift read-through review (two reviewers, no compiler) of the M1/M2 files,
  and what the fixer changed:
  - `RepoAcquisition.acquire`, `.url` branch on reopen: `git fetch` never moves
    the clone's own HEAD, so an unpinned re-acquire re-pinned the ORIGINAL
    clone-time sha instead of the default branch head section 3 promises. Now
    resolves `refs/remotes/origin/HEAD` after the fetch and falls back to `HEAD`
    only when that ref is missing (older clones); fresh clones and `.local`
    keep `pinnedSHA ?? "HEAD"`.
  - `SelfTestSupport.runProcess`: drained stdout to EOF and then stderr on the
    calling thread (two-pipe deadlock once a child writes > 64 KB to stderr;
    no timeout). Both pipes now drain on background queues into a
    lock-protected `StreamBuffer`, with a `timeout` parameter (default 120 s)
    that SIGKILLs the child and throws `StudioError`, mirroring
    `GitRunner.Child`.
  - `GitRunner.parseLinePorcelain`: `let final = Int(parts[2])` bound a
    contextual keyword as an identifier; renamed to `finalLineNumber`. The
    codebase otherwise avoids keyword identifiers (`override` is backticked in
    `OnboardingManifest.Models`).
  - `WalkthroughStudioApp`: `--probe` was parsed into a `var onlyProbe`
    captured by the `Task { @MainActor in }` closure; now an immediately
    evaluated `let` like the existing `--selftest` block.
  - Contract mismatch, not code: ARCHITECTURE.md rows M1 (lines 83 and 530)
    named `pixel(_:x:y:)` and a `snapshot(view:size:appearance:)` helper. The
    implementation is `pixel(in:x:y:)` and `snapshot` is deferred until the
    onboarding sheet probes need the offscreen-snapshot pattern; both rows now
    say so. The five NSHostingView harnesses in SelfTest.swift are untouched.
  - Left as is, to revisit only if the Mac run fails: `StillsVideoWriter`
    relies on `endSession(atSourceTime: total + trailingHold)` to hold the last
    sample for the trailing second (if stills-probe.mp4 measures ~9.5 s, add a
    schedule entry at `total + trailingHold - repeatInterval`);
    `manifestRoundTripProbe` asserts Foundation's pretty-printed text
    (`"createdAt" : "2026-09-21T14:13:20Z"`, `"capUSD" : 25`), the first
    assertion to relax to value checks if it fails.
- Swift read-through review of the M2 packet half (no compiler), and what the
  fixer changed. The theme: every finding but one was the Swift and Python
  validators disagreeing about the SAME packet, which is the one thing this
  contract cannot afford — a producer diffs the two reports.
  - Schema conformance (PACKET.md section 7 rule 1) had no Swift equivalent at
    all: only the cross-file rules ran, so a packet `validate_packet.py`
    rejects imported cleanly. Added `PacketValidationRun.checkSchemaConstraints`
    for the constraints that matter — fact `id` pattern, `claim` 10 to 600,
    `confidence` 0 to 1, fact `kind`/`status`, `verdicts[].verdict`,
    `entryPoints[].kind`, `checks[].check`/`status`, `cves[].severity`,
    `dependencies[].ecosystem`, non-empty `hops`, the five required
    `messageKeywords` keys — at the locations and in the wording jsonschema
    produces (`facts.jsonl:<n>:confidence`, `'x' is not one of ['a', 'b']`).
    The fact kind/status and coverage level/concern status checks moved out of
    the hand-rolled passes into it so each defect is reported once, at the
    schema's own location. `additionalProperties: false` stays unenforced on
    purpose (the models ignore unknown keys); the header says so.
  - Fact messages were numbered from the array index, i.e. among the NON-BLANK
    lines; Python numbers the real file line. One blank line in facts.jsonl and
    every location below it disagreed. `ResearchPacket` now carries
    `factLines` (parallel to `facts`) and `factLine(at:)`; the existing
    `sourceLine(ofFact:)` is deliberately not used here, since it holds the
    first line for an id and would point a duplicate-id error at the original.
  - `PacketAnchorResolver.directoryExists` used `git ls-tree -r` and accepted
    any output, so `code:src/api/orders_handler.py/@fb63e78` — a file with a
    stray slash — resolved in Swift and failed in Python. New
    `GitRunner.treeExists` runs `ls-tree -d --name-only`, which matches trees
    only (verified against the fixture repo: `src` and `db` answer, a file path
    gives empty output).
  - The sha7 pin check lowercased the anchor's sha while `Anchor.isHex` accepts
    A-F, so `...@FB63E78` passed in Swift; Python's `CODE_RE` is lowercase-only,
    so there the anchor is not pinned at all. Swift now rejects a non-lowercase
    sha7 with Python's own wording ("code anchor without @sha7 ...").
  - `--validate-packet` printed a reader failure at the packet DIRECTORY
    (`ERROR   fixture-repo.packet: facts.jsonl: file missing`) where Python
    prints `ERROR   facts.jsonl: file missing`. Added
    `PacketReader.splitFileReason`, which unwraps `<file>: <reason>` only when
    the prefix is a location the reader produces; the tool also prints a
    `stats   {}` line now, like `finish()`. Still open, and noted for a later
    session: `PacketReader.load` throws on the FIRST bad file instead of
    collecting per-file failures into the report, so a broken packet yields one
    error where Python yields the whole report.
  - `PacketImporter.importPacket` replaced `packet/` before writing the
    manifest, so a failing manifest write left the new producer's packet under
    the old producer's name — the half-imported state the file header forbids.
    The pure part is now `manifest(for:in:)`, built before the copy; only the
    atomic write follows it.
  - The no-repository warning's wording ("no repository given" vs Python's
    "no --repo given") is now a documented, deliberate exception, with the
    header naming both known exceptions instead of claiming identical wording.
  - Two findings rejected after checking them against the tree. (1) A reviewer
    read the two new probes as unconditional on a fixture packet that "does not
    exist yet" and asked for them to be skipped; the packet landed in this same
    session (commit 94cc274) and ships via `.copy("OnboardingResources")`, so
    both probes stay hard failures. (2) A reviewer called
    `fixturePacketProbe`'s `busFactor == 1` assertion over-specified because
    two authors "could" yield 2; with two authors one of them always holds at
    least 50 percent of a directory's commits, and all nine ownership entries
    in the checked-in packet are 1. The assertion stands, with a comment
    explaining why, and the `FixturePacketFacts` constants are now labelled as
    the producer/content contract rather than probe guesses.
Limits hit:
- Session usage limit at about 12:50 UTC (reset 16:40 UTC) killed 22 agents:
  Swift workflow wf_132b805e-587 finished 3 of 6 (writers done; both reviewers
  and the fixer failed); packet workflow wf_31862102-df9 finished 9 of 28
  (mappers and lenses done; all 18 verifiers and the ranker failed; tracers and
  decisions never started). WIP checkpoints of the Swift were pushed as
  commits a9e74c3 through b79c9a4. Resume point: `Workflow({scriptPath,
  resumeFromRunId})` for each run, which replays completed agents from cache;
  resumed at 18:41 UTC.
Packet result (M3, end of session):
- The fixture packet validates with zero errors and zero warnings and is checked
  in at Sources/WalkthroughStudio/OnboardingResources/fixtures/fixture-repo.packet/
  (600 KB, 15 files). 213 facts (206 verified, 5 refuted, 2 unknown) from 4
  mappers and 5 lenses, judged by 18 paired verifier units (410 confirmed, 12
  refuted, 4 unknown). 4 critical paths traced out of 10 candidates, each of the
  6 untraced with a reason. 10 decisions, 30 glossary terms, 2051 anchors all
  resolving at fb63e787. No secret from config/settings.example appears anywhere
  in the packet.
- Acceptance findings all present: the orders_repo hotspot, bus factor 1 per
  directory, users.email as PII, migration 002 written but unapplied, the
  idempotency gap (order-creation trace marks the concern absent with four
  evidence anchors), no rollback in deploy.sh, the stale requests 2.19.0 pin.
- Acceptance criterion corrected: vendor/ reaching level `verified` is honest,
  not a failure. A mapper read the generated stub and found something real
  (protoc output that nothing imports, with no .proto source or protoc step), so
  the criterion now requires generated directories to be flagged with a reason
  rather than to stay unread.

Packet-half Swift (M2, end of session):
- PacketModels, PacketValidator, PacketImporter, SelfTestOnboarding+Packet and
  the `--validate-packet <packetDir> <repoDir>` flag are written (about 3,400
  lines) and reviewed by a read-through that found no compile errors, two
  runtime bugs and five contract mismatches; the fixer applied seven findings
  and rejected two with evidence from the tree.
- Because there is no Swift compiler here, fixturePacketProbe's eight assertions
  were simulated in Python against the checked-in packet. Two failed and both
  were real:
  (a) `pii` was prose ("yes: email is marked PII in schema") rather than a
      boolean, so the ERD projector could not colour a node by it. The contract
      now requires a boolean or "unknown" with the nuance in `piiNote`, the
      assembler normalises it (5 facts here), and PACKET.md, the fact schema and
      the mapper template say so.
  (b) the probe still demanded vendor/ stay unread. Rewritten to assert what
      actually matters: inventory flags generated directories with a reason, and
      coverage never claims a level the read count cannot support.
  All eight assertions now pass against the real packet data, which is the
  closest this environment can get to running the probe.

M8 projectors (reference implementation, end of session):
- `.claude/skills/onboarding-research/scripts/project_packet.py` turns a validated
  packet into 4 diagrams, 14 registers, 4 trace documents, a hub index and a
  backlink index, deterministically and with no model in the loop. The Swift
  DiagramProjector, RegisterProjector and HubProjector mirror it, as
  PacketValidator mirrors validate_packet.py.
- `scripts/render-mermaid.mjs` renders any folder of .mmd through the vendored
  Mermaid build in headless chromium and writes SVG plus PNG. This is the
  verification harness for diagrams in an environment with no Swift toolchain,
  and it is how the defects below were found.
- Verified: every fact is projected with its citation, and zero refuted facts
  reach any deliverable (asserted by the projector's own exit code). All eight
  .mmd files render.

Broke / learned (diagrams, all found by rendering and looking, never by reading):
- `git mv -k` silently no-ops on an untracked file and still exits 0, so the
  `|| mv` fallback never fired and the following `rm -rf` of the old directory
  destroyed the vendored mermaid.min.js. It was never committed and nobody
  noticed for a day. Restored from the scratchpad copy, hash re-verified against
  the pin in MERMAID-LICENSE.txt, and committed this time. Never chain
  `git mv -k` with a `||` fallback.
- A `%%{init}%%` theme directive inside the .mmd made Mermaid mark the element
  processed and emit no SVG at all. `mermaid.run()` also races its own
  startOnLoad pass. Use `mermaid.render(id, text)` and pass brand tokens through
  `initialize`; the .mmd files stay portable and BrandTheme stays the one source
  of brand tokens.
- Mermaid parses labels as markdown, so a backtick in a trace summary renders as
  "Unsupported markdown: codespan" instead of the label. Producers write
  backticks constantly, so the projector strips them.
- A trace walks into callees and back out, so drawing an edge per consecutive hop
  pair produced arrows pointing backwards (repo to handler). Edges now run from
  an earlier first appearance to a later one, which is what a call tree is.
- A parent directory that is itself an edge endpoint cannot be rendered as a bare
  subgraph, or Mermaid invents a phantom node for the group id. `db/` holds
  schema.sql, so it stays a real node.
- Chaining deployStep findings with arrows asserted a sequence the evidence does
  not support (several are observations such as "CI is not a gate"). The
  deployment diagram is now built from the deploy trace's ordered hops, with CI
  drawn as a dashed, disconnected node, which is the finding itself.
- Labels were truncating mid-word ("deploy/de"); they now break on word
  boundaries.

M10 hub (end of session):
- `Sources/WalkthroughStudio/OnboardingResources/hub/{hub.html,hub.css,hub.js}` is the
  real viewer: three panes (recommended order, stage, companion), one `route()`
  resolver over the anchor grammar (mirroring LinkRouter), live Mermaid with
  clickable nodes, a code view with line highlighting, a directory view, a
  backlink panel, search, and the coverage tracker from D18. The app loads these
  files in a WKWebView and HubExporter ships them verbatim, so this is product
  code, not a harness.
- The projector now also emits `docs/*.html` and `traces/*.html` (the reference
  for MarkdownLite: same slugs, same chip extraction) and `code/<path>.json` plus
  `code/index.json` for every file a deliverable cites, so anchor-to-code works
  with no git in the static export.
- Verified by serving the package and driving it in headless chromium: 21 items in
  the recommended order, 13 clickable diagram nodes, diagram node to directory
  view, doc chip to code view at the right lines, backlinks populated, 12 search
  hits, and no page errors (the one 404 is the browser asking for a favicon).

Broke / learned (hub):
- Container nodes carry directory anchors, which have no file to open. The hub
  consults `code/index.json` first and shows a directory listing instead of
  fetching a 404 on every container click.
- Mermaid's default note colour is yellow, which broke the brand on the trace
  sequence diagrams; note, actor and signal colours are now set explicitly in
  both the hub and the render harness.

Skill packaging sweep (end of session):
- `.claude/skills/onboarding-research/` is a complete, installable skill: SKILL.md
  with frontmatter, 10 JSON Schemas, 5 unit prompt templates, and 5 scripts
  (survey, assemble, validate, project, make_fixture_repo).
- Portability was tested, not assumed: the folder was copied on its own to a
  scratch directory and run from there. It built its own fixture repository,
  surveyed it, assembled and validated a packet with zero errors, and projected
  the full deliverable set. No reference to this repository is needed at runtime.
- Two references did dangle and are fixed: SKILL.md pointed at
  docs/onboarding/PACKET.md and at scripts/make-fixture-repo.sh "in the
  Walkthrough Studio repository". The skill now carries reference/PACKET.md and
  scripts/make_fixture_repo.sh, and `scripts/check-skill-sync.sh` fails the verify
  loop if either copy drifts from the repository's.

Next:
1. When the packet workflow finishes: scratchpad/split_units.py <journal> units/;
   assemble_packet.py --packet <survey copy> --units units/ --repo <fixture>
   --model claude-fable-5-1; fix validator errors; copy into
   Sources/WalkthroughStudio/OnboardingResources/fixtures/fixture-repo.packet/.
3. On the Mac: `swift build`; fix compile errors; `scripts/make-fixture-repo.sh
   /tmp/fixture-repo`; `./.build/debug/WalkthroughStudio --selftest-onboarding
   /tmp/fixture-repo /tmp/onboarding-out`; then the existing `--selftest`; look
   at stills-probe.mp4.

### S5: 2026-09-21 — M8 complete: the Swift projectors, and fuzzing found two real divergences
Milestone(s): M8
Built:
- `MarkdownLite.swift` — the markdown subset plus the `[[anchor]]` citation grammar:
  `esc`, `anchorLabel`, `inlineHTML`, `toHTML`, and one `scanCitations` shared by the
  chip renderer and the backlink index.
- `HubProjector.swift` — `hub/index.json` (reading order, minutes, coverage summary)
  and `index/anchors.json` (anchor -> every deliverable citing it). The hub
  republishes `packet.json` and `coverage.json` sub-objects **verbatim** rather than
  re-encoding the decoded models: a date the producer wrote as
  `2025-02-06T10:00:00+00:00` should reach the reader that way, and a field a future
  schema adds should travel even though this build knows nothing about it.
- `PackageProjector.swift` — orchestrates the three projectors, writes every file,
  and (given a checkout) emits the cited sources at the pinned commit so a package
  shared as a folder needs no git.
- `projectorParityProbe` — runs the Swift over the fixture packet and diffs against
  `fixture-repo.golden`. Markdown and Mermaid byte for byte; JSON as values, because
  object key order is not meaningful and the two languages order it differently.
  Array order is meaningful and is compared.
- `markdownLiteProbe` plus `markdown-lite-cases.json`, 576 adversarial cases whose
  expectations the reference computed, regenerable with
  `scripts/make-markdown-cases.py`. The golden projection only covers friendly prose;
  every case in the corpus is a shape that once produced different output on the two
  sides, and the regression list is append-only.
- `OrderedJSONObject` and `Diagram.nodeOrder`: Python dicts keep insertion order and
  `build_backlinks` walks the diagram nodes in it to build a JSON **array**. A Swift
  `[String: Any]` would have reordered that at random.
Verified (no Swift toolchain in this container, so: everything except compiling):
- The checked-in golden projection is current: regenerating it from the reference
  produces byte-identical files.
- **The algorithms were transcribed back into Python and fuzzed against the
  reference regexes.** 18 real documents, 326 real anchors, then 40,000 random
  inline strings, 40,000 random markdown documents and 144,694 random anchors drawn
  from a markdown-hostile alphabet. Final count: **0 divergences**.
- The demo pipeline still builds and serves: fixture repo, packet validates with 0
  errors, 4 diagrams, 14 registers, 4 traces, 21 hub items, 137 backlinked anchors,
  15 code files, hub and a generated HTML page both served 200.
- `scripts/check-skill-sync.sh` clean.
- not verified: none of this Swift has been compiled or run.
Broke / learned:
- **The fuzz found two real bugs, both invisible in the fixture.** First, my anchor
  parser took the last `#` in a `code:` anchor and gave up when what followed was
  not a line span — so every chip for a path containing a hash (`c#-samples/x.cs`)
  was mislabelled. The reference regex treats such a `#` as part of the path,
  because `.+` is greedy and the line span is anchored to the end of the string.
  Walking `@` from the right reproduces that backtracking exactly.
- Second, `Path(...).name`: pathlib drops `.` components while parsing and keeps
  `..`, so `src/.` is named `src`. My version returned the whole path.
- **One divergence was the reference's bug, not mine.** `{code:   }` matched the
  heading-chip regex, stripped to the empty string and emitted a chip pointing at
  the anchor `code:`. Requiring one non-space character (`[^}\s][^}]*`) drops it
  instead, which is what the Swift already did. Fixed in `project_packet.py`; the
  golden is byte-identical after the change, so no real content relied on it.
- Two implementations of one contract will drift; the only question is whether a
  build says so or a reader discovers it. Transcribing the Swift back into Python
  and fuzzing it against the reference is the cheapest way found so far to get the
  answer before a Mac is in the room — it has now caught four real defects across
  two sessions, none of which a reading review found.
Limits hit:
- none.
Next:
1. On the Mac: `swift build`, then
   `./.build/debug/WalkthroughStudio --selftest-onboarding /tmp/fixture-repo /tmp/onboarding-out`
   — ten probes now, `markdownLiteProbe` and `projectorParityProbe` last. Then the
   original `--selftest`.
2. M4: the player shell. It now has real deliverables to show.
3. M5: narration, scene renderer, transcript and code-ref map.

### S4: 2026-09-21 — M8 Swift port begins, and an ordering error in the plan
Milestone(s): M8
Found first, before writing anything:
- **The milestone order was wrong.** The app can validate and import a packet but
  cannot produce a single deliverable from it: the projectors existed only in
  Python. M4 (the player) would have had nothing to show. M8's Swift port blocks
  M4, not the other way round, so M8 is being built first.
- **A semantic divergence the parity fixture would have hidden.** Swift's
  `usableFacts` filters to verified plus unknown, matching PACKET.md section 4;
  the Python projector used "not refuted", which also admits `proposed` facts.
  The fixture has no proposed facts, so a parity test would have passed by luck
  and diverged on any packet whose producer skipped verification. The spec is
  right, so the Python was fixed, and it now warns when proposed facts are held
  back rather than dropping research silently. The golden projection is
  byte-identical after the change, which is the evidence that the fixture did not
  exercise this path.
Built:
- `Sources/WalkthroughStudio/OnboardingResources/fixtures/fixture-repo.golden/`:
  the Python projection checked in as the oracle for the Swift port (34 files;
  derived HTML and copied source files excluded, one HTML sample kept to cover the
  markdown converter).
- `Onboarding/Projectors/ProjectionSupport.swift`: slugs, Mermaid ids and labels,
  word-safe clipping, deterministic JSON. Function for function against the Python.
- `Onboarding/Projectors/DiagramProjector.swift`: C4 context, C4 container, ERD,
  deployment and the per-trace sequence diagram, including every fix the rendering
  pass found (trace-derived edges by first appearance, no phantom subgraph nodes,
  no backtick labels, no arrow chain over unrelated deploy findings).
- `Onboarding/Projectors/ProjectionAPI.swift`: the few read-only accessors the
  projectors need, kept out of PacketModels so the packet types stay a faithful
  decoding of the contract and nothing else.
Verified:
- Balance and API checks only (no Swift toolchain here): braces and parens balance
  ignoring string literals, and every model member the projector touches exists
  with the name and type it assumes.
- The Python change leaves the golden projection byte-identical.
- not verified: none of the new Swift has been compiled or run.
Next:
1. RegisterProjector (14 registers plus trace documents), MarkdownLite (the
   markdown-to-HTML converter with citation chips), HubProjector (hub/index.json,
   index/anchors.json, the cited-source emitter).
2. `projectorParityProbe`: run the Swift projectors over the fixture packet and
   diff against fixture-repo.golden. A difference is a failure, not a surprise.
3. Then M4, the player shell, which the projectors unblock.

### S3: 2026-09-21 — First compile and first run on the Mac: all eight probes pass
Milestone(s): M1, M2, M3
Built:
- Nothing new. This session compiled and ran what S2 wrote blind.
Verified (on the human's MacBook, Xcode 26.2 / macOS 26.2 SDK):
- `swift build`: **Build complete (7.86s)** on the first attempt. 8,148 lines of
  Swift written by three agents with no compiler available, reviewed only by
  reading, compiled clean. The only warnings are pre-existing Swift 6
  sendability notices in `Services/FrameCompositor.swift`, a file this branch
  never touched.
- `--selftest-onboarding /tmp/fixture-repo /tmp/onboarding-out`: **SELFTEST PASS**,
  8 of 8 probes, first run:
  1. fixtureRepoProbe: HEAD fb63e78, 12 commits, Ada 8 / Grace 4, 15 files, tests PASS
  2. stillsWriterProbe: 10.00s stills, 4 frames colour-checked; narrated 9.00s, audio reaches 6.50s
  3. anchorRoundTripProbe: 19 anchors round-trip as string, URL and JSON; 14 malformed rejected
  4. manifestRoundTripProbe: unknown keys ignored, missing optionals nil
  5. packageStoreProbe: 13 dirs, atomic overwrite leaves no temp files, 2 sessions in both logs, keys redacted
  6. gitRunnerProbe: archive == ls-tree (15 files), blame 1-3 Ada, 1 worktree (the user's clone untouched), acquire(.local) clean
  7. packetValidateProbe: fixture packet 0 errors 0 warnings; the deliberately broken copy rejected with exactly 3 errors; import succeeded
  8. fixturePacketProbe: all eight acceptance findings present, including idempotency absent in order-creation
Broke / learned:
- The three riskiest assumptions the writers flagged all held. `endSession(atSourceTime:)`
  does extend the final sample: the stills movie measured 10.00s, not the 9.5s the
  writer feared. `xcrun --find git` and the GIT_ASKPASS helper work under the
  hardened runtime. `Bundle.module` finds the fixture packet, so the
  `.copy("OnboardingResources")` resource rule is correct.
- Worth watching, not yet a bug: the narrated output measured 9.00s against a
  10.00s stills asset. That is `assembleNarratedVideo`'s documented silent clamp
  (CLAUDE.md known limitations), not a new defect, and the probe's own assertion
  (audio reaching past the last segment start) held. Revisit when M5 builds real
  videos, where a clamp would desync captions.
- Reading review caught nothing false here, but it also cannot prove runtime
  behaviour. Writing probes that assert observed values, not just "it ran", is
  what made this session a five-minute confirmation instead of a debugging day.
Limits hit:
- none.
Next:
1. Run the existing `--selftest` to confirm no regression in the original pipeline
   (the timeline extraction and the terminate-guard change both touched it), and
   look at the PNGs and MP4s it dumps.
2. M4: the player shell, now unblocked because StillsVideoWriter and ToneNarrator
   can build a real fixture video on the Mac.
3. M5: narration, scene renderer, transcript and code-ref map.
