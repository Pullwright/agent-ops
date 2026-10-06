#!/bin/bash
#
# deploy/docker/stage-exec.sh — installed root-owned, by the Dockerfile, as
# /usr/local/libexec/agent-ops/stage-exec: the one way the Script starts a
# process as the stage user (requirement 45e of
# docs/IMPLEMENTATION-PIPELINE-SPEC.md).
#
# Usage (as the Script's user):
#   sudo -n -u stage /usr/local/libexec/agent-ops/stage-exec COMMAND [ARGS...]
#
# The Script rarely names this. `/usr/local/bin/claude`
# (deploy/docker/claude-shim.sh) does, so every `claude` the image runs — a
# stage, a limit probe, `doctor.sh`'s checks, an operator's interactive
# login — runs as the stage user, which owns the Claude configuration.
# lib/stage-boundary.sh names it for the few things the Script does in a
# workspace once a stage has had it.
#
# What it does, as the stage user:
#
#   1. Builds the stage's environment. sudo has already reset it to the
#      variables `env_keep` names in deploy/docker/sudoers-agent-ops, so the
#      Script's forge credentials and the Apps' identities never arrive here;
#      they are unset again below all the same, so that a later edit to that
#      list cannot pass one through by accident. A stage authors through
#      `PW_GH_TOKEN_BROKER` instead (lib/forge-token-broker.sh), and commits
#      under the node's git identity, from the same `GIT_USER_NAME` and
#      `GIT_USER_EMAIL` that lib/git-identity.sh requires.
#   2. Gives the stage a scratch directory of its own (lib/scratch.sh), since
#      it cannot write the Script's, and sweeps the ones killed stages left.
#   3. Runs COMMAND as its child and waits for it, returning its exit status.
#   4. Stops the child's whole process group when it is told to stop, or when
#      the sudo it was started by dies.
#
# Why (4) cannot be left to the Script. The Script stops a stage by
# signalling the stage's process group (requirements 4e and 9c). A process
# may signal only its own user's processes, so that signal reaches sudo,
# which runs as root on the Script's behalf, and none of the stage user's.
# sudo relays a TERM, INT or HUP to its own child, this script, and to
# nothing below it, and a KILL — all that a cycle's signal handler sends —
# it cannot relay at all. So this script does what the Script's group signal
# used to do. On TERM, INT or HUP it sends TERM to its process group (the
# group the Script launched, of which it can signal exactly the stage user's
# members), waits `PW_STAGE_KILL_GRACE` seconds (default 3, inside the
# launcher's own five), and sends KILL. And it asks the kernel for a TERM
# when its parent dies (`setpriv --pdeathsig`), which is how a KILL to sudo
# reaches it.

set -u

if [[ "${1:-}" != --supervised ]]; then
  exec setpriv --pdeathsig TERM -- /bin/bash "${BASH_SOURCE[0]}" --supervised "$@"
fi
shift
parent="$PPID"

# Files a stage creates in a workspace stay writable by the Script's user,
# which shares the stage user's group, removes the workspace when its cycle
# ends, and must be able to.
umask 002

unset GH_TOKEN GITHUB_TOKEN PW_GH_DEGRADE_TOKEN NOTIFY_WEBHOOK_URL \
  PULLWRIGHT_AUTHOR_APP_ID PULLWRIGHT_AUTHOR_INSTALLATION_ID \
  PULLWRIGHT_AUTHOR_INSTALLATION_IDS PULLWRIGHT_AUTHOR_PRIVATE_KEY_PATH \
  PULLWRIGHT_APPROVER_APP_ID PULLWRIGHT_APPROVER_INSTALLATION_ID \
  PULLWRIGHT_APPROVER_INSTALLATION_IDS PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH \
  PW_GH_STATE_DIR TMPDIR

export PW_GH_TOKEN_BROKER="${PW_STAGE_TOKEN_BROKER:-/usr/local/libexec/agent-ops/forge-token-request}"
# A root-owned global git configuration, so that the credential helper a
# stage pushes through cannot be rewritten by one stage for the next. It also
# trusts a workspace the Script's user created (`safe.directory`).
export GIT_CONFIG_GLOBAL="${PW_STAGE_GITCONFIG:-/etc/agent-ops/stage-gitconfig}"
unset PW_STAGE_TOKEN_BROKER PW_STAGE_GITCONFIG

if [[ -n "${GIT_USER_NAME:-}" ]]; then
  export GIT_AUTHOR_NAME="$GIT_USER_NAME" GIT_COMMITTER_NAME="$GIT_USER_NAME"
fi
if [[ -n "${GIT_USER_EMAIL:-}" ]]; then
  export GIT_AUTHOR_EMAIL="$GIT_USER_EMAIL" GIT_COMMITTER_EMAIL="$GIT_USER_EMAIL"
fi

if (( $# == 0 )); then
  printf 'stage-exec: no command given\n' >&2
  exit 2
fi

grace="${PW_STAGE_KILL_GRACE:-3}"
[[ "$grace" =~ ^[0-9]+$ ]] || grace=3

# shellcheck source=lib/scratch.sh
. "${AGENT_OPS_ROOT:-/app}/lib/scratch.sh"
SCRATCH_DIR=""

stop_group() {
  trap '' TERM INT HUP
  kill -TERM 0 2>/dev/null
  sleep "$grace"
  scratch_release
  kill -KILL 0 2>/dev/null
  exit 143
}
trap stop_group TERM INT HUP
# The parent may have died before the death signal was armed.
[[ -e "/proc/$parent" ]] || stop_group

scratch_sweep_dead_owners /tmp >/dev/null
if ! scratch_enter stage; then
  exit 1
fi

# `<&0` because bash gives a backgrounded command /dev/null for stdin when job
# control is off, and a stage's prompt arrives on stdin (requirement 4c).
# Backgrounded at all so that `wait` returns, and the trap runs, the moment a
# signal arrives, rather than after the child has exited.
"$@" <&0 &
child=$!

rc=0
while :; do
  wait "$child"
  rc=$?
  kill -0 "$child" 2>/dev/null || break
done
scratch_release
exit "$rc"
