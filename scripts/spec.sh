#!/usr/bin/env bash
#
# scripts/spec.sh — read-only lookup and validation for every anchored
# requirement, acceptance-check and component label across
# docs/spec/implementation/, docs/spec/review.md and docs/spec/monitor.md
# (issue #2095).
#
# A label is addressed by a *qualified* form naming which specification and
# which sequence it belongs to: "IMPL 17a" (a requirement), "IMPL AC 1g"
# (an acceptance check), "IMPL C 14b" (a component), "REV R5", "REV AC 5",
# "REV C 5", "MON M4", "MON AC 4", "MON C 4". A bare label ("17a") or the
# existing English phrase ("requirement 17a") means the implementation
# specification's requirement, unchanged from before this convention
# existed. A bare "R5"/"M4"-shaped label means the review/monitor
# specification's requirement, since those two sequences already embed
# their own letter. See docs/README.md "Requirement-label citations".
#
# Usage:
#   scripts/spec.sh show <label>    Print the entry and what cites it.
#   scripts/spec.sh where <label>   Print "<file>#<anchor>".
#   scripts/spec.sh check           Validate every citation in the repo.
#   scripts/spec.sh index [--check] Regenerate docs/spec/index.json, or
#                                    (--check) fail if it is stale.
#
# Read-only: no subcommand writes anything except `index` writing
# docs/spec/index.json itself. Uses only bash and jq.

set -uo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 1

index_path="docs/spec/index.json"
ratchet_path="scripts/spec-check-ratchet.tsv"

usage() {
  cat >&2 <<'EOF'
Usage: scripts/spec.sh show <label>
       scripts/spec.sh where <label>
       scripts/spec.sh check
       scripts/spec.sh index [--check]
EOF
}

# Every markdown file that carries anchored labels, newest split files
# included — discovered rather than listed, same reasoning as
# scripts/lint-shell.sh's file set: a future split under
# docs/spec/implementation/ is covered without anyone remembering to list it
# here.
spec_md_files() {
  find docs/spec -name '*.md' -print | LC_ALL=C sort
}

# Classify an anchor id into one of the nine (specification, sequence)
# kinds. The anchor prefix alone carries the classification — the directory
# a file lives in does not matter, which is what lets a future spec split
# stay invisible to this script.
spec_kind_for_anchor() {
  case "$1" in
    impl-ac-*) echo impl-ac ;;
    impl-c-*) echo impl-c ;;
    impl-*) echo impl ;;
    rev-ac-*) echo rev-ac ;;
    rev-c-*) echo rev-c ;;
    rev-*) echo rev ;;
    mon-ac-*) echo mon-ac ;;
    mon-c-*) echo mon-c ;;
    mon-*) echo mon ;;
    *) return 1 ;;
  esac
}

spec_qualify() {
  case "$1" in
    impl) echo "IMPL $2" ;;
    impl-ac) echo "IMPL AC $2" ;;
    impl-c) echo "IMPL C $2" ;;
    rev) echo "REV $2" ;;
    rev-ac) echo "REV AC $2" ;;
    rev-c) echo "REV C $2" ;;
    mon) echo "MON $2" ;;
    mon-ac) echo "MON AC $2" ;;
    mon-c) echo "MON C $2" ;;
  esac
}

