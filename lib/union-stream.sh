#!/usr/bin/env bash
#
# lib/union-stream.sh — reading the fleet event union as a stream rather than
# slurping it (agent-ops#1649). A `jq -s` over the union holds every parsed
# event in one process, about five bytes of resident memory per byte of a log
# `scripts/rotate-logs.sh` never rotates; the readers here hold only what a
# reader's answer is about.
#
# Three things live here, so each is written once:
#
#   UNION_STREAM_JQ      the jq definitions every streamed reader shares: the
#                        tolerant raw-line event stream, the span fold, the
#                        kept-events-then-span protocol, and the consumer-side
#                        peel of that protocol.
#   union_stream         one streamed pass over a union that keeps what a
#                        reader declares and closes with the span.
#   union_partition      one streamed pass that writes the kept events of
#                        several readers at once, each reader's from its own
#                        declaration (`union_reader_events`), so the union is
#                        parsed once for all of them rather than once each.
#
# A reader's event types are declared once — in `union_reader_events` for the
# Publisher's own readers, beside the program in its library for the others —
# and `test/union-stream.test.sh` fails when a reader's program reads an event
# type its declaration lacks, since such a read would otherwise see nothing
# and report a quiet zero.
#
# Sourced, never executed: no shell options are set here, matching every
# other lib/*.sh — the caller owns those. Sourced by agent-cycle.sh,
# review-cycle.sh, monitor-cycle.sh, scripts/node-health.sh and
# scripts/publish-dashboard.sh, and by lib/limit-detect.sh, lib/fleet-sizing.sh
# and lib/item-lifecycle.sh for their own readers; sourcing it twice is
# harmless, since it only defines.

# The tolerant raw-line event stream (#2037). The fleet union is every node's
# log concatenated, and one line in it may not parse — a record cut off
# part-way, a stump, a fragment a NUL run left — so a reader that must not go
# blind on such a line reads the input as raw lines (`jq -nR`) and parses each
# on its own:
#
#   union_raw_objects        every line that parses to an object, in order;
#                            a line that does not parse, or parses to
#                            anything else, is skipped. Plain `inputs` under
#                            `jq -n` aborts at the first such line, and a
#                            slurp (`jq -s`) aborts the whole read.
#   union_event_in(NAMES)    whether the record's `event` is one of NAMES (an
#                            array of strings); a record whose `event` is not
#                            a string is never wanted.
#   union_events(NAMES)      the objects whose `event` is one of NAMES: the
#                            stream every tolerant reader folds, so no two of
#                            them can skip a different set of lines.
#
# The membership test is a `reduce`, not `any`, `first` or `limit`: under jq
# 1.6 a `try` — which `fromjson?` is — swallows the `break` those are built
# on, so they do not stop where they should over a stream that holds one.

