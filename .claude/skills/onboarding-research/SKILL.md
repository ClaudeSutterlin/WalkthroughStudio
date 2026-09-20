---
name: onboarding-research
description: Produce a Research Packet for the repository you are working in, so Walkthrough Studio can build an interactive onboarding package (diagrams, registers, critical-path traces, narrated code-walk videos, a hub, a playback chat agent) from it. Use when asked to "research this codebase for onboarding", "produce a research packet", "onboard someone to this repo", or to prepare acquisition due diligence on a codebase. The packet format is docs/onboarding/PACKET.md in the Walkthrough Studio repository.
---

# Onboarding research: produce a Research Packet

You are the producer. You know this repository better than any cold fleet will,
so the packet should read like a senior engineer's field notes, every claim
pinned to code. The consumer is Walkthrough Studio, which turns the packet into
content. Everything you write must pass `scripts/validate_packet.py` with zero
errors; that is the definition of done.

Rules that never bend:
1. Every fact has at least one `code:` (or `commit:`/`cmd:`) evidence anchor
   pinned to HEAD's sha7, with the line range you actually read.
2. The code wins over the README. Document the disagreement as a fact.
3. Refute your own facts. Run verifiers who must cite counter-evidence to
   refute. Keep refuted facts in the packet as `refuted`.
4. Say what you did not read. `coverage.json` is honest or the packet is wrong.
5. Never write secrets into the packet. Excerpts of config files must redact
   values that look like credentials.

## Step 0: pin and prepare

```sh
git status --porcelain            # warn the user if dirty: the packet describes HEAD only
git rev-parse HEAD                # this is packet.json.repo.headSHA; sha7 = first 7 chars
SKILL=<path to this skill folder>
PACKET=../<RepoName>.packet       # outside the repository unless the user says otherwise
python3 "$SKILL/scripts/survey_repo.py" --repo . --out "$PACKET" --producer claude-code-skill
```

Read `inventory.json` and `history.json`. They are your map: top-level
directories, entry point candidates, manifests, hotspots, bus factor per
directory, stale files, parallel implementations, notable commits. Note
`packet.json` is a skeleton with a placeholder summary and zeroed counts; you
finish it in step 7.

If the repository has a build or test command and running it is allowed in your
environment, run it now and capture the output to
`$PACKET/commands/buildtest/1.txt` (command, exit code, last 200 lines). Cite
it as `cmd:buildtest/1`. Record the check in `coverage.json.checks` either way.

## Step 1: plan the fan-out

Write `$PACKET/plan.md` (not part of the contract; delete it at the end or
leave it, the validator ignores unknown files) with:
- one **mapper** unit per top-level directory that is not generated, splitting
  directories above about 40 files into clusters;
- **lens** units: data (schemas, migrations, PII), dependencies (fill license,
  eol, cves with evidence or `unknown`), deploy (CI, infra, rollback), observability
  (logging, metrics, alerts), integrations (every external call), security
  (authn, authz, secrets, tenancy), testTruth (what the tests actually cover,
  skipped tests), migrations (half-finished work, dual paths, flags older than
  six months), landmines (non-obvious things that cost a day), glossary;
- **verify** units, one per 25 facts, two independent verifiers per batch;
- **rank** then one **trace** unit per ranked path;
- **decisions** (retroactive ADRs) and **coverage**.

Sub-agents: use the Agent tool with the templates in `templates/`. Give each
sub-agent the repository path, HEAD sha7, its unit id, its directory or lens,
and the output rules. Each returns JSONL text only. Append each result to
`$PACKET/facts.jsonl` yourself after a quick sanity pass (valid JSON per line,
ids prefixed with the unit id).

## Step 2: map

Run the mapper units (`templates/mapper.md`). A mapper reads every file in its
directory (or says which it skipped and why), and emits facts of kinds
component, interface, endpoint, dataEntity, dataField, config, integration,
deployStep, hotspot (from history), risk, landmine, term. Each mapper also
returns the list of paths it read; keep it for coverage.

