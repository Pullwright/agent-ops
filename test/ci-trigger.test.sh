#!/usr/bin/env bash
#
# test/ci-trigger.test.sh — regression test for lib/ci-trigger.sh
# (issue #2560): a push onto a pipeline-owned PR branch whose CI trigger
# GitHub never delivered leaves the head with zero check runs at all — not
# failing, simply absent — which nothing catches until a Reviewer handoff
# that may run hours later (agent-ops#2506: ~7 hours, the head actually
# failing `scripts/spec.sh check`).
#
# `gh pr checks`/`gh pr view` are stubbed through CI_TRIGGER_GH, the same
# convention test/review-gate.test.sh's stub uses; `gh api graphql` (the
# merge-queue probe `ci_trigger_ensure` calls through `lib/merge-queue.sh`)
# is stubbed through MERGE_QUEUE_GH, pointed at the same binary. The actual
# nudge push (`_ci_trigger_nudge_push`) is stubbed as a recorder — the same
# technique test/rebase-only-wiring.test.sh already uses for
# `rebase_only_forge_capture`/`rebase_only_forge_check`, since a real push
# needs a real forge and that is exactly what this file's own git-plumbing
# function (fetch/checkout/commit/push against "https://github.com/$slug.git")
# is not meant to run against in a test. `ci_trigger_ensure`'s own polling
# and decision logic — the part this issue is actually about — is what runs
# for real against the stub above.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/ci-trigger.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/merge-queue.sh
. "$SCRIPT_DIR/lib/merge-queue.sh"
# shellcheck source=lib/ci-trigger.sh
. "$SCRIPT_DIR/lib/ci-trigger.sh"

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

SLUG="Pullwright/agent-ops"
NUMBER="2560"
BRANCH="agent/2560"

# The poll must not spend real wall-clock in a test.
export CI_TRIGGER_POLL_ATTEMPTS=3
export CI_TRIGGER_POLL_INTERVAL=0

# --- The stub gh --------------------------------------------------------------
# $tmp_dir/checks-sequence   one `pr checks` payload per line, consumed in
#                            order across successive polls within a single
#                            ci_trigger_ensure call — "ERROR" fails that read
#                            outright, reproducing an unreadable list (a 502,
#                            a transient auth failure) rather than a
#                            confirmed-empty one. Exhausted lines repeat the
#                            last one, so a test need only list as many as it
#                            cares to distinguish.
# $tmp_dir/checks-calls      incremented once per `pr checks` call, so a test
#                            can assert exactly how many polls happened.
# $tmp_dir/head-sha          what `gh pr view --json headRefOid` answers.
# $tmp_dir/queue-response.json  the GraphQL payload `merge_queue_probe` itself
#                            already shapes into {queued, dequeued_at,
#                            dequeue_reason}; "FAIL" fails the call outright.
cat > "$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"

if [[ "$1 $2" == "pr checks" ]]; then
  n="$(cat "$d/checks-calls" 2>/dev/null || echo 0)"
  echo "$(( n + 1 ))" > "$d/checks-calls"
  line="$(sed -n "$(( n + 1 ))p" "$d/checks-sequence" 2>/dev/null)"
  [[ -z "$line" ]] && line="$(tail -n1 "$d/checks-sequence" 2>/dev/null)"
  [[ "$line" == "ERROR" ]] && exit 1
  printf '%s' "$line"
  exit 0
fi

if [[ "$1 $2" == "pr view" ]]; then
  content="$(cat "$d/head-sha" 2>/dev/null || printf 'deadbeef')"
  [[ "$content" == "ERROR" ]] && exit 1
  printf '%s' "$content"
  exit 0
fi

if [[ "$1" == "api" && "$2" == "graphql" ]]; then
  [[ -f "$d/queue-fail" ]] && exit 1
  jqfilter="." prev=""
  for a in "$@"; do
    [[ "$prev" == "--jq" ]] && jqfilter="$a"
    prev="$a"
  done
  jq -c "$jqfilter" "$d/queue-response.json" 2>/dev/null
  exit 0
