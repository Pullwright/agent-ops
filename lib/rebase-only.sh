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

# rebase_only_forge_check SLUG OLD_BASE OLD_HEAD BASE_NAME BRANCH
# `rebase_only_push` against what the forge holds, in a repository only the
# Script has written. True (exit 0) when BRANCH's head on the forge has moved
# from OLD_HEAD and its diff against BASE_NAME's head is patch-id-identical
# to OLD_HEAD's against OLD_BASE. Sets `rebase_only_new_head` and
# `rebase_only_new_base` to the two heads it read, for the caller's log line.
#
# Never computed in a stage's workspace. That clone is the Implementer's to
# rewrite (requirement 45e): its `.git/config` names `origin` and can name
# diff drivers, filters, an fsmonitor and hooks, so a comparison run there
# would both answer whatever the stage arranged and run the stage's commands
# as the Script. Here both heads come from `ls-remote` against the forge's
# own URL, and the commits are fetched, without their blobs (each is fetched
# when `diff` first needs it), into a bare repository made for this check
# under the Script's own scratch directory and removed after it. The Script's
# own git configuration — the credential helper through the gh shim — is the
# only configuration in play.
#
# Fails closed like everything else in this file: a head that cannot be
# read, a head that has not moved (no push, which is not a push that changed
# nothing), or a fetch that does not deliver the commits is never
# rebase-only.
rebase_only_new_head=""; rebase_only_new_base=""
rebase_only_forge_check() {
  local slug="$1" old_base="$2" old_head="$3" base_name="$4" branch="$5"
  local url repo result=1
  rebase_only_new_head=""; rebase_only_new_base=""
  [[ -n "$slug" && -n "$old_base" && -n "$old_head" && -n "$base_name" && -n "$branch" ]] || return 1
  url="https://github.com/$slug.git"
  rebase_only_new_head="$(git ls-remote "$url" "refs/heads/$branch" 2>/dev/null | awk '{print $1; exit}')"
  rebase_only_new_base="$(git ls-remote "$url" "refs/heads/$base_name" 2>/dev/null | awk '{print $1; exit}')"
  [[ -n "$rebase_only_new_head" && -n "$rebase_only_new_base" ]] || return 1
  [[ "$rebase_only_new_head" != "$old_head" ]] || return 1
  repo="$(mktemp -d "${TMPDIR:-/tmp}/rebase-only.XXXXXX")" || return 1
  if git init --quiet --bare "$repo" >/dev/null 2>&1 \
     && git -C "$repo" remote add origin "$url" \
     && git -C "$repo" fetch --quiet --filter=blob:none origin \
          "$old_head" "$old_base" "$rebase_only_new_head" "$rebase_only_new_base" >/dev/null 2>&1 \
     && rebase_only_push "$repo" "$old_base" "$old_head" \
          "$rebase_only_new_base" "$rebase_only_new_head"; then
    result=0
  fi
  rm -rf -- "$repo"
  return "$result"
}
