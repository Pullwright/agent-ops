#!/usr/bin/env bash
#
# scripts/wake-poll.sh — wake an idle node when a source-relevant event
# lands (requirement 54, issue #613), instead of waiting for the next
# schedule.cycle_interval_minutes cron firing. Runs from its own crontab
# line, every schedule.wake_poll_minutes (deploy/docker/crontab.tmpl).
#
# ## Mechanism (D14 pricing)
#
# A webhook receiver was rejected: nodes have no public ingress (they sit
# behind Tailscale, deploy/tailscaled.init) and standing one up needs an
# owner-only act per repository (ingress, a webhook registration, a shared
# secret) — see the Enabler's specification on issue #613. A poller needs
# none, so that is what this is: one conditional GET (`If-None-Match`) per
# configured repository per endpoint below, every wake_poll_minutes. GitHub
# does not charge a `304` against the primary rate-limit budget — measured
# live against this deployment's own token while this item was scoped
# (`x-ratelimit-remaining` held steady across a `304`, and dropped by
# exactly one on the very next ordinary call) — so an idle repository's
# wake-poll ticks are free; a real change costs one call per endpoint that
# changed, at the exact moment a cycle is about to spend far more anyway.
# Each endpoint call is independent and cheap, so no lock guards against two
# overlapping runs: the worst an overlap costs is a duplicated conditional
# GET, still free on a `304`.
#
# ## Endpoint choice: walking lib/noop-skip.sh's own fingerprint table
#
# The wake trigger must be a *subset* of what busts that fingerprint, source
# by source, or it wakes nodes for nothing:
#
#   issues, tech-debt            `repos/<slug>/issues` (an issue or a new
#                                 comment on one bumps its own `updated_at`,
#                                 which changes this listing's `ETag`)
#   review-feedback,
#   landing-refusals,
#   human-visibility             `repos/<slug>/pulls` (a review, a review
#                                 comment or a plain comment on an open pull
#                                 request bumps its `updated_at` the same way)
#   failed-runs, dequeued        `repos/<slug>/actions/runs` (a merge-group
#                                 run — what a dequeue is decided from — is an
#                                 ordinary workflow run, so every run created
#                                 moves this listing's own `total_count`. A
#                                 run that merely *completes* while a newer
#                                 run already exists moves neither that count
#                                 nor the single newest-created run the
#                                 listing returns, and waits for the ordinary
#                                 cron firing: under-coverage, which the
#                                 subset rule above permits)
#   code, implementation-plan,
#   project-review               `repos/<slug>/commits` (anything living in
#                                 the repository's own tree changes by a push)
#
# `security`/`code-quality` are deliberately absent: `repos/<slug>/dependabot/
# alerts` returned `403` against this deployment's own token while this item
# was scoped (the token lacks the alerts-read scope) — polling an endpoint
# this token cannot read would only ever log a warning, never a wake, so it
# is left to the ordinary cron firing rather than shipped as dead weight.
#
# `abandoned-drafts` and `merge-conflicts` are absent by design, not
# oversight: neither moves any forge event a poll can see (a draft goes
# abandoned by sitting untouched; a PR turns `CONFLICTING` when its *base*
# moves, an event on a different item's history) — see lib/noop-skip.sh's
# own header. The cron firing this file wakes a node early from is never
# replaced, only pre-empted: those two sources, and everything else, still
# get their ordinary cycle_interval_minutes look.
#
# ## Bootstrap firing
#
# A repository's first-ever tick on a node has no stored ETag, so every
# endpoint reads as "changed" and this wakes a cycle regardless of whether
# anything actually moved since main's last commit — the identical bootstrap
# shape `lib/candidate-select.sh`'s own `emit_first_seen` already names (its
# `bootstrap` flag), for the same reason: a first observation cannot be
# compared against a previous one that does not exist. Costs at most one
# extra cycle per (node, repository), once.
#
# ## What a wake costs, once triggered
#
# A detected change invokes agent-cycle.sh directly — the same entry point
# cron's own @CYCLE_MINUTE@ line uses — so a woken node takes the same lock
# (requirement 1), the same claims, and the same back-pressure cap as a
# cron-fired one; nothing here adds a second path into it. If a cycle is
# already running, agent-cycle.sh's own lock logs `cycle-skipped` and exits 0
# immediately, so an overlapping wake costs one lock check, not a duplicate
# cycle. Its output inherits this script's own stdout/stderr — wake-poll.log,
# not cron.log — so the log that names *why* a cycle started at an odd
# minute is the same one that decided to start it. That file grows a line
# every wake_poll_minutes, quiet ticks included, which is why
# scripts/rotate-logs.sh bounds it (requirement 2.6) and scripts/state-sync.sh
# keeps it local to this node.
#
# What a wake does *not* guarantee is that the woken cycle reads the
# repository that changed. A woken cycle is an ordinary cycle, so it reads
# the nine expensive bands fresh for exactly one repository —
# `expensive_gather_slug`, whichever this node has gone longest without
# expensively reading (requirement 48, lib/expensive-gather-cache.sh) — and
# reuses its cached snapshot for the rest. The change is not re-offered
# either: the new ETag is stored below *before* the wake, so the next tick
# answers 304 whether or not the cycle looked at that repository. Nothing is
# lost by this — the ordinary cron firing still rotates on its own schedule —
# but the win is statistical (every woken cycle advances the rotation a step)
# rather than item-deterministic. See requirement 54 for why biasing the
# rotation toward the woken repository is not done here.
#
# Never fails the cron job: every `gh` call that cannot be read as a status
# line logs a warning and is skipped, exactly like the doctor line's own
# `|| true`.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export AGENT_OPS_ROOT="$SCRIPT_DIR"

