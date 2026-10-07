## Acceptance checks

### Acceptance checks — continued (part 5 of 6; items 8t–50)

8t. **The arming step lands only what the classifier clears, re-reads every
    gate fresh, and disarms cleanly (requirement 8d, D18 WI-7).**
    `test/landing.test.sh` passes against a stubbed `gh`:
    `landing_protected_paths_hit` reports every one of the nine protected
    prefixes agent-ops's own `merge_autonomy_protected_paths` default names
    (`.github/*`, `deploy/*`, `prompts/*`, `lib/*`, `config.schema.json`,
    `config.json`, `agent-cycle.sh`, `review-cycle.sh`, `CODEOWNERS`) and
    exits 0 when any is touched, 1 when none is, 2 — never trusted as a
    pass — on an unreadable or page-capped changed-file listing, and 3 —
    also never trusted as a pass, but distinct from 2 — on a
    `merge_autonomy_protected_paths` entry `_landing_is_protected`'s own jq
    program cannot compare against a path at all (a non-string entry, which
    makes `jq -e` raise — its own exit 5 — rather than merely return false;
    TD-PPagop-26082320, not reachable through a schema-validated
    `config.json`, whose `items` are constrained to non-empty strings, but
    still a contract the helper itself must hold); `landing_eligible` names
    which of the two fired in its own `unknown:` reason text rather than
    blaming the changed-file list regardless of cause
    (TD-PPagop-26082325); a repo-level `merge_autonomy_protected_paths` override (the
    same precedence `merge_autonomy_routine_sources` uses) wins over the
    top-level list, pinned against `scripts/detect-classifier-escapes.sh`'s
    own independent reimplementation (`test/detect-classifier-escapes.test.sh`,
    D18 Stage 3, agent-ops#724) so the two can never silently diverge on what
    counts as protected, including on that same non-string-entry verdict;
    `landing_eligible` reads `ineligible` for a level below `agent-merges-routine`,
    for a complexity outside the repository's own
    `merge_autonomy_routine_complexity` — `complexity:high` under the
    default `["low", "medium"]` list, regardless of source or path — and for
    an empty complexity, for a source outside the repository's own
    `merge_autonomy_routine_sources` (a repo-level override taking
    precedence over the top-level list, the same precedence
    `merge_autonomy` itself uses) and for an empty source, `unknown` on an
    unreadable protected-path read (naming the changed-file list), an
    unevaluable protected-paths list (naming `merge_autonomy_protected_paths`
    instead, TD-PPagop-26082325), or an exit code from
    `landing_protected_paths_hit` outside its documented 0/1/2/3 contract
    (agent-ops#1232, pinned by temporarily replacing the helper with one
    that exits an out-of-contract code, since the real helper's own case
    statement never produces one), and `eligible` only once every condition
    clears — with a repo-level `merge_autonomy_routine_complexity` override
    admitting `complexity:high` for that repository alone while a repository
    without one still refuses it, and a top-level override admitting it
    fleet-wide (D18 Stage 3, agent-ops#725) — with pinned cases confirming the `source` comparison is exact
    string equality, never expanded against the four `issues:<band>` ranks:
    a plain `issues` routine-list entry matches a real issues work order's
    own `"issues"` source, and an `issues:low` entry (a schema error, since
    the key takes `landingSourceToken` and not `sourceToken`) does not, the
    comparison folding no bands. The membership test is additionally guarded
    against an empty routine list, because `jq -e` on empty input exits 0 on
    jq 1.6 and 4 on jq 1.7, which would otherwise invert this gate on a 1.6
    host; `landing_approver_standing_review`
    reads a login's own most recent standing `APPROVED`/`CHANGES_REQUESTED`
    review — ignoring `COMMENTED`/`DISMISSED` — reading empty for a login
    that never reviewed, and non-zero on an unreadable list, confirming this
    is a fresh GitHub read independent of whatever `agent-cycle.sh`'s own
    in-process verdict says; `landing_arm` enqueues via
    `enqueuePullRequest` when `merge_queue_for_branch` reports an active
    queue on the pull request's base branch, falls back to `gh pr merge
    --auto --squash` when it reports none, issues either write with
    `GH_TOKEN` set for that one invocation only, and returns non-zero
    printing nothing when the pull request's own details, the queue probe,
    the mutation or the merge itself cannot be confirmed — each of those
    four (plus bad arguments and the mutation's own partial-write case) its
    own distinguishable exit status (agent-ops#532), pinned directly in
    `test/landing.test.sh` together with `_landing_arm_failure_reason`'s
    mapping from each one to the text `run_landing_stage` folds into its
    `landing-refused` reason.
    `test/merge-queue.test.sh` covers `merge_queue_for_branch` the same way
    `merge_queue_probe` is already covered: the literal `null` for no
    queue, the queue object verbatim when one exists, and non-zero on an
    unreadable or malformed response. Wired into the Approver stage
    (`lib/approver.sh`; `test/approver-wiring.test.sh` continuing to pass
    confirms
    `run_approver_stage` still reports `approver_stage_verdict`/
    `approver_stage_adjudicating` correctly for `run_landing_stage`'s own
    precondition), with `test/landing-wiring.test.sh` lifting
    `run_landing_stage`, `_landing_stage_attempt` and `_landing_refuse`
    verbatim out of `lib/landing.sh` and exercising every gate under `set
    -euo pipefail`,
    the options that file itself runs under rather than the `set -uo
    pipefail` a library test uses — a refusal a gate helper reports in its
    *exit status* (`review_gate_verdict` exits 1 for `dirty`, 2 for an
    unreadable required-check list) must log `landing-refused` and return,
    never abort the cycle mid-stage, and only the production options can
    tell the two apart: a protected-path pull request is never armed at
    `agent-merges-routine`, whatever the Approver's verdict, complexity or
    source; at `agent-merges-all` it is armed only once D18 WI-12's own gate
    4.5 clears (below) — an Approver refusal, an adjudication (its
    own `land` included), an unparseable verdict, or a stage that did not
    run each leave `run_landing_stage` returning immediately with nothing
    armed; at `merge_autonomy: human` and `agent-approves` no arming path
    executes at all and every existing pr-ready/Approver behaviour is
    unchanged; a local `approve` verdict whose review GitHub itself refused
    to post is caught by the fresh standing-review re-read and refuses
    arming rather than trusting the in-process verdict; a standing human
    `CHANGES_REQUESTED` prevents arming regardless of the App's own
    approval; a `merge_budget_decide` result of
    `hold` or `refuse` reaches `merge_budget_apply_decision` and arms
    nothing; a successful arm logs `landing-armed` exactly once and never
    withholds `pr-ready`, the claim release or the Approver's own review;
    every refusal path logs `landing-refused` naming a reason, never a
    blocked pull request or a withheld claim.

    The four-level ladder crossed with both landing paths is swept in one
    conformance test, `test/landing-human-veto-conformance.test.sh`
    (agent-ops#577, part of D18 #402): with a standing human
    `CHANGES_REQUESTED` in place throughout, nothing arms in any of eight
    cases — `human`, `agent-approves`, `agent-merges-routine` and
    `agent-merges-all`, each crossed with the landing path `landing_arm`
    would otherwise take (`enqueued` for a base branch with an active merge
    queue, `auto-merge` for the no-queue fallback). The eight cases are not
    one shape repeated: `_landing_stage_attempt`'s gate 1 refuses on the
    effective level *before* gate 4 is ever consulted, so at `human` and
    `agent-approves` the refusal names the level and
    `_handoff_blocking_reviewers` is never called at all (pinned directly,
    by call count); only at `agent-merges-routine` and `agent-merges-all`
    does the refusal come from the human-veto gate itself, naming the
    blocking reviewer, in a reason textually distinct from every other
    refusal class in the same function (gate 4's own App-approval half
    included). Since the veto refuses upstream of gates 5 and 6 and of
    `landing_arm` itself at every level it binds, `landing_arm` is never
    invoked in any of the eight cases regardless of which landing path is
    configured — proof that neither path offers a way around the veto, not
    merely two differently-labelled identical runs.

    `test/handoff.test.sh` covers the freshness half directly against
    `_handoff_blocking_reviewers` itself, against a real (stubbed `gh`)
    review history rather than a stubbed gate: a reviewer's `DISMISSED`
    position is excluded from `_handoff_latest_reviews`'s own filter before
    `group_by`/`last` ever runs, so it never stands in for a clearing
    `APPROVED` — a `CHANGES_REQUESTED` dismissed and then reasserted still
    blocks, and a `CHANGES_REQUESTED` merely dismissed (with nothing
    following) still blocks too, since the dismissal is invisible to the
    computation rather than read as the reviewer's own last word; only a
    genuine later `APPROVED` from that reviewer clears it.

    These two files pin the formal-review half of "a human change request
    blocks landing" — `_handoff_blocking_reviewers` reads only formal
    reviews, and a human cannot leave a formal `REQUEST_CHANGES` review on
    this system's own pull requests at all: GitHub refuses that review type
    from a pull request's own author, and every pipeline write and every
    human comment on these pull requests land under the same account, so
    their only instrument is an ordinary comment. `lib/reconciliation-gate.sh`
    (agent-ops#533, closed via PR #539) closes that case at the Reviewer's
    own ready-flip: a pull request carrying an unreconciled non-pipeline
    comment since it last left draft cannot be flipped Ready in the first
    place. That gate runs once, at hand-off, and on its own does not reach a
    comment posted after a pull request is already Ready, in the window
    before a later cycle's arming step lands it — gate 4's fresh
    formal-review read alone still sees nothing standing against a plain
    comment. Gate 4 (`_landing_stage_attempt`, `lib/landing.sh`) closes that
    residual window itself (agent-ops#672) by calling `reconciliation_gate`
    a second time, unbounded, immediately after `_handoff_blocking_reviewers`
    — unbounded because, unlike the Reviewer's own call, this stage never
    flips the pull request out of draft, so the raw "most recent
    `ready_for_review` event, not since undone" already is the anchor this
    read needs. A `dirty` verdict refuses arming, naming the unreconciled
    comment(s); an `unknown` verdict (the timeline or comment list could not
    be read), and the empty word a call that never executed at all leaves
    behind, both refuse too (#753's ruling on agent-ops#746) — neither is
    unfolded as a case distinct from the other, and the refusal is
    unconditional, never dependent on `merge_autonomy_effective_level`.
    `test/landing-wiring.test.sh` pins this directly: a case with a `dirty`
    `reconciliation_gate` stub refuses arming with the unreconciled comment
    named in `landing-refused` and never calls `landing_arm`, a case with
    `unknown` and a case with the empty word both refuse arming too — a
    `landing-refused` naming what could not be confirmed, `landing_arm`
    never called, `_landing_stage_attempt_armed` staying `0` — and the happy
    path confirms `reconciliation_gate` is called exactly once per attempt,
    unbounded.

    D18 WI-12 (Stage 4, agent-ops#415) is pinned separately, in both files.
    `test/landing.test.sh`: `landing_eligible` reads `eligible`, not
    `ineligible`, for a protected path at `agent-merges-all` (deferred,
    never refused, since this classifier alone cannot see the compensating
    controls); `landing_approver_standing_review_at` returns the standing
    review's own state, `submitted_at` and `commit_id` together, at the same
    one reviews read `landing_approver_standing_review` already makes;
    `landing_cool_off_effective_hours`
    resolves the repo-override-else-top-level-else-24 precedence, `0`
    included, exactly as `merge_budget_effective_cap` does;
    `landing_cool_off_remaining_hours` computes the correct remaining time
    (clamped to `0`, never negative) against a pinned `NOW_ISO`, and is
    empty — never `0` — on an unparseable timestamp or duration;
    `landing_protected_path_controls_ok` is `ok` immediately for a pull
    request touching no protected path, refuses naming the tier for
    anything but `critical`, refuses naming the missing timestamp with no
    `submitted_at`, refuses naming both commits (even past a full day
    elapsed) when the standing review's `commit_id` does not match a fresh
    read of the pull request's current head — the push-after-approval case,
    agent-ops#658 — refuses naming the remaining time while the cool-off is
    open once the commits do match, is `ok` once it has elapsed or
    `landing_cool_off_hours` is `0`, and is `unknown` on a re-check that
    cannot read either the changed-file list or the pull request's current
    head;
    `landing_retry_tier` reads the most recent matching `approver-verdict`
    event's own `tier` from the fleet log, the same "several events, keep
    the latest, skip malformed lines, stdin works like a named file" shape
    `landing_retry_source_map` already has pinned. `test/landing-wiring.test.sh`
    lifts the new gate 4.5 in place, stubbed as its own function: never
    consulted at all below `agent-merges-all` (confirmed by an empty call
    log) with the pull request still arming normally; at `agent-merges-all`
    a refusal from the gate — a live cool-off, a non-critical tier, an
    unreadable re-check — arms nothing and is named in `landing-refused`;
    the gate is consulted with this round's own in-process `approver_stage_tier`
    on the ordinary path, and with `landing_retry_tier`'s own fleet-log read
    instead on a direct `_landing_stage_attempt` call with `RETRY` set,
    confirming a re-arm never trusts a tier fact that belongs to a different
    process. `test/approver-wiring.test.sh` covers the tier-forcing half:
    a protected-path pull request launches a real critical-tier engagement
    at every complexity grade, `complexity:low` included (which alone would
    have skipped the model entirely), logging `critical_reason: "protected-path"`;
    the classifier's own exit 2 (an unreadable changed-file list), its
    exit 3 (a `merge_autonomy_protected_paths` list it cannot evaluate
    against a path, TD-PPagop-26082325), and any exit code outside its
    documented 0/1/2/3 contract (agent-ops#1232) each force the same
    critical tier rather than falling back to a cheaper one, pinned
    separately so the exit-code split cannot silently drop one of them —
    the guarding condition names only the legitimate exit 1 as an
    exemption from the forced tier, rather than enumerating the fail-closed
    codes, so an unrecognised code cannot silently join it; a refuse
    streak of two still logs `critical_reason: "refuse-streak"`, so the two
    causes are pinned as distinguishable in the log; and a pull request
    touching no protected path is unaffected, keeping every tier exactly as
    requirement 8s already pins it. `scripts/doctor.sh` warns when a
    repository's own configured `merge_autonomy` is `agent-merges-all` and
    its effective `landing_cool_off_hours` resolves to `0` — the cool-off
    control disabled entirely, the residual risk §7 risk 1 accepts only with
    both controls in force (`test/doctor.test.sh`).

    `scripts/doctor.sh` also warns, separately, when a repository's own
    configured `merge_autonomy` is `agent-merges-routine` or above and its
    resolved `merge_autonomy_protected_paths` (its own `repos[]` override
    when present, else the top-level key) is `[]` — schema-valid, since
    neither carries a `minItems` — naming the repository and its level, on
    the model of the `landing_cool_off_hours 0` warning above
    (TD-PPagop-26082403, `test/doctor.test.sh`): the shipped nine-path
    default draws no warning, a top-level or `repos[]`-level `[]` each draw
    it at `agent-merges-routine` or above, and the same `[]` below that tier
    draws none, since the gate does not bind there either.

    `scripts/doctor.sh` warns when
    a repository's effective `merge_autonomy_routine_sources` names a source
    that repository's own `sources` never gathers, and separately warns when
    that effective list carries any `issues:<band>` entry (agent-ops#519) —
    an entry that can validate clean against the first check (the
    repository's own `sources` list typically does gather that banded
    token) while still never matching a work order once its `source`
    collapses to the plain word `issues` — naming the banded entry and
    `lib/landing.sh`'s own header as the cause, and never firing for an
    unbanded entry (`test/doctor.test.sh`).
    `scripts/doctor.sh` also fails, for every repository at
    `agent-merges-routine` or above (its own *configured* level), a default
    branch with no active merge queue while either `allow_auto_merge` or
    `allow_squash_merge` is off (agent-ops#532) — `landing_arm`'s no-queue
    fallback is `gh pr merge --auto --squash`, a call GitHub refuses
    outright unless both are enabled — reading `repos/$slug` and
    `merge_queue_for_branch` once each per repository and naming in the
    failure which of the two is off together with both fixes (enable it or
    adopt a merge queue); an active queue is `ok` regardless of either
    setting, an unreadable repository and a `repos/$slug` that reports
    neither key or only one of them (GitHub returns both only to a token
    with admin visibility of the repository's merge settings) are each a
    `skip` naming whichever went unreported, and a repository below the
    routine tier is left silent. An **unreadable merge-queue state is a
    `fail`**, alone among this check's bail-out paths and expressly not
    covered by the "never fail for what this run could not check" rule the
    consolidated verdict below still follows: `merge_queue_for_branch` is
    the identical read `landing_arm` performs as its own gate 7, at a level
    this check only reaches because landing is armed, and the `repos/$slug`
    read above has already established that the token can see the
    repository — so a failure here is neither a visibility gap nor an
    unchecked precondition but the landing path itself demonstrated down,
    and the failure names that, both candidate causes (the query in
    `lib/merge-queue.sh` against GitHub's current schema, and the token's
    reach) and the repository it is down for. The consolidated
    autonomy-readiness verdict still reports that repository's
    merge-settings/merge-queue pairing as **unconfirmed** rather than
    missing, since this run established nothing either way about the
    settings themselves. A setting read as a
    definite `false` decides the verdict before the unreported case is
    considered, so an unreadable sibling never masks one doctor did read as
    off. The `ok` states only the settings actually read, since they are a
    necessary condition for that call rather than a sufficient one
    (`test/doctor.test.sh`).
    `./scripts/render-config-table.sh --check` and `./scripts/lint-shell.sh`
    are clean.
8u. **A pull request the arming step already approved once, but could not
    land for a reason that can change without the pull request changing, is
    re-armed without a human's click (TD-PPagop-26081701).**
    Once per cycle, fleet-wide regardless of `--repo` and skipped on
    `--dry-run` (it can land a pull request), for every repository whose
    `merge_autonomy_effective_level` (a *fresh* read, issue #513) is
    `agent-merges-routine` or `agent-merges-all`: every open, non-draft pull
    request carrying `pr_label` whose own `complexity:*` label reads `low` or
    `medium` and whose Approver review is genuinely standing `APPROVED` on
    GitHub right now is offered to `_landing_stage_attempt` (requirement 8d)
    with `RETRY` set — the identical seven gates the round that first approved
    it ran, never a second copy of them, so a `complexity:high` pull request,
    a source outside the repository's own `merge_autonomy_routine_sources`,
    or a protected-path hit below `agent-merges-all` is refused exactly as it
    always was: by `landing_eligible`, on the same terms, every time it is
    asked. At `agent-merges-all`, `landing_eligible` instead reports a
    protected-path hit eligible and defers to gate 4.5 (requirement 8d), just
    as it did the round that first approved the pull request — the sweep
    re-enters gate 4.5 too, and a control it finds unmet there refuses the
    pull request identically. A pull request whose `complexity:*` label
    already reads `high`, or that carries no standing Approver `APPROVED`
    review (ordinary in-flight work, not a stranded approval), is never
    offered at all — cheap, fresh-read exclusions that keep this sweep from
    re-attempting, and re-logging, work the gates below would refuse
    identically every cycle. The one gate this sweep answers differently
    from the original round is the pull request's own `source`: not
    re-derivable from GitHub (there is no field for it, and it is fixed at
    claim time regardless), so `landing_retry_source_map`
    (`lib/union-log-scan.sh`) reads it back from the fleet's own union log's
    `selection` events for that repository, one pass building a
    `{branch: {source, item}}` map — built once for this sweep's whole pass,
    never once per candidate (#1050) — keeping only the most recent event
    when a branch was reused; a pull request whose source cannot be resolved
    this cycle is skipped, never guessed at. Every arm or refusal this sweep produces is
    `landing-armed`/`landing-refused`, the same events requirement 8d's own
    gates always log, additionally carrying `retry: true` so the fleet log
    (and any reader of it) can tell a sweep-driven landing apart from the
    round that first approved it.

    **Neither this sweep nor this round's own arming step ever arms more of
    a repository's stranded pull requests, between them, than that
    repository's remaining merge budget** — `merge_budget_per_day` less what
    it has already landed in the rolling window (PR #557 review, widened in
    review round 2 from a bound private to this sweep's own pass): both call
    into `_landing_stage_attempt` — this sweep, and `run_landing_stage`'s own
    gate 0, run later the same cycle process for whatever repository this
    round's own Implementer worked in — read and grow one cycle-scoped
    `landing_armed_by_repo[SLUG]` map (`agent-cycle.sh`, declared ahead of
    both), rather than a tally private to either. Each, immediately after a
    candidate arms (read off `_landing_stage_attempt`'s own
    `_landing_stage_attempt_armed` global, the one signal that function's
    always-0 exit status cannot carry), grows that repository's own entry and
    passes the running total as `_landing_stage_attempt`'s ALREADY_ARMED
    argument on every subsequent call for the same repository, whichever
    call site makes it. `merge_budget_decide` (requirement 2.3c) discounts
    ALREADY_ARMED from the live merged-PR count before deciding `arm` vs
    `hold`, because GitHub's own record only shows a pull request as merged
    once the merge has actually landed, never the moment either call site
    arms its enqueue or auto-merge — without this shared tally, a repository
    the sweep already armed several pull requests for could still have this
    round's own gate 0 read the same stale not-yet-merged count and arm one
    more past the cap, and the next cycle's own budget read would then see
    more merged pull requests than the cap ever permitted and wrongly trip
    the counting-anomaly freeze (`merge_budget_apply_decision`) against an
    operator who did nothing wrong — the gap a bound scoped to the sweep's
    own pass alone could not close, since it never knew what the other call
    site had armed. ALREADY_ARMED only ever tightens the `arm`/`hold`
    boundary; the `count` and `anomaly` `merge_budget_decide` reports stay
    exactly what GitHub's own merged-PR record read, so a call that holds a
    candidate back on the shared running tally never reports a false anomaly
    for doing so.

    **Neither this sweep nor this round's own arming step ever re-arms a
    pull request GitHub's merge queue has already removed once and nobody
    has re-queued since** (PR #557 review round 2) — gate 6
    (`merge_queue_probe`, requirement 8d) treats a non-null `dequeue_reason`
    as a refusal regardless of which call site asks, distinguishing only the
    refusal's wording via `merge_queue_dequeue_actionable`
    (`lib/merge-queue.sh`): a `manual` removal is the maintainer's own
    deliberate act (re-arming it would silently reverse their click every
    cycle for as long as the pull request stays open), and any other reason
    (chiefly `failed_checks`) is exactly what `scripts/gather-dequeued.sh`'s
    own `dequeued` source (requirement 3z) exists to diagnose and fix before
    a human re-queues — arming it blindly here instead would re-run the same
    failing merge group once per cycle indefinitely, an unbounded CI cost for
    no forward progress. Neither reading is this stage's own to retry: it is
    a different mechanism's pull request from the moment GitHub dequeues it,
    not a gate this stage may reasonably ask again later the way a budget
    hold or an unreadable check list can be.

    `test/landing-wiring.test.sh` pins `_landing_stage_attempt`, called
    directly with a non-empty `RETRY` (bypassing `run_landing_stage`'s own
    gate 0, which a retry attempt has none of), still arms an eligible,
    fully-cleared pull request and marks its `landing-armed` event `retry:
    true`; a `complexity:high` verdict from the classifier still arms
    nothing and marks the resulting `landing-refused` event `retry: true`
    the same way; and the ordinary path through `run_landing_stage` continues
    to log no `retry` field at all. It also pins gate 6's dequeue check for
    both call sites: a `manual` or a `failed_checks` `dequeue_reason` refuses
    arming (worded differently, per `merge_queue_dequeue_actionable`) whether
    reached through `run_landing_stage` or directly with `RETRY` set, an
    empty `dequeue_reason` still arms normally, and gate 0 both reads
    `landing_armed_by_repo[selected_repo]` as ALREADY_ARMED and grows it by
    one after an arm — pinned directly by seeding the map before the call and
    reading it back after. `lib/union-log-scan.sh`'s own
    `landing_retry_source_map` is pinned directly: the most recent matching
    `selection` event's `source`/`item` wins, per branch, when a branch was
    claimed more than once (its two events carrying a different value for
    each field, so the assertion measures which one won rather than passing
    either way), both fields coming off that one winning event rather than
    a per-field reach-back into a superseded one, a different branch
    resolves independently from the same one-pass map, a malformed log line
    is skipped rather than aborting the read, another repository's events
    never leak into this one's map, and an unmatched branch or an
    unreadable/repo-less log both print `{}`.
    `test/landing-retry-sweep.test.sh` lifts `_landing_retry_sweep_repo`
    (`lib/landing.sh`) verbatim — the candidate rule that decides which pull
    requests reach `_landing_stage_attempt` at all, with that function itself
    stubbed to record what it is offered — and pins: below
    `agent-merges-routine` nothing is even listed; a draft, a
    `complexity:high` pull request and one carrying no `complexity:*` label
    at all are excluded before any per-candidate read; a pull request with no
    standing Approver `APPROVED` review is skipped silently, logging nothing
    (ordinary in-flight work, never a stall to report); a source
    `landing_retry_source_map` cannot resolve drops the candidate the same
    way; a pull request a peer node's fleet-wide `pr-<n>` claim currently
    holds (issue #987) never reaches `_landing_stage_attempt` either, logging
    a `landing-retry-sweep-skipped-claimed` event that names the pull
    request, while a candidate the claim listing does not name is still
    offered, and the stubbed `_approver_sweep_claimed_pr_numbers` is
    confirmed called at most once across a pass regardless of how many
    candidates it holds; so is the stubbed `landing_retry_source_map` itself
    (#1050) — built once for the whole pass, never once per candidate;
    a truncated pull-request listing (`github_pr_list_truncated`) logs one
    `warning` naming the repository; and an unreadable default branch falls
    back to `main` while a readable one is passed through unchanged. It also
    pins the bound: across several eligible candidates in one pass, the
    ALREADY_ARMED argument each successive `_landing_stage_attempt` call
    receives is the stub's own running count of how many earlier candidates
    in that same pass it reported as armed — `0` for the first, `1` for the
    second once the first armed, and so on — never reset mid-pass and never
    fed back from a candidate the stub reported as refused; and that this
    running count both starts from and writes back to
    `landing_armed_by_repo[SLUG]`, so a repository this sweep already armed
    candidates for earlier the same cycle (a fixture pre-seeding the map)
    starts its own pass's tally there rather than at a fresh `0`, and the
    map holds the pass's own final count once it returns.
    `test/merge-budget.test.sh` pins `merge_budget_decide`'s own half of the
    bound directly: an ALREADY_ARMED count that pushes `count + ALREADY_ARMED`
    to or past the cap holds rather than arms, while the `count` and
    `anomaly` it reports stay exactly what the (unmodified) merged-PR count
    read — an ALREADY_ARMED-driven hold never reports `anomaly: true` on its
    own.
46. **A pull request cannot rely on the cycle that owed it an Approver
    round to also deliver one (requirement 46, agent-ops#682, #890).**
    `test/approver.test.sh` passes against a stubbed `gh`: `approver_review_
    stale` reads `CHANGES_REQUESTED` with a mismatched commit as stale and
    everything else — an `APPROVED` state, an empty state, an empty commit,
    an empty head — as not, with no `gh` call at all (a pure predicate);
    `approver_newest_commit_authored_at` reads the newest of several
    `authoredDate`s regardless of list order, a single commit as its own
    newest, and returns non-zero printing nothing on an empty commit list, an
    unreadable one, or an empty pull request URL; `approver_dismiss_review`
    issues one `PUT .../reviews/{id}/dismissals` carrying `GH_TOKEN` for that
    one invocation only (never leaking into the caller's own environment,
    the same discipline `approver_post_review` already holds) and the
    message given, never touching the ordinary review-post log, and attempts
    no write at all given no token, a non-numeric review id, or an empty
    pull request URL — reporting GitHub's own refusal as a failure, never a
    dismissal.

    `test/approver-restale-sweep.test.sh` lifts `_approver_restale_sweep_repo`
    (`lib/approver.sh`) verbatim — the candidate rule and routing logic, with
    `_approver_restale_review`, `_approver_restale_dismiss` and
    `_approver_restale_escalate` stubbed to record what they are offered, the
    same split `test/landing-retry-sweep.test.sh` already draws around
    `_landing_stage_attempt` — and pins: a stale review with a commit
    authored after it reaches `_approver_restale_review` exactly once,
    carrying the pull request's own slug, url, branch, complexity and title,
    and never falls back to dismissal or escalation once it reports
    `posted`; the same candidate falls back to `_approver_restale_dismiss`,
    naming the review id resolved from the reviews list, only when
    `_approver_restale_review` reports `unavailable`, and never escalates on
    that pass; the identical candidate, when `_approver_restale_review`
    reports `unposted` instead (agent-ops#988: a verdict was reached — most
    often an adjudication `escalate` — but nothing was written to GitHub),
    falls back to neither dismissal nor a fresh engagement on the very next
    pass — a stubbed `approver_restale_unposted_prior_engagement` fixture
    with no prior event still lets the first engagement through and logs
    `approver-restale-unposted-engaged` naming the review id, while a second
    pass with that event now on the union log, still inside `approver_
    restale_escalate_after_hours` of it, reaches neither
    `_approver_restale_review` nor `_approver_restale_dismiss` again; once
    that first `unposted` engagement is older than the threshold, the same
    pass reaches `_approver_restale_escalate` instead — naming the identical
    review-scoped item ref the no-progress branch below uses, and its own
    `unposted` cause, so the issue a human opens does not claim every push
    since the review was a rebase — and never a fresh
    `_approver_restale_review` call; a stale review with nothing
    authored since it (a rebase-only push) reaches neither
    `_approver_restale_review` nor `_approver_restale_dismiss` — under
    `approver_restale_escalate_after_hours` nothing at all is logged, and
    once the standing review's own `submitted_at` is older than the
    threshold `_approver_restale_escalate` is called instead, naming a
    review-round-scoped item ref (`pr-<n>-approver-restale-<review-id>`),
    the review's own `submitted_at`, never `updatedAt`, and the rebase-only
    cause rather than the `unposted` one; a schema-illegal
    `approver_restale_escalate_after_hours` (reaching jq's `tonumber` and
    erroring) computes an empty cutoff instead, which fails the same way —
    no escalation — but first logs a `warning` naming the config key, the
    raw value and `_approver_restale_sweep_repo`, pinned at both the
    no-progress site and the `unposted`-bound site; a longer configured
    threshold holds the identical review back from escalation; a review
    whose commit still matches the pull request's current head, a draft
    pull request, a currently-`APPROVED` pull request and one with no
    readable head SHA are
    all excluded before any staleness read at all; an unreadable standing-
    review read is skipped silently (ordinary in-flight work, never a
    stall to report); a reviews-list entry for a different login or a
    different `submitted_at` than the one just read never resolves a review
    id, so nothing runs; nothing runs at `merge_autonomy: human` (the
    Approver itself never engages there); and a truncated pull-request
    listing logs one `warning` naming the repository and saying a stale
    review beyond it is not swept this cycle; a pull request a peer node's
    fleet-wide `pr-<n>` claim currently holds (issue #987) reaches none of
    `_approver_restale_review`, `_approver_restale_dismiss` or
    `_approver_restale_escalate`, logging an
    `approver-restale-sweep-skipped-claimed` event that names it, while a
    candidate the claim listing does not name is still offered normally; and
    a repository with a candidate in both the stale and the unreviewed
    trigger in the same pass still calls the stubbed
    `_approver_sweep_claimed_pr_numbers` exactly once, confirming the two
    triggers share the one fetch rather than each asking the registry for
    itself.

    The same harness lifts `approver_unreviewed_prior_engagement` verbatim
    alongside the sweep and pins the unreviewed trigger (agent-ops#890)
    against the constructed case its acceptance criterion 6 asks for —
    ready, non-draft, `pr_label`, zero Approver reviews, past
    `approver_unreviewed_engage_after_hours` — never a live backlog item
    (criterion 7): that candidate reaches `_approver_restale_review` exactly
    once, in `unreviewed` mode, and its engagement is logged as
    `approver-unreviewed-engaged` keyed on the exact head and carrying the
    outcome; a draft, a candidate inside the engage bound, one under a live
    fleet `pr-<n>` claim, one with a standing `APPROVED` review, one whose
    standing-review read is unreadable, and a `CHANGES_REQUESTED` one are
    all left alone (the claim-held and unreadable cases logging nothing); a
    head whose prior engagement reported `posted` is never re-engaged, nor
    is one that reported `unposted` (agent-ops#988), while an `unavailable`
    one is retried; a first engagement at the current head
    older than `approver_restale_escalate_after_hours` with still no
    standing review reaches `_approver_unreviewed_escalate` — naming the
    head-scoped item ref and that first engagement's own timestamp, never a
    fresh engagement — and an engagement recorded at a different head
    neither blocks nor escalates the current one. A schema-illegal
    `approver_restale_escalate_after_hours` at this second check logs the
    identical `warning` and never escalates, falling through to the same
    `last_result` check as before; and a schema-illegal
    `approver_unreviewed_engage_after_hours` logs its own `warning` naming
    the key and value and returns before the trigger's own candidate loop
    ever runs, rather than being indistinguishable from an empty backlog.

    A second harness in the same file lifts `_approver_restale_review` itself
    verbatim, run under `set -euo pipefail` with none of the five globals it
    borrows defined — the sweep's own context, since it runs before the cycle
    has selected any work — and pins that it reaches a verdict rather than
    dying on the unset read, engages `run_approver_stage` under the pull
    request's own slug, its own fresh clone and the synthetic work
    order/Implementer summary/Reviewer summary, reports `posted` in
    `_approver_restale_review_result` when the stubbed stage reaches a
    verdict with `approver_stage_posted` true — even when the stage writes
    its whole transcript to stdout (`--once`) — reports `unposted`
    (agent-ops#988) when the stubbed stage reaches a verdict but
    `approver_stage_posted` is false, reports `unavailable` for a stage that
    reached no verdict at all and for a clone that failed (engaging nothing
    in that case), restores every borrowed global, and tears its recovery
    clone down; called again in `unreviewed` mode it engages the stage under
    a synthetic work order naming `pr-<n>-approver-unreviewed` instead,
    reporting its outcome through the same global.

46a. **A newer authored commit whose diff is unchanged is not genuine
    progress (requirement 46a, agent-ops#1806).** `test/rebase-only.test.sh`
    exercises `lib/rebase-only.sh`'s `diff_patch_id`/`rebase_only_push`
    against a real, local, throwaway git fixture repository — no stubs, since
    this is pure git plumbing: a clean rebase (the same change replayed onto
    a base that moved somewhere the change never touches) reports
    rebase-only; a manually-authored commit that reproduces the pre-conflict
    diff byte-for-byte on the moved base — a different commit entirely, no
    rebase ancestry — also reports rebase-only, pinning that the check is
    about diff content, never commit ancestry; a resolution that changes the
    diff reports not-rebase-only; and an unresolvable ref (a bogus SHA)
    reports not-rebase-only too, with `diff_patch_id` printing nothing for
    it, never guessed at as "unchanged".

    `test/approver-restale-sweep.test.sh` extends its own
    `_approver_restale_sweep_repo` harness (above) with a stubbed
    `_approver_restale_diff_unchanged`, steerable per candidate, and pins: a
    candidate with a commit authored after the standing review but a
    diff the stub reports unchanged reaches neither `_approver_restale_review`
    nor `_approver_restale_dismiss`, and, past `approver_restale_escalate_
    after_hours`, escalates under the same `rebase-only` cause and
    review-scoped item ref the no-progress branch already uses — the
    identical treatment a bare rebase gets, confirming the new gate folds
    into that branch rather than growing a third one; the control case,
    identical except the stub reports the diff changed, still reaches a real
    re-review exactly as every pre-#1806 case in the file does, confirming
    the new gate narrows nothing it should not.
8v. **A D18 rollout stage's own exit criteria are measured, not recalled
    (component 22).** `test/autonomy-stage-report.test.sh` passes: a
    repository at `human` (Stage 0) verdicts `met` once a baseline file
    exists and `merge_autonomy` is configured; a repository at
    `agent-approves` (Stage 1) short of its 15-agent-approved-pull-request
    bar verdicts `not-met (criterion: agent_approved_prs)` even though its
    other criterion (App-verdict/human-action divergence, component 22a) is
    simultaneously `unavailable`, both its pull requests being unreadable
    from GitHub in that fixture — a real failure outranks a merely-missing
    measurement; a `pr_url` counted toward one repository's agent-approved
    count is never credited to a same-prefixed sibling repository (an exact
    `owner/repo/pull/` match, not a substring one). A repository at
    `agent-merges-routine` (Stage 2/3) whose autonomous-landing count and
    revert rate both clear their bars still verdicts `insufficient-evidence`,
    never `met`, because `classifier_escapes` has no detector yet
    (agent-ops#572) — no criterion is ever reported satisfied from missing
    data. The revert-rate criterion reads the *earliest* dated
    `docs/reviews/*-merge-autonomy-baseline.md` as the Stage 0 baseline, not
    a later, worse one placed beside it in the fixture. A fifth repository,
    at `agent-approves` with six agent-approved pull requests — five reading
    clean and one 404ing from the stub — verdicts `divergence: unavailable`,
    never `met`, even though the five it could read alone clear the minimum
    sample and carry no divergence between them: a partial read never
    certifies a zero (agent-ops#661), and its `measured` string still names
    both the settled sample and the pull request left unread.
    `scripts/autonomy-stage-report.sh` passes `shellcheck`.
8w. **The Approver's verdict is paired with the pull request's eventual fate,
    and a divergence is never silently dropped (component 22a).**
    `test/verdict-fate.test.sh` passes: `verdict_fate_posted_review` maps the
    Approver's own verdict vocabulary onto the two GitHub review events the
    Script posts and prints empty for a verdict that reaches neither;
    `verdict_fate_latest_per_pr` collapses a pull request carrying several
    `approver-verdict` events to its single latest by `ts`, excludes a
    verdict whose review never reached GitHub (`posted: false`, or no mapped
    review at all) while reading an event predating that field as `true`,
    matches a repository by exact prefix so a same-prefix decoy is never
    counted, derives `repo` from `pr_url` even for an event carrying no `repo`
    field at all, and carries a pull request with two `APPROVE` verdicts'
    `first_approve_ts` as the earlier one, not the later verdict's own `ts`;
    `verdict_fate_classify` returns each fate and comparison the record's own
    vocabulary names, with a human `CHANGES_REQUESTED` submitted after
    `FIRST_APPROVE_TS` scoring `changes-requested-after-approval`/`divergence`
    even once the pull request later lands anyway, a bot's own
    `CHANGES_REQUESTED` never counting as a human's, and one submitted before
    `FIRST_APPROVE_TS` not counting as "after" it; `verdict_fate_summarize`
    excludes `pending` from both the sample and the rate, and reports
    `insufficient-sample` rather than state a rate below the stated minimum.
    The two are also exercised *together*, on the sequence that defeats
    either read alone: fed `verdict_fate_latest_per_pr`'s own entry for a
    pull request approved, sent a human `CHANGES_REQUESTED`, and re-approved,
    `verdict_fate_classify` still scores
    `changes-requested-after-approval`/`divergence`, and the same call handed
    that entry's latest `ts` instead of its `first_approve_ts` is asserted to
    lose it — the composition, not either half, is where agent-ops#661's
    defect lived.
    `test/verdict-fate-report.test.sh` passes: against a stubbed `gh`,
    `scripts/verdict-fate-report.sh` exits 0 with a silent stderr, prints one
    entry per pull request the Approver ruled on across every fate, counts a
    superseded verdict once and as its later one, excludes a same-prefix
    decoy repository, and honours `--min-sample` and `--since`; one of those
    pull requests carries a human `CHANGES_REQUESTED` between two `APPROVE`
    verdicts, so it records as a divergence only while the wrapper threads
    `first_approve_ts` through to `verdict_fate_classify` — the end-to-end
    guard that a caller cannot quietly drop the window (agent-ops#661).
    `test/autonomy-stage-report.test.sh`'s fourth repository proves component
    22 consumes that join rather than the `unavailable` placeholder it used
    to report: five approved-and-landed pull requests carrying no human
    `CHANGES_REQUESTED` verdict its `divergence` criterion `met`, naming the
    sample the zero is backed by. `lib/verdict-fate.sh` and
    `scripts/verdict-fate-report.sh` pass `shellcheck`.
8x. **The classifier-escape audit recomputes independently, never trusts
    what it is auditing, and never confuses "cannot tell" with "clean"
    (requirement 8e, agent-ops#572).** `test/detect-classifier-escapes.test.sh`
    pins the reimplemented protected-path matching, protected-path resolution,
    routine-sources resolution and routine-complexity resolution in
    `scripts/detect-classifier-escapes.sh`
    byte-for-byte identical to `lib/landing.sh`'s own
    `_landing_is_protected`/`_landing_protected_paths`/`_landing_routine_sources`/`_landing_routine_complexity`
    (D18 Stage 3, agent-ops#724 and agent-ops#725, each pair resolving its own
    key — `merge_autonomy_protected_paths`, `merge_autonomy_routine_complexity` —
    the same repo-override-else-top-level-else-default way), over the same
    battery of inputs, so none of them can drift apart
    unnoticed despite none being sourced; it pins both protected-path
    fallbacks against `config.schema.json`'s own declared
    `merge_autonomy_protected_paths` default as well, since that is the pair
    production rests on — the gate is called with the defaulted config and
    resolves the schema's copy, the detector with the raw `--config` file and
    resolves its own literal; against a stubbed `gh`, a merged
    pull request armed below `agent-merges-all` whose merge commit touches a
    protected path (an injected
    known escape) is reported `classifier-escape` even though it carries a
    `landing-armed` event recording `complexity: low` — the detector's own
    recomputation, not the recorded value, is what disagreed — as are the
    other three ways the recomputation can disagree: a complexity outside the
    repository's own `merge_autonomy_routine_complexity` standing at merge, a
    source outside the repository's routine
    list, and a landing whose own `landing-armed` event records an effective
    `merge_autonomy` level below `agent-merges-routine` even though every
    other input agrees; the same protected-path hit recorded at
    `agent-merges-all`, with every other input agreeing, is instead
    `outcome: "unverifiable"` and never `classifier-escape`, naming the WI-12
    compensating controls it defers to — while a complexity outside that same
    routine-complexity list standing alongside that same unrecomputable hit
    still reports
    `classifier-escape`, naming the complexity rather than the protected
    path, so an independently reconstructable disagreement is never masked by
    one that is not; a
    merged pull request whose recomputed level, complexity, source and
    protected-path check all agree with its having landed is `outcome:
    "clean"`; a merge commit GitHub reports with no `files` array (too large
    to enumerate), a merge commit whose `files` array reaches the 300-entry
    cap (may be hiding more, exactly like the too-large case), a merge with
    zero or more than one `complexity:*` label standing at `merged_at`, a
    `pr_url` with no `landing-armed` event to read a source from, and a
    `landing-armed` event recording no effective level at all are each
    `outcome: "unverifiable"`, never `"clean"` and — for the unrecorded
    level — never `classifier-escape` either, asserted against a
    `config.json` whose own `merge_autonomy` reads `human`, so a detector
    that fell back to current configuration would fail the whole battery
    rather than only this case; a pull request merged by an
    account other than the passed-in Approver login is `outcome:
    "not-approver"`, not an audit finding; and a `pr_url` already carrying a
    `classifier-escape`/`landing-audit`/`landing-audit-skip` event in the
    fleet log — whether a prior audit finding or a prior `not-approver`
    record — is skipped before any `gh` call is spent on it at all, verified
    by the stub logging every call it receives and the test asserting the
    skipped pull request's own number never appears in that log, not merely
    absent from the detector's output. The same stub refuses any call
    carrying `-f`/`-F` fields without `--method GET`, since the real `gh api`
    turns one into a POST — which these endpoints answer 404/422, so a
    detector that read them that way would silently find nothing at all for
    ever. `test/landing-wiring.test.sh` pins the other end of that
    read-back: a successful arm's own `landing-armed` event carries the
    effective `merge_autonomy` level gate 1 judged it against (requirement
    34). `test/escape-audit-wiring.test.sh` pins `agent-cycle.sh`'s own
    translation of an `outcome: "not-approver"` line into its own
    `landing-audit-skip` event, kept apart from `landing-audit` in the
    logged fields. `test/publish-dashboard.test.sh` pins
    `counts.escape_audits`'s aggregation over `classifier-escape`/
    `landing-audit` events only — never `landing-audit-skip` — (all-time,
    not windowed) and the per-row `audit`/`audit_reason` join into the WI-8
    digest's `armed` rows. `./scripts/lint-shell.sh` is clean.

8w. **A repository's autonomy readiness is one verdict, and it never fails for
    what it could not read (component 14, agent-ops#575).**
    `test/doctor.test.sh` passes, over the same single-target-repo fixture and
    `gh`/`rulesets` stubs acceptance check 38g uses. The three new
    preconditions first: at `agent-merges-routine`, a default-branch ruleset
    whose `pull_request` rule reports `dismiss_stale_reviews_on_push: false` is
    a `fail` and `true` an `ok`, both naming the repository and level; a
    ruleset carrying any `bypass_actors` entry is a `fail` naming the count,
    an empty one an `ok`; and both stay silent below the routine tier. The
    Approver App installation's live granted permissions are an `ok` at
    exactly `contents: write`, `metadata: read` and `pull_requests: write`, a
    `fail` naming the gap where one is narrower (`contents is read, needs
    write`) or where a fourth is granted (`issues granted but not required`),
    a `skip` where the installation endpoint does not answer, and silent both
    with no credential in this environment and with nothing configured above
    `human` — exercised through `lib/approver-token.sh`'s real JWT signing
    against a throwaway RSA key and a stubbed `APPROVER_TOKEN_CURL`, so the
    check itself runs for real while no real network is reachable. The
    consolidated verdict then prints once per repository at `agent-approves`
    and above, and not at all at `human` — but which facts it consults
    depends on the printed level. At `agent-approves`, over `ma_approves_config`
    paired with `stub_perm 200 '{"permissions":{"contents":"write","metadata":"read"}}'`
    (a live installation narrowed off `pull_requests: write`), the verdict is a
    `fail` naming `the Approver App installation's live permissions do not
    match exactly what this fleet needs (owner act)`, never an `ok` claiming
    "is fully supported by its forge configuration" while the App cannot post
    a review at all — the ruleset and merge-path facts play no part at this
    level, since `landing_arm` is unreachable below `agent-merges-routine`
    regardless of the ruleset or merge settings. From `agent-merges-routine`
    upward those two join `approver_app_id`/`approver_model_default` and the
    App installation's permissions in the one verdict: `ok` where every
    applicable precondition is satisfied; `fail`, never `warn`, where any is
    not, naming each as an owner act (`no active default-branch ruleset
    requires approving reviews (owner act)`, `no merge queue and
    allow_auto_merge/allow_squash_merge are not both enabled (owner act)`) or
    a configuration error (`approver_model_default is not set (configuration
    error)`); and `skip` where the only gaps are ones this run could not
    read — an unreachable `rulesets` endpoint, and an unreadable merge-queue
    state, each named as unread rather than as never looked at. This
    verdict's own `skip` never raises `doctor.sh`'s exit status by itself:
    for the `rulesets` case the run still exits 0, while an unreadable
    merge-queue state exits 1 on the strength of the pairing check's own
    `fail` (requirement 8t) — a separate verdict answering the separate
    question of whether landing works at all, not this one changing its
    mind about what it could confirm.
8x. **`file_debt`/`file_issue` file what a stage found, and only the Script
    ever writes (requirements 36c, 42a, agent-ops#631, revised agent-ops#874).**
    `test/tech-debt-file.test.sh` passes: `techdebt_file_debt` dedups first
    against the target repository's own open `pw::type:tech-debt` issues by
    normalised title — an exact match, a normalised (case/punctuation-folded)
    match, and a containment match (either direction, both titles at least
    eight normalized characters) all get the new body and provenance as a
    comment on the matched issue rather than a second filing, returning that
    issue's own number/url; a short needle never matches an unrelated long
    title by containment, only by exact equality; an unusable dedup search
    (not a JSON array) is skipped rather than failing the filing; and the
    search itself carries `--limit TECHDEBT_DEDUP_LIST_LIMIT` rather than
    inheriting `gh`'s own default of 30, so a repository with more open debt
    than that page still dedups against all of it. No dedup hit
    creates a fresh issue labelled `pw::type:tech-debt`; a labelled create
    that fails is retried once unlabelled and still succeeds, while an
    unlabelled create that fails returns 1 with no output. A `TOKEN` argument
    reaches every `gh` call; its absence explicitly unsets `GH_TOKEN`
    (`env -u GH_TOKEN`) rather than merely omitting an override, so a value
    this process happened to inherit cannot leak into a call meant to run
    under the ordinary login. No call ever touches `git/refs` or `pr create` —
    there is no id reservation, no branch, and no pull request left in this
    path, so there is nothing to clean up on any failure. `techdebt_file_issue`
    (unchanged) returns an existing issue whose body already quotes the item
    reference rather than filing a duplicate, and fails cleanly when creation
    fails.

    `test/approver-tech-debt-file-wiring.test.sh`,
    `test/enabler-tech-debt-file-wiring.test.sh` and
    `test/merge-observed.test.sh` pass, each lifting its own stage's block out
    of `agent-cycle.sh`/`lib/merge-observed.sh` verbatim (the same technique
    acceptance checks 8s–8w already rely on for the rest of the Approver's
    wiring, and `test/enabler-verdicts.test.sh` for the Enabler's) with
    `techdebt_file_debt`/`techdebt_file_issue` stubbed as recorders: a
    well-formed `file_debt`/`file_issue` on either stage's final JSON calls
    the matching function with the repo, title, body, provenance, and
    (Approver only) the same App token `approver_post_review` already posts
    the review under, then `default_fix`/`owner_decision` in that order, logs
    `tech-debt-filed`/`issue-filed` naming `by: "approver"`/`by: "enabler"`/
    `by: "reviewer"` and the returned `issue_number`/`issue_url` on success,
    and logs a `warning` — never a changed `verdict` — when the field is
    missing a title or body, or when the filing call itself fails. Neither
    field is gated by which verdict accompanies it: an Enabler `unblocked` and
    an Approver `refuse` each still file alongside their own ordinary
    handling, proving the two are independent rather than one silently
    suppressing the other.
8y. **A stage files inline, on its own branch, and a stale pre-#874
    reservation drains itself rather than sitting forever (agent-ops#631).**
    `test/release-pending-reservations.test.sh` passes (requirement 17g,
    component 23f, TD-PPagop-26082427): with no `state_repo` configured, or
    an empty `reservation-releases/` tree, the script is a silent no-op that
    calls `gh` not at all; a marker whose branch delete now succeeds is
    reported `"released"` and its own marker file is cleared; a marker whose
    branch delete fails but a follow-up read confirms the branch already
    gone is reported `"absent"` and its marker is cleared the same way; a
    marker whose delete fails again, while still younger than
    `reservation_release_stuck_after_days`, is reported as a `warning` and
    left in place, unlike the two outcomes above, neither of which leaves a
    marker behind; a marker at least that many days past its own `ts` is
    reported as `reservation-release-stuck` instead, exactly once, with
    `escalated_at` written back onto the marker itself, and a marker already
    carrying `escalated_at` reports nothing at all on a further failed
    delete while the delete is still retried — the escalation fires past the
    threshold and not before, and never twice; with `0` the escalation is
    disabled and however old a marker gets it still reports the ordinary
    `warning`, as does one whose own `escalated_at` write fails, so a
    failed write never claims an escalation that did not persist; a
    malformed marker (missing `repo` or `branch`) is reported as a
    `warning` and left untouched rather than acted on; and two markers
    naming different target repositories, in one invocation, are each
    handled independently.

    Requirements 24b and 30d are covered by
    `prompts/implementer.md`/`prompts/reviewer.md` naming the dedup-search
    step explicitly — `gh issue list -R <repo> --label pw::type:tech-debt
    --search "<working title>"` — before filing a fresh
    `pw::type:tech-debt` issue (read, not executed — an Implementer or
    Reviewer engagement is a live model session this suite does not drive).

8x. **One durable audit record justifies every autonomous landing, and a
    landing with none is an anomaly, not a null (D18, agent-ops#578).**
    `_landing_stage_attempt` (lib/landing.sh) logs `landing-audit-record`
    once, in the same call that logs `landing-armed`, on every successful
    arm — assembled at the moment of arming, never reconstructed later by
    joining separate events at report time. It carries the pull request's
    own number and `review_commit_sha` (the Approver's standing review's own
    `commit_id`, already read at gate 4 — never a fresh read for a fact this
    cheap to reuse; the commit the Approver approved, not necessarily the
    commit that actually merged — `landing_protected_path_controls_ok` is
    the only gate that compares the two against a fresh head read, and it
    runs only at `agent-merges-all` on a protected-path hit, so this field
    alone can never be read as the commit that landed), the effective
    `merge_autonomy` level and whether SLUG's own `repos[]` entry or the
    top-level key produced it
    (`merge_autonomy_resolution_source`, lib/merge-autonomy.sh), the work
    `source` and `complexity` label, the protected-path verdict
    (`clear`/`hit`/`unknown`) and, on a `hit`, the protected paths it hit —
    every changed file the classifier judged protected, never the full
    changed-file list, and an empty array on a `clear` or `unknown` verdict
    (a fresh `landing_protected_paths_hit` read, the same "never more than one
    function call old" discipline gate 4.5's own
    `landing_protected_path_controls_ok` already applies to the same
    primitive, rather than trust gate 2's now-discarded read), the
    Approver's tier/model/verdict/adjudication and this pull request's full
    adjudication history (`landing_approver_adjudication_history`,
    lib/landing.sh — every `approver-verdict` event this pull request ever
    received, not only the one that authorised this landing, read from the
    union of `$union_log` and `${log_file:-}`, deduplicated — on both the
    round that first approves a pull request and a 2.1e landing-retry
    re-arm, so that a peer node's refusal recorded only in `$union_log`
    still appears in the history a first-approval round writes), every
    deterministic gate this function itself just passed with its own
    evidence — including the human-veto gate's own `blocking_reviewers` list
    (`_handoff_blocking_reviewers`'s return at gate 4, always empty here: a
    non-empty list already refused before this line), carried beside that
    gate's verdict the same way the top-level `protected_path` object
    already names the paths it examined, rather than the verdict alone — the
    `merge_budget_decide` object gate 5 already computed
    (`cap`/`count`/`anomaly`/`waiting_backlog`) and would otherwise discard
    the moment `decision == "arm"` was confirmed, and the landing mechanism
    (`enqueued`/`auto-merge`) `landing_arm` actually used. Written to
    `log.jsonl` via the ordinary `log_event`, so it inherits that file's own
    analytics retention (requirement 2.6 — `log.jsonl` is one of the two
    logs `scripts/rotate-logs.sh` never rotates) rather than the transcript
    rotation `state_dir/cycles/<id>/*.out` is subject to.

    `scripts/publish-dashboard.sh`'s WI-8 autonomous-landing digest joins
    each armed row to this record by `pr_url` **and the arming cycle**,
    taking the earliest `landing-audit-record` at or after the arm — never
    the newest at or before, since `_landing_stage_attempt` always writes
    `landing-armed` first and `landing-audit-record` second, moments apart
    from the same call. The cycle carries the whole weight of pairing a
    *second* arm of the same pull request with the right record: on
    timestamps alone, an arm whose record write never completed would
    adopt the next cycle's record for the same `pr_url` and render
    `anomaly: false`, hiding exactly the unexplained landing this panel
    exists to surface. `anomaly: true` marks a `landing-armed` with no
    matching record — reported, never rendered with the silent nulls the
    digest used to fall back to. The older `approver-verdict`-by-timestamp
    join is retained as the fallback for a `landing-armed` from before
    requirement 8x shipped, which can never have a matching audit record:
    it explains that row's tier and verdict where one is locatable, and
    never clears its `anomaly: true`, which the missing record alone
    decides. `dashboard/index.html`'s landings panel adds a Record column
    (`ok`/`missing`) — its own column, beside requirement 8e's `Audit` one
    rather than folded into it — and a summary line naming how many
    landings in the window carry no audit record.

    `test/landing-wiring.test.sh`'s happy path asserts the audit record is
    logged alongside `landing-armed`, naming the pull request number,
    `review_commit_sha`, autonomy level/source, protected-path verdict, empty
    adjudication history (nothing seeded), a passing gate's own evidence, the
    budget object, and the mechanism. `test/landing-audit-record.test.sh` pins
    the record's full shape — every field, a protected-path hit, the
    human-veto gate's own empty `blocking_reviewers` list beside its `clear`
    verdict, and a non-empty adjudication history across a refuse streak —
    and proves
    `publish-dashboard.sh`'s own digest-assembly `jq` reads it correctly
    from a raw synthetic `log.jsonl`: a landing with a matching record
    renders its tier/verdict, and one without is `anomaly: true`.
    `test/dashboard-render.test.sh` asserts the rendered panel shows
    "missing" for an anomalous landing rather than a bare "unknown".

8z. **The untrusted-content framing is present and identical in every
    prompt (requirement 45).** `test/prompt-untrusted-framing.test.sh`
    passes: every shipped stage prompt — `prompts/project-reviewer.md`
    included (docs/spec/review.md R18) — carries the marker-delimited
    block exactly once, and every copy is byte-identical with requirement
    45a's canonical one, which the test lifts from this document at run
    time rather than restating.

45e. **A stage runs as its own Unix user (requirement 45e).**
    `test/stage-boundary.test.sh` passes. Anywhere, it proves that a
    breadcrumb gives back only a github.com pull-request URL and never
    through a link; that removal hands what it cannot finish to the stage
    user; that sharing changes nothing without the `stage` group; and that
    `deploy/docker/stage-exec.sh` strips every forge credential, App
    identity and the notification secret, sets the token broker, the stage
    git configuration and the node's identity, passes stdin and the exit
    status through, removes its own scratch directory, and stops its whole
    process group on a TERM and when its parent is killed. In the node image
    it also proves, across the two real users, that the stage user cannot
    read a file only `agent` can, `agent`'s environment, or write `/app` or
    an unshared directory of `agent`'s; that a forge credential `agent`
    exports never reaches it; that it can run nothing as `agent` but the
    token helper; that it can write a shared workspace, which `agent` then
    removes even after the stage locked part of it; and that a TERM or a
    KILL to a stage's process group leaves none of its processes running.
    `test/forge-token-broker.test.sh` proves the helper mints only for the
    authoring App, from the environ file it is given and not the caller's
    environment, never gives the degrade token when a mint fails, and
    refuses a malformed owner; `test/gh-shim-auth.test.sh` proves the shim
    in a stage presents the broker's token and identity, asks for the
    call's own owner, mints nothing and falls back to nothing.

47. **The rework record matches `docs/FLOW-SCHEMA.md` and is emitted at
    every one of the nine classes' own detector sites (requirement 47).**
    `test/rework-record.test.sh` drives `lib/rework.sh`'s `rework_fields`
    directly — a well-formed evidence object, an unparseable one (degrades to
    `evidence: null` rather than failing), a supplied `attributed_stage` and
    an omitted one (`null`), and `repo`/`item`/`pr_url` present versus
    omitted — and separately exercises each detector's own reduction against
    a canned event stream: `review-gate-checks-read {ok: false}` yields a
    `check-failure` record and `review-gate-checks-degraded` yields none; a
    `claim-lost` with `cause: held`/`pr-held` yields a `claim-race-duplicate`
    record and a `claim-lost` with no `cause` at all, or `cause:
    unreachable`, yields none; a malformed event line in the stream is
    skipped rather than fatal to the reduction. `scripts/lint-shell.sh` is
    clean on every file this requirement touches.

48. **Expensive per-repository gather runs for one repository per cycle,
    offset per node (requirement 48, agent-ops#1106).**
    `test/expensive-gather-cache.test.sh` passes:
    `expensive_gather_pick_repo` picks a never-cached repository over any
    already-cached one, breaks a tie among never-cached repositories on the
    calling node's own offset (`_expensive_gather_node_offset`, a stable
    `cksum` hash of `node_name` reduced modulo the repository count) rather
    than slug ascending — two node names that hash to different offsets
    pick different slugs against the identical never-cached pair, and the
    same node name picks the same slug again on a re-run — and picks the
    oldest cache file once every configured repository has one;
    `expensive_gather_cache_load` round-trips a saved
    object exactly, a band past `MAX_ARG_STRLEN` (131072 bytes) included, and
    reads a zero-byte or corrupt cache file as absent — not `{}` — logging a
    `warning` that names the slug; `expensive_gather_pick_repo` treats that
    same zero-byte or corrupt file as never-cached (epoch 0), so it is picked
    again the very next cycle rather than waiting out a full rotation;
    `expensive_gather_cache_save` is atomic (no stray `.tmp` file survives
    it), refuses (non-zero, no write) an empty or non-object third argument,
    and a single-repository set (`--repo`) always picks that repository; and
    a configured set whose sorted candidate lines outgrow one pipe buffer
    still picks cleanly under the caller's own `$(…)`-under-`set -e` shape
    rather than dying 141 on the `sort`'s SIGPIPE (agent-ops#806's shape —
    the assertion runs its caller as a separate process, because a subshell
    in a `||` context has its own `set -e` suppressed and would pass either
    way). `test/repo-entry-build.test.sh` still passes unchanged for the
    per-repo entry-build block's own eight-band shape, and additionally pins
    `lib/candidate-gather.sh`'s expensive-gather cache-save build itself,
    lifted the same way: per requirement 4g, its nine values (the eight
    bands plus `issues_excluded`) reach `jq` on stdin, never in argv, so a
    band past `MAX_ARG_STRLEN` — agent-ops's own raw `tech_debt` band has
    reached 421,622 bytes — round-trips through the real save+load intact
    rather than the build dying silently at `execve` and leaving a 0-byte
    cache (agent-ops#1107). `test/issue-state-reapply.test.sh` passes:
    `issue_state_reapply` (lib/candidate-select.sh) drops a candidate the
    sampled source-state digest reports assigned or `blocked`-labelled,
    reporting `"assigned"` or `"blocked-label"` and giving `"assigned"`
    precedence when both apply; leaves an unsampled candidate untouched;
    folds a fresh drop into a prior `issues_excluded` set — a fresh drop's
    own reason winning a clash with a stale cached one for the same number,
    and a `null` prior with no fresh drop staying `null` rather than a false
    `[]` — without ever dropping a prior entry whose own issue is no longer a
    candidate; and the cached-branch wiring in `gather_ordered_repos`
    (lib/candidate-gather.sh) calls it only when this cycle's own
    `gather_source_state` sample reports `ok == true`, otherwise leaving a
    replayed band unfiltered by this reapplication. `scripts/lint-shell.sh`
    is clean on every file this requirement touches.

49. **The item lifecycle record matches `docs/FLOW-SCHEMA.md`, the join key
    reaches every site requirement 49 names, and the fold balances
    (requirement 49).** `test/item-lifecycle.test.sh` drives
    `lib/item-lifecycle.sh`'s `item_lifecycle_fold` directly against one
    fixture per terminal fate (`landed` via `merge-observed`, `voided` via an
    unresolved `item-void`, `superseded` via `orphan-branch-released
    {reason: "superseded"}` with its item derived from an `agent/<N>`
    branch, `abandoned` via `draft-obsolete-flagged`, `blocked` via an
    unresolved `attempt-failed`, `open` via a bare `first-seen`), the flow
    invariant balancing (`totals.balanced`) on a fixture carrying every fate
    at once, a voided-after-landed contradiction landing in `unaccounted[]`
    with its reason — and its mirror image, voided-before-landed, resolving
    to `landed` outright, not treated as a contradiction — an item carrying
    both a standing block and a draft-obsolete-flagged event resolving to
    `blocked`, never `abandoned`, `--since` bounding the population but never
    the fate an included item resolves to (an item entering the population on
    one within-window event still reports `landed`/`abandoned` from
    merge/draft-obsolete-flagged evidence that sits before the bound), a
    landed item carrying a later item-scoped event (a second `pr-raised`)
    resolving `fate: "landed"` with `reworked_after_landed` present and naming
    that event and its own timestamp, an ordinary landed item with no later
    activity carrying no `reworked_after_landed` field at all, and the
    degradation cases a malformed line, a missing field, an event naming
    no item, and an event whose `repo` is valid JSON but not a string all
    yielding a conforming report rather than aborting. The same
    test file drives `item_lifecycle_pickup_pairs` directly against a fixture
    carrying a bare, valid-JSON scalar line ahead of its object lines,
    asserting pairing is computed from the object lines rather than collapsing
    to the all-zero fallback the way an unguarded `.ts`/`.event` index on the
    scalar would. `test/pickup-metrics.test.sh` passes unchanged, exercising
    `item_lifecycle_pickup_pairs` indirectly through `scripts/pickup-
    metrics.sh`'s own unchanged CLI and output shape.
    The same test file also proves the de-duplication property requirement
    2.6d states: two nodes' own logs carrying overlapping events for the
    same item are each unioned with the other's via `fleet_logs` (requirement
    2.5, `lib/fleet.sh`), and the fold over each node's own resulting union
    is asserted byte-identical to the other's — the general "two nodes
    folding the same union produce identical record sets" property — and
    concatenating both folds' `records[]` and reducing by `{repo, item}`
    leaves exactly one record per item, never two.
    The join key itself — `{repo, item}`, present whenever the emitting site
    knows both and omitted, never `null`, otherwise — is pinned at each
    producing site by lifting the real code: `test/stage-budget-apply-join-
    key.test.sh` (`stage-start`, including the fleet-wide-REPO omission
    case), `test/stage-end-join-key.test.sh` (`agent-cycle.sh`'s own two
    item-scoped `stage-end` sites, the Implementer's and the Reviewer's,
    which `stage_budget_apply` does not write and the test above therefore
    does not reach), `test/pr-raised-join-key.test.sh`, `test/checks-green-join-
    key.test.sh` (`checks-green` and `review-gate-checks-read`, both call
    sites of each), `test/standdown-sweep-join-key.test.sh`
    (`issue-closed-post-merge` and `merge-observed` as wired from
    `scripts/sweep-closed-issues.sh`'s own actions), and dedicated
    assertions in `test/landing-wiring.test.sh` (`landing-armed`/
    `landing-refused`, and the new `merge-observed` at `lib/landing.sh`'s own
    arm site — fires only once `pr_merge_state` confirms a synchronous merge,
    never on an enqueued arm), `test/landing-retry-sweep.test.sh`
    (`landing_retry_source_map`'s own `item` field), `test/approver-wiring.test.sh`
    (`approver-verdict`), `test/human-reviewer-handoff-wiring.test.sh`
    (`pr-ready`, both call sites) and `test/sweep-closed-issues.test.sh`
    (the sweep's own `merge-observed` action, bounded by `pr_search_limit`
    and de-duplicated per node across repeated runs of the same window, and
    a seen-file write the sweep cannot perform reporting a `warning` action
    rather than losing the memo silently).
    `scripts/lint-shell.sh` is clean on every file this requirement touches.

50. **The node time-state record matches `docs/FLOW-SCHEMA.md`, a `node-state`
    transition reaches every site requirement 50 names, and the invariant
    balances (requirement 50).** `test/node-time-state.test.sh` drives
    `lib/node-time-state.sh` directly: `node_time_state_for_cause` against
    every one of the sixteen closed-vocabulary tokens, including the three
    translated rather than renamed (`raced`/`pre-claimed` to `peer-claimed`,
    `untraceable` to `coordinator-declined`) and an unrecognised
    cause (maps to nothing, never a guess); `node_time_state_idle_split`
    against a positive eligible count, a zero count and an unreadable one;
    `node_state_for_stage` against the Implementer and Reviewer (`producing`)
    and every other actor (`overhead`); and `node_time_state_fold` directly
    against a fixture exercising all six states across two nodes at once,
    asserting: the flow invariant (`balanced`, `expected_total_seconds`,
    node-count x window) holds; a node absent for part of the window, and one
    absent for the whole of it, both score `down` for exactly the ungoverned
    stretch, never more or less; widening the window with `--until` extends
    the last transition's own interval rather than truncating it; two
    overlapping event streams for one node — an `agent-cycle.sh` run and a
    `review-cycle.sh` run, unioned exactly as `scripts/node-time-state.sh`
    unions `log.jsonl` and `review-log.jsonl` — still sum to exactly one
    window's worth of seconds for that node, never double-counted, however
    the two streams interleave; and the degradations this requirement's own
    acceptance names: an unrecognised `state` value lands in
    `unaccounted_seconds` rather than being dropped or misclassified, an
    `idle-with-demand` event with no recognised `cause` counts under
    `unspecified` rather than a guessed one, a malformed raw line does not
    abort the fold (dropped before it ever becomes a candidate event,
    uncounted), and an event naming no node, or whose `ts` is present but
    fails `fromdateiso8601`, is excluded and counted under `skipped_events`
    rather than silently vanishing or aborting the whole fold to the
    fallback all-empty shape. Each of the three
    translated-not-renamed causes' own assertions (`raced`/`pre-claimed` to
    `peer-claimed`, `untraceable` to `coordinator-declined`)
    pins the translation's output distinctly from its input, which is what
    proves the original `stand-down`/`claim-lost` event's own field stays
    untouched — the translation happens only on the `node-state` event
    beside it, never in place.

    The same test also pins the silence rule at the sites most able to break
    it quietly, both structurally and end to end. Structurally, it scans
    `review-cycle.sh` for every `set_node_state_terminal` call appearing
    ahead of the implementation-cycle check and asserts each is followed
    immediately by `suppress_node_state_if_peer_owns_node`, plus that exactly
    six such sites exist — so the scan cannot pass vacuously, and a seventh
    ending added later cannot slip through unguarded. Behaviourally, it runs
    the real `review-cycle.sh` against a shim node (symlinks back into the
    tree with a `config.json` of its own, the harness
    `test/review-not-before.test.sh` established) held off by
    `repository_review.defaults.not_before`, and asserts all three readings:
    with a live process named in `lock.json` the stand-down logs its own
    event and **no** `node-state` transition at all; with no `lock.json` it
    logs `idle-without-demand`/`no-demand` as before; and with a `lock.json`
    naming a pid that is gone it logs it too — which is what proves the guard
    is suppressing on the peer rather than swallowing the transition
    wholesale. The live and gone readings are then repeated against
    `review-lock.json`, for the peer *review* run the second probe answers
    about, and a fourth case pins the one guarded site that runs after the
    lock is won: with a usage-limit cooldown in force and this run's own pid
    in `review-lock.json`, the cooldown stand-down still logs
    `externally-blocked`/`usage-limit`, which is what proves that probe
    excludes this process itself rather than reading its own lock as a peer.
    `scripts/lint-shell.sh` is clean on every
    file this requirement touches.

