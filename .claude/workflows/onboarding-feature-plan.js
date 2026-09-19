export const meta = {
  name: 'onboarding-feature-plan',
  description: 'Map reusable parts of Walkthrough Studio, then design the AI codebase-onboarding feature via proposal panel + judges + synthesis',
  phases: [
    { title: 'Understand', detail: 'parallel readers over each subsystem, structured reuse map' },
    { title: 'Design', detail: 'three independent architecture proposals from different angles' },
    { title: 'Judge', detail: 'three lenses score the proposals' },
    { title: 'Synthesize', detail: 'one architecture + phasing, then a completeness critic' },
  ],
}

const FEATURE = `
FEATURE UNDER DESIGN: a new top-level menu option in Walkthrough Studio, "Onboard to a Codebase". The user points it at a GitHub repo URL (or local clone). The app then, with NO remote humans involved, uses a fleet of AI sub-agents (as many as needed) to research the repository and generate a complete onboarding package, including videos. Deliverables the fleet must produce (from the acquisition-onboarding playbook the user already approved):
- Code-anchored diagrams: C4 context + container (+ component for critical containers), ERD with PII/volume flags, deployment topology. Every box links to repo path + owner; every arrow names protocol + contract file. Source form (Mermaid) + rendered.
- Critical path traces: for the 5-10 flows the product cannot live without, a sequence diagram + narrated video following one real request through the actual code (entry, authz, validation, logic, persistence, side effects, failure handling, idempotency, timeouts/retries, logging) ending with "what scares me about this path".
- A video series (each <= 15 min, chaptered, TL;DR card in first 30 s, screen shows real code not slides): architecture overview, domain model, code tour, dev env to green tests, deploy/release/rollback, data layer, observability/on-call, security posture, integrations, half-finished migrations, plus one "confessional" per subsystem (what is fragile, what only the code knows).
- Written registers in markdown: architecture narrative, retroactive ADRs, ownership/bus-factor map from git history, dependency register (EOL/license/CVE), ranked tech-debt register, incident/bug-pattern register, operational scorecard, test-strategy truth (coverage on critical paths), data inventory, security posture, glossary, landmines doc (like this repo's CLAUDE.md).
- A hub index page tying everything together with recommended order and minutes per item.
KEY UX REQUIREMENTS: documents and videos must be INTERACTIVE and INTERTWINED with each other and with the code (click a diagram box -> file; a doc section -> the video chapter that covers it; a video chapter -> the doc + the exact file@sha#Lline). While a video plays, the user can chat with an agent that knows exactly what is on screen and what has been narrated so far, so every video needs a TIMESTAMPED transcript plus a per-timestamp map of visible code refs. The onboarding must be as seamless as possible: point at a repo, wait, review.
HARD CONSTRAINTS: native macOS SwiftUI Swift Package (no .xcodeproj), no third-party Swift dependencies unless the human approves (state clearly if you think one is worth asking for), Anthropic Messages API over raw HTTP (AnthropicClient exists), ElevenLabs TTS (client exists), existing video/HTML rendering pipeline, API keys in Keychain only. The build will be done by AI agents in many sessions and WILL exceed context/session limits repeatedly, so the design must be resumable/checkpointed and must keep a build log. Verification is the headless selftest pattern in SelfTest.swift.
`

const MAP_SCHEMA = {
  type: 'object',
  properties: {
    subsystem: { type: 'string' },
    files: { type: 'array', items: { type: 'string' } },
    capabilities: { type: 'array', items: { type: 'object', properties: {
      name: { type: 'string' }, entry: { type: 'string', description: 'file:symbol' },
      what: { type: 'string' }, reuseForOnboarding: { type: 'string', description: 'how the onboarding feature can reuse or extend it, or "none"' } },
      required: ['name', 'entry', 'what', 'reuseForOnboarding'] } },
    integrationPoints: { type: 'array', items: { type: 'string' }, description: 'exact places (file:symbol) where a new feature would hook in: menu, view model, pipeline, persistence, settings, selftest' },
    constraints: { type: 'array', items: { type: 'string' }, description: 'conventions, gotchas, threading/MainActor rules, format contracts that the new feature must honor' },
    gaps: { type: 'array', items: { type: 'string' }, description: 'what this subsystem cannot do today that the feature needs (e.g. tool-use loop, streaming, timestamps, git)' },
  },
  required: ['subsystem', 'files', 'capabilities', 'integrationPoints', 'constraints', 'gaps'],
}

