#!/usr/bin/env bash
#
# test/manage-status.test.sh — the two `--status` lines lib/manage.sh added
# for agent-ops#1377: this node's own publication freshness (`published:`)
# and the scheduled doctor's last verdict (`doctor:`).
#
# Why these two are worth a test: from 2026-09-12 to -15 poetic-2 published
# nothing for three days while `--status` read every stage `ok`; the doctor
# failed its publication check hourly the whole time, into a file nothing
# surfaced to the terminal a maintainer actually reads. `check-nodes.sh`
# (external) prints `--status` per node, so these lines are where that fact
# now lands. Both must degrade to a plain sentence, never an error, on a node
# that has nothing to report yet.
#
# No network, no GitHub. Run directly: ./test/manage-status.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/fleet.sh
. "$SCRIPT_DIR/lib/fleet.sh"
# shellcheck source=lib/mirror-lock.sh
. "$SCRIPT_DIR/lib/mirror-lock.sh"
# shellcheck source=lib/manage.sh
. "$SCRIPT_DIR/lib/manage.sh"

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
assert_lacks() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected NOT to contain: %s\n     actual:   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# The globals lib/manage.sh reads from agent-cycle.sh's own process, and the
# one config accessor it calls (node_stale_after_minutes → 30, the shipped
# default, as `cfg` would resolve it).
state_dir="$tmp_dir/state"
workspace_root="$tmp_dir/workspace"
mkdir -p "$state_dir" "$workspace_root"
state_repo="Poetic-Poems/agent-ops-state"
cfg() { case "$1" in *node_stale_after_minutes*) echo 1800 ;; *) echo "" ;; esac; }

# --- manage_age_phrase ---------------------------------------------------------
assert_eq "seconds under a minute" "42s" "$(manage_age_phrase 42)"
assert_eq "minutes under an hour" "7m" "$(manage_age_phrase 450)"
assert_eq "hours under a day" "3h" "$(manage_age_phrase 12000)"
assert_eq "days beyond" "2d" "$(manage_age_phrase 200000)"
assert_eq "garbage reads as zero, never an arithmetic error" "0s" "$(manage_age_phrase abc)"

# --- publication_status_report -------------------------------------------------
assert_eq "no publication read back yet is a plain unknown" \
  "published: unknown — no fetch has read this node's own branch back yet" \
  "$(publication_status_report)"

jq -nc --arg ts "$(date -u -d '2 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" '{ts: $ts}' \
  > "$state_dir/.state-sync-published.json"
out="$(publication_status_report)"
assert_contains "a publication two minutes old is fresh" "published: fresh — last confirmed publication 2m ago" "$out"
assert_contains "…against the node_stale_after_minutes threshold" "under the 30m threshold" "$out"

# poetic-2's own shape on 2026-09-15: a read-back nearly three days old.
jq -nc --arg ts "$(date -u -d '68 hours ago' +%Y-%m-%dT%H:%M:%SZ)" '{ts: $ts}' \
  > "$state_dir/.state-sync-published.json"
out="$(publication_status_report)"
assert_contains "a publication days old is STALE, in capitals" "published: STALE — last confirmed publication 2d ago" "$out"
assert_contains "…and says what that usually means" "state-sync.sh push has likely stopped working" "$out"
assert_contains "…citing the issue that explains the read-back" "agent-ops#602" "$out"

state_repo=""
assert_eq "a node with no state_repo says so rather than reading a file that cannot exist" \
  "published: not configured (no state_repo)" "$(publication_status_report)"
state_repo="Poetic-Poems/agent-ops-state"

# --- the mirror lock's own current holder (agent-ops#1679) ---------------------
# "another state-sync holds the mirror" is self-clearing only for an ordinary
# slow fetch — a push wedged holding it for hours looks identical from
# outside otherwise, so this line names the current hold's age once it has
# outrun one push interval (300s here: the stub `cfg` above answers nothing
# for `schedule.state_sync_push_minutes`, so `publication_status_report`
# falls back to its own default the same way a real unconfigured key would).
mirror="$workspace_root/.agent-ops-state"
jq -nc --arg ts "$(date -u -d '2 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" '{ts: $ts}' \
  > "$state_dir/.state-sync-published.json"

# hold_mirror_lock -> sets $holder_parent/$holder_child, the two pids
# actually holding the open file description the flock sits on. `flock file
# cmd` forks: the parent keeps the lock open across the fork, so `cmd` (here,
# `sleep`) inherits the same fd and keeps the lock held even after the parent
# alone is killed — both have to be killed to release it below. Backgrounded
# directly, never through a `$(...)` command substitution: bash kills a
# command substitution's own still-running background jobs the moment that
# subshell exits, which would free the lock before this function's caller
# ever got to use it.
hold_mirror_lock() {
  flock "$mirror.lock" sleep 5 &
  holder_parent=$!
  sleep 0.2
  holder_child="$(pgrep -P "$holder_parent" | head -1)"
}

