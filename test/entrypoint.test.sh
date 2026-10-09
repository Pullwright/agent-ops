#!/usr/bin/env bash
#
# test/entrypoint.test.sh — deploy/docker/entrypoint.sh's config guard
# (require_string_config, issue #1884/PR #1888) and its volume preparation.
#
# entrypoint.sh hardcodes APP_DIR=/app and reads CONFIG_FILE from it, so it
# cannot be exercised against a real container here; both are overridable
# from the environment for exactly this reason (issue #1890), and every
# invocation below runs the real script — never a copy of its logic — with
# APP_DIR pointed at a throwaway stub layout instead of a real image.
#
# The properties that matter:
#   - require_string_config rejects a missing key, an explicit null, a
#     number, an array and an empty string for both state_dir and
#     workspace_root, each with exit status 1 and the guard's own
#     "ERROR: $CONFIG_FILE's <key> is missing or not a string" line (say's
#     own "entrypoint: " prefix, printed to stdout — say has no stream
#     redirection of its own, so that is where the line actually lands);
#   - a config where both keys are valid strings reaches past the guard and
#     the script runs to `exec "$@"` cleanly, with no guard error printed;
#   - a fresh Claude configuration volume's settings.json is seeded mode 640
#     (requirement 4k/45e, issue #2251), never group-writable; an existing
#     volume whose settings.json is group-writable (the shape the stage user
#     could reach before this fix), or is a symbolic link, dangling or not
#     (the shape it can still plant, having write permission on the
#     directory), has it quarantined to a `.quarantined-<timestamp>` sibling
#     and the seed restored, naming both files, writing nothing through the
#     link and still reaching its own `exec`; and a volume already in the
#     correct shape is left untouched;
#   - none of this touches a real container, the real HOME, or the network:
#     every invocation gets its own HOME and a stub APP_DIR carrying just
#     enough of a layout (an empty claude-settings.json, a no-op
#     author-token.sh, a no-op render-crontab.sh) for the script's own
#     earlier sections — the Claude-config seed and the git-credential
#     wiring, both of which run before the guard — to complete without
#     needing real credentials.
#
# Run directly: ./test/entrypoint.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRYPOINT="$SCRIPT_DIR/deploy/docker/entrypoint.sh"

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

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s\n     expected NOT to contain: %s\n     actual:   %s\n' "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# A minimal stand-in for a real /app: just enough that the script's own
# Claude-config seed and git-credential wiring — both of which run before
# require_string_config, since the guard sits immediately ahead of the
# state_dir/workspace_root reads rather than at the top of the file — finish
# without a real image, real credentials or any network access.
stub_app="$tmp_dir/app"
mkdir -p "$stub_app/deploy/docker" "$stub_app/lib"
printf '{}\n' > "$stub_app/deploy/docker/claude-settings.json"
cat > "$stub_app/lib/author-token.sh" <<'EOF'
author_token_credential_present() { return 1; }
EOF
cat > "$stub_app/deploy/docker/render-crontab.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$stub_app/deploy/docker/render-crontab.sh"

write_config() {  # write_config <path> <json>
  printf '%s' "$2" > "$1"
}

# run_entrypoint <config-file> [command...] — runs the real entrypoint.sh
# against the stub APP_DIR above and the given config, with its own throwaway
# HOME (unless PRESET_HOME names one, for a test that must plant something in
# $HOME/.claude before the entrypoint runs, or must find what it seeded there
# afterwards — run_entrypoint is always called inside a `$(...)` capturing its
# stdout, so a `local home` set inside it is a subshell's and never reaches
# the caller) so the Claude-config seed and git config --global calls never
# touch anything outside $tmp_dir. Combines stdout and stderr, since say()
# (every message entrypoint.sh prints, guard included) writes to stdout.
run_entrypoint() {
  local cfg="$1" home
  shift
  home="${PRESET_HOME:-$tmp_dir/home-$RANDOM}"
  mkdir -p "$home"
  # CLAUDE_CONFIG_DIR is pinned here, not merely left to entrypoint.sh's own
  # HOME-relative default, because an ambient value (set by whatever runs
  # this test — an interactive Claude Code session's own environment does)
  # would otherwise leak straight through `: "${CLAUDE_CONFIG_DIR:=...}"` and
  # point every assertion below at a real, already-seeded volume instead of
  # this test's own throwaway one.
  APP_DIR="$stub_app" CONFIG_FILE="$cfg" HOME="$home" CLAUDE_CONFIG_DIR="$home/.claude" GH_TOKEN="" \
    bash "$ENTRYPOINT" "$@" 2>&1
}

# --- require_string_config: five failing shapes, for each of the two keys
#     it guards, holding the other key valid so only the key under test can
#     be the one that trips the guard -------------------------------------

