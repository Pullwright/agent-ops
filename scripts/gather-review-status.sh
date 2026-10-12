#!/usr/bin/env bash
#
# gather-review-status.sh — whether a project-review recommendation's own ref
# is named by a merged pull request on the default branch (requirement 34i's
# project-review half), or every tracking id its own recommendation text
# names is itself closed or resolved (issue #2333's PR-independent half).
#
# Given a repo slug, its default branch and one or more recommendation refs
# (`review-<date>-R-NN`), print a JSON object mapping each ref it could confirm
# either signal for to that signal's own distinct value:
#
#   {"review-2026-07-11-R-02": "merged", "review-2026-09-28-R-02": "tracked-closed"}
#
# Usage: gather-review-status.sh <owner/repo> <default-branch>
#          [--issues-file <path>] [--register-file <path>] <ref> [<ref>…]
#
# ## The same test requirement 16 already applies
#
# A `project-review` recommendation is already excluded from the Co-Ordinator's
# candidates once "a *merged* pull request references its ref"
# (`docs/spec/implementation/requirements`, requirement 16) — the review folder
# itself is a point-in-time record and is never edited to say a recommendation
# is done (requirement 25), so a merged PR naming the ref, put there by the
# Implementer that closed it out (the Implementer prompt's `source: project-review`
# section), is the only fact anywhere that can answer "is this one finished?".
# This reads that same fact, so a block can clear on it without paying for a
# Co-Ordinator to notice.
#
# ## The PR-independent signal (issue #2333)
#
# A recommendation can also be satisfied by owner action outside this
# pipeline entirely — closing the issue(s) its own "Tech-debt item(s): …" line
# designates by hand, or flipping a tech-debt register file's frontmatter
# directly — which never produces a pull request naming the ref at all, so the
# signal above never fires and the block sits until an Enabler engagement
# notices by hand. `lib/review-recommendation.sh`'s
# `review_recommendation_tracking_ids` reads that line (any of the three text
# shapes observed in the wild: a single bare `#NNN`, several "and"-joined, or
# one backtick-quoted register id); every id it names is then checked against
# ISSUES_JSON (a JSON array of this repo's own open issue numbers) for a bare
# id, or REGISTER_JSON (`{"<id>": "<status>", …}`) for a register id.
#
# Both are digests the caller (`lib/candidate-gather.sh`) already holds this
# cycle — the repo's full open-issues digest and the register status already
# fetched for this repo's other blocked register items — passed in rather
# than re-fetched here, per "unknown is not gone": an id absent from, or
# unresolvable in, the digest it was given leaves the *whole* ref unresolved,
# never treated as closed on a guess. Omitting a flag entirely (as every
# caller before issue #2333 does) answers "unknown" for that class, so a
# caller that never passes `--issues-file` gets exactly today's behaviour for
# every bare-issue tracking id — this signal simply never fires for them.
# Omitting *both* skips the recommendations read altogether rather than
# performing it per ref and discarding the answer: nothing either digest could
# have decided is in hand, so the read could only ever cost a `gh` call and
# conclude "unknown".
#
# Both travel as a *file path*, never inline JSON (requirement 4g): an
# open-issues digest grows with the repo, unbounded, and an inline
# `--issues-json` would risk the same MAX_ARG_STRLEN failure
# TD-PPagop-26081401 already fixed for `work_gone_clearances`'s own inputs —
# silently answering "unknown" on a busy repo rather than diagnosing anything.
#
# ## Only the refs asked for, and only when they are blocked
#
# Like `gather-register-status.sh`, this answers one question about a handful
# of named items and the Script calls it only for the blocked items whose refs
# are project-review refs, which is nearly always none. A fleet with no blocked
# project-review items spends nothing here.
#
# ## Sampled, not exhaustive
#
# The merged-PR search is the repo's 100 most-recently-closed pull requests,
# the same page size every gatherer uses. A recommendation closed by a PR that
# has since aged off that page answers nothing here for that signal — the safe
# direction, since the block then simply waits on the tracking-id signal (or,
# failing that, the Enabler) exactly as it always did.
#
# Never exits non-zero: it always prints a valid object. A gatherer that
# aborted the cycle would make a tidy-up a reliability risk.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Rate-limit-aware `gh`: sourcing this wraps every `gh` call below so a
# refusal GitHub will lift in seconds is waited out rather than degrading
# this source to nothing. See lib/github-limit.sh.
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"
# `review_recommendation_tracking_ids` — reading a recommendation's own
# "Tech-debt item(s): …" line, shared with lib/void-guard.sh's
# `void_review_item_tech_debt_id` (issue #2333). See lib/review-recommendation.sh.
# shellcheck source=lib/review-recommendation.sh
. "$SCRIPT_DIR/lib/review-recommendation.sh"

