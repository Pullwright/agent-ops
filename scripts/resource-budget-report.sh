#!/usr/bin/env bash
#
# resource-budget-report.sh — read this node's own local resource-usage log
# and print the compact per-container/per-volume report (D14, issue #606):
# `{latest, median, p95}` of `cpu_cores`/`memory_bytes`/
# `net_rx_bytes_per_hour`/`net_tx_bytes_per_hour` per container, `{latest,
# growth_bytes_per_day}` of `disk_bytes` per volume. The derivation itself
# is `lib/resource-usage.sh`'s `resource_budget_report`, a pure function
# over the sample text — this script is the thin I/O wrapper around it
# (config, state_dir, the window) `scripts/publish-revert-rate.sh` and its
# siblings already establish the shape for.
#
# Read by `scripts/state-sync.sh` (folded into `heartbeat.json`'s
# `resources` field, a summary never a series) and by `scripts/doctor.sh`
# (compared against `config.json`'s `resources.containers`/
# `resources.volumes` budgets, a breach warned about by name). Never writes
# anything itself — `scripts/collect-resource-usage.sh` is the one script
# that appends to the log this reads.
#
# Exit status is always 0: an empty or missing log is a clean, zeroed
# report (`resource_budget_report`'s own degradation), never a failure —
# the same "no samples yet" posture `scripts/doctor.sh`'s own host-budget
# section already takes on a host-facts record that has not been written
# yet.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/config-schema.sh
. "$SCRIPT_DIR/lib/config-schema.sh"
# shellcheck source=lib/resource-usage.sh
. "$SCRIPT_DIR/lib/resource-usage.sh"

CONFIG_FILE="$SCRIPT_DIR/config.json"
SCHEMA_FILE="$SCRIPT_DIR/config.schema.json"
state_dir_override=""
now_override=""
window_hours_override=""

usage() {
  cat <<'EOF'
usage: resource-budget-report.sh [--config FILE] [--state-dir DIR]
                                  [--now ISO8601] [--window-hours N]

Prints the per-container/per-volume resource report derived from
<state_dir>/.resource-samples.jsonl over resources.report_window_hours
(default 24). --now fixes "now" for a reproducible test run; --window-hours
overrides the configured window.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift 2 ;;
    --state-dir) state_dir_override="$2"; shift 2 ;;
    --now) now_override="$2"; shift 2 ;;
    --window-hours) window_hours_override="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done

expand_home() {
  local p="$1"
  [[ "$p" == "~"* ]] && p="$HOME${p:1}"
  printf '%s\n' "$p"
}

if [[ -f "$CONFIG_FILE" ]]; then
  DEFAULTED_CONFIG="$(config_defaults "$CONFIG_FILE" "$SCHEMA_FILE" 2>/dev/null || printf '{}')"
else
  DEFAULTED_CONFIG='{}'
fi

if [[ -n "$state_dir_override" ]]; then
  state_dir="$state_dir_override"
else
  state_dir="$(expand_home "$(jq -r '.state_dir // empty' <<<"$DEFAULTED_CONFIG")")"
fi

if [[ -n "$window_hours_override" ]]; then
  window_hours="$window_hours_override"
else
  window_hours="$(jq -r '.resources.report_window_hours // 24' <<<"$DEFAULTED_CONFIG")"
fi
[[ "$window_hours" =~ ^[0-9]+$ ]] || window_hours=24

if [[ -n "$now_override" ]]; then
  now_iso="$now_override"
else
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi
now_ts="$(jq -nr --arg t "$now_iso" '$t | fromdateiso8601' 2>/dev/null)"
window_start=""
if [[ "$now_ts" =~ ^[0-9]+$ ]]; then
  window_start="$(jq -nr --argjson secs "$(( window_hours * 3600 ))" --argjson now "$now_ts" \
    '($now - $secs) | todateiso8601' 2>/dev/null)"
fi

samples_file="${state_dir:+$state_dir/.resource-samples.jsonl}"
samples=""
if [[ -n "$samples_file" && -r "$samples_file" ]]; then
  samples="$(cat "$samples_file")"
fi

resource_budget_report "$samples" "$window_start"
