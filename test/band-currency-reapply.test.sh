#!/usr/bin/env bash
#
# test/band-currency-reapply.test.sh — regression test for agent-ops#2916:
# the currency re-test the cached (non-turn) branch of `gather_ordered_repos`
# (lib/candidate-gather.sh) gives the five replayed bands that, unlike the
# `issues` band's own `issue_state_reapply` (lib/candidate-select.sh,
# test/issue-state-reapply.test.sh), previously got none at all.
#
# Four things are under test, each lifted whole out of the shipped source so
# a change to the real code is what this suite exercises, not a
# reimplementation of it:
#
#   1. `pr_band_state_reapply` (lib/candidate-select.sh) — the pure jq
#      transform re-applying `gather_source_state`'s own `open_prs` sample to
#      a PR-keyed band: drops an entry whose PR has closed, and — only when
#      asked to require a draft — one whose matching PR has flipped ready.
#   2. The four gated, per-entry live-read helpers in lib/candidate-gather.sh
#      (`_merge_conflicts_state_reapply`, `_dequeued_state_reapply`,
#      `_landing_refusals_state_reapply`, `_findings_state_reapply`): each
#      skips a GitHub read entirely on an empty band, drops only the entries
#      their own targeted read confirms are stale, and fails open per entry.
#   3. The cached-branch wiring in `gather_ordered_repos` that calls all of
#      the above, gated on `state.ok` for the four PR-keyed bands and
#      unconditionally (but still band-empty-gated) for `findings_raw`.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/band-currency-reapply.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/candidate-select.sh
. "$SCRIPT_DIR/lib/candidate-select.sh"
# shellcheck source=lib/candidate-gather.sh
. "$SCRIPT_DIR/lib/candidate-gather.sh"

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

# =============================================================================
# Part 1: pr_band_state_reapply itself
# =============================================================================

band='[{"pr_number":1,"ref":"pr-1-abandoned-aaa"},{"pr_number":2,"ref":"pr-2-abandoned-bbb"},{"pr_number":3,"ref":"pr-3-abandoned-ccc"}]'
# #1 closed (absent from open_prs), #2 still open and still draft, #3 still
# open but flipped ready.
open_prs='[{"n":2,"u":"","h":"agent/x","d":true},{"n":3,"u":"","h":"agent/y","d":false}]'

out_draft="$(pr_band_state_reapply "$band" "$open_prs" "true")"
assert_eq "a PR no longer in open_prs is dropped" \
  "false" "$(jq -e 'any(.[]; .pr_number == 1)' <<<"$out_draft" >/dev/null 2>&1 && echo true || echo false)"
assert_eq "a PR still open and still draft survives" \
  "true" "$(jq -e 'any(.[]; .pr_number == 2)' <<<"$out_draft" >/dev/null 2>&1 && echo true || echo false)"
assert_eq "require-draft=true drops a PR that flipped ready" \
  "false" "$(jq -e 'any(.[]; .pr_number == 3)' <<<"$out_draft" >/dev/null 2>&1 && echo true || echo false)"
assert_eq "exactly one entry survives the draft-required pass" \
  '[{"pr_number":2,"ref":"pr-2-abandoned-bbb"}]' "$(jq -c '.' <<<"$out_draft")"

out_nodraft="$(pr_band_state_reapply "$band" "$open_prs" "false")"
assert_eq "require-draft=false keeps a flipped-ready PR, only the closed one drops" \
  '[{"pr_number":2,"ref":"pr-2-abandoned-bbb"},{"pr_number":3,"ref":"pr-3-abandoned-ccc"}]' \
  "$(jq -c '.' <<<"$out_nodraft")"

assert_eq "a malformed band is handed back unmodified" \
  "not-an-array" "$(pr_band_state_reapply "not-an-array" "$open_prs" "false")"
assert_eq "a malformed open_prs sample is handed back unmodified, never defaulted to [] (fail-open, never too-eager)" \
  "$band" "$(pr_band_state_reapply "$band" "not-an-array" "true")"
assert_eq "a genuinely empty open_prs sample drops every entry — nothing is open" \
  "[]" "$(pr_band_state_reapply "$band" "[]" "false")"

# =============================================================================
# Part 2: the gated per-entry live-read helpers
# =============================================================================

empty_band='[]'
assert_eq "_merge_conflicts_state_reapply on an empty band makes no read, returns it unmodified" \
  "$empty_band" "$(CANDIDATE_GATHER_GH="$SCRIPT_DIR/does-not-exist" _merge_conflicts_state_reapply "$empty_band" "o/r")"
