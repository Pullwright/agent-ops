#!/usr/bin/env bash
#
# scripts/sweep-closed-issues.sh — close an issue whose implementing PR
# already merged but never triggered GitHub's own auto-close (requirement
# 17c), for one repository.
#
# requirement 25a's CI check stops a *new* PR from merging without a real
# closing keyword. This is the sweep for what already got through before
# that check existed, and the defence-in-depth backstop for whatever gets
# through some way this check does not cover (a body edited after the check
# ran and before merge, a squash-merge commit message that drops the body
# entirely on some other host, …): PR #206 said "Implements #198" instead of
# "Closes #198", #198's own fix merged in 8h37m, and the issue then sat open
# for three more days — selected and voided twice — before a human closed it
# by hand. Nothing but a human noticing ever would have.
#
# For every merged pull request labelled `pr_label` that names an issue `N`
# still open, this closes issue `N` with a comment carrying the merge
# evidence — the PR number, its merge commit, and when it merged — instead
# of leaving the tombstone that keeps a finished item selectable forever
# (issue #240). A PR names its issue two ways, either sufficing:
#
#   - the `<!-- agent-ops:closes-issue item=N -->` marker
#     (`prompts/implementer.md` Procedure step 2; requirement 23b);
#   - failing that, a head branch of exactly `agent/<N>` — the name the
#     Script itself mints for a work order whose item is a bare issue number
#     (`claim_branch_for`, agent-cycle.sh), the `issues` and `tech-debt`
#     sources alike since D15 as revised (#869/#875/#879), and for nothing
#     else, so it needs no model to have
#     remembered anything. Without this fallback, the Implementer forgetting
#     the marker blinded the sweep and the CI check together — the two
#     defences failing on the same omission they exist to catch.
#
# One thing it deliberately will not touch: an issue GitHub reports
# `state_reason: "reopened"`. Somebody reopened that issue after it was
# closed, which is the same answer requirement 34k's `void-object-closed`
# record protects on the other sweep — a human's re-open must win, and must
# not be undone on the hour, every hour, with a comment each time.
#
# Bounded, deliberately: only the `pr_search_limit` most recently updated
# merged, labelled pull requests are examined per call. Older strays are the
# ordinary case requirement 25a now prevents from recurring, and a fleet
# running this every cycle catches a fresh miss within the hour regardless —
# an unbounded historical scan would cost every cycle to protect against a
# defect this same change makes rare.
#
# That "most recently updated" window alone has a gap, though (agent-ops#2851):
# a merged PR nobody touches again ages out of it for good once enough newer
# PRs merge, with no persistent cursor to reach back for it — PR #2425 merged
# 2026-10-20 and met every closing criterion below, but #2393 sat open for
# three weeks because it never again surfaced near the top of that ordering.
# So alongside the "most recently updated" call, this script also walks a
# second, persistent cursor across the same merged/labelled pull requests in
# ascending creation order — `<state-dir>/sweep-closed-issues-cursor.json`
# remembers, per repo slug, the `createdAt` of the newest pull request this
# cursor has already examined — bounded by the same `pr_search_limit` per
# call, so a full backlog still surfaces gradually rather than in one burst.
# Once the cursor catches up to the present (an empty batch), it simply stays
# there: every pull request merged from that point on is fresh enough to
# appear in the "most recently updated" window on its own, so there is
# nothing further for the cursor to reach for. The two listings' results are
# merged and de-duplicated by pull request number before either is examined
# below, so a pull request either call finds is only ever processed once.
#
# The cursor only ever advances past a batch every cursor-sourced pull
# request in it actually finished (agent-ops#2869 review): closing is
# idempotent, so re-walking a batch that finished cleanly is wasteful but
# harmless, but advancing past one that did not is not — the next cursor
# search is strictly past whatever it last reached, and an old pull request
# by definition no longer surfaces in the "most recently updated" window
# either, so a close deferred by the shared `max_actions` budget, or one a
# transient `gh` failure left alone, would become permanently unreachable.
# Provenance (whether a given swept pull request came from this cursor
# listing, as opposed to only the "most recently updated" one) is checked
# per row despite the earlier de-duplication, and the cursor-advance write
# at the bottom of this script is skipped entirely — leaving the saved
# cursor exactly where it was — whenever any cursor-sourced row's close was
# deferred or failed. The search itself also matches `created_at` at or
# after the saved cursor (`created:>=`, not `created:>`) rather than
# strictly after it, so two pull requests sharing one `createdAt` second at
# the boundary can never let one of them slip past unexamined — the
# occasional re-fetch of an already-finished boundary row this costs is the
# same harmless idempotent re-walk already described above.
#
# A PR can also name more than one issue in its own closing references
# (agent-ops#2851): PR #2812 closed both #2801 and #2813, but this sweep's
# marker/branch resolution only ever anchors a single target per PR, so #2813
# sat open for five days after #2801 closed within the half hour. Each pull
# request's own GitHub-reported `closingIssuesReferences` — fetched in the
# same listing call, no extra request needed — is checked for any other
# same-repository issue beyond that single marker/branch-derived target, and
# each such issue, if still open and not reopened, is closed the same way,
# under the same `max_actions` budget as the primary target.
#
# This same listing is also one of the item-lifecycle record's two merge
# observation points (requirement 49, issue #595) — the other is
# `lib/landing.sh`'s own arm site, which only ever sees a landing this
# pipeline itself armed. A pull request a human merged by hand, or one
# GitHub's merge queue resolved well after `lib/landing.sh` last looked, has
# no other site that ever notices — this sweep already lists every merged,
# labelled pull request fleet-wide, every stand-down, and already resolves
# each back to its item (marker or branch), so it costs nothing further to
# emit a `merge-observed` action for every one it can identify. Bounded the
# same way the close action already is by `pr_search_limit`, and de-duplicated
# per node against `<state-dir>/sweep-closed-issues-merge-observed-seen.json`
# — a small list of `repo#number` keys this call has already reported, for
# every repository this state_dir has ever been swept for, not only this
# invocation's own `slug`: `lib/standdown.sh`'s 2.1c sweep invokes this script
# once per configured repository, all sharing one state_dir, so a write that
# kept only this invocation's own window would erase every other repo's keys
# on every pass (agent-ops#2476). Each write therefore merges this run's own
# window into whatever the file already held, pruning only the entries that
# carry this invocation's own `slug#` prefix and have aged out of its current
# window — self-pruning stays bounded by `pr_search_limit` per repo, but only
# for the repo actually being swept this call; every other repo's keys are
# left exactly as that repo's own invocation last wrote them, and pruned only
# when that repo is swept in turn.
# Cross-node duplication is not de-duplicated here — several nodes each
# noticing the same merge is the ordinary fleet-wide shape every other record
# in `docs/reference/flow-schema.md` already tolerates, reduced first-wins-by-`ts` by
# whatever reads the union log.
#
# Output: one JSON object per action on stdout —
#   {"action":"closed","issue":198,"pr_number":206,"pr_url":…}
#   {"action":"merge-observed","pr_number":206,"pr_url":…,"item":"198","merge_sha":…}
#   {"action":"approver-escalation-retired","pr_url":…,"issue_number":199,"issue_url":…,
#    "cause":"merged","merged_by":…,"merged_at":…}
#   {"action":"warning","detail":…}
#   {"action":"deferred","remaining":N}
# The caller logs them; this script logs nothing itself. Exit 0 unless the
# arguments are unusable.
#
# Usage: sweep-closed-issues.sh <owner/repo> <node-name> <cycle-id> [state-dir]
# STATE-DIR defaults to this repository's own `config.json`'s `state_dir`;
# pass it explicitly to keep a test hermetic against a real home directory.
# Environment: SWEEP_GH overrides `gh` (tests stub it); AGENT_OPS_CONFIG
# overrides the config path.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Rate-limit-aware `gh`: sourcing this wraps every `gh` call below so a
# refusal GitHub will lift in seconds is waited out rather than degrading
# this source to nothing. See lib/github-limit.sh.
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"
CONFIG_FILE="${AGENT_OPS_CONFIG:-$SCRIPT_DIR/config.json}"
SCHEMA_FILE="$SCRIPT_DIR/config.schema.json"
GH="${SWEEP_GH:-gh}"

