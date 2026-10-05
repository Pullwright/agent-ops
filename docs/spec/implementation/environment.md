## Environment (verified 2026-07-20)

- A containerized node: `bash`, `git`, `jq`, `gh` and the standalone `claude`
  CLI are all bundled in the node image (`deploy/docker/`); nothing is
  installed by hand.
- `gh` is authenticated as `warwickallen`, with push access to all configured
  repositories.
- On a containerized node, cron runs inside the scheduler container under
  supercronic, with the crontab rendered from `deploy/docker/crontab.tmpl`
  (see `docs/guides/operating/install-a-node.md`).
- Headless `claude -p` invocations authenticate with the user's existing
  Claude subscription login; `gh` uses its existing token. No new keys.

### The node image (`deploy/docker/`)

The same pipeline also runs from a container image, so a node can be a cloud VM
as readily as the laptop. The image is the *only* deployment artefact: it is
built from this repository, `/app` inside it **is** the deployed agent-ops, and
a node updates by pulling a new image rather than by pulling a branch.

- Base `ubuntu:24.04`, non-root user `agent` (uid/gid from the `PUID`/`PGID`
  build args, default 1000) with `HOME=/home/agent`, so `config.json`'s
  `~`-relative `state_dir` and `workspace_root` resolve under that home.
- Toolchain: `bash`, `git`, `jq`, `curl`, `python3`, `perl`, `coreutils`,
  `flock` and `rsync` (requirement 2.5); `openssl`, which RS256-signs the
  Approver App's JWT (requirement 14b) and is installed explicitly rather
  than relied on to arrive transitively, since a missing binary would
  surface only as a mint failure at run time; `gh` from GitHub's apt repository (the distro package is too old for
  the flags the pipelines use), installed unpinned and therefore guarded at
  build time by a fixed-string `grep -aF` over the installed binary for both
  stderr diagnoses `review_gate_required_checks` keys on (requirement 31c) —
  a `gh` that reworded either one fails the image build rather than reaching a
  node, where it would quietly demote every conflicting pull request from the
  trap it is to a node-level `unknown`; Node.js from NodeSource at the same major as
  the laptop; the `claude` CLI from `@anthropic-ai/claude-code`;
  `supercronic`, a pinned release binary verified by SHA-1 (one pin per
  architecture), which runs the container's crontab as an ordinary process
  with no cron daemon and no root; and `shellcheck`, a pinned release binary
  verified by SHA-256 (one pin per architecture, the amd64 one
  byte-identical to `.github/workflows/shellcheck.yml`'s own pin — component
  10), so an Implementer working inside this image can run
  `scripts/lint-shell.sh` — the gate its own pull request is judged by —
  before pushing. On a node that run is the gate minus its size guard: the
  container's memory ceiling is below what the largest script costs to lint,
  so that one file is skipped with a warning and CI is where it is actually
  checked (acceptance check 1g-i).
- `deploy/docker/entrypoint.sh` runs as `agent` on every container start and is
  idempotent: it seeds `$CLAUDE_CONFIG_DIR/settings.json` from
  `deploy/docker/claude-settings.json` **only when absent** (that directory is a
  persistent volume holding refreshing OAuth credentials, and the seed carries
  model/effort defaults only — no plugins and no local marketplaces); wires
  authentication — since agent-ops#1021, no token is minted here at all. When
  the forge authoring App's credential is present (component 14g's
  `author_token_credential_present`), it moves whatever ambient `GH_TOKEN` a
  PAT-carrying node already held into `PW_GH_DEGRADE_TOKEN` (component 14h
  owns the name) and leaves `GH_TOKEN` explicitly empty — exported, not
  merely unset — so every process this entrypoint execs inherits an empty
  `GH_TOKEN` and resolves its own credential through the on-demand seam
  (component 22c) rather than a token that may be hours from expiry by the
  time it authenticates anything; either way (App configured or not) it then
  configures `git`'s own credential helper directly —
  `git config --global --replace-all credential.https://github.com.helper
  '!gh auth git-credential'` — rather than through `gh auth setup-git`, whose
  own behaviour would bake the *absolute path* of the real `gh` binary into
  the config (`os.Executable()`, read inside the process the shim execs
  through to) and so bypass the shim, and therefore the seam, on every future
  credential fill; the unqualified `gh` re-resolves through `PATH` — the
  shim, ahead of the real binary — on every call — and, beside it,
  `credential.https://github.com.useHttpPath true`, without which git tells
  the helper only the protocol and the host, leaving component 22c's
  `gh_shim_target_owner` nothing in the request that names the repository, so
  every push and fetch would mint against the scalar default installation
  whatever organisation it was for; neither `git config` call is fatal — a
  node that could not write either still authenticates, just always as the
  default identity — refuses to start, before creating either directory, if
  `config.json`'s `state_dir` or `workspace_root` is missing, empty, or not a
  string, checked by JSON type (so a number or array value is rejected too,
  rather than stringified into a literal directory name); otherwise creates
  `state_dir` and `workspace_root`, and then execs the service it was given.
  It also refuses to
  start if `state_dir` is not writable, rather than
  letting a mis-owned volume become a silent failure to record anything. It
  does *not* set the git identity: every container this image runs — including
  the dashboard services and every command a `docker run` might be given —
  goes through this same entrypoint, and only a cycle that might actually
  commit needs an identity to commit under.
- `GIT_USER_NAME`/`GIT_USER_EMAIL` are instead required, with no default, by
  `agent-cycle.sh` and `review-cycle.sh` themselves (`lib/git-identity.sh`),
  checked once each has confirmed this tick will do real work — past its role
  guard, the switch, the fleet switch, the usage-limit stand-down, and (for
  review-cycle.sh) a lost or failed claim — and before the first git operation
  that could commit. A silent default would let a node commit every pull
  request it opens under the wrong name; checking this late means a standby
  tick, a switched-off node, a stood-down node, or a tick that ends up with
  nothing to do never needs an identity it was never going to use.
