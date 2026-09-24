#!/usr/bin/env bash
#
# scripts/release-pending-reservations.sh — retry a tech-debt reservation
# release a failed cleanup could not make land (TD-PPagop-26082427).
#
# The cleanup in question was `lib/tech-debt-file.sh`'s `_techdebt_unfile`, on
# `techdebt_file_debt`'s id-reservation filing path. It ran once, on that
# function's own failure path, against the same GitHub API whose failure just
# put it there — a transient window that failed a filing's branch-create or
# contents-write call is the same window that could fail the DELETE meant to
# undo it. Nothing before this script ever retried that DELETE:
# `scripts/sweep-orphan-branches.sh` leaves a bare `td/<id>` reservation
# branch alone (issue #545, since it cannot tell whether <id> has since been
# filed elsewhere — and, since #882 retired the `td/` namespace from that
# walk, it no longer lists the namespace at all), and the release workflow
# that once swept them only ever fired for a `td/<id>` whose record actually
# reached `main` — an id that was reserved and then
# abandoned never got that push. Left uncovered, a reservation orphaned this
# way is "left for good", the exact phrase `lib/tech-debt-file.sh`'s own
# header used to concede before this script existed: observed for real on
# this repository, fourteen consecutive reservations (TD-PPagop-26082407
# through TD-PPagop-26082420) orphaned in one seventy-second window on
# 2026-08-23, each one that cleanup's own failed DELETE.
#
# agent-ops#874 retired the whole reservation path — `techdebt_file_debt`
# files a `pw::type:tech-debt`-labelled issue now, with no id, no branch and
# so no cleanup — so nothing writes a fresh marker any more and this sweep
# only ever has pre-#874 ones left to drain (agent-ops#1219). A marker, while
# any remains, is one JSON file per pending release under
# `reservation-releases/<repo>/<branch>.json` in the state
# repository (the same `state_repo` `lib/claim.sh`'s own claim registry
# already lives in, under its own `claims/` tree). This script is the other
# half: every cycle (lib/standdown.sh, step 2.1g), fleet-wide regardless of
# `--repo`, it walks that tree, retries each marker's own delete, and clears
# the marker once the branch is confirmed gone — by this retry, by a peer
# node's concurrent retry, or by anything else that already deleted it
# (a human's own `git push --delete`, now that nothing else sweeps `td/`).
# A delete that fails again leaves the marker in place for the next cycle's
# pass, so recovery costs no more than time: the marker survives until a
# transient GitHub failure finally clears, or a human deletes the branch by
# hand and lets this script notice on its next pass. A failure that is not
# transient at all — an archived target repository, a branch protected
# against deletion, a login that lost push access — would otherwise be
# retried and warned about identically for ever, so once a marker's own `ts`
# is `reservation_release_stuck_after_days` old it is escalated exactly once
# (`escalated_at` written back onto the marker itself, so no later pass
# repeats it) and thereafter retried in silence (TD-PPagop-26082806,
# agent-ops#1011).
#
# Where a `td-record/<id>` marker and its sibling `td/<id>` marker both sit
# under the same repo directory — the shape a window that failed both of
# `_techdebt_unfile`'s own deletes leaves behind — this script always acts on
# the `td-record/<id>` one first, matching `_techdebt_unfile`'s own ordering
# (TD-PPagop-26082805): that ordering existed because releasing `td/<id>`
# while `td-record/<id>` still exists let `reserve-tech-debt-id.pl` hand the
# id out again into a ref this script had not yet cleared. #882 has since
# retired that minting tool along with it, so no marker minted after #874
# will ever exist to test this — but a pre-#874 pair, if one is ever still
# being drained, keeps the same ordering this script has always promised.
# Each repo directory is fetched and classified by branch prefix in full
# before anything is deleted, so the ordering holds regardless of what order
# GitHub's own directory listing happens to name the two files in — not, as
# before, by the accident that `-` (0x2D) sorts below `_` (0x5F) in every
# marker filename this script has ever seen.
#
# Requires no repository argument: every marker names its own target repo,
# so one invocation walks every pending release in the state repository
# regardless of which repositories this installation is configured against.
# A no-op when `state_repo` is unset — the same single-node reading
# `lib/claim.sh`'s own registry gives it.
#
# Output: one JSON object per marker examined, on stdout —
#   {"action":"released","repo":…,"branch":…}
#   {"action":"absent","repo":…,"branch":…}
#   {"action":"warning","repo":…,"branch":…,"detail":…}
#   {"action":"reservation-release-stuck","repo":…,"branch":…,"detail":…}
# — and nothing at all for a marker already carrying `escalated_at`, whose
# delete failed again. The caller logs them; this script logs nothing itself. Always exits 0 — a
# branch this script fails to delete must not fail the cycle it runs inside;
# the marker it leaves behind is what stands behind it.
#
# Usage: release-pending-reservations.sh
# Environment: RELEASE_PENDING_GH overrides `gh` (tests stub it);
# AGENT_OPS_CONFIG overrides the config path, as review-cycle.sh accepts it;
# RELEASE_PENDING_NOW_EPOCH overrides "now" for the stuck-marker age check
# (tests stub it), the same seam TOGGLE_NOW_EPOCH (lib/toggle.sh) already
# uses for this repo's other age-since-a-timestamp checks.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Rate-limit-aware `gh`: sourcing this wraps every `gh` call below so a
# refusal GitHub will lift in seconds is waited out rather than degrading
# this pass to nothing. See lib/github-limit.sh.
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"
CONFIG_FILE="${AGENT_OPS_CONFIG:-$SCRIPT_DIR/config.json}"
SCHEMA_FILE="$SCRIPT_DIR/config.schema.json"
GH="${RELEASE_PENDING_GH:-gh}"

