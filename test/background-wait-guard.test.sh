#!/usr/bin/env bash
#
# test/background-wait-guard.test.sh — regression test for
# lib/background-wait-guard.sh and scripts/background-wait-guard.sh (issue
# #2778, requirement 4m): the managed PreToolUse hook that mechanically
# denies a Bash call backgrounded with run_in_background: true, and an
# Agent call backgrounded (true or absent — the Agent tool's own default),
# since this single-invocation harness has no later turn to receive either
# one's background completion notification.
#
# Covers both layers: `background_wait_guard_should_deny`/
# `background_wait_guard_main` directly (no process spawned), and the
# installed executable end to end, exactly as Claude Code's own hook runner
# would invoke it — a synthetic PreToolUse JSON payload on stdin, the exit
# code and stderr read back.
#
# No network, no GitHub. Run directly:
#
#   ./test/background-wait-guard.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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

# shellcheck source=lib/background-wait-guard.sh
. "$SCRIPT_DIR/lib/background-wait-guard.sh"

# --- 1. background_wait_guard_should_deny, both tool names -----------------

assert_eq "Bash with run_in_background: true is denied" \
  "deny" \
  "$(background_wait_guard_should_deny Bash '{"run_in_background":true}' && echo deny || echo allow)"
assert_eq "Bash with run_in_background: false is allowed" \
  "allow" \
  "$(background_wait_guard_should_deny Bash '{"run_in_background":false}' && echo deny || echo allow)"
assert_eq "Bash with run_in_background absent is allowed" \
  "allow" \
  "$(background_wait_guard_should_deny Bash '{"command":"ls"}' && echo deny || echo allow)"

assert_eq "Agent with run_in_background: true is denied" \
  "deny" \
  "$(background_wait_guard_should_deny Agent '{"run_in_background":true}' && echo deny || echo allow)"
assert_eq "Agent with run_in_background absent is denied (the tool's own default)" \
  "deny" \
  "$(background_wait_guard_should_deny Agent '{"description":"x"}' && echo deny || echo allow)"
assert_eq "Agent with run_in_background: false is allowed" \
  "allow" \
  "$(background_wait_guard_should_deny Agent '{"run_in_background":false}' && echo deny || echo allow)"
assert_eq "Agent with isolation: remote is denied even with run_in_background: false" \
  "deny" \
  "$(background_wait_guard_should_deny Agent '{"isolation":"remote","run_in_background":false}' && echo deny || echo allow)"
assert_eq "Agent with isolation: remote and run_in_background absent is denied" \
  "deny" \
  "$(background_wait_guard_should_deny Agent '{"isolation":"remote"}' && echo deny || echo allow)"
assert_eq "Agent with isolation: worktree and run_in_background: false is allowed" \
  "allow" \
  "$(background_wait_guard_should_deny Agent '{"isolation":"worktree","run_in_background":false}' && echo deny || echo allow)"

assert_eq "Workflow is always denied" \
  "deny" \
  "$(background_wait_guard_should_deny Workflow '{"script":"export const meta = {}"}' && echo deny || echo allow)"
assert_eq "Workflow with no tool_input at all is still denied" \
  "deny" \
  "$(background_wait_guard_should_deny Workflow '{}' && echo deny || echo allow)"

assert_eq "an unrelated tool name is never denied" \
  "allow" \
  "$(background_wait_guard_should_deny Read '{"run_in_background":true}' && echo deny || echo allow)"

# --- 2. background_wait_guard_main, reading a PreToolUse payload from stdin -

run_main() {
  local payload="$1" out rc
  out="$(printf '%s' "$payload" | background_wait_guard_main 2>&1)"
  rc=$?
  printf '%s|%s' "$rc" "$out"
}

assert_eq "a backgrounded Bash call is denied with a reason naming a foreground retry" \
  "2|true" \
  "$(out="$(run_main '{"tool_name":"Bash","tool_input":{"command":"sleep 1","run_in_background":true}}')"; \
     rc="${out%%|*}"; msg="${out#*|}"; \
     printf '%s|%s' "$rc" "$(grep -qi "run_in_background" <<<"$msg" && echo true || echo false)")"
assert_eq "a foreground Bash call passes silently" \
  "0|" "$(run_main '{"tool_name":"Bash","tool_input":{"command":"ls"}}')"
assert_eq "an Agent call with no run_in_background key is denied" \
  "2" "$(out="$(run_main '{"tool_name":"Agent","tool_input":{"description":"x"}}')"; printf '%s' "${out%%|*}")"
