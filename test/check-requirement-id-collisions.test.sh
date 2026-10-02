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
echo "All tests passed!"
