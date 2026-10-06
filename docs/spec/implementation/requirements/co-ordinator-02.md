## Requirements

### The Co-Ordinator — requirements, continued (part 2 of 2; 18a–20: Fresh evidence on a blocked issue makes requirement 18's r…)

18a. **Fresh evidence on a blocked issue makes requirement 18's re-check
    mandatory, not discretionary.** For a blocked item that is a GitHub
    issue, before excluding it under requirement 16 the Co-Ordinator compares
    the issue's own `updated_at` against the later of two timestamps carried
    on its `blocked` entry: the `ts` of the `attempt-failed` event that
    blocked it, and its `recheck_clean_ts` if it has one — the newest
    `recheck-clean` event recorded for it (below), or absent if none exists.
    If `updated_at` is newer than that later timestamp, something was posted
    to the thread since the block was last confirmed current, so the
    Co-Ordinator must read the issue and every comment (requirement 14a's
    whole-thread rule) before honouring the marker, and judge against that
    fresh reading whether the recorded blocker still holds:
    - If it does not, report the item in `unblocked`, as the bare item id
      requirement 20 specifies. This is the same outcome and the same two
      limits as requirement 18 (impediments only; never clears a void); only
      the trigger changes, from "may check when convenient" to "must check
      when the thread has moved".
    - If it still holds, report the item in `recheck_clean` as
      `{item, repo}` (requirement 20) instead of leaving the re-check
      unrecorded — both fields off the `blocked` entry just re-checked. The
      Script logs this as a `recheck-clean` event (requirement 33) and folds
      the newest one per item into the `blocked` extract as
      `recheck_clean_ts`, which is what the next cycle's comparison above
      reads. Without this marker, a comment that fails to clear the block
      would look, to every later cycle, exactly like one that was never
      read: `updated_at` stays newer than the original `ts` forever, and
      every Co-Ordinator that runs re-reads the same stale thread and
      re-judges the same evidence until the block finally clears by some
      other route.

    When `updated_at` is no newer than the later of the two timestamps,
    nothing has changed since the more recent of the block or its last
    confirmed re-check, and the ordinary skip applies without a re-read.

    **`recheck_clean` must never be produced by re-emitting `attempt-failed`,
    and a re-check that still holds must never move the blocked entry's own
    `ts`.** Requirement 35a's Enabler clock is measured from the block's `ts`
    forward; a fresh `attempt-failed` — or any change to the existing one —
    would advance that clock exactly as a genuine re-block does, delaying the
    Enabler's own eventual escalation over a confirmation that changed
    nothing. `recheck_clean` is deliberately a separate marker that only this
    comparison reads, so confirming a block never resets anyone else's clock.

    This exists because the general case left a gap a periodic sweep alone
    cannot close at cycle speed: requirement 3b's fingerprint already digests
    each issue's `updated_at`, so a comment landing on an already-blocked
    issue busts the fingerprint and wakes a Co-Ordinator within the hour —
    but that Co-Ordinator would otherwise skip straight past the item on the
    stale marker without ever looking at what changed, exactly the failure
    the Enabler's own periodic re-check (requirement 35a) exists to bound to
    days rather than never. Reading the fresh comment the same cycle that
    woke for it is cheaper than either the silent stall or the Enabler's
    eventual sweep, and does not replace the Enabler: an item this check
    finds still blocked is exactly the item the Enabler goes on to re-examine
    on its own schedule. The `recheck_clean` marker exists so that reading it
    once is also the *last* time it gets read on a thread that has not moved
    again since — without it, the cost this requirement was meant to bound to
    "one re-read per genuine comment" would instead recur every cycle a
    Co-Ordinator runs, for as long as the block lasts.

    No other blocked source needs the same treatment, so this requirement
    binds to GitHub issues only and requirement 18's general, discretionary
    check still covers the rest. Tech-debt entries, security and code-quality
    findings, plan tasks and project-review recommendations have no per-item
    "new evidence arrived" signal at all: their content lives in a file or an
    alert record, not a thread a human can add to after the block. The
    PR-derived sources do have one, but they do not need this rule, because
    their refs are scoped to the round or the head SHA that produced them
    (`pr-<n>-review-<review-id>`, `pr-<n>-conflict-<head-sha>`,
    `pr-<n>-superseded-<head-sha>`, `pr-<n>-dequeued-<head-sha>`,
    `pr-<n>-abandoned-<head-sha>` —
    requirement 20): a human reviewing again,
    or a commit landing on the branch, mints a fresh item id that no block
    covers, so evidence arriving there is never held behind a stale marker.
19. Chooses the Implementer's model: `implementer_model_trivial` only when
    the item can be completed without changing any file that affects runtime
    behaviour (docs, comments, register entries); otherwise
    `implementer_model_default`. Records the reasoning.
