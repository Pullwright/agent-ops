#!/usr/bin/env bash
#
# lib/markdown-scan.sh — the one fence-aware reading of a Markdown file
# (requirements 52, 52a and 52b, components 24, 24a and 24b).
#
# Sourced by scripts/render-toc.sh, which takes the table of contents from the
# headings outside fenced code; by lib/docs-benchmark.sh, which follows
# each benchmark question's sources to a heading or a label outside fenced
# code; and by scripts/check-docs.sh, which resolves a link's #fragment and a
# quoted section citation to a heading. One reading serves all three, so a
# fence one of them mistakes for prose cannot make the others disagree with
# it.
#
# The same holds for generated regions: the "Generated regions" section below
# lists every region a renderer rewrites and the markers that delimit it, so
# scripts/render-toc.sh and scripts/render-config-table.sh, which render them,
# and scripts/check-docs.sh, which leaves them out of the size budget, read
# one list and one marker grammar.

# markdown_unfenced FILE
# Print FILE's lines that lie outside fenced code blocks, in order, leaving out
# the fence lines themselves.
#
# A fence opens on a line whose first non-blank characters are three or more
# backticks or three or more tildes. It may be indented by any amount, because
# a fence inside a list item is indented with the item, and both specifications
# and the README have such fences. It closes only on a later line that holds
# nothing but the same character, repeated at least as many times as the
# opening run, and blank space; so a `~~~` line inside a backtick fence, or a
# shorter run, is content and leaves the fence open. As CommonMark has it, a
# backtick run followed by another backtick on the same line is inline code,
# not a fence. An unterminated fence runs to the end of the file.
#
# A carriage return at the end of a line is dropped before anything else, so
# a file with CRLF line endings reads as its LF form does. Kept, it would
# follow a closing fence and stop it closing, and every heading and label after
# the first fence would vanish from both readers.
markdown_unfenced() {
  markdown_unfenced_lines 0 "$1"
}

# markdown_unfenced_numbered FILE
# As markdown_unfenced, but each line is prefixed with its line number in FILE
# and a tab, so a reader that finds a line here can go back to FILE itself for
# what lies around it, fenced code included.
markdown_unfenced_numbered() {
  markdown_unfenced_lines 1 "$1"
}

# markdown_unfenced_lines NUMBERED FILE
# The one fence-aware pass behind both readers above.
markdown_unfenced_lines() {
  awk -v numbered="$1" '
    function run(s, c,    n) {
      n = 0
      while (substr(s, n + 1, 1) == c) n++
      return n
    }
    {
      sub(/\r$/, "")
      stripped = $0
      sub(/^[ \t]+/, "", stripped)
      c = substr(stripped, 1, 1)
      if (fence == "") {
        if (c == "`" || c == "~") {
          n = run(stripped, c)
          if (n >= 3 && !(c == "`" && index(substr(stripped, n + 1), "`") > 0)) {
            fence = c
            fence_len = n
            next
          }
        }
        if (numbered) print NR "\t" $0
        else print
        next
      }
      if (c == fence) {
        n = run(stripped, c)
        rest = substr(stripped, n + 1)
        sub(/[ \t]+$/, "", rest)
        if (n >= fence_len && rest == "") fence = ""
      }
    }' "$2"
}

# gh_slug TEXT
# GitHub's own heading-anchor slug: lower-case, strip anything that is not
# alphanumeric/underscore/hyphen/space, spaces to hyphens. GitHub does not
# collapse consecutive hyphens: a removed character leaves both its
# neighbouring spaces behind, each becoming its own hyphen.
#
# Sourced by scripts/render-toc.sh (the table-of-contents anchors) and by
# scripts/check-docs.sh (link-fragment and heading-citation checks), so the
# two cannot disagree about what a heading's anchor is.
gh_slug() {
  local text="$1"
  text=$(echo "$text" | tr '[:upper:]' '[:lower:]')
  text="${text//[^a-z0-9 _-]/}"
  text="${text// /-}"
  echo "$text"
}

