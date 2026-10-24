#!/usr/bin/env bash
#
# test/stage-run.test.sh — the substrate seam behind `run_model_stage`
# (requirement 4d of docs/spec/implementation/README.md, issue #2133).
#
# Three properties, and they are tested separately because they are different
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
#   …and reached the way a cycle script reaches it   the same stub adapter,
#                             dispatched to through the whole chain
#                             `agent-cycle.sh`, `review-cycle.sh` and
#                             `monitor-cycle.sh` drive — `providers_load`,
#                             then `resolve_model_id_into`, then
#                             `run_model_stage` — with nothing written into
#                             MODEL_PROVIDER by hand. Part 2 proves dispatch
#                             *given* a populated map; this proves the step
#                             that populates it, which is the half that can
#                             break silently, since both readers of the map
#                             fall back to `anthropic`/`claude-code` rather
#                             than failing.
#
# `claude` is a stub on PATH — no network, no model, no cost.
#
# Run directly: ./test/stage-run.test.sh — exit 0 iff all passed.
#
# shellcheck disable=SC2031  # false positive, file-wide: a `VAR=val
# run_model_stage ...` prefix assignment does not subshell a function call —
# bash scopes it to that one command's own environment, not a copy of the
# calling shell — so `run_model_stage`'s own global writes (`stage_lane`,
# `stage_kill_reason`, and friends) reach this file's later assertions
# exactly as part 6's own runs below prove empirically.

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
# shellcheck source=lib/toggle.sh
. "$SCRIPT_DIR/lib/toggle.sh"

# Read by the cycle scripts' signal handlers, which this file does not have.
# shellcheck disable=SC2034
stage_pid=""
# shellcheck disable=SC2034
stage_name=""

# Issue #2241, D30: lane management (the draw, the forcing, the live-stream
# verification) only ever engages once at least one of claude-code's two
# credentials is present (`stage_lane_any_present`) — see
# `run_model_stage`'s own "Presence" paragraph for why. One credential
# present, deterministically, is what every part below except part 6 (which
# manages its own) needs: the acceptance criterion this exists to satisfy is
# "the existing test/stage-run.test.sh cases pass unchanged with no `lanes`
# configured and one credential present" — present, not ambient, since
# relying on whatever happens to be in this process's own environment would
# make every assertion below depend on the host that runs it rather than on
# this file alone. A placeholder shape (test/metering.test.sh's own
# convention), and a config directory that is never created, so the
# subscription lane is never also present by accident.
export ANTHROPIC_API_KEY="sk-ant-test-placeholder"
export CLAUDE_CONFIG_DIR="$tmp_dir/no-such-claude-config"

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
printf '%s\n' '{"type":"system","subtype":"init","session_id":"s1","apiKeySource":"ANTHROPIC_API_KEY"}'
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

expected_stream='{"type":"system","subtype":"init","session_id":"s1","apiKeySource":"ANTHROPIC_API_KEY"}
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
assert_eq "the run's own lane, observed off the stub's init event, reaches stage_lane_json (issue #2239)" \
  '"api"' "$stage_lane_json"

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
# lib/substrate-claude-code.sh's four functions: build the argv, decide the
# prompt-delivery method (here, stdin again — a provider that needed
# `--prompt-file` instead would simply write one here), name the binary, and
# become it via `exec`; find the terminal result line; recognise a rate-limit
# refusal (this stub never produces one); read the lane a run used (this stub
# never reports one, since it is not Claude Code and has no apiKeySource
# vocabulary of its own — issue #2239 is Claude Code's own adapter alone).
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
substrate_stub_cli_lane_of() {
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

# =============================================================================
# 3. …and it is reached the way a cycle script reaches it
# =============================================================================
#
# Part 2 proves dispatch *given* a populated MODEL_PROVIDER, which it
# populates by hand. That leaves the step before it untested, and that step is
# the one that can silently stop working: the map is populated as a side
# effect of resolution, so a caller that resolves inside a command
# substitution loses the recording with the subshell and gets a silent
# fallback to `claude-code` rather than an error. This part therefore drives
# the whole chain a cycle script drives — `providers_load` from a config
# `providers` block, then `resolve_model_id_into` on a qualified id, then
# `run_model_stage` on what that assigned — and asserts the stub adapter is
# reached with nothing set by hand in between.
#
# lib/model-id.sh is sourced here rather than at the top of the file because
# it declares PROVIDER_SUBSTRATE/MODEL_PROVIDER fresh, which would undo part
# 2's own registrations; `providers_load` resets PROVIDER_SUBSTRATE in any
# case. The stub substrate is re-registered below for the same reason.

# shellcheck source=lib/model-id.sh
. "$SCRIPT_DIR/lib/model-id.sh"

# The substrate enum, as a real installation gets it from
# config.schema.json's `providers.*.substrate` via config_provider_errors:
# resolve_model_provider refuses a provider whose substrate is not installed,
# so the stub has to join the array before it can resolve at all.
PROVIDER_SUBSTRATE_INSTALLED+=(stub-cli)
# The `providers` block, as a real installation gets it from config.json.
providers_load '{"stub-provider": {"substrate": "stub-cli"}}'

assert_eq "providers_load registers the stub provider's substrate" \
  "stub-cli" "${PROVIDER_SUBSTRATE[stub-provider]:-}"

e2e_capture="$tmp_dir/e2e-run"
mkdir -p "$e2e_capture"
export STUB_CAPTURE="$e2e_capture"
e2e_out="$e2e_capture/implementer.out"

# Exactly what agent-cycle.sh/monitor-cycle.sh/review-cycle.sh do with a
# configured model, and nothing else: no MODEL_PROVIDER write by hand.
resolve_model_id_into e2e_model implementer_model_default "stub-provider/stub-model-2"
e2e_rc_resolve=$?

assert_eq "resolve_model_id_into assigns the bare id a provider's CLI wants" \
  "stub-model-2" "${e2e_model:-}"
assert_eq "…and succeeds" "0" "$e2e_rc_resolve"
assert_eq "…and the recording survives into the caller's own shell" \
  "stub-provider" "${MODEL_PROVIDER[stub-model-2]:-<unrecorded>}"
assert_eq "…so stage_model_substrate resolves it without anything set by hand" \
  "stub-cli" "$(stage_model_substrate "$e2e_model")"

run_model_stage implementer 60 "$e2e_model" "irrelevant for this stub" "$e2e_out" "$e2e_capture"
rc=$?

assert_eq "run_model_stage dispatches on a provider resolved from config alone" \
  "0" "$rc"
assert_eq "…reaching the stub adapter, not the Claude one" \
  "stub-provider-ran" "$(jq -r '.result' "$e2e_out" 2>/dev/null)"
assert_contains "…with the stub's own argv carrying the resolved bare id" \
  "--model
stub-model-2" "$(cat "$e2e_capture/stub-argv.seen" 2>/dev/null)"
assert_eq "…and claude was never invoked for it" \
  "" "$(cat "$e2e_capture/argv.seen" 2>/dev/null)"
assert_eq "stage_provider names the provider the model resolved to" \
  "stub-provider" "$stage_provider"

# The printing form is the one a caller uses when it only wants the string,
# and it cannot carry the recording: pinned here so the two forms' difference
# is a tested property rather than a comment, since a future call site
# reaching for the wrong one is exactly how this seam stops dispatching.
unset 'MODEL_PROVIDER[stub-model-3]'
substituted_model="$(resolve_model_id implementer_model_trivial "stub-provider/stub-model-3")"
assert_eq "resolve_model_id still returns the bare id" \
  "stub-model-3" "$substituted_model"
assert_eq "…but a command substitution discards the recording, so the substrate falls back" \
  "claude-code" "$(stage_model_substrate "$substituted_model")"

# =============================================================================
# 4. An empty MODEL resolves to the anthropic fallback, not a hard abort
# =============================================================================
#
# Issue #2234: bash makes an empty subscript on an associative array a hard
# "bad array subscript" error rather than an empty read, so
# `${MODEL_PROVIDER[$model]:-anthropic}` never gets a chance to apply when
# MODEL is empty — unlike an unknown-but-non-empty model, which the fallback
# above already covers. Run under the same `set -euo pipefail` every cycle
# script runs under (same shape as test/approver.test.sh's "survives the
# caller's shell options"), so a regression here reports as a failed
# assertion rather than the whole test process dying mid-run.
empty_model_rc=0
empty_model_substrate="$(
  set -euo pipefail
  . "$SCRIPT_DIR/lib/stage-run.sh" 2>/dev/null
  stage_model_substrate ""
)" || empty_model_rc=$?
assert_eq "an empty model does not abort stage_model_substrate under set -e" \
  "0" "$empty_model_rc"
