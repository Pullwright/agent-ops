## Requirements

### The Script — requirements, continued (part 9 of 13; 8e–62: The classifier-escape audit re-checks the outcome, not just the decision…)

8e. <a id="impl-8e"></a>**The classifier-escape audit re-checks the outcome, not just the
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
8f. <a id="impl-8f"></a>**An open question the Reviewer could not settle holds unattended
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
    seen the moment it happens, and acceptance check 8u's retry sweep re-reads it
    exactly as it re-reads every other gate, needing no second copy of this
    one either. A hit refuses, logged `landing-refused` with its own
    `open-question:` reason class (the same `class:detail` shape
    `landing_autonomy_refusal_reason`'s `kill-switch:` and `landing_
    eligible`'s `ineligible:` already establish, so the *Autonomous
    landings* panel's existing `byReason` grouping (`docs/DASHBOARD-
    SPEC.md`) surfaces it with no dashboard code change); a pass rides in
    the landing audit record (acceptance check 8x) as its own `open-question`
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

    **Both rungs' filing checks for a standing open issue
    (`escalation_open_existing`), skipping the guard below if found;
    otherwise it is rate-limited per close (agent-ops#779, decided on #784),
    requirement 8c's same guard for
    `approver_escalate`.** `create_escalation_issue`'s own dedup
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
8w. <a id="impl-8w"></a>**Gate 4.5's protected-path-tier sub-case re-engages the Approver at the
   critical tier, rather than only re-arming landing (issue #2514).** A
   landing-retry sweep re-arm (acceptance check 8u) that finds gate 4.5's
   protected-path-tier sub-case — the recorded tier `landing_retry_tier`
   reads back is empty or below `critical`, or no usable approval timestamp
   could be established — can never clear it by retrying landing again: that
   recorded tier is fixed at whatever round wrote it, and nothing about
   re-arming changes it, the identical "confident, recurring no-op" shape
   requirement 62's own `agent-ops#1950` instance names, except here it is a
   landing attempt holding forever rather than a Co-Ordinator cycle.

   `_landing_protected_path_tier_resolve` (`lib/landing.sh`) is gate 4.5's own
   call, made only on a retry (never the round that first ran the Approver,
   which already forces the critical tier for a genuine protected-path hit —
   requirement 8b's own `critical_reason`) and only for this one sub-case —
   every other `protected-path-*` refusal (cool-off, stale head) and every
   other gate are untouched. It is capped at one reapproval pass per
   occurrence, an occurrence being the pull request's current head commit
   read fresh from GitHub (`protected_path_tier_reapproval_attempted_before`,
   keyed on a `protected-path-tier-reapproval` event already logged for that
   `pr_url`/head pair) — mirroring requirement 8f's own "one pass per human
   touch" bound, with a fresh push standing in for a human's own touch, since
   a push already earns its own fresh pass everywhere else this gate reasons
   about this control (the stale-head sub-case's rule). That cap is read
   fleet-wide — the `union_log` snapshot, falling back to this node's own
   stream, exactly as requirement 8f's own `open_question_pass_available`
   reads its cap and as gate 4.5 reads the tier that triggered the call:
   acceptance check 8u's sweep runs on every node, so a cap keyed to one node's
   stream alone would let each node spend its own pass over the same
   unchanged head commit. A head whose pass is
   already spent skips the reapproval and escalates directly, the same
   `always-escalate`-shaped ladder requirement 8f's own open-question gate
   uses, keyed to a synthetic `pr-<n>-protected-path-tier` item reference
   (`protected_path_tier_escalate`, rate-limited by the same
   `escalation_recent_close`/`escalation_refile_suppressed` guard requirement
   8f's own `open_question_escalate` applies).

   The reapproval pass itself (`run_protected_path_tier_reapproval`) is a
   fresh, narrow engagement at the Approver's own critical tier
   (`approver_model_critical`, never `run_approver_stage` — that function is
   the ordinary once-per-round review, tied to globals this retry sweep,
   running across every configured repository, does not carry), against
   `prompts/approver-reapprove-protected-path-tier.md`, reading the pull
   request's diff directly (`gh pr diff`, no clone) rather than `run_
   approver_stage`'s full ceremony. On `approve` it posts a real GitHub
   review under the Approver App's own identity and logs the resulting
   `approver-verdict` event itself — `tier: "critical"`, `critical_reason:
   "protected-path-tier-reapproval"` — exactly the event `landing_retry_tier`
   already reads for every ordinary round, so a later retry sees it with no
   further plumbing. A missing `approver_model_critical`, a missing prompt
   file, an unreadable credential, a stage failure, an unparseable verdict,
   a token that cannot be minted to post the review, or a review write that
   reaches this point but does not land on GitHub (`approver_post_or_warn`
   always returns 0 regardless of the write's own outcome, so this is read
   off `approver_last_post_ok` rather than the call's exit status) all print
   `escalate` and log nothing to `approver-verdict`, since none of them
   resulted in anything this pipeline can vouch for having reached GitHub.

   `_landing_protected_path_tier_resolve` never hands the caller a bare
   pass/fail: it re-reads the pull request's own live standing review and
   tier after the attempt and prints whatever `landing_protected_path_
   controls_ok` now reports — `ok` once a fresh critical-tier approval is
   standing and every other control (head match, cool-off) also clears, or,
   almost always on a successful reapproval, a brand-new cool-off wait
   (the fresh approval's own `submitted_at` is "now", so the ordinary
   `landing_cool_off_hours` wait still applies before this pull request can
   land). Gate 4.5's own dispatch below always classifies this *current*
   value through the same `cooloff`/`tier`/`stale-head`/`ineligible`/
   `unknown` case every other call already uses, never the stale class that
   triggered the call — a successful reapproval therefore refuses, if it
   refuses at all, under `protected-path-cooloff`, never `protected-path-
   tier` a second time.

   The escalation is bounded by that same recomputed value, and fires only
   while the sub-case this pass exists to clear is itself still standing —
   the tier or the missing-timestamp wording, the two gate 4.5 triggers the
   call on. A recomputed verdict of `ok`, a fresh cool-off wait, a stale head
   or an `unknown:*` read failure each refuse (or arm) on their own ordinary
   terms and raise nothing for a human: the dominant outcome of a *successful*
   reapproval is the brand-new cool-off above, which is this gate working as
   designed and clears itself unattended, so an escalation there would assert
   that a critical-tier approval "could not be established" moments after
   this function established one, for a pull request with nothing left for
   anyone to do. An `unknown:*` verdict is held back on the same reasoning
   requirement 8d applies to every unreadable control: it means the gate
   could not ask, so the next retry asks again rather than a human being
   asked instead. This holds even when the posted review itself succeeded: a
   reapproval that approved and posted, followed by a transient failure of
   this same function's own live recheck (its own identity read, or its own
   standing-review read), hands back `unknown:*` rather than the stale
   triggering value — falling through unchanged would otherwise escalate on
   the strength of a read failure moments after a critical-tier approval was
   established, the one outcome this paragraph exists to rule out.
62. <a id="impl-62"></a>**A persistent landing refusal says why, on the pull request itself, not
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
   `kill-switch`, `open-question`, `protected-path-cooloff`,
   `protected-path-stale-head`, `protected-path-tier`,
   `reconciliation-unanswered`, `human-changes-requested` and
   `merge-queue-occupied` — a subset of `_LANDING_REFUSAL_CLASSES`,
   `test/landing-wiring.test.sh` asserts — every class whose cause will not
   change without a new push, a configuration edit, a cool-off timer
   elapsing or a human act; the `protected-path-*` trio (issue #1992) is
   gate 4.5's own three distinct compensating-control refusals, named apart
   from the generic `ineligible` every other gate still shares). A
   persistent refusal
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
