#!/usr/bin/env bash
#
# test/stage-run.test.sh — the substrate seam behind `run_model_stage`
# (requirement 4d of docs/spec/implementation/README.md, issue #2133).
#
# Two properties, and they are tested separately because they are different
# claims about the same seam:
#
#   byte-for-byte unchanged   with only `anthropic` configured — every
#                             installation that exists today — a stage's
#                             `<stage>.stream.jsonl`, `<stage>.out` and
#                             `<stage>.out.stderr` are exactly what
#                             `run_claude_stage` always produced. The
#                             extraction of the Claude adapter into
#                             lib/substrate-claude-code.sh must be invisible
#                             from here: nothing downstream of this launcher
#                             (the result parsers, metering, limit detection)
#                             can tell the dispatch happened.
#   a second adapter is one file away   a stub substrate, defined and
#                             registered entirely inside this test — never
#                             touching lib/ or config.schema.json, and never
#                             installed in the image — proves `run_model_stage`
#                             dispatches on the provider a model resolves to
#                             rather than on anything hard-coded to Claude
#                             Code. This is what "the Claude adapter extracted
#                             behind the one stage launcher" has to mean: a
#                             sibling adapter plugs in without `stage-run.sh`
#                             itself changing.
#
# `claude` is a stub on PATH — no network, no model, no cost.
#
# Run directly: ./test/stage-run.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:   %s\n' \
      "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# shellcheck source=lib/stage-run.sh
. "$SCRIPT_DIR/lib/stage-run.sh"

# Read by the cycle scripts' signal handlers, which this file does not have.
# shellcheck disable=SC2034
stage_pid=""
# shellcheck disable=SC2034
stage_name=""

# =============================================================================
# 1. Byte-for-byte: only `anthropic` configured, the extraction changed nothing
# =============================================================================
#
# The stub plays the same role test/stage-stream.test.sh's does: a fixed
# four-event transcript, captured verbatim. What is new here is the
# comparison target — not "does metering read it the same way" (that test's
# own claim) but "is the file itself identical to what the pre-extraction
# function wrote", checked against the exact fixture strings below.

mkdir -p "$tmp_dir/bin"
cat >"$tmp_dir/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_CAPTURE/argv.seen"
cat > "$STUB_CAPTURE/prompt.seen"
printf '%s\n' '{"type":"system","subtype":"init","session_id":"s1"}'
printf '%s\n' '{"type":"assistant","message":{"role":"assistant"}}'
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok","total_cost_usd":0.01,"duration_ms":100,"num_turns":2}'
STUB
chmod +x "$tmp_dir/bin/claude"
export PATH="$tmp_dir/bin:$PATH"

fixture_capture="$tmp_dir/fixture"
mkdir -p "$fixture_capture"
export STUB_CAPTURE="$fixture_capture"
out="$fixture_capture/implementer.out"

run_model_stage implementer 60 claude-sonnet-5 "a fixed prompt" "$out" "$fixture_capture"
rc=$?

assert_eq "a fixture run exits with the invocation's own status" "0" "$rc"

expected_stream='{"type":"system","subtype":"init","session_id":"s1"}
{"type":"assistant","message":{"role":"assistant"}}
{"type":"result","subtype":"success","is_error":false,"result":"ok","total_cost_usd":0.01,"duration_ms":100,"num_turns":2}'
assert_eq ".stream.jsonl is byte-for-byte the transcript the run emitted" \
  "$expected_stream" "$(cat "$(stage_stream_file "$out")")"

expected_out='{"type":"result","subtype":"success","is_error":false,"result":"ok","total_cost_usd":0.01,"duration_ms":100,"num_turns":2}'
assert_eq ".out is byte-for-byte the stream's own final result event" \
  "$expected_out" "$(cat "$out")"

assert_eq ".out.stderr is empty, as it is for a stage that wrote nothing to it" \
  "0" "$(wc -c < "$out.stderr")"

assert_eq "the prompt reached the substrate's own binary on stdin, unchanged" \
  "a fixed prompt" "$(cat "$fixture_capture/prompt.seen")"
assert_contains "the launch argv is still the Claude adapter's own, unchanged" \
  "--dangerously-skip-permissions" "$(cat "$fixture_capture/argv.seen")"

