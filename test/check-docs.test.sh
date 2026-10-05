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
  mkdir -p "$dir/scripts" "$dir/docs/reviews" "$dir/docs/reference" "$dir/lib"
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
| `docs/MONITOR-PIPELINE-SPEC.md` | agent | reference | Fixture spec |
| `docs/DASHBOARD-SPEC.md` | agent | reference | Fixture spec |
| `docs/reference/configuration.md` | operator | reference | Fixture configuration reference |
| `docs/ROADMAP.md` | maintainer | decision log | Fixture roadmap |
| `docs/reviews/2026-01-01-fixture.md` | maintainer | record | Fixture review |
| `CHANGELOG.md` | maintainer | record | Fixture changelog |
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

## As-built specifications

Fixture conventions.

## Generated regions

Fixture conventions.

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

  cat > "$dir/docs/MONITOR-PIPELINE-SPEC.md" <<'MD'
# Fixture monitor spec

Content.
MD

  cat > "$dir/docs/DASHBOARD-SPEC.md" <<'MD'
# Fixture dashboard spec

Content.
MD

  cat > "$dir/docs/reference/configuration.md" <<'MD'
# Fixture configuration reference

Content.
MD

  # Check 3 fails an exemption that matches no document, so the tree carries
  # one document for each of check-docs.sh's SIZE_EXEMPT patterns.
  printf '# Fixture roadmap\n\nContent.\n' > "$dir/docs/ROADMAP.md"
  printf '# Fixture review\n\nContent.\n' > "$dir/docs/reviews/2026-01-01-fixture.md"
  printf '# Fixture changelog\n\nContent.\n' > "$dir/CHANGELOG.md"

  echo '{}' > "$dir/config.schema.json"
  printf '# empty — nothing over budget in this fixture\n' > "$dir/scripts/docs-size-ratchet.tsv"
  printf '# empty — no as-built phrasing in this fixture\n' > "$dir/scripts/docs-phrasing-ratchet.tsv"

  (cd "$dir" && git init -q && git add -A)
  echo "$dir"
}

run_script() (
  cd "$1" && ./scripts/check-docs.sh --check
)

# pad_past_budget: print filler just past check 3's 100,000-byte budget.
pad_past_budget() {
  yes 'Padding line to cross the size budget.' | head -c 100100
}

# assert_fails DESC OUTPUT RC NEEDLE: the run exited non-zero and named NEEDLE.
assert_fails() {
  local desc="$1" out="$2" rc="$3" needle="$4"
  if (( rc != 0 )); then
    pass "$desc: --check exits non-zero"
  else
    fail "$desc: --check exits non-zero (got rc=0)"
  fi
  assert_contains "$desc: names the defect" "$out" "$needle"
}

# assert_size_ok DESC OUTPUT RC: the run exited 0 with the size check ok.
assert_size_ok() {
  local desc="$1" out="$2" rc="$3"
  assert_eq "$desc: --check exits 0" "0" "$rc"
  assert_contains "$desc: size budget ok" "$out" "size budget: ok"
}

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

# --- Check 1, explicit anchors: a fragment that no heading slugs to, but an
#     `<a id="…">` anchor in the target provides, is a working GitHub link and
#     must pass — docs/concepts/glossary.md writes exactly this over a heading
#     whose own slug differs. A fragment matching neither still fails. ---
anchor_repo="$(new_repo)"
cat >> "$anchor_repo/docs/IMPLEMENTATION-PIPELINE-SPEC.md" <<'MD'

<a id="explicit-anchor"></a>
## A heading whose slug is not the anchor

Content.
MD
cat >> "$anchor_repo/README.md" <<'MD'

