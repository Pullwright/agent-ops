#!/usr/bin/env bash
#
# test/toggle.test.sh — regression test for lib/toggle.sh.
#
# The switch has one job (stop cycles starting) and one way to fail badly: to
# resolve toward "enabled" when it shouldn't, or to stay "disabled" when
# nothing will ever clear it. Both are silent. The assertions below are almost
# all about those two directions rather than about the happy path:
#
#   - an unreadable or half-written record must read as disabled, not enabled;
#   - an unparseable `expires_at` must not expire;
#   - a TTL typo must be an error, not a guess in either direction;
#   - `--enable` on an already-enabled pipeline is a normal outcome and must
#     not return non-zero, because every call site is `x="$(toggle_clear …)"`
#     under `set -e` (the trap in the Gotchas table).
#
# The offline e2e section below also covers `agent-cycle.sh --kill-merge-
# autonomy`/`--restore-merge-autonomy` (D18, requirement 2.3b): a third fleet
# flag built on this file's own `fleet_flag_*` machinery, exercised here
# rather than in test/merge-autonomy.test.sh because the CLI harness — the
# node/log/gh-backing scaffolding — already lives in this file for the switch
# and the limit flag, and a third flag reusing the identical mechanism does
# not earn a second copy of it. lib/merge-autonomy.sh's own config-resolution
# and kill-switch unit coverage is test/merge-autonomy.test.sh's job.
#
# No test framework is used (none exists elsewhere in this repo). Run directly:
#
#   ./test/toggle.test.sh
#
# Exit status is 0 iff every assertion passed.

# lib/toggle.sh declares `local state_dir="$1"` in each of its functions, and
# this file happens to call them with a global of the same name. Reading them
# together, shellcheck takes the locals for writes to our global and warns that
# the writes are lost in the command substitutions they happen in — but there
# is no write: every one is a `local`, and this file only ever reads its own.
# shellcheck disable=SC2031

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/toggle.sh
. "$SCRIPT_DIR/lib/toggle.sh"
# fleet_limit_publish and fleet_limit_resume_at_for (issue #2135) call
# limit_flag_record_for, which lives in lib/limit-detect.sh rather than here —
# agent-cycle.sh sources limit-detect.sh before toggle.sh for exactly this
# reason (see its own sourcing-order comment), and this file has to mirror
# that order or those two functions silently see an undefined function
# instead of the real one (bash's "command not found" on an unset function,
# swallowed here because this file does not run under `set -e`), which reads
# as limit_flag_record_for always returning empty — the extend-only guard
# below then never finds a "current, same-provider" record to compare
# against and overwrites on every publish, whatever the resume_at ordering.
# shellcheck source=lib/limit-detect.sh
. "$SCRIPT_DIR/lib/limit-detect.sh"

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

state_dir="$tmp_dir/state"
mkdir -p "$state_dir"

# A pinned clock: 2026-07-17T12:00:00Z. Expiry is the feature most worth
# testing and the least testable by waiting.
export TOGGLE_NOW_EPOCH=1784289600

state_of() { jq -r '.state' <<<"$(toggle_state "$state_dir")"; }

# --- No switch ---

assert_eq "no record reads as enabled" "enabled" "$(state_of)"

# The call-site shape, under `set -e`, in a subshell: the absence of a switch is
# the normal case, and a non-zero here would kill every cycle at line one.
(
  set -euo pipefail
  . "$SCRIPT_DIR/lib/toggle.sh"
  s="$(toggle_state "$state_dir")"
  r="$(toggle_clear "$state_dir")"
  printf '%s%s' "$s" "$r" >/dev/null
  exit 0
) >/dev/null 2>&1
assert_eq "an absent switch does not abort its caller under set -e" "0" "$?"

assert_eq "clearing an unset switch is silent, not an error" "" "$(toggle_clear "$state_dir")"

# --- toggle_parse_ttl ---

assert_eq "a bare number means hours" "2026-07-17T16:00:00Z" "$(toggle_parse_ttl "4" 9)"
assert_eq "hours" "2026-07-17T16:00:00Z" "$(toggle_parse_ttl "4h" 9)"
assert_eq "minutes" "2026-07-17T13:30:00Z" "$(toggle_parse_ttl "90m" 9)"
assert_eq "days" "2026-07-19T12:00:00Z" "$(toggle_parse_ttl "2d" 9)"
assert_eq "an empty spec falls back to the configured default" \
  "2026-07-17T16:00:00Z" "$(toggle_parse_ttl "" 4)"
assert_eq "forever has no expiry" "" "$(toggle_parse_ttl "forever" 4)"
assert_eq "never is a synonym for forever" "" "$(toggle_parse_ttl "never" 4)"

# A typo must not silently become either 4 hours or forever: one resumes the
# pipeline while an agent is still editing, the other never resumes it.
toggle_parse_ttl "4hours" 4 >/dev/null 2>&1
assert_eq "an unparseable duration is an error, not a default" "64" "$?"
toggle_parse_ttl "0" 4 >/dev/null 2>&1
assert_eq "a zero duration is an error, not an indefinite disable" "64" "$?"

# --- toggle_parse_until ---

assert_eq "an absolute timestamp in the future" \
  "2026-07-17T16:00:00Z" "$(toggle_parse_until "2026-07-17T16:00:00Z")"
assert_eq "a GNU date -d string, not just ISO-8601" \
  "2026-07-17T16:00:00Z" "$(toggle_parse_until "2026-07-17 16:00:00 UTC")"

toggle_parse_until "not a date" >/dev/null 2>&1
assert_eq "an unparseable --until is an error, not a guess" "64" "$?"

toggle_parse_until "2026-07-17T10:00:00Z" >/dev/null 2>&1
assert_eq "a --until already in the past is an error" "64" "$?"

# The examples --help and the unparseable-timestamp error advertise must
# themselves parse. An example that errors is worse than no example, because
# it is precisely what a hurried operator copies — and GNU date has no `noon`
# keyword, so the obvious-looking 'tomorrow noon' is not one of them.
for example in "2026-08-10 18:00" "tomorrow 12:00"; do
  toggle_parse_until "$example" >/dev/null 2>&1
  assert_eq "the advertised example '$example' actually parses" "0" "$?"
done

# --- toggle_resolve_disable_spec ---

assert_eq "only --for given passes through unchanged" \
  "2h" "$(toggle_resolve_disable_spec "2h" "" 4)"

# Only --until given: the resulting spec must still resolve, through
# toggle_parse_ttl, to the instant --until named.
assert_eq "only --until given resolves to that instant via toggle_parse_ttl" \
  "2026-07-17T16:00:00Z" \
  "$(toggle_parse_ttl "$(toggle_resolve_disable_spec "" "2026-07-17T16:00:00Z" 4)" 4)"

# Both given, --for later (20:00 vs 16:00): --for's own spec wins outright.
assert_eq "both given, --for is the later deadline: --for wins" \
  "8h" "$(toggle_resolve_disable_spec "8h" "2026-07-17T16:00:00Z" 4 2>/dev/null)"
resolve_stderr="$(toggle_resolve_disable_spec "8h" "2026-07-17T16:00:00Z" 4 2>&1 >/dev/null)"
assert_eq "picking --for over --until is announced on stderr" \
  "1" "$(grep -c 'both --for and --until' <<<"$resolve_stderr")"

# Both given, --until later (20:00 vs 14:00): resolves to --until's instant.
assert_eq "both given, --until is the later deadline: --until wins" \
  "2026-07-17T20:00:00Z" \
  "$(toggle_parse_ttl "$(toggle_resolve_disable_spec "2h" "2026-07-17T20:00:00Z" 4 2>/dev/null)" 4)"
resolve_stderr="$(toggle_resolve_disable_spec "2h" "2026-07-17T20:00:00Z" 4 2>&1 >/dev/null)"
assert_eq "picking --until over --for is announced on stderr" \
  "1" "$(grep -c 'both --for and --until' <<<"$resolve_stderr")"

# Both given, --for forever: indefinite always outlasts a named instant.
assert_eq "both given, --for forever always wins" \
  "forever" "$(toggle_resolve_disable_spec "forever" "2026-08-01T00:00:00Z" 4 2>/dev/null)"

toggle_resolve_disable_spec "2h" "not a date" 4 >/dev/null 2>&1
assert_eq "both given, an unparseable --until fails" "64" "$?"

toggle_resolve_disable_spec "4hours" "2026-07-17T20:00:00Z" 4 >/dev/null 2>&1
assert_eq "both given, an unparseable --for fails" "64" "$?"

# --- Setting and reading the switch ---

record="$(toggle_disable "$state_dir" "editing lib/toggle.sh" "2h" 4 "tester pid 1")"
assert_eq "disable writes the reason" "editing lib/toggle.sh" "$(jq -r '.reason' <<<"$record")"
assert_eq "disable stamps the expiry from the spec" \
  "2026-07-17T14:00:00Z" "$(jq -r '.expires_at' <<<"$record")"
assert_eq "disable records who set it" "tester pid 1" "$(jq -r '.by' <<<"$record")"
assert_eq "disable records a manual kind by default" "manual" "$(jq -r '.kind' <<<"$record")"
assert_eq "disable derives the actor when none is given" \
  "$(toggle_actor)" "$(jq -r '.actor' <<<"$record")"
assert_eq "a set switch reads as disabled" "disabled" "$(state_of)"

# --- mode (requirement 2.3d): stop vs drain ---

assert_eq "toggle_disable defaults mode to stop" "stop" "$(jq -r '.mode' <<<"$record")"
assert_eq "toggle_mode reads the default back" "stop" "$(toggle_mode "$record")"

drain_record="$(toggle_disable "$state_dir" "clearing the backlog" "2h" 4 "tester pid 1" \
  "" manual node drain)"
assert_eq "toggle_disable writes mode drain when asked" "drain" "$(jq -r '.mode' <<<"$drain_record")"
assert_eq "toggle_mode reads drain back" "drain" "$(toggle_mode "$drain_record")"
assert_eq "a drain still reads as disabled at the state level — mode is orthogonal to state" \
  "disabled" "$(state_of)"

assert_eq "toggle_mode defaults a record with no mode field to stop" "stop" \
  "$(toggle_mode '{"reason":"pre-existing record"}')"
assert_eq "toggle_mode defaults an empty record to stop" "stop" "$(toggle_mode '{}')"
assert_eq "toggle_mode defaults no argument at all to stop" "stop" "$(toggle_mode)"

assert_eq "toggle_switch_summary carries mode" "drain" \
  "$(jq -r '.mode' <<<"$(toggle_switch_summary "$state_dir")")"

toggle_clear "$state_dir" >/dev/null
record="$(toggle_disable "$state_dir" "editing lib/toggle.sh" "2h" 4 "tester pid 1")"
assert_eq "an unmodified toggle_disable is mode stop again (restoring fixture state)" \
  "stop" "$(jq -r '.mode' <<<"$record")"

# --- toggle_actor (#244): attribution, never "unknown" ---
# The record's actor is what tells a reader whose decision a stand-down was;
# `unknown@<container-id>` is exactly the reading requirement 2.3 forbids.
assert_eq "NODE_NAME names the actor outright" "node-x" \
  "$(NODE_NAME=node-x bash -c ". '$SCRIPT_DIR/lib/toggle.sh'; toggle_actor")"
actor_no_user="$(env -u USER -u NODE_NAME bash -c ". '$SCRIPT_DIR/lib/toggle.sh'; toggle_actor")"
assert_eq "with no USER at all the actor is still someone, never unknown" "0" \
  "$([[ -n "$actor_no_user" && "$actor_no_user" != unknown* ]] && echo 0 || echo 1)"

# --- Expiry ---

TOGGLE_NOW_EPOCH=$(( 1784289600 + 7199 ))   # one second before the TTL
assert_eq "a switch one second short of its TTL is still disabled" "disabled" "$(state_of)"
TOGGLE_NOW_EPOCH=$(( 1784289600 + 7200 ))   # exactly at the TTL
assert_eq "a switch at its TTL has expired" "expired" "$(state_of)"
TOGGLE_NOW_EPOCH=1784289600

# The reason the TTL exists at all: an agent that disables the pipeline and
# then dies leaves this file behind, and nothing else would ever clear it.
assert_eq "an expired switch still carries its record, so the log can say what expired" \
  "editing lib/toggle.sh" \
  "$(TOGGLE_NOW_EPOCH=$(( 1784289600 + 7200 )) toggle_state "$state_dir" | jq -r '.record.reason')"

cleared="$(toggle_clear "$state_dir")"
assert_eq "clearing returns the record it removed" "editing lib/toggle.sh" "$(jq -r '.reason' <<<"$cleared")"
assert_eq "a cleared switch reads as enabled" "enabled" "$(state_of)"

# --- forever ---

toggle_disable "$state_dir" "long maintenance" "forever" 4 "tester" >/dev/null
assert_eq "an indefinite switch stores a null expiry" "null" \
  "$(jq -r '.expires_at' "$(toggle_file "$state_dir")")"
assert_eq "an indefinite switch does not expire, ever" "disabled" \
  "$(TOGGLE_NOW_EPOCH=$(( 1784289600 + 86400 * 365 )) toggle_state "$state_dir" | jq -r '.state')"
toggle_clear "$state_dir" >/dev/null

# --- Everything ambiguous resolves toward disabled ---

# A half-written record. The file exists because something meant to stop the
# pipeline; reading "enabled" out of a truncated write would run the very cycle
# the switch was set to prevent.
printf '{"disabled_at": "2026-07-17T09:00:00Z", "rea' > "$(toggle_file "$state_dir")"
assert_eq "an unreadable record reads as disabled, not enabled" "disabled" "$(state_of)"
assert_eq "an unreadable record still describes itself to the operator" \
  "0" "$([[ -n "$(toggle_describe "$(toggle_state "$state_dir" | jq -c '.record')")" ]] && echo 0 || echo 1)"
rm -f "$(toggle_file "$state_dir")"

# An expiry that doesn't parse has no expiry — it must not be treated as long
# past and cleared on the next tick.
jq -n '{disabled_at: "2026-07-17T09:00:00Z", expires_at: "next tuesday-ish", by: "t", reason: "r"}' \
  > "$(toggle_file "$state_dir")"
assert_eq "an unparseable expiry does not expire the switch" "disabled" "$(state_of)"
rm -f "$(toggle_file "$state_dir")"

# A failed disable must leave no switch: an operator told "that didn't work"
# who is nonetheless disabled has been lied to in the more dangerous direction.
toggle_disable "$state_dir" "reason" "banana" 4 "tester" >/dev/null 2>&1
assert_eq "a disable with an unparseable duration fails" "64" "$?"
assert_eq "a failed disable writes no switch" "enabled" "$(state_of)"

