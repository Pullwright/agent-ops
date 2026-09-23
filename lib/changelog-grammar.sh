#!/usr/bin/env bash
# lib/changelog-grammar.sh — shared parser for the `## Changelog` section
# grammar (requirement 25c, roadmap decision D27, agent-ops#1807). Walks a
# pull-request description — or a squashed commit body, the same shape —
# once, and emits one tab-separated record per event on stdout, so
# scripts/check-changelog-section.sh (validates a description) and
# scripts/assemble-changelog.sh (extracts bullets from merged commit bodies)
# read the same grammar off the same state machine instead of each
# re-implementing the fence/HTML-comment/heading walk and the
# None/category/bullet classification underneath it.
#
# Usage: source this file, then call `changelog_grammar_walk "$body"` and
# read its stdout. Record shapes (`<n>` numbers each `## Changelog` heading
# found, in document order, starting at 1 — a caller that wants only the
# first content-bearing one, as an assembler reading a single commit body
# does, filters on it; a caller that must fault a second one with content,
# as the checker does, watches for a second `SECTION-END` whose
# content-lines is greater than 0):
#
#   SECTION-START  <n>
#   SECTION-END    <n>  <content-lines>
#   NONE           <n>  <line>
#   NONE-BAD       <n>  category|bullet  <line>
#   BAD-FIRST      <n>  <line>
#   CATEGORY       <n>  <name>  <valid 0|1>  <dup 0|1>
#   CATEGORY-END   <n>  <name>  <bullet-count>
#   BULLET         <n>  <line>
#   CONTINUATION   <n>  <category>  <open 0|1>  <line>
#   LOOSE          <n>  <category>  <line>
#   UNCLOSED-FENCE
#   UNCLOSED-COMMENT
#
# A `<line>` field is always the last field of its record, carrying the
# source line verbatim, tabs and all — a caller peels the fields ahead of it
# one at a time with a 2-variable `read` (`IFS=$'\t' read -r field rest`),
# never a single multi-variable `read` across the whole record, so an
# embedded tab inside the line itself (real tab indentation, pasted content)
# lands in `rest` intact rather than being mistaken for a field boundary.
# `<name>`/`<category>` (heading text) is not given the same protection —
# a literal tab inside a `### <Category>` heading is accepted as a known,
# vanishingly rare edge case rather than engineered around.
#
# Fields never carry a literal newline (one input line in, one output
# record out).

CHANGELOG_GRAMMAR_CATEGORIES='Added|Changed|Deprecated|Removed|Fixed|Security'

_changelog_grammar_close_category() {
  if [[ -n "$_changelog_grammar_category" ]]; then
    printf 'CATEGORY-END\t%s\t%s\t%s\n' \
      "$_changelog_grammar_section_n" "$_changelog_grammar_category" "$_changelog_grammar_bullets"
  fi
  _changelog_grammar_category=""
  _changelog_grammar_bullets=0
}

_changelog_grammar_close_section() {
  (( _changelog_grammar_in_section )) || return 0
  if [[ "$_changelog_grammar_mode" == "categories" ]]; then
    _changelog_grammar_close_category
  fi
  printf 'SECTION-END\t%s\t%s\n' "$_changelog_grammar_section_n" "$_changelog_grammar_content_lines"
  _changelog_grammar_in_section=0
  _changelog_grammar_mode=""
}

