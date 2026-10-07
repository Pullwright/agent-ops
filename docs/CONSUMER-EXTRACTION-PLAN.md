# Consumer-extraction plan

**Status: preparation.** The extraction has not happened. This document is
the plan of record for it, tracked by #601 (owner acts, `blocked` so the
pipeline never selects it). It is a planning document, not an as-built
specification: it describes what will be done and in what order; the
as-built specs under `docs/spec/` remain the authority on what *is*. When a
step lands, tick it in #601 and amend this document where the evidence
overtakes it.

## The decision this plan executes

D8 (`docs/ROADMAP.md`) is a transfer followed by an extraction. The transfer
is done: agent-ops itself moved to the Pullwright organisation on
2026-09-07 (#912, `docs/PULLWRIGHT-REHOMING.md`) and is the product
repository in place, with its history, its issues, its D18 evidence and its
Approver. What remains is the extraction: Poetic's consumer configuration
and deployment move **out** of agent-ops into a new, differently named
repository in Poetic-Poems (GitHub retired `Poetic-Poems/agent-ops` on
transfer, so the name cannot be reused), and that repository holds no
pipeline code.

Every path on `main` lands on one side of that line. Four classes, defined
once and used throughout:

- **product** — stays in agent-ops, which is already the product
  repository. Nothing moves to or is created in Pullwright by this plan.
- **consumer** — leaves agent-ops for the new Poetic-Poems repository, as
  Poetic's own configuration and deployment.
- **both** — a product artefact with a Poetic-specific instance: agent-ops
  keeps the artefact, the consumer repository holds Poetic's instance of
  it, and a stated mechanism connects the two at run time.
- **retired by the extraction** — nothing needs it once the consumer has
  moved.

## Part 1 — Inventory

### Top-level paths

Re-derived from `main` at `e0af12b4765d3a53aeb0f8fc7e9a16571b4946aa`
(2026-10-07). 27 paths — the same count the issue specification lists.

| Path | Class |
|------|-------|
| `.claude/` | product |
| `.dockerignore` | product |
| `.githooks/` | both |
| `.github/` | both (split below) |
| `.gitignore` | both |
| `AGENTS.md` | both |
| `CHANGELOG.md` | both |
| `CLAUDE.md` | both |
| `CODEOWNERS` | both |
| `CONTRIBUTING.md` | both |
| `LICENCE` | owner decision (below) |
| `README.md` | both |
| `SECURITY.md` | both |
| `TECH-DEBT.md` | product |
| `agent-cycle.sh` | product |
| `config.json` | consumer |
| `config.schema.json` | product |
| `dashboard/` | product |
| `deploy/` | both (split below) |
| `docs/` | product |
| `lib/` | product |
| `monitor-cycle.sh` | product |
| `prompts/` | product |
| `review-cycle.sh` | product |
| `scripts/` | product |
| `tech-debt/` | product |
| `test/` | product |

`docs/`, `scripts/` and `lib/` are each genuinely uniform — every file
inside is pipeline-internal and carries no Poetic-specific content beyond
illustrative values — and are detailed in their own subsections below
rather than split. `deploy/` and `.github/` are not uniform and are split at
least one level deeper. The small repository-meta files (`AGENTS.md`,
`CLAUDE.md`, `CODEOWNERS`, `CONTRIBUTING.md`, `SECURITY.md`, `CHANGELOG.md`,
`README.md`, `.gitignore`, `.githooks/`) are each **both** for the same
reason — every repository needs its own instance — and are grouped under
"Repository documents" rather than repeated nine times.

### `config.json` and `config.schema.json` — the worked example

**Today.** The schema (`config.schema.json`) is generic and stays in
agent-ops; `config.json` holds Poetic's real values — its three
`repos[]` entries (`Poetic-Poems/poetic`, `Poetic-Poems/poetic-fiddle`,
`Pullwright/agent-ops` itself), its `state_repo`
(`Poetic-Poems/agent-ops-state`), its `state_dir`/`workspace_root`, its
Approver/Author installation ids, and every other installation-specific
value. `agent-cycle.sh` reads it from a hardcoded path
(`CONFIG_FILE="$SCRIPT_DIR/config.json"`, no override); `review-cycle.sh`
and `monitor-cycle.sh`, and most of `scripts/`, already accept
`AGENT_OPS_CONFIG` as an override (built for tests) and fall back to the
same hardcoded path when it is unset. The Dockerfile reads `config.json`
at **build** time to pre-create and `chown` the `state_dir`/`workspace_root`
directories inside the image, and `deploy/docker/compose.yaml` mounts the
state and workspace volumes at the literal paths
`/home/agent/.local/state/poetic-agents` and
`/home/agent/.cache/poetic-agents/workspaces` — not from a variable, the
directory name Poetic chose is written into the compose file itself. This
last point is `docs/PHASE-1-POETIC-SPECIFICS-AUDIT.md` finding 6 (#657,
"needs a key", still open): the directory name is baked into the image at
three sites (the Dockerfile's `RUN`, `deploy/docker/crontab.tmpl`, and
`compose.yaml`'s volume targets) with no build argument and no runtime
remapping.

**Split.** `config.schema.json` stays product. `config.json` — Poetic's
real values — moves to the consumer repository in full, unchanged.

**Mechanism: how a node's configuration reaches the product image.**
Three options exist:

1. **A mounted file**, named by `AGENT_OPS_CONFIG`, bind-mounted from a
   checkout of the consumer repository kept current on the node's host.
2. **A consumer image layered on the product image**
   (`FROM ghcr.io/pullwright/agent-ops` plus `COPY config.json /app/`),
   published from the consumer repository's own build workflow.
3. **A config-path variable honoured by every entry point**, which is
   option 1's prerequisite rather than an alternative to it — `agent-cycle.sh`
   is the one entry point that does not yet honour `AGENT_OPS_CONFIG`.

Option 2 is rejected: it gives the consumer repository a Dockerfile and a
publish workflow of its own, which is exactly the pipeline code D8
says it must not hold, and it reopens D28 ("one image, many containers")
by producing a second, installation-specific image that every node would
need to track alongside the product's own. Option 1, completing option 3
first, is recommended:

- Extend `agent-cycle.sh`'s `CONFIG_FILE` resolution to
  `"${AGENT_OPS_CONFIG:-$SCRIPT_DIR/config.json}"`, matching
  `review-cycle.sh` and `monitor-cycle.sh` exactly. This is a small,
  backward-compatible change — unset, behaviour is unchanged — landable in
  agent-ops as an ordinary fleet pull request ahead of T0, with no fleet
  disruption.
- Add `AGENT_OPS_CONFIG: ${AGENT_OPS_CONFIG:-}` to `compose.yaml`'s shared
  environment anchor (`x-agent-ops-env`), so a node opts in by setting one
  `.env` variable rather than by an image change.
- Add a new `.env` variable naming a **host** path to the consumer
  repository's `config.json` (e.g. `AGENT_OPS_CONFIG_HOST_PATH`), bind-mounted
  read-only to a fixed container path (e.g. `/etc/agent-ops/config.json`),
  using the same `/dev/null`-safe-default idiom `compose.yaml` already uses
  for the Approver's and the Author's private keys — unset, the mount is a
  harmless no-op and the container falls back to its own shipped
  `config.json`. Set `AGENT_OPS_CONFIG` to that fixed container path
  whenever the mount is wired.
- A node keeps that host checkout current by pulling the consumer
  repository, the same way a node keeps `compose.yaml` current today
  (`deploy/docker/README.md`, "Keeping the compose file current") — this
  plan does not invent a second mechanism; the reconciler-pull pattern
  `lib/compose-drift.sh` established is this change's one more consumer,
  not a new one to design.
- Resolve #657 alongside this: the Dockerfile's build-time `state_dir`/
  `workspace_root` pre-creation, and `compose.yaml`'s own volume targets,
  must stop hardcoding `poetic-agents` so that a mounted consumer
  `config.json` naming a different directory does not reintroduce the
  root-owned-volume restart loop the Dockerfile's own comment documents.
  The direction this plan takes — mount the real config in, rather than
  bake the product's shipped default into the image and trust every
  installation to match it — is exactly what makes this resolution
  necessary before T0, not merely convenient.
- **Validation** does not need the consumer repository to hold any
  pipeline code: its own CI workflow clones `Pullwright/agent-ops` at
  `main` (or a pinned ref) and runs `scripts/doctor.sh --config config.json
  --offline` plus `jq -e .` against its own `config.json`, the same two
  checks `docs/PULLWRIGHT-DAY-ONE-AUTONOMY.md` §4 already runs by hand
  against a copy. This composes the validation capability at check time
  rather than vendoring it — the D20-aligned shape, for a check D20 itself
  does not yet cover.

**What the product ships in `config.json`'s place.** A minimal,
schema-valid placeholder: one example `repos[]` entry (a neutral
`org/repo-a`-style slug, matching `prompts/coordinator.md`'s own existing
placeholder convention, with one `sources` entry), and `state_dir`/
`workspace_root` under the product's own name rather than Poetic's
(`~/.local/state/agent-ops`, `~/.cache/agent-ops/workspaces`) — satisfying
`config.schema.json`'s `required`/`minItems` so the image keeps building
standalone, and giving a fresh adopter a starting point to edit rather than
an empty file to write from nothing. `AGENTS.md`'s own testing convention
already treats this as safe: a test asserts that `config.json` is schema-valid,
never what it says, and every fixture supplies its own values — replacing
the shipped file's content is explicitly a routine configuration change,
not a risk to the suite.

### `.github/`

| Path | Class | Why |
|------|-------|-----|
| `.github/workflows/build-image.yml` | product | Builds and publishes the product image; nothing about it names Poetic |
| `.github/workflows/codeql.yml` | product | Scans agent-ops's own code |
| `.github/workflows/shellcheck.yml` | product | Lints agent-ops's own `.sh` files |
| `.github/workflows/config-table.yml` | product | Regenerates agent-ops's own generated regions from `config.schema.json` |
| `.github/workflows/toc.yml` | product | Regenerates agent-ops's own generated tables of contents |
| `.github/workflows/docs.yml` | product | Runs `scripts/check-docs.sh` over agent-ops's own documentation |
| `.github/workflows/docs-benchmark.yml` | product | Benchmarks agent-ops's own documentation |
| `.github/workflows/graphql-drift.yml` | product | Checks GraphQL query drift in agent-ops's own `lib/*.sh` |
| `.github/workflows/requirement-id-collisions.yml` | product | Checks requirement-ID collisions in agent-ops's own `docs/spec/` |
| `.github/workflows/compose-deploy-reminder.yml` | product | Reminds on a PR touching `deploy/docker/compose.yaml`, which stays product (below) |
| `.github/workflows/commit-format.yml` | both | Generic Conventional-Commits check any repository in the convention needs |
| `.github/workflows/closing-keyword.yml` | both | Generic `agent/<n>`-branch closing-keyword check any pipeline-target repository needs |
| `.github/workflows/changelog-section.yml` | both | Enforces D27, which any repository under it needs checked |
| `.github/workflows/tech-debt-close-guard.yml` | both | Advisory D15 check any repository using the `pw::type:tech-debt` label needs |
| `.github/ISSUE_TEMPLATE/issue.md` | both | Each repository authors its own |
| `.github/PULL_REQUEST_TEMPLATE.md` | both | Each repository authors its own, dropping the as-built-spec checklist line the consumer repository has no use for |

The four **both** workflows are the ones gating conventions that apply to
*any* repository the fleet works as a pipeline target, not to agent-ops's
own pipeline source specifically — exactly the class D20 names as tooling
that belongs to the product, not to the repository it runs in, with its
delivery mechanism an open Phase 2 question. Until D20 settles that, the
consumer repository's answer is the same interim every existing
pipeline-target repository already uses: its own vendored copy of the
workflow and its backing script, adopted the way `poetic`'s and
`poetic-fiddle`'s own D27 adoptions were (`Poetic-Poems/poetic#251`,
`Poetic-Poems/poetic-fiddle#434`) — landed once, at or shortly after
creation, and not re-synced by this plan. This is stated as the interim
explicitly, per D20's own "assume interim vendoring, plan for delivery"
rule; it is not a second copy of anything this plan is retiring (unlike
`deploy/`'s compose-drift machinery, below, nothing here is slated to
retire).

### `deploy/`

| Path | Class | Why |
|------|-------|-----|
| `deploy/docker/Dockerfile` | product | Builds the product image; no installation-specific literal survives once #657 lands |
| `deploy/docker/compose.yaml` | product | Generic service topology, driven entirely by `.env`; the one hardcoded directory name is #657's, not a design choice |
| `deploy/docker/entrypoint.sh` | product | Generic container entrypoint |
| `deploy/docker/crontab`, `crontab.tmpl`, `render-crontab.sh`, `reconcile-crontab` | product | Generic cron rendering |
| `deploy/docker/egress-allowlist.txt`, `egress-proxy.conf`, `egress-proxy-start.sh` | product | The D24 egress fence; the allowlist names the forge and model-provider hosts every installation needs, not Poetic specifically |
| `deploy/docker/claude-settings.json`, `claude-managed-settings.json` | product | Generic Claude Code policy (D24 requirement 4k) |
| `deploy/docker/watchtower-pre-update.sh` | product | Generic pre-update hook |
| `deploy/docker/cloud-init.yaml`, `ts-serve.json` | product | Generic node-bootstrap and Tailscale-serve templates |
| `deploy/kubernetes/collector-cronjob.yaml` | product | Generic Kubernetes manifest |
| `deploy/agent-ops-dashboard.init`, `deploy/tailscaled.init` | product | Generic legacy-host launchers; `RUNAS`/`APPDIR` carry no default (#656 already resolved this) |
| `deploy/docker/README.md` | both (split below) | Mixes a generic deployment guide with Poetic's own operational runbook |
| `deploy/docker/.env.example` | both (split below) | Mixes a generic template with comments naming Poetic's own repositories |

**Why the deployment mechanism stays product.** Every file above is already
parameterised through `.env` (compose) or generic by content (the
Dockerfile, the egress fence, the Kubernetes manifest): nothing in the
service topology, the image build, or the fence policy is a Poetic choice —
only the *values* a node supplies are, and those values live in `.env`,
which is never committed to either repository. A node's `.env` is the real
"both" boundary for everything in this table, not the files themselves.
Nodes keep fetching `deploy/docker/compose.yaml` and pulling the image from
`ghcr.io/pullwright/agent-ops` exactly as today — nothing about where
`config.json` lives changes the image or the compose file, so this
extraction leaves image/compose continuity entirely alone (see Part 2).

**`deploy/docker/README.md` and `.env.example` split.** Both files hold two
kinds of content today: a generic deployment guide (building the image,
the compose shape, the volumes, the egress fence, Kubernetes) and Poetic's
own operational runbook (the four-node table — `ockham-container`,
`ockham-2`, `poetic-1`, `poetic-2` — their hosts and cron-minute
assignments, and GitHub-token-scoping advice naming Poetic's actual four
repositories). The generic halves stay in agent-ops's own
`deploy/docker/README.md`/`.env.example`, genericised (placeholder repo
names and a generic token-scoping description in place of Poetic's own).
The operational halves move into the consumer repository as its own
deployment runbook and its own filled-in environment notes — new documents
authored from this content, not files moved by this pull request.

**Compose-drift machinery and Phase 2.** `deploy/`'s compose-drift
mechanism (#131: the compose self-mount, `lib/compose-drift.sh`,
`compose-deploy-reminder.yml`) stays product regardless of this extraction,
because `compose.yaml` itself stays product — this plan **precedes** Phase
2's "Make the deployment an artefact" item, which retires that machinery on
its own schedule once `compose.yaml` stops being hand-applied per node.
Nothing in this plan creates a second copy of that machinery in the
consumer repository: the consumer repository holds no `compose.yaml` of
its own to drift-check.

### `.claude/skills/`

The vendored `project-review` skill that `review-cycle.sh` stages into each
clone at runtime is product source (D7) and stays. Nothing inside it is
Poetic-specific (`docs/PHASE-1-POETIC-SPECIFICS-AUDIT.md` finding 15: the
gap there is untracked provenance, not a Poetic-specific to remove, and is
better filed as its own tech-debt item than folded into this plan).

### `tech-debt/` and `TECH-DEBT.md`

Both stay product. The frozen archive (`tech-debt/TD-PPagop-*.md`, 221
files) is overwhelmingly the pipeline's own debt, filed while this
repository was `Poetic-Poems/agent-ops` — its scope code, `PPagop`, says so
directly. `TECH-DEBT.md`'s own "Resolution and history" section anchors
each item's permanent audit trail to `git log --follow tech-debt/<id>.md`
on *this repository's own history* — history that the 2026-09-07 transfer
carried with it (GitHub transfers keep every commit), and that a newly
created consumer repository, with no shared history with agent-ops, cannot
reproduce. Copying the archive to the consumer repository is rejected for
the same reason the issue warns against generally: D15 (as revised)
already retired the register's own vendoring-and-drift machinery, and
holding a second copy anywhere would deepen exactly the copying D20 exists
to retire, for a register that does both a historical and a mechanical job
nothing in the consumer repository needs.

### `LICENCE` — owner decision

D5 has settled FSL-1.1-ALv2 for the product; `LICENCE`'s own file already
states this is provisional pending the "Apply the FSL-1.1-ALv2 licence"
item's prerequisites (naming the licensor, clearing the trademark search).
That item, and the choice it settles, is out of scope here and stays
exactly as it is.

What the consumer repository needs is not settled by any decision this
plan can find. D5 names *the product* — the FSL "Competing Use" restriction
exists to stop a reseller building a competing service from Pullwright's
own code, and Poetic's configuration values and deployment runbook are not
that code. Whether the consumer repository should carry the same licence as
the product (for consistency, even though its content is not the asset the
licence protects), a different open-source licence, or no public licence
at all, is an **owner decision** this plan flags rather than makes.

### Repository documents

`AGENTS.md`, `CLAUDE.md`, `CODEOWNERS`, `CONTRIBUTING.md`, `SECURITY.md`,
`CHANGELOG.md`, `README.md`, `.gitignore` and `.githooks/`.

Each is **both**: every repository needs its own instance, and none of
them is delivered or synced between the two beyond what already exists.

- **`AGENTS.md`/`CLAUDE.md`.** agent-ops's `AGENTS.md` keeps describing the
  pipeline's own conventions (as-built discipline, generated regions, the
  tech-debt band) — none of it describes a configuration-and-deployment
  repository. The consumer repository gets its **own** `AGENTS.md`, with
  its own stamped regions (the branch workflow, commit messages, the
  maintainer statement, the documentation principles — the same three
  fragments agent-ops's own `AGENTS.md` carries, from the same
  organisation-wide sync) and its own hand-written sections for whatever a
  configuration repository needs beyond those fragments. It must not take a
  copy of agent-ops's own `AGENTS.md` — most of that file does not apply.
  `CLAUDE.md` is the same one-line `@AGENTS.md` stub in each repository,
  pointing at that repository's own file.
- **`README.md`.** agent-ops's `README.md` is already fully generic — it
  describes "Pullwright" the product, with Poetic's installation named only
  as the illustrative reference installation — and needs no change. The
  consumer repository gets its own new `README.md`, describing itself as
  Poetic's deployment and configuration of the Pullwright pipeline and
  pointing back at the product repository for what the pipeline is.
- **`CODEOWNERS`.** Identical content (`@warwickallen`, `@Warwick-Allen`) in
  each repository, authored directly at consumer-repository creation —
  there is no mechanism delivering this today, and none is created here.
- **`CONTRIBUTING.md`, `SECURITY.md`.** Each repository's own, the consumer
  repository's considerably shorter — a configuration-and-deployment
  repository has no pipeline source to contribute to, and the security
  reporting boilerplate is identical regardless.
- **`CHANGELOG.md`.** Under D27, assembled from each repository's own
  merged pull-request descriptions; the consumer repository's starts empty
  from its first release or scheduled roll.
- **`.gitignore`, `.githooks/`.** Each repository's own, seeded once at
  consumer-repository creation from agent-ops's own copies and evolving
  independently thereafter — a one-time copy at creation, not an ongoing
  vendoring relationship, and (unlike `AGENTS.md`'s stamped regions, which
  the organisation's sync already maintains across repositories) this plan
  does not create one for `.githooks/`.

### Things outside this repository, following the consumer

Not inventoried above because they are not paths in this repository, but
named here because the order in Part 2 depends on when each moves:

- **Each node's own stack and its `.env`** — unchanged by this plan except
  for the new `AGENT_OPS_CONFIG_HOST_PATH` variable above.
- **The state repository, `Poetic-Poems/agent-ops-state`**, which
  `config.json`'s `state_repo` key names and whose claims are keyed by
  repository slug. It already sits in Poetic-Poems and does not move; it
  becomes the consumer repository's state store simply by continuing to be
  what Poetic's installation already uses it as.
- **`Poetic-Poems/helper-scripts/count-autonomous-agent-prs.sh`**, which
  reads `config.json` from `Pullwright/agent-ops` today (updated by the
  2026-09-07 transfer's own aftercare, helper-scripts `ccb9dbb`). It needs a
  second, equivalent update once `config.json` moves again — from the
  product's slug to the consumer repository's — and that update belongs in
  the cutover's own checklist (Part 2), the same way the transfer's did.
- **The Poetic-Poems fleet runbook**, due to move into the consumer
  repository once it exists, as that repository's own operational
  documentation (alongside the `deploy/docker/README.md`/`.env.example`
  extracts above).

## Part 2 — Order

### Before T0 (fleet, no owner act, no fleet disruption)

These can land in agent-ops independently of everything else in this plan,
exactly as #913's per-owner Approver installation landed weeks ahead of the
2026-09-07 transfer:

1. Extend `agent-cycle.sh`'s `CONFIG_FILE` resolution to honour
   `AGENT_OPS_CONFIG`, matching `review-cycle.sh`/`monitor-cycle.sh`.
2. Resolve #657 (the Dockerfile/`crontab.tmpl`/`compose.yaml` hardcoded
   `poetic-agents` directory name) so the image's own directory
   pre-creation tracks whatever `config.json` — shipped or mounted — names.
3. Add the `AGENT_OPS_CONFIG`/`AGENT_OPS_CONFIG_HOST_PATH` wiring to
   `compose.yaml`'s shared environment and volumes, defaulted off
   (`/dev/null`-safe), so existing nodes are unaffected until a node
   chooses to set the new variables.
4. Replace `config.json`'s content with the product's own generic
   placeholder (above) — **not yet**; this step is T0 itself (step 2
   below), because until the consumer repository exists and a node's
   mount is wired, agent-ops's own `config.json` is still what every node
   actually runs from.
5. Genericise `deploy/docker/README.md`/`.env.example`'s generic halves
   (placeholder repository names, a generic token-scoping paragraph),
   extracting Poetic's own operational content for step 2 below to carry
   into the new repository.

None of this touches a live node's behaviour: each item is additive
(an unset environment variable, a resolved build-time hardcode, a
genericised example) until T0 actually switches a node over.

### T0 — owner act, about an hour with the fleet stood down

The 2026-09-07 transfer is the precedent to estimate from: its own runbook
planned about an hour with the fleet stood down, and #912's comments record
a clean execution against that estimate. This cutover is smaller in surface
(one file moving between two repositories, not a whole repository changing
owner) but touches every node's `.env`, so the same order and the same
discipline apply:

1. **Stand the fleet down** and wait for running cycles to finish, exactly
   as `docs/PULLWRIGHT-REHOMING.md`'s own T0 step 1
   (`agent-cycle.sh --disable`, then `watchtower-pre-update.sh` on each
   node until idle).
2. **Create the consumer repository** in Poetic-Poems (name is the owner's
   choice). Populate it with: Poetic's live `config.json`, unchanged; the
   extracted operational content from `deploy/docker/README.md`/
   `.env.example` (Part 1); the repository documents each needs fresh
   (`README.md`, `AGENTS.md`/`CLAUDE.md` stamped from the organisation's
   sync, `CODEOWNERS`, `CONTRIBUTING.md`, `SECURITY.md`, `.githooks/`,
   `.gitignore`); the interim-vendored copies of the four **both** CI
   workflows and their backing scripts (`.github/`, Part 1); and its own
   validation workflow (cloning `Pullwright/agent-ops` to run
   `scripts/doctor.sh --config config.json --offline`, Part 1).
3. **Replace `config.json` in agent-ops** with the product's own generic
   placeholder (Part 1) in the same pull request that removes nothing else
   — this is a content replacement, not a path deletion, so it carries no
   "no path moved, deleted or renamed" exception to account for.
4. **Update `count-autonomous-agent-prs.sh`** (Poetic-Poems/helper-scripts)
   to read `config.json` from the new consumer repository's slug.
5. **On each node** — `ockham-container`, `ockham-2`, `poetic-1`,
   `poetic-2` — once idle:
   - Fetch (clone or pull) the consumer repository to a fixed host path.
   - Edit `.env`: add `AGENT_OPS_CONFIG_HOST_PATH` naming that path, and
     `AGENT_OPS_CONFIG=/etc/agent-ops/config.json` (the fixed container
     path the new bind mount targets).
   - `docker compose up -d` to apply the new mount and environment —
     image and compose file are already current, so this recreates
     containers against the same image, not a roll.
   - Confirm `docker exec agent-ops-scheduler-1 /app/scripts/doctor.sh`
     reads the mounted `config.json`, not the product's placeholder.
6. **Re-enable** the fleet and watch the first cycle on each node, exactly
   as the rehoming runbook's own closing step.

### What is broken in between, and for how long

Between step 3 (agent-ops's own `config.json` becomes the placeholder) and
each node completing step 5, that node runs — if it were not already stood
down — against the placeholder's empty-of-real-work `repos[]` entry: a
safe, inert failure mode (a no-op cycle that selects nothing and stands
down again), never a crash or a bad merge, because the placeholder is
schema-valid by construction. Standing the fleet down for the whole of T0
(as above) removes even that: no cycle runs between step 1 and step 6, so
nothing observes the inconsistent state at all. The window is the time to
complete steps 2–5 once, not per node — about an hour, the same order of
magnitude as the transfer, since the dominant cost (editing four nodes'
`.env` and recreating their containers) is the same shape of work the
transfer's own T0 step 4 already did once for `GH_TOKEN`/`AGENT_OPS_IMAGE`.

### Fleet continuity across the extraction

**A node mid-cycle when the configuration moves** is the failure this plan
is written around, and standing the fleet down (T0 step 1) removes it by
construction — no node is mid-cycle during steps 2–5 because none is
running at all. The alternative this plan rejects — cutting over with the
fleet live — would read `config.json` at different points of the same
*running* cycle inconsistently (`agent-cycle.sh` reads the file more than
once per cycle), exactly the hazard a hand-edited live node already risks
today and D16 already warns against; standing down is cheaper than solving
that hazard for a one-hour, once-only cutover.

**Config changes, after T0, should land on an idle node** — the same
discipline `watchtower-pre-update.sh` already enforces for image rolls.
This plan does not build a new idle-check for configuration specifically;
whatever mechanism eventually keeps a node's consumer-repository checkout
current (Part 1's "kept current by pulling the consumer repository") should
reuse that existing idle-wait pattern rather than apply a configuration
change under a running cycle.

### Node deployment follow-through

**The image.** Unchanged. Every node keeps pulling
`ghcr.io/pullwright/agent-ops` by tag, built by the product's own
`build-image.yml`, exactly as today.

**The compose file.** Unchanged. Every node keeps fetching
`deploy/docker/compose.yaml` from `Pullwright/agent-ops` (directly, or via
the `reconciler` service), exactly as today — this extraction adds two new
`.env`-driven lines to that file (Part 1) but does not change where it
lives or how a node gets it.

**`.env`.** Gains the two new variables above
(`AGENT_OPS_CONFIG_HOST_PATH`, `AGENT_OPS_CONFIG`); every other variable is
untouched.

**The configuration mechanism.** As resolved in Part 1: a bind-mounted
`config.json` from a host checkout of the consumer repository, kept current
the way `compose.yaml` already is.

### Does the consumer repository become a pipeline target?

Yes, but not during the cutover itself — only once it is provisioned
(below) and the fleet is confirmed stable again post-T0. It is added to
`repos[]` **in the consumer repository's own `config.json`** (a
self-referential entry, naming itself) as an ordinary, fleet-workable
config-only pull request — no different in kind from adding any other
repository, and not an owner act. This is an aftercare item, not part of
T0's own order, the same way the transfer's own aftercare items (releasing
stray claims, confirming `count-autonomous-agent-prs.sh`) followed T0
rather than gating it.

### Provisioning

The consumer repository starts at agent-ops's own `merge_autonomy` level
from day one, not at the product default — Principle 8
(`docs/ROADMAP.md`) states this directly: "`docs/PULLWRIGHT-DAY-ONE-AUTONOMY.md`
is the provisioning checklist this rule cashes out to for any repository
created after the transfer — **the consumer repository first**." That
checklist's own status header predates the 2026-08-28 D8 amendment and
still describes a hypothetical product repository in Pullwright; correcting
it is out of scope here (per the issue specification), but its checklist
content — the default-branch ruleset matching agent-ops's own, extending
the Pullwright Approver App installation to cover the new repository, and
the `repos[]` entry mirroring agent-ops's own current one — applies
directly to the consumer repository created by this plan. This plan does
not restate that checklist; it is referenced as the constraint governing
step 2 of T0 ("populate it with... its own validation workflow") and the
"becomes a pipeline target" step above, both of which must wait on
`scripts/doctor.sh`'s consolidated autonomy-readiness verdict reading `ok`
for the new repository before either is treated as safe to rely on.

## Open dependencies

- **#657** (state/workspace directory name baked into the image at build
  time) must resolve before T0, per Part 1's mechanism section.
- **D20** (tooling delivery mechanism) is still open with a Phase 2 gate;
  the four **both** CI workflows in `.github/` are vendored into the
  consumer repository as an explicit interim, per that section.
- **The consumer repository's licence** is an owner decision this plan
  does not make (Part 1, `LICENCE`).
- **Phase 2's "Make the deployment an artefact"** item retires the
  compose-drift machinery independently of this plan; this plan precedes
  it and creates no second copy for it to retire later.
