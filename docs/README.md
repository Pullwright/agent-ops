# Documentation

This is the map of all documentation in this repository, the conventions that
govern them, and a routing table to find answers to common questions.

## Quick routing

Where to start for common questions: each row names the file and the heading
to read first.

| What you want to do | Where to find it |
|----------------------|-------------------|
| Reserve an issue so the pipeline doesn't pick it up while you work on it yourself | `docs/guides/working-with-pullwright/README.md` § "Reserving an issue for yourself" |
| Understand what a "refined" item is and what the Refiner does | `docs/guides/operating/watch.md` or `docs/spec/implementation/requirements/refiner.md` § "The Refiner" |
| Understand how the pipeline prioritizes which issue to work on next | `docs/guides/working-with-pullwright/README.md` § "Issue priority" |
| Understand what "blocked" and "void" mean, and what to do if you disagree with one | `docs/guides/operating/diagnose-by-symptom.md` § "An item is blocked or void" |
| Respond to review comments the pipeline left on your pull request | `docs/guides/working-with-pullwright/README.md` § "Responding to your review comments" |
| Pause the pipeline fleet without killing in-flight work | `docs/guides/operating/run-and-pause.md` § "Draining instead of stopping" |
| Let one node reach an outside address without opening it up fleet-wide | `docs/guides/operating/install-a-node.md` § "The egress fence" |
| Check that a freshly brought-up node is configured correctly before it starts working | `docs/guides/operating/diagnose-by-symptom.md` § "Checking an installation" |
| Get a node onto a newer image after merging a fix | `deploy/docker/README.md` § "Updating" |
| Figure out why no node has opened a pull request in a while | `docs/guides/operating/diagnose-by-symptom.md` § "A pull request will not land" |
| See what you need to provide to run an instance on your own infrastructure | `deploy/docker/README.md` § "What you need first" |
| See which product decisions are still open | `docs/ROADMAP.md` § "Open questions" |
| Understand which node in the fleet runs a given cycle | `docs/guides/operating/watch.md` § "Which node runs the cycles" |
| Understand the levels of merge autonomy | `docs/guides/working-with-pullwright/README.md` § "Merge autonomy" |
| Run the test suite | `docs/guides/contributing/README.md` § "Running the tests" |
| Understand which parts of the docs are generated and must not be hand-edited | `AGENTS.md` § "Generated regions" |
| Understand where a changelog entry belongs | `AGENTS.md` § "Documentation principles" |
| Try a change on a real node before it merges | `docs/guides/contributing/README.md` § "Trying a change on a real node before it merges" |
| Find the requirement governing when a claim on an item expires | `docs/spec/implementation/configuration.md` § "Extended notes: `claim_ttl_hours`" |
| Find the requirement governing the daily merge budget | `docs/spec/implementation/configuration.md` § "Extended notes: `merge_budget_per_day`" |
| Understand how the as-built specifications relate to this repository | `docs/guides/contributing/README.md` § "For maintainers: the as-built specifications" |
| Understand why a cycle produced no change | `docs/guides/operating/run-and-pause.md` § "Staying warm without spending" |
| Understand how the pipeline avoids piling up unreviewed work | `docs/guides/working-with-pullwright/README.md` § "Staying in front of you" |
| View the monitoring dashboard | `docs/guides/operating/watch.md` § "The dashboard" |
| Look up a configuration key, its default, and its notes | `docs/reference/configuration.md` |

## All documents

This section lists every tracked Markdown document in the repository, excluding
`test/fixtures/`, `tech-debt/` (frozen archive), and giving each dated review
set under `docs/reviews/` one entry for its directory.

### Root-level documents