# Best-effort one-line title from the text following the anchor tag: the
# first bold span if there is one (every requirement and most acceptance
# checks open with one), else the raw line capped at 120 characters (most
# components, which open with a code span instead).
spec_title_from_rest() {
  local rest="$1" title
  if [[ $rest =~ ^\*\*([^*]+)\*\* ]]; then
    title="${BASH_REMATCH[1]}"
  elif [[ $rest =~ ^\*\*(.*)$ ]]; then
    title="${BASH_REMATCH[1]}"
  else
    title="$rest"
  fi
  if (( ${#title} > 120 )); then
    title="${title:0:117}..."
  fi
  printf '%s' "$title"
}

# Scan every spec markdown file and emit one TSV row per labelled entry:
# kind\tlabel\tqualified\tanchor\tfile\tline\ttitle
spec_scan() {
  local file lineno line label anchor rest kind qualified title
  while IFS= read -r file; do
    lineno=0
    while IFS= read -r line; do
      lineno=$((lineno + 1))
      if [[ $line =~ ^[[:space:]]*([A-Za-z0-9]+)\.\ \<a\ id=\"([a-z0-9-]+)\"\>\</a\>(.*)$ ]]; then
        label="${BASH_REMATCH[1]}"
        anchor="${BASH_REMATCH[2]}"
        rest="${BASH_REMATCH[3]}"
        kind="$(spec_kind_for_anchor "$anchor")" || continue
        qualified="$(spec_qualify "$kind" "$label")"
        title="$(spec_title_from_rest "$rest")"
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$kind" "$label" "$qualified" "$anchor" "$file" "$lineno" "$title"
      fi
    done < "$file"
  done < <(spec_md_files)
}

# Reads the TSV from spec_scan on stdin; prints a message per duplicate
# (kind, label) pair to stderr and returns 1 if any exist.
spec_report_duplicates() {
  awk -F'\t' '
    {
      key = $1 "\t" $2
      count[key]++
      locs[key] = locs[key] $5 ":" $6 " "
    }
    END {
      bad = 0
      for (k in count) {
        if (count[k] > 1) {
          split(k, parts, "\t")
          printf "spec.sh: duplicate label %s %s at %s\n", parts[1], parts[2], locs[k] > "/dev/stderr"
          bad = 1
        }
      }
      exit bad
    }
  '
}

spec_tsv_to_index_json() {
  jq -R -s -c '
    split("\n") | map(select(length > 0)) | map(split("\t")) |
    map({
      qualified: .[2],
      value: {kind: .[0], label: .[1], anchor: .[3], file: .[4], line: (.[5] | tonumber), title: .[6]}
    })
  ' | jq '{generated_by: "scripts/spec.sh index", labels: (map({(.qualified): .value}) | add // {})}'
}

# Turn a user-supplied query into the canonical qualified label used as the
# index.json key, honouring every input form this convention accepts.
# Prints the qualified label and returns 0, or returns 1 if the query's
# shape is not recognised (this does not mean the label does not exist —
# callers still check the index for that).
spec_normalize() {
  local q upper first rest
  q="$1"
  q="$(printf '%s' "$q" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  [[ -z "$q" ]] && return 1
  upper="$(printf '%s' "$q" | tr '[:lower:]' '[:upper:]')"
  case "$upper" in
    "IMPL AC "*) echo "IMPL AC ${q:8}"; return 0 ;;
    "IMPL C "*) echo "IMPL C ${q:7}"; return 0 ;;
    "IMPL "*) echo "IMPL ${q:5}"; return 0 ;;
    "REV AC "*) echo "REV AC ${q:7}"; return 0 ;;
    "REV C "*) echo "REV C ${q:6}"; return 0 ;;
    "REV "*) echo "REV ${q:4}"; return 0 ;;
    "MON AC "*) echo "MON AC ${q:7}"; return 0 ;;
    "MON C "*) echo "MON C ${q:6}"; return 0 ;;
    "MON "*) echo "MON ${q:4}"; return 0 ;;
    "ACCEPTANCE CHECK "*) spec_resolve_english ac "${q:17}"; return $? ;;
    "ACCEPTANCE CHECKS "*) spec_resolve_english ac "${q:18}"; return $? ;;
    "COMPONENT "*) spec_resolve_english c "${q:10}"; return $? ;;
    "COMPONENTS "*) spec_resolve_english c "${q:11}"; return $? ;;
    "REQUIREMENT "*) echo "IMPL ${q:12}"; return 0 ;;
    "REQUIREMENTS "*) echo "IMPL ${q:13}"; return 0 ;;
    *)
      first="${q:0:1}"
      rest="${q:1}"
      if [[ "$first" == [Rr] && "$rest" =~ ^[0-9] ]]; then
        echo "REV ${first^^}${rest}"
      elif [[ "$first" == [Mm] && "$rest" =~ ^[0-9] ]]; then
        echo "MON ${first^^}${rest}"
      else
        echo "IMPL $q"
      fi
      return 0
      ;;
  esac
}

# "acceptance check <label>" / "component <label>" name no specification,
# so try each in turn and resolve to whichever one the index actually
# carries — IMPL first, since that is overwhelmingly where these bare
# English citations already point.
spec_resolve_english() {
  local kindword="$1" label="$2" spec key mid
  [[ "$kindword" == ac ]] && mid="AC" || mid="C"
  for spec in IMPL REV MON; do
    key="$spec $mid $label"
    if spec_index_has "$key"; then
      echo "$key"
      return 0
    fi
  done
  echo "IMPL $mid $label"
  return 0
}

