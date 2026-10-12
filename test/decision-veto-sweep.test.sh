#!/usr/bin/env bash
#
# test/decision-veto-sweep.test.sh — regression test for
# `run_decision_veto_sweep` (lib/decision-veto.sh, agent-ops#937,
# agent-ops#1198): the wiring that turns `scripts/sweep-decision-vetoes.sh`'s
# stdout into fleet-log events.
#
# This file's own job, on top of what `record_needs_refinement_block`'s
# recording is already covered by (test/dependency-block-refusal.test.sh and
# friends): that a veto re-block logs an `escalated` event naming the same
# log issue, `decision: true` — the registration that makes
# `ENABLER_ELIGIBLE_JQ` (lib/cycle-state.sh, see
# test/enabler-eligibility.test.sh's own decision-veto-tie cases) treat an
# open veto as a mechanical hold and its close as an immediate release. This
# fires whenever this item has a *live* block to attach it to — a freshly
# recorded one, or one this cycle's own `blocked_json` already carried before
# the sweep ran (review round 2: an Implementer needs-refinement bounce
# landing between the decision and the owner's reopen is exactly the case
# most likely to prompt a veto, and `record_needs_refinement_block` refuses
# to record a *second* block over the same item, so the registration must
# not depend on that call succeeding) — but never for an item with no live
# block at all (a genuinely malformed entry) or that does not match the veto
# this cycle's own `vetoed` action just reported.
#
# `scripts/sweep-decision-vetoes.sh` itself is replaced by a fixture under a
# fake `SCRIPT_DIR` that plays back a canned action stream regardless of its
# stdin — this file is about the wiring one level up, already covered
# end-to-end by test/sweep-decision-vetoes.test.sh for the script itself.
#
# No test framework is used (none exists elsewhere in this repo). Run it
# directly:
#
#   ./test/decision-veto-sweep.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/cycle-state.sh
. "$REPO_ROOT/lib/cycle-state.sh"
# shellcheck source=lib/decision-veto.sh
. "$REPO_ROOT/lib/decision-veto.sh"
# shellcheck source=lib/pipeline-marker.sh
. "$REPO_ROOT/lib/pipeline-marker.sh"
# shellcheck source=lib/refile.sh
. "$REPO_ROOT/lib/refile.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

failures=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected: %s\n     actual:   %s\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:             %s\n' \
      "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

assert_eq_n() {  # assert_eq_n DESC EXPECTED_COUNT NEEDLE HAYSTACK — count of NEEDLE lines in HAYSTACK
  local desc="$1" expected="$2" needle="$3" haystack="$4" actual
  actual="$(grep -c -- "$needle" <<<"$haystack" || true)"
  assert_eq "$desc" "$expected" "$actual"
}

# --- Fixture harness ---------------------------------------------------------
# `run_decision_veto_sweep` shells out to
# "$SCRIPT_DIR/scripts/sweep-decision-vetoes.sh"; SCRIPT_DIR is pointed at a
# fake root whose own copy of that path is this test's own canned fixture,
# playing back one action stream regardless of stdin.
SCRIPT_DIR="$tmp_dir/fake-root"
mkdir -p "$SCRIPT_DIR/scripts"
fixture="$SCRIPT_DIR/scripts/sweep-decision-vetoes.sh"
cat > "$fixture" <<'STUB'
#!/usr/bin/env bash
cat "$ACTIONS_FILE"
STUB
chmod +x "$fixture"

CONFIG_FILE="$tmp_dir/config.json"
jq -n '{repos: [{slug: "acme/widgets"}]}' > "$CONFIG_FILE"

union_log="$tmp_dir/union.jsonl"
: > "$union_log"

cycle_dir="$tmp_dir/cycle"
mkdir -p "$cycle_dir"
node_name="node-1"
cycle_id="cycle-1"
DRY_RUN=0

LOG_EVENT_CALLS_FILE="$tmp_dir/log_event_calls"
log_event() { printf '%s\t%s\n' "$1" "$2" >> "$LOG_EVENT_CALLS_FILE"; }
reset_log_event_calls() { rm -f "$LOG_EVENT_CALLS_FILE"; }
log_event_calls() { [[ -f "$LOG_EVENT_CALLS_FILE" ]] && cat "$LOG_EVENT_CALLS_FILE"; return 0; }