| File | Audience | Kind | Purpose |
|------|----------|------|---------|
| `README.md` | operator, evaluator, person working in repo | tutorial | Landing page: what Pullwright is, and where to go next |
| `CONTRIBUTING.md` | contributor, person working in repo | how-to | Guidelines for contributing; pointers to detailed conventions |
| `AGENTS.md` | agent, person working in repo, contributor | reference, explanation | Conventions for the repository: branch workflow, commit messages, PR rules, tech-debt, generated regions, documentation principles |
| `CLAUDE.md` | agent | reference | Pointer to AGENTS.md (AGENTS.md imports it) |
| `TECH-DEBT.md` | person working in repo, contributor | reference | Tech-debt filing and resolution workflow |
| `SECURITY.md` | evaluator, operator | reference | How to report a security vulnerability privately; no bug-bounty programme |
| `CHANGELOG.md` | operator, person working in repo | record | Dated history of changes (generated from PR descriptions) |

### Documentation directory: `docs/`

#### This map

| File | Audience | Kind | Purpose |
|------|----------|------|---------|
| `docs/README.md` | operator, evaluator, contributor, agent, person working in repo, reader of fleet output | reference | This document: the map of every tracked document, with the conventions that govern them |

#### Guides: `docs/guides/`

| File | Audience | Kind | Purpose |
|------|----------|------|---------|
| `docs/guides/working-with-pullwright/README.md` | person working in a target repository | how-to | How the pipeline selects, claims, and hands back work in a repository it works; review, merge autonomy, and dependencies |
| `docs/guides/operating/README.md` | operator | index | Entry point to the operating guides (see pages below) |
| `docs/guides/operating/install-a-node.md` | operator | how-to | Bring up a container node with credentials and roles |
| `docs/guides/operating/configure.md` | operator | how-to | Set up repositories, work sources, and configuration |
| `docs/guides/operating/run-and-pause.md` | operator | how-to | Operate the disable switch, drain mode, and usage limits |
| `docs/guides/operating/watch.md` | operator | how-to | Monitor dashboards, logs, and multi-node state sharing |
| `docs/guides/operating/diagnose-by-symptom.md` | operator | how-to | Troubleshoot by symptom, with causes and fixes |
| `docs/guides/operating/change-a-node.md` | operator | how-to | Roll images, update configuration, remove nodes |
| `docs/guides/contributing/README.md` | contributor | how-to | For maintainers, branch workflow, and development |

#### Reference: `docs/reference/`

| File | Audience | Kind | Purpose |
|------|----------|------|---------|
| `docs/reference/configuration.md` | operator, agent, contributor | reference | Every configuration key, its default, and its extended notes (generated from `config.schema.json`) |

#### Concepts (explanations)

| File | Audience | Kind | Purpose |
|------|----------|------|---------|
| `docs/concepts/glossary.md` | evaluator, agent, contributor, operator, person working in repo | explanation | Glossary of every coined or repurposed term, each defined once with a stable anchor |

#### Specifications (as-built)

Split into within-budget files by #2094: `docs/spec/implementation/` for the
implementation pipeline, `docs/spec/dashboard/` for the monitoring dashboard,
each with a `README.md` holding a directory-wide table of contents.

