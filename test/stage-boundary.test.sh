#!/usr/bin/env bash
#
# test/stage-boundary.test.sh — regression test for the boundary between the
# Script and its stages (requirement 45e): lib/stage-boundary.sh, the stage
# wrapper deploy/docker/stage-exec.sh, and — inside the node image, where the
# stage user and the sudoers rules exist — the boundary itself, across two
# real uids.
#
# Three parts:
#
#   1. lib/stage-boundary.sh on its own terms, anywhere: what a breadcrumb
#      read lets back out, what removal does with a tree it cannot remove
#      alone, and that sharing changes nothing where there is no boundary.
#   2. deploy/docker/stage-exec.sh run directly as this user: the environment
#      a stage is given, its own scratch directory, stdin and exit status
#      passing through, and the process group it stops — on a signal, and
#      when its parent dies.
#   3. In the image only (skipped, and said so, anywhere the rule is absent):
#      the stage user cannot read a file only the Script's user can, the
#      Script's environment, or write /app; a forge credential the Script
#      exports never reaches a stage; the stage user can run nothing as the
#      Script's user but the token helper; and a stage's processes do not
#      outlive the TERM or the KILL the Script sends its process group.
#
#   ./test/stage-boundary.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE_EXEC="$SCRIPT_DIR/deploy/docker/stage-exec.sh"

tmp_dir="$(mktemp -d)"
trap 'chmod -R u+rwx "$tmp_dir" 2>/dev/null; rm -rf "$tmp_dir"' EXIT

failures=0
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected: %s\n     actual:   %s\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}

# live_in_group PGID — how many processes in the group are still running
# (a zombie has finished; it is only waiting for whoever reaps it).
live_in_group() {
  ps -eo pgid=,stat= | awk -v g="$1" '$1 == g && $2 !~ /^Z/' | wc -l | tr -d ' '
}

# === 1. lib/stage-boundary.sh ===============================================

# shellcheck source=lib/stage-boundary.sh
. "$SCRIPT_DIR/lib/stage-boundary.sh"

crumb="$tmp_dir/crumb"
printf 'https://github.com/acme/widgets/pull/42\n' >"$crumb"
assert_eq "a breadcrumb holding a pull-request URL gives it back" \
  "https://github.com/acme/widgets/pull/42" "$(stage_breadcrumb_pr_url "$crumb")"
printf '  https://github.com/acme/widgets/pull/42  \r\nsecond line\n' >"$crumb"
assert_eq "  ... its first line only, whitespace stripped" \
  "https://github.com/acme/widgets/pull/42" "$(stage_breadcrumb_pr_url "$crumb")"
printf -- '-----BEGIN RSA PRIVATE KEY-----\nMIIE\n' >"$tmp_dir/secret.pem"
printf -- '-----BEGIN RSA PRIVATE KEY-----\n' >"$crumb"
assert_eq "a breadcrumb holding anything else gives nothing" "" "$(stage_breadcrumb_pr_url "$crumb")"
rm -f "$crumb"
ln -s "$tmp_dir/secret.pem" "$crumb"
assert_eq "a breadcrumb that is a link is never followed" "" "$(stage_breadcrumb_pr_url "$crumb")"
printf 'https://github.com/acme/widgets/pull/42\n' >"$tmp_dir/real-crumb"
rm -f "$crumb"; ln -s "$tmp_dir/real-crumb" "$crumb"
assert_eq "  ... even to a file that holds a pull-request URL" "" "$(stage_breadcrumb_pr_url "$crumb")"
rm -f "$crumb"; mkdir "$crumb"
assert_eq "a breadcrumb that is a directory gives nothing" "" "$(stage_breadcrumb_pr_url "$crumb")"
rmdir "$crumb"
{ head -c 600 /dev/zero | tr '\0' 'a'; printf 'https://github.com/acme/widgets/pull/42\n'; } >"$crumb"
assert_eq "only the first 512 bytes are read" "" "$(stage_breadcrumb_pr_url "$crumb")"
assert_eq "a missing breadcrumb gives nothing, successfully" "0" \
  "$(stage_breadcrumb_pr_url "$tmp_dir/absent" >/dev/null; echo $?)"
printf 'https://github.com/acme/widgets/pull/42; rm -rf /\n' >"$crumb"
assert_eq "a URL with anything after it gives nothing" "" "$(stage_breadcrumb_pr_url "$crumb")"

