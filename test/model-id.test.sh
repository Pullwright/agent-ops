#!/usr/bin/env bash
#
# test/model-id.test.sh — self-contained regression test for
# lib/model-id.sh (docs/spec/implementation/requirements requirement 1a).
#
# No test framework is used (none exists elsewhere in this repo); this is a
# plain bash script with hand-rolled assertions. Run it directly:
#
#   ./test/model-id.test.sh
#
# Exit status is 0 iff every assertion passed.

# Version 0.10 of the linter traces this file's control flow to the end of a
# helper that never returns to it, and concludes the assertion helpers below are
# unreachable. They are reached — from inside the command substitutions the
# assertions are written as, which is the "invoked indirectly" case SC2317
# itself names.
# shellcheck disable=SC2317

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/model-id.sh
. "$SCRIPT_DIR/lib/model-id.sh"

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

assert_true() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n' "$desc"
    failures=$(( failures + 1 ))
  fi
}

assert_false() {
  local desc="$1"; shift
  if ! "$@" >/dev/null 2>&1; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n' "$desc"
    failures=$(( failures + 1 ))
  fi
}

# --- A bare id is unchanged, and full backward compatibility means bare ids
#     never go near the provider check. ---
assert_eq "a bare id passes through unchanged" "claude-sonnet-5" \
  "$(resolve_model_id coordinator_model "claude-sonnet-5")"
assert_eq "a bare id with digits and dashes passes through unchanged" \
  "claude-haiku-4-5-20251001" \
  "$(resolve_model_id implementer_model_trivial "claude-haiku-4-5-20251001")"

# --- An `anthropic/`-qualified id is accepted and stripped to the bare id
#     `claude --model` expects. ---
assert_eq "an anthropic/-qualified id is stripped to its bare id" "claude-sonnet-5" \
  "$(resolve_model_id implementer_model_default "anthropic/claude-sonnet-5")"

# --- Empty stays empty: reviewer_model_complex and enabler_model both use an
#     empty string to switch a stage/escalation off, and that must survive
#     resolution untouched. ---
assert_eq "an empty value (disables a stage) passes through unchanged" "" \
  "$(resolve_model_id enabler_model "")"

# --- A non-anthropic qualifier is the fail-fast case: it must not print a
#     value, and it must fail, so a caller assigning the result under `set -e`
#     aborts rather than ever handing the qualified string to `claude --model`. ---
assert_false "a non-anthropic qualifier fails" \
  resolve_model_id reviewer_model_default "openai/gpt-5"
assert_eq "a non-anthropic qualifier prints nothing on stdout" "" \
  "$(resolve_model_id reviewer_model_default "openai/gpt-5" 2>/dev/null)"

err="$(resolve_model_id enabler_model "openai/gpt-5" 2>&1 >/dev/null)"
case "$err" in
  *"enabler_model"*"openai"*) printf 'ok   - %s\n' "the error names the offending key and provider" ;;
  *)
    printf 'FAIL - the error names the offending key and provider\n     actual: %s\n' "$err"
    failures=$(( failures + 1 ))
    ;;
esac

# --- Exercised in the same caller context production code uses: an
#     assignment under `set -euo pipefail` must abort the script on a
#     rejected qualifier, exactly like a real cfg read that fails validation
#     (the failure mode a plain `assert_false` above cannot observe, since a
#     bare function call is not inside an assignment). ---
abort_probe="$(bash -euo pipefail -c '
  source "'"$SCRIPT_DIR"'/lib/model-id.sh"
  echo before
  bad="$(resolve_model_id coordinator_model "openai/gpt-5")"
  echo "unreachable: $bad"
' 2>/dev/null || true)"
assert_eq "a rejected qualifier aborts the script when assigned under set -e" \
  "before" "$abort_probe"

