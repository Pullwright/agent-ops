#!/usr/bin/env bash
#
# test/compose-reconcile.test.sh — the compose reconciler (lib/compose-
# reconcile.sh): what applies a merged compose.yaml to a node without a human,
# the way watchtower applies a merged image.
#
# The properties that matter, each one a way the thing could be worse than the
# manual ritual it replaces:
#
#   - it acts only on drift, and a second run after a successful one does
#     nothing at all — an actor on a five-minute tick that is not idempotent
#     recreates a node's whole stack every five minutes;
#   - a `${VAR}` the new file requires and the node's `.env` does not define
#     refuses the whole apply, changing nothing: compose would otherwise
#     interpolate an empty string and `up -d` would deploy it;
#   - a `${VAR:-default}` is not such a variable, and neither is `$$VAR` nor a
#     shell fragment in a comment — a scan that cannot tell those apart
#     refuses every node for ever;
#   - a cycle in flight defers it, exactly as `watchtower-pre-update.sh`
#     defers a roll, and a `roll-pending` marker defers it too — the same
#     marker the hook reads as licence to destroy a container is read here as
#     a reason to wait, so the two updaters never recreate one at once;
#   - the recreate never runs inside the project it recreates. `reconciler` is
#     one of the services an apply replaces, so an `up -d` driven from this
#     container stops the process driving it and leaves the project
#     part-applied; it is handed to a transient sibling instead, and the
#     property the tests hold it to is that every service is running once the
#     tick that asked for it has been killed part-way, exactly as a real apply
#     kills it;
#   - `applying` is on the marker before the recreate starts, so a heartbeat
#     from a node stopped mid-apply says so rather than repeating the verdict
#     of the tick before, and the next tick retries and settles it;
#   - a recreate that has not completed is retried even though the file it
#     installed has already cleared the drift that would otherwise be the only
#     thing asking — and a lock or a due roll arriving in between postpones
#     that retry rather than discarding it;
#   - the file is replaced *in place*, keeping its inode, because a bind mount
#     of a file pins the inode it was created against;
#   - `.env` is never written, and its values are never read;
#   - every event is a transition, not a tick.
#
# `docker` is stubbed throughout: this suite creates no container and reaches
# no socket. Every path the library reads is given explicitly
# (COMPOSE_RECONCILE_PROJECT_DIR / _IMAGE_FILE / _STATE_DIR / _CONFIG /
# _DOCKER / _NOW), the same way test/compose-drift.test.sh gives its own,
# because the CI suite runs inside the image where the defaults would answer
# for the build container instead of the fixture.
#
# Run directly: ./test/compose-reconcile.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/compose-reconcile.sh
. "$SCRIPT_DIR/lib/compose-reconcile.sh"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

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

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:              %s\n' \
      "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# --- The fixture ---------------------------------------------------------------
# A node's project directory (its compose.yaml and its .env), the image's own
# copy of compose.yaml, a state directory, a config.json of its own values —
# never this repository's, which must be free to change without moving a test
# — and a `docker` that records its arguments instead of running.

project="$tmp_dir/project"
state="$tmp_dir/state"
bin="$tmp_dir/bin"
mkdir -p "$project" "$state" "$bin"

config="$tmp_dir/config.json"
cat > "$config" <<'EOF'
{"lock_stale_after": 4, "repository_review": {"lock_stale_after": 6}}
EOF

export DOCKER_STUB_LOG="$tmp_dir/docker-calls.log"
: > "$DOCKER_STUB_LOG"

# What this stack's own containers answer to. The library asks the daemon
# which container it is running in — `$HOSTNAME` cannot say, since watchtower
# clones it forward across a roll — and then which image that container
# holds, so the stub has to answer both.
export DOCKER_STUB_SELF_ID=b0a1c2d3e4f5
export DOCKER_STUB_SELF_IMAGE=sha256:1111111111111111111111111111111111111111111111111111111111111111

# The project's services, and the file recording which of them are running.
# The list is the stub's own, not read out of the fixture compose file: what
# these assertions are about is what an `up -d` leaves behind, and the one
# name that matters in it is `reconciler` — the service the process driving
# that `up` is itself in.
export DOCKER_STUB_SERVICES='scheduler
collector
egress-proxy
dashboard
reconciler'
export DOCKER_STUB_RUNNING_FILE="$tmp_dir/running"

# The socket the sibling is handed. A plain file is enough: the library only
# ever mounts it by path and reads its group.
socket="$tmp_dir/docker.sock"
: > "$socket"

