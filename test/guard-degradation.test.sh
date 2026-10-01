#!/usr/bin/env bash
#
# test/guard-degradation.test.sh — regression tests for TD-PPagop-26081407:
# a guarded call site (`cmd 2>&1)" || { guard_warn ...; var=fallback; }`)
# reports on the union log when its guarded command fails, instead of
# silently substituting the same literal it always did. The fallback itself
# is never touched by this item — only the silence around it — so every
# assertion below checks both halves: the `guard-degraded` event fired, and
# the caller-visible value is exactly what it was before this item.
#
# `guard_warn`, `stage_budget_overrides`, `gather_claimed`,
# `unaccounted_items` and `coordinator_eligible_items` are lifted whole out
# of agent-cycle.sh with awk, the same technique test/verdict-corroboration.
# test.sh and test/pr-claim-exclusion.test.sh use for the same reason: this
# cannot pass against a paraphrase of the real function.
#
# Coverage here is representative, not the full 67-site sweep TD-PPagop-
# 26081407 converted: the guard shape is mechanically identical everywhere
# (capture stdout+stderr, guard_warn on failure, restore the untouched
# fallback), so this file exercises `guard_warn` itself once, then the
# handful of standalone functions and the one inline block (the fleet
# stand-down date parse) whose failure carries the most consequence — a
# false zero there silently lets the fleet run through an active usage-limit
# cooldown. The full test suite staying green after this item's mechanical
# sweep (no fallback value changed) is what backstops the rest.
#
# No test framework is used (none exists elsewhere in this repo). Run
# directly:
#
#   ./test/guard-degradation.test.sh
#
# Exit status is 0 iff every assertion passed.

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

# --- Lift the functions under test whole out of their own files (#771: -----
#     gather_claimed/unaccounted_items/coordinator_eligible_items moved to
#     lib/candidate-select.sh; the other three stay in agent-cycle.sh) -------
extract_function() {  # extract_function <name> <file>
  awk -v fn="$1" '
    $0 ~ ("^" fn "\\(\\) \\{") { on = 1; opener = 1 }
    on {
      print
      # Two shapes close a function here. A multi-line one closes on a `}`
      # back at column 0; a one-line one -- `fn() { ...; }`, which is what
      # both cycles own log_event wrapper became in issue #967 -- closes on
      # its own opening line. Without that second case the walk runs past
      # the end of the function and captures whatever follows it.
      if ($0 == "}" || (opener && $0 ~ /;[[:space:]]*\}[[:space:]]*$/)) exit
      opener = 0
    }
  ' "$2"
}

log_event_src="$(extract_function log_event "$SCRIPT_DIR/agent-cycle.sh")"
guard_warn_src="$(extract_function guard_warn "$SCRIPT_DIR/agent-cycle.sh")"
stage_budget_overrides_src="$(extract_function stage_budget_overrides "$SCRIPT_DIR/agent-cycle.sh")"
gather_claimed_src="$(extract_function gather_claimed "$SCRIPT_DIR/lib/candidate-select.sh")"
unaccounted_items_src="$(extract_function unaccounted_items "$SCRIPT_DIR/lib/candidate-select.sh")"
coordinator_eligible_items_src="$(extract_function coordinator_eligible_items "$SCRIPT_DIR/lib/candidate-select.sh")"

for pair in \
  "log_event_src:log_event()" \
  "guard_warn_src:guard_warn()" \
  "stage_budget_overrides_src:stage_budget_overrides()" \
  "gather_claimed_src:gather_claimed()" \
  "unaccounted_items_src:unaccounted_items()" \
  "coordinator_eligible_items_src:coordinator_eligible_items()"; do
  name="${pair%%:*}"
  needle="${pair#*:}"
  if [[ "${!name}" != *"$needle"* ]]; then
    printf 'FAIL - could not extract %s from agent-cycle.sh (renamed or moved?)\n' "$needle"
    exit 1
  fi
done

