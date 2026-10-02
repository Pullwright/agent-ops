# Documentation

This is the map of all documentation in this repository, the conventions that
govern them, and a routing table to find answers to common questions.

## Quick routing

Here are the answers to the 25 most common questions. Each entry names the file
path and the heading that answers it.

| Question | Where to find it |
|----------|------------------|
| **I want to set up this pipeline to run** | `README.md` § "Installation" |
| **What does this pipeline actually do?** | `README.md` § "What it does" |
| **How do I run the pipeline one cycle by hand?** | `README.md` § "Operation" |
| **Where is the configuration schema documented?** | `README.md` § "Configuration" |
| **How do I reserve an issue so the pipeline doesn't touch it?** | `README.md` § "Reserving an issue for yourself" |
| **What does "merge autonomy" mean?** | `README.md` § "Merge autonomy" |
| **I want to understand the Implementer stage** | `docs/IMPLEMENTATION-PIPELINE-SPEC.md` § "Implementer" |
| **I want to understand the Reviewer stage** | `docs/REVIEW-PIPELINE-SPEC.md` § "Reviewer" |
| **What are the product decisions that shaped this?** | `docs/ROADMAP.md` § "Settled decisions" |
| **Where are the standing decisions recorded?** | `docs/STANDING-DECISIONS.md` |
| **What is the overall system architecture?** | `docs/IMPLEMENTATION-PIPELINE-SPEC.md` § "Architecture" |
| **How does the merge queue work?** | `docs/IMPLEMENTATION-PIPELINE-SPEC.md` § "The landing gate" |
| **Where do I find the branch workflow for this repo?** | `AGENTS.md` § "Branch workflow" |
| **How are tech-debt items tracked and resolved?** | `TECH-DEBT.md` |
| **How do I contribute to this repository?** | `CONTRIBUTING.md` |
| **What are the security considerations?** | `SECURITY.md` |
| **How does the repository-review pipeline work?** | `docs/REVIEW-PIPELINE-SPEC.md` |
| **What is the structure of a pipeline cycle?** | `docs/IMPLEMENTATION-PIPELINE-SPEC.md` § "The five stages" |
| **How do I look at the monitoring dashboard?** | `README.md` § "Monitoring" § "Dashboard" |
| **What has changed in recent versions?** | `CHANGELOG.md` |
| **Where are the generated configuration tables?** | `README.md` § "Configuration", `docs/IMPLEMENTATION-PIPELINE-SPEC.md` § "Configuration table", `docs/REVIEW-PIPELINE-SPEC.md` § "Configuration table" |
| **I want to understand the landing gate and autonomy levels** | `docs/IMPLEMENTATION-PIPELINE-SPEC.md` § "The landing gate" |
| **How does the Enabler stage work?** | `docs/IMPLEMENTATION-PIPELINE-SPEC.md` § "Enabler" |
| **Where can I see dated audits or investigations?** | `docs/reviews/` — each dated subdirectory |
| **What's the history of decisions made?** | `docs/ROADMAP.md` § "Settled decisions" or `docs/STANDING-DECISIONS.md` for open decisions |

## All documents

This section lists every tracked Markdown document in the repository, excluding
`test/fixtures/`, `tech-debt/` (frozen archive), and giving each dated review
set under `docs/reviews/` one entry for its directory.

### Root-level documents

| File | Audience | Kind | Purpose |
|------|----------|------|---------|
| `README.md` | operator, evaluator, person working in repo | tutorial, how-to | Landing page; how to install, operate, and understand the pipeline |
| `CONTRIBUTING.md` | contributor, person working in repo | how-to | Guidelines for contributing; pointers to detailed conventions |
| `AGENTS.md` | agent, person working in repo, contributor | reference, explanation | Conventions for the repository: branch workflow, commit messages, PR rules, tech-debt, generated regions, documentation principles |
| `CLAUDE.md` | agent | reference | Pointer to AGENTS.md (AGENTS.md imports it) |
| `TECH-DEBT.md` | person working in repo, contributor | reference | Tech-debt filing and resolution workflow |
| `SECURITY.md` | evaluator, operator | reference | Security considerations and policies |
| `CHANGELOG.md` | operator, person working in repo | record | Dated history of changes (generated from PR descriptions) |

### Documentation directory: `docs/`

#### Specifications (as-built)

