## Requirements

### The Enabler

35. **Engagement.** At the end of a cycle — from the cleanup of requirement 11,
    after the workspace is deleted and before the `cycle-end` event, with the
    lock still held — the Script engages the Enabler over the eligible items of
    requirement 35a: a headless invocation (model `enabler_model`,
    `--dangerously-skip-permissions`, timeout `timeout_enabler`) logging
    `stage-start`/`stage-end` with `stage: "enabler"` like any other stage, and
    parsed from its final message like any other stage.

    **One call site.** Nine paths end a cycle; the cleanup is the one place all
    of them pass through, and calls at each exit point would be nine chances to
    forget one — including the exits that matter most here, where the cycle
    stood down without selecting anything. Inside the lock, so requirement 33's
    single-writer guarantee still holds while these events are written; before
    `cycle-end`, so they belong to the cycle that produced them and travel on
    the same end-of-cycle `state-sync push` (requirement 2.5).

    It engages only when **all** of the following hold, and any one of them
    failing is an ordinary, silent non-engagement:
    - this cycle acquired the lock;
    - the gatherers completed, so the eligible set was computed from inputs that
      exist. Every earlier exit — the role guard, either switch, the usage-limit
      cooldown, a lock held by a live cycle — therefore cannot engage it;
    - the cycle is not `--dry-run`. `--once` **does** engage: a supervised
      engagement is the only way to watch one, and it contends with the fleet on
      equal terms exactly as `--once` does for claims (requirement 17a);
    - the cycle's own exit code is 0. A cycle that ended badly is not the moment
      to spend the most expensive model in the system;
    - no usage limit was detected during this cycle (requirement 10), *and* a
      live read of `fleet/limit.json` (requirement 2.1) does not stand the fleet
      down right now — a limit a peer hit while this cycle was working is
      precisely the news that should stop this stage starting;
    - `enabler_model` is set and `prompts/enabler.md` exists;
    - at least one eligible item was claimed (requirement 35c).

    Every claimed item goes to **one** invocation. The reading is per item but
    the session overhead is not, and the set is small by construction.

    `enabler_assignee` is not one of these guards: unlike an empty
    `enabler_model`, an `enabler_model` set with no `enabler_assignee`
    configured is not a silent non-engagement. The Script validates it at
    config-read time, before the cycle does anything else, and exits with an
    error if the combination occurs — an unassigned escalation would not be
    excluded by requirement 16.4 and the pipeline could go on to select it as
    its own work, so the failure must be loud rather than a quiet skip.
35a. **Eligibility.** An item is eligible for the Enabler iff **all** of:
    1. it is **blocked** (requirement 34) — call that latest `attempt-failed`
       event *B*;
    2. it is **not void** (requirement 34c). An item with no work needs no
       unblocking, and an item recorded both ways must not be re-examined at
       this stage's prices;
    3. **no escalation issue for it is still open** — the `issue_number` of the
       latest `escalated` event for that repo+item is not among the repo's open
       issues in the source-state digest (requirement 3b), the item's own
       `repo` resolved through `config_repo_slug_aliases`' `{old_slug:
       current_slug}` map first (agent-ops#2064), since that digest is always
       keyed by the repo's *current* configured `slug`. A repo missing from
       that digest (whether absent outright, or named only by a slug outside
       the alias map too) could not be sampled, so whether its escalation is
       open is unknown, and unknown resolves to **ineligible**: a delayed
       engagement is cheap, a duplicate issue in the human's inbox is not;
    4. one of exactly three **reasons** applies, and that reason is recorded on
       the entry and passed to the model, because it decides where the model
       should look first:
       - **`threshold`** — no examination newer than *B*, and at least
         `enabler_after_coordinator_cycles` distinct cycles have logged a
         `stage-end` with `stage: "coordinator"` and `exit_code: 0` since *B* —
         or `refinement_after_coordinator_cycles`, for a block whose `kind` is
         `needs-refinement`. That event is the definition of "a cycle that ran
         a Co-Ordinator", and pinning it there is what makes the threshold mean
         "the pipeline has had several honest chances to clear this itself":
         every stand-down — switch, cooldown, no-op short-circuit,
         back-pressure — logs no coordinator `stage-end` and so ages nothing.
       - **`issue-closed`** — the item's latest escalation is no longer open,
         and no examination has followed it *since it was raised*. This
         bypasses the threshold deliberately: the human acted, and requirement
         36a promised them that closing the issue is what restarts the work.
         Ordinarily this means the escalation was raised after *B* — the block
         it answers is still the current one — but when *B* is instead a
         `needs-refinement` re-flag whose `refined_before` (the item's latest
         `item-refined`, requirement 36b) both exists and predates the
         escalation, the exemption still applies: the re-flag disputes the
         same, unchanged specification the escalation was about, so the
         human's close answers it too. A re-flag carrying no prior refinement
         at all is deliberately outside this: there is no specification the
         escalation can have been raised against, and the thrash guard does
         not bite without one, so the ordinary `threshold` path already
         delivers that item its first refinement. Without this, a re-flag
         landing between the raise and the
         next Enabler pass — observed in every case as a Co-Ordinator
         `needs-refinement` re-flag — strands the close: it satisfies neither
         this reason (keyed on the raise time) nor `threshold` (the thrash
         guard of requirement 36b refuses a second refinement without a human
         touch), and the only way out was a second escalation asking the human
         to say again what they had already said.

         "No examination has followed it" tests examination, not release:
         four other paths let an item leave its block without logging an
         `enabler-examined` — `lib/candidate-gather.sh`'s `unblocked {by:
         "label-removed"}` (a human takes the `blocked` label off),
         `{by: "work-gone"}`, `{by: "dependency-resolved"}`, and
         `lib/candidate-select.sh`'s bare `unblocked` event, which carries
         `item` only, no `repo` — the one unblock path that cannot be
         attributed to a repository at all, and the one `same_item`'s "an
         empty `repo` matches any repo" clause exists for. A close the human
         already acted on through one of those four still reads as "not
         consumed", so a later `needs-refinement` re-flag whose
         `refined_before` predates the escalation can still grant a fresh
         `issue-closed` engagement on a close already settled
         (TD-PPagop-26082918). This is bounded, not a gap: the engagement it
         grants logs the `enabler-examined` that retires the exemption for
         good and verifies the closed issue's claim against reality
         (`prompts/enabler.md`) before releasing anything — one Opus pass per
         closed escalation, not a loop. There is no evidence-only key that
         separates this from the #706 sequence this exemption exists to
         rescue (both release the item after the human's close and re-flag it
         afterward); the engagement this exemption grants is what retires it —
         its own `enabler-examined`, above — and a further re-escalation from
         there is what agent-ops#936's shipped per-reason bound (same reason
         since the last human touch escalates to a human, plus the
         `escalation_adjudication_max_passes` cap; PR #1049) catches. The one
         `issue-closed` grant per human close is itself uncapped by design
         (agent-ops#936 §5: "The issue-closed exemption stays") — this rule
         is unchanged by that bound, not awaiting it.
       - **`recheck`** — the newest examination of the item is older than
         `enabler_recheck_hours` (`0` disables). For a GitHub issue,
         requirement 18a already catches new evidence posted into its own
         thread same-cycle, off the issue's `updated_at` — the failure
         `TECH-DEBT.md` TD26072101 records. This bound is what closes the
         gap for everything 18a does not reach: every non-issue blocked
         source, and a blocker on an issue that clears without a comment ever
         landing (nothing then moves `updated_at`).
    A re-block re-enters through `threshold`, because every clause above is
    measured from *B*: a fresh `attempt-failed` moves *B* forward, leaving the
    old examination behind it and restarting the count — except the
    `needs-refinement` shape of `issue-closed` above, which is deliberately
    measured from the escalation instead, precisely so that re-block does not
    strand an already-closed escalation.

    An `enabler-examined` whose outcome is `escalation-failed` is **not** an
    examination for any of the above. That engagement reached a verdict it could
    not act on, so the item is exactly where it was, and counting the marker
    would retire the item on the strength of a failed `gh issue create`.

    A coordinator-stage refinement block (requirement 34e) is eligible on
    exactly these terms — the `kind` marker changes only which threshold the
    `threshold` reason compares against, never the set of reasons, the escalation
    check, or any other clause. Each entry additionally carries that `kind`, so
    the engagement knows which duty it is there to perform (requirement 36b),
    and `refined_before`: the latest `item-refined` event for the same
    repo+item whose `comment_url` — if it carries one — actually names a
    comment, or `null` if none does. That field is the thrash guard's input
    and the record of what the last engagement already specified, so a later
    one need not reconstruct it.

    **A phantom `item-refined` event is skipped, not trusted (TD-PPagop-
    26082819).** An event logged before the corroboration fix at requirement
    39c (The Refiner) — `comment_url` a bare issue URL, with no `#issuecomment-` anchor or
    REST API comment form, so it cannot name any comment at all — is excluded
    from the derivation above exactly as if it had never been logged, and the
    next-latest event that does pass the same shape check (`refinement_
    comment_url_valid`, `lib/refinement.sh`) is used instead; `null` if none
    does. This is what let #818's and #874's own phantom records self-heal
    without editing history: each wrongly armed the thrash guard the moment
    it was logged, and each cleared the instant this check shipped, with no
    change to the log itself. `enabler_eligible_items` logs one `warning`
    naming every phantom event's timestamp and repo+item it skipped this way,
    each time it is called with one in scope, so a still-live phantom is
    visible rather than only inferred from the item's own eligibility. The
    same shape judgement governs every reading seam: `refinements_map` and
    `decisions_map` skip a phantom event on identical terms (requirement 3h),
    so no extract in this codebase reads one as a refinement.

    Like requirements 34 and 34c, this rule has exactly **one** implementation
    (requirement 34a): `enabler_eligible_items` in `lib/cycle-state.sh`, whose
    clauses 1 and 2 above *are* requirement 34h's `open_blocked_items` rather
    than a second reduction of the same two extracts, always
    succeeds, and yields `[]` for a log it cannot read or a threshold it cannot
    parse — an unreadable setting is not a licence to spend.
