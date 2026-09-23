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
# commit first within a category and, within one commit, in the order its
# author wrote them. Each bullet ends with ` (#N)`, `N` the squash title's
# own trailing `(#N)` GitHub appends on merge, unless the bullet already
# cites that number somewhere in its own text.
#
# An existing `[Unreleased]` section is *spliced*, never re-rendered: its
# lines are carried across one for one and the new bullets inserted above
# the existing ones of their category, a wholly new category heading taking
# its Keep a Changelog place among whatever headings are already there. So
# existing bullets, and every released section, are left byte-for-byte
# unchanged — including the things the pull-request-description grammar
# would fault but a real changelog legitimately carries (a category heading
# appearing twice, a heading outside the six, prose, blank lines between
# bullets). Re-rendering the section from that grammar's parse instead would
# delete every such file's whole `[Unreleased]` section on the first run.
#
# The marker is rewritten to `HEAD` whether or not any commit in range
# carried a bullet — the marker tracks how far the file has been read, not
# how far it has changed. It only ever advances over a range that was
# actually read: a `git log` that fails (a shallow checkout, a marker sha
# this repository does not carry) is an error that exits non-zero, never an
# empty range that would carry the marker silently past unread commits.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/changelog-grammar.sh
. "$SCRIPT_DIR/lib/changelog-grammar.sh"

usage() {
  # The header's opening summary and its usage block, stopping at the first
  # `# --- ` divider: everything past that is design commentary for a reader of
  # the source, not for someone who typed --help.
  awk 'NR >= 2 { if ($0 !~ /^#/ || $0 ~ /^# --- /) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
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

if ! git -C "$repo_root" rev-parse --verify --quiet "${since_sha}^{commit}" >/dev/null; then
  echo "assemble-changelog: $since_sha is not a commit in this checkout — a shallow clone (--depth) does not carry enough history; CI must check out with fetch-depth: 0" >&2
  exit 1
fi

head_sha="$(git -C "$repo_root" rev-parse HEAD)"

# --- Extraction: walk a body via the shared grammar into CATEGORY -> blocks -
# Applied to a candidate commit's body — a fresh block per bullet, with the
# `(#N)` suffix — and to nothing else. The existing `[Unreleased]` section is
# deliberately not run through it; see the render section below for why a
# validator's verdict must not decide what an existing file gets to keep.
# Only the body's first section is read (a second one is itself a fault
# scripts/check-changelog-section.sh would have already caught before this
# commit could ever merge).
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
      # Prepended, not appended: the log is walked oldest-first (`--reverse`),
      # so putting each commit's whole staged group in front of what is already
      # there leaves the newest commit's group first, as requirement 25d asks,
      # while keeping the bullets *within* one commit's own section in the order
      # its author wrote them. Reversing the flat bullet list at render time
      # instead would also have flipped those.
      # shellcheck disable=SC2004  # associative via nameref, see above
      if [[ -n "${_cc_target[$cat]+x}" ]]; then
        _cc_target[$cat]="${_cc_staged[$cat]}"$'\x1e'"${_cc_target[$cat]}"
      else
        _cc_target[$cat]="${_cc_staged[$cat]}"
      fi
    done
  fi
}

# `git log` is read into a file first, and its exit status checked, rather than
# piped straight in from a process substitution: `set -euo pipefail` does not
# observe a process substitution's status, so a git failure there would read as
# an empty range — and the marker would then advance to HEAD past every commit
# that was never read, losing their entries permanently and silently.
commits_file="$(mktemp)"
trap 'rm -f "$commits_file"' EXIT
if ! git -C "$repo_root" log --first-parent --reverse -z \
     --format='%H%x1f%s%x1f%b' "${since_sha}..HEAD" -- >"$commits_file"; then
  echo "assemble-changelog: cannot read the commit range ${since_sha}..HEAD" >&2
  exit 1
fi

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
done <"$commits_file"