other_key() { [[ "$1" == state_dir ]] && printf 'workspace_root' || printf 'state_dir'; }

for key in state_dir workspace_root; do
  other="$(other_key "$key")"

  cfg="$tmp_dir/${key}-absent.json"
  write_config "$cfg" "$(jq -n --arg ok "$other" '{($ok): "/valid/path"}')"
  out="$(run_entrypoint "$cfg" true)"; rc=$?
  assert_eq "$key absent: exit status 1" "1" "$rc"
  assert_contains "$key absent: exact guard error" \
    "entrypoint: ERROR: $cfg's $key is missing or not a string" "$out"

  for case_name_value in 'null:null' 'a number:5' 'an array:[]' 'an empty string:""'; do
    case_name="${case_name_value%%:*}"
    bad_json="${case_name_value#*:}"
    cfg="$tmp_dir/${key}-${case_name// /-}.json"
    write_config "$cfg" "$(jq -n --arg ok "$other" --arg bk "$key" --argjson bv "$bad_json" \
      '{($ok): "/valid/path", ($bk): $bv}')"
    out="$(run_entrypoint "$cfg" true)"; rc=$?
    assert_eq "$key is $case_name: exit status 1" "1" "$rc"
    assert_contains "$key is $case_name: exact guard error" \
      "entrypoint: ERROR: $cfg's $key is missing or not a string" "$out"
  done
done

# --- Both keys valid: past the guard, the script runs to `exec "$@"` -------

valid_cfg="$tmp_dir/valid.json"
write_config "$valid_cfg" "$(jq -n --arg s "$tmp_dir/state" --arg w "$tmp_dir/workspace" \
  '{state_dir: $s, workspace_root: $w}')"
out="$(run_entrypoint "$valid_cfg" true)"; rc=$?
assert_eq "both keys valid: reaches exec \"\$@\" and the command exits 0" "0" "$rc"
assert_not_contains "both keys valid: no guard error printed" "is missing or not a string" "$out"
assert_eq "both keys valid: state_dir created" "true" "$([[ -d "$tmp_dir/state" ]] && echo true || echo false)"
assert_eq "both keys valid: workspace_root created" "true" "$([[ -d "$tmp_dir/workspace" ]] && echo true || echo false)"

# --- The Claude configuration volume's settings.json (requirement 4k/45e,
#     issue #2251): never left group-writable, and never reused once it is --

PRESET_HOME="$tmp_dir/fresh-volume"
out="$(run_entrypoint "$valid_cfg" true)"; rc=$?
unset PRESET_HOME
seeded="$tmp_dir/fresh-volume/.claude/settings.json"
assert_eq "a fresh volume: entrypoint exits 0" "0" "$rc"
assert_contains "a fresh volume: seeded, named on stdout" "seeded $seeded" "$out"
assert_eq "a fresh volume: settings.json exists" "true" "$([[ -e "$seeded" ]] && echo true || echo false)"
assert_eq "a fresh volume: settings.json is mode 640" "640" "$(stat -c %a "$seeded" 2>/dev/null)"

# A volume an older entrypoint (or, before this fix, the stage user itself)
# left group-writable: the quarantine must fire even though nothing here can
# make the file stage-*owned* (the test has no privilege to chown), since
# group-writable alone is already the exposure #2251 describes.
PRESET_HOME="$tmp_dir/existing-volume"
mkdir -p "$PRESET_HOME/.claude"
printf '{"apiKeyHelper":"/tmp/evil"}\n' >"$PRESET_HOME/.claude/settings.json"
chmod 664 "$PRESET_HOME/.claude/settings.json"
out="$(run_entrypoint "$valid_cfg" true)"; rc=$?
unset PRESET_HOME
mapfile -t quarantined < <(find "$tmp_dir/existing-volume/.claude" -maxdepth 1 \
  -name 'settings.json.quarantined-*' 2>/dev/null)
seeded="$tmp_dir/existing-volume/.claude/settings.json"
assert_eq "a group-writable existing file: entrypoint exits 0" "0" "$rc"
assert_eq "a group-writable existing file: exactly one quarantined copy" \
  "1" "${#quarantined[@]}"
assert_contains "a group-writable existing file: the warning names the original" \
  "$seeded" "$out"
assert_contains "a group-writable existing file: the warning names the quarantined copy" \
  "${quarantined[0]:-}" "$out"
assert_eq "a group-writable existing file: the quarantined copy keeps the old content" \
  '{"apiKeyHelper":"/tmp/evil"}' "$(cat "${quarantined[0]:-/dev/null}" 2>/dev/null)"
