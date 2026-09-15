#!/usr/bin/env bash
#
# test/void-retire-wiring.test.sh — regression test for the wiring that
# survives PR #1503's removal of the register-hygiene machinery (issue
# #1529): the block in lib/candidate-gather.sh that turns requirement 34n's
# liveness rule into a decision for the five void shapes still live there —
# alert, merge-conflict, dequeued, human-visibility, failed-run — plus the
# two argument-wiring rules beside it.
#
# PR #1503 (issue #882) deleted the original test/void-retire-wiring.test.sh
# whole. Half of it died legitimately alongside it — the
# gather_register_hygiene per-pass diagnostic-filename assertions, which
# guarded a two-pass (prefetch/void) filename collision unique to the
# register machinery that no longer exists. The other half guarded wiring
# that is still live and is now covered by nothing:
#
#   - **The per-shape tee-file read-back block that builds
#     void_liveness_gather_json.** A repo with no gather for a shape must
#     decide nothing for that shape (ok:false, empty ids) — a regression
#     here silently retires still-live voids on a gather that never ran.
#   - **void_config_actioned's call site reads the unnarrowed
#     all_repos_json**, never repos_json (carries --repo's filter) or
#     ordered_repos_json (rewritten by back-pressure) — either of the other
#     two would mint spurious source-dropped retirements on a --repo run or
#     a back-pressured cycle.
#   - **The void residue list travels to jq on stdin, never argv**
#     (requirement 4g) — the extract is unbounded, and an --argjson
#     delivery of it once silently failed into its own `|| echo '[]'`
#     fallback, disabling the sweep that retires void state.
#
# test/cycle-state.test.sh covers the pure functions either side of this
# wiring and — per the original file's own header — passes with the wiring
# broken; that was observed for real when requirement 34n first shipped
# (PR #340).
#
# The liveness-gather block is lifted verbatim out of lib/candidate-gather.sh,
# the way test/backpressure-wiring.test.sh and test/auth-failure-wiring.test.sh
# lift theirs, so the assertions are about the shipped code rather than a copy
# of its logic.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/void-retire-wiring.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

extract_block() {
  local start_re="$1" end_re="$2" file="$3"
  BLOCK_START_RE="$start_re" BLOCK_END_RE="$end_re" awk '
    $0 ~ ENVIRON["BLOCK_START_RE"] { on = 1 }
    on                             { print }
    on && $0 ~ ENVIRON["BLOCK_END_RE"] { exit }
  ' "$file"
}