# shellcheck source=lib/log-event.sh
. "$SCRIPT_DIR/lib/log-event.sh"
eval "$log_event_src"
eval "$guard_warn_src"
eval "$stage_budget_overrides_src"
eval "$gather_claimed_src"
eval "$unaccounted_items_src"
eval "$coordinator_eligible_items_src"

# log_event's own dependencies, the same fixtures test/verdict-corroboration.
# test.sh and its siblings use — consumed by the eval'd log_event above,
# which shellcheck cannot see into.
# shellcheck disable=SC2034
cycle_id="test-cycle"
# shellcheck disable=SC2034
node_name="test-node"
log_file="$tmp_dir/log.jsonl"
: > "$log_file"

last_guard_events() {  # every guard-degraded event this run wrote
  jq -c 'select(.event == "guard-degraded")' "$log_file"
}

# =================================================================================
# guard_warn / log_event
# =================================================================================

: > "$log_file"
guard_warn "some:site" "jq: error (at <stdin>:0): whatever broke"
n_events="$(jq -s 'length' "$log_file")"
assert_eq "guard_warn writes exactly one event" "1" "$n_events"
assert_eq "…tagged guard-degraded" "guard-degraded" "$(jq -r '.event' "$log_file")"
assert_eq "…naming the site" "some:site" "$(jq -r '.site' "$log_file")"
assert_eq "…carrying the captured failure text as detail" "jq: error (at <stdin>:0): whatever broke" \
  "$(jq -r '.detail' "$log_file")"
assert_eq "…stamped with this cycle's id" "test-cycle" "$(jq -r '.cycle' "$log_file")"

# --- The report's own bounds ------------------------------------------------
# guard-degraded lands on the fleet-replicated union log, the unbounded input
# requirements 4c and 4g exist because of, and a guard that fails
# *persistently* — a date parse of a field that is simply always absent, a gh
# outage across the repo loop — fires once per occurrence per cycle per node.
# Both axes are capped: repeats of one site label, and the size of a `detail`
# that for a gh api body has no bound of its own.

reset_guard_counts() { unset guard_warn_counts; }

: > "$log_file"; reset_guard_counts
for _ in 1 2 3 4 5 6 7; do guard_warn "loop:site" "keeps failing"; done
assert_eq "a persistently failing site is capped at GUARD_WARN_SITE_MAX reports" \
  "3" "$(last_guard_events | jq -s 'length')"
assert_eq "…numbered so a reader can see they are repeats" "1 2 3" \
  "$(last_guard_events | jq -rs 'map(.n | tostring) | join(" ")')"
assert_eq "…with only the last marked final, so the silence after it is legible" \
  "3" "$(last_guard_events | jq -rs 'map(select(.final == true) | .n) | join(" ")')"

: > "$log_file"; reset_guard_counts
guard_warn "site:a" "broke"; guard_warn "site:b" "broke"; guard_warn "site:c" "broke"
guard_warn "site:a" "broke"; guard_warn "site:b" "broke"
assert_eq "the cap is per label, so a slug-keyed site still reports per slug" \
  "5" "$(last_guard_events | jq -s 'length')"

: > "$log_file"; reset_guard_counts
guard_warn "big:site" "$(head -c 4000 /dev/zero | tr '\0' 'x')"
assert_eq "an unbounded detail is capped to its leading 500 bytes" \
  "500" "$(last_guard_events | jq -r '.detail | length')"

# --- The management path reports to stderr, not to the shared log -----------
# --status runs before the lock and deliberately creates no cycle directory,
# so its cycle_id names a cycle that never ran; stamping the fleet's log with
# one would record a failed read during somebody's read-only query.

: > "$log_file"; reset_guard_counts
manage_stderr="$(MANAGE_ACTION=status guard_warn "limit_status_report:rec_class" "jq: parse error" 2>&1 >/dev/null)"
assert_eq "a management command writes no event to the union log" \
  "0" "$(last_guard_events | jq -s 'length')"
assert_eq "…and says so on stderr instead, naming the site" \
  "agent-cycle: guard-degraded: limit_status_report:rec_class: jq: parse error" "$manage_stderr"

