#!/usr/bin/env bash
#
# test/standdown-credential-preflight.test.sh — regression test for
# requirement 2.0h's model-credential preflight in lib/standdown.sh
# (agent-ops#2308): not whether `stage_api_refusal_class` classifies a
# refusal correctly (test/stage-api-refusal.test.sh covers that in
# isolation) but whether the cycle actually acts on the classification —
# standing down with the API's own words as the reason and escalating,
# before the GitHub gather or the Co-Ordinator ever runs — and whether the
# probe itself is skipped once a healthy node has already paid for one this
# container's lifetime.
#
# The incident this guards: on 2026-10-10 an `ANTHROPIC_API_KEY` minted
# without a workspace scope crash-looped all four fleet nodes for eleven
# hours, every cycle running a full GitHub gather before the Co-Ordinator was
# refused in about a second — nothing probed the credential ahead of the
# gather the way requirement 2.0b already does for `GH_TOKEN`.
#
# The block is lifted verbatim out of lib/standdown.sh, the same way
# test/auth-failure-wiring.test.sh lifts 2.0b's own, so the assertions are
# about the shipped code rather than a copy of its logic. `run_model_stage`
# and `_updater_health_own_started` are stubbed (no network, no real
# container clock); `stage_api_refusal`/`_class`/`_message` are the real
# functions from lib/stage-attempt.sh, sourced directly, so this test
# exercises the genuine classification the shipped preflight depends on.
#
# This file also covers the retirement path #2414 added:
# `credential_refused_retire_resolved` (lib/enabler.sh) is stubbed the same
# way `create_escalation_issue` is, so these assertions are about whether
# the shipped block *calls* the retirement function with the right
# arguments at the right transition, not about what `gh issue close` itself
# does — the same division of labour `test/crash-loop.test.sh` draws around
# `crash_loop_retire_resolved`'s own final `gh issue close`.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly: ./test/standdown-credential-preflight.test.sh — exit 0 iff all
# passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STANDDOWN="$SCRIPT_DIR/lib/standdown.sh"

failures=0
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected: %s\n     actual:   %s\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}

# state_verdict STATE_DIR — the "verdict" field run_block's own state file
# (`$state_dir/.credential-preflight.json`) was left holding, read the same
# way the real block reads cred_prev_verdict.
state_verdict() {
  jq -r '.verdict // ""' "$1/.credential-preflight.json" 2>/dev/null
}

extract_block() {
  local start_re="$1" end_re="$2" file="$3"
  BLOCK_START_RE="$start_re" BLOCK_END_RE="$end_re" awk '
    $0 ~ ENVIRON["BLOCK_START_RE"] { on = 1 }
    on                             { print }
    on && $0 ~ ENVIRON["BLOCK_END_RE"] { exit }
  ' "$file"
}

# shellcheck source=lib/stage-attempt.sh
. "$SCRIPT_DIR/lib/stage-attempt.sh"
# shellcheck source=lib/metering.sh
. "$SCRIPT_DIR/lib/metering.sh"

# lib/standdown.sh wraps each stand-down band in its own `_standdown_*`
# helper (issue #2699), so the raw extraction up to 2.1's heading also
# carries this check's own closing `}` and 2.1's own
# `_standdown_usage_limit_cooldown() {` opening line — both stripped below,
# neither is part of the check itself.
cred_block="$(extract_block '^# 2\.0h Model credential check' '^# 2\.1 Usage-limit cooldown' "$STANDDOWN" \
  | grep -vE '^}$|^_standdown_[a-z_]+\(\) \{$')"
if [[ -z "$cred_block" ]]; then
  echo "FAIL - could not extract the model-credential check block from lib/standdown.sh — has it moved?" >&2
  exit 1
fi
if ! grep -q 'run_model_stage credential-probe' <<<"$cred_block"; then
  echo "FAIL - extracted block does not call run_model_stage credential-probe — the anchors matched the wrong text" >&2
  exit 1
fi
if [[ "$cred_block" != *'stage: "credential-probe"'* || "$cred_block" != *'metering_fields'* ]]; then
  echo "FAIL - extracted block does not log a stage-end carrying metering_fields for stage: \"credential-probe\"" >&2
  exit 1
fi

