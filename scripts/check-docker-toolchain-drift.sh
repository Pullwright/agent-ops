#!/usr/bin/env bash
#
# scripts/check-docker-toolchain-drift.sh — compare the four hand-pinned
# toolchain `ARG` defaults in deploy/docker/Dockerfile against their own
# upstream release feed, and file (or update) an ordinary GitHub issue when
# one has fallen behind (issue #2708, following the decide-tactical decision
# on that issue: option 1, drift-report shape, modelled on
# scripts/check-graphql-drift.sh).
#
# The four pins, and the feed each is checked against — not Dependabot's
# ecosystems (#2697/#2706 already cover the `docker`/`docker-compose`/
# `github-actions` manifests; none of these four is visible to any of them):
#
#   SUPERCRONIC_VERSION    GitHub releases, aptible/supercronic
#   SHELLCHECK_VERSION     GitHub releases, koalaman/shellcheck
#   CLAUDE_CODE_VERSION    npm registry,    @anthropic-ai/claude-code
#   GROK_BUILD_VERSION     npm registry,    @xai-official/grok
#
# This never bumps a pin and never opens a pull request — only ever an
# issue, naming what drifted, for the pipeline's own ordinary selection to
# pick up as implementer work afterwards. A drift-fixing PR was considered
# and rejected in the decision above: the two GitHub-released pins each sit
# beside two architecture-specific checksums (SUPERCRONIC_SHA1SUM_{AMD64,
# ARM64}, SHELLCHECK_SHA256_{AMD64,ARM64}), so a bump moves three values per
# pin, not one, which is implementer work, not safe template substitution in
# a cron job.
#
# Filing goes through lib/tech-debt-file.sh's techdebt_file_debt, the same
# dedup-or-comment helper every other deferred-work filer in this repository
# uses: a stable title is what lets a second scheduled run recognise the
# issue a prior run already opened and comment on it instead of filing a
# duplicate, which is also how "updates the existing open one" is satisfied
# without this script tracking any state of its own between runs. Labelled
# pw::type:tech-debt, the same label scripts/gather-tech-debt.sh already
# serves from. The workflow's own GH_TOKEN (.github/workflows/
# docker-toolchain-drift.yml's `secrets.GITHUB_TOKEN`) is passed through as
# techdebt_file_debt's TOKEN argument: a GitHub Actions runner carries no
# stored `gh auth login` identity, so the tokenless default every other
# caller's Enabler path relies on would leave every dedup/comment/create call
# inside the filing helper unauthenticated here.
#
# lib/github-limit.sh is sourced ahead of it for the same reason
# check-graphql-drift.sh sources it: this shadows `gh` for every call below,
# including the two GitHub releases lookups and techdebt_file_debt's own
# filing call, so a rate-limit refusal on any of them is waited out rather
# than read as "could not check". The filing call only gets that coverage
# because it carries GH_TOKEN as above — `_techdebt_gh` (lib/tech-debt-file.sh)
# runs a tokenless call through `env -u GH_TOKEN gh`, which execs the `gh`
# binary directly and bypasses this shadow.
#
# Usage:
#   ./scripts/check-docker-toolchain-drift.sh           # check, file on drift
#   ./scripts/check-docker-toolchain-drift.sh --list    # print the four pins
#                                                        # and upstream versions,
#                                                        # file nothing
#
# Environment: DOCKER_DRIFT_DOCKERFILE overrides the Dockerfile path and
# DOCKER_DRIFT_REPO the repository filed against (both the test uses).
#
# Exit 0: every pin's upstream version was resolved; found none or filed it.
# Exit 1: at least one pin had drifted but the filing itself failed.
# Exit 2: at least one pin's upstream version could not be resolved at all —
#   never reported as clean, and never as drift, same convention as
#   check-graphql-drift.sh's own exit contract. `--list` never returns 1: an
#   unresolved pin is printed as `?` rather than failing the listing.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"
# shellcheck source=lib/tech-debt-file.sh
. "$SCRIPT_DIR/lib/tech-debt-file.sh"

DOCKERFILE="${DOCKER_DRIFT_DOCKERFILE:-$SCRIPT_DIR/deploy/docker/Dockerfile}"
REPO="${DOCKER_DRIFT_REPO:-Pullwright/agent-ops}"

usage() {
  awk 'NR >= 3 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"
  exit "${1:-0}"
}

list_only=0
for arg in "$@"; do
  case "$arg" in
    -h|--help) usage 0 ;;
    --list)    list_only=1 ;;
    *)         printf 'unknown argument: %s\n' "$arg" >&2; usage 2 ;;
  esac
done

[[ -f "$DOCKERFILE" ]] || { printf '::error::%s does not exist — nothing to check\n' "$DOCKERFILE" >&2; exit 2; }

# pin_value NAME — the ARG's own default from the Dockerfile, or empty.
pin_value() {
  sed -n "s/^ARG $1=\\(.*\\)\$/\\1/p" "$DOCKERFILE" | head -n1
}

