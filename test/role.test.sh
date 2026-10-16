#!/usr/bin/env bash
#
# test/role.test.sh — regression test for lib/role.sh and the role guard in
# both pipeline entry points.
#
# The guard has one job (stop a node that is not the active one from spending)
# and one way to fail badly: to resolve toward "active" when it shouldn't. That
# failure is not silent — it opens duplicate pull requests and pays for them —
# but it is only visible after the money is gone, so the assertions below are
# mostly about the fail-closed direction: every value that is not exactly
# `active` must stand the node down, and a standby tick must leave no trace in
# state_dir for the next snapshot restore to disagree with.
#
# The two end-to-end cases drive the real scripts with stubbed `claude`/`gh`
# binaries and a throwaway HOME, because the guard's placement (before the
# config is read, after the flags are parsed) is as much the requirement as
# its logic. Both scripts' own cleanup still runs regardless of where the
# guard or the disabled-pipeline switch stands a cycle down (agent-ops#2421:
# a node's heartbeat push and the pager's own tick happen unconditionally at
# cycle end), so every invocation below is fully sandboxed, not just
# role-guarded: a throwaway `AGENT_OPS_CONFIG` with `state_repo` blanked out,
# an explicit `NODE_NAME` (never left to fall back to the host/container's
# own), the stub directory first on `PATH` rather than appended, and every
# credential-bearing variable the image sets unset — so a run that reaches
# past the guard can push nothing and claim nothing on any real remote.
#
# No test framework is used (none exists elsewhere in this repo). Run directly:
#
#   ./test/role.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/role.sh
. "$SCRIPT_DIR/lib/role.sh"

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
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# --- role_current / role_is_active ---

unset AGENT_OPS_ROLE
assert_eq "unset is standby" "standby" "$(role_current)"
assert_eq "unset is not active" "no" "$(role_is_active && echo yes || echo no)"

export AGENT_OPS_ROLE=""
assert_eq "empty is standby" "standby" "$(role_current)"

export AGENT_OPS_ROLE="active"
assert_eq "active is active" "yes" "$(role_is_active && echo yes || echo no)"

export AGENT_OPS_ROLE="  Active
"
assert_eq "case and surrounding whitespace are tolerated" "yes" "$(role_is_active && echo yes || echo no)"

# The fail-closed cases: a typo, a near-miss and a value from some other
# vocabulary must all stand down rather than being generously interpreted.
for bad in activ ACTIV3 "active,standby" primary leader true 1 yes; do
  export AGENT_OPS_ROLE="$bad"
  assert_eq "'$bad' is not active" "no" "$(role_is_active && echo yes || echo no)"
done

# --- role_declared ---
#
# The same normalisation without the fail-closed default: what a publisher
# of the fleet's own record needs (scripts/state-sync.sh's heartbeat,
# scripts/publish-dashboard.sh's self row), because "this node is a standby"
# and "this process was told nothing" are different claims, and a peer acts
# on the first of them — lib/pager-invariants.sh's `firing-missed` exempts a
# node whose published role is a standby's (agent-ops#1686).
unset AGENT_OPS_ROLE
assert_eq "unset declares no role at all" "" "$(role_declared)"
export AGENT_OPS_ROLE=""
assert_eq "empty declares no role either" "" "$(role_declared)"
export AGENT_OPS_ROLE="  Active
"
assert_eq "a declared role is normalised, not merely repeated" "active" "$(role_declared)"
export AGENT_OPS_ROLE="activ"
assert_eq "a value that is nobody's role is still reported as itself" "activ" "$(role_declared)"
assert_eq "  ... while the guard still stands the node down on it" "no" \
  "$(role_is_active && echo yes || echo no)"

export AGENT_OPS_ROLE="standby"
assert_contains "standby skip message names the role" "this node is standby" "$(role_skip_message agent-cycle)"
export AGENT_OPS_ROLE="activ"
assert_contains "an unrecognised value diagnoses itself" "AGENT_OPS_ROLE=activ is not a role" "$(role_skip_message agent-cycle)"

# --- End to end, against the real entry points ---
#
# A throwaway HOME makes config.json's ~-relative state_dir (and
# workspace_root) land in the temp tree, so "the tick left nothing behind" is
# an assertion about a directory this test owns. The stub `claude`/`gh`
# satisfy each script's required-binary check without any risk of a real
# invocation: if the guard ever let a cycle through, the stub would fail the
# cycle rather than spend — and every call either stub receives is appended
# to stub_calls, so a run that should have touched neither can be checked
# against an empty log rather than trusted on faith.
fake_home="$tmp_dir/home"
mkdir -p "$fake_home/.local/bin"
stub_calls="$tmp_dir/stub-calls.log"
: > "$stub_calls"
for stub in claude gh; do
  cat > "$fake_home/.local/bin/$stub" <<STUB
#!/bin/sh
printf '%s %s\n' "$stub" "\$*" >> "$stub_calls"
echo "$stub stub: the role guard should have prevented this" >&2
exit 1
STUB
  chmod +x "$fake_home/.local/bin/$stub"
done

# agent-ops#2421: both scripts' own end-of-cycle cleanup (the state-sync
# heartbeat push, the pager's tick) runs regardless of where the guard or the
# disabled-pipeline switch stands a cycle down — reaching that far must still
# be unable to touch anything real. A sandboxed copy of the real config with
# state_repo blanked out makes every write scripts/state-sync.sh or
# lib/claim.sh could make a documented no-op (both already no-op silently
# when state_repo is unset), and an explicit NODE_NAME means neither ever
# falls back to publishing under this host/container's own hostname — the
# exact mechanism that published a pseudo-node from inside a live node
# container. The stub directory goes *first* on PATH, not appended the way
# agent-cycle.sh/review-cycle.sh's own PATH bootstrap deliberately does it,
# so a real claude/gh resolvable earlier on the inherited PATH (true inside
# the node image, where this bug actually surfaced) is never reached either.
sandbox_config="$tmp_dir/config.json"
jq '.state_repo = ""' "$SCRIPT_DIR/config.json" > "$sandbox_config"
sandbox_node_name="role-test-node"

