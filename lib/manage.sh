#!/usr/bin/env bash
# shellcheck disable=SC2154,SC2034  # this file's functions read and write the cycle's own globals — assigned by agent-cycle.sh, which sources every lib/*.sh file into one process (#771) — never locally; each function's own header names which ones.
#
# lib/manage.sh — the management commands (`--status`, `--disable`,
# `--enable`, `--clear-limit`, `--kill-merge-autonomy`, …): everything
# `agent-cycle.sh` does *instead of* running a cycle.
#
# Split out of agent-cycle.sh (#771). The seam is the sharpest one left in
# that file: these run before the lock and before any `gh` call, share none
# of the cycle's own phases, and every branch of them ends the process — so
# nothing below the call site can be reached from here, and nothing here is
# reachable from a cycle that runs. What is left in the spine is the one
# `run_manage_command` call, in the place the block occupied.
#
# `--status` must stay usable — and instant — while a cycle holds the lock,
# since "is one running right now?" is the question it is most often asked,
# and the switch's transitions are logged like any other state change: an
# operator finding cycles stopped is owed the same evidence trail as one
# finding them failing, and `disabled`/`enabled` events are what let the
# dashboard say why.
#
# Sourced by agent-cycle.sh only. Reads the cycle's own globals
# (`MANAGE_ACTION`, `SCRIPT_DIR`, `state_dir`, `state_repo`, `workspace_root`,
# `lock_file`, `review_lock_file`, `disable_default_ttl_hours`, `DISABLE_FOR`,
# `DISABLE_UNTIL`, `DISABLE_REASON`, `THIS_NODE`, …) directly, and — like
# `run_standdown_checks` (lib/standdown.sh) — deliberately declares nothing
# `local`, so the call is indistinguishable, to the rest of the cycle, from
# the inline block it replaces. `exit` inside it ends the process exactly as
# it did inline: nothing here runs inside a subshell. The log readers below
# fold UNION_STREAM_JQ's tolerant event stream (`union_events`,
# lib/union-stream.sh), which agent-cycle.sh sources before this file.
refresh_dashboard() {
  if [[ -x "$SCRIPT_DIR/scripts/publish-dashboard.sh" ]]; then
    timeout 120 "$SCRIPT_DIR/scripts/publish-dashboard.sh" >/dev/null 2>&1 || true
  fi
}

# The usage-limit stand-down in force right now (requirement 2.1), as its
# governing record, or empty when there is none. The management commands run
# long before the cycle's union snapshot exists, so they build their own. A
# union that could not be built (`fleet_logs` failing) or read at all is
# reported (on stderr, `--status` being a management command) and leaves the
# flag carrier to answer alone; a line that merely does not parse is skipped
# by the read itself (#2037). `pipefail` is set for the pipeline here rather
# than left to the caller, so a failed build fails the assignment whatever the
# caller's options.
current_limit_record() {
  local union
  union="$({ set -o pipefail
             fleet_logs "$state_dir" "$(fleet_peers_dir "$workspace_root")" log.jsonl \
               | limit_union_record; } 2>&1)" \
    || { guard_warn "current_limit_record:union" "$union"; union=""; }
  limit_later_record "$union" "$(fleet_flag_fetch "$state_repo" "$state_dir" limit)"
}

# current_limit_record_for PROVIDER
# current_limit_record, narrowed to PROVIDER (issue #2135) — the answer
# `--clear-limit <provider>` acts on: the union's own answer for PROVIDER
# (limit_union_record_for, itself already folding in the wildcard bucket) and
# the live flag, narrowed to PROVIDER by limit_flag_record_for. A separate
# function rather than a parameter on current_limit_record above, since that
# one is also `--status`'s own fleet-wide read and must keep answering exactly
# as it always has.
current_limit_record_for() {
  local provider="$1" union
  union="$({ set -o pipefail
             fleet_logs "$state_dir" "$(fleet_peers_dir "$workspace_root")" log.jsonl \
               | limit_union_record_for "$provider"; } 2>&1)" \
    || { guard_warn "current_limit_record:union" "$union"; union=""; }
  limit_later_record "$union" \
    "$(limit_flag_record_for "$(fleet_flag_fetch "$state_repo" "$state_dir" limit)" "$provider")"
}

# current_limit_record_for_lane PROVIDER LANE
# current_limit_record_for, narrowed one level further to LANE (issue
# #2242) — the answer `--clear-limit <provider>/<lane>` acts on, and what
# `limit_status_report` below checks for each of a provider's two lanes.
current_limit_record_for_lane() {
  local provider="$1" lane="$2" union
  union="$({ set -o pipefail
             fleet_logs "$state_dir" "$(fleet_peers_dir "$workspace_root")" log.jsonl \
               | limit_union_record_for_lane "$provider" "$lane"; } 2>&1)" \
    || { guard_warn "current_limit_record:union" "$union"; union=""; }
  limit_later_record "$union" \
    "$(limit_flag_record_for "$(fleet_flag_fetch "$state_repo" "$state_dir" limit)" "$provider" "$lane")"
}

# The `--status` line for that stand-down. Reported alongside the switch
# because they are two answers to one question — "why is nothing happening?"
# — and a status that knew only about the switch is what let a stale limit
# cooldown sit unexplained for a day. The fleet-wide headline (unchanged
# since before issue #2242) is followed by one line per currently-frozen
# lane of every configured provider (`PROVIDER_LANES`, populated by
# `providers_load` well before `run_manage_command` runs) — the finer
# answer "which lane specifically, and until when" once a provider's two
# lanes disagree, which the headline alone cannot give (a stage of that
# provider that would have drawn the frozen lane simply falls through to the
# other instead, `lib/stage-run.sh`'s `stage_lane_draw`, so this is
# diagnostic, not a second "nothing is happening" warning).
limit_status_report() {
  local rec resume_at resume_epoch rec_class
  rec="$(current_limit_record)"
  resume_at="$(jq -r '.resume_at // empty' <<<"${rec:-{\}}" 2>/dev/null || true)"
  # TD-PPagop-26081407: `rec` is fleet state read off disk/across nodes by
  # current_limit_record above (test 1 — a peer's flag file or log line can be
  # mid-write); epoch 0 reads as "already expired" (test 2 — indistinguishable
  # from a stand-down that genuinely lapsed), which would silently let the
  # fleet ignore an active cooldown.
  if [[ -n "$resume_at" ]]; then
    resume_epoch="$(date -d "$resume_at" +%s 2>&1)" \
      || { guard_warn "limit_status_report:resume_epoch" "$resume_epoch"; resume_epoch=0; }
  else
    resume_epoch=0
  fi
  if [[ -z "$resume_at" ]] || (( resume_epoch <= $(date +%s) )); then
    printf 'limit:    none in force\n'
  else
    # Same site class as above: `rec` can fail to parse, and "other" is
    # exactly the class a well-formed-but-unset record also reports (test 2).
    rec_class="$(jq -r '.class // "other"' <<<"$rec" 2>&1)" \
      || { guard_warn "limit_status_report:rec_class" "$rec_class"; rec_class=other; }
    printf 'limit:    STANDING DOWN — %s\n' \
      "$(limit_describe "$resume_at" "$rec_class" "$(limit_reset_known "$rec")")"
  fi
  local limit_status_name limit_status_lane limit_status_rec \
    limit_status_resume_at limit_status_resume_epoch limit_status_class
  for limit_status_name in $(printf '%s\n' "${!PROVIDER_LANES[@]}" anthropic | sort -u); do
    for limit_status_lane in api subscription; do
      limit_status_rec="$(current_limit_record_for_lane "$limit_status_name" "$limit_status_lane")"
      limit_status_resume_at="$(jq -r '.resume_at // empty' <<<"${limit_status_rec:-{\}}" 2>/dev/null || true)"
      [[ -n "$limit_status_resume_at" ]] || continue
      limit_status_resume_epoch="$(date -d "$limit_status_resume_at" +%s 2>/dev/null || echo 0)"
      (( limit_status_resume_epoch > $(date +%s) )) || continue
      limit_status_class="$(jq -r '.class // "other"' <<<"$limit_status_rec" 2>/dev/null || echo other)"
      printf '          %s/%s: STANDING DOWN — %s\n' "$limit_status_name" "$limit_status_lane" \
        "$(limit_describe "$limit_status_resume_at" "$limit_status_class" "$(limit_reset_known "$limit_status_rec")")"
    done
  done
  return 0
}

