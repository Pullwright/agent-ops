#!/usr/bin/env bash
#
# test/rebase-only.test.sh — regression test for lib/rebase-only.sh
# (requirements 31e/46a, agent-ops#1806): does a push change anything about
# a pull request's own net content, regardless of whether it authored a new
# commit?
#
# Built against a real, local, throwaway git fixture repository rather than
# stubs — this is pure git plumbing (`git merge-base`, `git diff`, `git
# patch-id`), the same idiom test/merge-conflicts.test.sh's own
# `conflicted_paths` block uses for its dry-run merge. No network, no `gh`.
#
# Three shapes, matching the acceptance criteria:
#   - a clean rebase: the same change replayed onto a base that moved
#     somewhere the change never touches — identical patch, rebase-only.
#   - a manually-authored resolution that reproduces the pre-conflict diff
#     byte-for-byte on the moved base — identical patch, different commit
#     (no rebase ancestry at all), still rebase-only. (A *genuine* same-region
#     text conflict, resolved by keeping both sides, is deliberately not
#     modelled this way here — combining two edits to the same region
#     necessarily changes the diff's own surrounding lines, which
#     `git patch-id` is sensitive to; that shape is exactly the third case
#     below, "a resolution that changes the diff", not a false positive this
#     helper needs to avoid.)
#   - a resolution that changes the diff — not rebase-only.
# Plus the fail-closed contract: an unresolvable ref is never read as
# "unchanged".
#
# Run directly:
#
#   ./test/rebase-only.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/rebase-only.sh
. "$SCRIPT_DIR/lib/rebase-only.sh"

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

repo="$tmp_dir/fixture"
git init -q -b main "$repo"
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test

# --- base: a file the "feature" branch never touches, and one it does. ---
printf 'a\nb\nc\n' > "$repo/shared.txt"
git -C "$repo" add shared.txt
git -C "$repo" commit -q -m base
old_base="$(git -C "$repo" rev-parse HEAD)"

# --- old_head: the "reviewed" state — feature.txt added, shared.txt untouched. ---
git -C "$repo" checkout -q -b feature
printf 'feature content\n' > "$repo/feature.txt"
git -C "$repo" add feature.txt
git -C "$repo" commit -q -m feature
old_head="$(git -C "$repo" rev-parse HEAD)"

# --- new_base: the base moved, touching only shared.txt — feature.txt's own
#     diff has nothing to overlap with. ---
git -C "$repo" checkout -q main
printf 'a\nb\nc\nmain change\n' > "$repo/shared.txt"
git -C "$repo" commit -q -am main-change
new_base="$(git -C "$repo" rev-parse HEAD)"

# --- Scenario 1: a clean rebase — git itself replays old_head onto new_base. ---
git -C "$repo" checkout -q -b rebased "$old_head"
git -C "$repo" rebase -q main >/dev/null
rebased_head="$(git -C "$repo" rev-parse HEAD)"

if rebase_only_push "$repo" "$old_base" "$old_head" "$new_base" "$rebased_head"; then
  assert_eq "a clean rebase reports rebase-only" "true" "true"
else
  assert_eq "a clean rebase reports rebase-only" "true" "false"
fi

# --- Scenario 2: a manually-authored commit reproducing the same diff on the
#     moved base — no rebase ancestry, a different tree history entirely, but
#     the identical net change to feature.txt. Models a conflict resolved by
#     hand (e.g. because a naive patch-apply rebase balked at an unrelated
#     hunk) rather than by `git rebase` itself. ---
git -C "$repo" checkout -q -b resolved main
printf 'feature content\n' > "$repo/feature.txt"
git -C "$repo" add feature.txt
git -C "$repo" commit -q -m "resolve: reproduce the feature change by hand"
resolved_head="$(git -C "$repo" rev-parse HEAD)"

if rebase_only_push "$repo" "$old_base" "$old_head" "$new_base" "$resolved_head"; then
  assert_eq "a manually-authored, diff-identical resolution reports rebase-only" "true" "true"
else
  assert_eq "a manually-authored, diff-identical resolution reports rebase-only" "true" "false"
fi
if [[ "$rebased_head" != "$resolved_head" ]]; then
  assert_eq "the two rebase-only heads are still different commits" "true" "true"
else
  assert_eq "the two rebase-only heads are still different commits" "true" "false"
fi

