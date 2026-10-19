#!/usr/bin/env bash
#
# lib/lane.sh — lane_effective_open: the one open/closed rule D4/D30 define
# for a credit-mix lane, shared by `stage_lane_draw` (lib/stage-run.sh, issue
# #2241) and `lib/mix.sh`'s own status report (issue #2244), so the
# launcher's actual draw and what an operator is told is open can never
# drift apart from one another (requirement 34a) — two readings of the same
# lanes object that disagreed would mean `--status` describing a lane as
# closed that the next launch draws from, or the reverse.
#
# A standalone file, not folded into either caller, because neither may
# assume the other has already been sourced in this process:
# `lib/stage-run.sh` self-sources this exactly as it already self-sources
# `lib/substrate-claude-code.sh`/`lib/substrate-grok-build.sh` (so a caller
# that sources only lib/stage-run.sh — every test in test/stage-run.test.sh
# that predates model-id.sh being loaded included — still resolves a draw),
# and `lib/mix.sh` self-sources it too (so `scripts/node-health.sh`, which
# stays free of lib/stage-run.sh's heavier dependencies by design, still
# resolves a lane's state for its own `--metrics` field).

set -uo pipefail

# lane_effective_open LANES_JSON LANE PRESENT_API PRESENT_SUBSCRIPTION
# True (exit 0) iff LANE ("api" or "subscription") is open under D4/D30's
# rule: present, and either explicitly `enabled: true` in LANES_JSON, or
# `enabled` unset/null and LANE is the one the CLI would use unaided — `api`
# whenever it is present, `subscription` only when it is present and `api` is
# not. `enabled: false` always closes it outright, present or not.
lane_effective_open() {
  local lanes_json="$1" lane="$2" present_api="${3:-0}" present_sub="${4:-0}" enabled present
  enabled="$(jq -r --arg l "$lane" '.[$l].enabled' <<<"$lanes_json" 2>/dev/null)"
  case "$lane" in
    api) present="$present_api" ;;
    subscription) present="$present_sub" ;;
    *) return 1 ;;
  esac
  case "$enabled" in
    true) (( present )) ;;
    false) return 1 ;;
    *)
      case "$lane" in
        api) (( present )) ;;
        subscription) (( present_sub && ! present_api )) ;;
      esac
      ;;
  esac
}
