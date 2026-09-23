#!/usr/bin/env bash
#
# test/check-changelog-section.test.sh — regression test for
# scripts/check-changelog-section.sh (requirement 25c, roadmap decision D27):
# the deterministic check that a pull-request description's `## Changelog`
# section is present where the title owes one and well-formed wherever it is
# present.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/check-changelog-section.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$SCRIPT_DIR/scripts/check-changelog-section.sh"

failures=0
NL=$'\n'

assert_pass() {  # assert_pass DESC BODY [TITLE]
  local desc="$1" body="$2" title="${3:-}" err
  if err="$("$CHECK" "$body" "$title" 2>&1 >/dev/null)"; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s (expected exit 0)\n     stderr: %s\n' "$desc" "$err"
    failures=$(( failures + 1 ))
  fi
}

assert_fail() {  # assert_fail DESC BODY [NEEDLE] [TITLE]
  local desc="$1" body="$2" needle="${3:-}" title="${4:-}" err
  err="$("$CHECK" "$body" "$title" 2>&1 >/dev/null)"
  if "$CHECK" "$body" "$title" >/dev/null 2>&1; then
    printf 'FAIL - %s (expected non-zero exit)\n' "$desc"
    failures=$(( failures + 1 ))
    return
  fi
  if [[ "$err" != *"::error::"* ]]; then
    printf 'FAIL - %s\n     expected a ::error:: workflow-command line on stderr\n     actual:   %s\n' \
      "$desc" "$err"
    failures=$(( failures + 1 ))
    return
  fi
  if [[ -n "$needle" && "$err" != *"$needle"* ]]; then
    printf 'FAIL - %s\n     expected stderr to contain: %s\n     actual:   %s\n' \
      "$desc" "$needle" "$err"
    failures=$(( failures + 1 ))
    return
  fi
  printf 'ok   - %s\n' "$desc"
}

FIXED="## Changelog${NL}${NL}### Fixed${NL}${NL}- The rework panel no longer double-counts a killed cycle.${NL}"
NONE="## Changelog${NL}${NL}None.${NL}"

# --- Usage ---------------------------------------------------------------------
"$CHECK" >/dev/null 2>&1; rc=$?
if (( rc == 2 )); then printf 'ok   - no arguments at all is a usage error (exit 2)\n'; else
  printf 'FAIL - no arguments at all should exit 2, got %s\n' "$rc"; failures=$(( failures + 1 )); fi

# --- Which titles owe a section ------------------------------------------------
assert_pass "no section, chore title" "Routine housekeeping." "chore: tidy the fixtures"
assert_pass "no section, no title (the title rule is skipped)" "Anything at all."
assert_pass "no section, docs title" "Prose only." "docs: reword the README"
assert_pass "no section, refactor title" "No behaviour change." "refactor(lib): extract a helper"
assert_pass "no section, Dependabot's build(deps) title" "Bumps x from 1 to 2." "build(deps): bump x from 1.0.0 to 2.0.0"
assert_pass "no section, Dependabot's chore(deps) title" "Bumps y." "chore(deps): Bump y from 1 to 2"
assert_pass "no section, a title commit-format would reject owes nothing here" "Whatever." "Update stuff"
assert_fail "no section, fix title owes one" "Fixes the thing." "owes a \`## Changelog\` section" "fix(dashboard): stop double-counting"
assert_fail "no section, feat title owes one" "Adds the thing." "owes a" "feat: add a panel"
assert_fail "no section, perf title owes one" "Faster." "owes a" "perf(gather): cache the listing"
assert_fail "no section, fix title with no scope owes one" "Fixes." "owes a" "fix: a bare fix"
assert_fail "no section, breaking refactor owes one" "Renames a flag." "breaking change" "refactor!: rename the flag"
assert_fail "no section, breaking scoped chore owes one" "Drops a key." "owes a" "chore(config)!: drop a key"
assert_fail "empty body, fix title owes one" "" "owes a" "fix: something"

