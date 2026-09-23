#!/usr/bin/env bash
#
# scripts/sweep-legacy-refinement-assignees.sh — undo requirement 38b's old
# bookkeeping mechanism wherever it is still standing (agent-ops#639).
#
# Before agent-ops#639, a Co-Ordinator-recorded (or Refiner-declined, or
# Implementer-escaped) refinement block on an issue got both a label
# (`needs_refinement_label`) *and* an assignment to `enabler_assignee` — the
# assignment was meant to put the block on the human's own Assigned-to-me
# dashboard, but nothing distinguished that bookkeeping assignment from a
# genuine escalation (requirement 36a) or a human's own claim, so a removal
# that failed left an issue silently, permanently assigned. 21 such
# assignments needed clearing by hand on 2026-08-21 alone. Requirement 38b now
# projects `blocked`/`blocked:needs-refinement` labels instead and never
# assigns anything — but every block the old mechanism already recorded still
# carries `needs_refinement_assignee` on its own, already-written
# `attempt-failed` event (nothing rewrites history), so this script is what
# clears the backlog that left behind and keeps clearing it if a repository
# this pipeline has not walked in a while turns out to still have one.
#
# For REPO, reads the shared log (LOG_FILE, or stdin if it is "-" or omitted —
# the same convention `lib/cycle-state.sh`'s own `blocked_items` uses) and,
# for every still-open `needs-refinement`-kind block against that repo whose
# event carries `needs_refinement_assignee`:
#   - removes that assignment from the issue (`refinement_assignee_remove`) —
#     a no-op, not a failure, if it is already gone;
#   - applies `blocked:needs-refinement` to the same issue
#     (`refinement_label_add`, unconditionally — no human reaches for that
#     compound name on their own) and `blocked` (`refinement_label_project`,
#     read-before-write — see below) — the pair requirement 38b would have
#     applied instead, had this block been recorded after agent-ops#639 — a
#     no-op if either is already there.
#
# Every step is best-effort and idempotent: safe to run more than once,
# against the same repository or a fresh one, from a terminal or a cron job.
# The matching set can only ever shrink — a block recorded after agent-ops#639
# never carries `needs_refinement_assignee` in the first place
# (`record_needs_refinement_block` never sets it) — so a repeat run against an
# already-swept repository finds nothing and does nothing.
#
# This script does not touch the log itself: `needs_refinement_assignee`
# stays on the historical event forever, and that is what the release path
# reads it as. For the reason label that reading is enough on its own —
# `refinement_blocked_label_targets` (lib/refinement.sh) treats a block
# carrying `needs_refinement_assignee` and neither `blocked_label` nor
# `blocked_reason_label` as carrying `blocked:needs-refinement`, so that
# label comes off again when the block clears, exactly as a freshly recorded
# block's does — safe because the name is fixed and no human ever applies it
# themselves, so this script can only ever be the one that did.
#
# The generic `blocked` label does not get the unconditional-add treatment,
# and that is deliberate (agent-ops#651). `blocked` *is* a name a human
# reaches for on their own (`lib/labels.sh`'s own catalogue documents it as
# their hand-applied control), so this script projects it through
# `refinement_label_project` instead of an unconditional add — a pre-existing
# `blocked` is left exactly as found, the same read-before-write guard the
# fresh path (`record_needs_refinement_block`) uses.
#
# Which of `added`/`present` actually happened is recorded two ways, neither
# of which rewrites the block's own historical event (nothing rewrites
# history): when the caller passes OWN-LOG-FILE (below), an `added` result —
# for `blocked` and, unconditionally, for the reason label — is logged there
# as an `own-label-action add` (`label_own_action_fields`,
# `lib/label-marker.sh`), exactly the record the fresh path's own cycle log
# gets for free. Without OWN-LOG-FILE, this run has nowhere to write that
# record, so `added` and `present` are indistinguishable to every later
# reader: a legacy block's `blocked_label` field on its own `attempt-failed`
# event can never be filled either way, and `refinement_blocked_label_targets`
# never treats a legacy block's generic `blocked` as this pipeline's to
# remove — over-held rather than guessed at, the same trade-off
# `refinement_label_project` already makes for an unreadable label list. Both
# branches share one guarantee: nothing here ever lets a later block-clearing
# remove a `blocked` a human applied for their own reasons on an issue that
# also happens to carry a still-open pre-agent-ops#639 block — the exact
# defect `refinement_label_project` exists to prevent.
#
# **What each path releases for a legacy-swept issue**, stated plainly.
# `refinement_blocked_label_targets` offers the *reason* label up when the
# block clears — a legacy block's `needs_refinement_assignee`, with neither
# blocked-label field set, is enough to name it — regardless of OWN-LOG-FILE.
# If that reason-label removal silently fails, `refinement_blocked_label_stale`
# (requirement 38b's log-keyed reconciliation sweep, agent-ops#651) retries
# it, but only when this run's own `add` reached OWN-LOG-FILE: that function
# offers up only a label whose logged history says `add`, so a run with no
# OWN-LOG-FILE leaves a failed reason-label removal unretried, the same as the
# generic `blocked` below.
#
# The generic `blocked` label reaches `refinement_blocked_label_stale` the
# same way, once OWN-LOG-FILE has recorded its `add`: the moment the block
# clears — the reason label released, successfully or not — `blocked`'s own
# add-with-no-later-remove history makes it eligible for retry there too, and
# `lib/candidate-gather.sh`'s unconditional per-cycle sweep removes it within
# one cycle of the block clearing (TD-PPagop-26082608). Without OWN-LOG-FILE,
# `blocked` has no such history anywhere, and two narrower mechanisms are all
# that can still reach it: requirement 38b's *live* reconciliation
# (agent-ops#816, TD-PPagop-26082602) — `refinement_blocked_label_orphaned`
# needs no `own-label-action` history, only a live GitHub read, but only while
# the issue still carries the reason label live (it is what puts the issue in
# front of that read at all) — and, once the reason label has itself come
# off, nothing: a legacy-swept issue left carrying a bare `blocked` with no
# OWN-LOG-FILE history and no live reason label alongside it stays invisible
# to both, and `scripts/gather-issues.sh`'s own `blocked`-label filter goes on
# excluding that issue for as long as the label stands. Passing OWN-LOG-FILE
# on every run is what closes that residue for good.
#
# **Projecting onto a block LOG_FILE does not yet know has cleared**
# (agent-ops#994, TD-PPagop-26082602). `blocked_items` already excludes an
# item the moment LOG_FILE itself carries a later `unblocked` event for it —
# that half is a plain read, and no timestamp ordering in the file matters,
# only the events' own `ts` fields — so this script can only ever act on
# stale data by being handed a LOG_FILE that is itself stale: a union that
# has not yet absorbed a peer's `unblocked` write. That is exactly what
# happened to issue #602 in the 2026-08-21 migration run: its block cleared
# at 07:52:09, and the sweep, fed a union that had not caught up, still
# projected the pair onto it at 12:45. PEERS_DIR, when given, closes that gap
# the same way requirement 38b's own live reconciliation does
# (`fleet_logs_healthy`, lib/fleet.sh): refuse the whole run rather than act
# on a union that is empty or sits behind a stale peers-fetch marker, since a
# projection onto a block LOG_FILE has not yet caught up to clearing must not
# guess. This is a precondition, not a cure — a union that is merely a little
# behind, inside the fetch-cron's own interval, still reads healthy and can
# still miss a very recent clear — but it is exactly the guard already
# trusted elsewhere in this pipeline for the identical question, and it is
# what would have caught the #602 run: a migration launched moments after a
# fetch failure, or against a peers directory that had gone quiet, refuses
# instead of mis-projecting.
#
# Usage: sweep-legacy-refinement-assignees.sh <owner/repo> [log-file] [peers-dir] [fetch-minutes] [own-log-file]
#
# PEERS_DIR is optional and defaults to unset, which skips the health gate
# entirely (the pre-agent-ops#994 behaviour, and what every existing caller —
# this script's own tests included — still gets without change). Passing it
# only makes sense alongside a real LOG_FILE path (not "-"/stdin, which
# `fleet_logs_healthy` cannot stat), and should always be the freshest
# available fleet union — the caller's responsibility, the same as it always
# was. FETCH_MINUTES defaults to `fleet_logs_healthy`'s own default (7
# minutes, `schedule.state_sync_fetch_minutes`'s default) when PEERS_DIR is
# given without it.
#
# OWN-LOG-FILE is optional and defaults to unset, which skips the
# `own-label-action` logging entirely — the pre-agent-ops#999 behaviour, and
# what every caller that omits it still gets without change. When given, it
# must be this node's own persistent log (`state_dir/log.jsonl`, never
# LOG_FILE itself: LOG_FILE is read-only state, often a synthesized fleet
# union rather than a file this node can usefully append to and have a peer
# ever see) — the file `state-sync.sh` publishes to the fleet, so a
# reconciliation keyed on this run's own `own-label-action add` (requirement
# 38b's log-keyed sweep, agent-ops#651) reaches every peer on its own next
# state-sync, not only this node.
#
# Prints one line per issue actually touched, `<repo>#<number>: <what>`, to
# stdout; failures (a `gh` call that did not take) go to stderr and do not
# stop the sweep — the next run, or a human, gets another chance at whichever
# issue it was.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/cycle-state.sh
. "$SCRIPT_DIR/lib/cycle-state.sh"
# shellcheck source=lib/void-guard.sh
. "$SCRIPT_DIR/lib/void-guard.sh"
# shellcheck source=lib/refinement.sh
. "$SCRIPT_DIR/lib/refinement.sh"
# shellcheck source=lib/fleet.sh
. "$SCRIPT_DIR/lib/fleet.sh"
# shellcheck source=lib/log-event.sh
. "$SCRIPT_DIR/lib/log-event.sh"
# shellcheck source=lib/label-marker.sh
. "$SCRIPT_DIR/lib/label-marker.sh"