const SUBSYSTEMS = [
  { key: 'app-shell', files: 'Sources/WalkthroughStudio/WalkthroughStudioApp.swift, Sources/WalkthroughStudio/Views/ContentView.swift, Sources/WalkthroughStudio/StudioViewModel.swift, Sources/WalkthroughStudio/Models.swift, Sources/WalkthroughStudio/Views/ProcessingView.swift, Sources/WalkthroughStudio/Views/ReviewView.swift', focus: 'app shell, menu/commands, project model + persistence, the run() busy gate and autoPipelineCore() pipeline, pipelineNotice, how a new top-level mode/menu option would be added' },
  { key: 'llm', files: 'Sources/WalkthroughStudio/Services/AnthropicClient.swift, Sources/WalkthroughStudio/Services/Briefing.swift, Sources/WalkthroughStudio/Views/SetupSheet.swift, Sources/WalkthroughStudio/Views/SettingsView.swift, Sources/WalkthroughStudio/Services/Keychain.swift', focus: 'Anthropic Messages API plumbing: request/response shapes, model selection, gateway support, whether tool use / streaming / system prompts / long contexts are supported today, what an agentic tool-use loop with sub-agents would need' },
  { key: 'audio', files: 'Sources/WalkthroughStudio/Services/ElevenLabsClient.swift, Sources/WalkthroughStudio/Services/SpeechTranscriber.swift, Sources/WalkthroughStudio/Views/NarrationView.swift, Sources/WalkthroughStudio/Services/Exporters.swift', focus: 'TTS synthesis, formats, how narration audio durations are known, SRT/caption generation, whether word/character timestamps exist or could (ElevenLabs with-timestamps endpoint), transcription seam' },
  { key: 'video', files: 'Sources/WalkthroughStudio/Services/VideoService.swift, Sources/WalkthroughStudio/Services/FrameCompositor.swift, Sources/WalkthroughStudio/Services/VideoFrame.swift, Sources/WalkthroughStudio/Resources/video-frame-template.html, Sources/WalkthroughStudio/Views/ExportVideoSheet.swift, Sources/WalkthroughStudio/Services/SceneDetector.swift', focus: 'how the narrated video timeline is assembled from ExportSegments, how frames are composited, whether a video can be built from rendered HTML/still frames with NO source screen recording, chapter/segment timing, SRT alignment' },
  { key: 'render', files: 'Sources/WalkthroughStudio/Services/BrandedRenderer.swift, Sources/WalkthroughStudio/Services/BrandTheme.swift, Sources/WalkthroughStudio/Views/BrandedView.swift, Sources/WalkthroughStudio/Resources/slide-template.html, Sources/WalkthroughStudio/Views/ThemeEditorView.swift', focus: 'offscreen WKWebView rasterization of HTML templates, the {{PLACEHOLDER}} contract, TemplateStore user overrides, theming; whether it can render code listings, Mermaid diagrams, and animated "code walk" frames' },
  { key: 'verify', files: 'Sources/WalkthroughStudio/SelfTest.swift, scripts/make-test-video.swift, build-app.sh, Package.swift, Support/Info.plist, README.md', focus: 'the headless selftest harness and probe pattern, packaging/signing, resources bundling, how a large new feature would be tested headlessly and what fixture (a tiny synthetic repo) it would need' },
]

phase('Understand')
const maps = (await parallel(SUBSYSTEMS.map(s => () => agent(
`You are mapping ONE subsystem of the Walkthrough Studio macOS app (Swift Package at the current working directory) to prepare the design of a new feature. Read-only: do not edit files.
Subsystem: ${s.key}. Read these files fully: ${s.files}. Follow references into other files when needed to be accurate.
Focus: ${s.focus}.
${FEATURE}
Return a precise, code-anchored map for this subsystem only (file:symbol references, not vague descriptions). Be concrete about gaps: what would have to be built. Return ONLY the structured output.`,
  { label: `map:${s.key}`, phase: 'Understand', schema: MAP_SCHEMA })))).filter(Boolean)
log(`mapped ${maps.length}/${SUBSYSTEMS.length} subsystems`)
const mapDigest = JSON.stringify(maps)

