#!/usr/bin/env bash
#
# lib/model-id.sh — provider-qualified model identifiers (D12,
# docs/IMPLEMENTATION-PIPELINE-SPEC.md requirement 1a, issue #2131).
#
# Every model key in config.json (coordinator_model, implementer_model_*,
# reviewer_model_*, enabler_model, repository_review.defaults.model and its
# per-repo overrides) accepts either a bare model
# id (`claude-sonnet-5`) or one qualified with a provider prefix
# (`anthropic/claude-sonnet-5`, or `<name>/<id>` for a provider config.json's
# own `providers` block configures). `anthropic` is always accepted, with
# substrate `claude-code`, whether or not `providers` names it explicitly
# (D12: no existing config.json needs a `providers.anthropic` entry to keep
# resolving as it always has). A qualifier naming any other provider fails
# fast here, at config read time, rather than reaching `claude --model`
# mid-cycle — either because config.json's `providers` does not configure
# that name, or because it configures a `substrate` this node has no adapter
# for (`PROVIDER_SUBSTRATE_INSTALLED` below; after this issue, `claude-code`
# alone, so the second case cannot yet be reached through a schema-valid
# config — it is forward groundwork for #2133/#2134).
#
# Sourced by agent-cycle.sh and review-cycle.sh. `providers_load` must be
# called once, with config's own `providers` object, before either script's
# first `resolve_model_id`/`resolve_model_provider`/`resolve_model_qualified`
# call needs to see a provider beyond the implicit `anthropic` — the same
# startup position requirement 1b's schema gate occupies. A caller that never
# calls it (every test in test/model-id.test.sh included) still resolves
# bare and `anthropic/`-qualified ids exactly as before this issue, since
# `anthropic` needs no entry in `PROVIDER_SUBSTRATE` to be accepted.

# Populated by providers_load. Keyed by provider name, valued by that
# provider's configured substrate. Read directly by resolve_model_provider;
# empty (no providers_load call yet) is not a special case there, since
# `anthropic` is checked before this map ever is.
declare -gA PROVIDER_SUBSTRATE=()

# Populated by providers_load alongside PROVIDER_SUBSTRATE. The environment
# variable the provider's adapter reads for an API key — config's own
# `credential_env`, or PROVIDER_SUBSTRATE_DEFAULT_CREDENTIAL_ENV's default for
# that provider's substrate when config does not set one. Informational
# (scripts/doctor.sh's own report, "Providers" section) — nothing here reads
# a credential through it; each substrate's adapter still reads its own
# environment variable directly (`lib/stage-run.sh`'s `claude` invocation
# reads `ANTHROPIC_API_KEY` itself, same as before this issue).
declare -gA PROVIDER_CREDENTIAL_ENV=()

# The credential_env default for a substrate with no explicit one configured.
declare -gA PROVIDER_SUBSTRATE_DEFAULT_CREDENTIAL_ENV=(
  [claude-code]=ANTHROPIC_API_KEY
)

# Substrates this codebase has an adapter for, and so the full enum
# config_provider_errors validates `providers.*.substrate` against — the two
# concepts are the same list today (there is no partial-install concept yet:
# an adapter either exists in this codebase or it does not). After this
# issue, `claude-code` alone; #2133/#2134 add to this, never remove from it.
declare -ga PROVIDER_SUBSTRATE_INSTALLED=(claude-code)

# providers_load PROVIDERS_JSON
# Populates PROVIDER_SUBSTRATE and PROVIDER_CREDENTIAL_ENV from config's
# `providers` object — a JSON object (or "{}"/"null" when config.json does
# not set the key) keyed by provider name, each value carrying `substrate`
# and optionally `credential_env`. Idempotent and safe to call more than
# once (a fresh engagement re-sourcing this file gets a fresh, empty map
# first). `anthropic` is synthesized with substrate `claude-code` whenever
# config does not name it explicitly.
providers_load() {
  local providers_json="${1:-null}"
  PROVIDER_SUBSTRATE=()
  PROVIDER_CREDENTIAL_ENV=()
  local name substrate credential_env default_env
  while IFS=$'\t' read -r name substrate credential_env; do
    [[ -n "$name" ]] || continue
    PROVIDER_SUBSTRATE["$name"]="$substrate"
    # An entry carrying no `substrate` at all is a config fault, but it is
    # `config_provider_errors`' fault to report, by name, one call *later*
    # than this one — every caller loads the seam before running that guard,
    # since the checks after it need the seam populated. So this has to
    # survive a malformed entry rather than abort on it: the substrate is the
    # default table's own subscript, and bash rejects an empty
    # associative-array subscript outright ("bad array subscript", the same
    # trap model_tier_rank guards below), which under the `set -e` every
    # cycle script runs with would kill the script here — before its own
    # guard could name the offending key.
    default_env=""
    if [[ -n "$substrate" ]]; then
      default_env="${PROVIDER_SUBSTRATE_DEFAULT_CREDENTIAL_ENV[$substrate]:-}"
    fi
    PROVIDER_CREDENTIAL_ENV["$name"]="${credential_env:-$default_env}"
  done < <(jq -r '(. // {}) | to_entries[] | [.key, (.value.substrate // ""), (.value.credential_env // "")] | @tsv' \
    <<<"$providers_json" 2>/dev/null)
  if [[ -z "${PROVIDER_SUBSTRATE[anthropic]+set}" ]]; then
    PROVIDER_SUBSTRATE[anthropic]="claude-code"
    # shellcheck disable=SC2034  # read by scripts/doctor.sh, which sources this file
    PROVIDER_CREDENTIAL_ENV[anthropic]="ANTHROPIC_API_KEY"
  fi
}

