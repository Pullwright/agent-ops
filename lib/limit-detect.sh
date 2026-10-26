#!/usr/bin/env bash
#
# lib/limit-detect.sh — shared usage-limit / spend-cap detection.
#
# Sourced by agent-cycle.sh, review-cycle.sh, monitor-cycle.sh,
# scripts/node-health.sh and scripts/publish-dashboard.sh so the phrase
# pattern, the reset-time parsing and the union's limit reduction live in
# exactly one place and the detectors can't drift apart again (see
# TD26071401). The union readers below fold UNION_STREAM_JQ's tolerant event
# stream, so this file sources lib/union-stream.sh itself, as
# lib/fleet-sizing.sh does: a test or script that sources this file alone
# still gets readers that work.
#
# Claude emits (at least) two distinct "you've hit a limit" messages, and they
# need different downstream handling:
#   - Weekly/rolling usage limit — "You've hit your weekly limit · resets Jul
#     17, 4am (Pacific/Auckland)". Carries a parseable reset time: stand down
#     until exactly then.
#   - Monthly spend cap — "You've hit your monthly spend limit · raise it at
#     claude.ai/settings/usage". Carries no reset time; clears only when a
#     human raises the cap (or the billing month rolls over) — auto-retry
#     cannot fix it.
# Both share the stem "You've hit your ... limit", so a single case-insensitive
# `hit your .* limit` term catches every observed variant, alongside the
# original terms this project has looked for from the start.

# The tolerant raw-line event stream the union readers fold (#2037).
# shellcheck source=lib/union-stream.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/union-stream.sh"

# Case-insensitive ERE fed to `grep -E`. This is the one place either script's
# limit-phrase pattern comes from — do not inline a copy elsewhere. Anthropic's
# own phrasing only: `rate limit` already matches xAI's transient 429 text
# ("Too many requests: Rate limit exceeded …"), which is `stage_api_refusal`'s
# business (a short retry), not a weekly/monthly stand-down — issue #2135's own
# xAI phrases below are deliberately a disjoint set for exactly this reason.
LIMIT_PHRASE_REGEX='hit your .* limit|usage limit|rate limit|usage cap|quota exceeded'

# xAI's own "you've hit a limit" phrasing (issue #2135, from #2132's record
# and the review of #2132, PR #2195): a weekly/monthly usage limit ("too many
# requests", observed on the subscription lane) and a spend/credit cap
# ("resource has been exhausted", "used all available credits", "spending
# limit"), on the Grok Build substrate.
#
# "too many requests" also opens xAI's own transient 429 text ("Too many
# requests: Rate limit exceeded"), and `detect_and_log_limit_hit` below reads
# raw output text regardless of any refusal classification already applied to
# the same attempt — so a transient rate limit can still match this phrase
# and open an *estimated* stand-down for the xai provider alone. That
# mis-fire is bounded, not open-ended: neither this phrase nor xAI's 429 text
# contains "weekly"/"monthly", so `limit_class_of` grades it "other" and
# `limit_decide` falls back to `limit_cooldown_default_hours` (a few hours,
# not `LIMIT_LONG_COOLDOWN_HOURS`'s 24), and 2.1b's own probe — now run
# against xAI's own adapter (`limit_probe_model_for`) — retires it the moment
# the account next answers. Narrowing the phrase further would need telling
# xAI's two "too many requests" messages apart by more than substring
# matching, which this system has no evidence to do today.
XAI_LIMIT_PHRASE_REGEX='too many requests|resource has been exhausted|used all available credits|spending limit'

# limit_phrase_regex_for PROVIDER
# The phrase pattern `limit_phrase_in`/`limit_probe_verdict` should apply for
# PROVIDER: Anthropic's own `LIMIT_PHRASE_REGEX` for `anthropic` (and anything
# unrecognised, so a future provider with no table of its own here fails
# closed onto the one pattern this system has always used rather than
# matching nothing at all), `XAI_LIMIT_PHRASE_REGEX` for `xai`.
limit_phrase_regex_for() {
  case "$1" in
    xai) printf '%s' "$XAI_LIMIT_PHRASE_REGEX" ;;
    *)   printf '%s' "$LIMIT_PHRASE_REGEX" ;;
  esac
}