: > "$log_file"; reset_guard_counts
guard_warn "limit_status_report:rec_class" "jq: parse error"
assert_eq "…while a real cycle still logs the same site" \
  "1" "$(last_guard_events | jq -s 'length')"

reset_guard_counts

# =================================================================================
# stage_budget_overrides — CONFIG_FILE read off disk (test 1: external;
# test 2: {} is what a healthy unconfigured file also answers)
# =================================================================================

: > "$log_file"
CONFIG_FILE="$tmp_dir/does-not-exist.json"
out="$(stage_budget_overrides implementer "org/repo")"
assert_eq "a missing CONFIG_FILE still yields the documented {} fallback" "{}" "$out"
assert_eq "…and the read failure is reported" "1" "$(last_guard_events | jq -s 'length')"
assert_eq "…under the right site" "stage_budget_overrides" "$(last_guard_events | jq -r '.site')"

: > "$log_file"
CONFIG_FILE="$tmp_dir/config.json"
printf '{"repos": [{"slug": "org/repo", "stage_timeouts": {"implementer": 42}}]}' > "$CONFIG_FILE"
out="$(stage_budget_overrides implementer "org/repo")"
assert_eq "a healthy CONFIG_FILE is read normally" "42" "$(jq -r '.backstop' <<<"$out")"
assert_eq "…and nothing is reported on the happy path" "0" "$(last_guard_events | jq -s 'length')"

# =================================================================================
# gather_claimed — the fleet's active claims for one repo, still delivered to
# jq as --argjson (test 1: MAX_ARG_STRLEN, the kernel's 131072-byte per-argv-
# entry cap, the same mechanism the 2026-08-12 outage hit); test 2: [] reads
# exactly like "this repo has no claims", which the caller uses to decide
# whether a candidate is already claimed.
# =================================================================================

fake_claim_sh() {  # writes a lib/claim.sh stand-in that answers a big fixture
  cat > "$tmp_dir/claim.sh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  claims) cat "$CLAIM_SH_FIXTURE" ;;
  branches) echo '[]' ;;
esac
STUB
  chmod +x "$tmp_dir/claim.sh"
}
fake_claim_sh
mkdir -p "$tmp_dir/lib"
cp "$tmp_dir/claim.sh" "$tmp_dir/lib/claim.sh"

real_script_dir="$SCRIPT_DIR"
SCRIPT_DIR="$tmp_dir"
# cycle_dir and branch_prefix are consumed by gather_claimed above, out of
# static-analysis reach.
# shellcheck disable=SC2034
cycle_dir="$tmp_dir"
# shellcheck disable=SC2034
branch_prefix="agent/"

big_registry="$(jq -nc '[range(1300) | {item: ("TD-fill-" + (. | tostring)),
  age_hours: 1, pr_number: null, detail: ("pad " + ("x" * 100))}]')"
assert_eq "the oversized claims fixture really is past MAX_ARG_STRLEN" "1" \
  "$(( $(printf '%s' "$big_registry" | wc -c) > 131072 ))"

CLAIM_SH_FIXTURE="$tmp_dir/big-registry.json"
printf '%s' "$big_registry" > "$CLAIM_SH_FIXTURE"
export CLAIM_SH_FIXTURE

: > "$log_file"
out="$(gather_claimed "org/repo")"
assert_eq "a claims registry past the argv cap still falls back to []" "[]" "$out"
assert_eq "…and the argv failure is reported, not swallowed" "1" "$(last_guard_events | jq -s 'length')"
assert_eq "…under the right site" "gather_claimed:org/repo" "$(last_guard_events | jq -r '.site')"

CLAIM_SH_FIXTURE="$tmp_dir/small-registry.json"
printf '[{"item": "TD1", "age_hours": 1, "pr_number": null}]' > "$CLAIM_SH_FIXTURE"
: > "$log_file"
out="$(gather_claimed "org/repo")"
assert_eq "a normal-sized claims registry is read whole" "TD1" "$(jq -r '.[0].item' <<<"$out")"
assert_eq "…and nothing is reported on the happy path" "0" "$(last_guard_events | jq -s 'length')"
SCRIPT_DIR="$real_script_dir"

