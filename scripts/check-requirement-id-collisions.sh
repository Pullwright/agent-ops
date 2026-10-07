#!/usr/bin/env bash
#
# scripts/check-requirement-id-collisions.sh — permanent CI guard against
# duplicate requirement ids across sections in
# docs/spec/implementation/requirements/*.md and docs/spec/implementation/acceptance-checks/*.md
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
# more than one ### section, unless that id is in the allowlist below. It
# also fails if any bare acceptance-check id heading repeats within the flat
# "## Acceptance checks" region (which has no ### subsections of its own),
# unless that id is in the second allowlist below (issue #2110).
#
# Exit 0 iff no collision outside either allowlist is found in the spec file.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 1

# Unquoted everywhere it is read (test/check-requirement-id-collisions.test.sh
# sed-replaces this one assignment with a single quoted fixture path; in
# production it is two glob patterns, which an unquoted expansion turns into
# every requirements/ and acceptance-checks/ file, read in one pass exactly
# as the single pre-#2094 file was — the ### section a requirement id sits
# under, and whether an acceptance-check id repeats, do not depend on which
# file holds which heading, only on the headings themselves in file order.
spec_file="docs/spec/implementation/requirements/*.md docs/spec/implementation/acceptance-checks/*.md"

# Known pre-existing collisions, left unresolved by issue #1105's own scope
# decision (qualify citations, don't renumber) and tracked individually:
# 39/39c (issue #1105 itself; the two "The Script"/"The Refiner" pairs),
# 55 (issue #1584), 17b and 17g (both within the single "The Co-Ordinator
# (selection only)" section). This allowlist is also the collision inventory
# issue #2095's own renumbering proposal would start from. Only a collision
# outside this list fails the check; growing this list for a new collision
# is itself a sign that id should be renumbered or qualified instead, not a
# routine maintenance edit.
allowlisted_ids=(39 39c 55 17b 17g)

# Known pre-existing collisions within the flat "## Acceptance checks"
# region, which has no ### subsections of its own and so cannot be checked
# by section like the Requirements region above (issue #2110). A repeated id
# here is the same kind of ambiguous cross-reference issue #1105 documented
# for Requirements, just discovered by direct scan rather than per-section
# comparison: 39a/39c mirror the Requirements-side 39/39c pair; the rest
# (1c, 1d, 1m, 51, 55, 8e, 8w, 8x) are pre-existing collisions this region's
# own flat structure already had, found while extending this script. Only a
# collision outside this list fails the check; growing this list for a new
# collision is itself a sign that id should be renumbered or qualified
# instead, not a routine maintenance edit.
acceptance_allowlisted_ids=(1c 1d 1m 39a 39c 51 55 8e 8w 8x)

# shellcheck disable=SC2206  # Unquoted on purpose: $spec_file is glob patterns in production.
spec_files=( $spec_file )
if (( ${#spec_files[@]} == 0 )) || [[ ! -f "${spec_files[0]}" ]]; then
  echo "check-requirement-id-collisions: $spec_file matches no file" >&2
  exit 1
fi

# Extract all requirement id headings and their sections from the
# "## Requirements" section, and separately count repeated id headings
# within the flat "## Acceptance checks" section (which has no ### subsections
# of its own, so a repeated id there is detected by direct count rather than
# by comparing sections).
# Format of heading: "^NN[a-z]?\. \*\*"
# We'll track: requirement_id -> list of sections, and acceptance_id -> count

declare -A requirement_sections
declare -A acceptance_heading_counts

current_section=""
in_requirements_section=0
in_acceptance_section=0

while IFS= read -r line; do
  # Detect top-level section headers (## ...)
  if [[ $line =~ ^##\ (.+)$ ]]; then
    section_name="${BASH_REMATCH[1]}"
    if [[ "$section_name" == "Requirements" ]]; then
      in_requirements_section=1
    else
      in_requirements_section=0
    fi
    if [[ "$section_name" == "Acceptance checks" ]]; then
      in_acceptance_section=1
    else
      in_acceptance_section=0
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

  # Detect acceptance-check headings (NNx. **), counting repeats within the
  # flat Acceptance checks section
  if (( in_acceptance_section )) && [[ $line =~ ^([0-9]+[a-z]?)\.\ \*\* ]]; then
    acc_id="${BASH_REMATCH[1]}"
    acceptance_heading_counts[$acc_id]=$(( ${acceptance_heading_counts[$acc_id]:-0} + 1 ))
  fi
done < <(cat "${spec_files[@]}")

# Check for collisions
exit_code=0
for req_id in "${!requirement_sections[@]}"; do
  sections="${requirement_sections[$req_id]}"

  # Count the number of sections (separated by |)
  section_count=$(grep -o '|' <<< "$sections" | wc -l)
  section_count=$((section_count + 1))

  if (( section_count > 1 )); then
    is_allowlisted=0
    for allowed in "${allowlisted_ids[@]}"; do
      if [[ "$req_id" == "$allowed" ]]; then
        is_allowlisted=1
        break
      fi
    done
    if (( is_allowlisted )); then
      continue
    fi

    echo "check-requirement-id-collisions: requirement id '$req_id' appears in multiple sections:" >&2
    IFS='|' read -ra section_array <<< "$sections"
    for sec in "${section_array[@]}"; do
      echo "  - $sec" >&2
    done
    exit_code=1
  fi
done

for acc_id in "${!acceptance_heading_counts[@]}"; do
  count="${acceptance_heading_counts[$acc_id]}"

  if (( count > 1 )); then
    is_allowlisted=0
    for allowed in "${acceptance_allowlisted_ids[@]}"; do
      if [[ "$acc_id" == "$allowed" ]]; then
        is_allowlisted=1
        break
      fi
    done
    if (( is_allowlisted )); then
      continue
    fi

    echo "check-requirement-id-collisions: acceptance-check id '$acc_id' heads $count checks in the Acceptance checks section" >&2
    exit_code=1
  fi
done

exit $exit_code