changelog_grammar_walk() {
  local body="$1" line
  local _changelog_grammar_in_fence=0 _changelog_grammar_fence_char=""
  local _changelog_grammar_in_comment=0
  local _changelog_grammar_in_section=0 _changelog_grammar_mode=""
  local _changelog_grammar_category="" _changelog_grammar_bullets=0
  local _changelog_grammar_seen_categories="" _changelog_grammar_content_lines=0
  local _changelog_grammar_section_n=0
  local valid dup open

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"

    if (( _changelog_grammar_in_fence )); then
      if [[ "$line" =~ ^[[:space:]]{0,3}(\`{3,}|~{3,}) ]]; then
        [[ "${BASH_REMATCH[1]:0:1}" == "$_changelog_grammar_fence_char" ]] && _changelog_grammar_in_fence=0
      fi
      continue
    fi
    if (( _changelog_grammar_in_comment )); then
      [[ "$line" == *'-->'* ]] && _changelog_grammar_in_comment=0
      continue
    fi
    if [[ "$line" =~ ^[[:space:]]{0,3}(\`{3,}|~{3,}) ]]; then
      _changelog_grammar_in_fence=1
      _changelog_grammar_fence_char="${BASH_REMATCH[1]:0:1}"
      continue
    fi
    if [[ "$line" =~ ^[[:space:]]*\<!-- ]]; then
      [[ "$line" == *'-->'* ]] || _changelog_grammar_in_comment=1
      continue
    fi

    if [[ "$line" =~ ^##[[:space:]]+[Cc][Hh][Aa][Nn][Gg][Ee][Ll][Oo][Gg][[:space:]]*$ ]]; then
      _changelog_grammar_close_section
      _changelog_grammar_section_n=$(( _changelog_grammar_section_n + 1 ))
      _changelog_grammar_in_section=1
      _changelog_grammar_mode=""
      _changelog_grammar_content_lines=0
      _changelog_grammar_seen_categories=""
      printf 'SECTION-START\t%s\n' "$_changelog_grammar_section_n"
      continue
    fi
    if [[ "$line" =~ ^#[[:space:]] || "$line" =~ ^##[[:space:]]+[^#[:space:]] ]]; then
      _changelog_grammar_close_section
      continue
    fi

    (( _changelog_grammar_in_section )) || continue
    [[ "$_changelog_grammar_mode" == "bad" ]] && continue
    [[ -z "${line//[[:space:]]/}" ]] && continue
    _changelog_grammar_content_lines=$(( _changelog_grammar_content_lines + 1 ))

    case "$_changelog_grammar_mode" in
      "")
        if [[ "$line" =~ ^None([[:space:][:punct:]]|$) ]]; then
          _changelog_grammar_mode="none"
          printf 'NONE\t%s\t%s\n' "$_changelog_grammar_section_n" "$line"
        elif [[ "$line" =~ ^###[[:space:]]+(.+[^[:space:]])[[:space:]]*$ ]]; then
          _changelog_grammar_mode="categories"
          _changelog_grammar_category="${BASH_REMATCH[1]}"
          _changelog_grammar_bullets=0
          valid=1
          [[ "$_changelog_grammar_category" =~ ^(${CHANGELOG_GRAMMAR_CATEGORIES})$ ]] || valid=0
          _changelog_grammar_seen_categories=" $_changelog_grammar_category "
          printf 'CATEGORY\t%s\t%s\t%s\t0\n' \
            "$_changelog_grammar_section_n" "$_changelog_grammar_category" "$valid"
        else
          printf 'BAD-FIRST\t%s\t%s\n' "$_changelog_grammar_section_n" "$line"
          _changelog_grammar_mode="bad"
        fi
        ;;
      none)
        if [[ "$line" =~ ^###[[:space:]] ]]; then
          printf 'NONE-BAD\t%s\tcategory\t%s\n' "$_changelog_grammar_section_n" "$line"
          _changelog_grammar_mode="bad"
        elif [[ "$line" =~ ^[[:space:]]*[-*][[:space:]]+[^[:space:]] ]]; then
          printf 'NONE-BAD\t%s\tbullet\t%s\n' "$_changelog_grammar_section_n" "$line"
          _changelog_grammar_mode="bad"
        else
          printf 'NONE\t%s\t%s\n' "$_changelog_grammar_section_n" "$line"
        fi
        ;;
      categories)
        if [[ "$line" =~ ^###[[:space:]]+(.+[^[:space:]])[[:space:]]*$ ]]; then
          _changelog_grammar_close_category
          _changelog_grammar_category="${BASH_REMATCH[1]}"
          _changelog_grammar_bullets=0
          valid=1
          [[ "$_changelog_grammar_category" =~ ^(${CHANGELOG_GRAMMAR_CATEGORIES})$ ]] || valid=0
          dup=0
          [[ "$_changelog_grammar_seen_categories" == *" $_changelog_grammar_category "* ]] && dup=1
          _changelog_grammar_seen_categories="$_changelog_grammar_seen_categories $_changelog_grammar_category "
          printf 'CATEGORY\t%s\t%s\t%s\t%s\n' \
            "$_changelog_grammar_section_n" "$_changelog_grammar_category" "$valid" "$dup"
        elif [[ "$line" =~ ^[-*][[:space:]]+[^[:space:]] ]]; then
          _changelog_grammar_bullets=$(( _changelog_grammar_bullets + 1 ))
          printf 'BULLET\t%s\t%s\n' "$_changelog_grammar_section_n" "$line"
        elif [[ "$line" =~ ^[[:space:]]+[^[:space:]] ]]; then
          open=1
          (( _changelog_grammar_bullets > 0 )) || open=0
          printf 'CONTINUATION\t%s\t%s\t%s\t%s\n' \
            "$_changelog_grammar_section_n" "$_changelog_grammar_category" "$open" "$line"
        else
          printf 'LOOSE\t%s\t%s\t%s\n' \
            "$_changelog_grammar_section_n" "$_changelog_grammar_category" "$line"
        fi
        ;;
    esac
  done <<<"$body"
  _changelog_grammar_close_section

  (( _changelog_grammar_in_fence )) && printf 'UNCLOSED-FENCE\n'
  (( _changelog_grammar_in_comment )) && printf 'UNCLOSED-COMMENT\n'
}