# --- Model-tier ordering (requirement 1c; agent-ops#822): one capability
#     scale spanning every provider (D31, issue #2445) — the fleet's four
#     currently configured Claude models, ranked haiku < sonnet < opus <
#     fable, and xAI's three Grok models placed on the same scale rather than
#     a scale of their own. MODEL_TIER_RANK is keyed by the fully-qualified
#     id (issue #2131), never the bare one resolve_model_id returns. ---
assert_eq "haiku ranks below sonnet" "10" "$(model_tier_rank anthropic/claude-haiku-4-5-20251001)"
assert_eq "sonnet ranks above haiku, below opus" "20" "$(model_tier_rank anthropic/claude-sonnet-5)"
assert_eq "opus ranks above sonnet, below fable" "30" "$(model_tier_rank anthropic/claude-opus-5)"
assert_eq "fable ranks highest" "40" "$(model_tier_rank anthropic/claude-fable-5)"
assert_false "a bare id (unqualified) is not itself a ranked key" \
  model_tier_rank claude-haiku-4-5-20251001
assert_false "an unranked model prints nothing and fails" \
  model_tier_rank anthropic/claude-nonexistent-9
assert_eq "an unranked model's rank is empty" "" \
  "$(model_tier_rank anthropic/claude-nonexistent-9 2>/dev/null)"
# An empty id must return 1 the ordinary way rather than abort the caller:
# bash rejects an empty associative-array subscript ("bad array subscript"),
# which under the `set -e` every script sourcing this file runs with would
# take the whole cycle down instead. Probed in a subshell that would print
# nothing at all if the lookup aborted.
assert_false "an empty model id is not ranked" model_tier_rank ""
assert_eq "an empty model id fails cleanly under set -e rather than aborting the caller" \
  "survived" \
  "$(bash -euo pipefail -c '
      . "$1/lib/model-id.sh"
      model_tier_rank "" || true
      model_tier_rank || true
      printf survived
    ' _ "$SCRIPT_DIR" 2>/dev/null)"

assert_true "model_tier_known accepts empty (a disabled stage)" model_tier_known ""
assert_true "model_tier_known accepts a ranked model" model_tier_known anthropic/claude-sonnet-5
assert_false "model_tier_known rejects an unranked model" model_tier_known anthropic/claude-nonexistent-9

assert_true "haiku is below sonnet" \
  model_tier_below anthropic/claude-haiku-4-5-20251001 anthropic/claude-sonnet-5
assert_false "sonnet is not below sonnet (equal tier clears the floor)" \
  model_tier_below anthropic/claude-sonnet-5 anthropic/claude-sonnet-5
assert_false "opus is not below sonnet" \
  model_tier_below anthropic/claude-opus-5 anthropic/claude-sonnet-5
assert_false "an empty candidate never reports below (a different check's business)" \
  model_tier_below "" anthropic/claude-sonnet-5
assert_false "an empty floor never reports below (a different check's business)" \
  model_tier_below anthropic/claude-haiku-4-5-20251001 ""
assert_false "an unranked candidate never reports below — 'cannot verify', not 'fails'" \
  model_tier_below anthropic/claude-nonexistent-9 anthropic/claude-sonnet-5
assert_false "an unranked floor never reports below either" \
  model_tier_below anthropic/claude-haiku-4-5-20251001 anthropic/claude-nonexistent-9

# --- D31 (issue #2445): tiers compare across providers on one shared scale
#     now, never only within one provider — a ranked pair from two different
#     providers is compared exactly as a same-provider pair is. ---
assert_false "sonnet and grok-4.7 tie (same band): neither is below the other" \
  model_tier_below anthropic/claude-sonnet-5 xai/grok-4.7
assert_false "sonnet and grok-4.7 tie (same band), checked in the other order too" \
  model_tier_below xai/grok-4.7 anthropic/claude-sonnet-5
assert_true "grok-4.3 ranks below sonnet on the shared scale" \
  model_tier_below xai/grok-4.3 anthropic/claude-sonnet-5
assert_false "sonnet does not rank below grok-4.3" \
  model_tier_below anthropic/claude-sonnet-5 xai/grok-4.3
assert_true "grok-4.7 ranks below opus on the shared scale" \
  model_tier_below xai/grok-4.7 anthropic/claude-opus-5
assert_false "opus does not rank below grok-4.7" \
  model_tier_below anthropic/claude-opus-5 xai/grok-4.7