assert_eq "…and resolves to the anthropic fallback's own substrate" \
  "claude-code" "$empty_model_substrate"

empty_run_capture="$tmp_dir/empty-model-run"
mkdir -p "$empty_run_capture"
(
  set -euo pipefail
  . "$SCRIPT_DIR/lib/stage-run.sh" 2>/dev/null
  # shellcheck disable=SC2030,SC2031
  STUB_CAPTURE="$empty_run_capture"
  export STUB_CAPTURE
  run_model_stage implementer 60 "" "irrelevant for this stub" \
    "$empty_run_capture/implementer.out" "$empty_run_capture"
  [[ "$stage_provider" == "anthropic" ]] || exit 9
)
assert_eq "run_model_stage with an empty model does not abort under set -e" \
  "0" "$?"
assert_eq "…and the stub it dispatched to is still the claude-code one" \
  "ok" "$(jq -r '.result' "$empty_run_capture/implementer.out" 2>/dev/null)"

# =============================================================================
# 5. ANTHROPIC_WORKSPACE_ID composes the anthropic-workspace-id header (#2309)
# =============================================================================
#
# A fresh stub `claude`, prepended onto PATH ahead of part 1's: this one also
# prints its own environment's ANTHROPIC_CUSTOM_HEADERS, which is the one
# thing substrate_claude_code_compose_workspace_header
# (lib/substrate-claude-code.sh) changes before the real exec.

mkdir -p "$tmp_dir/header-bin"
cat >"$tmp_dir/header-bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s' "${ANTHROPIC_CUSTOM_HEADERS:-}" > "$STUB_CAPTURE/headers.seen"
cat > /dev/null
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
STUB
chmod +x "$tmp_dir/header-bin/claude"
export PATH="$tmp_dir/header-bin:$PATH"

header_capture="$tmp_dir/header-run-valid"
mkdir -p "$header_capture"
# shellcheck disable=SC2031  # false positive: run_model_stage's own
# backgrounded subshell exports this name too, for the stub it launches —
# this process's own value, never that one, is what this line sets
export STUB_CAPTURE="$header_capture"
export ANTHROPIC_WORKSPACE_ID="wrkspc_abc"
unset ANTHROPIC_CUSTOM_HEADERS
run_model_stage implementer 60 claude-sonnet-5 "irrelevant for this stub" \
  "$header_capture/implementer.out" "$header_capture"
assert_eq "a valid ANTHROPIC_WORKSPACE_ID composes the anthropic-workspace-id header" \
  "anthropic-workspace-id: wrkspc_abc" "$(cat "$header_capture/headers.seen" 2>/dev/null)"

header_capture="$tmp_dir/header-run-operator"
mkdir -p "$header_capture"
export STUB_CAPTURE="$header_capture"
export ANTHROPIC_WORKSPACE_ID="wrkspc_abc"
# shellcheck disable=SC2031  # same false positive: this process's own value
# is what the stub prints, never a value read back from the subshell above
export ANTHROPIC_CUSTOM_HEADERS="x-operator: 1"
run_model_stage implementer 60 claude-sonnet-5 "irrelevant for this stub" \
  "$header_capture/implementer.out" "$header_capture"
assert_eq "an operator-supplied ANTHROPIC_CUSTOM_HEADERS is kept, with the workspace line appended" \
  "x-operator: 1
anthropic-workspace-id: wrkspc_abc" "$(cat "$header_capture/headers.seen" 2>/dev/null)"

header_capture="$tmp_dir/header-run-malformed"
mkdir -p "$header_capture"
export STUB_CAPTURE="$header_capture"
export ANTHROPIC_WORKSPACE_ID="not-a-workspace-id"
unset ANTHROPIC_CUSTOM_HEADERS
run_model_stage implementer 60 claude-sonnet-5 "irrelevant for this stub" \
  "$header_capture/implementer.out" "$header_capture"
assert_eq "a malformed ANTHROPIC_WORKSPACE_ID composes nothing" \
  "" "$(cat "$header_capture/headers.seen" 2>/dev/null)"
assert_contains "...and the launch records a warning naming the bad id, on its own .out.stderr" \
  "not-a-workspace-id" "$(cat "$header_capture/implementer.out.stderr" 2>/dev/null)"

header_capture="$tmp_dir/header-run-unset"
mkdir -p "$header_capture"
export STUB_CAPTURE="$header_capture"
unset ANTHROPIC_WORKSPACE_ID
unset ANTHROPIC_CUSTOM_HEADERS
run_model_stage implementer 60 claude-sonnet-5 "irrelevant for this stub" \
  "$header_capture/implementer.out" "$header_capture"
