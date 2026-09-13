#!/usr/bin/env bash
#
# gather-landing-refusals.sh — pre-fetch a repo's pull requests that gate 4 of
# `_landing_stage_attempt` (`lib/landing.sh`) keeps refusing to arm over an
# unreconciled human comment, or a comment-reconciliation read it could not
# make (requirement 53, issue #979, agent-ops#672/#746/#753).
#
# Gate 4 exists to close the residual human-veto gap `lib/reconciliation-
# gate.sh`'s own gate at the Reviewer's ready-flip cannot see: a plain comment
# posted *after* a pull request is already Ready, in the window before a later
# cycle's arming step lands it. Refusing to arm over it is correct — it is the
# human veto D18 promises — but nothing before this script turned the refusal
# back into work: `gather-review-feedback.sh` cannot see it (no formal
# `CHANGES_REQUESTED`, no draft flip — see that script's own header), and
# `gather-abandoned-drafts.sh` only ever sees drafts, while this pull request
# is Ready. So the refusal cost one `landing-refused` log line per cycle,
# indefinitely, with nobody ever asked to answer the comment that caused it.
#
# Given a repo slug, print a JSON array of candidates: open, non-draft PRs
# raised by this system whose most recent `landing-refused` event began
# `reconciliation-unanswered:` or `reconciliation-unreadable:`, and which
# still carry at least one unreconciled human comment right now. Each
# candidate carries the unreconciled comment(s) verbatim — id, author, body —
# so the Implementer can answer them without re-deriving anything.
#
# Usage: gather-landing-refusals.sh <owner/repo> <pr-label> <branch-prefix> <union-log> [tech-debt-branch-prefix]
#
# <union-log> is the fleet-wide union log (agent-cycle.sh's own `union_log`),
# not a single node's own `log.jsonl`: `landing-refused` is a fact only this
# pipeline's own log carries (GitHub has no record of a gate declining to
# arm), and the refusal this script must see may have been logged by a peer
# node's own cycle. A missing or unreadable log simply yields no candidates —
# see `lib/landing.sh`'s `landing_latest_refusal_reason`.
#
# Candidate shape:
#   {
#     "source": "landing-refusals",
#     "ref": "pr-57-landing-refusal-4718691960",   // scoped to the exact set
#                                                    // of unreconciled comment
#                                                    // ids — see below
#     "number": 57,
#     "pr_number": 57,
#     "url": "https://github.com/…/pull/57",
#     "pr_url": "https://github.com/…/pull/57",
#     "title": "fix(blogger-auth): …",
#     "branch": "agent/td26071701-…",
#     "item": "TD26071701",               // the originating item, if inferable
#     "head_sha": "eea6184…",
#     "refused_at": "2026-08-24T01:23:45Z",
#     "reason": "reconciliation-unanswered:human comment(s) posted on … carry no … line answering them: …",
#     "comments": [{"id": 4718691960, "at": "2026-08-24T01:00:00Z", "author": "warwickallen", "body": "…verbatim…"}],
#     "body": "…every unreconciled comment, verbatim, oldest first…"
#   }
#
# ## The candidate rule
#
# A PR is a candidate iff all of:
#   - it is open and not a draft — a draft is the Implementer's own claim
#     marker, and `lib/landing.sh` gate 4 never runs against one in the first
#     place, so there is nothing here for `gather-abandoned-drafts.sh` to miss;
#   - it carries <pr-label> and its head branch starts with <branch-prefix> (or
#     `td/`, the tech-debt claim branch) — i.e. this system raised it, the same
#     "ours" test every sibling finishing source applies;
#   - the most recent `landing-refused` event logged against it in <union-log>
#     has a `reason` beginning `reconciliation-unanswered:` or
#     `reconciliation-unreadable:` — the exact prefixes gate 4 logs at its two
#     comment-reconciliation refusal points (`lib/landing.sh`, requirement 8d
#     gate 4). Reading the *logged refusal*, not recomputing the gate
#     independently, is deliberate: gate 4 only ever reaches this check once
#     every gate before it — approval, no formal `CHANGES_REQUESTED`, a green
#     required-check list — has already passed, so keying on the log keeps this
#     source complementary to `review-feedback` rather than duplicating it for
#     a pull request review-feedback already covers for a different reason;
#   - `lib/reconciliation-gate.sh`'s own `reconciliation_unreconciled_comments`,
#     asked fresh right now (unbounded, the same call gate 4 itself makes), still
#     reports at least one unreconciled human comment. This is the answered
#     clause every finishing source needs (see gather-dequeued.sh's own header,
#     "Why the dequeue must still be unanswered", for the general shape): once
#     the Implementer's reply carries the `<!-- agent-ops:reconciles
#     comment=<id> -->` marker, gate 4's *next* attempt reads `clean` and stops
#     logging fresh refusals — but the old `landing-refused` event never
#     disappears from the log, so without this second, live check the pull
#     request would be offered forever on the strength of history alone. A read
#     that fails outright (the URL is unparseable, or the timeline/comments
#     could not be fetched) is never read as "nothing to reconcile" — it drops
#     the candidate for this cycle, the same fail-closed direction
#     gather-dequeued.sh's own answered clause takes.
#
# ## Why the ref is scoped to the unreconciled ids, not the pull request alone
#
# Same reasoning as every sibling finishing source's own scoped ref (see
# gather-dequeued.sh's "Why the ref is scoped to the head SHA"): an item
# recorded blocked stays blocked until something clears it, so a bare
# `pr-<n>-landing-refusal` an Implementer once failed to resolve would still
# read blocked after a fresh comment is answered — or after a *new* human
# comment arrives needing its own answer. Scoping the ref to the sorted,
# joined set of currently-unreconciled comment ids means each change to that
# set — one answered, one added — mints a fresh candidate no old block or void
# covers, while a repeat read of the identical unreconciled set keeps the same
# ref and stays correctly blocked or claimed.
#
# Fails safe: always prints a valid JSON array and exits 0. A repo with
# nothing refused for this reason contributes `[]`; an API or log that will
# not answer contributes `[]` too — the source simply does not fire this
# cycle.
#
# Environment: LANDING_REFUSALS_GH overrides `gh` (tests stub it).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/pipeline-marker.sh
. "$SCRIPT_DIR/lib/pipeline-marker.sh"
# Rate-limit-aware `gh`: sourcing this wraps every `gh` call below (including
# the ones inside reconciliation_unreconciled_comments, which defaults to the
# same shadowed name) so a refusal GitHub will lift in seconds is waited out
# rather than degrading this source to nothing. See lib/github-limit.sh.
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"
GH="${LANDING_REFUSALS_GH:-gh}"
RECONCILIATION_GATE_GH="$GH"
export RECONCILIATION_GATE_GH
# shellcheck source=lib/reconciliation-gate.sh
. "$SCRIPT_DIR/lib/reconciliation-gate.sh"
# shellcheck source=lib/landing.sh
. "$SCRIPT_DIR/lib/landing.sh"

