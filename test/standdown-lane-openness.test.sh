#!/usr/bin/env bash
# shellcheck disable=SC2034  # this file's fixtures are read by the spans it lifts out of lib/standdown.sh and runs through `eval`, which no static reader can follow — the same reason that file carries this directive itself
#
# test/standdown-lane-openness.test.sh — regression test for which lanes
# requirement 2.1's "every lane of it is frozen" actually counts (issue
# #2242, lib/standdown.sh).
#
# A lane whose credential is absent on this node, or which the provider's own
# `lanes` config closes, is no fallthrough for a frozen sibling's stages:
# `stage_lane_draw` will not draw it either. So a provider whose *only* open
# lane freezes has no open lane left and must stand down, exactly as it did
# before this issue scoped the record to a lane. Reading a closed or absent
# sibling as merely "not frozen" instead would skip the gate entirely — no
# `externally-blocked usage-limit` node state, no 2.1b probe to retire an
# estimated resume early, no requirement 2 freeze escalation — and leave
# every launch to be refused by `run_model_stage`'s own `no-open-lane` path,
# which names config.json rather than the live limit that actually caused it.
#
# That is the common shape rather than an edge case: `lane_effective_open`'s
# own default (`enabled` unset — every provider whose config.json names no
# `lanes` block) opens `subscription` only when `api` is *absent*, so an
# unconfigured provider has exactly one open lane even with both credentials
# on the node.
#
# Both the openness predicate (`limit_lane_configured_open`) and the gate's
# own lending block are lifted verbatim out of lib/standdown.sh, so this test
# is about the shipped code rather than a copy of its logic — the same
# technique test/standdown-limit-probe.test.sh and its siblings use.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/standdown-lane-openness.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STANDDOWN="$SCRIPT_DIR/lib/standdown.sh"

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

# `lane_effective_open` itself, the one open/closed rule the draw and
# `--status` share (requirement 34a) — sourced real, never stubbed, since
# "the gate agrees with the draw" is the whole point of the predicate below
# delegating to it.
# shellcheck source=lib/lane.sh
. "$SCRIPT_DIR/lib/lane.sh"

declare -gA PROVIDER_SUBSTRATE=()
declare -gA PROVIDER_LANES=()
STAGE_LANE_DEFAULT_JSON='{"api":{"weight":1,"enabled":null},"subscription":{"weight":0,"enabled":null}}'

predicate_src="$(awk '
  /^limit_lane_configured_open\(\) \{$/ { on = 1 }
  on                                    { print }
  on && /^\}$/                          { exit }
' "$STANDDOWN")"
# shellcheck disable=SC2016  # a literal source fragment to match, not an expansion
if [[ "$predicate_src" != *'lane_effective_open "$lanes_json"'* ]]; then
  echo "FAIL - could not extract limit_lane_configured_open from lib/standdown.sh (moved or reworded?)" >&2
  exit 1
fi
eval "$predicate_src"

gate_src="$(awk '
  /^if \(\( limit_frozen_api \)\) && ! \(\( limit_frozen_sub \)\) \\$/ { on = 1 }
  on                                                                   { print }
  on && /^fi$/                                                         { exit }
' "$STANDDOWN")"
# shellcheck disable=SC2016  # literal source fragments to match, not expansions
if [[ "$gate_src" != *'limit_lane_configured_open'* ]] || [[ "$gate_src" != *'governing_sub="$governing_api"'* ]]; then
  echo "FAIL - could not extract the unopen-sibling lending block from lib/standdown.sh (moved or reworded?)" >&2
  exit 1
fi

# Stands in for lib/substrate-claude-code.sh's own credential probe: this
# test is about which lanes the gate counts, not about how presence is
# detected.
# Named `stub_*`, deliberately: `limit_lane_configured_open` declares its own
# `present_api`/`present_sub` locals, and bash's dynamic scoping would hand
# those — not this harness's — to a stub reading the bare names.
stub_api_present=0
stub_sub_present=0
# shellcheck disable=SC2317,SC2329  # called from $predicate_src via eval, invisible to a static reader
substrate_claude_code_lane_present() {
  case "$1" in
    api) (( stub_api_present )) ;;
    subscription) (( stub_sub_present )) ;;
    *) return 1 ;;
  esac
}

# Every one of these is read, and most of them written, by the eval'd block
# rather than by anything a static reader can see.
# shellcheck disable=SC2034
{
  check_provider=anthropic
  limit_frozen_api=0; limit_frozen_sub=0
  governing_api='{}'; governing_sub='{}'
  resume_at_api=''; resume_at_sub=''
  union_state_api=''; union_state_sub=''
}

# gate_outcome
# Which of the three outcomes the gate immediately below the lending block in
# lib/standdown.sh would reach, given the variables as the block left them:
# the combined (single-record) stand-down, the split-lane stand-down, or no
# stand-down at all. The combined verdict names the record and the `since` it
# would carry forward, since lending in the wrong direction is the mistake
# that would otherwise stand a provider down on `{}` with no resume at all.
gate_outcome() {
  if (( limit_frozen_api && limit_frozen_sub )) && [[ "$governing_api" == "$governing_sub" ]]; then
    printf 'combined %s %s' "$governing_api" "$union_state_api"
  elif (( limit_frozen_api && limit_frozen_sub )); then
    printf 'split'
  else
    printf 'none'
  fi
}