# limit_phrase_in FILE...
# True if any of the given files (missing files are silently ignored) contain
# a limit/quota phrase for $limit_phrase_provider (the caller's own
# `stage_provider`, or unset/empty) — `limit_phrase_regex_for` above's table.
# A variable rather than an argument, like `detect_and_log_limit_hit`'s own
# `stage_provider`/`stage_rate_limit_json` reads: every one of this
# function's three production callers (lib/candidate-select.sh,
# review-cycle.sh, monitor-cycle.sh) and every existing test call it with
# FILE... alone, so threading a new positional through all of them to carry
# one more piece of ambient per-stage context would touch far more call sites
# than it saves.
limit_phrase_in() {
  grep -qihE "$(limit_phrase_regex_for "${limit_phrase_provider:-anthropic}")" "$@" 2>/dev/null
}

# limit_class_of TEXT
# Echoes "weekly", "monthly", or "other" depending on which class of limit the
# text describes. The class decides both which reset-time parse applies and
# how long the fallback cooldown should be when no reset time can be parsed.
limit_class_of() {
  local text="$1"
  if grep -qiE 'weekly' <<<"$text"; then
    echo weekly
  elif grep -qiE 'monthly' <<<"$text"; then
    echo monthly
  else
    echo other
  fi
}

# limit_parse_human_reset TEXT
# Parses a human-readable "resets <Month> <day>, <time> (<Named/Zone>)" clause
# (e.g. "resets Jul 17, 4am (Pacific/Auckland)") to a concrete UTC ISO-8601
# timestamp on stdout. Returns 1 with no output if no such clause is present.
#
# The message never states a year, so this assumes the next upcoming
# occurrence of that month/day, rolling forward a year if the naive parse
# would fall in the past.
#
# The named zone must be applied via TZ, not left in the string: `date -d`
# fed the whole "<time> (<Zone>)" text does not understand the parenthesised
# zone and silently ignores it. It must also NOT be combined with `date -u`
# in the same call — `-u` operates as though TZ were UTC0, which would
# override (not compose with) the named zone. So this parses in two steps:
# first resolve the local wall-clock time to an epoch under `TZ=<Zone>` with
# no `-u`, then format that epoch in UTC as a separate `date -u -d @<epoch>`
# call.
limit_parse_human_reset() {
  local text="$1" clause month day time tz year epoch now_epoch
  clause="$(grep -oiE "resets?[[:space:]]+[A-Za-z]+[[:space:]]+[0-9]{1,2},[[:space:]]*[0-9]{1,2}(:[0-9]{2})?[[:space:]]*[ap]m[[:space:]]*\([A-Za-z_/+-]+\)" <<<"$text" | head -n1 || true)"
  [[ -n "$clause" ]] || return 1

  shopt -s nocasematch
  if [[ "$clause" =~ ^resets?[[:space:]]+([A-Za-z]+)[[:space:]]+([0-9]{1,2}),[[:space:]]*([0-9]{1,2}(:[0-9]{2})?[[:space:]]*[ap]m)[[:space:]]*\(([A-Za-z_/+-]+)\)$ ]]; then
    month="${BASH_REMATCH[1]}"
    day="${BASH_REMATCH[2]}"
    time="${BASH_REMATCH[3]}"
    tz="${BASH_REMATCH[5]}"
  else
    shopt -u nocasematch
    return 1
  fi
  shopt -u nocasematch

  year="$(date -u +%Y)"
  epoch="$(TZ="$tz" date -d "$month $day $year $time" +%s 2>/dev/null)" || return 1
  now_epoch="$(date +%s)"
  if (( epoch < now_epoch )); then
    epoch="$(TZ="$tz" date -d "$month $day $((year + 1)) $time" +%s 2>/dev/null)" || return 1
  fi
  date -u -d "@$epoch" +%Y-%m-%dT%H:%M:%SZ
}