# shellcheck source=lib/config-schema.sh
. "$SCRIPT_DIR/lib/config-schema.sh"
# shellcheck source=lib/pipeline-marker.sh
. "$SCRIPT_DIR/lib/pipeline-marker.sh"

slug="${1:-}"
node_name="${2:-}"
cycle_id="${3:-}"
state_dir_override="${4:-}"
if [[ -z "$slug" || -z "$node_name" || -z "$cycle_id" ]]; then
  echo "usage: sweep-closed-issues.sh <owner/repo> <node-name> <cycle-id> [state-dir]" >&2
  exit 64
fi

DEFAULTED_CONFIG="$(config_defaults "$CONFIG_FILE" "$SCHEMA_FILE" 2>/dev/null)"
cfg() { jq -r "$1" <<<"$DEFAULTED_CONFIG" 2>/dev/null; }

pr_label="$(cfg '.pr_label')"
enabler_escalation_label="$(cfg '.enabler_escalation_label')"

expand_home() {
  local p="$1"
  [[ "$p" == "~"* ]] && p="$HOME${p:1}"
  printf '%s\n' "$p"
}

if [[ -n "$state_dir_override" ]]; then
  state_dir="$state_dir_override"
else
  state_dir="$(expand_home "$(cfg '.state_dir')")"
