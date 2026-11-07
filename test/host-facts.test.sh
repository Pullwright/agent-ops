#!/usr/bin/env bash
#
# test/host-facts.test.sh — the driver-independent half of the host-facts
# record (lib/host-facts.sh, docs/reference/host-facts-schema.md): `host.network`'s
# MTU comparison, the updater ledger/last-session parse, and the
# viewer-vantage probe. The compose- and Kubernetes-specific sections each
# have their own test file; this one covers what both drivers share.
#
# The properties that matter:
#   - mtu_match is true when the configured DOCKER_MTU equals the measured
#     egress MTU, false when it differs, and null — never guessed — when
#     the egress MTU itself could not be measured;
#   - the updater ledger tail reads the last N entries across every file in
#     the ledger directory — never one named for the querying node, which
#     no writer ever creates — merged oldest-first, and degrades to an empty
#     array rather than failing on a missing directory or a malformed line;
#   - the last-session parser reads the newest "Session done Failed=N
#     Scanned=N Updated=N" line's own `time="…"` timestamp, never this
#     collector's own clock, and reads null when no such line exists;
#   - a viewer probe that gets valid JSON back reads ok:true with a byte
#     count and a timing; one that fails to fetch, or gets a body that will
#     not parse, reads ok:false with a reason and null timing/bytes.
#
# Run directly: ./test/host-facts.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/disk-space.sh
. "$SCRIPT_DIR/lib/disk-space.sh"
# shellcheck source=lib/host-facts.sh
. "$SCRIPT_DIR/lib/host-facts.sh"

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

# --- host.network / MTU ------------------------------------------------------
network_match="$(DOCKER_MTU=1500 host_facts_network_json)"
egress="$(jq -r '.egress_mtu' <<<"$network_match")"
if [[ "$egress" == "null" ]]; then
  assert_eq "no default route here: mtu_match is null, never guessed" \
    "null" "$(jq -r '.mtu_match' <<<"$network_match")"
else
  assert_eq "DOCKER_MTU equal to the measured egress MTU matches" \
    "true" "$(DOCKER_MTU="$egress" host_facts_network_json | jq -r '.mtu_match')"
fi
network_mismatch="$(DOCKER_MTU=1 host_facts_network_json)"
if [[ "$(jq -r '.egress_mtu' <<<"$network_mismatch")" != "null" ]]; then
  assert_eq "DOCKER_MTU of 1 never equals a real egress MTU" \
    "false" "$(jq -r '.mtu_match' <<<"$network_mismatch")"
fi
assert_eq "DOCKER_MTU falls back to 1500, the same default compose.yaml uses" \
  "1500" "$(env -u DOCKER_MTU bash -c '. "'"$SCRIPT_DIR"'/lib/host-facts.sh"; host_facts_network_json' | jq -r '.docker_mtu_configured')"

# --- host_facts_node_name sanitization (issue #1344) --------------------------
# scripts/publish-dashboard.sh sanitizes its own copy of the node name
# (`${self_node//[^A-Za-z0-9._-]/-}`) before reading a host-facts record; this
# must sanitize the same way so the collector's write and the dashboard's
# reads never disagree about the filename.
assert_eq "a hostname-shaped NODE_NAME passes through unchanged" \
  "poetic-1" "$(NODE_NAME='poetic-1' host_facts_node_name)"
assert_eq "a NODE_NAME with a disallowed character is sanitized" \
  "a-b-c" "$(NODE_NAME='a b:c' host_facts_node_name)"

# --- host.mem_total_bytes / host.cpu_count (issue #757) ----------------------
# Both read real, unfixtured system files (/proc/meminfo, /proc/cpuinfo, the
# same files host_facts_mem_available_bytes already reads without an
# override) — a readable-happy-path smoke test only, the same "unreadable is
# empty, never a guessed 0" contract left to lib/memory.sh's own
# already-tested memory_total_kb rather than duplicated here (see
# docs/spec/implementation/acceptance-checks/'s 2n-ii acceptance check).
mem_total="$(host_facts_mem_total_bytes)"
assert_eq "mem_total_bytes reads a positive integer on this host" \
  "yes" "$(if [[ "$mem_total" =~ ^[0-9]+$ ]] && (( mem_total > 0 )); then echo yes; else echo no; fi)"
