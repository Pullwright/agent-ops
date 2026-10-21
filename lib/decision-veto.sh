#!/usr/bin/env bash
# shellcheck disable=SC2154,SC2034  # this file's functions read and write the cycle's own globals — assigned by agent-cycle.sh, which sources every lib/*.sh file into one process (#771) — never locally; each function's own header names which ones.
#
# lib/decision-veto.sh — the decision-veto sweep (agent-ops#937): find a
# `pw::decision` decision-log issue a human reopened and act on it.
#
# `decide-tactical` (agent-ops#936) lets the pipeline take a tactical decision
# on its own authority rather than paging a human; `lib/enabler.sh`'s `decide`
# verdict files that decision's own durable record as a closed `pw::decision`
# issue (`create_decision_log_issue`) — a log, not an ask. Reopening it is the
# veto: the D18 pattern (a log a human can scan, a lever they can pull)
# applied to decisions the way requirement 36a already applies it to
# escalations. `scripts/sweep-decision-vetoes.sh` does the GitHub-facing half
# of finding and acting on one; this file is the wiring that turns its stdout
# into fleet-log events and, for a non-terminal item, a real needs-refinement
# block — the one piece a standalone script cannot do itself, since
# `record_needs_refinement_block` (lib/candidate-select.sh) reads and writes
# this cycle's own globals (`blocked_json`, `needs_refinement_label`, …).
#
# Deliberately **not** part of `run_standdown_checks` (lib/standdown.sh),
# despite being a fleet-wide, `--dry-run`-skipped, per-cycle sweep exactly like
# every one of that function's own 2.1a–2.1g sections: that function is called
# before `compute_skip_lists` (agent-cycle.sh) sets `blocked_json`, and
# `record_needs_refinement_block`'s own already-blocked dedup check needs it
# current. `run_decision_veto_sweep` is called separately, after
# `compute_band_eligibility`'s own extracts are settled, so every global this
# file's one function touches already exists.
#
# The re-block this function records for a non-terminal veto also registers
# the still-open log issue as that block's own escalation (agent-ops#937's
# third "Done when" bullet, agent-ops#1198): an `escalated` event naming the
# same `issue_number`/`issue_url`, marked `decision: true`. `ENABLER_ELIGIBLE_JQ`
# (lib/cycle-state.sh) reads that event exactly the way it reads any ordinary
# Enabler escalation — while the log issue stays open, `$issue_state` reads
# `open` and the item is not eligible at all, a mechanical hold no
# `decide-tactical` pass can talk its way past, since the item never reaches
# the Enabler to be re-decided while the veto stands; once the owner comments
# their own decision and re-closes the log issue, the very same `issue-closed`
# branch that answers an ordinary closed escalation fires for this one too,
# with no extra coordinator-cycle wait. Without this registration the veto's
# own re-block would age out through the ordinary threshold regardless of
# whether the log issue was ever closed, and nothing would have stopped a
# later `decide-tactical` pass from silently re-deciding over the still-open
# veto.
#
# The registration is not conditioned on `record_needs_refinement_block`
# actually recording a *fresh* block (review round 2): that call refuses —
# and returns 1 — for an item this cycle's own `blocked_json` already shows
# blocked, the ordinary case being an Implementer's own needs-refinement
# bounce landing between the decision and the owner's reopen, which is
# exactly the situation most likely to prompt a veto. Registering the
# escalation only on a successful *fresh* record would leave that real,
# common case with no registration at all — the existing block ages out on
# its own unrelated threshold, oblivious to the veto standing over it. The
# escalated event is logged whenever this cycle's own `blocked_json` already
# carried the item *or* the fresh record succeeds — the two ways a live
# block for this item can exist the moment the veto is discovered — so it
# always has a block to attach to.

