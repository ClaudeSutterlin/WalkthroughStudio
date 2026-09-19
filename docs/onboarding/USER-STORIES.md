# Onboard to a Codebase: user stories

Feature: a new top-level mode in Walkthrough Studio. The user points the app at a
GitHub repository. A fleet of AI research agents reads the repository and produces
the full acquisition-onboarding package (diagrams, registers, critical-path traces,
a chaptered video series, a hub) with no remote humans involved. Documents, videos
and code are cross-linked, and a chat agent answers questions while a video plays
with full knowledge of what is on screen at that moment.

Personas:
- **Onboarding engineer** (primary): the senior architect who must understand an
  unfamiliar codebase fast and cannot afford to miss a critical-path or
  architecture problem.
- **Package author**: the same person, reviewing and correcting what the fleet
  produced before sharing it with a team.
- **Builder**: the AI agent (or human) implementing this feature across many
  sessions, who needs the work to be resumable and testable headlessly.

Priority: P0 = the feature is not usable without it. P1 = first release.
P2 = later. Each story has acceptance criteria that a headless selftest probe or a
manual check can verify. The story-to-milestone map at the end of this file
says which ARCHITECTURE.md milestone delivers each story.

Story IDs are stable. Do not renumber. Add new stories at the end of an epic.

---

## Epic 1: Point at a repository

| ID | Priority | Story |
|---|---|---|
| ON-1.1 | P0 | As an onboarding engineer, I want a menu item "Onboard to a Codebase..." that asks for a GitHub URL or a local folder, so that starting is one action. |
| ON-1.2 | P0 | As an onboarding engineer, I want the app to clone the repository (or use my local clone) at a pinned commit, so that every reference in the package points at exactly one SHA. |
| ON-1.3 | P1 | As an onboarding engineer, I want private repositories to work with a GitHub token stored in the Keychain, so that I never paste secrets into a file. |
| ON-1.4 | P0 | As an onboarding engineer, I want a progress view that shows which research agents are running, what they are reading, and what has been produced so far, so that a long run is not a black box. |
| ON-1.5 | P0 | As an onboarding engineer, I want to cancel a run and later resume it from the last checkpoint, so that a crash, a quit, or an API limit never loses work. |
| ON-1.6 | P1 | As an onboarding engineer, I want a cost and time estimate before the run starts and a running total during it, so that I can bound spend. |
| ON-1.7 | P1 | As an onboarding engineer, I want the run to be complete by default, with a preview scope available for a fast first look, and a live progress and coverage tracker instead of a depth cap, so that I see how deep the research went rather than deciding in advance. |
| ON-1.8 | P1 | As an onboarding engineer, I want to open an existing package from a recents list or a folder picker without starting a run, including one produced on another Mac, so that packages are portable. |
| ON-1.9 | P1 | As an onboarding engineer, I want to pause a running fleet (distinct from cancel), open the package so far, and see a clear paused state when the API is unreachable, so that a long run is under my control. |
| ON-1.10 | P0 | As an onboarding engineer, I want the pre-run sheet to let me choose the output folder, override the pinned commit, attach a briefing, and opt in to build and test execution with a plain warning, so that a run is configured in one place. |

Acceptance criteria:
- ON-1.1: menu item exists under File; a sheet collects the URL or folder; validation rejects non-git targets with a readable message.
- ON-1.2: the package manifest records the remote URL and the commit SHA; every code anchor in the package resolves against that SHA.
- ON-1.3: token is read lazily, never in a view initializer; clone of a private repo succeeds with the token and fails with a clear message without it.
- ON-1.4: progress view lists agents by role, current activity, and produced artifact count; updates at least every 2 seconds.
- ON-1.5: killing the process mid-run and relaunching offers "Resume"; resumed run does not re-execute completed research units; selftest probe proves it.
- ON-1.6: estimate is shown from repository size before start; actual tokens and dollars are tallied in the manifest at the end.
- ON-1.7: `complete` is the default scope; the tracker shows per-directory coverage levels (unread, inventoried, mapped, verified, traced), files read over files present, candidate versus traced paths with reasons, and deliverables produced versus planned; the scope and final coverage are recorded in the package.
- ON-1.8: opening validates the package (repo folder present, head SHA matches, referenced files exist) and reports each failure by name; recents are stored in settings.
- ON-1.9: pause cancels the in-flight request, writes the checkpoint, and leaves the window usable; the circuit breaker shows "Paused: API unreachable" with a Resume button; each notice has an inline Retry.
- ON-1.10: the sheet stores folder, SHA, briefing path and the opt-in flag in the manifest; the estimate updates when depth changes.

