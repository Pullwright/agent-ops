#!/usr/bin/env bash
#
# test/check-brace-default-trap.test.sh — the permanent CI guard against the
# bash `${var:-word}` brace-default trap (issue #1035,
# scripts/check-brace-default-trap.sh).
#
# The trap: `${parameter:-word}` closes on the FIRST unquoted closing
# character in `word`, not the one the author meant — so a default word that
# opens with an unescaped `{` or `[` right after `:-` leaves a stray closing
# character sitting outside the substitution, corrupting every non-empty
# value while the empty/unset path composes the intended default by
# accident (agent-ops#933/TD-PPagop-26082816). This exercises the script's
# own file-set (agent-cycle.sh, review-cycle.sh, lib/, scripts/, test/,
# tracked files only) and its clean-tree/finding behaviour.
#
# Run directly: ./test/check-brace-default-trap.test.sh — exit 0 iff all
# passed.
#
# shellcheck disable=SC2016
# Every single-quoted printf format string below that looks like a `${...}`
# expansion is deliberate: it is fixture text being written into a file for
# check-brace-default-trap.sh to scan, not a variable the shell should ever
# expand — expanding it would defeat the fixture.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$SCRIPT_DIR/scripts/check-brace-default-trap.sh"

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

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected NOT to contain: %s\n     actual:   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# Built from parts, never spelled out whole: this file lives under test/,
# which is itself part of the swept set check-brace-default-trap.sh reads
# from git ls-files, so a fixture spelling the trap out literally in this
# file's own source would trip the very check it exercises.
ob='{' cb='}' osb='[' csb=']'
object_trap="${ob}${cb}${cb}"  # what check-brace-default-trap.sh's pattern matches
array_trap="${osb}${csb}${csb}"

repo="$tmp_dir/repo"
mkdir -p "$repo/scripts" "$repo/lib" "$repo/test" "$repo/docs"
cp "$CHECK" "$repo/scripts/check-brace-default-trap.sh"
chmod +x "$repo/scripts/check-brace-default-trap.sh"

printf '#!/usr/bin/env bash\ntrue\n'                        > "$repo/agent-cycle.sh"
printf '#!/usr/bin/env bash\ntrue\n'                        > "$repo/review-cycle.sh"
printf '#!/usr/bin/env bash\nx="${clean:-default}"\n'       > "$repo/lib/clean.sh"

git -C "$repo" init --quiet
git -C "$repo" add -A
git -C "$repo" -c user.email=t@t -c user.name=t commit --quiet -m init

run_check() {
  ( cd "$repo" && ./scripts/check-brace-default-trap.sh 2>&1 )
}

# --- A clean tree passes -----------------------------------------------
out="$(run_check)"; rc=$?
assert_eq "a clean tree exits 0" "0" "$rc"
assert_contains "…and says so" "check-brace-default-trap: clean" "$out"

# --- The literal object-default trap fails the run, wherever it is swept
printf '#!/usr/bin/env bash\n# shellcheck disable=SC2154\nx="${report_json:-%s"\n' \
  "$object_trap" > "$repo/lib/bug.sh"
git -C "$repo" add lib/bug.sh
git -C "$repo" -c user.email=t@t -c user.name=t commit --quiet -m "add bug"

out="$(run_check)"; rc=$?
assert_eq "the object-default trap under lib/ fails the run" "1" "$rc"
assert_contains "the finding names the offending file and line" "lib/bug.sh:3" "$out"
assert_contains "the failure explains the FIRST-unquoted-close rule" \
  "closes on the FIRST unquoted" "$out"
assert_contains "…and points at the spec's Gotchas table entry" \
  "docs/spec/implementation/gotchas.md" "$out"
assert_contains "…naming the row by its issue" "agent-ops#933" "$out"

git -C "$repo" rm --quiet lib/bug.sh
git -C "$repo" -c user.email=t@t -c user.name=t commit --quiet -m "drop bug"

# --- The literal array-default trap fails the run too -------------------
# (Unlike the object form, brackets aren't special to bash's own `${...}`
# parsing, so this needs the real terminating `}` spelled out separately —
# the bug here is the extra bracket producing invalid JSON downstream, not
# an early-terminated expansion.)
printf '#!/usr/bin/env bash\nx="${items_json:-%s}"\n' "$array_trap" > "$repo/scripts/bug2.sh"
git -C "$repo" add scripts/bug2.sh
git -C "$repo" -c user.email=t@t -c user.name=t commit --quiet -m "add bug2"

out="$(run_check)"; rc=$?
assert_eq "the array-default trap under scripts/ fails the run" "1" "$rc"
assert_contains "the finding names the offending file" "scripts/bug2.sh" "$out"

git -C "$repo" rm --quiet scripts/bug2.sh
git -C "$repo" -c user.email=t@t -c user.name=t commit --quiet -m "drop bug2"

# --- agent-cycle.sh and review-cycle.sh at the repo root are swept too --
printf '#!/usr/bin/env bash\nx="${top_json:-%s"\n' "$object_trap" > "$repo/agent-cycle.sh"
git -C "$repo" add agent-cycle.sh
git -C "$repo" -c user.email=t@t -c user.name=t commit --quiet -m "bug at root"

out="$(run_check)"; rc=$?
assert_eq "a trap in agent-cycle.sh at the repo root fails the run" "1" "$rc"
assert_contains "the finding names it" "agent-cycle.sh" "$out"

printf '#!/usr/bin/env bash\ntrue\n' > "$repo/agent-cycle.sh"
git -C "$repo" add agent-cycle.sh
git -C "$repo" -c user.email=t@t -c user.name=t commit --quiet -m "fix root"

# --- A file outside the swept set is not checked -------------------------
printf '`${outside_json:-%s` is not in the swept set.\n' "$object_trap" > "$repo/docs/note.md"
git -C "$repo" add docs/note.md
git -C "$repo" -c user.email=t@t -c user.name=t commit --quiet -m "unswept file"

out="$(run_check)"; rc=$?
assert_eq "a matching pattern outside lib/scripts/test/root is not flagged" "0" "$rc"
assert_not_contains "…and is never mentioned" "docs/note.md" "$out"

git -C "$repo" rm --quiet docs/note.md
git -C "$repo" -c user.email=t@t -c user.name=t commit --quiet -m "drop unswept file"

# --- An untracked file in a swept directory is not checked ---------------
printf '#!/usr/bin/env bash\nx="${untracked_json:-%s"\n' "$object_trap" > "$repo/lib/untracked.sh"
out="$(run_check)"; rc=$?
assert_eq "an untracked file under a swept directory is not flagged" "0" "$rc"
assert_not_contains "…and is never mentioned" "untracked.sh" "$out"
rm -f "$repo/lib/untracked.sh"

printf '\n%s\n' "-----"
if (( failures == 0 )); then
  printf 'check-brace-default-trap.test.sh: all assertions passed\n'
  exit 0
fi
printf 'check-brace-default-trap.test.sh: %d assertion(s) failed\n' "$failures"
exit 1