assert_false "an unranked id against a ranked one of a different provider still never reports below" \
  model_tier_below anthropic/claude-nonexistent-9 xai/grok-4.7
assert_false "a ranked id against an unranked one of a different provider still never has anything rank below it" \
  model_tier_below xai/grok-4.7 anthropic/claude-nonexistent-9
assert_true "a same-provider pair is still compared as before" \
  model_tier_below anthropic/claude-haiku-4-5-20251001 anthropic/claude-sonnet-5

# --- The provider seam (issue #2131): a top-level `providers` config block,
#     and a model id qualified with a configured provider resolves to it
#     instead of failing. ---

# Before providers_load is ever called, `anthropic` still resolves exactly as
# it always has — no test here, and no existing caller before this issue,
# needs to call it first.
assert_eq "resolve_model_provider accepts anthropic with no providers_load call" \
  "anthropic" "$(resolve_model_provider coordinator_model "claude-sonnet-5")"
assert_eq "resolve_model_provider accepts an anthropic/-qualified id the same way" \
  "anthropic" "$(resolve_model_provider coordinator_model "anthropic/claude-sonnet-5")"
assert_eq "resolve_model_provider prints nothing for an empty value" \
  "" "$(resolve_model_provider enabler_model "")"
assert_false "resolve_model_provider rejects an unconfigured provider" \
  resolve_model_provider reviewer_model_default "openai/gpt-5"
assert_eq "resolve_model_qualified qualifies a bare id under anthropic" \
  "anthropic/claude-sonnet-5" "$(resolve_model_qualified coordinator_model "claude-sonnet-5")"
assert_eq "resolve_model_qualified passes an already-qualified id through" \
  "anthropic/claude-sonnet-5" "$(resolve_model_qualified coordinator_model "anthropic/claude-sonnet-5")"
assert_eq "resolve_model_qualified prints nothing for an empty value" \
  "" "$(resolve_model_qualified enabler_model "")"

# providers_load with no `providers` key set (absent/null) behaves exactly
# as if it were never called — `anthropic` synthesized, nothing else known.
providers_load "null"
assert_eq "providers_load with no providers configured still accepts anthropic" \
  "anthropic" "$(resolve_model_provider coordinator_model "claude-sonnet-5")"
assert_false "providers_load with no providers configured still rejects others" \
  resolve_model_provider reviewer_model_default "xai/grok-4.3"

# A configured provider resolves instead of failing (the issue's own
# acceptance criterion, run against this library directly). `claude-code` is
# reserved for `anthropic` alone (D29, issue #2198) — a config error
# test/config-schema.test.sh asserts, not something lib/model-id.sh itself
# polices — so this fixture gives `xai` a substrate the test appends to
# PROVIDER_SUBSTRATE_INSTALLED instead, never claude-code.
PROVIDER_SUBSTRATE_INSTALLED+=(test-substrate)
providers_load '{"xai": {"substrate": "test-substrate", "credential_env": "XAI_API_KEY"}}'
assert_eq "a configured provider's qualifier resolves" \
  "grok-4.3" "$(resolve_model_id implementer_model_default "xai/grok-4.3")"
assert_eq "resolve_model_provider names the configured provider" \
  "xai" "$(resolve_model_provider implementer_model_default "xai/grok-4.3")"
assert_eq "resolve_model_qualified builds the qualified id for the tier ladder" \
  "xai/grok-4.3" "$(resolve_model_qualified implementer_model_default "xai/grok-4.3")"
assert_true "PROVIDER_CREDENTIAL_ENV records the configured credential_env" \
  [ "${PROVIDER_CREDENTIAL_ENV[xai]}" = "XAI_API_KEY" ]
assert_eq "anthropic is still synthesized alongside an explicitly configured provider" \
  "anthropic" "$(resolve_model_provider coordinator_model "claude-sonnet-5")"