# --- toggle_lock_held ---

lock="$tmp_dir/lock.json"
assert_eq "an absent lock is not held" "" "$(toggle_lock_held "$lock")"
jq -n '{pid: 999999, started_at: "2026-07-17T11:00:00Z"}' > "$lock"
assert_eq "a lock held by a dead pid is not held" "" "$(toggle_lock_held "$lock")"
jq -n --argjson p "$$" '{pid: $p, started_at: "2026-07-17T11:00:00Z"}' > "$lock"
assert_eq "a lock held by a live pid is reported" \
  "held by pid $$ since 2026-07-17T11:00:00Z" "$(toggle_lock_held "$lock")"

# --- toggle_status_report ---

toggle_disable "$state_dir" "editing" "1h" 4 "tester" >/dev/null
report="$(toggle_status_report "$state_dir" "cycle=$lock" "review=$tmp_dir/absent.json")"
assert_eq "status reports the switch" "1" "$(grep -c 'DISABLED' <<<"$report")"
assert_eq "status reports a running pipeline" "1" "$(grep -c 'cycle:.*RUNNING' <<<"$report")"
assert_eq "status reports an idle pipeline" "1" "$(grep -c 'review:.*idle' <<<"$report")"
# Disabling stops the next cycle, not the one already running. An agent that
# doesn't know that disables the pipeline, starts editing, and is puzzled when
# the cycle it thought it stopped fails on its half-written file.
assert_eq "status warns when a cycle is running despite the switch" \
  "1" "$(grep -c 'does not stop one already running' <<<"$report")"

# ===== Fleet flags (requirements 2.3a and 2.1) ================================
#
# The failure directions here mirror the local switch's, one level up:
#
#   - a flag one node set must read as set on another node (that is the flag's
#     whole job);
#   - an unreachable state repo must fall back to the cached copy, and to
#     enabled with none — never crash a cycle;
#   - a 404 is "clear", definitively, and must also clear the cache;
#   - a garbage flag reads as disabled, like a garbage local record;
#   - the limit flag only ever extends, whatever order writes land in;
#   - "cleared" must never be reported for a flag that is still set.

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

# A stub `gh` backed by a directory: the contents API reduced to GET/PUT/DELETE
# with sha compare-and-swap, exactly the subset lib/toggle.sh uses.
# GH_STUB_MODE=down makes every call fail the way an unreachable GitHub does.
gh_backing="$tmp_dir/fleet-remote"
mkdir -p "$gh_backing"
gh_stub="$tmp_dir/gh-stub"
cat > "$gh_stub" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
if [[ "${GH_STUB_MODE:-ok}" == "down" ]]; then
  echo "dial tcp: could not resolve host github.com" >&2
  exit 1
fi
backing="${GH_STUB_BACKING:?}"
method=GET path="" jq_expr=""
declare -A f=()
args=("$@"); i=0
while (( i < ${#args[@]} )); do
  a="${args[$i]}"
  case "$a" in
    -X)      i=$((i+1)); method="${args[$i]}" ;;
    --jq)    i=$((i+1)); jq_expr="${args[$i]}" ;;
    -f)      i=$((i+1)); kv="${args[$i]}"; f["${kv%%=*}"]="${kv#*=}" ;;
    repos/*) path="$a" ;;
  esac
  i=$((i+1))
done
if [[ "$path" == repos/*/* && "$path" != */contents/* ]]; then
  # Repo-existence probe (TD-PPagop-26081602): `repos/<repo>`, no
  # `/contents/...`. GH_STUB_MODE=repo-404 simulates a repo missing or
  # invisible to this token — the case a flag file's own 404 alone cannot
  # tell apart from the flag file genuinely not existing.
  if [[ "${GH_STUB_MODE:-ok}" == "repo-404" ]]; then
    echo "gh: Not Found (HTTP 404)" >&2
    exit 1
  fi
  echo '{}'
  exit 0
fi
rel="${path#repos/*/*/contents/}"; rel="${rel%%\?*}"
file="$backing/$rel"
sha_of() { sha1sum "$1" | awk '{print $1}'; }
case "$method" in
  GET)
    [[ -f "$file" ]] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    if [[ "$jq_expr" == ".sha" ]]; then sha_of "$file"; exit 0; fi
    jq -n --arg c "$(base64 -w0 < "$file")" --arg s "$(sha_of "$file")" '{content: $c, sha: $s}'
    ;;
  PUT)
    if [[ -f "$file" ]]; then
      [[ "${f[sha]:-}" == "$(sha_of "$file")" ]] || { echo "gh: sha mismatch (HTTP 409)" >&2; exit 1; }
    elif [[ -n "${f[sha]:-}" ]]; then
      echo "gh: sha given for a missing file (HTTP 422)" >&2; exit 1
    fi
    mkdir -p "$(dirname "$file")"
    printf '%s' "${f[content]:?}" | base64 -d > "$file"
    ;;
  DELETE)
    [[ -f "$file" ]] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    [[ "${f[sha]:-}" == "$(sha_of "$file")" ]] || { echo "gh: sha mismatch (HTTP 409)" >&2; exit 1; }
    rm -f "$file"
    ;;
esac
STUB
chmod +x "$gh_stub"
export TOGGLE_GH="$gh_stub" GH_STUB_BACKING="$gh_backing"

slug="example/agent-ops-state"
fs_a="$tmp_dir/fleet-state-a"; fs_b="$tmp_dir/fleet-state-b"
mkdir -p "$fs_a" "$fs_b"

# --- Fetch, cache, and the failure directions ---

assert_eq "an absent fleet flag fetches as nothing" "" \
  "$(fleet_flag_fetch "$slug" "$fs_b" disabled)"
assert_eq "an absent fleet flag leaves no cache" "0" \
  "$(test -f "$(fleet_cache_file "$fs_b" disabled)" && echo 1 || echo 0)"
assert_eq "no state repo means no fleet: everything is a quiet no-op" "enabled" \
  "$(fleet_disabled_state "" "$fs_b" | jq -r '.state')"

rec="$(jq -nc '{disabled_at: "2026-07-17T11:00:00Z", expires_at: "2026-07-17T13:00:00Z", by: "node-a", reason: "fleet halt"}')"
fleet_flag_write "$slug" disabled "$rec" "set by the test"
assert_eq "writing a fleet flag succeeds" "0" "$?"
assert_eq "a flag node A set reads as disabled on node B" "disabled" \
  "$(fleet_disabled_state "$slug" "$fs_b" | jq -r '.state')"
assert_eq "the record round-trips through the contents API" "fleet halt" \
  "$(fleet_disabled_state "$slug" "$fs_b" | jq -r '.record.reason')"
assert_eq "a successful fetch caches the flag" "1" \
  "$(test -f "$(fleet_cache_file "$fs_b" disabled)" && echo 1 || echo 0)"

assert_eq "an unreachable repo falls back to the cached copy" "disabled" \
  "$(GH_STUB_MODE=down fleet_disabled_state "$slug" "$fs_b" | jq -r '.state')"
fs_c="$tmp_dir/fleet-state-c"; mkdir -p "$fs_c"
assert_eq "an unreachable repo with no cache reads as enabled (claims are the backstop)" "enabled" \
  "$(GH_STUB_MODE=down fleet_disabled_state "$slug" "$fs_c" | jq -r '.state')"

assert_eq "a fleet flag past its expiry reads as expired" "expired" \
  "$(TOGGLE_NOW_EPOCH=$(( 1784289600 + 4 * 3600 )) fleet_disabled_state "$slug" "$fs_b" | jq -r '.state')"

printf 'not json at all' > "$gh_backing/fleet/disabled.json"
assert_eq "a garbage fleet flag reads as disabled, not enabled" "disabled" \
  "$(fleet_disabled_state "$slug" "$fs_b" | jq -r '.state')"

# --- Delete: absent is cleared, unreachable is NOT ---

delete_word="$(fleet_flag_delete "$slug" "$fs_b" disabled)"
assert_eq "deleting a set flag succeeds" "0" "$?"
assert_eq "and reports that it actually deleted something (issue #426)" "deleted" "$delete_word"
assert_eq "the flag is gone from the repo" "0" \
  "$(test -f "$gh_backing/fleet/disabled.json" && echo 1 || echo 0)"
assert_eq "a successful delete drops the local cache too" "0" \
  "$(test -f "$(fleet_cache_file "$fs_b" disabled)" && echo 1 || echo 0)"
delete_word="$(fleet_flag_delete "$slug" "$fs_b" disabled)"
assert_eq "deleting an absent flag is already-clear, not an error" "0" "$?"
assert_eq "and reports there was nothing to delete, distinctly from a real delete (issue #426)" \
  "absent" "$delete_word"
GH_STUB_MODE=down fleet_flag_delete "$slug" "$fs_b" disabled >/dev/null
assert_eq "an unreachable repo must NOT report the flag cleared" "1" "$?"

assert_eq "fleet_flag_delete_outcome maps a real delete to ok" "ok" \
  "$(fleet_flag_write "$slug" disabled "$rec" "set for the outcome test" \
     && fleet_flag_delete_outcome "$slug" "$fs_b" disabled)"
assert_eq "and an already-absent flag to unconfigured, not ok" "unconfigured" \
  "$(fleet_flag_delete_outcome "$slug" "$fs_b" disabled)"
assert_eq "and an unreachable repo to failed" "failed" \
  "$(fleet_flag_write "$slug" disabled "$rec" "set for the outcome test" \
     && GH_STUB_MODE=down fleet_flag_delete_outcome "$slug" "$fs_b" disabled)"
fleet_flag_delete "$slug" "$fs_b" disabled >/dev/null

assert_eq "fleet_flag_write_outcome maps a real write to ok" "ok" \
  "$(fleet_flag_write_outcome "$slug" disabled "$rec" "set for the outcome test")"
fleet_flag_delete "$slug" "$fs_b" disabled >/dev/null
assert_eq "and no state repo to unconfigured" "unconfigured" \
  "$(fleet_flag_write_outcome "" disabled "$rec" "set for the outcome test")"
assert_eq "and an unreachable repo to failed" "failed" \
  "$(GH_STUB_MODE=down fleet_flag_write_outcome "$slug" disabled "$rec" "set for the outcome test")"

# A 404 on fetch clears a stale cache: the flag was cleared remotely and the
# cached copy must not keep this node standing down.
fleet_flag_write "$slug" disabled "$rec" "set again"
fleet_flag_fetch "$slug" "$fs_b" disabled >/dev/null
rm -f "$gh_backing/fleet/disabled.json"
# fleet_flag_fetch_status now memoises a live answer per process
# (issue #502), so the second fetch below — same flag, same
# state_dir — would otherwise just replay the first one's memo rather than
# notice the file is gone. _fleet_flag_memo_clear is what a real write/delete
# already calls; using it here stands in for "the next cycle's process",
# which is genuinely who would notice this 404 in production (the flag was
# not cleared through this process's own fleet_flag_write/_delete, so nothing
# else would have invalidated the memo for it).
_fleet_flag_memo_clear disabled
fleet_flag_fetch "$slug" "$fs_b" disabled >/dev/null
assert_eq "a 404 clears the cached copy" "0" \
  "$(test -f "$(fleet_cache_file "$fs_b" disabled)" && echo 1 || echo 0)"

# The memo root is named from `$$`, which is unique only among the processes
# running now: $TMPDIR outlives them and PIDs are recycled, so a node chaining
# cycle after cycle eventually starts one whose PID a dead cycle's memos are
# still filed under. Nothing else expires them, so sourcing this file must —
# or a recycled PID would serve this process another process's answer for its
# whole run, which on the kill switch means an operator's `disabled` read as
# `clear`. Asserted in a child shell, because the purge happens at source time
# and this process is long past its own.
memo_purge_out="$(TMPDIR="$tmp_dir/memo-tmp" bash -c '
  root="$TMPDIR/agent-ops-fleet-flag-memo.$$"
  mkdir -p "$root/merge-autonomy-kill"
  printf "clear\t" > "$root/merge-autonomy-kill/_a_state_dir"
  . "'"$SCRIPT_DIR"'/lib/toggle.sh"
  test -e "$root" && echo survived || echo purged
')"
assert_eq "a memo root left behind by a dead process with this PID is purged at source time" \
  "purged" "$memo_purge_out"

# --- TD-PPagop-26081602: a repo-level 404 must not read the kill switch as
#     clear — and must keep reading the fail-open flags exactly as before ---
#
# The contents API answers "this repository does not exist, or this token
# cannot see it" with the same 404 as "the flag file does not exist". For
# the fail-open flags that collapse is accepted and their 404 stays
# terminal; the kill switch's read asks fleet_flag_fetch_status for its
# `probe-404` mode, which probes the repo itself before calling either 404 a
# clear flag — a 2xx there confirms the flag file's own 404 was genuine, and
# anything else (modelled here by GH_STUB_MODE=repo-404) must not be
# reported as clear. test/merge-autonomy.test.sh covers the one caller that
# asks for the mode; this block covers the mechanism, on the disabled flag's
# name for convenience.

status_of() {
  local combined
  combined="$(fleet_flag_fetch_status "$@")"
  printf '%s' "${combined%%$'\t'*}"
}

fs_probe="$tmp_dir/fleet-state-probe"; mkdir -p "$fs_probe"

# Default mode first: byte-identical to the pre-probe behaviour even when
# the repo itself is invisible — the flag-file 404 stays terminal (clear,
# cache dropped) and no probe call is spent. This is the fail-open contract
# the TD item pinned: a fleet resume must never wait on a probe's own
# transient failure.
fleet_flag_write "$slug" disabled "$rec" "primed for the default-mode 404 test" "$fs_probe"
rm -f "$gh_backing/fleet/disabled.json"
assert_eq "default mode: fleet_flag_fetch prints nothing for a flag-file 404 against an invisible repo" \
  "" "$(GH_STUB_MODE=repo-404 fleet_flag_fetch "$slug" "$fs_probe" disabled)"
assert_eq "and the 404 stayed terminal — the cached copy is dropped, not fallen back to" "0" \
  "$(test -f "$(fleet_cache_file "$fs_probe" disabled)" && echo 1 || echo 0)"
assert_eq "and no repo probe was spent on the fail-open path" "0" \
  "$(test -f "$(fleet_cache_file "$fs_probe" disabled).repo-err" && echo 1 || echo 0)"
assert_eq "the status wrapper agrees: the default mode reads the same 404 clear" "clear" \
  "$(GH_STUB_MODE=repo-404 status_of "$slug" "$fs_probe" disabled)"