# =================================================================================
# unaccounted_items — this is the guard the 2026-08-14 outage went through:
# an execve failure here read as "everything is accounted for" and the
# Script corroborated a none-selected verdict silently.
# =================================================================================

: > "$log_file"
out="$(unaccounted_items 'not json' '[{"repo":"o/r","item":"TD1","source":"tech-debt"}]' '{}')"
assert_eq "malformed recorded-json still falls back to []" "[]" "$out"
assert_eq "…and the failure is reported" "1" "$(last_guard_events | jq -s 'length')"
assert_eq "…under the right site" "unaccounted_items" "$(last_guard_events | jq -r '.site')"

: > "$log_file"
out="$(unaccounted_items '{"needs_refinement":[],"voided":[]}' \
  '[{"repo":"o/r","item":"TD1","source":"tech-debt"}]' '{}')"
assert_eq "a well-formed input still names the unaccounted item" "TD1" "$(jq -r '.[0].item' <<<"$out")"
assert_eq "…and nothing is reported on the happy path" "0" "$(last_guard_events | jq -s 'length')"

# =================================================================================
# coordinator_eligible_items — the Co-Ordinator's own eligible-set
# denominator; a jq failure reading as [] would silently tell the fleet
# nothing was ever selectable.
# =================================================================================

: > "$log_file"
# A bare-scalar element passes the function's own `type == "array"` sanity
# check (it *is* an array) but breaks inside the pipeline itself (`.slug` on
# a number), which is the failure mode the pre-check at the top of the
# function cannot catch — the one this item's guard is for.
out="$(coordinator_eligible_items '[1,2,3]' '[]')"
assert_eq "an array of non-objects still falls back to []" "[]" "$out"
assert_eq "…and the failure is reported" "1" "$(last_guard_events | jq -s 'length')"
assert_eq "…under the right site" "coordinator_eligible_items" "$(last_guard_events | jq -r '.site')"

: > "$log_file"
ordered='[{"slug":"o/r","sources":["tech-debt"],"tech_debt":[{"ref":"TD1"}]}]'
out="$(coordinator_eligible_items "$ordered" '[]')"
assert_eq "a well-formed input still names the eligible item" "TD1" "$(jq -r '.[0].item' <<<"$out")"
assert_eq "…and nothing is reported on the happy path" "0" "$(last_guard_events | jq -s 'length')"

# =================================================================================
# The fleet stand-down date parse (main cycle path, not --status) — lifted by
# its own start/end markers rather than a function signature, the same
# technique test/pr-claim-exclusion.test.sh uses for the stale-ref block: the
# gate this feeds decides whether the whole fleet stands down for an active
# limit, so a false "already expired" here is the highest-stakes single site
# this item touches.
# =================================================================================

resume_block_src="$(awk '
    /^resume_epoch=0$/ { on = 1 }
    on                 { print }
    on && /^fi$/        { exit }
  ' "$SCRIPT_DIR/lib/standdown.sh")"
if [[ "$resume_block_src" != *"resume_epoch"* ]]; then
  printf 'FAIL - could not extract the resume_epoch block from agent-cycle.sh (moved or reworded?)\n'
  exit 1
fi

run_resume_block() {  # run_resume_block <resume_at>
  # resume_at is consumed, and resume_epoch assigned, by the eval'd block
  # above (another case shellcheck's own reach does not extend into).
  # shellcheck disable=SC2034
  resume_at="$1"
  eval "$resume_block_src"
  # shellcheck disable=SC2154
  printf '%s' "$resume_epoch"
}

: > "$log_file"
out="$(run_resume_block 'not a date')"
assert_eq "an unparseable resume_at still falls back to epoch 0" "0" "$out"
assert_eq "…and the date-parse failure is reported, not swallowed" "1" "$(last_guard_events | jq -s 'length')"
assert_eq "…under the right site" "cycle:resume_epoch" "$(last_guard_events | jq -r '.site')"