# run_decision_veto_sweep
# Called once, after `compute_band_eligibility`/`compute_enabler_eligible_set`/
# `compute_refiner_candidates` (agent-cycle.sh) have run. Reads
# `decision_vetoes_processed_items` off `union_log` once, fleet-wide, then
# sweeps every configured repository regardless of `--repo` — the same
# breadth every sweep in lib/standdown.sh uses, since a veto on a repository
# this cycle is not otherwise touching still needs to reach a human. Skipped
# on `--dry-run`: the sweep comments, re-blocks, flips pull requests to draft,
# and files issues.
run_decision_veto_sweep() {
  (( DRY_RUN )) && return 0

  local processed_json sweep_slug slug_processed_json sweep_action action
  local veto_repo="" veto_item="" veto_issue_number="" veto_issue_url=""
  local na_repo="" na_item="" na_already_blocked=0 na_recorded=0
  local pending_acts_json cancelled_act
  processed_json="$(decision_vetoes_processed_items "$union_log" "$repo_slug_aliases_json")"
  # Requirement 36f: a veto of a decision whose act has not been performed
  # yet cancels the act, and says so on the log. The retirement itself is
  # already mechanical — `pending_decision_acts` excludes anything a
  # `decision-vetoed` names — but a pending act that simply stops appearing
  # leaves no record that the reopen is what stopped it, and the whole point
  # of putting the window in front of the act is that the cancellation is the
  # visible outcome rather than a silent absence.
  pending_acts_json="$(pending_decision_acts "$union_log")"

  while IFS= read -r sweep_slug; do
    [[ -n "$sweep_slug" ]] || continue
    slug_processed_json="$(jq -c --arg r "$sweep_slug" \
      '[.[] | select(.repo == $r)]' <<<"$processed_json" 2>/dev/null || printf '[]')"
    while IFS= read -r sweep_action; do
      [[ -n "$sweep_action" ]] || continue
      action="$(jq -r '.action // ""' <<<"$sweep_action" 2>/dev/null || true)"
      case "$action" in
        vetoed)
          log_event "decision-vetoed" "$(jq -c 'del(.action)' <<<"$sweep_action" 2>/dev/null || printf '{}')"
          veto_repo="$(jq -r '.repo // ""' <<<"$sweep_action" 2>/dev/null || true)"
          veto_item="$(jq -r '.item // ""' <<<"$sweep_action" 2>/dev/null || true)"
          veto_issue_number="$(jq -r '.issue_number // ""' <<<"$sweep_action" 2>/dev/null || true)"
          veto_issue_url="$(jq -r '.issue_url // ""' <<<"$sweep_action" 2>/dev/null || true)"
          cancelled_act="$(jq -c --arg n "$veto_issue_number" \
            'map(select((.issue_number | tostring) == $n)) | first | .act // empty' \
            <<<"$pending_acts_json" 2>/dev/null || true)"
          if [[ -n "$cancelled_act" && "$cancelled_act" != "null" ]]; then
            log_event "decision-acted" "$(jq -nc --arg r "$veto_repo" --arg i "$veto_item" \
              --argjson n "$veto_issue_number" --arg u "$veto_issue_url" --argjson act "$cancelled_act" \
              '{repo: $r, item: $i, issue_number: $n, issue_url: $u, act: $act,
                outcome: "cancelled"}')"
          fi
          ;;
        needs-refinement)
          na_repo="$(jq -r '.repo // ""' <<<"$sweep_action" 2>/dev/null || true)"
          na_item="$(jq -r '.item // ""' <<<"$sweep_action" 2>/dev/null || true)"
          na_already_blocked=0
          if jq -e --arg r "$na_repo" --arg i "$na_item" \
               'any(.[]?; (.repo // "") == $r and ((.item // "") | tostring) == $i)' \
               <<<"${blocked_json:-[]}" >/dev/null 2>&1; then
            na_already_blocked=1
          fi
          na_recorded=0
          record_needs_refinement_block "$(jq -c 'del(.action)' <<<"$sweep_action" 2>/dev/null || printf '{}')" \
            "script" && na_recorded=1
          if (( na_recorded || na_already_blocked )) \
             && [[ -n "$veto_issue_number" ]] \
             && [[ "$na_repo" == "$veto_repo" ]] \
             && [[ "$na_item" == "$veto_item" ]]; then
            log_event "escalated" "$(jq -nc --arg r "$veto_repo" --arg i "$veto_item" \
              --argjson n "$veto_issue_number" --arg u "$veto_issue_url" \
              '{repo: $r, item: $i, issue_number: $n, issue_url: $u, decision: true}')"
          fi
          ;;
        comment-posted|pr-flipped-to-draft|revisit-filed)
          : # informational only — the veto, the re-block and its escalation
            # registration are what future cycles need on the log; these
            # three are already visible on GitHub itself (the comment, the
            # draft flip, the filed issue).
          ;;
        warning)
          log_event "warning" "$(jq -c --arg r "$sweep_slug" \
            '{detail: ("decision-veto sweep (" + $r + "): "
                       + ((.detail // "") | if . == "" then (del(.action) | tostring) else . end))}' \
            <<<"$sweep_action" 2>/dev/null || printf '{}')"
          ;;
        deferred) ;; # nothing to record — a future cycle picks up where this one capped out
      esac
    done < <(timeout 120 "$SCRIPT_DIR/scripts/sweep-decision-vetoes.sh" "$sweep_slug" "$node_name" "$cycle_id" \
               <<<"$slug_processed_json" 2>>"$cycle_dir/decision-veto-sweep.err" || true)
  done < <(jq -r '.repos[].slug' "$CONFIG_FILE" 2>/dev/null || true)

  return 0
}