# =============================================================================
# 2. A second adapter is one file away
# =============================================================================
#
# A stub substrate, "stub-cli", defined entirely in this test's own process —
# never written to lib/, never added to config.schema.json's `providers`
# description, and with no binary installed anywhere on this node's image.
# Registering it costs exactly the two maps the issue's own "shape" names:
# one new entry in PROVIDER_SUBSTRATE_INSTALLED (the enum
# `config_provider_errors` validates against in a real installation) and one
# provider naming it in PROVIDER_SUBSTRATE (what `providers_load` would
# populate from a real `providers` config block). `run_model_stage` itself is
# touched nowhere below — the whole point is that it does not need to be.

mkdir -p "$tmp_dir/stub-bin"
cat >"$tmp_dir/stub-bin/stub-cli" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$STUB_CAPTURE/stub-argv.seen"
cat > /dev/null
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"stub-provider-ran"}'
STUB
chmod +x "$tmp_dir/stub-bin/stub-cli"

# The stub adapter's own contract — same shape as
# lib/substrate-claude-code.sh's three functions: build the argv, decide the
# prompt-delivery method (here, stdin again — a provider that needed
# `--prompt-file` instead would simply write one here), name the binary, and
# become it via `exec`; find the terminal result line; recognise a rate-limit
# refusal (this stub never produces one).
substrate_stub_cli_exec() {
  local model="$1" resume_session_id="$2"
  exec stub-cli --model "$model" ${resume_session_id:+--continue "$resume_session_id"}
}
substrate_stub_cli_result_line() {
  local stream_file="$1"
  jq -c 'select(type == "object" and .type == "result")' "$stream_file" 2>/dev/null | tail -n 1
}
substrate_stub_cli_rejected_rate_limit() {
  return 1
}

# The two registrations the issue's own acceptance criterion names: one
# substrate-enum entry (PROVIDER_SUBSTRATE_INSTALLED — a real installation's
# counterpart is config.schema.json's `providers.*.substrate`, validated
# against this same array by lib/config-schema.sh's config_provider_errors)
# and one provider naming it (PROVIDER_SUBSTRATE — a real installation's
# counterpart is `providers_load` populating it from config's own `providers`
# block). Declared fresh, since this test sources lib/stage-run.sh alone,
# never lib/model-id.sh: a real installation's PROVIDER_SUBSTRATE_INSTALLED
# already carries `claude-code` by the time it reaches this point, but
# nothing stage-run.sh does checks that array at all, so its absence here
# costs this test nothing.
# shellcheck disable=SC2034  # documents the real installation's parallel registration; nothing in this file's own run_model_stage path reads it
declare -ga PROVIDER_SUBSTRATE_INSTALLED=(stub-cli)
PROVIDER_SUBSTRATE[stub-provider]=stub-cli
MODEL_PROVIDER[stub-model-1]=stub-provider

stub_capture="$tmp_dir/stub-run"
mkdir -p "$stub_capture"
export PATH="$tmp_dir/stub-bin:$PATH"
export STUB_CAPTURE="$stub_capture"
stub_out="$stub_capture/implementer.out"

run_model_stage implementer 60 stub-model-1 "irrelevant for this stub" "$stub_out" "$stub_capture"
rc=$?

assert_eq "stage_model_substrate resolves the registered model to the new substrate" \
  "stub-cli" "$(stage_model_substrate stub-model-1)"
assert_eq "a model resolving to an unregistered substrate still falls back to claude-code" \
  "claude-code" "$(stage_model_substrate some-other-model)"
assert_eq "run_model_stage dispatched to the stub adapter, not the Claude one" "0" "$rc"
assert_eq "…and the stub's own result reached .out" \
  "stub-provider-ran" "$(jq -r '.result' "$stub_out" 2>/dev/null)"
assert_contains "…via the stub's own binary and argv, never claude's" \
  "--model
stub-model-1" "$(cat "$stub_capture/stub-argv.seen" 2>/dev/null)"
assert_eq "and the real claude stub from part 1 was never invoked for this run" \
  "" "$(cat "$stub_capture/argv.seen" 2>/dev/null)"

printf '\n'
if (( failures )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
