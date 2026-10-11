#!/usr/bin/env bash
#
# test/stage-project-settings.test.sh — a stage is never launched in a
# directory whose Claude Code project settings could make the runner run
# something (requirement 4k), and never launched at all while the Claude
# configuration volume's own user-level settings.json could do the same
# (requirement 4k/45e, issue #2251).
#
# What this guards:
#
#   the allowlist
#     `stage_project_settings_refusal` passes a settings file only when every
#     key in it is inert, or is a hook or MCP-approval key that the image's
#     managed policy makes inert. `env`, the credential and telemetry helpers,
#     `processWrapper` and plugin enabling are refused with or without the
#     policy, because no managed key can switch them off; `hooks` is refused
#     when the policy is absent; and `permissions` passes only for its `allow`
#     list. A file that is not a JSON object is refused rather than guessed
#     at, and `settings.local.json` is vetted exactly as `settings.json` is.
#
#   where the file came from
#     The refusal says whether the commit the checkout holds carries the file
#     as the working tree does, because a file an earlier stage left in a
#     reused clone is refused too but appears nowhere in the pull request.
#
#   the launcher
#     `run_model_stage` must not start the runner at all in such a directory:
#     the stub `claude` below records every invocation, and a refused stage
#     must leave no record of one. It must also leave the reason where a
#     reader looks (`<stage>.out.stderr`), leave `stage_kill_reason` empty (a
#     cap kill is read by the stage-budget controller and the rework ledger,
#     and this is neither), and give `handle_stage_failure` a detail that
#     says what happened, whatever was wrong with the file, and that no later
#     failure of the same stage inherits.
#
#   the user-level file (section 5)
#     `stage_user_settings_refusal` vets `$CLAUDE_CONFIG_DIR/settings.json`
#     the same way, with the same allowlist plus `effortLevel`, the one key
#     the image's own seed holds that no project settings file would. It has
#     no commit to compare against, so `run_model_stage` wires it in as a
#     second, independent check, and `handle_stage_failure` must tell its
#     refusal apart from a project-settings one rather than blaming the
#     checkout for what the configuration volume did.
#
# `claude` is a stub on PATH; nothing here reaches a model.
#
# Run directly: ./test/stage-project-settings.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
# A scratch checkout that is not a repository must not find one above it.
export GIT_CEILING_DIRECTORIES="$tmp_dir"

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

# The logic on its own terms, with no stage boundary: in the node image a
# read would otherwise be the stage user's, which cannot enter this test's own
# directory (test/stage-boundary.test.sh reads across the boundary).
export STAGE_BOUNDARY_GROUP="agent-ops-no-such-group"
# Isolates every test in sections 1-4 from stage_user_settings_refusal
# (section 5): a path that is never created, so the user-level file is always
# "absent" until a test below points CLAUDE_CONFIG_DIR somewhere real.
export CLAUDE_CONFIG_DIR="$tmp_dir/no-such-claude-config"
# shellcheck source=lib/stage-run.sh
. "$SCRIPT_DIR/lib/stage-run.sh"
# shellcheck source=lib/stage-attempt.sh
. "$SCRIPT_DIR/lib/stage-attempt.sh"

# The signal handlers' globals, which run_model_stage advertises into.
# shellcheck disable=SC2034
stage_pid=""
# shellcheck disable=SC2034
stage_name=""

# The managed policy as the image installs it, and a path where none exists.
policy="$tmp_dir/managed-settings.json"
cp "$SCRIPT_DIR/deploy/docker/claude-managed-settings.json" "$policy"
no_policy="$tmp_dir/no-such-managed-settings.json"

# checkout NAME FILE JSON — a scratch checkout with one settings file in it.
checkout() {
  local dir="$tmp_dir/$1"
  mkdir -p "$dir/.claude"
  [[ -n "$2" ]] && printf '%s\n' "$3" >"$dir/.claude/$2"
  printf '%s' "$dir"
}

# refusal DIR POLICY [SUBSTRATE] — the guard's status and output, as
# "<rc>|<output>", without the clause on where the file came from, which
# section 3 tests. SUBSTRATE defaults to claude-code, same as the function
# under test.
refusal() {
  local out rc
  out="$(STAGE_CLAUDE_MANAGED_SETTINGS="$2" stage_project_settings_refusal "$1" "${3:-claude-code}")"
  rc=$?
  printf '%s|%s' "$rc" "${out%%; the file is *}"
}
# What follows the keys in every refusal that names them.
loads=", which no stage loads from the checkout it runs in"