# The fleet line of `--status` (issue #379): `toggle_status_report` above
# already covers the node-scoped switch (`switch:`/`record:`), so this adds
# only the fleet one and, where both are in play, says plainly what each of
# --enable and --enable --this-node would leave — the question an operator
# who finds a node down for more than one reason actually has.
#
# The local record's `scope` (requirement 2.3) is what makes that answer
# truthful rather than merely confident. A fleet-wide --disable writes both
# levels, so the node that issued one has a local record it never asked for;
# calling that "its own node-scoped disable" describes a second decision that
# was never taken, and sends the operator looking for whoever made it.
fleet_status_report() {
  local local_disabled=0 local_scope="node" local_state fleet_state
  local_state="$(toggle_state "$state_dir")"
  if [[ "$(jq -r '.state' <<<"$local_state")" == "disabled" ]]; then
    local_disabled=1
    local_scope="$(toggle_scope "$(jq -c '.record // {}' <<<"$local_state")")"
  fi
  fleet_state="$(fleet_disabled_state "$state_repo" "$state_dir")"
  if [[ "$(jq -r '.state' <<<"$fleet_state")" == "disabled" ]]; then
    printf 'fleet:    DISABLED — %s\n' "$(toggle_describe "$(jq -c '.record' <<<"$fleet_state")")"
    if (( local_disabled )) && [[ "$local_scope" == "fleet" ]]; then
      printf '          the local record above mirrors this fleet switch — it is not a second, node-scoped disable; --enable clears both levels and every node resumes\n'
    elif (( local_disabled )); then
      printf '          this node also carries its own node-scoped disable (above) — --enable clears both; --enable --this-node clears only the local record, leaving the fleet switch (and this node) still down\n'
    else
      printf '          this node has no node-scoped disable of its own — --enable clears the fleet switch and every node resumes\n'
    fi
  elif (( local_disabled )) && [[ "$local_scope" == "fleet" ]]; then
    # The orphan (requirement 2.3): --enable run on a *peer* clears the fleet
    # flag but cannot reach this file, so this node alone stays down under a
    # fleet decision that has since been lifted. Naming it is the whole point
    # of the scope tag — otherwise this reads as a node-scoped disable nobody
    # set, and the node waits out a `forever` TTL that no longer applies.
    printf 'fleet:    not set — but the local record above mirrors a fleet switch that has since been cleared (probably by --enable on another node), so this node is standing down alone; --enable clears it\n'
  elif (( local_disabled )); then
    printf 'fleet:    not set — this node stands down on its own node-scoped disable above; --enable --this-node clears it\n'
  else
    printf 'fleet:    not set\n'
  fi
}

# The D18 kill switch (requirement 2.3b) — a separate flag from the fleet
# switch above, so killing merge autonomy never stops cycles running and
# disabling the pipeline never touches this. Reported alongside the other two
# stand-downs because all three answer some version of "why is this pipeline
# behaving the way it is right now".
merge_autonomy_status_report() {
  local ma_state
  ma_state="$(merge_autonomy_kill_state "$state_repo" "$state_dir")"
  # Anything but `enabled` is killed, the same test merge_autonomy_effective_level
  # itself applies — not `== "disabled"`. _toggle_eval also speaks `expired`,
  # and a record carrying an expiry it has passed resolves to `human` there
  # while reading as "not killed" here, which is the one way this report can
  # tell an operator the opposite of what the pipeline is doing.
  if [[ "$(jq -r '.state' <<<"$ma_state")" != "enabled" ]]; then
    # The fail-closed synthesis names itself — `record.kind: "fail-closed"`,
    # written by merge_autonomy_kill_state and nothing else, the same
    # discriminator scripts/doctor.sh branches on (requirement 2.3b, #454).
    # Nobody has necessarily set anything in that state: the node simply
    # cannot confirm the switch is clear, so KILLED here would send the
    # operator hunting a lever-pull that never happened, and
    # --restore-merge-autonomy would not help. Reporting-only — both branches
    # resolve every repo's effective level to human, unchanged.
    if [[ "$(jq -r '.record.kind // ""' <<<"$ma_state")" == "fail-closed" ]]; then
      printf 'merge_autonomy: FAIL-CLOSED — %s\n' "$(jq -r '.record.reason // "state repo unreachable"' <<<"$ma_state")"
      printf '          nobody has necessarily set the switch; check connectivity and state-repo health — --restore-merge-autonomy does not apply\n'
    else
      printf 'merge_autonomy: KILLED — %s\n' "$(toggle_describe "$(jq -c '.record' <<<"$ma_state")")"
      printf '          every repo'"'"'s effective level is human regardless of merge_autonomy; --restore-merge-autonomy clears it\n'
    fi
  else
    printf 'merge_autonomy: not killed — each repo runs at its configured level\n'
  fi
}

# Per-stage health (issue #662): whether each stage's most recent run of
# attempts on *this node* has been succeeding — the reading that was missing
# during the 2026-08-21 incident, where `cycle: RUNNING` and a clean fleet
# check both stayed true while every stage failed for 10.5 hours. Reads
# `state_dir/.stage-health.json`, written by `stage_health_write_status`
# (lib/stage-health.sh) at the end of every real cycle's own cleanup, rather
# than recomputing here — the same division `doctor_status_json`'s dashboard
# read keeps from `write_unattended_status`. A node that has not completed a
# cycle since upgrading reports that plainly instead of nothing.
stage_health_status_report() {
  printf 'stages:\n'
  stage_health_status_lines "$state_dir/.stage-health.json"
}