# The per-cycle cap on acts performed, for the same reason every sweep beside
# this one caps itself: a backlog surfaces a few per cycle, never as a flood.
# Each act also costs one `gh` read of its own log issue, and the fleet shares
# one rate-limit bucket.
PENDING_DECISION_ACT_MAX="${PENDING_DECISION_ACT_MAX:-3}"

# How long a due act may wait, in veto windows (`decision_veto_window_hours`
# each, and never less than an hour in all), before it is retired as refused
# rather than retried once more: a wait is a read, a search or a write that
# failed, each retry spends one of the slots above, and nothing else bounds
# how many cycles one act may fail for. Three windows is days — longer than
# any outage this fleet has seen, and short of for ever.
PENDING_DECISION_ACT_WAIT_WINDOWS="${PENDING_DECISION_ACT_WAIT_WINDOWS:-3}"

# run_pending_decision_acts
# Requirement 36f's other half: perform the acts `decide-with-veto` decisions
# deferred behind the veto window, once that window has passed and nobody
# pulled the lever. Called once per cycle, immediately after
# `run_decision_veto_sweep` — in that order deliberately, so a reopen this
# same cycle discovers cancels the act before this function could take it,
# rather than racing it. Reads `pending_decision_acts` (lib/cycle-state.sh)
# off `union_log`; skipped on `--dry-run`, since acting writes state events
# that other cycles read as facts.
#
# Three things must hold before an act is performed, and each refusal is
# silent rather than loud, because a not-yet is the ordinary case:
#
#   1. `act_after` has passed. Before then nothing happens and nothing is
#      logged — the decision is simply waiting.
#   2. The `pw::decision` log issue is still **closed**, re-read live. A
#      reopen is the veto and `run_decision_veto_sweep` has already handled
#      it; this second read exists because that sweep is bounded (three
#      actions per repository per cycle) and a veto it deferred must still
#      stop the act. An issue whose state cannot be read at all refuses the
#      act for this cycle and warns: the act is irreversible and the window
#      is not, so an unreadable lever fails closed. That is the opposite
#      direction from the veto sweep's own unreadable-events read, which
#      fails *open* toward honouring a veto — both choices protect the same
#      thing, the owner's ability to stop a decision.
#   3. The act is one this function knows how to perform. Anything else is a
#      warning and no act; `run_enabler_decide` already refused every kind
#      the mandate does not name, so reaching this is a defect, not input.
#
# `corroborate-void` — the first of the two acts requirement 36f reaches —
# is performed by writing the item's `item-void` event, `stage: "decision"`.
# That is the
# whole of it: the void record and requirement 34k's own close
# (`scripts/close-void-github-items.sh`) already exist and already close a
# `pr-<n>-abandoned-…`/`-review-…`/`-superseded-…` item's pull request on the
# next pre-extract window that reaches it. What requirement 34d was missing
# for these three shapes was never the machinery — it was the human
# corroboration an open draft that still changes files cannot get from any
# API call, and that is exactly what the delegate mandate, the elapsed window
# and the un-pulled lever supply here.
#
# `refile-to-pipeline-repo` — the second, reach (c) — is `refile_act`
# (lib/refile.sh): read the original, re-check the paths live, file the
# copy, close the original with a pointer. It is the one act here with
# outcomes short of performing it, each in its own branch below: a read, a
# search or a write that fails — a path that cannot be read at all among
# them — leaves it pending for a later cycle, exactly as an unreadable lever
# does; a re-check that establishes the fact false, or an original someone
# else already closed, retires it through `_decision_act_refuse` —
# `decision-acted`'s third outcome, `refused` — and says so on the
# decision-log issue, so the owner who was offered the lever learns the act
# was never taken. A wait is bounded (PENDING_DECISION_ACT_WAIT_WINDOWS,
# above): an act still owed that many veto windows after it fell due is
# retired the same way, so an original its author deleted, or a repository
# the token cannot write to, cannot hold one of a cycle's three slots for
# ever.

