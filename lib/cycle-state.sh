#!/usr/bin/env bash
#
# lib/cycle-state.sh — how a cycle reports that an item cannot proceed, and
# reads back which items a Co-Ordinator must skip and which the Enabler may
# re-examine.
#
# Sourced by both agent-cycle.sh and scripts/publish-dashboard.sh so the
# semantics of requirements 34, 34c and 35a have exactly one definition — what
# the dashboard reports is then, by construction, what the Co-Ordinator is told
# — and can be regression-tested directly (test/cycle-state.test.sh,
# test/enabler-eligibility.test.sh).
#
# Two states, deliberately distinct (requirement 34c):
#
#   blocked — the work is real but something is in the way *for now* (a red
#             check, an unmerged dependency, a decision nobody has taken). The
#             Co-Ordinator is expected to re-check it and clear it (`unblocked`)
#             once the impediment is demonstrably gone.
#   void    — there is no work: the work order's premise is false, almost always
#             because the item is already done on default_branch. Nothing is in
#             the way, so there is nothing that can "become unblocked" — and the
#             evidence that would tempt an agent to clear it (the work *is*
#             done) is precisely the reason it must stay shut.
#
# Collapsing the two is not a hypothetical. It shipped: an already-done review
# recommendation was recorded as `blocked`, and the next Co-Ordinator, following
# its standing instruction to clear blockers that have gone away, saw the work
# was done, concluded nothing blocked it, and logged `unblocked` — freeing the
# item to be selected and rediscovered forever. Only a human (`unvoided`, hand-
# appended) may clear a void; no agent may.
#
# On top of those two states sits one *derived set* (requirement 35a): the
# blocked items the Enabler may re-examine. It is not a third state — no event
# sets it and none clears it — but a question asked of the whole log at once:
# which blocked, non-void items have sat long enough, or changed enough, that
# one expensive re-examination is worth buying. It belongs here for the reason
# the other two do (requirement 34a): the Script decides an engagement from it
# and the dashboard reports what came of one, and a rule that decides when to
# spend money would drift, in a second copy, in the direction of spending it.
#
# And one *carry-forward* (requirement 3h): the refinements. When the Enabler
# specifies an under-specified item that has no thread to write into, the spec
# it produced lives only in the log, and `refinements_map` is what puts it back
# in front of the Co-Ordinator that will next select the item. Same log, same
# keying, same tolerance of a torn line.

# read_pr_url_breadcrumb CLONE_DIR
# Print the PR URL the Implementer left under .git/ the moment it opened its
# draft PR, or nothing if it never got that far.
#
# The fallback for when a stage exits without ever producing a final message
# (so there's nothing to grep or parse): a stranded attempt can still be found
# and flagged instead of going silent.
#
# Not the last fallback, and not a reliable one: writing this file is a step in
# the Implementer's own procedure, so a stage that skipped its final message
# may equally have skipped this — and on 2026-08-03 three did. What requirement
# 9 falls back to when this comes up empty is `pr_url_for_branch`
# (lib/handoff.sh), which asks GitHub about the branch the *Script* pushed and
# so needs nothing from the stage that failed.
#
# The file is the stage's, written in a workspace the stage can rewrite at
# will (requirement 45e), so it is read through `stage_breadcrumb_pr_url`:
# never through a link, and nothing but a pull-request URL comes back.
#
# Always succeeds. The callers are `[[ -z "$url" ]] && url="$(read_pr_url_breadcrumb …)"`,
# whose status is this function's, so returning non-zero here aborts the whole
# cycle under `set -e` — before the failure it was about to report is logged.
# shellcheck source=lib/stage-boundary.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/stage-boundary.sh"
read_pr_url_breadcrumb() {
  stage_breadcrumb_pr_url "$1/.git/agent-ops-pr-url"
}

# item_event_fields STAGE DETAIL REPO ITEM [EXTRA_JSON]
# Print the log fields common to the events that pin a state on one item
# (attempt-failed, item-void). REPO/ITEM are omitted when empty — a stage that
# fails before the Co-Ordinator has selected anything (or because it failed to
# select) has no item to blame, and must not be recorded as if it pinned a state
# on one.
item_event_fields() {
  local stage="$1" detail="$2" repo="$3" item="$4" extra="${5:-{\}}"
  jq -nc --arg s "$stage" --arg d "$detail" --arg r "$repo" --arg i "$item" --argjson x "$extra" \
    '{stage: $s, detail: $d}
     + (if $r == "" then {} else {repo: $r} end)
     + (if $i == "" then {} else {item: $i} end)
     + $x'
}

