# Contributing

<!-- toc:start -->
- [For maintainers: the as-built specifications](#for-maintainers-the-as-built-specifications)
- [Branch workflow](#branch-workflow)
- [Development](#development)
  - [Making a change when every instance is a container](#making-a-change-when-every-instance-is-a-container)
  - [Running the tests](#running-the-tests)
  - [Measuring the documentation](#measuring-the-documentation)
  - [Trying a change on a real node before it merges](#trying-a-change-on-a-real-node-before-it-merges)
  - [Taking one node out while the rest keep working](#taking-one-node-out-while-the-rest-keep-working)
  - [How a change propagates — and what survives it](#how-a-change-propagates--and-what-survives-it)
<!-- toc:end -->

## For maintainers: the as-built specifications

To modify this system (add a new work source, change the selection logic, etc.), start from `docs/spec/implementation/README.md` — the as-built requirements specification for the pipeline, with numbered requirements and acceptance checks. The specs are maintained as-built: a change to a component lands in the same pull request as the spec edit that keeps its document accurate (see `AGENTS.md`, "As-built specifications"). `prompts/coordinator.md`, `prompts/implementer.md`, and `prompts/reviewer.md` are the operating prompts actually fed to each stage's headless `claude -p` invocation — update the spec first, then bring the affected operating prompt(s) in line with it.

`docs/spec/dashboard/README.md` is the companion specification for the monitoring dashboard (`scripts/publish-dashboard.sh` and `dashboard/index.html`).

`docs/spec/review.md` is the companion specification for the repository-review pipeline (`review-cycle.sh` and `prompts/project-reviewer.md`).

`docs/spec/monitor.md` is the companion specification for the Pipeline Monitor (`monitor-cycle.sh`, `lib/monitor-digest.sh` and `prompts/monitor.md`).

## Branch workflow

This repo follows the same conventions as its target repos:
- `main` is protected; no direct commits. All changes go through pull requests.
- PR titles must be in [Conventional Commits](https://www.conventionalcommits.org/) format (`<type>[(scope)]: <description>`).
- `AGENTS.md` (which `CLAUDE.md` imports) binds all work done inside this
  repository, as each target repository's own `AGENTS.md` binds work there.

## Development

The image is the deployment, but it is never the workshop. Changes are made
in an ordinary git checkout, land on `main` through a pull request, and reach
the fleet as a freshly built image. Nothing is ever edited inside a running
container — there is no useful way to: `/app` is baked in at build time, and
the next image roll would discard the edit anyway.

### Making a change when every instance is a container

Work in a dedicated fresh clone on a feature branch and open a pull request —
the workflow in [Branch workflow](#branch-workflow) and `CLAUDE.md`. With the
legacy host install cut over, a checkout is purely a development artefact: no
cron entry and no pipeline runs out of it, so editing one cannot destabilise
a running cycle. The rule in [Pausing the
pipelines](../operating/run-and-pause.md#the-disableenable-switch) — disable before editing — protected the
host install, where cron ran the very files being edited; on a fleet of
containers, editing is always safe and the switch is about *rollout*, not
editing.

Because rollout is where the care has moved to: every merge to `main` that
touches anything the container reads builds and publishes a new image, and
every node on the `auto-update` profile restarts into it within watchtower's
poll interval (about five minutes). The
roll waits for a cycle rather than killing one — watchtower's pre-update hook
(`deploy/docker/watchtower-pre-update.sh`) exits 75 while either pipeline's
lock is held, so the update slides to the next poll and keeps sliding until
the node is idle. What that does *not* buy you is any say over *which* image a
node lands on, or over the order several nodes land in. So for a change that
touches cycle state, claims, or the state-sync format, stand the fleet down
first, merge, watch the roll, then resume — the switch works from any node:

```bash
docker compose exec scheduler /app/agent-cycle.sh --disable "rolling out PR #NN"
# merge; watchtower rolls every auto-update node onto the new image
docker compose exec scheduler /app/agent-cycle.sh --enable
```

### Running the tests

The unit tests are plain bash, no framework; each is self-contained and exits
non-zero on the first failed assertion. Run the suite the way CI runs it:

```bash
./scripts/run-tests.sh                      # every test/*.test.sh
./scripts/run-tests.sh cycle-state doctor   # only those whose name matches
./scripts/run-tests.sh --list                # just the selected names, one per line
```

`--list` needs no Docker and starts no container — it applies the same filter
to the host's own `test/*.test.sh` and prints the matching basenames, so a
caller bound by a hard per-invocation ceiling (the Reviewer stage's own
Bash-tool wall; see `prompts/reviewer.md`) can list the suite once, split it
into groups that each finish comfortably inside that ceiling, and run
`./scripts/run-tests.sh <group's names...>` once per group instead of one
unbounded call over the whole thing.

That copies the working tree into a throwaway container built from the image
and runs the suite there. Budget half an hour or more — CI runs the identical
loop inside the same image in about 20 minutes per architecture, and a
developer host is usually slower still, so a run that looks stuck probably is
not. It is worth the wait: the tests will
*start* anywhere and only *pass* in the environment CI uses, and
both ways of getting that wrong produce failures on an untouched `main` that
read as a broken branch rather than a broken invocation.

- **Straight out of the checkout** — which is what this section used to
  recommend — the host's `jq` is whatever the host has. `jq` 1.6 and 1.7
  disagree about enough for roughly nine of these files to fail, and not one of
  those failures mentions `jq`.

- **Through `docker exec` into a running node** — the obvious fix for the
  first, and its own trap: that container's `/app` is whatever commit it was
  last built from, not the working tree in front of you, so a fix made here is
  invisible to a suite run there. `docker run` copies the current working tree
  in fresh; `docker exec` never does. `docker run`, never `docker exec`.

Two smaller traps of the same shape. `run-tests.sh` prints per-assertion
detail only for a file that fails — a passing file is one `PASS <name>` line
— so a new assertion that silently asserts nothing looks exactly like a pass;
to see the `ok - …` lines for one file, run it alone inside a container from
the image (`tar -cf - . | docker run --rm -i --entrypoint bash <image> -c
'd="$(mktemp -d)" && cd "$d" && tar -xf - && bash test/<file>.test.sh'` —
`mktemp -d`, because `/` is not writable in the image), and follow a new
assertion by reverting the fix and confirming the assertion fails. And
`shellcheck` is pinned to v0.10.0 in CI and in the image while a developer
host commonly has 0.8.0, which misses findings CI fails on (SC2317 on a stub
function called only from an `eval`ed block, for one); run
`./scripts/lint-shell.sh` inside a container from the image before pushing.

`AGENT_OPS_TEST_IMAGE` picks the image, for testing against a locally built one
rather than `ghcr.io`'s latest:

```bash
docker build -f deploy/docker/Dockerfile -t agent-ops:dev .
AGENT_OPS_TEST_IMAGE=agent-ops:dev ./scripts/run-tests.sh
```

CI runs the same suite *inside* the freshly built image on every push that
could change it — along with toolchain, crontab and role-guard checks (see
`.github/workflows/build-image.yml`) — so an image that reaches `ghcr.io`
has already passed everything above. A change confined to documentation
builds no image and so runs none of this; anything else does, `prompts/*.md`
emphatically included, since those are what the pipeline feeds to `claude`,
and `docs/STANDING-DECISIONS.md` and every `docs/*-SPEC.md` emphatically
included too, since the image delivers both to a running stage.
`scripts/is-docs-only.sh` holds the line — the one place this allowlist is
written down, so it is not repeated here — and running it by hand answers
"will my branch build an image?":

```bash
git diff --no-renames --name-only main...HEAD | ./scripts/is-docs-only.sh
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

Build the image from the checkout and point a stack at it —
`AGENT_OPS_IMAGE` in `.env` exists for exactly this:

```bash
docker build -f deploy/docker/Dockerfile -t agent-ops .
# in the stack's .env:  AGENT_OPS_IMAGE=agent-ops
docker compose up -d
docker compose exec scheduler /app/agent-cycle.sh --dry-run
docker compose exec scheduler /app/agent-cycle.sh --once --repo poetic-fiddle
```

Do this on a scratch stack or a standby node, never the fleet's workhorse. A
second stack on the same host needs its own `COMPOSE_PROJECT_NAME`, node
name and token (see
[A second node on one host](../../../deploy/docker/README.md#a-second-node-on-one-host));
`--dry-run` and `--once` run regardless of role, so the guinea-pig node can
stay `standby` throughout. To mock a usage-limit event for testing the
cooldown, from a shell on that node (`docker compose exec scheduler bash`):

```bash
jq -n '{ts: now | todate, cycle: "manual", event: "limit-hit", resume_at: (now + 7200 | todate), detail: "test injection"}' >> ~/.local/state/poetic-agents/log.jsonl
```

### Taking one node out while the rest keep working

Yes — role and lifecycle are per-node, and so is `--disable --this-node`, the
graceful way to stand one node down: no container recreate, no role flip, the
rest of the fleet keeps working throughout.

```bash
docker compose exec scheduler /app/agent-cycle.sh --disable "editing lib/" --this-node --for 2h
# ... work on that node ...
docker compose exec scheduler /app/agent-cycle.sh --enable --this-node
```

`--this-node` writes only that node's own `$state_dir/disabled.json` and
never touches `fleet/disabled.json` — plain `--disable` (no `--this-node`)
is the one that stops the *fleet*, publishing the flag every node obeys, and
is the wrong tool for taking a single node aside. `--enable --this-node`
clears only the local record and leaves a fleet-wide disable, or a peer's own
`--this-node` one, untouched. It expires on the same terms as the fleet
switch (`disable_default_ttl` unless `--for`/`--until` says otherwise), so a
forgotten `--enable --this-node` costs a few lost cycles on that node, not a
silent permanent stand-down. `--status` on the node reports it, and its
dashboard card carries the same badge a fleet disable shows, beside its role
badge — so the stand-down is visible without a shell on the box.

A plain `--disable` writes a local record too, on the node you typed it on:
that write is what stands *that* node down while the fleet flag is still being
published, and what keeps it down if the state repository turns out to be
unreachable. It is tagged `scope: "fleet"` to mark it a mirror of the fleet
switch rather than a stand-down of that node's own — so neither `--status` nor
the dashboard reports the node you happened to type the command on as
separately disabled, and `--enable --this-node` refuses to clear it (plain
`--enable` is what undoes a fleet-wide disable, and clears both levels). One
case is worth knowing about: run `--enable` on a *different* node and it
clears the flag but cannot reach the first node's file, leaving that one node
standing down alone. `--status` there and its dashboard card both say so in
those words, and `--enable` on that node clears it.

That covers most "I need this one node to stop for a while" cases. For
anything it doesn't:

- **Stop it spending indefinitely, with no switch and no expiry**: set
  `ROLE=standby` in its `.env`, then `docker compose up -d`. It keeps its
  heartbeat and keeps following the fleet's memory, so promoting it back is
  the same one variable.
- **Stop it entirely**: `docker compose stop scheduler`, or
  `docker compose down` (which keeps the volumes). The rest of the fleet
  carries on; per-item claims mean no other node was depending on this one.
- **Hold it on a known image** while the rest follow `latest`: pin
  `AGENT_OPS_IMAGE=ghcr.io/pullwright/agent-ops:<sha>` in its `.env`.

All three, and a `--this-node` disable once its expiry passes or
`--enable --this-node` runs, leave the node able to come back, which is what
makes them the wrong answer when the machine is going away or its disk is
wanted: see [Remove a node for good](../operating/change-a-node.md#remove-a-node-for-good) for the
departure that also releases the volumes, the state branch, and the
credentials.

One caution before any *manual* `docker compose up -d` on a live node: after
a watchtower roll, compose's recorded config-hash no longer matches, so
`up -d` recreates the scheduler even when nothing in the compose file
changed — killing a running cycle. The pre-update hook cannot save you here:
it is watchtower that consults it, and a hand-typed `up -d` asks nobody. Run
`--status` first and let a cycle in flight finish.

### How a change propagates — and what survives it

Containers are disposable and, in effect, immutable: an update *is* the
destruction of the old container and the creation of a new one from the new
image, whether watchtower performs it or a manual
`docker compose pull && docker compose up -d` does. That is not a cost to
work around but the design — nothing worth keeping lives in a container.
What carries across every roll:

- **The node's `.env`** — a file on the host, outside Docker entirely. The
  GitHub PAT (`GH_TOKEN`) is injected from it into each new container at
  start, so the recreated container uses the same token as the destroyed
  one; nothing is re-issued, and the token needs replacing only on its own
  expiry (or if leaked).
- **The `claude-config` volume** — Claude's OAuth credentials, which refresh
  themselves in place. The manual `docker compose exec scheduler claude`
  login is once per *node*, not per container: no re-authentication after an
  image update, a `stop`/`start`, or a role change. The only thing that
  costs a fresh login is destroying the volume itself
  (`docker compose down -v`).

  It also holds Claude Code's global config file. That file defaults to
  `~/.claude.json` — beside the config directory, not inside it — which put it
  in the container's writable layer, where every image roll took it: each new
  container printed "Claude configuration file not found" on stderr and built
  a fresh one. The image sets `CLAUDE_CONFIG_DIR` to this volume's mount point
  so the file lands inside it instead. Nothing else moved, and no node needs
  to do anything: the change arrives with the next watchtower roll.
- **The `state` and `workspaces` volumes** — the pipelines' memory and any
  in-progress clone.

What does *not* carry across a roll is the container's writable layer, and
nothing in it is meant to: it is where `$TMPDIR` lives, and it shares the
host's disk with the volumes above, so anything left there is disk the state
volumes' own pressure valve (requirement 2.5) cannot reclaim. Every scheduled
entry point and the dashboard Publisher therefore keeps everything it spools
inside one directory named after its own process
(`agent-ops.<name>.<pid>.XXXXXX`, `lib/scratch.sh`) and removes it on exit,
and the dashboard launcher's every window — and every cycle start — removes
the directories whose owning process is gone, which is what a `KILL` leaves.
`docker ps -s` shows the layer's size.