liveness_block="$(extract_block '^  void_failed_run_repos_json="\$\(jq' '^  done < <' "$SCRIPT_DIR/lib/candidate-gather.sh")"
if [[ -z "$liveness_block" ]]; then
  echo "FAIL - could not extract the void-liveness gather block from lib/candidate-gather.sh — has it moved?" >&2
  exit 1
fi
if grep -q 'register-hygiene' <<<"$liveness_block"; then
  echo "FAIL - extracted block still references register-hygiene — the anchors matched stale text, or the register machinery came back" >&2
  exit 1
fi

# --- Half two: which files the liveness pass reads back for each shape --------
#
# void_liveness_gather_json is built per repo, per shape, in one pass. Each
# scenario below writes the cycle dir's tee files for some subset of the five
# shapes and reads the whole per-repo map back, so one call covers several
# shapes' read-back at once.

# shellcheck disable=SC2016  # The harness's own $void_liveness_gather_json, written out literally for the assembled script to expand, not this shell.
run_liveness_block() {
  local cycle="$1" void_json="$2" source_states_json="$3" basenames_body="$4" harness="$tmp_dir/liveness-harness.sh"
  {
    printf '%s\n' 'set -euo pipefail'
    printf '. %q\n' "$SCRIPT_DIR/lib/void-liveness.sh"
    printf 'cycle_dir=%q\n' "$cycle"
    printf 'void_json=%q\n' "$void_json"
    printf 'ordered_repos_json=%q\n' '[{"slug":"o/r"}]'
    printf 'source_states_json=%q\n' "$source_states_json"
    printf 'gather_workflow_basenames() {\n%s\n}\n' "$basenames_body"
    printf '%s\n' "$liveness_block"
    printf '%s\n' 'printf "%s" "$void_liveness_gather_json"'
  } > "$harness"
  bash "$harness" 2>/dev/null
}

no_basenames='printf "%s" "{\"ok\":false,\"basenames\":{}}"'

# A repo with no gather at all: every shape decides nothing, including
# failed-run (which is skipped outright — its id never appears in void_json).
lv_cycle="$tmp_dir/lv-quiet"
rm -rf "$lv_cycle"; mkdir -p "$lv_cycle"
out="$(run_liveness_block "$lv_cycle" '[]' '[]' "$no_basenames")"
for shape in alert merge-conflict dequeued human-visibility failed-run; do
  assert_eq "quiet repo: $shape decides nothing (ok:false)" \
    "false" "$(jq -r --arg s "$shape" '."o/r"[$s].ok' <<<"$out")"
  assert_eq "  ... and offers no ids to decide it with" \
    "[]" "$(jq -c --arg s "$shape" '."o/r"[$s].ids' <<<"$out")"
done

# Every shape gathered something this cycle, including a completed
# failed-run gather (id -> basename resolved via gather_workflow_basenames).
lv_cycle="$tmp_dir/lv-full"
rm -rf "$lv_cycle"; mkdir -p "$lv_cycle"
printf '%s\n' '[{"ref":"dependabot-alert-7"}]' > "$lv_cycle/findings-o_r.json"
: > "$lv_cycle/findings-o_r.ok"
printf '%s\n' '[{"ref":"pr-12-conflict-abc123"}]' > "$lv_cycle/merge-conflicts-o_r.json"
: > "$lv_cycle/merge-conflicts-o_r.ok"
printf '%s\n' '[{"ref":"pr-13-dequeued-def456"}]' > "$lv_cycle/dequeued-o_r.json"
: > "$lv_cycle/dequeued-o_r.ok"
printf '%s\n' '[{"ref":"human-visibility-abcabcabcabc"}]' > "$lv_cycle/human-visibility-hygiene-o_r.json"
: > "$lv_cycle/human-visibility-hygiene-o_r.ok"

fr_void_json='[{"repo":"o/r","item":"failed-run-build"}]'
fr_source_states='[{"slug":"o/r","ok":true,"workflows":[{"w":42,"c":"failure"}]}]'
fr_basenames='printf "%s" "{\"ok\":true,\"basenames\":{\"42\":\"build\"}}"'

out="$(run_liveness_block "$lv_cycle" "$fr_void_json" "$fr_source_states" "$fr_basenames")"

assert_eq "full repo: alert reads its tee's ids" \
  "true" "$(jq -r '."o/r".alert.ok' <<<"$out")"
assert_eq "  ... alert" '["dependabot-alert-7"]' "$(jq -c '."o/r".alert.ids' <<<"$out")"
assert_eq "full repo: merge-conflict reads its tee's ids" \
  "true" "$(jq -r '."o/r"."merge-conflict".ok' <<<"$out")"
assert_eq "  ... merge-conflict" '["pr-12-conflict-abc123"]' "$(jq -c '."o/r"."merge-conflict".ids' <<<"$out")"
assert_eq "full repo: dequeued reads its tee's ids" \
  "true" "$(jq -r '."o/r".dequeued.ok' <<<"$out")"
assert_eq "  ... dequeued" '["pr-13-dequeued-def456"]' "$(jq -c '."o/r".dequeued.ids' <<<"$out")"
assert_eq "full repo: human-visibility reads its tee's ids" \
  "true" "$(jq -r '."o/r"."human-visibility".ok' <<<"$out")"
assert_eq "  ... human-visibility" '["human-visibility-abcabcabcabc"]' "$(jq -c '."o/r"."human-visibility".ids' <<<"$out")"
assert_eq "full repo: failed-run resolves the workflow id through gather_workflow_basenames" \
  "true" "$(jq -r '."o/r"."failed-run".ok' <<<"$out")"
assert_eq "  ... failed-run" '["failed-run-build"]' "$(jq -c '."o/r"."failed-run".ids' <<<"$out")"

# A completed gather that found nothing is a real answer, not an ungathered
# shape: ok:true with empty ids, distinct from ok:false above.
lv_cycle="$tmp_dir/lv-empty"
rm -rf "$lv_cycle"; mkdir -p "$lv_cycle"
printf '%s\n' '[]' > "$lv_cycle/findings-o_r.json"
: > "$lv_cycle/findings-o_r.ok"
out="$(run_liveness_block "$lv_cycle" '[]' '[]' "$no_basenames")"
assert_eq "a completed gather with nothing to report still earns ok:true" \
  "true" "$(jq -r '."o/r".alert.ok' <<<"$out")"
assert_eq "  ... with an empty answer, not a fabricated one" \
  "[]" "$(jq -c '."o/r".alert.ids' <<<"$out")"

# failed-run carries a second gather beyond the tee files the other four
# shapes trust (id -> basename resolution): if that gather itself fails, only
# failed-run decides nothing — it never drags the other four shapes' own,
# already-successful reads down with it.
lv_cycle="$tmp_dir/lv-fr-fail"
rm -rf "$lv_cycle"; mkdir -p "$lv_cycle"
printf '%s\n' '[{"ref":"dependabot-alert-7"}]' > "$lv_cycle/findings-o_r.json"
: > "$lv_cycle/findings-o_r.ok"
out="$(run_liveness_block "$lv_cycle" "$fr_void_json" "$fr_source_states" "$no_basenames")"
assert_eq "failed-run's own gather failing decides nothing for failed-run" \
  "false" "$(jq -r '."o/r"."failed-run".ok' <<<"$out")"
assert_eq "  ... while alert's already-successful read is unaffected" \
  "true" "$(jq -r '."o/r".alert.ok' <<<"$out")"

# --- Half three: which arguments the two rules are wired to -------------------
#
# Source-text assertions, because the failure is invisible at runtime until
# the cycle that exhibits it: a --repo run or a back-pressured cycle retiring
# a repo's whole void residue on a narrowing that means nothing of the sort,
# or the unbounded residue list crossing MAX_ARG_STRLEN through an --argjson
# delivery. The gather_register_hygiene rows the original file carried here
# are dropped along with the function itself — there is nothing left to wire.
while IFS=$'\t' read -r want desc pattern; do
  [[ -n "$pattern" ]] || continue
  assert_eq "$desc" "$want" "$(grep -cF -- "$pattern" "$SCRIPT_DIR/lib/candidate-gather.sh")"
done <<'PATTERNS'
1	void_review_plan_actioned is handed the review-superseded signal as its fourth argument	void_review_plan_actioned "$void_json" "$void_review_status_json" "$void_plan_status_json" "$void_review_current_json"
1	void_config_actioned is handed the unnarrowed all_repos_json	void_config_actioned "$void_json" "$all_repos_json"
0	  ... and never the --repo-filtered repos_json	void_config_actioned "$void_json" "$repos_json"
0	  ... nor the back-pressure-narrowed ordered_repos_json	void_config_actioned "$void_json" "$ordered_repos_json"
0	the void residue list never travels to jq via argv	--argjson void "$void_json"
PATTERNS

if (( failures )); then
  printf '\n%d assertion(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\nall assertions passed\n'
