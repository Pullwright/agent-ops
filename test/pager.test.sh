#!/usr/bin/env bash
#
# test/pager.test.sh — lib/pager.sh's own framework: the registry, the
# event-sourced state machine (clear/candidate/fired), and the three remedy
# classes (agent-ops#1278).
#
# Everything with a side effect outside the process is stubbed: `gh` (issue
# list/create/close), and a stand-in for lib/claim.sh's own `claim file`
# dispatch — controllable via CLAIM_STUB_RC — since this file's own job is
# pager.sh's state machine, not lib/claim.sh's contention behaviour (covered
# by test/claim.test.sh). A pipeline-act remedy function is stubbed too, with
# its call count tracked through a file rather than a plain variable, on
# test/crash-loop-escalate.test.sh's own precedent: every real call site
# invokes it via command substitution, a subshell a plain variable set inside
# would not survive.
#
# No test framework is used (none exists elsewhere in this repo). Run it
# directly:
#
#   ./test/pager.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/pager.sh
. "$SCRIPT_DIR/lib/pager.sh"

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

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# --- Test doubles ------------------------------------------------------------

CLAIM_STUB="$WORKDIR/claim-stub.sh"
cat > "$CLAIM_STUB" <<'EOF'
#!/usr/bin/env bash
exit "${CLAIM_STUB_RC:-0}"
EOF
chmod +x "$CLAIM_STUB"

GH_CALLS_FILE="$WORKDIR/gh-calls"
: > "$GH_CALLS_FILE"
STUB_GH_LIST_OPEN="[]"     # `gh issue list --state open ...` result
STUB_GH_LIST_ALL="[]"      # `gh issue list --state all ...` result (decision-log dedup)
STUB_GH_CREATE_URL="https://github.com/o/r/issues/501"
STUB_GH_CREATE_FAIL=""
STUB_GH_CLOSE_MODE="success"
# Every real call site invokes `gh` through a command substitution
# ($(...)), a subshell — so anything this stub needs a later assertion to
# see must go through a file, on test/crash-loop-escalate.test.sh's own
# precedent, never a plain variable, which would vanish with the subshell.
STUB_GH_LAST_BODY_FILE="$WORKDIR/gh-last-body"
: > "$STUB_GH_LAST_BODY_FILE"
gh() {
  printf '%s\n' "$*" >> "$GH_CALLS_FILE"
  case "$1 $2" in
    "issue list")
      if [[ " $* " == *" all "* ]]; then printf '%s' "$STUB_GH_LIST_ALL"
      else printf '%s' "$STUB_GH_LIST_OPEN"; fi
      return 0 ;;
    "issue create")
      # Capture the --body-file's own content, the way a real create would
      # read it, so a test can assert on what actually went into the issue.
      local a next=""
      for a in "$@"; do
        if [[ "$next" == "body-file" ]]; then cat "$a" > "$STUB_GH_LAST_BODY_FILE" 2>/dev/null || true; next=""; fi
        [[ "$a" == "--body-file" ]] && next="body-file"
      done
      [[ -z "$STUB_GH_CREATE_FAIL" ]] || return 1
      printf 'created: %s\n' "$STUB_GH_CREATE_URL"
      return 0 ;;
    "issue close")
      [[ "$STUB_GH_CLOSE_MODE" == "success" ]] ;;
    *) return 1 ;;
  esac
}

REMEDY_CALLS_FILE="$WORKDIR/remedy-calls"
: > "$REMEDY_CALLS_FILE"
STUB_REMEDY_OUTPUT="did the thing"
STUB_REMEDY_FAIL=""
stub_remedy() {
  printf 'x\n' >> "$REMEDY_CALLS_FILE"
  [[ -z "$STUB_REMEDY_FAIL" ]] || return 1
  printf '%s' "$STUB_REMEDY_OUTPUT"
}
remedy_calls() { wc -l < "$REMEDY_CALLS_FILE" | tr -d ' '; }

STUB_FIRING="true"
STUB_EVIDENCE="the sky is falling"
stub_eval() {
  if [[ "$STUB_FIRING" == "true" ]]; then
    jq -nc --arg e "$STUB_EVIDENCE" '{firing: true, evidence: $e}'
  else
    printf '{"firing":false}'
  fi
}

