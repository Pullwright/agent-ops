#!/usr/bin/env bash
#
# test/spec.test.sh — self-contained regression test for scripts/spec.sh
# (issue #2095).
#
# Runs the actual shipped script (copied byte-for-byte into a scratch
# "repository" built from fixture spec files) rather than a
# reimplementation of its logic, the same pattern test/check-docs.test.sh
# already uses. A fresh scratch repo is built per scenario, so one broken
# fixture never leaks state into the next.
#
# No test framework is used (none exists elsewhere in this repo); this is a
# plain bash script with hand-rolled assertions. Run it directly:
#
#   ./test/spec.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

failures=0
pass() { printf 'ok   - %s\n' "$1"; }
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
assert_status() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$desc"
  else
    printf 'FAIL - %s\n     expected exit: %s\n     actual exit:   %s\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}

# new_repo: build a fresh scratch "repository" at a fresh temp dir, with the
# real script and a minimal set of fixture spec files covering all nine
# (specification, sequence) kinds spec.sh knows about:
#   IMPL 1 / IMPL 1a (requirements), IMPL AC 2 (acceptance check, deliberately
#   not also a requirement number), IMPL AC 2a-i (a hyphenated acceptance-check
#   sub-item, agent-ops#2544), IMPL C 3 (component, likewise);
#   REV R1 / REV AC 1 / REV C 1; MON M1 / MON AC 1 / MON C 1.
# lib/fixture.sh cites "requirement 1" (valid), "requirement 2" (wrong
# kind — 2 is only an acceptance check), "requirement 99" (dangling),
# "acceptance check 2a-i" (valid, hyphenated) and "acceptance check 2a-zzzz"
# (dangling, hyphenated — must not silently truncate to its parent "2a").
new_repo() {
  local dir
  dir="$(mktemp -d)"
  mkdir -p "$dir/scripts" "$dir/lib" \
    "$dir/docs/spec/implementation/requirements" \
    "$dir/docs/spec/implementation/acceptance-checks" \
    "$dir/docs/spec/implementation/components"
  cp "$SCRIPT_DIR/scripts/spec.sh" "$dir/scripts/spec.sh"
  chmod +x "$dir/scripts/spec.sh"

  cat > "$dir/docs/spec/implementation/requirements/fixture.md" <<'MD'
## Requirements

### Fixture section

1. <a id="impl-1"></a>**First requirement.** Does a thing.
1a. <a id="impl-1a"></a>**Sub-requirement.** Does a sub-thing.
MD

  cat > "$dir/docs/spec/implementation/acceptance-checks/fixture.md" <<'MD'
## Acceptance checks

2. <a id="impl-ac-2"></a>**First check.** Verifies the thing.
2a-i. <a id="impl-ac-2a-i"></a>**Hyphenated sub-check.** Verifies a sub-thing.
MD

  cat > "$dir/docs/spec/implementation/components/fixture.md" <<'MD'
## Components

3. <a id="impl-c-3"></a>`fixture.sh` implementing requirement 1.
MD

  cat > "$dir/docs/spec/review.md" <<'MD'
## Requirements

### Fixture section

R1. <a id="rev-r1"></a>**Review requirement.** Does a review thing.

## Components

1. <a id="rev-c-1"></a>`review-fixture.sh` implementing R1.

## Acceptance checks

1. <a id="rev-ac-1"></a>**Review check.** Verifies the review thing.
MD

  cat > "$dir/docs/spec/monitor.md" <<'MD'
## Requirements

### Fixture section

M1. <a id="mon-m1"></a>**Monitor requirement.** Does a monitor thing.

## Components

1. <a id="mon-c-1"></a>`monitor-fixture.sh` implementing M1.

## Acceptance checks

1. <a id="mon-ac-1"></a>**Monitor check.** Verifies the monitor thing.
MD

  cat > "$dir/lib/fixture.sh" <<'EOF'
#!/usr/bin/env bash
# Cites requirement 1 (valid).
# Cites requirement 2 (wrong kind: 2 is an acceptance check, not a requirement).
# Cites requirement 99 (dangling: no such label exists).
# Cites acceptance check 2a-i (valid, hyphenated sub-item).
# Cites acceptance check 2a-zzzz (dangling: no such hyphenated sub-item exists).
EOF

  (cd "$dir" && git init -q && git add -A)
  printf '%s' "$dir"
}

