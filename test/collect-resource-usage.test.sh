#!/usr/bin/env bash
#
# test/collect-resource-usage.test.sh — end-to-end regression test for
# scripts/collect-resource-usage.sh (requirement 55, D14, issue #606).
#
# lib/resource-usage.sh's own arithmetic is covered in isolation by
# test/resource-usage.test.sh; what is worth testing here is the script
# around it: that a fresh (or freshly-touched) state file never loses a
# baseline it just wrote — jq given a genuinely empty file runs its filter
# zero times rather than erroring, so a naive "write to a temp file, mv
# over the original" can silently install an empty file when the source
# was empty, which is exactly what happened here before it was guarded
# (a second tick's delta arithmetic went missing, silently, with no
# non-zero exit anywhere to catch it) — a real regression this test exists
# to pin down; the disk-sampling throttle; the retention prune; and that a
# missing AGENT_OPS_SERVICE/--service is a clean no-op, never a crash.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/collect-resource-usage.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COLLECT="$SCRIPT_DIR/scripts/collect-resource-usage.sh"

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
assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# --- fixtures ------------------------------------------------------------
state_dir="$tmp_dir/state"
cgroup_root="$tmp_dir/cgroup"
net_dev="$tmp_dir/net_dev"
config="$tmp_dir/config.json"
mkdir -p "$state_dir" "$cgroup_root" "$tmp_dir/ws"

touch "$cgroup_root/cgroup.controllers"
echo 100000000 > "$cgroup_root/memory.current"
printf 'usage_usec 1000000\n' > "$cgroup_root/cpu.stat"
cat > "$net_dev" <<'EOF'
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
  eth0: 500000 10 0 0 0 0 0 0 200000 5 0 0 0 0 0 0
EOF
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
  "resources": {"disk_sample_interval_minutes": 60}
}
EOF

run() {
  "$COLLECT" --config "$config" --cgroup-root "$cgroup_root" --net-dev-file "$net_dev" "$@"
}

# --- no AGENT_OPS_SERVICE and no --service is a clean no-op ----------------
out="$(env -u AGENT_OPS_SERVICE "$COLLECT" --config "$config" --now "2026-09-15T06:00:00Z" 2>&1)"
rc=$?
assert_eq "no service named exits 0 (never breaks a cron tick)" "0" "$rc"
assert_contains "…and says why, on stderr" "AGENT_OPS_SERVICE is unset" "$out"
assert_eq "…and nothing was written" "0" "$(find "$state_dir" -name '.resource-samples.jsonl' | wc -l | tr -d ' ')"

# --- tick 1: no prior baseline, so cpu_cores/net rates are absent ----------
run --service scheduler --now "2026-09-15T06:00:00Z" >/dev/null
samples_after_1="$(cat "$state_dir/.resource-samples.jsonl")"
assert_eq "tick 1 writes exactly one scheduler sample and two disk samples (first tick always samples disk)" \
  "3" "$(wc -l < "$state_dir/.resource-samples.jsonl" | tr -d ' ')"
assert_eq "tick 1's scheduler sample carries memory_bytes" \
  "100000000" "$(jq -r 'select(.service == "scheduler") | .memory_bytes' <<<"$samples_after_1")"
assert_eq "tick 1's scheduler sample carries no cpu_cores yet (no baseline)" \
  "" "$(jq -r 'select(.service == "scheduler") | .cpu_cores // empty' <<<"$samples_after_1")"
assert_eq "the cumulative-reading cache now holds this tick's raw counters" \
  "1000000000" "$(jq -r '.scheduler.cpu_nanos' "$state_dir/.resource-usage-state.json")"

# --- tick 2, 5 minutes later: counters advanced, so a delta is computed ---
echo 150000000 > "$cgroup_root/memory.current"
printf 'usage_usec 4000000\n' > "$cgroup_root/cpu.stat"
cat > "$net_dev" <<'EOF'
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
  eth0: 800000 15 0 0 0 0 0 0 260000 8 0 0 0 0 0 0
EOF
run --service scheduler --now "2026-09-15T06:05:00Z" >/dev/null
tick2_sample="$(tail -n 1 "$state_dir/.resource-samples.jsonl")"
assert_eq "tick 2's cpu_cores is (4e9-1e9)ns over 300s = 0.01 cores" \
  "0.0100" "$(jq -r '.cpu_cores' <<<"$tick2_sample")"
assert_eq "tick 2's net_rx_bytes_per_hour is (800000-500000)*3600/300" \
  "3600000" "$(jq -r '.net_rx_bytes_per_hour' <<<"$tick2_sample")"
assert_eq "tick 2's net_tx_bytes_per_hour is (260000-200000)*3600/300" \
  "720000" "$(jq -r '.net_tx_bytes_per_hour' <<<"$tick2_sample")"
