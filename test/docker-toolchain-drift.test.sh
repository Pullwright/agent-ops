#!/usr/bin/env bash
#
# test/docker-toolchain-drift.test.sh — regression test for
# scripts/check-docker-toolchain-drift.sh (issue #2708).
#
# As with test/graphql-drift.test.sh, this stubs `gh` (and, here, `curl`)
# rather than asking the real GitHub releases API or the real npm registry —
# that would make the test itself exercise upstream drift rather than this
# repository's own logic. What is tested is everything this script actually
# owns: reading the four pins out of a Dockerfile, resolving each against the
# right kind of feed, comparing versions that may or may not carry a leading
# "v", building the issue body, and filing-or-commenting through
# lib/tech-debt-file.sh's own dedup rather than filing a duplicate on every
# run.
#
# Run directly:
#
#   ./test/docker-toolchain-drift.test.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$SCRIPT_DIR/scripts/check-docker-toolchain-drift.sh"

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
saw() { if grep -q -- "$1" <<<"$2"; then echo yes; else echo no; fi; }

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

dockerfile="$tmp_dir/Dockerfile"
cat > "$dockerfile" <<'EOF'
ARG SUPERCRONIC_VERSION=v0.2.47
ARG SHELLCHECK_VERSION=v0.10.0
ARG CLAUDE_CODE_VERSION=2.1.267
ARG GROK_BUILD_VERSION=1.0.46
EOF

cat > "$tmp_dir/gh" <<'STUB'
#!/usr/bin/env bash
tmp_dir="$(cd "$(dirname "$0")" && pwd)"
args=("$@")
printf '%s %s\n' "${GH_TOKEN:-<none>}" "${args[*]}" >> "$tmp_dir/calls"
if [[ "${args[0]:-}" == "api" ]]; then
  case "${args[1]:-}" in
    repos/aptible/supercronic/releases/latest)
      tag="$(cat "$tmp_dir/supercronic_tag" 2>/dev/null || true)"
      [[ -n "$tag" ]] || exit 1
      printf '%s\n' "$tag"; exit 0 ;;
    repos/koalaman/shellcheck/releases/latest)
      tag="$(cat "$tmp_dir/shellcheck_tag" 2>/dev/null || true)"
      [[ -n "$tag" ]] || exit 1
      printf '%s\n' "$tag"; exit 0 ;;
    *) exit 1 ;;
  esac
fi
if [[ "${args[0]:-}" == "issue" && "${args[1]:-}" == "list" ]]; then
  cat "$tmp_dir/issue_list_json" 2>/dev/null || printf '[]'
  exit 0