# The `--status` line counting `decide-tactical` decisions taken fleet-wide in
# the last 24h (agent-ops#937) — "where the owner sees them" 3 of that issue's
# own list, alongside the dashboard's Decisions panel. Built the same way
# `current_limit_record` above is: the management commands run long before
# the cycle's own union log snapshot exists, so this reads the fleet log
# fresh rather than reusing one — and reads it through UNION_STREAM_JQ's
# tolerant event stream (`union_events`, lib/union-stream.sh), as every union
# reader does: a slurp of the union aborts on its first unparseable line, and
# this line then read 0 whatever the fleet had decided (#2037). A union that
# could not be built, or a read that fails outright, says so instead of
# printing a zero nobody counted; `pipefail` is set here for the reason
# `current_limit_record` above gives.
decisions_status_report() {
  local count now_iso
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  # shellcheck disable=SC2016  # jq's own $now/$now_s/$from_s/$e
  count="$({ set -o pipefail
             fleet_logs "$state_dir" "$(fleet_peers_dir "$workspace_root")" log.jsonl \
               | jq -nR --arg now "$now_iso" "$UNION_STREAM_JQ"'
                   ($now | fromdateiso8601) as $now_s
                   | ($now_s - 86400) as $from_s
                   | reduce (union_events(["decision-taken"])
                             | select(((.ts // "") | length) > 0
                                      and (try (.ts | fromdateiso8601) catch 0) >= $from_s)) as $e
                       (0; . + 1)'; } 2>&1)" \
    || { guard_warn "decisions_status_report:count" "$count"; count=""; }
  if [[ "$count" =~ ^[0-9]+$ ]]; then
    printf 'decisions: %s taken in the last 24h\n' "$count"
  else
    printf 'decisions: unreadable — the fleet log could not be read\n'
  fi
}

# The `--status` line counting this node's own overrun-slot skips in the last
# 24h (requirement 11a, agent-ops#1287) — `check-nodes.sh` (external to this
# repository) already prints `--status` per node, so a new line here reaches
# it for free, the same way requirement 2.8's `stages:` section does. Unlike
# `decisions_status_report` above, this reads `$log_file` — this node's own
# log — rather than the fleet-wide union: a `cycle-skipped {reason:
# "overlap"}` event names the schedule this node's own cron fires, not a
# fleet-wide fact, and a peer's own overrun count belongs on its own
# `--status`, not folded into this one's.
#
# Read the way `decisions_status_report` reads, through `union_events`: a
# node's own log can hold an unparseable line too (both VM nodes' did, #2037),
# and a slurp that aborted on it read as zero overruns. A log not yet written
# is a plain zero; a log that exists and cannot be read says so.
overlap_status_report() {
  local count=0 now_iso
  now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ -e "$log_file" ]]; then
    # shellcheck disable=SC2016  # jq's own $now/$now_s/$from_s/$e
    count="$(jq -nR --arg now "$now_iso" "$UNION_STREAM_JQ"'
        ($now | fromdateiso8601) as $now_s
        | ($now_s - 86400) as $from_s
        | reduce (union_events(["cycle-skipped"])
                  | select(.reason == "overlap")
                  | select(((.ts // "") | length) > 0
                           and (try (.ts | fromdateiso8601) catch 0) >= $from_s)) as $e
            (0; . + 1)' "$log_file" 2>&1)" \
      || { guard_warn "overlap_status_report:count" "$count"; count=""; }
  fi
  if [[ "$count" =~ ^[0-9]+$ ]]; then
    printf 'overrun:  %s firing(s) overrun in the last 24h\n' "$count"
  else
    printf "overrun:  unreadable — this node's log could not be read\n"
  fi
}

# manage_age_phrase SECONDS -> "42s" | "7m" | "3h" | "2d"
# The coarse age the `stages:` lines already use (lib/stage-health.sh's own
# `ago`), for the two lines below, so `--status` reads one way throughout.
manage_age_phrase() {
  local s="${1:-0}"
  [[ "$s" =~ ^[0-9]+$ ]] || s=0
  if (( s < 60 )); then printf '%ss' "$s"
  elif (( s < 3600 )); then printf '%sm' "$(( s / 60 ))"
  elif (( s < 86400 )); then printf '%sh' "$(( s / 3600 ))"
  else printf '%sd' "$(( s / 86400 ))"
  fi
}

# The `--status` line for this node's own publication into the shared state
# (agent-ops#1377): `.state-sync-published.json` — `scripts/state-sync.sh
# fetch`'s read-back of what the state repository actually holds for this
# node's branch — through `fleet_publication_status`, the one verdict
# scripts/doctor.sh and the dashboard's fleet strip already derive
# (requirement 34a), so `--status` can never disagree with either. Here
# because `check-nodes.sh` (external to this repository) prints `--status`
# per node and that is where the maintainer looks: from 2026-09-12 to -15
# poetic-2 published nothing for three days while its every stage read `ok`
# and the doctor failed this same check hourly into a file nothing surfaced.
publication_status_report() {
  local ts json verdict age threshold mirror push_interval lock_json lock_age lock_mode holder_noun note=""
  if [[ -z "${state_repo:-}" ]]; then
    printf 'published: not configured (no state_repo)\n'
    return 0
  fi
  threshold="$(cfg '.node_stale_after_minutes * 60 | floor')"
  [[ "$threshold" =~ ^[0-9]+$ ]] || threshold=1800
  ts="$(fleet_ts_field "$state_dir/.state-sync-published.json")"
  json="$(fleet_publication_status "$ts" "$threshold")"
  verdict="$(jq -r '.verdict' <<<"$json" 2>/dev/null)"
  age="$(jq -r '.age_s // 0' <<<"$json" 2>/dev/null)"
  # The mirror lock's own current holder (agent-ops#1679): a push wedged
  # inside the redaction loop holds `mirror_lock` for hours while every fetch
  # reads "another state-sync holds the mirror" as if it were an ordinary
  # slow one, and this is the line a human actually looks at — read live
  # (`mirror_lock_probe`, lib/mirror-lock.sh) rather than from the last
  # confirmed publication above, since a wedge's whole defect is that it
  # never reaches that read-back at all.
  mirror="${STATE_SYNC_MIRROR:-$workspace_root/.agent-ops-state}"
  push_interval="$(cfg '.schedule.state_sync_push_minutes * 60 | floor')"
  [[ "$push_interval" =~ ^[0-9]+$ ]] || push_interval=300
  lock_json="$(mirror_lock_probe "$mirror" 2>/dev/null)"
  if [[ "$(jq -r '.held // false' <<<"$lock_json" 2>/dev/null)" == "true" ]]; then
    lock_age="$(jq -r '.age_s // empty' <<<"$lock_json" 2>/dev/null)"
    if [[ -n "$lock_age" ]] && (( lock_age > push_interval )); then
      # Named from the marker's own stamped mode (lib/mirror-lock.sh's
      # `mirror_lock_probe`) so a wedged fetch is not misreported as a wedged
      # push (agent-ops#1715) — mode-neutral whenever the probe could not
      # report one at all.
      lock_mode="$(jq -r '.mode // empty' <<<"$lock_json" 2>/dev/null)"
      case "$lock_mode" in
        push) holder_noun="a push" ;;
        fetch) holder_noun="a fetch" ;;
        *) holder_noun="a state-sync" ;;
      esac
      note=" — $holder_noun has been holding the mirror lock for $(manage_age_phrase "$lock_age"), longer than one push interval; it may be wedged (agent-ops#1679)"
    fi
  fi
  case "$verdict" in
    fresh)
      printf 'published: fresh — last confirmed publication %s ago, under the %s threshold%s\n' \
        "$(manage_age_phrase "$age")" "$(manage_age_phrase "$threshold")" "$note" ;;
    stale)
      printf 'published: STALE — last confirmed publication %s ago, over the %s threshold; state-sync.sh push has likely stopped working even if cycles are still running (agent-ops#602)%s\n' \
        "$(manage_age_phrase "$age")" "$(manage_age_phrase "$threshold")" "$note" ;;
    *)
      printf 'published: unknown — no fetch has read this node'"'"'s own branch back yet%s\n' "$note" ;;
  esac
}

