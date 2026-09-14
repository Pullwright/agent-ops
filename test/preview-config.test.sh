#!/usr/bin/env bash
#
# test/preview-config.test.sh — regression test for lib/preview-config.sh
# (D19 Phase 1, agent-ops#586, requirement 24a).
#
#   - preview_config_for_repo — resolves a repo's `preview` block, falling
#     back to `{"provider": "none"}` when the repo carries no `preview` key
#     or is absent from `repos[]` entirely. Unlike `merge_autonomy` and its
#     neighbours, there is no top-level key to fall through to first — a
#     preview arrangement is inherently repository-specific.
#   - preview_config_export_vercel_credentials — remaps whichever
#     `vercel.bypass_secret_env`/`vercel.token_env` a repo names onto the two
#     fixed variable names `scripts/preview-deploy.sh` itself still reads, so
#     that script needs no change for a repository whose secret lives under a
#     different name. A no-op on the defaulted names, and inert when
#     `provider` is not `"vercel"`.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/preview-config.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/preview-config.sh
. "$SCRIPT_DIR/lib/preview-config.sh"

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

# --- preview_config_for_repo ---

no_repos_cfg='{}'
assert_eq "a config with no repos[] at all resolves to provider none" '{"provider":"none"}' \
  "$(preview_config_for_repo "$no_repos_cfg" "acme/widgets")"

no_key_cfg='{"repos": [{"slug": "acme/widgets"}]}'
assert_eq "a repo entry with no preview key resolves to provider none" '{"provider":"none"}' \
  "$(preview_config_for_repo "$no_key_cfg" "acme/widgets")"

unlisted_cfg='{"repos": [{"slug": "acme/widgets", "preview": {"provider": "vercel"}}]}'
assert_eq "a slug absent from repos[] entirely resolves to provider none" '{"provider":"none"}' \
  "$(preview_config_for_repo "$unlisted_cfg" "acme/unlisted")"

vercel_cfg='{"repos": [
  {"slug": "acme/widgets", "preview": {"provider": "vercel", "vercel": {"bypass_secret_env": "ACME_BYPASS"}}},
  {"slug": "acme/gizmos", "preview": {"provider": "none"}}
]}'
assert_eq "a configured vercel entry is returned unchanged" \
  '{"provider":"vercel","vercel":{"bypass_secret_env":"ACME_BYPASS"}}' \
  "$(preview_config_for_repo "$vercel_cfg" "acme/widgets")"
assert_eq "an explicit provider none entry is returned unchanged" '{"provider":"none"}' \
  "$(preview_config_for_repo "$vercel_cfg" "acme/gizmos")"

# --- preview_config_export_vercel_credentials ---

unset VERCEL_AUTOMATION_BYPASS_SECRET VERCEL_TOKEN ACME_BYPASS ACME_TOKEN 2>/dev/null || true

preview_config_export_vercel_credentials '{"provider":"none"}'
assert_eq "provider none exports nothing" "" "${VERCEL_AUTOMATION_BYPASS_SECRET:-}"

VERCEL_AUTOMATION_BYPASS_SECRET="default-secret"
VERCEL_TOKEN="default-token"
preview_config_export_vercel_credentials '{"provider":"vercel"}'
assert_eq "the defaulted names are a no-op on themselves (bypass)" "default-secret" \
  "$VERCEL_AUTOMATION_BYPASS_SECRET"
assert_eq "the defaulted names are a no-op on themselves (token)" "default-token" \
  "$VERCEL_TOKEN"

export ACME_BYPASS="acme-secret-value"
export ACME_TOKEN="acme-token-value"
preview_config_export_vercel_credentials \
  '{"provider":"vercel","vercel":{"bypass_secret_env":"ACME_BYPASS","token_env":"ACME_TOKEN"}}'
assert_eq "a named override remaps onto the fixed bypass-secret variable" "acme-secret-value" \
  "$VERCEL_AUTOMATION_BYPASS_SECRET"
assert_eq "a named override remaps onto the fixed token variable" "acme-token-value" \
  "$VERCEL_TOKEN"

unset VERCEL_AUTOMATION_BYPASS_SECRET
preview_config_export_vercel_credentials \
  '{"provider":"vercel","vercel":{"bypass_secret_env":"MISSING_VAR_ACME"}}'
assert_eq "an override naming an unset variable remaps to empty, not left unset" "" \
  "${VERCEL_AUTOMATION_BYPASS_SECRET-unset}"

echo
if (( failures == 0 )); then
  echo "all assertions passed"
  exit 0
else
  echo "$failures assertion(s) failed"
  exit 1
fi