# Sharing is a no-op where there is no boundary, and refuses a link.
STAGE_BOUNDARY_GROUP="agent-ops-no-such-group"
mkdir -p "$tmp_dir/ws/sub"
before="$(stat -c '%G %a' "$tmp_dir/ws/sub")"
stage_workspace_share "$tmp_dir/ws"; rc=$?
assert_eq "without the stage group, sharing succeeds and changes nothing" \
  "0 $before" "$rc $(stat -c '%G %a' "$tmp_dir/ws/sub")"
ln -s "$tmp_dir/ws" "$tmp_dir/ws-link"
stage_workspace_share "$tmp_dir/ws-link"; rc=$?
assert_eq "sharing refuses a link" "1" "$rc"
stage_workspace_share "$tmp_dir/absent"; rc=$?
assert_eq "sharing refuses a path that is not a directory" "1" "$rc"

# Removal: a plain tree goes; a tree this user cannot remove alone is handed
# to the stage user (stubbed here as this same user, with `chmod` restored
# first, which is what the stage user can do with its own directories).
mkdir -p "$tmp_dir/rm1/a/b"; touch "$tmp_dir/rm1/a/b/f"
stage_workspace_remove "$tmp_dir/rm1"
assert_eq "removal takes a plain tree" "no" "$([[ -e "$tmp_dir/rm1" ]] && echo yes || echo no)"

mkdir -p "$tmp_dir/rm2/locked/deeper"; touch "$tmp_dir/rm2/locked/deeper/f"
chmod 000 "$tmp_dir/rm2/locked"
as_stage_calls="$tmp_dir/as-stage-calls"
stage_boundary_present() { return 0; }
stage_boundary_as_stage() {
  printf '%s\n' "$*" >>"$as_stage_calls"
  if [[ "$1" == find ]]; then
    chmod -R u+rwx "$tmp_dir/rm2" 2>/dev/null
  else
    "$@" 2>/dev/null
  fi
}
stage_workspace_remove "$tmp_dir/rm2"
assert_eq "removal hands a tree it cannot finish to the stage user" "no" \
  "$([[ -e "$tmp_dir/rm2" ]] && echo yes || echo no)"
assert_eq "  ... which first restores its own directories, then removes" \
  "find rm" "$(awk '{printf "%s ", $1}' "$as_stage_calls" | sed 's/ $//')"
: >"$as_stage_calls"
mkdir -p "$tmp_dir/rm3"
stage_workspace_remove "$tmp_dir/rm3"
assert_eq "  ... and is never called when this user managed alone" "" "$(cat "$as_stage_calls")"
unset -f stage_boundary_present stage_boundary_as_stage
. "$SCRIPT_DIR/lib/stage-boundary.sh"
STAGE_BOUNDARY_GROUP="agent-ops-no-such-group"
ln -s "$tmp_dir/ws" "$tmp_dir/rm-link"
stage_workspace_remove "$tmp_dir/rm-link"
assert_eq "removing a link removes the link and not what it names" "no yes" \
  "$([[ -e "$tmp_dir/rm-link" || -L "$tmp_dir/rm-link" ]] && echo yes || echo no) $([[ -d "$tmp_dir/ws/sub" ]] && echo yes || echo no)"
STAGE_BOUNDARY_GROUP="stage"

# === 2. deploy/docker/stage-exec.sh, run directly ===========================

broker="$tmp_dir/broker"
printf '#!/bin/sh\nexit 0\n' >"$broker"; chmod +x "$broker"
gitconfig="$tmp_dir/stage-gitconfig"; : >"$gitconfig"
stage_exec() {
  TMPDIR="$tmp_dir/outer-tmp" PW_STAGE_TOKEN_BROKER="$broker" PW_STAGE_GITCONFIG="$gitconfig" \
    AGENT_OPS_ROOT="$SCRIPT_DIR" PW_STAGE_KILL_GRACE=1 bash "$STAGE_EXEC" "$@"
}
mkdir -p "$tmp_dir/outer-tmp"

