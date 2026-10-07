#!/usr/bin/env bash
#
# scripts/render-toc.sh — render the table of contents for each file
# lib/markdown-scan.sh's TOC_FILES and TOC_DIR_FILES list, between marker
# regions.
#
# For a TOC_FILES entry: extracts `##` and `###` headings from the file
# itself (ignoring the top-level `# ` title, code blocks, and anything inside
# fenced code), and generates a nested markdown bullet list with links using
# GitHub's auto-generated anchor slugging. For a TOC_DIR_FILES entry: lists
# every other Markdown file under the paired directory instead, linking each
# sibling's own first heading, nested one level per sub-directory. Either
# way the list is written/checked between `<!-- toc:start -->` /
# `<!-- toc:end -->` marker pairs placed immediately after each document's
# title and any lead-in paragraph, before the first `##` heading.
#
# With no arguments, regenerate the ToC in every listed file. `--check`
# verifies that every listed file's region is current (exit non-zero if
# stale), mirroring render-config-table.sh's contract.

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

# shellcheck source=lib/markdown-scan.sh
. "$repo_root/lib/markdown-scan.sh"
# gh_slug is defined in lib/markdown-scan.sh, shared with scripts/check-docs.sh
# so the two cannot disagree about what a heading's anchor is. So are the
# files this renders (TOC_FILES) and the markers it matches (toc_start_re,
# toc_end_re), which scripts/check-docs.sh reads to leave exactly these
# regions out of the size budget.

# Extract headings from a file: lines starting with ## or ###, skipping anything
# inside fenced code blocks, which lib/markdown-scan.sh's `markdown_unfenced`
# recognises the same way for this and for the documentation benchmark.
# Outputs "level heading_text" for each.
extract_headings() {
  local file="$1" line

  while IFS= read -r line || [[ -n "$line" ]]; do
    # Extract headings: ## (level 2) or ### (level 3), skip #
    if [[ "$line" == "### "* ]]; then
      echo "3 ${line#\#\#\# }"
    elif [[ "$line" == "## "* ]]; then
      echo "2 ${line#\#\# }"
    fi
  done < <(markdown_unfenced "$file")
}

# Generate ToC markdown from extracted headings. Anchors are de-duplicated
# across the whole document, in heading order, the same way GitHub's own
# renderer de-duplicates repeated headings: the first occurrence of a slug
# keeps it bare, every later occurrence gets -1, -2, ... appended.
generate_toc() {
  local -A seen=()
  while read -r level heading; do
    local indent=""
    if (( level == 3 )); then
      indent="  "
    fi
    local anchor
    anchor=$(gh_slug "$heading")
    if [[ -n "${seen[$anchor]+x}" ]]; then
      seen[$anchor]=$(( seen[$anchor] + 1 ))
      anchor="${anchor}-${seen[$anchor]}"
    else
      seen[$anchor]=0
    fi
    echo "${indent}- [$heading](#$anchor)"
  done
}