# A live holder younger than one push interval is an ordinary contention —
# no different from any other push in progress — so no wedge note.
jq -nc --arg started "$(date -u -d '1 minute ago' +%Y-%m-%dT%H:%M:%SZ)" \
  '{started: $started, mode: "push", pid: 1}' > "$mirror.lock.holder"
hold_mirror_lock
out="$(publication_status_report)"
assert_lacks "a lock held for under one push interval is not called a wedge" \
  "agent-ops#1679" "$out"
kill "$holder_parent" "$holder_child" 2>/dev/null; wait "$holder_parent" 2>/dev/null

# A live holder older than one push interval is named as a possible wedge —
# the fact `--status` exists to surface without reading cron.log.
jq -nc --arg started "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" \
  '{started: $started, mode: "push", pid: 1}' > "$mirror.lock.holder"
hold_mirror_lock
out="$(publication_status_report)"
assert_contains "a lock held past one push interval is named as a possible wedge" \
  "holding the mirror lock for 1h, longer than one push interval" "$out"
assert_contains "…citing the issue that explains it" "agent-ops#1679" "$out"
assert_contains "…and a push-held marker names it as a push (agent-ops#1715)" \
  "a push has been holding the mirror lock" "$out"
kill "$holder_parent" "$holder_child" 2>/dev/null; wait "$holder_parent" 2>/dev/null

# A wedged fetch is named as a fetch, not misreported as a push
# (agent-ops#1715) — do_fetch takes the same mirror_lock as do_push, and the
# marker's own stamped mode is what tells them apart.
jq -nc --arg started "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" \
  '{started: $started, mode: "fetch", pid: 1}' > "$mirror.lock.holder"
hold_mirror_lock
out="$(publication_status_report)"
assert_contains "a wedged fetch is named as a fetch, not a push" \
  "a fetch has been holding the mirror lock for 1h, longer than one push interval" "$out"
kill "$holder_parent" "$holder_child" 2>/dev/null; wait "$holder_parent" 2>/dev/null

# A marker with no readable mode (agent-ops#1715's mode-absent case, Option
# (b)'s wording) falls back to the mode-neutral noun rather than defaulting
# to "a push".
jq -nc --arg started "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ)" \
  '{started: $started, pid: 1}' > "$mirror.lock.holder"
hold_mirror_lock
out="$(publication_status_report)"
assert_contains "a mode-absent marker falls back to the mode-neutral noun" \
  "a state-sync has been holding the mirror lock for 1h, longer than one push interval" "$out"
kill "$holder_parent" "$holder_child" 2>/dev/null; wait "$holder_parent" 2>/dev/null

# Once nothing holds the lock, the note is gone regardless of what the stale
# marker still says — the marker only means anything while a live flock backs
# it.
out="$(publication_status_report)"
assert_lacks "no live holder means no wedge note, however old the marker" \
  "agent-ops#1679" "$out"
rm -f "$mirror.lock" "$mirror.lock.holder"

# --- doctor_status_report ------------------------------------------------------
assert_eq "no unattended pass yet is a plain sentence" \
  "doctor:   no unattended pass recorded yet" "$(doctor_status_report)"

jq -nc --arg ts "$(date -u -d '50 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
  '{timestamp: $ts, verdict: "ok", fails: [], warns: [], skips: []}' > "$state_dir/.doctor-status.json"
assert_eq "an ok verdict carries only its age" "doctor:   ok (50m ago)" "$(doctor_status_report)"

# The verdict poetic-2's doctor wrote hourly for three days, verbatim but
# for the timestamp.
jq -nc --arg ts "$(date -u -d '50 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" \
  '{timestamp: $ts, verdict: "fail", warns: ["something minor"],
    fails: ["this node'"'"'s last confirmed publication into Poetic-Poems/agent-ops-state is 205644s old, over the 1800s node_stale_after_minutes threshold — state-sync.sh push has likely stopped working even if local cycles are still running (agent-ops#602)",
            "a second failing check"]}' > "$state_dir/.doctor-status.json"
out="$(doctor_status_report)"
assert_contains "a failing verdict counts its failures" "doctor:   fail (50m ago) — 2 failing, first: " "$out"
assert_contains "…and names the first one" "last confirmed publication into Poetic-Poems/agent-ops-state is 205644s old" "$out"
assert_eq "…on one line" "1" "$(printf '%s\n' "$out" | wc -l)"

