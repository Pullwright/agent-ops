#!/usr/bin/env bash
# shellcheck disable=SC2154,SC2034  # this file's functions read and write the cycle's own globals — assigned by agent-cycle.sh, which sources every lib/*.sh file into one process (#771) — never locally; each function's own header names which ones.
#
# lib/standdown.sh — the stand-down reason ladder (requirement 2): every
# check a cycle runs, in order, before it commits to doing any work this
# round — the GitHub API budget and credential check, the fleet-wide
# usage-limit cooldown and its own probe, the per-cycle claim GC and orphan/
# closing-keyword/human-visibility/landing-retry/classifier-escape sweeps,
# and back-pressure across every configured repository.
#
# Split out of agent-cycle.sh (#771) as the "stand-down reason ladder" seam
# docs/spec/implementation/README.md's requirements name. Sourced by
# agent-cycle.sh only, and called exactly once, in place, from where this
# text used to sit: every variable it reads (`github_min_core_budget`,
# `crash_loop_repo`, `enabler_assignee`, `union_log`, …) is already set by
# the spine ahead of it, and every variable it sets (`backpressure_tripped`,
# `open_composition`, `adjusted_open_count`, `counted_prs_json`, …) is read
# by the spine after it returns — deliberately not `local`, so this call is
# indistinguishable, to the rest of the cycle, from the inline block it
# replaces. `exit 0` inside it ends the cycle exactly as it did inline: nothing
# here runs inside a subshell.
# Defensive fallback for lib/stage-run.sh's stage_model_resolve_into and
# lib/model-id.sh's model_key_is_set (issue #2247): several of this file's
# own tests source this file alone and stub run_model_stage directly,
# never lib/model-id.sh or lib/stage-run.sh (the same gap lib/metering.sh's
# own MODEL_PROVIDER guard already documents for exactly this reason). A
# plain, never-a-set pass-through here is behaviourally identical to the
# real functions for every configuration those tests exercise, since none
# of them configures a weighted set, and is never reached in production
# (agent-cycle.sh sources both real implementations well before this file).
declare -F model_key_is_set >/dev/null 2>&1 || model_key_is_set() { return 1; }
declare -F stage_model_resolve_into >/dev/null 2>&1 || stage_model_resolve_into() {
  STAGE_MODEL_SET_EXTRA_JSON='{}'
  printf -v "$1" '%s' "$2"
}

run_standdown_checks() {
# --- 1.9 Forge authoring identity (D18 decision 1, agent-ops#607; the
# on-demand credential seam, agent-ops#1021). Nothing here resolves or
# exports a credential any more — that now happens per call, on demand,
# through the seam (lib/gh-shim.sh's `gh` transport shim and, for plain
# `git`, deploy/docker/entrypoint.sh's credential-helper wiring), which is
# what lets a cycle outlive a forge authoring App installation token's ~1 h
# lifetime without presenting a stale one. This step only logs which path a
# call made right now would take — `forge_auth_effective_gh_token`'s
# TOKEN is diagnostic only (lib/forge-auth.sh) — so that 2.0b's credential
# probe two steps later, whose own `gh` call goes through the same seam, and
# any operator reading the log, can see which identity this cycle actually
# authors under.
IFS=$'\t' read -r forge_auth_source _ < <(forge_auth_effective_gh_token)
log_event "forge-auth" "$(jq -nc --arg s "$forge_auth_source" '{source: $s}')"
if [[ "$forge_auth_source" == "gh-token-degraded" ]]; then
  log_event "warning" "$(jq -nc \
    --arg d "the forge authoring App credential (PULLWRIGHT_AUTHOR_APP_ID/_INSTALLATION_ID(S)/_PRIVATE_KEY_PATH) is configured but no token could be minted against this node's *default* installation — so every call the seam cannot attribute to a repository owner degrades to its fallback (PW_GH_DEGRADE_TOKEN, or GH_TOKEN), exactly as a node with none of them configured. Either the mint failed, or PULLWRIGHT_AUTHOR_INSTALLATION_ID is unset and only the per-owner map is configured" \
    '{detail: $d}')"
fi

# --- 2. Stand-down checks ---
# 2.0 GitHub API budget (requirement 2.0). First of the stand-down checks
# because it is the cheapest one: two points — one metered `GET /meta` for its
# `x-ratelimit-*` headers and one GraphQL `rateLimit` query — against the
# thousands every check below it can spend, the usage-limit probe most of all.
# Not the free `GET /rate_limit`: read cold, its body is an empty window, not
# a reading, and this gate answered `ok` from it through 95 refusals
# (agent-ops#1087; lib/github-limit.sh's header has the measurement).
#
# What this prevents is not the failed `gh` call. It is the cycle of
# 2026-08-12T20:52Z, which read a rate-limited GitHub as a quiet one: every
# gatherer degraded to `[]`, the Co-Ordinator engaged on that digest and chose
# an item, the claim was taken, and the cycle then died at the clone with
# `GraphQL: API rate limit already exceeded`. All of that is downstream of a
# question GitHub would have answered for free before the first token was
# spent.
#
# `unknown` — the meter itself unreadable — is deliberately not a stand-down.
# It is no evidence about the budget, and a node that cannot reach
# `/rate_limit` could not have run a cycle anyway; the failure it does have
# will be reported by whatever call meets it. Standing down here would invent
# a way for a network blip to look like an exhausted account.
# The reading is recorded first (requirement 2.0d) — whether or not a floor is
# set, since the record is what D25's "measured to bind" trigger reads — and
# the verdict judges that same reading rather than paying for a second one.
github_budget_record cycle-start
if (( github_min_core_budget > 0 || github_min_graphql_budget > 0 )); then
  IFS=$'\t' read -r gh_budget_verdict gh_budget_resource gh_budget_remaining gh_budget_reset_at \
    < <(github_limit_verdict "$GITHUB_BUDGET_LAST_SNAPSHOT" \
          "$github_min_core_budget" "$github_min_graphql_budget")
  if [[ "$gh_budget_verdict" == "exhausted" ]]; then
    if [[ "$gh_budget_resource" == "core" ]]; then
      gh_budget_floor="$github_min_core_budget"
    else
      gh_budget_floor="$github_min_graphql_budget"
    fi
    log_event "stand-down" "$(jq -nc --arg r "$(github_limit_describe \
      "$gh_budget_resource" "$gh_budget_remaining" "$gh_budget_floor" "$gh_budget_reset_at")" \
      --arg res "$gh_budget_resource" --arg rem "$gh_budget_remaining" \
      --arg until "$gh_budget_reset_at" \
      '{reason: $r, github_resource: $res, github_remaining: $rem, resume_at: $until, cause: "github-budget"}')"
    set_node_state_terminal externally-blocked github-budget
    exit 0
  fi
fi

# 2.0b GitHub credential check (requirement 2.0b, agent-ops#691). The same
# free `/rate_limit` call classifies a 401, and a missing token, apart from
# every other failure: either GitHub read the request and rejected the
# credentials outright, or `gh` had no credentials to send in the first
# place — both permanent, unlike 2.0's `exhausted` or 2.1's cooldown below,
# since no wait and no retry clears an expired, revoked or absent token.
# Checked here, ahead of the Co-Ordinator (step 4), because that stage is
# what a dead token wastes: on 2026-08-22 a node whose fine-grained PAT had
# expired ran a full Co-Ordinator engagement every cycle for ~3 hours ($1.05
# across five cycles) before a human noticed, every claim failing with
# `cause: "unreachable"` and the cycle reporting "this is an outage, not
# contention" — the one classification that sends nobody looking at the
# token. TD-PPagop-26082306 is the same fault in a different shape: a token
# unset or dropped from the environment failed the probe's stderr match too,
# so it also read as `unreachable` rather than `unauthorized`.
#
# Deliberately unconditional, unlike 2.0: a dead token is worth catching
# even on a node that has turned `github_min_core_budget` /
# `github_min_graphql_budget` off, and the call costs nothing either way
# (same free `/rate_limit` endpoint).
#
# Not routed through `escalation_autonomy` (D18, agent-ops#627): that ladder
# decides whether one specific kind of escalation — an Enabler
# refinement-disagreement (requirement 36b) — is adjudicated once before
# reaching a human. Its `adjudicate-first` path is itself a model engagement
# against GitHub, which a dead token defeats exactly as it defeats the
# Co-Ordinator; routing through it here would reintroduce the spend this
# check exists to avoid. This follows 1c's and 2.7's own precedent instead —
# an operational fact about the node, not a per-item disagreement — and
# escalates unconditionally through the same `create_escalation_issue`,
# deduplicated the same way (an open issue already naming this node's item
# ref is found, not re-filed).
IFS=$'\t' read -r gh_auth_verdict gh_auth_detail < <(github_auth_probe)
if [[ "$gh_auth_verdict" == "unauthorized" ]]; then
  # `github_auth_probe` folds two permanent faults into one verdict (2.0b's
  # own header above): a token GitHub rejected outright, and no token to send
  # at all. `detail`'s leading "no token present" (the probe's own literal
  # wording, TD-PPagop-26082306) is the only thing that tells them apart here
  # — without this branch every missing-token stand-down and escalation would
  # keep claiming a nonexistent "(HTTP 401)" and tell a human to replace a
  # token that was never set.
  if [[ "$gh_auth_detail" == "no token present"* ]]; then
    gh_auth_reason="GitHub authentication failed — no GH_TOKEN/GITHUB_TOKEN is set and gh has no stored credentials"
    auth_heading="This node has no GitHub credentials"
    auth_detail_label="detail"
    auth_title="GitHub credentials missing on node $node_name"
    auth_remedy="Nothing clears this automatically — set \`GH_TOKEN\` on this node and the next cycle proceeds normally."
    auth_warning_detail="GitHub credentials missing but the escalation issue could not be filed — will retry next cycle"
  else
    gh_auth_reason="GitHub authentication failed (HTTP 401) — GH_TOKEN is invalid or expired"
    auth_heading="GitHub rejected this node's credentials"
    auth_detail_label="GitHub's own response"
    auth_title="GitHub credentials rejected on node $node_name (HTTP 401)"
    auth_remedy="Nothing clears this automatically — replace \`GH_TOKEN\` on this node and the next cycle proceeds normally."
    auth_warning_detail="GitHub credentials rejected (401) but the escalation issue could not be filed — will retry next cycle"
  fi
  if ! (( DRY_RUN )) && [[ -n "$crash_loop_repo" && -n "$enabler_assignee" ]]; then
    auth_body="$cycle_dir/auth-failure-issue.md"
    # shellcheck disable=SC2016  # the backticks are the issue body's Markdown, not expansions
    {
      printf '## %s\n\n' "$auth_heading"
      printf -- '- node: `%s`\n- cycle: `%s`\n- %s:\n\n```\n%s\n```\n\n' \
        "$node_name" "$cycle_id" "$auth_detail_label" "$gh_auth_detail"
      printf '%s\n\n' "$auth_remedy"
      printf -- '---\nItem: `auth-failure:%s` · raised by the Script · cycle `%s` · node `%s`\n' \
        "$node_name" "$cycle_id" "$node_name"
    } > "$auth_body"
    if auth_created="$(create_escalation_issue "$crash_loop_repo" "auth-failure:$node_name" \
         "$enabler_escalation_label" \
         "$auth_title" \
         "$auth_body")" && [[ -n "$auth_created" ]]; then
      log_event "auth-failure-escalated" "$(jq -nc \
        --argjson n "${auth_created%%$'\t'*}" --arg u "${auth_created#*$'\t'}" \
        '{issue_number: $n, issue_url: $u}')"
    else
      log_event "warning" "$(jq -nc \
        --arg d "$auth_warning_detail" \
        '{detail: $d}')"
    fi
  fi
  log_event "stand-down" "$(jq -nc --arg r "$gh_auth_reason" --arg d "$gh_auth_detail" \
    '{reason: $r, cause: "unauthorized", detail: $d}')"
  set_node_state_terminal externally-blocked unauthorized
  exit 0
fi

# 2.0c Free disk space (requirement 2.0c, agent-ops#756; both directories,
# agent-ops#992). Free, like 2.0 and 2.0b: `df -Pk` costs nothing and touches
# no network, so it runs ahead of every check below that can spend.
# `scripts/doctor.sh` has read state_dir's and workspace_root's free space and
# warned below a fixed 2 GiB since before this check existed, but a warning
# only a human reads by hand does nothing for the cycle that writes into
# whatever room is actually left. On the ockham laptop that ran short, a write
# truncated mid-flight left zero-length git objects in both nodes' state
# mirrors, permanently disabling `git gc` (#604) — that is state_dir — and
# left 4.2 GB of orphaned clones behind it (#605) — that is workspace_root —
# starting work the host cannot finish is what made both possible, and this
# stands the cycle down before it tries, on either directory.
#
# `min_free_workspace_bytes` set to `0` turns the check off, for both
# directories, regardless of any footprint ever recorded — the same "0 is the
# off switch, unconditionally" convention `github_min_core_budget`/
# `github_min_graphql_budget` use. Otherwise the threshold this gate actually
# reads is not `min_free_workspace_bytes` itself but
# `disk_space_effective_min_bytes`'s derivation over it (agent-ops#904, the
# residual of #756): `max(min_free_workspace_bytes, workspace_headroom_factor
# × the largest clone-footprint this fleet has ever recorded)`, read back
# from `union_log` — already a local, already-fetched read by the time this
# runs, so deriving the threshold costs no network call of its own.
# `min_free_workspace_bytes` is the floor *under* that derivation, never a
# ceiling; with no footprint recorded (a fleet's first cycle, or a union log
# this node cannot read) the floor alone governs. `lib/disk-space.sh` is the
# one place free space is read and judged, so doctor.sh's own advisory
# warning and this gate cannot silently disagree about what "low" means, nor
# about which directories that covers, nor about which bound governed.
# Where state_dir and workspace_root share a filesystem — the common case, one
# home directory holding both — `disk_space_same_filesystem` collapses this to
# the one `df` reading requirement 2.0c always took; a split deployment (the
# shipped `deploy/docker/compose.yaml` mounts them as two separate volumes)
# takes one reading per directory instead.
#
# An unreadable `df` is not a stand-down, the same "no evidence" reasoning
# 2.0's own `unknown` rests on, for either directory: `disk_space_verdict`
# reads it as `ok`.
if (( min_free_workspace_bytes > 0 )); then
  disk_footprint_line=""
  [[ -s "$union_log" ]] && disk_footprint_line="$(disk_space_largest_footprint < "$union_log")"
  if [[ "$disk_footprint_line" == *$'\t'* ]]; then
    disk_footprint_bytes="${disk_footprint_line%%$'\t'*}"
    disk_footprint_repo="${disk_footprint_line#*$'\t'}"
  else
    disk_footprint_bytes=""
    disk_footprint_repo=""
  fi
  disk_effective_min_bytes="$(disk_space_effective_min_bytes \
    "$min_free_workspace_bytes" "$workspace_headroom_factor" "$disk_footprint_bytes")"
  disk_governed_by="$(disk_space_governed_by "$min_free_workspace_bytes" "$disk_effective_min_bytes")"
  disk_standdown_path=""
  disk_standdown_free_kb=""
  if disk_space_same_filesystem "$state_dir" "$workspace_root"; then
    disk_free_kb="$(disk_space_free_kb "$workspace_root")"
    if [[ "$(disk_space_verdict "$disk_free_kb" "$disk_effective_min_bytes")" == "low" ]]; then
      disk_standdown_path="$workspace_root"
      disk_standdown_free_kb="$disk_free_kb"
    fi
  else
    disk_state_dir_free_kb="$(disk_space_free_kb "$state_dir")"
    disk_workspace_free_kb="$(disk_space_free_kb "$workspace_root")"
    disk_state_dir_low="false"
    disk_workspace_low="false"
    [[ "$(disk_space_verdict "$disk_state_dir_free_kb" "$disk_effective_min_bytes")" == "low" ]] \
      && disk_state_dir_low="true"
    [[ "$(disk_space_verdict "$disk_workspace_free_kb" "$disk_effective_min_bytes")" == "low" ]] \
      && disk_workspace_low="true"
    if [[ "$disk_state_dir_low" == "true" && "$disk_workspace_low" == "true" ]]; then
      # Both short: name the one with less free space.
      if (( disk_state_dir_free_kb <= disk_workspace_free_kb )); then
        disk_standdown_path="$state_dir"
        disk_standdown_free_kb="$disk_state_dir_free_kb"
      else
        disk_standdown_path="$workspace_root"
        disk_standdown_free_kb="$disk_workspace_free_kb"
      fi
    elif [[ "$disk_state_dir_low" == "true" ]]; then
      disk_standdown_path="$state_dir"
      disk_standdown_free_kb="$disk_state_dir_free_kb"
    elif [[ "$disk_workspace_low" == "true" ]]; then
      disk_standdown_path="$workspace_root"
      disk_standdown_free_kb="$disk_workspace_free_kb"
    fi
  fi
  if [[ -n "$disk_standdown_path" ]]; then
    if [[ "$disk_standdown_free_kb" =~ ^[0-9]+$ ]] && (( disk_standdown_free_kb == 0 )); then
      disk_standdown_cause="disk-full"
    else
      disk_standdown_cause="disk-low"
    fi
    log_event "stand-down" "$(jq -nc \
      --arg r "$(disk_space_describe "$disk_standdown_path" "$disk_standdown_free_kb" \
        "$disk_effective_min_bytes" "$disk_governed_by" "$disk_footprint_repo" \
        "$disk_footprint_bytes" "$workspace_headroom_factor")" \
      --arg cause "$disk_standdown_cause" --arg path "$disk_standdown_path" --arg free_kb "$disk_standdown_free_kb" \
      --arg governed_by "$disk_governed_by" --argjson min_bytes "$disk_effective_min_bytes" \
      --arg repo "$disk_footprint_repo" --arg footprint_bytes "$disk_footprint_bytes" \
      '{reason: $r, cause: $cause, path: $path, free_kb: $free_kb,
         governed_by: $governed_by, min_bytes: $min_bytes}
       + (if $governed_by == "derived" then {repo: $repo, footprint_bytes: ($footprint_bytes | tonumber)} else {} end)')"
    set_node_state_terminal externally-blocked "$disk_standdown_cause"
    exit 0
  fi
