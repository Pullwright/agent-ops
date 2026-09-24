#!/usr/bin/env bash
#
# test/sweep-legacy-refinement-assignees.test.sh — the migration off
# requirement 38b's old, assignment-based bookkeeping (agent-ops#639).
#
# What this guards: `scripts/sweep-legacy-refinement-assignees.sh` finds a
# still-open needs-refinement block whose event carries the legacy
# `needs_refinement_assignee` field — the marker only the pre-agent-ops#639
# projection ever wrote — and, for exactly that item, removes the stale
# assignment and applies `blocked`/`blocked:needs-refinement` in its place.
# Every other block — a fresh one with no legacy field, a different repo's
# identically-numbered item, an ordinary (non-refinement) block — must be
# left untouched, and a repeat run over an already-swept repository must do
# nothing at all (idempotency is what makes this safe to re-run from a cron
# job rather than a careful one-off).
#
# The `blocked` half of that pair is also guarded read-before-write
# (agent-ops#651): a pre-existing `blocked` — a human's own, applied for
# their own reasons before this legacy block was ever migrated — is left
# exactly as found, never re-added and never claimed on stdout as this run's
# own doing.
#
# `gh` is a stub on PATH via REFINEMENT_GH; no network.
#
# Run directly: ./test/sweep-legacy-refinement-assignees.test.sh — exit 0 iff
# all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWEEP="$SCRIPT_DIR/scripts/sweep-legacy-refinement-assignees.sh"

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

# --- The stub: `gh issue edit <n> -R <slug> --remove-assignee|--add-label`,
# and `gh issue view <n> -R <slug> --json labels --jq ...` for
# `refinement_label_project`'s read-before-write on `blocked`. The view call
# serves the label names in $tmp_dir/issue-labels, one per line — empty (the
# common case) unless a test seeds it — and is never itself counted in
# $tmp_dir/calls, which stays scoped to the label/assignee *mutations* the
# assertions below count.
cat >"$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
d="$(dirname "$0")"
if [[ "$1" == "issue" && "$2" == "view" ]]; then
  cat "$d/issue-labels" 2>/dev/null
  exit 0
fi
[[ "$1" == "issue" && "$2" == "edit" ]] || exit 1
number="$3"; shift 3
repo=""; action=""; label=""; assignee=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -R) repo="$2"; shift 2 ;;
    --add-label) action="add"; label="$2"; shift 2 ;;
    --remove-label) action="remove"; label="$2"; shift 2 ;;
    --remove-assignee) action="unassign"; assignee="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[[ -n "$label" ]] && printf '%s %s %s %s\n' "$action" "$repo" "$number" "$label" >> "$d/calls"
[[ -n "$assignee" ]] && printf '%s %s %s %s\n' "$action" "$repo" "$number" "$assignee" >> "$d/calls"
exit 0
STUB
chmod +x "$tmp_dir/gh"
export REFINEMENT_GH="$tmp_dir/gh"

calls() { cat "$tmp_dir/calls" 2>/dev/null || true; }
reset_calls() { rm -f "$tmp_dir/calls"; }
issue_labels() { printf '%s\n' "$@" > "$tmp_dir/issue-labels"; }
reset_issue_labels() { rm -f "$tmp_dir/issue-labels"; }