| File | Audience | Kind | Purpose |
|------|----------|------|---------|
| `docs/spec/implementation/README.md` | agent, contributor, evaluator | reference | Implementation pipeline specification: index, environment, actors, directory table of contents |
| `docs/spec/implementation/acceptance-checks/acceptance-checks-01.md` | agent, contributor, evaluator | reference | Implementation pipeline specification: Acceptance checks |
| `docs/spec/implementation/acceptance-checks/acceptance-checks-02.md` | agent, contributor, evaluator | reference | Implementation pipeline specification: Acceptance checks, part 2 of 6 |
| `docs/spec/implementation/acceptance-checks/acceptance-checks-03.md` | agent, contributor, evaluator | reference | Implementation pipeline specification: Acceptance checks, part 3 of 6 |
| `docs/spec/implementation/acceptance-checks/acceptance-checks-04.md` | agent, contributor, evaluator | reference | Implementation pipeline specification: Acceptance checks, part 4 of 6 |
| `docs/spec/implementation/acceptance-checks/acceptance-checks-05.md` | agent, contributor, evaluator | reference | Implementation pipeline specification: Acceptance checks, part 5 of 6 |
| `docs/spec/implementation/acceptance-checks/acceptance-checks-06.md` | agent, contributor, evaluator | reference | Implementation pipeline specification: Acceptance checks, part 6 of 6 |
| `docs/spec/implementation/components/components-01.md` | agent, contributor, evaluator | reference | Implementation pipeline specification: Components |
| `docs/spec/implementation/components/components-02.md` | agent, contributor, evaluator | reference | Implementation pipeline specification: Components, part 2 of 3 |
| `docs/spec/implementation/components/components-03.md` | agent, contributor, evaluator | reference | Implementation pipeline specification: Components, part 3 of 3 |
| `docs/spec/implementation/configuration.md` | agent, contributor, evaluator | reference | Implementation pipeline specification: Configuration |
| `docs/spec/implementation/cost-profile.md` | agent, contributor, evaluator | reference | Implementation pipeline specification: Cost profile |
| `docs/spec/implementation/design-decisions.md` | agent, contributor, evaluator | reference | Implementation pipeline specification: Design decisions |
| `docs/spec/implementation/environment.md` | agent, contributor, evaluator | reference | Implementation pipeline specification: Environment (verified 2026-07-20) |
| `docs/spec/implementation/gotchas.md` | agent, contributor, evaluator | reference | Implementation pipeline specification: Gotchas |
| `docs/spec/implementation/landing-gate.md` | agent, contributor, evaluator | reference | Implementation pipeline specification: The Landing Gate |
| `docs/spec/implementation/requirements/approver-01.md` | agent, contributor, evaluator | reference | Implementation pipeline specification: The Approver |
| `docs/spec/implementation/requirements/approver-02.md` | agent, contributor, evaluator | reference | Implementation pipeline specification: The Approver, part 2 of 2 |
| `docs/spec/implementation/requirements/co-ordinator-01.md` | agent, contributor, evaluator | reference | Implementation pipeline specification: The Co-Ordinator (selection only) |
| `docs/spec/implementation/requirements/co-ordinator-02.md` | agent, contributor, evaluator | reference | Implementation pipeline specification: The Co-Ordinator, part 2 of 2 |
| `docs/spec/implementation/requirements/enabler-01.md` | agent, contributor, evaluator | reference | Implementation pipeline specification: The Enabler |
| `docs/spec/implementation/requirements/enabler-02.md` | agent, contributor, evaluator | reference | Implementation pipeline specification: The Enabler, part 2 of 2 |
| `docs/spec/implementation/requirements/every-stage.md` | agent, contributor, evaluator | reference | Implementation pipeline specification: Every stage (untrusted external content) |
| `docs/spec/implementation/requirements/implementer.md` | agent, contributor, evaluator | reference | Implementation pipeline specification: The Implementer |
| `docs/spec/implementation/requirements/logging-and-state-01.md` | agent, contributor, evaluator | reference | Implementation pipeline specification: Logging and state |
| `docs/spec/implementation/requirements/logging-and-state-02.md` | agent, contributor, evaluator | reference | Implementation pipeline specification: Logging and state, part 2 of 2 |
| `docs/spec/implementation/requirements/refiner.md` | agent, contributor, evaluator | reference | Implementation pipeline specification: The Refiner |
| `docs/spec/implementation/requirements/reviewer.md` | agent, contributor, evaluator | reference | Implementation pipeline specification: The Reviewer |
| `docs/spec/implementation/requirements/the-script-01.md` | agent, contributor, evaluator | reference | Implementation pipeline specification: Requirements |
| `docs/spec/implementation/requirements/the-script-02.md` | agent, contributor, evaluator | reference | Implementation pipeline specification: The Script, part 2 of 10 |
| `docs/spec/implementation/requirements/the-script-03.md` | agent, contributor, evaluator | reference | Implementation pipeline specification: The Script, part 3 of 10 |
| `docs/spec/implementation/requirements/the-script-04.md` | agent, contributor, evaluator | reference | Implementation pipeline specification: The Script, part 4 of 10 |
| `docs/spec/implementation/requirements/the-script-05.md` | agent, contributor, evaluator | reference | Implementation pipeline specification: The Script, part 5 of 10 |
| `docs/spec/implementation/requirements/the-script-06.md` | agent, contributor, evaluator | reference | Implementation pipeline specification: The Script, part 6 of 10 |
| `docs/spec/implementation/requirements/the-script-07.md` | agent, contributor, evaluator | reference | Implementation pipeline specification: The Script, part 7 of 10 |
| `docs/spec/implementation/requirements/the-script-08.md` | agent, contributor, evaluator | reference | Implementation pipeline specification: The Script, part 8 of 10 |
| `docs/spec/implementation/requirements/the-script-09.md` | agent, contributor, evaluator | reference | Implementation pipeline specification: The Script, part 9 of 10 |
| `docs/spec/implementation/requirements/the-script-10.md` | agent, contributor, evaluator | reference | Implementation pipeline specification: The Script, part 10 of 10 |
| `docs/spec/dashboard/README.md` | operator, evaluator | reference | Monitoring dashboard specification: index, architecture, directory table of contents |
| `docs/spec/dashboard/components.md` | operator, evaluator | reference | Monitoring dashboard specification: Components (as built) |
| `docs/spec/dashboard/design-decisions.md` | operator, evaluator | reference | Monitoring dashboard specification: Design decisions |
| `docs/spec/dashboard/integration.md` | operator, evaluator | reference | Monitoring dashboard specification: Integration |
| `docs/spec/dashboard/publisher.md` | operator, evaluator | reference | Monitoring dashboard specification: The Publisher (`scripts/publish-dashboard.sh`) |
| `docs/spec/dashboard/site.md` | operator, evaluator | reference | Monitoring dashboard specification: The Site (`dashboard/index.html`) |
| `docs/spec/dashboard/state.md` | operator, evaluator | reference | Monitoring dashboard specification: State it reads (verified 2026-07-14) |
| `docs/spec/dashboard/verifying-a-change.md` | operator, evaluator | reference | Monitoring dashboard specification: Verifying a change |
| `docs/spec/review.md` | agent, contributor, evaluator | reference | As-built specification of the repository-review pipeline |
| `docs/spec/monitor.md` | operator, evaluator | reference | As-built specification of the Pipeline Monitor |