# RECORD_RESULT controls whether the stubbed recorder reports the block as
# newly recorded (0, the ordinary case) or refused (1): the real recorder's
# own refusal logic is covered elsewhere (test/dependency-block-refusal.test.sh
# and neighbours). blocked_json is the cycle global the real recorder itself
# consults for its own already-blocked refusal — set before a case simulates
# an item that already carries a live block when the sweep runs.
RECORD_RESULT=0
blocked_json='[]'
RECORD_CALLS_FILE="$tmp_dir/record_calls"
reset_record_calls() { rm -f "$RECORD_CALLS_FILE"; RECORD_RESULT=0; blocked_json='[]'; }
# shellcheck disable=SC2317  # invoked only by run_decision_veto_sweep
record_needs_refinement_block() {
  printf '%s\t%s\n' "$1" "$2" >> "$RECORD_CALLS_FILE"
  return "$RECORD_RESULT"
}

run() {  # run ACTIONS_JSONL — runs the sweep with the fixture playing back the given actions
  local actions_file="$tmp_dir/actions.jsonl"
  printf '%s' "$1" > "$actions_file"
  ACTIONS_FILE="$actions_file" run_decision_veto_sweep
}

# --- Case 1: an ordinary non-terminal veto — the block is recorded, and an
# `escalated` event registers the same log issue, marked `decision: true` ---
reset_log_event_calls
reset_record_calls
actions='{"action":"vetoed","repo":"acme/widgets","item":"42","issue_number":501,"issue_url":"https://github.com/acme/widgets/issues/501","by":"warwickallen","terminal":false}
{"action":"needs-refinement","repo":"acme/widgets","item":"42","reason":"a human vetoed the pipeline decision by reopening https://github.com/acme/widgets/issues/501","missing":"the owner decision, posted as a comment","evidence":"decision-log issue https://github.com/acme/widgets/issues/501 was reopened"}
{"action":"comment-posted","repo":"acme/widgets","item":"42","url":"https://github.com/acme/widgets/issues/42#issuecomment-1"}'
run "$actions"

calls="$(log_event_calls)"
assert_eq_n "logs exactly one decision-vetoed event" "1" "^decision-vetoed" "$calls"
assert_eq_n "logs exactly one escalated event" "1" "^escalated" "$calls"
esc_fields="$(grep '^escalated' <<<"$calls" | cut -f2-)"
assert_eq "the escalated event names the same log issue number" "501" "$(jq -r '.issue_number' <<<"$esc_fields")"
assert_eq "...and its url" "https://github.com/acme/widgets/issues/501" "$(jq -r '.issue_url' <<<"$esc_fields")"
assert_eq "...and the original item, not the log issue" "42" "$(jq -r '.item' <<<"$esc_fields")"
assert_eq "...and the repo" "acme/widgets" "$(jq -r '.repo' <<<"$esc_fields")"
assert_eq "...marked decision: true, distinguishing it from an ordinary Enabler escalation" \
  "true" "$(jq -r '.decision' <<<"$esc_fields")"
assert_eq "the recorder is called with the block, stage script" "script" \
  "$(cut -f2 "$RECORD_CALLS_FILE")"

# --- Case 2: the recorder refuses, and the item was not already blocked
# either (a genuinely malformed entry) — no escalated event is logged, since
# there is no live block anywhere to attach it to ----------------------------
reset_log_event_calls
reset_record_calls
RECORD_RESULT=1
run "$actions"
calls="$(log_event_calls)"
assert_eq_n "still logs the decision-vetoed event" "1" "^decision-vetoed" "$calls"
assert_eq_n "logs no escalated event when nothing is actually blocked" "0" "^escalated" "$calls"

# --- Case 2b (review round 2): the recorder refuses because the item was
# *already* blocked (blocked_json already carries it) when the sweep ran —
# the escalated event still fires, registering the existing block rather
# than a fresh one, since an Implementer needs-refinement bounce landing
# between the decision and the owner's reopen is exactly the real case this
# covers, not a corner case -----------------------------------------------
reset_log_event_calls
reset_record_calls
RECORD_RESULT=1
blocked_json='[{"repo":"acme/widgets","item":"42","detail":"needs a human to add a secret"}]'
run "$actions"
calls="$(log_event_calls)"
assert_eq_n "still logs the decision-vetoed event" "1" "^decision-vetoed" "$calls"
assert_eq_n "logs the escalated event against the item's existing block" "1" "^escalated" "$calls"
esc_fields="$(grep '^escalated' <<<"$calls" | cut -f2-)"
assert_eq "the escalated event still names the log issue, not the pre-existing block" \
  "501" "$(jq -r '.issue_number' <<<"$esc_fields")"

