#!/usr/bin/env bash
#
# test/render-toc.test.sh — self-contained regression test for
# scripts/render-toc.sh (#1402).
#
# Runs the actual shipped script (copied byte-for-byte into a scratch
# "repository" built from fixture docs) rather than a reimplementation of its
# logic, so this test exercises the real heading extraction, the real
# marker-pair validation and the real --check diffing.
#
# No test framework is used (none exists elsewhere in this repo); this is a
# plain bash script with hand-rolled assertions. Run it directly:
#
#   ./test/render-toc.test.sh
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

mkdir -p "$tmp/scripts" "$tmp/docs/guides/working-with-pullwright" "$tmp/docs/guides/operating" "$tmp/docs/guides/contributing" "$tmp/lib" \
  "$tmp/docs/spec/implementation/sub" "$tmp/docs/spec/dashboard"
cp "$SCRIPT_DIR/scripts/render-toc.sh" "$tmp/scripts/render-toc.sh"
cp "$SCRIPT_DIR/lib/markdown-scan.sh" "$tmp/lib/markdown-scan.sh"
chmod +x "$tmp/scripts/render-toc.sh"

# --- Fixture docs: the working-with-pullwright guide carries a deliberately stale ToC region (a
#     heading was added without regenerating); the impl spec fixture carries
#     an already-fresh region, so the "fresh tree is a no-op" case is covered
#     on a second file too. ---
write_fixture_other_guides() {
  cat > "$tmp/docs/guides/operating/README.md" <<'MD'
# Fixture operating guide

<!-- toc:start -->
- [Operating Alpha](#operating-alpha)
<!-- toc:end -->

## Operating Alpha
MD
  cat > "$tmp/docs/guides/contributing/README.md" <<'MD'
# Fixture contributing guide

<!-- toc:start -->
- [Contributing Alpha](#contributing-alpha)
<!-- toc:end -->

## Contributing Alpha
MD
}

write_fixture_readme() {
  cat > "$tmp/docs/guides/working-with-pullwright/README.md" <<'MD'
# Fixture

Sentinel before.

<!-- toc:start -->
- [Old Heading](#old-heading)
<!-- toc:end -->

Sentinel between.

## First Heading

### A Sub Heading

## Second Heading

Sentinel after.
MD
}

# A directory-wide ToC (TOC_DIR_FILES): the README's own region lists every
# *other* Markdown file under its directory, not its own headings — a
# deliberately stale entry here (it names neither real sibling) covers the
# same "stale tree" and "fresh tree is a no-op" cases write_fixture_readme's
# single-file region does, for the other rendering mode.
write_fixture_impl_spec() {
  cat > "$tmp/docs/spec/implementation/README.md" <<'MD'
# Fixture spec

<!-- toc:start -->
- [Old Entry](old.md)
<!-- toc:end -->

Intro prose, no headings of its own to list.
MD
  cat > "$tmp/docs/spec/implementation/alpha.md" <<'MD'
## Alpha File

Content.
MD
  cat > "$tmp/docs/spec/implementation/sub/beta.md" <<'MD'
### Beta File

Content.
MD
}

write_fixture_dashboard() {
  cat > "$tmp/docs/spec/dashboard/README.md" <<'MD'
# Fixture dashboard spec

<!-- toc:start -->
<!-- toc:end -->

Intro prose, no siblings yet.
MD
}

write_fixture_readme
write_fixture_impl_spec
write_fixture_dashboard
write_fixture_other_guides

run_script() (
  cd "$tmp" && ./scripts/render-toc.sh "$@"
)

# --- --check on a stale tree: non-zero ---
check_out="$(run_script --check 2>&1)"
check_rc=$?
if (( check_rc != 0 )); then
  pass "--check exits non-zero on a stale region"
else
  fail "--check exits non-zero on a stale region (got rc=0)"
fi
assert_contains "--check names the stale file" "$check_out" "README.md"

# --- Rewrite in place ---
run_script >/dev/null
rewrite_rc=$?
assert_eq "rewriting in place exits 0" "0" "$rewrite_rc"

readme_content="$(cat "$tmp/docs/guides/working-with-pullwright/README.md")"
assert_contains "the regenerated ToC lists First Heading" "$readme_content" "- [First Heading](#first-heading)"
assert_contains "the regenerated ToC nests A Sub Heading" "$readme_content" "  - [A Sub Heading](#a-sub-heading)"
assert_contains "the regenerated ToC lists Second Heading" "$readme_content" "- [Second Heading](#second-heading)"
if [[ "$readme_content" == *"Old Heading"* ]]; then
  fail "the stale Old Heading entry is gone"
else
  pass "the stale Old Heading entry is gone"
fi
assert_contains "text before the region survives" "$readme_content" "Sentinel before."
assert_contains "text between the region and headings survives" "$readme_content" "Sentinel between."
assert_contains "text after the headings survives" "$readme_content" "Sentinel after."

impl_readme_content="$(cat "$tmp/docs/spec/implementation/README.md")"
assert_contains "the directory ToC lists a flat sibling's own heading" "$impl_readme_content" "- [Alpha File](alpha.md)"
assert_contains "the directory ToC nests a sibling under its sub-directory" "$impl_readme_content" "  - [Beta File](sub/beta.md)"
if [[ "$impl_readme_content" == *"Old Entry"* ]]; then
  fail "the stale directory-ToC entry is gone"
else
  pass "the stale directory-ToC entry is gone"
fi

# --- --check stays clean on the freshly rewritten tree, and regenerating
#     again is a no-op ---
before_hash="$(find "$tmp/docs" -name '*.md' -print0 | sort -z | xargs -0 cat | sha256sum)"
run_script --check >/dev/null 2>&1
fresh_check_rc=$?
assert_eq "--check exits zero on a fresh tree" "0" "$fresh_check_rc"
run_script >/dev/null
after_hash="$(find "$tmp/docs" -name '*.md' -print0 | sort -z | xargs -0 cat | sha256sum)"
assert_eq "regenerating a fresh tree is a no-op" "$before_hash" "$after_hash"

# ============================================================================
# Marker validation (#1402): a file with no toc:start/toc:end markers, or
# with only one of the pair, or with more than one of either, is refused
# rather than silently copied through unchanged.
# ============================================================================

# --- Both markers missing entirely ---
cp "$tmp/docs/guides/working-with-pullwright/README.md" "$tmp/docs/guides/working-with-pullwright/README.md.bak"
sed -i '/<!-- toc:start -->/,/<!-- toc:end -->/d' "$tmp/docs/guides/working-with-pullwright/README.md"
missing_regen_out="$(run_script 2>&1)"
missing_regen_rc=$?
if (( missing_regen_rc != 0 )); then
  pass "regenerate mode refuses a file with no toc markers"
else
  fail "regenerate mode refuses a file with no toc markers (got rc=0)"
fi
assert_contains "the no-markers error (regenerate mode) names the file" "$missing_regen_out" "README.md"
missing_check_out="$(run_script --check 2>&1)"
missing_check_rc=$?
if (( missing_check_rc != 0 )); then
  pass "--check mode refuses a file with no toc markers"
else
  fail "--check mode refuses a file with no toc markers (got rc=0)"
fi
assert_contains "the no-markers error (--check mode) names the file" "$missing_check_out" "README.md"
mv "$tmp/docs/guides/working-with-pullwright/README.md.bak" "$tmp/docs/guides/working-with-pullwright/README.md"

# --- Only the start marker present (end missing) ---
cp "$tmp/docs/guides/working-with-pullwright/README.md" "$tmp/docs/guides/working-with-pullwright/README.md.bak"
grep -v '^<!-- toc:end -->$' "$tmp/docs/guides/working-with-pullwright/README.md" > "$tmp/docs/guides/working-with-pullwright/README.md.tmp" && mv "$tmp/docs/guides/working-with-pullwright/README.md.tmp" "$tmp/docs/guides/working-with-pullwright/README.md"
only_start_out="$(run_script --check 2>&1)"
only_start_rc=$?
if (( only_start_rc != 0 )); then
  pass "--check refuses a file with only the start marker"
else
  fail "--check refuses a file with only the start marker (got rc=0)"
fi
assert_contains "the unpaired-start error names the file" "$only_start_out" "README.md"
mv "$tmp/docs/guides/working-with-pullwright/README.md.bak" "$tmp/docs/guides/working-with-pullwright/README.md"

# --- Only the end marker present (start missing) ---
cp "$tmp/docs/guides/working-with-pullwright/README.md" "$tmp/docs/guides/working-with-pullwright/README.md.bak"
grep -v '^<!-- toc:start -->$' "$tmp/docs/guides/working-with-pullwright/README.md" > "$tmp/docs/guides/working-with-pullwright/README.md.tmp" && mv "$tmp/docs/guides/working-with-pullwright/README.md.tmp" "$tmp/docs/guides/working-with-pullwright/README.md"
only_end_out="$(run_script --check 2>&1)"
only_end_rc=$?
if (( only_end_rc != 0 )); then
  pass "--check refuses a file with only the end marker"
else
  fail "--check refuses a file with only the end marker (got rc=0)"
fi
assert_contains "the unpaired-end error names the file" "$only_end_out" "README.md"
mv "$tmp/docs/guides/working-with-pullwright/README.md.bak" "$tmp/docs/guides/working-with-pullwright/README.md"

# --- More than one marker pair ---
cp "$tmp/docs/guides/working-with-pullwright/README.md" "$tmp/docs/guides/working-with-pullwright/README.md.bak"
sed -i '0,/<!-- toc:end -->/{s/<!-- toc:end -->/<!-- toc:end -->\n<!-- toc:start -->\n- extra\n<!-- toc:end -->/}' "$tmp/docs/guides/working-with-pullwright/README.md"
dup_out="$(run_script --check 2>&1)"
dup_rc=$?
if (( dup_rc != 0 )); then
  pass "--check refuses a file with more than one marker pair"
else
  fail "--check refuses a file with more than one marker pair (got rc=0)"
fi
assert_contains "the duplicate-markers error names the file" "$dup_out" "README.md"
mv "$tmp/docs/guides/working-with-pullwright/README.md.bak" "$tmp/docs/guides/working-with-pullwright/README.md"

# --- Markers present exactly once each, but in reversed order ---
cp "$tmp/docs/guides/working-with-pullwright/README.md" "$tmp/docs/guides/working-with-pullwright/README.md.bak"
awk '
  /^<!-- toc:start -->/ { start = $0; next }
  /^<!-- toc:end -->/ { print; print start; next }
  { print }
' "$tmp/docs/guides/working-with-pullwright/README.md" > "$tmp/docs/guides/working-with-pullwright/README.md.tmp" && mv "$tmp/docs/guides/working-with-pullwright/README.md.tmp" "$tmp/docs/guides/working-with-pullwright/README.md"
reversed_out="$(run_script --check 2>&1)"
reversed_rc=$?
if (( reversed_rc != 0 )); then
  pass "--check refuses a file with reversed markers"
else
  fail "--check refuses a file with reversed markers (got rc=0)"
fi
assert_contains "the reversed-markers error names the file" "$reversed_out" "README.md"
mv "$tmp/docs/guides/working-with-pullwright/README.md.bak" "$tmp/docs/guides/working-with-pullwright/README.md"

# --- A correctly paired region is unaffected: --check is clean afterwards ---
run_script --check >/dev/null 2>&1
final_check_rc=$?
assert_eq "a correctly paired region still checks clean after all the above" "0" "$final_check_rc"

echo
if (( failures == 0 )); then
  echo "render-toc.test.sh: all assertions passed"
  exit 0
else
  echo "render-toc.test.sh: $failures assertion(s) failed"
  exit 1
fi
