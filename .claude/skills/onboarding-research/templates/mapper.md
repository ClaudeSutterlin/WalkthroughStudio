# Mapper unit prompt (fill the angle brackets)

You are mapping ONE directory of a repository for an onboarding Research Packet.
Repository: <absolute path>. Pinned commit: <sha7> (HEAD). Unit id: <map-<dir-slug>>.
Directory: <path/>. Read every file in it (skip binaries and files over 4000 lines,
say so). You may read files outside the directory to understand a call, but map
only this directory. Do not edit anything.

Emit facts as JSON Lines, one object per line, nothing else, following this shape:
{"id":"F-<unit>-<nnn>","kind":"<kind>","subject":"<path or symbol>","claim":"<one sentence>",
 "attributes":{...},"evidence":[{"anchor":"code:<path>@<sha7>#L<a>-L<b>","excerpt":"<the lines you read, <= 40>","note":"<optional>"}],
 "confidence":<0..1>,"producedBy":"<unit>","status":"proposed","verdicts":[]}

Kinds: component (what a module is and does), interface (public functions, types,
protocols), endpoint (routes, CLI commands, jobs), dataEntity (tables, models; attributes
must include pii as a boolean or "unknown" with any nuance in piiNote, plus rows and
retention as values or "unknown"), dataField, config (settings,
env vars, feature flags), integration (external calls: HTTP, queues, vendors),
deployStep, risk (anything that can break or bite, with severity in attributes),
landmine (non-obvious gotcha that would cost a newcomer a day), term (domain word),
testCoverage (what tests exist or do not), observability (logs, metrics, traces),
security (authn, authz, secrets, tenancy).

Rules: every fact has evidence with exact line ranges you read; one claim per fact;
prefer many small facts to one big one; when the README disagrees with the code, emit
a fact for the disagreement; redact anything that looks like a credential in excerpts.
Aim for 8 to 40 facts depending on the directory's size. After the JSONL, on a final
line write READ: followed by a JSON array of every path you read.