# PROVIDER_LANES (issue #2240, D30): populated alongside PROVIDER_SUBSTRATE and
# PROVIDER_CREDENTIAL_ENV, both lanes always fully defaulted — api weight 1,
# subscription weight 0, neither enabled, no thresholds — whether or not
# config.json's own entry names a `lanes` block at all.
all_default_lanes='{"api":{"weight":1,"enabled":null,"spend_cap_usd":0,"spend_window_hours":24,"balance_usd":null,"balance_as_of":null,"balance_floor_usd":null},"subscription":{"weight":0,"enabled":null,"spend_cap_usd":0,"spend_window_hours":24,"balance_usd":null,"balance_as_of":null,"balance_floor_usd":null}}'
assert_eq "a configured provider with no lanes block resolves to the all-default lanes object" \
  "$all_default_lanes" "${PROVIDER_LANES[xai]}"
assert_eq "the implicit anthropic gets the same all-default lanes object" \
  "$all_default_lanes" "${PROVIDER_LANES[anthropic]}"

providers_load '{"xai": {"substrate": "test-substrate", "lanes": {"subscription": {"weight": 3, "enabled": true}}}}'
assert_eq "a configured lane overrides its own default weight and enabled" \
  '{"weight":3,"enabled":true,"spend_cap_usd":0,"spend_window_hours":24,"balance_usd":null,"balance_as_of":null,"balance_floor_usd":null}' \
  "$(jq -c '.subscription' <<<"${PROVIDER_LANES[xai]}")"
assert_eq "…leaving the sibling lane at its own untouched default" \
  '{"weight":1,"enabled":null,"spend_cap_usd":0,"spend_window_hours":24,"balance_usd":null,"balance_as_of":null,"balance_floor_usd":null}' \
  "$(jq -c '.api' <<<"${PROVIDER_LANES[xai]}")"

# A provider configured with no credential_env falls back to its substrate's
# own default, the same way claude-code's ANTHROPIC_API_KEY does — exercised
# here against this fixture's own test-substrate entry, appended above,
# rather than claude-code, for the same reason.
PROVIDER_SUBSTRATE_DEFAULT_CREDENTIAL_ENV[test-substrate]=TEST_SUBSTRATE_API_KEY
providers_load '{"xai": {"substrate": "test-substrate"}}'
assert_true "credential_env defaults by substrate when not configured explicitly" \
  [ "${PROVIDER_CREDENTIAL_ENV[xai]}" = "TEST_SUBSTRATE_API_KEY" ]

# A configured provider whose substrate has no adapter installed on this
# node fails fast too, naming the key and the substrate (today's schema enum
# admits `claude-code` and `grok-build`, both always installed, so this is
# exercised directly against the library, with a substrate name neither
# names, rather than through a schema-valid config.json).
providers_load '{"grok": {"substrate": "not-an-installed-substrate"}}'
assert_false "an uninstalled substrate fails resolve_model_provider" \
  resolve_model_provider implementer_model_default "grok/grok-4.3"
err="$(resolve_model_provider implementer_model_default "grok/grok-4.3" 2>&1 >/dev/null)"
case "$err" in
  *"implementer_model_default"*"not-an-installed-substrate"*) printf 'ok   - %s\n' "the substrate error names the key and the substrate" ;;
  *)
    printf 'FAIL - the substrate error names the key and the substrate\n     actual: %s\n' "$err"
    failures=$(( failures + 1 ))
    ;;
esac
assert_false "resolve_model_id fails the same way for an uninstalled substrate" \
  resolve_model_id implementer_model_default "grok/grok-4.3"
# --- resolve_model_id_into: the assigning form, and why it exists
#     (requirement 1a, issue #2133). ---
#
# MODEL_PROVIDER is the map requirement 4d's substrate dispatch and
# requirement 33a's `provider` field both read back, and it is populated as a
# side effect of resolution. That makes the *form* of the call load-bearing in
# a way nothing else about this library is: a subshell cannot hand an
# assignment back to its parent, so resolving inside `$( )` returns the bare
# id and silently drops the recording. Both halves are asserted, because the
# failure mode is not an error — it is a fallback that looks like success.
providers_load '{"xai": {"substrate": "claude-code"}}'
MODEL_PROVIDER=()

resolve_model_id_into into_model implementer_model_default "xai/grok-4.3"
assert_eq "resolve_model_id_into assigns the bare id to the named variable" \
  "grok-4.3" "${into_model:-}"
