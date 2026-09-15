#!/usr/bin/env bash
#
# test/node-health.test.sh — lib/node-health.sh's pure verdict functions
# (issue #608): the fold rule, liveness, the outbound/converged/health
# composition, and readiness's per-condition reporting. No files, no
# network, no Docker — exactly the constraints the library itself is
# written under.
#
# Run directly: ./test/node-health.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/node-health.sh
. "$SCRIPT_DIR/lib/node-health.sh"

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

# --- node_health_fold --------------------------------------------------

assert_eq "fold: all ok is ok" "ok" "$(node_health_fold ok ok ok)"
assert_eq "fold: any fail wins over ok and unknown" "fail" "$(node_health_fold ok fail unknown)"
assert_eq "fold: unknown wins over ok when nothing failed" "unknown" "$(node_health_fold ok unknown ok)"
assert_eq "fold: no arguments reads unknown, never ok" "unknown" "$(node_health_fold)"
assert_eq "fold: an unrecognised status folds as unknown, never crashes" "unknown" "$(node_health_fold ok bogus)"

# --- node_health_liveness -----------------------------------------------

assert_eq "liveness: no marker at all is not live" "false" \
  "$(node_health_liveness "" 180 1000 | jq -r '.live')"
assert_eq "liveness: no marker names the reason, not a bare boolean" \
  "no liveness marker yet" "$(node_health_liveness "" 180 1000 | jq -r '.reason')"
assert_eq "liveness: fresh marker is live" "true" \
  "$(node_health_liveness 950 180 1000 | jq -r '.live')"
assert_eq "liveness: marker aged past the threshold is not live" "false" \
  "$(node_health_liveness 700 180 1000 | jq -r '.live')"
assert_eq "liveness: age_s is reported" "300" \
  "$(node_health_liveness 700 180 1000 | jq -r '.age_s')"
assert_eq "liveness: a marker exactly at the threshold is still live" "true" \
  "$(node_health_liveness 820 180 1000 | jq -r '.live')"
assert_eq "liveness: a marker in the future never goes negative" "0" \
  "$(node_health_liveness 1500 180 1000 | jq -r '.age_s')"

# --- node_health_outbound_component --------------------------------------

assert_eq "outbound: fresh publication is ok" "ok" \
  "$(node_health_outbound_component '{"ts":"2026-09-15T00:00:00Z","age_s":10,"verdict":"fresh"}' | jq -r '.status')"
assert_eq "outbound: stale publication is fail" "fail" \
  "$(node_health_outbound_component '{"ts":"2026-09-01T00:00:00Z","age_s":999999,"verdict":"stale"}' | jq -r '.status')"
assert_eq "outbound: unknown publication (never fetched back) is unknown" "unknown" \
  "$(node_health_outbound_component '{"ts":null,"age_s":null,"verdict":"unknown"}' | jq -r '.status')"
assert_eq "outbound: an absent source reads unknown, never ok" "unknown" \
  "$(node_health_outbound_component null | jq -r '.status')"

# --- node_health_updater_component ---------------------------------------

assert_eq "updater: stuck is fail" "fail" \
  "$(node_health_updater_component '{"status":"stuck","at":"2026-09-01T00:00:00Z","seconds":9999,"reason":"allow"}' | jq -r '.status')"
assert_eq "updater: rolled is ok" "ok" \
  "$(node_health_updater_component '{"status":"rolled","at":"2026-09-15T00:00:00Z","seconds":10}' | jq -r '.status')"
assert_eq "updater: deferring is ok" "ok" \
  "$(node_health_updater_component '{"status":"deferring","at":"2026-09-15T00:00:00Z","seconds":10}' | jq -r '.status')"
assert_eq "updater: no ledger evidence (null) is unknown, never ok" "unknown" \
  "$(node_health_updater_component null | jq -r '.status')"

# --- node_health_image_component -----------------------------------------

