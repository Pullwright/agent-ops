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
# HOME so the Claude-config seed and git config --global calls never touch
# anything outside $tmp_dir. Combines stdout and stderr, since say() (every
# message entrypoint.sh prints, guard included) writes to stdout.
run_entrypoint() {
  local cfg="$1"
  shift
  local home="$tmp_dir/home-$RANDOM"
  mkdir -p "$home"
  APP_DIR="$stub_app" CONFIG_FILE="$cfg" HOME="$home" GH_TOKEN="" \
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

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
