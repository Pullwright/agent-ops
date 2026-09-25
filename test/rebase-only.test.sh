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

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
