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
  mkdir -p "$dir/scripts" "$dir/docs/reviews/project-review-2026-01-01" "$dir/docs/reference" "$dir/docs/guides/operating" "$dir/lib" \
    "$dir/docs/spec/implementation" "$dir/docs/spec/dashboard"
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
| `docs/spec/implementation/README.md` | agent | reference | Fixture spec |
| `docs/spec/review.md` | agent | reference | Fixture spec |
| `docs/spec/monitor.md` | agent | reference | Fixture spec |
| `docs/spec/dashboard/README.md` | agent | reference | Fixture spec |
| `docs/reference/configuration.md` | operator | reference | Fixture configuration reference |
| `docs/guides/operating/README.md` | operator | how-to | Fixture operating guide |
| `docs/ROADMAP.md` | maintainer | decision log | Fixture roadmap |
| `docs/reviews/2026-01-01-fixture.md` | maintainer | record | Fixture review |
| `docs/reviews/project-review-2026-01-01/` | maintainer | record | Fixture project review |
| `CHANGELOG.md` | maintainer | record | Fixture changelog |
| `AGENTS.md` | agent | reference | Fixture conventions |

See `docs/spec/implementation/README.md` § "Fixture Heading" for an example
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

  cat > "$dir/docs/spec/implementation/README.md" <<'MD'
# Fixture spec

## Fixture Heading

Content.
MD

  cat > "$dir/docs/spec/review.md" <<'MD'
# Fixture review spec

## Another Heading

Content.
MD

  cat > "$dir/docs/spec/monitor.md" <<'MD'
# Fixture monitor spec

Content.
MD

  cat > "$dir/docs/spec/dashboard/README.md" <<'MD'
# Fixture dashboard spec

Content.
MD

  # Two of the files lib/markdown-scan.sh lists as carrying generated
  # regions, so check 3's region scenarios can place them where they count.
  printf '# Fixture configuration reference\n\nContent.\n' > "$dir/docs/reference/configuration.md"
  printf '# Fixture operating guide\n\nContent.\n' > "$dir/docs/guides/operating/README.md"

  # Check 3 fails an exemption that matches no document, so the tree carries
  # one document for each of check-docs.sh's SIZE_EXEMPT patterns, and a
  # review report at both depths docs/reviews/** covers.
  printf '# Fixture roadmap\n\nContent.\n' > "$dir/docs/ROADMAP.md"
  printf '# Fixture review\n\nContent.\n' > "$dir/docs/reviews/2026-01-01-fixture.md"
  printf '# Fixture project review\n\nContent.\n' > "$dir/docs/reviews/project-review-2026-01-01/report.md"
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

