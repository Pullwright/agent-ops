#!/usr/bin/env bash
#
# agent-cycle.sh — orchestrates one cycle of the autonomous agent pipeline.
# Full specification: docs/IMPLEMENTATION-PIPELINE-SPEC.md. Config: config.json.

set -euo pipefail

# Captured before the flag loop below consumes it with `shift`: finish-then-
# continue (requirement 39) re-launches this same script with the same
# arguments a chained cycle later, and by then "$@" is long gone.
ORIGINAL_ARGV=("$@")

# --- PATH: cron's environment is minimal; make sure claude, gh, git, jq resolve. ---
# Appended, not prepended: an already-resolvable PATH entry — a caller's own
# shim, e.g. test/toggle.test.sh's offline-e2e stub_bin — must win over these
# fallbacks, or a subprocess of this script (the 2.1b usage-limit probe is the
# one that actually does this) silently reaches a real `claude`/`gh` instead
# of the stub standing in for them (TD-PPagop-26080701).
nvm_bin=""
if [[ -s "$HOME/.nvm/nvm.sh" ]]; then
  # shellcheck disable=SC1091
  . "$HOME/.nvm/nvm.sh" --no-use
  nvm_bin="$(nvm which current 2>/dev/null | xargs -r dirname 2>/dev/null || true)"
fi
path_dirs=(/usr/local/bin /usr/bin /bin "$HOME/.local/bin" "$HOME/.claude/local")
[[ -n "$nvm_bin" ]] && path_dirs+=("$nvm_bin")
PATH="$PATH:$(IFS=:; echo "${path_dirs[*]}")"
export PATH

for bin in claude gh git jq sha256sum; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "agent-cycle: required binary not found on PATH: $bin" >&2
    exit 1
  fi
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"
SCHEMA_FILE="$SCRIPT_DIR/config.schema.json"
PROMPTS_DIR="$SCRIPT_DIR/prompts"
# Exported, and the only variable here that is: a stage's working directory is
# its own ephemeral clone, so a prompt that wants to name a tool this repository
# ships has nothing to name it relative to. A hard-coded `/app` would be right
# for every node as deployed and wrong for every other way this repository is
# run — a maintainer's checkout, the test suite — and a prompt cannot tell which
# it is in. See requirement 24a.
export AGENT_OPS_ROOT="$SCRIPT_DIR"

# shellcheck source=lib/scratch.sh
. "$SCRIPT_DIR/lib/scratch.sh"
# This cycle's scratch directory (lib/scratch.sh, requirement 2.5), entered
# before any other library is sourced so that everything this process or a
# library it calls spools through `mktemp` — lib/issue-priority.sh's cache,
# made as that file is sourced; lib/gh-shim.sh's per-call directories; the
# toggle memos; the end-of-cycle hook's own publish — lies inside it, and
# `cleanup` releases it at the very end. The trap is armed first, on an empty
# name, so that an exit anywhere before `cleanup` is installed — the role
# guard, the schema gate, a management command — releases it too, and a
# signal landing during the mktemp itself finds nothing to release and leaves
# the directory to the sweep.
SCRATCH_DIR=""
trap scratch_release EXIT
scratch_enter agent-cycle || exit 1

# The tolerant raw-line event stream every fleet-union reader folds
# (`union_events`, #2037), sourced here as well as by lib/limit-detect.sh so
# that lib/manage.sh's and lib/drain.sh's readers never depend on the order
# of the sources below.
# shellcheck source=lib/union-stream.sh
. "$SCRIPT_DIR/lib/union-stream.sh"
# shellcheck source=lib/limit-detect.sh
. "$SCRIPT_DIR/lib/limit-detect.sh"
# GitHub's rate limits, which are a different system from the Claude usage
# limits above. Sourcing this also wraps every `gh` call this script makes —
# see the wrapper's header for what that does and does not cover.
# shellcheck source=lib/github-limit.sh
. "$SCRIPT_DIR/lib/github-limit.sh"
# shellcheck source=lib/disk-space.sh
. "$SCRIPT_DIR/lib/disk-space.sh"
# shellcheck source=lib/memory.sh
. "$SCRIPT_DIR/lib/memory.sh"
# shellcheck source=lib/host-budget.sh
. "$SCRIPT_DIR/lib/host-budget.sh"
# shellcheck source=lib/repo-clone.sh
. "$SCRIPT_DIR/lib/repo-clone.sh"
# shellcheck source=lib/model-id.sh
. "$SCRIPT_DIR/lib/model-id.sh"
# shellcheck source=lib/config-schema.sh
. "$SCRIPT_DIR/lib/config-schema.sh"
# expand_home, cfg, cfg_json — shared with review-cycle.sh so the two copies
# can never drift (issue #967).
# shellcheck source=lib/config-access.sh
. "$SCRIPT_DIR/lib/config-access.sh"
# log_event_append — the envelope logic behind this file's own log_event,
# shared with review-cycle.sh's (issue #967); each cycle's own id field, id
# value and log file are the one genuine difference, and stay local to each
# script's own log_event wrapper below.
# shellcheck source=lib/log-event.sh
. "$SCRIPT_DIR/lib/log-event.sh"
# shellcheck source=lib/report-directory.sh
# REPORT_DIRECTORY_DEFAULT (the review pipeline's own ultimate report_directory
# fallback, issue #761): lib/eligibility.sh's prefetch_refiner_sources reads it
# for a repository repository_review does not configure at all.
. "$SCRIPT_DIR/lib/report-directory.sh"
# shellcheck source=lib/metering.sh
. "$SCRIPT_DIR/lib/metering.sh"
# shellcheck source=lib/rework.sh
. "$SCRIPT_DIR/lib/rework.sh"
# shellcheck source=lib/node-time-state.sh
. "$SCRIPT_DIR/lib/node-time-state.sh"
# shellcheck source=lib/schedule-slots.sh
. "$SCRIPT_DIR/lib/schedule-slots.sh"
# shellcheck source=lib/stage-run.sh
. "$SCRIPT_DIR/lib/stage-run.sh"
# shellcheck source=lib/stage-budget.sh
. "$SCRIPT_DIR/lib/stage-budget.sh"
# shellcheck source=lib/stage-attempt.sh
# Sourced after stage-run.sh (run_claude_stage) and stage-budget.sh
# (stage_budget_apply), both of which run_coordinator_stage_attempt calls.
. "$SCRIPT_DIR/lib/stage-attempt.sh"
# shellcheck source=lib/cycle-state.sh
. "$SCRIPT_DIR/lib/cycle-state.sh"
# shellcheck source=lib/candidate-select.sh
. "$SCRIPT_DIR/lib/candidate-select.sh"
# shellcheck source=lib/expensive-gather-cache.sh
# Ahead of candidate-gather.sh, which is its only caller (requirement 48).
. "$SCRIPT_DIR/lib/expensive-gather-cache.sh"
# shellcheck source=lib/candidate-gather.sh
. "$SCRIPT_DIR/lib/candidate-gather.sh"
# shellcheck source=lib/eligibility.sh
# After candidate-gather.sh: its four functions run on what gather_ordered_repos
# and compute_skip_lists leave behind, and a reader following the phase order
# should meet them in that order too.
. "$SCRIPT_DIR/lib/eligibility.sh"
# shellcheck source=lib/notify.sh
# The installation's one notify channel (issue #1279) — notify_post_cycle is
# called from lib/standdown.sh (below), lib/manage.sh and lib/enabler.sh,
# each sourced later in this same process; a function call resolves at run
# time regardless of source order, same as the note on lib/standdown.sh below.
. "$SCRIPT_DIR/lib/notify.sh"
# shellcheck source=lib/standdown.sh
# Sourced last among these: run_standdown_checks calls into most of the libs
# above (crash-loop, github-limit, toggle, merge-autonomy, approver-token, …),
# and a function call resolves at run time regardless of source order — this
# position is for a reader, not the interpreter.
. "$SCRIPT_DIR/lib/standdown.sh"
# shellcheck source=lib/decision-veto.sh
# After lib/eligibility.sh (compute_band_eligibility) and lib/candidate-select.sh
# (record_needs_refinement_block): run_decision_veto_sweep is called after both
# have run, deliberately later than run_standdown_checks's own sweeps — see its
# own header for why.
. "$SCRIPT_DIR/lib/decision-veto.sh"
# shellcheck source=lib/toggle.sh
. "$SCRIPT_DIR/lib/toggle.sh"
# shellcheck source=lib/merge-budget.sh
. "$SCRIPT_DIR/lib/merge-budget.sh"
# shellcheck source=lib/merge-autonomy.sh
. "$SCRIPT_DIR/lib/merge-autonomy.sh"
# shellcheck source=lib/github-app-token.sh
. "$SCRIPT_DIR/lib/github-app-token.sh"
# shellcheck source=lib/approver-token.sh
. "$SCRIPT_DIR/lib/approver-token.sh"
# shellcheck source=lib/rebase-only.sh
# Ahead of approver.sh, whose restale sweep (requirement 46a) calls
# rebase_only_push to sharpen its own genuine-progress test.
. "$SCRIPT_DIR/lib/rebase-only.sh"
# shellcheck source=lib/approver.sh
. "$SCRIPT_DIR/lib/approver.sh"
# shellcheck source=lib/author-token.sh
. "$SCRIPT_DIR/lib/author-token.sh"
# shellcheck source=lib/forge-auth.sh
# Depends on lib/author-token.sh above; called from run_standdown_checks
# (lib/standdown.sh), ahead of every check that authenticates as this cycle.
. "$SCRIPT_DIR/lib/forge-auth.sh"
# shellcheck source=lib/merge-queue.sh
. "$SCRIPT_DIR/lib/merge-queue.sh"
# shellcheck source=lib/union-log-scan.sh
# Ahead of landing.sh, whose _landing_retry_sweep_repo calls
# landing_retry_source_map (#1050).
. "$SCRIPT_DIR/lib/union-log-scan.sh"
# shellcheck source=lib/landing.sh
# Sourced after merge-queue.sh (landing_arm's own queue-detection read),
# github-limit.sh (github_pr_list_truncated, sourced above already) and
# union-log-scan.sh (landing_retry_source_map, above).
. "$SCRIPT_DIR/lib/landing.sh"
# shellcheck source=lib/noop-skip.sh
. "$SCRIPT_DIR/lib/noop-skip.sh"
# shellcheck source=lib/fleet.sh
. "$SCRIPT_DIR/lib/fleet.sh"
# shellcheck source=lib/drain.sh
# Sourced after toggle.sh (uses _toggle_iso) and fleet.sh (uses fleet_logs),
# and ahead of manage.sh below, whose --status/--drain handling calls into it.
. "$SCRIPT_DIR/lib/drain.sh"
# shellcheck source=lib/mirror-lock.sh
# Sourced for manage.sh's own --status `published:` line below (agent-ops#1679):
# scripts/state-sync.sh sources it too, for the winning/losing sides of the
# lock itself, but this is a read-only probe that never takes the lock.
. "$SCRIPT_DIR/lib/mirror-lock.sh"
# shellcheck source=lib/manage.sh
# Sourced after toggle.sh, limit-detect.sh, fleet.sh and merge-autonomy.sh —
# the four its own --status reports are built from; like standdown.sh above,
# the position is for a reader, since run_manage_command resolves at run time
# regardless of source order.
. "$SCRIPT_DIR/lib/manage.sh"
# shellcheck source=lib/crash-loop.sh
. "$SCRIPT_DIR/lib/crash-loop.sh"
# shellcheck source=lib/token-expiry.sh
. "$SCRIPT_DIR/lib/token-expiry.sh"
# shellcheck source=lib/stage-health.sh
. "$SCRIPT_DIR/lib/stage-health.sh"
# shellcheck source=lib/workspace.sh
. "$SCRIPT_DIR/lib/workspace.sh"
# shellcheck source=lib/role.sh
. "$SCRIPT_DIR/lib/role.sh"
# shellcheck source=lib/git-identity.sh
. "$SCRIPT_DIR/lib/git-identity.sh"
# shellcheck source=lib/handoff.sh
. "$SCRIPT_DIR/lib/handoff.sh"
# shellcheck source=lib/review-gate.sh
. "$SCRIPT_DIR/lib/review-gate.sh"
# shellcheck source=lib/closing-keyword-gate.sh
. "$SCRIPT_DIR/lib/closing-keyword-gate.sh"
# shellcheck source=lib/changelog-section-gate.sh
. "$SCRIPT_DIR/lib/changelog-section-gate.sh"
# shellcheck source=lib/required-check-preflight.sh
. "$SCRIPT_DIR/lib/required-check-preflight.sh"
# shellcheck source=lib/reconciliation-gate.sh
. "$SCRIPT_DIR/lib/reconciliation-gate.sh"
# shellcheck source=lib/void-guard.sh
. "$SCRIPT_DIR/lib/void-guard.sh"
# shellcheck source=lib/unvoid-label.sh
. "$SCRIPT_DIR/lib/unvoid-label.sh"
# shellcheck source=lib/work-gone.sh
. "$SCRIPT_DIR/lib/work-gone.sh"
# shellcheck source=lib/void-liveness.sh
. "$SCRIPT_DIR/lib/void-liveness.sh"
# shellcheck source=lib/human-visibility-hygiene.sh
. "$SCRIPT_DIR/lib/human-visibility-hygiene.sh"
# shellcheck source=lib/preflight.sh
# Sourced after work-gone.sh, whose work_gone_clearances it wraps.
. "$SCRIPT_DIR/lib/preflight.sh"
# shellcheck source=lib/dependency-gate.sh
. "$SCRIPT_DIR/lib/dependency-gate.sh"
# shellcheck source=lib/refinement.sh
# Sourced after void-guard.sh, which defines the `entry_field_text` it uses.
. "$SCRIPT_DIR/lib/refinement.sh"
# shellcheck source=lib/enabler.sh
. "$SCRIPT_DIR/lib/enabler.sh"
# shellcheck source=lib/escalation-autonomy.sh
. "$SCRIPT_DIR/lib/escalation-autonomy.sh"
# shellcheck source=lib/preview-config.sh
. "$SCRIPT_DIR/lib/preview-config.sh"
# shellcheck source=lib/issue-priority.sh
. "$SCRIPT_DIR/lib/issue-priority.sh"
# shellcheck source=lib/tech-debt-file.sh
. "$SCRIPT_DIR/lib/tech-debt-file.sh"
# shellcheck source=lib/merge-observed.sh
# Sourced after handoff.sh (whose pr_merge_state it wraps), candidate-select.sh
# (release_pr_claim) and tech-debt-file.sh (techdebt_file_debt/_issue), all of
# which reviewer_merge_observed calls.
. "$SCRIPT_DIR/lib/merge-observed.sh"
# shellcheck source=lib/label-marker.sh
. "$SCRIPT_DIR/lib/label-marker.sh"
# shellcheck source=lib/prompt-overrides.sh
. "$SCRIPT_DIR/lib/prompt-overrides.sh"
# shellcheck source=lib/coordinator-brief.sh
. "$SCRIPT_DIR/lib/coordinator-brief.sh"
# shellcheck source=lib/coordinator-input.sh
. "$SCRIPT_DIR/lib/coordinator-input.sh"
# shellcheck source=lib/repo-order.sh
. "$SCRIPT_DIR/lib/repo-order.sh"
# shellcheck source=lib/gather-phase.sh
# After every lib/*.sh file run_gather_phase's body calls into — eligibility,
# decision-veto, coordinator-input and noop-skip among them — sourced above.
. "$SCRIPT_DIR/lib/gather-phase.sh"
# shellcheck source=lib/pipeline-marker.sh
. "$SCRIPT_DIR/lib/pipeline-marker.sh"
# shellcheck source=lib/labels.sh
. "$SCRIPT_DIR/lib/labels.sh"
# shellcheck source=lib/chain.sh
. "$SCRIPT_DIR/lib/chain.sh"
# shellcheck source=lib/version.sh
. "$SCRIPT_DIR/lib/version.sh"
# shellcheck source=lib/image-drift.sh
. "$SCRIPT_DIR/lib/image-drift.sh"
# shellcheck source=lib/updater-health.sh
. "$SCRIPT_DIR/lib/updater-health.sh"
# shellcheck source=lib/coordinator-phase.sh
# Last of all: after every lib/*.sh file run_coordinator_through_finishing_
# phase's body calls into.
. "$SCRIPT_DIR/lib/coordinator-phase.sh"

