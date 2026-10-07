## Requirements

### The Refiner

39. **Engagement.** From the same cleanup as requirement 35, immediately after
    the Enabler engages (or declines to) — one further call site, not a second
    one, since both run from `cleanup()` inside the lock, after the workspace
    is deleted and before `cycle-end`. A headless invocation (model
    `refiner_model`, `--dangerously-skip-permissions`, timeout
    `timeout_refiner`) logging `stage-start`/`stage-end` with
    `stage: "refiner"` like any other stage, and parsed from its final message
    like any other stage.

    It engages only when **all** of the following hold, and any one of them
    failing is an ordinary, silent non-engagement — the same guard list as
    requirement 35's, with the Enabler's own threshold and escalation-issue
    checks absent, because this stage has neither:
    - this cycle acquired the lock;
    - the gatherers completed, so the candidate set was computed from inputs
      that exist;
    - the cycle is not `--dry-run`; `--once` **does** engage, on the same terms
      as requirement 35's;
    - the cycle's own exit code is 0;
    - no usage limit was detected during this cycle, and a live read of
      `fleet/limit.json` does not stand the fleet down right now;
    - `refiner_model` is set and `prompts/refiner.md` exists;
    - at least one candidate was claimed (requirement 39b).

    Every claimed item goes to **one** invocation, for the same reason
    requirement 35 batches the Enabler's.