fi
merge_observed_seen_file="$state_dir/sweep-closed-issues-merge-observed-seen.json"
cursor_file="$state_dir/sweep-closed-issues-cursor.json"

# The bounded window (see header): recently-updated merged PRs only.
pr_search_limit=30
# The per-run action cap, for the same reason sweep-orphan-branches.sh caps
# itself: a backlog surfaces a few per cycle rather than as a comment flood.
max_actions=3

actions=0
deferred=0
last_close_incomplete=0

merge_observed_seen='[]'
[[ -n "$state_dir" && -s "$merge_observed_seen_file" ]] && \
  merge_observed_seen="$(jq -c 'if type == "array" then . else [] end' "$merge_observed_seen_file" 2>/dev/null || echo '[]')"
merge_observed_window=()

warn() { jq -nc --arg d "$1" '{action: "warning", detail: $d}'; }  # warn DETAIL

[[ -n "$pr_label" ]] || { warn "no pr_label configured — nothing to sweep"; exit 0; }

prs_json="$("$GH" pr list -R "$slug" --state merged --label "$pr_label" \
  --json number,body,url,mergeCommit,headRefName,mergedAt,mergedBy,closingIssuesReferences \
  --limit "$pr_search_limit" 2>/dev/null)" || prs_json=""
if [[ -z "$prs_json" ]]; then
  warn "could not list merged, $pr_label-labelled pull requests — skipping this pass"
  exit 0
fi

# The persistent cursor (see this script's own header): a second listing,
# ordered by creation ascending and starting at or just past whatever this
# repo's cursor last reached, so a merged pull request that ages out of the
# "most recently updated" window above is still found, eventually, rather
# than left to a human to rediscover. A failed call is warned about but does
# not abort the pass — the "most recently updated" window above still runs.
cursor_state='{}'
[[ -n "$state_dir" && -s "$cursor_file" ]] && \
  cursor_state="$(jq -c 'if type == "object" then . else {} end' "$cursor_file" 2>/dev/null || echo '{}')"
cursor_created_at="$(jq -r --arg slug "$slug" '.[$slug].created_at // ""' <<<"$cursor_state" 2>/dev/null)"

cursor_search="sort:created-asc"
[[ -n "$cursor_created_at" ]] && cursor_search="sort:created-asc created:>=$cursor_created_at"

cursor_prs_json="$("$GH" pr list -R "$slug" --state merged --label "$pr_label" \
  --search "$cursor_search" \
  --json number,body,url,mergeCommit,headRefName,mergedAt,mergedBy,closingIssuesReferences,createdAt \
  --limit "$pr_search_limit" 2>/dev/null)" || cursor_prs_json=""