## Step 3: lenses

Run the lens units (`templates/lens.md`) with the facts so far as context. Lenses
may read anything. The dependencies lens rewrites `dependencies.json` entries
in place (license, eol, cves, evidence) and may use web search when available,
citing `url:` anchors; otherwise leaves `unknown`.

## Step 4: verify

Batch facts by 25. For each batch run two verifiers (`templates/verifier.md`)
independently. Merge verdicts into each fact's `verdicts` array and set
`status`: both confirm or one confirms and one unknown → `verified`; both refute
→ `refuted`; split confirm/refute → `unknown`; anything else → `unknown`. A
refuting verdict without evidence anchors is discarded.

## Step 5: rank and trace

Run the ranker (`templates/ranker.md`) over entry points, verified facts and
history. It writes `paths.json`: every path the business would die without,
ranked, each with an entry anchor and a rationale, plus `untraced` candidates
with reasons. Then run one tracer per path (`templates/tracer.md`) writing
`traces/<pathId>.json`: one concrete scenario followed hop by hop through the
real code, the ten concerns each present/absent/unknown with evidence, and
"what scares me" in plain sentences. An `absent` concern is a finding.

## Step 6: decisions, glossary, summary

Run the decisions unit: the top decisions the code implies (framework, storage,
sync vs async, deploy model, testing approach), each with alternatives,
consequences, evidence, and `wouldRepeat` when you have an opinion; the packet
summary paragraph; and the top ten findings with anchors. Glossary terms come
from the glossary lens.

## Step 7: assemble, validate, hand off

Save every unit's output as JSON under a working folder with this layout, then
let the assembler merge them, apply the status rule, compute coverage and
counts, and run the validator:

```
$WORK/mappers/<unit>.json   {"unit","facts","readPaths","skipped"}
$WORK/lenses/<unit>.json    {"unit","facts","readPaths","dependencies"?,"glossary"?}
$WORK/verdicts/<id>.json    {"verifier","verdicts"}
$WORK/paths.json            ranker output
$WORK/traces/<pathId>.json  tracer outputs
$WORK/decisions.json        {"decisions","summary","topFindings"}
$WORK/checks.json           optional: what you ran or skipped (build, tests, ...)
```

```sh
python3 "$SKILL/scripts/assemble_packet.py" --packet "$PACKET" --units "$WORK" --repo . --model "<model id>"
```

The assembler writes facts.jsonl, paths.json, traces/, decisions.json,
glossary.json, dependencies.json, coverage.json and packet.json, then runs
`validate_packet.py` and exits with its status. Coverage levels are computed,
never hand-written: `traced` if a trace hop cites the directory, else
`verified` if it has verified facts, else `mapped` if it has facts, else
`inventoried` if something was read, else `unread` with a reason.

Fix every error and re-run until `PACKET OK`. Read the warnings; fix the ones
that are cheap. Report to the user: the packet path, the summary, the top ten
findings (risks and landmines with their anchors), the coverage by level, and
the warnings you left.

## Acceptance test for this skill

`scripts/make-fixture-repo.sh /tmp/fixture-repo` in the Walkthrough Studio
repository builds a deterministic repository (head `fb63e787…`). A packet
produced from it must validate with zero errors and contain facts for: the
`src/repo/orders_repo.py` hotspot (6 commits, one author), bus factor 1 in
every directory, `users.email` as PII, migration 002 written but not applied,
the idempotency gap in order creation (retry without key), no rollback in
`deploy/deploy.sh`, and the old pinned `requests==2.19.0`. Generated directories
must be flagged `generated` with a reason in `inventory.json`; their coverage
level simply reports what was read (reading `vendor/generated/client_pb2.py`
is fine and yields a real finding: generated code nothing imports, with no
`.proto` source or protoc step). The trace for order creation must mark `idempotency` absent with the
handler and repo anchors as evidence.