# run_gate <present_api> <present_sub> <lanes_json> <frozen_api> <frozen_sub>
#          [<provider>]
# Runs the extracted lending block over the pair of per-lane verdicts
# lib/standdown.sh has already computed by that point, with each frozen lane
# carrying its own distinct record, and prints `gate_outcome`.
run_gate() {
  check_provider="${6:-anthropic}"
  stub_api_present="$1"; stub_sub_present="$2"
  PROVIDER_LANES["$check_provider"]="$3"
  limit_frozen_api="$4"; limit_frozen_sub="$5"
  governing_api='{}'; governing_sub='{}'
  resume_at_api=''; resume_at_sub=''
  union_state_api='api-since'; union_state_sub='sub-since'
  (( limit_frozen_api )) && { governing_api='{"lane":"api"}'; resume_at_api='2099-01-01T00:00:00Z'; }
  (( limit_frozen_sub )) && { governing_sub='{"lane":"subscription"}'; resume_at_sub='2099-02-01T00:00:00Z'; }
  eval "$gate_src"
  gate_outcome
}

# run_gate_one_record <provider> <present_api> <present_sub> <frozen_api>
# As run_gate, but with both lanes resolving to one identical record — every
# pre-#2242 hit, which names no lane at all — so the lending block's own
# guard (the other lane not being frozen) is the only thing under test.
run_gate_one_record() {
  check_provider="$1"
  stub_api_present="$2"; stub_sub_present="$3"
  PROVIDER_LANES["$check_provider"]="$default_lanes"
  limit_frozen_api="$4"; limit_frozen_sub="$4"
  governing_api='{"resume_at":"2099-01-01T00:00:00Z"}'; governing_sub="$governing_api"
  resume_at_api='2099-01-01T00:00:00Z'; resume_at_sub="$resume_at_api"
  union_state_api='one-since'; union_state_sub='one-since'
  eval "$gate_src"
  gate_outcome
}

default_lanes="$STAGE_LANE_DEFAULT_JSON"
# This repository's own config.json: `api` left to the default rule, and
# `subscription` opened explicitly — the configuration that genuinely runs a
# two-lane split, and the only one that should ever reach the split path.
split_lanes='{"api":{"weight":0},"subscription":{"weight":1,"enabled":true}}'

# --- The regression itself: one open lane, and it is the frozen one -------

assert_eq "an api freeze stands the provider down when subscription is closed by the default rule" \
  'combined {"lane":"api"} api-since' "$(run_gate 1 1 "$default_lanes" 1 0)"
assert_eq "…and when the subscription credential is simply not on this node" \
  'combined {"lane":"api"} api-since' "$(run_gate 1 0 "$default_lanes" 1 0)"
assert_eq "a subscription freeze stands it down when the api credential is not on this node" \
  'combined {"lane":"subscription"} sub-since' "$(run_gate 0 1 "$split_lanes" 0 1)"
assert_eq "…and when api is closed outright by config" \
  'combined {"lane":"subscription"} sub-since' \
  "$(run_gate 1 1 '{"api":{"enabled":false},"subscription":{"enabled":true}}' 0 1)"

# The lent record is the frozen lane's own, never the empty sibling's: the
# combined path reads `governing_api`/`resume_at_api`/`union_state_api` for
# its reason line, its probe and its escalation age, so lending in the wrong
# direction would stand the provider down on `{}` with no resume at all.
run_gate 0 1 "$split_lanes" 0 1 >/dev/null
assert_eq "…carrying the frozen lane's own resume onto the lane that had none" \
  "2099-02-01T00:00:00Z" "$resume_at_api"

# --- What must not change --------------------------------------------------

assert_eq "a freeze on one lane beside an open, unfrozen sibling still stands nothing down" \
  'none' "$(run_gate 1 1 "$split_lanes" 1 0)"
assert_eq "…in the other direction too" \
  'none' "$(run_gate 1 1 "$split_lanes" 0 1)"
assert_eq "both lanes genuinely frozen under their own records still takes the split path" \
  'split' "$(run_gate 1 1 "$split_lanes" 1 1)"
assert_eq "no lane frozen at all stands nothing down, whatever is open" \
  'none' "$(run_gate 1 0 "$default_lanes" 0 0)"

# Two lanes shut by configuration alone is the pre-existing `no-open-lane`
# case and owes no usage-limit stand-down: the lending block only ever fires
# beside a lane that is genuinely frozen.
assert_eq "both lanes closed by config, nothing frozen, invents no stand-down" \
  'none' "$(run_gate 1 1 '{"api":{"enabled":false},"subscription":{"enabled":false}}' 0 0)"

# --- Where lane management is not running at all ---------------------------
# Each of these is a provider whose hits name no lane, so both lanes resolve
# to the same lane-wildcard bucket and arrive here already frozen together —
# the lending block's own guard never fires, and the combined path handles
# the single record exactly as it did before this issue.

PROVIDER_SUBSTRATE[xai]=grok-build
assert_eq "a substrate declaring no lane_present reads both lanes as open, so nothing is lent" \
  'none' "$(run_gate 0 0 "$default_lanes" 1 0 xai)"
assert_eq "…and neither credential present on a managed substrate reads the same way" \
  'none' "$(run_gate 0 0 "$default_lanes" 1 0)"
assert_eq "one identical record freezing both lanes alike still reaches the combined path" \
  'combined {"resume_at":"2099-01-01T00:00:00Z"} one-since' \
  "$(run_gate_one_record anthropic 1 1 1)"
assert_eq "…and does so for a substrate with no lanes at all" \
  'combined {"resume_at":"2099-01-01T00:00:00Z"} one-since' \
  "$(run_gate_one_record xai 0 0 1)"

if (( failures > 0 )); then
  printf '\n%s assertion(s) failed\n' "$failures"
  exit 1
fi
printf '\nAll assertions passed\n'