## Epic 2: The research fleet

| ID | Priority | Story |
|---|---|---|
| ON-2.1 | P0 | As an onboarding engineer, I want every fact the fleet states to carry evidence (file path, line range, commit SHA, or command output), so that I can verify any claim in one click. |
| ON-2.2 | P1 | As an onboarding engineer, I want the fleet to run the repository's own build and tests when I opt in for a run, so that the "dev environment" and "test truth" deliverables report what actually happened, not what the README says. |
| ON-2.3 | P0 | As an onboarding engineer, I want the fleet to mine git history (churn hotspots, author concentration, untouched files, parallel implementations), so that bus-factor and half-migration findings are grounded in data. |
| ON-2.4 | P0 | As an onboarding engineer, I want the fleet to identify the critical paths from evidence (entry points, money, auth, data, incident-prone areas) and rank them, so that depth goes where risk is. |
| ON-2.5 | P0 | As an onboarding engineer, I want independent verifier agents to attempt to refute each finding before it appears in a deliverable, so that confident nonsense is filtered out. |
| ON-2.6 | P1 | As an onboarding engineer, I want the fleet to state what it could not determine (unread areas, tests it could not run, unknown owners), so that silence never reads as coverage. |
| ON-2.7 | P0 | As a builder, I want every research unit to write its result to disk as a typed artifact before the next unit starts, so that a dead session resumes from the artifact store. |
| ON-2.8 | P1 | As an onboarding engineer, I want the fleet to work through an Anthropic-compatible gateway and a configurable model, so that it runs where my company's keys live. |
| ON-2.9 | P2 | As an onboarding engineer, I want to add a briefing (what the acquiring company intends: integrate, keep standalone, migrate), so that the assessment is framed for my decision. |

Acceptance criteria:
- ON-2.1: every `Fact` record has at least one `Evidence` record; deliverable renderers refuse facts without evidence; a probe counts zero orphan facts on the fixture repo.
- ON-2.2: execution is off by default and enabled per run by a checkbox with a plain warning (the app is not sandboxed); when on, commands detected from manifests and CI run in a temporary copy with a timeout and no privileges, and their exit status and log tail are stored; when off or nothing is detected, an explicit "could not run" record with the reason is produced.
- ON-2.3: the git-mining unit outputs hotspot, ownership and staleness tables for the fixture repo that match a scripted computation.
- ON-2.4: the critical-path list names the entry point of each path with evidence and a rank rationale; the fixture repo's known paths are all found.
- ON-2.5: each finding stores verifier verdicts with counter-evidence; at smoke and quick depth one refuting verdict rejects a fact, at standard depth and above two independent verifiers must both refute, and a split verdict marks the fact unknown and lists it as disputed; rejected facts live in a "rejected" list, never in deliverables.
- ON-2.6: the coverage report lists unread directories and skipped checks with reasons.
- ON-2.7: the artifact store is append-only JSON files keyed by unit id; a probe deletes the process mid-run and confirms resume skips completed ids.
- ON-2.8: existing base URL and model override settings are honored by the fleet.
- ON-2.9: briefing text is injected into synthesis prompts and quoted in the assessment.

## Epic 3: Diagrams

| ID | Priority | Story |
|---|---|---|
| ON-3.1 | P0 | As an onboarding engineer, I want C4 context and container diagrams whose boxes link to repository paths and whose arrows name the protocol and contract file, so that the map is verifiable. |
| ON-3.2 | P1 | As an onboarding engineer, I want component diagrams for the critical containers only, so that detail goes where it matters. |
| ON-3.3 | P0 | As an onboarding engineer, I want an entity relationship diagram with volume, retention and PII flags, so that data risk is visible at a glance. |
| ON-3.4 | P1 | As an onboarding engineer, I want a deployment topology diagram derived from infrastructure and CI files, so that I know how code reaches production. |
| ON-3.5 | P0 | As an onboarding engineer, I want to click any diagram box to open the file or folder it represents, so that diagrams are doors into the code. |
| ON-3.6 | P0 | As a package author, I want diagrams stored as Mermaid source alongside the rendered image, so that I can correct them. |