# _decision_act_refuse REPO ITEM ISSUE_NUMBER ISSUE_URL ACT_JSON REASON
# Retire a due act the Script could not corroborate at act time: a
# `warning`, a `decision-acted` with `outcome: "refused"` and the reason —
# which is what takes it out of `pending_decision_acts`, the same way
# `performed` and `cancelled` do — and one best-effort comment on the
# decision-log issue itself. The item is not unblocked: nothing happened,
# and its next Enabler engagement escalates to a person on requirement 36d's
# own per-reason bound, carrying this refusal.
_decision_act_refuse() {
  local repo="$1" item="$2" number="$3" url="$4" act="$5" reason="$6" kind
  kind="$(jq -r '.kind // ""' <<<"$act" 2>/dev/null || true)"
  log_event "warning" "$(jq -nc --arg r "$repo" --arg i "$item" \
    --arg d "pending decision act for $repo $item: the act \"$kind\" was refused at act time and retired — $reason (decision $url)" \
    '{detail: $d, repo: $r, item: $i}')"
  log_event "decision-acted" "$(jq -nc --arg r "$repo" --arg i "$item" \
    --argjson n "$number" --arg u "$url" --argjson act "$act" --arg reason "$reason" \
    '{repo: $r, item: $i, issue_number: $n, issue_url: $u, act: $act,
      outcome: "refused", reason: $reason}')"
  gh issue comment "$number" -R "$repo" --body "$(pipeline_comment_header enabler-decide "${node_name:-}")

