#!/usr/bin/env bash
#
# test/memory-throttle-retire-resolved.test.sh — direct coverage of
# `memory_throttle_retire_resolved` (lib/enabler.sh, requirement 2.0i,
# agent-ops#2469), the function `lib/standdown.sh`'s own `memory_throttle_
# check` calls once a node's parent-cgroup throttle check reads clean after
# a sustained band. test/memory-throttle-wiring.test.sh covers the wiring —
# that the check *calls* this function at the right transition, stubbing
# the function itself — the same division of labour
# test/credential-refused-retire-resolved.test.sh draws around
# `credential_refused_retire_resolved`, the per-node shape this function
# mirrors exactly. This file is the other half: the function's own body,
# exercised directly with a stubbed `gh`, including the labelled-first/
# label-less-fallback two-step read `escalation_issue_lookup`
# (lib/escalation-lookup.sh, agent-ops#2670) both functions now share.
#
# Kept in its own file rather than folded into
# test/memory-throttle-wiring.test.sh, the same reason
# test/credential-refused-retire-resolved.test.sh gives for its own
# separation: sourcing lib/enabler.sh and lib/notify.sh into that file
# widens shellcheck -x's variable pool past what it needs for its own
# wiring-only assertions.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly: ./test/memory-throttle-retire-resolved.test.sh — exit 0 iff all
# passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/notify.sh
# agent-cycle.sh always sources this ahead of lib/enabler.sh (issue #1279);
# without it here, memory_throttle_retire_resolved's own notify_post_cycle
# call below is an undefined command, not the no-op an unset notify_
# webhook_url is meant to be.
. "$SCRIPT_DIR/lib/notify.sh"
# shellcheck source=lib/escalation-lookup.sh
# agent-cycle.sh always sources this ahead of lib/enabler.sh too
# (agent-ops#2670); without it here, memory_throttle_retire_resolved's own
# escalation_issue_lookup call below is an undefined command.
. "$SCRIPT_DIR/lib/escalation-lookup.sh"
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
# test/credential-refused-retire-resolved.test.sh uses, so assertions can
# inspect exactly what this function emits without agent-cycle.sh's own
# logging plumbing ($log_file, $cycle_id, $node_name) along for the ride.
events_file="$tmp_dir/events"
log_event() { printf '%s\t%s\n' "$1" "${2:-{\}}" >> "$events_file"; }

