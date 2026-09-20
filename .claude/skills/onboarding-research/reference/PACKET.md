# The Research Packet

Version 1. The Research Packet is the contract between research and content in
the "Onboard to a Codebase" feature (ARCHITECTURE.md section 15). Research is
whoever knows the repository: a coding agent working inside it, the app's own
fleet, or a person. Content is the app: diagrams, registers, traces, narrated
code-walk videos with timestamped transcripts, the hub, the playback chat.
Nothing downstream of the packet knows which producer wrote it.

Normative files:
- JSON Schemas: `.claude/skills/onboarding-research/schema/*.json`
- Reference validator: `.claude/skills/onboarding-research/scripts/validate_packet.py`
  (wrapper: `scripts/validate-packet.py`)
- Survey tool that writes the deterministic half: `.../scripts/survey_repo.py`
  (wrapper: `scripts/survey-repo.py`)

The Swift `PacketValidator` in the app applies the same rules on import.

## 1. Principles

1. **Every claim carries evidence.** A fact without an evidence anchor is
   rejected. Anchors resolve against the repository at one pinned commit.
2. **The code wins.** A README claim is a `proposed` fact until code confirms it.
3. **Silence never reads as coverage.** `coverage.json` says what was not read
   and why. The validator rejects a packet where nothing reached `mapped`.
4. **Refuted facts stay in the packet** with the counter-evidence, marked
   `refuted`. Content never uses them; the review UI shows them.
5. **Deterministic where possible.** Inventory, history and dependency
   skeletons come from git and are byte-identical across runs on the same
   commit. Only judgement (facts, ranking, traces, decisions) comes from a model.

## 2. Layout

```
<name>.packet/
  packet.json            manifest: producer, repo {headSHA ...}, scope, summary, counts
  inventory.json         tree summary, languages, entry points, manifests, CI, infra, docs
  history.json           hotspots, ownership and bus factor per directory, stale files,
                         parallel implementations, commit-message keywords, notable commits
  dependencies.json      one entry per declared dependency; license, eol, cves or "unknown"
  facts.jsonl            one Fact per line (section 4)
  paths.json             ranked critical paths with entry anchors and rationale; untraced list
  traces/<pathId>.json   ordered hops, the ten concerns, "what scares me" (section 5)
  decisions.json         retroactive architecture decision records (optional)
  glossary.json          domain terms with where each is defined (optional)
  coverage.json          per-directory level, files read, facts; paths; checks (section 6)
  commands/<unit>/<n>.txt   captured command output for cmd: anchors (optional)
  drafts/                optional proposals: docs/*.md, scripts/*.json, diagrams/*.mmd
```

Required: `packet.json`, `inventory.json`, `history.json`, `facts.jsonl`,
`paths.json`, `coverage.json`, and one `traces/<id>.json` per traced path.

## 3. Anchor grammar

One string form everywhere: JSON fields, markdown links, chat citations.

| Form | Meaning |
|---|---|
| `code:<path>@<sha7>#L<a>-L<b>` | lines a to b of a file at the pinned commit; `#L<a>` one line; no fragment = whole file; trailing `/` on the path = directory (no fragment allowed) |
| `commit:<sha>` | a commit |
| `cmd:<unit>/<n>` | captured command output at `commands/<unit>/<n>.txt` |
| `fact:<id>` | a fact in `facts.jsonl` |
| `trace:<pathId>#hop<n>` | a hop in a trace |
| `issue:<n>` | a GitHub issue or pull request number |
| `url:<https url>` | an external page (advisories, registries) |
| `video:<id>#t=<s>`, `video:<id>#c=<chapter>`, `doc:<id>#<slug>`, `diagram:<id>#<node>` | content anchors; valid inside `drafts/` only, because the app creates those targets |

Parsing rule for `code:`: the path is everything before the **last** `@` that
is followed by 7 to 40 hex characters; the fragment is what follows the first
`#` after that. Paths may therefore contain `@` and `#`. `sha7` must be a
prefix of `packet.json.repo.headSHA`. Packets must pin every code anchor.

