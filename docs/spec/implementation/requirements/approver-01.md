## Requirements

### The Approver

D18 WI-5 (agent-ops#408; design `docs/reviews/2026-08-14-autonomy-investigation.md`
§5.2/§5.3). Requirements 8b and 8c above state when and why the Script
engages this stage; these state what the stage itself does once engaged.
Physically placed here, after the Refiner, rather than immediately after
"### The Reviewer" it follows in the pipeline's own running order — inserting
it there would have meant renumbering every requirement from "### Logging and
state" onward, and every one of their cross-references throughout this
document, for a stage whose numbers do not otherwise need to be contiguous
with the Reviewer's own.

40. **One engagement, judge only, never fix.** The Approver runs in the same
    ephemeral clone the Implementer and Reviewer already used, with the pull
    request's branch checked out, and reads: the diff, the work order, the
    Implementer's summary, the Reviewer's summary, and — on an adjudication
    engagement only — the Approver's own prior `REQUEST_CHANGES` review
    bodies on this pull request (requirement 8c). It may edit, commit, or
    push nothing; unlike the Reviewer, which repairs a pull request and then
    certifies its own repair, the Approver exists to be an independent second
    read of the same diff, and repairing what it is reviewing would collapse
    exactly the independence it exists to restore. `prompts/approver.md`
    states this as the stage's own operating rule, not only as a convention
    this requirement documents.
41. **Posture follows tier, and `prompts/approver.md` defines one for every
    tier word the `## Tier` section can carry.** Those words are
    `standard`, `high`, `critical` and `adjudication` — four, not the
    `trivial`/`standard`/`high`/`critical` tier set requirement 8b resolves,
    because `trivial` never reaches a prompt (the Script posts that approval
    itself, with no model call) and a refuse streak is labelled
    `adjudication` rather than by the tier it displaces. Standard
    (`complexity:medium`): find a reason
    to refuse; approve only if none is found. High (`complexity:high`):
    the same posture, refuse-by-default — this tier exists because the diff
    already earned `complexity:high` under requirement 26a's own rubric
    (concurrency, security, state replication, CI/workflow machinery, or
    shared library code), so the base rate of a genuine defect is higher and
    the prompt is told to read expecting one. Critical: the same posture at
    its sharpest, on the ordinary `approve`/`refuse` verdict set and with no
    `## Prior refusals` section beside it — requirement 8b's own
    protected-path forcing is the one cause that puts this word in front of
    an engagement, so a self-modifying change to the gate itself is read as
    closely as a genuine security fix whatever its complexity grade said.
    Adjudication, which requirement 8c's refuse streak is the one cause of
    and which always carries `## Prior refusals`: not a third
    ordinary review — a ruling on whether the disagreement the two prior
    refusals raised is real and unresolved (`refuse`), has since been
    answered (`land`), or is a genuine judgement call neither side can settle
    alone (`escalate`, favoured over a third guess). The streak takes
    precedence over whatever tier the complexity grade or a protected path
    chose, so no one engagement is told both words, and the two postures'
    verdict sets never have to be chosen between.
42. **Never writes to GitHub.** The Approver's prompt is explicitly
    forbidden `gh pr review`, `gh pr comment`, `gh api .../reviews`,
    `gh pr merge`, `gh pr ready`, or any other GitHub write — its entire
    contribution is the verdict in its final JSON message. Every actual
    GitHub write (`APPROVE`/`REQUEST_CHANGES`, the escalation issue on an
    unresolved adjudication) is a Script-issued call under the Approver's own
    minted App token (`approver_post_review`, `lib/approver.sh`;
    `approver_token_get`, `lib/approver-token.sh`, requirement 14b) —
    requirement 8c's own restatement of D18's cardinal rule, that the model
    never holds approve or merge rights, applied at this stage specifically.
