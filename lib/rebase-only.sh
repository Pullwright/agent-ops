#!/usr/bin/env bash
# shellcheck disable=SC2034  # this file's functions are sourced into agent-cycle.sh's process (#771); nothing here is unused, just not referenced from within this file itself.
#
# lib/rebase-only.sh — the diff-identity primitive requirement 31e/46a build
# on (agent-ops#1806): whether a push changed anything about a pull
# request's own net content, regardless of whether it authored a new commit.
#
# A plain rebase replays a commit's original author date and changes nothing
# about what it introduces, so requirement 46's restale sweep already treats
# "no commit authored since the review" as no progress. A merge-conflicts
# resolution commit is different in exactly one way that matters here: it
# authors a genuinely new commit (a fresh authored date), yet the tree it
# produces can be — and, for a clean rebase or a both-sides-kept resolution,
# usually is — identical in net content to what stood before. Authored-date
# alone cannot tell those two apart; comparing the actual diff can.
#
# `git patch-id --stable` is the primitive, not a byte-for-byte tree or
# textual diff comparison: it is exactly the tool built to answer "does this
# patch introduce the same change", and unlike a tree hash it survives a
# rebase's changed base — the same blob can sit at a different path in the
# tree, and the same hunk can carry different surrounding line numbers,
# without the patch-id changing, provided the actual added/removed content
# and its immediate context are unchanged. It does **not** ignore context: a
# hunk whose surrounding lines differ (a true same-region conflict resolved
# by keeping both sides, where the second side's content now sits in the
# first side's context) produces a different patch-id, correctly — that
# case is a content change, not a rebase, and must take the full Reviewer/
# Approver path. Only a change whose own diff — content and immediate
# context both — is byte-for-byte reproduced against its new base counts as
# rebase-only.
#
# Every function here fails closed: a merge-base that cannot be computed, a
# ref that cannot be resolved, or a `patch-id` invocation that produces no
# output is never read as "unchanged". Guessing "rebase-only" on a read
# failure would carry forward a Reviewer/Approver verdict for content nobody
# has actually confirmed is the same — silently skipping the very review
# this pipeline exists to run.

# diff_patch_id GIT_DIR BASE_REF HEAD_REF
# Prints the stable patch-id (`git patch-id --stable`'s first field only —
# its second field is the commit id, which differs by construction and is
# never part of the comparison) of HEAD_REF's diff against its own
# merge-base with BASE_REF, computed inside the repository at GIT_DIR.
# Prints nothing and returns 1 if either ref is unresolvable in that
# repository, or if the diff is empty (an empty diff has no patch-id at
# all, and treating "nothing to compare" as "identical" would be exactly
# the false "unchanged" this file exists to avoid).
diff_patch_id() {
  local git_dir="$1" base_ref="$2" head_ref="$3" merge_base id
  merge_base="$(git -C "$git_dir" merge-base "$base_ref" "$head_ref" 2>/dev/null)" || return 1
  [[ -n "$merge_base" ]] || return 1
  id="$(git -C "$git_dir" diff "$merge_base" "$head_ref" 2>/dev/null \
        | git -C "$git_dir" patch-id --stable 2>/dev/null | awk '{print $1; exit}')"
  [[ -n "$id" ]] || return 1
  printf '%s' "$id"
}

# rebase_only_push GIT_DIR OLD_BASE OLD_HEAD NEW_BASE NEW_HEAD
# True (exit 0) when NEW_HEAD's diff against NEW_BASE is patch-id-identical
# to OLD_HEAD's diff against OLD_BASE — the push changed no net content,
# whatever it changed about the commit graph to get there. False (exit 1,
# no output) whenever either patch-id could not be computed at all: a read
# failure is "could not tell", never "unchanged".
rebase_only_push() {
  local git_dir="$1" old_base="$2" old_head="$3" new_base="$4" new_head="$5"
  local old_id new_id
  old_id="$(diff_patch_id "$git_dir" "$old_base" "$old_head")" || return 1
  new_id="$(diff_patch_id "$git_dir" "$new_base" "$new_head")" || return 1
  [[ "$old_id" == "$new_id" ]]
}

