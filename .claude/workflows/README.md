# Onboarding build workflows

Workflow tool scripts used to build the "Onboard to a Codebase" feature, kept
here so a later session can re-run or resume them (the Workflow tool replays
completed agents from a run's journal with `resumeFromRunId`). Each script's
`meta` block says what it does. Run ids and journal locations are recorded in
docs/onboarding/BUILD-LOG.md under the session that launched them.

- onboarding-feature-plan.js: subsystem maps, three architecture proposals, judges, synthesis, critic (S1).
- onboarding-swift-m1-m2.js: three Swift writers, two read-through reviewers, one fixer (S2).
- onboarding-fixture-packet.js: mappers, lenses, paired verifiers, ranker, tracers, decisions on the fixture repo (S2). Takes the survey JSON as `args`.