repo="${1:-}"
log_file="${2:--}"
peers_dir="${3:-}"
fetch_minutes="${4:-7}"
own_log_file="${5:-}"
node_name="${NODE_NAME:-$(hostname 2>/dev/null || printf 'unknown')}"
node_name="${node_name//[^A-Za-z0-9._-]/-}"
if [[ -z "$repo" ]]; then
  echo "usage: sweep-legacy-refinement-assignees.sh <owner/repo> [log-file] [peers-dir] [fetch-minutes] [own-log-file]" >&2
  exit 64
fi

# sweep_log_own_add REPO NUMBER LABEL
# Record this run's own `add` in OWN_LOG_FILE, when the caller gave one — the
# provenance a fresh block's own cycle gets for free (`record_needs_refinement_block`
# logs the same event, to the cycle's own log) and this script, run outside any
# cycle, has never had anywhere to write until now (agent-ops#999,
# TD-PPagop-26082608). Silently a no-op with no OWN_LOG_FILE, preserving every
# existing caller's behaviour unchanged.
sweep_log_own_add() {
  local repo="$1" number="$2" label="$3"
  [[ -n "$own_log_file" ]] || return 0
  log_event_append "$own_log_file" cycle "" "$node_name" "own-label-action" \
    "$(label_own_action_fields "$repo" "$number" "$label" "add")"
}

