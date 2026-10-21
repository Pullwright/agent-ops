#!/usr/bin/env bash
#
# scripts/render-scripts-index.sh — render the index of every script under
# lib/ and scripts/ (issue #2097, delivering #1758's own scripts-index ask)
# into docs/reference/scripts.md's generated region.
#
# Grouped by directory — "Libraries: `lib/`" (sourced by agent-cycle.sh and
# review-cycle.sh, never run directly) and "Entry points: `scripts/`" (run
# directly: by cron, by CI, or by hand) — rather than by any finer-grained
# purpose, because the directory split is the one distinction this
# repository already enforces structurally (`lib/*.sh` has no shebang
# meant to be executed; AGENTS.md draws the same line) and anything finer
# would be a hand-maintained category per file, drifting the moment a
# script is renamed or added without updating it.
#
# Each row's "Purpose" column is the first paragraph of that script's own
# header comment: every `#` comment line (or, for a `.py` file, the opening
# `"""` docstring's first paragraph) from the one immediately after the
# shebang, up to the first blank comment line, wrapped lines joined with a
# single space — except where the wrap fell inside a token, at the token's
# own ASCII hyphen or underscore, which rejoins with nothing so the cell
# prints the token rather than a word cut in half. A hyphen used as
# punctuation (a space before it) and an em dash are unaffected, since
# neither sits directly against an alphanumeric.
# A leading `# shellcheck disable=...` paragraph — explaining
# why a lint rule is suppressed, not what the script does — is skipped in
# favour of the paragraph after it, the one genuine exception to "the first
# paragraph, verbatim": every other leading comment paragraph is used as
# found, usage lines included, rather than hunting for one that "reads
# well".
#
# With no arguments, regenerate the index. `--check` verifies the region is
# current (exit non-zero if stale), mirroring render-toc.sh's and
# render-config-table.sh's own contract.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 1

usage() {
  echo "usage: $(basename "$0") [--check]" >&2
  exit 2
}

check_mode=0
case "${1:-}" in
  --check) check_mode=1; shift ;;
  "") ;;
  *) usage ;;
