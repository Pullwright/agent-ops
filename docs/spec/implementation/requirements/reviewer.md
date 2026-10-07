## Requirements

### The Reviewer

28. Operates under the same one-shot constraint as the Implementer
    (requirement 21): no resumption, no background notification. It waits
    for slow commands — installs, builds, `gh pr checks --watch` — in the
    foreground within the same session rather than ending its turn early.
29. Reviews the PR against the work order's item and acceptance notes, and
    against the target repo's own standards and conventions; re-runs the
    repo's checks, and re-runs requirement 24a's preview check rather than
    trusting the Implementer's — a preview deployment is per head SHA, and any
    fix this stage pushes mints a new one.
29a. **A large test suite is run in pieces, never as one invocation
    (agent-ops#734).** The Bash tool this stage's own tool-calling harness
    provides enforces a fixed 10-minute ceiling per command: a command still
    running there is killed and returns no output at all, not even what had
    already completed, so a suite that mostly passed behind a slow batch is
    indistinguishable, from the outside, from one that never ran. This
    repo's own `test/` suite (well over a hundred files) run through a single
    `scripts/run-tests.sh` invocation risks exactly that wall, so requirement
    29's re-run lists the selected tests first (`scripts/run-tests.sh
    --list`, host-side, no Docker, returns instantly), splits that list into
    groups sized to finish comfortably inside the ceiling, and invokes
    `scripts/run-tests.sh` once per group — each group's own `PASS`/`FAIL`
    lines are read before the next group runs, so a group that never finishes
    costs only itself, not the whole suite's evidence. A Reviewer instead
    retried the same unbatched invocation three times, losing 30 of its
    90-minute budget to three identical 10-minute kills, then spent the rest
    re-batching ad hoc and still did not finish before the session's own
    final message came due — the entire review, its already-completed
    findings included, was recorded as a failed attempt with nothing to show
    for it (requirement 30a exists for the same reason, on the findings'
    side; this is the same failure on the test-evidence side).
30. Where it finds a problem it can fix with confidence, it fixes it
    directly on the branch — committing, rebasing onto the current default
    branch, or force-pushing as it judges best, always with
    `--force-with-lease` (permitted only on `branch_prefix` branches, per
    "The Landing Gate"). Where it cannot fix
    with confidence, it leaves a PR review comment describing the problem
    for the Human Reviewer. A `complexity:*` label (requirement 26a) plainly
    wrong for the diff counts as such a problem: having just read the whole
    diff, the Reviewer is better placed than the author, and corrects the
    label in either direction — the label endures for later finishing rounds
    (requirement 8a) and for the human. The ordinary pull request stays a
    draft throughout, which GitHub does not allow to be queued, so no
    merge-queue check applies to it here; the `review-feedback` source is the
    one case where it does, since that pull request is never a draft during
    the Reviewer's session (requirement 38f).
30a. **Emits as it goes, not only at the end.** Requirement 23a's counterpart
    for the Reviewer, and it binds harder here: an Implementer that is killed
    at least leaves the branch it has been building, whereas a review exists
    only as commits and comments that have reached GitHub. Everything else is
    in an ephemeral clone and in a stage that may not finish. So each fix under
    requirement 30 is pushed when it is made rather than held for requirement
    31's confirmation push, and each finding is posted when it is formed rather
    than batched into a closing pass. Comments carry `lib/pipeline-marker.sh`'s
    invisible marker, so requirement 3e's activity clock already discounts them
    (TD26072605) and there is no cost to posting more of them. This is what
    lets an interrupted review's successor start from what has already been
    established rather than from the diff — and, where nothing supersedes them,
    lets the findings a killed stage did reach still travel to the human.

    The failure it closes is total, not partial. On agent-ops#205 a Reviewer ran
    for the whole of its 45-minute cap and was killed; it left no commit, no
    review and no comment, so 45 minutes of Opus review produced nothing that
    outlived the clone. A stage cannot be stopped from dying mid-review, but it
    can be stopped from dying with everything still inside it.
30b. **Reports completion, unconditionally.** Every run posts exactly one more
    comment beyond requirement 30a's findings: a completion comment stating the
    review has finished and what it concluded, posted whether or not
    requirement 30 found anything — a clean PR is otherwise indistinguishable
    from one no Reviewer has looked at yet, since every write lands under the
    same account a human also comments as (requirement 9d). It is a separate
    `gh pr comment` call, never folded into a findings comment and never filed
    as a review (`gh pr review --comment`), carrying the same header and marker
    as every other pipeline comment (requirements 9d, 3e) plus four facts: the
    outcome (handed to the human, or left in draft and why), the CI state, the
    fixes requirement 30 pushed (or none), and the number of concerns
    requirement 30a raised (or none, stated plainly when the PR was otherwise
    green). Requirement 32's `comments_left` still counts only requirement
    30a's findings comments — this one is never among them.

    On the `ready` path it is the last act, posted after requirement 31's
    hand-off and requirement 31b's re-request, so it can state the true final
    state; on the `blocked` path, which never reaches requirement 31, it is
    posted immediately before requirement 32's final JSON. A post that fails
    does not become a `blocked` outcome — a comment that could not be written
    is not a review that did not happen — the Reviewer carries on and reports
    its verdict as normal.
30c. **Reconciles every standing human comment before marking a pull request
    ready (requirement 31c, agent-ops#533).** A human cannot leave a formal
    `REQUEST_CHANGES` review on this system's own pull requests — every
    pipeline write and every human comment on them land under the same
    GitHub account, and GitHub refuses that review type from a pull request's
    own author regardless of who is actually typing — so a plain PR comment,
    often paired with converting the pull request back to draft, is the
    change-request signal here (PR #512). Before requirement 31's hand-off,
    the Reviewer reads every general PR comment from a non-Bot account whose
    body carries no pipeline marker, posted since the pull request's most
    recent `ready_for_review` timeline event as it found it — one that was
    not itself later undone by a `convert_to_draft` event — or its own
    creation time, when no such surviving event exists, and answers each —
    implementing it under requirement 30, or explicitly contesting it in the
    completion comment's own prose — never leaving one unmentioned. "As it
    found it" is what makes this read possible at all: requirement 31's own
    `gh pr ready`, run later in the same session, mints a fresh
    `ready_for_review` event, so a Reviewer that read the anchor afterwards
    would find its own flip and no standing comment at all. The undone-event
    exclusion matters here for a second reason, not merely a subtler
    restatement of the first: a *previous* round can have left a
    `ready_for_review` event on this pull request that this pipeline itself
    later reverted (requirement 31c's own gate, on a `dirty` verdict,
    agent-ops#539) — GitHub keeps that event on the timeline regardless — and
    reading "most recent" without excluding it finds that stale flip instead,
    reading a still-unreconciled comment as ancient history one round after
    the round that refused it. This is the same trap requirement 31c's gate,
    which runs later still, answers by bounding its read at the cycle's start
    and skipping any undone flip within that bound. It cites every one it
    answers with its own
    `<!-- agent-ops:reconciles comment=<id> -->` line in that same completion
    comment, `<id>` the comment's own issue-comment id: a citation, because
    whether a diff actually answers a human's words is a judgement only the
    Reviewer can make, and the mechanism past this point can only confirm one
    was attempted, never judge it. Requirement 31c's own reconciliation gate
    reads this pull request's comments independently before acting on a
    `ready` verdict, refuses the hand-off for any standing comment it finds
    uncited, and — unlike the Reviewer's own read above — also puts the pull
    request back in draft when it does.
30d. **Filing deferred work inline, and the scope carve-out that goes with it
    (agent-ops#631).** Like the Implementer (requirement 24b), the Reviewer
    may notice genuine deferred work that does not belong in this pull
    request — a design gap in code the diff merely touches, something worth a
    human's attention that isn't itself a defect to fix under requirement 30.
    Rather than lose it to a step-32 comment nothing later sweeps for unfiled
    debt, it is filed the same way: dedup-search (`gh issue list --label
    pw::type:tech-debt --search "<working title>"`) first, then `gh issue
    create` labelled `pw::type:tech-debt` (or an unlabelled one, for a
    question rather than a scoped fix) plus a `Defers: #<n>` line added to
    the pull request's own body — riding along whether the Implementer or
    the Reviewer is the one who added it. A `Defers:`-linked issue with no
    accompanying code change is, for both stages, never itself grounds to
    flag a defect, correct the `complexity:*` label upward, or read the diff
    as having grown beyond its scope.
30e. **Verifying every `Defers:` link (D15 as revised, #869/#875/#879).** A
    `Defers: #<n>` line the Implementer (or an earlier Reviewer pass) added
    is a claim that issue `#<n>` exists and carries `pw::type:tech-debt` —
    the label is what makes it selectable as this band's own work later, and
    a typo'd number or a missing label leaves it invisible to both a human
    and `scripts/gather-tech-debt.sh` alike. The Reviewer confirms both
    (`gh issue view <n> --json state,labels`) for every `Defers:` line the
    pull request body carries, fixing what it can — the number, or the label
    on an issue that is genuinely a debt item simply filed without it — under
    requirement 30, and flagging the rest under requirement 32. A `Defers:`
    line is never also a closing keyword for the same `N`: a body caught
    both resolving and deferring the same number is a defect in the body,
    fixed by keeping whichever the diff actually does.
31. **Confirms CI is passing — every one of the target repo's branch-ruleset
    required status checks green at the pull request's current head commit
    (`gh pr checks --required`), the same subset requirement 31c
    independently re-verifies — and the PR is mergeable, then marks it ready
    for review (`gh pr ready`), and where a human's review is what blocks it,
    requests a fresh one from them (requirement 31b).** A status check
    outside that required subset failing is never, by itself, grounds for
    `blocked`: it is named in the `ci` field instead (requirement 32) rather
    than hidden behind a bare `passing`. Reading any failing check, required
    or not, as the trigger for `blocked` conflates the two and has produced
    both errors in practice: a bare `passing` reported over a red
    non-required check (PR #2176, masking it from the Approver), and
    `blocked` reported over a pull request every required check had already
    cleared, for the identical red non-required check (PR #2170, agent-ops#2179).
    It never approves and never merges. A `ready` verdict is itself re-verified
    against GitHub before any of this runs (requirement 31c) — the Reviewer's
    own confirmation is a model's, and the Script's is not.
31a. **The handoff is verified, not reported.** Requirement 31 is the pipeline's
    only irreversible outward act, and requirement 32 has the Reviewer *describe*
    it — two different things. Before recording `pr-ready` the Script asks GitHub
    whether the pull request is a draft (`gh pr view --json isDraft`), and:
    - not a draft — log `pr-ready` with `handoff: "reviewer"`. The ordinary path,
      one field on one PR;
    - still a draft — run `gh pr ready` itself, re-read the flag, and on success
      log a `warning` naming the PR and then `pr-ready` with `handoff: "script"`.
      The judgement is the expensive half and the Reviewer has made it; the flip
      is mechanism, and mechanism the Script can perform deterministically. It
      completes rather than fails, so a certified PR is never put in front of a
      human as a problem;
    - still a draft after that, or the flag unreadable — requirement 32a.

    Fail towards the state something else will look at: "could not ask" must
    never resolve to "not a draft", which is the defect itself with an API
    outage standing in for the Reviewer. One definition, in `lib/handoff.sh`,
    shared with requirement 32b (requirement 34a).

    The defect this exists to prevent shipped. A Reviewer returned
    `{"status": "ready", "ci": "passing"}` for a complete, green pull request,
    never ran `gh pr ready`, and the Script logged a successful handoff from the
    report alone. The PR stayed a draft: invisible to the human, who watches for
    review requests, and invisible to the log, which agreed with the Reviewer.
    Three hours later the abandoned-drafts source (requirement 3e) correctly
    re-detected a stalled draft, at a fresh head SHA and so under a fresh ref no
    block covers, and paid an Implementer and a Reviewer to finish finished
    work — which it would have gone on doing hourly, each round looking
    productive. No component could have noticed: the Reviewer believed it had
    handed off, the Script believed the Reviewer, and only GitHub disagreed.
31b. **The second half of the handoff: the re-request.** Requirement 31a's flip
    is the whole handoff exactly once per pull request. Every round after the
    first begins with a PR that is already ready — a review round the Implementer
    has just answered, above all — so `gh pr ready` is truthfully a no-op, and
    nothing is left that puts the pull request in front of the human. Their
    review request was consumed the moment they submitted the review that asked
    for the changes; the author cannot clear `CHANGES_REQUESTED` (requirement
    26b); and so the PR sits with changes requested, no review requested of
    anyone, and a completed handoff in the log.

    So on the `ready` path, after the draft flip, the Script asks GitHub the
    second question too: **does a human's review block this pull request, and
    has a fresh review been requested of them?** The blocking set is computed
    the way GitHub computes `reviewDecision` — the last APPROVED or
    CHANGES_REQUESTED review *per reviewer*, bots excluded — so a human who
    requested changes and later added a `COMMENTED` review is still blocking,
    and one who later approved is not. A blocking review from a GitHub App is
    therefore never in this set — GitHub's `requested_reviewers` holds users
    and teams, not App identities, so there is no request `confirm_review_
    requested` could make of one — and a pull request whose only
    `CHANGES_REQUESTED` review is an App's yields `none` here, never `failed`;
    `ensure_human_reviewer` reaches the human instead. Then:
    - nobody blocking — nothing to do. The answer on every first-round pull
      request, at the cost of one API read, and the reason the check is
      unconditional rather than gated on `source == "review-feedback"`: the
      question is answerable from the pull request itself, and gating it on the
      Co-Ordinator's classification would make a mislabelled source an
      unnotified human;
    - blocking, and a re-review already pending from each — `already`. Whoever
      got there first (normally the Implementer, requirement 26b) did it;
    - blocking, none pending — `POST …/pulls/<n>/requested_reviewers` for the
      ones not yet asked, then **re-read the pending list**: as with
      `gh pr ready`, the call's exit status is not the answer. `pr-ready` then
      carries `review_requested` and the `reviewers` named;
    - it did not take, or GitHub could not be asked — a `warning` naming the PR
      and the reviewers, and `review_requested: "failed"` on the `pr-ready`
      event. **Not** an `attempt-failed`: the pull request is finished, green and
      visible, and only a notification is missing — the Implementer's own reply
      comment mentions the reviewer, which notifies them too. Recording a
      handback here would put a certified PR in front of the Enabler as a
      problem, which is what requirement 31a exists to avoid.

    **This does not clear the block, and must not appear to.** Re-requesting
    review leaves `reviewDecision` at `CHANGES_REQUESTED` and `mergeable_state`
    at `blocked` — verified against GitHub on poetic-fiddle #200, before and
    after — so "The Landing Gate" holds unchanged: the PR still needs an approving
    review from a code owner that this system cannot give itself. All the
    re-request does is return the PR to the queue the human actually reads.

    The defect this exists to prevent shipped, and is why requirement 31a's
    lesson needed a second telling. poetic-fiddle #200 was reviewed at 10:18
    with one requested change, answered and pushed at 21:33, and replied to at
    21:44 with a comment saying so. Every actor did its job; the Implementer
    prompt has carried "then re-request review from the reviewer" since the
    review-feedback source existed, as best-effort prose that nothing verified.
    It was skipped, the log recorded a clean `pr-ready`, and the human found the
    pull request only by going to look for it. The report is not the deed — so
    the model may still do it, the Script asks GitHub whether it happened, and
    where it did not the Script does it. One definition, in `lib/handoff.sh`
    (requirement 34a).
31c. **A `ready` verdict is confirmed against GitHub before it is acted on, not
    trusted from the Reviewer — and the same confirmation binds every path
    that can flip a draft to ready, not the Reviewer's own handoff alone
    (agent-ops#440).** poetic-fiddle #216 reached
    `reviewDecision: APPROVED` while a CodeQL high-severity alert ("clear-text
    logging of sensitive information") sat open, hidden inside an otherwise
    15/16-green check list — the Reviewer's own instruction to confirm CI is
    green (requirement 30) is a model reading a check list and judging it, and
    that judgement is exactly what missed this one. So before any pull
    request is taken out of draft, the Script asks GitHub directly, through
    `lib/handoff.sh`'s `handoff_complete_review` — the one gate-and-flip
    implementation both the Reviewer's own handoff below and the Enabler's
    `complete_handoff` recovery path (requirement 32b) call, so the gate binds
    on both by construction rather than by each path remembering to run it.
    (PR #433: an Enabler `complete_handoff` flipped a pull request to ready
    whose Implementer had failed and whose Reviewer had therefore never run
    at all — the gate below simply was not part of that path yet.)
    `handoff_complete_review` runs `lib/review-gate.sh`'s `review_gate_verdict`
    (component 20) first:
    - every required status check green at the pull request's *current* head
      commit (`gh pr checks --required`, asked fresh rather than reused from
      anything read earlier in the engagement, so a check still catching up to
      a fix just pushed is never mistaken for one that passed). A pull request
      reporting no required checks at all is treated as failing, never as a
      vacuous pass — poetic-fiddle #190, a CONFLICTING pull request, reports
      *no* required checks, which is the conflicting-PR-runs-no-CI trap this
      guards against — and so is a required check that is real and not green;
    - no code-scanning alert carrying a security severity that this pull
      request's branch carries and the default branch does not — a default
      branch that already lives with an accepted alert must not freeze every
      future pull request over debt that is not theirs, so the default
      branch's own open alerts are read and subtracted before anything is
      judged "introduced" by this pull request.

    `clean` — requirement 31 proceeds exactly as before. `dirty` — the
    handoff never runs at all; this is recorded as a Reviewer handback
    (requirement 32a) naming what the gate found, exactly as though the
    Reviewer itself had reported `blocked`, and no `gh pr ready` is attempted.

    `unknown` covers two distinct facts, told apart by `review_gate_verdict`'s
    exit status rather than by the word alone (TD-PPagop-26081305): `gh pr
    checks --required` failing to answer *at all* — a 502, a transient auth
    failure, a rate limit — is a fact about this node or GitHub's
    availability, not this pull request, but it is not evidence of "nothing
    wrong" either, so it still refuses the handoff (a non-zero exit) exactly
    like `dirty` does. That failure is told apart from the trap above by the
    diagnosis `gh` writes to stderr and not by the shape of its answer, because
    `gh` reports a pull request with no required checks as an error too — `no
    required checks reported on the '<branch>' branch`, returned before the
    `--json` payload is ever written — so both arrive with empty stdout and a
    non-zero exit, and a split on stdout alone would file every conflicting
    pull request as a degraded node. An unrecognised diagnosis is `unknown`:
    both words refuse the handoff, so a `gh` that rewords its message costs
    attribution and never safety. The Script records the node case as its own
    node-level `warning`
    — naming the node, not the pull request — carrying an `unblock_condition`
    that says to retry once a node can read GitHub again, not the generic
    "fix your required checks" wording a real failure earns, so an Enabler
    reading a queue of these does not mistake a degraded node for N unrelated
    broken pull requests.

    A `gh` degraded enough to fail this read is rarely wrong only once
    (TD-PPagop-26081404): the Script logs a `review-gate-checks-read`
    bookkeeping event — `{ok: true}` or `{ok: false}` — on every evaluation of
    this gate regardless of outcome, and passes this node's own slice of its
    log to `lib/review-gate.sh`'s `review_gate_unknown_streak_verdict`, which
    reuses `lib/crash-loop.sh`'s consecutive-run-resets-on-success shape
    (requirement 2.7) scoped to one node rather than the whole fleet — a peer's
    successful read must never reset this node's own streak, and a successful
    read of its own does. Success here is `review_gate_verdict` exiting
    anything but 2, its required-checks-read-failed signal (component 20),
    never the printed word: a genuinely dirty alert outranks an unreadable
    required-check list for the word and the handback, and reading the word
    would let exactly that combination — the degraded-`gh` runs this streak
    exists to catch are when the sub-checks disagree — falsely reset the
    count. Once this node's own run of consecutive
    required-checks-unreadable events reaches three, the per-item `warning`
    above is replaced by one `review-gate-checks-degraded` event naming the
    node, the gate and the streak's count — one event per streak, not one
    per item past the threshold: `review_gate_degraded_since` keys on the
    run's own `first_ts` exactly as `crash_loop_escalated_since` dedups
    requirement 2.7's issue, so further items degrading in an
    already-escalated run log neither the warning nor a repeat (their
    bookkeeping event and unchanged handback are their whole record), and a
    new streak, after any successful read, escalates afresh. The streak is
    read from this node's own cumulative log, so it spans cycles — this path
    ends its cycle after the one item, so consecutive items are necessarily
    consecutive cycles — and the escalation lands inline at the evaluation
    that crosses the threshold, not at cycle end. It is not filed as an
    issue, unlike requirement 2.7's crash loop, since this is a pattern
    worth a human's attention in the log, not (yet) worth paging one over —
    but it is echoed to stderr so it is visible in `cron.log` as well as the
    union log. The handback itself is unchanged either way: an unread
    required-check list still refuses the handoff exactly like a genuinely
    failing one. A code-
    scanning read that could not be asked at all
    (no `security_events` permission on this token, code scanning not
    enabled, an unreachable API) is the *other* `unknown`, unrelated to the
    node's ability to read required checks: it exits 0, so the handoff
    proceeds and a plain `warning` is logged instead — the same "could not
    check is not a failure" contract requirement 24a's Vercel preview check
    already keeps, applied here so a token missing one permission cannot
    silently freeze every pull request's handoff fleet-wide. A `dirty`
    verdict from either check always wins over an `unknown` from the other;
    required checks are asked first and gate on their own.

    One further check shares this gate: requirement 25a's script-side
    closing-keyword gate (`lib/closing-keyword-gate.sh`, component 17a) is
    asked here too, inside `handoff_complete_review`, after `review_gate_verdict`
    and before either path's draft flip, and a `dirty` verdict from it is
    recorded as the same requirement 32a handback on the Reviewer's own path
    (a `warning` naming the finding, on the Enabler's — requirement 32b); an
    `unknown` one warns and proceeds, exactly as the non-blocking alerts
    `unknown` above does — a required-check list unreadable enough to matter
    already refused the handoff at `review_gate_verdict`, so by the time this
    gate runs the node is known able to read GitHub. It is asked again here
    rather than trusted from the pass it made when the pull request was
    raised, for the same reason the
    checks above are read fresh: a body can be edited between the two — and
    because that earlier call only *tells* the Reviewer, so this is the only
    point at which the closing keyword is actually enforced.

    A third check shares this gate too: the reconciliation gate
    (`lib/reconciliation-gate.sh`, component 20a, agent-ops#533), asked here
    after the closing-keyword gate and before either path's draft flip. PR
    #512: a human requested three changes in a plain PR comment and flipped
    the pull request back to draft, stating that the comment-plus-draft-flip
    *is* the change-request signal — a formal `REQUEST_CHANGES` review is
    unavailable on this system's own pull requests to begin with, since every
    pipeline write and every human comment on them land under the same
    GitHub account (`lib/pipeline-marker.sh`'s own header). The next Reviewer
    round answered one of the three points and declared the pull request
    ready without ever mentioning the other two, one of which it directly
    contradicted. `review_gate_verdict` and the closing-keyword gate had
    nothing to say about this — CI was green, the closing keyword intact, no
    alert introduced — because the defect was never in the diff; it was in
    what the Reviewer's own completion comment failed to address. The gate
    reads every general PR comment posted since the pull request's most
    recent `ready_for_review` timeline event that was not itself later undone
    by a `convert_to_draft` event at or before the same bound (or its own
    creation time, when no such surviving event exists — never having left
    draft, on a first round, or every `ready_for_review` on record having
    eventually been undone) from a non-Bot account whose body carries no pipeline
    marker — a human's own words, on this system's shared-account terms —
    and refuses the flip, `dirty`, naming the permalink of any whose id is
    not cited by a `<!-- agent-ops:reconciles comment=<id> -->` line in some
    pipeline comment since — a permalink rather than a count, because that
    string is the whole of what reaches the handback and the next round's
    Reviewer, and a refusal that does not say which comment to answer is a
    loop rather than a gate. The anchor is bounded by the cycle's own start
    time, which `agent-cycle.sh` passes to `handoff_complete_review` at both
    call sites: the Reviewer runs `gh pr ready` itself at requirement 31, so
    an unbounded search would take that flip — made inside this very round —
    as "when the pull request last left draft" and filter out every comment
    the round existed to answer. A `dirty` verdict is recorded as the same requirement 32a
    handback on the Reviewer's own path (a `warning` naming the finding, on
    the Enabler's — requirement 32b), exactly like the closing-keyword gate's
    own; an `unknown` — the timeline, the creation-time fallback or the
    comment list failing to read at all — warns and proceeds, on the same
    non-blocking terms. The one new convention this adds is on the
    Reviewer's own side, not the human's: `prompts/reviewer.md`'s completion
    comment (step 8) cites one such line per human comment it has answered,
    whether by implementing the request (step 4) or by explicitly contesting
    it in the comment's own prose — "cite", because whether a diff actually
    answers a human's words is a judgement no script can make, only confirm
    was attempted.

    What "refuses the flip" means differs by path, and the difference is
    shared with the closing-keyword gate rather than particular to this one.
    On the Enabler's `complete_handoff` recovery path the pull request is
    still a draft, so the refusal is literal: `confirm_pr_ready` never runs
    and the pull request stays in draft. On the Reviewer's own path the
    Reviewer has already run `gh pr ready` itself during its session, so what
    the gate refuses is this pipeline's *completion* of the handoff — the
    requirement 32a handback is recorded, no `pr-ready` event is logged, and
    the re-request and reviewer nudge never run, leaving the item blocked for
    the Enabler rather than recorded as handed off.

    **A `dirty` verdict also converts the pull request back to draft on both
    paths (agent-ops#539).** This was not always so, and its absence was
    itself a defect the gate above did not survive its own second round
    against: the first refusal on PR #512's real timeline was correctly
    `dirty`, but with nothing converting the pull request back to draft, the
    Reviewer's own step-7 flip from that round survived untouched — GitHub
    does not delete a `ready_for_review` event, a later `convert_to_draft`
    merely follows it on the timeline — and that surviving flip became the
    very next round's anchor. The standing comment the gate had just refused
    to let through fell before it and read as reconciled, permanently: on the
    one path that matters, the Reviewer's own, this gate could refuse a pull
    request exactly once per unreconciled comment, never twice.
    `handoff_complete_review` now calls `confirm_pr_draft` on every `dirty`
    reconciliation verdict — the same "confirm against GitHub, don't trust
    the call's own exit status" shape `confirm_pr_ready` already applies in
    the forward direction — printing `reverted` (`gh pr ready … --undo` ran
    and GitHub now agrees it is a draft), `already-draft` (nothing to undo:
    the Enabler's `complete_handoff` path, whose block never flipped this
    pull request ready to begin with), or `failed` (still ready after the
    attempt, or unreadable). This word is carried in `handoff_complete_review`'s
    own `revert` field so each call site can act on it, and a `failed` revert
    earns its own `warning` distinct from the ordinary `dirty` handback — the
    pull request is not merely carrying an unanswered comment at that point,
    it is *still ready*, so a human could merge it without ever seeing that
    the comment stands. The anchor's own undone-event exclusion above is what
    makes this revert worth performing at all: without it, the
    `convert_to_draft` event this call produces has no effect on the next
    round's read, and the defect reproduces one round later regardless of
    how faithfully the pull request is put back in draft.

    #216 itself: the human resolved it directly on the pull request (renaming
    the flagged constant, commit `8e62ff6`) before this requirement existed to
    check it, which is itself the confirmation that a script-side gate would
    have found nothing further to do once that fix landed.
31d. **A pull request that already merged is not handed off, not reviewed by
    the Approver, and not landed against — the Script's own read decides,
    never the Reviewer verdict's word (agent-ops#916, escalation #922).**
    `lib/handoff.sh`'s `pr_merge_state` is the one helper both reads share:
    fail-closed at the handoff — ahead of `confirm_pr_ready`'s own isDraft
    read, ahead of the Reviewer stage's own failure exit, and before
    `$rev_status` is even parsed, so a Reviewer that never noticed the merge
    (`"status": "ready"`), one that did (`"status": "blocked"`, naming it),
    and one that produced no parseable verdict at all — a crash, a timeout,
    an API refusal, an unparseable final message (agent-ops#1063) — are all
    caught the same way — and advisory
    at the Reviewer's own stage-start, so a whole engagement is never spent
    on a pull request already gone (an unreadable answer there simply runs
    the stage, since the fail-closed read afterward still guards whatever it
    produces). A confirmed merge is requirement 32c's completion, not
    requirement 32a's `attempt-failed`; a merge GitHub does not confirm — a
    Reviewer claiming one the Script's own read denies — is a model error
    and falls through requirement 32a unchanged, since nothing distinguishes
    it from any other unparseable or false claim.

    Live instance: cycle `20260828T013721Z-ockham-2-16721`, PR #883 — merged
    at 02:38:28Z, 21 minutes into a Reviewer engagement that ran another 24
    minutes never asking. The Reviewer opened a replacement pull request
    (#891), reported only in prose; nothing machine-readable ever named it,
    and it sat with zero reviews for 9.4 hours until a human found it by
    hand. Requirement 32c is what that pull request's leftovers become
    instead — `file_debt`/`file_issue` on the Reviewer's own verdict, filed
    by the Script — and `prompts/reviewer.md`'s own "When this pull request
    merges while you are still reviewing it" is the instruction that
    replaces the improvisation: no replacement pull request, ever.

31e. **A `merge-conflicts` item's rebase-only push carries the standing
    Reviewer verdict forward instead of paying for the engagement again
    (agent-ops#1806).** Resolving a conflict costs three stage runs in the
    ordinary path — Implementer, Reviewer, Approver — because the push moves
    the head, and a moved head is what the Reviewer stage keys on
    unconditionally. Most of those pushes change nothing about the pull
    request's own diff: a clean rebase, or a conflict resolved by keeping
    both sides of a hunk, reproduces the same net content on the moved base.
    Requirement 46a's restale sweep already answers this question for its
    own, independent recovery path; this requirement is the same answer
    applied where the cost is actually paid — inside the cycle that just ran
    the Implementer.

    Captured just ahead of the Implementer stage (step 6b), while
    `$selected_branch` still names the pull request's pre-push head: for a
    `merge-conflicts` work order that does not carry `"takeover": true` (a
    takeover names Dependabot's own pull request, ordinary fresh work
    requirement 3s already excludes from this treatment), the branch's and
    the work order's own `base`'s current tip SHAs, read with `git
    ls-remote` — no clone of their own, since the cycle's own clone has not
    yet been pointed at the pull request's branch at this point. `base` is
    the gathered entry's own `baseRefName` (`scripts/gather-merge-conflicts.sh`),
    carried onto the work order by both producers exactly as a `dequeued`
    entry's `base` already is — `mk`'s `mc_cands` composition
    (`lib/stage-attempt.sh`) for the deterministic fallback, and the
    Co-Ordinator's own "For a `merge-conflicts` entry" instruction
    (`prompts/coordinator.md`) for a model-selected one — so the capture's
    guard above (an absent `base` skipping the capture) is never live in
    practice; a takeover carries the field too, and is turned away by the
    takeover test above before its `base` is ever read.

    Compared at the Reviewer stage's own start, immediately after the
    existing merge-state advisory read (requirement 31d) and before the
    reviewer tier is computed: `rebase_only_push` (`lib/rebase-only.sh`)
    diffs the pre-push head against the pre-push base and the post-push head
    against the base's current tip, and reports whether the two diffs are
    `git patch-id --stable`-identical — never authored dates, which a
    conflict-resolution commit moves just like any other. Both heads are
    fetched by name from the forge, from the repository's own
    `https://github.com/<slug>.git`, symmetrically: the question is
    whether the *push* changed the diff, and the clone's own working tree
    would instead answer whether the Implementer's edits did — true even of
    an Implementer that reported `complete` having pushed nothing. Both
    comparisons run in a bare repository the Script makes for them, never in
    the Implementer's clone, which by then is the stage's (requirement 45e):
    before the Implementer stage, `rebase_only_forge_capture` fetches the
    pre-push pair into it, commits only (`--filter=tree:0`), and computes the
    pre-push patch-id there and then, while the forge still serves that head
    as a branch tip; at the Reviewer's start, `rebase_only_forge_check`
    fetches the post-push pair into the same repository, compares, and
    removes it. Nothing asks the forge for the pre-push head after the
    Implementer's force-push has made it unreachable. A head
    that did not move at all is therefore not a rebase-only push but no push,
    and takes the full path. Advisory exactly like requirement 31d's own
    read: an unreadable ref at either point (the fetch of the pre-push SHAs
    failed, either head could not be resolved) runs the Reviewer engagement
    as normal, never guessed at as rebase-only.

    A confirmed rebase-only push skips the Reviewer **engagement** —
    `stage_budget_apply` and the `run_claude_stage` call alone — and logs
    `reviewer-carried-forward` (`repo`, `item`, `pr_url`, `old_head`,
    `new_head`, `rebase_only: true`) for D23's cost accounting to read, in
    place of the `stage-end` event no stage run produced. The cycle then
    continues through the `ready` path below under a synthesised Reviewer
    verdict (`status: "ready"`, `fixes_applied: []`, `comments_left: 0`, `ci`
    naming this requirement) exactly as a real `ready` would: requirement
    31c's handoff gate, the Approver engagement (requirement 8b) and the
    arming step (requirement 8d) all run unchanged.

    The asymmetry is deliberate, and is the whole of what may be carried
    forward. The Reviewer's verdict is this pipeline's own state, so a push
    that changed no net content leaves it as true as it was. The Approver's
    verdict is a GitHub artefact, and every repository this pipeline may act
    on is required to set `dismiss_stale_reviews_on_push: true` (D18 Stage 3
    below, `docs/PULLWRIGHT-DAY-ONE-AUTONOMY.md` §1a) — a rule that keys on
    the head SHA moving and knows nothing of patch-id identity, so a
    `merge-conflicts` push, necessarily a force-push, dismisses the standing
    approval whether or not the diff changed. `run_approver_stage` is the
    only thing that mints a replacement, and the requirement 8u landing-retry
    sweep cannot recover one it never finds: `_landing_retry_sweep_repo`
    requires a currently standing approval and excludes `complexity:high`
    outright. Ending the cycle at this point would therefore leave the pull
    request un-approved and un-armed until requirement 46's unreviewed
    trigger reached it hours later — a larger cost than the engagement it
    saved, not a smaller one.

    Falling through also satisfies agent-ops#1806's own "provided the
    required checks pass on the new head" proviso without a check of its
    own: `handoff_complete_review` calls `review_gate_verdict`, which reads
    the required checks fresh at the current head, so a diff that is
    patch-id-identical against a base that *moved* — a semantic conflict, the
    default branch renaming something the unchanged diff still calls — is
    caught there rather than carried forward.

    Anything else — a resolution that changed the diff, a follow-up fix — runs
    the engagement below unchanged.

31f. **The Implementer's own stage-start pays the same advisory merge check
    requirement 31d already gives the Reviewer, for the same five finishing
    sources whose work order hands it a subject pull request before it ever
    runs (agent-ops#1062).** `review-feedback`, `merge-conflicts` (less a
    `takeover`, whose `pr_url` names Dependabot's own pull request, not a
    subject this stage can retire), `dequeued`, `landing-refusals` and
    `abandoned-drafts` — `preflight_existing_branch_source`'s own set — each
    claim a `pr_url` the Co-Ordinator never minted and the Implementer did not
    just raise, so it can be stale the same way the Reviewer's own subject
    can: merged in the gap between the cycle's gather and this stage's
    launch. Requirement 5c's own pre-flight already asks a related question
    earlier in the same cycle (`preflight_branch_merged_reason`, gated to the
    same five sources), but against an ancestry compare and a `source_states_
    json` digest both sampled before the Co-Ordinator engagement — exactly
    the window a merge can land inside. This requirement is the live
    counterpart, immediately ahead of the stage it would otherwise waste: one
    `pr_merge_state` (requirement 31d) read against the work order's own
    `pr_url`, run just ahead of step 7's own engagement (after step 6b's
    rebase-only pre-capture, before `stage_budget_apply implementer` is ever
    called).

    `merged` reaches requirement 32c's completion exactly as the Reviewer's
    own stage-start catch does — `reviewer_merge_observed` is the one
    implementation all three call sites share, logging `stage:
    "implementer-stage-start"` — and additionally releases the item-keyed
    claim (`release_claim no-pr`), which the Reviewer's own two call sites
    never have to: by the time either of those runs, the Implementer has
    already raised `pr-raised` and dropped the item-keyed claim in its own
    favour (step 7's "have-pr-pending"), but this read runs before the
    Implementer stage exists to do that, so the item-keyed claim this cycle's
    own claim loop won is still live and must be released here instead. Every
    other result (`open`, or an unreadable `failed`) is advisory only and
    simply runs the Implementer stage as normal — nothing about a merge
    caught here is irreversible the way a draft flip, an Approver review or a
    landing attempt is, and the Reviewer's own handoff-time read (requirement
    31d) still guards whatever this stage goes on to produce regardless.

55. **`review_gate_required_checks` also compares the base branch's own
    ruleset against what actually ran, so a required context with no run at
    all is caught, not read as a vacuous pass (issue #1543).** `gh pr checks
    --required` lists check *runs*; a branch that deletes the workflow, or
    removes or renames the job, producing one of the base branch's required
    contexts leaves that context with no run at all on the head commit —
    which is not a failing entry, it is simply absent, so requirement 31c's
    own `all(.bucket == "pass")` test is vacuously true for it. The live
    instance: PR #1503 (issue #882) deleted
    `.github/workflows/tech-debt-register.yml`, whose `register` job ruleset
    18857310 required; every check that did run was green, `mergeStateStatus`
    sat `BLOCKED`, and nothing surfaced the cause until an unrelated item
    (#1529) happened to block on this one 6+ hours later and #1540 escalated
    it only then.

    `review_gate_required_checks` (`lib/review-gate.sh`) takes an optional
    second argument, the base branch, and — only once the check-runs list it
    already read comes back all-`pass` — asks
    `repos/<slug>/rules/branches/<base>` for the branch's own active rules,
    collects every `required_status_checks` rule's `context`s, and compares
    that list against the `name`s the check-runs list actually carried. Any
    context present in the ruleset and absent from the runs is `dirty`,
    naming the missing context, distinct from both requirement 31c's existing
    `dirty` reasons (a real failing check, or the empty-list trap) and its
    `unknown`. A base branch whose ruleset itself cannot be read — `gh api`
    failing outright, no `required_status_checks` rule on it at all — skips
    the backstop exactly as if it had found nothing, the same non-blocking
    convention `review_gate_security_alerts` already applies to an alerts API
    it cannot reach: a ruleset this call could not ask is a fact about this
    node or GitHub's availability, not proof the branch is missing a check,
    and costs nothing beyond the one comparison this call already makes.
    Omitting the base branch — every caller that predates this — skips the
    backstop identically, so `review_gate_required_checks("$url")` alone is
    unchanged. `review_gate_verdict` (and therefore `handoff_complete_review`
    and `landing_arm`, its two live callers) already passes its own
    `default_branch` argument through to `review_gate_required_checks`, so
    both of requirement 31c's own gates — the Reviewer's `ready` handoff and
    the landing gate — get the backstop with no call-site change of their
    own.

    This is the backstop half of a two-seam fix; requirement 56 is the
    earlier, deterministic half, run once at pull-request time rather than
    waiting for this backstop to catch it at handoff.
61. **A required context reported more than once against the same head
    commit, with at least one of those runs already green, is repaired
    rather than read as a real failure (agent-ops#1978).** A duplicate
    `pull_request` webhook delivery for one push starts every triggered
    workflow twice against the same head commit. A workflow with no
    concurrency group simply runs, and passes, twice — harmless, and
    invisible to requirement 31c's `all(.bucket == "pass")` test either way.
    One that cancels a superseded run of itself (`cancel-in-progress`, as
    "Build the node image" does) leaves that run's check runs `CANCELLED`
    beside the surviving run's own `SUCCESS` ones for the same context
    names — `gh pr checks --required` reports both entries under the one
    `name`, so requirement 31c's own all-`pass` test fails even though the
    head commit is already proven fine. The live instance: `agent/1950`'s
    push of `18a0e699b3` started every `pull_request` workflow on this
    repository twice at 2026-09-29T17:04:1x, and "Build the node image"'s
    concurrency group cancelled `Work out what changed` and `Work out the
    version stamp` on the older of the two runs — both required contexts —
    while every other workflow's duplicate ran harmlessly to completion.
    GitHub's own rollup counted the cancellation; the pull request sat
    `mergeStateStatus: BLOCKED` from 17:04 until a human pushed a new commit
    at 08:30 the next day, despite a standing Approver approval reached at
    17:44 on the strength of `review_gate_verdict` reading the same checks as
    clean.

    Before `review_gate_required_checks` (`lib/review-gate.sh`) settles on
    `dirty` for a non-empty check-runs list that is not all `pass`, it calls
    `_review_gate_repair_duplicate_runs`: for every entry whose `bucket` is
    not `pass` but whose own `name` also carries a `pass` entry elsewhere in
    the same read — a required context superseded by a passing sibling run —
    it reruns the superseded run (`gh run rerun`, its id pulled from the
    entry's own `link`, an Actions job URL) and re-reads the required checks,
    up to `REVIEW_GATE_RERUN_ATTEMPTS` times (default 10)
    `REVIEW_GATE_RERUN_INTERVAL` seconds apart (default 15), stopping the
    moment a re-read comes back all-`pass`. `gh run rerun` replays the
    original event without a new push, so a standing Approver approval is
    never dismissed by the repair the way a corrective commit would dismiss
    it. A context whose only non-`pass` entries have no passing sibling —
    a genuine failure — is untouched by this and still reaches `dirty` from
    requirement 31c exactly as before.

    Not every superseded run clears on a rerun: a check that reads the pull
    request's description (or any other mutable field) from the triggering
    *event* rather than through the API replays that same stale value and
    fails again — the shape a description edit produces on `#1981`, whose
    `changelog-section` run failed against the old text and passed against
    the new one at the same head commit, both counted by the rollup even
    though `changelog-section` is not itself required. Where a repair
    attempt exhausts every re-read still short of all-`pass`, the context
    reaches `dirty` exactly as a genuine failure would — the ordinary repair
    path (a human, or a future push) still owns it; this requirement's own
    rerun is a best-effort clearing of a duplicate, not a guarantee.

    No code change removes the duplicate delivery itself: this repository's
    own trigger configuration (`.github/workflows/*.yml`) declares no
    duplicate `pull_request` trigger, and every push this pipeline makes is a
    single `git push`, so the doubled delivery in the live instance above
    originated on GitHub's side, outside this repository's control — the
    repair exists because a future duplicate delivery cannot be ruled out
    either way, exactly as `review_gate_verdict`'s existing `unknown` already
    treats a `gh` failure as a fact about the platform rather than the pull
    request.
63. **A repository that configures no CI at all is `clean`, not requirement
    31c's conflicting-PR-runs-no-CI trap (agent-ops#2194).** `gh pr checks
    --required` reports both "checks were expected on this pull request and
    are absent" (poetic-fiddle #190's trap) and "this repository runs no CI at
    all, so nothing was ever going to be reported" in the identical shape —
    empty stdout, non-zero exit. Poetic-Poems/poetic-fiddle#465 hit the
    second case directly: its pull request was against `Pullwright/.agent`, a
    repository with no `.github/workflows` and `actions/workflows` reporting
    `total_count: 0`, and the trap refused it anyway, with an
    `unblock_condition` naming a security-severity code-scanning alert that
    was never identified — code scanning is not even enabled on that
    repository.

    `_review_gate_no_ci_configured` (`lib/review-gate.sh`) is asked before
    either no-required-checks shape in `review_gate_required_checks` settles
    on `dirty`. Branch protection and rulesets are not readable on a private
    repository on the free plan (`403 Resource not accessible by
    integration`), so "which checks are required here" cannot be asked
    directly; two signals stand in for it instead — `GET
    /repos/{slug}/actions/workflows` reporting `total_count == 0` *and* the
    pull request's head commit carrying no commit statuses at all (`GET
    /repos/{slug}/commits/{sha}/status`, `total_count == 0`). Only once both
    read zero does the verdict become `clean`, with a line on stderr naming
    why; a repository with workflows configured that simply reported nothing
    for this head commit, or one with no workflows but a legacy commit-status
    integration still posting to it, stays on the `dirty` trap exactly as
    before — the regression poetic-fiddle #190 itself guards against.

    The `unblock_condition` a `dirty` verdict's requirement 32a handback
    carries (`lib/coordinator-phase.sh`) is chosen from which of requirement
    31c's two sub-checks actually produced the reason: it names the
    security-severity code-scanning alert only when the gate's own reason
    names one, never as a blanket addition to a required-checks failure that
    never implicated one.
32. Ends with a single JSON object:
    `{"status": "ready" | "blocked", "pr_url": …, "fixes_applied": […], "comments_left": n, "ci": "passing" | …}`,
    plus `reason` — one line naming what is wrong — on `blocked`, which becomes
    the block's own `detail` under requirement 32a. `blocked` is the only
    spelling that means anything; requirement 32a's `!= ready` fall-through
    already routes every other ending — an unparseable status included — down
    the same `attempt-failed` path, so no synonym was ever needed to provide
    tolerance for one.

    `ci: "passing"` means every one of requirement 31's required checks is
    green — nothing about a non-required check. Where a non-required check is
    red, `ci` enumerates it by name instead of a bare `passing`, e.g.
    `"ci": "required passing; non-required failing: docs"` — this is
    orthogonal to `status`, which stays `ready` on this shape exactly as it
    would with every check green, since only a required check failing bears
    on `status` at all (requirement 31).

    Additive to a `ready` verdict, absent or empty on the overwhelming
    majority of rounds: `"open_questions": [{"question": …,
    "why_this_actor_cannot_settle_it": …, "comment_url": …}]` (D18,
    agent-ops#668) — a narrow, structured companion for the one case
    `comments_left`'s plain findings comments do not fit: nothing in the diff
    is wrong, so there is nothing to fix or flag as a defect, but a question
    about the work order or its scope needs a decision the Reviewer is not
    the right actor to make. It is deliberately not a third status alongside
    `ready`/`blocked`: the pull request still hands off exactly as it always
    has, and an unresolved entry holds only *unattended landing*, through the
    gate requirement 8f adds — never the handoff itself, and never anything
    a defect or an impediment already has a channel for.

    Additive on the one ending requirement 31d describes, absent everywhere
    else: `"file_debt"`/`"file_issue"` (`{title, body, default_fix,
    owner_decision}` each — the Approver's own field shape, requirement 42a),
    carrying what a pass had already found when its subject merged out from
    under it. There is no live pull request left to hold a `Defers:` line or a
    replacement pull request of the Reviewer's own (requirement 31d forbids
    one), so the verdict field *is* the record: requirement 32c's completion
    path files whatever it names, and nothing else the Reviewer writes that
    round survives.
32a. **A Reviewer that cannot hand off hands back, not out.** Any ending other
    than a pull request the human can see — `blocked`, an unparseable status, or
    a `ready` whose handoff requirement 31a could not make true — is recorded as
    an `attempt-failed` against the item, carrying the `pr_url`. That is a
    blocked item by requirement 34 and Enabler-eligible by requirement 35a, so
    the Enabler re-examines it with the whole history in front of it and either
    clears it (requirement 32b) or escalates it to a human by issue
    (requirement 36).

    The promise this keeps: **a pull request that is not ready for review is the
    pipeline's problem until an Enabler says otherwise.** A human is never
    expected to discover work by noticing a draft. Recording the verdict as a
    bare `stage-end` — which is what it was — named no item, so it pinned no
    state, appeared in no blocked list, reached no Enabler, and left the PR to be
    swept up hours later by abandoned-drafts as though the Reviewer had never
    run.

    The Script leaves no comment of its own on the PR here. The Reviewer has
    already stated its concerns there in its own words (requirement 30) and that
    is the record the Enabler reads; a second comment would add nothing —
    marking it (requirement 3e) would keep it from resetting the staleness
    clock, but there is still nothing for it to say that the thread does not
    already contain. Where the Script does comment on a stage failure it says
    the item is recorded blocked and that the Enabler will re-examine it —
    never that the PR has been left for a human, which under this requirement
    is not true.
32b. **`complete_handoff`.** An Enabler `unblocked` verdict may carry
    `complete_handoff: true` on an item whose `pr_url` is set (requirement 35a),
    meaning: this block *is* an unfinished handoff — an open draft this system
    raised, checks green, work done, no unanswered concern — take it out of
    draft. The Enabler establishes it; the **Script** performs it, through
    `handoff_complete_review` (requirement 31c) — the same gate-and-flip
    implementation the Reviewer's own handoff calls, run here in full rather
    than skipped — and on a clean verdict logs `pr-ready` with
    `handoff: "enabler"`. The division is requirement 36's: the Script is the
    only writer of the pipeline's outward acts, which is why it and not the
    Enabler also files the escalation issue. A `complete_handoff` on an item with
    no `pr_url` is ignored — there is nothing to hand off.

    **The Script refuses `complete_handoff` outright — logging a `warning`
    naming the reason, never the flip — when the item's most recently recorded
    failure is at or before the Implementer stage** (agent-ops#440, PR #433):
    the block a `complete_handoff` recovers must itself be a Reviewer's, or
    nothing has ever confirmed the pull request is safe to hand off, and every
    one of the four preconditions above can read as satisfied only because
    none of them was ever actually asked. This is checked before
    `handoff_complete_review` runs at all — a Reviewer verdict is a
    precondition for asking the gate, not a substitute for it — and reads the
    block's own `stage` field (the same one `handle_stage_failure`/
    `log_reviewer_handback` stamp on every `attempt-failed`, requirement 35a):
    `"reviewer"` and the recovery proceeds; anything else (`"implementer"`,
    `"coordinator"`, `""`, …) and it is refused. On PR #433 the Implementer
    had failed, the Reviewer block never ran, and a `complete_handoff` still
    flipped the pull request to ready — the gate did not exist on this path at
    all yet, so nothing caught it. A refused `complete_handoff` does not undo
    the item's own `unblocked` verdict, which still stands: the underlying
    impediment the Enabler diagnosed is still cleared, and the stalled pull
    request is left for a Reviewer to actually examine — which is what the
    `abandoned-drafts` source (requirement 3e) does once the draft goes
    stale, handing it to a fresh Implementer-then-Reviewer pass.

    **That recovery is structural, not configurational.** The item never
    finds its own way back: the draft's branch *is* the claim the item was
    taken under, so every later claim on it 422s and the Co-Ordinator's
    exclusion reads "claimed, skip" — requirement 17b's mechanism, in
    precisely the state that requirement's sweep exists to convert *into*
    this one — and the other three finishing sources exclude drafts by
    construction (requirements 3c, 3g, 3z), because a draft is the
    Implementer's own claim marker rather than work awaiting a human. That
    is why `abandoned-drafts` is a required member of every repository's
    `sources` (requirement 3e; agent-ops#472's decision): a repository able
    to omit it would leave this draft for a human, along with every other
    stalled draft it ever raises, whatever stalled it. The refusal can
    therefore count on requirement 3e re-detecting the draft — and it stays
    a refusal either way, since the alternative is flipping to ready a pull
    request nothing has reviewed.

    Once a Reviewer verdict is on record, `handoff_complete_review`'s own gate
    still applies exactly as requirement 31c describes it: `dirty` (either
    sub-check, or the closing-keyword gate) or an unreadable required-check
    list refuses the flip with a `warning` naming what the gate found — never
    a Reviewer handback, since there is no Reviewer engagement to hand back
    to — and `complete_handoff` is recorded on the resulting
    `enabler-examined` event as `"failed"` rather than a flip word, so a
    reader can tell "the gate refused it" apart from "there was nothing to
    hand off" and from an actual flip. An unreadable required-check list also
    runs requirement 31c's own node-health streak (TD-PPagop-26081404) here,
    through the same `review_gate_escalate_unreadable_streak` helper the
    Reviewer's own handoff calls (TD-PPagop-26081603): a run of consecutive
    unreadable-checks failures escalates to one `review-gate-checks-degraded`
    event whether it lands on this path or that one, rather than only the
    latter.

    Requirement 31b runs on this path too, and it is not decoration here: an
    `already` is exactly what a stalled review round answers, because that PR was
    never a draft. Completing only the flip would clear the block, log a handoff,
    and leave the human as unasked as before. Both handoff paths run both halves,
    or the one that recovers a failure is the one that recovers it incompletely.
32c. **A subject that merges mid-stage is a completion, not a hand-back
    (agent-ops#916, escalation #922).** Requirement 31d's `pr_merge_state`
    read confirming `merged` — at the Reviewer's own stage-start or at the
    handoff, ahead of the stage-failure exit and `$rev_status`'s own branch
    alike — ends the cycle here
    instead: `merge-observed` is logged (repo, item, `pr_url`, the merge
    commit when GitHub reports one, and which of the two reads caught it),
    whatever the Reviewer's own verdict asked to be filed under `file_debt`/
    `file_issue` is filed under the ordinary pipeline login — the Reviewer
    carries no App identity of its own, the same reason the Enabler's own
    use of the two fields (requirement 36c) always omits a token too — and
    the PR-keyed claim is released. No `pr-ready`, no Approver engagement
    (requirement 8b), no landing attempt: the item retires the way
    `lib/work-gone.sh` retires one whose issue closed underneath it
    (requirement 34i), never as requirement 32a's `attempt-failed`, because
    the work this pipeline was asked to hand off is not missing — it is
    already on `default_branch`, merged by whoever merged it, and there is
    nothing left for an Enabler to re-examine.

    `lib/merge-observed.sh`'s `reviewer_merge_observed` is the one
    implementation all three call sites run: both stage-start calls pass it
    an empty verdict (`{}` — no stage ran yet, so there is nothing to have
    asked for filed); the handoff call passes the Reviewer's own parsed
    JSON, `file_debt`/`file_issue` included wherever its own
    `"status": "blocked"` ending set them (`prompts/reviewer.md`'s "When this
    pull request merges while you are still reviewing it"), or that same
    empty verdict where the stage produced no parseable JSON to carry them.
    Requirement 31f's own call — the Implementer's own stage-start, ahead of
    a finishing source's pre-existing subject — is the third: it reaches
    this same completion for an item the Implementer stage never even
    launched for, additionally releasing the item-keyed claim its own header
    explains (`release_claim no-pr`, since `reviewer_merge_observed` itself
    only ever held the PR-keyed one).

    A merged subject retires the *item*; it says nothing about the *node*. So
    on that no-parseable-verdict path the handoff call site still takes the
    usage-limit read the stage-failure exit it now precedes would have taken
    (`detect_and_log_limit_hit`, requirement 32a's own
    `handle_stage_failure`), and takes it nowhere else: a Reviewer stopped the
    moment the account refused is the fact requirement 35's Enabler guard and
    the fleet's own stand-down (requirement 2.1b) both key on, so a usage
    limit that happened to coincide with a merge would otherwise go
    unrecorded — and the Enabler, the fleet's most expensive model, would
    engage moments after it and simply re-hit it.