assert_eq "…and records the provider in the caller's own MODEL_PROVIDER" \
  "xai" "${MODEL_PROVIDER[grok-4.3]:-<unrecorded>}"

MODEL_PROVIDER=()
substituted="$(resolve_model_id implementer_model_default "xai/grok-4.3")"
assert_eq "the printing form returns the same bare id" "grok-4.3" "$substituted"
assert_eq "…but its recording is discarded with the command substitution" \
  "0" "${#MODEL_PROVIDER[@]}"

# An empty value is the "this stage is disabled" convention, not an error:
# it assigns empty, records nothing, and succeeds — the three cycle scripts
# call this under `set -e`, so a non-zero return here would abort startup
# for every installation with a stage switched off.
MODEL_PROVIDER=()
resolve_model_id_into into_empty enabler_model ""
assert_eq "an empty value assigns empty and succeeds" "0" "$?"
# `${x-…}`, not `${x:-…}`: the claim is that the variable was *assigned* an
# empty string, which `:-` could not tell from never having been set at all.
assert_eq "…assigning nothing, but assigning it" "" "${into_empty-unset}"
assert_eq "…and recording nothing" "0" "${#MODEL_PROVIDER[@]}"

# A rejected qualifier fails exactly as the printing form does, and records
# nothing, so a caller under `set -e` still stops at config read time.
MODEL_PROVIDER=()
assert_false "resolve_model_id_into fails for an unconfigured provider" \
  resolve_model_id_into into_bad reviewer_model_default "openai/gpt-5"
assert_eq "…and records nothing for it" "0" "${#MODEL_PROVIDER[@]}"

MODEL_PROVIDER=()

# --- model_tiers_load (issue #2465, D29's customer-control rule): an
#     installation-level override of MODEL_TIER_RANK, merged over the
#     shipped table rather than ever edited in it. `xai` is configured on
#     `grok-build` (always installed), never `test-substrate`, since these
#     assertions are about the override mechanism, not substrate
#     resolution, already covered above. ---
providers_load '{"xai": {"substrate": "grok-build"}}'

model_tiers_load '{"xai/grok-4.7": 30}'
assert_eq "model_tiers moves a model the shipped table already places" \
  "30" "$(model_tier_rank xai/grok-4.7)"
assert_true "…and model_tier_below reads the moved band" \
  model_tier_below anthropic/claude-sonnet-5 xai/grok-4.7
assert_false "…the moved band also clears what it used to rank below" \
  model_tier_below xai/grok-4.7 anthropic/claude-sonnet-5

model_tiers_load '{"xai/grok-5": 30}'
assert_true "model_tiers places a model the shipped table has never heard of" \
  model_tier_known xai/grok-5
assert_eq "…at the stated band" "30" "$(model_tier_rank xai/grok-5)"
assert_eq "…and a prior call's override (grok-4.7) is not carried into this one — reset first" \
  "20" "$(model_tier_rank xai/grok-4.7)"

# A key naming a provider `providers` does not configure is the identical
# fail-fast config error an ordinary model key gets, naming "model_tiers" as
# the key — every other key in the same object is still attempted and
# merged, so one bad entry never hides what a sibling would have reported.
assert_false "model_tiers_load fails on a key naming an unconfigured provider, after merging its valid sibling" \
  model_tiers_load '{"xai/grok-4.7": 25, "openai/gpt-5": 10}'
assert_eq "…the valid sibling still merged" "25" "$(model_tier_rank xai/grok-4.7)"
err="$(model_tiers_load '{"openai/gpt-5": 10}' 2>&1 >/dev/null)"
case "$err" in
  *"model_tiers"*"openai"*) printf 'ok   - %s\n' "the error names model_tiers and the offending provider" ;;
  *)
    printf 'FAIL - the error names model_tiers and the offending provider\n     actual: %s\n' "$err"
    failures=$(( failures + 1 ))
    ;;
esac