cpu_count="$(host_facts_cpu_count)"
assert_eq "cpu_count reads a positive integer on this host" \
  "yes" "$(if [[ "$cpu_count" =~ ^[0-9]+$ ]] && (( cpu_count > 0 )); then echo yes; else echo no; fi)"
assert_eq "host_facts_host_json carries mem_total_bytes and cpu_count" \
  "true" "$(host_facts_host_json /tmp /tmp | jq -r '(.mem_total_bytes | type == "number") and (.cpu_count | type == "number")')"

# --- Updater ledger tail ------------------------------------------------------
# Every filename here is deliberately container-ID-shaped and shares no
# characters with any node name. That is the real shape on a compose node:
# the ledger's only writer keys each file by the *writing container's* own
# $HOSTNAME, never by NODE_NAME, so a reader that selects a file by node
# name finds nothing while a populated ledger sits beside it — the defect
# every earlier fixture hid by keying its file to the name it then queried.
ledger_dir="$tmp_dir/updater-ledger"
mkdir -p "$ledger_dir"
{
  printf '{"verdict":"allow","ts":"2026-09-08T00:00:00Z","service":"scheduler"}\n'
  printf '{"verdict":"allow","ts":"2026-09-08T00:05:00Z","service":"scheduler"}\n'
  printf 'not json\n'
  printf '{"verdict":"allow","ts":"2026-09-08T00:10:00Z","service":"scheduler"}\n'
} > "$ledger_dir/3f9a1c2b4d5e.jsonl"

tail_json="$(host_facts_updater_ledger_tail "$ledger_dir" 3)"
assert_eq "a malformed line among the tail is skipped, not fatal to the rest" \
  "2" "$(jq 'length' <<<"$tail_json")"
assert_eq "ledger tail is oldest-first" "2026-09-08T00:05:00Z" \
  "$(jq -r '.[0].ts' <<<"$tail_json")"
assert_eq "the tail is read though no file is named for the querying node" \
  "2026-09-08T00:10:00Z" "$(jq -r '.[-1].ts' <<<"$tail_json")"

# A roll's replacement writes under a fresh container ID, so one node's own
# updater history spans files by construction: the tail is the newest
# entries across all of them, ordered by ts rather than by filename.
printf '{"verdict":"allow","ts":"2026-09-08T00:07:00Z","service":"scheduler"}\n' \
  > "$ledger_dir/a1b2c3d4e5f6.jsonl"
merged="$(host_facts_updater_ledger_tail "$ledger_dir" 5)"
assert_eq "entries from every generation's file are merged into one tail" \
  "4" "$(jq 'length' <<<"$merged")"
assert_eq "the merged tail is ordered by ts, not by filename" \
  "2026-09-08T00:00:00Z 2026-09-08T00:05:00Z 2026-09-08T00:07:00Z 2026-09-08T00:10:00Z" \
  "$(jq -r '[.[].ts] | join(" ")' <<<"$merged")"
assert_eq "the merged tail truncates to the newest N across all files" \
  "2026-09-08T00:07:00Z 2026-09-08T00:10:00Z" \
  "$(host_facts_updater_ledger_tail "$ledger_dir" 2 | jq -r '[.[].ts] | join(" ")')"

mkdir -p "$tmp_dir/empty-ledger"
assert_eq "a ledger directory holding no .jsonl file degrades to an empty array" \
  "[]" "$(host_facts_updater_ledger_tail "$tmp_dir/empty-ledger")"
