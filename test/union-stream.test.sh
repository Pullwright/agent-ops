#!/usr/bin/env bash
#
# test/union-stream.test.sh — regression test for lib/union-stream.sh and the
# event-type declarations of every reader that folds the fleet union from a
# stream (agent-ops#1649).
#
# What matters here:
#
#   declarations    a reader gathers only the event types it declares, so a
#                   program that reads a type its declaration lacks sees none
#                   of them and reports a quiet zero. Every reader's program
#                   is checked against its declaration: the Publisher's own
#                   (between `# union-reader:` markers in
#                   scripts/publish-dashboard.sh, declared by
#                   `union_reader_events`) and the library folds' (each
#                   `<NAME>_JQ` against its `<NAME>_EVENTS`).
#   union_stream    the kept-events-then-span protocol: the two timestamp
#                   rules, the SINCE gate, `--objects`, `--raw`, and the
#                   abort on a record that is not an object, which must leave
#                   no span line and a non-zero status.
#   union_partition one pass, one file per reader, each closed by the span;
#                   an event two readers declare reaches both; a failed pass
#                   leaves no file behind.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/union-stream.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PUBLISH="$SCRIPT_DIR/scripts/publish-dashboard.sh"

# shellcheck source=lib/cycle-state.sh
. "$SCRIPT_DIR/lib/cycle-state.sh"
# shellcheck source=lib/union-stream.sh
. "$SCRIPT_DIR/lib/union-stream.sh"
# shellcheck source=lib/rework-panel.sh
. "$SCRIPT_DIR/lib/rework-panel.sh"
# shellcheck source=lib/node-time-state.sh
. "$SCRIPT_DIR/lib/node-time-state.sh"
# shellcheck source=lib/stage-budget.sh
. "$SCRIPT_DIR/lib/stage-budget.sh"
# shellcheck source=lib/fleet-sizing.sh
. "$SCRIPT_DIR/lib/fleet-sizing.sh"

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

# event_reads PROGRAM — the event types a jq program reads, one per line,
# sorted: `.event == "x"` in any spacing, `.event | IN("x", …)`, and the
# set/clear pair a `latest_unresolved("x"; "y")` call folds.
event_reads() {
  local text="$1"
  {
    grep -oE '\.event *== *"[A-Za-z0-9_-]+"' <<<"$text" | grep -oE '"[^"]+"'
    grep -oE '\.event *\| *IN\([^)]*\)' <<<"$text" | grep -oE '"[^"]+"'
    grep -oE 'latest_unresolved\("[^"]+"; *"[^"]+"\)' <<<"$text" | grep -oE '"[^"]+"'
  } | tr -d '"' | LC_ALL=C sort -u
}

# undeclared PROGRAM DECLARED — the types PROGRAM reads that DECLARED (a word
# list) does not name, space-separated; empty when every read is declared.
undeclared() {
  local reads declared
  reads="$(event_reads "$1")"
  # shellcheck disable=SC2086  # a word list by design.
  declared="$(printf '%s\n' $2 | LC_ALL=C sort -u)"
  LC_ALL=C comm -23 <(printf '%s\n' "$reads" | sed '/^$/d') <(printf '%s\n' "$declared") \
    | tr '\n' ' ' | sed 's/ $//'
}

# reader_text NAME — the Publisher's own program for union reader NAME: every
# line between its `# union-reader: NAME` and `# union-reader-end: NAME`.
reader_text() {
  awk -v r="$1" '$0 == "# union-reader-end: " r { on = 0 } on { print } $0 == "# union-reader: " r { on = 1 }' \
    "$PUBLISH"
}

# --- The checker itself catches an undeclared read --------------------------------
# Without this, a checker that silently matched nothing would pass every
# reader below.
assert_eq "the checker finds every form of read" "a b c d e" \
  "$(event_reads 'select(.event == "a") | select(.event=="b") | (.event | IN("c", "d")) | latest_unresolved("e"; "a")' \
     | tr '\n' ' ' | sed 's/ $//')"
assert_eq "an undeclared read is reported" "zzz-undeclared" \
  "$(undeclared 'select(.event == "stage-end" or .event == "zzz-undeclared")' "stage-end")"
assert_eq "a fully declared program reports nothing" "" \
  "$(undeclared 'select(.event == "stage-end")' "stage-end selection")"