assert_eq "with no ANTHROPIC_WORKSPACE_ID set, ANTHROPIC_CUSTOM_HEADERS is left unset" \
  "" "$(cat "$header_capture/headers.seen" 2>/dev/null)"

# =============================================================================
# 6. The credit mix: a lane is drawn by weight, forced, and verified (#2241, D30)
# =============================================================================
#
# A stub `claude` whose `init` event reports an `apiKeySource` the caller can
# either let fall out of its own environment (so a forced lane's own `env -u
# ANTHROPIC_API_KEY` is observable) or override outright (so the mismatch and
# managed-key cases can be driven without actually faking a real credential).
# `STUB_HOLD` keeps the process alive a few seconds after its `init` line so
# the 2-second poll loop gets a chance to read and act on it before the stub
# exits on its own — the same reason test/stage-watchdog.test.sh's "rejected"
# mode sleeps after its own rate-limit event.
mkdir -p "$tmp_dir/lane-bin"
cat >"$tmp_dir/lane-bin/claude" <<'STUB'
#!/usr/bin/env bash
cat > /dev/null
src="${STUB_INIT_SOURCE:-}"
if [[ -z "$src" ]]; then
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then src="ANTHROPIC_API_KEY"; else src="none"; fi
fi
printf '%s\n' "{\"type\":\"system\",\"subtype\":\"init\",\"apiKeySource\":\"$src\"}"
if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then echo present >"$STUB_CAPTURE/key.seen"; else echo absent >"$STUB_CAPTURE/key.seen"; fi
sleep "${STUB_HOLD:-3}"
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
STUB
chmod +x "$tmp_dir/lane-bin/claude"
export PATH="$tmp_dir/lane-bin:$PATH"

# A real subscription credential (a file-existence check, never a live
# `claude auth status` call — lib/substrate-claude-code.sh's own
# `substrate_claude_code_lane_present` header) and one that is absent.
sub_present_dir="$tmp_dir/sub-present-claude-config"
mkdir -p "$sub_present_dir"
printf '{}' >"$sub_present_dir/.credentials.json"
sub_absent_dir="$tmp_dir/sub-absent-claude-config"
mkdir -p "$sub_absent_dir"

# Fleet-union call-count instrumentation: `run_model_stage`/`stage_lane_draw`
# read no ledger at all, so every reader the real fleet union is behind stays
# at zero through every scenario below, this file's own stub adapters from
# parts 1-5 included (the acceptance criterion is "no read", not "no read
# during this one scenario").
union_stream_calls=0
union_stream() { union_stream_calls=$(( union_stream_calls + 1 )); }
fleet_logs_calls=0
fleet_logs() { fleet_logs_calls=$(( fleet_logs_calls + 1 )); }

# --- 6a. The draw itself: reproducible, and splits by weight -----------------
export ANTHROPIC_API_KEY="sk-ant-test-placeholder"
export CLAUDE_CONFIG_DIR="$sub_present_dir"
PROVIDER_LANES[anthropic]='{"api":{"weight":2,"enabled":true},"subscription":{"weight":1,"enabled":true}}'

assert_eq "the same seed always draws the same lane" \
  "$(stage_lane_draw anthropic claude-code 'repeat-me')" \
  "$(stage_lane_draw anthropic claude-code 'repeat-me')"

api_draws=0
sub_draws=0
for ((i = 0; i < 300; i++)); do
  case "$(stage_lane_draw anthropic claude-code "fixture-seed-$i")" in
    api) api_draws=$(( api_draws + 1 )) ;;
    subscription) sub_draws=$(( sub_draws + 1 )) ;;
  esac
done
api_pct=$(( api_draws * 100 / 300 ))
assert_eq "300 seeds at weight 2:1 split within ten points of the 66.7% api would need" \
  "within tolerance" \
  "$(if (( api_pct >= 57 && api_pct <= 77 )); then echo "within tolerance"; else echo "$api_pct% api, outside 57-77%"; fi)"
assert_eq "...and every one of the 300 drawn lanes was one of the two configured" \
  "300" "$(( api_draws + sub_draws ))"

# --- 6a1. The shipped lanes block draws the split its own weights state -----
# Read back through `providers_load`, the resolution every cycle script uses,
# rather than repeated, so the credit mix's change of weights (#2238: 1:1,
# then 1:9) needs no change here. Run in a subshell, because providers_load
# replaces PROVIDER_LANES and the scenarios below set their own. Both
# credentials are present, as on a node that holds the key.
shipped_draw="$(
  providers_load "$(jq -c '.providers' "$SCRIPT_DIR/config.json")"
  lanes="${PROVIDER_LANES[anthropic]}"
  w_api="$(jq -r '.api.weight' <<<"$lanes")"
  w_sub="$(jq -r '.subscription.weight' <<<"$lanes")"
  api_n=0 sub_n=0
  for ((i = 0; i < 300; i++)); do
    case "$(stage_lane_draw anthropic claude-code "shipped-seed-$i")" in
      api) api_n=$(( api_n + 1 )) ;;
      subscription) sub_n=$(( sub_n + 1 )) ;;
    esac
  done
  printf '%s %s %s %s\n' "$w_api" "$w_sub" "$api_n" "$sub_n"
)"
read -r shipped_w_api shipped_w_sub shipped_api_n shipped_sub_n <<<"$shipped_draw"
shipped_want_pct=$(( shipped_w_api * 100 / (shipped_w_api + shipped_w_sub) ))
shipped_api_pct=$(( shipped_api_n * 100 / 300 ))
assert_eq "the shipped lanes block, at ${shipped_w_api}:${shipped_w_sub}, draws api within ten points of ${shipped_want_pct}%" \
  "within tolerance" \
  "$(if (( shipped_api_pct >= shipped_want_pct - 10 && shipped_api_pct <= shipped_want_pct + 10 )); then echo "within tolerance"; else echo "$shipped_api_pct% api"; fi)"
assert_eq "...and draws every lane its weights open at least once" \
  "yes" \
  "$(if (( (shipped_w_api == 0 || shipped_api_n > 0) && (shipped_w_sub == 0 || shipped_sub_n > 0) )); then echo yes; else echo "api $shipped_api_n, subscription $shipped_sub_n"; fi)"
assert_eq "...and every one of the 300 drawn lanes was one of the two configured" \
  "300" "$(( shipped_api_n + shipped_sub_n ))"

# --- 6a1m. The credit mix's live lever outranks config for the keys it names
# (issue #2244, D30) — overlaid once, by providers_apply_mix, before the draw
# ever runs; stage_lane_draw itself knows nothing about fleet/mix.json. Both
# credentials are present throughout (the module-level ANTHROPIC_API_KEY/
# CLAUDE_CONFIG_DIR=$sub_present_dir above 6a), so config alone (1:0, no
# `enabled` set) keeps subscription closed under D4's own "api present wins"
# default — exactly the baseline a live mix flag then opens.

