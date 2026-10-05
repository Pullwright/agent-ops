## Requirements

### The Script — requirements, continued (part 6 of 10; 3c–3v: Review-feedback pre-fetch (requirement 3c)…)

3c. **Review-feedback pre-fetch (requirement 3c).** For each configured repo
   whose `sources` include `review-feedback` (requirement 48: freshly for the one repository this cycle picks, replayed from this node's expensive-gather cache for the rest), run
   `scripts/gather-review-feedback.sh <slug> <pr_label> <branch_prefix>` and
   attach the array to that repo's entry as `review_feedback`. It prints the
   PRs *waiting on us to answer a human's review*: open, non-draft, carrying
   `pr_label`, head branch under `branch_prefix`, `reviewDecision` of
   `CHANGES_REQUESTED`, and — the load-bearing clause — **no GitHub
   review-thread event has answered the blocking review**: no marked reply
   whose marker's `actor=` field is `implementer` (a review or general PR
   comment carrying `lib/pipeline-marker.sh`'s invisible marker) and no
   `review_requested` timeline event, either dated after the blocking review
   was submitted. Each entry carries every review body and inline comment in
   the round, verbatim.

   - **The turn rule is the whole feature.** This system raises PRs as the
     account it runs as, and GitHub forbids approving or dismissing a review on
     your own PR. So the agent *cannot* clear `CHANGES_REQUESTED`; it stays set
     after the fix is pushed, and nothing about the PR's own state ever says
     "answered". Deriving whose turn it is from review-thread events is the
     only thing that does. Without it every PR the agent fixed would stay a
     candidate forever — selected, re-fixed, re-selected, each cycle
     looking like a productive one and each paying a Sonnet run to redo work
     already pushed. Same shape as requirement 15's "a later green run
     supersedes".
   - **Events, not commit timestamps.** This used to compare the blocking
     review's `submitted_at` against the head commit's `committedDate`. A
     conflict-resolution force-push re-stamps every commit's date to push
     time, which silently satisfied that comparison on PR #205 while the
     human's `CHANGES_REQUESTED` sat unanswered — the branch had a fresh
     commit date from a rebase that never touched a single finding in the
     review. A marked reply and a `review_requested` timeline event are both
     stamped by GitHub itself at the moment they happen, so neither can be
     produced by a rebase; a round is answered only once one of them actually
     occurs after the blocking review.
   - **Only a marked reply from the Implementer answers a round.** The
     marker (`lib/pipeline-marker.sh`) records who wrote it — `script`,
     `enabler`, `reviewer` and `refiner` write it too, for reasons unrelated
     to answering a review — and two of those are never an answer:
     `actor=script` records a stage giving up on the PR, and `actor=enabler`
     a stall being diagnosed. On PR #269 exactly those two comments closed
     the round under the plain "any marked reply" rule, and the work sat
     stranded until a human was escalated (agent-ops#278). Requiring
     `actor=implementer` — `prompts/implementer.md`'s own "Answer the review
     before you finish" — fails loudly instead of silently: a future actor
     added to the marker (as `refiner` was) leaves the round open rather than
     closing it by default, and the next Implementer engagement simply finds
     the round already answered and finishes it properly. A legacy marked
     comment with no `actor=` field does not answer the round either, for the
     same reason.
   - **The blocking review is computed by `lib/handoff.sh`'s
     `handoff_latest_positions`, the same standing-position-per-reviewer
     definition `_handoff_blocking_reviewers` calls below — deliberately
     without that caller's bot filter** (requirement 34a): each reviewer's own
     most recent APPROVED-or-CHANGES_REQUESTED review, filtered to
     CHANGES_REQUESTED, latest across reviewers. A COMMENTED review never
     changes a reviewer's standing position, so a human who requested changes
     and later left a comment is still blocking. Bots count here and not in
     re-request: `reviewDecision` — the selection filter — counts bots, and
     the marked reply is the only event that can answer a bot's round, since
     the pipeline can neither dismiss a review on its own PR nor (by design)
     re-request a bot. Bot findings are addressed; bots are never pinged.
     `lib/preflight.sh`'s `preflight_review_feedback_reason` (3s, requirement
     34m) calls the same function, the same way, when it re-checks this
     source's own candidate rule at claim time, and
     `scripts/sweep-human-visibility.sh`'s `_sweep_round_answered` (requirement
     38c) calls it a third way for the blocking timestamp its own round
     judgement needs — one jq definition, four callers (this script, that
     preflight check, that sweep, and `_handoff_blocking_reviewers`/
     `_handoff_pr_approved` below), keyed on whichever reviewer-identifying
     field its own review shape carries (`who` in the three REST-shaped
     callers, `login` over `_handoff_pr_query`'s GraphQL shape), each
     filtering (or not) for bots before calling it rather than the function
     doing so itself — issue #1373, since two copies of a rule cross-referenced
     only by comment drift exactly as easily as no comment at all, and the
     sweep's copy — cross-referenced by no comment whatsoever — is how this
     rule reached four copies before anyone counted three.
   - **Gather every review in the round, not just the blocking one.** The
     substance and the formal signal routinely live in different reviews by
     different accounts, precisely *because* an author cannot request changes on
     their own PR. Observed here: the agent's account left a 6.5 KB `COMMENTED`
     review with every actual finding, and the human's second account posted the
     `CHANGES_REQUESTED` whose body reads, in full, "Refer to <link>". Gather
     only the blocker and the Implementer receives the words "Refer to". The
     round's start is the most recent answer event *before* the blocking
     review (or the PR's beginning, if none), so a COMMENTED review submitted
     moments before the blocking one is still included.
   - **The ref is `pr-<n>-review-<review-id>`, not `pr-<n>`.** A blocked item
     (requirement 34) stays blocked until cleared, so a bare `pr-57` the
     Implementer once failed on would still be blocked when the human posted
     fresh guidance, and that guidance would land on a dead item. Per-round refs
     expire by irrelevance, like the review-dated `review-<date>-R-NN` refs.
   - **Only branches under `branch_prefix`.** The Landing Gate reserves every
     other branch for humans; "they asked for changes" is not licence to push to
     a colleague's PR.
   - **The answered-from-events extraction and decision are `lib/handoff.sh`'s
     `handoff_answer_events` / `handoff_round_answered`, one definition shared
     with requirement 38c's sweep (requirement 34a).** This script passes all
     three signals — reviews, PR comments, and the timeline's
     `review_requested` events; `scripts/sweep-human-visibility.sh` calls the
     same functions with the timeline omitted, so its own re-request cannot
     read back next cycle as an answer to itself
     (tech-debt/TD-PPagop-26080804.md).
   - **The head SHA comes from `headRefOid`, not from the `commits`
     collection.** Reading `commits[-1].oid` cost 31 GraphQL points a call
     against a repository with three open pull requests — `gh` requests
     `commits(last: 100)` for each of the `--limit` slots, and GitHub charges
     for nodes asked for rather than nodes returned — where the scalar field
     costs 1. The listing is bounded at `GITHUB_PR_LIST_LIMIT`
     (`lib/github-limit.sh`) rather than inheriting `gh`'s undeclared default
     of 30, and says on stderr when the response came back at that cap; here
     truncation can only mean a review round is not offered this cycle.
   - Fails safe to `[]` (exit 0). But show `gh`'s stderr: a rejected `--json`
     field name otherwise degrades to an empty array indistinguishable from
     "nothing is under review", and the source silently never fires. That cost
     a debugging round when this was built.
   - **Every `gh api --paginate` read streams one object per line and is
     slurped afterward; none aggregates inside `--jq`.** `--paginate` re-runs
     the `--jq` filter once per page and prints each page's result as its own
     JSON document, rather than concatenating pages before filtering. A
     filter that builds its own aggregate (`[.[] | …]`) is therefore computed
     *per page* and disagrees with itself past the endpoint's thirty-item
     default page size: two or more array literals land in the variable
     instead of one. `jq -e 'type == "array"'` does not catch it — `jq`
     evaluates the filter once per input document and exits on the last
     one's truth, so the guard only establishes "every document is an
     array", never "this is one array" — and `--argjson` downstream then
     fails to parse the multi-document value. All four reads here (reviews,
     issue comments, the timeline, inline PR comments) emit one object per
     matching item and are slurped into a single array with `jq -s -c '.'`
     immediately after, the same pattern `_handoff_blocking_reviewers`
     (`lib/handoff.sh`) and `_sweep_round_answered`
     (`scripts/sweep-human-visibility.sh`) already use
     (tech-debt/TD-PPagop-26081306.md).
3e. **Abandoned-drafts pre-fetch.** For each configured repo (requirement 48: freshly for the one repository this cycle picks, replayed from this node's expensive-gather cache for the rest), run
   `scripts/gather-abandoned-drafts.sh <slug>
   <pr_label> <branch_prefix> <abandoned_draft_after_hours>` and attach the array
   to that repo's entry as `abandoned_drafts` — unconditionally, because
   `abandoned-drafts` is a required member of every repository's `sources`
   (the schema's `contains` rule, enforced by requirement 1b's gate; decided
   in #472). It is the only route back to a draft this system raised and
   then abandoned: the other finishing sources exclude drafts by
   construction (requirements 3c, 3g, 3z), the draft's own branch is the
   claim the item was taken under so nothing can re-attempt it, and
   requirement 17b's sweep recovers an orphan precisely by minting the draft
   this source is the only reader of — so a repository able to omit the
   token would leave every stalled draft it ever raises unreachable. Its
   *position* in `sources` remains the installation's choice: required means
   listed, not ranked anywhere in particular. It prints the draft PRs *this
   system raised and then abandoned*: open, **draft**, carrying `pr_label`, head
   branch under `branch_prefix`, and whose last **real** activity
   (below) is older than `now − abandoned_draft_after_hours`. Each entry carries
   the round's ref, the PR number and URL, the existing branch, the head SHA,
   that last-real-activity timestamp (as `updated_at`), and the draft PR's own
   body verbatim (the original plan).

   - **A draft is the claim; a stale draft is an abandoned claim.** Requirement 23
     has the Implementer open a draft PR the moment it starts, as the visible
     claim. A draft that has sat untouched past the threshold is therefore a claim
     whose owner never returned — a stage that timed out, hit a usage limit, or
     died. A genuine push, review or comment resets the clock, so a draft that is
     merely being worked (or that a peer node has picked up) never qualifies; the
     threshold sits comfortably beyond a whole cycle for exactly this reason.
   - **Last real activity, not GitHub's raw `updatedAt`** (TD26072605). `updatedAt`
     advances on *anything* — a push, a comment, a label or a title edit —
     including this system's own housekeeping, and when this system touches a PR
     that usually means the opposite of "somebody is on it". So this source
     computes its own measure instead: the latest of the head commit's
     `committedDate`, every review's `submittedAt` and every comment's
     `createdAt`, **excepting** any review or comment carrying the invisible
     marker `lib/pipeline-marker.sh` defines — the body is what is tested, not
     which collection the write landed in, because `gh pr comment` and `gh pr
     review --comment` file the same words under different ones and the Reviewer
     may use either. Two writes are therefore never evidence of
     activity: a **label edit** is discounted unconditionally (the label set is
     this system's own bookkeeping, never a sign of work in progress), and a
     **comment this system posted itself** — stamped by `agent-cycle.sh`'s own
     stage-failure comments and by the Implementer's, Enabler's and Reviewer's
     comment instructions (`prompts/implementer.md`, `prompts/enabler.md`,
     `prompts/reviewer.md`) — is discounted because it carries the marker. A
     human's comment (or a peer node commenting
     on a human's behalf) carries no marker and always counts; filtering by
     author cannot make this distinction, because every pipeline write happens
     under the same GitHub account a human also comments as. A marked comment
     resets the clock **not at all**, never partially — the Enabler's own verdict
     already reaches selection as an `unblocked`/`still-blocked` event
     (requirement 18), so a partial reset would add nothing.
   - **The head commit arrives as `headRefOid` plus one REST call, never as
     the `commits` collection.** The listing asks for the head sha as a scalar
     field, and the head commit's `committedDate` — which the clock above
     needs and a sha alone does not give — is fetched per surviving candidate
     from `GET /repos/<slug>/commits/<sha>`, reading `.commit.committer.date`
     (REST's spelling of GraphQL's `committedDate`; `.commit.author.date` is
     the other one and would be the wrong field). Asking a listing for
     `commits` cost 31 GraphQL points a call against a repository with three
     open pull requests, because `gh` requests `commits(last: 100)` for each
     of the `--limit` slots and GitHub charges for nodes asked for rather than
     nodes returned; the same listing with `headRefOid` measures 1. A PR whose
     head-commit date cannot be read is excluded this cycle, loudly on stderr,
     under the same uncomputable-activity rule as a capped collection.
   - **A nested collection at `gh`'s cap is missing evidence, not evidence.**
     `gh pr list` does not paginate the collections this computation reads —
     `reviews` and `comments` each arrive capped at 100 items, with `comments`
     oldest-first — so at the cap the newest activity may be absent. A PR with
     either collection at the cap is excluded this cycle, loudly on stderr:
     the same uncomputable-activity treatment as the unreadable-head-commit
     case above, chosen over paginating per candidate because the failure it
     guards against is the dangerous direction (a live human conversation past
     the cap misread as silence) while the cost is the safe one — a stalled
     draft that has somehow accumulated 100 of anything waits for a human, and
     on this system's own drafts such a PR is an anomaly worth a human's eye
     anyway. `commits` needed the same guard while it was read, because at its
     cap `commits[-1]` was the hundredth commit rather than the head;
     `headRefOid` is the head at any branch length, so that clause has no
     counterpart here and is not missing.
   - **The listing itself is bounded and its truncation is noticed.** It asks
     for `GITHUB_PR_LIST_LIMIT` pull requests (`lib/github-limit.sh`) rather
     than inheriting `gh`'s undeclared default of 30, and says on stderr when
     the response came back at that cap. Unlike the back-pressure gate of
     requirement 2.2, where the same truncation is dangerous, here it can only
     mean a draft is not offered for recovery this cycle — the safe direction
     every other exclusion in this source takes.
   - **Ready PRs are not ours to touch here.** A non-draft PR is finished work
     waiting on the human; answering it is `review-feedback`'s job, and
     force-pushing it would violate the Landing Gate. Only drafts qualify.
   - **The ref is scoped to the head SHA** — `pr-<n>-abandoned-<head-sha>`, not
     `pr-<n>-abandoned` — so a block recorded against one abandoned state does not
     swallow a later, possibly-finishable state after fresh commits land, while a
     draft re-abandoned at the same head keeps the same ref and stays blocked.
     Same reasoning as requirement 3c's per-round refs.
   - **Its candidacy turns on the clock**, uniquely among the sources, and that is
     the deciding reason it is pre-fetched rather than left to the Co-Ordinator:
     the staleness transition moves no commit, issue, alert or even a PR's real
     activity, so only an array computed against the clock here makes it visible
     to the no-op fingerprint (requirement 3b). As with requirement 3c the rule
     must exist for the fingerprint anyway, so it gets one definition
     (requirement 34a).
   - Fails safe to `[]` (exit 0), with the same stderr discipline as requirement
     3c. A PR whose real activity cannot be computed (an unreadable head-commit
     date — should never happen — or a collection at the cap, above) is excluded
     rather than treated as maximally stale: the dangerous direction is stealing
     live work, not leaving a stalled draft one more cycle. `shellcheck`-clean.
3g. **Merge-conflicts pre-fetch.** For each configured repo whose `sources`
   include `merge-conflicts` (requirement 48: freshly for the one repository this cycle picks, replayed from this node's expensive-gather cache for the rest), run `scripts/gather-merge-conflicts.sh <slug>
   <pr_label> <branch_prefix>` and attach the array
   to that repo's entry as
   `merge_conflicts`. It prints the PRs *this system raised that are otherwise
   ready but conflict with their base*: open, **non-draft**, carrying `pr_label`,
   head branch under `branch_prefix`, and with `mergeable` exactly
   `CONFLICTING`. Each entry carries a head-SHA-scoped ref, the PR number and URL,
   the existing branch, its `base`, the head SHA, the `updatedAt`, the PR's
   own body verbatim, and `conflicted_paths`.

   - **Only *ready* PRs, and only *definite* conflicts.** A draft's conflict is
     abandoned-drafts' to resolve (as part of finishing the draft); this source is
     for PRs otherwise ready for review or merge, where the conflict is the sole
     blocker. And `mergeable` must be `CONFLICTING`, never `UNKNOWN`: GitHub
     computes mergeability asynchronously, so a PR whose base just moved reports
     `UNKNOWN` for a beat. Treating that as a conflict would send the Implementer
     to rebase a PR that may not conflict; skipping it means the PR is simply
     reconsidered next cycle, once GitHub has settled the answer.
   - **Both listings are bounded, their truncation is noticed, and the head
     arrives as a scalar.** The ours-by-label listing and the Dependabot
     listing each ask for `GITHUB_PR_LIST_LIMIT` pull requests
     (`lib/github-limit.sh`) rather than inheriting `gh`'s undeclared default
     of 30, and each says on stderr when its response came back at that cap.
     Truncation here is cost, never damage: a conflicted PR beyond the cap is
     simply not offered this cycle, and a newer bump beyond it is not counted
     as superseding — the conflicted bump it would have excused is minted as
     the conflict shape instead, whose treatment (nudge, then take over,
     requirement 3s) closes nothing. The head SHA is read from `headRefOid`,
     not `commits[-1].oid`, for requirement 3e's two reasons: the collection
     read costs `--limit`-slots × 100 nodes where the scalar measures 1 point,
     and at the collection's 100-item cap `commits[-1]` was the hundredth
     commit rather than the head.
   - **The ref is scoped to the head SHA** — `pr-<n>-conflict-<head-sha>`, not
     `pr-<n>-conflict` — so a block recorded against one conflicted state does not
     swallow a later, possibly-resolvable one after fresh commits land, while a
     resolution (which moves the head) retires the ref and a conflict re-detected
     at the same head keeps it. Same reasoning as requirements 3c and 3e. A
     Dependabot entry superseded by a newer open bump of the same dependency
     (requirement 3s) mints the sibling shape `pr-<n>-superseded-<head-sha>`
     instead, so requirement 34k's act-on-void close can tell the two claims
     apart on the id alone (TD-PPagop-26081304).
   - **Its candidacy turns on the base moving**, an event no signal on the PR
     itself carries, which is the deciding reason it is pre-fetched rather than
     left to the Co-Ordinator: the base advance moves the repo head SHA one cycle,
     but mergeability resolves to `CONFLICTING` a later cycle with the repo head
     SHA unchanged since — so only an array computed here makes the transition
     visible to the no-op fingerprint (requirement 3b). As with requirements 3c
     and 3e the rule must exist for the fingerprint anyway, so it gets one
     definition (requirement 34a).
   - Fails safe to `[]` (exit 0), with the same stderr discipline as requirement
     3c. `shellcheck`-clean.
   - **`conflicted_paths` names which files conflicted (issue #1805).**
     Establishing which lever actually causes a repo's conflicts used to mean
     replaying every claim's head against its base by hand; this answers it
     from the record itself. For every admitted candidate,
     `gather-merge-conflicts.sh` runs a dry-run merge — `git merge-tree
     --write-tree --name-only --no-messages <base> <head>` (git ≥2.38),
     which touches no ref, no working tree and no index — against a blobless
     bare clone (`git clone --filter=blob:none --bare`) of the repository,
     fetched at most once per script invocation and reused across every
     candidate that invocation admits: the script is itself already called
     at most once per repository per cycle (requirement 48's expensive-gather
     cache, above), so this is the "one bare blobless clone per repository
     per cycle" bound, not a further cache of its own. Each candidate's own
     dry run fetches only the two refs — its base and its own head — it
     needs into that shared clone. `conflicted_paths` is the literal JSON
     `null`, never `[]`, whenever the dry run cannot be computed — the clone
     failed, the fetch failed, or `git merge-tree` exited with anything other
     than 0 (clean) or 1 (conflicts) — since an empty array would assert
     "this merge is clean", which contradicts the candidate rule above (the
     PR is already known `CONFLICTING`). A clean result (exit 0) is reported
     as `[]` honestly, on the rare chance the base or head moved between
     GitHub's own mergeability computation and this dry run. A failed dry run
     is silent on stderr — it degrades one optional field on one candidate,
     never the candidate itself, so it does not count against this
     requirement's own liveness marker (`lib/candidate-select.sh`'s
     `gather_merge_conflicts`, which watches stderr to distinguish "empty
     because there is nothing" from "empty because it could not look").
     `conflicted_paths` flows onward exactly as `base`/`pr_url`/`pr_number`
     already do: into the rework record's `evidence` at selection
     (`lib/rework.sh`'s `rework_selection_fields`) and into the
     `merge-conflicts` work order the Implementer receives
     (`prompts/coordinator.md`, `lib/stage-attempt.sh`'s deterministic
     fallback) — so the Implementer knows what it is resolving before it
     even clones.
3s. **Dependabot conflicts: nudge, then take over (issue #250).** Requirement
   3g's `merge_conflicts` array also carries Dependabot's own conflicted PRs —
   open, non-draft, `mergeable` exactly `CONFLICTING`, authored by
   `DEPENDABOT_LOGIN` (`app/dependabot`, `lib/dependabot-bump.sh`) — regardless
   of `pr_label` or `branch_prefix`, neither of which a bot PR ever carries.
   Each such entry carries `bot: true` and three fields no ours-by-label entry
   does:

   - `rebase_requested` — true iff a comment already on the PR carries
     `dependabot_rebase_marker` scoped to *this exact* head SHA (12 hex
     chars, the same scoping as the `ref` itself): this system has already
     asked Dependabot to rebase this state and it has not resolved.
   - `superseded_by` — another open Dependabot PR's number, when it bumps the
     same dependency (same family: package manager plus dependency, read off
     the branch name by `dependabot_bump_family`) to a strictly newer version
     (`dependabot_bump_version`, compared via `sort -V`) — this PR's bump is
     moot regardless of its conflict.
   - `superseded_evidence` — present only alongside `superseded_by`:
     pre-formatted evidence text a Co-Ordinator pastes **verbatim** into a
     `voided` entry. It names this PR's own number as "PR #N" (which
     `lib/void-guard.sh`'s `void_pr_matches_item` reads off the item's own id
     for a `pr-<n>-…` item cited in the entry's own repo, as a bare citation
     always is — the id is minted from that very PR — and fetches PR #N live
     to corroborate it: `void_finishing_pr_reason` reads a `pr-<n>-superseded-…`
     item against **both** whether its author is still Dependabot and whether
     `dependabot_newer_open_pr`, re-run live against the repository's
     currently-open Dependabot pull requests — a listing bounded at the same
     stated `GITHUB_PR_LIST_LIMIT` cap the gatherer read at, where an empty
     answer that came back at the cap refuses naming the cap, since "no newer
     bump in the first N" is not "no newer bump" — still names a
     strictly-newer open bump of the same family; the mergeability test a
     `-conflict-` item gets
     proves nothing here, since a superseded bump can be superseded whether or
     not it still conflicts) and the superseding
     PR only by its branch name — never as "PR #M" and never by its URL (both
     of which the guard resolves live against that *other* pull request's own
     body and branch, and would refuse, since a different, independent bump
     will never carry this item's id in either). This is the one piece of
     free-text evidence in the whole pipeline a writer must not compose
     itself — see the "Dependabot's own conflicted PRs" entry in Design
     decisions.

   The write side is `scripts/nudge-dependabot-rebase.sh` (requirement 3s
   continued below); the read side above computes every field fresh each
   cycle and writes nothing — one definition of the classification rule
   (requirement 34a), shared by both.

   Three outcomes follow, all still ranked and claimed as an ordinary
   `merge_conflicts` candidate (requirement 15d), never a new source or
   ledger:

   - **First sighting** (`bot: true`, `rebase_requested: false`, no
     `superseded_by`): before the Co-Ordinator ever sees this cycle's
     `merge_conflicts` array, `agent-cycle.sh`'s per-repo gather step pipes it
     through `scripts/nudge-dependabot-rebase.sh`, which posts `@dependabot
     rebase` (this system's ordinary comment header and marker, plus the
     scoped rebase marker) and drops the candidate from the array — both the
     copy stored for the fingerprint and the copy the Co-Ordinator receives.
     There is genuinely nothing selectable yet; the next cycle's
     `gather-merge-conflicts.sh` read reports `rebase_requested: true` for
     the same head, a different array shape that busts the no-op fingerprint
     on its own (requirement 3b), exactly as requirement 3g's own base-moved
     transition does. This step is a real write, so `--dry-run` skips it. A
     failed post is logged as a `warning` and retried automatically next
     cycle, since a failed nudge leaves `rebase_requested: false`. If the
     nudge step itself fails to produce a valid result (`nudge-dependabot-rebase.sh`
     crashes, or emits something other than the expected object),
     `lib/candidate-select.sh`'s `gather_merge_conflicts` falls back to the
     gatherer's
     own read rather than losing every candidate in the repo — including our
     own, non-bot ones — over one broken write step, but that fallback drops
     first-sighting entries too, by the same predicate: a broken nudge step
     must never hand the Co-Ordinator an un-nudged `bot: true` candidate
     either. Taking this fallback is itself logged as a `warning` — the
     per-candidate loop that would otherwise report a failed post never runs
     on this path, so without one here a nudge step broken outright (missing,
     crashed, `jq` unavailable) would silently drop every conflicted
     Dependabot PR in the repo, every cycle, with no signal anywhere that the
     feature had stopped working. If the fallback's own filter then fails —
     the gatherer's array contains a non-object element, which only a
     malformed gatherer output can produce — it degrades to an empty
     candidate set for the repo, with a second `warning`, rather than
     aborting the cycle under `set -euo pipefail`.
   - **Still conflicting a cycle later** (`bot: true`, `rebase_requested:
     true`, no `superseded_by`): a **takeover** candidate. The Co-Ordinator
     may select it, but the work order it constructs sets `"takeover": true`
     and, unlike every other `merge-conflicts` work order, carries no
     `branch` — Dependabot's own branch is the bot's, never rebased or
     force-pushed by this system, so the Script claims and derives
     `agent/<ref>` for this work order exactly as it does for a non-finishing
     source (requirement 17a's carve-out below), and the Implementer follows
     the ordinary new-item Procedure (branch already claimed, open a draft
     PR) rather than the "branch and PR already exist" shortcut every other
     `merge-conflicts` item uses. It reads the bot PR's diff, recreates the
     same dependency bump on its own branch, and closes the bot's PR
     referencing the replacement (`prompts/implementer.md`'s "Dependabot
     takeover" section) — the underlying bump is what completes, unlike the
     ordinary rebase case, because there is no other PR left to carry it.
   - **Superseded** (`superseded_by` non-null, either state of
     `rebase_requested`): never nudged (nothing to gain by asking Dependabot
     to rebase a PR that has nothing left to do) and never a takeover
     candidate. Its ref mints the distinct shape `pr-<n>-superseded-<head-sha>`
     (requirement 3g), not `pr-<n>-conflict-<head-sha>`. The Co-Ordinator
     instead records it in `voided`, copying `superseded_evidence` verbatim as
     `evidence`, so it is never offered again — and, because the id shape says
     which claim is being made, requirement 34k's act-on-void step *does* close
     the pull request (TD-PPagop-26081304): unlike `pr-<n>-conflict-…`, which
     stays excluded because that shape also covers a live, unconflicted PR of
     ours whose conflict merely resolved, `pr-<n>-superseded-…` names only a
     Dependabot bump the void itself says is moot, so closing it discards
     nothing.

   `prompts/coordinator.md` states the first-sighting case explicitly, as a
   named third treatment alongside superseded and takeover, rather than
   leaving it to fall through the ordinary case's catch-all ("every other
   entry, including `bot: false`") on the strength of a separate paragraph
   alone — defence in depth for any path, present or future, that hands the
   Co-Ordinator an unfiltered array: a first-sighting entry must read as
   unselectable and not-a-void on its own terms, not only because nothing
   upstream is meant to let one through.

   Claimed and ranked exactly as any other `merge_conflicts` candidate
   (requirements 15d, 17a) with the one carve-out named above for a takeover's
   claim kind and branch. No new ledger, escalation concept, or source token
   is introduced — the acceptance test this requirement was written against
   (poetic-fiddle #129) is a candidate in the same `merge_conflicts` array
   every other conflicted PR is.
3z. **Dequeued-PR pre-fetch (TD-PPagop-26081409, issue #374).** For each
   configured repo whose `sources` include `dequeued` (requirement 48: freshly for the one repository this cycle picks, replayed from this node's expensive-gather cache for the rest), run
   `scripts/gather-dequeued.sh <slug> <pr_label> <branch_prefix>` and attach the
   array to that repo's entry as `dequeued`. It prints the PRs *this system
   raised that GitHub's merge queue removed over a merge-group checks failure
   without merging*: open, **non-draft**, carrying `pr_label`, head branch under
   `branch_prefix`, with `mergeable` exactly `MERGEABLE`, and whose
   most recent `lib/merge-queue.sh` `merge_queue_probe` reports `queued: false`,
   a non-null `dequeued_at`, and a `dequeue_reason` reading, case-insensitively,
   exactly `failed_checks`, **and whose dequeue is still unanswered** — no
   marked `actor=implementer` reply newer than `dequeued_at`, per the clause
   below. Each entry carries a head-SHA-scoped ref, the PR number and URL, the
   existing branch, its `base`, the head SHA, the `updatedAt`, the PR's own body
   verbatim, and the probe's `dequeued_at` and `dequeue_reason`. The array is
   ordered by `dequeued_at`, oldest first (`updated_at` breaking ties) — longest
   unanswered, first offered.

   - **Complementary to requirement 3g, never overlapping.** A merge queue
     dequeues a pull request whose own head is green but whose speculative
     merge with whatever sat ahead of it in the queue failed a required check —
     a real defect in the pull request, of exactly the kind requirement 3g
     already fixes autonomously when git surfaces it as a textual conflict
     instead. Requiring `mergeable == "MERGEABLE"` here is what keeps the two
     candidate rules from ever admitting the same PR head at once: a PR that is
     both dequeued *and* now conflicting against a base that moved further
     since is requirement 3g's candidate (a rebase is the fix it needs), not
     this one's, and requirement 3g's own rule already excludes anything not
     `CONFLICTING`.
   - **The allow-list, not deny-list, reason gate.** GitHub documents
     `RemovedFromMergeQueueEvent.reason` (and the `pull_request.dequeued`
     webhook's own `reason`) as a free-text `String`, not a fixed enum —
     checked 2026-08-14 against both the live GraphQL schema and
     octokit/webhooks' JSON Schema for the webhook payload — so this is
     deliberately an allow-list: only the one value confirmed against a real
     GitHub deployment as meaning a merge-group checks failure
     (`failed_checks`) is a candidate. A human manually removing their own
     queue entry is a different `reason` string this rule never recognises, on
     purpose — selecting it would have a cycle push a fix to a branch the
     human just took back, the wrong-direction failure this requirement's own
     tech-debt record was filed to prevent. An unreadable probe is never read
     as "not dequeued", the one direction `merge_queue_probe`'s own contract
     forbids, so a PR whose probe fails is simply not a candidate this cycle.
   - **The dequeue must still be unanswered, and that clause is load-bearing.**
     Every sibling finishing source stops yielding a candidate once the
     pipeline has acted, because the condition it keys on clears by itself: a
     rebase makes requirement 3g's `mergeable` stop reading `CONFLICTING`; any
     activity resets requirement 3e's clock. This source has neither.
     `RemovedFromMergeQueueEvent` is immutable timeline history, so the probe
     returns the same `dequeued_at`/`dequeue_reason` for ever, and
     `isInMergeQueue` returns to `true` only on a *human's* re-queue, which D17
     reserves to them. Without this clause, the Implementer's own fix push
     leaves every other clause true and moves only the head SHA — which mints a
     *fresh* ref (below) that no `blocked`, `void` or `claimed` record covers —
     so the pull request is selected again, at rank five, pointed at a
     merge-group run already fixed, and again after each round that pushes
     anything, for as long as the human takes to re-queue. That is the
     re-selection loop `scripts/gather-review-feedback.sh`'s header calls
     load-bearing to prevent, arising from the identical root cause: the agent
     cannot clear the state it is keyed on. So candidacy also requires
     `lib/handoff.sh`'s `handoff_round_answered` — requirement 34a's one
     definition, shared with requirement 3c and requirement 38c — to answer
     exactly `unanswered` for the round beginning at `dequeued_at`. Three
     properties of that call are deliberate: the round starts at `dequeued_at`
     rather than at the PR's birth, so a *second* dequeue after the fix
     correctly re-opens candidacy; `REREQUESTS_JSON` is not passed, because a
     review re-request does not answer a dequeue and passing the timeline would
     let requirement 38c's own re-request read back as one
     (tech-debt/TD-PPagop-26080804.md); and an `unknown` verdict — an
     unreadable reviews or comments response — drops the PR for the cycle
     rather than being collapsed into `unanswered`, the opposite of
     requirement 3c's default, because here `unanswered` is the verdict that
     creates work.
   - **The ref is scoped to the head SHA** — `pr-<n>-dequeued-<head-sha>`, not
     `pr-<n>-dequeued` — for the identical reason requirement 3g's own
     `pr-<n>-conflict-<head-sha>` is: a block recorded against one dequeued
     state must not swallow a later, possibly-resolvable one, and a re-detected
     dequeue at the *same* head keeps the same ref and stays correctly blocked.
     Unlike requirement 3g's, this scoping does **not** end the pull request's
     candidacy — a fresh push replaces the ref rather than retiring it, which is
     the clause above's job. The two are complementary and neither substitutes
     for the other.
   - **What it costs, per cycle.** One `merge_queue_probe` GraphQL call per PR
     surviving the listing filter — so the cost scales with the number of open,
     non-draft, `MERGEABLE`, `pr_label`-carrying PRs, not with the number of
     dequeues — plus, for each PR that probe admits, two REST reads (its
     reviews and its issue comments) for the answered clause. The bound on the
     first is `GITHUB_PR_LIST_LIMIT`, **not** `max_open_agent_prs`: requirement
     2.2's count deliberately excludes PRs waiting on a human, so a repo can
     hold more open labelled PRs than the cap. The probe cannot be skipped
     without weakening the gate, since an unreadable probe is never read as
     "not dequeued"; the two reads behind it are ordered last, so they are paid
     only for the PRs a dequeue has actually been found on.
   - **Its candidacy turns on a transition no signal on the PR itself
     carries** — sharper than requirement 3g's own case, since a dequeue moves
     neither the head, `updatedAt`, nor even `mergeable`, which is what
     requirement 3g's own array rides on. The only trace is a
     `RemovedFromMergeQueueEvent` on the PR's timeline, read live each cycle by
     `merge_queue_probe`. So this array, like requirement 3g's, is fed to the
     no-op fingerprint verbatim (`lib/noop-skip.sh`) — without it, a dequeue
     appearing or resolving would sit invisible behind a matching fingerprint
     until the forced recheck.
   - **Requirement 38f's human notice is independent of this rule, and
     deliberately wider.** `scripts/sweep-human-visibility.sh` posts its
     merge-queue-dequeued notice for every reason
     `merge_queue_dequeue_actionable` admits — a deny-list excluding only
     `"manual"` and `"merged"` (requirement 38f, agent-ops#394) — so a
     dequeue this requirement's own allow-list does not recognise still
     reaches a human even though nothing here can act on it. This
     requirement narrows only which dequeues become Co-Ordinator-selectable
     work, never which ones a human is told about.
   - Claimed as a finishing source exactly like requirements 3c, 3e and 3g
     (file claim on the existing branch, no new branch created; requirement
     17a's PR-keyed claim taken alongside it) — the branch and the PR predate
     the claim, and the Implementer works `prompts/implementer.md`'s "When
     `source` is `dequeued`" procedure rather than opening a new one.
   - Fails safe to `[]` (exit 0), with the same stderr discipline as
     requirement 3g. `shellcheck`-clean.
3j. **Issues pre-fetch.** For each configured repo whose `sources` include any
   `issues:<band>` entry (one source at four ranks — any band warrants the one
   fetch) (requirement 48: freshly for the one repository this cycle picks, replayed from this node's expensive-gather cache for the rest), run `scripts/gather-issues.sh <slug>`, which prints
   `{"candidates": […], "excluded": […]|null}`, and attach `.candidates` to
   that repo's entry as `issues` and `.excluded` as `issues_excluded` — or
   `[]` when `.excluded` is `null` (the gather did not run to completion; see
   "Degrades…" below), since the Co-Ordinator's own runtime input specifies
   `issues_excluded` as an array. Each
   `issues` entry is one candidate issue, whole thread included:
   `source: "issues"`, the bare issue number as `ref` (and as `number`),
   `url`, `title`, the `Priority` band as `priority` (read exactly as the
   source-state digest reads it — same field, same four names, same `Medium`
   default — because a band the digest and the candidate set derived
   differently is the fingerprint failure requirement 3b exists to prevent),
   `labels`, `author`, `created_at`, `updated_at`, the `body` verbatim, and
   `comments` (author, timestamp, body — verbatim, oldest first). Each
   `issues_excluded` entry is `{number, reason}` — one per issue the
   deterministic filter below dropped, `reason` one of `"assigned"`,
   `"blocked-label"`, or `"blocked-by: <ref>"` — see "The deterministic drop is
   reported, not lost" below.

   - **Why this source is pre-fetched at all.** It used to be the
     Co-Ordinator's own read, and that contract failed closed: cycle
     `20260727T145500Z-poetic-1-1431114` recorded the Co-Ordinator reasoning
     "no issue data provided in input; per the prompt, I do not re-query" — a
     rule that never existed — and skipping the entire issues walk while six
     selectable issues sat open. A source the model can silently decline to
     read is the model-side twin of the fingerprint gap requirement 3b warns
     about: no error, just tidy `none-selected` events over live work. The
     array makes the candidate set an input rather than an errand, the same
     move every drifted source before it got (3a, 3c, 3e, 3g).
   - **The deterministic half of requirement 16.4 is applied here**: assigned
     issues, issues labelled `blocked` (case-insensitive), issues naming an
     unresolved `Blocked-by:` reference (requirement 34j, checked live once
     each candidate's whole thread is in hand), and the pull requests the
     issues endpoint interleaves are dropped in the gatherer, so the
     Co-Ordinator never spends judgement on entries no rule would let it
     pick — the assignment drop also covers the Enabler's escalation issues,
     which are always assigned. The judgement half ("a question or discussion
     rather than actionable work", over the whole thread) stays the
     Co-Ordinator's — and because it stays there, requirement 3x makes it a
     *reported* judgement (requirement 16a) rather than a silent one: it is
     the only decline in any pre-fetched band that the Script cannot record
     for itself, and an unrecorded decline is a band that cannot be
     corroborated. This gatherer itself never reads the shared log, so it
     drops nothing for being blocked or void there — that exclusion runs as a
     later, second pass over this array, once the log's extracts are final
     (requirement 3u), and even then only a *stale* block is dropped: a
     blocked issue carrying fresh evidence stays, because requirement 18a's
     mandatory re-check needs the thread and `updated_at` in front of the
     Co-Ordinator to decide whether that evidence unblocks it. On a
     repository whose `issues` band requirement 48 replays rather than reads
     fresh, the assigned/`blocked`-label halves of this same drop are
     re-applied every cycle from that cycle's own `gather_source_state`
     sample instead (`issue_state_reapply`, lib/candidate-select.sh) — only
     the `Blocked-by:` third stays as recent as the band's own last fresh
     read (requirement 34j).
   - **A `pw::type:tech-debt`-labelled issue is dropped too, unreported** (D15
     as revised, #869; issue #875), on the same terms as the pull requests the
     issues endpoint interleaves: it belongs to the `tech-debt` band instead
     (requirement 3t), so it was never an `issues` candidate to begin with,
     and keeping the two bands disjoint is not a deterministic-filter drop
     `issues_excluded` needs to explain.
   - **The deterministic drop is reported, not lost** (agent-ops#447). Before
     this, the three drops above left nothing behind anywhere — no line on
     stdout, no line on stderr, no event in the shared log — so an issue an
     Enabler had just refined, or a human had assigned to themselves for
     their own reasons, could sit permanently unselectable with nobody able
     to tell why short of reading the filter's source. `issues_excluded`
     (above) is that record: the Script logs an `issues-excluded` event
     (requirement 33) per repo whose `issues` band it read fresh this cycle
     (requirement 48 — a repo replaying its cached band observed nothing new,
     so it logs nothing), when that repo's exclusion set changes from the one
     most recently logged, carrying the same `{number, reason}` pairs and a
     `count`, so the cycle log and the dashboard's log tail can both show "N
     issues excluded, and why" without a reader re-deriving the filter. The
     Co-Ordinator receives
     the same array as `issues_excluded` on its own runtime input
     (prompts/coordinator.md) — informational only, never a candidate list:
     nothing in it is eligible for selection, a re-check, or a
     `needs_refinement` report.
   - **Degrades to `candidates: []`, `excluded: null` (exit 0) on any API
     failure**, like requirement 3a and unlike the source-state digest: the
     output is *given to* the Co-Ordinator, so an empty `candidates` array is
     a faithful record of the input it got, and the independently sampled
     issues digest still busts the fingerprint when a real issue moves during
     the degradation. `excluded` degrades to `null`, not `[]` (review
     decision on agent-ops#452 concern 3): the deterministic filter did not
     run to completion, so the exclusion set is unknown, not known-empty, and
     an empty array would read downstream as "gathered, and nothing was
     excluded" — a claim the degrade cannot back. `lib/candidate-select.sh`'s
     own `gather_issues` carries the same reading one layer up, defaulting to
     `excluded: null` for the shapes it falls back on itself (a gather that
     produced no object at all). Failures are loud on stderr (teed to
     `issues-<repo>.err` in the cycle record).
   - The listing-plus-comments read is one paginated GraphQL walk
     (`issue_prefetch_open_issues`, `lib/issue-prefetch.sh`, agent-ops#1085),
     stated and checked the same way `gh pr list`'s own cap is
     (`ISSUE_PREFETCH_MAX_PAGES`, default 2000 open issues) rather than
     silently truncated at its predecessor's own uncontrolled first REST
     page; each issue's own comment thread takes one 100-comment window, the
     newest 100 where a thread runs longer than that. Both bounds are stated
     in that function's own header rather than silently applied.
3k. **Implementation-plan path and report-directory passthrough.** The
   `implementation-plan` source names no path of its own: for each configured
   repo whose `sources` include it, attach that repo's
   `implementation_plan_path` (from its `config.json` entry) to its
   runtime-input entry, so the Co-Ordinator knows where to read that repo's
   plan document without any path fixed in the prompt or in code — a repo
   with a differently named or located plan needs only its own
   `implementation_plan_path`, never a prompt change. A repo that lists the
   source without configuring the path is a startup misconfiguration: the
   Script exits with an error before any stage runs, the same guard as
   `enabler_assignee` (Configuration table). There is no gatherer script and no
   pre-fetch, as for `project-review`: the Co-Ordinator reads the file itself
   (`gh api repos/<slug>/contents/<path>`).

   The `project-review` source's own live read names no directory of its own
   either (issue #1018): for each configured repo whose `sources` include it,
   attach that repo's resolved `report_directory` to its runtime-input entry —
   `config_repository_review_repos`'s own resolution of
   `repository_review.repos[].report_directory`/`repository_review.defaults`'s,
   falling back to the shipped `reviews/project-review-%Y-%m-%d` where the
   repo configures neither, the identical value the Refiner's own pre-fetch
   (requirement 3y) and the Reviewer-Agent's write path
   (`docs/spec/review.md` R4a) already resolve to, read
   from the same helper rather than re-derived — so a repo overriding
   `report_directory` needs only its own config, never a prompt change.
   Unlike `implementation_plan_path`, a repo listing `project-review` with no
   `report_directory` configured is not a misconfiguration: the shipped
   default is a valid resolution in its own right, so the field is simply
   present with that value rather than the engagement being refused at
   startup.

   The runtime-input entry also carries `report_directory_resolved` (issue
   #1891): the latest existing review folder's own path, resolved by calling
   `report_directory_most_recent` (`lib/report-directory.sh`, the same helper
   `scripts/gather-project-review.sh` and the Refiner's own pre-fetch already
   call) against that repo's resolved `report_directory` — so the
   Co-Ordinator's live read of this source (requirement 3y, requirement 15)
   reads a Script-resolved path directly rather than walking the format
   string by hand. Present alongside `report_directory` wherever that
   resolution returns a path; wherever it returns nothing the entry carries
   `report_directory` with no `_resolved` field, and `prompts/coordinator.md`
   falls back to the hand-rolled walk. An empty resolution does **not**
   distinguish "no review folder exists yet" from "the listing behind the
   resolution failed": this call site declines the degraded-read signal
   `report_directory_most_recent` offers (requirement 3y, issue #1024) with an
   explicit `|| true`, because the Co-Ordinator's own fallback walk re-derives
   the value anyway, and because this gather runs bare under `agent-cycle.sh`'s
   `set -euo pipefail`, where letting a rate limit inside the walk reach
   errexit would cost the whole cycle rather than one optional field. So the
   field's absence is never evidence that the repository has no review to
   read, and `prompts/coordinator.md` says so where it describes the
   fallback — a caller that does need the distinction reads the exit status,
   as requirement 3y's own `--current-date` mode does. Unlike the eight
   bands, this resolution is not part of requirement 48's
   one-repository-per-cycle rotation: it is
   one listing call for every repository whose `sources` lists
   `project-review`, every cycle, because every entry the Co-Ordinator might
   be handed needs the field and not only the one repository gathered freshly
   — a cheap probe on the same footing as the ones requirement 48's own
   closing paragraph leaves unrestricted.
3h. **Refinement carry-forward.** The Co-Ordinator's runtime input carries a
   `refinements` map — repo → item → the latest `item-refined` payload
   (requirement 33), for items that are not void — built from the fleet's log
   union by `refinements_map` in `lib/cycle-state.sh`, alongside the `blocked`
   and `void` extracts and keyed the same way (requirement 34's repo+item rule:
   a refinement written for one repo's `TD26071805` is not a specification of
   the other's).

   It exists because a refinement has to land where a *future* Co-Ordinator will
   read it, and for most item types there is nowhere. An issue has a thread, and
   requirement 36b puts the refinement there as one authoritative comment that
   requirement 20 already pastes into the work order; a tech-debt record, a
   review recommendation, a plan task or a finding has no such surface, and no
   actor here may edit the register. So for those the specification lives in the
   log and this map is what returns it to selection. Without it the Enabler would
   write a refinement, the item would be unblocked, and the next work order would
   be composed as though nothing had been settled — paying for the refinement and
   discarding it.

   Void items are excluded: a refined specification of work that does not exist
   would arrive in the Co-Ordinator's input arguing, in the pipeline's own voice
   and in detail, for an item requirement 34c says must never be selected again.

   **A phantom `item-refined` event is skipped here on requirement 35a's own
   terms (TD-PPagop-26082819):** an event whose `comment_url` names no comment
   — no `#issuecomment-` anchor or REST API comment form
   (`refinement_comment_url_valid`, `lib/refinement.sh`, the one predicate) —
   is excluded from the map exactly as if it had never been logged, and the
   latest event that does pass the shape check is used instead; no entry if
   none does. The readers of this judgement must never disagree: this map
   decides both what the Co-Ordinator sees as refined and what
   `refiner_candidate_items` (requirement 39a (The Refiner)) excludes from a fresh
   refinement, while requirement 17f's traceability gate resolves the recorded
   URL at claim time — so an entry only this map trusts is an item the
   Co-Ordinator keeps proposing, the Refiner never re-specifies, and the gate
   can never admit: every claim faults `untraceable`, and the fleet stands
   down on work nothing in the log's own lifecycle can repair. Skipping the
   phantom restores one answer everywhere: the item reads unrefined, the
   Refiner owes it a genuine specification under its unchanged
   `refinement_policy`, and the dropped entry leaves the no-op fingerprint's
   refinements projection (requirement 3b), so the correction itself wakes a
   fleet the phantom idled. The same skip governs `decisions_map`'s
   superseded test (requirement 36d): a phantom wrote no specification, so it
   never retires a pending decision. The skip is silent here — requirement
   39c (The Refiner)'s recording seam refuses the shape, so the phantom set cannot grow,
   and requirement 35a's own warning still names any phantom standing behind
   an open block.
3o. **Claim visibility (issue #175).** The Co-Ordinator's runtime input carries
   a `claimed` array — `{repo, item, age_hours}`, plus `pr_number` where the
   claim is known to target one (issue #238; see requirement 17a's PR-keyed
   claim) — alongside `blocked`, `void` and `refinements`, gathered fresh by the
   Script for every repo it is about to walk, immediately before the
   Co-Ordinator launches. It is the union of two independent sources, deduped by
   repo+item:

   - every claim-registry entry younger than `claim_ttl_hours` for that repo
     (`lib/claim.sh claims`) — the only source for a *file* claim, since
     `review-feedback`, `merge-conflicts`, `dequeued`, `landing-refusals` and
     `abandoned-drafts` finish an
     existing PR and mint no branch; `age_hours` is the entry's exact age, and
     `pr_number` rides along when the underlying registry entry recorded one —
     which, for all five of those sources, is always, once requirement 17a's
     PR-keyed claim exists alongside the item-keyed one; and
   - every live `<branch_prefix>*` branch on the target repository
     itself (`lib/claim.sh branches`), which still catches a claim the
     registry missed — `state_repo` unset, or a best-effort registry write
     that failed — with `age_hours` reported as `null` when no registry entry
     backs it, and no `pr_number` at all: a branch name carries no PR number,
     only an item ref. This runs after the claim gc (2.1a) has already swept
     anything past the TTL that was left untouched, so a live branch found here
     is either still fresh or has real work pushed to it — either way it
     belongs in the list, and needs no separate TTL check of its own.

   Before this existed, exclusion 3's second half (a live claim branch is a
   claim, even before its draft PR appears) was a live check the Co-Ordinator
   itself had to perform — nominally `git ls-remote` per repo, in practice a
   step routinely skipped by the smaller model this stage runs on, and one that
   the four finishing sources' file claims (invisible as branches) could never
   have covered even performed perfectly. `claimed` replaces it: exclusion 16's
   second bullet is now a lookup against pre-fetched data, not a live query, and
   it is complete over both claim shapes. A candidate whose repo+item is not in
   `claimed` genuinely has no fresh claim on it — the array is not a hint to go
   verify, it is the answer.

   Item refs recovered from a branch name mirror `claim_branch_for`
   (requirement 17a): `<branch_prefix><ref>` strips to `<ref>` for a fresh
   claim. That recovery is exact in practice for every item
   type this system ever mints such a branch for — an issue number, an alert
   ref, or a project-review ref — none of which contain a
   character `claim_branch_for`'s sanitiser would have touched, so there is
   nothing lossy to recover from.
3p. **PR-level candidate exclusion (issue #238).** The scoped item refs the
   five sources that finish an existing pull request mint — per review round,
   per head SHA, or (for `landing-refusals`) per set of unreconciled comment
   ids (requirements 3c, 3e, 3g, 3z, 53) — mean a
   peer's claim on a PR under one round's or one head's ref is invisible to
   exclusion 16's ordinary repo+item lookup against `claimed` the moment a
   fresh review round or a fresh push mints a *different* ref for the *same*
   PR — which is how PR #205 was worked by three nodes at once on 2026-08-07
   (one poetic-2 Co-Ordinator run even *saw* a peer's claim on the PR and
   reasoned past it, because the item ref genuinely didn't match).
   Deterministic code closes this, not a comparison added to the
   Co-Ordinator's own judgement calls: for each repo, before its
   `review_feedback`, `merge_conflicts`, `dequeued`, `landing_refusals` and
   `abandoned_drafts`
   arrays are assembled into the runtime input, the Script drops any candidate
   whose `pr_number` appears among that repo's freshly gathered `claimed` set's
   `pr_number` values. A PR already excluded this way never reaches the
   Co-Ordinator's input at all, so there is nothing left for it to reason past.

   This is a visibility layer, not the hard gate — a claim taken after this
   filter ran (a peer's cycle overlapping this one) is still possible, and
   requirement 17a's PR-keyed claim is what actually excludes it, fleet-wide,
   the same create-only way every other claim does.
3q. **Item-level candidate exclusion.** The same deterministic-code-not-
   model-judgement decision as 3p, extended from PR numbers to item refs and
   from those five sources to every array the Script pre-fetches:
   for each repo, before its `issues`, `findings`, `tech_debt`,
   `review_feedback`, `merge_conflicts`, `dequeued`,
   `landing_refusals` and
   `abandoned_drafts` arrays are assembled into the runtime input, the Script
   drops any entry whose `ref` — the exact string a claim on that item is
   keyed on, minted by every gather script by construction — appears among
   that repo's freshly gathered `claimed` items. What remains of the prompt's
   claimed-item exclusion is only the sources the Co-Ordinator derives itself
   (project-review, failed-runs, implementation-plan), which have no
   pre-fetched array to filter.

   The incident that makes this a requirement rather than a tidy-up: on
   2026-08-09 a Co-Ordinator read four issues as "claimed in the live
   branches" — the `claimed` array had done its job perfectly — then
   reasoned that claimed items still make good alternates because the
   Script's claim is atomic anyway, ranked three of them, and the cycle
   lost all three claims and stood down, repeatedly, across most of a day.
   Visibility was never the gap; the judgement step was. An item filtered
   out before the model sees it cannot be reasoned past.

   Like 3p, this is a visibility layer, not the hard gate: requirement 17a's
   atomic claim still arbitrates anything that lands in the gather-to-claim
   window, and 17a's pre-claim skip is the same principle applied on the
   claim side for the derived sources this filter cannot reach.
3t. **Tech-debt pre-fetch, and deterministic blocked/void exclusion (issue
   #310; the store moved from the in-repo register to labelled issues by D15
   as revised, #869/#875).** For each configured repo whose `sources` include
   `tech-debt` (requirement 48: freshly for the one repository this cycle
   picks, replayed from this node's expensive-gather cache for the rest),
   run `scripts/gather-tech-debt.sh <slug>` and attach the array
   to that repo's entry as `tech_debt`. Each entry is one candidate: an open
   GitHub issue carrying the product-managed label `pw::type:tech-debt` — the
   D24 trust anchor, since only a collaborator with triage can apply it, so an
   issue's membership of this band is trustable even though its body stays
   framed as untrusted data — that has also survived the same deterministic
   filter requirement 3j applies to the `issues` band: not assigned, not
   labelled `blocked`, and naming no still-open `Blocked-by:` reference
   (requirement 34j), shared between the two gatherers via
   `lib/issue-prefetch.sh` rather than re-derived. `source: "tech-debt"`, the
   bare issue number as `ref` (and as `number`), `title`, `url`, `labels`,
   `author`, `created_at`, `updated_at`, and the whole issue thread — body and
   every comment, verbatim — as `body`/`comments`. Sorted by issue number
   ascending. Degrades to `[]` (exit 0) on any failure, like requirements 3a
   and 3j: this array is *given to* the Co-Ordinator, so an empty array
   faithfully records what it saw, and the repo's `head_sha` (already in the
   no-op fingerprint, requirement 3b) still busts the fingerprint when a real
   commit changes the candidate set out from under a transient failure.

   **Transition note, accepted deliberately (issue #875).** Between this
   gatherer landing and a repo's own register migration (#880 and its
   siblings in the other target repos), that repo's unmigrated register items
   are invisible to this band: `scripts/gather-tech-debt.sh` never reads a
   register file, only the label. A repo with no `pw::type:tech-debt` issues
   yet contributes `[]`, indistinguishable from one with no open debt at all
   — debt is a low-urgency band, and the gap closes as each repo migrates.

   Claimed-item exclusion is applied the same way as for every other
   pre-fetched array (requirement 3q, above) — `exclude_claimed_items` against
   that repo's freshly gathered `claimed` set, during the same repo-loop pass
   that gathers `tech_debt`.

   Blocked/void exclusion is applied in a **second** pass, once
   `blocked_json`/`void_json` are final — after every reconciliation
   requirement 34 runs (34f, 34g, 34i, 34j) and after requirement 34n's
   retirement — because both extracts depend on this same repo loop's
   `ordered_repos_json` for their own work-gone reconciliation and so do not
   exist yet at gather time. `exclude_blocked_or_void_items` drops any
   `tech_debt` entry whose `ref` is recorded blocked or void for that repo,
   scoped by repo exactly as the Co-Ordinator's own reading of
   `blocked`/`void` always has been (a blank `repo` on an old, pre-scoping
   event still matches every repo). This is safe to do deterministically in
   full, unlike the `issues` source's blocked exclusion (requirement 3j),
   because a `tech_debt` ref is now a bare issue number, so requirement 34i's
   work-gone reconciliation clears a stale block the same way it clears one
   for `issues` — the number is absent from the repo's open-issue digest —
   and a still-open issue naming an unresolved `Blocked-by:` reference never
   reaches this array to begin with: nothing filtered out here is ever a
   block that needed a second look. `issues` still keeps a live re-check for
   a blocked entry carrying fresh evidence — requirement 18a needs the thread
   itself — but every other pre-fetched band, including `issues`' own stale
   blocks and every band's void entries, gets this identical second pass or
   the purpose-built variant requirement 3u describes, once
   `blocked_json`/`void_json` are final at this same point in the cycle.

   What remains in each repo's `tech_debt` array after both passes is the
   Script's complete, no-per-item-judgement-required answer to
   "what could the Co-Ordinator actually select from this band this cycle".
   `prompts/coordinator.md`'s exclusions 1–3 are already applied for it before
   the Co-Ordinator ever runs. It is read *after* requirement 2.2a's
   back-pressure decision, not at the second pass above, so that it describes
   the array the Co-Ordinator is actually handed: a back-pressured cycle
   narrows every repo to the four finishing sources and empties `tech_debt`
   with them, and the eligible set is then correctly empty for a verdict that
   was never allowed to consider the band. Requirement 3x extends that reading
   to every other pre-fetched band and folds all of them into one
   Script-internal set, `eligible_items_json`
   (`coordinator_eligible_items`); the tech-debt band described here is one
   band of it, and what follows is stated for tech-debt because that is the
   band it was proven on, not because anything about it is tech-debt-specific.

   **Why this source is pre-fetched at all.** It used to be the Co-Ordinator's
   own read: the prompt told it to unpack the register tarball itself
   (`gh api repos/<slug>/tarball/<default-branch> | tar -xz`, then
   `grep -l '^status: open'`) and cross-reference each row against
   `blocked`/`void`/`claimed` by its own judgement. Between 2026-08-10 and
   2026-08-12, with roughly 30 eligible items sitting in the register
   (29 of them fully eligible by the Script's own later count), the
   Co-Ordinator returned `none-selected` with reasons that misdescribed the
   band — "remaining tech-debt candidates require per-item evaluation against
   blocked/void/claimed records", "open tech-debt heavily voided or blocked"
   (29 of 30 were neither) — the same failure shape as the incident 3q's
   history section describes, applied to a source 3q's own fix never reached
   because tech-debt had no pre-fetched array for it to filter. Requirement
   3b's no-op fingerprint then cemented one such wrong answer for a full day
   (see 3b's own note on rejected verdicts, below): 6 selections on 08-10, 0
   on 08-11 (240 stand-downs, not one Co-Ordinator invocation), 9 on 08-12.
   Handing the candidates over pre-fetched and pre-filtered, exactly as every
   other drifted source got before it (3a, 3c, 3e, 3g, 3j), removes the
   judgement step that kept getting reasoned past.

   **Machine corroboration, and fingerprint rejection.** A `selected: false`
   verdict owes an account of every item the eligible set names: each
   must have been reported in `needs_refinement` (under that item's own
   `source`, requirement 16a) or voided this same cycle (requirement 34c) —
   the only two
   ways a bar-clearing item may be declined without being selected — unless
   that source's `refinement_policy` is `"required"`, where an unrefined item is
   silently skippable by design (requirement 39a (The Refiner)) and needs no report. Once
   the Co-Ordinator's final message is in hand, the Script tests every
   eligible entry against **what it recorded from those two arrays, never the
   arrays verbatim**: an account is the state the report left behind, not the
   report itself. A `needs_refinement` entry therefore counts only if
   `record_needs_refinement_block` accepted it — one dropped at requirement
   34d's five-field bar records nothing but a warning, so its item stays
   open, unclaimed and eligible, and letting it count anyway would satisfy
   the corroboration, arm the fingerprint, and stand the next byte-identical
   cycle down on a verdict that never engaged with the band: this incident's
   freeze, reached again through the narrow door of every eligible item
   reported and every report malformed (`missing` and `evidence` are exactly
   the fields a small model omits). A `voided` entry counts whichever way the
   void guard rules, and this asymmetry is deliberate rather than a gap:
   both of the guard's outcomes write state — a pass records the void, a
   refusal records a block (requirement 34d) — so either way the item leaves
   the next cycle's eligible set, and the guard's live-evidence rejection,
   which no shape test could reproduce in a projection, needs no reproducing.
   One rule covers both arrays: count what was recorded. Any eligible entry
   left unaccounted for is logged as a `warning` event (`eligible_total`, the
   unaccounted `{repo, item}` pairs, and the verdict's own `reason`) — the
   machine-readable trace of exactly the contradiction this requirement's
   history section describes, available on the dashboard without a human
   re-deriving it from prose.

   When any item is unaccounted for, the `none-selected` event this cycle logs
   omits the `fingerprint` field entirely (carrying `td_verdict_rejected: true`
   instead — a name requirement 3x keeps for its readers' sake though the gate
   is no longer tech-debt-only) — the same treatment requirement 3b's own "an empty fingerprint is
   omitted, not stored" already gives a fingerprint with nothing to compare,
   extended to a fingerprint that exists but is not trustworthy. Requirement
   3b's `noop_last_none_selected` only ever matches against a `none-selected`
   event that carries a `fingerprint`, so a rejected verdict cannot arm the
   no-op short-circuit: the very next cycle asks the Co-Ordinator again,
   unconditionally, rather than replaying the wrong answer until
   `none_selected_recheck_hours` forces a recheck.
3u. **Blocked/void exclusion, extended to every other pre-fetched band, and
   `void` withheld from the Co-Ordinator's own input entirely (issue #320).**
   Requirement 3t proved the pattern on one band: candidates the Script
   already knows are blocked or void need no per-item model judgement to
   exclude, and handing them over anyway is exactly the unreviewed band a
   small model confabulates a verdict about (issue #310). That pattern now
   applies to every pre-fetched band, not tech-debt alone.

   Once `blocked_json`/`void_json` are final — the same point in the cycle
   3t's own second pass runs, after every reconciliation requirement 34 runs
   and after requirement 34n's retirement — the Script re-applies
   `exclude_blocked_or_void_items` to `findings`, `review_feedback`,
   `abandoned_drafts`, `merge_conflicts` and
   `human_visibility`, exactly as it
   already did to `tech_debt`: any entry whose `ref` is recorded blocked or
   void for that repo is dropped, scoped by repo exactly as
   `BLOCKED_ITEMS_JQ`'s own repo-or-blank match (a blank `repo` on an old,
   pre-scoping event still matches every repo). There is nothing
   tech-debt-specific about the exclusion itself — only tech-debt was the
   band it was first proven safe on.

   `issues` is the one band this cannot apply to unmodified. Requirement 18a
   obliges the Co-Ordinator to re-read a blocked issue's live thread when its
   `updated_at` carries evidence posted after the block was last confirmed
   current, and a candidate the Script drops before the Co-Ordinator ever
   sees it cannot be re-read — dropping every blocked issue here would
   silently retire that mandatory re-check rather than apply it. So `issues`
   gets a purpose-built pass instead, `exclude_blocked_or_void_issues`: void
   entries are dropped unconditionally, exactly like every other band (a void
   has no re-check to preserve — requirement 34c: only a human's `unvoided`
   ever reopens one), but a blocked entry is dropped only when it is
   *stale* — its `updated_at` no newer than the later of the block's own `ts`
   and its newest `recheck_clean_ts`, requirement 18a's own comparison,
   mirrored verbatim (`test/cycle-state.test.sh`'s `needs_mandatory_reread`
   pins the same comparison against the same fields). That is exactly the
   "skip it on the marker alone, no re-read needed" case the prompt already
   told the Co-Ordinator was mechanical (prompts/coordinator.md's "Re-checking
   blocked items"), so removing it from the Co-Ordinator's judgement removes
   no judgement at all — a blocked issue carrying fresh evidence still
   reaches the Co-Ordinator, exactly as before this requirement, for the live
   re-read only it can perform.

   What remains in each band after both passes is the Script's own,
   no-per-item-judgement-required answer to "what could the Co-Ordinator
   actually select from this band this cycle" — open, unclaimed, unblocked
   (or, for `issues`, blocked-but-due-a-re-read), not void — for every
   pre-fetched band without exception, not tech-debt alone.

   **`void` is removed from `coordinator_input` entirely.** Every band the
   Script pre-fetches whole is now void-filtered before the Co-Ordinator ever
   runs, so a raw list for it to apply that same judgement to by eye no
   longer has a use the nine pre-fetched bands need — and the three sources
   the Co-Ordinator still derives itself (`project-review`, `failed-runs`,
   `implementation-plan`) carry no array in `coordinator_input` for the Script
   to check a list against in the first place (requirement 3y's arrays for two
   of them reach the Refiner only), so withholding the list changes
   nothing structural for them either: the Co-Ordinator's own live evidence,
   read while evaluating each candidate ("Voiding an item yourself"), was
   always how those three get voided, list or no list. The Co-Ordinator may
   still *add* a fresh entry to `voided` in its verdict without ever having
   seen the existing extract — the Script's void corroboration (requirement
   34d) validates that entry independently, against the evidence cited, never
   against a list the model was shown. `blocked` stays, because `issues`' live
   re-check duty and the three Co-Ordinator-derived sources' own exclusion-1
   check both still need it, but trimmed to the fields either duty actually
   reads — `repo`, `item`, `ts`, `detail` and `recheck_clean_ts` where
   present — dropping `stage`, `cycle`, `event` and an Implementer's
   `unblock_condition`, none of which `prompts/coordinator.md` ever reads off
   a `blocked` entry. `detail` itself is one line (agent-ops#1379): its first
   line, and at most 200 bytes of that, ending in `…` where it was cut,
   because what either duty reads off it is *what is in the way*, and the
   Implementer's whole needs-refinement report or a void-corroboration
   transcript is not that — on 2026-09-23 the fleet's 110 recorded blocks
   carried 51 KB of `detail` (median 381 bytes, longest 2,478) into the band
   requirement 4i's ladder cannot shed. And, given the cycle's repo array,
   `coordinator_blocked_view` keeps only an entry for a repository that array
   names, or for no repository at all — the same filter "4. Co-Ordinator
   stage" applies to each engagement's own list, so an entry for a repository
   no engagement runs for is never sent and requirement 4i's overhead
   measures what will be spent (37 of those 110 blocks named a slug the fleet
   no longer configures). The view reads nothing of the repo array but its
   slugs, which no rung of the fit changes, so the measurement and the
   assembly may each call it against the array as they find it.

   The no-op fingerprint (requirement 3b) is unaffected by any of this: its
   own input still hashes the full, untrimmed `blocked_json` and `void_json`
   verbatim, exactly as before this requirement — a void-state or block-state
   change must still buy the next cycle a fresh look, even though the
   Co-Ordinator itself no longer reads a void list and reads a narrower
   `blocked` one. Trimming or removing what the *model* sees is deliberately
   a separate decision from what the *fingerprint* covers, made once here and
   never coupled: coupling them would let a `void` extract edit stop busting
   the fingerprint the same day it stopped being visible to the model, for no
   reason connected to whether the fleet's state had actually changed.

   Both extracts this requirement's exclusions read arrive at
   `exclude_blocked_or_void_items`/`exclude_blocked_or_void_issues` on stdin,
   never in argv, exactly as requirement 3t's own second pass already
   delivered them (requirement 4g) — this requirement adds call sites to an
   existing, already-compliant function and a new function built the same
   way; neither introduces a new `--argjson` delivery for either extract.

3v. **Corroboration, scoped to the repositories that said no, and mechanical
   fallback selection (issue #321; scope narrowed to drop the model retry by
   issue #587).** Requirement 3t's gate stops a rejected verdict from arming
   the no-op fingerprint, so the *next* cycle asks again unconditionally —
   but the rejected cycle itself still stood down, and before requirement
   15's per-repository split, if the confabulation recurred cycle after
   cycle (as it did across 2026-08-10 to 08-12, issue #310), the fleet
   degraded into a warning-per-cycle loop with zero selections: visible on
   the log, but liveness still depending entirely on the model eventually
   getting it right. Requirement 15's split changes the blast radius of a
   single confabulation on its own: one repository's own engagement
   returning a wrong `"selected": false` now costs only that repository's
   own opportunity this cycle, not the whole cycle's, since every other
   configured repository still got its own independent engagement and its
   own independent chance. A model retry — asking the same repository again,
   in the same cycle, when its own engagement confabulated — was judged not
   worth its own added cost once N engagements per cycle already exist
   instead of one (D14, priced in the pull request that made this change):
   retrying every repository that said no could as much as double this
   cycle's own already-multiplied cost for a recovery this repository's own
   *next* cycle already provides for free. What remains is corroboration
   (unchanged in kind, narrowed in scope) and the same mechanical fallback as
   before, now the sole recourse once every repository's own confabulation is
   on the record:

   - **Corroboration, scoped to the repositories whose own engagement said
     no.** A repository that selected needs no corroboration — it already
     accounted for its own eligible work by returning it — so only a
     repository whose own verdict was `"selected": false` can have left
     something eligible unaccounted for. Once every configured repository's
     own engagement this cycle has answered, the Script checks the *union*
     of the eligible items belonging to repositories that said no against
     the *union* of every repository's own recorded `needs_refinement`/
     `voided` entries (every repository's own entries, selected or not, fold
     into this union — a selected repository can still report one alongside
     its candidates) — `unaccounted_items` (requirement 3x), applied exactly
     as it was before the split, just against these two fleet-scoped-but-
     no-repository-filtered unions rather than the single engagement's own
     recorded bands.
   - **Fallback selection.** If the merged, reordered candidate list
     (requirement 15z) from every repository that *did* select is empty —
     nothing was selected fleet-wide — and the corroboration above finds an
     eligible item some repository's own `false` verdict left unaccounted,
     the Script selects mechanically — no further Co-Ordinator engagement of
     any kind this cycle. `fallback_select_candidate` walks a fixed
     source-band priority order over `ordered_repos_json`, approximating
     `prompts/coordinator.md`'s "Selection algorithm": the five cross-repo
     overrides (security, urgent issues, review-feedback, merge-conflicts,
     abandoned-drafts) ahead of the residual bands (human-visibility, high
     issues, tech-debt, medium issues, low issues,
     code-quality) — restricted to the bands `ordered_repos_json` itself
     carries an array for; `failed-runs`, `implementation-plan` and
     `project-review` have none there and are skipped rather than
     approximated (each would need a live `gh` read or a tree fetch the
     Co-Ordinator performs for itself, which this mechanical path does not —
     and requirement 3y's arrays for the latter two are the Refiner's alone,
     deliberately not a selection input). It is an
     approximation in one further respect, which costs at most a
     less-preferred pick on a path that exists to pick *something*: the walk
     is band-major across the whole fleet rather than the per-repository
     source walk requirement 15 now runs, and it is a **separate**
     approximation from requirement 15z's own merge — the two do not share
     code, so an edit to one's band order does not silently move the other's
     (so a lower-ranked repo's higher band outranks a higher-ranked repo's
     lower one, here, where requirement 15z's own merge would not). It is
     **not** an approximation of what the cycle was allowed to select from:
     each repo's own configured
     `sources` list bounds every band, and an issue's `Priority` band must
     have its own `issues:<band>` token listed, exactly as for the
     Co-Ordinator. Requirement 3x made that necessary as well as tidy — the
     pre-fetched arrays stopped being the authority the moment requirement
     2.2a's back-pressure began narrowing the *list* while leaving `findings`
     and `human_visibility` populated. Under requirement 3t
     the point could not arise (back-pressure empties `tech_debt`, so a
     tech-debt-only gate could never reject during a restricted cycle, and
     this function was unreachable); under a gate that also counts the
     finishing sources it can, and a fallback blind to `sources` would answer
     a back-pressured cycle by starting fresh work through a full landing gate.
     `eligible_items_total > 0` is what let
     the gate reject a verdict at all, and every band that set counts has a
     rank in this walk, so there is always something to fall to — the one
     guarantee this path depends on. Its single exception is a superseded
     Dependabot merge-conflict entry, which the gate counts (the prompt
     requires it in `voided`) but this walk declines exactly as the prompt
     does; a cycle whose only unaccounted item is one of those reaches the
     no-candidate branch below, which stands down rather than assuming the
     guarantee.
     `refinement_policy` (requirement 39a (The Refiner)) binds the mechanical pick exactly
     as it binds the Co-Ordinator: an unrefined item from a `"required"`
     source is never a fallback candidate, and a `"preferred"` source's
     refined items rank ahead of its unrefined ones within their own band
     (a stable sort, so nothing else about the band order moves). The
     alternative — a fallback deliberately outside the refinement discipline,
     on the grounds that a frozen fleet is worse — is rejected because it is
     not the trade it appears to be: a `"required"` source's unrefined item
     is one nobody has specified yet, so selecting it hands the Implementer
     the generic `acceptance` string above and nothing else, which is the
     outcome requirement 39a (The Refiner) exists to prevent, and it buys no liveness the
     guarantee above does not already provide. Nor does it cost that
     guarantee anything, band by band: `unaccounted_items` drops an eligible
     entry whose own source is `"required"` before it can make the gate
     reject at all, so a band that could send a cycle here is by construction
     a band this exclusion does not empty.
     Each candidate is built straight from its own pre-fetched entry's own
     fields — the same `item`/`branch`/`pr_url`/`pr_number`/`takeover` shape
     `prompts/coordinator.md`'s "Output" section requires per source — with
     `context` a verbatim paste of the entry's own body and `acceptance` a
     generic instruction naming the source's standard procedure, since no
     model composed a bespoke one; `model`/`model_reason` are
     `implementer_model_default` and a fixed string naming this as a
     mechanical pick, and `pr_label` is `config.json`'s own key — the same
     value the Co-Ordinator copies from its runtime input into every
     candidate (requirement 20). Composing it here is redundant-but-harmless
     rather than load-bearing (agent-ops#956): the claim loop
     (requirement 17a) stamps the configured `pr_label` onto whichever
     candidate wins — this mechanical one included — unconditionally, so the
     Implementer (requirement 23) is labelled correctly regardless of
     whether this composition ran at all. The single winning candidate is fed into requirement
     17a's ordinary claim loop exactly as a model-ranked candidate would be —
     no special-cased race, so a lost claim stands the cycle down the same
     way any exhausted candidate list would.
   - **Distinguishable in the log.** A fallback-won `selection` event carries
     `selected_by: "script-fallback"` (present only then — a model pick's
     event has no such field), which lets a human reading the raw log tell a
     fallback pick from a model pick by eye. The field has no reader outside
     `agent-cycle.sh`'s own two write sites: the dashboard's actor and model
     scorecards panel (`docs/spec/dashboard/README.md`, issue #610) reports the
     Co-Ordinator's verdict quality as the corroboration rate requirement 3w
     computes from `corroboration` events, not from a fallback count keyed on
     this field.
     The one corroboration check this cycle runs — across every repository
     that said no, once — logs its own `corroboration` event (`attempt: 1`
     always, now that there is no second attempt to distinguish it from;
     `verdict: "accepted"|"rejected"`, `eligible_total`, `unaccounted_total`,
     requirement 3x's per-band `bands` tally on a rejection), so a rejection's
     own scope is visible on the event that explains it.
   - **Fingerprint un-arming is unchanged, and `none-selected` still names
     the outcome.** Requirement 3t's own rule — omit `fingerprint` from
     `none-selected` whenever any eligible item is left unaccounted —
     applies identically here. A cycle that *falls back* logs no
     `none-selected` at all: the rejected verdict is already fully on the
     record (a `warning` and a `corroboration` carrying its own `reason`),
     and `none-selected` names a cycle's outcome rather than a verdict —
     requirement 3b's fingerprint reads it that way, and so does the
     dashboard's outcome precedence (`docs/spec/dashboard/site.md`, where it outranks
     both `selection` and `stand-down`), so a cycle emitting both it and the
     `selection` its mechanical pick won would render as "Nothing selected"
     and report the recovery as the failure it recovered from. The event is
     written only on the branch where the fallback finds no candidate at all
     and the cycle really does select nothing; a fallback pick that is then
     lost to a claim race stands down through requirement 17a's ordinary
     path, and records that (`stand-down`, cause `raced`), not this.