# lib/refinement.sh's self-heal hook (requirement 6a, agent-ops#687), installed
# here because this is the one file that sources both it and lib/labels.sh: a
# label projection whose add failed retries once through this, and without it
# `refinement_label_add` has nothing to retry through and the self-heal never
# happens at all. Here rather than beside the projections themselves so it is
# in place before `cleanup`'s trap can run the Refiner — that path projects
# `refined_label` on every ending of the cycle, including one that exits before
# the gather loop's own ensure has run.
#
# The catalogue lookup is what makes a label created this way indistinguishable
# from one the eager per-gathered-repository ensure would have made; a name the
# `target` catalogue does not carry falls through to labels_ensure_one's own
# neutral defaults rather than not being created.
refinement_label_ensure_one() {
  local repo="$1" name="$2" c_name c_colour c_description
  while IFS=$'\t' read -r c_name c_colour c_description; do
    [[ "$c_name" == "$name" ]] || continue
    labels_ensure_one "$repo" "$name" "$c_colour" "$c_description" >/dev/null
    return $?
  done < <(labels_catalogue "$CONFIG_FILE" "$SCHEMA_FILE" target)
  labels_ensure_one "$repo" "$name" >/dev/null
}
REFINEMENT_LABEL_ENSURE=refinement_label_ensure_one

usage() {
  cat <<'EOF'
usage: agent-cycle.sh [--dry-run] [--once] [--repo <slug>]
       agent-cycle.sh --disable [<reason>] [--for <90m|4h|2d|forever>] [--until <timestamp>] [--this-node]
       agent-cycle.sh --drain <reason> [--for <90m|4h|2d|forever>] [--until <timestamp>] [--this-node]
       agent-cycle.sh --enable [--this-node]
       agent-cycle.sh --clear-limit [<reason>]
       agent-cycle.sh --kill-merge-autonomy [<reason>]
       agent-cycle.sh --restore-merge-autonomy
       agent-cycle.sh --status

Run one cycle of the autonomous agent pipeline, or manage the switch that
stops cycles from starting (shared with review-cycle.sh).

  --dry-run          Select an item and print the work order; implement nothing.
  --once             One verbose cycle in the foreground.
  --repo <slug>      Restrict selection to one configured repo (testing).
  --disable [reason] Stop future cycles starting outright — in-flight work
                     included. A reason is required — the next person to
                     wonder why nothing is happening is entitled to one.
                     Expires after `disable_default_ttl` unless --for or
                     --until says otherwise. Issued while a --drain is active,
                     this tightens it to a full stop immediately.
  --drain <reason>   Stop new work being picked up, but keep finishing
                     whatever is already in flight — an open changes-requested,
                     merge-conflict, dequeued, or abandoned-draft pull request
                     — until every repo has nothing left to finish, then rest
                     there rather than exiting. A reason is required, on the
                     same terms as --disable. Same --for/--until/--this-node
                     handling as --disable, including which of --enable or
                     --enable --this-node clears it. Issued while a --disable
                     is active, this is a usage error — it would loosen a
                     stricter stand-down, which only --enable may do; issued
                     while a --drain is already active, it extends it, same as
                     re-issuing --disable does.
  --for <duration>   How long --disable or --drain lasts: 90m, 4h, 2d, or
                     `forever`.
  --until <timestamp> When --disable or --drain lasts until: a GNU
                     `date`-compatible absolute timestamp (e.g. '2026-08-10
                     18:00', 'tomorrow 12:00'), an alternative to --for. With
                     both given, the later of the two deadlines wins and a
                     warning is issued.
  --enable           Clear the switch — whichever mode it is in — and let
                     cycles run (or resume picking up new work) again.
  --this-node        Modifies --disable, --drain or --enable to act on this
                     node alone, never on the fleet switch: writes only this
                     node's own record, and for --enable clears only that
                     record, leaving `fleet/disabled.json` untouched either
                     way. Stands this one node down without a container
                     recreate — the rest of the fleet keeps working.
                     Combining it with anything but --disable, --drain or
                     --enable is an error. An unmodified --disable or --drain
                     also writes a local record, but tags it `scope: "fleet"`
                     to mark it a mirror of the fleet switch rather than a
                     node-scoped stand-down; --enable --this-node refuses to
                     clear one of those, since plain --enable is what undoes a
                     fleet-wide disable.
  --clear-limit      Lift a usage-limit stand-down across the fleet (2.1). Use
                     it once the limit is actually gone — you raised the cap,
                     or the plan rolled over. Unlike --enable this touches no
                     switch: it clears fleet/limit.json and logs a
                     `limit-cleared` event that supersedes the cooldown.
  --kill-merge-autonomy [reason]
                     Force every repo's effective `merge_autonomy` to `human`
                     fleet-wide, immediately, regardless of config.json or any
                     per-repo override — the D18 kill switch (docs/reviews/
                     2026-08-14-autonomy-investigation.md §6). A reason is
                     required, on the same terms as --disable. Reuses the
                     fleet-flag mechanism --disable/--enable share
                     (fleet/merge-autonomy-kill.json) but stops nothing else:
                     cycles keep running normally, only approval and landing
                     are forced back to human.
  --restore-merge-autonomy
                     Clear the kill switch and let each repo's configured
                     `merge_autonomy` level — and any per-repo override —
                     govern again.
  --status           Report the switch — distinguishing a node-scoped disable,
                     a fleet disable, or both, whether it is a full stop or a
                     drain (and, while draining, how much finishing-source
                     work is left as of the last cycle to check) — any
                     usage-limit stand-down, the merge-autonomy kill switch,
                     and whether either pipeline is running.
  --help             Display this help and exit.

--dry-run and --once bypass the no-op short-circuit (requirement 3b): a human
asking for a cycle wants the Co-Ordinator's answer, not a cached verdict. They
do not bypass the switch — if you disabled the pipeline to edit these files,
running them by hand is the same hazard.

The Enabler (requirement 35) runs at the very end of a cycle, once the
workspace is gone: --dry-run never engages it (a cycle that promises to change
nothing must not claim an item or raise an issue), while --once does — a
supervised engagement is the only way to watch one happen.

Environment:
  AGENT_OPS_ROLE   `active` on the one node that runs unattended cycles;
                   anything else (including unset) makes this a standby, which
                   skips them. --dry-run and --once bypass it; the switch
                   commands work on any node.
EOF
}

# --- Flags ---
DRY_RUN=0
ONCE=0
REPO_FILTER=""
MANAGE_ACTION=""
DISABLE_REASON=""
DRAIN_REASON=""
DISABLE_FOR=""
DISABLE_UNTIL=""
CLEAR_LIMIT_REASON=""
KILL_MERGE_AUTONOMY_REASON=""
THIS_NODE=0
set_manage_action() {
  if [[ -n "$MANAGE_ACTION" ]]; then
    echo "agent-cycle: --disable, --drain, --enable, --clear-limit, --kill-merge-autonomy, --restore-merge-autonomy and --status are mutually exclusive" >&2
    exit 64
  fi
  MANAGE_ACTION="$1"
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --once) ONCE=1; shift ;;
    --repo) REPO_FILTER="${2:-}"; shift 2 ;;
    --disable)
      set_manage_action disable; shift
      # A bare `--disable "editing lib/"` reads far better than forcing
      # `--reason`, and the next token can only be a reason if it isn't a flag.
      if [[ $# -gt 0 && "$1" != --* ]]; then DISABLE_REASON="$1"; shift; fi
      ;;
    --drain)
      set_manage_action drain; shift
      # Required, unlike --disable's optional reason (below): a drain that
      # never says why is doubly hard to explain, since it looks like a
      # working pipeline (cycles run, PRs finish) right up until nothing new
      # appears.
      if [[ $# -gt 0 && "$1" != --* ]]; then DRAIN_REASON="$1"; shift; fi
      ;;
    --enable) set_manage_action enable; shift ;;
    --clear-limit)
      set_manage_action clear-limit; shift
      # Optional here, unlike --disable's: a stand-down being lifted is
      # self-explanatory in a way that one being imposed is not.
      if [[ $# -gt 0 && "$1" != --* ]]; then CLEAR_LIMIT_REASON="$1"; shift; fi
      ;;
    --kill-merge-autonomy)
      set_manage_action kill-merge-autonomy; shift
      # A reason is required, same as --disable's — the next person to
      # wonder why every repo is stuck at human is entitled to one.
      if [[ $# -gt 0 && "$1" != --* ]]; then KILL_MERGE_AUTONOMY_REASON="$1"; shift; fi
      ;;
    --restore-merge-autonomy) set_manage_action restore-merge-autonomy; shift ;;
    --status) set_manage_action status; shift ;;
    --for) DISABLE_FOR="${2:-}"; shift 2 ;;
    --until) DISABLE_UNTIL="${2:-}"; shift 2 ;;
    --this-node) THIS_NODE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "agent-cycle: unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

if [[ -n "$MANAGE_ACTION" ]]; then
  if (( DRY_RUN || ONCE )) || [[ -n "$REPO_FILTER" ]]; then
    echo "agent-cycle: --disable/--drain/--enable/--clear-limit/--kill-merge-autonomy/--restore-merge-autonomy/--status manage stand-down state; they do not run a cycle" >&2
    exit 64
  fi
  if [[ "$MANAGE_ACTION" != "disable" && "$MANAGE_ACTION" != "drain" ]] && [[ -n "$DISABLE_FOR" || -n "$DISABLE_UNTIL" ]]; then
    echo "agent-cycle: --for and --until only apply to --disable or --drain" >&2
    exit 64
  fi
  if [[ "$MANAGE_ACTION" == "disable" && -z "$DISABLE_REASON" ]]; then
    echo "agent-cycle: --disable needs a reason, e.g. --disable 'editing lib/cycle-state.sh'" >&2
    exit 64
  fi
  if [[ "$MANAGE_ACTION" == "drain" && -z "$DRAIN_REASON" ]]; then
    echo "agent-cycle: --drain needs a reason, e.g. --drain 'clearing the backlog before a Kubernetes migration'" >&2
    exit 64
  fi
  if [[ "$MANAGE_ACTION" == "kill-merge-autonomy" && -z "$KILL_MERGE_AUTONOMY_REASON" ]]; then
    echo "agent-cycle: --kill-merge-autonomy needs a reason, e.g. --kill-merge-autonomy 'Approver App misbehaving'" >&2
    exit 64
  fi
fi
if (( THIS_NODE )) && [[ "$MANAGE_ACTION" != "disable" && "$MANAGE_ACTION" != "drain" && "$MANAGE_ACTION" != "enable" ]]; then
  echo "agent-cycle: --this-node only modifies --disable, --drain or --enable" >&2
  exit 64
fi

# --- Role guard (requirement 2.4) ---
# Before the config is even read: a standby node must leave no trace of the
# tick beyond the cron log — no cycle directory, no log.jsonl event — so its
# state stays a faithful mirror of the active node's (see scripts/state-sync.sh)
# and its dashboard shows the fleet's work rather than its own idling.
#
# Bypassed by --dry-run and --once (a human asking for a cycle is not an
# unattended one) and by the switch commands, which must stay usable on every
# node. Not bypassed by --repo alone: that flag narrows an otherwise ordinary
# cycle.
if [[ -z "$MANAGE_ACTION" ]] && ! (( DRY_RUN || ONCE )) && ! role_is_active; then
  # The trailing newline is added here because command substitution eats the
  # one role_skip_message prints, and a cron log wants whole lines.
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(role_skip_message agent-cycle)"
  exit 0
fi

# --- Config ---
# The schema gate (requirement 1b): config.schema.json is the single
# statement of config.json's shape, validated here, before any individual key
# is read from it — the same fail-fast position requirement 1a's model-id
# resolution occupies below, and well before the lock. One error per run
# names every offending path at once, so a five-key typo costs one cycle to
# fix, not five.
schema_errors="$(config_schema_errors "$CONFIG_FILE" "$SCHEMA_FILE")" && schema_status=0 || schema_status=$?
if ((schema_status == 2)); then
  echo "agent-cycle: $schema_errors" >&2
  exit 1
elif ((schema_status == 1)); then
  echo "agent-cycle: config.json does not match config.schema.json:" >&2
  while IFS= read -r line; do echo "agent-cycle:   $line" >&2; done <<<"$schema_errors"
  exit 1
fi

# config_defaults (issue #197) is the only place a default is written: every
# key config.schema.json declares a `default` for reads as fully populated
# below, with no `// literal` of its own to drift from the schema's.
DEFAULTED_CONFIG="$(config_defaults "$CONFIG_FILE" "$SCHEMA_FILE")"

# Requirement 1b's cross-key duplicate-slug guard for repos[] (issue #1576):
# unlike repository_review.repos (config_duplicate_repository_review_slugs, shared
# with review-cycle.sh's own startup refusal), nothing checked repos[] itself
# for two entries naming the same slug. lib/prompt-overrides.sh's
# prompt_overrides_json_for_repo has no head -1/first guard and would emit a
# multi-line, unparseable overrides string on a duplicate; refusing here
# means no resolver's behaviour under a duplicate slug ever depends on
# whether it happens to guard itself the way lib/escalation-autonomy.sh's and
# lib/landing.sh's already do. Checked here, right after config_defaults
# resolves .repos and before anything reads it (the first read today is
# all_repos_json below), since this is a configuration error independent of
# whether this cycle happens to reach a .repos read; shared with
# scripts/doctor.sh's own `fail` through the same config_duplicate_repos_slugs
# (lib/config-schema.sh).
duplicate_repos_slugs="$(config_duplicate_repos_slugs "$(cfg_json '.repos')")"
if [[ -n "$duplicate_repos_slugs" ]]; then
  echo "agent-cycle: repos lists [$duplicate_repos_slugs] more than once — refusing to start rather than guess which entry's overrides apply" >&2
  exit 1
fi

