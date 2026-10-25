#!/usr/bin/env bash
#
# test/git-identity.test.sh — regression test for lib/git-identity.sh
# (issue #1148, issue #76): the sole guard that stops an unattended cycle
# from committing under no git identity or the wrong one.
#
# Two shapes, matching the acceptance criteria:
#   - either GIT_USER_NAME or GIT_USER_EMAIL unset: require_git_identity
#     fails closed — exits 1, with an error on stderr, and sets no global
#     git identity at all.
#   - both set: it writes exactly those values to the global git config
#     (isolated to a scratch GIT_CONFIG_GLOBAL file so this test never
#     touches the real one), read back with `git config --global`.
#
# Run directly:
#
#   ./test/git-identity.test.sh
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

# shellcheck source=lib/git-identity.sh
. "$SCRIPT_DIR/lib/git-identity.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

scratch_config="$tmp_dir/gitconfig"

# --- the failure path: either var missing refuses to commit under anything ---

run_identity() {  # [ENV_ASSIGNMENTS...] — invoke require_git_identity in a
                   # subshell isolated from this test's own real environment
                   # and global git config
  # shellcheck disable=SC2016  # the single quotes are deliberate: "$0" below
  # is the inner bash's own positional arg, not this shell's expansion
  env -u GIT_USER_NAME -u GIT_USER_EMAIL GIT_CONFIG_GLOBAL="$scratch_config" \
    "$@" bash -c '. "$0/lib/git-identity.sh"; require_git_identity test' "$SCRIPT_DIR"
}

rm -f "$scratch_config"
out="$(run_identity 2>&1)"; rc=$?
assert_eq "both unset: exits non-zero" "1" "$rc"
assert_eq "both unset: prints an error" "yes" \
  "$(printf '%s' "$out" | grep -qF 'ERROR' && echo yes || echo no)"
assert_eq "both unset: sets no global identity" "" \
  "$(git config --file "$scratch_config" user.name 2>/dev/null || true)"

rm -f "$scratch_config"
out="$(run_identity GIT_USER_NAME='Example Bot' 2>&1)"; rc=$?
assert_eq "email unset: exits non-zero" "1" "$rc"
assert_eq "email unset: prints an error" "yes" \
  "$(printf '%s' "$out" | grep -qF 'ERROR' && echo yes || echo no)"
assert_eq "email unset: sets no global identity" "" \
  "$(git config --file "$scratch_config" user.name 2>/dev/null || true)"

rm -f "$scratch_config"
out="$(run_identity GIT_USER_EMAIL='bot@example.com' 2>&1)"; rc=$?
assert_eq "name unset: exits non-zero" "1" "$rc"
assert_eq "name unset: prints an error" "yes" \
  "$(printf '%s' "$out" | grep -qF 'ERROR' && echo yes || echo no)"
assert_eq "name unset: sets no global identity" "" \
  "$(git config --file "$scratch_config" user.name 2>/dev/null || true)"

# --- the success path: both set writes exactly those values, globally ---

rm -f "$scratch_config"
out="$(run_identity GIT_USER_NAME='Example Bot' GIT_USER_EMAIL='bot@example.com' 2>&1)"; rc=$?
assert_eq "both set: exits zero" "0" "$rc"
assert_eq "both set: writes the given user.name" "Example Bot" \
  "$(git config --file "$scratch_config" user.name)"
assert_eq "both set: writes the given user.email" "bot@example.com" \
  "$(git config --file "$scratch_config" user.email)"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