cat > "$bin/docker" <<'EOF'
#!/usr/bin/env bash
#
# The `docker` this suite gives the library. It records every call, answers
# the two questions the library asks about this container, and models what an
# `up -d` does to the project — including the part that is the whole point:
# the process driving the `up` is stopped by it, and whether the rest of the
# project ends up running depends on where that process was.
printf '%s\n' "$*" >> "$DOCKER_STUB_LOG"

case "$1" in
  ps)      printf '%s\n' "$DOCKER_STUB_SELF_ID";    exit 0 ;;
  inspect) printf '%s\n' "$DOCKER_STUB_SELF_IMAGE"; exit 0 ;;
esac

# What is left running once this `up -d` has done what it can. From a sibling
# container, all of it: nothing the `up` stops is the process running it. From
# inside the project — `docker compose up -d` with no `run` in front of it —
# nothing at all: Compose creates each replacement, stops the old container,
# and reaches its own before it has started anything, so the project is left
# stopped or created-but-never-started. That second branch is this stub's
# whole reason for modelling the two shapes apart: it is what fails the
# "every service running" assertions below if the recreate ever moves back
# inside the project.
if [[ "${DOCKER_STUB_RC:-0}" == "0" ]]; then
  if [[ "$1" == run ]]; then
    printf '%s\n' "$DOCKER_STUB_SERVICES" > "$DOCKER_STUB_RUNNING_FILE"
  else
    : > "$DOCKER_STUB_RUNNING_FILE"
  fi
fi

# ... and the recreate stops the reconciler container itself, which is where
# this tick is running. The suite asks for that explicitly, per tick, so that
# the ticks modelling a container that survives its own apply — the retry,
# above all — are not killed here too.
if [[ -n "${DOCKER_STUB_KILL_FILE:-}" && -s "${DOCKER_STUB_KILL_FILE:-/dev/null}" ]]; then
  kill -9 "$(cat "$DOCKER_STUB_KILL_FILE")" 2>/dev/null
  sleep 1
fi

# Deliberately different on every call — compose's own last line carries
# per-run timings, and a verdict that folded that into the field the
# transition test compares would log one event per tick for ever.
printf 'Container agent-ops-scheduler-1  Recreated %s.%ss\n' "$RANDOM" "$RANDOM"
exit "${DOCKER_STUB_RC:-0}"
EOF
chmod +x "$bin/docker"

image_file="$tmp_dir/image-compose.yaml"
host_file="$project/compose.yaml"
env_file="$project/.env"
marker="$state/.compose-reconcile.json"
log_file="$state/log.jsonl"