# --- Case 3: a terminal veto (revisit-filed, no needs-refinement action at
# all) — nothing to register an escalation against, so none is logged -------
reset_log_event_calls
reset_record_calls
terminal_actions='{"action":"vetoed","repo":"acme/widgets","item":"44","issue_number":503,"issue_url":"https://github.com/acme/widgets/issues/503","by":"warwickallen","terminal":true}
{"action":"revisit-filed","repo":"acme/widgets","item":"44","number":700,"url":"https://github.com/acme/widgets/issues/700"}'
run "$terminal_actions"
calls="$(log_event_calls)"
assert_eq_n "logs the decision-vetoed event for a terminal item too" "1" "^decision-vetoed" "$calls"
assert_eq_n "logs no escalated event — there is no re-block to register it against" "0" "^escalated" "$calls"


# ============================================================================
# run_pending_decision_acts (PR #1389, requirement 36f): the other half
# of `decide-with-veto` — the act a decision deferred behind its veto window,
# performed once the window has passed and nobody pulled the lever.
#
# `pending_decision_acts` (lib/cycle-state.sh) runs for real here, off a real
# union log: what makes the sweep safe is precisely which decisions it finds,
# so stubbing the finder would leave the interesting half untested. `gh` is a
# function, shadowing the binary, and is the only thing stood in for.
#
# The two directions that matter, stated once: the act is irreversible and
# the window is not, so anything this cannot establish — an unreadable log
# issue, an `act_after` that will not parse — refuses the act rather than
# taking it. That is the opposite of the veto sweep's own unreadable-events
# read, which fails *open* toward honouring a veto, and for the same reason.
# ============================================================================

GH_ISSUE_STATE="CLOSED"
GH_ISSUE_FAIL=""
GH_CALLS_FILE="$tmp_dir/gh_calls"
# shellcheck disable=SC2317  # invoked only by run_pending_decision_acts
gh() {
  printf '%s\n' "$*" >> "$GH_CALLS_FILE"
  [[ -z "$GH_ISSUE_FAIL" ]] || return 1
  printf '%s' "$GH_ISSUE_STATE"
}

taken_evt() {  # taken_evt ISSUE_NUMBER ACT_AFTER [ITEM] -> one decision-taken log line
  jq -nc --arg n "$1" --arg aa "$2" --arg i "${3:-pr-363-abandoned-aaaaaaaaaaaa}" \
    '{ts: "2026-09-01T00:00:00Z", event: "decision-taken", repo: "acme/widgets", item: $i,
      decision: "close the abandoned draft", rationale: "nothing on it is wanted",
      issue_number: ($n | tonumber), issue_url: ("https://github.com/acme/widgets/issues/" + $n),
      act: {kind: "corroborate-void"}, act_after: $aa}'
}

run_acts() {  # run_acts LOG_LINES — union log, then one sweep, under the Script's own set -e
  printf '%s\n' "$1" > "$union_log"
  : > "$GH_CALLS_FILE"
  reset_log_event_calls
  # agent-cycle.sh runs this sweep under `set -euo pipefail`, so it runs the
  # same way here (review of PR #2344: a bare `a_result="$(...)"; a_rc=$?`
  # passed under this file's own options and aborted every cycle on a node).
  local rc=0
  ( set -e; run_pending_decision_acts ) || rc=$?
  assert_eq "run_pending_decision_acts returned 0 under set -e" "0" "$rc"
}

future="$(date -u -d '+6 hours' +%Y-%m-%dT%H:%M:%SZ)"
past="$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)"
now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- Before the window: nothing happens, and nothing is said. A decision
# merely waiting is the ordinary case, not an event. ------------------------
run_acts "$(taken_evt 601 "$future")"
calls="$(log_event_calls)"
assert_eq "before the window: nothing at all is logged" "" "$calls"
assert_eq "before the window: the log issue is not even read" "0" \
  "$(wc -l < "$GH_CALLS_FILE" | tr -d ' ')"

# --- After it, with the lever un-pulled: the act runs ----------------------
GH_ISSUE_STATE="CLOSED"
run_acts "$(taken_evt 602 "$past")"
calls="$(log_event_calls)"
assert_eq_n "after the window: exactly one item-void is written" "1" "^item-void" "$calls"
void_fields="$(grep '^item-void' <<<"$calls" | cut -f2-)"
assert_eq "the void carries stage \"decision\" — requirement 34d's second writer outside the guard" \
  "decision" "$(jq -r '.stage' <<<"$void_fields")"
assert_eq "...naming the item the decision was about" "pr-363-abandoned-aaaaaaaaaaaa" \
  "$(jq -r '.item' <<<"$void_fields")"
assert_eq "...carrying the decision itself as the reason" "close the abandoned draft" \
  "$(jq -r '.detail' <<<"$void_fields")"