Acceptance criteria:
- ON-3.1 and ON-3.6: `diagrams/*.mmd` exist with a sidecar `*.links.json` mapping node ids to anchors; the renderer produces SVG or PNG; a probe checks every node id has an anchor that resolves.
- ON-3.3: ERD node metadata includes `rows`, `retention`, `pii` fields, each with evidence or "unknown".
- ON-3.5: clicking a node in the hub navigates to the code view at the anchor.

## Epic 4: Written registers

| ID | Priority | Story |
|---|---|---|
| ON-4.1 | P0 | As an onboarding engineer, I want an architecture narrative that matches the diagrams and links into them, so that prose and picture never disagree. |
| ON-4.2 | P1 | As an onboarding engineer, I want retroactive architecture decision records for the top decisions the code implies, so that I understand why, not only what. |
| ON-4.3 | P0 | As an onboarding engineer, I want an ownership and bus-factor map per directory, so that I know where knowledge is concentrated. |
| ON-4.4 | P0 | As an onboarding engineer, I want a dependency register with version, license, end-of-life and known-vulnerability status, so that legal and security risk is listed. |
| ON-4.5 | P0 | As an onboarding engineer, I want a ranked technical-debt register with blast radius and evidence, so that I can decide what to fix first. |
| ON-4.6 | P1 | As an onboarding engineer, I want a bug and incident pattern register mined from issues, commit messages and TODO/FIXME markers, so that I know where it breaks. |
| ON-4.7 | P0 | As an onboarding engineer, I want a test-truth report showing coverage on the critical paths specifically and listing skipped tests, so that green CI cannot mislead me. |
| ON-4.8 | P1 | As an onboarding engineer, I want a data inventory and a security posture summary, so that PII and auth risks are enumerated. |
| ON-4.9 | P0 | As an onboarding engineer, I want a landmines document in the style of this repository's CLAUDE.md (verify loop first, numbered gotchas), so that the next person does not pay the same debugging bill. |
| ON-4.10 | P1 | As an onboarding engineer, I want a glossary of domain terms with the file where each concept is defined, so that vocabulary is learnable. |
| ON-4.11 | P0 | As an onboarding engineer, I want every register section to link to the video chapter that covers it and to the code it cites, so that reading, watching and code are one surface. |

Acceptance criteria:
- Each register is a markdown file under `docs/` in the package with front matter naming its evidence artifacts; a probe renders each without missing links.
- ON-4.7: coverage is reported per critical path, or an explicit "could not measure" with the reason.
- ON-4.11: every `##` section carries a `video:` and at least one `code:` anchor when applicable; the hub resolves them.

## Epic 5: Critical path traces

| ID | Priority | Story |
|---|---|---|
| ON-5.1 | P0 | As an onboarding engineer, I want a sequence diagram per critical path following one real request through the actual code, so that I see the mechanism, not the org chart. |
| ON-5.2 | P0 | As an onboarding engineer, I want each trace to cover entry, authorization, validation, business logic, persistence, side effects, failure handling, idempotency, timeouts and retries, and logging, with a "not found" verdict where a concern is absent, so that gaps are explicit. |
| ON-5.3 | P0 | As an onboarding engineer, I want each trace to end with "what scares me about this path", so that risk is stated in plain words. |
| ON-5.4 | P0 | As an onboarding engineer, I want a narrated code-walk video per trace that highlights each step in the real source, so that I can follow the path at 1.5x. |

Acceptance criteria:
- ON-5.1: `traces/<path-id>/trace.json` lists ordered hops, each with an anchor and the call site; `trace.mmd` is generated from it.
- ON-5.2: each of the ten concerns has a status `present`, `absent`, or `unknown` with evidence.
- ON-5.4: the video's chapter list equals the hop list; each chapter's code-ref map names the anchor on screen.

## Epic 6: Video series

