#!/usr/bin/env bash
#
# test/constraint-cli.test.sh — regression test for scripts/constraint.sh
# (docs/ROADMAP.md D21's "state the constraint" bullet, issue #609): the
# read-only CLI wiring around lib/constraint.sh's `constraint_classify`,
# distinct from test/constraint.test.sh's own pure-function coverage of the
# classification itself.
#
# What matters here:
#
#   read-only and    a run against a fixture tree writes nothing, takes no
#   offline          lock and makes no `gh` call — acceptance criterion 7 of
#                    issue #609, asserted rather than merely claimed in a
#                    comment.
#   both logs         node-state events live in either log.jsonl
#   unioned           (agent-cycle.sh) or review-log.jsonl (review-cycle.sh);
#                     a node running either pipeline must be folded in,
#                     exactly as scripts/node-time-state.sh already does.
#   config wiring      constraint_min_share/constraint_min_sample_seconds/
#                       schedule.cycle_interval_minutes come from this
#                       repository's own config.json, not a hard-coded
#                       default, when not overridden by a flag.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/constraint-cli.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONSTRAINT="$SCRIPT_DIR/scripts/constraint.sh"

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

# --- Acceptance criterion 7: read-only and offline ---------------------------
#
# scripts/constraint.sh must never call `gh`, never take this repository's
# own pipeline lock, and never write to the fixture tree it reads. The first
# two are asserted statically against the script's own source (the same
# thing a reviewer would grep for); the third is asserted by hashing the
# fixture tree before and after a run and requiring the two to match byte
# for byte.

assert_eq "the script never shells out to gh" \
  "0" "$(grep -c '\bgh \|\bgh$' "$CONSTRAINT" || true)"
assert_eq "the script never sources a lock/claim library" \
  "0" "$(grep -cE 'lib/claim(-key)?\.sh|acquire_lock|flock' "$CONSTRAINT" || true)"

ro_state="$tmp_dir/ro-state"
ro_peers="$tmp_dir/ro-peers/node-b"
mkdir -p "$ro_state" "$ro_peers"
cat > "$ro_state/log.jsonl" <<'EOF'
{"ts":"2026-09-01T00:00:00Z","node":"node-a","event":"node-state","state":"producing"}
{"ts":"2026-09-01T00:10:00Z","node":"node-a","event":"node-state","state":"overhead"}
EOF
cat > "$ro_peers/log.jsonl" <<'EOF'
{"ts":"2026-09-01T00:00:00Z","node":"node-b","event":"node-state","state":"idle-with-demand","cause":"back-pressure"}
EOF

before_hash="$(find "$tmp_dir" -type f -exec sha256sum {} \; | sort)"
before_mtimes="$(find "$tmp_dir" -type f -printf '%p %T@\n' | sort)"
out_ro="$("$CONSTRAINT" --state-dir "$ro_state" --peers-dir "$tmp_dir/ro-peers")"
rc_ro=$?
after_hash="$(find "$tmp_dir" -type f -exec sha256sum {} \; | sort)"
after_mtimes="$(find "$tmp_dir" -type f -printf '%p %T@\n' | sort)"

assert_eq "exits 0" "0" "$rc_ro"
assert_eq "the fixture tree's file set and contents are byte-identical after a run" \
  "$before_hash" "$after_hash"
assert_eq "  ... and no file's own mtime moved (nothing was even touched, not just unwritten)" \
  "$before_mtimes" "$after_mtimes"
assert_eq "prints valid JSON" \
  "0" "$(jq -e . >/dev/null 2>&1 <<<"$out_ro"; echo $?)"

# --- Both logs are unioned: a node's node-state events split across
#     log.jsonl and review-log.jsonl still fold into one account -------------

union_state="$tmp_dir/union-state"
union_peers="$tmp_dir/union-peers"
mkdir -p "$union_state" "$union_peers"
cat > "$union_state/log.jsonl" <<'EOF'
{"ts":"2026-09-02T00:00:00Z","node":"n1","event":"node-state","state":"overhead"}
{"ts":"2026-09-02T00:10:00Z","node":"n1","event":"node-state","state":"producing"}
EOF
cat > "$union_state/review-log.jsonl" <<'EOF'
{"ts":"2026-09-02T00:20:00Z","node":"n1","event":"node-state","state":"idle-without-demand","cause":"no-demand"}
EOF

out_union="$("$CONSTRAINT" --state-dir "$union_state" --peers-dir "$union_peers")"
assert_eq "log.jsonl and review-log.jsonl are both folded into one node's timeline" \
  "1200" "$(jq -r '.expected_total_seconds' <<<"$out_union")"

# --- An empty log directory pair is a clean report, not an error ------------

empty_state="$tmp_dir/empty-state"
empty_peers="$tmp_dir/empty-peers"
mkdir -p "$empty_state" "$empty_peers"
out_empty="$("$CONSTRAINT" --state-dir "$empty_state" --peers-dir "$empty_peers")"
assert_eq "an empty log exits 0" "0" "$?"
assert_eq "  ... reports insufficient-evidence, not a crash" \
  "insufficient-evidence" "$(jq -r '.status' <<<"$out_empty")"
assert_eq "  ... naming the missing time-account data" \
  "no-time-account-data" "$(jq -r '.insufficient_reason' <<<"$out_empty")"

# --- Config wiring: min_share/min_sample_seconds/cadence_bound_minutes come
#     from this repository's own config.json -------------------------------

assert_eq "min_share echoes this repository's own config.json (or the schema default)" \
  "$(jq -r '.constraint_min_share // 0.3' "$SCRIPT_DIR/config.json")" \
  "$(jq -r '.min_share' <<<"$out_empty")"
assert_eq "min_sample_seconds echoes this repository's own config.json (or the schema default)" \
  "$(jq -r '.constraint_min_sample_seconds // 14400' "$SCRIPT_DIR/config.json")" \
  "$(jq -r '.min_sample_seconds' <<<"$out_empty")"
assert_eq "cadence_bound_minutes echoes schedule.cycle_interval_minutes" \
  "$(jq -r '.schedule.cycle_interval_minutes' "$SCRIPT_DIR/config.json")" \
  "$(jq -r '.cadence_bound_minutes' <<<"$out_empty")"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