run() { (cd "$1" && shift && ./scripts/spec.sh "$@") ; }

# --- show ---
repo="$(new_repo)"
run "$repo" index >/dev/null
show_out="$(run "$repo" show 1a)"
assert_contains "show: prints the qualified label" "$show_out" "IMPL 1a"
assert_contains "show: prints file#anchor" "$show_out" "docs/spec/implementation/requirements/fixture.md#impl-1a"
assert_contains "show: prints the entry's own text" "$show_out" "Sub-requirement"

show_cite_out="$(run "$repo" show 1)"
assert_contains "show: surfaces a citing file" "$show_cite_out" "lib/fixture.sh"

run "$repo" show bogus >/dev/null 2>&1
assert_status "show: unknown label exits non-zero" "1" "$?"
rm -rf "$repo"

# --- where, across every input form the convention accepts ---
repo="$(new_repo)"
run "$repo" index >/dev/null
assert_eq "where: bare requirement number" \
  "docs/spec/implementation/requirements/fixture.md#impl-1" \
  "$(run "$repo" where 1)"
assert_eq "where: English 'requirement N'" \
  "docs/spec/implementation/requirements/fixture.md#impl-1" \
  "$(run "$repo" where "requirement 1")"
assert_eq "where: qualified IMPL form" \
  "docs/spec/implementation/requirements/fixture.md#impl-1a" \
  "$(run "$repo" where "IMPL 1a")"
assert_eq "where: English 'acceptance check N'" \
  "docs/spec/implementation/acceptance-checks/fixture.md#impl-ac-2" \
  "$(run "$repo" where "acceptance check 2")"
assert_eq "where: qualified IMPL AC form" \
  "docs/spec/implementation/acceptance-checks/fixture.md#impl-ac-2" \
  "$(run "$repo" where "IMPL AC 2")"
assert_eq "where: English 'acceptance check N-i' (hyphenated sub-item)" \
  "docs/spec/implementation/acceptance-checks/fixture.md#impl-ac-2a-i" \
  "$(run "$repo" where "acceptance check 2a-i")"
assert_eq "where: English 'component N'" \
  "docs/spec/implementation/components/fixture.md#impl-c-3" \
  "$(run "$repo" where "component 3")"
assert_eq "where: bare R-prefixed label means REV" \
  "docs/spec/review.md#rev-r1" \
  "$(run "$repo" where "R1")"
assert_eq "where: qualified REV form" \
  "docs/spec/review.md#rev-r1" \
  "$(run "$repo" where "REV R1")"
assert_eq "where: qualified REV AC form" \
  "docs/spec/review.md#rev-ac-1" \
  "$(run "$repo" where "REV AC 1")"
assert_eq "where: qualified REV C form" \
  "docs/spec/review.md#rev-c-1" \
  "$(run "$repo" where "REV C 1")"
assert_eq "where: bare M-prefixed label means MON" \
  "docs/spec/monitor.md#mon-m1" \
  "$(run "$repo" where "M1")"
assert_eq "where: qualified MON form" \
  "docs/spec/monitor.md#mon-m1" \
  "$(run "$repo" where "MON M1")"
assert_eq "where: qualified MON AC form" \
  "docs/spec/monitor.md#mon-ac-1" \
  "$(run "$repo" where "MON AC 1")"
assert_eq "where: qualified MON C form" \
  "docs/spec/monitor.md#mon-c-1" \
  "$(run "$repo" where "MON C 1")"
rm -rf "$repo"

# --- index ---
repo="$(new_repo)"
run "$repo" index >/dev/null
assert_eq "index: writes docs/spec/index.json" "1" "$(cd "$repo" && [[ -f docs/spec/index.json ]] && echo 1)"
assert_eq "index: records every one of the nine kinds' fixture label, plus the hyphenated sub-item" "11" \
  "$(cd "$repo" && jq '.labels | length' docs/spec/index.json)"