assert_contains "...and evidence naming the log issue that nobody reopened" \
  "https://github.com/acme/widgets/issues/602" "$(jq -r '.evidence' <<<"$void_fields")"
assert_eq_n "after the window: exactly one decision-acted" "1" "^decision-acted" "$calls"
acted_fields="$(grep '^decision-acted' <<<"$calls" | cut -f2-)"
assert_eq "the decision-acted says the act was performed" "performed" \
  "$(jq -r '.outcome' <<<"$acted_fields")"
assert_eq "...and names the act" "corroborate-void" "$(jq -r '.act.kind' <<<"$acted_fields")"
assert_eq_n "after the window: the item is unblocked, the ordinary way" "1" "^unblocked" "$calls"
unblk_fields="$(grep '^unblocked' <<<"$calls" | cut -f2-)"
assert_eq "the unblock credits the enabler, like every other decision's does" "enabler" \
  "$(jq -r '.by' <<<"$unblk_fields")"
assert_eq "after the window: no warning" "0" "$(grep -c '^warning' <<<"$calls" || true)"

# --- A window of 0 is due the moment it is written ------------------------
run_acts "$(taken_evt 603 "$now")"
calls="$(log_event_calls)"
assert_eq_n "a zero window acts on the very next cycle" "1" "^item-void" "$calls"

# --- The lever, pulled: an open log issue performs nothing and says nothing.
# The veto sweep owns the record of a veto; a second one here would double it.
GH_ISSUE_STATE="OPEN"
run_acts "$(taken_evt 604 "$past")"
calls="$(log_event_calls)"
assert_eq "a reopened log issue performs no act and logs nothing" "" "$calls"
GH_ISSUE_STATE="CLOSED"

# --- The lever, unreadable: refuse and say so. This is the fail-closed half:
# an act nobody could confirm was un-vetoed must not be taken on a guess. ---
GH_ISSUE_FAIL=1
run_acts "$(taken_evt 605 "$past")"
calls="$(log_event_calls)"
assert_eq_n "an unreadable log issue performs no act" "0" "^item-void" "$calls"
assert_eq_n "...and logs exactly one warning" "1" "^warning" "$calls"
assert_contains "...naming the issue it could not read" \
  "https://github.com/acme/widgets/issues/605" "$(grep '^warning' <<<"$calls" | cut -f2- | jq -r '.detail')"
GH_ISSUE_FAIL=""

# --- An act_after nothing can parse leaves the decision standing rather than
# acting early: an unestablished window is not a window that has passed. ----
run_acts "$(taken_evt 606 "not a timestamp")"
calls="$(log_event_calls)"
assert_eq "an unparseable act_after acts on nothing" "" "$calls"

# --- Retirement: an act already performed is never performed twice, and a
# vetoed one is never performed at all ------------------------------------
run_acts "$(taken_evt 607 "$past")
$(jq -nc '{ts: "2026-09-02T00:00:00Z", event: "decision-acted", repo: "acme/widgets",
           item: "pr-363-abandoned-aaaaaaaaaaaa", issue_number: 607, outcome: "performed"}')"
calls="$(log_event_calls)"
assert_eq "an act already performed is never performed again" "" "$calls"

run_acts "$(taken_evt 608 "$past")
$(jq -nc '{ts: "2026-09-02T00:00:00Z", event: "decision-vetoed", repo: "acme/widgets",
           item: "pr-363-abandoned-aaaaaaaaaaaa", issue_number: 608, by: "warwickallen"}')"
calls="$(log_event_calls)"
assert_eq "a vetoed decision's act is never performed" "" "$calls"

# --- A decision carrying no act is not a pending act at all ---------------
run_acts "$(jq -nc '{ts: "2026-09-01T00:00:00Z", event: "decision-taken", repo: "acme/widgets",
                     item: "TD26080001", decision: "accept the residual", rationale: "r",
                     issue_number: 609, issue_url: "u"}')"
calls="$(log_event_calls)"
assert_eq "an actless decision is never swept for an act" "" "$calls"

# --- The per-cycle cap defers rather than flooding, and says how many ------
PENDING_DECISION_ACT_MAX=2
run_acts "$(taken_evt 610 "$past" pr-610-abandoned-aaaaaaaaaaaa)
$(taken_evt 611 "$past" pr-611-abandoned-aaaaaaaaaaaa)
$(taken_evt 612 "$past" pr-612-abandoned-aaaaaaaaaaaa)"
calls="$(log_event_calls)"
assert_eq_n "the cap performs only as many acts as it allows" "2" "^item-void" "$calls"
assert_eq_n "...and reports the overflow rather than dropping it silently" "1" "^warning" "$calls"
assert_contains "...naming how many were left for a later cycle" \
  "1 due act(s) were left for a later cycle" "$(grep '^warning' <<<"$calls" | cut -f2- | jq -r '.detail')"
