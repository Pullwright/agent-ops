#!/usr/bin/env bash
#
# scripts/constraint.sh — print the constraint statement (D21 of
# docs/ROADMAP.md's "state the constraint" bullet, issue #609): one sentence
# naming what is limiting this installation's throughput right now, over
# what share of the window, and what to do about it — computed from the node
# time-state account (`scripts/node-time-state.sh`, issue #597), never
# asserted. `lib/constraint.sh`'s `constraint_classify` is the pure
# derivation this script only wires to the fleet's own logs, the same
# division `scripts/node-time-state.sh` already keeps against
# `lib/node-time-state.sh`.
#
# Reads the union of both pipelines' logs — log.jsonl (agent-cycle.sh) and
# review-log.jsonl (review-cycle.sh) — for the identical reason
# scripts/node-time-state.sh does: both emit node-state transitions, and a
# node can run either (or briefly both) at once.
#
# Read-only throughout: it opens nothing but the two union logs
# (lib/fleet.sh's fleet_logs, called once per basename) and this
# repository's own config.json (never a target repo's), and prints a JSON
# object to stdout. Never touches the lock, writes no event, makes no
# network call, and is safe to run against a live node at any time — the
# same contract scripts/node-time-state.sh and scripts/pickup-metrics.sh
# already keep.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"
SCHEMA_FILE="$SCRIPT_DIR/config.schema.json"

# shellcheck source=lib/config-schema.sh
. "$SCRIPT_DIR/lib/config-schema.sh"
# shellcheck source=lib/fleet.sh
. "$SCRIPT_DIR/lib/fleet.sh"
# shellcheck source=lib/node-time-state.sh
. "$SCRIPT_DIR/lib/node-time-state.sh"
# shellcheck source=lib/constraint.sh
. "$SCRIPT_DIR/lib/constraint.sh"

usage() {
  cat <<'EOF'
usage: constraint.sh [--since <iso8601>] [--until <iso8601>] [--state-dir <dir>] [--peers-dir <dir>]

Read-only. Prints the constraint statement as JSON on stdout — see
lib/constraint.sh's own header for the full field-by-field contract:

  - `sentence`: the one leading line, always present. Names the binding
    constraint, its share of the window, and the recommended change; or
    states "insufficient evidence" and why, naming the missing or
    too-thin record rather than guessing.
  - `status`/`insufficient_reason`: "ok", or "insufficient-evidence" with
    one of "no-time-account-data", "window-below-minimum-sample",
    "no-candidate-above-minimum-share".
  - `candidates`: all six named candidates (cron latency, the
    back-pressure cap, node count, model capacity, the human merge gate,
    the pipeline's own defect rate), fixed order — the last two are never
    evaluable from this account alone (#574, #596) and always report why.
  - `window`, `nodes`, `expected_total_seconds`: the node time-state
    account this was computed from (scripts/node-time-state.sh, #597).
  - `min_share`, `min_sample_seconds`: this repository's own
    constraint_min_share/constraint_min_sample_seconds (config.json),
    echoed back so a reader can see what gated the verdict.
  - `cadence_bound_minutes`: this repository's own
    schedule.cycle_interval_minutes — purely informational, the same
    resolution floor scripts/pickup-metrics.sh states beside its own
    figures; never gates anything here.

  --since       only fold node-state events at or after this ISO-8601
                timestamp (default: the whole log).
  --until       only fold node-state events at or before this ISO-8601
                timestamp (default: the whole log).
  --state-dir   this node's own log directory (default: config.json's
                state_dir)
  --peers-dir   the peers directory fleet_logs reads (default:
                fleet_peers_dir over config.json's workspace_root)

Needs no network access and changes nothing.
EOF
}

since=""
until_ts=""
state_dir_override=""
peers_dir_override=""

while (( $# > 0 )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --since) since="${2:-}"; shift 2 ;;
    --until) until_ts="${2:-}"; shift 2 ;;
    --state-dir) state_dir_override="${2:-}"; shift 2 ;;
    --peers-dir) peers_dir_override="${2:-}"; shift 2 ;;
    *) echo "constraint: unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

expand_home() {
  local p="$1"
  [[ "$p" == "~"* ]] && p="$HOME${p:1}"
  printf '%s\n' "$p"
}

DEFAULTED_CONFIG="$(config_defaults "$CONFIG_FILE" "$SCHEMA_FILE" 2>/dev/null)" || {
  echo "constraint: could not read $CONFIG_FILE against $SCHEMA_FILE" >&2
  exit 2
}
cfg() { jq -r "$1" <<<"$DEFAULTED_CONFIG"; }

if [[ -n "$state_dir_override" ]]; then
  state_dir="$state_dir_override"
else
  state_dir="$(expand_home "$(cfg '.state_dir')")"
fi

if [[ -n "$peers_dir_override" ]]; then
  peers_dir="$peers_dir_override"
else
  peers_dir="$(fleet_peers_dir "$(expand_home "$(cfg '.workspace_root')")")"
fi

min_share="$(cfg '.constraint_min_share')"
[[ "$min_share" =~ ^[0-9.]+$ ]] || min_share=0.3
min_sample_seconds="$(cfg '.constraint_min_sample_seconds')"
[[ "$min_sample_seconds" =~ ^[0-9]+$ ]] || min_sample_seconds=14400
cadence_bound_minutes="$(cfg '.schedule.cycle_interval_minutes')"
[[ "$cadence_bound_minutes" =~ ^[0-9]+$ ]] || cadence_bound_minutes=null

account_json="$(
  {
    fleet_logs "$state_dir" "$peers_dir" log.jsonl
    fleet_logs "$state_dir" "$peers_dir" review-log.jsonl
  } | node_time_state_fold - "$since" "$until_ts"
)"

constraint_classify "$account_json" "$min_share" "$min_sample_seconds" "$cadence_bound_minutes"