#### Schemas (reference)

| File | Audience | Kind | Purpose |
|------|----------|------|---------|
| `docs/FLOW-SCHEMA.md` | agent, evaluator | reference | Complete schema of the flow metadata structure |
| `docs/HOST-FACTS-SCHEMA.md` | agent, operator | reference | Schema of host facts collected by the pipeline |
| `docs/METERING-SCHEMA.md` | operator, evaluator | reference | Schema of metering and usage tracking |
| `docs/DATA-HANDLING.md` | operator, evaluator | reference | Data handling, retention, and privacy policies |

#### Planning and decision logs

| File | Audience | Kind | Purpose |
|------|----------|------|---------|
| `docs/ROADMAP.md` | operator, evaluator, person working in repo | decision log | Product roadmap and settled decisions; intent rather than as-built |
| `docs/STANDING-DECISIONS.md` | contributor, agent, person working in repo | decision log | Settled owner answers on recurring questions (lines added or amended, never deleted) |

#### Audits and investigations (records)

| File | Audience | Kind | Purpose |
|------|----------|------|---------|
| `docs/PHASE-1-POETIC-SPECIFICS-AUDIT.md` | evaluator, person working in repo | record | Point-in-time audit of Poetic-Poems-specific features (dated 2026) |
| `docs/VOCABULARY-SWEEP-679-AUDIT.md` | evaluator, contributor | record | Audit and cleanup of vocabulary inconsistencies (dated 2026) |
| `docs/PULLWRIGHT-DAY-ONE-AUTONOMY.md` | evaluator, contributor | record | Analysis of autonomy level on day one of product launch (dated 2026) |
| `docs/PULLWRIGHT-REHOMING.md` | operator, contributor | record | Runbook for moving the repository to the Pullwright organisation |
| `docs/PROVIDER-SEAM-AUDIT.md` | agent, contributor | record | Inventory of every place the code assumes the Claude Code CLI specifically, ahead of cutting the provider seam (dated 2026) |