assert_eq "a missing ledger directory degrades to an empty array" \
  "[]" "$(host_facts_updater_ledger_tail "$tmp_dir/no-such-ledger-dir")"

# --- last-session parse -------------------------------------------------------
log_text='time="2026-09-08T09:00:00Z" level=info msg="Session done" Failed=0 Scanned=3 Updated=1
time="2026-09-08T10:00:00Z" level=info msg="Session done" Failed=2 Scanned=3 Updated=0'
assert_eq "the newest Session-done line wins, not the first" \
  '{"ts":"2026-09-08T10:00:00Z","failed":2,"scanned":3,"updated":0,"conflict_failed":0}' \
  "$(host_facts_parse_last_session "$log_text")"
assert_eq "no Session-done line at all reads null" "null" \
  "$(host_facts_parse_last_session 'nothing relevant here')"
assert_eq "no log text at all reads null" "null" "$(host_facts_parse_last_session)"

# A Failed count fully explained by the *other* compose project's own roll
# window on a shared host (agent-ops#1099/#1944) — each Conflict line
# counted, and conflict_failed lands equal to failed.
conflict_log_text='time="2026-09-03T21:06:56Z" level=error msg="Error response from daemon: Conflict. The container name \"/agent-ops-dashboard-1\" is already in use by container \"abc123\"."
time="2026-09-03T21:06:56Z" level=error msg="Error response from daemon: Conflict. The container name \"/agent-ops-scheduler-1\" is already in use by container \"def456\"."
time="2026-09-03T21:06:56Z" level=error msg="Error response from daemon: Conflict. The container name \"/agent-ops-egress-proxy-1\" is already in use by container \"ghi789\"."
time="2026-09-03T21:06:56Z" level=info msg="Session done" Failed=3 Scanned=6 Updated=0'
assert_eq "a Failed count matching its own Conflict lines reads conflict_failed equal to failed" \
  '{"ts":"2026-09-03T21:06:56Z","failed":3,"scanned":6,"updated":0,"conflict_failed":3}' \
  "$(host_facts_parse_last_session "$conflict_log_text")"

# A prior session's own Conflict lines must not inflate the newest
# session's count: the tail can span several polling cycles, and this
# session's own Failed=1 is explained by its own single Conflict line, not
# by the two left over from the session before it.
multi_session_conflict_log_text='time="2026-09-08T09:00:00Z" level=error msg="Error response from daemon: Conflict. The container name \"/agent-ops-dashboard-1\" is already in use by container \"abc123\"."
time="2026-09-08T09:00:00Z" level=error msg="Error response from daemon: Conflict. The container name \"/agent-ops-scheduler-1\" is already in use by container \"def456\"."
time="2026-09-08T09:00:00Z" level=info msg="Session done" Failed=2 Scanned=6 Updated=0
time="2026-09-08T10:00:00Z" level=error msg="Error response from daemon: Conflict. The container name \"/agent-ops-dashboard-1\" is already in use by container \"ghi789\"."
time="2026-09-08T10:00:00Z" level=info msg="Session done" Failed=1 Scanned=6 Updated=0'
assert_eq "a prior session's own Conflict lines are not counted against this one's Failed" \
  '{"ts":"2026-09-08T10:00:00Z","failed":1,"scanned":6,"updated":0,"conflict_failed":1}' \
  "$(host_facts_parse_last_session "$multi_session_conflict_log_text")"

# --- updater section ----------------------------------------------------------
assert_eq "no ledger dir and no log text: the whole updater section is null" \
  "null" "$(host_facts_updater_json "$tmp_dir/no-such-state-dir" "")"

# End to end through the section builder, which is where the node name used
# to be threaded in and drop the tail on the floor.
assert_eq "the section carries the ledger tail though no file bears this node's name" \
  "4" "$(host_facts_updater_json "$tmp_dir" "" | jq '.ledger_tail | length')"