out="$(GH_TOKEN=ghp_x PW_GH_DEGRADE_TOKEN=ghp_y GITHUB_TOKEN=ghp_z NOTIFY_WEBHOOK_URL=https://hook \
  PULLWRIGHT_AUTHOR_PRIVATE_KEY_PATH=/k PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH=/k2 PW_GH_STATE_DIR=/s \
  GIT_USER_NAME="Node Bot" GIT_USER_EMAIL=bot@example.com \
  stage_exec bash -c 'env | sort' </dev/null)"
for name in GH_TOKEN PW_GH_DEGRADE_TOKEN GITHUB_TOKEN NOTIFY_WEBHOOK_URL \
            PULLWRIGHT_AUTHOR_PRIVATE_KEY_PATH PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH PW_GH_STATE_DIR; do
  assert_eq "the stage environment has no $name" "" "$(grep "^$name=" <<<"$out" || true)"
done
assert_eq "the stage authors through the token broker" "PW_GH_TOKEN_BROKER=$broker" \
  "$(grep '^PW_GH_TOKEN_BROKER=' <<<"$out")"
assert_eq "  ... with its own global git configuration" "GIT_CONFIG_GLOBAL=$gitconfig" \
  "$(grep '^GIT_CONFIG_GLOBAL=' <<<"$out")"
assert_eq "  ... and the node's identity as author and committer" \
  "GIT_AUTHOR_EMAIL=bot@example.com GIT_AUTHOR_NAME=Node Bot GIT_COMMITTER_EMAIL=bot@example.com GIT_COMMITTER_NAME=Node Bot" \
  "$(grep -E '^GIT_(AUTHOR|COMMITTER)_' <<<"$out" | tr '\n' ' ' | sed 's/ $//')"
stage_tmp="$(sed -n 's/^TMPDIR=//p' <<<"$out")"
assert_eq "the stage has a scratch directory of its own" "yes" \
  "$([[ "$stage_tmp" == /tmp/agent-ops.stage.* ]] && echo yes || echo no)"
assert_eq "  ... removed when it ends" "no" "$([[ -e "$stage_tmp" ]] && echo yes || echo no)"
assert_eq "files it creates stay writable by the Script's group" "0002" \
  "$(stage_exec bash -c umask </dev/null)"

out="$(printf 'the prompt\n' | stage_exec bash -c 'cat; exit 7')"; rc=$?
assert_eq "stdin reaches the command" "the prompt" "$out"
assert_eq "  ... and its exit status comes back" "7" "$rc"
stage_exec </dev/null; rc=$?
assert_eq "no command is refused" "2" "$rc"

# A signal to the wrapper — what sudo relays — stops the whole group.
set -m
stage_exec bash -c 'sleep 300 & sleep 300 & wait' </dev/null &
job=$!
set +m
sleep 1.5
assert_eq "a running stage has its processes in its group" "yes" \
  "$( (( $(live_in_group "$job") >= 3 )) && echo yes || echo no)"
wrapper_pid="$(ps -eo pid=,pgid=,args= | awk -v g="$job" '$2 == g && /--supervised/ {print $1; exit}')"
kill -TERM "$wrapper_pid"
wait "$job" 2>/dev/null
# The wrapper itself lives through its grace (one second here) before the KILL.
sleep 2
assert_eq "TERM to the wrapper stops every process in the group" "0" "$(live_in_group "$job")"

# Its parent dying — sudo, killed — stops the whole group too.
set -m
bash -c "TMPDIR='$tmp_dir/outer-tmp' PW_STAGE_TOKEN_BROKER='$broker' PW_STAGE_GITCONFIG='$gitconfig' AGENT_OPS_ROOT='$SCRIPT_DIR' PW_STAGE_KILL_GRACE=1 bash '$STAGE_EXEC' bash -c 'sleep 300 & sleep 300 & wait' </dev/null; :" &
job=$!
set +m
sleep 1.5
kill -KILL "$job"
wait "$job" 2>/dev/null
sleep 2.5
assert_eq "the wrapper's parent being killed stops every process in the group" "0" "$(live_in_group "$job")"

# === 3. The boundary itself, in the image ===================================

if ! ( cd / && sudo -n -u stage /usr/local/libexec/agent-ops/stage-exec true ) >/dev/null 2>&1; then
  printf 'skip - the stage user and its sudoers rule are not here (not the node image)\n'
