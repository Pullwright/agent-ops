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
# not a section, and a `<!-- -->` note inside one is not content):
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

if (( $# < 1 )); then
  printf 'usage: %s <pr-body> [<pr-title>]\n' "${0##*/}" >&2
  exit 2
fi

body="$1"
title="${2:-}"

CATEGORIES='Added|Changed|Deprecated|Removed|Fixed|Security'
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

# --- Walk the body once ------------------------------------------------------
# States: outside the section, inside it before any content, inside it in
# `None` mode, inside it in category mode, or inside it after a fault on its
# first line (`bad`, which swallows the rest so one mistake reports once).
sections=0
in_fence=0
in_comment=0
in_section=0
mode=""
category=""
bullets=0
seen_categories=""
content_lines=0

close_category() {
  if [[ -n "$category" ]] && (( bullets == 0 )); then
    fault "\`### $category\` in the \`## Changelog\` section has no bullet under it — add at least one \`- \` bullet, or remove the heading"
  fi
  category=""
  bullets=0
}

close_section() {
  (( in_section )) || return 0
  # No content but blank lines and comments is an absent section, not an
  # empty one — see the header. Only a section with content counts towards
  # "exactly one".
  if (( content_lines > 0 )); then
    sections=$(( sections + 1 ))
    if (( sections > 1 )); then
      fault "more than one \`## Changelog\` section with content — keep exactly one"
    fi
    if [[ "$mode" == "categories" ]]; then
      close_category
    fi
  fi
  in_section=0
  mode=""
}

while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"

  # Fenced code: nothing inside it is a heading, content or a fault.
  if [[ "$line" =~ ^[[:space:]]{0,3}(\`\`\`|~~~) ]]; then
    if (( in_fence )); then in_fence=0; else in_fence=1; fi
    continue
  fi
  (( in_fence )) && continue

  # HTML comments, single- or multi-line: skipped the same way.
  if (( in_comment )); then
    [[ "$line" == *'-->'* ]] && in_comment=0
    continue
  fi
  if [[ "$line" =~ ^[[:space:]]*\<!-- ]]; then
    [[ "$line" == *'-->'* ]] || in_comment=1
    continue
  fi

  # A level-one or level-two heading: the section's own, or the end of it.
  if [[ "$line" =~ ^##[[:space:]]+[Cc][Hh][Aa][Nn][Gg][Ee][Ll][Oo][Gg][[:space:]]*$ ]]; then
    close_section
    in_section=1
    mode=""
    content_lines=0
    continue
  fi
  if [[ "$line" =~ ^#[[:space:]] || "$line" =~ ^##[[:space:]]+[^#[:space:]] ]]; then
    close_section
    continue
  fi

  (( in_section )) || continue
  [[ "$mode" == "bad" ]] && continue
  [[ -z "${line//[[:space:]]/}" ]] && continue
  content_lines=$(( content_lines + 1 ))

  case "$mode" in
    "")
      if [[ "$line" =~ ^None([[:space:][:punct:]]|$) ]]; then
        mode="none"
      elif [[ "$line" =~ ^###[[:space:]]+(.+[^[:space:]])[[:space:]]*$ ]]; then
        mode="categories"
        category="${BASH_REMATCH[1]}"
        bullets=0
        if [[ ! "$category" =~ ^(${CATEGORIES})$ ]]; then
          fault "\`### $category\` is not a Keep a Changelog category — use exactly one of Added, Changed, Deprecated, Removed, Fixed, Security"
        fi
        seen_categories=" $category "
      else
        fault "the first line under \`## Changelog\` must be a \`### <Category>\` heading or the line \`None.\`, not: $line"
        mode="bad"
      fi
      ;;
    none)
      if [[ "$line" =~ ^###[[:space:]] ]]; then
        fault "the \`## Changelog\` section says \`None\` but also carries \`$line\` — either list the change under a category or say \`None.\` alone"
        mode="bad"
      elif [[ "$line" =~ ^[[:space:]]*[-*][[:space:]]+[^[:space:]] ]]; then
        fault "the \`## Changelog\` section says \`None\` but also carries a bullet: $line — either list the change under a category or say \`None.\` alone"
        mode="bad"
      fi
      ;;
    categories)
      if [[ "$line" =~ ^###[[:space:]]+(.+[^[:space:]])[[:space:]]*$ ]]; then
        close_category
        category="${BASH_REMATCH[1]}"
        bullets=0
        if [[ ! "$category" =~ ^(${CATEGORIES})$ ]]; then
          fault "\`### $category\` is not a Keep a Changelog category — use exactly one of Added, Changed, Deprecated, Removed, Fixed, Security"
        elif [[ "$seen_categories" == *" $category "* ]]; then
          fault "\`### $category\` appears more than once in the \`## Changelog\` section — merge the bullets under one heading"
        fi
        seen_categories="$seen_categories $category "
      elif [[ "$line" =~ ^[-*][[:space:]]+[^[:space:]] ]]; then
        bullets=$(( bullets + 1 ))
      elif [[ "$line" =~ ^[[:space:]]+[^[:space:]] ]]; then
        # An indented line continues the bullet above it (or is a nested
        # bullet, which the assembler keeps with its parent). Counts as
        # a bullet only if one is already open.
        (( bullets > 0 )) || fault "a line under \`### $category\` is indented but no bullet precedes it: $line"
      else
        fault "a line under \`### $category\` is neither a \`- \` bullet nor an indented continuation of one: $line"
      fi
      ;;
  esac
done <<<"$body"
close_section

# --- The title rule ----------------------------------------------------------
if (( owes )) && (( sections == 0 )); then
  fault "a \`feat\`, \`fix\` or \`perf\` title, or a breaking change, owes a \`## Changelog\` section in the pull-request description — add one with \`### Added\`/\`### Changed\`/\`### Deprecated\`/\`### Removed\`/\`### Fixed\`/\`### Security\` bullets, or the single line \`None.\` if the change is not notable"
fi

exit "$status"