: > "$log_file"
out="$(run_resume_block '2026-08-14T00:00:00Z')"
assert_eq "a well-formed resume_at is parsed normally" "1786665600" "$out"
assert_eq "…and nothing is reported on the happy path" "0" "$(last_guard_events | jq -s 'length')"

# =================================================================================
# The union's usage-limit carrier and the automatic-freeze escalation (#2037),
# lifted out of lib/standdown.sh by their own markers the same way. The union
# is read once, by `limit_union_state`, for the governing hit, the freeze's
# start and the escalation memory. The read skips a line that does not parse
# and fails only when it cannot read at all; that failure, and a union the
# snapshot could not build (`union_build_ok`), are reported and never taken
# for "no limit" or "no freeze". The fixture line is the shape both VM nodes'
# logs carried: a record cut off part-way and run into a whole later one.
# =================================================================================

# shellcheck source=lib/limit-detect.sh
. "$SCRIPT_DIR/lib/limit-detect.sh"

# From `union_state=` up to, and not including, the `governing=` line that
# hands the union's record to `limit_later_record`.
union_block_src="$(awk '
    /^union_state=/ { on = 1 }
    /^governing=/   { exit }
    on              { print }
  ' "$SCRIPT_DIR/lib/standdown.sh")"
if [[ "$union_block_src" != *"limit_union_state"* ]]; then
  printf 'FAIL - could not extract the union_state block from lib/standdown.sh (moved or reworded?)\n'
  exit 1
fi
# The escalation block, from the gate that decides whether to escalate at all
# to the `fi` at its own indentation that closes it.
freeze_block_src="$(awk '
    /^      if \(\( limit_escalate_after_hours > 0 \)\)/ { on = 1 }
    on                                                   { print }
    on && /^      fi$/                                   { exit }
  ' "$SCRIPT_DIR/lib/standdown.sh")"
if [[ "$freeze_block_src" != *"limit-freeze-escalated"* ]]; then
  printf 'FAIL - could not extract the freeze-escalation block from lib/standdown.sh (moved or reworded?)\n'
  exit 1
fi

spliced_line='{"ts":"2026-09-18T00:00:00Z","event":"github-budget","core":{"limit":5000,"{"ts":"2026-09-18T00:05:00Z","event":"cycle-end","exit_code":0}'
union_log="$tmp_dir/union.jsonl"

run_union_block() {  # run_union_block — prints union_record, then union_state_ok
  # union_log and union_build_ok are read, and union_state, union_state_ok and
  # union_record assigned, by the eval'd block.
  eval "$union_block_src"
  # shellcheck disable=SC2154
  printf '%s\n%s' "$union_record" "$union_state_ok"
}

printf '%s\n' '{"ts":"2026-09-17T06:54:54Z","event":"limit-hit","resume_at":"2099-01-01T00:00:00Z"}' \
  "$spliced_line" > "$union_log"
: > "$log_file"; reset_guard_counts
union_build_ok=1
out="$(run_union_block)"
assert_eq "the union carrier still reads the governing hit past a spliced line" \
  "2099-01-01T00:00:00Z" "$(head -n1 <<<"$out" | jq -r '.resume_at' 2>/dev/null)"
assert_eq "…and nothing is reported, because nothing failed" "0" "$(last_guard_events | jq -s 'length')"

: > "$log_file"; reset_guard_counts
# shellcheck disable=SC2317  # the stub is called from $union_block_src via eval, invisible to a static reader
out="$(limit_union_state() { echo "jq: killed" >&2; return 137; }; run_union_block)"
assert_eq "a union read that fails outright leaves the carrier empty" "" "$(head -n1 <<<"$out")"
assert_eq "…marks the union's answers unknown, not empty" "0" "$(tail -n1 <<<"$out")"
assert_eq "…and is reported, not read as no limit" "1" "$(last_guard_events | jq -s 'length')"
assert_eq "…under the right site" "cycle:union_record" "$(last_guard_events | jq -r '.site')"

