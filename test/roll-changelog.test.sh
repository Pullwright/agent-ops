#!/usr/bin/env bash
#
# test/roll-changelog.test.sh — regression test for
# scripts/roll-changelog.sh (agent-ops#1809, requirement 25e).
#
# Runs the actual shipped script against a real scratch git "origin" (a
# non-bare local repository `git push` reaches over the filesystem) rather
# than a reimplementation of its logic — the same pattern
# test/assemble-changelog.test.sh already uses for a script that needs a
# real git history to exercise honestly. `git clone`'s own URL is redirected
# to that local origin via CLONE_GIT (lib/repo-clone.sh's own test seam);
# `gh` is a stub via ROLL_GH (and, through it, MERGE_QUEUE_GH — see
# lib/merge-queue.sh), logging every call and serving fixed answers; no
# network.
#
# The "0 commits merged since the marker" no-op path (component 17d) is not
# reachable through any real commit history: the marker's own value is
# necessarily the hash of a strict ancestor of whatever commit first carries
# it (a commit cannot embed its own hash — that would need a SHA-1
# preimage), so `git log MARKER..HEAD` always contains at least that
# introducing commit. It is tested directly instead, by shadowing `git` on
# PATH for that one case to answer the specific `log --first-parent
# --oneline <marker>..HEAD` query with nothing, passing every other
# invocation through to the real binary unchanged.
#
# Run directly: ./test/roll-changelog.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROLL="$SCRIPT_DIR/scripts/roll-changelog.sh"

failures=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; failures=$(( failures + 1 )); }
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$desc"
  else
    printf 'FAIL - %s\n     expected: %s\n     actual:   %s\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}
assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$desc"
  else
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:               %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}
assert_not_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass "$desc"
  else
    printf 'FAIL - %s\n     expected NOT to contain: %s\n     actual:                   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

origin="$work/origin"
git init -q -b main "$origin"
git -C "$origin" config user.email test@example.com
git -C "$origin" config user.name test

mkdir -p "$origin/scripts" "$origin/lib"
cp "$SCRIPT_DIR/scripts/assemble-changelog.sh" "$origin/scripts/assemble-changelog.sh"
cp "$SCRIPT_DIR/lib/changelog-grammar.sh" "$origin/lib/changelog-grammar.sh"
chmod +x "$origin/scripts/assemble-changelog.sh"

# --- CLONE_GIT: redirect the fabricated GitHub URL to the local origin ------
clone_stub="$work/clone-git-stub"
cat > "$clone_stub" <<STUB
#!/usr/bin/env bash
if [[ "\$1" == "clone" ]]; then
  shift
  args=()
  for a in "\$@"; do
    if [[ "\$a" == https://github.com/*.git ]]; then
      args+=("$origin")
    else
      args+=("\$a")
    fi
  done
  exec git clone "\${args[@]}"
fi
exec git "\$@"
STUB
chmod +x "$clone_stub"

# --- ROLL_GH: a stub `gh`, dispatching on the argument shape the script
# actually uses, logging every call to calls.log and serving fixtures from
# $work/existing-pr-number and $work/queued. ---------------------------------
gh_calls="$work/calls.log"
gh_stub="$work/gh-stub"
cat > "$gh_stub" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$gh_calls"
case "\$1 \$2" in
  "pr list")
    [[ -f "$work/existing-pr-number" ]] && cat "$work/existing-pr-number"
    exit 0 ;;
  "pr create")
    echo 999 > "$work/existing-pr-number"
    echo "https://github.com/test-owner/test-repo/pull/999"
    exit 0 ;;
  "pr edit")
    exit 0 ;;
  "api graphql")
    if [[ -f "$work/queued" ]]; then
      echo '{"queued": true, "dequeued_at": null, "dequeue_reason": null}'
    else
      echo '{"queued": false, "dequeued_at": null, "dequeue_reason": null}'
    fi
    exit 0 ;;
esac
exit 1
STUB
chmod +x "$gh_stub"

run() {
  rm -f "$gh_calls"
  env GIT_USER_NAME="Test Bot" GIT_USER_EMAIL="test-bot@example.invalid" \
    CLONE_GIT="$clone_stub" ROLL_GH="$gh_stub" \
    "$ROLL" test-owner/test-repo
}

roll_content() { git -C "$origin" show changelog-roll:CHANGELOG.md 2>/dev/null; }
roll_ref() { git -C "$origin" rev-parse --verify -q changelog-roll 2>/dev/null || echo "(none)"; }

# --- Migration: no marker at all -----------------------------------------------

cat > "$origin/CHANGELOG.md" <<'EOF'
# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- Some pre-convention hand written entry.
- Another one.
EOF
git -C "$origin" add -A
git -C "$origin" commit -q -m "chore: seed"

run >/dev/null 2>&1; rc=$?
assert_eq "the migration run exits 0" "0" "$rc"
content="$(roll_content)"
assert_contains "the migration renames the old section to #1810's own merge date" "$content" "## [2026-09-23]"
assert_contains "  ... unchanged, byte for byte" "$content" "- Some pre-convention hand written entry."
assert_contains "  ... every bullet" "$content" "- Another one."
assert_contains "  ... and opens a fresh, empty Unreleased above it" "$content" $'## [Unreleased]\n\n## [2026-09-23]'
assert_contains "  ... and sets the marker to #1810's own squash-merge commit" "$content" \
  "<!-- changelog:assembled-through sha=5e78f991c282a0f858942fcd10066a39c102e365 -->"
