#!/usr/bin/env bash
#
# lib/role.sh — whether this node runs unattended cycles.
#
# The pipelines run on any number of machines, and any number of them may be
# `active` at once: per-item claims (requirement 17a) keep concurrent actives
# off the same work, so the role no longer elects "the" worker — it decides
# whether *this* machine spends at all. A standby still pushes its heartbeat,
# fetches its peers and serves the dashboard; it just runs no cycles until
# someone flips one variable.
#
# Fail-closed by design: only the literal value `active` runs unattended
# cycles. Unset, empty, misspelt or any other value is a standby, because the
# failure modes are not symmetric — a standby that should have been active
# costs skipped cycles, an accidental active costs money unattended.
#
# Shared by agent-cycle.sh and review-cycle.sh so there is one definition of
# "active", the same way lib/toggle.sh is the one definition of the switch.

# The role this process was told, normalised — lowercased and stripped of
# whitespace — and empty when the variable is unset or empty. The one place
# the normalisation lives, so `role_current` below and every publisher of the
# fleet's own record agree on what a value means.
role_declared() {
  printf '%s' "${AGENT_OPS_ROLE:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]'
}

# The current role, normalised, defaulting to `standby` when the variable is
# unset or empty.
#
# `role_current` and `role_declared` answer two different questions, and the
# difference matters wherever one node's answer is evidence another node acts
# on. "May this process spend?" is `role_current`, and silence resolves to
# `standby` because the failure modes are not symmetric. "What role is this
# node running as?" is `role_declared`, and the honest answer to silence is
# none at all — which is what `scripts/state-sync.sh` and
# `scripts/publish-dashboard.sh` publish as `unknown` (agent-ops#1686). Every
# scheduled process on a node is handed the variable by Compose
# (`deploy/docker/compose.yaml` sets `AGENT_OPS_ROLE: ${ROLE:-standby}`), so
# an empty answer means the process is not one of them — a hand run on the
# host — and a `standby` inferred from that silence would be a claim about
# the node that nobody made. The pager acts on the published role
# (`lib/pager-invariants.sh`'s `firing-missed`), so the claim has to be real.
role_current() {
  local r
  r="$(role_declared)"
  printf '%s' "${r:-standby}"
}

# True only for the one role that may spend.
role_is_active() {
  [[ "$(role_current)" == "active" ]]
}

# One line for the cron log explaining a skip. Names the role it saw, because
# the common fault is a value that is neither `active` nor `standby` — a typo
# in a .env or a crontab — and "AGENT_OPS_ROLE=activ" diagnoses itself where a
# bare "not active" would not.
role_skip_message() {
  local who="${1:-agent-cycle}" role
  role="$(role_current)"
  case "$role" in
    standby) printf '%s: skipped — this node is standby (AGENT_OPS_ROLE=%s)\n' "$who" "${AGENT_OPS_ROLE:-<unset>}" ;;
    *)       printf '%s: skipped — AGENT_OPS_ROLE=%s is not a role; treating this node as standby\n' "$who" "$role" ;;
  esac
}