# A union the snapshot could not build was reported where it was built
# (`cycle:union_build`, agent-cycle.sh); here it is treated exactly as a failed
# read, without reading what part of it was written.
: > "$log_file"; reset_guard_counts
union_build_ok=0
union_reads="$tmp_dir/union-reads"
: > "$union_reads"
# shellcheck disable=SC2317  # the stub is called from $union_block_src via eval, invisible to a static reader
out="$(limit_union_state() { echo read >> "$union_reads"; return 1; }; run_union_block)"
assert_eq "a union that could not be built is not read" "" "$(cat "$union_reads")"
assert_eq "…leaves the carrier empty, so the flag decides alone" "" "$(head -n1 <<<"$out")"
assert_eq "…and marks the union's answers unknown" "0" "$(tail -n1 <<<"$out")"
union_build_ok=1

# The freeze block's own inputs, as lib/standdown.sh has them by this point.
# shellcheck disable=SC2034  # all consumed by the eval'd blocks
{
  limit_escalate_after_hours=24
  DRY_RUN=0
  crash_loop_repo="o/ops"
  enabler_assignee="someone"
  enabler_escalation_label="escalation"
  cycle_dir="$tmp_dir"
}
filed="$tmp_dir/filed"
# shellcheck disable=SC2317  # called from $freeze_block_src via eval, invisible to a static reader
create_escalation_issue() { printf '%s\n' "$2" >> "$filed"; printf '42\thttps://example.invalid/o/ops/issues/42'; }
run_freeze_block() {  # run_freeze_block <now_epoch> <governing record>
  # now_epoch and governing are read by the eval'd blocks; the union block
  # runs first, as it does in lib/standdown.sh, to give the freeze block its
  # union_state and union_state_ok.
  # shellcheck disable=SC2034
  now_epoch="$1"
  # shellcheck disable=SC2034
  governing="$2"
  : > "$filed"
  : > "$log_file"
  reset_guard_counts
  eval "$union_block_src"
  eval "$freeze_block_src"
}
freeze_events() { jq -c 'select(.event == "limit-freeze-escalated")' "$log_file"; }
warning_events() { jq -c 'select(.event == "warning")' "$log_file"; }

now_s="$(date -u +%s)"
three_days_ago="$(date -u -d "@$(( now_s - 3 * 86400 ))" +%Y-%m-%dT%H:%M:%SZ)"
an_hour_ago="$(date -u -d "@$(( now_s - 3600 ))" +%Y-%m-%dT%H:%M:%SZ)"
auto_union='{"resume_at":"2099-01-01T00:00:00Z","kind":"auto"}'

# A freeze three days old, with a spliced line after its first hit: the start
# is still found, so the escalation files. Before #2037 the start read empty,
# `date -d ""` answered midnight today, and the freeze never came of age.
printf '%s\n' "{\"ts\":\"$three_days_ago\",\"event\":\"limit-hit\",\"resume_at\":\"2099-01-01T00:00:00Z\"}" \
  "$spliced_line" > "$union_log"
run_freeze_block "$now_s" "$auto_union"
assert_eq "a three-day freeze past a spliced line escalates, keyed on its start" \
  "usage-limit-freeze:$three_days_ago" "$(cat "$filed")"
assert_eq "…and records the escalation against that start" "$three_days_ago" \
  "$(freeze_events | jq -r '.since')"
assert_eq "…aged from the union's own first hit" "union" "$(freeze_events | jq -r '.since_basis')"
assert_eq "…with nothing reported" "0" "$(last_guard_events | jq -s 'length')"

# The escalation already recorded past a spliced line is still found, so the
# freeze does not file twice.
printf '%s\n' "{\"ts\":\"$three_days_ago\",\"event\":\"limit-hit\",\"resume_at\":\"2099-01-01T00:00:00Z\"}" \
  "$spliced_line" \
  "{\"ts\":\"$three_days_ago\",\"event\":\"limit-freeze-escalated\",\"since\":\"$three_days_ago\",\"issue_number\":42}" \
  > "$union_log"
run_freeze_block "$now_s" "$auto_union"
assert_eq "an escalation already in the union past a spliced line is not filed again" "" "$(cat "$filed")"

