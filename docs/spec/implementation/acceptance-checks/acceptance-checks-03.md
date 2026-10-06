## Acceptance checks

### Acceptance checks — continued (part 3 of 6; items 7g–11e)

7g. **A candidate's refinement is made to trace back to it, and one that
   cannot be is skipped rather than claimed (requirement 17f, agent-ops#626,
   agent-ops#767).**
   The repair half is proven alongside the check: a work order missing its
   refinement comment is repaired and then passes the check it had just
   failed, with the comment landing verbatim in `context` and everything the
   order already said left intact; a recorded `spec` absent from `context` is
   repaired the same way; a `comment_url` naming a *different* issue is never
   repaired and spends no `gh` call proving it; a compliant work order is not
   touched at all; and an unreadable refinement leaves the candidate exactly
   as it was. The claim loop is asserted to attempt the repair before
   skipping, and to count an unrescued fault separately from both the
   pre-claimed skips and the race losses, so a traceability stand-down can
   never again be reported as `raced`. `test/finish-then-continue.test.sh`
   passes, against the real stand-down block lifted out of `agent-cycle.sh`:
   a cycle whose every candidate is untraceable stands down with
   `cause: "untraceable"`, its own `trace_faults` count, and never chains;
   a genuine race loss alongside one or more untraceable faults still reads
   `raced` and chains like any other raced stand-down.
   `test/refinement-traceability.test.sh` passes, against
   `refinement_traceability_fault` (and the `_traceability_normalize` helper
   it calls) lifted verbatim from `lib/candidate-select.sh`:
   a
   candidate whose recorded `spec` is absent from its own `context`, or
   whose recorded `comment_url` names a different issue than the candidate's
   own `item`, is faulted with no `gh` call at all; a candidate whose
   `comment_url`'s own issue number matches but whose actual comment body
   (fetched live) is present in neither `context` nor `acceptance` — the
   #571/#529 shape — is faulted after exactly one `gh` call; a candidate
   carrying its own comment or spec, normalized, in either field, passes,
   including one whose paste reflowed a line or collapsed whitespace
   (TD-PPagop-26082307), while one whose text is genuinely different still
   faults; an item with no `refinements` entry, or one recorded under a
   different repo, is not checked and costs no `gh` call; a malformed
   `refinements` document fails open rather than faulting the candidate; and
   an unreachable GitHub now faults the candidate (`untraceable`, same as a
   mismatch) rather than passing it, with the failed read reported through
   `guard_warn` rather than swallowed. A `comment_url` in the REST API form
   (`.../issues/comments/<n>`) is now checked rather than silently waved
   through — `refinement_comment_url_id`'s two recognised shapes
   (TD-PPagop-26082603), pinned with both a passing and a faulting comment
   under that shape — and a `comment_url` matching neither known shape now
   faults (no `gh` call, no `guard_warn` — the same terms the structural,
   wrong-issue check already uses) rather than the pre-fix "no fault having
   tested nothing at all". The same test pins the scoping: a
   candidate `fallback_select_candidate` itself picks for a spec-refined item
   does not satisfy the normalized check, and the claim loop's own call site
   guards the check with `selected_by_fallback` so that candidate is never
   faulted.
7h. **Retired (requirement 17g, agent-ops#1156, resolving TD-PPagop-26090604).**
   This check existed to verify a trimmed candidate's `acceptance` against
   the item's own live text — `item_live_text`, `item_text_fault` and
   `item_text_supply` in `lib/candidate-select.sh`, exercised by
   `test/item-text-fabrication.test.sh`. Requirement 17h (agent-ops#769) made
   every `issues`/`tech-debt` candidate's `context`/`acceptance` a Script
   composition from a live read, which removed the condition — a model's
   paste of a possibly-trimmed extract — this check existed to catch; once
   nothing reaching the claim loop from either source could still be that,
   agent-ops#1156 removed the checked functions and retired
   `test/item-text-fabrication.test.sh` with them. There is nothing left
   here to verify. See requirement 17g's as-built note for the history.
8. **A no-op Implementer is recorded.** Drive one cycle in which the
   Implementer reports `blocked` without opening a PR: the cycle must exit 0
   having logged an `attempt-failed` carrying that item and the stage's own
   reason — not die part-way, and not log nothing. Under `errexit` this is
   where a helper returning "not found" as a non-zero status silently kills
   the run (requirement 9).
8e. **A stage that leaves a bare fence or a resumable session is recovered,
   not discarded (requirement 9e).** `test/extract-json-result.test.sh`
   passes: a verdict fenced ``` … ``` with no `json` info string, or with a
   different one, parses on the fenced-block fallback exactly as a
   `json`-tagged fence always did, both bash copies and the dashboard's jq
   port agreeing. `test/stage-salvage.test.sh` passes, against a `claude`
   stub that answers differently depending on whether `--resume` is present
   in its argv: `stage_salvage_result` given an `.out` file whose
   `session_id` is set and whose `result` does not parse resumes that session
   and returns the resume's own parsed verdict when the resume's final
   message does parse, logging `salvage` with `outcome: "recovered"`; returns
   nothing and logs `outcome: "failed"` when the resume's message still does
   not parse; and — given an `.out` file with no `session_id` at all —
   attempts no resume, calls `claude` not once, and logs no `salvage` event,
   since there was nothing to spend a resume on.
8a. **A void survives an agent trying to clear it.** Append an `item-void` for
   an item, then an `unblocked` for the same item, then run a cycle: the item
   must still be void and absent from the Co-Ordinator's candidates. This is
   the check that would have caught requirement 9b being collapsed into one
   state, and it fails loudly on a system that looks entirely healthy — the
   log fills with confident, correct-looking events and the same item is
   worked forever. Assert the negative too: `unvoided` *does* clear it, or you
   have built a state no human can escape.
8c. **A void must be earned (requirement 34d).** `test/void-guard.test.sh`
   passes: an entry with no `evidence` — and `null`, `""`, whitespace, `{}` and
   `[]` all count as none — is refused before any API call; an entry whose
   `evidence` is shaped `{ref, path, expect, pattern}` is fetched and tested —
   refused when the fetch fails, or the presence/absence or pattern does not
   hold, or the entry names no repo to resolve against. Assert that
   an `absent` claim rests on `404 Not Found` and on nothing else: stub a rate
   limit and an unresolvable `ref`, both of which fail the fetch exactly as a
   real absence does, and both must be refused. That is the difference between
   a checked citation and a fetch nobody looked at the answer of. Assert the
   closed-list rule itself (issue #413, WI-10): an entry whose `evidence` is
   prose fitting neither the structured shape nor a PR/commit citation, on an
   item whose id names no pull request to finish, is refused naming what was
   missing — not accepted on being merely non-empty, the fall-through
   TD26072114's void (below) walked through and issue #243 left open. Assert
   every one of the three checkable forms remains independently sufficient
   where it applies — the structured shape resolving, a citation
   corroborating, a finishing-source item's own live state — and that any one
   of them present-and-failing still refuses the void outright even when
   another form was not attempted. An entry
   whose repo+item matches a gathered candidate whose PR still changes files is
   refused naming that PR; a PR the API will not answer for is refused as
   uncorroborated; and an evidenced entry with an empty PR diff, or with no PR
   to check at all, is allowed. Assert the citation test directly: an entry
   citing a real, fetchable PR whose body and branch name neither one mentions
   the voided item is refused as a fabricated citation; the identical entry
   citing the pull request that genuinely implements the item is allowed; and
   the same shape holds for a cited commit — refused when it is not an
   ancestor of the default branch, or when it is but neither its message nor
   any pull request associated with it names the item, and allowed when one of
   those does. Assert the URL forms resolve identically: a
   `https://github.com/<owner>/<repo>/pull/<n>` or `.../commit/<sha>` citation
   is checked the same way as its bare-form equivalent, and — the case a bare
   citation cannot express — a URL naming a *different* repository from the
   entry's own `repo` is resolved against the URL's own `owner/repo`, not the
   entry's, so a PR number that would match in the wrong repository is not
   corroboration. Assert the review-ref resolver (issue #2030): a
   `review-<date>-R-<nn>` item citing a pull request whose body and branch
   name only the recommendation's own designated tech-debt id — never the
   review ref itself — is allowed once that id is resolved off a
   recommendations-file fixture; the identical citation is still refused when
   the cited pull request names neither id; and the item falls through to the
   ordinary refusal, rather than erroring, when the recommendations file
   cannot be fetched at all. Assert the finishing sources are not caught by it: an item
   `pr-<n>-abandoned-…`, `pr-<n>-review-…`, `pr-<n>-conflict-…`,
   `pr-<n>-superseded-…` or `pr-<n>-dequeued-…`
   citing pull request `<n>` in the entry's own repo is
   corroborated by fetching that PR's own live state, while the same item
   citing a *different* pull request is still refused by the ordinary
   body/branch test. Assert every live state `void_finishing_pr_reason`
   decides between, and that the item's own shape selects which reading it
   gets: a merged PR is allowed and a closed-but-unmerged PR is allowed,
   whatever the shape; a PR the API will not answer for is refused as
   unreadable. For the two closing shapes (`-abandoned-`, `-review-`, and any
   id of no recognised shape), an open PR with an empty diff against its base
   is allowed and one with a non-empty diff is refused, naming the file count
   still outstanding — *unless* the PR carries the human-applied `obsolete`
   label, which allows it outright, with the file count never even fetched;
   assert this for both `-abandoned-` and `-review-`, that an id of no
   recognised shape gets no such reading (the strict diff test only), and that
   a labelled `-conflict-`/`-superseded-` PR is unaffected — the label
   corroborates only the two shapes 34k closes on the diff claim. Assert the
   machine alternative to that label (issue #413, WI-10, design doc §5.5): at
   `merge_autonomy_level` `agent-merges-all`, with the current void's own
   evidence the structured shape and resolving, a `draft-obsolete-flagged`
   event naming this repo and item, at least 24 hours old and from a
   different cycle, whose own evidence is *also* the structured shape and
   resolves, corroborates in place of the label — and is refused if any one
   of those conditions fails: below `agent-merges-all`; the current void's own
   evidence not structured; the flag younger than 24 hours; the flag from the
   same cycle; the flag's own evidence not structured or not resolving; or the
   flag naming a different repo or item. For
   `-conflict-`, an open PR is allowed whatever its
   diff unless `mergeable` is `false`, so assert all three readings of that
   field: `true` allowed, `null` allowed (not yet computed is not
   definitively conflicting), `false` refused naming the conflict rather than
   the diff — including when `user.login` is `dependabot[bot]`, which buys
   this shape nothing since TD-PPagop-26081304 moved that excuse to
   `-superseded-`. For `-dequeued-` (requirement 3z, TD-PPagop-26081409),
   which 34k likewise closes nothing for, assert the two-part live re-check
   and both of its ambiguous-accepts directions: an open PR still at the head
   SHA the item's own id embeds whose `merge_queue_probe` still reports
   `queued: false` is refused naming the dequeue rather than the diff; the
   same PR corroborates once the probe reports it re-queued, once its current
   head has moved past the SHA the id names (asserted without the probe
   answering at all, so the head check alone decides it), and when the probe
   cannot answer — the same asymmetry `-conflict-`'s `null` mergeable gets.
   For `-superseded-` (requirement 3s, TD-PPagop-26081304), an
   open PR is corroborated only when **both**, re-derived live, hold: assert
   all four combinations — `user.login` is `dependabot[bot]` and
   `dependabot_newer_open_pr` (re-run against a stubbed currently-open
   Dependabot PR list) still names a strictly-newer open bump of the same
   family is allowed; either the author is not Dependabot's, or no such newer
   bump is open now, is refused naming which half failed; the PR's own
   `mergeable` field is irrelevant to this shape, so assert a still-open,
   still-superseded PR is allowed whether `mergeable` reads `true`, `false`
   or `null`. Assert the id shortcut is
   slug-gated: the same item citing number `<n>` by a URL naming
   a *different* repository is fetched — refused when the fetch fails, and
   refused when the fetched body and branch name no item — and an entry
   naming no `repo` at all whose URL citation's fetched body does name the
   item is allowed, corroborated by the live test it fell through to rather
   than by the number. Assert it runs with `repos: []` exactly
   as the Enabler's and the Implementer's calls do, and with `repos`
   populated exactly as the Co-Ordinator's own call is — the candidate
   carrying the synthetic id in `ref` and its `item` as the gatherers leave
   it, so that both call shapes reach the same finishing-source verdict, in
   both directions: the live-state fetch needs no candidate list, and the
   candidate test can never match one of these items. Assert the shape split
   end to end on the case that separates them: a `-conflict-` void of a pull
   request that is open, mergeable again and still carrying its full diff is
   recorded, while an `-abandoned-` void of a pull request in that same state
   is refused. Then drive it end to end: a
   Co-Ordinator returning a `voided` entry the guard refuses must produce an
   `attempt-failed` for that item and **no** `item-void`, and the next cycle
   must list the item as blocked rather than void. The negative matters as
   much — assert a well-formed void is still recorded, or the guard has
   quietly abolished a feature requirement 18 depends on to avoid full
   Implementer runs. `test/enabler-verdicts.test.sh` passes: driving
   `maybe_run_enabler` itself with an unevidenced `void` verdict produces the
   same `attempt-failed`, plus an `enabler-examined` event whose `outcome` is
   `void-refused` — the Enabler's own guarded path, not only the
   Co-Ordinator's. Assert `flag_obsolete` too: a `still-blocked` verdict
   carrying it, a `pr_url` and structured, resolving `evidence` produces
   exactly one `draft-obsolete-flagged` event naming the repo, item and the
   pull request number read out of `pr_url`, and never an `item-void`; the
   same verdict with prose evidence, or with no `pr_url` on the item, produces
   no `draft-obsolete-flagged` event and a `warning` naming which precondition
   failed.
8d. **A `pr-ready` event means the pull request is not a draft (requirement
   31a).** `test/handoff.test.sh` passes: a non-draft PR reports `already`
   without calling `gh pr ready`; a draft is flipped and reports `flipped`; a
   flip that exits 0 and changes nothing reports `failed`; and a PR whose state
   cannot be read reports `failed` rather than being assumed handed off. Then
   drive a cycle whose Reviewer answers `{"status": "ready"}` on a PR it left as
   a draft: the cycle must log a `warning`, take the PR out of draft itself, and
   log `pr-ready` with `handoff: "script"`. Assert against GitHub, not against
   the log — the whole defect was a log that agreed with a Reviewer nobody had
   checked.
8d-i. **A handed-off pull request is in somebody's review queue (requirement
   31b).** `test/handoff.test.sh` passes for `confirm_review_requested`: a PR
   nobody is blocking reports `none` and asks for nothing; a blocking reviewer
   with no request pending is re-requested and reported `requested`; one already
   pending reports `already` without posting again; a reviewer whose
   changes-requested is followed by a `COMMENTED` review is still asked, and one
   whose is followed by an `APPROVED` is not; a bot is never asked; a POST that
   exits 0 and changes nothing reports `failed`; and an API that will not answer
   reports `failed` rather than an assumed `none`. Then drive a cycle on a
   `review-feedback` item end to end: the `pr-ready` event must carry
   `review_requested` and the reviewer's login, and GitHub — not the log — must
   show the review pending. Assert the negative too, because it is the whole
   point of the requirement's bound: `reviewDecision` must still read
   `CHANGES_REQUESTED` and the PR must still be un-mergeable afterwards. A
   re-request that cleared the block would have moved the landing gate, not
   rung it.
8d-ii. **A `ready` verdict is confirmed against GitHub, not trusted, before any
   handoff mechanism runs (requirement 31c).** `test/review-gate.test.sh`
   passes: every required check passing is `clean`; a failing required check
   and a pull request reporting no required checks are both `dirty`, never a
   vacuous pass; a required-check list that could not be read at all is
   `unknown` rather than folded into `dirty` — but still exits non-zero,
   refusing the handoff exactly like `dirty` does (TD-PPagop-26081305). Those
   last two are asserted against the shapes `gh` itself produces, both of them
   an empty stdout and a non-zero exit told apart only by the diagnosis on
   stderr, with `gh`'s own wording in the stub for each (`no required checks
   reported on the '<branch>' branch` against a transport failure's) — a stub
   that answered the no-required-checks case with `[]` would assert a shape no
   `gh` emits and let the trap it exists for be filed as a degraded node. An
   open code-scanning alert
   with a security severity on the pull request's branch is `dirty` unless the
   same alert number is already open on the default branch, in which case it
   is `clean`; an alert with no security severity never gates; the pull
   request's alerts are read on `refs/pull/<n>/merge` and never on
   `refs/pull/<n>/head` (asserted on the ref the stubbed `gh` is actually
   asked for, because the head ref answers with an empty list and a 200 — a
   silent `clean` that leaves every other assertion here passing); an empty
   alert list is `clean` only when an analysis exists for the merge ref — with
   none, or with the existence read itself failing, it is `unknown` naming
   why, and the existence check is not spent at all when alerts are in hand
   (asserted on the endpoints the stub is actually asked for); and an alerts
   API that cannot be asked at all is `unknown` too, but exits 0 — a dirty
   verdict from either check always wins over an `unknown` from the other, and
   an unreadable required-check list, being the one that must still block,
   wins over an unreadable alerts read when both are unknown at once. Then
   drive a cycle whose Reviewer answers `{"status": "ready"}` against a
   stubbed `gh` reporting a failing required check: the cycle must record the
   same outcome as a Reviewer `blocked` verdict (requirement 32a) — an
   `attempt-failed` naming what the gate found — and must never call `gh pr
   ready` at all. Assert the two `unknown` paths separately, since they behave
   oppositely: the same cycle with the alerts read failing but required checks
   clean must still complete the handoff, with a `warning` logged rather than
   a block, so a token missing one permission cannot silently freeze every
   pull request's handoff fleet-wide; the same cycle with the required-checks
   read itself failing must instead record an `attempt-failed` exactly as the
   `dirty` case does, plus a separate node-level `warning` naming the node and
   what could not be read, and the `attempt-failed`'s `unblock_condition` must
   say to retry once a node can read GitHub again — never the required-checks-
   specific wording a genuine failure earns, which would send an Enabler
   looking for a defect that is not there.

   The same file also passes for `review_gate_unknown_streak_verdict`
   (TD-PPagop-26081404): one occurrence, and two, both print nothing — the
   threshold is not reached yet; a third *consecutive* occurrence for the same
   node prints one object naming that node, `gate: "required-checks"` and
   `count: 3`; a different node's own run stays a separate count, asserted
   both ways — the first node's run still escalates when interleaved with a
   second node's, and the second node's own count is its own, not the
   interleaved total; and a successful read (`{ok: true}`) resets a node's
   streak, seeding the next run at one rather than continuing the old one.
   For `review_gate_degraded_since`, the run's own escalation is found by its
   `first_ts`; a new run's `first_ts` matches nothing and escalates afresh;
   another node's escalation never suppresses this node's own; and an empty
   `first_ts` or stream answers not-escalated — a spurious repeat is the
   right failure mode for an alarm, a silent swallow is not.

   What `agent-cycle.sh` then *does* with each verdict is asserted separately,
   by `test/review-gate-wiring.test.sh`, against the ready-gate block lifted
   verbatim from the script — every one of the four verdicts leaves the same
   word on stdout as at least one other, so the consequence is where they are
   actually distinguishable: `dirty` records the handback naming the fault and
   ends the cycle, its bookkeeping event following `review_gate_verdict`'s
   exit status rather than the word (`{ok: false}` on exit 2, the alerts
   check outranking an unreadable required-check list, so that combination
   cannot falsely reset the streak); the blocking `unknown` ends it too but
   logs the node-level
   `warning` first and hands back the retry `unblock_condition` rather than
   the required-checks one — unless `review_gate_unknown_streak_verdict`
   (stubbed here, covered by its own test above) reports this node's streak
   has crossed the threshold, in which case the block logs one
   `review-gate-checks-degraded` event naming the count instead of the
   per-item `warning`, and only for a streak not already escalated
   (`review_gate_degraded_since`, stubbed likewise): an already-escalated
   run logs neither the repeat nor the warning, keeping the escalation one
   event per streak, while the handback is unchanged throughout; the
   non-blocking
   `unknown` and `clean` both carry on into the rest of the handoff, recording
   only the `review-gate-checks-read` bookkeeping event the streak verdict
   needs against the item. The last of those is what pins the exit status as
   the discriminator: a block that read the word alone would stall every pull
   request on a node whose token cannot see code-scanning alerts.
8d-iii. **A standing human comment is reconciled — implemented or explicitly
   contested — before a draft pull request is flipped ready, and a refusal
   survives past the round it was made in (requirement 31c, agent-ops#533,
   agent-ops#539).** `test/reconciliation-gate.test.sh` passes: no human
   comment since the anchor, or every one cited by a `<!-- agent-ops:
   reconciles comment=<id> -->` line in some comment carrying the pipeline
   marker, is `clean`; a comment from a Bot account, one performed via a
   GitHub App, or one carrying the
   pipeline marker itself, never counts as human; an uncited human comment is
   `dirty`, naming its `#issuecomment-<id>` permalink, and a partially-cited
   pair of comments names only
   the uncited one; a comment posted before the pull request's most recent
   `ready_for_review` timeline event does not count, even when an earlier
   such event exists — the maximum, not any member; with no `ready_for_review`
   event at all (a first round), the pull request's own creation time is the
   anchor instead; and the timeline, the creation-time fallback or the
   comment list each failing to read is `unknown`, never `dirty`, and exits 0
   so a caller warns rather than blocks. An empty URL is `dirty`, a bug in the
   caller. Replay PR #512's own event ordering — the human's comment, the
   draft flip, then a *later* `ready_for_review` standing in for the
   Reviewer's own step-7 flip: bounded by a round-start argument earlier than
   that flip the verdict must be `dirty` and must name the human's comment,
   while the same fixture read unbounded is `clean`, which is the whole
   reason the bound exists; the same must hold one layer down, where the
   in-round flip is the *first* `ready_for_review` event and the bounded read
   must fall back to the creation time; and where no flip happened inside the
   round, the bounded and unbounded reads must agree.

   The suite also replays PR #512's ordering across **two** consecutive
   rounds, the case the Approver review that named this defect found nothing
   in the original diff exercised: round one (bounded before the Reviewer's
   own flip and before the `convert_to_draft` a revert of it would later add)
   is `dirty`, naming the human's comment, exactly as the single-round case
   above; round two, bounded past both that flip *and* a `convert_to_draft`
   event standing in for `confirm_pr_draft`'s own revert of it, must stay
   `dirty` and must still name the same comment — not read as `clean` because
   the reverted flip is again "the most recent `ready_for_review` event at or
   before the bound." This is the anchor's own undone-event exclusion: a
   `ready_for_review` event with a `convert_to_draft` event after it, at or
   before the bound, is skipped, and the search continues past it (to an
   earlier surviving flip, or to the pull request's own creation time when
   none survives) exactly as it would if that flip had never happened.
   `test/handoff.test.sh` passes `handoff_complete_review`'s own
   composition: a dirty reconciliation gate refuses the flip with `safe:
   false` even when the review gate and the closing-keyword gate are both
   clean, calls `confirm_pr_draft` and carries its word — `reverted`,
   `already-draft`, or `failed` — in the JSON's own `revert` field, an
   unknown reconciliation verdict passes through to the flip attempt exactly
   as the other two gates' own `unknown`s do without ever calling
   `confirm_pr_draft`, and the round-start bound reaches `reconciliation_gate`
   as its second argument. `confirm_pr_draft` itself is tested the same way
   `confirm_pr_ready` is, mirrored: a draft pull request reports
   `already-draft` without attempting an undo; a ready one is reverted, and
   GitHub's own re-read — not the undo call's exit status — is what confirms
   it; an undo that changes nothing, an unreadable pull request, and a
   confirming read that fails mid-attempt are all `failed`; an empty URL is
   `failed` without asking GitHub at all; and the real call-site shape
   (`x="$(confirm_pr_draft …)" || true` under `set -euo pipefail`) does not
   abort the caller. Then drive a cycle whose
   Reviewer answers `{"status": "ready"}` against a pull request carrying an
   unreconciled human comment: the cycle must record the same outcome as a
   Reviewer `blocked` verdict (requirement 32a) — an `attempt-failed` naming
   the unreconciled comment — and must never reach the flip and re-request
   that follow the gate
   (`test/review-gate-wiring.test.sh`); a `revert` of `failed` must additionally
   log a `warning` naming that the pull request could not be converted back
   to draft, distinct from the handback itself, while `reverted` and
   `already-draft` earn no such warning; assert the same refusal, and the
   same distinct `failed`-revert warning, on the
   Enabler's `complete_handoff` recovery path (`test/enabler-verdicts.test.sh`)
   so the gate — and its revert-on-refusal — bind both callers of
   `handoff_complete_review`, not the Reviewer's alone (requirement 34a).
   Both call sites must be pinned to
   forward the round-start bound: it is a trailing positional argument, so
   dropping it silently disarms the gate rather than failing.
8e. **A pull request nobody could hand off reaches the Enabler, not the human
   (requirement 32a).** Drive a cycle whose Reviewer answers `blocked`: the
   cycle must log an `attempt-failed` for the item carrying the PR's `pr_url`,
   so that the next cycle lists it blocked and, after
   `enabler_after_coordinator_cycles`, eligible — with the `pr_url` present
   in the Enabler's runtime input. Assert the PR is *not* commented on with
   anything telling a human it is theirs, and that a bare `stage-end` is no
   longer the only record: that shape named no item, pinned no state, and is what
   let a finished draft sit unseen. Then assert requirement 32b's other end: an
   Enabler `unblocked` verdict carrying `complete_handoff: true`, on an item whose
   block `stage` is `"reviewer"` and whose `handoff_complete_review` gate is
   clean, takes the PR out of draft and logs `pr-ready` with `handoff: "enabler"`;
   the same verdict on an item with no `pr_url` is ignored without error; on an
   item whose block `stage` is anything else (`"implementer"`, `"coordinator"`,
   absent) is refused with a `warning` and no `pr-ready`, `handoff_complete_review`
   never called at all (agent-ops#440, PR #433); and on an item whose `stage` is
   `"reviewer"` but whose gate is `dirty` or whose required checks are unreadable
   is refused with a `warning` naming the gate's own finding, again with no
   `pr-ready`. For the unreadable-checks case, also drive this node's own
   streak past `review_gate_unknown_streak_after` (TD-PPagop-26081603) and
   assert the same escalation requirement 8d pins for the Reviewer's own
   handoff: one `review-gate-checks-degraded` event naming the count, in
   place of a second per-item `warning`, with `complete_handoff` still
   recorded as `"failed"` on the `enabler-examined` event.
8e-i. **A stage that says nothing still names its pull request (requirement
   9).** `test/handoff.test.sh` passes its `pr_url_for_branch` assertions: an
   open PR on the claimed branch is found and its URL returned; a branch with
   no open PR yields nothing; an unreachable API yields nothing rather than a
   non-zero return, which under `errexit` would kill the cycle ahead of the
   failure it is describing; and an empty repo or branch asks GitHub nothing at
   all. Then drive an Implementer that exits 0 having pushed a draft PR,
   written no `.git/agent-ops-pr-url` breadcrumb, printed no URL and ended with
   prose instead of a JSON object: the `attempt-failed` must still carry that
   PR's `pr_url`, the PR must still receive the stage-failure comment, and the
   claim must be released as `have-pr` rather than `no-pr`. Assert the URL came
   from the branch and not from the stage — that is the whole point, and a test
   whose Implementer helpfully left a breadcrumb passes without exercising
   anything.
8e-ii. **A subject pull request that merges mid-stage is a completion, not an
   attempt-failed (requirements 31d/32c, agent-ops#916, agent-ops#1063).**
   Drive a cycle whose `$impl_pr_url` is confirmed merged by `pr_merge_state`
   before the Reviewer's own stage-failure exit and its ready/blocked branch
   are read — when the Reviewer's own verdict is `"status": "ready"` (never
   noticed), when it is `"status": "blocked"` naming the merge (noticed), and
   when the Reviewer stage produced no parseable verdict at all (a crash, a
   timeout, an unparseable final message): in every case the cycle must log
   `merge-observed` for the item, never `pr-ready`, `attempt-failed` or an
   Approver engagement, and must release the PR-keyed claim
   (`test/reviewer-merge-observed-wiring.test.sh`, extracting the dispatch
   block out of `lib/coordinator-phase.sh` the same way
   `test/human-reviewer-handoff-wiring.test.sh` extracts its own). Assert that
   the no-parseable-verdict case alone still takes the usage-limit read the
   stage-failure exit would have taken (`detect_and_log_limit_hit` against the
   stage's own output file), and that a verdict which parsed takes it neither
   there nor on the fall-through, where `handle_stage_failure` owns it — one
   read per ending, never two and never none. Assert the
   same for the Reviewer's own stage-start advisory read: a merged
   `$impl_pr_url` skips the Reviewer stage entirely (no `stage-start`/
   `stage-end` for `reviewer`), reaching the same `merge-observed` completion
   at zero stage cost. Assert `file_debt`/`file_issue` on the Reviewer's own
   verdict are filed under the ordinary pipeline login (no `TOKEN`) exactly as
   the Enabler's own use of the two fields already is, and against the cycle's
   own clone of the target repository rather than its state directory
   (requirement 23d's `GIT_DIR`, which a state directory fails outright)
   (`test/merge-observed.test.sh`), and are silently absent at the stage-start
   call site, where no verdict exists yet to carry them. Assert the fall-through: a Reviewer
   claiming a merge `pr_merge_state` does not confirm (`merge_state` `open` or
   `failed`) is handled exactly as an ordinary `"status": "blocked"` verdict
   always has been (requirement 32a) — this is a model error, not a
   completion; and that an unreadable `pr_merge_state` on an otherwise-`ready`
   verdict refuses the handoff (a `log_reviewer_handback`, never a silent
   pass-through).
8e-iii. **`pr_merge_state` (requirement 31d) is fail-closed, the same
   convention `confirm_pr_ready` already keeps.** `test/pr-merge-state.test.sh`
   passes: a `state: "MERGED"` reply reports `merged` with the merge commit's
   `oid` when GitHub supplies one and an empty second field when it does not;
   a `state: "OPEN"` or `state: "CLOSED"` reply reports `open`; an unreachable
   API, a reply with no recognisable `state` field, and an empty PR URL all
   report `failed` and exit non-zero — never `open`, since a caller that read
   an unreadable pull request as still open would run the very handoff a
   genuine merge invalidates.
8e-iiiA. **A `merge-conflicts` work order carries `base` from both producers
   (requirement 31e, agent-ops#1806).** `test/coordinator-merge-fallback.test.sh`
   passes: the deterministic fallback's `mc_cands` composition carries the
   gathered entry's own `base` onto both an ordinary and a takeover
   candidate, exactly as `dq_cands` already carries a `dequeued` entry's
   `base`. `prompts/coordinator.md`'s "For a `merge-conflicts` entry"
   instruction names `"base"` alongside `"pr_url"`/`"pr_number"`/
   `"conflicted_paths"` as a field the work order must carry from the entry.
   Without both, requirement 31e's own capture guard (an absent `base`
   skipping the capture) is always live, and `rebase_only` never fires on a
   real cycle regardless of how correct `rebase_only_push` itself is.
8e-iv. **A `merge-conflicts` item's rebase-only push skips the Reviewer
   engagement, and only the engagement, for the cycle that just ran the
   Implementer (requirement 31e, agent-ops#1806).**
   `test/rebase-only-wiring.test.sh` extracts both
   dispatch blocks out of `agent-cycle.sh` the same way
   `test/reviewer-merge-observed-wiring.test.sh` extracts its own, and pins:
   the pre-capture block (step 6b) records the pre-push head and base SHAs
   only for a `merge-conflicts` work order that does not carry `"takeover":
   true` and whose own `base` resolves to a real ref, and leaves both empty
   for a takeover, for any other source, or for an unresolvable base; the
   stage-start advisory block, given a stubbed `rebase_only_push` reporting
   the pre-push and post-push diffs identical, reports `rebase_only` true and
   reads both heads from `origin` rather than the clone's own `HEAD`; the
   same block reports false — without calling `rebase_only_push` at all —
   when the post-push head equals the pre-push one, since no push happened;
   the same block, with `rebase_only_push` reporting the diffs different,
   reports false; and with no pre-capture at all (not a `merge-conflicts`
   item), it reports false without calling `rebase_only_push` even once.
   The engagement block pins the consequence: a true `rebase_only` logs
   `reviewer-carried-forward` (naming `pr_url`/`old_head`/`new_head` and
   `rebase_only: true`), never calls `run_claude_stage` or
   `stage_budget_apply`, and leaves a synthesised `status: "ready"` verdict
   for the handoff path below — so the Approver engagement and the arming
   step still run; a false one runs the engagement and logs a `stage-end`
   instead. `test/rebase-only.test.sh` pins
   `rebase_only_push`/`diff_patch_id` themselves — see requirement 46a's own
   acceptance check.
8e-v. **The Implementer's own stage-start pays the same advisory merge check
   before it runs, for the five finishing sources whose work order already
   names a subject pull request (requirement 31f, agent-ops#1062).**
   `test/implementer-merge-observed-wiring.test.sh` extracts the step 6c
   dispatch block out of `lib/coordinator-phase.sh` the same way
   `test/reviewer-merge-observed-wiring.test.sh` extracts its own, and pins:
   a `review-feedback`, `merge-conflicts` (without `"takeover": true`),
   `dequeued`, `landing-refusals` or `abandoned-drafts` work order whose
   `pr_url` is confirmed merged by `pr_merge_state` never reaches
   `stage_budget_apply`/`run_claude_stage` for `implementer` at all, logs
   `merge-observed` with `stage: "implementer-stage-start"` and an empty
   verdict, and releases both the item-keyed and the PR-keyed claim; a
   `merge-conflicts` work order carrying `"takeover": true`, or any source
   outside `preflight_existing_branch_source`'s own five, never even calls
   `pr_merge_state`, since its `pr_url` (where present at all) does not name
   a subject this stage can retire; and an `open` or unreadable
   (`failed`) `pr_merge_state` result runs the Implementer stage exactly as
   an item with no pre-existing pull request would.
8f. **A human can reopen a void from where they actually are (requirement
   34f).** `test/unvoid-label.test.sh` passes: a request clears a void recorded
   before the label; a void recorded after it, or at the same instant, stands; a
   second cycle over the same label clears nothing; and a request cannot reach
   another repo's identically-named item, while a void carrying no repo is
   clearable from any. Then drive it end to end: apply the label to a pull
   request naming a voided item and run a cycle — the item must be absent from
   the Co-Ordinator's `void` list *in that same cycle*, not the next, and the
   label must still be on the pull request afterwards. Assert the negatives,
   which are the whole risk: run two further cycles and confirm no second
   `unvoided` event is written, then record a fresh void on the same item and
   confirm the still-present label does not clear it. A label that keeps
   clearing is a permanent exemption, and its only symptom is an item that never
   stays void.
8b. **The two states are visible apart, and so is "waiting on you".** A human
   looking at the monitor can tell "waiting on something" from "there is nothing
   to do here" without reading the log. If both render as one list, the operator
   cannot tell an item needing their help from one needing nothing, which is how
   a stuck pipeline and a healthy one come to look identical. Within the blocked
   list, an item with an open escalation (requirement 36a) is distinguishable
   from one the pipeline is still working on itself — the dashboard's blocked
   table carries the issue link, or the Enabler's last verdict where there is no
   open issue (`docs/spec/dashboard/README.md`). Otherwise the one row on the page that
   is addressed *to the reader* looks exactly like the rows that are not.
8g. **An item in both states reads as void, everywhere (requirement 34h).**
   `test/cycle-state.test.sh` passes: `open_blocked_items` drops a blocked item
   that a later `item-void` covers, keeps one whose void was itself cleared by
   an `unvoided`, honours a repo-less void across every repo, and returns the
   entry otherwise untouched — while `blocked_items` beside it still reports the
   raw requirement 34 set, since the Co-Ordinator is owed both. Then assert it
   through the Publisher: `test/publish-dashboard.test.sh` passes with a log
   carrying a blocked-and-void item, which must appear in `data.js`'s `void[]`
   and **not** in its `blocked[]`. Assert the double negative too — an ordinary
   block beside it is still listed — because a subtraction that over-reaches
   empties the one panel that says the pipeline is stuck, and an empty panel and
   a healthy pipeline look identical.
8h. **A block outlives its impediment, never its work (requirement 34i).**
   `test/work-gone.test.sh` passes, and every assertion in it is made in both
   directions, because the two ways this can be wrong are not alike. Too eager
   clears a block out from under real work and costs a full cycle an hour until
   somebody notices: so a closed issue, a merged pull request, a `resolved` or
   `not-debt` register item, a project-review recommendation named by a merged
   pull request, and an implementation-plan task checked off in its document
   each clear their block, while an **open** issue, an **open** pull request, an
   **open** register item, a recommendation no merged pull request names, and an
   **unchecked** (or ambiguous) plan task each do not, and every unreadable
   shape — a repo missing from the digest, a digest carrying `ok: false`, an id
   no item file claims by `id` or `legacy-id`, an id two of them claim, a
   register/review/plan read that failed — clears nothing at all. Too shy is
   the silent failure this requirement exists to end: so assert the legacy id
   (`TD26072401`) resolving through the renamed file that carries it, and assert
   that the classes still left to the Enabler stay blocked — above all a
   `dependabot-alert-N`, whose source degrades to `[]` on an API error and would
   otherwise read as "every alert is fixed", and a `human-visibility-<hash>`
   item, which has no completion signal at all. `scripts/gather-register-status.sh`,
   `scripts/gather-review-status.sh` and `scripts/gather-plan-status.sh` each run
   for real against a stubbed `gh` in that file, so what is asserted is the
   shipped scripts rather than a copy of their logic.
8i. **A structured dependency is held and released without a model ever
   re-reading it (requirement 34j).** `test/dependency-gate.test.sh` passes:
   `dependency_refs` parses a same-repo `#195`, a cross-repo
   `owner/repo#42`, several references on one comma-separated line, and
   references spread across the body and more than one comment, is
   case-insensitive on the keyword, tolerates a leading list marker, ignores
   a bare number with no `#`, and returns `[]` for text with no `Blocked-by:`
   line at all; `dependency_clearances` clears a blocked issue present in the
   reshaped `issues` map with a `Blocked-by:` line still in its thread, and
   clears nothing for a blocked issue absent from that map, present but with
   no `Blocked-by:` line, or of a shape other than a bare issue number. Then
   the #196–#199-shaped scenario, end to end against a stubbed `gh`: an issue
   whose body reads `Blocked-by: #195` while #195 is open is absent from
   `scripts/gather-issues.sh`'s candidates and present in its `excluded`
   report as `blocked-by: #195` (requirement 3j); the same issue, already
   recorded
   `attempt-failed`, stays in the open blocked set that cycle. Flip #195 to
   closed and run both again — the issue reappears in `gather-issues.sh`'s
   candidates, leaves its `excluded` report,
   *and* `dependency_clearances` produces its release — asserting
   both halves clear within the one cycle the dependency resolved in, and
   that neither ever spent an Enabler engagement or a Co-Ordinator judgement
   doing it.
8i-i. **A `needs_refinement` report re-asserting a resolved dependency is
   refused, never recorded (requirement 16's dependency third; requirement
   34e; agent-ops#566).** `test/dependency-gate.test.sh` passes:
   `dependency_refusal_reason` refuses an entry only when all three hold — its
   `source` is (or defaults to) `"issues"`, its item's own thread (read from the
   `issues_by_repo_json`-shaped map handed in) names at least one `Blocked-by:`
   reference, and its own `reason`/`missing`/`evidence` names that same
   reference by number (a genuine `#410` token or the cross-repo slug verbatim,
   never a mere substring of a different number) — and passes every entry
   short of one of the three: a non-`issues` source, an item this cycle's map
   does not carry or whose thread names no dependency at all, and a report
   naming no reference the thread's own resolved list carries (a genuine
   under-specification or a question/discussion decline). Then, driving
   `record_needs_refinement_block` itself — lifted verbatim from
   `lib/candidate-select.sh`, the same technique
   `test/refiner-verdicts.test.sh` uses —
   `test/dependency-block-refusal.test.sh` passes: a report shaped like the
   agent-ops#566 incident (an issue present in `issues_by_repo_json`, `evidence`
   quoting its thread's own stale `Blocked-by:` line) is refused with a
   `warning` naming the resolved reference, applies no label, makes no
   assignment, and writes no `attempt-failed` at all — while the identical
   report on an item absent from `issues_by_repo_json`, and a genuine
   under-specification report on an item present in it, are both recorded
   exactly as requirement 34e already describes, proving the refusal is scoped
   to the false dependency claim and leaves the judgement half untouched.
8j. **A corroborated void closes the GitHub object it names, exactly once
   (requirement 34k).** `test/close-void-github-items.test.sh` passes against
   a stubbed `gh`: an open issue or an open, obsolete pull request named by a
   void from any of the three writers — Co-Ordinator, Enabler, Implementer,
   all corroborated by requirement 34d (issue #243) — is closed with a
   comment carrying the void's own evidence; a void carrying no `stage` at
   all is left entirely alone with no API call made, the fail-closed default
   for an entry no writer this script recognises corroborated; an object
   already closed is reported (`closed_by: "already"`) rather than touched
   again; a shape naming no GitHub object (a register id) is left entirely
   alone; a `pr-<n>-conflict-<head-sha>` void — the merge-conflicts shape,
   which names a pull request but is not about closing it (TD-PPagop-26080901)
   — is left entirely alone too, with no API call made, exactly like the
   register id, and is excluded before the action cap, so it neither spends a
   slot nor appears in the deferred count; a `pr-<n>-dequeued-<head-sha>` void
   (requirement 3z, TD-PPagop-26081409) is left alone on the same terms, with
   no `gh` call made, so assert that shape too; their sibling shape
   `pr-<n>-superseded-<head-sha>` (TD-PPagop-26081304) carries no such
   exclusion and closes through the ordinary pull-request branch, so assert
   it *does* make the `gh` call and is reported `closed`; a void carrying no
   reason still reaches the comment with its evidence intact; a pull request
   carrying the human-applied `obsolete` label is closed with a comment that
   names the label (TD-PPagop-26081308), its presence re-checked live
   off the same fetch that reads its `state` rather than trusted from the
   void's own claim, while one without the label gets the ordinary comment
   with no such mention; and the per-call action cap defers rather than
   floods.
   `test/cycle-state.test.sh`'s `void_object_closed_items` section passes:
   once a `void-object-closed` event exists for an item, it is excluded from
   every later pass — asserted by driving the same item through the extract
   twice and confirming the second call still yields the recorded set, the
   fact that stops the sweep re-closing an object a human has since reopened
   by hand rather than through `unvoid_label`.
36f. **The delegate mandate reaches exactly two things, and its act waits out
   the veto window (requirement 36f).**
   `test/escalation-autonomy.test.sh` passes:
   `escalation_autonomy_configured_level` resolves `decide-with-veto` from
   the top-level key and from a `repos[]` override, on the same precedence
   every other level uses. `test/enabler-verdicts.test.sh` passes, driving
   `maybe_run_enabler` itself: at `decide-with-veto` the decide pass runs at
   all (the rung is a superset of `decide-tactical`, not a fourth branch
   nobody wired), and is handed `delegate` as its mandate while
   `decide-tactical` is handed `tactical`; a `decide` verdict carrying an
   `act` at `decide-with-veto` logs one `decision-taken` carrying that `act`
   and an `act_after`, files the decision-log issue, and logs **no**
   `unblocked`, the `enabler-examined` outcome reading `decision-pending`;
   the same verdict carrying no act unblocks the item immediately, exactly
   as at `decide-tactical`; the same verdict carrying an act at
   `decide-tactical` is escalated instead, the escalation body's
   `## Adjudication attempted` section naming the act; and a pending act
   whose decision-log issue could not be filed is abandoned rather than
   recorded — no `decision-taken` at all, a `warning` naming the missing
   lever, and the ordinary escalation filed in its place. Both directions
   matter for the same reason requirement 36f states them: an act nobody
   could veto is the one thing this rung must never take, and a pure
   acceptance that waited would be a window in front of nothing.
   `test/decision-veto-sweep.test.sh` passes, driving
   `run_pending_decision_acts` against a stubbed `gh` and a real
   `pending_decision_acts`: before `act_after` nothing happens and nothing is
   logged; after it, with the log issue still `CLOSED`, exactly one
   `item-void` carrying `stage: "decision"` is written, followed by
   `decision-acted` (`outcome: "performed"`) and `unblocked`; a log issue
   read back `OPEN` performs nothing and logs nothing, and one whose state
   cannot be read at all performs nothing and logs a `warning` — the two
   directions of "the act is irreversible, the window is not"; a window of
   `0` acts on the very next cycle; a `decision-acted` already on the log
   retires the act so it is never performed twice; and a veto the sweep
   records for a log issue still carrying a pending act logs
   `decision-acted` with `outcome: "cancelled"`, so the cancellation is on
   the record rather than merely absent from the pending set.
   `test/close-void-github-items.test.sh` passes its `stage: "decision"`
   case: such a void closes its pull request through the ordinary
   `pr-<n>-…` branch, exactly as an `enabler` one does, while an
   unrecognised stage is still skipped before the action cap.
8l. **A closing keyword is enforced, not requested (requirements 23b, 25a,
   17c).** `test/check-closing-keyword.test.sh` passes: called with only a
   body and a branch — no repo slug or pull request number, which the
   record-flip half below needs and the marker/keyword half does not — a PR
   body with no `agent-ops:closes-issue` marker and no `agent/<N>` head
   branch always passes; a marker with no matching closing keyword for the
   same number fails, naming it; an `agent/<N>` head branch with no marker
   for `N` fails naming the marker, and with no keyword for `N` fails naming
   the number — presence is demanded by the branch anchor, not requested of
   the prompt — while a non-numeric agent branch (`agent/td…`,
   `agent/register-hygiene-…`) and a `td/` branch demand nothing; a keyword
   for the *wrong* number does not satisfy a marker (`Closes #199` does not
   satisfy `item=198`); every recognised keyword form (`Closes`/`Fixes`/
   `Resolves`, past tense, a colon, case-insensitive, Markdown emphasis
   around it) passes, in each of the three issue-reference spellings GitHub
   honours (`#198`, `GH-198`, `owner/repo#198` for any `owner/repo`); a word
   merely ending in a keyword ("unclosed #198", "discloses #77", and the
   same near-misses in the other two spellings) does not; and multiple
   markers on one body are checked independently — one satisfied marker
   never excuses another. Given a repo slug and pull request number (a
   stubbed `gh`, issue #1363), the same suite passes for the tech-debt
   record-flip half: an issue with no "Filed as" line, or one carrying it
   but not `pw::type:tech-debt`-labelled, passes exactly as without the two
   extra arguments; a "Filed as" line whose record path falls outside the
   register's own ID charset matches nothing and demands nothing (issue
   #1764), asserted on the shape that distinguishes the narrowed capture
   from the ``[^`]+`` it replaced — the query injected *before* the extension
   (`tech-debt/TD-1?x=y.md`), which the old pattern captured whole, with a
   `files.json` supplied so that capture reached a real "does not touch that
   file" failure rather than a warn-and-skip on an unstubbed `gh` call; the
   suffix shape (`tech-debt/TD-1.md?x=y`) is asserted alongside it for the
   form the issue names, but pins nothing on its own, neither pattern ever
   having matched a segment not ending in `.md`; a "Filed as"-line issue
   whose named record file's diff
   adds `status: resolved` — or `status: not-debt`, the register's other
   terminal state (issue #1437) — passes; the same issue whose diff never
   touches that file fails naming that, and one whose diff touches it
   without adding a terminal `status:` line (left as it was, or flipped to
   the non-terminal `in-progress`) fails naming *that* — each asserted on
   its own message, never on the record path both carry; both of those
   failing shapes instead pass when the base-branch copy of the record
   already carries a terminal `status:` (issue #1493), while the untouched
   one still fails when that copy reads `status: open` — so the lapse is the
   base's own terminal state and not a general amnesty, but only for a pure
   append: given a terminal base copy, a patch that also carries a `-`
   deletion line against the record, or a `+status:` line setting a
   non-terminal value (a de-flip such as `+status: in-progress`), still
   fails naming the record-flip message even though the base is terminal,
   while a pure-append patch (`+` lines only, no non-terminal `+status:`)
   passes, and an untouched record (an empty patch) passes on the base's
   terminal status alone (issue #1795) — and the
   `still-open-body-quotes-resolved` fixture fails too where that copy's
   frontmatter reads `status: open` but its *body*, after the closing
   `---`, quotes another record's `status: resolved` line at column 0
   inside a fenced block, so the frontmatter bounding is asserted and not
   just the terminal state (issue #1764) — the `contents`
   fixture newline-wrapping its base64 as that API really does, and the
   touched-but-unflipped fixture omitting `.base.ref` so the `.base.sha`
   fallback is exercised alongside it; a markerless bare closing keyword on a branch
   that is neither `agent/<N>` nor otherwise anchored — the exact shape the
   marker/keyword half's first clause above passes unconditionally — is
   still pulled into this half once a repo slug and pull request number are
   given (issue #1438): an unflipped record fails it the same way the
   marker/branch-anchored path does, and a correctly flipped record passes;
   the same word-of-its-own guard that keeps "unclosed"/"discloses" from
   satisfying a keyword governs this half too, so a body containing only a
   keyword lookalike ("discloses #240", "an unfixed #240 note") demands no
   record flip at all, in every spelling; a markerless `Fixes GH-240` and a
   markerless `Fixes owner/repo#240` naming the repo slug passed in — matched
   case-insensitively — are each harvested into this half exactly as the bare
   `#240` is, while `Fixes otherowner/otherrepo#240` is not, the fixtures
   holding an unflipped record throughout so that harvesting and not
   harvesting are told apart by the verdict (issue #1460); a repo slug
   carrying digits of its own (`acme/widgets2`) contributes none of them as an
   issue number; neither a failed `gh issue view` nor a failed
   changed-files read (an unreadable issue, a token without access, a
   transient outage) ever fails the check itself, while an unreadable base
   branch leaves the ordinary failure standing instead — every fixture that
   supplies no `pr.json`/`contents.json` asserting the pre-#1493 verdict
   unchanged; and, against the same
   unflipped-record fixture, a keyword written inside a fenced code block, an
   inline code span (the PR #1396 shape), or a line beginning with `>` demands
   no record flip at all, while an ordinary unquoted keyword outside all
   three still does (issue #1463) — proving the stripping neither
   under-reaches (a real close still caught) nor over-reaches (the #1438
   regression case does not return).
   `test/sweep-closed-issues.test.sh` passes against a stubbed
   `gh`: a merged, marker-carrying pull request whose issue is still open is
   closed with the merge cited as evidence; a merged, markerless pull
   request whose head branch is `agent/<N>` closes issue `N` the same way,
   the branch cited as the anchor instead of the marker; an issue GitHub
   already closed (or a PR with neither marker nor numeric agent branch) is
   left untouched, with no extra API call made for the unnamed case; an
   issue GitHub reports `state_reason: "reopened"` is left alone and the
   skip reported, so a human's re-open is never undone on the hour; and the
   per-call action cap defers rather than floods.
8m. **The closing-keyword and changelog-section checks block, not just
   report (requirements 25a and 25c).** The one piece of requirements 25a
   and 25c that no file in this repository carries is the repo setting that
   makes a red check a blocked merge, so
   `scripts/doctor.sh` verifies it against GitHub directly, in its GitHub
   section: it resolves this checkout's own slug (`lib/version.sh`'s
   `agent_ops_version`), reads `gh api repos/<slug>/rulesets`, and for every
   active branch ruleset whose `conditions.ref_name.include` names
   `~DEFAULT_BRANCH` (the active `default` ruleset targeting the default
   branch), warns — once per context, in one pass — unless its
   `required_status_checks` carries an entry with `context: closing-keyword`
   and another with `context: changelog-section`, each with
   `integration_id: 15368` — the GitHub Actions app every other required
   context is pinned to. A missing entry
   warns that the check reports without blocking, the exact gap PR #256's
   review caught by hand; an entry present without the `integration_id` pin
   warns that any GitHub App reporting a check of that name could satisfy
   it; no active branch ruleset targeting the default branch at all warns
   the same way. The check is read-only, warn-level (the pipeline still
   runs without it) and runs on every `doctor.sh` invocation, so a ruleset
   drifting back to report-only surfaces on the next run rather than only
   when a human reads the repo settings by hand (TD-PPagop-26080802).
8n. **A claimed item's gone work is caught before the Implementer runs, not
   inside it (requirement 34m).** `test/preflight.test.sh` passes:
   `preflight_done_reason` returns the same reason `work_gone_clearances`
   would give the same item as a blocked entry — a closed issue, a finishing
   source's closed-or-merged pull request, a register row read `resolved` —
   and returns nothing for one still open, for a repo the digest never
   sampled, and for a register-shaped ref pre-flight never fetched a register
   row for (no currently-live source claims one, so the Script always passes
   an empty register map; passing none must decide nothing rather than assume
   open).
   An ordinary issues/tech-debt item whose own claim branch already carries an
   open pull request in the pre-claim digest is reported by
   `preflight_defer_reason` — a defer, never part of `preflight_done_reason`'s
   void-feeding answer — and a finishing source's own `pr-<n>-…`-shaped item
   never asks that question at all; it
   is already answered by the check above. `preflight_branch_merged_reason`
   reads `identical`/`behind` from a stubbed `gh api compare` as already
   merged, `diverged`/`ahead` as still live, and an unreadable or failed
   comparison as deciding nothing; `preflight_existing_branch_source` is true
   for exactly `review-feedback`, `merge-conflicts`, `dequeued`,
   `landing-refusals` and `abandoned-drafts`,
   false for every other source (including one that merely contains one of
   those names as a substring). `preflight_review_feedback_reason` (issue
   #1360), against a stubbed `gh api pulls/<n>/reviews`, reads the item's own
   review id as still blocking when it is the standing `CHANGES_REQUESTED`
   the recomputed blocking-review rule names, and as no longer blocking
   (voided) both when that same reviewer's later review is `APPROVED` and
   when a different reviewer's later `CHANGES_REQUESTED` has taken its
   place; it decides nothing for an item not shaped `pr-<n>-review-<id>`, and
   nothing for an unreadable reviews read, without calling `gh` at all for
   the former.
8o. **A void that is both actioned and old drops out of the extract; every
   other one does not (requirement 34n).** `test/cycle-state.test.sh`'s
   `retire_void_items` section passes: an entry whose `{repo, item}` is in
   the actioned set and whose `ts` is at least `void_retire_after_days` old
   is dropped; the same entry with a younger `ts` is kept; an old entry
   *not* in the actioned set is kept; an entry with no parseable `ts` is kept
   regardless of the actioned set; `void_retire_after_days` of `0` returns
   every entry unchanged, including old, actioned ones; and malformed input
   (either JSON argument) returns the original `void_json` verbatim rather
   than raising. The recorded half holds too: `void_retired_items` returns
   one `{repo, item, ts}` per pair — the latest `ts` — dropping repoless and
   itemless events, and `subtract_retired_voids` drops exactly the entries
   whose recorded retirement post-dates the void's own `ts` (an item voided
   afresh after its retirement stays in the extract), returning its input
   verbatim when either argument is malformed, while `void_items` over the
   same log still reports the retired entry — the raw set the dashboard and
   requirement 34c read. `test/cycle-state.test.sh`'s `open_blocked_items`,
   `enabler_eligible_items` and `refinements_map` sections keep asserting
   against the *raw*, unretired void/blocked pairing (`LATEST_UNRESOLVED_JQ`)
   with no retirement arguments in sight, pinning that retirement is a
   property of the extract a caller requests, never of the shared
   blocked/void definition those three read directly off the log.
8p. **The closing-keyword gate applies to every target repository, not only
   the one carrying the workflow (requirement 25a, TD-PPagop-26080803).**
   `test/closing-keyword-gate.test.sh` passes against a stubbed `gh`:
   `closing_keyword_gate` reads a pull request's body and head branch and
   reports the checker's own verdict as `clean` or `dirty<TAB>reason` — a
   body with no marker on a non-numeric branch is clean, a marker with a
   real closing keyword is clean, prose describing intent without a keyword
   is dirty naming the issue (the regression the underlying checker exists
   for), and an `agent/<N>` branch with no marker is dirty naming the
   missing marker. The two-fault case (no marker *and* no keyword) reports
   both faults, on one line and free of the `::error::` workflow-command
   prefix, since every caller parses the verdict with a single `read`.
   Separately, the cases where the question could not be put report
   `unknown` and exit 0, so a caller warns rather than stalling the item: an
   unreadable pull request, an answer carrying no head branch (which must
   never read as clean — an empty body on an empty branch is the shape of a
   *passing* pull request), and a checker that cannot be run. An empty URL
   remains `dirty`, and none of these is a crash.

   What `agent-cycle.sh` then *does* with each verdict is asserted separately,
   by `test/closing-keyword-wiring.test.sh`, against the two blocks lifted
   verbatim from the script: a `dirty` verdict at the Implementer-side call
   carries on into the Reviewer stage holding the fault (never recording the
   item `attempt-failed`, the refusal this gate deliberately does not make)
   and that fault reaches the Reviewer as a `## Script findings` section of
   its prompt; an `unknown` one warns and hands the Reviewer nothing; a clean
   one does neither, and leaves the prompt byte-for-byte as it was before the
   section existed.
55. **The ready-gate backstop catches a required context with no check run at
   all, and leaves every pre-existing shape alone (issue #1543).**
   `test/review-gate.test.sh` passes, against the same stubbed `gh` its other
   assertions already use, extended to stub
   `repos/<slug>/rules/branches/<base>`: a base branch given alongside an
   all-`pass` check-runs list whose contexts cover every one the ruleset
   names is still `clean`; the same all-`pass` list with the ruleset naming
   one context absent from it is `dirty`, naming the missing context; a
   genuinely failing required check still wins its own `dirty` reason over
   the backstop when both are true at once; the empty-list trap and the
   unreadable-list `unknown` are byte-for-byte unchanged by a base branch
   being passed alongside them; a ruleset this cannot read (an `ERROR` stub,
   the same convention `review_gate_security_alerts`'s own stub uses) skips
   the backstop and reports `clean` rather than blocking; and omitting the
   base branch entirely — every caller that predates this — skips the
   backstop exactly the same way. `review_gate_verdict`'s own existing
   assertions are unchanged, since `handoff_complete_review` and
   `landing_arm` already pass their own `default_branch` through unmodified.
56. **The deterministic pre-flight finds a deleted or edited-away required
   check's producing job, and escalates it (issue #1543).**
   `test/required-check-preflight.test.sh` passes, against a stubbed `gh`:
   `_required_check_preflight_job_ids` extracts every top-level job id from a
   workflow's literal YAML text and nothing from one with no `jobs:` key at
   all; `required_check_preflight_findings` finds the PR #1503 precedent
   itself — a wholly deleted workflow file whose one job is a required
   context — and finds the same fact when the file is merely *modified* to
   drop the job, comparing each side's own commit; a rename that keeps every
   job finds nothing, reading the rename's own `previous_filename` for the
   old side; a file outside `.github/workflows/` is never inspected; a
   dropped job that was never a required context finds nothing; and an
   unreadable ruleset, changed-file list, or base commit each find nothing
   rather than blocking, the same non-blocking convention requirement 55's
   own backstop applies. The finding path exits 0 — asserted both captured
   and uncaptured, with a required context deliberately sorting *after* the
   removed job id, the arrangement under which the loops' own last `grep`
   would otherwise be what the function returned, and the arrangement
   agent-ops's own ruleset is. `required_check_preflight_escalate` — stubbing
   `create_escalation_issue` exactly as `test/crash-loop-escalate.test.sh`
   already does — files exactly one escalation per call, carrying
   `enabler_escalation_label`, a title naming the missing context(s), the
   base branch and the pull request, and a body naming the context, the file
   that used to produce it, the `required_status_checks` rule as the ask, and
   issue #1543 itself; no findings at all calls `create_escalation_issue`
   not once.
25b. **The tech-debt close-guard finds exactly what requirement 25b's
   evidence rules say it should, posts once per close, and never fails its
   own run (issue #877).** `test/tech-debt-close-guard.test.sh` passes,
   against a stubbed `gh`: an issue not carrying `pw::type:tech-debt` is
   skipped without a single `gh` call; a `completed` close (or an empty
   `state_reason`, GitHub's own default) with a linked closing pull request —
   `closedByPullRequestsReferences`, merged or still open — needs nothing
   further, and the same holds for a linked closing commit
   (`timelineItems`'s `ClosedEvent.closer`); a `completed` close with neither
   kind of link but a comment already on the issue needs nothing further
   either; a `completed` close with none of the three draws exactly one
   comment naming what is missing; a `not_planned` close needs only a
   comment, drawing its own guard comment when none is present; a
   `duplicate` close follows that same comment rule without asking GitHub
   about a closing pull request at all, and its comment names the duplicate
   rather than reporting a completed close, while a `state_reason` this
   script has never heard of is named verbatim under the `completed` rule;
   the stubbed `gh` refuses `--slurp` alongside `--jq` exactly as the real
   binary does (issue #1116), so a comment read that regressed to that
   pairing fails here rather than silently reading every issue as
   comment-less; the guard's
   own past comment on the same issue is excluded when counting "a comment
   already present", so an issue whose only comment is an earlier guard
   comment is still judged unguarded; a comment already carrying this
   close's own `<!-- agent-ops:td-close-guard closed_at=… -->` marker is
   never posted twice, while the same marker naming a *different*
   `closed_at` (an earlier close of the same issue) does not excuse a fresh
   one; a comment-post failure is reported as a warning and the run still
   exits 0; and malformed arguments exit 2 without calling `gh` at all. Every
   path through the script exits 0 except that last usage failure — asserted
   directly, since a red run here must mean the guard could not operate, not
   that a close was irregular.
25c. **A changelog section is enforced, not requested (requirement 25c,
   D27).** `test/check-changelog-section.test.sh` passes: with no
   `## Changelog` section, a `chore`, `docs`, `refactor` or Dependabot
   `build(deps)`/`chore(deps)` title passes and a `feat`, `fix` or `perf`
   title, or any type carrying `!`, fails naming what is owed, an empty
   title skipping the rule; a section of one or more categories with
   bullets passes, as do `None.`, `None` and `None.` followed by a reason,
   asterisk bullets, indented continuations and nested bullets, CRLF line
   endings, a section that ends at the next level-one or level-two heading,
   HTML comments inside it, and a fenced block (a `td-record`, or an example
   of the heading itself) anywhere in the description; and it fails, each
   with a `::error::` line, on an owing title whose only `## Changelog`
   heading is empty or holds nothing but a comment — the template's
   untouched state, which a non-owing title passes, the shipped template
   file itself being asserted both ways — a lower-case heading holding an
   unknown category (proving the heading is detected case-insensitively), an unknown or mis-cased
   category, a category with no bullet, a duplicated category, loose prose
   or a deeper heading under a category, an indented line before any
   bullet, prose or a bullet as the first line, `Nonetheless` mistaken for
   `None`, `None` alongside a category or a bullet, two section headings
   with content (a comment-only heading beside a real one passes), and a
   fenced example standing in for a real section on a `fix` title.
   A fault on the section's first line reports once, without a cascade;
   distinct faults each report on their own line. No arguments at all is a
   usage error (exit 2). Separately, `test/doctor.test.sh`'s ruleset cases
   (acceptance check 8m) cover the `changelog-section` context beside
   `closing-keyword`.
8q. **A void shape with no closed-object or register-resolved signal still
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
8r. **A void whose source or repo the config has dropped retires too
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
   rather than retiring the whole extract. The section also pins the age
   half — an actioned-and-old config pair reaches `retire_void_items` and is
   dropped, an actioned-but-young one is kept — and, in `agent-cycle.sh`, that
   the array read is `all_repos_json` rather than the `--repo`-filtered
   `repos_json` or the back-pressure-narrowed `ordered_repos_json`.
8k. **The changelog-section gate applies to every target repository, not only
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
9. A cron-style invocation from a minimal environment can resolve `claude`
   and run `claude -V` (or a tiny `claude -p` smoke test) successfully.
10. One supervised full cycle (`--once`) against whichever repo the ordering
    picks: it produces a labelled, mergeable, ready-for-review PR with the
    originating register updated and a complete log trail. Report the PR URL
    to the human rather than merging anything.
11. **The eligibility rule round-trips through the real extract
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
    `{repo, item, ts}` triple rather than on `ts` alone.
11a. **The fingerprint wakes a quiet fleet at the threshold, and lets it go
    quiet again (requirement 35b).** In `test/noop-skip.test.sh`, per the same
    discipline as the abandoned-drafts trap: an item entering the eligible set
    changes the fingerprint, its `reason` flipping to `issue-closed` changes it,
    the set emptying after an engagement changes it, and an input recorded before
    the Enabler's keys existed canonicalises exactly as one carrying them empty.
    Without the first three, the escalation path comes due on a quiet week and
    nothing runs until the forced recheck; without the fourth, adding the feature
    would appear to change every replayed cycle.
11b. **An open escalation is invisible to the Co-Ordinator and to the Enabler.**
    Assign an issue and confirm requirement 16.4 excludes it from candidacy, and
    that the same issue's number in the repo's open-issue digest makes its item
    Enabler-ineligible. Then the half that closes the loop: with the issue gone
    from the digest, the item is eligible with reason `issue-closed`, and after
    the verification's examined event it is not eligible again. This is the check
    that the protocol the issue promises its reader — close it and the work
    resumes — is the protocol the code implements.
11d. **An under-specified item is reported, blocked, refined and carried
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
11d-i. **An escalation the Script did not file is never claimed on the work
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
11e. **A human's own label is read back, and only where this mechanism put it
    (requirement 34g).** `test/needs-refinement.test.sh` passes:
    `refinement_hand_flag_new` turns a labelled, open issue with no existing
    block — of any kind — into a fresh entry, and reports nothing for one
    already blocked (no duplicate for the same label on the same item) or for
    a labelled issue that is closed; `refinement_hand_flag_fields` marks what
    it builds `hand_flagged: true` with no `unblock_condition`;
    `refinement_hand_flag_cleared` maps a `hand_flagged` block whose issue has
    lost the label — open or closed — to an `unblocked` candidate, but leaves
    alone both a block still carrying the label and a block that is not marked
    `hand_flagged` (the Script's own projection from a Co-Ordinator's report),
    even when that one's label is also missing — proving the one-way rule
    requirement 34e states for that population still holds.