log="$tmp_dir/log.jsonl"
cat > "$log" <<'EOF'
{"ts":"2026-08-01T09:00:00Z","cycle":"c0","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"52","kind":"needs-refinement","detail":"gated","unblock_condition":"x","needs_refinement_label":"needs-refinement","needs_refinement_assignee":"warwickallen"}
{"ts":"2026-08-01T09:00:01Z","cycle":"c0","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"53","kind":"needs-refinement","detail":"gated","unblock_condition":"y","needs_refinement_label":"needs-refinement"}
{"ts":"2026-08-01T09:00:02Z","cycle":"c0","event":"attempt-failed","stage":"implementer","repo":"o/r","item":"54","detail":"needs a repo secret"}
{"ts":"2026-08-01T09:00:03Z","cycle":"c0","event":"attempt-failed","stage":"coordinator","repo":"o/other","item":"52","kind":"needs-refinement","detail":"gated","unblock_condition":"z","needs_refinement_label":"needs-refinement","needs_refinement_assignee":"warwickallen"}
EOF

reset_calls
reset_issue_labels
out="$("$SWEEP" "o/r" "$log")"
assert_eq "the legacy block's assignment is removed, exactly once" "1" \
  "$(grep -cE '^unassign o/r 52 warwickallen$' <<<"$(calls)")"
assert_eq "the blocked label is applied" "1" \
  "$(grep -cE '^add o/r 52 blocked$' <<<"$(calls)")"
assert_eq "the reason label is applied" "1" \
  "$(grep -cE '^add o/r 52 blocked:needs-refinement$' <<<"$(calls)")"
assert_eq "a fresh block with no legacy field is untouched" "0" \
  "$(grep -cE '(^| )53( |$)' <<<"$(calls)")"
assert_eq "an ordinary (non-refinement) block is untouched" "0" \
  "$(grep -cE '(^| )54( |$)' <<<"$(calls)")"
assert_eq "another repo's identically-numbered item is untouched" "0" \
  "$(grep -cE 'o/other' <<<"$(calls)")"
assert_eq "exactly three calls were made in total" "3" \
  "$(calls | grep -c .)"
assert_eq "the sweep names what it did, on stdout" "3" \
  "$(grep -cE '^o/r#52: ' <<<"$out")"

# --- OWN-LOG-FILE (5th arg, agent-ops#999/TD-PPagop-26082608): a genuine ----
# `added` result for either label is logged as an `own-label-action add`,
# giving `refinement_blocked_label_stale` (lib/refinement.sh) the history it
# needs to retry the generic `blocked` once the block later clears — the
# residue this item exists to close. No own-log-file at all (every call
# above) must keep logging nothing, which the calls-only assertions above
# already prove indirectly; this section asserts the positive log content
# directly.
own_log="$tmp_dir/own-log.jsonl"
cat >> "$log" <<'EOF'
{"ts":"2026-08-01T09:00:05Z","cycle":"c0","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"63","kind":"needs-refinement","detail":"gated","unblock_condition":"v","needs_refinement_label":"needs-refinement","needs_refinement_assignee":"warwickallen"}
EOF
reset_calls
reset_issue_labels
: > "$own_log"
"$SWEEP" "o/r" "$log" "" "" "$own_log" >/dev/null
assert_eq "a genuinely added blocked label is logged as own-label-action add" "1" \
  "$(jq -c 'select(.event=="own-label-action" and .repo=="o/r" and .item=="63" and .label=="blocked" and .action=="add")' "$own_log" | grep -c .)"
assert_eq "the reason label's add is logged too" "1" \
  "$(jq -c 'select(.event=="own-label-action" and .repo=="o/r" and .item=="63" and .label=="blocked:needs-refinement" and .action=="add")' "$own_log" | grep -c .)"
assert_eq "exactly two own-label-action events were logged for item 63" "2" \
  "$(jq -c 'select(.item=="63")' "$own_log" | grep -c .)"

# A pre-existing `blocked` (a human's own) is never logged as this run's own
# `add`, even with OWN-LOG-FILE given — only the reason label's unconditional
# add is.
reset_calls
issue_labels "blocked"
: > "$own_log"
"$SWEEP" "o/r" "$log" "" "" "$own_log" >/dev/null
assert_eq "a pre-existing blocked label is never logged as this run's own add" "0" \
  "$(jq -c 'select(.event=="own-label-action" and .item=="63" and .label=="blocked")' "$own_log" | grep -c .)"
assert_eq "  ... while the reason label's add is still logged" "1" \
  "$(jq -c 'select(.event=="own-label-action" and .item=="63" and .label=="blocked:needs-refinement" and .action=="add")' "$own_log" | grep -c .)"
reset_issue_labels

# No OWN-LOG-FILE argument at all (the default, every call above it) touches
# no file and does not error.
reset_calls
reset_issue_labels
assert_eq "omitting own-log-file entirely still succeeds" "0" \
  "$("$SWEEP" "o/r" "$log" >/dev/null 2>&1; echo $?)"

# --- Idempotency: a repeat run over the same log is a no-op in outcome -------
# (the calls are re-issued — every primitive here is a no-op-on-repeat `gh`
# call by construction, per lib/refinement.sh's own contract — but nothing
# new is discovered and no other item is ever touched.)
reset_calls
out2="$("$SWEEP" "o/r" "$log")"
assert_eq "a repeat run finds the same one item, and only it" "3" \
  "$(grep -cE '^o/r#52: ' <<<"$out2")"
assert_eq "  ... never touching 53, 54 or o/other#52" "0" \
  "$(calls | grep -cE '53|54|o/other')"

# --- A pre-existing `blocked` — a human's own — is read before it is written ---
# (agent-ops#651). Same legacy shape as item 52 above, a fresh item number (77)
# so nothing here can be confused with the idempotency run's own calls. The
# issue already carries `blocked` when the sweep reaches it: `blocked` must
# not be re-added or claimed as "applied" on stdout, while the reason label —
# a name no human reaches for on their own — still goes on unconditionally.
cat >> "$log" <<'EOF'
{"ts":"2026-08-01T09:00:04Z","cycle":"c0","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"77","kind":"needs-refinement","detail":"gated","unblock_condition":"w","needs_refinement_label":"needs-refinement","needs_refinement_assignee":"octocat"}
EOF
reset_calls
issue_labels "blocked"
out4="$("$SWEEP" "o/r" "$log")"
assert_eq "the legacy assignment on the human-blocked issue is still removed" "1" \
  "$(grep -cE '^unassign o/r 77 octocat$' <<<"$(calls)")"
assert_eq "the pre-existing blocked label is never re-added" "0" \
  "$(grep -cE '^add o/r 77 blocked$' <<<"$(calls)")"
assert_eq "  ... nor claimed as applied on stdout" "0" \
  "$(grep -cE '^o/r#77: applied blocked$' <<<"$out4")"
assert_eq "  ... it is named as already present instead" "1" \
  "$(grep -cE '^o/r#77: blocked already present' <<<"$out4")"
assert_eq "the reason label still goes on unconditionally" "1" \
  "$(grep -cE '^add o/r 77 blocked:needs-refinement$' <<<"$(calls)")"
reset_issue_labels

# --- An already-clean repository does nothing at all -------------------------
reset_calls
out3="$("$SWEEP" "o/other" "$tmp_dir/nonexistent-log")"
assert_eq "a repo with no legacy blocks at all makes no gh calls" "" "$(calls)"
assert_eq "  ... and prints nothing to stdout" "" "$out3"

# ==============================================================================
# agent-ops#994 / TD-PPagop-26082602: a block LOG_FILE already knows has
# cleared is never projected onto, and PEERS_DIR (new) refuses the whole run
# rather than act on a union that might be missing an unblock event.
# ==============================================================================

# --- A legacy block whose own unblocked event is already in LOG_FILE is left
#     alone, regardless of where in the file that event falls — `blocked_items`
#     matches on the events' own `ts`, never file order (the #602 case: the
#     clear predates the sweep's own run, and here it predates the block's
#     own event in the file too, which must not matter either) -------------
cleared_log="$tmp_dir/log-cleared.jsonl"
cat > "$cleared_log" <<'EOF'
{"ts":"2026-08-21T07:52:09Z","cycle":"c1","event":"unblocked","repo":"o/r","item":"602","by":"enabler"}
{"ts":"2026-07-01T09:00:00Z","cycle":"c0","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"602","kind":"needs-refinement","detail":"gated","unblock_condition":"x","needs_refinement_label":"needs-refinement","needs_refinement_assignee":"warwickallen"}
EOF
reset_calls
reset_issue_labels
out_cleared="$("$SWEEP" "o/r" "$cleared_log")"
assert_eq "a block LOG_FILE already shows cleared makes no gh calls at all" "" "$(calls)"
assert_eq "  ... and prints nothing to stdout" "" "$out_cleared"

# --- PEERS_DIR, when given, gates the whole run on fleet_logs_healthy -------
legacy_log="$tmp_dir/log-legacy-only.jsonl"
cat > "$legacy_log" <<'EOF'
{"ts":"2026-08-01T09:00:00Z","cycle":"c0","event":"attempt-failed","stage":"coordinator","repo":"o/r","item":"52","kind":"needs-refinement","detail":"gated","unblock_condition":"x","needs_refinement_label":"needs-refinement","needs_refinement_assignee":"warwickallen"}
EOF

no_marker_peers="$tmp_dir/peers-no-marker"
mkdir -p "$no_marker_peers"
reset_calls
reset_issue_labels
"$SWEEP" "o/r" "$legacy_log" "$no_marker_peers" >/dev/null
assert_eq "no peers marker at all (bootstrap) reads healthy — the run proceeds" "1" \
  "$(grep -cE '^unassign o/r 52 warwickallen$' <<<"$(calls)")"

stale_peers="$tmp_dir/peers-stale"
mkdir -p "$stale_peers"
printf '{"ok":false,"ts":"%s","last_ok_ts":null}' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  > "$stale_peers/.last-fetch.json"
reset_calls
reset_issue_labels
sweep_exit=0
sweep_err="$("$SWEEP" "o/r" "$legacy_log" "$stale_peers" 2>&1 >/dev/null)" || sweep_exit=$?
assert_eq "a stale (ok:false) peers marker refuses the run" "1" "$sweep_exit"
assert_eq "  ... making no gh calls at all" "" "$(calls)"
assert_eq "  ... and saying why on stderr" "1" \
  "$(grep -cE 'degraded' <<<"$sweep_err")"

fresh_peers="$tmp_dir/peers-fresh"
mkdir -p "$fresh_peers"
fresh_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '{"ok":true,"ts":"%s","last_ok_ts":"%s"}' "$fresh_ts" "$fresh_ts" \
  > "$fresh_peers/.last-fetch.json"
reset_calls
reset_issue_labels
"$SWEEP" "o/r" "$legacy_log" "$fresh_peers" >/dev/null
assert_eq "a fresh (ok:true) peers marker reads healthy — the run proceeds" "1" \
  "$(grep -cE '^unassign o/r 52 warwickallen$' <<<"$(calls)")"

reset_calls
reset_issue_labels
"$SWEEP" "o/r" "-" "$stale_peers" < "$legacy_log" >/dev/null
assert_eq "PEERS_DIR is a no-op against stdin (\"-\"), which the health gate cannot stat" "1" \
  "$(grep -cE '^unassign o/r 52 warwickallen$' <<<"$(calls)")"

# --- Usage ---------------------------------------------------------------
assert_eq "no repo argument is a usage error" "64" \
  "$("$SWEEP" >/dev/null 2>&1; echo $?)"

echo
if (( failures == 0 )); then
  echo "All sweep-legacy-refinement-assignees assertions passed."
  exit 0
else
  echo "$failures sweep-legacy-refinement-assignees assertion(s) FAILED."
  exit 1
fi
