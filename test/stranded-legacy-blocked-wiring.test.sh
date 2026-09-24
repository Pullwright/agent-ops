#!/usr/bin/env bash
#
# test/stranded-legacy-blocked-wiring.test.sh — regression test for the
# lib/candidate-gather.sh half of requirement 38b's second live reconciliation
# (agent-ops#1832).
#
# test/needs-refinement.test.sh already covers the library half — which
# `{number, labelled_at, reason_labelled_at}` triples
# `refinement_blocked_label_orphaned` releases, and which items
# `refinement_blocked_label_stranded_candidates` names. What it cannot touch is
# the shell block between them, which is where this reconciliation's real cost
# and its real fragility both live:
#
#   1. **The narrowing.** `blocked` is a human's own hand-applied control, so
#      most issues carrying one can never be this path's to claim. The block
#      must ask the log which items are even candidates *before* it reads any
#      issue's timeline, or every human-blocked issue in the repo pays a
#      paginated fetch every cycle, forever, to reach a branch that was never
#      going to release it.
#   2. **The two stamps out of one read.** A `labeled` event outlives the label
#      it records, which is the whole reason the reason label — long gone from
#      this issue's live labels — is still readable. Both stamps come back from
#      the one `--paginate` fetch, whose filter re-runs per page
#      (TD-PPagop-26081306), so the aggregate is taken outside it: an issue
#      whose timeline spans two pages must still yield one stamp per label, not
#      one per page.
#   3. **The memoisation**, per (repo, item) and never bare item number, the
#      same `_REFINEMENT_ORPHAN_RECENT` makes for the first reconciliation: an
#      issue the gather loop revisits costs one timeline call, not two.
#
# The block is lifted whole out of lib/candidate-gather.sh by its own literal
# start/end lines — the same technique test/issues-excluded-wiring.test.sh and
# test/repo-entry-build.test.sh use — so a change to the real code is what this
# suite tests, not a reimplementation of it. `gh` is stubbed, and the stub runs
# the block's own `--jq` filter with real jq against a fixture timeline, so the
# filter is under test too.
#
# No test framework is used (none exists elsewhere in this repo); this is a
# plain bash script with hand-rolled assertions. Run it directly:
#
#   ./test/stranded-legacy-blocked-wiring.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/cycle-state.sh
. "$SCRIPT_DIR/lib/cycle-state.sh"
# shellcheck source=lib/void-guard.sh
. "$SCRIPT_DIR/lib/void-guard.sh"
# shellcheck source=lib/refinement.sh
. "$SCRIPT_DIR/lib/refinement.sh"
# shellcheck source=lib/label-marker.sh
. "$SCRIPT_DIR/lib/label-marker.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

failures=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected: %s\n     actual:   %s\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}

