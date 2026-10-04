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
  awk '
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
        print
        next
      }
      if (c == fence) {
        n = run(stripped, c)
        rest = substr(stripped, n + 1)
        sub(/[ \t]+$/, "", rest)
        if (n >= fence_len && rest == "") fence = ""
      }
    }' "$1"
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
