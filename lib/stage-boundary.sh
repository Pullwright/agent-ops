#!/usr/bin/env bash
#
# lib/stage-boundary.sh — the Script's side of the boundary between itself
# and its stages (requirement 45e of
# docs/spec/implementation/requirements/every-stage.md).
#
# In the node image every model stage runs as the stage user, through
# deploy/docker/stage-exec.sh, and the Script runs as `agent`. The stage user
# cannot read the GitHub Apps' keys, the Script's environment or the token
# cache, and cannot write the Script's code or state. What it can write is
# the one thing it must: the workspace it works in. These functions are what
# the Script does about that workspace, and they hold to two rules.
#
#   1. A workspace is shared with the stage user deliberately, one at a time,
#      immediately before the first stage that has to write in it
#      (`stage_workspace_share`). Everything else the Script keeps under
#      `workspace_root` — the state mirror, the peers' copies, a throwaway
#      clone it compares diffs in, the Monitor's run directory — stays the
#      Script's alone, readable by a stage and never writable.
#   2. Once a stage has had a workspace, the Script treats what is in it as
#      the stage's: it runs no `git` there (a stage-written `.git/config` can
#      name commands — `core.fsmonitor`, hooks, diff and filter drivers — and
#      the Script would run them as itself), and it opens nothing there
#      itself, since a stage can leave a link to a file only the Script can
#      read, or a FIFO that blocks whoever opens it. What the Script must
#      learn from a workspace it learns through the stage user, bounded in
#      time and size (`stage_boundary_capture`, `stage_boundary_read`), and
#      validates before it uses (`stage_breadcrumb_pr_url`). It removes the
#      workspace with `stage_workspace_remove`, which can finish the job a
#      stage made hard.
#
# A stage's processes end with it: every launch through stage-exec also
# kills whatever the stage user is still running that no live launch owns
# (deploy/docker/stage-exec.sh), so nothing a stage detached is left to race
# the Script. `stage_boundary_sweep` asks for that on its own, and
# `stage_workspace_share` does so before it shares anything.
#
# Outside the image — a developer's checkout, the test suite on a host — there
# is no stage user and no `stage` group, and every function here degrades to
# what the Script did before the boundary existed: sharing is a no-op and
# removal is a plain `rm -rf`. `STAGE_BOUNDARY_GROUP`, `STAGE_EXEC_BIN` and
# the function `stage_boundary_as_stage` are the seams a test uses to point
# them elsewhere.

# The group a shared workspace is given, and the program that runs a command
# as the stage user.
STAGE_BOUNDARY_GROUP="${STAGE_BOUNDARY_GROUP:-stage}"
STAGE_EXEC_BIN="${STAGE_EXEC_BIN:-/usr/local/libexec/agent-ops/stage-exec}"

# stage_boundary_present
# True when this process can share a workspace with the stage user: the
# group exists and this user is a member of it.
stage_boundary_present() {
  local groups
  getent group "$STAGE_BOUNDARY_GROUP" >/dev/null 2>&1 || return 1
  groups=" $(id -Gn 2>/dev/null) "
  [[ "$groups" == *" $STAGE_BOUNDARY_GROUP "* ]]
}

# stage_workspace_share DIR
# Give the stage user write access to DIR and everything in it: group
# `stage`, group-writable, and setgid on every directory so that whatever
# either user creates later stays in the group. Only this user's own regular
# files and directories are changed, never a symbolic link. Returns 1 when DIR
# is not a directory, or the change failed, so that the caller can refuse to
# start a stage that could not do its work; returns 0 and changes nothing
# where there is no boundary.
#
# No stage process may change an entry between `find` listing it and the
# change reaching it, or a link swapped in would carry `chmod` to a file of
# this user's elsewhere. Nothing of the stage user's can write in DIR until
# this makes a directory group-writable, so the strays of earlier stages are
# swept first, the group is set without following a link (`chgrp -h`), the
# files' modes are set while no directory is yet writable to the stage user,
# and the directories' last, in post-order (`-depth`), so that a directory
# becomes writable only once everything in it has been changed.
stage_workspace_share() {
  local dir="$1"
  [[ -d "$dir" && ! -L "$dir" ]] || return 1
  stage_boundary_present || return 0
  stage_boundary_sweep
  find "$dir" -user "$(id -u)" \( -type f -o -type d \) \
      -exec chgrp -h "$STAGE_BOUNDARY_GROUP" {} + 2>/dev/null || return 1
  find "$dir" -user "$(id -u)" -type f -exec chmod g+rwX {} + 2>/dev/null || return 1
  find "$dir" -depth -user "$(id -u)" -type d -exec chmod g+rwxs {} + 2>/dev/null || return 1
  return 0
}

