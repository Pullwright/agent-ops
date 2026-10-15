#!/usr/bin/env bash
#
# test/stage-snapshot.test.sh — the watchdog/backstop kill's recovery net
# (issue #2186): a stage stopped by one of `run_model_stage`'s caps while its
# working tree carries real, uncommitted work must not lose that work to the
# clone's own disposal. `_stage_snapshot_and_push` (lib/stage-run.sh) is what
# closes that gap — it commits and pushes whatever the stage's CWD holds,
# as the stage user, in the pause between the TERM and the KILL every cap
# already sends.
#
# Two things matter here, and they are opposite findings:
#
#   real work survives      a stage killed mid-verification, after making a
#                            real change it never got around to committing
#                            itself, still leaves that change on the claimed
#                            branch — the one thing `release_branch_if_
#                            untouched` (lib/claim.sh) and the orphan-branch
#                            sweep (requirement 17b) both need to recover it.
#   a clean stage is unchanged   a stage that never touched its working tree
#                            is exactly as reapable after this change as
#                            before it: nothing is committed, nothing is
#                            pushed, and `git status --porcelain` finding
#                            nothing is what this function treats as "there is
#                            no snapshot to take", not an error.
#
# `claude` is a stub on PATH — no network, no model, no cost. `origin` is a
# real local bare repository — no GitHub, no network — so the push this test
# watches for is a real `git push`, not a mock of one.
#
# `STAGE_BOUNDARY_GROUP` is forced to a group that does not exist, exactly as
# test/stage-boundary.test.sh's own "no boundary" part does: there is no stage
# user in a plain checkout (or in this test's own sandbox, which may
# coincidentally belong to a group of that name for unrelated reasons), so
# every git operation below runs directly as this user instead of through
# `sudo -u stage`, on the same terms `lib/stage-boundary.sh` already documents
# for an installation with no boundary at all.
#
# Run directly: ./test/stage-snapshot.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# No boundary for this test: see the header note above.
STAGE_BOUNDARY_GROUP="agent-ops-no-such-group"

# shellcheck source=lib/stage-run.sh
. "$SCRIPT_DIR/lib/stage-run.sh"

# Read by the cycle scripts' signal handlers, which this file does not have.
# shellcheck disable=SC2034
stage_pid=""
# shellcheck disable=SC2034
stage_name=""

# --- The stub ---------------------------------------------------------------------
# One line, then silence — the shape test/stage-watchdog.test.sh calls
# "quiet": enough to prove the stage genuinely started and then stopped
# producing, which is what the watchdog is supposed to act on.
mkdir -p "$tmp_dir/bin"
cat >"$tmp_dir/bin/claude" <<'STUB'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' '{"type":"system","subtype":"init"}'
sleep "${STUB_HOLD:-60}"
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
STUB
chmod +x "$tmp_dir/bin/claude"
export PATH="$tmp_dir/bin:$PATH"

# --- A real local remote, so the push this test watches for is a real one ---------
origin="$tmp_dir/origin.git"
git init --quiet --bare "$origin"

make_clone() {  # make_clone NAME BRANCH -> prints the clone's directory
  local name="$1" branch="$2" dir
  dir="$tmp_dir/$name"
  git clone --quiet "$origin" "$dir" >/dev/null 2>&1
  git -C "$dir" config user.email test@example.invalid
  git -C "$dir" config user.name "Test"
  printf 'first\n' >"$dir/README.md"
  git -C "$dir" add README.md
  git -C "$dir" commit --quiet -m "chore: seed"
  git -C "$dir" push --quiet origin "HEAD:refs/heads/$branch" >/dev/null 2>&1
  git -C "$dir" checkout --quiet -b "$branch" 2>/dev/null || git -C "$dir" checkout --quiet "$branch"
  printf '%s\n' "$dir"
}

origin_head() {  # origin_head BRANCH -> the bare repo's own tip sha for BRANCH, or empty
  git -C "$origin" rev-parse "refs/heads/$1" 2>/dev/null
}

