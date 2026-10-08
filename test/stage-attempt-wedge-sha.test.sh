#!/usr/bin/env bash
#
# test/stage-attempt-wedge-sha.test.sh — a stage killed for inactivity, with
# a pull request already known, states in its own comment whether it pushed
# (requirement 9g, agent-ops#2236).
#
# `handle_stage_failure` (lib/stage-attempt.sh) is exercised directly, the
# inverse of test/coordinator-merge-fallback.test.sh and
# test/reviewer-merge-observed-wiring.test.sh, which stub the function itself
# — those cover its *callers*; this covers the function's own comment body.
# `gh` is stubbed to answer `pr view --json headRefOid` with a controlled
# "kill time" head SHA and to capture the body of `pr comment`.
#
# Run directly: ./test/stage-attempt-wedge-sha.test.sh — exit 0 iff all
# passed.

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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:              %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

STAGE_BOUNDARY_GROUP="agent-ops-no-such-group"
export STAGE_BOUNDARY_GROUP
# shellcheck source=lib/stage-run.sh
. "$SCRIPT_DIR/lib/stage-run.sh"
# shellcheck source=lib/stage-attempt.sh
. "$SCRIPT_DIR/lib/stage-attempt.sh"
# shellcheck source=lib/pipeline-marker.sh
. "$SCRIPT_DIR/lib/pipeline-marker.sh"

node_name="test-node"
cycle_id="test-cycle"

# handle_stage_failure's other collaborators, stubbed as recorders — each is
# covered on its own terms elsewhere, same as test/stage-project-settings.test.sh.
log_attempt_failed() { :; }
detect_and_log_limit_hit() { return 1; }
release_claim() { :; }

# gh — answers `pr view … --json headRefOid …` with $GH_KILL_SHA (empty means
# the read failed, same as an unreachable API or a closed pull request), and
# captures `pr comment … --body …`'s body to $comment_body_file.
comment_body_file="$tmp_dir/comment-body"
GH_KILL_SHA=""
gh() {
  if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
    [[ -n "$GH_KILL_SHA" ]] || return 1
    printf '%s' "$GH_KILL_SHA"
    return 0
  fi
  if [[ "${1:-}" == "pr" && "${2:-}" == "comment" ]]; then
    rm -f "$comment_body_file"
    local arg prev=""
    for arg in "$@"; do
      [[ "$prev" == "--body" ]] && printf '%s' "$arg" > "$comment_body_file"
      prev="$arg"
    done
    return 0
  fi
  return 1
}

posted_body() {
  rm -f "$comment_body_file"
  "$@"
  [[ -e "$comment_body_file" ]] && cat "$comment_body_file"
  return 0
}

out_file="$tmp_dir/reviewer.out"
pr_url="https://github.com/acme/widgets/pull/42"

# --- Equal SHAs: the round pushed nothing ---
stage_kill_reason="inactivity"
stage_pr_head_sha_at_start="abc1111"
GH_KILL_SHA="abc1111"
body="$(posted_body handle_stage_failure reviewer 124 "$out_file" "$pr_url")"
assert_contains "equal SHAs: states plainly the round pushed nothing" \
  "This round pushed nothing — the head SHA is unchanged at abc1111 — so every comment it posted this round describes intent, not landed work." \
  "$body"

# --- Differing SHAs: names both, invites a diff ---
stage_pr_head_sha_at_start="abc1111"
GH_KILL_SHA="def2222"
body="$(posted_body handle_stage_failure reviewer 124 "$out_file" "$pr_url")"
assert_contains "differing SHAs: names both and invites a diff of the range" \
  "This round's head moved from abc1111 to def2222 while it ran — diff that range against what its comments claimed before taking any of them at face value." \
  "$body"

# --- No round-start SHA (an ordinary fresh claim, no PR yet at round start):
# the sentence is dropped, not fabricated from a false "unchanged". ---
stage_pr_head_sha_at_start=""
GH_KILL_SHA="def2222"
body="$(posted_body handle_stage_failure reviewer 124 "$out_file" "$pr_url")"
assert_eq "no round-start SHA: comment is the plain wedged-stage notice" \
  "The Reviewer stopped on this PR: reviewer produced no output at all for its inactivity threshold and was stopped as wedged. Recorded blocked; the pipeline's Enabler will re-examine it, and will raise an issue if a human is needed." \
  "$(sed -n '3p' <<<"$body")"

# --- The kill-time read itself fails (closed PR, rate limit, …): degrade the
# same way, rather than failing the whole wedged-stage comment post. ---
stage_pr_head_sha_at_start="abc1111"
GH_KILL_SHA=""
body="$(posted_body handle_stage_failure reviewer 124 "$out_file" "$pr_url")"
assert_eq "unreadable kill-time SHA: comment is the plain wedged-stage notice" \
  "The Reviewer stopped on this PR: reviewer produced no output at all for its inactivity threshold and was stopped as wedged. Recorded blocked; the pipeline's Enabler will re-examine it, and will raise an issue if a human is needed." \
  "$(sed -n '3p' <<<"$body")"

# --- Every other detail branch's comment is unaffected by this requirement:
# both SHAs known, but the kill is not an inactivity one. ---
stage_kill_reason=""
stage_pr_head_sha_at_start="abc1111"
GH_KILL_SHA="def2222"
body="$(posted_body handle_stage_failure reviewer 1 "$out_file" "$pr_url")"
assert_eq "a non-inactivity failure's comment carries no SHA sentence at all" \
  "The Reviewer stopped on this PR: reviewer exited 1. Recorded blocked; the pipeline's Enabler will re-examine it, and will raise an issue if a human is needed." \
  "$(sed -n '3p' <<<"$body")"

if (( failures > 0 )); then
  printf '\n%d assertion(s) failed.\n' "$failures"
  exit 1
fi
printf '\nAll assertions passed.\n'