# provider_substrate_installed SUBSTRATE
# True (exit 0) iff this node has an adapter for SUBSTRATE
# (PROVIDER_SUBSTRATE_INSTALLED).
provider_substrate_installed() {
  local want="$1" s
  for s in "${PROVIDER_SUBSTRATE_INSTALLED[@]}"; do
    [[ "$s" == "$want" ]] && return 0
  done
  return 1
}

# resolve_model_provider KEY VALUE
# Prints the provider name VALUE resolves to — "anthropic" for a bare id or
# an `anthropic/`-qualified one (whether or not `providers_load` has run),
# otherwise the named qualifier iff `providers_load` has configured it and
# its substrate has an adapter on this node — or prints nothing for an empty
# VALUE (the "this stage is disabled" convention several keys use). Prints a
# message naming KEY and the offending provider or substrate to stderr and
# returns 1 for a qualifier naming a provider config.json's `providers` does
# not configure, or one configured with a substrate this node has no
# adapter for.
resolve_model_provider() {
  local key="$1" value="$2" provider substrate
  case "$value" in
    "")
      printf '\n'
      return 0
      ;;
    */*)
      provider="${value%%/*}"
      ;;
    *)
      provider="anthropic"
      ;;
  esac
  if [[ -n "${PROVIDER_SUBSTRATE[$provider]+set}" ]]; then
    substrate="${PROVIDER_SUBSTRATE[$provider]}"
  elif [[ "$provider" == "anthropic" ]]; then
    substrate="claude-code"
  else
    # Prefixed with the library's own name, not a script's: review-cycle.sh
    # sources this too, and an error blaming agent-cycle for
    # `repository_review.defaults.model` sends the operator to the wrong
    # script. Matches lib/toggle.sh.
    echo "model-id: $key: provider '$provider' is not configured (add a providers.$provider entry to config.json) — got '$value'" >&2
    return 1
  fi
  if provider_substrate_installed "$substrate"; then
    printf '%s\n' "$provider"
  else
    echo "model-id: $key: provider '$provider' is configured with substrate '$substrate', which this node has no adapter for — got '$value'" >&2
    return 1
  fi
}

# resolve_model_id KEY VALUE
# Prints the bare model id `claude --model` (or a future provider's own
# model-selection flag) expects. An unqualified VALUE (including empty,
# which some keys use to disable a stage) passes through unchanged; a
# qualified VALUE has the qualifier stripped once resolve_model_provider
# accepts it. Prints nothing and returns 1, exactly as resolve_model_provider
# does and for the same reasons, when it does not.
resolve_model_id() {
  local key="$1" value="$2"
  resolve_model_provider "$key" "$value" >/dev/null || return 1
  case "$value" in
    */*) printf '%s\n' "${value#*/}" ;;
    *) printf '%s\n' "$value" ;;
  esac
}

# resolve_model_qualified KEY VALUE
# Prints VALUE fully qualified by the provider it resolves to —
# "anthropic/claude-sonnet-5" for a bare id or an already-qualified one of
# that shape, "<provider>/<bare-id>" for any other configured provider — or
# nothing for an empty VALUE. This is the id MODEL_TIER_RANK is keyed by;
# resolve_model_id's own bare return value is what a provider's CLI wants,
# never this. Fails exactly as resolve_model_id does, and for the same
# reason, since it calls the same resolution.
resolve_model_qualified() {
  local key="$1" value="$2" provider bare
  [[ -n "$value" ]] || { printf '\n'; return 0; }
  provider="$(resolve_model_provider "$key" "$value")" || return 1
  bare="$(resolve_model_id "$key" "$value")" || return 1
  printf '%s/%s\n' "$provider" "$bare"
}

