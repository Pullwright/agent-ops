#!/usr/bin/env bash
#
# lib/reason-url.sh — generate URLs for reason code documentation
#
# This library provides a single point of configuration for reason code URLs,
# allowing the base URL to be changed in one place when documentation
# migrates from GitHub to a dedicated site.
#
# Sourced, never executed: no shell options are set here, matching every
# other lib/*.sh — the caller owns those.

# Build a URL to a reason code's documentation entry
# reason_code_url CODE -> URL
#
# Returns the GitHub-anchored URL by default. When a dedicated site is deployed,
# change the base URL here and all usages throughout the codebase will
# automatically point to the new location.
reason_code_url() {
  local code="$1"
  # Base URL configured here — change this to the site address when deployed
  local base_url="${REASON_DOCS_BASE_URL:-https://github.com/Pullwright/agent-ops/blob/main/docs/reference/reasons.md}"
  printf '%s#%s' "$base_url" "$(printf '%s' "$code" | sed 's/[^a-z0-9]/-/g')"
}

# reason_docs_base_url [NEW_BASE]
# Get or set the base URL for reason documentation
reason_docs_base_url() {
  if (( $# > 0 )); then
    REASON_DOCS_BASE_URL="$1"
  else
    printf '%s\n' "${REASON_DOCS_BASE_URL:-https://github.com/Pullwright/agent-ops/blob/main/docs/reference/reasons.md}"
  fi
}