# gh: see test/credential-refused-retire-resolved.test.sh's own header for
# the full contract — `--label`-carrying calls answer from
# GH_ISSUE_LIST_JSON, label-less ones from GH_ISSUE_LIST_UNLABELLED_JSON
# (defaulting to GH_ISSUE_LIST_JSON), `gh issue list` fails outright when
# GH_ISSUE_LIST_RC is non-zero, and `gh issue close` is recorded into
# GH_CLOSE_CALLS_FILE or fails without being recorded when
# GH_ISSUE_CLOSE_RC is non-zero.
GH_ISSUE_LIST_JSON='[]'
GH_ISSUE_LIST_UNLABELLED_JSON=''
GH_ISSUE_LIST_RC=0
GH_ISSUE_CLOSE_RC=0
GH_CLOSE_CALLS_FILE="$tmp_dir/close-calls"
gh() {
  if [[ "$1" == "issue" && "$2" == "list" ]]; then
    if (( GH_ISSUE_LIST_RC != 0 )); then
      return "$GH_ISSUE_LIST_RC"
    fi
    if [[ " $* " == *" --label "* ]]; then
      printf '%s' "$GH_ISSUE_LIST_JSON"
    else
      printf '%s' "${GH_ISSUE_LIST_UNLABELLED_JSON:-$GH_ISSUE_LIST_JSON}"
    fi
    return 0
  elif [[ "$1" == "issue" && "$2" == "close" ]]; then
    (( GH_ISSUE_CLOSE_RC == 0 )) || return "$GH_ISSUE_CLOSE_RC"
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
# naming this cycle. ---

# shellcheck disable=SC2016  # the backticks are literal Markdown, not command substitution
GH_ISSUE_LIST_JSON='[{"number":65,"url":"https://github.com/acme/agent-ops/issues/65","body":"- node: `test-node`\n\n---\nItem: `memory-throttled:test-node` · raised by the Script"}]'
: > "$GH_CLOSE_CALLS_FILE"; : > "$events_file"
memory_throttle_retire_resolved "acme/agent-ops" "test-node" "20261017T000000Z-test-node-1"
assert_eq "a matching open escalation is closed exactly once" \
  "1" "$(grep -c '^---end---$' "$GH_CLOSE_CALLS_FILE" 2>/dev/null)"
assert_eq "…the right issue number" \
  "yes" "$(if grep -q '^number=65$' "$GH_CLOSE_CALLS_FILE"; then echo yes; else echo no; fi)"
assert_eq "…the closing comment names this cycle" \
  "yes" "$(if grep -q '20261017T000000Z-test-node-1' "$GH_CLOSE_CALLS_FILE"; then echo yes; else echo no; fi)"
assert_eq "…and logs memory-throttle-retired" \
  "1" "$(grep -c '^memory-throttle-retired' "$events_file" 2>/dev/null)"

# --- "the per-node scoping": an open issue for a *different* node must
# never be closed by this node's own clean reading. ---

# shellcheck disable=SC2016  # the backticks are literal Markdown, not command substitution
GH_ISSUE_LIST_JSON='[{"number":66,"url":"https://github.com/acme/agent-ops/issues/66","body":"- node: `other-node`\n\n---\nItem: `memory-throttled:other-node` · raised by the Script"}]'
: > "$GH_CLOSE_CALLS_FILE"; : > "$events_file"
memory_throttle_retire_resolved "acme/agent-ops" "test-node" "20261017T000000Z-test-node-2"
assert_eq "a different node's escalation is never closed" \
  "0" "$(wc -l < "$GH_CLOSE_CALLS_FILE" | tr -d ' ')"
assert_eq "…and nothing is logged as retired" \
  "0" "$(grep -c '^memory-throttle-retired' "$events_file" 2>/dev/null)"

# --- no open escalation at all (never filed, or already closed by hand): a
# quiet no-op, not an error. ---

GH_ISSUE_LIST_JSON='[]'
GH_ISSUE_LIST_RC=0; GH_ISSUE_CLOSE_RC=0
: > "$GH_CLOSE_CALLS_FILE"; : > "$events_file"
memory_throttle_retire_resolved "acme/agent-ops" "test-node" "20261017T000000Z-test-node-3"
retire_rc=$?
assert_eq "no open escalation means nothing is closed" \
  "0" "$(wc -l < "$GH_CLOSE_CALLS_FILE" | tr -d ' ')"
assert_eq "…and returns success — a genuinely empty lookup is not a failure" \
  "0" "$retire_rc"

# --- failure window (a): the matching escalation is found, but `gh issue
# close` itself fails. Must return non-zero and never log memory-throttle-
# retired, since the close never actually happened. ---

# shellcheck disable=SC2016  # the backticks are literal Markdown, not command substitution
GH_ISSUE_LIST_JSON='[{"number":67,"url":"https://github.com/acme/agent-ops/issues/67","body":"- node: `test-node`\n\n---\nItem: `memory-throttled:test-node` · raised by the Script"}]'
GH_ISSUE_LIST_RC=0; GH_ISSUE_CLOSE_RC=1
: > "$GH_CLOSE_CALLS_FILE"; : > "$events_file"
memory_throttle_retire_resolved "acme/agent-ops" "test-node" "20261017T000000Z-test-node-4"
retire_rc=$?
assert_eq "a failed gh issue close returns non-zero" \
  "1" "$retire_rc"
assert_eq "…never logs memory-throttle-retired" \
  "0" "$(grep -c '^memory-throttle-retired' "$events_file" 2>/dev/null)"
assert_eq "…logs a warning naming issue #67 and that it will retry next cycle" \
  "yes" "$(if grep -E '^warning' "$events_file" | grep -q '#67' \
              && grep -E '^warning' "$events_file" | grep -q 'will retry next cycle'; then echo yes; else echo no; fi)"

# --- failure window (b): the `gh issue list` lookup itself errors, distinct
# from a genuinely empty result above — must log a warning and return
# non-zero, never attempting a close. ---

GH_ISSUE_LIST_RC=1; GH_ISSUE_CLOSE_RC=0
: > "$GH_CLOSE_CALLS_FILE"; : > "$events_file"
memory_throttle_retire_resolved "acme/agent-ops" "test-node" "20261017T000000Z-test-node-5"
retire_rc=$?
assert_eq "a failed gh issue list lookup returns non-zero" \
  "1" "$retire_rc"
assert_eq "…never attempts a close" \
  "0" "$(wc -l < "$GH_CLOSE_CALLS_FILE" | tr -d ' ')"
assert_eq "…logs a warning naming the lookup failure and the retry" \
  "yes" "$(if grep -E '^warning' "$events_file" | grep -q 'lookup' \
              && grep -E '^warning' "$events_file" | grep -q 'will retry next cycle'; then echo yes; else echo no; fi)"
GH_ISSUE_LIST_RC=0

# --- failure window (c): `gh issue list` succeeds but returns a payload
# `jq` cannot parse — must not be read as a genuinely empty match, so must
# log a warning and return non-zero rather than silently forfeiting the
# close. ---

GH_ISSUE_LIST_JSON='not valid json'
GH_ISSUE_LIST_RC=0; GH_ISSUE_CLOSE_RC=0
: > "$GH_CLOSE_CALLS_FILE"; : > "$events_file"
memory_throttle_retire_resolved "acme/agent-ops" "test-node" "20261017T000000Z-test-node-6"
retire_rc=$?
assert_eq "an unparseable gh issue list payload returns non-zero" \
  "1" "$retire_rc"
assert_eq "…never attempts a close" \
  "0" "$(wc -l < "$GH_CLOSE_CALLS_FILE" | tr -d ' ')"
assert_eq "…never logs memory-throttle-retired" \
  "0" "$(grep -c '^memory-throttle-retired' "$events_file" 2>/dev/null)"
assert_eq "…logs a warning naming the unparseable payload and the retry" \
  "yes" "$(if grep -E '^warning' "$events_file" | grep -q 'could not parse' \
              && grep -E '^warning' "$events_file" | grep -q 'will retry next cycle'; then echo yes; else echo no; fi)"
GH_ISSUE_LIST_JSON='[]'

# --- the label-less fallback (agent-ops#2657, agent-ops#2666, agent-ops#2670):
# an escalation filed via `create_escalation_issue`'s own retry-without-label
# path is still found and retired here, through `escalation_issue_lookup`'s
# own two-step read. ---

GH_ISSUE_LIST_JSON='[]'
# shellcheck disable=SC2016  # the backticks are literal Markdown, not command substitution
GH_ISSUE_LIST_UNLABELLED_JSON='[{"number":68,"url":"https://github.com/acme/agent-ops/issues/68","body":"- node: `test-node`\n\n---\nItem: `memory-throttled:test-node` · raised by the Script"}]'
: > "$GH_CLOSE_CALLS_FILE"; : > "$events_file"
memory_throttle_retire_resolved "acme/agent-ops" "test-node" "20261017T000000Z-test-node-7"
assert_eq "a label-less escalation is still closed exactly once" \
  "1" "$(grep -c '^---end---$' "$GH_CLOSE_CALLS_FILE" 2>/dev/null)"
assert_eq "…the right issue number" \
  "yes" "$(if grep -q '^number=68$' "$GH_CLOSE_CALLS_FILE"; then echo yes; else echo no; fi)"
assert_eq "…and logs memory-throttle-retired" \
  "1" "$(grep -c '^memory-throttle-retired' "$events_file" 2>/dev/null)"

# --- the label-less fallback must not mistake an open `pw::decision`
# decision-log issue for the escalation: it carries the identical
# `` Item: `<ref>` `` footer, but the `<!-- agent-ops:decision-log` marker
# excludes it (agent-ops#2666). ---

GH_ISSUE_LIST_JSON='[]'
# shellcheck disable=SC2016  # the backticks are literal Markdown, not command substitution
GH_ISSUE_LIST_UNLABELLED_JSON='[{"number":69,"url":"https://github.com/acme/agent-ops/issues/69","body":"<!-- agent-ops:decision-log item=memory-throttled:test-node repo=acme/agent-ops reason_key=k -->\n\n---\nItem: `memory-throttled:test-node` · decided by the pipeline"}]'
: > "$GH_CLOSE_CALLS_FILE"; : > "$events_file"
memory_throttle_retire_resolved "acme/agent-ops" "test-node" "20261017T000000Z-test-node-8"
assert_eq "an open decision-log issue is never closed as the escalation" \
  "0" "$(wc -l < "$GH_CLOSE_CALLS_FILE" | tr -d ' ')"
assert_eq "…and nothing is logged as retired" \
  "0" "$(grep -c '^memory-throttle-retired' "$events_file" 2>/dev/null)"
GH_ISSUE_LIST_UNLABELLED_JSON=''

printf '\n'
if (( failures )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
