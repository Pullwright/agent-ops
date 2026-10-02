#!/usr/bin/env bash
#
# test/roll-standdown-wiring.test.sh — regression test for the post-
# `acquire_lock` roll-pending block in agent-cycle.sh (requirement 39c
# amendment, agent-ops#1102 option 2): the other half of #1096/#1100/#1102's
# own marker handling, closing the one case `chain_clear_landed_roll_pending`
# deliberately leaves open — a cycle that reacquires `lock.json` under a
# marker whose verdict still reads "behind" now idles instead of running its
# stages underneath the marker's own unconditional override, but only when
# watchtower is actually polling and being turned away, and never more than
# once per pending roll.
#
# The block under test is lifted verbatim out of agent-cycle.sh — from the
# pre-existing "shed a landed marker" `if`, which test/chain.test.sh already
# covers in isolation but agent-cycle.sh itself never had a wiring test for,
# through the new stand-down `if` this item adds — the same way test/
# finish-then-continue.test.sh lifts the chain-spawn block beside it.
# `lib/chain.sh` is sourced for real (its own functions are unit-tested in
# test/chain.test.sh; this file checks that agent-cycle.sh calls them
# correctly, not that they are themselves correct). `image_drift_status`,
# `agent_ops_version`, `cfg` and `updater_status` are stubbed — the first two
# on the same terms test/finish-then-continue.test.sh already stubs them,
# the last two to drive deterministic verdicts without a real config or a
# real updater-ledger (both already covered by test/config-schema.test.sh and
# test/updater-health.test.sh respectively).
#
# Run directly: ./test/roll-standdown-wiring.test.sh — exit 0 iff all passed.
#
# shellcheck disable=SC2016
# This file's whole business is assembling scripts whose `$`-expressions must
# reach the assembled file unexpanded; the single-quoted printf templates
# below are deliberate, the same way test/finish-then-continue.test.sh's are.

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

# --- Extraction ---------------------------------------------------------------

extract_block() {
  awk '
    /^if \[\[ -f "\$state_dir\/roll-pending\.json" \]\]; then$/ { on = 1 }
    on                                  { print }
    on && /^# --- 1b\. Crash-loop escalation/ { exit }
  ' "$1"
}

block="$(extract_block "$SCRIPT_DIR/agent-cycle.sh")"
if [[ -z "$block" || "$block" != *"chain_roll_pending_live"* || "$block" != *"chain_roll_standdown_record"* ]]; then
  echo "FAIL - could not extract the roll-standdown block from agent-cycle.sh — has it moved?" >&2
  exit 1
fi

# --- Harness -------------------------------------------------------------------
# run_block DESC IMAGE_STATUS_JSON UPDATER_STATUS_JSON [PRESEED...]
# Assembles state_dir with an optional pre-seeded roll-pending.json (named
# "live"/"expired"/"none") and roll-standdown.json ("none"/"capped"), runs the
# extracted block as a real script, and reports what happened: every event
# logged, whether set_node_state_terminal was called, whether the block ran to
# its own end (prints "END" — a stand-down's `exit 0` never reaches it), and
# the roll-pending.json/roll-standdown.json state afterward.
run_block() {
  local desc="$1" image_json="$2" updater_json="$3" marker="$4" standdown="$5"
  local run_dir="$tmp_dir/$desc"
  mkdir -p "$run_dir"

  case "$marker" in
    live)    jq -nc --arg u "$(date -u -d '+10 minutes' +%Y-%m-%dT%H:%M:%SZ)" '{until: $u}' > "$run_dir/roll-pending.json" ;;
    expired) jq -nc --arg u "$(date -u -d '-10 minutes' +%Y-%m-%dT%H:%M:%SZ)" '{until: $u}' > "$run_dir/roll-pending.json" ;;
    none)    : ;;
  esac
  case "$standdown" in
    capped) jq -nc '{count: 1, since: "2026-08-30T00:00:00Z"}' > "$run_dir/roll-standdown.json" ;;
    none)   : ;;
  esac

  local script="$run_dir/run.sh"
  {
    printf '#!/usr/bin/env bash\nset -uo pipefail\n'
    printf 'state_dir=%q\n' "$run_dir"
    printf 'HOSTNAME=test-node\nAGENT_OPS_SERVICE=scheduler\n'
    printf 'log_event() { printf "EVENT\\t%%s\\t%%s\\n" "$1" "$2" >> %q; }\n' "$run_dir/events.log"
    printf 'set_node_state_terminal() { printf "TERMINAL\\t%%s\\t%%s\\n" "$1" "${2:-}" >> %q; }\n' "$run_dir/events.log"
    printf 'agent_ops_version() { printf null; }\n'
    printf 'IMG_JSON=%q\n' "$image_json"
    printf 'image_drift_status() { printf %%s "$IMG_JSON"; }\n'
    printf 'cfg() { case "$1" in *updater_stuck_after_minutes*) printf 30 ;; *) printf 24 ;; esac; }\n'
    printf 'UPDATER_JSON=%q\n' "$updater_json"
    printf 'updater_status() { printf %%s "$UPDATER_JSON"; }\n'
    # shellcheck source=lib/chain.sh
    printf 'source %q\n' "$SCRIPT_DIR/lib/chain.sh"
    printf '%s\n' "$block"
    printf 'printf END >> %q\n' "$run_dir/events.log"
  } > "$script"
  chmod +x "$script"

  timeout 10 bash "$script" >/dev/null 2>&1 || true
  printf '%s' "$run_dir"
}