# A band JSON writes with a fractional part that is still an integer is
# `integer` to requirement 1b's schema (`type_ok` reads the keyword as "a
# number with nothing after the point"), so it passes both cycle scripts'
# startup gate and reaches this loader — and jq's own `tostring` would render
# it `25.0`, which bash arithmetic cannot evaluate. Canonicalised here
# instead, so model_tier_below compares it rather than swallowing a shell
# error and reporting requirement 1c's floor clear on a comparison it never
# made.
assert_true "model_tiers_load accepts a band the schema calls an integer but JSON writes with a point" \
  model_tiers_load '{"xai/grok-5": 25.0}'
assert_eq "…canonicalised to the plain decimal form bash arithmetic can read" \
  "25" "$(model_tier_rank xai/grok-5)"
assert_true "…so model_tier_below really compares it" \
  model_tier_below anthropic/claude-sonnet-5 xai/grok-5
assert_true "…and exponent notation the schema accepts the same way" \
  model_tiers_load '{"xai/grok-5": 1e2}'
assert_eq "…also canonicalised" "100" "$(model_tier_rank xai/grok-5)"

# A band this loader cannot canonicalise is refused by name and the shipped
# band stands, rather than reaching MODEL_TIER_RANK and turning every later
# comparison into a swallowed shell error. Only scripts/doctor.sh — which
# names a schema fault and then keeps going — and a band too large for jq to
# render as a plain integer get this far, but a band that cannot be compared
# is worse than no override at all, so it is a fault here rather than a
# merge.
assert_false "model_tiers_load refuses a band that is not a non-negative integer" \
  model_tiers_load '{"xai/grok-4.7": "ten"}'
assert_eq "…leaving the shipped band standing for it" \
  "20" "$(model_tier_rank xai/grok-4.7)"
assert_false "…and a band too large for jq to render as a plain integer, rather than merging '1e+20'" \
  model_tiers_load '{"xai/grok-4.7": 1e20}'
assert_eq "…leaving that shipped band standing too" \
  "20" "$(model_tier_rank xai/grok-4.7)"
err="$(model_tiers_load '{"xai/grok-4.7": "ten"}' 2>&1 >/dev/null)"
case "$err" in
  *"model_tiers"*"xai/grok-4.7"*"ten"*) printf 'ok   - %s\n' "the error names model_tiers, the key and the offending band" ;;
  *)
    printf 'FAIL - the error names model_tiers, the key and the offending band\n     actual: %s\n' "$err"
    failures=$(( failures + 1 ))
    ;;
esac

# A caller that never calls model_tiers_load reads the shipped table
# unchanged — exercised here by resetting with an absent/null object, which
# must behave identically to never having called it at all.
model_tiers_load "null"
assert_eq "an absent model_tiers leaves the shipped table exactly as it ships" \
  "20" "$(model_tier_rank anthropic/claude-sonnet-5)"
assert_false "…and an earlier call's override does not survive a later one" \
  model_tier_known xai/grok-5

# --- Weighted model sets (issue #2247): a *_model-shaped key may name an
#     object {"models": [...]} instead of one bare/qualified id, resolved
#     through model_key_load_into — the set-aware form of
#     resolve_model_id_into every call site switches to. ---
providers_load '{"xai": {"substrate": "grok-build"}}'

assert_true "model_key_load_into resolves every member of a set, each through resolve_model_id_into" \
  model_key_load_into mk1_var mk1_key '{"models": [{"id": "claude-sonnet-5", "weight": 2}, {"id": "xai/grok-4.7", "weight": 1}]}'
# shellcheck disable=SC2154  # mk1_var: assigned by model_key_load_into above, the assigning form
assert_eq "…and sets VAR to the key itself, the set's own handle" \
  "mk1_key" "$mk1_var"
assert_true "model_key_is_set recognizes the handle" \
  model_key_is_set "$mk1_var"
assert_eq "…normalizing every member to its qualified id, weight defaulted where omitted" \
  '[{"id":"anthropic/claude-sonnet-5","weight":2},{"id":"xai/grok-4.7","weight":1}]' \
  "${MODEL_SET_JSON[$mk1_var]}"
assert_eq "…and recording each member's provider in MODEL_PROVIDER, as an ordinary key would" \
  "xai" "${MODEL_PROVIDER[grok-4.7]}"