# commit_all DIR — make DIR a repository whose one commit holds all of it.
commit_all() {
  git -C "$1" init -q
  git -C "$1" add -A
  git -C "$1" -c user.name=test -c user.email=test@example.invalid commit -q -m test
}

# --- 1. The allowlist ------------------------------------------------------------
assert_eq "with no managed policy, only the inert keys are allowed" \
  "$STAGE_PROJECT_SETTINGS_INERT_KEYS" \
  "$(STAGE_CLAUDE_MANAGED_SETTINGS="$no_policy" stage_project_settings_allowed_keys)"
assert_eq "the shipped policy adds the hook and MCP-approval keys it makes inert" \
  '["hooks","enableAllProjectMcpServers","enabledMcpjsonServers","disabledMcpjsonServers"]' \
  "$(STAGE_CLAUDE_MANAGED_SETTINGS="$policy" stage_project_settings_allowed_keys \
     | jq -c --argjson inert "$STAGE_PROJECT_SETTINGS_INERT_KEYS" '. - $inert')"
printf '%s\n' '{"allowManagedHooksOnly": false, "allowedMcpServers": [{"serverName": "x"}]}' \
  >"$tmp_dir/weak-policy.json"
assert_eq "a policy that does not pin a control does not unlock its keys" \
  "$STAGE_PROJECT_SETTINGS_INERT_KEYS" \
  "$(STAGE_CLAUDE_MANAGED_SETTINGS="$tmp_dir/weak-policy.json" stage_project_settings_allowed_keys)"

# --- 2. What is refused, and what is not ------------------------------------------
assert_eq "a directory with no project settings is not refused" \
  "1|" "$(refusal "$(checkout none "" "")" "$no_policy")"
# shellcheck disable=SC2016  # "$schema" is a JSON key, not a variable
assert_eq "inert keys are not refused" \
  "1|" "$(refusal "$(checkout inert settings.json \
    '{"$schema":"x","permissions":{"allow":["Bash(npm test)"]},"includeCoAuthoredBy":true}')" "$no_policy")"

hooks_dir="$(checkout hooks settings.json \
  '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"true"}]}]}}')"
assert_eq "hooks are refused when no managed policy makes them inert" \
  "0|.claude/settings.json sets hooks$loads" "$(refusal "$hooks_dir" "$no_policy")"
assert_eq "and allowed under the shipped policy" \
  "1|" "$(refusal "$hooks_dir" "$policy")"

for key in env apiKeyHelper awsAuthRefresh awsCredentialExport gcpAuthRefresh \
           otelHeadersHelper proxyAuthHelper processWrapper enabledPlugins \
           extraKnownMarketplaces statusLine; do
  assert_eq "$key is refused even under the shipped policy" \
    "0|.claude/settings.json sets $key$loads" \
    "$(refusal "$(checkout "key-$key" settings.json "{\"$key\":\"x\"}")" "$policy")"
done

# `permissions` sets what the stage may do: `deny` takes a tool away, and
# `disableBypassPermissionsMode` drops the run out of bypass mode. Only
# `allow`, which a stage's untrusted workspace ignores, passes.
for sub in deny ask defaultMode disableBypassPermissionsMode additionalDirectories; do
  assert_eq "permissions.$sub is refused even under the shipped policy" \
    "0|.claude/settings.json sets permissions.$sub$loads" \
    "$(refusal "$(checkout "permissions-$sub" settings.json \
         "{\"permissions\":{\"allow\":[],\"$sub\":\"x\"}}")" "$policy")"
done
assert_eq "and so is a permissions value that is not an object" \
  "0|.claude/settings.json sets permissions$loads" \
  "$(refusal "$(checkout permissions-string settings.json '{"permissions":"x"}')" "$policy")"

assert_eq "the refusal names every key outside the allowlist, in file order" \
  "0|.claude/settings.json sets env, apiKeyHelper$loads" \
  "$(refusal "$(checkout two settings.json \
    '{"permissions":{},"env":{"BASH_ENV":"x"},"apiKeyHelper":"x"}')" "$policy")"