| ID | Priority | Story |
|---|---|---|
| ON-6.1 | P0 | As an onboarding engineer, I want a video series (architecture overview, domain model, code tour, dev environment to green tests, deploy and rollback, data layer, observability, security, integrations, half-finished migrations) generated from the research artifacts, so that I can learn by watching. |
| ON-6.2 | P0 | As an onboarding engineer, I want every video to be 15 minutes or shorter, chaptered, and to open with a 30-second summary card, so that no video wastes my time. |
| ON-6.3 | P0 | As an onboarding engineer, I want the screen to show real code, real diagrams and real command output rather than slides, so that what I see is what exists. |
| ON-6.4 | P0 | As an onboarding engineer, I want narration synthesized in the configured voice with captions, so that I can watch muted or listen away from the screen. |
| ON-6.5 | P1 | As an onboarding engineer, I want a "confessional" video per subsystem that states what is fragile and what only the code knows, so that candor is not lost by having no humans. |
| ON-6.6 | P1 | As a package author, I want to edit a video's script and regenerate only that video, so that corrections are cheap. |
| ON-6.7 | P1 | As an onboarding engineer, I want the videos to render offline as standard MP4 with SRT, so that they play outside the app. |

Acceptance criteria:
- ON-6.1: `videos/<id>/script.json` (scenes with narration, on-screen content spec, anchors), `video.mp4`, `captions.srt`, `transcript.json`, `coderefs.json` exist per video.
- ON-6.2: scene durations sum to 900 seconds or less; the first scene is a summary card; chapters are written to the transcript.
- ON-6.3: scene types are limited to code listing with highlight, diagram, terminal output, table, and summary card; a probe pixel-checks one of each on the fixture.
- ON-6.6: regenerating one video does not touch other videos' files; a probe checks timestamps.

## Epic 7: Timestamped transcripts and code-ref maps

| ID | Priority | Story |
|---|---|---|
| ON-7.1 | P0 | As an onboarding engineer, I want a transcript with a start and end time for every sentence, so that the agent and the captions know exactly what has been said at time t. |
| ON-7.2 | P0 | As an onboarding engineer, I want a per-timestamp map of what is on screen (scene type, file anchor, highlighted line range, diagram node ids), so that "what is that?" is answerable. |
| ON-7.3 | P1 | As an onboarding engineer, I want word-level timing when the TTS provider supplies it, with sentence-level fallback, so that captions and highlights stay in sync. |

Acceptance criteria:
- ON-7.1: `transcript.json` segments carry `start`, `end`, `text`, `sceneId`; segments are contiguous and sorted; a probe checks the sum against the audio duration within 250 ms.
- ON-7.2: `coderefs.json` intervals cover the whole timeline; every anchor resolves at the pinned SHA.
- ON-7.3: transcript records `timingSource` as `provider-words` or `sentence-estimate`.

## Epic 8: The interactive hub

| ID | Priority | Story |
|---|---|---|
| ON-8.1 | P0 | As an onboarding engineer, I want a hub that lists every deliverable in a recommended order with minutes per item and read or watched status, so that I always know what is next. |
| ON-8.2 | P0 | As an onboarding engineer, I want to click from a doc section to the video chapter that covers it, from a video chapter to the doc and the code, and from code to every video and doc that mentions it, so that the three are one surface. |
| ON-8.3 | P0 | As an onboarding engineer, I want an in-app code view that opens at an anchor, highlights the range, and shows the file at the pinned SHA, so that links never dangle. |
| ON-8.4 | P1 | As an onboarding engineer, I want the hub to open the anchor in my editor of choice, so that I can start working from a video. |
| ON-8.5 | P1 | As an onboarding engineer, I want a search over transcripts, docs and code refs, so that I can find where a topic is covered. |
| ON-8.6 | P1 | As a package author, I want the hub exported as a static site (HTML, MP4, SRT, JSON), so that I can share it with a team without the app. |
| ON-8.7 | P0 | As an onboarding engineer, I want the video to keep playing in a docked mini-player when I click into code or a doc, and "Back to video" to return me to the same moment, so that exploring never loses my place. |
| ON-8.8 | P1 | As an onboarding engineer, I want keyboard transport and shortcuts (play and pause, chapter skip, captions, focus chat, bookmark, search, back), so that I can drive the player without the mouse. |
| ON-8.9 | P1 | As a package author, I want the export to let me choose a destination and tell me what is excluded (agent transcripts, chat, the clone) and that chat is unavailable in the exported site, so that I know what I am sharing. |

