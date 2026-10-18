#!/usr/bin/env bash
#
# test/credential-refused-retire-resolved.test.sh — direct coverage of
# `credential_refused_retire_resolved` (lib/enabler.sh, agent-ops#2414), the
# function requirement 2.0h's own retirement block in lib/standdown.sh calls
# once a node's credential probe recovers. test/standdown-credential-
# preflight.test.sh covers the wiring — that the block *calls* this function
# with the right arguments at the right transition, stubbing the function
# itself — the same division of labour test/crash-loop.test.sh and
# test/crash-loop-escalate.test.sh draw around `crash_loop_retire_resolved`.
# This file is the other half: the function's own body, exercised directly
# with a stubbed `gh`, which is what actually binds the issue's per-node
# acceptance criterion — "a probe that succeeds on one node never closes
# another node's escalation" — since the jq body-match guard inside this
# function, not anything the standdown block does, is what makes that safe.
#
# Kept in its own file rather than folded into
# test/standdown-credential-preflight.test.sh: sourcing lib/enabler.sh and
# lib/notify.sh into that file widens shellcheck -x's variable pool enough
# to surface SC2030 findings against that file's own pre-existing
# subshell-local assignments, unrelated to anything this file adds. A fresh
# file sidesteps that entirely, the same way test/crash-loop-escalate.test.sh
# already sources both of those modules on its own without issue.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly: ./test/credential-refused-retire-resolved.test.sh — exit 0 iff
# all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/notify.sh
# agent-cycle.sh always sources this ahead of lib/enabler.sh (issue #1279);
# without it here, credential_refused_retire_resolved's own
# notify_post_cycle call below is an undefined command, not the no-op an
# unset notify_webhook_url is meant to be.
. "$SCRIPT_DIR/lib/notify.sh"
# shellcheck source=lib/enabler.sh
. "$SCRIPT_DIR/lib/enabler.sh"

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

cycle_dir="$tmp_dir/cycle"; mkdir -p "$cycle_dir"
enabler_escalation_label="autonomous-agent-escalation"

# log_event: a recorder, the same convention
# test/crash-loop-escalate.test.sh uses, so assertions can inspect exactly
# what this function emits without agent-cycle.sh's own logging plumbing
# ($log_file, $cycle_id, $node_name) along for the ride.
events_file="$tmp_dir/events"
log_event() { printf '%s\t%s\n' "$1" "${2:-{\}}" >> "$events_file"; }

# gh: `gh issue list` returns whatever GH_ISSUE_LIST_JSON names; `gh issue
# close` is recorded into GH_CLOSE_CALLS_FILE, `---end---`-terminated since
# the body is multi-line (the same convention run_block's own escalation
# stub in test/standdown-credential-preflight.test.sh uses for the same
# reason).
GH_ISSUE_LIST_JSON='[]'
GH_CLOSE_CALLS_FILE="$tmp_dir/close-calls"
gh() {
  if [[ "$1" == "issue" && "$2" == "list" ]]; then
    printf '%s' "$GH_ISSUE_LIST_JSON"
    return 0
  elif [[ "$1" == "issue" && "$2" == "close" ]]; then
    # --comment is always the last flag this codebase passes it as.
    { printf 'number=%s\n' "$3"
      echo "---comment---"
      printf '%s\n' "${*: -1}"
      echo "---end---"
    } >> "$GH_CLOSE_CALLS_FILE"
    return 0
  fi
  return 1
}

# --- "the close": a matching open escalation is closed, with a comment
# naming this cycle and the probe's own timestamp. ---

# shellcheck disable=SC2016  # the backticks are literal Markdown, not command substitution
GH_ISSUE_LIST_JSON='[{"number":55,"url":"https://github.com/acme/agent-ops/issues/55","body":"- node: `test-node`\n\n---\nItem: `credential-refused:test-node` · raised by the Script"}]'
: > "$GH_CLOSE_CALLS_FILE"; : > "$events_file"
credential_refused_retire_resolved "acme/agent-ops" "test-node" "20261017T000000Z-test-node-5" \
  "2026-10-14T19:49:02Z"
assert_eq "a matching open escalation is closed exactly once" \
  "1" "$(grep -c '^---end---$' "$GH_CLOSE_CALLS_FILE" 2>/dev/null)"
assert_eq "…the right issue number" \
  "yes" "$(if grep -q '^number=55$' "$GH_CLOSE_CALLS_FILE"; then echo yes; else echo no; fi)"
assert_eq "…the closing comment names this cycle" \
  "yes" "$(if grep -q '20261017T000000Z-test-node-5' "$GH_CLOSE_CALLS_FILE"; then echo yes; else echo no; fi)"
assert_eq "…and the probe's own timestamp" \
  "yes" "$(if grep -q '2026-10-14T19:49:02Z' "$GH_CLOSE_CALLS_FILE"; then echo yes; else echo no; fi)"
assert_eq "…and logs credential-refused-retired" \
  "1" "$(grep -c '^credential-refused-retired' "$events_file" 2>/dev/null)"

# --- "the per-node scoping": an open issue exists in the same repo, under
# the same escalation label, but it names a *different* node — it must
# never be closed by this node's own recovery, however GitHub's own
# `--search` ranked it among the results. ---

# shellcheck disable=SC2016  # the backticks are literal Markdown, not command substitution
GH_ISSUE_LIST_JSON='[{"number":56,"url":"https://github.com/acme/agent-ops/issues/56","body":"- node: `other-node`\n\n---\nItem: `credential-refused:other-node` · raised by the Script"}]'
: > "$GH_CLOSE_CALLS_FILE"; : > "$events_file"
credential_refused_retire_resolved "acme/agent-ops" "test-node" "20261017T000000Z-test-node-6" \
  "2026-10-14T19:49:02Z"
assert_eq "a different node's escalation is never closed" \
  "0" "$(wc -l < "$GH_CLOSE_CALLS_FILE" | tr -d ' ')"
assert_eq "…and nothing is logged as retired" \
  "0" "$(grep -c '^credential-refused-retired' "$events_file" 2>/dev/null)"

# --- no open escalation at all (never filed, or already closed by hand): a
# quiet no-op, not an error. ---

GH_ISSUE_LIST_JSON='[]'
: > "$GH_CLOSE_CALLS_FILE"; : > "$events_file"
credential_refused_retire_resolved "acme/agent-ops" "test-node" "20261017T000000Z-test-node-7" \
  "2026-10-14T19:49:02Z"
assert_eq "no open escalation means nothing is closed" \
  "0" "$(wc -l < "$GH_CLOSE_CALLS_FILE" | tr -d ' ')"

printf '\n'
if (( failures )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