- The image sets `CLAUDE_CONFIG_DIR=/home/agent/.claude` — the `claude-config`
  volume's mount point. Claude Code's global config file defaults to
  `~/.claude.json`, a *sibling* of its config directory rather than a member of
  it, so it sat in the container's writable layer and every image roll destroyed
  it: each new container announced "Claude configuration file not found" on
  stderr and rebuilt the file from nothing. Pointing the variable at the default
  directory moves that one file inside the volume and changes no other path —
  credentials, `settings.json`, `projects/` and `sessions/` resolve exactly
  where they already did. It is set in the image rather than in each node's
  compose `environment:` so watchtower delivers it without a `docker compose up
  -d`, which would kill a cycle in flight — and in the image rather than only
  defaulted in `entrypoint.sh`, because the two reach different processes:
  `docker compose exec scheduler claude`, the once-per-node interactive login,
  starts from the image's environment and never runs the entrypoint. With the
  default alone, that login would write its config where the next roll destroys
  it while the cycles read the volume, and an operator who authenticated
  successfully would watch the node fail to authenticate. The entrypoint
  defaults it regardless, for any context that replaces the environment
  wholesale. The variable is honoured by the CLI but is not in its published
  settings documentation, so the image build asserts it (requirement 1b's
  checks) — against the image's own config rather than a running container's
  environment, since the entrypoint's default would otherwise mask a missing
  `ENV`. If a future CLI drops the variable, that check fails before the image
  reaches a node.