Acceptance criteria:
- ON-8.1: the hub reads `manifest.json` and shows status persisted per user.
- ON-8.2: a probe walks every link in the package and confirms each target exists.
- ON-8.3: code view loads file content from the pinned checkout, not the working tree.
- ON-8.6: the exported folder opens in a browser with working links and playback.
- ON-8.7: docking keeps the player on the same clock; the "Follow along" split mode opens the on-screen file at every shot change; a probe checks the stage restores the video at the same t.
- ON-8.8: J, K, L transport; [ and ] chapters; C captions; ? focuses chat; Cmd-B bookmark; Cmd-K search; Cmd-[ back; Escape leaves the docked view.
- ON-8.9: the export sheet lists excluded folders; the exported hub shows a note where chat would be.

## Epic 9: The playback chat agent

| ID | Priority | Story |
|---|---|---|
| ON-9.1 | P0 | As an onboarding engineer, I want to ask a question while a video plays and have the agent know exactly what has been narrated up to now and what is on screen, so that I can ask "what does that function do?" and be understood. |
| ON-9.2 | P0 | As an onboarding engineer, I want answers to cite code anchors and package sections, and for those citations to be clickable, so that I can verify instead of trust. |
| ON-9.3 | P0 | As an onboarding engineer, I want the agent to read the actual source at the pinned SHA when my question needs it, so that answers are grounded in the code and not only the transcript. |
| ON-9.4 | P1 | As an onboarding engineer, I want the video to pause when I start typing and resume when I choose, so that I do not lose my place. |
| ON-9.5 | P1 | As an onboarding engineer, I want to bookmark a moment with a note, so that my questions become a review list. |
| ON-9.6 | P1 | As an onboarding engineer, I want the agent to tell me when a claim in the video is contradicted by code it just read, so that mistakes in the package surface during viewing. |
| ON-9.7 | P2 | As an onboarding engineer, I want the agent to jump the video to the chapter that answers my question, so that navigation is conversational. |
| ON-9.8 | P1 | As an onboarding engineer, I want chat conversations to persist per video, resume when I reopen the package, roll into a new session with a summary after many questions, and report a spend cap or refusal in the pane rather than failing silently, so that the companion is dependable. |
| ON-9.9 | P1 | As a package author, I want to review, clear, and turn flags and bookmarks into review items from the companion tabs, so that what I noticed while watching becomes work. |

Acceptance criteria:
- ON-9.1: the request sent at time t contains transcript segments with `end <= t`, the coderefs interval containing t with the highlighted source inlined, the shot's facts, the next two sentences marked as not yet narrated, the video's summary and chapter list, and a package digest (deliverable list, head SHA, module map); a probe asserts the assembled context for a fixture video at three times.
- ON-9.2: replies use a citation syntax the hub renders as links; a probe checks parsing.
- ON-9.3: the agent has read-only tools: read file at SHA, list directory, search package; tool calls are logged.
- ON-9.6: a contradiction is recorded to `review/flags.json` for the package author.
- ON-9.8: conversations are append-only files per video; a new session starts after 30 questions with the old one summarized; tool calls show as "reading ..." rows; cap and refusal messages are visible.
- ON-9.9: flags and bookmarks tabs list items with jump links; an item can be cleared or promoted to `review/status.json` with a note.

## Epic 10: Review and corrections

| ID | Priority | Story |
|---|---|---|
| ON-10.1 | P0 | As a package author, I want a review checklist per deliverable (accept, fix, regenerate) with the evidence beside it, so that I can sign off deliberately. |
| ON-10.2 | P1 | As a package author, I want to correct a fact and have every deliverable that depends on it marked stale, so that corrections propagate. |
| ON-10.3 | P1 | As a package author, I want the rejected-findings list visible and a way to restore a fact with a note, so that I can rescue a false negative. |
| ON-10.4 | P1 | As a package author, I want to regenerate any single deliverable (doc, diagram, trace, video) and see its dependents marked stale, so that corrections stay cheap and honest. |

Acceptance criteria:
- ON-10.1: review state is stored in `review/status.json`; the hub shows it.
- ON-10.2: dependency edges from facts to deliverables exist in the manifest; staleness is computed from them.
- ON-10.3: restore appends a reviewer verdict to the fact file (never rewrites) and re-pends dependents.
- ON-10.4: regenerating one deliverable touches only its files; dependents show a stale badge until regenerated.

## Epic 11: Builder stories (resumability, verification, build log)

| ID | Priority | Story |
|---|---|---|
| ON-11.1 | P0 | As a builder, I want a headless selftest for this feature that runs against a tiny synthetic fixture repository with no network, so that every milestone is verifiable in CI. |
| ON-11.2 | P0 | As a builder, I want a build log in the repository that records what was built, what was verified, what broke, and what is next, so that a fresh session can continue without re-deriving state. |
| ON-11.3 | P0 | As a builder, I want the fleet, renderers and player to be separable milestones, each with a probe, so that sessions end at stable points. |
| ON-11.4 | P0 | As a builder, I want LLM and TTS calls behind protocols with recorded fixtures, so that the selftest exercises the pipeline offline. |
| ON-11.5 | P1 | As a builder, I want a "smoke" depth that produces one diagram, one register, one trace, and one 60-second video, so that an end-to-end run fits in a session. |
| ON-11.6 | P1 | As a builder, I want a record mode that captures real LLM and TTS responses as fixtures during a live run, and a warning when a prompt has drifted from its recording, so that fixtures can be refreshed deliberately. |

Acceptance criteria:
- ON-11.1: `scripts/make-fixture-repo.sh` creates a git repository with known paths, an ERD-worthy schema, a fake CI file, and two authors; `--selftest-onboarding <fixture> <outDir>` ends with `SELFTEST PASS`.
- ON-11.2: `docs/onboarding/BUILD-LOG.md` has an entry per session with the template in that file.
- ON-11.6: the record toggle writes recordings in the fixture layout; a request-hash mismatch logs a warning and the build log notes when fixtures were re-recorded.
- ON-11.4: the `LLMTransport` seam (recorded request and response replay keyed by prompt name and turn) and the `Narrating` protocol (tone narrator with synthetic alignment) have fixture-backed implementations; the selftest never opens a network connection.

## Epic 12: Settings and cost

| ID | Priority | Story |
|---|---|---|
| ON-12.1 | P0 | As an onboarding engineer, I want the feature to use the existing Anthropic, ElevenLabs and gateway settings, so that setup is not repeated. |
| ON-12.2 | P1 | As an onboarding engineer, I want an optional per-run dollar cap (off by default) that stops the fleet gracefully with a partial package and a coverage report, so that I can bound spend when I choose to. |
| ON-12.3 | P2 | As an onboarding engineer, I want to pick the narration voice per package, so that the series sounds consistent. |
| ON-12.4 | P0 | As an onboarding engineer, I want an Onboarding section in Settings (planner and worker models, effort, parallelism, spend cap, default package folder, editor command, GitHub token, record-fixtures toggle), so that the feature is configurable without editing files. |
| ON-12.5 | P1 | As an onboarding engineer, I want tokens, dollars and cache-hit rate by model during and after a run, and the coverage report opened from the hub when a run ends partial, so that cost and blind spots are visible where I look. |

Acceptance criteria:
- ON-12.2: hitting the cap ends the run with `manifest.status = "partial"` and a list of unproduced deliverables.
- ON-12.4: the GitHub token field loads lazily in `.task`; `claude-opus-5` is added to the model list.
- ON-12.5: the progress view shows per-model usage and cache-hit rate; the hub links the coverage report.

---

## Epic 13: The Research Packet contract and producers

| ID | Priority | Story |
|---|---|---|
| ON-13.1 | P0 | As an onboarding engineer, I want a documented Research Packet format with JSON Schemas, so that any tool with good context on my project can produce the research and the app builds the content and viewer from it. |
| ON-13.2 | P0 | As an onboarding engineer, I want to import a Research Packet from a folder, have it validated (schema, anchors resolving at the pinned commit, orphan facts, missing traces), and see the report before anything is built, so that bad research is caught at the door. |
| ON-13.3 | P0 | As a Claude Code user, I want a skill in this repository that produces a valid Research Packet for the repository I am working in, so that my coding agent's project knowledge becomes the research. |
| ON-13.4 | P0 | As a producer, I want a command-line validator that runs anywhere without the app, so that I can check a packet before handing it over. |
| ON-13.5 | P1 | As an onboarding engineer, I want the hub to show which producer made the packet, when, with which model, and the coverage it reported, so that provenance is never in doubt. |
| ON-13.6 | P1 | As an onboarding engineer, I want to re-import an updated packet into an existing package and have only the affected deliverables go stale, so that research can iterate without a full rebuild. |
| ON-13.7 | P2 | As a producer, I want to include drafts (narratives, scripts, diagrams) in the packet that the app treats as proposals, so that a producer with strong opinions can shape the deliverables. |

Acceptance criteria:
- ON-13.1: `docs/onboarding/PACKET.md` and `docs/onboarding/packet-schema/*.json` exist and the fixture packet validates against them.
- ON-13.2: import refuses on errors and lists warnings; a packet with a dangling anchor, an orphan fact and a missing trace is rejected with exactly those three errors in a probe.
- ON-13.3: running the skill on the fixture repo produces a packet that validates with zero errors and contains the fixture's known findings (hotspot, bus factor, PII column, unapplied migration, idempotency gap, no rollback, old pinned dependency).
- ON-13.4: `scripts/validate-packet.py <packet> [<repo>]` exits 0 only with zero errors and prints statistics.
- ON-13.5: the hub's About card shows `packet.json.producer` and the coverage summary.
- ON-13.6: re-import diffs fact ids and content hashes and marks dependents stale through manifest edges.
- ON-13.7: drafts are validated like everything else and the composer records whether it kept or replaced each.

## Out of scope for the first release

- Multi-repository products (monorepo is in scope, several repos is not).
- Editing code from inside the hub.
- Team features: comments, shared review state, permissions.
- Languages the fleet cannot build: the fleet still reads and maps them, but the "dev environment" and "test truth" deliverables report "could not run".

---

## Story-to-milestone map

Milestones are defined in ARCHITECTURE.md section 11. A story listed under two
milestones is delivered across both (the first builds the mechanism, the second
populates it).

| Milestone | Stories delivered |
|---|---|
| M0 Planning docs | ON-11.2, ON-11.3 |
| M1 Fixture, selftest scaffold, stills writer | ON-11.1 |
| M2 Package format, anchors, store, git, Research Packet contract | ON-1.2, ON-1.3 (token storage), ON-2.7 (artifact store), ON-13.1, ON-13.2, ON-13.4 |
| M3 Claude Code producer skill and fixture packet | ON-13.3 |
| M4 Player shell on a fixture package | ON-1.1, ON-1.8, ON-1.10 (sheet), ON-3.5, ON-8.2, ON-8.3, ON-8.7, ON-9.5 (bookmarks) |
| M5 Narration, scene renderer, transcript, code-ref map | ON-6.2, ON-6.3, ON-6.4, ON-6.7, ON-7.1, ON-7.2, ON-7.3, ON-11.4 (narrator fixture), ON-12.3 |
| M6 LLM runtime | ON-2.8, ON-11.4 (transport fixture), ON-11.6, ON-12.1, ON-12.2 (meter) |
| M7 Playback chat agent | ON-9.1, ON-9.2, ON-9.3, ON-9.4, ON-9.6, ON-9.7, ON-9.8, ON-9.9 |
| M11 In-app research fleet (second producer) | ON-1.3 (private clone), ON-1.4, ON-1.5, ON-1.7, ON-1.9, ON-1.10 (opt-in), ON-4.6 (issues unit), ON-12.4, ON-12.5, ON-2.1 (emit_fact), ON-2.2, ON-2.3, ON-11.5 (smoke depth), ON-12.2 (cap ends run as partial) |
| M11 (continued) | ON-2.4, ON-2.5, ON-2.6, ON-2.9, ON-5.1, ON-5.2, ON-5.3 (trace facts) |
| M8 Projectors: Mermaid diagrams, registers, traces | ON-3.1, ON-3.2, ON-3.3, ON-3.4, ON-3.6, ON-4.1 to ON-4.11, ON-5.1 to ON-5.3 (projection) |
| M9 Video scripts and the series | ON-5.4, ON-6.1, ON-6.5, ON-6.6 |
| M10 Hub, cross-links, search, export, coverage tracker | ON-8.1, ON-8.4, ON-8.5, ON-8.6, ON-8.8, ON-8.9 |
| M12 Review, staleness, end-to-end smoke | ON-1.6, ON-13.5, ON-13.6, ON-13.7, ON-2.9 (briefing), ON-10.1, ON-10.2, ON-10.3, ON-10.4 |
