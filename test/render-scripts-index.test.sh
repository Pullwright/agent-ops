#!/usr/bin/env bash
#
# test/render-scripts-index.test.sh — self-contained regression test for
# scripts/render-scripts-index.sh (issue #2097).
#
# Runs the actual shipped script (copied byte-for-byte into a scratch
# "repository" built from fixture lib/ and scripts/ files) rather than a
# reimplementation of its logic, so this test exercises the real header-
# comment extraction, the real marker-pair validation and the real --check
# diffing.
#
# No test framework is used (none exists elsewhere in this repo); this is a
# plain bash script with hand-rolled assertions. Run it directly:
#
#   ./test/render-scripts-index.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

failures=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; failures=$(( failures + 1 )); }
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$desc"
  else
    printf 'FAIL - %s\n     expected: %s\n     actual:   %s\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:               %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/scripts" "$tmp/lib" "$tmp/docs/reference"
cp "$SCRIPT_DIR/scripts/render-scripts-index.sh" "$tmp/scripts/render-scripts-index.sh"
cp "$SCRIPT_DIR/lib/markdown-scan.sh" "$tmp/lib/markdown-scan.sh"
chmod +x "$tmp/scripts/render-scripts-index.sh"

# --- Fixture scripts: a plain one, one with a leading shellcheck-disable
#     paragraph to skip, one whose first paragraph has no dash (a usage
#     line), one wrapped so that it splits a token at the token's own hyphen
#     and underscore, and a Python one with a docstring. ---
cat > "$tmp/lib/alpha.sh" <<'SH'
#!/usr/bin/env bash
#
# lib/alpha.sh — the alpha fixture, plain and simple.
#
# A second paragraph that must not appear in the index.
SH

cat > "$tmp/lib/beta.sh" <<'SH'
#!/usr/bin/env bash
# shellcheck disable=SC2034  # beta's own globals are read elsewhere.
#
# lib/beta.sh — the beta fixture, behind a shellcheck preamble.
SH

cat > "$tmp/scripts/gamma.sh" <<'SH'
#!/usr/bin/env bash
#
# gamma.sh <owner/repo> [--flag]
#
# The real description, in a second paragraph the script does not index.
SH

cat > "$tmp/scripts/epsilon.sh" <<'SH'
#!/usr/bin/env bash
#
# scripts/epsilon.sh — the epsilon fixture, wrapped so that run_through_
# finishing_phase and classifier-
# escape each break a token at its own separator, while a punctuation dash -
# and a trailing slash in lib/
# scripts/ do not.
SH

cat > "$tmp/scripts/delta.py" <<'PY'
#!/usr/bin/env python3
"""delta.py — the delta fixture, a Python docstring.

A second paragraph that must not appear in the index.
"""
PY

cat > "$tmp/docs/reference/scripts.md" <<'MD'
# Fixture scripts reference

<!-- scripts-index:start -->
<!-- scripts-index:end -->
MD

run_script() {
  (cd "$tmp" && ./scripts/render-scripts-index.sh "$@")
}

# --- Regenerate: every fixture file appears, grouped by directory, beta's
#     lint-directive preamble skipped, the Python docstring handled. ---
run_script >/dev/null 2>&1
assert_eq "regeneration exits 0" "0" "$?"

content="$(cat "$tmp/docs/reference/scripts.md")"
assert_contains "lib/ group heading present" "$content" "### Libraries: \`lib/\`"
assert_contains "scripts/ group heading present" "$content" "### Entry points: \`scripts/\`"
assert_contains "alpha's first paragraph, filename stripped" "$content" "| \`lib/alpha.sh\` | the alpha fixture, plain and simple. |"
if [[ "$content" == *"must not appear in the index"* ]]; then
  fail "no fixture's second paragraph leaks into the index"
else
  pass "no fixture's second paragraph leaks into the index"
fi
assert_contains "beta's shellcheck preamble is skipped in favour of its real paragraph" "$content" "| \`lib/beta.sh\` | the beta fixture, behind a shellcheck preamble. |"
assert_contains "gamma's usage-line paragraph is used verbatim (no dash to strip)" "$content" "| \`scripts/gamma.sh\` | <owner/repo> [--flag] |"
assert_contains "delta's Python docstring paragraph is indexed" "$content" "| \`scripts/delta.py\` | the delta fixture, a Python docstring. |"
# A wrapped header comment that breaks a token at its own hyphen or
# underscore rejoins without a space, so the index prints the token rather
# than a word cut in half; a hyphen or slash used as punctuation, with a
# space before it or a non-alphanumeric, keeps its space.
assert_contains "epsilon's underscore-split and hyphen-split tokens rejoin without a space" "$content" \
  "the epsilon fixture, wrapped so that run_through_finishing_phase and classifier-escape each break a token at its own separator, while a punctuation dash - and a trailing slash in lib/ scripts/ do not."

# --- A freshly regenerated tree checks clean. ---
run_script --check >/dev/null 2>&1
assert_eq "--check is clean immediately after regeneration" "0" "$?"

# --- A hand edit inside the region is caught. ---
sed -i 's/plain and simple/HAND-EDITED/' "$tmp/docs/reference/scripts.md"
stale_out="$(run_script --check 2>&1)"
stale_rc=$?
if (( stale_rc != 0 )); then
  pass "--check refuses a hand-edited row"
else
  fail "--check refuses a hand-edited row (got rc=0)"
fi
assert_contains "the stale error names the file" "$stale_out" "docs/reference/scripts.md"
run_script >/dev/null 2>&1

# --- A new script with no header comment at all fails loudly, not silently. ---
cat > "$tmp/lib/no-header.sh" <<'SH'
set -euo pipefail
echo "no header comment here"
SH
noheader_out="$(run_script 2>&1)"
noheader_rc=$?
if (( noheader_rc != 0 )); then
  pass "a script with no header-comment paragraph fails the render"
else
  fail "a script with no header-comment paragraph fails the render (got rc=0)"
fi
assert_contains "the no-header error names the file" "$noheader_out" "lib/no-header.sh"
rm "$tmp/lib/no-header.sh"

# --- Missing marker pair is refused, not silently copied through. ---
cat > "$tmp/docs/reference/scripts.md" <<'MD'
# Fixture scripts reference, no markers at all
MD
nomark_out="$(run_script --check 2>&1)"
nomark_rc=$?
if (( nomark_rc != 0 )); then
  pass "--check refuses a file with no marker pair"
else
  fail "--check refuses a file with no marker pair (got rc=0)"
fi
assert_contains "the no-marker error names the file" "$nomark_out" "docs/reference/scripts.md"

echo
if (( failures == 0 )); then
  echo "render-scripts-index.test.sh: all assertions passed"
  exit 0
else
  echo "render-scripts-index.test.sh: $failures assertion(s) failed"
  exit 1
fi