fi

# 2.0f Free host memory (requirement 2.0f). Free, and for the same reason as
# 2.0c immediately above: reading `/proc/meminfo` touches no network and costs
# nothing, so it runs ahead of every check below that can spend. 2.0c stands a
# cycle down when the host is short of disk; nothing did the same for memory,
# and on the ockham WSL2 host that is the half that keeps biting. The VM is
# capped at 6 GiB, both nodes' cycles overlap for most of every hour, and a
# cycle that starts into a host with no headroom pushes the VM into a
# Windows-backed swap file — whereupon the machine stalls, and a git write
# truncated by the stall leaves the zero-length objects that permanently
# disabled `git gc` (#604). A stand-down costs one cycle; the freeze costs the
# host.
#
# MemAvailable, not MemFree, and the host's rather than this cgroup's — see
# lib/memory.sh's header for why each is the right meter. `lib/memory.sh` is
# the one place free memory is read and judged, so doctor.sh's own advisory
# warning and this gate cannot silently disagree about what "low" means.
#
# An unreadable `/proc/meminfo` is not a stand-down, the same "no evidence"
# reasoning 2.0's `unknown` and 2.0c's own gate rest on: `memory_verdict`
# reads it as `ok`.
if (( min_free_memory_bytes > 0 )); then
  memory_free_kb="$(memory_available_kb)"
  if [[ "$(memory_verdict "$memory_free_kb" "$min_free_memory_bytes")" == "low" ]]; then
    log_event "stand-down" "$(jq -nc \
      --arg r "$(memory_describe "$memory_free_kb" "$min_free_memory_bytes")" \
      --arg cause "memory-low" --arg free_kb "$memory_free_kb" \
      --arg total_kb "$(memory_total_kb)" \
      '{reason: $r, cause: $cause, free_kb: $free_kb, total_kb: $total_kb}')"
    set_node_state_terminal externally-blocked memory-low
    exit 0
  fi
fi

# 2.0i Parent-cgroup memory throttle (requirement 2.0i, agent-ops#2469). Free,
# and for the same reason as 2.0c/2.0f immediately above: every value this
# reads is already bind-mounted read-only (the three MEMORY_CGROUP_PARENT_*
# windows 2.0f's own header documents) or sitting in this node's own
# state_dir, no network call of its own. 2.0f protects against the *host's*
# own exhaustion; this protects against the failure 2.0f cannot see at all —
# a node whose *parent* cgroup is throttling it under memory.high while the
# host itself has gigabytes free. `doctor.sh` has warned on this for a long
# time ("it is throttling right now") and nothing ever acted on the warning;
# meanwhile `kill_reason: inactivity` ends a disproportionate share of this
# node's own stages whenever the parent is in this band (agent-ops#2382,
# #1634 name what that kill costs).
#
# `memory_throttle_check` (below, defined at file scope so the function
# exists whether or not this call is ever reached) is called a second time,
# verbatim, immediately before the Co-Ordinator engages (agent-cycle.sh's own
# spine) — this slot alone is stale by the time a model stage actually
# starts, since the gather phase between here and there routinely takes
# longer than the interval a throttle band can open and close in.
memory_throttle_check

# 2.0g Host budget (requirement 2.0g, agent-ops#757). Free, and for the same
# reason as 2.0c/2.0f immediately above: this reads a file already sitting in
# this node's own state_dir, no network and no docker socket of its own (the
# runtime deliberately holds neither, agent-ops#603), so it runs in the same
# band as the other two. 2.0c and 2.0f each protect the host against *this*
# node's own next cycle; neither says anything about the *other* containers
# sharing the same host — the two-Compose-projects-per-host layout
# deploy/docker/compose.yaml's own D14 comment already names, where each
# project sizes its ceilings as though it owned the whole machine. Nothing
# bounded the sum of those ceilings until this check: measured on ockham
# 2026-08-24, six containers each believed they could take the whole 7.457 GiB
# VM, and the host froze repeatedly.
#
# `host_budget_enforce` off (the default) turns this whole check into a
# no-op: the host-facts collector (scripts/collect-host-facts.sh,
# agent-ops#1283) already publishes the sum and its headroom in every
# record regardless, so the figures are visible before anything binds on
# them without this gate refusing a single cycle — "an operator who
# knowingly overcommits a development box should be able to say so once"
# (the issue's own words) is exactly what leaving this off does.
if [[ "$host_budget_enforce" == "true" ]]; then
  # `|| true` is load-bearing, not decoration: agent-cycle.sh sources this
  # file under `set -euo pipefail` and calls `run_standdown_checks` bare, so
  # a `cat` that fails on a record this node has not published yet would
  # abort the whole cycle with 1 here instead of falling through — the
  # opposite of the "no evidence, no stand-down" this block exists to hold
  # to. 2.0c/2.0f have no such hazard only because `disk_space_free_kb`/
  # `memory_available_kb` swallow their own unreadable meter and return 0.
  host_budget_record="$(cat "$state_dir/host-facts/$node_name.json" 2>/dev/null || true)"
  # No fabricated verdict from a record that does not exist yet (a fresh
  # node whose collector has not completed a first pass), does not parse, or
  # predates this feature / carries no compose driver's `budget` section (a
  # Kubernetes node, out of scope — see the issue's own "Why Kubernetes does
  # not close this") — the same "no evidence, no stand-down" reasoning 2.0c's
  # unreadable `df` and 2.0f's unreadable `/proc/meminfo` already rest on.
  if [[ -n "$host_budget_record" ]] && jq -e . >/dev/null 2>&1 <<<"$host_budget_record"; then
    host_budget_summary="$(jq -c '.budget // empty' <<<"$host_budget_record" 2>/dev/null)"
    if [[ -n "$host_budget_summary" && "$host_budget_summary" != "null" ]]; then
      host_budget_mem_declared="$(jq -r '.mem_declared_bytes // 0' <<<"$host_budget_summary")"
      host_budget_mem_total="$(jq -r '.mem_total_bytes // empty' <<<"$host_budget_summary")"
      host_budget_cpu_declared="$(jq -r '.cpu_declared_nanos // 0' <<<"$host_budget_summary")"
      host_budget_cpu_count="$(jq -r '.cpu_count // empty' <<<"$host_budget_summary")"
      host_budget_mem_verdict="$(host_budget_mem_verdict "$host_budget_mem_declared" "$host_budget_mem_total" "$host_budget_reserved_memory_bytes")"
      host_budget_cpu_verdict="$(host_budget_cpu_verdict "$host_budget_cpu_declared" "$host_budget_cpu_count" "$host_budget_reserved_cpus")"
      if [[ "$host_budget_mem_verdict" == "over" || "$host_budget_cpu_verdict" == "over" ]]; then
        log_event "stand-down" "$(jq -nc \
          --arg r "$(host_budget_describe "$host_budget_summary" "$host_budget_reserved_memory_bytes" "$host_budget_reserved_cpus")" \
          --arg cause "host-overcommit" --argjson budget "$host_budget_summary" \
          --arg mem_verdict "$host_budget_mem_verdict" --arg cpu_verdict "$host_budget_cpu_verdict" \
          '{reason: $r, cause: $cause, budget: $budget, mem_verdict: $mem_verdict, cpu_verdict: $cpu_verdict}')"
        set_node_state_terminal externally-blocked host-overcommit
        exit 0
      fi
    fi
  fi