# The image's copy. Deliberately carries all four shapes the variable scan has
# to tell apart: a defaulted reference, a required one, compose's `$$` escape,
# and — the one that is not hypothetical — a bare `${VAR}` inside a *comment*,
# which the real deploy/docker/compose.yaml carries today in the paragraph
# describing this very check. Compose parses YAML before it interpolates, so a
# comment is gone before interpolation begins; a scan that did not strip
# comments first would read that prose as a variable every node must define,
# and refuse every node for ever.
write_image_compose() {  # [extra line]
  cat > "$image_file" <<'EOF'
# The reference copy, as the image ships it.
# A comment full of things that look like configuration and are not:
#   every ${VAR} the new file requires is checked, and
#   pid=$(docker inspect -f '{{.State.Pid}}' "$c") && echo "/sys/fs/cgroup$pid"
name: agent-ops
services:
  scheduler:
    image: ${AGENT_OPS_IMAGE:-ghcr.io/pullwright/agent-ops:latest}
    environment:
      NODE_NAME: ${NODE_NAME}
    command:
      - bash
      - -c
      - |
        sleep "$$AGENT_OPS_INTERVAL_SECONDS"
EOF
  [[ $# -eq 0 ]] || printf '%s\n' "$1" >> "$image_file"
}

write_env() {  # <keys...>
  : > "$env_file"
  printf '# a node.env\n' >> "$env_file"
  local k
  for k in "$@"; do printf '%s=some-secret-value\n' "$k" >> "$env_file"; done
}

reset_fixture() {
  rm -rf "$project" "$state"
  mkdir -p "$project" "$state"
  write_image_compose
  # The node's own copy starts a release behind: one material line differs.
  sed 's/^name: agent-ops$/name: agent-ops-old/' "$image_file" > "$host_file"
  write_env NODE_NAME AGENT_OPS_IMAGE
  : > "$DOCKER_STUB_LOG"
  # The previous generation of the project, running the file about to be
  # replaced. Every apply below starts from here.
  printf '%s\n' "$DOCKER_STUB_SERVICES" > "$DOCKER_STUB_RUNNING_FILE"
  unset DOCKER_STUB_RC
}

run_reconcile() {  # [now]
  COMPOSE_RECONCILE_PROJECT_DIR="$project" \
  COMPOSE_RECONCILE_IMAGE_FILE="$image_file" \
  COMPOSE_RECONCILE_STATE_DIR="$state" \
  COMPOSE_RECONCILE_CONFIG="$config" \
  COMPOSE_RECONCILE_DOCKER="$bin/docker" \
  COMPOSE_RECONCILE_DOCKER_SOCKET="$socket" \
  COMPOSE_RECONCILE_NOW="${1:-2026-09-11T00:00:00Z}" \
  NODE_NAME=fixture-node \
    compose_reconcile_run
}

# The same tick, in a child process of its own that the stub ends the moment
# the recreate is asked for — which is what the recreate really does to the
# container this runs in. It has to be a separate process, not a subshell:
# what is being modelled is a tick that never returns to write a second
# verdict, and the suite has to survive it.
tick_script="$tmp_dir/tick.sh"
cat > "$tick_script" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$\$" > "\$DOCKER_STUB_KILL_FILE"
. "$SCRIPT_DIR/lib/compose-reconcile.sh"
compose_reconcile_run
EOF
chmod +x "$tick_script"

# Wrapped in a subshell whose stderr is discarded: a foreground command killed
# by a signal makes the shell that reaped it announce the fact, and that notice
# is this suite's own output, not a result. The trailing `:` is what keeps the
# subshell a shell — bash execs the last command of a subshell in place of it,
# which would put the pid the stub kills back in the outer shell's hands and
# the notice back on this suite's stderr.
run_reconcile_killed() {
  : > "$tmp_dir/tick.pid"
  ( DOCKER_STUB_KILL_FILE="$tmp_dir/tick.pid" \
  COMPOSE_RECONCILE_PROJECT_DIR="$project" \
  COMPOSE_RECONCILE_IMAGE_FILE="$image_file" \
  COMPOSE_RECONCILE_STATE_DIR="$state" \
  COMPOSE_RECONCILE_CONFIG="$config" \
  COMPOSE_RECONCILE_DOCKER="$bin/docker" \
  COMPOSE_RECONCILE_DOCKER_SOCKET="$socket" \
  COMPOSE_RECONCILE_NOW=2026-09-11T00:00:00Z \
  NODE_NAME=fixture-node \
    "$tick_script" >/dev/null 2>&1; : ) 2>/dev/null
}

docker_calls() { wc -l < "$DOCKER_STUB_LOG" | tr -d ' '; }
# `grep -c` exits 1 on no match having already printed `0`, so a bare
# `|| echo 0` fallback prints it twice — which reads as `0` in an assertion
# message and as a syntax error in arithmetic. One counter, used by all of
# them, that answers a number on every path including a missing file.
count_matching() {  # <pattern> <file>
  local n
  n="$(grep -c -- "$1" "$2" 2>/dev/null)" || n=0
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s' "$n"
}

# The two shapes an `up -d` can take, counted apart: one of them is the bug.
sibling_recreates()  { count_matching '^run --rm .* up -d --remove-orphans$' "$DOCKER_STUB_LOG"; }
in_place_recreates() { count_matching '^compose --project-directory' "$DOCKER_STUB_LOG"; }
running_services()   { sort "$DOCKER_STUB_RUNNING_FILE" 2>/dev/null | paste -sd, -; }
every_service()      { printf '%s\n' "$DOCKER_STUB_SERVICES" | sort | paste -sd, -; }
events_of()   { count_matching "\"event\":\"$1\"" "$log_file"; }
last_event()  { tail -n 1 "$log_file" 2>/dev/null; }

# --- The variable scan ---------------------------------------------------------
# Ahead of any run, because everything below depends on it being able to tell a
# required variable from the three things that merely look like one.

write_image_compose
assert_eq "only the undefaulted \${VAR} is required — a default, a \$\$ escape and a comment's own \${VAR} are not" \
  "NODE_NAME" "$(compose_reconcile_required_vars "$image_file" | paste -sd, -)"

# And the same scan over the file every node actually runs. This one is a
# standing guard rather than a fixture: it requires nothing today, every
# reference in it carrying a default, and a change that adds one without a
# default makes every node refuse the merged file until its .env defines that
# name by hand. If that is deliberate, say so here and in the rollout; if it
# is not, give the variable a default.
assert_eq "this repository's own compose.yaml requires no variable a node's .env must be taught" \
  "" "$(compose_reconcile_required_vars "$SCRIPT_DIR/deploy/docker/compose.yaml" | paste -sd, -)"

# shellcheck disable=SC2016  # the ${...} is compose's own interpolation, fed in literally
write_image_compose '    mem_limit: ${AGENT_OPS_MEM:?a node must size this}'
assert_eq "\${VAR:?…} is required too — it has no default, it has an error message" \
  "AGENT_OPS_MEM,NODE_NAME" "$(compose_reconcile_required_vars "$image_file" | paste -sd, -)"
write_image_compose

write_env NODE_NAME GH_TOKEN
assert_eq "the .env scan reports key names and never a value" \
  "GH_TOKEN,NODE_NAME" "$(compose_reconcile_env_keys "$env_file" | paste -sd, -)"

# --- No drift ------------------------------------------------------------------

reset_fixture
cp "$image_file" "$host_file"
verdict="$(run_reconcile)"
assert_eq "identical copies read in-sync" "in-sync" "$(jq -r '.status' <<<"$verdict")"
assert_eq "in-sync runs no docker command at all" "0" "$(docker_calls)"
assert_eq "in-sync is not an event — it is the steady state, and log.jsonl is replicated fleet-wide" \
  "0" "$( [[ -f "$log_file" ]] && wc -l < "$log_file" | tr -d ' ' || echo 0)"
assert_eq "the verdict is recorded even when there is nothing to do" \
  "in-sync" "$(jq -r '.status' "$marker")"

# --- The ordinary reconciliation ----------------------------------------------

reset_fixture
before_inode="$(stat -c %i "$host_file")"
before_env="$(sha256sum "$env_file" | cut -d' ' -f1)"
verdict="$(run_reconcile)"
assert_eq "drift with everything in place reconciles" "reconciled" "$(jq -r '.status' <<<"$verdict")"
assert_eq "the node's file is now the image's file, byte for byte" \
  "$(sha256sum "$image_file" | cut -d' ' -f1)" "$(sha256sum "$host_file" | cut -d' ' -f1)"
assert_eq "the verdict names both digests" \
  "$(sha256sum "$image_file" | cut -d' ' -f1)" "$(jq -r '.to' <<<"$verdict")"
assert_eq "and the digest it replaced" "1" \
  "$([[ "$(jq -r '.from' <<<"$verdict")" != "$(jq -r '.to' <<<"$verdict")" ]] && echo 1 || echo 0)"
assert_eq "the project is recreated through the node's own project directory" \
  "1" "$(grep -c -- "compose --project-directory $project up -d --remove-orphans" "$DOCKER_STUB_LOG")"
assert_eq "exactly one recreate, never one per service" "1" "$(sibling_recreates)"

# The whole of agent-ops#1913, in one assertion: `reconciler` is a service of
# the project this recreates, so an `up -d` run from inside this container
# stops the process running it and leaves the project part-applied. It took
# ockham-container's stack down on 2026-09-28.
assert_eq "the recreate is never run from inside the project it recreates" \
  "0" "$(in_place_recreates)"
assert_eq "it is handed to a transient sibling container instead" "1" "$(sibling_recreates)"
sibling_cmd="$(grep '^run --rm ' "$DOCKER_STUB_LOG" | tail -n 1)"
assert_contains "which is this very container's own image, by id" \
  "$DOCKER_STUB_SELF_IMAGE" "$sibling_cmd"
assert_contains "labelled for what it is" \
  "com.pullwright.agent-ops.compose-apply" "$sibling_cmd"
assert_contains "removing itself once the apply is done" "run --rm" "$sibling_cmd"
assert_contains "holding the Docker socket" "--volume $socket:$socket" "$sibling_cmd"
assert_contains "and the project directory at the same absolute path on both sides" \
  "--volume $project:$project" "$sibling_cmd"
assert_contains "with no network of its own, like the service that launched it" \
  "--network none" "$sibling_cmd"
assert_contains "running the Compose CLI over the image's own entrypoint" \
  "--entrypoint env" "$sibling_cmd"
# Not tidiness. Compose resolves a `${VAR}` from the process environment ahead
# of the project's `.env`, and this image's own `ENV` sets `TZ`, which
# `compose.yaml` interpolates: a sibling holding the image's environment would
# deploy every service with the image's `TZ` however the node's `.env` is
# written, quietly moving the hour that node's cron fires — on an apply whose
# whole claim is to install the merged file byte for byte. The container this
# runs in escapes it only because its own service declares `TZ: ${TZ:-UTC}`.
assert_contains "under a cleared environment, so the node's own .env is the only thing interpolation reads" \
  "-i PATH=" "$sibling_cmd"
assert_contains "with only the CLI's own two needs put back" "HOME=" "$sibling_cmd"
assert_contains "and then the Compose CLI itself" \
  "docker compose --project-directory $project up -d --remove-orphans" "$sibling_cmd"
# The name carries no timestamp on purpose: the `up` starts this container's
# replacement before the sibling has finished, that replacement's own first
# tick can fall due seconds later and will want a recreate of its own, and two
# `docker compose up -d` runs against one project take no lock against each
# other. A fixed name per node has the daemon refuse the second, which lands as
# an ordinary deferral.
assert_contains "named for this node alone, so the name is the mutex and not just a label" \
  "--name agent-ops-compose-apply-fixture-node " "$sibling_cmd"
assert_eq "the file keeps its inode — a bind-mounted file pins the inode it was created against" \
  "$before_inode" "$(stat -c %i "$host_file")"
assert_eq ".env is never written" "$before_env" "$(sha256sum "$env_file" | cut -d' ' -f1)"
assert_eq "no staging file is left behind in the node's stack directory" "0" \
  "$(find "$project" -maxdepth 1 -name '.compose.yaml.reconcile.*' | wc -l | tr -d ' ')"
assert_eq "one compose-reconciled event" "1" "$(events_of compose-reconciled)"
assert_eq "the event carries both digests" \
  "$(jq -r '.to' <<<"$verdict")" "$(jq -r '.to' <<<"$(last_event)")"
assert_eq "and no fabricated cycle id" "null" "$(jq -r '.cycle' <<<"$(last_event)")"
assert_eq "and this node's name" "fixture-node" "$(jq -r '.node' <<<"$(last_event)")"

assert_eq "and every service of the project is left running" \
  "$(every_service)" "$(running_services)"

# An apply that began is a record of its own, ahead of its outcome: a node
# whose apply dies mid-way must not go on publishing the verdict of the tick
# before it (agent-ops#1913).
assert_eq "an apply that began is logged before its outcome" "1" \
  "$(events_of compose-reconcile-applying)"
assert_eq "and the outcome after it" "1" "$(events_of compose-reconciled)"

# --- Idempotence ---------------------------------------------------------------

: > "$DOCKER_STUB_LOG"
verdict="$(run_reconcile 2026-09-11T00:05:00Z)"
assert_eq "the next tick finds nothing to do" "in-sync" "$(jq -r '.status' <<<"$verdict")"
assert_eq "and runs no docker command" "0" "$(docker_calls)"
assert_eq "and logs nothing further" "1" "$(events_of compose-reconciled)"

# --- A variable the node's .env does not define --------------------------------

reset_fixture
write_env AGENT_OPS_IMAGE          # NODE_NAME, which the new file requires, is gone
host_before="$(sha256sum "$host_file" | cut -d' ' -f1)"
verdict="$(run_reconcile)"
assert_eq "a missing required variable refuses" "refused" "$(jq -r '.status' <<<"$verdict")"
assert_contains "and names it" "NODE_NAME" "$(jq -r '.reason' <<<"$verdict")"
assert_eq "and applies nothing" "$host_before" "$(sha256sum "$host_file" | cut -d' ' -f1)"
assert_eq "and recreates nothing" "0" "$(docker_calls)"
assert_eq "one compose-reconcile-refused event" "1" "$(events_of compose-reconcile-refused)"

# The discriminating half: the same run, with the same .env, once the file's
# only requirement carries a default instead. A scan that cannot tell the two
# apart refuses every node for ever.
reset_fixture
write_env AGENT_OPS_IMAGE
# shellcheck disable=SC2016  # likewise: this rewrites compose's interpolation, not the shell's
sed -i 's/\${NODE_NAME}/${NODE_NAME:-unnamed}/' "$image_file"
verdict="$(run_reconcile)"
assert_eq "a defaulted variable is not a missing one" "reconciled" "$(jq -r '.status' <<<"$verdict")"

# --- A cycle in flight ---------------------------------------------------------

reset_fixture
lock_now() { printf '{"pid":1,"started_at":"%s","host":"agent-ops-scheduler"}\n' \
  "$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"; }
lock_now > "$state/lock.json"
host_before="$(sha256sum "$host_file" | cut -d' ' -f1)"
verdict="$(run_reconcile)"
assert_eq "an implementation cycle in flight defers" "deferred" "$(jq -r '.status' <<<"$verdict")"
assert_eq "and nothing is applied" "$host_before" "$(sha256sum "$host_file" | cut -d' ' -f1)"
assert_eq "and nothing is recreated" "0" "$(docker_calls)"
assert_eq "one compose-reconcile-deferred event" "1" "$(events_of compose-reconcile-deferred)"

# A tick every five minutes must leave one record of a deferral, not one per
# tick: a 40-minute cycle would otherwise put eight identical lines into a log
# replicated to every node in the fleet.
run_reconcile 2026-09-11T00:05:00Z >/dev/null
run_reconcile 2026-09-11T00:10:00Z >/dev/null
assert_eq "a deferral that has not changed is not logged again" \
  "1" "$(events_of compose-reconcile-deferred)"

# The same lock, past this fixture's own lock_stale_after: the hook stops
# honouring a lock exactly where the next cycle would take it over, and so
# does this.
printf '{"pid":1,"started_at":"%s","host":"agent-ops-scheduler"}\n' \
  "$(date -u -d '10 hours ago' +%Y-%m-%dT%H:%M:%SZ)" > "$state/lock.json"
verdict="$(run_reconcile 2026-09-11T00:15:00Z)"
assert_eq "a stale lock defers nothing" "reconciled" "$(jq -r '.status' <<<"$verdict")"

# --- A roll falling due -------------------------------------------------------
# The marker deploy/docker/watchtower-pre-update.sh reads as "you may destroy
# this container" is read here as "stand back": watchtower and this library
# recreate the same containers, and on ockham-container on 2026-09-28 the two
# were racing to recreate the same five within one second, with nothing
# surviving to say which stop was whose (agent-ops#1913). The wait is bounded
# by the marker's own `until` and by the next cycle clearing it once the roll
# has landed, so the apply arrives a cycle interval later at worst.

reset_fixture
printf '{"until":"%s"}\n' "$(date -u -d '30 minutes' +%Y-%m-%dT%H:%M:%SZ)" > "$state/roll-pending.json"
host_before="$(sha256sum "$host_file" | cut -d' ' -f1)"
verdict="$(run_reconcile)"
assert_eq "a live roll-pending marker defers, with no lock held at all" \
  "deferred" "$(jq -r '.status' <<<"$verdict")"
assert_contains "and says a roll is what it is waiting for" "roll" "$(jq -r '.reason' <<<"$verdict")"
assert_eq "and nothing is applied" "$host_before" "$(sha256sum "$host_file" | cut -d' ' -f1)"
assert_eq "and nothing is recreated" "0" "$(sibling_recreates)"

reset_fixture
lock_now > "$state/lock.json"
printf '{"until":"%s"}\n' "$(date -u -d '30 minutes' +%Y-%m-%dT%H:%M:%SZ)" > "$state/roll-pending.json"
verdict="$(run_reconcile)"
assert_eq "and a held lock.json is one more reason to wait, never an override of one" \
  "deferred" "$(jq -r '.status' <<<"$verdict")"

reset_fixture
lock_now > "$state/review-lock.json"
printf '{"until":"%s"}\n' "$(date -u -d '30 minutes' +%Y-%m-%dT%H:%M:%SZ)" > "$state/roll-pending.json"
verdict="$(run_reconcile)"
assert_eq "review-lock.json defers regardless, as it always has" \
  "deferred" "$(jq -r '.status' <<<"$verdict")"

reset_fixture
printf '{"until":"%s"}\n' "$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" > "$state/roll-pending.json"
verdict="$(run_reconcile)"
assert_eq "an expired marker holds nothing back — the roll it named has landed" \
  "reconciled" "$(jq -r '.status' <<<"$verdict")"

reset_fixture
printf '{"until":"not a date"}\n' > "$state/roll-pending.json"
verdict="$(run_reconcile)"
assert_eq "and neither does one whose 'until' will not parse" \
  "reconciled" "$(jq -r '.status' <<<"$verdict")"

# --- A recreate that failed ----------------------------------------------------
# The file is installed before `up -d` runs, so drift reads in-sync from that
# moment on: without the marker's own retry state, a failed recreate would
# leave the containers stale in exactly the silence this whole mechanism
# exists to end.

reset_fixture
DOCKER_STUB_RC=1
export DOCKER_STUB_RC
verdict="$(run_reconcile)"
assert_eq "a failed recreate defers rather than refusing — it is retried" \
  "deferred" "$(jq -r '.status' <<<"$verdict")"
assert_contains "and says what the recreate exited with" "exited 1" "$(jq -r '.reason' <<<"$verdict")"
assert_contains "carrying docker's own last line as detail, not as the reason" \
  "Recreated" "$(jq -r '.detail' <<<"$verdict")"
assert_eq "the file is installed regardless, so drift alone can no longer ask" \
  "$(sha256sum "$image_file" | cut -d' ' -f1)" "$(sha256sum "$host_file" | cut -d' ' -f1)"
assert_eq "so the retry rides on the verdict itself" "true" "$(jq -r '.pending_apply' "$marker")"
# The retry logs no second event, although docker's output differs every run:
# the varying half is `detail`, which the transition test does not compare.
run_reconcile 2026-09-11T00:05:00Z >/dev/null
run_reconcile 2026-09-11T00:10:00Z >/dev/null
assert_eq "a repeated failure whose docker output differs is still one event" \
  "1" "$(events_of compose-reconcile-deferred)"

# A lock taken, or a roll falling due, between the install and the retry
# postpones that retry; it must never discard it. The file is already
# installed by this point, so drift reads in-sync from here on and
# `pending_apply` is the only thing left that can ask for the recreate — a
# deferral that dropped it would leave the node running a compose.yaml none
# of its containers came from, for ever, in silence.
lock_now > "$state/lock.json"
verdict="$(run_reconcile 2026-09-11T00:12:00Z)"
assert_eq "a cycle starting mid-retry defers it" "deferred" "$(jq -r '.status' <<<"$verdict")"
assert_contains "naming the cycle, not the recreate" "implementation cycle" "$(jq -r '.reason' <<<"$verdict")"
assert_eq "and keeps the retry rather than dropping it" "true" "$(jq -r '.pending_apply' "$marker")"
rm -f "$state/lock.json"

unset DOCKER_STUB_RC
: > "$DOCKER_STUB_LOG"
verdict="$(run_reconcile 2026-09-11T00:15:00Z)"
assert_eq "the next tick retries the recreate even though there is no drift left" \
  "reconciled" "$(jq -r '.status' <<<"$verdict")"
assert_eq "and does recreate" "1" "$(sibling_recreates)"
assert_eq "and the retry state is cleared" "null" "$(jq -r '.pending_apply // null' "$marker")"

# --- The apply that recreates this very container ------------------------------
# The case agent-ops#1913 was filed over, and the one every real apply is:
# the compose change that drifted arrives on the same image roll that carries
# it, so `reconciler` is always among the services the apply recreates. The
# `up` therefore stops the container the tick is running in — modelled here
# exactly, by ending that tick where the recreate would — and what has to
# survive it is the project, not the tick.

reset_fixture
run_reconcile_killed
assert_eq "the tick that asked for the recreate does not live to settle it" \
  "applying" "$(jq -r '.status' "$marker")"
assert_eq "and says so before the recreate rather than after it, so no heartbeat reads the previous verdict through an apply" \
  "true" "$(jq -r '.pending_apply' "$marker")"
assert_eq "naming the file it installed" \
  "$(sha256sum "$image_file" | cut -d' ' -f1)" "$(jq -r '.to' "$marker")"
assert_eq "an apply that began is on the record even when nothing finished it" \
  "1" "$(events_of compose-reconcile-applying)"
assert_eq "and nothing claims it finished" "0" "$(events_of compose-reconciled)"
assert_eq "the recreate was never run from inside the project" "0" "$(in_place_recreates)"

# The acceptance criterion itself.
assert_eq "and every service of the project is running when it is over" \
  "$(every_service)" "$(running_services)"

# The successor, in the container the recreate created. Its own drift check
# reads in-sync — the file was installed before anything was recreated — so
# the marker is the only thing left that can ask, which is why it is written
# first.
: > "$DOCKER_STUB_LOG"
verdict="$(run_reconcile 2026-09-11T00:05:00Z)"
assert_eq "the next tick finishes what its predecessor started" \
  "reconciled" "$(jq -r '.status' <<<"$verdict")"
assert_eq "retrying the recreate rather than trusting it" "1" "$(sibling_recreates)"
assert_eq "and clearing the retry once it has actually returned" \
  "null" "$(jq -r '.pending_apply // null' "$marker")"
assert_eq "with the project still running" "$(every_service)" "$(running_services)"
assert_eq "one applying event across the two ticks, not one per tick" \
  "1" "$(events_of compose-reconcile-applying)"
assert_eq "and one reconciled event to close it" "1" "$(events_of compose-reconciled)"

# --- A container that cannot find itself --------------------------------------
# The sibling runs this container's own image, and the only way to that image
# is the daemon: `$HOSTNAME` is the container's short id at creation, but
# watchtower clones `Config.Hostname` forward across a roll, so after one it
# names a container that no longer exists. When the lookup comes up empty
# there is no sibling to hand the recreate to — and the one thing that must
# not happen then is running it here after all.

reset_fixture
host_before="$(sha256sum "$host_file" | cut -d' ' -f1)"
saved_self_id="$DOCKER_STUB_SELF_ID"
DOCKER_STUB_SELF_ID=""
verdict="$(run_reconcile)"
assert_eq "a container that cannot identify its own image defers" \
  "deferred" "$(jq -r '.status' <<<"$verdict")"
assert_contains "and says why" "cannot identify its own image" "$(jq -r '.reason' <<<"$verdict")"
assert_eq "installing nothing it has no way to apply" \
  "$host_before" "$(sha256sum "$host_file" | cut -d' ' -f1)"
assert_eq "and falling back to no recreate at all, least of all one from in here" \
  "0" "$(( $(sibling_recreates) + $(in_place_recreates) ))"
DOCKER_STUB_SELF_ID="$saved_self_id"

# --- A node that is not configured for this ------------------------------------

reset_fixture
verdict="$(COMPOSE_RECONCILE_PROJECT_DIR="" COMPOSE_RECONCILE_IMAGE_FILE="$image_file" \
  COMPOSE_RECONCILE_STATE_DIR="$state" COMPOSE_RECONCILE_CONFIG="$config" \
  COMPOSE_RECONCILE_DOCKER="$bin/docker" COMPOSE_RECONCILE_NOW=2026-09-11T00:00:00Z \
  compose_reconcile_run)"
assert_eq "no project directory refuses, rather than guessing at one" \
  "refused" "$(jq -r '.status' <<<"$verdict")"
assert_contains "and says what to set" "AGENT_OPS_PROJECT_DIR" "$(jq -r '.reason' <<<"$verdict")"

# --- Never non-zero ------------------------------------------------------------
# This runs from cron in a container whose only job it is. Nothing reads its
# exit status, and no verdict is worth one.

( set -e; run_reconcile >/dev/null )
assert_eq "no path returns non-zero" "0" "$?"

# --- The wiring ----------------------------------------------------------------
# The library is only ever reached through the compose service and the crontab
# that call it, exactly as compose-drift.sh is only ever armed through its own
# mount line — so losing either would silently disarm every node.

compose="$SCRIPT_DIR/deploy/docker/compose.yaml"

# The service's own block, cut out of the file: everything from its key to the
# next service's. Text, not a YAML parse — this image carries python3 but no
# PyYAML, and test/compose-drift.test.sh's own mount-line check sets the
# precedent that a wiring assertion here is a `grep` against the file the
# nodes actually run.
block="$(awk '/^  reconciler:$/ {inblock=1; next}
              inblock && /^  [a-z]/ {exit}
              inblock {print}' "$compose")"

has() { grep -qE "$1" <<<"$block" && echo 1 || echo 0; }

assert_eq "compose.yaml declares a reconciler service" "1" \
  "$([[ -n "$block" ]] && echo 1 || echo 0)"
assert_eq "in the auto-update profile, with watchtower — a node opted out of new images is opted out of new deployment files" \
  "1" "$(has '^ +profiles: \[auto-update\]$')"
assert_eq "it mounts the Docker socket read-write — recreating containers is the job" \
  "1" "$(has '^ +- /var/run/docker\.sock:/var/run/docker\.sock$')"
assert_eq "and the node's project directory at the same absolute path on both sides" \
  "1" "$(has '^ +- \$\{AGENT_OPS_PROJECT_DIR:-/dev/null\}:\$\{AGENT_OPS_PROJECT_DIR:-/dev/null\}$')"
assert_eq "and runs its own crontab under supercronic" \
  "1" "$(has '^ +command: \[.supercronic., ./app/deploy/docker/reconcile-crontab.\]$')"
assert_eq "and has no network at all — a container holding the socket needs no route out" \
  "1" "$(has '^ +network_mode: none$')"
# The credential check is the containment claim the PR makes, so it is pinned
# rather than trusted to the reading: this service must take neither shared
# anchor, because those carry every token and both App private keys.
assert_eq "and takes neither credential anchor" "0" \
  "$(grep -cE '^ +<<: \*agent-ops(-env)?$' <<<"$block")"
assert_eq "and names no secret of its own" "0" \
  "$(grep -cE 'GH_TOKEN|ANTHROPIC_API_KEY|PRIVATE_KEY' <<<"$block")"

assert_eq "the reconciler's crontab runs the script the image ships" "1" \
  "$(grep -cE '^\*/[0-9]+ \* \* \* \*[[:space:]]+/app/scripts/reconcile-compose\.sh$' \
     "$SCRIPT_DIR/deploy/docker/reconcile-crontab")"
assert_eq "and that script is executable, since supercronic execs it directly" "1" \
  "$([[ -x "$SCRIPT_DIR/scripts/reconcile-compose.sh" ]] && echo 1 || echo 0)"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
