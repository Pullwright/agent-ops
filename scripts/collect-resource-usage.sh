#!/usr/bin/env bash
#
# collect-resource-usage.sh — one sample of this container's own CPU,
# memory and network counters, appended to the node's local resource-usage
# log, plus a throttled disk sample of the volumes this container can see
# (D14, issue #606). Meant to run every few minutes from a container's own
# schedule — `deploy/docker/crontab.tmpl`'s `@RESOURCE_SAMPLE_MINUTES@` line
# for the `scheduler` service (supercronic), and a small background loop
# `scripts/serve-dashboard.sh` starts for `dashboard`/`dashboard-local`,
# which run no cron at all.
#
# Reads `AGENT_OPS_SERVICE` (the same environment variable
# `lib/updater-health.sh` already keys its own ledger on) to know which
# container it is running in when `--service` is not given; every sample
# and every disk reading is tagged with that name, which is also the key
# `config.json`'s `resources.containers`/`resources.volumes` budgets are
# read back under (`scripts/doctor.sh`, `scripts/publish-dashboard.sh`).
#
# The local log (`state_dir/.resource-samples.jsonl`) and the small
# last-cumulative-reading cache (`state_dir/.resource-usage-state.json`)
# are both excluded from state-sync's replication (`scripts/state-sync.sh`'s
# `EXCLUDES`) — raw samples are this node's own forensics, never a fact a
# peer would read; only the derived report (`scripts/resource-budget-
# report.sh`) folds into the heartbeat.
#
# `state_dir` is a volume `scheduler` and `dashboard`/`dashboard-local`
# mount in common, so both files are shared between whichever of those
# containers a node runs — guarded with `flock` (the same ledger-append
# idiom `lib/gh-shim.sh` already uses) so two containers ticking at once
# never tear each other's write.
#
# Exit status is always 0: a collector tick that cannot read a counter
# writes nothing for it (never a fabricated `0`) and this script must never
# be the reason a cron line, or the background loop, stops.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/config-schema.sh
. "$SCRIPT_DIR/lib/config-schema.sh"
# shellcheck source=lib/resource-usage.sh
. "$SCRIPT_DIR/lib/resource-usage.sh"

CONFIG_FILE="$SCRIPT_DIR/config.json"
SCHEMA_FILE="$SCRIPT_DIR/config.schema.json"
service="${AGENT_OPS_SERVICE:-}"
state_dir_override=""
cgroup_root="${RESOURCE_CGROUP_ROOT:-/sys/fs/cgroup}"
net_dev_file="${RESOURCE_NET_DEV_FILE:-/proc/net/dev}"
now_override=""
prune_override=""

usage() {
  cat <<'EOF'
usage: collect-resource-usage.sh [--config FILE] [--service NAME]
                                  [--state-dir DIR] [--cgroup-root DIR]
                                  [--net-dev-file FILE] [--now ISO8601]
                                  [--no-prune]

One sample tick: this container's own CPU/memory/network counters, appended
to <state_dir>/.resource-samples.jsonl, plus a disk sample of
workspace_root/state_dir throttled to
resources.disk_sample_interval_minutes. --service defaults to
$AGENT_OPS_SERVICE. --now fixes "now" for a reproducible test run.
--no-prune skips the retention-window rewrite (a peer container's tick
still prunes on its own schedule).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_FILE="$2"; shift 2 ;;
    --service) service="$2"; shift 2 ;;
    --state-dir) state_dir_override="$2"; shift 2 ;;
    --cgroup-root) cgroup_root="$2"; shift 2 ;;
    --net-dev-file) net_dev_file="$2"; shift 2 ;;
    --now) now_override="$2"; shift 2 ;;
    --no-prune) prune_override="no"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
done

if [[ -z "$service" ]]; then
  echo "collect-resource-usage: no --service given and AGENT_OPS_SERVICE is unset; nothing to tag this sample with" >&2
  exit 0
fi

[[ -f "$CONFIG_FILE" ]] || { echo "collect-resource-usage: config file not found: $CONFIG_FILE" >&2; exit 0; }
DEFAULTED_CONFIG="$(config_defaults "$CONFIG_FILE" "$SCHEMA_FILE")" || {
  echo "collect-resource-usage: could not read $CONFIG_FILE against $SCHEMA_FILE" >&2
  exit 0
}

expand_home() {
  local p="$1"
  [[ "$p" == "~"* ]] && p="$HOME${p:1}"
  printf '%s\n' "$p"
}