PENDING_DECISION_ACT_MAX=3

# --- A dry run acts on nothing, here as everywhere -------------------------
DRY_RUN=1
run_acts "$(taken_evt 613 "$past")"
calls="$(log_event_calls)"
assert_eq "--dry-run performs no act" "" "$calls"
DRY_RUN=0

# ============================================================================
# The veto sweep's own half of requirement 36f: a veto of a decision whose
# act is still pending cancels the act, on the record. The retirement is
# already mechanical — `pending_decision_acts` excludes anything a
# `decision-vetoed` names — so what this asserts is the *record*: without it,
# a cancelled act simply stops appearing, and nothing says the reopen is what
# stopped it.
# ============================================================================

pending_veto_actions='{"action":"vetoed","repo":"acme/widgets","item":"pr-363-abandoned-aaaaaaaaaaaa","issue_number":701,"issue_url":"https://github.com/acme/widgets/issues/701","by":"warwickallen","terminal":false}
{"action":"needs-refinement","repo":"acme/widgets","item":"pr-363-abandoned-aaaaaaaaaaaa","reason":"vetoed","missing":"the owner decision","evidence":"reopened"}'

printf '%s\n' "$(taken_evt 701 "$future")" > "$union_log"
reset_log_event_calls
reset_record_calls
run "$pending_veto_actions"
calls="$(log_event_calls)"
assert_eq_n "a veto of a pending act logs the veto itself" "1" "^decision-vetoed" "$calls"
assert_eq_n "...and one decision-acted recording the cancellation" "1" "^decision-acted" "$calls"
cancel_fields="$(grep '^decision-acted' <<<"$calls" | cut -f2-)"
assert_eq "the cancellation says so plainly" "cancelled" "$(jq -r '.outcome' <<<"$cancel_fields")"
assert_eq "...and names the act that will now never run" "corroborate-void" \
  "$(jq -r '.act.kind' <<<"$cancel_fields")"

# --- and a veto of an ordinary, actless decision cancels nothing -----------
printf '%s\n' "$(jq -nc '{ts: "2026-09-01T00:00:00Z", event: "decision-taken", repo: "acme/widgets",
                          item: "pr-363-abandoned-aaaaaaaaaaaa", decision: "d", rationale: "r",
                          issue_number: 701, issue_url: "u"}')" > "$union_log"
reset_log_event_calls
reset_record_calls
run "$pending_veto_actions"
calls="$(log_event_calls)"
assert_eq_n "a veto with no pending act still logs the veto" "1" "^decision-vetoed" "$calls"
assert_eq_n "...and logs no cancellation, because there was nothing to cancel" "0" "^decision-acted" "$calls"
: > "$union_log"

# ============================================================================
# run_pending_decision_acts, reach (c) (docs/STANDING-DECISIONS.md,
# 2026-10-12): the `refile-to-pipeline-repo` act. The same sweep, the same
# window and lever; what differs is the act, which has outcomes short of
# performing it. `gh` is a richer stand-in here — the act reads the
# original, searches for an earlier copy, files, closes and comments —
# dispatching on its first two words and recording every call.
# ============================================================================