# --- Scenario 3: a resolution that changes the diff — not rebase-only. ---
git -C "$repo" checkout -q -b changed main
printf 'different feature content\n' > "$repo/feature.txt"
git -C "$repo" add feature.txt
git -C "$repo" commit -q -m "resolve: change the content"
changed_head="$(git -C "$repo" rev-parse HEAD)"

if rebase_only_push "$repo" "$old_base" "$old_head" "$new_base" "$changed_head"; then
  assert_eq "a resolution that changes the diff is not rebase-only" "false" "true"
else
  assert_eq "a resolution that changes the diff is not rebase-only" "false" "false"
fi

# --- Fail-closed: an unresolvable ref is never read as "unchanged". ---
bogus_sha="0000000000000000000000000000000000000123"
if rebase_only_push "$repo" "$old_base" "$bogus_sha" "$new_base" "$rebased_head"; then
  assert_eq "an unreadable old head is never rebase-only" "false" "true"
else
  assert_eq "an unreadable old head is never rebase-only" "false" "false"
fi
bogus_output="$(diff_patch_id "$repo" "$old_base" "$bogus_sha" 2>/dev/null)"
assert_eq "diff_patch_id prints nothing for an unreadable ref" "" "$bogus_output"

# --- rebase_only_forge_capture / rebase_only_forge_check: the same question,
#     asked of the forge rather than of a stage's workspace (requirement 45e).
#     A bare repository stands in for the forge, mapped onto its URL with
#     `insteadOf` in a global configuration of this test's own. It serves
#     objects by id only when a ref reaches them
#     (`uploadpack.allowReachableSHA1InWant`), and between the capture and the
#     check the pull request's branch is force-pushed and the forge pruned, so
#     the old head is gone from it by the time the check runs: what a forge
#     after an Implementer's rebase can be. ---
scratch="$tmp_dir/scratch"
mkdir -p "$scratch"
forge="$tmp_dir/forge.git"
printf '[url "file://%s"]\n\tinsteadOf = https://github.com/acme/widgets.git\n' "$forge" \
  >"$tmp_dir/forge-gitconfig"

as_script() {  # FUNCTION [ARGS...] — run with the forge mapping and scratch
  GIT_CONFIG_GLOBAL="$tmp_dir/forge-gitconfig" TMPDIR="$scratch" "$@"
}

forge_check() {  # PR_HEAD — capture, push PR_HEAD over the branch, then ask
  rm -rf "$forge"
  git init -q --bare "$forge"
  git -C "$forge" config uploadpack.allowFilter true
  git -C "$forge" config uploadpack.allowReachableSHA1InWant true
  git -C "$repo" push -q "$forge" "$old_base:refs/heads/main" "$old_head:refs/heads/pr"
  as_script rebase_only_forge_capture acme/widgets main pr || return 2
  git -C "$repo" push -q -f "$forge" "$new_base:refs/heads/main" "$1:refs/heads/pr"
  git -C "$forge" reflog expire --expire=now --all
  git -C "$forge" gc -q --prune=now
  as_script rebase_only_forge_check main pr
}

forge_check "$rebased_head"; rc=$?
assert_eq "forge check: a clean rebase pushed to the forge reports rebase-only" "0" "$rc"
assert_eq "  ... capturing the old head from the forge" "$old_head" "$rebase_only_old_head"
assert_eq "  ... and the old base" "$old_base" "$rebase_only_old_base"
assert_eq "  ... reading the new head from the forge" "$rebased_head" "$rebase_only_new_head"
assert_eq "  ... and the new base" "$new_base" "$rebase_only_new_base"
assert_eq "  ... although the forge no longer holds the old head" "1" \
  "$(git -C "$forge" cat-file -e "$old_head" 2>/dev/null; echo $?)"
assert_eq "  ... leaving no repository of its own behind" "" "$(ls -A "$scratch")"

forge_check "$changed_head"; rc=$?
assert_eq "forge check: a push that changed the diff is not rebase-only" "1" "$rc"

forge_check "$old_head"; rc=$?
assert_eq "forge check: a head that never moved is not rebase-only" "1" "$rc"

as_script rebase_only_forge_capture acme/widgets main no-such-branch; rc=$?
assert_eq "forge capture: a branch the forge does not have captures nothing" "1" "$rc"
assert_eq "  ... and sets no old head" "" "$rebase_only_old_head"
assert_eq "  ... and leaves no repository behind" "" "$(ls -A "$scratch")"
as_script rebase_only_forge_check main pr; rc=$?
assert_eq "forge check: a check with no capture before it is never rebase-only" "1" "$rc"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