# --- Every Publisher reader reads only what it declares ---------------------------
mapfile -t publisher_readers < <(sed -n 's/^# union-reader: //p' "$PUBLISH")
assert_eq "the Publisher marks its declared readers" "yes" \
  "$( (( ${#publisher_readers[@]} >= 7 )) && echo yes || echo "no (${#publisher_readers[@]})")"
for r in "${publisher_readers[@]}"; do
  declared="$(union_reader_events "$r" 2>/dev/null | tr '\n' ' ')"
  assert_eq "publisher reader '$r' has a declaration" "yes" "$([[ -n "$declared" ]] && echo yes || echo no)"
  text="$(reader_text "$r")"
  assert_eq "publisher reader '$r' has a program between its markers" "yes" \
    "$([[ -n "$(event_reads "$text")" ]] && echo yes || echo no)"
  assert_eq "publisher reader '$r' reads only the event types it declares" "" \
    "$(undeclared "$text" "$declared")"
done
for r in "${publisher_readers[@]}"; do
  assert_eq "publisher reader '$r' closes its markers" "1" \
    "$(grep -cx "# union-reader-end: $r" "$PUBLISH")"
done

# --- Every library fold reads only what it declares -------------------------------
lib_check() {  # lib_check NAME PROGRAM DECLARED
  assert_eq "$1 reads at least one event type (the checker sees its program)" "yes" \
    "$([[ -n "$(event_reads "$2")" ]] && echo yes || echo no)"
  assert_eq "$1 reads only the event types it declares" "" "$(undeclared "$2" "$3")"
}
lib_check BLOCKED_ITEMS_JQ "$BLOCKED_ITEMS_JQ" "$BLOCKED_ITEMS_EVENTS"
lib_check OPEN_BLOCKED_JQ "$OPEN_BLOCKED_JQ" "$OPEN_BLOCKED_EVENTS"
lib_check DRAFT_OBSOLETE_FLAGS_JQ "$DRAFT_OBSOLETE_FLAGS_JQ" "$DRAFT_OBSOLETE_FLAGS_EVENTS"
lib_check REWORK_PANEL_JQ "$REWORK_PANEL_JQ" "$REWORK_PANEL_EVENTS"
lib_check NODE_TIME_STATE_FOLD_JQ "$NODE_TIME_STATE_FOLD_JQ" "$NODE_TIME_STATE_EVENTS"
lib_check STAGE_BUDGET_OBSERVATIONS_JQ "$STAGE_BUDGET_OBSERVATIONS_JQ" "$STAGE_BUDGET_OBSERVATIONS_EVENTS"
lib_check FLEET_SIZING_CONTENTION_BY_NODE_JQ "$FLEET_SIZING_CONTENTION_BY_NODE_JQ" "$FLEET_SIZING_CONTENTION_EVENTS"
assert_eq "void_items declares exactly its set/clear pair" "item-void unvoided" "$VOID_ITEMS_EVENTS"
# shellcheck disable=SC2086  # a word list by design.
assert_eq "the partition's open-blocked declaration is cycle-state's own" \
  "$(printf '%s\n' $OPEN_BLOCKED_EVENTS | tr '\n' ' ')" "$(union_reader_events open-blocked | tr '\n' ' ')"

# --- union_stream: the protocol, the two timestamp rules, the SINCE gate ----------
log="$tmp_dir/log.jsonl"
cat > "$log" <<'EOF'
{"ts":"2026-03-02T00:00:00Z","event":"stage-end","n":1}
{"ts":"2026-03-01T00:00:00Z","event":"github-budget","n":2}
{"ts":"","event":"noise","n":3}
{"event":"noise","n":4}
{"ts":"2026-03-03T00:00:00Z","event":"stage-end","n":5}
EOF
out="$(union_stream "$log" --events "stage-end")"; rc=$?
assert_eq "union_stream exits 0 on a clean log" "0" "$rc"
assert_eq "it keeps the declared events in log order, then the span" \
  '[1,5]' "$(jq -sc '.[:-1] | map(.n)' <<<"$out")"
assert_eq "the 'any' rule counts an empty-string ts, as [ .[] | .ts // empty ] | min did" \
  '{"lo":"","hi":"2026-03-03T00:00:00Z"}' "$(jq -sc '.[-1].span' <<<"$out")"
out="$(union_stream "$log" --events "stage-end" --ts nonempty)"
assert_eq "the 'nonempty' rule leaves the empty string out" \
  '{"lo":"2026-03-01T00:00:00Z","hi":"2026-03-03T00:00:00Z"}' "$(jq -sc '.[-1].span' <<<"$out")"
out="$(union_stream "$log" --events "stage-end" --ts nonempty --since "2026-03-02T00:00:00Z")"
assert_eq "SINCE gates the span to records at or after it" \
  '{"lo":"2026-03-02T00:00:00Z","hi":"2026-03-03T00:00:00Z"}' "$(jq -sc '.[-1].span' <<<"$out")"
assert_eq "…but not the kept events, which a --keep filter gates itself" \
  '[1,5]' "$(jq -sc '.[:-1] | map(.n)' <<<"$out")"
assert_eq "union_split_span parts the slurped lines into events and span" \
  '{"events":[1,5],"span":{"lo":"2026-03-02T00:00:00Z","hi":"2026-03-03T00:00:00Z"}}' \
  "$(jq -sc "$UNION_STREAM_JQ"' union_split_span | .events |= map(.n)' <<<"$out")"
assert_eq "…and an empty stream into no events and an empty span" \
  '{"events":[],"span":{"lo":null,"hi":null}}' "$(jq -nc "$UNION_STREAM_JQ"' [] | union_split_span')"

# The abort: a record that is not an object stops the fold where the whole-
# array reader failed, so the stream exits non-zero and never writes its span
# line — the signal every consumer gates its slurp on.
printf '7\n' >> "$log"
out="$(union_stream "$log" --events "stage-end" 2>/dev/null)"; rc=$?
assert_eq "a record that is not an object aborts the stream (non-zero)" "nonzero" \
  "$( (( rc != 0 )) && echo nonzero || echo zero)"
assert_eq "…and leaves no span line behind" "0" \
  "$(printf '%s\n' "$out" | grep -c '"span"')"
out="$(union_stream "$log" --events "stage-end" --objects)"; rc=$?
assert_eq "--objects drops it instead, as the two readers that dropped non-objects did" "0" "$rc"
assert_eq "…keeping the span" '"2026-03-03T00:00:00Z"' "$(jq -sc '.[-1].span.hi' <<<"$out")"
printf '{"ts":"2026-03-04T00:00:00Z","event":"stage-e\n' >> "$log"
out="$(union_stream "$log" --raw --objects --events "stage-end")"; rc=$?
assert_eq "--raw drops a torn line rather than aborting at it" "0" "$rc"

# --- union_partition ---------------------------------------------------------------
cat > "$log" <<'EOF'
{"ts":"2026-03-01T00:00:00Z","event":"classifier-escape","n":1}
{"ts":"2026-03-02T00:00:00Z","event":"decision-taken","n":2}
{"ts":"2026-03-03T00:00:00Z","event":"wake-poll","n":3}
EOF
kept="$tmp_dir/kept"
union_partition "$log" "$kept" landings escape-audits decisions; rc=$?
assert_eq "union_partition exits 0 on a clean log" "0" "$rc"
assert_eq "an event two readers declare reaches both: landings" '[1]' \
  "$(jq -sc '.[:-1] | map(.n)' "$kept/landings.jsonl")"
assert_eq "…and escape-audits" '[1]' "$(jq -sc '.[:-1] | map(.n)' "$kept/escape-audits.jsonl")"
assert_eq "each file holds only its own declared types" '[2]' \
  "$(jq -sc '.[:-1] | map(.n)' "$kept/decisions.jsonl")"
assert_eq "each file closes with the whole log's span" \
  '{"lo":"2026-03-01T00:00:00Z","hi":"2026-03-03T00:00:00Z"}' "$(jq -sc '.[-1].span' "$kept/decisions.jsonl")"
printf '7\n' >> "$log"
kept2="$tmp_dir/kept2"
union_partition "$log" "$kept2" landings decisions 2>/dev/null; rc=$?
assert_eq "a pass that aborts returns non-zero" "nonzero" "$( (( rc != 0 )) && echo nonzero || echo zero)"
assert_eq "…and leaves no reader's file behind" "" "$(ls -A "$kept2" 2>/dev/null)"
union_partition "$log" "$tmp_dir/kept3" no-such-reader 2>/dev/null; rc=$?
assert_eq "an undeclared reader is refused" "nonzero" "$( (( rc != 0 )) && echo nonzero || echo zero)"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