model_key_load_into mk_bare mk_bare_key claude-sonnet-5
# shellcheck disable=SC2154  # mk_bare: assigned by model_key_load_into above, the assigning form
assert_eq "a bare id is still unaffected: model_key_load_into delegates to resolve_model_id_into" \
  "claude-sonnet-5" "$mk_bare"
assert_false "…and is never mistaken for a set" \
  model_key_is_set "$mk_bare"

# An unresolvable member fails fast, naming the key and the offending
# member — the identical message an ordinary key's own bad value already
# prints — and the set is never half-recorded in MODEL_SET_JSON.
assert_false "an unresolvable member fails fast" \
  model_key_load_into mk2_var mk2_key '{"models": [{"id": "bogus/doesnotexist"}]}'
err="$(model_key_load_into mk2_var mk2_key '{"models": [{"id": "bogus/doesnotexist"}]}' 2>&1 >/dev/null)"
case "$err" in
  *"mk2_key"*"bogus/doesnotexist"*) printf 'ok   - %s\n' "…naming the key and the member" ;;
  *)
    printf 'FAIL - …naming the key and the member\n     actual: %s\n' "$err"
    failures=$(( failures + 1 ))
    ;;
esac
assert_false "…and the set is never half-recorded" \
  model_key_is_set mk2_key

# model_key_qualified_ids is requirement 1c's own reader: every member for a
# set, the one qualified id wrapped in an array for an ordinary key, and []
# for empty (disabled).
assert_eq "model_key_qualified_ids expands a set to every member's qualified id" \
  '["anthropic/claude-sonnet-5","xai/grok-4.7"]' \
  "$(model_key_qualified_ids mk1_key "$mk1_var")"
assert_eq "…one qualified id, wrapped in an array, for an ordinary key" \
  '["anthropic/claude-sonnet-5"]' \
  "$(model_key_qualified_ids implementer_model_default claude-sonnet-5)"
assert_eq "…and [] for empty (disabled)" \
  '[]' "$(model_key_qualified_ids enabler_model "")"

# model_key_fingerprint_json (issue #2660) is what a no-op fingerprint
# should embed in place of model_key_load_into's own VAR: a set's own
# normalized member array rather than its bare handle, so editing the set's
# membership or weights changes what gets embedded — restoring the
# fingerprint's sensitivity a bare VAR loses, since the handle is a
# constant (the config key's own name) unmoved by any edit to what it names.
assert_eq "model_key_fingerprint_json embeds a set's own member array, not its bare handle" \
  '[{"id":"anthropic/claude-sonnet-5","weight":2},{"id":"xai/grok-4.7","weight":1}]' \
  "$(model_key_fingerprint_json "$mk1_var")"
assert_eq "…and an ordinary key's bare id passes through as a JSON string, unchanged" \
  '"claude-sonnet-5"' "$(model_key_fingerprint_json "$mk_bare")"
assert_eq "…and empty (disabled) prints an empty JSON string" \
  '""' "$(model_key_fingerprint_json "")"

before_fp="$(model_key_fingerprint_json "$mk1_var")"
model_key_load_into mk1_var mk1_key '{"models": [{"id": "claude-sonnet-5", "weight": 9}, {"id": "xai/grok-4.7", "weight": 1}]}'
after_fp="$(model_key_fingerprint_json "$mk1_var")"
if [[ "$before_fp" != "$after_fp" ]]; then
  printf 'ok   - %s\n' "editing a set's weights changes model_key_fingerprint_json's own output for the same handle"
else
  printf 'FAIL - %s\n     before: %s\n     after:  %s\n' \
    "editing a set's weights changes model_key_fingerprint_json's own output for the same handle" "$before_fp" "$after_fp"
  failures=$(( failures + 1 ))
fi

# Leave providers_load back at the default state (no providers configured)
# before any remaining assertion below, in case one is ever added that
# relies on the no-op default.
providers_load "null"

echo
if (( failures == 0 )); then
  echo "All model-id assertions passed."
  exit 0
else
  echo "$failures model-id assertion(s) FAILED."
  exit 1
fi