printf 'not json\n' > "$state_dir/.doctor-status.json"
assert_eq "an unreadable status file is reported, not an error" \
  "doctor:   unreadable .doctor-status.json" "$(doctor_status_report)"

# --- the fleet-union readers: decisions_status_report, current_limit_record -----
# Both read `fleet_logs` — this node's log and every peer copy — and both read
# it line by line, so one line that does not parse costs that line and nothing
# else (#2037). The shape below is the one both VM nodes' logs carried: a
# record cut off part-way and run into a whole later record on one line. A
# slurp of the union aborted on it, so `decisions:` read 0 whatever the fleet
# had decided and the `limit:` line saw only the flag carrier.
# shellcheck source=lib/limit-detect.sh
. "$SCRIPT_DIR/lib/limit-detect.sh"
guard_calls="$tmp_dir/guard-calls"
: > "$guard_calls"
guard_warn() { printf '%s\n' "$1" >> "$guard_calls"; }
fleet_flag_fetch() { :; }   # the flag carrier is clear; only the union speaks
peer_dir="$(fleet_peers_dir "$workspace_root")/poetic-2"
mkdir -p "$peer_dir"
recent_iso="$(date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
old_iso="$(date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%SZ)"
spliced_line='{"ts":"2026-09-16T20:33:17Z","event":"github-budget","core":{"limit":5000,"{"ts":"2026-09-16T20:38:12Z","event":"wake-poll"}'
{ printf '{"ts":"%s","node":"self","event":"decision-taken","repo":"o/r","item":"TD1"}\n' "$recent_iso"
  printf '{"ts":"%s","node":"self","event":"decision-taken","repo":"o/r","item":"TD0"}\n' "$old_iso"
} > "$state_dir/log.jsonl"
{ printf '%s\n' "$spliced_line"
  printf '{"ts":"%s","node":"poetic-2","event":"decision-taken","repo":"o/r","item":"TD2"}\n' "$recent_iso"
  printf '{"ts":"%s","node":"poetic-2","event":"limit-hit","resume_at":"2099-01-01T00:00:00Z","class":"weekly","reset_known":true}\n' "$recent_iso"
} > "$peer_dir/log.jsonl"
assert_eq "decisions: a spliced peer line does not zero the fleet's count" \
  "decisions: 2 taken in the last 24h" "$(decisions_status_report)"
assert_eq "current_limit_record: a spliced peer line does not hide the governing hit" \
  "2099-01-01T00:00:00Z" "$(current_limit_record | jq -r '.resume_at')"
assert_eq "…and nothing was reported, because nothing failed" "" "$(cat "$guard_calls")"

# A read that fails outright — jq killed, as the memory cgroup did to three of
# them on 2026-10-01 — is said, not printed as a zero nobody counted, and the
# limit read leaves the flag carrier to answer alone. A jq that exits 137
# stands in for the killed one.
fake_jq_dir="$tmp_dir/fake-jq"
mkdir -p "$fake_jq_dir"
printf '#!/bin/sh\necho "jq: killed" >&2\nexit 137\n' > "$fake_jq_dir/jq"
chmod +x "$fake_jq_dir/jq"
assert_eq "decisions: a failed read says unreadable rather than 0" \
  "decisions: unreadable — the fleet log could not be read" \
  "$(PATH="$fake_jq_dir:$PATH" decisions_status_report)"
: > "$guard_calls"
PATH="$fake_jq_dir:$PATH" current_limit_record >/dev/null 2>&1
assert_eq "current_limit_record: a failed union read is reported under its own site" \
  "current_limit_record:union" "$(cat "$guard_calls")"
: > "$guard_calls"
PATH="$fake_jq_dir:$PATH" decisions_status_report >/dev/null 2>&1
assert_eq "decisions: the failed read is reported under its own site" \
  "decisions_status_report:count" "$(cat "$guard_calls")"

# A union that could not be built at all — its sort killed, or unable to write
# its temporary files on a full disk, the conditions behind #2037 — fails
# `fleet_logs`, and both readers say so rather than reading the empty or
# truncated stream as "no limit" and "0 decisions". A `sort` that exits 2
# stands in for the one that failed.
fake_sort_dir="$tmp_dir/fake-sort"
mkdir -p "$fake_sort_dir"
printf '#!/bin/sh\necho "sort: write failed: /tmp/sortXXXX: No space left on device" >&2\nexit 2\n' > "$fake_sort_dir/sort"
chmod +x "$fake_sort_dir/sort"
assert_eq "decisions: a union that could not be built says unreadable rather than 0" \
  "decisions: unreadable — the fleet log could not be read" \
  "$(PATH="$fake_sort_dir:$PATH" decisions_status_report 2>/dev/null)"