# shellcheck source=lib/mix.sh
. "$SCRIPT_DIR/lib/mix.sh"

mix_gh_backing="$tmp_dir/mix-remote"; mkdir -p "$mix_gh_backing"
mix_gh_stub="$tmp_dir/mix-gh-stub"
cat > "$mix_gh_stub" <<'STUB'
#!/usr/bin/env bash
set -uo pipefail
if [[ "${GH_STUB_MODE:-ok}" == "down" ]]; then
  echo "dial tcp: could not resolve host github.com" >&2
  exit 1
fi
backing="${GH_STUB_BACKING:?}"
method=GET path="" jq_expr=""
declare -A f=()
args=("$@"); i=0
while (( i < ${#args[@]} )); do
  a="${args[$i]}"
  case "$a" in
    -X)      i=$((i+1)); method="${args[$i]}" ;;
    --jq)    i=$((i+1)); jq_expr="${args[$i]}" ;;
    -f)      i=$((i+1)); kv="${args[$i]}"; f["${kv%%=*}"]="${kv#*=}" ;;
    repos/*) path="$a" ;;
  esac
  i=$((i+1))
done
if [[ "$path" == repos/*/* && "$path" != */contents/* ]]; then
  echo '{}'
  exit 0
fi
rel="${path#repos/*/*/contents/}"; rel="${rel%%\?*}"
file="$backing/$rel"
sha_of() { sha1sum "$1" | awk '{print $1}'; }
case "$method" in
  GET)
    [[ -f "$file" ]] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    if [[ "$jq_expr" == ".sha" ]]; then sha_of "$file"; exit 0; fi
    jq -n --arg c "$(base64 -w0 < "$file")" --arg s "$(sha_of "$file")" '{content: $c, sha: $s}'
    ;;
  PUT)
    if [[ -f "$file" ]]; then
      [[ "${f[sha]:-}" == "$(sha_of "$file")" ]] || { echo "gh: sha mismatch (HTTP 409)" >&2; exit 1; }
    elif [[ -n "${f[sha]:-}" ]]; then
      echo "gh: sha given for a missing file (HTTP 422)" >&2; exit 1
    fi
    mkdir -p "$(dirname "$file")"
    printf '%s' "${f[content]:?}" | base64 -d > "$file"
    ;;
  DELETE)
    [[ -f "$file" ]] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
    [[ "${f[sha]:-}" == "$(sha_of "$file")" ]] || { echo "gh: sha mismatch (HTTP 409)" >&2; exit 1; }
    rm -f "$file"
    ;;
esac
STUB
chmod +x "$mix_gh_stub"
mix_slug="example/agent-ops-state"
mix_fs="$tmp_dir/mix-state"; mkdir -p "$mix_fs"

# Config alone, no flag at all: 1:0, unset enabled — every draw lands on api.
PROVIDER_LANES=()
providers_load '{}'
config_api_n=0 config_sub_n=0
for ((i = 0; i < 30; i++)); do
  case "$(stage_lane_draw anthropic claude-code "mix-config-seed-$i")" in
    api) config_api_n=$(( config_api_n + 1 )) ;;
    subscription) config_sub_n=$(( config_sub_n + 1 )) ;;
  esac
done
assert_eq "config alone (1:0, unset enabled): every draw lands on api" \
  "30 0" "$config_api_n $config_sub_n"

# A live mix flag moves to 1:1 and opens subscription explicitly.
mix_overlay="$(mix_build_overlay anthropic "api=1" "subscription=1" "subscription.enabled=true")"
TOGGLE_GH="$mix_gh_stub" GH_STUB_BACKING="$mix_gh_backing" \
  mix_write "$mix_slug" "$mix_fs" anthropic "$mix_overlay" "operator pid 1" "operator" >/dev/null
TOGGLE_GH="$mix_gh_stub" GH_STUB_BACKING="$mix_gh_backing" \
  providers_apply_mix "$mix_slug" "$mix_fs"

mix_api_n=0 mix_sub_n=0
for ((i = 0; i < 300; i++)); do
  case "$(stage_lane_draw anthropic claude-code "mix-flag-seed-$i")" in
    api) mix_api_n=$(( mix_api_n + 1 )) ;;
    subscription) mix_sub_n=$(( mix_sub_n + 1 )) ;;
  esac
done
mix_api_pct=$(( mix_api_n * 100 / 300 ))
assert_eq "a live 1:1 mix flag splits the seeded draw within tolerance of 1:1" \
  "within tolerance" \
  "$(if (( mix_api_pct >= 40 && mix_api_pct <= 60 )); then echo "within tolerance"; else echo "$mix_api_pct% api, outside 40-60%"; fi)"

# The flag unreadable (state repo down, a fresh state_dir with no cache at
# all): falls back to config exactly as if the flag had never been set.
PROVIDER_LANES=()
providers_load '{}'
mix_fs_down="$tmp_dir/mix-state-down"; mkdir -p "$mix_fs_down"
GH_STUB_MODE=down TOGGLE_GH="$mix_gh_stub" GH_STUB_BACKING="$mix_gh_backing" \
  providers_apply_mix "$mix_slug" "$mix_fs_down"
down_api_n=0 down_sub_n=0
for ((i = 0; i < 30; i++)); do
  case "$(stage_lane_draw anthropic claude-code "mix-down-seed-$i")" in
    api) down_api_n=$(( down_api_n + 1 )) ;;
    subscription) down_sub_n=$(( down_sub_n + 1 )) ;;
  esac
done
assert_eq "an unreadable flag falls back to config: every draw lands on api" \
  "30 0" "$down_api_n $down_sub_n"

# --reset withdraws the lever explicitly, rather than merely going
# unreachable — the same fallback either way.
TOGGLE_GH="$mix_gh_stub" GH_STUB_BACKING="$mix_gh_backing" \
  mix_reset "$mix_slug" "$mix_fs" anthropic "operator pid 2" >/dev/null
PROVIDER_LANES=()
providers_load '{}'
TOGGLE_GH="$mix_gh_stub" GH_STUB_BACKING="$mix_gh_backing" \
  providers_apply_mix "$mix_slug" "$mix_fs"
reset_api_n=0 reset_sub_n=0
for ((i = 0; i < 30; i++)); do
  case "$(stage_lane_draw anthropic claude-code "mix-reset-seed-$i")" in
    api) reset_api_n=$(( reset_api_n + 1 )) ;;
    subscription) reset_sub_n=$(( reset_sub_n + 1 )) ;;
  esac