# --- Lift the block under test whole out of lib/candidate-gather.sh ----------
# Not a function, so it is lifted by its own literal start line and the `fi`
# that closes the reconciliation branch around it — the only one at that
# indentation.
route2_src="$(awk '
  index($0, "      # Requirement 38b'"'"'s Route 2 (agent-ops#1832)") == 1 { on = 1 }
  on && $0 == "    fi" { exit }
  on { print }
' "$SCRIPT_DIR/lib/candidate-gather.sh")"
if [[ "$route2_src" != *'refinement_blocked_label_stranded_candidates'* \
   || "$route2_src" != *'refinement_blocked_label_orphaned'* \
   || "$route2_src" != *'_REFINEMENT_STRANDED_STAMPS'* ]]; then
  printf 'FAIL - could not extract the Route 2 block from lib/candidate-gather.sh (moved or reworded?)\n'
  exit 1
fi

# --- The surroundings the block reads ----------------------------------------

slug="o/r"
# shellcheck disable=SC2034  # read by the lifted block, invisible to a static reader
refinement_reason_label="$(refinement_blocked_reason_label "$REFINEMENT_BLOCK_KIND")"
GITHUB_PR_LIST_LIMIT=100
union_log="$tmp_dir/union.jsonl"

# #300 and #301 are cleared legacy blocks — the cohort. #302's record is
# modern, #303's block is still open, and #402 has no record at all (a human's
# own `blocked`, the #402/#677/#678 class). Only the first two are candidates.
cat > "$union_log" <<'EOF'
{"ts":"2026-08-01T09:00:00Z","cycle":"c0","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"300","kind":"needs-refinement","detail":"gated","unblock_condition":"x","needs_refinement_assignee":"octocat"}
{"ts":"2026-08-01T10:00:00Z","cycle":"c1","event":"unblocked","repo":"o/r","item":"300"}
{"ts":"2026-08-01T09:00:00Z","cycle":"c0","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"301","kind":"needs-refinement","detail":"gated","unblock_condition":"y","needs_refinement_assignee":"octocat"}
{"ts":"2026-08-01T10:00:00Z","cycle":"c1","event":"unblocked","repo":"o/r","item":"301"}
{"ts":"2026-08-01T09:00:00Z","cycle":"c0","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"302","kind":"needs-refinement","detail":"gated","unblock_condition":"z","blocked_label":"blocked","blocked_reason_label":"blocked:needs-refinement"}
{"ts":"2026-08-01T10:00:00Z","cycle":"c1","event":"unblocked","repo":"o/r","item":"302"}
{"ts":"2026-08-01T09:00:00Z","cycle":"c0","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"303","kind":"needs-refinement","detail":"gated","unblock_condition":"w","needs_refinement_assignee":"octocat"}
EOF

issue_list_json="$tmp_dir/issue-list.json"
timeline_dir="$tmp_dir/timelines"
mkdir -p "$timeline_dir"
gh_calls="$tmp_dir/gh-calls"
label_calls_file="$tmp_dir/label-calls"
events_file="$tmp_dir/events"
: > "$gh_calls"; : > "$label_calls_file"; : > "$events_file"

# `gh issue list` serves the fixture listing; `gh api …/timeline` runs the
# block's own `--jq` filter — with real jq, so the filter itself is under test
# — over the fixture timeline, once per page, exactly as `--paginate` does.
# shellcheck disable=SC2317  # reached only from the lifted Route 2 block.
gh() {
  local a path="" filter="" want_jq=0 page num
  case "${1:-}" in
    issue)
      printf 'list %s\n' "$slug" >> "$gh_calls"
      cat "$issue_list_json"
      return 0
      ;;
    api)
      for a in "$@"; do
        if (( want_jq )); then filter="$a"; want_jq=0; continue; fi
        case "$a" in
          --jq) want_jq=1 ;;
          repos/*) path="$a" ;;
        esac
      done
      num="${path##*/issues/}"; num="${num%%/*}"
      printf 'timeline %s\n' "$num" >> "$gh_calls"
      [[ -f "$timeline_dir/$num.json" ]] || return 1
      for page in "$timeline_dir/$num.json" "$timeline_dir/$num.page2.json"; do
        [[ -f "$page" ]] || continue
        jq -r "$filter" "$page" || return 1
      done
      return 0
      ;;
  esac
  return 1
}

# The three the lifted block calls into, all reached only from it.
# shellcheck disable=SC2317
log_event() { printf '%s %s\n' "$1" "${2:-}" >> "$events_file"; }
# shellcheck disable=SC2317
github_pr_list_truncated() { (( ${1:-0} >= GITHUB_PR_LIST_LIMIT )); }
# shellcheck disable=SC2317
refinement_label_remove() {
  printf 'remove %s %s %s\n' "$1" "$2" "$3" >> "$label_calls_file"
}

labelled() {  # <label> <stamp>
  jq -nc --arg l "$1" --arg t "$2" '{event: "labeled", label: {name: $l}, created_at: $t}'
}

run_route2() { eval "$route2_src"; }
timeline_reads() { grep -c '^timeline ' "$gh_calls" || true; }
reset_calls() { : > "$gh_calls"; : > "$label_calls_file"; : > "$events_file"; }

# =============================================================================
# Part 1: the narrowing, the release, and the human's own label left alone
# =============================================================================

# The listing is what a repo really looks like: two of the cohort, one modern
# record, and one issue a human blocked by hand. #303 still carries the reason
# label, so the first reconciliation owns it and this read excludes it.
jq -nc '[{number: 300, labels: [{name: "blocked"}]},
         {number: 301, labels: [{name: "blocked"}]},
         {number: 302, labels: [{name: "blocked"}]},
         {number: 303, labels: [{name: "blocked"}, {name: "blocked:needs-refinement"}]},
         {number: 402, labels: [{name: "blocked"}, {name: "bug"}]}]' > "$issue_list_json"

# #300: the sweep applied both labels in one pass, seconds apart — and across
# two timeline pages, so the per-page filter yields the `blocked` stamp on one
# page and the reason label's on the other.
jq -nc --argjson a "$(labelled blocked 2026-08-22T11:03:12Z)" \
       --argjson b "$(jq -nc '{event: "commented", created_at: "2026-08-25T00:00:00Z"}')" \
       '[$a, $b]' > "$timeline_dir/300.json"
jq -nc --argjson a "$(labelled blocked:needs-refinement 2026-08-22T11:03:14Z)" \
       '[$a]' > "$timeline_dir/300.page2.json"
# #301: a human's own `blocked`, a fortnight after the sweep's reason label.
jq -nc --argjson a "$(labelled blocked:needs-refinement 2026-08-22T11:03:14Z)" \
       --argjson b "$(labelled blocked 2026-09-05T12:00:00Z)" \
       '[$a, $b]' > "$timeline_dir/301.json"
# #302 and #402 have timelines that would read as adjacent applications, so a
# block that failed to narrow would release them both.
jq -nc --argjson a "$(labelled blocked 2026-08-22T11:03:12Z)" \
       --argjson b "$(labelled blocked:needs-refinement 2026-08-22T11:03:14Z)" \
       '[$a, $b]' > "$timeline_dir/302.json"
cp "$timeline_dir/302.json" "$timeline_dir/402.json"

reset_calls
run_route2

assert_eq "only the log's own legacy candidates are worth a timeline read" \
  "$(printf 'timeline 300\ntimeline 301')" \
  "$(grep '^timeline ' "$gh_calls")"
assert_eq "the sweep's own adjacent pair releases the stranded label" \
  "remove o/r 300 blocked" \
  "$(cat "$label_calls_file")"
assert_eq "both of #300's stamps survive a two-page timeline" "1" \
  "$(grep -c '^timeline 300$' "$gh_calls")"
assert_eq "nothing is logged as a failed removal" "" \
  "$(grep '^warning' "$events_file" || true)"
assert_eq "the removal that did happen is recorded as this system's own action" \
  "own-label-action" \
  "$(awk '{print $1}' "$events_file" | sort -u | tr '\n' ' ' | sed 's/ $//')"

# =============================================================================
# Part 2: the memoisation
# =============================================================================

reset_calls
run_route2
assert_eq "a second pass over the same repo reads no timeline again" "0" \
  "$(timeline_reads)"
assert_eq "  ... and still releases from the stamps it already has" \
  "remove o/r 300 blocked" \
  "$(cat "$label_calls_file")"

# =============================================================================
# Part 3: an empty cohort costs nothing at all
# =============================================================================

# A repo whose log names no cleared legacy block must not even list issues:
# the listing is the cheaper of the two calls, but it is still one per repo
# per cycle for a set that can only ever be empty.
: > "$union_log"
unset _REFINEMENT_STRANDED_STAMPS
reset_calls
run_route2
assert_eq "no candidate in the log means no GitHub call at all" "" "$(cat "$gh_calls")"
assert_eq "  ... and no label is touched" "" "$(cat "$label_calls_file")"

# =============================================================================
# Part 4: the block survives the `set -e` it really runs under
# =============================================================================

# agent-cycle.sh runs under `set -euo pipefail`, and every guard in this block
# — a `gh` that fails, a listing that is not JSON, a timeline with no matching
# event — has to be a no-op rather than an aborted gather.
(
  set -euo pipefail
  # shellcheck disable=SC2030  # this subshell's own copy, deliberately
  unset _REFINEMENT_STRANDED_STAMPS
  cat > "$union_log" <<'EOF'
{"ts":"2026-08-01T09:00:00Z","cycle":"c0","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"300","kind":"needs-refinement","detail":"gated","unblock_condition":"x","needs_refinement_assignee":"octocat"}
{"ts":"2026-08-01T10:00:00Z","cycle":"c1","event":"unblocked","repo":"o/r","item":"300"}
EOF
  rm -f "$timeline_dir/300.json" "$timeline_dir/300.page2.json"
  # shellcheck disable=SC2317  # reached only from the lifted block, same as above.
  gh() { printf 'list %s\n' "$slug" >> "$gh_calls"; return 1; }
  run_route2
) >/dev/null 2>&1
assert_eq "a gh that fails outright leaves the gather running, and releases nothing" "0" "$?"

assert_eq "and no label was removed on that pass" "" "$(cat "$label_calls_file")"

if (( failures == 0 )); then
  echo "All stranded-legacy-blocked-wiring assertions passed."
  exit 0
fi
echo "$failures stranded-legacy-blocked-wiring assertion(s) FAILED." >&2
exit 1