# The probing mode. The flag file is absent and the repo is visible: the
# ordinary, definitive clear case, probe included.
assert_eq "probe-404: a flag-file 404 against a repo the token can see is clear" "clear" \
  "$(status_of "$slug" "$fs_probe" disabled probe-404)"

# The flag file is still absent, but now the repo probe itself fails too
# (GH_STUB_MODE=repo-404): with no cached copy at all this must read
# unreachable, never clear. Nothing about the flag has actually changed since
# the previous assertion — only the simulated reachability has — so without
# clearing the memo first this would just replay the "clear" answer memoised
# above rather than exercise the probe at all (issue #502).
_fleet_flag_memo_clear disabled
assert_eq "probe-404: a flag-file 404 against an invisible repo, no cache, reads unreachable" \
  "unreachable" \
  "$(GH_STUB_MODE=repo-404 status_of "$slug" "$fs_probe" disabled probe-404)"

# Prime a cache while the repo is visible, then repeat the repo-level 404: it
# must fall back to the cache, exactly as a transport failure would, rather
# than reporting clear on the strength of a 404 whose ambiguity was never
# resolved.
fleet_flag_write "$slug" disabled "$rec" "primed for the repo-404 cache test" "$fs_probe"
rm -f "$gh_backing/fleet/disabled.json"
assert_eq "probe-404: a repo-level 404 with a cached copy falls back to it, not clear" "cached" \
  "$(GH_STUB_MODE=repo-404 status_of "$slug" "$fs_probe" disabled probe-404)"

# transient failures on the probe itself (a timeout, a flaky response) get
# the same treatment as GH_STUB_MODE=down does for the flag fetch: no crash,
# just the ordinary cached-or-unreachable fallback — already covered above,
# since the stub's repo-404 case and a real probe timeout are
# indistinguishable to fleet_flag_fetch_status (any non-success response).

rm -f "$(fleet_cache_file "$fs_probe" disabled)"

# --- agent-ops#1118: fleet_flag_fetch_cause's own choice between the two
#     error files the block above writes. Asserted directly against the
#     files rather than through a fetch, because the one case that matters
#     most here — a `$cache.repo-err` left behind by an *earlier* call, on a
#     call that never probed the repo at all — is precisely the state a
#     single fetch cannot be made to produce: whichever call wrote the stale
#     file is by definition not the call under test. ---
fs_cause="$tmp_dir/fleet-state-cause"; mkdir -p "$fs_cause/fleet-cache"
cause_cache="$(fleet_cache_file "$fs_cause" disabled)"

# The ordinary case (agent-ops#1081's own shape): the flag fetch itself
# failed, with a diagnosis that is not a 404, so no probe ever ran and
# `$cache.err` is the whole story.
printf 'gh: You have exceeded a secondary rate limit.' > "$cause_cache.err"
rm -f "$cause_cache.repo-err"
assert_eq "cause: a non-404 flag-fetch failure is reported from \$cache.err" \
  "gh: You have exceeded a secondary rate limit." \
  "$(fleet_flag_fetch_cause "$fs_cause" disabled)"

# The same, but with a `$cache.repo-err` still on disk from an earlier call
# that did probe. Reading it unconditionally would report a stale, unrelated
# refusal as this call's cause — the mistake the 404 gate exists to prevent.
printf 'gh: Not Found (HTTP 404)' > "$cause_cache.repo-err"
assert_eq "  ... even with a stale \$cache.repo-err left by an earlier call" \
  "gh: You have exceeded a secondary rate limit." \
  "$(fleet_flag_fetch_cause "$fs_cause" disabled)"

# The probe case: the flag file's own 404 is the ambiguous one, so the repo
# probe ran and is what actually failed. Its own refusal is the real cause;
# the flag's "Not Found" is the misleading answer this fixes.
printf 'gh: HTTP 404: Not Found (https://api.github.com/repos/o/r/contents/fleet/disabled.json)' \
  > "$cause_cache.err"
printf 'gh: You have exceeded a secondary rate limit.' > "$cause_cache.repo-err"
assert_eq "cause: a flag-file 404 reports the repo probe's own refusal, not the flag's Not Found" \
  "gh: You have exceeded a secondary rate limit." \
  "$(fleet_flag_fetch_cause "$fs_cause" disabled)"

# A probe that failed silently (non-zero, nothing on stderr) truncates
# `$cache.repo-err` to nothing, so there is no better answer than the flag's
# own 404 — which must still be reported rather than an empty cause.
: > "$cause_cache.repo-err"
assert_eq "  ... but falls back to \$cache.err when the probe wrote nothing at all" \
  "gh: HTTP 404: Not Found (https://api.github.com/repos/o/r/contents/fleet/disabled.json)" \
  "$(fleet_flag_fetch_cause "$fs_cause" disabled)"

# No error file at all — a caller asking before any fetch has failed — is an
# empty cause, never an error.
rm -f "$cause_cache.err" "$cause_cache.repo-err"
assert_eq "cause: no error file at all is an empty cause, not a failure" \
  "" "$(fleet_flag_fetch_cause "$fs_cause" disabled)"

# --- issue #513 (PR #506 review follow-up): the memo is keyed by MODE too,
#     not just (NAME, STATE_DIR) — the default mode and `probe-404`
#     deliberately disagree about one and the same contents-API 404 (clear
#     vs a possible unreachable), so a default-mode `clear` memoised first
#     must never be served to a later `probe-404` read of the same flag. ---
fs_mode="$tmp_dir/fleet-state-mode-keying"; mkdir -p "$fs_mode"
rm -f "$gh_backing/fleet/disabled.json"
assert_eq "mode-keying: a default-mode read of an absent flag memoises clear" "clear" \
  "$(status_of "$slug" "$fs_mode" disabled)"
# Same (name, state_dir), now in probe-404 mode, with the repo itself made
# invisible to the probe and no cache to fall back to. Before mode-keying
# this would have replayed the default mode's own memoised "clear" without
# ever asking the stub again; keyed by mode, it has no memo of its own yet
# and must genuinely probe — reading unreachable, never the leaked clear.
assert_eq "mode-keying: a probe-404 read of the same flag is not served the default mode's own memo" \
  "unreachable" \
  "$(GH_STUB_MODE=repo-404 status_of "$slug" "$fs_mode" disabled probe-404)"

# --- issue #513 (PR #506 review follow-up): a torn or vanished memo file
#     falls through to a live fetch rather than being served as an
#     (incorrectly) confirmed answer — `[[ -f "$memo" ]] && { cat "$memo"; ...
#     }` would have returned success with empty output for either case,
#     which `merge_autonomy_kill_state` resolves to `{"state":"enabled"}`,
#     not killed — the same fail-open direction the recycled-PID bug 97539b7
#     fixed. ---
fs_torn="$tmp_dir/fleet-state-torn-memo"; mkdir -p "$fs_torn"
fleet_flag_write "$slug" disabled "$rec" "primed for the torn-memo test" "$fs_torn"
fleet_flag_fetch "$slug" "$fs_torn" disabled >/dev/null # primes the memo the ordinary way
memo_torn="$(_fleet_flag_memo_file disabled "$fs_torn")"
: > "$memo_torn" # simulate an interrupted write: present, but empty
assert_eq "an empty memo file falls through to a live fetch rather than being served" \
  "$rec" "$(fleet_flag_fetch "$slug" "$fs_torn" disabled)"
fleet_flag_fetch "$slug" "$fs_torn" disabled >/dev/null # re-primes the memo
rm -f "$memo_torn" # simulate the file vanishing between the -f test and the read
assert_eq "a vanished memo file falls through to a live fetch too" \
  "$rec" "$(fleet_flag_fetch "$slug" "$fs_torn" disabled)"
fleet_flag_delete "$slug" "$fs_torn" disabled >/dev/null

# --- TD-PPagop-26081604: the clear side of the same ambiguity ---
#
# fleet_flag_delete's own read-for-sha hits the identical ambiguous 404 the
# block above resolves for fetches, but it can never accept the fail-open
# collapse: "absent" here is a claim that the flag has been cleared, so every
# 404 is probed, unconditionally — there is no default mode to opt out of it.
# Both probe outcomes:

assert_eq "the flag file is genuinely absent before either probe case" "0" \
  "$(test -f "$gh_backing/fleet/disabled.json" && echo 1 || echo 0)"

# Probe succeeds (repo visible, the stub's default mode): the 404 is the flag
# file's own, genuinely absent. This exercises the same repo-visible probe
# path the "deleting an absent flag" case above now spends too, just against
# fs_probe rather than fs_b, so it is asserted explicitly here.
delete_word="$(fleet_flag_delete "$slug" "$fs_probe" disabled)"
assert_eq "probe confirms the repo is visible: the 404 resolves to absent" "0" "$?"
assert_eq "and reports absent, not a false deleted" "absent" "$delete_word"

# Probe fails (repo invisible, or unreachable): the 404 must NOT resolve to
# absent — reporting a flag cleared that is still set is exactly the harm
# this item closes.
GH_STUB_MODE=repo-404 fleet_flag_delete "$slug" "$fs_probe" disabled >/dev/null
assert_eq "an unconfirmed 404 (repo invisible) must NOT report the flag cleared" "1" "$?"
assert_eq "fleet_flag_delete_outcome reports it as failed, not unconfigured" "failed" \
  "$(GH_STUB_MODE=repo-404 fleet_flag_delete_outcome "$slug" "$fs_probe" disabled)"

# --- The limit flag only ever extends ---

fleet_limit_publish "$slug" "$fs_a" "2026-07-17T15:00:00Z" "monthly-spend" true node-a
assert_eq "the first limit publish creates the flag" "0" "$?"
assert_eq "the flag carries its resume_at" "2026-07-17T15:00:00Z" \
  "$(fleet_limit_resume_at "$slug" "$fs_b")"
fleet_limit_publish "$slug" "$fs_b" "2026-07-17T14:00:00Z" "weekly" false node-b
assert_eq "an earlier resume_at does not shorten the stand-down" "2026-07-17T15:00:00Z" \
  "$(fleet_limit_resume_at "$slug" "$fs_b")"
fleet_limit_publish "$slug" "$fs_b" "2026-07-17T18:00:00Z" "monthly-spend" true node-b
assert_eq "a later resume_at extends it" "2026-07-17T18:00:00Z" \
  "$(fleet_limit_resume_at "$slug" "$fs_a")"
assert_eq "the extending node signs the flag" "node-b" \
  "$(fleet_flag_fetch "$slug" "$fs_a" limit | jq -r '.node')"

# The published record attributes itself (#244): an automatic kind, the node
# as actor, and the API response that justified the write as evidence.
fleet_limit_publish "$slug" "$fs_b" "2026-07-17T20:00:00Z" "monthly-spend" false node-b \
  "HTTP 429: You've hit your monthly spend limit"
assert_eq "a publish carries its evidence" \
  "HTTP 429: You've hit your monthly spend limit" \
  "$(fleet_flag_fetch "$slug" "$fs_a" limit | jq -r '.evidence')"
assert_eq "and records an automatic kind with the node as actor" "auto/node-b" \
  "$(fleet_flag_fetch "$slug" "$fs_a" limit | jq -r '"\(.kind)/\(.actor)"')"
rm -f "$gh_backing/fleet/limit.json"

# --- The limit flag's extend-only guard is now PER PROVIDER (issue #2135) --
# The flag still carries exactly one record at a time (limit_flag_record_for's
# own header explains the trade), so a second provider's hit cannot simply
# join the first — it has to replace it outright. "Already covers this" is
# now judged against the CURRENT record's own provider via
# limit_flag_record_for: a longer-running freeze for a *different* provider
# must not suppress this provider's own publish just because its resume_at
# happens to be later, or whichever provider freezes longest would silently
# own the fast path forever.
fleet_limit_publish "$slug" "$fs_a" "2099-01-01T00:00:00Z" "monthly-spend" true node-a "" anthropic
assert_eq "an anthropic hit with a far-future resume_at creates the flag" "0" "$?"
assert_eq "…scoped to anthropic" "anthropic" \
  "$(fleet_flag_fetch "$slug" "$fs_a" limit | jq -r '.provider')"

fleet_limit_publish "$slug" "$fs_b" "2030-01-01T00:00:00Z" "weekly" false node-b "" xai
assert_eq "publishing a SHORTER-resuming hit for a DIFFERENT provider still succeeds" "0" "$?"
assert_eq "…and OVERWRITES the flag rather than no-opping against anthropic's longer freeze" \
  "2030-01-01T00:00:00Z" "$(fleet_limit_resume_at "$slug" "$fs_a")"
assert_eq "…the flag now names xai, not anthropic" "xai" \
  "$(fleet_flag_fetch "$slug" "$fs_a" limit | jq -r '.provider')"

# Extend-only is still preserved WITHIN the same provider — the regression
# this scoping must not introduce: a second, shorter hit for xai itself must
# still no-op against the xai record just written.
fleet_limit_publish "$slug" "$fs_b" "2025-01-01T00:00:00Z" "weekly" false node-b "" xai
assert_eq "a shorter hit for the SAME provider the flag already covers is a no-op" \
  "0" "$?"
assert_eq "…the flag still shows xai's own earlier (longer) publish" \
  "2030-01-01T00:00:00Z" "$(fleet_limit_resume_at "$slug" "$fs_a")"

# --- fleet_limit_resume_at_for: the per-provider live re-check -------------
# lib/enabler.sh and lib/refinement.sh take this right before launching their
# own stage, scoped the same way the main stand-down check is.
assert_eq "fleet_limit_resume_at_for returns the resume_at for the provider the flag currently names" \
  "2030-01-01T00:00:00Z" "$(fleet_limit_resume_at_for "$slug" "$fs_a" xai)"
assert_eq "…and is empty for a provider the current record doesn't name and isn't a wildcard" \
  "" "$(fleet_limit_resume_at_for "$slug" "$fs_a" anthropic)"
rm -f "$gh_backing/fleet/limit.json"

# A record with no provider field at all (every flag written before issue
# #2133, or one hand-migrated) is the wildcard case: it governs whichever
# provider asks, exactly as fleet_limit_resume_at (the fleet-wide reader)
# already treats it.
legacy_limit_rec="$(jq -nc '{resume_at: "2040-01-01T00:00:00Z", class: "monthly-spend", reset_known: true, node: "node-a", kind: "auto", actor: "node-a"}')"
fleet_flag_write "$slug" limit "$legacy_limit_rec" "legacy record, written before issue #2133 named a provider"
assert_eq "fleet_limit_resume_at_for honours a wildcard (pre-#2133) record for xai" \
  "2040-01-01T00:00:00Z" "$(fleet_limit_resume_at_for "$slug" "$fs_a" xai)"
