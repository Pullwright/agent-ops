# Watch

Monitor your nodes using the dashboard, event logs, and the Monitor's digest.

## The dashboard

A local, single-page dashboard shows everything at a glance:
- Active cycles and their status
- Usage-limit stand-downs and why
- Open agent PRs and their CI status
- Recent cycles with cost, duration, and model
- Failures, blocked and void items
- Work sources the Coordinator sees
- Hourly `doctor.sh` checks (Doctor section)
- Stage health per node
- Fleet pager alerts
- Model spend by day and actor

### View it locally

Enable the `local` profile in `.env`:

```bash
COMPOSE_PROFILES=local
```

Compose starts a `dashboard-local` service running `serve-dashboard.sh` inside the container, published to the host's loopback at `http://127.0.0.1:8787` (or the port set in `DASHBOARD_PORT`). Visit that address in your browser.

The page auto-refreshes every `dashboard_refresh_seconds` (5s by default). Untick *auto-refresh* to pause it while you read.

### View it over Tailscale

If your node has the `tailnet` profile enabled:

```bash
COMPOSE_PROFILES=tailnet
TS_AUTHKEY=<key>
```

The dashboard is served over HTTPS to your tailnet at `https://<NODE_NAME>.<tailnet>.ts.net`. It never reaches the public internet — the Tailscale sidecar handles the network namespace.

## Keep the dashboard fresh

The dashboard refreshes at the end of every cycle. Keeping it current between cycles — reflecting in-flight runs and live GitHub status — needs no setup: the container's own crontab already runs `scripts/publish-dashboard-launcher.sh` every `schedule.heartbeat_minutes` (5 minutes by default), and that launcher self-loops sub-minute internally, regenerating the dashboard roughly every 5 seconds without hammering the GitHub API. To change the cadence, set `schedule.heartbeat_minutes` in `config.json`.

To force an immediate refresh by hand:

```bash
docker compose exec scheduler /app/scripts/publish-dashboard.sh
```

## Watch a node's events

The pipeline records every event — work selected, items blocked, cycles completed, models used, state synced — to a JSON log. One event per line.

`state_dir` is a Docker volume, not a host directory, so read the log through the scheduler container at its in-container path:

```bash
# Follow the log as it runs
docker compose exec scheduler tail -f /home/agent/.local/state/poetic-agents/log.jsonl

# See how the last 10 cycles ended
docker compose exec scheduler \
  jq -r 'select(.event == "cycle-end") | "\(.ts)  exit_code=\(.exit_code)"' \
  /home/agent/.local/state/poetic-agents/log.jsonl | tail -10

# Why did a cycle stand down?
docker compose exec scheduler \
  jq -r 'select(.event == "stand-down") | "\(.ts)  \(.reason)"' \
  /home/agent/.local/state/poetic-agents/log.jsonl | tail -5

# What items were marked void, and why?
docker compose exec scheduler \
  jq -r 'select(.event == "item-void") | "\(.ts)  \(.repo)#\(.item)  \(.detail)"' \
  /home/agent/.local/state/poetic-agents/log.jsonl | tail -10
```

An item that is *blocked* (as opposed to void) is not a `log.jsonl` event at all — it's a `blocked` (or `blocked:<reason>`) label on the GitHub issue or pull request itself; see [An item is blocked or void](diagnose-by-symptom.md#an-item-is-blocked-or-void).

For a complete description of event types and fields, see `docs/spec/implementation/requirements` requirement 33.

## Keeping every node warm

A multi-node fleet needs to share memory: blocked items, void verdicts, no-op fingerprints, completed cycles. So every node publishes and fetches state through a shared state repository:

| Mode | When | What |
|---|---|---|
| `push` | Every 5 minutes and at the end of every cycle | Publishes `state_dir` as this node's branch, with a heartbeat (node name, role, image, timestamp) |
| `fetch` | Every 7 minutes | Materializes every peer's branch under `peers/`, and prunes a peer whose branch is gone |

Before either mode touches the state repository, it checks object integrity (`git fsck`). If a disk corruption is detected, the repository is rebuilt from source and the rebuild is logged.

What travels: logs, cycle records, the disable switch, the usage-limit stand-down.
What stays local: live locks, the generated dashboard, sync logs.

The pipeline reads the **union** of all logs — a blocked item discovered by one node prevents every node from re-trying it. The per-item claims are the lock underneath; there is no lease and no leader.

To enable state sharing, set `state_repo` in `config.json`:

```json
{
  "state_repo": "Poetic-Poems/agent-ops-state"
}
```

The cadence shown in the table above — `push` every 5 minutes, `fetch` every 7 — comes from `schedule.state_sync_push_minutes`/`schedule.state_sync_fetch_minutes`; see [Configure](configure.md#scheduling).

Every node needs a `GH_TOKEN` that can read and write to the state repository.

## Which node runs the cycles

The role says whether *this* node spends unattended:

```bash
ROLE=active     # this node runs cycles
ROLE=standby    # this node does not
```

On a containerized node, set `ROLE=active` in `.env` — the scheduler passes it through as `AGENT_OPS_ROLE` and defaults it to `standby` when missing. Set to exactly `active` (case and whitespace ignored) — unset, empty, or misspelt all mean standby.

**Any number of nodes can be active at once.** Per-item claims keep them off each other's work, and per-node minute offsets (hashed from the node's name) keep them from firing simultaneously.

A standby node still:
- Publishes its heartbeat
- Fetches every peer's memory
- Serves the dashboard
- Accepts manual commands (`--status`, `--enable`, `--disable`)

A standby is not idle: it keeps the fleet warm without spending.

## The Pipeline Monitor

A third pipeline runs once a day (and again after any pager alert) and reads the other two. It asks three questions:

1. What is broken now?
2. What limited throughput, and which lever might fix it?
3. What is new?

It produces a digest report and files mechanical findings (things with knowable fixes) as `pw::type:tech-debt` issues, tactical findings (configuration levers) as `pw::decision` records, and strategic findings or owner calls as escalation issues.

See the digest for today:

```bash
docker compose exec scheduler \
  cat /home/agent/.local/state/poetic-agents/monitor/"$(date -u +%F)"/report.md
```

To disable the Monitor, set `monitor_model` to `""` in `config.json`.

For the full specification, see `docs/spec/monitor.md`.

## Related pages

- [Run and pause](run-and-pause.md) — operate the switch and drain
- [Install a node](install-a-node.md) — set up dashboards and profiles
- [Diagnose by symptom](diagnose-by-symptom.md) — troubleshoot issues