assert_eq "index: anchor for IMPL AC 2" "impl-ac-2" \
  "$(cd "$repo" && jq -r '.labels["IMPL AC 2"].anchor' docs/spec/index.json)"
assert_eq "index: anchor for IMPL AC 2a-i (hyphenated sub-item)" "impl-ac-2a-i" \
  "$(cd "$repo" && jq -r '.labels["IMPL AC 2a-i"].anchor' docs/spec/index.json)"

index_check_out="$(run "$repo" index --check)"
index_check_status=$?
assert_status "index --check: passes when fresh" "0" "$index_check_status"
assert_contains "index --check: says up to date" "$index_check_out" "up to date"

cat >> "$repo/docs/spec/implementation/requirements/fixture.md" <<'MD'
1b. <a id="impl-1b"></a>**Another sub-requirement.** Added after indexing.
MD
run "$repo" index --check >/dev/null 2>&1
assert_status "index --check: fails once the spec drifts" "1" "$?"
rm -rf "$repo"

# --- check ---
repo="$(new_repo)"
run "$repo" index >/dev/null
check_out="$(run "$repo" check 2>&1)"
check_status=$?
assert_status "check: fails against the fixture's own wrong-kind and dangling citations" "1" "$check_status"
assert_contains "check: reports the wrong-kind citation" "$check_out" "requirement 2"
assert_contains "check: reports the dangling citation" "$check_out" "requirement 99"
assert_contains "check: reports a dangling hyphenated sub-item citation rather than truncating to its parent" \
  "$check_out" "acceptance check 2a-zzzz"
if [[ "$check_out" == *"2a-i"* ]]; then
  printf 'FAIL - %s\n     did not expect to find: %s\n     actual:                 %s\n' \
    "check: does not report the valid hyphenated sub-item citation" "2a-i" "$check_out"
  failures=$(( failures + 1 ))
else
  pass "check: does not report the valid hyphenated sub-item citation"
fi

# Ratchet all three known violations away and confirm check passes.
line2="$(grep -n 'requirement 2 ' "$repo/lib/fixture.sh" | head -1 | cut -d: -f1)"
line99="$(grep -n 'requirement 99' "$repo/lib/fixture.sh" | head -1 | cut -d: -f1)"
line_zzzz="$(grep -n 'acceptance check 2a-zzzz' "$repo/lib/fixture.sh" | head -1 | cut -d: -f1)"
cat > "$repo/scripts/spec-check-ratchet.tsv" <<EOF
label	file	line	issue
IMPL 2	lib/fixture.sh	$line2	#000
IMPL 99	lib/fixture.sh	$line99	#000
IMPL AC 2a-zzzz	lib/fixture.sh	$line_zzzz	#000
EOF
ratcheted_out="$(run "$repo" check 2>&1)"
ratcheted_status=$?
assert_status "check: passes once all three violations are ratcheted" "0" "$ratcheted_status"
assert_contains "check: says every citation resolves" "$ratcheted_out" "every citation resolves"

# A ratchet entry naming the wrong line must not mask the violation.
cat > "$repo/scripts/spec-check-ratchet.tsv" <<EOF
label	file	line	issue
IMPL 2	lib/fixture.sh	9999	#000
EOF
run "$repo" check >/dev/null 2>&1
assert_status "check: a ratchet entry naming the wrong line does not suppress the failure" "1" "$?"
rm -f "$repo/scripts/spec-check-ratchet.tsv"

# A duplicate label must fail even with no citation involved.
cat > "$repo/docs/spec/implementation/components/fixture.md" <<'MD'
## Components

3. <a id="impl-c-3"></a>`fixture.sh` implementing requirement 1.
3. <a id="impl-c-3"></a>`duplicate.sh` reusing the same label by mistake.
MD
dup_out="$(run "$repo" check 2>&1)"
assert_status "check: fails on a duplicate label" "1" "$?"
assert_contains "check: names the duplicate label" "$dup_out" "duplicate label impl-c 3"
rm -rf "$repo"

if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures" >&2
  exit 1
fi
exit 0