assert_eq "an Agent call explicitly in the foreground passes silently" \
  "0|" "$(run_main '{"tool_name":"Agent","tool_input":{"run_in_background":false}}')"
assert_eq "a tool this hook does not examine passes silently" \
  "0|" "$(run_main '{"tool_name":"Edit","tool_input":{"file_path":"/tmp/x"}}')"
assert_eq "a payload with no tool_input at all is read as an empty object" \
  "0|" "$(run_main '{"tool_name":"Bash"}')"
assert_eq "an Agent payload with no tool_input at all defaults to denied" \
  "2" "$(out="$(run_main '{"tool_name":"Agent"}')"; printf '%s' "${out%%|*}")"
assert_eq "an Agent call with isolation: remote is denied with a reason naming isolation, even with run_in_background: false" \
  "2|true" \
  "$(out="$(run_main '{"tool_name":"Agent","tool_input":{"isolation":"remote","run_in_background":false}}')"; \
     rc="${out%%|*}"; msg="${out#*|}"; \
     printf '%s|%s' "$rc" "$(grep -qi "isolation" <<<"$msg" && echo true || echo false)")"
assert_eq "a backgrounded Workflow call is denied with a reason naming the Workflow tool" \
  "2|true" \
  "$(out="$(run_main '{"tool_name":"Workflow","tool_input":{"script":"export const meta = {}"}}')"; \
     rc="${out%%|*}"; msg="${out#*|}"; \
     printf '%s|%s' "$rc" "$(grep -qi "Workflow tool" <<<"$msg" && echo true || echo false)")"
assert_eq "unparseable stdin is never mistaken for Bash, Agent or Workflow" \
  "0|" "$(run_main 'not json')"

# --- 3. The installed executable, end to end --------------------------------

hook="$SCRIPT_DIR/scripts/background-wait-guard.sh"
assert_eq "the installed hook script is executable" \
  "yes" "$([[ -x "$hook" ]] && echo yes || echo no)"

rc=0
stderr="$(printf '%s' '{"tool_name":"Bash","tool_input":{"run_in_background":true}}' | "$hook" 2>&1 1>/dev/null)" || rc=$?
assert_eq "the executable denies a backgrounded Bash call with exit 2" "2" "$rc"
assert_eq "...and names a foreground retry on stderr" \
  "yes" "$(grep -qi "run_in_background" <<<"$stderr" && echo yes || echo no)"

rc=0
printf '%s' '{"tool_name":"Agent"}' | "$hook" >/tmp/background-wait-guard-test.out 2>&1 || rc=$?
assert_eq "the executable denies a default-backgrounded Agent call with exit 2" "2" "$rc"
rm -f /tmp/background-wait-guard-test.out

rc=0
out="$(printf '%s' '{"tool_name":"Bash","tool_input":{"run_in_background":false}}' | "$hook")" || rc=$?
assert_eq "the executable allows a foreground Bash call with exit 0" "0" "$rc"
assert_eq "...and no output" "" "$out"

rc=0
printf '%s' '{"tool_name":"Agent","tool_input":{"isolation":"remote","run_in_background":false}}' \
  | "$hook" >/tmp/background-wait-guard-test.out 2>&1 || rc=$?
assert_eq "the executable denies an Agent call with isolation: remote, even with run_in_background: false" "2" "$rc"
rm -f /tmp/background-wait-guard-test.out

rc=0
stderr="$(printf '%s' '{"tool_name":"Workflow","tool_input":{"script":"export const meta = {}"}}' | "$hook" 2>&1 1>/dev/null)" || rc=$?
assert_eq "the executable denies a Workflow call with exit 2" "2" "$rc"
assert_eq "...and names the Workflow tool on stderr" \
  "yes" "$(grep -qi "Workflow tool" <<<"$stderr" && echo yes || echo no)"

# --- 4. The shipped managed policy wires this hook in on every tool name ----

policy="$SCRIPT_DIR/deploy/docker/claude-managed-settings.json"
assert_eq "the shipped policy's PreToolUse matcher covers Bash, Agent and Workflow" \
  "Bash|Agent|Workflow" \
  "$(jq -r '.hooks.PreToolUse[0].matcher' "$policy")"
assert_eq "...and points at this installed hook" \
  "/app/scripts/background-wait-guard.sh" \
  "$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$policy")"
assert_eq "...as a command-type hook" \
  "command" \
  "$(jq -r '.hooks.PreToolUse[0].hooks[0].type' "$policy")"

printf '\n%s\n' "----------------------------------------"
if (( failures == 0 )); then
  printf 'All assertions passed.\n'
  exit 0
fi
printf '%d assertion(s) failed.\n' "$failures"
exit 1
