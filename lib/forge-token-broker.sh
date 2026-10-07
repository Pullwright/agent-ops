#!/usr/bin/env bash
#
# lib/forge-token-broker.sh — the forge authoring token a stage may have, and
# nothing else (requirement 45e of
# docs/spec/implementation/requirements/every-stage.md).
#
# A stage runs as its own Unix user, which cannot read either GitHub App's
# private key, the Script's environment, or the token cache under /dev/shm.
# Yet a stage still authors: it pushes, comments and opens pull requests, and
# D25 has every such act mint an installation token immediately before the
# call (lib/gh-shim.sh's `gh_shim_resolve_token`, and git's credential helper
# through the same shim). This file is the one place that minting happens on
# a stage's behalf.
#
# The stage reaches it through exactly one sudoers rule
# (deploy/docker/sudoers-agent-ops): the stage user may run
# /usr/local/libexec/agent-ops/forge-token, as the Script's user, with one
# argument. That entry point (deploy/docker/forge-token.sh) sources this file
# and calls `forge_token_broker_main`. sudo resets the environment, so nothing
# the stage sets reaches the mint: the App's identity is read from the
# environment of pid 1 — the scheduler service the Script runs under, whose
# environment only the Script's user and root can read and nobody can
# rewrite — and only from the variables named in FORGE_TOKEN_BROKER_ENV.
#
# What it will hand out, by design:
#
#   - With the forge authoring App configured, an installation token for the
#     owner asked about, or for the default installation when the map does
#     not name that owner (enough to read public repositories, refused at
#     write time elsewhere). A failed mint is a failure: the stage gets no
#     token. It is never handed `PW_GH_DEGRADE_TOKEN`, the personal-token
#     fallback the Script itself keeps under D25.
#   - With no authoring App configured at all, the installation's own
#     `GH_TOKEN` (or the degrade token, which then holds it), because that is
#     the only credential such an installation authors with.
#   - Never anything minted from the Approver App's key, which is not among
#     the variables read.
#
# Output contract: the token on the first line and the identity tag the
# shim keys its cache and budget by (`app-<app id>-<installation id>`, or an
# empty line for a token that is not an App's) on the second. Exit 0 with a
# token, 1 when there is none to give, 2 on a malformed request.

# shellcheck source=lib/author-token.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/author-token.sh"

# The variables read from the trusted environment, and no others. The proxy
# variables are here because the mint itself is an HTTPS call that must pass
# the node's egress fence like any other.
FORGE_TOKEN_BROKER_ENV=(
  PULLWRIGHT_AUTHOR_APP_ID
  PULLWRIGHT_AUTHOR_INSTALLATION_ID
  PULLWRIGHT_AUTHOR_INSTALLATION_IDS
  PULLWRIGHT_AUTHOR_PRIVATE_KEY_PATH
  PW_GH_DEGRADE_TOKEN
  GH_TOKEN
  HTTPS_PROXY HTTP_PROXY NO_PROXY
  https_proxy http_proxy no_proxy
)

# forge_token_broker_owner_valid OWNER
# True for an empty owner (the default installation) or a GitHub account
# name. Anything else is refused before it reaches a lookup or a log line.
forge_token_broker_owner_valid() {
  [[ -z "${1:-}" || "$1" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,38}$ ]]
}

# forge_token_broker_load_env ENVIRON_FILE
# Clear every variable in FORGE_TOKEN_BROKER_ENV, then export each one that
# ENVIRON_FILE (NUL-separated NAME=value records, the format of
# /proc/<pid>/environ) sets. Returns 1 when the file cannot be read, which
# leaves every one of them unset.
forge_token_broker_load_env() {
  local file="$1" record name allowed
  for name in "${FORGE_TOKEN_BROKER_ENV[@]}"; do
    unset "$name"
  done
  [[ -r "$file" ]] || return 1
  while IFS= read -r -d '' record; do
    name="${record%%=*}"
    for allowed in "${FORGE_TOKEN_BROKER_ENV[@]}"; do
      if [[ "$name" == "$allowed" ]]; then
        export "$name=${record#*=}"
        break
      fi
    done
  done <"$file"
  return 0
}

# forge_token_broker_main ENVIRON_FILE OWNER
# Print a token for OWNER under the contract in this file's header.
forge_token_broker_main() {
  local environ_file="$1" owner="${2:-}" token installation_id tag=""
  if ! forge_token_broker_owner_valid "$owner"; then
    printf 'forge-token: refusing a malformed owner\n' >&2
    return 2
  fi
  if ! forge_token_broker_load_env "$environ_file"; then
    printf 'forge-token: cannot read the scheduler environment\n' >&2
    return 1
  fi
  # shellcheck disable=SC2119 # "is this identity configured at all"
  if author_token_credential_present; then
    token="$(author_token_get "$(date +%s)" "$owner" 2>/dev/null)" || token=""
    if [[ -z "$token" ]]; then
      printf 'forge-token: the authoring App could not mint a token\n' >&2
      return 1
    fi
    installation_id="$(author_token_installation_for_owner "$owner" 2>/dev/null)" || installation_id=""
    if [[ "${PULLWRIGHT_AUTHOR_APP_ID:-}" =~ ^[0-9]+$ && "$installation_id" =~ ^[0-9]+$ ]]; then
      tag="app-${PULLWRIGHT_AUTHOR_APP_ID}-${installation_id}"
    fi
    printf '%s\n%s\n' "$token" "$tag"
    return 0
  fi
  token="${GH_TOKEN:-${PW_GH_DEGRADE_TOKEN:-}}"
  if [[ -z "$token" ]]; then
    printf 'forge-token: this node has no forge credential\n' >&2
    return 1
  fi
  printf '%s\n\n' "$token"
}