done
assert_eq "after --reset, every draw lands on api again" \
  "30 0" "$reset_api_n $reset_sub_n"

# --- 6a2. The seed is the launch's own identifier, not just the stage name -
# review round on PR #2385: review-cycle.sh and monitor-cycle.sh never set
# `cycle_id` (only agent-cycle.sh does), so before that fix every launch of
# theirs seeded on the constant string "" (empty `cycle_id`) and `:$stage`
# alone — every review-cycle.sh launch of the same stage name drew the same
# lane forever, fleet-wide, however many distinct repos or runs it covered.
# This reproduces review-cycle.sh's own per-repo loop shape: one process,
# one stage name ("reviewer"), several repos sharing a single $review_id,
# each setting `cycle_id="$review_id:$slug"` (review-cycle.sh's own fix)
# immediately before calling `run_model_stage`. Two repos under the *same*
# review_id land on different lanes below — proof the slug, not merely the
# stage name, reaches the seed.
PROVIDER_LANES[anthropic]='{"api":{"weight":2,"enabled":true},"subscription":{"weight":1,"enabled":true}}'
review_id="fixture-review-1"
for slug in alpha beta; do
  cycle_id="$review_id:$slug"
  expect_lane="$(stage_lane_draw anthropic claude-code "$cycle_id:reviewer")"
  run_capture="$tmp_dir/lane-6a2-review-$slug"
  mkdir -p "$run_capture"
  STUB_CAPTURE="$run_capture" STUB_HOLD=0 \
    run_model_stage reviewer 60 claude-sonnet-5 "irrelevant" \
    "$run_capture/reviewer.out" "$run_capture"
  assert_eq "review-cycle-shaped launch for $review_id:$slug lands on the seeded draw's own output" \
    "$expect_lane" "$stage_lane"
done
assert_eq "...and the two repos under the same review_id drew different lanes" \
  "subscription then api" \
  "$(stage_lane_draw anthropic claude-code "$review_id:alpha:reviewer") then $(stage_lane_draw anthropic claude-code "$review_id:beta:reviewer")"

# monitor-cycle.sh's own fix: `cycle_id="$monitor_id"`, one launch per
# process. Two different monitor_id values draw different lanes below —
# proof the run's own identity reaches the seed there too, not a constant.
for monitor_id in fixture-monitor-1 fixture-monitor-3; do
  cycle_id="$monitor_id"
  expect_lane="$(stage_lane_draw anthropic claude-code "$cycle_id:monitor")"
  run_capture="$tmp_dir/lane-6a2-monitor-$monitor_id"
  mkdir -p "$run_capture"
  STUB_CAPTURE="$run_capture" STUB_HOLD=0 \
    run_model_stage monitor 60 claude-sonnet-5 "irrelevant" \
    "$run_capture/monitor.out" "$run_capture"
  assert_eq "monitor-cycle-shaped launch for $monitor_id lands on the seeded draw's own output" \
    "$expect_lane" "$stage_lane"
done
assert_eq "...and the two monitor_id values drew different lanes" \
  "api then subscription" \
  "$(stage_lane_draw anthropic claude-code "fixture-monitor-1:monitor") then $(stage_lane_draw anthropic claude-code "fixture-monitor-3:monitor")"

# The two assertions above drive the launcher with `cycle_id` set by *this
# file*, which is the behaviour half of the claim. The structural half is the
# shipped scripts: the seed reads a global each pipeline has to remember to
# set, and `${cycle_id:-}` keeps `set -u` quiet about one that forgot — which
# is precisely how review-cycle.sh and monitor-cycle.sh came to seed every
# launch on the same constant string. So assert over the scripts themselves,
# the way test/stage-prompt-delivery.test.sh asserts no cycle script grew its
# own `run_model_stage` back: deleting either assignment must fail a test
# rather than silently returning the fleet to one lane forever.
for cyc_script in agent-cycle.sh review-cycle.sh monitor-cycle.sh; do
  seed_assign="$(grep -n '^[[:space:]]*cycle_id=' "$SCRIPT_DIR/$cyc_script" | head -1)"
  assert_eq "$cyc_script assigns the \`cycle_id\` lib/stage-run.sh's lane seed reads" \
    "assigned" "$([[ -n "$seed_assign" ]] && echo assigned || echo 'never assigned')"
  # A constant would be as broken as an unset variable, so the value has to
  # expand something — this launch's own date/pid, review id, repo slug.
  assert_eq "...from a per-launch expansion rather than a constant" \
    "expands" "$([[ "$seed_assign" == *'$'* ]] && echo expands || echo "no expansion in: ${seed_assign:-<nothing>}")"
  # agent-cycle.sh reaches the launcher through the libs it sources
  # (lib/coordinator-phase.sh, lib/enabler.sh, …) rather than calling it
  # itself, so only the two scripts that call it directly can be ordered.
  # 0 for "no such line" keeps the arithmetic below well-formed on exactly
  # the regression this guards: an assignment deleted, the call still there.
  seed_call="$(grep -n '^[[:space:]]*\(if \)\?run_model_stage ' "$SCRIPT_DIR/$cyc_script" | head -1)"
  seed_assign_line="${seed_assign%%:*}"
  seed_call_line="${seed_call%%:*}"
  if [[ -n "$seed_call_line" ]]; then
    assert_eq "...before $cyc_script's own run_model_stage call" \
      "before" \
      "$(if (( ${seed_assign_line:-0} > 0 && ${seed_assign_line:-0} < seed_call_line )); then echo before
         else echo "assigned at line ${seed_assign_line:-none}, called at line $seed_call_line"; fi)"
  fi
done

# --- 6a3. A seed-suffix argument distinguishes several launches of one stage
# within one cycle (issue #2436) --------------------------------------------
# Unlike review-cycle.sh and monitor-cycle.sh above — one stage name per
# process, so `cycle_id` alone already distinguishes every launch —
# agent-cycle.sh's own per-repository loop can launch the coordinator stage
# more than once inside one process, all sharing the one `cycle_id` the
# process set once. `run_coordinator_stage_attempt` (lib/stage-attempt.sh)
# passes its own per-repository `coord_budget_repo` as `run_model_stage`'s
# trailing seed-suffix argument for exactly this reason; the Approver's own
# per-pull-request loop (lib/approver.sh), and the landing gate's own
# `run_open_question_adjudication` (lib/landing.sh, issue #2462), pass
# `$pr_url` the same way. This drives `run_model_stage` directly with that
# per-repository shape, since
# exercising `run_coordinator_stage_attempt` itself needs machinery
# (stage_budget_apply, log_event, …) this file never sources.
cycle_id="fixture-cycle-6a3"
for repo in alpha beta; do
  expect_lane="$(stage_lane_draw anthropic claude-code "$cycle_id:coordinator:$repo")"
  run_capture="$tmp_dir/lane-6a3-$repo"
  mkdir -p "$run_capture"
  STUB_CAPTURE="$run_capture" STUB_HOLD=0 \
    run_model_stage coordinator 60 claude-sonnet-5 "irrelevant" \
    "$run_capture/coordinator.out" "$run_capture" "" "" "" "$repo"
  assert_eq "coordinator-shaped launch for repo $repo lands on the seeded draw's own output" \
    "$expect_lane" "$stage_lane"
