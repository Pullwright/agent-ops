#!/usr/bin/env bash
#
# test/resource-budget-report.test.sh — regression test for
# scripts/resource-budget-report.sh (requirement 55, D14, issue #606).
#
# lib/resource-usage.sh's resource_budget_report is covered in isolation by
# test/resource-usage.test.sh; what is worth testing here is the thin I/O
# wrapper around it — that it reads state_dir and the configured window from
# config.json, that --state-dir/--window-hours/--now override them, and that
# a missing state_dir or samples file degrades to a clean empty report
# rather than an error, the same posture scripts/doctor.sh's own host-budget
# section already takes on an unwritten record.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/resource-budget-report.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT="$SCRIPT_DIR/scripts/resource-budget-report.sh"

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

state_dir="$tmp_dir/state"
mkdir -p "$state_dir"
cat > "$state_dir/.resource-samples.jsonl" <<'EOF'
{"ts":"2026-09-15T05:00:00Z","service":"scheduler","cpu_cores":0.3,"memory_bytes":250000000}
{"ts":"2026-01-01T00:00:00Z","service":"scheduler","cpu_cores":9.9,"memory_bytes":999}
EOF
config="$tmp_dir/config.json"
cat > "$config" <<EOF
{
  "repos": [{"slug": "o/r", "default_branch": "main", "sources": ["issues"]}],
  "state_dir": "$state_dir",
  "workspace_root": "$tmp_dir/ws",
  "coordinator_model": "claude-sonnet-5",
  "implementer_model_default": "claude-sonnet-5",
  "implementer_model_trivial": "claude-sonnet-5",
  "reviewer_model_default": "claude-sonnet-5",
  "pr_label": "autonomous-agent",
  "branch_prefix": "agent/",
  "max_open_agent_prs": 5,
  "limit_cooldown_default": 60,
  "resources": {"report_window_hours": 24}
}
EOF

out="$("$REPORT" --config "$config" --now "2026-09-15T06:00:00Z")"
assert_eq "the configured report_window_hours excludes the 2026-01-01 sample" \
  "1" "$(jq -r '.sample_count' <<<"$out")"
assert_eq "…and the surviving sample is the recent one" \
  "0.3" "$(jq -r '.containers.scheduler.cpu_cores.latest' <<<"$out")"

out_wide="$("$REPORT" --config "$config" --now "2026-09-15T06:00:00Z" --window-hours 100000)"
assert_eq "--window-hours overrides the configured window" \
  "2" "$(jq -r '.sample_count' <<<"$out_wide")"

other_state_dir="$tmp_dir/other-state"
mkdir -p "$other_state_dir"
cat > "$other_state_dir/.resource-samples.jsonl" <<'EOF'
{"ts":"2026-09-15T05:59:00Z","service":"dashboard","memory_bytes":5}
EOF
out_override="$("$REPORT" --config "$config" --state-dir "$other_state_dir" --now "2026-09-15T06:00:00Z")"
assert_eq "--state-dir overrides config.json's own state_dir" \
  "5" "$(jq -r '.containers.dashboard.memory_bytes.latest' <<<"$out_override")"

empty_state_dir="$tmp_dir/empty-state"
out_empty="$("$REPORT" --config "$config" --state-dir "$empty_state_dir" --now "2026-09-15T06:00:00Z")"
assert_eq "a state_dir with no samples file yet degrades to a clean empty report" \
  '{"containers":{},"volumes":{},"sample_count":0,"window_start":"2026-09-14T06:00:00Z"}' \
  "$out_empty"

missing_config="$tmp_dir/does-not-exist.json"
out_no_config="$("$REPORT" --config "$missing_config" --now "2026-09-15T06:00:00Z" 2>/dev/null)"
assert_eq "a missing config file still exits cleanly (degrades, never errors out)" \
  "0" "$?"
assert_eq "…printing a valid, empty report rather than nothing" \
  "0" "$(jq -r '.sample_count' <<<"$out_no_config")"

echo
if (( failures == 0 )); then
  echo "All resource-budget-report assertions passed."
  exit 0
else
  echo "$failures resource-budget-report assertion(s) FAILED."
  exit 1
fi