# markdown_heading_texts FILE
# Print FILE's heading text, verbatim, one per line, outside fenced code and
# in document order, for every level `#` through `######`. Used by
# scripts/check-docs.sh to check that a quoted section citation
# (`path` § "heading") names a heading that exists.
#
# Level 1 counts: GitHub anchors an `#` heading exactly as it does a `##`,
# so a fragment or citation naming one (`docs/README.md#installation-guide`)
# is a working reference, and leaving it out would report it broken.
# scripts/render-toc.sh does not use this function — its table of contents is
# deliberately `##`/`###` only, and it extracts those itself.
markdown_heading_texts() {
  # mawk's `{m,n}` interval expressions are unreliable (observed matching
  # only the minimum repeat count, silently dropping deeper headings), so
  # the hash run is matched open-ended with `+` and bounded by checking
  # RLENGTH instead — never with a `{1,6}` in the regex itself.
  awk '
    match($0, /^#+ /) {
      hashes = RLENGTH - 1
      if (hashes >= 1 && hashes <= 6) print substr($0, RLENGTH + 1)
    }' < <(markdown_unfenced "$1")
}

# markdown_heading_slugs FILE
# Print FILE's final GitHub anchor slug for every heading, in document order,
# outside fenced code — duplicate headings de-duplicated
# the way GitHub's own renderer does: the first occurrence keeps its bare
# slug, each later one gets -1, -2, ... appended, counting across every
# heading level together, as GitHub's own shared counter does. Used by
# scripts/check-docs.sh to resolve a link's #fragment to a heading that
# actually exists.
markdown_heading_slugs() {
  local anchor
  local -A seen=()
  while IFS= read -r anchor; do
    anchor=$(gh_slug "$anchor")
    if [[ -n "${seen[$anchor]+x}" ]]; then
      seen[$anchor]=$(( seen[$anchor] + 1 ))
      anchor="${anchor}-${seen[$anchor]}"
    else
      seen[$anchor]=0
    fi
    echo "$anchor"
  done < <(markdown_heading_texts "$1")
}

# ---------------------------------------------------------------------------
# Generated regions
# ---------------------------------------------------------------------------
#
# The regions AGENTS.md's "Generated regions" section describes: each one is
# rewritten by a renderer and never edited by hand. A region is generated
# only if it is listed here. scripts/render-toc.sh and
# scripts/render-config-table.sh render exactly the regions listed, and
# scripts/check-docs.sh leaves exactly these out of the size budget, so a
# marker pair placed anywhere else, or one carrying an id or fragment that
# nothing renders, holds hand-written bytes like any other line.

# The files whose table of contents scripts/render-toc.sh renders, one region
# each, from toc_start_re to toc_end_re.
# shellcheck disable=SC2034  # Read by the scripts that source this file.
TOC_FILES=(
  "docs/IMPLEMENTATION-PIPELINE-SPEC.md"
  "docs/guides/working-with-pullwright/README.md"
  "docs/guides/operating/README.md"
  "docs/guides/contributing/README.md"
)

# FILE:ID:AUDIENCE for each configuration table scripts/render-config-table.sh
# renders from config.schema.json: a table region (config_table_start_re ID to
# config_table_end_re) and the notes region beside it (config_notes_start_re
# ID to config_notes_end_re). The audience picks which x-docs field, and which
# schema description fallback, the regions render.
# shellcheck disable=SC2034  # Read by the scripts that source this file.
CONFIG_TABLE_REGIONS=(
  "docs/reference/configuration.md:main:readme"
  "docs/reference/configuration.md:review:readme"
  "docs/IMPLEMENTATION-PIPELINE-SPEC.md:main:spec"
  "docs/REVIEW-PIPELINE-SPEC.md:review:spec"
)

