#!/usr/bin/env bash
#
# test/forge-token-broker.test.sh — regression test for
# lib/forge-token-broker.sh and its entry point deploy/docker/forge-token.sh:
# the authoring token a stage may have, and nothing else (requirement 45e).
#
# What must hold, always:
#
#   - The App's identity comes from the environ file the entry point names
#     (pid 1's, in the image), never from the caller's own environment: a
#     key path or App id the caller exported is cleared before anything is
#     read.
#   - Only the variables the broker names are read from that file, so the
#     Approver App's identity, sitting beside the authoring App's in the same
#     environment, can never be minted from.
#   - With the authoring App configured, a failed mint gives nothing — never
#     `PW_GH_DEGRADE_TOKEN`, the personal-token fallback the Script keeps.
#   - With no App configured, the installation's own GH_TOKEN (or the degrade
#     token holding it) is what a stage authors with.
#   - A malformed owner is refused before any lookup.
#
# `curl` is stubbed through AUTHOR_TOKEN_CURL (test/author-token.test.sh's
# shape); real `openssl` signs a throwaway key. The test seam is set in this
# process's own environment, which the broker does not clear: in the image
# sudo resets the environment, so no caller can reach it there.
#
#   ./test/forge-token-broker.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/forge-token-broker.sh
. "$SCRIPT_DIR/lib/forge-token-broker.sh"

tmp_dir="$(mktemp -d)"
cache_dir="$(mktemp -d /dev/shm/forge-token-broker-test.XXXXXX)"
trap 'rm -rf "$tmp_dir" "$cache_dir"' EXIT

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

key_path="$tmp_dir/author-key.pem"
openssl genrsa -out "$key_path" 2048 >/dev/null 2>&1
chmod 600 "$key_path"
approver_key="$tmp_dir/approver-key.pem"
openssl genrsa -out "$approver_key" 2048 >/dev/null 2>&1
chmod 600 "$approver_key"

cat >"$tmp_dir/curl" <<STUB
#!/usr/bin/env bash
d="$tmp_dir"
printf '%s\n' "\$@" >> "\$d/curl_argv"
cat >/dev/null
[[ -f "\$d/curl_fail" ]] && exit 1
printf '%s\n%s' '{"token":"ghs_brokered","expires_at":"2099-01-01T00:00:00Z"}' 201
STUB
chmod +x "$tmp_dir/curl"
export AUTHOR_TOKEN_CURL="$tmp_dir/curl" AUTHOR_TOKEN_CACHE_DIR="$cache_dir"

# write_environ FILE NAME=value... — a NUL-separated environ file.
write_environ() {
  local file="$1"
  shift
  : >"$file"
  local record
  for record in "$@"; do
    printf '%s\0' "$record" >>"$file"
  done
}

environ="$tmp_dir/environ"
app_records=(
  "PULLWRIGHT_AUTHOR_APP_ID=7710033"
  "PULLWRIGHT_AUTHOR_INSTALLATION_ID=882110044"
  'PULLWRIGHT_AUTHOR_INSTALLATION_IDS={"Acme":882110055}'
  "PULLWRIGHT_AUTHOR_PRIVATE_KEY_PATH=$key_path"
  "PULLWRIGHT_APPROVER_APP_ID=999"
  "PULLWRIGHT_APPROVER_INSTALLATION_ID=998"
  "PULLWRIGHT_APPROVER_PRIVATE_KEY_PATH=$approver_key"
  "PW_GH_DEGRADE_TOKEN=ghp_personal"
  "GH_TOKEN="
  "BASH_ENV=$tmp_dir/never-sourced"
)

