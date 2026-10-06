## Components (as built)

- `scripts/publish-dashboard.sh` — the Publisher. `DASHBOARD_GH_CMD` names the
  `gh` it calls, and is exported so `scripts/gather-findings.sh` resolves the
  same one; it exists for the test suite, which must reach no network and
  cannot shadow a binary by PATH (the Publisher hardens PATH for cron, and its
  `gh` runs under `timeout`, which no exported shell function is visible to).
  Unset in production, where it is exactly `gh`. `DASHBOARD_TODAY` is a
  narrower seam over the same `today` the cost roll-ups use to compute
  `spend_today_usd`: it lets the test suite pin which UTC day counts as
  "today" without pinning every other window `--now` controls (below), and
  only when `--now` is absent — `--now` takes precedence over it when both
  are set. Unset in production, where "today" is the real UTC day. Not
  exported: this script is the only reader.
- `lib/version.sh` — what code this node is running: the image's CI stamp
  (`build-info.json`) if there is one, else git `HEAD`, else nothing. Shared
  with `scripts/state-sync.sh`, which publishes the answer in every heartbeat.
- `lib/image-drift.sh` — whether that code is the registry's newest published
  commit (#155): `image_drift_status` reads `ghcr.io/pullwright/agent-ops
  :latest`'s `org.opencontainers.image.revision`/`.created` labels anonymously
  over the OCI Distribution API and compares against `lib/version.sh`'s
  answer. Backed by a cache file (`<state_dir>/.image-drift-cache.json`,
  `IMAGE_DRIFT_TTL` seconds, 240 default) that this script and
  `scripts/state-sync.sh` name identically, since unlike `lib/version.sh` and
  `lib/compose-drift.sh` a real network round trip sits behind it — one this
  Publisher's 5-second tick cannot pay on every run. `IMAGE_DRIFT_CURL_CMD`
  is the test seam, following `DASHBOARD_GH_CMD`.
- `scripts/doctor.sh --unattended` (agent-ops#543, `docs/spec/implementation/requirements`
  requirement 2.6a) — not read live by this Publisher, unlike
  `lib/compose-drift.sh`/`lib/image-drift.sh` above: its GitHub section costs
  several calls per configured repository, too much for a 5-minute
  heartbeat, so it runs on its own hourly `crontab.tmpl` line instead and
  writes `<state_dir>/.doctor-status.json`
  (`{timestamp, verdict, fails[], warns[], skips}`). This Publisher reads
  that file verbatim into `status.doctor`; `null` until the first hourly
  pass has run. The raw file itself stays local — nothing replicates it to
  peers — but its own `verdict` now does, folded into the heartbeat's
  `doctor` field (agent-ops#1278) the same way `stage_health`'s does below,
  for `lib/pager.sh`'s `verdict-unanimous` invariant to read fleet-wide.
- `lib/stage-health.sh` (agent-ops#662,
  `docs/spec/implementation/requirements` requirement 2.8) — not read live by
  this Publisher either, on `doctor.sh --unattended`'s own precedent just
  above, even though (unlike doctor's GitHub section) recomputing it here
  would cost no network call: `agent-cycle.sh`'s own `cleanup()` already
  computes and merges `<state_dir>/.stage-health.json`
  (`{computed_at, threshold, idle_after_hours, stages}`) at the end of every
  cycle — and `monitor-cycle.sh` merges its own `monitor` stage into the same
  file at the end of every monitor run that engaged its stage — so reading it
  keeps this Publisher and the fleet heartbeat
  (`scripts/state-sync.sh`, below) reading the identical file rather than two
  computations that could disagree. This Publisher reads it verbatim into
  `status.stage_health`; `null` until this node's first cycle since this
  check shipped has completed. Unlike `.doctor-status.json`, its *content*
  does reach peers — folded into the heartbeat's own `stage_health` field,
  the same way `compose`/`image`/`switch` already travel — even though the
  raw file itself is excluded from `scripts/state-sync.sh`'s general
  replication, since a peer's copy of the raw file would answer for a
  computation nobody there ran.
- `lib/pager.sh` and `lib/pager-invariants.sh` (agent-ops#1278,
  `docs/spec/implementation/requirements` requirement 51) — unlike every
  component above, not a read: `pager_evaluate`, called from this
  Publisher's own `WITH_GITHUB` block, is the one place this script writes —
  a `pager-*` transition event to this node's own `log.jsonl`, and possibly a
  created or closed GitHub issue. `PAGER_GH`/`CLAIM_GH` are set to
  `DASHBOARD_GH_CMD` before the call, so the test suite's `gh` stub covers
  pager's own GitHub calls on the same terms as every other one this script
  makes.
- `scripts/publish-revert-rate.sh` (D18 issue #579,
  `docs/spec/implementation/requirements` requirement 2.6b) — not read live by
  this Publisher either, on the identical reasoning as `doctor.sh
  --unattended` above: it shells out to `scripts/mine-merge-history.sh`
  (several GitHub calls per bounded window per repository), too much for a
  5-minute heartbeat, so it runs on its own daily `crontab.tmpl` line and
  appends to `<state_dir>/revert-rate.jsonl` instead — fleet-wide data, unlike
  `.doctor-status.json`, so this Publisher reads it through the same union
  `fleet_logs` gives `log.jsonl`, not verbatim off this node's own file.
- `scripts/publish-dashboard-launcher.sh` — the sub-minute heartbeat driver
  (cron runs it every 5 min; it self-loops on 5-second boundaries).
- `dashboard/index.html` — the page (committed source; copied beside the
  generated `data.js` at publish time).
- `scripts/open-dashboard.sh` — regenerate + open in the browser.
- `scripts/serve-dashboard.sh` — optional loopback-only server (`file://`
  fallback). It writes no log of its own: whatever supervises it captures its
  output — a container runtime keeps it in the service's logs, and on the
  legacy WSL path the init script redirects it (below). **The page must answer
  on the host's loopback and on no network** — that is the requirement, and it
  is a requirement rather than an accident. Where the server runs on the host,
  loopback is where it binds, which is the default and what a bare invocation
  gets. The bind address is nonetheless a setting (`serve-dashboard.sh [port]
  [bind-address]`), because inside a container the literal bind and the
  guarantee come apart: a server on the container's own loopback is reachable
  from nothing at all, so each profile in `deploy/docker/compose.yaml` has to
  arrange the host's loopback its own way. The `tailnet` profile puts the server
  in the Tailscale sidecar's network namespace, unchanged on `127.0.0.1`, so
  Serve can proxy to its loopback (`ts-serve.json`, no Funnel). The `local`
  profile binds `0.0.0.0` inside the container and publishes
  `127.0.0.1:${DASHBOARD_PORT:-8787}:8787`, so the only route in is the host's
  loopback — the container's own addresses being on Docker's private bridge,
  which no one is on. Both land in the same place; neither widens what can
  reach the page. `deploy/agent-ops-dashboard.init` (the legacy WSL SysV path)
  sends the server's output to `<state_dir>/dashboard-server.log`, so every
  artefact the dashboard produces lands under `state_dir` and nothing is
  written beside the checkout. `RUNAS` and `APPDIR` carry no default and must be
  set in `/etc/default/agent-ops-dashboard` before the script will start; its
  remaining settings (`RUNHOME`, `PORT`, `PIDFILE`, `LOGFILE`) are defaults
  overridable from the same file, so a host that differs needs no edit to the
  installed script beyond the two required settings.
- The version stamp: `ARG`s and the `build-info.json` write at the foot of
  `deploy/docker/Dockerfile`, and the "Work out the version stamp" step of
  `.github/workflows/build-image.yml` that supplies them (with a check that the
  built image reads its own stamp back — the failure mode is otherwise silent).
- The cleanup hook in `agent-cycle.sh`; `.gitignore` and `.dockerignore`
  entries for `dashboard/data.js`, `dashboard/stamp.js` and `build-info.json`;
  the README "Monitoring" section's "Dashboard" subsection.

