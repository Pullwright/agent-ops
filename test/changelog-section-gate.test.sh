#!/usr/bin/env bash
#
# test/changelog-section-gate.test.sh — regression test for
# lib/changelog-section-gate.sh (requirement 25c, agent-ops#1808), on
# test/closing-keyword-gate.test.sh's own pattern.
#
# `gh` is stubbed through CHANGELOG_SECTION_GATE_GH, the same convention
# test/closing-keyword-gate.test.sh's stub uses. The checker itself is
# exercised end to end against the real scripts/check-changelog-section.sh —
# this test is about the gate's own plumbing (does it read the right PR
# fields, does it report `clean`/`dirty<TAB>reason`/`unknown<TAB>reason`
# correctly), not a re-test of the checker's own rules
# (test/check-changelog-section.test.sh already covers those).
#
# The three-way verdict is the point of half of what follows: a fault in the
# pull request is `dirty`, but a question that could not be *put* — an
# unreadable pull request, an unrunnable checker — is `unknown`, so a caller
# warns instead of stalling every item on a node with a degraded `gh`.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/changelog-section-gate.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/changelog-section-gate.sh
. "$SCRIPT_DIR/lib/changelog-section-gate.sh"

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
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:             %s\n' \
      "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

URL="https://github.com/Poetic-Poems/poetic-fiddle/pull/198"

# --- The stub gh --------------------------------------------------------------
# State lives in files:
#   $tmp_dir/pr.json   the `pr view --json body,title` payload;
#                       "ERROR" makes the call fail (unreadable PR).
cat >"$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"

if [[ "$1 $2" == "pr view" ]]; then
  content="$(cat "$d/pr.json" 2>/dev/null || echo '{}')"
  [[ "$content" == "ERROR" ]] && { echo "could not resolve pull request" >&2; exit 1; }
  printf '%s' "$content"
  exit 0
fi

exit 1
STUB
chmod +x "$tmp_dir/gh"
export CHANGELOG_SECTION_GATE_GH="$tmp_dir/gh"

set_pr() { printf '%s' "$1" >"$tmp_dir/pr.json"; }

# --- clean cases -------------------------------------------------------------

set_pr '{"body": "Nothing notable here.", "title": "docs: fix a typo"}'
out="$(changelog_section_gate "$URL")"; rc=$?
assert_eq "a non-owing title with no section: clean" "clean" "$out"
assert_eq "  ... and exits 0" "0" "$rc"

set_pr '{"body": "## Changelog\n\n### Fixed\n\n- Fixed the thing.", "title": "fix: repair the thing"}'
out="$(changelog_section_gate "$URL")"; rc=$?
assert_eq "an owing title with a well-formed section: clean" "clean" "$out"
assert_eq "  ... and exits 0" "0" "$rc"

set_pr '{"body": "## Changelog\n\nNone.", "title": "fix: repair the thing"}'
out="$(changelog_section_gate "$URL")"; rc=$?
assert_eq "an owing title with None.: clean" "clean" "$out"
assert_eq "  ... and exits 0" "0" "$rc"

# --- the regression itself: an owing title with no section is dirty ---------

set_pr '{"body": "Just a description, no heading.", "title": "fix: repair the thing"}'
out="$(changelog_section_gate "$URL")"; rc=$?
assert_eq "  ... exits 1" "1" "$rc"
assert_eq "an owing title with no section is dirty" "dirty" "${out%%$'\t'*}"
assert_contains "  ... naming what is owed" "Changelog" "$out"
assert_eq "  ... on a single line" "1" "$(grep -c '' <<<"$out")"
assert_eq "  ... with no ::error:: workflow-command prefix left in it" \
  "0" "$(grep -c '::error::' <<<"$out")"

# --- a malformed section is dirty too ----------------------------------------

set_pr '{"body": "## Changelog\n\n### NotACategory\n\n- something", "title": "feat: add a thing"}'
out="$(changelog_section_gate "$URL")"; rc=$?
assert_eq "  ... exits 1" "1" "$rc"
assert_eq "an unknown category is dirty" "dirty" "${out%%$'\t'*}"
assert_contains "  ... naming the bad category" "NotACategory" "$out"

# --- gh itself failing to resolve the PR -------------------------------------
# `unknown`, not `dirty`: a `gh` that cannot answer says something about this
# node, not about the pull request, and reading one as the other would stall
# every item on a node with a degraded `gh` (see the file header).

set_pr 'ERROR'
out="$(changelog_section_gate "$URL")"; rc=$?
assert_eq "an unreadable pull request is unknown, not dirty" "unknown" "${out%%$'\t'*}"
assert_eq "  ... and exits 0, so a caller warns rather than blocks" "0" "$rc"
assert_contains "  ... naming the pull request it could not read" "$URL" "$out"

# A payload that parses but carries no title — a truncated or otherwise
# unexpected answer — must not read as clean: an empty title reads to the
# checker as "owes nothing", exactly the shape of a *passing* pull request.
set_pr '{}'
out="$(changelog_section_gate "$URL")"; rc=$?
assert_eq "a payload with no title is unknown, never clean" "unknown" "${out%%$'\t'*}"
assert_eq "  ... and exits 0" "0" "$rc"

set_pr '{"body": "whatever", "title": ""}'
out="$(changelog_section_gate "$URL")"; rc=$?
assert_eq "a payload with an empty-string title is unknown too" "unknown" "${out%%$'\t'*}"
assert_eq "  ... and exits 0" "0" "$rc"

# --- the checker itself unrunnable -------------------------------------------
# Same class again: a missing or non-executable checker is this node's
# checkout, not this pull request.

set_pr '{"body": "Just a description, no heading.", "title": "fix: repair the thing"}'
out="$(CHANGELOG_SECTION_GATE_CHECK="$tmp_dir/not-a-real-checker" changelog_section_gate "$URL")"; rc=$?
assert_eq "an unrunnable checker is unknown, not dirty" "unknown" "${out%%$'\t'*}"
assert_eq "  ... and exits 0" "0" "$rc"

# --- an empty URL is dirty, not a crash --------------------------------------
# The one unanswerable case that stays `dirty`: a caller asking about nothing
# is a bug in the caller, not a degraded node.

out="$(changelog_section_gate "")"; rc=$?
assert_eq "  ... exits 1" "1" "$rc"
assert_eq "no URL at all is dirty" "dirty" "${out%%$'\t'*}"

echo
if (( failures > 0 )); then
  echo "$failures assertion(s) failed"
  exit 1
fi
echo "all assertions passed"
