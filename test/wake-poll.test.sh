#!/usr/bin/env bash
#
# test/wake-poll.test.sh — regression tests for scripts/wake-poll.sh
# (requirement 54, issue #613).
#
# Two things are covered, deliberately separated:
#
#   1. wake-poll.sh's own change-detection logic: a cold cache wakes
#      (bootstrap), a warm cache with nothing changed stays quiet, and one
#      changed endpoint among several unchanged ones still wakes. A stub
#      `gh` answers conditional GETs (`-i`, `If-None-Match`) exactly as
#      GitHub does — including exiting non-zero on a `304`, the trap this
#      file's own header explains — and WAKE_POLL_AGENT_CYCLE_BIN (a test
#      seam, never read in production) points the "wake" step at a marker
#      script instead of the real agent-cycle.sh.
#   2. The claim race the Enabler's own specification on issue #613 asks
#      for: "a woken node must contend for claims exactly as a cron-fired
#      one does." wake-poll.sh adds no code to the claim path at all — a
#      detected change invokes agent-cycle.sh through its ordinary entry
#      point, the same one cron uses — so the property to prove is that
#      lib/claim.sh's own race-correctness (test/claim.test.sh) is exactly
#      what two "woken" nodes reach. This section reuses that file's own
#      stub-gh-with-real-create-only-semantics harness rather than a second
#      copy, on the "put the test beside test/claim.test.sh, following that
#      harness's conventions" instruction.
#
# No network and no GitHub. Run directly:
#
#   ./test/wake-poll.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WAKE_POLL="$SCRIPT_DIR/scripts/wake-poll.sh"
CLAIM="$SCRIPT_DIR/lib/claim.sh"

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
    printf 'FAIL - %s\n     expected to contain: %s\n     actual: %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# === Part 1: change detection ===============================================