fi

# 2.0h Model credential check (requirement 2.0h, agent-ops#2308). The model
# path has no equivalent of 2.0b above: the first thing that exercises
# ANTHROPIC_API_KEY (or a subscription login) is the Co-Ordinator itself,
# after the GitHub gather, so a refused credential crash-loops every stage
# that follows it. On 2026-10-10 the owner replaced every node's key with one
# minted without a workspace scope, and for eleven hours all four nodes ran
# the Co-Ordinator's full gather, every cycle, before a human traced the
# refusal by hand reading `api_message` off the log (issues #2297/#2298/
# #2299, the crash-loop ladder those nodes' stand-downs filed, all pointed at
# `.out` files inside a container rather than at the API's own words already
# sitting on the event).
#
# It sits here, last of the 2.0 band, rather than beside the 2.0b check it
# otherwise mirrors, because it is the first check that spends: 2.0c, 2.0f
# and 2.0g each run "ahead of every check below that can spend" — their own
# words — and this one writes a probe transcript and its own state file into
# the very `state_dir` 2.0c exists to guard, whose exhaustion left
# zero-length git objects in two nodes' mirrors (#604). Catching a refused
# credential one check earlier buys nothing; starting a spend into a host
# 2.0c would have stood down costs exactly what that band exists to prevent.
#
# One minimal invocation of the trivial model, through the same
# `run_model_stage` 1b's own usage-limit probe below already uses, judged by
# `stage_api_refusal_class` and `stage_api_refusal` together: a `refused`
# verdict whose own token names the credential — `authentication_failed`,
# `workspace_scope_refused`, or a 4xx `api_error_<status>` — stands the cycle
# down exactly as 2.0b's GitHub check does above, with
# `stage_api_refusal_message` (already truncated to 600 bytes) as the reason,
# so the log and the escalation both quote the API's own words rather than a
# bare token. A `transient` verdict (a 5xx, an overload) changes nothing:
# that is 2.1's business, not this check's, the same distinction
# `stage_api_refusal_class` exists to draw (agent-ops#1073). Nor does a
# `refused` verdict carrying any other token: that is a deterministic fault
# in something other than the credential, and 2.7's own crash-loop ladder is
# what reads it.
#
# Gated, unlike 2.0b: a free `/rate_limit` call costs nothing, but this one
# spends a fraction of a cent, so it runs only on the first cycle after this
# container started, or on any cycle whose own last probe here was itself
# refused or inconclusive — a `transient` 5xx/overload, or a crashed or
# timed-out launch, neither of which answered anything about the
# credential — so a healthy node pays this once per container lifetime, and
# an unhealthy or merely-not-yet-answered one keeps being caught cheaply
# rather than crash-looping again until its next restart (agent-ops#2554: an
# inconclusive first probe after a container start used to close this gate
# for the container's whole remaining lifetime, since the state write below
# already recorded that case as an empty, not `"refused"`, verdict).
# "First cycle after this container started" is read
# from `_updater_health_own_started` (lib/updater-health.sh) — this
# container's own PID 1 start time, the same reading
# `deploy/docker/watchtower-pre-update.sh`'s own roll ledger uses, and for
# the same reason: this node's hostname alone survives a watchtower roll
# (agent-ops#1072), so only the kernel's own process-start clock tells a
# fresh boot from a restart-in-place — cached in this node's own `state_dir`
# alongside the last probe's own verdict, so a cycle before the first-ever
# reading (state file absent, or the reading itself unavailable) always
# probes rather than silently comparing two empty strings as unchanged.
# `--dry-run` never probes, the same reasoning 1b's own gate rests on below: a
# cycle that promises to change nothing must not write a fresh escalation.
if ! (( DRY_RUN )); then
  cred_state_file="$state_dir/.credential-preflight.json"
  cred_container_started="$(_updater_health_own_started)"
  cred_prev_started=""
  cred_prev_verdict=""
  if [[ -s "$cred_state_file" ]]; then
    IFS=$'\t' read -r cred_prev_started cred_prev_verdict < <(jq -r \
      '(.container_started // "") + "\t" + (.verdict // "")' \
      "$cred_state_file" 2>/dev/null || printf '\t\n')
  fi
  if [[ ! -s "$cred_state_file" \
        || -z "$cred_container_started" \
        || "$cred_prev_started" != "$cred_container_started" \
        || -z "$cred_prev_verdict" \
        || "$cred_prev_verdict" == "refused" ]]; then
    cred_probe_out="$cycle_dir/credential-probe.out"
    cred_probe_rc=0
    # Drawn once, before the lane (issue #2247), into its own local rather
    # than overwriting `implementer_model_trivial` itself: that global is
    # read by several other files across this same cycle, which want the
    # configured value (or set handle), not whichever member this one probe
    # happened to draw.
    local cred_probe_model
    stage_model_resolve_into cred_probe_model "$implementer_model_trivial" "${cycle_id:-}:credential-probe"
    # 30 s, not 1b's 180 s: a single-word trivial-model reply needs nowhere
    # near that long, and since #2567 this probe can re-run every cycle of a
    # boot that keeps coming back inconclusive — unlike 1b's, which runs at
    # most once per freeze — so its timeout is also the worst-case per-cycle
    # latency a crashed or hung launch costs (agent-ops#2573).
    run_model_stage credential-probe 30 "$cred_probe_model" \
      "Reply with the single word: ok" "$cred_probe_out" "$cycle_dir" || cred_probe_rc=$?
    cred_probe_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # The probe's own spend, joined into the fleet-wide ledger like every
    # other launch through run_model_stage (issue #2239, D30), the same way
    # 1b's own limit-probe stage-end does fifty lines below: it never had a
    # stage-start, but it is still a real invocation that spent real tokens,
    # and without this event that spend would be invisible to log.jsonl even
    # though the cost scan always saw it in the transcript itself.
    # `lib/stage-health.sh`'s own stage list does not name
    # "credential-probe", so this carries no verdict risk for it.
    log_event "stage-end" "$(jq -nc --argjson rc "$cred_probe_rc" --arg kr "$stage_kill_reason" \
      --argjson m "$(metering_fields "$cred_probe_model" "$cred_probe_out" "$stage_gaps_json" "$stage_lane_json")" \
      '{stage: "credential-probe", exit_code: $rc} + (if $kr == "" then {} else {kill_reason: $kr} end) + $m')"
    cred_class="$(stage_api_refusal_class "$cred_probe_out")"
    cred_token="$(stage_api_refusal "$cred_probe_out")"
    # Both halves, exactly as the requirement states them: a `refused` class
    # *and* a token naming the credential itself. The class alone is too
    # broad — `stage_api_refusal_class`'s default arm deliberately grades
    # every unrecognised deterministic refusal `refused`, `credit_exhausted`
    # among them (`lib/substrate-grok-build.sh` synthesises that one for a
    # billing lapse), and standing a node down as `credential-refused` over
    # an exhausted balance would send the next reader at the key rather than
    # the account. The same gate `crash_loop_escalate`'s own credential hint
    # and `scripts/doctor.sh`'s unattended pass apply, so all three readers
    # name a credential fault by the same rule.
    if [[ "$cred_class" == "refused" ]] \
       && [[ "$cred_token" == "authentication_failed" \
             || "$cred_token" == "workspace_scope_refused" \
             || "$cred_token" =~ ^api_error_4[0-9][0-9]$ ]]; then
      cred_message="$(stage_api_refusal_message "$cred_probe_out")"
      jq -nc --arg s "$cred_container_started" '{container_started: $s, verdict: "refused"}' \
        > "$cred_state_file" 2>/dev/null || true
      cred_reason="The model credential was refused by the API — $cred_message"
      if [[ -n "$crash_loop_repo" && -n "$enabler_assignee" ]]; then
        cred_body="$cycle_dir/credential-refused-issue.md"
        # shellcheck disable=SC2016  # the backticks are the issue body's Markdown, not expansions
        {
          printf '## This node'"'"'s model credential was refused\n\n'
          printf -- '- node: `%s`\n- cycle: `%s`\n- the API'"'"'s own response:\n\n```\n%s\n```\n\n' \
            "$node_name" "$cycle_id" "$cred_message"
          printf 'Nothing clears this automatically — replace or remove `ANTHROPIC_API_KEY` in `.env`, or complete the subscription login, then `docker compose up -d`, and the next cycle proceeds normally.\n\n'
          printf -- '---\nItem: `credential-refused:%s` · raised by the Script · cycle `%s` · node `%s`\n' \
            "$node_name" "$cycle_id" "$node_name"
        } > "$cred_body"
        if cred_created="$(create_escalation_issue "$crash_loop_repo" "credential-refused:$node_name" \
             "$enabler_escalation_label" \
             "Model credential rejected on node $node_name" \
             "$cred_body")" && [[ -n "$cred_created" ]]; then
          log_event "credential-refused-escalated" "$(jq -nc \
            --argjson n "${cred_created%%$'\t'*}" --arg u "${cred_created#*$'\t'}" \
            '{issue_number: $n, issue_url: $u}')"
        else
          log_event "warning" "$(jq -nc \
            --arg d "model credential refused but the escalation issue could not be filed — will retry next cycle" \
            '{detail: $d}')"
        fi
      fi
      log_event "stand-down" "$(jq -nc --arg r "$cred_reason" --arg d "$cred_message" --arg t "$cred_token" \
        '{reason: $r, cause: "credential-refused", detail: $d, token: $t}')"
      set_node_state_terminal externally-blocked credential-refused
      exit 0
    fi
    # Retirement, the credential-refused analogue of `crash_loop_retire_
    # resolved` (lib/enabler.sh) — but per node rather than fleet-wide, since
    # this escalation is filed per node and only that node's own probe can
    # speak to whether it has cleared (agent-ops#2311 is not a hazard here: a
    # staggered fleet recovery just means each node retires its own
    # escalation on its own probe, never a peer's). `cred_class` empty (not
    # `refused`, and not `transient` — a 5xx or an overload answers nothing
    # about the credential) alongside `cred_probe_rc == 0` is what tells a
    # genuine clean reply from both a credential refusal *and* a probe that
    # never produced a considered answer at all (a crashed or timed-out
    # launch, whose empty output also reads as `cred_class == ""`).
    #
    # The state write below only ever advances `cred_prev_verdict` to `"ok"`
    # on a genuine clean reply — never unconditionally, as it did before
    # #2511. Mirroring the filing side's own ordering (requirement-2.0h
    # above, "will retry next cycle"): a transient 5xx or a crashed probe
    # right after a `refused` verdict leaves the state untouched, so
    # `cred_prev_verdict` is still `"refused"` on the next probe and a later
    # genuinely clean reply still satisfies the comparison below rather than
    # having already been clobbered to a clean-looking value (case (c)). And
    # when the clean reply *is* the one that should retire a `refused`
    # verdict, the state only advances to `"ok"` if the retirement itself
    # actually succeeded — a failed lookup or a failed `gh issue close`
    # (cases (a)/(b)) leaves `cred_prev_verdict` at `"refused"` so the next
    # cycle retries the close instead of forfeiting it for the container's
    # whole remaining lifetime.
    #
    # The default itself must not survive a boot-id change unless it is
    # `"refused"` (agent-ops#2554, review round 2): an `"ok"` verdict answers
    # only for the boot that earned it, so carrying it onto a new boot's own
    # inconclusive first probe would close that new boot's gate on a
    # verdict it never itself confirmed — exactly the restart case this
    # paragraph's own reasoning above does not cover. `"refused"` is kept
    # across the boot change regardless, because that is the one verdict an
    # open escalation is still waiting on; losing it to a reset would leave
    # the escalation's eventual retirement unreachable.
    if [[ "$cred_prev_started" == "$cred_container_started" \
          || "$cred_prev_verdict" == "refused" ]]; then
      cred_new_verdict="$cred_prev_verdict"
    else
      cred_new_verdict=""
    fi
    if (( cred_probe_rc == 0 )) && [[ -z "$cred_class" ]]; then
      if [[ "$cred_prev_verdict" == "refused" ]] && [[ -n "$crash_loop_repo" ]]; then
        if credential_refused_retire_resolved "$crash_loop_repo" "$node_name" "$cycle_id" "$cred_probe_ts"; then
          cred_new_verdict="ok"
        else
          cred_new_verdict="refused"
        fi
      else
        cred_new_verdict="ok"
      fi
    fi
    jq -nc --arg s "$cred_container_started" --arg v "$cred_new_verdict" \
      '{container_started: $s, verdict: $v}' > "$cred_state_file" 2>/dev/null || true
  fi