# shellcheck source=lib/config-schema.sh
. "$SCRIPT_DIR/lib/config-schema.sh"
# TECHDEBT_RECORD_BRANCH_PREFIX (td-record/) alone, the fixed prefix a
# record-branch marker's own `branch` field always starts with — sourced
# rather than typed a second time, the same reasoning
# scripts/sweep-orphan-branches.sh's own sourcing of this file already gives.
# shellcheck source=lib/tech-debt-file.sh
. "$SCRIPT_DIR/lib/tech-debt-file.sh"

# config_defaults (issue #197) is the only place a default is written: every
# key config.schema.json declares a `default` for reads as fully populated
# below, with no `// literal` of its own to drift from the schema's.
DEFAULTED_CONFIG="$(config_defaults "$CONFIG_FILE" "$SCHEMA_FILE" 2>/dev/null)"
cfg() { jq -r "$1" <<<"$DEFAULTED_CONFIG" 2>/dev/null; }

state_repo="$(cfg '.state_repo')"
[[ -n "$state_repo" ]] || exit 0

stuck_after_days="$(cfg '.reservation_release_stuck_after_days')"
[[ "$stuck_after_days" =~ ^[0-9]+$ ]] || stuck_after_days=0
now_epoch="${RELEASE_PENDING_NOW_EPOCH:-$(date -u +%s)}"

warn() {  # warn REPO BRANCH DETAIL
  jq -nc --arg r "$1" --arg b "$2" --arg d "$3" \
    '{action: "warning", repo: $r, branch: $b, detail: $d}'
}

stuck() {  # stuck REPO BRANCH DETAIL
  jq -nc --arg r "$1" --arg b "$2" --arg d "$3" \
    '{action: "reservation-release-stuck", repo: $r, branch: $b, detail: $d}'
}

# One already-fetched marker: retry its branch's delete, then clear the
# marker on any outcome that leaves nothing further to retry. Split out from
# the old single `release_one` (which also fetched the marker) so
# release_dir below can fetch and classify every marker in a directory
# before acting on any of them — see release_dir's own comment for why.
_release_marker() {  # <dir> <file> <repo> <branch> <file_sha> <entry>
  local dir="$1" f="$2" e_repo="$3" e_branch="$4" file_sha="$5" entry="$6"
  local get_err get_rc action e_ts escalated_at ts_epoch age_days new_entry payload

  e_ts="$(jq -r '.ts // empty' <<<"$entry" 2>/dev/null)"
  escalated_at="$(jq -r '.escalated_at // empty' <<<"$entry" 2>/dev/null)"

  if "$GH" api -X DELETE "repos/$e_repo/git/refs/heads/$e_branch" >/dev/null 2>&1; then
    action="released"
  else
    # The same confirmation `_techdebt_release_ref` made before agent-ops#874
    # retired it along with the rest of that filing path
    # (lib/tech-debt-file.sh):
    # a DELETE can fail because the branch is already gone — released by a
    # peer node's own concurrent retry, or deleted by hand, since a marker is
    # only ever cleared once, never
    # renewed. Only a confirmed 404 counts as "nothing left to retry"; any
    # other answer, including the confirmation call itself failing, leaves
    # the marker standing for the next pass.
    get_err="$("$GH" api "repos/$e_repo/git/ref/heads/$e_branch" 2>&1 >/dev/null)"
    get_rc=$?
    if (( get_rc == 0 )) || [[ "$get_err" != *"HTTP 404"* ]]; then
      # Already escalated (a prior pass wrote escalated_at back onto this
      # marker): keep retrying the delete above every pass — cheap, and it
      # is what lets a belated fix on the target-repo side self-heal on the
      # very next pass, via the ordinary released/absent path below — but
      # say nothing further. The one-time reservation-release-stuck event
      # already told a human; repeating it, or falling back to `warning`,
      # is exactly the identical-every-cycle noise this exists to stop.
      if [[ -n "$escalated_at" ]]; then
        return 0
      fi
      # Not yet escalated: past reservation_release_stuck_after_days since
      # this marker's own first-seen `ts`, escalate once instead of warning
      # — a distinct action a human (or the dashboard) can act on, rather
      # than a `warning` indistinguishable from every other pass's. An
      # unparseable or missing `ts`, or stuck_after_days disabled (0), falls
      # through to the ordinary warning unchanged.
      if (( stuck_after_days > 0 )) && [[ -n "$e_ts" ]] \
         && ts_epoch="$(date -u -d "$e_ts" +%s 2>/dev/null)"; then
        age_days=$(( (now_epoch - ts_epoch) / 86400 ))
        if (( age_days >= stuck_after_days )); then
          new_entry="$(jq -c --arg esc "$(date -u -d "@$now_epoch" +%Y-%m-%dT%H:%M:%SZ)" \
            '. + {escalated_at: $esc}' <<<"$entry" 2>/dev/null)"
          payload="$(printf '%s' "$new_entry" | base64 -w0)"
          if "$GH" api -X PUT "repos/$state_repo/contents/reservation-releases/$dir/$f" \
               -f "message=reservation release stuck: $e_branch" -f "content=$payload" \
               -f "sha=$file_sha" >/dev/null 2>&1; then
            stuck "$e_repo" "$e_branch" \
              "delete failing since $e_ts (${age_days}d) — escalated once, marker left in place"
            return 0
          fi
          # Could not persist escalated_at: fall through to the ordinary
          # warning rather than claim an escalation that did not stick —
          # the next pass gets another chance to persist it.
        fi
      fi
      warn "$e_repo" "$e_branch" "delete failed again — marker left in place"
      return 0
    fi
    action="absent"
  fi

  if "$GH" api -X DELETE "repos/$state_repo/contents/reservation-releases/$dir/$f" \
       -f "message=reservation release settled: $e_branch" -f "sha=$file_sha" \
       >/dev/null 2>&1; then
    jq -nc --arg r "$e_repo" --arg b "$e_branch" --arg a "$action" '{action: $a, repo: $r, branch: $b}'
  else
    warn "$e_repo" "$e_branch" \
      "branch $action but its marker could not be cleared — will report it again next pass"
  fi
}

