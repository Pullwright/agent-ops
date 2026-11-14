## Acceptance checks

### Acceptance checks — continued (part 2 of 10; items 2m–2k)

2m. <a id="impl-ac-2m"></a>**The installation has one push-notification channel, and everything the
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
     `lib/enabler.sh` — the whole of acceptance check 2m before this rewrite, now
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
     `key` distinguishes the four instances (`standdown:usage-limit:<provider>`
     — `anthropic`, `xai`, … (issue #2135) — `standdown:node-switch:<node>`,
     `standdown:fleet-switch`, `standdown:merge-autonomy-kill`) so the
     coalescing below is per stand-down, not one bucket for all of them — and
     each instance's `begin` and `end` share that one key, which is why the
     coalescing below keys on the event too.

   An event whose class is not a member of `notify_events` is dropped before
   `notify_webhook_url` is even read — never sent, never logged. Every
   guarantee acceptance check 2m always made carries over unchanged: no `gh`/
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
   construction — `fleet-standdown-begin`/`-end` on
   `standdown:usage-limit:<provider>` and its three siblings,
   `pager-fired`/`pager-cleared` on the pager's own key — and a stand-down in
   force re-posts its `begin` every cycle, so keying on `key` alone would
   hold that key's last `notify-sent` permanently younger than the interval
   and suppress the `end` an operator is actually waiting on. A read log this node has not written yet is
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
2n. <a id="impl-ac-2n"></a>**A cycle does not start work the host has no room to finish, on either
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
2n-i. <a id="impl-ac-2n-i"></a>**A cycle does not start work the host has no memory to run (requirement
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
2n-ii. <a id="impl-ac-2n-ii"></a>**A cycle does not start work that overcommits the host it shares with
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
2n-iii. <a id="impl-ac-2n-iii"></a>**A cycle does not start work the host's own parent cgroup is
   throttling, even while the host itself has memory free (requirement
   2.0i, agent-ops#2469).** `test/memory.test.sh` passes:
   `memory_cgroup_throttle_rate_per_min` reads the parent's `memory.events`
   `high` counter's rise, in events per minute, between two readings, flooring
   a falling counter's delta at `0` rather than reading it negative (the
   parent cgroup was recreated), and is empty — never `0` — when the current
   counter is unreadable, there is no previous reading, or the elapsed time
   between the two is not strictly positive;
   `memory_cgroup_throttle_verdict` reads `throttling` only when that rate
   exceeds `max_cgroup_throttle_per_minute`, `ok` at or below it, and empty
   for a `0`/non-numeric threshold or whenever the rate itself is empty —
   never a verdict standing anything down on a guess;
   `memory_cgroup_throttle_describe` names the measured rate, the configured
   threshold and the elapsed window;
   `memory_cgroup_headroom_verdict` reads `near-ceiling` only when the gap
   between this cgroup's own `memory.current` and the parent's own
   `memory.high` falls below `min_cgroup_headroom_bytes`, `ok` above it, and
   empty for a `0`/non-numeric floor, an unreadable `memory.current`, or a
   parent `memory.high` that is itself unreadable or `max`;
   `memory_cgroup_headroom_describe` names what is held, the parent's own
   ceiling and the configured floor.
   `test/memory-throttle-wiring.test.sh` passes against the real
   `memory_throttle_check`/`_memory_throttle_escalate` functions
   (`lib/standdown.sh`), sourced directly rather than lifted by text
   extraction since both are defined at file scope precisely so the same
   function serves both call sites (requirement 2's own 0i slot and the
   pre-Co-Ordinator recheck at the top of band 4) without duplicating the
   logic: a `throttling` rate verdict or a `near-ceiling` headroom verdict
   each independently exits 0 with a logged `stand-down` event carrying
   `cause: "memory-throttled"` and the terminal node state to match, never
   falling through; both verdicts `ok`, or both empty (no parent window, or
   no previous reading), fall through untouched, standing nothing down;
   the consecutive count only advances on a real `throttling`/`near-ceiling`
   or a real `ok` — an empty verdict (no evidence either way) leaves it
   exactly where it was, so a transient read failure can neither manufacture
   nor erase a run; the state file persists whenever either verdict was
   produced, not only when `memory.events` itself was readable, so a
   headroom-only verdict still writes the updated count — with a `-`
   sentinel for the unreadable `memory.events` high, since `IFS=$'\t' read`
   collapses an empty middle field into its neighbour — rather than losing
   a reset or retirement when the process exits (agent-ops#2655); once the
   count reaches `memory_throttle_escalate_after`,
   each further firing calls `_memory_throttle_escalate`, naming this node's
   own `memory-throttled:<node>` item ref, and a clean reading immediately
   afterward calls `lib/enabler.sh`'s `memory_throttle_retire_resolved`
   instead — a clean reading that never reached the threshold calls neither,
   since there is nothing open yet to retire, and nor does an *empty*
   verdict above it, silence being the condition an open escalation is about
   rather than evidence it cleared; a close that could not be made keeps the
   consecutive count, so a later clean reading reaches it again instead of
   forfeiting it for the container's remaining lifetime (agent-ops#2511's
   own lesson, in 0i's shape); a count of `0` for
   `memory_throttle_escalate_after` never escalates regardless of how high
   the consecutive count climbs; `--dry-run` still stands the cycle down
   (standing down changes nothing a dry run needs to suppress) but suppresses
   both the escalation and the retirement lookup, keeping the count for a
   real cycle to retire against.
   `test/doctor.test.sh` passes: the parent `memory.events` `high` rate,
   read against a manually-seeded, non-real elapsed window (sub-second real
   elapsed time between two subprocess runs cannot assert a reliable
   per-minute rate), warns naming the measured rate and the configured
   `max_cgroup_throttle_per_minute` threshold above it, and reads `[ ok ]`
   naming the same rate and threshold when it stays at or below it;
   `max_cgroup_throttle_per_minute: 0` falls back to the plain "any rise at
   all" rule this warning held before this requirement existed, since there
   is then no configured rate to compare against. `test/node-time-state.test.sh`
   passes: `memory-throttled` maps to `externally-blocked`, and the fold's
   own default all-empty shape and `eb_causes` list both carry it alongside
   `memory-low`.
2c. <a id="impl-ac-2c"></a>`scripts/gather-merge-conflicts.sh Poetic-Poems/does-not-exist autonomous-agent agent/`
   prints `[]` and exits 0 — a missing repo, a disabled feature, or an API error
   never aborts the cycle. Its candidate rule, including the `bot`,
   `rebase_requested`, `superseded_by` and `superseded_evidence` fields on a
   Dependabot candidate, is regression-tested (through the real script, via
   `MERGE_CONFLICTS_GH`) in `test/merge-conflicts.test.sh`. Against the real
   API, `scripts/gather-merge-conflicts.sh Poetic-Poems/poetic-fiddle
   autonomous-agent agent/` reports poetic-fiddle #129 (issue #250's acceptance
   test) as a `bot: true` candidate.
2z. <a id="impl-ac-2z"></a>`scripts/gather-dequeued.sh Poetic-Poems/does-not-exist autonomous-agent
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
53. <a id="impl-ac-53"></a>`scripts/gather-landing-refusals.sh o/r autonomous-agent agent/
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
62. <a id="impl-ac-62"></a>**A persistent landing refusal posts, and a cleared one edits, the one
   notice comment (requirement 62, issue #1979).** `test/landing.test.sh`
   passes: `_landing_refusal_persistent` reads `ineligible`, `autonomy-level`,
   `kill-switch`, `open-question`, `protected-path-cooloff`,
   `protected-path-stale-head`, `protected-path-tier`,
   `reconciliation-unanswered`, `human-changes-requested` and
   `merge-queue-occupied` as persistent and every other
   `_LANDING_REFUSAL_CLASSES` member (and an empty class) as not;
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
2h. <a id="impl-ac-2h"></a>**Dependabot's own conflicted PRs are nudged, then — only after a full
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
2d. <a id="impl-ac-2d"></a>**Issue priority is read, defaulted and fingerprinted.**
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
2e. <a id="impl-ac-2e"></a>**Issues arrive pre-fetched, filtered, whole-thread and fingerprinted.**
   `test/issues-prefetch.test.sh` passes: against a stubbed issues endpoint,
   `scripts/gather-issues.sh` drops an assigned issue, a `Blocked`-labelled
   issue (whatever the case), a `pw::pager`-labelled issue (agent-ops#2564),
   and a pull request from `candidates`, while a
   clean issue arrives
   with `source: "issues"`, its number as `ref`, its `Priority` band (default
   `Medium`), its body, and its comments verbatim; the assigned,
   `Blocked`-labelled and `pw::pager`-labelled drops reappear in `excluded`
   tagged `assigned`, `blocked-label` and `pager` respectively, while the
   pull request never does (agent-ops#447); a `Blocked`-labelled issue whose
   own thread *also* names a still-open `Blocked-by:` reference reports both
   reasons, as two entries under the same number, while an otherwise-identical
   `Blocked`-labelled issue naming no such reference keeps reporting the one
   (issue #2607); a
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
2j. <a id="impl-ac-2j"></a>**Tech-debt arrives pre-fetched, pre-excluded, and its verdict is
   corroborated (requirement 3t).** `test/gather-tech-debt.test.sh` passes:
   against a stubbed issues endpoint, `scripts/gather-tech-debt.sh` prints a
   `candidates` array carrying one entry per open `pw::type:tech-debt`-labelled
   issue that survives the
   deterministic filter — `source: "tech-debt"`, the bare issue number as
   `ref` (a string) and as `number`, its `title`, `labels`, `author`,
   `created_at`, `updated_at`, `url`, its `body` and its whole comment thread
   verbatim as `comments`, sorted by issue number ascending — while an
   assigned issue, a `Blocked`-labelled one (whatever the case), a
   `pw::pager`-labelled one (agent-ops#2564) and one naming
   a still-open `Blocked-by:` reference are absent from it, that last one
   arriving
   once its reference closes; each of those four drops is reported in the
   sibling `excluded` array as `{number, reason}`, with the `Blocked-by:`
   one's reason carrying the reference's own display form (agent-ops#2603);
   an assigned issue whose own thread *also* names a still-open
   `Blocked-by:` reference reports both reasons, as two entries under the
   same number, while an otherwise-identical assigned issue naming no such
   reference keeps reporting the one (issue #2607); an issue that never
   carried the label is reported in neither array;
   and a failing API degrades to
   `{"candidates":[],"excluded":null}` (exit 0) with the failure on stderr.
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
2k. <a id="impl-ac-2k"></a>**Blocked/void exclusion reaches every pre-fetched band, `issues`
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

