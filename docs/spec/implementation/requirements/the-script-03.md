## Requirements

### The Script — requirements, continued (part 3 of 10; 2.3a–2.4: The fleet switch…)

2.3a. **The fleet switch.** The same switch, one level up: `fleet/disabled.json`
   on the state repository's main, holding the same record shape and read
   through the same evaluation. With several nodes active, "stop the
   pipelines" has to mean all of them, so `--disable` writes both levels
   (local first — it always works — then the fleet, with a loud warning
   naming the degraded state when the fleet write fails) and `--enable`
   clears both (and must **never** report the fleet flag cleared when it is
   not: an operator who believes they resumed the operation while every node
   still stands down is the worst lie this switch can tell). Both pipelines
   check it at cycle start, after the local switch and still before the
   lock; it costs one contents-API read.

   The local half of that pair is a *mirror*, tagged `scope: "fleet"`
   (requirement 2.3), and it is load-bearing rather than incidental: the fleet
   flag fails open when the state repo is unreachable, so the mirror is what
   holds the issuing node closed in that window. It is retagged `"node"` if
   the fleet write fails, and no reader may present it as a stand-down of that
   node's own while the fleet flag stands.

   A successful flag *write* also primes the local cache, exactly as a
   successful fetch does — otherwise the node that set a flag is the only one
   in the fleet holding no local copy of it, and an outage in the next minute
   drops it through this level's fail-open while every peer that had fetched
   once reads the flag from cache and stops. `fleet_flag_delete` already drops
   the cache on success; this is the other half of that symmetry, and it is
   what lets `--status` tell an unreachable state repo from a switch someone
   else cleared.

   **A flag's read is memoised for the life of the process** (issue #502),
   this level's flags and requirements 2.1, 2.3b and 2.3c's alike, since all
   of them go through the one `fleet_flag_fetch_status`. A `live` or `clear`
   answer — the two the state repository actually confirmed — is served to
   every later read of the same flag through the same `state_dir` and the
   same 404 mode in that process without a second contents-API call, so a
   cycle consulting one flag
   once per repository (requirement 2.2's own per-repository read of
   `merge_autonomy_effective_level`) spends one read on it rather than one per
   repository. The mode is part of that key because the default mode and
   `probe-404` deliberately resolve one and the same contents-API 404
   differently (requirement 2.3b), so a `clear` memoised by a default-mode
   read must never be served to a `probe-404` read of the same flag, which
   would silently disarm a fail-closed flag for the rest of the process. A
   `cached` or `unreachable` answer is never memoised: it is
   already this process's own uncertainty about a fetch that did not complete,
   so one bad moment must not decide every read for the rest of the run. A
   memoised answer is served only when it is present *and* non-empty — the
   entry is read in one step rather than tested for existence and then read,
   so a memo file that has vanished, or that an interrupted write left empty,
   falls through to a live fetch instead of being served as an empty answer
   (which on the kill switch reads as `enabled`, the one direction it must
   not fail in). A
   write or delete the process itself performs drops its own memo of that
   flag, so a flag it just set is never shadowed by its own earlier read. And
   a memo left in `TMPDIR` by a *dead* process is dropped when `lib/toggle.sh`
   is sourced — the memo is named from the process's PID, which is unique only
   among the processes running now, so without that a recycled PID would serve
   one process another process's answer for its whole run, and on the kill
   switch (requirement 2.3b) that is an operator's `disabled` read as `clear`.
   What the memo costs is mid-cycle freshness: a flag someone sets while a
   cycle is running is picked up by the next cycle's process rather than
   part-way through this one, which is the same staleness the interval between
   cycles already accepts. The kill switch's own *advisory* reads — the
   back-pressure count and `void_obsolete_ctx_json` — pay exactly this cost,
   same as any other flag. A caller that is about to take an outward action
   under the level rather than merely compute with it — `run_approver_stage`
   and D18 WI-7's arming step (requirement 8d) are the two such sites —
   asks `merge_autonomy_effective_level` for a fresh read instead: a non-empty
   FRESH argument skips this one call's memo hit and always asks GitHub, so a
   kill set from outside the process is seen at the stage boundary rather than
   replaying the cycle's first answer, at the cost of one extra contents-API
   read per acting site per cycle. The fresh answer is still written back to
   the memo afterwards, so a later advisory read in the same process benefits
   from it rather than repeating the fetch. FRESH reaches both flags the
   effective level rests on — the kill switch and the per-repo merge-budget
   freeze (requirement 8c's governor) — so neither can bind a cycle late; the
   freeze's own read is skipped entirely for any repository configured at
   `agent-approves` or below, whose level the freeze could not lower anyway.

   **`--this-node` (requirement 2.3) opts a single node out of this level
   entirely.** `--disable --this-node` writes only the local record and skips
   the fleet publish outright — not a degraded fallback of the unmodified
   path, but the deliberate point of the flag: the rest of the fleet must keep
   running. `--enable --this-node` clears only the local record and never
   calls the fleet delete, so a fleet-wide disable (or a peer's own
   node-scoped one) survives it untouched — and it refuses outright when the
   local record is a `scope: "fleet"` mirror, since clearing that one would
   drop the issuing node's fail-closed hold on itself while the fleet switch
   is still set. Every other property of this requirement — record shape,
   failure directions, expiry — is unchanged; `--this-node` decides only which
   levels a write reaches, never how a record already written is read or
   evaluated.

   Failure directions, deliberately: a 404 is *clear*, definitively; an
   unreachable state repo falls back to the copy cached at the last
   successful fetch (`state_dir/fleet-cache/`), and to enabled when there is
   none — safe to fail open because a node that charges ahead blind meets
   per-item claims that fail closed (requirement 17a); a flag that exists
   but does not parse is *disabled*, exactly as for the local record.

   Those directions are the *read*'s. The **clear** side never accepts a 404
   on its own, because `absent` there is a claim that the flag has been
   cleared rather than merely that nothing stands the fleet down:
   `fleet_flag_delete` probes `repos/<state_repo>` — `fleet_repo_visible`,
   the same probe requirement 2.3b's read spends — on every 404 its
   read-for-sha meets, unconditionally, and only a probe that confirms the
   repo is visible resolves to `absent`. Anything else the probe returns —
   404, 403, a timed-out call — is a failed delete: `fleet_flag_delete`
   returns non-zero, `fleet_flag_delete_outcome` reports `failed`, and
   `--enable`, `--clear-limit` and `--restore-merge-autonomy` (requirement
   12) each warn and name the manual fallback rather than report the flag
   clear. Unlike the read there is no cached-or-unreachable fallback to take
   instead — a delete has no cached copy of "the flag is gone"
   (TD-PPagop-26081604).

   An expired fleet disable is cleared by whichever cycle sees it first — the
   delete is sha-guarded and idempotent, so a lost race means a peer got
   there, and there is no singleton chore (requirement 2.5). The review
   pipeline honours the fleet switch but never sets or clears it, mirroring
   its relationship to the local one (`docs/spec/review.md`, R2a).
2.3b. **The merge-autonomy kill switch** (D18,
   `docs/reviews/2026-08-14-autonomy-investigation.md` §6; `lib/merge-autonomy.sh`).
   A second fleet flag, `fleet/merge-autonomy-kill.json`, independent of the
   fleet switch above: setting it forces every repository's *effective*
   `merge_autonomy` level to `human` immediately, fleet-wide, without touching
   `config.json` or restarting a container, while cycles keep running exactly
   as they would with the switch clear — killing merge autonomy stops
   approval and landing decisions, nothing else. "Immediately" is exact only
   at the site that acts on the level: `run_approver_stage` asks
   `merge_autonomy_effective_level` for a fresh read (requirement 2.3a's own
   FRESH argument) rather than the process-lifetime memo every other reader
   uses, so a kill set mid-cycle stops that stage at its own boundary; an
   advisory reader elsewhere in the same process still sees the cycle's first
   answer until the next cycle's process, exactly as requirement 2.3a
   describes. It reuses `lib/toggle.sh`'s
   generic fleet-flag machinery outright (`fleet_flag_fetch_status`/`_write`/
   `_delete`, the same CAS-guarded contents-API mechanism `fleet/disabled.json`
   already uses) under its own flag name, so a peer with an unreachable state
   repo falls back the same way requirement 2.3a's own flag does when it has a
   cached copy — to the last-fetched cache. Unlike requirement 2.3a's flag, a
   repo unreachable at the transport level (DNS, connection refused, a 5xx)
   with *no* cached copy at all reads as killed, not clear
   (TD-PPagop-26081507): `fleet_flag_fetch_status` is what lets
   `merge_autonomy_kill_state` tell that case apart from a clear-flag 404,
   which `lib/toggle.sh`'s plain `fleet_flag_fetch` deliberately cannot —
   the Design decisions entry on this switch explains why this one flag's
   fail-closed direction is correct where `fleet/disabled.json`'s and the
   usage-limit flag's fail-open one still is. One 404 is not the flag's own:
   the contents API answers "this repository does not exist, or this token
   cannot see it" with the same `404 Not Found` as "the flag file does not
   exist", so the kill switch's read never treats a flag-file 404 as clear
   on its own — `merge_autonomy_kill_state` asks `fleet_flag_fetch_status`
   for its probing mode (`probe-404`), which probes `repos/<state_repo>`
   first, and only a probe that confirms the repo is visible resolves to
   clear (TD-PPagop-26081602).
   Anything else the probe returns — 404, 403, a timed-out call — is treated
   exactly like a transport failure on the flag fetch itself: the fresh-node,
   no-cache case fails closed to `human`, and an established node falls back
   to its last-fetched cache. So a misconfigured `state_repo` slug or a token
   whose scopes lost access to it fails closed on the same terms as a DNS
   failure would, not clear. `scripts/doctor.sh`'s kill-switch report
   distinguishes this fail-closed synthesis — which names itself
   `record.kind: "fail-closed"`, a marker `merge_autonomy_kill_state` writes
   and nothing else does — from every genuine kill, including one set by
   hand through GitHub's web editor and one that arrived garbled, neither of
   which carries a `kind` at all. So an operator reading `[warn] the
   merge-autonomy kill switch is SET` versus `[warn] … could not be confirmed
   clear` is told which one they are looking at, alongside
   `check_repo_access`'s own report of `state_repo` unreachable-or-invisible.

   Managed by `--kill-merge-autonomy [<reason>]` and `--restore-merge-autonomy`
   (requirement 12), on the same terms as `--disable`/`--enable` where they
   apply and deliberately not where they don't: a reason is required on
   `--kill-merge-autonomy`, the record carries `actor`/`kind` exactly as
   `toggle_disable`'s own (`kind` always `manual` — nothing automatic writes
   this flag), and `--status` reports it (`merge_autonomy: KILLED — …`; or
   `merge_autonomy: FAIL-CLOSED — …` when the record is the unreachable
   synthesis, the same `record.kind: "fail-closed"` split `scripts/doctor.sh`
   makes and reporting-only either way, #454; or `not killed`) alongside the
   switch and the usage-limit stand-down — a
   report driven by the same "anything but clear reads as killed" test
   `merge_autonomy_effective_level` applies, so what `--status` and
   `scripts/doctor.sh` say and what a level resolution does cannot disagree.
   Each command logs its own event (requirement 33): `merge-autonomy-killed`
   carrying the record's `reason`/`by`/`actor`/`kind` and the
   `fleet_flag` outcome word, on the same terms as `disabled`'s; and
   `merge-autonomy-restored`, logged by outcome rather than by instruction —
   only where a flag was actually cleared, exactly as `enabled` is. Unlike
   the fleet switch there is no local record and no `--this-node` form: the
   kill switch is described as "a permanent operational control, not
   scaffolding" (§6) precisely because a single Approver App identity governs
   the whole fleet, so a node-scoped override would contradict what it is
   overriding. With no `state_repo` configured, `--kill-merge-autonomy` refuses
   (exit 64) rather than pretend to take effect — a flag this system cannot
   publish anywhere a future read would see it is not a kill switch, and a
   single-node install is already fully governed by its own `merge_autonomy`.
   `--restore-merge-autonomy` is idempotent: with no `state_repo`, or with the
   flag already clear, it says so and exits 0.

   `merge_autonomy_configured_level` (`CONFIG_JSON`, `SLUG`) resolves the
   *configured* level alone — a repository's own `repos[]` override when
   present, else the top-level `merge_autonomy` key, else `human` — on the
   same precedence `stage_timeouts` uses (requirement 4f). It has no opinion
   about the kill switch. `merge_autonomy_effective_level` (`CONFIG_JSON`,
   `SLUG`, `STATE_REPO`, `STATE_DIR`) is the one function that combines the
   overrides with it: `human` whenever the kill switch is set (or unreadable
   — everything ambiguous resolves toward the safe reading here too,
   mirroring 2.3's own rule); otherwise the configured level, capped at
   `agent-approves` by that repository's own merge-budget freeze where one is
   set (requirement 2.3c). Every approval or landing path must call the
   effective function, never the configured one directly, or neither override
   would actually override what it promises to — which is also what lets
   requirement 2.3c's freeze take effect everywhere with no call site of its
   own. Its readers are the Approver gate (requirement 8b) and requirement
   2.2's per-repository back-pressure exclusion. `scripts/doctor.sh`
   (component 14) reads the *configured* level instead, deliberately, so a
   pairing that would fail the moment someone clears the switch is caught now
   rather than only once they do.
2.3c. **The merge budget** (D18 §5.4, `docs/reviews/2026-08-14-autonomy-investigation.md`;
   `lib/merge-budget.sh`). `merge_budget_per_day` is a rolling-24-hour cap,
   per repository, on how many pull requests this pipeline may *land* —
   fleet-wide default with a `repos[]` override, on the same precedence
   `merge_autonomy` and `stage_timeouts` use (requirement 4f). `0` means
   unlimited and skips the count entirely, on the same terms
   `stage_inactivity`'s per-actor `0` already carries.

   `merge_budget_window_status` (`SLUG`, `PR_LABEL`, `MERGED_LOGIN`,
   `[NOW_ISO]`) counts SLUG's merged pull requests carrying `PR_LABEL`,
   merged by `MERGED_LOGIN` (the Approver App identity's own login —
   passed in, never looked up by this file, so it stays independent of
   `lib/approver-token.sh`), with `mergedAt` inside the trailing 24 hours of
   `NOW_ISO` — counted from GitHub's own record, never a private counter a
   restart or a second node would not share. The listing is *scoped* to the
   window by GitHub's own `merged:>=<cutoff>` search qualifier, not merely
   filtered to it afterwards: `gh pr list` orders by creation, so an unscoped
   `--state merged` listing enumerates the label's whole lifetime history,
   which every repository this fleet governs passes within weeks and never
   comes back under — leaving the listing truncated on every call and `arm`,
   `hold` and the anomaly freeze all permanently unreachable. The `jq` filter
   still decides the count on an exact `mergedAt >= cutoff` comparison, so
   the qualifier need only be a superset of the window. A listing that comes
   back at `GITHUB_PR_LIST_LIMIT` (requirement 2.2's own truncation cap)
   reads `truncated`, the same fail-closed direction as an
   outright-unreadable listing: an undercount here is the dangerous one for a
   governor.
   `merge_budget_decide` (`CONFIG_JSON`, `SLUG`, `PR_LABEL`, `MERGED_LOGIN`,
   `[NOW_ISO]`) turns the count into one of three outcomes: `arm` (under
   cap), `hold` (at or over cap — the pull request is still approved
   through the ordinary review path, but its landing does not arm; the
   backlog queues visibly rather than merging past the cap) or `refuse`
   (the count could not be established). A `hold` at cap 0 is impossible by
   construction — the count is never attempted — and a `hold` otherwise
   carries `waiting_backlog`, the oldest open, non-draft, `PR_LABEL`-carrying
   pull request for SLUG (`merge_budget_oldest_waiting`), best-effort: its
   own failure never turns a `hold` into a `refuse`.

   Landing *more* than the cap in a window — `count > cap`, a counting
   anomaly a correct governor should never observe, flagged as `anomaly:
   true` alongside the `hold` — freezes SLUG to `agent-approves`, never all
   the way to `human`: the Approver App still reviews, only automatic
   landing stops, and every other configured repository is unaffected. The
   freeze is a fleet flag, `fleet/merge-budget-freeze-<slug>.json` (slug
   slashes replaced with `-`), reusing `lib/toggle.sh`'s generic CAS-guarded
   contents-API machinery exactly as the merge-autonomy kill switch
   (requirement 2.3b) does, under its own per-repo flag name —
   `merge_budget_freeze_state`/`_set`/`_clear`. Unlike the kill switch, an
   unreachable state repo with no cached copy reads this flag as *not*
   frozen: the kill switch fails closed because an operator's own lever
   must hold even from a node that cannot currently confirm it, but a
   freeze exists only because a live, reachable count just observed the
   anomaly, so a node that cannot reach the state repo a moment later has
   no anomaly of its own to act on.

   `merge_autonomy_effective_level` (requirement 2.3b) reads the freeze
   directly — capping the configured level at `agent-approves` whenever
   SLUG's freeze is set and the configured level ranks above it — so every
   caller of that one function (the kill switch's own contract: never call
   `merge_autonomy_configured_level` directly) already honours a merge-
   budget freeze too, with no call site of its own to add or forget. The
   kill switch is checked first and still wins outright: a repository
   already forced to `human` gains nothing from also being frozen.

   `merge_budget_apply_decision` (`DECISION_JSON`, `SLUG`, `STATE_REPO`,
   `ESCALATION_LABEL`, `ASSIGNEE`) is the write side `merge_budget_decide`
   itself deliberately is not: a `refuse` logs a `warning`
   (requirement 33); a `hold` logs `merge-budget-hold` carrying `repo`,
   `cap`, `count` and `waiting_backlog`; an anomaly additionally freezes
   SLUG (logging `merge-budget-frozen`) and files an escalation issue
   against SLUG itself — never `crash_loop_repo`, because unlike a crash
   loop or a usage-limit freeze this anomaly is a fact about one
   repository, not the fleet, the same reasoning `approver_escalate`
   (requirement 8c) already applies — deduplicated the same way every
   other escalation is (an open issue in SLUG already naming this item's
   ref), logging `merge-budget-freeze-escalated` only on an issue actually
   filed.

   `run_landing_stage` (requirement 8d, D18 WI-7) is the one
   behaviour-affecting caller of `merge_budget_decide` and
   `merge_budget_apply_decision` — one of the gates the arming step re-reads
   fresh before landing a pull request itself. `merge_autonomy` at `human`
   is unaffected by any of this: a freeze only ever lowers a level already
   above `agent-approves`, and a repository configured at or below it stays
   exactly as configured, frozen or not.
2.3d. **The drain mode** (agent-ops#865, agent-ops#903). The switch's record
   (requirement 2.3) carries a second field, `mode`: `"stop"` — the switch's
   original, only behaviour, and what every record written before this field
   existed reads as — or `"drain"`, written by `--drain <reason> [--for
   <90m|4h|2d|forever>] [--until <timestamp>] [--this-node]`. Same TTL
   resolution, same scope/fleet-flag mechanics, same mandatory reason, same
   `--this-node` handling as `--disable` (requirement 2.3) — `--disable` and
   `--drain` are the same write with one field different, so every mechanic
   requirement 2.3/2.3a already define for the switch — expiry, the "resolve
   toward disabled" failure direction, `--this-node`'s node/fleet split, the
   fleet-write-failure retag — applies to a drain unchanged, without a second
   implementation of any of them. `--enable` (or `--enable --this-node`)
   clears either mode identically, since it deletes the record outright
   rather than inspecting it.

   A stop and a drain do not coexist quietly — one always governs, and moving
   between them is one-directional except through `--enable`:
   - **`--disable` issued while a drain is active tightens it to a full stop
     immediately** — the same overwrite an ordinary repeated `--disable`
     already performs, with `mode` reverting to `"stop"`.
   - **`--drain` issued while a stop is active is a usage error** (exit 64):
     writing a drain over a stop would *loosen* the stand-down, and only
     `--enable` may loosen — silently downgrading an operator's or a peer's
     stop to a drain would let new work move again under whatever the stop
     was protecting against. "Active" means either level: this node's own
     record, *and* — for a fleet-scoped `--drain`, the only kind that
     publishes a flag — the fleet switch of requirement 2.3a, which a peer's
     unmodified `--disable` sets without writing anything to this node's
     `state_dir` at all. Reading the local record alone would leave the one
     case that matters most unguarded, since republishing
     `fleet/disabled.json` as a drain downgrades every node at once. The
     fleet half is read on the same fail-open terms as every other reader of
     that flag: an unreachable state repo reads `enabled`, and in that same
     window the drain's own fleet write fails and retags itself `node`
     anyway. A `--drain --this-node` is unguarded by the fleet half by
     design — it publishes no flag, so it can loosen nothing, and the node
     stays stood down by the fleet stop regardless of what its own record
     says.
   - **`--drain` issued while a drain is already active extends it** — the
     same `extends`-in-the-log behaviour a repeated `--disable` already has,
     with a fresh `disabled_at` (and therefore a fresh window for requirement
     2.9's at-rest check, since a `drained` event is keyed on that field).

   Behaviourally, the two modes diverge only downstream of the switch check
   itself. A `mode: "stop"` record is unchanged from before this
   requirement existed: `agent-cycle.sh` exits immediately at the check
   (requirement 2.3/2.3a's own site), before the lock, before any `gh` call,
   and `review-cycle.sh` stands down identically (`docs/spec/review.md`,
   R2a). A `mode: "drain"` record does not exit there: `agent-cycle.sh` sets
   `DRAINING` (and `DRAIN_DISABLED_AT`, from whichever of the local or fleet
   record is active — the fleet one winning if both are, since it is the
   broader-scoped decision and the two ordinarily share one `disabled_at`
   anyway) and continues past the check; what a drain actually restricts is
   requirement 2.2c's own narrowing, applied unconditionally rather than only
   on back-pressure, and requirement 2.9 describes the at-rest detection and
   reporting built on top of it. `review-cycle.sh` stands down under a drain
   exactly as under a stop — it has no finishing set of its own to keep
   working, since every review it starts is new work by construction — so its
   existing `.state == "disabled"` check needs no `mode` branch at all; only
   its stand-down log line names which mode it was, for a reader wondering why
   a drain — nominally about letting existing work finish — stood this
   pipeline down entirely.

   The `disabled`/`enabled` events requirement 2.3/33 already define carry
   `mode` (`"stop"`/`"drain"`) alongside `scope` and `fleet_flag`, so a log
   reader can tell which was in force without cross-referencing the record
   file, which may have since been cleared or overwritten.
2.4. **The role guard.** The environment variable `AGENT_OPS_ROLE` names the
   one node that runs unattended cycles. Compared case-insensitively and
   ignoring surrounding whitespace against the single value `active`;
   **anything else — unset, empty, misspelt, or a word from some other
   vocabulary — is a standby**, and a standby exits 0 after writing one line to
   stdout (which cron redirects into `cron.log`) naming the role it saw.

   Checked *before the configuration is read*, and therefore before the lock,
   the log and the cycle directory: a standby tick must leave no trace in
   `state_dir` at all. That is stricter than the switch, which logs its
   stand-down, and deliberately so — a standby's `state_dir` holds no work of
   its own, so an event written there on every tick is noise in a stream
   that is otherwise a record of cycles, and an empty cycle directory on
   every tick is indistinguishable from a cycle that died before it logged
   anything.

   Bypassed by `--dry-run` and `--once`, which are a human asking for a cycle
   rather than an unattended one, and by `--disable`/`--enable`/`--status`,
   which manage shared state and must answer on every node. Not bypassed by
   `--repo`, which narrows an otherwise ordinary cycle. The switch is checked
   *after* the guard, so a standby node neither logs nor clears it: the record
   belongs to the active node, and expiry is its business to notice.

   **Why fail-closed.** The pipelines run on several machines (the laptop
   and any number of cloud nodes), and any number of them may be active at
   once — per-item claims (requirement 17a) keep concurrent actives off the
   same work, so the role no longer elects "the" worker; it decides whether
   *this* machine spends unattended at all. The two mistakes are still not
   symmetric: a node wrongly standby costs skipped cycles, visible on the
   dashboard within the hour and fixed by one variable; a node wrongly
   active spends money nobody chose to spend. So the guard resolves every
   ambiguity toward standby, exactly as requirement 2.3 resolves every
   ambiguity toward disabled. The guard is a local, zero-cost check: spend
   is opted into per machine, deliberately, never inherited from a typo.

   Implemented in `lib/role.sh`, shared with `review-cycle.sh`
   (`docs/spec/review.md`, R2b) so "active" has one definition.