# first_heading_title FILE
# FILE's own first heading (any level, outside fenced code), stripped of its
# `#` run, for use as a directory ToC entry's link text. Falls back to FILE's
# own basename when it has no heading at all.
first_heading_title() {
  local file="$1" line
  local title
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == "#"* ]]; then
      title="${line#"${line%%[!#]*}"}"
      title="${title#"${title%%[^ ]*}"}"
      # "Requirements" and "Acceptance checks" are the generic section marker
      # every file in those directories repeats (scripts/docs-benchmark.sh's
      # per-file section tracker needs it on every file, not just the
      # first) — not a useful ToC label on its own, so keep reading for a
      # more specific heading first and fall back to it only if there is none.
      if [[ "$title" != "Requirements" && "$title" != "Acceptance checks" && "$title" != "Components" ]]; then
        echo "$title"
        return
      fi
    fi
  done < <(markdown_unfenced "$file")
  if [[ -n "${title:-}" ]]; then
    echo "$title"
    return
  fi
  basename "$file"
}

# generate_dir_toc FILE DIR
# A directory-wide ToC: one entry per other Markdown file under DIR
# (recursive, sorted, FILE itself excluded), linking that sibling's own first
# heading, nested one level per sub-directory below DIR.
generate_dir_toc() {
  local file="$1" dir="$2" sibling rel title depth indent i
  while IFS= read -r sibling; do
    [[ "$sibling" == "$file" ]] && continue
    rel="${sibling#"$dir"/}"
    title="$(first_heading_title "$sibling")"
    depth="$(grep -o '/' <<<"$rel" | wc -l)"
    indent=""
    for (( i = 0; i < depth; i++ )); do
      indent+="  "
    done
    echo "${indent}- [$title]($rel)"
  done < <(find "$dir" -name '*.md' | sort)
}

# render_dir_file FILE DIR
# As render_file, but the content between the markers is DIR's directory-wide
# ToC (generate_dir_toc) rather than FILE's own headings.
render_dir_file() {
  local file="$1" dir="$2"
  local temp_file="${file}.toc.tmp"

  if ! markers_ok "$file"; then
    echo "render-toc: $file does not contain exactly one <!-- toc:start --> / <!-- toc:end --> marker pair" >&2
    return 1
  fi

  local toc_content
  toc_content=$(generate_dir_toc "$file" "$dir")

  awk -v toc="$toc_content" -v start="$(toc_start_re)" -v end="$(toc_end_re)" '
    $0 ~ start {
      print "<!-- toc:start -->"
      print toc
      while (getline && $0 !~ end) {}
      print "<!-- toc:end -->"
      next
    }
    { print }
  ' "$file" > "$temp_file"

  if (( check_mode )); then
    if ! diff -q "$file" "$temp_file" >/dev/null 2>&1; then
      echo "render-toc: $file is stale" >&2
      rm "$temp_file"
      return 1
    fi
    rm "$temp_file"
  else
    mv "$temp_file" "$file"
  fi

  return 0
}

# True when a file contains exactly one <!-- toc:start --> and exactly one
# <!-- toc:end --> marker, with the start marker on an earlier line than the
# end marker. A file with neither, only one of the pair, or more than one of
# either has no well-formed region to render into — the awk pass below would
# otherwise copy such a file through unchanged, making regeneration a silent
# no-op and --check a false pass. A file with exactly one of each but in
# reversed order is just as malformed: the awk pass below only recognises a
# toc:end line reached *after* a toc:start line, so a reversed pair would
# have it consume every line to the end of the file looking for one,
# silently discarding whatever lay between the markers.
markers_ok() {
  local file="$1"
  local start_count end_count
  start_count=$(grep -cE "$(toc_start_re)" "$file" || true)
  end_count=$(grep -cE "$(toc_end_re)" "$file" || true)
  if (( start_count != 1 || end_count != 1 )); then
    return 1
  fi
  local start_line end_line
  start_line=$(grep -nE "$(toc_start_re)" "$file" | cut -d: -f1)
  end_line=$(grep -nE "$(toc_end_re)" "$file" | cut -d: -f1)
  (( start_line < end_line ))
}

# Render ToC for a file between markers
render_file() {
  local file="$1"
  local temp_file="${file}.toc.tmp"

  if ! markers_ok "$file"; then
    echo "render-toc: $file does not contain exactly one <!-- toc:start --> / <!-- toc:end --> marker pair" >&2
    return 1
  fi

  # Extract headings and generate ToC
  local toc_content
  toc_content=$(extract_headings "$file" | generate_toc)

  # Use awk to replace content between markers
  # This is more robust than sed for multiline replacements
  awk -v toc="$toc_content" -v start="$(toc_start_re)" -v end="$(toc_end_re)" '
    $0 ~ start {
      print "<!-- toc:start -->"
      print toc
      while (getline && $0 !~ end) {}
      print "<!-- toc:end -->"
      next
    }
    { print }
  ' "$file" > "$temp_file"

  if (( check_mode )); then
    if ! diff -q "$file" "$temp_file" >/dev/null 2>&1; then
      echo "render-toc: $file is stale" >&2
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
for file in "${TOC_FILES[@]}"; do
  if ! render_file "$file"; then
    failed=1
  fi
done

for entry in "${TOC_DIR_FILES[@]}"; do
  file="${entry%%:*}"
  dir="${entry#*:}"
  if ! render_dir_file "$file" "$dir"; then
    failed=1
  fi
done

if (( failed )); then
  exit 1
fi
