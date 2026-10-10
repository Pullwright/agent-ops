#!/usr/bin/env bash
#
# test/substrate-grok-build.test.sh — lib/substrate-grok-build.sh's own
# operations (issue #2134), on their own terms, with no real `grok` and no
# real stage boundary.
#
# What this guards, above everything else: `substrate_grok_build_exec`
# must never pass `/dev/stdin` as Grok's `--prompt-file` — a real failure
# this issue's own CI run caught (`Error: Failed to read '/dev/stdin':
# Permission denied`), because Grok opens that path by name, and re-opening
# a process's own stdin by path is a fresh `open()` the kernel checks
# against the *original* file's permission bits, which fail once `grok`
# crosses into the stage user a different one opened it as. The fix writes
# the prompt to a real file instead, group-readable by `stage`, and leans
# on the subreaper wrapper's `--cleanup` to remove it once Grok is done
# (`_exec` itself never returns to do that, since its last act is `exec`).
#
# The file's own mode is only half of that, and the other half is checked
# here too: the stage user has to traverse every directory on the path to
# reach the file at all, which the Script's own scratch directory (0700,
# `lib/scratch.sh`) refuses outright. So the prompt file belongs in
# `$GROK_HOME`, the one directory the image shares between the two users,
# and falls back to `$TMPDIR` only where there is no boundary — which is
# the case in this file, so the two destinations are asserted directly
# rather than through a real uid change.
#
# Run directly: ./test/substrate-grok-build.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected NOT to contain: %s\n     actual:   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# shellcheck source=lib/substrate-grok-build.sh
. "$SCRIPT_DIR/lib/substrate-grok-build.sh"

# A stand-in for deploy/docker/grok-subreaper.py: records its own argv, the
# content of whatever `--prompt-file` names, and whether that file could
# actually be read (the one thing the real bug broke), then exits 0. Never
# execs anything further — there is no real `grok` here.
stub="$tmp_dir/stub-subreaper.sh"
cat >"$stub" <<'EOF'
#!/usr/bin/env bash
{
  printf 'argv:'
  for a in "$@"; do printf ' [%s]' "$a"; done
  printf '\n'
  # The argument right after --prompt-file, wherever it falls.
  prompt_file=""
  for ((i = 1; i <= $#; i++)); do
    if [[ "${!i}" == --prompt-file ]]; then
      j=$(( i + 1 ))
      prompt_file="${!j}"
      break
    fi
  done
  if [[ -n "$prompt_file" && -r "$prompt_file" ]]; then
    printf 'prompt-file-readable: yes\n'
    printf 'prompt-file-content: %s\n' "$(cat "$prompt_file")"
  else
    printf 'prompt-file-readable: no\n'
  fi
} > "$STUB_CAPTURE"
exit 0
EOF
chmod +x "$stub"

capture="$tmp_dir/capture.txt"
export SUBSTRATE_GROK_BUILD_SUBREAPER="$stub"
export STUB_CAPTURE="$capture"

( substrate_grok_build_exec grok-build-0.1 "" <<<"a test prompt" )
out="$(cat "$capture")"

assert_contains "never passes /dev/stdin as --prompt-file" \
  "--prompt-file" "$out"
assert_not_contains "…specifically, never /dev/stdin" "/dev/stdin" "$out"
assert_eq "the prompt file is readable by the stand-in (no permission failure)" \
  "yes" "$(grep -oE 'prompt-file-readable: (yes|no)' <<<"$out" | awk '{print $2}')"
assert_eq "…and carries exactly what was piped in" \
  "a test prompt" "$(sed -n 's/^prompt-file-content: //p' <<<"$out")"
assert_contains "the model is passed with -m" "[-m] [grok-build-0.1]" "$out"
assert_contains "bypassPermissions is always passed" \
  "[--permission-mode] [bypassPermissions]" "$out"
assert_contains "--include-partial-messages is always passed" \
  "[--include-partial-messages]" "$out"
assert_contains "the wrapper is told to clean the prompt file up" "--cleanup" "$out"
# The --cleanup argument and the --prompt-file argument name the same file —
# `_exec` has no later moment of its own to remove it, so if the two ever
# drifted apart the real file would leak forever.
# Each argv entry is printed `[word]`, so the pattern has to match the
# bracket around the flag too — without it both extractions come back empty
# and the comparison passes whatever the adapter did.
prompt_file_arg() {
  grep -oE -- "\[$1\] \[[^]]+\]" <<<"$2" | sed -E 's/.*\[(.*)\]$/\1/'
}
cleanup_arg="$(prompt_file_arg --cleanup "$out")"
prompt_arg="$(prompt_file_arg --prompt-file "$out")"
assert_eq "the two extractions found a path at all" \
  "yes" "$([[ -n "$prompt_arg" && -n "$cleanup_arg" ]] && echo yes || echo no)"
assert_eq "…and names the exact same path --prompt-file does" "$prompt_arg" "$cleanup_arg"

# Where the prompt file goes, which the file's own mode cannot settle: the
# stage user must be able to traverse to it, so $GROK_HOME (shared between
# the two users by the image: group `stage`, 2770, setgid) is where it goes
# whenever that is a writable directory.
grok_home="$tmp_dir/grok-home"
mkdir -p "$grok_home"
( GROK_HOME="$grok_home" substrate_grok_build_exec grok-build-0.1 "" <<<"homed prompt" )
homed="$(prompt_file_arg --prompt-file "$(cat "$capture")")"
assert_eq "the prompt file is written inside \$GROK_HOME when there is one" \
  "$grok_home" "$(dirname "$homed")"

( GROK_HOME="$tmp_dir/no-such-grok-home" TMPDIR="$tmp_dir" \
    substrate_grok_build_exec grok-build-0.1 "" <<<"fallback prompt" )
fallback="$(prompt_file_arg --prompt-file "$(cat "$capture")")"
assert_eq "…and in \$TMPDIR where \$GROK_HOME names nothing writable" \
  "$tmp_dir" "$(dirname "$fallback")"

# A resume session id is passed through as -r, and omitted when empty (the
# fresh-session case just exercised above already covers omission).
( substrate_grok_build_exec grok-build-0.1 "abc-123" <<<"another prompt" )
out2="$(cat "$capture")"
assert_contains "a resume session id is passed through as -r" "[-r] [abc-123]" "$out2"

printf '\n'
if (( failures )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