# --- Well-formed sections ------------------------------------------------------
assert_pass "one category with one bullet, fix title" "$FIXED" "fix(dashboard): stop double-counting"
assert_pass "one category with one bullet, chore title (present, so checked; fine)" "$FIXED" "chore: whatever"
assert_pass "None. with a fix title" "$NONE" "fix: internal only"
assert_pass "None without a full stop" "## Changelog${NL}${NL}None${NL}" "fix: internal only"
assert_pass "None. followed by a reason on the same line" "## Changelog${NL}None. A test-only fix.${NL}" "fix: internal only"
assert_pass "None. followed by a reason on the next line" "## Changelog${NL}${NL}None.${NL}${NL}The change is not visible to an operator.${NL}" "fix: internal only"
assert_pass "two categories, each with a bullet" \
  "## Changelog${NL}${NL}### Added${NL}${NL}- A thing.${NL}${NL}### Fixed${NL}${NL}- Another thing.${NL}" "feat: add and fix"
assert_pass "a bullet with an indented continuation line" \
  "## Changelog${NL}### Fixed${NL}- A bullet that runs on${NL}  to a second line.${NL}" "fix: wrap"
assert_pass "a nested bullet under an open bullet" \
  "## Changelog${NL}### Changed${NL}- Parent.${NL}  - Child.${NL}" "fix: nest"
assert_pass "asterisk bullets" "## Changelog${NL}### Removed${NL}* Gone.${NL}" "feat!: remove"
assert_pass "no blank line between the heading and the category" "## Changelog${NL}### Added${NL}- X.${NL}" "feat: tight"
assert_pass "trailing spaces on the category heading" "## Changelog${NL}### Fixed   ${NL}- X.${NL}" "fix: spaces"
assert_pass "section at the very end without a trailing newline" "Intro.${NL}${NL}## Changelog${NL}### Fixed${NL}- X." "fix: eof"
assert_pass "CRLF line endings" $'## Changelog\r\n\r\n### Fixed\r\n\r\n- X.\r\n' "fix: crlf"
assert_pass "a following level-two heading ends the section" \
  "## Changelog${NL}### Fixed${NL}- X.${NL}${NL}## Checklist${NL}${NL}- [ ] an unrelated checklist item${NL}loose prose here is fine${NL}" "fix: ends"
assert_pass "a following level-one heading ends the section" \
  "## Changelog${NL}### Fixed${NL}- X.${NL}# Notes${NL}loose prose${NL}" "fix: ends at h1"
assert_pass "a single-line HTML comment inside the section is ignored" \
  "## Changelog${NL}<!-- remember the audience -->${NL}### Fixed${NL}- X.${NL}" "fix: comment"
assert_pass "a multi-line HTML comment inside the section is ignored" \
  "## Changelog${NL}<!-- one${NL}## not a heading${NL}two -->${NL}### Fixed${NL}- X.${NL}" "fix: long comment"
assert_pass "a fenced td-record block after the section does not disturb it" \
  "## Changelog${NL}### Fixed${NL}- X.${NL}${NL}\`\`\`td-record${NL}## not a heading${NL}issue: 1${NL}\`\`\`${NL}" "fix: td"
assert_pass "the section heading inside a fenced block is not a section (chore title)" \
  "Example:${NL}${NL}\`\`\`markdown${NL}## Changelog${NL}### Fixed${NL}\`\`\`${NL}" "chore: show the shape"
assert_pass "the section heading inside a tilde fence is not a section either" \
  "~~~${NL}## Changelog${NL}~~~${NL}" "docs: show it"

# --- Malformed sections --------------------------------------------------------
assert_fail "the fenced example does not satisfy a fix title" \
  "\`\`\`${NL}## Changelog${NL}### Fixed${NL}- X.${NL}\`\`\`${NL}" "owes a" "fix: fenced only"
