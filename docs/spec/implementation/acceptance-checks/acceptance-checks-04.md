## Acceptance checks

### Acceptance checks — continued (part 4 of 6; items 39a–8s)

39a. **The Refiner's candidate set is correctly bounded (requirements 39a,
    39b).** `test/refiner-eligibility.test.sh` passes: `refiner_candidate_items`
    includes a pre-fetched item only when its source is not
    `refinement_policy`-exempt, excludes one `refinements_map` already names,
    one that is blocked, one that is void, and one that is claimed; a source
    absent from `refinement_policy` is treated as exempt; a `tech_debt` entry
    is a candidate under the same rule as every other pre-fetched source, so a
    `refinement_policy["tech-debt"]` of `"required"` or `"preferred"` reaches
    an engagement rather than shaping only the Co-Ordinator's ranking; a
    `project_review` and an `implementation_plan` entry each do the same under
    that same rule, and a policy set for either finds nothing to gather when
    the repos array does not carry the array (the ordinary shape of
    `ordered_repos_json`, which never gains one — requirement 3y);
    `refiner_engagement_set` caps the result deterministically by
    `(repo, source, item)` and treats an unreadable `MAX` as `0`.
    `test/enabler-verdicts.test.sh` covers requirement 39a (The Refiner)'s third clause's
    other bypass of the already-refined exclusion, the one `triage_only` is
    not: driving `maybe_run_enabler` to a `decide` verdict on a register
    record that already carried a refinement, the resulting `decision-taken`
    and `item-refined` events are replayed as a log in the order and with the
    gap `lib/enabler.sh` writes them in, `decisions_map` still names the
    decision after that re-record, and `refiner_candidate_items` still offers
    the item — carrying `decision`, and carrying no `triage_only`, since this
    candidate owes a whole specification rather than one field
    (agent-ops#1049). The same file covers that decision's other half
    (requirement 36d, agent-ops#1057) against the *real* call sequence rather
    than the two functions in isolation: with `refiner_model` set and a
    `tech-debt` policy of `"required"` (not exempt), driving
    `compute_band_eligibility` and then `prefetch_refiner_sources`, sourced
    whole and run back to back in the order `lib/gather-phase.sh` calls them,
    over one shared `ordered_repos_json`, the decided item leaves that
    aggregate's own `tech_debt` band — so no Co-Ordinator engagement can rank
    it — while `refiner_candidate_items`, fed the resulting
    `refiner_repos_json`, still offers it carrying the same pending decision.
    Both halves are asserted together over the one aggregate because either
    alone is the bug: asserting them against separately-constructed inputs
    leaves a `refiner_repos_json` derived from the post-withholding aggregate
    undetected, withholding the item from the Refiner too and so from the
    only actor whose `item-refined` could ever free it (requirement 3y). A
    second real-sequence case, over the identical pair of calls, proves the
    reachability gate at the other end: a decision-pending candidate from a
    band whose source `refinement_policy` leaves `exempt` (the installation's
    default for every source but `issues` and `tech-debt`) is **not** withheld
    from `ordered_repos_json` — since `refiner_candidate_items` would never
    have offered it to the Refiner either way, withholding it from the
    Co-Ordinator too would leave it permanently unreachable, the second defect
    the Reviewer and the Enabler confirmed on PR #2047. A third drives the
    same pair with `refiner_model` empty and the same `tech-debt: required`
    policy: the pass does not run at all, so the decided item is **not**
    withheld — with no Refiner configured, nothing could ever supersede the
    decision regardless of policy, so no cycle limit on the withholding could
    ever be realised.
3y. **The two Refiner-only gatherers read what requirement 3y says
    (requirement 3y).** `test/gather-project-review.test.sh` and
    `test/gather-implementation-plan.test.sh` pass, each driving its script
    against a stubbed `gh`: the review gatherer reads only the latest dated
    folder, mints `review-<date>-R-NN` refs, carries each recommendation's own
    section and its matching improvement prompt — whole, including a nested
    code block of the prompt's own and the fence lines around it — and prints
    `[]` for a repo with no `reviews/` tree; `--current-date` reports the
    latest folder's own date, distinguishes a listing that offers no folder
    (and a clean 404) as `{"ok": true, "date": ""}` from an API failure as
    `{"ok": false}`, counts a failed *second* listing — the library walk's own
    call, which degrades to the same silence an unmatched listing produces —
    among the failures rather than the definite emptiness that would retire
    every review ref in the repository, and leaves the default mode's `[]`
    unchanged for both; the plan gatherer returns open
    tasks in document order, skips checked ones and lines whose leading token
    is not a `WORK_GONE_PLAN_RE` id, and prints `[]` for a missing document.
    Neither ever exits non-zero.
39c. **The Refiner's verdicts are recorded as stated, driving the real switch
    (requirements 39c, 39d, 39e).** `test/refiner-verdicts.test.sh` passes:
    driving `maybe_run_refiner` itself — lifted verbatim from
    `lib/refinement.sh`, the file that now carries it — a `refined` verdict on an
    `issues`-source item carrying `comments_posted` produces exactly one
    `item-refined` with `by: "refiner"` and the `comment_url`, plus the
    `refined_label` add logged as an `own-label-action`; a non-issue item's
    `refined` verdict carrying `refined_spec` records the spec itself, with
    no `comment_url` and no label write. The degradation is asserted from
    both of its directions: an `issues` verdict with no comment — including a
    `comments_posted[0]` that is a bare issue URL naming no comment at all,
    or an array rather than a string, both treated identically to an empty
    one by `refinement_record_fields`'s own shared shape check
    (TD-PPagop-26082819, TD-PPagop-26082603; pinned directly in
    `test/needs-refinement.test.sh`, since the shape check is the shared
    function's own, not `maybe_run_refiner`'s) — and a
    non-issue verdict whose payload names `spec` instead of `refined_spec` —
    the exact field-name mismatch between `prompts/refiner.md` and
    `refinement_record_fields` that PR #283's review caught by hand — earn a
    `warning` and a `refiner-examined` with outcome `refined-uncorroborated`
    and **no** `item-refined`, and the shipped prompt is asserted to name
    `refined_spec` (never a bare `spec` field), so the prompt and the
    consumer cannot silently drift apart again. A `needs-refinement` decline
    is recorded through `record_needs_refinement_block` as an
    `attempt-failed` attributed `stage: "refiner"` carrying the label and
    assignee projections, while a decline with `missing` empty and one for
    an item already blocked are refused (`recorded: 0`) with a `warning` and
    no second block; an unrecognised verdict earns a `warning` and outcome
    `unknown-verdict`, acted on in no way. Re-affirmation (39c) is pinned from
    the same corroboration path: a `refined` verdict citing a comment URL
    that is not this cycle's own write — nothing distinguishes one in the
    payload the Script reads — is recorded exactly like a fresh comment's
    URL, `item-refined` and the `refined_label` add both included, proving
    the Script never demands the comment be freshly posted (agent-ops#670
    Part 2). Requirement 39e's containment:
    a verdict for an item the cycle never claimed is discarded with a
    `warning` and no `refiner-examined` at all, a claimed item the envelope
    never mentions is warned about by name and left claimed, and an
    engagement that exits non-zero or returns an unparseable final message
    (its salvage resume also failing) records no verdict events at all,
    expires every claim, and still returns 0.
39f. **Own-label-action memory stops a failed removal reopening a block, and
    tolerates clock skew and log propagation lag (requirement 39f;
    agent-ops#526).** `test/label-marker.test.sh` passes:
    `label_own_actions_map` reduces to the latest action per repo+item+label
    plus `adds`, every recorded `add`'s own timestamp; `label_is_own_application`
    reads true only when `own_class` classifies the candidate **ours** —
    some recorded `add` within `LABEL_OWN_SKEW_TOLERANCE_SECONDS` of
    `labelled_at`, in either direction, even when a later `remove` was also
    recorded — and false for both **not-ours** (a human's later application,
    an empty own record, or an empty `labelled_at`) and **deferred**
    (`labelled_at` newer than `LABEL_OWN_GRACE_SECONDS` ago with no own
    record yet); `label_filter_own_applications` drops exactly the **ours**
    and **deferred** candidates from a gathered list, preserving the rest
    verbatim, and drops none when the own map is empty or malformed.
    `label_own_stale_applications` given no open blocks returns exactly the
    **ours** set (never **deferred**, and never the same entries
    `label_filter_own_applications` still reports as a hand-flag) — and given
    a blocked extract returns nothing for an item with a block still open, of
    any kind, in that same repo; it has nothing to retry when the own map is
    empty or malformed, or when the blocked extract is malformed, the safe
    direction for a write. Three fixtures pin the cases #526 found the
    pre-existing exact-order comparison missing: an `own.ts` recorded a few
    seconds *behind* `labelled_at` (within tolerance) is still ours, an
    `add` matching `labelled_at` followed by a later recorded `remove` is
    still ours, and a label with no own record at all but `labelled_at`
    inside the grace window is deferred — reported neither as a hand-flag
    nor offered for stale removal — while the identical case past the grace
    window still earns the pre-#526 hand-flag treatment (requirement 34g
    unchanged). `test/needs-refinement.test.sh` passes cases built on the call
    site's own composition of the two: a hand-flag scan that finds the label
    still present after a simulated removal failure, with the own-action log
    showing the Script's own `add` and nothing since, does not manufacture a
    fresh block, and that same candidate is exactly what
    `label_own_stale_applications` hands back for `refinement_label_remove`
    to retry once no block stands behind it — while a label a human applied
    after the Script's last action, one whose removal was recorded as having
    succeeded, and one whose own block is still open, all earn their existing
    treatment and none is ever handed back to retry. A fourth fixture pins
    the deferred case at the call site: a candidate labelled inside the grace
    window with no own record earns no fresh block and is not offered back
    for a stale-removal retry either.

    **`log_latest_ts` and the snapshot horizon (agent-ops#670).**
    `test/label-marker.test.sh` also passes: `log_latest_ts` prints the
    newest `.ts` across a mixed log stream, skips a line that fails to
    parse rather than failing on it, and prints nothing for an empty,
    missing, or unreadable stream. A replay of the agent-ops#598 trace pins
    the fix directly: an own-actions map without the peer's record,
    `labelled_at` `2026-08-21T07:41:25Z`, `NOW` fixed at the snapshot
    horizon `2026-08-21T07:36:00Z` — *before* `labelled_at`, exactly the
    negative-age case a snapshot taken earlier in the cycle than a peer's
    later write produces — classifies **deferred**, not **not-ours**; the
    same candidate with `NOW` fixed at `2026-08-21T08:12:36Z` (wall clock at
    the moment the read-back actually ran in that incident) reproduces the
    pre-fix **not-ours** misattribution, pinning the regression the fix
    closes rather than only the fix itself. A negative `labelled_at` age
    (label applied after `NOW`) always classifies **deferred**, never
    **not-ours**, pinned so an `abs()` "simplification" of `own_class`'s
    `($now_epoch - $at_epoch) < $grace` test cannot silently regress it.
    `label_own_stale_applications` given the same fixed horizon excludes a
    candidate whose `labelled_at` falls after it from the stale-removal set,
    the other half of the same fix. The call-site wiring in `agent-cycle.sh`
    is pinned separately, by `test/label-marker-horizon-wiring.test.sh`:
    `union_log_horizon` is assigned after the `fleet_logs` snapshot that
    materialises `union_log` and textually before the first `>> "$union_log"`
    append later in the cycle, nothing repairs the snapshot or otherwise
    touches it in between (a repair's `log-repaired` record, stamped with
    wall-clock time, once set the horizon on every cycle while a peer copy
    stayed damaged), and both read-back calls
    (`label_filter_own_applications`, `label_own_stale_applications`) are
    handed it rather than falling back to the `date -u` default. That file
    asserts against the text of `agent-cycle.sh` rather than against a block
    lifted out of it, because the capture's *position* is the thing under
    test and lifting the block would lift the ordering with it. Every fixture
    above stays green through either break — they drive
    `label_filter_own_applications`/`label_own_stale_applications` directly
    rather than through the cycle script — so an append reordered ahead of the
    capture would otherwise make the horizon track wall clock again through
    this node's own fresh events and silently undo the fix.
39g. **Priority triage bands correctly and never lowers a band
    (requirement 39g).** `test/refiner-priority-triage.test.sh` passes:
    `refiner_candidate_items` admits an already-refined `issues` entry only
    when `priority_set` is literally `false`, marks it `triage_only: true`,
    excludes a banded or claimed/blocked/void/exempt one exactly as
    requirement 39a (The Refiner) already requires, and never admits an entry carrying no
    `priority_set` key at all — the pre-existing shape every source but
    `issues` still carries. `lib/issue-priority.sh`'s ratchet, driven
    against a stubbed `gh`: `issue_priority_field_ids` resolves the field
    and option ids from a live GraphQL read and fails (never an empty
    result read as "nothing to band") when the field is absent;
    `issue_priority_apply` re-reads the issue's current band immediately
    before writing, applies only when unset or strictly outranked by the
    verdict's own band, and skips — logged, not warned — an equal or lower
    one, asserted from both directions; `issue_priority_current` itself
    returns the raw option name unfiltered, and a current band outside the
    four ranked names is skipped as `skipped-unrankable` — logged, not
    warned, and never overwritten even by a verdict that would otherwise
    strictly outrank it (agent-ops#509); a field or issue read failure, and a
    failed mutation, are each a distinct failure reason, never silently
    read as a skip. A failed mutation additionally carries the `error` key
    (agent-ops#960), asserted from both directions against a stubbed `gh`
    that writes to stderr before it fails: a rejection carrying a
    type-mismatch-shaped GraphQL error yields that error's first line and no
    subsequent line, and a rejection with no stderr at all yields the key
    still present and empty, never omitted. The cache directory's own
    lifecycle: sourcing the
    library with `ISSUE_PRIORITY_CACHE_DIR` unset creates a directory and
    marks it owned, and `issue_priority_cache_cleanup` then removes it —
    fixture files inside it included, since an empty `rm -rf` proves nothing
    about the real per-SLUG cache it stands in for — while a caller-supplied
    path is marked unowned and still exists after the same call; a second
    call once it has already run, and a call in a process where the
    `mktemp -d` never produced a directory at all, each print nothing and
    still return 0; re-sourcing the library in the same process, with
    `ISSUE_PRIORITY_CACHE_DIR` still set to the directory the first source
    created, still marks it owned rather than reading it as caller-supplied,
    creates no second directory, and cleanup still removes it
    (agent-ops#541). Repointing `ISSUE_PRIORITY_CACHE_DIR` to a caller's own
    directory and re-sourcing, then unsetting it and re-sourcing again, makes
    the library create a second directory in the same process; both are
    tracked in `ISSUE_PRIORITY_CACHE_DIR_OWNED_PATHS`, and a single
    `issue_priority_cache_cleanup` call removes both while leaving the
    caller's own directory, sitting between them, untouched
    (TD-PPagop-26082202). An ownership record exported to a `bash -c` child
    process — `ISSUE_PRIORITY_CACHE_DIR`, `…_OWNED=1` and `…_OWNED_PATHS` all
    inherited, but stamped with the parent's own `$$` rather than the
    child's — is not trusted: the child marks the directory unowned, and its
    own `issue_priority_cache_cleanup` call leaves the directory in place. The
    array form of that same inherited-record check is asserted independently,
    since bash cannot export an array and a parent can therefore only ever
    export `ISSUE_PRIORITY_CACHE_DIR_OWNED_PATHS` as a scalar: with
    `ISSUE_PRIORITY_CACHE_DIR` itself left unset so the child takes the
    fresh-directory branch rather than the caller-supplied one, a `bash -c`
    child that inherits `…_OWNED_PATHS` as a scalar naming a victim directory,
    `…_OWNED=1` and the parent's own (foreign) `…_OWNER_PID` resets its own
    array to hold only the directory it just created, rather than appending
    onto the inherited scalar and folding the victim path into a record its
    own `issue_priority_cache_cleanup` call would then `rm -rf` — the victim
    directory still exists once that call returns (agent-ops#552). A
    source that follows a cleanup does not trust the record cleanup left
    behind: it creates a fresh directory, marks it owned, and field-id
    caching works again in that process. A cleanup reached through a command
    substitution is pinned as a case of its own, since that direct call
    clears the record before the re-source ever reads it and so leaves the
    source-time existence check unexercised: the subshell removes the
    directory but its record-clearing never reaches the parent, which
    re-sources holding a record still marked owned, still stamped with this
    same `$$` and still naming the now-removed directory, and a fresh owned
    directory is created and caches field ids regardless (agent-ops#552). A
    directory this file created is not abandoned when a caller subsequently
    repoints `ISSUE_PRIORITY_CACHE_DIR` at its own path:
    `issue_priority_cache_cleanup` still finds and removes the directory it
    made earlier, and leaves the caller's own (now-current)
    directory, and `ISSUE_PRIORITY_CACHE_DIR` itself, untouched (agent-ops#552).
    A failed cache write — `ISSUE_PRIORITY_CACHE_DIR` naming a directory
    that does not exist — prints nothing to stderr, and still returns the
    resolution it could not cache. A field missing one of the four options
    is asserted from both directions (agent-ops#534): with a lower option
    present, the verdict's band falls back to the nearest lower one and
    `requested` names the band actually asked for; with nothing lower
    present (the verdict was already `Low`, or every lower band is also
    missing), the fallback ties
    upward to the nearest higher option instead; the ratchet then runs
    against the fallback band, so a fallback that does not outrank the
    current band is still `skipped-lower-or-equal` with `requested` still
    reported; and a field with none of the four names writable at all is
    `band-option-missing`, a reason distinct from `field-unresolvable`, with
    no `gh` calls beyond the field resolution itself. `maybe_run_refiner`'s
    wiring: an ordinary `refined`
    verdict carrying `priority` records both `item-refined` and
    `issue-prioritised`; a `triage_only` item's `priority`-only verdict
    records neither `item-refined` nor a label, with outcome `triage-only`
    and no uncorroborated-comment warning; a `needs-refinement` verdict
    carrying `priority` still applies the band despite the decline; the same
    verdict on a `triage_only` item records no block, no
    `needs_refinement` label and no `blocked`/`blocked:needs-refinement`
    labels, with outcome `triage-only-refused` and a `warning`, while its
    band still applies; a
    failed band write is a `warning` that leaves the refinement or block
    already recorded untouched — naming both the band actually attempted and
    the band the verdict asked for when the failure followed a fallback, and
    the verdict's own band alone when it did not (agent-ops#551), and
    appending the mutation's own captured GraphQL error when the result
    carries a non-empty `error` and no such clause at all when it is empty
    (agent-ops#960) — while an
    unrankable current band is not — it logs `issue-prioritised-skipped`
    like any other ordinary skip, still carrying `requested` when a fallback
    ran; and
    `DRY_RUN` reaches no `gh` call and writes no event at all —
    `maybe_run_refiner`'s own first guard already returns before any
    candidate is claimed. `scripts/gather-issues.sh`'s `priority_set` is
    asserted true for an issue banded outside the four names, with
    `priority` itself still reading Medium (`test/issues-prefetch.test.sh`).
    `scripts/doctor.sh`'s own gate is asserted against the four banded
    `sources` tokens a valid configuration actually carries, so the check
    cannot regress to one that never runs, and its own EXIT trap is asserted
    against an isolated `TMPDIR` left empty by all three of its exit paths —
    a clean pass, `--help`, and an unreadable `--config`, the two of which
    exit before any check runs at all (`test/doctor.test.sh`). The
    pre-flight (issue #511):
    `refiner_drop_unbandable_triage` (`lib/refinement.sh`) drops only the
    named repositories' `triage_only` entries, leaves every other candidate
    from those repositories and every candidate from any other repository
    untouched, is the identity on an empty unresolvable-repository list, and
    falls back to its input unchanged (never `[]`) on malformed candidates
    JSON. `issue_priority_options_any` (`lib/issue-priority.sh`,
    agent-ops#542) is asserted true whenever the field carries at least one
    of the four band names, including only one, and false only when it
    carries none. `refiner_filter_unbandable_triage` (`lib/refinement.sh`),
    lifted verbatim and driven against a stubbed `gh` distinguishing three
    repositories — one whose field query fails outright, one whose field
    resolves carrying none of the four band names, one whose field resolves
    complete: the failing repository's and the no-bands repository's
    `triage_only` candidates never reach the returned set while their other
    candidates and the complete repository's candidates — `triage_only` or
    not — do; exactly one `warning` per dropped repository is logged, each
    naming the repository and the count of candidates it dropped, not one per
    item, with the no-bands repository's wording distinct from the
    field-unresolvable one; a repository missing only *some* of the four
    names is asserted unaffected by this pre-flight, reaching the returned
    set byte-identical with no warning logged; a repeat resolution of any of
    these repositories in the same process hits
    `issue_priority_field_ids`'s own cache rather than issuing a second
    query, including for the failing repository's cached failure; a cycle
    with no `triage_only` candidate at all issues no field query from this
    path; and when every contributing repository's field resolves with at
    least one band option, the returned set is byte-identical to the input.
    The call site's own guard (issue #567): lifted verbatim by the comment
    that immediately precedes it, since it is a call site rather than a
    function of its own, and driven with a stubbed
    `refiner_filter_unbandable_triage` counting its own invocations — with
    `refiner_model` empty the pre-flight is never called at all, and with it
    set the pre-flight still runs exactly once, unchanged.
11c. **A broken Enabler cannot break a cycle (requirement 37).** With a stubbed
    stage that times out, exits non-zero, or (after requirement 9e's salvage
    resume also fails to parse) returns prose instead of JSON: the
    cycle still exits 0, logs `stage-end` and one `warning`, writes **no**
    `unblocked`, `item-void`, `escalated` or `enabler-examined` event. The
    `warning` names every item the discarded engagement was given
    (`items: [{repo, item}, …]`), and each of those items' 35c tombstone is
    `expire`d rather than released — `test/claim.test.sh` passes: an expired
    entry's registry file still exists with its `ts` backdated and every
    other field unchanged, and a `gc` run immediately afterward retires it.
    Assert the ordering too — the engagement's events precede
    `cycle-end` — and that a limit phrase in that transcript produces an ordinary
    `limit-hit` rather than being swallowed with the rest of the failure.
33a. **The per-stage metering record matches `docs/METERING-SCHEMA.md`
    (requirement 33a).** `test/metering.test.sh` passes: `lib/metering.sh`'s
    `metering_fields` derives `model`, `provider` (read from
    `lib/model-id.sh`'s `MODEL_PROVIDER`, falling back to `anthropic` for a
    model never resolved through `resolve_model_id_into`, and for an empty
    one — which under `set -euo pipefail` resolves to that same fallback
    rather than aborting the caller on bash's own bad-array-subscript error
    for an empty associative-array subscript, issue #2234), `cost_usd`,
    `duration_ms`, `num_turns`,
    `is_error` and `tokens{input,output,cache_creation,cache_read}` from a
    single-model envelope and from a multi-model (subagent) envelope, summing
    `tokens` across every `modelUsage` entry in the latter; a genuinely zero or
    `false` value survives rather than collapsing to `null`; a missing, empty
    or unparseable out-file degrades the envelope-derived fields to `null`
    while `model` keeps the id it was passed; and an envelope whose
    `modelUsage` entries are unreadable still yields one valid object, so no
    envelope can cost a `stage-end` event its `stage` and `exit_code`. Both
    `agent-cycle.sh` and `review-cycle.sh` source
    `lib/metering.sh` and merge its output into every `stage-end` /
    `review-stage-end` event they log, so this one function's correctness is
    what "both pipelines emit conforming records" reduces to.
1c. **The configuration matches its schema, and the schema is an enforced
    startup gate, not merely a checkable one (requirement 1b).**
    `test/config-schema.test.sh` passes: this repository's own `config.json`
    validates, so a key added to the config without a schema entry fails
    immediately; every keyword the schema uses is one `lib/config-schema.sh`
    implements, asserted by reading the keywords back out of the schema
    rather than from a list maintained beside it; each keyword class is
    exercised with a value that must be rejected, naming the path that is
    wrong; and `scripts/doctor.sh` reproduces the two surviving cross-key
    guards (the Enabler's assignee, the implementation-plan path) as a
    `fail`, its silent-breach combinations as a `warn`, and a config that
    will not parse as exit 2 with nothing downstream attempted. Beyond the
    library level, `agent-cycle.sh` and `review-cycle.sh` themselves are
    driven end to end against a schema-violating config — with `claude` and
    `gh` stubbed so reaching either would itself mean the gate had failed —
    and asserted to exit non-zero naming `config.schema.json`, before either
    stub is ever reached; the retired `nice` and `prompt_overrides` guards'
    own wording is asserted gone in favour of the schema's, and the
    surviving Enabler-assignee guard is asserted to still fire on a config
    the schema itself accepts — as is the duplicate-`repos[]`-slug refusal,
    which exits 1 naming the repeated slug rather than reporting a schema
    failure the schema itself does not find. Every case is a mutation of
    `test/fixtures/config-base.json` — a configuration the suite owns, which
    names no `merge_autonomy` or `approver_*` key at all, so a cross-key
    rule's negative case builds the state it claims to test instead of
    inheriting half of it — run against the shipped scripts, so what is
    asserted is the product rather than a restatement of it. That fixture is
    itself asserted to validate against the schema, so a required key added
    to the schema fails once, naming it. The shipped `config.json` is read
    for two things only: that it validates, and that `doctor.sh` passes it
    (including its own `merge_autonomy` pairing, at whichever rung the file
    names — read back from it, never written down here). `--offline`
    throughout: no assertion here needs the network.

    A documented installation value is checked against the live config the
    same way (`config_documented_value_mismatches`, issue #567): a key whose
    `x-docs.value` differs from its own schema `default` — `refiner_model`
    documented as `claude-haiku-4-5-20251001` while the key had never once
    been set — earns a `warn` naming the key, the documented value and the
    resolved one; an empty resolved value renders `*(unset)*`, and an
    array-valued documented cell is compared by its parsed JSON rather than
    this script's rendered text, so `[5]` against a documented `[0]` still
    warns while whitespace alone never does; `merge_autonomy` — whose
    `x-docs.value` equals its own `default` — earns no such warning at any
    rung, at either the top-level key or a repository's own override; a key
    with no `x-docs.value` at all, and one whose `x-docs.value` is an object
    keyed `readme`/`spec`, are both asserted silent even set far from their
    own default; and the shipped `config.json`, unmodified, is asserted to
    report no such mismatch at all — closing the loop #568 opened by
    installing `refiner_model` for real.
1d. **The prose configuration tables are generated from the schema, and
    regenerating them is gated (requirement 1b, component 16).**
    `scripts/render-config-table.sh` with no arguments run against this
    repository's own `config.schema.json`, `docs/reference/configuration.md`,
    `docs/spec/implementation/README.md` and `docs/spec/review.md`
    leaves every file byte-identical to what is committed — regenerating a
    clean tree is a no-op — and `--check` exits 0 against it; `git diff`
    confirms nothing moved. `test/render-config-table.test.sh` passes: a key
    present in a fixture schema and absent from a region is added, a
    hand-edited row is restored, `--check` exits non-zero naming the file,
    the region and the first differing key on a stale region and zero on a
    fresh one, a `|` inside prose survives escaped, four distinct
    `x-docs.value` rows render verbatim, an `x-docs.value` keyed per
    audience gives each document its own value cell and falls through to the
    schema `default` for an audience it does not name, a key carrying no
    `x-docs` for an audience falls back to `description`, and a region whose
    first two lines are not a header row and a delimiter row is refused
    rather than rendered. A note over 500 characters is truncated at a word
    boundary — never inside a code span (single- or double-backtick
    delimited, the latter's content free to carry a literal backtick) or a
    link, each covered by its own fixture note — with its full text
    reproduced in the matching Extended notes subsection, including for a
    dotted (`schedule.*`-style) key; a document with two Extended notes
    headings that would slug the same is refused, and so is a document
    missing either half of a `config-table:notes` marker pair. A note that
    is an array of blocks (#220) — two paragraph strings; a paragraph, a
    `list` block and a paragraph; a paragraph, a `code` block and a
    paragraph, each over the
    cap — flattens to one space-joined table-cell line (the list's items
    comma-joined, the code's newlines turned to spaces and backtick-wrapped,
    backing off to a wider delimiter with padding spaces when the code
    itself contains a backtick) and, separately, renders as real block
    Markdown in the Extended notes
    subsection: a blank line between paragraphs, real `- ` list items, a
    real fenced code block, each still blank-line-separated from its
    neighbours; a `list`-only or `code`-only note under the cap degrades the
    same way in its cell with no Extended notes subsection generated at all.
    A start marker carrying trailing prose after its `id=<id>` token (#356)
    is matched and rewritten the same as one without: the fixture's markers
    carry it and every render/`--check` assertion above still passes against
    them, and the plain, unannotated form is separately exercised too (the
    orphan-marker fixture used for the no-heading-above-it case), proving
    both forms are accepted rather than only the newly-annotated one.
    `.github/workflows/config-table.yml`
    runs `--check` on every pull request, so a schema edit landing without a
    matching doc regeneration (or the reverse) fails CI rather than drifting
    the way `unvoid_label` and `state_local_cycles_retained` both did before
    this requirement existed.
1m. **`doctor.sh` checks write access, Claude credentials, the rendered
    crontab and `nice` reordering, and `--offline` still runs the two that
    need no network (requirement 1b, component 14).** `test/doctor.test.sh`
    passes, against a stubbed `gh` and `claude` on `PATH` — the seam
    `doctor.sh` leaves for both, carrying no override variable for either —
    run without `--offline` so these checks are actually exercised, with
    nothing on `PATH` able to reach a real network regardless: on the PAT
    path a `.permissions.push` of `true` is `ok`, `false` is `fail`, and an
    absent field is `skip`; `.archived: true` is `fail` even when
    `.permissions.push` is `true`; under the forge authoring App — stubbed
    through `AUTHOR_TOKEN_CURL` with a throwaway key, `GH_TOKEN` exported
    empty as the cron view has it — `.permissions` all false is *not* read as
    "cannot push" (agent-ops#1397), an installation carrying `contents:
    write` over a covered repository is `ok`, a narrower grant or a selection
    leaving the repository out is `fail` naming which, and either installation
    read being unreachable is `skip`; Claude credentials check both of D4/D30's
    two lanes independently — the `api` lane's non-empty `ANTHROPIC_API_KEY`
    shaped like an Anthropic key (the `sk-ant-` prefix) is `ok`, one that is
    not is `warn`, and its absence is `ok` naming it absent, each naming the
    lane's configured weight and whether it is enabled; the `subscription`
    lane's own `claude auth status --json` — run with `ANTHROPIC_API_KEY`
    stripped from that call's environment, so it is checked regardless of
    whether the `api` lane above is also present — reporting `loggedIn: true`
    with a `subscriptionType` is `ok` naming the lane present, `loggedIn:
    true` with no `subscriptionType` is `ok` naming a Console account rather
    than an open subscription lane (#2241), and `loggedIn: false` is `ok`
    naming it absent, each of these three naming the lane's configured
    weight and whether it is enabled, exactly as the `api` lane's own lines
    do; both lanes absent is `fail` — distinguished from the
    subscription lane's own parse failure, since `loggedIn: false` is a
    legitimate answer rather than evidence the JSON could not be read — and a
    `claude` with no `auth` subcommand leaves the subscription lane `skip`;
    the real
    `deploy/docker/render-crontab.sh` run against a config whose
    `schedule.excluded_minutes` rules out every minute is `fail`, the same
    renderer run against a trimmed copy of the repository missing
    `crontab.tmpl` is `skip`, and a clean render is `ok` naming the node and
    the cycle, review and heartbeat minutes the config asked for, and whether
    the cycle minute came from an explicit, allowed `CYCLE_MINUTE` or was
    hashed from the node's name; a second `ok` line names the background
    timer minutes (`state_sync_push_minutes`, `state_sync_fetch_minutes`,
    `log_rotation_minute`) the config asked for; a repository with a
    non-zero `nice` gets its own line naming the value and
    the multiplier, and one with every repository at `nice` 0 prints no line
    at all; and `--offline` still renders the crontab and reports `nice`
    reordering while reporting write access and Claude credentials as
    `skip`. Must pass `shellcheck`.
1n. **`--unattended` runs the GitHub section in full and skips only the two
    checks that spend, with wording distinct from `--offline`'s, and writes
    `state_dir/.doctor-status.json` (requirement 2.6a).** `test/doctor.test.sh`
    passes: against the same stubbed `gh` and `claude`, a run with
    `--unattended` still reports write access (the GitHub section is not
    skipped, unlike under `--offline`); Claude credentials and the
    stream-flushing probe are each reported `skip` naming `--unattended`,
    never `--offline`'s wording; a completed run leaves
    `state_dir/.doctor-status.json` with a `timestamp` (a real UTC instant),
    a `verdict` (the worst of `fail`/`warn`/`ok` this run found), its
    `fails`/`warns` as arrays of the exact messages printed, and a
    `token_expiry` (requirement 2.7a) that is `{expires_at, days_remaining}`
    when the GitHub section read a `GitHub-Authentication-Token-Expiration`
    header and `null` when it did not; an ordinary run
    with neither flag writes no such file and runs the Claude section for
    real, against the stub. Must pass `shellcheck`.
6h. **The pipeline creates the labels it applies, and touches no others
    (requirement 6a).** `test/labels.test.sh` passes against a stubbed `gh`
    that records every invocation and refuses a duplicate the way GitHub
    does: an empty repository receives every label of its role and each is
    reported created, `obsolete` included alongside `blocked` as one of the
    two non-configurable, human-only labels the target role always carries;
    a second pass over the same repository reports nothing;
    a partly-labelled one receives only what it lacks; a name differing only
    in case counts as present, since GitHub's uniqueness is case-insensitive;
    a label switched off by an empty configured name is not created; a
    renamed label is created under the configured name. The two safety
    properties are asserted from the request log rather than from the return
    value — **no `PATCH`, `PUT` or `DELETE` is ever issued**, and the only
    requests made at all are listings and creates — and the failure paths
    are asserted not to escalate: one refused create still creates the rest
    and returns 0, an unlistable repository returns 1 having created nothing
    and claimed no failures it did not observe, and a guarded call survives a
    total failure under `set -e`.

6j. **Labels a stage asks for are minted safely, and only within the caps
    (requirement 6c, issue #714).** `test/labels.test.sh` passes:
    `labels_reserved_names` lists the fixed set (`blocked`, `blocked:*`,
    `obsolete`, `complexity:*`, `pw::type:tech-debt`, `pw::owner-decision`,
    `pw::decision`, `open-question`) ahead of every non-empty configured
    label name — the project-review pull-request label, and a repository's
    own override of it, among them — and a name switched off by an empty
    configured value contributes nothing; `labels_validate_name` refuses an empty name, one
    over 50 characters, one carrying a comma, and one matching a reserved
    entry case-insensitively — by exact name or by prefix glob — while
    passing an ordinary name and one at exactly the 50-character limit;
    `labels_mint` creates and applies an accepted entry with its own colour
    and description, carries the description of an entry that names one but
    no colour through intact under the neutral-grey default rather than
    confusing the two fields, refuses an entry that is not an object at all
    without costing the well-formed entries beside it,
    applies without creating a name already present,
    refuses a reserved name without ever reaching `gh`, enforces its own
    per-item cap (the default 3, and a smaller explicit one) by refusing the
    surplus `cap` while the accepted entries still land, and reports
    `create-failed`/`apply-failed` distinctly for a `gh` refusal at each
    step — neither ever escalating past the returned report, and an empty
    repository, empty `LABELS_JSON` or unusable `KIND` printing the
    all-empty object rather than erroring.
    `test/refiner-verdicts.test.sh` passes: a verdict's own `labels` mints
    and applies onto the issue behind it regardless of `verdict` itself, a
    reserved name is refused and never reaches `gh`, and the per-engagement
    pool of 10 is shared across items claimed in the same engagement — the
    fourth of five items that each request labels within a shared budget
    still lands on an exactly-exhausted pool, and the fifth's own suggestion
    is refused `engagement-cap` before any `labels_mint` call is even
    attempted. A tech-debt item whose ref is not its backing issue number
    logs that ref as its `labels-minted` event's `item` (requirement 6c),
    while the `gh` write underneath it still names the number.
    `test/implementer-labels-wiring.test.sh` passes: a summary with no
    `labels` field, or an empty one, calls `labels_mint` not at all; a
    non-empty one calls it exactly once, against the pull request's own repo
    and number (parsed from its URL) with `kind` `pr`, reserved names drawn
    from `labels_reserved_names(CONFIG_FILE, SCHEMA_FILE)`, and the result
    logged as one `labels-minted` event naming `repo`, `item` and
    `actor: "implementer"`.
    `test/config-schema.test.sh` passes: `scripts/doctor.sh` fails a
    configured label set to `blocked:<anything>`, case-insensitively, the
    same as the pre-existing exact-`blocked` check.
    Grep assertion for the inertness invariant's own corollary: nothing in
    `agent-cycle.sh`, `lib/` or `scripts/` branches on a label name that is
    not in `labels_reserved_names`'s own list.

38. **Human-visibility (requirements 38a–38c).** `test/handoff.test.sh` passes:
    `_handoff_pr_approved` reads `true` for a standing `APPROVED` review with
    nothing `CHANGES_REQUESTED`-blocking, `false` for the reverse, and `false`
    again when the two positions are held by different reviewers (one
    approver, one blocker); a later review supersedes an earlier one from the
    same reviewer regardless of which state it moves to or from; a bot's
    `APPROVED` review is never counted (agent-ops#391); and an unreadable
    reviews list is a failure, never a guessed `false`.
    `ensure_human_reviewer` re-requests review from whoever has ever reviewed
    the pull request (any state) in preference to `assignee`; falls back to
    `assignee` only when nobody ever has; strikes the pull request's own author
    off both lists before asking, so an author's `COMMENT` review on their own
    pull request neither becomes a request target nor 422s the request for the
    human beside them, and an author-only reviews list, or `assignee` equal to
    the author with nobody else known, is the distinguishable
    `skip\tno-candidate` (tech-debt/TD-PPagop-26081001.md), never a bare
    `skip`; `skip`s (bare) while something is genuinely
    `CHANGES_REQUESTED`-blocking, and while the pull request is a draft; the
    pending list excludes a bot-type or `[bot]`-suffixed entry the same way
    the reviews list does, and counts a requested team — agreeing with
    requirement 38e's own read of the same rule
    (tech-debt/TD-PPagop-26081403.md); and an unreadable reviews list or
    pending list is `failed`, never an assumed
    `skip`, while a pending-list read refused specifically by GitHub's REST
    rate limit is `failed-rate-limited`, told apart from that bare `failed`
    (agent-ops#1082). `test/human-reviewer-handoff-wiring.test.sh` asserts
    what both call sites do with that answer, driving the Reviewer's own
    handoff block and the Enabler's `complete_handoff` block through the same
    cases: `failed-rate-limited` still warns, names GitHub's rate limit as
    the cause, still falls back to `enabler_assignee` for `reviewers`, and
    carries the distinguishing state on `pr-ready` rather than a bare
    `failed`. `handoff_round_answered` is asserted
    directly there too, both callers' halves at once: a marked
    `actor=implementer` reply after the blocking review is `answered`, the
    same reply before it is `unanswered`, an unmarked comment and another
    actor's marked comment never answer, and a `review_requested` event
    answers only the caller that passes that signal. Its failure direction is
    asserted as its own group, because that is where the requirement lives —
    an empty blocking timestamp, an argument that is not a single JSON array,
    two concatenated pages, and an array whose elements break the extraction
    are each `unknown`, never `answered`. `test/needs-refinement.test.sh` passes:
    `refinement_blocked_reason_label` maps `needs-refinement` to
    `blocked:needs-refinement` and any other kind to nothing;
    `refinement_block_fields`'s third and fourth arguments record
    `blocked_label`/`blocked_reason_label` independent of the label argument;
    `refinement_label_add`/`_remove`, the same primitive `needs_refinement_label`
    already uses, apply and remove both `blocked` and its reason label; and
    `refinement_blocked_label_targets` finds both of an issue's blocked
    labels, scoped by repo the same way `refinement_label_targets` is,
    surviving a void the same way, and finds only the reason label — never
    the generic `blocked` — for a legacy block that records
    `needs_refinement_assignee` and neither blocked-label field, since that
    block's own event cannot prove which of `added`/`present` the migration
    sweep actually saw when it applied `blocked`. `refinement_label_project`
    (agent-ops#651) reads before it
    writes: an absent `blocked` is added and reported `added`; a pre-existing
    one — another label on the issue does not mask this — is `present`,
    untouched and unrecorded; an unreadable label list is applied best-effort
    but `unrecorded`; and a label the repo does not have is `failed`, the same
    four-way contract the deleted `refinement_assignee_project` once had for
    the assignment this replaced. `refinement_blocked_label_stale`
    (agent-ops#651) offers up exactly the `blocked`/`blocked:<reason>` pair
    whose own-label-action history's latest action is `add` for an item no
    longer open, correctly leaving alone a label whose block is still open, one
    whose removal already succeeded, and another repo's identically-numbered
    item. `refinement_assignee_remove` — the one
    survivor of what used to be a pair, kept for
    `scripts/sweep-legacy-refinement-assignees.sh` alone — still makes one
    `gh issue edit --remove-assignee` call. `test/sweep-human-visibility.test.sh`
    passes against a stubbed `gh`: a pull request with nothing blocking it and
    no known reviewer yet is both re-requested (from the approver) and, when
    also approved, mergeable, green and idle past `human_nudge_idle_hours`,
    nudged in the same pass; a `CHANGES_REQUESTED`-blocked pull request whose
    round is unanswered has no review request made for it and is never
    nudged; the same pull request whose round *is* answered — a marked
    Implementer reply after the blocking review — is re-requested via
    `confirm_review_requested`, still never nudged (the nudge's own
    `_handoff_pr_approved` gate holds it off regardless, since the same
    reviews fixture is still `CHANGES_REQUESTED`); a reply
    predating the blocking review, or one carrying no marker at all, does not
    self-heal it; a round this cannot read (`handoff_round_answered`
    returning `unknown`) is a `warning`, never a guessed request; a listing
    the stub splits across two pages — the shape `--paginate` produces — still
    self-heals when answered and is still silent when unanswered, which is
    what holds `_sweep_round_answered`'s reads to the streamed form; an
    answered round on a pull request whose rollup is not green (empty or
    mixed) produces no review request and no output at all — the green gate
    (agent-ops#338) short-circuits before `_sweep_round_answered` is even
    asked; the same answered round on a rollup whose only non-`SUCCESS` entry
    is `SKIPPED` still self-heals, proving the self-heal shares
    `_sweep_checks_green` with the idle nudge rather than a stricter copy of
    it; a pull request nudged once already is not nudged
    again even when still idle; an unmergeable, not-yet-green, or not-yet-idle
    approved pull request is never nudged, and neither is one with an empty
    check rollup; an approved, `MERGEABLE`, green and idle pull request whose
    `mergeStateStatus` is `BLOCKED` — the base branch requiring a second
    approval `_handoff_pr_approved` cannot see — is not nudged either, while
    `CLEAN`, `BEHIND` and an unresolved `UNKNOWN` all still are; a rollup
    whose only non-`SUCCESS` entries are `SKIPPED` —
    the shape every target repository's pull requests carry, a `CheckRun`
    gated off by a `paths:` filter or an `if:`, distinct from `StatusContext`
    and so read by `.conclusion` alone, never `.state` — is nudged all the
    same, while a `CANCELLED` or still-`IN_PROGRESS` (`conclusion` null)
    entry still blocks it; `human_nudge_idle_hours: 0` disables the nudge while leaving
    the review-request self-heal unconditional; and a listing, a view, or a
    reviews read that fails is a `warning`, never silence — an unreadable
    reviews list warns twice for the same pull request, once from
    `ensure_human_reviewer`'s own candidate check and once from
    `_handoff_pr_approved`'s idle-nudge check, since each reads it
    independently and neither may mask the other's failure; and, where that
    idle-nudge reviews read fails specifically on a GitHub REST rate-limit
    refusal, its warning names the cause distinguishably — GitHub's `kind`
    rate limit, read via `github_limit_kind` from one further diagnostic-only
    read of the same endpoint — rather than the same generic detail a
    non-rate-limit failure gets (agent-ops#1082). The same distinction holds
    at the sweep's own review-request read: a rate-limited one still warns —
    never silence, which matching requirement 38a's bare `failed` alone would
    produce — with `— GitHub's REST rate limit refused the read` appended to
    the unchanged `could not request review from …` prefix requirement 38e
    classifies on, while a non-rate-limit failure at that read keeps that
    detail exactly as it was. A pull request
    whose only legal candidate is its own author is a `warning` naming
    `enabler_assignee`, not silence — the one `skip` reason the sweep itself
    surfaces, read off requirement 38a's `skip\tno-candidate` detail, unlike a
    still-`CHANGES_REQUESTED`-blocked pull request's bare `skip`, which
    produces no action at all. Confirm the nudge
    comment carries the visible attribution header and both markers
    (`agent-ops:pipeline-comment` and `agent-ops:human-nudge`).
38e. **A violation the sweep cannot heal is read back and re-verified, not
    guessed at.** `test/human-visibility-hygiene.test.sh` passes:
    `human_visibility_violations` keeps a repo-level (empty `pr_url`) warning
    with nothing to clear it; a later `human-review-requested` event clears a
    same-`pr_url` `could not request review from …` warning, and a later
    `human-nudged` event likewise clears a same-`pr_url` `could not post the
    idle nudge comment` warning and, separately, a same-`pr_url` `could not
    read the pull request's reviews …` warning (`_handoff_pr_approved`'s own
    read failing inside the idle-nudge check alone joins the nudge family,
    since nothing else the sweep does for that pull request depends on that
    same read), but a `human-dequeue-notice` event for that same `pr_url`
    does *not* clear any of those three — nor does a
    `human-nudged`/`human-review-requested` event clear a `could not post the
    merge-queue-dequeued notice` warning — proving the family split rather
    than assuming it (agent-ops#393); separately, a `human-review-requested`
    event does *not* clear a `could not read the pull request's reviews …`
    warning, confirming it is not read under the wider fail-safe default; a
    later event for a different `pr_url` or a different sweep leaves an
    identity's warning untouched; an unrecognised warning shape (one none of
    the classes above match) is cleared by any of the three success events,
    the fail-safe default for a warning with no family of its own; a repeated
    identity keeps only its latest detail regardless of family; and a torn
    log line is skipped, not fatal.
    `test/gather-human-visibility-hygiene.test.sh` passes against a
    stubbed `gh`: violations naming a different repo are ignored; a
    repo-level violation survives only while its listing still fails live and
    is dropped the moment a fresh listing succeeds; a pull-request violation
    of any class is dropped once it is merged, closed, or back in draft; a
    `could not request review from …` violation is dropped once
    `reviewRequests` is non-empty, and separately once a non-bot review with
    state `APPROVED` or `CHANGES_REQUESTED` exists in the reviews list —
    never `reviewDecision`, agent-ops#391, TD-PPagop-26081505 — and otherwise
    survives; a
    `reviewRequests` entry typed `Bot` (keyed `__typename`, the
    discriminator `gh pr view`'s exporter actually emits) or naming a
    `[bot]`-suffixed login alone does not drop it, while a
    requested-team-only entry does (tech-debt/TD-PPagop-26081403.md) — the
    bot half is defensive: today's exporter drops Bot reviewers from the
    array entirely, so in production a Copilot-only request arrives as `[]`
    and is the "otherwise survives" case (see Gotchas); a
    `could not post the idle nudge comment` violation on an `APPROVED` pull
    request survives while no comment carries both the exact
    `<!-- agent-ops:human-nudge -->` HTML-comment form and the pipeline-marker
    stamp — confirming the classes are told apart, not read off the same
    "has a human reviewed this" check, which would otherwise drop every
    nudge-class violation on sight — and separately survives a comment
    carrying the stamp but only prose mentioning the marker, a comment
    carrying the exact HTML form in a fenced code block but no stamp, and an
    ordinary pipeline comment carrying the stamp but no nudge marker at all
    (agent-ops#390, #428, mirroring `test/sweep-human-visibility.test.sh`'s own
    discriminating cases), and is dropped only once a single comment carries
    both; a `could not post the merge-queue-dequeued notice` violation
    (TD-PPagop-26081504) survives while the `agent-ops:merge-queue-dequeued:`
    marker comment is absent and is dropped once it appears, the same
    marker-read shape as the nudge class; a
    `no legal review-request candidate` violation
    (tech-debt/TD-PPagop-26081001.md) survives while `author`/`reviews` still
    show no non-author, non-bot, submitted review and no pending (unsubmitted)
    review counts either, is dropped the moment such a reviewer appears, is
    dropped separately once `reviewRequests` is non-empty under that same
    bot filter (a candidate a CODEOWNERS auto-request already named, before
    anyone has reviewed — agent-ops #350, #353, #355), survives a
    Bot-typed/`[bot]`-suffixed-only `reviewRequests` entry (defensive, as
    above) and is dropped by a
    requested-team-only one, and is dropped separately once the assignee
    named in its own detail text no longer names the pull request's author; a
    `could not read the pull request's reviews …` violation
    (`_handoff_pr_approved`'s own read failing inside the idle-nudge check)
    has no follow-up action outcome of its own to inspect — the read failing
    was the whole violation — and is dropped unconditionally the moment the
    outer `gh pr view` re-check itself succeeds: since agent-ops#1085 moved
    `_handoff_pr_approved` (`lib/handoff.sh`) onto the same GraphQL surface,
    asking for the same `reviews` field, that outer call already succeeds
    at, reaching this class at all past that success is the whole answer —
    survives only while the outer `gh pr view` re-check itself is
    unreadable, the same fail-safe default every other class shares, proven
    by `test/gather-human-visibility-hygiene.test.sh`'s own `STUB_VIEW_RC`
    case rather than by a second, separately-stubbable read this class no
    longer makes; a
    `could not read the pull request's state …` violation
    (`scripts/sweep-human-visibility.sh`'s own broad `gh pr view --json
    reviewDecision,mergeable,mergeStateStatus,statusCheckRollup,reviews,
    comments` call failing) is the same shape — no follow-up action outcome
    of its own, so it re-runs that exact call instead: dropped only once it
    succeeds again, judged on exit status alone; survives while it still
    fails, even though the narrower opening `gh pr view` re-check (which
    omits `statusCheckRollup`) succeeds, proving the fix does not infer the
    answer from that narrower read either; and is dropped on a merged,
    closed or draft pull request the same as every other class,
    decided before the class-specific re-check is even reached; a
    genuinely unrecognised warning shape (one none of the six classes
    above match)
    survives for as long as its pull request
    stays open and not a draft; an unreadable live re-check keeps the
    violation rather than dropping it; a repo-level and a pull-request
    violation for the same repo combine into one candidate; and every
    surviving candidate carries `source: "human-visibility"` and a
    `human-visibility-`-prefixed ref.
    `test/human-visibility-wiring.test.sh` passes against the block lifted
    verbatim out of `agent-cycle.sh` — the gate and the assignment that join
    the reduction to the gatherer, which neither test either side of it can
    reach: a repo whose `sources` list `human-visibility` is gated in and its
    entry's `human_visibility` array carries the candidate; a repo whose
    `sources` omit it is left at `[]` with the gatherer never called for it;
    each repo is handed its own slice of the violations rather than the
    fleet-wide array; and a re-check that drops everything, or a cycle with no
    violations at all, still leaves every entry a valid `[]`.
38f. **Merge-queue awareness reads the field GitHub actually exposes, and
    never guesses when it cannot.** `test/merge-queue.test.sh` passes against
    a stubbed `gh`: `merge_queue_probe` reports `queued: true`/`false`
    correctly from a fixture GraphQL response; a dequeue event's `createdAt`/
    `reason` are reported whether or not the pull request is currently
    queued (re-queued-since is the caller's own `queued == "false"` gate, not
    this function's); a `gh` failure and a malformed response (a `queued`
    key present but not a boolean) both return non-zero with no output a
    caller could mistake for a real answer; and bad arguments (an empty
    slug, an empty or non-numeric number, a slug with no `/` or with more
    than one) are rejected before ever calling `gh`, while a slug whose
    repository is named the same as its owner is probed like any other.
    `test/merge-queue.test.sh` also passes `merge_queue_dequeue_actionable`
    against every reason value verified live (`"manual"` and `"merged"`
    false; `""`, `"failed_checks"`, `"merge_conflict"` and an unrecognised
    value all true) (agent-ops#394).
    `test/sweep-human-visibility.test.sh` passes
    the merge-queue cases alongside its existing ones: a currently-queued
    pull request is never idle-nudged; a checks-failure dequeue produces its
    own `dequeue-notice` action (never `nudged`) even with
    `human_nudge_idle_hours: 0`, naming the removal time and reason and
    carrying the `agent-ops:merge-queue-dequeued:<time>` marker; an
    already-notified dequeue is not notified again, while a later, fresh
    dequeue still gets its own `dequeue-notice`; a pull request re-queued
    since a recorded dequeue event gets neither a notice nor a nudge; an
    unreadable merge-queue probe leaves the ordinary idle nudge (still
    `nudged`) behaving exactly as it did before this requirement existed; a
    failed dequeue-notice POST is a `warning`, never silence; a `"manual"`
    dequeue gets no notice even though it is otherwise fresh and
    unacknowledged (agent-ops#394); a dequeue older than
    `merge_queue_dequeue_notice_max_age_hours` gets no notice even though it
    carries an actionable reason and no marker is on the pull request yet
    (agent-ops#394); and `merge_queue_dequeue_notice_max_age_hours: 0`
    disables the notice outright, even for a same-second dequeue whose age
    (`0`) does not exceed the zero-width threshold arithmetic alone would
    apply (agent-ops#429).
38g. **Requirement 38c's ruleset dependency is reported, not silent
    (agent-ops#391).** `test/doctor.test.sh` passes, over the same
    single-target-repo fixture and `gh`/`rulesets` stub requirement 25a's own
    ruleset-drift cases (acceptance check 8m) use: an active default-branch
    ruleset whose `pull_request` rule carries `required_approving_review_count:
    1` is `ok`, naming the count; the same with `0` is a `warn` naming
    agent-ops#391 and stating this is informational, not a requirement 38
    fault; an active default-branch ruleset with no `pull_request` rule, and
    no active ruleset targeting the default branch at all, are both the same
    `skip`; an unreadable `rulesets` endpoint is its own `skip`; two active
    default-branch rulesets requiring `0` and `1` report the strictest — `ok`
    at `1` — in both list orders, so the verdict does not depend on what the
    API returned last; and none of these fail `doctor.sh` itself.
39. **Finish-then-continue's chain decision is a pure, tested function of what
    a cycle already gathered.** `test/chain.test.sh` passes: `chain_sources_remain`
    sums `.sources` across every repo, zero when every repo's is empty, summed
    across repos rather than stopping at the first; `chain_should_continue`
    chains when at least one source remains and the cycle's own place in its
    lineage is still under `max_chained_cycles`, stops exactly at and past the
    cap (including `max_chained_cycles: 1`, which disables chaining outright
    even on the first cycle), and fails closed (never chains) on a
    non-numeric `chain_count` or `max_chained_cycles`.
39a. **The chain only ever launches when it should, and never waits on what it
    launches.** `test/finish-then-continue.test.sh` passes, against the real
    `cleanup` block lifted out of `agent-cycle.sh`: `chain_eligible=1` with
    `exit_code == 0` launches exactly one child, carrying
    `AGENT_CYCLE_CHAIN_COUNT` incremented from wherever this cycle's own
    stood and the original argv verbatim (including an empty one, replayed
    as no argv rather than a stray token); `chain_eligible=0` never launches
    one, regardless of exit code; `chain_eligible=1` with an untrapped
    non-zero exit or a signal's 128+n never launches one either; a
    *handled* ending (exit 0, the same as a stand-down) still does, since
    the item's own disposition must not stall the fleet from picking up a
    different one sooner; and the parent's own exit is never delayed by a
    slow child, confirmed by timing a run against one that sleeps. The
    launched child inherits **no** ignored signal disposition — asserted by
    having it report back which of `TERM`, `INT` and `HUP` arrived already
    ignored, which must be none — so a chained cycle stays killable by
    requirement 1's takeover and by a container stop.
39b. **A sub-hourly cycle interval is an explicit cron minute list, correct at
    every occurrence, and backward-compatible at the boundary.**
    `test/render-crontab.test.sh` passes: the rendered cycle line lists the
    node's own minute then every `schedule.cycle_interval_minutes` after it
    while still under 60, each occurrence *dropped* (not shifted) when it
    lands on an excluded minute rather than the whole render failing;
    `cycle_interval_minutes: 60` reproduces the exact single-minute,
    once-per-hour line every release before the key existed rendered;
    `cycle_interval_minutes` outside 1..60, non-numeric, or absent-with-no-
    default all leave the baked crontab untouched, the same fail-safe
    every other malformed schedule key already gets. `test/doctor.test.sh`
    passes: the crontab report names the full comma list, not just the
    first occurrence.
39c. **A pending image roll overrides an otherwise-eligible chain, never
    grants one, widens the gap at every clean, non-`--once`, non-`--dry-run`
    cycle-end whether or not there was a chain to give up, is honoured at
    the hook against `lock.json` alone, is cleared once landed, and — while
    it is not — idles the next cycle at most once rather than letting it
    run underneath the
    marker** (requirement 39c (Finish-then-continue), agent-ops#1096, amended by agent-ops#1102,
    widened by agent-ops#1103). `test/chain.test.sh` passes: `chain_image_behind` reads
    true only for a `{"status":"behind",...}` verdict — "current",
    "unverified", the JSON literal `null` and malformed input all read false
    — and `chain_write_roll_pending` writes `$state_dir/roll-pending.json`
    naming a bare ISO-8601 `until` `schedule.cycle_interval_minutes` minutes
    out (falling back to the schema default of 15 on a non-numeric argument),
    creating `state_dir` if it does not yet exist. `chain_clear_landed_roll_pending`
    removes that same file unless the verdict handed to it still reads
    "behind" — "current", "unverified", `null` and no argument at all every
    clear it — and does nothing, without error, when the file is already
    absent. `test/finish-then-continue.test.sh` passes, against the same
    real `cleanup` block as 39a, now driven with a stubbed `image_drift_
    status`/`agent_ops_version`: a "behind" verdict cancels an otherwise
    chain-eligible, exit-0 cycle and writes the marker; a "current" verdict
    still chains and writes no marker; a cycle with no chain to give up
    (`chain_eligible=0`) still writes the marker on a "behind" verdict,
    chaining nothing since there was nothing to cancel; a `--once` run never
    writes the marker on a "behind" verdict either, nor does a `--dry-run`
    run (agent-ops#2103) — both cases still gated ahead of `chain_eligible`
    since neither a real `--once` nor a `--dry-run` run is ever chain-eligible
    to begin with; and a cycle that did not end cleanly (a non-zero exit)
    never even reaches the check, marker included. `test/watchtower-pre-update.
    test.sh` passes: an unexpired `roll-pending.json` makes the hook exit 0
    despite a live lock naming a live process in the hook's own container,
    when that lock is `lock.json` — but never when it is `review-lock.json`,
    which still defers on its own ordinary judgement regardless of the
    marker, and whose deferral the hook's own output never misdescribes as
    an override; the override's own sign-off names the marker's authority
    rather than the idle path's "no cycle in flight", which would contradict
    the in-flight line the same run already printed; an expired or
    unparseable marker leaves the ordinary lock-based judgement unchanged; no
    marker at all behaves exactly as before the marker existed.
    `test/state-sync.test.sh` passes:
    `roll-pending.json` does not replicate to a peer's branch, alongside the
    other live locks.

    The one case `chain_clear_landed_roll_pending` leaves open — a verdict
    still reading "behind" — is covered the same way (agent-ops#1102 option
    2). `test/chain.test.sh` passes: `chain_roll_pending_live` reads true only
    for a marker naming an `until` that has not yet passed, the identical
    parse `roll_pending_allow` uses; `chain_updater_should_standdown` reads
    true only for `updater_status`'s own `"deferring"` or `"stuck"`/`reason:
    "defer"`, never `"rolled"`, a bare `"stuck"`/`reason:"allow"`, `null`, or
    malformed input; `chain_roll_standdown_available` reads true only when
    `$state_dir/roll-standdown.json` is absent or its `count` is exactly `0`,
    failing closed (false) on an unreadable file or a non-numeric `count`;
    `chain_roll_standdown_record` creates that file at `count: 1` with a fresh
    `since` and increments an existing one while preserving its `since`; and
    `chain_clear_landed_roll_pending` now also removes `roll-standdown.json`
    alongside the marker once the verdict stops reading "behind", never while
    it still does. `test/roll-standdown-wiring.test.sh` passes, against the
    real post-`acquire_lock` block lifted out of `agent-cycle.sh`: a live
    marker with an eligible updater verdict logs a `stand-down` naming `cause:
    "roll-pending"` and the marker's own `until`, sets the node-state terminal
    to `externally-blocked`/`roll-pending`, records one stand-down against the
    cap, leaves `roll-pending.json` byte-identical to what it found (writing
    no new one), and exits before the block's own end; the same marker with a verdict
    idling cannot fix (`"rolled"`, `"stuck"`/`reason:"allow"`, or `null`) runs
    normally with nothing logged; an expired marker is left alone for its own
    clock; and a second eligible cycle under a marker whose cap is already
    spent logs a `roll-standdown-capped` event naming the marker and the spent
    count instead of standing down, then still reaches its own end.
17e. **Contended-claim-loss reporting is correct per node and per era
    (component 21).** `test/pickup-metrics.test.sh` passes against a fixture
    union log: `selection` and `claim-lost` events split "before"/"after" at
    each node's own first `chained` event, never at a fixed timestamp; a node
    with no `chained` event in the fixture falls wholly in "before"; a
    contended count includes `held` and `pr-held` `claim-lost` causes and
    excludes every other cause, including a line carrying no `cause` at all; a
    malformed trailing line is skipped rather than aborting the read; and
    `--since` bounds the window reported. `scripts/pickup-metrics.sh` passes
    `shellcheck`.
8s. **The Approver runs only above `human`, picks its tier correctly, and
    refuse-wins (requirements 8b, 8c).** `test/approver.test.sh` passes
    against a stubbed `gh`: `approver_tier_for` maps `low`/`medium`/`high` to
    `trivial`/`standard`/`high` and anything else to `standard`;
    `approver_model_for_tier` picks `MODEL_COMPLEX` only for `high`;
    `approver_refuse_streak` counts a login's own trailing
    `CHANGES_REQUESTED` reviews correctly over the line-per-review shape
    `--paginate --jq` emits — the aggregation runs once over every page's
    lines at once, so no page boundary is observable to it — stopping at that
    login's own most recent `APPROVED`, ignoring `COMMENTED` and `DISMISSED`,
    ignoring another account's reviews entirely, reading `0` for a login that
    never reviewed — and returns non-zero, printing nothing, when the list
    itself could not be read; `approver_post_review` posts with `GH_TOKEN` set
    for that one invocation only, never leaking into a later call under the
    stub's own default identity; `approver_prior_refusal_bodies` returns the
    same login's `REQUEST_CHANGES` bodies oldest-first and nothing on an
    unreadable list. `approver_post_or_warn` itself (agent-ops#1082, against
    the same `lib/github-limit.sh` sourced ahead of `lib/approver.sh` a real
    caller always has): a write refused by a secondary rate limit is retried
    once and reaches GitHub on the retry, `approver_last_post_ok` reporting
    `1` and no warning logged at all; a write still refused by that same
    limit after the retry logs a `warning`, with `approver_last_post_ok`
    reporting `0`, naming the rate limit distinguishably from a generic
    refusal and saying a retry was made; and a generic (non-rate-limit)
    refusal is not retried at all — one POST attempt only — and keeps the
    original, unchanged "GitHub refused the write" wording. `approver_escalate`
    composes the escalation issue's "Why the pipeline is blocked" paragraph
    from the condition it was told fired (agent-ops#1214): the `escalate`
    condition's body says the adjudication judged it a genuine judgement call,
    the `recurring-refuse` condition's says the disagreement kept recurring and
    never that the adjudication could not resolve it, and a condition it was
    not given keeps the "could not resolve the disagreement" wording an
    unparseable or unusable verdict earns — while the `pr-<n>-approver-
    adjudication` item ref `create_escalation_issue` dedups on, and the
    adjudication's own reasons, stay the same under every one of them.
    `test/approver-wiring.test.sh` lifts `run_approver_stage`,
    `approver_post_or_warn` and `approver_stage_complexity` verbatim out of
    `lib/approver.sh` and drives them with every GitHub call, model launch and
    log write stubbed: at a genuinely configured (or manually killed)
    `merge_autonomy: human` the stage posts no review, launches no model and
    logs nothing at all, having asked `merge_autonomy_kill_state` for a
    *fresh*, *retrying* read (requirements 2.3a, 8b's own fail-closed
    distinguishing behaviour, agent-ops#1081) rather than the
    process-lifetime memo. A stubbed fail-closed read (`.record.kind ==
    "fail-closed"`) — unlike the genuinely configured case — logs exactly one
    `warning` naming the pull request, the kill flag, and the cause, marked
    `fail_closed: true`; `retried: true` when the stub reports the retry was
    taken, and the warning's own detail says so; either way
    `merge_autonomy_effective_level` itself is never even asked, since a
    fail-closed `human` is decided by the kill switch alone. At
    `agent-approves` a
    `complexity:low` pull request gets a deterministic `APPROVE` with no
    model launched, `medium` and `high` launch `approver_model_default` and
    `approver_model_complex` respectively — the launched prompt assembled
    with an empty overrides object even when the harness's
    `prompt_overrides` carries a poisoned `approver` key (requirement 4a's
    lock) — a refusal's `reasons` become the
    `REQUEST_CHANGES` body, and a synthetic refuse streak of two routes the
    next round to `approver_model_critical` — for a `complexity:low` pull
    request too, which the grade alone would have approved without a model at
    all. Each failure path returns 0 having posted nothing and logged a
    `warning`: the stage disabled (`approver_model_default` empty), the
    credential absent, a verdict that would not parse, a verdict the Script
    does not recognise, and a review GitHub refused. An adjudication `refuse`
    below the recurrence threshold posts `REQUEST_CHANGES` and escalates
    nothing on its own; at the threshold (a refuse streak of four — the third
    consecutive adjudication `refuse`) it also escalates, and an adjudication
    `escalate` (or an unparseable/failed verdict) escalates regardless of the
    streak — the escalation issue's own body naming which of those three
    conditions triggered it (agent-ops#1214). `approver_stage_complexity`
    (requirement 8b) is exercised
    separately: given a pre-Reviewer `rev_complexity` of `medium` and a
    stubbed `gh pr view` reporting the PR now carries `complexity:high` — the
    Reviewer's own mid-round correction — it resolves `high`, and that `high`
    reaches `run_approver_stage`'s own tier choice (`approver_model_complex`
    launched, logged as the high tier), confirming the raise reaches the same
    round's Approver rather than only the next one; a `gh pr view` reporting
    no change, or an unreadable label, leaves `rev_complexity` unchanged.
    Every `approver-verdict` the stage logs carries the `repo` it ran for, the
    `model` that reached the verdict — empty on the deterministic Trivial
    tier, which launches none — and `posted` (requirement 33): `true` where
    the review reached GitHub, `false` both for a write GitHub refused
    despite an `approve` verdict and for a verdict that attempted no write at
    all (an adjudication `escalate`, or a verdict the Script does not
    recognise).
    `scripts/doctor.sh` fails a `merge_autonomy`
    above `human` configured with `approver_model_default` empty, the same
    shape its existing `approver_app_id` pairing check already fails on
    (`test/doctor.test.sh`).
