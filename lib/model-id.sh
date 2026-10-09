#!/usr/bin/env bash
#
# lib/model-id.sh — provider-qualified model identifiers (D12,
# docs/spec/implementation/requirements/the-script-01.md requirement 1a, issue #2131).
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
# Sourced by agent-cycle.sh, review-cycle.sh, monitor-cycle.sh,
# scripts/doctor.sh and scripts/publish-dashboard.sh. `providers_load` must be
# called once, with config's own `providers` object, before a script's first
# `resolve_model_id_into`/`resolve_model_id`/`resolve_model_provider`/`resolve_model_qualified`
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

# Populated as a side effect of every `resolve_model_id_into` call below:
# keyed by the bare id it assigned, valued by the provider that id resolved
# from (`resolve_model_provider`'s own return value for the same call). This
# is how `lib/stage-run.sh`'s `run_model_stage` (issue #2133) learns which
# substrate to launch a model on without every one of its own call sites
# having to resolve and pass a provider explicitly — "a stage runs on the
# provider its model resolves to" falls out of config load alone, since
# every model a stage ever launches first passed through
# `resolve_model_id_into` to reach the variable that names it.
#
# `resolve_model_id_into`, and not `resolve_model_id`: this map is the one
# thing about resolution that a *subshell* cannot deliver, so the form a
# caller picks decides whether the recording survives at all. See
# `resolve_model_id_into`'s own header for why, and
# `docs/spec/implementation/requirements/the-script-01.md` requirement 1a for
# the rule.
#
# Last-write-wins on a bare id two different keys both resolve to: today that
# never happens (`anthropic` is the only provider that exists), and is a
# known, acceptable narrowing for the day a second one does — see
# `lib/stage-run.sh`'s own `stage_model_substrate`.
declare -gA MODEL_PROVIDER=()

# Populated by providers_load alongside PROVIDER_SUBSTRATE. The environment
# variable the provider's adapter reads for an API key — config's own
# `credential_env`, or PROVIDER_SUBSTRATE_DEFAULT_CREDENTIAL_ENV's default for
# that provider's substrate when config does not set one. Informational
# (scripts/doctor.sh's own report, "Providers" section) — nothing here reads
# a credential through it; each substrate's adapter still reads its own
# environment variable directly (`lib/stage-run.sh`'s `claude` invocation
# reads `ANTHROPIC_API_KEY` itself, same as before this issue).
declare -gA PROVIDER_CREDENTIAL_ENV=()

# Populated by providers_load alongside PROVIDER_SUBSTRATE and
# PROVIDER_CREDENTIAL_ENV (issue #2240, D30). Keyed by provider name, valued
# by a compact JSON object `{"api": {...}, "subscription": {...}}`, each
# lane's own object carrying `weight` (integer >= 0; default 1 for `api`, 0
# for `subscription` — the fallback lane, drawn only when no weighted lane of
# its provider is open), `enabled` (boolean or `null` when unset — unset
# means "open only when it is the one the CLI would use unaided", today's
# behaviour), and the thresholds `scripts/doctor.sh`'s "Claude" section and
# the stage launcher (#2241/#2243) read: `spend_cap_usd` (0 means none,
# default 0), `spend_window_hours` (default 24), `balance_usd`,
# `balance_as_of` and `balance_floor_usd` (each `null` when unset). Every
# provider's entry carries both lanes fully defaulted, whether or not
# config.json's own `providers.<name>.lanes` names either of them, so a
# reader never has to re-apply the defaults itself. `anthropic` is
# synthesized with the all-default object whenever config does not name it
# explicitly, same as PROVIDER_SUBSTRATE above.
declare -gA PROVIDER_LANES=()

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

# Lanes ("<provider>/<lane>") with no cost measure at all (issue #2240, D30):
# the substrate reports no cost on that lane, and no statement (#2248)
# supplies one either, so no `spend_cap_usd` or `balance_floor_usd` can ever
# be enforced on it — `config_provider_errors` refuses a `lanes` block that
# sets either on a lane named here. Today: `xai/subscription` alone (#2246
# has not landed Grok Build's own adapter, and #2248 has not landed its
# statement); #2246/#2248 add to this, never remove from it.
# shellcheck disable=SC2034  # read by lib/config-schema.sh's config_provider_errors, which sources this file
declare -ga PROVIDER_LANE_NO_MEASURE=(xai/subscription)