# --- Render: splice into the existing file; never re-render it ----------------
# Assembled as an array of lines throughout, never a string routed back through
# a `$(...)` command substitution — command substitution unconditionally strips
# trailing newlines, which is exactly what silently ate the blank line meant to
# separate the marker from the next heading in an earlier version of this
# script. Lines only, end to end; joined once, at the very end.
#
# Whatever is already under `## [Unreleased]` is carried across line by line
# and new bullets are spliced in around it. The existing section is
# deliberately *not* re-parsed through the shared grammar and re-rendered from
# the result: that grammar is a validator for one pull-request description, and
# a long-lived CHANGELOG.md legitimately holds things it faults — a category
# heading appearing more than once (this repository's own file has thirteen
# headings for six names), a heading outside the six, a line of prose before
# the first one, a blank line between two bullets. A validator's verdict is the
# wrong instrument for deciding what to keep: reconstructing the section from a
# parse that is allowed to fail means a file like that loses its entire
# `[Unreleased]` section, silently and with exit 0, on the very first run.
# Splicing cannot lose what it never re-renders, which is what makes
# requirement 25d's "left byte-for-byte unchanged" true rather than aspirational.
trim_trailing_blank() {  # trim_trailing_blank ARRAY_NAME
  local -n _ttb="$1"
  while (( ${#_ttb[@]} > 0 )) && [[ -z "${_ttb[-1]}" ]]; do
    unset '_ttb[-1]'
  done
}

# new_bullet_lines CATEGORY ARRAY_NAME — the new bullets for CATEGORY, newest
# commit first (changelog_collect already prepends each commit's group), each
# block exploded back into its own lines.
new_bullet_lines() {
  local raw="${AC_CAT_BLOCKS[$1]:-}"
  local -n _nbl="$2"
  _nbl=()
  [[ -n "$raw" ]] || return 0
  local block remaining="$raw" bl
  while :; do
    if [[ "$remaining" == *$'\x1e'* ]]; then
      block="${remaining%%$'\x1e'*}"
      remaining="${remaining#*$'\x1e'}"
    else
      block="$remaining"
      remaining=""
    fi
    bl="$block"
    while [[ "$bl" == *$'\n'* ]]; do
      _nbl+=("${bl%%$'\n'*}")
      bl="${bl#*$'\n'}"
    done
    _nbl+=("$bl")
    [[ -n "$remaining" ]] || break
  done
}

# category_rank NAME — its index in Keep a Changelog order, or one past the end
# for a heading the file carries that is not one of the six.
category_rank() {
  local name="$1" i
  for i in "${!CATEGORY_ORDER[@]}"; do
    [[ "${CATEGORY_ORDER[$i]}" == "$name" ]] && { printf '%s\n' "$i"; return 0; }
  done
  printf '%s\n' "${#CATEGORY_ORDER[@]}"
}

# emit_joined VALUE ARRAY_NAME — append the newline-terminated lines held in
# VALUE to ARRAY_NAME, blank ones included.
emit_joined() {
  local v="$1"
  local -n _ej="$2"
  while [[ -n "$v" ]]; do
    _ej+=("${v%%$'\n'*}")
    v="${v#*$'\n'}"
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

any_new=0
for cat in "${CATEGORY_ORDER[@]}"; do
  [[ -n "${AC_CAT_BLOCKS[$cat]:-}" ]] && any_new=1
done
need_unreleased=0
(( unreleased_start >= 0 || any_new )) && need_unreleased=1

unreleased_block_lines=()
if (( unreleased_start >= 0 )); then
  # The existing section, verbatim, trailing blank lines trimmed (the final
  # assembly puts exactly one back).
  region=()
  for (( i = unreleased_start; i < unreleased_end; i++ )); do region+=("${lines[$i]}"); done
  trim_trailing_blank region

  if (( any_new )); then
    # Where each category's heading already is, skipping any inside a fenced
    # block. The *first* occurrence wins: new bullets go above the existing
    # ones of their category, and a file with the same heading more than once
    # (which this repository's own has) is spliced, not rejected.
    declare -A region_head=()
    region_head_names=()
    region_head_idx=()
    in_fence=0
    fence_char=""
    for (( j = 1; j < ${#region[@]}; j++ )); do
      if [[ "${region[$j]}" =~ ^[[:space:]]{0,3}(\`{3,}|~{3,}) ]]; then
        if (( in_fence )); then
          [[ "${BASH_REMATCH[1]:0:1}" == "$fence_char" ]] && in_fence=0
        else
          in_fence=1
          fence_char="${BASH_REMATCH[1]:0:1}"
        fi
        continue
      fi
      (( in_fence )) && continue
      if [[ "${region[$j]}" =~ ^###[[:space:]]+(.+[^[:space:]])[[:space:]]*$ ]]; then
        hname="${BASH_REMATCH[1]}"
        [[ -n "${region_head[$hname]+x}" ]] || region_head[$hname]=$j
        region_head_names+=("$hname")
        region_head_idx+=("$j")
      fi
    done

    # One insertion plan, keyed by the region index the lines go *before*, so
    # the splice is a single forward pass and no index ever has to be adjusted
    # for an earlier insertion.
    declare -A ins_at=()
    for cat in "${CATEGORY_ORDER[@]}"; do
      nb=()
      new_bullet_lines "$cat" nb
      (( ${#nb[@]} > 0 )) || continue
      ins=()
      if [[ -n "${region_head[$cat]+x}" ]]; then
        at=$(( region_head[$cat] + 1 ))
        if (( at >= ${#region[@]} )); then
          ins=("" "${nb[@]}")                     # heading is the last line
        else
          if [[ -z "${region[$at]}" ]]; then
            at=$(( at + 1 ))                      # past the heading's own blank line
          fi
          ins=("${nb[@]}")
          if (( at < ${#region[@]} )) && [[ "${region[$at]}" =~ ^#{1,6}[[:space:]] ]]; then
            ins+=("")                             # keep a blank before the next heading
          fi
        fi
      else
        # A wholly new category heading takes its Keep a Changelog place among
        # whatever headings are already there.
        rank="$(category_rank "$cat")"
        at=${#region[@]}
        for k in "${!region_head_idx[@]}"; do
          if (( $(category_rank "${region_head_names[$k]}") > rank )); then
            at=${region_head_idx[$k]}
            break
          fi
        done
        if (( at >= ${#region[@]} )); then
          ins=("" "### $cat" "" "${nb[@]}")
        else
          ins=("### $cat" "" "${nb[@]}" "")
        fi
      fi
      joined=""
      for l in "${ins[@]}"; do joined+="$l"$'\n'; done
      if [[ -n "${ins_at[$at]+x}" ]]; then ins_at[$at]+="$joined"; else ins_at[$at]="$joined"; fi
    done

    for (( j = 0; j < ${#region[@]}; j++ )); do
      if [[ -n "${ins_at[$j]+x}" ]]; then emit_joined "${ins_at[$j]}" unreleased_block_lines; fi
      unreleased_block_lines+=("${region[$j]}")
    done
    j=${#region[@]}
    if [[ -n "${ins_at[$j]+x}" ]]; then emit_joined "${ins_at[$j]}" unreleased_block_lines; fi
  else
    unreleased_block_lines=("${region[@]}")
  fi
elif (( any_new )); then
  unreleased_block_lines=("## [Unreleased]")
  for cat in "${CATEGORY_ORDER[@]}"; do
    nb=()
    new_bullet_lines "$cat" nb
    (( ${#nb[@]} > 0 )) || continue
    unreleased_block_lines+=("" "### $cat" "" "${nb[@]}")
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