slug="${1:-}"
pr_label="${2:-autonomous-agent}"
branch_prefix="${3:-agent/}"
union_log="${4:-}"
tech_debt_branch_prefix="${5-td/}"
if [[ -z "$slug" || -z "$union_log" ]]; then
  echo "usage: gather-landing-refusals.sh <owner/repo> <pr-label> <branch-prefix> <union-log> [tech-debt-branch-prefix]" >&2
  exit 64
fi

warn() {
  echo "gather-landing-refusals: $slug: $*" >&2
}

# The open, agent-raised, non-draft PRs. Same field set gather-review-
# feedback.sh reads its own listing with (`headRefOid` directly, never the
# `commits` collection — see that script's header for the cost this avoids).
all_prs="$("$GH" pr list -R "$slug" --state open --label "$pr_label" \
        --limit "$GITHUB_PR_LIST_LIMIT" \
        --json number,title,headRefName,headRefOid,isDraft,url,body \
        || true)"
if [[ -z "$all_prs" ]] || ! jq -e 'type == "array"' <<<"$all_prs" >/dev/null 2>&1; then
  printf '[]'
  exit 0
fi

if github_pr_list_truncated "$(jq 'length' <<<"$all_prs")"; then
  echo "gather-landing-refusals: $slug: the pull-request listing came back at its ${GITHUB_PR_LIST_LIMIT}-item cap; a refused PR beyond it is not offered this cycle" >&2
fi

# Empty tech_debt_branch_prefix disables the tech-debt namespace: the `or`
# clause is dropped rather than built with an empty startswith(""), which
# would match every head.
td_clause=""
if [[ -n "$tech_debt_branch_prefix" ]]; then
  td_clause=" or (.headRefName | startswith(\"$tech_debt_branch_prefix\"))"
