# Operating

<!-- toc:start -->
- [Installation](#installation)
  - [As a container](#as-a-container)
  - [The egress fence](#the-egress-fence)
  - [On the host (legacy, decommissioned)](#on-the-host-legacy-decommissioned)
- [Checking an installation](#checking-an-installation)
- [Operation](#operation)
  - [Dry run (no agents launched)](#dry-run-no-agents-launched)
  - [One cycle (foreground, verbose)](#one-cycle-foreground-verbose)
  - [Restrict to one repo (for testing)](#restrict-to-one-repo-for-testing)
- [Pausing the pipelines](#pausing-the-pipelines)
  - [Draining instead of stopping](#draining-instead-of-stopping)
  - [Lifting a usage-limit stand-down](#lifting-a-usage-limit-stand-down)
- [Which node runs the cycles](#which-node-runs-the-cycles)
- [Keeping every node warm](#keeping-every-node-warm)
- [Skipping no-op cycles](#skipping-no-op-cycles)
- [Diagnosing a cycle](#diagnosing-a-cycle)
  - [See the log](#see-the-log)
  - [Blocked and void items](#blocked-and-void-items)
  - [Closing an obsolete draft pull request](#closing-an-obsolete-draft-pull-request)
  - [Blocked items and the Enabler](#blocked-items-and-the-enabler)
  - [Refined items and the Refiner](#refined-items-and-the-refiner)
  - [Items nobody has specified](#items-nobody-has-specified)
  - [See stage transcripts](#see-stage-transcripts)
  - [Why a stage was stopped](#why-a-stage-was-stopped)
  - [See the security & code-quality findings](#see-the-security--code-quality-findings)
- [Repository review](#repository-review)
  - [Review instructions and context](#review-instructions-and-context)
  - [Install](#install)
  - [Operate the repository review](#operate-the-repository-review)
- [The Pipeline Monitor](#the-pipeline-monitor)
  - [Operate the Monitor](#operate-the-monitor)
- [Monitoring](#monitoring)
  - [Dashboard](#dashboard)
  - [View it](#view-it)
  - [Keep it fresh](#keep-it-fresh)
  - [Run as a service (legacy WSL path, decommissioned)](#run-as-a-service-legacy-wsl-path-decommissioned)
  - [View it away from home (Tailscale)](#view-it-away-from-home-tailscale)
  - [Watching a node's events](#watching-a-nodes-events)
  - [Push notifications](#push-notifications)
- [Troubleshooting](#troubleshooting)
- [Removing a node for good](#removing-a-node-for-good)
  - [1. Check the fleet can spare it](#1-check-the-fleet-can-spare-it)
  - [2. Let any cycle in flight finish](#2-let-any-cycle-in-flight-finish)
  - [3. Take off it anything you want to keep](#3-take-off-it-anything-you-want-to-keep)
  - [4. Destroy the stack, its volumes, and its tailnet identity](#4-destroy-the-stack-its-volumes-and-its-tailnet-identity)
  - [5. Remove it from the fleet's memory](#5-remove-it-from-the-fleets-memory)
  - [6. Revoke its credentials, then delete its directory](#6-revoke-its-credentials-then-delete-its-directory)
  - [7. Reclaim the disk](#7-reclaim-the-disk)
  - [Did it work?](#did-it-work)
- [Uninstall](#uninstall)
<!-- toc:end -->

## Installation

**Run a node as a container.** The image (`deploy/docker/`) carries the whole
toolchain and needs nothing on the host but Docker, and it is the deployment
artefact: `/app` inside it *is* agent-ops, so a node updates by pulling a new
image rather than by pulling a branch. The full runbook — bring-up, operations,
the failover drill, troubleshooting — is **[deploy/docker/README.md](../../../deploy/docker/README.md)**.

Before deploying to a new installation, see **[docs/DATA-HANDLING.md](../../DATA-HANDLING.md)** to
understand what data the pipeline reads, stores, and retains.

The **host install** further below is the laptop's old path, in which the
scripts ran straight out of a checkout under the user crontab and a SysV init
script. That cut-over is done — the laptop now runs as a container node like
every other — so those sections are retained only as a record of the retired
deployment; nothing runs that way any more.

### As a container

A node is one Compose project. Every node runs the same file and the same
image; the only thing that differs between two nodes is its `.env`.

```bash
mkdir -p ~/poetic-node && cd ~/poetic-node
base=https://raw.githubusercontent.com/Pullwright/agent-ops/main/deploy/docker
curl -fsSLO "$base/compose.yaml"
curl -fsSLO "$base/ts-serve.json"
curl -fsSL  "$base/.env.example" -o .env
curl -fsSLO "https://raw.githubusercontent.com/Pullwright/agent-ops/main/scripts/watch-node.sh"
chmod +x watch-node.sh
$EDITOR .env          # name the node, set its role, paste its tokens
docker compose up -d
docker compose exec scheduler claude   # authenticate this node, once
```

The node holds those four files and no clone. On a fresh cloud VM,
[`deploy/docker/cloud-init.yaml`](../../../deploy/docker/cloud-init.yaml) does all of
that unattended except the Claude login. `watch-node.sh` is how you follow its
pipeline output afterwards — see [Watching a node's
events](#watching-a-nodes-events).

Each image tag is a manifest list covering `linux/amd64` and `linux/arm64`, so
`docker compose up -d` pulls the right one on an x86-64 or an arm64 host —
including the cheaper arm instance classes — with nothing to choose.

`COMPOSE_PROFILES` in that `.env` decides what the node runs:

| Profile | What it adds |
|---|---|
| `tailnet` | Tailscale sidecar + the dashboard, served to your tailnet over HTTPS at `https://<node>.<tailnet>` — never to the public internet |
| `local` | the dashboard on the machine's own loopback instead (`http://127.0.0.1:8787`), for a node with no tailnet or no authkey |
| `node-health` | the node-health HTTP surface (`/livez`, `/readyz`, `/healthz`, `/metrics`) on the machine's own loopback (`http://127.0.0.1:8788`, moved by `NODE_HEALTH_PORT`), for a collector or an orchestrator that can only probe over HTTP. The scheduler's own liveness check runs the same CLI in-container whether or not this is on |
| `auto-update` | watchtower, which pulls new images and restarts into them |

The scheduler is in no profile: it runs on every node, whatever else does.

Five things are worth knowing:

- **`/app` is the deployment.** The image is built from this repository, so a
  node updates by pulling a new image — never by pulling a branch inside a
  running container. Every merge to `main` that touches anything the container
  reads builds one and publishes it to
  `ghcr.io/pullwright/agent-ops` as `latest` (what watchtower follows) and as
  the commit SHA. To pin a node to a known-good build, or to roll one back, set
  `AGENT_OPS_IMAGE=ghcr.io/pullwright/agent-ops:<sha>` in its `.env` — a
  documentation-only merge publishes nothing, so pin to a commit that built an
  image (the package's tag list is the record).
- **`~/.claude` and `state_dir` must be volumes.** Claude's OAuth credentials
  refresh and write back, and `state_dir` is the pipelines' memory. The
  entrypoint seeds `settings.json` only when it is absent, and refuses to start
  if `state_dir` is not writable by the container user (uid 1000 by default;
  rebuild with `--build-arg PUID=…` to match a host directory).
- **Give this node model credentials** (primary: BYO API key; alternative:
  subscription OAuth): The primary path (D4) is to set `ANTHROPIC_API_KEY` in
  `.env` and `docker compose up -d` to pick it up — nothing further to
  do, no interactive step, and any number of nodes can share the same key. Or,
  if you have a Claude subscription, authenticate once per node with `docker
  compose exec scheduler claude` and complete the interactive login. This
  subscription OAuth path is a supported self-hosted configuration, but it
  comes with two constraints: the login is interactive per node (no way to
  script it, so it does not scale past a handful of nodes), and the
  subscription's terms limit it to your own use, not a service you operate for
  others. Until one of these is configured, every cycle fails at its first
  stage, and the entrypoint warns about it on each start. This is the sole
  exception to this stack's otherwise non-interactive bring-up — every other
  credential, including GitHub's, arrives as a plain `.env` value read at
  container start, never by `exec`-ing into a running one. GitHub's own
  identity can be upgraded the same way, entirely optionally: the forge
  authoring App (D18 decision 1, `.env.example`'s "Forge authoring App"
  section) mints short-lived tokens in place of the `GH_TOKEN` PAT once an
  owner provisions it; unset, a node just keeps authenticating with `GH_TOKEN`,
  exactly as before this existed.
- **The dashboard is never reachable from a network.** The `tailnet` profile
  puts the server in the Tailscale sidecar's network namespace, so Serve can
  proxy to its loopback and nothing else can; the `local` profile publishes it
  to the host's loopback alone (`127.0.0.1:${DASHBOARD_PORT:-8787}:8787`). If
  the host already has something on 8787, set `DASHBOARD_PORT` in `.env` — it
  moves the host side of that mapping.
- **Set the Vercel variables if you want the stages to check preview
  deployments.** poetic-fiddle deploys every pull request to Vercel, and that
  deployment reports through GitHub's deployments API rather than as a check
  run — so a pull request can be entirely green over a preview that never
  built. `scripts/preview-deploy.sh` is what the Implementer and Reviewer run
  to find out, and it needs `VERCEL_AUTOMATION_BYPASS_SECRET` in the node's
  `.env` (Vercel → the project → Settings → Deployment Protection → Protection
  Bypass for Automation), because preview deployments sit behind Vercel
  Authentication and answer a login page to anything without it.
  `VERCEL_TOKEN` is optional on top and buys the build log when a deployment
  failed. Leave both empty and nothing changes: the stages report that the
  preview could not be checked, which is never a reason to block an item.

Set `ROLE=active` in the `.env` of every node meant to spend — any number may
be, since per-item claims keep them off each other's work (see
[Which node runs the cycles](#which-node-runs-the-cycles)); the rest stay
`standby`. Then read
[deploy/docker/README.md](../../../deploy/docker/README.md) for everything after that.

### The egress fence

The scheduler — the container that runs `claude` over text anyone on GitHub
can author, with live credentials in its environment — reaches the internet
only through the `egress-proxy` service's domain allowlist
(`deploy/docker/egress-allowlist.txt`; roadmap decision D24). The fence is
topology, not convention: the scheduler sits on an internal-only Docker
network with no gateway, and the proxy is the one way out, permitting only
HTTPS to the domains the pipelines actually use — GitHub, the Anthropic API,
Vercel previews, the npm registry and its build-time font fetches, and the
image registry. Everything else is refused, including all of Claude Code's
optional traffic (updates, telemetry, error reporting), which the
scheduler's environment turns off at the source.

**Rolling it onto an existing node** — the fence is compose-level, so no
image roll delivers it (the node's own heartbeat reports the compose drift
until you act). On a node running the `reconciler` service, a compose-level
change like this one now arrives on its own within a few minutes of the merge
— see [Keeping the compose file
current](../../../deploy/docker/README.md#keeping-the-compose-file-current), including
the one per-node step that enables it; the steps below are what a node without
it still needs:

```sh
cd ~/agent-ops   # wherever this node keeps compose.yaml and .env
base=https://raw.githubusercontent.com/Pullwright/agent-ops/main/deploy/docker
curl -fsSLO "$base/compose.yaml"
docker compose pull && docker compose up -d
docker compose exec scheduler /app/scripts/doctor.sh --offline || true
docker compose exec scheduler /app/scripts/doctor.sh   # Egress section: three [ ok ] lines
```

Mind the timing: `up -d` recreates the scheduler, so run it between cycles
or accept losing the one in flight (the watchtower pre-update hook does not
guard a manual `up -d`).

**A node needing an extra domain** — a Vercel project serving previews from
a custom domain is the expected case — names it in its `.env`:

```sh
EGRESS_EXTRA_ALLOW=preview.example.com
```

comma- or whitespace-separated, then `docker compose up -d egress-proxy`.
Fleet-wide additions belong in `deploy/docker/egress-allowlist.txt` instead,
where each entry states the code that needs it and
`test/egress-fence.test.sh` pins the set.

**If everything times out after enabling the fence**, check `DOCKER_MTU`
before blaming the allowlist: an MTU black hole through the proxy looks
exactly like a refused domain (compose.yaml's own MTU note tells you how to
set it). `scripts/doctor.sh`'s Egress section tells the three failure shapes
apart — proxy path broken, allowlist not enforcing, or direct egress still
open because this node's compose.yaml predates the fence.

There is deliberately no off-switch variable: unfencing a node is an edit to
its compose.yaml, made knowingly or not at all.

### On the host (legacy, decommissioned)

How the laptop ran before the cut-over — straight out of a checkout, under the
user crontab and a SysV init script. **No node runs this way now**; the steps
are kept as a record of the retired path, not as an install route. A new node
is a container: Docker and the `.env` above are the whole of it.

1. **Create the repo:**
   ```bash
   gh repo create Poetic-Poems/agent-ops --public --description "Autonomous agent pipeline for poetic and poetic-fiddle"
   ```

2. **Install the standalone Claude CLI:**
   ```bash
   curl -fsSL https://claude.ai/install.sh | bash
   # or
   npm install -g @anthropic-ai/claude-code
   ```
   Test headless auth directly:
   ```bash
   claude -p "Reply with OK" --model claude-haiku-4-5-20251001
   ```
   Also verify that the same environment cron will use can find Claude. A minimal cron-style sanity check is:
   ```bash
   env -i HOME="$HOME" PATH="$HOME/.local/bin:$HOME/.claude/local:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" /bin/bash -lc 'command -v claude && claude -V'
   ```
   If that fails, add a launcher such as `~/.local/bin/claude` or update the crontab PATH before continuing.

3. **Enable cron (WSL):**
   Edit `/etc/wsl.conf` (requires `sudo`):
   ```ini
   [boot]
   command = "service cron start"
   ```
   Then restart WSL: `wsl --shutdown` (from Windows).

   *Alternative (Windows Task Scheduler):* Create a task running `wsl.exe -u wallen -e $HOME/Code/Poetic-Poems/agent-ops/agent-cycle.sh` on the node's configured cadence (`schedule.cycle_interval_minutes`).

4. **Labels: nothing to do.** The pipeline creates the labels it uses — the PR
   label, the Enabler's escalation label, `needs-refinement`, `refined`,
   `unvoided`, the `complexity:*` grades, `blocked`, `blocked:needs-refinement`,
   `obsolete` and `pw::type:tech-debt` — in every repository it gathers data
   for, not only the one it happens to work, at most once per
   `labels_ensure_interval_hours` (default 24h), and puts back any you later
   delete within that interval. It only ever *creates*: a label you have
   recoloured or re-described keeps your version.

   All the token needs is permission to create them. If one is still missing
   after `labels_ensure_interval_hours` has passed since a cycle last gathered
   that repository, that permission is what to check — `./scripts/doctor.sh`
   names each absent label and says so.

5. **Enable the security work sources on each configured repo.** The `security` and `code-quality` sources read GitHub's own Dependabot alerts and code-scanning (CodeQL) alerts, so those features must be turned on for the alerts to exist:
   - In each repo's **Settings → Code security**, enable **Dependabot alerts** and **Code scanning** (a default CodeQL setup is fine). Free for public repos; private repos need GitHub Advanced Security.
   - The `gh` token must be able to read the alerts — the `security_events` scope (or `repo` on a classic token). Verify:
     ```bash
     ./scripts/gather-findings.sh Poetic-Poems/poetic
     ```
     You should get a JSON array of findings (or `[]` if there are none). If a feature is off, the script returns `[]` (exit 0) and the pipeline keeps working — you just won't get findings from that source; a real failure (the token can't read the alerts, a rate limit, an outage) instead exits 1, which the dashboard's work-sources panel shows as "couldn't read" rather than a false zero.

6. **Review and edit the local `config.json` file in this repository** (the one at `~/Code/Poetic-Poems/agent-ops/config.json` if you cloned it there). This is the agent system's own configuration file, not the target repos' config files. The main things to check are the `repos` list (which repositories and work sources to scan), the `pr_label`/`branch_prefix` values, and the timeout/cooldown settings if you want to tune behaviour for your environment.

7. **Install the crontab:**
   ```bash
   (crontab -l 2>/dev/null || true; echo "AGENT_OPS_ROLE=active"; echo "0 * * * * $HOME/Code/Poetic-Poems/agent-ops/agent-cycle.sh >> $HOME/.local/state/poetic-agents/cron.log 2>&1") | crontab -
   ```
   The `AGENT_OPS_ROLE=active` line is what marks this machine as the one that
   runs unattended cycles (see "Which node runs the cycles" below). Without it
   every tick stands down, which is the point: only one machine may spend.
   Verify it was installed successfully:
   ```bash
   crontab -l
   ```
   You should see a line containing `Poetic-Poems/agent-ops/agent-cycle.sh` in the output. Then confirm that cron's PATH can reach Claude:
   ```bash
   env -i HOME="$HOME" PATH="$HOME/.local/bin:$HOME/.claude/local:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" /bin/bash -lc 'command -v claude && claude -V'
   ```
   If this still fails, fix the PATH in the crontab (or install a symlink in `~/.local/bin`) before relying on scheduled runs.

## Checking an installation

```bash
./scripts/doctor.sh
```

Checks the whole installation in one pass and says what is wrong before a
cycle finds out the expensive way: your `config.json` against
`config.schema.json`, the rules that hold *between* config keys, the model
ids, the shipped and overridden prompts, the toolchain, the directories the
pipelines write to, the rendered crontab, the GitHub access your token
actually has — including whether it can *push*, not just read — and whether
`claude` is logged in.

Four verdicts:

- **`ok`** — checked and sound.
- **`warn`** — it will run, but something here will surprise you later: a
  label that does not exist in a repo (so the pipeline acts and you never see
  the label), a prompt override pointing at a file that is not there (so that
  stage quietly runs on the shipped prompt), a `timeout_*` or `inactivity_*`
  key set once and forgotten, which pins that cap and turns off its
  self-tuning for good.
- **`fail`** — the pipeline will not run, or will run on something other than
  what you configured. Exit status 1. This is what a repository your token
  can read but not push to gets, and what an archived repository gets
  regardless of permissions — both cost a cycle its work at the push, after
  it has already claimed and implemented the item.
- **`skip`** — the check needed something it could not reach, and is neither
  passed nor failed. `claude auth status` not answering with the expected
  shape — an older CLI with no `auth` subcommand, say — is a `skip`, not a
  `fail`: a probe that cannot answer is not evidence of a fault.

It also renders a trial crontab — `deploy/docker/render-crontab.sh` into a
`mktemp -d` it removes afterwards — against the config being checked, so a
broken template or an impossible `schedule` (every minute of the hour
excluded, say) shows up here rather than on the node's own cron. A clean
render reports the cycle, review, heartbeat and background-timer
(`state_sync_push_minutes`, `state_sync_fetch_minutes`, `log_rotation_minute`)
minutes the config asks for, and says whether the cycle minute came from an
explicit, allowed `CYCLE_MINUTE` or was hashed from the node's name — worth
reading closely on a laptop checking `--config PATH` for a node it is not
running on, since the hash is taken from *this* host's name, not the target
node's. It also lists any repository whose `nice` biases the walk away from
0, naming the multiplier that applies to its effective age.

```bash
./scripts/doctor.sh --offline          # config, toolchain and crontab only, no network
./scripts/doctor.sh --unattended       # full GitHub section, no model spend — what the hourly cron line runs
./scripts/doctor.sh --quiet            # warnings and failures only
./scripts/doctor.sh --config /tmp/new.json   # a config you have not deployed yet
```

Run it after editing `config.json`, on a new node before its first cycle, and
whenever a cycle does something the configuration does not explain. It is
read-only bar three things it declares: the state and workspace directories
your config names, which it creates in order to prove it can; the trial
crontab above, rendered into a `mktemp -d` it removes when done; and, under
`--unattended` only, `state_dir/.doctor-status.json`. Every GitHub
call it makes is a read (a GET, even the one that asks about *write*
access) — so it is safe to run against a live node, including mid-cycle.

A node also runs `--unattended` itself, unprompted, once an hour
(`deploy/docker/crontab.tmpl`) — the same checks above, minus the two that
spend (Claude credentials, the stream-flushing probe), so a configuration gap
that only shows up against a live repository (a `Priority` field missing a
band, say) does not go unseen between one operator-invoked pass and the
next. Its result reaches the **Doctor** section of the dashboard (see
Monitoring below), not your terminal.

That hourly pass also reads how many days remain on this node's
PAT — GitHub states its expiry on every authenticated response — and records
it for the dashboard, amber under 7 days; a node whose own token falls under
that threshold escalates once (an issue at the pipeline's configured
destination), the same route a crash loop or a dead credential already
escalates through, so a token's own expiry date is never again a fleet-wide
outage nobody saw coming (agent-ops#691, agent-ops#694).

Inside a container node, run it there rather than on the host, since that is
where the toolchain and the credentials are:

```bash
docker compose exec scheduler /app/scripts/doctor.sh
```

## Operation

### Dry run (no agents launched)
```bash
./agent-cycle.sh --dry-run
```
Completes stand-down checks, repo ordering, and coordinator selection, then exits. Prints the selected work order.

### One cycle (foreground, verbose)
```bash
./agent-cycle.sh --once
```
Launches implementer and reviewer in the foreground. Leaves the PR and workspace for inspection.

### Restrict to one repo (for testing)
```bash
./agent-cycle.sh --repo poetic
```

## Pausing the pipelines

Each node runs the pipelines from the image baked into it, not from a
checkout, so editing this repo no longer risks a running cycle (that hazard
belonged to the old host install; see [Development](../contributing/README.md#development)). What the
switch is for now is standing the fleet down deliberately — around a rollout
that would otherwise roll a node mid-cycle, or simply to stop spend. It does
so everywhere at once. On a container node you drive it through the scheduler:

```bash
docker compose exec scheduler /app/agent-cycle.sh --disable "rolling out PR #NN"  # expires after disable_default_ttl
docker compose exec scheduler /app/agent-cycle.sh --disable "big refactor" --for 8h  # or 90m, 2d, or `forever`
docker compose exec scheduler /app/agent-cycle.sh --disable "code freeze" --until "2026-08-10 18:00"  # or any GNU date -d string
docker compose exec scheduler /app/agent-cycle.sh --status   # what's set, and is anything running?
docker compose exec scheduler /app/agent-cycle.sh --enable   # resume
```

(From a shell on the node — `docker compose exec scheduler bash` — the bare
`./agent-cycle.sh …` form works, since `/app` is the working directory.)

The switch is one file (`$state_dir/disabled.json`) shared by **both**
`agent-cycle.sh` and `review-cycle.sh` — they run out of the same tree, so
stopping one and not the other stops nothing much. `agent-cycle.sh` is the only
way to set it; `review-cycle.sh` only obeys it. And, by default, it reaches
the whole fleet: `--disable` also publishes `fleet/disabled.json` to the state
repository (warning loudly if it cannot), every node checks that flag at
cycle start, and `--enable` clears both levels — so one command from any
node stands the entire operation down, or up. Add `--this-node` to either to
keep the effect on the node you typed it on — see [Taking one node out while
the rest keep working](../contributing/README.md#taking-one-node-out-while-the-rest-keep-working).

Three things worth knowing:

- **Disabling stops the *next* cycle, not one already running.** `--status`
  tells you whether a cycle is in flight, and `--disable` warns you if there
  is. Wait for it to finish before recreating a container by hand — a manual
  `up -d` (or `restart`, or `down`) kills a cycle mid-flight. A watchtower
  roll no longer does: its pre-update hook reads the same locks `--status`
  reads and defers the roll until they are free.
- **A disable expires by default.** The point is not tidiness: an agent that
  disables the pipeline and then dies would otherwise stop every future cycle
  silently — "no PRs" looks exactly like a quiet week. The TTL turns a
  forgotten switch into a few lost cycles. Use `--for forever` when you mean
  it, and `--enable` when you're done. `--until <timestamp>` is an absolute
  alternative to `--for`'s relative duration — give both and the later
  deadline wins, with a warning saying which.
- **A reason is required**, because the next person wondering why nothing has
  happened is entitled to one. It shows up in `--status`, in the log, and on
  the dashboard banner.

### Draining instead of stopping

`--disable` stops everything, in-flight work included. `--drain` is the
gentler alternative: it stops new work being picked up, but keeps finishing
whatever pull requests are already open — a changes-requested review to
answer, a merge conflict to rebase, a dequeued pull request to fix, an
abandoned draft to complete — until every configured repo has nothing left to
finish. It then rests there, ticking on future cycles without picking up
anything new, rather than exiting:

```bash
docker compose exec scheduler /app/agent-cycle.sh --drain "clearing the backlog before a Kubernetes migration"
docker compose exec scheduler /app/agent-cycle.sh --status   # DRAINING (N left) → DRAINED
docker compose exec scheduler /app/agent-cycle.sh --enable   # resume ordinary intake
```

Same `--for`/`--until`/`--this-node` handling as `--disable`, and the same
fleet-wide-by-default reach; `--enable` (or `--enable --this-node`) clears
either mode. The two modes never coexist quietly: issuing `--disable` while a
drain is running tightens it to a full stop immediately, and issuing `--drain`
while a plain stop is active is refused — `--enable` first, if you actually
want to switch from stopping to draining. That refusal covers a stop a *peer*
set, too: a fleet-wide `--disable` blocks `--drain` on every node, not only
on the one that issued it. (`--drain --this-node` is still allowed under a
fleet stop, since it publishes nothing and the node stays down either way.)
Once every repo is at rest,
`--status`, the dashboard badge and the heartbeat all say **drained**; nothing
escalates and nothing auto-converts back to a stop — it stays that way until
`--enable` or the drain's own TTL expires.

### Lifting a usage-limit stand-down

The switch is not the only thing that stops cycles. Hitting the account's
usage limit stands the whole fleet down until `resume_at` (requirement 2.1),
and `--enable` does not touch that — they are separate states with separate
causes. `--status` reports both:

```bash
docker compose exec scheduler /app/agent-cycle.sh --status
# switch:   ENABLED — cycles will run
# record:   /home/agent/.local/state/poetic-agents/disabled.json
# cycle:    idle
# review:   idle
# limit:    STANDING DOWN — with no stated reset; each cycle probes whether it has lifted — …
```

When the message states a reset time, `resume_at` is that time and waiting is
the whole answer. When it does not — the monthly spend-cap message is the
common case — `resume_at` is this system's own guess, only an upper bound:
each cycle probes the API with one minimal request (requirement 2.1b) and
retires the stand-down by itself the moment the account answers, so a limit
that was really an exhausted 5-hour session window clears within one cycle
interval of its rollover, not a day later. Such a limit still has two exits,
and you choose:

- **wait**, and let the probe notice the rollover on its own; or
- **raise the cap** at `claude.ai/settings/usage`, then tell the fleet
  without waiting for the next cycle's probe:

```bash
docker compose exec scheduler /app/agent-cycle.sh --clear-limit "cap raised"
```

That clears both carriers of the stand-down — `fleet/limit.json` in the state
repository, and the log union, via a `limit-cleared` event that supersedes the
earlier `limit-hit`. Peers pick it up at their next state-sync fetch. Run it
only once the limit is actually gone: if it is not, the next cycle simply
re-hits it and publishes a fresh stand-down.

Before the probe existed, `resume_at` passing was the only automatic exit, on
a clock the system had invented — so a cap raised in the morning still left
the fleet down until the next day. The probe asks the account itself, every
cycle; `--clear-limit` remains for when you have just raised the cap and want the
fleet back now rather than at the next cycle. The probe's verdict is in the
stand-down reason (`probe: still limited` / `probe: inconclusive`), and its
transcript is kept as `limit-probe.out` in the cycle record. To ask the
account yourself, the probe is just:

```bash
docker compose exec scheduler claude -p 'say ok'
```

## Which node runs the cycles

The pipelines run on any number of machines — a laptop, a cloud VM, several —
and **any number of them may cycle at once**: per-item claims (requirement
17a) keep concurrent actives off each other's work, and per-node minute
offsets (D5) keep them from even firing together. The environment variable
`AGENT_OPS_ROLE` says whether *this* machine spends unattended:

```bash
AGENT_OPS_ROLE=active     # this machine runs the implementation cycle and the daily review tick
AGENT_OPS_ROLE=standby    # ...anything else does not
```

On a containerised node, set `ROLE=active` in `deploy/docker/.env` — the
scheduler service passes it through as `AGENT_OPS_ROLE`, and defaults it to
`standby` when it is missing. On the host, set it in the crontab (a bare
`AGENT_OPS_ROLE=active` line above the schedule lines) or in the environment of
whatever runs the scripts. Only the exact value
`active` counts — case and surrounding whitespace are ignored, but **unset,
empty or misspelt all mean standby**. That is deliberate: a machine wrongly
standby costs skipped cycles, while a machine wrongly active spends money
nobody chose to spend. Any number of machines may be `active` at once —
per-item claims keep them off each other's work — so the role does not elect
a leader; it says whether *this* machine spends unattended.

A standby tick writes one line to the cron log and exits; it creates no cycle,
logs no event, and spends nothing. A standby is not idle, though — it
publishes its heartbeat and follows every peer's memory (see [Keeping every
node warm](#keeping-every-node-warm)), so promoting it is one variable, not a
hand-off.

What the role does *not* stop:

- `--dry-run` and `--once` — a human asking for a cycle is not an unattended
  one, and both run on any machine.
- `--disable`, `--enable`, `--clear-limit` and `--status` — the switch and the
  usage-limit stand-down are shared state, and must be readable and settable
  from wherever you happen to be.
- The dashboard, which is worth serving on every node.

## Keeping every node warm

A node that knows only its own history would re-try what a peer has already
tried and re-learn every no-op the hard way. So every node publishes its
memory, and every node follows everyone else's.

`scripts/state-sync.sh` works through the private repository named by
`state_repo`, one branch per node, in two modes — both on every node:

| Mode | When | What |
|---|---|---|
| `push` | every five minutes, and at the end of every cycle | publishes `state_dir` as this node's own `nodes/<NODE_NAME>` branch, stamped with a heartbeat (`{node, role, ts, last_cycle, version, compose, image, switch, mirror}`) |
| `fetch` | every seven minutes | materialises every peer's branch under the peers directory, whole, and prunes a peer whose branch is gone |

Before either mode touches its local mirror of the state repository, it
checks that mirror's object store (`git fsck --connectivity-only`) rather
than trusting a `.git/` directory that merely still exists: a host whose
disk has quietly corrupted a loose object gets that checkout discarded and
rebuilt from source on the spot, and the rebuild is recorded in the
heartbeat's `mirror` field so a repeat is visible rather than silent
self-healing.

What travels is the memory: `log.jsonl`, `review-log.jsonl`, `cycles/`,
`reviews/`, the switch, the cron logs. What stays behind is anything local or
derived — the live locks (peers read logs, never locks), the generated
dashboard, and each node's own sync log. Each branch keeps the newest
`cycles_retained` cycles and is a single amended commit, so the repository
does not grow; your own `state_dir` keeps the longer record, pruned to
`state_local_cycles_retained` by the same push. No two nodes share a branch,
so pushes cannot collide and nothing arbitrates them.

What travels is also redacted first: every file the push commits goes through
the same pass the dashboard applies to its own payload (`lib/redact.sh`), so
`/home/<user>` becomes `~` and anything token-shaped becomes
`[REDACTED-TOKEN]`. The state repository is private, but it keeps what it is
given indefinitely — `log.jsonl` is never rotated — so this is the backstop
for a token that reaches a stage's own output.

The pipelines read the **union** of all those logs — a blocked item, a void
verdict, a no-op fingerprint or a usage-limit hit learned by any node stands
the rest of the fleet down (or spares it a re-check) within one fetch
interval. The union is advisory speed; the per-item claims are the lock
underneath. Cross-node work arbitration has no other mechanism — there is no
lease and no leader.

Every node needs a `GH_TOKEN` that can read and write the state repository.
Leave `state_repo` out of `config.json` and none of this happens at all.

## Skipping no-op cycles

The Co-Ordinator costs the same to say "nothing to do" as it does to select
work — about 2½ minutes of Haiku, reading the configured repositories. Firing every
`schedule.cycle_interval_minutes` (15 by default; see [Configuration](../../reference/configuration.md#configuration)) instead
of once an hour is only affordable because of this check: without it, a quiet
week would be a Co-Ordinator call roughly every 15 minutes, all of them paid
for, purely to hear "nothing changed" again.

So before launching it, the Script fingerprints everything the Co-Ordinator's
verdict depends on: each repo's head commit, its pre-fetched findings, its open
issues (with labels, assignees and `Priority`), the conclusion of each workflow's latest
run, its open PRs (a PR is a claim), the blocked and void lists, the selection
config, and a hash of `prompts/coordinator.md` and any `prompt_overrides.coordinator`
files you've configured (see [Prompt overrides](../../reference/configuration.md#prompt-overrides)). If that fingerprint matches the
one recorded against the last `none-selected`, nothing the Co-Ordinator reads
has moved, so its answer cannot have changed — the cycle stands down for the
price of a few `gh` calls.

The claim is only ever "nothing changed", never "there is no work". If anything
at all is different — including a repo the Script couldn't read cleanly — the
Co-Ordinator runs. And `none_selected_recheck_hours` forces it to run anyway
once that long regardless, so if some future work source is ever missed by
the fingerprint, the cost is a bounded delay rather than a pipeline that has
quietly stopped picking up work forever.

`--dry-run` and `--once` always ask the Co-Ordinator: a human asking for a
cycle wants an answer, not a cached verdict.

```bash
# Why did a cycle stand down?
jq -r 'select(.event == "stand-down") | "\(.ts)  \(.reason)"' \
  ~/.local/state/poetic-agents/log.jsonl | tail -5
```

## Diagnosing a cycle

### See the log
```bash
tail -f ~/.local/state/poetic-agents/log.jsonl
```
One event per line (JSON). See `docs/IMPLEMENTATION-PIPELINE-SPEC.md` (requirement 33) for event types and fields.

### Blocked and void items
Two different reasons the pipeline will skip an item, with two different
remedies:

- **Blocked** — real work, something is in the way. The Co-Ordinator re-checks
  these itself and clears them (an `unblocked` event) once the impediment has
  gone, so usually you need do nothing. A block also clears the moment the
  *work* goes: each cycle, an item whose issue has been closed, whose pull
  request has been merged, whose tech-debt entry now reads `resolved` or
  `not-debt`, whose project-review recommendation is named by a merged pull
  request, or whose implementation-plan task is checked off in the plan
  document, is unblocked deterministically, logged `by: "work-gone"` with the
  fact that decided it. So finishing something by hand is enough to take it off
  the list — you never have to tell the pipeline you did. A block declared with
  a structured [`Blocked-by:`](../working-with-pullwright/README.md#cross-item-dependencies) reference clears the
  same way, logged `by: "dependency-resolved"`, the moment every item it names
  is closed.
- **Void** — there is no work: the item is already done, or its premise was
  false. No agent can ever clear this, by design — the only evidence that would
  ever turn up ("it's already done") is the reason it is void, so an agent
  allowed to clear it would free the item to be rediscovered every cycle.

Because a void is permanent, one has to be earned. Every void carries the
evidence behind it, and a Co-Ordinator's void — the only kind made without
opening the repository — is checked before it is recorded: an unevidenced
verdict, or one the cycle's own candidates contradict (the pull request it calls
finished still has a diff), is recorded **blocked** instead and handed to the
Enabler, which can read the repository and settle it properly. You will see the
refusal as a `warning` on the dashboard.

Both are listed on the dashboard. The void list only ever grows, so it is shown
short: the ten newest rows, each three lines tall, with **See more** at the foot
of the table for the older ones and any row opening to its full reason when you
click it. The heading counts every void item however few rows are showing.

The dashboard's own list — and the item's void mark itself — never shrink; what
does is the copy the pipeline hands the Co-Ordinator each cycle. Once a void is
both settled — its issue or pull request closed, or its tech-debt row read
`resolved`/`not-debt` — and `void_retire_after_days` old (30 by default), it
drops out of that copy: there is nothing left for the pipeline to keep
repeating to itself about an item everyone has already finished with. `0`
switches this off. A retirement is recorded in the pipeline's own log, so a
settled verdict is never re-checked against GitHub — and once an item has
retired, reopening its closed issue or pull request is enough by itself to
put it back in front of the pipeline as a fresh, ordinary candidate; the
`unvoided` label below is the route that works while the void is still being
carried.

To reopen a void item — you believe the work has genuinely regressed, or the
verdict was wrong — **label any issue or pull request that names the item with
`unvoided`**, in that item's repo:

```bash
gh pr edit 92 -R Poetic-Poems/poetic --add-label unvoided
```

The next cycle reads the label, works out which items that issue or PR names
(from its branch, title and body — and for an issue, its own number), and
reopens any of them that are void. The item is back in the Co-Ordinator's pool
in that same cycle. Only you can do this: no stage in the pipeline ever applies
this label, which is what keeps "only a human may clear a void" true.

**Leave the label where it is** once it has worked. Nothing removes it, and
nothing needs to: the rule is self-limiting rather than one-shot, so a label
left behind costs nothing. It cannot fire twice: a label only reopens voids
recorded *before* you applied it, so an old label can never quietly clear a
fresh verdict.

If you are on a node, appending the event by hand still works, while no cycle is
running:

```bash
printf '%s\n' "$(jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{ts: $ts, cycle: "manual", event: "unvoided", item: "review-2026-07-11-R-02"}')" \
  >> ~/.local/state/poetic-agents/log.jsonl
```

Omit `repo` to reopen the item in every repo, or add it to scope the change to
one. Either way the item becomes a candidate again; if there is still no work,
the Implementer will simply void it again — with evidence this time.

**Keep `cycle: "manual"` exactly as it is** here and in any other event you
append by hand — an `unblocked`, a `limit-hit`. It is not a placeholder for a
missing id; it is the marker that says no cycle produced this record, and the
dashboard reads it as one. Give the event a timestamped id of the real shape
instead and it becomes indistinguishable from a run: the Recent cycles table
grows a row for a cycle that never started, wearing whatever badge an empty
event stream earns. `manual` keeps the record in the log tail, where it
belongs, and out of the cycle list.

### Closing an obsolete draft pull request

A draft pull request the pipeline itself raised — an abandoned draft, or one
still carrying your own unactioned review feedback — can simply stop being
wanted. If it still changes files against its base, the pipeline cannot close
it on its own say-so: `void_finishing_pr_reason` (`lib/void-guard.sh`) accepts
an open pull request as void only when its diff against the base is empty, or
when you have said the draft is unwanted yourself (below), because "this
draft is no longer wanted" is a judgement no API call can corroborate on its
own, and closing a live branch on an unexamined one has destroyed real work
before. Absent either signal, an open, still-diff-carrying draft is escalated
to you instead of closed.

To tell the pipeline it really is unwanted, **label the pull request
`obsolete`**, in that item's repo:

```bash
gh pr edit 205 -R Poetic-Poems/poetic --add-label obsolete
```

The pipeline creates the label in every repository it gathers data for, not
only the one it happens to work, at most once per `labels_ensure_interval_hours`
(default 24h), so there is nothing to set up; `scripts/doctor.sh` warns while a
repo has not got it yet.
The next time the pipeline records this item as void — typically the Enabler,
re-examining the escalation this draft raised — the label corroborates the
void despite the diff, and the pull request is closed with a comment naming
the label as why. **Only you can apply this label: no stage in the pipeline
ever applies it itself**, exactly like `unvoided` above — a stage that could
apply it would be corroborating its own judgement, which is what the guard
exists to stop.

**A machine-checkable alternative exists too**, but only once a repository has
climbed to `merge_autonomy` level `agent-merges-all` (issue #413, WI-10;
`docs/reviews/2026-08-14-autonomy-investigation.md` §5.5): a two-touch
confirmation across two *independent* Enabler engagements, at least 24 hours
apart, each citing structured `{ref, path, expect, pattern}` evidence that
resolves live against the repository — the same evidentiary bar a `void`
itself needs, applied twice rather than once. The first Enabler to judge a
draft unwanted records a `draft-obsolete-flagged` event rather than voiding it
outright; a second, later engagement's own void of the same item then
corroborates against that flag exactly as it would against your label. This
is not a second way for the pipeline to label anything — it never writes
`obsolete`, and one engagement flagging a draft can never also be the void
that closes it — it is a second, independent Enabler pass standing in for
your label at the trust level where the installation has decided that is
enough. Below `agent-merges-all`, or for any pull request nobody has flagged,
the label remains the only way to tell the pipeline a draft is unwanted.

### Blocked items and the Enabler

Some blocked items the pipeline cannot ever clear by itself: the deploy check
needs a secret only you can set, a production bug needs logs only you can see, a
milestone waits on a decision that is yours to make. Left alone those items sit
blocked indefinitely, and nothing tells you they are there.

This is also where a pull request goes when a stage could not finish it — a
Reviewer that could not certify it, a handoff that did not take. **A pull
request that is not ready for review is the pipeline's problem, not yours**, and
you will hear about it only as an escalation issue. You are never expected to
find work by noticing a draft.

So once an item has been blocked for a few cycles, the **Enabler** — one Opus
pass, engaged rarely — reads it properly: the item, the whole thread, the
failing run. It then does one of four things:

- **unblocks it**, if whatever was in the way has demonstrably gone (the
  dependency merged, the check went green) — the item is selectable again next
  cycle. Where the block *was* a pull request that never left draft, and its
  checks are green and its work done, the unblock also takes it out of draft, so
  it arrives in your review queue instead of sitting where nobody would look;
- **voids it**, if it turns out there was no work to do after all (it is already
  done on `main`);
- **leaves it blocked**, with a fresher account of what would unstick it;
- **raises a GitHub issue for you** — in the item's own repo, **assigned to you**
  and labelled `enabler-escalation` — when only a human can move it.

One case of that last bullet gets its own setting: an item the Enabler already
specified once, re-flagged as still under-specified — two engagements
disagreeing about whether the earlier specification is adequate. With
`escalation_autonomy` (see [Configuration](../../reference/configuration.md#configuration)) left at its
default, `always-escalate`, that still raises an issue for you, exactly as
above. Set it to `adjudicate-first` and the Enabler instead runs one further,
narrower pass first — reading only the earlier specification and the
disagreement — and either confirms the item is already specified (no issue
raised; it just becomes selectable again) or escalates to you anyway when it
genuinely cannot tell.

That pass runs **once per item**. If the same item comes back disagreed-about
a second time, it is raised for you as it always would have been, without a
second pass — so the setting can save you an issue, but it cannot quietly keep
an item circulating between two models forever. Acting on an escalation about
the item (closing the issue it raised) gives it a fresh pass, on the same
terms every other "one per human touch" rule here uses.

Set `escalation_autonomy` to `decide-tactical` instead and the Enabler's
narrower pass widens to *every* escalation, not only a re-flagged
specification — an ordinary blocked item as much as a refinement disagreement.
It reaches one of three answers: **settle** it (the same "nothing needs
deciding" outcome `adjudicate-first` already reaches, now available to any
item), **decide** it — a genuine tactical trade-off among options the item's
own record already names, which the pipeline may answer on its own authority
and does, posting the decision as a comment where the item is a GitHub issue —
or **escalate** it to you regardless, when the question turns out to need
something only you can supply. An owner-only decision — spending money,
touching a credential or a permission, a product or roadmap call, anything
this system's own spec reserves to you by name — always escalates, at every
setting; `decide-tactical` only ever widens which *tactical* questions the
pipeline may answer for itself, never that boundary. Bounded per distinct
reason rather than once per item: a fresh question about an item that was
already decided over something else still gets its own pass, up to
`escalation_adjudication_max_passes` passes for that item in total (see
[Configuration](../../reference/configuration.md#configuration)) — and closing an escalation about it grants
one further pass beyond that cap, each time you do. The same question a
second time still comes to you, on the same terms `adjudicate-first`'s own
bound already uses.

Before it weighs any of that, the pass reads what has already been decided:
the installation's standing-decisions file (`standing_decisions_file` — one
dated line per answer you have given the pipeline), this repository's own
`pw::decision` records, and its most recently closed escalations. A question
you have already answered — for a sibling item, or as a principle — is
answered the same way again, as a `decide` that cites the earlier answer,
rather than escalated afresh. Keep that file current: it is the cheapest
lever this ladder has. And only two things reserve a choice to you: the
`pw::owner-decision` label on an issue, or an `Owner decision: yes` line in a
record — a body that merely calls a choice "one for a human" does not, a
threshold nobody has set is set by the pass rather than asked, and an option
the pipeline may take is taken even when its siblings would need you.

**One rung further: `decide-with-veto`.** Set `escalation_autonomy` to
`decide-with-veto` and the same pass runs, at the same model, over the same
escalations — with two things added to what it may reach, and one change to
when a decision takes effect.

The two additions, and nothing else. It may **accept a residual** — an
exposure or a risk left over in a repository you own, where the issue's own
filer already wrote down what they would do by default and where nothing
about the answer mints, rotates, edits or grants a credential, a secret, an
App, a ruleset, a permission or an account. And it may **corroborate a
void**: say, of a draft pull request this pipeline raised and abandoned, that
it is genuinely unwanted — the one judgement the void machinery otherwise
only accepts from your own `obsolete` label on the pull request. Everything
else stays exactly where it was: money and caps, licence and pricing,
roadmap decisions, ongoing obligations you would have to keep, this system's
own trust boundaries, an account the pipeline does not hold, and anything you
reserved with the `pw::owner-decision` label or an `Owner decision: yes`
line — all still yours, at this rung as at every other.

**The veto moves in front of the act.** Where a decision at this rung carries
something to *do* — closing that abandoned draft — the pipeline does not do
it straightaway. It records the decision, files the log issue with the
instant the act becomes due, and waits `decision_veto_window_hours` (24 by
default; `0` means the next cycle). Reopen the log issue before then and the
act is cancelled, with the cancellation written to the record, and nothing
ever happened. A decision that merely *accepts* something carries nothing to
do, so it takes effect at once, exactly as at `decide-tactical` — reopening
its log issue afterwards is still the correction.

The product default stays `always-escalate`: every rung above it is
something you switch on, per installation or per repository, and this one
most of all.

**Every `decide` verdict also files a closed, unassigned issue** labelled
`pw::decision` — a durable log of the decision, not a further ask — with the
decision, the rationale and the options considered — and, where the decision
carries an act, what that act is and when it becomes due. Reopen it to veto
the decision: the pipeline re-blocks the item, comments on it, flips any open
pull request for it back to draft, and waits for your own decision, posted
as a comment on the reopened issue, before you close it again. No window —
a reopen is honoured whenever it comes, and a reopen that arrives before an
act is due cancels the act outright. If the item has already merged or
closed by the time you veto it, there is nothing left to re-block, so the
pipeline instead files a fresh "revisit: …" issue quoting your comment. Every
decision taken in the last 7 days shows on the dashboard's Decisions panel,
vetoed ones marked as such, and `--status` carries a one-line count of
decisions taken in the last 24h.

**Closing that issue is the whole protocol.** Do the thing it asks, close it, and
say nothing: the next cycle notices the closure, the Enabler re-checks the item
against reality, and the work resumes (or the issue's thread gets a note saying
what is still missing). There is nothing else to update, no log to edit, and no
reply expected. The issue itself says all of this, in case you meet one before
you meet this page.

Two details worth knowing:

- The issues are assigned on purpose, and not only so you see them: an assigned
  issue is excluded from the pipeline's own `issues` work source, so the system
  can never pick up its own request for help as work to do.
- Every escalation is visible on the dashboard, in the blocked table's
  *Escalated* column — a link where the pipeline is waiting on you, and the
  Enabler's last verdict where it is not.

`--dry-run` never engages the Enabler: a cycle that promises to change nothing
must not raise an issue. `--once` does engage it, which is how you watch one
happen:

```bash
# What the Enabler has been doing, and what it asked for
jq -r 'select(.event == "enabler-examined" or .event == "escalated")
       | "\(.ts)  \(.event)  \(.item)  \(.outcome // .issue_url // "")"' \
  ~/.local/state/poetic-agents/log.jsonl | tail -10
```

### Refined items and the Refiner

Most items never need the Enabler at all. Before an under-specified item would
ever have to be blocked and wait several cycles, the **Refiner** — a cheap
model, engaged every cycle there is unrefined work — looks at every new
candidate whose source usually needs one (`issues` by default; see
`refinement_policy` below) and writes a specification for it: the goal, what
is in and out of scope, concrete acceptance criteria. For an issue that lands
as one comment, and the issue picks up the `refined` label; for anything else
it travels the same way an Enabler-written specification does — in the log,
pasted into the work order when the item is selected.

Where the Refiner cannot write one without deciding something that is yours —
a credential, a product choice, information that exists only in your head —
it declines instead, and the item follows the same path "Items nobody has
specified" describes below.

`refinement_policy` decides, per work source, whether an unrefined item may be
selected at all: `required` (never — it waits for the Refiner), `preferred`
(a refined item is ranked ahead of an equivalent unrefined one, but an
unrefined item may still be picked) or `exempt` (the source already carries
its own specification — a merge conflict, a review comment — and this does not
apply, the default for every source not named). Only `issues` and the sources
the Script already fetches in full — findings, review feedback, merge
conflicts, abandoned drafts, register hygiene — are ones the Refiner can
actually reach; setting a stricter policy for `tech-debt`, a plan task or a
review recommendation still shapes ranking, but nothing writes those a
specification yet.

```bash
# What the Refiner has written lately
jq -r 'select(.event == "item-refined" and .by == "refiner")
       | "\(.ts)  \(.repo)  \(.item)  \(.comment_url // "spec recorded in the log")"' \
  ~/.local/state/poetic-agents/log.jsonl | tail -10
```

`--dry-run` never engages the Refiner, for the same reason it never engages
the Enabler. `refiner_model` empty switches the stage off entirely — every
item then waits for the ordinary blocked/Enabler path below.

### Items nobody has specified

There is a third reason the pipeline skips an item, and it used to be invisible:
nobody ever wrote down what the work is. "Tidy up the sync script" names no end
state; an issue that is really a question has no acceptance criteria; a
milestone task waits on a decision that is yours. The Co-Ordinator cannot rank
any of those, so it skipped them — and every cycle after it skipped them too,
forever, without recording anything. Nothing looked wrong. The work simply
never happened, and you were never told it was waiting on you.

Now the Co-Ordinator reports such an item — or the Refiner declines one it was
given, or an Implementer gets partway into one and finds the brief itself
insufficient — and the Script records it as blocked with what is missing.
Nothing else changes about that cycle. If the item is a GitHub issue it also
picks up three labels — `needs-refinement`, `blocked` and
`blocked:needs-refinement` — so you can see the same thing the pipeline can
from a filtered issue list, and the item drops off the pipeline's own
candidate list the same way any other `blocked` issue does. If the item had
already been marked `refined`, that label comes off too: the specification it
named did not hold up.

```bash
gh issue list -R Poetic-Poems/poetic --label needs-refinement
gh issue list -R Poetic-Poems/poetic --label blocked:needs-refinement
```

After the usual few cycles — during which you, or the pipeline's own re-check,
may well settle it first — the Enabler picks it up and does one of three things:

- **specifies it**, where that can be done without deciding anything that is
  yours to decide: one comment on the issue carrying the goal, scope, acceptance
  criteria and relevant files, or, for a tech-debt entry or a review
  recommendation, a specification carried in the log and pasted into the next
  work order. The item is unblocked and the label comes off;
- **asks you**, through the ordinary escalation issue — a separate one, never
  the work item's own issue, and cross-linked from it where the item is an
  issue. Answer in comments on the escalation and then close it: the same
  protocol as any other escalation, and your answers are what let the next
  engagement finish the job;
- **leaves it**, where you have already parked the decision deliberately (an
  open question with a decide-by date in a plan or roadmap). It will not ask you
  to re-make a decision you have made.

An item is specified **once** between times you touch it. If the Co-Ordinator
flags an item the Enabler has already specified, that is two models disagreeing
about whether the specification is good enough, and you get an escalation rather
than a second rewrite.

```bash
# What the pipeline has specified for itself lately
jq -r 'select(.event == "item-refined")
       | "\(.ts)  \(.repo)  \(.item)  \(.comment_url // "spec recorded in the log")"' \
  ~/.local/state/poetic-agents/log.jsonl | tail -10
```

**You can flag an item yourself**, rather than waiting for the Co-Ordinator to
notice it. Apply `needs-refinement` to the issue directly:

```bash
gh issue edit 52 -R Poetic-Poems/poetic --add-label needs-refinement
```

The next cycle scans every repo's issues for the label, and — provided the
issue is still open and nothing already blocks it — records the same kind of
block a Co-Ordinator's own report would, naming you as the one who applied it.
From there it follows the ordinary path above: a few cycles' grace, then the
Enabler. **Take the label off while the block is still open** and that clears
it the same way closing an Enabler escalation does — the item is selectable
again next cycle, no need to touch the log yourself. This only works for a
block you created this way: taking the label off an item the pipeline blocked
on its own report does nothing, by design — that block's label is a one-way
projection of state the log already holds, not a second way to change it.

### See stage transcripts
```bash
ls -la ~/.local/state/poetic-agents/cycles/
```
Each cycle gets a directory (`<cycle-id>/`) with three files per stage that
ran: `<stage>.out` (the run's final JSON envelope — this is what gets
parsed), `<stage>.out.stderr` (diagnostics), and `<stage>.stream.jsonl`
(every event the run emitted, one JSON object per line, written as it
happened). The stream is the one to read when a stage did not finish: the
envelope is written only at the very end, so a stage killed at its timeout
leaves an empty `.out` and a stream showing exactly how far it had got.
Streams stay on the node that produced them — they are never replicated to
the state repository — and are pruned to the newest
`state_local_streams_retained` cycles, well ahead of the cycle directories
themselves. A push that finds `state_dir` below `min_free_workspace_bytes`
prunes them further still, oldest cycle first, down to the newest cycle's
alone if that is what it takes to get back over the floor: they are read only
by the cycle that wrote them, so under disk pressure they go before the node
does (requirement 2.5). When a cycle
pre-fetches findings, that directory also holds `findings-<owner>_<repo>.json`
(the normalised Dependabot + code-scanning alerts the Co-Ordinator was given).

### Why a stage was stopped
A stage has two caps, and they mean different things:

- **the backstop** — the stage ran for that long, whatever it was doing.
- **the liveness watchdog** — the stage produced no output *at all* for that
  long, and was treated as wedged. `0` turns it off and leaves the backstop as
  the only cap.

**Neither is a number you set.** Both are worked out per
(actor, repository, model) from the pipeline's own history, once per cycle,
and announced on the stage's `stage-start` event with where each came from.
A repository nobody has run before gets a shipped prior, so nothing has to be
chosen for it. `scripts/doctor.sh` prints the current table under **Stage
budgets**.

The `timeout_<actor>` and `inactivity_<actor>` keys are overrides, and they
win permanently — set one and that cap stops adapting, which is why doctor
warns about it. `lock_stale_after` is a floor under a threshold derived from
the backstops in force, not a value to keep in step with them by hand.

A third thing stops a stage and is not a cap at all: the account saying no.
When the stream reports a usage limit, the stage is stopped there and then,
rather than holding the node for the rest of its cap while every call it makes
is refused.

All three exit `124`, so the `stage-end` event carries `kill_reason` —
`backstop`, `inactivity` or `rate-limit` — to say which, and a watchdog kill
also logs a `warning` you will see on the dashboard. They want different
responses: a backstop kill on a stage that was still emitting says the cap is
too tight; a watchdog kill says the stage stopped, so read
`<stage>.stream.jsonl` to see what it was doing last; a rate-limit stop says
nothing about the caps, and the stand-down it writes carries the real reset
time the account gave rather than this system's estimate of one.

`scripts/doctor.sh` checks that the stream really flushes as it runs on this
node, because a runtime that buffered it would leave the watchdog with no
signal and kill every healthy stage. That check makes one call to the cheapest
configured model; `--offline` skips it.

### See the security & code-quality findings
The Co-Ordinator's security and code-quality candidates come from a
deterministic pre-fetch, not the model, to save credits — the Script runs
`scripts/gather-findings.sh` once per repo and injects the result. Run it
yourself to see exactly what the agents see:
```bash
./scripts/gather-findings.sh Poetic-Poems/poetic
```
It prints a JSON array of the repo's open Dependabot alerts and code-scanning
alerts (security-severity ones tagged `"source":"security"`, the rest
`"source":"code-quality"`), most severe first. It always prints valid JSON,
and exits 0 when a repo simply has the features off; a real failure to read
them (a rate limit, an outage) is different and exits 1, so the dashboard can
tell the two apart rather than showing a repo with nothing to report.

## Repository review

A second, independent pipeline — the **repository-review** pipeline, named
because each run takes one target repo, on its own, with its own clone,
branch, report set and pull request — runs a full **project review** of that
repo on a configured cadence
(`repository_review.defaults.min_days_between_reviews`) and opens a pull
request with the results — a set of Markdown reports (summary, findings,
prioritised recommendations, ready-to-use improvement prompts). Debt the
review surfaces is filed straight to GitHub as `pw::type:tech-debt`-labelled
issues while the run is under way, listed under the pull request's `Defers:`
section rather than committed alongside it, so the implementation pipeline's
Co-Ordinator can pick those issues up through its own `issues` source without
waiting for the review PR to land; merging that PR then lands the improvement
prompts, which you can hand to the `project-remediation` skill.

It reuses the implementation pipeline's machinery (ephemeral clones, the
shared usage-limit stand-down, the same lock/timeout discipline) but has its
own Script (`review-cycle.sh`), lock, PR label, and cron entry. It **defers
to** a running implementation cycle and shares the one usage-limit signal, so
the two never spend quota at the same moment. The `project-review` skill it
runs is vendored at `.claude/skills/project-review/` and staged into each
ephemeral clone at run time (never committed to the repo under review).

### Review instructions and context

By default a review runs identically everywhere: five facts about the repo,
plus the shipped prompt and skill. `review_instructions`, `review_context`
and `repo_context_file` let you tell a review what to weigh in *this*
repository and what it is for, without forking the skill.

```json
"repository_review": {
  "defaults": {
    "review_instructions": ["review-instructions/poetic-fiddle.md"],
    "review_context": ["review-context/poetic-suite.md"],
    "repo_context_file": ".github/REVIEW-CONTEXT.md"
  }
}
```

- **`review_instructions`** — an array of paths, appended in order, to text
  that becomes **instructions**: what to weigh, what to ignore, which
  standards apply to this repository. Installation-held only, resolved
  against `state_dir` exactly like [prompt overrides](../../reference/configuration.md#prompt-overrides). A
  path that does not resolve is a fail-fast error at cycle start and at
  `scripts/doctor.sh` — not silently dropped, because this text changes how
  strictly a review judges.
- **`review_context`** — the same shape, but for **context**: what the
  repository is for, its domain, its relationships to other repositories,
  its consumers and deployment. Same resolution and fail-fast behaviour as
  `review_instructions`.
- **`repo_context_file`** — a path *inside the repository under review*
  (e.g. `.github/REVIEW-CONTEXT.md`), read from the ephemeral clone and
  added as **context** — never instruction. Unset by default; a missing file
  is simply absent, not an error, since it is entirely optional for a
  repository to opt in.

**Why the trust boundary is asymmetric.** Only `review_instructions` and
`review_context` — both installation-held — can change how strictly a review
judges. A repository's own `repo_context_file` can only ever add background:
text a reviewed repository's contributors can edit is trustworthy only as
far as a pull request into that repository is, so nothing read out of the
clone is ever admitted as instruction. The Reviewer-Agent receives every
resolved source labelled with its own origin — `"source": "config"` or
`"source": "repository"` — and is told in its own prompt to treat a
`"repository"`-sourced entry as evidence about the repository, never as a
command. `review-stage-start` records every resolved source and a sha256 of
its text, so a past review's inputs are reconstructable without the log
carrying arbitrary file content. All three keys resolve per repository on
the same `defaults`/`repos[]` rule as the rest of `repository_review`.

### Install

Create the review PR label in each configured repo (once):
```bash
gh api -X POST repos/Poetic-Poems/<repo>/labels \
  -f name='project-review' -f color='5319e7' \
  -f description='Raised by the project-review pipeline'
```

Add the cron entry. **Recommended** — a daily tick guarded by
`min_days_between_reviews`, robust to a machine that sleeps through a strict
weekly tick:
```bash
(crontab -l 2>/dev/null || true; echo "30 3 * * * $HOME/Code/Poetic-Poems/agent-ops/review-cycle.sh >> $HOME/.local/state/poetic-agents/review-cron.log 2>&1") | crontab -
```
This needs the same `AGENT_OPS_ROLE=active` line in the crontab as the
implementation cycle ("Which node runs the cycles"); one line covers both
pipelines.
The skip-guard ensures this actually reviews each repo only about once a week.
For a strict weekly tick instead, use `30 3 * * 1` (Mondays 03:30) — simpler,
but a missed Monday tick skips the whole week.

### Operate the repository review

```bash
./review-cycle.sh --dry-run        # show which repos would be reviewed; launch nothing
./review-cycle.sh --once           # one run in the foreground, verbose
./review-cycle.sh --repo poetic    # restrict to one repo
tail -f ~/.local/state/poetic-agents/review-log.jsonl   # this pipeline's own event stream
```
Stage transcripts land in `~/.local/state/poetic-agents/reviews/<review-id>/`.
The shared `limit-hit` signal is written to the implementation pipeline's
`log.jsonl`, so a usage limit hit during a review also stands the
implementation pipeline down.

See `docs/REVIEW-PIPELINE-SPEC.md` for the full specification.

## The Pipeline Monitor

A third pipeline — the **Pipeline Monitor** — reads the other two. Once a day
(`schedule.monitor_hour`), and again within the hour after any fleet
invariant fires a page, `monitor-cycle.sh` assembles a digest of everything
the fleet recorded about itself in the last 24 hours and asks a model three
questions: what is broken now, what limited throughput and which lever it
points at, and what is new.

It exists because half of what is worth knowing about a pipeline needs a
*hypothesis*, not a threshold. Anything threshold-shaped — a node stopped
publishing, a stage is failing — already has a pager invariant watching for
it. The other half is the reading that only comes from holding several
records side by side, and this is the pipeline that does that on a schedule
instead of when somebody happens to look.

**What a run produces.**

- A dated report in the state store,
  `~/.local/state/poetic-agents/monitor/<date>/report.md`, carrying the three
  readings, a triage verdict for every open `pw::pager` page, and a ledger of
  exactly what the run filed, deferred or skipped and why.
- At most `monitor_max_filings_per_run` (default 3) GitHub items, each
  carrying a stable finding key and a provenance line
  (`Monitor: monitor/<date> M-<nn>`), deduplicated against what previous runs
  already filed — so a fault that persists is restated in the report and cites
  the issue already tracking it, rather than filing a second one.

**A repeat finding promotes into a pager invariant, autonomously.** Once a
finding key has been carried by `monitor_promote_after` (default 2) or more
reports, the Script stops filing (or citing) the same finding and instead
files one `pager: add invariant <key>` tech-debt issue, carrying the
detection rule and every report's own evidence — so the fix becomes a piece
of code the fleet implements once, rather than an issue restated for ever.
The key stays flagged `promoted` in the digest until that invariant actually
exists, at which point it drops out of the digest and the report altogether.
`monitor_promote_after: 0` disables this outright.

**What it files, by class.** A **mechanical** finding — a defect with a
knowable fix — becomes a `pw::type:tech-debt` issue in the repository it
names, which the implementation pipeline's own `tech-debt` source then picks
up and works, with no human in the loop. A **tactical** finding — a
configuration lever — is proposed in the report, and *moved* only for keys you
have listed in `monitor_tactical_keys` (empty by default, so out of the box it
proposes every lever and moves none); when it does move, it moves as a
`pw::decision` record you veto by reopening. A **strategic** finding, or
anything only you can decide, becomes one escalation assigned to
`enabler_assignee`, with the options written out. That escalation is the only
path from this pipeline to you.

**What it never does.** It never closes a pager page — a page's lifecycle
belongs to the pager, which retires it when the fact behind it clears — never
edits `config.json`, never writes a label the Co-Ordinator keys on, and never
runs as a stage of `agent-cycle.sh`. It holds no Docker socket and no host
path: everything it knows about a host comes from that node's own host-facts
record.

**Cost and cadence.** Its crontab line fires hourly and stands itself down
unless the day's run is still owed or a page has fired since the last report —
a stood-down tick costs no model call at all. When a run *is* due, exactly one
node in the fleet takes it, through the same claim mechanism that keeps two
nodes off one work item. It defers to a running implementation or review
cycle, and shares the one usage-limit signal with both.

### Operate the Monitor

```bash
./monitor-cycle.sh --dry-run   # build and print the digest; launch no model, file nothing
./monitor-cycle.sh --once      # one run now in the foreground, whatever the schedule says
tail -f ~/.local/state/poetic-agents/monitor-log.jsonl   # this pipeline's own event stream
cat ~/.local/state/poetic-agents/monitor/$(date -u +%F)/report.md
```

Set `monitor_model` to `""` to switch the pipeline off entirely.

See `docs/MONITOR-PIPELINE-SPEC.md` for the full specification.

## Monitoring

### Dashboard

A local, single-page dashboard shows everything at a glance: whether a cycle
is running, whether the pipelines are disabled and why, usage-limit
stand-downs, open agent PRs and their CI status,
recent cycles with per-stage cost/duration/model (substantive cycles only —
the no-op ticks the `*/15` cadence mostly produces are summarised in one
count beneath the table instead of holding rows), failures, blocked and void
items, the work sources the Co-Ordinator sees, the hourly unattended
`doctor.sh` pass's own warnings and failures (a **Doctor** section, with a
page-top banner when it has something to say), a per-stage health verdict for
each node (a **Stage health** section — `coordinator failing (11
consecutive, last success 8h ago)` and the like — with a page-top banner and
a fleet-strip badge naming which stage: the reading a plain `cycle:
RUNNING`/idle state cannot give, since that state stays green while a
stage's own attempts keep failing and the cycle process itself keeps
completing), any fleet-level invariant currently firing (a **pager-firing**
banner naming the invariant and its evidence, with a badge on every node
card the evidence names — the same failing verdict on every node at once is
almost always the reader being wrong, not every node failing alike; the
Publisher files one deduped `pw::pager`-labelled issue per firing invariant
in `pager_repo`, closing it with a one-line comment the moment the fact
clears), how often the Script rejects a Co-Ordinator verdict — by day
and by the model that produced it, with what
the fleet spent recovering, so it is visible whether the cheap Co-Ordinator
model is paying for itself — estimated token cost by day, by
model and by actor, and the raw log — with each stage's transcript viewable
inline.

Two things are worth knowing about before you first open it. Each node's card
names **the version that node is running** — the last pull request contained in
its image, plus the commit it was built from, and a `behind` marker while the
fleet holds a newer build. (A roll waits for the cycle it would otherwise
interrupt, so nodes sitting on different images for a while is normal; a node
that stays behind is a watchtower that has stopped.) And **every pull-request
number on the page** — there, in the open-PR table, and against each cycle —
shows that PR's record: title, author, state, when it merged, the merge
commit, its labels, and the cycle that raised it. Hover to peek at it; click or
tap to open it and leave it open (a click goes to the card rather than to
GitHub — the card carries its own *View on GitHub* link, and ctrl/cmd-click
still opens the PR in a new tab).

It is **local and private**: nothing is published to the internet, there is no
server and no open port, and it costs nothing to run (it makes no model
calls). `scripts/publish-dashboard.sh` reads the pipeline's state plus live
GitHub data and regenerates a self-contained page under
`~/.local/state/poetic-agents/dashboard/`. Home paths and any token-shaped
strings are redacted, so a screenshot is safe to share.

### View it
```bash
./scripts/open-dashboard.sh
```
This regenerates the dashboard and opens it in your browser (via `wslview` /
`explorer.exe` on WSL). Or open `~/.local/state/poetic-agents/dashboard/index.html`
directly. The page auto-refreshes every `dashboard_refresh_seconds` (5s by
default) and shows how stale its data is; untick *auto-refresh* to pause it.

If your browser refuses to load the data over a `file://` URL, serve it
locally instead (loopback only):
```bash
./scripts/serve-dashboard.sh        # then open http://127.0.0.1:8787
```

### Keep it fresh
The dashboard refreshes at the end of every cycle (a hook in `agent-cycle.sh`).
To also keep it current between cycles — reflecting in-flight runs, the
lock, and live GitHub status — add a heartbeat to your crontab:
```bash
(crontab -l 2>/dev/null || true; echo "*/5 * * * * $HOME/Code/Poetic-Poems/agent-ops/scripts/publish-dashboard.sh >> $HOME/.local/state/poetic-agents/dashboard.log 2>&1") | crontab -
```

The dashboard is a **reader**: it only ever reads the pipeline's state and
GitHub, never writes into the state tree, never touches the lock, and cannot
disturb a running cycle. See `docs/DASHBOARD-SPEC.md` for its design.

### Run as a service (legacy WSL path, decommissioned)

On a containerised node the dashboard is already a service — the `dashboard`
service in `deploy/docker/compose.yaml`, restarted by Docker and reached over
the tailnet through the sidecar. Everything from here to the end of this section
is the laptop's old SysV path, retired at the cut-over and kept only as a record
of it — the laptop now serves its dashboard from the container like every other
node.

To have the loopback server start automatically when WSL starts — so
`http://127.0.0.1:8787` is always up without a foreground terminal — install
it as a SysV init script hooked into WSL's own `[boot] command`, exactly the
way `cron` and the ArtistOS Telegram bridge already are. This distro's WSL
instance does not run systemd as its init, so the service is started by WSL's
minimal built-in init, which runs the `[boot] command` from `/etc/wsl.conf`
once, as root, at startup. The server still binds `127.0.0.1` only — it opens
a loopback port, never a network one.

1. **Install the init script** — [`deploy/agent-ops-dashboard.init`](../../../deploy/agent-ops-dashboard.init)
   drops to the user named by `RUNAS` (never root) via `start-stop-daemon
   --chuid` and serves `scripts/serve-dashboard.sh` on port 8787:

   ```sh
   sudo install -m 755 deploy/agent-ops-dashboard.init /etc/init.d/agent-ops-dashboard
   ```

   `RUNAS` and `APPDIR` carry no default and must be set in
   `/etc/default/agent-ops-dashboard` before the service will start, for
   example:

   ```sh
   printf 'RUNAS=youruser\nAPPDIR=/home/youruser/Code/agent-ops\n' | sudo tee /etc/default/agent-ops-dashboard
   ```

   Its `RUNHOME`, `PORT`, `PIDFILE` and `LOGFILE` settings are ordinary
   defaults; a host that differs overrides them the same way, in
   `/etc/default/agent-ops-dashboard`, rather than editing the installed
   script.

2. **Start it at WSL boot** — add it to `/etc/wsl.conf`'s existing boot
   command, alongside cron:

   ```ini
   [boot]
   command = service cron start; service artistos-telegram-bridge start; service docker start; service agent-ops-dashboard start
   ```

   This takes effect on the next WSL restart (`wsl --shutdown` from Windows,
   then reopen). To start it immediately without restarting:

   ```sh
   sudo service agent-ops-dashboard start
   ```

3. **Check it** — output goes to `dashboard-server.log` inside `state_dir`,
   with the rest of the pipeline's state:

   ```sh
   sudo service agent-ops-dashboard status
   tail -f ~/.local/state/poetic-agents/dashboard-server.log
   ```

   (An installation that predates this and still logs beside the checkout
   just has a stale `~/Code/Poetic-Poems/dashboard-server.log` left over;
   reinstall the init script and delete it.)

Common operations: `sudo service agent-ops-dashboard restart|stop`. Only run
one instance against port 8787 at a time — a second `python -m http.server`
on the same port dies with `Address already in use`, so stop any foreground
`serve-dashboard.sh` before starting the service (or vice versa).

### View it away from home (Tailscale)

The dashboard's privacy comes from never being published, and the only
supported remote-access path keeps it that way: a **tailnet** — your own
private WireGuard mesh, via [Tailscale](https://tailscale.com). The server
keeps binding `127.0.0.1` only; `tailscale serve` proxies HTTPS to it for
devices signed into *your* Tailscale account, and nothing ever gets a public
URL. (Never use `tailscale funnel`, which is the public-internet variant —
that would publish the pipeline's telemetry to anyone with the link.)

A containerised node has this already: the `tailnet` profile runs Tailscale as
a sidecar and the dashboard inside its network namespace, which is the same
arrangement — loopback server, Serve in front, no Funnel — assembled by
`docker compose up -d` instead of by hand. The steps below were the laptop's
manual equivalent before the cut-over, kept for reference; a node set up today
gets all of this from the `tailnet` profile.

Prerequisite: the loopback server must be running — install it as a boot
service first (see [Run as a service](#run-as-a-service-legacy-wsl-path-decommissioned)).

1. **Install Tailscale in WSL** and check the daemon binary landed:

   ```sh
   curl -fsSL https://tailscale.com/install.sh | sh
   command -v tailscaled
   ```

   (The package ships only a systemd unit, which this WSL distro's init
   ignores — hence the init script in the next step.)

2. **Install the init script** — [`deploy/tailscaled.init`](../../../deploy/tailscaled.init)
   runs `tailscaled` at boot. Root this time, deliberately: it needs
   `/dev/net/tun` and `/var/lib/tailscale`; the dashboard server itself
   stays unprivileged and loopback-only.

   ```sh
   sudo install -m 755 deploy/tailscaled.init /etc/init.d/tailscaled
   sudo service tailscaled start
   ```

   Then add `service tailscaled start` to `/etc/wsl.conf`'s `[boot]`
   command, alongside cron and the dashboard service:

   ```ini
   [boot]
   command = service cron start; service artistos-telegram-bridge start; service docker start; service agent-ops-dashboard start; service tailscaled start
   ```

3. **Join your tailnet** (one-time): run `sudo tailscale up`, open the
   printed URL in a browser, and sign in (creating the account on first
   use). In the [admin console](https://login.tailscale.com/admin/dns),
   enable **MagicDNS** and **HTTPS certificates** — `tailscale serve` needs
   both to mint the dashboard's certificate.

4. **Proxy the dashboard onto the tailnet** (one-time; the setting persists
   in tailscaled's state across restarts):

   ```sh
   sudo tailscale serve --bg 8787
   tailscale serve status    # shows the https://… URL it is served at
   ```

5. **On your phone or laptop**: install the Tailscale app, sign into the
   same account, and open the URL from `tailscale serve status`
   (`https://<machine>.<tailnet>.ts.net`). The page auto-refreshes there
   exactly as it does locally.

The machine (and WSL) must be awake for this — but that is already true of
the pipeline itself, so anything the dashboard would show you is only ever
produced while it is reachable. To stop sharing: `sudo tailscale serve
reset`; to leave the tailnet entirely: `sudo tailscale logout`.

### Watching a node's events

The dashboard renders cycle *state*; watching events as they happen — a cycle
starting, what the Co-Ordinator selected, a PR going up, a stand-down — means
following the node's log directly. `scripts/watch-node.sh` is the one command
for that, in place of remembering the `docker compose exec -T scheduler
tail ...` incantation:

```bash
./watch-node.sh events -f   # cycle log (log.jsonl): starts, selections, PRs, stand-downs
./watch-node.sh cron -f     # cron log (cron.log): one line per tick, including standby ones
```

Drop `-f` for the last 50 lines instead of following. Run it from the node's
stack directory — where its `compose.yaml` and `.env` live, and where it is
fetched to during [Bring up a node](#as-a-container) — or set `STACK_DIR` to
point at a stack directory elsewhere. It wraps `docker compose exec -T
scheduler tail` and nothing more, so it is the one path worth allow-listing
for an interactive agent: one script instead of ad-hoc docker-exec commands
that a permission classifier may deny. See
[deploy/docker/README.md](../../../deploy/docker/README.md#follow-a-nodes-events) for
more.

### Push notifications

The dashboard and `watch-node.sh` above are both pull — you have to be
looking. `notify_webhook_url` is the installation's one push channel: set it
and every escalation issue the pipeline files or auto-closes, every pager
transition, and every fleet-wide stand-down beginning or ending (a
usage-limit cooldown, the fleet switch, the merge-autonomy kill switch) POSTs
a compact JSON body — `{event, key, title, url, repo, node, ts, detail}` —
to it, so a switch someone set stops being indistinguishable from a quiet
week. `notify_events` narrows which of the three classes (`escalation`,
`pager`, `fleet-standdown`) actually POST; `notify_min_interval_seconds`
coalesces a repeating fact into one message and a count rather than one per
cycle. See the [Configuration](../../reference/configuration.md#configuration) table and its [extended
notes](../../reference/configuration.md#extended-notes-notify_webhook_url) for the two-edit setup (the
webhook's host also needs to be in each node's `EGRESS_EXTRA_ALLOW`) —
`scripts/doctor.sh` checks both the alias and the fence for you.

## Troubleshooting

**Cron not running:**
```bash
sudo service cron status
sudo service cron start
```

**No cycles firing:**
Check the switch first — it's the one cause that leaves no trace of a problem,
because a disabled pipeline and a quiet week look identical:
```bash
./agent-cycle.sh --status
```
If it's disabled, `--enable` resumes it. Otherwise, check the cron log:
```bash
tail -50 ~/.local/state/poetic-agents/cron.log
```
A line reading `skipped — this node is standby` means this machine is not the
active one (see [Which node runs the cycles](#which-node-runs-the-cycles)):
either that is correct and another machine is doing the work, or the crontab is
missing its `AGENT_OPS_ROLE=active` line. A line naming an unrecognised role
(`AGENT_OPS_ROLE=activ is not a role`) is a typo standing the node down.

**Cycles firing but never reaching the Co-Ordinator:**
Expected on a quiet repo — see [Skipping no-op cycles](#skipping-no-op-cycles);
a `stand-down` whose reason begins `no-op short-circuit` is the system working.
It becomes a *fault* only if there is genuinely work waiting, which would mean
some source isn't covered by the fingerprint. The recheck valve
(`none_selected_recheck_hours`) breaks the loop within a day either way, and
`--once` forces the Co-Ordinator immediately:
```bash
./agent-cycle.sh --once    # bypasses the short-circuit
```
If `--once` then picks up work that scheduled cycles were skipping, the
fingerprint is missing a signal — a bug worth filing, in
`scripts/gather-source-state.sh`.

**Stale lock warning:**
If a cycle was killed or hung and left a lock older than 3 hours, the next cycle will kill it and log a `warning` event. Inspect the old cycle's transcript to see what went wrong.

**PR won't merge (mergeable=false):**
The Reviewer should have caught this, or it arose after the PR was ready (another PR merged to `main` first). Use `gh pr view --json mergeStateStatus` to see why. The branch and PR remain open for manual intervention.

**Usage limit hit:**
The system logs a `limit-hit` event with the reset time if parseable. It then stands down until that time or `limit_cooldown_default`, whichever is later. Check the log for the event.

## Removing a node for good

[Taking one node out](../contributing/README.md#taking-one-node-out-while-the-rest-keep-working) puts a
node aside and leaves it able to come back. Decommissioning is the other
thing: the machine is going away, or its disk is wanted for something else,
and nothing of the node should remain — not its containers, not its volumes,
not its branch in the fleet's memory, not its credentials.

No other node depends on this one. Work is arbitrated per item, not per node
(see [Keeping every node warm](#keeping-every-node-warm)), so the fleet
experiences a departure as one fewer heartbeat and nothing else. The order
below exists only so that the node leaves nothing behind for a peer to trip
over: a claim it will never release, a branch nobody prunes, a token nobody
revokes.

Run every `docker compose` command from the departing node's stack directory —
the one holding its `compose.yaml` and `.env` (`~/poetic-node-1`, or whatever
it was called at bring-up), not from a checkout of this repo.

### 1. Check the fleet can spare it

```bash
docker compose exec scheduler /app/agent-cycle.sh --status
```

If this node is `active`, confirm that at least one other node is too before
it goes. Several may be active at once and the fleet elects no replacement, so
removing the last active node leaves an operation that heartbeats, syncs, and
does no work at all — with nothing anywhere announcing it. The dashboard's
fleet strip names each node's role. It is also the surviving actives that run
the claim GC at the end of each cycle, so a fleet with none of them stops
sweeping stale claims as well as stops working.

### 2. Let any cycle in flight finish

`--status` above reads `cycle: idle` and `review: idle`, or names what is
running. Stopping or recreating a container kills a running cycle's whole
process group, which leaves an orphaned clone under `workspace_root`, a lock
to be taken over as stale, and a claim that stands until the GC sweeps it
(`claim_ttl_hours`, derived from `schedule.cycle_interval_minutes` — see
[Configuration](../../reference/configuration.md#configuration)). So wait — or stop this node alone from
starting another one while you do:

```bash
docker compose exec scheduler /app/agent-cycle.sh --disable 'decommissioning' --this-node --for 2h
docker compose exec scheduler /app/agent-cycle.sh --status   # until both read idle
```

`--this-node` is the node-scoped form (see [Taking one node out while the
rest keep working](../contributing/README.md#taking-one-node-out-while-the-rest-keep-working)): it
never touches the fleet-wide switch, so the rest of the fleet keeps working
while this one finishes its current cycle, and there is nothing to remember
to `--enable` from a surviving node once this one is gone — the record is
destroyed along with the node. Reach for plain `--disable` (no `--this-node`)
instead only if you actually want the whole fleet paused for the duration;
that one *is* fleet-wide, so `--enable` from a *surviving* node once this one
is gone, or every other node stays down until the disable expires. On a
standby node either disable is unnecessary — a standby starts no cycles.

`--disable` here is deliberately the blunt tool, and deliberately not
`--drain`: decommissioning wants this node stopped as soon as its current
cycle ends, not kept running until every repo's finishing-source backlog is
clear — which could be a long wait on a busy fleet, for a node that is about
to be deleted anyway. `--drain` exists for the opposite situation: an
operator who wants the *whole fleet* to finish its open work before a
disruptive change, with every other node still picking up new work in the
meantime. Neither is the roadmap's *graceful shutdown* (`docs/ROADMAP.md`,
Phase 2): that one is automatic, requires no operator action, and only ever
concerns the one cycle a container happens to be mid-flight on when it exits
— it says nothing about intake and finishes nothing beyond that single cycle.

### 3. Take off it anything you want to keep

Everything the node has published already lives in the state repository, and
step 5 deletes it from there. Two things are worth a moment first:

- **Its history** — `log.jsonl`, its cycle records, its stage transcripts.
  Keep a copy by cloning the branch before you delete it:
  ```bash
  git clone --branch nodes/<NODE_NAME> --single-branch \
    https://github.com/Poetic-Poems/agent-ops-state.git ~/node-<NODE_NAME>-archive
  ```
- **What only it knows.** The union readers learn blocked items, void
  verdicts, and no-op fingerprints from every node's log. Deleting this node's
  branch forgets whatever it alone recorded, so an item it blocked may be
  tried once more by a peer. That is a re-tried cycle, not a fault — but it is
  the reason to do this deliberately rather than by letting a branch rot.

The `claude-config` volume stores the OAuth credentials from an interactive
subscription login. It is not worth preserving if your node used the BYO
API-key path (the primary, first-class configuration — set `ANTHROPIC_API_KEY`
in `.env`), since `claude` reads the API key from the environment on
every invocation and there is nothing stored in this volume. If your node used
the alternative OAuth subscription path, the credentials in it are per node;
a replacement node logs in once if configured for the OAuth path, or simply
sets the API key if using the primary path.

### 4. Destroy the stack, its volumes, and its tailnet identity

If the node ran the `tailnet` profile, log it out while the sidecar still
exists, then delete the machine in the Tailscale admin console — otherwise it
lingers there as an offline device still holding its name, which the next node
called the same thing will not be given:

```bash
docker compose exec tailscale tailscale logout
```

Then take the whole stack down, volumes included:

```bash
docker compose down -v --remove-orphans
```

The `-v` is the entire point of this step. Without it, `state`,
`claude-config`, `workspaces` and `tailscale-state` survive as project volumes
belonging to a node that no longer exists — and they are where the disk went
(`docker volume ls`, `docker system df`).

**On a host running two stacks**, check which one holds watchtower before
choosing which to remove. The `auto-update` profile is typically enabled on
one node only, and that single watchtower updates every labelled container on
the host, whichever compose project it belongs to. Removing the stack that
runs it silently stops the survivor auto-updating; the survivor then drifts
off the fleet's image digest with no symptom but staleness. Add `auto-update`
to the surviving node's `COMPOSE_PROFILES` and `docker compose up -d` there —
while it is idle, per the caution in [Taking one node
out](../contributing/README.md#taking-one-node-out-while-the-rest-keep-working) — if the departing node
was the one running it.

### 5. Remove it from the fleet's memory

A node leaves the fleet by having its state branch deleted. That is the only
signal there is, and it must come *after* step 4: a node still running would
push the branch back within five minutes.

```bash
gh api -X DELETE repos/Poetic-Poems/agent-ops-state/git/refs/heads/nodes/<NODE_NAME>
```

(`Poetic-Poems/agent-ops-state` is `state_repo` in `config.json`.) Every
peer's next `state-sync.sh fetch` — seven minutes at most — prunes the
matching peer directory, and the node's card leaves every dashboard with it.
Leave the branch in place and you get the opposite of a clean departure: a
permanent card whose heartbeat only ever gets older, on every node's fleet
strip, for ever.

### 6. Revoke its credentials, then delete its directory

The node's `.env` holds a GitHub PAT — one per node, precisely so that one
node can be revoked without disturbing another. Revoke it at
`github.com/settings/tokens` rather than merely deleting the file: the file is
a copy, not the credential. Revoke the node's Tailscale auth key too, if it
was given a dedicated one. Then the directory itself:

```bash
rm -rf ~/poetic-node-1   # compose.yaml, .env, ts-serve.json, watch-node.sh, any .bak files
```

### 7. Reclaim the disk

The volumes are the dependable half, and `down -v` has already returned them:
they are ordinary directories, so they cost what they appeared to cost. The
images are where the arithmetic misleads, and it misleads *upwards*.

**Read `UNIQUE SIZE`, never `SIZE`.** The size Docker prints in `docker images`
— and the `RECLAIMABLE` column of plain `docker system df` — includes every
layer an image shares with other images, so adding those figures up counts the
same bytes several times over. Deleting an image returns only what no other
image still references. `-v` is the view that separates them:

```bash
docker system df -v    # REPOSITORY … SIZE  SHARED SIZE  UNIQUE SIZE  CONTAINERS
```

On an auto-updating node the gap between the two columns is the whole story.
Every watchtower roll leaves its predecessor dangling, and a predecessor of
the *same* image shares nearly all its layers with the `:latest` that replaced
it. Half a dozen of them read as several GB in `docker images` and give back a
megabyte or two:

```bash
docker image prune     # dangling images only — always safe, and often ~nothing
```

So don't plan around it. Delete the node's images by name once no container
wants them, and check the unique column first to know what you are getting:

```bash
docker image rm ghcr.io/pullwright/agent-ops:latest \
                containrrr/watchtower:latest \
                tailscale/tailscale:latest
```

Docker refuses to remove an image a container still uses, so this is safe to
attempt with a second node still running: it removes what it can and declines
the rest. Resist `docker image prune -a` unless this host runs nothing but
agent-ops — it removes every image no *running* container references, which on
a development laptop means the images behind every stopped stack on it, each
one a re-pull away from being needed again.

**On WSL2, none of this reaches Windows on its own.** The distro's `ext4.vhdx`
grows to its high-water mark and never shrinks, so space freed inside it is
free to Linux and still spoken for on the host's disk — `df -h /` will report
plenty free while Windows reports none. Hand it back from PowerShell:

```powershell
wsl --shutdown
Optimize-VHD -Path <BasePath>\ext4.vhdx -Mode Full   # Hyper-V module; or diskpart's `compact vdisk`
```

(`<BasePath>` is the distro's value of that name under
`HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss`.)

### Did it work?

From a surviving node, one fetch interval later:

```bash
docker compose exec scheduler ls /home/agent/.cache/poetic-agents/workspaces/.agent-ops-peers
```

The departed node should not be listed, and its card should be gone from the
dashboard's fleet strip. On the host it left, `docker ps -a` names none of its
containers and `docker volume ls` none of its volumes. If this was the last
node, the operation is now off — there is nothing left running anywhere, and
the state repository holds no `nodes/` branches.

## Uninstall

This is the legacy host install (see [On the host (legacy,
decommissioned)](#on-the-host-legacy-decommissioned)) — cron entries, state
directories, and services on the machine itself. To remove a *container* node,
follow [Removing a node for good](#removing-a-node-for-good) instead.

1. **Remove the crontab lines** (the cycle, the repository review, and, if added, the dashboard heartbeat):
   ```bash
   crontab -l | grep -v 'Poetic-Poems/agent-ops/agent-cycle.sh' | grep -v 'Poetic-Poems/agent-ops/review-cycle.sh' | grep -v 'Poetic-Poems/agent-ops/scripts/publish-dashboard.sh' | crontab -
   ```
   (Or edit the Windows Task Scheduler job / `wsl.conf` change if you used
   that alternative instead.) If you installed the dashboard boot service,
   also remove `service agent-ops-dashboard start` from `/etc/wsl.conf`'s
   `[boot] command`, then `sudo service agent-ops-dashboard stop` and
   `sudo rm /etc/init.d/agent-ops-dashboard`. If you set up tailnet access,
   likewise `sudo tailscale serve reset`, remove `service tailscaled start`
   from the `[boot] command`, `sudo service tailscaled stop`, and
   `sudo rm /etc/init.d/tailscaled` (then `sudo tailscale logout` and
   uninstall the package if nothing else uses Tailscale).
2. **Let any in-flight cycle finish**, or kill it: find the PID in
   `~/.local/state/poetic-agents/lock.json` and `kill` it — the next
   `crontab`-less state is safe either way since nothing else will start.
3. **Remove state and workspaces:**
   ```bash
   rm -rf ~/.local/state/poetic-agents ~/.cache/poetic-agents
   ```
   This deletes the log, lock, and stage transcripts. Any open PRs the
   system already raised are untouched — they're ordinary GitHub PRs on the
   target repos and are yours to merge, close, or hand-finish.
4. **Optional:** remove the `autonomous-agent` label from each configured repo
   (`gh api -X DELETE repos/Poetic-Poems/<repo>/labels/autonomous-agent` for each repo) and uninstall the standalone `claude` CLI if nothing
   else on the machine uses it.