assert_eq "settings.local.json is vetted as settings.json is" \
  "0|.claude/settings.local.json sets enabledPlugins$loads" \
  "$(refusal "$(checkout local settings.local.json '{"enabledPlugins":{"p@m":true}}')" "$policy")"
assert_eq "a file jq cannot parse is refused, not guessed at" \
  "0|.claude/settings.json cannot be read as a JSON object, so it cannot be vetted" \
  "$(refusal "$(checkout broken settings.json '{"env": {')" "$policy")"
assert_eq "so is valid JSON that is not an object" \
  "0|.claude/settings.json cannot be read as a JSON object, so it cannot be vetted" \
  "$(refusal "$(checkout array settings.json '["env"]')" "$policy")"

link_dir="$(checkout link "" "")"
printf '%s\n' '{"env":{"BASH_ENV":"x"}}' >"$tmp_dir/elsewhere.json"
ln -s "$tmp_dir/elsewhere.json" "$link_dir/.claude/settings.json"
assert_eq "a settings file that is a symlink is vetted by what it points at" \
  "0|.claude/settings.json sets env$loads" "$(refusal "$link_dir" "$policy")"

# --- 3. Where the file came from ------------------------------------------------
origin_dir="$(checkout origin settings.json '{"env":{"A":"1"}}')"
commit_all "$origin_dir"
head="$(git -C "$origin_dir" rev-parse --short HEAD)"
assert_eq "a refused file the commit carries is said to be committed" \
  ".claude/settings.json sets env$loads; the file is as committed at $head" \
  "$(STAGE_CLAUDE_MANAGED_SETTINGS="$policy" stage_project_settings_refusal "$origin_dir")"
printf '%s\n' '{"env":{"A":"2"}}' >"$origin_dir/.claude/settings.json"
assert_eq "one changed since the commit is said not to be" \
  "the file is in the working tree but not as committed at $head" \
  "$(stage_project_settings_origin "$origin_dir" .claude/settings.json)"
printf '%s\n' '{"env":{"A":"1"}}' >"$origin_dir/.claude/settings.local.json"
assert_eq "and so is one the commit does not hold at all" \
  "the file is in the working tree but not as committed at $head" \
  "$(stage_project_settings_origin "$origin_dir" .claude/settings.local.json)"
assert_eq "a checkout that is not a repository has no commit to compare with" \
  "the file is in the working tree, and there is no commit to compare it with" \
  "$(stage_project_settings_origin "$link_dir" .claude/settings.json)"
assert_eq "an unreadable file says where it came from too" \
  ".claude/settings.json cannot be read as a JSON object, so it cannot be vetted; the file is in the working tree, and there is no commit to compare it with" \
  "$(STAGE_CLAUDE_MANAGED_SETTINGS="$policy" stage_project_settings_refusal "$tmp_dir/broken")"

# --- 4. The launcher -------------------------------------------------------------
mkdir -p "$tmp_dir/bin"
cat >"$tmp_dir/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf 'invoked\n' >> "$STUB_CAPTURE/invocations"
cat > /dev/null
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"result":"done"}'
STUB
chmod +x "$tmp_dir/bin/claude"
export PATH="$tmp_dir/bin:$PATH"

refused_dir="$(checkout launch-refused settings.json '{"env":{"BASH_ENV":"./x.sh"}}')"
commit_all "$refused_dir"
export STUB_CAPTURE="$refused_dir"
STAGE_CLAUDE_MANAGED_SETTINGS="$policy" \
  run_model_stage reviewer 60 test-model "a prompt" "$refused_dir/reviewer.out" "$refused_dir"
rc=$?
assert_eq "a refused stage returns non-zero" "1" "$rc"
assert_eq "and never starts the runner" \
  "no" "$([[ -e "$refused_dir/invocations" ]] && echo yes || echo no)"
assert_eq "it says why on the stage's stderr" \
  "run_model_stage: the reviewer stage was not launched: .claude/settings.json sets env$loads; the file is as committed at $(git -C "$refused_dir" rev-parse --short HEAD) (requirement 4k)" \
  "$(cat "$refused_dir/reviewer.out.stderr" 2>/dev/null)"
assert_eq "without claiming a cap killed it" "" "$stage_kill_reason"
assert_eq "its .out is empty, as a stage that never ran leaves it" \
  "0" "$(wc -c < "$refused_dir/reviewer.out")"