20. Emits its entire final message as one JSON object: `selected`,
    `unblocked`, `recheck_clean` (entries of `{item, repo}`, for requirement
    18a's mandatory re-check finding the blocker still holds — repo-scoped,
    unlike `unblocked`, because this marker suppresses a mandatory re-read
    where an over-broad `unblocked` merely re-admits a candidate, and the
    `blocked` entry being re-checked carries its `repo` in any case),
    `voided` (entries of `{item, repo, reason, evidence}`,
    requirement 34d), `needs_refinement` (entries of
    `{repo, item, source, reason, missing, evidence}`, requirement 16a), and a
    ranked `candidates` array of up to
    `candidates_max` work orders (the Script accepts the former
    single-selection shape — the work-order fields at the top level — for
    one release, treating it as a one-candidate list). Candidates carry no
    `branch`: the Script derives and injects the claim branch (requirement
    17a), except for the finishing sources `review-feedback`, `merge-conflicts`
    and `abandoned-drafts`, whose `branch` is the PR's existing branch carried from
    the entry. The Co-Ordinator does copy `pr_label` from its own runtime
    input into every candidate, but that copy is belt-and-braces, never
    load-bearing: the claim loop (requirement 17a) stamps the configured
    `pr_label` onto the winning candidate unconditionally, the same way it
    injects `branch`, so a work order's `pr_label` is guaranteed correct
    regardless of whether the model included or correctly copied it
    (agent-ops#956). For a `failed-runs` entry,
    `item` is `failed-run-` plus the workflow file's basename without extension —
    deterministic, so every node derives the same claim key. `source` is one of
    `security`, `review-feedback`, `merge-conflicts`, `abandoned-drafts`,
    `failed-runs`, `tech-debt`, `issues`, `implementation-plan`, `project-review`,
    or `code-quality`
    — an issue is `issues` whichever band it was selected from
    (requirement 15e); the `issues:<band>` tokens exist only in `sources`, to
    place the source in the walk, and never in a work order.

    **For every source except `project-review`, `failed-runs` and
    `implementation-plan`, the Co-Ordinator does not set `context` or
    `acceptance` at all — requirement 17h composes both, from a live read or
    the pre-fetched band entry, once the candidate is selected.** What
    follows here is what requirement 17h's own compose step produces for each
    of those sources, not something the Co-Ordinator writes: for a
    `review-feedback` entry, `item` is its `ref`, `branch` is the PR's
    **existing** branch, the order also carries `pr_url` and `pr_number`, and
    `context` is the entry's `body` **verbatim** — it is a human's specific,
    considered request and it is the entire brief. For a `merge-conflicts`
    entry, `item` is its `ref`, `branch` is the PR's **existing** branch, the
    order also carries `pr_url`, `pr_number` and the PR's `base`, and
    `context` is the PR's own `body` verbatim; `acceptance` names rebasing
    onto `base` and resolving the conflict — not re-doing or extending the
    work — with the PR left in the ready state it was already in, the
    underlying item deliberately left for its own eventual merge.
    **Exception — a Dependabot takeover** (requirement 3s: the entry carries
    `bot: true`, `rebase_requested: true`, no `superseded_by`): the
    Co-Ordinator's own candidate carries `"takeover": true` and **omits
    `branch`** — the Script derives `agent/<ref>` for it exactly as for a
    non-finishing source (requirement 17a's carve-out), since the PR named in
    `context` is Dependabot's, never rebased or force-pushed. `context` still
    carries the bot PR's `body` verbatim; `acceptance` names a new,
    mergeable, CI-green PR carrying the same dependency bump, left a
    **draft**, with the bot's PR closed — never the ordinary rebase
    acceptance, which a takeover's fresh-branch shape cannot satisfy. A
    `superseded_by` entry never becomes a work order at all — it belongs in
    `voided`, evidence copied from the entry's own `superseded_evidence`
    verbatim (requirement 3s). For an `abandoned-drafts` entry, `item` is its
    `ref`, `branch` is the draft PR's **existing** branch, the order also
    carries `pr_url` and `pr_number`, and `context` is the draft PR's own
    `body` verbatim (the original plan); `acceptance` names completion to the
    originating item's standard with the PR left a **draft** for the Reviewer
    to flip to ready. For a `dequeued` entry, `item` is its `ref`, `branch`
    is the PR's **existing** branch, the order also carries `pr_url`,
    `pr_number` and `base`, and `context` is the PR's own `body` verbatim;
    `acceptance` names diagnosing and fixing the merge-group's own checks
    failure, pushed to the existing branch, with the PR left ready for a
    human's fresh "Merge when ready". For a `human-visibility` entry, `item` is its
    `ref`, there is no PR to carry, `model` is always
    `implementer_model_default` (a diagnosis, not an edit), and `context` is
    the entry's `body` verbatim plus its `url`. For a `security`/
    `code-quality` finding, `item` is the finding's stable `ref` (e.g.
    `dependabot-alert-42`, `code-scanning-alert-17`) and `context` names the
    finding (package/rule, severity, affected location, advisory summary, and
    the alert URL) so the Implementer can act without re-querying the API.
    For an `issues` or `tech-debt` entry, `item` is the issue number and
    `context` is a *fresh* live read of the issue body **and every comment**
    (each attributed to its author, in order) — never the band entry the
    Co-Ordinator was shown, which the fit ladder (requirement 4i) may have
    trimmed; where the comments changed the ask, `acceptance` still names
    resolving per the current state of the thread, not the original body
    alone (requirement 17h).

    Only for `project-review`, `failed-runs` and `implementation-plan` — the
    three sources with no pre-fetched band for the Script to compose from,
    and never subject to the fit ladder's trimming in the first place — does
    the Co-Ordinator still author `context`/`acceptance` itself. For a
    `project-review` recommendation, `item` is its ref
    (`review-<review-date>-R-NN`) and `context` must paste the recommendation's
    improvement prompt (from `04-improvement-prompts.md`) verbatim, together
    with the review folder path and the `R-NN` detail; `acceptance` is the
    recommendation's *Intended end state*.

    ```json
    {
      "selected": true,
      "repo": "Poetic-Poems/poetic-fiddle",
      "default_branch": "main",
      "pr_label": "autonomous-agent",
      "source": "tech-debt",
      "item": "TD26051201",
      "title": "one-line description",
      "branch": "agent/td26051201-short-slug",
      "model": "claude-sonnet-5",
      "model_reason": "code change with tests",
      "context": "everything the Implementer needs: the register entry, issue text, or finding verbatim, file paths, related conventions found while evaluating, why the item is unblocked and in scope",
      "acceptance": "what done looks like, concretely"
    }
    ```