# Model-tier ordering (agent-ops#822, docs/IMPLEMENTATION-PIPELINE-SPEC.md
# requirement 1c). #815 (fixed by #819) and #821 both trace to the same root
# cause: nothing stopped a cheaper model from authoring a work order
# specification a more capable Implementer then executed. This table is what
# makes "cheaper" and "more capable" checkable in code rather than by
# convention — the fleet's four currently configured Claude model ids, ranked
# by capability (confirmed by Anthropic's own relative pricing: haiku <
# sonnet < opus < fable), each keyed by its fully-qualified id
# (resolve_model_qualified's own return shape) rather than the bare one
# resolve_model_id returns — issue #2131, so that a pair naming models from
# two different providers never collides on a bare id one provider's own
# naming happens to share with another's, and so requirement 1c's own checks
# below compare tiers only *within* one provider by construction: a
# cross-provider pair's own qualified ids are simply two different keys here,
# neither of which the other provider's rank can ever satisfy, so it ranks
# unknown — the same "cannot verify" every other unranked model already
# gets, never itself a floor violation. A model this table has never heard
# of — a future release, a typo the modelId pattern still accepts, or a
# second provider's own model before its tier is added here — ranks unknown
# rather than lowest or highest, and every function below treats "unknown" as
# "cannot verify", never as "fails" or "passes": scripts/doctor.sh warns
# separately so an unranked model is never silently invisible to the checks
# that use this.
declare -gA MODEL_TIER_RANK=(
  [anthropic/claude-haiku-4-5-20251001]=1
  [anthropic/claude-sonnet-5]=2
  [anthropic/claude-opus-5]=3
  [anthropic/claude-fable-5]=4
)

# model_tier_rank QUALIFIED_MODEL_ID
# Prints QUALIFIED_MODEL_ID's integer tier rank (higher is more capable) and
# returns 0, or prints nothing and returns 1 for a model MODEL_TIER_RANK does
# not know — an empty or absent QUALIFIED_MODEL_ID included, since "not
# ranked" is exactly what an unset `modelIdOrEmpty` key is. That empty case
# is guarded explicitly rather than left to the lookup: bash rejects an empty
# associative-array subscript outright ("bad array subscript"), which under
# `set -e` aborts the calling script instead of returning the 1 this
# promises. Both callers below already screen empties before they get here,
# but this is shared library code and the next caller may not.
# Takes an already-resolved qualified id (resolve_model_qualified's own
# "<provider>/<bare-id>" shape), never the bare id resolve_model_id returns —
# every caller here builds one before calling in.
model_tier_rank() {
  local id="${1:-}"
  [[ -n "$id" ]] || return 1
  if [[ -n "${MODEL_TIER_RANK[$id]+set}" ]]; then
    printf '%s\n' "${MODEL_TIER_RANK[$id]}"
  else
    return 1
  fi
}

# model_tier_known QUALIFIED_MODEL_ID
# True (exit 0) iff QUALIFIED_MODEL_ID is empty (the "this stage is
# disabled" value every `modelIdOrEmpty` key uses) or ranked in
# MODEL_TIER_RANK. Takes a qualified id, same as model_tier_rank.
model_tier_known() {
  local id="${1:-}"
  [[ -z "$id" ]] && return 0
  model_tier_rank "$id" >/dev/null 2>&1
}

# model_tier_below CANDIDATE FLOOR
# True (exit 0) iff both CANDIDATE and FLOOR are ranked and CANDIDATE's tier
# is strictly below FLOOR's. False whenever either side is empty (an empty
# model id means that stage is disabled — a different check's business) or
# unranked (an unranked model can never be placed relative to anything, so it
# never fails this predicate on that account alone) — including a
# cross-provider pair, which ranks unknown on each side by construction
# (MODEL_TIER_RANK's own qualified keying above) rather than ever being
# compared. Takes qualified ids, same as model_tier_rank.
model_tier_below() {
  local candidate="${1:-}" floor="${2:-}" cr fr
  [[ -n "$candidate" && -n "$floor" ]] || return 1
  cr="$(model_tier_rank "$candidate")" || return 1
  fr="$(model_tier_rank "$floor")" || return 1
  (( cr < fr ))
}
