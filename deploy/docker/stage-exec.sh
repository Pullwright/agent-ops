#!/bin/bash
#
# deploy/docker/stage-exec.sh — installed root-owned, by the Dockerfile, as
# /usr/local/libexec/agent-ops/stage-exec: the one way the Script starts a
# process as the stage user (requirement 45e of
# docs/spec/implementation/requirements/every-stage.md).
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
#   4. Stops everything below it when it is told to stop, when the sudo it
#      was started by dies, and when COMMAND ends, so that nothing a stage
#      started outlives it.
#   5. Kills every process of the stage user's that no live launch owns.
#
# Why (4) cannot be left to the Script. The Script stops a stage by
# signalling the stage's process group (requirements 4e and 9c). A process
# may signal only its own user's processes, so that signal reaches sudo,
# which runs as root on the Script's behalf, and none of the stage user's.
# sudo relays a TERM, INT or HUP to its own child, this script, and to
# nothing below it, and a KILL — all that a cycle's signal handler sends —
# it cannot relay at all. So this script does what the Script's group signal
# used to do, and more: on TERM, INT or HUP it sends TERM to every process
# below it, waits up to `PW_STAGE_KILL_GRACE` seconds (default 3, inside the
# launcher's own five) for them to go, sends KILL to any that remain, and
# exits 143. It asks the kernel for a TERM when its parent dies (`setpriv
# --pdeathsig`), which is how a KILL to sudo reaches it. And it is a child
# subreaper (prctl PR_SET_CHILD_SUBREAPER), so a process a stage detaches —
# `setsid`, a double fork, a daemon a tool starts — is re-parented to this
# script rather than to pid 1, stays below it, and is stopped with the rest
# when COMMAND ends.
#
# Why (5). A stage can still escape (4) by killing this script, which runs as
# the same user. What it left running would then hold write access to every
# workspace shared later and could race the Script's reads. So every launch
# — a stage, a probe, each thing lib/stage-boundary.sh does as the stage
# user — kills, as it starts and as it ends, every process of the stage
# user's that is not below a live launch. A launch is a process of the stage
# user's whose parent is sudo, running as root, started by the user sudo
# names as its invoker (`SUDO_UID`): nothing the stage user runs can make
# one, since the stage user may run nothing through sudo but forge-token, and
# that as the Script's user. Other stages running at the same time (a
# doctor check, an operator's login, the review pipeline) are below their own
# launches and are left alone.

set -u

# The parent is passed on: once the death signal is armed, a parent that had
# already died would show here only as whatever adopted this process.
if [[ "${1:-}" != --supervised ]]; then
  subreaper=()
  if command -v python3 >/dev/null 2>&1; then
    # shellcheck disable=SC2016  # Python, not shell
    subreaper=(python3 -I -S -c 'import ctypes, os, sys
ctypes.CDLL(None, use_errno=True).prctl(36, 1, 0, 0, 0)  # PR_SET_CHILD_SUBREAPER
os.execv("/bin/bash", ["/bin/bash"] + sys.argv[1:])')
  fi
  exec setpriv --pdeathsig TERM -- "${subreaper[@]:-/bin/bash}" \
    "${BASH_SOURCE[0]}" --supervised "$PPID" "$@"
fi
parent="${2:-}"
shift 2

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

# collect_descendants
# Fill `descendants` with every live process below this one. Read straight
# from /proc, in this shell, so that the reading itself adds no process.
descendants=()
collect_descendants() {
  local f rest pid state ppid p c
  local -A kids=()
  local -a queue=("$$")
  for f in /proc/[0-9]*/stat; do
    read -r rest 2>/dev/null <"$f" || continue
    pid="${rest%% *}"
    rest="${rest##*) }"
    state="${rest%% *}"
    rest="${rest#* }"
    ppid="${rest%% *}"
    [[ "$state" != Z ]] || continue
    kids[$ppid]+=" $pid"
  done
  descendants=()
  while (( ${#queue[@]} > 0 )); do
    p="${queue[0]}"
    queue=("${queue[@]:1}")
    for c in ${kids[$p]:-}; do
      descendants+=("$c")
      queue+=("$c")
    done
  done
}

# stop_descendants
# TERM to everything below this script, up to `grace` seconds for it to go,
# then KILL to whatever remains. This script is never among them, so it
# lives to clean up and to exit with its own status.
stop_descendants() {
  local waited=0
  collect_descendants
  (( ${#descendants[@]} == 0 )) || kill -TERM "${descendants[@]}" 2>/dev/null
  while (( ${#descendants[@]} > 0 && waited < grace * 10 )); do
    sleep 0.1
    waited=$(( waited + 1 ))
    collect_descendants
  done
  for _ in 1 2 3; do
    (( ${#descendants[@]} > 0 )) || break
    kill -KILL "${descendants[@]}" 2>/dev/null
    collect_descendants
  done
}

# sweep_strays
# Kill every process of this user's that no live launch owns (see "Why (5)"
# above). Does nothing unless this script was started through sudo by
# another user, which is the only case in which there is a launch to judge
# by.
sweep_strays() {
  local me invoker f pid key a b c p q hops sudo_seen
  local -A ppid=() ruid=() euid=() suid=() name=()
  local -a strays=()
  me="$(id -u)"
  invoker="${SUDO_UID:-}"
  [[ "$invoker" =~ ^[0-9]+$ && "$invoker" != "$me" ]] || return 0
  for f in /proc/[0-9]*/status; do
    pid="${f#/proc/}"
    pid="${pid%/status}"
    while IFS=$'\t' read -r key a b c _; do
      case "$key" in
        Name:) name[$pid]="$a" ;;
        PPid:) ppid[$pid]="$a" ;;
        Uid:) ruid[$pid]="$a"; euid[$pid]="$b"; suid[$pid]="$c" ;;
      esac
    done 2>/dev/null <"$f"
  done
  for pid in "${!ppid[@]}"; do
    [[ "$pid" != "$$" ]] || continue
    [[ "${ruid[$pid]:-}" == "$me" || "${suid[$pid]:-}" == "$me" ]] || continue
    # Walk up from pid; it is owned when it is, or is below, a launch.
    p="$pid"
    hops=0
    while [[ -n "$p" && "$p" != 0 ]] && (( hops < 256 )); do
      if [[ "${euid[$p]:-}" == "$me" ]]; then
        q="${ppid[$p]:-}"
        sudo_seen=0
        while [[ -n "$q" && "${name[$q]:-}" == sudo && "${euid[$q]:-}" == 0 ]]; do
          sudo_seen=1
          q="${ppid[$q]:-}"
        done
        if (( sudo_seen )) && [[ -n "$q" && "${euid[$q]:-}" == "$invoker" ]]; then
          continue 2
        fi
      fi
      p="${ppid[$p]:-}"
      hops=$(( hops + 1 ))
    done
    strays+=("$pid")
  done
  (( ${#strays[@]} == 0 )) || kill -KILL "${strays[@]}" 2>/dev/null
  return 0
}

stop_group() {
  trap '' TERM INT HUP
  stop_descendants
  scratch_release
  sweep_strays
  exit 143
}
trap stop_group TERM INT HUP
# The parent may have died before the death signal was armed.
[[ "$PPID" == "$parent" ]] || stop_group

sweep_strays
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
stop_descendants
scratch_release
sweep_strays
exit "$rc"