The act this decision carried (\`$kind\`) was **not** performed. When its window had passed, the pipeline found that $reason. The decision is retired; the item stays blocked and reaches a person through the ordinary escalation.

$(pipeline_comment_marker "${cycle_id:-}" enabler-decide)" >/dev/null 2>>"$cycle_dir/pending-decision-acts.err" || true
}

run_pending_decision_acts() {
  (( DRY_RUN )) && return 0

  local pending_json pending now_epoch due_epoch acted=0 deferred=0
  local a_repo a_item a_number a_url a_kind a_after a_decision a_rationale a_state
  local a_act a_extra a_result a_rc a_copy_number a_copy_url a_window a_wait_hours
  pending_json="$(pending_decision_acts "$union_log")"
  jq -e 'type == "array" and length > 0' <<<"$pending_json" >/dev/null 2>&1 || return 0
  now_epoch="$(date -u +%s)"

  while IFS= read -r pending; do
    [[ -n "$pending" ]] || continue
    a_after="$(jq -r '.act_after // ""' <<<"$pending" 2>/dev/null || true)"
    due_epoch="$(date -u -d "$a_after" +%s 2>/dev/null || true)"
    # An unparseable `act_after` is not a licence to act now: it is a
    # decision whose window cannot be established, and this leaves it
    # standing rather than performing it early.
    [[ "$due_epoch" =~ ^[0-9]+$ ]] || continue
    (( due_epoch <= now_epoch )) || continue

    if (( acted >= PENDING_DECISION_ACT_MAX )); then
      deferred=$(( deferred + 1 ))
      continue
    fi

    a_repo="$(jq -r '.repo // ""' <<<"$pending" 2>/dev/null || true)"
    a_item="$(jq -r '.item // ""' <<<"$pending" 2>/dev/null || true)"
    a_number="$(jq -r '.issue_number // ""' <<<"$pending" 2>/dev/null || true)"
    a_url="$(jq -r '.issue_url // ""' <<<"$pending" 2>/dev/null || true)"
    a_kind="$(jq -r '.act.kind // ""' <<<"$pending" 2>/dev/null || true)"
    a_decision="$(jq -r '.decision // ""' <<<"$pending" 2>/dev/null || true)"
    a_rationale="$(jq -r '.rationale // ""' <<<"$pending" 2>/dev/null || true)"
    [[ -n "$a_repo" && -n "$a_item" && -n "$a_number" ]] || continue

    a_state="$(gh issue view "$a_number" -R "$a_repo" --json state --jq '.state' \
                 2>>"$cycle_dir/pending-decision-acts.err" || true)"
    if [[ -z "$a_state" ]]; then
      log_event "warning" "$(jq -nc --arg r "$a_repo" --arg i "$a_item" --arg u "$a_url" \
        --arg d "pending decision act for $a_repo $a_item: could not read decision-log issue $a_url to confirm it is still closed — the act is irreversible, so it waits for a cycle that can read the veto lever" \
        '{detail: $d, repo: $r, item: $i}')"
      continue
    fi
    # A reopen is the veto; `run_decision_veto_sweep` has already acted on it
    # (or will, once its own per-repository cap frees up). Either way the act
    # does not happen, and no event is written here: the veto sweep owns the
    # record of a veto.
    [[ "$a_state" == "CLOSED" ]] || continue

    a_act="$(jq -c '.act // {}' <<<"$pending" 2>/dev/null || printf '{}')"
    a_extra='{}'

    # A due act still owed PENDING_DECISION_ACT_WAIT_WINDOWS windows after it
    # fell due has been waiting on something no later cycle is going to fix,
    # and is retired here rather than retried: every retry spends one of this
    # cycle's slots, and three such acts would starve every other act for
    # ever.
    a_window="${decision_veto_window_hours:-24}"
    [[ "$a_window" =~ ^[0-9]+$ ]] || a_window=24
    a_wait_hours=$(( PENDING_DECISION_ACT_WAIT_WINDOWS * a_window ))
    (( a_wait_hours >= 1 )) || a_wait_hours=1
    if (( now_epoch - due_epoch > a_wait_hours * 3600 )); then
      _decision_act_refuse "$a_repo" "$a_item" "$a_number" "$a_url" "$a_act" \
        "the act fell due at $a_after and has waited more than $a_wait_hours hours past that ($PENDING_DECISION_ACT_WAIT_WINDOWS veto windows) without being performed, which is as long as a wait may last"
      acted=$(( acted + 1 ))
      continue
    fi

    case "$a_kind" in
      corroborate-void)
        log_event "item-void" "$(item_event_fields "decision" \
          "${a_decision:-a decide-with-veto decision corroborated this void}" "$a_repo" "$a_item" \
          "$(jq -nc --arg ev "corroborated by the pipeline's own decision $a_url (requirement 36f's delegate mandate), unvetoed through its veto window${a_rationale:+ — $a_rationale}" \
             --argjson n "$a_number" --arg u "$a_url" \
             '{evidence: $ev, decision_issue_number: $n, decision_issue_url: $u}')")"
        ;;
      refile-to-pipeline-repo)
        # Performed through `refile_act`, which re-establishes the fact live,
        # never carried from the verdict: the window between the two is hours
        # long and either repository may have moved. A refusal and a wait
        # each spend one of this cycle's slots, since each cost the reads a
        # performed act would have, and the wait is bounded above. `|| a_rc=$?`,
        # never a bare assignment followed by `$?`: this runs under
        # agent-cycle.sh's `set -e`, where a substitution that fails would
        # abort the cycle before the status could be read.
        a_rc=0
        a_result="$(refile_act "$a_repo" "$a_item" "$a_act" "$a_url")" || a_rc=$?
        if (( a_rc == 2 )); then
          _decision_act_refuse "$a_repo" "$a_item" "$a_number" "$a_url" "$a_act" "$a_result"
          acted=$(( acted + 1 ))
          continue
        elif (( a_rc != 0 )); then
          log_event "warning" "$(jq -nc --arg r "$a_repo" --arg i "$a_item" \
            --arg d "pending decision act for $a_repo $a_item: $a_result — the act stays pending and is retried next cycle (decision $a_url)" \
            '{detail: $d, repo: $r, item: $i}')"
          acted=$(( acted + 1 ))
          continue
        fi
        IFS=$'\t' read -r a_copy_number a_copy_url <<<"$a_result"
        a_extra="$(jq -nc --arg r "$(decision_pipeline_repo)" --arg n "$a_copy_number" --arg u "$a_copy_url" \
          '{refiled: {repo: $r, number: ($n | tonumber), url: $u}}')"
        ;;
      *)
        log_event "warning" "$(jq -nc --arg r "$a_repo" --arg i "$a_item" --arg k "$a_kind" \
          --arg d "pending decision act for $a_repo $a_item names the act \"$a_kind\", which nothing performs — requirement 36f reaches exactly two acts, \"corroborate-void\" and \"refile-to-pipeline-repo\"" \
          '{detail: $d, repo: $r, item: $i}')"
        continue
        ;;
    esac

    log_event "decision-acted" "$(jq -nc --arg r "$a_repo" --arg i "$a_item" \
      --argjson n "$a_number" --arg u "$a_url" --argjson act "$a_act" --argjson extra "$a_extra" \
      '{repo: $r, item: $i, issue_number: $n, issue_url: $u, act: $act,
        outcome: "performed"} + $extra')"
    log_event "unblocked" "$(jq -nc --arg i "$a_item" --arg r "$a_repo" \
      --arg reason "decided: $a_decision" \
      '{item: $i, repo: $r, by: "enabler", reason: $reason}')"
    acted=$(( acted + 1 ))
  done < <(jq -c '.[]' <<<"$pending_json" 2>/dev/null || true)

  if (( deferred > 0 )); then
    log_event "warning" "$(jq -nc --argjson n "$deferred" \
      --arg d "pending decision acts: $deferred due act(s) were left for a later cycle by this cycle's own cap of $PENDING_DECISION_ACT_MAX" \
      '{detail: $d, deferred: $n}')"
  fi

  return 0
}