# LIMIT_LONG_COOLDOWN_HOURS: fallback stand-down for a weekly/monthly limit
# whose reset time couldn't be parsed at all (e.g. the spend-cap message,
# which never states one). `limit_cooldown_default` (a few hours) is sized
# for a transient rate limit, not a weekly or monthly one — at that cadence it
# would waste a retry roughly every 3 hours for days.
#
# It is an *upper bound*, not a prediction — and since the probe of
# requirement 2.1b, not the exit either. Every limit clears on its own at the
# plan's rollover, and this system has no way to learn when that is when the
# message does not say; so while an estimated stand-down is in force, every
# cycle asks the API directly (see `limit_probe_verdict` and the 2.1b
# block in agent-cycle.sh) and retires the stand-down the moment the account
# answers. What this constant bounds is how long the *record* can outlive the
# limit when every probe comes back inconclusive — a node whose probes cannot
# reach the API at all is a node whose cycles could not have run anyway. What
# it must never do is present the guess as a deadline — see `reset_known`
# below.
#
# Independent of `schedule.cycle_interval_minutes` (requirement 1d): bounded
# by the account provider's own weekly/monthly reset clock, not this
# installation's cadence.
LIMIT_LONG_COOLDOWN_HOURS=24

# limit_decide TEXT COOLDOWN_DEFAULT_HOURS
# Pure decision function (given a text blob, no file I/O): prints
# "<resume_at>\t<class>\t<reset_known>" — the exact fields
# detect_and_log_limit_hit() (agent-cycle.sh) logs on a limit-hit event.
#   - resume_at:   parsed from an ISO-8601 timestamp if present, else from a
#                  human-readable weekly reset clause, else a fallback
#                  COOLDOWN_DEFAULT_HOURS (or LIMIT_LONG_COOLDOWN_HOURS for
#                  weekly/monthly phrasing) hours from now.
#   - class:       weekly | monthly | other (see limit_class_of).
#   - reset_known: true only when a reset time was actually stated in the
#                  message. False means `resume_at` is this system's own
#                  guess and carries no information about the real reset.
#
# `reset_known` replaced an earlier `needs_human` flag, which claimed the
# spend-cap case "clears only when a human raises the cap". That was wrong in
# a way that mattered: a hit limit has *two* exits — wait for the plan's
# rollover (no human involved) or raise the cap (a human, and only if they
# want it back sooner). Calling the first exit nonexistent turned an unknown
# reset time into an apparent dead end, and left the pipeline standing down on
# a fabricated deadline with no supported way to lift it. What the detector
# actually knows is narrower and is all this field now claims: whether the
# message stated a reset time.
limit_decide() {
  local text="$1" cooldown_default_hours="$2" resume_at="" class reset_known=true

  resume_at="$(grep -oihE '[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}(:[0-9]{2})?Z' <<<"$text" | head -n1 || true)"
  if [[ -z "$resume_at" ]]; then
    resume_at="$(limit_parse_human_reset "$text" 2>/dev/null || true)"
  fi

  class="$(limit_class_of "$text")"

  if [[ -z "$resume_at" ]]; then
    reset_known=false
    if [[ "$class" == "weekly" || "$class" == "monthly" ]]; then
      resume_at="$(date -u -d "+${LIMIT_LONG_COOLDOWN_HOURS} hours" +%Y-%m-%dT%H:%M:%SZ)"
    else
      resume_at="$(date -u -d "+${cooldown_default_hours} hours" +%Y-%m-%dT%H:%M:%SZ)"
    fi
  fi

  printf '%s\t%s\t%s\n' "$resume_at" "$class" "$reset_known"
}