fi

exit 1
STUB
chmod +x "$tmp_dir/gh"
export CI_TRIGGER_GH="$tmp_dir/gh"
export MERGE_QUEUE_GH="$tmp_dir/gh"

set_checks_sequence() { printf '%s\n' "$@" > "$tmp_dir/checks-sequence"; }
reset_checks_calls() { rm -f "$tmp_dir/checks-calls"; }
checks_call_count() { cat "$tmp_dir/checks-calls" 2>/dev/null || echo 0; }
set_head_sha() { printf '%s' "$1" > "$tmp_dir/head-sha"; }
set_queue_response() { printf '%s' "$1" > "$tmp_dir/queue-response.json"; }
set_queue_fail() { : > "$tmp_dir/queue-fail"; }
clear_queue_fail() { rm -f "$tmp_dir/queue-fail"; }

set_head_sha 'deadbeef'
set_queue_response '{"data":{"repository":{"pullRequest":{"isInMergeQueue":false,"timelineItems":{"nodes":[]}}}}}'
clear_queue_fail

# Recorder in place of the real nudge push — the real one is a disposable
# git clone against "https://github.com/$slug.git", which a unit test must
# never actually dial (see this file's header). `ci_trigger_ensure`'s own
# decision to call it, with which arguments, is what this file tests.
nudge_push_calls_file="$tmp_dir/nudge-push-calls"
nudge_push_result_file="$tmp_dir/nudge-push-result"
printf 'success' > "$nudge_push_result_file"
_ci_trigger_nudge_push() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$nudge_push_calls_file"
  [[ "$(cat "$nudge_push_result_file")" == "success" ]]
}
reset_nudge_push() { rm -f "$nudge_push_calls_file"; printf 'success' > "$nudge_push_result_file"; }

# --- Acceptance criterion 2: a check run before the window elapses nudges nothing

reset_checks_calls; reset_nudge_push
set_checks_sequence '[]' '[{"name":"CI","bucket":"pending"}]' '[{"name":"CI","bucket":"pass"}]'
out="$(ci_trigger_ensure "$SLUG" "$NUMBER" "$BRANCH")"; rc=$?
assert_eq "a check run appearing before the window elapses is triggered" "triggered" "$out"
assert_eq "  ... and exits 0" "0" "$rc"
assert_eq "  ... stops polling the moment one appears (2 calls, not 3)" "2" "$(checks_call_count)"
assert_eq "  ... and never calls the nudge push" "" "$(cat "$nudge_push_calls_file" 2>/dev/null || true)"

# --- Acceptance criterion 1: zero check runs through the whole window nudges exactly once

reset_checks_calls; reset_nudge_push
set_checks_sequence '[]' '[]' '[]'
out="$(ci_trigger_ensure "$SLUG" "$NUMBER" "$BRANCH")"; rc=$?
assert_eq "zero check runs through the whole window is nudged" "nudged" "${out%%$'\t'*}"
assert_eq "  ... naming the head sha it nudged" "deadbeef" "${out#*$'\t'}"
assert_eq "  ... and exits 0" "0" "$rc"
assert_eq "  ... polls the full window (3 calls)" "3" "$(checks_call_count)"
assert_eq "  ... pushes exactly one nudge" "1" "$(wc -l < "$nudge_push_calls_file" | tr -d ' ')"
assert_eq "  ... onto this slug/branch, at the head it just confirmed" \
  "$(printf '%s\t%s\t%s' "$SLUG" "$BRANCH" "deadbeef")" "$(cat "$nudge_push_calls_file")"

# --- Acceptance criterion 3: at most one retrigger — a failed nudge is not retried here