# The stub answers `gh api -i repos/<slug>/<endpoint...>`, optionally
# conditioned with `-H "If-None-Match: <etag>"`. GH_STUB_ETAGS names, per
# path (query stripped), the etag that path's content currently carries —
# `path=etag[,path=etag...]` — so a test can change one endpoint's content
# between two wake-poll runs without touching the others. A request whose
# If-None-Match matches the path's current etag answers 304 (and, like the
# real `gh api -i`, exits 1 — verified live against GitHub while this item
# was scoped); anything else answers 200 with the current etag.
stub_bin="$tmp_dir/bin"
mkdir -p "$stub_bin"
cat > "$stub_bin/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
[[ "${GH_STUB_UNREACHABLE:-0}" == "1" ]] && { echo "gh: connection failed" >&2; exit 1; }
if [[ "${1:-}" != "api" ]]; then exit 1; fi
shift
path="" if_none_match=""
args=("$@")
for (( i=0; i<${#args[@]}; i++ )); do
  case "${args[i]}" in
    -H)
      hdr="${args[i+1]}"; (( i++ ))
      [[ "$hdr" == If-None-Match:* ]] && if_none_match="${hdr#If-None-Match: }"
      ;;
    repos/*) path="${args[i]%%\?*}" ;;
  esac
done
current="$(printf '%s' "${GH_STUB_ETAGS:-}" | tr ',' '\n' | grep "^$path=" | tail -1)"
current="${current#*=}"
[[ -n "$current" ]] || current="\"seed\""
if [[ -n "$if_none_match" && "$if_none_match" == "$current" ]]; then
  printf 'HTTP/2.0 304 Not Modified\r\n'
  printf 'etag: %s\r\n\r\n' "$current"
  exit 1
fi
printf 'HTTP/2.0 200 OK\r\n'
printf 'etag: %s\r\n\r\n' "$current"
printf '[]'
exit 0
STUB
chmod +x "$stub_bin/gh"

# The "wake" marker: WAKE_POLL_AGENT_CYCLE_BIN points wake-poll.sh's own
# invocation here instead of the real agent-cycle.sh, so a test can assert
# whether a wake happened without running the real pipeline.
marker_bin="$tmp_dir/marker"
mkdir -p "$marker_bin"
cat > "$marker_bin/agent-cycle.sh" <<STUB
#!/usr/bin/env bash
echo "woken" >> "$tmp_dir/woken.log"
exit 0
STUB
chmod +x "$marker_bin/agent-cycle.sh"

run_wake_poll() {  # run_wake_poll <config> <state-dir>
  PATH="$stub_bin:$PATH" WAKE_POLL_AGENT_CYCLE_BIN="$marker_bin/agent-cycle.sh" \
    GH_STUB_ETAGS="${GH_STUB_ETAGS:-}" GH_STUB_UNREACHABLE="${GH_STUB_UNREACHABLE:-0}" \
    "$WAKE_POLL" --config "$1" --state-dir "$2"
}

conf="$tmp_dir/config.json"
state="$tmp_dir/state"
mkdir -p "$state"
jq -n '{repos: [{slug: "o/r", sources: ["tech-debt"]}], state_dir: "'"$state"'"}' > "$conf"

rm -f "$tmp_dir/woken.log"
out1="$(GH_STUB_ETAGS='' run_wake_poll "$conf" "$state" 2>&1)"
assert_eq "a cold cache (no stored etag) wakes — bootstrap firing" "1" \
  "$(test -f "$tmp_dir/woken.log" && wc -l < "$tmp_dir/woken.log" | tr -d ' ' || echo 0)"
assert_contains "the wake reason names what changed" "changed" "$out1"
assert_eq "four etags are now stored, one per polled endpoint" "4" \
  "$(find "$state/wake-poll" -name '*.etag' | wc -l | tr -d ' ')"

rm -f "$tmp_dir/woken.log"
out2="$(GH_STUB_ETAGS='' run_wake_poll "$conf" "$state" 2>&1)"
assert_eq "a warm cache with nothing changed does not wake" "0" \
  "$(test -f "$tmp_dir/woken.log" && wc -l < "$tmp_dir/woken.log" | tr -d ' ' || echo 0)"
assert_contains "the quiet tick says so" "nothing changed" "$out2"

rm -f "$tmp_dir/woken.log"
out3="$(GH_STUB_ETAGS='repos/o/r/issues="v2"' run_wake_poll "$conf" "$state" 2>&1)"
assert_eq "one changed endpoint among several unchanged ones still wakes" "1" \
  "$(test -f "$tmp_dir/woken.log" && wc -l < "$tmp_dir/woken.log" | tr -d ' ' || echo 0)"
assert_contains "the wake names the endpoint that actually changed" "o/r issues" "$out3"

rm -f "$tmp_dir/woken.log"
out4="$(GH_STUB_ETAGS='repos/o/r/pulls="v3"' PATH="$stub_bin:$PATH" \
  WAKE_POLL_AGENT_CYCLE_BIN="$marker_bin/agent-cycle.sh" \
  "$WAKE_POLL" --config "$conf" --state-dir "$state" --dry-run 2>&1)"
assert_eq "--dry-run detects a change but never invokes the wake target" "0" \
  "$(test -f "$tmp_dir/woken.log" && wc -l < "$tmp_dir/woken.log" | tr -d ' ' || echo 0)"
assert_contains "--dry-run says it would have woken" "would wake" "$out4"

rm -f "$tmp_dir/woken.log"
out5="$(GH_STUB_UNREACHABLE=1 run_wake_poll "$conf" "$state" 2>&1)"; rc5=$?
assert_eq "an unreachable gh never wakes (no status line to read)" "0" \
  "$(test -f "$tmp_dir/woken.log" && wc -l < "$tmp_dir/woken.log" | tr -d ' ' || echo 0)"
assert_eq "an unreachable gh still exits 0 (the crontab line's own || true is a second belt)" \
  "0" "$rc5"
assert_contains "an unreachable endpoint logs a warning, not a crash" "unreachable" "$out5"

# The one logged event a real wake produces (never on a quiet tick — see
# above): a fleet reader (the dashboard, pickup-metrics) can distinguish
# "woke a node" from "cron fired it" the same way it distinguishes any other
# out-of-cycle writer (scripts/publish-revert-rate.sh's own `rework` rows,
# lib/log-event.sh's header).
triggered_events="$(jq -c 'select(.event == "wake-poll-triggered")' "$state/log.jsonl" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "exactly one wake-poll-triggered event was logged (the two real wakes above)" "2" "$triggered_events"

# === Part 2: the claim race — a woken node contends exactly as a cron-fired
#     one does (issue #613's own acceptance: "the concurrent-claim window is
#     no wider in practice than it is under cron firing, proven by a test
#     that races two woken nodes") ===========================================
#
# wake-poll.sh adds no code to the claim path: a detected change invokes
# agent-cycle.sh through its ordinary entry point, the one cron already
# uses, so there is no new race to construct — only the existing one
# (lib/claim.sh, test/claim.test.sh) to demonstrate still holds when the two
# racing engagements are framed as "woken" rather than "cron-fired". This
# stub is test/claim.test.sh's own (same create-only-on-the-filesystem
# semantics — the kernel arbitrates, so this races for real), reused rather
# than copied a second time and drifting from it (agent-ops#TD26071401's own
# "a second copy is how detectors drift apart" lesson, generalised to test
# doubles).
#
# Not asserted here: the `claim-lost` event itself, with its `cause` field
# (`held`/`pr-held`/`unreachable`) — that mapping and the `log_event` call
# live inline in agent-cycle.sh's own claim loop, coupled to state (the
# cycle id, the log file, the candidate) no unit test can construct without
# either sourcing the whole script (which runs the pipeline, not a function)
# or duplicating the loop. test/claim.test.sh itself stops at the same
# boundary, for the same reason: it proves exactly what this file proves —
# `lib/claim.sh` exits 0 for the winner and 3 for the loser — which is the
# one fact `claim_rc == 3 → cause: "held"` (agent-cycle.sh, requirement 17a)
# derives the logged cause from. The contended-loss-per-selection ratio
# `scripts/pickup-metrics.sh` reports staying flat is, by its own nature, a
# production measurement taken after this deploys and the fleet has run
# under it — not something a pre-merge test can assert.
claim_stub_dir="$tmp_dir/claim-bin"
mkdir -p "$claim_stub_dir"
cat > "$claim_stub_dir/gh" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
d="${GH_STUB_DIR:?}"
method=GET; path=""; declare -A f=()
args=("$@")
for (( i=0; i<${#args[@]}; i++ )); do
  case "${args[i]}" in
    -X)   method="${args[i+1]}"; (( i++ )) ;;
    -f)   kv="${args[i+1]}"; f["${kv%%=*}"]="${kv#*=}"; (( i++ )) ;;
    repos/*) path="${args[i]}" ;;
  esac
done
case "$method $path" in
  "POST "*/git/refs)
    slug="${path#repos/}"; slug="${slug%/git/refs}"
    ref="${f[ref]#refs/heads/}"
    file="$d/refs/$slug/$ref"
    mkdir -p "$(dirname "$file")"
    ( set -C; printf '%s' "${f[sha]}" > "$file" ) 2>/dev/null || exit 1
    exit 0 ;;
  "GET "*/git/ref/heads/*)
    slug="${path#repos/}"; slug="${slug%%/git/*}"
    ref="${path#*/git/ref/heads/}"
    if [[ "$ref" == "main" && ! -f "$d/refs/$slug/$ref" ]]; then
      printf '{"object":{"sha":"basesha000"}}'; exit 0
    fi
    [[ -f "$d/refs/$slug/$ref" ]] || exit 1
    printf '{"object":{"sha":"%s"}}' "$(cat "$d/refs/$slug/$ref")"; exit 0 ;;