spec_index_has() {
  jq -e --arg k "$1" '.labels[$k] // empty' "$index_path" >/dev/null 2>&1
}

spec_index_entry() {
  jq -e --arg k "$1" '.labels[$k] // empty' "$index_path" 2>/dev/null
}

spec_require_index() {
  if [[ ! -f "$index_path" ]]; then
    echo "spec.sh: $index_path does not exist; run scripts/spec.sh index first" >&2
    exit 1
  fi
}

cmd_where() {
  local query="$*" key entry
  [[ -z "$query" ]] && { usage; exit 2; }
  spec_require_index
  key="$(spec_normalize "$query")" || { echo "spec.sh: cannot parse label '$query'" >&2; exit 1; }
  entry="$(spec_index_entry "$key")" || { echo "spec.sh: no such label: $key" >&2; exit 1; }
  jq -r '"\(.file)#\(.anchor)"' <<< "$entry"
}

# Print the entry's own text block (from its anchored line up to, but not
# including, the next anchored line or heading in the same file), then
# every line elsewhere in the spec files and in the rest of the repository
# that cites this label — the acceptance checks, components, design
# decisions and gotchas that mention it, and the code and tests that do.
cmd_show() {
  local query="$*" key entry file line anchor title kind label
  [[ -z "$query" ]] && { usage; exit 2; }
  spec_require_index
  key="$(spec_normalize "$query")" || { echo "spec.sh: cannot parse label '$query'" >&2; exit 1; }
  entry="$(spec_index_entry "$key")" || { echo "spec.sh: no such label: $key" >&2; exit 1; }
  file="$(jq -r '.file' <<< "$entry")"
  line="$(jq -r '.line' <<< "$entry")"
  anchor="$(jq -r '.anchor' <<< "$entry")"
  title="$(jq -r '.title' <<< "$entry")"
  kind="$(jq -r '.kind' <<< "$entry")"
  label="$(jq -r '.label' <<< "$entry")"

  echo "$key  —  $title"
  echo "$file#$anchor"
  echo
  awk -v start="$line" '
    NR < start { next }
    NR == start { print; next }
    /^[[:space:]]*[A-Za-z0-9]+\. <a id="/ { exit }
    /^#/ { exit }
    { print }
  ' "$file"

  echo
  echo "Cites this label:"
  local found=0
  local phrase_patterns=()
  case "$kind" in
    impl) phrase_patterns=("[Rr]equirements? $label\b" "IMPL $label\b") ;;
    impl-ac) phrase_patterns=("[Aa]cceptance checks? $label\b" "IMPL AC $label\b") ;;
    impl-c) phrase_patterns=("[Cc]omponents? $label\b" "IMPL C $label\b") ;;
    rev) phrase_patterns=("\b$label\b" "REV $label\b") ;;
    rev-ac) phrase_patterns=("REV AC $label\b" "[Aa]cceptance checks? $label\b") ;;
    rev-c) phrase_patterns=("REV C $label\b" "[Cc]omponents? $label\b") ;;
    mon) phrase_patterns=("\b$label\b" "MON $label\b") ;;
    mon-ac) phrase_patterns=("MON AC $label\b" "[Aa]cceptance checks? $label\b") ;;
    mon-c) phrase_patterns=("MON C $label\b" "[Cc]omponents? $label\b") ;;
  esac
  local pattern
  for pattern in "${phrase_patterns[@]}"; do
    while IFS= read -r hit; do
      [[ -z "$hit" ]] && continue
      echo "  $hit"
      found=1
    done < <(grep -rnE --include='*.md' --include='*.sh' --include='*.json' \
      -- "$pattern" . \
      --exclude=CHANGELOG.md --exclude-dir=.git --exclude-dir=tech-debt \
      --exclude-dir=reviews --exclude-dir=fixtures 2>/dev/null \
      | grep -v "^\./$file:$line:" )
  done
  if (( ! found )); then
    echo "  (no citations found)"
  fi
}