# stage_boundary_as_stage COMMAND [ARGS...]
# Run COMMAND as the stage user, from `/` (sudo starts a command in this
# process's directory, which the stage user may not be able to enter), with
# its output discarded. A test replaces this function.
stage_boundary_as_stage() {
  ( cd / && sudo -n -u stage "$STAGE_EXEC_BIN" "$@" ) >/dev/null 2>&1
}

# stage_boundary_sweep
# Kill every process of the stage user's that no live launch owns. Any
# launch through stage-exec does that as it starts, so this is a launch of
# `true`. Does nothing where there is no boundary. Always returns 0.
stage_boundary_sweep() {
  stage_boundary_present || return 0
  stage_boundary_as_stage true
  return 0
}

# stage_boundary_capture SECONDS MAX_BYTES COMMAND [ARGS...]
# Run COMMAND as the stage user, from `/`, with no stdin and its stderr
# discarded, and print at most MAX_BYTES of what it writes to stdout. It is
# stopped after SECONDS (stage-exec then stops all of it), so nothing a stage
# left behind — a FIFO, a `core.fsmonitor` that never returns — can hold the
# Script. Returns COMMAND's status, or non-zero when it was stopped. What it
# prints is the stage user's to choose: the caller validates it. Where there
# is no boundary COMMAND runs as this user, on the same terms.
stage_boundary_capture() {
  local secs="$1" max="$2"
  shift 2
  local -a run=("$@")
  stage_boundary_present && run=(sudo -n -u stage "$STAGE_EXEC_BIN" "$@")
  ( set -o pipefail
    cd / && timeout -k 5 "$secs" "${run[@]}" </dev/null 2>/dev/null | head -c "$max" )
}

# stage_boundary_read FILE MAX_BYTES
# Print at most MAX_BYTES of FILE as the stage user reads it, given ten
# seconds (`stage_boundary_capture`). The stage user follows a link only to
# what it could read anyway, so a link to a file of this user's gives
# nothing, and a FIFO costs the ten seconds. Returns non-zero when FILE could
# not be read in that time.
stage_boundary_read() {
  stage_boundary_capture 10 "$2" head -c "$2" -- "$1"
}

# stage_workspace_remove DIR
# Remove DIR. A stage can leave behind what this user cannot remove — a
# directory it made unwritable, a file it created without group write — so
# when a plain `rm -rf` leaves anything, the stage user removes what it can
# (it owns whatever is left that this user does not), and this user then
# removes the rest. Never follows a link out of DIR: `rm -rf` does not.
# Always returns 0; the workspace reaper (lib/workspace.sh) takes anything
# that still remains.
stage_workspace_remove() {
  local dir="$1"
  [[ -n "$dir" ]] || return 0
  [[ -e "$dir" || -L "$dir" ]] || return 0
  rm -rf -- "$dir" 2>/dev/null
  [[ -e "$dir" || -L "$dir" ]] || return 0
  if [[ -d "$dir" && ! -L "$dir" ]] && stage_boundary_present; then
    stage_boundary_as_stage find "$dir" -mindepth 1 -user stage -type d -exec chmod u+rwx {} \;
    stage_boundary_as_stage rm -rf -- "$dir"
    rm -rf -- "$dir" 2>/dev/null
  fi
  return 0
}

# stage_breadcrumb_pr_url FILE
# Print the pull-request URL a stage left in the breadcrumb FILE, or nothing.
# The file is the stage's: it can make it anything at all, including a link to
# a file only this user can read or a FIFO, and a live stage process can swap
# one for the other between any check and any open. So it is looked at only
# when it is a regular file and not a link, then read only as the stage user
# reads it and for ten seconds at most (`stage_boundary_read`), only its
# first 512 bytes, and only a first line that is exactly a github.com
# pull-request URL is printed. Nothing else it holds can reach a log, a forge
# call or a later prompt. Always returns 0.
stage_breadcrumb_pr_url() {
  local f="$1" line
  [[ -f "$f" && ! -L "$f" ]] || return 0
  line="$(stage_boundary_read "$f" 512 | head -n 1 | tr -d '[:space:]')"
  if [[ "$line" =~ ^https://github\.com/[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+/pull/[0-9]+$ ]]; then
    printf '%s\n' "$line"
  fi
  return 0
}
