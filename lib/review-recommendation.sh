#!/usr/bin/env bash
#
# lib/review-recommendation.sh — reading a project-review recommendation's own
# "Tech-debt item(s): …" line back out of its recommendations file (issue
# #2030, extended by issue #2333).
#
# A `review-<date>-R-<nn>` ref never appears in the pull request that
# implements it — only the tech-debt id (or ids) the recommendation's own
# text designates does, on a line inside its `## R-<nn>` section of
# `reviews/project-review-<date>/03-recommendations.md`. Two different
# questions get asked of that same line:
#
#   - which single id should a citing pull request be checked against
#     (`review_recommendation_tech_debt_id`, lib/void-guard.sh's
#     `void_review_item_tech_debt_id`) — only ever the backtick-quoted
#     register-id form, because that is the only shape a citing pull request
#     was ever asked to name;
#   - every tracking id the line names at all
#     (`review_recommendation_tracking_ids`, scripts/gather-review-status.sh),
#     because a recommendation observed in the wild names its tech debt with
#     one bare `#NNN` issue reference, several of them joined by "and", or the
#     single backtick-quoted register id — and a work-gone clearance has to
#     recognise all three to decide whether every one of them is closed.
#
# Both share the one step that is genuinely fiddly: isolating the
# recommendation's own section so a neighbouring recommendation's tracking
# line can never bleed over (`review_recommendation_section`, below).
#
# Sourced, never executed: it sets no shell options, because agent-cycle.sh
# runs under `set -euo pipefail`.

# review_recommendation_section ITEM SLUG [BRANCH] [GH_BIN]
# Isolate the Markdown section a `review-<date>-R-<nn>` ref names, from its
# `## R-<nn> — …` heading up to (not including) the next `## ` heading or end
# of file, read from SLUG's `reviews/project-review-<date>/03-recommendations.md`
# on BRANCH.
#
# BRANCH is resolved live (one extra `gh api repos/<slug>` call) when empty —
# the original shape lib/void-guard.sh's callers need, since none of them
# already knows SLUG's default branch. A caller that already knows it (every
# scripts/gather-*.sh script takes it as its own argument) should pass it
# instead, so this never pays for a read its own caller's caller already did.
#
# Prints the section and returns 0 on success. Prints nothing and returns 1
# the moment anything is not exactly as expected — ITEM is not shaped like a
# recommendation ref, SLUG is empty, the recommendations file cannot be
# fetched, or no heading for this recommendation number exists — so a caller
# falls through to whatever it does when a recommendation cannot be resolved,
# rather than this function fabricating a section from a half-read file.
review_recommendation_section() {
  local item="$1" slug="$2" branch="${3:-}" gh_bin="${4:-gh}"
  local date rec_id path api_out content section

  [[ "$item" =~ ^review-([0-9]{4}-[0-9]{2}-[0-9]{2})-(R-[0-9]+)$ ]] || return 1
  date="${BASH_REMATCH[1]}"
  rec_id="${BASH_REMATCH[2]}"
  [[ -n "$slug" ]] || return 1

  if [[ -z "$branch" ]]; then
    branch="$("$gh_bin" api "repos/$slug" --jq '.default_branch' 2>/dev/null)" || branch=""
    [[ -n "$branch" ]] || branch="main"
  fi

  path="reviews/project-review-$date/03-recommendations.md"
  api_out="$("$gh_bin" api "repos/$slug/contents/$path?ref=$branch" 2>/dev/null)" || return 1
  [[ -n "$api_out" ]] || return 1
  content="$(jq -r '.content // empty' <<<"$api_out" 2>/dev/null | tr -d '\n' | base64 -d 2>/dev/null)"
  [[ -n "$content" ]] || return 1

  section="$(awk -v id="$rec_id" '
    $0 ~ ("^## " id "([ \t]|$)") { capture = 1; print; next }
    capture && /^## / { exit }
    capture { print }
  ' <<<"$content")"
  [[ -n "$section" ]] || return 1

  printf '%s' "$section"
}

# review_recommendation_tech_debt_id ITEM SLUG [BRANCH] [GH_BIN]
# The single id a citing pull request is expected to name — the backtick-
# quoted register id on this recommendation's own "Tech-debt item: `<id>`"
# line, e.g. `TD-PPpfid-26080907`. Prints nothing and returns 1 when the
# section cannot be resolved (review_recommendation_section's own failure
# modes) or carries no such backtick-quoted line.
review_recommendation_tech_debt_id() {
  local section td_id
  section="$(review_recommendation_section "$@")" || return 1
  # shellcheck disable=SC2016  # the backticks are literal Markdown, not command substitution.
  td_id="$(grep -oE 'Tech-debt item: `[^`]+`' <<<"$section" | head -n1 \
    | sed -E 's/Tech-debt item: `([^`]+)`/\1/')"
  [[ -n "$td_id" ]] || return 1
  printf '%s' "$td_id"
}

# review_recommendation_tracking_ids ITEM SLUG [BRANCH] [GH_BIN]
# Every tracking id this recommendation's own "Tech-debt item(s): …" line
# names, one per line — whichever of the three shapes observed in the wild it
# is written in:
#
#   Tech-debt item: `TD-PPpfid-26080907`.    -> TD-PPpfid-26080907
#   Tech-debt item: #447.                    -> 447
#   Tech-debt items: #432 and #437.          -> 432
#                                                437
#
# The backtick form takes priority when a line somehow carries both — it is
# the more specific citation, and nothing mints a recommendation naming both a
# register id and an issue number for the same gap — but every backtick-quoted
# id on the line is emitted, not just the first: a line naming two register
# ids only resolves once both of them do (issue #2355), never once either
# alone does. A bare id only matches a standalone `#NNN`; one prefixed with an
# `owner/repo` form (`owner/repo#123`) names a different repository's issue
# and is never emitted here, since resolving it against this repository's own
# open-issue digest would answer for the wrong repo entirely (issue #2355).
# Prints nothing and returns 1 when the section cannot be resolved, or is
# resolved but names no tracking id at all (issue #2171's "no twin to
# resolve" case, left to the caller).
review_recommendation_tracking_ids() {
  local section line ids
  section="$(review_recommendation_section "$@")" || return 1
  line="$(grep -m1 -E 'Tech-debt items?:' <<<"$section")"
  [[ -n "$line" ]] || return 1
  # shellcheck disable=SC2016  # the backticks are literal Markdown, not command substitution.
  ids="$(grep -oE '`[^`]+`' <<<"$line" | sed -E 's/^`(.*)`$/\1/')"
  if [[ -n "$ids" ]]; then
    printf '%s\n' "$ids"
    return 0
  fi
  # Drop any complete owner/repo#NNN span before matching bare ids, so a
  # cross-repository reference is never stripped down to a standalone number.
  ids="$(sed -E 's/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+#[0-9]+//g' <<<"$line" \
    | grep -oE '#[0-9]+' | tr -d '#')"
  [[ -n "$ids" ]] || return 1
  printf '%s\n' "$ids"
}