reset_checks_calls; reset_nudge_push
printf 'fail' > "$nudge_push_result_file"
set_checks_sequence '[]' '[]' '[]'
out="$(ci_trigger_ensure "$SLUG" "$NUMBER" "$BRANCH")"; rc=$?
assert_eq "a nudge push that itself fails to push is nudge-failed" "nudge-failed" "${out%%$'\t'*}"
assert_eq "  ... and exits 1" "1" "$rc"
assert_eq "  ... still attempted exactly once, never looped" "1" "$(wc -l < "$nudge_push_calls_file" | tr -d ' ')"
reset_nudge_push
printf 'success' > "$nudge_push_result_file"

# --- An unreadable read at the end of the window never nudges

reset_checks_calls; reset_nudge_push
set_checks_sequence '[]' 'ERROR' 'ERROR'
out="$(ci_trigger_ensure "$SLUG" "$NUMBER" "$BRANCH")"; rc=$?
assert_eq "a window ending on an unreadable read is unknown, not nudged" "unknown" "$out"
assert_eq "  ... and exits 1" "1" "$rc"
assert_eq "  ... and never calls the nudge push" "" "$(cat "$nudge_push_calls_file" 2>/dev/null || true)"

# A confirmed-empty read recovering after a transient unreadable one still nudges.
reset_checks_calls; reset_nudge_push
set_checks_sequence 'ERROR' '[]' '[]'
out="$(ci_trigger_ensure "$SLUG" "$NUMBER" "$BRANCH")"; rc=$?
assert_eq "the window's own last read decides it, not an earlier transient failure" "nudged" "${out%%$'\t'*}"

# --- A pull request currently in the merge group is never pushed to

reset_checks_calls; reset_nudge_push
set_queue_response '{"data":{"repository":{"pullRequest":{"isInMergeQueue":true,"timelineItems":{"nodes":[]}}}}}'
set_checks_sequence '[]' '[]' '[]'
out="$(ci_trigger_ensure "$SLUG" "$NUMBER" "$BRANCH")"; rc=$?
assert_eq "a currently-queued pull request is left alone" "queued" "$out"
assert_eq "  ... and exits 1" "1" "$rc"
assert_eq "  ... and never calls the nudge push" "" "$(cat "$nudge_push_calls_file" 2>/dev/null || true)"
set_queue_response '{"data":{"repository":{"pullRequest":{"isInMergeQueue":false,"timelineItems":{"nodes":[]}}}}}'

# --- An unreadable queue probe never nudges either (fail closed, not "assume not queued")

reset_checks_calls; reset_nudge_push
set_queue_fail
set_checks_sequence '[]' '[]' '[]'
out="$(ci_trigger_ensure "$SLUG" "$NUMBER" "$BRANCH")"; rc=$?
assert_eq "an unreadable queue probe is unknown, not nudged" "unknown" "$out"
assert_eq "  ... and exits 1" "1" "$rc"
assert_eq "  ... and never calls the nudge push" "" "$(cat "$nudge_push_calls_file" 2>/dev/null || true)"
clear_queue_fail

# --- Requirement 4: review_gate_required_checks's own behaviour is unchanged

# shellcheck source=lib/review-gate.sh
. "$SCRIPT_DIR/lib/review-gate.sh"
export REVIEW_GATE_GH="$tmp_dir/gh-review-gate"
cat > "$REVIEW_GATE_GH" <<'STUB'
#!/usr/bin/env bash
if [[ "$1 $2" == "pr checks" ]]; then
  printf '[{"name":"CI","bucket":"pass"}]'
  exit 0
fi
exit 1
STUB
chmod +x "$REVIEW_GATE_GH"
out="$(review_gate_required_checks "https://github.com/$SLUG/pull/$NUMBER")"; rc=$?
assert_eq "review_gate_required_checks is untouched by this file's own additions" "clean" "$out"
assert_eq "  ... and exits 0" "0" "$rc"

echo
if [[ "$failures" -eq 0 ]]; then
  echo "All assertions passed."
  exit 0
else
  echo "$failures assertion(s) failed."
  exit 1
fi