39a. **The candidate set and per-source policy.** An item is a Refiner
    candidate iff **all** of:
    1. it appears in this cycle's pre-fetched source arrays — `findings`
       (`security`/`code-quality`), `review_feedback`, `abandoned_drafts`,
       `merge_conflicts`, `dequeued`, `landing_refusals`,
       `issues`, `tech_debt`
       (requirement 3), the same arrays the Co-Ordinator reads, keyed the
       same way (`source`, `ref`), plus `project_review` and
       `implementation_plan`, keyed the same way again but carried only by
       the **Refiner-only** copy of the repos array `agent-cycle.sh` builds
       for this call (`refiner_repos_json`, requirement 3y). Those last two
       are never folded into `ordered_repos_json`: the Co-Ordinator goes on
       reading `reviews/…` and the plan document live, so the Script has one
       reader for them and the model has another, and neither constrains the
       other. `failed-runs` is the one source with no array at all and so the
       one source no policy can make a candidate of;
    2. its source's `refinement_policy` (config) is not `"exempt"` — the
       default for a source the object does not name, and the correct default
       for a source whose items already carry their own specification (a
       merge conflict, a review comment, a security finding names its own
       remediation);
    3. it carries no refinement yet — `refinements_map` (requirement 3h) has
       no entry for it — **or** it does, but `decisions_json` (requirement
       36d) still names a pending decision for it: a `decide-tactical` pass
       never writes a specification of its own, so a refined item it decided
       still owes the Refiner the fresh spec the decision has to become
       (agent-ops#1049). In this second case, when the item is also
       thread-less (no `entry.number`, and no numeric `item` substituting
       for one, requirement 36b) and not `triage_only`, the candidate
       additionally carries that
       prior refinement itself, as a `refinement` field beside `decision` —
       `entry` carries no specification of its own for a thread-less item,
       so without it the Refiner would have nothing to amend and would
       compose a fresh specification instead (agent-ops#1058). A
       thread-backed item never carries this field: its specification is
       already in `entry`'s own comments. Nor does a `triage_only` candidate,
       which can satisfy both this clause and requirement 39g's band-only
       bypass at once (an unbanded, already-refined issue a decide-tactical
       pass decided): 39g is the stronger constraint, since the Refiner may
       not write such an item a second specification at all, so it is handed
       none to amend. The same `decisions_json` entry that makes the item a
       candidate here is also what withholds it from the Co-Ordinator's own
       ranking entirely, for as long as some actor — in practice, a Refiner
       engagement reaching this very candidate — can still lift the
       withholding (requirement 36d, agent-ops#1057): every item satisfying
       this clause already satisfied clause 2 (not `refinement_policy`-exempt)
       to become a candidate at all, so for as long as this clause holds such
       an item a candidate, no Co-Ordinator engagement can have dispatched it
       meanwhile;
    4. it is not blocked (requirement 34), not void (requirement 34c), and not
       held by an ordinary implementation claim (the same `claimed` array the
       Co-Ordinator's own exclusion 3 reads).

    `refiner_candidate_items` (`lib/refinement.sh`) is the one implementation
    (requirement 34a), reusing `open_blocked_items`, `void_items` and
    `refinements_map` rather than re-deriving any of them. Each candidate
    carries the gatherer's own object for the item verbatim — an issue's whole
    thread, a finding's title and severity — so the Refiner can write a
    specification without a second fetch, the same reason the Co-Ordinator is
    handed its own candidates pre-fetched.

    `refinement_policy` is read by the Co-Ordinator too (requirement 17,
    "Per-source refinement policy" in `prompts/coordinator.md`): `"required"`
    excludes an unrefined item from selection outright; `"preferred"` ranks a
    refined item ahead of an equivalent unrefined one without excluding
    either; `"exempt"` leaves selection unaffected. The Refiner's own
    candidate gathering above is what actually produces a `refined` item for
    a `"required"` or `"preferred"` source to benefit from — so setting
    either policy on `failed-runs`, the one source clause 1 excludes, shapes
    the Co-Ordinator's ranking but starves it of anything to rank
    favourably.

    A pending decision's withholding from the Co-Ordinator (clause 3,
    requirement 36d) is a **separate mechanism from `refinement_policy`**, not
    a value of it: it drops the item from the Script's own pre-fetched bands
    before the Co-Ordinator ever ranks anything (`exclude_decision_pending_items`,
    called from `compute_band_eligibility`, `lib/eligibility.sh`), the same
    way requirement 3u's blocked/void exclusion does, rather than shaping how
    the model ranks what it is shown. It reads `refinement_policy` only as a
    **reachability precondition**, never as the value shaping the rank: an
    item whose source clause 2 above resolves `exempt` is withheld from
    Co-Ordinator ranking by nothing here, because such an item is never a
    Refiner candidate either (clause 2), and the only actor that can ever
    supersede a decision is a Refiner engagement reaching the candidate it
    names. Withholding an `exempt`-sourced item here too would make it
    permanently invisible to every automated actor rather than withheld for
    one cycle, which is why clause 2's own exemption is the one case this
    mechanism does not reach — the opposite of binding regardless of policy.
    The same reachability reasoning gates the mechanism a second way, per
    cycle rather than per item: it does not run at all when this installation
    has no Refiner configured (`refiner_model` empty), since with none,
    nothing of any source could ever be restored either.

39b. **Claims and the engagement cap.** Before claiming, the candidate set is
    reduced to at most `refiner_max_per_engagement` items, sorted by
    `(repo, source, item)` — deterministic, so every node in the fleet reduces
    to the same set and they contend on the same claims rather than each
    engaging a different slice of the backlog (`refiner_engagement_set`,
    mirroring requirement 35d's reasoning without a `blocked_ts` to sort by,
    since a Refiner candidate was never blocked). `0` removes the class from
    engagements entirely; candidates simply wait for a later cycle.

    Each surviving candidate takes a per-item file claim through
    `lib/claim.sh`, under the pseudo-slug `refiner` (parallel to the Enabler's
    `enabler`), keyed `<repo>__<source>__<item>` — stable across cycles for
    the same item, unlike the Enabler's block-timestamp-scoped key, because
    there is no block here to re-mint a fresh key from: an item stops being a
    candidate the moment it is refined or blocked, which is what lets a stable
    key never lock out a legitimately fresh occurrence. These claims are
    **never released** on success, on requirement 35c's exact reasoning: the
    claim is what stops the same item being re-claimed next cycle should the
    engagement produce no verdict for it, and `lib/claim.sh gc` sweeping it at
    `claim_ttl_hours` is the only thing that permits a retry. A total
    engagement failure (timeout, non-zero exit, or an unparseable final
    message that survives requirement 9e's salvage) `expire`s every claimed
    item's registry entry instead of leaving the tombstone standing its full
    life, exactly as requirement 37 already does for the Enabler.

39c. **The Refiner's powers.** For each claimed item the Refiner reaches
    exactly one of two verdicts, `refined` or `needs-refinement` (39d) —
    deliberately narrower than the Enabler's four: no escalation, no void, no
    handoff. A `refined` verdict must carry the specification, in the shape
    its source calls for:
    - an **`issues`**-source item: **one** comment on the issue, its URL in
      `comments_posted` — the same carrier and the same reasoning as
      requirement 36b's issue case, since the Co-Ordinator already reads the
      whole thread;
    - **any other source**: `spec`, self-contained markdown, in `refined_spec`
      — there is no thread to write into and no register or object the
      Refiner may edit.

    The Script records `item-refined` (requirement 33) carrying whichever of
    `spec`/`comment_url` the verdict supplied, `by: "refiner"`, and — for an
    `issues`-source item only — projects `refined_label` onto the issue,
    logging an `own-label-action` (requirement 39f) for the add. A `refined`
    verdict carrying neither is recorded as `refiner-examined` with outcome
    `refined-uncorroborated` and **no** `item-refined` is written: the item
    stays exactly as unrefined as it was, and is a candidate again next cycle.

    **`comments_posted[0]` must actually name a comment (TD-PPagop-26082819).**
    An `#issuecomment-<n>` anchor or the REST API comment form
    (`.../issues/comments/<n>`) — `refinement_comment_url_valid`/
    `refinement_comment_url_id` (`lib/refinement.sh`), the one predicate every
    caller in this codebase tests a comment URL's shape against (also
    requirement 17f's `refinement_traceability_fault`,
    `lib/candidate-select.sh`). A bare issue URL — no anchor at all, so it
    cannot point at any comment — is treated exactly as if `comments_posted`
    were empty: no `comment_url` field is extracted, and the verdict falls
    into the `refined-uncorroborated` path above rather than being recorded.
    This closed a live gap (#818, #874): the corroboration bar used to accept
    any non-empty string, so a verdict returning the issue's own URL with no
    anchor at all was recorded as a genuine refinement, and requirement 36b's
    thrash guard then refused every later attempt to write the specification
    the phantom record falsely claimed already existed.

    Reusing `refinement_record_fields` (`lib/refinement.sh`) for the
    extraction — the same function requirement 36b's `unblocked`/refinement
    path already uses — is what keeps the two writers of `item-refined`
    agreeing on its shape without a second implementation to drift from the
    first (requirement 34a); the shape check above lives inside that shared
    function, so both writers reject a phantom `comment_url` identically.

    **A `refined` verdict may be a re-affirmation, not only a fresh
    specification (agent-ops#670 Part 2).** The Refiner may find an item
    already carrying an adequate specification — its own, the Enabler's, or a
    human's — with nothing material changed since, and return `refined`
    citing that existing text rather than writing anything new, posting or
    writing nothing else. For an `issues`-source item this is the thread:
    name the *existing* specification comment's URL in `comments_posted`.
    **For any other source, "an existing specification" is the candidate's
    own gatherer `entry` — the same object `refiner_candidate_items` already
    hands the Refiner verbatim (a tech-debt item's whole file body; a
    finding's title, severity, and any remediation it names) — and it counts
    as one only where the Refiner judges it adequate by the same bar a fresh
    `refined_spec` must meet: something an Implementer could act on
    unassisted** (agent-ops#810, resolving agent-ops#813 option 2). Where it
    meets that bar, re-affirm by reproducing it verbatim in `refined_spec`;
    where it falls short, the ordinary path is unchanged and the Refiner
    writes a fresh specification. Either way the Refiner writes nothing back
    to the register or the underlying object — a non-`issues` item's `entry`
    is read-only input, the same as an issue's thread — so "never write a
    second specification" (below) binds only where adequate re-affirmable
    text already exists, never where the entry falls short of the bar.

    The Script's recording is unchanged either way: `refinement_record_fields`
    requires only that the verdict carry a `comment_url` or `spec`, never that
    either be this cycle's own write, so a re-affirmation is corroborated on
    the same terms as a fresh specification and re-enters `refinements_map`
    (requirement 3h) the same way. This is what closes the item's only path
    back to a block: once re-affirmed, requirement 39a's candidate rule
    excludes it again, exactly as a fresh refinement would.

    Re-affirmation is not available where the Refiner disagrees with the
    existing specification — that is a second opinion against a first, and
    stays a `needs-refinement` decline (39d), escalated rather than settled
    here. **For any source, "a specification already exists" is never by
    itself grounds for `needs-refinement`** — that verdict stays reserved for
    an owner-only decision (36a), information that exists only in someone's
    head, or a premise the Refiner judges wrong or stale; an adequate
    existing specification is `refined` by re-affirmation, not a reason to
    decline. Pass-through re-affirmation of an already-adequate
    human-authored `entry` is intended behaviour, not a defect: refinement's
    product is the adequacy **verdict**, not additional text, and the Refiner
    must not gold-plate an adequate entry — rewriting or elaborating it —
    merely to make refinement look additive.

39d. **The default-first rule (agent-ops#938).** Before reaching for
    `needs-refinement` on the strength of enumerated alternatives alone, the
    Refiner checks whether the item already answers its own question:

    - A `## Default: <fix>` heading (an in-repo tech-debt record body) or
      `default_fix` (a filed record's own field) names the option the filer —
      Approver, Enabler, or a project-review recommendation, per requirements
      36c/42a — would take. The Refiner specifies to it, `refined`, noting in
      the specification which alternatives the filer considered and why the
      default was chosen. Enumerating alternatives is never itself grounds
      for `needs-refinement` once one of them is marked the default.
    - The `pw::owner-decision` label (a filed issue) or an
      `Owner decision: yes` line beside the heading (a record) marks the
      choice as reserved under requirement 36a's boundary — `needs-refinement`,
      naming the decision and its clause in `missing`, exactly as any other
      owner-only item.
    - An item enumerating options with **neither** marker — filed before this
      convention, or by something outside this pipeline, or the
      malformed-verdict fallback `## Default: not stated` (requirements
      36c/42a) — is not automatically `needs-refinement` either: the Refiner
      specifies to the option the item's own text argues for. Where it argues
      for none and the options differ only in mechanics, with no
      operator-visible behaviour change either way, it specifies to the
      smaller one and says so. Only where the options genuinely differ in
      operator-visible behaviour, with no argued preference, does this reach
      `needs-refinement`, naming the fork in `missing` — the `decide-tactical`
      rung (agent-ops#936, requirement 36d) is the backstop for exactly this
      residue.

    **The `needs-refinement` decline.** Where the Refiner cannot write an
    adequate specification — the gap is a decision, a credential, or
    information that exists only in a human's head, or the item's own premise
    looks wrong to it (a `void` it has no power to declare) — it declines with
    `needs-refinement`, carrying `missing` and `evidence` on the same
    discipline as a Co-Ordinator's own `needs_refinement` report. The Script
    records this through `record_needs_refinement_block`, attributed
    `stage: "refiner"` — the identical recorder requirement 34e's
    Co-Ordinator path and requirement 9f's Implementer path use, so the block,
    its label and assignment projections, and its eligibility for the
    Enabler's own threshold (requirement 35a) never differ by which stage
    reported it.

    No second-pass thrash guard is needed here, unlike requirement 36b's for
    the Enabler's `unblocked` verdict on a refinement item: requirement 39a's
    candidate rule already excludes any item `refinements_map` names, so a
    refined item is structurally never offered to the Refiner again until a
    fresher `needs-refinement` block (from the Implementer's escape hatch,
    requirement 9f, or a further decline here) clears it from that map
    (requirement 39a's third clause reads the same `ts` comparison requirement
    9f describes). What such an item is offered back to next is not
    necessarily a second refinement *pass*, though: 39c's re-affirmation lets
    the Refiner say the existing specification still stands, with no new
    writing and no second opinion involved. The guarantee that holds is
    narrower than "no path back without a block" — it is that there is no
    path back to a *disagreeing* second specification that does not first
    pass through a human-actionable block. A re-affirmation is never that: it
    is the same opinion recorded twice, which 39c's corroboration accepts
    without asking a human anything.

39e. **Failure containment.** Whatever happens inside one Refiner engagement,
    this cycle's own exit code — computed before the exit trap ran — is the
    one recorded (the same containment requirement 37 states for the
    Enabler). A verdict for an item this cycle did not claim is discarded with
    a `warning`, never acted on. A claimed item the Refiner's output never
    mentions keeps its claim and is retried once `claim_ttl_hours` lets `gc`
    release it, recorded as a `warning` naming the item rather than silently
    dropped.

39f. **Own-label-action memory, extending requirement 34g.** Every label this
    system adds or removes is recorded as an `own-label-action` event
    (requirement 33): `refinement_label_add`/`_remove`'s callers in
    `agent-cycle.sh` log one alongside every successful call, for both
    `needs_refinement_label` and `refined_label`. `lib/label-marker.sh`'s
    `label_own_actions_map`, `label_filter_own_applications` and
    `label_is_own_application` read it back: a label currently present on an
    issue is explained by this system's own hand, rather than a human's, when
    an `own-label-action` `add` recorded for that repo, item and label falls
    within `LABEL_OWN_SKEW_TOLERANCE_SECONDS` (120s) of GitHub's own record of
    when the label was last applied (`gather-hand-flagged-refinements.sh`'s
    `labelled_at`), in either direction — not only when ours is no later.

    **The comparison tolerates clock skew and log propagation lag
    (agent-ops#526).** A per-repo+item+label `own` record is no longer a
    single latest action; `label_own_actions_map` also carries `adds`, every
    recorded `add`'s own timestamp, because the *latest* recorded action can
    be a `remove` that silently failed while an earlier `add` is still what
    explains the label's presence (#526 cause 2 below). `lib/label-marker.sh`'s
    `own_class` — one jq definition, embedded verbatim in every reader below
    so none of them can drift into disagreeing — classifies each candidate
    into exactly one of three states:

    - **ours**: some recorded `add`'s timestamp falls within
      `LABEL_OWN_SKEW_TOLERANCE_SECONDS` of `labelled_at`, whichever side of
      it falls earlier. This is symmetric where the pre-#526 comparison was
      not: a node whose clock runs *behind* GitHub's stamps its own `ts`
      earlier than the `labelled_at` it caused, which the exact-order test
      read as a human's later touch (#526's own measured skew: 13s ahead on
      one node, 5+s behind on another — the direction that used to fail).
    - **deferred**: no recorded `add` explains the label, but `labelled_at`
      is newer than `LABEL_OWN_GRACE_SECONDS` (1800s) *before the union-log
      snapshot's own horizon* — not wall clock (agent-ops#670). `NOW` for
      this comparison is `lib/label-marker.sh`'s `log_latest_ts`, the newest
      `.ts` across `union_log` — captured once, in `agent-cycle.sh`,
      immediately after `union_log` is materialised and before that cycle
      appends any of its own events into it — passed as the explicit third
      (`label_filter_own_applications`) or fourth
      (`label_own_stale_applications`) argument as `union_log_horizon`; both
      functions still default `NOW` to `date -u` when it is omitted or empty,
      which only the empty-union-log case and the test suite now rely on.
      Measuring against the snapshot's own horizon, rather than wall clock
      read back however much later in the cycle the read-back runs, is what
      makes the grace period mean what its own name says: an
      `own-label-action` a peer node just wrote is not necessarily in this
      node's union log yet — state-sync fetches peer logs on a periodic
      cadence, not synchronously, and #526 measured roughly 12 minutes of
      staleness against a ~6–7 minute fetch cadence — so absence this recent
      does not yet mean a human, and a cycle long enough to run past the
      grace period's own 1800s must not turn that absence into "not-ours" by
      the mere passage of its own wall-clock runtime (#670: agent-ops#597 and
      #598 cycled indefinitely on exactly this). A deferred candidate is
      excluded from *both* directions: not reported as a hand-flag, and not
      offered up for the stale-removal retry below, since it is not proven to
      be this system's own write either. What the horizon is worth stating
      exactly, because it is not the state-sync fetch time: `union_log` is
      `fleet_logs`' union of this node's *own* log and the peers' (`lib/fleet.sh`),
      and this cycle has already logged its `cycle-start` event into its own
      log before the snapshot is taken — so the newest `.ts` across the union
      is this cycle's own start, and only exceeds it where a peer's fetched
      log happens to carry something newer. That is the quantity the grace
      period should be measured against: it removes this cycle's own runtime
      between its start and the read-back — the 36 minutes that made
      agent-ops#598 cycle — while leaving state-sync's own propagation lag
      covered by `LABEL_OWN_GRACE_SECONDS` itself, exactly as #526 sized it.
      The accepted cost is that one cycle's runtime: a genuine human hand-flag
      is recognised by the first cycle that *starts* at least the grace period
      after `labelled_at`, rather than by the first read-back that *runs* that
      long after it.
    - **not-ours**: everything else — the pre-#526 fail-safe default, and
      still the answer for an unreadable log, a malformed argument, or a
      missing `labelled_at`.

    Both constants are env-overridable (`LABEL_OWN_SKEW_TOLERANCE_SECONDS`,
    `LABEL_OWN_GRACE_SECONDS`), the same convention every other pipeline
    timing constant in this codebase follows, so a test can substitute a
    value that reads clearly without touching production behaviour.

    This closes the gap requirement 34g's original design left: a block that
    cleared correctly but whose `needs_refinement_label` *removal* silently
    failed (a rate limit, a permissions blip — `release_refinement_label`
    already tolerates this by design) left the label sitting on an issue with
    no open block, which the next cycle's hand-flag scan read exactly like a
    human asking for one — restarting a block nobody asked for, the RC4
    incident of the 2026-08-07 pipeline-flow review. The Co-Ordinator's
    hand-flag scan now passes the gathered candidates through
    `label_filter_own_applications` before `refinement_hand_flag_new` sees
    them, so a label the read-back attributes to the Script's own last action
    is excluded in addition to the existing "not already blocked" test, rather
    than relying on that test alone to have covered every case a failed
    removal could produce. Only the `new` half is filtered:
    `refinement_hand_flag_cleared` reads the unfiltered list, because it asks
    which issues have *lost* the label and a candidate removed for being the
    Script's own would read there as a label that had gone.

    The scope stays exactly as narrow as requirement 34g's own design note
    requires: this is a stronger *test* for the one read-back that already
    existed (a hand-flagged `needs_refinement_label`), not the wider "any
    label touch reopens or closes a block" mechanism `TECH-DEBT.md`
    TD26072602 declined. `refined_label` carries no hand-applied meaning and
    is never read back at all — `own-label-action` records its writes purely
    for audit and for a future read-back this requirement does not itself
    need, on the same "extend what already exists" discipline the rest of
    this file follows.

    **The read-back also retries the removal it just proved is stale.**
    `lib/label-marker.sh`'s `label_own_stale_applications` takes exactly the
    candidates `own_class` puts in the **ours** state — never **deferred**,
    which is not yet proven to be this system's own write and so must not be
    torn back off the issue by its own writer — and returns those of them
    with no block still open, reading `lib/cycle-state.sh`'s `blocked_items`
    extract for the second test. It shares `own_class` verbatim with
    `label_filter_own_applications` rather than being expressed in terms of
    it, because since #526 the filter's own kept set is not this function's
    plain complement any more (the filter also excludes **deferred**
    candidates) — sharing the one classification is what keeps the two from
    disagreeing about whose hand a label is in. Both tests are load-bearing,
    and the blocked one is what keeps this from undoing requirement 34e: the label
    the Script applies to an item it has just blocked is its own last action
    too, but while that block stands the label is the live projection of it
    onto the issue — the one thing telling a human reading it that the
    pipeline is waiting on them — and not a leftover to clear. Every open
    block disqualifies a candidate, not only a refinement one, the same rule
    `refinement_hand_flag_new` applies to the entries this function does not
    take. After the Co-Ordinator's hand-flag scan filters the `new` half as
    above, `agent-cycle.sh` passes the same gathered candidates, and the
    blocked extract as it stands once this cycle's own new hand-flag blocks
    have been recorded, through `label_own_stale_applications`, and attempts
    `refinement_label_remove` again on each entry returned, logging a fresh
    `own-label-action` (`remove`) on success or a `warning` naming the item on
    a second failure — the same best-effort contract `release_refinement_label`
    already has for its own removal. This runs whenever
    `needs_refinement_label` is configured (guarded only by requirement 12's
    dry-run switch, the same as every other label write), so a stuck label
    left over from an earlier failed removal is cleared on the next cycle that
    finds it with its block gone, rather than sitting on the issue meaning
    nothing until a human removes it by hand.

39g. **Priority triage, a one-way ratchet the Refiner sets and the Script
    alone enforces (D18 WI-11; agent-ops#414).** Every open `issues`-source
    item carries GitHub's own `Priority` `IssueFieldSingleSelect` — the band
    requirement 15e already ranks the Co-Ordinator's walk by — and most of
    the backlog never has it set: `gather-issues.sh`'s `priority` collapses
    "unset", "unreadable" and "explicitly Medium" into the same value
    (deliberately, to agree with the Co-Ordinator's own default), so it
    emits a second field, `priority_set` (boolean), for exactly this duty to
    read — true whenever *any* option is set on the field, even one outside
    the four names `priority` itself recognises (an organisation can add a
    fifth at any time), so an issue banded with such an option reads as
    triaged and never re-enters the triage queue on every pass
    (agent-ops#509). `gather-source-state.sh`'s own digest keeps parsing the
    band identically (requirement 3b) but does not gain `priority_set`:
    nothing downstream of that digest needs it, since `maybe_run_refiner`
    below engages from every cycle's own exit trap unconditionally on the
    no-op fingerprint that digest feeds.

    An `issues` entry with `priority_set: false` is a Refiner candidate
    (requirement 39a) even when `refinements_map` already names it refined
    — the one exception to that exclusion in this whole file — marked
    `triage_only: true` (`refiner_candidate_items`, `lib/refinement.sh`) so
    the Refiner knows not to write a second specification for an item that
    already has one; every other requirement 39a exclusion (policy exempt,
    blocked, void, claimed) still applies unchanged. An entry with no
    `priority_set` key at all — every non-`issues` source, and any `issues`
    entry gathered before this requirement existed — never qualifies.

    A repository this token cannot resolve `Priority` for at all — `ORG_ONLY`
    visibility without organisation membership, or no such field — must never
    keep offering the Refiner `triage_only` candidates it structurally cannot
    band: `issue_priority_apply` would only ever return `field-unresolvable`
    for them, after the model spend is already paid, and because they carry
    no `refinements_map` entry (`triage_only` is precisely the exception that
    lets an already-refined item back in) they re-enter the candidate set
    every cycle with no possible progress. Worse, `refiner_engagement_set`
    caps at `refiner_max_per_engagement` sorted by `(repo, source, item)`
    (requirement 39b), so a single alphabetically-early repository in this
    state can fill the entire engagement set every cycle, starving genuine
    refinement work in every other repository, not merely wasting its own
    slice (issue #511).

    A pre-flight, not a post-hoc latch, guards against this: immediately
    after `refiner_candidate_items` builds this cycle's candidate set, and
    before the engagement cap or any claim, `refiner_filter_unbandable_triage`
    (`lib/refinement.sh`) collects the distinct repositories among this cycle's
    `triage_only` candidates — a cycle with none makes no query at all — and
    resolves each one's `Priority` field via `issue_priority_field_ids`
    (itself process-cached per repository, including its own failure, so this
    call and `issue_priority_apply`'s own later call inside
    `maybe_run_refiner` never resolve the same repository's field twice).
    Every `triage_only` candidate from a repository whose field failed to
    resolve, *or* whose field resolved carrying none of the four band names
    at all (agent-ops#542 — an organisation that renamed every option, e.g.
    to `P0`…`P3`), is dropped via the pure filter
    `refiner_drop_unbandable_triage` (`lib/refinement.sh`, jq-only and
    independently unit-testable) — checked against `issue_priority_options_any`
    (`lib/issue-priority.sh`) on the very `field_json` this call already
    fetched, so telling the two cases apart costs no further GraphQL query. A
    repository missing only *some* of the four names is unaffected by this
    pre-flight — `issue_priority_apply`'s own per-issue fallback
    (agent-ops#534, below) still bands it — since `issue_priority_options_any`
    is true whenever at least one name is present; only a field carrying
    *none* of the four is a terminal case for this pre-flight, on the same
    "can never write any band" terms as a field that fails to resolve at all.
    Every other candidate — `triage_only` or not, from that repository or any
    other — passes through unchanged, and when every contributing
    repository's field resolves with at least one band option, the candidate
    set is returned byte-identical. Exactly one `warning` is logged per
    dropped repository, naming it, how many `triage_only` candidates it
    dropped, and which of the two cases applied — a field-unresolvable
    warning is worded distinctly from a no-bands-at-all one, so a reader can
    tell the two misconfigurations apart — never one per dropped item. The
    pre-flight runs unconditionally whenever this installation has a Refiner
    (`refiner_model` set), including under `--dry-run`: it is a read, and
    skipping it there would make the dry-run fingerprint input (requirement
    3b's own `refiner_candidates_json`) differ from a live cycle's for no
    gain. With `refiner_model` empty the call site skips the pre-flight
    outright — no `issue_priority_field_ids` read, no `refiner:` warning —
    since candidate computation itself is unconditional (requirement 3y) and
    would otherwise pay for a GraphQL read, per cycle, for a stage that never
    engages (issue #567); the fingerprint invariant above holds only for an
    installation that has a Refiner, since one without it never paid this
    cost in the first place. No state persists between cycles — the day field
    visibility, its option names, or organisation membership changes, triage
    resumes on its own with no operator action and nothing to clear — and
    `issue_priority_apply`'s own `field-unresolvable` and `band-option-missing`
    paths and their warnings (below) are unchanged: this pre-flight makes both
    paths rare for `triage_only` items, it does not replace either, and they
    remain the correct behaviour for a field that becomes unreadable, or loses
    every band option, mid-cycle, after this pre-flight already ran — and for
    any non-`triage_only` item, which this pre-flight never inspects at all,
    since `issue_priority_apply` runs for those regardless of band
    availability.

    The Refiner's verdict (`parsed.refined[]`, requirement 39c (The Refiner)) gains an
    optional `priority` field, one of the four band names, independent of
    `verdict` itself: an ordinary item may carry both a specification and a
    band in the same verdict; a `triage_only` item carries `priority` alone
    and no `comments_posted`/`refined_spec` at all — its
    `refined-uncorroborated` degradation (requirement 39c (The Refiner)) does not apply to
    it, since it was never asked for a specification, and its outcome is
    recorded as `triage-only` rather than `refined`; and a `needs-refinement`
    decline may still carry a band. `maybe_run_refiner` applies the priority
    side of a verdict after the refined/needs-refinement switch, entirely
    independent of its outcome: a failed or skipped band write never
    retracts an `item-refined` or `attempt-failed` already recorded, and the
    reverse.

    A `needs-refinement` verdict on a `triage_only` item is refused rather
    than recorded: outcome `triage-only-refused` and a `warning`, no block,
    no `needs_refinement` label, no `blocked`/`blocked:needs-refinement`
    labels. The item is already refined and reached the Refiner only for its
    band, so a block here would hold an
    item that already carries a specification out of selection until a human
    cleared a block nobody asked for — the one way this requirement's own
    candidate rule could cost the pipeline work rather than save it. The band
    side of such a verdict still applies, on the independence stated above.

    The write and its ratchet live in `lib/issue-priority.sh`, never in the
    prompt — a prompt rule is a request, and the Script is the only writer of
    the pipeline's records (the same reasoning `prompts/refiner.md` itself
    states). `issue_priority_field_ids` resolves the field's own id and its
    four option ids live, per repository, via GraphQL introspection
    (`issueFields`) — never hardcoded, since both are per-repository objects
    and the field is `ORG_ONLY` visibility, so a token without organisation
    membership must read "cannot see the field" as failure, not as "nothing
    to band" (the same direction the Priority read already takes, and the
    one that stops a naive implementation from banding the entire backlog
    once field visibility fails). Resolution is cached to a directory
    (`ISSUE_PRIORITY_CACHE_DIR`) rather than an in-process variable, because
    every caller reaches it through a command substitution — a subshell —
    whose own variable writes never reach the parent; a file on disk
    survives that boundary where a shell variable cannot. Removing the
    directory is each sourcing site's own job, through
    `issue_priority_cache_cleanup`, which the library never calls itself:
    `agent-cycle.sh` calls it from its `cleanup()` EXIT trap, after
    `maybe_run_refiner` — the cache's main consumer — and `scripts/doctor.sh`
    calls it from an EXIT trap of its own, armed immediately after the
    library is sourced. `ISSUE_PRIORITY_CACHE_DIR_OWNED` records whether this
    process created the directory itself or the caller supplied its own
    path; ownership is a property of the directory, not of the most recent
    source, so a process that sources the library more than once — a second
    file sourcing it, or a test re-sourcing it — still recognises, on a
    later source, a directory it created on an earlier one, and does not
    read its own output as caller-supplied (`ISSUE_PRIORITY_CACHE_DIR_OWNED_PATHS`,
    an array, records every path this file created for itself in this
    process — a process that repoints `ISSUE_PRIORITY_CACHE_DIR` and
    re-sources, or unsets it and re-sources, can make the library create more
    than one directory in a single run, and the array tracks all of them
    rather than only the most recent (TD-PPagop-26082202) — and is what a
    re-source compares `ISSUE_PRIORITY_CACHE_DIR` against; agent-ops#541). The
    record is trusted only from the process that created it:
    `ISSUE_PRIORITY_CACHE_DIR_OWNER_PID` stamps that process's own `$$`,
    and a re-source compares it against the current `$$` before treating an
    inherited `ISSUE_PRIORITY_CACHE_DIR_OWNED=1` as its own — an exported
    record a child process merely inherited, with a different `$$`, is
    never trusted, so that child never `rm -rf`s a directory it did not
    create (agent-ops#552). The same check governs how the source-time branch
    that creates a fresh directory populates the array: it appends only when
    `ISSUE_PRIORITY_CACHE_DIR_OWNER_PID` already matches this process's own
    `$$` (a genuine same-process re-source extending its own history);
    otherwise it resets the array to hold only the directory just created.
    Bash cannot export an array, so a parent process that exports
    `ISSUE_PRIORITY_CACHE_DIR_OWNED_PATHS` necessarily exports it as a plain
    scalar — and appending onto that inherited scalar would silently upgrade
    it into element 0 of the child's own array, folding a foreign path into a
    record `issue_priority_cache_cleanup` later trusts as its own to
    `rm -rf`, reopening agent-ops#552 against the array form specifically.
    A same-process record is
    additionally trusted only while the directory it names still exists:
    `issue_priority_cache_cleanup`'s own record-clearing does not reach a
    caller that invokes it through a command substitution, so a source-time
    check independent of that clearing treats a same-process record naming a
    missing directory as "create a fresh one", never as "still ours"
    (agent-ops#552). `issue_priority_cache_cleanup` removes every
    directory this process created — keyed on the owned paths themselves, not
    on whatever `ISSUE_PRIORITY_CACHE_DIR` currently names, so a directory
    this file made is still found and removed even after a caller has since
    repointed `ISSUE_PRIORITY_CACHE_DIR` at its own path (agent-ops#552) —
    leaving a caller-supplied one for that caller to manage, and is
    idempotent — a no-op, returning 0, when called again or when no
    directory was ever created. A cache write that fails — the directory
    `ISSUE_PRIORITY_CACHE_DIR` names gone, or never writable — is silent:
    each of `issue_priority_field_ids`'s three writes redirects stderr
    before it opens the cache file, since redirections are applied left to
    right and the shell's own `No such file or directory` would otherwise
    reach a cycle's stderr ahead of a suppression written after it
    (agent-ops#552); the resolution the write could not cache is still
    returned to the caller, uncached. `issue_priority_apply` then re-reads
    the issue's current band immediately before writing
    (`issue_priority_current`) — unlike `gather-issues.sh` and
    `gather-source-state.sh`, whose REST `issue_field_values` parse both
    collapse anything outside the four names to their Medium default,
    `issue_priority_current` reads the raw option name whatever it is, so the
    ratchet itself can tell "no band" (safe to write) apart from "a band it
    cannot rank" (must not overwrite). A band a human — or another engagement
    — set between this cycle's pre-fetch and this write is honoured, never
    clobbered by a stale read, and the verdict's band is applied via the
    GraphQL `setIssueFieldValue` mutation only when the issue currently
    carries no band or the verdict's band strictly outranks it
    (`Urgent > High > Medium > Low`); an equal or lower band is skipped, not
    written — and so is a band outside those four names, however clearly the
    verdict's own band would otherwise outrank it: an organisation-added
    option (agent-ops#509) has no rank this ratchet can compare against, and
    treating "cannot rank" as "unset" would let this duty silently overwrite
    a band a human just set, the one thing requirement 39g exists to prevent.

    A repository whose `Priority` field resolves but is missing one or more
    of the four band options (agent-ops#534 — the narrower complement to a
    field that cannot be resolved at all, agent-ops#511/#528) does not fail
    the write outright: `issue_priority_apply` falls back to the nearest band
    the field actually has an option for, via `issue_priority_fallback_band`,
    before applying the ratchet — the nearest *lower* band first, since that
    never overstates the issue's priority, tying upward to the nearest
    *higher* band only when no lower option exists at all (the verdict's own
    band was already `Low`, or every lower band is missing too; Enabler
    refinement on agent-ops#534). The ratchet above then runs against this
    fallback band exactly as it would against the verdict's own, so an
    issue that already carries a band is still never overwritten by one that
    does not outrank it, and a lower-or-equal fallback is still skipped, not
    applied. Only a field carrying *none* of the four names at all — nothing
    to fall back to either — reports `band-option-missing` and applies
    nothing, a reason distinct from `field-unresolvable` because a caller
    must be able to tell "the field itself cannot be read" apart from "the
    field has no such option". The four results that reach the ratchet — the
    successful write, either skip, and a failed mutation — gain an optional
    `requested` field, present whenever the band actually written or skipped
    differs from the band the verdict asked for, so a fallback is always
    visible in the record rather than looking like an ordinary write of the
    requested band. The results that fail before the ratchet carry no
    `requested`: a bad argument is rejected before any band is chosen, and
    `field-unresolvable`, `band-option-missing` and `issue-unreadable` — the
    last of which *is* reached after a fallback band has been picked — are
    each logged as a `warning` that names the verdict's own band already.

    Every outcome is logged: `issue-prioritised` `{repo, item, priority,
    previous, by: "refiner"}` — plus `requested` when a fallback band was
    used — on a successful write, `issue-prioritised-skipped` with the same
    shape both when the ratchet declines a band that does not outrank the
    current one and when the current band cannot be ranked at all, and a
    `warning` when the field cannot be resolved, no band on it is writable
    at all, the issue cannot be read, or the mutation itself fails — never a
    `warning` for either ordinary skip, which is the ratchet working as
    designed rather than a failure. The warning always names the repo and
    item, but which band(s) it names depends on which of the four failures
    it is: `field-unresolvable` and `band-option-missing` are rejected
    before any band is chosen, and `issue-unreadable` — though reached
    after a fallback band has been picked — still never attempted a write,
    so each names only the verdict's own band, the one thing there is to
    name. `mutation-failed` is the one reason that can follow an actual,
    possibly different, attempted write: when its result carries no
    `requested` (no fallback ran) the warning is unchanged, naming that one
    band; when it does carry `requested`, the warning names both the band
    the failed mutation actually targeted and the band the verdict asked
    for, since naming the requested band alone would blame a write that was
    never attempted (agent-ops#551). `mutation-failed` additionally carries
    an `error` key — the first line of the `setIssueFieldValue` mutation's
    own stderr, captured rather than discarded — and the warning appends it
    when non-empty (agent-ops#960): before this, a one-token schema mismatch
    (`$optionId` declared `String!` against an `ID` argument) rejected every
    Priority write fleet-wide for three days with nothing in the logs beyond
    a bare `mutation-failed` to diagnose it from.

    `scripts/doctor.sh` warns, for every configured repository whose
    `sources` lists any of the four `issues:<band>` tokens, when its
    `Priority` field cannot be resolved at all, or resolves without one of
    the four expected option names — the one thing that would otherwise tell
    an operator this duty is silently doing nothing in that repository (the
    same shape as the existing per-repository label warnings). The gate is
    the same `startswith("issues")` prefix test the cycle's own gather uses
    (requirement 15e): the issues source is one source at four ranks and
    `sources` never carries the bare name, so an equality test against it
    would match no valid configuration and the check would never run.

39h. **May name labels for the item behind its verdict (requirement 6c, issue
    #714).** A verdict entry's optional `labels` field
    (`[{name, colour?, description?}, …]`), independent of `verdict` itself —
    an ordinary `refined` item, a `needs-refinement` decline, or a
    `triage_only` band-only verdict may all carry one, on the same
    independence-from-outcome terms `priority` above already has. Only an
    issue-backed item (`e_number` set, the same carrier test requirement 39c
    uses for `refined_spec` vs. a comment pointer) has anything to apply it
    to; a threadless item's own `labels` is silently unusable, the same as an
    unbanded non-`issues` item's `priority`.

    `_refiner_apply_labels` (`lib/refinement.sh`) is this verdict field's own
    consumer, `_refiner_apply_verdicts`'s per-engagement counterpart to
    `_refiner_apply_priority`. Requirement 6c's per-*item* cap of 3 is
    `labels_mint`'s own; the per-*engagement* cap of 10 is enforced here,
    because only the Refiner processes more than one item per engagement — a
    `local` (`_refiner_labels_engagement_remaining`) `_refiner_apply_verdicts`
    declares once before its verdict loop starts and threads by name through
    `_refiner_process_one_verdict` to `_refiner_apply_labels`, which binds it
    with a `local -n` nameref and updates it in place — the pool's name is an
    explicit parameter of both functions rather than a dynamic-scope read
    (agent-ops#1276) — shared across every item the engagement claims rather
    than reset per item. Once the pool is spent, a further item's own
    suggestions are refused `engagement-cap` — a `labels-minted` event still
    fires for it, `refused` naming every entry that reason,
    `created`/`applied` both empty — without a `labels_mint` call even being
    attempted, since a call given a zero-or-negative cap could only ever
    refuse everything it was handed.