fi
if [[ "${args[0]:-}" == "issue" && "${args[1]:-}" == "comment" ]]; then
  printf '%s\n' "${args[2]:-}" >> "$tmp_dir/comment_numbers"
  for (( i = 0; i < ${#args[@]}; i++ )); do
    if [[ "${args[$i]}" == "--body-file" ]]; then
      cat "${args[$((i+1))]}" >> "$tmp_dir/comment_log"
    fi
  done
  exit 0
fi
if [[ "${args[0]:-}" == "issue" && "${args[1]:-}" == "create" ]]; then
  for (( i = 0; i < ${#args[@]}; i++ )); do
    [[ "${args[$i]}" == "--title" ]] && printf '%s\n' "${args[$((i+1))]}" >> "$tmp_dir/create_titles"
    [[ "${args[$i]}" == "--body-file" ]] && cat "${args[$((i+1))]}" >> "$tmp_dir/create_log"
  done
  printf 'https://github.com/Example/repo/issues/999\n'
  exit 0
fi
exit 1
STUB
chmod +x "$tmp_dir/gh"

cat > "$tmp_dir/curl" <<'STUB'
#!/usr/bin/env bash
tmp_dir="$(cd "$(dirname "$0")" && pwd)"
url="${*: -1}"
case "$url" in
  *claude-code*)
    v="$(cat "$tmp_dir/claude_version" 2>/dev/null || true)"
    [[ -n "$v" ]] || exit 1
    printf '{"version":"%s"}' "$v"; exit 0 ;;
  *grok*)
    v="$(cat "$tmp_dir/grok_version" 2>/dev/null || true)"
    [[ -n "$v" ]] || exit 1
    printf '{"version":"%s"}' "$v"; exit 0 ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$tmp_dir/curl"

# The workflow (.github/workflows/docker-toolchain-drift.yml) runs this
# script with GH_TOKEN set from secrets.GITHUB_TOKEN for the whole step — a
# GitHub Actions runner carries no stored `gh auth login` identity, so every
# run_check call below reproduces that rather than the tokenless, locally-
# authenticated case the stub would otherwise paper over.
ci_token="ci-gh-token-abc123"

run_check() {
  rm -f "$tmp_dir"/create_titles "$tmp_dir"/create_log "$tmp_dir"/comment_log "$tmp_dir"/comment_numbers "$tmp_dir"/calls
  PATH="$tmp_dir:$PATH" DOCKER_DRIFT_DOCKERFILE="$dockerfile" DOCKER_DRIFT_REPO="Example/repo" \
    GH_TOKEN="$ci_token" \
    "$CHECK" "$@"
}

# --- 1. no drift: every pin matches upstream, nothing filed ---------------
printf 'v0.2.47\n' > "$tmp_dir/supercronic_tag"
printf 'v0.10.0\n' > "$tmp_dir/shellcheck_tag"
printf '2.1.267\n' > "$tmp_dir/claude_version"
printf '1.0.46\n' > "$tmp_dir/grok_version"
printf '[]' > "$tmp_dir/issue_list_json"

out="$(run_check)"; rc=$?
assert_eq "no drift: exit 0" "0" "$rc"
assert_eq "no drift: nothing filed" "no" "$(saw "drift reported" "$out")"
assert_eq "no drift: no issue created" "no" "$([[ -f "$tmp_dir/create_log" ]] && echo yes || echo no)"

# --- 2. drift on one pin, no existing issue: files a new one --------------
printf 'v0.2.51\n' > "$tmp_dir/supercronic_tag"
out="$(run_check)"; rc=$?
assert_eq "drift+new: exit 0" "0" "$rc"
assert_eq "drift+new: a new issue was created" "yes" "$([[ -f "$tmp_dir/create_log" ]] && echo yes || echo no)"
assert_eq "drift+new: title is stable" "yes" "$(saw 'Docker toolchain pins have drifted from upstream' "$(cat "$tmp_dir/create_titles" 2>/dev/null)")"
body="$(cat "$tmp_dir/create_log" 2>/dev/null)"
assert_eq "drift+new: names the stale pin" "yes" "$(saw 'SUPERCRONIC_VERSION' "$body")"
assert_eq "drift+new: names the pinned version" "yes" "$(saw 'v0.2.47' "$body")"
assert_eq "drift+new: names the upstream version" "yes" "$(saw 'v0.2.51' "$body")"
assert_eq "drift+new: mentions the checksum recompute" "yes" "$(saw 'recomputed' "$body")"
assert_eq "drift+new: no comment on an existing issue" "no" "$([[ -f "$tmp_dir/comment_log" ]] && echo yes || echo no)"
calls="$(cat "$tmp_dir/calls" 2>/dev/null)"
assert_eq "drift+new: dedup issue list carried GH_TOKEN" "yes" "$(saw "^$ci_token issue list" "$calls")"
assert_eq "drift+new: issue create carried GH_TOKEN" "yes" "$(saw "^$ci_token issue create" "$calls")"
assert_eq "drift+new: no filing call ran tokenless" "0" "$(grep -c '^<none> issue' <<<"$calls")"

# --- 3. drift on one pin, an open issue already covers it: comments -------
printf '[{"number":42,"url":"https://github.com/Example/repo/issues/42","title":"Docker toolchain pins have drifted from upstream","body":"old"}]' \
  > "$tmp_dir/issue_list_json"
out="$(run_check)"; rc=$?
assert_eq "drift+existing: exit 0" "0" "$rc"
assert_eq "drift+existing: no new issue created" "no" "$([[ -f "$tmp_dir/create_log" ]] && echo yes || echo no)"
assert_eq "drift+existing: commented on #42" "42" "$(cat "$tmp_dir/comment_numbers" 2>/dev/null)"
calls="$(cat "$tmp_dir/calls" 2>/dev/null)"
assert_eq "drift+existing: dedup issue list carried GH_TOKEN" "yes" "$(saw "^$ci_token issue list" "$calls")"
assert_eq "drift+existing: issue comment carried GH_TOKEN" "yes" "$(saw "^$ci_token issue comment" "$calls")"
assert_eq "drift+existing: no filing call ran tokenless" "0" "$(grep -c '^<none> issue' <<<"$calls")"

# --- 4. upstream unresolvable: unable, never reported as clean or drift ---
printf '[]' > "$tmp_dir/issue_list_json"
rm -f "$tmp_dir/supercronic_tag"
err="$(run_check 2>&1 1>/dev/null)"; rc=$?
assert_eq "unable: exit 2" "2" "$rc"
assert_eq "unable: names the unresolved pin" "yes" "$(saw 'SUPERCRONIC_VERSION' "$err")"
assert_eq "unable: files nothing" "no" "$([[ -f "$tmp_dir/create_log" ]] && echo yes || echo no)"

# --- 5a. GitHub-resolved version fails the allowlist: unable, files nothing
printf '[]' > "$tmp_dir/issue_list_json"
printf 'v0.2.51`](https://evil)\n' > "$tmp_dir/supercronic_tag"
err="$(run_check 2>&1 1>/dev/null)"; rc=$?
assert_eq "github invalid: exit 2" "2" "$rc"
assert_eq "github invalid: names the unresolved pin" "yes" "$(saw 'SUPERCRONIC_VERSION' "$err")"
assert_eq "github invalid: files nothing" "no" "$([[ -f "$tmp_dir/create_log" ]] && echo yes || echo no)"
out="$(run_check --list)"
assert_eq "github invalid: --list prints ? for the pin" "yes" "$(saw 'SUPERCRONIC_VERSION	v0.2.47	?' "$out")"
assert_eq "github invalid: --list never leaks the raw tag" "no" "$(saw 'evil' "$out")"
printf 'v0.2.47\n' > "$tmp_dir/supercronic_tag"

# --- 5b. npm-resolved version fails the allowlist: unable, files nothing ---
printf '2.1.312`](https://evil)\n' > "$tmp_dir/claude_version"
err="$(run_check 2>&1 1>/dev/null)"; rc=$?
assert_eq "npm invalid: exit 2" "2" "$rc"
assert_eq "npm invalid: names the unresolved pin" "yes" "$(saw 'CLAUDE_CODE_VERSION' "$err")"
assert_eq "npm invalid: files nothing" "no" "$([[ -f "$tmp_dir/create_log" ]] && echo yes || echo no)"
out="$(run_check --list)"
assert_eq "npm invalid: --list prints ? for the pin" "yes" "$(saw 'CLAUDE_CODE_VERSION	2.1.267	?' "$out")"
assert_eq "npm invalid: --list never leaks the raw version" "no" "$(saw 'evil' "$out")"
printf '2.1.267\n' > "$tmp_dir/claude_version"

# --- 5. --list prints every pin and files nothing --------------------------
printf 'v0.2.47\n' > "$tmp_dir/supercronic_tag"
out="$(run_check --list)"; rc=$?
assert_eq "--list: exit 0" "0" "$rc"
assert_eq "--list: prints every pin" "yes" "$(saw 'SUPERCRONIC_VERSION' "$out")"
assert_eq "--list: resolves the upstream version too" "yes" "$(saw 'v0.2.47' "$out")"
assert_eq "--list: files nothing" "no" "$([[ -f "$tmp_dir/create_log" ]] && echo yes || echo no)"
assert_eq "--list: comments on nothing" "no" "$([[ -f "$tmp_dir/comment_log" ]] && echo yes || echo no)"

if (( failures > 0 )); then
  printf '%s failure(s)\n' "$failures"
  exit 1
fi
printf 'all tests passed\n'