# --- The App configured: a token for the owner's installation, and its tag --
write_environ "$environ" "${app_records[@]}"
rm -f "$cache_dir"/* "$tmp_dir/curl_argv" "$tmp_dir/curl_fail"
out="$(forge_token_broker_main "$environ" Acme 2>/dev/null)"; rc=$?
assert_eq "App configured: exit 0" "0" "$rc"
assert_eq "  ... the minted token on the first line" "ghs_brokered" "$(sed -n 1p <<<"$out")"
assert_eq "  ... the mapped owner's installation in the tag" "app-7710033-882110055" "$(sed -n 2p <<<"$out")"
assert_eq "  ... minted against that installation" "1" \
  "$(grep -c 'app/installations/882110055/access_tokens' "$tmp_dir/curl_argv")"

out="$(forge_token_broker_main "$environ" "" 2>/dev/null)"; rc=$?
assert_eq "no owner: exit 0" "0" "$rc"
assert_eq "  ... the default installation in the tag" "app-7710033-882110044" "$(sed -n 2p <<<"$out")"

out="$(forge_token_broker_main "$environ" Unmapped 2>/dev/null)"; rc=$?
assert_eq "an owner the map does not name: the default installation" "app-7710033-882110044" "$(sed -n 2p <<<"$out")"

# --- A failed mint gives nothing, never the degrade token -------------------
rm -f "$cache_dir"/*
touch "$tmp_dir/curl_fail"
out="$(forge_token_broker_main "$environ" Acme 2>/dev/null)"; rc=$?
assert_eq "mint failure: exit 1" "1" "$rc"
assert_eq "  ... no output at all, so no personal token" "" "$out"
rm -f "$tmp_dir/curl_fail"

# --- Only the named variables are read; the caller's own are cleared --------
assert_eq "the Approver's key path is not among the variables read" "" \
  "$(printf '%s\n' "${FORGE_TOKEN_BROKER_ENV[@]}" | grep -i approver || true)"
write_environ "$environ" "PW_GH_DEGRADE_TOKEN=ghp_personal" "GH_TOKEN=ghp_personal"
export PULLWRIGHT_AUTHOR_APP_ID=999 PULLWRIGHT_AUTHOR_INSTALLATION_ID=998 \
  PULLWRIGHT_AUTHOR_PRIVATE_KEY_PATH="$approver_key"
rm -f "$cache_dir"/* "$tmp_dir/curl_argv"
out="$(forge_token_broker_main "$environ" "" 2>/dev/null)"; rc=$?
assert_eq "an App identity in the caller's environment is ignored: no mint" "no" \
  "$([[ -s "$tmp_dir/curl_argv" ]] && echo yes || echo no)"
assert_eq "  ... and the file's own credential is what is given" "ghp_personal" "$(sed -n 1p <<<"$out")"
unset PULLWRIGHT_AUTHOR_APP_ID PULLWRIGHT_AUTHOR_INSTALLATION_ID PULLWRIGHT_AUTHOR_PRIVATE_KEY_PATH

# --- No App configured: the installation's own token, untagged -------------
write_environ "$environ" "GH_TOKEN=ghp_only_credential"
out="$(forge_token_broker_main "$environ" Acme 2>/dev/null)"; rc=$?
assert_eq "no App: exit 0" "0" "$rc"
assert_eq "  ... GH_TOKEN on the first line" "ghp_only_credential" "$(sed -n 1p <<<"$out")"
assert_eq "  ... an empty tag" "" "$(sed -n 2p <<<"$out")"

write_environ "$environ" "GH_TOKEN="
out="$(forge_token_broker_main "$environ" Acme 2>/dev/null)"; rc=$?
assert_eq "no credential at all: exit 1" "1" "$rc"
assert_eq "  ... and no output" "" "$out"

# --- Refusals ---------------------------------------------------------------
out="$(forge_token_broker_main "$environ" 'Acme/../x' 2>/dev/null)"; rc=$?
assert_eq "a malformed owner: exit 2" "2" "$rc"
out="$(forge_token_broker_main "$environ" '-x' 2>/dev/null)"; rc=$?
assert_eq "an owner shaped like an option: exit 2" "2" "$rc"
# Every owner the gh shim can ask for is one the broker accepts: a managed
# user's `name_shortcode`, a dotted name, and one longer than 39 characters.
for owner in name_shortcode a.b "$(printf 'x%.0s' {1..45})"; do
  assert_eq "an owner the shim accepts is accepted: $owner" "0" \
    "$(forge_token_broker_owner_valid "$owner"; echo $?)"
done
out="$(forge_token_broker_main "$tmp_dir/no-such-environ" Acme 2>/dev/null)"; rc=$?
assert_eq "an unreadable environ file: exit 1" "1" "$rc"

out="$(bash "$SCRIPT_DIR/deploy/docker/forge-token.sh" Acme extra 2>/dev/null)"; rc=$?
assert_eq "the entry point refuses a second argument" "2" "$rc"
# shellcheck disable=SC2016  # the pattern is the entry point's own literal text
assert_eq "the entry point reads pid 1's environment and nothing else" "1" \
  "$(grep -c '^forge_token_broker_main /proc/1/environ "\${1:-}"$' "$SCRIPT_DIR/deploy/docker/forge-token.sh")"

printf '\n'
if (( failures == 0 )); then
  printf 'all assertions passed\n'
  exit 0
fi
printf '%d assertion(s) failed\n' "$failures"
exit 1
