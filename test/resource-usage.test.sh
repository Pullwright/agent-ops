#!/usr/bin/env bash
#
# test/resource-usage.test.sh — regression test for lib/resource-usage.sh
# (requirement 55, D14, issue #606).
#
# What matters here:
#
#   both cgroup layouts   one node in the fleet presents v1, its siblings
#                         v2 — a collector that reads only one reports
#                         nothing on half the fleet, silently, unless every
#                         read takes the layout as an argument and degrades
#                         to empty (never a fabricated 0) off "unknown".
#   deltas, never          CPU usage and network byte counts are cumulative
#   absolutes              counters that reset to zero on every container
#                         recreation; reporting the negative delta a naive
#                         subtraction would produce is worse than reporting
#                         nothing.
#   the report survives    a line that is not valid JSON, or an empty input,
#   malformed input        must degrade to a valid empty report rather than
#                         aborting — the same discipline
#                         test/pickup-metrics.test.sh already exercises for
#                         log.jsonl.
#   the breach comparison  strictly greater than, never at-or-above, and an
#                         unbudgeted or unmeasured resource contributes
#                         nothing — the one comparison doctor.sh and the
#                         dashboard must never disagree about.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/resource-usage.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/resource-usage.sh
. "$SCRIPT_DIR/lib/resource-usage.sh"

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

# --- cgroup layout detection -------------------------------------------------
v2_root="$tmp_dir/v2"
mkdir -p "$v2_root"
touch "$v2_root/cgroup.controllers"
echo 209715200 > "$v2_root/memory.current"
printf 'usage_usec 5000000\nuser_usec 4000000\nsystem_usec 1000000\n' > "$v2_root/cpu.stat"

v1_root="$tmp_dir/v1"
mkdir -p "$v1_root/memory" "$v1_root/cpuacct"
echo 104857600 > "$v1_root/memory/memory.usage_in_bytes"
echo 3000000000 > "$v1_root/cpuacct/cpuacct.usage"

unknown_root="$tmp_dir/unknown"
mkdir -p "$unknown_root"

assert_eq "v2 layout is detected from cgroup.controllers" "v2" "$(resource_cgroup_version "$v2_root")"
assert_eq "v1 layout is detected from memory/memory.usage_in_bytes" "v1" "$(resource_cgroup_version "$v1_root")"
assert_eq "neither marker present reads unknown" "unknown" "$(resource_cgroup_version "$unknown_root")"

# --- memory / cpu reads, both layouts ---------------------------------------
assert_eq "v2 memory.current is read" "209715200" "$(resource_memory_current_bytes "$v2_root" v2)"
assert_eq "v1 memory.usage_in_bytes is read" "104857600" "$(resource_memory_current_bytes "$v1_root" v1)"
assert_eq "an unknown layout reads no memory, not a fabricated 0" "" "$(resource_memory_current_bytes "$unknown_root" unknown)"
assert_eq "v1 asked under v2's layout reads nothing (wrong file for that layout)" "" "$(resource_memory_current_bytes "$v1_root" v2)"

assert_eq "v2 cpu.stat's usage_usec is scaled to nanoseconds" "5000000000" "$(resource_cpu_usage_nanos "$v2_root" v2)"
assert_eq "v1 cpuacct.usage is already nanoseconds" "3000000000" "$(resource_cpu_usage_nanos "$v1_root" v1)"
assert_eq "an unknown layout reads no cpu usage" "" "$(resource_cpu_usage_nanos "$unknown_root" unknown)"

# --- /proc/net/dev reads -----------------------------------------------------
net_dev="$tmp_dir/net_dev"
cat > "$net_dev" <<'EOF'
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 5000       10    0    0    0     0          0         0     5000      10    0    0    0     0       0          0
  eth0: 1234567    123    0    0    0     0          0         0   654321      12    0    0    0     0       0          0
EOF
assert_eq "loopback is excluded, eth0's own rx/tx are read" \
  '{"rx":1234567,"tx":654321}' "$(resource_net_bytes "$net_dev")"

net_dev_multi="$tmp_dir/net_dev_multi"
cat > "$net_dev_multi" <<'EOF'
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 5000       10    0    0    0     0          0         0     5000      10    0    0    0     0       0          0
  eth0: 100    1    0    0    0     0          0         0   200      1    0    0    0     0       0          0
  eth1: 300    1    0    0    0     0          0         0   400      1    0    0    0     0       0          0
EOF
assert_eq "multiple non-loopback interfaces are summed" \
  '{"rx":400,"tx":600}' "$(resource_net_bytes "$net_dev_multi")"

assert_eq "a missing /proc/net/dev reads null, not a fabricated zero" \
  "null" "$(resource_net_bytes "$tmp_dir/does-not-exist")"

