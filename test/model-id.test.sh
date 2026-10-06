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

# --- Model-tier ordering (requirement 1c; agent-ops#822): the fleet's four
#     currently configured models, ranked haiku < sonnet < opus < fable.
#     MODEL_TIER_RANK is keyed by the fully-qualified id (issue #2131), never
#     the bare one resolve_model_id returns. ---
assert_eq "haiku ranks below sonnet" "1" "$(model_tier_rank anthropic/claude-haiku-4-5-20251001)"
assert_eq "sonnet ranks above haiku, below opus" "2" "$(model_tier_rank anthropic/claude-sonnet-5)"
assert_eq "opus ranks above sonnet, below fable" "3" "$(model_tier_rank anthropic/claude-opus-5)"
assert_eq "fable ranks highest" "4" "$(model_tier_rank anthropic/claude-fable-5)"
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
assert_false "a cross-provider pair ranks unknown, never below, on either side" \
  model_tier_below xai/grok-4.3 anthropic/claude-sonnet-5

# --- D29 (issue #2198): once a second provider's model is itself ranked,
#     model_tier_below must still never compare it against another
#     provider's tiers — an explicit provider check, not an accident of
#     xai/grok-4.3 being unranked above. Ranked once low and once high, in
#     both argument positions, to prove the provider check runs before
#     either side's rank is read: if it didn't, at least one of these four
#     would report "below" on the strength of the numbers alone. ---
MODEL_TIER_RANK[xai/grok-4.3]=1
assert_false "a cross-provider candidate ranked below the floor's own number still never reports below" \
  model_tier_below xai/grok-4.3 anthropic/claude-fable-5
assert_false "a cross-provider floor ranked below the candidate's own number still never has anything rank below it" \
  model_tier_below anthropic/claude-fable-5 xai/grok-4.3
MODEL_TIER_RANK[xai/grok-4.3]=99
assert_false "a cross-provider candidate ranked above the floor's own number still never reports below" \
  model_tier_below xai/grok-4.3 anthropic/claude-haiku-4-5-20251001
assert_false "a cross-provider floor ranked above the candidate's own number still never has anything rank below it" \
  model_tier_below anthropic/claude-haiku-4-5-20251001 xai/grok-4.3
unset 'MODEL_TIER_RANK[xai/grok-4.3]'
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

# A provider configured with no credential_env falls back to its substrate's
# own default, the same way claude-code's ANTHROPIC_API_KEY does — exercised
# here against this fixture's own test-substrate entry, appended above,
# rather than claude-code, for the same reason.
PROVIDER_SUBSTRATE_DEFAULT_CREDENTIAL_ENV[test-substrate]=TEST_SUBSTRATE_API_KEY
providers_load '{"xai": {"substrate": "test-substrate"}}'
assert_true "credential_env defaults by substrate when not configured explicitly" \
  [ "${PROVIDER_CREDENTIAL_ENV[xai]}" = "TEST_SUBSTRATE_API_KEY" ]

# A configured provider whose substrate has no adapter installed on this
# node fails fast too, naming the key and the substrate — forward groundwork
# for #2133/#2134 (today's schema enum admits only `claude-code`, which is
# always installed, so this is exercised directly against the library
# rather than through a schema-valid config.json).
providers_load '{"grok": {"substrate": "grok-build"}}'
assert_false "an uninstalled substrate fails resolve_model_provider" \
  resolve_model_provider implementer_model_default "grok/grok-4.3"
err="$(resolve_model_provider implementer_model_default "grok/grok-4.3" 2>&1 >/dev/null)"
case "$err" in
  *"implementer_model_default"*"grok-build"*) printf 'ok   - %s\n' "the substrate error names the key and the substrate" ;;
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
