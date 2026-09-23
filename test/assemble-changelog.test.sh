#!/usr/bin/env bash
#
# test/assemble-changelog.test.sh — regression test for
# scripts/assemble-changelog.sh (issue #1807, roadmap decision D27) and the
# grammar it shares with scripts/check-changelog-section.sh via
# lib/changelog-grammar.sh.
#
# Runs the actual shipped script and library, copied byte-for-byte into a
# scratch git repository built from fixture commits, rather than a
# reimplementation of their logic — the same pattern
# test/merge-conflicts.test.sh and test/render-toc.test.sh already use for a
# script that needs a real git history or a real scratch "repository" to
# exercise honestly.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/assemble-changelog.test.sh
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
assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass "$desc"
  else
    printf 'FAIL - %s\n     expected NOT to contain: %s\n     actual:                   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

repo="$(mktemp -d)"
trap 'rm -rf "$repo"' EXIT

mkdir -p "$repo/scripts" "$repo/lib"
cp "$SCRIPT_DIR/scripts/assemble-changelog.sh" "$repo/scripts/assemble-changelog.sh"
cp "$SCRIPT_DIR/lib/changelog-grammar.sh" "$repo/lib/changelog-grammar.sh"
chmod +x "$repo/scripts/assemble-changelog.sh"

git -C "$repo" init -q -b main
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test

# commit_msg SUBJECT BODY — one throwaway file changed, so every commit is
# real and distinct; the message is what matters.
n=0
commit_msg() {
  local subject="$1" body="$2"
  n=$(( n + 1 ))
  echo "change $n" > "$repo/f$n.txt"
  git -C "$repo" add "f$n.txt" scripts lib >/dev/null 2>&1 || true
  git -C "$repo" add "f$n.txt" >/dev/null
  git -C "$repo" commit -q -m "$(printf '%s\n\n%s\n' "$subject" "$body")"
}

run() (
  cd "$repo" && ./scripts/assemble-changelog.sh "$@"
)

marker_sha() {
  git -C "$repo" rev-parse HEAD
}

# --- Usage / the marker-or-since requirement ----------------------------------
commit_msg "chore: seed" "Nothing notable."
root_sha="$(marker_sha)"

rm -f "$repo/CHANGELOG.md"
out="$(run 2>&1)"; rc=$?
assert_eq "no file, no --since: exit 1" "1" "$rc"
assert_contains "  ... names the missing marker" "$out" "no <!-- changelog:assembled-through --> marker"

out="$(run --bogus-flag 2>&1)"; rc=$?
assert_eq "an unknown flag: exit 2" "2" "$rc"

# --- First run via --since, from nothing --------------------------------------
commit_msg "feat: add a widget (#100)" \
  "$(printf '## Changelog\n\n### Added\n\n- A shiny new widget.\n')"
run --since "$root_sha"
content="$(cat "$repo/CHANGELOG.md")"
assert_contains "first run creates a Keep a Changelog preamble" "$content" "# Changelog"
assert_contains "  ... and the marker" "$content" "<!-- changelog:assembled-through sha="
assert_contains "  ... and the Unreleased heading" "$content" "## [Unreleased]"
assert_contains "  ... with the new Added category" "$content" "### Added"
assert_contains "  ... and the bullet, suffixed with its PR number" "$content" "- A shiny new widget. (#100)"

marked_sha="$(marker_sha)"
assert_contains "the marker names the head it assembled through" "$content" "sha=${marked_sha} -->"

# --- Idempotence: a second run with no new commits changes nothing -----------
before="$(cat "$repo/CHANGELOG.md")"
run
after="$(cat "$repo/CHANGELOG.md")"
assert_eq "a second run with no new commits is byte-identical" "$before" "$after"

out="$(run --check 2>&1)"; rc=$?
assert_eq "--check on an up-to-date file exits 0" "0" "$rc"
assert_eq "  ... and prints nothing" "" "$out"

# --- Range: only commits strictly after the marker are read ------------------
commit_msg "chore: unrelated" "No changelog owed."
commit_msg "fix: stop a crash (#101)" \
  "$(printf '## Changelog\n\n### Fixed\n\n- Stops a crash on startup.\n')"
run
content="$(cat "$repo/CHANGELOG.md")"
assert_contains "a later fix lands under Fixed" "$content" "- Stops a crash on startup. (#101)"
assert_contains "the earlier Added bullet is undisturbed" "$content" "- A shiny new widget. (#100)"

out="$(run --check 2>&1)"; rc=$?
assert_eq "--check is 0 again once caught up" "0" "$rc"

