## Requirements

### Logging and state

33. The shared log is a single JSON Lines file, `state_dir/log.jsonl`,
    appended by the Script (agents report via their final messages; the
    Script translates those into log events) and, for the one event class
    that is mined outside any cycle, by `scripts/publish-revert-rate.sh`'s
    daily pass (requirement 47's `post-merge-revert`, `cycle: null`). The
    lock in requirement 1 guarantees a single writer among cycles; the
    mining pass takes no cycle lock and can therefore append while a cycle
    is running, which is safe only because each of its appends is one
    `O_APPEND` write of one line. Events: `cycle-start`, `cycle-skipped`,
    `stand-down`, `selection`, `claim-lost`, `claim-skipped`, `none-selected`,
    `corroboration`, `stage-start`,
    `stage-end`, `pr-raised`, `pr-ready`, `attempt-failed`, `unblocked`,
    `merge-observed`,
    `recheck-clean`, `item-void`, `unvoided`, `item-refined`,
    `enabler-examined`, `refiner-examined`, `own-label-action`,
    `label-remove-failed`, `escalated`,
    `enabler-adjudication`,
    `crash-loop-escalated`, `provider-unreachable`,
    `labels-ensured`, `labels-minted`, `limit-hit`, `limit-cleared`,
    `orphan-branch-recovered`, `orphan-branch-released`,
    `issue-closed-post-merge`, `void-object-closed`, `void-retired`,
    `dependabot-rebase-requested`,
    `disabled`, `enabled`,
    `merge-autonomy-killed`, `merge-autonomy-restored`,
    `merge-budget-hold`, `merge-budget-frozen`, `merge-budget-freeze-escalated`,
    `salvage`, `chained`,
    `approver-verdict`, `approver-escalated`, `approver-escalation-retired`,
    `landing-armed`, `landing-refused`, `classifier-escape`, `landing-audit`,
    `open-question-raised`, `open-question-adjudication`, `open-question-escalated`,
    `review-gate-checks-read`, `review-gate-checks-degraded`, `first-seen`,
    `issues-excluded`, `rework`, `node-state`,
    `warning`, `cycle-end`. `rework` is requirement 47's own record, one
    entry per repetition, and `node-state` is requirement 50's own
    transition, one entry per node-state change, whose field-by-field
    contracts are `docs/FLOW-SCHEMA.md` rather than this list.
    `cycle-skipped {reason: "overlap", slot_ts, held_by, elapsed_s}` is
    requirement 11a's own overrun-slot record, one entry per schedule slot a
    cycle's own run overlapped, documented there rather than here or in
    `docs/FLOW-SCHEMA.md` (which is scoped to the rework, item-lifecycle and
    node-time-state records alone); the requirement 1 lock-contention
    `cycle-skipped` carries no `reason` at all and is unaffected.
    `classifier-escape` and `landing-audit`
    (requirement 8e, `scripts/detect-classifier-escapes.sh`) are the D18
    Stage 2 escape-audit's own two outcomes for a merged pull request the
    audit found no earlier record of auditing: `classifier-escape` is the
    loud one — recomputed eligibility disagreed with the fact that the pull
    request landed under the Approver identity — and `landing-audit` covers
    the other two outcomes, `outcome: "clean"` (recomputation agreed) and
    `outcome: "unverifiable"` (an input could not be reconstructed from the
    merged artefacts). Both carry `pr_url`, `repo`, `number`,
    `merge_commit_sha`, `source`, `complexity_recomputed`,
    `protected_paths_hit`, `protected_paths` and `reason`; `classifier-escape`
    omits `outcome` (the event name itself already says it), `landing-audit`
    keeps it so a reader of the log alone can tell `clean` from
    `unverifiable` without cross-referencing the event name.
    `label-remove-failed` (requirement 51's `blocked-label-orphaned`,
    `label_remove_failure_fields`, agent-ops#2232) is logged by that
    invariant's own remedy for a label removal `refinement_label_remove`
    reports non-zero: `repo`, `item`, `label`, `exit_code` and `stderr`
    (`gh`'s own exit code and stderr text for that attempt), so a removal
    that keeps failing can be told apart from a stale/racing read instead of
    only incrementing a failure counter.
    `merge-observed` (requirements 31d/31f/32c, `lib/merge-observed.sh`'s
    `reviewer_merge_observed`, agent-ops#916/#1062) is the completion this
    pipeline logs instead of `attempt-failed` when a subject pull request
    merges mid-stage: `repo`, `item`, `pr_url`, `stage` (`"reviewer"` for the
    Reviewer's own handoff-time read, `"reviewer-stage-start"` for its
    advisory stage-start one, `"implementer-stage-start"` for the
    Implementer's own advisory stage-start read), and `merge_sha` when
    GitHub reported one.
    `merge-budget-hold`, `merge-budget-frozen` and
    `merge-budget-freeze-escalated` (requirement 2.3c,
    `merge_budget_apply_decision`) are logged whenever gate 5 of
    `_landing_stage_attempt` (requirement 8d) reaches `merge_budget_decide`
    and the decision is not `arm` — from `run_landing_stage`'s own round and
    from the requirement 8u landing-retry sweep alike, since both enter that
    gate through the same function — carrying `repo`, `cap` and `count`
    throughout, plus `waiting_backlog` on `merge-budget-hold`; `fleet_flag`
    (the write outcome), `reason` (a short, deterministic rendering of the
    anomaly, D18 issue #574) and the same `waiting_backlog` the paired
    `merge-budget-hold` event just carried, on `merge-budget-frozen`; and
    `issue_number`/`issue_url` on
    `merge-budget-freeze-escalated`, on the same terms
    `crash-loop-escalated`/`approver-escalated` already carry theirs. `reason`
    and `waiting_backlog` on `merge-budget-frozen` (D18 issue #574) exist so a
    dashboard tick can show why a repository is frozen and what it is holding
    without a live read of the freeze flag or `merge_budget_oldest_waiting` —
    both network reads a dashboard tick has no business making
    (`docs/spec/dashboard/README.md`'s own budget note) — sourced instead from the
    event that already fires the moment `merge_budget_apply_decision`
    establishes them, the only place either fact is ever established.
    `enabler-adjudication` (requirement 36b, `escalation_autonomy:
    "adjudicate-first"`, agent-ops#627) is logged once per adjudication pass
    `run_enabler_adjudication` runs, carrying `repo`, `item`, `verdict`
    (`adequate`/`inadequate`), `evidence` and `adjudication: true` — the same
    verdict-plus-evidence shape `approver-verdict`'s own `adjudication: true`
    marker carries (requirement 8c), read here rather than reused there
    because the two adjudications judge different questions over different
    stages' own verdicts.
    `open-question-raised` (requirement 8f, agent-ops#668) is logged once per
    Reviewer `ready` round carrying one or more `open_questions`, whether or
    not this is the first such round for the pull request, carrying
    `pr_url`, `repo`, `label_projection` (`landing_open_question_label_
    project`'s own word) and `questions` (requirement 32's array, verbatim).
    `open-question-adjudication` is logged once per adjudication pass
    `run_open_question_adjudication` runs, carrying `pr_url`, `repo`,
    `verdict` (`settled`/`escalate`), `evidence` and `adjudication: true` —
    the same verdict-plus-evidence shape `enabler-adjudication` and
    `approver-verdict`'s own `adjudication: true` marker carry, read as its
    own event rather than reused from either because it judges a third,
    distinct question (does an existing pull request's own diff and work
    order already answer this question?) over neither stage's own verdict.
    `open-question-escalated` mirrors `approver-escalated` exactly —
    `pr_url`, `issue_number`, `issue_url` — logged by `open_question_
    escalate` whether reached directly (`escalation_autonomy:
    "always-escalate"`) or after an `escalate`/failed adjudication pass.
    `review-gate-checks-read` (requirement 31c,
    TD-PPagop-26081404) is bookkeeping, one per ready-gate evaluation, carrying
    `ok: true|false` — machine-read by the streak verdict, and kept out of
    the dashboard's log tail (`scripts/publish-dashboard.sh`,
    docs/spec/dashboard/README.md) so a row with nothing to tell an
    operator does not displace one that has; `review-gate-checks-degraded`
    is the escalation `review_gate_unknown_streak_verdict` triggers, logged
    once per streak, carrying the verdict's own
    `node`, `gate`, `count`, `first_ts` and `last_ts` — `first_ts` doubling
    as the dedup key `review_gate_degraded_since` matches the run by. A
    `first-seen` (TD-PPagop-26081405, issue #248 acceptance 4) is written by
    `emit_first_seen` (lib/candidate-select.sh) the first time any node's gather
    ever
    reports a given `{repo, item}` pair, for each of the seven pre-fetched
    arrays requirement 3q names (`issues`, `findings` — split into its own
    `security`/`code-quality` `source`, since one gather call answers for
    both — `tech_debt`, `review_feedback`,
    `merge_conflicts`, `dequeued`, `abandoned_drafts`), carrying `repo`,
    `item`, `source`
    (the same label the eventual `selection` for that item carries),
    `basis: "poll"` (every current source re-reads its target every cycle; a
    future event-native source, stage 3 of issue #248 recorded in
    `docs/ROADMAP.md`, would carry a different basis), and `bootstrap` —
    `true` when the writing node's own log held no earlier `first-seen` at
    all when the cycle began, `false` otherwise. It is a fact, not a state —
    logged once per item, ever, with no clearing event — and
    `emit_first_seen` keeps that guarantee itself: it reads
    `lib/cycle-state.sh`'s `first_seen_known_items` off the union log once
    per cycle and skips any candidate already present, so a later cycle —
    this node's own or a peer's — that gathers the same item appends
    nothing. Because two nodes can race to be first past that check before
    either write is visible to the other, the guarantee is once-per-cycle-
    per-node rather than fleet-atomic, exactly like every other log write
    this system makes outside the branch claim itself; a reader reduces
    same-item duplicates by keeping the earliest `ts` (`scripts/pickup-
    metrics.sh`'s `first_per_key`), the same first-wins convention
    `first_seen_known_items` itself applies. Emission runs on each source's
    raw gathered array, ahead of requirement 3q's own claimed-item exclusion
    and the blocked/void pass further down (3u), so an item claimed, blocked
    or voided the same cycle it first appears still gets one — those
    exclusions only ever narrow what the Co-Ordinator is shown, never what
    this fleet has seen. Eight sources, not all twelve that produce
    selections, and by construction rather than by oversight: the event
    exists only where a pre-fetched candidate array does, so the other four
    are outside it and their pickups land permanently in
    `coverage.selection_only` (component 21). Three of the four —
    `implementation-plan`, `project-review` and `failed-runs` — requirement
    3q itself names as Co-Ordinator-derived, with no pre-fetched array to
    hang the event on. The fourth, `human-visibility` (requirement 38e), has
    an array but is deliberately left out: `gather_human_visibility_hygiene`
    returns at most one candidate per repo whose `ref` is a digest of the
    *whole* surviving violation set
    (`scripts/gather-human-visibility-hygiene.sh`), so a violation appearing
    or clearing beside another mints a fresh `ref` — a fresh `first-seen`,
    dated now — and restarts the clock on a violation that had in truth been
    visible for days, understating the
    latency the figure exists to report. Nor is the upstream array an anchor:
    `human_visibility_violations` (`lib/human-visibility-hygiene.sh`) carries
    no `ref` at all, so `emit_first_seen` would log nothing there, and a
    synthetic one keyed on `pr_url` could never pair with the composite `ref`
    the eventual `selection` carries. Measuring this source honestly means
    re-scoping its `ref` to per-violation identity, the same
    expiry-by-irrelevance rule requirements 3c, 3e and 3g's own refs depend
    on; until that is done
    the boundary stands and is disclosed rather than papered over.
    `bootstrap` exists because a node's first cycle
    emitting `first-seen` at all — freshly onboarded, or the cycle this
    feature first deployed to it — reports nearly everything its gather sees
    as "new", when most of it has in truth existed for a while;
    `scripts/pickup-metrics.sh` (component 21) excludes those items from its
    median/p90 while still counting them, so the exclusion is visible rather
    than a silent drop. Kept out of the dashboard's log tail for the same
    reason `review-gate-checks-read` is: machine bookkeeping with nothing an
    operator can act on, read only by `scripts/pickup-metrics.sh`. A `rework`
    event (requirement 47, TD-PPagop-26082920) gets the same treatment for a
    related reason, provisionally rather than permanently: its record carries
    no `detail` for the dashboard's generic renderer to show, its only reader
    today is the Phase 2 rework panel (D23, #611) that does not yet exist, and
    `claim-race-duplicate`/`stage-rerun` fire often enough under healthy
    fleet contention to displace rows that do have something to say — the
    same "displace rows that have something to say" ground the two exclusions
    above already state. Unlike them, this one is expected to be undone: once
    #611's panel exists to consume the record, re-including `rework` in the
    tail is a one-line reversal, not a rediscovery. An
    `issues-excluded` event (requirement 3j; agent-ops#447) carries `repo`,
    `count` and `excluded` — the same `{number, reason}` array
    `scripts/gather-issues.sh` reports as `issues_excluded` — plus a `detail`
    string ("N issue(s) excluded: #125 (assigned), …", or plain "0 issue(s)
    excluded" with no trailing colon when the set is empty) for the
    dashboard's generic log-tail renderer, which shows any event's `detail`
    verbatim with no event-specific rendering of its own. Logged by
    `gather_issues`'s caller (lib/candidate-gather.sh) on change only (review
    decision
    on agent-ops#452 concern 1): once per cycle, for the one repo whose
    `issues` band that cycle read fresh (requirement 48 — a repo replaying
    its cached band logs nothing, having observed nothing new to log a change
    against), when that repo's
    exclusion set differs from the one carried by the most recent
    `issues-excluded` event logged for it — `lib/cycle-state.sh`'s
    `latest_issues_excluded`, read off the union log once per cycle the same
    way `first_seen_known_items` is, with a repo carrying no prior event read
    as an empty previous set. The transition to a smaller or empty set logs
    exactly as the transition to a larger one does, so a release from
    exclusion is as visible as its onset was — a repo whose exclusion set is
    unchanged from cycle to cycle, healthy or stuck alike, logs nothing
    further, so an operator scanning a quiet cycle does not have to skip past
    a row repeating what an earlier row already said; "how long has this
    repo's exclusion held" is then the age of its own last `issues-excluded`
    event, not a count of identical rows.

    The previous- and current-state reads are deliberately asymmetric
    (review decision on agent-ops#452 concern 3): the previous-state read
    fails open — any error reading it logs the event unconditionally rather
    than risk staying silent, since silence is exactly the #447 failure
    class this event exists to remove — while the current state does not,
    because logging asserts the *current* exclusion set and that assertion
    must be known to be made at all. `scripts/gather-issues.sh` reports
    `excluded: null`, not `[]`, when its deterministic filter did not run to
    completion (an API failure mid-gather), and `gather_issues`
    (lib/candidate-select.sh) carries the same `null` one layer up for its own
    catastrophic-fallback shapes; `gather_issues_excluded` returns that
    `null` verbatim. A `null` current set skips the comparison, the event and
    the baseline update entirely — the degraded mode must never assert
    something it doesn't know, and an empty array here would otherwise
    fabricate a release from exclusion on an ordinary `gh` hiccup, then
    overwrite the baseline so the next healthy cycle logs a spurious onset
    back. Leaving both untouched on a degraded cycle is what lets the
    staleness reading above ("how long has this repo's exclusion held")
    survive a flapping gatherer rather than resetting on every blip. The
    Co-Ordinator's own runtime input is unaffected either way: a `null`
    current set still reaches it as `issues_excluded: []`, the same "nothing
    to report" reading an empty `candidates` already gets. Unlike
    `first-seen`, `review-gate-checks-read` and `rework`, this event
    **stays** in the dashboard's log tail: every row reports a transition,
    which is precisely the kind of fact an operator can act on, not
    bookkeeping to hide. A
    `dependabot-rebase-requested` (requirement 3s)
    carries the `repo` and the `number` of the Dependabot pull request this
    cycle asked to rebase itself; a nudge that could not be posted is a
    `warning` whose `detail` names the same repo and number instead, since
    nothing was requested and the retry is automatic next cycle. A
    `void-retired` event (requirement 34n) carries the `repo` and `item` of
    the void entry it retired from the extract, the `void_ts` of the verdict
    it settled, and `by` — `object-closed` or `register-resolved` — the
    actioned signal that qualified it; it is a fact with no clearing event,
    read back by `void_retired_items`. A `salvage` event (requirement 9e) carries the
    `stage` being rescued and an `outcome` — `attempted`, `recovered` or
    `failed` — plus `exit_code` when the resume itself did not exit 0. It is
    written for every resume the Script actually starts, success or not,
    since a run of failed salvages with no `recovered` among them is itself
    the evidence that a shape `extract_json_result` still cannot reach has
    recurred; a failed run with no session to resume at all writes no
    `salvage` event, because no attempt was made. An `approver-verdict`
    (requirements 8b/8c) is written once per Approver engagement that reached
    a verdict, carrying the `pr_url`, the `repo` it belongs to, the `tier` it
    was judged at, the `model` that reached it (empty on the deterministic
    Trivial tier, which never launches one), the `verdict` itself, the
    `refuse_streak` that tier was chosen against, `adjudication` — `true`
    where the streak, not the complexity grade, chose the tier — and
    `posted` — `true` only once `approver_post_or_warn` reports the GitHub
    write it describes actually succeeded, `false` for a write GitHub
    refused *and* for a verdict that attempted none at all (an adjudication
    `escalate`, or an unrecognised verdict). `posted` is the field
    agent-ops#573's divergence record (component 22a) reads to exclude a
    verdict a human never saw a review for: it cannot have diverged from, or
    agreed with, an action taken in response to a review that was never
    actually posted. A `critical_reason` field (`protected-path` or
    `refuse-streak`; absent when `tier` is not `critical`) distinguishes D18
    WI-12's two causes of the critical tier — a protected-path hit and a
    two-refusal streak can both route here, and requirement 8d's own gate
    4.5 needs to know it was genuinely the critical tier that ran, not
    merely that an adjudication happened to land on the same model. The
    event otherwise records what the Approver decided, never that GitHub
    accepted the review on its own: a review the API refused is *also* a
    `warning` naming the pull request and the event (`approver_post_or_warn`),
    so an operator finding an `approver-verdict` with no review on the pull
    request has the write's own failure logged beside it rather than having
    to infer it, and `posted: false` says the same thing to a machine
    reader. An `approver-verdict` event logged before agent-ops#573 carries
    none of `repo`/`model`/`posted` — every reader of them (component 22a)
    treats an absent `posted` as `true` (the best available assumption for
    history it cannot re-observe) and derives `repo` from `pr_url` rather
    than trusting the field, so old and new events read the same way. An
    `approver-escalated` (requirement 8c) carries the same `pr_url` plus the
    `issue_number` and `issue_url` of the escalation an unsettled adjudication
    raised; a filing that failed is a `warning` instead, since
    `create_escalation_issue`'s own dedup makes the retry next cycle free. An
    `approver-escalation-retired` (requirement 8c, agent-ops#1215) is that
    escalation's own closing record, carrying `pr_url`, `issue_number`,
    `issue_url` and `cause` — `land` when this pipeline's own adjudication
    settled it, `merged` when requirement 17c's sweep found the pull request
    merged some other way — so a page the owner answered (no event: they
    closed the issue themselves) reads differently from one the pipeline
    outgrew. A close GitHub refused is a `warning` instead, the same shape
    the filing side already uses, since the next pass retries it for free.
    The `merged` half carries `repo` as well, `lib/standdown.sh` stamping it
    on every action `scripts/sweep-closed-issues.sh` reports. A
    `landing-armed` (requirement 8d, D18 WI-7) is written once per successful
    arm, carrying `pr_url`, `repo`, `source`, `complexity`, `level` — the
    *effective* `merge_autonomy` level gate 1 judged the arm against, kill
    switch and per-repo merge-budget freeze already folded in, recorded here
    because this is the only moment anything knows it and requirement 8e's
    post-hoc audit reads it back as the level that landing was armed under —
    and `method` — `enqueued` or `auto-merge`, `landing_arm`'s own report of
    which write it made — plus `cap` and `count` (D18 issue #574), gate 5's
    own `merge_budget_decide` result at the moment this arm was granted, paid
    for already and never a second read; this is the only trace an `arm`
    decision leaves of the cap/count `merge_budget_decide` saw, so a
    dashboard tick can read a repository's current consumption from the
    single latest of this event and
    `merge-budget-hold`/`merge-budget-frozen` — plus `retry: true` when the
    arm came from the landing-retry sweep
    rather than the round that first approved the pull request (requirement
    8u); the field is absent, never `false`, on that original round. A
    `landing-refused` carries `pr_url`, `repo`, `class` and `reason` —
    `reason` a plain string, one per refusal path in `_landing_stage_attempt`,
    naming the gate that failed (an ineligible or unreadable classifier
    verdict, a dirty or unreadable review gate, a standing human
    `CHANGES_REQUESTED`, D18 WI-12's own gate 4.5 refusing a protected-path
    pull request at `agent-merges-all` whose approving engagement did not run
    at the critical tier or whose `landing_cool_off_hours` wait has not yet
    elapsed (naming the remaining time), an unreadable merge budget or App
    login, an already-queued or unreadable merge-queue probe, an unreadable
    token mint, or `landing_arm` itself refusing) — and, on the same terms as
    `landing-armed` above, `retry: true` when the refusal came from the
    landing-retry sweep. `class` (TD-PPagop-26082823, issue #1017) is the
    mechanically enforced field a human — or `scripts/publish-dashboard.sh`'s
    landings digest — reads to tell every refusal path apart: one of
    `lib/landing.sh`'s own `_LANDING_REFUSAL_CLASSES`, a closed set
    `test/landing-wiring.test.sh` enumerates against every literal `CLASS`
    argument `_landing_refuse` is called with in that file, set at the call
    site rather than derived from `reason`'s own text. Gate 1's own refusal
    (`landing_autonomy_refusal_reason`, `lib/landing.sh`, D18 issue #576)
    carries class `kill-switch` only when a second, independent read of
    `merge_autonomy_kill_state` confirms the fleet-wide kill switch is the
    actual cause of LEVEL not qualifying — never when a repository has
    simply not had its level raised, which carries class `autonomy-level`
    instead. `class` is never omitted on an event this pipeline logs today:
    a `CLASS` outside the closed set is logged verbatim, never coerced to
    look legitimate, and costs a `warning` event naming the offending value
    so a call site that slipped past the enumeration test stays visible
    rather than silent; a caller passing an empty `CLASS` logs `class: null`,
    still never an absent key. An event logged before this field existed is
    the only one carrying no `class` value at all, which `byReason`
    (`dashboard/index.html`) reads as licence to fall back to the superseded
    text-before-first-`:` split described in `docs/spec/dashboard/README.md`'s own
    refusal-grouping note — never for an event that names a class, however
    its own varying content (chiefly an embedded `$pr_url`'s scheme colon,
    TD-PPagop-26082502) reads.
    `landing_arm`'s own refusal names which of its steps failed —
    the pull request read, the merge-queue read, the enqueue mutation (a
    transport failure or a partial write reporting no queue entry), or the
    fallback `gh pr merge --auto --squash` — read off its exit status by
    `_landing_arm_failure_reason` (`lib/landing.sh`, agent-ops#532) rather
    than left as one bare "could not enqueue or auto-merge" every one of
    those otherwise shared. A `merge_budget_decide` result of `hold` or
    `refuse` reached
    from the arming step logs through `merge_budget_apply_decision` exactly
    as it always has (above), not `landing-refused` — the two vocabularies
    do not overlap, so a reader scanning for either finds every refusal
    exactly once. A `stage-start` carries the two caps that stage
    was given and where each came from — `backstop_min`, `inactivity_min`,
    `source` and `basis` (requirement 4f) — because a self-tuning number that
    cannot be traced is a mystery number. It also carries `lane` (issue
    #2239, D30) — the credential lane the Script *intended* the stage to run
    on, `lib/metering.sh`'s `metering_intended_lane`: `api` when this node
    holds `ANTHROPIC_API_KEY`, `subscription` otherwise, until #2241 lets a
    provider route across a weighted set of open lanes instead of this
    node's single credential. Distinct from the `lane` requirement 33a's
    metering record carries on the matching `stage-end`, which is what the
    run *actually* used — read off the stage's own stream rather than
    assumed, so the two may disagree. A `stage-end` carries `kill_reason` —
    `inactivity`, `backstop` or `rate-limit` — when and only when requirement
    4e stopped the stage; its absence means the stage ended on its own,
    well or badly. `exit_code` is 124 for both kills and so cannot tell them
    apart, and they are different findings. A `labels-ensured` carries the `repo`, its `role`,
    and the labels `created`, `updated`, `deleted` and `failed` (requirement
    6a) — `updated`/`deleted` are ever non-empty only for a `label_prefix`-named
    label reconciled by `labels_reconcile_role`'s own full CRUD (`target`'s
    MODE `full` for `deleted`; any role, colour/description drift, for
    `updated`) — it is written
    only when there was something to report, so it appears the first cycle a
    repository is gathered and then not again until a full
    `labels_ensure_interval_hours` has elapsed, unless a label is deleted or
    the token cannot create one. A `labels-minted` (requirement 6c) carries
    `repo`, `item`, `actor` (`"refiner"` or `"implementer"`), and the names
    `created`, `applied` and `refused` — one per item that named at least one
    label, whatever the outcome; unlike `labels-ensured` it is never
    rate-limited, since minting is per-verdict rather than per-repository.
    A `claim-lost` names the repo, item and branch of
    the candidate the Script failed to claim, plus a `cause` — `held` when a
    peer node won it, `pr-held` when a peer holds the pull request it targets
    under some other item ref (and then also `pr_claim_key`, the `pr-<number>`
    key contended on), `unreachable` when GitHub could not be reached, or the
    raw exit code otherwise (requirement 17a); `selection` carries the
    claimed `branch`. A `pr-ready` carries `handoff` — `reviewer`, `script` or
    `enabler` — naming who took the PR out of draft (requirements 31a, 32b);
    the event means the pull request is not a draft, not that somebody said so.
    Where a human's review blocked it, `pr-ready` also carries
    `review_requested` — `already`, `requested` or `failed` — and the
    `reviewers` it names (requirement 31b); all three are omitted where nobody
    was blocking, which is the ordinary first-round case.
    An `attempt-failed` carries `pr_url` when the failing stage was working on
    one (requirement 32a), and — for the refinement class of requirement 34e —
    `kind: "needs-refinement"`, the `unblock_condition` taken from the report's
    `missing`, its `evidence` and reporting `source`, plus
    `needs_refinement_label` when the Script managed to project the label. It
    carries `stage_failure: true` when, and only when, the stage's own attempt
    is what failed — a crash, a timeout, a signal, an unparseable final
    message — and never when the event instead records a verdict about the
    *item* a stage reached by running to completion; requirement 2.8 is the
    reader that requires the marker and sets out why the two shapes have to be
    told apart. A
    `recheck-clean` (requirement 18a) carries the `item` and `repo` the
    Co-Ordinator named in `recheck_clean` — repo-scoped, unlike `unblocked`,
    because the two fail in opposite directions: an `unblocked` that
    over-matches across repos only makes an item a candidate again
    (requirement 34 calls that the safe direction), where a `recheck-clean`
    folded into an unrelated repo's identically-numbered item would raise
    requirement 18a's comparison threshold and so *suppress* a mandated
    re-read. The Script tolerates an entry that arrives as a bare id — the
    event is logged without `repo`, and the extract folds it into every
    same-numbered blocked item, leaning on requirement 18a having obliged the
    emitting Co-Ordinator to re-read all of them — but that is a degraded
    fallback, not the shape to emit. Unlike `unblocked` it clears nothing;
    the `blocked` extract instead folds the newest such event per item into
    that item's entry as `recheck_clean_ts`, for requirement 18a's own
    comparison to read on the next cycle. An
    `item-refined` carries `repo`, `item`, `by` (`"enabler"` or `"refiner"`,
    the stage that wrote it) and exactly one of the `spec` it wrote or the
    `comment_url` of the comment it posted — never both, and which one is
    settled by whether the item has a thread (requirements 36b, 39c (The
    Refiner), 4j); the
    common `cycle` and `ts` are what requirement 3h reads it back by, and what
    requirement 39a (The Refiner)'s own read compares against a fresher block's `ts` to
    decide whether the refinement still stands. A
    `stage-start`/`stage-end` pair's `stage` is `coordinator`,
    `implementer`, `reviewer`, `approver`, `enabler` or `refiner`; the last
    two are the ones that may appear on a cycle which selected nothing, since
    both run from the cleanup of requirement 11. A `stage-end` alone, with no
    paired `stage-start`, also carries `stage: "enabler-adjudicate"`
    (requirement 36b, `run_enabler_adjudication`) — the one caller of
    `run_model_stage` outside those six actors that logs a `stage-end` at
    all; a `<stage>-salvage` resume logs neither. The usage-limit probe of
    requirement 1b also logs a `stage-end` alone, `stage: "limit-probe"`
    (issue #2239, D30, `lib/standdown.sh`) — ignored by `lib/stage-health.sh`,
    whose stage list does not name it. An
    `enabler-examined` carries
    `repo`, `item`, the
    `blocked_ts` it was examined against, an `outcome`, and the Enabler's own
    `detail`; a `refiner-examined` carries the same shape plus `source`
    (requirement 39c (The Refiner)) — `outcome` is `refined`, `refined-uncorroborated` (a
    `refined` verdict naming neither a comment nor a `spec`, so nothing was
    recorded), `needs-refinement`, `needs-refinement-refused`, `triage-only`
    (a `triage_only` item's band-only verdict, requirement 39g),
    `triage-only-refused` (a `needs-refinement` decline of a `triage_only`
    item, which is not a block the Script will record), or
    `unknown-verdict`. An `own-label-action` carries `repo`, `item`, `label`
    and `action` (`"add"` or `"remove"`) — the Script's own memory of a label
    it applied or removed, read back only by the hand-flag mechanism of
    requirement 34g, extended by requirement 39f to tell the Script's own
    writes from a human's. An `escalated` carries `repo`, `item`, `issue_number`, `issue_url`
    and `blocked_ts` (requirements 35a, 36a). An `unblocked` written by the
    Enabler also carries `repo`, `by: "enabler"` and a `reason`, which is what
    distinguishes it from the Co-Ordinator's cheap re-check of requirement 18 —
    the bare-id form remains valid and remains what a human appends by hand. An
    `unvoided` written from a label (requirement 34f) carries `repo`,
    `by: "label"`, the `request_url` that authorised it, `labelled_at`, and the
    `cleared_void_ts` it reopened; the bare hand-appended form remains valid.
    A `corroboration` (requirement 3v) is one cycle-wide verdict measured
    against the Script's own eligible set across every repository whose own
    engagement said no (requirement 3x; the tech-debt band alone before it,
    every configured repository's own engagement together before issue
    #587's split): `attempt` (always `1` — there is no retry to distinguish
    it from, since issue #587 dropped the model retry a rejection used to
    buy), `verdict` — `accepted` or `rejected` — `eligible_total`,
    `unaccounted_total`, and, on a rejection, a `bands` object counting the
    unaccounted per source, the `unaccounted` `{repo, item, source}` triples
    and the verdict's own `reason` (every repository that said no, joined).
    Every event carries requirement 3w's `coordinator_model`. This is the
    record a rejection *rate* is computed from, one event per cycle that
    reaches it; the cycle's outcome is `none-selected` or `selection`, which
    is a different question and deliberately a different event.
    A `none-selected` carries the Co-Ordinator's own `reason`; the
    `fingerprint` requirement 3b arms the no-op short-circuit with, omitted
    where there was nothing to fingerprint, where some engagement produced no
    verdict at all (requirement 15y — the event then carries
    `engagements_failed`, the count of them), or where the corroboration gate
    rejected
    the verdict — which carries `td_verdict_rejected: true` (a name requirement
    3x keeps though the gate is no longer tech-debt-only) and requirement
    3x's `bands` instead, once the mechanical fallback (requirement 3v) also
    found nothing; and, on **every**
    branch, requirement 3w's `eligible_total` and `coordinator_model`, so a
    cycle whose bands were genuinely empty — which logs no `corroboration` at
    all — still says so on the record rather than being indistinguishable
    from an event written before any of this existed.
    The Reviewer's `stage-start` additionally carries the resolved
    `complexity` and the `model` it selected (requirement 8a) — the record
    that lets the distribution of complexity self-assessments be audited for
    drift. Common fields: ISO-8601 `ts`, `cycle` id, `node`, `event`, and where
    applicable `repo`, `item`, `pr_url`, `model`, `detail`. The cycle id is
    `<UTC-timestamp>-<node>-<pid>` — the node's `NODE_NAME` (hostname when
    unset), sanitised for use in a directory name, with the pid always last
    because the dashboard matches the running cycle by its `-<pid>` suffix.
    A record appended **by hand** was produced by no cycle, and says so: its
    `cycle` is the sentinel `"manual"`, which is deliberately not of that shape.
    Readers that enumerate cycles must therefore admit only ids matching
    `^[0-9]{8}T[0-9]{6}Z-` and ignore the rest, or a sentinel becomes a
    phantom run (dashboard spec, "A record in the log is not the same thing as
    a cycle"). Readers that act on the record — the blocked and void sets, the
    limit stand-down — key on the event and the item and never look at `cycle`,
    so a hand-appended record carries exactly the weight its event does.
    `node` says which machine wrote the record, which is what lets several
    nodes' records be combined; records written before the field existed
    simply lack it, and every reader treats it as optional. A `none-selected` also carries
    the `fingerprint` of requirement 3b; `disabled`/`enabled` carry the switch
    record, so the log can explain both why cycles stopped and why they
    resumed — including when they resumed because a disable expired rather than
    because anyone chose to re-enable it. Both also carry `scope` — `"node"`
    when the instruction (or, for the two automatic-expiry sites below, the
    record) touched only `state_dir/disabled.json`, `"fleet"` when it reached
    for `fleet/disabled.json` too — and, only when `scope` is `"fleet"`,
    `fleet_flag`: `"ok"` when the fleet flag was actually written or deleted,
    `"failed"` when a real attempt to reach it did not succeed, `"unconfigured"`
    when there was nothing to reach (no `state_repo`, or the flag was already
    absent). Every writer of `disabled`/`enabled` — `--disable`, `--enable`,
    and the node-scoped and fleet-scoped switch-expiry clearances at cycle
    start (requirements 2.3 and 2.3a) — shares this vocabulary, so a reader
    never has to learn a second set of words for the fleet-level case. The
    event is logged only once the fleet outcome is known, after the write or
    delete has been attempted, so a process killed mid-fleet-attempt loses the
    event rather than logging a `disabled` that cannot say whether the fleet
    followed; `enabled` is logged whenever anything was actually cleared — the
    local record, the fleet flag, or both — including a `--enable` run on a
    node with no local record of its own but a live fleet flag, which a
    `record`-only condition used to leave silently absent from the log. A
    `chained` event (requirement 39 (Finish-then-continue)) is logged by the parent cycle, from its
    own cleanup, immediately before it launches its continuation: `depth` is
    the launching child's own place in the lineage (the parent's plus one) and
    `max_chained_cycles` is the cap in force, so a lineage's length is
    reconstructable from the log without inferring it from consecutive
    `cycle-start` timestamps. `selection`, and any `attempt-failed` or
    `item-void` raised once an item has been selected, must carry both `repo`
    and `item` — requirements 34 and 34c key on them, so an event that omits
    them cannot pin any state on the item it names, and the omission is
    invisible until you notice the same work being redone.
33a. **Metering.** Every `stage-end` event additionally carries the per-stage
    metering record: `model` (the model id passed to the invocation),
    `provider` (the provider that model resolves to, per `lib/model-id.sh` —
    `anthropic` for every record this system has ever written, until a
    second provider lands behind requirement 4d's adapter seam; issue #2133),
    `cost_usd`, `duration_ms`, `num_turns`, `is_error` (pulled from the
    stage's `result` envelope named in requirements 11 and 4d /
    `docs/spec/dashboard/README.md`), and `tokens` — an object with `input`,
    `output`, `cache_creation` and `cache_read`, summed across every model the
    invocation's own tree used (top-level plus any subagents), matching how
    `cost_usd` already counts subagent spend. It also carries `lane` — `api`,
    `subscription` or `null` (issue #2239, D30) — the credential lane this
    run actually used, read off the stage's own *stream* rather than the
    `result` envelope every other field above comes from: `lib/stage-run.sh`
    reads it through the substrate seam's `_lane_of` operation
    (`lib/substrate-claude-code.sh`'s own version maps the stream's first
    `system`/`init` event's `apiKeySource`) exactly as it reads
    `stage_result_line`, and hands the result to `metering_fields` beside the
    gap statistics. `null` when the stream carries no readable answer, never
    a guessed lane. `lib/metering.sh`'s
    `metering_fields` derives this from the stage's own out-file, and is the
    one implementation both this Script and `review-cycle.sh` call for their
    `stage-end`/`review-stage-end` events — a stage whose out-file was never
    written, or whose envelope cannot be read, degrades every envelope-derived
    field to `null` (`model` stays, being the id it was given) rather than
    dropping the event or failing the cycle. That holds for any envelope, not
    only the unreadable ones: the record is merged into the event as it is
    logged, so a derivation that produced nothing would cost the event its own
    `stage` and `exit_code` — the fields requirement 33 above and requirement
    34 below key on — and the metering of a stage must never be able to do
    that.
    The record additionally carries `gaps` — `{n, p50, p95, p99, max}` in
    seconds, or `null` — the run's own **inter-event gap statistics**: how
    long the invocation went between one piece of output and the next. This is
    the one field not read from the envelope, because it cannot be: the
    envelope records that the run did things, never when. `lib/stage-run.sh`
    measures it by `stat`-ing the stage's event stream inside the poll loop
    that already runs every two seconds while a stage is in flight, so the
    unit of observation is bytes arriving rather than events parsed — the
    contract is "the runner streams progress to a file; liveness is monotonic
    growth of that file", which is a statement about running a stage rather
    than about one CLI's output format. The stage emits nothing for this,
    agrees no cadence, and can fake nothing. The first gap is the wait for the
    run's first byte and the last is the silence from the final output to the
    end of the stage — that one included deliberately, because a stage that
    fell quiet and was killed has its longest silence at the end, and a sample
    that dropped it would omit exactly the runs the measurement exists to
    describe.
    `docs/METERING-SCHEMA.md` is the field-by-field contract: types, units,
    the per-cycle aggregation rule, and what future change is additive versus
    breaking.
34. Blocked semantics: an item is blocked iff the most recent
    `attempt-failed` / `unblocked` event *for that item* is `attempt-failed`.
    An `attempt-failed` event must carry enough detail for a future
    Co-Ordinator to judge whether the blocker has since been removed.
    `unblocked` events may also be appended by hand by the human. Three
    details decide whether this rule works at all:
    - **Key on `repo` and `item` together.** An item id is only unique within
      its repo — every repo has a `dependabot-alert-1`, and registers that
      number by date collide across repos — so keying on the id alone lets one
      repo's block starve the other's identically-named work.
    - **An event carrying no `item` blocks nothing**, and must be dropped
      rather than grouped under an empty key: a stage that fails before
      anything is selected has no item to blame, and collapsing every such
      event together yields one "blocked" entry describing no item at all.
    - **An `unblocked` event naming no repo clears that item in every repo.**
      The Co-Ordinator reports unblocked as a bare id (requirement 18) and a
      human appending one by hand has no repo to hand either, so there is
      nothing to match on. Over-clearing is the safe direction: the item
      merely becomes a candidate again and re-blocks on its next attempt.
34a. Whatever computes requirement 34 must be the **only** definition of it.
    Anything else that reports blocked items — notably the monitoring
    dashboard (`docs/spec/dashboard/README.md`) — shares that one
    implementation rather than reimplementing the rule. Two copies drift, and
    a dashboard that quietly disagrees with the Co-Ordinator about what is
    blocked is worse than no dashboard: it is where you would look to find
    this class of bug, and it would show you the wrong answer confidently.
34c. Void semantics: an item is void iff the most recent `item-void` /
    `unvoided` event *for that item* is `item-void`. The rule is requirement
    34's shape over a different pair of events, and all three of its details
    apply unchanged — key on `repo`+`item`, an event naming no item voids
    nothing, a clear naming no repo clears everywhere. Build it as one
    parameterised rule used twice, not two rules that happen to agree
    (requirement 34a).
    - An `item-void` event carries `reason` and `evidence` — the SHAs, paths,
      or commands proving there is no work. A void is terminal, so the record
      must let a human audit the verdict without redoing the investigation.
    - **Only a human may clear a void**, by appending `unvoided` by hand. Give
      the Co-Ordinator no way to emit one; the whole point is that it must not
      reason its way out of a void, and it can reason its way out of anything.
    - A void is keyed to a specific item id, which is what stops it becoming a
      permanent gag. When the review pipeline runs again it files its
      recommendations under fresh ids (`review-<new-date>-R-NN`) that no
      existing void covers, so a genuine regression returns as new work. Voids
      expire by irrelevance rather than by review, which is the only expiry an
      unattended system will actually perform.
    - The Co-Ordinator may *create* voids (requirement 18) for candidates it
      can see conclusively are already done, and should: that is one cheap read
      instead of a full Implementer run reaching the same answer. Creating is
      safe where clearing is not — a wrong unvoid costs a full cycle, cycle after
      cycle, until someone notices — but it is not free, and requirement 34d is
      what makes it safe enough to keep.
34d. **Every `item-void` a stage writes is corroborated before it is made
    permanent.** `void_guard_reason` in `lib/void-guard.sh` is the one
    entry point the Co-Ordinator (requirement 18), the Enabler (requirement
    36a's `void` row) and the Implementer (requirement 9b) all call before
    logging `item-void`; none of the three may write it directly. The rule is
    about the three *stages*, and there are exactly two writers outside it.
    The first is the Script's own pre-flight (requirement 34m), which reads
    its evidence straight off `gh`, the register file or the cycle's own
    pre-claim digest — the ground truth the tests below check a stage's
    citation *against* — and so has nothing for the guard to corroborate it
    with. The second is requirement 36f's `corroborate-void` act
    (`run_pending_decision_acts`, `lib/decision-veto.sh`), which supplies for
    the three closing pull-request shapes exactly the corroboration this
    requirement otherwise only accepts from a human's own `obsolete` label: a
    decision taken under the delegate mandate, filed as a closed
    `pw::decision` issue, and left un-reopened for the whole of
    `decision_veto_window_hours`. Each carries its own `stage` all the same —
    `preflight` and `decision` — so a reader auditing the log for guarded
    voids can tell either from a stage evading this requirement. Five tests, all on the Script's side of the boundary:
    - **Evidence must be present.** Requirement 34c's `evidence` field is
      required on every void, and `null`, `""`, whitespace, `{}` and `[]` are
      all absence. An entry without it is not a verdict, it is an opinion.
    - **A resolvable citation must resolve.** `evidence` shaped `{ref, path,
      expect: "present"|"absent", pattern}` names a specific claim about a
      specific file at a specific ref — "the fix is on `main`", "the register
      says resolved" — and the guard fetches `repos/<slug>/contents/<path>?ref=<ref>`
      and tests it: `expect: "absent"` holds iff GitHub answers `404 Not
      Found`, `expect: "present"` holds iff the fetch succeeds and, when
      `pattern` is given, the decoded content matches it. Only that one answer
      establishes absence: a fetch that fails any other way — rate limited,
      unauthenticated, no network, a `ref` GitHub cannot resolve — has
      established nothing, and reads as the unreadable pull request below
      does, not as the absence it was asked about. A citation that does fit
      the shape but does not resolve — the fetch fails, the
      presence/absence/pattern does not hold, or the entry names no repo to
      resolve it against — is refused the same way an unrefuted PR diff is
      below. A citation that does not fit the shape at all is free text,
      tested by the next check rather than this one.
    - **A cited PR or commit must actually be about this item.** Evidence
      naming "PR #N" or "pull request #N" (bare form, resolved against the
      entry's own `repo`) or the URL `https://github.com/<owner>/<repo>/pull/<n>`
      (the form `gh pr view`/`gh pr create` print, resolved against the
      `owner/repo` the URL itself names, never against the entry's `repo`) is
      fetched live (`repos/<slug>/pulls/<n>`, `<slug>` being whichever of
      those two resolved it) and checked for the item id, as a whole word, in
      its body or its head branch — the same two places the gatherers read to
      associate a PR with an item in the first place. Evidence naming a
      commit ("commit `<sha>`" or "`<ref>@<sha>`", bare form, resolved against
      the entry's own `repo`) or the URL
      `https://github.com/<owner>/<repo>/commit/<sha>` (resolved against the
      URL's own `owner/repo`) is checked two ways: the commit must be an
      ancestor of the repository's default branch
      (`repos/<slug>/compare/<sha>...<default_branch>`, `status` `identical`
      or `ahead`), and either its own message or a pull request GitHub
      associates with it (`repos/<slug>/commits/<sha>/pulls`) must name the
      item the same way a cited PR does. A bare citation with no `repo` to
      resolve it against is refused naming the citation, exactly as before —
      a URL citation is unaffected, since it carries its own `owner/repo`
      regardless of whether the entry names one. A `review-<date>-R-<nn>`
      recommendation ref gets one more chance before the body/branch test
      above refuses it: the pull request implementing a recommendation is
      opened against the tech-debt issue that recommendation designates,
      never against the review ref itself, so a body/branch test that found
      neither resolves the ref instead — `void_review_item_tech_debt_id`,
      `lib/void-guard.sh`, reading the designated id off the recommendation's
      own "Tech-debt item: `<id>`" line in
      `reviews/project-review-<date>/03-recommendations.md` on the entry's
      own repo's default branch — and re-runs the same body/branch test
      against that id instead. Any failure along the way (the item is not
      shaped like a recommendation ref, the entry names no repo, the
      recommendations file cannot be fetched, or this recommendation carries
      no such line) falls through to the ordinary refusal unchanged
      (issue #2030). One item shape is decided by
      its id, rather than by the free-text body/branch test: a finishing-source
      item **is** a pull request — requirements 3e, 3g, 3z and 23 mint its id as
      `pr-<n>-abandoned-<head-sha>`, `pr-<n>-review-<review-id>`,
      `pr-<n>-conflict-<head-sha>`, `pr-<n>-superseded-<head-sha>` or
      `pr-<n>-dequeued-<head-sha>` — so a
      citation of pull request `<n>`
      names item `pr-<n>-…`'s own pull request by the id's own construction,
      and the id, not the citation text, decides which live check applies to
      it (`void_finishing_item_pr`, `void_finishing_item_shape`,
      `void_finishing_pr_reason`, `lib/void-guard.sh`). That check fetches PR
      `<n>` and reads its own state. A pull request the API will not answer
      for is refused as unreadable, never treated as innocent. `merged` or
      otherwise `closed` corroborates every shape outright — there is no more
      finishing to do on a pull request that will never land this way,
      whatever became of the underlying work. An `open` one is read against
      what its own shape claims, and **the strictness is calibrated to what
      requirement 34k then does with the void**:

      - `pr-<n>-abandoned-…` and `pr-<n>-review-…` — a corroborated void of
        these makes 34k *close pull request `<n>`*, with a comment. So an
        `open` reading is accepted in any of three cases: an **empty diff
        against its base** — whatever the item was to finish is already on
        the base, and closing the PR discards nothing — the pull request
        already carrying the human-applied **`obsolete` label**, checked live
        off the same fetch that read `state`, before the `/files` diff count
        is ever read (TD-PPagop-26081308) — or a **machine-checkable
        alternative to that label** (issue #413, WI-10, design doc §5.5),
        available only where `merge_autonomy_effective_level` is
        `agent-merges-all` for this repository: a `draft-obsolete-flagged`
        event an earlier, independent Enabler engagement logged for this
        pull request (36a's `flag_obsolete`, never a void itself), read at
        least 24 hours old, from a different cycle than the void's own, whose
        evidence — like the void's own — is the structured `{ref, path,
        expect, pattern}` shape and resolves live. The label is the
        deliberate, corroborable "no longer wanted" signal a diff can never
        be — restoring the capability an empty-diff-only reading could not
        reach, a draft that still changes files but is simply unwanted — and
        no pipeline stage may ever apply it itself (`lib/labels.sh`'s
        catalogue comment, `prompts/implementer.md`'s explicit prohibition):
        a stage that could would be corroborating its own judgement, exactly
        what this requirement exists to stop. The flag is not that stage's
        own judgement doing the same thing under a different name: an
        Enabler that flags a draft records no verdict that closes anything,
        and only a *second*, independent engagement's own void — on its own
        evidence, corroborated the ordinary way requirement 34d always
        required — can ever act on it, which is what the differing-cycle and
        24-hour conditions exist to guarantee. An open pull request with none
        of an empty diff, the label, or a corroborating flag is refused,
        naming the file count still outstanding — that claim is a judgement
        no API call can corroborate on its own say-so, and closing a live
        branch on an unexamined one is exactly how pull request #264 was lost
        (TD-PPagop-26080901). Such a void is escalated instead of recorded,
        to a human who can either resolve the item honestly or apply the
        label — or, where the installation runs at `escalation_autonomy:
        "decide-with-veto"`, to a decide pass that may supply the same
        judgement itself under requirement 36f's delegate mandate, with the
        veto window standing where the human's own reading of the draft
        otherwise stands.
      - `pr-<n>-conflict-…` — a corroborated void of this shape closes
        **nothing** (34k excludes it, for the same #264 reason: the void says
        the *conflict* resolved, not the pull request, which stays a live PR
        of ours carrying its full diff). An empty diff is therefore not the
        claim being made, and demanding one would refuse every honest void
        this source can write. The test mirrors the one that minted the item
        instead (requirement 3g, `gather-merge-conflicts.sh`): the void is
        refused only while the API still reports the PR **definitively
        conflicting** (`mergeable: false`). A `mergeable` GitHub has not
        finished computing (`null`) reads as not definitively conflicting and
        is accepted — the same asymmetry the gatherer chose in the other
        direction, admitting a candidate on `CONFLICTING` and never on the
        transient `UNKNOWN`.
      - `pr-<n>-dequeued-…` — a corroborated void of this shape closes
        **nothing** either (34k excludes it too, TD-PPagop-26081409), for the
        same reason as `-conflict-`: the void says the *dequeue* resolved, not
        the pull request. The test again mirrors the one that minted the item
        (requirement 3z, `gather-dequeued.sh`): the void is refused only while
        the pull request's *current* head still matches the head SHA the item's
        own id embeds — read out of the id, never trusted from the entry's own
        `evidence` — **and** `merge_queue_probe`, re-read live, still reports it
        not re-queued. A head that has moved (a fix landed, whichever cycle's)
        or a probe that cannot answer both read as resolved, the same
        ambiguous-accepts asymmetry the `-conflict-` shape's `null` mergeable
        gets.
      - `pr-<n>-superseded-…` — a corroborated void of this shape *does* close
        pull request `<n>` (34k's ordinary act-on-void path, once the id shape
        distinguishes it from `-conflict-`, TD-PPagop-26081304). The
        `-conflict-` shape's mergeability test proves the wrong claim here — a
        superseded bump can be superseded whether or not it still conflicts —
        so this shape gets its own live test instead, calibrated to the same
        closing act #264 was lost to: accepted only when **both** hold, at
        void time, never read off the entry's own `evidence`: the PR's author
        is Dependabot's own account — read here off a REST fetch, which spells
        it `dependabot[bot]`, not the `DEPENDABOT_LOGIN` spelling
        `lib/dependabot-bump.sh` holds for the GraphQL surface `gh --json`
        reads (the same account, two surfaces, and only the listing call below
        takes the GraphQL one) — and
        `dependabot_newer_open_pr`, re-run against the repository's
        *currently* open Dependabot pull requests, still names a
        strictly-newer open bump of the same family. Either half failing
        refuses, naming which one. This is the excuse `-conflict-` used to
        grant Dependabot before this shape existed — moved here because the
        claim it excuses ("superseded") now has its own shape to be
        corroborated against, rather than riding on a shape whose own
        mergeability test it can never honestly pass.

      An id of no recognised shape takes the strict reading, never the
      permissive one. The id names a pull request in the repository that
      minted it, so this
      check fires only when the citation resolves against the entry's own
      `repo` (the two slugs compared case-insensitively, as GitHub treats
      them); a citation resolving against any other repository, or one made
      by an entry that names no `repo` at all, shares only the number with
      the id and is tested against the cited pull request's body and branch
      like any other citation — corroborated when the fetch names the item,
      refused when it does not, never decided on the number alone. Any other
      pull request is tested as usual. Nothing writes that synthetic id into
      the pull request's body or branch, so the body/branch test would refuse
      the one citation these items can honestly make — which is why the id
      chooses the live-state test instead, rather than being skipped
      (TD-PPagop-26080807: this shortcut fired with no fetch at all, and so
      corroborated nothing but the id's own construction). That live check is
      the whole of the corroboration this shape gets, in **every** stage: the
      candidate test below never backstopped it and cannot. It matches a
      candidate's `item`, and a finishing-source id is never a candidate's
      `item` — the gatherers put it in `ref` and leave `item` as whatever
      register id the branch or body named, or `null` — so the Co-Ordinator's
      extra test is as silent on this shape as the Enabler's and the
      Implementer's `repos: []` calls are. Evidence citing neither a PR nor a
      commit is untouched by this test — the next one is what governs free
      prose that cites nothing. This is what a citation that merely *exists*
      was missing: the shipped defect that motivated it (below) cited a PR
      that was real, open, and entirely unrelated to the item being voided.
    - **Evidence that fits none of the checkable shapes is refused, not
      accepted on presence alone** (issue #413, WI-10). The three checks
      above are independent and additive — the structured shape when present,
      a citation when the evidence text carries one, a finishing-source
      item's own live state when its id names one — and any one of them
      failing refuses the void outright, even when another already succeeded:
      each is its own corroboration, not an alternative skipped once one has
      passed. An entry for which *none* applies — prose naming neither a
      citation nor the structured shape, on an item whose id names no pull
      request to finish — is refused with a reason naming what was missing.
      Before this, such evidence passed on being merely non-empty
      (TD26072601's own deliberate carve-out, "accepted on the presence test
      alone rather than demanding every void fit one mould") — exactly the
      hole `TD26072114`'s void (below) walked through, and the residual gap
      issue #243 left open on the reasoning that a human backstop
      (`unvoided`) covered it. D18 retires that backstop, so the residual is
      closed here.
    - **This cycle's own candidates must not refute it (Co-Ordinator only).**
      Where the voided repo+item matches a gathered candidate carrying a
      `pr_number`, the guard reads that PR's changed files: a non-empty diff
      against its base means the change is by definition not on the base,
      whatever anyone asserts. The candidates tested are the ones the
      Co-Ordinator was given, so a void can never be refused over something it
      could not have seen. A PR the API will not answer for counts as
      uncorroborated, not as innocent. The Enabler and the Implementer gather
      no per-cycle candidate list, so they call the same guard with `repos:
      []`; this one test simply has nothing to run, and every other test above
      applies to them exactly as it does to the Co-Ordinator.

    A refused void is recorded `attempt-failed` — blocked, not void — plus a
    `warning` naming the refusal, with `stage` set to whichever of the three
    wrote it. Blocked is the clearable twin: the stage still skips the item so
    nothing churns, and requirement 35a makes it Enabler-eligible, so an actor
    that *can* read the tree adjudicates. If the item really is done, a later
    engagement voids it properly, with evidence that survives corroboration.
    The pipeline reaches the same answer; it may not reach it by assertion. A
    refusal from the Enabler's own `void` verdict is recorded with the outcome
    `void-refused` on its `enabler-examined` event (requirement 36a) — an
    ordinary examination, not `escalation-failed`'s exemption, since the
    engagement did reach a verdict; it was simply not corroborated.

    Not a prompt instruction, and the distinction matters: "be certain" is
    already in `prompts/coordinator.md` twice, and the Co-Ordinator that voided
    `TD26072114` with "PR #92 work is finished … all merged; TECH-DEBT.md Ledger
    marked resolved" was certain. On the default branch the workflow still had no
    timeout, the Ledger row still read `open`, and PR #92 was an open, conflicted
    draft. Because a void keys on the item it bypassed the per-head refs of
    requirements 3e and 3g that exist precisely so a changed state gets a fresh
    look, so the item was unreachable from both directions at once — void as a
    tech-debt candidate and void as the abandoned draft that would have finished
    it. Every following cycle reported `none-selected` citing the void, the no-op
    fingerprint (requirement 3b) then matched, and three nodes stood down hourly
    on a repository with outstanding work. That is the shape of the failure this
    guards: not a wrong answer, but a silent one.

    The citation test above closes a second, distinct shape of the same
    failure: a Co-Ordinator voided an issue citing "PR #232 implemented all
    five rewrites" — #232 was real and mergeable, but it was a different
    issue's PR; the actual fix had landed in a different pull request
    entirely. Every test that existed before the citation test passed, because
    none of them had ever asked whether the cited PR was *about the item being
    voided*. Reading more of the repository does not fix this by itself — the
    Enabler and the Implementer already read more than the Co-Ordinator does,
    and carried the same gap regardless — only checking the citation does,
    which is why the guard is shared rather than duplicated per stage.

34e. **Under-specification is a class of block, not a parallel state.** Each
    well-formed `needs_refinement` entry (requirement 16a) is recorded by the
    **Script** as an `attempt-failed` against that repo+item with
    `stage: "coordinator"` and `kind: "needs-refinement"`, the entry's `missing`
    promoted to `unblock_condition` and its `reason` and `evidence` carried on
    the event. Everything downstream then follows from requirement 34 with no
    new machinery: the item is excluded from selection (16.1), becomes eligible
    for the Enabler on the ordinary threshold (35a), is cleared by an
    `unblocked` from either the Enabler or the Co-Ordinator's own cheap
    re-check (18), and can be voided if it turns out to describe no work. A
    parallel state would have had to re-earn every one of those properties, and
    would have earned each of them slightly differently.

    The threshold delay is a feature here, not a cost of the reuse: it gives the
    human — or requirement 18's re-check, which can clear a refinement block
    whose `unblock_condition` has demonstrably been met, such as a patched
    version appearing for a skipped security finding — several cycles to settle
    the item before the expensive stage is bought.

    Four entries are refused, all on the Script's side of the boundary:
    - **A malformed entry** — missing `repo`, `item`, `reason`, `missing` or
      `evidence`, judged on requirement 34d's emptiness discipline — is logged
      as a `warning` and dropped. The fields are what the Enabler starts from,
      so an entry short of one starves the very stage the report exists to
      reach.
    - **A re-report of an item that is already blocked** is logged as a
      `warning` and dropped. Requirement 35a measures the Enabler threshold from
      the *latest* `attempt-failed`, so a Co-Ordinator that re-reported the same
      item every cycle would push that clock forward cycle after cycle and the
      item would never become eligible — the identical silent starvation this
      path exists to end, wearing an event trail that looks like progress.
    - **A `source: "issues"` entry whose own `reason`/`missing`/`evidence` cites
      a `Blocked-by:` reference this cycle's dependency gate already resolved**
      (`dependency_refusal_reason`, `lib/dependency-gate.sh`; requirement 16's
      dependency third; agent-ops#566) is logged as a `warning` and dropped.
      `issues_by_repo_json` — the same reshaped candidate map requirement 34j's
      `dependency_clearances` already reads — is the proof: an item present in
      it has, by `scripts/gather-issues.sh`'s own live check this cycle, no
      unresolved reference left on its thread, so a report re-asserting one is
      demonstrably false, never a second opinion worth recording. Reused
      exactly as gathered — this refusal never issues a second `gh` read, and
      never re-derives what the gate already computed. Scoped to the
      dependency claim alone: the bar reads only whether the entry's own
      fields name a reference that item's thread carries, so a
      `source: "issues"` entry declining the item as a question or
      discussion, or for any other under-specification, names none and is
      recorded on the ordinary bar above.
    - **A Co-Ordinator report naming an item this same cycle's fit ladder
      (requirement 4i) actually trimmed** (`coordinator_fit_trim_refusal_reason`,
      `lib/coordinator-input.sh`; agent-ops#683) is logged as a `warning`
      naming the item and the rung, and dropped. On 2026-08-21 the ladder's
      bottom rung (`0:0:1000`) cut every candidate's body to a title-level
      fragment and its comments to none; the Co-Ordinator, correctly following
      its own prompt's "if you cannot tell what done would mean, report
      needs_refinement", reported exactly that for its whole visible backlog,
      and requirement 3x's own completeness bar then compelled the Script to
      record every one as a block — nine items, most of them already refined
      within the preceding day, flagged `needs-refinement` in 68 seconds (and,
      before agent-ops#651 ended that separate path, re-assigned too). Neither
      rule was individually wrong; the two are jointly compelled to this
      outcome whenever the ladder trims this far, and it recurs on every
      context-tight cycle that selects nothing, scaling with backlog size —
      the fix is a refusal here, on the Script's side, matched by requirement
      3x's own completeness exception below. `coordinator_fit_trimmed_items`
      (`lib/coordinator-input.sh`) is the exemption set — every issues/
      tech-debt candidate whose body or comments the fit's own `fit_entry`
      actually clipped this cycle, detected off the elision marker in a
      clipped body, the same marker in a clipped *comment* body, or the
      `comments_elided` key a cut comment list leaves behind, and never
      re-derived from the entry's current byte length. All three markers,
      because all three take text away from the same reader: an issue whose
      body is two lines and whose acceptance criteria live in a Refiner's
      comment is trimmed past what "done" would mean by a middle rung that
      clips that one comment and leaves everything else as it found it. The
      refusal is unconditional on the entry's own `reason`/`missing`/`evidence`, and on whether the reporting stage
      fetched the item live before writing them: the Script cannot tell a
      report grounded in a live read from one grounded in the elided extract
      it was handed, and the harm of the occasional false refusal is far
      smaller than the harm of asking the question at all on a cycle whose
      whole backlog was trimmed this far. Scoped to `stage == "coordinator"`:
      the Refiner and Implementer read the repository live rather than off
      this cycle's Co-Ordinator input, so a fit-ladder mark on that input says
      nothing about what either of them actually had in front of them. An item
      refused here is neither blocked nor accounted for — it stays exactly as
      eligible as it was, for a future, untrimmed cycle to judge on its own
      terms.

    **The label is a projection, never the record.** Where (and only where) the
    item is a GitHub issue — the `issues` source, whose ref is a bare number —
    the Script applies `needs_refinement_label` to it as it records the block,
    records on the event which label it applied, and removes that label when the
    block is cleared or the item is voided. Nothing ever reads the label back.
    Work items here are heterogeneous — issues, tech-debt records, review
    recommendations, findings, plan tasks, per-round PR refs — and a label can
    reach exactly one of those sources, so a pipeline that read it would see a
    fraction of its own state and be confidently wrong about the rest. The label
    is recorded on the event rather than assumed from config because it is what
    a later cycle removes: a label the Script did not apply is one it must not
    claim to have removed. A repo where the label does not exist gets a
    `warning` and the block regardless — losing the projection costs a human's
    filter, losing the block would cost the item its escape path.

    On `--dry-run` the block is recorded like the other verdicts this path
    already logs, and **no label is applied or removed**: a label is an outward
    change to a repository, which requirement 12's run promises not to make.
    Since the event records only what was actually applied, nothing later tries
    to remove a label that was never there.

    **No stage may write a block whose `unblock_condition` names, as the only
    remaining gap, a state that same block is itself about to create.** This
    recorder can, in the same write, both log the block and project a label
    onto the object it names — and a verdict whose own `missing`/`evidence`
    frames that label's *removal* as the way out has described a condition
    only a human can satisfy, using the pipeline's own next action as the
    reason it is needed. This happened for real (agent-ops#670): a Refiner
    found agent-ops#597 and #598 already carrying an adequate specification
    and, following its prompt's then-unqualified "never write a second
    specification" rule, declined both `needs-refinement` with the detail
    that nothing further could be added and the unblock condition that a
    human must remove the hand-applied label — three seconds before the
    Script applied that very label as this requirement's own projection, a
    deadlock the pipeline had manufactured for itself and could not exit
    under its own power. Requirement 39c (The Refiner)'s re-affirmation closes the
    Refiner's own route to this shape: an item it judges already adequately
    specified is `refined`, not `needs-refinement`, so no block — and no
    unblock condition referencing a label not yet applied — is ever written
    for it. The invariant is stated here, at the shared recorder, rather than
    only at the Refiner, because any future reporter that reaches this path —
    Co-Ordinator, Implementer, or a stage not yet written — inherits the same
    risk the moment its own verdict's free-text fields can describe the label
    this requirement is about to add.
34f. **The human's escape hatch reaches the human.** Requirement 34c reserves
    clearing a void to a human and gives them one interface: a line appended by
    hand to `state_dir/log.jsonl`. That interface is unreachable in the
    deployment this system actually has — the nodes are containers and
    `state_dir` is a volume inside one, while the maintainer is in a browser
    looking at the pull request the void is about. An escape hatch nobody can
    reach does not constrain anything; it just makes the terminal state
    permanent in practice as well as in principle.

    So a void is also cleared by applying the `unvoid_label` (default
    `unvoided`) to any issue or pull request naming the item, in the item's
    repo. Per repo per cycle the Script reads the issues carrying that label —
    one call, since the issues endpoint returns pull requests too — resolves
    each to the item ids its branch, title and body name (an issue also being
    its own id), and clears the matching voids. This is not a relaxation of
    requirement 34c: **no stage ever applies this label**, so only a human can,
    exactly as before. What changes is where they have to be standing.

    Three properties, all load-bearing:
    - **Applied above the extract.** The `unvoided` events are written before
      `blocked_items`/`void_items` are read for the cycle, and appended to the
      union snapshot of requirement 2.5 — the exact lines just written, not a
      rebuilt snapshot, which would pull in whatever peers wrote meanwhile. A
      clearance landing after `void_json` was computed is a cycle late, and a
      cycle late here means the human watches nothing happen and concludes, for
      the second time, that the label does not work. It also needs no new
      fingerprint input (requirement 3b): `void_json` is already fingerprinted,
      and it shrinks the same cycle the label is read.
    - **The label is never removed.** Removing it would move the item's
      `updatedAt`, which is the clock `abandoned_draft_after_hours` is measured
      against (requirement 3e) — so tidying up after the human would push the
      very pull request they are unsticking another staleness window into the
      future.
    - **Which makes the rule, not the label, what stops it repeating.** A
      clearance is emitted only where the item is void *now* and the void was
      recorded *strictly before* the label was applied. The first test makes it
      idempotent with no label churn. The second stops a label left in place
      becoming a standing exemption that auto-clears every future void on that
      item from an instruction given months earlier about a different verdict —
      a failure with no symptom at all beyond an item that never stays void.

    The recorded `unvoided` carries `by: "label"`, the `request_url`,
    `labelled_at`, and the `cleared_void_ts` it reopened, so a later reader can
    see which verdict was reopened and on whose authority without going back to
    GitHub. The hand-appended line of requirement 34c remains valid and
    unchanged; this is a second door to the same room.

    The instinct it serves is the one the system already teaches: labelling a
    pull request `autonomous-agent` hands it to the pipeline, so a label is
    already how a human tells this system something from GitHub. Faced with a
    void, a maintainer applied a label called `unvoided` to the pull request and
    nothing read it — the item stayed void, the fleet stood down hourly, and the
    label sat there looking like the action had been taken.

    Requirement 34n adds a second, coarser way back that is deliberately
    *not* this one — and it is a ratified change of position, not an
    oversight. While a void is still being carried, a plain reopen of the
    closed object changes nothing, exactly as this requirement records: the
    label is the only voice a human has. But once the void has *retired* from
    the extract (actioned and `void_retire_after_days` old), reopening the
    closed object is enough by itself: nothing in the extract suppresses the
    item any longer, so the reopened object is simply gathered as a fresh,
    ordinary candidate — the same outcome a genuine `unvoided` would have
    produced. The two mechanisms knowingly part company there: 34k's sweep
    still declines to re-close an object it once closed, and the audited
    label route, with its `ts`-ordering rule, remains the only exit *before*
    retirement. The judgement ratified is that a human reopening an issue
    whose void has been settled, actioned and stale for a month is
    unambiguously asking for the work back, and demanding the label on top
    of the reopen would be ceremony with no added authority.
34g. **A human's own hand-applied label is a report, not a state.** Requirement
    34e's projection is deliberately one-way for the block *it* creates: the
    label mirrors what the Co-Ordinator already reported, and nothing reads it
    back. That left the one person the mechanism serves unable to invoke it —
    a human reading an issue has no `needs_refinement` entry to hand a
    Co-Ordinator, and no `state_dir/log.jsonl` to append to from a browser, the
    same gap requirement 34f closes for a void. Applying
    `needs_refinement_label` by hand did nothing and looked exactly like it had
    worked.

    So, during source gathering, the Script scans each repo's issues — open and
    closed, one search per repo — for `needs_refinement_label` and resolves who
    last applied it and when from the issue's timeline. Read above the
    skip-list extracts, for the same reason as 34f: a reconciliation landing
    after `blocked_json` is computed is a cycle late, and a cycle late here
    reads to the human as the label not working, a second time.

    Two decisions follow, both against `blocked_items` as it stands at the
    point each is made:
    - **A currently-open issue carrying the label, with no block yet open for
      it under any kind or origin**, earns a coordinator-stage `attempt-failed`
      exactly like a Co-Ordinator's own `needs_refinement` report would:
      `kind: "needs-refinement"`, `detail` naming the label and who applied it,
      `source: "issues"`, the label itself as `needs_refinement_label` (so its
      lifecycle — removed when the block clears — is the one requirement 34e
      already describes), and `hand_flagged: true`, which marks this block as
      one this mechanism, not the Co-Ordinator, created. There is no
      `unblock_condition`: a human applying a label has said "this needs
      specifying", not what is missing, and a promoted field with nothing
      behind it would be worse than an absent one. A closed issue is excluded
      even if it still carries the label — a closed issue is not a candidate
      the `issues` source or requirement 35a's escalation test can reach
      either, so blocking it would buy an engagement over something already
      unselectable.
    - **A block this mechanism created (`hand_flagged: true`) whose issue no
      longer carries the label at all** — open or closed — maps to the
      existing hand-appended `unblocked` path (requirement 18): the Script
      logs `unblocked` with `by: "label-removed"`, and the item is selectable
      again next cycle. Scoped to `hand_flagged` blocks only, and only that
      scoping keeps 34e's one-way rule true for everything else: a block the
      Script itself projected the label onto is not marked `hand_flagged`, so a
      label missing from underneath one of those — by mistake, by the repo's
      own automation, by anything other than this mechanism — clears nothing.
      Reading the label back for every refinement block regardless of origin
      is the "second writer of refinement state" this design deferred rather
      than shipped as part of requirement 34e (`TECH-DEBT.md` TD26072602): it
      would let anything that touches the label reopen a block a model is
      still working from, on no authority at all. An issue that keeps the
      label but is closed is not a removal either, by the same closed-issue
      reasoning as above — the human closed the issue, they did not withdraw
      the flag.

    Eligibility asks nothing new of a hand-flagged block: requirement 35a
    already treats `kind` as informational rather than a second axis — "the
    kind marker changes nothing about the rule, and deliberately so" — so a
    hand-flagged block crosses the same `enabler_after_coordinator_cycles`
    threshold as any other refinement block, reported or hand-flagged alike.
    Carving out separate pacing for this one origin would be exactly the
    exception that design note declines to make, and the fleet has no evidence
    yet that a human's label needs different timing from a model's report;
    whether refinement blocks in general deserve their own threshold is the
    tuning question `TECH-DEBT.md` TD26072604 leaves open for later, not one
    this requirement answers on a guess.

    `--dry-run` still records both directions: neither writes to GitHub (the
    label is only ever read here, never applied or removed by this mechanism),
    so there is no outward change for requirement 12 to forbid.

34h. **Where the two states meet, void wins.** An item may carry both marks at
    once, and routinely does: `item-void` is a state of its own and clears no
    block, so a `void` verdict — the Enabler's ordinary way of retiring work
    that turned out to be already done (requirement 36a) — leaves the
    `attempt-failed` before it standing for as long as the log remembers it.
    Requirements 34 and 34c are the same rule over different events, but they
    are not symmetric in what they ask of whoever reads them, so any consumer
    that must reduce an item to *one* state resolves it to **void**: a void item
    is waiting for nothing, is never selected, and is never re-examined at the
    Enabler's prices, and reporting it as blocked overstates the backlog with
    work the pipeline has already closed the book on.

    That subtraction is a rule in its own right and so has exactly **one**
    implementation (requirement 34a): `open_blocked_items` in
    `lib/cycle-state.sh`, which composes the blocked and void extracts rather
    than re-deriving either, matches a void to a block on requirement 34's own
    terms — a void naming no repo covers the item in every repo, since either
    half of that pair may be hand-appended by a human with no repo to hand —
    and carries each entry through unchanged, `recheck_clean_ts` and all. Both
    consumers that owe a single answer use it: the Enabler's eligibility rule
    (requirement 35a, clauses 1 and 2) and the monitoring dashboard's Blocked
    items table (`docs/spec/dashboard/README.md`).

    The Co-Ordinator's own input is **not** reduced. It is handed the blocked
    list and the void list side by side (requirement 18), and requirement 34c
    means it to see both: "skip this for now, and clear it when the impediment
    goes" and "never select this again, and never clear it" are different
    instructions, and an item that has become the second is one the Co-Ordinator
    must be told about under the state that binds it.

