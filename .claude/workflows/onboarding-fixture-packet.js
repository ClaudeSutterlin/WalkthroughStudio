export const meta = {
  name: 'onboarding-fixture-packet',
  description: 'Run the onboarding-research skill units (mappers, lenses, paired verifiers, ranker, tracers, decisions) against the deterministic fixture repo to produce the Research Packet facts, traces, paths, decisions and glossary',
  phases: [
    { title: 'Map', detail: 'one mapper per directory group' },
    { title: 'Lenses', detail: 'five merged lens units' },
    { title: 'Verify', detail: 'two independent verifiers per batch of 25 facts' },
    { title: 'Rank and trace', detail: 'ranker, then one tracer per path' },
    { title: 'Decide', detail: 'decisions, glossary, summary' },
  ],
}

const REPO = '/tmp/claude-0/-home-user-WalkthroughStudio/39a042c9-1c2b-5bc2-9a06-d6510d9fa60f/scratchpad/fixture-a'
const SHA = 'fb63e78744ce026d810547afbb62c0a08ce2040a'
const SHA7 = 'fb63e78'
const SKILL = '/home/user/WalkthroughStudio/.claude/skills/onboarding-research'
const survey = args

const COMMON = `
You are one research unit of the "onboarding-research" skill, producing part of a Research Packet for a repository. Read the contract first: ${SKILL}/SKILL.md, then the template named below in ${SKILL}/templates/, then /home/user/WalkthroughStudio/docs/onboarding/PACKET.md sections 3 and 4.
Repository checkout (read-only, do not modify, do not run git commands that change it): ${REPO}. Pinned commit: ${SHA} (sha7 ${SHA7}). Every code anchor is code:<path>@${SHA7}#L<a>-L<b> with the exact lines you read (check line numbers with cat -n or grep -n). Excerpts are the lines you read, at most 40, and any value that looks like a credential is replaced by [REDACTED] (config/settings.example contains a fake secret; its VALUE must never appear in your output, the KEY name may).
Survey (from survey_repo.py): inventory ${JSON.stringify(survey.inventory)}; history ${JSON.stringify(survey.history)}.
Return ONLY the structured output.`

const FACT = { type: 'object', properties: {
  id: { type: 'string' }, kind: { type: 'string', enum: ['component','interface','endpoint','dependency','dataEntity','dataField','flowHop','decision','risk','owner','hotspot','testCoverage','migration','config','integration','deployStep','incidentPattern','term','landmine','metric','buildResult','security','observability'] },
  subject: { type: 'string' }, claim: { type: 'string' }, attributes: { type: 'object' },
  evidence: { type: 'array', minItems: 1, items: { type: 'object', properties: { anchor: { type: 'string' }, excerpt: { type: 'string' }, note: { type: 'string' } }, required: ['anchor'] } },
  confidence: { type: 'number' } }, required: ['id','kind','subject','claim','evidence','confidence'] }
const MAP_OUT = { type: 'object', properties: { unit: { type: 'string' }, facts: { type: 'array', items: FACT }, readPaths: { type: 'array', items: { type: 'string' } }, skipped: { type: 'array', items: { type: 'string' } } }, required: ['unit','facts','readPaths','skipped'] }

phase('Map')
const MAPPERS = [
  { unit: 'map-src', dirs: 'src/ (all four Python files: api, auth, service, repo)' },
  { unit: 'map-db', dirs: 'db/ (schema.sql and both migrations)' },
  { unit: 'map-ops', dirs: 'deploy/, config/, templates/, and the root files README.md and requirements.txt (directory "." in coverage terms)' },
  { unit: 'map-ci', dirs: '.github/ and tests/. Do NOT read vendor/ (it is generated and must stay unread in coverage); you may note that it exists from the inventory only.' },
]
const mapped = (await parallel(MAPPERS.map(m => () => agent(`${COMMON}
Template: templates/mapper.md. Unit id: ${m.unit}. Directories to map: ${m.dirs}. You may read other files to understand calls but emit facts only about your directories. Fact ids are F-${m.unit}-001, 002, ... producedBy ${m.unit}. Aim for the number of facts the template suggests; small files still deserve several precise facts (what it is, its interface, its risks, its landmines). dataEntity facts must carry attributes pii, rows, retention (values or "unknown"). Also record history-derived facts for your directories (hotspot, owner) citing code: anchors for the file plus commit: anchors from the survey where relevant.`,
  { label: m.unit, phase: 'Map', schema: MAP_OUT, effort: 'high' })))).filter(Boolean)
