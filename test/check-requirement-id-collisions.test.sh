#!/usr/bin/env bash
#
# test/check-requirement-id-collisions.test.sh — test the collision-checker script
# at scripts/check-requirement-id-collisions.sh

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 1

script="scripts/check-requirement-id-collisions.sh"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

# Test 1: Fixture with no collisions
cat > "$tmpdir/no-collisions.md" << 'EOF'
# Test Document

## Requirements

### The Script
1. **First requirement.** Something here.

### The Refiner
39. **Engagement.** Something different here.

## Acceptance checks

1. **First requirement acceptance.** Test this.

39. **Engagement acceptance.** Test this.
EOF

# Test 2: Fixture with a collision on an id that is not allowlisted
cat > "$tmpdir/with-collisions.md" << 'EOF'
# Test Document

## Requirements

### The Script
99. **Finish-then-continue.** Something here.

### The Refiner
99. **Engagement.** Something different here.

## Acceptance checks

99. **Finish-then-continue acceptance.** Test this.
EOF

# Test 3: Fixture whose only collision is on an allowlisted id (e.g. 39) —
# must still pass, since the allowlist exists so the checker does not go
# permanently red over the known pre-existing collisions issue #1105 chose
# to qualify rather than resolve.
cat > "$tmpdir/allowlisted-collision.md" << 'EOF'
# Test Document

## Requirements

### The Script
39. **Finish-then-continue.** Something here.

### The Refiner
39. **Engagement.** Something different here.

## Acceptance checks

39. **Finish-then-continue acceptance.** Test this.
EOF

# Test 4: Fixture with an unallowlisted collision only within the flat
# Acceptance checks section (Requirements side has no collision at all) —
# must fail, naming the id.
cat > "$tmpdir/acceptance-collision.md" << 'EOF'
# Test Document

## Requirements

### The Script
1. **First requirement.** Something here.

### The Refiner
2. **Second requirement.** Something different here.

## Acceptance checks

77. **First acceptance check.** Test this.

77. **A different, unrelated acceptance check.** Test something else.
EOF

# Test 5: Fixture whose only Acceptance-checks collision is on an
# allowlisted id (39a) — must still pass.
cat > "$tmpdir/acceptance-allowlisted-collision.md" << 'EOF'
# Test Document

## Requirements

### The Script
1. **First requirement.** Something here.

## Acceptance checks

39a. **First acceptance check.** Test this.

39a. **A different, unrelated acceptance check.** Test something else.
EOF

# Test 6: Fixture with both a Requirements-region collision (unallowlisted)
# and an Acceptance-checks-region collision (unallowlisted) at once — the
# allowlisted-ness of one must not mask the other failing independently.
cat > "$tmpdir/both-collisions.md" << 'EOF'
# Test Document

## Requirements

### The Script
88. **Something.** Something here.

### The Refiner
88. **Something else.** Something different here.

## Acceptance checks

77. **First acceptance check.** Test this.

77. **A different, unrelated acceptance check.** Test something else.
EOF

# Create a wrapper script that uses the temp fixtures
test_with_fixture() {
  local fixture="$1"

  # Create a temporary script that checks the fixture instead of the real spec
  local temp_script="$tmpdir/check.sh"
  sed "s|spec_file=.*|spec_file=\"$fixture\"|" "$script" > "$temp_script"
  chmod +x "$temp_script"
  "$temp_script"
}

echo "Test 1: Fixture with no collisions should pass..."
if test_with_fixture "$tmpdir/no-collisions.md"; then
  echo "✓ PASS: No collisions detected (as expected)"
else
  echo "✗ FAIL: Expected no collisions but checker failed"
  exit 1
fi

echo ""
echo "Test 2: Fixture with a non-allowlisted collision (99 in Script vs Refiner)..."
if test_with_fixture "$tmpdir/with-collisions.md"; then
  echo "✗ FAIL: Expected collision to be detected but checker passed"
  exit 1
else
  echo "✓ PASS: Collision detected (as expected)"
fi

echo ""
echo "Test 3: Fixture whose only collision is allowlisted (39 in Script vs Refiner)..."
if test_with_fixture "$tmpdir/allowlisted-collision.md"; then
  echo "✓ PASS: Allowlisted collision did not fail the check (as expected)"
else
  echo "✗ FAIL: Expected allowlisted collision to pass but checker failed"
  exit 1
fi

echo ""
echo "Test 4: Fixture with a non-allowlisted Acceptance-checks collision (77)..."
stderr_4="$(test_with_fixture "$tmpdir/acceptance-collision.md" 2>&1 1>/dev/null)"
exit_4=$?
if (( exit_4 == 0 )); then
  echo "✗ FAIL: Expected Acceptance-checks collision to be detected but checker passed"
  exit 1
elif [[ "$stderr_4" != *"'77'"* ]]; then
  echo "✗ FAIL: Checker failed but did not name id '77':"
  echo "$stderr_4"
  exit 1
else
  echo "✓ PASS: Acceptance-checks collision detected and id named (as expected)"
fi

echo ""
echo "Test 5: Fixture whose only Acceptance-checks collision is allowlisted (39a)..."
if test_with_fixture "$tmpdir/acceptance-allowlisted-collision.md"; then
  echo "✓ PASS: Allowlisted Acceptance-checks collision did not fail the check (as expected)"
else
  echo "✗ FAIL: Expected allowlisted Acceptance-checks collision to pass but checker failed"
  exit 1
fi

echo ""
echo "Test 6: Fixture with independent Requirements (88) and Acceptance-checks (77)"
echo "collisions at once — neither being allowlisted must mask the other failing..."
stderr_6="$(test_with_fixture "$tmpdir/both-collisions.md" 2>&1 1>/dev/null)"
exit_6=$?
if (( exit_6 == 0 )); then
  echo "✗ FAIL: Expected both collisions to be detected but checker passed"
  exit 1
elif [[ "$stderr_6" != *"'88'"* ]]; then
  echo "✗ FAIL: Checker failed but did not name requirement id '88':"
  echo "$stderr_6"
  exit 1
elif [[ "$stderr_6" != *"'77'"* ]]; then
  echo "✗ FAIL: Checker failed but did not name acceptance-check id '77':"
  echo "$stderr_6"
  exit 1
else
  echo "✓ PASS: Both independent collisions detected (as expected)"
fi

echo ""
echo "All tests passed!"