esac
if (( $# > 0 )); then
  usage
fi

# The file this renders (SCRIPTS_INDEX_FILES) and the markers that delimit
# its region come from lib/markdown-scan.sh, which scripts/check-docs.sh
# reads to leave exactly this region out of the size budget.
# shellcheck source=lib/markdown-scan.sh
. "$repo_root/lib/markdown-scan.sh"

# extract_first_paragraph FILE
# FILE's own header-comment first paragraph (see this script's own header
# above), one line, wrapped text joined with spaces. Empty if FILE's first
# line is not a `#!` shebang followed by a comment or a `"""` docstring.
extract_first_paragraph() {
  local file="$1"
  awk '
    BEGIN { state = "start"; para = ""; skipped_shellcheck = 0; done = 0 }
    function is_shellcheck_para() {
      return (para ~ /^shellcheck disable=/)
    }
    # A wrapped header comment can break a token at an ASCII hyphen or
    # underscore inside it (run_coordinator_through_ + finishing_phase,
    # classifier- + escapes). Joining those with a space prints a word cut
    # in half, so join with nothing instead — but only where the separator
    # sits directly against an alphanumeric, which a hyphen used as
    # punctuation (preceded by a space) and an em dash never do.
    function append(line) {
      if (para == "") { para = line; return }
      if (para ~ /[A-Za-z0-9][-_]$/) { para = para line; return }
      para = para " " line
    }
    function emit() {
      if (para == "") { return }
      if (!skipped_shellcheck && is_shellcheck_para()) {
        skipped_shellcheck = 1
        para = ""
        return
      }
      print para
      para = ""
      done = 1
    }
    state == "start" {
      if ($0 ~ /^#!/) { state = "body"; next }
      state = "body"
    }
    done { next }
    state == "body" {
      if ($0 ~ /^"""/) {
        state = "pydoc"
        line = $0
        sub(/^"""/, "", line)
        sub(/"""$/, "", line)
        if (line != "") para = line
        next
      }
      if ($0 ~ /^#[ \t]*$/) { emit(); next }
      if ($0 ~ /^#/) {
        line = $0
        sub(/^#[ \t]?/, "", line)
        append(line)
        next
      }
      emit()
      exit
    }
    state == "pydoc" {
      if ($0 ~ /"""/) { emit(); exit }
      if ($0 == "") { emit(); if (done) exit; next }
      append($0)
      next
    }
    END { if (!done) emit() }
  ' "$file"
}

# render_group_table DIR
# A "| Script | Purpose |" table, one row per `*.sh`/`*.py` file directly
# under DIR (not recursive — lib/ and scripts/ are both flat), sorted by
# path.
render_group_table() {
  local dir="$1" file paragraph base
  echo "| Script | Purpose |"
  echo "|--------|---------|"
  while IFS= read -r file; do
    paragraph="$(extract_first_paragraph "$file")"
    if [[ -z "$paragraph" ]]; then
      echo "render-scripts-index: $file has no header-comment first paragraph to index" >&2
      exit 1
    fi
    # The paragraph names its own file (this script's header above), which the
    # Script column already shows — strip that lead-in, by the file's full
    # path or its bare basename, so the cell starts at the description.
    base="$(basename "$file")"
    paragraph="${paragraph#"$file"}"
    paragraph="${paragraph#"$base"}"
    paragraph="${paragraph# }"
    paragraph="${paragraph#— }"
    paragraph="${paragraph#-- }"
    echo "| \`$file\` | $paragraph |"
  done < <(find "$dir" -maxdepth 1 -type f \( -name '*.sh' -o -name '*.py' \) | sort)
}

generate_index() {
  echo "### Libraries: \`lib/\`"
  echo
  echo "Sourced into \`agent-cycle.sh\`'s and \`review-cycle.sh\`'s own process; never run"
  echo "directly."
  echo
  render_group_table lib
  echo
  echo "### Entry points: \`scripts/\`"
  echo
  echo "Run directly: by cron, by CI, or by hand."
  echo
  render_group_table scripts
}

render_file() {
  local file="$1"
  local temp_file="${file}.scripts-index.tmp"

  local start_count end_count
  start_count=$(grep -cE "$(scripts_index_start_re)" "$file" || true)
  end_count=$(grep -cE "$(scripts_index_end_re)" "$file" || true)
  if (( start_count != 1 || end_count != 1 )); then
    echo "render-scripts-index: $file does not contain exactly one <!-- scripts-index:start --> / <!-- scripts-index:end --> marker pair" >&2
    return 1
  fi

  # Explicit rc check, not reliance on `set -e`: this function is called as
  # `if ! render_file ...`, and set -e does not apply to a command whose
  # exit status a conditional is testing — so a failure inside
  # generate_index's subshell (an unindexable script, surfaced by
  # render_group_table's own `exit 1`) would otherwise pass unnoticed here.
  local index_content
  if ! index_content="$(generate_index)"; then
    return 1
  fi

  awk -v content="$index_content" -v start="$(scripts_index_start_re)" -v end="$(scripts_index_end_re)" '
    $0 ~ start {
      print "<!-- scripts-index:start -->"
      print content
      while (getline && $0 !~ end) {}
      print "<!-- scripts-index:end -->"
      next
    }
    { print }
  ' "$file" > "$temp_file"

  if (( check_mode )); then
    if ! diff -q "$file" "$temp_file" >/dev/null 2>&1; then
      echo "render-scripts-index: $file is stale" >&2
      rm "$temp_file"
      return 1
    fi
    rm "$temp_file"
  else
    mv "$temp_file" "$file"
  fi

  return 0
}

failed=0
for file in "${SCRIPTS_INDEX_FILES[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "render-scripts-index: $file does not exist" >&2
    exit 1
  fi
  if ! render_file "$file"; then
    failed=1
  fi
done

if (( failed )); then
  exit 1
fi
if (( check_mode )); then
  echo "render-scripts-index: all regions match lib/ and scripts/"
fi