| File | Audience | Kind | Purpose |
|------|----------|------|---------|
| `docs/IMPLEMENTATION-PIPELINE-SPEC.md` | agent, contributor, evaluator | reference | As-built specification of the implementation pipeline (5 stages, architecture, requirements) |
| `docs/REVIEW-PIPELINE-SPEC.md` | agent, contributor, evaluator | reference | As-built specification of the repository-review pipeline |
| `docs/MONITOR-PIPELINE-SPEC.md` | operator, evaluator | reference | As-built specification of the Pipeline Monitor |
| `docs/DASHBOARD-SPEC.md` | operator, evaluator | reference | As-built specification of the monitoring dashboard |

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
| `docs/STANDING-DECISIONS.md` | contributor, agent, person working in repo | decision log | Standing decisions on open questions (updated as decisions are made) |

#### Audits and investigations (records)

| File | Audience | Kind | Purpose |
|------|----------|------|---------|
| `docs/PHASE-1-POETIC-SPECIFICS-AUDIT.md` | evaluator, person working in repo | record | Point-in-time audit of Poetic-Poems-specific features (dated 2026) |
| `docs/VOCABULARY-SWEEP-679-AUDIT.md` | evaluator, contributor | record | Audit and cleanup of vocabulary inconsistencies (dated 2026) |
| `docs/PULLWRIGHT-DAY-ONE-AUTONOMY.md` | evaluator, contributor | record | Analysis of autonomy level on day one of product launch (dated 2026) |
| `docs/PULLWRIGHT-REHOMING.md` | operator, contributor | record | Runbook for moving the repository to the Pullwright organisation |

#### Dated reviews (generated records)

| Directory | Audience | Kind | Purpose |
|-----------|----------|------|---------|
| `docs/reviews/2026-08-07-pipeline-flow-review.md` | evaluator, person working in repo | record | Pipeline flow review findings (generated report) |
| `docs/reviews/2026-08-14-autonomy-investigation.md` | evaluator, person working in repo | record | Autonomy levels investigation (generated report) |
| `docs/reviews/2026-08-15-merge-autonomy-baseline.md` | evaluator, person working in repo | record | Merge autonomy baseline review (generated report) |
| `docs/reviews/2026-08-23-d18-stage-3-promotion.md` | evaluator, contributor | record | Review for D18 Stage 3 promotion (generated report) |
| `docs/reviews/2026-09-11-escalation-autonomy-review.md` | evaluator, person working in repo | record | Escalation autonomy review (generated report) |
| `docs/reviews/project-review-2026-08-23/` | evaluator, person working in repo, contributor | record | Full project review with summary, findings, recommendations, and improvement prompts (generated) |
| `docs/reviews/project-review-2026-08-31/` | evaluator, person working in repo, contributor | record | Full project review (generated) |
| `docs/reviews/project-review-2026-09-05/` | evaluator, person working in repo, contributor | record | Full project review (generated) |
| `docs/reviews/project-review-2026-09-21/` | evaluator, person working in repo, contributor | record | Full project review (generated) |
| `docs/reviews/project-review-2026-09-28/` | evaluator, person working in repo, contributor | record | Full project review (generated) |

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
  decision log (settled decisions on recurring questions — updated as new
  decisions are made, not as decisions change). Neither is as-built: a decision
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

Hand-written documents stay under 100 KB (~25,000 tokens), so that an agent can
read the entire document in one API call without excessive context cost.

**Exemptions:**

- Generated files are exempt: `CHANGELOG.md` and all dated review reports under
  `docs/reviews/`.
- `docs/ROADMAP.md` (currently 118 KB) is also exempt as a decision log with
  historical weight.

**Current status — files over budget:**

- `docs/IMPLEMENTATION-PIPELINE-SPEC.md` — 2.4 MB (required by its nature as
  the complete specification)
- `docs/DASHBOARD-SPEC.md` — 329 KB (required)
- `docs/REVIEW-PIPELINE-SPEC.md` — 105 KB (required)
- `README.md` — 235 KB (required; includes extensive configuration and
  operation guides)

All of these are specifications or generated content required to be complete,
which outweighs the size budget.

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

Example: "`README.md` § \"Installation\"" or "`docs/IMPLEMENTATION-PIPELINE-SPEC.md` § \"The five stages\"".

This format is:
- Machine-readable (path is filepath, heading is quoted)
- Human-readable (§ is visually distinctive)
- Resilient to heading rewording within a document (though rewording still
  breaks the citation)

Cited headings should remain stable over time. Where a heading must be
reworded, update all citations together.

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