crash_loop_repo="pipe/ops"
pager_repo=""
RF_PRESENT=$'pipe/ops scripts/sweep-closed-issues.sh\npipe/ops prompts/implementer.md'
RF_UNKNOWN=""
RF_ORIG_STATE="OPEN"
RF_ORIG_FAIL=""
RF_LIST='[]'
RF_LIST_FAIL=""
RF_CREATE_FAIL=""
# shellcheck disable=SC2317  # invoked only by run_pending_decision_acts and lib/refile.sh
gh() {
  printf '%s\n' "$*" >> "$GH_CALLS_FILE"
  case "$1 $2" in
    "issue view")
      if [[ "$*" == *"--json state"* ]]; then
        [[ -z "$GH_ISSUE_FAIL" ]] || return 1
        printf '%s' "$GH_ISSUE_STATE"
      else
        [[ -z "$RF_ORIG_FAIL" ]] || return 1
        jq -nc --arg s "$RF_ORIG_STATE" \
          '{title: "sweep-closed-issues.sh resolves one item", body: "## The gap\n\nBlocked-by: #516\nthe body",
            state: $s, labels: [{name: "pw::type:tech-debt"}, {name: "blocked"}],
            url: "https://github.com/acme/widgets/issues/515"}'
      fi ;;
    "api repos/"*)
      local target="${2#repos/}" repo path
      repo="${target%%/contents/*}"; path="${target#*/contents/}"
      if grep -qxF "$repo $path" <<<"$RF_UNKNOWN"; then
        printf 'gh: error connecting to api.github.com\n' >&2; return 1
      fi
      if grep -qxF "$repo $path" <<<"$RF_PRESENT"; then printf '{"type":"file"}'; return 0; fi
      printf 'gh: Not Found (HTTP 404)\n' >&2; return 1 ;;
    "issue list")
      [[ -z "$RF_LIST_FAIL" ]] || return 1
      printf '%s' "$RF_LIST" ;;
    "issue create")
      [[ -z "$RF_CREATE_FAIL" ]] || return 1
      printf 'https://github.com/pipe/ops/issues/900\n' ;;
    *) return 0 ;;
  esac
}
refile_evt() {  # refile_evt ISSUE_NUMBER ACT_AFTER -> one decision-taken line carrying the act
  jq -nc --arg n "$1" --arg aa "$2" \
    '{ts: "2026-09-01T00:00:00Z", event: "decision-taken", repo: "acme/widgets", item: "515",
      decision: "re-file it in the pipeline repository", rationale: "nothing here can implement it",
      issue_number: ($n | tonumber), issue_url: ("https://github.com/acme/widgets/issues/" + $n),
      act: {kind: "refile-to-pipeline-repo", paths: ["scripts/sweep-closed-issues.sh", "prompts/implementer.md"]},
      act_after: $aa}'
}

# --- performed: re-check, file, close, record ------------------------------
GH_ISSUE_STATE="CLOSED"; GH_ISSUE_FAIL=""
run_acts "$(refile_evt 801 "$past")"
calls="$(log_event_calls)"
gh_calls="$(cat "$GH_CALLS_FILE")"
assert_eq_n "reach (c): no item-void is written — this act is not a void" "0" "^item-void" "$calls"
assert_contains "reach (c): the paths are re-checked live where the item was filed" \
  "api repos/acme/widgets/contents/scripts/sweep-closed-issues.sh" "$gh_calls"
assert_contains "reach (c): ...and in the pipeline repository" \
  "api repos/pipe/ops/contents/prompts/implementer.md" "$gh_calls"
assert_contains "reach (c): the copy is filed in the pipeline repository" \
  "issue create -R pipe/ops --title sweep-closed-issues.sh resolves one item" "$gh_calls"
assert_contains "reach (c): the original is closed as not planned" \
  "issue close 515 -R acme/widgets --reason not planned" "$gh_calls"
assert_eq_n "reach (c): exactly one decision-acted" "1" "^decision-acted" "$calls"
acted_fields="$(grep '^decision-acted' <<<"$calls" | cut -f2-)"
assert_eq "reach (c): ...performed" "performed" "$(jq -r '.outcome' <<<"$acted_fields")"
assert_eq "reach (c): ...naming the copy" "https://github.com/pipe/ops/issues/900" "$(jq -r '.refiled.url' <<<"$acted_fields")"
assert_eq "reach (c): ...and its repository" "pipe/ops" "$(jq -r '.refiled.repo' <<<"$acted_fields")"
assert_eq "reach (c): ...carrying the act's own paths" "2" "$(jq -r '.act.paths | length' <<<"$acted_fields")"
assert_eq_n "reach (c): the item is unblocked, the ordinary way" "1" "^unblocked" "$calls"
assert_eq "reach (c): no warning" "0" "$(grep -c '^warning' <<<"$calls" || true)"

# --- refused: the re-check fails, because the file now exists where the item
# was filed — the fact the verdict rested on no longer holds -------------------
RF_PRESENT=$'acme/widgets scripts/sweep-closed-issues.sh\npipe/ops scripts/sweep-closed-issues.sh\npipe/ops prompts/implementer.md'
run_acts "$(refile_evt 802 "$past")"
calls="$(log_event_calls)"
gh_calls="$(cat "$GH_CALLS_FILE")"
assert_eq_n "reach (c) refused: one decision-acted retires the act" "1" "^decision-acted" "$calls"
acted_fields="$(grep '^decision-acted' <<<"$calls" | cut -f2-)"
assert_eq "reach (c) refused: ...as refused" "refused" "$(jq -r '.outcome' <<<"$acted_fields")"
# shellcheck disable=SC2016  # the expected string carries Markdown backticks
assert_contains "reach (c) refused: ...with the path in its reason" \
  '`scripts/sweep-closed-issues.sh` exists in acme/widgets' "$(jq -r '.reason' <<<"$acted_fields")"