# limit_decide_structured INFO_JSON COOLDOWN_DEFAULT_HOURS
# The same `<resume_at>\t<class>\t<reset_known>` triple `limit_decide` prints,
# but read off the runner's own `rate_limit_info` object rather than parsed out
# of prose. Returns 1 with no output when the object says nothing usable.
#
# This is the better source wherever it exists, and worth saying why: the
# prose path exists because a limit used to be knowable only from the sentence
# the model printed, and a sentence has to be pattern-matched, may not state a
# reset time at all (the spend-cap message never does), and states it in a
# named zone that has to be resolved. `resetsAt` is an epoch. Where it is
# present the stand-down is a fact rather than an estimate, which is exactly
# the distinction `reset_known` was added to carry — and an estimated
# stand-down costs the fleet a probe every cycle until it clears.
#
# The class mapping follows what the fallback cooldown is for, not what the
# limit is called: a `seven_day*` limit is the long kind that
# `LIMIT_LONG_COOLDOWN_HOURS` exists for, and `five_hour` is not. It only
# matters when there is no `resetsAt` to use.
limit_decide_structured() {
  local info="${1:-}" cooldown_default_hours="${2:-3}" resets_at class reset_known resume_at
  [[ -n "$info" ]] || return 1
  jq -e 'type == "object"' <<<"$info" >/dev/null 2>&1 || return 1

  class="$(jq -r '
    (.rateLimitType // "" | tostring)
    | if startswith("seven_day") then "weekly" else "other" end' <<<"$info" 2>/dev/null)" || return 1

  resets_at="$(jq -r '.resetsAt // empty | tostring' <<<"$info" 2>/dev/null || true)"
  if [[ "$resets_at" =~ ^[0-9]+$ ]] && (( resets_at > 0 )); then
    resume_at="$(date -u -d "@$resets_at" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
  fi
  if [[ -n "${resume_at:-}" ]]; then
    reset_known=true
  else
    # No stated reset: fall back exactly as the prose path does, so the two
    # sources cannot produce differently-shaped stand-downs.
    reset_known=false
    if [[ "$class" == "weekly" ]]; then
      resume_at="$(date -u -d "+${LIMIT_LONG_COOLDOWN_HOURS} hours" +%Y-%m-%dT%H:%M:%SZ)"
    else
      resume_at="$(date -u -d "+${cooldown_default_hours} hours" +%Y-%m-%dT%H:%M:%SZ)"
    fi
  fi

  printf '%s\t%s\t%s\n' "$resume_at" "$class" "$reset_known"
}

# limit_probe_verdict OUT_TEXT [ERR_TEXT] [PROVIDER]
# Classify the transcript of one minimal probe invocation (requirement 2.1b:
# agent-cycle.sh spends it while an *estimated* stand-down is in force, asking
# the only authority on whether the limit is still real). OUT_TEXT is the
# probe's stdout — the headless JSON envelope — and ERR_TEXT its stderr; they
# arrive as two arguments because stray stderr diagnostics concatenated into
# the envelope would break the JSON parse (the same reason run_model_stage
# keeps the two files apart). PROVIDER (issue #2135) selects the phrase table
# `limit_phrase_regex_for` applies — the probe now runs against the frozen
# provider's own adapter, so its transcript carries that provider's own
# wording, not necessarily Anthropic's; empty/omitted defaults to `anthropic`,
# every call site before this issue. Prints exactly one of:
#   clear         the account answered — the limit behind the stand-down is
#                 gone, and the caller may retire it (both carriers)
#   limited       the transcript carries a limit phrase: still standing down
#   inconclusive  anything else — a timeout, a network failure, an empty or
#                 unparseable transcript. Says nothing about the limit, so
#                 the caller must change nothing on it.
#
# The phrase check runs first, over both streams, unconditionally: a limited
# probe's envelope is still well-formed JSON (the limit message arrives *in*
# `result`), and the one mistake this function must never make is reading
# "you've hit your … limit" as the account answering. Pure text-in,
# verdict-out — the `claude` invocation itself stays in agent-cycle.sh with
# every other one — so this can be regression-tested against canned
# transcripts.
limit_probe_verdict() {
  local out_text="$1" err_text="${2:-}" provider="${3:-anthropic}"
  if grep -qiE "$(limit_phrase_regex_for "$provider")" <<<"$out_text"$'\n'"$err_text"; then
    printf 'limited'
    return 0
  fi
  # The emptiness guard is not decoration: under jq 1.6, `jq -e` on empty
  # input exits 0 (fixed to exit 4 in 1.7), so without it an empty transcript
  # — the shape of every timeout — would read as the account answering.
  if [[ -n "${out_text//[[:space:]]/}" ]] \
     && jq -e 'type == "object" and (.is_error == false) and ((.result // "") != "")' \
       <<<"$out_text" >/dev/null 2>&1; then
    printf 'clear'
    return 0
  fi
  printf 'inconclusive'
}

# The usage-limit reduction of the fleet's event stream (requirement 2.1),
# defined once and read several ways below, so the stand-down check, its
# freeze escalation, `--status`, scripts/node-health.sh and the dashboard can
# never reduce the union differently.
#
# `limit_union_fold(NAMES)` folds UNION_STREAM_JQ's `union_events` over the
# events LIMIT_UNION_EVENTS declares, into one bucket per `provider` (issue
# #2135) — `.by["anthropic"]`, `.by["xai"]`, … — plus the empty-string bucket
# `.by[""]` for an event with no `provider` field at all: every `limit-hit`
# this system wrote before issue #2133, and any `limit-cleared`/
# `limit-freeze-escalated` written with no provider named, because clearing
# or escalating "every provider" is still how `--clear-limit`/a freeze with
# no live hit behave with no argument. A wildcard `limit-cleared`/
# `limit-freeze-escalated` resets or marks every bucket the fold has seen so
# far, not only `""` — `limit_union_state_for` below is what re-widens a
# single provider's answer to also honour that bucket, so a pre-#2133 record
# (or an explicit fleet-wide clear) still governs every provider, the same
# "a record without one applies to every provider" rule requirement 2.1's own
# `fleet/limit.json` carries (`limit_flag_record_for` below). Each bucket
# answers three things, the same three `limit_union_state`/
# `limit_union_state_for` have always printed for the single-record fold this
# replaces:
#
#   record      the governing `limit-hit` for that bucket, or null.
#               Most-recent-wins within the bucket, so a `limit-cleared`
#               written after a `limit-hit` supersedes it. Without that, an
#               operator who resolved the limit had no way to say so: the
#               stand-down is checked before any stage runs, so no cycle
#               could ever succeed and clear it from the inside.
#   since       the `ts` of the earliest `limit-hit` in that bucket's current
#               uninterrupted window — everything after the bucket's last
#               `limit-cleared` — or null. This is how long that bucket has
#               been frozen, as distinct from when the freeze was last
#               *extended* (the governing record's own `ts`), and is what the
#               automatic-freeze escalation ages against (requirement 2;
#               #244): a freeze that keeps re-confirming itself must not keep
#               resetting the clock that decides when a human hears about it.
#   escalated   the `since` of every `limit-freeze-escalated` event that
#               named this bucket (or named none, and so named every bucket),
#               the escalation's once-per-freeze memory. There are few, so
#               all are kept.
#
# The stream is time-ordered by `fleet_logs`, which takes a damaged line apart
# before its sort, so each record the fold sees sits at its own timestamp's
# place. It is read as raw lines, each parsed on its own, never slurped: one
# line that does not parse made a slurp abort, so the reduction returned
# nothing and the fleet read "no limit in force" while one was (#2037). The
# stream also holds one record at a time, where the slurp held the whole
# union (#1649).
#
# A line that does not parse is skipped; a read that fails outright (jq
# killed, or its input unreadable) exits non-zero with jq's own error on
# stderr, so each caller can tell "no limit" from "could not read" and report
# the second (`guard_warn` in agent-cycle.sh, a `warning` event in the review
# and monitor cycles) rather than act on it silently.
LIMIT_UNION_EVENTS='limit-hit limit-cleared limit-freeze-escalated'
# shellcheck disable=SC2016  # jq's own $names/$e/$prov
LIMIT_UNION_JQ='
  def limit_union_bucket: {record: null, first: null, escalated: []};
  def limit_union_fold($names):
    reduce union_events($names) as $e ({by: {}};
      ($e.provider // "") as $p |
      if $e.event == "limit-hit" then
        .by[$p] = ((.by[$p] // limit_union_bucket) | .record = $e | .first = (.first // $e))
      elif $e.event == "limit-cleared" then
        (if $p == "" then (.by | keys_unsorted) else [$p] end) as $ks |
        reduce $ks[] as $k (.; .by[$k] = ((.by[$k] // limit_union_bucket) | .record = null | .first = null))
      elif $e.event == "limit-freeze-escalated" then
        (if $p == "" then (.by | keys_unsorted) else [$p] end) as $ks |
        reduce $ks[] as $k (.; .by[$k] = ((.by[$k] // limit_union_bucket) | .escalated += [$e.since | strings]))
      else . end)
    | .by |= map_values({record, since: (.first.ts // null), escalated});
  def limit_union_bucket_or_empty($by; $key):
    $by[$key] // {record: null, since: null, escalated: []};
  # The later of two buckets by resume_at, lexicographically — every
  # resume_at this system ever writes is the same fixed-width
  # `date -u ... +%Y-%m-%dT%H:%M:%SZ` shape, which sorts the same as text as
  # it does as time, the same assumption limit_later_record makes with
  # `date -d` instead.
  def limit_bucket_later($a; $b):
    if ($a.record != null) and (($b.record == null) or (($a.record.resume_at // "") > ($b.record.resume_at // "")))
    then $a else $b end;
  def limit_union_fold_for($names; $prov):
    limit_union_fold($names) as $u |
    limit_union_bucket_or_empty($u.by; "") as $wild |
    limit_union_bucket_or_empty($u.by; $prov) as $own |
    limit_bucket_later($wild; $own) as $top |
    {record: $top.record, since: $top.since, escalated: ($wild.escalated + $own.escalated)};
  def limit_union_fold_collapsed($names):
    limit_union_fold($names) as $u |
    ($u.by | to_entries | map(select(.value.record != null))) as $withrec |
    if ($withrec | length) == 0 then {record: null, since: null, escalated: ([$u.by[] | .escalated[]?])}
    else
      ($withrec | sort_by(.value.record.resume_at // "") | last .value) as $top |
      {record: $top.record, since: $top.since, escalated: ([$u.by[] | .escalated[]?])}
    end;
'

# limit_union_record  < JSONL on stdin
# The governing `limit-hit` record the stream implies, fleet-wide across every
# provider (the later of each bucket's own, by resume_at), or nothing when
# none is in force. Unchanged in name and shape since before issue #2135 — a
# caller that wants one provider's own answer takes `limit_union_record_for`
# instead. The reader for everything but the stand-down's own freeze
# escalation, which takes `limit_union_state` instead.
limit_union_record() {
  # shellcheck disable=SC2086  # a word list by design
  jq -nRc "$UNION_STREAM_JQ $LIMIT_UNION_JQ"' limit_union_fold_collapsed($ARGS.positional) | .record | values' \
    --args $LIMIT_UNION_EVENTS
}

# limit_union_record_for PROVIDER  < JSONL on stdin
# limit_union_record, narrowed to PROVIDER: the later of its own bucket and
# the wildcard bucket (every pre-#2133 event, and any fleet-wide
# limit-cleared/escalation) — requirement 2.1's "later resume wins", applied
# a second time inside the union itself.
limit_union_record_for() {
  # shellcheck disable=SC2086  # a word list by design
  jq -nRc "$UNION_STREAM_JQ $LIMIT_UNION_JQ"' limit_union_fold_for($ARGS.positional; $prov) | .record | values' \
    --arg prov "${1:-}" --args $LIMIT_UNION_EVENTS
}

# limit_standdown_since  < JSONL on stdin
# The `ts` of the earliest `limit-hit` in the current uninterrupted stand-down
# window, fleet-wide, or nothing when no live hit exists. Unchanged since
# before issue #2135; `limit_union_state_for` carries one provider's own
# `since` for a caller that needs it.
limit_standdown_since() {
  # shellcheck disable=SC2086  # a word list by design
  jq -nRr "$UNION_STREAM_JQ $LIMIT_UNION_JQ"' limit_union_fold_collapsed($ARGS.positional) | .since | values' \
    --args $LIMIT_UNION_EVENTS
}

# limit_union_state  < JSONL on stdin
# All three fleet-wide answers in one pass, as one compact object —
# `{"record": {…}|null, "since": "…"|null, "escalated": ["…", …]}` — exactly
# as before issue #2135: the governing record across every provider (the
# later of each bucket's own, by resume_at), its own freeze start, and the
# union of every bucket's escalation memory. `--status`, scripts/node-health.sh
# and the dashboard's own fleet-wide badge read this unchanged;
# `limit_union_state_for` below is the per-provider form lib/standdown.sh,
# lib/enabler.sh, lib/refinement.sh, review-cycle.sh and monitor-cycle.sh read
# instead, now that a stand-down is scoped to the provider that hit it.
limit_union_state() {
  # shellcheck disable=SC2086  # a word list by design
  jq -nRc "$UNION_STREAM_JQ $LIMIT_UNION_JQ"' limit_union_fold_collapsed($ARGS.positional)' \
    --args $LIMIT_UNION_EVENTS
}

# limit_union_state_for PROVIDER  < JSONL on stdin
# limit_union_state's own answer narrowed to one provider: the later of its
# wildcard bucket ("", every pre-#2133 record and every explicit
# fleet-wide --clear-limit/escalation) and its PROVIDER-named bucket, by
# resume_at — the same "later resume wins" limit_later_record applies across
# the union and the flag carrier, applied a second time inside the union
# itself. Prints the same `{"record":…,"since":…,"escalated":[…]}` shape
# limit_union_state has always printed, so a caller narrowing by provider
# changes nothing about how it reads the answer.
limit_union_state_for() {
  # shellcheck disable=SC2086  # a word list by design
  jq -nRc "$UNION_STREAM_JQ $LIMIT_UNION_JQ"' limit_union_fold_for($ARGS.positional; $prov)' \
    --arg prov "${1:-}" --args $LIMIT_UNION_EVENTS
}

# limit_union_frozen_providers  < JSONL on stdin
# Every provider (the wildcard bucket included, printed as the empty string)
# the union currently names a live `limit-hit` for — i.e. every bucket whose
# own `.record` is non-null — one per line, for a caller enumerating
# currently-frozen providers (the dashboard's badge, the Monitor's digest)
# rather than checking one at a time. Says nothing about whether that record
# has actually lapsed (`resume_at` in the past) or about fleet/limit.json's
# own live flag — a caller wanting a provider's true current state still
# calls limit_governing_record_for for that provider.
limit_union_frozen_providers() {
  # shellcheck disable=SC2086  # a word list by design
  jq -nRr "$UNION_STREAM_JQ $LIMIT_UNION_JQ"' limit_union_fold($ARGS.positional) | .by
    | to_entries | map(select(.value.record != null) | .key) | .[]' \
    --args $LIMIT_UNION_EVENTS
}

# limit_later_record RECORD...
# Requirement 2.1's "later resume wins", over the records of both carriers —
# the log union and fleet/limit.json. Prints the governing record, or nothing
# when none of them names a resume time. Empty and unparseable arguments are
# skipped, so a caller can pass a carrier that is simply clear.
#
# Shared because three callers need the same answer — the stand-down check,
# `--status`, and `--clear-limit` — and a `--status` that disagreed with the
# check would be worse than no `--status` at all (requirement 34a).
limit_later_record() {
  local rec cand cand_epoch best="" best_epoch=0
  for rec in "$@"; do
    [[ -n "$rec" ]] || continue
    cand="$(jq -r '.resume_at // empty' <<<"$rec" 2>/dev/null || true)"
    [[ -n "$cand" ]] || continue
    cand_epoch="$(date -d "$cand" +%s 2>/dev/null || echo 0)"
    if (( cand_epoch > best_epoch )); then
      best_epoch="$cand_epoch"
      best="$rec"
    fi
  done
  if [[ -n "$best" ]]; then printf '%s' "$best"; fi
  return 0
}

# limit_flag_record_for RAW PROVIDER
# fleet/limit.json's own record (RAW — fleet_flag_fetch's raw bytes, the one
# record the flag ever carries) narrowed to PROVIDER: itself when its own
# `provider` field is PROVIDER or is absent entirely (every record before
# issue #2133, and a hand-written or migrated fixture — "a record without one
# applies to every provider"), never otherwise, since the flag holds exactly
# one record and a different provider's own hit must not borrow it to stand a
# healthy provider down. Prints nothing when RAW is empty, unparseable, or
# scoped to a different provider.
#
# The flag therefore still carries only ever one provider's own fast,
# live-read stand-down at a time — writing a second provider's hit overwrites
# it (`fleet_limit_publish` below), trading away the fast path's own speed
# advantage for whichever provider is not the most recently hit, in favour of
# the slower (one fetch interval) but always-correct log union. Two providers
# frozen at once is the rare case; the common one is a single provider's own
# account, for which the flag works exactly as it always has.
limit_flag_record_for() {
  local raw="$1" provider="$2"
  [[ -n "$raw" ]] || return 0
  jq -c --arg p "$provider" \
    'if (type == "object") and ((.provider // "") == "" or .provider == $p) then . else empty end' \
    <<<"$raw" 2>/dev/null || true
  return 0
}

# limit_governing_record_for STATE_REPO STATE_DIR PROVIDER  < JSONL on stdin
# The one record requirement 2.1's "later resume wins" governs PROVIDER by,
# combining the log union's own answer for PROVIDER (limit_union_state_for,
# itself already folding in the wildcard bucket) with the live flag, narrowed
# to PROVIDER by limit_flag_record_for above. Prints the governing record, or
# nothing when neither carrier names a live stand-down for PROVIDER.
#
# The canonical statement of that resolution, for a caller that wants only
# the record and can afford a fresh flag fetch — and the one
# `docs/spec/dashboard/state.md` and `docs/spec/monitor.md` cite by name when
# they describe what their own readers compute. No production caller spends
# it today, for a different reason in each band, and each is deliberate
# rather than an oversight: the stand-down checks themselves
# (lib/standdown.sh, review-cycle.sh, monitor-cycle.sh) also need the union's
# own `since`/`escalated` for their freeze-escalation step, so they call
# limit_union_state_for directly rather than read the union twice; the live
# pre-launch re-checks (lib/enabler.sh, lib/refinement.sh,
# lib/coordinator-phase.sh) want the flag alone and take
# fleet_limit_resume_at_for; and scripts/publish-dashboard.sh must not fetch
# the flag at all, so it assembles the same two halves around its own cached
# copy. Kept, and regression-tested in test/toggle.test.sh, so those four
# spellings have one definition to agree with rather than four to drift from.
limit_governing_record_for() {
  local state_repo="$1" state_dir="$2" provider="$3" union_record flag_record
  union_record="$(jq -c '.record // empty' <<<"$(limit_union_state_for "$provider")" 2>/dev/null)"
  flag_record="$(limit_flag_record_for "$(fleet_flag_fetch "$state_repo" "$state_dir" limit)" "$provider")"
  limit_later_record "$union_record" "$flag_record"
}

# limit_reset_known RECORD
# Whether a limit-hit event or fleet/limit.json record stated a real reset
# time. Reads the superseded `needs_human` when `reset_known` is absent, so a
# node running this code reports a peer's older event correctly during a
# rollout rather than silently calling every one of them authoritative.
#
# Left named `needs_human` deliberately (agent-ops#679): nothing ever writes
# it anymore, so renaming a wire-compatibility field read only for this
# cross-version fallback would buy a migration for nothing. It is also
# correct on its own merits regardless of `escalation_autonomy` — raising a
# spend cap is an owner-only act, so "needs a human" is what the old field
# actually meant.
limit_reset_known() {
  jq -r 'if has("reset_known") then .reset_known
         elif has("needs_human") then (.needs_human | not)
         else true end' <<<"${1:-{\}}" 2>/dev/null || printf 'true'
}

# limit_describe RESUME_AT CLASS RESET_KNOWN
# The one-line human explanation of a stand-down, shared by the dashboard
# banner and `--status` so they cannot describe the same state differently.
limit_describe() {
  local resume_at="$1" class="$2" reset_known="$3"
  if [[ "$reset_known" == "true" ]]; then
    printf 'until %s' "$resume_at"
    return 0
  fi
  printf 'with no stated reset; each cycle probes whether it has lifted — %s is only the estimated upper bound' "$resume_at"
  if [[ "$class" == "weekly" || "$class" == "monthly" ]]; then
    printf "%s" "; it clears at the plan's rollover — the next probe notices on its own — or sooner if you raise the cap; 'agent-cycle.sh --clear-limit' remains the manual override"
  fi
}