net_dev_only_lo="$tmp_dir/net_dev_only_lo"
cat > "$net_dev_only_lo" <<'EOF'
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 5000       10    0    0    0     0          0         0     5000      10    0    0    0     0       0          0
EOF
assert_eq "only loopback present reads null (nothing counted)" \
  "null" "$(resource_net_bytes "$net_dev_only_lo")"

# --- disk usage ---------------------------------------------------------------
disk_dir="$tmp_dir/disktest/sub"
mkdir -p "$disk_dir"
dd if=/dev/zero of="$disk_dir/f" bs=1024 count=10 2>/dev/null
assert_eq "du -sb's own total is read" "10240" "$(resource_disk_usage_bytes "$tmp_dir/disktest")"
assert_eq "a missing path reads empty, not a fabricated zero" "" "$(resource_disk_usage_bytes "$tmp_dir/no-such-dir")"

# --- delta / rate arithmetic --------------------------------------------------
assert_eq "cpu_cores: 2s of CPU time over 10s wall is 0.2 cores" \
  "0.2000" "$(resource_cpu_cores 1000000000 1000 3000000000 1010)"
assert_eq "cpu_cores: a smaller current value (container recreated) reads empty" \
  "" "$(resource_cpu_cores 5000000000 1000 1000000000 1010)"
assert_eq "cpu_cores: zero elapsed time reads empty (no division by zero)" \
  "" "$(resource_cpu_cores 1000000000 1000 3000000000 1000)"
assert_eq "cpu_cores: a non-numeric argument reads empty" \
  "" "$(resource_cpu_cores "" 1000 3000000000 1010)"
assert_eq "cpu_cores: an equal current value (no time passed with usage) reads 0 cores" \
  "0.0000" "$(resource_cpu_cores 1000000000 1000 1000000000 1010)"

assert_eq "rate_per_hour: 360000 bytes over 10s is 129600000 bytes/hour" \
  "129600000" "$(resource_rate_per_hour 1000000 1000 1360000 1010)"
assert_eq "rate_per_hour: a smaller current value (recreated) reads empty" \
  "" "$(resource_rate_per_hour 2000000 1000 1000000 1010)"

# --- resource_budget_report: derivation from a canned sample set ------------
samples="$(cat <<'EOF'
{"ts":"2026-09-15T00:00:00Z","service":"scheduler","cpu_cores":0.1,"memory_bytes":100000000,"net_rx_bytes_per_hour":1000,"net_tx_bytes_per_hour":500}
{"ts":"2026-09-15T01:00:00Z","service":"scheduler","cpu_cores":0.5,"memory_bytes":200000000,"net_rx_bytes_per_hour":2000,"net_tx_bytes_per_hour":900}
{"ts":"2026-09-15T02:00:00Z","service":"scheduler","cpu_cores":1.2,"memory_bytes":300000000,"net_rx_bytes_per_hour":3000,"net_tx_bytes_per_hour":1200}
this is not valid json
{"ts":"2026-09-15T00:00:00Z","volume":"workspace_root","disk_bytes":6000000000}
{"ts":"2026-09-15T02:00:00Z","volume":"workspace_root","disk_bytes":6200000000}
EOF
)"
report="$(resource_budget_report "$samples" "")"
assert_eq "malformed lines are skipped, not fatal — sample_count excludes it" \
  "5" "$(jq -r '.sample_count' <<<"$report")"
assert_eq "latest cpu_cores is the newest sample's own value" \
  "1.2" "$(jq -r '.containers.scheduler.cpu_cores.latest' <<<"$report")"
assert_eq "median cpu_cores is the nearest-rank middle value" \
  "0.5" "$(jq -r '.containers.scheduler.cpu_cores.median' <<<"$report")"
assert_eq "p95 memory_bytes is nearest-rank, not interpolated" \
  "200000000" "$(jq -r '.containers.scheduler.memory_bytes.p95' <<<"$report")"
assert_eq "disk latest is the newest disk sample" \
  "6200000000" "$(jq -r '.volumes.workspace_root.latest' <<<"$report")"
assert_eq "disk growth is a straight line between the window's oldest and newest sample" \
  "2400000000" "$(jq -r '.volumes.workspace_root.growth_bytes_per_day' <<<"$report")"

assert_eq "an empty input degrades to a valid, zeroed report" \
  '{"containers":{},"volumes":{},"sample_count":0,"window_start":null}' \
  "$(resource_budget_report "" "")"
assert_eq "an entirely-unparseable input degrades the same way" \
  '{"containers":{},"volumes":{},"sample_count":0,"window_start":null}' \
  "$(resource_budget_report "not json at all
also not json" "")"

# window_start filtering
windowed_samples="$(cat <<'EOF'
{"ts":"2026-09-15T00:00:00Z","service":"dashboard","cpu_cores":0.01,"memory_bytes":10000000}
{"ts":"2026-09-15T05:00:00Z","service":"dashboard","cpu_cores":0.02,"memory_bytes":20000000}
EOF
)"
windowed_report="$(resource_budget_report "$windowed_samples" "2026-09-15T04:00:00Z")"
assert_eq "window_start excludes samples before it" \
  "1" "$(jq -r '.sample_count' <<<"$windowed_report")"
