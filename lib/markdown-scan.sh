#!/usr/bin/env bash
#
# lib/markdown-scan.sh — the one fence-aware reading of a Markdown file
# (requirements 52 and 52a, components 24 and 24a).
#
# Sourced by scripts/render-toc.sh, which takes the table of contents from the
# headings outside fenced code, and by lib/docs-benchmark.sh, which follows
# each benchmark question's sources to a heading or a label outside fenced
# code. One reading serves both, so a fence one of them mistakes for prose
# cannot make the other disagree with it.

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
