#!/usr/bin/env bash
#
# scripts/grok-policy-probe.sh — does this machine's `grok` run what a
# checkout plants for it (issue #2134, requirement 4k's Grok counterpart)?
#
# Builds a scratch checkout holding the things a pull-request head could use
# to run a command the moment a headless Grok stage starts in it, under
# `GROK_FOLDER_TRUST=0` — a `.grok/hooks/start.json` hook; a `.claude/settings.json`
# hook, which Grok also runs under its own Claude-compatibility layer; an MCP
# server in `.grok/config.toml` and another in `.mcp.json`; and a project
# `.envrc` — then runs `grok -p` in it once, as a stage would. It reports
# which of the five ran and whether the clone's own `AGENTS.md` and a staged
# skill still loaded, which the policy must never block.
#
# No model is reached and nothing is billed: a local stand-in answers
# `GET /v1/models` and `GET /v1/api-key` (`GROK_XAI_API_BASE_URL`, the same
# override docs/reviews/2026-10-06-grok-build-evaluation.md §10 used) so
# Grok's own model-id check — which, unlike Claude Code's, needs a real
# answer before it will do anything else at all, model validation included
# — passes locally, and refuses everything else, so no chat-completion
# request the actual model is ever reached, which the image build's own
# `--network none` would refuse in any case. Every planted vector fires
# before that refusal.
#
# In the node image `grok` is the stage shim (deploy/docker/grok-shim.sh), so
# the CLI runs as the stage user, as a stage's does. The scratch checkout is
# therefore shared with that user (`stage_workspace_share`, requirement 45e),
# as the Script shares the Implementer's clone, and removed with
# `stage_workspace_remove`; outside the image both degrade to what they were.
#
# Usage: scripts/grok-policy-probe.sh [--expect blocked|ran]
#   --expect blocked (the default): exit 0 iff none of the five ran and the
#     instructions and skill still loaded — the policy is in force.
#   --expect ran: exit 0 iff all five ran — the control that shows the probe
#     can see what it is looking for.

set -uo pipefail

expect="blocked"
case "${1:-}" in
  "") ;;
  --expect)
    expect="${2:-}"
    [[ "$expect" == "blocked" || "$expect" == "ran" ]] \
      || { printf 'usage: %s [--expect blocked|ran]\n' "$0" >&2; exit 2; }
    ;;
  *) printf 'usage: %s [--expect blocked|ran]\n' "$0" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/stage-boundary.sh
source "$SCRIPT_DIR/lib/stage-boundary.sh"

probe="$(mktemp -d)"
trap 'stage_workspace_remove "$probe"' EXIT
marks="$probe/marks"
work="$probe/checkout"
mkdir -p "$marks" "$work/.grok/hooks" "$work/.claude/skills/policy-probe"

git -C "$work" init -q
printf '# Policy probe\nReply with the single word: ok\n' >"$work/AGENTS.md"
printf -- '---\nname: policy-probe\ndescription: A skill the probe checks still loads.\n---\n# Policy probe\n' \
  >"$work/.claude/skills/policy-probe/SKILL.md"
jq -n --arg m "$marks" \
  '{hooks: [{event: "SessionStart", command: "touch \($m)/grok-hook"}]}' \
  >"$work/.grok/hooks/start.json"
jq -n --arg m "$marks" \
  '{hooks: {SessionStart: [{hooks: [{type: "command", command: "touch \($m)/claude-settings-hook"}]}]}}' \
  >"$work/.claude/settings.json"
# Grok reads TOML here, not JSON, so this fixture is written directly
# rather than through jq, which the rest of this script uses only where the
# target format is itself JSON.
printf '[mcp_servers.policy-probe]\ncommand = "sh"\nargs = ["-c", "touch %s/grok-config-mcp; exec cat"]\n' \
  "$marks" >"$work/.grok/config.toml"
jq -n --arg m "$marks" \
  '{mcpServers: {"policy-probe-json": {command: "sh", args: ["-c", "touch \($m)/mcpjson-mcp; exec cat"]}}}' \
  >"$work/.mcp.json"
printf 'touch %s/envrc\n' "$marks" >"$work/.envrc"
# Never `--prompt-file /dev/stdin`: Grok opens whatever `--prompt-file`
# names by path, even `/dev/stdin`, and re-opening a process's own stdin by
# path is a fresh `open()` the kernel checks against the *original* file's
# permission bits — which fail once `grok` crosses into the stage user
# (lib/substrate-grok-build.sh's own `_exec` has the full account). Written
# here, before `stage_workspace_share` below, so it is shared with the
# stage user the same way every other fixture in this checkout is, rather
# than needing its own chgrp/chmod.
printf 'Reply with the single word: ok\n' >"$probe/prompt.txt"

