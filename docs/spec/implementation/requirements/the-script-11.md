## Requirements

### The Script — requirements, continued (part 11 of 13; 54–59: Wake-poll, Liveness, Readiness, and Health…)

54. <a id="impl-54"></a>**Wake-poll: an event-driven wake between cron firings (D14, issue
    #613).** `scripts/wake-poll.sh`, on its own crontab line
    (`schedule.wake_poll_minutes`, default 2m — well under
    `cycle_interval_minutes`'s own 15m default), does one conditional GET
    (`If-None-Match`) per configured repository against a small, fixed set
    of endpoints, and invokes `agent-cycle.sh --wake-poll` — the identical
    entry point the cron line's own `@CYCLE_MINUTE@` firing uses, so a woken
    node takes the same lock (requirement 1), the same claims (17a), and the
    same back-pressure cap as a cron-fired one — the moment any of them
    answers with real content rather than a `304`. This shortens pickup
    latency for a source-relevant event without widening the
    concurrent-claim window: nothing on the claim path changes, only how
    soon `agent-cycle.sh` is invoked. The one thing `--wake-poll` itself
    changes is requirement 11a's own overrun-slot logging, which it excludes
    this invocation from — a wake starts at whatever instant the poll
    detected a change, never a minute the real crontab fires on, so it must
    not be mistaken for the cron-fired original that requirement's gate
    exists to admit (agent-ops#1324).

    Mechanism, priced under D14: a GitHub webhook receiver was rejected —
    nodes have no public ingress (they sit behind Tailscale,
    `deploy/tailscaled.init`) and standing one up needs an owner-only act
    per repository (ingress, a webhook registration, a shared secret). A
    poller needs none of that, and its own cost is bounded and measured,
    not assumed: GitHub does not charge a `304` against the primary
    rate-limit budget (verified live against this deployment's own token
    while this item was built — `x-ratelimit-remaining` held steady across
    a conditional `304` and dropped by exactly one on the very next
    ordinary call), so an idle repository's wake-poll ticks cost nothing;
    a real change costs one call per endpoint that changed, at the exact
    moment a cycle is about to spend far more anyway. Each endpoint call
    is independent, so no lock guards two overlapping wake-poll runs — the
    worst an overlap costs is a duplicated conditional GET, still free on
    a `304`.

    Endpoint choice walks `lib/noop-skip.sh`'s own fingerprint table
    source by source, since the wake trigger must be a *subset* of what
    busts that fingerprint or it wakes nodes for nothing:
    `repos/<slug>/issues` (an issue or a comment on one bumps its own
    `updated_at`, covering `issues` and `tech-debt`), `repos/<slug>/pulls`
    (a review, a review comment or a plain comment on an open pull request
    bumps its `updated_at` the same way, covering `review-feedback`,
    `landing-refusals` and `human-visibility`), `repos/<slug>/actions/runs`
    (a merge-group run — what a dequeue is decided from — is an ordinary
    workflow run, so every run *created* moves this listing's own
    `total_count` and reaches `failed-runs` and `dequeued`; a run that
    merely *completes* while a newer run already exists moves neither that
    count nor the single newest-created run the listing returns, and waits
    for the ordinary cron firing — under-coverage, which the subset rule
    above permits, never over-coverage), and
    `repos/<slug>/commits` (anything living in the repository's own tree
    changes by a push, covering `code`, `implementation-plan` and
    `project-review`). `security`/`code-quality`
    are deliberately absent: this deployment's own token cannot read
    `repos/<slug>/dependabot/alerts` (`403`, measured live) — polling an
    endpoint the token cannot read would only ever log a warning, never a
    wake. `abandoned-drafts` and `merge-conflicts` are absent by design,
    not oversight, on `lib/noop-skip.sh`'s own header: neither moves any
    forge event a poll can see (a draft goes abandoned by sitting
    untouched; a pull request turns `CONFLICTING` when its *base* moves,
    an event on a different item's own history) — the ordinary cron
    firing is never replaced, only pre-empted, and everything wake-poll
    does not cover still gets its ordinary `cycle_interval_minutes` look.

    A repository's first-ever tick on a node has no stored `ETag`, so
    every endpoint reads as "changed" and this wakes a cycle regardless of
    whether anything actually moved since `main`'s last commit — the
    identical bootstrap shape `lib/candidate-select.sh`'s own
    `emit_first_seen` already names (its `bootstrap` flag), for the
    identical reason: a first observation cannot be compared against a
    previous one that does not exist. Costs at most one extra cycle per
    (node, repository), once; the stored ETags are node-local
    (`state_dir/wake-poll/`, excluded from `state-sync.sh` replication on
    the same reasoning as `expensive-gather/`).

    **What a wake does *not* guarantee: requirement 48's rotation.** A
    woken cycle is an ordinary cycle, which means it reads the nine
    expensive bands fresh for exactly one repository — `expensive_gather_slug`,
    whichever this node has gone longest without expensively reading
    (requirement 48) — and reuses its cached snapshot for every other
    configured repository. A wake triggered by a change in repository *X*
    therefore only re-reads *X* when the rotation happens to land there,
    and the change is not re-offered: `scripts/wake-poll.sh` stores the new
    `ETag` before it wakes, so that endpoint answers `304` on the next tick
    whether or not the cycle it woke looked at *X*. The improvement this
    requirement claims is accordingly statistical rather than
    item-deterministic — every woken cycle advances the rotation by one
    step, so a fleet under wake-poll reaches each repository's fresh read
    far more often than `cycle_interval_minutes` alone would — and no item
    is ever *lost* by it, since the ordinary cron firing still rotates on
    its own schedule. Biasing `expensive_gather_pick_repo` toward the woken
    repository would make it deterministic, at the cost of the
    every-repository-eventually guarantee that function is built on; that
    trade is not made here.

    **What a wake does not honour: `schedule.excluded_minutes`.** A wake
    invokes `agent-cycle.sh` the instant a change is detected, on whatever
    minute the wake-poll crontab line itself fired — without consulting
    `schedule.excluded_minutes` at all, so it can start a cycle on a minute
    the exclusion forbids the *scheduled* `@CYCLE_MINUTE@` firing from ever
    landing on. This is intentional, not an oversight: the exclusion's
    contract governs the scheduled *start* minute rendered into the crontab
    (`deploy/docker/render-crontab.sh`), guarding against a conflicting
    workload that runs at a fixed minute; a cycle, once started, already
    runs across every minute of the hour regardless of which minute
    triggered it, so guarding an out-of-band wake's own start-minute the
    same way would buy little against that same conflict. Skipping the wake
    instead of running it late is not an option either: `scripts/wake-poll.sh`
    stores the new `ETag` before it wakes (see above), so a wake skipped on
    an excluded minute would silently consume the change and leave the item
    waiting for the next ordinary cron firing with no second wake to catch
    it.

    A wake logs one `wake-poll-triggered` event (`{ts, cycle: null, node,
    event, changed}`, the same out-of-cycle envelope shape
    `scripts/publish-revert-rate.sh`'s own `rework` rows use) — never a
    quiet tick, matching this repository's own "don't pay to log the
    no-op case" convention. Its human-readable output, including the quiet
    ticks, goes to `wake-poll.log`, which `scripts/rotate-logs.sh` bounds
    (requirement 2.6) and `scripts/state-sync.sh` keeps local to the node,
    on the same terms as every other per-tick diagnostic log.

    **Acceptance measurement.** A poll-driven `first-seen` cannot honestly
    measure a poll-driven pickup-latency improvement, because waking a
    node moves both ends of the gap `scripts/pickup-metrics.sh` already
    measures (`first-seen` to `selection`) earlier by the same amount.
    `lib/candidate-select.sh`'s `emit_first_seen` therefore carries a
    candidate's own `created_at` forward as `forge_created_at` when the
    source provides one (`scripts/gather-issues.sh` and
    `scripts/gather-tech-debt.sh` both already do), and
    `lib/item-lifecycle.sh`'s `item_lifecycle_pickup_pairs` pairs it
    against the item's `selection` for a second measure,
    `pickup_latency_forge_anchored` — anchored on the forge's own clock,
    not this fleet's poll cadence, and therefore not bounded below by
    `cadence_bound_minutes` the way `pickup_latency` is. A source whose
    candidates carry no `created_at` simply contributes nothing to this
    second measure (`coverage.forge_anchored` counts how many paired
    items did); this is not a defect — it names exactly which sources'
    improvement is honestly measurable today.

    **The claim race.** `agent-cycle.sh`'s own claim step (17a) is already
    race-correct by construction and unchanged by this requirement — a
    wake reaches it through the identical path a cron firing does, adding
    no new entry point. `test/wake-poll.test.sh` demonstrates this
    directly: two claims racing the same item through `lib/claim.sh`,
    framed as two "woken" nodes rather than test/claim.test.sh's own two
    cron-fired ones, still resolve to exactly one winner (exit 0) and one
    contended loss (exit 3, `cause: "held"`) — the same invariant
    `scripts/pickup-metrics.sh`'s contended-loss-per-selection ratio
    already counts.

57. <a id="impl-57"></a>**Liveness: is supercronic still firing this node's jobs at all (issue
    #608, Phase 2).** A dedicated crontab line, carrying no substitution
    token of its own (`deploy/docker/crontab.tmpl`), touches
    `state_dir/.node-alive` every minute — deliberately the cheapest thing
    supercronic can be asked to prove it is still scheduling jobs, and
    deliberately decoupled from every other job's own health: a wedged
    `publish-dashboard-launcher.sh` window or a stuck cycle must not read
    as "not live", and a job doing real work to prove liveness could itself
    hang and take the liveness signal down with it. `lib/node-health.sh`'s
    `node_health_liveness` reads the marker's own mtime against
    `node_health_live_stale_after_minutes` and answers `{live, age_s,
    reason}` — never the cycle lock (`lock.json`): a lock held by a running
    Implementer stage is the pipeline doing its job, and a liveness probe
    that restarted a node over that misreading would be the graceful-drain
    failure arriving by another route. Never returns non-zero, and reports
    `live: false` with a stated reason rather than a bare boolean when the
    marker has never been touched at all (a container in its first minute).

58. <a id="impl-58"></a>**Readiness: could a cycle start now.** `lib/node-health.sh`'s
    `node_health_readiness` composes a `{ready, unmet}` verdict from facts
    `scripts/node-health.sh --ready` gathers, every unmet condition named
    by its own stable code rather than folded into a bare boolean:
    `credentials-missing` (`$CLAUDE_CONFIG_DIR/.credentials.json` absent —
    existence only, on the same terms `scripts/doctor.sh --unattended`
    already holds to, requirement 1c — or, where `providers` names an entry
    whose `substrate` is `grok-build`, that provider carrying neither
    `XAI_API_KEY` nor a subscription login at `$GROK_HOME/auth.json`, the
    same existence-only terms and the same code, each cause stating which
    it is in its own `detail`; the xAI condition is gated on that
    configuration, so an installation configuring no `grok-build` provider
    answers exactly as it did before the condition existed),
    `gh-unauthenticated`/
    `gh-forge-unreachable` (`lib/github-limit.sh`'s `github_auth_probe`, the
    two failure shapes requirement 2.0b already distinguishes),
    `disk-low` (`state_dir`'s free space against `min_free_workspace_bytes`,
    `lib/disk-space.sh`), `github-core-budget-low`/
    `github-graphql-budget-low` (against `github_min_core_budget`/
    `github_min_graphql_budget`), `node-disabled`/`fleet-disabled` (the two
    switches, requirements 2.4/2.3a — read from local evidence only, see
    58a) and `usage-limit-freeze` (the cooldown of requirement 2.1, read
    from the local log union only, see 58a). A condition this node cannot
    read at all — an unreadable disk meter, a `null` budget figure with
    `gh_auth: "ok"` — supports no verdict and is never folded into
    "not ready": only a reading that actually crosses its floor blocks
    readiness, the same "no evidence, no stand-down" reasoning requirement
    2.0's own `unknown` already rests on. An unreachable forge is the one
    exception stated as its own code (`gh-forge-unreachable`) rather than
    folded into "unknown": it is honestly evidence readiness cannot
    proceed, not merely evidence this node cannot say so.

    58a. <a id="impl-58a"></a>**No network call beyond the one exempt read, and no live fetch of
    fleet state.** `--ready` makes exactly one network call —
    `gh api rate_limit`, cached in `state_dir/.node-health-ratelimit-cache.json`
    with a TTL of `node_health_forge_check_cache_seconds` — so that an
    orchestrator polling readiness every few seconds cannot itself become a
    load source. That one call answers both halves of the check: its own
    response is classified into `github_auth_probe`'s vocabulary *and* read
    for the two budget figures, rather than the probe being asked first and
    the body fetched after, which would make the identical request twice per
    TTL window. `github_auth_probe` is consulted only when that call did not
    come back usable, where it buys the diagnosis the response cannot give
    (a rejected token, no token at all, an unreachable forge) and no budget
    figure exists on that path regardless. The cached answer is one JSON
    object (`{verdict, detail, core, graphql}`) read back with `jq`, never a
    delimited line, because a delimited line cannot carry this record safely:
    `detail` is empty on exactly the path that has budget figures to report,
    and `IFS=$'\t' read` drops an empty field rather than preserving it —
    tab is an IFS *whitespace* character, so a run of them folds into a
    single separator — which would shift every remaining figure one field
    left and have readiness compare the GraphQL pool against
    `github_min_core_budget`. Read from `/rate_limit`'s own body rather than a
    metered call's headers because that endpoint is exempt from the limits
    it reports (`github_min_core_budget`'s own note); this is a coarser,
    cheaper signal than requirement 2.0's own header-based budget gate, not
    a replacement for it. The node and fleet switches and the usage-limit
    freeze are read from local evidence only — `toggle_state` (a local
    file), `fleet_disabled_state_cached` (`lib/toggle.sh`, added
    alongside `fleet_disabled_state` for this requirement: the same
    vocabulary, read from `fleet_cache_file`'s own last-fetched copy
    instead of a live `fleet_flag_fetch`) and the local fleet log union
    (`lib/fleet.sh`'s `fleet_logs`, never a peer over the network) folded
    with the local `fleet-cache/limit.json` copy via `limit_later_record` —
    never a live fetch of `fleet/disabled.json` or `fleet/limit.json`: a
    stale local copy costs at most one wrongly-answered poll between the
    ordinary fetch cadence's own ticks, the same trade every other
    local-cache reader in this codebase already makes. A switch in `drain`
    mode does not block readiness — a cycle can still start while a drain
    winds down, exactly as requirement 2.4's own cycle-start check treats
    it — only a full stop does.

    The one cached `/rate_limit` read takes the node's D24 egress path from
    *whichever* container makes it — `deploy/docker/compose.yaml`'s
    `scheduler` and `node-health` services both carry the same proxy
    variables and both reach the forge only through the internal-only
    `egress` network — the scheduler confined to it alone, `node-health` on
    `default` and `egress` both for its published loopback port — so a
    readiness verdict is never evidence gathered over a route the cycle it
    reports on could not use (issue #1587 — the "answer
    came from a path the subject does not use" shape issue #608 already
    exists to close, one layer out). This matters because the cache file
    itself is shared: `state_dir/.node-health-ratelimit-cache.json` lives on
    the `state` volume both containers mount, so a verdict either container
    writes is read back by the other within the TTL — the two must not read
    the forge by different routes, or the dishonesty just moves from the
    answer to the cache behind it.

59. <a id="impl-59"></a>**Health: is this node doing its job over time, composed from named
    components, never restating liveness.** `lib/node-health.sh`'s
    `node_health_health` folds exactly two named components —
    `outbound` (`lib/fleet.sh`'s `fleet_publication_status` over this
    node's own `.state-sync-published.json`, requirement 2.5, #602) and
    `converged` (itself a fold of `updater`, `lib/updater-health.sh`'s
    `updater_status`, requirement 2.5, #603, and `image`,
    `lib/image-drift.sh`'s `image_drift_status`) — read back from this
    node's own last-published `heartbeat.json`
    (`workspace_root/.agent-ops-state/heartbeat.json`) rather than
    recomputed: `scripts/node-health.sh` makes no state-sync call, no
    registry read and no ledger read of its own (requirement 60c). The
    fold (`node_health_fold`, used at both the `converged` level and the
    top level, so the two can never compose differently): `fail` if
    anything folded is `fail`; `unknown` if anything is `unknown` and
    nothing is `fail`; `ok` only when everything folded is `ok`. A
    component whose source does not exist yet — no heartbeat has ever been
    published, or it predates a field — reads `unknown`, never `ok`: the
    2026-08-08 failure of two nodes self-certifying freshness for four days
    is exactly the green-endpoint-that-means-nothing this composition rule
    exists to close.

    59a. <a id="impl-59a"></a>**`updater` and `image` component mappings.** `updater`: `stuck`
    (a fault only a human clears) is `fail`; `rolled` and `deferring` (both
    ordinary, the second self-resolving) are `ok`; `null` (no ledger
    evidence yet) is `unknown`. `image`: `current` is `ok`; `unverified`
    (a registry read that failed, or an image with no revision label) is
    `unknown`; `behind` is `ok` while the registry's newest image is
    younger than `image_behind_grace_hours` (a roll waits for a cycle in
    flight, so this is routine) and `fail` once it is older, or once
    `registry_created_at` cannot be read at all — mirroring
    `dashboard/index.html`'s own `imageLine` colouring exactly (an
    unreadable age reads the same as "past grace" there too), so the
    endpoint and the dashboard page can never disagree about what "behind"
    means; `null` (this node runs no CI-stamped image, or the heartbeat
    predates this field) is `unknown`.

