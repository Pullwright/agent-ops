## Requirements

### Logging and state — requirements, continued (part 2 of 2; 34i–34n: A block whose work is gone is cleared without asking anyone…)

34i. **A block whose work is gone is cleared without asking anyone.** The
    common way a block ends is not that the impediment lifts — it is that
    somebody finishes the work: the issue is closed, the pull request merged,
    the register entry flipped to `resolved`. None of that emits an event, and
    both readers requirement 34 relies on are blind to it in the same place. The
    Co-Ordinator never revisits the item, because a finished item is offered by
    no source and so never reaches its candidates; the Enabler does, but only
    after `enabler_recheck_hours`, and it pays a full engagement to learn what
    one read of state the cycle already holds would have said. Until then the
    item is reported as blocked, and the count an operator reads at a glance
    says the pipeline is stuck on work that is done.

    So, in the same pre-extract window as requirements 34f and 34g, and against
    the *open* blocked set (34h — a void item needs no unblocking), the Script
    answers one question per item class and logs `unblocked` with
    `by: "work-gone"` and a `detail` naming the fact that decided it:

    - **an issue** (a bare number) — the number is not in that repo's open-issue
      digest (requirement 3b — paged to completion, precisely because this
      test reads absence as closed);
    - **a pull request** (`pr-<n>-abandoned-…`, `-conflict-…`, `-superseded-…`,
      `-review-…` — `WORK_GONE_PR_RE` reads the number off any `pr-<n>-…` shape,
      which is what keeps this rule indifferent to which source minted it) —
      the number is not in that repo's open-PR digest;
    - **a register item** (`TD<date><nn>` or `TD-<scope>-<date><nn>`) — the
      item's own file on the default branch says `status: resolved` or
      `status: not-debt`, read by `scripts/gather-register-status.sh` for the
      blocked ids and no others, so a fleet with no blocked register items pays
      nothing and the read is bounded by the backlog rather than the register.
      It sits above the no-op skip of requirement 3b, like the rest of this
      window, so an item that stays *genuinely* blocked does cost a listing and
      a file read every cycle. Deciding whether to reconcile only after deciding
      whether to run is the cycle-late failure 34f and 34g are placed here to
      avoid, and two reads is a small price beside the Enabler engagements that
      item is already earning;
    - **a project-review recommendation** (`review-<date>-R-NN`) — a *merged*
      pull request on the default branch names that ref, read by
      `scripts/gather-review-status.sh` for the blocked refs and no others,
      against the repo's 100 most-recently-closed pull requests. This is the
      same test requirement 16 already applies when deciding whether to offer
      the recommendation as a candidate at all — the review folder is a
      point-in-time record no stage ever edits to say a recommendation is
      done (requirement 25), so the merged PR's own text naming the ref, put
      there by the Implementer that closed the recommendation out, is the one
      fact anywhere that answers "is this done?", and this reads it instead of
      asking a Co-Ordinator to notice it went stale;
    - **an implementation-plan task** (e.g. `W10-breach-handling`) — the
      task's own checkbox, in the repo's `implementation_plan_path` document
      on the default branch, is checked (`- [x]`), read by
      `scripts/gather-plan-status.sh` for the blocked ids and no others. This
      is certain only when exactly one task-list line in the document names
      the id as a whole word; two such lines, or none, decide nothing.

    Four properties make this safe enough to run unattended:

    - **Unknown is never gone.** A repo missing from the digest, a digest
      carrying `ok: false`, an id no register file claims by `id` or
      `legacy-id`, a review ref no merged pull request's title or body names, a
      plan id no task-list line names (or that two of them do), all decide
      nothing and leave the item blocked. The failure is a delayed clearance,
      which costs a cycle; the other direction clears a block out from under
      work that is still real, which costs a cycle an hour until someone
      notices.
    - **A renamed repo's digest is still found.** For the issue and
      pull-request classes above only, the block's `repo` is resolved through
      `config_repo_slug_aliases`' `{old_slug: current_slug}` map (built from
      every configured repo's own `previous_slugs`, agent-ops#2064) before the
      digest lookup, since SOURCE_STATES_JSON is always keyed by a repo's
      *current* configured `slug` — without this, a block recorded under a
      slug the repository no longer has would read exactly like "a repo
      missing from the digest" above, forever rather than merely until the
      recheck window. The register/review/plan status maps are looked up by
      the block's own `repo` unresolved, since each is already keyed by
      whatever repo its own blocked-id grouping was given, not by this
      digest.
    - **The findings sources are excluded, and that is not an oversight.**
      `gather-findings.sh` degrades to `[]` on an API error by design
      (requirement 3), because a Co-Ordinator that sees no findings declines and
      the two agree. Read as a clearing signal the same `[]` says "every alert
      is fixed", so one 403 would clear every alert block on the fleet. A
      human-visibility
      item (`human-visibility-<hash>` — requirement 38e) is excluded for the
      plainer reason that it has no completion signal to read at all —
      GitHub's own live pull-request state *is* the item,
      and its own re-derivation is what
      `gather-human-visibility-hygiene.sh` itself repairs. It remains the
      Enabler's, exactly as before.
    - **It clears, it never voids.** The event is `unblocked`, which requirement
      34 calls the safe direction — a wrongly cleared item becomes a candidate
      again, is offered by no source, and nothing happens. A void is terminal
      (34c) and must be corroborated (34d), and neither is what a deterministic
      tidy-up has earned.

    The rule has one implementation, `work_gone_clearances` in
    `lib/work-gone.sh`, which is pure: it decides from the blocked set, the
    digests and the three side-channel status maps (register, review, plan) it
    is handed, and reads nothing itself.