done
assert_eq "...and the two repos under the same cycle_id drew different lanes" \
  "subscription then api" \
  "$(stage_lane_draw anthropic claude-code "$cycle_id:coordinator:alpha") then $(stage_lane_draw anthropic claude-code "$cycle_id:coordinator:beta")"
# The bug this closes: with no seed suffix, every repository's own launch
# seeds on the identical string ("$cycle_id:coordinator" names no repository
# at all), so both of the distinct draws above would instead collapse onto
# this one shared value.
assert_eq "...whereas the undifferentiated cycle-and-stage seed draws just one lane for both" \
  "api" \
  "$(stage_lane_draw anthropic claude-code "$cycle_id:coordinator")"

# --- 6a3b. The landing gate's own per-pull-request loop draws independently
# too (issue #2462) -----------------------------------------------------------
# The 2.1e landing-retry sweep can enter the landing gate for more than one
# pull request within one cycle, and `run_open_question_adjudication`
# (lib/landing.sh) launches the approver-adjudicate-open-question stage once
# per pull request it adjudicates, all sharing the one `cycle_id` the cycle
# set once — the same shape 6a3 above already covers for the Co-Ordinator's
# per-repository loop, this time for a third caller passing `$pr_url` as the
# trailing seed-suffix argument.
cycle_id="fixture-cycle-6a3b"
pr_url_1="https://github.com/acme/widgets/pull/1"
pr_url_2="https://github.com/acme/widgets/pull/3"
for pr_url in "$pr_url_1" "$pr_url_2"; do
  expect_lane="$(stage_lane_draw anthropic claude-code "$cycle_id:approver-adjudicate-open-question:$pr_url")"
  run_capture="$tmp_dir/lane-6a3b-$(basename "$pr_url")"
  mkdir -p "$run_capture"
  STUB_CAPTURE="$run_capture" STUB_HOLD=0 \
    run_model_stage approver-adjudicate-open-question 60 claude-sonnet-5 "irrelevant" \
    "$run_capture/approver-adjudicate-open-question.out" "$run_capture" "" "" "" "$pr_url"
  assert_eq "adjudication launch for pull request $pr_url lands on the seeded draw's own output" \
    "$expect_lane" "$stage_lane"
done
assert_eq "...and the two pull requests under the same cycle_id drew different lanes" \
  "api then subscription" \
  "$(stage_lane_draw anthropic claude-code "$cycle_id:approver-adjudicate-open-question:$pr_url_1") then $(stage_lane_draw anthropic claude-code "$cycle_id:approver-adjudicate-open-question:$pr_url_2")"
# The bug this closes: with no seed suffix, every pull request's own launch
# seeds on the identical string ("$cycle_id:approver-adjudicate-open-question"
# names no pull request at all), so both of the distinct draws above would
# instead collapse onto this one shared value.
assert_eq "...whereas the undifferentiated cycle-and-stage seed draws just one lane for both" \
  "subscription" \
  "$(stage_lane_draw anthropic claude-code "$cycle_id:approver-adjudicate-open-question")"

# --- 6b. End-to-end: run_model_stage lands on exactly what the draw dictates -
cycle_id="fixture-cycle-6b"
for stagename in implementer reviewer enabler refiner; do
  expect_lane="$(stage_lane_draw anthropic claude-code "$cycle_id:$stagename")"
  run_capture="$tmp_dir/lane-6b-$stagename"
  mkdir -p "$run_capture"
  STUB_CAPTURE="$run_capture" STUB_HOLD=0 \
    run_model_stage "$stagename" 60 claude-sonnet-5 "irrelevant" \
    "$run_capture/$stagename.out" "$run_capture"
  assert_eq "run_model_stage's own $stagename launch lands on the seeded draw's own output" \
    "$expect_lane" "$stage_lane"
done

# --- 6c. Weight 1:0 (api only, with both credentials): every stage runs api -
PROVIDER_LANES[anthropic]='{"api":{"weight":1,"enabled":null},"subscription":{"weight":0,"enabled":null}}'
for stagename in a b c; do
  run_capture="$tmp_dir/lane-6c-$stagename"
  mkdir -p "$run_capture"
  STUB_CAPTURE="$run_capture" STUB_HOLD=0 \
    run_model_stage "$stagename" 60 claude-sonnet-5 "irrelevant" \
    "$run_capture/$stagename.out" "$run_capture"
  assert_eq "weight 1:0 with both credentials present: $stagename lands on api" \
    "api" "$stage_lane"
  assert_eq "...and ANTHROPIC_API_KEY reached the stub, unforced" \
    "present" "$(cat "$run_capture/key.seen" 2>/dev/null)"
done

# --- 6d. Only a login present: every stage runs subscription whatever weight
saved_key="$ANTHROPIC_API_KEY"
unset ANTHROPIC_API_KEY
PROVIDER_LANES[anthropic]='{"api":{"weight":5,"enabled":null},"subscription":{"weight":1,"enabled":null}}'
for stagename in a b; do
  run_capture="$tmp_dir/lane-6d-$stagename"
  mkdir -p "$run_capture"
  STUB_CAPTURE="$run_capture" STUB_HOLD=0 \
    run_model_stage "$stagename" 60 claude-sonnet-5 "irrelevant" \
    "$run_capture/$stagename.out" "$run_capture"
  assert_eq "only a login present: $stagename lands on subscription whatever the weights" \
    "subscription" "$stage_lane"
  assert_eq "...and ANTHROPIC_API_KEY never reached the stub" \
    "absent" "$(cat "$run_capture/key.seen" 2>/dev/null)"
done
export ANTHROPIC_API_KEY="$saved_key"

# --- 6e. Both credentials, no lanes block at all: api always, subscription
#         never forced -------------------------------------------------------
unset 'PROVIDER_LANES[anthropic]'
for stagename in a b; do
  run_capture="$tmp_dir/lane-6e-$stagename"
  mkdir -p "$run_capture"
  STUB_CAPTURE="$run_capture" STUB_HOLD=0 \
    run_model_stage "$stagename" 60 claude-sonnet-5 "irrelevant" \
    "$run_capture/$stagename.out" "$run_capture"
  assert_eq "no lanes block at all, both credentials present: $stagename lands on api" \
    "api" "$stage_lane"
  assert_eq "...and the subscription lane's env -u ANTHROPIC_API_KEY never ran" \
    "present" "$(cat "$run_capture/key.seen" 2>/dev/null)"
