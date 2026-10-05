## Acceptance checks

Continued (part 2 of 6; items 2m–7f).

2m. **The installation has one push-notification channel, and everything the
   fleet already knows to log about an escalation, a page, or a stand-down
   also reaches it (issue #1279).** `notify_post` (`lib/notify.sh`) is the
   whole of it: given `notify_webhook_url` (fleet-wide, `escalation_webhook_url`
   accepted as an alias for one release when `notify_webhook_url` is itself
   empty), it POSTs one compact JSON body — `{event, key, title, url, repo,
   node, ts, detail}`, plus `count` when a suppressed burst preceded this
   send — for every event in one of three classes, each gated independently
   by `notify_events` (default all three):

   - `escalation` — `escalation-filed` on every fresh issue
     `create_escalation_issue` creates (never its own duplicate-guard reuse);
     `escalation-unfiled` on every filing failure (`escalation_webhook_notify`,
     `lib/enabler.sh` — the whole of requirement 2m before this rewrite, now
     one event class among three rather than the channel's only job);
     `escalation-closed` on the one retire path living alongside
     `create_escalation_issue` in the same file, `crash_loop_retire_resolved`
     (requirement 2.7).
   - `pager` — `pager-fired` and `pager-cleared`, posted from `pager_file`/
     `pager_close` (`lib/pager.sh`, requirement 51) themselves, guarded by
     `declare -F notify_post` so that file stays sourceable without
     `lib/notify.sh` alongside it (`test/pager.test.sh` sources it standalone).
     `pager_evaluate` gains two more trailing, optional parameters for this —
     `NOTIFY_EVENTS_JSON` and `NOTIFY_MIN_INTERVAL`, after #1281's own three
     — threaded through to `pager_file`/`pager_close`, and `pager_file`/
     `pager_close` each gain the same pair plus the webhook URL and the union
     log to read. Omitted, as every call site before this and every existing
     test leaves them, they read as empty, which `notify_post` treats as "no
     notify channel configured" exactly as it treats an unset
     `notify_webhook_url`.
   - `fleet-standdown` — `fleet-standdown-begin`/`fleet-standdown-end` for
     each of the three fleet-wide stand-downs a switch someone set can leave
     silently in force: the usage-limit cooldown (`lib/standdown.sh`'s own
     `stand-down`/`limit-cleared` events, requirement 2.1), the fleet switch
     at either scope — node or fleet (`agent-cycle.sh`'s own `stand-down`/
     `enabled` events and `lib/manage.sh`'s `--enable`, requirement 2.3/2.3a)
     — and the merge-autonomy kill switch (`lib/manage.sh`'s
     `--kill-merge-autonomy`/`--restore-merge-autonomy`, requirement 2.3b).
     `key` distinguishes the four instances (`standdown:usage-limit`,
     `standdown:node-switch:<node>`, `standdown:fleet-switch`,
     `standdown:merge-autonomy-kill`) so the coalescing below is per
     stand-down, not one bucket for all of them — and each instance's
     `begin` and `end` share that one key, which is why the coalescing
     below keys on the event too.

   An event whose class is not a member of `notify_events` is dropped before
   `notify_webhook_url` is even read — never sent, never logged. Every
   guarantee requirement 2m always made carries over unchanged: no `gh`/
   `GH_TOKEN` anywhere in this path, best-effort (a POST failure logs one
   local `notify-failed` and never propagates), `https://`-only on
   `notify_webhook_url` and `escalation_webhook_url` (the schema's own
   pattern) and on `NOTIFY_WEBHOOK_URL` (`notify_webhook_url_env_or_empty`,
   `lib/notify.sh` — see below, since the environment has no schema to be
   checked against), and never blocks the cycle (a 10s `curl --max-time`).

   **`notify_min_interval_seconds` (default 600) coalesces a burst per
   `(event, key)` pair**, event-sourced over the log rather than a cache: a
   POST inside the interval since that pair's last `notify-sent` logs
   `notify-suppressed` instead of sending, and the next allowed send folds
   every suppressed one since into its own `count` field — the thirty
   escalations in 48h of 2026-08-28 (issues #933–#938), one dead credential
   re-filing `escalation-unfiled` every cycle for two days, arrives as one
   message and a count rather than thirty. The event is half of the key
   because the two halves of a transition pair share one `key` by
   construction — `fleet-standdown-begin`/`-end` on `standdown:usage-limit`
   and its three siblings, `pager-fired`/`pager-cleared` on the pager's own
   key — and a stand-down in force re-posts its `begin` every cycle, so
   keying on `key` alone would hold that key's last `notify-sent`
   permanently younger than the interval and suppress the `end` an operator
   is actually waiting on. A read log this node has not written yet is
   ordinary rather than an error (a freshly provisioned node, before its
   first cycle): the read falls back to `/dev/null`, so nothing is found and
   nothing is suppressed, rather than failing a redirect and aborting a
   caller running under `set -e`. The read side prefers the fleet-wide union log
   (`${union_log:-$log_file}`) so two nodes racing the same key still
   coalesce; every call site reached before that union is built falls back to
   this node's own log, the same degradation `escalation_autonomy_*`'s own
   `${union_log:-$log_file}` already accepts elsewhere. Three bands are on
   that side of the line: `lib/manage.sh`'s management commands, and — because
   `union_log` is not assigned until the lock band — both switch checks in
   `agent-cycle.sh`, the node switch and the fleet switch. The node switch
   carries the node in its own key (`standdown:node-switch:<node>`), so per-node
   coalescing is all it ever wanted. `standdown:fleet-switch` does not: one
   fleet-wide fact, re-posted by every node on every cycle the switch holds,
   coalesces per node rather than across the fleet, so an operator sees one
   message per node per `notify_min_interval_seconds` for as long as it is set.
   Narrowing that to one message for the fleet means building the union
   earlier in the cycle than the lock band needs it, which is tracked
   separately (#1369) rather than folded in here.

   **Enabling it is two edits per node, not one — unchanged from before this
   rewrite.** The POST leaves the scheduler through the egress fence like
   every other outbound call — the scheduler's own `HTTPS_PROXY`
   (compose.yaml) points at squid, which is default-deny (D24, "The node
   stack") — so a webhook host that is not in that node's `EGRESS_EXTRA_ALLOW`
   (`.env`) draws a proxy `403`, `curl -f` returns non-zero, and the node
   logs `notify-failed`. `notify_webhook_url` is set fleet-wide (`config.json`
   ships in the image, so its value is every node's value); the allowlist
   entry is per node and ships with none, because no host can be guessed for
   an installation. `scripts/doctor.sh` gains two checks for this: a `warn`
   whenever `escalation_webhook_url` is set (the alias is good for one
   release only — rename it), and, in its Egress section, a live reachability
   probe of the resolved webhook host through whatever fence is in place
   (`curl`, no `-f`, same idiom as the section's other three canary checks) —
   a `warn` naming the host when it does not answer, so a silently
   misconfigured channel is a doctor finding, not a discovery the day an
   escalation needed it. **The host, never the URL**: a webhook secret
   ordinarily rides in the URL's own path
   (`https://hooks.slack.com/services/T…/B…/…`), which `lib/redact.sh`'s
   token-shaped patterns do not match, and every `warn` message is copied
   verbatim into `state_dir/.doctor-status.json`, which `scripts/state-sync.sh`
   pushes to the state-mirror repository and `scripts/publish-dashboard.sh`
   renders. The host is also all the message's own advice needs, since
   `EGRESS_EXTRA_ALLOW` is keyed on exactly that.

   **`notify_webhook_url`'s value is a credential — possession of the URL is
   authorisation to post to it — and `config.json` is both fleet-wide and
   tracked in this public repository, so it is a poor place to keep one
   (issue #991, TD-PPagop-26082516).** The `NOTIFY_WEBHOOK_URL` environment
   variable is this channel's non-public, per-node source, read by
   `agent-cycle.sh` and `scripts/publish-dashboard.sh` alike and resolved
   ahead of both config.json keys by `notify_resolve_webhook_url`'s own
   three-argument form (`lib/notify.sh`) — an installation that sets it can
   leave `notify_webhook_url` empty in the tracked file entirely, the same
   shape `GH_TOKEN` and `PULLWRIGHT_APPROVER_APP_ID` already use for every
   other credential this system reads. Plumbed through
   `deploy/docker/compose.yaml`'s shared `x-agent-ops-env` anchor exactly like
   those two, so both the scheduler and the dashboard containers see it.
   Validated at read time by `notify_webhook_url_env_or_empty` — empty or
   `https://` passes through unchanged, anything else is rejected (logged to
   fd 2) and treated as though the variable were unset, rather than handed to
   `notify_resolve_webhook_url` and POSTed to garbage, since this source has
   no schema to enforce the pattern for it. `scripts/doctor.sh` mirrors the
   same validation as a `fail`, and separately `warn`s when `NOTIFY_WEBHOOK_URL`
   wins over a `notify_webhook_url` or an `escalation_webhook_url` that is
   *also* set in `config.json`, naming whichever of the two is — the
   environment value is used either way, but the tracked file still carries
   the secret unless that key is cleared, and the deprecated alias is exactly
   as public as its replacement. Only when both tracked keys are empty does
   the environment source earn doctor's positive `ok`.

   `test/notify.test.sh` passes against `notify_post` and its helpers lifted
   verbatim from `lib/notify.sh`: each of the three classes posts only when
   `notify_events` lists it and is silently dropped otherwise; the alias
   (`escalation_webhook_url` feeding `notify_webhook_url` only when the
   latter is empty, `notify_webhook_url` always winning when both are set);
   `NOTIFY_WEBHOOK_URL` winning over both when passed as
   `notify_resolve_webhook_url`'s third argument, whatever the other two are
   set to; `notify_webhook_url_env_or_empty` passing an empty or `https://`
   candidate through unchanged and rejecting anything else to empty; the rate
   limit (a second POST of the same event on the same key inside
   `notify_min_interval_seconds` logs `notify-suppressed` and sends nothing,
   and the next allowed send's payload carries the accumulated `count`, while
   an unrelated key and — on the same key — the *other* half of a transition
   pair both still send: a `fleet-standdown-begin` 30s old suppresses neither
   `fleet-standdown-end` on `standdown:fleet-switch` nor `pager-cleared` on a
   key whose `pager-fired` has just gone out); a read log that does not exist
   (`notify_post` returns 0 and still POSTs, under a caller running `set -e`);
   and a stubbed POST failure (a `403` from the fence) logs `notify-failed`
   and `notify_post` still returns 0 — a down or misconfigured webhook must
   never propagate into the caller it is notifying on behalf of.

   `test/enabler-notify-wiring.test.sh` covers the other half — that
   `create_escalation_issue` calls it, on the right paths, without changing
   what it returns to the three routes that file through it. It passes
   against `create_escalation_issue` and `escalation_webhook_notify` lifted
   verbatim from `lib/enabler.sh` with `lib/notify.sh` sourced whole: a
   filing failure posts `escalation-unfiled`
   exactly once, keyed `<repo>#<item>`, carrying the failed issue's own title
   and body — and still returns 1, still printing nothing, so a notification
   can never read as a filing; a fresh create posts `escalation-filed`
   carrying the new issue's URL, and still prints `<number>\t<url>` unchanged,
   which is what every caller parses back; the duplicate-guard path posts
   nothing at all, because a fault already escalated is not a fresh page; an
   installation with `escalation` absent from `notify_events` posts nothing
   and logs nothing, not even a suppression; and a POST that fails logs
   `notify-failed` naming the key while leaving the verdict on both paths
   exactly as it was — 1 for the failed filing, 0 and the issue URL for the
   successful one.
2n. **A cycle does not start work the host has no room to finish, on either
   its clone or its writable state, and the threshold it is judged against is
   derived from what the fleet's clones actually need rather than a fixed
   constant alone (requirement 2.0c, agent-ops#756, agent-ops#992 and
   agent-ops#904).** `test/disk-space.test.sh` passes: `disk_space_free_kb`
   reads a directory's free KiB and is empty (never `0`) for a path `df`
   cannot read; `disk_space_verdict` reads `low` only when free KiB falls
   below the threshold it is given, converted to KiB, and `ok` for a `0`
   threshold, an unreadable meter, or free space at or above it;
   `disk_space_describe` names the directory, the free MiB and the threshold,
   and, given a `"derived"` fourth argument, additionally names the
   repository, its recorded footprint's own MiB figure and the factor, while
   a bare three-argument call (or an explicit `"floor"` fourth argument)
   renders byte-for-byte the plain-floor sentence it always has;
   `disk_space_same_filesystem` reads true only when both paths' device ids
   resolve and match, false when they differ or either is unreadable;
   `disk_space_clone_footprint_bytes` reads a directory's `du -sb` size in
   bytes and is empty (never `0`) for a path that does not exist or an
   unreadable `du`; `disk_space_largest_footprint`, fed JSONL on stdin
   (tolerant of an unparseable line, the same `fromjson? // empty` shape
   `lib/fleet.sh`'s own log readers use, rather than failing the whole read),
   returns the `<bytes>\t<repo>` of the single largest `clone-footprint` event
   present, ignoring any other event and any `clone-footprint` event missing
   a numeric `bytes` or a `repo`, and is empty for a log with none;
   `disk_space_effective_min_bytes` returns
   `max(floor, factor × largest)`, the floor alone for a non-numeric or zero
   factor, a non-numeric largest, or a derivation that does not exceed the
   floor, never below the floor even when the factor is `1` and the
   footprint equals it exactly, and `0` for a `0` or non-numeric floor
   whatever footprint it is handed — the off switch living in this one
   function rather than in each caller, so the caller that has no guard of
   its own (`scripts/doctor.sh`) honours it too; `disk_space_governed_by`
   reports `"derived"`
   only when the effective threshold exceeds the floor, `"floor"` otherwise
   (including for a non-numeric effective value, read as `0`).
   `test/disk-space-wiring.test.sh` passes against the block lifted verbatim
   from `lib/standdown.sh`: with `state_dir` and `workspace_root` on the same
   filesystem, exactly one `df` reading is taken and free space below the
   effective threshold exits 0 without falling through to the rest of the
   cycle, the logged `stand-down` event carrying `cause: "disk-full"` at
   exactly zero free KiB and `cause: "disk-low"` for any smaller shortfall,
   and the reason naming the directory and both figures — byte-for-byte what
   a single-directory reading always produced when no footprint is recorded.
   With the two on **different** filesystems: free space below the effective
   threshold on `state_dir` alone stands the cycle down and names `state_dir`
   in `path`/`free_kb`; the same for `workspace_root` alone; when both are
   short, the event names whichever has less free space. Free space at or
   above the threshold on both, an unreadable `df` on either, and
   `min_free_workspace_bytes: 0` all fall through untouched, standing nothing
   down — the `0` case falling through even with a large footprint recorded,
   and never even reading one, since the off switch is unconditional. A
   recorded footprint large enough that `workspace_headroom_factor × footprint`
   exceeds `min_free_workspace_bytes` stands the cycle down on free space the
   plain floor alone would have accepted, the logged event carrying
   `governed_by: "derived"`, `min_bytes` at the derived figure, and `repo`/
   `footprint_bytes` naming what it was derived from; the same free space with
   no footprint recorded, or with one too small to raise the threshold, falls
   through under the plain floor alone, `governed_by: "floor"`; exactly one
   `disk_space_largest_footprint` reading is taken regardless of how many
   directories are judged. The same file also passes against both cycles'
   *measuring* blocks, lifted verbatim out of `review-cycle.sh` and
   `agent-cycle.sh`: each logs one `clone-footprint` event carrying `{repo,
   bytes}` for the repository it cloned, and `review-cycle.sh`'s lands on the
   shared `log.jsonl` — never on its own `review-log.jsonl`, which no caller of
   `disk_space_largest_footprint` reads — where the real
   `disk_space_largest_footprint` reads it back whole. `test/doctor.test.sh`
   passes: a `min_free_workspace_bytes` set above this host's real free space
   (an exbibyte — no `df` stub needed, since no real free space could ever meet
   it) warns on both `state_dir` and `workspace_root`, naming the configured
   floor's own MiB figure, without turning the pass into a failure; a recorded
   `clone-footprint` large enough that `workspace_headroom_factor × footprint`
   clears the same bar warns the same way, naming the derived MiB figure, the
   factor, the repository and the footprint's own MiB figure; the same
   footprint with `workspace_headroom_factor: 0` derives nothing, leaving the
   plain floor's own sentence and never naming the repository; and
   `min_free_workspace_bytes: 0` warns on neither directory, however little
   free space actually remains and whatever footprint is recorded — the same
   unconditional off switch the gate short-circuits on, so the two cannot
   disagree about whether the check is on at all.
2n-i. **A cycle does not start work the host has no memory to run (requirement
   2.0f).** `test/memory.test.sh` passes: `memory_available_kb` reads
   MemAvailable rather than MemFree and is empty (never `0`) when
   `/proc/meminfo` cannot be read; `memory_verdict` reads `low` only when
   available KiB falls below `min_free_memory_bytes` converted to KiB, and
   `ok` for a `0` floor, an unreadable meter, a non-numeric floor, or memory
   at or above it; `memory_describe` names both the available MiB and the
   floor; `memory_cgroup_verdict` reads `unbounded` for a real `memory.max`
   with `memory.high` unset on both this cgroup and its parent, `bounded`
   once `memory.high` is set on this cgroup, `unlimited` when there is no
   ceiling at all, and `unknown` — never a verdict — when the cgroup files
   cannot be read; a parent window that is absent, empty (the `/dev/null`
   default), itself `max`, or at or above `memory.max` leaves the verdict
   `unbounded` rather than any of the three below — so neither an un-opted-in
   node nor one whose parent ceiling sits at the hard limit and would reclaim
   nothing before it is ever reported anything but plainly unbounded.
   Where this cgroup's own `memory.high` is unset but the mounted parent
   window carries a real one below `memory.max`, the verdict depends on the
   parent's *own* `memory.max` (agent-ops#1305, read via the
   `AGENT_OPS_SCHEDULER_CGROUP_MAX` mount, `MEMORY_CGROUP_PARENT_MAX`):
   `parented` when the parent's own `memory.max` is a real ceiling **strictly
   above** this cgroup's own `memory.max` **and** the parent's own
   `memory.high` sits no more than ~25% below this cgroup's own `memory.max`
   (a hard wall exists somewhere with actual headroom to reclaim into, and
   the throttle band between the parent's `memory.high` and this cgroup's
   own `memory.max` is narrow enough for the workload to cross it, so
   `memory.high`'s throttling eventually disengages); `livelocked` when the
   parent's own `memory.max` is `max` (no wall anywhere), a real number that
   is no higher than this cgroup's own `memory.max` (agent-ops#1620: a wall
   exists but adds no headroom beyond one this cgroup already has, so
   reaching it is not something the child can do any more than reaching an
   absent one is), **or** a real number strictly above this cgroup's own
   `memory.max` but with the parent's `memory.high` more than ~25% below it
   (agent-ops#1643, extrapolated from the two incidents below rather than
   itself measured: a wall exists and does add headroom, but the band the
   kernel's reclaim under `memory.high` has to throttle across before the
   workload could ever reach it would be too wide for that reclaim to
   disengage in practice) — every shape throttles without ever disengaging,
   exactly like the band that wedged `ockham-container` for 75 minutes with
   2,788,595 throttle events on 2026-09-09 (`memory.max` `max`) and again for
   most of 2026-09-16 (a real, coincident `memory.max`);
   `unconfirmed` when the parent's own `memory.max`
   window cannot be read (an un-migrated `compose.yaml`, or a node that has
   not re-run `cgroup-parent-setup.sh` since it started mounting that window)
   — never reported `parented` on an unmeasured guess. `parented` is the only
   one of these three that reads `[ ok ]`; `livelocked` and `unconfirmed` both
   warn, exactly as `bounded` does, and for the same reason: a state that
   might not still be true tomorrow — or was never actually measured — is not
   a healthy one to report as such. `test/memory-wiring.test.sh` passes
   against the block lifted verbatim from `lib/standdown.sh`: memory below
   the floor exits 0 without falling through to the rest of the cycle, the
   logged `stand-down` event carries `cause: "memory-low"` and both the
   available and total KiB; memory at or above the floor, an unreadable
   `/proc/meminfo`, and `min_free_memory_bytes: 0` all fall through
   untouched, standing nothing down. `test/doctor.test.sh` passes: the
   container-memory line always reports one of these verdicts' own wording;
   and, separately, a rising delta in the parent's own `memory.events` `high`
   counter (`MEMORY_CGROUP_PARENT_EVENTS`, persisted between runs at
   `state_dir/.doctor-memory-events-high`) warns naming the delta and the
   elapsed time since the prior sample, a flat delta reads `[ ok ]`, and a
   first sample establishes the baseline silently — this check needs no
   ceiling to be correctly configured first, so it still fires on a
   `livelocked` or `unconfirmed` node.
2n-ii. **A cycle does not start work that overcommits the host it shares with
   its siblings (requirement 2.0g, agent-ops#757).** `test/host-budget.test.sh`
   passes: `host_budget_declared_mem_bytes`/`host_budget_declared_cpu_nanos`
   sum only `"running"` entries carrying a numeric ceiling, read `0` for an
   empty or all-unknown array (never empty — a real answer, not "unknown"),
   and exclude an `"exited"` entry's ceiling from the sum entirely;
   `host_budget_declared_mem_unknown_count`/`_cpu_unknown_count` count the
   running entries the sum excluded; `host_budget_summary_json` carries
   `mem_total_bytes`/`cpu_count` through as `null` (never coerced to `0`)
   when its own input is non-numeric, and each `*_headroom_*` reads `null`
   whenever its own total does; `host_budget_mem_verdict`/
   `host_budget_cpu_verdict` read `over` only when the declared sum plus the
   configured reserve exceeds the host's own total, and `ok` for an
   unreadable host total, a `0` reserve, or a sum at or below it — including
   against a fixture whose declared container ceilings sum past a small
   host's total, proving the overcommit path directly rather than by waiting
   for a real host to run out (the issue's own "Done when"); `host_budget_
   describe` names both dimensions' arithmetic — the declared sum, the
   unknown-container count, the reserve, and the host total — regardless of
   which dimension is the one reading `over`.
   `test/host-budget-wiring.test.sh` passes against requirement 2.0g's own
   block lifted verbatim from `lib/standdown.sh`: `host_budget_enforce:
   "false"` (the default) falls through untouched however overcommitted the
   published record reads, standing nothing down; with it `"true"`, a
   published `budget` reading `over` in either dimension exits 0 without
   falling through, the logged `stand-down` event carries
   `cause: "host-overcommit"` and a `reason` naming the arithmetic; a missing
   host-facts file, one that does not parse, or one carrying no `budget`
   section (a Kubernetes-driver record, or one predating this requirement)
   all fall through untouched even with `host_budget_enforce: "true"` — no
   stand-down on a guess — and each of the first two leaves the block at exit
   0 rather than carrying a failed `cat` out of it, which under the
   `set -euo pipefail` `run_standdown_checks` is called beneath would abort
   the whole cycle instead of falling through to 2.1.
   `host_facts_mem_total_bytes`/`host_facts_cpu_count`
   read `/proc/meminfo`/`/proc/cpuinfo` directly, the same "unreadable is
   empty, never `0`" contract `host_facts_mem_available_bytes` already holds
   and, like it, untested at the unit level for the unreadable branch — none
   of these three take a path override, and the container running the test
   suite always has a readable `/proc`; `host_facts_mem_total_bytes` mirrors
   `lib/memory.sh`'s own already-tested `memory_total_kb` closely enough that
   a second dedicated unreadable-path test would add no coverage `test/
   memory.test.sh` does not already give the same arithmetic.
2c. `scripts/gather-merge-conflicts.sh Poetic-Poems/does-not-exist autonomous-agent agent/`
   prints `[]` and exits 0 — a missing repo, a disabled feature, or an API error
   never aborts the cycle. Its candidate rule, including the `bot`,
   `rebase_requested`, `superseded_by` and `superseded_evidence` fields on a
   Dependabot candidate, is regression-tested (through the real script, via
   `MERGE_CONFLICTS_GH`) in `test/merge-conflicts.test.sh`. Against the real
   API, `scripts/gather-merge-conflicts.sh Poetic-Poems/poetic-fiddle
   autonomous-agent agent/` reports poetic-fiddle #129 (issue #250's acceptance
   test) as a `bot: true` candidate.
2z. `scripts/gather-dequeued.sh Poetic-Poems/does-not-exist autonomous-agent
   agent/` prints `[]` and exits 0 — a missing repo, a disabled feature, or an
   API error never aborts the cycle (TD-PPagop-26081409, requirement 3z). Its
   candidate rule — the `MERGEABLE`-only gate that keeps it from ever
   overlapping requirement 3g's own candidates, the `failed_checks`-only
   allow-list on `dequeue_reason`, the answered clause (only a marked
   `actor=implementer` reply newer than `dequeued_at` excludes; any other
   actor, an unmarked comment, or an earlier one does not; an unreadable
   reviews or comments response drops the candidate rather than admitting it),
   the `dequeued_at` ordering, and the head-SHA-scoped ref — is
   regression-tested (through the real script, via `DEQUEUED_GH`/
   `MERGE_QUEUE_GH`) in `test/gather-dequeued.test.sh`.
53. `scripts/gather-landing-refusals.sh o/r autonomous-agent agent/
   /path/to/empty-union-log` prints `[]` and exits 0 — a missing repo, an
   empty or unreadable union log, or an API error never aborts the cycle
   (requirement 53, issue #979). Its candidate rule — the class filter on the
   most recent logged `landing-refused` event (`reconciliation-unanswered:`/
   `reconciliation-unreadable:` only, read from the union log, never
   recomputed independently), the live answered clause
   (`reconciliation_unreconciled_comments` reporting at least one
   unreconciled comment right now; a read that fails outright drops the
   candidate rather than admitting it), the `refused_at` ordering, and the
   ref scoped to the sorted, joined set of unreconciled comment ids — is
   regression-tested (through the real script, via `LANDING_REFUSALS_GH`) in
   `test/gather-landing-refusals.test.sh`. `lib/reconciliation-gate.sh`'s
   `_reconciliation_gate_unreconciled`/`reconciliation_unreconciled_comments`
   and `lib/landing.sh`'s `landing_latest_refusal_reason` are exercised
   through the same test and, for `reconciliation_gate`'s own unchanged
   behaviour, `test/reconciliation-gate.test.sh`.
   `scripts/sweep-human-visibility.sh`'s landing-refusal nudge-text
   substitution — fires only for the two comment-reconciliation refusal
   classes, re-confirmed live before trusting a possibly-stale logged
   refusal, and falls back to the ordinary "waiting on a merge click" text
   the moment the citation lands — is regression-tested in
   `test/sweep-human-visibility.test.sh`. `lib/noop-skip.sh`'s no-op
   fingerprint hashes `landing_refusals` verbatim, so a fresh refusal (or one
   answered) busts the fingerprint on the same terms as `dequeued` —
   regression-tested in `test/noop-skip.test.sh`.
   `scripts/close-void-github-items.sh` never closes a `pr-<n>-landing-
   refusal-<ids>`-shaped void's pull request, on the same reasoning as its
   `-conflict-`/`-dequeued-` exclusion (requirement 34k) — regression-tested
   in `test/close-void-github-items.test.sh`.
   Requirement 17's claim dispatch gives this source the file claim (and the
   PR-keyed `pr-<n>` claim beside it), never a branch claim — the condition is
   lifted verbatim out of `agent-cycle.sh` and evaluated per source in
   `test/claim-dispatch-existing-branch.test.sh`, which also asserts the
   dispatch and `PREFLIGHT_EXISTING_BRANCH_SOURCES` (requirement 34m) name the
   same set, since the two disagreeing is what mints a fresh branch for a
   source whose pull request already exists.
62. **A persistent landing refusal posts, and a cleared one edits, the one
   notice comment (requirement 62, issue #1979).** `test/landing.test.sh`
   passes: `_landing_refusal_persistent` reads `ineligible`, `autonomy-level`,
   `kill-switch`, `open-question`, `reconciliation-unanswered`,
   `human-changes-requested` and `merge-queue-occupied` as persistent and
   every other `_LANDING_REFUSAL_CLASSES` member (and an empty class) as not;
   `_landing_notice_eligible_at` computes a cool-off reason's absolute
   eligible-at as `approved + landing_cool_off_hours`, including a fractional
   hours value, and prints nothing for a reason that names no cool-off.
   Against a stubbed `gh` (the comments-list/create/PATCH endpoints added
   beside the existing files/reviews/graphql ones): `_landing_notice_upsert`
   with no standing notice posts exactly one comment naming the class and
   reason, carrying both `pipeline_landing_notice_marker` and the ordinary
   `pipeline_comment_header`/`pipeline_comment_marker` envelope; an unrelated
   standing comment (no marker) is never mistaken for it, so a fresh notice
   still posts rather than silently patching the wrong comment; called again
   with an identical class and reason is a no-op (no write at all), *including*
   when the standing notice was written by an earlier cycle on another node, so
   that its body carries a different cycle id and node name and only the
   `_landing_notice_stamp` comparison can recognise it as unchanged; called
   with a changed class or reason PATCHes the same standing comment id rather
   than posting a second one; called again for the protected-path cool-off
   with the same `approved`/`landing_cool_off_hours` but a different embedded
   "<N>h remaining" figure — the live countdown
   `landing_protected_path_controls_ok` recomputes every pass — is also a
   no-op, since `_landing_notice_normalized_reason` collapses that figure
   before either side of the comparison is hashed. `_landing_notice_clear`
   against a pull request carrying no standing notice posts nothing at all
   (never announces a hold that was never posted); against one that does,
   PATCHes it to say the hold cleared, naming why. `_landing_refuse` itself
   routes a persistent class to `_landing_notice_upsert`, and writes nothing
   at all for every other class — each of the ten non-persistent classes,
   given a pull request carrying a standing cool-off notice, leaves that
   notice byte-for-byte untouched.
   `test/landing-wiring.test.sh` extends its own `_LANDING_REFUSAL_CLASSES`
   wiring assertion with the mirrored check that
   `_LANDING_PERSISTENT_REFUSAL_CLASSES` is a subset of it, and exercises the
   full `run_landing_stage`/`_landing_stage_attempt` sequence (stubbing
   `pipeline_comment_upsert`/`pipeline_comment_edit_if_present` the way it
   already stubs every other gate helper) to pin: the kill-switch, cool-off,
   protected-path, human-`CHANGES_REQUESTED` and already-queued refusals each
   post the notice; an unreadable human-veto read and both dequeue classes
   neither post one nor clear one; and a successful arm
   clears any standing notice, naming the arming method, before
   `landing-armed` is logged. No test path here exercises
   `merge_budget_decide`'s own `hold`/`refuse` — out of scope, per
   requirement 62's own note that it is a distinct vocabulary `_landing_
   refuse` never sees.
2h. **Dependabot's own conflicted PRs are nudged, then — only after a full
   cycle at the same head — offered as a takeover (requirement 3s).**
   `lib/dependabot-bump.sh`'s family/version parsing and its
   strictly-newer-version supersession pick are regression-tested in
   `test/dependabot-bump.test.sh`. `scripts/nudge-dependabot-rebase.sh`'s
   nudge-then-drop, pass-through-unchanged, and fails-safe behaviour is
   regression-tested (against a stubbed `gh`, via `NUDGE_GH`) in
   `test/nudge-dependabot-rebase.test.sh`: a first-sighting `bot` candidate is
   both commented on (the `@dependabot rebase` ask, this system's ordinary
   header and marker, plus the head-scoped rebase marker) and dropped from the
   array it returns; an already-nudged or superseded candidate is neither
   commented on nor dropped; a non-bot candidate is untouched; a failed post is
   recorded but still drops nothing extra to retry next cycle.
2d. **Issue priority is read, defaulted and fingerprinted.**
   `test/issue-priority.test.sh` passes: against a stubbed issues endpoint,
   `scripts/gather-source-state.sh` bands each issue by its `Priority` issue
   field; an issue with no `issue_field_values`, with values but no `Priority`
   entry, or with a `Priority` the organisation added later reads as `Medium`;
   pull requests are still dropped from the digest; and the no-op fingerprint
   (`lib/noop-skip.sh`) differs between two samples that are identical except
   for one issue's band, so re-prioritising an issue always buys a Co-Ordinator
   run. Against the real API,
   `scripts/gather-source-state.sh Poetic-Poems/poetic-fiddle main` prints
   `ok: true` with a `p` on every issue.
2e. **Issues arrive pre-fetched, filtered, whole-thread and fingerprinted.**
   `test/issues-prefetch.test.sh` passes: against a stubbed issues endpoint,
   `scripts/gather-issues.sh` drops an assigned issue, a `Blocked`-labelled
   issue (whatever the case), and a pull request from `candidates`, while a
   clean issue arrives
   with `source: "issues"`, its number as `ref`, its `Priority` band (default
   `Medium`), its body, and its comments verbatim; the assigned and
   `Blocked`-labelled drops reappear in `excluded` tagged `assigned` and
   `blocked-label` while the pull request never does (agent-ops#447); a
   `pw::type:tech-debt`-labelled issue is dropped from `candidates` and,
   like the pull request, never reported in `excluded` either — it is the
   `tech-debt` band's candidate, not this one's (agent-ops#875); a
   failing API degrades to `{"candidates":[],"excluded":null}`
   (exit 0) with the failure on stderr; and the no-op fingerprint
   (`lib/noop-skip.sh`) differs between two inputs identical except for the
   text of one issue comment — the one transition only the verbatim array
   carries. Against the real API, `scripts/gather-issues.sh
   Poetic-Poems/poetic-fiddle` prints a `candidates` array whose entries all
   carry `comments` and a four-name `priority`.
2j. **Tech-debt arrives pre-fetched, pre-excluded, and its verdict is
   corroborated (requirement 3t).** `test/gather-tech-debt.test.sh` passes:
   against a stubbed issues endpoint, `scripts/gather-tech-debt.sh` prints one
   entry per open `pw::type:tech-debt`-labelled issue that survives the
   deterministic filter — `source: "tech-debt"`, the bare issue number as
   `ref` (a string) and as `number`, its `title`, `labels`, `author`,
   `created_at`, `updated_at`, `url`, its `body` and its whole comment thread
   verbatim as `comments`, sorted by issue number ascending — while an
   assigned issue, a `Blocked`-labelled one (whatever the case) and one naming
   a still-open `Blocked-by:` reference yield nothing, that last one arriving
   once its reference closes, and a failing API degrades to
   `[]` (exit 0) with the failure on stderr.
   `test/verdict-corroboration.test.sh` passes:
   `exclude_blocked_or_void_items` drops a candidate blocked or void for its
   own repo, leaves the same ref alone for a different repo, honours a
   repo-less entry against every repo, and degrades to the unfiltered array on
   malformed input; `unaccounted_items` reports every eligible item a
   `selected: false` verdict neither reported in `needs_refinement` (under the
   item's own source, not another's) nor voided, reports none from a source
   whose `refinement_policy` is `"required"`, and degrades to `[]` rather
   than a false positive on malformed input; and the corroboration is fed the
   recording loops' own collections, never the message's arrays verbatim — a
   `needs_refinement` entry dropped at requirement 34d's bar leaves its item
   unaccounted (the fingerprint is then withheld and the next cycle re-asks),
   while a `voided` entry the guard refuses still accounts, because the
   refusal is itself recorded as a block, and an entry naming no item, which
   records nothing, is not collected at all. Assert the wiring both ways, which
   the unit tests cannot: a `none-selected` with an item unaccounted for logs
   the `warning` **and** omits `fingerprint` from the event (carrying
   `td_verdict_rejected: true`), so the next cycle re-asks rather than skipping
   — the whole point of the requirement — while a fully accounted-for
   `none-selected` still carries its fingerprint and still skips. And assert
   the back-pressure case does not cry wolf: with `max_open_agent_prs` tripped
   and a finishing candidate present (acceptance check 6d's setup), a
   `none-selected` logs **no** contradiction warning and keeps its fingerprint,
   because requirement 2.2a empties `tech_debt` along with `issues` and the
   eligible set is read after that narrowing.
2k. **Blocked/void exclusion reaches every pre-fetched band, `issues`
   included, and `void` never reaches the Co-Ordinator (requirement 3u, issue
   #320).** `test/cycle-state.test.sh` passes: `exclude_blocked_or_void_items`,
   lifted the same way `test/verdict-corroboration.test.sh` already lifts it,
   drops a candidate blocked or void for its own repo from a `findings`-shaped
   array exactly as it does from a `tech_debt`-shaped one — the exclusion
   itself is not tech-debt-specific, only its first proof was. The new
   `exclude_blocked_or_void_issues` drops a void issue unconditionally; drops a
   *stale* blocked issue — `updated_at` no newer than the later of the block's
   own `ts` and its newest `recheck_clean_ts` — and keeps a *fresh* one, the
   same threshold comparison this file's `needs_mandatory_reread` mirror
   already pins for requirement 18a, asserted to agree with it on the same
   fixtures rather than duplicated as a second, driftable definition; honours
   repo scoping identically to `exclude_blocked_or_void_items` (a blank `repo`
   on the blocked/void entry matches every repo); drops a candidate with no
   `ref` rather than crashing on it; and degrades to the unfiltered array on
   malformed `blocked`/`void` input, delivered on stdin and proven past
   `MAX_ARG_STRLEN` the same way `test/verdict-corroboration.test.sh`'s own
   oversized-void fixture is. The band list the generic pass loops over is
   pinned too — `findings`, `review_feedback`, `abandoned_drafts`,
   `merge_conflicts`, `human_visibility`, `tech_debt`,
   every pre-fetched band but `issues` — because it is inline shell rather
   than a function, and a band added to a repo entry but not to it would keep
   handing the Co-Ordinator blocked and void candidates it has no `void` list
   left to check them against.

   The same file covers the sibling subtraction requirement 36d adds for a
   pending `decide-tactical` decision (agent-ops#1057), lifted and asserted
   the identical way: `exclude_decision_pending_items` withholds a candidate
   `decisions_map` names a decision for under that candidate's own repo —
   proven against a non-exempt source and an explicit policy — leaves the
   same decision's item untouched under a *different* repo, leaves every
   candidate untouched when the map is empty, drops a candidate with no
   `ref` rather than crashing on it, degrades to the unfiltered array on
   malformed decisions or policy input, and applies to an issue-shaped `ref`
   exactly as to any other — proving the restriction to non-issue bands is
   the call site's choice rather than the function's. A further case proves
   the reachability gate itself (agent-ops#1057, the second round): a
   decision-pending candidate whose source resolves `refinement_policy`-exempt
   is left untouched despite the pending decision, since no Refiner
   engagement could ever reach it to supersede one. That pass's own band list
   is pinned separately from the generic one above, by a `sed` pattern keyed
   on its own loop variable, for the same reason: a band added to a repo
   entry but not to it would keep handing the Co-Ordinator a specification
   the pipeline has already ruled superseded.

   Separately, `agent-cycle.sh`'s own
   `coordinator_input` build carries no `void` key at all, and its `blocked`
   entries carry only `repo`, `item`, `ts`, `detail` and `recheck_clean_ts` —
   asserted by lifting that build verbatim the same way and running it over a
   `blocked_json` entry with extra fields (`stage`, `cycle`, `event`,
   `unblock_condition`), which must not survive into what the
   Co-Ordinator reads — while the no-op fingerprint's own input
   (`test/noop-skip.test.sh`) is unaffected and still hashes both extracts,
   untrimmed, exactly as before this requirement.

2j-i. **The merge reconciles repositories correctly, and a rejected verdict
   costs a mechanical pick, never the cycle (requirements 15z, 3v; issue
   #587).** `test/coordinator-merge-fallback.test.sh` passes, against
   `run_coordinator_stage_attempt`, `fallback_select_candidate`,
   `coordinator_merge_candidates` and `coordinator_corroborate_and_fallback`
   lifted verbatim out of `lib/stage-attempt.sh`:
   - **`coordinator_merge_candidates`'s six-tier order, unit-tested
     directly.** A security-tier candidate wins even ranked last within its
     own repository; an `issues`-source candidate whose *own* repository
     marks it `Urgent` outranks a `review-feedback` candidate from a
     later-walk-order repository, while the identical ref is not treated as
     `Urgent` by a different repository that does not mark it so (the tier
     lookup is scoped to the candidate's own repository's `issues` array);
     all six named tiers (security, urgent issues, review-feedback,
     merge-conflicts, dequeued, abandoned-drafts) sort in the prompt's own
     order regardless of walk order; two residual-tier candidates from
     different repositories — carrying no cross-repository tier of their own
     — order by walk order alone, whichever of the residual sources either
     one is; two same-tier candidates from different repositories break
     their tie by walk order, and two candidates from the *same* repository's
     own tier break theirs by that repository's own rank; `candidates_max`
     caps the *merged* result (four raw candidates across two repositories,
     capped to two, keep the more-overdue repository's own two rather than
     one from each — repository order dominates a residual tier entirely);
     no internal `_tier`/`_repo_order`/`_rank` tag leaks onto a returned
     candidate; a non-array `candidates` argument degrades to an empty
     result, a non-array `repos` argument still merges by tier/rank alone,
     and a non-numeric `candidates_max` degrades to the documented default
     (`3`) — never a crash.
   - **`coordinator_corroborate_and_fallback` scopes corroboration to the
     repositories that said no.** A repository that selected needs no
     corroboration at all, even when a *different* selected repository's own
     eligible item went unreported — asserted directly: an eligible item
     belonging to a repository outside the false-repos list produces zero
     `corroboration` events regardless of whether it was ever accounted for.
     A false repository's own unaccounted item is rejected (`attempt: 1`
     always now — there is no second attempt to distinguish it from, since
     issue #587 dropped the model retry a fleet-wide rejection used to buy),
     and the mechanical fallback fires and finds it, with no `none-selected`
     event at all (the cycle selected something). A false repository whose
     own `needs_refinement`/`voided` report fully accounts for its band is
     accepted, with no fallback call and no `td_verdict_rejected`. When the
     fallback also finds nothing, the resulting `none-selected` carries
     `td_verdict_rejected: true`, the unaccounted `bands` tally, and no
     `fingerprint` (requirement 3t: a rejected verdict must never arm the
     no-op short-circuit) — proving the fingerprint-omission rule survives
     the retry's removal intact. When every configured repository's own
     bands are genuinely empty, no `corroboration` event fires at all (there
     is nothing to corroborate), and the resulting `none-selected` carries no
     `td_verdict_rejected`.
   - **`refinement_policy` binds the mechanical pick.** Against
     `fallback_select_candidate` in isolation: under
     `{"tech-debt": "required"}` an unrefined tech-debt item is not selected
     and a lower band wins instead.
   - **`fallback_select_candidate`'s band order and shapes, unit-tested
     directly** (no stage stub needed): against a synthetic
     `ordered_repos_json`, a security finding outranks a tech-debt item in
     the same repo; a `landing-refusals` entry outranks tech-debt and carries
     its own existing branch/PR; every band empty prints `null`, not a crash
     or an empty-string candidate accepted downstream as one.
   - **`sources` bounds the mechanical pick (requirement 3x).** The same
     fixture with its `sources` narrowed to the four finishing bands and its
     `issues`/`tech_debt` emptied — requirement 2.2a's own back-pressure
     shape — yields `null` rather than the security finding still sitting in
     its `findings` array, and yields that finding again the moment the token
     is restored.
   - **The gate is no longer tech-debt-only, and stays scoped to the
     repositories that said no (requirement 3x, issue #322).** A silent
     `selected: false` over a non-empty `issues` array and a non-empty
     `review_feedback` array — with the tech-debt band empty, so a
     tech-debt-only gate would have accepted it — is rejected, `eligible_total`
     counts both bands, and the `warning` and `corroboration` both carry a
     `bands` tally naming each; the rejected verdict's own mechanical
     fallback then picks the highest reachable band. A report filed under the
     wrong `source` leaves its actual band exactly as unaccounted as silence
     would. A verdict answering each band by its own route (a
     `needs_refinement` for the issue, a `voided` for the review-feedback
     entry) is accepted, buys no fallback call, and keeps its fingerprint.
   - **The argv cap survives the split (requirement 4g, TD-PPagop-26081401/
     26081406).** 3000 unclaimed tech-debt items, none reported back, still
     reach the `warning`/`corroboration` events in full past `MAX_ARG_STRLEN`
     (131072 bytes); 3000 recorded `needs_refinement` reports, read back
     through the same function, still fully account for an equally large
     eligible set.
   - **A no-verdict or zero-candidate Co-Ordinator engagement omits the
     fingerprint (requirement 15y).** The three consequences of requirement 15y
     are asserted in lifted blocks from `agent-cycle.sh`: the all-engagements-
     failed exit exits 0 when every engagement failed (full failure), exits 9
     when only some failed (partial failure), and exits 9 when zero repositories
     are configured (zero-configured case), proving every failure mode is
     correctly distinguished; an engagement that produced no verdict omits the
     fingerprint and records the count in `engagements_failed`, so the next
     cycle asks again (requirement 3t, requirement 3b), while a complete cycle
     where every engagement answered arms the fingerprint and carries no
     `engagements_failed` at all; a `selected:true` engagement that returned an
     empty `candidates` array is folded into the false-repos set with a reason
     naming the contract violation ("selected:true but returned no candidates"),
     contributes nothing to the merged candidates, and is distinguished from a
     non-empty list, which is carried into the merge as before.
2j-ii. **The corroboration covers every pre-fetched band (requirement 3x,
   issue #322).** `test/verdict-corroboration.test.sh` passes:
   `coordinator_eligible_items` emits `{repo, item, source}` for each band the
   repo's own `sources` lists and nothing for a band it does not (the
   `code-quality` half of a `findings` array whose repo lists only `security`
   is the case that separates the two); drops a `merge_conflicts` entry that
   is a never-nudged Dependabot PR while keeping its superseded sibling, which
   the prompt requires in `voided`; admits an issue only under its own
   `Priority` band's token and drops one recorded blocked (repo-scoped exactly
   as `exclude_blocked_or_void_items` scopes it, blank `repo` included); bounds
   everything by the narrowed `sources` list a back-pressured cycle leaves
   behind, so a restricted cycle owes no account of `findings`
   or `human_visibility` still sitting populated; and
   degrades to `[]` on malformed repos, and to filtering nothing rather than
   everything on a malformed `blocked`. `unaccounted_items` matches a
   `needs_refinement` report on repo **and** item **and** source — the same
   ref filed under another band, or against another repo, accounts for
   nothing — while a `voided` entry, which carries no source, accounts for its
   repo+item in whichever band it was eligible in; it applies
   `refinement_policy` per entry's own source, so `"required"` exempts that
   band and no other; and every entry it returns carries the band it was
   eligible in. `test/coordinator-merge-fallback.test.sh` passes the wiring:
   a silent `selected: false` over a non-empty `issues` array and a non-empty
   `review_feedback` array — with the tech-debt band empty, so requirement 3t
   alone would have accepted it — is rejected, `eligible_total` counts both
   bands, and the `warning` and `corroboration` both carry a `bands` tally
   naming each; a report filed under the wrong `source` leaves its band
   unaccounted; and a verdict answering each band by its own route (a
   `needs_refinement` for the issue, a `voided` for the review-feedback entry)
   is accepted on the first attempt, buys no retry, and keeps its
   fingerprint. `test/verdict-corroboration.test.sh` also passes
   `unaccounted_items`' fit-ladder exemption (requirement 4i, agent-ops#683): a
   4th `trimmed-json` argument naming one eligible item exempts only that
   item, on the same repo+item+source key as `voided`/`needs_refinement`,
   leaving any other still-unaccounted item flagged; an omitted 4th argument
   exempts nothing, matching the function's behaviour before this change; and
   malformed trimmed JSON degrades to exempting nothing rather than
   everything.
2j-iii. **A `needs_refinement` block against an entry the fit ladder trimmed
   this cycle is refused, never recorded, and the completeness check owes no
   account of it either (requirement 34e's fourth refusal, requirement 3x's
   matching exemption; agent-ops#683).** `test/coordinator-input.test.sh`
   passes `coordinator_fit_trimmed_items`/`coordinator_fit_trim_refusal_reason`
   in isolation: a cycle driven to the ladder's bottom rung with every entry
   still present marks every one of them trimmed; an untrimmed cycle marks
   nothing; a cycle trimmed only enough to clip one of two entries marks only
   that one; an entry whose comment prose alone was clipped — its body inside
   the rung's cap and its comment list kept whole — is marked trimmed on the
   marker inside that comment; and the refusal function refuses only an entry
   whose repo+item the trimmed set carries, names the rung in its reason, and
   degrades to
   refusing nothing on an empty or malformed trimmed set.
   `test/fit-trim-block-refusal.test.sh` then drives the real
   `record_needs_refinement_block` (lifted verbatim, the same technique
   `test/dependency-block-refusal.test.sh` uses) and passes: an
   agent-ops#683-shaped report — the Co-Ordinator citing a trimmed body's own
   lack of acceptance criteria — is refused with a `warning` naming the item
   and the rung, applies no label, and writes no `attempt-failed` at all; a
   genuine report against an item this cycle's fit never touched is recorded
   exactly as requirement 34e already describes; the refusal is scoped to
   `stage == "coordinator"` — the identical entry reported by a Refiner or an
   Implementer is not refused on this bar, since neither reads this cycle's
   fit-ladder-trimmed Co-Ordinator input; and the malformed-entry bar
   (requirement 34d) still runs ahead of this one. The same file then proves
   the two halves compose: with both of a fully-trimmed cycle's eligible items
   left unreported (as the refusal above forces), `unaccounted_items` finds
   nothing unaccounted — a `"selected": false` verdict over that cycle is
   accepted — while `coordinator_unassessable_items` still surfaces both as
   unassessable for the log, closing the loop the incident opened: the
   refusal alone would have just relocated the mass-flag into a
   corroboration-rejected retry loop over the same trimmed input, and this is
   the assertion that it does not.
   Both those files supply the trimmed set themselves, so neither can tell
   whether `agent-cycle.sh` ever builds one — the gap agent-ops#933 lived in
   for as long as the gate shipped. `test/coordinator-input-wiring.test.sh`
   closes it, over the exemption-set block lifted verbatim and driven off the
   fit report a genuinely-trimmed cycle actually left behind rather than a
   hand-written one: the block's `if` takes its true branch, so
   `coordinator_fit_trimmed_json` comes back non-empty and
   `coordinator_fit_rung` non-zero; requirement 3x's own accounting inside
   that same lifted block counts those candidates unassessable and logs
   `coordinator-input-fit-unassessable` carrying the count, the rung and its
   detail sentence; and `coordinator_fit_trim_refusal_reason`, given a
   `needs_refinement` report naming one of the items that block actually
   trimmed, refuses it and names the rung. Every one of those assertions
   fails against the pre-fix gate, which is what the empty-input fixtures
   above could not do.
2f. **A preview nobody can reach is never reported as a healthy one
   (requirement 24a).** `test/preview-deploy.test.sh` passes: against a stubbed
   `gh` and a stubbed Vercel that answers the login flow to any request not
   carrying the project's bypass secret, a built and reachable preview is exit
   0; a preview behind Vercel Authentication is exit 2 naming
   `VERCEL_AUTOMATION_BYPASS_SECRET`, with a different diagnosis for a secret
   that is unset and one that is rejected, since the two have different fixes;
   a failed build is exit 1 naming the inspector, and carries the tail of the
   build log when `VERCEL_TOKEN` is set; a preview that built and then serves a
   500 is exit 1 and is distinguished in words from a build failure; an
   application's own redirect is followed rather than mistaken for the login
   flow; no deployment at all, a SHA deployed only to Production, and a
   deployment still building are each exit 2; and `--wait` re-asks rather than
   answering from its first look. With no `--repo` and no `--pr` it resolves
   the checked-out branch's own pull request without combining `--repo` with
   an unidentified pull request — a shape the real `gh` CLI refuses, since
   `--repo` overrides the ambient-repository inference `gh pr view` otherwise
   uses to find the current branch's PR — and an explicit `--repo` with no
   `--pr` resolves the number first through `gh pr list --head <branch>`
   rather than combining the two; that refusal is pinned directly against the
   installed `gh` binary, not assumed by the stub. `--fetch <path>` against a
   preview behind the same stubbed wall still returns that route's status,
   headers and body — proving the bypass secret it sends internally reaches a
   protected preview's own content — while the secret's value never appears
   anywhere in the command's output; a binary body is noted rather than
   dumped, and an oversized one is truncated with a note naming the size.
   `prompts/implementer.md` and `prompts/reviewer.md` are asserted to invoke
   the check with `--fetch` in the same literal form, so the two cannot drift
   (requirement 34a). Against the real API and a
   real protected preview, `scripts/preview-deploy.sh --repo
   Poetic-Poems/poetic-fiddle --pr <n>` from a shell with no bypass secret set
   reports that the deployment built and that the page could not be checked.
   `test/preview-config.test.sh` covers the config-block half of the same
   requirement (D19 Phase 1): `preview_config_for_repo` resolves a configured
   `{"provider": "vercel"}` entry unchanged, falls back to
   `{"provider": "none"}` for a repo carrying no `preview` key at all and for
   a slug absent from `repos[]` entirely, and `preview_config_export_vercel_credentials`
   exports the two fixed variable names `scripts/preview-deploy.sh` reads
   from whichever variable name a `vercel.bypass_secret_env`/`vercel.token_env`
   override names, is a no-op on the defaulted names, and is inert for
   `provider: "none"`. `test/config-schema.test.sh` covers `scripts/doctor.sh`'s
   (component 14) own side of this same requirement, alongside its other
   cross-key rules: the shape half through `config_schema_errors` directly
   (rejecting an unknown `provider`, an unknown key inside `preview`, a
   `bypass_secret_env` that is not a bare shell identifier), and the
   credential-presence check through a real `scripts/doctor.sh` run, asserting
   it warns rather than fails when a `"vercel"`-configured repo's named
   variable is unset on the node it runs on.
2g. **Every pipeline comment is visibly attributed (requirement 9d).**
   `test/comment-identity.test.sh` passes: `pipeline_actor_label` returns the
   right display name for each of `script`, `coordinator`, `implementer`,
   `reviewer`, `enabler`, `review-script`, `project-reviewer` and `monitor`,
   and fails open — prints the token itself — for one it does not recognise;
   `pipeline_comment_header` renders `**<Display>** · autonomous pipeline ·
   node \`<node>\`` for a known and an unknown actor alike;
   `pipeline_comment_marker` carries both the cycle id and the actor token,
   still prefixed with `PIPELINE_COMMENT_MARKER_PREFIX`; and each of
   `prompts/implementer.md`, `prompts/enabler.md` and `prompts/reviewer.md`
   contains the literal header form `pipeline_comment_header` produces for its
   own actor token. `prompts/reviewer.md` also contains the literal
   instruction to post an unconditional completion comment (requirement 30b),
   pinned by a distinctive phrase from that instruction.
   `test/abandoned-drafts.test.sh` separately proves an
   older, actor-less marker and a newer, actor-carrying one both still exclude
   a comment from the activity clock, and that all three prompts (now
   including `prompts/implementer.md`) still carry
   `PIPELINE_COMMENT_MARKER_PREFIX`.
3. A second invocation while one holds the lock exits without acting.
4. A simulated stale lock (fake lock file, old timestamp, dead PID) is taken
   over with a logged warning. A simulated foreign lock (fake lock file
   naming a different `host`, fresh timestamp, a pid that is alive here
   because it collides with an unrelated local process) is taken over
   immediately with a logged warning, and that local process is left
   running.
4a. **A signal leaves a record, a released claim, and no orphaned model
   (requirement 9c).** `test/signal-exit.test.sh` passes: with the signal
   machinery lifted from `agent-cycle.sh` (and from `review-cycle.sh`), a
   TERM delivered mid-stage kills the stub stage's own process group, logs
   an `attempt-failed` whose detail is `<stage> terminated by SIGTERM`,
   releases the claim — `have-pr` when a breadcrumb names a PR, `no-pr`
   otherwise — and exits 143 through the EXIT trap; a stage that had
   already ended cleanly is not blamed (the event says `cycle`); and the
   requirement-1 takeover grace TERMs a live stale holder, proceeds as soon
   as the holder exits rather than sleeping out the full grace, and still
   takes the lock over.
5. An injected `limit-hit` event with a future `resume_at` and
   `reset_known: true` causes a stand-down with no probe launched; an expired
   one does not stand down. With `reset_known: false`, the cycle launches
   exactly one probe: a stubbed `claude` answering a clean envelope yields a
   `limit-cleared` event (`by: auto-probe@<node>`) and the cycle proceeds; a
   stub answering the limit phrase logs a fresh `limit-hit` and a stand-down
   whose reason ends `(probe: still limited)`; a stub that exits non-zero
   with no output changes no limit state and the reason ends
   `(probe: inconclusive)`. `--dry-run` with the same injected event launches
   no probe.
5a. **A crash loop, of either class and in each configured repository
   independently, is detected once and escalated once (requirement 2.7).**
   `test/crash-loop.test.sh` passes: for
   `crash_loop_verdict`, a stream of threshold-many consecutive same-detail
   Co-Ordinator failures yields a verdict carrying the count, the window and
   every failing node; one fewer yields nothing; a Co-Ordinator success
   anywhere in the run resets the count (including the `stage-end 0` that
   precedes an `unparseable final message` failure, which counts as one, not
   threshold-plus); a detail change restarts the count at one; item-stage
   failures and other nodes' noise never contribute; a threshold of 0 is the
   off switch. Per-repository grouping (agent-ops#1630): repository A
   accumulating `crash_loop_after` consecutive same-detail failures while
   repository B succeeds every cycle in between still yields A's own verdict,
   untouched by B's success; an event carrying no `repo` at all still yields
   its own verdict, with no `repo` field, independent of every real
   repository's own group in the same stream; two repositories independently
   crash-looping in the same cycle both yield their own verdict — one
   JSON-Lines line each, each carrying its own `repo`, `detail` and count.
   `crash_loop_reverify` matches a retry to the correct one of several
   same-cycle verdicts by `repo` as well as `detail`/`first_ts`, so a retry
   queued for one repository's own run is never mismatched to another's, even
   sharing a detail and a first_ts. `crash_loop_preselection_verdict` passes the same shape of
   cases against the class `crash_loop_verdict` cannot see: threshold-many
   consecutive cycles that each logged `cycle-start` then `cycle-end` with
   the same non-zero `exit_code` and no `stage-start` anywhere between them
   yields a verdict carrying the count, the window, every failing node and
   the `exit_code`; one fewer yields nothing; a completed cycle that reaches
   a selection-path stage (`coordinator`, `implementer` or `reviewer`)
   resets the count whatever that stage then exits, as does a clean
   (`exit_code` 0) cycle, while an Enabler or Refiner `stage-start` never
   counts as recovery; an exit-code change restarts the count at
   one; a cycle with no `cycle-end` at all is dropped, counted neither way;
   item-stage failures and other nodes' noise never contribute; a threshold
   of 0 is the off switch. For `crash_loop_escalated_since`, an escalation
   event for the same detail after the run's first failure suppresses
   re-escalation, while an older one — a closed issue from a past loop —
   does not, and a different detail never matches. For
   `crash_loop_open_escalations`, two `crash-loop-escalated` events bound to
   the same `issue_number` (a rebind, agent-ops#1140) yield only the
   newer-by-`ts` one's own fields, regardless of the events' order in the
   log, while a single escalation still round-trips exactly as it always
   did. For `crash_loop_detail_recurred_since` (the 2026-09-05 fleet flap):
   a same-detail Co-Ordinator failure at or after a given timestamp reads as
   a recurrence whether or not it ever reaches `crash_loop_after`; no such
   failure, a different detail, or one strictly before the timestamp does
   not; a failure exactly at the timestamp counts (the boundary is
   inclusive). The same file replays the 2026-09-05 incident's own real
   timestamps end to end: the first run's verdict names its real first
   failure and count, a verdict computed once the clearing success is
   already logged never fires, the second flap is on its own a genuinely new
   threshold-crossing run, and `crash_loop_detail_recurred_since` correctly
   reads that second flap as a recurrence of the first run's own detail
   since its clearing success — the fact `crash_loop_retire_resolved` (lib/
   enabler.sh) relies on to keep the first run's issue open across the flap
   rather than closing it and forcing a fresh one. `test/crash-loop-escalate.
   test.sh` covers that reliance directly, with `gh`/`create_escalation_issue`
   stubbed: replaying the same incident, a clearing success younger than
   `crash_loop_min_clear_minutes` is never retired, a same-detail failure
   since the clearing success blocks retirement outright regardless of how
   old that success is, a success that has genuinely held the window with no
   recurrence is retired exactly as before, and `crash_loop_min_clear_
   minutes` 0 restores instant retirement on the first nameable success.
   The same file also covers per-repository dedup and retirement
   (agent-ops#1630), two repositories sharing a generic detail (e.g. both
   "coordinator exited 1"): repository B's own run still files its own
   escalation issue undeterred by repository A's own same-detail escalation;
   repository A's own escalation is retired on repository A's own clearing
   success even while repository B, sharing the detail, is still actively
   failing under its own independent run; and repository B's own clearing
   success never retires repository A's own still-open escalation. And the
   transition case the same grouping has to survive: an escalation carrying
   no `repo` at all — one filed before agent-ops#1630 — is still retired by a
   repository-scoped clearing success, which is named in the closing comment,
   and its flap guard still sees a repository-scoped recurrence of its own
   detail and blocks that retirement.
   back-pressure, and the logged reason states the count's composition
   (`N ready + N draft + N unraised claim(s)`).
5b. **A personal access token's own expiry is read, recorded, and escalated
   once per credential (requirement 2.7a).** `test/token-expiry.test.sh` passes:
   `token_expiry_parse` turns a `GitHub-Authentication-Token-Expiration`
   header value into an ISO-8601 UTC instant and a day count that floors
   toward zero — a fractional remainder rounds down, six hours out reads 0
   days rather than 1, and a token already past its own expiry reads 0
   rather than a negative number — while an empty or unparseable value is
   refused outright rather than read as some fallback date;
   `token_expiry_escalated_for` matches on the exact node *and* `expires_at`,
   so a rotated token (a new expiry) escalates again despite the repeated
   event name, and another node's identical expiry never cross-matches.
   `test/token-expiry-wiring.test.sh` passes against the block lifted
   verbatim out of `agent-cycle.sh`: a recorded `token_expiry` under
   `TOKEN_EXPIRY_WARN_DAYS` files exactly one issue, through
   `create_escalation_issue` in `crash_loop_repo` under
   `enabler_escalation_label` and keyed `token-expiry:<node>:<expires_at>`,
   and logs one `token-expiry-escalated` event naming that expiry; a second
   cycle over the same expiry — reading the first cycle's own event back out
   of the log union, as state-sync would deliver it — files nothing and logs
   nothing further; a rotated token files again; and a token at or above the
   threshold, a `token_expiry` of `null`, and a missing
   `.doctor-status.json` each file nothing. In every one of those cases the
   block falls through and the cycle proceeds — unlike requirement 2.0b's,
   this check never stands the cycle down, because a token that has not yet
   expired blocks nothing the cycle needs.
6a. **The switch stops both pipelines and lets go by itself.**
   `--disable 'testing'` then a plain invocation of *both* `agent-cycle.sh` and
   `review-cycle.sh`: each logs a stand-down carrying the reason, exits 0, and
   launches no `claude`. `--enable` restores both. Then plant a record whose
   `expires_at` is already past and run a cycle: it must clear the switch, log
   `enabled` saying the disable expired, and proceed — the assertion that an
   agent which sets the switch and dies costs a few cycles rather than every
   future one. Assert the ambiguous cases resolve toward *disabled*: a
   truncated record, and one whose `expires_at` is gibberish, both keep the
   pipeline down.
6c. **A review round is answered exactly once.** With a PR carrying an
   unanswered `CHANGES_REQUESTED`, a cycle must select it (`source:
   "review-feedback"`, `item` the round's ref, `branch` the PR's existing
   branch) and the Implementer must push to that branch without opening
   anything. Then the check that matters: run another cycle and assert the PR
   is **no longer a candidate**, while `gh pr view --json reviewDecision` still
   reports `CHANGES_REQUESTED`. Those two facts are true simultaneously, and
   that is the point — the agent cannot clear a review on its own PR, so
   nothing about the PR's state ever says "answered", and only the turn rule
   (a marked reply or a re-requested review since the blocking review, never a
   commit's date — see the design note on why) distinguishes "our move" from
   "theirs". Get it wrong and the PR is re-fixed hourly forever while every
   cycle looks productive. Assert the reopen too: a *new* review after the
   agent's push makes it a candidate again under a *new* ref, or a round that
   once went `blocked` will swallow the human's next attempt to unstick it.
6d. **Back-pressure cannot deadlock the pipeline (requirement 2.2a).** Set
   `max_open_agent_prs` to 0 with a *finishing* candidate present — a
   review-feedback round, a merge-conflicted PR, a dequeued PR *or* an abandoned
   draft: the cycle
   must **not** stand down, and must reach the Co-Ordinator with every repo's
   `sources` narrowed to
   `["review-feedback", "merge-conflicts", "dequeued", "abandoned-drafts"]`. With none present
   it must stand down as before. This is the check that a system whose PRs have all
   been sent back for changes — or all stalled as abandoned drafts or wedged on
   conflicts, the very slots the cap is counting — can still dig itself out;
   without it, the state the pipeline is least able to escape is the one it is
   guaranteed to reach.
6e. **An abandoned draft is finished, not restarted (requirements 3e, 15c).**
   With an open *draft* PR carrying `pr_label` on a `branch_prefix`
   branch whose `updatedAt` is older than `abandoned_draft_after_hours`, a cycle
   must select it (`source: "abandoned-drafts"`, `item` the head-SHA-scoped ref,
   `branch` the PR's existing branch), and the Implementer must check out that
   branch and push to it without opening a new PR or branch. Assert the freshness
   gate: the same PR with a recent `updatedAt` is **not** a candidate — a draft
   merely being worked, or one a peer node just touched, must never be stolen.
   Assert a *ready* PR of ours is never an abandoned-drafts candidate (that is
   review-feedback's job). And assert the claim uses a file claim, not a
   create-ref against the already-existing branch (requirement 17a), or every
   attempt would 422 and no abandoned draft could ever be picked up.
6f. **A conflicted PR is rebased, not restarted (requirements 3g, 15d).** With an
   open *non-draft* PR carrying `pr_label` on a `branch_prefix` branch
   whose `mergeable` is `CONFLICTING`, a cycle must select it (`source:
   "merge-conflicts"`, `item` the head-SHA-scoped ref, `branch` the PR's existing
   branch), and the Implementer must check out that branch, rebase onto the base
   and push without opening a new PR or branch. Assert the guards: a PR whose
   `mergeable` is `UNKNOWN` is **not** a candidate — mergeability is computed
   asynchronously and guessing would rebase a PR that may not conflict; a *draft*
   conflicted PR is not a candidate here (that is abandoned-drafts' job once it
   goes stale); and a *mergeable* PR is never a candidate. And assert the claim
   uses a file claim, not a create-ref against the already-existing branch
   (requirement 17a), or every attempt would 422 and no conflicted PR could be
   picked up.
6i. **A merge-group-checks-failure dequeue is fixed, not restarted
   (requirements 3z, 15d; TD-PPagop-26081409).** With an open *non-draft* PR
   carrying `pr_label` on a `branch_prefix` branch whose `mergeable`
   is `MERGEABLE` and whose most recent `merge_queue_probe` reports
   `queued: false`, a non-null `dequeued_at`, and `dequeue_reason` exactly
   `failed_checks`, a cycle must select it (`source: "dequeued"`, `item` the
   head-SHA-scoped ref, `branch` the PR's existing branch), and the
   Implementer must check out that branch, push a fix without opening a new PR
   or branch, and never attempt to re-queue it. Assert the guards: a PR whose
   `mergeable` is `CONFLICTING` is **not** a candidate here (that is
   requirement 3g's job, and the two candidate rules must never both admit the
   same PR head); a PR whose `dequeue_reason` is anything other than
   `failed_checks` (including empty/unreadable) is **not** a candidate; a
   currently-queued PR (`queued: true`) is never a candidate; and **a dequeue
   the pipeline has already answered is not a candidate at a moved head** — a
   marked `actor=implementer` reply newer than `dequeued_at` excludes the PR
   even though the probe still reports the same dequeue, which is what stops
   the fixed pull request being re-offered on every cycle until a human
   re-queues it. Assert the clause's own edges too: the same reply *before*
   `dequeued_at` does not exclude (so a second dequeue re-opens candidacy),
   another actor's marked comment or an unmarked one does not exclude, and a
   reviews or comments read that fails yields no candidate rather than one.
   And assert the claim uses a file claim, not a create-ref against the
   already-existing branch (requirement 17a), or every attempt would 422 and no
   dequeued PR could be picked up.
6g. **The review runs at the tier the work graded itself (requirements 26a,
   8a).** `test/cycle-state.test.sh`'s reviewer-complexity section passes: the
   resolution takes the highest valid grade among the summary's `complexity`
   and the PR's `complexity:*` label values (a label `high` outranks a summary
   `medium`, and vice versa); an unknown grade contributes nothing rather than
   failing; and with no valid grade at all it falls back to `low` for a
   trivial-classified work order and `medium` otherwise. Driving a cycle
   end-to-end: the Implementer's PR carries exactly one `complexity:*` label,
   its summary carries `complexity`, and the reviewer's `stage-start` event
   records the resolved `complexity` and a `model` equal to
   `reviewer_model_complex` when and only when the grade is `high`.
6b. **The no-op short-circuit skips only what it can prove, and stops skipping
   when anything moves.** Drive a cycle that ends `none-selected`, confirm the
   event carries a fingerprint, then run a second cycle: it must stand down
   *without launching the Co-Ordinator* — that saving is the entire feature, so
   time both and see it. Then the half that actually matters, and the half
   it is tempting to skip because the happy path passed: assert
   per-source that the fingerprint *changes* when a commit lands, an issue is
   relabelled or assigned, a workflow's conclusion flips, a claiming PR closes,
   a draft PR of ours crosses the `abandoned_draft_after_hours` staleness
   threshold (assert this one especially — it is the sole transition that moves
   no other signal, so the `abandoned_drafts` array is the only thing that can
   carry it), a ready PR of ours turns `CONFLICTING` after its base moved (assert
   this one too — like the staleness transition it moves no other fingerprinted
   signal once the base advance is a cycle past, so the `merge_conflicts` array is
   the only thing that can carry it), a ready PR of ours is dequeued over a
   merge-group checks failure (assert this one too — it moves *no* other
   fingerprinted signal at all, not even `mergeable`, so the `dequeued` array
   is the only thing that can carry it), an item is unblocked or unvoided, a source is
   added to `config.json`, or `prompts/coordinator.md` is edited. Each of those is a
   source of work, and
   any one of them missing from the fingerprint is an unbounded silent stall
   that no other check in this document would catch. Assert too that a
   scheduled workflow rerunning green does *not* change it (see requirement 3b
   — this is where the feature quietly dies), and that a repo whose state could
   not be sampled makes the cycle unfingerprintable rather than skippable.
7. **A blocked verdict round-trips.** Append an `attempt-failed` for a
   selected item, then run a cycle: the Co-Ordinator's input must list that
   item as blocked, with its detail. This is the one check that catches the
   writer and the reader disagreeing about the event key (requirements 33/34)
   — nothing else in the system will tell you they disagree, because both
   halves look correct in isolation and the only symptom is work being
   silently redone.
7a. **The mandatory re-check round-trips too (requirement 18a).**
   `test/cycle-state.test.sh`'s requirement-18a section passes, proving both
   halves the requirement adds on top of check 7's general case. The
   comparison itself — a blocked GitHub issue's `updated_at` against the
   *later* of the block's `ts` and its `recheck_clean_ts` — is the
   Co-Ordinator's own judgement (prompts/coordinator.md, "A blocked issue
   with fresh evidence must be re-read"), not shell code, so the test mirrors
   that documented rule to check the real data `blocked_items` computes:
   with only an `attempt-failed` on record, an issue `updated_at` after the
   block's `ts` reads as due a mandatory re-read and one no later than `ts`
   does not (half 1, "forces the whole-thread re-read"); appending a
   `recheck-clean` folds `recheck_clean_ts` in, and the same, unchanged
   `updated_at` that just read as due now reads as not — a thread that said
   nothing new is not paid for twice (half 2, "stops the next cycle repeating
   it"); moving `updated_at` again past the `recheck_clean_ts` flips it back
   to due, so the marker's suppression lasts only as long as the thread
   stays quiet. Together with check 7, this is the writer
   (`recheck-clean`, requirement 33) and the reader (`blocked_items`'s fold)
   agreeing on both timestamps a blocked GitHub issue carries, the same way
   check 7 catches them agreeing on one.
7b. **An orphaned claim branch is put back in front of the pipeline
   (requirement 17b).** `test/sweep-orphan-branches.test.sh` passes: with a
   stubbed `gh`, a stale moved ref with no PR and no registry entry yields a
   draft PR carrying `pr_label` and a `recovered` action; a stale unmoved
   ref in the same state yields a ref delete and a `released` action; a ref
   with an open PR, a ref with a live registry entry, and a ref younger
   than `abandoned_draft_after_hours` are each left untouched; a registry
   read that fails with anything but 404 leaves the ref alone and says so
   (`warning`, fail closed); a missing label falls back to an unlabelled PR
   loudly; a stale ref with commits ahead but a merged PR against its head
   yields a ref delete and a `released` action rather than another recovery
   draft, and a failure to determine the merge state leaves the ref alone
   and says so; a stale ref with commits ahead, no merged PR of its own, but
   a rival branch sharing its stem merged after its first commit
   yields a ref delete and a `released` action carrying `reason: superseded`
   and the rival's URL, with **no** `pr create` call ever made; a same-stem
   rival that merged before this branch's own first commit does not count,
   and a tech-debt id's own eight-hex-digit numeric suffix (`TD-PPagop-
   26081403`) is never mistaken for the twelve-character random one, so
   neither collapses two unrelated same-scope items to one stem — both still
   yield the ordinary recovery draft, silently; and a failed or unparseable
   rival lookup also still yields the ordinary recovery draft, but with a
   `warning` naming the branch, distinct from the silent no-match case; and
   a backlog past the per-run cap acts on the cap's worth and reports the
   remainder (`deferred`) rather than flooding or staying silent. For the `td-record/*` namespace
   (TD-PPagop-26082310): a stale record branch whose only pull request was
   closed without merging yields a ref delete carrying
   `reason: "filing-declined"` and, on a clean 404 for `tech-debt/<id>.md` at
   the default branch, a second `released` for the paired `td/<id>`
   reservation, with **no** `pr create` call ever made; a 200 for that record
   keeps the reservation, and a contents read failing with anything but 404
   keeps it and says so (`warning`, fail closed); a *merged* filing is
   released by the ordinary merged-PR arm instead, never counted as declined
   and never asked the reservation question at all; a record branch with an
   open PR is left untouched and one with no PR at all is still recovered as
   a draft, both by the ordinary flow; and a run with only one action of
   headroom left defers the
   declined pair whole — neither ref touched — so the per-run cap holds
   strictly rather than overshooting by the release.
7c. **Claim visibility is deterministic, both shapes and both directions
   (requirement 3o, issue #175).** `test/claim.test.sh`'s `claims`/`branches`
   section passes: a fresh branch claim's registry entry appears in `claims`'
   output tagged `kind: "branch"` with its item; an entry older than
   `claim_ttl_hours` does not (the staleness escape survives); and `branches`
   no longer recognises the `td/` namespace at all — a live `td/*` ref
   matches nothing it lists, regardless of its age or its registry entry.
   `test/noop-skip.test.sh` covers
   the fingerprint half: a fresh entry added to `claimed` changes the
   fingerprint, and an empty `claimed` array canonicalises identically to an
   absent key, so a claim ageing back out of the array changes it too — the
   same silent-stall shape `abandoned_drafts` and `merge_conflicts` close for
   their own transitions.
7d. **The PR-keyed claim outlives the PR's own raising (requirement 17a,
   issue #360).** `test/pr-claim-hold-through-review.test.sh` passes: with
   `release_claim` and `release_pr_claim` lifted from `lib/candidate-select.sh`
   and
   the real `lib/claim.sh` running against a create-only `gh` stub,
   `have-pr-pending` drops the item-keyed registry entry and leaves the
   `pr-<n>` one standing; a peer's own claim on that same `pr-<n>` loses
   (rc 3) for as long as it stands, and wins only once `release_pr_claim`
   has run; `release_pr_claim` is idempotent; `have-pr`/`no-pr` still
   drop both entries together in the one call, the ordinary end-of-cycle
   shape; and an unhandled `errexit` abort after `pr-raised` — the one
   ending no handler reaches — still releases the `pr-<n>` entry through
   the EXIT trap's backstop, proven by running the real `cleanup` under
   `set -e`. `test/claim.test.sh` covers the back-pressure half: `count`
   counts the item-keyed entry a cycle just won and does not count a
   `pr-<n>` entry surviving on its own; and, given the pull requests the
   caller has already counted, it drops an item claim naming one of them
   while keeping a claim on a PR the caller's sum does not hold — matching
   whole numbers, so a claim on PR 90 survives a caller that counted PR 9.
7e. **The back-pressure block hands its parts to each other correctly
   (requirement 2.2).** The counting seam, not the parts: issue #427 and the
   over-correction in PR #434 were both defects of this wiring, and both
   shipped past a suite that tested `lib/claim.sh count` thoroughly and its
   caller not at all. `test/backpressure-wiring.test.sh` passes, against the
   block lifted verbatim from `agent-cycle.sh` with a `gh` stub replaying a
   listing per repo and a `lib/claim.sh` stub recording its argv: each repo's
   claim count is asked for against that repo's own drafts and
   pipeline-owed PRs and no others, so a claim on an approved PR waiting
   on a human keeps counting; a repo whose listing could not be read names no
   PRs at all, counting every claim, which is the fail-closed reading beside
   its own zeroed counts; and the composition line states the split the
   operator and the dashboard card both read. The same test covers the
   exclusion's level-awareness (D18 WI-6, requirement 2.3c): the identical
   approved, non-`CHANGES_REQUESTED` pull request is excluded for a repo at
   `human` and counted for one whose `merge_autonomy_effective_level` is
   `agent-merges-routine`, and in the counted case its claim does not
   double-count on top of it — so the difference is demonstrably the level
   and not a change to the underlying rule.
7f. **The decision site folds in what requirement 2.2's count could not see
   yet (requirement 2.2b, issue #459).** `test/backpressure-decision.test.sh`
   passes, against the fold-in block lifted verbatim from `agent-cycle.sh`: a
   repo with no `merge_conflicts`/`dequeued` candidates adds nothing and
   leaves `adjusted_open_count`, `open_composition` and `backpressure_tripped`
   untouched; a candidate PR already among `counted_prs_json`'s drafts and
   pipeline-owed PRs (it happened to also be `CHANGES_REQUESTED`) is not
   added again; a candidate PR that count did not hold is added exactly once,
   grows `adjusted_open_count` by it, and is named in `open_composition`; the
   same PR named by both `merge_conflicts` and `dequeued` is not
   double-counted; two repos' candidates are both folded in, and a PR number
   shared by two repos is scoped per repo rather than conflated; a fold-in
   that reaches `max_open_agent_prs` trips `backpressure_tripped` from `0` to
   `1` even though requirement 2.2's own count left it untripped; and an
   already-tripped cycle with nothing left to fold in stays tripped without
   its composition line changing.