assert_eq "…and the surviving sample is the newer one" \
  "0.02" "$(jq -r '.containers.dashboard.cpu_cores.latest' <<<"$windowed_report")"
assert_eq "window_start is echoed back" \
  "2026-09-15T04:00:00Z" "$(jq -r '.window_start' <<<"$windowed_report")"

# a resource never reported (e.g. bandwidth never sampled) reads null, not 0
bandwidth_absent="$(jq -r '.containers.scheduler.net_rx_bytes_per_hour.latest' <<<"$(resource_budget_report '{"ts":"2026-09-15T00:00:00Z","service":"scheduler","memory_bytes":1}' "")")"
assert_eq "a field no sample carries reads null" "null" "$bandwidth_absent"

# a disk sample series with only one point has no growth rate to report
one_disk_sample="$(resource_budget_report '{"ts":"2026-09-15T00:00:00Z","volume":"state_dir","disk_bytes":500}' "")"
assert_eq "a single disk sample has a latest but no growth rate" \
  "500 null" "$(jq -r '[.volumes.state_dir.latest, .volumes.state_dir.growth_bytes_per_day] | map(if . == null then "null" else tostring end) | join(" ")' <<<"$one_disk_sample")"

# --- resource_budget_breaches: the comparison doctor.sh and the dashboard
#     both make ----------------------------------------------------------------
breach_report='{"containers":{"scheduler":{"cpu_cores":{"latest":2.5,"median":2.0,"p95":2.5},"memory_bytes":{"latest":2000000000,"median":1900000000,"p95":2000000000},"net_rx_bytes_per_hour":{"latest":100,"median":100,"p95":100},"net_tx_bytes_per_hour":{"latest":50,"median":50,"p95":50}}},"volumes":{"workspace_root":{"latest":20000000000,"growth_bytes_per_day":5000}}}'
breach_budgets='{"containers":{"scheduler":{"cpu_cores":2.0,"memory_bytes":1610612736,"bandwidth_bytes_per_hour":2147483648}},"volumes":{"workspace_root":{"disk_bytes":10737418240}}}'
breaches="$(resource_budget_breaches "$breach_report" "$breach_budgets")"
assert_eq "cpu and memory both breach; bandwidth (well under) does not; disk breaches too" \
  "3" "$(jq -r 'length' <<<"$breaches")"
assert_eq "the cpu breach names the container, resource, actual and budget" \
  '{"scope":"container","name":"scheduler","resource":"cpu_cores","actual":2.5,"budget":2.0}' \
  "$(jq -c '.[] | select(.resource == "cpu_cores")' <<<"$breaches")"
assert_eq "the disk breach is scoped to the volume, compared on latest, never p95" \
  '{"scope":"volume","name":"workspace_root","resource":"disk_bytes","actual":20000000000,"budget":10737418240}' \
  "$(jq -c '.[] | select(.scope == "volume")' <<<"$breaches")"

at_line_report='{"containers":{"scheduler":{"cpu_cores":{"latest":2.0,"median":2.0,"p95":2.0}}},"volumes":{}}'
at_line_budgets='{"containers":{"scheduler":{"cpu_cores":2.0}}}'
assert_eq "exactly at the budget is not a breach (strictly greater than)" \
  "[]" "$(resource_budget_breaches "$at_line_report" "$at_line_budgets")"

under_line_report='{"containers":{"scheduler":{"cpu_cores":{"latest":1.9,"median":1.9,"p95":1.9}}},"volumes":{}}'
assert_eq "just under the budget is not a breach" \
  "[]" "$(resource_budget_breaches "$under_line_report" "$at_line_budgets")"

over_line_report='{"containers":{"scheduler":{"cpu_cores":{"latest":2.01,"median":2.01,"p95":2.01}}},"volumes":{}}'
assert_eq "just over the budget is a breach" \
  "1" "$(resource_budget_breaches "$over_line_report" "$at_line_budgets" | jq -r 'length')"

assert_eq "an unbudgeted container contributes no breach, however high its usage" \
  "[]" "$(resource_budget_breaches "$breach_report" '{"containers":{},"volumes":{}}')"
assert_eq "empty/malformed inputs degrade to an empty array, never null or an error" \
  "[]" "$(resource_budget_breaches "" "")"
assert_eq "…and the same for explicit JSON nulls" \
  "[]" "$(resource_budget_breaches "null" "null")"

echo
if (( failures == 0 )); then
  echo "All resource-usage assertions passed."
  exit 0
else
  echo "$failures resource-usage assertion(s) FAILED."
  exit 1
fi
