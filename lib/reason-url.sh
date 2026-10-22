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

# The one place the base is configured (issue #2098's third acceptance
# criterion): the GitHub address of the catalogue today, the site's own
# address once one exists. Every function below reads this rather than
# repeating the literal, so there is no second copy to leave behind —
# `REASON_DOCS_BASE_URL` overrides it for a caller that needs to point
# somewhere else (a test, a fork's own site).
REASON_DOCS_BASE_URL_DEFAULT='https://github.com/Pullwright/agent-ops/blob/main/docs/reference/reasons.md'

# reason_docs_base_url [NEW_BASE]
# Get or set the base URL for reason documentation.
# shellcheck disable=SC2120  # NEW_BASE is the setter form; every in-repo caller reads.
reason_docs_base_url() {
  if (( $# > 0 )); then
    REASON_DOCS_BASE_URL="$1"
  else
    printf '%s\n' "${REASON_DOCS_BASE_URL:-$REASON_DOCS_BASE_URL_DEFAULT}"
  fi
}

# Build a URL to a reason code's documentation entry
# reason_code_url CODE -> URL
#
# The fragment is the GitHub anchor of the entry's own `### `<code>``
# heading: GitHub lowercases the heading text, drops the backticks and
# every other non-alphanumeric that is not a space or hyphen, and turns
# spaces into hyphens — which for a code already of the form
# `[a-z0-9-]+` is the code itself.
reason_code_url() {
  local code="$1"
  # shellcheck disable=SC2119  # the getter form is what is wanted here.
  printf '%s#%s' "$(reason_docs_base_url)" \
    "$(printf '%s' "$code" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]//g')"
}