if [[ -z "$cursor_prs_json" ]]; then
  warn "could not list merged, $pr_label-labelled pull requests past the saved cursor — this pass only covers the most recently updated window"
  cursor_prs_json='[]'
fi

# Provenance for the cursor-advance gate below (see this script's own
# header): the number of every pull request this cursor listing itself
# found, so a row in the de-duplicated union can still be recognized as
# cursor-sourced after `unique_by(.number)` has erased which listing it
# originally came from.
cursor_pr_numbers_json="$(jq -c '[.[].number]' <<<"$cursor_prs_json" 2>/dev/null || echo '[]')"

# Union of both listings, de-duplicated by pull request number, so a pull
# request either call found is examined exactly once below.
swept_prs_json="$(jq -nc --argjson a "$prs_json" --argjson b "$cursor_prs_json" \
  '($a + $b) | unique_by(.number)')"

# The Approver-adjudication escalation retirement (agent-ops#1215, requirement
# 8c/17c): `lib/approver.sh`'s own `land` path retires the escalation the
# moment its own adjudication's APPROVE reaches GitHub, but a pull request a
# human merges directly — without an adjudication `land` ever posting, or
# merging well after one did — leaves that same `pr-<n>-approver-adjudication`
# issue open indefinitely, since nothing else ever reads it back. This is the
# one fleet-wide site that already notices a pull request merged some way
# other than this pipeline's own arm (see lib/landing.sh's own header on why),
# so it is also the only place a human's own merge click can retire one. One
# extra `gh issue list` call per repo — never per pull request — matched
# locally against the merged-PR listing already fetched above, and bounded by
# the same $max_actions/$deferred budget the closing-keyword sweep below
# shares this run with. Searched by $enabler_escalation_label, never
# $pr_label: an escalation issue carries the former, not the latter.
#
# `stateReason` rides along on that same listing for the same reason the
# closing-keyword loop below pays a whole `gh api` call to read
# `state_reason`: an escalation somebody reopened after this sweep retired it
# must stay reopened. Without the check, the merged pull request stays in this
# window for `pr_search_limit` entries, so the reopen would be undone — with a
# fresh comment — on the next stand-down and every one after it.
#
# A listing that *failed* is warned about rather than skipped silently: a
# successful call with nothing matching returns `[]`, so an empty $esc_json
# means the call itself did not answer — a rate limit, or a token that cannot
# read $enabler_escalation_label — and left unsaid that reads exactly like the
# common "no escalation is open" case while retiring nothing, every
# stand-down, indefinitely. The merged-pull-request listing above already
# warns on its own failure; this is the same answer. The sweep carries on
# either way: the closing-keyword pass below does not depend on this call.
#
# Label-less fallback (agent-ops#2657/#2666/#2670; this gap tracked as
# agent-ops#2685/#2686): an escalation `create_escalation_issue` files via
# its retry-without-label path carries no $enabler_escalation_label, so the
# labelled listing above never finds it, and it survives a direct human
# merge indefinitely — the same failure requirement 8c/17c already fixed for
# the labelled case. Tried whenever the labelled listing above found no
# match for a PR actually in this round's merged, $pr_label-labelled listing
# ($prs_json) — never merely "the labelled listing matched nothing at all",
# since a labelled escalation can be open (and matched) for some other,
# still-unresolved PR while a label-less one for a PR in $prs_json sits
# unfound; checking the labelled listing globally rather than per-swept-PR
# would let that other escalation's match suppress the fallback this round
# needs. Matching the labelled-first/label-less-fallback shape
# `lib/escalation-dedup.sh`'s `escalation_dedup_match` already established
# for every other escalation reader, rather than a per-matched-PR
# `escalation_issue_lookup` call (`lib/escalation-lookup.sh`): that helper
# takes one item_ref per call, while this listing already matches every
# currently-merged PR at once, so reusing it here would trade one `gh` call
# for one per matched PR. Keyed on the escalation footer's backticked
# `Item: ` form rather than the bare substring the labelled search above
# also keys on — a label-less listing has nothing but the body to match on —
# and excluding any `<!-- agent-ops:decision-log` body, so an unlabelled
# `pw::decision` veto or open-question issue naming the same reference is
# never mistaken for the escalation.
if [[ -n "$enabler_escalation_label" ]]; then
  if ! esc_json="$("$GH" issue list -R "$slug" --label "$enabler_escalation_label" --state open \
    --search "approver-adjudication" --json number,url,body,stateReason --limit 100 2>/dev/null)"; then
    esc_json=""
    warn "could not list open $enabler_escalation_label issues — no approver-adjudication escalation retired this pass"
  fi
  esc_rows=""
  esc_rows_for_swept=""
  if [[ -n "$esc_json" ]]; then
    esc_rows="$(jq -r '.[]
      | select((.stateReason // "" | ascii_downcase) != "reopened")
      | ((.body // "") | capture("pr-(?<n>[0-9]+)-approver-adjudication")? // null) as $m
      | select($m != null)
      | [(.number|tostring), .url, $m.n] | @tsv' <<<"$esc_json" 2>/dev/null || true)"
    esc_rows_for_swept="$(jq -r --argjson prs "$prs_json" '
      ([$prs[].number]) as $swept
      | .[]
      | select((.stateReason // "" | ascii_downcase) != "reopened")
      | ((.body // "") | capture("pr-(?<n>[0-9]+)-approver-adjudication")? // null) as $m
      | select($m != null)
      | select($swept | index($m.n | tonumber))
      | [(.number|tostring), .url, $m.n] | @tsv' <<<"$esc_json" 2>/dev/null || true)"
  fi
  if [[ -z "$esc_rows_for_swept" ]]; then
    if esc_json_labelless="$("$GH" issue list -R "$slug" --state open \
      --search "approver-adjudication" --json number,url,body,stateReason --limit 100 2>/dev/null)"; then
      esc_rows_labelless="$(jq -r '.[]
        | select((.stateReason // "" | ascii_downcase) != "reopened")
        | select((.body // "") | contains("<!-- agent-ops:decision-log") | not)
        | ((.body // "") | capture("Item: `pr-(?<n>[0-9]+)-approver-adjudication`")? // null) as $m
        | select($m != null)
        | [(.number|tostring), .url, $m.n] | @tsv' <<<"$esc_json_labelless" 2>/dev/null || true)"
      if [[ -n "$esc_rows_labelless" ]]; then
        esc_rows="$(printf '%s\n%s' "$esc_rows" "$esc_rows_labelless" | sed '/^$/d')"
      fi
    else
      warn "could not list open issues for the label-less approver-adjudication fallback — no label-less escalation retired this pass"
    fi
  fi
  if [[ -n "$esc_rows" ]]; then
    while IFS=$'\t' read -r esc_number esc_url esc_pr_number; do
      [[ -n "$esc_number" && "$esc_pr_number" =~ ^[0-9]+$ ]] || continue
      merged_fields="$(jq -r --argjson n "$esc_pr_number" \
        '.[] | select(.number == $n)
             | [(.mergedBy.login // "someone"), (.mergedAt // ""), (.url // "")] | @tsv' \
        <<<"$prs_json" 2>/dev/null)"
      [[ -n "$merged_fields" ]] || continue
      IFS=$'\t' read -r merged_by merged_at esc_pr_url <<<"$merged_fields"

      if (( actions >= max_actions )); then
        deferred=$(( deferred + 1 ))
        continue
      fi

      esc_comment_body="$(pipeline_comment_header script "$node_name")

This pull request merged — by \`$merged_by\` at \`$merged_at\` — so the
Approver-adjudication disagreement this issue was raised for has ended,
whether or not an adjudication \`land\` verdict is what actually did it.

Retiring this escalation now so it stops paging you for a pull request that
is already done.

$(pipeline_comment_marker "$cycle_id" script)"

      if "$GH" issue close "$esc_number" -R "$slug" --comment "$esc_comment_body" >/dev/null 2>&1; then
        jq -nc --arg pr_url "$esc_pr_url" --argjson issue_number "$esc_number" \
          --arg issue_url "$esc_url" --arg by "$merged_by" --arg at "$merged_at" \
          '{action: "approver-escalation-retired", pr_url: $pr_url,
            issue_number: $issue_number, issue_url: $issue_url,
            cause: "merged", merged_by: $by, merged_at: $at}'
        actions=$(( actions + 1 ))
      else
        warn "could not close approver-adjudication escalation issue #$esc_number (pull request #$esc_pr_number merged)"
      fi
    done <<<"$esc_rows"
  fi
fi

# close_named_issue PR_NUMBER PR_URL MERGE_SHA ITEM EVIDENCE — shared by the
# marker/branch-derived primary target below and by each extra same-repo
# `closingIssuesReferences` entry a pull request also names (agent-ops#2851):
# both close the same way, under the same $actions/$max_actions/$deferred
# budget, and differ only in the evidence cited in the comment.
#
# Sets the global $last_close_incomplete to 1 whenever this call's own issue
# was left in a state that still needs revisiting — deferred by the budget,
# or a transient read/close failure — and to 0 for every other outcome,
# including "already closed" and the deliberate, permanent "reopened" skip:
# neither of those needs this issue looked at again, so neither should block
# the cursor-advance gate below from treating a batch as finished. The
# caller, not this function, decides what an incomplete cursor-sourced row
# means for the cursor.
close_named_issue() {
  local pr_number="$1" pr_url="$2" merge_sha="$3" item="$4" evidence="$5"
  local issue_json state state_reason comment_body

  last_close_incomplete=0

  if (( actions >= max_actions )); then
    deferred=$(( deferred + 1 ))
    last_close_incomplete=1
    return
  fi

  issue_json="$("$GH" api "repos/$slug/issues/$item" 2>/dev/null)" || issue_json=""
  if [[ -z "$issue_json" ]]; then
    warn "could not read issue #$item (named by PR #$pr_number) — leaving it alone"
    last_close_incomplete=1
    return
  fi
  state="$(jq -r '.state // ""' <<<"$issue_json" 2>/dev/null)"
  [[ "$state" == "open" ]] || return

  # Open *because a human reopened it* is not the state this sweep is for.
  # GitHub sets `state_reason: "reopened"` on an issue reopened after a close,
  # and "still open" alone cannot tell that apart from "never closed" — so
  # without this the sweep would close, every hour, exactly the issue somebody
  # deliberately reopened, and comment each time. That is the failure
  # requirement 34k's own one-shot rule (`void-object-closed`) exists to
  # prevent on the other sweep; the same principle applies here, and this is
  # how it is spelled with no per-item record to keep: the reopen *is* the
  # record, and it is GitHub's, not ours.
  state_reason="$(jq -r '.state_reason // ""' <<<"$issue_json" 2>/dev/null)"
  if [[ "$state_reason" == "reopened" ]]; then
    warn "issue #$item (named by PR #$pr_number) was reopened after a close — leaving it to whoever reopened it"
    return
  fi

  comment_body="$(pipeline_comment_header script "$node_name")

This issue's implementing pull request has merged, but its body never
carried a GitHub closing keyword, so GitHub never auto-closed it. $evidence

Closing it now so it stops being offered as open work.

$(pipeline_comment_marker "$cycle_id" script)"

  if "$GH" issue close "$item" -R "$slug" --comment "$comment_body" >/dev/null 2>&1; then
    jq -nc --argjson issue "$item" --argjson pr "$pr_number" --arg url "$pr_url" \
      '{action: "closed", issue: $issue, pr_number: $pr, pr_url: $url}'
    actions=$(( actions + 1 ))
  else
    warn "could not close issue #$item (named by PR #$pr_number)"
    last_close_incomplete=1
  fi
}

cursor_batch_incomplete=0
while IFS=$'\t' read -r pr_number pr_url item merge_sha named_by extra_items_json cursor_sourced; do
  # bash's `read` collapses consecutive IFS-whitespace delimiters (tab
  # included) even when IFS is narrowed to just "\t", so a genuinely empty
  # middle field shifts every field after it — jq emits "-" rather than ""
  # for "no marker" specifically to keep the columns aligned. $extra_items_json
  # is never empty by construction (always at least a JSON "[]"), so it needs
  # no such placeholder.
  [[ "$item" == "-" ]] && item=""
  [[ -n "$pr_number" && -n "$item" ]] || continue

  # The item-lifecycle record's merge instant (requirement 49, issue #595) —
  # see this script's own header. Never subject to `max_actions`: it costs no
  # GitHub call (everything it needs is already in `swept_prs_json`), and
  # gating it on the same cap as the close action would silently drop merge
  # evidence behind whatever backlog of issue-closes this pass is also
  # working through.
  merge_key="$slug#$pr_number"
  merge_observed_window+=("$merge_key")
  if ! jq -e --arg k "$merge_key" 'index($k) != null' <<<"$merge_observed_seen" >/dev/null 2>&1; then
    jq -nc --argjson n "$pr_number" --arg url "$pr_url" --arg item "$item" --arg sha "$merge_sha" \
      '{action: "merge-observed", pr_number: $n, pr_url: $url, item: $item}
       + (if $sha == "" or $sha == "-" then {} else {merge_sha: $sha} end)'
  fi

  if [[ "$named_by" == "branch" ]]; then
    evidence="pull request #$pr_number ($pr_url) is the merged work order for \
this issue — its head branch is \`agent/$item\`, the name this pipeline mints \
only for issue-sourced work\
$( [[ -n "$merge_sha" && "$merge_sha" != "-" ]] && printf ' (merged as %s)' "$merge_sha" )\
 — but its body carried neither the \`agent-ops:closes-issue\` marker nor a \
closing keyword, so GitHub never auto-closed it."
  else
    evidence="pull request #$pr_number ($pr_url) carries the \
\`agent-ops:closes-issue item=$item\` marker and is merged\
$( [[ -n "$merge_sha" && "$merge_sha" != "-" ]] && printf ' (%s)' "$merge_sha" )\
, but never triggered GitHub's own closing-keyword auto-close."
  fi

  close_named_issue "$pr_number" "$pr_url" "$merge_sha" "$item" "$evidence"
  [[ "$cursor_sourced" == "1" && "$last_close_incomplete" == "1" ]] && cursor_batch_incomplete=1

  # A pull request can name more than one issue in its own closing
  # references (agent-ops#2851) — $extra_items_json already carries every
  # other same-repository issue number GitHub's own
  # `closingIssuesReferences` named for this pull request, besides the
  # marker/branch-derived $item above. Closed exactly the same way, under
  # the same budget, so the second issue a pull request closes is never
  # left stranded behind the one this sweep already knew how to find.
  if [[ "$extra_items_json" != "[]" ]]; then
    while IFS= read -r extra_item; do
      [[ -n "$extra_item" ]] || continue
      extra_evidence="pull request #$pr_number ($pr_url) also names this issue \
among the issues it closes (GitHub's own \`closingIssuesReferences\`) and is \
merged\
$( [[ -n "$merge_sha" && "$merge_sha" != "-" ]] && printf ' (%s)' "$merge_sha" )\
, but never triggered GitHub's own closing-keyword auto-close for it."
      close_named_issue "$pr_number" "$pr_url" "$merge_sha" "$extra_item" "$extra_evidence"
      [[ "$cursor_sourced" == "1" && "$last_close_incomplete" == "1" ]] && cursor_batch_incomplete=1
    done < <(jq -r '.[]' <<<"$extra_items_json" 2>/dev/null || true)
  fi
done < <(jq -r --arg slug "$slug" --argjson cursor_nums "$cursor_pr_numbers_json" '.[]
  | .number as $primary_number
  | ((.body // "") | capture("<!-- agent-ops:closes-issue item=(?<n>[0-9]+) -->")? // null) as $marker
  | ((.headRefName // "") | capture("^agent/(?<n>[0-9]+)$")? // null) as $branch
  | (if $marker then $marker.n elif $branch then $branch.n else null end) as $primary
  | ((.closingIssuesReferences // [])
      | map(select(
          ((((.repository.owner.login // "") + "/" + (.repository.name // "")) | ascii_downcase)
            == ($slug | ascii_downcase))
          and ($primary == null or (.number|tostring) != $primary)
        ))
      | map(.number) | unique) as $extra
  | [
    (.number|tostring),
    .url,
    (if $primary then $primary else "-" end),
    (.mergeCommit.oid // "-"),
    (if $marker then "marker" elif $branch then "branch" else "-" end),
    ($extra | tostring),
    (if ($cursor_nums | any(. == $primary_number)) then "1" else "0" end)
  ] | @tsv' <<<"$swept_prs_json" 2>/dev/null || true)

if (( deferred > 0 )); then
  jq -nc --argjson n "$deferred" '{action: "deferred", remaining: $n}'
fi

# Merge this run's own window into the seen-file rather than replacing it
# wholesale (see this script's own header) — pruning only this invocation's
# own $slug's entries that fell out of its current window, and leaving every
# other repository's own keys untouched, since this invocation never learns
# their current windows. An unwritable state_dir must not fail the sweep —
# the caller still gets this run's actions — but it must not go unnoticed
# either: silently losing the write means every merge-observed key for this
# repo re-emits, up to `pr_search_limit` of them, on every future stand-down
# until the directory is writable again.
if [[ -n "$state_dir" ]]; then
  window_json="$(printf '%s\n' "${merge_observed_window[@]:-}" | jq -R 'select(length > 0)' | jq -sc 'unique')"
  if ! { mkdir -p "$state_dir" 2>/dev/null && \
      jq -nc --argjson existing "$merge_observed_seen" --argjson window "$window_json" --arg slug "$slug" \
        '[$existing[] | select(startswith($slug + "#") | not)] + $window | unique' \
        > "$merge_observed_seen_file.tmp" 2>/dev/null && \
      mv "$merge_observed_seen_file.tmp" "$merge_observed_seen_file" 2>/dev/null; }; then
    warn "failed to write merge-observed seen-file $merge_observed_seen_file — merge-observed events may re-emit on future runs"
  fi
fi

# Advance this repo's own cursor to the newest pull request the cursor
# listing above actually examined (see this script's own header) — never to
# anything from the "most recently updated" window, which is not ordered by
# creation and would make the cursor's own ordering meaningless. An empty
# cursor listing (already caught up) leaves the cursor exactly where it was;
# there is nothing further for it to reach. A write failure is warned about,
# not silent — the next pass would otherwise re-walk this same batch from
# scratch, which is wasteful but not incorrect, since closing is idempotent.
#
# $cursor_batch_incomplete (set above, in the main loop) gates this the same
# way a write failure already does, but for a different reason: a deferred
# or failed close for a cursor-sourced row left that pull request's own
# issue unresolved, and advancing past it anyway would make it permanently
# unreachable — the next search starts strictly past this point, and an old
# pull request never resurfaces in the "most recently updated" window to
# compensate. Skipping the write leaves the cursor where it was, so the next
# pass re-examines the whole batch, including whatever already finished —
# the same harmless, idempotent re-walk the write-failure case already
# tolerates.
cursor_newest_created_at="$(jq -r \
  'if length > 0 then (max_by(.createdAt) | .createdAt) else "" end' \
  <<<"$cursor_prs_json" 2>/dev/null)"
if [[ -n "$state_dir" && -n "$cursor_newest_created_at" && "$cursor_batch_incomplete" -eq 0 ]]; then
  if ! { mkdir -p "$state_dir" 2>/dev/null && \
      jq -nc --argjson existing "$cursor_state" --arg slug "$slug" \
        --arg created_at "$cursor_newest_created_at" \
        '$existing + {($slug): {created_at: $created_at}}' \
        > "$cursor_file.tmp" 2>/dev/null && \
      mv "$cursor_file.tmp" "$cursor_file" 2>/dev/null; }; then
    warn "failed to write sweep cursor $cursor_file — the next pass may re-walk this batch"
  fi
fi

exit 0