fi

# 2.1 Usage-limit cooldown (fleet-wide: every node shares one Claude account,
# so a limit any node hit stands this one down too). Two carriers of the same
# signal, and the later resume wins: the log union is as fresh as the last
# state-sync fetch, while fleet/limit.json is read live — it is what lets a
# limit one node hit a minute ago stop this cycle now, not a fetch interval
# from now. Either carrier can be retired early — automatically by the probe
# of 2.1b below when the resume time is this system's own guess, or by hand
# with `--clear-limit` (2.1) — and both retirements work the same way: the
# union's reduction honours a `limit-cleared` event, and the flag is deleted
# outright.
#
# Both records are carried whole rather than reduced to a timestamp, so the
# logged reason can say whether `resume_at` is a stated reset or this system's
# own guess. Reporting a guess as a deadline is what let a stale stand-down
# outlive the limit that caused it and go unquestioned.
#
# The union is read once, by `limit_union_state` (lib/limit-detect.sh), for
# everything this check needs from it: the governing hit here, and the
# freeze's start and escalation memory for the escalation below. The read
# skips a line that does not parse, so it fails only when it could not read
# at all (jq killed, say). That is reported rather than taken for "no limit
# in force" (#2037), and a union the snapshot could not build
# (`union_build_ok`, reported there) is treated exactly the same way without
# being read: the flag carrier decides on its own, as it does when the union
# simply holds no live hit, and `union_state_ok` tells the escalation that
# the union's answers are unknown rather than empty.
union_state='{"record":null,"since":null,"escalated":[]}'
union_state_ok=1
if ! (( union_build_ok )); then
  union_state_ok=0
elif [[ -s "$union_log" ]]; then
  union_state="$(limit_union_state < "$union_log" 2>&1)" \
    || { guard_warn "cycle:union_record" "$union_state"; union_state=""; union_state_ok=0; }
fi
union_record=""
if (( union_state_ok )); then
  union_record="$(jq -c '.record // empty' <<<"$union_state" 2>&1)" \
    || { guard_warn "cycle:union_record" "$union_record"; union_record=""; union_state_ok=0; }
fi
governing="$(limit_later_record "$union_record" "$(fleet_flag_fetch "$state_repo" "$state_dir" limit)")"
[[ -n "$governing" ]] || governing='{}'
resume_at="$(jq -r '.resume_at // empty' <<<"$governing" 2>/dev/null || true)"
resume_epoch=0
if [[ -n "$resume_at" ]]; then
  # TD-PPagop-26081407: `governing` is fleet state read across nodes above
  # (test 1); epoch 0 reads as "already expired" (test 2) -- the gate this
  # feeds decides whether the whole fleet stands down for an active limit.
  resume_epoch="$(date -d "$resume_at" +%s 2>&1)" \
    || { guard_warn "cycle:resume_epoch" "$resume_epoch"; resume_epoch=0; }
fi
now_epoch="$(date +%s)"
if (( resume_epoch > now_epoch )); then
  governing_class="$(jq -r '.class // "other"' <<<"$governing" 2>&1)" \
    || { guard_warn "cycle:governing_class" "$governing_class"; governing_class=other; }
  governing_known="$(limit_reset_known "$governing")"
  # Absent means auto: every record this system writes is a detector's, and
  # says so; `manual` only ever enters by an operator's hand. The distinction
  # is load-bearing in both directions (requirement 2; #244) — an automatic
  # stand-down may be probed and cleared early, a manual one must never be.
  governing_kind="$(jq -r '.kind // "auto"' <<<"$governing" 2>&1)" \
    || { guard_warn "cycle:governing_kind" "$governing_kind"; governing_kind=auto; }
  standing=1
  probe_note=""
  # 2.1b The estimated stand-down probes its own exit. When `reset_known` is
  # false, `resume_at` is this system's invented time and carries no
  # information about the limit — and the observed spend-cap message is
  # emitted equally when a 5-hour session window meets an exhausted cap,
  # which clears at the session rollover, most of a day before the invented
  # time (it did, on 2026-07-28: both hits cleared within the hour; the fleet
  # would have slept 24). So instead of sleeping on a guess, spend one
  # minimal invocation of the cheapest model asking the only authority there
  # is. The economics run the right way round on both sides: a limited
  # account answers the probe with the limit message at no token cost, and an
  # unlimited one answers for a fraction of a cent, once — the first clear
  # verdict retires the stand-down for the whole fleet, and the gate stops
  # firing. A *stated* reset is never probed: the message named the time, and
  # asking earlier is the one spend that buys nothing. Nor does --dry-run
  # probe: a cycle that promises to change nothing must not write
  # `limit-cleared`, and a probe whose verdict it would have to ignore is
  # pure cost. And a *manual* record is never probed at all: it is an
  # operator's decision, not a detector's inference, and no probe verdict is
  # evidence about whether the human still means it (#244).
  if [[ "$governing_kind" != "manual" && "$governing_known" != "true" ]] && ! (( DRY_RUN )); then
    probe_out="$cycle_dir/limit-probe.out"
    probe_rc=0
    # Drawn once, before the lane (issue #2247) — see the identical comment
    # on the credential probe above.
    local limit_probe_model
    stage_model_resolve_into limit_probe_model "$implementer_model_trivial" "${cycle_id:-}:limit-probe"
    run_model_stage limit-probe 180 "$limit_probe_model" \
      "Reply with the single word: ok" "$probe_out" "$cycle_dir" || probe_rc=$?
    # The probe's own spend, joined into the fleet-wide ledger like every
    # other launch through run_model_stage (issue #2239, D30) — it never had
    # a stage-start, like 2.0h's own credential probe above, which requirement
    # 33 names beside it, but it is still a real invocation that spent real
    # tokens, and until this event existed that spend was invisible to
    # log.jsonl even though the cost scan always saw it in the transcript
    # itself. `lib/stage-health.sh`'s own stage list does not name
    # "limit-probe", so this carries no verdict risk for it.
    log_event "stage-end" "$(jq -nc --argjson rc "$probe_rc" --arg kr "$stage_kill_reason" \
      --argjson m "$(metering_fields "$limit_probe_model" "$probe_out" "$stage_gaps_json" "$stage_lane_json")" \
      '{stage: "limit-probe", exit_code: $rc} + (if $kr == "" then {} else {kill_reason: $kr} end) + $m')"
    probe_verdict="$(limit_probe_verdict "$(cat "$probe_out" 2>/dev/null || true)" \
      "$(cat "$probe_out.stderr" 2>/dev/null || true)")"
    case "$probe_verdict" in
      clear)
        # The same two carriers --clear-limit retires, for the same reason it
        # retires both: the stand-down lifts only when the later of the two
        # says so. The `limit-cleared` event outranks every earlier hit in
        # the union's reduction; the flag is deleted because
        # fleet_limit_publish is extend-only and delete is the one write that
        # legitimately moves a resume earlier.
        log_event "limit-cleared" "$(jq -nc --arg w "$resume_at" \
          --arg by "auto-probe@$node_name" --arg n "$node_name" \
          '{was: $w, reason: "probe answered: the limit behind this estimated stand-down is gone", by: $by, actor: $n, kind: "auto"}')"
        notify_post_cycle "fleet-standdown-end" "standdown:usage-limit" \
          "Usage-limit cooldown lifted" "" "" \
          "probe answered: the limit behind this estimated stand-down (resume was $resume_at) is gone"
        # node-state (docs/reference/flow-schema.md, D21): the fleet-wide block just
        # lifted and this cycle continues past this point — an immediate
        # transition, not a terminal one (this call does not exit).
        log_node_state_transition overhead
        if [[ -n "$state_repo" ]]; then
          # >/dev/null: fleet_flag_delete now prints which of "deleted"/
          # "absent" it was (issue #426); this site only reads the return
          # code, and the raw word must not leak into the cycle's own stdout.
          fleet_flag_delete "$state_repo" "$state_dir" limit >/dev/null || log_event "warning" \
            '{"detail": "could not clear fleet/limit.json after a clear probe — peers reading it live stand down until their own probes answer"}'
        fi
        standing=0
        ;;
      limited)
        # The probe just observed the limit live, which is worth recording
        # for two reasons: the Enabler must not be engaged from the exit trap
        # moments after a limit was re-confirmed (requirement 35's guards),
        # and the probe's transcript may state what the original message did
        # not — a parseable reset upgrades `reset_known` to true and stops
        # the probing until a time that is finally real.
        detect_and_log_limit_hit "$probe_out" || true
        probe_note=" (probe: still limited)"
        ;;
      *)
        probe_note=" (probe: inconclusive)"
        ;;
    esac
  fi
  if (( standing )); then
    if [[ "$governing_kind" == "manual" ]]; then
      # An operator's stand-down explains itself and is honoured as written:
      # no probe ran above, nothing here clears it, and it ends at its own
      # resume_at or when the human runs --clear-limit (#244).
      governing_actor="$(jq -r '.actor // .node // "?"' <<<"$governing" 2>&1)" \
        || { guard_warn "cycle:governing_actor" "$governing_actor"; governing_actor='?'; }
      standdown_reason="manual stand-down until $resume_at, set by $governing_actor — never probed or auto-cleared; 'agent-cycle.sh --clear-limit' lifts it early"
    else
      standdown_reason="usage-limit cooldown $(limit_describe "$resume_at" \
        "$governing_class" "$governing_known")$probe_note"
      # #244: a long-running *automatic* fleet-wide freeze is put in front of
      # a human — the operator did not choose it, so nobody is watching it —
      # while a manual stand-down never pages the person who set it. Aged
      # from the start of the current freeze (`since`, from the union read
      # above), not from its latest extension, and raised once per freeze:
      # the `limit-freeze-escalated` events in the union (`escalated`) are the
      # memory, and create_escalation_issue's open-issue guard catches the
      # cross-node race the union has not yet carried.
      #
      # When the union could not be built or read, whether this freeze was
      # already escalated cannot be told, so nothing is filed this cycle and
      # a `warning` says so; the next cycle tries again. Filing anyway would
      # rest on the open-issue guard alone, which a closed escalation passes.
      #
      # When the union was read but holds no live hit — the stand-down rests
      # on fleet/limit.json alone — the freeze is aged from the governing
      # record's own `ts` instead, which is the flag record's time: when
      # `fleet_limit_publish` (lib/toggle.sh) last wrote it, and since it
      # rewrites `ts` on every extension, the latest extension rather than
      # the freeze's start. That time is the escalation's key and its
      # `since`. A record with no usable `ts` is reported, and the age test
      # skipped, rather than fed to GNU `date -d ""`, which answers midnight
      # today with status 0 — a freeze that would always read under a day
      # old (#2037).
      if (( limit_escalate_after_hours > 0 )) && ! (( DRY_RUN )) \
         && [[ -n "$crash_loop_repo" && -n "$enabler_assignee" ]]; then
        freeze_since=""
        freeze_basis="union"
        if ! (( union_state_ok )); then
          log_event "warning" "$(jq -nc \
            --arg d "automatic usage-limit freeze: the fleet log union could not be built or read this cycle, so whether this freeze was already escalated cannot be told; the escalation is not filed this cycle, and the next cycle tries again" \
            '{detail: $d}')"
        else
          freeze_since="$(jq -r '.since // empty' <<<"$union_state" 2>&1)" \
            || { guard_warn "freeze_since" "$freeze_since"; freeze_since=""; union_state_ok=0; }
          if (( union_state_ok )) && [[ -z "$freeze_since" ]]; then
            freeze_basis="flag"
            freeze_since="$(jq -r 'if (.ts | type) == "string" and .ts != "" then .ts
                else error("fleet/limit.json governs this freeze but records no ts, so its age cannot be told; the age test is skipped this cycle") end' \
                <<<"$governing" 2>&1)" \
              || { guard_warn "freeze_since:flag" "$freeze_since"; freeze_since=""; }
          fi
        fi
        if [[ -n "$freeze_since" ]]; then
          freeze_epoch="$(date -d "$freeze_since" +%s 2>&1)" \
            || { guard_warn "freeze_epoch" "$freeze_epoch"; freeze_epoch=0; }
          freeze_done="$(jq -r --arg s "$freeze_since" \
              'if ([.escalated[] | select(. == $s)] | length) > 0 then "escalated" else "" end' <<<"$union_state" 2>&1)" \
            || { guard_warn "freeze_done" "$freeze_done"; freeze_done="unknown"; }
          if [[ -z "$freeze_done" ]] && (( freeze_epoch > 0 )) \
             && (( now_epoch - freeze_epoch >= limit_escalate_after_hours * 3600 )); then
            freeze_body="$cycle_dir/limit-freeze-issue.md"
            if [[ "$freeze_basis" == "flag" ]]; then
              freeze_since_note="$freeze_since, the time fleet/limit.json was last written (it is rewritten on every extension, so this is the latest extension; the fleet log union holds no limit-hit for this freeze)"
            else
              freeze_since_note="$freeze_since"
            fi
            # shellcheck disable=SC2016  # the backticks are the issue body's Markdown, not expansions
            {
              printf '## The fleet has been standing down automatically since %s\n\n' "$freeze_since_note"
              printf 'Every cycle since then has stood down on an automatic usage-limit record, and the freeze has now outlived `limit_escalate_after_hours` (%s h). The governing record:\n\n' "$limit_escalate_after_hours"
              printf '```json\n%s\n```\n\n' "$governing"
              printf 'If the limit is real, nothing is needed — the stand-down ends at its own resume time, and each cycle keeps probing an estimated one. If it has lapsed or was misread, `agent-cycle.sh --clear-limit <reason>` lifts it fleet-wide.\n\n'
              printf -- '---\nItem: `usage-limit-freeze:%s` · raised by the Script · cycle `%s` · node `%s`\n' \
                "$freeze_since" "$cycle_id" "$node_name"
            } > "$freeze_body"
            if freeze_created="$(create_escalation_issue "$crash_loop_repo" \
                 "usage-limit-freeze:$freeze_since" "$enabler_escalation_label" \
                 "Usage-limit freeze: the fleet has stood down automatically since $freeze_since" \
                 "$freeze_body")" && [[ -n "$freeze_created" ]]; then
              log_event "limit-freeze-escalated" "$(jq -nc \
                --argjson n "${freeze_created%%$'\t'*}" --arg u "${freeze_created#*$'\t'}" \
                --arg s "$freeze_since" --arg b "$freeze_basis" \
                '{issue_number: $n, issue_url: $u, since: $s, since_basis: $b}')"
            else
              log_event "warning" "$(jq -nc \
                --arg d "automatic usage-limit freeze since $freeze_since exceeds ${limit_escalate_after_hours}h but the escalation issue could not be filed — will retry next cycle" \
                '{detail: $d}')"
            fi
          fi
        fi
      fi
    fi
    log_event "stand-down" "$(jq -nc --arg r "$standdown_reason" '{reason: $r, cause: "usage-limit"}')"
    notify_post_cycle "fleet-standdown-begin" "standdown:usage-limit" \
      "Usage-limit cooldown in effect" "" "" "$standdown_reason"
    set_node_state_terminal externally-blocked usage-limit
    exit 0
  fi