# providers_load PROVIDERS_JSON
# Populates PROVIDER_SUBSTRATE, PROVIDER_CREDENTIAL_ENV and PROVIDER_LANES
# from config's `providers` object — a JSON object (or "{}"/"null" when
# config.json does not set the key) keyed by provider name, each value
# carrying `substrate`, optionally `credential_env`, and optionally `lanes`.
# Idempotent and safe to call more than once (a fresh engagement re-sourcing
# this file gets a fresh, empty map first). `anthropic` is synthesized with
# substrate `claude-code` and the all-default lanes object whenever config
# does not name it explicitly.
providers_load() {
  local providers_json="${1:-null}"
  PROVIDER_SUBSTRATE=()
  PROVIDER_CREDENTIAL_ENV=()
  PROVIDER_LANES=()
  local name substrate lanes_json credential_env default_env
  # lanes_json (never empty — lane_defaults always fills both lanes) comes
  # before credential_env (routinely empty) in both the jq row and this read:
  # `read` with a tab IFS collapses a run of consecutive tabs into a single
  # delimiter exactly as it does whitespace-default IFS, so an empty field
  # anywhere but last silently merges into its neighbour and shifts every
  # field after it — this field order is what keeps the one field that can
  # be empty safely last.
  while IFS=$'\t' read -r name substrate lanes_json credential_env; do
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
    PROVIDER_LANES["$name"]="$lanes_json"
  done < <(jq -r '
    def lane_defaults(n):
      {weight: (if n == "api" then 1 else 0 end), enabled: null,
       spend_cap_usd: 0, spend_window_hours: 24,
       balance_usd: null, balance_as_of: null, balance_floor_usd: null};
    (. // {}) | to_entries[] | . as $e |
    ($e.value.lanes // {}) as $lanes |
    [$e.key, ($e.value.substrate // ""),
     ({api: (lane_defaults("api") * ($lanes.api // {})),
       subscription: (lane_defaults("subscription") * ($lanes.subscription // {}))} | tojson),
     ($e.value.credential_env // "")
    ] | @tsv' \
    <<<"$providers_json" 2>/dev/null)
  if [[ -z "${PROVIDER_SUBSTRATE[anthropic]+set}" ]]; then
    PROVIDER_SUBSTRATE[anthropic]="claude-code"
    # shellcheck disable=SC2034  # read by scripts/doctor.sh, which sources this file
    PROVIDER_CREDENTIAL_ENV[anthropic]="ANTHROPIC_API_KEY"
    # shellcheck disable=SC2034  # read by scripts/doctor.sh, which sources this file
    PROVIDER_LANES[anthropic]='{"api":{"weight":1,"enabled":null,"spend_cap_usd":0,"spend_window_hours":24,"balance_usd":null,"balance_as_of":null,"balance_floor_usd":null},"subscription":{"weight":0,"enabled":null,"spend_cap_usd":0,"spend_window_hours":24,"balance_usd":null,"balance_as_of":null,"balance_floor_usd":null}}'
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

# resolve_model_id_into VAR KEY VALUE
# Assigns to the variable *named* VAR the bare model id `claude --model` (or
# a future provider's own model-selection flag) expects. An unqualified VALUE
# (including empty, which some keys use to disable a stage) passes through
# unchanged; a qualified VALUE has the qualifier stripped once
# resolve_model_provider accepts it. Leaves VAR untouched and returns 1,
# printing exactly what resolve_model_provider prints and for the same
# reasons, when it does not.
#
# Side effect (issue #2133): records MODEL_PROVIDER[<bare id>]=<provider> for
# every non-empty result, so a later `run_model_stage` call elsewhere in the
# same process can look the provider back up from the bare id alone — see
# MODEL_PROVIDER's own header comment above.
#
# **This assigning form exists because that side effect is the one thing a
# subshell cannot hand back, and the printing form below is always called in
# one.** `m="$(resolve_model_id KEY VALUE)"` runs the entire function —
# recording included — inside a command substitution, and nothing a subshell
# assigns ever reaches its parent: the bare id comes back on stdout, and the
# MODEL_PROVIDER entry naming its provider is discarded with the subshell.
# That is not a quirk of associative arrays; it is true of any assignment.
# So every site whose resolved value is later handed to `run_model_stage` or
# `metering_fields` — every stage model in agent-cycle.sh, review-cycle.sh
# and monitor-cycle.sh — must use this form, and the printing form is for a
# caller that genuinely only wants the string (scripts/doctor.sh's config
# report, scripts/publish-dashboard.sh's tier lookups, review-cycle.sh's
# startup validation, resolve_model_qualified below).
#
# VAR must not be named `__rmi_*`: bash's dynamic scoping would have this
# function's own locals shadow the caller's variable of that name, so
# `printf -v` would write to the local and the caller would see nothing.
# Nothing in this repository names a variable that way, and the prefix exists
# precisely so nothing has to think about it.
resolve_model_id_into() {
  local __rmi_var="$1" __rmi_key="$2" __rmi_value="$3" __rmi_provider __rmi_bare
  __rmi_provider="$(resolve_model_provider "$__rmi_key" "$__rmi_value")" || return 1
  case "$__rmi_value" in
    */*) __rmi_bare="${__rmi_value#*/}" ;;
    *) __rmi_bare="$__rmi_value" ;;
  esac
  # Read by lib/stage-run.sh's stage_model_substrate and lib/metering.sh's
  # metering_fields, which shellcheck cannot see from here.
  #
  # An `if` rather than the shorter `[[ … ]] && …`: unlike the printing form
  # this replaced, this function runs in its callers' own shell, under the
  # `set -euo pipefail` all three cycle scripts set, and an empty VALUE (the
  # "this stage is disabled" convention several keys use) is an ordinary
  # input here rather than an error. Bash does spare a failing AND-list that
  # is not a function's last command, but relying on that for a disabled
  # stage is a sharper edge than this shared library should carry.
  if [[ -n "$__rmi_bare" ]]; then
    # shellcheck disable=SC2034
    MODEL_PROVIDER["$__rmi_bare"]="$__rmi_provider"
  fi
  # `printf -v` rather than a nameref: it needs no bash feature this
  # codebase does not already rely on, and it cannot be fed a circular
  # reference the way `local -n` can when VAR happens to name a variable in
  # this function's own scope.
  printf -v "$__rmi_var" '%s' "$__rmi_bare"
}

# resolve_model_id KEY VALUE
# resolve_model_id_into's printing form, for a caller that wants the bare id
# and nothing else: identical resolution and identical failure, but — being
# called in a command substitution at every one of its own call sites — it
# cannot deliver the MODEL_PROVIDER recording described above. A caller whose
# value will be launched as a stage wants `resolve_model_id_into` instead.
resolve_model_id() {
  local bare=""
  resolve_model_id_into bare "$1" "$2" || return 1
  printf '%s\n' "$bare"
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

# Model-tier ordering (agent-ops#822, docs/spec/implementation/README.md
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
# naming happens to share with another's. Tiers are compared only *within*
# one provider (requirement 1c; D29, issue #2198): model_tier_below's own
# explicit provider check, below, is what enforces that — it is not, and
# cannot be, a side effect of this table's keying alone, since once a second
# provider is ranked here, a cross-provider pair's two ids are both ranked,
# just on scales nobody has ever compared, and whatever the two integers say
# would otherwise be compared as if they meant the same thing. A model this
# table has never heard of — a future release, a typo the modelId pattern
# still accepts, or a second provider's own model before its tier is added
# here — ranks unknown rather than lowest or highest, and every function
# below treats "unknown" as "cannot verify", never as "fails" or "passes":
# scripts/doctor.sh warns separately so an unranked model is never silently
# invisible to the checks that use this.
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
# True (exit 0) iff both CANDIDATE and FLOOR are ranked, they name the same
# provider, and CANDIDATE's tier is strictly below FLOOR's. False whenever
# either side is empty (an empty model id means that stage is disabled — a
# different check's business), unranked (an unranked model can never be
# placed relative to anything, so it never fails this predicate on that
# account alone), or the two providers differ (D29, issue #2198) — compared
# explicitly, before either side's rank is even read, so that ranking a
# second provider's models here never starts comparing them against the
# first provider's tiers on one integer scale nobody chose: each provider's
# own ranks are a scale ordered by that provider's own prices, never
# compared across providers, the interim rule the roadmap's open question on
# cross-provider tier ordering records until the question is decided. Takes
# qualified ids, same as model_tier_rank.
model_tier_below() {
  local candidate="${1:-}" floor="${2:-}" cr fr
  [[ -n "$candidate" && -n "$floor" ]] || return 1
  [[ "${candidate%%/*}" == "${floor%%/*}" ]] || return 1
  cr="$(model_tier_rank "$candidate")" || return 1
  fr="$(model_tier_rank "$floor")" || return 1
  (( cr < fr ))
}