assert_eq "…and for anthropic too" \
  "2040-01-01T00:00:00Z" "$(fleet_limit_resume_at_for "$slug" "$fs_a" anthropic)"
rm -f "$gh_backing/fleet/limit.json"

# --- limit_governing_record_for: the union and the flag, combined ----------
# Requirement 2.1's "later resume wins" over BOTH carriers at once, scoped to
# one provider — the answer lib/enabler.sh, lib/refinement.sh, the dashboard
# and the Monitor's digest want, without each re-deriving it from the union
# and the flag separately. With no state repo configured this degrades to
# reading the log union alone (fleet_flag_fetch's own quiet no-op for an
# empty STATE_REPO), which keeps this half of the test pure/offline.
xai_hit_only="$(printf '%s\n' \
  '{"ts":"2026-03-01T00:00:00Z","event":"limit-hit","resume_at":"2099-06-01T00:00:00Z","provider":"xai"}')"
assert_eq "limit_governing_record_for with no state repo reads the log union alone" \
  "2099-06-01T00:00:00Z" \
  "$(printf '%s\n' "$xai_hit_only" | limit_governing_record_for "" "$fs_a" xai | jq -r '.resume_at')"

# With a real flag published too, the later of the flag and the union governs
# — the same "later resume wins" rule, now exercised across both carriers at
# once rather than just within the union (above) or just within the flag
# (fleet_limit_publish's own extend-only guard).
fleet_limit_publish "$slug" "$fs_a" "2050-01-01T00:00:00Z" "monthly-spend" true node-a "" xai
union_earlier_than_flag="$(printf '%s\n' \
  '{"ts":"2026-03-01T00:00:00Z","event":"limit-hit","resume_at":"2040-01-01T00:00:00Z","provider":"xai"}')"
assert_eq "limit_governing_record_for picks the flag when IT is the later carrier" \
  "2050-01-01T00:00:00Z" \
  "$(printf '%s\n' "$union_earlier_than_flag" | limit_governing_record_for "$slug" "$fs_a" xai | jq -r '.resume_at')"

union_later_than_flag="$(printf '%s\n' \
  '{"ts":"2026-03-01T00:00:00Z","event":"limit-hit","resume_at":"2060-01-01T00:00:00Z","provider":"xai"}')"
assert_eq "…and picks the log union when IT is the later carrier" \
  "2060-01-01T00:00:00Z" \
  "$(printf '%s\n' "$union_later_than_flag" | limit_governing_record_for "$slug" "$fs_a" xai | jq -r '.resume_at')"

assert_eq "a provider the flag doesn't name and the union says nothing about has no governing record" \
  "" "$(printf '%s\n' "$union_earlier_than_flag" | limit_governing_record_for "$slug" "$fs_a" anthropic | jq -r '.resume_at // empty')"
rm -f "$gh_backing/fleet/limit.json"

# ===== The credit mix's live lever, lib/mix.sh (issue #2244, D30) =============
# `fleet/mix.json` is a fifth member of this file's own fleet-flag family —
# `mix_write`/`mix_reset` below are thin wrappers over `fleet_flag_write`/
# `_fetch`/`_delete`, exercised here at the lib level; the CLI surface
# (`agent-cycle.sh --mix`) is exercised further down, alongside
# --kill-merge-autonomy, in the offline e2e section.
# shellcheck source=lib/model-id.sh
. "$SCRIPT_DIR/lib/model-id.sh"
# shellcheck source=lib/substrate-claude-code.sh
. "$SCRIPT_DIR/lib/substrate-claude-code.sh"
# shellcheck source=lib/mix.sh
. "$SCRIPT_DIR/lib/mix.sh"

providers_load "{}"
fs_mix="$tmp_dir/fleet-state-mix"; mkdir -p "$fs_mix"

# --- mix_build_overlay: the same validation and messages as config.json's own
# providers.*.lanes block (lib/config-schema.sh's config_provider_errors) ---

ov="$(mix_build_overlay anthropic "api=70" "subscription=30" "subscription.enabled=true")"
assert_eq "mix_build_overlay builds the overlay from <lane>=<weight> and <lane>.enabled=true" \
  '{"api":{"weight":70},"subscription":{"weight":30,"enabled":true}}' "$ov"

ov_balance="$(mix_build_overlay anthropic "subscription.balance_usd=40")"
assert_eq "a balance_usd assignment stamps balance_as_of at the same instant" \
  "$(_toggle_iso)" "$(jq -r '.subscription.balance_as_of' <<<"$ov_balance")"
assert_eq "…alongside the balance itself" "40" "$(jq -r '.subscription.balance_usd' <<<"$ov_balance")"

mix_build_overlay anthropic "subscription.enabled=false" >/dev/null 2>/tmp/mix-err-$$
assert_eq "enabled=false is refused, not silently accepted" "64" "$?"
assert_contains "…naming --close-lane as the way to actually close a lane" \
  "--close-lane" "$(cat /tmp/mix-err-$$)"
rm -f /tmp/mix-err-$$

mix_build_overlay anthropic "api=-1" >/dev/null 2>/tmp/mix-err-$$
assert_eq "a negative weight is refused" "64" "$?"
assert_contains "…with the same message config.json's own validation gives" \
  "weight must be an integer >= 0" "$(cat /tmp/mix-err-$$)"
rm -f /tmp/mix-err-$$

mix_build_overlay anthropic "api=1.5" >/dev/null 2>/tmp/mix-err-$$
assert_eq "a non-integer weight is refused" "64" "$?"
rm -f /tmp/mix-err-$$

mix_build_overlay anthropic "xai.weight=1" >/dev/null 2>/tmp/mix-err-$$
assert_eq "an unknown lane is refused" "64" "$?"
assert_contains "…naming the lane" 'unknown lane "xai"' "$(cat /tmp/mix-err-$$)"
rm -f /tmp/mix-err-$$

mix_build_overlay anthropic "api.spend_cap_usd=5" >/dev/null 2>/tmp/mix-err-$$
assert_eq "an unknown key (a cap or a floor) is refused — this lever carries no closures" "64" "$?"
rm -f /tmp/mix-err-$$

# --- mix_write: writes the flag with provenance, and merges onto what is
# already there rather than replacing it outright ---

mix_write "$slug" "$fs_mix" anthropic "$ov" "operator pid 1" "operator" >/dev/null
assert_eq "mix_write publishes fleet/mix.json" "1" \
  "$(test -f "$gh_backing/fleet/mix.json" && echo 1 || echo 0)"
assert_eq "it carries the provider's own lanes" "70" \
  "$(fleet_flag_fetch "$slug" "$fs_mix" mix | jq -r '.providers.anthropic.lanes.api.weight')"
assert_eq "it attributes itself (by)" "operator pid 1" \
  "$(fleet_flag_fetch "$slug" "$fs_mix" mix | jq -r '.by')"
assert_eq "…and (actor)" "operator" \
  "$(fleet_flag_fetch "$slug" "$fs_mix" mix | jq -r '.actor')"
assert_eq "…and ts" "$(_toggle_iso)" \
  "$(fleet_flag_fetch "$slug" "$fs_mix" mix | jq -r '.ts')"

mix_write "$slug" "$fs_mix" anthropic '{"subscription":{"enabled":true}}' "operator pid 2" "operator" >/dev/null
assert_eq "a second write restates incrementally — api's own weight survives untouched" \
  "70" "$(fleet_flag_fetch "$slug" "$fs_mix" mix | jq -r '.providers.anthropic.lanes.api.weight')"
assert_eq "…while the new field actually lands" "true" \
  "$(fleet_flag_fetch "$slug" "$fs_mix" mix | jq -r '.providers.anthropic.lanes.subscription.enabled')"

mix_write "$slug" "$fs_mix" xai '{"api":{"weight":5}}' "operator pid 3" "operator" >/dev/null
assert_eq "a second provider's entry does not disturb the first's" "70" \
  "$(fleet_flag_fetch "$slug" "$fs_mix" mix | jq -r '.providers.anthropic.lanes.api.weight')"

# --- mix_write's own CAS retry: a stale sha on the first attempt re-reads and
# lands on the second, the same two-attempt shape fleet_limit_publish uses.
#
# The peer's own concurrent write actually *lands* in the stub below, between
# this process's read and its losing PUT, and it names a different provider
# (`xai`) than the one under test (`anthropic`). That is what makes this case
# able to tell a genuine re-read from a memo hit at all: mix_write's body is a
# whole-file replacement built from what it read, so a second attempt served
# `fleet_flag_fetch_status`' own per-process memo — which `fleet_flag_write`
# drops only on a *successful* PUT — re-sends the pre-peer snapshot against a
# sha it does read fresh, and silently deletes `xai` while reporting success.
# A stub that merely fails the first PUT without changing the file's content
# leaves the two indistinguishable, so `xai` is the whole assertion here. ---

race_backing="$tmp_dir/mix-race-remote"; mkdir -p "$race_backing/fleet"
jq -nc '{providers:{anthropic:{lanes:{api:{weight:1}}}}, by: "seed", actor: "seed", ts: "2026-07-17T00:00:00Z"}' \
  > "$race_backing/fleet/mix.json"
race_put_count="$tmp_dir/mix-race-put-count"
: > "$race_put_count"
race_stub="$tmp_dir/mix-race-gh-stub"
cat > "$race_stub" <<STUB
#!/usr/bin/env bash
set -uo pipefail
backing="$race_backing"
put_count_file="$race_put_count"
method=GET path="" jq_expr=""
declare -A f=()
args=("\$@"); i=0
while (( i < \${#args[@]} )); do
  a="\${args[\$i]}"
  case "\$a" in
    -X)      i=\$((i+1)); method="\${args[\$i]}" ;;
    --jq)    i=\$((i+1)); jq_expr="\${args[\$i]}" ;;
    -f)      i=\$((i+1)); kv="\${args[\$i]}"; f["\${kv%%=*}"]="\${kv#*=}" ;;
    repos/*) path="\$a" ;;
  esac
  i=\$((i+1))
done
if [[ "\$path" == repos/*/* && "\$path" != */contents/* ]]; then echo '{}'; exit 0; fi
rel="\${path#repos/*/*/contents/}"; rel="\${rel%%\?*}"
file="\$backing/\$rel"
sha_of() { sha1sum "\$1" | awk '{print \$1}'; }
case "\$method" in
  GET)
    [[ -f "\$file" ]] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    if [[ "\$jq_expr" == ".sha" ]]; then sha_of "\$file"; exit 0; fi
    jq -n --arg c "\$(base64 -w0 < "\$file")" --arg s "\$(sha_of "\$file")" '{content: \$c, sha: \$s}'
    ;;
  PUT)
    echo x >> "\$put_count_file"
    # The first PUT this process ever attempts loses the race outright — a
    # peer's own concurrent write landed between this process's read and its
    # PUT — whatever sha it offers. That peer's write is applied here, for
    # real, so the second attempt must re-read to see it. Every later attempt
    # behaves like the ordinary stub: real CAS against the file's live sha.
    if [[ \$(wc -l < "\$put_count_file") -eq 1 ]]; then
      jq -c '.providers.xai = {lanes:{api:{weight:5}}} | .by = "peer"' "\$file" \\
        > "\$file.peer" && mv "\$file.peer" "\$file"
      echo "gh: sha mismatch (HTTP 409)" >&2; exit 1
    fi
    if [[ -f "\$file" ]]; then
      [[ "\${f[sha]:-}" == "\$(sha_of "\$file")" ]] || { echo "gh: sha mismatch (HTTP 409)" >&2; exit 1; }
    fi
    mkdir -p "\$(dirname "\$file")"
    printf '%s' "\${f[content]:?}" | base64 -d > "\$file"
    ;;
esac
STUB
chmod +x "$race_stub"
TOGGLE_GH="$race_stub" GH_STUB_BACKING="$race_backing" \
  mix_write "$slug" "$tmp_dir/fs-race" anthropic '{"api":{"weight":99}}' "operator pid 4" "operator" >/dev/null
assert_eq "mix_write's own retry converges past a stale-sha PUT" "0" "$?"
assert_eq "…and the second attempt actually landed" "99" \
  "$(jq -r '.providers.anthropic.lanes.api.weight' "$race_backing/fleet/mix.json")"
assert_eq "…having tried the PUT exactly twice" "2" "$(wc -l < "$race_put_count")"
assert_eq "…and the peer's own concurrent entry survived the retry" "5" \
  "$(jq -r '.providers.xai.lanes.api.weight // "ERASED"' "$race_backing/fleet/mix.json")"

# --- mix_write reads past a memo this same process already filled: the real
# `agent-cycle.sh --mix` path calls providers_apply_mix at startup (line 1255)
# long before run_manage_command reaches mix_write, and that read memoises the
# flag for the identical (NAME, STATE_DIR, MODE) key. Without
# _mix_fetch_confirmed's FRESH, mix_write's *first* attempt never touches the
# network at all, so anything a peer wrote in between is erased on a PUT whose
# own sha was read fresh — and no retry is even involved. ---

memo_backing="$tmp_dir/mix-memo-remote"; mkdir -p "$memo_backing/fleet"
jq -nc '{providers:{anthropic:{lanes:{api:{weight:1}}}}, by: "seed", actor: "seed", ts: "2026-07-17T00:00:00Z"}' \
  > "$memo_backing/fleet/mix.json"
fs_memo="$tmp_dir/fleet-state-mix-memo"; mkdir -p "$fs_memo"
PROVIDER_LANES=()
providers_load "{}"
TOGGLE_GH="$gh_stub" GH_STUB_BACKING="$memo_backing" \
  providers_apply_mix "$slug" "$fs_memo"
# The peer's entry lands after this process's startup read, before its write.
jq -c '.providers.xai = {lanes:{api:{weight:5}}} | .by = "peer"' "$memo_backing/fleet/mix.json" \
  > "$memo_backing/fleet/mix.json.peer"
mv "$memo_backing/fleet/mix.json.peer" "$memo_backing/fleet/mix.json"
TOGGLE_GH="$gh_stub" GH_STUB_BACKING="$memo_backing" \
  mix_write "$slug" "$fs_memo" anthropic '{"api":{"weight":42}}' "operator pid 5" "operator" >/dev/null
assert_eq "mix_write after this process's own providers_apply_mix lands its edit" "42" \
  "$(jq -r '.providers.anthropic.lanes.api.weight' "$memo_backing/fleet/mix.json")"
assert_eq "…without replaying the startup read's memo over a peer's later entry" "5" \
  "$(jq -r '.providers.xai.lanes.api.weight // "ERASED"' "$memo_backing/fleet/mix.json")"