fi

# 2.1a Claim GC — sweep registry entries older than claim_ttl_hours (17a).
# Every node runs it, because it needs no coordination: a registry delete is
# sha-guarded, and a claim branch is deleted only if it is unmoved AND has no
# PR, so the worst race outcome is a no-op. Runs before 2.2 so the count
# there does not include entries this sweep just retired. Skipped on
# --dry-run: a cycle that promises to change nothing must not delete refs.
if ! (( DRY_RUN )); then
  "$SCRIPT_DIR/lib/claim.sh" gc >>"$cycle_dir/claim.log" 2>&1 || true
fi

# 2.1b Orphan-branch sweep (requirement 17b) — the state the gc above leaves
# behind on purpose. Retiring a moved branch's registry entry while keeping
# its ref is right for the work (pushed commits are never deleted) and wrong
# for the item: with no PR, nothing ever finds those commits again, every
# later claim 422s against the live ref, and the Co-Ordinator's exclusion
# reads it as "claimed, skip" — the item is wedged and nothing has said so.
# The sweep turns each provable orphan back into a state the pipeline already
# handles: a draft PR the abandoned-drafts source recovers, or (for a ref
# with nothing on it) no ref at all. Every node runs it, like the gc and for
# the same reason: GitHub rejects a second PR for the same head and a second
# ref delete is a no-op, so the worst race outcome is a warning. Fleet-wide
# like the gc, regardless of --repo. Skipped on --dry-run: the sweep opens
# PRs and deletes refs.
if ! (( DRY_RUN )); then
  while IFS= read -r sweep_slug; do
    [[ -n "$sweep_slug" ]] || continue
    while IFS= read -r sweep_action; do
      [[ -n "$sweep_action" ]] || continue
      case "$(jq -r '.action // ""' <<<"$sweep_action" 2>/dev/null || true)" in
        recovered) log_event "orphan-branch-recovered" \
          "$(jq -c --arg r "$sweep_slug" '{repo: $r} + del(.action)' <<<"$sweep_action")" ;;
        released)  log_event "orphan-branch-released" \
          "$(jq -c --arg r "$sweep_slug" '{repo: $r} + del(.action)' <<<"$sweep_action")" ;;
        deferred|warning) log_event "warning" "$(jq -c --arg r "$sweep_slug" \
          '{detail: ("orphan-branch sweep (" + $r + "): " + (del(.repo) | tostring))}' \
          <<<"$sweep_action")" ;;
      esac
    done < <(timeout 120 "$SCRIPT_DIR/scripts/sweep-orphan-branches.sh" "$sweep_slug" \
               2>>"$cycle_dir/orphan-sweep.err" || true)
  done < <(jq -r '.repos[].slug' "$CONFIG_FILE" 2>/dev/null || true)
fi

# 2.1c Post-merge closing-keyword sweep (requirement 17c) — the backstop for
# requirement 25a's CI check: a merged, `pr_label`-labelled pull request that
# named an issue (the `agent-ops:closes-issue` marker, requirement 23b) but
# never carried a real closing keyword leaves that issue open forever, to be
# re-selected and re-voided by every cycle that reaches it (issue #240; PR
# #206's "Implements #198" kept #198 open three days after its own fix
# merged). Cheap and bounded — scripts/sweep-closed-issues.sh examines only
# the most recently updated merged PRs per repo — and idempotent by
# construction: it only ever acts on an issue GitHub itself still reports
# open. Fleet-wide like 2.1a/2.1b, regardless of --repo. Skipped on
# --dry-run: the sweep closes issues.
#
# The same sweep also retires any open `pr-<n>-approver-adjudication`
# escalation issue (requirement 8c) it finds merged — `approver-escalation-
# retired` below, `cause: "merged"` — the other half of requirement 8c's own
# `land`-path retirement in `lib/approver.sh`, for a pull request that merged
# some other way (agent-ops#1215).
if ! (( DRY_RUN )); then
  while IFS= read -r sweep_slug; do
    [[ -n "$sweep_slug" ]] || continue
    while IFS= read -r sweep_action; do
      [[ -n "$sweep_action" ]] || continue
      case "$(jq -r '.action // ""' <<<"$sweep_action" 2>/dev/null || true)" in
        closed) log_event "issue-closed-post-merge" \
          "$(jq -c --arg r "$sweep_slug" '{repo: $r, item: (.issue | tostring)} + del(.action)' <<<"$sweep_action")" ;;
        merge-observed) log_event "merge-observed" \
          "$(jq -c --arg r "$sweep_slug" '{repo: $r, stage: "sweep-closed-issues"} + del(.action)' <<<"$sweep_action")" ;;
        approver-escalation-retired) log_event "approver-escalation-retired" \
          "$(jq -c --arg r "$sweep_slug" '{repo: $r} + del(.action)' <<<"$sweep_action")" ;;
        deferred|warning) log_event "warning" "$(jq -c --arg r "$sweep_slug" \
          '{detail: ("closed-issue sweep (" + $r + "): " + (del(.repo) | tostring))}' \
          <<<"$sweep_action")" ;;
      esac
    done < <(timeout 120 "$SCRIPT_DIR/scripts/sweep-closed-issues.sh" "$sweep_slug" "$node_name" "$cycle_id" "$state_dir" \
               2>>"$cycle_dir/closed-issue-sweep.err" || true)
  done < <(jq -r '.repos[].slug' "$CONFIG_FILE" 2>/dev/null || true)
fi