# One repo directory's markers: fetch and classify every one under DIR
# before acting on any of them, then act in two ordered passes —
# TECHDEBT_RECORD_BRANCH_PREFIX-branch markers first, everything else
# after — the record-before-reservation ordering this file's own header
# comment explains.
release_dir() {  # <dir>
  local dir="$1" files f resp file_sha entry entry_compact e_repo e_branch item
  local record_first=() others=()

  files="$("$GH" api "repos/$state_repo/contents/reservation-releases/$dir" \
    --jq '[.[] | select(.type == "file") | .name] | .[]' 2>/dev/null)" || return 0

  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    resp="$("$GH" api "repos/$state_repo/contents/reservation-releases/$dir/$f" 2>/dev/null)" || continue
    file_sha="$(jq -r '.sha // empty' <<<"$resp" 2>/dev/null)"
    entry="$(jq -r '.content // empty' <<<"$resp" 2>/dev/null | tr -d '\n' | base64 -d 2>/dev/null)"
    [[ -n "$file_sha" && -n "$entry" ]] || continue

    e_repo="$(jq -r '.repo // empty' <<<"$entry" 2>/dev/null)"
    e_branch="$(jq -r '.branch // empty' <<<"$entry" 2>/dev/null)"
    if [[ -z "$e_repo" || -z "$e_branch" ]]; then
      warn "" "reservation-releases/$dir/$f" "malformed marker — leaving it in place"
      continue
    fi

    # Compacted to a single line (jq -c) before it rides through the
    # tab-delimited tuple below — record_first/others are read back with
    # `read -r`, which is line-based, and the pretty-printed marker this
    # was decoded from may itself contain literal newlines.
    entry_compact="$(jq -c '.' <<<"$entry" 2>/dev/null)"

    if [[ "$e_branch" == "${TECHDEBT_RECORD_BRANCH_PREFIX}"* ]]; then
      record_first+=("$f"$'\t'"$e_repo"$'\t'"$e_branch"$'\t'"$file_sha"$'\t'"$entry_compact")
    else
      others+=("$f"$'\t'"$e_repo"$'\t'"$e_branch"$'\t'"$file_sha"$'\t'"$entry_compact")
    fi
  done <<<"$files"

  for item in "${record_first[@]:-}"; do
    [[ -n "$item" ]] || continue
    IFS=$'\t' read -r f e_repo e_branch file_sha entry <<<"$item"
    _release_marker "$dir" "$f" "$e_repo" "$e_branch" "$file_sha" "$entry"
  done
  for item in "${others[@]:-}"; do
    [[ -n "$item" ]] || continue
    IFS=$'\t' read -r f e_repo e_branch file_sha entry <<<"$item"
    _release_marker "$dir" "$f" "$e_repo" "$e_branch" "$file_sha" "$entry"
  done
}

dirs="$("$GH" api "repos/$state_repo/contents/reservation-releases" \
  --jq '[.[] | select(.type == "dir") | .name] | .[]' 2>/dev/null)" || exit 0

while IFS= read -r dir; do
  [[ -n "$dir" ]] || continue
  release_dir "$dir"
done <<<"$dirs"

exit 0