strip_marker() {
  grep -v '^<!-- changelog:assembled-through sha=' <<<"$1"
}

# --- A commit with no changelog owed / None. contributes nothing -------------
commit_msg "docs: reword a comment" "Nothing notable."
commit_msg "chore: tidy" "$(printf '## Changelog\n\nNone.\n')"
before="$(strip_marker "$(cat "$repo/CHANGELOG.md")")"
run
after="$(strip_marker "$(cat "$repo/CHANGELOG.md")")"
assert_eq "a docs commit and a None. commit add no bullets" "$before" "$after"

# --- --check catches a file that is behind HEAD -------------------------------
commit_msg "fix: another bug (#102)" \
  "$(printf '## Changelog\n\n### Fixed\n\n- Fixes another bug.\n')"
out="$(run --check 2>&1)"; rc=$?
assert_eq "--check on a stale file exits 1" "1" "$rc"
assert_contains "  ... and says so" "$out" "behind HEAD"
assert_not_contains "  ... without writing" "$(cat "$repo/CHANGELOG.md")" "Fixes another bug"
run
assert_contains "a plain run afterwards catches it up" "$(cat "$repo/CHANGELOG.md")" "- Fixes another bug. (#102)"

# --- Newest first within a category -------------------------------------------
content="$(cat "$repo/CHANGELOG.md")"
fixed_order="$(printf '%s\n' "$content" | grep -n '^- ' | grep -A2 -B2 "" >/dev/null; printf '%s\n' "$content" | awk '/^### Fixed/{f=1;next} /^### /{f=0} f && /^- /')"
first_fixed="$(printf '%s\n' "$fixed_order" | sed -n '1p')"
assert_contains "the newest Fixed bullet (#102) sorts above the older ones" "$first_fixed" "(#102)"

# --- A bullet that already cites its own PR number is not double-suffixed ----
commit_msg "fix: self-citing bullet (#103)" \
  "$(printf '## Changelog\n\n### Fixed\n\n- Already mentions #103 in its own text.\n')"
run
content="$(cat "$repo/CHANGELOG.md")"
assert_contains "the bullet keeps its own citation" "$content" "- Already mentions #103 in its own text."
assert_not_contains "  ... and gains no second one" "$content" "in its own text. (#103)"

# --- Category ordering follows Keep a Changelog, not commit order ------------
commit_msg "fix: a security one (#104)" \
  "$(printf '## Changelog\n\n### Security\n\n- Closes a hole.\n')"
commit_msg "feat: a changed one (#105)" \
  "$(printf '## Changelog\n\n### Changed\n\n- Behaviour differs now.\n')"
run
content="$(cat "$repo/CHANGELOG.md")"
added_line="$(printf '%s\n' "$content" | grep -n '^### Added$' | head -1 | cut -d: -f1)"
changed_line="$(printf '%s\n' "$content" | grep -n '^### Changed$' | head -1 | cut -d: -f1)"
fixed_line="$(printf '%s\n' "$content" | grep -n '^### Fixed$' | head -1 | cut -d: -f1)"
security_line="$(printf '%s\n' "$content" | grep -n '^### Security$' | head -1 | cut -d: -f1)"
if [[ -n "$added_line" && -n "$changed_line" && -n "$fixed_line" && -n "$security_line" \
      && "$added_line" -lt "$changed_line" && "$changed_line" -lt "$fixed_line" \
      && "$fixed_line" -lt "$security_line" ]]; then
  pass "categories render Added, Changed, ..., Fixed, Security in that order"
else
  fail "categories render Added, Changed, ..., Fixed, Security in that order (got $added_line/$changed_line/$fixed_line/$security_line)"
fi

# --- A fenced example of the heading is not a real section --------------------
fence='```'
commit_msg "docs: explain the convention (#106)" \
  "$(printf 'See the convention:\n\n%s\n## Changelog\n\n### Added\n\n- not real\n%s\n' "$fence" "$fence")"
before="$(strip_marker "$(cat "$repo/CHANGELOG.md")")"
run
after="$(strip_marker "$(cat "$repo/CHANGELOG.md")")"
assert_eq "a fenced example of the heading contributes nothing" "$before" "$after"

# --- A malformed section (loose, unindented prose) contributes nothing -------
commit_msg "fix: a malformed one (#107)" \
  "$(printf '## Changelog\n\n### Fixed\n\n- First line\nunindented continuation, which is loose prose.\n')"
before="$(strip_marker "$(cat "$repo/CHANGELOG.md")")"
run
after="$(strip_marker "$(cat "$repo/CHANGELOG.md")")"
assert_eq "a malformed section is dropped whole, not truncated into the file" "$before" "$after"
assert_not_contains "  ... no half-sentence bullet leaks in" "$after" "First line"