events_of() { grep -v '^END$' "$1/events.log" 2>/dev/null || true; }
reached_end() { [[ -s "$1/events.log" ]] && tail -c3 "$1/events.log" 2>/dev/null | grep -q 'END' && echo yes || echo no; }

behind='{"status":"behind","registry_commit":"abc1234","checked_at":"2026-08-30T00:00:00Z"}'
current='{"status":"current","checked_at":"2026-08-30T00:00:00Z"}'
deferring='{"status":"deferring","at":"2026-08-30T00:00:00Z","seconds":60}'
stuck_defer='{"status":"stuck","at":"2026-08-30T00:00:00Z","seconds":3600,"reason":"defer"}'
stuck_allow='{"status":"stuck","at":"2026-08-30T00:00:00Z","seconds":3600,"reason":"allow"}'
rolled='{"status":"rolled","at":"2026-08-30T00:00:00Z","seconds":60}'

# --- No marker at all: the whole block is a no-op --------------------------

run_dir="$(run_block no-marker "$current" "$deferring" none none)"
assert_eq "no roll-pending.json at all: nothing logged" "" "$(events_of "$run_dir")"
assert_eq "  ... and the block reaches its own end" "yes" "$(reached_end "$run_dir")"

# --- The landed marker is cleared before the stand-down check ever runs -----

run_dir="$(run_block landed-clears "$current" "$deferring" live none)"
assert_eq "a 'current' image verdict clears the marker" "0" \
  "$(test -f "$run_dir/roll-pending.json" && echo 1 || echo 0)"
assert_eq "  ... so no stand-down event is logged" "" "$(events_of "$run_dir")"
assert_eq "  ... and the block reaches its own end" "yes" "$(reached_end "$run_dir")"

# --- A still-'behind' verdict leaves the marker, which drives the new check -

run_dir="$(run_block standdown-fires "$behind" "$deferring" live none)"
assert_eq "a live marker + a 'deferring' updater verdict: stand down" \
  "1" "$(grep -c '^EVENT	stand-down	' "$run_dir/events.log" 2>/dev/null)"
assert_eq "  ... with cause roll-pending" "roll-pending" \
  "$(grep '^EVENT	stand-down	' "$run_dir/events.log" | sed 's/^EVENT\tstand-down\t//' | jq -r '.cause')"
assert_eq "  ... naming the marker's own until" "1" \
  "$([[ "$(grep '^EVENT	stand-down	' "$run_dir/events.log" | sed 's/^EVENT\tstand-down\t//' | jq -r '.until')" \
      =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] && echo 1 || echo 0)"
assert_eq "  ... and sets the node-state terminal to externally-blocked/roll-pending" \
  "TERMINAL	externally-blocked	roll-pending" "$(grep '^TERMINAL' "$run_dir/events.log")"
assert_eq "  ... recording one stand-down against the cap" "1" \
  "$(jq -r '.count' "$run_dir/roll-standdown.json")"
assert_eq "  ... and the block never reaches its own end (exit 0 fires first)" "no" "$(reached_end "$run_dir")"

run_dir="$(run_block standdown-fires-stuck-defer "$behind" "$stuck_defer" live none)"
assert_eq "a live marker + 'stuck'/reason:defer also stands down" "1" \
  "$(grep -c '^EVENT	stand-down	' "$run_dir/events.log" 2>/dev/null)"

# --- Verdicts idling cannot fix: run normally, nothing logged ---------------

for case_name_json in "stuck-allow:$stuck_allow" "rolled:$rolled" "null-verdict:null"; do
  case_name="${case_name_json%%:*}"
  case_json="${case_name_json#*:}"
  run_dir="$(run_block "normal-$case_name" "$behind" "$case_json" live none)"
  assert_eq "a live marker + '$case_name' runs normally, no stand-down" "" "$(events_of "$run_dir")"
  assert_eq "  ... and reaches its own end" "yes" "$(reached_end "$run_dir")"
done

# --- An expired (but not yet cleared) marker is not live --------------------

run_dir="$(run_block expired-marker "$behind" "$deferring" expired none)"
assert_eq "an expired marker is left for its own clock, not stood down against" "" "$(events_of "$run_dir")"
assert_eq "  ... and the block reaches its own end" "yes" "$(reached_end "$run_dir")"

# --- Guard B: the one-stand-down-per-pending-roll cap -----------------------

run_dir="$(run_block capped "$behind" "$deferring" live capped)"
assert_eq "a live marker, an eligible verdict, but the cap already spent: no stand-down" "0" \
  "$(grep -c '^EVENT	stand-down	' "$run_dir/events.log" 2>/dev/null)"
assert_eq "  ... logs the decision not taken instead" "1" \
  "$(grep -c '^EVENT	roll-standdown-capped	' "$run_dir/events.log" 2>/dev/null)"
assert_eq "  ... naming the marker's own until" "1" \
  "$([[ "$(grep '^EVENT	roll-standdown-capped	' "$run_dir/events.log" | sed 's/^EVENT\troll-standdown-capped\t//' | jq -r '.until')" \
      =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] && echo 1 || echo 0)"
assert_eq "  ... and the count already spent" "1" \
  "$(grep '^EVENT	roll-standdown-capped	' "$run_dir/events.log" | sed 's/^EVENT\troll-standdown-capped\t//' | jq -r '.count')"
assert_eq "  ... but still falls through and reaches its own end — runs the cycle normally" \
  "yes" "$(reached_end "$run_dir")"
assert_eq "  ... and the cap is left at 1, not bumped to 2" "1" \
  "$(jq -r '.count' "$run_dir/roll-standdown.json")"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