assert_contains "a pull request is opened, carrying the migration date" "$(cat "$gh_calls")" "pr create"
assert_contains "  ... as a draft" "$(cat "$gh_calls")" "--draft"
assert_contains "  ... labelled" "$(cat "$gh_calls")" "--label autonomous-agent"

# --- Ordinary roll: a marker exists, real commits sit ahead of it -------------

git -C "$origin" checkout -q main
root_sha="$(git -C "$origin" rev-parse HEAD)"
cat > "$origin/CHANGELOG.md" <<EOF
# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

<!-- changelog:assembled-through sha=$root_sha -->

## [Unreleased]
EOF
git -C "$origin" add -A
git -C "$origin" commit -q -m "docs(changelog): seed a post-migration marker for the test fixture"

echo "widget" > "$origin/widget.txt"
git -C "$origin" add widget.txt
git -C "$origin" commit -q -m "$(printf 'feat: add a widget (#100)\n\n## Changelog\n\n### Added\n\n- A shiny new widget.\n')"
head_after_widget="$(git -C "$origin" rev-parse HEAD)"

today="$(date -u +%Y-%m-%d)"
rm -f "$work/existing-pr-number"
run >/dev/null 2>&1; rc=$?
assert_eq "the ordinary roll exits 0" "0" "$rc"
content="$(roll_content)"
assert_contains "assembled bullets land under today's dated heading" "$content" "## [${today}]"
assert_contains "  ... with the new Added category" "$content" "### Added"
assert_contains "  ... and the bullet, suffixed with its PR number" "$content" "- A shiny new widget. (#100)"
assert_contains "  ... and a fresh empty Unreleased above it" "$content" "## [Unreleased]"
assert_contains "  ... and the marker advances to the assembled range's own HEAD" "$content" \
  "<!-- changelog:assembled-through sha=${head_after_widget} -->"
assert_contains "a new pull request is opened (the migration's own already merged in spirit — a fresh branch state)" \
  "$(cat "$gh_calls")" "pr create"

# --- Update, not duplicate: a second run while the first pull request is
#     still open force-pushes the same branch and edits that pull request --

echo 999 > "$work/existing-pr-number"
run >/dev/null 2>&1; rc=$?
assert_eq "a second run with the pull request still open exits 0" "0" "$rc"
calls="$(cat "$gh_calls")"
assert_contains "it updates the existing pull request" "$calls" "pr edit 999"
assert_not_contains "  ... rather than opening a second one" "$calls" "pr create"

# --- Merge-queue awareness: a queued pull request is never pushed under ------

touch "$work/queued"
before_ref="$(roll_ref)"
run >/dev/null 2>&1; rc=$?
assert_eq "a queued pull request's run still exits 0" "0" "$rc"
after_ref="$(roll_ref)"
assert_eq "  ... and the branch is left untouched" "$before_ref" "$after_ref"
assert_not_contains "  ... no pull request edit is attempted" "$(cat "$gh_calls")" "pr edit"
rm -f "$work/queued"

# --- No-op: nothing has merged since the marker -------------------------------
#
# Unreachable through real commit history (see the file header); the check
# is exercised directly by shadowing `git log --first-parent --oneline
# <marker>..HEAD` for the one range this asks about, leaving every other
# invocation — clone, add, commit, push, diff, rev-parse — untouched.

real_git="$(command -v git)"
noop_marker="$(git -C "$origin" rev-parse HEAD)"
path_stub_dir="$work/path-stub"
mkdir -p "$path_stub_dir"
cat > "$path_stub_dir/git" <<STUB
#!/usr/bin/env bash
if [[ "\$*" == *"log --first-parent"* && "\$*" == *"${noop_marker}..HEAD"* ]]; then
  exit 0
fi
exec "$real_git" "\$@"
STUB
chmod +x "$path_stub_dir/git"

sed -i "s/^<!-- changelog:assembled-through sha=[0-9a-f]\{40\} -->\$/<!-- changelog:assembled-through sha=${noop_marker} -->/" \
  "$origin/CHANGELOG.md"
git -C "$origin" add -A
git -C "$origin" commit -q -m "docs(changelog): pin the marker to HEAD for the no-op test"
# The commit above moves HEAD past noop_marker by exactly one — the
# structural lag the file header explains — so the stub's own PATH-only
# effect (never CLONE_GIT, which still reaches the real binary directly) is
# what makes the range this test cares about read as empty despite that.

rm -f "$work/existing-pr-number" "$gh_calls"
before_ref="$(roll_ref)"
PATH="$path_stub_dir:$PATH" env GIT_USER_NAME="Test Bot" GIT_USER_EMAIL="test-bot@example.invalid" \
  CLONE_GIT="$clone_stub" ROLL_GH="$gh_stub" "$ROLL" test-owner/test-repo >/dev/null 2>&1; rc=$?
assert_eq "a no-op run exits 0" "0" "$rc"
after_ref="$(roll_ref)"
assert_eq "  ... and touches neither the branch" "$before_ref" "$after_ref"
assert_eq "  ... nor the pull request" "" "$(cat "$gh_calls" 2>/dev/null)"

echo
if (( failures > 0 )); then
  echo "$failures assertion(s) failed"
  exit 1
fi
echo "all assertions passed"