assert_fail "an empty section" "## Changelog${NL}${NL}" "is empty" "fix: empty"
assert_fail "an empty section with a chore title is still a fault (present, so checked)" "## Changelog${NL}" "is empty" "chore: left the template heading"
assert_fail "a section holding only a comment is empty" "## Changelog${NL}<!-- fill me in -->${NL}" "is empty" "fix: template"
assert_fail "lowercase heading is detected, so its empty content is a fault" "## changelog${NL}" "is empty" "chore: case"
assert_fail "an unknown category" "## Changelog${NL}### Fixes${NL}- X.${NL}" "not a Keep a Changelog category" "fix: plural"
assert_fail "a lowercase category is not the exact spelling" "## Changelog${NL}### fixed${NL}- X.${NL}" "not a Keep a Changelog category" "fix: case"
assert_fail "a category with no bullet" "## Changelog${NL}### Fixed${NL}${NL}### Added${NL}- X.${NL}" "\`### Fixed\` in the \`## Changelog\` section has no bullet" "fix: hollow"
assert_fail "the last category with no bullet" "## Changelog${NL}### Fixed${NL}- X.${NL}### Added${NL}" "\`### Added\` in the \`## Changelog\` section has no bullet" "fix: hollow tail"
assert_fail "a duplicated category" "## Changelog${NL}### Fixed${NL}- X.${NL}### Fixed${NL}- Y.${NL}" "appears more than once" "fix: twice"
assert_fail "loose prose under a category" "## Changelog${NL}### Fixed${NL}- X.${NL}Also, some prose.${NL}" "neither a \`- \` bullet nor an indented continuation" "fix: prose"
assert_fail "an indented line before any bullet" "## Changelog${NL}### Fixed${NL}  indented first${NL}- X.${NL}" "indented but no bullet precedes it" "fix: indent"
assert_fail "a deeper heading under a category" "## Changelog${NL}### Fixed${NL}- X.${NL}#### Details${NL}" "neither a" "fix: h4"
assert_fail "prose as the first line" "## Changelog${NL}We fixed a thing.${NL}" "must be a \`### <Category>\` heading or the line \`None.\`" "fix: prose first"
assert_fail "a bullet as the first line, without a category" "## Changelog${NL}- X.${NL}" "must be a" "fix: bullet first"
assert_fail "Nonetheless is not None" "## Changelog${NL}Nonetheless, a fix.${NL}" "must be a" "fix: nonetheless"
assert_fail "None plus a category" "## Changelog${NL}None.${NL}### Added${NL}- X.${NL}" "says \`None\` but also carries" "fix: both"
assert_fail "None plus a bullet" "## Changelog${NL}None.${NL}- X.${NL}" "says \`None\` but also carries a bullet" "fix: both bullet"
assert_fail "two section headings" "## Changelog${NL}### Fixed${NL}- X.${NL}## Changelog${NL}None.${NL}" "more than one" "fix: twice over"

# --- One fault reports once; several distinct faults each report ---------------
err="$("$CHECK" "## Changelog${NL}### Fixes${NL}### Nope${NL}" "fix: many" 2>&1 >/dev/null)"
count="$(grep -c '::error::' <<<"$err")"
if (( count == 4 )); then printf 'ok   - two unknown categories, each hollow, report four faults, one per line\n'; else
  printf 'FAIL - expected four ::error:: lines, got %s:\n%s\n' "$count" "$err"; failures=$(( failures + 1 )); fi
err="$("$CHECK" "## Changelog${NL}We fixed it.${NL}- and this${NL}### Fixed${NL}" "fix: cascade" 2>&1 >/dev/null)"
count="$(grep -c '::error::' <<<"$err")"
if (( count == 1 )); then printf 'ok   - a fault on the first line swallows the rest of the section (no cascade)\n'; else
  printf 'FAIL - expected one ::error:: line after a first-line fault, got %s:\n%s\n' "$count" "$err"; failures=$(( failures + 1 )); fi

if (( failures > 0 )); then
  printf '\n%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf '\nall assertions passed\n'