# shellcheck source=lib/github-limit.sh
# Shadows `gh` with the secondary-rate-limit retry wrapper (bounded to
# GITHUB_LIMIT_MAX_WAIT_SECONDS, 60s by default) — the same one every other
# script in this repository gets, so a transient secondary refusal costs one
# short wait here too, rather than a skipped tick.
. "$SCRIPT_DIR/lib/github-limit.sh"
# shellcheck source=lib/config-schema.sh
. "$SCRIPT_DIR/lib/config-schema.sh"

CONFIG_FILE="$SCRIPT_DIR/config.json"
SCHEMA_FILE="$SCRIPT_DIR/config.schema.json"

usage() {
  cat <<'EOF'
usage: wake-poll.sh [--config FILE] [--state-dir DIR] [--dry-run]

Checks every repos[].slug in config.json for a source-relevant change via a
conditional GET, and invokes agent-cycle.sh the moment one is found. With no
flags, reads config.json beside this script.

  --config     override the config file (tests use a fixture)
  --state-dir  override state_dir (tests use a throwaway directory)
  --dry-run    detect and log a change but never invoke agent-cycle.sh

Exit status is always 0 once polling begins — see this file's own header for
why. A usage error (an unknown argument) exits 64 before any poll runs.

Environment:
  WAKE_POLL_AGENT_CYCLE_BIN  override which script a detected change invokes
                             (test/wake-poll.test.sh points this at a stub).
EOF
}

config_file="$CONFIG_FILE"
state_dir_override=""
dry_run=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) config_file="$2"; shift 2 ;;
    --state-dir) state_dir_override="$2"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "wake-poll: unknown argument: $1" >&2; usage >&2; exit 64 ;;
  esac
done

expand_home() {
  local p="$1"
  [[ "$p" == "~"* ]] && p="$HOME${p:1}"
  printf '%s\n' "$p"
}

if [[ ! -f "$config_file" ]]; then
  echo "wake-poll: config file not found: $config_file — skipping this tick" >&2
  exit 0
fi
DEFAULTED_CONFIG="$(config_defaults "$config_file" "$SCHEMA_FILE" 2>/dev/null)" || {
  echo "wake-poll: could not read $config_file against $SCHEMA_FILE — skipping this tick" >&2
  exit 0
}
[[ -n "$DEFAULTED_CONFIG" ]] || { echo "wake-poll: $config_file did not validate — skipping this tick" >&2; exit 0; }

if [[ -n "$state_dir_override" ]]; then
  state_dir="$state_dir_override"