log(`mapped: ${mapped.map(m => m.unit + '=' + m.facts.length).join(', ')}`)

phase('Lenses')
const factsSoFar = mapped.flatMap(m => m.facts)
const LENS_OUT = { type: 'object', properties: { unit: { type: 'string' }, facts: { type: 'array', items: FACT }, readPaths: { type: 'array', items: { type: 'string' } },
  dependencies: { type: 'array', items: { type: 'object', properties: { name: { type: 'string' }, version: { type: 'string' }, manifest: { type: 'string' }, ecosystem: { type: 'string' }, license: { type: 'string' }, eol: { type: 'string' }, cves: { anyOf: [ { type: 'string' }, { type: 'array', items: { type: 'object', properties: { id: { type: 'string' }, severity: { type: 'string' }, url: { type: 'string' }, note: { type: 'string' } }, required: ['id','severity'] } } ] }, direct: { type: 'boolean' }, note: { type: 'string' }, evidence: { type: 'array', items: { type: 'string' } } }, required: ['name','version','manifest','ecosystem','license','eol','cves'] } },
  glossary: { type: 'array', items: { type: 'object', properties: { term: { type: 'string' }, definition: { type: 'string' }, definedAt: { type: 'string' } }, required: ['term','definition'] } } }, required: ['unit','facts','readPaths'] }
const LENSES = [
  { unit: 'lens-data-migrations', brief: 'Lenses: data AND migrations. Every store and table, PII columns, retention, backups, ORM versus raw SQL, migrations written versus applied (compare db/migrations/* against db/schema.sql and what src/ reads), half-finished work and TODOs referencing unfinished changes.' },
  { unit: 'lens-dependencies', brief: 'Lens: dependencies. For each entry of the survey dependencies list, fill license (SPDX), eol status and known CVEs with ids and severity, citing url: anchors only if you actually fetched a page (WebFetch/WebSearch may be unavailable; then write "unknown" and say so in note). requests 2.19.0 and psycopg2 2.8.6 are old pins: state what you know with confidence levels and mark uncertain items unknown rather than inventing CVE ids. Return the rewritten dependencies array in the dependencies field, plus dependency-kind facts about the pins with manifest anchors.' },
  { unit: 'lens-deploy-ops', brief: 'Lenses: deploy, observability, integrations. How code reaches production (deploy/deploy.sh, ci.yml), rollback, migrations at deploy time, secrets, environments; what is logged or metered (likely nothing: that is a finding with evidence of where logging would be expected); every external call (database, ssh/scp targets, email template implies a sender) with failure modes, timeouts, retries.' },
  { unit: 'lens-security-tests', brief: 'Lenses: security AND testTruth. Authentication and authorization model (src/auth/authz.py and where it is or is not called), input validation at boundaries, secrets handling (config/settings.example), tenant isolation, audit trail; what tests/test_orders.sh actually covers versus what the handler, service and repo do, whether CI runs them, skipped or missing tests on money, auth and data paths.' },
  { unit: 'lens-landmines-glossary', brief: 'Lenses: landmines AND glossary. Non-obvious things that would cost a newcomer a day (retry semantics, connection lifetime, manual migrations, deploy without rollback, template placeholders, generated code in vendor/), each as a landmine fact; and the domain glossary (order, user, address, total, idempotency key as used or missing) returned in the glossary field with definedAt anchors.' },
]
const lensed = (await parallel(LENSES.map(l => () => agent(`${COMMON}
Template: templates/lens.md. Unit id: ${l.unit}. ${l.brief}
Facts found so far by the mappers (do not duplicate them; build on them): ${JSON.stringify(factsSoFar.map(f => ({ id: f.id, kind: f.kind, subject: f.subject, claim: f.claim })))}
Fact ids are F-${l.unit}-001, 002, ... producedBy ${l.unit}. Survey dependencies list: ${JSON.stringify(survey.dependencies.dependencies)}.`,
  { label: l.unit, phase: 'Lenses', schema: LENS_OUT, effort: 'high' })))).filter(Boolean)