assert_eq "_dequeued_state_reapply on an empty band makes no read, returns it unmodified" \
  "$empty_band" "$(_dequeued_state_reapply "$empty_band" "o/r")"
assert_eq "_landing_refusals_state_reapply on an empty band makes no read, returns it unmodified" \
  "$empty_band" "$(_landing_refusals_state_reapply "$empty_band")"
assert_eq "_findings_state_reapply on an empty band makes no read, returns it unmodified" \
  "$empty_band" "$(CANDIDATE_GATHER_GH="$SCRIPT_DIR/does-not-exist" _findings_state_reapply "$empty_band" "o/r")"

# --- _merge_conflicts_state_reapply, with a stub `gh pr view` ---------------
mc_band='[{"pr_number":10,"ref":"pr-10-conflict-aaa"},{"pr_number":11,"ref":"pr-11-conflict-bbb"},{"pr_number":12,"ref":"pr-12-conflict-ccc"},{"pr_number":13,"ref":"pr-13-conflict-ddd"}]'
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
cat > "$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
if [[ "$1 $2" == "pr view" ]]; then
  num="$3"
  [[ -f "$d/fail-$num" ]] && exit 1
  cat "$d/mergeable-$num" 2>/dev/null || exit 1
  exit 0
fi
exit 1
STUB
chmod +x "$tmp_dir/gh"
printf 'CONFLICTING' > "$tmp_dir/mergeable-10"
printf 'MERGEABLE' > "$tmp_dir/mergeable-11"
: > "$tmp_dir/fail-12"
printf 'UNKNOWN' > "$tmp_dir/mergeable-13"

out_mc="$(CANDIDATE_GATHER_GH="$tmp_dir/gh" _merge_conflicts_state_reapply "$mc_band" "o/r")"
assert_eq "still CONFLICTING survives" \
  "true" "$(jq -e 'any(.[]; .pr_number == 10)' <<<"$out_mc" >/dev/null 2>&1 && echo true || echo false)"
assert_eq "resolved to MERGEABLE is dropped" \
  "false" "$(jq -e 'any(.[]; .pr_number == 11)' <<<"$out_mc" >/dev/null 2>&1 && echo true || echo false)"
assert_eq "a failed read leaves the entry exactly as it arrived (fail open per entry)" \
  "true" "$(jq -e 'any(.[]; .pr_number == 12)' <<<"$out_mc" >/dev/null 2>&1 && echo true || echo false)"
assert_eq "a transient UNKNOWN read leaves the entry exactly as it arrived, never dropped" \
  "true" "$(jq -e 'any(.[]; .pr_number == 13)' <<<"$out_mc" >/dev/null 2>&1 && echo true || echo false)"

# --- _dequeued_state_reapply, stubbing merge_queue_probe itself ------------
dq_band='[{"pr_number":20,"ref":"pr-20-dequeued-aaa"},{"pr_number":21,"ref":"pr-21-dequeued-bbb"},{"pr_number":22,"ref":"pr-22-dequeued-ccc"}]'
merge_queue_probe() {  # <slug> <number>
  case "$2" in
    20) printf '{"queued":false}' ;;        # still dequeued: survives
    21) printf '{"queued":true}' ;;         # re-queued: drop
    22) return 1 ;;                          # probe failed: fail open, keep
  esac
}
out_dq="$(_dequeued_state_reapply "$dq_band" "o/r")"
assert_eq "still not re-queued survives" \
  "true" "$(jq -e 'any(.[]; .pr_number == 20)' <<<"$out_dq" >/dev/null 2>&1 && echo true || echo false)"
assert_eq "re-queued is dropped" \
  "false" "$(jq -e 'any(.[]; .pr_number == 21)' <<<"$out_dq" >/dev/null 2>&1 && echo true || echo false)"
assert_eq "a failed probe leaves the entry exactly as it arrived (fail open per entry)" \
  "true" "$(jq -e 'any(.[]; .pr_number == 22)' <<<"$out_dq" >/dev/null 2>&1 && echo true || echo false)"

# --- _landing_refusals_state_reapply, stubbing reconciliation_unreconciled_comments
lr_band='[{"pr_number":30,"pr_url":"https://github.com/o/r/pull/30","ref":"pr-30-landing-refusal-1"},{"pr_number":31,"pr_url":"https://github.com/o/r/pull/31","ref":"pr-31-landing-refusal-2"},{"pr_number":32,"pr_url":"https://github.com/o/r/pull/32","ref":"pr-32-landing-refusal-3"}]'
reconciliation_unreconciled_comments() {  # <pr_url>
  case "$1" in
    *"/30") printf '[{"id":1}]' ;;    # still unreconciled: survives
    *"/31") printf '[]' ;;            # answered since: drop
    *"/32") printf '[]'; return 1 ;;  # read failed: fail open, keep
  esac
}
out_lr="$(_landing_refusals_state_reapply "$lr_band")"
assert_eq "still unreconciled survives" \
  "true" "$(jq -e 'any(.[]; .pr_number == 30)' <<<"$out_lr" >/dev/null 2>&1 && echo true || echo false)"
