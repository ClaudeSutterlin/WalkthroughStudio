# Lens unit prompt (fill the angle brackets)

You are researching ONE cross-cutting concern for an onboarding Research Packet.
Repository: <absolute path>. Pinned commit: <sha7>. Unit id: <lens-<name>>.
Lens: <data | dependencies | deploy | observability | integrations | security | testTruth | migrations | landmines | glossary>.
Context: the facts found so far are in <path to facts.jsonl>; the survey is in
<inventory.json> and <history.json>. Read whatever you need. Do not edit anything.

What each lens must answer:
- data: every store and table, PII columns, volumes if inferable, retention, backups,
  migrations applied versus written, ORM versus raw SQL.
- dependencies: for each entry in dependencies.json, license (SPDX), end-of-life status,
  known CVEs with ids and severity; cite url: anchors when you used the web, else "unknown".
  Return the rewritten dependencies array after the facts, on a line starting DEPENDENCIES:.
- deploy: how code reaches production, gates, rollback, migrations, secrets, environments.
- observability: what is logged, metered, traced; alerts; runbooks; what is silent.
- integrations: every external call, its failure mode, timeouts, retries, cost, lock-in.
- security: authn, authz model, tenant isolation, secrets handling, input validation at
  boundaries, audit trail, dangerous defaults.
- testTruth: what the tests cover, especially on money, auth and data paths; skipped or
  quarantined tests; flakiness signals; whether CI runs them.
- migrations: half-finished refactors, dual code paths, feature flags older than six
  months, TODOs referencing unfinished work, v1 and v2 coexisting.
- landmines: things that cost a newcomer a day: environment quirks, ordering constraints,
  implicit contracts, hidden manual steps, scripts someone runs by hand.
- glossary: domain terms and where each concept is defined; return GLOSSARY: with a JSON
  array of {term, definition, definedAt} after the facts.

Emit facts as JSON Lines exactly as the mapper prompt specifies, with kind chosen from the
list there, ids "F-<unit>-<nnn>", status "proposed", verdicts []. End with READ: and the
JSON array of paths you read.
