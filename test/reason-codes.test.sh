#!/usr/bin/env bash
#
# test/reason-codes.test.sh — verify all reason codes have documentation
# (issue #2098's first acceptance criterion), and that lib/reason-url.sh's
# link helper is pinned.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

assert() {
  local cond="$1" msg="${2:-assertion failed}"
  [[ "$cond" ]] || { echo "FAIL: $msg"; exit 1; }
}

assert_eq() {
  local actual="$1" expected="$2" msg="${3:-values differ}"
  [[ "$actual" == "$expected" ]] || {
    echo "FAIL: $msg (expected '$expected', got '$actual')"
    exit 1
  }
}

# shellcheck source=lib/reason-codes.sh
source lib/reason-codes.sh
# shellcheck source=lib/reason-url.sh
source lib/reason-url.sh

echo "Checking every stand-down cause is documented..."
while IFS= read -r code; do
  [[ -n "$code" ]] || continue
  has_documentation_entry "$code" \
    || { echo "FAIL: stand-down cause '$code' not documented in docs/reference/reasons.md"; exit 1; }
done < <(extract_standdown_causes)

echo "Checking every item fate is documented..."
while IFS= read -r code; do
  [[ -n "$code" ]] || continue
  has_documentation_entry "$code" \
    || { echo "FAIL: item fate '$code' not documented in docs/reference/reasons.md"; exit 1; }
done < <(extract_item_fates)

echo "Checking every pager kind is documented..."
while IFS= read -r code; do
  [[ -n "$code" ]] || continue
  has_documentation_entry "$code" \
    || { echo "FAIL: pager kind '$code' not documented in docs/reference/reasons.md"; exit 1; }
done < <(extract_pager_kinds)

echo "Checking every landing refusal class is documented..."
while IFS= read -r code; do
  [[ -n "$code" ]] || continue
  has_documentation_entry "$code" \
    || { echo "FAIL: landing refusal class '$code' not documented in docs/reference/reasons.md"; exit 1; }
done < <(extract_landing_refusal_classes)

echo "Checking the aggregate extractor and validator agree with each family..."
# shellcheck disable=SC2119  # the default-DOC_FILE form is what is wanted here.
assert_eq "$(validate_all_codes_documented && echo ok)" "ok" \
  "validate_all_codes_documented should pass against the shipped catalogue"

echo "Checking each extractor returns a known, non-empty set..."
assert "$(extract_standdown_causes)" "extract_standdown_causes returned nothing"
assert "$(extract_item_fates)" "extract_item_fates returned nothing"
assert "$(extract_pager_kinds)" "extract_pager_kinds returned nothing"
assert "$(extract_landing_refusal_classes)" "extract_landing_refusal_classes returned nothing"
assert_eq "$(extract_standdown_causes | grep -c .)" "17" \
  "the canonical stand-down cause count changed — update docs/reference/reasons.md if a code was added or removed"
assert_eq "$(extract_item_fates | grep -c .)" "7" \
  "the item fate count changed — update docs/reference/reasons.md if a fate was added or removed"

echo "Checking reason_docs_base_url and reason_code_url are pinned..."
assert_eq "$(reason_docs_base_url)" \
  "https://github.com/Pullwright/agent-ops/blob/main/docs/reference/reasons.md" \
  "the default catalogue base URL changed"
assert_eq "$(reason_code_url usage-limit)" \
  "https://github.com/Pullwright/agent-ops/blob/main/docs/reference/reasons.md#usage-limit" \
  "reason_code_url's anchor derivation changed"

echo "Checking reason_docs_base_url's setter form overrides the default..."
reason_docs_base_url "https://example.com/reasons"
assert_eq "$(reason_code_url landed)" "https://example.com/reasons#landed" \
  "reason_code_url did not pick up an overridden base"
unset REASON_DOCS_BASE_URL

echo "✓ All reason codes are documented, and the link helper is pinned"