42a. **`file_debt`/`file_issue` (agent-ops#631): filing what the Approver
    noticed, without it writing anything itself.** Orthogonal to `verdict` —
    either, both, or neither may accompany any verdict this requirement or
    requirement 43 allows, since what it names is deferred work the diff read
    turned up, not what was decided about the pull request itself. Each is
    `{title, body, default_fix, owner_decision}`;
    present with either `title`/`body` empty, it is a `warning` and nothing
    is filed. `default_fix`/`owner_decision` follow requirement 36c's own
    contract exactly — same fields, same `## Default`/`Owner decision: yes`/
    `pw::owner-decision` handling in `lib/tech-debt-file.sh`, same
    malformed-verdict warning whenever neither is set (agent-ops#938). The
    Script cannot read whether the body it was handed names more than one
    fix, so it warns on the field's absence alone: a single-fix filing that
    never needed a default costs one `warning` and a `## Default: not stated`
    heading, which is the cheap side of the trade against a filing whose
    unstated choice would have cost a Refiner pass to rediscover. Filing is a
    Script-issued call
    (`techdebt_file_debt`/`techdebt_file_issue`, `lib/tech-debt-file.sh`),
    never a write the model performs, and every `gh` call either makes runs
    under the same App token requirement 42 already mints for posting the
    review, never the ordinary pipeline login — there is no second write
    under a different identity to account for, since filing is now a single
    issue create (or comment) and nothing else (agent-ops#874).

    - `file_debt` (agent-ops#874, D15 as revised #869) files a single GitHub
      issue in the target repository, labelled `pw::type:tech-debt`, deduped
      first against that repository's own open `pw::type:tech-debt` issues
      by normalised title (`_techdebt_title_dedup_match`,
      `lib/tech-debt-file.sh`, requirement 36c's own bullet describes the
      same dedup): a match gets the new body and provenance as a comment
      instead of a second filing. No id reservation, no branch, no pull
      request. Logs `tech-debt-filed` (`pr_url`, `repo`, `by: "approver"`,
      `issue_number`, `issue_url`) on success; a `warning` naming
      `tech-debt-file.err` on failure.
    - `file_issue` reuses the pull request's own URL as the duplicate-guard
      key: an open issue already quoting it *is* the record. No label, no
      assignee — legitimate autonomous work for the `issues` source to pick
      up later, not a request that source must exclude. Logs `issue-filed`
      (`pr_url`, `repo`, `by: "approver"`, `issue_number`, `issue_url`) on
      success; a `warning` on failure.

    Neither call changes `verdict` or whether a review is posted — a failed
    filing attempt costs a `warning`, never a withheld or altered review.
43. **Ends with a single JSON object:**
    `{"verdict": "approve" | "refuse", "reasons": […]}` on a Standard or High
    engagement, `{"verdict": "land" | "refuse" | "escalate", "reasons": […]}`
    on adjudication. `reasons` is a list of short, specific findings — it
    becomes the body of the GitHub review the Script posts on a refusal, and
    the evidence an escalation issue carries on adjudication, so it is
    written for a reader with no other context, never merely "looks risky."
    An unrecognised or missing `verdict`, or a stage that failed to launch or
    produced no parseable JSON at all, is never read as either verdict: the
    Script logs a `warning` and posts no review this round (requirement 8b)
    — on adjudication specifically, it is treated the same as an explicit
    `escalate` (requirement 8c), since "cannot settle" is not "nothing
    wrong."
44. **One-shot, no resumption, same foreground-wait discipline every other
    stage in this pipeline follows.** The Approver is launched exactly once
    per Reviewer-`ready` round via `run_model_stage` (component 4d, the same
    shared launcher every stage in this document uses), on
    `approver_model_default`/`approver_model_complex`/`approver_model_critical`
    per requirements 8b/8c, under the `approver` stage-budget key
    (`lib/stage-budget.sh`'s `STAGE_BUDGET_PRIORS`, falling back to the
    Implementer's own prior — requirement 4e's derivation — for any
    installation with no history for this stage yet). A stage timeout, a
    non-zero exit, or an unparseable final message ends the engagement with
    no review posted (requirement 43) — never a blocked pull request, since
    nothing about the human's own path to merging depends on this stage
    having run at all.
46. **A pull request cannot rely on the cycle that owed it an Approver
    round to also deliver one (agent-ops#682, #890).** The ordinary path —
    requirement 8b's own engagement, launched again once the same cycle's
    Reviewer next reports `ready` — already clears an ordinary standing
    review the moment the round that answered it completes. The gap is the
    cycle that never finishes: a stage timeout, a kill, or a host failure
    between the Implementer's own push and that continuation (PR #621 sat
    13.5 hours this way before a human dismissed the review by hand) leaves
    the fix on GitHub with no fresh Approver round ever having reached it,
    and GitHub's `requested_reviewers` re-request — the Implementer's own
    best-effort attempt at asking for one — silently no-ops for the
    Approver's Bot identity, so it can never itself signal the gap either.

    The **restale sweep** (`_approver_restale_sweep_repo`, `lib/approver.sh`,
    run fleet-wide every cycle immediately before the requirement-8u
    landing-retry sweep, skipped on `--dry-run`) is the independent recovery
    path, under two triggers sharing one pull-request listing: for every
    repository whose effective `merge_autonomy` is above `human`, every
    open, non-draft, `pr_label` pull request whose `reviewDecision` is
    `CHANGES_REQUESTED` is read fresh
    (`landing_approver_standing_review_at`, the same read `_landing_stage_
    attempt`'s gate 4 already makes — requirement 8u's own sweep calls its
    state-only sibling, `landing_approver_standing_review`, which carries no
    `commit_id` for this requirement to compare) for the Approver's own
    standing review. **Stale** (`approver_review_stale`,
    `lib/approver.sh`) means that review's own `commit_id` no longer matches
    the pull request's current head — the deterministic trigger, never
    `requested_reviewers`. A pull request a peer's cycle holds right now is
    excluded here exactly as it is from the unreviewed trigger below
    (issue #987, TD-PPagop-26082509): the same fleet-wide `pr-<n>` claim
    listing (`_approver_sweep_claimed_pr_numbers`), fetched once for
    whichever of the two triggers reaches a candidate first this pass and
    reused by the other rather than fetched twice, and a claimed candidate
    is skipped and logged (`approver-restale-sweep-skipped-claimed`) rather
    than reaching `_approver_restale_review`, `_approver_restale_dismiss` or
    `_approver_restale_escalate`.

    A stale review then splits on whether real work happened since it was
    submitted, decided from the pull request's own commit history rather
    than anything a rebase can move:

    - **Genuine progress** — `approver_newest_commit_authored_at`
      (`lib/approver.sh`, one `gh pr view --json commits` read) reports a
      commit *authored* after the standing review's own `submitted_at`. A
      rebase alone can never produce this: replaying a commit during a
      rebase reuses its original author date and only stamps a fresh
      committer date (the same forgeable-by-force-push signal requirement 3c
      already rejected `committedDate`/`updatedAt` for), so an authored date
      genuinely newer than the review means a real commit landed, not merely
      that the branch moved. This gets a **real re-review**
      (`_approver_restale_review`): the sweep clones the repository fresh,
      checks the pull request's branch out, assembles a synthetic-but-honest
      work order/Implementer-summary/Reviewer-summary explaining exactly
      why the usual ones are unavailable, and calls `run_approver_stage`
      itself — the same tiering, protected-path forcing, refuse-streak
      adjudication, escalation and tech-debt-filing logic requirement 8b's
      own engagement already carries, reused rather than duplicated, under
      globals (`selected_repo`/`clone_dir`/`work_order_json`/
      `impl_status_json`/`rev_status_json`) saved before the call and
      restored after it regardless of outcome — read defensively, since this
      sweep runs before the cycle has selected any work of its own and the
      last three are genuinely unset at that point, which `set -u` would
      otherwise make fatal. Its own outcome comes back in the
      `_approver_restale_review_result` global rather than on stdout, the
      same signalling `_landing_stage_attempt` uses for
      `_landing_stage_attempt_armed`: `run_approver_stage` writes the whole
      stage transcript to stdout itself under `--once`
      (`dump_stage_output`), so a caller capturing this function's output
      would read that transcript as the outcome and route a posted
      re-review into the dismissal fallback below. The result is one of
      three values, read off `run_approver_stage`'s own `approver_stage_
      posted` (agent-ops#988) rather than merely whether it reached a
      verdict at all: `posted` once a real GitHub review write was attempted
      and succeeded — a pull request this re-review approves is picked up
      by the very next requirement-8u sweep pass in the same cycle, since a
      fresh `APPROVED` standing review is exactly that sweep's own
      precondition; `unposted` once a verdict was reached but nothing was
      written to GitHub — overwhelmingly an adjudication `escalate`, whose
      own `approver_escalate` files or dedups onto an escalation issue and
      leaves the standing `CHANGES_REQUESTED` review, its `commit_id` and
      this trigger's own precondition exactly as they were, so a naive retry
      would re-fire the identical `approver_model_critical` engagement every
      cycle indefinitely (the gap this requirement's own predecessor left
      open until agent-ops#988: before it, this case read as `posted`
      merely because a verdict was reached, so it neither dismissed nor
      bounded, and the sweep re-engaged unboundedly); and `unavailable` when
      no verdict was reached at all.

      An `unposted` outcome is bounded rather than retried every cycle:
      `approver_restale_unposted_prior_engagement` reads the fleet's union
      log for the first `approver-restale-unposted-engaged` event logged
      against this exact standing review's own numeric id (never the pull
      request or its head — only a fresh Approver write, which produces
      `posted` and a new review id, retires this memory; a rebase-only push
      in the meantime does not). While that first engagement is younger than
      `approver_restale_escalate_after_hours`, no further engagement is
      attempted this cycle — the sweep leaves the review exactly as it
      stands, the same as the no-progress branch below. Once it is older,
      `_approver_restale_escalate` hands the pull request to a human instead
      — the identical per-review-id-deduplicated escalation path
      (`pr-<n>-approver-restale-<review-id>`) the no-progress branch already
      uses, so the same standing review is never escalated twice under two
      different names. That escalation's own issue body states this branch's
      facts rather than the no-progress branch's: a commit *was* authored
      since the review, it *was* re-reviewed, and the re-review reached a
      verdict it never wrote — which is the opposite of the "every push
      since has been a rebase, never a fix" the branch below says, so the
      two share the path and the dedup but never the wording. A fresh
      engagement (never attempted while a prior `unposted` engagement is
      still within the bound) that itself reports `unposted` logs the
      `approver-restale-unposted-engaged` event that starts this clock.
    - **No commit authored since the review** — a push landed (the head
      moved, or the trigger would not have fired at all) but it authored
      nothing new, i.e. a rebase alone. Neither re-reviewed (there is
      nothing new to judge) nor dismissed (the standing refusal may still be
      correct) — left exactly as it stands until
      `approver_restale_escalate_after_hours` have passed since the review's
      own `submitted_at` (never `updatedAt`, which a rebase does move),
      at which point `_approver_restale_escalate` hands it to a human
      instead of retrying it forever — the "rebase-only cycle masquerading
      as progress" the issue names. The escalation issue is filed through
      the same `create_escalation_issue` (`enabler_assignee`) every other
      escalation in this pipeline already uses, never a destination this
      path names itself (D18, agent-ops#627/#679), and is deduplicated per
      review round (`pr-<n>-approver-restale-<review-id>`), so a fresh
      standing review after a human acts gets its own escalation rather than
      colliding with the old one's.

    A genuine re-review that reports `unavailable` — the clone or branch
    checkout failed, or `run_approver_stage` bailed out before engaging at
    all (the stage disabled at this level, the credential absent, the
    refuse streak unreadable, no model resolved) — falls back to
    `_approver_restale_dismiss`: a self-dismissal of the Approver's own
    stale review via `PUT .../reviews/{id}/dismissals`
    (`approver_dismiss_review`, `lib/approver.sh`), which needs no
    permission beyond what posting a review already grants, since both write
    under the same App identity. This is reached only when genuine progress
    was found but a real re-review could not even be attempted this cycle —
    never in place of one that posted, never for one that reached a verdict
    and reported `unposted` (that review was actually judged; dismissing it
    would discard a completed, if unwritten, judgement rather than merely a
    missed attempt), and never for the no-progress case above, where
    dismissing a review that may still be correct would be worse than
    leaving it stand. Every write this requirement makes is best-effort: a
    failure at any step logs a `warning` and leaves the pull request exactly
    as it was, for the sweep to find again next cycle.

    The sweep's **unreviewed trigger** (agent-ops#890) recovers the pull
    request the stale trigger structurally cannot see: one that is ready but
    carries **no Approver review at all**. Every other recovery path is
    keyed on an event or a review state — `CHANGES_REQUESTED` for the stale
    trigger and the review-feedback source, a conflict, a draft, a dequeue,
    failed checks — so a cycle dying between the Reviewer's handoff and the
    Approver, an Approver verdict whose own GitHub write was refused, or the
    stage's silent fail-closed skip used to strand such a pull request
    permanently rather than for one cycle (PR #828 sat days this way; #1049
    and #1059 followed). This trigger is keyed on the *state*, so all three
    routes into the gap are recovered by the one path. A candidate is open,
    non-draft, carries `pr_label`, its `reviewDecision` is anything but
    `CHANGES_REQUESTED`, its `createdAt` is older than
    `approver_unreviewed_engage_after_hours` — younger is ordinary in-flight
    work whose own cycle's chained requirement-8b engagement is the ordinary
    path — and the same fresh `landing_approver_standing_review_at` read the
    stale trigger makes reports no standing Approver review at all (an
    unreadable read is skipped, never guessed at; any standing review at all
    routes elsewhere: `APPROVED` to requirement 8u, `CHANGES_REQUESTED` to
    the stale trigger). Non-draft under `pr_label` is itself the handoff
    record: an Implementer raises its pull request as a draft — the draft is
    its claim marker (requirement 23) — and only the Reviewer's handoff
    readies it, so a mid-Reviewer pull request is still a draft and never a
    candidate. A pull request a peer's cycle holds right now is excluded by
    the fleet-wide `pr-<n>` claim, read from the live claim registry
    (`_approver_sweep_claimed_pr_numbers`, one `claim.sh claims` listing per
    repository, taken only when a candidate exists to spend it on); the
    registry is advisory by its own contract, and the second, fleet-wide
    guard is the union log.

    A candidate gets a recovery engagement through the same
    `_approver_restale_review` above (mode `unreviewed`: the synthetic work
    order carries item `pr-<n>-approver-unreviewed`, source
    `approver-unreviewed`, and acceptance prose naming this trigger; the
    clone, borrowed globals and outcome contract are identical), and every
    engagement is recorded as an `approver-unreviewed-engaged` event
    (`pr_url`, `head`, `result`). That event is the trigger's own bound,
    read back from the fleet's union log
    (`approver_unreviewed_prior_engagement`, keyed on the exact head sha —
    a push makes the pull request a genuinely new judgement, so the count
    and the escalation clock start over with it): a head whose most recent
    engagement reached a verdict at all — `posted`, or the `unposted` of
    agent-ops#988 — is never re-engaged, because the verdict was reached,
    and re-judging the same head would spend a full engagement to reach the
    same verdict; the review write's own `approver_post_or_warn` retry (PR
    #1101) owns a refused post, and a write that still never lands is
    exactly what the escalation below exists for — while an `unavailable`
    one is retried next cycle. Both reached-a-verdict outcomes bind here
    even though the stale trigger above treats them differently: splitting
    `unposted` out of `posted` sharpened that trigger's own bound, and must
    not loosen this one, where the distinction buys nothing and a fresh
    engagement every cycle is precisely what this bound exists to prevent.
    Once the *first* engagement at the current head is older than
    `approver_restale_escalate_after_hours` with still no standing review,
    `_approver_unreviewed_escalate` hands the pull request to a human
    instead of engaging forever: an escalation through the same
    duplicate-guarded `create_escalation_issue` (`enabler_assignee`) as
    everything else in this requirement, deduplicated per head
    (`pr-<n>-approver-unreviewed-<head>`), logged as
    `approver-unreviewed-escalated`. Like every reduction the union log
    backs, the engagement memory is approximate across nodes for one
    propagation interval; the worst transient outcome is a doubled
    engagement whose second review lands under the same App identity, which
    GitHub folds into one standing position.

46a. **The stale trigger's own "genuine progress" test also asks whether the
    diff actually changed, not only whether a commit's authored date is
    newer than the review (agent-ops#1806).** `approver_newest_commit_
    authored_at` tells a real commit from a bare rebase, never from a
    conflict-resolution commit: resolving a merge conflict authors a
    genuinely fresh commit — its own authored date, newer than the standing
    review's `submitted_at` — even when the tree it produces is identical in
    net content to what the review already judged, a clean rebase or a
    both-sides-kept resolution reproduced on the moved base. Authored-date
    alone reads that as genuine progress and spends a full re-review
    (`_approver_restale_review`) on content nobody actually changed.

    `_approver_restale_diff_unchanged` (`lib/approver.sh`) closes that gap:
    once `approver_newest_commit_authored_at` reports a newer date, this
    additionally asks whether the pull request's current head, diffed
    against its own base, is `git patch-id --stable`-identical
    (`rebase_only_push`, `lib/rebase-only.sh`) to the standing review's own
    pinned `commit_id`, diffed against that same base. A fresh, throwaway
    clone (its own — the standing review's pinned commit is not necessarily
    reachable from any live ref once the pull request has moved past it, so
    a shallow fetch of the branch alone would not resolve it) fetches only
    the three refs this needs: the pinned commit, the branch, and the base.
    Fails closed on any read failure — an unresolvable base, a failed clone,
    an unresolvable head — read as "the diff changed", never as "unchanged",
    since a false "unchanged" would silently retire a review nobody has
    confirmed still applies.

    A diff reported unchanged joins the **No commit authored since the
    review** branch above — left exactly as it stands, re-reviewed only past
    `approver_restale_escalate_after_hours` — rather than the genuine-progress
    branch: the same treatment a bare rebase already gets, for the same
    reason, whether or not this particular push happened to author a commit.
    A diff that genuinely changed — including a same-region conflict
    resolved by keeping both sides, whose own diff necessarily differs from
    either side's alone, since the surviving content and its surrounding
    context are not what either commit introduced on its own — takes the
    **genuine progress** branch above exactly as before this requirement
    existed.

    This requirement is the restale sweep's own half of the same mechanism
    requirement 31e applies inside the cycle that just ran the Implementer;
    the two share `lib/rebase-only.sh`'s `rebase_only_push` and
    `diff_patch_id` rather than each defining their own, so the definition of
    "the diff did not change" cannot drift between the two call sites.

47. **Rework record.** D23 of `docs/ROADMAP.md` names nine classes of
    repetition, the pipeline's only honest quality signal, and this
    requirement is where each one is actually recorded: one `rework` event
    per repetition, logged the moment the detector that already exists for it
    fires, never inferred afterwards and never classified by a model.
    `lib/rework.sh`'s `rework_fields` is the one shaping function every site
    below calls, on the same terms `lib/metering.sh`'s `metering_fields`
    already established for requirement 33a: a caller hands it the class, the
    detector's own name, the detector's own raw evidence, and, only where the
    evidence itself names one, the stage the repetition is attributed to;
    `rework_fields` degrades an unparseable evidence argument to
    `evidence: null` rather than failing, the same fail-safe contract
    requirement 33a's own record keeps. `docs/FLOW-SCHEMA.md` is the
    field-by-field contract, the class enumeration and each class's detector
    site, under the same stability policy `docs/METERING-SCHEMA.md` already
    established.

    Nine classes, nine sites, none of them a new detector: each already
    existed for its own reason before this requirement gave its firing a
    record.

    - **review-round-trip** — a `review-feedback` candidate's own selection
      (requirement 3c's own gatherer, `scripts/gather-review-feedback.sh`, is
      the detector; the Script's selection event, where `{repo, item,
      pr_url}` are already in hand, is where the record is emitted).
    - **human-change-request** — requirement 31c's reconciliation gate going
      `dirty`, at either of the two sites that share requirement 34a's one
      `handoff_complete_review`: the Reviewer's own handoff and the
      Enabler's handoff-recovery path. Attributed to `reviewer` from both:
      this is the one class whose evidence names its stage directly, since
      the recovery path reaches this verdict only for a pull request with a
      Reviewer verdict already on record, so the request escaped the
      Reviewer whichever site observed it.
    - **check-failure** — a `review-gate-checks-read` event carrying
      `ok: false` (the per-attempt read TD-PPagop-26081404's own streak
      bookkeeping already counts), from either of that event's own two call
      sites — the same two handoffs, each naming itself in `detector`. Its
      escalation, `review-gate-checks-
      degraded`, is deliberately never counted a second time: it summarises
      repetitions already recorded at their own per-attempt site.
    - **merge-conflict** — a `merge-conflicts` candidate's own selection
      (`scripts/gather-merge-conflicts.sh` is the detector), the same
      selection-time site as review-round-trip.
    - **abandoned-draft-resumed** — an `abandoned-drafts` candidate's own
      selection (`scripts/gather-abandoned-drafts.sh` is the detector), the
      same selection-time site again.
    - **stage-rerun** — two detectors, because a killed-by-backstop stage and
      a deterministic crash loop are different mechanisms: every `stage-end`
      site that can carry requirement 4e's `kill_reason` logs one record per
      non-empty `kill_reason` (`lib/rework.sh`'s `rework_stage_rerun_maybe`,
      called from every such site in this Script and its libraries), and
      requirement 2.7's `crash-loop-escalated` event logs one record per
      escalated run — a `count`-many-in-one entry, not `count` separate ones,
      since the individual failures a run comprises were never a repetition
      this system could see at the time.
    - **claim-race-duplicate** — a `claim-lost` event whose `cause` is `held`
      or `pr-held`, never a bare `claim-lost`: `scripts/pickup-metrics.sh`'s
      own header already draws this distinction (healthy contention against
      an outage or a selection defect), and this requirement reuses it
      rather than restating it.
    - **refinement-bounce-back** — `record_needs_refinement_block`
      (`lib/candidate-select.sh`, requirement 34e's own single recorder)
      logging a fresh block for an item `refinements_json` already shows as
      refined — the same lookup its own `refined_label` cleanup already
      reads, so this class costs no new read.
    - **post-merge-revert** — the one class mined after the fact rather than
      emitted in-cycle, since a merge's own 48-hour observation window is
      inherent latency no in-cycle detector can shorten.
      `scripts/publish-revert-rate.sh`'s daily pass already mines each
      repository's `post_merge.detail[]` (`scripts/mine-merge-history.sh`'s
      own per-pull-request outcome list, D18 issue #579) to compute the
      aggregate rate it publishes; this requirement has that same pass log
      one record per not-yet-seen entry, memoised in this node's own
      `<state_dir>/rework-post-merge-revert-seen.json` so the same rolling
      14-day window does not re-emit an already-recorded outcome on every
      run.

    Attribution is never arbitrated: `attributed_stage` is set only where a
    class's own detector evidence names a stage directly — today, only
    human-change-request (`reviewer`) and stage-rerun (the stage that was
    killed) do. Every other class records `attributed_stage: null` rather
    than a model's or a script's guess at which stage is really at fault; D23
    parks that arbitration at Phase 2, with the rework panel, and this
    requirement's whole discipline is that a repetition's cause is the
    detector's own evidence or nothing.

    Before requirement 31c's reconciliation gate existed (2026-08-20), a
    human change request arriving as a plain pull request comment was
    invisible to the review gate entirely — the blind spot agent-ops#533
    named. That gate now catches it, at both handoffs above, but only
    there: a change request posted after a pull request is already ready, or
    one a human acts on directly without either handoff ever running, is
    still outside what this class's detector can see.
    `docs/FLOW-SCHEMA.md` states that residual coverage plainly, rather than
    letting a later reader assume the class covers every human change
    request there is.

48. **Expensive per-repository gather runs for one repository per cycle, not
    every configured one (agent-ops#1086).** The seven bands requirement 3
    pre-fetches whole — `findings`, `review_feedback`, `abandoned_drafts`,
    `merge_conflicts`, `dequeued`, `issues` (with
    `issues_excluded`) and `tech_debt` — are read fresh from GitHub, each
    cycle, for exactly one of `gather_ordered_repos`'s configured
    repositories: the one whose expensive-gather cache
    (`lib/expensive-gather-cache.sh`, under this node's own `state_dir`) is
    oldest, with a repository never yet cached always outranking one cached
    at all. The cache directory (`state_dir/expensive-gather/`) is local to
    this node, not synced fleet-wide the way the union log is — it is
    excluded from general state-sync replication
    (`scripts/state-sync.sh`'s `EXCLUDES`), on the identical reasoning as
    `labels-ensured/`: `expensive_gather_pick_repo` keys entirely on
    cache-file mtime, and a cache restored from the fleet state branch would
    carry a checkout-fresh mtime, deferring this node's next real gather of
    every configured repository by a full rotation while it kept serving the
    restored, arbitrarily stale snapshots. Every other configured
    repository's entry carries the raw gather this same node cached the
    last time its own turn came around — only once that cache actually holds
    one: a repository never yet cached, or whose cache file is zero-byte or
    unparseable, carries empty bands instead (below), the same shape a
    repository whose `sources` are all disabled already produces —
    `sources` gating and claim exclusion (`exclude_claimed_items`/
    `exclude_claimed_prs`) are re-applied to it fresh every cycle regardless,
    so a claim a peer takes or a `sources` edit still takes effect without a
    live read. The `issues` band additionally has requirement 16.4's
    assigned/`blocked`-label drop (3j) re-applied fresh every cycle, from
    this same cycle's own `gather_source_state` sample (`issue_state_reapply`,
    lib/candidate-select.sh) rather than a live read — so an issue a human
    assigns or labels `blocked` after this repository's last turn stops being
    a candidate on every node within one cycle, at no further GitHub cost,
    since that sample already runs for every configured repository every
    cycle regardless. The `Blocked-by:` third of that same drop stays as
    recent as the band's own last fresh read (34j), since resolving it needs
    the whole thread and a live per-reference check this sample does not
    carry. `--repo` narrows the configured set to one repository, which
    is then always the one picked, exactly as before this requirement
    existed.

    The nine values `expensive_gather_cache_save` writes into a repository's
    cache document — the eight raw bands plus `issues_excluded` — are each
    unbounded past the call that builds it (agent-ops's own raw `tech_debt`
    band alone has reached 421,622 bytes), so, per requirement 4g, they reach
    `jq` on stdin, one document per line, bound positionally with `input as
    $name` in the order printed, delivered via a here-string (requirement
    4c) — never in argv, where past `MAX_ARG_STRLEN` the build fails silently
    at `execve` inside `$(…)` (agent-ops#1107). `expensive_gather_cache_save`
    additionally refuses (non-zero, no write) an empty or non-object third
    argument, so a build failure of that kind is reported through the
    caller's own `|| log_event "warning" ...` rather than silently producing
    a 0-byte cache file. `expensive_gather_cache_load` treats a zero-byte or
    unparseable cache file as absent, not as `{}`, and logs a `warning`
    naming the slug; `expensive_gather_pick_repo` treats that same file as
    never-cached (epoch 0) rather than reading its mtime, so the affected
    repository is picked again on the very next cycle instead of waiting out
    a full rotation.

    Picking is keyed on this node's own last-read time for each repository
    (the cache file's mtime), never on `lib/repo-order.sh`'s effective-age
    ordering: that ordering is a pure function of GitHub state every node
    computes identically, so keying the expensive-gather pick on it would
    have every node read the same one repository fresh every cycle and
    starve every other configured repository of a fresh read for as long as
    nothing landed on its default branch — indefinitely, for a repository
    this pipeline has never gathered enough to select work in. Keying on
    this node's own cache age instead guarantees every configured repository
    eventually gets its own turn, regardless of commit activity, the same
    way `labels_reconcile_stamped`'s per-repo stamps already do.

    A full tie among a node's own candidates — most often every configured
    repository uncached, on a node's first cycle, or after a fleet-wide
    image roll or a `state_dir` wipe — breaks on a per-node offset, not on
    slug ascending (agent-ops#1106): `_expensive_gather_node_offset` reduces
    a stable hash of `node_name` (`cksum`) modulo the number of configured
    repositories, and `expensive_gather_pick_repo` breaks a tie in favour of
    the slug at that offset into the ascending-sorted slug list, rather than
    always the first. Without this, every node ties the same way and picks
    the same repository fresh in the same cycles, leaving every other
    configured repository unread for the next `repositories`-1 cycles and
    every aligned node racing the others for the same newly-visible item
    once its shared turn comes round. The offset is a fixed function of
    `node_name` and the repository count, so it spreads a fleet across the
    rotation with no coordination, no new state and no extra GitHub read —
    but it spreads without guaranteeing coverage, and requirement 48 claims
    no more than that. Two node names can hash to the same offset: N names
    drawn independently into M buckets ordinarily leave at least one offset
    unoccupied, and the repository at an unoccupied offset is read fresh by
    no node at all that interval, while every node sharing an offset stays
    aligned with the others that share it. Whatever stagger a given set of
    node names does yield holds, in turn, only from a common start: nodes
    whose caches were all populated in the same interval. A node that stands
    down before the gather (requirement 2's own ladder — budget,
    credentials, disk, cooldown) skips a rotation step its peers do not, and
    its phase drifts from theirs from that cycle on. Both the drift and the
    unoccupied offsets are corrected only by assigning phases across nodes
    rather than hashing each independently, which is fleet coordination
    (agent-ops#1092's Option 2), out of this requirement's scope.

    Every repository entry in `ordered_repos_json` carries
    `expensive_gather: {fresh, gathered_at}` — `fresh: true` for the one
    repository this cycle actually read, `gathered_at` naming when the
    bands shown were captured (`null` for a repository never yet read on
    this node). `lib/coordinator-input.sh` documents this shape for a
    reader of the Co-Ordinator's runtime input, and `prompts/coordinator.md`
    obliges a live re-check (`gh issue view`/`gh pr view`) before selecting
    a candidate from a non-fresh entry, the same obligation requirement 4i
    already places on a trimmed one. The no-op short-circuit's canonical
    form (`lib/noop-skip.sh`'s `NOOP_CANON_JQ`) re-projects each repository
    entry to a fixed field list that does not include `expensive_gather`, so
    neither field enters the fingerprint: a repository's cached bands
    fingerprint identically across cycles until its next fresh read, and the
    one repository read fresh each cycle does not bust the fingerprint
    merely by carrying a new `gathered_at` stamp.

    The cheap fleet-wide probes are unaffected and remain unrestricted: the
    per-repository default-branch/commit-timestamp read that orders the
    gather walk (`lib/repo-order.sh`), `gather_source_state`'s own four-call
    sample (the no-op fingerprint's `state.*` fields and
    `compute_enabler_eligible_set`'s input), `labels_reconcile_stamped`'s
    already-rate-limited label listing, and the `unvoid`/hand-flagged-
    `needs_refinement` label scans all still run for every configured
    repository every cycle — restricting any of these would either reopen
    agent-ops#687 (a repository never selected for work never getting its
    labels ensured) or leave a human's override on a non-selected repository
    unnoticed, for a saving small against the eight bands' own cost. A
    repository this cycle does not expensively re-read therefore still gets
    a same-cycle void-liveness verdict of "unsampled, not gone" wherever
    that liveness reads a marker only the skipped gather call would have
    written (`lib/candidate-gather.sh`'s own `.ok`-marker convention,
    TD-PPagop-26081303) — the existing safe default, unchanged by this
    requirement.

    Two mechanisms whose whole guarantee is *this cycle's own live read* are
    narrowed rather than fed a replayed band. Requirement 34j's release reads
    a map built only from the repositories this cycle actually gathered — a
    non-fresh repository's `issues` band proves what its own last turn found,
    not what is true now, and `dependency_clearances`' own rule already says
    an item this cycle's candidates do not carry decides nothing and stays
    blocked. Requirement 34j's *holding* half, and with it requirement 16.4's
    deterministic assigned/`blocked`-label drops (requirement 3j), are as
    recent as the band they filtered and are not re-applied to a replayed
    one: an issue assigned or labelled after its repository's last turn stays
    a candidate in that node's digest until its next turn. agent-ops#1095
    carries the close, from `gather_source_state`'s own already-sampled
    labels and assignee, which costs no further GitHub read.

49. **Item lifecycle record.** D21 of `docs/ROADMAP.md` names the flow
    account's own invariant — every work item carries a lifecycle from first
    sighting to terminal fate, and items entering equals items leaving plus
    work in progress, with an explicit `unaccounted` bucket for whatever
    cannot be classified — and this requirement is where it is made
    checkable: one durable record per `{repo, item}`, *derived* rather than
    emitted, folded from the union log by `lib/item-lifecycle.sh`'s
    `item_lifecycle_fold`, behind the read-only `scripts/item-lifecycle.sh`.
    `docs/FLOW-SCHEMA.md`'s "The item lifecycle record" section is the
    field-by-field contract — identity, every instant and its originating
    event, the six terminal fates and their assignment priority, the
    `unaccounted` case, and the window caveat — under the same stability
    policy `docs/METERING-SCHEMA.md` already established.

    Most of the instants this record accumulates already existed as
    scattered facts; what this requirement adds is narrower than the
    roadmap's own list of them suggests:

    - **The join key.** `{repo, item}`, additive, is added to `stage-start`
      (`agent-cycle.sh`'s `stage_budget_apply`, an optional fifth ITEM
      argument threaded from every item-scoped caller — `$selected_item` on
      the Implementer/Reviewer/Approver/`approver-adjudicate-open-question`
      sites, omitted on the Co-Ordinator/Enabler/Refiner top-level
      engagements, which run ahead of or across selection and so never have
      an item to carry — REPO itself is the fleet-wide `*` those pass for the
      Enabler and the Refiner, which span repositories, but not always for
      the Co-Ordinator, which since its own per-repository split (issue
      #1629) passes a real repository once selection has one to give it;
      REPO and ITEM are independent here), `stage-end`
      (the same four sites, plus `lib/enabler.sh`'s two per-item adjudication
      sites — `enabler-adjudicate`/`enabler-decide` — and
      `lib/landing.sh`'s `approver-adjudicate-open-question`), `pr-raised`,
      `pr-ready` (both call sites — the Reviewer's own handoff and the
      Enabler's `complete_handoff` recovery path), `landing-armed`/
      `landing-refused` (threaded through `_landing_stage_attempt`'s own
      ITEM parameter — `$selected_item` on `run_landing_stage`'s direct
      path, `landing_retry_source_map`'s (`lib/union-log-scan.sh`) own
      `item` field on the 2.1e retry sweep's own candidates),
      `approver-verdict`, `review-gate-checks-read` (both call sites), and
      `issue-closed-post-merge` (`item`, alongside the existing `issue`
      field). `review-gate-checks-degraded` deliberately does not gain one:
      it is a streak escalation spanning whatever items happened to fail
      consecutively, not a fact about any one of them.
    - **`checks-green`.** `review-gate-checks-read`'s own `ok` has always
      named whether the required-checks *read* succeeded, never whether what
      it found was clean, so no event before this requirement recorded a
      genuinely green gate. A `checks-green` event now fires, carrying
      `{repo, item, pr_url}`, at both sites that reach
      `handoff_complete_review`'s gate the moment its `gate.word` reads
      `"clean"` — the Reviewer's own handoff in `agent-cycle.sh`, and the
      Enabler's `complete_handoff` recovery path in `lib/enabler.sh`.
    - **The merge itself.** `lib/merge-observed.sh`'s `merge-observed` event
      (requirement 32c, agent-ops#916) already fires at the Reviewer's own
      mid-pass reads. It now additionally fires at `lib/landing.sh`'s own arm
      site — `pr_merge_state` (`lib/handoff.sh`) confirms, rather than
      assumes from the arm method alone, whether that file's own no-queue
      auto-merge fallback merged the pull request synchronously (see that
      file's header on when it does) — and at
      `scripts/sweep-closed-issues.sh`'s own periodic sweep (wired through
      `lib/standdown.sh`), which already lists every merged, `pr_label`-
      labelled pull request fleet-wide, every stand-down, and so is the
      catch-all for a human-clicked merge or one GitHub's merge queue
      resolved after any other site last looked. The sweep's own emission is
      bounded by the same `pr_search_limit` its existing close action
      already is, and de-duplicated per node against a small, self-pruning
      seen-file (`<state_dir>/sweep-closed-issues-merge-observed-seen.json`).
      A seen-file the sweep cannot write does not fail the sweep — the
      caller still gets this run's own actions — but it does not pass
      unnoticed either: the sweep reports a `warning` action naming the
      file, since losing that write silently re-emits every key in the
      window on every future stand-down, into a log that is never rotated.
      `scripts/mine-merge-history.sh` — a GitHub-API miner and Stage 0
      autonomy baseline (#404/D18 §6), keyed by pull request rather than by
      item, reading no event log — is explicitly out of this requirement's
      scope (escalation #827) and is untouched.

    The fold itself assigns each item exactly one of six terminal fates —
    `landed`, `voided`, `superseded`, `blocked`, `abandoned`, `open`, checked
    in that priority order — over the item's own whole event history, which
    under `--since` is wider than the `instants` it reports, reusing
    `lib/cycle-state.sh`'s existing `void_items`/`blocked_items`/
    `draft_obsolete_flags` extracts for the set/clear resolution rather than
    re-deriving that logic a second time (the drift requirement 34a already
    warns against): each is matched to the item by the same `{repo, item}`
    lookup, so all three read the whole log regardless of `--since`. `blocked`
    outranks `abandoned` — a currently-blocked item is demonstrably still in
    the system, which is stronger evidence than the merely uncorroborated
    intent to abandon a draft that `abandoned` records. A `superseded` fate is
    read off an `orphan-branch-released {reason: "superseded"}` event whose
    `item` the fold itself derives from an `agent/<N>` branch, the same
    convention `scripts/sweep-closed-issues.sh` already uses — that event's
    own producer (`scripts/sweep-orphan-branches.sh`) is not one of the
    join-key sites above and is not touched. Like `landed`, `superseded` is
    read off the item's own whole event history, not only the events inside
    `--since`'s window: `--since` bounds which items are reported at all
    (population), never the fate an item that is reported resolves to (see
    `docs/FLOW-SCHEMA.md`'s window caveat). An item that is both void and
    already landed, with the void's own `ts` later than the earliest landing
    evidence, is a contradiction the fold does not resolve by guessing: it
    lands in `unaccounted[]` with the reason, counted, never dropped —
    `totals.balanced` states, and is asserted on a fixture exercising every
    fate at once, that `entered` equals `landed + voided + superseded +
    abandoned` (`leaving`) plus `blocked + open` (`in_progress`) plus
    `unaccounted`, which holds by construction. Voided-after-landed is
    deliberately the only contradiction detected this way for now —
    `docs/FLOW-SCHEMA.md`'s `unaccounted` section names the candidate
    siblings considered and deferred, and the rule for reactivating one.

    `scripts/pickup-metrics.sh`'s own first-seen/selection pairing
    (TD-PPagop-26081405, issue #248 acceptance 4) is generalised onto this
    same fold — `lib/item-lifecycle.sh`'s `item_lifecycle_pickup_pairs`, the
    identical reduction moved rather than duplicated — with its CLI contract,
    output field names and its own test unchanged.

50. **Node time-state record.** D21 of `docs/ROADMAP.md` names the time
    account's own invariant — every node-second in a window falls into
    exactly one of six states (producing, overhead, externally-blocked,
    idle-with-demand, idle-without-demand, down), and the states sum to
    node-count x window — and this requirement is where it is made
    checkable: a `node-state` transition event, logged the instant a node's
    own state changes, carrying the state it is entering, its cause (for the
    four states that have one, from a closed sixteen-token vocabulary), and
    the state it was in a moment before; and a pure fold,
    `lib/node-time-state.sh`'s `node_time_state_fold` (behind the read-only
    `scripts/node-time-state.sh`), reconstructing seconds per state from
    those events alone. `docs/FLOW-SCHEMA.md`'s "The node time-state record"
    section is the field-by-field contract — the six states, the definitional
    pin for what counts as `producing` versus `overhead`, the closed cause
    vocabulary and its mapping to states, how absence resolves to `down`, and
    the documented known limitations — under the same stability policy
    `docs/METERING-SCHEMA.md` already established.

    Most of the instants this record rides on already existed as ordinary
    events; what this requirement adds is narrower than D21's own list
    suggests:

    - **The transition itself**, emitted alongside an event that already
      fires: the cycle's opening `overhead`, logged once `acquire_lock`
      returns (`review-cycle.sh`: once its implementation-cycle check has
      passed), every `stage-start`
      (`stage_budget_apply`; `producing` for the Implementer and Reviewer
      only, `node_state_for_stage`, `overhead` for every other actor), every
      `stage-end` (`overhead` — `agent-cycle.sh`'s own two item-scoped sites,
      `lib/approver.sh`, `lib/enabler.sh`'s three, `lib/landing.sh`,
      `lib/refinement.sh`, `lib/stage-attempt.sh`'s Co-Ordinator site, and
      `review-cycle.sh`'s one `review-stage-end`), `limit-hit`
      (`externally-blocked`/`usage-limit`, `lib/candidate-select.sh`) and the
      automatic-probe `limit-cleared` (`overhead`, `lib/standdown.sh`).
    - **A `cause` field, from the closed vocabulary, on every `stand-down`
      site that previously carried none** — the two switch stand-downs
      (`disabled-node`/`disabled-fleet`), the two draining stand-downs
      (`no-demand`/`peer-claimed`), back-pressure, the no-op fingerprint
      short-circuit (`awaiting-tick`/`no-demand`, by
      `node_time_state_idle_split` over `eligible_items_total`), the GitHub
      API budget guard (`github-budget`) and the usage-limit cooldown
      (`usage-limit`), both in `lib/standdown.sh`. Four sites already carried
      a `cause` before this requirement (`unauthorized`, `disk-low`/
      `disk-full`, `memory-low`) and are unchanged; the claim-race
      stand-down's own four causes (`raced`, `unreachable`, `pre-claimed`,
      `untraceable`) are unchanged too, since renaming an
      existing field's values is breaking (docs/FLOW-SCHEMA.md's stability
      policy) — `node_time_state_for_cause` translates the three of those
      four this requirement's own vocabulary does not already share
      (`unreachable` needed no translation) onto `peer-claimed`/
      `coordinator-declined` only on the `node-state` event beside it, never
      on the `stand-down` event itself.
    - **The genuinely-nothing-selected `none-selected` sites**
      (`lib/stage-attempt.sh`, all three) classified by
      `node_time_state_idle_split` over that same cycle's own
      `eligible_items_total`: `idle-with-demand`/`coordinator-declined` when
      positive, the healthy `idle-without-demand`/`no-demand` zero otherwise.
    - **Deferred emission for a cycle's own terminal state**
      (`set_node_state_terminal`/`finalize_node_state_for_cycle`,
      `finalize_node_state_for_review`): every stand-down/none-selected site
      above records intent rather than logging immediately, because
      `agent-cycle.sh`'s exit trap can still run the Enabler and the Refiner
      afterward (requirement 35), and their own `stage-start`/`stage-end`
      pairs are real `overhead` that must land on the timeline before the
      node settles into the state the stand-down named. The deferred call,
      once at the true end of `cleanup`, logs whichever state was recorded,
      or — for a cycle that ran a stage and ended normally, so nothing
      called it — the idle state `eligible_items_total` (minus the one item
      just claimed, floored at zero) implies.
    - **`review-cycle.sh`'s own instrumentation**, on the same terms: its
      opening `overhead` and `review-end`, its one `review-stage-start`/
      `review-stage-end` pair, and a `cause` from the closed vocabulary on
      every one of its eight `review-stand-down` sites — including the
      usage-limit cooldown re-checked between repositories inside the review
      loop, which records `externally-blocked`/`usage-limit` rather than
      letting `finalize_node_state_for_review` file a node a limit stopped
      mid-sweep as the healthy `idle-without-demand` zero. The one exception
      is the `cause` value at "an implementation cycle is running":
      `peer-pipeline-busy`, deliberately outside the `node-state`
      vocabulary, since that site emits no transition to carry it.
    - **Silence for a tick that owns no node-second.** The account is per
      *node*, not per process, and the two pipelines have separate crontab
      lines and separate locks — so a tick can start, find the node already
      busy under the other process, and end having owned none of it. The
      three sites that are unconditionally this (`cycle-skipped`,
      `review-skipped`, and `review-cycle.sh`'s "an implementation cycle is
      running" `review-stand-down`, whose `cause: "peer-pipeline-busy"` is
      deliberately outside the `node-state` vocabulary) write their ordinary
      event and no `node-state` transition at all: they call
      `suppress_node_state_transitions`, which stops the deferred terminal
      transition, and they exit before the opening `overhead` is reached —
      which is why that one is logged after the lock is won rather than
      beside `cycle-start`. Six further `review-stand-down` sites are
      conditionally this and are silent on the same terms when the condition
      holds: the implementation-cycle check is the last ending in
      `review-cycle.sh` that can fire while `agent-cycle.sh` is mid-stage,
      not the first, so both switch stand-downs, both `not_before`
      stand-downs, the tier-two every-repository-held one and the usage-limit
      cooldown each call `suppress_node_state_if_peer_owns_node` beside their
      own `set_node_state_terminal`. That helper runs `impl_cycle_running`,
      the same `lock.json` pid probe the check below it uses, and
      `review_cycle_running`, the equivalent probe of `review-lock.json`,
      which ignores a lock naming this process's own pid — five of the six
      sites run ahead of this process's own lock acquisition, where any live
      pid is a peer by construction, but the usage-limit cooldown runs after
      it, over a lock file this run has just written its own pid into — and
      suppresses when either probe finds a live peer, implementation cycle or
      peer review run, owning the node; a node genuinely idle under both
      pipelines still records its idle state from these sites.
      `agent-cycle.sh`'s own two switch stand-downs are the one known gap in
      this rule and are documented as such (`docs/FLOW-SCHEMA.md`, "Known
      limitations"; issue #1268). This is #597's own named pitfall
      ("`cycle-skipped` is not a state"), and it is not cosmetic: the fold
      holds each point's state until the next point's `ts`, and a running
      stage emits nothing between its own `stage-start` and `stage-end`, so
      one skipped tick's transitions would relabel the rest of a live
      Implementer engagement — up to its backstop — as overhead and then as
      idle on the very timeline the busy process is writing. The maintenance
      chores (`publish-dashboard-launcher.sh`, `state-sync.sh`, `doctor.sh`,
      `rotate-logs.sh`) emit nothing for the related reason that they take
      neither lock and never stop a cycle starting.

    `scripts/node-time-state.sh` unions `log.jsonl` and `review-log.jsonl`
    (`lib/fleet.sh`'s `fleet_logs`, once per basename) before folding, since
    a node can run either pipeline — briefly, both at once — and folding only
    one would misread a node running the other as `down`. Five known
    limitations are stated rather than modelled further (docs/FLOW-SCHEMA.md
    has all of them in full, with the issues that carry them): the node set
    the invariant's denominator uses is
    every node that has *ever* emitted a `node-state` event, not evaluated
    per second of the window the way a node truly joining or leaving the
    fleet mid-window would need (#1248); two pipelines' events on one node are
    merged by `ts` alone, with no `producing > overhead` precedence for a
    genuine overlap (#1248), which is one reason the sites that would need it
    emit nothing instead; a node that *stops* holds its last state for the
    rest of the window rather than falling to `down`, so `down` covers a
    node's leading absence but not a crash or a decommission (#1250);
    `agent-cycle.sh`'s two switch stand-downs record their `down` from a tick
    that never won the lock, so a `--disable` issued mid-cycle relabels that
    cycle's own `producing` seconds until its next transition (#1268), the
    one ending in either script not covered by the silence rule above; a
    `--since`/`--until` bound that fails `fromdateiso8601` aborts the fold's
    one jq program and falls through to the conforming all-zero report
    rather than being rejected, unlike an event's own unparseable `ts`,
    which is skipped and counted (#1273); and
    `balanced` is a self-check on the reduction's arithmetic — every node's
    segments tile the window by construction — never evidence that the events
    reduced described the fleet correctly, for which `skipped_events` and
    `unaccounted` are the honest measures.