- `deploy/docker/crontab` carries the three pipeline schedules — the
  dashboard heartbeat, the implementation cycle, the
  review tick — plus two fleet lines (requirement 2.5): a `state-sync.sh
  push`, which publishes this node's state and heartbeat to its own branch,
  and a `state-sync.sh fetch`, which materialises every peer's for the union
  readers; one log-rotation line (requirement 2.6), `rotate-logs.sh`,
  which bounds the seven logs those schedules append to; one
  unattended-doctor line (requirement 2.6a), `doctor.sh --unattended`, which
  runs the same configuration and GitHub checks an operator would run by
  hand, once an hour, with nobody watching; one revert-rate line
  (requirement 2.6b), `publish-revert-rate.sh`, which runs the merged-PR
  miner over a bounded window once a day, with nobody watching either; and
  one tech-debt-archive line (requirement 2.6c), `publish-tech-debt-
  archive.sh`, which mirrors every `pw::type:tech-debt`-labelled issue into
  the state repository once a day, with nobody watching that either; and one
  liveness-marker line (requirement 57, issue #608), running every minute
  with no substitution token of its own, which `touch`es
  `state_dir/.node-alive` — the marker `scripts/node-health.sh --live`
  reads. Every
  cadence named above — the heartbeat and both fleet lines' intervals, the
  log-rotation minute, and the doctor, revert-rate and tech-debt-archive
  passes' own offsets — comes from `config.json`'s `schedule`
  (`heartbeat_minutes`, `state_sync_push_minutes`, `state_sync_fetch_minutes`,
  `log_rotation_minute`, `doctor_offset_minutes`, `revert_rate_hour`,
  `revert_rate_offset_minutes`, `tech_debt_archive_hour`,
  `tech_debt_archive_offset_minutes`; see Configuration), baked at 5, 5, 7,
  19, 44, 2, 51, 4 and 37 in the checked-in
  config. Every line's log redirection goes through `LOGDIR`, which
  `render-crontab.sh` (below) sets from `config.json`'s own `state_dir` at
  every container start rather than baking it in, so the dashboard's
  log-derived views keep working against whichever path the installation
  actually configured. It deliberately omits the laptop's personal
  `update-main-branches.sh` entry: that refreshes interactive checkouts, and
  a node has none.
- **The cycle and review minutes are per-node** (design decision D5). At
  every container start, `entrypoint.sh` runs
  `deploy/docker/render-crontab.sh`, which renders `crontab.tmpl` over the
  baked crontab with this node's offsets: `CYCLE_MINUTE` from the
  environment when it names a minute `schedule.excluded_minutes` does not
  rule out, else a stable hash of `NODE_NAME` onto whichever minutes that
  exclusion list leaves standing — deterministic, needing no coordination,
  and never one of the excluded minutes. The cycle fires every
  `schedule.cycle_interval_minutes` (15 by default; issue #248, "faster
  heartbeat") from that minute, within every hour named by
  `schedule.cycle_hours` (`*` by default), as an explicit cron minute list
  (`base`, `base+interval`, `base+2×interval`, …, each occurrence dropped
  rather than shifted if it lands on an excluded minute) —
  `cycle_interval_minutes=60` reproduces the single-firing-per-hour shape
  every release before it carried. A firing that finds nothing changed
  costs a fingerprint comparison and no Co-Ordinator call at all (3b), so a
  faster interval raises the fleet's pickup responsiveness without raising
  its idle spend. The review runs at `schedule.review_offset_minutes` past
  the node's *base* minute (mod 60, not the interval list — the review
  keeps a single fixed daily slot at `schedule.review_hour`, independent of
  the cycle's own interval), keeping one node's two heavy
  pipelines maximally apart. Why: every active node spends one Claude
  account and pushes to the same repositories; the claims (17a) make
  simultaneous firing *correct*, the offsets make it *cheap*. Excluding
  minutes at all is a per-deployment choice, not logic this renderer
  carries: `schedule.excluded_minutes` is configuration, and poetic's own
  `config.json` excludes `0` because its hourly sync workflow owns the top
  of the hour, recording that reason in `schedule.excluded_minutes_reason`
  — a deployment with no such conflict ships an empty list. An invalid or
  excluded `CYCLE_MINUTE` warns loudly and uses the hash — a typo must not
  silently land a node on an excluded minute — and any render failure
  (including a missing or malformed `config.json`, or a
  `schedule.cycle_interval_minutes` outside 1..60) leaves the baked
  crontab, a valid schedule, byte-untouched (`test/render-crontab.test.sh`
  pins all of this). The offsets therefore arrive with the image alone;
  setting `CYCLE_MINUTE` explicitly requires the compose file that maps it.
- Nothing host-specific and nothing secret is baked in. `GH_TOKEN`, the Claude
  credentials volume, `NODE_NAME` and `AGENT_OPS_ROLE` all arrive at run time,
  and a node that is not `active` (requirement 2.4) costs nothing but its
  cron-log lines.
- The image is built by CI, not by hand:
  `.github/workflows/build-image.yml` builds it on every pull request and
  every merge that could change it, runs the acceptance checks below *inside*
  it, and — on `main` only — publishes it to
  `ghcr.io/pullwright/agent-ops` tagged both `latest`
  (what a node's watchtower follows) and the commit SHA (how a node is pinned
  or rolled back, through `AGENT_OPS_IMAGE`), each tag a multi-platform manifest
  list covering `linux/amd64` and `linux/arm64`. A pull request builds and
  tests both legs — each in its own job on a runner of the image's own
  architecture, loaded (`load: true`) and run natively through requirement
  1b's acceptance checks — but publishes nothing. This is the whole update
  path: merge produces an image, and nodes replace containers. "Could change
  it" is requirement 1b-i's question: a change confined to prose builds
  nothing and publishes nothing, so a documentation merge leaves the fleet
  where it is and no tag carries its SHA.
- The image creates the volume mount points (`~/.claude`, `state_dir`,
  `workspace_root`) owned by `agent`, because a container runtime seeds a new
  named volume from the image's mount point — ownership included — and creates
  it as root when the image has nothing there. `state_dir`/`workspace_root`
  are read out of the image's own copy of `config.json` at build time, not
  hardcoded, so an installation whose `config.json` names different paths —
  including one outside `/home/agent` — gets them pre-created and owned
  correctly by its own ordinary build; the build fails outright if either key
  is missing or not a string, rather than creating a mount point under a
  literal `null` path.
- The image builds for both `linux/amd64` and `linux/arm64`: `supercronic` is
  the one binary not coming from a signed, multi-architecture apt repository,
  so the Dockerfile selects its release asset and pinned checksum from
  `TARGETARCH`, buildx's predefined build arg for the platform currently
  building.

### The node stack (`deploy/docker/compose.yaml`)

A node is a single Compose project. Every node runs the same file and the same
image; the only thing that differs between two nodes is `deploy/docker/.env` —
its name, its role and its tokens. `deploy/docker/.env.example` documents that
file and carries placeholders only; `.env` itself is never committed.

- **`scheduler`** — `supercronic /app/deploy/docker/crontab`, in no profile, so
  it runs on every node. `AGENT_OPS_ROLE` comes from `ROLE` in `.env` and
  **defaults to `standby`** if unset, so a half-configured node cannot become a
  second worker. Carries a `healthcheck:` running `scripts/node-health.sh
  --live` in-container (requirement 60c, issue #608) — the same command a
  Kubernetes `exec` probe would run, so this line and that manifest's own
  probe answer identically. Deliberately the liveness verdict alone: a
  sidecar HTTP responder answering `200` while supercronic is wedged beside
  it would be the same self-certification that let two nodes report
  themselves fresh for four days on 2026-08-08 (agent-ops#602's own
  motivation) — the `node-health` service below is a second surface over the
  identical computation, for a reader that can only speak HTTP, not what
  makes this check honest.
- **`egress-proxy` and the egress fence (D24)** — the scheduler reaches the
  internet only through this service. The scheduler sits on the
  `egress` network, declared `internal: true`, so Docker attaches no
  gateway: there is no route out to strip a proxy variable towards, and the
  fence is enforced by topology rather than by convention. `egress-proxy` —
  the same agent-ops image with `deploy/docker/egress-proxy-start.sh` as its
  entrypoint, in no profile, on both `egress` and `default` — runs squid
  permitting exactly one thing: CONNECT to port 443 on a domain named by
  `deploy/docker/egress-allowlist.txt` (baked into the image, every entry
  commented with the code that needs it) merged with the node's own
  `EGRESS_EXTRA_ALLOW` additions from `.env`. The scheduler's environment
  extends the shared block — via the `x-agent-ops-env` merge anchor, so the
  two never drift — with the proxy variables in both spellings, and with
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, `DISABLE_AUTOUPDATER` and
  `ENABLE_CLAUDEAI_MCP_SERVERS=false`, which turn off the `claude` CLI's
  optional traffic at the source so its domains stay off the allowlist. The
  proxy overrides the image's entrypoint because it runs no cycles and must
  not be gated on a writable state volume; it mounts `state` read-only
  solely so `watchtower-pre-update.sh` can honour a running cycle's lock
  before a roll recreates it mid-stage, and its config is parsed at image
  build time so a typo fails the build rather than a node.
- **The fence is delivered per node and observed per node.** Being
  compose-level, the fence arrives only when a human updates a node's
  `compose.yaml` and runs `docker compose up -d` there — no image roll
  carries it (the general hazard `lib/compose-drift.sh` exists for, and an
  un-updated node self-reports as compose drift in its heartbeat).
  `scripts/doctor.sh`'s Egress section probes the live fence's three failure
  shapes on every unattended run: the proxy path broken (fail — the node
  cannot work), a canary domain answering through the proxy (fail — the
  allowlist is theatre), and direct egress still routable (fail — the
  compose predates the fence, so it is advisory). A node with no
  `HTTPS_PROXY` at all warns rather than fails, so the fleet can roll the
  fence out node by node without every un-updated node reading as broken.
- **The Vercel variables are a capability, not a precondition.**
  `VERCEL_AUTOMATION_BYPASS_SECRET` and `VERCEL_TOKEN` reach both agent-ops
  services from `.env` through the shared environment block, and requirement
  24a's check is the only thing that reads them. A node with neither runs every
  cycle exactly as it did before that check existed — it reports "could not
  check" where a configured node reports a verdict — so they are never a reason
  for a cycle to stand down or an item to block. Being compose-level, they
  arrive only when a human edits that node's `.env` and runs
  `docker compose up -d` there; no image roll delivers them, which is the
  general hazard `lib/compose-drift.sh` and `scripts/check-node-compose.sh`
  exist for.
- **Model credentials are one of two paths, per D4.** `ANTHROPIC_API_KEY`
  reaches the scheduler from `.env` through the shared environment block —
  the BYO API-key path, D4's primary — read by `claude` directly and
  non-interactively on every invocation. Left empty, a node instead runs the
  subscription-OAuth alternative: an interactive `claude` login performed
  once against the `claude-config` volume, which the entrypoint warns is
  absent on every start until that login exists — a warning scoped to this
  path alone, since it would be false on the API-key path above. This path
  carries D4's stated constraints — interactive per node, so it does not
  scale the way the API-key path does, and limited by the subscription's own
  terms to your own use. `scripts/doctor.sh`'s Claude section reports on
  whichever path this node carries.
- **`tailscale`** (profile `tailnet`) — the sidecar whose network namespace
  `dashboard` shares. Refuses to start when `TS_AUTHKEY` is empty: its
  `entrypoint` checks the variable itself, before the image's own
  `containerboot` ever runs, logs one line to stderr and exits 1 rather than
  letting `tailscaled` start, ask for an interactive login it cannot
  complete, and exit 0 having already generated and registered a fresh node
  key against the tailnet — the failure mode behind issue #644's 1,421
  ephemeral nodes. `TS_AUTHKEY` is therefore required at every start of this
  service, not only the first, even where the `tailscale-state` volume
  already holds the node's identity. Its `restart: on-failure:5` is bounded,
  where every other service in the file is `unless-stopped`, so a credential
  that cannot fix itself on retry stops the container instead of restarting
  it forever; the accepted cost is that Docker does not re-apply an
  `on-failure` policy when the daemon restarts, so this sidecar and the
  `dashboard` behind it may need a `docker compose up -d` after a host reboot
  that the rest of the stack does not.
- **`dashboard`** (profile `tailnet`) — `scripts/serve-dashboard.sh` sharing the
  `tailscale` sidecar's network namespace (`network_mode: service:tailscale`).
  That shared namespace is what lets Tailscale Serve reach a server bound to
  `127.0.0.1` while nothing on any network can, so containerisation costs the
  dashboard's privacy model nothing. The sidecar's `ts-serve.json` proxies
  `https://<node>.<tailnet>` to `http://127.0.0.1:8787` and allows no Funnel.
  It carries `restart: on-failure:5`, like the sidecar, overriding the
  anchor's `unless-stopped` — but as a statement of intent rather than an
  observed bound: joining a network namespace whose owning container is not
  running is refused at *start*, so once `tailscale` has given up over a
  missing `TS_AUTHKEY` and stopped, `dashboard` never runs and never exits,
  and a policy keyed on exit codes — `on-failure:5` here, or the anchor's
  `unless-stopped` — is never consulted either way. Measured on VM1,
  2026-08-24, and corroborated on a keyless node: it lands in `Created` with
  a `RestartCount` of 0 and exit 128, at zero attempts under *both* policies
  (TD-PPagop-26091401 records the measurement against TD-PPagop-26082303,
  whose belief that `unless-stopped` retries this failure indefinitely did
  not reproduce). `on-failure:5` is kept here as intent, not as this
  container's own transient-error budget — it would bound a genuine
  crash-and-exit failure of this container, should one arise, but the
  namespace-join failure it was added for never reaches it.
- **`dashboard-local`** (profile `local`) — the same server on a node with no
  tailnet, readable on that host's loopback and nowhere else (`DASHBOARD-SPEC`).
  It gets there in two moves: the server is told to bind `0.0.0.0` *inside the
  container*, since a bind to the container's own loopback is reachable from
  nothing, and the port is published as
  `127.0.0.1:${DASHBOARD_PORT:-8787}:8787`, which keeps the page off every
  network the host is on. `DASHBOARD_PORT` moves the host side of that mapping
  only, and exists because the host may already have something on 8787 — the
  laptop's legacy SysV dashboard does.
- **`node-health`** (profile `node-health`) — the HTTP surface over
  `scripts/node-health.sh` (requirement 60d, issue #608):
  `scripts/node-health-server.py` answering `/livez`, `/readyz`, `/healthz`
  and `/metrics`. Off by default, in no other profile, and published on the
  identical loopback-only pattern `dashboard-local` uses immediately above:
  bind `0.0.0.0` inside the container,
  `127.0.0.1:${NODE_HEALTH_PORT:-8788}:${NODE_HEALTH_PORT:-8788}` on the host
  side. It is a second front over the same computation the scheduler's own
  `healthcheck:` already runs in-container, never a substitute for it — see
  that service's own entry below for why a sidecar cannot be what makes a
  container's liveness honest. It also carries the scheduler's own proxy
  variables and sits on `default` and `egress` both — not `egress` alone,
  which is `internal: true` and would strand its published loopback port —
  so `/readyz`'s one forge read (58a) leaves through the same D24 egress
  path the scheduler uses, rather than a route the cycle it reports on could
  not itself take (issue #1587).
- **`watchtower`** (profile `auto-update`) — how a node picks up new code: it
  polls for a new image tag and restarts the services into it. Enabled by
  label, so it touches this stack's containers and no others on the host. It
  runs with `WATCHTOWER_LIFECYCLE_HOOKS` on, and `WATCHTOWER_SCHEDULE` exists
  as an alternative to `WATCHTOWER_POLL_INTERVAL` for a node that would rather
  roll at a fixed time than poll — the two are mutually exclusive and
  watchtower exits fatally if given both, so setting the schedule means
  clearing the interval.

  **It watches only what is running.** A container that is stopped, or that
  never started at all, is not scanned and therefore cannot be rolled — and
  it is absent from the `Scanned=` count, so nothing in watchtower's own log
  distinguishes "this container is up to date" from "this container has not
  been looked at since it died". A service that stays down across an image
  release is left on the old code with no drift signal of its own, and comes
  back on that old code whenever it is next started, however many rolls the
  rest of the stack has taken meanwhile. Observed on VM1, 2026-08-24:
  `dashboard` sat in `Created` for four hours behind a stopped `tailscale`
  (below), scanned zero times, while the scheduler beside it was polled every
  five minutes. This is the second half of #603 — the updater's silence about
  a container it is not watching is as unreportable as its repeated failure
  on one it is.
- **A roll defers to a running cycle.** Recreating a container kills the
  process group its cycle runs in, so before watchtower touches any agent-ops
  container it runs `deploy/docker/watchtower-pre-update.sh` inside it (the
  `com.centurylinklabs.watchtower.lifecycle.pre-update` label, on the shared
  block so every service carrying the image has it). The script exits **75**
  (`EX_TEMPFAIL`), which watchtower reads as "cancel this container's update
  and re-check on the next poll", whenever `lock.json` or `review-lock.json`
  is held: always bounded by **that pipeline's `lock_stale_after`**, and
  beyond that judged by who is asking. A lock the running container itself
  wrote (the recorded `host` matches) is held while its process is alive —
  the same judgement requirement 1's `acquire_lock` makes, so the hook
  protects exactly what a cycle would have respected. A lock written by any
  other container, or one carrying no `host`, is held **until released or
  stale, with no liveness check at all**: a pid is only meaningful in the PID
  namespace that minted it, and on a tailnet node the dashboard reads the
  scheduler's locks through the shared `state` volume. Either way **a single
  deferral** can never outlast `lock_stale_after` — which is not a bound on
  the *sequence* of them by itself, and must not be read as one. Each poll is
  answered independently, so a node whose next cycle starts before
  watchtower's next poll is never asked at a moment when the lock is free:
  every refusal correct, every one well inside `lock_stale_after`, and the
  node never rolling on this check alone. Measured on VM1, 2026-08-24:
  `Failed=3 Scanned=3 Updated=0` every five minutes for hours, one of two
  nodes on that host catching a gap and rolling while its neighbour kept
  missing it and stayed ninety minutes behind, unreported. Surfacing that is
  #603's business, not this hook's. What was missing is agent-ops#1096's
  `roll-pending` marker (requirement 39c (Finish-then-continue)): at its own cycle boundary, a node
  whose image has fallen behind the registry's newest declines the chain it
  would otherwise take and writes the marker instead, which the hook honours
  as an unconditional allow against `lock.json` alone — never
  `review-lock.json`, which never wrote the marker and never yielded
  anything (agent-ops#1102) — until the window it names expires, or until the
  cycle that next reacquires `lock.json` clears it itself, at its own start,
  once `image_drift_status` no longer reads "behind" (also agent-ops#1102: a
  fixed clock offset from cycle-end is not "until the next cycle would have
  started", so without this a reacquired lock could otherwise run its own
  stages underneath a marker that still authorises overriding it). The bound
  today is therefore two-part: one cycle's length for a node that is merely
  busy, and `lock_stale_after` only for one that is actually wedged and so
  never reaches that cycle-boundary check at all. **A compose apply in flight
  defers the roll too** (agent-ops#1913): the `reconciler` service below
  recreates this whole project when a merged `compose.yaml` reaches the node,
  and a roll landing part-way through has watchtower and Compose stopping and
  creating the same containers at once, with nothing in the daemon's log
  afterwards able to say which stop was whose. So the hook exits 75 while
  `$state_dir/.compose-reconcile.json` reads `applying` and its `at` is less
  than ten minutes old — twice the reconciler's own tick, because the one way
  that marker outlives its apply is the apply's container dying part-way,
  which the next tick settles. Past that bound, on an `at` that will not
  parse, or on any other status, it defers nothing: this is the same
  fail-open discipline as everything else here, and it is not overridable by
  `roll-pending`, which is a decision a cycle took about itself and not one a
  half-applied project ever took. The reconciler deferring while
  `roll-pending` is in force (requirement 2.5a) is the same serialisation from
  the other side. The fail-closed side is
  the cheap
  one — a leftover foreign lock is taken over or removed within the hour by
  the next cycle (requirement 1 precedes the stand-down checks, so standby
  nodes clear it too), while a foreign `kill -0` answers for the wrong
  process in both directions, and watchtower undid a live deferral off
  exactly that answer once (issue #130): its restart map is keyed by *image*
  id, so the dashboard's wrong exit 0 led it to recreate the deferred
  scheduler sharing that image, stopped only by the name conflict with the
  never-stopped container. That name conflict remains the only backstop
  against a *second compose project* running the same image on one host: its
  own state volume is rightly separate, so it rolls whenever its own node is
  idle and its map entry still names the shared image — the deferred
  container survives because the create fails on its own name, at the price
  of a `Failed` count and a name-conflict error in watchtower's log each
  poll. It exits 0 when both are free, and also on any
  internal failure — not because a non-zero status would freeze the node's
  image, but because **75 is the only status watchtower defers on**: every
  other non-zero code is logged as a failed hook and the update proceeds
  regardless ("an exit code different than 0 or 75 (EX_TEMPFAIL) will not
  prevent watchtower from updating the container"). A hook that cannot answer
  therefore cannot protect anything whatever it returns, and 0 is simply the
  honest way to say so. The label carries a `pre-update-timeout` of 1 minute
  (watchtower's unit is minutes), and that bound **fails open** too: on
  expiry watchtower continues the update loop, so a container too wedged to
  answer inside the minute is rolled anyway. Setting the label to `0` would
  disable the timeout and fail closed, at the price of one wedged container
  stalling every node's updates indefinitely; the minute stands as the lesser
  hazard while the hook remains a handful of `jq` calls.
  `test/watchtower-pre-update.test.sh` pins all of this.
  The hook covers the automatic roll and nothing else: a manual `up -d`,
  `restart`, `down` or host reboot recreates containers without consulting
  watchtower, so the operating rule for those remains `--status` first.
- **`reconciler`** (profile `auto-update`) — how a node picks up a new
  *`compose.yaml`*, the half `watchtower` above cannot deliver: a roll
  recreates a container from the old container's `Config`, so every
  compose-level change waited on a human until this service existed. The same
  image, `network_mode: none`, the Docker socket read-write, and this node's
  own stack directory bind-mounted at the absolute path it has on the host
  (`AGENT_OPS_PROJECT_DIR`); it takes neither shared anchor, so it carries no
  credential. `supercronic` runs `scripts/reconcile-compose.sh` every five
  minutes (`deploy/docker/reconcile-crontab`), which applies the image's own
  copy of this file when — and only when — the drift check below says the
  node's copy differs, the new file needs no `${VAR}` the node's `.env` lacks,
  neither pipeline holds its lock, and no image roll is due. The recreate
  itself runs in a transient sibling container, because this service is one of
  those the recreate replaces. Requirement 2.5a is the whole
  mechanism; its verdict rides the heartbeat beside the drift verdict.
- **A node's copy of this file is watched for drift.** A node holds its own
  `compose.yaml`, which no image roll can update — labels, service
  environment and mounts arrive only via a human running `docker compose up
  -d` on that host — so a merged compose change can otherwise sit inert on
  every node while the repository's own checks stay green (issue #131, which
  is what it cost to learn this). The file therefore mounts *itself*
  read-only into the agent-ops services (`./compose.yaml:/host/compose.yaml:ro`,
  on the shared block), and `lib/compose-drift.sh` diffs the mount against
  the image's own copy at `/app/deploy/docker/compose.yaml` — comments and
  blank lines aside, since what drifts in comments cannot change what a
  container runs. The reference tracks `main` by exactly the channel that
  already works, the image roll. The verdict — `{status: "in-sync"}`,
  `{status: "drifted", diff_lines: N}`, `{status: "unmounted"}`, or `null`
  outside a container — travels in the node's heartbeat (requirement 2.5)
  and is rendered on every dashboard's fleet strip (`docs/spec/dashboard/site.md`).
  `unmounted` is the bootstrap problem answering itself: a compose file too
  old to carry the mount is behind by construction, and the *check* reaches
  every node by image roll with no `up -d` required, so a node that cannot
  be verified says so from its first rolled image until its stack is
  re-created. Where the `reconciler` service above runs, the verdict now has
  an actor rather than only a reader: a `drifted` reading is what that service
  acts on, and it clears itself on the first tick the node is idle
  (requirement 2.5a). Where it does not — a node whose owner has not yet run
  the one enabling `up -d` — the badge and the per-node ritual are exactly
  what they were. What the mount cannot see — whether the running containers
  were created from the file, and watchtower's own environment, the one
  container nothing ever rolls — needs the Docker socket, which these
  containers rightly lack: `scripts/check-node-compose.sh` (component 12)
  answers those from the host. Merging a change to this file is not
  deploying it, and `.github/workflows/compose-deploy-reminder.yml` says so
  on every pull request that touches it — one marker-keyed comment, posted
  once rather than per push, naming both what a node running the
  `reconciler` service needs (nothing, unless the change adds a `${VAR}`
  with no default or alters that service's own definition) and the per-node
  ritual a node without it still needs.
- **A node's running image is watched for staleness against the registry.**
  Comparing nodes with each other (`version`, above) answers *divergence* —
  are the nodes on the same commit — but not *staleness*: a fleet that
  adopts one broken image at once agrees with itself perfectly and reads as
  healthy on that measure alone, which is exactly what happened across
  issues #149/#154. `lib/image-drift.sh` answers against a reference outside
  the fleet instead — `ghcr.io/pullwright/agent-ops:latest`'s own
  `org.opencontainers.image.revision` label, read anonymously over the OCI
  Distribution API (no GitHub `read:packages` scope needed) — never against
  `origin/main`, since a documentation-only merge publishes no image at all
  and would otherwise read as false staleness. The verdict —
  `{status: "current"}`, `{status: "behind", registry_commit,
  registry_created_at}`, `{status: "unverified", reason}`, or `null` for a
  node not running a CI-stamped image — travels in the node's heartbeat
  (requirement 2.5) and is rendered on every dashboard's fleet strip
  (`docs/spec/dashboard/site.md`) with a threshold that tolerates the ordinary
  mid-roll deferral. `scripts/check-node-image.sh` answers the same question
  by hand from a node's host, exec'd into the scheduler container to reuse
  the same library rather than duplicating a registry client there.
- Which profiles a node runs is set by `COMPOSE_PROFILES` in its `.env`, so the
  operator's command is `docker compose up -d` on every node regardless.
- Three named volumes carry everything that must survive a container being
  replaced: `state` (the node's cycle records, logs and locks), `claude-config`
  (the OAuth credentials, which refresh themselves and cannot be rebuilt from
  the image, and — via `CLAUDE_CONFIG_DIR` — the global config file that would
  otherwise sit outside it), and `workspaces`. A node updates by replacing its
  containers; these are what it keeps. Anything Claude Code writes that is not
  under one of these mount points is lost on the next roll, which is why the
  config directory is relocated rather than the volume list extended: a named
  volume cannot mount a single file.
- The dashboard service of either profile `depends_on` the scheduler. Both mount
  the `state` volume, and on a node's first start that volume is empty and is
  seeded from the image's mount point; two containers seeding it at once race,
  and one aborts the `up` with `mkdir … /cycles: file exists`. The dependency
  routes the first-run seed through a single container. On every later start the
  volume already exists, so it only orders startup.
- **Every container carries a resource ceiling (D14).** Each service states a
  `mem_limit`, a `cpus` and a `pids_limit`, and every agent-ops service also
  states a bounded `json-file` rotation; each value is a `${VAR:-default}` a
  node may raise or lower in its `.env`. The defaults come from measurement
  rather than from a rule of thumb — scheduler 1536m/2.0 against an observed
  190-290 MiB at 1.0-1.3 cores, dashboard 512m/1.0 against 11-54 MiB, and the
  `tailscale` and `watchtower` sidecars 256m/0.5 and 128m/0.5 against 52 MiB
  and 28 MiB — and they are ceilings, not reservations: Docker reserves
  nothing, so the sum may exceed the host and only bounds one container's blast
  radius. Where the host is small enough that the sum is the binding number, as
  on a WSL2 VM running two nodes, the defaults are chosen so the whole file
  fits — and requirement 2.0g (agent-ops#757) is what checks that they still
  do, on every cycle, against every container sharing the host (not only this
  file's own three services), rather than trusting this paragraph's own
  arithmetic to stay correct by hand. A process ceiling sits beside the
  memory one because a fork loop
  exhausts a host's pid space long before its memory, and the failure then
  takes the host rather than the container. The stated trade is that a stage
  outgrowing its ceiling is killed mid-cycle instead of taking the host down
  with it — one lost cycle, loudly, over a frozen machine — so a node losing
  cycles to exit 137 raises the variable rather than removing the limit. Two
  of D14's four budgets are **not** enforced here and cannot be: Docker's
  blkio throttles need kernel support the WSL2 kernel lacks (`docker info`
  warns `No blkio throttle.read_bps_device support`), and Compose has no
  per-container egress cap at all. Disk and bandwidth are therefore bounded
  only by what the pipeline itself does — measured and reported rather than
  enforced (requirement 55, agent-ops#606): `scripts/collect-resource-usage.sh`
  self-samples both from inside `scheduler`/`dashboard`/`dashboard-local`,
  and `scripts/doctor.sh` warns when the windowed figure crosses
  `config.json`'s own `resources` budget, the same "reportable, not
  enforceable" answer this file's own D16 open-question table gives disk and
  bandwidth generally.
  Nor does `mem_limit` bound the *whole* of what a container may hold: it is
  a ceiling on `memory.current` (resident plus page cache), never on
  `memory.current` plus swap, so on a host `docker info` reports "No swap
  limit support" for (every node in this fleet, as of the ceilings above), a
  container over its ceiling swaps into the host's own swap file rather than
  being killed — the OOM trade this paragraph states two sentences up simply
  does not happen there, and a container that should have been killed
  instead keeps running while the host's own swap fills, which is a slower
  and less legible version of the same freeze the ceiling exists to prevent.
  A scheduler's own `mem_limit` is not the whole of what bounds it: an
  opted-in node also creates it under a parent cgroup
  (`scripts/cgroup-parent-setup.sh`) carrying `memory.high` (the proactive
  reclaim `mem_limit` alone cannot express), `memory.max` and
  `memory.swap.max` — the latter two added by agent-ops#1305 after a parent
  with `memory.high` set and `memory.max` left at `max` proved to be a
  livelock, not a mitigation: throttling that never disengages because
  nothing anywhere is a hard enough ceiling to reclaim past, or to kill (see
  requirement 2.0f above for the full mechanism and `memory_cgroup_verdict`'s
  `livelocked`/`unconfirmed` verdicts).

### Target repositories

| Repo | GitHub | Work sources, in priority order |
|---|---|---|
| poetic (framework) | `Poetic-Poems/poetic` | 1. **security findings** · 2. **`issues:urgent`** · 3. **review-feedback** · 4. **merge-conflicts** · 5. **human-visibility** · 6. **abandoned-drafts** · 7. failed Actions runs on `main` · 8. `issues:high` · 9. `TECH-DEBT.md` · 10. `issues:medium` · 11. project-review recommendations · 12. `issues:low` · 13. code-quality findings |
| poetic-fiddle (web app) | `Poetic-Poems/poetic-fiddle` | 1. **security findings** · 2. **`issues:urgent`** · 3. **review-feedback** · 4. **merge-conflicts** · 5. **human-visibility** · 6. **abandoned-drafts** · 7. failed Actions runs on `main` · 8. `issues:high` · 9. `TECH-DEBT.md` · 10. `issues:medium` · 11. `implementation-plan` (its configured plan document, `docs/IMPLEMENTATION-PLAN.md`; next milestone task) · 12. project-review recommendations · 13. `issues:low` · 14. code-quality findings |
| agent-ops (pipeline itself) | `Pullwright/agent-ops` | 1. **security findings** · 2. **`issues:urgent`** · 3. **review-feedback** · 4. **merge-conflicts** · 5. **landing-refusals** · 6. **human-visibility** · 7. **abandoned-drafts** · 8. failed Actions runs on `main` · 9. `issues:high` · 10. `TECH-DEBT.md` · 11. `issues:medium` · 12. `issues:low` · 13. code-quality findings |

This is this installation's current `config.json`: its `repos` array names
these three repos and each one's `sources`, in this order. Unlike this document,
`prompts/coordinator.md` names neither repo — the Co-Ordinator's own copy of
this table is rendered from `config.json` at cycle time, not hand-written
here twice (requirement 4b), so this table is the one place a config change
needs an editorial update to stay accurate.

The `security` and `code-quality` sources draw on GitHub's own automated
analysis, not just files in the tree:

- **`security`** — open **Dependabot alerts** (vulnerable dependencies) and
  open **code-scanning alerts** (CodeQL and any other configured code-scanning
  tool) that carry a security severity. All Dependabot alerts are security by
  nature; a code-scanning alert counts here when its
  `security_severity_level` is set. This source is **first in every repo's
  list**, and, more strongly, **within a repository any security-related
  candidate takes precedence over every non-security candidate regardless of
  which source it came from** — including a GitHub issue labelled
  `security`/`vulnerability` or a tech-debt item flagged as a security
  concern. Across repositories it is this source itself that carries the
  top global tier (requirement 15a): a security-labelled issue or a
  security-flagged tech-debt item is reconciled at its own source's tier
  there, never ahead of another repository's ordinary work. Security work is
  always prioritised.
- **`code-quality`** — the remaining open **code-scanning alerts** (those
  *without* a security severity: maintainability, correctness, and style
  findings) plus any other code-quality findings GitHub surfaces. Automated
  quality suggestions are more speculative and higher-volume than curated
  tech-debt or filed issues, so they are picked up only when nothing more
  deliberate is waiting.

The `human-visibility` source draws on `scripts/sweep-human-visibility.sh`'s
own log (requirement 38c), read back and re-verified live:

- **`human-visibility`** — a violation requirement 38c's periodic sweep found
  but could not self-heal (a `gh` read, the review-request POST, or the
  nudge-comment POST itself failing), still true once
  `scripts/gather-human-visibility-hygiene.sh` re-checks it live (requirement
  38e). **Ranked immediately after `merge-conflicts`**, the same "finishing
  beats starting" class as `review-feedback`, `merge-conflicts` and
  `abandoned-drafts`: finished work invisible to the human whose merge
  everything waits on is not a cosmetic repair, and must not sit behind the
  full repo walk on a rationale that does not describe it.

The `issues` source is **banded by the issue's own `Priority` field**, so it
occupies four separate ranks rather than one:

- **`issues:urgent`**, **`issues:high`**, **`issues:medium`**, **`issues:low`**
  — open GitHub issues whose organisation-level `Priority` issue field reads
  `Urgent`, `High`, `Medium` or `Low` respectively. An issue with **no**
  `Priority` set is **`Medium`** (requirement 15e), which is the rank the
  single, unbanded `issues` source used to hold — so an untriaged backlog ranks
  exactly where it always did, and setting the field is what moves an issue up
  or down.

  The four bands are one source, not four: they share the whole of the `issues`
  source's behaviour — the exclusions of requirement 16 (assigned, `blocked`,
  a question or discussion), the whole-thread read of requirement 14a, the bare
  issue number as the item ref, and the work order's `"source": "issues"`
  (requirement 21). Only the rank differs. Nothing downstream of selection can
  tell the bands apart, which is deliberate: the band is a statement about
  *when* the work is picked up, not about what the work is or how it is done.

  The `Priority` field is GitHub's native issue field, not a label and not a
  Projects v2 field, so it arrives on both the REST issues endpoint and its
  GraphQL equivalent, in `issue_field_values`/`issueFieldValues` respectively
  (the entry whose `issue_field_name`/`field.name` is `Priority`, read from
  its `single_select_option.name`/`name`). It is absent from `gh issue view
  --json`, which is why requirement 15e names one of the other two surfaces
  instead. An issue whose
  `issue_field_values` is empty, or that carries no `Priority` entry, or whose
  entry cannot be read at all, is `Medium` — the field's visibility is
  `organization_members_only`, and a token that cannot see it must degrade to
  today's behaviour rather than to an unranked pile.

The `project-review` source draws on the review pipeline's own
output (see `docs/spec/review.md`), which lands in each repo via a
merged PR:

- **`project-review`** — the prioritised **recommendations** produced by the
  most recent project review, which live on the default branch under that
  repository's own resolved report directory (`report_directory` in its
  runtime-input entry, requirement 3k — `reviews/project-review-YYYY-MM-DD/`
  where the repository configures neither `repository_review.repos[]`'s nor
  `repository_review.defaults`' own `report_directory`) as
  `03-recommendations.md` (the recommendation table and per-`R-NN` detail)
  paired with `04-improvement-prompts.md` (one ready-to-run agent prompt per
  recommendation). The Co-Ordinator reads the **latest** review folder's two
  files directly (`gh api .../contents/...`, no pre-fetch needed) and treats
  each recommendation as a candidate. A recommendation's **stable ref** is
  `review-<review-date>-R-NN` (e.g. `review-2026-07-20-R03`); that ref goes in
  the branch and PR so a claim (open PR) and a completion (merged PR) are both
  detectable later. The improvement prompt is the Implementer's brief and the
  recommendation's *Intended end state* is its acceptance. This source sits
  **below tech-debt and `issues:medium`** deliberately: the review already
  mirrors its debt-shaped recommendations into the tech-debt register
  (cross-referencing the `R-NN`), and those curated, status-tracked entries are
  the primary channel — the `project-review` source exists to pick up the
  review's remaining recommendations (typically smaller improvements) that were
  *not* also filed as tech-debt or an issue, so nothing the review surfaced is
  silently dropped. It ranks above `issues:low` and `code-quality` because a
  human-approved review recommendation is more deliberate than either an
  automated quality suggestion or an issue its own author has marked as the
  least pressing thing they filed. A recommendation whose text flags a
  **security concern** is security-related and so is caught by "security is
  always prioritised" like any other security candidate.

The `review-feedback`, `merge-conflicts` and `abandoned-drafts` sources are all
*finishing* sources — they carry an already-open pull request the rest of the way
rather than starting new work — and all are pre-fetched:

- **`review-feedback`** — pull requests this system raised on which a human has
  requested changes we have not yet answered (requirement 3c). Ranked second, and
  across all repos (requirement 15b).
- **`merge-conflicts`** — pull requests this system raised that are otherwise
  ready (for review or for merge) but whose `mergeable` is definitively
  `CONFLICTING` because the base advanced underneath them (requirement 3g). A
  rebase-and-resolve makes the PR mergeable again; until it is, nothing can land
  it and nothing else on it can proceed. Ranked third, and across all repos
  (requirement 15d). Like `abandoned-drafts` its candidacy turns on something no
  event on the PR itself carries — the base moving, which GitHub reflects in
  `mergeable` a beat later — so the no-op fingerprint must account for it
  (requirement 3b).
- **`abandoned-drafts`** — draft pull requests this system raised and then
  abandoned: still open, still draft, carrying `pr_label` on a branch under
  `branch_prefix`, and untouched for at least
  `abandoned_draft_after_hours` (requirement 3e). A stage that timed out, hit a
  usage limit, or died leaves its draft PR behind as a stalled claim; finishing it
  costs less than starting fresh and turns the back-pressure slot it occupies —
  which nothing would otherwise clear — into a landable PR.
  Ranked fourth, and across all repos (requirement 15c). Uniquely, its candidacy
  turns on the passage of time itself, which the no-op fingerprint must account
  for (requirement 3b) as it must for merge-conflicts' base-driven flip.

Because Dependabot and code-scanning alerts live behind paginated, verbose
GitHub APIs, the Script pre-fetches and normalises them once per cycle via
`scripts/gather-findings.sh` (a deterministic, model-free script) and injects
the compact result into the Co-Ordinator's runtime input, so the Co-Ordinator
does not spend model tokens paginating those endpoints itself (see
requirement 3a and 20).

Conventions shared by all configured repos (agents must honour all of these):

- `main` is protected: no direct pushes by anyone or anything; every change
  lands via a pull request, squash-merged, so **the PR title becomes the
  commit on `main` and must be in Conventional Commits format**.
- Tech debt is filed as an open GitHub issue carrying the `pw::type:tech-debt`
  label (D15 as revised, #869/#875/#879), claimed and worked exactly like any
  other issue-shaped item — an `agent/<issue-number>` branch, never a
  register file — and resolved by closing the issue with a real GitHub
  closing keyword together with a fenced `td-record` block in the same pull
  request's body (requirement 25), which becomes the permanent record once
  the squash-merge commit carries it onto `main`. `tech-debt/<id>.md` is a
  frozen historical archive of every item a repository filed while debt
  was tracked as a per-item register, before that policy changed: its files
  are never edited, deleted or renamed, and an issue migrated from that
  archive additionally flips its named file's frontmatter to a terminal
  `status:` on resolution (`TECH-DEBT.md`).
- CI runs on every PR (build/lint/test workflows plus CodeQL and
  commit-format checks). A PR is not finished until its checks pass and
  `gh pr view --json mergeable,mergeStateStatus` reports it mergeable.
- A notable change's changelog entry goes where the repository's own
  `AGENTS.md` says: under D27, a `## Changelog` section of its pull-request
  description, which the squash merge carries onto `main`, with
  `CHANGELOG.md` assembled from those descriptions by the release pull
  request and edited by nothing else (requirement 25c); in a repository yet
  to adopt D27, an `[Unreleased]` entry in `CHANGELOG.md`. Other docs are
  as-built (no historical phrasing).

