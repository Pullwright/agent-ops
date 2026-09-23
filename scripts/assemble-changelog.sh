#!/usr/bin/env bash
# scripts/assemble-changelog.sh — assemble CHANGELOG.md's `## [Unreleased]`
# section from merged pull-request descriptions (roadmap decision D27,
# agent-ops#1807). The write side of requirement 25c: every other pull
# request now writes its changelog entry into its own description's
# `## Changelog` section rather than into this file, and this script is the
# one place that turns those descriptions into the file — run by the
# release pull request in a repository that cuts releases, or a scheduled
# roll in one that does not (this repository's own roll is agent-ops#1809).
#
# Usage: assemble-changelog.sh [--check] [--since <ref>] [<path>]
#
#   <path>    defaults to CHANGELOG.md at this script's own repository root
#             (scripts/../CHANGELOG.md) — the file this script assembles,
#             wherever it has been synced.
#   --since   overrides the file's own marker as the start of the commit
#             range. Required on a file that carries no marker yet (the
#             first run after adoption); optional afterwards.
#   --check   computes what a normal run would write, compares it to the
#             file's current content, and exits non-zero — without writing —
#             if they differ, so a release workflow can refuse to tag a
#             stale file. Exits 0, silently, when they already agree
#             (idempotence: a second run with no new commits always agrees).
#
# Requires a checkout with real commit history reachable from HEAD back past
# the marker (or --since) commit — a blobless clone (`--filter=blob:none`)
# is enough, since only commit metadata is read, never blob content, but a
# shallow one (`--depth`) is not: CI must check out with `fetch-depth: 0`.
#
# --- Range -------------------------------------------------------------------
# CHANGELOG.md carries its own progress marker near its top,
# `<!-- changelog:assembled-through sha=<full sha> -->`. Every first-parent
# commit on the current branch strictly after that commit
# (`git log --first-parent --reverse <sha>..HEAD`) is a candidate — the
# squash merges that landed on this branch since the file was last
# assembled, `--first-parent` because a merge commit's own second-parent
# side is the feature branch, whose commits were squashed away and never
# reach `main` on their own. A file with neither a marker nor a `--since`
# override is an error, never a guess at where to start.
#
# --- Extraction ----------------------------------------------------------------
# Each candidate commit's body is parsed by the exact grammar
# scripts/check-changelog-section.sh enforces on every pull request before
# it can merge — shared, not duplicated, via lib/changelog-grammar.sh's
# `changelog_grammar_walk` — so this script trusts nothing check-changelog-
# section.sh would have failed. A body with no `## Changelog` section, or
# whose section says `None.`, contributes nothing. Only the first
# content-bearing section is read (a second one is itself a fault the
# checker would have caught before this commit could ever merge); a body
# that predates requirement 25c's adoption and fails the grammar outright
# (no marker sha old enough to predate it, in practice) contributes nothing
# rather than aborting the run — this script assembles history, and one
# malformed old commit must not block every commit after it. A bullet keeps
# its indented continuation lines verbatim.
#
# --- Output --------------------------------------------------------------------
# Under `## [Unreleased]` (created, below the preamble — before the first
# existing `## ` heading, or at the end of the file if there is none — when
# absent), one `### <Category>` per category present, in Keep a Changelog
# order (Added, Changed, Deprecated, Removed, Fixed, Security), newest
# commit first within a category. Each bullet ends with ` (#N)`, `N` the
# squash title's own trailing `(#N)` GitHub appends on merge, unless the
# bullet already cites that number somewhere in its own text. Existing
# bullets already under `[Unreleased]`, and every released section, are
# left byte-for-byte unchanged; new bullets are inserted above the existing
# ones of their category, and a wholly new category heading takes its
# Keep a Changelog place among whatever categories are already there. The
# marker is rewritten to `HEAD` whether or not any commit in range carried
# a bullet — the marker tracks how far the file has been read, not how far
# it has changed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/changelog-grammar.sh
. "$SCRIPT_DIR/lib/changelog-grammar.sh"

usage() {
  awk 'NR >= 3 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
  exit "${1:-0}"
}

repo_root="$SCRIPT_DIR"
check_mode=0
since_ref=""
path=""

while (( $# > 0 )); do
  case "$1" in
    --check) check_mode=1; shift ;;
    --since)
      [[ $# -ge 2 ]] || { echo "usage: ${0##*/} [--check] [--since <ref>] [<path>]" >&2; exit 2; }
      since_ref="$2"; shift 2 ;;
    --help|-h) usage 0 ;;
    --) shift; break ;;
    -*) echo "usage: ${0##*/} [--check] [--since <ref>] [<path>]" >&2; exit 2 ;;
    *)
      if [[ -n "$path" ]]; then
        echo "usage: ${0##*/} [--check] [--since <ref>] [<path>]" >&2
        exit 2
      fi
      path="$1"; shift ;;
  esac