# --- Neither writer proceeds on an answer GitHub did not confirm. Every read
# of this flag fails open (requirement 2.3e), because the lever can only open
# a lane; a *write* has no such safe direction — its body replaces the whole
# file, so building one from a cached or unreachable answer deletes every
# entry written since. mix_reset additionally must not report `absent`, which
# the CLI prints as "config.json already governs": a reset that never ran. ---

# `fs_dead` is a state dir no fetch has ever filled, so there is no cached
# copy either — the `unreachable` answer, not `cached`.
fs_dead="$tmp_dir/fleet-state-mix-dead"

GH_STUB_MODE=down mix_write "$slug" "$fs_dead" anthropic '{"api":{"weight":7}}' "operator pid 7" >/dev/null
assert_eq "mix_write refuses outright when the state repo is unreachable" "1" "$?"

GH_STUB_MODE=down mix_reset "$slug" "$fs_dead" anthropic "operator pid 7" >/dev/null
assert_eq "mix_reset refuses rather than reporting a reset it never made" "1" "$?"
assert_eq "…printing nothing, so the CLI's own catch-all warns instead of saying 'absent'" "" \
  "$(GH_STUB_MODE=down mix_reset "$slug" "$fs_dead" anthropic "operator pid 7" 2>/dev/null)"

# The `cached` answer is the dangerous one, and the reason the gate tests the
# status rather than merely asking for a fresh read: a transient failure on
# the read alone, with the write's own sha GET succeeding a moment later,
# hands the writer a cache arbitrarily older than the file it is about to
# replace. Here the cache knows only `anthropic` while the remote already
# carries a peer's `xai`, and only the first GET fails.
cached_backing="$tmp_dir/mix-cached-remote"; mkdir -p "$cached_backing/fleet"
jq -nc '{providers:{anthropic:{lanes:{api:{weight:1}}}, xai:{lanes:{api:{weight:5}}}},
         by: "peer", actor: "peer", ts: "2026-07-17T00:00:00Z"}' \
  > "$cached_backing/fleet/mix.json"
fs_cached="$tmp_dir/fleet-state-mix-cached"
mkdir -p "$fs_cached/fleet-cache"
jq -nc '{providers:{anthropic:{lanes:{api:{weight:1}}}},
         by: "stale", actor: "stale", ts: "2026-07-16T00:00:00Z"}' \
  > "$(fleet_cache_file "$fs_cached" mix)"