# The span is the least and the greatest of the timestamps a reader counts,
# folded as the stream passes. Two rules exist because the whole-array readers
# this replaces computed two different things, and each streamed reader keeps
# its own reader's rule so its output is unchanged:
#
#   any        `.ts // empty` — every timestamp but null and false, the empty
#              string included: what `[ .[] | .ts // empty ] | min`/`max` gave
#              the actor scorecards and the stage-gap series.
#   nonempty   `.ts // ""` without the empty string: what
#              `map(.ts // "") | map(select(. != "")) | sort | first`/`last`
#              gave the item-lifecycle window and the fleet-sizing window.
#
# A record counts towards the span only at or after `$since` (when `$since` is
# not empty), by `(.ts // "") >= $since`, the gate those two windowed readers
# apply. A record that is not an object aborts the fold, because `.ts` cannot
# index it — exactly where the whole-array reader failed — unless the caller
# drops non-objects first, as the two readers whose whole-array form dropped
# them do.
#
# The protocol: the kept records, one per line in log order, then one closing
# `{"span": {"lo": …, "hi": …}}` line. `union_split_span`, applied to the
# slurped lines, gives `{events, span}`; a stream that did not run to its end
# has no closing line, so a caller gates its slurp on the stream's exit status
# rather than folding a truncated log as though it were whole.
# shellcheck disable=SC2016  # jq's own $x/$t/$since, not the shell's.
UNION_STREAM_JQ='
  def union_raw_objects: inputs | fromjson? // empty | objects;
  def union_event_in($names):
    ((.event | strings) as $e | reduce $names[] as $n (false; . or $n == $e)) // false;
  def union_events($names): union_raw_objects | select(union_event_in($names));
  def union_ts_any: .ts // empty;
  def union_ts_nonempty: (.ts // "") | select(. != "");
  def union_span_add($e; ts; $since):
    reduce ($e | select($since == "" or ((.ts // "") >= $since)) | ts) as $t (.;
      .lo = (if .lo == null or $t < .lo then $t else .lo end)
      | .hi = (if .hi == null or $t > .hi then $t else .hi end));
  def union_kept_with_span(stream; keep; ts; $since):
    foreach ((stream | {e: .}), {end: true}) as $x ({lo: null, hi: null};
      if $x.end then . else union_span_add($x.e; ts; $since) end;
      if $x.end then {span: {lo: .lo, hi: .hi}} else ($x.e | keep) end);
  def union_split_span:
    {events: .[:-1], span: ((.[-1] // {}).span // {lo: null, hi: null})};
'

# union_stream SOURCE [OPTION...]
# Print SOURCE's kept records, one compact JSON value per line in log order,
# then the closing span line (UNION_STREAM_JQ's protocol). Exits non-zero, as
# jq does, when the stream aborts part-way. Options:
#
#   --raw              read SOURCE as raw lines, each through `fromjson? //
#                      empty`, for a union no `read_events` has cleaned: plain
#                      `inputs` aborts at the first spliced record. With
#                      --objects as well, the stream is UNION_STREAM_JQ's own
#                      `union_raw_objects`.
#   --objects          drop every record that is not an object first.
#   --events "A B …"   keep the records whose `event` is one of these — the
#                      reader's declaration, tested by `union_event_in`
#                      (`union_wanted` in a --keep filter reads the same
#                      list).
#   --keep FILTER      keep what FILTER outputs for each record, instead of
#                      every record --events names.
#   --defs TEXT        jq definitions FILTER uses.
#   --ts any|nonempty  which timestamps the span counts (default any).
#   --since ISO        count only records at or after ISO towards the span;
#                      `$since` is also bound for a --keep filter to use.
union_stream() {
  local src="$1"; shift
  local stream='inputs' keep='' defs='' ts='any' since='' names='' objects=0 raw=0
  local -a opts=(-nc)
  while (( $# > 0 )); do
    case "$1" in
      --raw)     opts=(-nRc); raw=1; shift ;;
      --objects) objects=1; shift ;;
      --events)  names="$2"; shift 2 ;;
      --keep)    keep="$2"; shift 2 ;;
      --defs)    defs="$2"; shift 2 ;;
      --ts)      ts="$2"; shift 2 ;;
      --since)   since="$2"; shift 2 ;;
      *) printf 'union_stream: unknown option %s\n' "$1" >&2; return 2 ;;
    esac
  done
  if (( raw && objects )); then
    stream='union_raw_objects'
  elif (( raw )); then
    stream='inputs | fromjson? // empty'
  elif (( objects )); then
    stream='inputs | objects'
  fi
  [[ -n "$keep" ]] || keep='select(union_wanted)'
  # shellcheck disable=SC2086  # NAMES is a word list by design.
  jq "${opts[@]}" --arg since "$since" "$UNION_STREAM_JQ $defs"'
    def union_wanted: union_event_in($ARGS.positional);
    def union_keep: '"$keep"';
    union_kept_with_span('"$stream"'; union_keep; union_ts_'"$ts"'; $since)' \
    "$src" --args $names
}

# union_reader_events READER
# Print the event types READER folds, one per line: the one declaration both
# `union_partition` and `test/union-stream.test.sh` read. These are the
# Publisher's own readers (`scripts/publish-dashboard.sh`), whose programs sit
# between `# union-reader: READER` and `# union-reader-end: READER` there;
# `open-blocked` and `void` are `lib/cycle-state.sh`'s readers, whose
# declarations stay beside their programs in that file and are only read here.
union_reader_events() {
  case "$1" in
    scorecards)
      printf '%s\n' corroboration item-refined none-selected pr-raised pr-ready rework selection stage-end ;;
    stage-gaps)
      printf '%s\n' review-stage-end stage-end ;;
    blocked-enrichment)
      printf '%s\n' enabler-examined escalated ;;
    landings)
      printf '%s\n' approver-verdict classifier-escape landing-armed landing-audit landing-audit-record \
        landing-refused merge-budget-frozen merge-budget-hold ;;
    decisions)
      printf '%s\n' decision-acted decision-taken decision-vetoed ;;
    escape-audits)
      printf '%s\n' classifier-escape landing-audit ;;
    github-budget)
      printf '%s\n' github-budget guard-degraded stand-down ;;
    open-blocked)
      # shellcheck disable=SC2086  # a word list by design.
      printf '%s\n' ${OPEN_BLOCKED_EVENTS:?lib/cycle-state.sh is not sourced} ;;
    void)
      # shellcheck disable=SC2086  # a word list by design.
      printf '%s\n' ${VOID_ITEMS_EVENTS:?lib/cycle-state.sh is not sourced} ;;
    *) return 1 ;;
  esac
}

# union_partition SOURCE DIR READER...
# One streamed pass over SOURCE (parsed JSON lines, as `read_events` writes
# them) that writes DIR/READER.jsonl for each READER: the records whose
# `event` `union_reader_events READER` declares, in log order, closed by the
# span line (rule `any`, over every record). A record is written once for each
# reader that declares its type. Returns non-zero, and removes every file it
# wrote, when the pass fails — a record that is not an object aborts it, as it
# aborted each whole-array reader — so a reader's own fallback runs on a
# missing file rather than folding a truncated one.
union_partition() {
  local src="$1" dir="$2" r ev
  shift 2
  local -a spec=()
  for r in "$@"; do
    ev="$(union_reader_events "$r")" || return 1
    spec+=("$r=${ev//$'\n'/ }")
  done
  mkdir -p "$dir" || return 1
  # shellcheck disable=SC2016  # jq's own $spec/$readers_of/$e, not the shell's.
  jq -nr "$UNION_STREAM_JQ"'
    [ $ARGS.positional[] | capture("^(?<r>[^=]+)=(?<ev>.*)$") ] as $spec
    | (reduce $spec[] as $s ({};
         reduce ($s.ev | splits(" +") | select(. != "")) as $e (.; .[$e] += [$s.r]))) as $readers_of
    | union_kept_with_span(inputs;
        . as $rec | (.event | strings) as $n | ($readers_of[$n] // [])[] | [., $rec];
        union_ts_any; "")
    | if type == "array" then .[0] + "\t" + (.[1] | tojson)
      else . as $span | $spec[] | .r + "\t" + ($span | tojson) end' \
    "$src" --args "${spec[@]}" \
  | awk -F'\t' -v d="$dir" '{ f = d "/" $1 ".jsonl"; print substr($0, length($1) + 2) > f }'
  if (( PIPESTATUS[0] != 0 || PIPESTATUS[1] != 0 )); then
    for r in "$@"; do rm -f "$dir/$r.jsonl"; done
    return 1
  fi
}
