#!/usr/bin/env bash
#
# test/render-labels-table.test.sh — self-contained regression test for
# scripts/render-labels-table.sh (issue #2097).
#
# Runs the actual shipped script against this repository's real
# lib/labels.sh and config.schema.json (copied byte-for-byte, so this test
# exercises the real catalogue and the real METADATA_JSON, not a
# reimplementation of either) — only docs/reference/labels.md itself is a
# scratch fixture, since that is the one file this script writes.
#
# No test framework is used (none exists elsewhere in this repo); this is a
# plain bash script with hand-rolled assertions. Run it directly:
#
#   ./test/render-labels-table.test.sh
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
cp "$SCRIPT_DIR/scripts/render-labels-table.sh" "$tmp/scripts/render-labels-table.sh"
cp "$SCRIPT_DIR/lib/markdown-scan.sh" "$tmp/lib/markdown-scan.sh"
cp "$SCRIPT_DIR/lib/labels.sh" "$tmp/lib/labels.sh"
cp "$SCRIPT_DIR/lib/config-schema.sh" "$tmp/lib/config-schema.sh"
cp "$SCRIPT_DIR/lib/stage-budget.sh" "$tmp/lib/stage-budget.sh"
cp "$SCRIPT_DIR/config.schema.json" "$tmp/config.schema.json"
chmod +x "$tmp/scripts/render-labels-table.sh"

cat > "$tmp/docs/reference/labels.md" <<'MD'
# Fixture labels reference

<!-- labels-table:start -->
<!-- labels-table:end -->
MD

run_script() {
  (cd "$tmp" && ./scripts/render-labels-table.sh "$@")
}

# --- Regenerate against the real catalogue: a handful of known, stable
#     labels appear with all four columns filled. ---
run_script >/dev/null 2>&1
assert_eq "regeneration exits 0" "0" "$?"

content="$(cat "$tmp/docs/reference/labels.md")"
assert_contains "table header present" "$content" "| Label | Applied by | Meaning | Removing it does |"
assert_contains 'the fixed blocked label appears, meaning taken from the catalogue' "$content" "| \`blocked\` |"
assert_contains "blocked's own catalogue description appears verbatim" "$content" "Keeps the pipeline from selecting this issue"
assert_contains "the configurable pr_label resolves to its schema example" "$content" "| \`pw::agent\` |"
assert_contains "the review role's own pr_label resolves to its schema example" "$content" "| \`project-review\` |"
assert_contains "a label shared by two roles (pw::pager) appears exactly once" "$content" "| \`pw::pager\` |"
# shellcheck disable=SC2016  # the backticks here are literal Markdown, not command substitution
pager_count=$(grep -c '| `pw::pager` |' <<<"$content")
assert_eq "pw::pager is not duplicated across roles" "1" "$pager_count"

# --- A freshly regenerated tree checks clean. ---
run_script --check >/dev/null 2>&1
assert_eq "--check is clean immediately after regeneration" "0" "$?"

# --- A hand edit inside the region is caught. ---
sed -i 's/Keeps the pipeline from selecting this issue/HAND-EDITED/' "$tmp/docs/reference/labels.md"
stale_out="$(run_script --check 2>&1)"
stale_rc=$?
if (( stale_rc != 0 )); then
  pass "--check refuses a hand-edited row"
else
  fail "--check refuses a hand-edited row (got rc=0)"
fi
assert_contains "the stale error names the file" "$stale_out" "docs/reference/labels.md"
run_script >/dev/null 2>&1

# --- A label the catalogue returns with no METADATA_JSON entry fails the
#     render loudly, rather than rendering a blank cell. ---
sed -i '/"pw::pager": {/,/},/d' "$tmp/scripts/render-labels-table.sh"
nometa_out="$(run_script 2>&1)"
nometa_rc=$?
if (( nometa_rc != 0 )); then
  pass "a catalogue label missing from METADATA_JSON fails the render"
else
  fail "a catalogue label missing from METADATA_JSON fails the render (got rc=0)"
fi
assert_contains "the missing-metadata error names the label" "$nometa_out" "pw::pager"

# --- Missing marker pair is refused, not silently copied through. ---
cp "$SCRIPT_DIR/scripts/render-labels-table.sh" "$tmp/scripts/render-labels-table.sh"
chmod +x "$tmp/scripts/render-labels-table.sh"
cat > "$tmp/docs/reference/labels.md" <<'MD'
# Fixture labels reference, no markers at all
MD
nomark_out="$(run_script --check 2>&1)"
nomark_rc=$?
if (( nomark_rc != 0 )); then
  pass "--check refuses a file with no marker pair"
else
  fail "--check refuses a file with no marker pair (got rc=0)"
fi
assert_contains "the no-marker error names the file" "$nomark_out" "docs/reference/labels.md"

echo
if (( failures == 0 )); then
  echo "render-labels-table.test.sh: all assertions passed"
  exit 0
else
  echo "render-labels-table.test.sh: $failures assertion(s) failed"
  exit 1
fi