# pin_line NAME — the 1-based line the ARG sits on, for the issue body.
pin_line() {
  grep -n "^ARG $1=" "$DOCKERFILE" | head -n1 | cut -d: -f1
}

# github_latest_tag OWNER/REPO — the latest release's tag name, or empty.
github_latest_tag() {
  gh api "repos/$1/releases/latest" --jq '.tag_name' 2>/dev/null || true
}

# npm_latest_version PACKAGE — the npm `latest` dist-tag's version, or empty.
# The scoped package's own slash is percent-encoded, which is npm's own
# documented form for a scoped package's registry URL.
npm_latest_version() {
  local encoded="${1/\//%2f}"
  curl -fsSL "https://registry.npmjs.org/${encoded}/latest" 2>/dev/null \
    | jq -r '.version // empty' 2>/dev/null || true
}

# normalize_version V — V with a single leading "v" stripped, so
# "v0.2.47"/"0.2.47" compare equal regardless of which form either side uses.
normalize_version() {
  local v="$1"
  printf '%s' "${v#v}"
}

# Name, upstream resolver, and upstream kind/ref — one row per pin, in the
# order the issue #2708 spec itself lists them.
names=(SUPERCRONIC_VERSION SHELLCHECK_VERSION CLAUDE_CODE_VERSION GROK_BUILD_VERSION)
kinds=(github github npm npm)
refs=(aptible/supercronic koalaman/shellcheck @anthropic-ai/claude-code @xai-official/grok)

unable=0
drifted_lines=()
checksum_note_needed=0

for i in "${!names[@]}"; do
  name="${names[$i]}"
  kind="${kinds[$i]}"
  ref="${refs[$i]}"
  current="$(pin_value "$name")"
  if [[ -z "$current" ]]; then
    printf '::error::%s not found in %s — refusing to report no drift\n' "$name" "$DOCKERFILE" >&2
    unable=1
    (( list_only )) && printf '%s\t?\t?\n' "$name"
    continue
  fi

  if [[ "$kind" == github ]]; then
    latest="$(github_latest_tag "$ref")"
  else
    latest="$(npm_latest_version "$ref")"
  fi

  if [[ -z "$latest" ]]; then
    printf '::error::could not resolve %s''s upstream version from %s (%s)\n' "$name" "$ref" "$kind" >&2
    unable=1
    (( list_only )) && printf '%s\t%s\t?\n' "$name" "$current"
    continue
  fi

  if (( list_only )); then
    printf '%s\t%s\t%s\n' "$name" "$current" "$latest"
    continue
  fi

  if [[ "$(normalize_version "$current")" != "$(normalize_version "$latest")" ]]; then
    drifted_lines+=("- \`$name\`: pinned \`$current\`, upstream \`$latest\` (deploy/docker/Dockerfile:$(pin_line "$name"), $ref)")
    [[ "$kind" == github ]] && checksum_note_needed=1
  fi
done

(( list_only )) && exit 0

if (( unable )); then
  exit 2
fi

if (( ${#drifted_lines[@]} == 0 )); then
  printf 'all four hand-pinned toolchain versions match upstream; no drift\n'
  exit 0
fi

body_file="$(mktemp)" || exit 1
trap 'rm -f "$body_file"' EXIT
{
  # shellcheck disable=SC2016  # backticks here are Markdown, not command substitution — single-quoted deliberately
  printf 'The scheduled docker-toolchain-drift check found the following hand-pinned toolchain `ARG` default(s) in `deploy/docker/Dockerfile` behind their own upstream release feed:\n\n'
  printf '%s\n' "${drifted_lines[@]}"
  printf '\n'
  if (( checksum_note_needed )); then
    # shellcheck disable=SC2016  # backticks here are Markdown, not command substitution — single-quoted deliberately
    printf 'Bumping a GitHub-released pin above (`SUPERCRONIC_VERSION`/`SHELLCHECK_VERSION`) also needs its two architecture-specific checksums (`*_SHA1SUM_{AMD64,ARM64}`/`*_SHA256_{AMD64,ARM64}`) recomputed — three values change, not one.\n\n'
  fi
  printf 'Noticed by the scheduled run, not a pull request — this check never bumps a pin itself; see issue #2708 for the decision that this is reported as an issue rather than fixed automatically.\n'
} > "$body_file"

provenance="Filed by the scheduled docker-toolchain-drift check (scripts/check-docker-toolchain-drift.sh), run ${GITHUB_RUN_ID:+${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-$REPO}/actions/runs/$GITHUB_RUN_ID}."

result="$(techdebt_file_debt "$REPO" "Docker toolchain pins have drifted from upstream" \
  "$(cat "$body_file")" "$provenance" "${GH_TOKEN:-}")" || result=""

if [[ -z "$result" ]]; then
  printf '::error::could not file or update the drift issue in %s\n' "$REPO" >&2
  exit 1
fi

printf 'drift reported: %s\n' "$result"
exit 0