# The `--status` line for the scheduled doctor's last verdict
# (`.doctor-status.json`, `write_unattended_status`, requirement 2.6a),
# naming its first failing check the way the heartbeat's bounded `fails`
# does (agent-ops#1397). The doctor is the one node-side check that looks
# past the pipeline's own stages — at the credential, the disk, the
# publication above — and its verdict reached the dashboard and the pager
# but never the terminal a maintainer actually has open.
doctor_status_report() {
  local f="$state_dir/.doctor-status.json" line
  if [[ ! -s "$f" ]]; then
    printf 'doctor:   no unattended pass recorded yet\n'
    return 0
  fi
  line="$(jq -r --argjson now "$(date -u +%s)" '
      (.verdict // "unknown") as $v
      | ((.timestamp // "") | (try fromdateiso8601 catch null)) as $t
      | (if $t == null then 0 else ([$now - $t, 0] | max) end) as $age
      | (.fails // []) as $f
      | "\($v)\t\($age)\t\($f | length)\t\(if ($f | length) > 0 then ($f[0] | .[0:200]) else "" end)"
    ' "$f" 2>/dev/null)" || line=""
  if [[ -z "$line" ]]; then
    printf 'doctor:   unreadable .doctor-status.json\n'
    return 0
  fi
  local verdict age nfails first
  IFS=$'\t' read -r verdict age nfails first <<<"$line"
  if (( nfails > 0 )); then
    printf 'doctor:   %s (%s ago) — %s failing, first: %s\n' "$verdict" "$(manage_age_phrase "$age")" "$nfails" "$first"
  else
    printf 'doctor:   %s (%s ago)\n' "$verdict" "$(manage_age_phrase "$age")"
  fi
}

# The `--status` line(s) for the credit mix's live lever (issue #2244, D30):
# every configured provider's effective lanes, built from the one shared
# object `lib/mix.sh`'s `mix_status_text` also renders for `agent-cycle.sh
# --mix` itself (requirement 34a) — so a value read here can never disagree
# with what the lever reports directly, or with `scripts/node-health.sh
# --metrics`'s own copy of the same object.
mix_status_report() {
  printf 'mix:\n'
  mix_status_text
}

# run_manage_command — the `--disable`/`--enable`/`--status`/`--clear-limit`/
# `--kill-merge-autonomy` handling itself, called once from `agent-cycle.sh`
# in place of the inline block it replaces (#771). Returns without doing
# anything when no management action was asked for, so the call site needs no
# guard of its own; every action it does handle exits the process.
run_manage_command() {
if [[ -n "$MANAGE_ACTION" ]]; then
  case "$MANAGE_ACTION" in
    status)
      toggle_status_report "$state_dir" "cycle=$lock_file" "review=$review_lock_file"
      # A drain's own progress line, alongside the switch line above: printed
      # only while the local record is actually a drain (requirement 2.9),
      # since a plain stop or an enabled pipeline has no "how much is left"
      # to report and drain_status_line would otherwise print a misleading
      # "no cycle has checked yet" for a switch that was never a drain at all.
      status_switch_state="$(toggle_state "$state_dir")"
      if [[ "$(jq -r '.state' <<<"$status_switch_state")" == "disabled" ]] \
         && [[ "$(toggle_mode "$(jq -c '.record // {}' <<<"$status_switch_state")")" == "drain" ]]; then
        drain_status_line "$state_dir" "$(jq -c '.record' <<<"$status_switch_state")"
      fi
      fleet_status_report
      limit_status_report
      merge_autonomy_status_report
      mix_status_report
      stage_health_status_report
      decisions_status_report
      overlap_status_report
      publication_status_report
      doctor_status_report
      exit 0
      ;;
    disable)
      # toggle_actor, never `${USER:-unknown}`: the record's actor is what
      # tells a reader whose decision this was, and `unknown@<container-id>`
      # is what let a deliberate operator stand-down read as a runaway
      # automatic freeze (#244).
      actor="$(toggle_actor)"
      by="$actor pid $$"
      # Read before writing: a --disable over a live switch is an extension of
      # the operator's earlier decision, and the log should say so rather than
      # presenting it as a fresh stop.
      prior_switch="$(toggle_state "$state_dir")"
      extends="$(jq -c 'select(.state == "disabled") | .record' <<<"$prior_switch" 2>/dev/null || true)"
      if ! disable_spec="$(toggle_resolve_disable_spec "$DISABLE_FOR" "$DISABLE_UNTIL" \
                             "$disable_default_ttl_hours")"; then
        exit 64
      fi
      # What this record *is*, not merely that it exists (requirement 2.3) —
      # written before the record, because the record carries it.
      #
      # This is deliberately not the same question as `disable_scope` below,
      # and the two part company in exactly one case. That one records the
      # operator's *instruction* for the log (issue #426), so a --disable on
      # an installation with no `state_repo` is still `scope: "fleet"`, with
      # `fleet_flag: "unconfigured"` saying why nothing was published. This one
      # answers "is there a fleet flag for this record to mirror?" — and with
      # no state repo there is none, so it is `node`. Tagging it `fleet` would
      # have --status claim a mirror of a switch that cannot exist, and
      # --enable --this-node refuse to clear the only record holding this node
      # down. Under --this-node both agree on `node`, for the same reason.
      record_scope=node
      if (( ! THIS_NODE )) && [[ -n "$state_repo" ]]; then record_scope=fleet; fi
      # mode "stop", explicit rather than left to toggle_disable's own default
      # (requirement 2.3d): a --disable issued while a --drain is active must
      # *tighten* it to a full stop immediately, and writing "stop" here is
      # what makes that the same code path as an ordinary fresh --disable
      # rather than a special case — the record this overwrites is simply
      # whatever mode it was in before.
      if ! record="$(toggle_disable "$state_dir" "$DISABLE_REASON" "$disable_spec" \
                       "$disable_default_ttl_hours" "$by" "$actor" manual "$record_scope" stop)"; then
        exit 64
      fi
      printf 'agent-cycle: disabled — %s\n' "$(toggle_describe "$record")"
      # The same record goes up as the fleet switch (requirement 2.3a): with
      # several nodes active, "stop the pipelines" has to mean all of them.
      # Best-effort — the local switch above already holds this node either
      # way, and the operator is told which of the two situations they are in.
      # --this-node opts out of that: the whole point of the flag is a
      # graceful, single-node stand-down that never reaches the fleet flag,
      # so the rest of the fleet is left running rather than warned about.
      #
      # `disable_scope` and `fleet_flag_outcome` are what the operator asked
      # for and what actually happened to it — logged below, once both are
      # known, rather than at the top of this block (issue #426): a process
      # killed mid-fleet-attempt must lose the event rather than log a
      # `disabled` that never says whether the fleet went down too.
      disable_scope="fleet"
      fleet_flag_outcome=""
      if (( THIS_NODE )); then
        disable_scope="node"
        printf 'agent-cycle: node-scoped disable — only %s stands down; the rest of the fleet keeps running\n' "$actor"
      else
        fleet_flag_outcome="$(fleet_flag_write_outcome "$state_repo" disabled "$record" \
          "fleet: disabled by $by — $DISABLE_REASON" "$state_dir")"
        case "$fleet_flag_outcome" in
          ok) printf 'agent-cycle: fleet switch set — every node will stand down\n' ;;
          failed)
            # Retag before warning: no fleet switch was set, so the local
            # record is no longer a mirror of anything — this node genuinely
            # is standing down alone, and a record still claiming `fleet`
            # would have --status and the dashboard describe a fleet
            # stand-down that does not exist. `unconfigured` needs no retag:
            # record_scope was already `node` when there is no state repo.
            toggle_mark_scope "$state_dir" node
            printf 'agent-cycle: WARNING — could not set the fleet switch (state repo unreachable?); only this node is disabled\n' >&2
            ;;
        esac
      fi
      log_event "disabled" "$(jq -nc --argjson r "$record" --argjson x "${extends:-null}" \
        --arg scope "$disable_scope" --arg ff "$fleet_flag_outcome" \
        '{reason: $r.reason, expires_at: $r.expires_at, by: $r.by,
          actor: $r.actor, kind: $r.kind, scope: $scope, mode: ($r.mode // "stop")}
         + (if $x == null then {} else {extends: $x} end)
         + (if $ff == "" then {} else {fleet_flag: $ff} end)')"
      # Say it plainly rather than leaving it to be discovered: an agent that
      # disables the pipeline to edit these files has not stopped the cycle
      # that is already reading them.
      held="$(toggle_lock_held "$lock_file")"
      [[ -n "$held" ]] && printf 'agent-cycle: WARNING — a cycle is still running (%s); it will finish.\n' "$held"
      held="$(toggle_lock_held "$review_lock_file")"
      [[ -n "$held" ]] && printf 'agent-cycle: WARNING — a review cycle is still running (%s); it will finish.\n' "$held"
      refresh_dashboard
      exit 0
      ;;
    drain)
      # requirement 2.3d. Same shape as `disable)` above — same record, same
      # scope/fleet-flag handling, same TTL resolution, same log fields — with
      # two differences: the record's `mode` is `"drain"` rather than the
      # default `"stop"`, and precedence is checked first, because a drain is
      # not simply "another disable": it may never *loosen* a stop already in
      # force (only --enable may), and issuing it must not silently discard
      # the plain --disable a peer or operator already imposed.
      actor="$(toggle_actor)"
      by="$actor pid $$"
      prior_switch="$(toggle_state "$state_dir")"
      prior_state="$(jq -r '.state' <<<"$prior_switch")"
      prior_mode="$(toggle_mode "$(jq -c '.record // {}' <<<"$prior_switch")")"
      if [[ "$prior_state" == "disabled" && "$prior_mode" == "stop" ]]; then
        echo "agent-cycle: --drain cannot loosen an active --disable (a full stop) — run --enable first if you want to switch to draining instead" >&2
        exit 64
      fi
      # The fleet switch counts as a prior stop too, and this node need not
      # carry a mirror of one: an unmodified `--disable` on a *peer* publishes
      # `fleet/disabled.json` and writes nothing to this node's own
      # `state_dir` (which is exactly why `--enable` below logs for the
      # no-local-record case, issue #426). Reading only the local record would
      # therefore let a fleet-scoped `--drain` here republish that flag as a
      # drain and downgrade the peer's stop across the whole fleet — the loosening
      # requirement 2.3d forbids in as many words. Checked only where the
      # loosening could actually happen: a `--this-node` drain, or one on a
      # node with no `state_repo`, publishes no flag and so cannot discard
      # anyone's stop. Fail-open on the same terms as every other reader of
      # this flag (requirement 2.3a) — an unreachable state repo reads
      # `enabled`, and in that same window the drain's own fleet write would
      # fail and retag itself `node` anyway.
      if (( ! THIS_NODE )) && [[ -n "$state_repo" ]]; then
        fleet_prior_switch="$(fleet_disabled_state "$state_repo" "$state_dir")"
        if [[ "$(jq -r '.state' <<<"$fleet_prior_switch")" == "disabled" ]] \
           && [[ "$(toggle_mode "$(jq -c '.record // {}' <<<"$fleet_prior_switch")")" == "stop" ]]; then
          echo "agent-cycle: --drain cannot loosen the fleet-wide --disable already in force (a full stop) — run --enable first if you want the fleet to drain instead" >&2
          exit 64
        fi
      fi
      extends="$(jq -c 'select(.state == "disabled") | .record' <<<"$prior_switch" 2>/dev/null || true)"
      if ! disable_spec="$(toggle_resolve_disable_spec "$DISABLE_FOR" "$DISABLE_UNTIL" \
                             "$disable_default_ttl_hours")"; then
        exit 64
      fi
      record_scope=node
      if (( ! THIS_NODE )) && [[ -n "$state_repo" ]]; then record_scope=fleet; fi
      if ! record="$(toggle_disable "$state_dir" "$DRAIN_REASON" "$disable_spec" \
                       "$disable_default_ttl_hours" "$by" "$actor" manual "$record_scope" drain)"; then
        exit 64
      fi
      printf 'agent-cycle: draining — %s\n' "$(toggle_describe "$record")"
      printf 'agent-cycle: new work will not be picked up; open review-feedback, merge-conflict, dequeued and abandoned-draft pull requests will still be finished\n'
      disable_scope="fleet"
      fleet_flag_outcome=""
      if (( THIS_NODE )); then
        disable_scope="node"
        printf 'agent-cycle: node-scoped drain — only %s stands down from new work; the rest of the fleet keeps working\n' "$actor"
      else
        fleet_flag_outcome="$(fleet_flag_write_outcome "$state_repo" disabled "$record" \
          "fleet: drain started by $by — $DRAIN_REASON" "$state_dir")"
        case "$fleet_flag_outcome" in
          ok) printf 'agent-cycle: fleet switch set — every node will drain\n' ;;
          failed)
            toggle_mark_scope "$state_dir" node
            printf 'agent-cycle: WARNING — could not set the fleet switch (state repo unreachable?); only this node is draining\n' >&2
            ;;
        esac
      fi
      log_event "disabled" "$(jq -nc --argjson r "$record" --argjson x "${extends:-null}" \
        --arg scope "$disable_scope" --arg ff "$fleet_flag_outcome" \
        '{reason: $r.reason, expires_at: $r.expires_at, by: $r.by,
          actor: $r.actor, kind: $r.kind, scope: $scope, mode: "drain"}
         + (if $x == null then {} else {extends: $x} end)
         + (if $ff == "" then {} else {fleet_flag: $ff} end)')"
      refresh_dashboard
      exit 0
      ;;
    enable)
      # --this-node undoes a --disable --this-node. It must refuse a record
      # tagged `fleet` (requirement 2.3), because clearing that one is never
      # what the operator wanted and can be actively harmful: the mirror is
      # this node's fail-closed hold on itself for exactly the window where
      # the fleet flag cannot be read (state repo unreachable — see
      # lib/toggle.sh's fleet section, which fails *open*), so dropping it
      # while the fleet switch stands is how a node resumes work the fleet was
      # stood down to prevent. Plain --enable is the right command in every
      # case: it clears this record and issues the fleet delete, which is
      # idempotent and treats an already-cleared flag as success.
      if (( THIS_NODE )); then
        enable_state="$(toggle_state "$state_dir")"
        if [[ "$(jq -r '.state' <<<"$enable_state")" == "disabled" ]] \
           && [[ "$(toggle_scope "$(jq -c '.record // {}' <<<"$enable_state")")" == "fleet" ]]; then
          echo "agent-cycle: this node's disable record mirrors a fleet-wide --disable, not a --this-node one; --enable --this-node will not clear it. Use --enable, which clears both levels (harmless if the fleet switch is already clear)." >&2
          exit 64
        fi
      fi
      record="$(toggle_clear "$state_dir")"
      if [[ -n "$record" ]]; then
        printf 'agent-cycle: enabled — cleared the disable set at %s (%s)\n' \
          "$(jq -r '.disabled_at // "?"' <<<"$record")" "$(jq -r '.reason // "?"' <<<"$record")"
      else
        printf 'agent-cycle: already enabled — no switch was set\n'
      fi
      # Clear the fleet switch too — and complain loudly if that fails,
      # because a fleet flag left set keeps every node down after the
      # operator believes they have re-enabled the operation.
      # --this-node opts out: it undoes only this node's own --disable
      # --this-node, and must never clear a fleet switch (or another node's
      # own node-scoped one) it did not set.
      enable_scope="fleet"
      fleet_flag_outcome=""
      if (( THIS_NODE )); then
        enable_scope="node"
        printf 'agent-cycle: node-scoped enable — the fleet switch, if any, is untouched\n'
      elif [[ -n "$state_repo" ]]; then
        fleet_flag_outcome="$(fleet_flag_delete_outcome "$state_repo" "$state_dir" disabled)"
        case "$fleet_flag_outcome" in
          ok|unconfigured) printf 'agent-cycle: fleet switch clear\n' ;;
          failed) printf 'agent-cycle: WARNING — could not clear the fleet switch; every node still stands down. Re-run --enable, or delete fleet/disabled.json in %s by hand.\n' "$state_repo" >&2 ;;
        esac
      else
        fleet_flag_outcome="unconfigured"
      fi
      # Log `enabled` whenever anything was actually cleared — the local
      # record, the fleet flag, or both — not only when the local record was
      # set (issue #426): a node with no local record but a live fleet flag
      # previously left the fleet coming back up absent from the log
      # entirely.
      if [[ -n "$record" || "$fleet_flag_outcome" == "ok" ]]; then
        log_event "enabled" "$(jq -nc --argjson r "${record:-null}" \
          --arg scope "$enable_scope" --arg ff "$fleet_flag_outcome" \
          '{detail: "cleared by hand", was: $r, scope: $scope}
           + (if $ff == "" then {} else {fleet_flag: $ff} end)')"
        if [[ "$enable_scope" == "node" ]]; then
          notify_post_cycle "fleet-standdown-end" "standdown:node-switch:$node_name" \
            "Node switch cleared by hand" "" "" "cleared by hand"
        else
          notify_post_cycle "fleet-standdown-end" "standdown:fleet-switch" \
            "Fleet switch cleared by hand" "" "" "cleared by hand"
        fi
      fi
      refresh_dashboard
      exit 0
      ;;