Citation syntax inside prose (drafts, and later the app's documents and chat):
`[[<anchor>]]` or `[[<anchor>|<label>]]`.

## 4. Facts

```json
{"id": "F-map-src-repo-003", "kind": "risk", "subject": "src/repo/orders_repo.py",
 "claim": "Order inserts are retried without an idempotency key, so a timeout after commit double-inserts.",
 "attributes": {"severity": "high"},
 "evidence": [{"anchor": "code:src/repo/orders_repo.py@fb63e78#L12-L20",
               "excerpt": "for attempt in range(2): ...", "note": "retry loop around _insert_once"}],
 "confidence": 0.9, "producedBy": "map-src", "status": "verified",
 "verdicts": [{"verifier": "verify-01", "verdict": "confirmed", "reason": "loop retries after OperationalError with no key",
               "evidence": ["code:src/repo/orders_repo.py@fb63e78#L12-L20"]}]}
```

Rules:
- `id` unique in the packet. Producers derive ids from the unit and a counter
  or tool-call id so a replayed unit cannot duplicate a fact.
- `kind` is one of: component, interface, endpoint, dependency, dataEntity,
  dataField, flowHop, decision, risk, owner, hotspot, testCoverage, migration,
  config, integration, deployStep, incidentPattern, term, landmine, metric,
  buildResult, security, observability.
- `claim` is one sentence. Put structured detail in `attributes`.
- `evidence` has at least one anchor. The `excerpt` (up to about 40 lines)
  is the text the producer actually read; the validator does not check it
  against the file, but reviewers and the playback agent show it.
- `status`: `proposed` (no verdicts yet), `verified` (a confirming verdict),
  `refuted` (a refuting verdict that cites counter-evidence), `unknown`
  (verifiers disagreed or could not tell). Content uses verified and unknown
  facts (unknown with hedged wording) and never refuted ones.
- `dataEntity` and `dataField` facts carry `attributes.pii`, `attributes.rows`
  and `attributes.retention`. `pii` is a boolean or `"unknown"`, because the
  entity relationship diagram colours nodes by it; any nuance ("yes: email is
  annotated, address is not") goes in `attributes.piiNote`. `rows` and
  `retention` are a value or `"unknown"`.

## 5. Traces

One file per critical path. `hops` follow one concrete scenario from entry to
response in call order; each hop has a `code:` anchor and a one-sentence
summary. `concerns` has exactly these ten keys, each with `status`
(`present`, `absent`, `unknown`) and `evidence` anchors when present or absent:
`entry`, `authorization`, `validation`, `businessLogic`, `persistence`,
`sideEffects`, `failureHandling`, `idempotency`, `timeoutsRetries`, `logging`.
`scaresMe` is a non-empty list of plain sentences. An `absent` concern is a
finding, not a gap in the research.

## 6. Coverage

Levels per top-level directory, in order: `unread` (with a reason),
`inventoried` (listed only), `mapped` (facts cite it), `verified` (its facts
have verdicts), `traced` (a critical path passes through it). `filesRead` over
`files` is reported honestly; the app renders this as a coverage map. `paths`
lists candidates, traced count and every untraced candidate with a reason.
`checks` records what was run or skipped: build, tests, lint, typecheck,
secretScan, dependencyAudit, issues.

## 7. Validation

`validate_packet.py <packet> --repo <checkout>` applies, in order: schema
conformance of every file; anchor grammar; anchor resolution (file and line
range exist at `headSHA`; commits exist; `cmd:` files exist; `fact:` and
`trace:` targets exist); evidence rules; trace rules (hops numbered from 1,
ten concerns present, `present`/`absent` carry evidence, every ranked path has
a trace); coverage consistency (every inventory directory listed, levels
consistent with facts and filesRead); completeness gates (no facts, placeholder
summary, nothing mapped are errors); manifest counts against computed counts
(warnings). Exit code 0 only with zero errors. `--json` writes the report the
app shows on import.

## 8. Producers

A producer must: pin `headSHA`; run the survey tool (or reproduce its output);
write facts with evidence for every directory it maps; verify facts (two
independent verifiers when it can); rank critical paths from evidence; trace
each ranked path; fill `coverage.json` honestly; write `packet.json.summary`
and `counts`; run the validator and fix every error before handing off.

Known producers: `claude-code-skill` (`.claude/skills/onboarding-research/`),
`walkthrough-studio-fleet` (the app, ARCHITECTURE.md M11).

## 9. Versioning

`version` is 1 in every file. Additive changes (new optional fields) keep the
version. A breaking change bumps every file's version and the validator
accepts both for one release. The app records the packet version it imported.