# Files this script validates citations against. Historical and generated
# records are excluded on purpose: CHANGELOG.md and docs/reviews/ describe
# what a past pull request did, docs/ROADMAP.md and
# docs/STANDING-DECISIONS.md are decision logs exempt from the as-built
# rule the rest of the repository follows, tech-debt/ is a frozen archive,
# and test/fixtures/ holds synthetic content that is not a real citation.
# This script's own usage documentation and its test's fixture labels are
# excluded for the same reason: they are examples of the citation grammar,
# not citations of anything that has to resolve.
spec_citation_sources() {
  git ls-files \
    | grep -vE '^(CHANGELOG\.md|docs/ROADMAP\.md|docs/STANDING-DECISIONS\.md)$' \
    | grep -vE '^(tech-debt/|docs/reviews/|test/fixtures/)' \
    | grep -vE '^(scripts/spec\.sh|test/spec\.test\.sh)$' \
    | grep -vE '\.(png|jpg|jpeg|gif|svg|lock)$'
}

spec_ratchet_has() {
  local key="$1" file="$2" line="$3"
  [[ -f "$ratchet_path" ]] || return 1
  awk -F'\t' -v k="$key" -v f="$file" -v l="$line" \
    'NR>1 && $1==k && $2==f && $3==l { found=1 } END { exit !found }' \
    "$ratchet_path"
}

# Validate every "requirement N" / "acceptance check N" / "component N"
# English citation, and every qualified "IMPL"/"REV"/"MON" citation, in the
# files spec_citation_sources lists: each must resolve to a real label, and
# a bare "requirement N" must resolve to a requirement, not to an
# acceptance check or a component that happens to share its number — the
# exact bug this issue found at scripts/doctor.sh:508, config.schema.json
# and lib/landing.sh before they were fixed.
#
# A citation with a dotted sub-number ("requirement 2.5", "16.1") names a
# step inside requirement 2's or 16's own nested checklist, a third,
# unqualified numbering scheme this script does not model yet
# (agent-ops#2520) — skipped here rather than mismatched against the
# truncated integer part.
cmd_check() {
  spec_require_index
  local violations=0
  local tsv
  tsv="$(spec_scan)"
  if ! printf '%s\n' "$tsv" | spec_report_duplicates; then
    violations=1
  fi

  local pattern
  for pattern in \
    '[Rr]equirements? [0-9]+(\.[0-9]+)?[A-Za-z]?' \
    '[Aa]cceptance checks? [0-9]+(\.[0-9]+)?[A-Za-z]?' \
    '[Cc]omponents? [0-9]+(\.[0-9]+)?[A-Za-z]?' \
    '\bIMPL( AC| C)? [A-Za-z0-9]+' \
    '\bREV( AC| C)? [A-Za-z0-9]+' \
    '\bMON( AC| C)? [A-Za-z0-9]+'
  do
    while IFS=: read -r file lineno phrase; do
      [[ -z "${file:-}" ]] && continue
      if [[ $phrase == *.* ]]; then
        continue
      fi
      local key
      key="$(spec_normalize "$phrase")" || continue
      if spec_index_has "$key"; then
        continue
      fi
      if spec_ratchet_has "$key" "$file" "$lineno"; then
        continue
      fi
      echo "spec.sh check: $file:$lineno: '$phrase' does not resolve ($key)" >&2
      violations=1
    done < <(spec_citation_sources | xargs -r grep -noE -- "$pattern" 2>/dev/null)
  done

  if (( violations == 0 )); then
    echo "spec.sh check: every label is unique and every citation resolves"
  fi
  exit $violations
}

cmd_index() {
  local check_mode=0
  if [[ "${1:-}" == "--check" ]]; then
    check_mode=1
  fi
  local tmp
  tmp="$(mktemp)"
  spec_scan | spec_tsv_to_index_json > "$tmp"
  if (( check_mode )); then
    if diff -q "$tmp" "$index_path" > /dev/null 2>&1; then
      rm -f "$tmp"
      echo "spec.sh index: $index_path is up to date"
      exit 0
    else
      echo "spec.sh index: $index_path is stale; run 'scripts/spec.sh index' to regenerate" >&2
      rm -f "$tmp"
      exit 1
    fi
  else
    mv "$tmp" "$index_path"
    echo "spec.sh index: wrote $index_path"
  fi
}

main() {
  local cmd="${1:-}"
  [[ $# -gt 0 ]] && shift
  case "$cmd" in
    show) cmd_show "$@" ;;
    where) cmd_where "$@" ;;
    check) cmd_check "$@" ;;
    index) cmd_index "$@" ;;
    *) usage; exit 2 ;;
  esac
}

main "$@"
