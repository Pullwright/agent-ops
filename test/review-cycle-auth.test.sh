#!/usr/bin/env bash
#
# test/review-cycle-auth.test.sh — review-cycle.sh's own entry point against
# the forge authoring App's on-demand credential seam (agent-ops#1022,
# TD-PPagop-26082834).
#
# agent-ops#1021 (PR #1313) replaced the once-per-cycle "resolve and export
# GH_TOKEN" shape this item originally asked review-cycle.sh to adopt with a
# fleet-wide on-demand seam: `lib/gh-shim.sh`'s `gh` transport shim on `PATH`,
# reached both directly and through git's own credential helper
# (`deploy/docker/entrypoint.sh`). review-cycle.sh needs no source change to
# reach it — it never reads or sets `GH_TOKEN` itself, so every `gh` call it
# makes resolves through whatever the shim decides. What this file pins,
# that no other test does, is that review-cycle.sh's own entry point —
# its `gh api "repos/$slug"` (default-branch resolution) and `gh pr list`
# (the idempotency skip-guard, R4) call sites — actually reach the shim and
# present a freshly-minted App token when one is configured, and the
# ambient GH_TOKEN unchanged when it is not. `test/gh-shim-auth.test.sh`
# already covers the shim's own minting/caching contract in full; this file
# never re-asserts that, only that review-cycle.sh's own calls flow through
# it rather than around it.
#
# The stub "real gh" this file installs answers every call generically
# (never fails, never blocks a skip-guard, an init-time label/role/toggle
# check some other lib may make along the way) and logs the GH_TOKEN each
# call it can identify — the default-branch fetch and the pr-list check —
# actually saw. Chosen by matching each call's own argv text rather than by
# call order, since review-cycle.sh's own two call sites are not the only
# `gh` invocations a real run might make before reaching them, and an
# order-based stub would silently mis-attribute one of those to a slot the
# test never intended, as `test/gh-shim.test.sh`'s own numbered-plan stub
# would.
#
# The repository under review always has an open pull request already
# carrying `pr_label` (the stub's `pr list` answer), which is what stops the
# run at the R4 skip-guard rather than reaching the clone or the Reviewer-
# Agent — no need to stub either. Both `gh` calls that reach the App happen
# before that skip.
#
# No test framework is used (none exists elsewhere in this repo). Run it
# directly:
#
#   ./test/review-cycle-auth.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REVIEW="$SCRIPT_DIR/review-cycle.sh"

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

tmp_dir="$(mktemp -d)"
cache_dir="$(mktemp -d /dev/shm/review-cycle-auth-test.XXXXXX)"
trap 'rm -rf "$tmp_dir" "$cache_dir"' EXIT

slug="test/one-repo"

# --- A throwaway App key for this run ---------------------------------------
key_path="$tmp_dir/app-key.pem"
openssl genrsa -out "$key_path" 2048 >/dev/null 2>&1
chmod 600 "$key_path"

# --- The stub curl behind the mint (test/gh-shim-auth.test.sh's own shape) --
stub_curl_bin="$tmp_dir/curl"
cat > "$stub_curl_bin" <<STUB
#!/usr/bin/env bash
cat >/dev/null 2>&1
printf '{"token":"ghs_forge_review_token","expires_at":"2099-01-01T00:00:00Z"}\n201'
STUB
chmod +x "$stub_curl_bin"

# --- The stub "real gh": never fails, matched by argv text, logs GH_TOKEN --
real_gh_dir="$tmp_dir/realgh"
mkdir -p "$real_gh_dir"
cat > "$real_gh_dir/gh" <<STUB
#!/usr/bin/env bash
set -uo pipefail
d="\${STUB_LOG_DIR:?}"
{ printf '%s\x1f' "\$@"; printf '\n'; } >> "\$d/calls.log"
has_include=0
for a in "\$@"; do [[ "\$a" == "-i" || "\$a" == "--include" ]] && has_include=1; done
argv="\$*"
body='{}'
log="\$d/other-tokens.log"
case "\$argv" in
  *"repos/$slug "*)
    body="main"
    log="\$d/default-branch-tokens.log"
    ;;
  *"pr list "*"$slug"*)
    body="1"
    log="\$d/prlist-tokens.log"
    ;;
esac
printf '%s\n' "\${GH_TOKEN:-}" >> "\$log"
if [[ "\$has_include" == 1 ]]; then
  printf 'HTTP/2.0 200 OK\r\n\r\n%s' "\$body"
else
  printf '%s' "\$body"
fi
exit 0
STUB
chmod +x "$real_gh_dir/gh"