# rebase_only_forge_capture SLUG BASE_NAME BRANCH
# rebase_only_forge_check BASE_NAME BRANCH
# `rebase_only_push` against what the forge holds, in a repository only the
# Script has written, in two halves either side of the Implementer stage.
# The capture fetches BRANCH's and BASE_NAME's heads from the forge, sets
# `rebase_only_old_head` and `rebase_only_old_base` to them, and computes the
# old diff's patch-id then and there (`rebase_only_old_id`), while both
# commits are still branch tips the forge will serve. The check fetches the
# two heads again, sets `rebase_only_new_head` and `rebase_only_new_base` for
# the caller's log line, and is true (exit 0) when BRANCH's head has moved
# and its diff against BASE_NAME's head has the captured patch-id. Nothing in
# the check asks the forge for the old head, which a force-push has by then
# made unreachable from every ref, and which a forge need not serve by its
# id at all.
#
# Never computed in a stage's workspace. That clone is the Implementer's to
# rewrite (requirement 45e): its `.git/config` names `origin` and can name
# diff drivers, filters, an fsmonitor and hooks, so a comparison run there
# would both answer whatever the stage arranged and run the stage's commands
# as the Script. Here the heads are fetched by name from the forge's own URL,
# commits only (`--filter=tree:0`: `merge-base` needs nothing else, and
# `diff` fetches just the trees and blobs it compares), into a bare
# repository made by the capture under the Script's own scratch directory
# (`rebase_only_repo`), which the check reuses, so the second fetch brings
# only what the push added, and then removes. The Script's own git
# configuration — the credential helper through the gh shim — is the only
# configuration in play.
#
# Fails closed like everything else in this file: a head that cannot be
# fetched, a head that has not moved (no push, which is not a push that
# changed nothing), a patch-id that cannot be computed, or a check with no
# capture before it is never rebase-only.
rebase_only_repo=""
rebase_only_old_head=""; rebase_only_old_base=""; rebase_only_old_id=""
rebase_only_new_head=""; rebase_only_new_base=""

# _rebase_only_fetch_pair LABEL BASE_NAME BRANCH
# Fetch BRANCH's and BASE_NAME's heads into `rebase_only_repo`, commits only,
# as refs/rebase-only/LABEL-head and refs/rebase-only/LABEL-base.
_rebase_only_fetch_pair() {
  git -C "$rebase_only_repo" fetch --quiet --no-tags --filter=tree:0 origin \
    "+refs/heads/$3:refs/rebase-only/$1-head" \
    "+refs/heads/$2:refs/rebase-only/$1-base" >/dev/null 2>&1
}

# _rebase_only_ref LABEL-PART
# The commit refs/rebase-only/LABEL-PART names in `rebase_only_repo`.
_rebase_only_ref() {
  git -C "$rebase_only_repo" rev-parse --verify --quiet "refs/rebase-only/$1" 2>/dev/null
}

# rebase_only_forge_release
# Remove the capture's repository, if there is one.
rebase_only_forge_release() {
  [[ -z "$rebase_only_repo" ]] || rm -rf -- "$rebase_only_repo"
  rebase_only_repo=""
}

rebase_only_forge_capture() {
  local slug="$1" base_name="$2" branch="$3"
  rebase_only_forge_release
  rebase_only_old_head=""; rebase_only_old_base=""; rebase_only_old_id=""
  [[ -n "$slug" && -n "$base_name" && -n "$branch" ]] || return 1
  rebase_only_repo="$(mktemp -d "${TMPDIR:-/tmp}/rebase-only.XXXXXX")" || { rebase_only_repo=""; return 1; }
  if git init --quiet --bare "$rebase_only_repo" >/dev/null 2>&1 \
     && git -C "$rebase_only_repo" remote add origin "https://github.com/$slug.git" \
     && _rebase_only_fetch_pair old "$base_name" "$branch" \
     && rebase_only_old_head="$(_rebase_only_ref old-head)" \
     && rebase_only_old_base="$(_rebase_only_ref old-base)" \
     && rebase_only_old_id="$(diff_patch_id "$rebase_only_repo" "$rebase_only_old_base" "$rebase_only_old_head")"; then
    return 0
  fi
  rebase_only_forge_release
  rebase_only_old_head=""; rebase_only_old_base=""; rebase_only_old_id=""
  return 1
}

rebase_only_forge_check() {
  local base_name="$1" branch="$2" new_id result=1
  rebase_only_new_head=""; rebase_only_new_base=""
  if [[ -n "$rebase_only_repo" && -n "$rebase_only_old_head" && -n "$rebase_only_old_id" \
        && -n "$base_name" && -n "$branch" ]] \
     && _rebase_only_fetch_pair new "$base_name" "$branch" \
     && rebase_only_new_head="$(_rebase_only_ref new-head)" \
     && rebase_only_new_base="$(_rebase_only_ref new-base)" \
     && [[ "$rebase_only_new_head" != "$rebase_only_old_head" ]] \
     && new_id="$(diff_patch_id "$rebase_only_repo" "$rebase_only_new_base" "$rebase_only_new_head")" \
     && [[ "$new_id" == "$rebase_only_old_id" ]]; then
    result=0
  fi
  rebase_only_forge_release
  return "$result"
}
