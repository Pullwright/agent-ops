## Acceptance checks

### Acceptance checks — continued (part 9 of 10; items 8q–11d)

8q. <a id="impl-ac-8q"></a>**A void shape with no closed-object or register-resolved signal still
   retires, once its source stops yielding it (requirement 34n's liveness
   rule, TD-PPagop-26081303).** `test/cycle-state.test.sh`'s
   `void_liveness_actioned` section passes, against `lib/void-liveness.sh`:
   for each of the five structured-gather shapes (an alert ref, a
   `failed-run-` ref, a merge-conflict ref, a
   `pr-<n>-dequeued-<head-sha>` ref, a `human-visibility-<hash>` ref), an id
   still present in GATHER_JSON's `ids` for its repo+shape is never actioned,
   however old; an id absent from a `{ok: true}` gather is actioned, tagged
   `liveness-<shape>`; an id absent from a `{ok: false}` gather, or from a
   repo/shape GATHER_JSON carries nothing for at all, decides nothing — the
   same "unknown is not gone" rule requirement 34i's own clearances observe;
   a same-numbered id in a different, unlisted repo is untouched; a
   repo-less (hand-appended) void matches no shape's repo lookup; an id
   shaped like none of the five is ignored; and malformed `VOID_JSON` or
   `GATHER_JSON` fails safe to `[]`. The `void_review_plan_actioned` section
   passes the same way for the two on-demand-reader shapes: a project-review
   ref is actioned once a status map reports `"merged"`, an
   implementation-plan task id only once it reports `"done"`, anything else
   (including a malformed status map) decides nothing. The same section pins
   the `review-superseded` signal (TD-PPagop-26082309) against
   `REVIEW_CURRENT_JSON`, the fourth input: a review ref whose embedded date
   matches the repo's current review folder is not actioned however old, one
   whose date differs is actioned as `review-superseded` — every such ref in
   the repo, not just one — an empty-string date (no review folder at all)
   actions every review ref in that repo, a repo the map carries no entry for
   at all actions none of its refs, `review-merged` still wins for a ref a
   merged pull request names, and a malformed fourth input decides nothing.
   Both sections also
   pin the two remaining halves of the requirement: an actioned-and-old
   liveness or review/plan pair reaches `retire_void_items` and is dropped
   exactly like an object-closed or register-resolved one, an
   actioned-but-young pair is kept, and a `void-retired` fact already on the
   log still masks a liveness-retired id via `subtract_retired_voids` — the
   same round-trip the register-resolved path already proves, now covering
   every shape the rule actions.