# 2.1d Human-visibility sweep (requirement 38) — the periodic half of the same
# guarantee requirement 38a keeps at the moment of handoff: every open, ready
# pull request this system raised gets a live review request whether or not
# any stage touched it this cycle, and an approved, mergeable, green one idle
# past `human_nudge_idle_hours` gets one nudge comment. Fleet-wide like the
# sweeps above and for the same reason — a review request or a comment either
# lands or it does not, so two nodes sweeping at once cost nothing but a
# redundant read. Skipped on --dry-run: the sweep requests reviews and posts
# comments.
#
# Its actions get their own event names rather than borrowing `pr-ready`, for
# the same reason 2.1b's do: the Publisher's outcome ladder reads `pr-ready` as
# "this cycle got a pull request to ready" and ranks it above every other
# reading, so a sweep that re-asked for a review on some other repo's
# long-since-ready pull request would rewrite the outcome of a cycle that stood
# down or selected nothing.
#
# Its `warning` events are appended into `union_log` the moment the sweep
# finishes (below), the same technique requirement 34j's own reconciliation
# uses to see its own cycle's freshly-logged events: `human_visibility_json`,
# computed later this cycle from `union_log` (requirement 38e), must see a
# violation this very sweep just found, not only one a previous cycle logged —
# otherwise the human-visibility hygiene pass a few hundred lines below would
# never catch what its own cycle's sweep just discovered, and the violation
# would sit one full cycle behind its own detection for no reason.
if ! (( DRY_RUN )); then
  log_lines_before="$(wc -l < "$log_file" 2>&1)" \
    || { guard_warn "log_lines_before" "$log_lines_before"; log_lines_before=0; }
  while IFS= read -r sweep_slug; do
    [[ -n "$sweep_slug" ]] || continue
    while IFS= read -r sweep_action; do
      [[ -n "$sweep_action" ]] || continue
      case "$(jq -r '.action // ""' <<<"$sweep_action" 2>/dev/null || true)" in
        human-review-requested) log_event "human-review-requested" \
          "$(jq -c --arg r "$sweep_slug" '{repo: $r} + del(.action)' <<<"$sweep_action")" ;;
        nudged) log_event "human-nudged" "$(jq -c --arg r "$sweep_slug" \
          '{repo: $r} + del(.action)' <<<"$sweep_action")" ;;
        dequeue-notice) log_event "human-dequeue-notice" "$(jq -c --arg r "$sweep_slug" \
          '{repo: $r} + del(.action)' <<<"$sweep_action")" ;;
        warning) log_event "warning" "$(jq -c --arg r "$sweep_slug" \
          '{detail: ("human-visibility sweep (" + $r + "): " + (del(.action) | tostring))}' \
          <<<"$sweep_action")" ;;
      esac
    done < <(timeout 120 "$SCRIPT_DIR/scripts/sweep-human-visibility.sh" "$sweep_slug" "$cycle_id" "$node_name" "$union_log" \
               2>>"$cycle_dir/human-visibility-sweep.err" || true)
  done < <(jq -r '.repos[].slug' "$CONFIG_FILE" 2>/dev/null || true)
  tail -n "+$(( log_lines_before + 1 ))" "$log_file" >> "$union_log" 2>/dev/null || true
fi

# Approver restale sweep (requirement 46, agent-ops#682) — a pull request the
# Approver refused whose own review has since gone stale (the Implementer
# answered it and pushed, but the cycle that pushed never lived long enough
# to reach its own Reviewer-then-Approver continuation) otherwise sits behind
# GitHub's own `requested_reviewers`, which silently no-ops for the
# Approver's Bot identity and so can never itself clear it — see
# `_approver_restale_sweep_repo`'s own header for the full candidate rule.
# Fleet-wide regardless of `--repo`, same as every sweep in this section: any
# repository at `merge_autonomy` above `human` may have one. Run before the
# landing-retry sweep below on purpose — a pull request this sweep freshly
# re-approves becomes exactly the standing-`APPROVED` candidate that sweep's
# own precondition looks for, so a genuine fix can clear both gaps in the one
# cycle that finds it rather than waiting a further cycle for the second.
# Skipped on `--dry-run`: it can post a review, dismiss one, or escalate.
if ! (( DRY_RUN )); then
  if restale_login="$(approver_token_identity_login "")" && [[ -n "$restale_login" ]]; then
    while IFS= read -r restale_slug; do
      [[ -n "$restale_slug" ]] || continue
      _approver_restale_sweep_repo "$restale_slug" "$restale_login"
    done < <(jq -r '.repos[].slug' "$CONFIG_FILE" 2>/dev/null || true)
  fi
fi

# 2.1e Landing-retry sweep (TD-PPagop-26081701) — the tracked gap "## The
# Landing Gate" and requirement 8d gate 5 both name: a pull request the
# arming step already approved once, but could not land for a reason that
# can change without the pull request itself changing (the merge budget
# resetting, the kill switch or a per-repo freeze lifting, a
# `merge_autonomy`/`merge_autonomy_routine_sources` config change, a
# transient unreadable, a red required check going green), otherwise sits
# there until a human merges it by hand — forever, for the fail-closed
# unreadables. `_landing_retry_sweep_repo` (below) re-enters
# `_landing_stage_attempt`'s own seven gates verbatim for each candidate (RETRY
# set), rather than a second copy of them. Fleet-wide like the sweeps above,
# regardless of --repo: any repository at `agent-merges-routine` or above may
# have a stranded, Approver-approved pull request waiting. Skipped on
# --dry-run: it can land a pull request. `approver_token_identity_login` is
# asked once, fleet-wide (the Approver App's own login does not vary by
# repository), rather than once per repository as `_landing_stage_attempt`'s
# own gate 4 already does per pull request — an unreadable login here means
# nothing in the sweep can confirm a standing review, so the whole sweep is
# skipped for the cycle rather than every repository paying for the same
# unreadable credential.
if ! (( DRY_RUN )); then
  if retry_login="$(approver_token_identity_login "")" && [[ -n "$retry_login" ]]; then
    while IFS= read -r sweep_slug; do
      [[ -n "$sweep_slug" ]] || continue
      _landing_retry_sweep_repo "$sweep_slug" "$retry_login"
    done < <(jq -r '.repos[].slug' "$CONFIG_FILE" 2>/dev/null || true)
  fi
fi

# 2.1f Classifier-escape audit (D18 Stage 2 exit criterion "zero classifier
# escapes"; agent-ops#572) — nothing above re-checks the *outcome* of a
# landing, only the decision that produced it: `scripts/detect-classifier-
# escapes.sh` is the independent, read-only audit, deliberately reimplementing
# `lib/landing.sh`'s protected-path list and never calling `landing_eligible`
# (its own header explains why), rather than being sourced or trusted the
# way `_landing_retry_sweep_repo` above reuses the real gates verbatim — an
# audit that shared the code it exists to check could not catch a bug in
# that shared code. Same sweep shape as `scripts/sweep-human-visibility.sh`
# (above): stdout is one JSON object per newly-audited pull request, this
# loop is what actually appends anything to the log — a standalone script
# never may, per requirement 33's single-writer rule. Fleet-wide regardless
# of `--repo`, and safe on `--dry-run`: it never arms or lands anything,
# only reads GitHub's own merged-PR record and the fleet log. Run every
# cycle rather than gated on `merge_autonomy`: idempotent against its own
# prior findings (LOG_FILE) for any pull request this repository has already
# produced a `classifier-escape`/`landing-audit`/`landing-audit-skip` event
# for, regardless of who merged it — a repository sitting below
# `agent-merges-routine`, where a merge under the Approver identity is rare
# or never happens, still pays the one `repos/SLUG/pulls/N` read each such
# pull request needs to learn who merged it, but only once: that fact is
# recorded (as `outcome: "not-approver"`, logged below as
# `landing-audit-skip`) exactly like an audited landing is, so it is never
# paid again on a later cycle. `timeout 120` bounds what a single cycle
# spends on this either way, and while a repository with a large backlog of
# never-yet-recorded pull requests may need several cycles to work through
# it, each cycle's budget goes further than the last rather than being
# pinned at a permanent frontier — see the script's own "Idempotency"
# section for what oldest-first candidate order buys and for the size of
# that backlog on this repository as of 2026-08-22. The same
# unreadable-login skip the retry sweep above uses applies here too — with
# no Approver identity to test `merged_by` against, nothing below could
# tell an autonomous landing apart from a human's own merge.
if escape_login="$(approver_token_identity_login "")" && [[ -n "$escape_login" ]]; then
  while IFS= read -r escape_slug; do
    [[ -n "$escape_slug" ]] || continue
    escape_log_lines_before="$(wc -l < "$log_file" 2>&1)" \
      || { guard_warn "escape_log_lines_before" "$escape_log_lines_before"; escape_log_lines_before=0; }
    while IFS= read -r escape_action; do
      [[ -n "$escape_action" ]] || continue
      case "$(jq -r '.outcome // ""' <<<"$escape_action" 2>/dev/null || true)" in
        escape) log_event "classifier-escape" "$(jq -c 'del(.outcome)' <<<"$escape_action")" ;;
        clean|unverifiable) log_event "landing-audit" "$(jq -c '.' <<<"$escape_action")" ;;
        not-approver) log_event "landing-audit-skip" "$(jq -c '.' <<<"$escape_action")" ;;
      esac
    done < <(timeout 120 "$SCRIPT_DIR/scripts/detect-classifier-escapes.sh" \
               "$escape_slug" "$escape_login" "$union_log" --config "$CONFIG_FILE" \
               2>>"$cycle_dir/classifier-escape-audit.err" || true)
    tail -n "+$(( escape_log_lines_before + 1 ))" "$log_file" >> "$union_log" 2>/dev/null || true
  done < <(jq -r '.repos[].slug' "$CONFIG_FILE" 2>/dev/null || true)
fi

# 2.1g Reservation-release retry sweep (TD-PPagop-26082427) — the durable
# backstop for a `_techdebt_unfile` (lib/tech-debt-file.sh) DELETE that could
# not land: rather than leaving an abandoned `td/<id>`/`td-record/<id>`
# reservation branch orphaned for good, that failure now writes a marker
# under `reservation-releases/` in the state repository, and this is the
# pass that retries it. One invocation, not a per-repo loop: every marker
# already names its own target repository, so a single pass covers
# whichever repositories have anything pending regardless of `--repo` or
# which repos this node is configured against — the same shape
# `lib/claim.sh gc` already uses for its own state-repo-wide sweep. Every
# node may run it concurrently: a second delete of an already-gone branch is
# a no-op and a second clear of an already-cleared marker is a 404 this
# script already treats as nothing to report. Skipped on --dry-run: it
# deletes refs and state-repo markers.
if ! (( DRY_RUN )); then
  while IFS= read -r pending_action; do
    [[ -n "$pending_action" ]] || continue
    case "$(jq -r '.action // ""' <<<"$pending_action" 2>/dev/null || true)" in
      released|absent) log_event "reservation-release-retried" \
        "$(jq -c 'del(.action) + {outcome: .action}' <<<"$pending_action")" ;;
      warning) log_event "warning" "$(jq -c \
        '{detail: ("reservation-release retry: " + (.repo // "") + " " + (.branch // "") + ": " + (.detail // ""))}' \
        <<<"$pending_action")" ;;
      reservation-release-stuck) log_event "reservation-release-stuck" \
        "$(jq -c 'del(.action)' <<<"$pending_action")" ;;
    esac
  done < <(timeout 120 "$SCRIPT_DIR/scripts/release-pending-reservations.sh" \
             2>>"$cycle_dir/reservation-release-sweep.err" || true)
fi

