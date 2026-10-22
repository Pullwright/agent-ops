#!/usr/bin/env bash
#
# lib/reason-codes.sh — extract and validate reason codes from the codebase
#
# This library provides functions to extract reason codes from the source code
# and validate that all codes have corresponding documentation entries.
#
# Sourced, never executed: no shell options are set here, matching every
# other lib/*.sh — the caller owns those.

# Extract all stand-down cause codes from the codebase
extract_standdown_causes() {
  # Get all explicit standdown_cause assignments plus known ones from mappings
  (
    grep -rh 'standdown_cause=' lib/ scripts/ 2>/dev/null \
      | grep -o 'standdown_cause="[a-z-]*"' \
      | cut -d'"' -f2

    # Known causes from node-time-state.sh mapping
    cat <<'CAUSES'
disabled-node
disabled-fleet
usage-limit
github-budget
unreachable
unauthorized
credential-refused
disk-low
disk-full
memory-low
host-overcommit
roll-pending
back-pressure
awaiting-tick
peer-claimed
coordinator-declined
no-demand
CAUSES
  ) | sort -u
}

# Extract all reason codes from log_event calls
extract_reason_codes_from_logs() {
  # Look for item_event_fields calls which take a reason parameter
  # This is a simplified approach that looks for common patterns
  grep -rh 'item_event_fields.*"' lib/ 2>/dev/null \
    | grep -o 'item_event_fields "[^"]*"' \
    | sed 's/item_event_fields "\(.*\)"/\1/' \
    | grep -v '^\$' \
    | sort -u
}

# Extract all reason codes referenced in the flow-schema vocabulary
extract_flow_schema_reasons() {
  # Extract cause names from the node_time_state_for_cause function
  sed -n '/^node_time_state_for_cause/,/^}/p' lib/node-time-state.sh \
    | grep 'printf' \
    | sed "s/.*printf '[^']*'\t\([a-z-]*\).*/\1/" \
    | grep -E '^[a-z-]+$' \
    | sort -u
}

# Extract pager remedy classes
extract_pager_classes() {
  grep -roh 'remedy_class="[^"]*"' lib/ scripts/ 2>/dev/null \
    | sed 's/remedy_class="\(.*\)"/\1/' \
    | sort -u
}

# Extract all reason codes from the codebase
extract_all_reason_codes() {
  (
    extract_standdown_causes
    extract_reason_codes_from_logs
    extract_flow_schema_reasons
  ) | sort -u
}

# Check if a code has a documentation entry
has_documentation_entry() {
  local code="$1"
  local doc_file="${2:-docs/reference/reasons.md}"

  if [[ ! -f "$doc_file" ]]; then
    return 1
  fi

  # Check if the code appears in the documentation as a documented entry
  grep -q "^###\s*\`$code\`" "$doc_file" || grep -q "^#### \`$code\`" "$doc_file"
}

# Validate that all codes have documentation
validate_all_codes_documented() {
  local doc_file="${1:-docs/reference/reasons.md}"
  local undocumented=()

  while IFS= read -r code; do
    if ! has_documentation_entry "$code" "$doc_file"; then
      undocumented+=("$code")
    fi
  done < <(extract_all_reason_codes)

  if (( ${#undocumented[@]} > 0 )); then
    printf 'Undocumented reason codes: %s\n' "${undocumented[@]}" >&2
    return 1
  fi

  return 0
}
