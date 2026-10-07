## Requirements

### The Script — requirements, continued (part 10 of 10; 60–60: The CLI surface: `scripts/node-health.sh`…)

60. **The CLI surface: `scripts/node-health.sh`.** `[--live|--ready|--health|
    --metrics] [--json] [--config FILE] [--state-dir DIR] [--peers-dir DIR]`
    (the last three test-only overrides, on the same convention
    `scripts/pickup-metrics.sh` already carries). Exactly one compact JSON
    object on stdout per call, always — `--json` is accepted but changes
    nothing, since there is no other rendering to select. Exit code matches
    the verdict: `--live`/`--ready` exit `0` when the verdict is good, `1`
    otherwise; `--health` exits `0` (`ok`), `1` (`fail`) or `2` (`unknown`)
    — a third code, distinct from both, since "the endpoint could not tell"
    is not the same fact as "the endpoint tells you it is broken"; `--metrics`
    always exits `0`, since it reports data, never a verdict. No argument
    prints `--health`.

    60a. **Read-only throughout.** Touches no lock, writes no event,
    publishes nothing, and — beyond the one cached forge read of 58a —
    makes no network call and triggers no state-sync push, gather, dashboard
    publish or `claude` invocation: every verdict computes on demand from
    what cron already wrote. `test/node-health-cli.test.sh` asserts this
    directly — a fixture `state_dir`/`workspace_root` are byte-identical,
    file for file, before and after every mode runs, excepting only the one
    cache file 58a's own header documents.

    60b. **The three verdicts genuinely diverge, from one CLI, in one
    process.** `test/node-health-cli.test.sh` builds a fixture that is live
    (a fresh marker), not ready (the node switch set) and unhealthy (a
    `stuck` updater verdict and a stale publication) all at once, and
    asserts all three answers from the same three calls — the acceptance
    criterion this whole item exists to satisfy, proven end to end through
    the CLI rather than only through `lib/node-health.sh`'s own pure
    functions (`test/node-health.test.sh`).

    60c. **The container-runtime healthcheck runs the identical CLI.**
    `deploy/docker/compose.yaml`'s `scheduler` service carries a
    `healthcheck:` running `scripts/node-health.sh --live` *inside* the
    container — the same command a Kubernetes `exec` probe would run, so
    the two can never disagree about what "live" means. Deliberately the
    liveness verdict alone, never readiness or health: a sidecar answering
    for a wedged scheduler beside it would be the identical
    self-certification the 2026-08-08 incident exposed, arriving by a new
    route. `docker compose config` renders it cleanly.

    60d. **The HTTP surface is a second front over the identical
    computation, never a second answer.** `scripts/node-health-server.py`
    answers `/livez`, `/readyz`, `/healthz`, `/metrics` by shelling out to
    the same `scripts/node-health.sh` the container healthcheck runs
    in-container — `200` when the underlying call exits `0`, `503`
    otherwise (`/metrics`: always `200`, since it reports data, not a
    verdict), the CLI's own JSON body either way; any other path answers
    `404` — including a path that merely resembles one of the four (a
    trailing slash, a query string), which is matched literally rather than
    normalised. Holds no cache and no state of its own — a request while
    `state_dir` is unreadable still returns valid JSON, reading `unknown`
    rather than hanging or stack-tracing, because the underlying CLI itself
    never crashes on that input (`lib/node-health.sh`'s own contract).
    Served by the `node-health` compose service, which is in that one
    profile and no other, so it is off unless a node opts in — bound
    `0.0.0.0` *inside* the
    container, published to the host's own loopback alone
    (`127.0.0.1:${NODE_HEALTH_PORT:-8788}:${NODE_HEALTH_PORT:-8788}`), the
    identical loopback-only pattern `scripts/serve-dashboard.sh`'s own
    header documents for `dashboard-local`. This service is never what
    makes the scheduler's own liveness honest (60c already is, in-process);
    it exists solely for a reader — a collector, an orchestrator's own
    URL-level probe — that can only speak HTTP. It also carries the
    scheduler's own `HTTPS_PROXY`/`HTTP_PROXY` variables (both spellings)
    and sits on `default` and `egress` both, alongside its loopback
    publishing — never `egress` alone, since that network is
    `internal: true` and a published port into it is not the reachable
    mapping this paragraph already requires — so the one forge read 58a
    describes leaves through the same D24 egress path the scheduler uses
    (issue #1587).

    60e. **`--metrics`' field list is the node metrics shape
    `docs/METERING-SCHEMA.md` documents under its own stability policy.**
    Node identity (`node`, `role`, `ts`, `version`), all three other
    verdicts and their components in full (`live`, `ready`, `health`),
    cycle counters over this node's own retained `log.jsonl`
    (`cycles.log_selections`, `cycles.log_attempts_failed` — this node's
    own log only, deliberately never the fleet union, so nothing here
    double-counts against whatever else unions each peer), and per-
    container resource actuals-against-budget where issue #606's collector
    has produced them (`host-facts/<node>.json`'s own `budget` section,
    `containers`, `null` when absent — reported where it exists, never
    fabricated: issue #606 itself, not this item, produces those figures).
    Explicitly not Prometheus/OpenMetrics, not OTLP, and no adapter to
    either — the wire-format question issue #614 owns, deliberately parked
    by this item's own scope. `test/node-health-cli.test.sh` asserts every
    top-level field's presence against this documented shape.

    60f. **New config keys, documented and rendered.**
    `node_health_live_stale_after_minutes` (57) and
    `node_health_forge_check_cache_seconds` (58a) — both flat top-level
    keys, `config.schema.json`'s existing convention, never nested: this
    feature is fleet-wide like `node_stale_after_minutes` and
    `updater_stuck_after_minutes` beside it, not per-repository like
    `repos[].preview`. Neither the HTTP bind address nor its port is a
    `config.json` key — `NODE_HEALTH_PORT` is a compose/`.env` variable on
    the identical convention `DASHBOARD_PORT` already carries for the
    dashboard's own `local` profile, since a listening port is a deployment
    topology choice, not pipeline behaviour. `scripts/render-config-table.sh
    --check` passes against both new keys.