if [[ -n "$peers_dir" && "$log_file" != "-" ]]; then
  if ! fleet_logs_healthy "" "$peers_dir" "$log_file" "$fetch_minutes"; then
    echo "sweep-legacy-refinement-assignees: $repo: fleet log union at $log_file is degraded (empty, or peers directory $peers_dir stale) — refusing to reconcile against a view that may be missing an unblock event; retry once state-sync catches up" >&2
    exit 1
  fi
fi

blocked_json="$(blocked_items "$log_file")"

legacy_json="$(jq -c --arg repo "$repo" --arg kind "$REFINEMENT_BLOCK_KIND" '
  [ .[]?
    | select((.kind // "") == $kind)
    | select((.repo // "") == $repo)
    | select((.needs_refinement_assignee // "") != "")
    | select(((.item // "") | tostring) | test("^[0-9]+$")) ]
  | unique_by(.item)' <<<"$blocked_json" 2>/dev/null || printf '[]')"

n="$(jq 'length' <<<"$legacy_json" 2>/dev/null || echo 0)"
if [[ "$n" == "0" ]]; then
  echo "sweep-legacy-refinement-assignees: $repo: nothing to reconcile" >&2
  exit 0
fi

while IFS=$'\t' read -r number assignee; do
  [[ -n "$number" ]] || continue
  if refinement_assignee_remove "$repo" "$number" "$assignee"; then
    printf '%s#%s: removed legacy assignment to %s\n' "$repo" "$number" "$assignee"
  else
    echo "sweep-legacy-refinement-assignees: $repo#$number: could not remove the legacy $assignee assignment" >&2
  fi
  # `blocked` is a human's own, hand-applied control (`lib/labels.sh`'s own
  # catalogue), so this reads before it writes — `refinement_label_project`,
  # the same guard the fresh path (`record_needs_refinement_block`) uses —
  # rather than an unconditional `refinement_label_add`: a pre-existing
  # `blocked` is left exactly as found, and only a genuine `added` result is
  # logged (`sweep_log_own_add`, above) — this read is what tells the two
  # apart, stopping both a needless re-add and a false `own-label-action add`
  # for a label this run never actually applied.
  case "$(refinement_label_project "$repo" "$number" "$REFINEMENT_BLOCKED_LABEL")" in
    added)
      printf '%s#%s: applied %s\n' "$repo" "$number" "$REFINEMENT_BLOCKED_LABEL"
      sweep_log_own_add "$repo" "$number" "$REFINEMENT_BLOCKED_LABEL"
      ;;
    present)
      printf '%s#%s: %s already present — left as is\n' "$repo" "$number" "$REFINEMENT_BLOCKED_LABEL"
      ;;
    unrecorded)
      echo "sweep-legacy-refinement-assignees: $repo#$number: could not read its labels — $REFINEMENT_BLOCKED_LABEL was applied best-effort" >&2
      ;;
    *)
      echo "sweep-legacy-refinement-assignees: $repo#$number: could not apply the $REFINEMENT_BLOCKED_LABEL label" >&2
      ;;
  esac
  reason_label="$(refinement_blocked_reason_label "$REFINEMENT_BLOCK_KIND")"
  if [[ -n "$reason_label" ]]; then
    if refinement_label_add "$repo" "$number" "$reason_label"; then
      printf '%s#%s: applied %s\n' "$repo" "$number" "$reason_label"
      sweep_log_own_add "$repo" "$number" "$reason_label"
    else
      echo "sweep-legacy-refinement-assignees: $repo#$number: could not apply the $reason_label label" >&2
    fi
  fi
done < <(jq -r '.[] | [(.item // ""), (.needs_refinement_assignee // "")] | @tsv' <<<"$legacy_json" 2>/dev/null)