# FILE:FRAGMENT for each region Pullwright/.agent's scripts/sync.sh stamps in
# this repository, from stamp_start_re FRAGMENT to stamp_end_re FRAGMENT. That
# repository's sync/manifest.tsv decides them and nothing here can read it, so
# this is a copy: a fragment the manifest adds counts as hand-written until it
# is listed here too, which errs towards the budget, never past it.
# shellcheck disable=SC2034  # Read by the scripts that source this file.
STAMPED_REGIONS=(
  "AGENTS.md:conventions"
  "AGENTS.md:maintainer"
  "AGENTS.md:documentation-principles"
)

# The markers, as POSIX extended regular expressions, each matched against a
# whole line; ID and FRAGMENT are plain words. A configuration table's start
# marker, or its notes', may carry prose between its id and a closing `-->`
# (scripts/render-config-table.sh's header gives that contract). A stamped
# region's start marker carries the source commit and a hash after its
# fragment, as sync.sh writes it, and its end marker names the fragment again,
# which is how sync.sh pairs the two. The other end markers carry nothing.
toc_start_re() { printf '%s' '^<!-- toc:start -->$'; }
toc_end_re() { printf '%s' '^<!-- toc:end -->$'; }
config_table_start_re() { printf '^<!-- config-table:start id=%s($| .*-->$)' "$1"; }
config_table_end_re() { printf '%s' '^<!-- config-table:end -->$'; }
config_notes_start_re() { printf '^<!-- config-table:notes id=%s($| .*-->$)' "$1"; }
config_notes_end_re() { printf '%s' '^<!-- config-table:notes-end -->$'; }
stamp_start_re() { printf '^<!-- agent-info:start fragment=%s( .*)? -->$' "$1"; }
stamp_end_re() { printf '^<!-- agent-info:end fragment=%s -->$' "$1"; }

# markdown_generated_regions FILE
# Print the first and last line numbers of each generated region FILE carries,
# tab-separated, one region per line in document order, with both marker lines
# included. Used by scripts/check-docs.sh to leave the regions out of the size
# budget.
#
# Only the regions listed above for FILE count. A marker counts only as a
# whole line outside fenced code, so a marker quoted in prose or shown in an
# example opens nothing; fenced code inside a region is still part of it, and
# a caller counts the region's lines from FILE itself. A region counts only
# once its own end marker is reached, so an unterminated start leaves the rest
# of the file out. Regions do not nest, so a start marker inside a region is
# part of that region. Each listed region counts once, at its first
# occurrence, which is the copy each renderer's check reads, so a second copy
# is hand-written.
markdown_generated_regions() {
  local file="$1" entry path id
  local -a markers=()
  for path in "${TOC_FILES[@]}"; do
    if [[ "$path" == "$file" ]]; then
      markers+=("$(toc_start_re)" "$(toc_end_re)")
    fi
  done
  for entry in "${CONFIG_TABLE_REGIONS[@]}"; do
    IFS=: read -r path id _ <<< "$entry"
    if [[ "$path" == "$file" ]]; then
      markers+=("$(config_table_start_re "$id")" "$(config_table_end_re)")
      markers+=("$(config_notes_start_re "$id")" "$(config_notes_end_re)")
    fi
  done
  for entry in "${STAMPED_REGIONS[@]}"; do
    path="${entry%%:*}"
    id="${entry#*:}"
    if [[ "$path" == "$file" ]]; then
      markers+=("$(stamp_start_re "$id")" "$(stamp_end_re "$id")")
    fi
  done
  if (( ${#markers[@]} == 0 )); then
    return 0
  fi
  printf '%s\n' "${markers[@]}" | awk '
    FNR == NR {
      if (FNR % 2) start[++regions] = $0
      else stop[regions] = $0
      next
    }
    {
      nr = $0
      sub(/\t.*/, "", nr)
      line = substr($0, length(nr) + 2)
    }
    open {
      if (line ~ stop[open]) {
        print first "\t" nr
        done[open] = 1
        open = 0
      }
      next
    }
    {
      for (i = 1; i <= regions; i++)
        if (!(i in done) && line ~ start[i]) { open = i; first = nr; break }
    }' - <(markdown_unfenced_numbered "$file")
}