log(`lenses: ${lensed.map(l => l.unit + '=' + l.facts.length).join(', ')}`)

phase('Verify')
const allFacts = [...factsSoFar, ...lensed.flatMap(l => l.facts)]
const batches = []
for (let i = 0; i < allFacts.length; i += 25) batches.push(allFacts.slice(i, i + 25))
const VERDICTS_OUT = { type: 'object', properties: { verifier: { type: 'string' }, verdicts: { type: 'array', items: { type: 'object', properties: { id: { type: 'string' }, verdict: { type: 'string', enum: ['confirmed','refuted','unknown'] }, reason: { type: 'string' }, evidence: { type: 'array', items: { type: 'string' } } }, required: ['id','verdict','reason','evidence'] } } }, required: ['verifier','verdicts'] }
const verdictSets = await pipeline(batches, (batch, _item, i) => parallel(['a', 'b'].map(side => () => agent(`${COMMON}
Template: templates/verifier.md. Verifier id: verify-${String(i + 1).padStart(2, '0')}-${side}. ${side === 'a' ? 'Read the cited lines first, then the surrounding function.' : 'Read the whole file first, then locate the cited lines; be especially strict about claims broader than their evidence.'}
Facts to verify (return one verdict per fact id, all ${batch.length}): ${JSON.stringify(batch)}`,
  { label: `verify-${i + 1}-${side}`, phase: 'Verify', schema: VERDICTS_OUT, effort: 'high' }))))
const verdictsById = {}
for (const pair of verdictSets) for (const vs of (pair || []).filter(Boolean)) for (const v of vs.verdicts) {
  (verdictsById[v.id] ||= []).push({ verifier: vs.verifier, verdict: v.verdict, reason: v.reason, evidence: v.evidence })
}
const statusFor = (vs) => {
  const c = vs.filter(v => v.verdict === 'confirmed').length
  const r = vs.filter(v => v.verdict === 'refuted' && v.evidence.length > 0).length
  if (r >= 2) return 'refuted'
  if (c >= 1 && r === 0) return 'verified'
  return 'unknown'
}
const facts = allFacts.map(f => { const vs = verdictsById[f.id] || []; return { ...f, verdicts: vs, status: vs.length ? statusFor(vs) : 'proposed' } })
const counts = facts.reduce((acc, f) => { acc[f.status] = (acc[f.status] || 0) + 1; return acc }, {})
log(`verified statuses: ${JSON.stringify(counts)}`)

phase('Rank and trace')
const usable = facts.filter(f => f.status !== 'refuted')
const PATHS_OUT = { type: 'object', properties: { candidates: { type: 'integer' }, paths: { type: 'array', items: { type: 'object', properties: { id: { type: 'string' }, title: { type: 'string' }, entry: { type: 'string' }, rank: { type: 'integer' }, rationale: { type: 'string' }, businessImpact: { type: 'string' }, factIds: { type: 'array', items: { type: 'string' } } }, required: ['id','title','entry','rank','rationale','businessImpact','factIds'] } }, untraced: { type: 'array', items: { type: 'object', properties: { id: { type: 'string' }, title: { type: 'string' }, reason: { type: 'string' } }, required: ['id','reason'] } } }, required: ['candidates','paths','untraced'] }
const ranked = await agent(`${COMMON}
Template: templates/ranker.md. Rank every critical path the evidence supports (there is no fixed count; the fixture is small, expect roughly two to four). Use only these fact ids in factIds: ${JSON.stringify(usable.map(f => ({ id: f.id, kind: f.kind, subject: f.subject, claim: f.claim, status: f.status })))}`,
  { label: 'rank-paths', phase: 'Rank and trace', schema: PATHS_OUT, effort: 'xhigh' })
