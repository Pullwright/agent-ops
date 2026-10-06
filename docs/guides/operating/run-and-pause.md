# Run and pause

The pipelines run automatically on a schedule, but you can pause them with a switch, drain them gradually, or check their status.

## Which node is active

Nodes run on the role set in `.env`:

```bash
ROLE=active     # this node runs unattended cycles
ROLE=standby    # this node does not; it still syncs state with peers
```

Any number of nodes can be active. Per-item claims keep them off each other's work, and per-node minute offsets (hashed from the node's name) keep them from firing at the same moment.

## The disable/enable switch

Stop all pipelines fleet-wide with one command:

```bash
docker compose exec scheduler /app/agent-cycle.sh --disable "rolling out PR #123"
docker compose exec scheduler /app/agent-cycle.sh --disable "freeze" --for 8h
docker compose exec scheduler /app/agent-cycle.sh --disable "code freeze" --until "2026-12-25 00:00"
docker compose exec scheduler /app/agent-cycle.sh --enable
```

Check what's set:

```bash
docker compose exec scheduler /app/agent-cycle.sh --status
# switch:   ENABLED — cycles will run
# record:   /home/agent/.local/state/poetic-agents/disabled.json
# cycle:    idle
# review:   idle
# limit:    —
```

Three things worth knowing:

1. **Disables stop the *next* cycle, not one in flight.** `--status` tells you if a cycle is running. Don't recreate a container by hand (with `up -d`, `restart`, or `down`) during a cycle — use `--disable` to wait it out, then act.

2. **Disables expire by default.** They last for `disable_default_ttl`, which is derived from the configured cadence rather than fixed: four firings of `schedule.cycle_interval_minutes` wide, so it stays a few cycles rather than a few hours whatever the cadence is. Setting the key puts a floor under that derivation, never a ceiling. That prevents a forgotten switch from stopping everything silently forever. Use `--for forever` when you really mean it, and `--enable` when done.

3. **A reason is required.** It appears in `--status`, the logs, and the dashboard banner, so the next operator knows why nothing is running.

### Disabling to a specific node

By default, `--disable` stops the entire fleet by publishing to the state repository. To stop only this node:

```bash
docker compose exec scheduler /app/agent-cycle.sh --disable "maintenance" --this-node
```

Same `--for` and `--until` handling, but the effect stays local.

## Draining instead of stopping

`--disable` stops everything, including in-flight work. `--drain` is gentler: it stops new work being picked up, but lets existing pull requests finish:

```bash
docker compose exec scheduler /app/agent-cycle.sh --drain "clearing backlog before rollout"
docker compose exec scheduler /app/agent-cycle.sh --status
# switch:   DRAINED (3 left) → after work finishes → DRAINED

docker compose exec scheduler /app/agent-cycle.sh --enable
```

Same `--for`, `--until`, and `--this-node` options. The drain stays active until:
- Every configured repository has nothing left to finish, or
- The TTL expires

Once drained, nothing escalates and nothing auto-converts back — it stays that way until you `--enable` it or its TTL expires.

## Lifting a usage-limit stand-down

The pipelines also stop when the account hits its usage limit. Unlike the manual switch, a usage-limit stand-down is separate — `--enable` does not touch it. Check both with `--status`:

```bash
docker compose exec scheduler /app/agent-cycle.sh --status
# switch:   ENABLED — cycles will run
# limit:    STANDING DOWN — with no stated reset; each cycle probes whether it has lifted
```

When the message names a reset time, wait until then. When it does not (a monthly spend cap is common), each cycle probes the account automatically. Or raise the cap at [claude.ai/settings/usage](https://claude.ai/settings/usage) and tell the fleet:

```bash
docker compose exec scheduler /app/agent-cycle.sh --clear-limit "cap raised"
```

This clears both:
- The local disable file
- The fleet's shared limit record in the state repository (if configured)

Run it only after you have actually raised the cap — the next cycle will re-hit an un-raised cap and publish a fresh stand-down.

## Running cycles manually

For testing or forced runs:

```bash
# Show what would be selected, nothing more
docker compose exec scheduler /app/agent-cycle.sh --dry-run

# Run one cycle end-to-end in the foreground
docker compose exec scheduler /app/agent-cycle.sh --once

# Run cycles for one repository only
docker compose exec scheduler /app/agent-cycle.sh --repo poetic
```

Neither requires `ROLE=active`. A `--once` run engages all stages, including the Enabler — a good way to watch them work.

## Staying warm without spending

The pipeline has a no-op short-circuit: before it asks the Coordinator to select work, it fingerprints everything the Coordinator reads — repository heads, open issues, CI status, PRs, blocked items, void verdicts, the selection config, and the Coordinator prompt itself. If nothing changed, the coordinator does not run.

This saves credits: a quiet week might produce a coordinator call roughly every 15 minutes — all of them paid for — to hear "nothing changed" again. The short-circuit side-steps that.

But it still needs heartbeats and state syncs. A standby node that never spends can still:
- Publish its heartbeat
- Fetch peers' states
- Serve the dashboard
- Accept manual commands (`--status`, `--enable`, `--disable`)

So a standby is not idle: it keeps the fleet warm without burning credits.

## Next steps

- [Diagnose by symptom](diagnose-by-symptom.md) if something unexpected happens
- [Change a node](change-a-node.md) to update the image, config, or remove a node