count_events() {  # count_events LOG_FILE EVENT_NAME [KEY]
  local log="$1" name="$2" key="${3:-}"
  jq -R -n --arg n "$name" --arg k "$key" \
    '[inputs | select(length>0) | fromjson? // empty
      | select(.event == $n and ($k == "" or (.key // "") == $k))] | length' \
    < "$log" 2>/dev/null
}
last_event() {  # last_event LOG_FILE EVENT_NAME KEY
  local log="$1" name="$2" key="$3"
  jq -R -n --arg n "$name" --arg k "$key" \
    '[inputs | select(length>0) | fromjson? // empty
      | select(.event == $n and (.key // "") == $k)] | sort_by(.ts) | last // empty' \
    < "$log" 2>/dev/null
}

# --- pager_register -----------------------------------------------------------

PAGER_EVAL_FN=(); PAGER_REMEDY_CLASS=(); PAGER_REMEDY_ARG=(); PAGER_KEYS=()
if pager_register "" stub_eval pipeline-act "" 2>/dev/null; then
  printf 'FAIL - an empty key is refused\n'; failures=$(( failures + 1 ))
else
  printf 'ok   - an empty key is refused\n'
fi
if pager_register k1 stub_eval nonsense-class "" 2>/dev/null; then
  printf 'FAIL - an unknown remedy class is refused\n'; failures=$(( failures + 1 ))
else
  printf 'ok   - an unknown remedy class is refused\n'
fi
# agent-ops#2600: a key outside ^[A-Za-z0-9-]+$ would register fine but
# lib/pager-invariants.sh's _pager_page_key extraction truncates it at the
# first disallowed character, so it can never match this registry again.
# Refused loudly at registration instead.
if pager_register foo_bar stub_eval pipeline-act "" 2>/dev/null; then
  printf 'FAIL - a key outside ^[A-Za-z0-9-]+$ is refused\n'; failures=$(( failures + 1 ))
else
  printf 'ok   - a key outside ^[A-Za-z0-9-]+$ is refused\n'
fi
assert_eq "  ... and it is not added to the registry" "" "$(pager_registered_keys | tr '\n' ' ' | sed 's/ $//')"
pager_register k1 stub_eval pipeline-act stub_remedy
pager_register k2 stub_eval owner-only "decide this"
assert_eq "registered keys, in registration order" "k1 k2" "$(pager_registered_keys | tr '\n' ' ' | sed 's/ $//')"
pager_register k1 stub_eval owner-only "changed my mind"
assert_eq "re-registering a key replaces it rather than duplicating" "k1 k2" "$(pager_registered_keys | tr '\n' ' ' | sed 's/ $//')"
assert_eq "  ... and the new registration wins" "owner-only" "${PAGER_REMEDY_CLASS[k1]}"

# A fifth, optional argument (agent-ops#1282) — MIN_FIRING_MINUTES_OVERRIDE,
# `node-stale`'s own per-key filing-hysteresis override — records against the
# key; omitted (every call above), it stays empty rather than absent, so
# _pager_evaluate_one's own `${...:-}` lookup falls through to
# pager_evaluate's shared parameter unchanged.
assert_eq "an omitted override records as empty, not unset" "" "${PAGER_MIN_FIRING_MINUTES_OVERRIDE[k1]}"
pager_register k3 stub_eval owner-only "decide this too" 180
assert_eq "a given override records against the key" "180" "${PAGER_MIN_FIRING_MINUTES_OVERRIDE[k3]}"

# The event declaration (agent-ops#2429): `pager_declare_events KEY
# [EVENT...]` records, against a registered key, the event types its EVAL_FN
# reads from the union, and `_pager_evaluate_one` hands it the union reduced
# to those. A companion call rather than a sixth positional argument, because
# the distinction the design turns on — a key declared with *no* types, whose
# EVAL_FN reads nothing from the union and gets an empty file, against a key
# with no declaration, which gets the whole union — is one an omitted and an
# empty trailing argument cannot carry, both reading as "".
assert_eq "a registered key starts with no declaration" "no" \
  "$([[ -v "PAGER_EVAL_EVENTS[k1]" ]] && echo yes || echo no)"
pager_declare_events k1 cycle-start cycle-end
assert_eq "a declaration records the key's event types, as a word list" "cycle-start cycle-end" \
  "${PAGER_EVAL_EVENTS[k1]}"
pager_declare_events k2
assert_eq "a key declared with no types records an empty declaration, present rather than absent" "yes" \
  "$([[ -v "PAGER_EVAL_EVENTS[k2]" && -z "${PAGER_EVAL_EVENTS[k2]}" ]] && echo yes || echo no)"
if pager_declare_events k9 cycle-start 2>/dev/null; then
  printf 'FAIL - a declaration for an unregistered key is refused\n'; failures=$(( failures + 1 ))
else
  printf 'ok   - a declaration for an unregistered key is refused\n'
fi
pager_register k1 stub_eval owner-only "changed my mind again"
assert_eq "re-registering a key clears its declaration, since a declaration describes the EVAL_FN it was made with" \
  "no" "$([[ -v "PAGER_EVAL_EVENTS[k1]" ]] && echo yes || echo no)"

# --- pager_state_for / pager_last_event ---------------------------------------

state_fixture="$WORKDIR/state-fixture.jsonl"
: > "$state_fixture"
assert_eq "no events at all reads clear" "clear" "$(pager_state_for demo < "$state_fixture")"
printf '{"ts":"2026-01-01T00:00:00Z","event":"pager-candidate","key":"demo","first_seen":"2026-01-01T00:00:00Z"}\n' >> "$state_fixture"
assert_eq "a candidate event reads candidate" "candidate" "$(pager_state_for demo < "$state_fixture")"
printf '{"ts":"2026-01-01T00:05:00Z","event":"pager-candidate-cleared","key":"demo"}\n' >> "$state_fixture"
assert_eq "a candidate-cleared event resets to clear" "clear" "$(pager_state_for demo < "$state_fixture")"
printf '{"ts":"2026-01-01T00:10:00Z","event":"pager-fired","key":"demo","first_seen":"2026-01-01T00:10:00Z","evidence":"x"}\n' >> "$state_fixture"
assert_eq "a fired event reads fired" "fired" "$(pager_state_for demo < "$state_fixture")"
printf '{"ts":"2026-01-01T00:20:00Z","event":"pager-cleared","key":"demo","cleared_at":"2026-01-01T00:20:00Z"}\n' >> "$state_fixture"
assert_eq "a cleared event reads clear again" "clear" "$(pager_state_for demo < "$state_fixture")"
assert_eq "a different key's events are ignored" "clear" "$(pager_state_for other < "$state_fixture")"

# --- pager_events_extract (agent-ops#2429) -----------------------------------
# What `pager_evaluate` and the Publisher's own `pager` array read in place of
# the whole union: it must carry every pager event, and nothing a state read
# could mistake for one. The decoys are the three shapes the prefilter alone
# would get wrong — a record of another type whose nested object carries
# `"event":"pager-fired"` (built with `jq -nc`, so it is compact exactly as a
# real record is; a string field could not carry it, since JSON escapes the
# quotes inside a string), a spliced line, and a blank line.
extract_in="$WORKDIR/extract-in.jsonl"
{
  printf '{"ts":"2026-01-01T00:00:00Z","event":"cycle-start","node":"n1","cycle":"c0"}\n'
  cat "$state_fixture"
  jq -nc '{ts: "2026-01-01T00:30:00Z", event: "escalated", node: "n1", key: "demo",
           record: {event: "pager-fired", key: "demo"}}'
  printf '{"ts":"2026-01-01T00:40:00Z","event":"pager-fired","key":"spliced"}{"ts":"2026-01-01T00:41:00Z","event":"pager-cleared","key":"spliced"}\n'
  printf '\n'
  printf '{"ts":"2026-01-01T00:50:00Z","event":"pager-candidate","key":"other","first_seen":"2026-01-01T00:50:00Z"}\n'
} > "$extract_in"
extract_out="$WORKDIR/extract-out.jsonl"
pager_events_extract < "$extract_in" > "$extract_out"
extract_rc=$?
assert_eq "the extract exits 0 over a union with pager events in it" "0" "$extract_rc"
assert_eq "the extract keeps the four pager event types, in log order, and nothing else" \
  "pager-candidate pager-candidate-cleared pager-fired pager-cleared pager-candidate" \
  "$(jq -r '.event' "$extract_out" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "  ... a record of another type carrying the prefilter's substring in a nested object is dropped" \
  "0" "$(grep -c '"event":"escalated"' "$extract_out")"
assert_eq "  ... a spliced line is dropped whole, the tolerance every union reader has" \
  "0" "$(grep -c 'spliced' "$extract_out")"
assert_eq "  ... and every kept line is one compact object" \
  "5" "$(jq -c 'objects' "$extract_out" | wc -l | tr -d ' ')"
assert_eq "a union with no pager event at all extracts to nothing, with exit status 0 (grep's 1 is not a failure)" \
  "0 0" "$(out="$(printf '{"ts":"2026-01-01T00:00:00Z","event":"cycle-start"}\n' | pager_events_extract)"; printf '%s %s' "$?" "${#out}")"
assert_eq "  ... and so does an empty one" \
  "0 0" "$(out="$(pager_events_extract < /dev/null)"; printf '%s %s' "$?" "${#out}")"

# `pager_state_for` over the extract must equal `pager_state_for` over the raw
# union at every point of the state machine above — compared over every prefix
# of the decoy-laden union, so clear, candidate, clear again, fired and clear
# again are each compared, with the decoys in play.
raw_states=""; extract_states=""
extract_prefix="$WORKDIR/extract-prefix.jsonl"
for (( n = 0; n <= $(wc -l < "$extract_in"); n++ )); do
  head -n "$n" "$extract_in" > "$extract_prefix"
  raw_states+="$(pager_state_for demo < "$extract_prefix") "
  extract_states+="$(pager_events_extract < "$extract_prefix" | pager_state_for demo) "
done
assert_eq "pager_state_for over the extract equals pager_state_for over the raw union at every prefix" \
  "$raw_states" "$extract_states"
assert_eq "  ... and that walk is the state machine itself, undisturbed by the decoys" \
  "clear clear candidate clear fired clear clear clear clear clear " "$raw_states"

# --- pager_evaluate over a union carrying a decoy nested record ---------------
# The extract is what the state reads inside `_pager_evaluate_one` consult, so
# a decoy must not read as a fired key there either; and the extract must be
# rebuilt per call, so tick 2 sees the candidate tick 1 appended. TMPDIR is
# pointed at WORKDIR for the calls, so the extract's own removal can be seen.
PAGER_EVAL_FN=(); PAGER_REMEDY_CLASS=(); PAGER_REMEDY_ARG=(); PAGER_KEYS=()
pager_register decoyed stub_eval pipeline-act stub_remedy
union_log="$WORKDIR/decoy.jsonl"
jq -nc '{ts: "2026-01-01T00:00:00Z", event: "escalated", node: "n1", key: "decoyed",
         record: {event: "pager-fired", key: "decoyed"}}' > "$union_log"
: > "$GH_CALLS_FILE"; : > "$REMEDY_CALLS_FILE"
STUB_FIRING="true"; STUB_GH_CREATE_FAIL=""; STUB_GH_LIST_OPEN="[]"; STUB_GH_LIST_ALL="[]"
TMPDIR="$WORKDIR" pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1
assert_eq "tick 1 over a decoy: the key reads clear and becomes a candidate, never fired" \
  "1 0" "$(printf '%s %s' "$(count_events "$union_log" pager-candidate decoyed)" \
                          "$(count_events "$union_log" pager-fired decoyed)")"
TMPDIR="$WORKDIR" pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1
assert_eq "tick 2: the extract is rebuilt per call, so the candidate tick 1 appended is seen and fires" \
  "fired" "$(pager_state_for decoyed < "$union_log")"
assert_eq "  ... the remedy ran exactly once" "1" "$(remedy_calls)"
assert_eq "  ... and the extract file is removed when the loop ends" "" \
  "$(ls "$WORKDIR"/pager-events.* 2>/dev/null)"

# --- The declared reduction: EVAL_FN is handed only the events its key declares
# (agent-ops#2429). A recording EVAL_FN keeps a copy of the UNION_LOG_FILE it
# was handed, the path it came by, and what PAGER_REMEDY_UNION_LOG_FILE named
# at the time. Three keys, each registered and evaluated alone so its
# recording is its own: one declared, one undeclared, one declared with no
# types. The union carries two declared types, two undeclared ones, and a
# record of another type carrying `"event":"cycle-start"` in a nested object
# — the one shape that passes the byte-level prefilter, which an EVAL_FN's
# own `select` is what drops. TMPDIR is pointed at WORKDIR so the input
# file's own removal can be seen.
SEEN_INPUT="$WORKDIR/seen-input.jsonl"; SEEN_PATH="$WORKDIR/seen-path"; SEEN_REMEDY="$WORKDIR/seen-remedy"
# shellcheck disable=SC2317  # invoked by lib/pager.sh's _pager_evaluate_one by name, which a static reader does not follow
recording_eval() {
  cp "$2" "$SEEN_INPUT" 2>/dev/null || : > "$SEEN_INPUT"
  printf '%s' "$2" > "$SEEN_PATH"
  printf '%s' "${PAGER_REMEDY_UNION_LOG_FILE:-}" > "$SEEN_REMEDY"
  printf '{"firing":false}'
}
union_log="$WORKDIR/declared.jsonl"
cat > "$union_log" <<'EOF'
{"ts":"2026-01-01T00:00:00Z","event":"cycle-start","node":"n1","cycle":"c1"}
{"ts":"2026-01-01T00:01:00Z","event":"merge-observed","node":"n1","cycle":"c1","repo":"o/r","item":"1"}
{"ts":"2026-01-01T00:02:00Z","event":"stage-end","node":"n1","cycle":"c1","stage":"coordinator","exit_code":0}
{"ts":"2026-01-01T00:03:00Z","event":"log-repaired","node":"n1","nested":{"event":"cycle-start"}}
{"ts":"2026-01-01T00:04:00Z","event":"cycle-end","node":"n1","cycle":"c1","exit_code":0}
EOF
PAGER_EVAL_FN=(); PAGER_REMEDY_CLASS=(); PAGER_REMEDY_ARG=(); PAGER_KEYS=(); PAGER_EVAL_EVENTS=()
pager_register declared recording_eval owner-only "decide this"
pager_declare_events declared cycle-start cycle-end
TMPDIR="$WORKDIR" pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1
assert_eq "a declared key's EVAL_FN is handed the lines of its declared types, in log order, the nested decoy among them" \
  "cycle-start log-repaired cycle-end" "$(jq -r '.event' "$SEEN_INPUT" | tr '\n' ' ' | sed 's/ $//')"
assert_eq "  ... as a file under TMPDIR, never the union by its own path" "yes" \
  "$([[ "$(cat "$SEEN_PATH")" == "$WORKDIR"/pager-input.* ]] && echo yes || echo "no ($(cat "$SEEN_PATH"))")"
assert_eq "  ... removed once the evaluation has returned" "" "$(ls "$WORKDIR"/pager-input.* 2>/dev/null)"
assert_eq "  ... while PAGER_REMEDY_UNION_LOG_FILE still names the whole union" "$union_log" "$(cat "$SEEN_REMEDY")"
assert_eq "  ... and the union itself is untouched" "5" "$(wc -l < "$union_log" | tr -d ' ')"

PAGER_EVAL_FN=(); PAGER_REMEDY_CLASS=(); PAGER_REMEDY_ARG=(); PAGER_KEYS=(); PAGER_EVAL_EVENTS=()
pager_register undeclared recording_eval owner-only "decide this"
TMPDIR="$WORKDIR" pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1
assert_eq "an undeclared key's EVAL_FN is handed the whole union, by its own path" "$union_log" "$(cat "$SEEN_PATH")"
assert_eq "  ... every line of it" "5" "$(wc -l < "$SEEN_INPUT" | tr -d ' ')"

PAGER_EVAL_FN=(); PAGER_REMEDY_CLASS=(); PAGER_REMEDY_ARG=(); PAGER_KEYS=(); PAGER_EVAL_EVENTS=()
pager_register nothing recording_eval owner-only "decide this"
pager_declare_events nothing
TMPDIR="$WORKDIR" pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1
assert_eq "a key declared with no types is handed an empty file" "0" "$(wc -c < "$SEEN_INPUT" | tr -d ' ')"
assert_eq "  ... not the union" "yes" "$([[ "$(cat "$SEEN_PATH")" != "$union_log" ]] && echo yes || echo no)"
assert_eq "  ... and it too is removed afterwards" "" "$(ls "$WORKDIR"/pager-input.* 2>/dev/null)"

# A prefilter that fails — here, a union that cannot be read — leaves the
# whole union in place, so the EVAL_FN sees what it always saw rather than
# a reduction of nothing. stderr is silenced because the state reads' own
# redirections from the missing file say so too, as they always have.
PAGER_EVAL_FN=(); PAGER_REMEDY_CLASS=(); PAGER_REMEDY_ARG=(); PAGER_KEYS=(); PAGER_EVAL_EVENTS=()
pager_register declared recording_eval owner-only "decide this"
pager_declare_events declared cycle-start
TMPDIR="$WORKDIR" pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 0 "$WORKDIR/own.jsonl" "$WORKDIR/missing-union.jsonl" '[]' n1 c1 2>/dev/null
assert_eq "a prefilter that fails leaves the whole union in place, by its own path" \
  "$WORKDIR/missing-union.jsonl" "$(cat "$SEEN_PATH")"
assert_eq "  ... and leaves no input file behind" "" "$(ls "$WORKDIR"/pager-input.* 2>/dev/null)"

# --- End to end: fire (candidate) -> hysteresis -> fired -> clear ------------
# One invariant, pipeline-act, min_firing_minutes 0 so the very first
# candidate evaluation is already past hysteresis on the next tick.

PAGER_EVAL_FN=(); PAGER_REMEDY_CLASS=(); PAGER_REMEDY_ARG=(); PAGER_KEYS=()
pager_register demo stub_eval pipeline-act stub_remedy

union_log="$WORKDIR/e2e.jsonl"
: > "$union_log"
: > "$GH_CALLS_FILE"; : > "$REMEDY_CALLS_FILE"
STUB_FIRING="true"; STUB_GH_CREATE_FAIL=""; STUB_GH_LIST_OPEN="[]"; STUB_GH_LIST_ALL="[]"

pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1
assert_eq "tick 1 (first firing): one pager-candidate, nothing filed" \
  "1" "$(count_events "$union_log" pager-candidate demo)"
assert_eq "  ... no issue created yet" "0" "$(remedy_calls)"
assert_eq "  ... and not yet fired" "0" "$(count_events "$union_log" pager-fired demo)"

pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1
assert_eq "tick 2 (hysteresis 0, still firing): exactly one pager-fired" \
  "1" "$(count_events "$union_log" pager-fired demo)"
assert_eq "  ... the remedy function ran exactly once" "1" "$(remedy_calls)"
assert_eq "  ... its return value rode into the issue body" "1" \
  "$(grep -c "$STUB_REMEDY_OUTPUT" "$STUB_GH_LAST_BODY_FILE")"

# The tracking issue now "exists" on the fake GitHub — the close attempt
# below must find it via `gh issue list`, exactly as the real one would.
STUB_GH_LIST_OPEN="$(jq -nc --arg u "$STUB_GH_CREATE_URL" \
  '[{number: 501, url: $u, body: "ref: pager:demo", stateReason: null}]')"

pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1
assert_eq "tick 3 (still firing, already fired): no second pager-fired" \
  "1" "$(count_events "$union_log" pager-fired demo)"
assert_eq "  ... and no second remedy call" "1" "$(remedy_calls)"

STUB_FIRING="false"
pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1
assert_eq "tick 4 (fact clears): exactly one pager-cleared" \
  "1" "$(count_events "$union_log" pager-cleared demo)"
assert_eq "  ... the tracking issue got a close call" "1" \
  "$(grep -c '^issue close' "$GH_CALLS_FILE")"

pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1
assert_eq "tick 5 (still clear): no second pager-cleared" \
  "1" "$(count_events "$union_log" pager-cleared demo)"

# --- Hysteresis: a candidate that drops before the threshold is never filed -

PAGER_EVAL_FN=(); PAGER_REMEDY_CLASS=(); PAGER_REMEDY_ARG=(); PAGER_KEYS=()
pager_register blip stub_eval pipeline-act stub_remedy
union_log="$WORKDIR/blip.jsonl"; : > "$union_log"
: > "$REMEDY_CALLS_FILE"
STUB_FIRING="true"
pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 15 "$union_log" "$union_log" '[]' n1 c1
STUB_FIRING="false"
pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 15 "$union_log" "$union_log" '[]' n1 c1
assert_eq "a candidate that clears before the hysteresis threshold logs candidate-cleared" \
  "1" "$(count_events "$union_log" pager-candidate-cleared blip)"
assert_eq "  ... and is never filed" "0" "$(count_events "$union_log" pager-fired blip)"
assert_eq "  ... the remedy never ran" "0" "$(remedy_calls)"
assert_eq "  ... state is clear again" "clear" "$(pager_state_for blip < "$union_log")"

# --- Per-key MIN_FIRING_MINUTES override (agent-ops#1282) --------------------
# A key registered with its own override ignores pager_evaluate's own shared
# MIN_FIRING_MINUTES entirely: 0 would ordinarily file on the very next tick
# (the end-to-end case above), but a key overridden to 180 stays a candidate
# through a second tick regardless.

PAGER_EVAL_FN=(); PAGER_REMEDY_CLASS=(); PAGER_REMEDY_ARG=(); PAGER_KEYS=()
pager_register overridden stub_eval pipeline-act stub_remedy 180
union_log="$WORKDIR/override.jsonl"; : > "$union_log"
: > "$REMEDY_CALLS_FILE"
STUB_FIRING="true"
pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1
assert_eq "tick 1: still just a candidate" "candidate" "$(pager_state_for overridden < "$union_log")"
pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1
assert_eq "tick 2: the shared MIN_FIRING_MINUTES (0) is ignored — the override wins" \
  "0" "$(count_events "$union_log" pager-fired overridden)"
assert_eq "  ... still just a candidate" "candidate" "$(pager_state_for overridden < "$union_log")"
assert_eq "  ... the remedy never ran" "0" "$(remedy_calls)"

# --- A lost/unreachable claim never evaluates --------------------------------

PAGER_EVAL_FN=(); PAGER_REMEDY_CLASS=(); PAGER_REMEDY_ARG=(); PAGER_KEYS=()
pager_register locked stub_eval pipeline-act stub_remedy
union_log="$WORKDIR/locked.jsonl"; : > "$union_log"
CLAIM_STUB_RC=3 pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1
assert_eq "a lost claim (rc 3) evaluates nothing" "clear" "$(pager_state_for locked < "$union_log")"
CLAIM_STUB_RC=1 pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1
assert_eq "an unreachable claim (rc 1) evaluates nothing either — fail closed" "clear" "$(pager_state_for locked < "$union_log")"

# --- config-lever: a second, separate pw::decision record --------------------

PAGER_EVAL_FN=(); PAGER_REMEDY_CLASS=(); PAGER_REMEDY_ARG=(); PAGER_KEYS=()
pager_register lever stub_eval config-lever "raise the threshold"
union_log="$WORKDIR/lever.jsonl"; : > "$union_log"
: > "$GH_CALLS_FILE"
STUB_FIRING="true"; STUB_GH_LIST_OPEN="[]"; STUB_GH_LIST_ALL="[]"
pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1
pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1
assert_eq "config-lever: the tracking issue is filed unassigned" "0" \
  "$(grep -c -- '--assignee' "$GH_CALLS_FILE")"
assert_eq "  ... and a second create call files the pw::decision record" "2" \
  "$(grep -c '^issue create' "$GH_CALLS_FILE")"
assert_eq "  ... the decision record is filed under the pw::decision label" "1" \
  "$(grep '^issue create' "$GH_CALLS_FILE" | grep -c 'pw::decision')"
assert_eq "  ... which is then closed immediately (a log, not a request)" "1" \
  "$(grep -c '^issue close' "$GH_CALLS_FILE")"

# --- owner-only: the tracking issue is assigned -------------------------------

PAGER_EVAL_FN=(); PAGER_REMEDY_CLASS=(); PAGER_REMEDY_ARG=(); PAGER_KEYS=()
pager_register owner stub_eval owner-only "a human must decide this"
union_log="$WORKDIR/owner.jsonl"; : > "$union_log"
: > "$GH_CALLS_FILE"
STUB_FIRING="true"; STUB_GH_LIST_OPEN="[]"; STUB_GH_LIST_ALL="[]"
pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "the-owner" "" 0 "$union_log" "$union_log" '[]' n1 c1
pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "the-owner" "" 0 "$union_log" "$union_log" '[]' n1 c1
assert_eq "owner-only: the tracking issue is assigned to the configured assignee" "1" \
  "$(grep '^issue create' "$GH_CALLS_FILE" | grep -c -- '--assignee the-owner')"
assert_eq "  ... exactly one issue created, no separate decision record" "1" \
  "$(grep -c '^issue create' "$GH_CALLS_FILE")"

# --- pipeline-act: a failed remedy still records the failure honestly -------

PAGER_EVAL_FN=(); PAGER_REMEDY_CLASS=(); PAGER_REMEDY_ARG=(); PAGER_KEYS=()
pager_register broken stub_eval pipeline-act stub_remedy
union_log="$WORKDIR/broken.jsonl"; : > "$union_log"
: > "$GH_CALLS_FILE"; : > "$REMEDY_CALLS_FILE"
STUB_FIRING="true"; STUB_REMEDY_FAIL="1"; STUB_GH_LIST_OPEN="[]"; STUB_GH_LIST_ALL="[]"
pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1
pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1
assert_eq "a failing remedy still lets the tracking issue file" "1" \
  "$(count_events "$union_log" pager-fired broken)"
STUB_REMEDY_FAIL=""

# --- The pw::pager label is ensured on the create path, and only there -------
# Both the dedup search and the auto-close find a page *by* its label, so a
# page filed into a repository that has never carried `pw::pager` — which
# `pager_repo` is, by construction: it falls back to `crash_loop_repo`, which
# no cycle otherwise touches — would be re-filed on every later fire and
# never auto-closed. lib/enabler.sh's create_escalation_issue ensures the
# catalogue through labels_reconcile_role for exactly this reason;
# lib/pager.sh probes for `labels_reconcile_role` with `declare -F` so the
# rest of this file still runs without lib/labels.sh sourced at all.
ENSURE_CALLS_FILE="$WORKDIR/ensure-calls"; : > "$ENSURE_CALLS_FILE"
# shellcheck disable=SC2317  # invoked only by lib/pager.sh's _pager_ensure_label_role, behind its `declare -F` probe, which a static reader does not follow
labels_reconcile_role() { printf '%s\n' "$3 $4" >> "$ENSURE_CALLS_FILE"; }
ensure_calls() { wc -l < "$ENSURE_CALLS_FILE" | tr -d ' '; }

PAGER_EVAL_FN=(); PAGER_REMEDY_CLASS=(); PAGER_REMEDY_ARG=(); PAGER_KEYS=()
pager_register labelled stub_eval owner-only "a human must decide this"
union_log="$WORKDIR/labelled.jsonl"; : > "$union_log"
: > "$GH_CALLS_FILE"
STUB_FIRING="true"; STUB_GH_LIST_OPEN="[]"; STUB_GH_LIST_ALL="[]"
pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "the-owner" "" 0 "$union_log" "$union_log" '[]' n1 c1
pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "the-owner" "" 0 "$union_log" "$union_log" '[]' n1 c1
assert_eq "filing ensures the escalation label catalogue in pager_repo first" \
  "o/r escalation" "$(head -n1 "$ENSURE_CALLS_FILE")"
assert_eq "  ... exactly once, through labels_reconcile_role" "1" "$(ensure_calls)"

# The page now exists on the fake GitHub, so the next fire dedups onto it —
# and the ensure must not run again: it is a label listing per call, and the
# dedup path is the common one.
: > "$ENSURE_CALLS_FILE"
STUB_GH_LIST_OPEN="$(jq -nc '[{number: 501, url: "https://github.com/o/r/issues/501",
                               body: "ref: pager:labelled", stateReason: null}]')"
PAGER_EVAL_FN=(); PAGER_REMEDY_CLASS=(); PAGER_REMEDY_ARG=(); PAGER_KEYS=()
pager_register labelled2 stub_eval owner-only "a human must decide this"
union_log="$WORKDIR/labelled2.jsonl"; : > "$union_log"
printf '%s\n' '{"ts":"2026-01-01T00:00:00Z","event":"pager-candidate","key":"labelled2","first_seen":"2026-01-01T00:00:00Z"}' > "$union_log"
STUB_GH_LIST_OPEN="$(jq -nc '[{number: 502, url: "https://github.com/o/r/issues/502",
                               body: "ref: pager:labelled2", stateReason: null}]')"
pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "the-owner" "" 0 "$union_log" "$union_log" '[]' n1 c1
assert_eq "  ... and never on the dedup path, where the label already exists" \
  "0" "$(ensure_calls)"
unset -f labels_reconcile_role

# --- pager_repo empty: the transition is still logged, nothing is filed ------
# This is the whole reason `pager_enabled` is a boolean rather than reusing
# `pager_repo` empty as the off switch `crash_loop_repo` uses (requirement
# 51): an installation with nowhere to file still gets the fired/cleared
# history on its dashboard. An early return here instead would strand the key
# on `candidate` for ever — never firing, and never able to clear.

PAGER_EVAL_FN=(); PAGER_REMEDY_CLASS=(); PAGER_REMEDY_ARG=(); PAGER_KEYS=()
pager_register norepo stub_eval pipeline-act stub_remedy
union_log="$WORKDIR/norepo.jsonl"; : > "$union_log"
: > "$GH_CALLS_FILE"; : > "$REMEDY_CALLS_FILE"
STUB_FIRING="true"; STUB_GH_LIST_OPEN="[]"; STUB_GH_LIST_ALL="[]"
pager_evaluate "$CLAIM_STUB" "" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1
pager_evaluate "$CLAIM_STUB" "" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1
assert_eq "no pager_repo: the invariant still fires and the transition is logged" \
  "1" "$(count_events "$union_log" pager-fired norepo)"
assert_eq "  ... with a null issue_number, not a missing one" "null" \
  "$(jq -r '.issue_number | tostring' <<<"$(last_event "$union_log" pager-fired norepo)")"
assert_eq "  ... and a null issue_url" "null" \
  "$(jq -r '.issue_url | tostring' <<<"$(last_event "$union_log" pager-fired norepo)")"
assert_eq "  ... nothing was created on GitHub" "0" "$(grep -c '^issue create' "$GH_CALLS_FILE")"
assert_eq "  ... the state really is fired, not stranded on candidate" \
  "fired" "$(pager_state_for norepo < "$union_log")"
STUB_FIRING="false"
pager_evaluate "$CLAIM_STUB" "" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1
assert_eq "  ... and it can clear again, with nothing to close" \
  "1" "$(count_events "$union_log" pager-cleared norepo)"
assert_eq "  ... state back to clear" "clear" "$(pager_state_for norepo < "$union_log")"

# --- a stale peers view: no transition at all, one pager-evaluation-skipped -
# (agent-ops#2266) A node whose own peers marker is stale cannot tell its own
# broken fetch apart from a genuinely dark peer, so PEERS_STALE=true must
# make `pager_evaluate` skip every key outright — no candidate, no fired, no
# remedy call — rather than act on a reading it cannot trust.

PAGER_EVAL_FN=(); PAGER_REMEDY_CLASS=(); PAGER_REMEDY_ARG=(); PAGER_KEYS=()
pager_register peerstale stub_eval pipeline-act stub_remedy
union_log="$WORKDIR/peerstale.jsonl"; : > "$union_log"
: > "$REMEDY_CALLS_FILE"
STUB_FIRING="true"
pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1 \
  "" "" "" "" "" "" "" "" "" "" "" "" "" "" \
  "true" "2026-01-01T00:00:00Z"
assert_eq "peer view stale: no pager-candidate is written, even for a firing invariant" \
  "0" "$(count_events "$union_log" pager-candidate peerstale)"
assert_eq "  ... and no pager-fired either" "0" "$(count_events "$union_log" pager-fired peerstale)"
assert_eq "  ... the remedy never ran" "0" "$(remedy_calls)"
assert_eq "  ... state stays clear, as if this pass never happened" \
  "clear" "$(pager_state_for peerstale < "$union_log")"
assert_eq "  ... exactly one pager-evaluation-skipped is logged" "1" \
  "$(count_events "$union_log" pager-evaluation-skipped)"
assert_eq "  ... with reason peer-view-stale" "peer-view-stale" \
  "$(jq -r 'select(.event == "pager-evaluation-skipped") | .reason' "$union_log" 2>/dev/null)"
assert_eq "  ... and the marker's own last_ok_ts" "2026-01-01T00:00:00Z" \
  "$(jq -r 'select(.event == "pager-evaluation-skipped") | .last_ok_ts' "$union_log" 2>/dev/null)"

STUB_FIRING="true"
pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log" "$union_log" '[]' n1 c1
assert_eq "once the peers view is fresh again (PEERS_STALE omitted), evaluation resumes" \
  "1" "$(count_events "$union_log" pager-candidate peerstale)"

union_log2="$WORKDIR/peerstale-empty.jsonl"; : > "$union_log2"
pager_evaluate "$CLAIM_STUB" "o/r" "pw::pager" "enabler-escalation" \
  "" "" 0 "$union_log2" "$union_log2" '[]' n1 c1 \
  "" "" "" "" "" "" "" "" "" "" "" "" "" "" \
  "" ""
assert_eq "an empty PEERS_STALE (every call site before #2266) behaves exactly as omitted" \
  "1" "$(count_events "$union_log2" pager-candidate peerstale)"

# --- the notify guard leaves the exit status alone ----------------------------
# This file sources lib/pager.sh without lib/notify.sh, so `notify_post` is
# undefined for every assertion above — which is the whole point of the
# `declare -F` guard in `pager_file`/`pager_close` (issue #1279). The guard
# must also be invisible in the *exit status*: written as a `&&` list it
# carried its own failed left-hand side out as the function's result, so
# `pager_close` returned 1 on every standalone source and any caller under
# `set -e` died on it. Asserted in a `set -e` subshell, because `set -uo
# pipefail` alone (this file's own options, line 24) cannot see the fault.
assert_eq "notify_post is genuinely undefined here (the guard is under test)" \
  "" "$(declare -F notify_post 2>/dev/null || true)"
guard_log="$(mktemp)"
assert_eq "pager_close returns 0 when lib/notify.sh is not alongside" "0" \
  "$(pager_close gk "ev" "" "pw::pager" "$guard_log" n1 c1 >/dev/null 2>&1; printf '%s' "$?")"
assert_eq "  ... and a set -e caller survives the call" "survived" \
  "$(set -e; pager_close gk "ev" "" "pw::pager" "$guard_log" n1 c1 >/dev/null 2>&1; printf 'survived')"
assert_eq "  ... while still logging the pager-cleared transition" "2" \
  "$(count_events "$guard_log" pager-cleared gk)"
rm -f "$guard_log"

printf '\n'
if (( failures )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