: > "$guard_calls"
PATH="$fake_sort_dir:$PATH" decisions_status_report >/dev/null 2>&1
assert_eq "…and reports it under its own site" "decisions_status_report:count" "$(cat "$guard_calls")"
: > "$guard_calls"
assert_eq "current_limit_record: a union that could not be built leaves the flag carrier to answer alone" \
  "" "$(PATH="$fake_sort_dir:$PATH" current_limit_record 2>/dev/null)"
assert_eq "…and reports it under its own site" "current_limit_record:union" "$(cat "$guard_calls")"
unset -f guard_warn fleet_flag_fetch

# --- mix_status_report (issue #2244, D30): the credit mix's own --status
# section, built from the identical `mix_fleet_status_json`/`mix_status_text`
# (lib/mix.sh) node-health.sh --metrics also renders from (requirement 34a).
# Needs the provider seam and the fleet-flag machinery mix.sh is built on,
# neither of which the sections above needed — sourced here, immediately
# before the one section that does.
# shellcheck source=lib/model-id.sh
. "$SCRIPT_DIR/lib/model-id.sh"
# shellcheck source=lib/toggle.sh
. "$SCRIPT_DIR/lib/toggle.sh"
# shellcheck source=lib/substrate-claude-code.sh
. "$SCRIPT_DIR/lib/substrate-claude-code.sh"
# shellcheck source=lib/mix.sh
. "$SCRIPT_DIR/lib/mix.sh"

mix_gh_backing="$tmp_dir/mix-fleet-remote"
mkdir -p "$mix_gh_backing"
mix_gh_stub="$tmp_dir/mix-gh-stub"
cat > "$mix_gh_stub" <<'STUB'
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
esac
STUB
chmod +x "$mix_gh_stub"
export TOGGLE_GH="$mix_gh_stub" GH_STUB_BACKING="$mix_gh_backing"
mix_slug="example/agent-ops-state"
mix_fs="$tmp_dir/mix-fleet-state"
mkdir -p "$mix_fs"

providers_load "{}"

# Case 1: config alone governs (no live flag, and no cache yet either) —
# every field's source reads "config".
providers_apply_mix "$mix_slug" "$mix_fs"
out="$(mix_status_report)"
assert_contains "mix: reports the config-only case" "mix:" "$out"
assert_contains "…weight sourced from config" "anthropic api: weight=1 (config)" "$out"
assert_contains "…subscription weight also from config" "anthropic subscription: weight=0 (config)" "$out"

# Case 2: a live `--mix` sets the fleet flag; --status must report both the
# new weights *and* which side supplied them, with the flag's own ts/by.
mix_overlay="$(mix_build_overlay anthropic "api=70" "subscription=30" "subscription.enabled=true")"
mix_write "$mix_slug" "$mix_fs" anthropic "$mix_overlay" "operator pid 1" "operator" >/dev/null
providers_apply_mix "$mix_slug" "$mix_fs"
out="$(mix_status_report)"
assert_contains "mix: reports the live flag's api weight" "anthropic api: weight=70 (fleet/mix.json, set" "$out"
assert_contains "…naming the actor who set it" "by operator pid 1)" "$out"
assert_contains "mix: reports the live flag's subscription weight and enabled" \
  "anthropic subscription: weight=30 (fleet/mix.json" "$out"
assert_contains "…and enabled sourced from the flag too" "enabled=yes (fleet/mix.json" "$out"

# Case 3: the flag is unreadable (state repo down, no cache) — --status must
# fall back to reporting config, exactly as case 1, never the stale fleet
# values from case 2 above (a fresh fleet-state dir makes sure of that).
mix_fs_fresh="$tmp_dir/mix-fleet-state-fresh"
mkdir -p "$mix_fs_fresh"
# A fresh providers_load, the same reset a brand-new process's own cycle
# start performs — PROVIDER_LANES still carried case 2's overlaid 70/30 from
# the mutation above, and this is what a real unreadable-flag process never
# has to undo: it starts from config every time.
providers_load "{}"
GH_STUB_MODE=down providers_apply_mix "$mix_slug" "$mix_fs_fresh"
out="$(GH_STUB_MODE=down mix_status_report)"
assert_contains "mix: an unreadable flag falls back to config" "anthropic api: weight=1 (config)" "$out"
assert_contains "…for every field, not just weight" "enabled=default (config)" "$out"

if (( failures > 0 )); then
  echo "$failures failure(s)"
  exit 1
fi
echo "all tests passed"
