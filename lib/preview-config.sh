#!/usr/bin/env bash
#
# lib/preview-config.sh — resolves a repository's `preview` config block
# (D19 Phase 1, agent-ops#586, requirement 24a).
#
# Unlike `merge_autonomy`/`escalation_autonomy` and their neighbours, `preview`
# has no top-level fleet-wide key to fall back to: a preview arrangement is
# inherently repository-specific (one deployment project per repository), so
# there is nothing above a repo's own `repos[].preview` entry to inherit from.
# A repository that carries none of it — the common case for a repository with
# no preview deployment at all — resolves to `{"provider": "none"}`, which the
# Implementer's and Reviewer's prompts (`prompts/implementer.md` step 4a,
# `prompts/reviewer.md`'s own preview check) both read as "skip this step
# entirely, and report nothing about it".
#
# `config_defaults` (lib/config-schema.sh) already synthesises this shape for
# every repo entry — including one that names no `preview` key at all — since
# its generic `fill` walks every schema property with a `default`, `preview`'s
# own `provider` among them. `preview_config_for_repo` below only has to find
# the right repo entry and fall back to the literal default in the one case
# `config_defaults` cannot cover: a repo not present in `.repos[]` at all
# (never expected of a genuinely selected work order, but the fallback keeps
# this function pure rather than assuming a caller always passes a defaulted
# config for a repo that is actually configured).

# preview_config_for_repo CONFIG_JSON SLUG
# Prints the resolved `preview` object for SLUG — CONFIG_JSON's own
# `repos[].preview` entry when present (ordinarily already schema-defaulted by
# config_defaults), else the bare `{"provider": "none"}` fallback.
preview_config_for_repo() {
  local config_json="$1" slug="$2" resolved
  resolved="$(jq -c --arg slug "$slug" \
    '(.repos // [])[] | select(.slug == $slug) | .preview // empty' \
    <<<"$config_json" 2>/dev/null | head -1)"
  if [[ -n "$resolved" && "$resolved" != "null" ]]; then
    printf '%s' "$resolved"
    return 0
  fi
  printf '{"provider":"none"}'
}

# preview_config_export_vercel_credentials PREVIEW_JSON
# `scripts/preview-deploy.sh` still reads exactly two fixed environment
# variable names, `VERCEL_AUTOMATION_BYPASS_SECRET` and `VERCEL_TOKEN` — the
# script itself is unchanged by this item (D19's "served"/"rendered" tiers are
# separate work; this one is the configuration surface only). What PREVIEW_JSON's
# `vercel.bypass_secret_env`/`vercel.token_env` name is *where the node keeps
# the secret*, which may differ from those two fixed names once a second
# Vercel-deployed repository needs its own; this function is the one place
# that gap is closed, by exporting the fixed names the script reads from
# whichever variable the config actually points at, immediately before the
# Implementer and Reviewer stages run. A schema `pattern` already restricts
# both config values to a bare shell identifier (config.schema.json), so the
# indirection below (`${!name}`) never expands anything but a plain variable
# reference.
#
# A no-op, byte-for-byte, for every installation that has not set either key —
# the default resolves to the same two fixed names, so this exports each
# variable to its own current value. Silent when `provider` is not `"vercel"`:
# nothing here is read unless a preview step actually runs.
preview_config_export_vercel_credentials() {
  local preview_json="$1" provider bypass_name token_name
  provider="$(jq -r '.provider // "none"' <<<"$preview_json" 2>/dev/null)"
  [[ "$provider" == "vercel" ]] || return 0
  bypass_name="$(jq -r '.vercel.bypass_secret_env // "VERCEL_AUTOMATION_BYPASS_SECRET"' <<<"$preview_json" 2>/dev/null)"
  token_name="$(jq -r '.vercel.token_env // "VERCEL_TOKEN"' <<<"$preview_json" 2>/dev/null)"
  [[ "$bypass_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && export VERCEL_AUTOMATION_BYPASS_SECRET="${!bypass_name:-}"
  [[ "$token_name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && export VERCEL_TOKEN="${!token_name:-}"
}