# 2.2 Back-pressure — across ALL configured repos, regardless of --repo.
#
# The stand-down is *deferred* rather than taken here (requirement 2.2a). Back-
# pressure throttles starting new work, and until the sources are gathered we do
# not know whether the only candidate is review-feedback — which finishes work
# already parked in whichever queue requirement 2.2's merge_autonomy-aware
# exclusion currently holds it in (a human's, below agent-merges-routine; see
# D18 WI-6 below) instead of adding to it. Standing down here would
# deadlock the pipeline exactly when it is most stuck: max_open_agent_prs PRs
# all waiting on the agent, and the one source that could clear them never
# reached. The cost of deferring is the handful of `gh` calls in step 3.
#
# A ready PR only counts toward the trip when the pipeline itself has a next
# action on it — `reviewDecision == CHANGES_REQUESTED`, the same "whose turn
# is it" rule requirement 3c's review-feedback candidate filter uses
# (scripts/gather-review-feedback.sh), so the two definitions cannot disagree.
# A ready PR that is approved, or awaiting a first or re-review with nothing
# currently `CHANGES_REQUESTED`-blocking it, is sitting in a human's queue only
# below agent-merges-routine (D18 WI-6, the level-aware loop below) — the
# pipeline cannot shrink that queue by declining to open new work, so counting
# it against the cap only back-pressures the fleet for a queue it has no lever
# to drain (agent-ops#246). At agent-merges-routine and above there is no such
# queue for it to sit in, and it counts like any other ready PR (see
# `backpressure_autonomous_rank` below).
#
# The count is taken in four parts — ready PRs awaiting a human (only below
# agent-merges-routine; see D18 WI-6 below), ready PRs awaiting the pipeline,
# draft PRs, live claims — because the trip decision needs only the
# human-queue-excluded sum, but the logged reason states the full split: a
# human-queue PR could fill the raw total without ever counting against the
# cap, at levels where such a queue exists; a pipeline-turn ready PR is that
# queue answered (or, at agent-merges-routine and above, simply the next
# ready PR) and now the agent's to act on; a draft is work in flight (the
# Implementer's own claim marker, requirement 23); an unraised claim is a
# registry entry whose PR does not yet exist. Which of them filled the gate
# is what a cap-tuning decision needs to know. Recording it here costs
# nothing; reconstructing it later means cycle-record archaeology.
#
# The listing's page size is stated (`GITHUB_PR_LIST_LIMIT`, lib/github-limit.sh)
# rather than left to `gh`'s undeclared default of 30, and a response that came
# back at it is treated as a trip. This is the one place in the pipeline where
# a truncated listing is actively dangerous: `gh` gives no signal that it
# capped, so the counts below would simply be low, and low counts open a gate
# whose whole purpose is to stay shut. Note that the raw listing is not bounded
# by `max_open_agent_prs` — a pull request sitting in whichever queue
# requirement 2.2's merge_autonomy-aware exclusion currently parks it in still
# carries `pr_label` and is deliberately excluded from the sum — so a repo can
# genuinely hold more open labelled PRs than the cap, and the cap is no
# guarantee the page was big enough.
#
# Live claims count toward the cap too: a claim is work in flight that has
# not yet surfaced as a PR, and N nodes counting only PRs would collectively
# overshoot by the work each other had claimed but not yet raised. Still
# approximate — two nodes can pass this check simultaneously — with a stated
# bound of max_open_agent_prs + (nodes - 1), transient.
#
# "Not yet surfaced as a PR" is the whole of it, and it is why each repo's
# claims are counted *here*, inside the same iteration as its own PR listing,
# rather than in a second loop of their own: `claim.sh count` is told which of
# this repo's pull requests the sum above already holds, and drops any claim
# that merely names one of them. Two claim shapes name a PR. The PR-keyed
# `pr-<n>` exclusion entry (issue #238) is held past its PR's own raising
# (issue #360) and `claim.sh` drops it unconditionally; the item claim beside
# it carries the `pr-<n>-<kind>-<scope>` ref the four finishing sources use,
# and until now it was counted — a claimed abandoned draft was its own draft
# PR *plus* its own claim, two against a cap it occupies once. Only the PRs
# actually inside the sum are passed, so a conflicted or dequeued PR that the
# rule above leaves out of the sum keeps counting through its claim, which is
# then the only record of it in flight.
ready_count=0
human_queue_count=0
draft_count=0
claim_count=0
listing_truncated=0
# Per-repo set of PR numbers this count already holds — its drafts and its
# CHANGES_REQUESTED-ready PRs, the same rule `counted_prs` below applies one
# repo at a time. An object keyed by slug, each value a JSON array of PR
# numbers. Requirement 2.2a's decision site reads this back to tell which of
# a repo's merge-conflict/dequeued candidates (gathered later, in step 3, so
# they cannot be folded in above) this count already counted and which it did
# not.
counted_prs_json='{}'
# The rank a repo's effective merge_autonomy level must reach before an
# otherwise-eligible ready pull request stops excluding from this loop's
# human-queue count (D18 WI-6, requirement 2.2's own level-aware paragraph)
# — loop-invariant, so it is resolved once rather than once per repo.
backpressure_autonomous_rank="$(merge_autonomy_rank agent-merges-routine)"
while IFS= read -r slug; do
  # D18 WI-6 (requirement 2.2's own level-aware paragraph): above
  # agent-merges-routine there is no human queue for an *otherwise-eligible*
  # ready pull request to sit in, so nothing is excluded from this repo's
  # count below for one the pipeline could actually land. Read once per
  # repo, against the effective level (never the configured one —
  # merge_autonomy_effective_level is the one function every reader of this
  # key must go through), so a fleet-wide kill switch or a merge-budget
  # freeze (requirement 2.3c) un-excludes those pull requests again by the
  # next cycle's process — this read is advisory, not an acting site, so it
  # is memoised for this process's whole run like every other advisory read
  # (requirement 2.3a, issue #513).
  slug_level="$(merge_autonomy_effective_level "$DEFAULTED_CONFIG" "$slug" "$state_repo" "$state_dir")"
  slug_level_rank="$(merge_autonomy_rank "$slug_level" 2>/dev/null)" || slug_level_rank=0
  prs_json="$(gh pr list -R "$slug" --state open --label "$pr_label" \
    --limit "$GITHUB_PR_LIST_LIMIT" --json number,isDraft,reviewDecision,headRefName,labels 2>/dev/null)" || prs_json=''
  [[ -n "$prs_json" ]] || prs_json='[]'
  counts="$(jq -r '[([.[] | select(.isDraft | not)] | length),
           ([.[] | select(.isDraft | not) | select(.reviewDecision != "CHANGES_REQUESTED")] | length),
           ([.[] | select(.isDraft)] | length),
           length] | @tsv' <<<"$prs_json" 2>/dev/null)" || counts=''
  IFS=$'\t' read -r n_ready n_human n_draft n_total <<<"$counts"
  [[ "$n_ready" =~ ^[0-9]+$ ]] || n_ready=0
  [[ "$n_human" =~ ^[0-9]+$ ]] || n_human=0
  [[ "$n_draft" =~ ^[0-9]+$ ]] || n_draft=0
  [[ "$n_total" =~ ^[0-9]+$ ]] || n_total=0
  # D18 WI-6, requirement 2.2's own "otherwise-eligible" qualifier: above
  # agent-merges-routine there is no human queue for a ready pull request the
  # pipeline could actually land — but one it is barred from landing, by
  # complexity or by source, still has no other actor to move it, so it
  # stays in the human queue exactly as it would below this level. Only a
  # non-CHANGES_REQUESTED one is asked about: a CHANGES_REQUESTED pull
  # request is pipeline-owed at every level whatever its grade or source
  # (`gather-review-feedback.sh` re-engages it, and that path consults
  # neither), so narrowing it into the human queue would make this level
  # hold *fewer* pull requests against the cap than the same repository does
  # at `human` — the one direction requirement 2.2 rules out. Restricting
  # the candidates keeps `n_human` a subset of the un-narrowed rule's own
  # answer rather than a different set. `landing_eligible`
  # itself is not called here: its protected-path gate is a live changed-file
  # read this decision has no need of (a protected path does not stop a
  # human from landing it, only the pipeline from doing so automatically),
  # so `landing_routine_eligible` (lib/landing.sh) — the same
  # _landing_routine_complexity/_landing_routine_sources primitives
  # `landing_eligible` itself reads — answers this alone, at no extra
  # network cost. SOURCE has no field on GitHub at all (a pull request's
  # source is fixed at claim time; `landing_retry_source_map`'s own header,
  # lib/union-log-scan.sh), so it is read back from one pass over the fleet's
  # union log — built once for this repository, below, shared across every
  # candidate rather than re-parsed per candidate (#1050), and lazily, only
  # when this repository has a candidate to spend it on, so a repository with
  # none reads the log no more often than it did before the map existed — the
  # same map the 2.1e landing-retry sweep now builds too, on the same terms
  # (`_landing_retry_sweep_repo`); a
  # candidate whose source cannot be resolved this way counts toward the
  # cap rather than being excluded from it (fail-closed — of the two ways
  # to be wrong here, opening work past a full cap is the one that is not
  # recoverable next cycle), with a warning naming the repository and the
  # pull request so an operator can see why it was not narrowed.
  ineligible_prs_json='[]'
  if (( slug_level_rank >= backpressure_autonomous_rank )); then
    backpressure_candidates="$(jq -c '.[] | select(.isDraft | not)
      | select(.reviewDecision != "CHANGES_REQUESTED")' <<<"$prs_json" 2>/dev/null)"
    cand_source_map='{}'
    if [[ -n "$backpressure_candidates" ]]; then
      cand_source_map="$(landing_retry_source_map "$slug" "$union_log")"
    fi
    while IFS= read -r cand; do
      [[ -n "$cand" ]] || continue
      cand_number="$(jq -r '.number' <<<"$cand")"
      cand_branch="$(jq -r '.headRefName' <<<"$cand")"
      cand_complexity="$(jq -r '((.labels // []) | map(.name)
        | map(select(startswith("complexity:"))) | first // "" | sub("^complexity:";""))' <<<"$cand")"
      cand_source="$(jq -r --arg b "$cand_branch" '.[$b].source // empty' <<<"$cand_source_map" 2>/dev/null)"
      if [[ -z "$cand_source" ]]; then
        log_event "warning" "$(jq -nc --arg r "$slug" --argjson n "$cand_number" \
          --arg d "back-pressure: $slug#$cand_number's originating source could not be resolved from the fleet log, so it is counted toward the cap rather than excluded from it (fail-closed)" \
          '{repo: $r, pr_number: $n, detail: $d}')"
        continue
      fi
      cand_elig="$(landing_routine_eligible "$DEFAULTED_CONFIG" "$slug" "$cand_complexity" "$cand_source")"
      if [[ "$cand_elig" != "eligible" ]]; then
        appended="$(jq -c --argjson n "$cand_number" '. + [$n]' <<<"$ineligible_prs_json" 2>/dev/null)"
        [[ -n "$appended" ]] && ineligible_prs_json="$appended"
      fi
    done <<<"$backpressure_candidates"
    [[ -n "$ineligible_prs_json" ]] || ineligible_prs_json='[]'
    n_human="$(jq 'length' <<<"$ineligible_prs_json" 2>/dev/null)" || n_human=0
    [[ "$n_human" =~ ^[0-9]+$ ]] || n_human=0
  fi
  if github_pr_list_truncated "$n_total"; then
    listing_truncated=1
    log_event "warning" "$(jq -nc --arg r "$slug" --arg l "$GITHUB_PR_LIST_LIMIT" --arg d \
      "back-pressure: $slug's open labelled pull requests came back at the ${GITHUB_PR_LIST_LIMIT}-item listing cap, so the count below is a floor, not a total; treating back-pressure as tripped rather than counting a truncated page" \
      '{repo: $r, limit: $l, detail: $d}')"
  fi
  ready_count=$(( ready_count + n_ready ))
  human_queue_count=$(( human_queue_count + n_human ))
  draft_count=$(( draft_count + n_draft ))
  # The pull requests this repo just contributed to the trip: its drafts, and
  # its ready ones the pipeline still owes a change — at agent-merges-routine
  # or above, every ready one `ineligible_prs_json` above did not just carve
  # out into the human queue (the same predicate `n_human` was built from,
  # so the two can never disagree about the same pull request), which leaves
  # its CHANGES_REQUESTED ones in the set here exactly as the branch below
  # keeps them, since the loop above never offers them as candidates.
  # Bounded by
  # GITHUB_PR_LIST_LIMIT, so it may ride argv (requirement 4g). An unreadable
  # listing leaves it empty, which counts every claim — the fail-closed
  # reading, matching the zeroed counts above.
  if (( slug_level_rank >= backpressure_autonomous_rank )); then
    counted_prs_array="$(jq -c --argjson ineligible "$ineligible_prs_json" \
      '[.[] | select(.isDraft or (([.number] - $ineligible) | length > 0)) | .number]' \
      <<<"$prs_json" 2>/dev/null)" || counted_prs_array='[]'
  else
    counted_prs_array="$(jq -c '[.[] | select(.isDraft or .reviewDecision == "CHANGES_REQUESTED") | .number]' \
      <<<"$prs_json" 2>/dev/null)" || counted_prs_array='[]'
  fi
  [[ -n "$counted_prs_array" ]] || counted_prs_array='[]'
  counted_prs="$(jq -r 'join(",")' <<<"$counted_prs_array" 2>/dev/null)" || counted_prs=''
  counted_prs_json="$(jq -c --arg s "$slug" --argjson ns "$counted_prs_array" \
    '. + {($s): $ns}' <<<"$counted_prs_json" 2>/dev/null)" || counted_prs_json='{}'
  n="$("$SCRIPT_DIR/lib/claim.sh" count "$slug" "$counted_prs" 2>&1)" \
    || { guard_warn "claim-count:$slug" "$n"; n=0; }
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  claim_count=$(( claim_count + n ))
done < <(jq -r '.[].slug' <<<"$all_repos_json")