done
if (( $# > 0 )); then
  [[ -n "$path" ]] || { path="$1"; shift; }
fi
: "${path:="$repo_root/CHANGELOG.md"}"

MARKER_PREFIX='<!-- changelog:assembled-through sha='
marker_line_regex='^<!-- changelog:assembled-through sha=([0-9a-f]{40}) -->[[:space:]]*$'
CATEGORY_ORDER=(Added Changed Deprecated Removed Fixed Security)

existing_content=""
[[ -f "$path" ]] && existing_content="$(cat "$path")"

# --- Resolve the range's starting sha -----------------------------------------
existing_marker_sha=""
if [[ -n "$existing_content" ]]; then
  while IFS= read -r l; do
    if [[ "$l" =~ $marker_line_regex ]]; then
      existing_marker_sha="${BASH_REMATCH[1]}"
      break
    fi
  done <<<"$existing_content"
fi

if [[ -n "$since_ref" ]]; then
  since_sha="$(git -C "$repo_root" rev-parse --verify "${since_ref}^{commit}" 2>/dev/null)" || {
    echo "assemble-changelog: cannot resolve --since ref '$since_ref' to a commit" >&2
    exit 1
  }
elif [[ -n "$existing_marker_sha" ]]; then
  since_sha="$existing_marker_sha"
else
  echo "assemble-changelog: $path carries no <!-- changelog:assembled-through --> marker and no --since <ref> was given" >&2
  exit 1
fi

head_sha="$(git -C "$repo_root" rev-parse HEAD)"

# --- Extraction: walk a body via the shared grammar into CATEGORY -> blocks -
# Shared by both a candidate commit's body (a fresh block per bullet, with
# the `(#N)` suffix) and the existing `[Unreleased]` section's own inner text
# (wrapped in a synthetic `## Changelog` heading so the same grammar applies,
# no `(#N)` suffix since a prior run already added one) — one state machine,
# a target associative-array name (`declare -n`) telling it where to file
# what it finds. Only the body's first content-bearing section is read (a
# second one is itself a fault scripts/check-changelog-section.sh would have
# already caught before this commit could ever merge).
#
# Every bullet this call finds is staged locally first and only merged into
# the target once the whole section is confirmed clean — never written
# straight through as each bullet is seen. A body that fails the grammar
# anywhere in its one section (`BAD-FIRST`, `NONE-BAD`, `LOOSE`, an orphan
# continuation, an invalid or duplicate category, an empty one — every fault
# scripts/check-changelog-section.sh itself raises) contributes nothing at
# all, rather than the bullets seen before the fault: a real, merged
# pre-adoption commit in this repository's own history (agent-ops#1819) has
# an unindented paragraph continuation the grammar reads as `LOOSE` mid-
# bullet, and truncating that bullet at the fault line — silently shipping
# half a sentence into `CHANGELOG.md` — is worse than dropping it whole.
_cc_pr_n=""
_cc_target_name=""
_cc_section_n=""
_cc_cur_category=""
_cc_cur_valid=1
_cc_bad=0
_cc_block=()
declare -A _cc_staged=()

_cc_flush_block() {
  if (( ${#_cc_block[@]} > 0 )) && [[ -n "$_cc_cur_category" ]] && (( _cc_cur_valid )); then
    local block
    block="$(printf '%s\n' "${_cc_block[@]}")"
    block="${block%$'\n'}"
    if [[ -n "$_cc_pr_n" ]] && [[ ! "$block" =~ (^|[^0-9])#${_cc_pr_n}([^0-9]|$) ]]; then
      block+=" (#${_cc_pr_n})"
    fi
    # shellcheck disable=SC2004  # associative array: $ is required to use
    # the category NAME as the key, not the literal text "_cc_cur_category"
    if [[ -n "${_cc_staged[$_cc_cur_category]+x}" ]]; then
      _cc_staged[$_cc_cur_category]+=$'\x1e'"$block"
    else
      _cc_staged[$_cc_cur_category]="$block"
    fi
  fi
  _cc_block=()
}

changelog_collect() {  # changelog_collect BODY PR_N TARGET_ARRAY_NAME
  local body="$1"
  _cc_pr_n="$2"
  _cc_target_name="$3"
  _cc_section_n=""
  _cc_cur_category=""
  _cc_cur_valid=1
  _cc_bad=0
  _cc_block=()
  _cc_staged=()

  local event rest
  while IFS=$'\t' read -r event rest; do
    case "$event" in
      SECTION-START)
        if [[ -z "$_cc_section_n" ]]; then
          IFS=$'\t' read -r _cc_section_n <<<"$rest"
        fi
        ;;
      CATEGORY)
        local sn name valid dup
        IFS=$'\t' read -r sn name valid dup <<<"$rest"
        [[ "$sn" == "$_cc_section_n" ]] || continue
        _cc_flush_block
        _cc_cur_category="$name"
        _cc_cur_valid="$valid"
        if (( ! valid )) || (( dup )); then _cc_bad=1; fi
        ;;
      CATEGORY-END)
        local sn bullets
        IFS=$'\t' read -r sn _ bullets <<<"$rest"
        [[ "$sn" == "$_cc_section_n" ]] || continue
        (( bullets == 0 )) && _cc_bad=1
        ;;
      BULLET)
        local sn line
        IFS=$'\t' read -r sn line <<<"$rest"
        [[ "$sn" == "$_cc_section_n" ]] || continue
        _cc_flush_block
        _cc_block=("$line")
        ;;
      CONTINUATION)
        local sn open line
        IFS=$'\t' read -r sn _ open line <<<"$rest"
        [[ "$sn" == "$_cc_section_n" ]] || continue
        if (( open )); then
          _cc_block+=("$line")
        else
          _cc_bad=1
        fi
        ;;
      LOOSE)
        local sn
        IFS=$'\t' read -r sn _ <<<"$rest"
        [[ "$sn" == "$_cc_section_n" ]] && _cc_bad=1
        ;;
      BAD-FIRST|NONE-BAD)
        local sn
        IFS=$'\t' read -r sn _ <<<"$rest"
        [[ "$sn" == "$_cc_section_n" ]] && _cc_bad=1
        ;;
      *) ;;
    esac
  done < <(changelog_grammar_walk "$body")

  _cc_flush_block

  if (( ! _cc_bad )); then
    local -n _cc_target="$_cc_target_name"
    local cat
    for cat in "${!_cc_staged[@]}"; do
      # shellcheck disable=SC2004  # associative via nameref, see above
      if [[ -n "${_cc_target[$cat]+x}" ]]; then
        _cc_target[$cat]+=$'\x1e'"${_cc_staged[$cat]}"
      else
        _cc_target[$cat]="${_cc_staged[$cat]}"
      fi
    done
  fi
}

