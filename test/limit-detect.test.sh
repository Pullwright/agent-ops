#!/usr/bin/env bash
#
# test/limit-detect.test.sh — self-contained regression test for
# lib/limit-detect.sh (TD26071401).
#
# No test framework is used (none exists elsewhere in this repo); this is a
# plain bash script with hand-rolled assertions. Run it directly:
#
#   ./test/limit-detect.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/test/fixtures"

# shellcheck source=lib/limit-detect.sh
. "$SCRIPT_DIR/lib/limit-detect.sh"

weekly_fixture="$FIXTURES_DIR/weekly-limit.txt"
monthly_fixture="$FIXTURES_DIR/monthly-spend-limit.txt"
weekly_text="$(cat "$weekly_fixture")"
monthly_text="$(cat "$monthly_fixture")"

failures=0

assert_true() {
  local desc="$1"; shift
  if "$@"; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n' "$desc"
    failures=$(( failures + 1 ))
  fi
}

assert_false() {
  local desc="$1"; shift
  if ! "$@"; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n' "$desc"
    failures=$(( failures + 1 ))
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s (expected %q, got %q)\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}

assert_match() {
  local desc="$1" pattern="$2" actual="$3"
  if [[ "$actual" =~ $pattern ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s (%q did not match /%s/)\n' "$desc" "$actual" "$pattern"
    failures=$(( failures + 1 ))
  fi
}

# --- limit_phrase_in: the two exact record fixtures must both match --------
assert_true  "limit_phrase_in matches the weekly-limit fixture"        limit_phrase_in "$weekly_fixture"
assert_true  "limit_phrase_in matches the monthly-spend-limit fixture" limit_phrase_in "$monthly_fixture"

# --- limit_phrase_in: original terms must still match (no regression) -----
for phrase in 'usage limit exceeded' 'hit the rate limit' 'over the usage cap' 'quota exceeded, try later'; do
  tmp="$(mktemp)"
  printf '%s\n' "$phrase" > "$tmp"
  assert_true "limit_phrase_in still matches legacy phrase '$phrase'" limit_phrase_in "$tmp"
  rm -f "$tmp"
done

# --- limit_phrase_in: unrelated output must not match ----------------------
tmp="$(mktemp)"
printf 'Implemented the feature and opened a pull request.\n' > "$tmp"
assert_false "limit_phrase_in does not match ordinary output" limit_phrase_in "$tmp"
rm -f "$tmp"

# --- limit_phrase_regex_for / limit_phrase_in: per-provider phrase tables --
# Issue #2135: xAI's own limit messages ("too many requests", "resource has
# been exhausted", …) don't appear in Anthropic's table, and Anthropic's own
# phrasing doesn't appear in xAI's deliberately disjoint one (see the comment
# above XAI_LIMIT_PHRASE_REGEX in lib/limit-detect.sh) — so selecting a
# provider has to actually change which phrases match, not just which table
# happens to be in scope.
assert_eq "limit_phrase_regex_for returns Anthropic's table for anthropic" \
  "$LIMIT_PHRASE_REGEX" "$(limit_phrase_regex_for anthropic)"
assert_eq "limit_phrase_regex_for returns xAI's table for xai" \
  "$XAI_LIMIT_PHRASE_REGEX" "$(limit_phrase_regex_for xai)"
assert_eq "limit_phrase_regex_for fails closed onto Anthropic's table for an unrecognised provider" \
  "$LIMIT_PHRASE_REGEX" "$(limit_phrase_regex_for some-future-provider)"

# limit_phrase_in reads $limit_phrase_provider, a bash variable rather than an
# argument (see its own header) — unset or empty means anthropic, exactly as
# every call site before this issue behaved. The two fixtures already proved
# this above; this re-proves it with the variable explicitly unset, so a
# regression that made limit_phrase_in require the variable to be set would
# be caught here rather than only in callers that happen to set it.
unset limit_phrase_provider
assert_true  "limit_phrase_in with no provider set still matches the weekly-limit fixture" \
  limit_phrase_in "$weekly_fixture"
assert_true  "limit_phrase_in with no provider set still matches the monthly-spend-limit fixture" \
  limit_phrase_in "$monthly_fixture"

# provider=xai must match xAI's own phrasing...
xai_tmp="$(mktemp)"
printf 'Error: resource has been exhausted, try again later\n' > "$xai_tmp"
limit_phrase_provider=xai
assert_true  "limit_phrase_in with provider=xai matches xAI's own phrasing" \
  limit_phrase_in "$xai_tmp"
unset limit_phrase_provider
assert_false "limit_phrase_in with no provider set does not match xAI's own phrasing (tables are disjoint)" \
  limit_phrase_in "$xai_tmp"
rm -f "$xai_tmp"

# ...and the two Anthropic fixtures' own stems ("hit your weekly limit",
# "hit your monthly spend limit") must NOT read as an xAI limit: neither
# contains any of xAI's four phrases (checked by hand against both tables
# before writing this), so a provider=xai read of either must come back
# false, not fall through to Anthropic's table by accident.
limit_phrase_provider=xai
assert_false "limit_phrase_in with provider=xai does not match the weekly-limit fixture" \
  limit_phrase_in "$weekly_fixture"
assert_false "limit_phrase_in with provider=xai does not match the monthly-spend-limit fixture" \
  limit_phrase_in "$monthly_fixture"
unset limit_phrase_provider

# --- limit_class_of --------------------------------------------------------
assert_eq "limit_class_of classifies the weekly fixture"  "weekly"  "$(limit_class_of "$weekly_text")"
assert_eq "limit_class_of classifies the monthly fixture" "monthly" "$(limit_class_of "$monthly_text")"
assert_eq "limit_class_of classifies a generic rate-limit message as other" \
  "other" "$(limit_class_of "rate limit hit, please retry")"

# --- limit_parse_human_reset ------------------------------------------------
# Monthly fixture has no reset clause at all: must fail cleanly.
if reset="$(limit_parse_human_reset "$monthly_text" 2>/dev/null)"; then
  printf 'FAIL - limit_parse_human_reset should fail on the monthly fixture (got %q)\n' "$reset"
  failures=$(( failures + 1 ))
else
  printf 'ok   - limit_parse_human_reset fails cleanly on the monthly fixture\n'
fi

# Weekly fixture: "resets Jul 17, 4am (Pacific/Auckland)" must resolve to a
# concrete UTC instant. Assert on invariants rather than a hardcoded date so
# the test doesn't rot: valid ISO-8601 UTC, the instant is in the future (the
# year-rollover logic guarantees this), and converting it back to
# Pacific/Auckland wall-clock time reproduces "Jul 17 04:00" exactly — this is
# also the regression check for the TZ-handling bug (a naive
# `TZ=... date -d '...' -u ...` in one call silently drops the named zone
# because `-u` overrides TZ during parsing; see the comment in
# lib/limit-detect.sh).
weekly_resume="$(limit_parse_human_reset "$weekly_text")"
assert_match "limit_parse_human_reset returns an ISO-8601 UTC timestamp" \
  '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$weekly_resume"

if [[ -n "$weekly_resume" ]]; then
  resume_epoch="$(date -d "$weekly_resume" +%s 2>/dev/null || echo 0)"
  now_epoch="$(date +%s)"
  assert_true "limit_parse_human_reset's weekly resume_at is in the future" \
    bash -c "(( $resume_epoch > $now_epoch ))"

  auckland_wall_clock="$(TZ='Pacific/Auckland' date -d "@$resume_epoch" +'%b %d %H:%M')"
  assert_eq "the parsed instant is 04:00 Jul 17 in Pacific/Auckland" \
    "Jul 17 04:00" "$auckland_wall_clock"
fi

# --- limit_decide: the full resume_at/class/reset_known decision ----------
# Weekly: reset time is parseable, so resume_at must match the direct parse,
# class is weekly, and reset_known records that the time came from the message.
IFS=$'\t' read -r d_resume d_class d_reset_known < <(limit_decide "$weekly_text" 3)
assert_eq "limit_decide resume_at for weekly matches limit_parse_human_reset" "$weekly_resume" "$d_resume"
assert_eq "limit_decide class for weekly fixture" "weekly" "$d_class"
assert_eq "limit_decide reset_known is true for weekly fixture" "true" "$d_reset_known"

# Monthly: no reset time at all, so it must still log a limit-hit (non-empty
# resume_at) with a long fallback cooldown, and must mark the reset UNKNOWN —
# resume_at there is this system's own retry interval, not a stated reset. The
# earlier `needs_human` flag claimed more than the detector knows: a spend cap
# also clears by itself at the plan's rollover.
IFS=$'\t' read -r d_resume d_class d_reset_known < <(limit_decide "$monthly_text" 3)
assert_eq "limit_decide class for monthly fixture" "monthly" "$d_class"
assert_eq "limit_decide reset_known is false for monthly fixture" "false" "$d_reset_known"
if [[ -n "$d_resume" ]]; then
  d_resume_epoch="$(date -d "$d_resume" +%s 2>/dev/null || echo 0)"
  now_epoch="$(date +%s)"
  delta_hours=$(( (d_resume_epoch - now_epoch) / 3600 ))
  assert_true "limit_decide's monthly fallback is a long cooldown (>12h), not the 3h default" \
    bash -c "(( $delta_hours > 12 ))"
else
  printf 'FAIL - limit_decide produced no resume_at for the monthly fixture\n'
  failures=$(( failures + 1 ))
fi

# Generic/other phrasing with no timestamp: preserve the original behaviour
# of falling back to the short default cooldown. The reset is unknown here
# too — the cooldown is a guess, it is just a shorter one.
IFS=$'\t' read -r d_resume d_class d_reset_known < <(limit_decide "rate limit hit, please retry" 3)
assert_eq "limit_decide class for a generic rate-limit message" "other" "$d_class"
assert_eq "limit_decide reset_known is false for a generic rate-limit message" "false" "$d_reset_known"
if [[ -n "$d_resume" ]]; then
  d_resume_epoch="$(date -d "$d_resume" +%s 2>/dev/null || echo 0)"
  now_epoch="$(date +%s)"
  delta_seconds=$(( d_resume_epoch - now_epoch ))
  # Allow a couple of minutes' slack for the time this test itself takes to run.
  assert_true "limit_decide's generic fallback honours the passed-in default cooldown (~3h)" \
    bash -c "(( $delta_seconds > (3 * 3600 - 120) && $delta_seconds < (3 * 3600 + 120) ))"
else
  printf 'FAIL - limit_decide produced no resume_at for the generic fixture\n'
  failures=$(( failures + 1 ))
fi

# --- limit_union_record: the reduction the stand-down and dashboard share --
# Time-ordered, most-recent-wins, over both limit events.
union_hits="$(printf '%s\n' \
  '{"ts":"2026-01-01T00:00:00Z","event":"limit-hit","resume_at":"2030-01-01T00:00:00Z","class":"weekly","reset_known":true}' \
  '{"ts":"2026-01-01T01:00:00Z","event":"cycle-end","exit_code":0}' \
  '{"ts":"2026-01-01T02:00:00Z","event":"limit-hit","resume_at":"2031-01-01T00:00:00Z","class":"monthly","reset_known":false}')"
assert_eq "limit_union_record returns the most recent limit-hit" \
  "2031-01-01T00:00:00Z" "$(limit_union_record <<<"$union_hits" | jq -r '.resume_at')"

# The whole point of the new event: a limit-cleared written afterwards retires
# the stand-down. Without it nothing could ever lift one, because the check
# runs before any stage and no cycle could reach a success to clear it.
union_cleared="$union_hits
{\"ts\":\"2026-01-01T03:00:00Z\",\"event\":\"limit-cleared\",\"was\":\"2031-01-01T00:00:00Z\"}"
assert_eq "a later limit-cleared supersedes the limit-hit" \
  "" "$(limit_union_record <<<"$union_cleared")"

# ...and a limit hit *after* a clear stands the fleet down again.
union_recleared="$union_cleared
{\"ts\":\"2026-01-01T04:00:00Z\",\"event\":\"limit-hit\",\"resume_at\":\"2032-01-01T00:00:00Z\",\"class\":\"weekly\",\"reset_known\":true}"
assert_eq "a limit-hit after a limit-cleared stands down again" \
  "2032-01-01T00:00:00Z" "$(limit_union_record <<<"$union_recleared" | jq -r '.resume_at')"

assert_eq "limit_union_record is empty for a stream with no limit events" \
  "" "$(limit_union_record <<<'{"ts":"2026-01-01T00:00:00Z","event":"cycle-end"}')"

# --- limit_standdown_since: the start of the current freeze (#244) ---------
# The escalation of requirement 2 ages a freeze from its first hit, not its
# latest extension — a freeze that keeps re-confirming itself must not keep
# resetting the clock that decides when a human hears about it.
assert_eq "limit_standdown_since names the first hit of an unbroken freeze" \
  "2026-01-01T00:00:00Z" "$(limit_standdown_since <<<"$union_hits")"
assert_eq "a limit-cleared ends the freeze: nothing to age" \
  "" "$(limit_standdown_since <<<"$union_cleared")"
assert_eq "a hit after a clear starts a new freeze at its own ts, not the old one's" \
  "2026-01-01T04:00:00Z" "$(limit_standdown_since <<<"$union_recleared")"
assert_eq "limit_standdown_since is empty for a stream with no limit events" \
  "" "$(limit_standdown_since <<<'{"ts":"2026-01-01T00:00:00Z","event":"cycle-end"}')"

# --- A union line that does not parse (#2037) ------------------------------
# The shape both VM nodes' logs carried from their disk-pressure period: a
# record cut off part-way, with no newline, run into a whole later record on
# the same line. One such line anywhere in the union made a slurp abort, so
# both readers printed nothing — a governing limit read as no limit, and the
# freeze had no start to age from. The line is skipped; everything around it
# still counts.
spliced_hit='{"ts":"2026-09-17T06:54:54Z","event":"limit-hit","resume_at":"2099-01-01T00:00:00Z"}'
spliced_line='{"ts":"2026-09-18T00:00:00Z","event":"github-budget","core":{"limit":5000,"{"ts":"2026-09-18T00:05:00Z","event":"cycle-end","exit_code":0}'
assert_eq "limit_union_record still finds the governing hit past a spliced line" \
  "2099-01-01T00:00:00Z" \
  "$(printf '%s\n' "$spliced_hit" "$spliced_line" | limit_union_record | jq -r '.resume_at')"
assert_eq "…and before one" \
  "2099-01-01T00:00:00Z" \
  "$(printf '%s\n' "$spliced_line" "$spliced_hit" | limit_union_record | jq -r '.resume_at')"
assert_eq "limit_standdown_since still names the freeze's start past a spliced line" \
  "2026-09-17T06:54:54Z" "$(printf '%s\n' "$spliced_hit" "$spliced_line" | limit_standdown_since)"
# Most-recent-wins is unchanged by the skip: a clear after the bad line still
# retires the hit before it, and a hit after the clear still starts a new
# freeze at its own ts.
spliced_cleared="$(printf '%s\n' "$spliced_hit" "$spliced_line" \
  '{"ts":"2026-09-19T00:00:00Z","event":"limit-cleared"}')"
assert_eq "a limit-cleared past a spliced line still supersedes the hit" \
  "" "$(limit_union_record <<<"$spliced_cleared")"
assert_eq "…and leaves no freeze to age" "" "$(limit_standdown_since <<<"$spliced_cleared")"
spliced_rehit="$spliced_cleared"$'\n''{"ts":"2026-09-20T00:00:00Z","event":"limit-hit","resume_at":"2099-02-01T00:00:00Z"}'
assert_eq "a hit after that clear governs again" \
  "2099-02-01T00:00:00Z" "$(limit_union_record <<<"$spliced_rehit" | jq -r '.resume_at')"
assert_eq "…and starts a new freeze at its own ts" \
  "2026-09-20T00:00:00Z" "$(limit_standdown_since <<<"$spliced_rehit")"
# A line that parses to something other than a record (a stump that happens
# to be a bare number or string) is skipped too, rather than failing the
# whole read on `.event`.
assert_eq "a line that parses to a non-object is skipped, not fatal" \
  "2099-01-01T00:00:00Z" \
  "$(printf '%s\n' "$spliced_hit" '5000' '"text"' '[1]' | limit_union_record | jq -r '.resume_at')"
# An unparseable line is the reader's to skip; a read that fails outright is
# not, and must not pass for "no limit": the exit status carries it to the
# caller, which reports it (`guard_warn` in agent-cycle.sh). A jq that dies —
# the OOM kill of 2026-10-01 — is stood in for by one that exits 137.
fake_jq_dir="$(mktemp -d)"
printf '#!/bin/sh\necho "jq: killed" >&2\nexit 137\n' > "$fake_jq_dir/jq"
chmod +x "$fake_jq_dir/jq"
if PATH="$fake_jq_dir:$PATH" limit_union_record <<<"$spliced_hit" >/dev/null 2>&1; then
  printf 'FAIL - limit_union_record reports a failed read as success\n'
  failures=$(( failures + 1 ))
else
  printf 'ok   - limit_union_record exits non-zero when its read fails outright\n'
fi
if PATH="$fake_jq_dir:$PATH" limit_standdown_since <<<"$spliced_hit" >/dev/null 2>&1; then
  printf 'FAIL - limit_standdown_since reports a failed read as success\n'
  failures=$(( failures + 1 ))
else
  printf 'ok   - limit_standdown_since exits non-zero when its read fails outright\n'
fi

# limit_union_state gives the stand-down all three answers from one pass —
# the governing hit, the freeze's start and the escalation memory — where it
# read the union three times (#2037). The same fold backs the two readers
# above, so the three can never disagree.
state_union="$(printf '%s\n' \
  '{"ts":"2026-09-16T00:00:00Z","event":"limit-hit","resume_at":"2099-01-01T00:00:00Z"}' \
  "$spliced_line" \
  '{"ts":"2026-09-17T00:00:00Z","event":"limit-freeze-escalated","since":"2026-09-16T00:00:00Z"}' \
  '{"ts":"2026-09-18T00:00:00Z","event":"limit-hit","resume_at":"2099-02-01T00:00:00Z"}' \
  '{"ts":"2026-09-19T00:00:00Z","event":"limit-freeze-escalated","since":7}')"
assert_eq "limit_union_state answers the governing hit, the freeze's start and the escalations in one pass" \
  '{"resume_at":"2099-02-01T00:00:00Z","since":"2026-09-16T00:00:00Z","escalated":["2026-09-16T00:00:00Z"]}' \
  "$(limit_union_state <<<"$state_union" | jq -c '{resume_at: .record.resume_at, since, escalated}')"
assert_eq "…and agrees with limit_union_record" "2099-02-01T00:00:00Z" \
  "$(limit_union_record <<<"$state_union" | jq -r '.resume_at')"
assert_eq "…and with limit_standdown_since" "2026-09-16T00:00:00Z" "$(limit_standdown_since <<<"$state_union")"
assert_eq "limit_union_state over a stream with no limit events answers nothing for each" \
  '{"record":null,"since":null,"escalated":[]}' \
  "$(limit_union_state <<<'{"ts":"2026-01-01T00:00:00Z","event":"cycle-end"}')"
if PATH="$fake_jq_dir:$PATH" limit_union_state <<<"$spliced_hit" >/dev/null 2>&1; then
  printf 'FAIL - limit_union_state reports a failed read as success\n'
  failures=$(( failures + 1 ))
else
  printf 'ok   - limit_union_state exits non-zero when its read fails outright\n'
fi
rm -rf "$fake_jq_dir"

# --- limit_union_record_for / limit_union_state_for / limit_union_frozen_providers:
#     issue #2135's per-provider folding -------------------------------------
# Before this issue every limit-hit this system ever wrote carried no
# `provider` field at all, and governed every account at once because there
# was only ever one account. LIMIT_UNION_JQ's fold now keys each event by its
# own `provider`, with the empty string "" standing in for the wildcard
# bucket an unscoped event falls into — so a hit on one provider's account
# must stand down only that provider, while a record with no provider at all
# (every event from before #2133, and a bare fleet-wide --clear-limit) still
# has to govern every provider, the same back-compat rule
# limit_flag_record_for applies to the flag carrier.

# Two providers hit independently: each one's own query sees only its own.
two_provider_hits="$(printf '%s\n' \
  '{"ts":"2026-02-01T00:00:00Z","event":"limit-hit","resume_at":"2099-01-01T00:00:00Z","provider":"anthropic"}' \
  '{"ts":"2026-02-02T00:00:00Z","event":"limit-hit","resume_at":"2099-02-01T00:00:00Z","provider":"xai"}')"
assert_eq "limit_union_record_for sees only anthropic's own hit" \
  "2099-01-01T00:00:00Z" "$(limit_union_record_for anthropic <<<"$two_provider_hits" | jq -r '.resume_at')"
assert_eq "limit_union_record_for sees only xai's own hit" \
  "2099-02-01T00:00:00Z" "$(limit_union_record_for xai <<<"$two_provider_hits" | jq -r '.resume_at')"
assert_eq "limit_union_record_for is clear for a third provider neither hit named" \
  "" "$(limit_union_record_for grok <<<"$two_provider_hits")"

# A wildcard (no-provider) hit governs every provider — the pre-#2133 record's
# own reach, preserved.
wildcard_hit='{"ts":"2026-02-01T00:00:00Z","event":"limit-hit","resume_at":"2099-03-01T00:00:00Z"}'
assert_eq "a wildcard limit-hit governs a provider that never had its own" \
  "2099-03-01T00:00:00Z" "$(limit_union_record_for anthropic <<<"$wildcard_hit" | jq -r '.resume_at')"
assert_eq "…and a different provider too" \
  "2099-03-01T00:00:00Z" "$(limit_union_record_for xai <<<"$wildcard_hit" | jq -r '.resume_at')"

# Later-of-two wins within one provider's own query, the same "later resume
# wins" limit_later_record applies across carriers, applied here a second
# time inside the union itself: a provider's own later hit beats an earlier
# wildcard, and a later wildcard beats an earlier provider-own hit.
own_later_than_wildcard="$(printf '%s\n' \
  '{"ts":"2026-02-01T00:00:00Z","event":"limit-hit","resume_at":"2099-01-01T00:00:00Z"}' \
  '{"ts":"2026-02-02T00:00:00Z","event":"limit-hit","resume_at":"2099-04-01T00:00:00Z","provider":"anthropic"}')"
assert_eq "a provider's own later hit wins over an earlier wildcard" \
  "2099-04-01T00:00:00Z" "$(limit_union_record_for anthropic <<<"$own_later_than_wildcard" | jq -r '.resume_at')"
wildcard_later_than_own="$(printf '%s\n' \
  '{"ts":"2026-02-01T00:00:00Z","event":"limit-hit","resume_at":"2099-01-01T00:00:00Z","provider":"anthropic"}' \
  '{"ts":"2026-02-02T00:00:00Z","event":"limit-hit","resume_at":"2099-05-01T00:00:00Z"}')"
assert_eq "a later wildcard hit wins over a provider's own earlier one" \
  "2099-05-01T00:00:00Z" "$(limit_union_record_for anthropic <<<"$wildcard_later_than_own" | jq -r '.resume_at')"

# A provider-scoped limit-cleared clears only its own bucket, leaving every
# other provider's own hit standing — the one place this issue's scoping
# actually changes clearing behaviour, since a clear used to be fleet-wide by
# definition.
provider_cleared="$two_provider_hits
{\"ts\":\"2026-02-03T00:00:00Z\",\"event\":\"limit-cleared\",\"provider\":\"anthropic\"}"
assert_eq "a provider-scoped limit-cleared clears only that provider" \
  "" "$(limit_union_record_for anthropic <<<"$provider_cleared")"
assert_eq "…and leaves the other provider's own hit standing" \
  "2099-02-01T00:00:00Z" "$(limit_union_record_for xai <<<"$provider_cleared" | jq -r '.resume_at')"

# A wildcard (no-provider) limit-cleared resets every bucket seen so far at
# once — the "clear everything" behaviour a bare --clear-limit has always
# had, preserved exactly for providers that have never named themselves.
wildcard_cleared="$two_provider_hits
{\"ts\":\"2026-02-03T00:00:00Z\",\"event\":\"limit-cleared\"}"
assert_eq "a wildcard limit-cleared clears anthropic's own bucket" \
  "" "$(limit_union_record_for anthropic <<<"$wildcard_cleared")"
assert_eq "…and xai's own bucket too" \
  "" "$(limit_union_record_for xai <<<"$wildcard_cleared")"

# limit_union_state_for prints the same {"record":…,"since":…,"escalated":[…]}
# shape limit_union_state has always printed, narrowed to one provider.
assert_eq "limit_union_state_for answers the same shape as limit_union_state, scoped to one provider" \
  '{"resume_at":"2099-01-01T00:00:00Z","since":"2026-02-01T00:00:00Z"}' \
  "$(limit_union_state_for anthropic <<<"$two_provider_hits" | jq -c '{resume_at: .record.resume_at, since}')"
assert_eq "limit_union_state_for over a provider with nothing recorded answers nothing for each field" \
  '{"record":null,"since":null,"escalated":[]}' \
  "$(limit_union_state_for grok <<<"$two_provider_hits")"

# limit_union_frozen_providers: every bucket (the wildcard included, printed
# as the empty string) whose own record is currently non-null — the
# dashboard/Monitor's enumeration of who is frozen right now, rather than
# checking one provider at a time.
frozen_mixed="$(printf '%s\n' \
  '{"ts":"2026-02-01T00:00:00Z","event":"limit-hit","resume_at":"2099-01-01T00:00:00Z","provider":"anthropic"}' \
  '{"ts":"2026-02-02T00:00:00Z","event":"limit-hit","resume_at":"2099-02-01T00:00:00Z","provider":"xai"}' \
  '{"ts":"2026-02-03T00:00:00Z","event":"limit-cleared","provider":"xai"}' \
  '{"ts":"2026-02-04T00:00:00Z","event":"limit-hit","resume_at":"2099-03-01T00:00:00Z"}')"
assert_eq "limit_union_frozen_providers lists exactly the currently-recorded buckets (xai was cleared, anthropic and the wildcard were not)" \
  "$(printf '%s\n' "" anthropic | sort)" \
  "$(limit_union_frozen_providers <<<"$frozen_mixed" | sort)"

# --- limit_flag_record_for: fleet/limit.json's own record, narrowed --------
# The flag holds exactly one record at a time. A record with no `provider`
# field at all applies to every provider — the "before issue #2133" reading,
# identical to the wildcard bucket above — while a record naming one provider
# applies only to that provider, never to a different one asking.
rec_anthropic='{"provider":"anthropic","resume_at":"2030-01-01T00:00:00Z"}'
assert_eq "a record scoped to anthropic is returned when anthropic asks" \
  "$rec_anthropic" "$(limit_flag_record_for "$rec_anthropic" anthropic)"
assert_eq "…and withheld when a different provider asks" \
  "" "$(limit_flag_record_for "$rec_anthropic" xai)"

rec_no_provider='{"resume_at":"2030-01-01T00:00:00Z"}'
assert_eq "a record with no provider field applies to anthropic" \
  "$rec_no_provider" "$(limit_flag_record_for "$rec_no_provider" anthropic)"
assert_eq "…and to xai too (it predates issue #2133, or was hand-written/migrated)" \
  "$rec_no_provider" "$(limit_flag_record_for "$rec_no_provider" xai)"

assert_eq "empty RAW returns nothing" "" "$(limit_flag_record_for "" anthropic)"
assert_eq "garbage RAW returns nothing" "" "$(limit_flag_record_for "not json at all" anthropic)"

# --- limit_later_record: requirement 2.1's "later resume wins" -------------
rec_early='{"resume_at":"2030-01-01T00:00:00Z","class":"weekly","reset_known":true}'
rec_late='{"resume_at":"2031-01-01T00:00:00Z","class":"monthly","reset_known":false}'
assert_eq "limit_later_record picks the later resume, whatever the argument order" \
  "2031-01-01T00:00:00Z" "$(limit_later_record "$rec_late" "$rec_early" | jq -r '.resume_at')"
assert_eq "limit_later_record picks the later resume (reversed)" \
  "2031-01-01T00:00:00Z" "$(limit_later_record "$rec_early" "$rec_late" | jq -r '.resume_at')"
assert_eq "limit_later_record skips a carrier that is clear" \
  "2030-01-01T00:00:00Z" "$(limit_later_record "" "$rec_early" | jq -r '.resume_at')"
assert_eq "limit_later_record is empty when every carrier is clear" \
  "" "$(limit_later_record "" "")"

# --- limit_reset_known: the field, and the superseded one ------------------
assert_eq "limit_reset_known reads reset_known when present" \
  "false" "$(limit_reset_known '{"reset_known":false}')"
# A peer still running the previous release publishes needs_human, whose sense
# is inverted; reading it wrong would call an invented time authoritative.
assert_eq "limit_reset_known inverts a legacy needs_human:true" \
  "false" "$(limit_reset_known '{"needs_human":true}')"
assert_eq "limit_reset_known inverts a legacy needs_human:false" \
  "true" "$(limit_reset_known '{"needs_human":false}')"

# --- limit_describe: what the operator is actually told --------------------
known_note="$(limit_describe "2030-01-01T00:00:00Z" weekly true)"
assert_eq "a stated reset is described as a deadline" \
  "until 2030-01-01T00:00:00Z" "$known_note"

# The correction this change exists for: an unstated reset must not be
# presented as a deadline, and must name BOTH ways out — waiting for the
# rollover (no human) and raising the cap (a human, only if sooner is wanted).
#
# Checked in-process rather than through `bash -c`: the note contains an
# apostrophe ("the plan's rollover"), which no amount of quoting survives
# being interpolated into a child shell's `[[ ]]`.
contains() { if [[ "$1" == *"$2"* ]]; then echo yes; else echo no; fi; }
guess_note="$(limit_describe "2030-01-01T00:00:00Z" monthly false)"
assert_eq "an unstated reset is marked as an estimate" \
  "yes" "$(contains "$guess_note" "estimated")"
assert_eq "an unstated reset is not presented as a deadline" \
  "no" "$(contains "$guess_note" "until ")"
assert_eq "an unstated reset says it clears at the rollover on its own" \
  "yes" "$(contains "$guess_note" "rollover")"
assert_eq "an unstated reset offers --clear-limit as the way to resume sooner" \
  "yes" "$(contains "$guess_note" "--clear-limit")"
assert_eq "no limit is ever described as needing a human before it can clear" \
  "no" "$(contains "$guess_note" "needs human")"
assert_eq "an unstated reset says the cycle's probe is watching for the lift" \
  "yes" "$(contains "$guess_note" "probe")"

# --- limit_probe_verdict: the three answers a probe can give ---------------
# The envelope fixtures are canned transcripts of the two real probe shapes
# observed on 2026-07-28: a clean answer, and a 429 whose limit message
# arrives *inside* a well-formed envelope's `result` — the case the
# phrase-first ordering exists for, because that envelope parses perfectly
# and only `is_error` and the phrase say what it actually is.
clear_envelope="$(cat "$FIXTURES_DIR/probe-clear-envelope.txt")"
limited_envelope="$(cat "$FIXTURES_DIR/probe-limited-envelope.txt")"

assert_eq "a clean envelope with a result is clear" \
  "clear" "$(limit_probe_verdict "$clear_envelope")"
assert_eq "a well-formed envelope carrying the limit message is limited, never clear" \
  "limited" "$(limit_probe_verdict "$limited_envelope")"
assert_eq "a raw limit message with no envelope at all is limited" \
  "limited" "$(limit_probe_verdict "$monthly_text")"
assert_eq "the limit phrase on stderr outweighs a clean envelope on stdout" \
  "limited" "$(limit_probe_verdict "$clear_envelope" "$monthly_text")"
assert_eq "an empty transcript is inconclusive" \
  "inconclusive" "$(limit_probe_verdict "" "")"
assert_eq "stderr diagnostics alone are inconclusive, never clear" \
  "inconclusive" "$(limit_probe_verdict "" "connect: connection refused")"
assert_eq "a failed envelope with no limit phrase is inconclusive" \
  "inconclusive" "$(limit_probe_verdict '{"is_error":true,"result":"upstream connect error"}')"
assert_eq "a clean envelope with an empty result is inconclusive" \
  "inconclusive" "$(limit_probe_verdict '{"is_error":false,"result":""}')"

# --- limit_probe_verdict: PROVIDER selects the phrase table (issue #2135) --
# The probe now runs against the frozen provider's own adapter, so its
# transcript carries that provider's own wording — an xAI-specific phrase
# must be read as "limited" when the probe says it ran against xai, and must
# NOT be mistaken for a limit at all when read under Anthropic's table
# (the default, and what every call site used before this issue), since
# "resource has been exhausted" never appears in Anthropic's own phrasing.
xai_probe_text="Error: resource has been exhausted, try again later"
assert_eq "an xAI phrase with provider=xai is limited" \
  "limited" "$(limit_probe_verdict "$xai_probe_text" "" xai)"
assert_eq "the same xAI phrase with provider=anthropic is not read as a limit at all" \
  "inconclusive" "$(limit_probe_verdict "$xai_probe_text" "" anthropic)"
assert_eq "…and the same, with PROVIDER simply omitted (anthropic's own default)" \
  "inconclusive" "$(limit_probe_verdict "$xai_probe_text")"
# The phrase check runs over both streams: an xAI phrase on stderr must be
# caught the same way one on stdout is, for the provider it actually belongs
# to.
assert_eq "an xAI phrase on stderr alone is limited for provider=xai" \
  "limited" "$(limit_probe_verdict "" "$xai_probe_text" xai)"

# --- limit_decide_structured: the runner's own record, not its prose -------
# The better source wherever it exists, for a reason worth pinning down: a
# stated `resetsAt` makes the stand-down a fact rather than an estimate, and
# an estimated stand-down costs the fleet a usage probe every cycle until it
# clears. So `reset_known` must come back `true` here where the prose path
# would usually have to guess.
assert_eq "a structured record with a reset time yields that exact time, known" \
  "$(date -u -d @1786086000 +%Y-%m-%dT%H:%M:%SZ)	other	true" \
  "$(limit_decide_structured '{"status":"rejected","resetsAt":1786086000,"rateLimitType":"five_hour"}' 3)"

# The class exists only to choose a fallback cooldown, so it follows what that
# fallback is for — the long weekly kind — not what the limit is called.
assert_eq "a seven-day limit is the weekly class" "weekly" \
  "$(limit_decide_structured '{"status":"rejected","rateLimitType":"seven_day_opus"}' 3 | cut -f2)"
assert_eq "…and with no stated reset falls back to the long cooldown, unknown" \
  "false" \
  "$(limit_decide_structured '{"status":"rejected","rateLimitType":"seven_day_opus"}' 3 | cut -f3)"
assert_eq "a five-hour limit is not the weekly class" "other" \
  "$(limit_decide_structured '{"status":"rejected","rateLimitType":"five_hour"}' 3 | cut -f2)"

# Nothing usable must be a refusal to answer, not a fabricated stand-down: the
# caller falls back to the phrase matcher, which is what has always handled
# this.
for junk in '' 'not json at all' '[]' 'null'; do
  if limit_decide_structured "$junk" 3 >/dev/null 2>&1; then
    printf 'FAIL - limit_decide_structured answered for unusable input: %s\n' "${junk:-<empty>}"
    failures=$(( failures + 1 ))
  else
    printf 'ok   - unusable input (%s) is declined rather than guessed at\n' "${junk:-<empty>}"
  fi
done

# --- Regression guard: must not abort under `set -e -o pipefail` ----------
# agent-cycle.sh runs with `set -euo pipefail`. Several helpers above build a
# result via `grep ... | head -n1` inside a plain assignment; under
# `pipefail`, grep finding nothing (the common case — most limit messages
# carry neither an ISO timestamp nor a weekly reset clause) makes that
# pipeline exit non-zero, which aborts the whole script under `-e` unless the
# assignment ends in `|| true`. This bit exactly once already (limit_decide's
# ISO-timestamp grep and limit_parse_human_reset's clause grep both lacked
# it), so exercise every public function in exactly that caller context,
# with input that guarantees each internal grep comes up empty.
strict_probe="$(bash -euo pipefail -c '
  source "'"$SCRIPT_DIR"'/lib/limit-detect.sh"
  limit_phrase_in "'"$monthly_fixture"'" /nonexistent || true
  limit_class_of "no timestamp, no weekly or monthly word here" >/dev/null
  limit_parse_human_reset "no reset clause in this text at all" 2>/dev/null || true
  limit_decide "no timestamp, no reset clause, no weekly or monthly word" 3 >/dev/null
  limit_decide_structured "{}" 3 >/dev/null
  limit_decide_structured "not json at all" 3 >/dev/null || true
  limit_probe_verdict "" "" >/dev/null
  echo STRICT_MODE_SURVIVED
' 2>&1)"
assert_eq "every limit-detect helper survives set -e -o pipefail with a non-matching input" \
  "STRICT_MODE_SURVIVED" "$(tail -n1 <<<"$strict_probe")"
if [[ "$(tail -n1 <<<"$strict_probe")" != "STRICT_MODE_SURVIVED" ]]; then
  printf '%s\n' "$strict_probe"
fi

echo
if (( failures == 0 )); then
  echo "All limit-detect assertions passed."
  exit 0
else
  echo "$failures limit-detect assertion(s) FAILED."
  exit 1
fi
