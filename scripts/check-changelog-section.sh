#!/usr/bin/env bash
# scripts/check-changelog-section.sh — deterministic check of the
# `## Changelog` section a pull-request description carries (requirement
# 25c, roadmap decision D27).
#
# Usage: check-changelog-section.sh <pr-body> [<pr-title>]
#
# D27 moves a change's changelog entry out of `CHANGELOG.md` and into its
# own pull-request description, which the squash merge writes onto `main`
# (`squash_merge_commit_message: PR_BODY`). `CHANGELOG.md` is then assembled
# from those descriptions by the release pull request alone, so two pull
# requests can no longer conflict over the file — between 2026-09-13 and
# 2026-09-23 the file was the sole conflicting path in 16 of the 22 merge
# conflicts the pipeline repaired here (agent-ops#1804). An entry in a
# description is only worth that trade if its shape is dependable enough to
# assemble from, and only present if something checks for it: prompt
# instruction alone was asked for the closing keyword and silently skipped
# once (issue #240), and this is the same kind of fact, so it is a fact CI
# checks, on the same shape as scripts/check-closing-keyword.sh.
#
# The grammar, applied outside fenced code blocks and HTML comments (a
# fenced example of the heading — this very file's own tests carry one — is
# not a section, a `<!-- -->` note inside one is not content, and each of
# the two is literal text inside the other):
#
#   ## Changelog
#
#   ### Fixed
#
#   - One bullet per change, written for the repository's changelog
#     audience; an indented line continues the bullet above it.
#
#   ### Added
#
#   - …
#
# or, for a change that is not notable,
#
#   ## Changelog
#
#   None. (Optionally, why.)
#
# A heading's content runs to the next level-one or level-two heading or
# to the end of the body. A heading whose content is nothing but blank
# lines and HTML comments — the pull-request template's own untouched
# state — is treated as absent, not as empty: a type that owes nothing
# passes it as it stands, and a type that owes a section gets the same
# fault as for no heading at all, never one it could only clear by deleting
# a heading the template gave it (PR #1810 review). Exactly one heading
# with content is allowed (case-insensitive). The first non-blank line of
# the content is either a line
# starting with `None` or a `### <Category>` heading, where `<Category>` is
# one of Keep a Changelog's six, spelt exactly: Added, Changed, Deprecated,
# Removed, Fixed, Security. Every category heading is followed by at least
# one bullet (`- ` or `* `), a category appears at most once, and a line
# under a category is a bullet, an indented continuation, or a comment —
# never loose prose, which an assembler could neither place nor drop. A
# `None` section lists no category and no bullet.
#
# Which descriptions owe a section is decided by the title, the one anchor
# no description edit can move: a Conventional Commits type of `feat`,
# `fix` or `perf`, or a `!` breaking-change marker on any type, requires the
# section — even if only to say `None.`, so an omission is deliberate rather
# than forgotten. Every other type (`chore`, `docs`, `refactor`, `test`,
# `build`, `ci`, `style`, `revert`), and a Dependabot bump among them, may
# omit it; a section that is present is checked for shape whatever the
# type. The type pattern is `.githooks/check-commit-format.sh`'s own; a
# title that pattern rejects owes nothing here, since commit-format already
# fails it.
#
# The finishing sources (`review-feedback`, `merge-conflicts`, `dequeued`,
# `landing-refusals`) touch a description that already carries whatever it
# carries, exactly as they never wrote a `CHANGELOG.md` entry before; this
# check runs on the description as a whole, so it sees the section the
# original round wrote.
#
# Output: one `::error::`-prefixed line per fault on stderr (a GitHub Actions
# workflow command, so each fault is an annotation on the pull request), and
# exit 1; nothing and exit 0 when the description is in order. Exit 2 for a
# usage error. The body and the title reach this script as arguments, never
# interpolated into a shell string, so a fork's title or body cannot inject
# anything — the workflow passes both through `env:` for the same reason.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/changelog-grammar.sh
. "$SCRIPT_DIR/lib/changelog-grammar.sh"

