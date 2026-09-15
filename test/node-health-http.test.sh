#!/usr/bin/env bash
#
# test/node-health-http.test.sh — scripts/node-health-server.py (issue #608,
# requirement 58d): the HTTP surface over scripts/node-health.sh.
#
# The two other node-health suites cover the computation
# (test/node-health.test.sh) and the CLI that gathers its inputs
# (test/node-health-cli.test.sh). This one covers the only thing neither can:
# that the four documented paths answer over a real socket, with the
# documented status codes and a JSON body either way, that nothing else
# answers at all, and that a request arriving while `state_dir` cannot be
# read still gets valid JSON reading `unknown` rather than a stack trace or a
# hang — acceptance criterion 8, which is a property of the responder and not
# of anything the CLI's own tests can reach.
#
# Hermetic: HOME points at a fixture directory, so the server's own
# argument-less CLI call resolves config.json's `~`-relative state_dir and
# workspace_root inside it and never touches this node's real state; a `gh`
# stub on PATH answers the one forge read `--ready` makes, so nothing here
# reaches the network either.
#
# Run directly: ./test/node-health-http.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER="$SCRIPT_DIR/scripts/node-health-server.py"

tmp_dir="$(mktemp -d)"
server_pid=""
cleanup() {
  [[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null
  # The unreadable-state-dir case leaves a directory nothing can traverse.
  chmod -R u+rwX "$tmp_dir" 2>/dev/null
  rm -rf "$tmp_dir"
}
trap cleanup EXIT

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

export HOME="$tmp_dir/home"
export CLAUDE_CONFIG_DIR="$tmp_dir/claude-config"
state_dir="$HOME/.local/state/poetic-agents"
mkdir -p "$state_dir" "$HOME/.cache/poetic-agents/workspaces"

# One forge answer, from a stub rather than the network: `--ready` is the one
# mode that reads it, and a real `gh` here would either hang or make the test
# depend on this node's own credentials.
stub_dir="$tmp_dir/stub"
mkdir -p "$stub_dir"
cat > "$stub_dir/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" == "api rate_limit" ]]; then
  printf '%s' '{"resources":{"core":{"remaining":4999,"limit":5000},"graphql":{"remaining":4999,"limit":5000}}}'
  exit 0
fi
exit 1
STUB
chmod +x "$stub_dir/gh"
export PATH="$stub_dir:$PATH"

# A free port, asked for and released immediately — the same small race every
# server test in this repository accepts, and the alternative (a fixed port)
# collides with whatever else is listening on a developer's own machine.
port="$(python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()')"

cat > "$tmp_dir/get.py" <<'PY'
import sys
import urllib.error
import urllib.request

url = "http://127.0.0.1:%s%s" % (sys.argv[1], sys.argv[2])
try:
    with urllib.request.urlopen(url, timeout=30) as response:
        status, body = response.status, response.read().decode("utf-8")
except urllib.error.HTTPError as exc:          # 404/503 are answers, not failures
    status, body = exc.code, exc.read().decode("utf-8")
except Exception as exc:                        # noqa: BLE001 — reported, not raised
    status, body = 0, str(exc)
print(status)
print(body.replace("\n", " "))
PY

get_status() { python3 "$tmp_dir/get.py" "$port" "$1" | head -1; }
get_body()   { python3 "$tmp_dir/get.py" "$port" "$1" | tail -n +2; }

"$SERVER" "$port" 127.0.0.1 >"$tmp_dir/server.log" 2>&1 &
server_pid=$!

ready=0
for _ in $(seq 1 60); do
  if [[ "$(get_status /livez)" =~ ^(200|503)$ ]]; then ready=1; break; fi
  sleep 0.5
done
assert_eq "the server accepts connections" "1" "$ready"
if (( ! ready )); then
  cat "$tmp_dir/server.log" >&2
  printf '%d failure(s)\n' "$(( failures + 1 ))"
  exit 1
fi

# --- The four documented paths, their codes and their bodies ---------------

# No liveness marker has ever been touched in this fixture, so /livez is the
# 503 half of the contract; the body is still JSON, and still says why.
assert_eq "/livez answers 503 when the node is not live" "503" "$(get_status /livez)"
assert_eq "/livez's 503 still carries the CLI's own JSON body" "false" \
  "$(get_body /livez | jq -r '.live')"

touch "$state_dir/.node-alive"
assert_eq "/livez answers 200 once the marker is fresh" "200" "$(get_status /livez)"
assert_eq "/livez's 200 body reads live" "true" "$(get_body /livez | jq -r '.live')"

assert_eq "/readyz answers 503 when a condition is unmet" "503" "$(get_status /readyz)"
assert_eq "/readyz names the unmet conditions rather than a bare boolean" "true" \
  "$(get_body /readyz | jq '(.unmet | length) > 0')"

assert_eq "/healthz answers 503 while no component has a source" "503" "$(get_status /healthz)"
assert_eq "/healthz reads unknown, never ok, with nothing published" "unknown" \
  "$(get_body /healthz | jq -r '.status')"

assert_eq "/metrics answers 200 — it reports data, never a verdict" "200" "$(get_status /metrics)"
assert_eq "/metrics carries the documented object" "true" \
  "$(get_body /metrics | jq 'has("node") and has("live") and has("ready") and has("health")')"

# --- And nothing else ------------------------------------------------------

for path in / /healthz/ /metrics/extra /../etc/passwd /livez?x=1; do
  assert_eq "$path is 404" "404" "$(get_status "$path")"
done
assert_eq "a 404 is JSON too, and names the routes that do exist" "4" \
  "$(get_body /nope | jq '.routes | length')"

# --- An unreadable state dir answers, rather than hanging or crashing ------
# Acceptance criterion 8. Root bypasses the permission bits that make this
# case exist at all, so the assertion is skipped there rather than passing
# vacuously; the image this suite runs in is non-root (`USER agent`).
if (( EUID != 0 )); then
  chmod 000 "$state_dir"
  status="$(get_status /healthz)"
  body="$(get_body /healthz)"
  chmod 755 "$state_dir"
  assert_eq "an unreadable state_dir still answers /healthz" "503" "$status"
  assert_eq "and answers it with valid JSON reading unknown, not a stack trace" "unknown" \
    "$(jq -r '.status' <<<"$body" 2>/dev/null)"
else
  printf 'skip - unreadable state_dir (running as root: the permission bits do not apply)\n'
fi

echo
if (( failures > 0 )); then
  printf '%d failure(s)\n' "$failures"
  exit 1
fi
echo "all passed"