done
PROVIDER_LANES[anthropic]='{"api":{"weight":2,"enabled":true},"subscription":{"weight":1,"enabled":true}}'

# --- 6f. A forced lane bypasses the draw -------------------------------------
forced_capture="$tmp_dir/lane-6f"
mkdir -p "$forced_capture"
STUB_CAPTURE="$forced_capture" STUB_HOLD=0 \
  run_model_stage forced-stage 60 claude-sonnet-5 "irrelevant" \
  "$forced_capture/out" "$forced_capture" 0 "" subscription
assert_eq "an explicit lane argument is forced outright, never drawn" \
  "subscription" "$stage_lane"
assert_eq "...confirmed by the env the stub actually saw" \
  "absent" "$(cat "$forced_capture/key.seen" 2>/dev/null)"

# An override naming a lane this node holds no credential for is a refusal,
# never a silent fall-through to the unmanaged path 6e already covers — a
# caller that named a lane explicitly (requirement 2.1b's probe, doctor's own
# per-lane check) gets either that lane or a clear "no open lane", never its
# request quietly ignored because nothing else happened to be present either.
forced_absent_capture="$tmp_dir/lane-6f-absent"
mkdir -p "$forced_absent_capture"
saved_key_6f="$ANTHROPIC_API_KEY"
unset ANTHROPIC_API_KEY
export CLAUDE_CONFIG_DIR="$sub_absent_dir"
STUB_CAPTURE="$forced_absent_capture" STUB_HOLD=0 \
  run_model_stage forced-absent 60 claude-sonnet-5 "irrelevant" \
  "$forced_absent_capture/out" "$forced_absent_capture" 0 "" api
forced_absent_rc=$?
assert_eq "forcing a lane with no credential for it refuses, rather than launching unmanaged" \
  "1" "$forced_absent_rc"
assert_eq "...attributed to no-open-lane" \
  "no-open-lane" "$stage_kill_reason"
export ANTHROPIC_API_KEY="$saved_key_6f"
export CLAUDE_CONFIG_DIR="$sub_present_dir"

# --- 6g. A genuine mismatch stops the stage at its init event ---------------
mismatch_capture="$tmp_dir/lane-6g"
mkdir -p "$mismatch_capture"
STUB_CAPTURE="$mismatch_capture" STUB_HOLD=5 STUB_INIT_SOURCE=ANTHROPIC_API_KEY \
  run_model_stage mismatched 60 claude-sonnet-5 "irrelevant" \
  "$mismatch_capture/out" "$mismatch_capture" 0 "" subscription
mismatch_rc=$?
assert_eq "a forced lane the init event contradicts stops the stage at once" \
  "124" "$mismatch_rc"
assert_eq "...attributed to a lane mismatch, not a cap" \
  "lane-mismatch" "$stage_kill_reason"
assert_eq "...naming the forced and the observed lane for the record" \
  '{"forced":"subscription","observed":"api"}' "$stage_lane_mismatch_json"
assert_contains "...and earns a warning naming the mismatch" \
  "does not match the lane it was launched on" "$(stage_watchdog_warning mismatched)"

# ...and the node stands itself down over it: the local switch
# (state_dir/disabled.json, kind "auto", scope "node"), so every further
# cycle on this node refuses to run until a human clears it.
mismatch_state_dir="$tmp_dir/lane-6g-state"
mkdir -p "$mismatch_state_dir"
stage_lane_mismatch_standdown "$mismatch_state_dir" mismatched
assert_eq "a lane mismatch writes the local switch, kind auto" \
  "auto" "$(jq -r '.kind' "$mismatch_state_dir/disabled.json" 2>/dev/null)"
assert_eq "...scoped to this node, never the fleet" \
  "node" "$(jq -r '.scope' "$mismatch_state_dir/disabled.json" 2>/dev/null)"
assert_eq "...indefinite: nothing here can derive a TTL to expire it against" \
  "null" "$(jq -c '.expires_at' "$mismatch_state_dir/disabled.json" 2>/dev/null)"
assert_contains "...naming the mismatch in its own reason" \
  "forced subscription, observed api" "$(jq -r '.reason' "$mismatch_state_dir/disabled.json" 2>/dev/null)"
clean_after_mismatch_capture="$tmp_dir/lane-6g-clean"
mkdir -p "$clean_after_mismatch_capture"
STUB_CAPTURE="$clean_after_mismatch_capture" STUB_HOLD=0 \
  run_model_stage clean-after-mismatch 60 claude-sonnet-5 "irrelevant" \
  "$clean_after_mismatch_capture/out" "$clean_after_mismatch_capture"
assert_eq "a run that was not a lane mismatch writes no switch at all" \
  "1" "$(stage_lane_mismatch_standdown "$tmp_dir/lane-6g-state-unused" clean-after-mismatch >/dev/null 2>&1; echo $?)"

# --- 6h. A managed-key login is the documented soft case, not a mismatch ----
managed_capture="$tmp_dir/lane-6h"
mkdir -p "$managed_capture"
SUBSTRATE_CLAUDE_CODE_SUBSCRIPTION_MANAGED_KEY=0
STUB_CAPTURE="$managed_capture" STUB_HOLD=3 STUB_INIT_SOURCE="/login managed key" \
  run_model_stage managed 60 claude-sonnet-5 "irrelevant" \
  "$managed_capture/out" "$managed_capture" 0 "" subscription
managed_rc=$?
assert_eq "a managed-key login does not stop the stage" "0" "$managed_rc"
assert_eq "...and carries no kill reason" "" "$stage_kill_reason"
managed_warning="$(stage_watchdog_warning managed)"
assert_contains "...but earns a one-time warning naming the Console login" \
  "Console login" "$managed_warning"

# ...and the very next launch in this cycle draws `api`: the subscription
# lane closed the moment the managed key was discovered, so the weighted
# 2:1-favouring-api config above now has only one open lane to draw from,
# whatever its own weight says.
after_managed_capture="$tmp_dir/lane-6h-next"
mkdir -p "$after_managed_capture"
STUB_CAPTURE="$after_managed_capture" STUB_HOLD=0 \
  run_model_stage after-managed 60 claude-sonnet-5 "irrelevant" \
  "$after_managed_capture/out" "$after_managed_capture"
assert_eq "the next launch in the cycle draws api, the subscription lane now closed" \
  "api" "$stage_lane"