if (( $# < 1 )); then
  printf 'usage: %s <pr-body> [<pr-title>]\n' "${0##*/}" >&2
  exit 2
fi

body="$1"
title="${2:-}"

COMMIT_TYPES='build|chore|ci|docs|feat|fix|perf|refactor|revert|style|test'
status=0

fault() {
  printf '::error::%s\n' "$1" >&2
  status=1
}

# --- Does the title owe a section? -------------------------------------------
owes=0
if [[ -n "$title" ]]; then
  if [[ "$title" =~ ^(feat|fix|perf)(\([a-zA-Z0-9_./-]+\))?!?:\  ]]; then
    owes=1
  elif [[ "$title" =~ ^(${COMMIT_TYPES})(\([a-zA-Z0-9_./-]+\))?!:\  ]]; then
    owes=1
  fi
fi

# --- Walk the body once, via the shared grammar ------------------------------
# `lib/changelog-grammar.sh`'s `changelog_grammar_walk` runs the same
# fence/HTML-comment/heading state machine and None/category/bullet
# classification `scripts/assemble-changelog.sh` reads too; this loop turns
# each of its events into the same faults this check has always raised.
sections=0
in_fence=0
in_comment=0

while IFS=$'\t' read -r event rest; do
  case "$event" in
    SECTION-END)
      IFS=$'\t' read -r _n content_lines <<<"$rest"
      # No content but blank lines and comments is an absent section, not an
      # empty one — see the header. Only a section with content counts
      # towards "exactly one".
      if (( content_lines > 0 )); then
        sections=$(( sections + 1 ))
        if (( sections > 1 )); then
          fault "more than one \`## Changelog\` section with content — keep exactly one"
        fi
      fi
      ;;
    NONE-BAD)
      IFS=$'\t' read -r _n kind line <<<"$rest"
      if [[ "$kind" == "category" ]]; then
        fault "the \`## Changelog\` section says \`None\` but also carries \`$line\` — either list the change under a category or say \`None.\` alone"
      else
        fault "the \`## Changelog\` section says \`None\` but also carries a bullet: $line — either list the change under a category or say \`None.\` alone"
      fi
      ;;
    BAD-FIRST)
      IFS=$'\t' read -r _n line <<<"$rest"
      fault "the first line under \`## Changelog\` must be a \`### <Category>\` heading or the line \`None.\`, not: $line"
      ;;
    CATEGORY)
      IFS=$'\t' read -r _n name valid dup <<<"$rest"
      if (( ! valid )); then
        fault "\`### $name\` is not a Keep a Changelog category — use exactly one of Added, Changed, Deprecated, Removed, Fixed, Security"
      elif (( dup )); then
        fault "\`### $name\` appears more than once in the \`## Changelog\` section — merge the bullets under one heading"
      fi
      ;;
    CATEGORY-END)
      IFS=$'\t' read -r _n name bullets <<<"$rest"
      if (( bullets == 0 )); then
        fault "\`### $name\` in the \`## Changelog\` section has no bullet under it — add at least one \`- \` bullet, or remove the heading"
      fi
      ;;
    CONTINUATION)
      IFS=$'\t' read -r _n category open line <<<"$rest"
      # An indented line continues the bullet above it (or is a nested
      # bullet, which the assembler keeps with its parent). Counts as
      # a bullet only if one is already open.
      (( open )) || fault "a line under \`### $category\` is indented but no bullet precedes it: $line"
      ;;
    LOOSE)
      IFS=$'\t' read -r _n category line <<<"$rest"
      fault "a line under \`### $category\` is neither a \`- \` bullet nor an indented continuation of one: $line"
      ;;
    UNCLOSED-FENCE) in_fence=1 ;;
    UNCLOSED-COMMENT) in_comment=1 ;;
    SECTION-START | NONE | BULLET) ;;
  esac
done < <(changelog_grammar_walk "$body")

# --- The title rule ----------------------------------------------------------
if (( owes )) && (( sections == 0 )); then
  # A body that ends inside an unclosed fence or comment has hidden
  # everything after the opener from this parser, exactly as GitHub's own
  # rendering hides it; say so, or the author goes looking for a section
  # that is right there.
  hint=""
  (( in_fence )) && hint=" (the description ends inside an unclosed code fence, which hides everything after it — close the fence)"
  (( in_comment )) && hint=" (the description ends inside an unclosed <!-- comment, which hides everything after it — close the comment)"
  fault "a \`feat\`, \`fix\` or \`perf\` title, or a breaking change, owes a \`## Changelog\` section in the pull-request description — add one with \`### Added\`/\`### Changed\`/\`### Deprecated\`/\`### Removed\`/\`### Fixed\`/\`### Security\` bullets, or the single line \`None.\` if the change is not notable${hint}"
fi

exit "$status"