# A union that could not be read: whether this freeze was already escalated
# cannot be told, so nothing is filed this cycle and a warning says why. Filing
# anyway would rest on the open-issue guard alone, which a closed escalation
# passes, so every such cycle would file it again.
printf '%s\n' "{\"ts\":\"$three_days_ago\",\"event\":\"limit-hit\",\"resume_at\":\"2099-01-01T00:00:00Z\"}" > "$union_log"
# shellcheck disable=SC2317  # the stub is called from $union_block_src via eval, invisible to a static reader
(limit_union_state() { echo "jq: killed" >&2; return 137; }; run_freeze_block "$now_s" "$auto_union")
assert_eq "a failed union read files no escalation" "" "$(cat "$filed")"
assert_eq "…reports the read under its own site" "cycle:union_record" "$(last_guard_events | jq -r '.site')"
assert_eq "…and says the escalation waits for the next cycle" "1" \
  "$(warning_events | jq -s '[.[] | select(.detail | test("not filed this cycle"))] | length')"

# The same for a union the snapshot could not build.
union_build_ok=0
run_freeze_block "$now_s" "$auto_union"
assert_eq "a union that could not be built files no escalation" "" "$(cat "$filed")"
assert_eq "…and says the escalation waits for the next cycle" "1" \
  "$(warning_events | jq -s '[.[] | select(.detail | test("not filed this cycle"))] | length')"
# shellcheck disable=SC2034  # read by the eval'd blocks, as above
union_build_ok=1

# No live hit in the union: the stand-down rests on fleet/limit.json alone,
# so the freeze is aged from the flag record's own `ts` — the time the flag was
# last written, its latest extension — which keys the escalation and is its
# `since`. Before, the age test was skipped, and a flag-only freeze never
# escalated however long it lasted.
printf '%s\n' '{"ts":"2026-09-17T06:54:54Z","event":"cycle-end"}' "$spliced_line" > "$union_log"
flag_record="{\"ts\":\"$three_days_ago\",\"resume_at\":\"2099-01-01T00:00:00Z\",\"kind\":\"auto\",\"class\":\"monthly\"}"
run_freeze_block "$now_s" "$flag_record"
assert_eq "a flag-only freeze three days old escalates, keyed on the flag record's time" \
  "usage-limit-freeze:$three_days_ago" "$(cat "$filed")"
assert_eq "…records that time as the escalation's since" "$three_days_ago" "$(freeze_events | jq -r '.since')"
assert_eq "…and says it is the flag record's time" "flag" "$(freeze_events | jq -r '.since_basis')"
assert_eq "…and so does the issue body" "1" \
  "$(grep -c 'the time fleet/limit.json was last written' "$tmp_dir/limit-freeze-issue.md")"
assert_eq "…with nothing reported" "0" "$(last_guard_events | jq -s 'length')"

flag_fresh="{\"ts\":\"$an_hour_ago\",\"resume_at\":\"2099-01-01T00:00:00Z\",\"kind\":\"auto\"}"
run_freeze_block "$now_s" "$flag_fresh"
assert_eq "a flag-only freeze an hour old files nothing" "" "$(cat "$filed")"
assert_eq "…and reports nothing, since nothing failed" "0" "$(last_guard_events | jq -s 'length')"

# A flag record with no `ts` cannot be aged. The age test is skipped — never
# fed `date -d ""`, whose midnight-today answer would read the freeze as
# under a day old — and the skip is reported.
run_freeze_block "$(( now_s + 3 * 86400 ))" "$auto_union"
assert_eq "a flag-only freeze with no ts files nothing" "" "$(cat "$filed")"
assert_eq "…and reports that its age could not be told" "freeze_since:flag" \
  "$(last_guard_events | jq -r '.site')"
unset -f create_escalation_issue