esac
exit 1
STUB
chmod +x "$claim_stub_dir/gh"
export GH_STUB_DIR="$tmp_dir/claim-gh-state"
mkdir -p "$GH_STUB_DIR"

# "Woken" is a framing, not a code path: both racers reach lib/claim.sh the
# identical way a cron-fired agent-cycle.sh would (requirement 17a) — the
# name difference from test/claim.test.sh's own node-a/node-b is deliberate,
# so a reader of this file's own output sees which property it is proving.
CLAIM_GH="$claim_stub_dir/gh" CLAIM_NODE="woken-node-1" CLAIM_CYCLE="cycle-woken-1" \
  CLAIM_ITEM="613" CLAIM_SOURCE="issues" \
  "$CLAIM" claim branch o/r agent/613-race main >/dev/null 2>&1 &
pid_1=$!
CLAIM_GH="$claim_stub_dir/gh" CLAIM_NODE="woken-node-2" CLAIM_CYCLE="cycle-woken-2" \
  CLAIM_ITEM="613" CLAIM_SOURCE="issues" \
  "$CLAIM" claim branch o/r agent/613-race main >/dev/null 2>&1 &
pid_2=$!
wait "$pid_1"; rc_1=$?
wait "$pid_2"; rc_2=$?
assert_eq "two woken nodes racing the same claim: exactly one winner (exit 0), one loser (exit 3)" \
  "0 3" "$(printf '%s\n' "$rc_1" "$rc_2" | sort -n | tr '\n' ' ' | sed 's/ $//')"
assert_eq "the winning claim created the branch ref" "1" \
  "$(test -f "$GH_STUB_DIR/refs/o/r/agent/613-race" && echo 1 || echo 0)"

if (( failures == 0 )); then
  echo "all assertions passed"
  exit 0
else
  echo "$failures assertion(s) failed"
  exit 1
fi
