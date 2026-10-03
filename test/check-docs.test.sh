#!/usr/bin/env bash
#
# test/check-docs.test.sh — self-contained regression test for
# scripts/check-docs.sh (#2088).
#
# Runs the actual shipped script (copied byte-for-byte into a scratch
# "repository" built from fixture docs) rather than a reimplementation of
# its logic, the same pattern test/render-toc.test.sh and
# test/render-config-table.test.sh already use. A fresh scratch repo is
# built per scenario, so one broken fixture never leaks state into the
# next.
#
# No test framework is used (none exists elsewhere in this repo); this is a
# plain bash script with hand-rolled assertions. Run it directly:
#
#   ./test/check-docs.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

failures=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; failures=$(( failures + 1 )); }
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:               %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$desc"
  else
    printf 'FAIL - %s\n     expected: %s\n     actual:   %s\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}

# new_repo: build a fresh scratch "repository" at a fresh temp dir, with the
# real script and its one library dependency, and return its path on stdout.
# Every scenario below calls this itself rather than sharing one tree, so a
# break made for one check can never bleed into another's baseline.
new_repo() {
  local dir
  dir="$(mktemp -d)"
  mkdir -p "$dir/scripts" "$dir/docs" "$dir/lib"
  cp "$SCRIPT_DIR/scripts/check-docs.sh" "$dir/scripts/check-docs.sh"
  cp "$SCRIPT_DIR/lib/markdown-scan.sh" "$dir/lib/markdown-scan.sh"
  chmod +x "$dir/scripts/check-docs.sh"

  cat > "$dir/README.md" <<'MD'
# Fixture README

## Installation

See [Installation](#installation) for details.
MD

  cat > "$dir/docs/README.md" <<'MD'
# Documentation

## All documents

| File | Audience | Kind | Purpose |
|------|----------|------|---------|
| `README.md` | operator | how-to | Fixture root readme |
| `docs/README.md` | operator | reference | This map |
| `docs/IMPLEMENTATION-PIPELINE-SPEC.md` | agent | reference | Fixture spec |
| `docs/REVIEW-PIPELINE-SPEC.md` | agent | reference | Fixture spec |
| `AGENTS.md` | agent | reference | Fixture conventions |

See `docs/IMPLEMENTATION-PIPELINE-SPEC.md` § "Fixture Heading" for an example
citation.

## Size budget

Fixture documents stay small on purpose.
MD

  # The real scripts/check-docs.sh cites AGENTS.md and docs/README.md in its
  # own header comment — it is copied byte-for-byte below, so the fixture
  # tree must carry what it cites, the same as any other file's citations.
  cat > "$dir/AGENTS.md" <<'MD'
# Fixture AGENTS

## Tech debt

Fixture conventions.
MD

  cat > "$dir/docs/IMPLEMENTATION-PIPELINE-SPEC.md" <<'MD'
# Fixture spec

## Fixture Heading

Content.
MD

  cat > "$dir/docs/REVIEW-PIPELINE-SPEC.md" <<'MD'
# Fixture review spec

## Another Heading

Content.
MD

  echo '{}' > "$dir/config.schema.json"
  printf '# empty — nothing over budget in this fixture\n' > "$dir/scripts/docs-size-ratchet.tsv"
  printf '# empty — no as-built phrasing in this fixture\n' > "$dir/scripts/docs-phrasing-ratchet.tsv"

  (cd "$dir" && git init -q && git add -A)
  echo "$dir"
}

run_script() (
  cd "$1" && ./scripts/check-docs.sh --check
)

# --- Baseline: a clean fixture tree passes every check. ---
baseline="$(new_repo)"
baseline_out="$(run_script "$baseline" 2>&1)"
baseline_rc=$?
assert_eq "baseline fixture: --check exits 0" "0" "$baseline_rc"
assert_contains "baseline: links and anchors ok" "$baseline_out" "links and anchors: ok"
assert_contains "baseline: the map ok" "$baseline_out" "the map: ok"
assert_contains "baseline: size budget ok" "$baseline_out" "size budget: ok"
assert_contains "baseline: section citations ok" "$baseline_out" "section citations: ok"
assert_contains "baseline: as-built phrasing ratchet ok" "$baseline_out" "as-built phrasing ratchet: ok"
rm -rf "$baseline"

# --- Check 1: links and anchors — a relative link to a file that doesn't
#     exist. ---
links_repo="$(new_repo)"
cat >> "$links_repo/README.md" <<'MD'

See [Nowhere](nonexistent.md) too.
MD
links_out="$(run_script "$links_repo" 2>&1)"
links_rc=$?
if (( links_rc != 0 )); then
  pass "check 1 fixture: --check exits non-zero on a broken link"
else
  fail "check 1 fixture: --check exits non-zero on a broken link (got rc=0)"
fi
assert_contains "check 1 fixture: names the unresolved target" "$links_out" "does not resolve"
rm -rf "$links_repo"

# --- Check 2: the map — an in-scope document that exists on disk but is
#     never listed. ---
map_repo="$(new_repo)"
cat > "$map_repo/docs/ORPHAN.md" <<'MD'
# Orphan

Never added to the map.
MD
(cd "$map_repo" && git add -A)
map_out="$(run_script "$map_repo" 2>&1)"
map_rc=$?
if (( map_rc != 0 )); then
  pass "check 2 fixture: --check exits non-zero on an unmapped document"
else
  fail "check 2 fixture: --check exits non-zero on an unmapped document (got rc=0)"
fi
assert_contains "check 2 fixture: names the unmapped file" "$map_out" "docs/ORPHAN.md is not listed"
rm -rf "$map_repo"

# --- Check 3: size budget — a document past 100,000 bytes with no ratchet
#     entry. ---
size_repo="$(new_repo)"
{
  echo '# Fixture spec'
  echo
  echo '## Fixture Heading'
  echo
  yes 'Padding line to cross the size budget.' | head -c 100100
} > "$size_repo/docs/IMPLEMENTATION-PIPELINE-SPEC.md"
size_out="$(run_script "$size_repo" 2>&1)"
size_rc=$?
if (( size_rc != 0 )); then
  pass "check 3 fixture: --check exits non-zero on an over-budget file"
else
  fail "check 3 fixture: --check exits non-zero on an over-budget file (got rc=0)"
fi
assert_contains "check 3 fixture: names the size-budget violation" "$size_out" "exceeds the 100000-byte size budget"
rm -rf "$size_repo"

# --- Check 4: section citations — a citation naming a heading that does
#     not exist. ---
cite_repo="$(new_repo)"
sed -i 's/"Fixture Heading"/"Nonexistent Heading"/' "$cite_repo/docs/README.md"
cite_out="$(run_script "$cite_repo" 2>&1)"
cite_rc=$?
if (( cite_rc != 0 )); then
  pass "check 4 fixture: --check exits non-zero on a stale citation"
else
  fail "check 4 fixture: --check exits non-zero on a stale citation (got rc=0)"
fi
assert_contains "check 4 fixture: names the missing heading" "$cite_out" "but that heading does not exist in"
rm -rf "$cite_repo"

# --- Check 5: as-built phrasing ratchet — historical phrasing with no
#     ratchet entry. ---
phrasing_repo="$(new_repo)"
cat >> "$phrasing_repo/README.md" <<'MD'

This document previously described a different installation step.
MD
phrasing_out="$(run_script "$phrasing_repo" 2>&1)"
phrasing_rc=$?
if (( phrasing_rc != 0 )); then
  pass "check 5 fixture: --check exits non-zero on unratcheted phrasing"
else
  fail "check 5 fixture: --check exits non-zero on unratcheted phrasing (got rc=0)"
fi
assert_contains "check 5 fixture: names the missing ratchet entry" "$phrasing_out" "has no entry in"
rm -rf "$phrasing_repo"

if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures" >&2
  exit 1
fi
exit 0