assert_eq "answered since is dropped" \
  "false" "$(jq -e 'any(.[]; .pr_number == 31)' <<<"$out_lr" >/dev/null 2>&1 && echo true || echo false)"
assert_eq "a failed reconciliation read leaves the entry exactly as it arrived (fail open per entry)" \
  "true" "$(jq -e 'any(.[]; .pr_number == 32)' <<<"$out_lr" >/dev/null 2>&1 && echo true || echo false)"

# --- _findings_state_reapply, with a stub `gh api` --------------------------
f_band='[{"ref":"dependabot-alert-40","kind":"dependabot","number":40},{"ref":"code-scanning-alert-41","kind":"code-scanning","number":41},{"ref":"dependabot-alert-42","kind":"dependabot","number":42}]'
cat > "$tmp_dir/gh-findings" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "api" ]]; then
  path="$2"
  body=""
  case "$path" in
    *dependabot/alerts/40) body='{"state":"open"}' ;;
    *code-scanning/alerts/41) body='{"state":"dismissed"}' ;;
    *dependabot/alerts/42) exit 1 ;;
    *) exit 1 ;;
  esac
  jqfilter="." prev=""
  for a in "$@"; do
    [[ "$prev" == "--jq" ]] && jqfilter="$a"
    prev="$a"
  done
  jq -r "$jqfilter" <<<"$body"
  exit 0
fi
exit 1
STUB
chmod +x "$tmp_dir/gh-findings"

out_f="$(CANDIDATE_GATHER_GH="$tmp_dir/gh-findings" _findings_state_reapply "$f_band" "o/r")"
assert_eq "a still-open alert survives" \
  "true" "$(jq -e 'any(.[]; .ref == "dependabot-alert-40")' <<<"$out_f" >/dev/null 2>&1 && echo true || echo false)"
assert_eq "a dismissed alert is dropped" \
  "false" "$(jq -e 'any(.[]; .ref == "code-scanning-alert-41")' <<<"$out_f" >/dev/null 2>&1 && echo true || echo false)"
assert_eq "a failed alert read leaves the entry exactly as it arrived (fail open per entry)" \
  "true" "$(jq -e 'any(.[]; .ref == "dependabot-alert-42")' <<<"$out_f" >/dev/null 2>&1 && echo true || echo false)"

# =============================================================================
# Part 3: the cached-branch wiring in lib/candidate-gather.sh
# =============================================================================
#
# Lifted whole, the same technique test/issue-state-reapply.test.sh's own
# Part 2 uses for the issues-source block right beside this one: the exact
# source text between the tech-debt cache load and the pre-existing
# `findings="[]"` line, so a change to the real wiring is what this exercises.

cached_block_src="$(awk '
  index($0, "  # agent-ops#2916: the currency re-test the issues band alone had") == 1 { on = 1 }
  on { print }
  on && index($0, "  findings=\"[]\"") == 1 { exit }
' "$SCRIPT_DIR/lib/candidate-gather.sh")"
if [[ "$cached_block_src" != *'pr_band_state_reapply'* \
   || "$cached_block_src" != *'_merge_conflicts_state_reapply'* \
   || "$cached_block_src" != *'_dequeued_state_reapply'* \
   || "$cached_block_src" != *'_landing_refusals_state_reapply'* \
   || "$cached_block_src" != *'_findings_state_reapply'* ]]; then
  printf 'FAIL - could not extract the cached-branch currency-reapply block from lib/candidate-gather.sh (moved or reworded?)\n'
  exit 1
fi

run_cached_block() {  # <state-json> <abandoned_drafts_raw> <merge_conflicts_raw> <dequeued_raw> <landing_refusals_raw> <findings_raw>
  (
    # Consumed only by the eval'd block below, invisible to static analysis.
    # shellcheck disable=SC2034
    state="$1" abandoned_drafts_raw="$2" merge_conflicts_raw="$3" dequeued_raw="$4" \
      landing_refusals_raw="$5" findings_raw="$6" slug='o/r'
    eval "$cached_block_src"
    # Assigned only by the eval'd block above, invisible to static analysis.
    # shellcheck disable=SC2154
    jq -nc --argjson ad "$abandoned_drafts_raw" --argjson mc "$merge_conflicts_raw" \
      --argjson dq "$dequeued_raw" --argjson lr "$landing_refusals_raw" --argjson f "$findings_raw" \
      '{abandoned_drafts_raw: $ad, merge_conflicts_raw: $mc, dequeued_raw: $dq,
        landing_refusals_raw: $lr, findings_raw: $f}'
  )
}