# size_diag FILE BYTES: check 3's diagnostic for FILE at BYTES hand-written
# bytes, past the budget with no ratchet entry. Asserting the whole of it
# pins both which check failed and what it measured.
size_diag() {
  printf '%s: %s hand-written bytes exceeds the 100000-byte size budget' "$1" "$2"
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
assert_fails "check 1 fixture" "$links_out" $? "does not resolve"
rm -rf "$links_repo"

# --- Check 1, explicit anchors: a fragment that no heading slugs to, but an
#     `<a id="…">` anchor in the target provides, is a working GitHub link and
#     must pass — docs/concepts/glossary.md writes exactly this over a heading
#     whose own slug differs. A fragment matching neither still fails. ---
anchor_repo="$(new_repo)"
cat >> "$anchor_repo/docs/spec/implementation/README.md" <<'MD'

<a id="explicit-anchor"></a>
## A heading whose slug is not the anchor

Content.
MD
cat >> "$anchor_repo/README.md" <<'MD'

See [the anchored section](docs/spec/implementation/README.md#explicit-anchor).
MD
anchor_out="$(run_script "$anchor_repo" 2>&1)"
anchor_rc=$?
assert_eq "explicit-anchor fixture: --check exits 0" "0" "$anchor_rc"
assert_contains "explicit-anchor fixture: links and anchors ok" "$anchor_out" "links and anchors: ok"

sed -i 's/#explicit-anchor/#no-such-anchor/' "$anchor_repo/README.md"
anchor_bad_out="$(run_script "$anchor_repo" 2>&1)"
assert_fails "explicit-anchor fixture, a fragment matching neither heading nor anchor" "$anchor_bad_out" $? "has no matching heading"
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
assert_fails "check 2 fixture" "$map_out" $? "docs/ORPHAN.md is not listed"
rm -rf "$map_repo"

# --- Check 3: size budget — a document past 100,000 bytes with no ratchet
#     entry. ---
size_repo="$(new_repo)"
pad_past_budget >> "$size_repo/AGENTS.md"
size_out="$(run_script "$size_repo" 2>&1)"
assert_fails "check 3 fixture" "$size_out" $? "$(size_diag AGENTS.md "$(wc -c < "$size_repo/AGENTS.md")")"
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

# --- Check 3, exemptions: a document each SIZE_EXEMPT pattern covers, over
#     budget with no ratchet entry, passes. That is CHANGELOG.md, the
#     roadmap, and a review report at either depth docs/reviews/** reaches —
#     no as-built specification carries a blanket exemption (#2094 split the
#     two that had actually grown past the budget into files that are each
#     within it; see check-docs.sh's SIZE_EXEMPT comment). ---
for doc in CHANGELOG.md docs/ROADMAP.md docs/reviews/2026-01-01-fixture.md \
  docs/reviews/project-review-2026-01-01/report.md; do
  exempt_repo="$(new_repo)"
  pad_past_budget >> "$exempt_repo/$doc"
  exempt_out="$(run_script "$exempt_repo" 2>&1)"
  assert_size_ok "check 3 exemption fixture, $doc" "$exempt_out" $?
  rm -rf "$exempt_repo"
done

# --- Check 3, no blanket specification exemption: a specification file over
#     budget with no ratchet entry fails like any other document, the way
#     docs/spec/implementation/README.md and its sibling files do since
#     #2094 — proof that SIZE_EXEMPT carries no `docs/*-SPEC.md`-shaped
#     pattern a specification could still hide behind. ---
spec_repo="$(new_repo)"
pad_past_budget >> "$spec_repo/docs/spec/implementation/README.md"
spec_out="$(run_script "$spec_repo" 2>&1)"
assert_fails "check 3 specification fixture, no blanket exemption" "$spec_out" $? \
  "$(size_diag docs/spec/implementation/README.md "$(wc -c < "$spec_repo/docs/spec/implementation/README.md")")"
rm -rf "$spec_repo"

# --- Check 3, generated regions: the bytes inside each kind of region
#     lib/markdown-scan.sh lists, placed in a file it lists for that kind, do
#     not count. ---
while IFS='|' read -r kind file start_marker end_marker; do
  region_repo="$(new_repo)"
  {
    echo
    echo "$start_marker"
    pad_past_budget
    echo
    echo "$end_marker"
  } >> "$region_repo/$file"
  region_out="$(run_script "$region_repo" 2>&1)"
  assert_size_ok "check 3 generated-region fixture, $kind" "$region_out" $?
  rm -rf "$region_repo"
done <<'REGIONS'
table of contents|docs/guides/operating/README.md|<!-- toc:start -->|<!-- toc:end -->
configuration table|docs/reference/configuration.md|<!-- config-table:start id=main — GENERATED from config.schema.json by scripts/render-config-table.sh; edit the schema, not these rows -->|<!-- config-table:end -->
configuration-table notes|docs/reference/configuration.md|<!-- config-table:notes id=review -->|<!-- config-table:notes-end -->
stamped region|AGENTS.md|<!-- agent-info:start fragment=conventions source=Pullwright/.agent@b517d3d sha256=30bd787a7b6c -->|<!-- agent-info:end fragment=conventions -->
REGIONS

# --- Check 3, regions that are not generated: a marker pair in a file, or
#     with an id or fragment, that lib/markdown-scan.sh does not list, a
#     stamped region closed under another fragment's name, and a start marker
#     with no end all leave their bytes counted as hand-written. ---
while IFS='|' read -r case_name file start_marker end_marker; do
  counted_repo="$(new_repo)"
  {
    echo
    echo "$start_marker"
    pad_past_budget
    echo
    [[ -z "$end_marker" ]] || echo "$end_marker"
  } >> "$counted_repo/$file"
  counted_out="$(run_script "$counted_repo" 2>&1)"
  assert_fails "check 3 counted-region fixture, $case_name" "$counted_out" $? \
    "$(size_diag "$file" "$(wc -c < "$counted_repo/$file")")"
  rm -rf "$counted_repo"
done <<'COUNTED'
table of contents in a file render-toc.sh does not render|docs/reference/configuration.md|<!-- toc:start -->|<!-- toc:end -->
configuration table with an id nothing renders|docs/reference/configuration.md|<!-- config-table:start id=other -->|<!-- config-table:end -->
configuration table in a file nothing renders one in|AGENTS.md|<!-- config-table:start id=main -->|<!-- config-table:end -->
fragment the sync does not stamp here|AGENTS.md|<!-- agent-info:start fragment=unlisted source=Pullwright/.agent@b517d3d sha256=30bd787a7b6c -->|<!-- agent-info:end fragment=unlisted -->
stamped region closed under another fragment's name|AGENTS.md|<!-- agent-info:start fragment=conventions source=Pullwright/.agent@b517d3d sha256=30bd787a7b6c -->|<!-- agent-info:end fragment=maintainer -->
unterminated region|docs/reference/configuration.md|<!-- config-table:start id=main -->|
COUNTED

# --- Check 3, markers inside fenced code open nothing, even in a file whose
#     region they name. ---
fenced_repo="$(new_repo)"
{
  echo
  echo '```'
  echo '<!-- toc:start -->'
  pad_past_budget
  echo
  echo '<!-- toc:end -->'
  echo '```'
} >> "$fenced_repo/docs/guides/operating/README.md"
fenced_out="$(run_script "$fenced_repo" 2>&1)"
assert_fails "check 3 fenced-markers fixture" "$fenced_out" $? \
  "$(size_diag docs/guides/operating/README.md "$(wc -c < "$fenced_repo/docs/guides/operating/README.md")")"
rm -rf "$fenced_repo"

# --- Check 3, a second copy of a listed region is hand-written, since each
#     renderer's check reads only the first. ---
second_repo="$(new_repo)"
second_conf="$second_repo/docs/reference/configuration.md"
first_copy=$'<!-- config-table:start id=main -->\n<!-- config-table:end -->\n'
printf '%s' "$first_copy" >> "$second_conf"
{
  echo '<!-- config-table:start id=main -->'
  pad_past_budget
  echo
  echo '<!-- config-table:end -->'
} >> "$second_conf"
second_out="$(run_script "$second_repo" 2>&1)"
assert_fails "check 3 second-copy fixture" "$second_out" $? \
  "$(size_diag docs/reference/configuration.md "$(( $(wc -c < "$second_conf") - ${#first_copy} ))")"
rm -rf "$second_repo"

# --- Check 3, an entry for a document with a generated region holds it at
#     its hand-written size, which leaves out the whole region, fenced code
#     inside it included; one more hand-written byte fails. The operating
#     guide's own entry has this shape. ---
live_repo="$(new_repo)"
live_guide="$live_repo/docs/guides/operating/README.md"
pad_past_budget >> "$live_guide"
echo >> "$live_guide"
live_hand=$(wc -c < "$live_guide")
{
  echo '<!-- toc:start -->'
  yes 'A generated table-of-contents line.' | head -n 100
  echo '```'
  echo 'A fenced example inside the region.'
  echo '```'
  echo '<!-- toc:end -->'
} >> "$live_guide"
printf 'docs/guides/operating/README.md\t%s\t1\n' "$live_hand" >> "$live_repo/scripts/docs-size-ratchet.tsv"
live_out="$(run_script "$live_repo" 2>&1)"
assert_size_ok "check 3 live-entry fixture" "$live_out" $?
printf 'x' >> "$live_guide"
live_out="$(run_script "$live_repo" 2>&1)"
assert_fails "check 3 live-entry fixture, one hand-written byte more" "$live_out" $? \
  "docs/guides/operating/README.md: $(( live_hand + 1 )) hand-written bytes, grew past"
rm -rf "$live_repo"

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
exempt document|CHANGELOG.md|CHANGELOG.md is exempt from the size budget
missing document|docs/GONE.md|docs/GONE.md is not an in-scope document
document within the budget|AGENTS.md|AGENTS.md is within the size budget
DEAD

# --- Check 3, dead entries: a document over the budget as a whole but
#     within it once its generated region is left out is within the budget,
#     so its entry is dead too. ---
over_raw_repo="$(new_repo)"
over_raw_guide="$over_raw_repo/docs/guides/operating/README.md"
over_raw_hand=$(wc -c < "$over_raw_guide")
{
  echo '<!-- toc:start -->'
  pad_past_budget
  echo
  echo '<!-- toc:end -->'
} >> "$over_raw_guide"
printf 'docs/guides/operating/README.md\t200000\t1\n' >> "$over_raw_repo/scripts/docs-size-ratchet.tsv"
over_raw_out="$(run_script "$over_raw_repo" 2>&1)"
assert_fails "check 3 dead-entry fixture, over the budget only by its region" "$over_raw_out" $? \
  "docs/guides/operating/README.md is within the size budget at $over_raw_hand hand-written bytes"
rm -rf "$over_raw_repo"

# --- Check 4: section citations — a citation naming a heading that does
#     not exist. ---
cite_repo="$(new_repo)"
sed -i 's/"Fixture Heading"/"Nonexistent Heading"/' "$cite_repo/docs/README.md"
cite_out="$(run_script "$cite_repo" 2>&1)"
assert_fails "check 4 fixture" "$cite_out" $? "but that heading does not exist in"
rm -rf "$cite_repo"

# --- Check 5: as-built phrasing ratchet — historical phrasing with no
#     ratchet entry. ---
phrasing_repo="$(new_repo)"
cat >> "$phrasing_repo/README.md" <<'MD'

This document previously described a different installation step.
MD
phrasing_out="$(run_script "$phrasing_repo" 2>&1)"
assert_fails "check 5 fixture" "$phrasing_out" $? "has no entry in"
rm -rf "$phrasing_repo"

if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures" >&2
  exit 1
fi
exit 0