# run_block MODE BOOT_ID DRY_RUN STATE_DIR PROBE_COUNT_FILE ESCALATION_FILE EVENT_FILE [RETIRE_FILE] [RETIRE_RC]
# MODE selects what the stubbed run_model_stage writes to the probe's .out
# file: "ok" (a clean reply), "refused-400" (the workspace-scope 400 the
# 2026-10-10 outage actually returned), or "transient-503" (a 5xx, which
# must not be mistaken for a credential problem). BOOT_ID is fed to the
# stubbed _updater_health_own_started, so two calls sharing one BOOT_ID
# simulate two cycles of the same container's life. RETIRE_FILE (optional,
# defaults to /dev/null) receives one line per call the block makes to the
# stubbed `credential_refused_retire_resolved` (#2414's retirement path).
# RETIRE_RC (optional, defaults to 0) is the exit code that stub returns —
# #2511 added the block's own read of it, to decide whether the state
# file's verdict may advance to "ok" or must stay "refused".
run_block() {
  local mode="$1" boot_id="$2" dry_run="$3" state_dir="$4"
  local probe_count_file="$5" escalation_file="$6" event_file="$7"
  local retire_file="${8:-/dev/null}" retire_rc="${9:-0}"
  : > "$event_file"
  (
    set -euo pipefail
    # shellcheck disable=SC2034  # consumed by $cred_block below, invisible to a static reader
    DRY_RUN="$dry_run"
    # shellcheck disable=SC2034
    crash_loop_repo="acme/agent-ops"
    # shellcheck disable=SC2034
    enabler_assignee="ops-bot"
    # shellcheck disable=SC2034
    enabler_escalation_label="autonomous-agent-escalation"
    # shellcheck disable=SC2034
    cycle_dir="$tmp_dir"
    # shellcheck disable=SC2034
    node_name="test-node"
    # shellcheck disable=SC2034
    cycle_id="20260101T000000Z-test-node-1"
    # state_dir is already in scope here as run_block's own 4th positional
    # parameter (`local … state_dir="$4"`), consumed by $cred_block below.
    # shellcheck disable=SC2034
    implementer_model_trivial="claude-haiku-4-5-20251001"

    # shellcheck disable=SC2317  # called from $cred_block via eval
    _updater_health_own_started() { printf '%s\n' "$BOOT_ID"; }
    export BOOT_ID="$boot_id"

    # shellcheck disable=SC2317  # called from $cred_block via eval
    run_model_stage() {
      echo "call" >> "$PROBE_COUNT_FILE"
      local out_file="$5"
      case "$STUB_CRED_MODE" in
        ok)
          echo '{"is_error":false,"terminal_reason":"completed","result":"ok"}' > "$out_file"
          ;;
        refused-400)
          echo '{"is_error":true,"terminal_reason":"api_error","api_error_status":400,"result":"This API key is not scoped to a workspace, so this request must include the anthropic-workspace-id header with the ID of the workspace to use."}' > "$out_file"
          ;;
        transient-503)
          echo '{"is_error":true,"terminal_reason":"api_error","api_error_status":503,"result":"This is a server-side issue, usually temporary"}' > "$out_file"
          ;;
        refused-credit)
          echo '{"is_error":true,"terminal_reason":"credit_exhausted","api_error_status":429,"result":"Your credit balance is too low to access the Anthropic API."}' > "$out_file"
          ;;
      esac
      # The two caller-visible globals a real run_model_stage launch leaves
      # (lib/stage-run.sh), read back by the credential-probe's own
      # stage-end via metering_fields — set here so $cred_block's log_event
      # call runs under the same `set -u` the real block runs under.
      # shellcheck disable=SC2034
      stage_gaps_json="null"
      # shellcheck disable=SC2034
      stage_lane_json='"api"'
      # shellcheck disable=SC2034
      stage_kill_reason=""
      return 0
    }
    export PROBE_COUNT_FILE="$probe_count_file" STUB_CRED_MODE="$mode"

    # shellcheck disable=SC2317  # called from $cred_block via eval
    create_escalation_issue() {
      { printf 'repo=%s\nitem=%s\nlabel=%s\ntitle=%s\n' "$1" "$2" "$3" "$4"
        echo "---body---"
        cat "$5" 2>/dev/null
        echo "---end---"
      } >> "$ESCALATION_FILE"
      printf '99\thttps://github.com/acme/agent-ops/issues/99'
    }
    export ESCALATION_FILE="$escalation_file"

    # shellcheck disable=SC2317  # called from $cred_block via eval
    credential_refused_retire_resolved() {
      printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$RETIRE_FILE"
      return "$RETIRE_RC"
    }
    export RETIRE_FILE="$retire_file" RETIRE_RC="$retire_rc"

    # shellcheck disable=SC2317  # called from $cred_block via eval
    log_event() { printf '%s\t%s\n' "$1" "${2:-{\}}" >> "$EVENT_FILE"; }
    export EVENT_FILE="$event_file"
    # shellcheck disable=SC2317  # called from $cred_block via eval
    set_node_state_terminal() { printf 'set_node_state_terminal\t%s\t%s\n' "$1" "$2" >> "$EVENT_FILE"; }

    eval "$cred_block"
    printf 'FELL THROUGH\n' >> "$EVENT_FILE"
  )
  printf '%s' "$?"
}