See [the anchored section](docs/IMPLEMENTATION-PIPELINE-SPEC.md#explicit-anchor).
MD
anchor_out="$(run_script "$anchor_repo" 2>&1)"
anchor_rc=$?
assert_eq "explicit-anchor fixture: --check exits 0" "0" "$anchor_rc"
assert_contains "explicit-anchor fixture: links and anchors ok" "$anchor_out" "links and anchors: ok"

sed -i 's/#explicit-anchor/#no-such-anchor/' "$anchor_repo/README.md"
anchor_bad_out="$(run_script "$anchor_repo" 2>&1)"
anchor_bad_rc=$?
if (( anchor_bad_rc != 0 )); then
  pass "explicit-anchor fixture: a fragment matching neither heading nor anchor fails"
else
  fail "explicit-anchor fixture: a fragment matching neither heading nor anchor fails (got rc=0)"
fi
assert_contains "explicit-anchor fixture: names the missing fragment" "$anchor_bad_out" "has no matching heading"
rm -rf "$anchor_repo"

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
pad_past_budget >> "$size_repo/AGENTS.md"
size_out="$(run_script "$size_repo" 2>&1)"
assert_fails "check 3 fixture" "$size_out" $? "exceeds the 100000-byte size budget"
rm -rf "$size_repo"

# --- Check 3, ratchet: an entry at the file's own hand-written size holds
#     it, and one more byte fails. ---
ratchet_repo="$(new_repo)"
pad_past_budget >> "$ratchet_repo/AGENTS.md"
printf 'AGENTS.md\t%s\t1\n' "$(wc -c < "$ratchet_repo/AGENTS.md")" >> "$ratchet_repo/scripts/docs-size-ratchet.tsv"
ratchet_out="$(run_script "$ratchet_repo" 2>&1)"
assert_size_ok "check 3 ratchet fixture" "$ratchet_out" $?
printf 'x' >> "$ratchet_repo/AGENTS.md"
ratchet_out="$(run_script "$ratchet_repo" 2>&1)"
assert_fails "check 3 ratchet fixture, one byte more" "$ratchet_out" $? "grew past its scripts/docs-size-ratchet.tsv entry"
rm -rf "$ratchet_repo"

# --- Check 3, exemption: every as-built specification AGENTS.md lists,
#     over budget with no ratchet entry, passes — it is exempt by nature
#     (#2163) — whichever docs/*-SPEC.md name it carries. ---
for spec in IMPLEMENTATION-PIPELINE REVIEW-PIPELINE MONITOR-PIPELINE DASHBOARD; do
  exempt_repo="$(new_repo)"
  pad_past_budget >> "$exempt_repo/docs/$spec-SPEC.md"
  exempt_out="$(run_script "$exempt_repo" 2>&1)"
  assert_size_ok "check 3 exemption fixture, docs/$spec-SPEC.md" "$exempt_out" $?
  rm -rf "$exempt_repo"
done

# --- Check 3, generated regions: bytes inside a complete region of each
#     kind AGENTS.md's "Generated regions" section lists do not count. ---
while IFS='|' read -r kind start_marker end_marker; do
  region_repo="$(new_repo)"
  {
    echo
    echo "$start_marker"
    pad_past_budget
    echo
    echo "$end_marker"
  } >> "$region_repo/docs/reference/configuration.md"
  region_out="$(run_script "$region_repo" 2>&1)"
  assert_size_ok "check 3 generated-region fixture, $kind" "$region_out" $?
  rm -rf "$region_repo"
done <<'REGIONS'
table of contents|<!-- toc:start -->|<!-- toc:end -->
configuration table|<!-- config-table:start id=main — GENERATED from config.schema.json by scripts/render-config-table.sh; edit the schema, not these rows -->|<!-- config-table:end -->
configuration-table notes|<!-- config-table:notes id=main -->|<!-- config-table:notes-end -->
stamped region|<!-- agent-info:start fragment=conventions source=Pullwright/.agent@b517d3d sha256=30bd787a7b6c -->|<!-- agent-info:end fragment=conventions -->
REGIONS

# --- Check 3, generated regions: an unterminated region, or markers inside
#     fenced code, leave the bytes counted as hand-written. ---
unterminated_repo="$(new_repo)"
{
  echo
  echo '<!-- config-table:start id=main -->'
  pad_past_budget
} >> "$unterminated_repo/docs/reference/configuration.md"
unterminated_out="$(run_script "$unterminated_repo" 2>&1)"
assert_fails "check 3 unterminated-region fixture" "$unterminated_out" $? "docs/reference/configuration.md: "
rm -rf "$unterminated_repo"

fenced_repo="$(new_repo)"
{
  echo
  echo '```'
  echo '<!-- toc:start -->'
  pad_past_budget
  echo
  echo '<!-- toc:end -->'
  echo '```'
} >> "$fenced_repo/docs/reference/configuration.md"
fenced_out="$(run_script "$fenced_repo" 2>&1)"
assert_fails "check 3 fenced-markers fixture" "$fenced_out" $? "docs/reference/configuration.md: "
rm -rf "$fenced_repo"

# --- Check 3, dead entries: a ratchet entry check 3 would never read — for
#     an exempt document, a missing one, or one within the budget — fails,
#     so a conflict resolution cannot keep one that looks live. ---
while IFS='|' read -r case_name rpath needle; do
  dead_repo="$(new_repo)"
  printf '%s\t200000\t1\n' "$rpath" >> "$dead_repo/scripts/docs-size-ratchet.tsv"
  dead_out="$(run_script "$dead_repo" 2>&1)"
  assert_fails "check 3 dead-entry fixture, $case_name" "$dead_out" $? "$needle"
  rm -rf "$dead_repo"
done <<'DEAD'
exempt document|docs/REVIEW-PIPELINE-SPEC.md|docs/REVIEW-PIPELINE-SPEC.md is exempt from the size budget
missing document|docs/GONE.md|docs/GONE.md is not an in-scope document
document within the budget|AGENTS.md|AGENTS.md is within the size budget
DEAD

# --- Check 3, stale exemption: an exemption that matches no document
#     fails, as #2094's move of the specifications would make it. ---
stale_repo="$(new_repo)"
(cd "$stale_repo" && git rm -qf docs/ROADMAP.md)
sed -i '\|docs/ROADMAP.md|d' "$stale_repo/docs/README.md"
stale_out="$(run_script "$stale_repo" 2>&1)"
assert_fails "check 3 stale-exemption fixture" "$stale_out" $? "size exemption 'docs/ROADMAP.md' matches no in-scope document"
rm -rf "$stale_repo"

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