fi
ours="$(jq -c "[.[] | select(.isDraft | not)
                    | select((.headRefName | startswith(\"$branch_prefix\"))$td_clause)]" \
        <<<"$all_prs" 2>/dev/null || echo '[]')"
jq -e 'type == "array"' <<<"$ours" >/dev/null 2>&1 || ours='[]'

out='[]'

emit() {  # <pr-json>
  local pr="$1" number head_sha pr_url refusal refused_at reason
  local unreconciled_json ids item cand docs body
  number="$(jq -r '.number' <<<"$pr")"
  head_sha="$(jq -r '.headRefOid // ""' <<<"$pr")"
  pr_url="$(jq -r '.url // ""' <<<"$pr")"
  [[ -n "$head_sha" && -n "$pr_url" ]] || return 0

  refusal="$(landing_latest_refusal_reason "$pr_url" "$union_log")"
  [[ -n "$refusal" ]] || return 0
  refused_at="${refusal%%$'\t'*}"
  reason="${refusal#*$'\t'}"
  case "$reason" in
    reconciliation-unanswered:* | reconciliation-unreadable:*) ;;
    *) return 0 ;;
  esac

  # The live check (see the header's "answered clause"): unbounded, the same
  # call gate 4 itself makes at arming time. A failed read never reads as
  # "nothing to reconcile" — it drops the candidate for this cycle.
  if ! unreconciled_json="$(reconciliation_unreconciled_comments "$pr_url")"; then
    warn "could not confirm pr #$number's unreconciled comments; not offering it this cycle"
    return 0
  fi
  jq -e 'type == "array"' <<<"$unreconciled_json" >/dev/null 2>&1 || return 0
  [[ "$(jq 'length' <<<"$unreconciled_json")" != "0" ]] || return 0

  ids="$(jq -r '[.[].id] | sort | join("-")' <<<"$unreconciled_json")"
  [[ -n "$ids" ]] || return 0

  # The originating item, so the Implementer can find the tech-debt entry or
  # issue this PR came from. Best-effort: a ref in the branch name or PR body.
  item="$(jq -r '(.headRefName + " " + (.body // ""))' <<<"$pr" \
          | grep -oiE '\b(TD[0-9]{8}|dependabot-alert-[0-9]+|code-scanning-alert-[0-9]+|review-[0-9]{4}-[0-9]{2}-[0-9]{2}-R-?[0-9]+)\b' \
          | head -n1 || true)"

  # Every unreconciled comment, verbatim, oldest first — the way gather-
  # review-feedback.sh assembles its own `body` from review text. Delivered on
  # stdin (requirement 4g): $unreconciled_json is unbounded past this point.
  body="$(jq -cn 'input as $u |
    [$u | sort_by(.at)[] | "── human comment by \(.author) at \(.at) (id \(.id))\n\(.body)"]
    | join("\n\n")' <<<"$unreconciled_json")"
  [[ -n "$body" ]] || body='""'

  # $pr and $unreconciled_json each carry unbounded text past this point
  # (requirement 4g), so both travel on stdin rather than argv.
  cand="$(jq -nc \
    --arg ref "pr-${number}-landing-refusal-${ids}" \
    --arg item "$item" \
    --arg head_sha "$head_sha" \
    --arg refused_at "$refused_at" \
    --arg reason "$reason" \
    'input as $pr | input as $comments | input as $body | {source: "landing-refusals",
      ref: $ref,
      number: $pr.number,
      pr_number: $pr.number,
      url: $pr.url,
      pr_url: $pr.url,
      title: $pr.title,
      branch: $pr.headRefName,
      item: (if $item == "" then null else $item end),
      head_sha: $head_sha,
      refused_at: $refused_at,
      reason: $reason,
      comments: $comments,
      body: $body}' <<<"$pr"$'\n'"$unreconciled_json"$'\n'"$body")" \
    || { warn "candidate assembly failed for pr #$number"; return 0; }

  # Same stdin-doc accumulator every sibling finishing source uses, for the
  # same MAX_ARG_STRLEN reason (requirement 4g).
  docs="$(printf '%s\n' "$out" "$cand")"
  out="$(jq -nc '
    input as $out | input as $c
    | $out + [$c]
  ' <<<"$docs" || { warn "array assembly failed at pr #$number"; printf '%s' "$out"; })"
}

while IFS= read -r pr; do
  [[ -n "$pr" ]] || continue
  emit "$pr"
done < <(jq -c '.[]' <<<"$ours" 2>/dev/null || true)

# Longest-refused first: the pull request whose refusal has stood unanswered
# longest goes first, the same "finish the oldest wait" ordering every
# sibling finishing source applies.
jq -c 'sort_by(.refused_at)' <<<"$out"