state_dir="$(expand_home "$(cfg '.state_dir')")"
workspace_root="$(expand_home "$(cfg '.workspace_root')")"
# Exported, not merely a local, so every subprocess this cycle forks from
# here on — a `scripts/gather-*`/`scripts/sweep-*` call and, crucially, each
# `claude -p` stage — inherits it: the `gh` transport shim (requirement
# 2.0e, agent-ops#1084) reads this to find state_dir/gh-shim/ from wherever
# it is invoked, including a model-driven `gh …` call this process never sees
# directly.
export PW_GH_STATE_DIR="$state_dir"
coordinator_model="$(resolve_model_id coordinator_model "$(cfg '.coordinator_model')")"
implementer_model_default="$(resolve_model_id implementer_model_default "$(cfg '.implementer_model_default')")"
implementer_model_trivial="$(resolve_model_id implementer_model_trivial "$(cfg '.implementer_model_trivial')")"
reviewer_model_default="$(resolve_model_id reviewer_model_default "$(cfg '.reviewer_model_default')")"
# The complexity escalation (requirement 8a): a PR graded `complexity:high` is
# reviewed on this tier. Empty falls back to the default tier, which switches
# the escalation off.
reviewer_model_complex="$(cfg '.reviewer_model_complex')"
[[ -n "$reviewer_model_complex" ]] || reviewer_model_complex="$reviewer_model_default"
reviewer_model_complex="$(resolve_model_id reviewer_model_complex "$reviewer_model_complex")"
# The Approver (requirement 8b, D18 WI-5). Three tiers on the same
# empty-falls-back-to-the-tier-below chain `reviewer_model_complex` already
# uses, extended one step further for adjudication — `resolve_model_id`
# passes an empty value through unchanged, so `approver_model_default` empty
# stays empty here and disables the whole stage further down (requirement 8b).
approver_model_default="$(resolve_model_id approver_model_default "$(cfg '.approver_model_default')")"
approver_model_complex="$(cfg '.approver_model_complex')"
[[ -n "$approver_model_complex" ]] || approver_model_complex="$approver_model_default"
approver_model_complex="$(resolve_model_id approver_model_complex "$approver_model_complex")"
approver_model_critical="$(cfg '.approver_model_critical')"
[[ -n "$approver_model_critical" ]] || approver_model_critical="$approver_model_complex"
approver_model_critical="$(resolve_model_id approver_model_critical "$approver_model_critical")"
# The restale sweep's own no-progress escalation threshold (requirement 46,
# agent-ops#682) — how long a rebase-only-stale Approver review, or an
# unreviewed pull request whose recovery engagements are not producing one
# (agent-ops#890), is retried before it is handed to a human instead.
approver_restale_escalate_after_hours="$(cfg '.approver_restale_escalate_after_hours')"
# The unreviewed trigger's own arming threshold (requirement 46,
# agent-ops#890) — how long a ready, non-draft, `pr_label` pull request may
# carry no Approver review at all before the sweep treats it as stranded
# rather than as ordinary in-flight work.
approver_unreviewed_engage_after_hours="$(cfg '.approver_unreviewed_engage_after_hours')"
# The Enabler (requirements 35–37). Its model is the most expensive this system
# runs, which is affordable only because the eligibility rule engages it rarely:
# an empty `enabler_model` disables the stage outright.
enabler_model="$(resolve_model_id enabler_model "$(cfg '.enabler_model')")"
# The Enabler's own critical tier (D18 §6, agent-ops#936): both bounded
# passes below `escalate` — `adjudicate-first`'s adjudication and
# `decide-tactical`'s decide — run at this model, on the same
# empty-falls-back-to-the-tier-below pattern `approver_model_critical` uses
# above, rather than at `enabler_model` itself: the Enabler has no second
# tier the way the Approver's three-tier chain does, so this is that tier's
# first appearance.
enabler_model_critical="$(cfg '.enabler_model_critical')"
[[ -n "$enabler_model_critical" ]] || enabler_model_critical="$enabler_model"
enabler_model_critical="$(resolve_model_id enabler_model_critical "$enabler_model_critical")"
enabler_after_coordinator_cycles="$(cfg '.enabler_after_coordinator_cycles')"
# A refinement block (requirements 34e, 35a) ages on its own threshold,
# because unlike an ordinary block it waits on the Enabler and nothing else —
# a human refining the item first, or the Co-Ordinator's cheap re-check
# noticing the condition already cleared. Left unconfigured it inherits
# enabler_after_coordinator_cycles' value, which preserves the shared
# threshold this class had before the two were split apart (TD-PPagop-26072604).
# This inheritance is cross-key, not a schema default (config.schema.json has
# none for this key), so it stays a runtime fallback rather than moving into
# config_defaults.
refinement_after_coordinator_cycles="$(cfg '.refinement_after_coordinator_cycles')"
[[ -n "$refinement_after_coordinator_cycles" && "$refinement_after_coordinator_cycles" != "null" ]] \
  || refinement_after_coordinator_cycles="$enabler_after_coordinator_cycles"