assert_eq "and so is its stream" \
  "0" "$(wc -c < "$refused_dir/reviewer.stream.jsonl")"

# handle_stage_failure's collaborators, stubbed to capture the detail.
log_attempt_failed() { captured_detail="$2"; }
detect_and_log_limit_hit() { return 1; }
release_claim() { :; }
captured_detail=""
handle_stage_failure reviewer "$rc" "$refused_dir/reviewer.out"
assert_eq "handle_stage_failure records a stage refused for a committed file as such" \
  "reviewer was not launched: the commit its checkout holds carries Claude Code project settings no stage may load" \
  "$captured_detail"

# A file only the working tree holds, as one an earlier stage left in the
# clone would be, and unreadable, so that the detail cannot lean on keys.
leftover_dir="$(checkout launch-leftover settings.json '{"permissions":{"allow":["Bash(npm test)"]}}')"
commit_all "$leftover_dir"
printf '%s\n' '{"env": {' >"$leftover_dir/.claude/settings.local.json"
export STUB_CAPTURE="$leftover_dir"
STAGE_CLAUDE_MANAGED_SETTINGS="$policy" \
  run_model_stage reviewer 60 test-model "a prompt" "$leftover_dir/reviewer.out" "$leftover_dir"
rc=$?
assert_eq "a file only the working tree holds refuses the stage too" "1" "$rc"
captured_detail=""
handle_stage_failure reviewer "$rc" "$leftover_dir/reviewer.out"
assert_eq "and is recorded as not in the commit" \
  "reviewer was not launched: its checkout's working tree holds Claude Code project settings, not in the commit, that no stage may load" \
  "$captured_detail"

rm "$leftover_dir/.claude/settings.local.json"
STAGE_CLAUDE_MANAGED_SETTINGS="$policy" \
  run_model_stage reviewer 60 test-model "a prompt" "$leftover_dir/reviewer.out" "$leftover_dir"
rc=$?
assert_eq "once the file is gone the same stage launches" "0" "$rc"
captured_detail=""
handle_stage_failure reviewer 1 "$leftover_dir/reviewer.out"
assert_eq "and a later failure of it is not recorded as the earlier refusal" \
  "reviewer exited 1" "$captured_detail"

allowed_dir="$(checkout launch-allowed settings.json \
  '{"permissions":{},"hooks":{"SessionStart":[]}}')"
export STUB_CAPTURE="$allowed_dir"
STAGE_CLAUDE_MANAGED_SETTINGS="$policy" \
  run_model_stage reviewer 60 test-model "a prompt" "$allowed_dir/reviewer.out" "$allowed_dir"
rc=$?
assert_eq "an allowed directory launches the runner as before" "0" "$rc"
assert_eq "exactly once" "1" "$(wc -l < "$allowed_dir/invocations" 2>/dev/null || echo 0)"

# --- 5. The user-level Claude configuration file (requirement 4k/45e, issue
#        #2251) ------------------------------------------------------------
user_loads=", which no stage loads from the Claude configuration volume"

assert_eq "with no managed policy, the user-level allowlist adds just effortLevel" \
  "$(jq -c '. + ["effortLevel"]' <<<"$STAGE_PROJECT_SETTINGS_INERT_KEYS")" \
  "$(STAGE_CLAUDE_MANAGED_SETTINGS="$no_policy" stage_project_settings_allowed_keys \
     | jq -c --argjson extra "$STAGE_USER_SETTINGS_EXTRA_ALLOWED_KEYS" '. + $extra')"

user_config="$tmp_dir/claude-config"
mkdir -p "$user_config"
export CLAUDE_CONFIG_DIR="$user_config"

assert_eq "an absent user-level file is not refused" "1" "$(stage_user_settings_refusal; echo $?)"

printf '%s\n' '{"effortLevel":"max","includeCoAuthoredBy":true}' >"$user_config/settings.json"
assert_eq "the seed's own keys are not refused" "1" "$(stage_user_settings_refusal; echo $?)"

for key in env apiKeyHelper awsAuthRefresh gcpAuthRefresh; do
  printf '{"%s":"x"}' "$key" >"$user_config/settings.json"
  assert_eq "user-level $key is refused" \
    "0|$user_config/settings.json sets $key$user_loads" \
    "$(out="$(stage_user_settings_refusal)"; printf '%s|%s' "$?" "$out")"
