#!/usr/bin/env bash
#
# test/stage-project-settings.test.sh — a stage is never launched in a
# directory whose Claude Code project settings could make the runner run
# something (requirement 4k).
#
# What this guards:
#
#   the allowlist
#     `stage_project_settings_refusal` passes a settings file only when every
#     key in it is inert, or is a hook or MCP-approval key that the image's
#     managed policy makes inert. `env`, the credential and telemetry helpers,
#     `processWrapper` and plugin enabling are refused with or without the
#     policy, because no managed key can switch them off; `hooks` is refused
#     when the policy is absent. A file that is not a JSON object is refused
#     rather than guessed at, and `settings.local.json` is vetted exactly as
#     `settings.json` is.
#
#   the launcher
#     `run_claude_stage` must not start the runner at all in such a directory:
#     the stub `claude` below records every invocation, and a refused stage
#     must leave no record of one. It must also leave the reason where a
#     reader looks (`<stage>.out.stderr`, `stage_launch_refusal`), leave
#     `stage_kill_reason` empty (a cap kill is read by the stage-budget
#     controller and the rework ledger, and this is neither), and give
#     `handle_stage_failure` a detail that names what happened.
#
# `claude` is a stub on PATH; nothing here reaches a model.
#
# Run directly: ./test/stage-project-settings.test.sh — exit 0 iff all passed.

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
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:   %s\n' \
      "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# shellcheck source=lib/stage-run.sh
. "$SCRIPT_DIR/lib/stage-run.sh"
# shellcheck source=lib/stage-attempt.sh
. "$SCRIPT_DIR/lib/stage-attempt.sh"

# The signal handlers' globals, which run_claude_stage advertises into.
# shellcheck disable=SC2034
stage_pid=""
# shellcheck disable=SC2034
stage_name=""

# The managed policy as the image installs it, and a path where none exists.
policy="$tmp_dir/managed-settings.json"
cp "$SCRIPT_DIR/deploy/docker/claude-managed-settings.json" "$policy"
no_policy="$tmp_dir/no-such-managed-settings.json"

# checkout NAME FILE JSON — a scratch checkout with one settings file in it.
checkout() {
  local dir="$tmp_dir/$1"
  mkdir -p "$dir/.claude"
  [[ -n "$2" ]] && printf '%s\n' "$3" >"$dir/.claude/$2"
  printf '%s' "$dir"
}

# refusal DIR POLICY — the guard's output and status, as "<rc>|<output>".
refusal() {
  local out rc
  out="$(STAGE_CLAUDE_MANAGED_SETTINGS="$2" stage_project_settings_refusal "$1")"
  rc=$?
  printf '%s|%s' "$rc" "$out"
}

# --- 1. The allowlist ------------------------------------------------------------
assert_eq "with no managed policy, only the inert keys are allowed" \
  "$STAGE_PROJECT_SETTINGS_INERT_KEYS" \
  "$(STAGE_CLAUDE_MANAGED_SETTINGS="$no_policy" stage_project_settings_allowed_keys)"
assert_eq "the shipped policy adds the hook and MCP-approval keys it makes inert" \
  '["hooks","enableAllProjectMcpServers","enabledMcpjsonServers","disabledMcpjsonServers"]' \
  "$(STAGE_CLAUDE_MANAGED_SETTINGS="$policy" stage_project_settings_allowed_keys \
     | jq -c --argjson inert "$STAGE_PROJECT_SETTINGS_INERT_KEYS" '. - $inert')"
printf '%s\n' '{"allowManagedHooksOnly": false, "allowedMcpServers": [{"serverName": "x"}]}' \
  >"$tmp_dir/weak-policy.json"
assert_eq "a policy that does not pin a control does not unlock its keys" \
  "$STAGE_PROJECT_SETTINGS_INERT_KEYS" \
  "$(STAGE_CLAUDE_MANAGED_SETTINGS="$tmp_dir/weak-policy.json" stage_project_settings_allowed_keys)"

# --- 2. What is refused, and what is not ------------------------------------------
assert_eq "a directory with no project settings is not refused" \
  "1|" "$(refusal "$(checkout none "" "")" "$no_policy")"
# shellcheck disable=SC2016  # "$schema" is a JSON key, not a variable
assert_eq "inert keys are not refused" \
  "1|" "$(refusal "$(checkout inert settings.json \
    '{"$schema":"x","permissions":{"allow":["Bash(npm test)"]},"includeCoAuthoredBy":true}')" "$no_policy")"

hooks_dir="$(checkout hooks settings.json \
  '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"true"}]}]}}')"
assert_eq "hooks are refused when no managed policy makes them inert" \
  "0|.claude/settings.json sets hooks" "$(refusal "$hooks_dir" "$no_policy")"