# --- Viewer probe --------------------------------------------------------------
ok_curl="$tmp_dir/ok-curl.sh"
cat > "$ok_curl" <<'STUB'
#!/usr/bin/env bash
echo '{"generated_at":"2026-09-09T00:00:00Z"}'
STUB
chmod +x "$ok_curl"

fail_curl="$tmp_dir/fail-curl.sh"
cat > "$fail_curl" <<'STUB'
#!/usr/bin/env bash
exit 22
STUB
chmod +x "$fail_curl"

connect_refused_curl="$tmp_dir/connect-refused-curl.sh"
cat > "$connect_refused_curl" <<'STUB'
#!/usr/bin/env bash
echo "curl: (7) Failed to connect to node-d port 443: Connection refused" >&2
exit 7
STUB
chmod +x "$connect_refused_curl"

timeout_curl="$tmp_dir/timeout-curl.sh"
cat > "$timeout_curl" <<'STUB'
#!/usr/bin/env bash
exit 28
STUB
chmod +x "$timeout_curl"

bad_body_curl="$tmp_dir/bad-body-curl.sh"
cat > "$bad_body_curl" <<'STUB'
#!/usr/bin/env bash
echo 'not valid json at all'
STUB
chmod +x "$bad_body_curl"

probe_ok="$(host_facts_viewer_probe_one node-a http://node-a/data.js "$ok_curl")"
assert_eq "a successful fetch that parses reads ok:true" "true" "$(jq -r '.ok' <<<"$probe_ok")"
assert_eq "a successful fetch carries a byte count" "1" \
  "$(jq -r '(.bytes // 0) > 0 | if . then 1 else 0 end' <<<"$probe_ok")"

probe_fail="$(host_facts_viewer_probe_one node-b http://node-b/data.js "$fail_curl")"
assert_eq "a failed fetch reads ok:false" "false" "$(jq -r '.ok' <<<"$probe_fail")"
assert_eq "a failed fetch carries no byte count" "null" "$(jq -r '.bytes' <<<"$probe_fail")"

probe_refused="$(host_facts_viewer_probe_one node-d http://node-d/data.js "$connect_refused_curl")"
assert_eq "a connection-refused fetch reads ok:false" "false" "$(jq -r '.ok' <<<"$probe_refused")"
assert_eq "a connection-refused fetch names the connect failure, not the generic reason" \
  "connection failed (curl exit 7): curl: (7) Failed to connect to node-d port 443: Connection refused" \
  "$(jq -r '.reason' <<<"$probe_refused")"

probe_timeout="$(host_facts_viewer_probe_one node-e http://node-e/data.js "$timeout_curl")"
assert_eq "a timed-out fetch reads ok:false" "false" "$(jq -r '.ok' <<<"$probe_timeout")"
assert_eq "a timed-out fetch names the timeout, distinctly from a connection failure" \
  "timed out (curl exit 28)" "$(jq -r '.reason' <<<"$probe_timeout")"

probe_bad_body="$(host_facts_viewer_probe_one node-c http://node-c/data.js "$bad_body_curl")"
assert_eq "a body that will not parse reads ok:false" "false" "$(jq -r '.ok' <<<"$probe_bad_body")"
assert_eq "a body that will not parse still reports what it received" \
  "body did not parse as JSON" "$(jq -r '.reason' <<<"$probe_bad_body")"

probe_json="$(host_facts_viewer_probe_json $'node-a\nnode-b' 'http://{node}/data.js' "$ok_curl")"
assert_eq "the probe object is keyed by every node in the list" \
  '["node-a","node-b"]' "$(jq -c 'keys' <<<"$probe_json")"

# --- Viewer probe URL template (agent-ops#2779/#2528) --------------------------
# Regression: bash's `${VAR:-default}` expansion treats the first unescaped
# `}` inside the default text as closing the expansion, so an unescaped
# `{node}` placeholder in the default template used to be silently
# truncated to `{node` whenever the override was unset or empty — curl's
# own URL globbing then expanded that to the literal hostname `node` for
# every target, which is exactly what made every probe fail 100% of the
# time against every node.
unset AGENT_OPS_VIEWER_URL_TEMPLATE
assert_eq "the default template keeps its {node} placeholder intact when the override is unset" \
  "https://{node}/data.js" "$(host_facts_viewer_url_template)"

