## Requirements

### The Enabler — requirements, continued (part 2 of 2; 36f–38g: **The delegate mandate (D18, PR #1389, recommendation 3 of…)

36f. **The delegate mandate (D18, PR #1389, recommendation 3 of
    `docs/reviews/2026-09-11-escalation-autonomy-review.md`).** The fourth rung of
    `escalation_autonomy`, `decide-with-veto`, including everything
    `decide-tactical` reaches (requirement 36d) and widening it in exactly
    two places. Same pass (`run_enabler_decide`,
    `prompts/enabler-decide.md`), same tier (`enabler_model_critical`,
    falling back to `enabler_model`), same per-reason bound and cap, same
    decision log and veto (requirement 36e). One field of the pass's runtime
    input differs: `mandate`, `"tactical"` at `decide-tactical` and
    `"delegate"` at `decide-with-veto`, and it is the only thing that tells
    the pass which of the two reaches below are open to it. Every pass at
    this rung is logged as the same `enabler-adjudication` event carrying
    `pass: "decide-tactical"` that requirement 36d's own passes are, which is
    what keeps one bound over both: the two rungs are one ladder position
    apart, and a repository moved between them must not find its per-reason
    bound and its cap suddenly unspent.

    **What the delegate mandate reaches, and nothing else.** Written once
    here and referenced — never restated — by `prompts/enabler-decide.md`,
    the same discipline requirement 36a's own boundary keeps:

    - **(a) Condition 2's acceptance clause alone.** Accepting a residual
      exposure or a residual risk in a repository the installation itself
      owns — the private state repository's unreachable-object tail
      (agent-ops#1310/#1298) is the case this was measured against — where
      the item's filer already named a `## Default` (requirements 36c, 42a,
      39d) and where nothing the decision takes mints, rotates, edits or
      grants a credential, a secret, a GitHub App, a ruleset, a permission,
      an organisation or account setting, or an account. Every other part of
      condition 2 stays owner-only at this rung, exactly as at every other.
    - **(b) Human corroboration of a void**, for the three pull-request item
      shapes requirement 34k actually closes: `pr-<n>-abandoned-<head-sha>`,
      `pr-<n>-review-<review-id>` and `pr-<n>-superseded-<head-sha>`. A
      `decide` verdict may carry `act: {"kind": "corroborate-void"}`, and
      that act says the thing requirement 34d cannot establish from any API
      call: this draft is genuinely unwanted. `pr-<n>-conflict-<head-sha>`
      and `pr-<n>-dequeued-<head-sha>` are never reachable — requirement 34k
      excludes them by construction, the void on those shapes is about the
      conflict or the dequeue rather than about the pull request, and closing
      one discards live work of ours (TD-PPagop-26080901).

    Conditions 1, 3, 4, 5, 6 and 9 of requirement 36a are owner-only at
    every rung including this one; condition 7 stays owner-only wherever the
    account is genuinely not held; condition 8 is already narrowed by
    requirement 36a's "undefined thresholds are set, not asked" reading and
    is not widened further here.

    **A verdict carrying an act is out of mandate at `decide-tactical`.**
    `run_enabler_decide` refuses it there and returns `escalate` with
    `evidence` naming the act, on the same reading it gives a `decide`
    verdict missing its own `decision`/`rationale` (requirement 36d): a
    verdict this system may not act on is not a decision, whatever it called
    itself. It refuses the same way, at either rung, an act whose `kind` is
    not `corroborate-void`, and a `corroborate-void` act on an item whose id
    is not one of the three shapes above. Each refusal names the act, so the
    escalation the human then receives says what the pass proposed.

    **The act waits out a veto window, and nothing else about the decision
    waits.** A `decide` verdict that carries an act is recorded as
    `decision-taken` (requirement 36d's own fields) with two more: `act`, the
    verdict's own object, and `act_after`, the event's own time plus
    `decision_veto_window_hours`. It files its `pw::decision` log issue
    exactly as any other decision does, and the body carries the act and the
    `Acts after:` instant so the lever a reader is offered is one *before*
    the fact. It does **not** unblock the item, does not release
    `needs_refinement_label`, does not re-record an existing refinement and
    posts no comment on the item's own thread: nothing about it is final
    until the act runs, and the `enabler-examined` event's `outcome` is
    `decision-pending` rather than `unblocked`. A `decide` verdict carrying
    **no** act is unchanged at this rung — a pure acceptance, reach (a)'s
    own shape, unblocks the item immediately exactly as at `decide-tactical`,
    because nothing irreversible happened and requirement 36e's
    reopen-to-veto re-block is the whole of the correction it needs.

    **A pending act with no log issue is abandoned, not taken.** Filing the
    log issue is best-effort for an ordinary decision (requirement 36e): the
    decision stands, only without a lever. Here it is not: an act nobody
    could veto is the one thing this rung must never take, so a failed
    filing costs the *decision* — a `warning` says so, nothing is recorded
    on `decision-taken`, and the item escalates to a person with the pass's
    own evidence appended the ordinary way (requirement 36d's `escalate`).
    This is why `pending_decision_acts` (`lib/cycle-state.sh`) can key on the
    log issue's own number without a gap: a pending act without one cannot
    exist to be found.

    **Performing the act.** `run_pending_decision_acts` (`lib/decision-veto.sh`),
    one per-cycle fleet-wide sweep called from `agent-cycle.sh` immediately
    *after* `run_decision_veto_sweep` — in that order, so a reopen this cycle
    has just discovered cancels the act rather than racing it — reads
    `pending_decision_acts` off the union log: every `decision-taken` event
    carrying an `act`, an `act_after` and an `issue_number` that no later
    `decision-acted` or `decision-vetoed` event has retired. For each whose
    `act_after` has passed, in the order they were decided and capped at
    three per cycle (the overflow reported as a `warning`, never silent, the
    same bound every sweep beside it keeps), it re-reads the log issue's own
    state live and:

    - **still `CLOSED`** — performs the act, then logs `decision-acted`
      (`repo`, `item`, `issue_number`, `issue_url`, `act`, `outcome:
      "performed"`) and the ordinary `unblocked` (`by: "enabler"`, `reason`
      naming the decision);
    - **open** — does nothing and logs nothing. The reopen is the veto, and
      `run_decision_veto_sweep` owns the record of one;
    - **unreadable** — refuses the act for this cycle and logs a `warning`
      naming the issue. The act is irreversible and the window is not, so an
      unreadable lever fails closed here — the opposite direction from
      requirement 36e's own unreadable-events read, which fails open toward
      honouring a veto, and for the same reason: both protect the owner's
      ability to stop a decision.

    An `act_after` that does not parse leaves the decision pending rather
    than acting early, and an act whose `kind` nothing performs is a
    `warning` and no act — unreachable input, since `run_enabler_decide`
    already refused every kind the mandate does not name, and therefore a
    defect if it is ever seen.

    **`corroborate-void` is the item's void, and nothing more.** Performing
    it writes one `item-void` event through requirement 33's shared field
    shape (`item_event_fields`), `stage: "decision"`, `detail` the decision
    itself and `evidence` naming the log issue, the delegate mandate and the
    window it stood through, plus `decision_issue_number`/`decision_issue_url`.
    Requirement 34k's own pass then closes pull request `<n>` on the next
    pre-extract window that reaches it, through
    `scripts/close-void-github-items.sh`, with no change to that script
    beyond admitting `decision` to its corroboration gate — the void record
    and the close both already existed, and the corroboration was the only
    thing missing. This is requirement 34d's second writer outside the shared
    guard (the first being the Script's own pre-flight, requirement 34m): the
    guard has nothing to corroborate it *with*, because what corroborates it
    is the decision, the log issue nobody reopened, and the window that
    elapsed. Requirement 34k's one-shot rule, its `stage` gate, its action
    cap and a human's plain re-open all apply to it exactly as to any other
    corroborated void.

    **A veto cancels a pending act, and says so.** When
    `run_decision_veto_sweep` records a `decision-vetoed` for a log issue
    `pending_decision_acts` still names, it also logs `decision-acted` with
    that act and `outcome: "cancelled"`. The retirement itself is already
    mechanical — the pending set excludes anything a veto names — but a
    pending act that merely stopped appearing would leave no record that the
    reopen is what stopped it, and a cancellation the owner cannot see is
    not the lever this rung promised. Everything else requirement 36e's veto
    does is unchanged.

    **Requirement 8f is untouched.** `lib/landing.sh` checks the configured
    level for `adjudicate-first` exactly, so a Reviewer's own open question
    behaves at `decide-with-veto` precisely as it does at `decide-tactical`:
    at `adjudicate-first`'s own behaviour, never a further widening. That
    exception to "each rung includes the one below it" is stated once in
    requirement 36d's own extended note and holds unchanged for this rung.
37. **Failure containment.** The Enabler must never change a cycle's outcome.
    A timeout, a non-zero exit, or an unparseable final message produces the
    stage's `stage-end`, a `warning`, and **no state events at all**: no
    verdict was reached, so nothing is recorded about any item, and gc is
    what allows the retry. The cycle's exit code is the one
    it had before the engagement, and every step of the engagement — each `gh`
    call, each parse — tolerates its own failure, because this code runs inside
    the exit trap where an unguarded non-zero status would cost the cycle its
    `cycle-end` event, its lock release and its state-sync push.

    An exit that leaves an unparseable final message gets requirement 9e's
    salvage attempt first — the engagement's own session, resumed once, asked
    for nothing but its verdicts — before this requirement's silence takes
    over; a timeout or non-zero exit has no session to resume and goes
    straight to it. Only once that also comes up empty does the `warning` name
    every item that was in this engagement (`items: [{repo, item}, …]`), so a
    human reading the log can see what was lost without cross-referencing the
    claim registry, and each of those items' 35c tombstone is backdated with
    `lib/claim.sh expire` rather than left to age out at the full
    `claim_ttl_hours` — `gc` (requirement 2.1a, every cycle) retires it on its
    very next sweep instead. This is deliberately not a release: 35c's own
    design-decision note already explains why releasing a failed engagement's
    claim outright would let the very next cycle re-engage the same
    still-unchanged items at Opus prices for nothing, and `expire` keeps that
    bound while shortening the tombstone's floor from `claim_ttl_hours` to
    about one cycle interval.

    A usage-limit phrase in the transcript still goes down requirement 10's
    ordinary path (`limit-hit`, `fleet/limit.json`), because a limit belongs to
    the whole fleet and not to this stage. A claimed item the model never
    mentions, and a verdict the Script does not recognise, are `warning`s: the
    item stays blocked and the log is the only place a stage that routinely
    omits items would ever become visible.

38. **Human-visibility.** Whatever the configured escalation ladder leaves for
    the human — every item `escalation_autonomy`/`merge_autonomy` did not
    settle earlier, not a fixed universal — must be visible to them: on
    `github.com/pulls/review-requested` for a pull request, on Assigned-to-me
    for a genuine Enabler escalation (requirement 36a), on a filtered issue
    list (`blocked`/`blocked:needs-refinement` — requirement 38b) for a
    Co-Ordinator-, Refiner- or Implementer-recorded refinement block — not
    merely recorded in the pipeline's own log. A 2026-08-07 pipeline-flow
    review found neither guarantee held: no currently-open pull request
    carried a live review request (every prior request had been consumed by a
    submitted review), and the one genuine human-decision block in this
    repository (#203) was unassigned, so it never appeared on Assigned-to-me
    either.

    Today this membership test is still, in practice, every item the ladder
    leaves over: `run_enabler_adjudication` (D18, agent-ops#627) runs inline,
    in the same cycle as the `escalate` verdict that triggers it, so no item
    is ever durably parked awaiting adjudication and there is no non-person
    waiting state for this requirement to cover. #668's landing gate is what
    would first change that — it holds a pull request across cycles on an
    unresolved open question, with its own adjudication explicitly not
    same-cycle — and is the point at which this membership test would
    genuinely need widening; revisit it there, not before.

38a. **A ready pull request's live review request is kept, not only made
    once.** `lib/handoff.sh`'s `ensure_human_reviewer(pr_url, assignee)`
    covers the case `confirm_review_requested` (requirement 31b) does not:
    nobody's `CHANGES_REQUESTED` is blocking the pull request, so there is no
    blocking reviewer to re-request from, and yet the human may still not have
    been *asked* — a first review nobody has given, or an approval nobody has
    acted on since (poetic-fiddle #170: approved, green, and idle 6.8 days,
    because CODEOWNERS' request is consumed the moment the review is
    submitted and nothing asks again). Requesting review from someone who has
    already approved withdraws nothing they said; it only puts the pull
    request back in the one queue a human actually watches.

    The target is whoever has ever reviewed the pull request, in any state
    (`_handoff_known_reviewers`), before it is ever `assignee`
    (`enabler_assignee`). That order is load-bearing, not stylistic: this
    system's own pull requests are authored under the same account
    `enabler_assignee` routinely names — issue assignment has no such
    conflict, pull-request review does — and GitHub refuses a review request
    aimed at a pull request's own author with a 422. CODEOWNERS already solved
    that once, automatically, the moment the pull request went ready; reading
    who it already picked is both correct and one API call. `assignee` is the
    fallback for a pull request CODEOWNERS never touched at all.

    Between those two, an already-pending review-request entry (GraphQL's
    `reviewRequests`, one query shared with every other per-pull-request read
    in this file since agent-ops#1085; two separate REST fields,
    `requested_reviewers` and `requested_teams`, before it) is its
    own candidate source, read before `assignee` is ever considered: it is
    what a fresh CODEOWNERS auto-request leaves behind before anyone has
    reviewed, which `_handoff_known_reviewers` — reviews *submitted*, not
    requested — cannot see. Omitting this check misread three of this
    system's own pull requests (agent-ops #350, #353, #355): each already
    carried a live request for `Warwick-Allen`, this repository's
    human-review identity, made by CODEOWNERS the moment the pull request
    opened, but with nobody's review submitted yet and `assignee` equal to
    the author (`warwickallen`, this repository's commit and comment
    identity), `ensure_human_reviewer` fell all the way to `skip\tno-candidate`
    — a live human review request already sitting on the pull request,
    reported as if none existed. A non-empty pending list at this point
    already answers the requirement — a human has already been asked — so it
    is reported `already`, not requested again.

    The author is struck off the candidates whichever list proposed them,
    before anything is asked, and a request left with no candidate — nothing
    known, nothing pending, and `assignee` equal to the author — is a `skip`
    rather than an attempt: a 422 is not a transient failure worth a `warning`
    every cycle, it is a fact about the configuration that will not change
    tomorrow, and one invalid login fails the whole POST rather than its own
    entry — so an unfiltered author would take the real reviewer down with it.
    The filter applies to the reviews list too, not only to `assignee`:
    GitHub closes `APPROVE` and `REQUEST_CHANGES` to a pull request's author
    but leaves `COMMENT` open to them, and a Reviewer's own findings may be
    filed that way — `prompts/reviewer.md` offers `gh pr review --comment` for
    them — under the account that raised the pull request. The pending list
    needs no author filter: GitHub never lets a review request name the pull
    request's own author to begin with. It does carry the same *bot* filter
    the reviews list applies: a bot-type account (GraphQL's `__typename`,
    belt-and-braces alongside the same `[bot]`-suffix test the reviews list
    uses) sitting in the pending review-request list is never read as proof a
    human was asked — this org runs Copilot code review, and a repository
    ruleset can auto-request it into this exact list, which would otherwise
    answer the requirement without ever asking a human
    (tech-debt/TD-PPagop-26081403.md). It also reads a requested team, not
    only a requested user — one field, `reviewRequests`, since agent-ops#1085
    (two separate REST fields, `requested_teams` and `requested_reviewers`,
    before it): a requested team is extended the same review-request
    mechanism CODEOWNERS gives a named human, and a team can never itself be
    a bot, so this function and requirement 38e's own read of the same rule
    (`scripts/gather-human-visibility-hygiene.sh`'s `no_candidate` re-check)
    count a pending request the same way.

    The no-candidate `skip` carries its own detail, `skip\tno-candidate`,
    distinguishable from the other two `skip` reasons — a draft, or something
    `CHANGES_REQUESTED`-blocking it — which `confirm_review_requested` already
    covers with its own actor and its own clock. Nothing else will ever ask
    this human, so the periodic sweep (requirement 38c) reads the distinction
    to log its own `warning`, closing the gap tech-debt/TD-PPagop-26081001.md
    recorded: before this, all three reasons shared one bare `skip`, so this
    one could not be told apart from the other two to surface at all.

    Called from both places `confirm_review_requested` already is — the
    Reviewer's own handoff and the Enabler's `complete_handoff` — whenever
    that call answers `none`, and from the periodic sweep of requirement 38c
    below, so the guarantee holds whether or not any stage touches the pull
    request in a given cycle. A `failed` result is a `warning` on the
    `pr-ready` event, on the same terms requirement 31b's own re-request
    failure is: the pull request is finished and visible, only a notification
    is missing.

    The pending review-request read this candidate rule and
    the POST's own re-check both depend on (`_handoff_pending_review_
    targets`) tells a GitHub rate-limit refusal — REST before agent-ops#1085
    moved this read onto GraphQL, and `github_limit_kind` (`lib/github-
    limit.sh`) recognises both phrasings — apart from any other
    read failure at that one call site (agent-ops#1082): where
    `github_limit_kind` (`lib/github-limit.sh`) — reused, not reclassified —
    names the failure a rate-limit refusal, `ensure_human_reviewer` prints
    `failed-rate-limited` in place of the bare `failed` above. Every one of
    the three call sites that reads that answer treats it as a failure the
    same way the bare `failed` is, and names GitHub's rate limit as the cause
    in the warning it already logs: the Reviewer's own handoff and the
    Enabler's `complete_handoff` (both `pr-ready` warnings, which stay
    identical to each other), and requirement 38c's sweep (its
    `could not request review from …` warning, whose prefix is unchanged so
    requirement 38e's own classification of it is unaffected). An operator
    reading the log can then tell "no human was notified because the owner's
    shared GitHub API budget was gone" from a real fault, which a bare
    `failed` could not say — and no site may answer the new state with
    silence, which would be worse than the indistinguishable warning it
    replaced.

38b. **A Co-Ordinator-recorded block gated on a human decision is labelled
    `blocked` and by reason, not only by class.** Requirement 34e projects the
    `needs-refinement` label onto the issue behind a `needs_refinement`
    report, but that label alone matches nothing on a human's filtered issue
    list unless they already know to look for it — agent-ops#203 was exactly
    this shape (labelled correctly, effectively invisible) until fixed by
    hand. From 2026-06 to 2026-08 this requirement closed that gap by
    *assigning* `enabler_assignee` to the same issue, mirroring the label's
    lifecycle; agent-ops#639 replaced that assignment with two further
    labels, applied and removed exactly where the assignment used to be:

    - `blocked` — the generic hold marker `scripts/gather-issues.sh` already
      excludes on (requirement 16.4's deterministic half), so the item is
      unselectable through the same mechanism a human's own hand-applied
      `blocked` label already uses, not a second one alongside it;
    - `blocked:<reason>` — naming *why*, derived from the block's own `kind`
      (and, for a future block class this projection does not cover yet,
      `stage`): `blocked:needs-refinement` for `kind: "needs-refinement"`,
      the only kind this projection has ever covered, since every block
      `record_needs_refinement_block` records — the Co-Ordinator's own report
      (requirement 16a), the Refiner's decline (requirement 39d), or the
      Implementer's escape hatch (requirement 9f) — carries that kind.
      `lib/refinement.sh`'s `refinement_blocked_reason_label` is the whole of
      this taxonomy today, a one-entry table rather than a placeholder: a
      future block class that earns its own reason label extends that
      function's `case`, not this projection's callers.

    Both are fixed, unconfigurable names, like `blocked` itself always has
    been — there is nothing here for an installation to rename or disable, in
    contrast to `needs_refinement_label` alongside them. `record_needs_refinement_block`
    applies `blocked:<reason>` through `refinement_label_add` (the same
    primitive `needs_refinement_label` uses) unconditionally, because no human
    reaches for that compound name on their own — but applies `blocked`
    through `refinement_label_project` instead (agent-ops#651), which reads
    the issue's labels before writing: `lib/labels.sh`'s own catalogue still
    documents `blocked` as the human's own, hand-applied control, so an
    unconditional add-and-record would let `release_refinement_label` later
    remove a `blocked` a human applied for their own reasons before this block
    existed — the same defect the deleted `refinement_assignee_project` once
    existed to prevent, moved from the assignee list to the label list.
    Whichever of the two actually landed — `added` for a genuinely fresh
    label, never `present`, which the projection leaves unrecorded — is kept
    as `blocked_label`/`blocked_reason_label` on the block's `attempt-failed`
    event (`refinement_block_fields`'s third and fourth arguments) so
    `release_refinement_label` can take them off again — via
    `refinement_blocked_label_targets`, read from the block record exactly as
    `refinement_label_targets` is — the moment the block clears, by the same
    three paths that already release `needs_refinement_label`. Best-effort,
    like that label: a failed application, or a read that fails outright
    (`unrecorded`, applied best-effort but not recorded — over-holding
    `blocked` is cosmetic; removing one that may have pre-existed is the
    defect this exists to prevent), is a `warning`, and the block is recorded
    regardless.

    **This requirement never assigns anything.** Assignment stays reserved
    for requirement 36a's own, genuine escalations — a *separate* issue a
    human must personally act on — which is the only assignment this
    pipeline makes of any issue, anywhere, since agent-ops#639. That is what
    closes the ambiguity requirement 16.4's own note describes: before
    agent-ops#639, an assigned issue reaching that exclusion could be a
    genuine escalation, a human's own claim, or this requirement's
    bookkeeping, with no reliable way to tell the three apart from the
    assignee list alone; now it is always one of the first two.

    **Migration** (agent-ops#639). Every block this requirement projected an
    assignment onto before that change still carries `needs_refinement_assignee`
    on its own, already-written `attempt-failed` event — nothing here rewrites
    history — so `scripts/sweep-legacy-refinement-assignees.sh` finds every
    still-open block whose event carries that field, removes the stale
    assignment (`refinement_assignee_remove`, the one function this
    requirement's old mechanism left behind, kept for exactly this) and
    applies the `blocked`/`blocked:needs-refinement` pair this requirement
    would have applied instead — `blocked:needs-refinement` unconditionally,
    the same as the fresh path; `blocked` through the same read-before-write
    `refinement_label_project` the fresh path uses (agent-ops#651), so a
    pre-existing `blocked` on a legacy issue is left exactly as found rather
    than reapplied — all best-effort and idempotent — safe to re-run,
    including from a cron job or a future cycle, since every step is a no-op
    once already done and the matching set only ever shrinks as blocks
    clear. Run once against every configured repository as part of landing
    agent-ops#639 (21 assignments cleared by hand on 2026-08-21, ahead of
    this fix; 14 more had accumulated in `Poetic-Poems/agent-ops` alone by
    the time this script ran against it). A block recorded *after*
    agent-ops#639 landed never carries `needs_refinement_assignee` in the
    first place — `record_needs_refinement_block` never sets it — so the
    script's matching set can only ever be the pre-existing backlog, never a
    growing one.

    **The migration script refuses a degraded union rather than project onto
    one** (agent-ops#994, TD-PPagop-26082602). `blocked_items` already
    excludes an item the moment its own LOG_FILE carries a later `unblocked`
    event for it — a plain read, keyed on the events' own `ts`, immune to
    file order — so this script can only ever act on stale data by being
    handed a LOG_FILE that has not yet absorbed a peer's clearing write. That
    is what happened to issue #597, #598 (`unblocked … by: label-removed`)
    and, most visibly, #602 (`unblocked … by: enabler` at 07:52:09, the
    script's own run at 12:45): the union fed to the 2026-08-21 migration run
    had not caught up. `scripts/sweep-legacy-refinement-assignees.sh` takes
    an optional PEERS-DIR (and FETCH-MINUTES) argument for exactly this: when
    given, and LOG_FILE is a real path rather than stdin, the whole run is
    gated on `fleet_logs_healthy` (`lib/fleet.sh`) — the identical guard
    requirement 38b's own live reconciliation below trusts for the same
    question — refusing outright (rather than reconciling partially) when the
    union is empty or the peers directory's freshness marker reads stale.
    This is a precondition, not a cure: a union inside the fetch cron's own
    interval still reads healthy and can still be missing a clear from the
    last few minutes, and PEERS-DIR is optional, so a caller that omits it
    gets the unguarded pre-agent-ops#994 behaviour unchanged. What it does
    catch is the shape #602 actually was — a run launched against a union
    that was already known-degraded, not merely a little behind.

    **The reason label is released at block-clear time regardless; the
    generic `blocked` needs the sweep's own log to be released the same way**
    (agent-ops#651, agent-ops#999). The reason label needs no proof of
    provenance: no human reaches for `blocked:needs-refinement` on their own,
    so the sweep can only ever have applied it, unconditionally, and the
    record alone — `needs_refinement_assignee` present, neither blocked-label
    field set — is enough for `refinement_blocked_label_targets` to offer it
    up wherever it would otherwise be left on the issue forever once the
    block cleared. `blocked` is different: it *is* a name a human reaches for
    (`lib/labels.sh`'s own catalogue), which is exactly why the sweep projects
    it through the read-before-write above rather than an unconditional add.

    Which of `added`/`present` a given run actually saw is recorded the same
    way `record_needs_refinement_block`'s own `added` result is —
    `own-label-action add` (`label_own_action_fields`, `lib/label-marker.sh`)
    — when the caller passes `scripts/sweep-legacy-refinement-assignees.sh`
    its optional fifth argument, OWN-LOG-FILE: this node's own persistent log
    (`state_dir/log.jsonl`, never LOG_FILE itself, which may be a synthesized
    fleet union this node cannot usefully write to). Neither call rewrites
    the block's own historical `attempt-failed` event — nothing rewrites
    history — so a legacy block's `blocked_label` field is never filled the
    way a fresh block's is; the provenance instead lives in OWN-LOG-FILE's own
    `own-label-action` history, which `refinement_blocked_label_stale`
    (agent-ops#651's own log-keyed reconciliation, described below) already
    reads for exactly this question. Once that record exists, `blocked`
    reaches the same retry path the reason label always has: the moment the
    block clears — the reason label released, successfully or not —
    `blocked`'s own logged `add` with no later `remove` makes it eligible, and
    `lib/candidate-gather.sh`'s unconditional per-cycle sweep removes it
    within one cycle.

    A run made without OWN-LOG-FILE has nowhere to write that record, so
    `added` and `present` stay indistinguishable to every later reader, the
    same as before agent-ops#999: `refinement_blocked_label_targets` never
    offers a legacy block's generic `blocked` for removal at *the moment its
    block clears* — over-held rather than guessed at, the same trade-off
    `refinement_label_project` already makes for an unreadable label list —
    and `refinement_blocked_label_stale` has no history to retry it from
    either. Inferring the fixed pair for every legacy block regardless of
    provenance — which is what this requirement once did — would let
    `release_refinement_label` remove a `blocked` a human applied for their
    own reasons on any issue that also happens to carry a still-open
    pre-agent-ops#639 block: the exact defect `refinement_label_project`
    exists to prevent. A *fresh* block landing on the same issue later does
    not release an over-held `blocked` either, because `refinement_label_project`
    finds the label already `present` and so records nothing for that block
    to give back. A legacy block the sweep has not reached yet costs one `gh`
    call that finds nothing to remove, best-effort like every other call on
    that path.

    The live reconciliation below lifts a no-OWN-LOG-FILE run's over-hold for
    two cases: an issue still carrying its `blocked:<reason>` label at the
    moment that reconciliation next runs, since that label is the whole of
    what puts an issue in front of it (agent-ops#816 — the reason label's own
    removal never happened either, so the pair is still standing and comes
    off together), and one whose reason label *did* come off when the block
    cleared, leaving a bare `blocked` with nothing left to bring the issue back
    in front of a `blocked:<reason>` listing at all (agent-ops#1832,
    TD-PPagop-26082608's residue — resolved for a run that passed
    agent-ops#999's OWN-LOG-FILE argument, but not for one that could not,
    because that argument did not exist yet when it ran). The second
    reconciliation below closes that residue for the second case.

    **The reconciliation sweep for a removal that silently failed**
    (agent-ops#651). Unlike `needs_refinement_label`'s hand-flag path
    (requirement 39f), `blocked`/`blocked:<reason>` have no live-GitHub
    attribution to make: nothing but this pipeline ever applies them — a
    human's own `blocked` is exactly what `refinement_label_project` above
    already keeps out of `blocked_label`, so it is never mistaken for this
    system's to remove — so a logged `own-label-action add` with no later
    `remove` for a given repo/item/label is proof enough on its own that a
    removal is ours to retry, with no `labelled_at` comparison or skew
    tolerance required. `lib/refinement.sh`'s `refinement_blocked_label_stale`
    takes the current `blocked_items` extract and the shared log, and returns
    every `blocked`/`blocked:<reason>` whose own-label-action history's most
    recent action is `add` for an item no longer in that extract — i.e. the
    block cleared, but nothing proves the label came off. `agent-cycle.sh`
    retries `refinement_label_remove` on each, unconditionally and every
    cycle (guarded only by requirement 12's dry-run switch, the same as every
    other label write here) — not gated on `needs_refinement_label` being
    configured, since neither label depends on it. Otherwise a
    `release_refinement_label` removal that failed the moment its block
    cleared would never be retried again: `scripts/gather-issues.sh` would
    keep excluding the issue forever (requirement 16.4's deterministic half),
    invisibly, the same permanently-stuck-hold class of failure agent-ops#639
    ended for the assignment-based mechanism.

    **The live reconciliation for a label history cannot see**
    (agent-ops#816, TD-PPagop-26082602). The sweep just above is blind to two
    cases, both real: a `blocked:<reason>` applied by
    `scripts/sweep-legacy-refinement-assignees.sh` run without its own
    OWN-LOG-FILE argument (see below — with it, the sweep's own `added`
    result is logged exactly as `record_needs_refinement_block`'s is, and
    this cohort does not arise), and one whose block cleared before
    agent-ops#651's `own-label-action` logging existed to record the add at
    all. Both leave a label standing with no `add` in the log for the sweep
    to key on, so `scripts/gather-issues.sh` excludes the issue forever,
    invisibly — the same class of failure the log-based sweep exists to end,
    reopened on the one path that cannot prove its own history.

    `lib/refinement.sh`'s `refinement_blocked_label_orphaned` closes it a
    different way, needing no history for the *reason* label at all:
    `blocked:<reason>` is never a label a human reaches for on their own (the
    same fact the fresh path's unconditional add already relies on), so its
    live presence on an open issue this repo's currently-open blocks do not
    name is proof enough on its own that it is stuck. `lib/candidate-gather.sh`'s
    per-repo gather loop runs it wherever `sources` configures the `issues`
    band, ahead of `scripts/gather-issues.sh` itself so an issue this frees
    becomes a candidate the same cycle: one `gh issue list --label
    blocked:<reason> --state open` call, compared against
    `blocked_items`. It rides on that band's own fresh read, so requirement
    48 narrows it to the one repository this cycle expensively gathers: a
    stuck pair on any other configured repository is released on that
    repository's own next turn — bounded by one rotation, never indefinite,
    unlike the page cap below — which is a delay this reconciliation can
    afford, since a label stuck long enough to be orphaned has by then been
    stuck for far longer than a rotation. An issue
    that never carried the reason label is never
    read by this call at all, so a standalone hand-applied `blocked` — #402,
    #677, #678 among them — is untouched by it, the same guarantee the fresh
    path's `refinement_label_project` gives at the moment of application.
    Guarded by requirement 12's dry-run switch, like every other label write
    here, and gated on the reason label being configured at all — today
    always true, since `refinement_blocked_reason_label` names exactly one
    kind. The listing states its page cap (`GITHUB_PR_LIST_LIMIT`) rather
    than inheriting `gh`'s undeclared default, and warns when it comes back
    at that cap: a stuck pair past the page is simply not released this
    cycle, and because the listing is newest-first while a stuck label is by
    nature an old one, that miss does not clear itself on a later pass
    either.

    The generic `blocked` label needs a second proof before it rides along,
    added on the PR #823 review's own concern 3: a live-labelled issue's most
    recent `attempt-failed` event of this kind — open or long since cleared —
    is consulted (`lib/refinement.sh` reads it off the same union log every
    other reader here does), and `blocked` is released only when that event
    either predates agent-ops#639 (it carries `needs_refinement_assignee` and
    neither blocked-label field — the genuinely history-less, legacy-swept
    cohort this requirement exists for), or explicitly records this pipeline
    as having added `blocked` itself (`blocked_label` set, the same field
    `refinement_blocked_label_targets` above reads at block-clear time). A
    modern event whose `blocked_label` field is empty did not record this
    pipeline applying the label: either `refinement_label_project` found it
    already present — a human's own hand — or it never got as far as
    recording an application (the `unrecorded` verdict, whose own warning at
    block-record time already says the label will not be removed when the
    block clears). Neither proves the label ours, so `blocked` is left alone
    for that issue even though the reason label still comes off: the same
    over-hold `refinement_blocked_label_targets` already applies to a block
    still open, extended here to one already cleared. No history at all for
    an issue (neither a legacy nor a modern record survives to be read) falls
    back to the reason label's own proof alone, exactly as this requirement
    read before PR #823's review.

    Two more conditions gate the whole reconciliation, both added on that
    same review. First, `union_log_healthy` (`lib/fleet.sh`'s
    `fleet_logs_healthy`, computed once per cycle ahead of the per-repo
    loop): this is the one reader in the cycle that turns a *silent* union —
    `fleet_logs` returns nothing at all when `$state_dir/log.jsonl` is absent
    and the peers directory is empty, which a fresh node before its first
    state-sync, a mirror just discarded and rebuilt (requirement 2.5's own
    corruption path), or a failing fetch cron all produce — into "no block
    exists" rather than "no block is visible from here", so it is the one
    reader such a silence actively misleads. `fleet_logs_healthy` refuses to
    let it: an empty union, or a peers directory `fleet_peers_stale` (lib/fleet.sh,
    #990) calls stale — its freshness marker records the last fetch as
    failed, or an `ok: true` marker whose `ts` is older than the configured
    threshold (a dead fetch cron that never logged a failure) — is unhealthy,
    and so is a union the snapshot could not build (requirement 2.5's
    `union_build_ok`, #2037), whatever part of it was written; in each case
    the whole reconciliation for that cycle is skipped with one warning
    logged (not one per repo, since every repo shares the one union and the
    one peers directory). Second, a grace window against `union_log_horizon`
    (requirement 39f's own snapshot horizon): a peer node can apply this
    exact label pair within seconds of logging the block that justifies it,
    while that log line reaches this node only through the fleet's periodic
    state-sync — up to a full fetch interval behind — so a label applied too
    recently for its own block record to plausibly have arrived yet is
    deferred rather than stripped. The reason label's own `labelled_at` (read
    per candidate issue off its GitHub timeline, the same endpoint
    `scripts/gather-hand-flagged-refinements.sh` already reads, with the
    latest of the matching applications picked *outside* the `--jq` filter
    rather than inside it — `gh api --paginate` re-runs that filter once per
    page and this endpoint pages at thirty, so an in-filter aggregate reads
    one stamp per matching page on a long timeline, per TD-PPagop-26081306;
    the two gathers that still do it that way are TD-PPagop-26082701) is
    compared against `union_log_horizon` with `LABEL_OWN_GRACE_SECONDS`
    (`lib/label-marker.sh`) tolerance — the same constant requirement 39f
    already measures a peer's label writes against that horizon with, reused
    rather than duplicated. An unresolvable `labelled_at` (a failed timeline
    call) defers the same as a too-recent one: this mechanism only ever acts
    on a positive, aged proof, never a missing one.

    **A second live reconciliation reaches the cohort the first cannot see at
    all** (agent-ops#1832). The reconciliation above is fed by
    `gh issue list --label blocked:<reason>`, so an issue whose reason label
    already released normally when its legacy block cleared never reaches it —
    the reason label is exactly what is missing. It is missing from the
    issue's *live* labels, though, not from its history: GitHub keeps a
    `labeled` event for a label since removed, so the sweep's own application
    of `blocked:<reason>` stays readable on the timeline long after the label
    itself came off. That event is this cohort's proof.

    `lib/refinement.sh`'s `refinement_blocked_label_stranded_candidates` names
    the cohort from the log alone — every item in the repo whose most recent
    `attempt-failed` record has the legacy shape and whose block has since
    cleared — and `lib/candidate-gather.sh` runs a second `gh issue list
    --label blocked` in the same per-repo turn, excluding anything still
    carrying the reason label live at that moment (already the first
    reconciliation's own to reach, whether or not it already has this same
    cycle). Only an issue in both sets costs a timeline read: `blocked` is a
    hand-applied human control, so most issues carrying one can never be this
    path's to claim, and reading their timelines first would spend a paginated
    fetch on each of them every cycle for good. Each survivor's timeline is
    read once per (repo, item) per process, the same memoisation the first
    reconciliation makes, and yields both of that issue's own stamps: when its
    `blocked` and its `blocked:<reason>` were each last applied.

    `refinement_blocked_label_orphaned` takes these as a fifth, optional
    argument (`STRANDED_JSON`, `[{"number": …, "labelled_at": …,
    "reason_labelled_at": …}]`) and, for each entry whose matching
    `attempt-failed` record is the legacy shape (the same
    `needs_refinement_assignee`-present, neither-blocked-label-field test the
    first reconciliation already uses), compares the two stamps against *each
    other* within `LABEL_OWN_SKEW_TOLERANCE_SECONDS` (`lib/label-marker.sh`,
    requirement 39f's own clock-skew tolerance, reused rather than
    duplicated) in either direction. The sweep applies the reason label
    (unconditionally) and `blocked` (projected, read-before-write) in one
    invocation, seconds apart, so a `blocked` the sweep applied itself sits
    within that tolerance of the reason label beside it; a `blocked` it found
    already present it never applied at all, so that issue's stamp is the
    human's own and falls outside. The record's own `ts` is deliberately not
    what either stamp is measured against: this cohort's block was recorded
    before agent-ops#639, while the sweep that labelled it first existed in
    that same commit, so record and application are weeks apart by
    construction. A candidate whose two stamps are far apart, whose matching
    record is modern rather than legacy, that carries no matching record at
    all, or either of whose stamps cannot be resolved, is left alone —
    over-held, the same direction every other unprovable case in this
    reconciliation already takes; unlike the reason label, a bare `blocked`
    has no live-state proof of its own to fall back on, so absence of proof
    here is never read as proof of absence. `refinement_label_remove` retries
    a proven survivor the same way the first reconciliation's does, logging
    its own `own-label-action remove`.

38c. **An idle, approved pull request is nudged, not left silent.** For every
    open, non-draft, `pr_label`-carrying pull request in every configured
    repository — fleet-wide, like the sweeps of requirements 17b and 34i,
    regardless of `--repo` — `scripts/sweep-human-visibility.sh` runs once per
    cycle and, per pull request:

    - where nothing is `CHANGES_REQUESTED`-blocking it, ensures
      `ensure_human_reviewer` (requirement 38a, kept continuously rather than
      only at the moment of handoff);
    - where something *is* `CHANGES_REQUESTED`-blocking it, the round has
      already been answered — a marked reply from the Implementer after the
      blocking review, and only that signal (see below) — and the pull
      request's checks are genuinely green (`_sweep_checks_green`, the same
      test the idle nudge below applies, shared rather than duplicated),
      repeats requirement 31b's re-request (`confirm_review_requested`). An
      answered round whose checks are *not* green is left entirely alone,
      exactly like an unanswered one: this call stands in for the Reviewer's
      own `ready` verdict (see below), and that verdict itself never fires
      without requirement 31c's green precondition already holding, so
      replaying only the "answered" half of it and skipping the "green" half
      would re-request a human's review on a pull request whose next actor is
      still the pipeline (agent-ops#338). The checks-green test is evaluated
      first, off the same `pr view` payload already read for the round check
      below, so a not-green pull request never even asks whether the round
      was answered — it is a silent no-op, costing no further reads;
    - where the pull request is approved, `MERGEABLE`, not `BLOCKED`, every
      check genuinely green (an empty `statusCheckRollup` is excluded
      explicitly — that is CI not having run, not CI having passed — while a
      `SKIPPED` `CheckRun`, which every target repository carries on every
      pull request, is accepted alongside `SUCCESS`/`NEUTRAL`), and has been
      since before `human_nudge_idle_hours` ago, posts one nudge comment naming
      `enabler_assignee` — unless one is already there, which a comment
      carrying both the exact `<!-- agent-ops:human-nudge -->` marker and
      `lib/pipeline-marker.sh`'s own `PIPELINE_COMMENT_MARKER_PREFIX` stamp
      makes idempotent rather than merely time-windowed. Neither condition
      alone is a safe test: a comment merely discussing the mechanism (a
      Reviewer summarising a change to this sweep, say) can quote the literal
      marker string without being the nudge itself, and the marker prefix
      alone is stamped on every pipeline comment, nudge or not — so a
      conversation comment can never disable a future nudge (agent-ops#390).
      `human_nudge_idle_hours` of `0` disables the nudge only; the
      review-request self-heal above (both halves) is unconditional.
      "Approved" is `_handoff_pr_approved`'s own verdict
      (`lib/handoff.sh`) — derived from the reviews list, the same "latest
      review per reviewer" computation `_handoff_blocking_reviewers` already
      applies for the `CHANGES_REQUESTED` half — never GitHub's own
      `reviewDecision`: that field is computed against the base branch's
      *required* approving review count, and where a repository's ruleset
      sets that to `0` — this repository's own, agent-ops#391 — it never
      becomes `APPROVED` however many humans approve, so a gate reading it
      directly could never fire here. An unreadable reviews list is a
      `warning`, the same fail-safe default every other read in this script
      gets.

      `MERGEABLE` and not `BLOCKED` are two separate reads, and both are
      required: `mergeable` answers the merge-*conflict* question alone
      (`MERGEABLE`/`CONFLICTING`), while whether GitHub would let the merge
      happen at all is `mergeStateStatus`. Since `_handoff_pr_approved`
      reports "approved" on the *first* standing approval, a base branch
      requiring two or more would otherwise be nudged — "only waiting on your
      merge click" — while GitHub was still waiting on a second approval. No
      configured repository requires more than one today, so this is
      correctness in general rather than a live fix, and it costs nothing
      where the required count is `0`: an approved, green, up-to-date pull
      request there reads `CLEAN`, exactly as an unapproved one does, and a
      required merge queue (all three target repositories carry a
      `merge_queue` rule) does not read `BLOCKED` either, so requirement 38f's
      own states stay reachable. Every other state — including an `UNKNOWN`
      GitHub has not finished computing — falls through, the fail-open
      direction the merge-queue probe already takes, since suppressing a
      legitimate nudge is the worse of the two mistakes.

    This *is* the periodic, deterministic audit of requirement 38's own
    guarantee, made self-healing rather than merely reported: a violation this
    script can fix, it fixes in the same pass, so there is never a gap between
    detection and correction for a human to fall through. What it cannot fix —
    a listing or a read that fails — is a `warning`, never a silent skip; and
    a `warning` that does not clear on its own becomes ordinary selectable
    work rather than sitting unread in the log (requirement 38e). Skipped on
    `--dry-run`, like every sweep that writes.

    A pull request something is `CHANGES_REQUESTED`-blocking, but whose round
    is not yet answered, is left entirely alone — the sweep must not
    re-request on the strength of `reviewDecision` alone. Re-requesting an
    *unanswered* round inverts the queue — the human is asked to re-look at a
    pull request whose next actor is the pipeline — and, because requirement
    3c's candidate rule reads a review-requested timeline event as the round
    having been *answered* (`scripts/gather-review-feedback.sh`, the
    events-not-timestamps fix), it would also drop the pull request out of
    the Implementer's own review-feedback selection while the human's
    `CHANGES_REQUESTED` sat unanswered — PR #205's silent-starvation failure,
    reintroduced cycle after cycle and fleet-wide.

    The discriminating judgement is `lib/handoff.sh`'s
    `handoff_round_answered` (requirement 34a) — the same predicate
    requirement 3c's candidate rule uses — called here with the timeline
    signal omitted: only a marked reply from the Implementer counts as
    `answered`, never a `review_requested` event, because this call's own
    re-request would otherwise read back next cycle as the round having
    answered itself. `unanswered` and `unknown` (a read this script could not
    make, reported as a `warning`) are both left alone; only `answered`
    repeats the re-request. This closes the gap `tech-debt/TD-PPagop-26080804.md`
    recorded: a `ready`-verdict re-request that `agent-cycle.sh` lost to a
    crash between the Implementer's push and the Reviewer's verdict now heals
    on the sweep's next pass rather than sitting unrequested indefinitely.

    The tri-state is asymmetric, and the implementation must fail towards
    `unknown`: `answered` is the verdict that *acts*, so a verdict reached by
    accident costs the queue inversion and the silent starvation above, where
    the same accident landing on `unknown` costs one warning and a retry next
    cycle. Anything `handoff_round_answered` cannot compute — an empty
    blocking timestamp, an argument that is not a single JSON array, an
    extraction that errors — is therefore `unknown`. That places a
    requirement on its callers' reads: `gh api --paginate` emits its `--jq`
    filter's result once per page as separate documents, so an aggregate
    written inside the filter is computed per page and disagrees with itself
    past the endpoint's thirty-item default, and two documents satisfy a
    `type == "array"` check before failing the extraction. Both of
    `_sweep_round_answered`'s reads therefore stream one object per line and
    slurp with `jq -s` afterwards, as `_handoff_blocking_reviewers`
    (requirement 31b) does. `scripts/gather-review-feedback.sh`'s four reads
    do not yet, which is recorded as `tech-debt/TD-PPagop-26081306.md`; the
    predicate's `unknown` is what keeps that failure on the safe side of the
    line meanwhile.

    The Script logs what the sweep did under the sweep's own event names —
    `human-review-requested`, `human-nudged` and `human-dequeue-notice`
    (requirement 38f), each carrying the `repo` swept and the `pr_url` acted
    on — exactly as requirement 17b's sweep logs `orphan-branch-recovered` /
    `orphan-branch-released`, and deliberately not as `pr-ready`. The idle
    nudge and the dequeue notice are logged under distinct event names rather
    than sharing one, so requirement 38e's reduction can tell which of the
    two actually resolved a given pull request's warning rather than reading
    either as proof of the other. A sweep
    action is not a handoff: the Publisher's outcome ladder
    (`docs/spec/dashboard/README.md`) reads a `pr-ready` anywhere in a cycle as "this
    cycle got a pull request to ready" and ranks it above every other reading,
    so a `pr-ready` logged for a re-request on some other repository's
    long-since-ready pull request would rewrite the recorded outcome of a cycle
    that stood down or selected nothing.

38d. **Scope note.** Requirement 38 does not extend the same guarantee to
    every conceivable class of human-blocked work — an `escalate` verdict
    (requirement 36a) was already assigned and labelled before this
    requirement existed, and remains the canonical path for a decision only a
    human can make. What requirements 38a–38c add is continuity (the guarantee
    holds between the moments a model-driven stage would otherwise renew it)
    and one further origin (a Co-Ordinator's own `needs_refinement` report)
    that previously reached only a label. This scope limit is deliberate and
    stays a limit: requirement 38e (below) closes the *other* gap 38a–38c left
    — a violation the sweep finds but cannot itself heal — without extending
    the guarantee to either of these already-otherwise-handled classes.

38e. **A violation the sweep cannot heal is selectable work, not only a log
    line.** `scripts/sweep-human-visibility.sh` (requirement 38c) fixes almost
    every violation it finds in the same pass; what it cannot fix — a `gh`
    read, the review-request POST, or the nudge-comment POST itself failing,
    or requirement 38a's own no-candidate `skip` (no POST even attempted,
    tech-debt/TD-PPagop-26081001.md) — was, before this requirement, only a
    `warning` event: no selectable work,
    nothing tracking whether it recurred, and the human it concerns by
    definition not looking (tech-debt/TD-PPagop-26080801.md, the gap
    requirement 38d's scope note names). `scripts/gather-human-visibility-hygiene.sh`,
    run for every configured repo whose `sources` include `human-visibility`,
    closes it:

    - `lib/human-visibility-hygiene.sh`'s `human_visibility_violations` reduces
      the log union (`union_log`) to one entry per identity — a pull request's
      `pr_url` where the warning named one, the bare `repo` for a listing
      failure that named none — replaying each identity's events in order and
      keeping one standing violation, exactly as `blocked_items`/`void_items`
      (`lib/cycle-state.sh`) keep the latest attempt-failed/item-void per
      item: a `warning` always becomes the new standing violation, regardless
      of what preceded it. A later `human-review-requested`, `human-nudged` or
      `human-dequeue-notice` event for the same identity — the sweep
      succeeding next time — only clears it when the two share a *family*
      (`review-request`, `nudge` or `dequeue-notice`, matched from the
      warning's own detail text against which action produced the success):
      three distinct actions can fire for one pull request in a single sweep
      pass (requirement 38f), and succeeding at one proves nothing about
      whether either of the other two would have — a dequeue notice posting
      successfully must never clear a same-pass `could not request review
      from …` warning (agent-ops#393). A warning shape none of the three
      families recognises (most often the read failure that gates every
      downstream check for that pull request) keeps the wider rule instead:
      any of the three success events clears it, since each depends on that
      same read having worked. An unrelated warning — a different identity,
      or a different family with the family unmatched — never clears
      anything.
    - The Script appends this cycle's own freshly-logged human-visibility
      events into `union_log` the moment the sweep (requirement 38c) finishes,
      the same technique requirement 34j's own reconciliation uses, so a
      violation this cycle's sweep just found is caught this same cycle rather
      than sitting one cycle behind its own detection.
    - For each repo with at least one violation, `gather-human-visibility-hygiene.sh`
      re-verifies every one live before treating it as a candidate, read-only
      throughout — never `confirm_review_requested` or `ensure_human_reviewer`
      (`lib/handoff.sh`), which POST. A repo-level listing failure only
      survives if the listing still fails right now. A pull-request violation
      first survives only while that pull request is still open and not a
      draft, then survives its own warning class's own live check: a
      `could not request review from …` warning survives only while no human
      review is currently requested or already given (`gh pr view --json
      reviewRequests,reviews` — a pending `reviewRequests` entry, once
      filtered of a Bot-typed or `[bot]`-suffixed one the same way
      `ensure_human_reviewer`'s own pending read is (requirement 38a,
      tech-debt/TD-PPagop-26081403.md; here the filter is defensive, keyed
      on `__typename` first — `gh pr view`'s exporter emits only
      `__typename`-keyed `User`/`Team` entries and drops Bot reviewers from
      the array entirely, so a Copilot-only request already arrives as `[]`;
      see Gotchas) — a requested team counts, neither
      reader's filter can ever drop one — or a non-bot review with state
      `APPROVED` or `CHANGES_REQUESTED` already exists, is the request having
      worked after all. This is read from the reviews list, never
      `reviewDecision` (agent-ops#391, TD-PPagop-26081505): that field is
      computed against the base branch's *required* approving review count,
      and on this repository's own ruleset, which sets that count to `0`, it
      can never become `APPROVED` however many humans approve, so a check
      keyed on it directly could never fire here — the same reasoning
      requirement 38c's own `_handoff_pr_approved` read already applies); a
      `could not post the idle nudge comment` warning survives only while no
      comment carries both the exact `<!-- agent-ops:human-nudge -->`
      HTML-comment form and `lib/pipeline-marker.sh`'s own
      `PIPELINE_COMMENT_MARKER_PREFIX` stamp on the same comment — the same
      conjunction `scripts/sweep-human-visibility.sh` itself checks for
      (agent-ops#390, #428); neither alone is safe, since the HTML form alone
      still matches a comment merely discussing the marker and the stamp
      alone is on every pipeline comment, nudge or not;
      a `no legal review-request candidate` warning (requirement 38a's
      `skip\tno-candidate`, tech-debt/TD-PPagop-26081001.md) survives only
      while `gh pr view --json author,reviews,reviewRequests` still shows no
      non-author, non-bot, submitted review, no review request already
      pending under that same bot filter (most often CODEOWNERS' own
      auto-request, live before anyone has reviewed — agent-ops #350, #353,
      #355 were each already live-requested this way), and `enabler_assignee`
      — carried in the warning's own detail text, at the value it held when
      the sweep warned — still names the pull request's own author: any of
      the three is `ensure_human_reviewer`'s own candidate rule, generalised
      read-only, resolving itself, since the sweep's own next pass would
      report `already` or `requested` for that candidate, never
      `no-candidate` again, before this gatherer runs again. The three
      classes are told apart deliberately:
      every pull request a nudge warning is logged against is already
      `APPROVED` (the nudge's own gate), so the request-class check alone
      would read every nudge-class warning as resolved the moment it was
      created, silently dropping the one class this requirement exists to
      keep visible — and a no-candidate warning has no live request to find at
      all, so neither of the other two checks would ever clear it. A warning
      shape none of the three recognises is kept for as long as its pull
      request stays open and not a draft, the same fail-safe default an
      unreadable re-check gets — the log alone cannot tell a persisting
      problem from one that has quietly resolved (a repo-level listing
      success with nothing to act on logs nothing at all; a merged, closed or
      now-answered pull request is never visited again either way). An answer
      this re-check itself cannot get is never read as "resolved" — the
      violation is kept, the same reasoning the sweep itself applies to its
      own reads. Two further classes have no follow-up *action* outcome to
      inspect at all — the read failing was the whole violation, so each
      re-runs the exact call that failed rather than inferring an answer
      from a different one this re-check already opened with. A
      `could not read the pull request's reviews …` warning
      (`_handoff_pr_approved`'s own REST `gh api …/reviews --paginate` read
      failing, inside the idle-nudge check alone) drops only once a fresh
      call to that same function succeeds — the GraphQL `gh pr view`
      read this re-check opened with is a different API surface, with its
      own rate limit and its own breakable code path, and proves nothing
      about it. A `could not read the pull request's state …` warning
      (`scripts/sweep-human-visibility.sh`'s own broad `gh pr view --json
      reviewDecision,mergeable,mergeStateStatus,statusCheckRollup,reviews,
      comments` call — the read that gates every downstream check the
      sweep makes for a pull request — failing) is the same shape: it
      re-runs that exact call verbatim and drops only once it succeeds
      again, since the narrower `gh pr view` this re-check opened with
      omits `statusCheckRollup` entirely and a broader query is its own
      opportunity to fail even when a narrower one does not.
    - A survivor becomes a candidate carrying its own source,
      `source: "human-visibility"` — ranked immediately after
      `merge-conflicts` (config.schema.json's `sources` enum and priority-order
      notes), the same "finishing beats starting" class as `review-feedback`,
      `merge-conflicts` and `abandoned-drafts`: a violation here means finished
      work is invisible to the human whose merge everything waits on, not a
      cosmetic repair that can safely wait its turn. Selection, branch
      derivation (`agent/<ref>`) and the
      block/void escape hatch all work exactly as any other source's
      still do — only the source name and its rank differ. Its `ref` —
      `human-visibility-<hash>`, a digest of the surviving violations'
      identities and details — is its own namespace, so a repeat detection of
      the *same* set of violations stays correctly blocked while a later,
      disjoint set gets a fresh ref.
    - **The work order is its own kind: a diagnosis, not a repair.** A
      `human-visibility-<hash>` entry has no `blob_sha`; its `acceptance` is
      that each named violation no longer holds — or that the Implementer
      reports `blocked` naming a cause outside the repository (a token's
      scopes, an `enabler_assignee` who is not a collaborator, a GitHub
      outage); and its `model` is `models.default`.
      `prompts/coordinator.md` and
      `prompts/implementer.md` give this source its own section, so the
      Co-Ordinator does not emit an
      already-satisfied acceptance test, a trivial model tier or a `blob_sha`
      that does not exist for a diagnosis of GitHub's API and permissions.
    - Fed to the no-op fingerprint (requirement 3b) via its own `human_visibility`
      array, hashed verbatim (`lib/noop-skip.sh`) — its own key, not shared
      with any other source's.

    A pull request whose only legal review-request candidate is its own
    author is covered by requirement 38a's own `skip\tno-candidate` and this
    requirement's `no_candidate` warning class above
    (tech-debt/TD-PPagop-26081001.md) — the one `skip` reason nothing else
    will ever ask a human about, unlike a draft or a `CHANGES_REQUESTED`-
    blocked pull request, each of which has its own actor and its own clock.
    Left deliberately unaddressed, as an adjacent gap rather than this one: an
    issue human-blocked by a classification other than the two requirement
    38b and 36a cover remains requirement 38d's own, deliberate, scope limit.

38f. **Merge-queue awareness (D17).** Where a target repository has a GitHub
    merge queue enabled, enqueueing is the merge act itself, and the actual
    merge lands minutes later, asynchronously, once the merge group's own
    checks pass — or never, if the queue dequeues the pull request. Below
    `agent-merges-routine` on D18's ladder that act is the human's own merge
    click ("Merge when ready", D17) and nothing in this pipeline enqueues;
    at or above it, requirement 8d's arming step enqueues under the Approver
    App's own identity once every gate it re-reads has cleared. Everything
    this requirement says below holds whichever of the two put the pull
    request in the queue: a queue entry is a landing in progress, and the
    one direction a wrong guess costs anything — a push evicting it — is
    the same either way. Neither `isInMergeQueue` (is it queued right now) nor a
    dequeue is exposed by `gh pr list`/`gh pr view --json` (verified against gh
    2.97.0), so `lib/merge-queue.sh`'s `merge_queue_probe` runs a dedicated
    GraphQL query instead — verified live against GitHub's own schema, via
    introspection, that `PullRequest.isInMergeQueue` is a plain non-null
    boolean and that a `RemovedFromMergeQueueEvent` on the timeline carries
    `createdAt` and `reason`. A probe that fails is *unknown*, and every caller
    below treats unknown the same as "possibly queued" — never as "definitely
    not queued" — since that is the one direction a wrong guess would let a
    push evict a human's live queue entry with no further signal that it
    happened.

    `scripts/sweep-human-visibility.sh` (requirement 38c) is the one script
    that reads GitHub's merge-queue fields directly, and does so twice:

    - **The idle nudge (38c) never fires on a currently-queued pull
      request.** A queued pull request reads approved, `MERGEABLE` and
      green exactly like one nobody has acted on yet — before this
      requirement, the nudge told a human "it is waiting on a merge click"
      after they had already clicked it. `mq_queued == "true"` is now an
      additional skip alongside `_handoff_pr_approved`/`mergeable`/the check
      rollup; an unreadable probe (`mq_queued` empty) is not this skip and
      leaves the nudge behaving exactly as it did before this requirement
      existed.
    - **A checks-failure dequeue gets its own notice, unconditional on
      `human_nudge_idle_hours`.** GitHub marks a dequeued pull request
      nowhere but the timeline — no field distinguishes it from one that was
      never queued — so this reads `merge_queue_probe`'s `dequeued_at`
      directly rather than tracking state across cycles itself. The gate is
      `mq_queued == "false" && dequeued_at` is set: deliberately excluding
      both an unreadable probe and a pull request re-queued since at the
      same head, either of which has nothing fresh to say. Two further gates
      (agent-ops#394, tech-debt/TD-PPagop-26081409.md):
      `merge_queue_dequeue_actionable` (`lib/merge-queue.sh`) excludes the
      two `dequeue_reason` values that are nobody's defect, both verified
      live against public repositories with an active queue: `"manual"`,
      GitHub's own value for a removal the maintainer performed themselves
      via the API or the merge queue's own UI — telling them their own
      removal "needs a fresh look" is noise addressed to the person who
      caused it — and `"merged"`, the removal that *is* the pull request
      landing, which this script never encounters (it reads open pull
      requests only) but which a shared classification must not call
      actionable for the two sites below. Every other reason,
      including one this never learned to recognise, stays actionable, the
      same "unknown must not suppress" direction `merge_queue_probe`'s own
      contract takes. And the event's own age is bounded by
      `merge_queue_dequeue_notice_max_age_hours` (default 24 h; `minimum: 0`,
      agent-ops#429): a removal older than that gets no notice even the first
      time a sweep reads it, so a repository's queue adoption (or this
      requirement's own rollout) does not retroactively read every
      already-old removal on every open, labelled pull request as fresh
      news. `0` disables the notice outright — an explicit `awk`-computed
      guard around `mq_recent`, not merely a zero-width threshold a
      same-second dequeue could still slip through — for a repository that
      runs without a merge queue and should say so in config rather than by
      tuning this value near zero; the trade-off is losing the only human
      signal this pipeline raises for a merge-group failure. The notice is
      idempotent per removal event — `<!-- agent-ops:merge-queue-dequeued:
      <dequeued_at> -->` — rather than per pull request, so a second dequeue
      after an earlier one was already acknowledged gets its own notice
      rather than being silently suppressed by the first. It does not wait on
      `human_nudge_idle_hours`: this is new information a human has not
      seen, not the "forgot to click merge" case that threshold exists for.
      A failed POST is a `warning`, exactly as the ordinary idle nudge's
      is, and is logged and cleared under its own action (`dequeue-notice`)
      and event (`human-dequeue-notice`) — never the idle nudge's `nudged`/
      `human-nudged` — precisely so that a later successful idle nudge cannot
      read back as this warning having resolved, nor the reverse (agent-ops
      #393). Requirement 38e's log reduction recognises this warning's own
      family and clears it only off a later `human-dequeue-notice` success
      for the same pull request. `gather-human-visibility-hygiene.sh`'s own
      live re-check, one step further on, has its own dedicated
      `dequeue_notice` class (TD-PPagop-26081504) alongside its other five
      (`could_not_request`/`could_not_post_nudge`/`no_candidate`/
      `could_not_read_reviews`/`could_not_read_state`) — it
      re-verifies that a posted comment actually landed by reading the pull
      request's comments for the `agent-ops:merge-queue-dequeued:` marker,
      the same kind of read `could_not_post_nudge` already makes for the
      idle nudge's own marker — so a warning stuck on a re-queued pull
      request, or one whose retry never came before the notice aged out,
      clears the moment the marker is found rather than only through a
      later same-family sweep success. An unreadable pull request, or one
      whose marker genuinely is not there, still falls into that script's
      own fail-safe default: kept selectable for as long as the pull
      request stays open and not a draft, the same as any warning shape
      none of its six classes recognise. The notice's own
      gate is `merge_queue_dequeue_actionable`'s, above, and it is
      deliberately *wider* than requirement 3z's: requirement 3z admits only
      `failed_checks`, an allow-list, because it pushes a fix to the branch;
      this notice admits everything except `"manual"` and `"merged"`, a
      deny-list, because it only addresses a human. The three cases that
      follow are therefore distinct. A `failed_checks` dequeue reaches both:
      a human is told, and the pull request also becomes requirement 3z's
      `dequeued` candidate for this system to fix itself. Any other
      actionable reason — including one neither rule has learned to
      recognise — reaches the notice alone, which is the point of the wider
      gate: a human is the only remedy left for it, so they must be told
      even though nothing here can act. A `"manual"` or `"merged"` removal
      reaches neither, for the reasons given above.

    **Design note: `statusCheckRollup` is scoped wider than `--required`, on
    purpose.** The self-heal's own green gate and the idle nudge's (both
    requirement 38c, `_sweep_checks_green`) both read `statusCheckRollup` off
    `gh pr view --json` — every check GitHub ran against the head commit,
    required or not — never `lib/review-gate.sh`'s `gh pr checks --required`
    (requirement 31c), which is scoped to the branch ruleset's required subset
    alone. The two reads answer different questions: the review gate asks
    whether GitHub would actually let the pull request merge, and a
    non-required check has no say in that; the self-heal and the nudge ask
    whether the pull request is genuinely finished, and a non-required check
    still failing is real, uncorrected work sitting on it — telling a human
    "this is answered" or "this is waiting on your merge click" while an
    optional check is red would be untrue. This is a deliberate scope
    difference between the two reads, not an inconsistency: neither would
    serve the other's purpose if it used the other's field.

    Every other reader of PR merge state in this repository is safe against a
    queued pull request without further code change — most by construction
    of its own candidate rule, one only because of a GitHub platform
    guarantee that holds conditionally rather than always:

    - `scripts/gather-merge-conflicts.sh` (requirements 3g, 3s) selects only
      `mergeable == "CONFLICTING"`; a queued pull request is mergeable by
      definition and can never match.
    - `scripts/gather-dequeued.sh` (requirement 3z) is the one exception to
      "needs no code change" — it exists to read exactly this state, and
      selects only `queued == "false"` with a non-null `dequeued_at`, so a
      currently-queued pull request is excluded by its candidate rule's own
      construction, the same direction every other reader here is already
      safe in.
    - `scripts/gather-review-status.sh` and `lib/void-liveness.sh`
      (requirement 34i, 34n) key on `merged_at`/`"merged"` alone — an
      enqueued-but-not-yet-landed pull request is still open, and answers
      nothing until the queue actually lands the merge, never a guess from
      `mergeable` or `mergeStateStatus`.
    - `lib/work-gone.sh` and `scripts/gather-source-state.sh`'s `open_prs`
      digest key on `state == "open"` alone; a queued pull request is still
      open until the queue lands or evicts it.
    - `lib/void-guard.sh` (requirements 34c, 34d, 34k): the `abandoned`/
      `review` void shapes are corroborated only by a human-applied
      `obsolete` label or an empty diff, and their candidates
      (`scripts/gather-abandoned-drafts.sh`) are draft-only — GitHub does
      not allow enqueueing a draft, so this path cannot misfire on a queued
      pull request. The `conflict` shape's `mergeable == false` test is
      unaffected for the same reason as `gather-merge-conflicts.sh` above,
      and the `dequeued` shape's own live re-check (requirement 3z) reads
      `merge_queue_probe` again directly, so a pull request re-queued since
      the void was written reads as resolved rather than misread as still
      broken.
    - `lib/handoff.sh` (requirements 31, 31a, 31b, 32, 32a, 38a) reads only
      `isDraft` and `reviewDecision`, never a merge-state field, and pushes
      nothing itself.
    - `scripts/gather-review-feedback.sh` (requirement 3c) is the one
      exception, and it is conditional, not built-in: its candidate rule
      reads `reviewDecision == CHANGES_REQUESTED` directly, with no
      merge-state field in the query at all, so nothing in the script itself
      excludes a queued pull request. Whether GitHub can even let one reach
      the queue depends on a per-repo branch-protection setting outside this
      script's control: where the repo requires an approving review before
      merge, GitHub refuses to queue a pull request a human has left
      `CHANGES_REQUESTED` on, so this gatherer is safe there for the same
      platform reason as `gather-merge-conflicts.sh` above, just not written
      into its own query; where the repo does not require one,
      `CHANGES_REQUESTED` never blocked enqueueing, and this gatherer lists
      a queued, still-`CHANGES_REQUESTED` pull request as an ordinary
      `review-feedback` candidate.
    - `prompts/coordinator.md` never reads GitHub live; every field above
      reaches it only through the pre-fetched candidate arrays. Every
      candidate rule but `review-feedback`'s excludes a queued pull request
      outright; `review-feedback`'s excludes one only where the repo
      requires an approving review before merge, and otherwise depends
      entirely on the push-time probe below rather than on anything the
      Co-Ordinator itself can see — which is why that probe, not the
      Co-Ordinator's candidate rules, is the thing this system actually
      relies on to keep a queued pull request safe.

    The Implementer and Reviewer prompts are the two places outside this
    script that push to a pull request's branch, and each checks queue
    membership immediately before doing so, using the same
    `merge_queue_probe` query above (`prompts/implementer.md`'s
    "Merge-queue awareness" section, `prompts/reviewer.md`'s section of the
    same name): before any push to a `review-feedback`, `merge-conflicts`,
    `dequeued` or `abandoned-drafts` branch (requirement 26, Implementer step 6's
    mergeable re-check), and before any push in the Reviewer's own steps 4
    and 6 (requirements 29, 30, 30a) when the pull request being reviewed is
    not a draft — which is only ever true for the Reviewer's own
    `review-feedback` handling (requirement 30a), since the ordinary flow's
    pull request stays draft through the Reviewer's step 6. A probe that
    prints `true`, or fails, stops the push and reports `"status":
    "blocked"` rather than guessing — `abandoned-drafts`' push is exempt from
    the check entirely, since its pull request is always a draft and GitHub
    cannot queue one.

    Nothing in this pipeline infers "merged" from anything but `merged`/
    `merged_at` — the queue's asynchronous landing makes this load-bearing
    rather than merely tidy, since enqueueing — a human's merge click at
    `merge_autonomy: human`, the Script's own arming step at
    `agent-merges-routine` and above — no longer implies "merged" the moment
    it happens.

38g. **The ruleset setting behind requirement 38c's own approval derivation
    is reported, not silent (agent-ops#391).** GitHub computes
    `reviewDecision` against the base branch's *required* approving review
    count; where a target repository's ruleset sets that to `0`, the field
    never becomes `APPROVED` however many humans approve — a fact
    `_handoff_pr_approved` (requirement 38c) no longer depends on, but one
    that cost a cross-repository investigation to find in the first place,
    purely because nothing reported it. `scripts/doctor.sh`'s GitHub section
    reads each configured `repos[].slug`'s active branch ruleset targeting
    the default branch (`gh api repos/<slug>/rulesets`, the same technique
    requirement 25a's own ruleset check uses), and reports the
    `required_approving_review_count` GitHub actually enforces: the
    **maximum** across every matching ruleset's `pull_request` rule, never
    whichever the API happened to return last, because GitHub enforces the
    strictest applicable rule — a repository with one ruleset requiring `1`
    and another requiring `0` would otherwise be warned about a
    `reviewDecision` that in fact reaches `APPROVED` there. `0` is a `warn`
    naming agent-ops#391 and stating this is informational, not a requirement
    38 fault; any other value is `ok`; no active ruleset carrying a
    `pull_request` rule, or an unreadable `rulesets` endpoint, is a `skip` —
    a repository may legitimately gate approvals through classic branch
    protection instead, which this check does not read. A count that is not a
    non-negative integer is not a count: it is passed over like an absent
    rule rather than evaluated, since a non-numeric value would otherwise
    compare as `0`, the one value that changes the verdict. Cheap,
    read-only, one call per repository plus one per candidate ruleset.

