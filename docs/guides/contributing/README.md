# Contributing

A guide for anyone contributing to this repository — humans working locally, or agents preparing their first pull request. It covers the development loop, the as-built specifications that govern changes, documentation conventions, and what every pull request to this repository must carry.

For a map of all documentation and how to find answers, see `docs/README.md`.

<!-- toc:start -->
- [The development loop for a container fleet](#the-development-loop-for-a-container-fleet)
  - [Make a change](#make-a-change)
  - [Run the tests](#run-the-tests)
  - [Try the change on a real node](#try-the-change-on-a-real-node)
  - [Take one node out](#take-one-node-out)
  - [Know how a change propagates](#know-how-a-change-propagates)
- [The as-built rule in practice](#the-as-built-rule-in-practice)
  - [Which specification to edit](#which-specification-to-edit)
  - [How to find the governing requirement](#how-to-find-the-governing-requirement)
  - [How to resolve a citation](#how-to-resolve-a-citation)
  - [How to add a requirement](#how-to-add-a-requirement)
  - [How to bring in-flight work through a specification split](#how-to-bring-in-flight-work-through-a-specification-split)
- [Generated and stamped regions](#generated-and-stamped-regions)
  - [Configuration tables](#configuration-tables)
  - [Table of contents](#table-of-contents)
  - [Stamped regions](#stamped-regions)
  - [Labels table](#labels-table)
  - [Scripts index](#scripts-index)
- [Documentation workflow](#documentation-workflow)
  - [Where a new document goes](#where-a-new-document-goes)
  - [Size budget and checks](#size-budget-and-checks)
  - [Running the documentation benchmark](#running-the-documentation-benchmark)
- [What a pull request must carry](#what-a-pull-request-must-carry)
  - [Conventional Commits title](#conventional-commits-title)
  - [Changelog section](#changelog-section)
  - [Closing-keyword marker (for issue-sourced work)](#closing-keyword-marker-for-issue-sourced-work)
  - [Tech-debt record (if resolving a tech-debt issue)](#tech-debt-record-if-resolving-a-tech-debt-issue)
  - [Protected paths and cool-off](#protected-paths-and-cool-off)
  - [Every commit in Conventional Commits format](#every-commit-in-conventional-commits-format)
- [Branch workflow](#branch-workflow)
- [Development environment setup](#development-environment-setup)
  - [Running the tests](#running-the-tests)
  - [Measuring the documentation](#measuring-the-documentation)
  - [Trying a change on a real node before it merges](#trying-a-change-on-a-real-node-before-it-merges)
  - [Taking one node out while the rest keep working](#taking-one-node-out-while-the-rest-keep-working)
  - [How a change propagates — and what survives it](#how-a-change-propagates--and-what-survives-it)
<!-- toc:end -->

## The development loop for a container fleet

The image is the deployment, but it is never the workshop. Changes are made in an ordinary git checkout, land on `main` through a pull request, and reach the fleet as a freshly built image. Nothing is ever edited inside a running container — there is no useful way to: `/app` is baked in at build time, and the next image roll would discard the edit anyway.

### Make a change

Work in a dedicated fresh clone on a feature branch and open a pull request. With the container-based fleet, a checkout is purely a development artefact: no cron entry runs from it, so editing it cannot destabilise a running cycle.

### Run the tests

The unit tests are plain bash, no framework; each is self-contained and exits non-zero on the first failed assertion. Run them the way CI does:

```bash
./scripts/run-tests.sh                      # every test/*.test.sh
./scripts/run-tests.sh cycle-state doctor   # only those whose name matches
./scripts/run-tests.sh --list                # just the selected names, one per line
```

`--list` needs no Docker and starts no container — it applies the same filter to the host's own `test/*.test.sh` and prints the matching basenames, useful for splitting the suite into groups within a hard per-invocation ceiling.

That copies the working tree into a throwaway container and runs the suite there. The tests only *pass* in the environment CI uses, and the host's tools disagree enough for roughly nine test files to fail if run directly. Budget half an hour or more — CI runs the identical loop in about 20 minutes, and a developer host is usually slower.

### Try the change on a real node

Build the image from the checkout and point a stack at it — `AGENT_OPS_IMAGE` in `.env` exists for exactly this:

```bash
docker build -f deploy/docker/Dockerfile -t agent-ops .
# in the stack's .env:  AGENT_OPS_IMAGE=agent-ops
docker compose up -d
docker compose exec scheduler /app/agent-cycle.sh --dry-run
docker compose exec scheduler /app/agent-cycle.sh --once --repo poetic-fiddle
```

Do this on a scratch stack or a standby node, never the fleet's workhorse. A second stack on the same host needs its own `COMPOSE_PROJECT_NAME`, node name and token (see `deploy/docker/README.md`); `--dry-run` and `--once` run regardless of role, so the guinea-pig node can stay `standby` throughout.

### Take one node out

Yes — role and lifecycle are per-node, and so is `--disable --this-node`, the graceful way to stand one node down:

```bash
docker compose exec scheduler /app/agent-cycle.sh --disable "editing lib/" --this-node --for 2h
# ... work on that node ...
docker compose exec scheduler /app/agent-cycle.sh --enable --this-node
```

`--this-node` writes only that node's own disabled state and never touches the fleet-wide flag.

### Know how a change propagates

Because every merge to `main` that touches anything the container reads builds and publishes a new image, and every node on the `auto-update` profile restarts into it within watchtower's poll interval (about five minutes), rollout is where the care has moved.

For a change that touches cycle state, claims, or the state-sync format, stand the fleet down first, merge, watch the roll, then resume:

```bash
docker compose exec scheduler /app/agent-cycle.sh --disable "rolling out PR #NN"
# merge; watchtower rolls every auto-update node onto the new image
docker compose exec scheduler /app/agent-cycle.sh --enable
```

Containers are disposable and, in effect, immutable: an update is the destruction of the old container and the creation of a new one from the new image. What carries across every roll:

- **The node's `.env`** — a file on the host, outside Docker. The GitHub PAT is injected from it into each new container at start.
- **The `claude-config` volume** — Claude's OAuth credentials, which refresh themselves in place. A manual `docker compose exec scheduler claude` login is once per *node*, not per container.
- **The `grok-config` volume** — the xAI counterpart, for the same reason.
- **The `state` and `workspaces` volumes** — the pipelines' memory and any in-progress clone.

What does *not* carry across is the container's writable layer, and nothing in it is meant to: every process removes its own temporary files on exit.

## The as-built rule in practice

This repository follows the as-built specification rule: a change that alters what a component does, requires, or produces must land in the same pull request as the spec edit that keeps its document accurate. Here is how to apply that rule.

### Which specification to edit

Each pipeline component has a numbered, requirement-based specification that describes it as-built:

- **Implementation pipeline** (`agent-cycle.sh`, `lib/`, `scripts/`, stage prompts): `docs/spec/implementation/README.md` and its numbered requirements
- **Repository-review pipeline** (`review-cycle.sh`, prompts): `docs/spec/review/README.md`
- **Pipeline Monitor** (`monitor-cycle.sh`, `lib/monitor-digest.sh`, prompts): `docs/spec/monitor.md`
- **Monitoring dashboard** (`scripts/publish-dashboard.sh`, `dashboard/index.html`): `docs/spec/dashboard/README.md` and its numbered requirements

A change to behaviour, requirements, or outputs must update the matching spec first. The specs outrank the operating prompts: `prompts/*.md` implement the specs' requirements, so bring the spec in line first, then the affected prompt(s).

### How to find the governing requirement

The specifications are split across multiple readable files, each with numbered requirements and acceptance checks. When making a change:

1. Read the spec's `README.md` for an overview and directory structure
2. Use `grep` to find the requirement that governs the behaviour you are changing
3. Update the requirement's text and any acceptance checks anchored to it
4. Then update the affected code/prompts to match the new spec

For example, if changing how claims expire, find and read `docs/spec/implementation/requirements/` files; grep for `claim_ttl` or `expir`; update that requirement; then update the code.

### How to resolve a citation

A citation names a specific requirement, acceptance check or component — a bare `requirement 17a`, or a qualified form naming which specification and sequence it belongs to (`IMPL AC 1g`, `REV R5`, `MON M4`; see `docs/README.md` § "Requirement-label citations" for the full grammar). Run `scripts/spec.sh show <label>` rather than opening and searching the spec file by hand: it prints the entry's own text, its anchor, and every file that cites it, from the committed `docs/spec/index.json`. `scripts/spec.sh check` is the permanent CI guard against a citation that collides, dangles, or names the wrong one of the three sequences.

### How to add a requirement

When adding new behaviour, add a new numbered requirement to the appropriate spec:

1. Read the spec file's heading to understand the item numbering — it carries a heading like `### Requirements — continued (part N of M; items X–Y)` that tells you the range
2. Add the new requirement after the last in that file, with its own `<a id>` anchor and a label `scripts/spec.sh check` confirms is unique within its sequence
3. If the file is full (nearing the size budget documented in `AGENTS.md`), start a new file at the next unused number
4. Add a matching acceptance check in `acceptance-checks/`, using the same numbering and the same anchor convention
5. Update the spec's `README.md` table of contents, and `docs/README.md`'s file-by-file listing
6. Update the code/prompts to implement the new requirement

Requirements state only what is, never an earlier state or what is planned; history and rationale belong in the specs' design-decision and gotcha sections. A parenthetical or subordinate aside inside a requirement may cite an earlier state when that explains what is, provided deleting the aside leaves a complete and correct statement of the current system; an aside the requirement cannot stand without is history in the assertion, and belongs in the design-decision or gotcha section instead. If you find a spec and the code disagreeing, that is a bug: fix whichever is wrong rather than working around the mismatch.

### How to bring in-flight work through a specification split

If you opened a branch before #2094 landed (the spec-split pull request), and your branch's diff touches the old monolithic `docs/IMPLEMENTATION-PIPELINE-SPEC.md` or `docs/DASHBOARD-SPEC.md`, a rebase will conflict as a modify/delete. Resolve it by running the split script from #2094's description on your own modified version of the old file, then take the result — this carries your edits into whichever new file now holds the section you touched, rather than losing them to the delete side.

## Generated and stamped regions

Some parts of the documentation are generated or stamped, and must never be hand-edited.

### Configuration tables

`docs/reference/configuration.md` and the spec files have configuration tables in `<!-- config-table:start … -->` … `<!-- config-table:end -->` regions, generated from `config.schema.json` by `scripts/render-config-table.sh`. Never hand-edit a row inside these regions.

To make a change to a configuration entry:

1. Edit the key's `description`, `x-docs.readme`, `x-docs.spec` or `x-docs.value` in `config.schema.json`
2. Run `scripts/render-config-table.sh` (no arguments) to regenerate every region
3. Run `scripts/render-config-table.sh --check` before you push — CI runs the same check

### Table of contents

Each guide under `docs/guides/` has a table of contents between `<!-- toc:start -->` and `<!-- toc:end -->` markers, extracted from its own `##` and `###` headings. The spec `README.md` files carry a directory-wide table of contents listing every sibling file. These are generated by `scripts/render-toc.sh` from heading text.

Never hand-edit content between these markers:

1. Edit headings instead
2. Run `scripts/render-toc.sh` (no arguments) to regenerate
3. Run `scripts/render-toc.sh --check` before you push

### Stamped regions

Three `<!-- agent-info:start fragment=... -->` regions in `AGENTS.md` carry text stamped from the organisation's `.agent` repository. Never hand-edit inside them — change the fragment there, then re-stamp.

### Labels table

`docs/reference/labels.md` has a labels table in a `<!-- labels-table:start -->` … `<!-- labels-table:end -->` region, generated from `lib/labels.sh`'s own catalogue (`labels_catalogue`) by `scripts/render-labels-table.sh`. Never hand-edit a row inside this region.

To make a change to a label:

1. Edit the catalogue entry in `lib/labels.sh` (name, colour, description), and — for what applies it and what removing it does — the matching entry in `scripts/render-labels-table.sh`'s own `METADATA_JSON`
2. Run `scripts/render-labels-table.sh` (no arguments) to regenerate
3. Run `scripts/render-labels-table.sh --check` before you push — CI runs the same check

### Scripts index

`docs/reference/scripts.md` has an index of every script under `lib/` and `scripts/` in a `<!-- scripts-index:start -->` … `<!-- scripts-index:end -->` region, generated from each script's own header-comment first paragraph by `scripts/render-scripts-index.sh`. Never hand-edit a row inside this region.

To make a change to an entry:

1. Edit the script's own header comment
2. Run `scripts/render-scripts-index.sh` (no arguments) to regenerate
3. Run `scripts/render-scripts-index.sh --check` before you push — CI runs the same check

## Documentation workflow

### Where a new document goes

- **A guide (how-to, tutorial):** `docs/guides/<topic>/README.md` or `docs/guides/<topic>/<page>.md`
- **A specification (as-built requirement, acceptance checks):** `docs/spec/implementation/` or `docs/spec/dashboard/`, organized into `requirements/`, `components/`, `acceptance-checks/`
- **A reference document (configuration, glossary):** `docs/reference/`
- **A concept/explanation:** `docs/concepts/`

Each has a size budget to keep documents readable. See `docs/README.md` § "Size budget".

### Size budget and checks

The documentation size budget is enforced by `scripts/check-docs.sh`. It is a
single uniform 100,000 hand-written bytes per document (`SIZE_BUDGET_BYTES`
in that script; see `docs/README.md` § "Size budget" for the full rule,
including which regions are generated and so left out of the count, and the
exemptions) — there is no line count and no per-category tier.

Run `scripts/check-docs.sh` before pushing. CI runs the same check on every PR.

`docs/` is also published as a static site — `site/` (Astro + Starlight) holds
the whole toolchain, and `site/scripts/sync-docs.mjs` regenerates its content
collection from the real files on every build, so the repository's own
Markdown stays the single source and nothing under `site/src/content/docs/` is
committed. `.github/workflows/docs-site.yml` builds the site on every pull
request, failing it on a broken internal link, and deploys it to
`https://pullwright.github.io/agent-ops/` from `main`. To reproduce that build:

```bash
cd site && npm ci && npm run build
```

It needs the clone's full history, because each page's last-updated date is
read from it — `sync-docs.mjs` refuses a shallow clone rather than stamping
every page with the build's own date.

If a file grows past the budget, split it at the next unused number in its directory — e.g. if `01`–`06` exist, create `07`. Never rename or renumber existing files when splitting.

### Running the documentation benchmark

The documentation has a benchmark (`scripts/docs-benchmark.sh`) that scores it against real reader questions. Run it to measure whether your documentation changes make the docs more or less helpful:

```bash
scripts/docs-benchmark.sh --dry-run            # list each question and its commands
scripts/docs-benchmark.sh --check              # check the questions and follow every source
scripts/docs-benchmark.sh --calibrate          # grade each gold answer against its facts
scripts/docs-benchmark.sh --only contributor-01 # one question, against main
scripts/docs-benchmark.sh main                 # every question, against main
```

The full run spends tokens (budget for it), and the report is written to `docs/reviews/<date>-docs-benchmark.md`. Never run the benchmark from a pipeline stage — agents do not launch other agents.

## What a pull request must carry

### Conventional Commits title

PR titles must follow [Conventional Commits](https://www.conventionalcommits.org/) format: `<type>[(scope)]: <description>`. The PR title becomes the squash commit on `main`, so make it accurate and complete now.

Allowed types: `build`, `chore`, `ci`, `docs`, `feat`, `fix`, `perf`, `refactor`, `revert`, `style`, `test`.

Example: `docs(guides): rewrite the contributor guide`

CI enforces this format on both the PR title and every commit on the branch.

### Changelog section

Add a `## Changelog` heading in the PR body with one or more of these sub-headings:

- `### Added` — new features or content
- `### Changed` — changes to existing features or content
- `### Deprecated` — features marked for removal
- `### Removed` — removed features
- `### Fixed` — bug fixes
- `### Security` — security fixes

Each sub-heading contains bullet points written for the changelog audience (operators and users of the system).

A change that is not notable (routine, doc-only) says `None.` under the same heading, so the omission is visibly deliberate.

A `feat`, `fix`, `perf` title, or a breaking change marker (`!`), must carry the section — the check fails without it.

The squash merge carries the description onto `main` as the commit message. The release process assembles `CHANGELOG.md` from merged PR descriptions.

### Closing-keyword marker (for issue-sourced work)

If your branch is named `agent/<n>` (where `<n>` is an issue number), add this marker to the PR body to confirm it closes that issue:

```
<!-- agent-ops:closes-issue item=<n> -->
```

And add a real GitHub closing keyword in the body:

```
Closes #<n>
```

CI checks that both are present and that `<n>` matches.

### Tech-debt record (if resolving a tech-debt issue)

If your pull request resolves a `pw::type:tech-debt` labelled issue, add a fenced `td-record` block in the PR body:

```
td-record
issue: <n>
title: "<the issue's own title, verbatim>"
filed: <YYYY-MM-DD of issue creation>
summary: "<what the debt was>"
resolution: "<what this PR did about it>"
```

All five fields are required, in this order. The squash commit carries this record into `main`'s history as a permanent entry.

If the issue's body says "Filed as `tech-debt/<id>.md`, <date>.", that file exists in the frozen register. This PR must also flip its frontmatter to a terminal status — `status: resolved`, or `status: not-debt` if the resolution concludes the item was never debt — with `resolved:` and `ref:` fields filled in, as `TECH-DEBT.md` describes.

### Protected paths and cool-off

`AGENTS.md` is a protected path in this repository. Below `merge_autonomy:
agent-merges-all`, a protected-path pull request is simply ineligible for
autonomous landing. At `agent-merges-all` — the level this repository's own
`config.json` entry sets — a protected-path hit is instead deferred to two
compensating controls, neither of which is a human review:

- **Critical-tier review** — a model verdict at the critical Approver tier,
  posted by the Pullwright Approver App, forced regardless of the PR's
  `complexity:*` grade.
- **Cool-off** — a wait, measured from that standing approval, before the
  arming step may land it; a fresh push restarts the wait. This repository's
  own `config.json` entry sets it to 6 hours (`landing_cool_off_hours`); the
  fleet-wide default, which applies to a repository with no override, is 24
  hours, and `0` disables the wait.

The full list of protected path prefixes is the `merge_autonomy_protected_paths` key in `config.schema.json` — a fleet-wide default of nine paths, scoped to agent-ops's own gate code. This repository's `config.json` entry overrides that default with its own list, which is where `AGENTS.md` (along with `CLAUDE.md`, `scripts/*`, `.claude/*` and `docs/STANDING-DECISIONS.md`) is actually added — check that entry, not the schema default, for the list that governs this repository.

### Every commit in Conventional Commits format

Not just the PR title — every individual commit on your branch must also follow the format. CI checks all of them.

## Branch workflow

This repository follows the same conventions as its target repositories:

- **`main` is protected** — no direct commits. All changes go through pull requests.
- **PR titles use Conventional Commits format** — `<type>[(scope)]: <description>` (see "What a pull request must carry" above).
- **`AGENTS.md` binds all work in this repository** — the rules for branches, commits, tech-debt, generated regions, and documentation all live there. `CLAUDE.md` imports it; they are two halves of the same system.

## Development environment setup

### Running the tests

The tests only *pass* in the environment CI uses. Some key traps:

- **Straight from the checkout** — the host's `jq` version may differ from CI's. `jq` 1.6 and 1.7 disagree enough for roughly nine test files to fail, with no mention of `jq` in the error.
- **Via `docker exec` into a running node** — that container's `/app` is whatever it was last built from, not your working tree, so a fix here is invisible to a suite run there. Use `docker run` instead, which copies the working tree in fresh.
- **A new assertion that silently asserts nothing looks exactly like a pass.** To see per-assertion detail, run the file alone inside a container from the image, then revert the fix and confirm the assertion fails.
- **`shellcheck` is pinned to v0.11.0 in CI**, while a developer host commonly has 0.8.0, which misses findings CI will fail on (e.g., SC2317 on a stub function called only from an `eval`ed block). Run `./scripts/lint-shell.sh` inside a container from the image before pushing.

To test against a locally built image instead of `ghcr.io`'s latest:

```bash
docker build -f deploy/docker/Dockerfile -t agent-ops:dev .
AGENT_OPS_TEST_IMAGE=agent-ops:dev ./scripts/run-tests.sh
```

CI runs the same suite inside the freshly built image on every push that could change it, along with toolchain, crontab and role-guard checks (see `.github/workflows/build-image.yml`). A change confined to documentation builds no image and runs no suite; a change confined to paths the image delivers but no test reads — `docs/STANDING-DECISIONS.md` alone today, optionally beside inert documentation — builds, verifies and publishes an image but runs no suite; anything else does both, including `prompts/*.md`, since those are what the pipeline feeds to `claude`.

To check whether your branch will trigger an image build, and whether it will run the suite:

```bash
git diff --no-renames --name-only main...HEAD | ./scripts/is-docs-only.sh
git diff --no-renames --name-only main...HEAD | ./scripts/is-docs-only.sh --skip-suite-only
```

### Measuring the documentation

`scripts/docs-benchmark.sh` scores the documentation against a fixed set of
real questions. `test/docs-benchmark/questions.jsonl` holds at least 48, each
asked the way one of six readers would ask it (someone working in a target
repository, an operator, an engineer evaluating the product, a contributor, an
agent working a cycle here, and someone reading the fleet's own output), with a
gold answer, the documents that state it and the facts a correct answer must
contain. It exists so that a change to the documentation is measured rather
than asserted: run it on `main` before a restructure and again afterwards, and
compare how many questions each reader gets right and how many tool calls,
tokens and seconds each answer took.

```bash
scripts/docs-benchmark.sh --dry-run            # list each question and its commands; launch nothing
scripts/docs-benchmark.sh --check              # check the questions and follow every source they cite
scripts/docs-benchmark.sh --calibrate          # grade each gold answer against its own facts
scripts/docs-benchmark.sh --only operator-01   # one question, against main
scripts/docs-benchmark.sh main                 # every question, against main
```

Each question is answered by headless Claude Code in a plain directory
holding the ref's files, without the benchmark's own files and without
`.git`, with a fixed model at a fixed effort and only the Read, Grep and Glob
tools; a second call grades the answer fact by fact. A full run's report is
written to `docs/reviews/<date>-docs-benchmark.md`, with the raw records
beside it (a second full run on the same day takes the suffix `-2`), and a
one-question run's to `<date>-docs-benchmark-only-<id>.md`. The run prints
its working directory when it starts, and Ctrl-C stops it, with the question
in flight, saying how to render what it has recorded. Every run spends
tokens, so nothing runs the benchmark automatically — not CI, not the
crontab, and never a pipeline stage, where launching `claude` would be an
agent launching an agent. Run it by hand or from an interactive session.

The report's header carries the hash of the protocol (the definitions that
decide what the figures mean, which `lib/docs-benchmark.sh` names), the hash
of what a run reads of the questions, and the Claude Code version, and two
reports are comparable when all three match. A new Claude Code release does
not strand a baseline: any ref can be measured with today's questions, so
run the old ref again beside the new one.

When a document moves, the `docs-benchmark sources` check fails on that pull
request until the questions' `sources` follow it; moving a source does not
change the questions' hash. When the product changes so that a gold answer
is no longer true, correct the question in the same pull request, and run
`--calibrate` after any edit to the questions: a question whose own gold
answer fails it would lower every score for a reason that has nothing to do
with the documentation. Never edit a document to make a question easier to
answer.

### Trying a change on a real node before it merges

See "[Try the change on a real node](#try-the-change-on-a-real-node)" above for the basic steps. To mock a usage-limit event for testing the cooldown, from a shell on that node (`docker compose exec scheduler bash`):

```bash
jq -n '{ts: now | todate, cycle: "manual", event: "limit-hit", resume_at: (now + 7200 | todate), detail: "test injection"}' >> ~/.local/state/poetic-agents/log.jsonl
```

### Taking one node out while the rest keep working

See "[Take one node out](#take-one-node-out)" above for the basic `--disable --this-node` workflow. For other scenarios:

- **Stop it indefinitely with no switch and no expiry**: set `ROLE=standby` in its `.env`, then `docker compose up -d`. Promoting it back is the same one variable.
- **Stop it entirely**: `docker compose stop scheduler`, or `docker compose down` (which keeps the volumes). The rest of the fleet carries on; per-item claims mean no other node was depending on this one.
- **Hold it on a known image** while the rest follow `latest`: pin `AGENT_OPS_IMAGE=ghcr.io/pullwright/agent-ops:<sha>` in its `.env`.

For removing a node for good, see [Remove a node for good](../operating/change-a-node.md#remove-a-node-for-good).

One caution before any *manual* `docker compose up -d` on a live node: after a watchtower roll, compose's recorded config-hash no longer matches, so `up -d` recreates the scheduler even when nothing in the compose file changed — killing a running cycle. The pre-update hook cannot save you here: it is watchtower that consults it, and a hand-typed `up -d` asks nobody. Run `--status` first and let a cycle in flight finish.

### How a change propagates — and what survives it

See "[Know how a change propagates](#know-how-a-change-propagates)" above for an overview. The volumes that persist across image rolls are the node's `.env` file (on the host), `claude-config`, `grok-config`, and `state`/`workspaces`. Nothing in the container's writable layer is meant to persist — every process removes its own temporary files on exit.