enabler_recheck_hours="$(cfg '.enabler_recheck_hours')"
labels_ensure_interval_hours="$(cfg '.labels_ensure_interval_hours')"
enabler_escalation_label="$(cfg '.enabler_escalation_label')"
# Requirement 36d's `precedents`: the installation's standing-decisions file,
# relative to this checkout (the directory holding config.json) unless
# absolute; empty (the schema default, or an explicit null) supplies none.
standing_decisions_file="$(cfg '.standing_decisions_file')"
# Requirement 36f's veto window, in hours: how long a `decide-with-veto`
# decision that carries an act waits before the act is performed.
decision_veto_window_hours="$(cfg '.decision_veto_window_hours')"
[[ "$decision_veto_window_hours" =~ ^[0-9]+$ ]] || decision_veto_window_hours=24
[[ "$standing_decisions_file" != "null" ]] || standing_decisions_file=""
if [[ -n "$standing_decisions_file" && "$standing_decisions_file" != /* ]]; then
  standing_decisions_file="$SCRIPT_DIR/$standing_decisions_file"
fi
# The assignment is what does the work — it both puts the issue in front of the
# human configured to receive them and excludes it from the `issues` source
# (requirement 16.4), so an escalation can never be selected as work by the
# very pipeline that raised it. That second property depends on the assignee
# actually being set, so an enabled Enabler with no assignee configured is a
# fatal misconfiguration, not a silent skip: an unassigned escalation is one
# the pipeline could go on to pick up as its own work.
enabler_assignee="$(cfg '.enabler_assignee')"
# The per-close re-filing rate limit (requirement 8f/8c, agent-ops#779,
# decided on #784 as behaviour (b)): how long a human's own close of an
# escalation issue suppresses the *next* filing for the same item, in
# `open_question_escalate` (lib/landing.sh) and `approver_escalate`
# (lib/approver.sh) alike. `0` disables the guard outright.
escalation_refile_after_hours="$(cfg '.escalation_refile_after_hours')"
# Crash-loop escalation (requirement 2.7). `crash_loop_after` is the
# consecutive-failure threshold; 0 or absent turns the check off, so an
# older config runs exactly as before. `crash_loop_repo` is where the
# escalation issue is filed — the pipeline's own repository, because a
# Co-Ordinator that cannot run belongs to no target repo's backlog.
crash_loop_after="$(cfg '.crash_loop_after')"
[[ "$crash_loop_after" =~ ^[0-9]+$ ]] || crash_loop_after=0
crash_loop_repo="$(cfg '.crash_loop_repo')"
# `crash_loop_min_clear_minutes`: how long a Co-Ordinator-class escalation's
# clearing success must hold, with the same detail never resuming in the
# meantime, before `crash_loop_retire_resolved` actually closes the issue
# (the 2026-09-05 fleet flap — six escalations in four hours, each retired
# within minutes of a lone success before the same detail resumed, with
# gaps as short as two minutes between a retirement and the next same-
# detail failure). The default, 30, is two of `schedule.cycle_interval_
# minutes`'s own default 15-minute firings — long enough for a recurrence
# to reach this node's own peer-synced union before the success is
# trusted. `0` restores instant retirement on the first nameable success.
crash_loop_min_clear_minutes="$(cfg '.crash_loop_min_clear_minutes')"
[[ "$crash_loop_min_clear_minutes" =~ ^[0-9]+$ ]] || crash_loop_min_clear_minutes=0
# Deferred crash-loop escalations this cycle's step-1b block could not file
# safely (agent-ops#1074): populated by `crash_loop_escalate_or_defer`,
# drained by `crash_loop_refile_pending` from `cleanup()`, once this cycle's
# own Co-Ordinator attempt (if any) has had its chance to prove the run over.
crash_loop_pending_refile=()
# escalation_webhook_url is read for its own sake below (an alias
# notify_resolve_webhook_url folds into notify_webhook_url — issue #1279,
# requirement 2m) and separately because scripts/doctor.sh's own alias
# warning reads the raw key, not the resolved one.
escalation_webhook_url="$(cfg '.escalation_webhook_url')"
# NOTIFY_WEBHOOK_URL — the non-public, per-node source for the same
# credential (issue #991, TD-PPagop-26082516): config.json is fleet-wide and
# tracked in this public repository, so an installation that would rather not
# commit a live webhook URL there sets this in .env instead and leaves
# notify_webhook_url empty. Validated here, at read time, rather than only by
# scripts/doctor.sh — a malformed value is rejected and logged rather than
# silently handed to curl, the same way an unset variable would resolve.
notify_webhook_url_env="$(notify_webhook_url_env_or_empty "${NOTIFY_WEBHOOK_URL:-}")"
# notify_webhook_url — the installation's one notify channel (requirement
# 2m, lib/notify.sh, issue #1279): every escalation issue filed or
# auto-closed, every pager-fired/pager-cleared (#1278), and every fleet-wide
# stand-down beginning or ending, POSTed as one compact JSON body. Resolved
# with NOTIFY_WEBHOOK_URL (the environment) ahead of both config.json keys
# (issue #991) — config.json's own notify_webhook_url ships in the image and
# is credential-independent of GH_TOKEN by construction, but fleet-wide and
# tracked, which is exactly what the environment source exists to avoid.
# Empty (the default, once every source above is also empty) means this
# installation has none configured, and notify_post is a no-op throughout the
# cycle. A set value is still inert on a node whose EGRESS_EXTRA_ALLOW does
# not name the webhook's host: the POST leaves through the same default-deny
# egress fence every other outbound call does (D24) — doctor.sh checks for
# this (requirement 2m).
notify_webhook_url="$(notify_resolve_webhook_url "$(cfg '.notify_webhook_url')" "$escalation_webhook_url" "$notify_webhook_url_env")"
notify_events_json="$(cfg_json '.notify_events')"
notify_min_interval_seconds="$(cfg '.notify_min_interval_seconds')"
[[ "$notify_min_interval_seconds" =~ ^[0-9]+$ ]] || notify_min_interval_seconds=600
# TD-PPagop-26081404: how many consecutive times, on this one node, the
# required-checks read at the ready-gate (requirement 31c) must come back
# `unknown` before its per-item node-level `warning` is replaced by one
# louder escalation event naming the streak — see the ready-gate block below
# and `review_gate_unknown_streak_verdict` (lib/review-gate.sh). Deliberately
# not `crash_loop_after`: that threshold governs a different escalation
# (fleet-wide, issue-filing) with its own semantics, and reusing its config
# key would let a tuning change for one silently retune the other. A fixed
# constant rather than its own config key, since the fix this exists for is
# "notice a repeating pattern sooner", not something an installation needs to
# tune per repo.
review_gate_unknown_streak_after=3
if ! config_enabler_assignee_ok "$enabler_model" "$enabler_assignee"; then
  echo "agent-cycle: enabler_model is set but enabler_assignee is not configured — refusing to run with an unassigned escalation target; set enabler_assignee in config.json or clear enabler_model to disable the Enabler" >&2
  exit 1
fi
# The label a human applies on GitHub to ask for a void to be reopened
# (requirement 34f). Only a human can apply it — no stage here ever does — so
# requirement 34c's "only a human may clear a void" is unchanged; what this
# gives them is a way to say it from where they actually are.
unvoid_label="$(cfg '.unvoid_label')"
# How old a fully-actioned void must be before it is dropped from the extract
# (requirement 34n). `0` disables retirement, which is also what an
# unparseable value falls back to — never retiring is the safe direction, an
# unbounded extract being the cost this requirement exists to bound rather
# than a correctness risk on its own.
void_retire_after_days="$(cfg '.void_retire_after_days')"
[[ "$void_retire_after_days" =~ ^[0-9]+$ ]] || void_retire_after_days=0
# The refinement class (requirements 34e, 35d). The label is a projection onto
# issue-type items and nothing reads it back, so an empty value switches the
# projection off without touching the log mechanism that actually carries the
# state. The cap bounds how much of one engagement the day-one backlog of
# silently-skipped items may take; `0` removes the class from engagements while
# still recording the blocks.
needs_refinement_label="$(cfg '.needs_refinement_label')"
refinement_max_per_engagement="$(cfg '.refinement_max_per_engagement')"
[[ "$refinement_max_per_engagement" =~ ^[0-9]+$ ]] || refinement_max_per_engagement=3
# The per-reason bound's own cap (D18 §5, agent-ops#936): how many
# decide-tactical passes `escalation_autonomy_decide_pass_available` (lib/
# enabler.sh) allows for one item in total, whatever their reason — the
# backstop that turns "a fresh reason always gets a fresh pass" into a
# bounded total rather than an unbounded one. A human touch (eligibility
# `reason: "issue-closed"`) short-circuits the check for that cycle, granting
# one further pass, but does not reset the count.
escalation_adjudication_max_passes="$(cfg '.escalation_adjudication_max_passes')"
[[ "$escalation_adjudication_max_passes" =~ ^[0-9]+$ ]] || escalation_adjudication_max_passes=3
# The Refiner (requirement 39): the positive counterpart of the refinement
# class above. `refined_label` is a projection too, never read back — there is
# no hand-applied form of it, unlike `needs_refinement_label` — and empty
# switches it off without touching the `item-refined` record the Co-Ordinator
# actually reads (requirement 3h). `refinement_policy` is per-source and read
# by both the Refiner (which sources it may spend an engagement on) and the
# Co-Ordinator (which sources it must not select unrefined); an unreadable
# object is treated as empty, which is "every source exempt" — the same "not a
# licence to spend" default every threshold here falls back to.
refiner_model="$(resolve_model_id refiner_model "$(cfg '.refiner_model')")"
refined_label="$(cfg '.refined_label')"
refiner_max_per_engagement="$(cfg '.refiner_max_per_engagement')"
[[ "$refiner_max_per_engagement" =~ ^[0-9]+$ ]] || refiner_max_per_engagement=5
refinement_policy_json="$(cfg_json '.refinement_policy')"
jq -e 'type == "object"' <<<"$refinement_policy_json" >/dev/null 2>&1 || refinement_policy_json='{}'
# Requirement 1c (agent-ops#822): a source resolved to "required" is never
# selected unrefined (prompts/coordinator.md's "Per-source refinement
# policy"), so with no Refiner ever engaging to refine one (requirement 39's
# own gate on refiner_model being set), its items would wait forever — the
# same pairing shape as the enabler_assignee guard above, shared with
# scripts/doctor.sh through the same lib/config-schema.sh function.
required_sources_without_refiner="$(config_required_refinement_sources_without_refiner \
  "$refinement_policy_json" "$refiner_model")"
if [[ -n "$required_sources_without_refiner" ]]; then
  echo "agent-cycle: refinement_policy requires [$required_sources_without_refiner] but refiner_model is empty — refusing to start rather than let a source's unrefined items wait forever with nothing ever refining one" >&2
  exit 1
fi
# Requirement 1c's second refuse spelling (agent-ops#924's decision on
# TD-PPagop-26082704/agent-ops#1003): "failed-runs" has no candidate array at
# all for the Refiner's own candidate gathering to ever reach
# (prompts/coordinator.md's "Per-source refinement policy"), so a "required"
# policy on it is unsatisfiable whatever refiner_model or
# refiner_max_per_engagement are — refused outright, the same as an empty
# refiner_model above.
required_failed_runs_source="$(config_required_failed_runs_source "$refinement_policy_json")"
if [[ -n "$required_failed_runs_source" ]]; then
  echo "agent-cycle: refinement_policy requires failed-runs but that source has no candidate array for the Refiner's own candidate gathering to ever reach — refusing to start rather than let its items wait forever with nothing ever refining one" >&2
  exit 1
fi
# Requirement 1c's *warn*, not refuse, spelling (agent-ops#924's decision on
# TD-PPagop-26082704/agent-ops#1003): refiner_max_per_engagement: 0 with
# refiner_model set is a deliberate, temporary pause of a stage that still
# exists, not a configuration nobody could ever satisfy — so a "required"
# source left unrefinable by the cap alone only warns, and only after logging
# is initialised below (log_event/log_file are not defined yet at this point
# in the script), every cycle the condition holds so it cannot age out of the
# dashboard's window. Carried forward in this variable rather than logged
# here.
refinement_paused_sources="$(config_refinement_sources_paused_by_cap \
  "$refinement_policy_json" "$refiner_model" "$refiner_max_per_engagement")"
# Requirement 1c, "the floor" (agent-ops#822): refiner_model and enabler_model
# are the two stages that can author a work order's context/acceptance
# directly (requirements 39 and 36b); either ranking below an implementer
# tier it might write for is exactly the failure #815 (fixed by #819) and
# #821 both trace to. Shared with scripts/doctor.sh through the same
# lib/config-schema.sh function, so the Script's refusal and doctor's `fail`
# can never drift.
tier_violations="$(config_model_tier_floor_violations "$refiner_model" "$enabler_model" \
  "$implementer_model_default" "$implementer_model_trivial")"
if [[ -n "$tier_violations" ]]; then
  while IFS=$'\t' read -r author_key floor_key author_id floor_id; do
    [[ -n "$author_key" ]] || continue
    echo "agent-cycle: $author_key ($author_id) ranks below $floor_key ($floor_id) on the fleet's model-tier ladder (lib/model-id.sh's MODEL_TIER_RANK) — refusing to start rather than let it author a specification for a more capable Implementer (docs/IMPLEMENTATION-PIPELINE-SPEC.md requirement 1c)" >&2
  done <<<"$tier_violations"
  exit 1
fi
pr_label="$(cfg '.pr_label')"
# Read here (rather than left to the Co-Ordinator, which puts it in the work
# order's `branch`) because requirement 3c's gatherer needs it: a PR is only
# ours to push to if its head branch is under this prefix. The Landing Gate says
# branches outside it belong to humans.
branch_prefix="$(cfg '.branch_prefix')"
max_open_agent_prs="$(cfg '.max_open_agent_prs')"
# Every stage cap — the wall-clock backstop and the liveness watchdog alike —
# is now derived per (actor, repository, model) from the fleet's own record of
# itself (requirement 4f, lib/stage-budget.sh). What is read from the
# configuration here is only what an installation has explicitly overridden;
# absent, the derivation answers, and with no history at all the shipped prior
# does. Nothing in this file carries a default for them any more, which is the
# point: a self-tuning value that a config key silently outranks would never
# tune at all.
#
# `lock_stale_after` becomes a *floor* on a derived value rather than an
# assertion checked against fixed caps (requirement 4f). Absent is normal.
lock_stale_configured_hours="$(cfg '.lock_stale_after // 0')"

# How much room the derived lock leaves beyond the summed backstops. Half an
# hour covers everything a cycle does outside its stages — the pre-fetches,
# the claim traffic, the clone and its deletion — with margin, and erring long
# here is close to free: a dead holder is taken over on its pid rather than on
# its age, so this bounds only how long a live but hung cycle may hold on.
LOCK_SLACK_MIN=30

# Initialised here, not at the derivation below, because the EXIT trap is armed
# long before that: a cycle that stands down or finds the lock held still runs
# `cleanup`, and an unset variable read from inside a trap under `set -u` would
# abandon the trap part-way — costing the cycle its `cycle-end` event, its lock
# release and its state-sync push. An empty table is a valid answer that
# resolves to the shipped priors.
stage_budget_json='{"cells":{},"actors":{}}'
# Likewise: `acquire_lock` reads this, and is called immediately after the
# derivation sets it, but a function that reads an unset global under `set -u`
# fails at the reader rather than at the writer. Four hours, the value this
# used to be configured to, until the derivation replaces it.
lock_stale_after_sec=14400

# stage_budget_overrides ACTOR [REPO]
# What the configuration says about this actor, as `{backstop, inactivity}` —
# either a number or null. The first two levels of requirement 4f's
# precedence, most specific first: a `stage_timeouts`/`stage_inactivity` entry
# on the repository being worked, then the plain `timeout_<actor>` /
# `inactivity_<actor>` key. Null means the configuration is silent and the
# derivation answers.
#
# Read here rather than in lib/stage-budget.sh because the configuration is
# this script's to know; the library stays a pure function of the log.
stage_budget_overrides() {
  local actor="$1" repo="${2:-}" out
  # TD-PPagop-26081407: reads CONFIG_FILE straight off disk (test 1 — a
  # config a human is mid-edit, or a bad merge, can be unparseable at this
  # exact moment) and `{}` — "no overrides configured" — is the fallback a
  # healthy read of an unconfigured file gives too (test 2), so a failure
  # here is invisible without a report.
  out="$(jq -nc --slurpfile c "$CONFIG_FILE" --arg a "$actor" --arg r "$repo" '
    ($c[0] // {}) as $cfg
    | (($cfg.repos // []) | map(select(.slug == $r)) | first // {}) as $repo_cfg
    | {
        backstop: (($repo_cfg.stage_timeouts // {})[$a] // $cfg["timeout_" + $a] // null),
        inactivity: (($repo_cfg.stage_inactivity // {})[$a] // $cfg["inactivity_" + $a] // null)
      }' 2>&1)" || { guard_warn "stage_budget_overrides" "$out"; out='{}'; }
  printf '%s' "$out"
}

# stage_budget_apply ACTOR REPO MODEL [EXTRA [ITEM]]
# Resolve this launch's two caps, announce them on the stage-start event, and
# leave them in `stage_backstop_min` / `stage_inactivity_min` for the launch.
#
# Announced rather than merely used: a self-tuning number that cannot be
# traced is a mystery number, and `stage-start` is where a reader looking at
# this stage will already be. The event carries where the value came from
# (`config`, `cell`, `pooled` or `prior`) and, when it came from the
# derivation, whether the cell had enough of its own evidence to speak for
# itself or is still sitting on the pooled estimate.
#
# ITEM (requirement 49, issue #595) is the item-lifecycle join key's other
# half — REPO already is one, once it names a real repository rather than the
# `*` a fleet-wide actor (the Enabler, the Refiner) passes for its own cell
# lookup. The two are independent: the Co-Ordinator passes a real repository
# (issue #1629 — each engagement has run for exactly one since the
# per-repository split, agent-ops#1560/#587) while still passing no ITEM at
# all, because it runs ahead of the selection that would name one. Both are
# omitted, never logged `null`, when there is none: `*` for REPO (a stage
# that runs across repositories has no one repo to name — see the
# enabler/refiner call sites' own comments) or an empty ITEM (every other
# caller passes `$selected_item`).
stage_budget_apply() {
  local actor="$1" repo="${2:-*}" model="${3:-*}" extra="${4:-{\}}" item="${5:-}" budget
  budget="$(stage_budget_resolve "$stage_budget_json" "$actor" "$repo" "$model" \
    "$(stage_budget_overrides "$actor" "$repo")")"
  # TD-PPagop-26081407: passes triage test 2 — a failure here yields empty
  # string, and the very next block treats anything that is not `^[0-9]+$`
  # (empty string included) as unresolved and recomputes it from
  # STAGE_BUDGET_PRIORS, so this fallback can never reach a caller unvetted.
  stage_backstop_min="$(jq -r '.backstop_min' <<<"$budget" 2>/dev/null || printf '')"
  stage_inactivity_min="$(jq -r '.inactivity_min' <<<"$budget" 2>/dev/null || printf '')"
  # A derivation that produced nothing readable must not stop a cycle: fall
  # back to the shipped prior for this actor, which is what a fresh
  # installation runs on anyway.
  [[ "$stage_backstop_min" =~ ^[0-9]+$ ]] \
    || stage_backstop_min="$(jq -nr --argjson p "$STAGE_BUDGET_PRIORS" --arg a "$actor" \
         '($p[$a] // $p.implementer).backstop')"
  [[ "$stage_inactivity_min" =~ ^[0-9]+$ ]] \
    || stage_inactivity_min="$(jq -nr --argjson p "$STAGE_BUDGET_PRIORS" --arg a "$actor" \
         '($p[$a] // $p.implementer).inactivity')"
  log_event "stage-start" "$(jq -nc --arg s "$actor" --arg m "$model" \
    --argjson e "$extra" --arg r "$repo" --arg i "$item" \
    --argjson b "$(jq -nc --argjson x "$budget" \
      --argjson bs "$stage_backstop_min" --argjson is "$stage_inactivity_min" \
      'if ($x | type) == "object" then $x else {} end
       + {backstop_min: $bs, inactivity_min: $is}')" \
    '{stage: $s, model: $m} + (if ($e | type) == "object" then $e else {} end) + $b
     + (if $r == "" or $r == "*" then {} else {repo: $r} end)
     + (if $i == "" then {} else {item: $i} end)')"
  # node-state (docs/FLOW-SCHEMA.md, D21): every stage-start is a transition,
  # producing only for the Implementer/Reviewer (node_state_for_stage).
  log_node_state_transition "$(node_state_for_stage "$actor")"
}
limit_cooldown_default_hours="$(cfg '.limit_cooldown_default')"
disable_default_ttl_hours="$(cfg '.disable_default_ttl')"
# How long an automatic fleet-wide stand-down may run before it is put in
# front of a human (requirement 2; #244). 0 turns the escalation off, the same
# convention as crash_loop_after. Manual stand-downs never escalate — the
# person who set one does not need to be paged about their own decision.
limit_escalate_after_hours="$(cfg '.limit_escalate_after_hours')"
[[ "$limit_escalate_after_hours" =~ ^[0-9]+$ ]] || limit_escalate_after_hours=24
# The GitHub API budget a cycle must find before it is worth starting one
# (requirement 2.0). Two floors because GitHub meters two pools separately and
# either can be the binding one — on 2026-08-12 the fleet exhausted `graphql`
# while `core` still had 96% of its hour left. Either set to 0 turns that
# resource's floor off; both at 0 turns the check off entirely.
github_min_core_budget="$(cfg '.github_min_core_budget')"
[[ "$github_min_core_budget" =~ ^[0-9]+$ ]] || github_min_core_budget=0
github_min_graphql_budget="$(cfg '.github_min_graphql_budget')"
[[ "$github_min_graphql_budget" =~ ^[0-9]+$ ]] || github_min_graphql_budget=0
# How long lib/github-limit.sh's `gh` wrapper may wait out a single refusal,
# and how long this whole process may spend waiting across all of them. Read
# here and exported so the gatherers and sweeps this cycle launches are
# governed by the installation's number rather than the library's default.
GITHUB_LIMIT_MAX_WAIT_SECONDS="$(cfg '.github_retry_max_wait_seconds')"
[[ "$GITHUB_LIMIT_MAX_WAIT_SECONDS" =~ ^[0-9]+$ ]] || GITHUB_LIMIT_MAX_WAIT_SECONDS=60
GITHUB_LIMIT_TOTAL_WAIT_SECONDS=$(( GITHUB_LIMIT_MAX_WAIT_SECONDS * 2 ))
export GITHUB_LIMIT_MAX_WAIT_SECONDS GITHUB_LIMIT_TOTAL_WAIT_SECONDS
# The free-space floor on workspace_root a cycle must clear before it is worth
# starting one (requirement 2.0c, agent-ops#756): a cycle that starts anyway
# clones into whatever room is actually left, and a clone or push truncated
# mid-write is what disabled `git gc` on the ockham laptop (#604) and left it
# 4.2 GB of orphaned clones (#605). `0` turns the check off.
min_free_workspace_bytes="$(cfg '.min_free_workspace_bytes')"
[[ "$min_free_workspace_bytes" =~ ^[0-9]+$ ]] || min_free_workspace_bytes=0
# The headroom the 2.0c threshold derives over the largest clone this fleet
# has actually measured (agent-ops#904, the residual of #756):
# `min_free_workspace_bytes` is the floor *under* `factor × largest recorded
# footprint`, never a ceiling — see lib/disk-space.sh's
# `disk_space_effective_min_bytes`. Non-numeric or absent reads as the
# schema's default of 2 rather than 0, so a misread here cannot silently
# turn the derivation off the way a real `0` legitimately can.
workspace_headroom_factor="$(cfg '.workspace_headroom_factor')"
[[ "$workspace_headroom_factor" =~ ^[0-9]+$ ]] || workspace_headroom_factor=2
# The free-memory floor the host must clear before a cycle is worth starting
# one (requirement 2.0f): a cycle runs a model stage whose working set the
# host has to hold alongside every other node sharing it, and on the ockham
# WSL2 laptop — 6 GiB, two nodes whose cycles overlap for most of every hour —
# starting into no headroom is what pushes the VM into a Windows-backed swap
# file and stalls the whole machine. `0` turns the check off.
min_free_memory_bytes="$(cfg '.min_free_memory_bytes')"
[[ "$min_free_memory_bytes" =~ ^[0-9]+$ ]] || min_free_memory_bytes=0
# Requirement 2.0g (agent-ops#757): whether the sum of every running
# container's own declared ceiling on this host — not only this project's
# three services, every container the host-facts collector's Docker socket
# sees — is allowed to overcommit the host, and the margin reserved for the
# host itself in each dimension when it is not. `host_budget_enforce` off
# (the default) leaves the check advisory: the sum is still published in
# the host-facts record, but nothing here stands the cycle down on it.
host_budget_enforce="$(cfg '.host_budget_enforce')"
[[ "$host_budget_enforce" == "true" ]] || host_budget_enforce="false"
host_budget_reserved_memory_bytes="$(cfg '.host_budget_reserved_memory_bytes')"
[[ "$host_budget_reserved_memory_bytes" =~ ^[0-9]+$ ]] || host_budget_reserved_memory_bytes=0
host_budget_reserved_cpus="$(cfg '.host_budget_reserved_cpus')"
[[ "$host_budget_reserved_cpus" =~ ^[0-9]+(\.[0-9]+)?$ ]] || host_budget_reserved_cpus=0
none_selected_recheck_hours="$(cfg '.none_selected_recheck_hours')"
candidates_max="$(cfg '.candidates_max')"
# Requirement 4i (agent-ops#641): the largest assembled prompt the Co-Ordinator
# may be handed. Non-numeric or absent reads as 0 — the bound off — because a
# misread here must not be able to trim a cycle's candidates to nothing, which
# is a worse failure than the overflow the bound exists to catch.
coordinator_prompt_max_bytes="$(cfg '.coordinator_prompt_max_bytes')"
[[ "$coordinator_prompt_max_bytes" =~ ^[0-9]+$ ]] || coordinator_prompt_max_bytes=0
max_chained_cycles="$(cfg '.max_chained_cycles')"
# How far apart this node's own cron firings are (requirement 39,
# agent-ops#1096): the width of the window a `roll-pending` marker needs to
# span so a healthy node that declines to chain on a pending image roll still
# gets watchtower a real gap to poll into, rather than the sub-second one a
# chained cycle's own lock hand-off leaves. Not derived from `cycle_hours`/
# `excluded_minutes` the way `lock_stale_after` and its siblings are
# (requirement 1d) — this bounds one cycle's own deferral, not a span of
# fleet history, and the plain interval is the right width for that.
cycle_interval_minutes="$(cfg '.schedule.cycle_interval_minutes')"
[[ "$cycle_interval_minutes" =~ ^[0-9]+$ ]] || cycle_interval_minutes=15
# The whole, already-defaulted `schedule` block (requirement 11a,
# agent-ops#1287): `cleanup`'s `schedule_overrun_slots` call reads
# `cycle_hours` and `excluded_minutes` from it as well, and resolving it once
# here — well before `acquire_lock` can ever set `lock_acquired=1` — is what
# lets that call read a plain global under this script's `set -u` rather than
# a value it would otherwise have to guard as possibly unset.
schedule_json="$(cfg_json '.schedule')"
# How long a draft PR this system raised may sit untouched before it counts as
# abandoned and finishing it becomes selectable work (requirement 3e). Comfortably
# beyond a whole cycle, so a draft merely being worked never qualifies.
abandoned_draft_after_hours="$(cfg '.abandoned_draft_after_hours')"
state_repo="$(cfg '.state_repo')"
all_repos_json="$(cfg_json '.repos')"
# The implementation-plan source has no path of its own in the prompt or the
# code (issue #77): a repo that lists it must say where its plan document
# lives. A repo that lists the source without configuring the path is a fatal
# misconfiguration, not a silent fallback — the Co-Ordinator would have
# nothing to read — so this fails the same way the enabler_assignee guard
# above does: at startup, before any stage runs. This rule holds *between*
# `sources` and `implementation_plan_path`, which is outside what the schema
# gate above can state about either key alone, so it stays here — shared with
# `scripts/doctor.sh` via `config_missing_plan_path_repos` (requirement 1b).
missing_plan_path="$(config_missing_plan_path_repos "$all_repos_json")"
if [[ -n "$missing_plan_path" ]]; then
  echo "agent-cycle: repo(s) [$missing_plan_path] list the implementation-plan source but have no implementation_plan_path configured — set it in config.json's repos entry or drop the source" >&2
  exit 1
fi

# Per-installation prompt overrides (requirement 4a, lib/prompt-overrides.sh):
# config-pointed files, outside prompts/*.md, appended to (or, for `replace`,
# substituted for) a stage's shipped prompt. Absent entirely, every stage
# assembles byte-identical to today. Its shape is enforced by the schema gate
# above; what remains tolerated here is a *runtime* fault only — a
# well-formed entry whose file is unreadable this cycle stays tolerated in the
# lib, since files legitimately come and go, and an unreadable one still
# moves the fingerprint, where a structural typo would not have.
prompt_overrides_json="$(cfg_json '.prompt_overrides')"

mkdir -p "$state_dir" "$state_dir/cycles" "$workspace_root"
log_file="$state_dir/log.jsonl"
lock_file="$state_dir/lock.json"
review_lock_file="$state_dir/review-lock.json"

# The node's name travels in the cycle id and in every event this cycle
# writes: once several nodes run at once, a record that does not say which
# machine produced it cannot be combined with its peers'. Sanitised because
# the id is also a directory name; the pid stays LAST — the dashboard finds
# the running cycle by its "-<pid>" suffix.
node_name="${NODE_NAME:-$(hostname)}"
node_name="${node_name//[^A-Za-z0-9._-]/-}"
cycle_id="$(date -u +%Y%m%dT%H%M%SZ)-$node_name-$$"
# The same instant in the format GitHub's own API returns, so it can be
# compared against a timeline event's `created_at` without reformatting. It is
# the bound `handoff_complete_review` hands `reconciliation_gate` (requirement
# 31c, agent-ops#533): "when this pull request last left draft" has to mean
# "as this round found it", and every draft flip this cycle performs — the
# Reviewer's own `gh pr ready` at its step 7, most of all — happens after this
# line. The cycle id's own leading token is the same instant, but in a
# different format and welded to the node name and pid, so it is minted
# separately rather than parsed back out.
cycle_started_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cycle_dir="$state_dir/cycles/$cycle_id"
# A management command runs no stages and writes no transcripts; giving it a
# cycle directory would leave an empty one behind for every --status anyone
# ever ran.
[[ -n "$MANAGE_ACTION" ]] || mkdir -p "$cycle_dir"

# What a dead process left in the container's writable layer — a Publisher's
# working set from a publish the OOM killer or a container stop ended, a
# cycle's own scratch directory from a stale-lock takeover's KILL,
# lib/toggle.sh's memos under a pid no longer alive (lib/scratch.sh,
# agent-ops#1827). The launcher sweeps the same directory at the start of
# every window, on every node whatever its role; this sweep runs before this
# cycle's own free-space gate (requirement 2.0c) reads the disk, so what it
# reclaims counts. Skipped by a management command for the same reason the
# cycle directory above is, since it runs no cycle.
if [[ -z "$MANAGE_ACTION" ]]; then
  # shellcheck disable=SC2119  # the default — the base this cycle's own scratch directory was made in — is the one wanted here
  swept_scratch="$(scratch_sweep_dead_owners)"
  if [[ "$swept_scratch" =~ ^[0-9]+$ ]] && (( swept_scratch > 0 )); then
    echo "agent-cycle: removed $swept_scratch scratch director(ies) left by dead processes in ${SCRATCH_BASE:-${TMPDIR:-/tmp}}" >&2
  fi
fi

# --- Logging ---
# The envelope logic (the FIELDS contract, issue #361/#458) lives in
# lib/log-event.sh's log_event_append, shared with review-cycle.sh; `cycle`
# is this pipeline's own id field.
log_event() { log_event_append "$log_file" cycle "$cycle_id" "$node_name" "$@"; }

# Requirement 1c's warn spelling (agent-ops#924's decision on
# TD-PPagop-26082704/agent-ops#1003), computed above and carried forward to
# here because logging was not yet initialised at that point in the script.
# Emitted on every cycle the condition holds, never once, so it cannot age out
# of the dashboard's window the way a once-only warning would.
#
# Gated on MANAGE_ACTION for the same reason the cycle directory just above
# is: a management command runs no cycle, and every event it wrote would land
# under a cycle id that has no `cycle-start`, no `cycle-end` and no transcript
# directory — the shape scripts/publish-dashboard.sh renders as a cycle that
# began and can never end, holding a MAX_CYCLES slot for good. `--status` is
# the command an operator is told to poll (README's drain and stand-down
# sections), so this would be an unbounded row source, not a rare one.
if [[ -z "$MANAGE_ACTION" && -n "$refinement_paused_sources" ]]; then
  log_event "warning" "$(jq -nc \
    --arg d "refinement_policy requires [$refinement_paused_sources] but refiner_max_per_engagement is $refiner_max_per_engagement — refiner_engagement_set slices every engagement's candidates to none, so nothing is ever refined; these sources' unrefined items wait, unlabelled, until the cap is raised above 0" \
    --argjson cap "$refiner_max_per_engagement" \
    --argjson sources "$(jq -Rc 'split(", ")' <<<"$refinement_paused_sources")" \
    '{detail: $d, refiner_max_per_engagement: $cap, sources: $sources}')"
fi

# void_obsolete_ctx_json REPO_SLUG [FLAGS_JSON]
# What every `void_guard_reason` call site (the Co-Ordinator, the Enabler, the
# Implementer) hands it as CTX_JSON, so the machine `obsolete` alternative
# (design doc §5.5, issue #413, WI-10) has what it needs without lib/void-
# guard.sh ever touching config, the kill switch, or the log itself — that
# file stays self-contained and stubbable with `gh` alone, exactly as its own
# tests rely on.
#
# FLAGS_JSON is optional: a caller that already holds the current
# `draft_obsolete_flags` result — `log_voided_items` below computes it once
# per invocation and hands it to every entry in its loop — passes it straight
# through, skipping the two full union-log `jq` scans a fresh call would
# otherwise pay per entry. Every other call site is single-shot per cycle
# (issue #508) and omits it, letting this function compute it itself exactly
# as it always has.
#
# `${union_log:-$log_file}` rather than `$union_log` outright: this is called
# from functions the Script may invoke before the fleet-wide union log is
# built partway through a cycle (`union_log="$cycle_dir/.fleet-log.jsonl"`,
# set once, well after this function is first defined) — falling back to this
# node's own local log costs only *this node's* peers' flags being briefly
# invisible to a void decided that early, never a crash under `set -u`. A
# `draft-obsolete-flagged` event is a fact, never retracted (lib/cycle-
# state.sh's `draft_obsolete_flags`), so a flag missed this way is not lost —
# it is simply not yet in whichever log this call happened to read. The same
# reasoning is why the level read below is never hoisted alongside it, even
# for the looped caller: it gates the *permissive* machine-`obsolete` path, so
# it stays live, per entry (verdict recorded on #501; do not revisit without a
# human decision).
void_obsolete_ctx_json() {
  local slug="$1" flags_json="${2:-}" level
  level="$(merge_autonomy_effective_level "$DEFAULTED_CONFIG" "$slug" "$state_repo" "$state_dir" 2>/dev/null || true)"
  [[ -n "$flags_json" ]] || flags_json="$(draft_obsolete_flags "${union_log:-$log_file}")"
  jq -nc --arg lvl "$level" --arg cycle "$cycle_id" --argjson now "$(date -u +%s)" --argjson flags "$flags_json" \
    '{merge_autonomy_level: $lvl, cycle: $cycle, now_epoch: $now, flags: $flags}'
}

# TD-PPagop-26081407: a guarded call site (`cmd 2>&1) || { guard_warn ...;
# var=fallback; }`) that falls back to a literal on failure without saying so
# is indistinguishable from a genuinely empty/zero answer downstream — the
# defect the union log's `guard-degraded` event exists to remove. Every
# converted site captures the failed command's own stdout+stderr (its `2>&1`
# replaces the old `2>/dev/null`) and passes it here as `detail`; the fallback
# itself is never touched, only reported. Kept to one line per call site on
# purpose — 67 near-identical `jq -nc '{...}'` wrappers would be their own
# noise.
#
# The report is bounded on both axes, because its destination is the
# fleet-replicated union log — the unbounded input requirements 4c and 4g
# exist because of. A guard that fails *persistently* (a `date` parse of a
# field that is simply always absent, a `gh` outage across the repo loop)
# would otherwise write one event per occurrence per cycle per node: the
# first GUARD_WARN_SITE_MAX occurrences of each site label are reported, the
# last of them marked `final` so a reader knows the site may have kept
# failing unreported, and `detail` — a failed command's own output, which for
# a `gh api` body has no bound at all — is capped to its leading 500 bytes,
# where the cause is. A site label carrying a loop variable
# (`claim-count:<slug>`) still reports per slug; the cap is on repeats of one
# label, not on distinct sites. The tally is a shell variable, so a guard
# raised inside a command substitution counts only within it — those sites
# report unbounded within one cycle as before, which is the conservative
# direction to fail in for a cap whose only job is to stop noise.
#
# On a management command the report goes to stderr instead. --status runs
# before the lock and deliberately creates no cycle directory (see the
# comment above `mkdir -p "$cycle_dir"`) so that a read-only query leaves
# nothing behind; its `cycle_id` names a cycle that never ran, and stamping
# the fleet's shared log with one would be a record of a failed read during
# somebody's query, not of pipeline state. --disable/--enable do write to the
# log from this path, but they record a state change a human asked for.
# Nothing is lost: every fleet-state read a management command guards is read
# again by real cycles, which report it under a cycle id that resolves — and
# stderr is where the human who typed the command is already looking.
guard_warn() {  # guard_warn <site-label> <captured-stdout+stderr>
  local max="${GUARD_WARN_SITE_MAX:-3}" n detail="${2:0:500}"
  # `declare -p`, not `${guard_warn_counts+x}`: the latter tests element 0, so
  # an associative array that exists but is still empty reads as unset and the
  # tally would reset on every call.
  declare -p guard_warn_counts >/dev/null 2>&1 || declare -gA guard_warn_counts=()
  n=$(( ${guard_warn_counts["$1"]:-0} + 1 ))
  guard_warn_counts["$1"]=$n
  (( n <= max )) || return 0
  if [[ -n "${MANAGE_ACTION:-}" ]]; then
    printf 'agent-cycle: guard-degraded: %s: %s\n' "$1" "$detail" >&2
    return 0
  fi
  log_event "guard-degraded" "$(jq -nc --arg s "$1" --arg d "$detail" \
    --argjson n "$n" --argjson m "$max" \
    '{site: $s, detail: $d, n: $n} + (if $n >= $m then {final: true} else {} end)')"
}

# --- Management commands (--disable / --enable / --status) ---
# Handled here, before the lock and before any `gh` call: they change no
# pipeline state that the lock protects, and `--status` must stay usable — and
# instant — while a cycle holds the lock, since "is one running right now?" is
# the question it is most often asked. `lib/manage.sh` (#771) carries the
# whole of it — the five report helpers and the action handling — and returns
# at once when no management action was asked for; every action it does handle
# exits the process, so nothing below here is reachable from one.
run_manage_command

# The repo and item this cycle selected, once the Co-Ordinator has picked one.
# Requirement 33 puts `repo`/`item` on an event where applicable, and the
# requirement 34 blocked extract groups attempt-failed events by repo+item — so
# an event raised after selection that omits them can never block the item it
# failed on, and the same item is free to be re-selected next cycle.
selected_repo=""
selected_item=""
selected_source=""
# The branch this cycle claimed, alongside them because it answers a question
# the other two cannot: *which pull request is this*. The Script computed it
# and pushed it before any stage ran (requirement 17a), so it is the one handle
# on a stranded attempt that survives a stage contributing nothing — which is
# what requirement 9's last fallback is built on.
selected_branch=""

# This one function backs both a genuine stage-attempt failure (a crash, a
# timeout, a SIGTERM) and a stage's own truthful verdict that the *item* it
# was handed is blocked or void (the Implementer's `void refused`/`blocked`
# reports below, `log_reviewer_handback` in lib/review-gate.sh) — both are
# `attempt-failed` against repo+item (requirement 34), but only the former is
# a stage failure for lib/stage-health.sh's own purposes (issue #1511): a
# caller reporting the latter must not add `stage_failure: true` to `extra`,
# and every caller that does — the SIGTERM handler below, and
# lib/stage-attempt.sh's `handle_stage_failure` — is a real crash, never an
# item verdict a stage reached by running to completion.
log_attempt_failed() {
  local stage="$1" detail="$2" extra="${3:-{\}}"
  log_event "attempt-failed" \
    "$(item_event_fields "$stage" "$detail" "$selected_repo" "$selected_item" "$extra")"
}

# --- The claim this cycle holds (requirement 17a) ---
# Set by the claim loop after selection; released on every path that ends the
# cycle without an open PR. "have-pr" keeps the branch (the PR supersedes the
# claim — its head must survive) and drops only the registry entry; "no-pr"
# releases fully, and lib/claim.sh deletes a claim branch only if it is
# exactly where the claim left it — pushed work is never deleted.
claim_active=0
claim_kind=""
claim_key=""
# The second, PR-keyed file claim (issue #238) a finishing-source win also
# holds — empty for every other source, and for a finishing source whose PR
# number neither its candidate nor its item ref yielded. Always a `file` claim
# (there is no PR-keyed branch), so its release never touches a ref. Tracked
# independently of claim_active (below): the item-keyed claim and this one are
# released on different schedules (issue #360), so a flag that zeroed both at
# once could not represent "item claim gone, PR-keyed claim still held".
claim_pr_key=""

# Zero means unbounded (GNU timeout treats a duration of 0 as "no timeout"),
# which is every ordinary release. The signal handler (requirement 9c) and
# cleanup's backstop release set a small bound instead: the handler runs on
# borrowed time — a lock takeover KILLs what has not exited within its grace —
# and the EXIT trap carries the cycle's record, so in both a release the
# network stalls must not cost the exit record. A claim the release never
# reached is retired by the gc within `claim_ttl_hours` anyway.
claim_release_timeout=0

# --- The Enabler's state for this cycle (requirements 35, 37) ---
# All three are read from the exit trap, so they are initialised here — before
# anything can exit — and only ever move in the safe direction. `enabler_allowed`
# is set once the gatherers have finished, so no early exit (a standby node, the
# switch, a usage-limit cooldown, a lost lock) can engage a stage on inputs it
# never computed.
enabler_allowed=0
enabler_eligible_json='[]'
# The Refiner's own state (requirement 39), same reasoning and same guard.
refiner_allowed=0
refiner_candidates_json='[]'
limit_hit_this_cycle=0

# `landing_armed_by_repo` (PR #557 review round 2 of TD-PPagop-26081701) is
# this cycle's own running tally of how many pull requests each repository
# has already been armed for so far, keyed by slug because
# `merge_budget_decide`'s cap is per repository. Shared by the two call
# sites of `_landing_stage_attempt` that can both run in one cycle process —
# the 2.1e landing-retry sweep (`_landing_retry_sweep_repo`, below) and this
# round's own arming step (`run_landing_stage`, gate 0) — so a live
# `merge_budget_decide` read at either one discounts arms the other already
# made this same cycle, not only its own. Declared here, ahead of both, so
# neither reads an unset array under `set -u`; only ever grows within a
# cycle, and this process exits before the next one, so it needs no reset.
declare -A landing_armed_by_repo=()

# --- Cleanup (always runs on exit) ---
lock_acquired=0
clone_dir=""
# Finish-then-continue (requirement 39): set true only once this cycle has
# won a claim and is about to run the Implementer. Initialised here, ahead
# of the trap, for the same reason lock_acquired is: a cycle that stands
# down or fails before ever reaching that point still runs cleanup, and an
# unset variable read under `set -u` inside a trap would abort it part-way.
#
# chain_count is this cycle's own place in its lineage, 1 for the cron-fired
# original — AGENT_CYCLE_CHAIN_COUNT is how a chained child learns it is not
# the original; garbage or absent both mean "the original".
chain_eligible=0
chain_count="${AGENT_CYCLE_CHAIN_COUNT:-1}"
[[ "$chain_count" =~ ^[0-9]+$ && "$chain_count" -ge 1 ]] || chain_count=1
cleanup() {
  local exit_code=$?
  # A signal landing mid-cleanup must not re-enter the handler over a cycle
  # that is already writing its record (requirement 9c).
  trap '' TERM INT HUP
  # The PR-keyed claim's backstop (issue #360). Every handled ending has
  # already released it by the time this trap runs — the terminal handoff, a
  # handback, a stage failure, a signal — and then this is a no-op on an
  # empty claim_pr_key. What it catches is the one ending no handler sees:
  # an unhandled errexit abort between `pr-raised` and the Reviewer's
  # terminal path, which would otherwise strand `claims/<repo>/pr-<n>.json`
  # until the gc's `claim_ttl_hours` — hours in which the PR this cycle
  # abandoned mid-Reviewer, the very PR that just lost its Reviewer and most
  # needs picking up, is invisible to every peer's finishing sources.
  # Time-bounded like the signal handler's release and for the same reason:
  # this trap carries `cycle-end`, the lock release and the clone deletion,
  # and a release the network stalls must not cost the record.
  claim_release_timeout=8
  release_pr_claim
  if [[ -n "$clone_dir" && -d "$clone_dir" ]]; then
    rm -rf "$clone_dir"
  fi
  # The Enabler (requirement 35): here, and only here. This is the one place
  # every ending of a cycle passes through — nine of them exit 0 — so a single
  # call site covers them all, where calls at each exit point would be nine
  # chances to forget one. It runs after the workspace is deleted (it needs no
  # clone) and before `cycle-end`, so its events belong to the cycle that
  # produced them and travel on the state-sync push below. Contained by
  # requirement 37: whatever happens inside, this cycle's exit code is the one
  # computed above.
  maybe_run_enabler "$exit_code" || true
  # The Refiner (requirement 39): same one call site, same reasoning, run
  # after the Enabler so a fleet-limit hit the Enabler's own engagement
  # triggers this cycle is still visible to the live check below.
  maybe_run_refiner "$exit_code" || true
  # Deferred crash-loop escalations (requirement 2.7, agent-ops#1074): after
  # the Enabler and the Refiner, same reasoning as both — and after every
  # stage this cycle might have run, coordinator included, which is the
  # whole point: `crash_loop_refile_pending` re-gathers the union log fresh
  # here, so a Co-Ordinator success this very cycle logged already shows.
  crash_loop_refile_pending || true
  # lib/issue-priority.sh's own cache directory (issue #510): removed here,
  # after the Refiner, since the Refiner's own priority-triage duty is that
  # cache's main consumer.
  issue_priority_cache_cleanup
  # The fleet-log snapshot (`union_log`) goes with it (agent-ops#1826). It is
  # scratch with this cycle's lifetime (requirement 2.5): read only through
  # that variable and only by this process, whose last readers — the Enabler,
  # the Refiner and the deferred crash-loop refile — have all just run, and
  # nothing below reads it (the state-sync push and the dashboard build
  # their own). It is the whole fleet's history to this moment, tens of
  # megabytes and growing with that history, so it is removed by the cycle
  # that wrote it rather than counted out later by
  # `state_local_streams_retained`, which bounds how many snapshots are kept
  # and never how large they are; the stage streams beside it stay for that
  # prune, and so does the snapshot of a cycle killed before this line.
  # Guarded because a cycle can end before the snapshot is taken.
  [[ -z "${union_log:-}" ]] || rm -f -- "$union_log" || true
  # The closing GitHub budget reading (requirement 2.0d): after the Enabler
  # and the Refiner so their own calls fall inside it, before `cycle-end` so
  # it travels with this cycle. Only for a cycle that took the opening
  # reading — an ending that never read GitHub (the switch, requirement 2.3)
  # must not start now. Two points; never fatal.
  if [[ "${GITHUB_BUDGET_CYCLE_OPEN:-0}" == "1" ]]; then
    github_budget_record cycle-end || true
  fi
  # node-state (docs/FLOW-SCHEMA.md, D21): the state this node settles into
  # once this process exits, logged last of all — after maybe_run_enabler/
  # maybe_run_refiner above, whose own stage-start/stage-end pairs are real
  # overhead that must land on the timeline before this cycle's own idle/
  # down/externally-blocked verdict does (see set_node_state_terminal's
  # header for why logging it earlier, at the stand-down site itself, would
  # let a later Enabler engagement silently overwrite it).
  finalize_node_state_for_cycle
  # Overrun-slot skips (requirement 11a, agent-ops#1287): schedule slots that
  # fell inside this cycle's own run, which supercronic silently dropped
  # because this cycle was still holding the lock at each of them. Only the
  # lock holder can ever know this happened — the process supercronic would
  # have started for one of these firings never starts at all, so nothing
  # else ever gets the chance to log it — and only a cycle that actually
  # acquired the lock can have blocked one. Before `cycle-end`, with the lock
  # still held, on the same terms as the Enabler/Refiner engagement above, so
  # these events belong to the cycle that produced them and travel on the
  # same end-of-cycle state-sync push.
  #
  # These are ordinary `cycle-skipped` events, like requirement 1's own
  # lock-contention case, but — unlike that case — never call
  # suppress_node_state_transitions: the seconds they describe already
  # belong to this cycle's own node-state timeline, finalized immediately
  # above, not seconds of their own to account for separately.
  #
  # Holding the lock is necessary but not sufficient: this must also be the
  # cron-fired original, because only that cycle *is* supercronic's running
  # job. A chained continuation (requirement 39) is spawned detached and
  # disowned below and the cron-fired parent then exits, so supercronic's job
  # has already ended by the time the chained cycle runs: its slots are not
  # dropped at all — they fire, contend for the lock, and are already recorded
  # by the contending tick as requirement 1's own `reason`-less
  # `cycle-skipped`. Logging them again here would double-count them, and at a
  # fabricated `slot_ts` besides: a chained cycle starts whenever its
  # predecessor happened to finish, an arbitrary minute-of-hour, which
  # `schedule_overrun_slots` would take as the node's base minute (see its
  # header). `--once` and `--dry-run` runs have exactly that shape too — the
  # manual run is not supercronic's job, so its firings land and contend as
  # normal. The one case left ungated is a human running this script with
  # neither flag; distinguishing that from the cron firing needs machinery
  # this is not worth (agent-ops#1301).
  if [[ "$lock_acquired" == "1" ]] && (( chain_count == 1 )) && ! (( ONCE || DRY_RUN )); then
    local overrun_now_iso overrun_now_epoch overrun_start_epoch overrun_slot overrun_slot_epoch
    overrun_now_iso="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    overrun_now_epoch="$(date -u +%s)"
    overrun_start_epoch="$(date -u -d "$cycle_started_at" +%s 2>/dev/null || echo "$overrun_now_epoch")"
    while IFS= read -r overrun_slot; do
      [[ -n "$overrun_slot" ]] || continue
      overrun_slot_epoch="$(date -u -d "$overrun_slot" +%s 2>/dev/null || echo "$overrun_now_epoch")"
      log_event "cycle-skipped" "$(jq -nc --arg r "overlap" --arg s "$overrun_slot" \
        --arg h "$cycle_id" --argjson e "$(( overrun_slot_epoch - overrun_start_epoch ))" \
        '{reason: $r, slot_ts: $s, held_by: $h, elapsed_s: $e}')"
    done < <(schedule_overrun_slots "$cycle_started_at" "$overrun_now_iso" "$schedule_json")
  fi
  log_event "cycle-end" "$(jq -nc --argjson rc "$exit_code" '{exit_code: $rc}')"
  if [[ "$lock_acquired" == "1" ]]; then
    rm -f "$lock_file"
  fi
  # Per-stage health snapshot (issue #662, lib/stage-health.sh): recomputed
  # from this node's own $log_file — which already carries every stage-end
  # and attempt-failed event this cycle logged — and written before the
  # state-sync push below, so that push's own heartbeat (requirement 2.5)
  # carries this cycle's fresh verdict rather than the previous one's.
  # Best-effort like the dashboard refresh beside it: never affects this
  # cycle's own exit code.
  stage_health_write_status "$state_dir" "$log_file" || true
  # Publish this node's state to the fleet (requirement 2.5) — its own
  # `nodes/<NODE_NAME>` branch, so there is nothing another node's push could
  # overwrite and nothing to gate. Here at the end so the cycle's record is
  # complete once `cycle-end` is logged; the every-few-minutes crontab push
  # keeps the heartbeat fresh in between. Isolated like the dashboard refresh
  # below: a sync failure is a replication problem, never a cycle outcome.
  timeout 300 "$SCRIPT_DIR/scripts/state-sync.sh" push || true
  # Refresh the local monitoring dashboard. Fully isolated: a failure or a slow
  # gh call here must never affect the cycle's outcome or exit code.
  if [[ -x "$SCRIPT_DIR/scripts/publish-dashboard.sh" ]]; then
    timeout -k 10 120 "$SCRIPT_DIR/scripts/publish-dashboard.sh" >/dev/null 2>&1 || true
  fi
  # This cycle's scratch directory (lib/scratch.sh) goes here: after the
  # state-sync push and the hook publish above, which made their own inside
  # it, and before the chained cycle below is spawned, so that child inherits
  # the TMPDIR this process was given rather than a directory that no longer
  # exists. Nothing between spools anything.
  scratch_release
  # Yield to a pending image roll (requirement 39, agent-ops#1096, widened by
  # agent-ops#1103): a node running long or chained cycles never presents
  # watchtower's deploy/docker/watchtower-pre-update.sh a gap to poll into,
  # so a healthy, merely-busy node could stay behind the registry's newest
  # image indefinitely — the bound `lock_stale_after` gives a wedged cycle
  # never applied to one that is simply busy. This has two separable jobs:
  # cancelling a chain this cycle would otherwise take (nothing to cancel on
  # a cycle that was never going to chain), and widening the gap itself from
  # whatever instant this cycle's own lock release happens to leave to a
  # window the five-minute poll is guaranteed to land in (needed at every
  # clean cycle-end, chain or no chain). So the marker is written whenever
  # this cycle ended cleanly, whether or not it had a chain to give up —
  # `chain_eligible` only gates the cancellation, which is a no-op where
  # there was nothing eligible to begin with. `--once` is excluded outright:
  # a human or a test asking for exactly one cycle must not arm an override
  # on the node it ran on. Reads the same `image_drift_status` verdict the
  # heartbeat's `image` field publishes (requirement 2.5) — no second signal
  # — through the identical cache file the state-sync push just above
  # refreshed, so this costs no second registry round trip.
  if (( exit_code == 0 )) && ! (( ONCE )); then
    local image_status_json=""
    image_status_json="$(image_drift_status "$(agent_ops_version "$SCRIPT_DIR")" \
      "$state_dir/.image-drift-cache.json" 2>/dev/null || echo null)"
    if chain_image_behind "$image_status_json"; then
      chain_eligible=0
      chain_write_roll_pending "$state_dir" "$cycle_interval_minutes"
      log_event "roll-pending" "$(jq -nc --argjson image "$image_status_json" \
        --argjson minutes "$cycle_interval_minutes" \
        '{image: $image, minutes: $minutes}')"
    fi
  fi
  # Finish-then-continue (requirement 39), last of all: a chained cycle is a
  # brand-new process with its own cycle id, its own lock acquisition and its
  # own full cleanup, so it must not start until this one has released
  # everything above — the lock first of all, or it would just log
  # `cycle-skipped` and exit. Gated on `exit_code == 0` too: `chain_eligible`
  # is decided in the claim section (requirement 17a) — at a won claim, or at
  # a raced stand-down whose fresh look is the whole point (requirement 39) —
  # and nothing past that point may turn a real success into a chain off of a
  # genuine failure. Detached
  # with input from /dev/null and both streams appended to the same cron.log
  # a cron-fired cycle already writes to, then disowned: this process is
  # about to exit, and nothing here should wait for — or die with — the
  # child.
  #
  # Spawned through a subshell that restores the default dispositions first,
  # which is not decoration: an *ignored* signal is inherited across both fork
  # and exec, and a shell that starts with a signal already ignored can never
  # take it back — `trap ... TERM` in the child is silently a no-op for the
  # rest of its life. The `trap '' TERM INT HUP` at the top of this function
  # is exactly such an ignore, so a child forked from here would run the whole
  # of the next cycle deaf to every signal requirement 9c's handler exists to
  # catch, and requirement 1's stale-lock takeover would find its TERM ignored
  # and reach the item only through the KILL that follows — no `attempt-failed`,
  # no `cycle-end`, no claim released. EXIT is reset alongside them so a failed
  # `exec` cannot re-enter this same handler in the subshell.
  if (( chain_eligible )) && (( exit_code == 0 )); then
    log_event "chained" "$(jq -nc --argjson n "$(( chain_count + 1 ))" --argjson m "$max_chained_cycles" \
      '{depth: $n, max_chained_cycles: $m}')"
    (
      trap - TERM INT HUP EXIT
      AGENT_CYCLE_CHAIN_COUNT=$(( chain_count + 1 )) exec "$SCRIPT_DIR/agent-cycle.sh" "${ORIGINAL_ARGV[@]}"
    ) </dev/null >>"$state_dir/cron.log" 2>&1 &
    disown 2>/dev/null || true
  fi
  exit "$exit_code"
}
trap cleanup EXIT

# --- Signals (requirement 9c) ---
# The kills that reach this script are real and routine: a peer taking over a
# stale lock TERMs this cycle's whole process group (requirement 1), an
# operator stops a container, a `--once` run is interrupted at the terminal.
# Untrapped, any of them ends bash between one statement and the next: no
# `attempt-failed`, no `cycle-end`, no claim release, no PR comment — and the
# stage's own process group, which `set -m` detached from ours precisely so a
# timeout could kill it whole, is beyond every one of those signals, so the
# model runs on for work whose cycle is already dead.
#
# The handler's order is its design. The stage is stopped first, with KILL
# rather than TERM: the signaller's patience is unknown and may be two
# seconds, and a stage whose cycle is dead has nothing left to negotiate.
# The event lands second — one local file append, the thing that must
# survive, and what makes the death visible to requirement 34's blocked
# extract instead of silent. The claim release runs last and time-bounded
# (see `claim_release_timeout`): releasing now beats waiting out the gc's
# `claim_ttl_hours`, but not at the price of the record. Exiting through
# `exit` hands 128+n to the EXIT trap, so `cycle-end` reports the truth and
# `maybe_run_enabler`'s cycle_rc guard skips the Enabler unasked.
#
# `stage_pid`/`stage_name` are advertised by `run_claude_stage` while a stage
# is in flight and empty otherwise, so the handler never blames a stage that
# had already ended cleanly.
stage_pid=""
stage_name=""
on_signal() {  # on_signal NAME NUM
  local name="$1" num="$2" pr_url="" actor
  trap '' TERM INT HUP
  if [[ -n "$stage_pid" ]] && kill -0 "$stage_pid" 2>/dev/null; then
    kill -KILL "-$stage_pid" 2>/dev/null || true
  fi
  # A stranded Implementer may have opened its draft PR without ever
  # reporting it; the breadcrumb is the same fallback requirement 9 gives the
  # ordinary failure path, and it must be read before the EXIT trap deletes
  # the clone it lives in.
  #
  # The breadcrumb and nothing else: `pr_url_for_branch`, requirement 9's more
  # reliable fallback, is a network call, and this handler runs on borrowed
  # time — the peer that TERMed us KILLs what has not exited within its grace,
  # which may be two seconds. The event below is the thing that must survive,
  # and a stalled API call ahead of it would trade the record for the URL. A
  # local file read cannot stall; that is the whole reason this line is the
  # one that stayed.
  if [[ -n "$clone_dir" ]]; then
    pr_url="$(read_pr_url_breadcrumb "$clone_dir")"
  fi
  actor="${stage_name:-cycle}"
  log_attempt_failed "$actor" "$actor terminated by SIG$name" \
    "$(jq -nc --arg u "$pr_url" '{stage_failure: true} + (if $u == "" then {} else {pr_url: $u} end)')"
  claim_release_timeout=8
  if [[ -n "$pr_url" ]]; then
    release_claim have-pr
  else
    release_claim no-pr
  fi
  exit "$(( 128 + num ))"
}
trap 'on_signal TERM 15' TERM
trap 'on_signal INT 2'  INT
trap 'on_signal HUP 1'  HUP

# --- Workspace safety assertion (requirement 6) ---
assert_in_workspace() {
  local dir="$1"
  case "$dir" in
    "$workspace_root"/*) return 0 ;;
    *)
      echo "agent-cycle: refusing to launch a stage outside workspace_root: $dir" >&2
      exit 1
      ;;
  esac
}

log_event "cycle-start" "$(jq -nc --argjson once "$([[ $ONCE == 1 ]] && echo true || echo false)" \
  --argjson dry_run "$([[ $DRY_RUN == 1 ]] && echo true || echo false)" '{once: $once, dry_run: $dry_run}')"

# --- 0. The switch (requirement 2.3) ---
# Checked before the lock and before any `gh` call, because a disabled pipeline
# should cost nothing at all — and because taking a lock a disabled cycle will
# immediately drop only widens the window in which a real cycle sees it held.
#
# An expired switch is cleared here rather than ignored, and the clearing is
# logged: cycles resuming is a state change, and an operator should be able to
# find out from the log why they resumed without knowing to look for a file
# that is, by then, gone. Deliberately not gated on --once or --dry-run — the
# switch means "these files are being edited, do not run them", which is no
# less true when a human is the one running them.
#
# A `mode: "drain"` record does not exit here (requirement 2.3d/2.9): unlike a
# full stop it means "finish what is open, refuse only new work", so the
# cycle keeps going and `DRAINING`/`DRAIN_DISABLED_AT` below carry that
# decision to the 2.2a-adjacent narrowing further down, the one site that
# actually restricts what gets picked up. A `mode: "stop"` record — the only
# kind before this field existed, and every plain `--disable` since — is
# unchanged: exit immediately, before the lock, before any `gh` call.
DRAINING=0
DRAIN_DISABLED_AT=""
switch_state="$(toggle_state "$state_dir")"
case "$(jq -r '.state' <<<"$switch_state")" in
  expired)
    expired_record="$(jq -c '.record' <<<"$switch_state")"
    toggle_clear "$state_dir" >/dev/null
    log_event "enabled" "$(jq -nc --argjson r "$expired_record" \
      '{detail: "disable expired", was: $r, scope: "node"}')"
    notify_post_cycle "fleet-standdown-end" "standdown:node-switch:$node_name" \
      "Node disable expired" "" "" "disable expired"
    ;;
  disabled)
    switch_record="$(jq -c '.record' <<<"$switch_state")"
    if [[ "$(toggle_mode "$switch_record")" == "drain" ]]; then
      DRAINING=1
      DRAIN_DISABLED_AT="$(jq -r '.disabled_at // ""' <<<"$switch_record")"
    else
      log_event "stand-down" "$(jq -nc \
        --arg r "disabled: $(toggle_describe "$switch_record")" \
        '{reason: $r, cause: "disabled-node"}')"
      notify_post_cycle "fleet-standdown-begin" "standdown:node-switch:$node_name" \
        "Node disabled" "" "" "disabled: $(toggle_describe "$switch_record")"
      set_node_state_terminal down disabled-node
      (( ONCE )) && echo "agent-cycle: the pipeline is disabled — run --status for detail, --enable to resume" >&2
      exit 0
    fi
    ;;
esac

# --- 0a. The fleet switch (requirement 2.3a) ---
# The same switch, one level up: fleet/disabled.json on the state repository's
# main. Local first because it is free; this one costs a single contents read
# — still before the lock, still before anything that spends. Absent means
# enabled; unreachable falls back to the last fetched copy, and to enabled
# with none — safe, because a node that charges ahead blind meets per-item
# claims that fail closed (requirement 17a).
#
# An expired fleet disable is cleared by whichever node sees it first: the
# delete is sha-guarded and idempotent, so a lost race just means a peer got
# there — there is no singleton chore here (requirement 2.5).
fleet_switch_state="$(fleet_disabled_state "$state_repo" "$state_dir")"
case "$(jq -r '.state' <<<"$fleet_switch_state")" in
  expired)
    # fleet_flag_delete's own outcome used to be discarded (`|| true`) — this
    # fleet-level expiry could win the delete, lose it to a peer's own race
    # (fine, requirement 2.5), or fail outright, and the log could not tell
    # those apart (issue #426). fleet_flag_delete_outcome folds this site into
    # the same ok/failed/unconfigured vocabulary the `--enable` path uses.
    fleet_expiry_flag_outcome="$(fleet_flag_delete_outcome "$state_repo" "$state_dir" disabled)"
    log_event "enabled" "$(jq -nc \
      --argjson r "$(jq -c '.record' <<<"$fleet_switch_state")" \
      --arg ff "$fleet_expiry_flag_outcome" \
      '{detail: "fleet disable expired", was: $r, scope: "fleet", fleet_flag: $ff}')"
    notify_post_cycle "fleet-standdown-end" "standdown:fleet-switch" \
      "Fleet switch expired" "" "" "fleet disable expired"
    ;;
  disabled)
    fleet_switch_record="$(jq -c '.record' <<<"$fleet_switch_state")"
    if [[ "$(toggle_mode "$fleet_switch_record")" == "drain" ]]; then
      # A fleet-wide drain wins over a node-scoped one for the purpose of
      # DRAIN_DISABLED_AT (checked after the local switch above, so this
      # simply overwrites it when both are active): the fleet decision is the
      # broader-scoped one, and the two share a disabled_at in the ordinary
      # case anyway (an unmodified --drain writes both levels at once).
      DRAINING=1
      DRAIN_DISABLED_AT="$(jq -r '.disabled_at // ""' <<<"$fleet_switch_record")"
    else
      log_event "stand-down" "$(jq -nc \
        --arg r "fleet switch: $(toggle_describe "$fleet_switch_record")" \
        '{reason: $r, cause: "disabled-fleet"}')"
      notify_post_cycle "fleet-standdown-begin" "standdown:fleet-switch" \
        "Fleet switch set" "" "" "fleet switch: $(toggle_describe "$fleet_switch_record")"
      set_node_state_terminal down disabled-fleet
      (( ONCE )) && echo "agent-cycle: the fleet switch is set — agent-cycle.sh --enable clears it everywhere" >&2
      exit 0
    fi
    ;;
esac

# --- 1. Lock ---
acquire_lock() {
  if [[ -f "$lock_file" ]]; then
    local pid started_at host
    pid="$(jq -r '.pid // empty' "$lock_file" 2>/dev/null || true)"
    started_at="$(jq -r '.started_at // empty' "$lock_file" 2>/dev/null || true)"
    host="$(jq -r '.host // empty' "$lock_file" 2>/dev/null || true)"
    if [[ "$pid" =~ ^[0-9]+$ ]]; then
      local started_epoch now_epoch age_sec pgid
      started_epoch="$(date -d "$started_at" +%s 2>&1)" \
        || { guard_warn "stale-lock:started_epoch" "$started_epoch"; started_epoch=0; }
      now_epoch="$(date +%s)"
      age_sec=$(( now_epoch - started_epoch ))
      if [[ -n "$host" && "$host" != "${HOSTNAME:-}" ]]; then
        # A pid is only meaningful in the PID namespace that minted it. This
        # lock's `host` names a different container, so its incarnation is
        # gone by construction — take it over without asking `kill -0`,
        # which would be answering about an unrelated process in ours (#130
        # fixed the same confusion in the watchtower hook).
        log_event "warning" "$(jq -nc --arg d "foreign lock from pid $pid on host $host (age ${age_sec}s) taken over" '{detail: $d}')"
      else
        local stale_after_sec
        stale_after_sec="$lock_stale_after_sec"
        if kill -0 "$pid" 2>/dev/null && (( age_sec < stale_after_sec )); then
          log_event "cycle-skipped" "$(jq -nc --arg d "lock held by pid $pid, age ${age_sec}s" '{detail: $d}')"
          # node-state (docs/FLOW-SCHEMA.md, D21): a skipped tick is not a
          # state. The cycle holding this lock is the one occupying these
          # node-seconds, and its own transitions already say so — see
          # suppress_node_state_transitions' header.
          suppress_node_state_transitions
          # Nor is it a record (agent-ops#1826): the directory made above
          # holds nothing but the fleet-log snapshot taken before the lock —
          # tens of megabytes a tick that ran no stage will never read — and
          # every such directory takes one of `state_local_streams_retained`'s
          # slots from a cycle that did run, until the cycle still holding
          # this lock is pushed out of that window by the ticks that found it
          # held. The `cycle-skipped` event is the tick's record, and the
          # dashboard already renders a cycle id that has no directory.
          # Nothing in `cleanup` needs it when the lock was not taken: the
          # Enabler and the Refiner both gate on `lock_acquired`.
          rm -rf -- "$cycle_dir"
          exit 0
        fi
        if kill -0 "$pid" 2>/dev/null; then
          pgid="$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')"
          if [[ -n "$pgid" ]]; then
            # TERM first, so the doomed cycle's own handler (requirement 9c)
            # can log its `attempt-failed` and release its claim; KILL only
            # after a grace sized to that handler's worst case — one
            # process-group kill, one log append, one 8-second-bounded claim
            # release. Polled rather than slept: a cycle that records and
            # exits in one second costs one second.
            kill -TERM "-$pgid" 2>/dev/null || true
            local grace_waited=0
            while (( grace_waited < 20 )) && kill -0 "$pid" 2>/dev/null; do
              sleep 1
              grace_waited=$(( grace_waited + 1 ))
            done
            if kill -0 "$pid" 2>/dev/null; then
              kill -KILL "-$pgid" 2>/dev/null || true
            fi
          fi
        fi
        log_event "warning" "$(jq -nc --arg d "stale lock from pid $pid (age ${age_sec}s) taken over" '{detail: $d}')"
      fi
    fi
  fi
  # `host` names the container (PID namespace) the pid is meaningful in: the
  # dashboard shares this lock through the state volume, and its copy of
  # watchtower's pre-update hook must know it cannot `kill -0` our pid (#130).
  jq -n --argjson pid "$$" --arg started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg host "${HOSTNAME:-}" \
    '{pid: $pid, started_at: $started_at, host: $host}' > "$lock_file"
  lock_acquired=1
}
# --- 1a. The fleet's memory (requirement 2.5) ---
# `lock.json` keeps two cycles apart on one node; per-item claims (requirement
# 17a) keep two *nodes* off the same work. Nothing arbitrates "the" active
# node any more — what the fleet shares instead is memory: the union of every
# node's event log, materialised by `state-sync.sh fetch` into the peers
# directory. Snapshotted here, once, so every reader below (the usage-limit
# cooldown, the blocked and void extractions, the no-op fingerprint) sees one
# consistent stream — a lesson any node learned spares the whole fleet.
#
# Taken before the lock rather than after it, which it was until the stage
# budgets came to be derived from it (requirement 4f): `lock_stale_after` is
# now one of the things derived, and `acquire_lock` needs it. A snapshot taken
# a few milliseconds earlier is the same snapshot — peers change only when
# `state-sync.sh fetch` runs — and the cost to a cycle that then finds the
# lock held is one read of a file it would have read anyway.
peers_dir="$(fleet_peers_dir "$workspace_root")"
union_log="$cycle_dir/.fleet-log.jsonl"
# A peer that has not repaired its own log yet — or history replicated before
# it did — can still hand this node a NUL-holed or spliced line via
# peers_dir/*/log.jsonl. `fleet_logs` takes such a line apart before its sort
# (lib/fleet.sh), so every record it holds sits at its own timestamp's place
# and nothing below has to repair the snapshot (agent-ops#794, #2037).
#
# A union that could not be built (`tr`, `awk`, `jq` or the sort failing — an
# OOM kill or a full disk, say) is reported here, and `union_build_ok` carries
# it to the readers below that must tell "could not read" from "nothing
# there": the usage-limit read treats it exactly as a failed read, and the
# freeze escalation files nothing this cycle (lib/standdown.sh).
union_build_ok=1
union_build_err="$(fleet_logs "$state_dir" "$peers_dir" log.jsonl 2>&1 > "$union_log")" \
  || { guard_warn "cycle:union_build" "$union_build_err"; union_build_err=""; union_build_ok=0; }
# The snapshot's own horizon (requirement 39f, #670): the newest `.ts` the
# union above reaches, not wall clock — in practice this cycle's own
# `cycle-start` event, already in this node's log by the time `fleet_logs`
# unions it in, unless a peer's fetched log carries something newer. The
# own-label grace window has to be measured against that, or a long cycle
# reads a peer's label write, already inside the snapshot, as older than it
# is by the cycle's own runtime. Captured here, immediately after the
# snapshot and before this cycle's own log lines are appended into
# `$union_log` (three
# such appends stand between here and the requirement-39f read-back below,
# and more after it): an append reordered ahead of this point would make the
# horizon track wall clock again through this node's own fresh events, and
# the fix would evaporate. `test/label-marker-horizon-wiring.test.sh` pins
# that ordering, and pins both read-back calls below being handed the result.
union_log_horizon="$(log_latest_ts "$union_log")"

# --- 1a1. What each stage is allowed this cycle (requirement 4f) ---
# Derived, not stored and not configured: one fold over the union above gives
# every node the same two numbers per (actor, repository, model) with nothing
# to synchronise. See lib/stage-budget.sh for why the watchdog threshold is
# estimated and the backstop controlled, and why each moves the way it does.
stage_budget_config="$(cat "$CONFIG_FILE" 2>&1)" \
  || { guard_warn "stage_budget_config" "$stage_budget_config"; stage_budget_config='{}'; }
stage_budget_settings_json="$(stage_budget_settings "$stage_budget_config")"
stage_budget_json="$(stage_budget_table \
  "$(stage_budget_observations < "$union_log")" "$stage_budget_settings_json")"

# The cycle lock has to outlast a cycle that runs every stage to its limits,
# and those limits now move — so it is derived from them plus slack rather
# than asserted against them by hand (requirement 4f). A configured
# `lock_stale_after` is a floor, never a ceiling.
lock_stale_after_sec="$(stage_budget_lock_seconds "$stage_budget_json" \
  "$(stage_budget_all_overrides "$stage_budget_config")" "$LOCK_SLACK_MIN" "$lock_stale_configured_hours")"

# --- 1a2. Reclaim the workspaces of cycles that never cleaned up (#605) ---
# Here because this is the first point at which the lock window exists, and
# comfortably before the clone that will need the room. Before the lock rather
# than after it, and before every stand-down: a node standing down for a
# fleet limit is a node with hours of nothing to do and, quite possibly, a
# full disk — the one moment housekeeping matters most is the one where the
# cycle does no other work. It runs at most once per cycle interval per node
# either way.
#
# `|| true` and a lib that swallows its own failures: reclaiming disk must
# never be the reason a cycle does not run. The event is written only when
# something was actually reclaimed — an ordinary cycle on a healthy node reaps
# nothing, and a `workspaces-reaped` line every cycle would say nothing while
# burying the ones that mean something.
workspace_reap_json="$(workspace_reap_summary "$workspace_root" \
  "$(workspace_reap_window "$lock_stale_after_sec")" || printf '{"reaped":0}')"
if [[ "$(jq -r '.reaped // 0' <<<"$workspace_reap_json" 2>/dev/null || printf 0)" != "0" ]]; then
  log_event "workspaces-reaped" "$workspace_reap_json"
fi

acquire_lock
# node-state (docs/FLOW-SCHEMA.md, D21): a live node emits the transition out
# of `down` here — `down` is derived from absence and never emits its own.
# Here rather than beside `cycle-start` above, because everything between the
# two can still end in a tick that owns no node-second at all: `cycle-skipped`
# (this node is busy in the *other* process, whose events already own those
# seconds) exits from inside `acquire_lock`, and a transition logged before it
# would relabel that process's own live stage as this tick's overhead for as
# long as the stage runs. The two switch stand-downs above exit before this
# line too and want no `overhead` either — their own `down` is what
# `finalize_node_state_for_cycle` logs at the end of `cleanup`.
log_node_state_transition overhead

# Shed a landed roll-pending marker before this cycle's own stages run
# (requirement 39c amendment, agent-ops#1102): the marker a prior cycle's
# cleanup() wrote is honoured on a fixed clock, not "until the next cycle
# would have started", so a cycle that reacquires the lock (as this one just
# did) before that clock runs out would otherwise spend its own run
# underneath a marker that still tells watchtower-pre-update.sh to override
# this very lock. Re-acquiring the lock is itself the proof the gap the
# marker described has ended, so clear it once the image is no longer
# "behind" — the only case a cycle boundary can act on either way (see
# lib/chain.sh's chain_image_behind). Reads the same cache-backed round trip
# the state-sync heartbeat already keeps warm (`IMAGE_DRIFT_TTL`), so this
# costs a network call only when that cache was already due to refresh.
if [[ -f "$state_dir/roll-pending.json" ]]; then
  chain_clear_landed_roll_pending "$state_dir" \
    "$(image_drift_status "$(agent_ops_version "$SCRIPT_DIR")" \
      "$state_dir/.image-drift-cache.json" 2>/dev/null || echo null)"
fi

# Stand down instead of running this cycle's own stages under a marker that
# survived the clear above (requirement 39c amendment, agent-ops#1102's own
# option 2): the block above declines to clear a marker whose verdict still
# reads "behind", which is deliberate — the roll genuinely has not landed —
# but leaves this cycle free to run every stage underneath an unconditional
# override of `lock.json`, exactly the cost the hook exists to prevent. Idling
# is worth it only when something is actually there to take the gap a
# stand-down opens, so this asks one more question before giving up the
# cycle: is watchtower actually invoking the hook and being turned away right
# now (`chain_updater_should_standdown`, reusing `lib/updater-health.sh`'s own
# `updater_status` verdict off the same ledger the heartbeat already reads —
# no second signal)? `chain_eligible` is still 0 here regardless (it is only
# ever raised inside the claim loop, well after this point), so there is no
# chain to protect by standing down — this is purely about not running this
# cycle's own stages under the marker.
if chain_roll_pending_live "$state_dir"; then
  updater_stuck_after_seconds="$(cfg '.updater_stuck_after_minutes * 60 | floor')"
  updater_defer_stuck_after_seconds="$(cfg \
    '([.lock_stale_after // 4, .repository_review.lock_stale_after // 6] | max) * 3600 | floor')"
  updater_status_json="$(updater_status "$state_dir/updater-ledger" "$updater_stuck_after_seconds" \
    "$updater_defer_stuck_after_seconds" "${HOSTNAME:-}" "${AGENT_OPS_SERVICE:-}" 2>/dev/null || echo null)"
  if chain_updater_should_standdown "$updater_status_json"; then
    roll_pending_until="$(jq -r '.until // empty' "$state_dir/roll-pending.json" 2>/dev/null || true)"
    if chain_roll_standdown_available "$state_dir"; then
      chain_roll_standdown_record "$state_dir"
      log_event "stand-down" "$(jq -nc --arg u "$roll_pending_until" --argjson updater "$updater_status_json" \
        --arg r "a live roll-pending marker is still in force and watchtower is being turned away rather than rolling the image (updater_status: $updater_status_json) — idling this cycle instead of running its stages underneath the marker's own override of lock.json" \
        '{reason: $r, cause: "roll-pending", until: $u, updater: $updater}')"
      set_node_state_terminal externally-blocked roll-pending
      exit 0
    fi
    # Guard B's cap (agent-ops#1102 option 2): already spent on this pending
    # roll. Log the decision not taken — the live marker and the count — so a
    # node running under a marker it could not idle away a second time is
    # visible rather than silent, then fall through and run this cycle
    # normally.
    log_event "roll-standdown-capped" "$(jq -nc --arg u "$roll_pending_until" \
      --arg c "$(jq -r '.count // "unknown"' "$state_dir/roll-standdown.json" 2>/dev/null || echo unknown)" \
      '{until: $u, count: $c}')"
  fi
fi

# --- 1b. Crash-loop escalation (requirement 2.7) ---
# A Co-Ordinator failure pins no item — nothing is blocked, so the whole
# blocked → Enabler → escalation ladder that covers item failures never sees
# it — and the cycle still ends 0, so the dashboard shows a healthy idle
# fleet. When the failure is deterministic and ships in the image (the
# 2026-08-01 argv-cap outage: `coordinator exited 126`, every node, every
# hour, ~15 hours), the record and the reality diverge completely. So the one
# signal that class does leave — the same failure, verbatim, over and over
# with no success anywhere in the fleet — is read here, from the same union
# every other fleet-wide judgement uses, and escalated the same way the
# Enabler escalates: an issue at the human, deduplicated, assigned so the
# pipeline can never select its own SOS as work. Before the stand-down
# checks, so a fleet that is also standing down (a limit, the switch) still
# raises the alarm; after the union snapshot, because the loop is a property
# of the fleet's memory, not this node's. The cycle then proceeds normally —
# detection must never suppress the recovery attempt that might end the loop.
#
# Two classes share this block, through the one `crash_loop_escalate` path:
# a Co-Ordinator that runs and fails identically (`crash_loop_verdict`), and
# a cycle that dies before any stage — Co-Ordinator included — ever starts
# (`crash_loop_preselection_verdict`, TD-PPagop-26081302). The second exists
# because the first is blind to exactly the shape both real outages took:
# `execve` failing on an oversized argv kills the cycle before `stage-start`
# for any stage is ever logged, so no `attempt-failed` exists for
# `crash_loop_verdict` to count. Each class keys its own item ref, so either
# can escalate independently of the other. `crash_loop_verdict` further keys
# by repository (agent-ops#1630): since issue #587 split Co-Ordinator
# selection into one engagement per configured repository, it can now return
# more than one line, each an independent per-repository run, so a single
# repository's own deterministic failure is never reset by a sibling
# repository's success and can escalate on its own — see the loop below.
# `crash_loop_preselection_verdict` stays fleet-wide/exit-code-grouped: it
# fires before selection ever assigns a repository to anything.
#
# `crash_loop_verdict`'s own run can additionally be *transient* (issue
# #1073): every failure it counted was the API being unreachable — a 5xx, a
# dropped connection — not the API refusing a request it considered. On
# 2026-08-29/30 the Ockham host lost outbound network for four hours and this
# block escalated it as "almost certainly deterministic … no amount of
# retrying will clear it" (#1070), which was false on the escalation's own
# evidence and cleared itself the moment the network returned. `escalate`
# (set by `crash_loop_verdict` itself, from each failure's own
# `api_refusal_class`) is what tells the two apart here: `false` means every
# failure in the run was `transient`, so this is a node/fleet connectivity
# fact, not a deterministic fault, and it is logged for the dashboard's node
# card instead of raised as an issue asserting a cause it cannot support.
# `crash_loop_preselection_verdict` carries no such class — an `execve`
# failure is never a network refusal — so its run always escalates exactly as
# it always has.
#
# A verdict here is always computed from the union log as it stood before
# this cycle's own Co-Ordinator attempt (if any) — this point in the script
# runs first, deliberately (the alarm must fire even on a cycle that stands
# down before reaching the Co-Ordinator at all). That makes a *first* attempt
# at filing this exact run reliable — nothing has looked at it before — but
# not a *retried* one: `crash_loop_escalate_or_defer` (lib/enabler.sh) files
# a verdict never before attempted immediately, exactly as `crash_loop_
# escalate` always has, but queues a deferred retry — or a fresh attempt that
# itself failed to file — for `crash_loop_refile_pending` to re-verify from
# `cleanup()`, once this cycle's own Co-Ordinator has had its chance to prove
# the run over (agent-ops#1074). Filing every retry here regardless of
# staleness is exactly what turned the 2026-08-29/30 Ockham outage's last
# hour into a false alarm (#1070): the escalation and the Co-Ordinator
# success that refuted it landed in the same cycle, the escalation first only
# because this block runs before the Co-Ordinator does. `crash_loop_retire_
# resolved` closes the other side of the same gap: an already-open Co-
# Ordinator-class escalation whose run has broken since, on any later cycle's
# ordinary union snapshot — no same-cycle race to lose, so no need to wait
# for `cleanup()`.
#
# Retirement runs FIRST, before either `crash_loop_escalate_or_defer` call
# below (agent-ops#1134 review). `create_escalation_issue`'s own open-issue
# dedup is a live `gh issue list` query, not a read of this cycle's
# `$union_log` — so if a resolved run's issue is still open when a *new*,
# same-detail run re-crosses `crash_loop_after` later in this same block,
# `create_escalation_issue` finds that still-open issue and rebinds it to the
# new run instead of filing a fresh one, and this retirement step then closes
# it out from under that live run on the strength of a `$union_log` snapshot
# that predates the rebind. Running retirement first closes the resolved
# run's issue before the new run's own filing attempt can see it, so that
# attempt's `gh issue list` no longer finds anything to reuse and opens a
# fresh issue instead — the new run gets its own alarm rather than inheriting
# one already closed for the old.
if ! (( DRY_RUN )) && (( crash_loop_after > 0 )) \
    && [[ -n "$crash_loop_repo" && -n "$enabler_assignee" && -s "$union_log" ]]; then
  # Retirement (agent-ops#1074): independent of whether either class fires a
  # verdict this cycle — an open escalation from a run that broke cycles ago
  # is exactly what this closes, whatever this cycle's own union log shows
  # right now.
  crash_loop_retire_resolved "$union_log_horizon"

  # crash_loop_verdict now prints one JSON-Lines object per independently
  # crash-looping repository (plus the repo-less fallback group) — each line
  # is escalated on its own, under its own item ref, so one repository
  # reaching threshold never waits on, or gets folded into, another's.
  while IFS= read -r crash_loop_line; do
    [[ -n "$crash_loop_line" ]] || continue
    crash_loop_verdict_repo="$(jq -r '.repo // ""' <<<"$crash_loop_line")"
    if [[ -n "$crash_loop_verdict_repo" ]]; then
      crash_loop_item_ref="crash-loop:coordinator:$crash_loop_verdict_repo"
      crash_loop_title_prefix="Crash loop: the Co-Ordinator is failing for $crash_loop_verdict_repo"
    else
      crash_loop_item_ref="crash-loop:coordinator"
      crash_loop_title_prefix="Crash loop: the Co-Ordinator is failing fleet-wide"
    fi
    if [[ "$(jq -r '.escalate' <<<"$crash_loop_line")" == "true" ]]; then
      crash_loop_escalate_or_defer "$crash_loop_line" "$crash_loop_item_ref" \
        "Co-Ordinator failures" \
        "$crash_loop_title_prefix" \
        "Start with the newest failing cycle's \`coordinator-<repo-slug>.out\` files under \`state_dir/cycles/\` — one per configured repository, since each gets its own engagement (requirement 15) — a stage the API refused outright records the refusal there, as a \`result\` with \`is_error: true\`, and leaves the matching \`.out.stderr\` empty (agent-ops#641). Read those \`.out.stderr\` files too, for a stage that died rather than being refused; the stage transcripts survive every failure."
    else
      log_event "provider-unreachable" "$crash_loop_line"
    fi
  done < <(crash_loop_verdict "$crash_loop_after" < "$union_log")

  crash_loop_preselection_json="$(crash_loop_preselection_verdict "$crash_loop_after" < "$union_log")"
  if [[ -n "$crash_loop_preselection_json" ]]; then
    crash_loop_escalate_or_defer "$crash_loop_preselection_json" "crash-loop:pre-selection" \
      "cycles dying before any stage started" \
      "Crash loop: cycles are dying before any stage starts" \
      "No stage transcript exists for a cycle that dies before any stage begins — start with the newest failing cycle's entry in \`cron.log\` (or \`cron.log.1\` after rotation) under \`state_dir/\`."
  fi
fi

# 1c. Token-expiry escalation (agent-ops#694). GitHub states a personal
# access token's own expiry on every API response it authenticates
# (`GitHub-Authentication-Token-Expiration`); on 2026-08-22 that date went
# unread until it arrived, and every node lost GitHub at once, misdiagnosed
# as an outage (agent-ops#691) for hours before an operator noticed. This is
# the warning before that cliff, 2.0b above is the fallback for having
# missed it.
#
# Free: reads this node's own `state_dir/.doctor-status.json` — the hourly
# `doctor.sh --unattended` pass's own artefact (requirement 2.6a) — rather
# than making a GitHub call of its own. `doctor.sh` is read-only by its own
# declared contract, so the header read lives there and the escalation
# (a write — `gh issue create`) lives here instead, the same split
# `.doctor-status.json`'s fails/warns already use with the dashboard.
#
# Escalated the same fleet-scoped, deduplicated route 1b's crash loop and
# 2.0b's auth failure already use — `create_escalation_issue` in
# `crash_loop_repo`, labelled `enabler_escalation_label`, assigned
# `enabler_assignee` — never `escalation_autonomy` (D18, agent-ops#627):
# that ladder decides whether one specific escalation, an Enabler
# refinement-disagreement (requirement 36b), is adjudicated once before
# reaching a human, and there is no disagreement to adjudicate here, only a
# date comparison — the same reasoning 2.0b's own block gives for the
# identical choice.
#
# Deduplicated on the expiry timestamp itself (`token_expiry_escalated_for`,
# lib/token-expiry.sh), not merely "is there an open issue right now": a
# human closing the issue without rotating the token must not reopen the
# gate every cycle until they do — it reopens only once the token is
# actually rotated, which is exactly when the expiry timestamp changes.
# Before the stand-down checks, like 1b, so a fleet that is also standing
# down still raises the alarm; the cycle then proceeds normally regardless,
# since a token that has not yet expired blocks nothing this cycle needs.
#
# Every read below falls back rather than propagating `jq`'s own exit status:
# this file runs under `set -e`, `.doctor-status.json` is not this script's
# own artefact, and a shape `jq` refuses to index (a `token_expiry` that is
# valid JSON but not an object, say) would otherwise kill the cycle here —
# before any stage starts, which is exactly requirement 2.7's pre-selection
# crash-loop class. No warning is worth costing the cycle that carries it.
doctor_status_json="$(jq -c '.' "$state_dir/.doctor-status.json" 2>/dev/null || echo null)"
token_expiry_days="$(jq -r '.token_expiry.days_remaining // empty' <<<"$doctor_status_json" 2>/dev/null || true)"
token_expiry_expires_at="$(jq -r '.token_expiry.expires_at // empty' <<<"$doctor_status_json" 2>/dev/null || true)"
if [[ "$token_expiry_days" =~ ^[0-9]+$ ]] && [[ -n "$token_expiry_expires_at" ]] \
    && (( token_expiry_days < TOKEN_EXPIRY_WARN_DAYS )); then
  if ! (( DRY_RUN )) && [[ -n "$crash_loop_repo" && -n "$enabler_assignee" ]] \
      && ! token_expiry_escalated_for "$node_name" "$token_expiry_expires_at" < "$union_log"; then
    token_expiry_body="$cycle_dir/token-expiry-issue.md"
    # shellcheck disable=SC2016  # the backticks are the issue body's Markdown, not expansions
    {
      printf '## This node'"'"'s PAT is expiring soon\n\n'
      printf -- '- node: `%s`\n- expires: `%s`\n- days remaining: **%s**\n\n' \
        "$node_name" "$token_expiry_expires_at" "$token_expiry_days"
      printf 'GitHub states this on every authenticated API response; `doctor.sh --unattended` reads it hourly. Rotate this node'"'"'s `GH_TOKEN` before it expires — agent-ops#691 is what happens if it is not: every pipeline stands down at once, misread as an outage.\n\n'
      printf -- '---\nItem: `token-expiry:%s:%s` · raised by the Script · node `%s`\n' \
        "$node_name" "$token_expiry_expires_at" "$node_name"
    } > "$token_expiry_body"
    if token_expiry_created="$(create_escalation_issue "$crash_loop_repo" \
         "token-expiry:$node_name:$token_expiry_expires_at" \
         "$enabler_escalation_label" \
         "GitHub PAT on node $node_name expires in ${token_expiry_days}d ($token_expiry_expires_at)" \
         "$token_expiry_body")" && [[ -n "$token_expiry_created" ]]; then
      log_event "token-expiry-escalated" "$(jq -nc \
        --arg e "$token_expiry_expires_at" --argjson d "$token_expiry_days" \
        --argjson n "${token_expiry_created%%$'\t'*}" --arg u "${token_expiry_created#*$'\t'}" \
        '{expires_at: $e, days_remaining: $d, issue_number: $n, issue_url: $u}')"
    else
      log_event "warning" "$(jq -nc \
        --arg d "this node's GitHub PAT expires in ${token_expiry_days}d but the escalation issue could not be filed — will retry next cycle" \
        '{detail: $d}')"
    fi
  fi
fi

run_standdown_checks
# --- 2b. Git identity ---
# After every stand-down check above (switch, fleet switch, usage-limit) and
# before the first repo this cycle might actually touch: none of those
# earlier exits commit anything and must not be blocked on an identity they
# never use, but everything from here on can. See lib/git-identity.sh.
require_git_identity agent-cycle

# --- 3. Repo ordering through 3b. No-op short-circuit (lib/gather-phase.sh,
#     issue #1958) --- one function: band eligibility, the decision-veto
#     sweep, back-pressure's finishing-sources narrowing, the requirement-4i
#     prompt-fit ladder and the no-op short-circuit, in that order. Exits the
#     cycle itself (stand-down/back-pressure/no-op) on several paths; falls
#     through to the Co-Ordinator stage below only when there is a prompt
#     worth sending.
run_gather_phase

# --- 4. Co-Ordinator stage through end of cycle (lib/coordinator-phase.sh,
#     issue #1958) --- one function: the Co-Ordinator stage itself (one
#     invocation per repository, issue #587), candidate selection and the
#     claim, the workspace, the Implementer stage, the Reviewer stage, the
#     Approver stage and the landing-arming step. The script's own final
#     statement lives inside it.
run_coordinator_through_finishing_phase