assert_eq "and allowed under the shipped policy" \
  "1|" "$(refusal "$hooks_dir" "$policy")"

for key in env apiKeyHelper awsAuthRefresh awsCredentialExport gcpAuthRefresh \
           otelHeadersHelper proxyAuthHelper processWrapper enabledPlugins \
           extraKnownMarketplaces statusLine; do
  assert_eq "$key is refused even under the shipped policy" \
    "0|.claude/settings.json sets $key" \
    "$(refusal "$(checkout "key-$key" settings.json "{\"$key\":\"x\"}")" "$policy")"
done

assert_eq "the refusal names every key outside the allowlist, in file order" \
  "0|.claude/settings.json sets env, apiKeyHelper" \
  "$(refusal "$(checkout two settings.json \
    '{"permissions":{},"env":{"BASH_ENV":"x"},"apiKeyHelper":"x"}')" "$policy")"
assert_eq "settings.local.json is vetted as settings.json is" \
  "0|.claude/settings.local.json sets enabledPlugins" \
  "$(refusal "$(checkout local settings.local.json '{"enabledPlugins":{"p@m":true}}')" "$policy")"
assert_eq "a file jq cannot parse is refused, not guessed at" \
  "0|.claude/settings.json cannot be read as a JSON object" \
  "$(refusal "$(checkout broken settings.json '{"env": {')" "$policy")"
assert_eq "so is valid JSON that is not an object" \
  "0|.claude/settings.json cannot be read as a JSON object" \
  "$(refusal "$(checkout array settings.json '["env"]')" "$policy")"

link_dir="$(checkout link "" "")"
printf '%s\n' '{"env":{"BASH_ENV":"x"}}' >"$tmp_dir/elsewhere.json"
ln -s "$tmp_dir/elsewhere.json" "$link_dir/.claude/settings.json"
assert_eq "a settings file that is a symlink is vetted by what it points at" \
  "0|.claude/settings.json sets env" "$(refusal "$link_dir" "$policy")"

# --- 3. The launcher -------------------------------------------------------------
mkdir -p "$tmp_dir/bin"
cat >"$tmp_dir/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf 'invoked\n' >> "$STUB_CAPTURE/invocations"
cat > /dev/null
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"done"}'
STUB
chmod +x "$tmp_dir/bin/claude"
export PATH="$tmp_dir/bin:$PATH"

refused_dir="$(checkout launch-refused settings.json '{"env":{"BASH_ENV":"./x.sh"}}')"
export STUB_CAPTURE="$refused_dir"
STAGE_CLAUDE_MANAGED_SETTINGS="$policy" \
  run_claude_stage reviewer 60 test-model "a prompt" "$refused_dir/reviewer.out" "$refused_dir"
rc=$?
assert_eq "a refused stage returns non-zero" "1" "$rc"
assert_eq "and never starts the runner" \
  "no" "$([[ -e "$refused_dir/invocations" ]] && echo yes || echo no)"
assert_contains "it says why on the stage's stderr" \
  "the reviewer stage was not launched: .claude/settings.json sets env" \
  "$(cat "$refused_dir/reviewer.out.stderr" 2>/dev/null)"
assert_eq "and in stage_launch_refusal" \
  ".claude/settings.json sets env" "$stage_launch_refusal"
assert_eq "without claiming a cap killed it" "" "$stage_kill_reason"
assert_eq "its .out is empty, as a stage that never ran leaves it" \
  "0" "$(wc -c < "$refused_dir/reviewer.out")"
assert_eq "and so is its stream" \
  "0" "$(wc -c < "$refused_dir/reviewer.stream.jsonl")"

# handle_stage_failure's collaborators, stubbed to capture the detail.
log_attempt_failed() { captured_detail="$2"; }
detect_and_log_limit_hit() { return 1; }
release_claim() { :; }
captured_detail=""
handle_stage_failure reviewer "$rc" "$refused_dir/reviewer.out"
assert_eq "handle_stage_failure records a not-launched stage as such" \
  "reviewer was not launched: the checkout's Claude Code project settings hold keys no stage loads" \
  "$captured_detail"

allowed_dir="$(checkout launch-allowed settings.json \
  '{"permissions":{},"hooks":{"SessionStart":[]}}')"
export STUB_CAPTURE="$allowed_dir"
STAGE_CLAUDE_MANAGED_SETTINGS="$policy" \
  run_claude_stage reviewer 60 test-model "a prompt" "$allowed_dir/reviewer.out" "$allowed_dir"
rc=$?
assert_eq "an allowed directory launches the runner as before" "0" "$rc"
assert_eq "exactly once" "1" "$(wc -l < "$allowed_dir/invocations" 2>/dev/null || echo 0)"
assert_eq "and a launched stage clears the refusal a previous one left" \
  "" "$stage_launch_refusal"

printf '\n'
if (( failures )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