assert_eq_n "reach (c) refused: exactly one warning" "1" "^warning" "$calls"
assert_eq_n "reach (c) refused: nothing is unblocked" "0" "^unblocked" "$calls"
assert_eq "reach (c) refused: nothing is filed" "0" "$(grep -c '^issue create' <<<"$gh_calls" || true)"
assert_eq "reach (c) refused: nothing is closed" "0" "$(grep -c '^issue close' <<<"$gh_calls" || true)"
assert_contains "reach (c) refused: the refusal is said on the decision-log issue" \
  "issue comment 802 -R acme/widgets" "$gh_calls"
RF_PRESENT=$'pipe/ops scripts/sweep-closed-issues.sh\npipe/ops prompts/implementer.md'

# --- refused: the original is already closed — someone acted first --------
RF_ORIG_STATE="CLOSED"
run_acts "$(refile_evt 803 "$past")"
calls="$(log_event_calls)"
gh_calls="$(cat "$GH_CALLS_FILE")"
acted_fields="$(grep '^decision-acted' <<<"$calls" | cut -f2-)"
assert_eq "reach (c) closed original: refused" "refused" "$(jq -r '.outcome' <<<"$acted_fields")"
assert_contains "reach (c) closed original: ...saying someone acted first" "someone acted first" \
  "$(jq -r '.reason' <<<"$acted_fields")"
assert_eq "reach (c) closed original: nothing is filed" "0" "$(grep -c '^issue create' <<<"$gh_calls" || true)"
assert_eq "reach (c) closed original: the original is read before any contents read, so none is made" "0" \
  "$(grep -c '^api repos/' <<<"$gh_calls" || true)"
RF_ORIG_STATE="OPEN"

# --- waits: the create fails; the act is still owed, and the next cycle
# performs it ---------------------------------------------------------------
RF_CREATE_FAIL=1
run_acts "$(refile_evt 804 "$past")"
calls="$(log_event_calls)"
assert_eq_n "reach (c) create failed: no decision-acted — the act is still owed" "0" "^decision-acted" "$calls"
assert_eq_n "reach (c) create failed: one warning says why" "1" "^warning" "$calls"
assert_contains "reach (c) create failed: ...naming the repository" "could not file the copy in pipe/ops" \
  "$(grep '^warning' <<<"$calls" | cut -f2- | jq -r '.detail')"
RF_CREATE_FAIL=""
run_acts "$(refile_evt 804 "$past")"
calls="$(log_event_calls)"
assert_eq "reach (c) create failed: the next cycle performs it" "performed" \
  "$(grep '^decision-acted' <<<"$calls" | cut -f2- | jq -r '.outcome')"

# --- idempotent: a copy already carrying the marker is reused, the close
# alone is made ---------------------------------------------------------------
RF_LIST='[{"number":890,"url":"https://github.com/pipe/ops/issues/890","body":"<!-- agent-ops:refiled-from repo=acme/widgets item=515 -->"}]'
run_acts "$(refile_evt 805 "$past")"
calls="$(log_event_calls)"
gh_calls="$(cat "$GH_CALLS_FILE")"
assert_eq "reach (c) reuse: no second filing" "0" "$(grep -c '^issue create' <<<"$gh_calls" || true)"
assert_eq "reach (c) reuse: the close is made" "1" "$(grep -c '^issue close' <<<"$gh_calls" || true)"
assert_eq "reach (c) reuse: the record names the copy found" "https://github.com/pipe/ops/issues/890" \
  "$(grep '^decision-acted' <<<"$calls" | cut -f2- | jq -r '.refiled.url')"
RF_LIST='[]'

# --- waits: a path that cannot be read at act time leaves the act owed — a
# decision that stood through its window is not retired over a read that
# failed — and the next cycle, able to read, performs it ----------------------
RF_UNKNOWN="acme/widgets prompts/implementer.md"
run_acts "$(refile_evt 806 "$past")"
calls="$(log_event_calls)"
assert_eq_n "reach (c) unreadable path: no decision-acted — the act is still owed" "0" "^decision-acted" "$calls"
assert_eq_n "reach (c) unreadable path: one warning says why" "1" "^warning" "$calls"
# shellcheck disable=SC2016  # the expected string carries Markdown backticks
assert_contains "reach (c) unreadable path: ...naming the path" \
  'could not establish whether `prompts/implementer.md` exists in acme/widgets' \
  "$(grep '^warning' <<<"$calls" | cut -f2- | jq -r '.detail')"