slug="${1:-}"
branch="${2:-}"
shift 2 2>/dev/null || true

issues_json=""
register_json='{}'
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --issues-file) issues_json="$(cat "${2:-/dev/null}" 2>/dev/null || true)"; shift 2 ;;
    --register-file) register_json="$(cat "${2:-/dev/null}" 2>/dev/null || true)"; [[ -n "$register_json" ]] || register_json='{}'; shift 2 ;;
    *) break ;;
  esac
done

if [[ -z "$slug" || -z "$branch" ]]; then
  echo "usage: gather-review-status.sh <owner/repo> <default-branch> [--issues-file <path>] [--register-file <path>] <ref> [<ref>…]" >&2
  printf '{}'
  exit 0
fi
if (( $# == 0 )); then
  printf '{}'
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

closed="$(gh api "repos/$slug/pulls?state=closed&base=$branch&per_page=100" 2>"$work/gh.err")"
rc=$?
if (( rc != 0 )); then
  cat "$work/gh.err" >&2
  printf '{}'
  exit 0
fi

# One newline-joined haystack of every merged PR's title and body, searched
# per ref below with a literal (non-regex) match — a recommendation's ref is a
# fixed slug, never a pattern, and a literal match cannot be tripped up by any
# regex metacharacter a title or body happens to contain.
merged_text="$(jq -r '[ .[] | select(.merged_at != null)
                            | ((.title // "") + "\n" + (.body // "")) ]
                       | join("\n")' <<<"$closed" 2>/dev/null || true)"

# tracking_id_closed ID — whether ID (a bare issue number or a register id)
# is itself closed/resolved, decided only from ISSUES_JSON/REGISTER_JSON — see
# the file header for why no fetch happens here.
tracking_id_closed() {
  local id="$1"
  if [[ "$id" =~ ^[0-9]+$ ]]; then
    [[ -n "$issues_json" ]] || return 1
    ! jq -e --argjson n "$id" 'index($n) != null' <<<"$issues_json" >/dev/null 2>&1
  else
    local status
    status="$(jq -r --arg k "$id" '.[$k] // ""' <<<"$register_json" 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    [[ "$status" == "resolved" || "$status" == "not-debt" ]]
  fi
}

# Whether either digest can answer for an id at all. A caller that passes
# neither — `lib/candidate-gather.sh`'s own `void`-purpose call, and every
# caller that predates this signal — can never confirm a tracking id, so
# reading the recommendations file for one would be a `gh` call per unmerged
# ref, every cycle, for an answer already known to be "unknown". Checked
# before the loop rather than inside it: the two digests are the same for
# every ref asked about.
tracking_possible=0
if [[ -n "$issues_json" ]] \
   || jq -e 'type == "object" and length > 0' <<<"$register_json" >/dev/null 2>&1; then
  tracking_possible=1
fi

out="{}"
for ref in "$@"; do
  [[ -n "$ref" ]] || continue
  if [[ -n "$merged_text" ]] && grep -Fq -- "$ref" <<<"$merged_text"; then
    out="$(jq -c --arg k "$ref" '. + {($k): "merged"}' <<<"$out" 2>/dev/null || printf '%s' "$out")"
    continue
  fi
  (( tracking_possible )) || continue
  tracked_ids="$(review_recommendation_tracking_ids "$ref" "$slug" "$branch" 2>/dev/null || true)"
  [[ -n "$tracked_ids" ]] || continue
  all_closed=1
  while IFS= read -r tid; do
    [[ -n "$tid" ]] || continue
    if ! tracking_id_closed "$tid"; then
      all_closed=0
      break
    fi
  done <<<"$tracked_ids"
  if (( all_closed )); then
    out="$(jq -c --arg k "$ref" '. + {($k): "tracked-closed"}' <<<"$out" 2>/dev/null || printf '%s' "$out")"
  fi
done

printf '%s' "$out"