run_guarded() {  # run_guarded <role|-> <script> [args…]
  local role="$1" script="$2"; shift 2
  # Every `-u` must precede every `NAME=VALUE` in `env`'s own argument order
  # — GNU env stops parsing options at the first assignment it sees, so
  # `AGENT_OPS_ROLE=standby -u GH_TOKEN` silently treats `-u` as the command
  # to exec rather than an option.
  local -a seam=(
    -u GH_TOKEN -u GITHUB_TOKEN -u GIT_CONFIG_GLOBAL
    -u PW_GH_TOKEN_BROKER -u PW_GH_DEGRADE_TOKEN
    -u PULLWRIGHT_AUTHOR_APP_ID -u PULLWRIGHT_AUTHOR_INSTALLATION_ID
    -u PULLWRIGHT_AUTHOR_INSTALLATION_IDS -u PULLWRIGHT_AUTHOR_PRIVATE_KEY_PATH
  )
  if [[ "$role" == "-" ]]; then
    seam+=(-u AGENT_OPS_ROLE)
  fi
  seam+=(
    GIT_CONFIG_NOSYSTEM=1 HOME="$fake_home" NODE_NAME="$sandbox_node_name"
    AGENT_OPS_CONFIG="$sandbox_config" PATH="$fake_home/.local/bin:$PATH"
  )
  [[ "$role" == "-" ]] || seam+=(AGENT_OPS_ROLE="$role")
  env "${seam[@]}" "$SCRIPT_DIR/$script" "$@" 2>&1
}

assert_eq "the stub gh is first on PATH, never the image's own" \
  "$fake_home/.local/bin/gh" "$(PATH="$fake_home/.local/bin:$PATH" command -v gh)"

out="$(run_guarded - agent-cycle.sh)"; rc=$?
assert_eq "agent-cycle: no role exits 0" "0" "$rc"
assert_contains "agent-cycle: no role logs a skip" "skipped — this node is standby" "$out"

out="$(run_guarded standby review-cycle.sh)"; rc=$?
assert_eq "review-cycle: standby exits 0" "0" "$rc"
assert_contains "review-cycle: standby logs a skip" "skipped — this node is standby" "$out"

assert_eq "a skipped tick writes no state" "" "$(ls -A "$fake_home/.local/state" 2>/dev/null)"

# The guard must not be the *only* thing standing a node down, and it must not
# stand down a human. Both are checked with the pipeline disabled, which is the
# next stand-down after the guard: reaching it proves the guard let the run
# past, and stops the run before it costs anything.
mkdir -p "$fake_home/.local/state/poetic-agents"
cat > "$fake_home/.local/state/poetic-agents/disabled.json" <<'EOF'
{"reason":"role.test.sh","disabled_at":"2026-07-20T00:00:00Z","expires_at":"forever","by":"test"}
EOF

out="$(run_guarded active agent-cycle.sh --repo Poetic-Poems/poetic)"; rc=$?
assert_eq "agent-cycle: active runs the cycle (reaching the switch)" "0" "$rc"
assert_contains "agent-cycle: active stood down on the switch, not the role" \
  "stand-down" "$(cat "$fake_home/.local/state/poetic-agents/log.jsonl" 2>/dev/null)"

out="$(run_guarded - agent-cycle.sh --once)"; rc=$?
assert_eq "agent-cycle: --once bypasses the guard" "0" "$rc"
assert_contains "agent-cycle: --once reached the switch" "the pipeline is disabled" "$out"

out="$(run_guarded - review-cycle.sh --dry-run)"; rc=$?
assert_eq "review-cycle: --dry-run bypasses the guard" "0" "$rc"
assert_contains "review-cycle: --dry-run reached the switch" "review-stand-down" \
  "$(cat "$fake_home/.local/state/poetic-agents/review-log.jsonl" 2>/dev/null)"

# The switch commands answer on any node: an operator on a standby must still
# be able to ask what the pipeline is doing.
out="$(run_guarded standby agent-cycle.sh --status)"; rc=$?
assert_eq "--status works on a standby node" "0" "$rc"
assert_contains "--status reports the switch" "role.test.sh" "$out"

# agent-ops#2421's own regression: every run above that reached a cycle's own
# cleanup (the "reaching the switch" and "--once"/"--dry-run bypasses the
# guard" cases) still ran the state-sync heartbeat push and a pager tick —
# neither call site may be skipped just because the guard already said no.
# With state_repo blanked out in the sandboxed config, both are a documented
# no-op before either ever reaches `git` or `gh`, so the stub log from every
# invocation above must still be empty: not merely "the stub failed safely",
# but "the stub was never reached at all". Reverting this test's own sandbox
# (state_repo, NODE_NAME, or the prepended PATH) fails this assertion.
assert_eq "no run above pushed or claimed anything on any remote" \
  "" "$(cat "$stub_calls" 2>/dev/null)"

printf '\n%s\n' "----------------------------------------"
if (( failures == 0 )); then
  printf 'All assertions passed.\n'
  exit 0
fi
printf '%d assertion(s) failed.\n' "$failures"
exit 1