else
  as_stage() { ( cd / && sudo -n -u stage /usr/local/libexec/agent-ops/stage-exec "$@" ); }

  assert_eq "the wrapper runs as the stage user" "stage" "$(as_stage id -un 2>/dev/null)"
  assert_eq "claude on PATH is the shim that runs it as the stage user" \
    "/usr/local/bin/claude" "$(command -v claude)"

  open_dir="$(mktemp -d /tmp/stage-boundary-open.XXXXXX)"
  chmod 755 "$open_dir"
  printf 'secret\n' >"$open_dir/key.pem"; chmod 600 "$open_dir/key.pem"
  assert_eq "the stage user cannot read a file only this user can" "denied" \
    "$(as_stage cat "$open_dir/key.pem" >/dev/null 2>&1 && echo read || echo denied)"
  assert_eq "  ... nor this process's environment" "denied" \
    "$(as_stage cat "/proc/$$/environ" >/dev/null 2>&1 && echo read || echo denied)"
  assert_eq "  ... nor write /app" "denied" \
    "$(as_stage touch /app/stage-boundary-probe >/dev/null 2>&1 && echo wrote || echo denied)"
  assert_eq "  ... nor a directory of this user's that was not shared" "denied" \
    "$(as_stage touch "$open_dir/planted" >/dev/null 2>&1 && echo wrote || echo denied)"
  out="$(GH_TOKEN=ghp_x PW_GH_DEGRADE_TOKEN=ghp_y PULLWRIGHT_AUTHOR_PRIVATE_KEY_PATH=/k \
    as_stage env 2>/dev/null)"
  assert_eq "  ... and never receives a forge credential this user exports" "" \
    "$(grep -E '^(GH_TOKEN|PW_GH_DEGRADE_TOKEN|PULLWRIGHT_)' <<<"$out" || true)"
  assert_eq "the stage user may run nothing as this user but the token helper" "refused" \
    "$(as_stage sudo -n -u agent id >/dev/null 2>&1 && echo ran || echo refused)"
  assert_eq "  ... and the helper refuses a malformed owner" "2" \
    "$(as_stage /usr/local/libexec/agent-ops/forge-token-request 'a b' >/dev/null 2>&1; echo $?)"

  # A shared workspace: the stage writes it, this user removes it, even
  # after the stage has locked part of it.
  ws="$(mktemp -d /tmp/stage-boundary-ws.XXXXXX)"
  chmod 755 "$ws"; mkdir "$ws/tree"; touch "$ws/tree/from-script"
  stage_workspace_share "$ws"; rc=$?
  assert_eq "sharing a workspace succeeds" "0" "$rc"
  assert_eq "  ... and the stage user can then write in it" "wrote" \
    "$(as_stage bash -c "mkdir -p '$ws/tree/locked/in' && touch '$ws/tree/locked/in/f'" >/dev/null 2>&1 && echo wrote || echo denied)"
  as_stage chmod 000 "$ws/tree/locked" >/dev/null 2>&1
  stage_workspace_remove "$ws"
  assert_eq "a workspace the stage locked part of is still removed" "no" \
    "$([[ -e "$ws" ]] && echo yes || echo no)"

  # The Script's group signals reach sudo only; the wrapper must stop the rest.
  set -m
  ( exec sudo -n -u stage /usr/local/libexec/agent-ops/stage-exec bash -c 'sleep 300 & sleep 300 & wait' ) </dev/null &
  job=$!
  set +m
  sleep 1.5
  kill -TERM "-$job" 2>/dev/null
  wait "$job" 2>/dev/null
  sleep 4.5
  assert_eq "TERM to a stage's group leaves none of the stage user's processes running" "0" \
    "$(live_in_group "$job")"
  set -m
  ( exec sudo -n -u stage /usr/local/libexec/agent-ops/stage-exec bash -c 'sleep 300 & sleep 300 & wait' ) </dev/null &
  job=$!
  set +m
  sleep 1.5
  kill -KILL "-$job" 2>/dev/null
  wait "$job" 2>/dev/null
  sleep 4.5
  assert_eq "KILL to a stage's group, as a cycle's handler sends, leaves none running either" "0" \
    "$(live_in_group "$job")"
  rm -rf "$open_dir"
fi

printf '\n'
if (( failures == 0 )); then
  printf 'all assertions passed\n'
  exit 0
fi
printf '%d assertion(s) failed\n' "$failures"
exit 1
