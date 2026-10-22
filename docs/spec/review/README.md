# Repository-Review Pipeline — as-built specification

Split from a single file by #2608 so every part is within the 100,000-byte documentation size budget (`docs/README.md` "Size budget").

<!-- toc:start -->
- [Requirements](requirements.md)
- [Components](components.md)
- [Acceptance checks](acceptance-checks.md)
<!-- toc:end -->

## About this document

This is the as-built requirements specification for the repository-review
pipeline — named for what each run does: one repository, on its own, with
its own clone, branch, report set and pull request. It is a companion to
`docs/spec/implementation/README.md` (the implementation pipeline)
and `docs/spec/dashboard/README.md` (the monitoring dashboard), and like them it
describes the system as it exists — any change to this pipeline lands
together with the edit that keeps this document accurate (see `AGENTS.md`,
"As-built specifications").

**Where this document is silent, follow `docs/spec/implementation/README.md`.** The two
pipelines deliberately share their machinery — the lock discipline, the
minimal-`PATH` bootstrap for cron, usage-limit detection (`lib/limit-detect.sh`),
the JSON-Lines log format and `log_event` helper, the ephemeral-clone rule,
the stage launcher with its per-stage timeout, process-group kill and event
stream (`lib/stage-run.sh`'s `run_model_stage`), and the
"straight-parse-else-last-fenced-```json```-block" result parser. This
pipeline **reuses** those, and must not reinvent them. References of the form
"requirement N" mean requirement N of `docs/spec/implementation/README.md`. The target
repositories' `AGENTS.md` files — or `CLAUDE.md`, for a repository that has
not migrated — remain binding on any agent working inside them.

## What it is

A second, independent pipeline that runs alongside the implementation
pipeline, on its own configured cadence
(`repository_review.defaults.min_days_between_reviews`). For each run it takes
one target repository and produces a full project review — via the vendored
`project-review` skill — against a fresh ephemeral clone, and leaves **one**
mergeable pull request carrying the review reports. Debt the review surfaces
is filed straight to GitHub as `pw::type:tech-debt`-labelled issues as the
review runs (R12), named under the pull request's `Defers:` section rather
than committed alongside it. A human merges the pull request. The filed
issues and the review's improvement prompts then feed the implementation
pipeline (and/or the `project-remediation` skill). The only human
involvement is merging the review pull request.

```
cron (repository_review.defaults.min_days_between_reviews; a daily tick with a
       skip-guard is recommended — see R4)
  └─ review-cycle.sh                  ← the Review Script: lock, stand-down, per-repo skip-guard
       └─ for each target repo, sequentially:
            ├─ ephemeral clone            ← fresh from GitHub, under workspace_root
            ├─ inject the vendored skill  ← into the clone, git-excluded (never committed)
            └─ Reviewer-Agent (Sonnet)    ← runs the skill, raises ONE review PR (ready)
                  └─ Human                ← reviews and merges (the only gate)
                        └─ feeds → implementation pipeline / project-remediation
```

## Relationship to the existing pipelines

- **Separate everything that must be separate:** its own Script
  (`review-cycle.sh`), its own cron entry, its own lock (`review-lock.json`),
  its own PR label (`project-review`). **Shared where sharing is correct:**
  `config.json`, `state_dir`, `workspace_root`, `lib/limit-detect.sh`,
  `lib/git-identity.sh`, the ephemeral-clone discipline, the `PATH`
  bootstrap, the `gh` transport shim that bootstrap resolves
  (`docs/spec/implementation/requirements/the-script-02.md`'s requirement 2.0e — `review-cycle.sh`
  exports `PW_GH_STATE_DIR` once it resolves `state_dir`, so the shim finds
  this node's own state from every subprocess the review cycle forks,
  including its model-driven stage), and the result parser.
- **The review pipeline defers to the implementation pipeline.** If the
  implementation lock (`lock.json`) is held by a live process, the Review
  Script stands down and waits for the next tick — two heavy `claude` runs
  should not overlap, because they draw on the same subscription quota. This
  requires **no change to `agent-cycle.sh`**; the deference is entirely on the
  review side.
- **One shared quota signal.** A `limit-hit` event (requirement 10) is written
  to the *shared* `log.jsonl` with the *same* shape, so a usage-limit hit in
  either pipeline stands **both** down, and the dashboard shows it. The one
  other event that crosses over is `clone-footprint`, which the implementation
  pipeline's own pre-clone free-space gate reads back (requirement 2.0c of
  `docs/spec/implementation/README.md`). Every other review event goes to the
  review pipeline's own stream (R16), so the dashboard's existing `log.jsonl`
  parser is unaffected.