assert_eq "reach (c) unreadable path: nothing is filed" "0" "$(grep -c '^issue create' "$GH_CALLS_FILE" || true)"
assert_eq "reach (c) unreadable path: nothing is said on the decision-log issue" "0" \
  "$(grep -c '^issue comment' "$GH_CALLS_FILE" || true)"
RF_UNKNOWN=""
run_acts "$(refile_evt 806 "$past")"
assert_eq "reach (c) unreadable path: the next cycle performs it" "performed" \
  "$(grep '^decision-acted' <<<"$(log_event_calls)" | cut -f2- | jq -r '.outcome')"

# --- performed by a cycle that died between its close and its record: the
# original is closed and a copy carries the marker, so this is the act, done,
# and the record is written at last --------------------------------------------
RF_ORIG_STATE="CLOSED"
RF_LIST='[{"number":890,"url":"https://github.com/pipe/ops/issues/890","body":"<!-- agent-ops:refiled-from repo=acme/widgets item=515 -->"}]'
run_acts "$(refile_evt 807 "$past")"
calls="$(log_event_calls)"
gh_calls="$(cat "$GH_CALLS_FILE")"
acted_fields="$(grep '^decision-acted' <<<"$calls" | cut -f2-)"
assert_eq "reach (c) closed with a marked copy: performed" "performed" "$(jq -r '.outcome' <<<"$acted_fields")"
assert_eq "reach (c) closed with a marked copy: ...naming the copy" \
  "https://github.com/pipe/ops/issues/890" "$(jq -r '.refiled.url' <<<"$acted_fields")"
assert_eq_n "reach (c) closed with a marked copy: the item is unblocked" "1" "^unblocked" "$calls"
assert_eq "reach (c) closed with a marked copy: no filing and no close" "0" \
  "$(grep -c -E '^issue (create|close)' <<<"$gh_calls" || true)"
RF_ORIG_STATE="OPEN"; RF_LIST='[]'

# --- waits: the search for an earlier copy fails, which is not "none" --------
RF_LIST_FAIL=1
run_acts "$(refile_evt 808 "$past")"
calls="$(log_event_calls)"
assert_eq_n "reach (c) search failed: no decision-acted" "0" "^decision-acted" "$calls"
assert_eq_n "reach (c) search failed: one warning" "1" "^warning" "$calls"
assert_contains "reach (c) search failed: ...saying why" "might file it twice" \
  "$(grep '^warning' <<<"$calls" | cut -f2- | jq -r '.detail')"
assert_eq "reach (c) search failed: nothing is filed" "0" "$(grep -c '^issue create' "$GH_CALLS_FILE" || true)"
RF_LIST_FAIL=""

# --- bounded: an act still owed PENDING_DECISION_ACT_WAIT_WINDOWS veto windows
# after it fell due is retired as refused rather than retried for ever ---------
long_past="$(date -u -d '-4 days' +%Y-%m-%dT%H:%M:%SZ)"
RF_ORIG_FAIL=1
run_acts "$(refile_evt 810 "$long_past")"
calls="$(log_event_calls)"
acted_fields="$(grep '^decision-acted' <<<"$calls" | cut -f2-)"
assert_eq "reach (c) bound: an act four days past due with a 24 h window is refused" "refused" \
  "$(jq -r '.outcome' <<<"$acted_fields")"
assert_contains "reach (c) bound: ...saying how long a wait may last" \
  "waited more than 72 hours past that (3 veto windows)" "$(jq -r '.reason' <<<"$acted_fields")"
assert_eq "reach (c) bound: ...after the lever read alone, with no read of the original or its paths" "0" \
  "$(grep -c -E '^(api repos/|issue list|issue view 515)' "$GH_CALLS_FILE" || true)"
assert_contains "reach (c) bound: ...said on the decision-log issue" "issue comment 810 -R acme/widgets" \
  "$(cat "$GH_CALLS_FILE")"
decision_veto_window_hours=1
four_hours_ago="$(date -u -d '-4 hours' +%Y-%m-%dT%H:%M:%SZ)"
run_acts "$(refile_evt 811 "$four_hours_ago")"
assert_eq "reach (c) bound: the bound follows the configured window — four hours past a 1 h window is refused" \
  "refused" "$(grep '^decision-acted' <<<"$(log_event_calls)" | cut -f2- | jq -r '.outcome')"
run_acts "$(refile_evt 812 "$past")"
calls="$(log_event_calls)"
assert_eq_n "reach (c) bound: ...and one hour past it still waits" "0" "^decision-acted" "$calls"
assert_eq_n "reach (c) bound: ...with its warning" "1" "^warning" "$calls"
unset decision_veto_window_hours
RF_ORIG_FAIL=""
: > "$union_log"

echo
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
echo "all tests passed"