34j. **A structured dependency is held, and released, by code — never by a
    model re-reading prose.** `Blocked-by: #195` (same repo) or
    `Blocked-by: owner/repo#195` (a repo this pipeline also walks), one or
    more comma- or whitespace-separated references on their own line in a
    GitHub issue's body or any comment in its thread, names a specific item
    whose live open/closed state — not a narrative account of it — decides
    the block. This exists because prose did not survive being re-judged: a
    note like "hold until #195 is merged" is only ever a description of a
    moment, and the moment it describes can pass without the note changing.
    Four issues (#196–#199) recorded exactly that — the initial re-check
    correctly cleared them within 43 minutes of #195 actually merging, and
    the same stale sentence then re-blocked more than one of them again,
    each false block costing a full Enabler engagement to undo, because the
    only reader of the note was a Co-Ordinator asked to re-examine it
    (requirement 18a) from nothing but the paragraph itself. A reference is
    immune to this by construction: nothing here ever trusts what a
    `Blocked-by:` line asserts happened, only what re-checking the number it
    names says *now* — so a stale line naming an already-closed item is
    inert, not wrong, and never needs to be edited out for the mechanism to
    stay correct (contrast the Enabler's own remedy below, which is about
    the next dependency, not this one).

    Two deterministic mechanisms apply it, both reusing data the cycle
    already holds and asking no model anything:

    - **Holding.** `scripts/gather-issues.sh` drops a candidate whose thread
      names a `Blocked-by:` reference that is not closed — checked live,
      per reference, the moment its whole thread is in hand — the same way
      it already drops an assigned or `blocked`-labelled issue (requirement
      3j). An item newly declaring a dependency therefore never reaches the
      Co-Ordinator and never earns an `attempt-failed`: the dependency holds
      it before the pipeline's own notion of "blocked" is ever written, at
      zero cost beyond the one `gh` read per reference the candidate would
      otherwise have spent a full evaluation on anyway. That holding is as
      recent as the band it filtered only for the `Blocked-by:` reference
      itself: requirement 48 runs this gatherer for one repository per cycle
      per node, so a dependency that a repository's thread gained *after*
      its last turn does not hold its candidate out of that node's digest
      until the repository's next turn comes round — resolving it needs the
      whole thread and a live per-reference check, the expensive work
      requirement 48 exists to skip on a replayed repository's off cycles.
      An assignment or a `blocked` label gained in that same window does not
      wait that long: 3j's own assigned/`blocked`-label drops are re-applied
      to a replayed band too, every cycle, from `gather_source_state`'s own
      already-sampled labels and assignee (`issue_state_reapply`,
      lib/candidate-select.sh), which costs no further GitHub read
      (agent-ops#1095).
    - **Releasing.** Against the *open* blocked set (34h), in the same
      pre-extract window as 34f, 34g and 34i, the Script reshapes this
      cycle's own freshly gathered `issues` candidates to a `repo → item →
      thread` map and clears any blocked issue found there whose thread
      still carries a `Blocked-by:` line: presence in that map, on its own,
      already proves gather-issues.sh's holding check found every reference
      resolved this same cycle, so the release asks no second question of
      GitHub — it reads the holding check's own verdict rather than
      re-deriving one. An item excluded from this cycle's candidates for
      *any* reason — a reference still open, an assignment, the `blocked`
      label, or simply a repo this cycle did not walk — is absent from the
      map and decides nothing, the same "unknown is never gone" rule
      requirement 34i's clearances observe. A repository whose `issues` band
      requirement 48 replayed from this node's expensive-gather cache rather
      than reading fresh counts as one this cycle did not walk, and is
      narrowed out of the map before the reshape: its band carries the
      holding check's verdict from whenever its own last turn was, which is
      not the proof this release reads. Logged `unblocked` with
      `by: "dependency-resolved"` and a `detail` naming the reference(s)
      that resolved.

    The rule has one implementation, `dependency_clearances` in
    `lib/dependency-gate.sh`, alongside the parser, `dependency_refs`, that
    both mechanisms share.

    This binds to GitHub issues only, for the same reason requirement 18a
    does: they are the one blocked-item shape with a thread the cycle
    already reads whole. It does not need requirement 3b's fingerprint
    extended to cover it: a same-repo reference's state is already part of
    that repo's `issues` digest (open issues) or claim signal (open PRs),
    and a cross-repo reference needs its own repo configured and walked
    for the same reason 34i's register/review/plan reads do — so the
    reference resolving always changes the `issues` array gather-issues.sh
    hands the Co-Ordinator (a previously excluded candidate now appears),
    which requirement 3b already fingerprints verbatim, waking the fleet
    within the hour without a dedicated projection.

    A model's part in this is deliberately narrow. Nothing here edits an
    issue's body — an agent rewriting a human's own text is a cost this
    convention does not need paid, since a stale reference is inert rather
    than misleading. The Enabler, examining a blocked or refinement-class
    item and recognising an unstructured dependency note it cannot itself
    act on, may post one comment naming the structured form the pipeline
    can read (requirement 36's existing "one concise comment" power,
    spending nothing new); the comment becomes part of the thread this
    convention already reads, so a human — or the Co-Ordinator, next time it
    is asked to select this item — can adopt it verbatim.
34k. **Act on void: close the GitHub object a void names.** A void
    (requirement 34c) already stops the item being selected again, but
    nothing before this touched the *object* it is about — an obsolete draft
    pull request or a superseded issue stayed open on GitHub, visible to
    every human and to every tool that reads the repository rather than this
    pipeline's own log, and kept being re-derived void by cycle after cycle
    with nothing ever said to it (issue #240; poetic-fiddle #190/#214 were
    re-derived void on 7+ separate cycles and never closed). Void tombstones
    are private state, and the world they describe was never corrected.

    So, in the same pre-extract window as 34f/34g/34i, against `void_json`
    (the full void set — an already-void item needs no unblocking, but it
    still names an object that may need closing), the Script asks
    `scripts/close-void-github-items.sh` to close it, for the two id shapes
    that name a GitHub object at all (the same shapes requirement 34i's own
    work-gone rule reads, from the one definition in `lib/work-gone.sh`):

    - **an issue** (a bare number) — closed, with a comment carrying the
      void's own `detail` (the reason) and `evidence`, iff GitHub still
      reports it open;
    - **a pull request** (`pr-<n>-abandoned-…`, `-review-…`, `-superseded-…`)
      — closed the same way, iff still open.

    **The `-conflict-`, `-dequeued-` and `-landing-refusal-` shapes are
    excluded from the pull-request case
    above.** `pr-<n>-conflict-<head-sha>` names the pull request only to say
    the *conflict* on it resolved — the void is about the conflict, not about
    the pull request, which stays a live, ready PR of ours the moment the
    shape is voided. Closing it here would discard exactly the work
    requirement 34's `merge-conflicts` source exists to protect, and did, for
    real: pull request #264 — the first raising of the branch that became
    #273, carrying a human `CHANGES_REQUESTED` review round — was closed
    unmerged when the unrelated item `pr-264-conflict-…` was voided after its
    conflict resolved, and both the PR and the review round were lost
    (TD-PPagop-26080901). `pr-<n>-dequeued-<head-sha>` (requirement 3z) makes
    the identical shape of claim about a dequeue rather than a conflict — the
    pull request stays live and ready, waiting on the human's own re-queue —
    so it is excluded on the same reasoning (TD-PPagop-26081409).
    `pr-<n>-landing-refusal-<ids>` (requirement 53, issue #979) makes the
    identical shape of claim about a comment-reconciliation refusal instead —
    the pull request stays live and ready, waiting on nothing but the answer
    a landing-refusals Implementer round already gave it — scoped to the
    unreconciled comment ids exactly as `-conflict-`/`-dequeued-` are scoped
    to a head SHA, so it is excluded on the same reasoning. So a void of any
    of the three shapes closes nothing: it is left
    exactly like a void shape that names no GitHub object at all, below. The
    exclusion is decided before the per-call action cap, exactly as the
    `stage` gate below is: these shapes are never actionable on any cycle, so
    they must neither consume one of the three slots nor be counted in the
    overflow the cap reports — a deferred count naming work nothing will ever
    do would have the Script log that warning every cycle in perpetuity,
    since a shape this never closes never earns the `void-object-closed`
    that would retire it under requirement 34n.

    **`pr-<n>-superseded-<head-sha>` is not excluded.** A Dependabot bump a
    newer open bump has made moot (requirement 3s) mints this sibling shape
    instead of `-conflict-`, and its void makes the opposite claim — the pull
    request itself is moot, not merely its conflict — so closing it discards
    nothing (TD-PPagop-26081304). It closes through the ordinary
    pull-request branch above, with requirement 34d's own live corroboration
    (author still Dependabot, a newer open bump of the same family still
    open) standing in the same place #264's empty-diff test does for
    `-abandoned-`/`-review-`. Distinguishing the two shapes at the id, rather
    than reading the void's reason, is what lets this close resume without
    re-admitting the `-conflict-` shape #264 cost this pipeline: the two
    claims never share an id again.

    **Which obsolete pull requests this can actually reach.** The close above
    fires on a *corroborated* void, and requirement 34d corroborates the two
    closing shapes strictly for this reason: a `pr-<n>-abandoned-…` or
    `pr-<n>-review-…` void whose pull request is still open, still changes
    files against its base, and does not carry the human-applied `obsolete`
    label is refused, so an open draft that is obsolete rather than
    already-landed reaches this close only once a human has said so. Absent
    the label, it is escalated to a human instead — the Enabler adjudicates
    through the same guard, refuses it for the same reason, and raises the
    issue. That is the deliberate trade #264 bought: "this draft is no longer
    wanted" is a judgement no API call corroborates on its own, and a
    pipeline that closes live branches on an uncorroborated judgement
    destroys work. The `obsolete` label (TD-PPagop-26081308) is the
    corroborable form of that judgement — applied only by a human, never by a
    pipeline stage — so the leading example above, the obsolete draft that
    stayed open, is reachable by this close once the human who knows it is
    unwanted says so on the pull request itself, alongside the cases the API
    can confirm outright: the pull request already closed, or its diff
    already empty against the base. The close comment names the label whenever
    the closed pull request carries it (`scripts/close-void-github-items.sh`)
    — its presence re-checked live, presence being all the sweep can know —
    so the action stays auditable from the comment alone. And because the
    prohibition on a stage applying the label is only as strong as the names
    the config may take, `scripts/doctor.sh` fails a config that gives any
    configurable label key the name `obsolete`, case-insensitively as the
    guard reads it: `pr_label` alone is projected onto every draft the
    Implementer raises, so one configured name would hand this close every
    live draft at once — the same key-level guard the issue-side label keys
    already carry against `blocked`.

    Every other void shape — a tech-debt register id, a project-review ref,
    an implementation-plan task id — names something that is not a GitHub
    object to close, and requirement 34k does nothing with it; a register id
    is instead requirement 34n's own register-status signal's concern,
    below.

    **Only a corroborated void — the three stage writers, and the delegate
    mandate's own act.** `void_json` holds the unresolved `item-void` events
    of all three stage writers (Co-Ordinator, Enabler, Implementer), and
    requirement 34d's guard corroborates every one of them before it is
    logged (issue #243), so each is eligible here. `stage: "decision"` — the
    void requirement 36f's `corroborate-void` act writes — is eligible too,
    on its own corroboration rather than the guard's: a decision taken under
    the delegate mandate, filed as a closed `pw::decision` issue, and left
    un-reopened for the whole of `decision_veto_window_hours`. That is what
    this close was always waiting for on a `pr-<n>-abandoned-…` or
    `pr-<n>-review-…` draft that still changes files — the judgement, not the
    machinery — so nothing else here changes to admit it: the one-shot rule,
    the action cap, the `-conflict-`/`-dequeued-` exclusion and a human's
    plain re-open each apply to it exactly as to any other corroborated void.
    `void_json` also holds the Script's own pre-flight voids (requirement
    34m), and the `stage` gate below excludes them: a pre-flight void closes
    no GitHub object, so a finishing-source item it voids leaves its pull
    request open for a human, or for a later corroborated void, to close. Each candidate still carries its event's `stage`, and
    `close-void-github-items.sh` still gates on it — an uncorroborated
    `item-void` must never reach this point, but if one somehow did (a future
    writer that bypassed the guard, a malformed or stageless entry), the gate
    is what stops it closing a live issue on an unexamined claim. An
    ineligible void is left exactly as a register id is — unprocessed and
    unmarked, so nothing stops a later pass acting on it once it is
    corroborated. The one-shot rule immediately below is the second,
    independent bound — recovery rather than precondition — and a human's
    plain re-open wins permanently.

    **Acted on at most once, ever — deliberately not tied to the void
    clearing.** `void_object_closed_items` (`lib/cycle-state.sh`) is the set
    of `{repo, item}` pairs a `void-object-closed` event already names; the
    Script excludes them from every future pass, regardless of what happens
    to the object afterwards. This is not the same safety margin as 34d's
    corroboration — it exists because closing is an action with a visible,
    somewhat blunt side effect (a comment on someone's issue), and a human
    who simply reopens the object, without going through the sanctioned
    `unvoid_label` route (34f) that actually clears the void, must not have
    it closed on them again next cycle. `unvoid_label` remains the only way
    to make the *void* itself go away; this only ever runs once regardless.

    Bounded and idempotent: three actions per repo per cycle (the overflow
    reported, never silent, same as every other sweep here), and a `gh` read
    before every close means the worst outcome of two nodes racing is both
    finding nothing left to do. Skipped on `--dry-run`.
34m. **A freshly claimed item gets the same gone-work check, before the
    Implementer runs, not inside it.** 34i clears a *blocked* item's void
    without asking anyone, from digests the cycle already gathered; a
    candidate this cycle just won the claim on has never been blocked, but
    the question — is this item's work already done? — is identical, and
    just as often the answer (TD-PPpfid-26072801: merged and register-flipped
    15 minutes before the review window this fixed opened, then re-selected
    and re-implemented 21 hours later — a full Implementer engagement to
    learn what one `gh` read already sitting in the cycle's own gathered
    state would have said). So, immediately after the claim loop of
    requirement 17a wins and before the workspace clone, the Script runs
    `lib/preflight.sh`'s `preflight_done_reason` against the winning
    candidate alone: `source_states_json` (requirement 3, gathered for every
    repo the cycle walked, well before the claim) answers it for an `issues`
    item (closed) and for a finishing source's item (its pull request closed
    or merged). A register-shaped ref would additionally cost one fresh
    `gather-register-status.sh` read, scoped to the one item, because a
    freshly claimed item was never a member of the blocked set
    `register_status_json` is otherwise scoped to — but no currently-live
    source claims a register-shaped ref (the `tech-debt` band moved to
    `pw::type:tech-debt`-labelled issues, agent-ops#875), so the Script passes
    an empty register map for every source; `gather-register-status.sh` and
    the register map parameter it feeds remain for a repository that has not
    migrated off register-shaped refs, and for `register_status_json`'s own
    blocked-set pass (requirement 34i). Every other source is left
    to the Implementer, exactly as before — this is the three done-signals
    34i already reads deterministically, reused, not a new one invented for
    the occasion.

    One more done-signal runs alongside `preflight_done_reason`, cheap
    enough to cost no clone of its own: **the claimed branch is already
    merged into `default_branch`**
    (`lib/preflight.sh`'s `preflight_branch_merged_reason`): one live
    `gh api repos/<slug>/compare/<default_branch>...<branch>` call —
    `identical` or `behind` means every commit on the branch is already an
    ancestor of `default_branch`, so the draft's work landed some other way
    while it sat. Run only for `review-feedback`, `merge-conflicts`,
    `dequeued`, `landing-refusals` and
    `abandoned-drafts` — the five sources whose branch and pull request
    predate the claim (`lib/preflight.sh`'s
    `preflight_existing_branch_source`) — and never for an ordinary
    `issues`/`tech-debt` claim, whose branch the Script has just created at
    `default_branch`'s own head: comparing it against that same head the
    moment the claim is won would always read `identical` and void every
    ordinary claim on its first tick. Under squash-merge — the configured
    repositories' merge mode — a merged branch reads `diverged`, so this
    signal actually catches only a true merge, a fast-forward, or a branch
    carrying nothing of its own; the narrowing is false-negative-only (a
    missed hit costs an Implementer engagement that discovers the same
    thing, never a wrong void).

    A third done-signal runs alongside the other two, scoped narrower still:
    **the claimed item's own blocking review has already been superseded**
    (`lib/preflight.sh`'s `preflight_review_feedback_reason`, issue #1360).
    `work_gone_clearances`'s PR-shaped clearance answers "is the pull
    request itself closed or merged?" for every `pr-<n>-…` shape alike, a
    `review-feedback` item's `pr-<n>-review-<id>` included — but a review
    round can be answered, and the same reviewer's `CHANGES_REQUESTED`
    superseded by their own later `APPROVED`, with the pull request staying
    open throughout, so that clearance never fires for it. Run only for
    `review-feedback`, the one source whose item names a specific review:
    one live `gh api repos/<slug>/pulls/<n>/reviews` call, recomputing
    "the review currently blocking" via `lib/handoff.sh`'s `handoff_latest_
    positions` — the same call `scripts/gather-review-feedback.sh` makes when
    deciding whether to offer the candidate at all (requirement 34a's one
    shared definition — the same standing-position-per-reviewer rule,
    deliberately called without a bot filter here too, since a bot
    reviewer's own `APPROVED` is exactly the signal that answers its
    `CHANGES_REQUESTED` in the first place) — a hit is the ref's own review
    id no longer matching that recomputed blocking review, whether because
    it now stands answered or because a newer round from another reviewer
    has taken its place. This exists because the Script's own gather can go
    stale between when a round is answered and when the item is dispatched:
    requirement 48's `expensive-gather` cache reads `review_feedback` fresh
    for only one configured repository per cycle, per node, and every other
    repository/node replays its own last-cached raw gather unverified —
    `work_gone_clearances` and requirement 34j's dependency reconciliation
    both already narrow to the repos a cycle read fresh for exactly this
    reason, but a `review-feedback` item is never a member of the *blocked*
    set either narrowing operates over, so neither one ever saw it. This one
    live call, paid once per claim, closes that gap at the point closest to
    the engagement it would otherwise waste, regardless of which cache or
    race produced the stale ref.

    A hit from any of the three done-signals logs `item-void` (stage
    `preflight`) with the reason `work_gone_clearances`,
    `preflight_branch_merged_reason` or `preflight_review_feedback_reason`
    gives, releases the claim (requirement 17a's release rules) and ends the
    cycle — no Implementer engagement spent. None needs a corroboration
    guard of its own (requirement 34d exists to catch a model's fabricated
    citation, and there is no model in this path to fabricate one): the
    evidence is read directly off `gh`/the register file/the cycle's own
    pre-claim digest, the same ground truth requirement 34d's guard checks a
    citation against. And all three are safe to make terminal for the same
    reason the 34i signals are: each fact, once true, stays true — the
    staleness of a pre-claim digest can only delay such a fact's arrival,
    never assert one that later becomes false.

    **An open pull request already carrying the just-claimed branch defers
    the claim instead of voiding it** (`preflight_defer_reason`, agent-ops
    #279) — checked for every item whose id is not a finishing source's own
    `pr-<n>-…` shape (that shape is already answered by
    `work_gone_clearances`), read from the same pre-claim digest's
    `open_prs[].h`. It is the one pre-flight fact that can become false
    again — the pull request it names may close unmerged tomorrow — and its
    usual cause is narrower still: the digest is sampled before the
    Co-Ordinator engagement, and a branch claim is create-only (requirement
    17a), so winning the claim proves the ref did not exist at claim time
    and the digest's pull request is very likely already gone. A void is
    terminal (requirement 34h: never re-selected, never re-examined, cleared
    only by a human) — voiding on a reversible, probably-stale fact would
    retire live items silently, with nothing to prompt the human who alone
    could unvoid them. So a hit logs a `warning` naming the repo, item and
    reason, releases the claim, and ends the cycle: the item is free again
    the next cycle, judged against a fresh digest. The check is nearly
    unreachable by construction (the create-only claim excludes a live PR's
    branch, and `scripts/sweep-orphan-branches.sh` refuses to delete a ref
    with an open pull request) and is kept as defence in depth: it is cheap,
    pure, and the state it names — however it arose — is one this cycle must
    not spend an Implementer on either way.
34n. **A void that is both actioned and old retires from the extract.**
    Requirement 34c's only exit from void is a human's hand-appended
    `unvoided` — deliberately, since nothing else may reason its way out of a
    terminal state — so the *set* nothing ever leaves grows by one entry for
    every item ever voided, forever. On 2026-08-12 it reached 122 entries and
    133,615 bytes, past `MAX_ARG_STRLEN` (131,072 bytes): every node's cycle
    died at `execve` with `Argument list too long`, before the Co-Ordinator
    ever ran, for roughly two hours across the fleet (issue #309). Requirement
    4g's stdin-only delivery is what stops that failure recurring; this is
    what stops the growth that caused it, by retiring an entry once holding
    onto it no longer buys anything.

    An entry retires once it is both:

    - **actioned** — one of seven signals, one per class of void shape, none
      of them a model's judgement:

      - an issue or pull request GitHub itself reports closed
        (`void_object_closed_items`, the set requirement 34k's sweep already
        maintains) — the bare-issue shape and the non-`-conflict-`
        `pr-<n>-…` shapes 34k's sweep itself acts on;
      - a tech-debt register row whose own file on the default branch says
        `status: resolved` or `status: not-debt` — requirement 34i's own
        "the work is gone" statuses, read for the still-unretired void
        register ids (a `TD<date><nn>`/`TD-<scope>-<date><nn>` shape) by a
        further `scripts/gather-register-status.sh` call per repo, alongside
        the one requirement 34i already makes for that repo's blocked ones;
      - **liveness**, for the five shapes the cycle already gathers as
        structured data each cycle (TD-PPagop-26081303, extended by
        TD-PPagop-26081409 and agent-ops#646): a
        `dependabot-alert-<n>`/`code-scanning-alert-<n>`, a `human-visibility-<hash>`, either
        merge-conflicts shape
        (`pr-<n>-conflict-<head-sha>`, which 34k deliberately excludes from its
        own close, and `pr-<n>-superseded-<head-sha>`, which it closes — both
        come from the same gather, so the same absent-from-it test decides
        both, redundantly for the second, which also earns a
        `void-object-closed` once that close lands), a
        `pr-<n>-dequeued-<head-sha>` (requirement 3z, excluded from 34k's own
        close for the same reason the conflict shape is), or a
        `failed-run-<…>` is actioned once its id is (a) absent from this
        cycle's own gather for its source, decided only when that source's
        gather succeeded this cycle, and (b) nothing else — liveness is not
        itself the age test, which the second half of this rule still
        applies uniformly. Age-only retirement for these five shapes was
        considered and rejected: a void whose id is *still being gathered* —
        a still-open alert, a workflow still failing, a PR still conflicted or dequeued — is doing live
        suppression work every cycle, and retiring it on age alone would
        re-expose the item to be rediscovered void all over again, the exact
        rediscovery churn requirement 34k exists to stop. "This cycle's own
        gather" is, for the first four, the same array the Co-Ordinator's
        runtime input already carries for that repo — read from the tee
        files `gather_findings`/
        `gather_merge_conflicts`/`gather_dequeued`/
        `gather_human_visibility_hygiene` already write during the
        repo walk, before
        claim exclusion narrows them (a claimed alert is still an open one),
        so this costs no further `gh` call; "that source's gather succeeded"
        is a `.ok` marker each of those four functions writes *only*
        alongside its tee file — never on its own, since a marker with no
        array beside it reads downstream as "gathered, found nothing", the
        one sentence it exists to stop the cycle saying — and only when that
        read also succeeded: gather-findings.sh's own exit code for the alert
        shape, stderr emptiness for the other two, which never signal failure
        via exit code by design (see their own headers). The
        merge-conflicts shape is the one whose id is minted per occurrence
        rather than per object — a fresh `<head-sha>` mints a fresh id, so no
        two ever coalesce — which makes it the fastest-growing member of
        this class; it needs nothing beyond the ordinary liveness rule, since
        `scripts/gather-merge-conflicts.sh` re-gathers the source on that
        repository's own turn (requirement 48 — every cycle before it, one
        cycle in `repositories` since) and stops yielding the id the moment
        the conflict resolves. The narrowing costs a rotation, never a wrong
        answer: a cycle that replays the band writes no
        `merge-conflicts-<repo>.ok` marker, and the liveness pass reads an
        absent marker as "unsampled", so the void is held to that
        repository's next turn rather than retired on a stale array.

        The `human-visibility-<hash>` shape (agent-ops#646) joins on the same
        rule and needs one thing none of the others do. Its ref is a digest
        of the surviving violations' own `pr_url|detail` pairs, so — unlike
        every `pr-<n>-…` shape — a
        violation set that merely *changes* mints a different ref rather than
        dropping this one, and the void of the superseded ref is dead weight
        from that moment on; the absent-from-this-cycle's-gather test is
        exactly right for it. What differs is the walk. The human-visibility
        band is built only for repos the union-log reduction found a live
        violation for, so a repo whose violations have all cleared — the
        precise state in which its void residue *should* retire — was walked
        by nobody, left no `.ok` marker, and was read as ungathered for ever.
        So the walk additionally covers any repo carrying unretired void
        residue of this shape, bounded the same way requirement 34n's own
        `failed-run` fetch is (usually no repos at all) and free where it
        applies: with no violations handed to it,
        `scripts/gather-human-visibility-hygiene.sh` re-verifies nothing,
        makes no `gh` call, and prints the `[]` that is the definite answer
        the rule was missing. Its marker condition is that printed array
        itself — every failure path in that script leaves stdout empty or
        unparseable — and an unreadable reduction walks no repo at all, since
        `[]` handed to the gatherer on evidence we never read would be the
        one way a marker could assert an emptiness nothing established.
        `failed-run-<…>` is the one shape not read straight off a tee file:
        `scripts/gather-source-state.sh`'s own `workflows` digest names each
        still-failing workflow by id, not by the basename the item id is
        minted from (requirement 19), so `scripts/gather-workflow-basenames.sh`
        maps id to basename, called once per repo that still carries
        unretired `failed-run-` void residue (usually none) — bounded the
        same way the register-status read is;
      - a *merged* pull request, for a project-review ref
        (`review-<date>-R-NN`), or a checked task-list box, for an
        implementation-plan task id — the same on-demand readers requirement
        34i already calls for the blocked set
        (`scripts/gather-review-status.sh`, `scripts/gather-plan-status.sh`),
        called here for the void residue of those two shapes instead, since
        neither is pre-fetched as structured data at all;
      - a project-review ref whose review folder is no longer the
        repository's current one (`by: "review-superseded"`,
        TD-PPagop-26082309) — the residue `review-merged` can never reach,
        because a `review-<date>-R-NN` ref is voided precisely when the work
        was found already done and so no Implementer ran, which means no
        merged pull request ever named it: the signal above is defined for
        exactly the population that never gets voided. A recommendation
        lives in a point-in-time review document, and
        `scripts/gather-project-review.sh` (and the Co-Ordinator's own live
        read) only ever reads the *latest* review folder under the
        repository's own resolved `report_directory` (requirement 3k), so a
        ref minted by a
        superseded folder is never offered again by anything and retiring
        its void costs nothing — the same reasoning `void_config_actioned`'s
        `source-dropped` rule already rests on. `scripts/gather-project-
        review.sh --current-date` reads only that directory's own listing
        (never the recommendation/prompt files) and reports the current folder's own
        date, one call per repo already walked for review-shaped void
        residue: `{"ok": true, "date": "2026-08-10"}` when a folder resolves,
        `{"ok": true, "date": ""}` when the listing succeeds and offers none
        at all (including a clean 404 on that directory's own static prefix —
        a definite
        fact), or `{"ok": false}` for any other failure, which decides
        nothing, the same "unknown is not gone" rule every liveness shape
        above observes. A ref's own embedded date (the `YYYY-MM-DD` between
        `review-` and `-R-`) that disagrees with the repo's current folder's
        date is actioned; one that agrees is not, and a repo the
        `--current-date` read could not resolve actions no ref in it either;
        and
      - **the configuration itself**, for the residue none of the five above
        can reach (`void_config_actioned`, decided on PR #340's review,
        2026-08-13). Liveness decides nothing without the source's own
        successful gather, and a source is gathered only for a repo whose
        `sources` still list it — so a repo that drops `merge-conflicts` (or
        `security`) freezes every void of that shape
        it had already minted, and a repo dropped from `repos` altogether
        freezes every shape but the closed-object one. An entry is actioned
        when its repo is absent from the configured repo set (`by:
        "repo-dropped"`, any shape — nothing in a repo the config does not
        name can be offered by any source), or when its item is shaped like a
        source's own id and that source is absent from the repo's `sources`
        (`by: "source-dropped"`). The shape -> source map is the inverse of
        the repo walk's own gating, one entry per shape — the alert shape
        alone has two, `security` and `code-quality`, because
        `scripts/gather-findings.sh` serves both and either alone keeps its
        voids live. The `source-dropped` half is deliberately confined to the
        shapes whose id *form* names the source that mints them: a bare issue
        number or a `pr-<n>-…` shaped neither `-conflict-` nor `-superseded-`
        is offered by several sources
        (`issues:<band>`, `review-feedback`, `abandoned-drafts`), so no
        inverse exists and no verdict can be read
        off the id — those keep the closed-object signal they already had.
        `human-visibility` was listed among them until agent-ops#646 and is
        not one: it mints exactly one id shape, its own
        `human-visibility-<hash>` ref, so the inverse is as well defined for
        it as for the other mapped shapes and it carries a `source-dropped`
        verdict like them.

        This is **not** a weakening of requirement 34i's "unknown is not
        gone". That rule is about a *failed read*, which is indistinguishable
        from absence; a source missing from `sources` is a definite fact the
        cycle reads locally for free, and the two were conflated only because
        a missing `.ok` marker meant both "the gather failed" and "the gather
        never ran". What a void buys is suppression of a candidate the
        Co-Ordinator would otherwise be offered; an ungathered source offers
        nothing, so the void buys nothing. Nor does the rediscovery-churn
        objection that killed age-only retirement reach it: churn needs the
        item to be re-offered, which needs a human to re-add the source or
        the repo, at which point one rediscovery pass is the correct
        behaviour of a newly-enabled source and is bounded by what is still
        live at that moment. The array read is `all_repos_json`, the
        **unnarrowed** one straight off `cfg_json '.repos'`, and that is
        load-bearing twice over: `repos_json` carries `--repo`'s own filter,
        under which every other repo would read as dropped, and
        `ordered_repos_json`'s `sources` are rewritten by back-pressure
        (requirement 2.2a) down to the four finishing sources, which would
        mint a spurious `source-dropped` for `security`
        on every back-pressured cycle. A `repos` array
        that is empty or unreadable decides nothing rather than retiring the
        whole extract at once. The decision is config-derived and so is only
        as fleet-consistent as the config: a node running a stale image can
        retire on a repo a newer config still names, which costs the same
        bounded rediscovery a wrong retirement always costs, never a
        clearance;

      `lib/void-liveness.sh`'s `void_liveness_actioned` (the four
      structured-gather shapes), `void_review_plan_actioned` (the
      on-demand-reader shapes, plus the review-superseded signal alongside
      them) and `void_config_actioned` (the config residue) are the three
      pure functions this cycle folds into the actioned set alongside
      `void_object_closed_items` and the register-status read, all five
      concatenated before `retire_void_items` ever sees them. A void naming
      no repo (the hand-appended form requirement 34c allows) matches none of
      the seven signals — the config rule skips an empty repo explicitly, and
      `void_review_plan_actioned`'s fourth input skips a repo absent from
      its own map — so it is left, as it always was, for a human to
      retract; and
    - **old** — its `item-void` event's own `ts` is at least
      `void_retire_after_days` old (default 30; `0` disables retirement
      outright).

    A retirement, once decided, is **recorded**: a `void-retired` event per
    entry — `{repo, item, void_ts, by}`, `by` naming the actioned signal
    (`object-closed`, `register-resolved`, `liveness-<shape>`,
    `review-merged`, `review-superseded`, `plan-task-done`, `source-dropped`
    or `repo-dropped`) — a fact rather than a state,
    exactly as requirement 34k's `void-object-closed` is: nothing clears it.
    The next cycle reads the recorded set back (`void_retired_items`,
    `lib/cycle-state.sh`) and subtracts it from the extract
    (`subtract_retired_voids`) the moment `void_items` has produced it —
    before the 34k sweep, the register-status read, and this requirement's own
    evidence-gathering. Two bounds follow that re-deciding retirement from
    scratch each cycle would not give: the per-cycle GitHub cost is
    proportional to the *unretired residue*, never to every void ever filed —
    an id whose retirement is on the log is never asked about again — and the
    extract stays bounded even on a cycle whose register read fails, because
    the subtraction needs nothing but the log. The subtraction is ts-ordered
    like every clearing rule here: a `void-retired` event masks only an
    `item-void` older than itself, so an item voided afresh after its
    retirement re-enters the extract on the new verdict's own terms. On
    `--dry-run` nothing is recorded — the mark is durable state, like the
    34k sweep it mirrors — while the in-memory narrowing still applies, so a
    dry run sees the extract a real cycle would.

    `retire_void_items` (`lib/cycle-state.sh`) is the one implementation,
    called once, immediately after the register-status read
    and before anything downstream reads `void_json`: the Script reassigns
    `void_json` to its answer rather than introducing a second name, so the
    Refiner's candidate filter, the no-op fingerprint and the Co-Ordinator's
    own input all see the bounded set with nothing to remember. Every earlier
    reader this same cycle — the 34k sweep and the register-status read,
    both running against the extract with recorded retirements already
    subtracted, and `unvoid_clearances_json`, which reads `void_items`
    directly and so still reaches a retired-but-void item — needs nothing
    from the narrower set this call produces: 34k's own closed-object gate
    already skips a closed item on its own account, and the register-status
    read has nothing left to do once a row already reads `resolved`/`not-debt`, which
    is a precondition retirement itself requires. (Narrowing before the
    register-status read is
    also what stops a repo whose void register ids have all retired paying a
    register fetch every cycle forever.)

    **This changes what one cycle hands somebody, never what counts as
    void.** Requirement 34c is untouched, and so is every internal reader
    that recomputes void straight off the log instead of calling
    `void_items` — `open_blocked_items` (34h), `enabler_eligible_items`
    (35a), `refinements_map` (3h), and the monitoring dashboard's own void
    table — each its own copy of the shared `LATEST_UNRESOLVED_JQ` rule
    (requirement 34a), unbounded and unaffected. A retired item therefore
    never resurfaces as blocked (open_blocked_items still subtracts it from
    the raw, ever-growing void set) and the dashboard's void count is
    unchanged; only the payload this one cycle goes on to hand the
    Co-Ordinator, the Refiner and the no-op fingerprint shrinks. A retired
    entry's only remaining trace is the `item-void` event itself, still on
    the log forever, and the closed GitHub object or resolved register row
    the retirement rule required before it would act — which is also why a
    human reopening that object later behaves exactly as intended even
    without the `unvoid_label` route of requirement 34f: 34f's own rule binds
    a clearance to "void recorded *before* the label", and a retired void
    has nothing left in the extract for a label to clear — the reopened
    object simply becomes a fresh, ordinary candidate the next time a source
    gathers it, the same outcome a genuine `unvoided` would have produced.

    Fails safe in the direction requirement 34d already established for void
    itself: `void_retire_after_days` of `0`, or unset, disables retirement
    and every entry stays — and takes the register read with it, so an
    installation that has switched retirement off pays nothing for the
    evidence retirement would have needed; an `item-void` event with no
    parseable `ts`, or a malformed `void_json`/actioned set of any kind, is
    never retired. `0` also stops the recorded subtraction: the
    `void-retired` facts stay on the log but stop masking, so the extract
    returns to the full raw set while retirement is off — an operator's kill
    switch if retirement ever misbehaves — and resumes masking, with nothing
    re-queried, when it is switched back on. The
    failure mode this leaves is one more cycle carrying an entry that was
    ready to go — never a void quietly reopened.

    As defence in depth alongside requirement 4g's stdin delivery — which is
    what actually keeps this from reaching `MAX_ARG_STRLEN` again, since
    retirement only bounds the steady state and stdin removed the argv limit
    entirely — the Script logs a `warning` naming the byte size and entry
    count whenever `void_json` is still over 100,000 bytes after retirement:
    a live signal that retirement itself has fallen behind (a burst of new
    voids, `void_retire_after_days` set too high, or 34k failing to
    action items), well before any cap could bite.

