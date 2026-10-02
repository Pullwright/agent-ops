#!/usr/bin/env bash
#
# scripts/check-requirement-id-collisions.sh — permanent CI guard against
# duplicate requirement ids across sections in docs/IMPLEMENTATION-PIPELINE-SPEC.md
# (issue #1105).
#
# Requirement ids (e.g., "39c") are unique within the ### section that defines
# them, but this script enforces that they do not collide across different
# sections — e.g., two different "39c. **..." headings under "### The Script"
# and "### The Refiner" would be a collision. When such a collision is
# detected, cross-references become ambiguous and must be qualified with
# section names.
#
# This script fails (exit 1) if any bare requirement id heading appears under
# more than one ### section. Otherwise it exits 0.
#
# Exit 0 iff no collisions are found in the spec file.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 1

spec_file="docs/IMPLEMENTATION-PIPELINE-SPEC.md"

if [[ ! -f "$spec_file" ]]; then
  echo "check-requirement-id-collisions: $spec_file not found" >&2
  exit 1
fi

# Extract all requirement id headings and their sections, but only from the
# "## Requirements" section, not from "## Acceptance checks" (which mirrors
# the same ids as acceptance criteria, not as separate requirement definitions).
# Format of heading: "^NN[a-z]?\. \*\*"
# We'll track: requirement_id -> list of sections

declare -A requirement_sections

current_section=""
in_requirements_section=0

while IFS= read -r line; do
  # Detect top-level section headers (## ...)
  if [[ $line =~ ^##\ (.+)$ ]]; then
    section_name="${BASH_REMATCH[1]}"
    if [[ "$section_name" == "Requirements" ]]; then
      in_requirements_section=1
    else
      in_requirements_section=0
    fi
  fi

  # Detect subsection headers (### ...)
  if [[ $line =~ ^###\ (.+)$ ]]; then
    if (( in_requirements_section )); then
      current_section="${BASH_REMATCH[1]}"
    fi
  fi

  # Detect requirement headings (NNx. **), but only in the Requirements section
  if (( in_requirements_section )) && [[ $line =~ ^([0-9]+[a-z]?)\.\ \*\* ]]; then
    req_id="${BASH_REMATCH[1]}"

    if [[ -z "$current_section" ]]; then
      # This shouldn't happen in a well-formed spec, but skip it
      continue
    fi

    # Track this requirement id with its section
    if [[ -z "${requirement_sections[$req_id]:-}" ]]; then
      requirement_sections[$req_id]="$current_section"
    else
      requirement_sections[$req_id]="${requirement_sections[$req_id]}|$current_section"
    fi
  fi
done < "$spec_file"

# Check for collisions
exit_code=0
for req_id in "${!requirement_sections[@]}"; do
  sections="${requirement_sections[$req_id]}"

  # Count the number of sections (separated by |)
  section_count=$(grep -o '|' <<< "$sections" | wc -l)
  section_count=$((section_count + 1))

  if (( section_count > 1 )); then
    echo "check-requirement-id-collisions: requirement id '$req_id' appears in multiple sections:" >&2
    IFS='|' read -ra section_array <<< "$sections"
    for sec in "${section_array[@]}"; do
      echo "  - $sec" >&2
    done
    exit_code=1
  fi
done

exit $exit_code