const PROPOSAL_SCHEMA = {
  type: 'object',
  properties: {
    angle: { type: 'string' },
    summary: { type: 'string', description: '5-10 sentences' },
    components: { type: 'array', items: { type: 'object', properties: {
      name: { type: 'string' }, responsibility: { type: 'string' },
      newOrReused: { type: 'string', enum: ['new', 'reused', 'extended'] },
      files: { type: 'array', items: { type: 'string' }, description: 'existing files touched or new files to create' } },
      required: ['name', 'responsibility', 'newOrReused', 'files'] } },
    dataModel: { type: 'string', description: 'the on-disk package format: directories, JSON/markdown files, how docs/videos/code refs/transcripts link to each other; include the anchor scheme (file@sha#Lx, video#t=)' },
    agentOrchestration: { type: 'string', description: 'how the research fleet runs: runtime choice (native Messages API tool-use loop in Swift vs Claude Code CLI subprocess vs other), tool set, sub-agent roles, checkpointing/resume, cost controls' },
    videoGeneration: { type: 'string', description: 'how each video is produced without a screen recording: scene types, how code is shown, chapters, narration, rendering pipeline, timing' },
    timestampedTranscript: { type: 'string', description: 'how the per-timestamp transcript and visible-code-ref map are produced and stored' },
    interactivePlayer: { type: 'string', description: 'the in-app player + docs experience: cross-links, navigation, tech (SwiftUI/AppKit/WKWebView)' },
    contextAgent: { type: 'string', description: 'the chat agent during playback: exactly what context it is given at time t, how it cites code, how it answers' },
    phasing: { type: 'array', items: { type: 'string' }, description: 'ordered milestones, each independently demoable and selftest-probeable' },
    risks: { type: 'array', items: { type: 'string' } },
    thirdPartyAsks: { type: 'array', items: { type: 'string' }, description: 'dependencies worth asking the human for, with why; empty if none' },
    openQuestions: { type: 'array', items: { type: 'string' } },
  },
  required: ['angle', 'summary', 'components', 'dataModel', 'agentOrchestration', 'videoGeneration', 'timestampedTranscript', 'interactivePlayer', 'contextAgent', 'phasing', 'risks', 'thirdPartyAsks', 'openQuestions'],
}

const ANGLES = [
  { key: 'reuse-first', brief: 'Maximize reuse of the existing pipeline: treat the onboarding package as a generalization of the current WalkthroughStep/ExportSegment model so docs, videos and hub fall out of existing renderers with minimal new surface. Bias toward the smallest set of new abstractions.' },
  { key: 'agent-first', brief: 'Design from the research fleet outward: a robust, resumable orchestrator with typed research artifacts (facts with evidence citations) as the single source of truth, from which every deliverable is a deterministic projection. Bias toward correctness, verifiability and never losing work when a session dies.' },
  { key: 'experience-first', brief: 'Design from the interactive player outward: the moment-to-moment experience of watching a code walk video, clicking into code, asking the agent a question at t=4:32 and getting a cited answer. Bias toward the cross-linking data model and the player, then derive what the fleet must produce.' },
]

phase('Design')
const proposals = (await parallel(ANGLES.map(a => () => agent(
`You are a senior architect proposing the design for a new feature in the Walkthrough Studio macOS app (Swift Package at cwd). Read-only.
${FEATURE}
Your assigned angle: ${a.key}. ${a.brief}
Here is a code-anchored map of the existing subsystems produced by readers (trust it, but open files when you need detail): ${mapDigest}
Be decisive and concrete: name files, types, and formats. Make the runtime choice for the agent fleet and defend it against the alternatives. Make the video-generation approach work with the constraint that there is NO screen recording (the app must render code walks itself). Specify the timestamped transcript and per-timestamp code-ref map format. Specify what the playback chat agent is given at time t. Phasing must be milestones an AI can build in separate sessions with a headless selftest probe each. Return ONLY the structured output.`,
  { label: `design:${a.key}`, phase: 'Design', schema: PROPOSAL_SCHEMA, effort: 'high' })))).filter(Boolean)
log(`${proposals.length} proposals ready`)
const proposalDigest = JSON.stringify(proposals)

const JUDGE_SCHEMA = {
  type: 'object',
  properties: {
    lens: { type: 'string' },
    scores: { type: 'array', items: { type: 'object', properties: {
      angle: { type: 'string' }, score: { type: 'number', description: '0-10' }, rationale: { type: 'string' } },
      required: ['angle', 'score', 'rationale'] } },
    graft: { type: 'array', items: { type: 'string' }, description: 'specific ideas from the non-winning proposals that the final design must keep' },
    fatalFlaws: { type: 'array', items: { type: 'string' }, description: 'anything in any proposal that will not work in this codebase/platform, with why' },
  },
  required: ['lens', 'scores', 'graft', 'fatalFlaws'],
}
const LENSES = [
  { key: 'feasibility', brief: 'Will this actually build and run in THIS codebase on macOS with no third-party deps? Check claims against the code (open files). Weigh session-resumability and headless testability heavily.' },
  { key: 'experience', brief: 'Is the interactive docs+video+code+agent experience genuinely seamless for the onboarding engineer? Does the cross-link data model support every promised click? Is the playback agent context sufficient to answer "what is that function on screen doing" at any t?' },
  { key: 'risk', brief: 'Where will the research fleet produce confident nonsense, miss critical paths, or burn unbounded tokens? Is every deliverable grounded in evidence citations? Can a human verify claims? Are cost and time bounded?' },
]