assert_eq "a group-writable existing file: the seed is restored" \
  "true" "$([[ -e "$seeded" ]] && echo true || echo false)"
assert_eq "a group-writable existing file: the restored seed is mode 640" \
  "640" "$(stat -c %a "$seeded" 2>/dev/null)"
assert_eq "a group-writable existing file: the restored seed is not group-writable" \
  "0" "$(find "$seeded" -perm -g+w 2>/dev/null | wc -l)"

# A volume whose settings.json is already correct — agent-owned, mode 640 —
# is left exactly as it is: no quarantine, no second "seeded" line.
PRESET_HOME="$tmp_dir/clean-volume"
mkdir -p "$PRESET_HOME/.claude"
printf '{"effortLevel":"max"}\n' >"$PRESET_HOME/.claude/settings.json"
chmod 640 "$PRESET_HOME/.claude/settings.json"
out="$(run_entrypoint "$valid_cfg" true)"; rc=$?
unset PRESET_HOME
seeded="$tmp_dir/clean-volume/.claude/settings.json"
assert_eq "a clean existing file: entrypoint exits 0" "0" "$rc"
assert_not_contains "a clean existing file: no quarantine warning" "quarantined" "$out"
assert_not_contains "a clean existing file: not re-seeded" "seeded $seeded" "$out"
assert_eq "a clean existing file: content is untouched" \
  '{"effortLevel":"max"}' "$(cat "$seeded" 2>/dev/null)"

# A settings.json that is a symbolic link to a path that does not exist — the
# one shape neither the ownership nor the mode test can see, and the one the
# stage user can plant with a single `ln -s` into a directory it has write
# permission on. The link is quarantined like any other suspect file, and the
# seeding `cp` never runs against it: GNU `cp` refuses to write through a
# dangling link, and `set -e` would make that refusal kill the entrypoint
# before `exec "$@"`.
PRESET_HOME="$tmp_dir/symlink-volume"
mkdir -p "$PRESET_HOME/.claude"
ln -s "$PRESET_HOME/.claude/nowhere" "$PRESET_HOME/.claude/settings.json"
out="$(run_entrypoint "$valid_cfg" true)"; rc=$?
unset PRESET_HOME
mapfile -t quarantined < <(find "$tmp_dir/symlink-volume/.claude" -maxdepth 1 \
  -name 'settings.json.quarantined-*' 2>/dev/null)
seeded="$tmp_dir/symlink-volume/.claude/settings.json"
assert_eq "a dangling symlink: entrypoint exits 0, reaching its exec" "0" "$rc"
assert_eq "a dangling symlink: exactly one quarantined copy" "1" "${#quarantined[@]}"
assert_eq "a dangling symlink: the quarantined copy is the link itself" \
  "true" "$([[ -L "${quarantined[0]:-}" ]] && echo true || echo false)"
assert_contains "a dangling symlink: the warning names the quarantined copy" \
  "${quarantined[0]:-}" "$out"
assert_contains "a dangling symlink: the seed is restored, named on stdout" \
  "seeded $seeded" "$out"
assert_eq "a dangling symlink: the restored seed is a regular file" \
  "true" "$([[ -f "$seeded" && ! -L "$seeded" ]] && echo true || echo false)"
assert_eq "a dangling symlink: the restored seed is mode 640" \
  "640" "$(stat -c %a "$seeded" 2>/dev/null)"
assert_eq "a dangling symlink: nothing was written through the link" \
  "false" "$([[ -e "$tmp_dir/symlink-volume/.claude/nowhere" ]] && echo true || echo false)"

# The same link, but pointing at a file that does exist: `stat` would resolve
# it and report this user as the owner, so only the link test catches it.
PRESET_HOME="$tmp_dir/live-symlink-volume"
mkdir -p "$PRESET_HOME/.claude"
printf '{"apiKeyHelper":"/tmp/evil"}\n' >"$PRESET_HOME/.claude/elsewhere"
ln -s "$PRESET_HOME/.claude/elsewhere" "$PRESET_HOME/.claude/settings.json"
out="$(run_entrypoint "$valid_cfg" true)"; rc=$?
unset PRESET_HOME
seeded="$tmp_dir/live-symlink-volume/.claude/settings.json"
assert_eq "a live symlink: entrypoint exits 0" "0" "$rc"
assert_eq "a live symlink: the restored seed is a regular file" \
  "true" "$([[ -f "$seeded" && ! -L "$seeded" ]] && echo true || echo false)"
assert_eq "a live symlink: the seed did not overwrite the link's target" \
  '{"apiKeyHelper":"/tmp/evil"}' \
  "$(cat "$tmp_dir/live-symlink-volume/.claude/elsewhere" 2>/dev/null)"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