8r. <a id="impl-ac-8r"></a>**A void whose source or repo the config has dropped retires too
   (requirement 34n's config signal, PR #340's review).**
   `test/cycle-state.test.sh`'s `void_config_actioned` section passes,
   against `lib/void-liveness.sh`: an entry naming a repo the configured
   array does not list is actioned as `repo-dropped` whatever its shape,
   including the bare-issue shape and the `pr-<n>-…` shapes that are neither
   `-conflict-` nor `-superseded-`, off which no
   `source-dropped` verdict can be read; an entry whose shape names a
   source the repo still lists is never actioned; an entry whose shape names
   a source the repo no longer lists is actioned as `source-dropped`, tested
   for each of the eight mapped shapes; the alert shape stays live while
   *either* `security` or `code-quality` remains, and retires only when both
   are gone; a bare issue number and a `pr-<n>-stale` in a *configured* repo
   are never actioned however few sources remain; a repo-less void is
   skipped; and an empty, non-array or malformed repo array decides nothing
   rather than retiring the whole extract. A void recorded under a
   configured repo's `previous_slugs` alias is resolved to that repo's
   current slug before either test (agent-ops#2455): it is never
   `repo-dropped` while the repo it was renamed from stays configured under
   its new slug, it is `source-dropped` precisely when the resolved repo's
   `sources` omits the shape's source, and a void under a
   genuinely unconfigured slug — one no `previous_slugs` entry names — is
   still `repo-dropped`. The section also pins the age
   half — an actioned-and-old config pair reaches `retire_void_items` and is
   dropped, an actioned-but-young one is kept — and, in `agent-cycle.sh`, that
   the array read is `all_repos_json` rather than the `--repo`-filtered
   `repos_json` or the back-pressure-narrowed `ordered_repos_json`.
8k. <a id="impl-ac-8k"></a>**The changelog-section gate applies to every target repository, not only
   the one carrying the workflow (requirement 25c, agent-ops#1808).**
   `test/changelog-section-gate.test.sh` passes against a stubbed `gh`, on
   acceptance check 8p's own pattern: `changelog_section_gate` reads a pull
   request's body and title and reports the checker's own verdict as `clean`
   or `dirty<TAB>reason` — a `chore`/`docs`/`refactor` title with no
   `## Changelog` section is clean, a `feat`/`fix`/`perf` title (or any type
   carrying `!`) with a well-formed section or `None.` is clean, and the
   same title with no section, or a malformed one, is dirty naming the
   fault. Separately, the cases where the question could not be put report
   `unknown` and exit 0: an unreadable pull request, an answer carrying no
   title (which must never read as clean — an empty title reads to the
   checker as "owes nothing", the shape of a *passing* pull request), and a
   checker that cannot be run. An empty URL remains `dirty`, and none of
   these is a crash.

   What `agent-cycle.sh` and `lib/handoff.sh` then *do* with each verdict is
   asserted separately: `test/closing-keyword-wiring.test.sh`, extended
   alongside its existing closing-keyword assertions, covers the
   Implementer-side call — a `dirty` verdict carries on into the Reviewer
   stage holding the fault and reaches the Reviewer as a second
   `## Script findings` entry beside a closing-keyword one where both fire;
   an `unknown` one warns and hands the Reviewer nothing; a clean one does
   neither. `test/handoff.test.sh`'s `handoff_complete_review` section,
   extended with a `changelog_section_gate` stub beside its existing
   `closing_keyword_gate` one, covers the Reviewer's-handoff call: a `dirty`
   verdict (with the closing-keyword gate clean) makes `safe` false without
   running the reconciliation gate or the draft flip, and an `unknown`
   verdict does not.
9. <a id="impl-ac-9"></a>A cron-style invocation from a minimal environment can resolve `claude`
   and run `claude -V` (or a tiny `claude -p` smoke test) successfully.
10. <a id="impl-ac-10"></a>One supervised full cycle (`--once`) against whichever repo the ordering
    picks: it produces a labelled, mergeable, ready-for-review PR with the
    originating register updated and a complete log trail. Report the PR URL
    to the human rather than merging anything.
11. <a id="impl-ac-11"></a>**The eligibility rule round-trips through the real extract
    (requirement 35a).** `test/enabler-eligibility.test.sh` passes: an
    `attempt-failed` plus `enabler_after_coordinator_cycles` synthetic
    coordinator `stage-end`s (`exit_code: 0`) makes the item eligible with reason
    `threshold`, one fewer does not, and a `stage-end` that timed out or belongs
    to another stage does not count at all — that last assertion is the one that
    catches a rule keyed on an event nobody emits, which would engage nothing,
    forever, while reading correctly. An examined item is not re-examined; an
    `item-void` for the same item excludes it; a re-block re-enters via
    `threshold` — except the one shape that must not, a `needs-refinement`
    re-flag landing after an already-closed escalation the item was refined
    before, which stays `issue-closed` so the human's close is not stranded
    (TD-PPagop-26082901), while an examination since that escalation, an
    ordinary re-flag, and a re-flag with no prior refinement each get no such
    exemption; and every boundary is asserted on both sides of itself, because
    too permissive spends Opus in a loop and too strict never escalates at all,
    and both look like a quiet pipeline. A block behind only a phantom
    `item-refined` event (`comment_url` a bare issue URL, no
    `#issuecomment-`/REST-API comment anchor — #818's and #874's own shape,
    TD-PPagop-26082819) derives a `null` `refined_before` and logs a warning
    naming the phantom's timestamp and repo+item; a genuine refinement is
    still found behind an earlier or a later phantom, in either order; a
    spec-carrying (non-issue) event, which has no `comment_url` to test at
    all, is never treated as phantom; and one item's phantom does not
    suppress a *different* item's genuine refinement stamped in the same
    second, since the log is fleet-wide and `log_event`'s timestamps are
    whole-second, so the phantom set is matched on the whole
    `{repo, item, ts}` triple rather than on `ts` alone. Clause 5 is asserted
    on both sides too: a `threshold` candidate whose thread still names an
    open `Blocked-by:` reference is deferred and logs one
    `enabler-dependency-deferred` naming the item and the reference, the same
    candidate is engaged once the reference closes and engaged anyway once
    past the age bound, and an `issue-closed` or `recheck` candidate is
    engaged without its thread being fetched at all. One assertion is about
    the wiring rather than the rule — the predicates the clause needs are
    defined by some library `agent-cycle.sh` sources — because the clause
    skips itself when they are not, and a rule that silently skips itself
    reads exactly like a rule with nothing to defer.
11a. <a id="impl-ac-11a"></a>**The fingerprint wakes a quiet fleet at the threshold, and lets it go
    quiet again (requirement 35b).** In `test/noop-skip.test.sh`, per the same
    discipline as the abandoned-drafts trap: an item entering the eligible set
    changes the fingerprint, its `reason` flipping to `issue-closed` changes it,
    the set emptying after an engagement changes it, and an input recorded before
    the Enabler's keys existed canonicalises exactly as one carrying them empty.
    Without the first three, the escalation path comes due on a quiet week and
    nothing runs until the forced recheck; without the fourth, adding the feature
    would appear to change every replayed cycle.
11b. <a id="impl-ac-11b"></a>**An open escalation is invisible to the Co-Ordinator and to the Enabler.**
    Assign an issue and confirm requirement 16.4 excludes it from candidacy, and
    that the same issue's number in the repo's open-issue digest makes its item
    Enabler-ineligible. Then the half that closes the loop: with the issue gone
    from the digest, the item is eligible with reason `issue-closed`, and after
    the verification's examined event it is not eligible again. This is the check
    that the protocol the issue promises its reader — close it and the work
    resumes — is the protocol the code implements.
11d. <a id="impl-ac-11d"></a>**An under-specified item is reported, blocked, refined and carried
    forward (requirements 16a, 34e, 35d, 36b, 3h).**
    `test/needs-refinement.test.sh` passes: a well-formed report becomes a
    coordinator-stage `attempt-failed` marked `kind: "needs-refinement"` whose
    `unblock_condition` is the report's `missing`, while an entry short of any
    required field is dropped; the label is projected onto an issue-type item
    and not onto a tech-debt one, and is found for removal when the block clears
    and when the item is voided; such a block is Enabler-eligible on the
    ordinary `enabler_after_coordinator_cycles` threshold and its entry carries
    `kind` and `refined_before`; the per-engagement cap keeps ordinary items and
    drops refinement items beyond it, `0` removing the class entirely; an
    `unblocked` verdict's `refined_spec` becomes an `item-refined` event that
    reaches the next cycle's `refinements` map, and a void item's does not; and
    a second refinement of an already-refined item is refused unless a human has
    just closed an escalation about it. `test/enabler-verdicts.test.sh` passes:
    driving `maybe_run_enabler` itself with an `unblocked` verdict on an item
    carrying `refined_before` produces no `unblocked` and no `item-refined`
    event, only a `warning` and an `enabler-examined` event whose `outcome` is
    `refinement-refused`; the same item with reason `issue-closed` is not
    refused. Both directions matter here for the same
    reason as requirement 35a's rule: too eager and two models re-specify each
    other's work forever, too shy and the item starves exactly as it did before
    any of this existed.
11d-i. <a id="impl-ac-11d-i"></a>**An escalation the Script did not file is never claimed on the work
    item's thread (requirement 36b).** `test/enabler-verdicts.test.sh` passes,
    on both halves of the reconciliation — the call and the comment.
    Driving `maybe_run_enabler` itself with an `escalate` verdict on a
    `needs-refinement` item whose ref is a bare issue number:
    `escalation_thread_reconcile` is called exactly once per engagement, with
    `escalated` and the filed issue's real number and URL when
    `create_escalation_issue` succeeds; with `adjudicated-adequate`, and no
    number, when an `adjudicate-first` pass settled the disagreement before
    `create_escalation_issue` was reached at all — asserted with a
    `create_escalation_issue` stub that fails the run outright if it is
    called, since that path is the one the #604/#613/#640 incident actually
    took and the one nothing covered; and with `escalation-failed`, and no
    number, when the filing itself returns 1. A TD-shaped item calls it on no
    path, the scope requirement 36b states. Then the comment those calls
    produce, asserted against the real function: the `escalated` body's
    `Blocked-by: #<n>` line is read back by `dependency_refs`
    (`lib/dependency-gate.sh`) — the reader `scripts/gather-issues.sh`'s own
    exclusion depends on, not a literal-text match — while both correcting
    bodies say plainly that no escalation was filed **and** carry no
    `Blocked-by:` reference at all, so a withdrawal can never read as a live
    dependency to the next gather. Every body opens with the Script's own
    `pipeline_comment_header` and closes with the cycle's own marker. Nothing
    at all is posted for an `escalated` outcome carrying no number, or for an
    outcome this function does not recognise: the failure this requirement
    exists to end is a comment asserting an escalation that does not exist,
    so silence is the only safe answer to an outcome it cannot describe.
    **A repeated `escalation-failed` outcome does not repeat the comment
    (agent-ops#998).** `test/enabler-verdicts.test.sh` passes: with
    `escalation_thread_failed_already_posted` stubbed to return the thread's
    literal most recent comment (via a fake `gh api … issues/…/comments`
    read), an identical prior `escalation-failed` reconcile — posted under a
    different cycle id and a different pipeline actor — is recognised as
    such and the second call posts nothing at all, with no `gh` write of any
    kind; and a human comment landing on the thread after that same prior
    reconcile breaks the streak, so the next `escalation-failed` outcome
    posts a fresh correcting comment rather than staying silent.