now=1757900000  # an arbitrary fixed instant for reproducible age arithmetic
assert_eq "image: current is ok" "ok" \
  "$(node_health_image_component '{"status":"current","checked_at":"x"}' 3 "$now" | jq -r '.status')"
assert_eq "image: unverified is unknown" "unknown" \
  "$(node_health_image_component '{"status":"unverified","reason":"registry unreachable"}' 3 "$now" | jq -r '.status')"
assert_eq "image: no CI-stamped image (null) is unknown" "unknown" \
  "$(node_health_image_component null 3 "$now" | jq -r '.status')"

recent="$(date -u -d "@$(( now - 3600 ))" +%Y-%m-%dT%H:%M:%SZ)"   # 1h old — within a 3h grace
stale="$(date -u -d "@$(( now - 36000 ))" +%Y-%m-%dT%H:%M:%SZ)"   # 10h old — past a 3h grace
assert_eq "image: behind, within grace, is ok (a roll waits for a cycle in flight)" "ok" \
  "$(node_health_image_component "$(jq -nc --arg t "$recent" '{status:"behind", registry_commit:"abc1234", registry_created_at:$t}')" 3 "$now" | jq -r '.status')"
assert_eq "image: behind, past grace, is fail" "fail" \
  "$(node_health_image_component "$(jq -nc --arg t "$stale" '{status:"behind", registry_commit:"abc1234", registry_created_at:$t}')" 3 "$now" | jq -r '.status')"
assert_eq "image: behind with no readable age is fail, never grey-listed as ok" "fail" \
  "$(node_health_image_component '{"status":"behind","registry_commit":"abc1234","registry_created_at":null}' 3 "$now" | jq -r '.status')"

# --- node_health_converged and node_health_health: composition -----------

assert_eq "converged: both components ok folds to ok" "ok" \
  "$(node_health_converged '{"status":"rolled","at":"x","seconds":1}' '{"status":"current"}' 3 "$now" | jq -r '.status')"
assert_eq "converged: updater stuck fails the whole component" "fail" \
  "$(node_health_converged '{"status":"stuck","at":"x","seconds":9999,"reason":"allow"}' '{"status":"current"}' 3 "$now" | jq -r '.status')"
assert_eq "converged: no source for either sub-component is unknown, never ok" "unknown" \
  "$(node_health_converged null null 3 "$now" | jq -r '.status')"

fresh_pub='{"ts":"2026-09-15T00:00:00Z","age_s":10,"verdict":"fresh"}'
stale_pub='{"ts":"2026-09-01T00:00:00Z","age_s":999999,"verdict":"stale"}'
ok_updater='{"status":"rolled","at":"x","seconds":1}'
ok_image='{"status":"current"}'

assert_eq "health: outbound fresh + converged ok folds to ok" "ok" \
  "$(node_health_health "$fresh_pub" "$ok_updater" "$ok_image" 3 "$now" | jq -r '.status')"
assert_eq "health: outbound stale fails the top-level verdict even when converged is ok" "fail" \
  "$(node_health_health "$stale_pub" "$ok_updater" "$ok_image" 3 "$now" | jq -r '.status')"
# Acceptance criterion 4: a component whose source does not exist yet reads
# unknown, never ok — asserted here with fixture stand-ins for #602's and
# #603's own published fields absent (both null, the honest state before
# either has ever published for this node), then again once both exist,
# reaching both ok and fail.
assert_eq "health: neither #602 nor #603 has ever published — unknown, never ok" "unknown" \
  "$(node_health_health '{"ts":null,"age_s":null,"verdict":"unknown"}' null null 3 "$now" | jq -r '.status')"
assert_eq "health: once both publish good data, health reaches ok" "ok" \
  "$(node_health_health "$fresh_pub" "$ok_updater" "$ok_image" 3 "$now" | jq -r '.status')"