assert_eq "...and earns no managed-key warning of its own: it was not the run that discovered it" \
  "" "$(stage_watchdog_warning after-managed || true)"
SUBSTRATE_CLAUDE_CODE_SUBSCRIPTION_MANAGED_KEY=0

# --- 6i. A credential present but configured into total unavailability
#         refuses to launch at all, rather than running unmanaged ------------
# Distinct from 6e's "neither credential present at all", which launches
# unmanaged on purpose (run_model_stage's own "Presence" paragraph) — here
# ANTHROPIC_API_KEY *is* present, so there is something to manage, and the
# operator has configured both lanes closed.
noopen_capture="$tmp_dir/lane-6i"
mkdir -p "$noopen_capture"
export CLAUDE_CONFIG_DIR="$sub_absent_dir"
PROVIDER_LANES[anthropic]='{"api":{"weight":0,"enabled":false},"subscription":{"weight":0,"enabled":false}}'
STUB_CAPTURE="$noopen_capture" STUB_HOLD=0 \
  run_model_stage noopen 60 claude-sonnet-5 "irrelevant" \
  "$noopen_capture/out" "$noopen_capture"
noopen_rc=$?
assert_eq "a present credential configured into total unavailability refuses to launch" \
  "1" "$noopen_rc"
assert_eq "...attributed to no-open-lane, not a cap" \
  "no-open-lane" "$stage_kill_reason"
assert_eq "...and the stub was never actually invoked" \
  "0" "$(wc -c < "$noopen_capture/out" 2>/dev/null || echo 1)"
assert_contains "...which earns a warning naming the provider with no open lane" \
  "no lane is open for provider anthropic" "$(stage_watchdog_warning noopen)"
export CLAUDE_CONFIG_DIR="$sub_present_dir"
PROVIDER_LANES[anthropic]='{"api":{"weight":2,"enabled":true},"subscription":{"weight":1,"enabled":true}}'

# --- 6j. A weighted model set (issue #2247): the model is drawn before the
#         lane, by the same seeded rule stage_lane_draw already uses --------
# Both credentials present throughout (module-level ANTHROPIC_API_KEY/
# CLAUDE_CONFIG_DIR=$sub_present_dir above 6a); xai is configured with the
# grok-build substrate, which has no lane_present function of its own, so a
# grok-4.7 member is never screened or excluded for a lane reason (today only
# claude-code manages lanes at all — run_model_stage's own "Presence"
# paragraph).
providers_load "$(jq -nc '{xai: {substrate: "grok-build"}}')"
# shellcheck disable=SC2154  # mix_model_key: assigned by model_key_load_into below, the assigning form
model_key_load_into mix_model_key mix_model_key \
  '{"models": [{"id": "claude-sonnet-5", "weight": 2}, {"id": "xai/grok-4.7", "weight": 1}]}'

# Six seeds chosen (by brute-force search over the same cksum-mod-total-
# weight-then-bucket draw, never adjusted after the fact) to land exactly
# 4:2 — a 2:1 weighted set drawn six times splits in that ratio, the same
# way "fixture-seed-$i" above exercises stage_lane_draw's own weights rather
# than merely asserting a statistical tolerance.
mix_sonnet_n=0
mix_grok_n=0
for ((i = 1; i <= 6; i++)); do
  # shellcheck disable=SC2154  # mix_model_key: assigned by model_key_load_into above, the assigning form
  stage_model_resolve_into mix_drawn "$mix_model_key" "fixture-model-seed-$i"
  # shellcheck disable=SC2154  # mix_drawn: assigned by stage_model_resolve_into just above, the assigning form
  case "$mix_drawn" in
    claude-sonnet-5) mix_sonnet_n=$(( mix_sonnet_n + 1 )) ;;
    grok-4.7) mix_grok_n=$(( mix_grok_n + 1 )) ;;
  esac
done
assert_eq "a 2:1 set over an empty window splits six stages 4:2" \
  "4 2" "$mix_sonnet_n $mix_grok_n"
assert_eq "...each draw recorded its own qualified member on STAGE_MODEL_SET_EXTRA_JSON" \
  "mix_model_key" "$(jq -r '.model_set' <<<"$STAGE_MODEL_SET_EXTRA_JSON")"
assert_eq "...and an ordinary (non-set) value resolves unchanged, with no extra fields" \
  "claude-sonnet-5 {}" \
  "$(stage_model_resolve_into plain_drawn claude-sonnet-5 'irrelevant-seed'
     # shellcheck disable=SC2154  # plain_drawn: assigned by stage_model_resolve_into just above
     printf '%s %s' "$plain_drawn" "$STAGE_MODEL_SET_EXTRA_JSON")"

# --- 6j1. A member whose only lane is closed is skipped for the next -------
# anthropic's only credential, the subscription one (CLAUDE_CONFIG_DIR
# below points at an empty directory — 6e's own "absent" fixture, reused
# read-only), is absent; grok-4.7 is still always available (no lane
# management for grok-build at all), so every draw of this 5:1 set — heavily
# weighted toward the now-closed sonnet member — settles on grok-4.7
# regardless of seed.
export CLAUDE_CONFIG_DIR="$sub_absent_dir"
unset ANTHROPIC_API_KEY
# shellcheck disable=SC2154  # mix_closed_key: assigned by model_key_load_into below, the assigning form
model_key_load_into mix_closed_key mix_closed_key \
  '{"models": [{"id": "claude-sonnet-5", "weight": 5}, {"id": "xai/grok-4.7", "weight": 1}]}'
mix_closed_all_grok=1
for ((i = 1; i <= 5; i++)); do
  # shellcheck disable=SC2154  # mix_closed_key: assigned by model_key_load_into above, the assigning form
  stage_model_resolve_into mix_closed_drawn "$mix_closed_key" "closed-lane-seed-$i"
  # shellcheck disable=SC2154  # mix_closed_drawn: assigned by stage_model_resolve_into just above
  [[ "$mix_closed_drawn" == "grok-4.7" ]] || mix_closed_all_grok=0
done
assert_eq "a member whose only lane is closed is skipped for the next, every time" \
  "1" "$mix_closed_all_grok"
export ANTHROPIC_API_KEY="sk-ant-test-placeholder"
export CLAUDE_CONFIG_DIR="$sub_present_dir"
providers_load "null"

# --- 6k. The fleet union is never read, through every scenario above --------
assert_eq "run_model_stage/stage_lane_draw read the union stream zero times" \
  "0" "$union_stream_calls"
assert_eq "...and the fleet's own per-node logs zero times" \
  "0" "$fleet_logs_calls"

unset ANTHROPIC_API_KEY CLAUDE_CONFIG_DIR
unset 'PROVIDER_LANES[anthropic]'

printf '\n'
if (( failures )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