clear-limit)
      # Which of up to two bare tokens (agent-cycle.sh's own argv parsing)
      # is a provider[/lane] and which is a reason cannot be told until now
      # (issue #2135, extended to the lane by #2242): providers_load runs
      # well before run_manage_command, so PROVIDER_SUBSTRATE's keys — every
      # provider config.json names, plus the always-implicit `anthropic`
      # (lib/model-id.sh) — are what decide it. Two tokens are unambiguous in
      # *shape* (provider[/lane], then reason), but the first still has to
      # name a real provider — there is no second reading of two bare tokens
      # to fall back on, and silently scoping the clear to a provider that
      # does not exist would log a `limit-cleared` nothing reads and report
      # a stand-down lifted that never was. One token is the provider[/lane]
      # only if its provider half names one, exactly as before this issue
      # otherwise (a single token is the reason). The lane half, if given,
      # must be `api` or `subscription`, the only two lanes this system
      # knows.
      CLEAR_LIMIT_LANE=""
      clear_limit_arg1_provider="${CLEAR_LIMIT_ARG1%%/*}"
      if [[ "$CLEAR_LIMIT_ARG1" == */* ]]; then
        CLEAR_LIMIT_LANE="${CLEAR_LIMIT_ARG1#*/}"
      fi
      if [[ -n "$CLEAR_LIMIT_ARG1" ]] \
         && { [[ "$clear_limit_arg1_provider" == "anthropic" ]] \
              || [[ -n "${PROVIDER_SUBSTRATE[$clear_limit_arg1_provider]:-}" ]]; } \
         && { [[ -z "$CLEAR_LIMIT_LANE" ]] \
              || [[ "$CLEAR_LIMIT_LANE" == "api" || "$CLEAR_LIMIT_LANE" == "subscription" ]]; }; then
        CLEAR_LIMIT_PROVIDER="$clear_limit_arg1_provider"
        CLEAR_LIMIT_REASON="$CLEAR_LIMIT_ARG2"
      elif [[ -n "$CLEAR_LIMIT_ARG1" ]] && [[ "$CLEAR_LIMIT_ARG1" == */* ]] \
           && { [[ "$clear_limit_arg1_provider" == "anthropic" ]] \
                || [[ -n "${PROVIDER_SUBSTRATE[$clear_limit_arg1_provider]:-}" ]]; }; then
        printf 'agent-cycle: --clear-limit: "%s" is not api or subscription, the only two lanes\n' \
          "$CLEAR_LIMIT_LANE" >&2
        exit 64
      elif [[ -n "$CLEAR_LIMIT_ARG2" ]]; then
        printf 'agent-cycle: --clear-limit: "%s" is not a configured provider (known: %s) — with two arguments the first must name one\n' \
          "$CLEAR_LIMIT_ARG1" \
          "$(printf '%s\n' "${!PROVIDER_SUBSTRATE[@]}" anthropic | sort -u | paste -sd, -)" >&2
        exit 64
      elif [[ -n "$CLEAR_LIMIT_ARG1" ]]; then
        CLEAR_LIMIT_REASON="$CLEAR_LIMIT_ARG1"
        CLEAR_LIMIT_LANE=""
      fi
      clear_limit_target="${CLEAR_LIMIT_PROVIDER}${CLEAR_LIMIT_LANE:+/$CLEAR_LIMIT_LANE}"

      # Both carriers of requirement 2.1, because the stand-down lifts only
      # when the later of the two says so. Clearing one alone reads as
      # success and changes nothing — the failure this command exists to end.
      if [[ -n "$CLEAR_LIMIT_LANE" ]]; then
        governing="$(current_limit_record_for_lane "$CLEAR_LIMIT_PROVIDER" "$CLEAR_LIMIT_LANE")"
      elif [[ -n "$CLEAR_LIMIT_PROVIDER" ]]; then
        governing="$(current_limit_record_for "$CLEAR_LIMIT_PROVIDER")"
      else
        governing="$(current_limit_record)"
      fi
      was="$(jq -r '.resume_at // empty' <<<"${governing:-{\}}" 2>/dev/null || true)"

      # Carrier 1: the log union. A `limit-cleared` event dated now outranks
      # every earlier limit-hit for this same scope, on this node immediately
      # and on its peers at their next state-sync fetch. A `provider` field
      # scopes the clear to that provider alone, and a `lane` field within it
      # to that lane alone (issue #2242); either absent means every
      # provider, or every lane of the named provider, exactly as
      # `--clear-limit` always has before the issue that added it.
      log_event "limit-cleared" "$(jq -nc --arg w "$was" --arg r "$CLEAR_LIMIT_REASON" \
        --arg by "$(toggle_actor)" --arg p "$CLEAR_LIMIT_PROVIDER" --arg l "$CLEAR_LIMIT_LANE" \
        '{was: (if $w == "" then null else $w end),
          reason: (if $r == "" then "cleared by hand" else $r end),
          by: $by, actor: $by, kind: "manual"}
         + (if $p == "" then {} else {provider: $p} end)
         + (if $l == "" then {} else {lane: $l} end)')"
      notify_post_cycle "fleet-standdown-end" \
        "standdown:usage-limit${clear_limit_target:+:$clear_limit_target}" \
        "Usage-limit cooldown cleared by hand${clear_limit_target:+ ($clear_limit_target)}" "" "" \
        "${CLEAR_LIMIT_REASON:-cleared by hand}"

      # Carrier 2: the live flag. Deleting it rather than shortening it,
      # because fleet_limit_publish is extend-only by design (concurrent hits
      # must converge on the latest resume) — a human lifting a stand-down is
      # the one case that legitimately moves it earlier, and delete is the
      # only write that expresses that. With a named provider[/lane], the
      # flag is only ever deleted outright when its own current record names
      # *exactly* that key — strict equality, never `limit_flag_record_for`'s
      # own wildcard-tolerant match: a wildcard record (no `provider`, or, with
      # a lane named, no `lane`) governs every provider/lane and must survive
      # a scoped clear, which can only ever narrow one bucket of the union,
      # never un-write "every provider/lane but this one" from the flag.
      clear_flag=1
      if [[ -n "$CLEAR_LIMIT_PROVIDER" && -n "$state_repo" ]]; then
        flag_now="$(fleet_flag_fetch "$state_repo" "$state_dir" limit)"
        flag_provider="$(jq -r '.provider // empty' <<<"$flag_now" 2>/dev/null || true)"
        flag_lane="$(jq -r '.lane // empty' <<<"$flag_now" 2>/dev/null || true)"
        [[ "$flag_provider" == "$CLEAR_LIMIT_PROVIDER" && "$flag_lane" == "$CLEAR_LIMIT_LANE" ]] \
          || clear_flag=0
      fi
      if [[ -n "$state_repo" ]]; then
        if (( clear_flag )); then
          # >/dev/null: fleet_flag_delete now prints which of "deleted"/"absent"
          # it was (issue #426) for callers that log the outcome; this one only
          # ever reads the return code, and the raw word must not leak to the
          # operator's terminal.
          if fleet_flag_delete "$state_repo" "$state_dir" limit >/dev/null; then
            printf 'agent-cycle: fleet usage-limit flag clear\n'
          else
            printf 'agent-cycle: WARNING — could not clear fleet/limit.json; peers reading it live still stand down. Re-run --clear-limit, or delete fleet/limit.json in %s by hand.\n' "$state_repo" >&2
          fi
        elif [[ -n "$CLEAR_LIMIT_PROVIDER" ]]; then
          printf 'agent-cycle: fleet/limit.json does not name %s — it is left in place; whether %s is still held down is reported below\n' \
            "$clear_limit_target" "$clear_limit_target"
        fi
      fi

      # Did the clear actually work? Asked of the carriers themselves rather
      # than inferred from what was written to them, because a *scoped* clear
      # has one case where both carriers legitimately refuse it: a wildcard
      # record — no `provider` (or, with a lane named, no `lane`) field at
      # all — governs every provider or every lane by the "a record without
      # one applies to every provider/lane" rule, and neither carrier can
      # express "every provider/lane but this one". The union's
      # `limit-cleared` resets only this key's own bucket, leaving the
      # wildcard bucket standing; the flag is left alone by the guard above.
      # So the stand-down survives a clear that otherwise reports success —
      # which is the exact failure this command exists to end, and the
      # reason it is re-read here instead of trusted. Only the scoped form
      # can hit it: a bare `--clear-limit` writes a wildcard `limit-cleared`
      # and deletes the flag outright.
      if [[ -n "$CLEAR_LIMIT_LANE" ]]; then
        still="$(current_limit_record_for_lane "$CLEAR_LIMIT_PROVIDER" "$CLEAR_LIMIT_LANE")"
      elif [[ -n "$CLEAR_LIMIT_PROVIDER" ]]; then
        still="$(current_limit_record_for "$CLEAR_LIMIT_PROVIDER")"
      else
        still=""
      fi
      still_at="$(jq -r '.resume_at // empty' <<<"${still:-{\}}" 2>/dev/null || true)"
      still_epoch=0
      if [[ -n "$still_at" ]]; then
        still_epoch="$(date -d "$still_at" +%s 2>&1)" \
          || { guard_warn "clear_limit:still_epoch" "$still_epoch"; still_epoch=0; }
      fi

      if (( still_epoch > $(date +%s) )); then
        printf 'agent-cycle: WARNING — the usage-limit stand-down for %s is NOT lifted: a wider record still holds it down until %s, and a clear scoped to one %s cannot remove it. Re-run "agent-cycle.sh --clear-limit"%s with no %s to clear every %s at once.\n' \
          "$clear_limit_target" "$still_at" \
          "${CLEAR_LIMIT_LANE:+lane}${CLEAR_LIMIT_LANE:-provider}" \
          "${CLEAR_LIMIT_LANE:+ $CLEAR_LIMIT_PROVIDER}" \
          "${CLEAR_LIMIT_LANE:+lane}${CLEAR_LIMIT_LANE:-provider}" \
          "${CLEAR_LIMIT_LANE:+lane}${CLEAR_LIMIT_LANE:-provider}" >&2
      elif [[ -n "$was" ]]; then
        printf 'agent-cycle: usage-limit stand-down lifted (resume_at was %s)%s\n' "$was" \
          "${clear_limit_target:+ for $clear_limit_target}"
      else
        printf 'agent-cycle: no usage-limit stand-down was in force%s\n' \
          "${clear_limit_target:+ for $clear_limit_target}"
      fi
      refresh_dashboard
      exit 0
      ;;
    close-lane)
      # `agent-cycle.sh --close-lane <provider>/<lane> [--for <d>|--until
      # <ts>|forever] [--reason <text>]` (issue #2242): a manual, fail-closed
      # stop for exactly one of a provider's two lanes — the operator's way
      # to close one down by hand (a terms concern, say) without an image
      # roll, naming the same lane grammar as --mix and --clear-limit.
      #
      # Fail-closed by construction, unlike --mix (which only ever opens a
      # lane or restates a preference, never closes one, lib/mix.sh's own
      # header): this writes to fleet/limit.json, whose "no lane named
      # applies to every lane of its provider" rule means a node on an older
      # image that cannot read this record's own `lane` field stands the
      # whole provider down rather than reading nothing at all — the same
      # "an old reader fails closed" direction #2135's own provider scoping
      # chose. fleet/mix.json's own absence-means-default rule runs the
      # other way (an old reader of a lever record simply sees the default,
      # open, weight), which is why that lever is the wrong file for a
      # closure.
      close_lane_provider="${CLOSE_LANE_ARG%%/*}"
      close_lane_lane=""
      [[ "$CLOSE_LANE_ARG" == */* ]] && close_lane_lane="${CLOSE_LANE_ARG#*/}"
      if [[ -z "$CLOSE_LANE_ARG" || "$CLOSE_LANE_ARG" != */* ]]; then
        printf 'agent-cycle: --close-lane needs <provider>/<lane>, e.g. anthropic/subscription\n' >&2
        exit 64
      fi
      if [[ "$close_lane_lane" != "api" && "$close_lane_lane" != "subscription" ]]; then
        printf 'agent-cycle: --close-lane: "%s" is not api or subscription, the only two lanes\n' "$close_lane_lane" >&2
        exit 64
      fi
      if [[ "$close_lane_provider" != "anthropic" && -z "${PROVIDER_SUBSTRATE[$close_lane_provider]:-}" ]]; then
        printf 'agent-cycle: --close-lane: "%s" is not a configured provider (known: %s)\n' \
          "$close_lane_provider" \
          "$(printf '%s\n' "${!PROVIDER_SUBSTRATE[@]}" anthropic | sort -u | paste -sd, -)" >&2
        exit 64
      fi
      if [[ -z "$DISABLE_FOR" && -z "$DISABLE_UNTIL" ]]; then
        printf 'agent-cycle: --close-lane needs a bound — --for <90m|4h|2d|forever>, or --until <timestamp>\n' >&2
        exit 64
      fi
      if ! close_lane_spec="$(toggle_resolve_disable_spec "$DISABLE_FOR" "$DISABLE_UNTIL" \
                                "$disable_default_ttl_hours")"; then
        exit 64
      fi
      if ! close_lane_resume_at="$(toggle_parse_ttl "$close_lane_spec" "$disable_default_ttl_hours")"; then
        exit 64
      fi
      # `toggle_parse_ttl` prints nothing for `forever`/`never`/`indefinite`
      # — fleet/limit.json's own `resume_at` is never null (every epoch
      # comparison in lib/limit-detect.sh assumes a parseable instant), so an
      # indefinite closure is represented as a fixed far-future sentinel
      # instead, the same way an indefinite --disable's own `expires_at:
      # null` has no analogue here.
      [[ -n "$close_lane_resume_at" ]] || close_lane_resume_at="9999-12-31T00:00:00Z"
      close_lane_actor="$(toggle_actor)"
      close_lane_reason="${CLOSE_LANE_REASON:-closed by hand}"
      # The local record first — it always works — then the fleet, exactly
      # as --disable writes both levels (requirement 2.3a): this node is
      # closed to the lane immediately even if the fleet write below fails,
      # and detect_and_log_limit_hit's own `log_event` then `fleet_limit_publish`
      # ordering is the same "local first" shape, reused here rather than
      # invented afresh.
      log_event "limit-hit" "$(jq -nc --arg r "$close_lane_resume_at" --arg n "$close_lane_actor" \
        --arg reason "$close_lane_reason" --arg p "$close_lane_provider" --arg l "$close_lane_lane" \
        '{resume_at: $r, class: "manual", reset_known: true, kind: "manual", actor: $n, provider: $p, lane: $l,
          evidence: $reason}')"
      if [[ -n "$state_repo" ]]; then
        if fleet_limit_close_lane "$state_repo" "$state_dir" "$close_lane_provider" "$close_lane_lane" \
             "$close_lane_resume_at" "$close_lane_reason" "$close_lane_actor"; then
          printf 'agent-cycle: %s/%s closed until %s\n' "$close_lane_provider" "$close_lane_lane" "$close_lane_resume_at"
        else
          printf 'agent-cycle: WARNING — could not write fleet/limit.json; peers reading it live will not see this closure until it reaches them through the log union.\n' >&2
        fi
      else
        printf 'agent-cycle: %s/%s closed until %s (no state_repo configured — this node only)\n' \
          "$close_lane_provider" "$close_lane_lane" "$close_lane_resume_at"
      fi
      refresh_dashboard
      exit 0
      ;;
    kill-merge-autonomy)
      # D18 §6 (requirement 2.3b): a permanent operational control, not
      # scaffolding — inherently fleet-wide, so unlike --disable there is no
      # --this-node form and no local record to write first. With no
      # state_repo configured this is a single-node install and the flag
      # cannot be published anywhere every future read would see it — say so
      # rather than pretend the kill took effect.
      by="$(toggle_actor) pid $$"
      if [[ -z "$state_repo" ]]; then
        echo "agent-cycle: no state_repo configured — --kill-merge-autonomy has nothing to publish to (single-node install; the config's own merge_autonomy already governs)" >&2
        exit 64
      fi
      outcome="$(merge_autonomy_kill_set "$state_repo" "$KILL_MERGE_AUTONOMY_REASON" "$by")"
      case "$outcome" in
        ok) printf 'agent-cycle: merge-autonomy kill switch set — every repo'"'"'s effective level is now human\n' ;;
        *) echo "agent-cycle: WARNING — could not set the merge-autonomy kill switch (state repo unreachable?)" >&2 ;;
      esac
      log_event "merge-autonomy-killed" "$(jq -nc --arg r "$KILL_MERGE_AUTONOMY_REASON" \
        --arg by "$by" --arg actor "$(toggle_actor)" --arg outcome "$outcome" \
        '{reason: $r, by: $by, actor: $actor, kind: "manual", fleet_flag: $outcome}')"
      notify_post_cycle "fleet-standdown-begin" "standdown:merge-autonomy-kill" \
        "Merge-autonomy kill switch set" "" "" "$KILL_MERGE_AUTONOMY_REASON"
      refresh_dashboard
      exit 0
      ;;
    restore-merge-autonomy)
      if [[ -z "$state_repo" ]]; then
        printf 'agent-cycle: no state_repo configured — the kill switch was never publishable (single-node install)\n'
        exit 0
      fi
      outcome="$(merge_autonomy_kill_clear "$state_repo" "$state_dir")"
      case "$outcome" in
        ok) printf 'agent-cycle: merge-autonomy kill switch cleared — each repo'"'"'s configured level governs again\n' ;;
        unconfigured) printf 'agent-cycle: merge-autonomy kill switch was not set\n' ;;
        *) echo "agent-cycle: WARNING — could not clear the merge-autonomy kill switch; every repo still forced to human. Re-run --restore-merge-autonomy, or delete fleet/merge-autonomy-kill.json in $state_repo by hand." >&2 ;;
      esac
      if [[ "$outcome" == "ok" ]]; then
        log_event "merge-autonomy-restored" "$(jq -nc --arg by "$(toggle_actor)" \
          '{detail: "cleared by hand", by: $by, actor: $by, kind: "manual"}')"
        notify_post_cycle "fleet-standdown-end" "standdown:merge-autonomy-kill" \
          "Merge-autonomy kill switch cleared" "" "" "cleared by hand"
      fi
      refresh_dashboard
      exit 0
      ;;
    mix)
      # No arguments at all: print the effective mix every provider is
      # running under right now — the same report `--status` gives, read
      # through the identical `mix_status_text` (requirement 34a).
      if (( ${#MIX_ARGS[@]} == 0 )); then
        mix_status_text
        exit 0
      fi
      mix_provider="${MIX_ARGS[0]}"
      if [[ "$mix_provider" == --* ]]; then
        echo "agent-cycle: --mix needs a provider name first (got \"$mix_provider\")" >&2
        exit 64
      fi
      mix_rest=("${MIX_ARGS[@]:1}")
      if [[ -z "$state_repo" ]]; then
        echo "agent-cycle: no state_repo configured — --mix has nothing to publish to (single-node install; config.json's providers.$mix_provider.lanes already governs)" >&2
        exit 64
      fi
      by="$(toggle_actor) pid $$"
      if (( ${#mix_rest[@]} == 1 )) && [[ "${mix_rest[0]}" == "--reset" ]]; then
        mix_outcome="$(mix_reset "$state_repo" "$state_dir" "$mix_provider" "$by")"
        case "$mix_outcome" in
          absent)
            printf 'agent-cycle: no live mix entry for %s — config.json already governs\n' "$mix_provider"
            ;;
          deleted)
            printf 'agent-cycle: mix reset for %s — fleet/mix.json cleared (it was the last provider on it)\n' "$mix_provider"
            ;;
          written)
            printf 'agent-cycle: mix reset for %s — other providers'"'"' entries on fleet/mix.json are left standing\n' "$mix_provider"
            ;;
          *)
            echo "agent-cycle: WARNING — could not reset the mix for $mix_provider (state repo unreachable?)" >&2
            exit 1
            ;;
        esac
        log_event "mix-reset" "$(jq -nc --arg p "$mix_provider" --arg by "$by" \
          --arg actor "$(toggle_actor)" --arg outcome "$mix_outcome" \
          '{provider: $p, by: $by, actor: $actor, outcome: $outcome}')"
        refresh_dashboard
        exit 0
      fi
      for mix_tok in "${mix_rest[@]}"; do
        if [[ "$mix_tok" == "--reset" ]]; then
          echo "agent-cycle: --mix: --reset must be the only argument after the provider name" >&2
          exit 64
        fi
      done
      if (( ${#mix_rest[@]} == 0 )); then
        echo "agent-cycle: --mix $mix_provider needs at least one <lane>=<weight>, <lane>.enabled=true or <lane>.balance_usd=<n>, or --reset" >&2
        exit 64
      fi
      mix_overlay="$(mix_build_overlay "$mix_provider" "${mix_rest[@]}")" || exit $?
      if ! mix_write "$state_repo" "$state_dir" "$mix_provider" "$mix_overlay" "$by" >/dev/null; then
        echo "agent-cycle: WARNING — could not publish the mix for $mix_provider (state repo unreachable?)" >&2
        exit 1
      fi
      printf 'agent-cycle: mix set for %s: %s\n' "$mix_provider" "$mix_overlay"
      log_event "mix-set" "$(jq -nc --arg p "$mix_provider" --argjson overlay "$mix_overlay" \
        --arg by "$by" --arg actor "$(toggle_actor)" \
        '{provider: $p, overlay: $overlay, by: $by, actor: $actor}')"
      refresh_dashboard
      exit 0
      ;;
  esac
fi
}
