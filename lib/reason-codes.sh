#!/usr/bin/env bash
#
# lib/reason-codes.sh — extract reason codes from the codebase for
# docs/reference/reasons.md's own coverage check (issue #2098's first
# acceptance criterion).
#
# Four closed vocabularies, one extractor each: each reads the one function
# or variable that is already that vocabulary's single source of truth —
# never a second, hand-maintained copy of it — so a code added there is
# picked up here with no edit to this file.
#
# Three families the issue also named — doctor.sh's check names, the kinds
# of escalation, and the Monitor's own finding classes — have no such
# closed vocabulary in the code today: doctor.sh emits free-text messages
# under section()/ok()/warn()/fail() headings, not named check codes, and
# neither escalation kinds nor Monitor finding classes are enumerated as
# string constants anywhere. Giving them one is a design decision — adding
# a code vocabulary to a dense, already-large file — not a docs-and-wiring
# change, so docs/reference/reasons.md says so in prose instead of
# fabricating entries for codes that do not exist (see #2625 for the
# tech-debt issue tracking it).
#
# Sourced, never executed: no shell options are set here, matching every
# other lib/*.sh — the caller owns those.

# extract_standdown_causes
# The eighteen-token closed cause vocabulary `lib/node-time-state.sh`'s
# `node_time_state_for_cause` maps to a state: the canonical cause each case
# arm echoes back after its own tab, which for an arm with aliases (e.g.
# `peer-claimed|raced|pre-claimed`) is the one name downstream events ever
# carry — the aliases themselves are translated away before they reach a
# `node-state` event (that function's own header), so they are never codes
# of their own to document.
extract_standdown_causes() {
  sed -n '/^node_time_state_for_cause()/,/^}/p' lib/node-time-state.sh \
    | grep -oE "printf '[a-z-]+\\\\t[a-z-]+\\\\n'" \
    | sed -E "s/printf '[a-z-]+\\\\t([a-z-]+)\\\\n'/\\1/" \
    | sort -u
}

# extract_item_fates
# The seven-value closed vocabulary `lib/item-lifecycle.sh`'s terminal-fate
# fold assigns (docs/reference/flow-schema.md's "Terminal fates"): every
# `{fate: "..."}` object literal the fold's own jq program constructs.
extract_item_fates() {
  grep -oh '{fate: "[a-z]*"' lib/item-lifecycle.sh \
    | sed -E 's/\{fate: "([a-z]*)"/\1/' \
    | sort -u
}

# extract_pager_kinds
# The closed set of pager invariant keys `lib/pager-invariants.sh` registers
# via `pager_register KEY EVAL_FN [REMEDY_CLASS [REMEDY_ARG]] …` — each KEY
# is the `key` a fired page is filed and closed under (`lib/pager.sh`'s
# `pager_file`/`pager_close`), so this is exactly the vocabulary a reader
# sees in a page's own title and `ref:` line.
extract_pager_kinds() {
  grep -oh '^[[:space:]]*pager_register [a-z0-9-]*' lib/pager-invariants.sh \
    | sed -E 's/^[[:space:]]*pager_register //' \
    | sort -u
}

# extract_landing_refusal_classes
# The closed set `_LANDING_REFUSAL_CLASSES` (lib/landing.sh) enumerates —
# every value `_landing_refuse` may be called with — read from that one
# space-separated string rather than re-listed here, so a class added there
# is picked up with no edit to this file.
extract_landing_refusal_classes() {
  # shellcheck disable=SC2016  # the sed pattern's own literal $'s, not the shell's.
  grep -oh '^_LANDING_REFUSAL_CLASSES="[^"]*"' lib/landing.sh \
    | sed -E 's/^_LANDING_REFUSAL_CLASSES="(.*)"$/\1/' \
    | tr ' ' '\n' \
    | sort -u
}

# extract_all_reason_codes
# Every reason code the four closed vocabularies above enumerate, deduped
# across families (none of the four shares a token with another today, but
# a future collision would still only cost one documentation entry, not a
# conflict).
extract_all_reason_codes() {
  (
    extract_standdown_causes
    extract_item_fates
    extract_pager_kinds
    extract_landing_refusal_classes
  ) | sort -u
}

# has_documentation_entry CODE [DOC_FILE]
# Exit 0 when CODE has its own `### \`CODE\`` (or `#### \`CODE\``) heading in
# DOC_FILE (default docs/reference/reasons.md).
has_documentation_entry() {
  local code="$1"
  local doc_file="${2:-docs/reference/reasons.md}"

  [[ -f "$doc_file" ]] || return 1

  grep -q "^###\s*\`$code\`" "$doc_file" || grep -q "^####\s*\`$code\`" "$doc_file"
}

# validate_all_codes_documented [DOC_FILE]
# Exit 0 when every code `extract_all_reason_codes` names has a
# documentation entry in DOC_FILE; otherwise prints the undocumented codes
# to stderr and exits 1.
validate_all_codes_documented() {
  local doc_file="${1:-docs/reference/reasons.md}"
  local -a undocumented=()
  local code

  while IFS= read -r code; do
    [[ -n "$code" ]] || continue
    has_documentation_entry "$code" "$doc_file" || undocumented+=("$code")
  done < <(extract_all_reason_codes)

  if (( ${#undocumented[@]} > 0 )); then
    printf 'Undocumented reason codes: %s\n' "${undocumented[*]}" >&2
    return 1
  fi

  return 0
}