# A minimal stand-in for api.x.ai, listening on loopback only (reachable
# across the stage-user boundary within the same network namespace, but
# never leaving the container even without `--network none`). Answers the
# two GET routes Grok's own start-up needs — a model list that admits
# whatever `-m` names, and an unblocked/undisabled api-key report — and
# refuses everything else, `/v1/chat/completions` included, so no model
# call ever succeeds whatever the image's own network policy is.
standin_py="$probe/standin.py"
cat >"$standin_py" <<'PYEOF'
import http.server
import json
import sys

MODEL_ID = sys.argv[1] if len(sys.argv) > 1 else "grok-build-0.1"


class Handler(http.server.BaseHTTPRequestHandler):
    def _json(self, status, body):
        payload = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        if self.path.startswith("/v1/models"):
            self._json(200, {"data": [{"id": MODEL_ID, "object": "model"}]})
        elif self.path.startswith("/v1/api-key"):
            self._json(
                200,
                {
                    "api_key_blocked": False,
                    "api_key_disabled": False,
                    "team_blocked": False,
                    "acls": ["api-key"],
                    "api_key_id": "policy-probe",
                    "name": "policy-probe",
                    "team_id": "policy-probe-team",
                },
            )
        else:
            self._json(403, {"error": "refused by the policy-probe stand-in"})

    def do_POST(self):
        self._json(403, {"error": "refused by the policy-probe stand-in"})

    def log_message(self, fmt, *args):
        with open(sys.argv[2], "a") as f:
            f.write((fmt % args) + "\n")


server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
PYEOF

python3 "$standin_py" grok-build-0.1 "$probe/standin.requests" >"$probe/standin.port" 2>"$probe/standin.stderr" &
standin_pid=$!
trap 'kill "$standin_pid" 2>/dev/null; stage_workspace_remove "$probe"' EXIT
standin_waited=0
while [[ ! -s "$probe/standin.port" ]] && (( standin_waited < 50 )); do
  sleep 0.1
  standin_waited=$(( standin_waited + 1 ))
done
standin_port="$(cat "$probe/standin.port" 2>/dev/null || true)"
if [[ ! "$standin_port" =~ ^[0-9]+$ ]]; then
  printf 'grok-policy-probe: the local stand-in never reported a port\n' >&2
  cat "$probe/standin.stderr" >&2 2>/dev/null || true
  exit 1
fi

stage_workspace_share "$probe" \
  || { printf 'grok-policy-probe: cannot share %s with the stage user\n' "$probe" >&2; exit 1; }

(
  cd "$work" || exit 1
  timeout 60 env GROK_FOLDER_TRUST=0 GROK_DISABLE_AUTOUPDATER=1 GROK_TELEMETRY_ENABLED=0 \
    XAI_API_KEY=xai-policy-probe-placeholder \
    GROK_XAI_API_BASE_URL="http://127.0.0.1:$standin_port" \
    grok -m grok-build-0.1 --permission-mode bypassPermissions \
    --output-format streaming-messages-json --include-partial-messages \
    --prompt-file "$probe/prompt.txt" \
    >"$probe/run.jsonl" 2>"$probe/run.stderr"
)
run_rc=$?
printf 'grok exit status: %s\n' "$run_rc"
printf 'stdout bytes: %s\n' "$(wc -c <"$probe/run.jsonl" 2>/dev/null || echo 0)"
if [[ -s "$probe/run.stderr" ]]; then
  printf 'stderr (first 2000 bytes):\n%s\n' "$(head -c 2000 "$probe/run.stderr")"
fi
if [[ -s "$probe/standin.requests" ]]; then
  printf 'stand-in requests:\n%s\n' "$(cat "$probe/standin.requests")"
fi

ran=()
for m in grok-hook claude-settings-hook grok-config-mcp mcpjson-mcp envrc; do
  [[ -e "$marks/$m" ]] && ran+=("$m")
done
# A looser signal than claude-policy-probe.sh's own skill-name check against
# the `init` line's `skills` array: Grok's `init` line shape has not been
# captured for every field this probe could otherwise assert on. Reaching a
# terminal `result` line at all is still informative, since the model can
# only answer "ok" once its own AGENTS.md instructions (and, were the prompt
# to ask for it, the staged skill) have been read off disk — a policy that
# somehow blocked those too would show up here as no result line at all.
result_line="$(jq -c 'select(type == "object" and .type == "result")' "$probe/run.jsonl" 2>/dev/null | tail -n 1)"

printf 'ran: %s\n' "${ran[*]:-none}"
printf 'reached a result line: %s\n' "$([[ -n "$result_line" ]] && echo yes || echo no)"

if [[ "$expect" == "blocked" ]]; then
  (( ${#ran[@]} == 0 ))
else
  (( ${#ran[@]} == 5 ))
fi