# A stub merge_queue_probe/reconciliation_unreconciled_comments that never
# drops anything, and a stub gh (via CANDIDATE_GATHER_GH) that never drops
# anything either — this part is about the wiring (what gets called, and
# when), not re-proving Part 2's own per-entry drop logic. Both are invoked
# only from inside run_cached_block's eval'd block, invisible to static
# analysis.
# shellcheck disable=SC2317,SC2329
merge_queue_probe() { printf '{"queued":false}'; }
# shellcheck disable=SC2317,SC2329
reconciliation_unreconciled_comments() { printf '[]'; return 1; }
cat > "$tmp_dir/gh-noop" <<'STUB'
#!/usr/bin/env bash
if [[ "$1 $2" == "pr view" ]]; then printf 'CONFLICTING'; exit 0; fi
exit 1
STUB
chmod +x "$tmp_dir/gh-noop"
export CANDIDATE_GATHER_GH="$tmp_dir/gh-noop"

state_ok='{"ok":true,"open_prs":[{"n":1,"u":"","h":"agent/x","d":true},{"n":2,"u":"","h":"agent/y","d":true}]}'
ad_band='[{"pr_number":1,"ref":"pr-1-abandoned-aaa"},{"pr_number":2,"ref":"pr-2-abandoned-bbb"}]'
mc_band2='[{"pr_number":1,"ref":"pr-1-conflict-aaa"},{"pr_number":3,"ref":"pr-3-conflict-ccc"}]'

out_wired="$(run_cached_block "$state_ok" "$ad_band" "$mc_band2" '[]' '[]' '[]')"
assert_eq "wiring: state.ok true drops an abandoned-draft entry whose PR has closed" \
  "false" "$(jq -e '.abandoned_drafts_raw | any(.pr_number == 3)' <<<"$out_wired" >/dev/null 2>&1 && echo true || echo false)"
assert_eq "wiring: state.ok true drops a merge-conflict entry whose PR has closed" \
  "false" "$(jq -e '.merge_conflicts_raw | any(.pr_number == 3)' <<<"$out_wired" >/dev/null 2>&1 && echo true || echo false)"
assert_eq "wiring: a merge-conflict entry whose PR is still open and still conflicting survives both passes" \
  "true" "$(jq -e '.merge_conflicts_raw | any(.pr_number == 1)' <<<"$out_wired" >/dev/null 2>&1 && echo true || echo false)"

# --- state.ok == false: every PR-keyed band is left exactly as replayed ----
state_bad='{"ok":false}'
out_bad="$(run_cached_block "$state_bad" "$ad_band" "$mc_band2" '[]' '[]' '[]')"
assert_eq "wiring: a failed state sample leaves abandoned_drafts_raw unfiltered" \
  "$ad_band" "$(jq -c '.abandoned_drafts_raw' <<<"$out_bad")"
assert_eq "wiring: a failed state sample leaves merge_conflicts_raw unfiltered" \
  "$mc_band2" "$(jq -c '.merge_conflicts_raw' <<<"$out_bad")"

# --- findings_raw's reapplication runs regardless of state.ok, gated only on
#     its own band being non-empty ------------------------------------------
cat > "$tmp_dir/gh-findings-wired" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "api" ]]; then
  case "$2" in
    *dependabot/alerts/50)
      jqfilter="." prev=""
      for a in "$@"; do
        [[ "$prev" == "--jq" ]] && jqfilter="$a"
        prev="$a"
      done
      jq -r "$jqfilter" <<<'{"state":"dismissed"}'
      exit 0
      ;;
  esac
fi
exit 1
STUB
chmod +x "$tmp_dir/gh-findings-wired"
f_band_wired='[{"ref":"dependabot-alert-50","kind":"dependabot","number":50}]'
export CANDIDATE_GATHER_GH="$tmp_dir/gh-findings-wired"
out_findings_wired="$(run_cached_block "$state_bad" '[]' '[]' '[]' '[]' "$f_band_wired")"
assert_eq "wiring: findings_raw is re-tested even when state.ok is false, and a dismissed alert is dropped" \
  "[]" "$(jq -c '.findings_raw' <<<"${out_findings_wired:-}")"

unset -f merge_queue_probe reconciliation_unreconciled_comments
unset CANDIDATE_GATHER_GH

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
