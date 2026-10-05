#!/usr/bin/env bash
#
# test/markdown-scan.test.sh — lib/markdown-scan.sh's `markdown_unfenced`, the
# one fence-aware reading of Markdown that scripts/render-toc.sh (requirement
# 52), the documentation benchmark's source check (requirement 52a) and
# scripts/check-docs.sh (requirement 52b) share, and its numbered form.
#
# A fence the scanner gets wrong does not fail loudly: it hides every heading
# and label after it, or lets a line of code count as one. So each way a fence
# can be misread is a case here.
#
# Run directly: ./test/markdown-scan.test.sh — exit 0 iff all passed.
#
# shellcheck disable=SC2016
# The backticks in this file are literal Markdown fences, never command
# substitution.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/markdown-scan.sh
. "$SCRIPT_DIR/lib/markdown-scan.sh"

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

# unfenced TEXT — the lines of TEXT the scanner keeps, joined with `|`.
unfenced() {
  printf '%s\n' "$1" >"$tmp_dir/doc.md"
  markdown_unfenced "$tmp_dir/doc.md" | paste -sd'|' -
}

assert_eq "prose passes through, fences and their content do not" "a|d" \
  "$(unfenced $'a\n```bash\nb\nc\n```\nd')"
assert_eq "a tilde fence is a fence" "a|d" \
  "$(unfenced $'a\n~~~\n## b\n~~~\nd')"
assert_eq "a tilde line inside a backtick fence leaves it open" "a|e" \
  "$(unfenced $'a\n```\n~~~\n## b\n```\ne')"
assert_eq "a backtick line inside a tilde fence leaves it open" "a|e" \
  "$(unfenced $'a\n~~~\n```\n## b\n~~~\ne')"
assert_eq "a shorter run does not close a longer fence" "a|e" \
  "$(unfenced $'a\n````\n```\n## b\n````\ne')"
assert_eq "a longer run does close a shorter fence" "a|d" \
  "$(unfenced $'a\n```\nb\n`````\nd')"
assert_eq "a closing run followed by text does not close" "a|e" \
  "$(unfenced $'a\n```\n``` not yet\nb\n```\ne')"
assert_eq "an indented fence, as inside a list item, is a fence" "1. item|after" \
  "$(unfenced $'1. item\n   ```bash\n   9. not a label\n   ```\nafter')"
assert_eq "a backtick run with another backtick on its line is inline code" \
  '``` x ``` is prose|b' \
  "$(unfenced $'``` x ``` is prose\nb')"
assert_eq "an unterminated fence runs to the end of the file" "a" \
  "$(unfenced $'a\n```\n## b\nc')"
assert_eq "two backticks are not a fence" '``x``|b' \
  "$(unfenced $'``x``\nb')"
assert_eq "a fence closes in a file with CRLF line endings, and no line keeps its CR" "a|## c" \
  "$(unfenced $'a\r\n```\r\nb\r\n```\r\n## c\r')"

# markdown_unfenced_numbered keeps the same lines, each tagged with its own
# line number in the file, so a reader can go back to the file's own bytes.
printf '%s\n' $'a\n```\nb\n```\nd' >"$tmp_dir/doc.md"
assert_eq "the numbered reading keeps the same lines, with their line numbers" $'1\ta|5\td' \
  "$(markdown_unfenced_numbered "$tmp_dir/doc.md" | paste -sd'|' -)"

if (( failures > 0 )); then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf '\nall assertions passed\n'