AGENT_OPS_VIEWER_URL_TEMPLATE=""
assert_eq "an empty override also falls through to the same intact default" \
  "https://{node}/data.js" "$(host_facts_viewer_url_template)"

AGENT_OPS_VIEWER_URL_TEMPLATE="http://{node}:9999/viewer.js"
assert_eq "a non-empty override is used verbatim" \
  "http://{node}:9999/viewer.js" "$(host_facts_viewer_url_template)"
unset AGENT_OPS_VIEWER_URL_TEMPLATE

# --- Viewer probe fold (owner decision #1358, agent-ops#2788) -----------------
# The `viewer-probe` sidecar writes {"generated_at":…, "viewer_probe":{…}} to
# its own file on the shared state volume; `collect-host-facts.sh` folds it
# in when fresh, and must fall back — printing nothing, returning 1 — on
# every other shape: missing file, stale timestamp, no `viewer_probe` key,
# unparseable JSON.
fold_dir="$tmp_dir/viewer-probe"
mkdir -p "$fold_dir"
now_epoch=1793555200  # 2026-11-01T17:46:40Z, fixed so this needs no live clock

fresh_file="$fold_dir/fresh.json"
printf '{"generated_at":"2026-11-01T17:46:10Z","viewer_probe":{"poetic-1":{"ok":true,"bytes":42,"seconds":0.1,"reason":null}}}' \
  > "$fresh_file"  # 30s before now_epoch
assert_eq "a file present and fresh folds its own viewer_probe object in" \
  '{"poetic-1":{"ok":true,"bytes":42,"seconds":0.1,"reason":null}}' \
  "$(host_facts_viewer_probe_fold_json "$fresh_file" 900 "$now_epoch")"

stale_file="$fold_dir/stale.json"
printf '{"generated_at":"2026-11-01T17:30:00Z","viewer_probe":{"poetic-1":{"ok":true,"bytes":1,"seconds":0.1,"reason":null}}}' \
  > "$stale_file"  # 970s before now_epoch, older than the 900s window
assert_eq "a file older than the window falls back (non-zero)" \
  "1" "$(host_facts_viewer_probe_fold_json "$stale_file" 900 "$now_epoch" >/tmp/fold-stale.$$ 2>/dev/null; echo $?)"
assert_eq "a stale file's own stdout is empty, the caller's fall-back signal" \
  "" "$(cat /tmp/fold-stale.$$)"
rm -f /tmp/fold-stale.$$

assert_eq "a missing file falls back (non-zero, no stdout)" \
  "1" "$(host_facts_viewer_probe_fold_json "$fold_dir/no-such-file.json" 900 "$now_epoch" >/tmp/fold-missing.$$ 2>/dev/null; echo $?)"
assert_eq "a missing file prints nothing to fall back on" "" "$(cat /tmp/fold-missing.$$)"
rm -f /tmp/fold-missing.$$

no_key_file="$fold_dir/no-key.json"
printf '{"generated_at":"2026-11-01T17:46:10Z"}' > "$no_key_file"
assert_eq "a fresh file with no viewer_probe key still falls back" \
  "1" "$(host_facts_viewer_probe_fold_json "$no_key_file" 900 "$now_epoch" >/dev/null 2>&1; echo $?)"

malformed_file="$fold_dir/malformed.json"
printf 'not json at all' > "$malformed_file"
assert_eq "malformed JSON falls back rather than aborting the caller" \
  "1" "$(host_facts_viewer_probe_fold_json "$malformed_file" 900 "$now_epoch" >/dev/null 2>&1; echo $?)"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