# --- 1. A stage killed mid-verification, with real uncommitted work -------------------
clone="$(make_clone work agent/2186)"
before_sha="$(origin_head agent/2186)"
printf 'in progress\n' >"$clone/NOTES.md"
printf 'changed\n' >>"$clone/README.md"
STUB_HOLD=60 run_model_stage wedged 120 test-model "a prompt" "$tmp_dir/wedged.out" "$clone" 4
rc=$?
assert_eq "a stage with real uncommitted work is still killed as wedged" "124" "$rc"
assert_eq "…attributed to the watchdog" "inactivity" "$stage_kill_reason"

after_sha="$(origin_head agent/2186)"
if [[ -n "$after_sha" && "$after_sha" != "$before_sha" ]]; then
  printf 'ok   - the claimed branch moved on origin: the snapshot was pushed\n'
else
  printf 'FAIL - the claimed branch did not move on origin\n     before: %s\n     after:  %s\n' \
    "$before_sha" "$after_sha"
  failures=$(( failures + 1 ))
fi

recovered="$tmp_dir/recovered"
git clone --quiet "$origin" "$recovered" >/dev/null 2>&1
git -C "$recovered" checkout --quiet agent/2186 >/dev/null 2>&1
assert_eq "the tracked file's uncommitted change reached origin" \
  "$(printf 'first\nchanged\n')" "$(cat "$recovered/README.md" 2>/dev/null)"
assert_eq "an untracked file reached origin too (git add -A, not add -u)" \
  "in progress" "$(cat "$recovered/NOTES.md" 2>/dev/null)"
assert_contains "the snapshot commit is Conventional-Commits-shaped, so CI's own format check does not fail the draft it lands on" \
  "chore:" "$(git -C "$recovered" log -1 --format=%s 2>/dev/null)"

# --- 2. A stage killed with nothing uncommitted is unaffected ---------------------
clean_clone="$(make_clone clean agent/9999)"
clean_before="$(origin_head agent/9999)"
STUB_HOLD=60 run_model_stage clean_wedged 120 test-model "a prompt" "$tmp_dir/clean_wedged.out" "$clean_clone" 4
rc=$?
assert_eq "a stage with nothing uncommitted is still killed the same way" "124" "$rc"
clean_after="$(origin_head agent/9999)"
assert_eq "…and origin's ref for it never moves: untouched stays untouched" \
  "$clean_before" "$clean_after"

# --- 3. The backstop's own kill gets the same net ----------------------------------
# A productively-looping stage (no inactivity cap tripped) still has real work
# worth saving when the wall clock, not the watchdog, is what stops it.
busy_clone="$(make_clone busy agent/4242)"
busy_before="$(origin_head agent/4242)"
printf 'busy work\n' >"$busy_clone/BUSY.md"
cat >"$tmp_dir/bin/claude" <<'STUB'
#!/usr/bin/env bash
cat > /dev/null
i=0
while (( i < ${STUB_HOLD:-30} )); do
  printf '%s\n' '{"type":"assistant","message":{}}'
  sleep 1
  i=$(( i + 1 ))
done
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"ok"}'
STUB
chmod +x "$tmp_dir/bin/claude"
STUB_HOLD=30 run_model_stage busy 4 test-model "a prompt" "$tmp_dir/busy.out" "$busy_clone" 120
rc=$?
assert_eq "a steadily-emitting stage still hits its backstop" "124" "$rc"
assert_eq "…attributed to the backstop, not the watchdog" "backstop" "$stage_kill_reason"
busy_after="$(origin_head agent/4242)"
if [[ -n "$busy_after" && "$busy_after" != "$busy_before" ]]; then
  printf 'ok   - a backstop kill snapshots and pushes too\n'
else
  printf 'FAIL - a backstop kill left the uncommitted work behind\n'
  failures=$(( failures + 1 ))
fi

printf '\n'
if (( failures )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