if [[ -n "$state_dir_override" ]]; then
  state_dir="$state_dir_override"
else
  state_dir="$(expand_home "$(jq -r '.state_dir' <<<"$DEFAULTED_CONFIG")")"
fi
mkdir -p "$state_dir"

retention_hours="$(jq -r '.resources.sample_retention_hours // 48' <<<"$DEFAULTED_CONFIG")"
[[ "$retention_hours" =~ ^[0-9]+$ ]] || retention_hours=48
disk_interval_minutes="$(jq -r '.resources.disk_sample_interval_minutes // 60' <<<"$DEFAULTED_CONFIG")"
[[ "$disk_interval_minutes" =~ ^[0-9]+$ ]] || disk_interval_minutes=60

samples_file="$state_dir/.resource-samples.jsonl"
usage_state_file="$state_dir/.resource-usage-state.json"
lock_file="$state_dir/.resource-usage.lock"
touch "$samples_file"
# An empty file, not `{}`, is what a bare `touch` (or a `mv` racing this
# script's own rewrite below) leaves behind — and `jq` given empty input
# with no `-n` runs its filter zero times, producing no output at all
# rather than an error. A caller that then `mv`s that empty output over
# this file would silently wipe every service's cached baseline instead of
# updating one; seeding real JSON here, and never leaving the file empty
# below, is what keeps every read past this point able to assume valid
# JSON is there to read.
[[ -s "$usage_state_file" ]] || printf '{}' > "$usage_state_file"

if [[ -n "$now_override" ]]; then
  now_iso="$now_override"
else
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
fi
now_ts="$(jq -nr --arg t "$now_iso" '$t | fromdateiso8601' 2>/dev/null)"
[[ "$now_ts" =~ ^[0-9]+$ ]] || { echo "collect-resource-usage: could not parse --now as ISO 8601: $now_iso" >&2; exit 0; }

version="$(resource_cgroup_version "$cgroup_root")"
mem_bytes="$(resource_memory_current_bytes "$cgroup_root" "$version")"
cpu_nanos="$(resource_cpu_usage_nanos "$cgroup_root" "$version")"
net_json="$(resource_net_bytes "$net_dev_file")"
net_rx="$(jq -r 'if . == null then "" else .rx end' <<<"$net_json")"
net_tx="$(jq -r 'if . == null then "" else .tx end' <<<"$net_json")"

