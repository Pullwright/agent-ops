#!/usr/bin/env bash
#
# test/stage-api-refusal.test.sh — `stage_api_refusal`/`stage_api_refusal_class`/
# `stage_api_refusal_message` (lib/stage-attempt.sh), covering two fixes
# agent-ops#2308 makes to them: a bare `terminal_reason: "api_error"` now
# carries its own HTTP status in the returned token rather than being
# returned verbatim, and a model credential the API refuses for carrying no
# workspace scope is named by its own stable token, `workspace_scope_refused`,
# rather than falling through unclassified.
#
# Run directly: ./test/stage-api-refusal.test.sh — exit 0 iff all passed.

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

# shellcheck source=lib/stage-attempt.sh
. "$SCRIPT_DIR/lib/stage-attempt.sh"

# --- The fix: a bare `terminal_reason: "api_error"` now carries its status ---
echo '{"is_error":true,"terminal_reason":"api_error","api_error_status":400,"result":"some other 400 problem"}' \
  > "$tmp_dir/bare-api-error-400.out"
assert_eq "a bare terminal_reason of api_error now carries its own status" \
  "api_error_400" "$(stage_api_refusal "$tmp_dir/bare-api-error-400.out")"
assert_eq "…and is classified refused, an ordinary 4xx" \
  "refused" "$(stage_api_refusal_class "$tmp_dir/bare-api-error-400.out")"

# --- The new token: a key refused for carrying no workspace scope ---
echo '{"is_error":true,"terminal_reason":"api_error","api_error_status":400,"result":"This API key is not scoped to a workspace, so this request must include the anthropic-workspace-id header with the ID of the workspace to use. Add the header, or use an API key that is scoped to a workspace."}' \
  > "$tmp_dir/workspace-scoped.out"
assert_eq "an unscoped-workspace key is named by its own stable token" \
  "workspace_scope_refused" "$(stage_api_refusal "$tmp_dir/workspace-scoped.out")"
assert_eq "…and classified refused: no retry clears it, only a rescoped key" \
  "refused" "$(stage_api_refusal_class "$tmp_dir/workspace-scoped.out")"
assert_eq "…with the API's own words kept beside the name" \
  "This API key is not scoped to a workspace, so this request must include the anthropic-workspace-id header with the ID of the workspace to use. Add the header, or use an API key that is scoped to a workspace." \
  "$(stage_api_refusal_message "$tmp_dir/workspace-scoped.out")"

# A sibling wording for the same class of fault: an invalid x-api-key.
echo '{"is_error":true,"terminal_reason":"api_error","api_error_status":401,"result":"invalid x-api-key"}' \
  > "$tmp_dir/invalid-key.out"
assert_eq "an invalid x-api-key message takes the same token" \
  "workspace_scope_refused" "$(stage_api_refusal "$tmp_dir/invalid-key.out")"

# --- Existing cases unchanged: authentication_failed ---
cat > "$tmp_dir/unauthenticated.out" <<'REC'
{"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error","api_error_status":null,"duration_ms":559,"num_turns":1,"result":"Failed to authenticate: OAuth session expired and could not be refreshed","total_cost_usd":0}
REC
assert_eq "authentication_failed is unchanged by either fix" \
  "authentication_failed" "$(stage_api_refusal "$tmp_dir/unauthenticated.out")"
assert_eq "…and still classifies refused" \
  "refused" "$(stage_api_refusal_class "$tmp_dir/unauthenticated.out")"

# --- Existing case unchanged: a 503 is still transient, not api_error_503
#     mistaken for a credential refusal ---
cat > "$tmp_dir/ockham-503.out" <<'REC'
{"is_error":true,"api_error_status":503,"terminal_reason":"api_error","result":"API Error: ERROR: The requested URL could not be retrieved. This is a server-side issue, usually temporary — try again in a moment. If it persists, check https://status.claude.com."}
REC
assert_eq "a bare api_error 503 still carries its status in the token" \
  "api_error_503" "$(stage_api_refusal "$tmp_dir/ockham-503.out")"
assert_eq "…and is still classified transient, not refused" \
  "transient" "$(stage_api_refusal_class "$tmp_dir/ockham-503.out")"

if (( failures > 0 )); then
  printf '\n%d assertion(s) failed.\n' "$failures"
  exit 1
fi
printf '\nAll assertions passed.\n'