phase('Judge')
const judgments = (await parallel(LENSES.map(l => () => agent(
`You are judging three architecture proposals for a new feature in the Walkthrough Studio macOS app (Swift Package at cwd). Read-only; open files to check claims.
${FEATURE}
Your lens: ${l.key}. ${l.brief}
Subsystem map: ${mapDigest}
Proposals: ${proposalDigest}
Score each proposal 0-10 under your lens with a rationale, list ideas to graft from non-winners, and list fatal flaws with evidence. Return ONLY the structured output.`,
  { label: `judge:${l.key}`, phase: 'Judge', schema: JUDGE_SCHEMA, effort: 'high' })))).filter(Boolean)
log(`${judgments.length} judgments ready`)

const SYNTH_SCHEMA = {
  type: 'object',
  properties: {
    decisionSummary: { type: 'string', description: '10-15 sentences: the chosen architecture and why' },
    architectureMarkdown: { type: 'string', description: 'full architecture section in markdown: components (new/extended/reused with files), package data model with anchor scheme, fleet orchestration + resume, video generation, transcript + code-ref map, player, playback agent. Use headings ###, tables where useful, no emoji.' },
    decisionsMarkdown: { type: 'string', description: 'ADR-style list: each decision, alternatives, why, consequences' },
    phasingMarkdown: { type: 'string', description: 'ordered milestones M0..Mn, each: goal, files, selftest probe, demo, estimated sessions' },
    risksMarkdown: { type: 'string', description: 'ranked risks with mitigations' },
    thirdPartyAsks: { type: 'array', items: { type: 'string' } },
    openQuestionsForHuman: { type: 'array', items: { type: 'string' }, description: 'only questions that change the build materially' },
  },
  required: ['decisionSummary', 'architectureMarkdown', 'decisionsMarkdown', 'phasingMarkdown', 'risksMarkdown', 'thirdPartyAsks', 'openQuestionsForHuman'],
}

phase('Synthesize')
const synth = await agent(
`You are the lead architect. Synthesize ONE final architecture for the feature below from three proposals and three judgments. Take the winner by weighted score, graft every idea the judges asked to keep, and remove every fatal flaw. Read-only; open files in the repo (cwd) when needed.
${FEATURE}
Subsystem map: ${mapDigest}
Proposals: ${proposalDigest}
Judgments: ${JSON.stringify(judgments)}
Write for a hand-off document that AI agents will build from across many sessions: precise file names, type names, JSON/markdown formats, and one selftest probe per milestone. No emoji, no em-dashes. Return ONLY the structured output.`,
  { label: 'synthesize', phase: 'Synthesize', schema: SYNTH_SCHEMA, effort: 'max' })

const CRITIC_SCHEMA = {
  type: 'object',
  properties: {
    missing: { type: 'array', items: { type: 'string' }, description: 'requirements from the feature brief the synthesis does not cover, each with the fix' },
    contradictions: { type: 'array', items: { type: 'string' } },
    unverifiedClaims: { type: 'array', items: { type: 'string' }, description: 'claims about the codebase or platform APIs that were not checked, each with how to check' },
    userStoryGaps: { type: 'array', items: { type: 'string' }, description: 'user-facing behaviors implied by the brief that need a user story' },
  },
  required: ['missing', 'contradictions', 'unverifiedClaims', 'userStoryGaps'],
}
const critic = await agent(
`You are the completeness critic for a feature architecture. Read-only; open repo files (cwd) to check claims.
${FEATURE}
Synthesis: ${JSON.stringify(synth)}
Find what is missing versus the brief, contradictions, unverified claims about the codebase or Apple/ElevenLabs/Anthropic APIs, and user-facing behaviors that lack a user story. Be specific. Return ONLY the structured output.`,
  { label: 'critic', phase: 'Synthesize', schema: CRITIC_SCHEMA, effort: 'high' })

return { maps, proposals, judgments, synth, critic }