assert_eq "tick 2 does not re-sample disk (throttled to disk_sample_interval_minutes) — still just tick 1's two volumes" \
  "2" "$(jq -r 'select(.volume) | .volume' "$state_dir/.resource-samples.jsonl" | wc -l | tr -d ' ')"

# --- a container recreation (cpu_nanos resets lower) yields no bogus delta -
echo 200000000 > "$cgroup_root/memory.current"
printf 'usage_usec 500000\n' > "$cgroup_root/cpu.stat"
run --service scheduler --now "2026-09-15T06:10:00Z" >/dev/null
tick3_sample="$(tail -n 1 "$state_dir/.resource-samples.jsonl")"
assert_eq "a reset counter (container recreated) yields no cpu_cores this tick" \
  "" "$(jq -r '.cpu_cores // empty' <<<"$tick3_sample")"

# --- disk sampling fires again once the throttle interval has passed ------
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
  "resources": {"disk_sample_interval_minutes": 5}
}
EOF
run --service scheduler --now "2026-09-15T06:15:00Z" >/dev/null
assert_eq "a shorter throttle interval samples disk again on the next due tick" \
  "2" "$(jq -r 'select(.volume) | .volume' "$state_dir/.resource-samples.jsonl" | sort -u | wc -l | tr -d ' ')"

# --- a second service sharing state_dir gets its own cached baseline,
#     never clobbering the first's ----------------------------------------
dashboard_cgroup="$tmp_dir/cgroup-dashboard"
mkdir -p "$dashboard_cgroup"
touch "$dashboard_cgroup/cgroup.controllers"
echo 50000000 > "$dashboard_cgroup/memory.current"
printf 'usage_usec 200000\n' > "$dashboard_cgroup/cpu.stat"
"$COLLECT" --config "$config" --service dashboard --cgroup-root "$dashboard_cgroup" \
  --net-dev-file "$net_dev" --now "2026-09-15T06:15:00Z" >/dev/null
assert_eq "the state cache holds both services, each its own baseline" \
  "true" "$(jq -r 'has("scheduler") and has("dashboard")' "$state_dir/.resource-usage-state.json")"
assert_eq "…and scheduler's own baseline is untouched by dashboard's tick" \
  "true" "$(jq -r '.scheduler.cpu_nanos > 0' "$state_dir/.resource-usage-state.json")"

# --- --no-prune leaves an old sample in place; the default prune removes it
old_state_dir="$tmp_dir/state-prune"
mkdir -p "$old_state_dir"
cat > "$old_state_dir/.resource-samples.jsonl" <<'EOF'
{"ts":"2020-01-01T00:00:00Z","service":"scheduler","memory_bytes":1}
EOF
prune_config="$tmp_dir/prune-config.json"
cat > "$prune_config" <<EOF
{
  "repos": [{"slug": "o/r", "default_branch": "main", "sources": ["issues"]}],
  "state_dir": "$old_state_dir",
  "workspace_root": "$tmp_dir/ws",
  "coordinator_model": "claude-sonnet-5",
  "implementer_model_default": "claude-sonnet-5",
  "implementer_model_trivial": "claude-sonnet-5",
  "reviewer_model_default": "claude-sonnet-5",
  "pr_label": "autonomous-agent",
  "branch_prefix": "agent/",
  "max_open_agent_prs": 5,
  "limit_cooldown_default": 60,
  "resources": {"sample_retention_hours": 1, "disk_sample_interval_minutes": 6000}
}
EOF
"$COLLECT" --config "$prune_config" --service scheduler --cgroup-root "$cgroup_root" \
  --net-dev-file "$net_dev" --now "2026-09-15T06:00:00Z" --no-prune >/dev/null
assert_eq "--no-prune leaves the ancient sample in place" \
  "1" "$(jq -rc 'select(.ts == "2020-01-01T00:00:00Z")' "$old_state_dir/.resource-samples.jsonl" | wc -l | tr -d ' ')"
"$COLLECT" --config "$prune_config" --service scheduler --cgroup-root "$cgroup_root" \
  --net-dev-file "$net_dev" --now "2026-09-15T06:05:00Z" >/dev/null
assert_eq "the default (pruning) run drops it, outside sample_retention_hours" \
  "0" "$(jq -rc 'select(.ts == "2020-01-01T00:00:00Z")' "$old_state_dir/.resource-samples.jsonl" | wc -l | tr -d ' ')"

echo
if (( failures == 0 )); then
  echo "All collect-resource-usage assertions passed."
  exit 0
else
  echo "$failures collect-resource-usage assertion(s) FAILED."
  exit 1
fi
