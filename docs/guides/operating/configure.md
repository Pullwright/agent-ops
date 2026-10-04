# Configure

A node's configuration tells it which repositories to scan, what work sources to enable, and how to behave. Configuration reaches a node through `config.json`.

## Configuration reaches a node

For a containerized node, configuration is **baked into the image or mounted as a volume**:

1. **Via volume mount** (recommended for changing config without rebuilding):
   ```bash
   # In .env or docker-compose override
   volumes:
     - /path/to/config.json:/app/config.json:ro
   ```

2. **Via image rebuild** (if you want config shipped with the image):
   ```bash
   docker build --build-arg CONFIG=/path/to/config.json deploy/docker
   ```

3. **Via entrypoint override** (if your orchestrator supplies it):
   ```bash
   AGENT_OPS_CONFIG_URL=https://your-config-server/config.json
   ```

See the configuration reference for all keys and their meanings: [docs/reference/configuration.md](../../reference/configuration.md).

## Key configuration sections

### Repositories

Tell the pipeline which repositories to scan and how often:

```json
{
  "repos": [
    {
      "name": "Poetic-Poems/poetic",
      "pull_label": "autonomous-agent",
      "branch_prefix": "agent/",
      "work_sources": ["issues", "tech-debt", "code-quality", "security"]
    },
    {
      "name": "Poetic-Poems/poetic-fiddle",
      "pull_label": "autonomous-agent",
      "branch_prefix": "agent/",
      "work_sources": ["issues", "tech-debt"]
    }
  ]
}
```

- `name` — `owner/repo` from GitHub
- `pull_label` — label the pipeline applies to its PRs (used to track autonomy; keep it unique per node)
- `branch_prefix` — branch prefix for new work (`agent/` for issue #123 becomes `agent/123`)
- `work_sources` — which sources to scan:
  - `issues` — GitHub issues (general work)
  - `tech-debt` — GitHub issues labelled `pw::type:tech-debt`
  - `code-quality` — Dependabot and CodeQL alerts
  - `security` — GitHub security alerts
  - `project-review` — recommendations from this repo's own reviews

### Scheduling

Control how often cycles run and what happens when they do:

```json
{
  "schedule": {
    "cycle_interval_minutes": 15,
    "cycle_minute": null,
    "monitor_hour": 3
  }
}
```

- `cycle_interval_minutes` — how often the coordinator picks work (default 15)
- `cycle_minute` — which minute of the hour (null to hash from the node's name, to spread multiple nodes)
- `monitor_hour` — which hour (UTC) the Monitor runs its digest

### Work-source controls

Enable or disable individual work sources globally:

```json
{
  "coordinator": {
    "enabled_sources": {
      "issues": "preferred",
      "tech-debt": "required",
      "security": "preferred",
      "code-quality": "preferred"
    }
  }
}
```

- `required` — must be specified before selection (waits for the Refiner)
- `preferred` — a specified item ranks higher, but unspecified items may still be picked
- `exempt` — source carries its own spec (review feedback, merge conflicts, etc.)

### Usage limits and timeouts

Cap spending and set stage timeouts (which self-tune based on history):

```json
{
  "spend_cap_monthly_usd": 100,
  "timeout_implementer_minutes": 90,
  "timeout_reviewer_minutes": 90,
  "inactivity_implementer_minutes": 30,
  "inactivity_reviewer_minutes": 30
}
```

- `timeout_*` — hard limit for a stage
- `inactivity_*` — if the stage produces no output for this long, it's killed as wedged
- `spend_cap_*` — refuse work once the cap is hit (probed every cycle)

### State sharing

If multiple nodes should share memory (blocked items, no-ops, cycles completed):

```json
{
  "state_repo": "Poetic-Poems/agent-ops-state",
  "state_sync_push_minutes": 5,
  "state_sync_fetch_minutes": 7
}
```

Every node fetches peers' states every 7 minutes and pushes its own every 5, so fleet-wide decisions converge within a few minutes.

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
- Cron schedule is valid (if this is a host node)
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