#### Dated reviews (generated records)

| Directory | Audience | Kind | Purpose |
|-----------|----------|------|---------|
| `docs/reviews/2026-08-07-pipeline-flow-review.md` | evaluator, person working in repo | record | Pipeline flow review findings (generated report) |
| `docs/reviews/2026-08-14-autonomy-investigation.md` | evaluator, person working in repo | record | Autonomy levels investigation (generated report) |
| `docs/reviews/2026-08-15-merge-autonomy-baseline.md` | evaluator, person working in repo | record | Merge autonomy baseline review (generated report) |
| `docs/reviews/2026-08-23-d18-stage-3-promotion.md` | evaluator, contributor | record | Review for D18 Stage 3 promotion (generated report) |
| `docs/reviews/2026-09-11-escalation-autonomy-review.md` | evaluator, person working in repo | record | Escalation autonomy review (generated report) |
| `docs/reviews/2026-10-02-docs-benchmark.md` | evaluator, person working in repo | record | Documentation benchmark run measuring answer accuracy against a question set (generated report) |
| `docs/reviews/2026-10-02-docs-benchmark-2.md` | evaluator, person working in repo | record | Second documentation benchmark run against the same question set (generated report) |
| `docs/reviews/2026-10-03-rest-budget-shim-baseline.md` | evaluator, operator | record | Before/after REST budget and refusal counts for the `gh` transport shim (generated report) |
| `docs/reviews/2026-10-03-rest-budget-shim-baseline-pre.md` | evaluator, operator | record | Raw GitHub API budget report, pre-shim window (generated report) |
| `docs/reviews/2026-10-03-rest-budget-shim-baseline-post.md` | evaluator, operator | record | Raw GitHub API budget report, post-shim window (generated report) |
| `docs/reviews/2026-10-06-grok-build-evaluation.md` | evaluator, contributor | record | Grok Build run headlessly against the provider substrate contract, with the adapter specification for the xAI provider (#2132) |
| `docs/reviews/project-review-2026-08-23/` | evaluator, person working in repo, contributor | record | Full project review with summary, findings, recommendations, and improvement prompts (generated) |
| `docs/reviews/project-review-2026-08-31/` | evaluator, person working in repo, contributor | record | Full project review (generated) |
| `docs/reviews/project-review-2026-09-05/` | evaluator, person working in repo, contributor | record | Full project review (generated) |
| `docs/reviews/project-review-2026-09-21/` | evaluator, person working in repo, contributor | record | Full project review (generated) |
| `docs/reviews/project-review-2026-09-28/` | evaluator, person working in repo, contributor | record | Full project review (generated) |

### Pipeline prompts: `prompts/`

Each file is the operating prompt a Script invocation hands to one headless
agent for one pipeline stage; `docs/spec/implementation/README.md` and
`docs/spec/review.md` are the specifications these prompts
implement.

| File | Audience | Kind | Purpose |
|------|----------|------|---------|
| `prompts/coordinator.md` | agent, contributor | reference | Operating prompt for the Co-Ordinator stage: selects one item of work and emits a work order |
| `prompts/implementer.md` | agent, contributor | reference | Operating prompt for the Implementer stage: carries out a work order on a branch and raises a draft pull request |
| `prompts/reviewer.md` | agent, contributor | reference | Operating prompt for the Reviewer stage: checks the Implementer's pull request, fixes what it can, and hands off |
| `prompts/enabler.md` | agent, contributor | reference | Operating prompt for the Enabler stage: re-examines items the pipeline recorded as blocked |
| `prompts/enabler-decide.md` | agent, contributor | reference | Operating prompt for the Enabler's decide-tactical and decide-with-veto passes |
| `prompts/enabler-adjudicate.md` | agent, contributor | reference | Operating prompt for the Enabler's adjudication pass under `escalation_autonomy: "adjudicate-first"` |
| `prompts/approver.md` | agent, contributor | reference | Operating prompt for the Approver stage: an independent second look at a Reviewer-certified pull request |
| `prompts/approver-adjudicate-open-question.md` | agent, contributor | reference | Operating prompt for the Approver's adjudication pass over an open question raised on a pull request |
| `prompts/refiner.md` | agent, contributor | reference | Operating prompt for the Refiner stage: writes the specification an unscoped item lacks |
| `prompts/monitor.md` | agent, operator | reference | Operating prompt for the Pipeline Monitor: a scheduled reading of the pipelines' own state |
| `prompts/project-reviewer.md` | agent, contributor | reference | Operating prompt for the Reviewer-Agent stage of the repository-review pipeline |

### Claude Code skills: `.claude/skills/`

| File | Audience | Kind | Purpose |
|------|----------|------|---------|
| `.claude/skills/project-review/SKILL.md` | agent, contributor | how-to | Instructions an agent follows to run a full project review |
| `.claude/skills/project-review/references/output-templates.md` | agent | reference | Templates for the project review's output documents |
| `.claude/skills/project-review/references/prompt-writing.md` | agent | reference | How to write the improvement prompts a project review produces |
| `.claude/skills/project-review/references/resumability.md` | agent | reference | How a project review checkpoints and resumes after an interruption |
| `.claude/skills/project-review/references/review-checklist.md` | agent | reference | The review dimensions and checklist a project review works through |
| `.claude/skills/td/SKILL.md` | agent, contributor | how-to | Instructions an agent follows to resolve a single tech-debt item via `/td <n>` |

### GitHub templates: `.github/`

| File | Audience | Kind | Purpose |
|------|----------|------|---------|
| `.github/ISSUE_TEMPLATE/issue.md` | contributor, person working in repo | reference | Template GitHub pre-fills for a new issue |
| `.github/PULL_REQUEST_TEMPLATE.md` | contributor, person working in repo | reference | Template GitHub pre-fills for a new pull request description |

### Node deployment: `deploy/docker/`

| File | Audience | Kind | Purpose |
|------|----------|------|---------|
| `deploy/docker/README.md` | operator | how-to | How to run, update, and remove one node (a Docker Compose project) |

## Documentation conventions

### Kinds of documents

Six kinds of documents live in this repository. Each document has one primary
kind. Understanding the kind helps you know what to expect and when to trust
what you read.

- **Tutorial** — a guided introduction, usually in `docs/tutorials/`. Teaches a
  person to get something done by following steps. Written for people new to a
  topic. Does not try to be comprehensive.

- **How-to guide** — instructional, for someone who already knows the basics.
  Lives in `docs/guides/` organised by audience. Answers "how do I do X?"

- **Reference** — a complete, comprehensive description: a specification, a
  schema, a configuration table, a script index, API documentation. Expected to
  be read selectively rather than end-to-end. Highest accuracy standard.

- **Explanation** — conceptual, why-focused. Lives in `docs/concepts/` and
  answers "why is it that way?" and "what is this for?" Helps readers
  understand the system. Does not give step-by-step instructions.

- **Records** — dated and point-in-time: audits, investigations, and snapshot
  reviews. Lives in `docs/records/` and `docs/reviews/`. Never updated after
  filing; new findings go in a new record. Exempt from the "as-built" rule:
  records describe what was true on one date, not what is true today. The fact
  of a dated review — that a review happened, what it found — is permanent and
  immutable (like a commit). The current state is in the as-built docs, not the
  record.

- **Decision log** — records open questions and the decisions made on them over
  time. `docs/ROADMAP.md` is a planning decision log (intent, open for revisions
  as decisions land). `docs/STANDING-DECISIONS.md` is an implementation
  decision log (settled decisions on recurring questions — a line is added
  when an escalation is answered and amended, dated, if the owner later
  changes their mind, but never deleted). Neither is as-built: a decision
  log is prescriptive, not descriptive.

### Audiences

This pipeline has six audiences. Each document has one primary audience (the
reader it is written for) and secondary audiences who may find it useful.

- **Person working in a target repository** — a developer, maintainer, or
  integrator using this pipeline on their own code. Wants to know: how do I set
  it up, run it, reserve work, understand what it did? Reads README, quick
  start, how-tos by their role, and pull request bodies.

- **Operator** — someone running an installation of this pipeline (often a
  platform team member or SRE, or an individual for a self-hosted instance).
  Wants installation and operation guides, configuration reference, monitoring
  and troubleshooting, planning (roadmap). Reads README § "Installation" /
  "Operation", `ROADMAP.md`, specs.

- **Evaluator** — someone deciding whether this product is a good fit: a
  security reviewer, an architecture reviewer, a potential customer evaluator.
  Wants to understand what it does, what decisions were made and why, the
  security model, any known risks. Reads `ROADMAP.md`, decision logs,
  specifications, security docs, audits.

- **Contributor** — someone writing code that changes the pipeline. Wants to
  know: what conventions do I follow? What are the specs I must keep up to
  date? What is out of scope? Reads `AGENTS.md`, `CONTRIBUTING.md`, the
  relevant specification, decision logs.

- **Agent in a cycle** — an LLM-based agent executing a pipeline stage. Needs
  precise instructions, all context required to complete the item, and the
  standard it must meet. Reads stage prompts (`prompts/*.md`), the relevant
  specification, issue bodies, pull request descriptions, test files.

- **Reader of the fleet's own output** — a human reading something an agent
  wrote: a PR, a commit message, a comment, a pull request description. Wants
  clarity on what the agent did and why. Reads PR bodies, commit messages,
  design decisions embedded in code comments.

### Placement

Each kind of document goes in a specific directory. The recommended structure is
below; this repository currently has documents scattered and this list reflects
where future documents should go (later issues may move existing ones).

```
README.md                          root landing page
docs/README.md                     this map and these conventions
docs/tutorials/                    guided introductions
docs/guides/                       how-to guides; subdirs by audience
  working-with-pullwright/         for people using this on their repos
  operating/                       for operators
  contributing/                    for contributors
docs/concepts/                     explanations: architecture, glossary, etc.
docs/reference/                    configuration, schemas, scripts, labels, reasons
docs/spec/                         as-built specifications
docs/records/                      dated audits, plans and investigations
docs/reviews/                      machine-written review reports (dated subdirs)
docs/ROADMAP.md                    planning decision log
docs/STANDING-DECISIONS.md         implementation decision log
```

### Front matter

Each hand-written document (not generated) may optionally carry a YAML front
matter block at the top, between `---` delimiters. This is optional; if present,
it must include these fields:

- `title` — the document's title (used by the site generator)
- `summary` — one-line summary of what the document answers
- `audience` — primary audience: one of the six kinds above
- `kind` — one of the six kinds above

Example:

```yaml
---
title: Installation Guide
summary: How to set up this pipeline on your infrastructure
audience: operator
kind: how-to
---

# Installation Guide
...
```

**Note on rendering:** GitHub renders YAML front matter as a metadata table at
the top of the rendered document. This is acceptable in this repository.

### Size budget

A document's hand-written content stays under 100 KB (~25,000 tokens). The
budget bounds what an author writes and maintains: prose kept small enough
for an agent to read in one API call without excessive context cost, and a
document that outgrows it is split.

Generated regions are left out of the measure. These are the regions
`lib/markdown-scan.sh` lists, which `scripts/render-toc.sh`,
`scripts/render-config-table.sh` and `Pullwright/.agent`'s sync rewrite
(AGENTS.md's "Generated regions" section): a configuration table and its
notes, a table of contents and a stamped region. Their size follows their
source (the schema, the headings, the shared fragments), not anything the
document's author can trim, so a budget on them could only block the change
that regenerates them; their source is where their size is kept in check. A
marker pair that nothing renders holds hand-written bytes like any other line.
So `docs/reference/configuration.md`, which is mostly the configuration tables
generated from `config.schema.json`, is measured by its prose alone, although
an agent that reads the whole file still reads its tables.

**Exemptions:**

- Generated files are exempt: `CHANGELOG.md` and all dated review reports under
  `docs/reviews/`.
- `docs/ROADMAP.md` (currently 118 KB) is also exempt as a decision log with
  historical weight.
- No as-built specification carries a blanket exemption: AGENTS.md's
  "As-built specifications" section requires each one to grow with every
  requirement-affecting change, so one that grows past the budget is split
  into a directory of files that are each within it (#2094) — the same
  regime every other document follows, a future addition that pushes one of
  those files over the budget fixed by splitting it further, never by
  exempting it.

**Current status.** Every other document over the budget is tracked in
`scripts/docs-size-ratchet.tsv`, each entry naming the most hand-written bytes
it may hold and the issue that will bring it under budget — checked in CI; see
"Checked in CI" below. An entry for a document that is missing, exempt or
back within the budget fails the check, as does an exemption that matches no
document, so the file holds the remaining debt and nothing else.

### Headings and anchors

Headings must be unique within a file so that GitHub's generated anchors stay
stable. For example, two `### Operate` headings produce anchors `#operate` and
`#operate-1` respectively; adding a third repoints both.

Anything cited in code, prompts, or other documents should have an explicit
anchor that does not change when the heading's wording does. This is not
yet systematically done in this repository and is left for a future
documentation sweep.

### How sections are cited

Sections are cited using the format: path + heading.

Example: "`docs/guides/operating/README.md` § \"Installation\"" or "`docs/spec/implementation/README.md` § \"What it is\"".

This format is:
- Machine-readable (path is filepath, heading is quoted)
- Human-readable (§ is visually distinctive)
- Resilient to heading rewording within a document (though rewording still
  breaks the citation)

Cited headings should remain stable over time. Where a heading must be
reworded, update all citations together.

### Checked in CI

`scripts/check-docs.sh` (`.github/workflows/docs.yml`) checks five of the
conventions above on every pull request: every relative link and `#fragment`
resolves (including every `x-docs` link in `config.schema.json`); every
in-scope document is named in this map, and every path this map names
exists; no in-scope document's hand-written content exceeds the size budget
unless the document is exempt or has a `scripts/docs-size-ratchet.tsv`
entry, and every entry there is one the check still reads; a quoted section
citation names a heading that exists; and a ratchet in
`scripts/docs-phrasing-ratchet.tsv` holds historical-sounding as-built
phrasing to its current count or lower.
It does not check spelling, grammar, external links, or requirement-label
citations.

### Line wrapping

Hand-written prose is wrapped at approximately 78 characters per line, matching
the current style. Tables and code blocks are exempt from this rule; generated
regions preserve their formatting.

### Product vs. installation boundary

**This rule is settled here in principle; issue #601 will classify each file.**

Two categories of documents exist: those describing **Pullwright** (the product)
and those describing **Poetic-Poems's installation** of it (configuration,
customization, deployment specifics).

**Product documents** describe features and behaviour common to all
installations — what Pullwright *is*, not what one particular installation
does with it.

**Installation documents** describe how Poetic-Poems runs the product —
configuration choices, how we've deployed it, what we've customised.

The boundary is necessary because the same repository serves both audiences,
and the documentations serve them best when they are separate. A person
evaluating Pullwright for their own use needs to know product-level decisions;
a person running Poetic-Poems's installation needs to know our configuration.

The rule: a document is a product document unless it is explicitly and
entirely about Poetic-Poems's installation of the pipeline. If a document
describes both, that is a signal to split it.

**This is a guide, not a hard enforcement.** The classification will be
formalized in issue #601; until then, use judgment.

## The map evolves

This map describes what exists today. Every pull request that moves, renames,
splits, or merges a document updates this map. When you create a new tracked
document, add it to the appropriate section with its audience, kind, and
summary — treated as code review just like the document itself.

Because every document edit touches its entry here, the map stays up to date by
construction. If you find it out of sync with the actual files, that is a bug:
file an issue or a PR to sync them.