# --- Merging into an existing hand-maintained [Unreleased] section -----------
repo2="$(mktemp -d)"
mkdir -p "$repo2/scripts" "$repo2/lib"
cp "$SCRIPT_DIR/scripts/assemble-changelog.sh" "$repo2/scripts/assemble-changelog.sh"
cp "$SCRIPT_DIR/lib/changelog-grammar.sh" "$repo2/lib/changelog-grammar.sh"
chmod +x "$repo2/scripts/assemble-changelog.sh"
git -C "$repo2" init -q -b main
git -C "$repo2" config user.email test@example.com
git -C "$repo2" config user.name test

cat > "$repo2/CHANGELOG.md" <<'MD'
# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed

- An existing bullet that must survive untouched. (#10)

## [1.0.0] - 2026-01-01

### Added

- Initial release.
MD
git -C "$repo2" add -A
git -C "$repo2" commit -q -m "chore: seed with a released version"
base2="$(git -C "$repo2" rev-parse HEAD)"

echo "x" > "$repo2/g1.txt"
git -C "$repo2" add g1.txt
git -C "$repo2" commit -q -m "$(printf 'feat: add a widget (#200)\n\n## Changelog\n\n### Added\n\n- A brand new widget.\n')"
echo "y" > "$repo2/g2.txt"
git -C "$repo2" add g2.txt
git -C "$repo2" commit -q -m "$(printf 'fix: another crash (#201)\n\n## Changelog\n\n### Fixed\n\n- Fixes another crash.\n  With a continuation line.\n')"

(cd "$repo2" && ./scripts/assemble-changelog.sh --since "$base2")
content2="$(cat "$repo2/CHANGELOG.md")"
assert_contains "a new category is created alongside the existing one" "$content2" "### Added"
assert_contains "  ... with the new bullet" "$content2" "- A brand new widget. (#200)"
assert_contains "the existing category gains the new bullet above the old one" "$content2" "- Fixes another crash."
assert_contains "  ... continuation preserved" "$content2" "  With a continuation line. (#201)"
assert_contains "the pre-existing bullet survives byte-for-byte" "$content2" "- An existing bullet that must survive untouched. (#10)"
assert_contains "the released section is untouched" "$content2" "## [1.0.0] - 2026-01-01"
assert_contains "  ... including its own bullet" "$content2" "- Initial release."

new_pos="$(printf '%s\n' "$content2" | grep -n "Fixes another crash" | cut -d: -f1)"
old_pos="$(printf '%s\n' "$content2" | grep -n "An existing bullet that must survive" | cut -d: -f1)"
if [[ -n "$new_pos" && -n "$old_pos" && "$new_pos" -lt "$old_pos" ]]; then
  pass "the new Fixed bullet is inserted above the existing one"
else
  fail "the new Fixed bullet is inserted above the existing one (new=$new_pos old=$old_pos)"
fi

# Idempotent on the merged repo too.
before2="$(cat "$repo2/CHANGELOG.md")"
(cd "$repo2" && ./scripts/assemble-changelog.sh)
after2="$(cat "$repo2/CHANGELOG.md")"
assert_eq "the merged file is idempotent on a second run" "$before2" "$after2"

rm -rf "$repo2"

# --- An existing section the description grammar would fault is still kept ---
# The `## Changelog` grammar is a validator for one pull-request description,
# and a long-lived CHANGELOG.md legitimately carries things it faults: a
# category heading appearing more than once (this repository's own file has
# thirteen headings for six names), a heading outside the six, prose before the
# first heading, a blank line between two bullets. Re-rendering the section from
# that parse deletes all of it — silently, with exit 0 — so the section is
# spliced instead, never re-rendered.
repo3="$(mktemp -d)"
mkdir -p "$repo3/scripts" "$repo3/lib"
cp "$SCRIPT_DIR/scripts/assemble-changelog.sh" "$repo3/scripts/assemble-changelog.sh"
cp "$SCRIPT_DIR/lib/changelog-grammar.sh" "$repo3/lib/changelog-grammar.sh"
chmod +x "$repo3/scripts/assemble-changelog.sh"
git -C "$repo3" init -q -b main
git -C "$repo3" config user.email test@example.com
git -C "$repo3" config user.name test

cat > "$repo3/CHANGELOG.md" <<'MD'
# Changelog

## [Unreleased]

Some prose the grammar would fault before the first heading.

### Added

- First Added bullet. (#10)

- A second one, separated by a blank line. (#11)

### Notes

- A heading outside the six. (#12)

### Added

- A second Added block entirely. (#13)
MD
git -C "$repo3" add -A
git -C "$repo3" commit -q -m "chore: seed an awkward but real changelog"
base3="$(git -C "$repo3" rev-parse HEAD)"
kept3="$(cat "$repo3/CHANGELOG.md")"

echo "x" > "$repo3/h1.txt"
git -C "$repo3" add h1.txt
git -C "$repo3" commit -q -m "$(printf 'feat: a thing (#300)\n\n## Changelog\n\n### Added\n\n- The newest thing.\n')"

(cd "$repo3" && ./scripts/assemble-changelog.sh --since "$base3")
content3="$(cat "$repo3/CHANGELOG.md")"
for kept in \
  "Some prose the grammar would fault before the first heading." \
  "- First Added bullet. (#10)" \
  "- A second one, separated by a blank line. (#11)" \
  "### Notes" \
  "- A heading outside the six. (#12)" \
  "- A second Added block entirely. (#13)"; do
  assert_contains "an existing section the grammar faults keeps: $kept" "$content3" "$kept"
done
assert_contains "  ... and still gains the new bullet" "$content3" "- The newest thing. (#300)"
assert_contains "  ... with the blank line between two bullets preserved" \
  "$content3" "$(printf -- '- First Added bullet. (#10)\n\n- A second one')"
new3="$(printf '%s\n' "$content3" | grep -n "The newest thing" | cut -d: -f1)"
old3="$(printf '%s\n' "$content3" | grep -n "First Added bullet" | cut -d: -f1)"
if [[ -n "$new3" && -n "$old3" && "$new3" -lt "$old3" ]]; then
  pass "  ... inserted above the first Added block, not the second"
else
  fail "  ... inserted above the first Added block, not the second (new=$new3 old=$old3)"
fi
before3="$(cat "$repo3/CHANGELOG.md")"
(cd "$repo3" && ./scripts/assemble-changelog.sh)
assert_eq "  ... and is idempotent on a second run" "$before3" "$(cat "$repo3/CHANGELOG.md")"
# Everything the seed file held is still present, byte for byte.
missing3=0
while IFS= read -r seeded; do
  [[ -n "$seeded" ]] || continue
  [[ "$content3" == *"$seeded"* ]] || missing3=$(( missing3 + 1 ))
done <<<"$kept3"
assert_eq "  ... losing no line of the original file" "0" "$missing3"

# --- Multiple bullets from one commit keep the order their author wrote them -
echo "y" > "$repo3/h2.txt"
git -C "$repo3" add h2.txt
git -C "$repo3" commit -q -m "$(printf 'feat: two at once (#301)\n\n## Changelog\n\n### Changed\n\n- Alpha, written first.\n- Beta, written second.\n')"
(cd "$repo3" && ./scripts/assemble-changelog.sh)
content3="$(cat "$repo3/CHANGELOG.md")"
a_pos="$(printf '%s\n' "$content3" | grep -n "Alpha, written first" | cut -d: -f1)"
b_pos="$(printf '%s\n' "$content3" | grep -n "Beta, written second" | cut -d: -f1)"
if [[ -n "$a_pos" && -n "$b_pos" && "$a_pos" -lt "$b_pos" ]]; then
  pass "two bullets from one commit keep their written order"
else
  fail "two bullets from one commit keep their written order (alpha=$a_pos beta=$b_pos)"
fi

rm -rf "$repo3"

# --- A commit range that cannot be read is an error, never an empty range ----
# `set -euo pipefail` does not observe a process substitution's exit status, so
# reading `git log` through one turns a shallow checkout into an empty range —
# and the marker would then advance past every commit that was never read,
# losing their entries permanently and silently.
repo4="$(mktemp -d)"
mkdir -p "$repo4/scripts" "$repo4/lib"
cp "$SCRIPT_DIR/scripts/assemble-changelog.sh" "$repo4/scripts/assemble-changelog.sh"
cp "$SCRIPT_DIR/lib/changelog-grammar.sh" "$repo4/lib/changelog-grammar.sh"
chmod +x "$repo4/scripts/assemble-changelog.sh"
git -C "$repo4" init -q -b main
git -C "$repo4" config user.email test@example.com
git -C "$repo4" config user.name test
echo "seed" > "$repo4/s.txt"
git -C "$repo4" add -A
git -C "$repo4" commit -q -m "chore: seed"
absent="0000000000000000000000000000000000000001"
printf '# Changelog\n\n<!-- changelog:assembled-through sha=%s -->\n\n## [Unreleased]\n\n### Added\n\n- Must survive. (#1)\n' "$absent" > "$repo4/CHANGELOG.md"
kept4="$(cat "$repo4/CHANGELOG.md")"
out4="$( (cd "$repo4" && ./scripts/assemble-changelog.sh) 2>&1 )" && rc4=0 || rc4=$?
assert_eq "a marker sha this checkout does not carry exits non-zero" "1" "$rc4"
assert_contains "  ... and says the history is not there" "$out4" "is not a commit in this checkout"
assert_eq "  ... without advancing the marker over unread commits" "$kept4" "$(cat "$repo4/CHANGELOG.md")"
out4="$( (cd "$repo4" && ./scripts/assemble-changelog.sh --check) 2>&1 )" && rc4=0 || rc4=$?
assert_eq "  ... and --check refuses the same way rather than reporting fresh" "1" "$rc4"
rm -rf "$repo4"

# --- An empty first `## Changelog` section does not shadow a later real one --
# The collector locks onto the *first* `## Changelog` heading's section
# number; if that section turns out to carry no content (blank lines/HTML
# comments only — which the checker treats as absent, not as a fault), a
# real section later in the same body must still be read.
repo5="$(mktemp -d)"
mkdir -p "$repo5/scripts" "$repo5/lib"
cp "$SCRIPT_DIR/scripts/assemble-changelog.sh" "$repo5/scripts/assemble-changelog.sh"
cp "$SCRIPT_DIR/lib/changelog-grammar.sh" "$repo5/lib/changelog-grammar.sh"
chmod +x "$repo5/scripts/assemble-changelog.sh"
git -C "$repo5" init -q -b main
git -C "$repo5" config user.email test@example.com
git -C "$repo5" config user.name test
echo seed > "$repo5/seed.txt"
git -C "$repo5" add -A
git -C "$repo5" commit -q -m "chore: seed"
root5="$(git -C "$repo5" rev-parse HEAD)"

echo x > "$repo5/i1.txt"
git -C "$repo5" add i1.txt
git -C "$repo5" commit -q -m "$(printf 'feat: empty section then a real one (#500)\n\n## Changelog\n\n<!-- TODO -->\n\n## Notes\n\n## Changelog\n\n### Added\n\n- The real entry.\n')"
(cd "$repo5" && ./scripts/assemble-changelog.sh --since "$root5")
content5="$(cat "$repo5/CHANGELOG.md")"
assert_contains "an empty first Changelog section does not shadow the real one that follows" \
  "$content5" "- The real entry. (#500)"
rm -rf "$repo5"

# --- A tab-indented continuation keeps its leading tab -----------------------
# `IFS=$'\t' read` collapses a run of adjacent tab delimiters into one, so a
# multi-variable (or a final 2-variable) `read` across a CONTINUATION record
# eats a tab-indented continuation's own leading tab — indistinguishable from
# the field separator right in front of it. A space-indented continuation
# (exercised above, via repo2) cannot catch this: only a literal tab collides
# with IFS.
repo6="$(mktemp -d)"
mkdir -p "$repo6/scripts" "$repo6/lib"
cp "$SCRIPT_DIR/scripts/assemble-changelog.sh" "$repo6/scripts/assemble-changelog.sh"
cp "$SCRIPT_DIR/lib/changelog-grammar.sh" "$repo6/lib/changelog-grammar.sh"
chmod +x "$repo6/scripts/assemble-changelog.sh"
git -C "$repo6" init -q -b main
git -C "$repo6" config user.email test@example.com
git -C "$repo6" config user.name test
echo seed > "$repo6/seed.txt"
git -C "$repo6" add -A
git -C "$repo6" commit -q -m "chore: seed"
root6="$(git -C "$repo6" rev-parse HEAD)"

echo x > "$repo6/j1.txt"
git -C "$repo6" add j1.txt
git -C "$repo6" commit -q -m "$(printf 'fix: tab-indented continuation (#501)\n\n## Changelog\n\n### Fixed\n\n- A bullet.\n\tA tab-indented continuation.\n')"
(cd "$repo6" && ./scripts/assemble-changelog.sh --since "$root6")
content6="$(cat "$repo6/CHANGELOG.md")"
assert_contains "a bullet keeps its indented continuation lines" "$content6" "- A bullet."
assert_contains "  ... and a tab-indented continuation keeps its leading tab" \
  "$content6" "$(printf '\tA tab-indented continuation. (#501)')"
assert_not_contains "  ... never flush-left" "$content6" "$(printf '\nA tab-indented continuation.')"
rm -rf "$repo6"

echo
if (( failures > 0 )); then
  echo "$failures assertion(s) failed"
  exit 1
fi
echo "all assertions passed"