## Actors

1. The **Review Cronjob** — the crontab entry that fires the Review Script.
2. The **Review Script** (`review-cycle.sh`) — a bash script that orchestrates
   one run across the target repositories, on its own configured cadence
   (`repository_review.defaults.min_days_between_reviews`). It launches the
   Reviewer-Agent; agents never launch the Script.
3. The **Reviewer-Agent** — a headless Claude Code invocation that runs the
   `project-review` skill against one ephemeral clone and raises one review
   pull request. One invocation per repository. It writes no comments today, so
   it stamps none of `docs/spec/implementation/README.md`'s requirement 9d
   headers itself; `dashboard/index.html`'s `ACTOR` map and
   `lib/pipeline-marker.sh`'s `pipeline_actor_label` both carry an entry for it
   anyway, under the token `project-reviewer` and the display name **Project
   Reviewer** — the name this document's own Actor entry differs from, kept
   here as *Reviewer-Agent* since that is what the rest of this document calls
   it throughout.
4. The **Human Reviewer** — merges the review pull request through the ordinary
   GitHub process, and decides how to action its recommendations. Not launched
   by any part of this system.

## Environment

Identical to `docs/spec/implementation/README.md` ("Environment" and "Target
repositories"); not repeated here. The target repositories are the same as
that document's, currently `Poetic-Poems/poetic`, `Poetic-Poems/poetic-fiddle`,
and `Pullwright/agent-ops`, and their shared conventions (protected `main`,
squash-merge so the PR title becomes the commit, Conventional Commits) bind
the Reviewer-Agent exactly as they bind the Implementer. Where a configured
repository still carries a per-item tech-debt register (`tech-debt/`), that
register is a frozen archive: no ID is allocated into it and no file is added
to it. The Reviewer-Agent only ever
reads it, to update an item it finds already resolved (R12) — new debt this
review surfaces is filed as a labelled GitHub issue instead, never into that
register.

One repository-specific fact worth noting: `poetic` already stores prior
reviews under `reviews/project-review-YYYY-MM-DD/`; `poetic-fiddle` does not
yet have a `reviews/` folder, and the skill will create one on its first run.

## The `project-review` skill (vendored)

The skill is **vendored** into this repository at
`.claude/skills/project-review/` — a pinned copy of the upstream skill at
`skills/project-review/` in `warwickallen/claude-skills` (upstream commit
`981af30`, vendored 2026-10-17), plus one local change upstream does
not carry: new tech debt is filed as `pw::type:tech-debt` issues (R12, with
R12a's cross-reference to the recommendation it mirrors), with a fallback
for an unreachable tracker and, for a missing label, the handling that
standing decision #942 sets (create the label or, if that fails, file
unlabelled and name the remedy), wherever `SKILL.md` and
`references/output-templates.md` describe filing it (#919, #1937, #2464).
That change is this product's policy (D15), not the general skill's. It is
exactly what `diff -r` between this copy and upstream at the pinned commit
shows, ignoring `evals/`, so a re-sync carries that difference onto
upstream's newer commit, and the same `diff -r` against the new commit
then shows nothing else. Only the runtime surface is vendored: `SKILL.md`
and `references/` (the four reference documents the skill reads); the
upstream `evals/` directory is dev-only and is intentionally omitted.

Two decisions are deliberate:

- **Vendored, not relied on ambient.** A machine's globally available
  `project-review` skill, wherever it comes from (a clone of
  `warwickallen/claude-skills`, a link into one, or an account-synced copy),
  is machine state outside this repository's version control. Vendoring a
  pinned copy makes the pipeline reproducible from `agent-ops` alone and
  immune to upstream, or a machine's copy of it, changing under it. Re-sync
  the copy deliberately when you want a newer skill; treat upstream as the
  source and this copy as a pinned deployment, exactly as `poetic` vendors
  framework files into consumer repos.
- **In the orchestrator, not the product repos.** The review runs in an
  *ephemeral clone* of each product repo (the pipeline never touches the
  working copies under `~/Code`, and `main` is protected). So the skill must
  live with the orchestrator and be **staged into the clone at runtime**
  (R5b). Keeping it here — rather than committing it into `poetic` and
  `poetic-fiddle` — keeps the product repos clean, keeps the skill out of its
  own review's scope, and avoids opening a pull request into two protected
  product repositories merely to enable this pipeline.

## Configuration

One `repository_review` object in the existing `config.json` (one config file —
never a second one) holds every tunable for this pipeline, in two parts
(issue #342): `defaults` — every tunable set once, installation-wide —
and `repos` — the repositories to review, each a `{"slug": "owner/name"}`
entry that may additionally carry any of `defaults`' own keys to override it
for that repository alone. The resolution rule is uniform: for repository *r*
and key *k*, the effective value is `repos[i][k]` when that key is present and
non-null on *r*'s own entry, and `defaults[k]` otherwise; an entry carrying
only `slug` inherits every default. `lock_stale_after` sits outside `defaults`
— it bounds the shared review lock, which covers whichever repositories a run
touches, not any one repository, so it has no per-repo override.

**`project_review` is a deprecated alias for `repository_review`**
(agent-ops#592, D7): the two are the identical shape, and `config_defaults`
resolves either spelling into `.repository_review` before any stage reads it,
so nothing downstream of that merge ever has to know the old spelling exists.
Setting both in the same `config.json` is a configuration error —
`config_schema_errors` refuses it, naming both keys — rather than a silent
precedence, since resolving one of two present keys by precedence is exactly
the quiet failure `config.schema.json`'s own validator exists to catch.
`scripts/doctor.sh` warns when `project_review` is the only one set, naming
`repository_review` as the replacement. There is no calendar-based
deprecation window for the old spelling: this installation has no release
train to express one in (`config.json` ships inside the image, so a node
never runs new code against an old config file of its own), and the only
compatibility window that genuinely exists is the fleet roll — **the old
spelling stops being accepted once every node in the fleet reports an image
containing the rename.**

### Review instructions and context

Three further keys, resolved on the same requirement-342 rule as every other
`defaults`/`repos[]` pair, give a review its repository's own instructions and
context (R1c, R5 step 2a; issue #589, D7 in `docs/ROADMAP.md`): what to weigh,
what to ignore, which standards apply, what the repository is for, its
domain, its relationships to other repositories, its consumers and
deployment. Before this, the Reviewer-Agent had only five facts
(`repo`, `default_branch`, `review_date`, `branch`, `pr_label`) plus the
shipped prompt and skill, identical for every repository — an installation
reviewing several repositories against different standards, or wanting a
generated or vendored directory held out of scope, had nowhere to say so
short of forking the skill.

**The decision, and the reasoning (D7's open question, now closed):** both
layered, **configuration winning**, with repository-held text admissible as
*context* only — never as *instruction*. `review_instructions` and
`review_context` hold installation-supplied text, resolved from `state_dir`
exactly like `prompt_overrides`' `extend` (requirement 4a); `repo_context_file`
additionally admits one file read from the repository under review's own
clone, but only into `context`. The reasoning is D19's: text a reviewed
repository's contributors can edit is trustworthy only as far as a pull
request into that repository is, so anything that changes how *strictly* a
review judges — instruction — must live in the installation's own
configuration, never in the repository being judged; a repository may still
describe *itself* (D20's rule that a repository holds its own data), and
that description reaches the Reviewer-Agent as attributed data, labelled
`source: "repository"`, never as an unattributed instruction
(`prompts/project-reviewer.md`'s own "Untrusted external content" section
states this boundary for the agent). Unlike a `prompt_overrides` path, which
a stage silently runs without when it does not resolve, a configured
`review_instructions`/`review_context` path that does not resolve is a
fail-fast config error (R1c) at cycle start and at `scripts/doctor.sh`,
because this text changes a review's verdict rather than a stage's general
guidance; `repo_context_file` is the opposite — legitimately absent for a
repository that has not opted in, so a missing file there is simply absent,
never a fault.

```json
"repository_review": {
  "defaults": {
    "review_instructions": ["review-instructions/poetic-fiddle.md"],
    "review_context": ["review-context/poetic-suite.md"],
    "repo_context_file": ".github/REVIEW-CONTEXT.md"
  }
}
```

Delivery: `review-cycle.sh` resolves every source for the repository about to
be reviewed and appends two fields to the Reviewer-Agent's runtime input
(R5 step 2a) — `instructions` and `context`, each an array of `{source,
origin, text, truncated, bytes, digest}` objects, `source` one of `"config"`
or `"repository"` and `origin` the configured or repository-relative path the
text came from. Each source is capped at a fixed size
(`REVIEW_CONTEXT_SOURCE_MAX_BYTES`, `lib/review-context.sh`), with `truncated`
set rather than the text silently trimmed without saying so. The
`review-stage-start` event (R7b) names every resolved source alongside a
sha256 digest of the text actually sent — `lib/review-context.sh`'s
`review_context_sources_digest` — so a past review's inputs are
reconstructable without the log carrying arbitrary file content.

The values below are the confirmed defaults; `docs/reference/configuration.md`
documents each key, and
`config.schema.json` carries them alongside the implementation pipeline's
(`docs/spec/implementation/requirements` requirement 1b) — one file, one
schema, so `scripts/doctor.sh` checks both pipelines' configuration in one
pass and neither half can drift while the other is checked. The object as a
whole is optional there: an installation that does not run reviews simply
leaves it out. `review-cycle.sh` therefore tests for the block against
`config.json` itself rather than against the merge `config_defaults` returns
(`docs/spec/implementation/requirements` requirement 1b): that merge
synthesises a `repository_review` object from the defaults of the leaves under
it, so it can never report the block absent, and this one check must read
absence as absence — against either spelling (`has("repository_review") or
has("project_review")`), since the deprecated alias above counts as
configuring the pipeline exactly as the current spelling does. Every key
*within* the block is read from the merge as everywhere else, which is what
lets it use `repository_review` unconditionally: `config_defaults` has
already folded whichever spelling `config.json` set into that key.

The body rows of the table below are generated from that schema — each key's
`x-docs.spec` prose and `x-docs.value` cell — by
`scripts/render-config-table.sh` (`docs/spec/implementation/README.md`
component 16), between the `config-table` markers, and CI fails a pull
request that leaves them stale. Edit the schema, not the rows. A Notes cell
over 500 characters is capped, with its full text deferred to this document's
`config-table:notes id=review` region below the table; `not_before`'s note is
the one long enough for that today.

```json
"repository_review": {
  "defaults": {
    "model": "claude-sonnet-5",
    "pr_label": "project-review",
    "branch_prefix": "review/",
    "min_days_between_reviews": 6,
    "not_before": "2026-07-30T16:00:00Z"
  },
  "repos": [
    { "slug": "Poetic-Poems/poetic" },
    { "slug": "Poetic-Poems/poetic-fiddle" }
  ]
}
```

<!-- config-table:start id=review — GENERATED from config.schema.json by scripts/render-config-table.sh; edit the schema, not these rows -->
| Key | Value | Notes |
|---|---|---|
| `repository_review.lock_stale_after` | *(unset)* | A floor under the derived value, on the same terms as the implementation pipeline's `lock_stale_after` (requirement 4f). The derivation multiplies the widest Reviewer-Agent backstop by the number of repositories configured for review (floored at one, so a single-repository installation is unaffected), because one lock can span all of them reviewed back to back, and adds the same slack. |
| `repository_review.defaults.model` | `claude-sonnet-5` | The Reviewer-Agent's model — the lead that drives the skill. The skill itself delegates well-scoped sub-tasks to lower-cost subagents, so this is the only model to pin here. A deeper review can be dialled up to a higher-capability model without other changes. |
| `repository_review.defaults.pr_label` | `project-review` | Applied to every review PR. **Distinct** from the implementation pipeline's `autonomous-agent`, so review PRs never count against `max_open_agent_prs` and are trivially filterable. It must not be `obsolete`, for the reason given against the implementation `pr_label`. |
| `repository_review.defaults.branch_prefix` | `review/` | Branch name `review/<date>`, e.g. `review/2026-07-20`. A branch is already scoped to its repository, so no slug is needed. |
| `repository_review.defaults.timeout_review` | *(unset)* | An override for the Reviewer-Agent's backstop, on the same terms as `timeout_coordinator` and through the same derivation (requirement 4f). Absent is the normal case. |
| `repository_review.defaults.inactivity_review` | *(unset)* | An override for the watchdog threshold of requirement 4e, taking precedence over the derivation of requirement 4f. Absent is the normal case; `0` disables the watchdog and leaves the backstop as the only cap. |
| `repository_review.defaults.min_days_between_reviews` | `6` | The skip-guard threshold (R4). A repo reviewed within this many days is skipped. Six (not seven) leaves a day of slack, so a review that lands late one week is not pushed a full extra week the next. |
| `repository_review.defaults.min_prs_between_reviews` | `5` | The other half of the skip-guard threshold (R4). A repo with fewer than this many PRs merged into its default branch since its last review is skipped, independent of `min_days_between_reviews`. Absent everywhere, 5 is used — the fallback lives in code, not this default. |
| `repository_review.defaults.not_before` | *(unset)* | Optional. A timestamp before which no review may start (R3.3). Absent or empty means no stand-down; a value `date -d` cannot read stands the pipeline down rather than running through it. Expires by itself, which is why it exists rather than raising `min_days_between_reviews`: a threshold has to be put back by hand, and a cadence left quietly throttled is not noticed for weeks. As `defaults.not_before` it gates the whole cycle before the lock, exactly as a single...[continued below](#extended-notes-repository_reviewdefaultsnot_before) |
| `repository_review.defaults.report_directory` | *(unset)* | Optional. The report directory, as a GNU `date`(1) format string resolved with `date -u +"<format>"` relative to the repository root, for the run's own `review_date` (R4a). Absent, and absent on a repository's own override too, `reviews/project-review-%Y-%m-%d` is used — today's layout, unchanged; the fallback lives in code, not this default, so a schema-only reader sees it as genuinely unset. Must be day-granular (R4a): a format carrying `%H`, `%M` or `%S` resolves...[continued below](#extended-notes-repository_reviewdefaultsreport_directory) |
| `repository_review.defaults.review_instructions` | *(unset)* | Optional. Installation-held instructions (R5 step 2a), resolved against `state_dir` on the same terms as `prompt_overrides`' `extend` (requirement 4a). A configured path that does not resolve is a fail-fast config error (R1c) — never tolerated the way a `prompt_overrides` path is, because this text changes how strictly a review judges. The only instruction channel D7 admits; a repository under review has none. |
| `repository_review.defaults.review_context` | *(unset)* | Optional. Installation-held context (R5 step 2a), resolved exactly as `review_instructions` and equally fail-fast on a missing configured path (R1c). Layered with `repo_context_file` below rather than replacing it — both reach the Reviewer-Agent as `context`, each with its own origin stated. |
| `repository_review.defaults.repo_context_file` | *(unset)* | Optional. A repository-relative path read from the ephemeral clone (R5 step 2a) and added as `context`, attributed `source: "repository"`. Never treated as instruction (D7). Unset by default; absent from the clone is simply absent — never a fail-fast error, unlike `review_instructions`/`review_context`. |
| `repository_review.repos` | `[{"slug": "Poetic-Poems/poetic"}, {"slug": "Poetic-Poems/poetic-fiddle"}]` | The repositories to review. Each entry's `slug` is required; every other key overrides the same-named key in `defaults` for that repository alone (issue #342), and an entry carrying only `slug` inherits every default. A review has no per-repo work-source structure beyond these overrides. Adding a repo is a config-only change. |
| `project_review` | *(unset)* | Deprecated alias for `repository_review` (agent-ops#592, D7): accepted with the identical shape while the fleet rolls onto an image containing the rename. `scripts/doctor.sh` warns when this is the only one set, naming `repository_review` as the replacement. Setting both is a configuration error (`config_schema_errors` refuses it, naming both keys) rather than a silent precedence, since resolving one of two present keys is exactly the quiet failure this schema exists to...[continued below](#extended-notes-project_review) |
<!-- config-table:end -->

Model IDs are pinned in config (one place to update); do not use floating
aliases in the launch command.

`repository_review.defaults.model` (or a repository's own override in
`repository_review.repos`, issue #342) accepts a bare id
(`claude-sonnet-5`, meaning `anthropic`) or a provider-qualified one
(`anthropic/claude-sonnet-5`, or `<name>/<id>` for a provider the top-level
`providers` object configures), resolved by the same `resolve_model_id_into`
(`lib/model-id.sh`) the implementation pipeline uses — see
`docs/spec/implementation/requirements/the-script-01.md` requirement 1a.
`anthropic` is always
accepted, substrate `claude-code`, whether or not `providers` names it
explicitly (D12, `docs/ROADMAP.md`); a qualifier naming a provider
`providers` does not configure, or one configured with a substrate this
image has no adapter for, is a fail-fast config error at cycle start, not a
value passed to `claude --model`.

<!-- config-table:notes id=review — GENERATED from config.schema.json by scripts/render-config-table.sh; edit the schema, not this section -->

#### Extended notes: `repository_review.defaults.not_before`

Optional. A timestamp before which no review may start (R3.3). Absent or empty means no stand-down; a value `date -d` cannot read stands the pipeline down rather than running through it. Expires by itself, which is why it exists rather than raising `min_days_between_reviews`: a threshold has to be put back by hand, and a cadence left quietly throttled is not noticed for weeks. As `defaults.not_before` it gates the whole cycle before the lock, exactly as a single installation-wide value always has; a repository's own override on `repos[]` is resolved separately, per repository, once the cycle is under way (requirement 3.3).

#### Extended notes: `repository_review.defaults.report_directory`

Optional. The report directory, as a GNU `date`(1) format string resolved with `date -u +"<format>"` relative to the repository root, for the run's own `review_date` (R4a). Absent, and absent on a repository's own override too, `reviews/project-review-%Y-%m-%d` is used — today's layout, unchanged; the fallback lives in code, not this default, so a schema-only reader sees it as genuinely unset. Must be day-granular (R4a): a format carrying `%H`, `%M` or `%S` resolves differently at discovery time than it did at write time, and discovery silently finds nothing.

#### Extended notes: `project_review`

Deprecated alias for `repository_review` (agent-ops#592, D7): accepted with the identical shape while the fleet rolls onto an image containing the rename. `scripts/doctor.sh` warns when this is the only one set, naming `repository_review` as the replacement. Setting both is a configuration error (`config_schema_errors` refuses it, naming both keys) rather than a silent precedence, since resolving one of two present keys is exactly the quiet failure this schema exists to catch. The old spelling stops being accepted once every node in the fleet reports an image containing the rename (`repository_review`) — there is no calendar-based deprecation window: this installation has no release train to express one in, config.json ships inside the image (so a node never runs new code against an old config file of its own), and the fleet roll is the only compatibility window that genuinely exists.

<!-- config-table:notes-end -->

## The Landing Gate and the loop it closes

The review pipeline raises **one pull request per repository, ready for
review** (not draft — the review *is* the deliverable, and there is no second
review stage to flip it). The PR is labelled with the repository's own
resolved `repository_review` pr_label (its override, or
`repository_review.defaults.pr_label`, issue #342), titled in
Conventional Commits form (e.g. `docs(review): repository review 2026-07-20`),
and its body summarises the verdict and links the review index. A human
approves and merges it, at every `merge_autonomy` level: `review-cycle.sh`
engages no Approver stage, so the implementation pipeline's trust ladder
(`docs/spec/implementation/landing-gate.md` §The Landing Gate) does not yet
reach review pull requests, however the installation has configured it.
Review PRs join that ladder when an Approver is wired into this pipeline —
work no item covers yet, named here so the gap is a stated one rather than
a silent one.

The point of the pipeline is the *loop*, not the report. Debt the review
surfaces is filed straight to GitHub, as labelled issues, while the review
runs (R12) — not held for the pull request to land; once the pull request
merges, its `04-improvement-prompts.md` lands on `main` too, where:

- the **implementation pipeline's** Co-Ordinator can pick up any issue the
  review filed through its own `issues` work source; and/or
- the human runs the **`project-remediation`** skill (the review's
  counterpart) to work down the recommendations deliberately.

So the review is the *front* of a loop that ends in merged improvements,
each landed through whatever gate its repository's `merge_autonomy` level
sets — the human's own, at the default — never a dead-end document.

## Cost profile

One deep review per repo per week: a Sonnet lead driving the skill, which
itself delegates to lower-cost subagents. Bounded by each repository's own
resolved `timeout_review`.
The skip-guard caps it at one review per repo per `min_days_between_reviews`, so
a daily cron tick does not multiply cost. Deferring to the implementation lock
keeps the two pipelines from doubling up on quota at the same moment. The Script
itself makes no model calls.

## Design decisions

Recorded so a future reader knows they were deliberate. History and
superseded approaches belong here, never in the requirements above, which
state only what is.

- **A separate pipeline, not a new stage of `agent-cycle.sh`.** A review is
  weekly, long, and whole-repo; the implementation cycle is hourly, short, and
  single-item. Bolting the review onto the cycle would either starve the cycle
  (a review holding the shared lock for hours) or complicate its per-stage
  timeouts. A sibling Script with its own lock, label, and cron keeps each
  simple — while a single shared `limit-hit` signal and a one-way deference
  (review yields to a running cycle) keep them from fighting over quota.
- **The skill is vendored into the orchestrator and injected into the clone**,
  not committed into the product repos. Reproducible (pinned, in this repo's
  version control, not a machine's global copy of the skill), keeps the product
  repos clean, keeps the review out of its own scope, and needs no pull request
  into two protected product repositories to switch the pipeline on.
- **The review PR is raised ready, not draft.** The review is the deliverable;
  there is no correctness pass to add (unlike the Implementer→Reviewer
  hand-off), so a second agent stage would only add cost. The landing gate is the
  merge.
- **"Once a week" is implemented as a daily tick plus a skip-guard**, because a
  strict weekly cron on a machine that sleeps can miss its one tick and lose a
  whole week. The guard also makes re-runs idempotent.
- **The outputs feed the existing pipelines by design.** The review files
  debt straight to GitHub as labelled issues the hourly Co-Ordinator's
  `issues` work source can already pick up, and writes the improvement
  prompts the `project-remediation` skill consumes — so the review is the
  front of an existing loop, not a parallel dead-end.
- **Review-sourced debt is filed as GitHub issues, not register entries
  (agent-ops#876, D15).** The register served this well while an item's ID
  needed to be race-safe across concurrent human and agent writers and its
  filing needed to survive as an immutable per-item file; GitHub issues give
  both natively — an issue number allocates atomically, and a labelled issue
  cannot silently conflict with another. Filing therefore costs one API call
  (`gh issue create --label pw::type:tech-debt`) instead of an ID
  reservation and a commit, and the review PR's `Defers:` section is the
  record connecting the review to what it found, in place of a register diff
  the pull request used to carry. A repository's existing register, where it
  still has one, is left exactly as it was: history, never a second place
  new debt lands (R12).
- **`min_days_between_reviews` is 6, not 7**, so a review that lands a day late
  one week is not deferred a full extra week the next.

The shared platform, models, permissions, and system location were confirmed
with the repo owner for the implementation pipeline and carry over unchanged;
no open questions remain.