else
  state_dir="$(expand_home "$(jq -r '.state_dir' <<<"$DEFAULTED_CONFIG")")"
fi
mkdir -p "$state_dir/wake-poll" 2>/dev/null || {
  echo "wake-poll: cannot create $state_dir/wake-poll — skipping this tick" >&2
  exit 0
}

node_name="${NODE_NAME:-$(hostname 2>/dev/null || echo node)}"
log_file="$state_dir/log.jsonl"

mapfile -t repo_slugs < <(jq -r '.repos[].slug // empty' <<<"$DEFAULTED_CONFIG")

# See this file's own header for why these four, and why security/
# code-quality and abandoned-drafts/merge-conflicts are absent.
ENDPOINTS=(
  "issues?state=open&sort=updated&direction=desc&per_page=1"
  "pulls?state=open&sort=updated&direction=desc&per_page=1"
  "actions/runs?per_page=1"
  "commits?per_page=1"
)

changed=0
changed_detail=""

for slug in "${repo_slugs[@]}"; do
  [[ -n "$slug" ]] || continue
  safe="${slug//\//_}"
  cache_dir="$state_dir/wake-poll/$safe"
  mkdir -p "$cache_dir" 2>/dev/null || continue

  for endpoint in "${ENDPOINTS[@]}"; do
    ep_name="${endpoint%%\?*}"
    ep_safe="${ep_name//\//_}"
    etag_file="$cache_dir/$ep_safe.etag"
    etag=""
    [[ -s "$etag_file" ]] && etag="$(cat "$etag_file" 2>/dev/null || true)"

    out_file="$(mktemp)" || continue
    if [[ -n "$etag" ]]; then
      gh api -i "repos/$slug/$endpoint" -H "If-None-Match: $etag" >"$out_file" 2>/dev/null
    else
      gh api -i "repos/$slug/$endpoint" >"$out_file" 2>/dev/null
    fi
    # `gh api -i` exits non-zero on a 304 (it is not a 2xx), so status —
    # never rc — is what decides the outcome; rc only tells us whether any
    # status line came back at all.
    status="$(head -1 "$out_file" 2>/dev/null | awk '{print $2}')"
    new_etag="$(grep -i '^etag:' "$out_file" 2>/dev/null | head -1 | tr -d '\r' | sed -E 's/^[Ee][Tt][Aa][Gg]: *//')"
    rm -f "$out_file"

    if [[ -z "$status" ]]; then
      echo "wake-poll: $slug $ep_name: unreachable — skipping this endpoint" >&2
      continue
    fi

    case "$status" in
      304) : ;;  # unchanged — no signal, ETag stays as it was
      2??)
        [[ -n "$new_etag" ]] && printf '%s' "$new_etag" > "$etag_file"
        echo "wake-poll: $slug $ep_name changed (status $status)"
        changed=1
        changed_detail="${changed_detail}${changed_detail:+,}\"$slug $ep_name\""
        ;;
      *)
        echo "wake-poll: $slug $ep_name: unexpected status $status — skipping this endpoint" >&2
        ;;
    esac
  done
done

if (( changed == 0 )); then
  echo "wake-poll: nothing changed — no wake"
  exit 0
fi

if (( dry_run == 1 )); then
  echo "wake-poll: change detected — would wake (--dry-run, agent-cycle.sh not invoked)"
  exit 0
fi

echo "wake-poll: change detected ($changed_detail) — waking agent-cycle.sh"
jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg node "$node_name" \
    --argjson changed "[$changed_detail]" \
    '{ts: $ts, cycle: null, node: $node, event: "wake-poll-triggered", changed: $changed}' \
  >> "$log_file" 2>/dev/null || true

# WAKE_POLL_AGENT_CYCLE_BIN lets a test point this at a stub rather than the
# real agent-cycle.sh (test/wake-poll.test.sh) — the same override-by-env-var
# seam test/claim.test.sh's CLAIM_GH and test/state-sync.test.sh's
# STATE_SYNC_REMOTE already use, never read in production.
"${WAKE_POLL_AGENT_CYCLE_BIN:-$SCRIPT_DIR/agent-cycle.sh}"
exit 0