pipeline_ready_count=$(( ready_count - human_queue_count ))
raw_open_count=$(( ready_count + draft_count + claim_count ))
adjusted_open_count=$(( pipeline_ready_count + draft_count + claim_count ))
open_composition="$pipeline_ready_count pipeline-owed + $draft_count draft + $claim_count unraised claim(s) — plus $human_queue_count waiting on human ($raw_open_count raw)"

backpressure_tripped=0
if (( adjusted_open_count >= max_open_agent_prs )); then
  backpressure_tripped=1
fi
# A truncated listing trips the gate on its own, whatever the visible sum came
# to: the counts are a floor and the real total is unknown, and of the two ways
# to be wrong — deferring a cycle that could have run, or opening work past a
# cap that was already full — only the first is recoverable next cycle.
if (( listing_truncated )); then
  backpressure_tripped=1
  open_composition="$open_composition — at least one repo's listing was truncated, so these are floors"
fi

}

# memory_throttle_check — requirement 2.0i (agent-ops#2469). Defined at file
# scope, unlike every check above, because it is called from two places:
# once from 2.0i's own slot inside run_standdown_checks, in the cheap
# pre-flight band every other check in this file runs in, and again from
# agent-cycle.sh's own spine immediately before the Co-Ordinator engages — a
# median of 28 to 38 minutes later on the measured fleet (the pre-stage
# sweeps), long enough for a throttle band that opened after the first
# reading to matter before a model stage ever starts. A nested function
# inside run_standdown_checks would not exist yet if an earlier check in that
# ladder exits first, so the second call site could not reach it; this one
# is defined the moment lib/standdown.sh is sourced, before either call site
# can run.
#
# Reads every value through lib/memory.sh's own cgroup functions, never its
# own `/proc` or `/sys` paths, so this and `scripts/doctor.sh`'s advisory
# warning can never silently disagree about what "throttling" means. The
# previous reading lives in its own gate-owned file,
# `$state_dir/.memory-cgroup-throttle-state`, deliberately separate from
# doctor's own `.doctor-memory-events-high` (that file's own header) so
# neither reader's sampling interval moves the other's baseline.
#
# Exits the whole process with 0 when either signal trips — the rate
# (`max_cgroup_throttle_per_minute`) or, if configured on, the level
# (`min_cgroup_headroom_bytes`) — exactly like every other check in this
# ladder; returns normally (falls through to whatever the caller does next)
# otherwise. Off entirely when both thresholds are `0`.
memory_throttle_check() {
  (( max_cgroup_throttle_per_minute > 0 || min_cgroup_headroom_bytes > 0 )) || return 0

  local mt_state_file="$state_dir/.memory-cgroup-throttle-state"
  local mt_prev_ts="" mt_prev_high="" mt_prev_consecutive=0
  if [[ -s "$mt_state_file" ]]; then
    IFS=$'\t' read -r mt_prev_ts mt_prev_high mt_prev_consecutive < "$mt_state_file" 2>/dev/null || true
  fi
  [[ "$mt_prev_consecutive" =~ ^[0-9]+$ ]] || mt_prev_consecutive=0

  local mt_current_high mt_current_ts mt_current_mem mt_parent_high
  mt_current_high="$(memory_cgroup_parent_events_high)"
  mt_current_ts="$(date -u +%s)"
  mt_current_mem="$(memory_cgroup_field memory.current)"
  mt_parent_high="$(memory_cgroup_parent_high)"

  local mt_rate="" mt_elapsed_min=0
  if [[ "$mt_prev_ts" =~ ^[0-9]+$ ]]; then
    mt_elapsed_min=$(( (mt_current_ts - mt_prev_ts) / 60 ))
  fi
  mt_rate="$(memory_cgroup_throttle_rate_per_min "$mt_current_high" "$mt_current_ts" "$mt_prev_high" "$mt_prev_ts")"

  local mt_throttle_verdict="" mt_headroom_verdict=""
  if (( max_cgroup_throttle_per_minute > 0 )); then
    mt_throttle_verdict="$(memory_cgroup_throttle_verdict "$mt_current_high" "$mt_current_ts" \
      "$mt_prev_high" "$mt_prev_ts" "$max_cgroup_throttle_per_minute")"
  fi
  if (( min_cgroup_headroom_bytes > 0 )); then
    mt_headroom_verdict="$(memory_cgroup_headroom_verdict "$mt_current_mem" "$mt_parent_high" \
      "$min_cgroup_headroom_bytes")"
  fi

  # The reading is persisted whenever there is one to persist, regardless of
  # verdict — next cycle's delta needs it either way — but the consecutive
  # count only ever moves on positive evidence (a real "throttling" or a real
  # "ok"): a verdict of "" (no parent window, or this is the first reading)
  # is not evidence either way, so the count is left exactly where it was,
  # the same "silence must never retire an alarm" reasoning lib/crash-loop.sh
  # already rests on for its own escalation retirement.
  local mt_triggered=0 mt_cleared=0 mt_new_consecutive="$mt_prev_consecutive" mt_reason=""
  if [[ "$mt_throttle_verdict" == "throttling" || "$mt_headroom_verdict" == "near-ceiling" ]]; then
    mt_triggered=1
    mt_new_consecutive=$(( mt_prev_consecutive + 1 ))
  elif [[ "$mt_throttle_verdict" == "ok" || "$mt_headroom_verdict" == "ok" ]]; then
    mt_cleared=1
    mt_new_consecutive=0
  fi

  # The retirement runs here, *before* the state write below, rather than
  # after it: that write is what decides whether a failed close can ever be
  # retried. The `mt_prev_consecutive >= memory_throttle_escalate_after`
  # test is the only thing that ever brings this node back to the close, and
  # a count already persisted as `0` can never satisfy it again — so a close
  # that failed would be forfeited for the container's whole remaining
  # lifetime, the exact regression agent-ops#2511 fixed for 0h. Keeping the
  # previous count whenever a retirement that was *owed* was not confirmed
  # *done* is what makes `memory_throttle_retire_resolved`'s own "will retry
  # next cycle" true: the three windows it returns non-zero for (the lookup
  # erroring, a payload jq cannot parse, the close itself failing) and the
  # two paths that never attempt it at all (`--dry-run`, no
  # `crash_loop_repo`) all leave the count where a later clean reading can
  # still reach the close. 0h's own caller guards its `cred_prev_verdict`
  # write the same way, for the same reason.
  #
  # Gated on `mt_cleared` — a real `ok` — and never on a merely empty
  # verdict: an unreadable parent window is the very condition an open
  # escalation here is about, not evidence that it has cleared, and retiring
  # on silence is exactly what the consecutive count's own "silence must
  # never retire an alarm" rule above already refuses to do. A clean reading
  # that never reached the threshold has nothing open to retire, so the
  # overwhelmingly common healthy path pays no `gh issue list` call at all.
  if (( mt_cleared )) && (( memory_throttle_escalate_after > 0 )) \
     && (( mt_prev_consecutive >= memory_throttle_escalate_after )); then
    if ! (( DRY_RUN )) && [[ -n "$crash_loop_repo" ]]; then
      memory_throttle_retire_resolved "$crash_loop_repo" "$node_name" "$cycle_id" \
        || mt_new_consecutive="$mt_prev_consecutive"
    else
      mt_new_consecutive="$mt_prev_consecutive"
    fi
  fi

  if [[ -n "$mt_current_high" ]]; then
    local mt_state_tmp="$mt_state_file.tmp.$$"
    if printf '%s\t%s\t%s\n' "$mt_current_ts" "$mt_current_high" "$mt_new_consecutive" \
         > "$mt_state_tmp" 2>/dev/null; then
      mv -f "$mt_state_tmp" "$mt_state_file" 2>/dev/null || rm -f "$mt_state_tmp" 2>/dev/null
    else
      rm -f "$mt_state_tmp" 2>/dev/null || true
    fi
  fi

  if (( mt_triggered )); then
    if [[ "$mt_throttle_verdict" == "throttling" ]]; then
      mt_reason="$(memory_cgroup_throttle_describe "$mt_rate" "$max_cgroup_throttle_per_minute" "$mt_elapsed_min")"
    else
      mt_reason="$(memory_cgroup_headroom_describe "$mt_current_mem" "$mt_parent_high" "$min_cgroup_headroom_bytes")"
    fi
    log_event "stand-down" "$(jq -nc --arg r "$mt_reason" --arg cause "memory-throttled" \
      --arg rate "$mt_rate" --argjson consecutive "$mt_new_consecutive" \
      '{reason: $r, cause: $cause} + (if $rate == "" then {} else {rate_per_min: $rate} end) + {consecutive: $consecutive}')"
    set_node_state_terminal externally-blocked memory-throttled
    if (( memory_throttle_escalate_after > 0 )) && (( mt_new_consecutive >= memory_throttle_escalate_after )) \
       && ! (( DRY_RUN )) && [[ -n "$crash_loop_repo" && -n "$enabler_assignee" ]]; then
      _memory_throttle_escalate "$mt_new_consecutive" "$mt_reason"
    fi
    exit 0
  fi
}

# _memory_throttle_escalate CONSECUTIVE REASON
# Files (or finds the already-open) `memory-throttled:<node>` escalation
# issue once `memory_throttle_check` has stood this node down
# `memory_throttle_escalate_after` consecutive times — a sustained band that,
# unlike a transient resource dip, will not clear on its own: the remedy is
# an operator re-running `scripts/cgroup-parent-setup.sh` with a wider
# ceiling (agent-ops#1639), not waiting. `create_escalation_issue`'s own
# open-issue search is what makes this safe to call every cycle the
# threshold is still met — an open issue already naming this item ref is
# found, not re-filed.
_memory_throttle_escalate() {
  local consecutive="$1" reason="$2"
  local item_ref="memory-throttled:$node_name"
  local body="$cycle_dir/memory-throttle-issue.md"
  # shellcheck disable=SC2016  # the backticks are the issue body's Markdown, not expansions
  {
    printf '## Node %s'"'"'s parent cgroup has throttled it for %s consecutive cycles\n\n' \
      "$node_name" "$consecutive"
    printf -- '- node: `%s`\n- cycle: `%s`\n- reason: %s\n\n' "$node_name" "$cycle_id" "$reason"
    printf 'This will not clear on its own — re-run `scripts/cgroup-parent-setup.sh` on this node with a `--max`/`--limit` above the container'"'"'s own ceiling (agent-ops#1639), and the next cycle proceeds normally.\n\n'
    printf -- '---\nItem: `%s` · raised by the Script · cycle `%s` · node `%s`\n' \
      "$item_ref" "$cycle_id" "$node_name"
  } > "$body"
  local created
  if created="$(create_escalation_issue "$crash_loop_repo" "$item_ref" "$enabler_escalation_label" \
       "Parent-cgroup memory throttle on node $node_name" "$body")" && [[ -n "$created" ]]; then
    log_event "memory-throttle-escalated" "$(jq -nc \
      --argjson n "${created%%$'\t'*}" --arg u "${created#*$'\t'}" --argjson c "$consecutive" \
      '{issue_number: $n, issue_url: $u, consecutive: $c}')"
  else
    log_event "warning" "$(jq -nc \
      --arg d "node $node_name has throttled for $consecutive consecutive cycles but the escalation issue could not be filed — will retry next cycle" \
      '{detail: $d}')"
  fi
}