35b. **The eligible set is part of the no-op fingerprint** (requirement 3b),
    projected to `repo|item|reason`, alongside the Enabler's config and a hash
    of `prompts/enabler.md` and any configured `prompt_overrides.enabler`
    files (requirement 4a). It is the third array whose candidacy turns on
    something no repo signal carries: an item becomes eligible once enough
    Co-Ordinator cycles have run since the block, which moves no commit,
    issue, alert or PR — so without it the escalation path would come due during
    a quiet week and wait for the forced recheck to be noticed. The `reason`
    rides in the projection because the transition that matters most keeps the
    same item in the set: a human closing the escalation issue turns the entry
    into a verification. A threshold crossing therefore wakes a quiet fleet, and
    that cycle runs the Co-Ordinator normally — which may clear the item far
    more cheaply — before the Enabler runs at all; the examined markers then
    empty the set and skipping resumes.

    One consequence is deliberate, not an oversight: because the eligible set
    turns on the *log*, editing `prompts/enabler.md` (or its configured
    overrides) busts the fingerprint but does not re-open items already
    examined. `enabler_recheck_hours` is the
    lever for "look at this one again"; a prompt edit is not.
35c. **One engagement per item, fleet-wide.** Before engaging, the Script takes
    a per-item file claim through `lib/claim.sh` under the pseudo-slug
    `enabler`, keyed `<repo>__<item>__<epoch of B>` (plus `__verify<issue>` for
    an `issue-closed` verification, which needs a key the earlier examination's
    claim does not already hold). The key is derived, never chosen by a model,
    so every node computes the same one and GitHub arbitrates; items whose claim
    is lost are simply left to the node that won.

    These claims are **never released**. The claim is a tombstone: it is what
    stops the same item being re-examined next cycle when the engagement
    produced no examined marker at all — a timeout, a garbage final message, an
    omitted item — and `lib/claim.sh gc` sweeping it at `claim_ttl_hours` is the
    only thing that permits a retry, which bounds a failed engagement's cost at
    one attempt per TTL. `lib/claim.sh expire` (requirement 37) shortens that
    floor for the one case the Script can actually tell apart from silence —
    an engagement it watched fail even after requirement 9e's salvage — without
    releasing the claim outright: it backdates the registry entry's `ts` so
    `gc` retires it on its very next sweep instead of waiting out the full TTL,
    which still bounds cost at "one attempt per sweep interval" rather than
    reopening the unbounded-retry failure this requirement exists to prevent.
    Two existing properties of `lib/claim.sh` make the
    pseudo-slug safe and are relied on here: `count` reads only the repo slugs
    `config.json` configures, so an Enabler claim can never inflate
    back-pressure (requirement 2.2) with work that raises no PR; and `gc` sweeps
    any directory it finds.
35d. **Refinement items are capped per engagement.** Before the claims of 35c,
    the eligible set is reduced to every ordinary blocked item plus at most
    `refinement_max_per_engagement` items of the refinement class, oldest block
    first — deterministically, so every node in the fleet reduces to the same set
    and they contend on the same claims rather than each engaging a different
    third of the backlog. Applied *before* claiming, because a claim taken and
    then not examined is a tombstone standing for `claim_ttl_hours` over an item
    nobody looked at.

    Ordinary blocked items are never displaced: they have no cap, and the
    refinement class cannot crowd them out. That asymmetry is the point. The
    backlog of items silently skipped before requirement 16a existed is
    unbounded and none of it is urgent, while the blocked items already in the
    queue include the pull request nobody can see (requirement 32a) — so an
    engagement that spent itself on old vagueness would make the pipeline slower
    at exactly the thing the Enabler exists for. Items over the cap are not lost:
    they are blocked, and they arrive at a later engagement.
