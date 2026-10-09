#!/usr/bin/env bash
#
# test/grok-subreaper.test.sh — deploy/docker/grok-subreaper.py contains a
# killed Grok Build run (issue #2134).
#
# Grok starts every `run_terminal_command` in its own session, so
# lib/stage-run.sh's own process-group kill (`kill -TERM -$pid`) ends Grok
# but leaves its last command running, reparented to PID 1 — unless Grok is
# launched under this wrapper, which sweeps whatever is left of it once it
# has set itself a child subreaper (`prctl(PR_SET_CHILD_SUBREAPER)`).
#
# Two shapes stand in for what the evaluation record
# (docs/reviews/2026-10-06-grok-build-evaluation.md, "Beyond the ten
# questions" section, "Containing them") found a real Grok run leaves
# behind: a `setsid` child (what Grok itself does to every command it
# starts) and a double-forked daemon that has changed directory away from
# where it was launched (the general case the record tested the mechanism
# against, before trusting it with Grok specifically). Neither needs the
# real `grok` binary: the wrapper's own containment does not know or care
# what its direct child actually is.
#
# Run directly: ./test/grok-subreaper.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WRAPPER="$SCRIPT_DIR/deploy/docker/grok-subreaper.py"

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

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

# --- 1. Ordinary passthrough: exit status, stdin, stdout --------------------

"$WRAPPER" true
assert_eq "a clean exit passes through unchanged" "0" "$?"

"$WRAPPER" bash -c 'exit 7'
assert_eq "a non-zero exit passes through unchanged" "7" "$?"

assert_eq "stdin reaches the wrapped command unchanged" \
  "hello" "$(printf 'hello' | "$WRAPPER" cat)"

# --- 2. Containment: a setsid child survives a direct SIGTERM to the
#     wrapper's own direct child, and the sweep still kills it ------------

cat >"$tmp_dir/spawn-setsid.sh" <<'EOF'
#!/bin/bash
setsid sleep 95 >/dev/null 2>&1 &
echo "$!" >"$MARK_DIR/setsid-pid"
sleep 95
EOF
chmod +x "$tmp_dir/spawn-setsid.sh"
MARK_DIR="$tmp_dir" "$WRAPPER" "$tmp_dir/spawn-setsid.sh" &
wrapper_pid=$!
# Poll for the mark file rather than a fixed sleep: the direct child needs a
# moment to fork and write it, and a fixed sleep either wastes time or, under
# contention, races it.
waited=0
while [[ ! -s "$tmp_dir/setsid-pid" ]] && (( waited < 50 )); do
  sleep 0.1
  waited=$(( waited + 1 ))
done
setsid_pid="$(cat "$tmp_dir/setsid-pid" 2>/dev/null || true)"
kill -TERM "$wrapper_pid" 2>/dev/null || true
wait "$wrapper_pid" 2>/dev/null
# The wrapper's own 2-second grace plus its sweep passes, bounded well under
# lib/stage-run.sh's 5-second TERM-then-KILL grace that this is sized to fit.
assert_eq "the setsid child is gone once the wrapper has returned" \
  "no" "$([[ -n "$setsid_pid" ]] && kill -0 "$setsid_pid" 2>/dev/null && echo yes || echo no)"

# --- 3. Containment: a double-forked daemon that changed directory --------

cat >"$tmp_dir/spawn-daemon.sh" <<'EOF'
#!/bin/bash
(
  cd /
  setsid bash -c 'sleep 95' </dev/null >/dev/null 2>&1 &
  echo "$!" >"$MARK_DIR/daemon-pid"
) &
disown
sleep 95
EOF
chmod +x "$tmp_dir/spawn-daemon.sh"
rm -f "$tmp_dir/daemon-pid"
MARK_DIR="$tmp_dir" "$WRAPPER" "$tmp_dir/spawn-daemon.sh" &
wrapper_pid=$!
waited=0
while [[ ! -s "$tmp_dir/daemon-pid" ]] && (( waited < 50 )); do
  sleep 0.1
  waited=$(( waited + 1 ))
done
daemon_pid="$(cat "$tmp_dir/daemon-pid" 2>/dev/null || true)"
kill -TERM "$wrapper_pid" 2>/dev/null || true
wait "$wrapper_pid" 2>/dev/null
assert_eq "the double-forked, directory-changed daemon is gone too" \
  "no" "$([[ -n "$daemon_pid" ]] && kill -0 "$daemon_pid" 2>/dev/null && echo yes || echo no)"

printf '\n'
if (( failures )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