declare -A AC_CAT_BLOCKS=()
while IFS= read -r -d '' rec; do
  # A multi-line body defeats a `read <<<"$rec"` split — `read` stops at the
  # first embedded newline regardless of IFS. Peel the two known-tab-free
  # prefix fields off with parameter expansion instead, which never treats a
  # newline specially, leaving the body (real newlines and all) untouched in
  # the final remainder.
  rec_rest="${rec#*$'\x1f'}"
  subject="${rec_rest%%$'\x1f'*}"
  body="${rec_rest#*$'\x1f'}"
  n=""
  if [[ "$subject" =~ \(#([0-9]+)\)[[:space:]]*$ ]]; then
    n="${BASH_REMATCH[1]}"
  fi
  changelog_collect "$body" "$n" AC_CAT_BLOCKS
done < <(git -C "$repo_root" log --first-parent --reverse -z --format='%H%x1f%s%x1f%b' "${since_sha}..HEAD" --)

# --- Render: assembled as an array of lines throughout, never a string ------
# routed back through a `$(...)` command substitution — command substitution
# unconditionally strips trailing newlines, which is exactly what silently
# ate the blank line meant to separate the marker from the next heading in
# an earlier version of this script. Lines only, end to end; joined once, at
# the very end.
trim_trailing_blank() {  # trim_trailing_blank ARRAY_NAME
  local -n _ttb="$1"
  while (( ${#_ttb[@]} > 0 )) && [[ -z "${_ttb[-1]}" ]]; do
    unset '_ttb[-1]'
  done
}

append_category_block() {  # append_category_block CATEGORY TARGET_ARRAY_NAME
  local cat="$1"
  local -n _acb_tgt="$2"
  local new_raw="${AC_CAT_BLOCKS[$cat]:-}" existing_raw="${EXISTING_CAT_BLOCKS[$cat]:-}"
  [[ -n "$new_raw" || -n "$existing_raw" ]] || return 0

  local -a blocks=()
  if [[ -n "$new_raw" ]]; then
    # Newest first: AC_CAT_BLOCKS accumulated oldest-to-newest (--reverse
    # log order), so reverse it back on the way out.
    local -a nb=()
    local remaining="$new_raw"
    while [[ "$remaining" == *$'\x1e'* ]]; do
      nb+=("${remaining%%$'\x1e'*}")
      remaining="${remaining#*$'\x1e'}"
    done
    nb+=("$remaining")
    local i
    for (( i = ${#nb[@]} - 1; i >= 0; i-- )); do
      blocks+=("${nb[$i]}")
    done
  fi
  if [[ -n "$existing_raw" ]]; then
    # Already newest-first on disk; append in the order found, unreversed.
    local remaining="$existing_raw"
    while [[ "$remaining" == *$'\x1e'* ]]; do
      blocks+=("${remaining%%$'\x1e'*}")
      remaining="${remaining#*$'\x1e'}"
    done
    blocks+=("$remaining")
  fi

  (( ${#_acb_tgt[@]} > 0 )) && _acb_tgt+=("")
  _acb_tgt+=("### $cat" "")
  local b
  for b in "${blocks[@]}"; do
    local bl="$b"
    while [[ "$bl" == *$'\n'* ]]; do
      _acb_tgt+=("${bl%%$'\n'*}")
      bl="${bl#*$'\n'}"
    done
    _acb_tgt+=("$bl")
  done
}

lines=()
if [[ -n "$existing_content" ]]; then
  mapfile -t lines <<<"$existing_content"
fi

marker_idx=-1
for i in "${!lines[@]}"; do
  if [[ "${lines[$i]}" =~ $marker_line_regex ]]; then marker_idx=$i; break; fi
done

first_heading_idx=-1
for i in "${!lines[@]}"; do
  if [[ "${lines[$i]}" =~ ^##[[:space:]] ]]; then first_heading_idx=$i; break; fi
done

unreleased_start=-1
for i in "${!lines[@]}"; do
  if [[ "${lines[$i]}" =~ ^##[[:space:]]+\[Unreleased\][[:space:]]*$ ]]; then unreleased_start=$i; break; fi
done
unreleased_end=${#lines[@]}
if (( unreleased_start >= 0 )); then
  for (( i = unreleased_start + 1; i < ${#lines[@]}; i++ )); do
    if [[ "${lines[$i]}" =~ ^##[[:space:]] ]]; then unreleased_end=$i; break; fi
  done
fi

declare -A EXISTING_CAT_BLOCKS=()
if (( unreleased_start >= 0 )); then
  existing_inner="## Changelog"$'\n\n'
  for (( i = unreleased_start + 1; i < unreleased_end; i++ )); do
    existing_inner+="${lines[$i]}"$'\n'
  done
  changelog_collect "$existing_inner" "" EXISTING_CAT_BLOCKS
fi

any_new=0
for cat in "${CATEGORY_ORDER[@]}"; do
  [[ -n "${AC_CAT_BLOCKS[$cat]:-}" ]] && any_new=1
done
need_unreleased=0
(( unreleased_start >= 0 || any_new )) && need_unreleased=1

unreleased_block_lines=()
if (( need_unreleased )); then
  unreleased_block_lines=("## [Unreleased]")
  for cat in "${CATEGORY_ORDER[@]}"; do
    append_category_block "$cat" unreleased_block_lines
  done
fi

if (( unreleased_start >= 0 )); then
  pre_end=$(( unreleased_start - 1 ))
  post_start=$unreleased_end
elif (( first_heading_idx >= 0 )); then
  pre_end=$(( first_heading_idx - 1 ))
  post_start=$first_heading_idx
else
  pre_end=$(( ${#lines[@]} - 1 ))
  post_start=${#lines[@]}
fi

out_lines=()
if (( pre_end >= 0 )); then
  for (( i = 0; i <= pre_end; i++ )); do out_lines+=("${lines[$i]}"); done
fi
if (( ${#out_lines[@]} == 0 )); then
  out_lines=(
    "# Changelog" ""
    "All notable changes to this project are documented in this file." ""
    "The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/)." ""
  )
fi

marker_new_line="${MARKER_PREFIX}${head_sha} -->"
if (( marker_idx >= 0 && marker_idx <= pre_end )); then
  out_lines[marker_idx]="$marker_new_line"
  trim_trailing_blank out_lines
  out_lines+=("")
else
  trim_trailing_blank out_lines
  out_lines+=("" "$marker_new_line" "")
fi

if (( need_unreleased )); then
  out_lines+=("${unreleased_block_lines[@]}")
  trim_trailing_blank out_lines
  out_lines+=("")
fi

for (( i = post_start; i < ${#lines[@]}; i++ )); do out_lines+=("${lines[$i]}"); done
trim_trailing_blank out_lines

if (( check_mode )); then
  new_content="$(printf '%s\n' "${out_lines[@]}")"
  if [[ "$new_content"$'\n' == "$existing_content"$'\n' ]]; then
    exit 0
  fi
  echo "assemble-changelog: $path is behind HEAD ($head_sha) — run without --check to regenerate it" >&2
  exit 1
fi

printf '%s\n' "${out_lines[@]}" > "$path"
