#!/usr/bin/env bash
#
# lib/schedule-slots.sh — which schedule slots fell inside a cycle's own run
# (agent-ops#1287). supercronic will not start a job while the previous run
# of that job is still running: it logs the drop to the container log and
# nothing else records it, so a cycle that runs long loses its fleet a whole
# slot (or several) with no event of any kind in `log.jsonl`. `cleanup()`
# (agent-cycle.sh, requirement 11a) calls `schedule_overrun_slots` at the end
# of every cycle, before the lock releases, and logs one `cycle-skipped
# {reason: "overlap", ...}` per slot it returns.
#
# One pure function, on the same terms lib/node-time-state.sh's fold is: it
# never reads the log, never touches state_dir, and knows nothing about
# `cycle_id` — the caller shapes what this returns into the documented event.
#
# Sourced, never executed: no shell options are set here, matching every
# other lib/*.sh — the caller owns those.

# schedule_overrun_slots START_ISO END_ISO SCHEDULE_JSON [TRUE_BASE_MINUTE]
#
# Prints one ISO-8601 UTC timestamp per line, ascending, for each slot of the
# node's own series (see TRUE_BASE_MINUTE below) that falls strictly after
# START_ISO and at or before END_ISO — firings supercronic silently dropped
# because this cycle, which started at START_ISO, was still holding the lock
# at each of them. SCHEDULE_JSON is the already-defaulted `schedule` config
# block ({cycle_hours, cycle_interval_minutes, excluded_minutes} —
# `config_defaults`'s own output, requirement 1b). Prints nothing (never
# fails) if START_ISO/END_ISO do not parse, or if the span holds no further
# slot.
#
# TRUE_BASE_MINUTE, when given as a plain integer 0-59, is taken as the
# series base directly: it names the lowest minute the node's real crontab
# line actually fires on (`schedule_crontab_base_minute`, read from the
# rendered crontab by the caller — `cleanup()`, requirement 11a — since this
# function stays pure and never reads a file itself). Omitted, empty, or any
# other value, this falls back to START_ISO's own minute-of-hour instead —
# there is no need to re-derive it by re-hashing NODE_NAME the way
# `deploy/docker/render-crontab.sh`'s own `hash_minute()` does, and doing so
# here would risk drifting from whatever the real crontab actually fired on.
# Every later slot simply repeats that script's own
# restart-at-the-base-minute-each-hour pattern going forward from the base
# minute's own hour.
#
# The fallback base is only as good as START_ISO, and this function has no
# way to check it: it is meaningful precisely when START_ISO is a minute
# supercronic already chose to fire on (the crontab that script renders never
# fires outside one). The caller owns that precondition — `cleanup()` gates
# its call on the cycle being the cron-fired original (requirement 11a),
# since a chained continuation, a `--once`/`--dry-run` run, or a
# wake-poll-triggered run (requirement 54) starts at an arbitrary
# minute-of-hour and would make every slot named here a fabrication.
#
# The fallback series is the node's whole slot set only when START_ISO fell
# on the lowest kept minute of its hour. A cycle that fired on a later kept
# minute yields a proper subset — no slot at any earlier minute-of-hour of
# any subsequent hour — because one firing minute does not identify which of
# the hour's kept minutes is the base (:55 at a 15-minute interval is equally
# consistent with a base of 10, 25, 40 or 55; recovering it needs the second
# input TRUE_BASE_MINUTE supplies). Supplied a valid TRUE_BASE_MINUTE, the
# series is exact, not a lower bound; falling back, the error stays
# one-sided the way it always was: every slot printed is one the crontab
# really would have fired, so the caller's count is a lower bound on the
# firings lost, never an overstatement (agent-ops#1324).
#
# `parse_cycle_hours`/`kept_minutes` below are deliberately the same
# grammar and shape as `lib/config-schema.sh`'s `config_defaults` (cadence_gaps,
# requirement 1d) — a cron hour field (`*`, `*/N`, `a-b`, `a-b/N`, plain
# numbers, comma-combined) into the set of allowed hours 0..23, and a base
# minute into the kept firing minutes within one allowed hour — copied
# rather than shared because jq has no mechanism to import a function
# between two independent `jq` invocations; keep the two in step by hand if
# the grammar ever changes. Unlike that derivation, this one is not a
# worst-case estimate: it walks real slot instants across the actual
# [START_ISO, END_ISO] span, using this cycle's own real base minute.
schedule_overrun_slots() {
  local start_iso="$1" end_iso="$2" schedule_json="$3" true_base_minute="${4:-}"
  jq -nr --arg start "$start_iso" --arg end "$end_iso" --argjson sched "$schedule_json" \
    --arg truebase "$true_base_minute" '
    def parse_hour_token($t):
        if $t == "*" then [range(0;24)]
        elif ($t | test("^\\*/[0-9]+$")) then
          ($t | sub("^\\*/"; "") | tonumber) as $step
          | (if $step > 0 then [range(0;24;$step)] else [range(0;24)] end)
        elif ($t | test("^[0-9]+-[0-9]+/[0-9]+$")) then
          ($t | capture("^(?<a>[0-9]+)-(?<b>[0-9]+)/(?<s>[0-9]+)$")) as $c
          | ($c.a | tonumber) as $a | ($c.b | tonumber) as $b | ($c.s | tonumber) as $s
          | (if $a <= $b and $a < 24 and $s > 0 then [range($a; ([$b+1,24] | min); $s)] else [] end)
        elif ($t | test("^[0-9]+-[0-9]+$")) then
          ($t | capture("^(?<a>[0-9]+)-(?<b>[0-9]+)$")) as $c
          | ($c.a | tonumber) as $a | ($c.b | tonumber) as $b
          | (if $a <= $b and $a < 24 then [range($a; ([$b+1,24] | min))] else [] end)
        elif ($t | test("^[0-9]+$")) then
          ($t | tonumber) as $n | (if $n >= 0 and $n < 24 then [$n] else [] end)
        else []
        end;
    def parse_cycle_hours($s):
        ( ($s // "*") | split(",") | map(parse_hour_token(.)) | add // [] )
        | unique | sort;
    def kept_minutes($s; $interval; $excluded):
        [range($s; 60; $interval)] - $excluded;

    (try ($start | fromdateiso8601) catch null) as $start_s
    | (try ($end | fromdateiso8601) catch null) as $end_s
    | if $start_s == null or $end_s == null or $end_s <= $start_s then empty else
      (if ($sched.cycle_hours | type) == "string" then $sched.cycle_hours else "*" end) as $hours
      | (if ($sched.cycle_interval_minutes | type) == "number" and $sched.cycle_interval_minutes > 0
         then $sched.cycle_interval_minutes else 60 end) as $interval
      | (if ($sched.excluded_minutes | type) == "array"
         then ($sched.excluded_minutes | map(select(type == "number"))) else [] end) as $excluded
      | (parse_cycle_hours($hours)) as $allowed_hours
      | ($start_s | gmtime) as $start_bd
      | (if ($truebase | test("^[0-9]+$")) and ($truebase | tonumber) < 60
         then ($truebase | tonumber) else $start_bd[4] end) as $base_minute
      | (kept_minutes($base_minute; $interval; $excluded) | unique | sort) as $minutes
      | ((($end_s - $start_s) / 3600 | floor) + 2) as $hour_span
      | [ range(0; $hour_span) as $h
          | ($start_bd | .[3] += $h | .[4] = 0 | .[5] = 0 | mktime) as $hour_epoch
          | ($hour_epoch | gmtime | .[3]) as $hour_of_day
          | select(($allowed_hours | length) == 0 or ($allowed_hours | index($hour_of_day)) != null)
          | $minutes[] as $m
          | ($hour_epoch + ($m * 60)) as $candidate
          | select($candidate > $start_s and $candidate <= $end_s)
          | $candidate ]
      | unique
      | .[]
      | gmtime | strftime("%Y-%m-%dT%H:%M:%SZ")
      end
  '
}

# schedule_crontab_base_minute CRONTAB_FILE
#
# Prints the node's true base minute (agent-ops#1324) — `schedule_overrun_
# slots`'s own TRUE_BASE_MINUTE argument above — by reading it straight out
# of the rendered crontab (`deploy/docker/render-crontab.sh`'s own
# @CYCLE_MINUTE@ substitution): the agent-cycle.sh line's own minute field is
# a comma-separated, ascending list — cycle_minute, cycle_minute+interval,
# … — so its lowest entry is cycle_minute itself, the one minute no single
# firing can be told apart from its neighbours (see schedule_overrun_slots's
# own header). CRONTAB_FILE is the very file supercronic runs
# (compose.yaml's `scheduler` names deploy/docker/crontab), so this is exact
# whether or not render-crontab.sh's own render succeeded: the crontab baked
# into the image, which a failed render leaves standing, carries a real
# minute list of its own and is the schedule supercronic then fires on.
# Prints nothing at all — never fails — if CRONTAB_FILE does
# not exist, carries no line invoking */agent-cycle.sh outside a comment
# (`#`-prefixed lines, including the template's own explanatory ones, are
# skipped), or that line's own first field is not a plain comma-separated
# list of integers (a line shaped by a template this parser does not
# recognise — crontab.tmpl's own unrendered @CYCLE_MINUTE@ among them,
# though this function is never pointed at the template).
schedule_crontab_base_minute() {
  local crontab_file="$1" cron_line="" minute_field=""
  [[ -f "$crontab_file" ]] || return 0
  cron_line="$(grep -E '^[^#].*/agent-cycle\.sh([[:space:]]|$)' "$crontab_file" 2>/dev/null | head -1)"
  [[ -n "$cron_line" ]] || return 0
  minute_field="$(awk '{print $1}' <<<"$cron_line")"
  [[ "$minute_field" =~ ^[0-9]+(,[0-9]+)*$ ]] || return 0
  tr ',' '\n' <<<"$minute_field" | sort -n | head -1
}