done

printf '%s\n' '{"env": {' >"$user_config/settings.json"
assert_eq "a user-level file jq cannot parse is refused, not guessed at" \
  "0|$user_config/settings.json cannot be read as a JSON object, so it cannot be vetted" \
  "$(out="$(stage_user_settings_refusal)"; printf '%s|%s' "$?" "$out")"

rm -f "$user_config/settings.json"

# The launcher: a planted apiKeyHelper refuses the launch exactly as a
# project-level one does, and handle_stage_failure does not mistake it for a
# checkout's own project settings, which it is not.
printf '{"apiKeyHelper":"x"}' >"$user_config/settings.json"
user_refused_dir="$(checkout user-refused "" "")"
export STUB_CAPTURE="$user_refused_dir"
STAGE_CLAUDE_MANAGED_SETTINGS="$policy" \
  run_model_stage reviewer 60 test-model "a prompt" "$user_refused_dir/reviewer.out" "$user_refused_dir"
rc=$?
assert_eq "a planted user-level apiKeyHelper refuses the launch" "1" "$rc"
assert_eq "and never starts the runner" \
  "no" "$([[ -e "$user_refused_dir/invocations" ]] && echo yes || echo no)"
assert_eq "it says why on the stage's stderr, naming the user-level file" \
  "run_model_stage: the reviewer stage was not launched: $user_config/settings.json sets apiKeyHelper$user_loads (requirement 4k)" \
  "$(cat "$user_refused_dir/reviewer.out.stderr" 2>/dev/null)"

captured_detail=""
handle_stage_failure reviewer "$rc" "$user_refused_dir/reviewer.out"
assert_eq "handle_stage_failure attributes it to the configuration volume, not the checkout" \
  "reviewer was not launched: the Claude configuration volume's settings.json carries a key no stage may load" \
  "$captured_detail"

rm -f "$user_config/settings.json"
export CLAUDE_CONFIG_DIR="$tmp_dir/no-such-claude-config"

# --- 6. Grok Build's own counterpart (issue #2134) -------------------------------
# The same guard, dispatched by substrate: `.claude/settings.json`'s own
# checks above already run for `grok-build` too (no second stub of them
# needed — the dispatch is the one thing under test here), plus two files
# only a Grok stage's own launch vets.

# grok_checkout NAME REL_PATH CONTENT — a scratch checkout with one file at
# an arbitrary relative path, for .grok/lsp.json and .grok/config.toml,
# neither of which `checkout` above (fixed to .claude/<name>) can place.
grok_checkout() {
  local dir="$tmp_dir/$1" rel="$2"
  mkdir -p "$dir/$(dirname "$rel")"
  printf '%s\n' "$3" >"$dir/$rel"
  printf '%s' "$dir"
}

assert_eq "a directory with no Grok files is not refused for grok-build" \
  "1|" "$(refusal "$(checkout grok-none "" "")" "$no_policy" grok-build)"

# .claude/settings.json's own checks are not substrate-specific: Grok reads
# the same file's hooks under its own Claude-compatibility layer when
# GROK_FOLDER_TRUST=0 trusts a checkout, so the one guard protects a
# grok-build stage against its `env` key too, with no dispatch of its own.
assert_eq "a grok-build stage is refused on .claude/settings.json's env too" \
  "0|.claude/settings.json sets env$loads" \
  "$(refusal "$(checkout grok-env settings.json '{"env":{"BASH_ENV":"x"}}')" "$policy" grok-build)"

lsp_dir="$(grok_checkout grok-lsp .grok/lsp.json '{}')"
assert_eq ".grok/lsp.json is refused outright" \
  "0|.grok/lsp.json is present, and no stage runs a project LSP server from the checkout it runs in" \
  "$(refusal "$lsp_dir" "$policy" grok-build)"
assert_eq "…but not for claude-code, which never reads it" \
  "1|" "$(refusal "$lsp_dir" "$policy" claude-code)"

allowed_toml_dir="$(grok_checkout grok-toml-allowed .grok/config.toml \
  $'[permission]\nfoo = true\n[mcp]\nbar = 1\n[mcp_servers]\n')"
assert_eq ".grok/config.toml with only permission/mcp/mcp_servers sections is not refused" \
  "1|" "$(refusal "$allowed_toml_dir" "$policy" grok-build)"