log(`paths: ${ranked.paths.map(p => p.id).join(', ')}; untraced ${ranked.untraced.length}`)
const CONCERN = { type: 'object', properties: { status: { type: 'string', enum: ['present','absent','unknown'] }, evidence: { type: 'array', items: { type: 'string' } }, note: { type: 'string' } }, required: ['status','evidence'] }
const TRACE_OUT = { type: 'object', properties: { pathId: { type: 'string' }, title: { type: 'string' }, entry: { type: 'string' }, scenario: { type: 'string' },
  hops: { type: 'array', minItems: 1, items: { type: 'object', properties: { n: { type: 'integer' }, anchor: { type: 'string' }, callSite: { type: 'string' }, summary: { type: 'string' }, factIds: { type: 'array', items: { type: 'string' } } }, required: ['n','anchor','summary','factIds'] } },
  concerns: { type: 'object', properties: Object.fromEntries(['entry','authorization','validation','businessLogic','persistence','sideEffects','failureHandling','idempotency','timeoutsRetries','logging'].map(k => [k, CONCERN])), required: ['entry','authorization','validation','businessLogic','persistence','sideEffects','failureHandling','idempotency','timeoutsRetries','logging'] },
  scaresMe: { type: 'array', minItems: 1, items: { type: 'string' } }, factIds: { type: 'array', items: { type: 'string' } } }, required: ['pathId','title','entry','scenario','hops','concerns','scaresMe','factIds'] }
const traces = (await parallel(ranked.paths.map(p => () => agent(`${COMMON}
Template: templates/tracer.md. Path: ${JSON.stringify(p)}. Use only these fact ids in factIds: ${JSON.stringify(usable.map(f => f.id))}. Hop numbers start at 1 and increase by one; callSite is the anchor of the calling line or omitted.`,
  { label: `trace:${p.id}`, phase: 'Rank and trace', schema: TRACE_OUT, effort: 'xhigh' })))).filter(Boolean)
log(`traces: ${traces.length}`)

phase('Decide')
const DECIDE_OUT = { type: 'object', properties: {
  decisions: { type: 'array', items: { type: 'object', properties: { id: { type: 'string' }, title: { type: 'string' }, decision: { type: 'string' }, alternatives: { type: 'array', items: { type: 'string' } }, consequences: { type: 'string' }, wouldRepeat: { type: 'boolean' }, evidence: { type: 'array', minItems: 1, items: { type: 'string' } }, factIds: { type: 'array', items: { type: 'string' } } }, required: ['id','title','decision','alternatives','consequences','evidence','factIds'] } },
  summary: { type: 'string', description: 'one paragraph a stranger reads first, at least 60 words' },
  topFindings: { type: 'array', items: { type: 'string' } } }, required: ['decisions','summary','topFindings'] }
const decided = await agent(`${COMMON}
Write decisions.json content (retroactive architecture decision records the code implies: raw SQL over an ORM, retry strategy, deploy by scp with no rollback, hand-applied migrations, authorization in the handler, test strategy), the packet summary paragraph, and the top ten findings in plain sentences with anchors. Use only these fact ids: ${JSON.stringify(usable.map(f => ({ id: f.id, claim: f.claim })))}. Traces: ${JSON.stringify(traces.map(t => ({ pathId: t.pathId, scaresMe: t.scaresMe, concerns: Object.fromEntries(Object.entries(t.concerns).map(([k, v]) => [k, v.status])) })))}`,
  { label: 'decisions', phase: 'Decide', schema: DECIDE_OUT, effort: 'high' })

return { mapped, lensed, facts, ranked, traces, decided }