# --- refused (400, no workspace scope): the incident this exists for ---

state_dir="$tmp_dir/state-refused"; mkdir -p "$state_dir"
probe_count="$tmp_dir/refused-probe-count"; : > "$probe_count"
esc_file="$tmp_dir/refused-escalations"; : > "$esc_file"
evt_file="$tmp_dir/refused-events"
block_rc="$(run_block refused-400 boot-1 0 "$state_dir" "$probe_count" "$esc_file" "$evt_file")"

assert_eq "a refused credential stands the cycle down (exit 0, never falls through)" \
  "0" "$block_rc"
assert_eq "…and the block never runs off its own end into the gather" \
  "no" "$(if grep -q 'FELL THROUGH' "$evt_file"; then echo yes; else echo no; fi)"
assert_eq "the probe actually ran" "1" "$(wc -l < "$probe_count" | tr -d ' ')"

stage_end_line="$(grep -m1 '^stage-end' "$evt_file" || true)"
assert_eq "the probe's own spend is logged as a stage-end" \
  "yes" "$(if [[ -n "$stage_end_line" ]]; then echo yes; else echo no; fi)"
assert_eq "…naming stage: credential-probe" \
  "credential-probe" "$(jq -r '.stage' <<<"${stage_end_line#stage-end$'\t'}" 2>/dev/null)"
assert_eq "…with a real exit_code (the stub run_model_stage returns 0)" \
  "0" "$(jq -r '.exit_code' <<<"${stage_end_line#stage-end$'\t'}" 2>/dev/null)"
assert_eq "…carrying the metering fields a real run leaves" \
  "true" "$(jq -r 'has("lane") and has("cost_usd") and has("tokens")' <<<"${stage_end_line#stage-end$'\t'}" 2>/dev/null)"

standdown_line="$(grep '^stand-down' "$evt_file" || true)"
assert_eq "a stand-down event was logged" "yes" "$(if [[ -n "$standdown_line" ]]; then echo yes; else echo no; fi)"
assert_eq "…with the API's own words as the reason" \
  "yes" "$(if [[ "$standdown_line" == *"not scoped to a workspace"* ]]; then echo yes; else echo no; fi)"
assert_eq "…and the structured cause is credential-refused" \
  "yes" "$(if [[ "$standdown_line" == *'"cause":"credential-refused"'* ]]; then echo yes; else echo no; fi)"
assert_eq "the node state is set terminal with the matching cause" \
  "yes" "$(if grep -q '^set_node_state_terminal	externally-blocked	credential-refused$' "$evt_file"; then echo yes; else echo no; fi)"

assert_eq "exactly one escalation is filed" \
  "1" "$(grep -c '^---end---' "$esc_file" 2>/dev/null)"
assert_eq "the escalation names the item ref by node" \
  "yes" "$(if grep -q '^item=credential-refused:test-node$' "$esc_file"; then echo yes; else echo no; fi)"
assert_eq "…filed in crash_loop_repo, not a target repository" \
  "yes" "$(if grep -q '^repo=acme/agent-ops$' "$esc_file"; then echo yes; else echo no; fi)"
assert_eq "…and the body quotes the API's own response" \
  "yes" "$(if grep -q 'not scoped to a workspace' "$esc_file"; then echo yes; else echo no; fi)"

# --- a second cycle of the same (still refused) container: the probe runs
# again rather than being skipped, and finds the open issue rather than
# filing a second one (create_escalation_issue's own dedup, exercised
# directly in test/crash-loop-escalate.test.sh; here we only check the probe
# still runs and still calls through to it). ---

esc_file2="$tmp_dir/refused-escalations-2"; : > "$esc_file2"
evt_file2="$tmp_dir/refused-events-2"
block_rc2="$(run_block refused-400 boot-1 0 "$state_dir" "$probe_count" "$esc_file2" "$evt_file2")"
assert_eq "a second cycle on the same still-refused credential stands down again" \
  "0" "$block_rc2"
assert_eq "…and the probe ran again rather than being skipped" \
  "2" "$(wc -l < "$probe_count" | tr -d ' ')"
assert_eq "…and it still calls through to the escalation route" \
  "1" "$(grep -c '^---end---' "$esc_file2" 2>/dev/null)"

# --- recovered: the next probe on this same (still-refused) node succeeds —
# #2414's retirement path fires exactly once, naming this cycle and the
# probe's own timestamp. ---

retire_file_recovered="$tmp_dir/refused-retire"; : > "$retire_file_recovered"
evt_file3="$tmp_dir/refused-events-3"
block_rc3="$(run_block ok boot-1 0 "$state_dir" "$probe_count" "$esc_file2" "$evt_file3" \
  "$retire_file_recovered")"
assert_eq "a recovered probe on a previously-refused node exits 0" "0" "$block_rc3"
assert_eq "…and falls through to the rest of the cycle" \
  "yes" "$(if grep -q 'FELL THROUGH' "$evt_file3"; then echo yes; else echo no; fi)"
assert_eq "retirement fires exactly once" \
  "1" "$(wc -l < "$retire_file_recovered" | tr -d ' ')"
retire_line="$(head -n1 "$retire_file_recovered")"
assert_eq "…naming crash_loop_repo, never a target repository" \
  "acme/agent-ops" "$(cut -f1 <<<"$retire_line")"
assert_eq "…scoped to this node — never another node's escalation" \
  "test-node" "$(cut -f2 <<<"$retire_line")"
assert_eq "…naming this cycle" \
  "20260101T000000Z-test-node-1" "$(cut -f3 <<<"$retire_line")"
assert_eq "…and a real timestamp for the probe that just succeeded" \
  "yes" "$(if [[ "$(cut -f4 <<<"$retire_line")" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then echo yes; else echo no; fi)"
assert_eq "…and the state file's verdict advances to ok once retirement succeeds (agent-ops#2511)" \
  "ok" "$(state_verdict "$state_dir")"

# --- recovered, but retirement itself fails (agent-ops#2511, case (a)/(b)):
# the probe came back clean, but the stubbed retirement reports failure —
# the state file's verdict must stay "refused" rather than advancing to
# "ok", so the next cycle retries the close instead of forfeiting it for
# the container's remaining lifetime. ---

state_dir_refail="$tmp_dir/state-retire-fails"; mkdir -p "$state_dir_refail"
probe_count_refail="$tmp_dir/retire-fails-probe-count"; : > "$probe_count_refail"
esc_file_refail="$tmp_dir/retire-fails-escalations"; : > "$esc_file_refail"
evt_file_refail_a="$tmp_dir/retire-fails-events-a"
run_block refused-400 boot-1 0 "$state_dir_refail" "$probe_count_refail" "$esc_file_refail" \
  "$evt_file_refail_a" >/dev/null
retire_file_refail="$tmp_dir/retire-fails-retire"; : > "$retire_file_refail"
evt_file_refail_b="$tmp_dir/retire-fails-events-b"
block_rc_refail="$(run_block ok boot-1 0 "$state_dir_refail" "$probe_count_refail" "$esc_file_refail" \
  "$evt_file_refail_b" "$retire_file_refail" 1)"
assert_eq "a recovered probe whose own retirement fails still exits 0" "0" "$block_rc_refail"
assert_eq "…and still falls through to the rest of the cycle" \
  "yes" "$(if grep -q 'FELL THROUGH' "$evt_file_refail_b"; then echo yes; else echo no; fi)"
assert_eq "…retirement was attempted exactly once" \
  "1" "$(wc -l < "$retire_file_refail" | tr -d ' ')"
assert_eq "…but the state file's verdict stays refused rather than advancing (agent-ops#2511)" \
  "refused" "$(state_verdict "$state_dir_refail")"
probe_count_refail_after_first="$(wc -l < "$probe_count_refail" | tr -d ' ')"
evt_file_refail_c="$tmp_dir/retire-fails-events-c"
run_block ok boot-1 0 "$state_dir_refail" "$probe_count_refail" "$esc_file_refail" \
  "$evt_file_refail_c" "$retire_file_refail" 1 >/dev/null
assert_eq "…so the next cycle probes again rather than treating the credential as clean" \
  "$(( probe_count_refail_after_first + 1 ))" "$(wc -l < "$probe_count_refail" | tr -d ' ')"

# --- ok: nothing to do, the cycle proceeds into the gather ---

state_dir_ok="$tmp_dir/state-ok"; mkdir -p "$state_dir_ok"
probe_count_ok="$tmp_dir/ok-probe-count"; : > "$probe_count_ok"
esc_file_ok="$tmp_dir/ok-escalations"; : > "$esc_file_ok"
evt_file_ok="$tmp_dir/ok-events"
retire_file_ok="$tmp_dir/ok-retire"; : > "$retire_file_ok"
block_rc_ok="$(run_block ok boot-1 0 "$state_dir_ok" "$probe_count_ok" "$esc_file_ok" "$evt_file_ok" \
  "$retire_file_ok")"
assert_eq "a healthy credential exits 0" "0" "$block_rc_ok"
assert_eq "a healthy credential falls through to the rest of the cycle" \
  "yes" "$(if grep -q 'FELL THROUGH' "$evt_file_ok"; then echo yes; else echo no; fi)"
assert_eq "…without filing anything" "0" "$(grep -c '^---end---' "$esc_file_ok" 2>/dev/null)"
assert_eq "…and without standing anything down" \
  "no" "$(if grep -q '^stand-down' "$evt_file_ok"; then echo yes; else echo no; fi)"
assert_eq "a node that was never refused never calls the retirement path" \
  "0" "$(wc -l < "$retire_file_ok" | tr -d ' ')"
assert_eq "the first cycle after a container start always probes" \
  "1" "$(wc -l < "$probe_count_ok" | tr -d ' ')"
assert_eq "…and still logs the probe's own stage-end on the healthy path" \
  "1" "$(grep -c '^stage-end' "$evt_file_ok")"

# --- a second cycle of the same healthy container: the probe is skipped —
# a healthy node pays for this once per container lifetime, not every cycle ---

evt_file_ok2="$tmp_dir/ok-events-2"
block_rc_ok2="$(run_block ok boot-1 0 "$state_dir_ok" "$probe_count_ok" "$esc_file_ok" "$evt_file_ok2")"
assert_eq "a second cycle of a healthy container also exits 0" "0" "$block_rc_ok2"
assert_eq "a second cycle of the same healthy container falls through too" \
  "yes" "$(if grep -q 'FELL THROUGH' "$evt_file_ok2"; then echo yes; else echo no; fi)"
assert_eq "…without probing again" \
  "1" "$(wc -l < "$probe_count_ok" | tr -d ' ')"

# --- a later cycle after a fresh container start (a different boot id):
# the probe runs again even though the last verdict here was ok ---

evt_file_ok3="$tmp_dir/ok-events-3"
block_rc_ok3="$(run_block ok boot-2 0 "$state_dir_ok" "$probe_count_ok" "$esc_file_ok" "$evt_file_ok3")"
assert_eq "a fresh container start on a healthy credential also exits 0" "0" "$block_rc_ok3"
assert_eq "a fresh container start probes again regardless of the last verdict" \
  "2" "$(wc -l < "$probe_count_ok" | tr -d ' ')"

# --- transient (503): not a credential problem, stands nothing down ---

state_dir_t="$tmp_dir/state-transient"; mkdir -p "$state_dir_t"
probe_count_t="$tmp_dir/transient-probe-count"; : > "$probe_count_t"
esc_file_t="$tmp_dir/transient-escalations"; : > "$esc_file_t"
evt_file_t="$tmp_dir/transient-events"
block_rc_t="$(run_block transient-503 boot-1 0 "$state_dir_t" "$probe_count_t" "$esc_file_t" "$evt_file_t")"
assert_eq "a transient 5xx exits 0, falling through" "0" "$block_rc_t"
assert_eq "a transient 5xx is not treated as a credential refusal" \
  "yes" "$(if grep -q 'FELL THROUGH' "$evt_file_t"; then echo yes; else echo no; fi)"
assert_eq "…and nothing is escalated for it here" \
  "0" "$(grep -c '^---end---' "$esc_file_t" 2>/dev/null)"
assert_eq "…and nothing is stood down for it here" \
  "no" "$(if grep -q '^stand-down' "$evt_file_t"; then echo yes; else echo no; fi)"

# --- a transient 5xx on the container's very first cycle leaves the state
# file's verdict empty (inconclusive), not "ok" — the gate must treat that as
# still due a probe on the next cycle of the same container, rather than
# reading an empty verdict as settled and closing itself for the container's
# whole remaining lifetime (agent-ops#2554). ---

probe_count_t2="$tmp_dir/transient-probe-count-2"; : > "$probe_count_t2"
esc_file_t2="$tmp_dir/transient-escalations-2"; : > "$esc_file_t2"
evt_file_t2b="$tmp_dir/transient-events-2b"
block_rc_t2b="$(run_block transient-503 boot-1 0 "$state_dir_t" "$probe_count_t2" "$esc_file_t2" "$evt_file_t2b")"
assert_eq "a second cycle after a first-cycle transient reply exits 0" "0" "$block_rc_t2b"
assert_eq "…and leaves the state file's verdict empty (inconclusive), not ok" \
  "" "$(state_verdict "$state_dir_t")"
assert_eq "…and re-probes rather than treating the empty verdict as settled" \
  "1" "$(wc -l < "$probe_count_t2" | tr -d ' ')"

# --- a healthy node restarts, and the new boot's very first probe is itself
# inconclusive: the stale "ok" verdict the old boot earned must not survive
# onto the new boot id, or the new boot's gate closes on a verdict it never
# itself confirmed (agent-ops#2554, review round 2 — the restart form of the
# same gap: a node that was ever healthy hit this on every restart, since the
# gate's own `-z "$cred_prev_verdict"` disjunct never fires when the carried
# verdict is a stale "ok"). ---

state_dir_restart="$tmp_dir/state-restart"; mkdir -p "$state_dir_restart"
probe_count_restart="$tmp_dir/restart-probe-count"; : > "$probe_count_restart"
esc_file_restart="$tmp_dir/restart-escalations"; : > "$esc_file_restart"
evt_file_restart_a="$tmp_dir/restart-events-a"
run_block ok boot-1 0 "$state_dir_restart" "$probe_count_restart" "$esc_file_restart" "$evt_file_restart_a" \
  >/dev/null
assert_eq "the pre-restart boot settles at ok" "ok" "$(state_verdict "$state_dir_restart")"

evt_file_restart_b="$tmp_dir/restart-events-b"
block_rc_restart_b="$(run_block transient-503 boot-2 0 "$state_dir_restart" "$probe_count_restart" \
  "$esc_file_restart" "$evt_file_restart_b")"
assert_eq "a transient reply on the new boot's first cycle exits 0" "0" "$block_rc_restart_b"
assert_eq "…and leaves the state file's verdict empty, not the old boot's stale ok" \
  "" "$(state_verdict "$state_dir_restart")"

evt_file_restart_c="$tmp_dir/restart-events-c"
run_block ok boot-2 0 "$state_dir_restart" "$probe_count_restart" \
  "$esc_file_restart" "$evt_file_restart_c" >/dev/null
assert_eq "a later cycle of the same new boot re-probes rather than reading the stale ok as settled" \
  "3" "$(wc -l < "$probe_count_restart" | tr -d ' ')"
assert_eq "…and now settles the new boot at its own genuinely-confirmed ok" \
  "ok" "$(state_verdict "$state_dir_restart")"

# --- a refused node restarts, and the new boot's first probe is itself
# inconclusive before a later cycle gets a genuine clean reply: the open
# escalation's "refused" verdict must survive the boot change — unlike "ok"
# above — so the eventual clean probe still finds `cred_prev_verdict ==
# "refused"` and still retires it, rather than reading the reset-to-empty
# default as a credential nobody ever had to clear. ---

state_dir_rr="$tmp_dir/state-refused-restart"; mkdir -p "$state_dir_rr"
probe_count_rr="$tmp_dir/refused-restart-probe-count"; : > "$probe_count_rr"
esc_file_rr="$tmp_dir/refused-restart-escalations"; : > "$esc_file_rr"
evt_file_rr_a="$tmp_dir/refused-restart-events-a"
run_block refused-400 boot-1 0 "$state_dir_rr" "$probe_count_rr" "$esc_file_rr" "$evt_file_rr_a" \
  >/dev/null
evt_file_rr_b="$tmp_dir/refused-restart-events-b"
run_block transient-503 boot-2 0 "$state_dir_rr" "$probe_count_rr" "$esc_file_rr" "$evt_file_rr_b" \
  >/dev/null
assert_eq "a refused verdict survives a boot change through an inconclusive first probe" \
  "refused" "$(state_verdict "$state_dir_rr")"

retire_file_rr="$tmp_dir/refused-restart-retire"; : > "$retire_file_rr"
evt_file_rr_c="$tmp_dir/refused-restart-events-c"
run_block ok boot-2 0 "$state_dir_rr" "$probe_count_rr" "$esc_file_rr" "$evt_file_rr_c" "$retire_file_rr" \
  >/dev/null
assert_eq "…so a later genuine clean reply on the new boot still retires the escalation" \
  "1" "$(wc -l < "$retire_file_rr" | tr -d ' ')"
assert_eq "…and the state file's verdict advances to ok" \
  "ok" "$(state_verdict "$state_dir_rr")"

# --- a node that was refused, then on its next probe only gets a transient
# 5xx: the transient reply says nothing about the credential, so retirement
# must not fire on the strength of it — only a genuine clean reply clears a
# `credential-refused` escalation. ---

state_dir_rt="$tmp_dir/state-refused-then-transient"; mkdir -p "$state_dir_rt"
probe_count_rt="$tmp_dir/refused-then-transient-probe-count"; : > "$probe_count_rt"
esc_file_rt="$tmp_dir/refused-then-transient-escalations"; : > "$esc_file_rt"
evt_file_rt="$tmp_dir/refused-then-transient-events"
run_block refused-400 boot-1 0 "$state_dir_rt" "$probe_count_rt" "$esc_file_rt" "$evt_file_rt" \
  >/dev/null
retire_file_rt="$tmp_dir/refused-then-transient-retire"; : > "$retire_file_rt"
evt_file_rt2="$tmp_dir/refused-then-transient-events-2"
block_rc_rt2="$(run_block transient-503 boot-1 0 "$state_dir_rt" "$probe_count_rt" "$esc_file_rt" \
  "$evt_file_rt2" "$retire_file_rt")"
assert_eq "a transient reply right after a refused credential exits 0" "0" "$block_rc_rt2"
assert_eq "…and does not call the retirement path" \
  "0" "$(wc -l < "$retire_file_rt" | tr -d ' ')"
assert_eq "…and leaves the state file's verdict at refused, not advanced to ok (agent-ops#2511 case (c))" \
  "refused" "$(state_verdict "$state_dir_rt")"

# --- refused, but not by the credential: `credit_exhausted` reaches
# `stage_api_refusal_class`'s own default arm as `refused` (deliberately —
# a top-up, not a retry, is what clears it) while its token names the
# account's balance, not the key. `lib/substrate-grok-build.sh` synthesises
# exactly this shape for a billing lapse, so standing the fleet down as
# `credential-refused` over it would send the next reader at the key. The
# gate is both halves: the class *and* a credential-shaped token. ---

state_dir_credit="$tmp_dir/state-credit"; mkdir -p "$state_dir_credit"
probe_count_credit="$tmp_dir/credit-probe-count"; : > "$probe_count_credit"
esc_file_credit="$tmp_dir/credit-escalations"; : > "$esc_file_credit"
evt_file_credit="$tmp_dir/credit-events"
block_rc_credit="$(run_block refused-credit boot-1 0 "$state_dir_credit" \
  "$probe_count_credit" "$esc_file_credit" "$evt_file_credit")"
assert_eq "a refused-class verdict whose token is not credential-shaped exits 0" \
  "0" "$block_rc_credit"
assert_eq "…falling through rather than standing the cycle down" \
  "yes" "$(if grep -q 'FELL THROUGH' "$evt_file_credit"; then echo yes; else echo no; fi)"
assert_eq "…with no stand-down logged" \
  "no" "$(if grep -q '^stand-down' "$evt_file_credit"; then echo yes; else echo no; fi)"
assert_eq "…and no credential escalation filed against an exhausted balance" \
  "0" "$(grep -c '^---end---' "$esc_file_credit" 2>/dev/null)"
assert_eq "…and the probe did run, so this is the gate's verdict and not a skip" \
  "1" "$(wc -l < "$probe_count_credit" | tr -d ' ')"

# --- the container-start reading itself unavailable: the gate must treat an
# empty reading as due a probe, never compare two empty readings as
# unchanged. `_updater_health_own_started` returning nothing (a kernel this
# node cannot read a start time from) is the case: the first cycle writes
# `container_started: ""`, and a second cycle comparing `"" != ""` would
# otherwise skip for the rest of that container's life. ---

state_dir_noboot="$tmp_dir/state-noboot"; mkdir -p "$state_dir_noboot"
probe_count_noboot="$tmp_dir/noboot-probe-count"; : > "$probe_count_noboot"
esc_file_noboot="$tmp_dir/noboot-escalations"; : > "$esc_file_noboot"
evt_file_noboot="$tmp_dir/noboot-events"
run_block ok "" 0 "$state_dir_noboot" "$probe_count_noboot" "$esc_file_noboot" \
  "$evt_file_noboot" >/dev/null
assert_eq "an unavailable container-start reading still probes on the first cycle" \
  "1" "$(wc -l < "$probe_count_noboot" | tr -d ' ')"
evt_file_noboot2="$tmp_dir/noboot-events-2"
block_rc_noboot2="$(run_block ok "" 0 "$state_dir_noboot" "$probe_count_noboot" \
  "$esc_file_noboot" "$evt_file_noboot2")"
assert_eq "a second cycle with the reading still unavailable exits 0" \
  "0" "$block_rc_noboot2"
assert_eq "…and probes again rather than reading two empty strings as unchanged" \
  "2" "$(wc -l < "$probe_count_noboot" | tr -d ' ')"

# --- --dry-run: no call is made at all ---

state_dir_dry="$tmp_dir/state-dry"; mkdir -p "$state_dir_dry"
probe_count_dry="$tmp_dir/dry-probe-count"; : > "$probe_count_dry"
esc_file_dry="$tmp_dir/dry-escalations"; : > "$esc_file_dry"
evt_file_dry="$tmp_dir/dry-events"
block_rc_dry="$(run_block refused-400 boot-1 1 "$state_dir_dry" "$probe_count_dry" "$esc_file_dry" "$evt_file_dry")"
assert_eq "--dry-run exits 0, falling through" "0" "$block_rc_dry"
assert_eq "--dry-run makes no probe call at all, even against a refused credential" \
  "0" "$(wc -l < "$probe_count_dry" | tr -d ' ')"
assert_eq "…and falls through to the rest of the cycle" \
  "yes" "$(if grep -q 'FELL THROUGH' "$evt_file_dry"; then echo yes; else echo no; fi)"

# --- --dry-run on a node that was already refused: a cycle that promises to
# change nothing must not close the escalation either, even though a
# non-dry-run cycle right now would recover it (#2414's own rule, mirroring
# 0h's existing "a cycle that promises to change nothing must not write a
# fresh escalation"). ---

state_dir_dry2="$tmp_dir/state-dry-recovered"; mkdir -p "$state_dir_dry2"
probe_count_dry2="$tmp_dir/dry-recovered-probe-count"; : > "$probe_count_dry2"
esc_file_dry2="$tmp_dir/dry-recovered-escalations"; : > "$esc_file_dry2"
evt_file_dry2a="$tmp_dir/dry-recovered-events-a"
run_block refused-400 boot-1 0 "$state_dir_dry2" "$probe_count_dry2" "$esc_file_dry2" "$evt_file_dry2a" \
  >/dev/null
retire_file_dry2="$tmp_dir/dry-recovered-retire"; : > "$retire_file_dry2"
evt_file_dry2b="$tmp_dir/dry-recovered-events-b"
block_rc_dry2="$(run_block ok boot-1 1 "$state_dir_dry2" "$probe_count_dry2" "$esc_file_dry2" \
  "$evt_file_dry2b" "$retire_file_dry2")"
assert_eq "--dry-run on a previously-refused node exits 0, falling through" "0" "$block_rc_dry2"
assert_eq "…and makes no probe call at all" \
  "1" "$(wc -l < "$probe_count_dry2" | tr -d ' ')"
assert_eq "…so the retirement path is never called" \
  "0" "$(wc -l < "$retire_file_dry2" | tr -d ' ')"

echo
if (( failures == 0 )); then
  echo "All standdown-credential-preflight assertions passed."
  exit 0
else
  echo "$failures standdown-credential-preflight assertion(s) FAILED."
  exit 1
fi
