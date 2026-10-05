## Requirements

### The Script — requirements, continued (part 9 of 10; 8e–59: **The classifier-escape audit re-checks the outcome, not jus…)

8e. **The classifier-escape audit re-checks the outcome, not just the
   decision (D18 Stage 2 exit criterion "zero classifier escapes";
   agent-ops#572).** Requirement 8d's `landing_eligible` is a decision:
   asking it whether its own decision was right is no check at all, so
   nothing above tests whether a pull request that actually landed
   autonomously was in fact eligible. `scripts/detect-classifier-escapes.sh`
   is that independent, read-only, post-hoc test — deliberately never
   calling `landing_eligible`, and never sourcing `lib/landing.sh` at all:
   the protected-path list and the routine-sources and routine-complexity
   resolutions are each reimplemented from scratch in the detector itself,
   so a bug shared between the classifier and its own auditor cannot pass
   unnoticed by both agreeing. Run once per cycle, fleet-wide regardless of
   `--repo`, and safe on `--dry-run` — it never arms or lands anything, only
   reads.

   For every repository, the detector considers every merged, `pr_label`-
   carrying pull request, oldest-created first (GitHub's own
   `sort=created&direction=asc`, which is creation order rather than merge
   order), and for each already carrying a `classifier-escape`,
   `landing-audit` or `landing-audit-skip` event for its `pr_url` in the
   fleet log skips it at zero `gh` cost (looked at most once, ever — a
   merged pull request's history is a fixed, past fact — and GitHub's
   `html_url` for a pull request is deterministic from its own repository
   and number, so an already-seen one is recognised before any read, not
   just before the reads past the first). For the remainder it reads
   `merged_by.login` (GitHub's live record, never this pipeline's own event
   log — trusting the log to say what it landed would make the audit
   circular): one merged by anyone other than the Approver App's login is
   not an audit finding — nothing armed that merge, so there is no
   eligibility to have recomputed — but the fact is recorded once, as
   `outcome: "not-approver"` (logged as its own `landing-audit-skip` event,
   kept out of `counts.escape_audits` below since it is not a finding), so
   the `repos/SLUG/pulls/N` read that established it is never paid again on
   a later cycle; one merged by the Approver App's login recomputes four
   things from the merged artefacts and from current configuration, never
   from what this pipeline recorded about its own decision: the
   protected-path hit, from the merge commit's own file list
   (`repos/SLUG/commits/SHA`, a different GitHub resource from
   `landing_protected_paths_hit`'s own read); the complexity, replayed from
   the pull request's labelled/unlabelled timeline up to `merged_at` — the
   label standing *at merge*, never today's; the work source, read back
   from the fleet log's own `landing-armed` event for that `pr_url`, the one
   input GitHub carries no field for at all; and the effective
   `merge_autonomy` level the landing was armed under — `landing_eligible`'s
   own first gate (requirement 8d), which this recomputation must not skip,
   since an Approver-identity merge at a level that forbids autonomous
   landing outright is exactly the shape a broken gate 1 would produce —
   read back from that same `landing-armed` event, which records it
   (requirement 34) at the moment gate 1 resolves it, kill switch and
   per-repo merge-budget freeze already folded in. The source and the level
   are the two inputs the detector reads as recorded rather than re-derives,
   and for the same reason: neither can be reconstructed after the fact, the
   level least of all, since this detector has no state-repo access and
   current configuration is not evidence of what was in force at a past
   merge. Reading today's configured level instead would break this
   requirement's own governing invariant in both directions — an operator's
   later dial-down would manufacture a first-class escape out of a landing
   that was correct when it happened, driving the Stage 2 exit criterion
   non-zero on an action with nothing wrong with it, while a since-cleared
   kill switch or since-lifted freeze would read a level that actually
   forbade landing as one that permitted it. Neither read-back makes the
   audit circular: the log never decides *what* gets audited — the candidate
   set is GitHub's own `merged_by` — and neither field is a verdict
   `landing_eligible` reached, only an input it was handed. The
   routine-sources list alone is still resolved fresh from current
   configuration (repo override, else the top level, else the default) — a
   real, accepted limitation, since nothing in this codebase preserves that
   key's history, so a landing audited long after a deliberate change to it
   is judged against today's list.

   `agent-cycle.sh` runs the detector once per repository per cycle under
   `timeout 120`, so a repository whose candidate list does not fit inside
   that budget is looked at only as far as one pass reaches, oldest
   candidate first. What a cycle spends re-confirming history it has
   already looked at shrinks as it goes — an already-seen pull request,
   whether previously audited or previously recorded as `not-approver`,
   costs nothing to skip (above) — and the oldest-first order means the
   ground one cycle covers stays covered rather than being displaced by
   newer merges landing ahead of it. Unlike an audit finding, a
   `not-approver` fact needs no eligibility recomputed, but the
   `repos/SLUG/pulls/N` read that discovers it is exactly as expensive, and
   recording it the same way is what stops that read recurring: a
   repository whose non-Approver-merged backlog alone exceeds one cycle's
   budget pays it down over as many cycles as it takes rather than at the
   same frontier forever, since every pull request a cycle reaches — either
   kind — becomes free to skip from the very next cycle onward. Measured
   against `Poetic-Poems/agent-ops` on 2026-08-22, before any of that
   backlog had ever been recorded: 190 merged `pr_label`-carrying pull
   requests, none of them merged by the Approver identity, at ~0.9 s per
   `repos/SLUG/pulls/N` read — about 170 s to record all of them once
   against the 120 s budget, so paying down that one-time backlog itself
   spans more than a single cycle. The `counts.escape_audits` totals the
   dashboard renders (below) are accordingly a floor on what has been
   checked at any given moment, but one that converges on complete coverage
   as a repository's backlog is paid down, rather than one permanently short
   of it.

   Any recomputed input that cannot be reconstructed — an unreadable,
   too-large-to-enumerate, or (short of either) file-count-capped merge
   commit, zero or more than one `complexity:*` label standing at merge
   time, no matching `landing-armed` event to read a source from, or a
   `landing-armed` event recording no effective level (one armed before that
   field existed) — reports `outcome: "unverifiable"`, never
   `"clean"`: an audit that cannot answer must never be read as an audit
   that passed, and in particular an unrecorded level is never allowed to
   become an escape. Otherwise, recomputed eligibility agrees with the fact
   that the pull request landed (`outcome: "clean"`) when the recorded
   effective level is `agent-merges-routine`/`agent-merges-all`, complexity
   is in the routine complexity list, the source is in the routine list, and
   no protected path was touched. A protected-path hit is level-dependent,
   the same way requirement 8d's own gate 2 is: below `agent-merges-all`
   it disagrees unconditionally, exactly like any other mismatched input; at
   `agent-merges-all`, `landing_eligible` itself reports `eligible` and
   defers the decision to gate 4.5's compensating controls
   (`landing_protected_path_controls_ok`) — facts (the approving tier, the
   standing review's own `submitted_at`/`commit_id`) this post-hoc detector
   has no way to recompute, so recording it as a disagreement would
   manufacture a first-class escape out of every sanctioned
   `agent-merges-all` protected-path landing. That case reports
   `outcome: "unverifiable"` instead, never `"clean"` and never `"escape"`,
   unless some other, genuinely reconstructable input already disagrees on
   its own — an out-of-range level, an out-of-range complexity, or a source
   outside the routine list — in which case that disagreement alone is
   still a `classifier-escape` regardless of the protected-path hit's own
   unverifiability. Any other disagreement is a `classifier-escape` event —
   the loud one, a first-class event of its own rather than a value nested
   inside a routine one, per the issue's own "make it loud rather than a row
   nobody reads". Every outcome is logged
   under the single-writer rule (requirement 33): the detector itself only
   prints one JSON object per newly-seen pull request to stdout, and
   `agent-cycle.sh`'s own loop — the same "sweep prints, the Script logs"
   shape `scripts/sweep-human-visibility.sh` already established — is what
   calls `log_event`.

   `scripts/publish-dashboard.sh` folds every `classifier-escape` and
   `landing-audit` event — never `landing-audit-skip`, which names a merge
   nothing armed rather than an audit finding — fleet-wide and all-time
   (never windowed — an escape is a permanent fact about one merged pull
   request, and a window that let it age out of view would be exactly the
   "row nobody reads" this requirement exists to prevent), into
   `counts.escape_audits` (`{checked, clean, escapes, unverifiable,
   escape_list: [...], unverifiable_list: [...]}`), and joins the newest
   audit outcome for each landed pull request's own `pr_url` into its row of
   the WI-8 autonomous-landing digest ("## The Landing Gate", requirement
   8d) as `audit`/`audit_reason` — a row with no audit yet (not merged long
   enough ago for the sweep to have reached it, merged by someone other than
   the Approver identity, or genuinely unauditable) reads `audit: null`,
   never folded into either `clean` or `escape`.
8f. **An open question the Reviewer could not settle holds unattended
    landing (D18, agent-ops#668).** Requirement 32's `open_questions` is
    additive to a `ready` verdict — the pull request still hands off exactly
    as it always has — and names a narrow case: nothing in the diff is
    wrong, but a question about the work order or its scope needs a
    decision the Reviewer is not the right actor to make. The Script
    projects `open-question` onto the pull request (`landing_open_question_
    label_project`, `lib/landing.sh`) the moment a `ready` verdict carries
    one or more, read-before-write exactly as `refinement_label_project`
    already is for the issue-side `blocked` (agent-ops#651's contract), and
    logs `open-question-raised` carrying the question, why the Reviewer
    could not settle it, and the PR comment stating it in the Reviewer's own
    words (requirement 30).

    `landing_open_question_label_project` documents exit 1 for its own
    `unrecorded` and `failed` words as ordinary outcomes, never a fault — a
    repository the pipeline has not created the label in yet is the
    practical case for `failed`. Its two call sites capture that outcome
    with `oq_proj="$(landing_open_question_label_project …)" || true`
    (agent-ops#889): a projection failure costs only the landing gate's
    label-based hold — logged truthfully in `label_projection` and warned
    on immediately below — and never the round itself, which reaches the
    Approver stage (requirement 8b) and the landing arming step
    (requirement 8d) exactly as a successful projection does.

    A further gate in `_landing_stage_attempt`, inserted between gate 2
    (eligibility) and gate 3 (the review gate), on the same terms as every
    gate beside it: `landing_open_question_hit` reads the label fresh from
    GitHub — never a log join, so a human's own removal of the label is
    seen the moment it happens, and requirement 8u's retry sweep re-reads it
    exactly as it re-reads every other gate, needing no second copy of this
    one either. A hit refuses, logged `landing-refused` with its own
    `open-question:` reason class (the same `class:detail` shape
    `landing_autonomy_refusal_reason`'s `kill-switch:` and `landing_
    eligible`'s `ineligible:` already establish, so the *Autonomous
    landings* panel's existing `byReason` grouping (`docs/DASHBOARD-
    SPEC.md`) surfaces it with no dashboard code change); a pass rides in
    the landing audit record (requirement 8x) as its own `open-question`
    gate, reading `clear` where no question stood and `settled` where one
    did and the adjudication pass below answered it on that same round — so
    a landing armed over a question is never indistinguishable, in the
    record, from one that never had a question at all. But a hit does
    not merely refuse: it resolves through the same `escalation_autonomy`
    ladder requirement 36b already reads (`escalation_autonomy_configured_
    level`, `lib/escalation-autonomy.sh`), level-aware rather than summoning
    a human outright:

    - At `always-escalate`, `open_question_escalate` files (or finds
      already-filed, via `create_escalation_issue`'s own dedup) one
      escalation issue per pull request — footer-keyed to a synthetic
      `pr-<n>-open-question` item reference, the same shape
      `pr-<n>-approver-adjudication` (requirement 8c) already uses — naming
      the question, and asking the human to answer it, take the
      `open-question` label off the pull request, and close the issue. The
      label is what the gate reads, so the label is what the issue body asks
      for first and names as the releasing act: the gate keeps refusing
      until it comes off, whatever the issue's own state. A closed issue
      means only that a human has acted — it restores the
      `adjudicate-first` pass below, and never releases the gate by itself.
    - At `adjudicate-first`, one bounded adjudication pass runs first
      (`run_open_question_adjudication`, `prompts/approver-adjudicate-open-
      question.md`) at the Approver's own critical tier
      (`approver_model_critical` — the tier D18 §5.2 already reserves for
      litigated judgement, never `enabler_model`: the question is about
      whether this pull request's own diff and work order already answer
      it, the Approver's own ground). `settled` posts the answer as a PR
      comment, logs `open-question-adjudication` carrying `verdict:
      "settled"` and `evidence`, releases the label
      (`landing_open_question_label_release`), and the gate clears —
      nothing else about the pull request changes. `escalate`, a stage
      failure, or an unparseable verdict all log the same event with
      `verdict: "escalate"` and reach `open_question_escalate` exactly as
      `always-escalate` does; "cannot settle" is not read as "nothing to
      settle" (requirement 8c). Bounded exactly as 36b is bounded — one
      pass per question, per human touch (`open_question_pass_available`,
      mirroring `escalation_autonomy_pass_available`'s own shape, including
      its "a human already acted" exemption: a closed escalation issue for
      this pull request's `pr-<n>-open-question` reference means the next
      pass is the first since they did) — a question already carrying an
      `open-question-adjudication` event escalates without a second pass.

    **Both rungs' own filing is rate-limited per close (agent-ops#779,
    decided on #784 as behaviour (b)), the identical guard requirement 8c
    applies to `approver_escalate`.** `create_escalation_issue`'s own dedup
    matches *open* issues only, so a human who closes the escalation issue
    without also removing the `open-question` label — closing is not the
    releasing act — would otherwise get a fresh issue on every subsequent
    refusing round. Before filing, `open_question_escalate` reads the most
    recently closed `enabler_escalation_label` issue for this pull request's
    own `pr-<n>-open-question` reference live from GitHub
    (`escalation_recent_close`, `lib/enabler.sh`). Filing is suppressed —
    logged as a `warning` naming the prior issue and the UTC instant the
    window lapses, with no GitHub write — while `now − closedAt` is less
    than `escalation_refile_after_hours` (`escalation_refile_suppressed`,
    `lib/escalation-autonomy.sh`, a pure comparator), *unless* it is the one
    immediate re-escalation a failed post-close adjudication owes: an
    adjudication pass ran this very round (the `adjudicate-first` rung's own
    `escalate` verdict reaching this call) *and* no `open-question-escalated`
    event for this pull request already exists on the log at or after that
    close (`escalation_event_logged_since`). That first post-close filing
    always proceeds, window or not — each human close buys at most one
    immediate re-file plus whatever the window permits after it lapses; the
    `always-escalate` rung, which never runs an adjudication pass, therefore
    always has this carve-out read false and is bound by the window alone.
    Whenever a recent close is found and the filing proceeds regardless of
    which of those two paths let it through, the issue body gains a "Why
    this is back" section naming the prior issue, its close time, and that
    removing the label — not closing the issue — is what still releases the
    gate. `escalation_refile_after_hours: 0` disables the guard outright,
    guarded explicitly rather than left to the arithmetic: every refusing
    round files, exactly as before this guard existed.

    **Distinct from requirement 8c's own refuse-streak adjudication in every
    way that requirement's own text calls for**: different trigger (an open
    question stands, never a refuse streak), different prompt
    (`prompts/approver-adjudicate-open-question.md`, never
    `prompts/approver.md` with a `## Prior refusals` section appended),
    different input (the question and its own comment, never prior refusal
    bodies), different event (`open-question-adjudication`, never
    `approver-verdict`), and never conflated with requirement 36b's own
    `enabler-adjudication` either — same ladder, different actor and tier.

    **Only two things clear `open-question`**: a `settled` adjudication
    verdict, or a human removing the label themselves. A new head commit
    does not — the question is about scope, not about the diff, so pushing
    more code answers nothing a label keyed to the diff's own head would
    correctly track. A later Reviewer round raising a further question
    while the label already stands logs its own `open-question-raised`
    event (the label projects `present`, not `added`) and leaves the pull
    request exactly as held as it already was.

    No identifier this requirement introduces names a human as the
    destination of the signal (requirement 45's own framing extended by
    agent-ops#679): `open-question`, `open_questions`, `open-question-
    raised`, `open-question-adjudication` and `open-question-escalated` all
    name the question, never where it goes.

    **Requirement 38 needs no change for this.** A pull request held on an
    open question is finished work not landing, the shape requirement 38
    exists to surface — but every gate round that refuses on a hit either
    settles the question or calls `open_question_escalate` before it
    returns, so the escalation issue (assigned to `enabler_assignee` under
    `enabler_escalation_label`, `open_question_escalate`'s own dedup finding
    it again on every later round) exists by the same round the refusal is
    logged, giving it exactly the visibility requirement 36a's own
    escalations get (Assigned-to-me) with no gap for a sweep to close.
62. **A persistent landing refusal says why, on the pull request itself, not
   only in the node log (issue #1979).** Requirement 8d's own gates refuse to
   arm a pull request for many reasons, logged as `landing-refused`
   (requirement 33) and nothing else — the pull request itself still shows
   only its ordinary approval and merge-box state, so a human reading it has
   no way to tell a routine wait from a silent, repeating refusal.
   `agent-ops#1950` is the live instance: `poetic-1` and `poetic-2` refused it
   roughly 25 times over 2026-09-29/30 with `ineligible:touches protected
   path(s): scripts/publish-dashboard.sh`, and the owner learned why only by
   asking an interactive session to read the node logs.

   `_landing_refuse` (`lib/landing.sh`) — the one function every refusal this
   stage makes already calls — classifies its own `class` argument as
   persistent or not (`_landing_refusal_persistent`,
   `_LANDING_PERSISTENT_REFUSAL_CLASSES`: `ineligible`, `autonomy-level`,
   `kill-switch`, `open-question`, `reconciliation-unanswered`,
   `human-changes-requested` and `merge-queue-occupied` — a subset of
   `_LANDING_REFUSAL_CLASSES`, `test/landing-wiring.test.sh` asserts — every
   class whose cause will not change without a new push, a configuration
   edit, a cool-off timer elapsing or a human act). A persistent refusal
   posts or updates, in place, one pipeline-marked comment on the pull
   request (`_landing_notice_upsert`) naming the class and the reason in
   words; a refusal whose cause touches `landing_cool_off_hours` states the
   absolute wall-clock time the pull request becomes eligible
   (`_landing_notice_eligible_at`), computed from the standing review's own
   `submitted_at` plus the configured cool-off, never the embedded "N hours
   remaining" figure, which is already stale by the time anyone reads the
   comment. A refusal outside this set (every `*-unreadable` class,
   `unknown`, `malformed-pr-url`, `arm-failed`, `review-gate`,
   `approver-review-not-approved`, and the two `dequeued-*` classes the
   `dequeued` work-order source already announces on its own terms) is a
   plain, retryable fact about the forge or this round's own mechanics, not
   this requirement's business, and writes nothing on the pull request at all
   — neither a notice of its own nor a "cleared" edit over a standing one (see
   below for why a refusal never clears). `merge_budget_decide`'s
   own `hold`/`refuse` outcomes (`merge-budget-hold`/`merge-budget-frozen`,
   requirement 33) are a distinct vocabulary `_landing_refuse` never sees —
   out of scope here, the same vocabularies-never-overlap note requirement 33
   itself makes.

   The same comment is found and edited in place on every later cycle, never
   re-posted: `pipeline_comment_upsert`/`pipeline_comment_edit_if_present`
   (`lib/pipeline-marker.sh`) look up the pull request's own standing comment
   by `pipeline_landing_notice_marker`'s invisible stamp (paired with the
   ordinary `pipeline_comment_header`/`pipeline_comment_marker` envelope
   every pipeline comment carries) via one paginated `gh api
   .../issues/<n>/comments` read (`pipeline_find_marked_comment`), matching on
   `PIPELINE_LANDING_NOTICE_MARKER_PREFIX` alone, and PATCH it
   (`repos/<slug>/issues/comments/<id>`) rather than post a second one.
   This is the generic "find and edit the pipeline's own prior comment on a
   pull request" primitive this issue introduces; nothing before it existed
   in this file.

   A write happens only on a change of what the notice says, never once per
   pass (issue #1601). That marker carries a stamp of the notice's own facts
   and nothing else — `_landing_notice_state`'s digest of the kind, class,
   `_landing_notice_normalized_reason`'s normalized reason, and eligible-at
   (`_landing_notice_stamp`) — which
   `_landing_notice_upsert`/`_landing_notice_clear` hand to
   `pipeline_comment_upsert`/`pipeline_comment_edit_if_present` as
   `UNCHANGED_IF_CONTAINS`: a standing comment already carrying that stamp is
   left alone, with no `gh` write at all.

   The reason is normalized, not used verbatim, because one persistent
   class's reason text is not actually stable: the protected-path cool-off's
   own reason embeds a "<N>h remaining" figure that
   `landing_protected_path_controls_ok` recomputes from wall-clock `now` on
   every pass, rounded to 0.1h — moving roughly every six minutes, faster
   than any cycle cadence, while nothing about the pull request's own
   situation has changed. Left in the digest, a standing cool-off refusal
   would mint a different stamp on essentially every retry, defeating the
   once-per-change rule this paragraph states for exactly the one class whose
   reason text was never actually stable. `_landing_notice_normalized_reason`
   collapses that clause to a fixed placeholder before hashing; the stable
   `(approved …, landing_cool_off_hours=…)` clause and the digest's own
   separate `eligible_at` already carry everything about the cool-off that is
   not purely a function of wall-clock read time, so nothing is lost. Every
   other persistent class's reason text is already stable, so normalizing it
   is a no-op. The body a human reads still shows the reason as given,
   countdown included, and the comment's own embedded stamp line is built
   from the same normalized reason so it matches what `_landing_notice_
   upsert` computes to decide whether to write at all — only the
   change-detection digest is normalized. Comparing the whole body cannot
   serve here, because the notice's own visible prose carries
   `pipeline_comment_header`'s node name and `pipeline_comment_marker`'s cycle
   id, both of which move every cycle and between nodes while the refusal
   stands unchanged. This matters because the 2.1e landing-retry sweep
   (`_landing_retry_sweep_repo`) re-enters `_landing_stage_attempt`, and
   therefore `_landing_refuse`, for the same still-open pull request every
   cycle it remains stranded, on every node: the `#1950` instance's roughly 25
   refusals becomes one comment and one write, not one comment and 25 edits —
   which would also bust `scripts/gather-source-state.sh`'s own `updated_at`-
   keyed open-PR digest, and so the no-op-skip fingerprint (`lib/noop-skip.sh`),
   every cycle a stranded pull request carried a notice.

   The notice is edited to say the hold has cleared — naming the arming method
   (`enqueued`/`auto-merge`), never silently deleted — in the one place this
   stage can soundly observe that: `_landing_stage_attempt`'s own successful
   arm, immediately before `landing-armed` is logged (`_landing_notice_clear`,
   built on `pipeline_comment_edit_if_present`'s own no-create guarantee — a
   pull request never notified in the first place gets no "cleared" comment
   either). A refusal never clears, whatever its class. A refusal is still a
   refusal, so telling a reader the hold has lifted would be false; and a
   refusal at one gate establishes only that the persistent gates *before* it
   in `_landing_stage_attempt`'s order passed this round, never anything about
   the gates after it, which were not evaluated — the protected-path cool-off
   (gate 4.5) sits after seven classes that are plain read failures, so a `gh`
   hiccup on any one of them would otherwise replace an accurate cool-off
   notice with a claim that nothing is holding the pull request, and restore
   it the next cycle. Arming is the one observation that establishes every
   gate passed. A notice whose named class has since stopped applying on a
   pull request that is still held is superseded by the next persistent
   refusal's own upsert; one on a pull request that leaves by a path this
   stage never revisits is #2034. Neither write touches a label, a gate
   verdict, or the merge-queue/budget state the gates themselves already
   decided — the notice is informational only, exactly as every other read in
   this function already is.
9. **Failure handling.** If any stage times out, exits non-zero, or returns
   an unparseable summary: kill that stage's process group, log
   `attempt-failed` with enough detail for a future cycle to know the item
   is blocked and what would unblock it, and — if a draft PR was already
   opened — comment on it that the agent has abandoned it and why, leaving
   the PR and branch for the human to keep or discard.

   Naming that pull request is the Script's job, not the failed stage's, and
   it tries four things in order, each less dependent on the stage than the
   last: the `pr_url` of a parseable final message; a pull-request URL
   grepped from the stage's output; the `.git/agent-ops-pr-url` breadcrumb in
   the clone (requirement 23); and finally an open pull request whose head is
   the branch this cycle claimed (requirement 17a), asked of GitHub directly.
   **The last of those is the one that must exist**, because the first three
   are all things the Implementer had to remember to do, and a stage that
   emitted no parseable final message is exactly a stage that may have
   remembered none of them — whereas the branch was computed and pushed by
   the Script before the stage began. Each lookup coming up empty is an
   ordinary outcome, not an error: under `errexit` a non-zero from any of
   them kills the cycle before it logs the very failure this requirement is
   about (see Gotchas).

   The consequences of failing to name it are not confined to this
   requirement, which is why the fourth lookup is required rather than
   merely sensible: no stage-failure comment reaches the pull request
   (above), no `pr_url` travels on the `attempt-failed` event (requirement
   32a), and so the Enabler's one power to clear this kind of block by act
   rather than by verdict — `complete_handoff`, gated on that field
   (requirement 32b) — is unavailable for precisely the failure it exists to
   recover.
9a. **A reported verdict is not a failure.** A stage that runs to completion
   and ends with `{"status": "blocked", …}` or `{"status": "void", …}`
   (requirement 27) has not failed: it has spent a full model run
   establishing something worth keeping. Record it against the selected item,
   carrying the stage's own words verbatim, rather than routing it through
   requirement 9's path (which would file it as "exited 0", discarding what it
   found) or, worse, dropping it. This is what stops the pipeline buying the
   same discovery every cycle for as long as the item exists.
9b. **`blocked` and `void` are different states and must not share one.**
   This is the requirement most likely to be read as pedantry and collapsed
   into "an item that can't proceed". Do not.
   - **`blocked`** — the work is real, something is in the way *for now* (an
     unmerged dependency, a red check, a decision nobody has taken). Record
     `attempt-failed` with the stage's `reason` and `unblock_condition`. The
     Co-Ordinator is expected to re-check these and clear them (`unblocked`)
     when the impediment lifts.
   - **`void`** — there is no work: the premise is false, almost always
     because the item is already done on `default_branch`. Pass the stage's
     `reason` and `evidence` through requirement 34d's shared corroboration
     guard first; record `item-void` only if it passes, `attempt-failed`
     (outcome `void-refused`) if it does not. **No agent may ever clear a
     recorded void**; only a human, by appending `unvoided` to the log by
     hand.
   The failure mode if you merge them is specific, silent, and was found in
   production rather than in review. An already-done recommendation is filed
   as `blocked`. The next Co-Ordinator, obeying its standing instruction to
   clear blockers that have gone away, checks the item, finds the work is
   done, correctly concludes that nothing is in its way, and logs `unblocked`.
   The item returns to the pool, is selected, is rediscovered as already done,
   and is filed again — indefinitely. Every component behaves exactly as
   specified. The bug is that one channel carried two meanings, so the
   evidence that should have shut the item forever (*the work is done*) was
   the very evidence that reopened it. If a state can be cleared by the same
   fact that ought to make it permanent, it is the wrong state.
9c. **A signal is a failure with a record.** The Script traps `TERM`, `INT`
   and `HUP` from the moment its cleanup trap is armed. The kills that reach
   it are real and routine — a peer taking over a stale lock TERMs the whole
   process group (requirement 1), an operator stops a container, a `--once`
   run is interrupted at the terminal — and before this requirement any of
   them ended bash between one statement and the next: no `attempt-failed`,
   no claim release, no `cycle-end`, and the in-flight stage's own process
   group (detached from the Script's by design, so the timeout can kill it
   whole) left running a model for a cycle that was already dead. The
   handler, in an order that is itself the requirement:
   1. kills the in-flight stage's process group, if any, with KILL — the
      signaller's patience is unknown and may be two seconds, and a stage
      whose cycle is dead has nothing left to negotiate;
   2. logs `attempt-failed` against the selected repo+item where one exists
      (so requirement 34's blocked extract sees the death), with detail
      `<stage> terminated by SIG<name>` naming the stage that was in flight
      — or `cycle` when none was — and carrying `pr_url` when the
      requirement-23 breadcrumb identifies one (read before the clone is
      deleted, since the breadcrumb dies with it);
   3. releases the claim (`have-pr` when a PR is known, `no-pr` otherwise),
      time-bounded to 8 seconds — releasing now beats waiting out the gc's
      `claim_ttl_hours`, but not at the price of the exit record — and
   4. exits `128+n` through the ordinary `exit`, so the EXIT trap still
      writes `cycle-end` with a truthful code, releases the lock and pushes
      state, and `maybe_run_enabler`'s cycle_rc guard skips the Enabler
      without being asked.
   A stage that had already ended cleanly is never blamed: the stage
   pid/name pair is advertised only while a stage is in flight. A signal
   landing during cleanup itself must not re-enter the handler.
   `review-cycle.sh` carries the same discipline as R7a of its own spec.
9d. **Visible attribution.** Every pull-request or issue comment this system
   posts — from `agent-cycle.sh` directly, and from the Implementer, Reviewer,
   Enabler and Refiner — opens with a leading bold line naming the Actor that
   wrote it and the node it ran on:

   ```
   **<Display>** · autonomous pipeline · node `<node>`
   ```

   then a blank line, then the comment's own prose. The Actor is whichever
   stage **wrote** the comment, not the one it is about — the Script's own
   stage-failure note carries `**Script**`, with the stage that failed named in
   the prose (`The Implementer stopped on this PR: …`), spelled from the same
   token→display map below, and no other preamble.
   This exists because requirement 3e's own text already states the reason no
   other signal can: every pipeline write lands under `warwickallen`, the same
   GitHub account a human also comments as, so the author field cannot tell a
   human's comment from the pipeline's, including which comments are a human's
   own. `lib/pipeline-marker.sh`'s `pipeline_comment_header ACTOR NODE` prints
   the line; `pipeline_actor_label TOKEN` is the token→display map, matching
   this document's, `docs/spec/review.md`'s and
   `docs/spec/monitor.md`'s *Actors* sections and
   the vocabulary `dashboard/index.html`'s `ACTOR` map already uses, and it
   fails open on an unknown token — prints it raw — so an Actor added later
   degrades gracefully rather than vanishing from a comment. `agent-cycle.sh`
   and `review-cycle.sh` call it directly; a model cannot source shell, so
   `prompts/implementer.md`, `prompts/reviewer.md`, `prompts/enabler.md` and
   `prompts/refiner.md` each spell the header's literal form out and instruct
   their stage to open every comment with it, using the node name each receives
   at invocation verbatim (`## Node` for the Implementer and Reviewer; the
   runtime input's `node` for the Enabler and the Refiner, each of which
   already received it). Regression-tested by
   `test/comment-identity.test.sh`.
9e. **Salvage before discard.** Before requirement 9's failure path fires on
   an unparseable final message — the Co-Ordinator, Implementer and Reviewer
   stages here, and requirement 37's Enabler engagement — the Script makes
   one bounded resume attempt, provided the failed run actually left a
   session behind to resume: `run_claude_stage` again, `--resume`d onto the
   `session_id` the failed run's own envelope carried, prompted with nothing
   but "return the verdict JSON object, nothing else." A run that timed out
   or exited non-zero has no living session behind it and is never salvaged
   — only a process that exited 0 and still left `extract_json_result`
   nothing to parse gets the attempt (`stage_salvage_result`,
   `lib/stage-attempt.sh`). The resume is capped at a fixed, conservative
   `stage_salvage_backstop_sec`/`stage_salvage_inactivity_sec` (5 minutes /
   90 seconds) rather than requirement 4f's adaptive per-(actor, repository,
   model) budget — a continuation with no tool calls needs none of that
   estimation, and a bound that could grow to a whole stage's own backstop is
   not a bound worth having.

   When the resume's own final message parses, its object is used exactly as
   if the original run had produced it — no failure is recorded here, no
   `attempt-failed`, no discard — and a `salvage` event with
   `outcome: "recovered"` is logged (requirement 33). When it does not
   (including when there was no session to resume at all), requirement 9's
   ordinary failure path runs unchanged, `salvage` events record
   `outcome: "attempted"` and `outcome: "failed"` for the attempt, and the
   resume's own use of `run_claude_stage` never leaks into the *original*
   run's kill-reason, gap or rate-limit bookkeeping — `stage_salvage_result`
   saves and restores them around its own call, because
   `detect_and_log_limit_hit` still reads them against the original `.out`
   file afterwards and must see what that run actually reported, not what
   the resume did.

   The fenced-block parse this backs up is itself widened alongside it: a
   verdict fenced without a `json` info string, or with a different one,
   parses on the straight fallback and never needs a salvage at all — only
   the fence's *presence*, not its tag, was ever what told a verdict apart
   from prose (issue #237).

   This exists because a model slipping the final-message contract is not
   evidence the work itself was wrong. On 2026-08-07, poetic-2's completed
   conflict resolution of PR #205 was correct, fenced without a `json` tag,
   and discarded anyway — erasing the pipeline's memory that the conflict
   was fixed and triggering a three-node duplicate-work cascade on the same
   PR. A background task left running past the final message ("I'll check
   back shortly") is the same shape from the runner's side: real work,
   wrapped wrong. A discard should cost a retry only when a stage genuinely
   produced nothing usable, not when the parser of the day could not yet see
   what it produced.
9f. **`needs-refinement` is the Implementer's own escape hatch, and a third
   state alongside `blocked` and `void` (extending requirement 9b).** A stage
   that ran to completion and reported `{"status": "needs-refinement", …}`
   (requirement 27) found real work whose *specification* — not the world
   around it — is what stopped it: no acceptance criterion it could find, a
   scope too vague for two implementations of it to agree. Recorded through
   `record_needs_refinement_block` (`lib/candidate-select.sh`), the same
   recorder a
   Co-Ordinator's own `needs_refinement` report uses (requirement 34e) and,
   independently, the Refiner's own decline (requirement 39d) — one
   definition (requirement 34a), three reporters, attributed by `stage`
   (`"coordinator"`, `"implementer"` or `"refiner"`) so a reader can tell
   which one found the gap.

   Distinct from `blocked` on purpose, on the same reasoning requirement 9b
   already gives `blocked` against `void`: `blocked` says something in the
   world is in the way and resolves when that changes; `needs-refinement`
   says the brief itself is short of what "done" would mean, and resolves
   only once someone — a human, or the Refiner working the item again — adds
   to it. Collapsing the two would age an honest "the spec doesn't say
   enough" on the same clock as "the build is red", when the two need
   entirely different attention and, per the reasoning below, different
   consequences for a `refined` mark the item might be carrying.

   If the item carried a `refined` mark (requirement 39c (The Refiner)) when the
   Implementer selected it, that mark no longer describes the item
   accurately — the specification it named was tried and found wanting — so
   recording the block also removes `refined_label` from the issue, if the
   item has one and carries it, mirroring `release_refinement_label`'s
   removal of `needs_refinement_label` when a block clears, but here on block
   *creation* rather than clearance, and for the positive label rather than
   the negative one. Requirement 3h's `refinements_map` independently stops
   naming the item from the moment a fresher `needs-refinement` block exists
   for it (comparing `ts` to `blocked_ts`), which is what stops a
   Co-Ordinator pasting a specification the Implementer has already found
   wanting into a future work order, whether or not the label removal itself
   succeeded.
10. **Usage-limit detection.** Two sources, and the structured one is
    preferred wherever it exists. When a stage was stopped because its stream
    reported the account `rejected` (requirement 4e), the `limit-hit` is
    derived from that `rate_limit_info` by `limit_decide_structured`: it
    states `resetsAt` as an epoch, so the stand-down is a fact rather than an
    estimate, and it is the only source available on that path at all, since a
    stage stopped at the refusal writes no final message for a phrase matcher
    to read. Otherwise — and whenever any `claude` invocation's transcript
    matches the shared pattern in `lib/limit-detect.sh` (`LIMIT_PHRASE_REGEX`
    — the generic `hit your .* limit` stem plus the legacy `usage limit` /
    `rate limit` / `usage cap` / `quota exceeded` terms; sourced by both the
    Script and `scripts/publish-dashboard.sh` so the two can't drift apart) —
    it is parsed out of the prose. Either way the event is a `limit-hit`
    carrying the same three fields, because no reader downstream should have
    to know which source produced it: `resume_at`, `class`, and
    `reset_known`:
    - `resume_at` is parsed from an ISO-8601 timestamp in the message if
      present, else from a human-readable weekly reset clause (e.g. "resets
      Jul 17, 4am (Pacific/Auckland)" — the named zone is applied via `TZ`,
      not left in the string for `date -d`, and never combined with `date -u`
      in the same call, which would silently override the named zone), else
      a fallback: now + `limit_cooldown_default` for an ordinary/transient
      match, or now + a much longer cooldown (`LIMIT_LONG_COOLDOWN_HOURS`,
      ~1 day) when the phrasing says "weekly" or "monthly" and no reset time
      could be parsed at all — that fallback is too short for something that
      recurs on a multi-day cadence.
    - `class` is `weekly`, `monthly`, or `other`.
    - `reset_known` is true only when a reset time was actually stated in the
      message. False means `resume_at` is the fallback above — this system's
      own retry interval, carrying no information about the real reset — and
      everything reported to a human must say so rather than presenting it as
      a deadline.

    `reset_known` replaced a `needs_human` flag that claimed the spend-cap
    case "clears only when a human raises the cap". Every limit has two
    exits: the plan's rollover, which needs no one, and a cap increase, which
    needs a human and only if sooner is wanted. Calling the first exit
    nonexistent turned an unknown reset time into an apparent dead end.
    Readers accept the superseded field during a rollout, inverting its sense
    (`lib/limit-detect.sh`'s `limit_reset_known`), so a peer on the previous
    release is not misread as authoritative.

    There is no supported API for querying a subscription plan's remaining
    quota, so this fail-safe detection *is* the quota check, and
    back-pressure (2.2) is the primary spend control. `resume_at` is an upper
    bound to stand down *until*, never a promise the block lasts that long —
    but nothing inside a cycle can shorten it, because 2.1 stands the cycle
    down before any stage runs. Lifting it early is `--clear-limit`'s job and
    only `--clear-limit`'s.
11. **Cleanup.** Always: delete the cycle's workspace, engage the Enabler if
    this cycle should (requirement 35), log the schedule slots this cycle's
    own run overlapped, if any (requirement 11a), write a `cycle-end` event,
    release the lock. Tee each stage's stdout/stderr to
    `state_dir/cycles/<cycle-id>/` for debugging.
11a. **Overrun-slot skips** (agent-ops#1287). supercronic will not start a job
    while the previous run of that job is still running: it logs the drop
    ("not starting: job is still running since … (…elapsed)") to the
    container log and nothing else records it, so a cycle that runs long
    loses its fleet a whole slot — or, on a fifteen-minute node, several —
    with no event of any kind in `log.jsonl`, reading `RUNNING` in
    `--status` and the dashboard the whole time while delivering nothing.

    Only the cycle holding the lock can ever know this happened: the process
    supercronic would have started for one of these firings never starts at
    all, so nothing else ever gets the chance to log it. At cleanup
    (requirement 11), before the lock releases and only for a cycle that
    actually acquired the lock *and* is the cron-fired original — its chain
    depth is 1 (requirement 39) and neither `--once` nor `--dry-run` was
    given — the Script computes which of its own schedule's
    slots fell strictly inside its own run — from its own start
    (`cycle_started_at`) and its own end, and its own already-defaulted
    `schedule` block (`cycle_hours`, `cycle_interval_minutes`,
    `excluded_minutes` — the same block `deploy/docker/render-crontab.sh`
    renders into the crontab, requirement 1d) — and writes one
    `cycle-skipped {reason: "overlap", slot_ts, held_by: <cycle id>,
    elapsed_s}` event per slot, oldest first. `slot_ts` is the dropped
    firing's own instant; `elapsed_s` is how long this cycle had already
    been running at that instant — the same quantity supercronic's own log
    line reports, computed independently here since this process never
    reads that log. The node's own base minute is never re-derived by
    re-hashing `NODE_NAME` the way that script's `hash_minute()` does:
    for the cron-fired original the gate above admits, `cycle_started_at` is
    a minute the real crontab already chose to fire this cycle on, so its own
    minute-of-hour serves directly, and no slot named this way can be one the
    crontab would not have fired — which an independent re-hash, drifting
    from the rendered schedule, could name.

    That gate is what makes the base minute trustworthy, and holding the lock
    alone would not: only the cron-fired original *is* supercronic's running
    job. A chained continuation (requirement 39) is spawned detached and
    disowned and its cron-fired parent then exits, ending supercronic's job,
    so the slots inside a chained cycle's run are not dropped at all — they
    fire, contend for the lock, and are already recorded by the contending
    tick as requirement 1's own `reason`-less `cycle-skipped`. Logging them
    here as well would double-count them, and at a fabricated `slot_ts`
    besides, since a chained cycle starts whenever its predecessor happened
    to finish — an arbitrary minute-of-hour, which the derivation above would
    take as the node's base. `--once` and `--dry-run` runs have the same
    shape: supercronic's job is untouched by them, so their firings land and
    contend as normal. Nothing is lost by the narrowing, because every slot
    it declines to name is one the contending tick recorded. A human running
    the script with neither flag is the one case left ungated, a known bound
    rather than an oversight: distinguishing it from the cron firing needs
    machinery this does not carry.

    What it names is the slot series running forward from *this* firing's
    own minute, repeating at `cycle_interval_minutes` within each allowed
    hour. That is the node's whole series only when the cycle fired on the
    lowest kept minute of its hour; a cycle that fired on a later one
    contributes no slot at any earlier minute-of-hour of any subsequent
    hour, because one firing minute does not identify which of the hour's
    kept minutes is the base (`:55` at a fifteen-minute interval is equally
    consistent with a base of 10, 25, 40 or 55). The error is one-sided:
    every event written names a firing that really was dropped, and the
    count is a lower bound on the firings lost, never an overstatement
    (agent-ops#1324) (`lib/schedule-slots.sh`'s `schedule_overrun_slots`,
    `test/schedule-slots.test.sh`).

    These are ordinary `cycle-skipped` events, sharing their name with
    requirement 1's own lock-contention case, but unlike that case they
    never call `suppress_node_state_transitions` (`docs/FLOW-SCHEMA.md`):
    the seconds they describe already belong to this cycle's own node-state
    timeline, finalized immediately before them at cleanup, not seconds of
    their own to account for separately.

    Two readers surface the count without this repository changing either:
    `scripts/publish-dashboard.sh`'s `noop_ticks` gains an `overlap` field —
    a flat count of the window's own `reason: "overlap"` events, never
    folded into `total`, since (unlike the stand-down/lock-held pair
    `noop_ticks` already counted) the cycle that logs one kept its own row
    in `cycles[]` by running real stages, and this is additional
    information about that row rather than a tick held out of the list
    (`docs/spec/dashboard/README.md`). `--status` gains an `overrun: N firing(s)
    overrun in the last 24h` line, this node's own count
    (`overlap_status_report`, `lib/manage.sh`) — `check-nodes.sh` (external
    to this repository; not committed here) already prints `--status` per
    node and so inherits it for free, on the same terms requirement 2.8's
    `stages:` section already does. The count reads the log through the
    tolerant event stream requirement 2.1's reduction reads (`union_events`)
    and skips a line that does not parse; a log not yet written counts zero, and
    a read that fails outright prints `overrun:  unreadable — this node's log
    could not be read` and reports a `guard-degraded` warning on stderr
    rather than a zero nobody counted.
12. **Flags.** `--dry-run` (run through step 5 then stop: prints the work
    order, launches no Implementer), `--once` (one verbose cycle in the
    foreground), `--repo <slug>` (restrict selection, for testing),
    `-h`/`--help` (print the usage text and exit), plus the
    switch's `--disable [<reason>] [--for <duration>] [--until <timestamp>]`,
    `--enable` and `--status` (requirement 2.3), which manage the switch and
    run no cycle.

    The usage text describes every flag the Script accepts, `--help`
    included: a flag the parser honours but the usage omits is one an
    operator can only find by reading the source.

    `--clear-limit [<reason>]` lifts a usage-limit stand-down (2.1) and runs
    no cycle either. It is deliberately not `--enable`: the switch and the
    stand-down are separate states with separate causes, and one command for
    both would let an operator clearing a spend cap silently re-enable a
    pipeline another agent had disabled to edit these files. It clears both
    carriers, reports what it lifted and what it could not, and warns loudly
    on a failed flag delete — a flag left set keeps every node down after the
    operator believes they have resumed. The reason is optional, unlike
    `--disable`'s: a stand-down being lifted is self-explanatory in a way one
    being imposed is not.

    `--kill-merge-autonomy [<reason>]` and `--restore-merge-autonomy`
    (requirement 2.3b) manage the D18 kill switch and run no cycle either. Like
    `--clear-limit` this is deliberately not `--disable`/`--enable`: killing
    merge autonomy stops nothing else — cycles keep running normally, only
    approval and landing are forced back to `human` — so folding it into the
    switch would make an operator editing these files also, incidentally, force
    every repo's landing decisions onto a human, or vice versa. The reason is
    required on `--kill-merge-autonomy`, the same terms as `--disable`'s: the
    next person to wonder why every repo is stuck at `human` is entitled to
    one. Neither takes `--this-node`: the kill switch has no node-scoped form,
    since a node-scoped merge-autonomy override would contradict the
    fleet-wide identity a single Approver App holds.
13. The Script must pass `shellcheck` and must set its own `PATH` explicitly
    (cron's environment is minimal), covering `claude`, `gh`, `git`, `jq`.
    When provisioning a host, prove that a cron-style invocation can resolve
    `claude` by running it from a minimal environment (for example with a
    sanitized `PATH` and `HOME`) before relying on scheduled runs.
39. **Finish-then-continue** (issue #248): a cycle that wins a claim and
    launches the Implementer may, once it has fully ended, launch another
    cycle immediately rather than leave the next one to the next cron
    firing — `lib/chain.sh`. Two conditions, both cheap, both judged from
    what the cycle already gathered ahead of the Co-Ordinator
    (`ordered_repos_json`, ready before requirement 3b's fingerprint is
    even taken):
    - **Sources remain.** At least one configured repository's `.sources` —
      already narrowed by back-pressure (2.2a) if it was tripped — is
      non-empty. This counts enabled source *categories*, not items, and is
      near-unconditional in practice: back-pressure narrows `.sources` to
      the four finish-work sources rather than to empty, so a repo
      configuring any of `review-feedback`/`merge-conflicts`/`dequeued`/
      `abandoned-drafts` keeps the count non-zero however back-pressured the
      fleet is. It is not a prediction that work remains — the chained
      cycle's own Co-Ordinator and gather decide that, and at full price,
      since the cycle just finished changed the no-op fingerprint (3b) with
      its own PR. In effect the cap below is the only gate that fires after
      a productive cycle, and its cost is a deliberate trade — see the
      finish-then-continue design decision.
    - **The lineage has room.** This cycle's own place in an unbroken chain
      of immediate continuations, 1 for the cron-fired original, is still
      under `max_chained_cycles` (default 3). A chained cycle inherits its
      place plus one via `AGENT_CYCLE_CHAIN_COUNT`; `max_chained_cycles: 1`
      disables chaining outright.

    Never chains on `--once` (a human or a test asked for exactly one
    cycle) or past any stand-down before the claim section, the switch, or
    a cycle that selected nothing — all of those end before a claim is ever
    attempted, so `chain_eligible` is never true for them. One stand-down
    *inside* the claim section does chain, under the same two conditions
    above: the `raced` stand-down (17a), where every attempted claim was
    lost to a peer. That cycle's Co-Ordinator engagement bought the
    knowledge that the fleet is busy, not that it is done — and the
    winners' claims, invisible when this cycle gathered, are exactly what
    the chained cycle's fresh gather and requirement 3q's filters see, so
    the continuation is routed to the next-best item instead of the same
    fight. The other three causes never chain: an `unreachable` or
    `pre-claimed` stand-down against a fresh cycle buys a second engagement
    into the same outage, or the same selection defect, and the same
    empty-handed ending; an `untraceable` stand-down (17f, 17h) is the
    Script's own construction-time check refusing to hand a candidate on,
    which no peer's claim or absence had any part in, so a fresh cycle
    would spend the same chain budget re-composing the same broken work
    order rather than routing around anyone.
    Nor does it chain over an untrapped crash or a signal: the gate
    is `chain_eligible` *and* this cycle's own `exit_code == 0`, checked in
    `cleanup` (11) after everything else there has already run — the lock
    released, the Enabler engaged, `cycle-end` logged, state pushed. Every
    *ordinary* ending after a won claim (complete, blocked, void, a handled
    stage failure) exits 0 like a stand-down does, and does still chain: a
    failed or blocked item must not stall the fleet from picking up a
    different one sooner. The chained cycle is a genuinely new process —
    its own cycle id, its own lock acquisition, its own full cleanup —
    launched with the original argv (`ORIGINAL_ARGV`, captured before flag
    parsing consumes it), detached (backgrounded, `disown`ed, stdin from
    `/dev/null`, stdout/stderr appended to the same `cron.log` a cron
    firing already writes to) so the parent never waits on it and its life
    does not depend on the parent's — and launched with the default
    dispositions for `TERM`, `INT` and `HUP` restored, because `cleanup`
    ignores all three before it spawns (9c) and an *ignored* signal is
    inherited across both fork and exec into a shell that can never take it
    back. Without that reset a chained cycle would run deaf to every signal
    9c's handler exists to catch, and requirement 1's stale-lock takeover
    would reach it only through the `KILL` that follows its ignored `TERM`
    — no `attempt-failed`, no `cycle-end`, no claim released.
39c. **A pending image roll overrides the chain, and widens the gap at every
    clean cycle-end, not only a chaining one** (agent-ops#1096, widened by
    agent-ops#1103). This covers two separable jobs, not one: cancelling a
    chain this cycle would otherwise take, and widening the gap a poll needs
    from whatever instant this cycle's own lock release happens to leave to
    one the five-minute poll is guaranteed to land in. A node running long or
    chained cycles never leaves `deploy/docker/watchtower-pre-update.sh` such
    a gap — every individual deferral stays correctly bounded by that
    pipeline's `lock_stale_after`, and the node still never rolls, because the
    next chained cycle's own claim reacquires the lock before the lock-free
    instant a poll would need — but the identical starvation reaches a node
    that is merely busy and never chains at all: chaining disabled
    (`max_chained_cycles: 1`), a chain that has exhausted `max_chained_cycles`,
    or any other clean cycle-end, since none of those leave more than the
    natural, possibly sub-second gap between this cycle's lock release and
    the next cron firing either. So immediately before the chain decision,
    inside the same `cleanup` (11), every cycle that ended cleanly
    (`exit_code == 0`) and was neither a `--once` nor a `--dry-run` run (a
    human or a test asking for exactly one cycle, real or dry, must not arm
    an override on the node it ran on) asks: is the image it is running
    behind the registry's newest
    (`lib/image-drift.sh`'s `image_drift_status`, read back through the
    identical cache the requirement-2.5 heartbeat push just above it already
    refreshed — no second registry round trip, no second signal)? If so,
    `chain_write_roll_pending` writes `$state_dir/roll-pending.json`
    (`{"until": <ISO8601>}`, `schedule.cycle_interval_minutes` from now,
    requirement 2.5's own exclusion list) regardless of `chain_eligible` —
    and, separately, `chain_image_behind` (`lib/chain.sh`) flips
    `chain_eligible` back to false wherever it was true — overriding, never
    granting, and a no-op on a cycle that was never going to chain anyway.
    `deploy/docker/watchtower-pre-update.sh` reads that marker back and
    honours it as an unconditional allow against `lock.json` alone —
    overriding only that pipeline's own ordinary in-flight-cycle deferral,
    never `review-lock.json`'s (agent-ops#1102: `review-cycle.sh` never wrote
    the marker and never decided to yield anything, so a project review
    beginning just after a yielding implementation cycle must keep deferring
    on its own ordinary judgement regardless) — until `until`: wide enough
    that the next poll is guaranteed to land inside it, which the true gap a
    declined chain (or a cycle with no chain to decline) leaves (the instant
    between this cycle's lock release and the next cron-fired cycle's own
    claim) is not.

    Because `until` is a fixed clock offset from this cycle's own end, not
    "the next cycle's own start", a cycle that reacquires `lock.json` before
    `until` passes would otherwise run its own stages underneath a marker
    that still authorises overriding that very lock (agent-ops#1102). So the
    other half of this mechanism runs at the *top* of every cycle, immediately
    after `acquire_lock`: if `$state_dir/roll-pending.json` exists, the same
    `image_drift_status` round trip (the identical TTL-backed cache, so this
    is a network call only when that cache was already due to refresh) is
    read again, and `chain_clear_landed_roll_pending` (`lib/chain.sh`) removes
    the marker unless the verdict still reads "behind". Re-acquiring the lock
    is itself the proof the gap the marker described has ended; once the
    verdict is no longer "behind" the marker has either already done its job
    (the roll landed in the gap) or was never earned by this node's own
    current image, and leaving it live either way would let a marker written
    for one roll authorise watchtower to destroy *this* cycle's own container
    for whatever publishes next. A verdict still reading "behind" leaves the
    marker untouched, and the cycle that just reacquired `lock.json` asks one
    further question before running its own stages under it (agent-ops#1102's
    own option 2): is watchtower actually invoking the pre-update hook and
    being turned away right now? `chain_updater_should_standdown`
    (`lib/chain.sh`) answers this off `lib/updater-health.sh`'s own
    `updater_status` verdict, read against the same `updater-ledger`
    directory the state-sync heartbeat already reads (no second signal) —
    "deferring", or "stuck" with `reason:"defer"`, both say watchtower is
    there and being refused; "rolled", a bare "stuck"/`reason:"allow"` (the
    roll is failing for reasons of its own, #1099's `Conflict` observation),
    and `null` (no live ledger evidence at all) all say idling fixes nothing,
    so the cycle runs normally. When it does say so, the cycle idles instead
    of running: it logs a `stand-down` naming `cause: "roll-pending"` and the
    marker's own `until`, settles into `externally-blocked`/`roll-pending`
    (`set_node_state_terminal`, `docs/FLOW-SCHEMA.md`'s closed cause
    vocabulary), and exits 0 without ever reaching the Co-Ordinator — `chain_
    eligible` plays no part, since it is never raised this early in the
    cycle. This is capped at one stand-down per pending marker (`chain_roll_
    standdown_available`/`chain_roll_standdown_record`, `$state_dir/roll-
    standdown.json`): even a verdict that stays wrong every cycle cannot idle
    a node indefinitely, so a second cycle under the same still-live,
    still-"behind" marker logs a `roll-standdown-capped` event naming the
    marker and the spent count instead, and runs normally. The counter is
    cleared alongside the marker itself, by the same `chain_clear_landed_
    roll_pending` call above, once the verdict stops reading "behind" — so a
    later, genuinely new pending roll earns its own fresh stand-down
    allowance.

    The result is the bound the hook's own header now states: one cycle's
    length for a node that is merely busy, and `lock_stale_after` only for
    one that is actually wedged and so never reaches this check at all.
17d. **Race-loss observability**: how many candidates a cycle lost to a peer
    genuinely holding the item (17a's `cause: "held"`, as opposed to
    `"unreachable"`) before it won its own claim, or — on the cycle that
    exhausts every candidate — before it stood down. Carried as
    `race_losses` on the `selection` event (only when it is greater than
    zero — 17a) and on that stand-down's event. Candidates skipped as
    pre-claimed (17a's `claim-skipped`) are deliberately *not* race
    losses and never inflate this count: a loss knowable from the cycle's
    own gather is a selection defect wearing contention's clothes, and
    folding it in would make the fleet look busier against itself than it
    is — the miscounting that let a day of one Co-Ordinator re-proposing
    four already-claimed issues read as healthy racing.
    A cycle recovering a race (winning after one or more losses) is
    healthy contention, not a fault: `scripts/publish-dashboard.sh` and
    `dashboard/index.html` surface it as an informational "recovered race
    ×N" badge, on the cycle history, the live-cycle panel and the fleet
    cards, wherever that cycle's `title`/`source` already render (never a
    warning colour). A cycle that lost *every* candidate recovered nothing
    and never carries that badge; it is marked instead beside its outcome,
    where the plain "Stood down" verdict cannot say by itself whether the
    fleet's own contention or a GitHub outage produced it — the same
    informational colour, and DASHBOARD-SPEC's `raced` / `standdown_cause`
    is the shape both readings come from. Faster cadence and
    finish-then-continue (39) both
    raise how often nodes contend for the same item, which is why this
    became worth watching rather than left to a `claim-lost` grep.
54. **Wake-poll: an event-driven wake between cron firings (D14, issue
    #613).** `scripts/wake-poll.sh`, on its own crontab line
    (`schedule.wake_poll_minutes`, default 2m — well under
    `cycle_interval_minutes`'s own 15m default), does one conditional GET
    (`If-None-Match`) per configured repository against a small, fixed set
    of endpoints, and invokes `agent-cycle.sh` — the identical entry point
    the cron line's own `@CYCLE_MINUTE@` firing uses, so a woken node
    takes the same lock (requirement 1), the same claims (17a), and the
    same back-pressure cap as a cron-fired one — the moment any of them
    answers with real content rather than a `304`. This shortens pickup
    latency for a source-relevant event without widening the
    concurrent-claim window: nothing on the claim path changes, only how
    soon `agent-cycle.sh` is invoked.

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

57. **Liveness: is supercronic still firing this node's jobs at all (issue
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

58. **Readiness: could a cycle start now.** `lib/node-health.sh`'s
    `node_health_readiness` composes a `{ready, unmet}` verdict from facts
    `scripts/node-health.sh --ready` gathers, every unmet condition named
    by its own stable code rather than folded into a bare boolean:
    `credentials-missing` (`$CLAUDE_CONFIG_DIR/.credentials.json` absent —
    existence only, on the same terms `scripts/doctor.sh --unattended`
    already holds to, requirement 1c), `gh-unauthenticated`/
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

    58a. **No network call beyond the one exempt read, and no live fetch of
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

59. **Health: is this node doing its job over time, composed from named
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

    59a. **`updater` and `image` component mappings.** `updater`: `stuck`
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