# _log_fold SRC PROGRAM EVENTS [JQ_OPTION...]
# Run the jq PROGRAM over the records of SRC (a log file, or stdin for "-")
# whose `event` is one of the words in EVENTS — the reader's declaration,
# written once beside its program — gathered into one array in log order, and
# print what PROGRAM prints. One process (agent-ops#1649): each line is parsed
# with `fromjson? // empty`, so a torn or spliced line is dropped rather than
# fatal, and only the declared events are ever gathered, so the process holds
# them rather than the whole parsed log, which is otherwise a linear function
# of a log that is never rotated. A parsed value that is not an object is
# gathered too, so it still aborts PROGRAM exactly as it did when every line
# was slurped. JQ_OPTIONs (`--arg …`) are passed to jq ahead of the program.
# `test/union-stream.test.sh` fails when a program reads an event type its
# declaration lacks.
_log_fold() {
  local src="$1" prog="$2" events="$3"
  shift 3
  local -a files=()
  [[ "$src" == "-" ]] || files=("$src")
  # shellcheck disable=SC2016,SC2086  # jq's own $e/$ARGS; EVENTS is a word list by design.
  jq -nRc "$@" '
    def wanted: .event as $e | any($ARGS.positional[]; . == $e);
    [ inputs | fromjson? // empty | select(type != "object" or wanted) ]
    | ('"$prog"')' "${files[@]}" --args $events
}

# The rule behind both extracts: an item is in a state iff its most recent
# $set event has no later $clear event. `blocked` and `void` are the same shape
# over different event pairs, so they share one program rather than two copies
# that agree until the day it matters (the drift TD26071401 fixed for limit
# detection, and requirement 34a makes general).
#
# Events carrying no item are dropped rather than grouped under a shared empty
# key: they pin nothing, and collapsing them together yields one meaningless
# entry that describes no item at all.
#
# State is keyed on repo+item, because an item id is only unique within its
# repo — both repos carry a `dependabot-alert-1` and number tech debt from the
# same date — so keying on the id alone would let one repo starve the other's
# identically-named work.
#
# A clearing event that names no repo clears that item in *every* repo. That is
# deliberate, not laxity: `unblocked` is reported by the Co-Ordinator as a bare
# item id (requirement 18) and both clears may be appended by hand by a human
# (requirements 34, 34c), so neither source has a repo to match on. Over-
# clearing is the safe direction — the item merely becomes a candidate again,
# and re-pins on the next attempt if the reason is still there.
# $aliases (issue #2064, extended to this program by #2359) must already be
# bound by the caller — `--argjson aliases …` at the top of whichever jq
# invocation splices this program in — mapping a repo slug this pipeline used
# to be configured under to the slug it is configured under now
# (`config_repo_slug_aliases`). `canon_repo` resolves both the $set event's own
# repo (for grouping) and each candidate $clear event's repo (for matching)
# through it before either comparison, the same read-time-only way
# `work_gone_clearances` (lib/work-gone.sh) already resolves a block's repo:
# without it, a repository rename splits one item's identity across two
# slugs, and an `unblocked`/`item-void` logged under the current slug can
# never clear an `attempt-failed`/`item-void` recorded under the slug the
# repository had before the rename.
# shellcheck disable=SC2016  # $set/$clear/$events/$e/$aliases are jq's, not the shell's.
LATEST_UNRESOLVED_JQ='
  def canon_repo($r): ($aliases[$r] // $r);
  [ .[] | select((.event == $set or .event == $clear)
                 and (.item // "") != "") ] as $events
  | ($events | map(select(.event == $clear))) as $clears
  | $events
  | map(select(.event == $set))
  | group_by(canon_repo(.repo // "") + "|" + .item)
  | map(sort_by(.ts) | last)
  | map(. as $e
        | select($clears
                 | any(.item == $e.item
                       and ((.repo // "") == "" or canon_repo(.repo // "") == canon_repo($e.repo // ""))
                       and .ts > $e.ts)
                 | not))
'

# _latest_unresolved SET_EVENT CLEAR_EVENT [LOG_FILE] [ALIASES_JSON]
# ALIASES_JSON (issue #2064, extended by #2359) is `config_repo_slug_aliases`'s
# own map, resolved through `LATEST_UNRESOLVED_JQ`'s `canon_repo` before the
# set/clear match runs; defaults to `{}`, under which every repo resolves to
# itself and behaviour is unchanged. An argument that is not a JSON object is
# treated the same way — read-time resolution must never fail the fold.
#
# Always succeeds, printing [] for a missing, empty, or unreadable log: a caller
# running under `set -e` must not be killed by an unparseable log line, and a
# log that can't be read pins nothing. Malformed lines are skipped rather than
# fatal, so one truncated append can't strand every item.
_latest_unresolved() {
  local set_event="$1" clear_event="$2" src="${3:--}" aliases="${4:-{\}}" out=""
  jq -e 'type == "object"' <<<"$aliases" >/dev/null 2>&1 || aliases='{}'
  if [[ "$src" == "-" || -s "$src" ]]; then
    out="$(_log_fold "$src" "$LATEST_UNRESOLVED_JQ" "$set_event $clear_event" \
      --arg set "$set_event" --arg clear "$clear_event" --argjson aliases "$aliases" 2>/dev/null || true)"
  fi
  [[ -n "$out" ]] || out='[]'
  printf '%s' "$out"
}

# Requirement 18a's marker: a `recheck-clean` event records that a
# Co-Ordinator re-read a blocked GitHub issue's thread after its `updated_at`
# moved past the block's own `ts`, and judged that the blocker still holds. It
# clears nothing — only `unblocked` does that — so it is folded into the
# block's own record as `recheck_clean_ts` rather than treated as another
# member of the set/clear pair `_latest_unresolved` computes. The event is
# repo-scoped (`{item, repo}`, requirement 33), unlike `unblocked`, because
# the two fail in opposite directions: an `unblocked` that over-clears only
# makes an item a candidate again, where a `recheck_clean_ts` folded into an
# unrelated repo's identically-numbered item *raises* that item's comparison
# threshold, so it suppresses a mandated re-read rather than adding one — and
# issue numbers collide across repos far more readily than register ids do.
# Scoping the match makes that fail safe structurally: a marker can only ever
# suppress the one issue its Co-Ordinator actually read.
#
# A repo-less event (older logs, or a report the Script accepted as a bare
# id) still folds — into every same-numbered blocked item. That fallback
# leans on the emitting cycle rather than the match: requirement 18a obliged
# that Co-Ordinator to re-read every blocked issue of that id whose thread
# had moved, so its marker stands for each of them, provided it complied.
# The residual case either way — a blocked issue no marker covers — is
# caught by requirement 35a, whose clocks are measured from the block's own
# `ts` and which this marker deliberately never touches.
# The event types BLOCKED_ITEMS_JQ reads — the set/clear pair and the marker —
# its declaration (`_log_fold`). $aliases must already be bound by the caller
# (`--argjson aliases …`), same contract as `LATEST_UNRESOLVED_JQ`'s own:
# beyond the nested `latest_unresolved` call (which resolves through it
# already), the recheck-clean join below matches a marker's own `repo`
# against the block's directly — never through `latest_unresolved` — so
# `canon_repo` is applied there too (agent-ops#2388): without it, a
# `recheck-clean` logged under a repo's current slug would never fold into a
# block recorded under a slug in that repo's `previous_slugs`, leaving
# requirement 18a's re-read-suppression marker unable to cover a renamed
# block.
BLOCKED_ITEMS_EVENTS="attempt-failed unblocked recheck-clean"
# shellcheck disable=SC2016  # jq's $b/$rechecks/$aliases, not the shell's.
BLOCKED_ITEMS_JQ='
  def canon_repo($r): ($aliases[$r] // $r);
  def latest_unresolved($set; $clear): '"$LATEST_UNRESOLVED_JQ"';
  . as $all
  | ($all | latest_unresolved("attempt-failed"; "unblocked")) as $blocked
  | ([ $all[] | select(.event == "recheck-clean" and (.item // "") != "") ]) as $rechecks
  | $blocked
  | map(. as $b
        | ($rechecks
           | map(select(.item == $b.item
                        and ((.repo // "") == "" or canon_repo(.repo // "") == canon_repo($b.repo // ""))))
           | map(.ts // "")
           | sort | last) as $rc_ts
        | if $rc_ts == null then $b else $b + {recheck_clean_ts: $rc_ts} end)
'

# blocked_items [LOG_FILE] [ALIASES_JSON]
# Print, as a JSON array, the most recent attempt-failed event for every item
# with no later unblocked event — the items a Co-Ordinator must skip *for now*,
# and may clear itself once the impediment has demonstrably gone. Each entry
# additionally carries `recheck_clean_ts` when a `recheck-clean` marker exists
# for it (requirement 18a) — the newest such ts, for the Co-Ordinator to
# compare a blocked GitHub issue's `updated_at` against alongside the block's
# own `ts`. Reads LOG_FILE, or stdin if it is omitted or "-".
#
# ALIASES_JSON (issue #2064, extended by #2359) is threaded into
# `BLOCKED_ITEMS_JQ`'s own `latest_unresolved`, so an `unblocked` logged under
# a repo's current slug clears an `attempt-failed` recorded under a slug in
# that repo's `previous_slugs`, and vice versa. Defaults to `{}` (every repo
# resolves to itself); an argument that is not a JSON object is treated the
# same way.
blocked_items() {
  local src="${1:--}" aliases="${2:-{\}}" out=""
  jq -e 'type == "object"' <<<"$aliases" >/dev/null 2>&1 || aliases='{}'
  if [[ "$src" == "-" || -s "$src" ]]; then
    out="$(_log_fold "$src" "$BLOCKED_ITEMS_JQ" "$BLOCKED_ITEMS_EVENTS" \
      --argjson aliases "$aliases" 2>/dev/null || true)"
  fi
  [[ -n "$out" ]] || out='[]'
  printf '%s' "$out"
}

# The set/clear pair void_items folds, in that order — its declaration
# (`_log_fold`).
VOID_ITEMS_EVENTS="item-void unvoided"

# void_items [LOG_FILE] [ALIASES_JSON]
# Print, as a JSON array, the most recent item-void event for every item with no
# later unvoided event — the items that no longer describe real work, which a
# Co-Ordinator must skip and must never clear. Reads LOG_FILE, or stdin if it is
# omitted or "-".
#
# ALIASES_JSON (issue #2064, extended by #2359) is threaded straight into
# `_latest_unresolved`, so an `unvoided` logged under a repo's current slug
# clears an `item-void` recorded under a slug in that repo's `previous_slugs`,
# and vice versa. Defaults to `{}` (every repo resolves to itself).
#
# A void is scoped to the item id, so it cannot outstay its welcome: next week's
# review files its recommendations under fresh refs (review-<new-date>-R-NN),
# which no void covers. Voiding R-02 today cannot silence a genuine regression a
# later review finds.
void_items() {
  local log="${1:--}" aliases="${2:-{\}}"
  # shellcheck disable=SC2086  # VOID_ITEMS_EVENTS is a word list by design.
  set -- "$log" $VOID_ITEMS_EVENTS
  _latest_unresolved "$2" "$3" "$1" "$aliases"
}

# void_object_closed_items [LOG_FILE]
# Print, as a JSON array of {repo, item}, every void item requirement 34k's
# act-on-void sweep has already handled — closed the GitHub object for, or
# found it already closed. Reads LOG_FILE, or stdin if it is omitted or "-".
#
# This is the sweep's own idempotency: closing a void'd issue or pull request
# is a one-shot action, deliberately never repeated even if a human reopens
# the object without applying the `unvoid_label` (requirement 34f) — the
# sanctioned way to say a void was wrong. (Requirement 34n qualifies that
# since: once the void has *retired* — actioned and `void_retire_after_days`
# old — a plain reopen does put the item back in front of the pipeline, as a
# fresh candidate rather than a cleared void; 34f records the ratified
# position.) Without this record the sweep would
# re-close whatever it had just reopened, every cycle, forever: exactly the
# "unvoided" bug 34f itself warns against, aimed at a human's plain re-open
# instead of at the label.
#
# `void-object-closed` is a fact, not a state with a clearing event like
# `item-void`/`unvoided` — once an item has been actioned, it stays actioned,
# so the latest occurrence is enough; no _latest_unresolved pairing is needed.
void_object_closed_items() {
  local src="${1:--}" out=""
  local jq_prog='
    [ .[] | select(.event == "void-object-closed"
                   and (.repo // "") != "" and (.item // "") != "")
      | {repo, item} ] | unique'
  if [[ "$src" == "-" ]]; then
    out="$(jq -c -R 'fromjson? // empty' 2>/dev/null \
      | jq -sc "$jq_prog" 2>/dev/null || true)"
  elif [[ -s "$src" ]]; then
    out="$(jq -c -R 'fromjson? // empty' "$src" 2>/dev/null \
      | jq -sc "$jq_prog" 2>/dev/null || true)"
  fi
  [[ -n "$out" ]] || out='[]'
  printf '%s' "$out"
}

# decision_vetoes_processed_items [LOG_FILE]
# Print, as a JSON array of {repo, item}, every `pw::decision` decision-log
# issue #937's veto sweep has already handled — logged
# `decision-vetoed` for. `item` here is the *log issue's own number*
# (stringified), not the original work item's ref: one work item's decision
# could in principle be re-decided and re-vetoed later under a fresh log
# issue, and keying on the log issue number, exactly like
# `void_object_closed_items` keys on the void'd object above, is what lets
# `scripts/sweep-decision-vetoes.sh` skip only the veto instance it already
# processed rather than every veto this item will ever have.
#
# This is the sweep's own idempotency (agent-ops#937's "once, not every
# cycle"): without it, an open (reopened) `pw::decision` issue would be
# re-detected, re-logged and re-acted on — a fresh needs-refinement block, a
# fresh comment, a fresh draft flip — on every cycle for as long as a human
# leaves it open before commenting their own decision and closing it again.
# `decision-vetoed` is a fact, not a state with a clearing event: once a veto
# has been recorded for a given log issue, it stays recorded, so the latest
# occurrence (there should only ever be one) is enough.
decision_vetoes_processed_items() {
  local src="${1:--}" out=""
  local jq_prog='
    [ .[] | select(.event == "decision-vetoed"
                   and (.repo // "") != "" and (.issue_number // "") != "")
      | {repo, item: (.issue_number | tostring)} ] | unique'
  if [[ "$src" == "-" ]]; then
    out="$(jq -c -R 'fromjson? // empty' 2>/dev/null \
      | jq -sc "$jq_prog" 2>/dev/null || true)"
  elif [[ -s "$src" ]]; then
    out="$(jq -c -R 'fromjson? // empty' "$src" 2>/dev/null \
      | jq -sc "$jq_prog" 2>/dev/null || true)"
  fi
  [[ -n "$out" ]] || out='[]'
  printf '%s' "$out"
}

# pending_decision_acts [LOG_FILE]
# Print, as a JSON array, every `decide-with-veto` decision whose *act* is
# still owed (requirement 36f): a `decision-taken` event carrying an `act`
# object, an `act_after` instant and its own `pw::decision` log issue, for
# which no later `decision-acted` (the act performed, or cancelled) and no
# `decision-vetoed` (the owner reopened the log issue) has retired it. Reads
# LOG_FILE, or stdin if it is omitted or "-".
#
# Keyed on the log issue's own number, exactly as
# `decision_vetoes_processed_items` above is keyed and for the same reason:
# one item can carry more than one decision over time, and only the log issue
# tells two of them apart. A decision with no `issue_number` never appears
# here at all, which is not a gap but the invariant — `lib/enabler.sh` refuses
# to record a pending act whose log issue could not be filed, because an act
# nobody could veto is the one thing this rung must never take, so a pending
# act without a lever cannot exist to be found.
#
# Every field the act needs to be performed and logged travels on the event
# itself: no second read of GitHub, and no dependency on the cycle that took
# the decision still being around.
pending_decision_acts() {
  local src="${1:--}" out=""
  # shellcheck disable=SC2016  # jq's $retired/$d, not the shell's.
  local jq_prog='
    ([ .[] | select(.event == "decision-acted" and (.issue_number // null) != null)
       | (.issue_number | tostring) ]
     + [ .[] | select(.event == "decision-vetoed" and (.issue_number // null) != null)
       | (.issue_number | tostring) ]) as $retired
    | [ .[] | select(.event == "decision-taken"
                     and ((.act // null) | type) == "object"
                     and (.act_after // "") != ""
                     and (.issue_number // null) != null
                     and (.repo // "") != "" and (.item // "") != "")
        | . as $d
        | select(($retired | index($d.issue_number | tostring)) == null)
        | {repo, item, issue_number, issue_url: (.issue_url // ""),
           act, act_after, decision: (.decision // ""), rationale: (.rationale // ""),
           ts: (.ts // "")} ]
    | unique_by(.issue_number) | sort_by(.ts)'
  if [[ "$src" == "-" ]]; then
    out="$(jq -c -R 'fromjson? // empty' 2>/dev/null \
      | jq -sc "$jq_prog" 2>/dev/null || true)"
  elif [[ -s "$src" ]]; then
    out="$(jq -c -R 'fromjson? // empty' "$src" 2>/dev/null \
      | jq -sc "$jq_prog" 2>/dev/null || true)"
  fi
  [[ -n "$out" ]] || out='[]'
  printf '%s' "$out"
}

# void_retired_items [LOG_FILE]
# Print, as a JSON array of {repo, item, ts}, the most recent `void-retired`
# event for every {repo, item} pair one was ever recorded against (requirement
# 34n). Reads LOG_FILE, or stdin if it is omitted or "-".
#
# `void-retired` is a fact, not a state, for the same reason and in the same
# shape as `void-object-closed` above: retirement is decided once, on evidence
# (actioned and old — requirement 34n), and recording the decision is what
# stops the next cycle asking GitHub the same settled question about the same
# id forever. The one wrinkle a plain unique-pairs read would miss is *time*:
# an item can be voided afresh after its old verdict retired (the object
# reopened and re-gathered, then found already-done again), and the new
# `item-void` must not be masked by the old retirement — so the latest `ts`
# per pair is kept, for `subtract_retired_voids` to order against.
#
# Repoless or itemless events are dropped, as everywhere else in this file: a
# retirement is only ever recorded from an actioned pair, and an actioned pair
# always names both.
void_retired_items() {
  local src="${1:--}" out=""
  local jq_prog='
    [ .[] | select(.event == "void-retired"
                   and (.repo // "") != "" and (.item // "") != "") ]
    | group_by((.repo // "") + "|" + .item)
    | map(sort_by(.ts) | last | {repo, item, ts})'
  if [[ "$src" == "-" ]]; then
    out="$(jq -c -R 'fromjson? // empty' 2>/dev/null \
      | jq -sc "$jq_prog" 2>/dev/null || true)"
  elif [[ -s "$src" ]]; then
    out="$(jq -c -R 'fromjson? // empty' "$src" 2>/dev/null \
      | jq -sc "$jq_prog" 2>/dev/null || true)"
  fi
  [[ -n "$out" ]] || out='[]'
  printf '%s' "$out"
}

# first_seen_known_items [LOG_FILE]
# Print, as a JSON array of {repo, item}, every item a `first-seen` event has
# ever been logged for (requirement 33, TD-PPagop-26081405, issue #248
# acceptance 4). Reads LOG_FILE, or stdin if it is omitted or "-".
#
# `first-seen` is a fact, not a state like `item-void`/`unvoided`: once an
# item has been logged, it stays logged, so the existence of any occurrence —
# from this node or a peer's — is enough to answer "has the fleet already
# seen this item", the once-ever guarantee `emit_first_seen` (agent-cycle.sh)
# reads this back to keep. No _latest_unresolved pairing, no clearing event.
first_seen_known_items() {
  local src="${1:--}" out=""
  local jq_prog='
    [ .[] | select(.event == "first-seen"
                   and (.repo // "") != "" and (.item // "") != "")
      | {repo, item} ] | unique'
  if [[ "$src" == "-" ]]; then
    out="$(jq -c -R 'fromjson? // empty' 2>/dev/null \
      | jq -sc "$jq_prog" 2>/dev/null || true)"
  elif [[ -s "$src" ]]; then
    out="$(jq -c -R 'fromjson? // empty' "$src" 2>/dev/null \
      | jq -sc "$jq_prog" 2>/dev/null || true)"
  fi
  [[ -n "$out" ]] || out='[]'
  printf '%s' "$out"
}

# draft_obsolete_flags' program and its declaration (`_log_fold`).
DRAFT_OBSOLETE_FLAGS_EVENTS="draft-obsolete-flagged"
DRAFT_OBSOLETE_FLAGS_JQ='
  [ .[] | select(.event == "draft-obsolete-flagged"
                 and (.repo // "") != "" and (.item // "") != "")
    | {repo, item, pr: (.pr // null), evidence: (.evidence // null),
       cycle: (.cycle // ""), node: (.node // ""), ts: (.ts // "")} ]'

# draft_obsolete_flags [LOG_FILE]
# Print, as a JSON array, every `draft-obsolete-flagged` event ever logged —
# `{repo, item, pr, evidence, cycle, node, ts}`, written by the Script
# (agent-cycle.sh) when an Enabler verdict flags a draft pull request as
# unwanted (design doc §5.5, issue #413, WI-10). Reads LOG_FILE, or stdin if
# it is omitted or "-".
#
# A fact, not a state, the same reason `first_seen_known_items` above keeps no
# clearing event: flagging a draft is not itself a void (that engagement
# writes no `item-void`), so nothing ever retracts a flag once logged — it
# either goes on to corroborate a later, independent void
# (`lib/void-guard.sh`'s `void_draft_obsolete_flag_reason`, which does its own
# repo/item/age/cycle filtering) or it simply never does. Every occurrence,
# from this node or a peer's, is handed to the guard unfiltered by repo or
# item — the guard is what decides which ones are relevant to the void in
# front of it, the same division of labour `blocked_items`/`open_blocked_
# items` already keep.
draft_obsolete_flags() {
  local src="${1:--}" out=""
  if [[ "$src" == "-" || -s "$src" ]]; then
    out="$(_log_fold "$src" "$DRAFT_OBSOLETE_FLAGS_JQ" "$DRAFT_OBSOLETE_FLAGS_EVENTS" 2>/dev/null || true)"
  fi
  [[ -n "$out" ]] || out='[]'
  printf '%s' "$out"
}

# latest_issues_excluded [LOG_FILE]
# Print, as a JSON object keyed by repo slug, the `excluded` array carried by
# the most recent `issues-excluded` event logged for that repo (requirement
# 33, review decision on agent-ops#452 concern 1) — the "previous state" the
# on-change logging in agent-cycle.sh compares each cycle's freshly gathered
# set against. Reads LOG_FILE, or stdin if it is omitted or "-", the same
# read-off-the-union-log convention first_seen_known_items (above) uses,
# with the same tolerated once-per-cycle-per-node race and first-wins
# convention for readers.
#
# A repo with no `issues-excluded` event yet is simply absent from the
# result: the caller reads a missing key as an empty previous set, per the
# review decision's "no previous event ⇒ previous set was empty" rule — the
# same reading a first occurrence gets from first_seen_known_items.
latest_issues_excluded() {
  local src="${1:--}" out=""
  local jq_prog='
    [ .[] | select(.event == "issues-excluded" and (.repo // "") != "") ]
    | group_by(.repo)
    | map({key: .[0].repo, value: (sort_by(.ts) | last | .excluded // [])})
    | from_entries'
  if [[ "$src" == "-" ]]; then
    out="$(jq -c -R 'fromjson? // empty' 2>/dev/null \
      | jq -sc "$jq_prog" 2>/dev/null || true)"
  elif [[ -s "$src" ]]; then
    out="$(jq -c -R 'fromjson? // empty' "$src" 2>/dev/null \
      | jq -sc "$jq_prog" 2>/dev/null || true)"
  fi
  [[ -n "$out" ]] || out='{}'
  printf '%s' "$out"
}

# subtract_retired_voids VOID_JSON RETIRED_JSON [ALIASES_JSON]
# Print VOID_JSON (the shape `void_items` returns) with every entry whose
# {repo, item} pair a RETIRED_JSON record (`void_retired_items`) covers
# dropped — "covers" meaning the retirement's `ts` is strictly later than the
# void entry's own, the same ordering rule every clearing event here obeys
# (`LATEST_UNRESOLVED_JQ`), so a fresh `item-void` recorded *after* the pair
# retired re-enters the extract on its own terms.
#
# This is requirement 34n's memory, applied before anything reads the extract:
# the bound it gives holds even on a cycle whose register read fails, because
# it needs nothing but the log — and it is what keeps the per-cycle register
# read proportional to the unretired residue rather than to every void ever
# filed. Both inputs are unbounded, so both travel on stdin, never in argv
# (requirement 4g). Fails safe the same way `retire_void_items` does: a jq
# failure on either input returns VOID_JSON verbatim — never subtracting is
# one oversized extract, wrongly subtracting is a verdict silently dropped.
#
# ALIASES_JSON (issue #2064, extended by #2359, extended by #2393) maps a repo
# slug this pipeline used to be configured under to the slug it is configured
# under now (`config_repo_slug_aliases`), defaulting to `{}`. Applied to the
# `repo` half of the match on both sides — the void entry and each RETIRED_JSON
# candidate compared against it — so a void entry recorded under a pre-rename
# slug still matches a retirement recorded under the current one. Travels as a
# third document on stdin, alongside the two unbounded arrays above, never
# `--argjson` — the same requirement-4g delivery.
subtract_retired_voids() {
  local void_json="${1:-[]}" retired_json="${2:-[]}" aliases_json="${3:-{\}}" out=""
  jq -e 'type == "object"' <<<"$aliases_json" >/dev/null 2>&1 || aliases_json='{}'
  # shellcheck disable=SC2016  # jq's $void/$retired/$aliases/$e, not the shell's.
  out="$(jq -c -n '
    input as $void | input as $retired | input as $aliases
    | def canon_repo($r): ($aliases[$r] // $r);
      $void
      | map(. as $e
            | select($retired
                     | any(canon_repo(.repo // "") == canon_repo($e.repo // "")
                           and (.item // "") == ($e.item // "")
                           and ((.ts // "") > ($e.ts // "")))
                     | not))
  ' <<<"$void_json"$'\n'"$retired_json"$'\n'"$aliases_json" 2>/dev/null || true)"
  [[ -n "$out" ]] || out="$void_json"
  printf '%s' "$out"
}

# retire_void_items VOID_JSON ACTIONED_JSON RETIRE_AFTER_DAYS [NOW_EPOCH] [ALIASES_JSON]
# Print VOID_JSON (the shape `void_items` returns) with every entry that is
# both **actioned** — its `{repo, item}` pair present in ACTIONED_JSON — and
# **old** — its `ts` at least RETIRE_AFTER_DAYS old — dropped (requirement
# 34n). Everything else, including every entry `_latest_unresolved` groups
# under the same key, passes through unchanged.
#
# This does not change what is void (requirement 34c is untouched, and every
# internal reader that subtracts void from blocked — `open_blocked_items`,
# `enabler_eligible_items`, `refinements_map`, each its own copy of
# `LATEST_UNRESOLVED_JQ` rather than a call to `void_items` — recomputes the
# *raw*, unretired set straight off the log, so a retired item never
# resurfaces as blocked). It only shrinks the *extract* a caller goes on to
# hand to the Co-Ordinator, the no-op fingerprint, or the Refiner's candidate
# filter — the value requirement 4g moved onto stdin after it crossed
# `MAX_ARG_STRLEN` at 122 entries on 2026-08-12, and which keeps growing by
# one entry for every item ever voided if nothing ever retires. ACTIONED_JSON
# is the caller's business, not this function's: `void_object_closed_items`
# (requirement 34k, an issue or pull request GitHub confirms closed) and a
# register row read `resolved` or `not-debt` (requirement 34i's own "gone"
# statuses, checked for the void set the same way that requirement already
# checks it for the blocked one) are both `{repo, item}` pairs, so the caller
# simply concatenates them.
#
# A void naming no repo — the hand-appended form requirement 34c allows —
# never matches an ACTIONED_JSON entry (every actioned pair names a repo) and
# so is never retired; a human's own line is left for a human to retract.
#
# Fails safe in every direction an unattended cycle can hit: RETIRE_AFTER_DAYS
# 0 (or not a non-negative integer) disables retirement outright and returns
# VOID_JSON verbatim, unparseable input (either JSON argument, or a `ts` that
# does not parse as ISO-8601) counts as "not old" rather than erroring the
# entry away, and a jq failure of any kind returns VOID_JSON unchanged. Never
# retiring is always the safe direction here — the failure mode is one more
# cycle carrying an entry that was ready to go, not a void quietly reopened.
#
# This function only *decides*; the caller records each entry it dropped as a
# `void-retired` event, and it is the recorded set (`void_retired_items`,
# subtracted by `subtract_retired_voids` above) that keeps an id from being
# re-evidenced and re-decided every cycle thereafter.
#
# ALIASES_JSON (issue #2064, extended by #2359, extended by #2393) maps a repo
# slug this pipeline used to be configured under to the slug it is configured
# under now (`config_repo_slug_aliases`), defaulting to `{}`. Applied to the
# `repo` half of the key on both sides of the match — each ACTIONED_JSON pair
# and the void entry itself — so a void entry recorded under a pre-rename slug
# still matches an actioned pair the caller built from a live, current-slug
# read; without it, such an entry is never actioned and so never retires,
# growing requirement 34n's extract forever. Travels as a third document on
# stdin, alongside the two unbounded arrays above, never `--argjson` — the
# same requirement-4g delivery.
retire_void_items() {
  local void_json="${1:-[]}" actioned_json="${2:-[]}" retire_days="${3:-0}" now="${4:-}" aliases_json="${5:-{\}}"
  local out=""
  if ! [[ "$retire_days" =~ ^[0-9]+$ ]] || (( retire_days == 0 )); then
    printf '%s' "$void_json"
    return 0
  fi
  [[ "$now" =~ ^[0-9]+$ ]] || now="$(date +%s)"
  jq -e 'type == "object"' <<<"$aliases_json" >/dev/null 2>&1 || aliases_json='{}'
  # Both arrays on stdin, never in argv (requirement 4g): VOID_JSON is the
  # unbounded extract itself, and ACTIONED_JSON grows with it — an --argjson
  # here is the same delivery that failed at MAX_ARG_STRLEN on 2026-08-12.
  # ALIASES_JSON travels the same way, as a third document, for the same
  # reason.
  # shellcheck disable=SC2016  # jq's $done/$e/$key/$t/$old/$aliases, not the shell's.
  out="$(jq -c -n --argjson days "$retire_days" --argjson now "$now" '
    input as $void | input as $actioned | input as $aliases
    | def canon_repo($r): ($aliases[$r] // $r);
      ($actioned | map(canon_repo(.repo // "") + "|" + (.item // "")) | unique) as $done
      | $void
      | map(. as $e
            | (canon_repo($e.repo // "") + "|" + ($e.item // "")) as $key
            | ((try ($e.ts | fromdateiso8601) catch null)) as $t
            | (($done | index($key)) != null) as $actioned_hit
            | ($t != null and ($now - $t) >= ($days * 86400)) as $old
            | select(($actioned_hit and $old) | not))
  ' <<<"$void_json"$'\n'"$actioned_json"$'\n'"$aliases_json" 2>/dev/null || true)"
  [[ -n "$out" ]] || out="$void_json"
  printf '%s' "$out"
}

# The two states meet in one place, and the answer there is always the same:
# **void wins** (requirement 34h). An item can hold both marks at once, and
# routinely does — `item-void` is a state of its own and clears no block, so the
# Enabler's `void` verdict, which is its ordinary way of retiring work that
# turned out to be already done, leaves the last `attempt-failed` standing for
# ever. Nothing re-examines such an item and nothing selects it: it is finished
# with, and every consumer that *acts* on the blocked set already subtracts the
# void one before it does.
#
# This is that subtraction, written once (requirement 34a). It had been written
# twice — inline in the Enabler's eligibility rule, and not at all in the
# Publisher — which is exactly the drift 34a warns about, and it surfaced where
# 34a says it would: the dashboard's Blocked items table, the page you would go
# to to find this class of bug, listed fifteen items the pipeline had already
# closed the book on, one of them for a fortnight.
#
# The match is requirement 34's, not a stricter one: a void naming no repo
# covers the item in every repo, for the reason 34c gives — both an `item-void`
# and its `unvoided` may be hand-appended by a human, who has no repo to hand.
# $aliases must already be bound by the caller (`--argjson aliases …`), same
# contract as `LATEST_UNRESOLVED_JQ`'s own: beyond the nested
# `latest_unresolved`/`BLOCKED_ITEMS_JQ` calls (which resolve through it
# already), the void-wins subtraction below matches a void event's own `repo`
# against the block's directly — never through `latest_unresolved` — so
# `canon_repo` is applied there too (agent-ops#2388), the same way
# `REFINEMENTS_MAP_JQ`'s own void drop already does: without it, an
# `item-void` logged under a repo's current slug would never clear an
# `attempt-failed` recorded under a slug in that repo's `previous_slugs`
# (or the mirror), leaving a cross-rename-voided item handed to the Enabler
# and listed on the dashboard's blocked table forever.
# The event types OPEN_BLOCKED_JQ reads — the void pair and BLOCKED_ITEMS_JQ's —
# its declaration (`_log_fold`).
OPEN_BLOCKED_EVENTS="$VOID_ITEMS_EVENTS $BLOCKED_ITEMS_EVENTS"
# shellcheck disable=SC2016  # jq's $all/$void/$b/$aliases, not the shell's.
OPEN_BLOCKED_JQ='
  def canon_repo($r): ($aliases[$r] // $r);
  def latest_unresolved($set; $clear): '"$LATEST_UNRESOLVED_JQ"';
  . as $all
  | ($all | latest_unresolved("item-void"; "unvoided")) as $void
  | ($all | ('"$BLOCKED_ITEMS_JQ"'))
  | map(. as $b
        | select($void
                 | any(.item == $b.item
                       and ((.repo // "") == "" or canon_repo(.repo // "") == canon_repo($b.repo // "")))
                 | not))
'

# open_blocked_items [LOG_FILE] [ALIASES_JSON]
# Print, as a JSON array, the blocked items that are not void — the items still
# waiting on something, in the sense a human reading a dashboard or an Enabler
# deciding where to spend means it. Entries are `blocked_items`' entries
# unchanged, `recheck_clean_ts` and all. Reads LOG_FILE, or stdin if it is
# omitted or "-".
#
# ALIASES_JSON (issue #2064, extended by #2359) is threaded into
# `OPEN_BLOCKED_JQ`'s own nested `latest_unresolved`/`BLOCKED_ITEMS_JQ` calls,
# on the same terms `blocked_items`/`void_items` document. Defaults to `{}`
# (every repo resolves to itself).
#
# `blocked_items` remains the raw rule of requirement 34 and is what the
# Co-Ordinator's own skip list is built from: it is handed the void list beside
# the blocked one and requirement 34c is emphatic that it must be able to see
# both, so nothing is subtracted there.
open_blocked_items() {
  local src="${1:--}" aliases="${2:-{\}}" out=""
  jq -e 'type == "object"' <<<"$aliases" >/dev/null 2>&1 || aliases='{}'
  if [[ "$src" == "-" || -s "$src" ]]; then
    out="$(_log_fold "$src" "$OPEN_BLOCKED_JQ" "$OPEN_BLOCKED_EVENTS" \
      --argjson aliases "$aliases" 2>/dev/null || true)"
  fi
  [[ -n "$out" ]] || out='[]'
  printf '%s' "$out"
}

# The refinements a later Co-Ordinator must be given (requirement 3h), as one jq
# program over the fleet's whole event stream: the latest `item-refined` event
# per repo+item, for items that are not void.
#
# Keyed repo → item → payload rather than by item alone, for requirement 34's
# reason: an item id is only unique within its repo, and a refinement written
# for one repo's TD26071805 is not a specification of the other's.
#
# Void items are dropped because a refined specification of work that does not
# exist is worse than none: it would arrive in the Co-Ordinator's input arguing,
# in detail and in the pipeline's own voice, for an item requirement 34c says
# must never be selected again.
#
# A refinement is also dropped once a *fresher* needs-refinement block stands
# against the same item — the Implementer's escape hatch (requirement 9f) or a
# further Refiner decline (requirement 39d) saying the specification it names
# was tried and found wanting. Comparing timestamps rather than existence alone
# is what lets the item be refined again afterwards: a later `item-refined`
# clears an older block exactly the way `unblocked` already does, and this rule
# must not re-shadow that recovery.
#
# A phantom `item-refined` event — `comment_url` present but naming no comment
# (`$re`, bound to `REFINEMENT_COMMENT_URL_RE` by the caller), the shape logged
# before the recording seam validated it (TD-PPagop-26082819) — is skipped
# exactly as `ENABLER_ELIGIBLE_JQ`'s `refined_before` derivation already skips
# it, and the latest event that does pass the shape check is used instead.
# Without this, the two seams disagree about the same event: this map said
# #874 was refined — so the Co-Ordinator kept proposing it and
# `refiner_candidate_items` kept excluding it — while requirement 17f's
# traceability gate could never resolve the recorded URL to a comment, so
# every claim of it faulted `untraceable` and the fleet stood down on an item
# nothing on the log's own terms could ever repair (the 2026-09-04 outage).
# Skipping it here restores one answer everywhere: the item reads unrefined,
# the Refiner owes it a genuine specification, and the entry leaves the no-op
# fingerprint's refinements projection so the change wakes the fleet on its
# own. The skip is silent by design — the recording seam now refuses the
# shape, so the set of phantom events is closed, and `enabler_eligible_items`
# already warns for any of them still standing behind an open block.
# $aliases must already be bound by the caller (`--argjson aliases …`), same
# contract as `LATEST_UNRESOLVED_JQ`'s own. Beyond the two nested
# `latest_unresolved` calls (which resolve through it already), the void/
# blocked exclusions below match a refinement event's own `repo` against
# `$void`/`$blocked`'s directly — never through `latest_unresolved` — so
# `canon_repo` is applied there too: without it, a refinement logged under a
# repo's current slug would not be recognized as refining (or voiding, or
# superseding) a block recorded under a slug in that repo's `previous_slugs`,
# issue #2359's second symptom (`refined_before` reading null across a
# rename, disarming requirement 36b's one-refinement-per-item thrash guard).
# shellcheck disable=SC2016  # jq's $set/$clear/$r/$re/$aliases, not the shell's.
REFINEMENTS_MAP_JQ='
  def canon_repo($r): ($aliases[$r] // $r);
  def latest_unresolved($set; $clear): '"$LATEST_UNRESOLVED_JQ"';
  . as $all
  | ($all | latest_unresolved("item-void"; "unvoided")) as $void
  | ($all | latest_unresolved("attempt-failed"; "unblocked")) as $blocked
  | [ $all[]
      | select(.event == "item-refined"
               and (.item // "") != "" and (.repo // "") != "")
      | select(((.comment_url // "") == "") or ((.comment_url // "") | test($re)))
      | . as $r
      | select($void
               | any((.item // "") == ($r.item // "")
                     and ((.repo // "") == "" or canon_repo(.repo // "") == canon_repo($r.repo // "")))
               | not)
      | select($blocked
               | any((.kind // "") == "needs-refinement"
                     and (.item // "") == ($r.item // "")
                     and ((.repo // "") == "" or canon_repo(.repo // "") == canon_repo($r.repo // ""))
                     and (((.ts // "") > ($r.ts // ""))))
               | not) ]
  | sort_by(.ts)
  | reduce .[] as $r ({};
      .[$r.repo][($r.item | tostring)] =
        ({ts: ($r.ts // ""), cycle: ($r.cycle // "")}
         + (if ($r.spec // "") == "" then {} else {spec: $r.spec} end)
         + (if ($r.comment_url // "") == "" then {} else {comment_url: $r.comment_url} end)))
'

# refinements_map [LOG_FILE] [ALIASES_JSON]
# Print, as a JSON object keyed repo → item, the latest refinement recorded for
# every item that has one and is not void. Reads LOG_FILE, or stdin if it is
# omitted or "-".
#
# ALIASES_JSON (issue #2064, extended by #2359) is `config_repo_slug_aliases`'s
# own map, threaded into `REFINEMENTS_MAP_JQ`'s `canon_repo`. Defaults to `{}`
# (every repo resolves to itself); an argument that is not a JSON object is
# treated the same way.
#
# Always succeeds, printing {} for a missing, empty or unreadable log, for the
# same reason `_latest_unresolved` prints []: this is computed inside a cycle
# running under `set -e`, and a log it cannot parse must cost the Co-Ordinator
# one input, never the cycle.
refinements_map() {
  local src="${1:--}" aliases="${2:-{\}}" out=""
  # The same literal-copy fallback `enabler_eligible_items` keeps, for the
  # same reason: a caller testing this file in isolation may not have sourced
  # lib/refinement.sh, and the two must still agree — production always has
  # the real one (agent-cycle.sh sources every lib/*.sh file, requirement 4a).
  local comment_url_re="${REFINEMENT_COMMENT_URL_RE:-(#issuecomment-[0-9]+|/issues/comments/[0-9]+)$}"
  jq -e 'type == "object"' <<<"$aliases" >/dev/null 2>&1 || aliases='{}'
  if [[ "$src" == "-" ]]; then
    out="$(jq -c -R 'fromjson? // empty' 2>/dev/null \
      | jq -sc --arg re "$comment_url_re" --argjson aliases "$aliases" "$REFINEMENTS_MAP_JQ" 2>/dev/null || true)"
  elif [[ -s "$src" ]]; then
    out="$(jq -c -R 'fromjson? // empty' "$src" 2>/dev/null \
      | jq -sc --arg re "$comment_url_re" --argjson aliases "$aliases" "$REFINEMENTS_MAP_JQ" 2>/dev/null || true)"
  fi
  [[ -n "$out" ]] || out='{}'
  printf '%s' "$out"
}

# The tactical decisions a later Refiner engagement must be given (agent-ops
# #936, requirement 36d), beside — never merged into — `REFINEMENTS_MAP_JQ`
# above: a `decision-taken` event settles a policy question, not a
# specification, so an item can carry a decision with no refinement at all
# (the ordinary shape for a `decide-tactical` pass over an item that was never
# refined), and the Refiner still has to turn that decision into an actual
# specification the way it would from a human's own answer on a closed
# escalation. Latest `decision-taken` event per repo+item, dropped once the
# item is void (a decision about work that does not exist is worse than none,
# the same reasoning `REFINEMENTS_MAP_JQ` gives its own void drop) or once a
# refinement genuinely carries the decision forward: an `item-refined` whose
# own `ts` postdates the decision *and* that is not itself marked `unchanged:
# true`. That marker (agent-ops#1049) is what makes the distinction: the
# settle/decide path in lib/enabler.sh re-records `item-refined` whenever a
# prior refinement existed, but that re-record always carries `refined_before`
# verbatim and always postdates the `decision-taken` it sits beside — it is
# never the Refiner turning the decision into an actual specification, only
# the Enabler preserving `refinements_map`'s own entry (requirement 34e). A
# marked re-record therefore does *not* mean the decision's job is done, and
# is excluded here; only an unmarked `item-refined` — the Refiner's own
# fresh-spec write (lib/refinement.sh) — supersedes a decision. A refined
# non-issue item with a decision still pending stays a candidate despite
# `refinements_map` showing it refined (`refiner_candidate_items`,
# lib/refinement.sh) for exactly this reason. A phantom `item-refined` —
# `comment_url` present but naming no comment (TD-PPagop-26082819) — never
# supersedes either, on `REFINEMENTS_MAP_JQ`'s own terms just above: no
# specification was actually written, so the decision it would shadow is
# still owed its spec.
#
# A `decision-vetoed` event postdating the decision drops it too
# (agent-ops#937, agent-ops#1198): reopening the log issue withdraws the
# decision it logged, and a Refiner engagement the veto's own re-block leads
# to must not be handed the very decision the owner just vetoed as though it
# still stood. `decision-vetoed`'s own `item` names the *original* work item
# (never the log issue's own number — that is `decision_vetoes_processed_items`'
# own remapping, not this event's own field), so it matches `$d` the same
# `same_item`-shaped way `$refined` does above.
#
# $aliases must already be bound by the caller (`--argjson aliases …`), the
# same contract `LATEST_UNRESOLVED_JQ` and `REFINEMENTS_MAP_JQ` share — the
# nested `latest_unresolved` call below requires it in scope regardless, and
# the void/refined/vetoed matches resolve through the same `canon_repo` for
# the same reason `REFINEMENTS_MAP_JQ`'s own matches do (agent-ops#2359).
# shellcheck disable=SC2016  # jq's $set/$clear/$r/$re/$aliases, not the shell's.
DECISIONS_MAP_JQ='
  def canon_repo($r): ($aliases[$r] // $r);
  def latest_unresolved($set; $clear): '"$LATEST_UNRESOLVED_JQ"';
  . as $all
  | ($all | latest_unresolved("item-void"; "unvoided")) as $void
  | [ $all[] | select(.event == "item-refined" and (.unchanged // false) != true)
             | select(((.comment_url // "") == "") or ((.comment_url // "") | test($re))) ] as $refined
  | [ $all[] | select(.event == "decision-vetoed" and (.item // "") != "") ] as $vetoed
  | [ $all[]
      | select(.event == "decision-taken"
               and (.item // "") != "" and (.repo // "") != "")
      | . as $d
      | select($void
               | any((.item // "") == ($d.item // "")
                     and ((.repo // "") == "" or canon_repo(.repo // "") == canon_repo($d.repo // "")))
               | not)
      | select($refined
               | any((.item // "") == ($d.item // "")
                     and ((.repo // "") == "" or canon_repo(.repo // "") == canon_repo($d.repo // ""))
                     and (((.ts // "") > ($d.ts // ""))))
               | not)
      | select($vetoed
               | any((.item // "") == ($d.item // "")
                     and ((.repo // "") == "" or canon_repo(.repo // "") == canon_repo($d.repo // ""))
                     and (((.ts // "") > ($d.ts // ""))))
               | not) ]
  | sort_by(.ts)
  | reduce .[] as $d ({};
      .[$d.repo][($d.item | tostring)] =
        {ts: ($d.ts // ""), decision: ($d.decision // ""), rationale: ($d.rationale // "")}
        + (if ($d.options_considered // "") == "" then {} else {options_considered: $d.options_considered} end)
        + (if ($d.comment_url // "") == "" then {} else {comment_url: $d.comment_url} end)
        + (if ($d.issue_number // "") == "" then {} else {issue_number: $d.issue_number} end)
        + (if ($d.issue_url // "") == "" then {} else {issue_url: $d.issue_url} end))
'

# decisions_map [LOG_FILE] [ALIASES_JSON]
# Print, as a JSON object keyed repo → item, the latest tactical decision
# recorded for every item that has one, is not void, and has not since been
# carried forward into a refinement. Reads LOG_FILE, or stdin if it is
# omitted or "-". Always succeeds, printing {} on a missing, empty or
# unreadable log, on the same terms `refinements_map` does.
#
# ALIASES_JSON (issue #2064, extended by #2359) is `config_repo_slug_aliases`'
# own map, threaded into `DECISIONS_MAP_JQ`'s `canon_repo`. Defaults to `{}`
# (every repo resolves to itself); an argument that is not a JSON object is
# treated the same way.
decisions_map() {
  local src="${1:--}" aliases="${2:-{\}}" out=""
  # Same fallback as refinements_map above, same reason.
  local comment_url_re="${REFINEMENT_COMMENT_URL_RE:-(#issuecomment-[0-9]+|/issues/comments/[0-9]+)$}"
  jq -e 'type == "object"' <<<"$aliases" >/dev/null 2>&1 || aliases='{}'
  if [[ "$src" == "-" ]]; then
    out="$(jq -c -R 'fromjson? // empty' 2>/dev/null \
      | jq -sc --arg re "$comment_url_re" --argjson aliases "$aliases" "$DECISIONS_MAP_JQ" 2>/dev/null || true)"
  elif [[ -s "$src" ]]; then
    out="$(jq -c -R 'fromjson? // empty' "$src" 2>/dev/null \
      | jq -sc --arg re "$comment_url_re" --argjson aliases "$aliases" "$DECISIONS_MAP_JQ" 2>/dev/null || true)"
  fi
  [[ -n "$out" ]] || out='{}'
  printf '%s' "$out"
}

# The Enabler's eligibility rule (requirement 35a), as one jq program over the
# fleet's whole event stream. It re-uses the extracts above rather than
# re-deriving any of them: the set it computes is a subset of `open_blocked_items`
# — blocked and not void — and a second opinion about which items those are is
# exactly the drift requirement 34a exists to prevent.
#
# An item is eligible iff all of:
#
#   1. it is blocked — call that latest attempt-failed event B — and
#   2. it is not void: an item with no work needs no unblocking, and the
#      blocked∩void shape every `void` verdict creates (requirement 34h) must
#      not be re-examined at Opus prices. Both clauses are `open_blocked_items`;
#   3. no escalation issue for it is still open — the human has been asked and
#      has not answered yet, so there is nothing new to read. When the repo's
#      issue digest is missing (its source state could not be sampled) we
#      cannot tell, and "cannot tell" resolves to ineligible: the cheap
#      mistake is a delayed engagement, not a duplicate issue;
#   4. one of three reasons applies, and the reason travels on the entry so the
#      model knows why it was woken:
#
#      threshold    — nothing has examined it since B, and MIN_COORD_CYCLES
#                     distinct cycles have run a Co-Ordinator (a `stage-end`
#                     for `coordinator` with `exit_code: 0`) since — or
#                     REFINEMENT_MIN_COORD_CYCLES, for a block whose `kind` is
#                     `needs-refinement`. Counting *cycles that actually
#                     selected* rather than wall-clock hours is what makes the
#                     threshold mean "the pipeline has had several honest
#                     chances to clear this itself": a fleet standing down on
#                     a usage limit, or a switch, logs no coordinator
#                     stage-end and so ages nothing.
#      issue-closed — the item's latest escalation is no longer open and no
#                     examination has followed it since it was raised. This
#                     bypasses the threshold deliberately: the human acted, and
#                     the whole protocol promised them that closing the issue
#                     is what re-starts the work (requirement 36a). Ordinarily
#                     that means the escalation was raised after B (the block
#                     it answers is still the current one); but when B is a
#                     `needs-refinement` re-flag whose `refined_before` (the
#                     item's latest `item-refined`) both exists and predates
#                     the escalation, the re-flag disputes the same
#                     specification the escalation was about, so the human's
#                     close answers it too — TD-PPagop-26082901's race, where
#                     a re-flag between the raise and the next Enabler pass
#                     would otherwise strand the close. A re-flag with no
#                     prior refinement is outside this on purpose: the thrash
#                     guard does not bite without one, so `threshold` already
#                     delivers that item its first refinement.
#
#                     "No examination has followed it" tests examination, not
#                     release: an item can leave its block through four other
#                     paths that log no `enabler-examined` —
#                     lib/candidate-gather.sh's `unblocked {by:
#                     "label-removed"}`/`{by: "work-gone"}`/`{by:
#                     "dependency-resolved"}`, and lib/candidate-select.sh's
#                     bare `unblocked` (item only, no repo — the one path
#                     same_item's "empty repo matches any repo" clause exists
#                     for). A close already acted on through one of those
#                     still reads as unconsumed and can grant a fresh
#                     issue-closed engagement on a long-settled close
#                     (TD-PPagop-26082918). Bounded, not a gap: the engagement
#                     it grants logs the enabler-examined that retires the
#                     exemption for good, verifying the closed issue's claim
#                     against reality before releasing anything
#                     (prompts/enabler.md) — one Opus pass per closed
#                     escalation, not a loop. Distinguishing this from a
#                     genuinely stale re-flag needs a key this rule does not
#                     have on its own: the engagement's own enabler-examined
#                     retires the exemption, and a re-escalation from there
#                     records the re-flag's reason key, so agent-ops#936's
#                     shipped per-reason bound (same reason since the last
#                     human touch escalates to a human, plus the
#                     escalation_adjudication_max_passes cap; PR #1049) is
#                     what stops a settled question being re-asked from
#                     there. The one issue-closed grant per human close is
#                     itself uncapped by design (agent-ops#936 §5: "The
#                     issue-closed exemption stays") — exactly the bounded,
#                     disclosed cost the one-Opus-pass-per-closed-escalation
#                     sentence above already states.
#      recheck      — the newest examination of it is older than RECHECK_HOURS
#                     (0 disables). This is the path by which evidence that
#                     arrived after an examination — a diagnosis posted into
#                     the very thread whose absence blocked the item — is
#                     eventually read at all, and the only bound on how long a
#                     permanently-stuck item can sit unexamined.
#
# A re-block after an examination re-enters through `threshold`, because every
# guard above is measured from B: a fresh attempt-failed moves B forward, which
# leaves the old examination behind it and starts the count again — except for
# the `needs-refinement` shape of `issue-closed` just described, which is
# measured from the escalation instead precisely so that re-block does not
# strand an already-closed escalation.
#
# An `enabler-examined` whose outcome is `escalation-failed` is deliberately not
# an examination. The engagement reached a verdict it could not act on, so the
# item is exactly where it was; treating the marker as progress would retire the
# item on the strength of a failed `gh issue create`.
#
# Each entry carries `pr_url` when the blocking event named one (requirement
# 32a). Under that requirement a pull request the Reviewer could not hand off is
# a blocked item like any other, and for a finishing source the item id names a
# register entry rather than the PR — so without this the Enabler would have to
# re-derive from the id the very artefact the block is about. Empty when the
# block had no PR, which is most of them.
#
# Two more fields carry the refinement class (requirements 34e, 36b). `kind` is
# the block's own marker, so an engagement can tell an under-specified item from
# an impeded one and knows which duty it is there to perform; it is `""` for
# every ordinary block, which is what keeps this class invisible to the rest of
# the rule. `refined_before` is the latest `item-refined` for the same repo+item
# — the thrash guard's input, and the record of what the last engagement already
# said, so a second one need not guess at it.
#
# TD-PPagop-26082819: an `item-refined` event whose `comment_url` does not
# actually name a comment — logged before the recording seam
# (`refinement_record_fields`, `lib/refinement.sh`) validated its shape, the
# same phantom shape #818's and #874's events both carried — is skipped here
# rather than trusted, so `$refined` derives to the latest event that really
# is corroborated (or `null`, if none is). `$phantom` is the caller's own
# pre-computed set of such events, over the same `$all` (see
# `enabler_eligible_items`'s own comment on why the check lives there and not
# inline here): every candidate for `$refined` is drawn from the same
# `$all[]` this file already scans, so matching an event against that set —
# rather than re-testing the URL's shape a second time in this jq program —
# keeps `refinement_comment_url_valid` (`lib/refinement.sh`) the one place
# that predicate is evaluated, on the same "one predicate, one rule" terms
# TD-PPagop-26082603 asks for.
#
# The match is on the whole `{repo, item, ts}` triple, never `ts` alone.
# `log_event` (`agent-cycle.sh`) stamps whole-second UTC timestamps and this
# runs over the fleet-wide *union* log, so two `item-refined` events sharing
# a second across different items is ordinary traffic — keying on `ts` alone
# would let one item's phantom suppress another item's genuine refinement,
# silently disarming requirement 36b's thrash guard for an item that really
# was refined and discarding the `spec`/`comment_url` `lib/enabler.sh`'s
# adjudication path reads back out of `refined_before`.
# shellcheck disable=SC2016  # jq's $ vars ($all/$b/$open/$phantom/…), not the shell's.

# $all and $phantom are bound by the caller, via `input as $all`/`input as
# $phantom` (requirement 4g) — never a leading `. as $all` here, since the
# caller runs this body with `jq -n`.
#
# The `issue-closed` branch's own timestamp guard reads `$escalation.ts >=
# $b.ts`, not strictly `>` (agent-ops#937, agent-ops#1198): an ordinary
# escalation is filed cycles after the block it answers, so the two never
# tie, but the decision-veto sweep (`lib/decision-veto.sh`) logs its
# `escalated` registration in the very same pass — and often the very same
# wall-clock second — as the `needs-refinement` block it re-blocks the item
# with, since both describe the same veto discovered in the same cycle.
# `log_event` (`agent-cycle.sh`) stamps whole-second timestamps, so a strict
# `>` would coin-flip that tie and strand the veto's own release the way
# #1198 named. Widening to `>=` costs nothing on the ordinary path — the two
# events there are never this close — and is exactly what makes the veto's
# escalation registration observe the same "closing it releases the item"
# contract an ordinary escalation already gets.
ENABLER_ELIGIBLE_JQ='
  def canon_repo($r): ($aliases[$r] // $r);
  def same_item($e): (.item // "") == ($e.item // "")
                     and ((.repo // "") == "" or canon_repo(.repo // "") == canon_repo($e.repo // ""));
  ($all | ('"$OPEN_BLOCKED_JQ"')) as $blocked
  | [ $blocked[]
      | . as $b
      | ([ $all[]
           | select(.event == "escalated" and same_item($b)
                    and ((.issue_number // "") | tostring | test("^[0-9]+$"))) ]
         | sort_by(.ts)) as $escalations
      | ($escalations | last) as $escalation
      | ([ $all[]
           | select(.event == "enabler-examined" and same_item($b)
                    and (.outcome // "") != "escalation-failed"
                    and .ts > $b.ts) ]
         | sort_by(.ts)) as $examined
      | ([ $all[]
           | select(.event == "enabler-examined" and same_item($b)
                    and (.outcome // "") != "escalation-failed"
                    and $escalation != null and .ts > $escalation.ts) ]
         | sort_by(.ts)) as $examined_since_escalation
      | ([ $all[]
           | select(.event == "item-refined" and same_item($b))
           | . as $e
           | select($phantom
                    | any(.ts == ($e.ts // "")
                          and .repo == ($e.repo // "")
                          and .item == (($e.item // "") | tostring))
                    | not) ]
         | sort_by(.ts) | last) as $refined
      | ([ $all[]
           | select(.event == "stage-end" and (.stage // "") == "coordinator"
                    and (.exit_code // 1) == 0
                    and (.cycle // "") != "" and .ts > $b.ts)
           | .cycle ]
         | unique | length) as $coord_cycles
      | canon_repo($b.repo // "") as $crepo
      | (if $escalation == null then "none"
         elif ($open | has($crepo) | not) then "unknown"
         elif (($open[$crepo] // []) | map(tostring)
               | index($escalation.issue_number | tostring)) != null then "open"
         else "closed"
         end) as $issue_state
      | (if $issue_state == "open" or $issue_state == "unknown" then null
         elif $issue_state == "closed"
              and ($examined_since_escalation | length) == 0
              and ($escalation.ts >= $b.ts
                   or (($b.kind // "") == "needs-refinement"
                       and $refined != null
                       and $refined.ts < $escalation.ts))
           then "issue-closed"
         elif ($examined | length) == 0
           then ((if ($b.kind // "") == "needs-refinement"
                  then $refinement_min_coord else $min_coord end) as $effective_min
                 | if $coord_cycles >= $effective_min then "threshold" else null end)
         else
           ((try (($examined | last).ts | fromdateiso8601) catch 0) as $seen
            | if $recheck_hours > 0 and $seen > 0
                 and ($now - $seen) >= ($recheck_hours * 3600)
              then "recheck" else null end)
         end) as $reason
      | select($reason != null)
      | {repo: ($b.repo // ""), item: $b.item, reason: $reason, blocked_ts: ($b.ts // ""),
         stage: ($b.stage // ""), detail: ($b.detail // ""),
         unblock_condition: ($b.unblock_condition // ""),
         pr_url: ($b.pr_url // ""),
         kind: ($b.kind // ""),
         refined_before: (if $refined == null then null
                          else {ts: ($refined.ts // ""), cycle: ($refined.cycle // ""),
                                comment_url: ($refined.comment_url // ""),
                                spec: ($refined.spec // "")}
                          end),
         escalation: (if $escalation == null then null
                      else {issue_number: ($escalation.issue_number | tostring | tonumber),
                            issue_url: ($escalation.issue_url // ""),
                            ts: ($escalation.ts // "")}
                      end)}
    ]
'

# ENABLER_DEPENDENCY_DEFER_LAPSE_MULTIPLIER / _FALLBACK_HOURS —
# `enabler_defer_open_dependency_items`'s own lapse bound (issue #2492,
# filing bound (a)): past this many hours since a block's own `blocked_ts`,
# the function stops deferring even an item whose thread still names an open
# `Blocked-by:` reference, so a dependency that is itself stuck does not
# suppress the item forever. Wired to RECHECK_HOURS — the multiplier times
# it, when recheck is enabled — rather than a config key of its own: three
# missed recheck windows is the same cadence the `recheck` reason already
# uses as its own re-examination clock, so this bound never outlives the one
# the rest of the rule already runs on. RECHECK_HOURS disabled (0) has no
# cadence to multiply, so the fallback is a flat three days: long enough that
# an ordinary dependency (the concrete instance this was filed from, #2440,
# closed about two hours after #2480 was deferred) resolves comfortably
# inside it, short enough that a dependency that is itself stuck still
# reaches a human.
#
# The two branches are deliberately not the same length, and the multiplied
# one is the longer: at the shipped `enabler_recheck_hours` of 72, three
# missed windows is 216 hours — nine days — against the fallback's flat 72.
# A fleet configured to re-examine less often should wait proportionally
# longer before paying the engagement this suppresses, which is the whole
# point of reading the cadence rather than fixing a span; the fallback is
# what a fleet with no cadence to read falls back to, never a stand-in for
# the multiplied value.
ENABLER_DEPENDENCY_DEFER_LAPSE_MULTIPLIER="${ENABLER_DEPENDENCY_DEFER_LAPSE_MULTIPLIER:-3}"
ENABLER_DEPENDENCY_DEFER_FALLBACK_HOURS="${ENABLER_DEPENDENCY_DEFER_FALLBACK_HOURS:-72}"

# enabler_defer_open_dependency_items OUT_JSON NOW RECHECK_HOURS ALIASES_JSON
# Post-filter OUT_JSON — an `enabler_eligible_items` result, before its own
# `[]` fallback is applied — dropping a `threshold`-reason candidate whose
# `item` is a bare GitHub issue number when its thread still names an open
# `Blocked-by:` reference (issue #2492). `scripts/gather-issues.sh` already
# runs this exact live check (`issue_blocked_by_ref`, lib/issue-prefetch.sh,
# over a thread fetched by `item_live_entry`, lib/candidate-select.sh) before
# ever offering such an item to the Co-Ordinator; without this, an item that
# check is already holding out of the Co-Ordinator's own view still reaches a
# full Enabler engagement once its block's own coordinator-cycle count
# crosses the threshold, paying an Opus pass to re-derive a fact one `gh`
# read already answered (the concrete instance: issue #2480, held by #2440,
# reached the Enabler in cycle 20261017T120900Z-ockham-2-13286 this way).
#
# Scoped to `reason == "threshold"` only — never `recheck`, and never
# `issue-closed`, which stays exempt by construction because this function
# is simply never consulted for it (a human has just acted on the escalation
# issue, and the thread needs re-reading regardless of what a `Blocked-by:`
# line still says). Narrowing to `threshold` keeps the added `gh` cost paid
# only by the candidates this was filed for, not by every eligible item
# (never more than one thread fetch plus one reference-resolution call per
# such candidate).
#
# The deferral lapses past `ENABLER_DEPENDENCY_DEFER_LAPSE_MULTIPLIER` ×
# RECHECK_HOURS hours (or the flat fallback above) since the block's own
# `blocked_ts`: past that age the candidate is returned exactly as it was
# found, open reference or not, so a dependency that is itself stuck still
# reaches the Enabler, and from there a human, the same way any other
# permanently-stuck item already does. Each deferral this function actually
# applies is logged as `enabler-dependency-deferred`, naming the item and the
# reference that held it, so the suppression is auditable on the fleet log
# rather than silent.
#
# Always succeeds, printing OUT_JSON back unchanged on any failure along the
# way — `issue_blocked_by_ref`/`item_live_entry` not being defined at all (a
# harness testing this file without also sourcing
# lib/issue-prefetch.sh/lib/dependency-gate.sh/lib/candidate-select.sh, the
# same fallback `enabler_eligible_items` already takes for `log_event`), a
# failed thread fetch, or malformed input, are all read the same way: this is
# a cost saving, never the correctness gate, the same direction every other
# live-state filter in this file already takes.
#
# One failure inside the check is the exception, and it defers rather than
# engaging: a `gh` read that cannot resolve a *reference's* own state is read
# by `issue_blocked_by_ref` as the reference being still open, which is its
# own documented fail-safe and the right direction for its first caller
# (`scripts/gather-issues.sh`, where the consequence is holding a candidate
# back from work). Here the consequence is the opposite one — an Enabler
# engagement suppressed for the cycle — bounded by the lapse above and by
# the next cycle asking again.
enabler_defer_open_dependency_items() {
  local out="${1:-[]}" now="${2:-}" recheck_hours="${3:-0}" aliases="${4:-{\}}"
  command -v issue_blocked_by_ref >/dev/null 2>&1 || { printf '%s' "$out"; return 0; }
  command -v item_live_entry >/dev/null 2>&1 || { printf '%s' "$out"; return 0; }
  [[ "$now" =~ ^[0-9]+$ ]] || now="$(date -u +%s)"
  jq -e 'type == "array"' <<<"$out" >/dev/null 2>&1 || { printf '%s' "$out"; return 0; }
  jq -e 'type == "object"' <<<"$aliases" >/dev/null 2>&1 || aliases='{}'
  local lapse_hours
  if [[ "$recheck_hours" =~ ^[0-9]+$ ]] && (( recheck_hours > 0 )); then
    lapse_hours=$(( recheck_hours * ENABLER_DEPENDENCY_DEFER_LAPSE_MULTIPLIER ))
  else
    lapse_hours="$ENABLER_DEPENDENCY_DEFER_FALLBACK_HOURS"
  fi
  local candidates
  candidates="$(jq -c '[.[] | select(.reason == "threshold"
                                     and ((.item // "") | tostring | test("^[0-9]+$"))
                                     and (.repo // "") != "")]' \
    <<<"$out" 2>/dev/null || true)"
  [[ -n "$candidates" && "$candidates" != "[]" ]] || { printf '%s' "$out"; return 0; }
  local entry repo item blocked_ts canon_repo blocked_epoch age_hours entry_data thread_text ref_display
  local deferred='[]'
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    repo="$(jq -r '.repo' <<<"$entry" 2>/dev/null || true)"
    item="$(jq -r '.item' <<<"$entry" 2>/dev/null || true)"
    blocked_ts="$(jq -r '.blocked_ts // ""' <<<"$entry" 2>/dev/null || true)"
    [[ -n "$repo" && -n "$item" ]] || continue
    # Tested for emptiness first, not left to `date` to reject: GNU `date -u
    # -d "" +%s` succeeds, answering today's midnight, so a block whose own
    # `ts` is missing would read as a few hours old and be deferred — the
    # opposite of the direction the `else` branch below is here to take.
    blocked_epoch=""
    [[ -n "$blocked_ts" ]] && blocked_epoch="$(date -u -d "$blocked_ts" +%s 2>/dev/null || true)"
    if [[ -n "$blocked_epoch" ]]; then
      age_hours=$(( (now - blocked_epoch) / 3600 ))
    else
      age_hours="$lapse_hours"
    fi
    (( age_hours < lapse_hours )) || continue
    canon_repo="$(jq -nr --argjson a "$aliases" --arg r "$repo" '$a[$r] // $r' 2>/dev/null || true)"
    [[ -n "$canon_repo" ]] || canon_repo="$repo"
    entry_data="$(item_live_entry "$canon_repo" "issues" "$item" 2>/dev/null || true)"
    [[ -n "$entry_data" ]] || continue
    thread_text="$(jq -r '(.body // "") as $b | ((.comments // []) | map(.body // "")) as $c
                           | ([$b] + $c | join("\n"))' <<<"$entry_data" 2>/dev/null || true)"
    [[ -n "$thread_text" ]] || continue
    ref_display="$(issue_blocked_by_ref "$canon_repo" "$thread_text" 2>/dev/null || true)"
    [[ -n "$ref_display" ]] || continue
    command -v log_event >/dev/null 2>&1 && log_event "enabler-dependency-deferred" "$(jq -nc \
      --arg repo "$repo" --arg item "$item" --arg ref "$ref_display" \
      --arg d "enabler-eligibility: deferring threshold candidate $repo#$item — its thread still names an open Blocked-by reference ($ref_display) that scripts/gather-issues.sh's own live check already excludes it on (issue #2492)" \
      '{detail: $d, repo: $repo, item: $item, ref: $ref}')"
    deferred="$(jq -c --arg r "$repo" --arg i "$item" '. + [{repo: $r, item: $i}]' \
      <<<"$deferred" 2>/dev/null || printf '%s' "$deferred")"
  done < <(jq -c '.[]' <<<"$candidates" 2>/dev/null || true)
  [[ "$deferred" != "[]" ]] || { printf '%s' "$out"; return 0; }
  jq -c --argjson deferred "$deferred" '
    ($deferred | map((.repo // "") + "#" + ((.item // "") | tostring))) as $defset
    | [ .[] | select((((.repo // "") + "#" + ((.item // "") | tostring)) as $k | ($defset | index($k)) == null)) ]
    ' <<<"$out" 2>/dev/null || printf '%s' "$out"
}

# enabler_eligible_items [LOG_FILE] [MIN_COORD_CYCLES] [RECHECK_HOURS] [OPEN_ISSUES_JSON] [NOW_EPOCH] [REFINEMENT_MIN_COORD_CYCLES] [ALIASES_JSON]
# Print, as a JSON array, the blocked items the Enabler may examine this cycle
# (requirement 35a), each carrying the `reason` it became eligible. Reads
# LOG_FILE, or stdin if it is omitted or "-".
#
# OPEN_ISSUES_JSON maps a repo slug to its open issue numbers, built from the
# source-state digests of the repos that sampled cleanly; a slug that is absent
# is a repo we could not read, and an escalation there is treated as possibly
# still open.
#
# REFINEMENT_MIN_COORD_CYCLES is the `threshold` reason's cycle count for a
# block whose `kind` is `needs-refinement`, defaulting to MIN_COORD_CYCLES
# when omitted or not a number — the two ages independently only when a
# caller actually configures them apart (requirement 35a).
#
# ALIASES_JSON (issue #2064, extended by #2359) maps a repo slug this pipeline
# used to be configured under to the slug it is configured under now
# (`config_repo_slug_aliases`). A block's `repo` is resolved through it before
# the OPEN_ISSUES_JSON lookup above, since that map is always built from the
# live configured slug — without this, a block recorded under a name the
# repository no longer has reads as a repo this cycle "could not read",
# which this function already treats as `unknown` and leaves ineligible
# forever, not merely delayed. `ENABLER_ELIGIBLE_JQ`'s `same_item` resolves
# through the same map (#2359), so an escalation, an `enabler-examined`, or
# the `item-refined` behind `refined_before` logged under one slug is matched
# against a block recorded under the other — without that, `refined_before`
# read null for an item refined across a rename, disarming requirement 36b's
# one-refinement-per-item thrash guard exactly when the rename made it most
# likely to fire.
#
# Before returning, a `threshold`-reason candidate whose `item` is a bare
# issue number is further post-filtered through
# `enabler_defer_open_dependency_items` below (issue #2492): a candidate
# whose thread still names an open `Blocked-by:` reference is deferred for
# this cycle rather than handed to the Enabler, the same live exclusion
# `scripts/gather-issues.sh` already applies before the Co-Ordinator ever
# sees it. See that function's own header for the live check, the lapse
# bound and the `issue-closed` exemption.
#
# Always succeeds, printing [] for a missing, empty or unreadable log, exactly
# as `_latest_unresolved` does and for the same reason: the caller runs under
# `set -e` inside the exit trap, and a log it cannot parse must cost an
# engagement, never a cycle. A threshold that is not a number prints [] too —
# an unreadable setting is not a licence to spend.
enabler_eligible_items() {
  local src="${1:--}" min_coord="${2:-}" recheck_hours="${3:-0}" open_issues="${4:-{\}}" now="${5:-}" refinement_min_coord="${6:-}" aliases="${7:-{\}}"
  local out="" all_json="" docs
  local phantom_blocked="" phantom_json='[]' phantom_n=0
  # Falls back to a literal copy of lib/refinement.sh's own pattern rather
  # than an unbound-variable abort under `set -u` when that file has not been
  # sourced (a caller testing this file in isolation): the two must still
  # agree, so this is a fallback, never a second definition to keep in sync
  # by hand — production always has the real one sourced (agent-cycle.sh
  # sources every lib/*.sh file, requirement 4a).
  local comment_url_re="${REFINEMENT_COMMENT_URL_RE:-(#issuecomment-[0-9]+|/issues/comments/[0-9]+)$}"
  [[ "$min_coord" =~ ^[0-9]+$ ]] || { printf '[]'; return 0; }
  [[ "$recheck_hours" =~ ^[0-9]+$ ]] || recheck_hours=0
  [[ "$now" =~ ^[0-9]+$ ]] || now="$(date +%s)"
  [[ "$refinement_min_coord" =~ ^[0-9]+$ ]] || refinement_min_coord="$min_coord"
  jq -e 'type == "object"' <<<"$open_issues" >/dev/null 2>&1 || open_issues='{}'
  jq -e 'type == "object"' <<<"$aliases" >/dev/null 2>&1 || aliases='{}'
  if [[ "$src" == "-" ]]; then
    all_json="$(jq -c -R 'fromjson? // empty' 2>/dev/null | jq -sc '.' 2>/dev/null || true)"
  elif [[ -s "$src" ]]; then
    all_json="$(jq -c -R 'fromjson? // empty' "$src" 2>/dev/null | jq -sc '.' 2>/dev/null || true)"
  fi
  if [[ -n "$all_json" ]]; then
    # TD-PPagop-26082819: an `item-refined` event logged before the recording
    # seam (`refinement_record_fields`, `lib/refinement.sh`) validated
    # `comment_url`'s shape can still be sitting on the log — #818's and
    # #874's both were. Scoped to items this cycle's own open blocks
    # actually name (`open_blocked_items`, the same extract requirement 34
    # builds, reused rather than re-derived), so a resolved item's old
    # phantom does not warn forever.
    phantom_blocked="$(jq -c '.[]' <<<"$all_json" 2>/dev/null | open_blocked_items - 2>/dev/null || true)"
    [[ -n "$phantom_blocked" ]] || phantom_blocked='[]'
    phantom_json="$(jq -nc --arg re "$comment_url_re" '
        input as $all | input as $blocked
        | ($blocked | map({r: (.repo // ""), i: ((.item // "") | tostring)})) as $bitems
        | [ $all[]?
            | select((.event // "") == "item-refined")
            | select((.comment_url // "") != "")
            | select((.comment_url | test($re)) | not)
            | . as $e | (($e.repo // "")) as $er | (($e.item // "") | tostring) as $ei
            | select($bitems | any(.r == $er and .i == $ei))
            | {repo: $er, item: $ei, ts: ($e.ts // "")} ]' \
      <<<"$all_json"$'\n'"$phantom_blocked" 2>/dev/null || true)"
    [[ -n "$phantom_json" ]] || phantom_json='[]'
    phantom_n="$(jq 'length' <<<"$phantom_json" 2>/dev/null || printf 0)"
    [[ "$phantom_n" =~ ^[0-9]+$ ]] || phantom_n=0
    if (( phantom_n > 0 )); then
      # `command -v`, not a bare call: a harness that tests this file in
      # isolation (test/enabler-eligibility.test.sh) defines no `log_event`,
      # and this function's own "always succeeds" contract must hold there
      # too — production always has it, sourced from agent-cycle.sh itself.
      command -v log_event >/dev/null 2>&1 && log_event "warning" "$(jq -nc --argjson p "$phantom_json" \
        --arg d "enabler-eligibility: ignoring phantom item-refined event(s) whose comment_url does not actually name a comment — the block(s) they claimed to refine are treated as still unrefined (TD-PPagop-26082819)" \
        '{detail: $d, phantom: $p}')"
    fi
    # $all (the log, arbitrary in length), $open (the open-issues map, one
    # number per open issue per repo), $phantom (TD-PPagop-26082819's
    # phantom events, computed above — the whole `{repo, item, ts}` triple,
    # since `ts` alone does not identify an event on a fleet-wide log stamped
    # to the second) and $aliases (issue #2064's slug-rename map) arrive on
    # stdin, one document per line, bound positionally with `input as $name`
    # in the order printed (requirement 4g) — never in argv.
    docs="$all_json"$'\n'"$open_issues"$'\n'"$phantom_json"$'\n'"$aliases"
    out="$(jq -nc --argjson min_coord "$min_coord" --argjson recheck_hours "$recheck_hours" \
        --argjson now "$now" --argjson refinement_min_coord "$refinement_min_coord" \
        'input as $all | input as $open | input as $phantom | input as $aliases | ('"$ENABLER_ELIGIBLE_JQ"')' \
        <<<"$docs" 2>/dev/null || true)"
  fi
  if [[ -n "$out" && "$out" != "[]" ]]; then
    out="$(enabler_defer_open_dependency_items "$out" "$now" "$recheck_hours" "$aliases")"
  fi
  [[ -n "$out" ]] || out='[]'
  printf '%s' "$out"
}

# reviewer_complexity SUMMARY_GRADE TRIVIAL [LABEL_GRADE...]
# Print the effective complexity the Reviewer stage runs at (requirement 8a):
# the highest valid grade (`low` < `medium` < `high`) among the Implementer
# summary's `complexity` and the PR's `complexity:*` label values — taking the
# maximum is what makes the label's raise-never-lower rule (requirement 26a)
# hold at the decision point too. When no argument carries a valid grade at
# all, falls back to `low` if TRIVIAL is "1" (the Co-Ordinator already
# classified the work order trivial, requirement 19 — the answer is known
# without asking the trivial tier to self-grade) and `medium`, the default
# tier, otherwise.
#
# Always succeeds, and an unknown grade contributes nothing rather than
# failing: this feeds a model choice, and a garbled grade must degrade to the
# default tier, never cost the cycle.
reviewer_complexity() {
  local summary="${1:-}" trivial="${2:-0}" g best="" best_rank=0 rank
  shift 2 2>/dev/null || shift $#
  for g in "$summary" "$@"; do
    case "$g" in
      high)   rank=3 ;;
      medium) rank=2 ;;
      low)    rank=1 ;;
      *)      rank=0 ;;
    esac
    if (( rank > best_rank )); then
      best_rank=$rank
      best="$g"
    fi
  done
  if [[ -n "$best" ]]; then
    printf '%s\n' "$best"
  elif [[ "$trivial" == "1" ]]; then
    printf 'low\n'
  else
    printf 'medium\n'
  fi
}