flaky_count="$tmp_dir/mix-flaky-get-count"; : > "$flaky_count"
flaky_stub="$tmp_dir/mix-flaky-gh-stub"
cat > "$flaky_stub" <<STUB
#!/usr/bin/env bash
set -uo pipefail
# Only the very first contents GET fails — the writer's own sha read, and
# every later attempt, reach the real stub below.
for a in "\$@"; do
  if [[ "\$a" == */contents/* ]]; then
    echo x >> "$flaky_count"
    if [[ \$(wc -l < "$flaky_count") -eq 1 ]]; then
      echo "dial tcp: could not resolve host github.com" >&2
      exit 1
    fi
  fi
done
exec "$gh_stub" "\$@"
STUB
chmod +x "$flaky_stub"
TOGGLE_GH="$flaky_stub" GH_STUB_BACKING="$cached_backing" \
  mix_write "$slug" "$fs_cached" anthropic '{"api":{"weight":77}}' "operator pid 8" "operator" >/dev/null
assert_eq "mix_write past a transiently-failed read lands on its retry" "77" \
  "$(jq -r '.providers.anthropic.lanes.api.weight' "$cached_backing/fleet/mix.json")"
assert_eq "…never building the replacement body from the stale local cache" "5" \
  "$(jq -r '.providers.xai.lanes.api.weight // "ERASED"' "$cached_backing/fleet/mix.json")"

# --- providers_apply_mix: overlays onto PROVIDER_LANES, fails open on a flag
# too mangled to parse, and MIX_SOURCE names which side supplied each field ---

PROVIDER_LANES=()
providers_load "{}"
providers_apply_mix "$slug" "$fs_mix"
assert_eq "providers_apply_mix overlays the live weight onto PROVIDER_LANES" "70" \
  "$(jq -r '.api.weight' <<<"${PROVIDER_LANES[anthropic]}")"
assert_eq "…leaving an unmentioned field (spend_cap_usd) at its config default" "0" \
  "$(jq -r '.api.spend_cap_usd' <<<"${PROVIDER_LANES[anthropic]}")"
assert_eq "MIX_SOURCE names the fleet flag as api's weight source" "fleet" \
  "$(jq -r '.api.weight' <<<"${MIX_SOURCE[anthropic]}")"
assert_eq "…and config as api's own enabled source (the flag never named it)" "config" \
  "$(jq -r '.api.enabled' <<<"${MIX_SOURCE[anthropic]}")"

printf 'not json at all' > "$gh_backing/fleet/mix.json"
PROVIDER_LANES=()
providers_load "{}"
providers_apply_mix "$slug" "$tmp_dir/fs-mix-garbage"
assert_eq "a garbage flag is reported (non-zero), not silently accepted" "1" "$?"
assert_eq "…and PROVIDER_LANES is left exactly as config resolved it" "1" \
  "$(jq -r '.api.weight' <<<"${PROVIDER_LANES[anthropic]}")"

# --- mix_reset: deletes a provider's own entry, or the whole flag when it was
# the last one ---

fs_reset="$tmp_dir/fleet-state-mix-reset"; mkdir -p "$fs_reset"
rm -f "$gh_backing/fleet/mix.json"
assert_eq "resetting a provider with no live entry at all is a quiet no-op" "absent" \
  "$(mix_reset "$slug" "$fs_reset" anthropic "operator pid 5")"

mix_write "$slug" "$fs_reset" anthropic '{"api":{"weight":40}}' "operator pid 6" >/dev/null
mix_write "$slug" "$fs_reset" xai '{"api":{"weight":5}}' "operator pid 6" >/dev/null
assert_eq "resetting one of two providers leaves the flag written, the other untouched" "written" \
  "$(mix_reset "$slug" "$fs_reset" anthropic "operator pid 7")"
assert_eq "anthropic's own entry is gone" "null" \
  "$(fleet_flag_fetch "$slug" "$fs_reset" mix | jq -c '.providers.anthropic // null')"
assert_eq "xai's survives" "5" \
  "$(fleet_flag_fetch "$slug" "$fs_reset" mix | jq -r '.providers.xai.lanes.api.weight')"

assert_eq "resetting the last provider deletes the whole flag" "deleted" \
  "$(mix_reset "$slug" "$fs_reset" xai "operator pid 8")"
assert_eq "fleet/mix.json is actually gone" "0" \
  "$(test -f "$gh_backing/fleet/mix.json" && echo 1 || echo 0)"

rm -f "$gh_backing/fleet/mix.json"
PROVIDER_LANES=()

# ===== The pipelines honour the fleet flags (offline e2e) =====================
#
# Node A sets the fleet switch with the real management command; node B runs
# the real pipelines. Every external surface is stubbed: TOGGLE_GH is the
# contents-API stub above, STATE_SYNC_REMOTE is a local bare repository (the
# cycle's cleanup push needs somewhere to land), CLAIM_GH fails fast, and a
# PATH shim makes `gh` and `claude` fail fast — a regression that let a cycle
# continue past the fleet checks must die at the next fence, never reach the
# network or a model.

stub_bin="$tmp_dir/stub-bin"
mkdir -p "$stub_bin"
printf '#!/usr/bin/env bash\nexit 1\n' > "$stub_bin/gh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$stub_bin/claude"
chmod +x "$stub_bin/gh" "$stub_bin/claude"

state_remote="$tmp_dir/state-remote.git"
git init --quiet --bare --initial-branch=main "$state_remote"

new_home() {  # new_home <name> -> prints a throwaway node HOME
  local home="$tmp_dir/$1"
  mkdir -p "$home/.local/state/poetic-agents" "$home/.cache/poetic-agents/workspaces"
  printf '%s' "$home"
}

run_node() {  # run_node <home> <script> [args…]
  local home="$1" script="$2"; shift 2
  # DASHBOARD_GH_CMD: agent-cycle.sh's --disable/--enable/--clear-limit/
  # --kill-merge-autonomy/--restore-merge-autonomy paths all end in
  # refresh_dashboard(), which shells out to publish-dashboard.sh as a
  # separate process — TOGGLE_GH's PATH-independent stub reaches every other
  # `gh` call this section makes, but not that one, since publish-dashboard.sh
  # resolves `gh` through this seam instead of PATH (see its own PATH comment).
  # Left unset, that call reaches the real `gh` and the real network the rest
  # of this section is built to avoid (TD-PPagop-26080701). $stub_bin/gh's
  # unconditional `exit 1` is exactly the "fail fast" this offline e2e wants.
  env HOME="$home" AGENT_OPS_ROLE=active NODE_NAME="$(basename "$home")" \
    PATH="$stub_bin:$PATH" TOGGLE_GH="$gh_stub" GH_STUB_BACKING="$gh_backing" \
    DASHBOARD_GH_CMD="$stub_bin/gh" \
    CLAIM_GH=/bin/false STATE_SYNC_REMOTE="$state_remote" \
    GIT_USER_NAME="Test Node" GIT_USER_EMAIL="test-node@example.invalid" \
    "$SCRIPT_DIR/$script" "$@"
}

# direct_enable HOME [--this-node]
# The state-only equivalent of `agent-cycle.sh --enable`/`--enable
# --this-node`: clears the local record and, unless --this-node, the shared
# fleet flag too (mirroring lib/manage.sh's `enable)` branch — a plain
# --enable always attempts the fleet delete when a state repo is configured,
# whether or not there was a local record to clear).
#
# Used only where a run_node --enable exists purely to reset fleet/node state
# for a *later* assertion, and nothing checks this step's own output, exit
# code or log — --enable's CLI wiring (the message it prints, the log event,
# refresh_dashboard) is already exercised by the real --enable subprocess
# calls elsewhere in this file, so re-paying a full script spawn here would
# prove nothing this file does not already prove.
direct_enable() {
  local home="$1" this_node="${2:-}" state_dir
  state_dir="$home/.local/state/poetic-agents"
  toggle_clear "$state_dir" >/dev/null
  if [[ "$this_node" != "--this-node" ]]; then
    fleet_flag_delete "$slug" "$state_dir" disabled >/dev/null 2>&1 || true
  fi
}

# direct_disable HOME REASON SPEC MODE [--this-node]
# The state-only equivalent of `agent-cycle.sh --disable`/`--drain` (MODE is
# "stop" or "drain"), --this-node included: writes the local record and,
# unless --this-node, publishes the identical record as the fleet flag too
# (mirroring lib/manage.sh's `disable)`/`drain)` branches, which both tag the
# local record's scope "fleet" and publish it whenever a state repo is
# configured and --this-node was not given).
#
# Same justification as direct_enable: only for a run_node --disable/--drain
# that exists to put a node into a known state for a later assertion, with no
# assertion reading this step's own output. `by`/`actor` are cosmetic here —
# no assertion this function replaces inspects them — chosen only to look
# like a real record if a failure ever prints one for debugging.
direct_disable() {
  local home="$1" reason="$2" spec="$3" mode="$4" this_node="${5:-}"
  local state_dir scope rec
  state_dir="$home/.local/state/poetic-agents"
  scope=fleet
  [[ "$this_node" == "--this-node" ]] && scope=node
  rec="$(toggle_disable "$state_dir" "$reason" "$spec" 4 "test-setup pid $$" \
    "$(basename "$home")" manual "$scope" "$mode")"
  if [[ "$scope" == "fleet" ]]; then
    fleet_flag_write "$slug" disabled "$rec" "fleet: test setup" "$state_dir" >/dev/null 2>&1 || true
  fi
  return 0
}

a_home="$(new_home fleet-node-a)"
b_home="$(new_home fleet-node-b)"
a_log="$a_home/.local/state/poetic-agents/log.jsonl"
b_log="$b_home/.local/state/poetic-agents/log.jsonl"
b_review_log="$b_home/.local/state/poetic-agents/review-log.jsonl"

# A disables; the flag must land in the state repo, not just locally.
disable_out="$(run_node "$a_home" agent-cycle.sh --disable "fleet e2e halt" --for forever 2>&1)"
assert_contains "--disable reports the fleet switch set" "fleet switch set" "$disable_out"
assert_eq "--disable publishes fleet/disabled.json" "1" \
  "$(test -f "$gh_backing/fleet/disabled.json" && echo 1 || echo 0)"
# The published record attributes itself (#244): the node that set it, never
# `unknown`, and the manual kind that tells a probe to keep its hands off.
assert_eq "the fleet switch names the node that set it" "fleet-node-a" \
  "$(jq -r '.actor' "$gh_backing/fleet/disabled.json")"
assert_eq "and records a manual kind" "manual" \
  "$(jq -r '.kind' "$gh_backing/fleet/disabled.json")"
# Requirement 33 (issue #426): the `disabled` event records the scope the
# operator asked for and the outcome of reaching the fleet flag, so a reader
# can tell a fleet-wide stop from a node-scoped one without cross-referencing
# fleet/disabled.json.
assert_contains "and the disabled event carries fleet scope" '"scope":"fleet"' \
  "$(cat "$a_log" 2>/dev/null)"
assert_contains "and reports the fleet flag write as ok" '"fleet_flag":"ok"' \
  "$(cat "$a_log" 2>/dev/null)"

# A second --disable over the live switch is an extension, and the log says
# so rather than presenting a fresh stop.
run_node "$a_home" agent-cycle.sh --disable "fleet e2e halt, extended" --for forever >/dev/null 2>&1
assert_contains "re-disabling records the switch it extends" '"extends"' \
  "$(cat "$a_home/.local/state/poetic-agents/log.jsonl" 2>/dev/null)"

# B's implementation cycle stands down for it.
run_node "$b_home" agent-cycle.sh >/dev/null 2>&1
assert_eq "a cycle on another node exits cleanly under the fleet switch" "0" "$?"
assert_contains "and logs a fleet-switch stand-down" '"event":"stand-down"' "$(cat "$b_log" 2>/dev/null)"
assert_contains "naming the fleet switch as the reason" 'fleet switch' "$(cat "$b_log" 2>/dev/null)"

# B's review cycle stands down for it too.
run_node "$b_home" review-cycle.sh >/dev/null 2>&1
assert_eq "a review on another node exits cleanly under the fleet switch" "0" "$?"
assert_contains "and logs a fleet-switch review-stand-down" 'fleet switch' "$(cat "$b_review_log" 2>/dev/null)"

# A re-enables; the fleet flag must actually be gone.
enable_out="$(run_node "$a_home" agent-cycle.sh --enable 2>&1)"
assert_contains "--enable reports the fleet switch clear" "fleet switch clear" "$enable_out"
assert_eq "--enable removes fleet/disabled.json" "0" \
  "$(test -f "$gh_backing/fleet/disabled.json" && echo 1 || echo 0)"
assert_contains "and the enabled event carries fleet scope" '"scope":"fleet"' \
  "$(cat "$a_log" 2>/dev/null)"
assert_contains "and reports the fleet flag delete as ok" '"fleet_flag":"ok"' \
  "$(cat "$a_log" 2>/dev/null)"

# TD-PPagop-26081604 (e2e): a repo-level 404 on the fleet flag's own delete
# must not read through the real --enable command as a clear fleet switch.
# The local record still clears (that write never touched the state repo),
# but the fleet flag's own state is unconfirmed, and the operator must be
# warned rather than told the fleet switch is clear.
c_home="$(new_home fleet-node-c)"
# Setup only: nothing below asserts anything about this write itself, only
# about the --enable that follows it, so it is a direct record write rather
# than a real agent-cycle.sh subprocess (see direct_disable's own header).
direct_disable "$c_home" "e2e unconfirmed-clear setup" forever stop
rm -f "$gh_backing/fleet/disabled.json"
unconfirmed_enable_out="$(GH_STUB_MODE=repo-404 run_node "$c_home" agent-cycle.sh --enable 2>&1)"
assert_eq "--enable still exits cleanly when the fleet flag could not be confirmed cleared" "0" "$?"
assert_contains "and warns rather than claiming the fleet switch is clear" \
  "could not clear the fleet switch" "$unconfirmed_enable_out"
assert_contains "naming the manual fallback" \
  "delete fleet/disabled.json in" "$unconfirmed_enable_out"
assert_eq "the local record still cleared, since that write never reaches the state repo" "0" \
  "$(test -f "$c_home/.local/state/poetic-agents/disabled.json" && echo 1 || echo 0)"

# Requirement 33 (issue #426, acceptance 4): a node with no local disable of
# its own must still log `enabled` when a live fleet flag it clears — the
# defect this closes let the fleet coming back up go unlogged whenever the
# node running --enable had no local record to report.
rec_fleet_only="$(jq -nc '{disabled_at: "2026-07-17T09:00:00Z", expires_at: null, by: "operator@laptop pid 1", reason: "another node froze the fleet", actor: "operator@laptop", kind: "manual"}')"
fleet_flag_write "$slug" disabled "$rec_fleet_only" "fleet freeze set by another node"
assert_eq "no local record on A going into this scenario" "0" \
  "$(test -f "$a_home/.local/state/poetic-agents/disabled.json" && echo 1 || echo 0)"
rm -f "$a_log"
no_local_enable_out="$(run_node "$a_home" agent-cycle.sh --enable 2>&1)"
assert_contains "--enable still reports the fleet switch clear with no local record" \
  "fleet switch clear" "$no_local_enable_out"
assert_contains "and logs enabled even though there was nothing local to clear" \
  '"event":"enabled"' "$(cat "$a_log" 2>/dev/null)"
assert_contains "naming the fleet scope" '"scope":"fleet"' "$(cat "$a_log" 2>/dev/null)"
assert_contains "and the fleet flag outcome as ok" '"fleet_flag":"ok"' "$(cat "$a_log" 2>/dev/null)"

# --- --this-node (issue #379): a node-scoped stand-down that never touches
# the fleet flag -------------------------------------------------------------

# Reset the log so the scope/fleet_flag assertions below read only this
# block's own event, not the fleet-scoped ones the sections above logged.
rm -f "$a_log"

# `--disable --this-node` writes only the local record and never publishes
# the fleet flag.
this_disable_out="$(run_node "$a_home" agent-cycle.sh --disable "editing lib/" --this-node --for 1h 2>&1)"
assert_contains "--disable --this-node says plainly only this node stands down" \
  "only" "$this_disable_out"
assert_not_contains "--disable --this-node never reports the fleet switch set" \
  "fleet switch set" "$this_disable_out"
assert_eq "--disable --this-node writes the local record" "1" \
  "$(test -f "$a_home/.local/state/poetic-agents/disabled.json" && echo 1 || echo 0)"
assert_eq "--disable --this-node writes no fleet flag" "0" \
  "$(test -f "$gh_backing/fleet/disabled.json" && echo 1 || echo 0)"
assert_contains "and the disabled event carries node scope, not fleet" \
  '"scope":"node"' "$(cat "$a_log" 2>/dev/null)"
assert_not_contains "and carries no fleet_flag outcome at all" \
  '"fleet_flag"' "$(cat "$a_log" 2>/dev/null)"

# `--status` has to say which of the two levels is down and which command
# lifts it (requirement 2.3) — an operator who finds a node stopped learns
# nothing from "DISABLED" alone. Here only the local record is set.
local_only_status="$(run_node "$a_home" agent-cycle.sh --status 2>&1)"
assert_contains "--status reports the node-scoped switch as disabled" \
  "switch:   DISABLED" "$local_only_status"
assert_contains "and reports no fleet switch alongside it" \
  "fleet:    not set" "$local_only_status"
assert_contains "naming --enable --this-node as what clears it" \
  "--enable --this-node clears it" "$local_only_status"

# A peer is unaffected: no fleet flag was ever set, so its own cycle runs.
# (The log is reset first: it still carries the fleet-switch stand-downs the
# earlier block in this file logged, before that flag was cleared.)
rm -f "$b_log"
run_node "$b_home" agent-cycle.sh >/dev/null 2>&1
assert_eq "a peer's cycle is unaffected by another node's --this-node disable" "0" "$?"
assert_not_contains "and does not stand the peer down" \
  '"event":"stand-down"' "$(cat "$b_log" 2>/dev/null)"

# `--enable --this-node` must leave a fleet flag someone else set alone: the
# local record is this node's own decision to undo, the fleet flag is not.
rec_fleet="$(jq -nc '{disabled_at: "2026-07-17T10:00:00Z", expires_at: null, by: "operator@laptop pid 1", reason: "fleet freeze", actor: "operator@laptop", kind: "manual"}')"
fleet_flag_write "$slug" disabled "$rec_fleet" "fleet freeze for the test"
rm -f "$a_log"
enable_this_out="$(run_node "$a_home" agent-cycle.sh --enable --this-node 2>&1)"
assert_not_contains "--enable --this-node does not claim the fleet switch cleared" \
  "fleet switch clear" "$enable_this_out"
assert_eq "--enable --this-node leaves the fleet flag set" "1" \
  "$(test -f "$gh_backing/fleet/disabled.json" && echo 1 || echo 0)"
assert_eq "--enable --this-node clears the local record" "0" \
  "$(test -f "$a_home/.local/state/poetic-agents/disabled.json" && echo 1 || echo 0)"
assert_contains "and the enabled event carries node scope even with a live fleet flag" \
  '"scope":"node"' "$(cat "$a_log" 2>/dev/null)"
assert_not_contains "and never claims a fleet_flag outcome it never touched" \
  '"fleet_flag"' "$(cat "$a_log" 2>/dev/null)"

# The mirror image of the `--status` case above: the fleet flag alone is set,
# so what this node needs told is that a plain `--enable` is the one that
# lifts it, and that nothing local is holding it down as well.
fleet_only_status="$(run_node "$a_home" agent-cycle.sh --status 2>&1)"
assert_contains "--status reports a fleet switch this node did not set" \
  "fleet:    DISABLED" "$fleet_only_status"
assert_contains "carrying the record's own reason" "fleet freeze" "$fleet_only_status"
assert_contains "and says this node adds no node-scoped disable of its own" \
  "no node-scoped disable of its own" "$fleet_only_status"
assert_contains "so a plain --enable resumes the whole fleet" \
  "every node resumes" "$fleet_only_status"

# A node carrying both a node-scoped disable and the (still-set) fleet switch
# stays down when only the node-scoped one is cleared.
# Setup only: only the --status call right below is asserted on.
direct_disable "$a_home" "editing again" 1h stop --this-node

# With both set, `--status` has to spell out the asymmetry rather than
# reporting two disables and leaving the operator to guess which `--enable`
# undoes which — the case the distinction exists for.
both_status="$(run_node "$a_home" agent-cycle.sh --status 2>&1)"
assert_contains "--status under both switches reports the node-scoped one" \
  "switch:   DISABLED" "$both_status"
assert_contains "and the fleet one beside it" "fleet:    DISABLED" "$both_status"
assert_contains "saying --enable clears both" "--enable clears both" "$both_status"
assert_contains "and that --enable --this-node leaves the node down under the fleet switch" \
  "leaving the fleet switch" "$both_status"

rm -f "$a_log"
run_node "$a_home" agent-cycle.sh >/dev/null 2>&1
assert_eq "a node under both switches exits cleanly" "0" "$?"
assert_contains "and stands down for its own node-scoped switch first" \
  '"reason":"disabled:' "$(cat "$a_log" 2>/dev/null)"

# Setup only: the cycle run right below is what is asserted on.
direct_enable "$a_home" --this-node
rm -f "$a_log"
run_node "$a_home" agent-cycle.sh >/dev/null 2>&1
assert_eq "clearing only the node-scoped switch still exits cleanly" "0" "$?"
assert_contains "but the node still stands down, now for the fleet switch" \
  'fleet switch' "$(cat "$a_log" 2>/dev/null)"

# Clean up the fleet flag this block set, so the baseline the rest of this
# file assumes ("nothing set" going into the limit tests below) still holds.
fleet_flag_delete "$slug" "$fs_a" disabled >/dev/null

# A node-scoped disable still expires on its own TTL, exactly like the fleet
# one — --this-node changes only which levels a write reaches, never how a
# record already written decides it has lapsed.
# Setup only (clock already pinned to 1784289600, lib/toggle.sh's own
# TOGGLE_NOW_EPOCH): the cycle run below, past the TTL, is what is asserted.
direct_disable "$a_home" "editing" 1h stop --this-node
rm -f "$a_log"
TOGGLE_NOW_EPOCH=$(( 1784289600 + 3900 )) run_node "$a_home" agent-cycle.sh >/dev/null 2>&1
assert_eq "a cycle past a node-scoped disable's TTL exits cleanly" "0" "$?"
assert_contains "and the expired node-scoped disable is cleared and logged" \
  '"detail":"disable expired"' "$(cat "$a_log" 2>/dev/null)"
assert_eq "the local record is gone once it has expired" "0" \
  "$(test -f "$a_home/.local/state/poetic-agents/disabled.json" && echo 1 || echo 0)"
# Requirement 33 (issue #426): the two automatic-expiry sites fold into the
# same scope/fleet_flag vocabulary the --disable/--enable command paths use —
# this one only ever touches the local record, so it is node-scoped and
# carries no fleet_flag at all.
assert_contains "and the expiry event carries node scope" \
  '"scope":"node"' "$(cat "$a_log" 2>/dev/null)"
assert_not_contains "and no fleet_flag outcome, since only the local record was touched" \
  '"fleet_flag"' "$(cat "$a_log" 2>/dev/null)"

# The fleet-level counterpart: a fleet-wide disable past its TTL is cleared by
# whichever node's cycle sees it first, and that clear now reports whether the
# fleet flag delete actually succeeded (defect 3 in issue #426 — the old code
# discarded fleet_flag_delete's result with `|| true`).
rec_fleet_ttl="$(jq -nc '{disabled_at: "2026-07-17T11:00:00Z", expires_at: "2026-07-17T12:00:00Z", by: "operator@laptop pid 1", reason: "fleet TTL test", actor: "operator@laptop", kind: "manual"}')"
fleet_flag_write "$slug" disabled "$rec_fleet_ttl" "fleet freeze for the expiry test"
rm -f "$a_log"
TOGGLE_NOW_EPOCH=$(( 1784289600 + 4 * 3600 )) run_node "$a_home" agent-cycle.sh >/dev/null 2>&1
assert_eq "a cycle past a fleet-wide disable's TTL exits cleanly" "0" "$?"
assert_contains "and the expired fleet disable is cleared and logged" \
  '"detail":"fleet disable expired"' "$(cat "$a_log" 2>/dev/null)"
assert_contains "carrying fleet scope" '"scope":"fleet"' "$(cat "$a_log" 2>/dev/null)"
assert_contains "and reporting the delete as ok" '"fleet_flag":"ok"' "$(cat "$a_log" 2>/dev/null)"
assert_eq "the fleet flag is actually gone, not just locally forgotten" "0" \
  "$(test -f "$gh_backing/fleet/disabled.json" && echo 1 || echo 0)"

# --this-node is a modifier on --disable/--enable only.
this_status_out="$(run_node "$a_home" agent-cycle.sh --status --this-node 2>&1)"
assert_eq "--this-node with --status is a usage error" "64" "$?"
assert_contains "and says so" "only modifies --disable, --drain or --enable" "$this_status_out"

# --- `scope` (requirement 2.3): the local half of a fleet-wide --disable is a
# mirror, not a second decision ----------------------------------------------
#
# An unmodified --disable writes both levels, so the node that issues a
# fleet-wide stand-down ends up holding a local record byte-identical to a
# --this-node one. Untagged, every reader announced a node-scoped disable
# nobody had asked for, and that one node of a uniformly-down fleet wore the
# dashboard's amber `disabled` badge while its equally-stopped peers wore none.

a_switch="$a_home/.local/state/poetic-agents/disabled.json"

run_node "$a_home" agent-cycle.sh --disable "resize the VM" --for forever >/dev/null 2>&1
assert_eq "an unmodified --disable tags its local record as a fleet mirror" "fleet" \
  "$(jq -r '.scope' "$a_switch" 2>/dev/null)"
assert_eq "and still publishes the fleet flag" "1" \
  "$(test -f "$gh_backing/fleet/disabled.json" && echo 1 || echo 0)"

assert_eq "and caches the flag it just wrote, like a successful fetch would" "1" \
  "$(test -f "$a_home/.local/state/poetic-agents/fleet-cache/disabled.json" && echo 1 || echo 0)"

mirror_status="$(run_node "$a_home" agent-cycle.sh --status 2>&1)"
assert_contains "--status names the local record as this fleet switch's mirror" \
  "mirrors this fleet switch" "$mirror_status"
assert_not_contains "and never reports it as a second, node-scoped disable" \
  "also carries its own node-scoped disable" "$mirror_status"

# The writer must not be the one node blind to a flag it set: with the state
# repo unreachable it reads its own cache and still reports the fleet switch,
# rather than falling through this level's fail-open to the orphan wording
# below — which would tell an operator mid-outage that the switch they had
# just set had been cleared.
export GH_STUB_MODE=down
offline_mirror_status="$(run_node "$a_home" agent-cycle.sh --status 2>&1)"
unset GH_STUB_MODE
assert_contains "an unreachable state repo still reports the fleet switch from cache" \
  "fleet:    DISABLED" "$offline_mirror_status"
assert_not_contains "and never mistakes an outage for a switch cleared elsewhere" \
  "has since been cleared" "$offline_mirror_status"

# The mirror is this node's fail-*closed* hold on itself for exactly the window
# where the fleet flag cannot be read — that flag fails open — so clearing it
# under a live fleet switch is how a node resumes the work the fleet was stood
# down to prevent. --enable --this-node must refuse rather than oblige.
mirror_enable_out="$(run_node "$a_home" agent-cycle.sh --enable --this-node 2>&1)"
assert_eq "--enable --this-node refuses a fleet mirror" "64" "$?"
assert_contains "naming plain --enable as what undoes a fleet-wide disable" \
  "Use --enable" "$mirror_enable_out"
assert_eq "and leaves the mirror in place" "1" \
  "$(test -f "$a_switch" && echo 1 || echo 0)"

# The orphan, and the reason the tag is worth carrying: --enable on a *peer*
# clears the fleet flag but cannot reach this node's file, so this node alone
# stays down under a decision lifted elsewhere — indefinitely, on `--for
# forever`. Untagged it read as a node-scoped disable nobody had set.
run_node "$b_home" agent-cycle.sh --enable >/dev/null 2>&1
assert_eq "a peer's --enable clears the fleet flag" "0" \
  "$(test -f "$gh_backing/fleet/disabled.json" && echo 1 || echo 0)"
orphan_status="$(run_node "$a_home" agent-cycle.sh --status 2>&1)"
assert_contains "--status reports a surviving mirror as a cleared switch's leftover" \
  "mirrors a fleet switch that has since been cleared" "$orphan_status"
assert_contains "and names --enable as what clears it" \
  "--enable clears it" "$orphan_status"

run_node "$a_home" agent-cycle.sh --enable >/dev/null 2>&1
assert_eq "--enable clears the orphaned mirror" "0" \
  "$(test -f "$a_switch" && echo 1 || echo 0)"

# A --disable whose fleet publish fails leaves this node standing down alone,
# so the optimistic `fleet` tag has to be corrected: a record still claiming to
# mirror a switch that was never set would have --status and the dashboard
# describe a fleet-wide stand-down that does not exist.
export GH_STUB_MODE=down
run_node "$a_home" agent-cycle.sh --disable "fleet write will fail" --for 1h >/dev/null 2>&1
unset GH_STUB_MODE
assert_eq "a failed fleet publish retags the local record node-scoped" "node" \
  "$(jq -r '.scope' "$a_switch" 2>/dev/null)"
assert_eq "leaving its disabled_at as first written" "2026-07-17T12:00:00Z" \
  "$(jq -r '.disabled_at' "$a_switch" 2>/dev/null)"
assert_eq "and no fleet flag was published" "0" \
  "$(test -f "$gh_backing/fleet/disabled.json" && echo 1 || echo 0)"
run_node "$a_home" agent-cycle.sh --enable --this-node >/dev/null 2>&1
assert_eq "--enable --this-node clears that one, since it is genuinely node-scoped" "0" \
  "$(test -f "$a_switch" && echo 1 || echo 0)"

# The deliberate single-node case is unchanged, and travels to peers: a card
# rendering another node's switch has to be able to tell the two apart, and
# only the node holding the record knows which it is.
run_node "$a_home" agent-cycle.sh --disable "editing lib/" --this-node --for 1h >/dev/null 2>&1
assert_eq "--disable --this-node tags its record node-scoped" "node" \
  "$(jq -r '.scope' "$a_switch" 2>/dev/null)"
assert_eq "and toggle_switch_summary carries the scope to peers" "node" \
  "$(jq -r '.scope' <<<"$(toggle_switch_summary "$a_home/.local/state/poetic-agents")")"

# A record written before the field existed reads as node-scoped: what such a
# record effectively was, and the direction that keeps a node down rather than
# talking itself out of a stand-down.
jq -c 'del(.scope)' "$a_switch" > "$tmp_dir/legacy-switch.json" && mv "$tmp_dir/legacy-switch.json" "$a_switch"
assert_eq "a record with no scope reads as node-scoped" "node" \
  "$(toggle_scope "$(jq -c '.record // {}' <<<"$(toggle_state "$a_home/.local/state/poetic-agents")")")"
assert_eq "and toggle_switch_summary defaults it the same way" "node" \
  "$(jq -r '.scope' <<<"$(toggle_switch_summary "$a_home/.local/state/poetic-agents")")"

# Back to the baseline the limit tests below assume: nothing set at either
# level. Setup only — no assertion follows this directly.
direct_enable "$a_home"

# A usage limit published by one node stands another node down until resume_at.
fleet_limit_publish "$slug" "$fs_a" "2030-01-01T00:00:00Z" "monthly-spend" true node-a
rm -f "$b_log"
run_node "$b_home" agent-cycle.sh >/dev/null 2>&1
assert_eq "a cycle under a fleet limit flag exits cleanly" "0" "$?"
assert_contains "and stands down until the flag's resume_at" \
  'usage-limit cooldown (anthropic) until 2030-01-01T00:00:00Z' "$(cat "$b_log" 2>/dev/null)"

# --- --clear-limit (2.1a) -------------------------------------------------
# The stand-down must have a supported exit. It arrives on two carriers and
# lifts only when BOTH are retired, so this exercises both at once: the flag
# published by node A above, and a limit-hit in B's own log — the carrier no
# amount of flag-deleting can reach, and the one that made a stand-down
# outlive the limit that caused it.
printf '%s\n' \
  '{"ts":"2026-01-01T00:00:00Z","cycle":"seed","node":"node-b","event":"limit-hit","resume_at":"2030-06-01T00:00:00Z","class":"monthly","reset_known":false}' \
  >> "$b_log"
run_node "$b_home" agent-cycle.sh >/dev/null 2>&1
assert_contains "a limit-hit in the node's own log also stands it down" \
  'usage-limit cooldown' "$(cat "$b_log" 2>/dev/null)"

clear_out="$(run_node "$b_home" agent-cycle.sh --clear-limit "cap raised" 2>&1)"
assert_contains "--clear-limit reports what it lifted" "stand-down lifted" "$clear_out"
assert_contains "--clear-limit reports the fleet flag cleared" "fleet usage-limit flag clear" "$clear_out"
assert_eq "--clear-limit removes fleet/limit.json" "0" \
  "$(test -f "$gh_backing/fleet/limit.json" && echo 1 || echo 0)"
assert_contains "--clear-limit logs a limit-cleared event" \
  '"event":"limit-cleared"' "$(cat "$b_log" 2>/dev/null)"
assert_contains "recording the reason it was given" 'cap raised' "$(cat "$b_log" 2>/dev/null)"

# And the proof it was worth doing: the next cycle no longer stands down for
# the limit. The log is NOT truncated first — the superseded limit-hit must
# still be sitting in it, or this asserts nothing. Only the events the new
# cycle appends are examined.
b_log_before="$(wc -l < "$b_log")"
run_node "$b_home" agent-cycle.sh >/dev/null 2>&1
assert_eq "a cycle after --clear-limit exits cleanly" "0" "$?"
assert_contains "the superseded limit-hit is still in the log" \
  '2030-06-01T00:00:00Z' "$(cat "$b_log" 2>/dev/null)"
assert_not_contains "and the cycle no longer stands down for the usage limit" \
  'usage-limit cooldown' "$(tail -n +$(( b_log_before + 1 )) "$b_log" 2>/dev/null)"
rm -f "$gh_backing/fleet/limit.json"

# --- --clear-limit <provider>: the two faults a scoped clear can hide ------
# Two bare tokens are provider-then-reason, so the first must actually name
# a configured provider: there is no second reading to fall back on, and
# silently scoping the clear to a provider that does not exist would log a
# `limit-cleared` nothing reads and report a stand-down lifted that never
# was. A single token naming no provider is still the reason, as it always
# has been (asserted by the `cap raised` call above).
clear_bad_out="$(run_node "$b_home" agent-cycle.sh --clear-limit "the cap" "was raised" 2>&1)"
assert_eq "--clear-limit rejects a two-token form whose first token names no provider" \
  "64" "$?"
assert_contains "...saying which token it objected to" 'is not a configured provider' "$clear_bad_out"

# A wildcard record — no `provider` field at all, as every record written
# before #2133 is — governs every provider, and NEITHER carrier can express
# "every provider but this one": the union's scoped `limit-cleared` resets
# only that provider's own bucket and leaves the wildcard bucket standing,
# and the flag is left alone rather than deleted out from under whichever
# other provider it covers. So a scoped clear genuinely does not lift it,
# and the operator must be told that rather than reading "stand-down lifted"
# and walking away. Asserted on each carrier separately, because the check
# re-reads the carriers rather than inferring from what it wrote — a check
# keyed on the flag alone would miss the union-only case entirely.
printf '%s\n' '{"resume_at":"2030-01-01T00:00:00Z","class":"monthly-spend","reset_known":true,"kind":"auto","actor":"node-a"}' \
  > "$gh_backing/fleet/limit.json"
clear_wild_out="$(run_node "$b_home" agent-cycle.sh --clear-limit anthropic 2>&1)"
assert_contains "a scoped --clear-limit reports a wildcard flag record as NOT lifted" \
  'is NOT lifted' "$clear_wild_out"
assert_contains "...naming the bare --clear-limit that can remove it" \
  'with no provider' "$clear_wild_out"
assert_eq "...leaving fleet/limit.json in place rather than clearing another provider's too" "1" \
  "$(test -f "$gh_backing/fleet/limit.json" && echo 1 || echo 0)"
rm -f "$gh_backing/fleet/limit.json"

# The same refusal, carried by the log union alone with no flag at all: a
# pre-#2133 limit-hit still sitting in the log. The flag-only form of this
# check reported success here, which is why it is re-read from the carriers.
# The union's own fold is ts-ordered, not append-ordered (fleet_logs sorts the
# whole stream, lib/fleet.sh), so this event's own `ts` has to sort after the
# real clock-stamped `limit-cleared` events the two calls above already wrote
# into this same log a moment ago — a canned past date here would let the
# fold treat those earlier clears as happening *after* this hit and wipe the
# wildcard bucket before the assertions below even run.
printf '%s\n' \
  "{\"ts\":\"$(date -u -d '+10 minutes' +%Y-%m-%dT%H:%M:%SZ)\",\"cycle\":\"seed\",\"node\":\"node-b\",\"event\":\"limit-hit\",\"resume_at\":\"2031-01-01T00:00:00Z\",\"class\":\"monthly\",\"reset_known\":true}" \
  >> "$b_log"
clear_union_out="$(run_node "$b_home" agent-cycle.sh --clear-limit anthropic 2>&1)"
assert_contains "a scoped --clear-limit reports a wildcard *union* record as NOT lifted too" \
  'is NOT lifted' "$clear_union_out"
assert_contains "...naming the resume time still in force" '2031-01-01T00:00:00Z' "$clear_union_out"
# And the bare form, which writes a wildcard limit-cleared, does lift it.
clear_all_out="$(run_node "$b_home" agent-cycle.sh --clear-limit 2>&1)"
assert_contains "while the bare --clear-limit lifts that same wildcard record" \
  'stand-down lifted' "$clear_all_out"

# --- --kill-merge-autonomy / --restore-merge-autonomy (D18, requirement 2.3b) ---
# A third fleet flag, independent of the switch and the limit above: killing
# merge autonomy must publish its own file under its own name and must not
# touch fleet/disabled.json or fleet/limit.json (both already confirmed clear
# by this point in the run).
kill_out="$(run_node "$a_home" agent-cycle.sh --kill-merge-autonomy "Approver App misbehaving" 2>&1)"
assert_contains "--kill-merge-autonomy reports the switch set" \
  "merge-autonomy kill switch set" "$kill_out"
assert_eq "--kill-merge-autonomy publishes fleet/merge-autonomy-kill.json" "1" \
  "$(test -f "$gh_backing/fleet/merge-autonomy-kill.json" && echo 1 || echo 0)"
assert_eq "the record names the actor that set it" "fleet-node-a" \
  "$(jq -r '.actor' "$gh_backing/fleet/merge-autonomy-kill.json")"
assert_eq "and records a manual kind" "manual" \
  "$(jq -r '.kind' "$gh_backing/fleet/merge-autonomy-kill.json")"
assert_eq "and the reason given" "Approver App misbehaving" \
  "$(jq -r '.reason' "$gh_backing/fleet/merge-autonomy-kill.json")"
assert_eq "neither the fleet switch nor the limit flag is touched" "0 0" \
  "$(test -f "$gh_backing/fleet/disabled.json" && echo -n 1 || echo -n 0)$(printf ' ')$(test -f "$gh_backing/fleet/limit.json" && echo -n 1 || echo -n 0)"
assert_contains "the merge-autonomy-killed event is logged" \
  '"event":"merge-autonomy-killed"' "$(cat "$a_log" 2>/dev/null)"

status_out="$(run_node "$a_home" agent-cycle.sh --status 2>&1)"
assert_contains "--status reports the kill switch set" "merge_autonomy: KILLED" "$status_out"
assert_contains "  ... naming what clears it" "--restore-merge-autonomy clears it" "$status_out"

restore_out="$(run_node "$a_home" agent-cycle.sh --restore-merge-autonomy 2>&1)"
assert_contains "--restore-merge-autonomy reports the switch cleared" \
  "merge-autonomy kill switch cleared" "$restore_out"
assert_eq "--restore-merge-autonomy removes fleet/merge-autonomy-kill.json" "0" \
  "$(test -f "$gh_backing/fleet/merge-autonomy-kill.json" && echo 1 || echo 0)"
assert_contains "the merge-autonomy-restored event is logged" \
  '"event":"merge-autonomy-restored"' "$(cat "$a_log" 2>/dev/null)"

status_out2="$(run_node "$a_home" agent-cycle.sh --status 2>&1)"
assert_contains "--status reports the kill switch clear again" "merge_autonomy: not killed" "$status_out2"

# A required reason, the same terms as --disable's.
bare_kill_out="$(run_node "$a_home" agent-cycle.sh --kill-merge-autonomy 2>&1)"
bare_kill_rc=$?
assert_eq "--kill-merge-autonomy with no reason is a usage error" "64" "$bare_kill_rc"
assert_contains "naming what is missing" "needs a reason" "$bare_kill_out"

# Restoring an already-clear switch is a normal, idempotent outcome.
already_clear_out="$(run_node "$a_home" agent-cycle.sh --restore-merge-autonomy 2>&1)"
# Captured here, not after the assert_contains below: assert_contains always
# returns 0 (it counts a failure rather than returning one), so reading `$?`
# after it would compare 0 against 0 and assert nothing at all.
already_clear_rc=$?
assert_contains "--restore-merge-autonomy on an already-clear switch says so" \
  "was not set" "$already_clear_out"
assert_eq "and exits cleanly" "0" "$already_clear_rc"

rm -f "$gh_backing/fleet/merge-autonomy-kill.json"

# --- agent-cycle.sh --mix (issue #2244, D30): the CLI surface over lib/mix.sh,
# a fifth fleet flag built on the same family's fleet_flag_write/_fetch ------

mix_out="$(run_node "$a_home" agent-cycle.sh --mix anthropic api=70 subscription=30 subscription.enabled=true 2>&1)"
assert_contains "--mix reports what it set" "mix set for anthropic" "$mix_out"
assert_eq "--mix publishes fleet/mix.json" "1" \
  "$(test -f "$gh_backing/fleet/mix.json" && echo 1 || echo 0)"
assert_eq "it carries the weights given" "70 30" \
  "$(jq -r '.providers.anthropic.lanes | "\(.api.weight) \(.subscription.weight)"' "$gh_backing/fleet/mix.json")"
assert_eq "…and the enabled flag" "true" \
  "$(jq -r '.providers.anthropic.lanes.subscription.enabled' "$gh_backing/fleet/mix.json")"
assert_eq "it attributes itself, the same by/actor/ts provenance as fleet/disabled.json" \
  "fleet-node-a" "$(jq -r '.actor' "$gh_backing/fleet/mix.json")"
assert_contains "…naming the pid in by" "pid" "$(jq -r '.by' "$gh_backing/fleet/mix.json")"
assert_eq "…and a timestamp" "false" "$(jq -r '.ts == null' "$gh_backing/fleet/mix.json")"
assert_contains "the mix-set event is logged" '"event":"mix-set"' "$(cat "$a_log" 2>/dev/null)"

mix_status_out="$(run_node "$a_home" agent-cycle.sh --status 2>&1)"
assert_contains "--status reports the live mix" "anthropic api: weight=70" "$mix_status_out"
assert_contains "…naming the fleet flag as its source" "fleet/mix.json" "$mix_status_out"

a_log_lines_before="$(wc -l < "$a_log" 2>/dev/null || echo 0)"
mix_bare_out="$(run_node "$a_home" agent-cycle.sh --mix 2>&1)"
assert_contains "--mix with no arguments prints the same effective report" \
  "anthropic api: weight=70" "$mix_bare_out"
assert_eq "…and does not log anything (it is a read, not a command)" \
  "$a_log_lines_before" "$(wc -l < "$a_log" 2>/dev/null || echo 0)"

mix_close_out="$(run_node "$a_home" agent-cycle.sh --mix anthropic subscription.enabled=false 2>&1)"
mix_close_rc=$?
assert_eq "--mix refuses enabled=false" "64" "$mix_close_rc"
assert_contains "…naming --close-lane as the way to actually close a lane" \
  "--close-lane" "$mix_close_out"
assert_eq "…and the flag is unchanged by the refusal" "true" \
  "$(jq -r '.providers.anthropic.lanes.subscription.enabled' "$gh_backing/fleet/mix.json")"

mix_reset_out="$(run_node "$a_home" agent-cycle.sh --mix anthropic --reset 2>&1)"
assert_contains "--mix --reset reports clearing the flag" "fleet/mix.json cleared" "$mix_reset_out"
assert_eq "--reset deletes fleet/mix.json (anthropic was the only provider on it)" "0" \
  "$(test -f "$gh_backing/fleet/mix.json" && echo 1 || echo 0)"
assert_contains "the mix-reset event is logged" '"event":"mix-reset"' "$(cat "$a_log" 2>/dev/null)"

reset_again_out="$(run_node "$a_home" agent-cycle.sh --mix anthropic --reset 2>&1)"
assert_contains "resetting again, with nothing live, says so rather than erroring" \
  "no live mix entry" "$reset_again_out"

# A garbage flag yields config with a warning (lib/mix.sh's own
# providers_apply_mix, exercised here through an ordinary cycle attempt
# rather than --status/--mix, which never log it — see agent-cycle.sh's own
# comment on why that warning is gated on a real cycle alone).
printf 'not json at all' > "$gh_backing/fleet/mix.json"
rm -f "$a_log"
run_node "$a_home" agent-cycle.sh >/dev/null 2>&1
assert_contains "a garbage mix flag earns a warning event on an ordinary cycle" \
  '"event":"warning"' "$(cat "$a_log" 2>/dev/null)"
assert_contains "…naming fleet/mix.json" "fleet/mix.json" "$(cat "$a_log" 2>/dev/null)"
rm -f "$gh_backing/fleet/mix.json" "$a_log"

# --- A manual fleet/limit.json is honoured, never probed (#244) -----------
# An operator's stand-down is a decision, not an inference: the cycle must
# stand down naming the actor and the manual kind, must not spend a probe on
# it, and must not clear it.
jq -n '{resume_at: "2030-03-01T00:00:00Z", class: "other", reset_known: false,
        node: "operator", actor: "warwick@laptop", kind: "manual",
        ts: "2026-08-12T00:00:00Z"}' > "$gh_backing/fleet/limit.json"
rm -f "$b_log"
run_node "$b_home" agent-cycle.sh >/dev/null 2>&1
assert_eq "a cycle under a manual limit flag exits cleanly" "0" "$?"
assert_contains "a manual stand-down names its actor and kind" \
  'manual stand-down (anthropic) until 2030-03-01T00:00:00Z, set by warwick@laptop' \
  "$(cat "$b_log" 2>/dev/null)"
assert_not_contains "a manual stand-down is never probed" \
  '(probe:' "$(cat "$b_log" 2>/dev/null)"
assert_not_contains "and never auto-cleared" \
  '"event":"limit-cleared"' "$(cat "$b_log" 2>/dev/null)"
assert_eq "the manual flag survives the cycle" "1" \
  "$(test -f "$gh_backing/fleet/limit.json" && echo 1 || echo 0)"
rm -f "$gh_backing/fleet/limit.json"

# --- A long-running automatic freeze attempts its escalation (#244) -------
# The seeded hit is months old with no limit-cleared after it, so the freeze
# is far past `limit_escalate_after_hours`. Offline, `gh` fails fast, so the
# attempt surfaces as the warning naming the freeze's start — which is the
# assertion: the escalation fired, and a manual stand-down (above) never
# reached it.
printf '%s\n' \
  '{"ts":"2026-01-01T00:00:00Z","cycle":"seed","node":"node-b","event":"limit-hit","resume_at":"2030-06-01T00:00:00Z","class":"monthly","reset_known":false}' \
  > "$b_log"
run_node "$b_home" agent-cycle.sh >/dev/null 2>&1
assert_eq "a cycle under a stale automatic freeze exits cleanly" "0" "$?"
assert_contains "the freeze escalation is attempted and its failure recorded" \
  'automatic usage-limit freeze since 2026-01-01T00:00:00Z' \
  "$(cat "$b_log" 2>/dev/null)"

# --- --drain (requirement 2.3d): CLI plumbing and mode precedence ----------
# The mode field itself is covered above (lib/toggle.sh unit tests); this
# section is the CLI surface and the tighten/error/extend precedence rules,
# end to end through agent-cycle.sh and lib/manage.sh.

d_home="$(new_home drain-node)"
d_switch="$d_home/.local/state/poetic-agents/disabled.json"
d_log="$d_home/.local/state/poetic-agents/log.jsonl"
d_review_log="$d_home/.local/state/poetic-agents/review-log.jsonl"

drain_no_reason_out="$(run_node "$d_home" agent-cycle.sh --drain 2>&1)"
assert_eq "--drain with no reason is a usage error" "64" "$?"
assert_contains "and says so" "--drain needs a reason" "$drain_no_reason_out"

run_node "$d_home" agent-cycle.sh --drain "clearing the backlog" --for 4h >/dev/null 2>&1
assert_eq "--drain writes mode drain" "drain" "$(jq -r '.mode' "$d_switch" 2>/dev/null)"
assert_eq "--drain writes an ordinary switch record otherwise" "clearing the backlog" \
  "$(jq -r '.reason' "$d_switch" 2>/dev/null)"
assert_contains "the disabled event names mode drain" '"mode":"drain"' "$(cat "$d_log" 2>/dev/null)"

drain_status_out="$(run_node "$d_home" agent-cycle.sh --status 2>&1)"
assert_contains "--status reports DRAINING for a drain record" "switch:   DRAINING" "$drain_status_out"
assert_not_contains "and never DISABLED, which a stop alone reads as" "switch:   DISABLED" "$drain_status_out"

# Loosening a stop into a drain is refused outright — only --enable may loosen.
# Both lines above the refusal attempt are setup only: nothing checks their
# own output, only the state they leave behind for the refused --drain below.
direct_enable "$d_home"
direct_disable "$d_home" "full stop" 4h stop
drain_over_stop_out="$(run_node "$d_home" agent-cycle.sh --drain "trying to loosen" 2>&1)"
assert_eq "--drain over an active --disable is a usage error" "64" "$?"
assert_contains "and names --enable as the way out" "run --enable first" "$drain_over_stop_out"
assert_eq "the stop record is untouched by the refused --drain" "stop" \
  "$(jq -r '.mode' "$d_switch" 2>/dev/null)"
assert_eq "and its reason is untouched too" "full stop" "$(jq -r '.reason' "$d_switch" 2>/dev/null)"

# --disable over an active drain tightens it to a full stop immediately.
# The two lines above the real --disable below are setup only, in the same
# sense as above: they exist to leave d_home mid-drain for the real call to
# tighten, and nothing checks their own output.
direct_enable "$d_home"
direct_disable "$d_home" "clearing the backlog" 4h drain
run_node "$d_home" agent-cycle.sh --disable "actually need it fully stopped" >/dev/null 2>&1
assert_eq "--disable over an active drain tightens it to mode stop" "stop" \
  "$(jq -r '.mode' "$d_switch" 2>/dev/null)"
assert_eq "and overwrites the reason, like an ordinary re-disable" \
  "actually need it fully stopped" "$(jq -r '.reason' "$d_switch" 2>/dev/null)"

# --drain over an active drain extends it — a fresh disabled_at, same as
# re-issuing --disable over a live stop already does.
# Setup only, as above: the extend attempt right below is the real assertion
# target, and needs only a live drain already in place to extend.
direct_enable "$d_home"
direct_disable "$d_home" "first drain" 1h drain
run_node "$d_home" agent-cycle.sh --drain "extending the drain" --for 2h >/dev/null 2>&1
assert_eq "extending a drain succeeds" "0" "$?"
assert_eq "the reason is updated" "extending the drain" "$(jq -r '.reason' "$d_switch" 2>/dev/null)"
assert_eq "and mode stays drain" "drain" "$(jq -r '.mode' "$d_switch" 2>/dev/null)"
assert_contains "the log records the extension" '"extends"' "$(cat "$d_log" 2>/dev/null)"

# --enable clears a drain exactly as it clears a stop.
run_node "$d_home" agent-cycle.sh --enable >/dev/null 2>&1
assert_eq "--enable clears a drain record" "0" "$(test -f "$d_switch" && echo 1 || echo 0)"

# review-cycle.sh stands down under a drain exactly as under a stop (R2a):
# `.state == "disabled"` already reads true regardless of mode, so this
# asserts the observable behaviour rather than the (absent) branch. The
# --drain setup below is not itself asserted on — only the review-cycle.sh
# run right after is.
direct_disable "$d_home" "reviewer should stand down too" 1h drain
run_node "$d_home" review-cycle.sh >/dev/null 2>&1
assert_eq "a review cycle exits cleanly under a drain" "0" "$?"
assert_contains "and logs a review-stand-down" '"event":"review-stand-down"' \
  "$(cat "$d_review_log" 2>/dev/null)"
assert_contains "naming drain mode in its reason, not a bare disabled" \
  "drain mode" "$(cat "$d_review_log" 2>/dev/null)"
# Cleanup only: nothing about d_home is asserted on again below.
direct_enable "$d_home"

# A *peer's* fleet-wide stop is a stop this node may not loosen either, even
# though it has no local record of its own to read: an unmodified --disable
# publishes fleet/disabled.json and writes nothing to any other node's
# state_dir, so reading only the local record would let a fleet-scoped --drain
# here republish that flag as a drain and downgrade the whole fleet
# (requirement 2.3d).
p_home="$(new_home drain-peer-a)"
q_home="$(new_home drain-peer-b)"
q_switch="$q_home/.local/state/poetic-agents/disabled.json"
run_node "$p_home" agent-cycle.sh --disable "peer's full stop" --for forever >/dev/null 2>&1
assert_eq "the peer's --disable published a stop to the fleet flag" "stop" \
  "$(jq -r '.mode' "$gh_backing/fleet/disabled.json" 2>/dev/null)"
drain_over_fleet_out="$(run_node "$q_home" agent-cycle.sh --drain "trying to loosen the fleet" 2>&1)"
assert_eq "--drain over a peer's fleet-wide --disable is a usage error" "64" "$?"
assert_contains "and names --enable as the way out" "run --enable first" "$drain_over_fleet_out"
assert_eq "the fleet flag is still a full stop, not downgraded to a drain" "stop" \
  "$(jq -r '.mode' "$gh_backing/fleet/disabled.json" 2>/dev/null)"
assert_eq "and the refusing node wrote no local record of its own" "0" \
  "$(test -f "$q_switch" && echo 1 || echo 0)"

# --drain --this-node publishes no fleet flag, so it cannot loosen one and is
# allowed: the node stays stood down by the fleet stop regardless of what its
# own record says.
run_node "$q_home" agent-cycle.sh --drain "node-scoped drain under a fleet stop" --this-node >/dev/null 2>&1
assert_eq "--drain --this-node under a fleet stop is allowed" "drain" \
  "$(jq -r '.mode' "$q_switch" 2>/dev/null)"
assert_eq "and leaves the fleet flag a full stop" "stop" \
  "$(jq -r '.mode' "$gh_backing/fleet/disabled.json" 2>/dev/null)"
# End-of-file cleanup only: nothing after this reads either node's state.
direct_enable "$q_home" --this-node
direct_enable "$p_home"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
