# Configure

A node's configuration tells it which repositories to scan, what work sources to enable, and how to behave. Configuration reaches a node through `config.json`.

## Configuration reaches a node

`config.json` is not mounted or fetched at run time — it is committed to this repository, and the image's `COPY --chown=agent:agent . /app` (`deploy/docker/Dockerfile`) bakes it in at build time. A config change reaches a node the same way a code change does: edit `config.json`, open a pull request, get it merged to `main` (which publishes a new image to `ghcr.io/pullwright/agent-ops`), then let the node roll onto that image — automatically if the `auto-update` profile is enabled, or manually; see [Roll a new image](change-a-node.md#roll-a-new-image). There is no volume mount, build-arg, or URL for supplying a different `config.json` to a running container.

Validate a changed `config.json` before it reaches a node:

```bash
./scripts/doctor.sh --config /path/to/config.json
```

See the configuration reference for all keys and their meanings: [docs/reference/configuration.md](../../reference/configuration.md).

## Key configuration sections

### Repositories

Tell the pipeline which repositories to work and in what priority order:

```json
{
  "repos": [
    {
      "slug": "Poetic-Poems/poetic",
      "sources": [
        "security",
        "issues:urgent",
        "review-feedback",
        "merge-conflicts",
        "dequeued",
        "landing-refusals",
        "abandoned-drafts",
        "failed-runs",
        "issues:high",
        "tech-debt",
        "issues:medium",
        "issues:low",
        "code-quality"
      ]
    }
  ]
}
```

- `slug` — `owner/repo` from GitHub
- `sources` — this repository's work sources, in priority order (earlier entries rank first). `issues` is really four rank tokens — `issues:urgent`, `issues:high`, `issues:medium`, `issues:low` — the same source banded by the issue's own Priority field. `abandoned-drafts` must appear somewhere in the array: it is the only route back to a draft this pipeline raised and then abandoned, so a repository cannot opt out of recovering its own stalled work. The full set of valid tokens — `security`, `tech-debt`, `code-quality`, `review-feedback`, `merge-conflicts`, `dequeued`, `landing-refusals`, `human-visibility`, `abandoned-drafts`, `failed-runs`, `project-review`, `implementation-plan`, plus the four `issues:<band>` tokens — is in [docs/reference/configuration.md](../../reference/configuration.md). A token simply absent from this array is off for this repository; there is no separate enable/disable switch.

`pr_label` (the label stamped on every PR this pipeline raises) and `branch_prefix` (`agent/` by default — issue #123 becomes `agent/123`) are fleet-wide, top-level `config.json` keys, not per-repository.

### Scheduling

`deploy/docker/render-crontab.sh` renders every cron line in a containerized node from the top-level `schedule` object, at container start:

```json
{
  "schedule": {
    "cycle_hours": "*",
    "cycle_interval_minutes": 15,
    "excluded_minutes": [0],
    "heartbeat_minutes": 5,
    "state_sync_push_minutes": 5,
    "state_sync_fetch_minutes": 7,
    "monitor_hour": 5
  }
}
```

- `cycle_hours`/`cycle_interval_minutes` — which hours, and how often within an allowed hour, the implementation cycle's crontab line fires. The *minute* itself is not a config key: it is `CYCLE_MINUTE` in a node's `.env`, or a stable hash of `NODE_NAME` when that's unset, so that multiple nodes on one account don't all fire at once.
- `excluded_minutes` — minutes the per-node minute may never land on (e.g. to avoid colliding with another scheduled job on the host)
- `heartbeat_minutes` — how often the dashboard-heartbeat cron line fires; see [Keep the dashboard fresh](watch.md#keep-the-dashboard-fresh)
- `state_sync_push_minutes`/`state_sync_fetch_minutes` — how often this node publishes and fetches shared state; see [Keeping every node warm](watch.md#keeping-every-node-warm)
- `monitor_hour` — the UTC hour the Pipeline Monitor's daily run is due (its own crontab line fires hourly and stands down until this hour, or until a pager alert fires)

See [docs/reference/configuration.md](../../reference/configuration.md) for the rest of `schedule`'s keys.

### Work-source controls

Control whether an item from a given source must be refined — given a written specification — before the Co-Ordinator may select it:

```json
{
  "refinement_policy": {
    "issues": "required",
    "tech-debt": "required",
    "security": "preferred"
  }
}
```

- `required` — the Co-Ordinator never selects an unrefined item from this source; it waits for the Refiner
- `preferred` — a refined item ranks ahead of an otherwise-equal unrefined one, but the Co-Ordinator may still select an unrefined item on its own judgement
- `exempt` (the default for any source not named here) — the source already carries its own specification (a merge conflict, a review comment, a security finding), so refinement doesn't apply

A source resolved to `required` needs `refiner_model` set — otherwise its items wait forever.

### Stage timeouts

Override a stage's wall-clock backstop or liveness-watchdog threshold, in minutes (both self-tune from history when omitted):

```json
{
  "timeout_implementer": 150,
  "timeout_reviewer": 90,
  "inactivity_implementer": 30,
  "inactivity_reviewer": 30
}
```

- `timeout_<actor>` — override for that stage's wall-clock backstop; omit it and the backstop is derived per (actor, repository, model) from history
- `inactivity_<actor>` — override for that stage's liveness-watchdog threshold; `0` disables the watchdog for that actor

Either can also be set per-repository, under that repository's own `stage_timeouts`/`stage_inactivity`. There is no monthly spend-cap key: a usage limit is Anthropic's own account limit, and the pipeline reacts to the error it gets back rather than probing a configured cap — see [Lifting a usage-limit stand-down](run-and-pause.md#lifting-a-usage-limit-stand-down).

### State sharing

If multiple nodes should share memory (blocked items, no-ops, cycles completed):

```json
{
  "state_repo": "Poetic-Poems/agent-ops-state"
}
```

The cadence this replicates on — `state_sync_push_minutes`/`state_sync_fetch_minutes` — lives under `schedule`, covered above.

## Verifying configuration

Run `doctor.sh` to validate your configuration:

```bash
docker compose exec scheduler /app/scripts/doctor.sh
```

This checks:
- `config.json` matches the schema
- All configured repositories are readable and writable
- GitHub token has needed scopes
- Model credentials are set
- The rendered crontab is valid
- Prompts and overrides exist

Exit codes:
- `0` — all checks passed
- `1` — a check failed; fix it before running cycles
- `2` — a check could not be run (network, old CLI)

Run it after editing `config.json`, on a new node before its first cycle, and whenever a cycle does something the config does not explain.

## Configuration reference

For the complete list of keys, accepted values, defaults, and how to configure per-repository overrides, see [docs/reference/configuration.md](../../reference/configuration.md).

## Related pages

- [Install a node](install-a-node.md) — how credentials reach nodes
- [Run and pause](run-and-pause.md) — how to operate the switch and drain