# --- read this service's previous cumulative reading, compute this tick's
#     sample, append it, and cache the new cumulative reading — all under
#     one lock so a peer container sharing state_dir never tears either
#     file's write. -----------------------------------------------------
(
  flock -w 5 200 || exit 0

  prev="$(jq -c --arg s "$service" '.[$s] // {}' "$usage_state_file" 2>/dev/null || printf '{}')"
  prev_cpu_nanos="$(jq -r '.cpu_nanos // empty' <<<"$prev")"
  prev_ts="$(jq -r '.ts // empty' <<<"$prev")"
  prev_rx="$(jq -r '.net_rx // empty' <<<"$prev")"
  prev_tx="$(jq -r '.net_tx // empty' <<<"$prev")"

  cpu_cores=""
  [[ -n "$cpu_nanos" ]] && cpu_cores="$(resource_cpu_cores "$prev_cpu_nanos" "$prev_ts" "$cpu_nanos" "$now_ts")"
  net_rx_rate=""
  [[ -n "$net_rx" ]] && net_rx_rate="$(resource_rate_per_hour "$prev_rx" "$prev_ts" "$net_rx" "$now_ts")"
  net_tx_rate=""
  [[ -n "$net_tx" ]] && net_tx_rate="$(resource_rate_per_hour "$prev_tx" "$prev_ts" "$net_tx" "$now_ts")"

  jq -nc \
    --arg ts "$now_iso" --arg service "$service" \
    --arg mem "$mem_bytes" --arg cpu "$cpu_cores" \
    --arg rx "$net_rx_rate" --arg tx "$net_tx_rate" \
    '{ts: $ts, service: $service} +
     (if $mem == "" then {} else {memory_bytes: ($mem | tonumber)} end) +
     (if $cpu == "" then {} else {cpu_cores: ($cpu | tonumber)} end) +
     (if $rx == "" then {} else {net_rx_bytes_per_hour: ($rx | tonumber)} end) +
     (if $tx == "" then {} else {net_tx_bytes_per_hour: ($tx | tonumber)} end)' \
    >> "$samples_file"

  new_entry="$(jq -nc \
    --arg cpu "$cpu_nanos" --arg ts "$now_ts" --arg rx "$net_rx" --arg tx "$net_tx" \
    '{} +
     (if $cpu == "" then {} else {cpu_nanos: ($cpu | tonumber)} end) +
     {ts: ($ts | tonumber)} +
     (if $rx == "" then {} else {net_rx: ($rx | tonumber)} end) +
     (if $tx == "" then {} else {net_tx: ($tx | tonumber)} end)')"
  tmp_state="$(mktemp "$state_dir/.resource-usage-state.json.XXXXXX")"
  jq -c --arg s "$service" --argjson e "$new_entry" '.[$s] = ((.[$s] // {}) + $e)' \
    "$usage_state_file" > "$tmp_state" 2>/dev/null
  # Never install an empty rewrite: jq given genuinely empty input runs its
  # filter zero times rather than erroring, which would otherwise `mv` a
  # zero-byte file over every other service's own cached baseline (see the
  # header comment above touch/-s guard for the read side of this).
  if [[ -s "$tmp_state" ]]; then mv "$tmp_state" "$usage_state_file"; else rm -f "$tmp_state"; fi

  # --- disk: throttled to disk_sample_interval_minutes, and only for a
  #     volume this container actually has mounted. Read/write the marker
  #     from the same locked state file, under the same lock, so two
  #     containers cannot both fire in the same window. ------------------
  last_disk_ts="$(jq -r '.disk.last_sample_ts // empty' "$usage_state_file" 2>/dev/null)"
  due=1
  if [[ "$last_disk_ts" =~ ^[0-9]+$ ]]; then
    elapsed=$(( now_ts - last_disk_ts ))
    (( elapsed >= disk_interval_minutes * 60 )) || due=0
  fi
  if (( due )); then
    workspace_root="$(expand_home "$(jq -r '.workspace_root' <<<"$DEFAULTED_CONFIG")")"
    state_dir_path="$state_dir"
    for pair in "workspace_root:$workspace_root" "state_dir:$state_dir_path"; do
      vol_name="${pair%%:*}"; vol_path="${pair#*:}"
      [[ -d "$vol_path" ]] || continue
      disk_bytes="$(resource_disk_usage_bytes "$vol_path")"
      [[ -n "$disk_bytes" ]] || continue
      jq -nc --arg ts "$now_iso" --arg vol "$vol_name" --argjson bytes "$disk_bytes" \
        '{ts: $ts, volume: $vol, disk_bytes: $bytes}' >> "$samples_file"
    done
    tmp_state="$(mktemp "$state_dir/.resource-usage-state.json.XXXXXX")"
    jq -c --arg ts "$now_ts" '.disk = {last_sample_ts: ($ts | tonumber)}' \
      "$usage_state_file" > "$tmp_state" 2>/dev/null
    if [[ -s "$tmp_state" ]]; then mv "$tmp_state" "$usage_state_file"; else rm -f "$tmp_state"; fi
  fi

  # --- prune: drop anything older than the retention window, so the log a
  #     node keeps forever (it is never rotated the way log.jsonl is not
  #     either) stays bounded at a few hundred KB rather than growing
  #     without one. Skipped when another tick on this node just pruned —
  #     --no-prune lets a caller that knows a peer already did avoid the
  #     redundant full-file rewrite, though correctness does not depend on
  #     it: an un-pruned file just stays a little larger until the next
  #     tick that does prune it. ------------------------------------------
  if [[ "$prune_override" != "no" ]]; then
    cutoff_iso="$(jq -nr --argjson secs "$(( retention_hours * 3600 ))" --argjson now "$now_ts" \
      '($now - $secs) | todateiso8601')"
    tmp_samples="$(mktemp "$state_dir/.resource-samples.jsonl.XXXXXX")"
    if jq -Rrc --arg cutoff "$cutoff_iso" '
      (try fromjson catch empty) as $e
      | select($e != null and ($e | type) == "object" and (($e.ts? // "") >= $cutoff))
      | $e
    ' "$samples_file" > "$tmp_samples" 2>/dev/null; then
      mv "$tmp_samples" "$samples_file"
    else
      rm -f "$tmp_samples"
    fi
  fi
) 200>"$lock_file"

exit 0