# --- PATH: the real shim installed as `gh`, ahead of everything else -------
# review-cycle.sh's own PATH bootstrap appends its fallback dirs rather than
# prepending them (its own comment: "an already-resolvable PATH entry ...
# must win over these fallbacks"), so this front entry is never shadowed.
path_bin="$tmp_dir/pathbin"
mkdir -p "$path_bin"
ln -s "$SCRIPT_DIR/scripts/gh-shim.sh" "$path_bin/gh"
printf '#!/usr/bin/env bash\nexit 1\n' > "$path_bin/claude"
chmod +x "$path_bin/claude"

# --- Config: one repo, always due for review, always skipped by an open PR -
config_file="$tmp_dir/config.json"
jq --arg slug "$slug" \
  'del(.repository_review.defaults.not_before)
   | .repository_review.repos = [{slug: $slug}]' \
  "$SCRIPT_DIR/config.json" > "$config_file"

state_remote="$tmp_dir/state-remote.git"
git init --quiet --bare --initial-branch=main "$state_remote"

run_review() {
  local home="$1"
  mkdir -p "$home/.local/state/poetic-agents" "$home/.cache/poetic-agents/workspaces"
  env HOME="$home" AGENT_OPS_ROLE=active NODE_NAME="$(basename "$home")" \
    PATH="$path_bin:$PATH" TOGGLE_GH=/bin/false CLONE_GIT=/bin/false \
    AGENT_OPS_CONFIG="$config_file" STATE_SYNC_REMOTE="$state_remote" \
    GIT_USER_NAME="Test Node" GIT_USER_EMAIL="test-node@example.invalid" \
    STUB_LOG_DIR="$log_dir" \
    "${@:2}" \
    "$REVIEW" >"$home/run.log" 2>&1
}

# === App configured, GH_TOKEN empty: review-cycle.sh's own calls mint =======

log_dir="$tmp_dir/logs-app"
mkdir -p "$log_dir"
state_dir_app="$tmp_dir/ghstate-app"
mkdir -p "$state_dir_app"
run_review "$tmp_dir/node-app" \
  GH_TOKEN= \
  PULLWRIGHT_AUTHOR_APP_ID=7710033 \
  PULLWRIGHT_AUTHOR_INSTALLATION_ID=882110044 \
  PULLWRIGHT_AUTHOR_PRIVATE_KEY_PATH="$key_path" \
  AUTHOR_TOKEN_CURL="$stub_curl_bin" \
  AUTHOR_TOKEN_CACHE_DIR="$cache_dir" \
  PW_GH_REAL_BIN="$real_gh_dir/gh" \
  PW_GH_STATE_DIR="$state_dir_app"

assert_eq "the default-branch call was made" "1" \
  "$(wc -l < "$log_dir/default-branch-tokens.log" 2>/dev/null || echo 0)"
assert_eq "…and presented a freshly-minted App token, not an empty one" \
  "ghs_forge_review_token" "$(tail -1 "$log_dir/default-branch-tokens.log" 2>/dev/null)"
assert_eq "the pr-list skip-guard call was made" "1" \
  "$(wc -l < "$log_dir/prlist-tokens.log" 2>/dev/null || echo 0)"
assert_eq "…and presented the same freshly-minted App token" \
  "ghs_forge_review_token" "$(tail -1 "$log_dir/prlist-tokens.log" 2>/dev/null)"
assert_eq "the open PR it reported actually stood the repo down (no clone attempted)" "0" \
  "$(find "$tmp_dir/node-app/.cache/poetic-agents/workspaces" -mindepth 1 -maxdepth 1 -name '[!.]*' 2>/dev/null | wc -l)"

# === No App configured: the ambient GH_TOKEN authenticates unchanged =======
# (the pre-#1021, pre-#1022 behaviour every PAT-only fleet still relies on)

log_dir="$tmp_dir/logs-pat"
mkdir -p "$log_dir"
state_dir_pat="$tmp_dir/ghstate-pat"
mkdir -p "$state_dir_pat"
run_review "$tmp_dir/node-pat" \
  GH_TOKEN=ghp_the_owner_pat \
  PW_GH_REAL_BIN="$real_gh_dir/gh" \
  PW_GH_STATE_DIR="$state_dir_pat"

assert_eq "no App configured: the default-branch call still authenticates" \
  "ghp_the_owner_pat" "$(tail -1 "$log_dir/default-branch-tokens.log" 2>/dev/null)"
assert_eq "…and so does the pr-list skip-guard call" \
  "ghp_the_owner_pat" "$(tail -1 "$log_dir/prlist-tokens.log" 2>/dev/null)"

printf '\n'
if (( failures > 0 )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
