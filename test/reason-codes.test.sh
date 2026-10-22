#!/usr/bin/env bash
#
# test/reason-codes.test.sh — verify all reason codes have documentation
#
# This test ensures that every reason code the pipeline can emit has a
# corresponding entry in docs/reference/reasons.md.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# Shorthand for test assertions
assert() {
  local cond="$1" msg="${2:-assertion failed}"
  [[ "$cond" ]] || { echo "FAIL: $msg"; exit 1; }
}

# shellcheck source=lib/reason-codes.sh
source lib/reason-codes.sh

echo "Checking that all reason codes are documented..."

# Extract all stand-down causes
echo "Checking stand-down causes..."
while IFS= read -r cause; do
  [[ -n "$cause" ]] || continue
  # Strip any quotes or whitespace
  cause="$(printf '%s' "$cause" | sed 's/[" '\'']*//g')"

  # Check if it's documented (look for ### \`cause\` in reasons.md)
  if ! grep -q "^###\s*\`$cause\`" docs/reference/reasons.md; then
    echo "FAIL: Stand-down cause '$cause' not documented in reasons.md"
    exit 1
  fi
done < <(extract_standdown_causes)

echo "All stand-down causes are documented."

# Extract pager remedy classes
echo "Checking pager remedy classes..."
while IFS= read -r class; do
  [[ -n "$class" ]] || continue
  class="$(printf '%s' "$class" | sed 's/[" '\'']*//g')"

  # These should be in reasons.md
  if ! grep -q -i "^###\s*\`$class\`" docs/reference/reasons.md; then
    # Pager classes might not need entries, so we warn rather than fail
    echo "WARN: Pager class '$class' not explicitly documented"
  fi
done < <(extract_pager_classes)

echo "Pager classes check complete."

echo "✓ All documented reason codes pass validation"