# =================================================================================
# Every guard site, structurally — the sweep the representative tests above
# cannot be: 67 near-identical one-liners are exactly the shape a copy-paste
# slip hides in, and the slip is invisible to the suite because the guarded
# command succeeds in every test that does not force it to fail. The form is
#
#   <var>="$(cmd … 2>&1)" || { guard_warn "<site>" "$<var>"; <var>=<fallback>; }
#
# and all three names must be the one variable the assignment targets: report
# some *other* variable's contents and the event names the wrong value; assign
# the fallback to some *other* variable and the guard both leaves the captured
# error text standing where a value belongs and clobbers a bystander. That
# second half is not hypothetical — the void closed-merge site shipped in this
# item's first pass writing `void_json='[]'` where it meant
# `void_actioned_json='[]'`, which would have emptied the whole void extract
# for the cycle (making every voided item selectable again) on any failure of
# a jq call nothing else re-checks.
# =================================================================================

# #771 moved most of agent-cycle.sh's own guard_warn sites out to lib/*.sh —
# the sweep below follows them there rather than assuming every site still
# lives in the one file it used to. Run per file (never one perl process over
# a concatenation of all of them): the walk-back-80-lines target search must
# not cross a file boundary into an unrelated file's tail.
guard_site_count=0
guard_site_mismatches=""
for guard_file in "$SCRIPT_DIR/agent-cycle.sh" "$SCRIPT_DIR"/lib/*.sh; do
  guard_site_report="$(perl -0777 -ne '
    my @lines = split /\n/, $_;
    my $sites = 0;
    for my $i (0 .. $#lines) {
      my $t = $lines[$i];
      next unless $t =~ /guard_warn\s+"/;      # skips the definition and the prose
      $sites++;
      my ($detail) = $t =~ /guard_warn\s+"[^"]*"\s+"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"/;
      my ($fb)     = $t =~ /guard_warn\s+"[^"]*"\s+"[^"]*";\s*([A-Za-z_][A-Za-z0-9_]*)=/;
      # The assignment this guard belongs to opens the statement, which the jq
      # program between them can carry a long way up the file — so walk back to
      # the nearest `<var>="$(`, rather than trying to rejoin a statement whose
      # continuations are raw newlines inside a single-quoted jq script.
      my $target;
      for (my $j = $i; $j >= 0 && $j > $i - 80; $j--) {
        if ($lines[$j] =~ /([A-Za-z_][A-Za-z0-9_]*)="\$\(/) { $target = $1; last }
      }
      for my $pair ([ "detail", $detail ], [ "fallback", $fb ]) {
        my ($what, $got) = @$pair;
        next if defined $target && defined $got && $target eq $got;
        printf "%s: %s names %s, assignment targets %s\n",
          $i + 1, $what, (defined $got ? $got : "(unparsed)"),
          (defined $target ? $target : "(unparsed)");
      }
    }
    print "sites=$sites\n";
  ' "$guard_file")"
  guard_file_count="$(sed -n 's/^sites=//p' <<<"$guard_site_report")"
  guard_file_mismatches="$(grep -v '^sites=' <<<"$guard_site_report" || true)"
  guard_site_count=$(( guard_site_count + guard_file_count ))
  if [[ -n "$guard_file_mismatches" ]]; then
    guard_site_mismatches="$guard_site_mismatches$(printf '%s:\n%s\n' "$guard_file" "$guard_file_mismatches")"
  fi
done

# A parser that matched nothing would pass the assertion below vacuously; the
# floor is deliberately well under the count this item converted, so ordinary
# additions and removals do not need to touch it, but a silent parse failure
# still fails here.
if (( guard_site_count < 50 )); then
  printf 'FAIL - found only %s guard_warn call sites across agent-cycle.sh and lib/*.sh (parser broken?)\n' \
    "$guard_site_count"
  failures=$(( failures + 1 ))
else
  printf 'ok   - swept %s guard_warn call sites\n' "$guard_site_count"
fi
assert_eq "every guard site reports and falls back on its own assignment target" \
  "" "$guard_site_mismatches"

echo "----------------------------------------"
if (( failures == 0 )); then
  echo "All assertions passed."
  exit 0
else
  echo "$failures assertion(s) failed."
  exit 1
fi
