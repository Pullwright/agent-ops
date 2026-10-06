## Requirements

### The Approver — requirements, continued (part 2 of 2; 51–55: Fleet-level invariants (the pager)…)

51. **Fleet-level invariants (the pager).** Issue #1126's own four-week
    incident table named fourteen fleet-wide failures, none surfaced by a
    pipeline-filed ticket: the silent ones sat four days to a month while
    the repair loop that does escalate closes what it catches at a 2.0 h
    median. Ten of the fourteen turned out to be one-line invariants once
    named, and every one of those ten is a fact already readable from what
    every node replicates — the union fleet log, every peer's heartbeat, this
    node's own doctor verdict. `lib/pager.sh` is where that reading happens.

    `pager_register KEY EVAL_FN REMEDY_CLASS REMEDY_ARG` builds a registry —
    `PAGER_KEYS`/`PAGER_EVAL_FN`/`PAGER_REMEDY_CLASS`/`PAGER_REMEDY_ARG`, four
    associative structures rather than a config file, so a repository's own
    `scripts/publish-dashboard.sh` decides at source time which invariants
    exist. EVAL_FN is a pure function, `EVAL_FN FLEET_NODES_JSON
    UNION_LOG_FILE`, printing one line — `{firing, evidence}`, plus an
    optional `nodes` array the dashboard's own node-card badge reads — with
    one documented exception (`page-outlived-item`, below) that reads GitHub
    directly rather than a replicated fact, since an issue's own terminal
    state is not something any heartbeat carries. REMEDY_CLASS is one of
    `pipeline-act` (REMEDY_ARG names a shell function, `REMEDY_ARG KEY
    EVIDENCE`, run before filing — it performs the fix directly, never
    asking, and its one-line return value is recorded in the issue body),
    `config-lever` (REMEDY_ARG is prose; the tracking issue is filed
    alongside a second, separate `pw::decision` record through the same
    filed-closed-immediately convention `create_decision_log_issue`
    (requirement 36a) uses, so a config-lever remedy inherits #937's veto
    window — reopen the decision record to veto), or `owner-only` (REMEDY_ARG
    is prose naming what the owner must decide; the tracking issue is
    assigned to `enabler_assignee`, the load-bearing half that excludes it
    from the `issues` source, requirement 16.4, exactly as an ordinary
    Enabler escalation).

    `pager_evaluate` runs every registered invariant once, from
    `scripts/publish-dashboard.sh`'s own `WITH_GITHUB` tick of the Publisher
    (`docs/spec/dashboard/publisher.md`'s "The Publisher" section) — the point where
    this node's own union log and every peer's heartbeat have already
    converged for this tick, and the one tick allowed to touch GitHub at all.
    Exactly one node evaluates a given invariant in a given five-minute
    window: a claim on `<key>__<window>` (`window` the epoch second divided
    by 300) through `lib/claim.sh`'s `claim file pager <key>__<window>` — the
    same pseudo-slug pattern the Enabler's own `claims/enabler/` claims use
    (requirement 35c) — so a claim lost or unreachable skips this node's own
    evaluation for the window rather than risk two nodes filing the same
    invariant twice.

    An invariant's lifecycle is event-sourced over the union log,
    transition-only on the same terms requirement 2.7's crash-loop escalation
    and #937's decision log already settled — a firing invariant
    re-evaluated every five minutes writes nothing new — via four event
    names: `pager-candidate {key, first_seen}` the first evaluation seen
    firing; `pager-candidate-cleared {key}` a candidate that stopped firing
    before `pager_min_firing_minutes` elapsed, never having been filed, so
    nothing to retract, only a reset; `pager-fired {key, first_seen,
    evidence, issue_number, issue_url, remedy_class, nodes}` once the
    hysteresis threshold is reached and the tracking issue is filed;
    `pager-cleared {key, cleared_at, evidence}` once a fired invariant
    evaluates clear and its issue is closed. `pager_state_for`/
    `pager_last_event` derive the current state (`clear`/`candidate`/`fired`)
    purely from the latest of these four for a key, on the same no-state-file
    terms `token_expiry_escalated_for` (requirement 2m) already uses for a
    single-shot escalation — any node, in any window, agrees with every
    other about what has already happened.

    `pager_file`/`pager_close` are the filing and auto-close primitives.
    Every firing invariant that reaches the hysteresis threshold gets one
    issue per key, in `pager_repo` (empty falls back to `crash_loop_repo`;
    both empty disables filing — invariants still evaluate and `pager_file`
    still logs `pager-fired`, with `issue_number`/`issue_url` null, so the
    transition still reaches the dashboard and the key can still return to
    `clear` later; nothing is filed on GitHub and nothing is assigned),
    carrying the fixed `pw::pager` label (`lib/labels.sh`'s `escalation`
    *and* `target` role catalogues — both, so that `target`'s own MODE `full`
    reconcile does not delete it out from under this framework in a
    repository holding both roles, which `pager_repo`'s fallback to
    `crash_loop_repo` makes ordinary; see requirement 6a — fixed for the
    identical reason `pw::decision` is: a renamed
    label would silently stop being found by this framework's own dedup and
    auto-close search), deduped on the item reference `pager:<key>` the way
    `create_escalation_issue` dedupes — a body-contains-item-ref search,
    never a second index — though on the bare reference rather than
    requirement 36a's backtick-delimited token, these bodies carrying a
    `ref: <item>` footer of their own rather than an `` Item: `<item>` ``
    one.

    The label is *ensured* in `pager_repo` on the create path, and only
    there, exactly as `create_escalation_issue` does it (requirement 6a's
    `labels_reconcile_role`, the `escalation` role) and for the reason that
    function states: an escalation repository is by construction not one any
    cycle otherwise touches, so its labels have nowhere else to be created.
    Here the label is load-bearing rather than cosmetic — both the dedup
    above and the auto-close below find a page *by* it — so a page filed
    through the retry-without-label fallback would be re-filed on every later
    fire and never auto-closed, leaving on the owner's open list precisely
    the stale page this requirement exists to prevent. Both dedup searches
    and the auto-close search state `--limit 200` rather than inheriting
    `gh`'s undeclared default of 30, on `lib/tech-debt-file.sh`'s own
    `TECHDEBT_DEDUP_LIST_LIMIT` reasoning: a truncated listing is
    indistinguishable from a complete one, and the direction of harm is a
    duplicate filed against an issue the dedup could not see.

    `pager_close` closes it with a one-line comment
    naming that the fact cleared, on `approver_escalation_retire`'s own
    established pattern (requirement 8f's #1215 retirement), and logs
    `pager-cleared` regardless of whether an open issue was actually found to
    close — a human who already closed it by hand, or a webhook-only filing
    that never became a real issue, must still let the key return to
    `clear`. Deliberately independent of `lib/enabler.sh`: its
    `create_escalation_issue`/`create_decision_log_issue` read cycle-scoped
    globals (`cycle_dir`, `enabler_assignee`, `node_name`, `cycle_id`) that
    exist only inside `agent-cycle.sh`'s own per-item cycle, which the
    Publisher never runs as — `lib/pager.sh` mirrors their dedup search, their
    retry-without-label, and `escalation_webhook_notify`'s webhook fallback,
    parameterised, rather than reaching into a stage it is not.

    Configuration: `pager_enabled` (default `true`) gates evaluation
    outright — the first boolean-typed key in this schema, needed because
    unlike `crash_loop_repo`'s own empty-disables convention, an invariant's
    fired/cleared transitions are worth having on the dashboard even with no
    `pager_repo` configured to file into, so `pager_repo` empty cannot double
    as this framework's off switch the way it does for crash-loop escalation.
    `pager_repo` (default empty, falls back to `crash_loop_repo`) and
    `pager_min_firing_minutes` (default 15) are described above.

    Two invariants ship with the framework (`lib/pager-invariants.sh`),
    chosen to exercise the whole of it:

    - **`verdict-unanimous`** (pipeline-act). Fires when every *active* node
      (`.stale | not`; fewer than two active nodes can never be "unanimous")
      reports the identical failing verdict at once — the #1071 signature,
      where all four nodes read `updater: stuck` because the *reader's* rule
      was wrong, not because every node had independently failed the same
      way at the same instant. Checks, first hit wins: a `stage_health` stage
      `failing` on every active node (`stage_health.stages` folds into every
      heartbeat already, requirement 2.8), `updater.status == "stuck"` on
      every active node (requirement 2.6), or `doctor.verdict == "fail"` on
      every active node — the last of these needed a heartbeat change of its
      own: `.doctor-status.json`'s `{timestamp, verdict}` now folds into
      `heartbeat.json` as `doctor`, the same way `stage_health`'s does, since
      this invariant is the first reader anywhere that needs a peer's doctor
      verdict rather than only this node's own. Since agent-ops#1397 a
      **bounded** `fails` folds in beside them — the first three entries,
      each truncated to 200 characters — and the doctor branch's evidence
      names the entries common to every active node (at most two), so the
      page says *which* check failed rather than only that one did; nodes
      failing genuinely different checks, or a peer still publishing the
      older shape, yield no such clause rather than a wrong one, and the
      `stage_health`/`updater` branches' evidence is unchanged. Bounding is
      the point: `warns`/`skips` remain unbounded diagnostic prose with no
      off-node reader and `token_expiry` has no reader off the node holding
      the credential, so those three stay local, and the whole fleet
      re-fetches this file every `schedule.state_sync_fetch_minutes`.
      `publish-dashboard.sh` projects this node's own fleet
      row identically, so every row in the fleet answers to one shape. Its
      pipeline-act remedy files a
      `pw::type:tech-debt` issue against this pipeline's own repository (the
      reader lives here, never in a target repo), never asking.
    - **`page-outlived-item`** (pipeline-act). Fires when any open issue
      carrying `enabler_escalation_label` or `pw::pager` in `pager_repo`
      links a PR or issue (the first `github.com/…/pull/<n>` or
      `github.com/…/issues/<n>` its body names) that has already gone
      terminal — merged, closed. "Or" is a union of two listings, one per
      label, merged and deduped on the issue number, because `gh issue
      list`'s own `--label "a,b"` is an *intersection* — it filters for
      issues carrying every name given — and no page ever carries both, so a
      single comma-joined listing would be empty in every real case and leave
      this invariant permanently clear. The one documented exception to "pure
      over replicated facts": an issue's own live state is the fact in question,
      so its EVAL_FN reads GitHub directly, through
      `PAGER_EVAL_REPO`/`PAGER_EVAL_ESCALATION_LABEL`, plain shell variables
      `pager_evaluate` sets before calling it — deliberately not threaded
      through EVAL_FN's own two-argument contract, so an ordinary invariant's
      signature never has to know these exist. Its pipeline-act remedy closes
      every outlived page it finds, generalising #1215's
      `approver_escalation_retire` from the single adjudication page to
      every page this framework or the Enabler files.

    Issue #1282 (part 3c of #1126's own findings) adds five more —
    **fleet liveness from a peer's vantage**, the class where every signal a
    node emitted was one it also consumed, so only another node evaluating
    it can catch the gap. All five are `owner-only`: none has a fix a
    pipeline could perform on its own behalf, unlike `verdict-unanimous`'s
    tech-debt filing. `pager_register` gains a fifth, optional argument,
    `MIN_FIRING_MINUTES_OVERRIDE` — when non-empty, `_pager_evaluate_one`
    uses it instead of `pager_evaluate`'s own `MIN_FIRING_MINUTES` for that
    key alone (`lib/pager.sh`'s `PAGER_MIN_FIRING_MINUTES_OVERRIDE`), and an
    omitted one (every call site before #1282) falls through unchanged.
    `pager_evaluate` also gains five trailing, optional parameters —
    `CYCLE_INTERVAL_MINUTES`, `NODE_STALE_AFTER_MINUTES`,
    `UPDATER_STUCK_AFTER_MINUTES`, `DASHBOARD_FETCH_SECONDS`,
    `REVIEW_UNION_LOG_FILE` — which `_pager_evaluate_one` sets as
    `PAGER_EVAL_CYCLE_INTERVAL_MINUTES` and four siblings, the identical
    plain-variable exception `PAGER_EVAL_REPO` already established: none of
    these thresholds (or, for `review-pipeline-failing`, the review-log
    union path) is a fact either of EVAL_FN's own two arguments carries, an
    omitted one is empty, and every EVAL_FN below treats an empty threshold
    as "never fire" rather than guessing at a default.

    - **`firing-missed`** (owner-only). Fires when an *active* node's newest
      evidence of its scheduler firing — a `cycle-start` or a `cycle-skipped`
      (the implementation union log; `acquire_lock` logs `cycle-skipped` only
      when it found the lock held by another live pid, itself proof the
      scheduler ticked on schedule and deferred correctly) — is older than 2×
      `schedule.cycle_interval_minutes` while it holds no lock — the
      signature of supercronic dropping a firing outright (#1287 records the
      gap from the inside: no `cycle-start`, no `cycle-skipped`, nothing in
      `log.jsonl` at all), as distinct from a cycle that is simply still
      running, or a long cycle whose scheduler keeps ticking (and skipping)
      around it. The nodes judged are the *cycling* ones: the row's
      heartbeat is fresh **and** its published `role` is not a standby's.
      Freshness alone is not enough, and the role is compared normalised —
      lowercased, whitespace stripped, requirement 2.4's own reading, since
      `AGENT_OPS_ROLE=Active` runs unattended cycles and must not read as a
      standby to a peer. Both publishers of that field normalise it before
      it travels (requirement 2.5), so the comparison is over a value the
      fleet agrees on; a node running an image older than that still has its
      raw value read the same way here. A standby is exempt outright, not
      given a wider window: requirement 2.4 makes a standby tick exit before
      the lock, the log and the cycle directory, so it writes neither a
      `cycle-start` nor a `cycle-skipped`, the union log carries no evidence
      of its scheduler in either direction, and the newest cycle event it
      holds for that node is from before the node was demoted — any finite
      multiple of the interval would eventually page on it (#1686: ockham-2,
      whose last cycle ran on 2026-09-16, was paged repeatedly over the
      following days, #1768 at 7,970 minutes).

      The exemption's cost is stated rather than hidden: a standby whose
      scheduler alone has stopped is invisible to this invariant until it is
      promoted, and `node-stale` does not cover it — that reads the
      heartbeat, which `scripts/state-sync.sh push` writes from its own
      crontab line, so a node that has lost its `agent-cycle.sh` line and
      nothing else keeps publishing and looks healthy. Closing that gap
      means giving a standby tick a trace to be judged by, which moves
      requirement 2.4's own ordering; #1788 carries it.

      A row whose `role` is absent, empty or `unknown` is judged exactly as
      it was before #1686: the exemption asks for positive evidence that a
      node is standing by, and `unknown` — what `scripts/publish-dashboard.sh`
      writes for a peer whose heartbeat carries no role, and what either
      publisher writes for a process that was handed none — is not a node
      saying so. This is the one place the fleet's record and requirement
      2.4's guard resolve silence in opposite directions, and deliberately:
      the guard answers "may this node spend?", where silence must mean no;
      the record answers "what is this node running as?", where silence must
      mean nothing at all, because a `standby` invented from an unset
      variable would retire a real page (requirement 2.5).

      Promotion is the edge a role alone cannot see. A node whose role turns
      `active` has a newest cycle event as old as its demotion, so the fact
      is true the instant the promotion publishes and stays true until the
      node's first tick, which is up to a whole interval away. Nothing is
      *filed* on it: this key registers a per-key filing window of
      `schedule.cycle_interval_minutes` plus fifteen minutes for
      replication (`MIN_FIRING_MINUTES_OVERRIDE`, the same mechanism
      `node-stale` uses), so the promoted node's first `cycle-start` clears
      the candidate before a page is written, while a scheduler that has
      really dropped a firing holds the fact across the window and is filed
      as before. Demotion is the mirror image: demoting a node the fleet was
      paging for closes its page as cleared, because the fleet has stopped
      expecting cycles from it — the evidence stays in the closed issue, and
      #1788 is what would let the fault go on being noticed.

      `lock.json` is never published (`scripts/state-sync.sh`
      excludes it), so "holds no lock" is derived purely from the union log:
      a node's own newest cycle-start/cycle-end/cycle-skipped event being a
      `cycle-start` means that cycle has not yet ended, so a long
      *legitimate* cycle is never mistaken for a missed one. Staleness itself
      is measured from the newer of the node's last `cycle-start` and last
      `cycle-skipped`, not from `cycle-start` alone, so a cycle that outlasts
      2× the interval while its scheduler keeps ticking (and correctly
      skipping, because the earlier cycle still holds the lock) never crosses
      the age threshold either — only silence on both counts does (#1312's
      review of #1282 caught a trailing `cycle-skipped` inverting "holds no
      lock" into a false positive; the fixture at
      `test/pager-invariants.test.sh`'s `n5` reproduces and covers it).
      `schedule.cycle_interval_minutes` is fleet-wide config, identical on
      every node that reads it including the evaluating one, so no peer-
      specific threshold needs to travel at all. The threshold is that bare
      interval, **not** requirement 1d's worst-case gap: an installation
      that restricts `schedule.cycle_hours` or `schedule.excluded_minutes`
      goes longer between firings than twice the interval by design, and
      this invariant would read the quiet stretch as a dropped firing. The
      shipped configuration restricts neither, where the two quantities
      coincide; #1314 carries the derivation, which needs `cadence_gaps`
      (requirement 1b) to surface a gap it currently only consumes.
      Evidence carries each
      firing node's own recent cycle-duration histogram (up to five
      completed cycles, matched by the `cycle` id every start/end pair
      shares) — the acceptance's own "file, with the node's cycle-duration
      histogram".
    - **`node-stale`** (owner-only). Fires when a node's `heartbeat_age_s`
      (`fleet_publication_status`, requirement 2.5, carried by every row
      including this node's own) exceeds 2× `node_stale_after_minutes` —
      past the dashboard's own `.stale` badge (1×) and into the 2026-08-08
      both-laptop-nodes signature, four days nobody was looking at a page
      nobody had. Files only after `pager_stale_file_after_minutes`
      (default 180 min), its own `MIN_FIRING_MINUTES_OVERRIDE`: the
      underlying fact is already slow-forming, so filing waits far longer
      than the framework's blip-sized default. Once #1279's notification
      channel lands, this class of page reaches it automatically
      (`notify_events`' own default already names `pager`) — today it is
      filed only.
    - **`updater-stuck`** (owner-only). Fires when any *live* node's
      `updater.status == "stuck"` for over 2× `updater_stuck_after_minutes`
      — live, meaning a fresh heartbeat, whatever the node's role: the
      updater runs from a crontab line of its own on every node, and a
      standby whose image has stopped rolling is a standby that cannot
      safely be promoted.
      `.updater.seconds` (`lib/updater-health.sh`'s `updater_status`) already
      carries the streak's own elapsed time, recomputed fresh on every
      heartbeat write, so this reads it directly rather than re-deriving an
      age from the union log the way `firing-missed` has to for a fact that
      is never published at all.
    - **`review-pipeline-failing`** (owner-only). Fires when any node's
      streak of failed review *runs* (`review-log.jsonl`, fleet-replicated
      like `log.jsonl` — `scripts/state-sync.sh` does not exclude it)
      reaches 3 with no completed review between. A run — grouped by the
      `review` id `review-cycle.sh`'s own `log_event` stamps on every line —
      rather than a bare event, because `review-end` is written by that
      script's `cleanup()` EXIT trap on *every* run whatever happened, and
      both of its ordinary `review-attempt-failed` sites return success, so
      a run that just failed still reports `review-end` with `exit_code: 0`;
      a reader resetting on that would reset on the very run it was counting
      and could never reach 3 at one repository per run. So, per run: any
      `review-attempt-failed` increments; none, plus a `review-stage-end`,
      resets; neither — a stand-down, a skip, nothing due — leaves the streak
      untouched, since such a run carries no information about the pipeline's
      health in either direction. That last case is the indistinguishability
      agent-ops#996 names, refused here rather than guessed at. 3 is not schema-backed,
      mirroring `lib/stage-health.sh`'s own un-schema-backed `THRESHOLD`
      default for the identical reason it states: this class has not yet
      seen a real incident to tune the number against. (`stage_health_
      verdicts` itself counts non-zero `stage-end` events and never counts
      `attempt-failed` toward its streak — the threshold is shared, the
      reduction is this invariant's own, because the two pipelines record
      a failed attempt differently.) **This invariant is the fleet-vantage
      reader of the same fact `docs/spec/review.md` R19 publishes
      per node as `review_stage_health` (agent-ops#996): R19 states the
      verdict where a human or the dashboard can read it, this invariant
      reduces the fleet's replicated `review-log.jsonl` union and files a
      page when nobody is reading** — the two are complementary rather than
      redundant, and its evidence names the verdict it is the alarm for.
    - **`dashboard-unreadable`** (owner-only). Fires when a row's
      `dashboard_fetch: {seconds, parsed}` field — a fact no node can
      observe about itself — names a fetch slower than
      `pager_dashboard_fetch_seconds` (default 30 s) or one that failed to
      parse. This field is the contract #1283's own viewer-vantage probe is
      expected to fold into `fleet_nodes_json` the same way `doctor` was
      folded in for `verdict-unanimous` (#1278); until #1283 lands and
      populates it, every row's `dashboard_fetch` is absent and this
      invariant never fires — the same null-until-populated convention
      `doctor`/`updater`/`stage_health` already use for a peer row built
      from a heartbeat that predates the check, never a false negative from
      a producer that does not exist yet.

    Configuration for the five: `pager_stale_file_after_minutes` (default
    180 min, `node-stale`'s own filing-hysteresis override) and
    `pager_dashboard_fetch_seconds` (default 30 s, `dashboard-unreadable`'s
    fetch-time tolerance) are new; `firing-missed`, `updater-stuck` and
    `review-pipeline-failing` reuse `schedule.cycle_interval_minutes`,
    `updater_stuck_after_minutes` and a fixed, un-schema-backed 3
    respectively, needing no key of their own.

    Issue #1281 (part 3b of #1126's own findings) adds seven more — the
    **selection and ledger** class: the fleet-wide starvation/wedging class
    of #1128/#1136/#1163/#1165, this time read from the Co-Ordinator's own
    selection/fit machinery and from the block/escalation ledger rather than
    a peer's liveness signals. `pager_evaluate` gains three more trailing,
    optional parameters — `IDLE_CYCLES`, `REPAIR_RATE_PERCENT`,
    `ESCALATION_BURST` — set as `PAGER_EVAL_IDLE_CYCLES` and two siblings, the
    identical plain-variable exception `PAGER_EVAL_REPO`/`PAGER_EVAL_CYCLE_
    INTERVAL_MINUTES` already established. `pager_file` additionally sets
    `PAGER_REMEDY_LOG_FILE`, `PAGER_REMEDY_UNION_LOG_FILE`, `PAGER_REMEDY_
    NODE` and `PAGER_REMEDY_CYCLE` before calling a pipeline-act REMEDY_ARG —
    the identical documented exception as `PAGER_REMEDY_REPO`, needed here
    because `blocked-label-orphaned`, `claim-unreconciled` and
    `digest-truncated`'s own remedies re-derive their candidate set from the
    union log or log a new union-log event of their own, neither of which
    `REMEDY_ARG KEY EVIDENCE`'s own two-argument contract carries.

    - **`idle-with-demand`** (owner-only). Fires when a *cycling* node's
      (`firing-missed`'s own reading: a fresh heartbeat and a published
      `role` that is not a standby's) last `pager_idle_cycles` (default 6)
      *cycles* all ended in state
      `idle-with-demand` (D21, `lib/node-time-state.sh`) with a cause other
      than `back-pressure` — a deliberate throttle, not a
      symptom, and the one exclusion the issue's own list (usage-limit,
      disk/memory, unauthorized, a fleet/kill-switch's own `down`,
      back-pressure) names that the D21 state vocabulary does not already
      separate into a different state on its own: every other named
      exclusion already logs `externally-blocked` or `down` instead of
      `idle-with-demand`. A cycle is read from its own *last* `node-state`
      event, grouped by the `cycle` id every one of them carries, because
      `node-state` is emitted several times per cycle — `overhead`
      unconditionally at the top of every cycle that takes the lock, and one
      transition per `stage-start` — so only `finalize_node_state_for_cycle`,
      logged once at the very end of `cleanup`, says how a cycle *ended*; a
      window over raw events would demand a run of consecutive
      `idle-with-demand` events no cycling node can produce, and would never
      fire at all. A tick that skipped contributes nothing (a
      `cycle-skipped` calls `suppress_node_state_transitions` and logs no
      `node-state`), which is the wanted answer: deferring to a cycle already
      running is not a cycle that ended idle. The role test is #1686's, for
      the same fault one invariant along and in a sharper form: a node
      demoted mid-streak keeps publishing a fresh heartbeat while
      requirement 2.4 stops its ticks, and where `firing-missed` needs time
      to pass before its window is wrong, this one needs none — no further
      cycle will ever break the streak its last cycles left behind.
      Fewer than `pager_idle_cycles`
      cycles for a node
      decides nothing — "last N cycles" cannot be confirmed from an
      incomplete window. Caught: the 2026-09-04 fleet-wide stand-down
      (#1163/#1165) and the 2026-08-31 starvation (#1128). Evidence embeds
      the node's own most recent `none-selected.reason` and
      `coordinator-input-fitted` detail — the two facts a diagnosis starts
      from, per the issue's own acceptance — though neither is load-bearing
      for the firing decision itself.
    - **`fit-ladder-pinned`** (owner-only). Fires when a node's
      `coordinator-input-fitted` events (`lib/coordinator-input.sh`,
      `agent-cycle.sh`) in the trailing 24h have all run out of prose to shed
      and are dropping whole entries — rung 11 or tighter, the first of the 10
      entry caps that follow the 10 prose tiers (`COORDINATOR_INPUT_TIERS` +
      1, a fixed constant of the ladder rather than a field either array
      carries) — with `entries_dropped > 0`. A node with no fitted cycle at
      all in the window contributes nothing. The segment, not its last
      notch: #1128/#1136's own evidence is `poetic-1` pinned at the
      *loosest* entry cap (rung 9 of the eight-tier ladder of the day)
      dropping 48–68 entries in 149 of 150 fitted cycles since 2026-09-04,
      so a test for the last notch alone would miss the incident this
      invariant is built from. The two clauses nearly coincide by
      construction: `coordinator_apply_rung`'s own entry cap is a no-op
      while it is null, which is every prose rung, so `entries_dropped > 0`
      is unreachable above rung 11 — the rung floor states in the ladder's
      own vocabulary what the drop count would otherwise leave implied. A
      node whose every fitted cycle sits on the identity-only rung 10
      dropping nothing — the ordinary shape agent-ops#1379 made of a
      ~300-entry backlog — is not pinned.
    - **`work-order-repaired-rate`** (owner-only). Fires when the fleet-wide
      count of `work-order-repaired` events (`agent-cycle.sh`, #821 — a work
      order composed from trimmed input) in the trailing 24h exceeds
      `pager_repair_rate_percent` (default 20) percent of that same
      window's `selection` count. A window with zero selections decides
      nothing. **Retire this invariant once #769's part (b) lands and #1156
      removes the gate this rate reads** — the issue's own instruction,
      recorded here since a requirement, unlike an issue comment, is what
      this repository's own conventions treat as the durable copy.
    - **`blocked-label-orphaned`** (pipeline-act). Fires when a live
      `blocked:needs-refinement`/`blocked` label carries no open block
      behind it — either `lib/refinement.sh`'s own `own-label-action`
      history shows an `add` with no later `remove`
      (`refinement_blocked_label_stale`, pure over the union log), or a live
      GitHub read (scoped to every repo this pipeline's own history has ever
      applied the `needs-refinement` block kind or a `blocked`/`blocked:
      <reason>` label to, never an arbitrary configured-repo list) finds one
      history alone cannot prove ours (`refinement_blocked_label_orphaned`,
      requirement 38b, #816). Caught: #816 — twelve issues unselectable for
      five days after being unblocked. The remedy calls the identical
      `refinement_label_remove`/`label_own_action_fields` requirement 38b's
      own release path already uses, never a reimplementation, logging
      `own-label-action` on success; a removal that succeeds clears on this
      invariant's own next evaluation (the label is gone), so only a
      removal that keeps failing stays filed — "the invariant files only if
      the removal fails," in a framework that always records a pipeline-act
      attempt (this requirement's own remedy-class table).
    - **`claim-unreconciled`** (pipeline-act). Fires when an
      `enabler-examined` event whose `outcome` is the Enabler's own escalate
      verdict (`lib/enabler.sh`: `outcome="$verdict"`, never reassigned on
      the path that actually files) *in the trailing 24h* carries no
      `escalated`/`tech-debt-filed`
      event for the same repo, item and cycle. Caught: #815 — #640 sat
      blocked five days on a claim an adjudication pass had cancelled; this
      invariant catches the same signature recurring by a different route (a
      crash between the claim and its own reconciliation, or an engagement
      that never reached it). The remedy re-checks live — never parsing
      EVIDENCE's own prose, on `pager_remedy_page_outlived_item`'s own
      terms — and, for any claim still unreconciled, posts one correction
      comment on the item's own thread, mirroring (never calling —
      `escalation_thread_reconcile` reads cycle-scoped globals this
      framework's process does not have, this requirement's own header)
      the #815 correction-comment pattern, over the identical window its own
      EVAL_FN read. Both are windowed, and a ledger reader has to be:
      `log.jsonl` is never rotated, so an unwindowed reading would fire on
      #815's own original incident — still in this fleet's history — could
      never *clear* (a fact derived from immutable history stays true for
      ever, so `pager_close` would never run), and would comment on items
      settled months ago.
    - **`escalation-burst`** (owner-only). Fires when the fleet-wide count
      of `escalated` events in the trailing 24h exceeds
      `pager_escalation_burst` (default 10), or the same re-flag reason —
      the triggering `attempt-failed`'s own `detail`/`unblock_condition`,
      fingerprinted with `escalation_autonomy_decide_reason_key`
      (`lib/escalation-autonomy.sh`, requirement 36d's own per-reason bound,
      reused rather than duplicated) — pages the same item twice inside that
      same 24h, regardless
      of the count threshold. Both halves are windowed, the re-flag half for
      `claim-unreconciled`'s own reason (an unrotated union log would leave
      the 2026-08-28 burst below firing this for ever, unclearably) and
      because the window bounds the per-escalation fingerprinting this half
      performs on a path that runs every five minutes. The `attempt-failed`
      half is not windowed: it is read only to name the reason behind an
      escalation already inside the window, and the re-flag it names may be
      a little older than the page it caused. Caught: 2026-08-28 (#933–#938;
      55% mechanical, from three unfixed bugs). Evidence carries the reason
      histogram.
    - **`digest-truncated`** (pipeline-act). Fires when a repo's most recent
      `source-state-digest` event (`lib/candidate-gather.sh`, logged
      alongside `gather_source_state`'s own already-fetched counts — no
      extra `gh` call on that cheap per-cycle path) still claiming `ok:
      true` undercounts a live total this invariant fetches itself via
      GitHub's search API, once per evaluation window rather than once per
      node per cycle. That live query carries a `created:<=<ts>` qualifier
      bound to the matched digest event's own `ts` (every `log_event` write
      already carries one), rather than reading an unbounded "right now"
      total — without the bound, a repo that creates issues/PRs quickly
      (this pipeline's own traffic, several per cycle) under-reads its own
      live total against a digest only a few minutes old, which is drift,
      not truncation (#1348). Caught: #1165 — requirement 34i read absence-
      from-digest as "closed" and false-cleared every block older than the
      newest hundred; #1165 already fixed the root cause
      (`api_json_paged`'s own full pagination in `scripts/gather-source-
      state.sh`), so this invariant is a regression watchdog for the same
      signature recurring. The remedy logs a `digest-truncation-veto` event
      for the affected repo(s) (parsed from EVIDENCE's own repo tokens);
      `lib/candidate-gather.sh` checks for one still active (within a
      trailing 24h) immediately after its own `gather_source_state` call
      and forces that cycle's digest `ok: false` when it finds one, so
      `work_gone_clearances`'s own `ok == true` gate — "unknown decides
      nothing" — refuses to act on that repo's absence for the vetoed
      cycle, exactly the issue's own remedy text ("refuse to act on absence
      for that cycle, then file").

    Configuration for the seven: `pager_idle_cycles` (default 6),
    `pager_repair_rate_percent` (default 20) and `pager_escalation_burst`
    (default 10) are new; `blocked-label-orphaned`, `claim-unreconciled` and
    `digest-truncated` read no new configuration of their own, only the
    union log and (for the latter two) a live GitHub read.

    Issue #1280 (part 3a of #1126's own findings) adds three more —
    **landing and approval**: the class where a pull request sits ready, or a
    whole repository stops landing, with nothing any existing invariant reads
    catching it, because the facts live in the Landing Gate's own refusal
    path (`lib/landing.sh`) and the Approver's own unreviewed-trigger memory
    (requirement 46) rather than a node's liveness or the Co-Ordinator's own
    selection machinery. `pager_evaluate` gains four more trailing, optional
    parameters — `REPOS_JSON`, `PR_LABEL`,
    `APPROVER_UNREVIEWED_ENGAGE_AFTER_HOURS`, `LANDING_ARMED_WITHIN_DAYS` —
    set as `PAGER_EVAL_REPOS_JSON` and three siblings, the identical
    plain-variable exception `PAGER_EVAL_REPO`/`PAGER_EVAL_CYCLE_INTERVAL_
    MINUTES` already established. `PAGER_EVAL_REPOS_JSON` carries each
    configured repository's own *configured* `merge_autonomy` level (a
    repository's own override, else the fleet-wide default) — never the live
    effective level, the identical D18 WI-6 approximation `config_json`'s own
    back-pressure card already makes, since a per-repository merge-budget-
    freeze read is a cost neither this invariant nor that card pays on every
    evaluation.

    - **`landing-never-armed`** (pipeline-act). Fires when a repository
      configured at merge_autonomy `agent-merges-routine` or above logged at
      least one `landing-refused` event in the trailing
      `pager_landing_armed_within_days` (default 7) window but no
      `landing-armed` event in that same window. Caught: #718 — agent-ops sat
      at `agent-merges-routine` from 2026-08-18 with 115 `landing-refused`
      and zero armings for six days, because `landing_protected_paths_hit`'s
      `gh api … -F` POSTed and 404'd on every call. The `landing-refused`
      gate is deliberate, never "no `landing-armed` event" alone: a
      repository with nothing ready to land in the window is not this
      incident, and would otherwise fire on every quiet repository at this
      level, forever. Evidence embeds each firing repository's own
      refusal-class histogram (`reason`'s own `<class>:<detail>` vocabulary,
      split on the first colon) — the fact a diagnosis starts from. The
      pipeline-act remedy files a `pw::type:tech-debt` issue against this
      pipeline's own repository (the reader, `lib/landing.sh`, lives here,
      never in a target repo), naming the histogram, on
      `verdict-unanimous`'s own terms.
    - **`landing-refused-unknown`** (pipeline-act). Fires when
      `landing-refused` events of class `unknown` (`lib/landing.sh`'s own
      `unknown:<reason>` vocabulary — the fail-closed answer
      `landing_eligible`/`landing_protected_path_controls_ok` give when a
      live GitHub read could not even be attempted, never a deterministic
      `ineligible`) make up at least half of a trailing-24h window's
      `landing-refused` events, fleet-wide, with at least five. Caught: the
      same #718 incident (72 of 115). The fraction and the floor are fixed,
      un-schema-backed constants, `review-pipeline-failing`'s own precedent
      above, for the identical reason it states: this class has not yet seen
      a second incident to tune them against. The pipeline-act remedy files
      a `pw::type:tech-debt` issue on the identical terms
      `landing-never-armed`'s own remedy uses — the two invariants share one
      root cause class, and often fire together for the same incident.
    - **`pr-unreviewed`** (pipeline-act). Fires when at least one ready,
      non-draft, `pr_label` pull request, older than
      `approver_unreviewed_engage_after_hours` (requirement 46's own cutoff,
      reused rather than duplicated), carries no standing review at all
      (GitHub's own `reviewDecision`, read once per candidate repository's
      own `gh pr list` call — a superset of "no standing *App* review"
      specific enough in practice, since a third party reviewing an
      autonomous pipeline's own pull request ahead of the Approver is not the
      ordinary case this invariant needs to rule out, and costs no further
      per-pull-request API call the way a live per-pull-request read would),
      no `approver-verdict`, no warning naming it and no
      `approver-unreviewed-engaged` event *at all* — never merely stale, the
      total silence of requirement 46's own unreviewed trigger (#890) never
      having run for this pull request even once. A cutoff that fails to
      produce a usable value — a schema-illegal
      `approver_unreviewed_engage_after_hours` (e.g. `"2h"`), rejected by
      `_pager_pr_unreviewed_candidates`'s own upstream numeric-format guard
      before it ever reaches `_pager_ready_pr_candidates`, or a schema-legal
      but extreme one that reaches `_pager_ready_pr_candidates` and overflows
      `strftime` there — logs its own `warning` either way (naming
      `approver_unreviewed_engage_after_hours`, the raw value and whichever
      of the two functions rejected it) and never fires, rather than being
      silently indistinguishable from an empty backlog. Of the two, only the
      second is reachable from the pipeline's own evaluation site:
      `scripts/publish-dashboard.sh` substitutes the schema default (`2`) for
      a configured value failing that same numeric-format regex before it
      passes one at all, so the guard in `_pager_pr_unreviewed_candidates`
      states the function's own contract for a caller that passes the
      configured value through unchanged, and a schema-illegal key evaluates
      this invariant at the substituted default rather than disabling it.
      Caught: PR #1059, stranded
      when the kill-switch read failed closed with no log line (#1081) —
      exactly the silent skip this invariant is built to notice from outside
      the sweep that skipped. The pipeline-act remedy logs the identical
      `approver-unreviewed-engaged` event requirement 46's own sweep would
      (`result: "unavailable"`, truthful — this framework has no clone or
      model credential with which to post a real review itself, the
      host-independence this issue's own compatibility note requires) for
      every candidate found. Logging it is the "enqueue" half of the issue's
      own remedy text: it starts the escalate clock
      `_approver_restale_sweep_repo` reads
      (`approver_unreviewed_prior_engagement`) for a pull request that clock
      had never started for at all, so the very next ordinary sweep — any
      node, its own next cycle, needing no signal from here to run — either
      posts a real review or, once `approver_restale_escalate_after_hours`
      passes from this logged engagement, escalates to `enabler_assignee`
      itself: the "file if a second window passes" half of the issue's own
      remedy text, performed by the sweep this remedy hands the baton to
      rather than reimplemented here.

    Configuration for the three: `pager_landing_armed_within_days` (default
    7 days) is new; `landing-refused-unknown` reads no new configuration of
    its own (fixed constants only); `pr-unreviewed` reuses `pr_label` and
    `approver_unreviewed_engage_after_hours`, needing no key of their own.
    All three read the union log and the forge alone — never a clone, never a
    host — the compatibility this issue's own acceptance names for the
    orchestrated-container target.

    `docs/spec/dashboard/publisher.md`'s "The Publisher" section documents the
    evaluation site and the `WITH_GITHUB`-not-merely-`FULL` gate; its own
    page-rendering section documents the `pager-firing` banner and node-card
    badge this requirement's `nodes` field feeds.

53. **Landing-refusal pre-fetch (issue #979).** Requirement 8d gate 4
    (`_landing_stage_attempt`, `lib/landing.sh`) refuses to arm a pull request
    over an unreconciled human comment (`reconciliation-unanswered:`) or an
    unreadable comment-reconciliation read (`reconciliation-unreadable:`) —
    correctly, since it is the human veto D18 promises — but that refusal by
    itself is a dead end: `scripts/gather-review-feedback.sh`'s own candidate
    rule cannot see it (no formal `CHANGES_REQUESTED`, no draft flip), and
    `scripts/gather-abandoned-drafts.sh` only ever sees drafts, while the
    pull request stays Ready. Before this requirement, the only trace was one
    `landing-refused` log line per cycle that nothing read back into work, and
    `scripts/sweep-human-visibility.sh`'s own idle nudge (requirement 38c)
    told the assignee the pull request "is waiting on a merge click" — true of
    every other approved, green, mergeable pull request, false of this one.

    `scripts/gather-landing-refusals.sh` (`gather_landing_refusals`,
    `lib/candidate-select.sh`) is the route back: for a repo whose `sources`
    lists `landing-refusals`, it lists that repo's own open, non-draft
    `pr_label` pull requests and, for each, reads the *fleet-wide* union log's
    most recent `landing-refused` event for that pull request
    (`lib/landing.sh`'s `landing_latest_refusal_reason`, the same `LOG_FILE`
    convention `landing_retry_tier` already established — a peer node's own
    cycle may have logged the refusal this node must still see). A pull
    request is a candidate iff that event's `reason` begins
    `reconciliation-unanswered:` or `reconciliation-unreadable:` *and*
    `lib/reconciliation-gate.sh`'s own `reconciliation_unreconciled_comments`
    (unbounded, the identical call gate 4 itself makes), asked fresh right
    now, still reports at least one unreconciled human comment — the
    "answered clause" every finishing source needs (`scripts/gather-
    dequeued.sh`'s own header), since the old log event never disappears once
    the Implementer's `<!-- agent-ops:reconciles comment=<id> -->` reply
    clears it. Reading the *logged refusal* rather than recomputing gate 4's
    own reconciliation check independently is deliberate: gate 4 only ever
    reaches that check once every gate before it — approval, no formal
    `CHANGES_REQUESTED`, a green required-check list — has already passed, so
    this source stays complementary to `review-feedback` rather than
    duplicating it for a pull request review-feedback already covers for a
    different reason.

    `_reconciliation_gate_comments` (`lib/reconciliation-gate.sh`) carries a
    `who` field (the comment author's login) alongside its existing
    `id`/`at`/`body`/`bot` fields, and `_reconciliation_gate_unreconciled`
    factors the "unreconciled" test `reconciliation_gate` itself reports as
    `dirty` into its own function, returning `{id, at, author, body}` per
    unreconciled comment (requirement 34a: one definition per rule) — the
    structured shape `reconciliation_unreconciled_comments` (a new public
    entry point, unbounded NOT_AFTER) exposes for a caller needing the
    comment's own text rather than a permalink string. `reconciliation_gate`
    itself is unchanged in every observable respect: it calls the same shared
    helper internally and still reports `clean`/`dirty<TAB>reason`/
    `unknown<TAB>reason` exactly as before.

    The candidate ref is `pr-<n>-landing-refusal-<ids>`, where `<ids>` is the
    sorted, hyphen-joined set of currently-unreconciled comment ids — not the
    pull request alone — on the same "an item recorded blocked stays blocked
    until something clears it" reasoning every sibling finishing source's own
    scoped ref follows (`scripts/gather-dequeued.sh`'s header): answering one
    comment, or a fresh comment arriving, changes the set and mints a
    candidate no old block or void covers, while an unchanged set keeps the
    same ref and stays correctly blocked or claimed. The candidate carries
    `refused_at`/`reason` (the logged event), `comments` (the structured
    array) and `body` (every unreconciled comment rendered verbatim, oldest
    first, the way `gather-review-feedback.sh` assembles review text) — the
    Implementer's brief is the comment prose itself, never a summary of it.

    Wired into the ordinary pre-fetch machinery exactly as `review-feedback`/
    `merge-conflicts`/`dequeued` are: gated on `sources` naming
    `landing-refusals`, folded into the "expensive" per-cycle band (`lib/
    expensive-gather-cache.sh`) alongside its eight siblings, `emit_first_seen`
    and claim exclusion (`exclude_claimed_prs`/`exclude_claimed_items`)
    applied identically, and carried on the Co-Ordinator's own runtime input
    as each repo entry's `landing_refusals` array. The selection side is
    wired to match, band for band, with the same six lists every other
    pre-fetched source appears in: requirement 3c/3u's blocked-and-void
    second pass (`lib/eligibility.sh`'s own band loop), requirement 3x's
    eligible-set denominator (`coordinator_eligible_items`), requirement 17h's
    compose (`CANDIDATE_ENTRY_LOOKUP_JQ`/`CANDIDATE_TEMPLATE_JQ`, whose
    `acceptance` for this source is to answer every unreconciled comment and
    cite each with its own `<!-- agent-ops:reconciles comment=<id> -->` line),
    requirement 3v's deterministic fallback (`fallback_select_candidate`,
    ranked immediately after `dequeued`), and requirement 39a's own Refiner
    candidate walk (`refiner_candidate_items`, `lib/refinement.sh`), which
    reaches this band like any other so a `refinement_policy` set for it can
    actually be satisfied — and
    `PREFLIGHT_EXISTING_BRANCH_SOURCES` (requirement 34m), which this source
    joins as a fifth member because its branch and pull request predate the
    claim — and, for the same reason and necessarily together with it,
    requirement 17's own claim dispatch (`agent-cycle.sh`), where this source
    takes the *file* claim keyed on its item ref and the PR-keyed `pr-<n>`
    claim beside it, never a branch claim: a branch claim here would mint
    `agent/pr-<n>-landing-refusal-<ids>` fresh off the default branch and
    overwrite the candidate's own `branch` with it, so the Implementer would
    push to a branch the refused pull request does not track and the
    `<!-- agent-ops:reconciles comment=<id> -->` line that clears gate 4 would
    never reach it. Two more inputs outside that six-list set also carry
    `landing_refusals`, for reasons requirement 3b and 34k's own text already
    give in general: `lib/noop-skip.sh`'s no-op fingerprint (requirement 3b)
    hashes it verbatim, on the identical reasoning `dequeued` already
    established there — gate 4's own refusal moves nothing else the
    fingerprint samples, so leaving this source out of it would be the exact
    silent stall that file's own header warns against, for the one source
    whose entire purpose is giving a refusal a route back to work; and
    `scripts/close-void-github-items.sh`'s pull-request-close exclusion
    (requirement 34k) treats `pr-<n>-landing-refusal-<ids>` exactly as it
    treats `-conflict-`/`-dequeued-`, since a landing-refusals void makes the
    identical claim (the refusal is gone, not the pull request). Deliberately
    **not**
    folded into requirement 2.2a's four-source back-pressure/drain finishing
    set, nor into the claim-pattern and void-corroboration parity the other
    four finishing sources share (`lib/drain.sh`, `lib/claim.sh`, `lib/void-
    guard.sh`) — extending those is a separate policy question (whether this
    source alone should keep back-pressure from tripping, or a drain from
    reaching rest) this issue's own refined scope did not ask for, tracked
    instead as its own deferred item.

    `scripts/sweep-human-visibility.sh`'s idle nudge (requirement 38c) takes
    an optional fourth argument, the fleet-wide union log; when a pull
    request's most recent `landing-refused` event reads
    `reconciliation-unanswered:`/`reconciliation-unreadable:` and a fresh
    live check still confirms at least one unreconciled comment, the nudge
    names that reason instead of "waiting on a merge click" — the same
    marker-based once-per-state suppression as before, `<!-- agent-ops:human-nudge
    -->`, so the fix changes the wording a human sees, not how often they see it.
    `lib/standdown.sh`'s own call site passes `union_log` alongside the
    existing `cycle_id`/`node_name` arguments.

55. **Resource usage and budgets, self-measured (D14, issue #606).** #755
    gave every container a `mem_limit`/`cpus` ceiling (this file's own
    "Every container carries a resource ceiling" design decision, above) and
    requirement 2.0g checks the declared sum against the host, but neither
    *measures* what a container actually uses, and neither says anything
    about disk or bandwidth at all — the two budgets D14 also names that
    Compose and this kernel cannot enforce (the same design decision's own
    paragraph). This requirement is the measured, reported half: a baseline
    for all four resources, budgets stated in `config.json` rather than only
    in a compose comment, actuals published per node and per container, and
    a container or volume over budget made a reportable condition — the
    "Done when" the issue's own specification (2026-08-21, adjudicated
    adequate the same day) sets out.

    **What is measured, and from where.** `lib/resource-usage.sh` reads this
    container's own cgroup and `/proc/net/dev` directly — self-measurement,
    not the host-facts collector's Docker-socket vantage
    (`scripts/collect-host-facts.sh`, requirement 2.0g's own source): every
    container that vantage could reach either already has a `mem_limit`/
    `cpus` ceiling from #755 (the enforcement half) or is out of scope for
    self-measurement here regardless (`tailscale`/`watchtower` run no
    agent-ops script to self-measure from; `egress-proxy`/`collector`/
    `reconciler` are deferred, agent-ops#1563). In scope: `scheduler`,
    `dashboard` and `dashboard-local` — the three services that run this
    image — plus the `workspace_root`/`state_dir` volumes they mount.
    `resource_cgroup_version` reads `ROOT/cgroup.controllers` (v2) or
    `ROOT/memory/memory.usage_in_bytes` (v1) to tell the two cgroup layouts
    apart — the fleet is not uniform, one node presents v1 and its siblings
    v2 — and every read below takes that layout as an argument rather than
    assuming one, returning empty, never a fabricated `0`, off an
    `"unknown"` layout or a missing file. `resource_memory_current_bytes`
    reads `memory.current` (v2) or `memory/memory.usage_in_bytes` (v1);
    `resource_cpu_usage_nanos` reads `cpu.stat`'s `usage_usec` (v2, scaled
    to nanoseconds) or `cpuacct/cpuacct.usage` (v1, already nanoseconds) —
    both cumulative counters since the cgroup was created, never a rate by
    themselves. `resource_net_bytes` sums every non-loopback interface's
    `rx`/`tx` byte counters from `/proc/net/dev` (not namespaced away from
    this container — reading it from inside answers for this container's
    own interface, unlike `/proc/meminfo`, which requirement 2.0f's own
    header already establishes reads the *host's* figures because memory
    accounting is not namespaced the same way). `resource_disk_usage_bytes`
    is `du -sb` on a volume path.

    **Deltas, never absolutes, for CPU and bandwidth.** `resource_cpu_cores`
    and `resource_rate_per_hour` each take two samples — a value and a
    Unix-epoch timestamp, taken and cached a tick apart — and refuse to
    report a rate when the later value is smaller than the earlier one: a
    container recreation resets both counters to zero, and reporting the
    negative delta a naive subtraction would produce is worse than
    reporting nothing, the same "no evidence is not evidence" discipline
    `lib/host-budget.sh`'s own unknown-ceiling exclusion already holds.
    Memory and disk are read as instantaneous values, not deltas — a
    cgroup's `memory.current` and a volume's `du` total are already the
    figure a budget compares against, not a counter to difference.

    **The collector, its cadence, and what it writes.**
    `scripts/collect-resource-usage.sh` is one sample tick: it reads
    `AGENT_OPS_SERVICE` (or `--service`) to know which container it is
    running in, tags every sample and every disk reading with that name —
    the same key `config.json`'s `resources.containers`/`resources.volumes`
    budgets are read back under — computes this tick's `cpu_cores`/
    `net_rx_bytes_per_hour`/`net_tx_bytes_per_hour` against the previous
    tick's cached cumulative reading (`state_dir/.resource-usage-state.json`,
    one small JSON object keyed by service name), appends a sample line to
    `state_dir/.resource-samples.jsonl`, and prunes anything older than
    `resources.sample_retention_hours` (default 48) on every tick unless
    called with `--no-prune`. Disk is sampled far less often — a `du` on a
    multi-GB tree is not the cheap read a cgroup file is — throttled
    separately to `resources.disk_sample_interval_minutes` (default 60) via
    a marker in the same state file, and only for a volume this container
    actually has mounted (`-d` checked before `du`). Both files are guarded
    with `flock` (the same ledger-append idiom `lib/gh-shim.sh` already
    uses) because `state_dir` is a volume `scheduler` and `dashboard`/
    `dashboard-local` mount in common on a node running both, so two
    containers can tick inside the same window.

    Runs every `schedule.resource_sample_minutes` minutes (default 5) from
    `scheduler`'s own crontab line (`deploy/docker/crontab.tmpl`); `dashboard`/
    `dashboard-local` run no crontab at all (`serve-dashboard.sh` `exec`s the
    HTTP server as the container's own process), so that script starts a
    small background loop — gated on `AGENT_OPS_SERVICE` being set, so a
    human running it on a laptop to browse the dashboard never spawns
    one — calling the same collector on the same interval before its own
    `exec`, detached from the shell's job table so the `exec` (which
    replaces the process image, not the backgrounded job) leaves it running.
    The loop lives exactly as long as the server: `exec` keeps the shell's
    pid, so the loop polls that pid every ten seconds and exits when it is
    gone, rather than sleeping the whole interval and running for ever
    after a server killed by anything but the container stopping (six such
    orphans on poetic-2's scheduler on 2026-09-15, two per run of
    `test/dashboard-exposure.test.sh`, which starts the script inside the
    scheduler and kills it; that test now unsets `AGENT_OPS_SERVICE` for
    the spawn, since the bind address it checks has nothing to do with
    sampling).

    **The report.** `resource_budget_report` (`lib/resource-usage.sh`) is
    the pure derivation `scripts/resource-budget-report.sh` wraps for
    standalone use and `scripts/state-sync.sh`/`scripts/doctor.sh`/
    `scripts/publish-dashboard.sh` call directly: given the sample text and
    a window-start bound, it groups by `service` and by `volume`, and for
    every numeric field prints `{latest, median, p95}` (nearest-rank —
    the value at index `floor(p * (n-1))` of the sorted sample array, not
    interpolated, so a reader can point at the one real sample that
    produced the figure) for `cpu_cores`/`memory_bytes`/
    `net_rx_bytes_per_hour`/`net_tx_bytes_per_hour` per container, and
    `{latest, growth_bytes_per_day}` (a straight line between the window's
    oldest and newest disk sample — never a regression, since disk is
    sampled hourly at most and two points is the ordinary case) for
    `disk_bytes` per volume. A line that is not valid JSON, or parses to
    something other than an object, is skipped rather than failing the
    whole report, the same discipline `test/pickup-metrics.test.sh` already
    exercises for `log.jsonl`; an empty or entirely-unparseable input
    degrades to `{"containers":{},"volumes":{},"sample_count":0,
    "window_start":null}`, never a jq failure — the same "always one valid
    object" contract `lib/metering.sh`'s own `metering_fields` holds for a
    missing stage envelope.

    **Budgets, in versioned configuration.** `config.schema.json`'s
    `resources` key states them: `resources.containers.<AGENT_OPS_SERVICE>`
    (`cpu_cores`, `memory_bytes`, `bandwidth_bytes_per_hour`) and
    `resources.volumes.<name>` (`disk_bytes`), for exactly the three
    containers and two volumes this requirement measures.
    `containers.*.cpu_cores`/`containers.*.memory_bytes` default to the
    same figures `deploy/docker/compose.yaml`'s own `cpus`/`mem_limit`
    already ship (2.0/1536m for `scheduler`, 1.0/512m for `dashboard` and
    `dashboard-local`) — the read side of a budget the compose file already
    enforces, not a second enforcement path, and keeping the two in step
    across an edit is a human responsibility today (D16's own control-plane
    migration, when it comes, is what removes the duplication by generating
    both from one source). `containers.*.bandwidth_bytes_per_hour` and
    every `volumes.*.disk_bytes` are provisional: neither resource had ever
    been measured before this requirement, so both ship generously above
    what a quiet node is expected to use, meant to be tightened once
    `scripts/resource-budget-report.sh` has real fleet windows to set them
    from — a config edit, per the issue's own reinterpreted acceptance
    criterion, never a re-implementation.

    **Published per node and per container.** `scripts/state-sync.sh`
    folds `resource_budget_report`'s own output into `heartbeat.json`'s
    `resources` field, over `resources.report_window_hours` (default 24) —
    a summary, never a series, the same "latest plus the window's p95"
    shape the issue's own specification asks for and the same reasoning
    `stage_health`/`compose_reconcile` already give for what travels in a
    heartbeat versus what stays a raw local file
    (`.resource-samples.jsonl`/`.resource-usage-state.json`, both excluded
    from state-sync's replication — a raw sample is this node's own
    forensics, never a fact a peer would read). `scripts/publish-
    dashboard.sh` reads the identical field from a peer's heartbeat, and
    recomputes the identical report live for this node's own row (the same
    "self is read live, a peer is read from its heartbeat" split every
    other per-node fact on the page already holds) — `docs/spec/dashboard/publisher.md`
    documents the resulting `resource budget` badge.

    **A breach is a reportable condition.** `resource_budget_breaches`
    (`lib/resource-usage.sh`) is `scripts/doctor.sh`'s "Resource budgets"
    comparison, factored out of that section exactly as `lib/host-budget.sh`
    is factored out of its own host-budget section (requirement 2.0g) — given
    the report and the configured budgets, it prints one entry per breach
    (windowed p95 for CPU/memory/bandwidth, latest for disk, an unbudgeted
    or unmeasured resource contributing nothing) rather than a verdict, so a
    caller decides what to do with each. `doctor.sh` `warn`s one line per
    entry, naming the container or volume, the resource, the measured
    figure and the configured budget — never silent, and never only
    something a human reading a graph would notice. Skips cleanly, the same
    "no evidence, not a failure" posture requirement 2.0g's own host-budget
    section already takes on an unwritten host-facts record, when
    `.resource-samples.jsonl` does not exist yet or carries no samples
    inside the window.

    `dashboard/index.html`'s `resourcesLine` applies the identical rule —
    windowed p95 for CPU/memory/bandwidth, latest for disk, an unbudgeted or
    unmeasured resource contributing nothing — but cannot share the
    function: it is JavaScript running in a browser over the payload, with
    no route to a bash library, the same constraint every other badge on
    that page already works under. What the two genuinely share is their
    *input*, `resource_budget_report`'s own output shape, identical whether
    a row's `resources` field was recomputed live for this node or carried
    in a peer's heartbeat. The duplication is therefore real and is kept in
    step by hand: `resource_budget_breaches`'s own at/under/over-the-line
    boundary test (acceptance check 55) is what pins the rule, and a change
    to either side has to be made to both.

    **Tests.** `test/resource-usage.test.sh` covers `lib/resource-usage.sh`
    directly: the collector's arithmetic against canned cgroup v1 and v2
    fixtures and a canned `/proc/net/dev`, the delta/rate guards (a fresh
    baseline, a recreated container), the report's derivation from a
    canned sample set (latest/median/p95, disk growth, a malformed line
    skipped), the unknown-layout degradation, and `resource_budget_breaches`'s
    own comparison at, just under and just over the line — the boundary
    `scripts/doctor.sh` calls directly and `dashboard/index.html`'s
    `resourcesLine` re-states in JavaScript, pinned here so the rule both
    sides implement has one authoritative test.
    `test/collect-resource-usage.test.sh` covers the
    collector script end-to-end against fixture cgroup/proc files — two
    ticks, five minutes apart, producing the expected delta, and a
    baseline-reset on a simulated container recreation — the disk-sampling
    throttle, two services sharing one `state_dir` without clobbering each
    other's cached baseline, and the prune (`--no-prune` versus the
    default). `test/resource-budget-report.test.sh` covers the thin
    script wrapper: config-resolved `state_dir`/window versus the
    `--state-dir`/`--window-hours` overrides, and the clean empty-report
    degradation on a missing config or an unwritten samples file.
    `test/config-schema.test.sh` covers the reportable half — what
    `scripts/doctor.sh`'s own "Resource budgets" section prints over a
    breach, an all-clear, an unwritten samples file and a window with
    nothing in it — because that is where this repository's
    `doctor.sh --offline` assertions live rather than in
    `test/doctor.test.sh`, whose own header records why.