plugins_toml_dir="$(grok_checkout grok-toml-plugins .grok/config.toml \
  $'[permission]\nfoo = true\n[plugins]\nbaz = true\n')"
assert_eq ".grok/config.toml naming a section outside the allowlist is refused" \
  "0|.grok/config.toml sets section(s) plugins, which no stage loads from the checkout it runs in" \
  "$(refusal "$plugins_toml_dir" "$policy" grok-build)"
assert_eq "…but not for claude-code, which never reads it" \
  "1|" "$(refusal "$plugins_toml_dir" "$policy" claude-code)"

# TOML lets the same section be written several ways, and each of them
# declares it as surely as `[hooks]` does. A header the guard cannot read as
# a bare name is refused as itself rather than passed over, because a header
# it does not name is one it cannot clear.
for header in '[[plugins]]' '[ plugins ]' '["plugins"]'; do
  shape_dir="$(grok_checkout "grok-toml-shape-$RANDOM" .grok/config.toml \
    "$header"$'\nbaz = true\n')"
  assert_eq ".grok/config.toml's $header is refused, not read past" \
    "0|.grok/config.toml sets section(s) $header, which no stage loads from the checkout it runs in" \
    "$(refusal "$shape_dir" "$policy" grok-build)"
done

# …and a `[` that opens an array value rather than a section is not a
# header, so an allowed section holding a multi-line list still passes.
array_toml_dir="$(grok_checkout grok-toml-array .grok/config.toml \
  $'[permission]\nallow = [\n  "Bash",\n]\n')"
assert_eq ".grok/config.toml with a multi-line array in an allowed section passes" \
  "1|" "$(refusal "$array_toml_dir" "$policy" grok-build)"

# The file is read the way the `.claude` files are — as the stage user,
# bounded in time and size — because the directory is often a workspace an
# earlier stage has had (lib/stage-boundary.sh's second rule). One that
# cannot be read that way is refused, never skipped: a dangling link here
# stands in for the FIFO and the link-to-the-Script's-own-file that the real
# boundary exists for.
unreadable_dir="$tmp_dir/grok-toml-unreadable"
mkdir -p "$unreadable_dir/.grok"
ln -s /no/such/grok/config.toml "$unreadable_dir/.grok/config.toml"
assert_eq ".grok/config.toml that cannot be read is refused, not passed over" \
  "0|.grok/config.toml cannot be read as a file of at most $STAGE_PROJECT_SETTINGS_MAX_BYTES bytes, so it cannot be vetted" \
  "$(refusal "$unreadable_dir" "$policy" grok-build)"

# The launcher, dispatched to grok-build by MODEL_PROVIDER/PROVIDER_SUBSTRATE
# (as `resolve_model_id_into`/`providers_load` populate them, requirement
# 1a) rather than a real `grok` binary — a refused stage never reaches
# `substrate_grok_build_exec` at all, so none is needed.
# shellcheck disable=SC2034  # read by stage_model_substrate
MODEL_PROVIDER[test-grok-model]=xai
# shellcheck disable=SC2034
PROVIDER_SUBSTRATE[xai]=grok-build

grok_refused_dir="$(grok_checkout grok-launch-refused .grok/lsp.json '{}')"
commit_all "$grok_refused_dir"
export STUB_CAPTURE="$grok_refused_dir"
STAGE_CLAUDE_MANAGED_SETTINGS="$policy" \
  run_model_stage reviewer 60 test-grok-model "a prompt" "$grok_refused_dir/reviewer.out" "$grok_refused_dir"
rc=$?
assert_eq "a Grok stage refused on .grok/lsp.json returns non-zero" "1" "$rc"
assert_eq "and never starts a runner" \
  "no" "$([[ -e "$grok_refused_dir/invocations" ]] && echo yes || echo no)"
assert_eq "it says why on the stage's stderr, exactly as a refused Claude stage does" \
  "run_model_stage: the reviewer stage was not launched: .grok/lsp.json is present, and no stage runs a project LSP server from the checkout it runs in; the file is as committed at $(git -C "$grok_refused_dir" rev-parse --short HEAD) (requirement 4k)" \
  "$(cat "$grok_refused_dir/reviewer.out.stderr" 2>/dev/null)"

printf '\n'
if (( failures )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