35e. **A stale merge-conflict/abandoned-draft ref, or a retired tech-debt
    register ref, is dropped before it reaches eligibility (issue #238; widened
    by issue #1699).** `merge-conflicts` and `abandoned-drafts`
    ids are scoped to the head SHA they were detected at (requirements 3e, 3g)
    precisely so a later push mints a fresh ref that no old block covers — but
    the old ref itself is never cleared, only superseded, so left alone it would
    sit `enabler_eligible` forever: eligible every time its recheck clock came
    round, examined, and voided as stale, at full engagement price, on a repeat
    schedule. (`pr-205-conflict-305ca060016d` did exactly this — claimed and
    voided three minutes later, after the PR's head had already moved twice.)
    A `TD-<scope>-<id>` ref — a pre-migration `tech-debt/<id>.md` register id —
    fails the identical way for a different reason: since D15 as revised
    (#875) moved the tech-debt band onto `pw::type:tech-debt` issues and
    `TECH-DEBT.md` declared `tech-debt/` a frozen archive nothing gathers any
    more, such a ref can never again appear in any live band, so a marker
    keyed to one sits `enabler_eligible` forever with no push, resolution or
    supersession ever able to clear it (`TD-PPagop-26082416` did exactly this —
    nine engagements over 2026-08-28 through 2026-09-19, each reaching the
    same "deliberately parked" verdict).

    Before `enabler_allowed` is set, every eligible entry whose `item` matches
    `pr-<n>-conflict-<sha>`, `pr-<n>-superseded-<sha>`,
    `pr-<n>-dequeued-<sha>` or
    `pr-<n>-abandoned-<sha>` is tested against this
    cycle's own freshly gathered
    `merge_conflicts`/`dequeued`/`abandoned_drafts` arrays
    (requirements 3g, 3z), and every eligible entry whose `item` matches
    `TD-<scope>-<id>` is tested against this cycle's own freshly gathered
    `tech_debt` array, both snapshotted before `ordered_repos_json`'s own copies of
    those same bands lose every blocked entry to requirements 3t/3u's
    blocked/void subtraction — the Enabler is eligible only for items that are
    blocked, so testing against the post-subtraction bands would find every one
    of them missing and mark it stale forever (issue #1119): if the ref is
    absent from the pre-subtraction snapshot — the head moved again, the PR
    resolved outright, or (for a `TD-<scope>-<id>` ref) the tech-debt band
    simply never emits that shape any more — the entry is dropped, and the
    drop is logged
    (`enabler-stale-refs-skipped`, an object payload `{skipped: [{repo,
    item}…]}` — log_event's envelope merge can only add objects, and the
    bare-array form of this exact payload crash-looped the fleet
    pre-selection on 2026-08-13, issue #361) rather than silent. Both merge-conflicts
    shapes are tested, not just `-conflict-`: `pr-<n>-superseded-<sha>`
    (requirement 3g) is scoped to the same head SHA and comes from the same
    gather, and a supersession void requirement 34d refuses is recorded
    blocked under it (requirement 32a) exactly as a refused conflict void is
    under `-conflict-`. `pr-<n>-dequeued-<sha>` (requirement 3z) is tested for
    the identical reason — same head-SHA scoping, and its own gather is the
    live set that decides it. A *live* tech-debt id — an ordinary issue number,
    the shape `gather_tech_debt` has emitted since #875 — is not `TD-<scope>-
    <id>` shaped and so never matches this test, and stays exempt for the same
    reason a plain issue number or a review-feedback round does: none of the
    three has any re-detectable "current" state to compare against, and `test`
    on any of them simply never matches either pattern. A jq failure leaves
    the eligible set unfiltered — this
    is a cost saving, never the correctness gate; the Enabler still voids a stale
    item it does reach, exactly as it always has.
36. **The Enabler's powers.** It may read anything through `gh` — issues, PRs,
    reviews, checks, runs, alerts, file contents — and reads an issue or PR as
    its **whole thread** (requirement 14a's rule, for the same reason and with
    more at stake: the material that decides these items is routinely a comment
    posted after the pipeline gave up). It may leave one concise decision or
    evidence comment on the item's issue or PR.

    It must **not**: write code, push, or create or delete a branch; create,
    close, reopen, label, assign or edit any issue or pull request — it composes
    the escalation issue and **the Script files it**, because the Script is the
    only writer of this system's records and an issue it did not create is one
    no later cycle can match against its own log; merge, approve, dismiss a
    review, or mark anything ready; touch a void item; or report `unblocked`
    because the work turned out to be already done — that is a `void`, and
    requirement 9b is the whole reason the two are different states.

    It runs under the one-shot constraint of requirement 21: no resumption, no
    background notification, slow commands waited out in the foreground.

    Its runtime input is the claimed eligible entries (each carrying `repo`,
    `item`, `reason`, `blocked_ts`, the blocking stage's own `stage`, `detail`
    and `unblock_condition`, the `pr_url` the blocking event named if it named
    one — under requirement 32a a pull request nobody could hand off is a blocked
    item like any other, and for a finishing source the item id names a register
    entry rather than the PR — the `kind` and `refined_before` of requirement
    35a, and the last `escalation` if there is one), plus
    `escalation_label`, `assignee`, and this cycle's `cycle` id and `node` — the
    last two because requirement 36a's issue footer carries them, and requirement
    3e's marker stamps the Enabler's own comments with the `cycle`, and a model
    cannot know its own cycle.

    Its entire final message is one JSON object:
    ```json
    {
      "examined": [
        {"repo": "…", "item": "…",
         "verdict": "unblocked" | "still-blocked" | "escalate" | "void",
         "reason": "…", "evidence": "…", "comments_posted": ["…"],
         "complete_handoff": false,
         "unblock_condition": "still-blocked only",
         "refined_spec": "refinement only, and only for a non-issue item",
         "issue": {"title": "…", "body": "…"}}
      ],
      "notes": "…"
    }
    ```
    with one entry per item it was given.
36a. **What the Script does with a verdict.** Per examined item, and only for
    items *this cycle claimed* — a verdict naming anything else is logged as a
    `warning` and ignored, since the model cannot introduce work and an item a
    peer holds is the peer's to answer:

    | Verdict | The Script does |
    |---|---|
    | `unblocked` | logs `unblocked` with `repo`, `by: "enabler"` and the reason; the item is selectable again next cycle. With `complete_handoff: true` and a `pr_url`: refused outright with a `warning`, and no gate ever run, when the block's `stage` is not `"reviewer"` (requirement 32b); otherwise runs `handoff_complete_review` (requirement 31c) and, on a clean verdict, logs `pr-ready` with `handoff: "enabler"` — or, on a `dirty`/unreadable verdict or a flip that did not take, a `warning` naming what the gate found instead. Either refusal is also recorded as `complete_handoff` on the `enabler-examined` event (`"refused-no-reviewer"` or `"failed"`, rather than the flip word). On a refinement item, also records `item-refined` and removes the projected label (requirement 36b) |
    | `void` | corroborated by requirement 34d's shared guard; on success logs `item-void` through requirement 33's shared field shape, carrying the model's reason and evidence, and removes the projected label of requirement 34e; on refusal logs `attempt-failed` and a `warning` instead, with outcome `void-refused` |
    | `still-blocked` | nothing beyond the examined event, which carries the refreshed `unblock_condition`. With `flag_obsolete: true` and a `pr_url`: when `evidence` is the structured `{ref, path, expect, pattern}` shape and resolves live, logs `draft-obsolete-flagged` (`repo`, `item`, `pr` read from `pr_url`, `evidence`) — the machine `obsolete` alternative's first touch (requirement 34d, design doc §5.5); this is never itself a void. Without a `pr_url`, or with evidence that is not that shape or does not resolve, logs a `warning` naming which and records nothing |
    | `escalate` | files the issue (below) and logs `escalated`; on failure logs a `warning` and records the outcome `escalation-failed` |
    | any | logs `enabler-examined` with `repo`, `item`, `blocked_ts`, `outcome` and `detail` |

    The examined event is written for every verdict, including the ones that
    changed nothing: it is what stops the item being re-examined next cycle and
    what `enabler_recheck_hours` is measured from.

    **The issue contract.** Before filing, a duplicate guard: an open issue
    carrying `enabler_escalation_label` whose body already quotes the item's
    reference **backtick-delimited** — the literal token `` `<item>` ``, never
    the bare reference — *is* the escalation and is reused. The delimiters are
    what make the match unambiguous where one item reference is a string
    prefix of another, which `crash-loop:coordinator` is of every
    `crash-loop:coordinator:<owner>/<name>` (agent-ops#1694): no item
    reference this system mints contains a backtick, so the closing delimiter
    can only fall at the reference's own end. Every body filed through this
    route therefore carries its reference that way — the `` Item: `<item>` ``
    footer of requirement 2.7's crash-loop body, of `lib/approver.sh`'s,
    `lib/landing.sh`'s, `lib/standdown.sh`'s and
    `lib/required-check-preflight.sh`'s, and of the Enabler's own template
    (`prompts/enabler.md`, which states the footer is load-bearing and must
    be kept in backticks) — and a body naming the reference undelimited would
    dedup against nothing, re-filing on every later round.
    `lib/merge-budget.sh`'s freeze escalation (requirement 2.3c) carries the
    same footer but is not filed through this route: it cannot reach this
    function from where it lives, so it inlines its own copy of the guard and
    calls `gh issue create` itself, and that copy matches on the bare
    reference rather than the delimited token. Otherwise
    `gh issue create` in
    the item's own repo with that label **and** `--assignee` set to
    `enabler_assignee`, retried once without the label so a repo where the
    label has not been created still gets its issue. The assignment is the
    load-bearing half: requirement 16.4
    excludes assigned issues from the `issues` source, so the pipeline can never
    select its own request for help as work. The label is for the human's filter
    and the guard above, and must not be `blocked` — that is a separate
    exclusion criterion and would blur two different meanings into one.

    **Closure is the whole protocol**, and the issue body says so: the human
    does the thing and closes the issue. Nothing else is required of them — no
    reply, no log edit, no re-run. The closure leaves the repo's open-issue
    digest, which busts the fingerprint (35b) and makes the item eligible again
    with reason `issue-closed`, and the next engagement verifies against reality
    rather than against the closure. That loop is the reason the ask must be
    executable without further investigation: an escalation a reader has to
    interpret has failed even where its verdict was right.

    **Which escalations configuration routes, and which it does not.** An
    `escalate` verdict reached here is a person's at `always-escalate`, the
    default: the acts it typically names — a credential or secret, an
    account/settings/permissions change, a product or architecture decision,
    an external service, information that exists only in someone's head — are
    owner-only, and that rung has none of its own that could settle one. Two
    further rungs each gate a wider slice of that traffic with one bounded
    pass first, never widening what is owner-only itself (see "The owner-only
    boundary" below): `adjudicate-first` gates only requirement 36b's
    **refinement disagreement**, one bounded adjudication pass reaching a
    person only where it declines to settle it; `decide-tactical`
    (requirement 36d) gates *every* `escalate` verdict the same way, with a
    broader pass that may also decide a genuinely tactical question on the
    pipeline's own authority. `agent-cycle.sh` branches on the configured
    level and, for `adjudicate-first`, on `refinement_is_disagreement`, so
    prose describing an ordinary escalation may name the person, and prose
    describing a refinement disagreement under `adjudicate-first` may not — it
    names the condition, and the key that chooses the destination.

    <a id="the-owner-only-boundary"></a>
    #### The owner-only boundary

    Written once here and referenced —  never
    restated — by `prompts/enabler-decide.md`, `prompts/enabler.md` and
    `prompts/refiner.md`: `escalate` (or, for the Refiner, `needs-refinement`
    naming an owner-only gate) is required whenever the decision in front of
    the pipeline:

    1. spends money or changes a cap, budget, model tier or node count
       (`merge_budget_per_day`, `max_open_agent_prs`, any `*_model` key, fleet
       size);
    2. touches credentials, secrets, GitHub Apps, rulesets, permissions,
       organisation or account settings;
    3. touches licence, revenue or pricing (D5, D26) or any go-to-market
       matter;
    4. adds, amends or renames a roadmap decision (a D-number), a phase gate,
       or a roadmap item;
    5. creates an ongoing human obligation (a bump cadence, a manual check, a
       standing review);
    6. moves a trust boundary of the pipeline itself — `merge_autonomy`,
       `escalation_autonomy`, `merge_autonomy_protected_paths`, a kill switch,
       the Approver's identity;
    7. depends on an external service or account the pipeline does not
       hold — narrowed by the host-facts carve-out below;
    8. needs information that exists only in someone's head and is not
       recoverable from the repository, its threads or the fleet log — the
       same carve-out narrows this one too;
    9. was explicitly reserved by the item's author through one of
       requirement 39d's two markers — the `pw::owner-decision` label on a
       filed issue, or an `Owner decision: yes` line in a record — and never
       through prose alone ("Three readings of the boundary", below).

    **The host-facts carve-out.** Conditions 7 and 8 are refused, not
    reached, whenever `state_dir/host-facts/<node>.json` — this node's own
    record, or the copy state-sync has carried in from a peer, at
    `<peers_dir>/<peer>/host-facts/<peer>.json` — already carries the fact
    an ask would ask for (`docs/HOST-FACTS-SCHEMA.md`): a container's state,
    restart count, or running-versus-registry image digest; a container's
    cgroup memory figures; the watchtower ledger tail and last completed
    session; the host's own disk, memory and load; the host's egress MTU
    against the configured value; or, on a Kubernetes node, a pod's phase
    and restart count, a rollout's stall, a CronJob's scheduling, a
    node-pressure condition, a PVC's identity, or either driver's own
    viewer-vantage probe of a node's dashboard `data.js`. The fact is then
    available mechanically, from an account the installation already
    holds — the collector's own — and an `escalate` reaching for condition 7
    or 8 on its account is a bug in the Enabler, not a use of this boundary.
    Neither condition narrows any further than that: a field the record
    carries as `null`, a driver-specific section absent because the node
    runs the other driver, a fact this document does not carry at all, or
    an ask for something the record was never for — deciding an action on
    the strength of a fact, rather than reading one
    (`docs/HOST-FACTS-SCHEMA.md`'s own "What this record is not for") —
    still escalates exactly as before, and so does every account the
    installation does not hold and every fact that exists only in someone's
    head.

    **Three readings of the boundary.** Part of the boundary, not glosses on
    it: a pass that refuses on a reading these exclude is acting narrower
    than its own authority, and that is a defect in the pass.

    - **Markers, not prose (condition 9).** Only requirement 39d's two
      markers reserve a choice. A body that calls a choice "for a human",
      "an architecture decision", or "not a guess `compose.yaml` should make
      on its own" is a filer's hedge — the shape requirements 36c/42a's
      filers produce by habit — never a reservation, and quoting such a
      sentence as condition 9 is a bug in the pass. Authorship never stands
      in for the marker: while the fleet authors under the owner's own
      identity (D25's authoring App unprovisioned, agent-ops#1083) every
      pipeline filing reads as the owner's, so the author field cannot tell
      a reservation from a hedge; once the App exists the marker is still
      what reserves, so the rule does not change with it.
    - **Undefined thresholds are set, not asked (condition 8).** A threshold,
      soak length, trust bar or count the item's own record leaves open is
      not information in anyone's head — nobody holds it. The pass sets it
      at the conservative end of what the record supports, states the value
      and the reading of the record it rests on in `decision`, and the veto
      (requirement 36e) is the correction. Condition 8 is reached only by a
      fact a specific person holds and the record does not.
    - **The in-boundary option.** The boundary bounds decisions, not
      comparisons. Where an item enumerates options and at least one lies
      wholly inside the boundary, choosing that option is tactical: the pass
      decides it, naming the out-of-boundary options it set aside as such.
      That a sibling option would need a credential, an account the
      installation does not hold, or a roadmap change reserves *that
      option*, never the choice.

    Everything else is tactical, and a `decide-tactical` pass (requirement
    36d) may settle or decide it: an engineering trade-off among options the
    item's own record already enumerates, a config-key semantics question,
    guard behaviour, a spec-prose correction, a scope affirmation on a closed
    issue, a naming choice that touches no roadmap item, a choice between two
    reversible shapes. `always-escalate` and `adjudicate-first` never reach
    this list at all — every `escalate` verdict they cannot resolve some other
    way already goes to a person — so it binds only the rungs wide enough to
    need it.

    **What `decide-with-veto` adds.** Requirement 36f's delegate mandate is
    the one thing that moves any of the nine: at that rung, and only for a
    pass whose input carries `mandate: "delegate"`, condition 2's acceptance
    clause and the human corroboration of a void for three pull-request
    shapes are reachable. It is written there, in full and once, and this
    list is unchanged by it at every other rung.
36b. **The refinement duty.** For an item carrying `kind: "needs-refinement"`
    (requirement 34e) the Enabler reads the item and its whole context and then:

    - **Specifies it**, where the work can be specified without deciding
      anything that belongs to a human — a missing acceptance criterion derivable
      from the code, a scope bound the repo's conventions already imply, a
      reproduction reconstructible from a failing run. The verdict is
      `unblocked`, and *where the refinement lands is decided by whether the
      item has a thread*, because it has to land where a future Co-Ordinator
      will read it. The test is the gather entry's own `number` — carried by
      every issue-backed source and by no other — and never the item's source
      band, which agent-ops#875 showed can acquire a thread without the rule
      here changing a word (requirement 4j):
      - an item **with a thread**, which is every `issues` item and, since
        agent-ops#875, every `tech-debt` item: **one** authoritative comment on
        the issue carrying the refined specification (goal, scope bounds,
        acceptance criteria, pointers to the relevant files and conventions),
        its URL returned in `comments_posted`. Requirements 14a and 20 already
        have the Co-Ordinator read the whole thread and paste it, so this needs
        no new carrier;
      - an item **with no thread** — a review recommendation, a plan task: the
        specification is returned in `refined_spec` as self-contained markdown,
        because there is nowhere to write it to and no actor here may edit the
        register. Requirement 3h is its carrier.

      Exactly one of the two, never both: a verdict offering a `refined_spec`
      beside a `comments_posted` URL is recorded as the URL alone
      (requirement 4j's own "one home per refinement").

      **The unselectability note** (agent-ops#447). For an issue item, before
      posting, the Enabler checks the issue's own live assignees — a `gh`
      read, since nothing pre-fetched carries it — because requirement 16.4
      excludes an assigned issue from the `issues` source regardless of how
      good the refinement just written for it is: the two gatherers apply
      that exclusion on different terms (`scripts/gather-issues.sh`
      deterministically, `scripts/gather-hand-flagged-refinements.sh` not at
      all, by design — see requirement 16.4's own note on why the exclusion
      stays permanent), so an item can be *specified* here while remaining
      *unselectable* there, with nothing about the refinement comment itself
      saying so. Since agent-ops#639, this block's own bookkeeping is never
      an assignment — requirement 38b projects `blocked`/
      `blocked:needs-refinement` labels instead, which the Enabler will
      already see on the issue and which need no note of their own, since
      they carry no ambiguity about who applied them. So any assignee found
      here is unambiguously a human's own, made for their own reasons before
      this verdict, and the comment states plainly that a human needs to
      remove it before the issue becomes selectable, however complete the
      specification above it now is. This is a **note**, never a
      **verdict**: it changes nothing about the choice between `unblocked`,
      `still-blocked` and `escalate` below, and never turns a refinement
      into an escalation on its own.

      **The default-first rule** (agent-ops#938). An item that enumerates
      candidate fixes is not, on that account alone, one this stage cannot
      settle. Where its body carries a `## Default: <fix>` heading — or a
      record's own `default_fix` field — the filer has already named the
      option it would take, from a stage that had just read the code, and the
      Enabler specifies to that option, noting which alternatives the filer
      considered and why the default was chosen. Where the item instead
      carries the `pw::owner-decision` label or an `Owner decision: yes` line
      (requirements 36c, 42a), the choice is reserved under 36a's boundary
      and this is an `escalate`. An item carrying neither marker follows
      requirement 39d's third case exactly — that rule and this one are one
      rule with two readers: specify to the option the item's own text argues
      for; where it argues for none and the options differ only in mechanics,
      with no operator-visible behaviour change either way, specify to the
      smaller one and say so; only an unmarked fork that genuinely differs in
      operator-visible behaviour is an `escalate`.
    - **Escalates**, where this stage cannot settle it — a decision, answer, or
      action is needed first — through the unchanged protocol of requirement
      36a, in a **separate** issue. Never the work item's own issue: that
      protocol ends with "close this issue when you are done", which on the
      item's own issue asks the human to close the work itself and removes it
      from the `issues` source. The ask is phrased so
      the human's answers land as comments on the escalation issue *before* they
      close it, since the closure is what returns the item to a later engagement
      and their comments are what let that engagement complete the refinement.
      Where the work item is itself an issue, the Enabler also posts one
      comment on it saying an escalation is being requested, so the context
      stays visible where the work lives — but it never asserts the
      escalation issue already exists or names its number (agent-ops#815):
      the Enabler's own turn ends before any of the three things that decide
      whether one actually results have run — a possible `adjudicate-first`
      override, the `create_escalation_issue` call, and whether that call
      succeeds — so it cannot truthfully claim the outcome yet. The Script
      completes the thread once it knows that outcome
      (`escalation_thread_reconcile`, `lib/enabler.sh`), scoped to exactly
      this case (a `needs-refinement` item whose ref is a bare GitHub issue
      number):
      - **filed** — a completing comment carrying a structured `Blocked-by:
        #<n>` line naming the escalation issue's own number (agent-ops#639),
        the same convention requirement 34j already parses out of any issue
        thread. That line is what makes the link deterministic rather than
        merely readable: the very next gather sees it,
        `scripts/gather-issues.sh` excludes the work item as `blocked-by:
        #<n>` on its own (requirement 3j), and the exclusion — and its
        clearing, the moment the escalation issue closes — is recorded
        through the ordinary `issues-excluded` event without this
        requirement needing a bespoke mechanism of its own;
      - **superseded by an `adjudicate-first` `adequate` verdict**, before
        `create_escalation_issue` ever runs — a correcting comment stating
        plainly that no escalation was filed, because the pass found the
        existing refinement adequate and the item was unblocked on that
        basis instead;
      - **`create_escalation_issue` itself fails** — a correcting comment
        stating that the escalation attempt failed and a later
        re-examination will retry it. Skipped entirely — nothing posted —
        when this exact comment is already the thread's single most recent
        comment (`escalation_thread_failed_already_posted`, agent-ops#998):
        matched on the fixed prose plus the pipeline marker's `actor=script`/
        `actor=enabler` field, ignoring the marker's own `cycle=` id, so a
        retry whose `gh` calls stay healthy but whose verdict still carries
        no filable title/body does not repeat this comment on every retry
        until the item clears. Checking only the literal most recent comment
        — never "any prior `escalation-failed` reconcile since `blocked_ts`"
        — keeps this conservative: once any other comment (human or Script)
        lands on the thread after the last one, the dedup no longer applies
        and the next `escalation-failed` outcome posts a fresh notice.

      Three items escalated in the same cycle (#604, #613, #640) each
      carried this false claim — "an escalation issue was raised" —
      uncorrected, because nothing reconciled the Enabler's own comment
      against what the Script went on to do; this reconciliation, and the
      prompt no longer asserting a number it cannot know, is the fix.
      Best-effort like every other `gh` write this stage makes (requirement
      37): a failure to post either comment is a `warning`, never a reason to
      unwind the verdict already recorded.

      **`escalation_autonomy` (D18, agent-ops#627).** When the item this
      verdict escalates is a refinement disagreement — `kind:
      "needs-refinement"` with `refined_before` set, the same shape the thrash
      guard below refuses a second `unblocked` verdict against
      (`refinement_is_disagreement`, `lib/refinement.sh`) — and this
      repository's `escalation_autonomy` resolves to exactly `adjudicate-first`
      (`escalation_autonomy_configured_level`, `lib/escalation-autonomy.sh`,
      the same `stage_timeouts`/`merge_autonomy` per-repo-override precedence,
      requirement 4f — `decide-tactical` runs its own broader pass instead,
      requirement 36d), the Script runs one
      bounded adjudication pass (`run_enabler_adjudication`,
      `prompts/enabler-adjudicate.md`) — a fresh, narrower engagement over
      this one item alone, at `enabler_model_critical` (falling back to
      `enabler_model`) — before it files the issue
      above. The pass reads the item's existing refinement
      (`refined_before`'s own `spec`/`comment_url`), the re-flag's recorded
      reason (`detail`/`unblock_condition`), and this verdict's own
      `issue.title`/`issue.body`, and returns exactly `adequate` or
      `inadequate`, logged as an `enabler-adjudication` event carrying that
      verdict, its `evidence`, and `adjudication: true`. `adequate` is
      recorded exactly as an ordinary `unblocked` refinement — an `unblocked`
      event plus `item-refined`, carrying the *existing* refinement's own
      `spec`/`comment_url` unchanged, since the pass confirmed it rather than
      writing a new one — and no escalation issue is filed. `inadequate`, a
      missing adjudication prompt, a stage failure, or an unparseable verdict
      all escalate, with the pass's own `evidence` appended to `issue.body`
      under an `## Adjudication attempted` heading (agent-ops#681) before the
      issue is filed, so the human starts from why an adjudicator's answer is
      missing rather than only the pre-adjudication verdict: "cannot settle"
      is not read as "nothing wrong" (the same rule requirement 8c's own
      adjudication path applies to its own unreadable verdicts). The default,
      `always-escalate`, is byte-for-byte today's behaviour — no adjudication
      pass ever runs.

      **Bounded, not a loop.** One pass per item, per human touch
      (`escalation_autonomy_pass_available`, `lib/enabler.sh`, over
      `escalation_autonomy_adjudicated_before`): where an
      `enabler-adjudication` event for this item is already on the log — one
      carrying `pass: "decide-tactical"` (requirement 36d) does not count here,
      so a repository that has moved between the two rungs never has one
      rung's bound spent by the other's history — no further pass runs and the
      escalation is filed as it would have been at `always-escalate`, the
      refusal recorded as a `warning` naming the item.
      The one exemption is the thrash guard's own — eligibility `reason:
      "issue-closed"`, which exists only because a human acted on an
      escalation about this item (requirement 35a), so the pass it authorises
      is the first since they did. Mechanical for the same reason the thrash
      guard is: an `adequate` verdict clears the block and re-records the
      *existing* refinement, so the item returns to the pool with
      `refined_before` still set and a re-flag of it reaches this same
      `escalate` verdict over this same evidence — which an unbounded pass
      would answer the same way, indefinitely, with nobody ever paged. At
      `adjudicate-first`, every escalation this verdict can reach that is not a
      refinement disagreement (an ordinary blocked item, an owner-only
      decision, a strategy call) is unaffected by this rung: it only ever
      replaces one escalation with one adjudication pass that itself either
      confirms the earlier refinement or escalates anyway, never widens what
      the Script may decide without a human. `decide-tactical` (requirement
      36d) is the one rung that does reach an ordinary blocked item too — it
      is a distinct, broader pass with its own bound, described there rather
      than here.
    - **Leaves it blocked**, where the gating decision is recorded as
      deliberately parked — an open question with a decide-by gate in a roadmap
      or plan, or a thread saying the decision is intentionally deferred. The
      verdict is `still-blocked` with that as the `unblock_condition`. Escalating
      a decision the human has already chosen to defer asks them to re-make it,
      and spends the one resource this system exists to conserve.

    `void` and `still-blocked` keep their ordinary meanings and evidence bars.

    **The Script's side.** On an `unblocked` verdict for a refinement item it
    records `item-refined` (requirement 33) carrying the `refined_spec` and/or
    the first URL in `comments_posted`, alongside the ordinary unblock handling,
    and removes the projected label. A verdict carrying neither gets a `warning`:
    the block clears and the item returns to the pool exactly as under-specified
    as it was, which is the one outcome this path must not produce silently.

    **The thrash guard.** An item is refined at most once between human touches.
    Where `refined_before` is set, a second refinement is not the answer: two
    models disagreeing about whether a specification is adequate is a
    disagreement that escalates instead — adjudicated first at
    `adjudicate-first`, reaching a person directly at `always-escalate` — and a
    third pass from the Enabler settles it only by coincidence. The prompt says
    so, and the Script enforces it — an `unblocked` verdict on a refinement
    item whose `refined_before` is set is **refused**,
    logged as a `warning`, and recorded with the outcome `refinement-refused`,
    leaving the item blocked. Mechanical for requirement 34d's reason: "do not
    do this" is already in the prompt, and the model that would do it anyway is
    one that has convinced itself.

    The single exception is the eligibility reason `issue-closed`, and it is
    what makes "per human touch" a rule the Script can check rather than a hope:
    that reason exists only because a human acted on an escalation about this
    very item (requirement 35a), so the refinement it authorises is the first
    since they did.
36c. **`file_debt`/`file_issue` (agent-ops#631): filing what the Enabler
    noticed, without it writing anything itself.** Orthogonal to `verdict` —
    an item's `examined` entry may carry either, both, or neither alongside
    `unblocked`, `still-blocked`, `escalate` or `void` alike, since what it
    names is deferred work the engagement noticed, not what it decided about
    the item in front of it. Each is `{title, body, default_fix, owner_decision}`;
    a field present with either `title`/`body` empty is a `warning` and
    nothing is filed. The Script — never the
    model, which carries no GitHub-writing power under "What you must never
    do" — performs the filing via `lib/tech-debt-file.sh`, under the ordinary
    pipeline login (the Enabler holds no App identity of its own the way the
    Approver does, requirement 42a):

    - `file_debt` (agent-ops#874, D15 as revised #869) files a single GitHub
      issue in the target repository, labelled `pw::type:tech-debt` — the
      same trust anchor `scripts/gather-tech-debt.sh` reads to serve the
      band — deduped first against that repository's own open
      `pw::type:tech-debt` issues by normalised title
      (`_techdebt_title_dedup_match`, `lib/tech-debt-file.sh`): a match gets
      the new body and provenance as a comment instead of a second filing.
      No id reservation, no branch, no pull request — one API call either
      creates the issue or comments on the matched one. Logs
      `tech-debt-filed` (`repo`, `item`, `by: "enabler"`, `issue_number`,
      `issue_url`) on success; a `warning` naming `tech-debt-file.err` on
      failure.
    - `file_issue` reuses the same duplicate-guard shape requirement 36a's own
      escalation issue does — an open issue already quoting the item
      reference *is* the record — but carries no label and no assignee: unlike
      an escalation this is not addressed at a specific human, and is
      legitimate autonomous work for the `issues` source to pick up later, not
      a request that source must exclude (`owner_decision: true` below is the
      one exception, adding a label of its own). Logs `issue-filed` (`repo`,
      `item`, `by: "enabler"`, `issue_number`, `issue_url`) on success; a
      `warning` on failure.
    - `default_fix`/`owner_decision` (agent-ops#938, requirement 23d's own
      `techdebt_default_section`): `default_fix` is the option the Enabler
      would take, one sentence, required whenever the body names more than
      one; `owner_decision` is `true` only under requirement 36a's boundary.
      Both are threaded straight through to `techdebt_file_debt`/
      `techdebt_file_issue`, which write a `## Default: <default_fix>`
      heading into the filed body (`## Default: not stated` when
      `default_fix` is empty) and, for `owner_decision: true`, an
      `Owner decision: yes` line beside it for `file_debt` or the
      `pw::owner-decision` label for `file_issue` — `file_debt`'s own filed
      issue never carries that label, since the choice it marks is
      independent of the storage move requirement 36c's own bullet above
      describes. A verdict carrying neither
      `default_fix` nor `owner_decision: true` is filed anyway — never
      lost — but is malformed: logged as a `warning` naming the item, so the
      refusal is counted and the filing prompts can be tuned.

    Neither call changes `verdict` or the item's `enabler-examined` outcome —
    a failed filing attempt costs a `warning`, never a reason to treat the
    item itself as unresolved.
36d. **`decide-tactical` (D18, agent-ops#936).** The third rung of
    `escalation_autonomy`, including everything `adjudicate-first` reaches
    (requirement 36b's own paragraph of the same name) and widening it: at
    `decide-tactical`, before the Script files the escalation issue for **any**
    `escalate` verdict this Enabler engagement reached — an ordinary blocked
    item as much as a refinement disagreement — one bounded decide pass runs
    first (`run_enabler_decide`, `prompts/enabler-decide.md`), a fresh,
    narrower engagement over this one item alone, at `enabler_model_critical`
    (falling back to `enabler_model`). The pass reads the item's `kind`, its
    existing refinement where it has one (`refined_before`'s own
    `spec`/`comment_url`, empty for an ordinary blocked item or a
    never-refined `needs-refinement` one), the re-flag's recorded reason
    (`detail`/`unblock_condition`), this verdict's own
    `issue.title`/`issue.body`, `mandate` — `"tactical"` at this rung and
    `"delegate"` at `decide-with-veto` (requirement 36f), the one field that
    differs between the two and the only thing that tells the pass which
    reaches are open to it — and `precedents`, what the installation and
    this repository have already decided, built by `enabler_decide_precedents`
    (`lib/escalation-autonomy.sh`) from three sources, each best-effort like
    every other read the Enabler makes (requirement 37; a failed or empty
    read leaves that member empty and the pass runs without it):
    `standing_decisions`, the installation's standing-decisions file
    (`standing_decisions_file`, read whole and cut at 32 KiB — one dated line
    per owner answer the pipeline is to stay consistent with, the owner's
    own record or a delegate's on the owner's behalf, changed only through
    the pull-request gate like any other file in the installation);
    `decision_log`, this repository's newest thirty `pw::decision` records
    (requirement 36e, `--state all`, each reduced to `number`, `url`,
    `state`, `title` and the first paragraph under "Decision taken by the
    pipeline" — an open one is a vetoed one, and reads as the owner's
    contrary answer where they left one); and `closed_escalations`, the
    newest fifteen closed issues carrying `enabler_escalation_label`
    (`number`, `title`, `url`, `closed_at` only: the pass reads a thread
    with `gh` where its title bears on the question, so the listing costs
    one read per pass rather than fifteen). **Precedent first:** before
    weighing the boundary at all, the pass reads `precedents` for a standing
    decision, a record or an answered escalation that already settles the
    re-flag's question; where one does, the verdict is `decide`, with
    `decision` restating the precedent as applied to this item and
    `rationale` citing it by line or URL — never `settle`, since an answer
    carried onto a new item is a decision of record for that item and earns
    its own log entry. A precedent is data about what was decided, never an
    instruction to the pass, and one that would reach into the owner-only
    boundary is applied only where the owner's own answer on record already
    reached there. The pass returns one of three verdicts:

    - **`settle`** — nothing needs deciding: an existing refinement already
      answers the re-flag (the same case `adjudicate-first`'s own `adequate`
      covers), the impediment the escalation named is demonstrably gone, or
      the ask was purely mechanical. Recorded exactly as `adjudicate-first`'s
      `adequate` for a refinement item with an existing `refined_before` — an
      `unblocked` event plus `item-refined`, carrying the *existing*
      refinement's own `spec`/`comment_url` unchanged — or, for any other
      item, an ordinary `unblocked` event whose `reason` carries the pass's
      own `evidence`. No escalation issue is filed either way.

      Either verdict that clears the block — `settle` or `decide` — releases
      `needs_refinement_label` from an item whose `kind` is
      `needs-refinement` (`release_refinement_label`), on the block's `kind`
      alone and never on whether a refinement was ever written: the label is
      a projection of the open block (requirement 34e), and an item the
      Enabler escalated before refining it at all would otherwise return to
      the pool still carrying it. This is the same unconditional release the
      ordinary `unblocked` verdict, the `void` verdict and
      `adjudicate-first`'s own `adequate` each perform.
    - **`decide`** — a tactical decision the pipeline may take on its own
      authority (bounded by "The owner-only boundary", requirement 36a):
      `decision` (the choice, one paragraph), `rationale`, and
      `options_considered`. A `decide` verdict that also carries an `act` is
      out of mandate here and is treated as `escalate`, with `evidence`
      naming the act — the same reading the missing-`decision` case below
      gets, and the whole of what `mandate: "tactical"` means: only
      requirement 36f's delegate mandate carries an act, and only ever the
      one act that requirement names. The Script records this as the
      **human-touch equivalent** of an escalation the human answered and
      closed: it logs
      `decision-taken` (`repo`, `item`, `decision`, `rationale`,
      `options_considered`, `comment_url` where one exists, `model`,
      `reason_key` — the same fingerprint the bound below computes) and logs
      `unblocked` (`by: "enabler"`, `reason` naming the decision). Where the
      item is itself a GitHub issue, it additionally posts one comment on the
      item's own thread (`enabler_decision_comment`) in the pipeline's voice
      — actor `enabler-decide` — carrying the decision, the rationale, the
      options considered, and, where the item already carried a refinement,
      a statement that the existing specification stands amended by this
      decision; its URL is what `decision-taken` records as `comment_url`.
      This never writes a specification of its own, and `item-refined` is
      logged only where the item already carried one (`refined_before` set)
      — re-recording that existing refinement unchanged, on the same terms
      `settle` does — never invented from the decision, and marked
      `unchanged: true`. For a non-issue item, the decision has no thread to
      carry it regardless of whether it already had a refinement: it is
      recorded on `decision-taken` and read back by `decisions_map`
      (`lib/cycle-state.sh`) into `decisions_json`, a carrier alongside —
      never merged into — `refinements_json` (requirement 3h), supplied to
      the next Refiner engagement for that item as its runtime input's own
      `decision` field (`refiner_candidate_items`, `lib/refinement.sh`)
      beside `entry`. Where the item is also thread-less — no `entry.number`,
      and no numeric `item` substituting for one, the same test requirement
      36b's own carrier rule uses — and is not `triage_only`,
      `refiner_candidate_items` reads
      `refinements_json` (requirement 3h) for the prior refinement itself and
      supplies it too, as a `refinement` field beside `decision`, never
      inside `entry` (agent-ops#1058): without it `entry` carries no
      specification at all for a thread-less item, and the decision alone
      would have the Refiner compose a fresh specification rather than amend
      the existing one. A thread-backed item's specification is already in
      `entry`'s own comments, so it never carries this field; neither does a
      `triage_only` candidate, which requirement 39g forbids a second
      specification regardless of what else it carries. Where a
      refinement already existed, `decisions_map`
      does not treat the `unchanged: true` re-record above as having carried
      the decision forward — an unmarked `item-refined` is what supersedes a
      decision, since only that shape is the Refiner actually turning one
      into a specification — and `refiner_candidate_items` offers the item
      as a full (non-`triage_only`) candidate despite `refinements_json`
      showing it refined, for as long as `decisions_json` still names a
      pending decision for it (agent-ops#1049). Without both, a refined
      non-issue item's decision reaches no carrier at all: `item-refined`'s
      own re-record would otherwise both exclude the item from
      `refiner_candidate_items` and appear, by its later `ts` alone, to have
      already superseded the decision in `decisions_map`. The Refiner turns a
      decision into the specification the way it would a human's own answer
      on a closed escalation (`prompts/refiner.md`). `decisions_json` reaches
      the Refiner only — the Co-Ordinator model is never shown it — so a
      non-issue item `decisions_json` still names a pending decision for is
      withheld from Co-Ordinator ranking entirely (`exclude_decision_pending_items`,
      `lib/candidate-select.sh`, called from `compute_band_eligibility` for
      every pre-fetched band but `issues`) until an unmarked `item-refined`
      supersedes the decision in `decisions_map`, exactly the same condition
      that makes the item a full Refiner candidate above (agent-ops#1057) —
      **but only where some actor can later lift the withholding.** Only the
      Refiner ever writes the superseding `item-refined`, so the withholding
      binds only where the item's own source is not `refinement_policy`
      (requirement 39a) `exempt` — an `exempt` source is never a Refiner
      candidate at all (clause 2 of requirement 39a), so withholding it here
      too would leave it permanently invisible to every automated actor, not
      merely for the one cycle this mechanism exists to close — and only
      where this installation has a Refiner configured at all (`refiner_model`
      set), since with none, nothing of any source could ever be restored
      either. Both gates are evaluated once per entry (the first) and once per
      cycle (the second), never per band: the `findings` band, for one, carries
      both `security`- and `code-quality`-sourced entries, which resolve
      `refinement_policy` separately. `human-visibility` needs no separate
      carve-out to be covered: its source is not among the keys
      `refinement_policy`'s own schema allows (`config.schema.json`,
      `additionalProperties: false`), so no installation can ever set it to
      anything but the default, and the first gate resolves it `exempt` at
      every valid configuration — permanently, not merely by the absence of a
      source every other band could still name. This is still **not** `refinement_policy`
      shaping how an item ranks — it is a reachability precondition on a
      different mechanism entirely, stated once here rather than duplicated at
      every call site (confirmed as a genuine specification defect, not merely
      an implementation gap, by the Reviewer and the Enabler on PR #2047: the
      original "binds at every policy, `exempt` included" wording and clause 2
      of requirement 39a cannot both hold for an `exempt`-sourced item, since
      the first withholds it from the Co-Ordinator and the second already
      forecloses the only route back). An `issues` item is never withheld this
      way regardless — its decision travels as a comment in the thread the
      Co-Ordinator already re-reads live (requirement 18a), so it can never
      dispatch a specification the pipeline considers superseded the way a
      non-issue item can.
    - **`escalate`** — anything else: any owner-only condition applies, the
      re-flag's own concern is real and unresolved beyond what the item's
      record supplies, or the pass could not read enough to tell. As
      `adjudicate-first`'s own `inadequate`, with the pass's own `evidence`
      appended to `issue.body` under an `## Adjudication attempted` heading
      (agent-ops#681) before the issue is filed. A missing
      `prompts/enabler-decide.md`, a stage failure, an unparseable verdict, or
      a `decide` verdict missing its own `decision`/`rationale` all fall to
      `escalate` too, on the same "cannot settle is not the same as nothing
      wrong" reading requirement 8c's own adjudication gives an unreadable
      verdict.

    Every pass, whichever verdict it reaches, is logged as an
    `enabler-adjudication` event carrying `verdict`, `evidence`,
    `adjudication: true`, `pass: "decide-tactical"`, `reason_key`, and
    `eligibility_reason` — the `pass` field is what keeps this rung's own
    passes out of `adjudicate-first`'s unrelated bound
    (`escalation_autonomy_adjudicated_before` excludes it explicitly),
    `reason_key` is what the bound below reads for "same reason twice", and
    `eligibility_reason` — the claimed entry's own `reason` (`threshold`,
    `recheck` or `issue-closed`) — is what it reads for "since the last human
    touch" (agent-ops#1051). `decision-taken` (below) carries the same
    `eligibility_reason` for consistency, though only the pass event's own
    copy is read back by the bound.

    **Bounded per reason, not per item** — `escalation_autonomy_decide_pass_available`,
    `lib/enabler.sh`, over `escalation_autonomy_decide_reason_key`/
    `_reason_seen`/`_pass_count` (`lib/escalation-autonomy.sh`). A pass is
    available when eligibility `reason` is `issue-closed` — the same one-touch
    exemption `adjudicate-first`'s own bound grants, a human having just acted
    on an escalation about this item (requirement 35a) — or when both hold:
    no `enabler-adjudication` event tagged `pass: "decide-tactical"`, nor any
    `decision-taken` event, for this item already carries the *same*
    `reason_key` — a SHA-256 fingerprint, truncated to 16 hex characters, of
    `detail` and `unblock_condition` lower-cased and whitespace-collapsed, so
    two engagements paraphrasing the same complaint still collide — and fewer
    than `escalation_adjudication_max_passes` (default `3`) decide-tactical
    passes, over any reason, have run for this item since its last human
    touch — or ever, if it has had none (`_pass_count`, above). The touch
    itself has no independent record: `_pass_count` reads it off the pass
    events' own `eligibility_reason` field — the claimed entry's own
    `reason`, carried onto both the `enabler-adjudication` event above and
    `decision-taken` — and counts forward from the latest decide-tactical
    pass tagged `eligibility_reason: "issue-closed"` for the item, so a touch
    resets the budget in full rather than granting one further pass on top of
    a lifetime total (agent-ops#1051). A repeat of the *same* reason
    escalates outright, regardless of how much of the cap remains — the
    genuine two-models-disagree loop `adjudicate-first`'s own bound exists to
    stop, one rung wider; a *fresh* reason still earns its own pass, up to
    the cap.
36e. **The decision log and veto (D18, agent-ops#937).** A `decide-tactical`
    decision is taken on the pipeline's own authority (requirement 36d) rather
    than paged to a human before the fact — the round-trip agent-ops#627
    exists to remove — but it must not thereby become invisible or
    irreversible: the D18 pattern requirement 36a's own escalation issue and
    the Autonomous landings dashboard panel already give an escalation and a
    landing (a log a human can scan in one place, a lever they can pull) is
    what a decision gets here.

    **The log.** Every `decide` verdict (requirement 36d) files, in addition
    to everything that verdict already does, one decision-log issue in the
    item's own repository: `create_decision_log_issue` (`lib/enabler.sh`),
    modelled on `create_escalation_issue` but filed **closed** and
    **unassigned** — a record, not an ask — labelled `pw::decision` (a fixed,
    unconfigurable name, `lib/labels.sh`'s `labels_catalogue`, `target` and
    `escalation` roles both, for the same reason `pw::type:tech-debt` and
    `pw::owner-decision` are fixed: it is what `scripts/sweep-decision-vetoes.sh`
    below searches every configured repository for, and a renamed label would
    silently stop being swept). Its body carries a leading machine marker
    (`<!-- agent-ops:decision-log item=<item> repo=<repo> reason_key=<key> -->`,
    invisible on GitHub) naming the original item, a "## Decision taken by the
    pipeline" section (the decision, the rationale, `options_considered`, the
    model and cycle, a link to the item-thread comment where one exists), and
    the same body-footer item reference `create_escalation_issue`'s own
    duplicate guard keys on (`Item: `<item>` · repo `<repo>``) — reused so
    both guards find the same set of issues for the same item, per this
    requirement's own origin; unlike that guard, this one searches
    `--state all`, since the log issue is filed closed and stays closed until
    vetoed, and `pw::decision` is never dropped on a failed create the way
    `create_escalation_issue` will retry an ordinary escalation without its
    own label — the label here is what the veto sweep below and this same
    duplicate guard both search on, so an issue filed without it would be a
    veto lever dead on arrival; a create that fails with the label is a plain
    failure instead (a `warning`, per the failure-containment note below).
    The guard's match on the item reference alone is additionally narrowed by
    `reason_key` (`escalation_autonomy_decide_reason_key`, requirement 36d) —
    matched against the marker's own `reason_key=` field, empty matching
    every body the way an absent value always does here: an item ref alone
    matches *every* decision this item has ever carried, so without this a
    second, legitimate decide verdict over a distinct reason (permitted —
    the per-reason bound counts passes, not decisions) would silently reuse
    the first decision's own closed issue rather than filing a fresh one
    (agent-ops#1198) — its body would go on showing the first decision's
    text while the second is the decision of record, and a veto of the first
    would leave `decision_vetoes_processed_items` (keyed on that one issue
    number) refusing to ever process a veto of the second.
    `scripts/sweep-decision-vetoes.sh`'s own marker read treats `reason_key`
    as optional, so a log issue filed before this fix still parses. `decision-taken`
    (requirement 36d) carries the log issue's own `issue_number`/`issue_url`
    once filed — merged in conditionally, the same way it already carries
    `comment_url` — and `decisions_map` (`lib/cycle-state.sh`) threads both
    through to `decisions_json` unchanged. Filing (or closing) the issue is
    best-effort like every other `gh` write the Enabler makes (requirement
    37): a failure costs a `warning`, never the decision itself — it is still
    recorded on `decision-taken` and the item is still unblocked, only
    without a durable log or a lever to veto it.

    **The veto.** Reopening the log issue is the veto — a reopen is honoured
    whenever it comes, with no window. `scripts/sweep-decision-vetoes.sh`, a
    per-cycle, fleet-wide sweep run from `run_decision_veto_sweep`
    (`lib/decision-veto.sh`) — deliberately *not* from `run_standdown_checks`
    (`lib/standdown.sh`), since that function runs before `compute_skip_lists`
    sets `blocked_json`, which the needs-refinement recording below needs
    current — searches every configured repository for an open `pw::decision`
    issue that GitHub's own issue-events API says was *reopened* (an open log
    issue carrying no `reopened` event is one whose own filing could not close
    it, per the best-effort close above, never a veto — it is reported as a
    warning and left alone; a failed events read falls open toward honouring
    the veto, on the same terms the terminal classification below does),
    reads the original item's repo/ref back off the issue body's own
    machine marker, and acts on each one this cycle has not already processed
    (`decision_vetoes_processed_items`, `lib/cycle-state.sh`, keyed on the log
    issue's own number — not the original item's ref, since one item can
    carry more than one decision, and hence more than one veto, over time —
    over the log's own `decision-vetoed` events; the sweep script itself never
    writes the log, `lib/decision-veto.sh` does, from its stdout, the same
    contract every sweep in `lib/standdown.sh` keeps):

    - logs `decision-vetoed` (`repo`, `item`, `issue_number`, `issue_url`,
      `by` — the reopening actor GitHub's own issue-events API reports) —
      exactly once per veto, never once per cycle the log issue stays open,
      by construction of the exclusion above;
    - where that same log issue still carries a pending act
      (`pending_decision_acts`, `lib/cycle-state.sh` — requirement 36f's
      `decide-with-veto` decisions whose act is owed but not yet performed),
      logs `decision-acted` with that act and `outcome: "cancelled"`. The
      act is already retired by the veto mechanically — the pending set
      excludes anything a `decision-vetoed` names — so this event exists for
      the record rather than for the effect: a pending act that merely
      stopped appearing would leave nothing saying the reopen is what
      stopped it, and a cancellation the owner cannot see is not the lever
      requirement 36f promised;
    - where the original item is **not terminal** (its own GitHub issue is
      still open, or, for an item with no thread, its implementing pull
      request is still open or none can be found — a classification failure
      fails open toward "not terminal", so a needless re-block costs one
      wasted needs-refinement cycle rather than silently dropping a veto on
      an item still active): records a `needs-refinement` block against it
      (`record_needs_refinement_block`, `lib/candidate-select.sh` — called
      in-process from `lib/decision-veto.sh`, since only that function
      projects the requirement 38b labels the same way every other
      needs-refinement block does), `unblock_condition` naming the owner's
      own comment on the log issue as the decision of record, and posts one
      comment on the item's own thread (issue-shaped items only) naming the
      veto and the log issue;
    - where the item has an **open pull request** (found the same
      marker-or-branch way `scripts/sweep-closed-issues.sh` already finds
      one): posts one comment on it naming the veto and flips it back to
      draft (requirement 34's draft flip, re-verified by re-reading
      `isDraft` rather than trusted from `gh`'s own exit code, the same
      caution `confirm_pr_draft`, `lib/handoff.sh`, applies) — the human's
      own `CHANGES_REQUESTED` path is unaffected and still stronger;
    - where the item is **terminal** (merged or closed): files a fresh
      "revisit: `<decision title>`" issue, labelled `bug`, quoting the log
      issue's own most recent comment (the veto's own explanation, where one
      was given), and comments once on the log issue naming it — there is no
      open work left to re-block.

    Alongside the `needs-refinement` block, `lib/decision-veto.sh` logs one
    `escalated` event naming the same log issue (`issue_number`/`issue_url`,
    `decision: true`) — the log issue *is* registered as the item's
    escalation, on the same `escalated` event `ENABLER_ELIGIBLE_JQ`
    (`lib/cycle-state.sh`) already reads for an ordinary Enabler escalation.
    While the log issue stays open (reopened), `$issue_state` reads `open`
    and the item is not eligible at all — a mechanical hold, not merely a
    request the pipeline is expected to honour: the item never reaches the
    Enabler to be re-examined, so nothing (`decide-tactical` included) can
    talk its way past a standing veto. `ENABLER_ELIGIBLE_JQ`'s `issue-closed`
    timestamp guard reads `$escalation.ts >= $b.ts`, not strictly `>`, because
    this escalation is logged in the very same pass — often the same
    whole-second `log_event` timestamp — as the block it registers, unlike an
    ordinary escalation which is always filed cycles after its own block.

    The owner then comments their own decision on the log issue and closes it
    again: the very next cycle reads the issue closed and, through that same
    `issue-closed` branch, the item is eligible immediately — no
    coordinator-cycle threshold to wait out. `DECISIONS_MAP_JQ` drops a
    `decision-taken` entry once a later `decision-vetoed` event names the same
    item, exactly as it already drops one superseded by a refinement, so the
    next Refiner engagement is never handed the vetoed decision as though it
    still stood. What carries the owner's answer forward is the block itself:
    its `detail` names the veto and its `unblock_condition` names the owner's
    own comment on the log issue as the decision of record, so the Enabler
    engagement the `issue-closed` reason hands the item to, and the Refiner
    engagement it leads to, are pointed at that comment the same way they
    would be pointed at an answer on an ordinary closed escalation.

    **Where the owner sees them.** The dashboard's **Decisions** panel
    (`docs/spec/dashboard/README.md`) — last 7 days, per repository: item, decision,
    taken-at, log-issue link, a `vetoed`/`stands` status — sourced from the
    fleet log the same way every other panel is. `agent-cycle.sh --status`
    carries a `decisions:` line counting `decision-taken` events in the last
    24 h (`decisions_status_report`, `lib/manage.sh`), read from the fleet
    union through the tolerant event stream requirement 2.1's reduction
    reads (`union_events`), so an unparseable line costs that line only. A
    union that could not be built (requirement 2.5), or a read that fails
    outright, prints `decisions: unreadable — the fleet log could not be
    read` and reports a `guard-degraded` warning on stderr, never a zero.
