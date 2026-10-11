#!/usr/bin/env bash
#
# test/union-read-memory-bound.test.sh — three readers that have to scale with
# the handful of records they care about, never with the whole fleet-log
# union they are handed (agent-ops#2312).
#
# `log_latest_ts` (lib/label-marker.sh) and `crash_loop_open_escalations`
# (lib/crash-loop.sh) used to slurp the whole union into one `jq` array just
# to take a max or filter almost everything away again — and ran before
# `acquire_lock` besides. On 2026-10-10, once the union reached 111 MB, that
# OOM-killed five `jq` processes on one node's cgroup (anon-RSS 541-616 MB
# each against a 1536 MiB hard ceiling). `label_own_actions_map` held the
# same shape, found while auditing the file's other readers against the same
# standard. All three now filter (or fold) before they collect.
#
# `ulimit -v` — not `/usr/bin/time -v`, which this image does not ship — is
# the bound here: a virtual-memory cap a child process cannot allocate past,
# so "stays in the tens of megabytes" is enforced rather than merely
# observed. `jq: error: cannot allocate memory` at 50,000 KB is exactly what
# every pre-fix form of these three readers does against this same fixture;
# the point of this file is that the shipped forms no longer do.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/union-read-memory-bound.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/label-marker.sh
. "$SCRIPT_DIR/lib/label-marker.sh"
# shellcheck source=lib/crash-loop.sh
. "$SCRIPT_DIR/lib/crash-loop.sh"

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

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# A union of at least 100 MB: mostly `merge-observed` filler — the event
# #2253 names as what actually grows these logs — plus a handful of real
# signal records whose correct extraction this file also pins.
union_log="$tmp_dir/union.jsonl"
python3 - "$union_log" <<'PYEOF'
import json, sys

path = sys.argv[1]
target = 105 * 1024 * 1024
written = 0
with open(path, "w") as f:
    i = 0
    while written < target:
        rec = {
            "ts": f"2026-08-21T07:{i % 60:02d}:{(i * 7) % 60:02d}Z",
            "node": "n1",
            "event": "merge-observed",
            "repo": "o/r",
            "detail": "x" * 40,
        }
        line = json.dumps(rec) + "\n"
        f.write(line)
        written += len(line)
        i += 1
    f.write(json.dumps({"ts": "2026-08-21T09:59:59Z", "event": "stage-end", "stage": "reviewer"}) + "\n")
    f.write(json.dumps({
        "ts": "2026-08-21T05:00:00Z", "event": "crash-loop-escalated", "stage": "coordinator",
        "detail": "d1", "first_ts": "2026-08-21T04:00:00Z", "issue_number": 501,
        "issue_url": "https://example/501",
    }) + "\n")
    f.write(json.dumps({
        "ts": "2026-08-21T05:05:00Z", "event": "crash-loop-escalated", "stage": "coordinator",
        "detail": "d2", "first_ts": "2026-08-21T04:30:00Z", "issue_number": 502,
        "issue_url": "https://example/502",
    }) + "\n")
    f.write(json.dumps({"ts": "2026-08-21T05:10:00Z", "event": "crash-loop-retired", "issue_number": 502}) + "\n")
    f.write(json.dumps({
        "ts": "2026-08-21T06:00:00Z", "event": "own-label-action", "label": "needs-refinement",
        "repo": "o/r", "item": "77", "action": "add",
    }) + "\n")
    f.write(json.dumps({
        "ts": "2026-08-21T06:30:00Z", "event": "own-label-action", "label": "needs-refinement",
        "repo": "o/r", "item": "77", "action": "remove",
    }) + "\n")
PYEOF

union_bytes="$(wc -c < "$union_log" | tr -d ' ')"
assert_eq "the generated fixture is at least 100 MB" \
  "1" "$(( union_bytes >= 100 * 1024 * 1024 ))"

# A tens-of-megabytes virtual-memory cap: generous for a streaming `jq`
# process's own baseline (interpreter, shared libraries, this file's small
# selected subset held as one array), nowhere near enough to hold 100+ MB of
# parsed-and-exploded JSON objects. `bash -c` re-execs `jq` after the
# `ulimit`, so the cap binds the child, not this script's own shell.
MEMORY_BOUND_KB=50000

run_under_bound() {
  local fn="$1"; shift
  bash -c '
    ulimit -v "$1"
    shift
    fn="$1"; shift
    # shellcheck disable=SC1090
    . "$0"/lib/label-marker.sh
    # shellcheck disable=SC1090
    . "$0"/lib/crash-loop.sh
    "$fn" "$@"
  ' "$SCRIPT_DIR" "$MEMORY_BOUND_KB" "$fn" "$@"
}

# --- log_latest_ts -----------------------------------------------------------
out="$(run_under_bound log_latest_ts "$union_log")"
rc=$?
assert_eq "log_latest_ts succeeds under a ${MEMORY_BOUND_KB} KB virtual-memory cap" "0" "$rc"
assert_eq "  ... and still finds the newest ts across the fixture" \
  "2026-08-21T09:59:59Z" "$out"

# --- crash_loop_open_escalations ---------------------------------------------
out="$(run_under_bound crash_loop_open_escalations < "$union_log")"
rc=$?
assert_eq "crash_loop_open_escalations succeeds under the same cap" "0" "$rc"
assert_eq "  ... and still reports only the still-open escalation" \
  "501" "$(jq -r '.issue_number' <<<"$out" 2>/dev/null)"
assert_eq "  ... one line only — the retired issue_number is excluded" \
  "1" "$(wc -l <<<"$out" | tr -d ' ')"

# --- label_own_actions_map (the audit this issue also asked for) ------------
out="$(run_under_bound label_own_actions_map needs-refinement "$union_log")"
rc=$?
assert_eq "label_own_actions_map succeeds under the same cap" "0" "$rc"
assert_eq "  ... and still folds the add/remove pair into one entry" \
  '{"o/r|77":{"action":"remove","ts":"2026-08-21T06:30:00Z","adds":["2026-08-21T06:00:00Z"]}}' \
  "$out"

# --- The property holds without the cap too — this is a correctness fixture,
# not only a memory-bound one; the three assertions above are what pin the
# fix, not merely "ran out of memory, as expected elsewhere".
assert_eq "log_latest_ts, uncapped, agrees with the capped run" \
  "2026-08-21T09:59:59Z" "$(log_latest_ts "$union_log")"

if (( failures == 0 )); then
  printf '\nAll assertions passed.\n'
  exit 0
fi
printf '\n%d assertion(s) failed.\n' "$failures"
exit 1