assert_eq "health: once both publish bad data, health reaches fail" "fail" \
  "$(node_health_health "$stale_pub" '{"status":"stuck","at":"x","seconds":9999,"reason":"allow"}' "$ok_image" 3 "$now" | jq -r '.status')"
assert_eq "health: health names which components it cannot evaluate" \
  "unknown" "$(node_health_health "$fresh_pub" null "$ok_image" 3 "$now" | jq -r '.components.converged.components.updater.status')"

# --- node_health_readiness ------------------------------------------------

all_good='{"credentials_present":true,"gh_auth":"ok","disk_free_kb":99999999,"disk_floor_bytes":0,
  "core_remaining":500,"core_floor":300,"graphql_remaining":500,"graphql_floor":100,
  "node_disabled":false,"fleet_disabled":false,"limit_freeze":false}'
assert_eq "readiness: every condition met is ready with no unmet entries" "true" \
  "$(node_health_readiness "$all_good" | jq -r '.ready')"
assert_eq "readiness: every condition met has an empty unmet array" "0" \
  "$(node_health_readiness "$all_good" | jq '.unmet | length')"

# Acceptance criterion 5: each condition reports its own specific code.
check_condition() {
  local desc="$1" patch="$2" want_code="$3"
  local facts out
  facts="$(jq -c ". + ($patch)" <<<"$all_good")"
  out="$(node_health_readiness "$facts")"
  assert_eq "readiness: $desc is not ready" "false" "$(jq -r '.ready' <<<"$out")"
  assert_eq "readiness: $desc names its own code" "true" \
    "$(jq --arg c "$want_code" '[.unmet[].code] | index($c) != null' <<<"$out")"
}

check_condition "absent Claude credentials" '{credentials_present:false}' "credentials-missing"
check_condition "unauthenticated gh" '{gh_auth:"unauthorized",gh_auth_detail:"bad token"}' "gh-unauthenticated"
check_condition "an unreachable forge" '{gh_auth:"unreachable",gh_auth_detail:"timeout"}' "gh-forge-unreachable"
check_condition "state_dir below the disk floor" '{disk_free_kb:100,disk_floor_bytes:1000000000}' "disk-low"
check_condition "core below its floor" '{core_remaining:10,core_floor:300}' "github-core-budget-low"
check_condition "graphql below its floor" '{graphql_remaining:10,graphql_floor:100}' "github-graphql-budget-low"
check_condition "node disabled" '{node_disabled:true}' "node-disabled"
check_condition "fleet disabled" '{fleet_disabled:true}' "fleet-disabled"
check_condition "a usage-limit freeze in force" '{limit_freeze:true}' "usage-limit-freeze"

# An unreadable local meter is "unknown", not "not ready" — the disk/budget
# checks never fire on a null reading, only on a reading that is actually
# below the floor (see the header's own distinction between an unreachable
# forge and an unreadable local signal).
unreadable_disk="$(jq -c '. + {disk_free_kb:null,disk_floor_bytes:1000000000}' <<<"$all_good")"
assert_eq "readiness: an unreadable disk meter alone does not block readiness" "true" \
  "$(node_health_readiness "$unreadable_disk" | jq -r '.ready')"
unreadable_core="$(jq -c '. + {core_remaining:null,core_floor:300,gh_auth:"ok"}' <<<"$all_good")"
assert_eq "readiness: an unreadable core budget alone (gh itself ok) does not block readiness" "true" \
  "$(node_health_readiness "$unreadable_core" | jq -r '.ready')"

# Multiple conditions failing at once are all named, not just the first.
multi="$(jq -c '. + {credentials_present:false, node_disabled:true}' <<<"$all_good")"
assert_eq "readiness: multiple failed conditions are all reported" "2" \
  "$(node_health_readiness "$multi" | jq '.unmet | length')"

echo
if (( failures > 0 )); then
  printf '%d failure(s)\n' "$failures"
  exit 1
fi
echo "all passed"
