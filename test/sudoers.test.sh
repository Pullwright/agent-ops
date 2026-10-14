#!/usr/bin/env bash
#
# test/sudoers.test.sh — regression test for
# deploy/docker/sudoers-agent-ops' own `env_keep` list (requirement 45e of
# docs/spec/implementation/requirements/every-stage.md). sudo resets a
# stage's environment to exactly what this file names, so a variable missing
# here never reaches a stage no matter what the compose anchor forwards into
# the container — issue #2309 added ANTHROPIC_WORKSPACE_ID and
# ANTHROPIC_CUSTOM_HEADERS to the compose anchor for the
# `anthropic-workspace-id` header, and this pins that they also made it into
# this file's own allowlist, which is the half a compose-only check cannot
# see.
#
# No network, no GitHub, no sudo. Run directly:
#
#   ./test/sudoers.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUDOERS="$SCRIPT_DIR/deploy/docker/sudoers-agent-ops"

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

# The one line that keeps the Claude credential variables across sudo's
# environment reset — grep rather than a full sudoers parse, the same
# precedent test/compose-reconcile.test.sh's own "the wiring" section sets
# for pinning a line in a file this suite does not otherwise parse.
claude_env_keep_line="$(grep -E '^Defaults!/usr/local/libexec/agent-ops/stage-exec env_keep \+= "ANTHROPIC_API_KEY ' "$SUDOERS")"

assert_eq "the Claude env_keep line is present" "1" \
  "$([[ -n "$claude_env_keep_line" ]] && echo 1 || echo 0)"
assert_eq "...and keeps ANTHROPIC_WORKSPACE_ID across sudo's reset" "1" \
  "$(grep -c 'ANTHROPIC_WORKSPACE_ID' <<<"$claude_env_keep_line")"
assert_eq "...and keeps ANTHROPIC_CUSTOM_HEADERS across sudo's reset" "1" \
  "$(grep -c 'ANTHROPIC_CUSTOM_HEADERS' <<<"$claude_env_keep_line")"

# visudo, when it is on this host, is the authoritative syntax check — the
# same one deploy/docker/Dockerfile runs at build time (line 434) — so this
# runs it too rather than trusting the grep above to mean the file still
# parses. Skipped, not failed, where visudo is absent (the host, not the
# image).
if command -v visudo >/dev/null 2>&1; then
  visudo_rc=0
  visudo -c -f "$SUDOERS" >/dev/null 2>&1 || visudo_rc=$?
  assert_eq "visudo -c accepts the file" "0" "$visudo_rc"
else
  printf 'skip - visudo is not on this host\n'
fi

printf '\n%s\n' "----------------------------------------"
if (( failures == 0 )); then
  printf 'All assertions passed.\n'
  exit 0
fi
printf '%d assertion(s) failed.\n' "$failures"
exit 1
