#!/usr/bin/env bash
#
# test/release-pending-reservations.test.sh — regression tests for
# scripts/release-pending-reservations.sh (TD-PPagop-26082427): the retry
# pass for a tech-debt reservation release lib/tech-debt-file.sh's
# `_techdebt_unfile` could not make land the first time.
#
# Behaviours asserted:
#
#   - **A marker whose branch delete now succeeds is reported "released"**,
#     and its own marker file is cleared from the state repository.
#   - **A marker whose branch is already gone (a peer's concurrent retry, or
#     a delete by hand) reports "absent"**, not an
#     error, and is cleared the same way.
#   - **A marker whose delete fails again reports "warning"**, and is left in
#     place — checked by asserting no DELETE of the marker file itself is
#     attempted.
#   - **A marker younger than `reservation_release_stuck_after_days` still
#     reports "warning"**, however many times it has already failed
#     (TD-PPagop-26082806, agent-ops#1011).
#   - **A marker at/past that threshold escalates exactly once**: it reports
#     `"reservation-release-stuck"` instead of `"warning"`, and gains its own
#     `escalated_at` field via a `contents` API `PUT` against the marker.
#   - **A marker already carrying `escalated_at` reports nothing at all** on a
#     further failed delete — no repeated escalation, no fallback `warning` —
#     while the delete itself is still retried every pass.
#   - **`reservation_release_stuck_after_days: 0` disables escalation**,
#     restoring the unconditional retry-and-warn-forever behaviour regardless
#     of the marker's own age.
#   - **A marker whose `escalated_at` write itself fails falls back to an
#     ordinary `"warning"`**, rather than claiming an escalation that did not
#     persist.
#   - **A malformed marker (missing repo or branch) reports "warning"** and is
#     left in place rather than acted on.
#   - **No `state_repo` configured is a silent no-op** — no `gh` call at all.
#   - **An empty `reservation-releases/` tree is a silent no-op.**
#   - **One invocation covers markers naming different target repositories**,
#     each independently.
#   - **A `td-record/<id>` marker's release always completes before its
#     sibling `td/<id>` marker's, even when the directory listing names the
#     `td/<id>` one first** (TD-PPagop-26082805) — matching
#     `_techdebt_unfile`'s own record-branch-before-reservation ordering
#     regardless of what order GitHub's own listing returns the two markers
#     in.
#
# `gh` is stubbed through RELEASE_PENDING_GH, the technique
# test/sweep-orphan-branches.test.sh's own SWEEP_GH already uses to bypass
# lib/github-limit.sh's rate-limit wrapper in tests.
#
# No test framework is used (none exists elsewhere in this repo). Run it
# directly:
#
#   ./test/release-pending-reservations.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE="$SCRIPT_DIR/scripts/release-pending-reservations.sh"

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

config_no_state="$tmp_dir/config-no-state.json"
jq -n '{}' > "$config_no_state"

config="$tmp_dir/config.json"
jq -n '{state_repo: "o/state"}' > "$config"

# Explicit rather than relying on the schema default, so this test does not
# silently drift if that default ever changes.
config_stuck14="$tmp_dir/config-stuck14.json"
jq -n '{state_repo: "o/state", reservation_release_stuck_after_days: 14}' > "$config_stuck14"

config_stuck_disabled="$tmp_dir/config-stuck-disabled.json"
jq -n '{state_repo: "o/state", reservation_release_stuck_after_days: 0}' > "$config_stuck_disabled"

# --- The stub gh ---------------------------------------------------------------
# $tmp_dir/dirs.json            newline-separated dir names under reservation-releases/,
#                                one per line -- matching what `gh --jq '[...] | .[]'`
#                                actually prints for real, not a JSON array literal
# $tmp_dir/files-<dir>.json     newline-separated file names under reservation-releases/<dir>/
# $tmp_dir/marker-<dir>-<file>  the marker's own body (repo, branch) and a "sha"
#                                field this stub reports as the file's own blob sha
# $tmp_dir/delete-fails         branch names (one per line, "repo branch") whose
#                                git/refs/heads/<branch> DELETE fails
# $tmp_dir/absent-branches      branch names (one per line, "repo branch") whose
#                                git/ref/heads/<branch> GET 404s
# $tmp_dir/marker-delete-fails  "dir/file" entries whose marker DELETE fails
# $tmp_dir/calls                every invocation's argv, one per line
stub="$tmp_dir/gh"
cat > "$stub" <<'STUB'
#!/usr/bin/env bash
d="$RELEASE_STUB_DIR"
printf '%s\n' "$*" >> "$d/calls"

# repos/<state_repo>/contents/reservation-releases  (top-level dir listing)
if [[ "$1" == "api" && "$2" == "repos/o/state/contents/reservation-releases" && "$3" == "--jq" ]]; then
  cat "$d/dirs.json" 2>/dev/null
  exit 0
fi

# repos/<state_repo>/contents/reservation-releases/<dir>  (file listing)
if [[ "$1" == "api" && "$2" == repos/o/state/contents/reservation-releases/* && "$3" == "--jq" ]]; then
  dir="${2##*/reservation-releases/}"
  cat "$d/files-$dir.json" 2>/dev/null
  exit 0
fi

# repos/<state_repo>/contents/reservation-releases/<dir>/<file>  (one marker's content)
if [[ "$1" == "api" && "$2" == repos/o/state/contents/reservation-releases/*/* ]]; then
  path="${2#repos/o/state/contents/reservation-releases/}"
  cat "$d/marker-${path//\//__}" 2>/dev/null && exit 0
  exit 1
fi

if [[ "$1" == "api" && "$2" == "-X" && "$3" == "DELETE" && "$4" == repos/o/state/contents/reservation-releases/* ]]; then
  path="${4#repos/o/state/contents/reservation-releases/}"
  grep -qxF "$path" "$d/marker-delete-fails" 2>/dev/null && exit 1
  exit 0
fi

# repos/<state_repo>/contents/reservation-releases/<dir>/<file>  (rewrite a marker,
# e.g. to write escalated_at back onto it) -- records the decoded new body under
# put-content-<dir>__<file> so a test can assert what was written.
if [[ "$1" == "api" && "$2" == "-X" && "$3" == "PUT" && "$4" == repos/o/state/contents/reservation-releases/* ]]; then
  path="${4#repos/o/state/contents/reservation-releases/}"
  grep -qxF "$path" "$d/marker-put-fails" 2>/dev/null && exit 1
  content=""
  for arg in "$@"; do
    case "$arg" in
      content=*) content="${arg#content=}" ;;
    esac
  done
  printf '%s' "$content" | base64 -d > "$d/put-content-${path//\//__}" 2>/dev/null || true
  exit 0
fi

if [[ "$1" == "api" && "$2" == "-X" && "$3" == "DELETE" && "$4" == *"/git/refs/heads/"* ]]; then
  repo="$(sed -E 's#repos/([^/]+/[^/]+)/git/refs/heads/.*#\1#' <<<"$4")"
  branch="${4##*/git/refs/heads/}"
  grep -qxF "$repo $branch" "$d/delete-fails" 2>/dev/null && exit 1
  exit 0
fi

if [[ "$1" == "api" && "$2" == *"/git/ref/heads/"* ]]; then
  repo="$(sed -E 's#repos/([^/]+/[^/]+)/git/ref/heads/.*#\1#' <<<"$2")"
  branch="${2##*/git/ref/heads/}"
  if grep -qxF "$repo $branch" "$d/absent-branches" 2>/dev/null; then
    echo "gh: Not Found (HTTP 404)" >&2
    exit 1
  fi
  echo '{"object":{"sha":"deadbeef"}}'
  exit 0
fi

exit 1
STUB
chmod +x "$stub"

reset_stub() {
  : > "$tmp_dir/calls"
  rm -f "$tmp_dir"/marker-*.json "$tmp_dir"/files-*.json "$tmp_dir"/put-content-*
  : > "$tmp_dir/delete-fails"
  : > "$tmp_dir/absent-branches"
  : > "$tmp_dir/marker-delete-fails"
  : > "$tmp_dir/marker-put-fails"
  : > "$tmp_dir/dirs.json"
}

# "Now" for every run() below: the same instant the default marker `ts`
# (DEFAULT_TS) already names, so an ordinary marker using that default is
# always exactly 0 days old and never crosses reservation_release_stuck_after_days
# on its own -- only a test that deliberately backdates ts (age_days below)
# exercises the stuck-marker path.
NOW_EPOCH="$(date -u -d "2026-08-23T16:23:03Z" +%s)"
DEFAULT_TS="2026-08-23T16:23:03Z"

# age_days N -- an RFC3339 timestamp N days before NOW_EPOCH.
age_days() { date -u -d "@$(( NOW_EPOCH - ${1} * 86400 ))" +%Y-%m-%dT%H:%M:%SZ; }

# marker DIR FILE REPO BRANCH [SHA] [TS] [ESCALATED_AT] -- writes the fixture
# files a listing of DIR would report FILE under, and the base64-content
# response for that path exactly as GitHub's contents API shapes it.
marker() {
  local dir="$1" file="$2" repo="$3" branch="$4" sha="${5:-abc123}" \
        ts="${6:-$DEFAULT_TS}" escalated_at="${7:-}" body
  if [[ -n "$escalated_at" ]]; then
    body="$(jq -nc --arg repo "$repo" --arg branch "$branch" --arg ts "$ts" --arg esc "$escalated_at" \
      '{repo: $repo, branch: $branch, ts: $ts, escalated_at: $esc}')"
  else
    body="$(jq -nc --arg repo "$repo" --arg branch "$branch" --arg ts "$ts" \
      '{repo: $repo, branch: $branch, ts: $ts}')"
  fi
  jq -nc --arg sha "$sha" --arg body "$body" '{sha: $sha, content: ($body | @base64)}' \
    > "$tmp_dir/marker-${dir}__${file}"
}

run() {
  RELEASE_PENDING_GH="$stub" RELEASE_STUB_DIR="$tmp_dir" RELEASE_PENDING_NOW_EPOCH="$NOW_EPOCH" \
    AGENT_OPS_CONFIG="$1" "$RELEASE"
}

# --- No state_repo configured -> silent no-op, gh never called -------------
reset_stub
out="$(run "$config_no_state")"; rc=$?
assert_eq "no state_repo: exit 0" "0" "$rc"
assert_eq "  ... no output" "" "$out"
assert_eq "  ... gh never called" "" "$(cat "$tmp_dir/calls")"

# --- Empty reservation-releases/ tree -> silent no-op -----------------------
reset_stub
out="$(run "$config")"; rc=$?
assert_eq "empty tree: exit 0" "0" "$rc"
assert_eq "  ... no output" "" "$out"

# --- A marker whose delete now succeeds -> released, and marker cleared ----
reset_stub
echo "o__r" > "$tmp_dir/dirs.json"
echo "td__TD-PPagop-26082407.json" > "$tmp_dir/files-o__r.json"
marker "o__r" "td__TD-PPagop-26082407.json" "o/r" "td/TD-PPagop-26082407"
out="$(run "$config")"; rc=$?
assert_eq "delete succeeds: exit 0" "0" "$rc"
assert_eq "  ... action released" "released" "$(jq -r '.action' <<<"$out")"
assert_eq "  ... repo/branch reported" "o/r td/TD-PPagop-26082407" \
  "$(jq -r '"\(.repo) \(.branch)"' <<<"$out")"
assert_eq "  ... the branch delete was attempted" "1" \
  "$(grep -c 'api -X DELETE repos/o/r/git/refs/heads/td/TD-PPagop-26082407' "$tmp_dir/calls")"
assert_eq "  ... the marker itself was cleared" "1" \
  "$(grep -c 'api -X DELETE repos/o/state/contents/reservation-releases/o__r/td__TD-PPagop-26082407.json' "$tmp_dir/calls")"

# --- A marker whose branch is already gone -> absent, marker still cleared -
reset_stub
echo "o__r" > "$tmp_dir/dirs.json"
echo "td__TD-PPagop-26082408.json" > "$tmp_dir/files-o__r.json"
marker "o__r" "td__TD-PPagop-26082408.json" "o/r" "td/TD-PPagop-26082408"
echo "o/r td/TD-PPagop-26082408" > "$tmp_dir/delete-fails"
echo "o/r td/TD-PPagop-26082408" > "$tmp_dir/absent-branches"
out="$(run "$config")"; rc=$?
assert_eq "already absent: exit 0" "0" "$rc"
assert_eq "  ... action absent" "absent" "$(jq -r '.action' <<<"$out")"
assert_eq "  ... the marker itself was still cleared" "1" \
  "$(grep -c 'api -X DELETE repos/o/state/contents/reservation-releases/o__r/td__TD-PPagop-26082408.json' "$tmp_dir/calls")"

# --- A marker whose delete fails again -> warning, marker left in place ----
reset_stub
echo "o__r" > "$tmp_dir/dirs.json"
echo "td__TD-PPagop-26082409.json" > "$tmp_dir/files-o__r.json"
marker "o__r" "td__TD-PPagop-26082409.json" "o/r" "td/TD-PPagop-26082409"
echo "o/r td/TD-PPagop-26082409" > "$tmp_dir/delete-fails"
out="$(run "$config")"; rc=$?
assert_eq "delete fails again: exit 0" "0" "$rc"
assert_eq "  ... action warning" "warning" "$(jq -r '.action' <<<"$out")"
assert_eq "  ... the marker itself was NOT cleared" "0" \
  "$(grep -c 'api -X DELETE repos/o/state/contents/reservation-releases/o__r/td__TD-PPagop-26082409.json' "$tmp_dir/calls")"

# --- A marker just below the stuck threshold -> still an ordinary warning --
reset_stub
echo "o__r" > "$tmp_dir/dirs.json"
echo "td__TD-PPagop-26082412.json" > "$tmp_dir/files-o__r.json"
marker "o__r" "td__TD-PPagop-26082412.json" "o/r" "td/TD-PPagop-26082412" "abc123" "$(age_days 13)"
echo "o/r td/TD-PPagop-26082412" > "$tmp_dir/delete-fails"
out="$(run "$config_stuck14")"; rc=$?
assert_eq "13d old, 14d threshold: exit 0" "0" "$rc"
assert_eq "  ... still an ordinary warning" "warning" "$(jq -r '.action' <<<"$out")"
assert_eq "  ... the marker itself was NOT rewritten" "0" \
  "$(grep -c 'api -X PUT repos/o/state/contents/reservation-releases/o__r/td__TD-PPagop-26082412.json' "$tmp_dir/calls")"

# --- A marker at/past the stuck threshold -> escalates once, marker flagged
reset_stub
echo "o__r" > "$tmp_dir/dirs.json"
echo "td__TD-PPagop-26082413.json" > "$tmp_dir/files-o__r.json"
marker "o__r" "td__TD-PPagop-26082413.json" "o/r" "td/TD-PPagop-26082413" "abc123" "$(age_days 14)"
echo "o/r td/TD-PPagop-26082413" > "$tmp_dir/delete-fails"
out="$(run "$config_stuck14")"; rc=$?
assert_eq "14d old, 14d threshold: exit 0" "0" "$rc"
assert_eq "  ... action reservation-release-stuck" "reservation-release-stuck" "$(jq -r '.action' <<<"$out")"
assert_eq "  ... repo/branch reported" "o/r td/TD-PPagop-26082413" \
  "$(jq -r '"\(.repo) \(.branch)"' <<<"$out")"
assert_eq "  ... the marker itself was rewritten with escalated_at" "1" \
  "$(grep -c 'api -X PUT repos/o/state/contents/reservation-releases/o__r/td__TD-PPagop-26082413.json' "$tmp_dir/calls")"
assert_eq "  ... escalated_at was actually written" "true" \
  "$(jq -r 'has("escalated_at")' "$tmp_dir/put-content-o__r__td__TD-PPagop-26082413.json")"
assert_eq "  ... the marker itself was NOT cleared" "0" \
  "$(grep -c 'api -X DELETE repos/o/state/contents/reservation-releases/o__r/td__TD-PPagop-26082413.json' "$tmp_dir/calls")"

# --- A marker already escalated -> retried silently, no event, no re-write -
reset_stub
echo "o__r" > "$tmp_dir/dirs.json"
echo "td__TD-PPagop-26082414.json" > "$tmp_dir/files-o__r.json"
marker "o__r" "td__TD-PPagop-26082414.json" "o/r" "td/TD-PPagop-26082414" "abc123" \
  "$(age_days 30)" "$(age_days 10)"
echo "o/r td/TD-PPagop-26082414" > "$tmp_dir/delete-fails"
out="$(run "$config_stuck14")"; rc=$?
assert_eq "already escalated: exit 0" "0" "$rc"
assert_eq "  ... nothing printed at all" "" "$out"
assert_eq "  ... the branch delete was still retried" "1" \
  "$(grep -c 'api -X DELETE repos/o/r/git/refs/heads/td/TD-PPagop-26082414' "$tmp_dir/calls")"
assert_eq "  ... the marker was NOT rewritten again" "0" \
  "$(grep -c 'api -X PUT repos/o/state/contents/reservation-releases/o__r/td__TD-PPagop-26082414.json' "$tmp_dir/calls")"
assert_eq "  ... the marker itself was NOT cleared" "0" \
  "$(grep -c 'api -X DELETE repos/o/state/contents/reservation-releases/o__r/td__TD-PPagop-26082414.json' "$tmp_dir/calls")"

# --- Escalation disabled (reservation_release_stuck_after_days: 0) ---------
reset_stub
echo "o__r" > "$tmp_dir/dirs.json"
echo "td__TD-PPagop-26082415.json" > "$tmp_dir/files-o__r.json"
marker "o__r" "td__TD-PPagop-26082415.json" "o/r" "td/TD-PPagop-26082415" "abc123" "$(age_days 90)"
echo "o/r td/TD-PPagop-26082415" > "$tmp_dir/delete-fails"
out="$(run "$config_stuck_disabled")"; rc=$?
assert_eq "escalation disabled: exit 0" "0" "$rc"
assert_eq "  ... still an ordinary warning, however old" "warning" "$(jq -r '.action' <<<"$out")"
assert_eq "  ... the marker itself was NOT rewritten" "0" \
  "$(grep -c 'api -X PUT repos/o/state/contents/reservation-releases/o__r/td__TD-PPagop-26082415.json' "$tmp_dir/calls")"

# --- The escalated_at write itself fails -> falls back to an ordinary warning
reset_stub
echo "o__r" > "$tmp_dir/dirs.json"
echo "td__TD-PPagop-26082416.json" > "$tmp_dir/files-o__r.json"
marker "o__r" "td__TD-PPagop-26082416.json" "o/r" "td/TD-PPagop-26082416" "abc123" "$(age_days 14)"
echo "o/r td/TD-PPagop-26082416" > "$tmp_dir/delete-fails"
echo "o__r/td__TD-PPagop-26082416.json" > "$tmp_dir/marker-put-fails"
out="$(run "$config_stuck14")"; rc=$?
assert_eq "escalated_at write fails: exit 0" "0" "$rc"
assert_eq "  ... falls back to an ordinary warning" "warning" "$(jq -r '.action' <<<"$out")"
assert_eq "  ... the marker itself was NOT cleared" "0" \
  "$(grep -c 'api -X DELETE repos/o/state/contents/reservation-releases/o__r/td__TD-PPagop-26082416.json' "$tmp_dir/calls")"

# --- A malformed marker (no repo/branch) -> warning, left in place ---------
reset_stub
echo "o__r" > "$tmp_dir/dirs.json"
echo "broken.json" > "$tmp_dir/files-o__r.json"
jq -nc '{sha: "abc123", content: ("{}" | @base64)}' > "$tmp_dir/marker-o__r__broken.json"
out="$(run "$config")"; rc=$?
assert_eq "malformed marker: exit 0" "0" "$rc"
assert_eq "  ... action warning" "warning" "$(jq -r '.action' <<<"$out")"
assert_eq "  ... no DELETE of anything attempted" "0" \
  "$(grep -c 'api -X DELETE' "$tmp_dir/calls")"

# --- Two markers under different repo dirs are each handled independently --
reset_stub
printf 'o__r\nacme__widgets\n' > "$tmp_dir/dirs.json"
echo "td__TD-PPagop-26082410.json" > "$tmp_dir/files-o__r.json"
echo "td__TD-PPagop-26082411.json" > "$tmp_dir/files-acme__widgets.json"
marker "o__r" "td__TD-PPagop-26082410.json" "o/r" "td/TD-PPagop-26082410"
marker "acme__widgets" "td__TD-PPagop-26082411.json" "acme/widgets" "td/TD-PPagop-26082411"
out="$(run "$config")"; rc=$?
n="$(jq -s 'length' <<<"$out")"
assert_eq "two repos: exit 0" "0" "$rc"
assert_eq "  ... two lines emitted" "2" "$n"
assert_eq "  ... both reported released" "released
released" "$(jq -r '.action' <<<"$out")"
assert_eq "  ... both repos named" "acme/widgets
o/r" "$(jq -r '.repo' <<<"$out" | sort)"

# --- Two markers for one id, listed reservation-first -> the record-branch
# marker's own release still completes before the reservation-branch
# marker's does (TD-PPagop-26082805): `td__<id>.json` sorts ahead of
# `td-record__<id>.json` in a plain byte-collation listing, the hazard shape
# component 23d and `_techdebt_unfile`'s own ordering (releasing
# `td-record/<id>` before `td/<id>`) exist to prevent regardless of listing
# order. -----------------------------------------------------------------
reset_stub
echo "o__r" > "$tmp_dir/dirs.json"
printf 'td__TD-PPagop-26082805.json\ntd-record__TD-PPagop-26082805.json\n' \
  > "$tmp_dir/files-o__r.json"
marker "o__r" "td__TD-PPagop-26082805.json" "o/r" "td/TD-PPagop-26082805"
marker "o__r" "td-record__TD-PPagop-26082805.json" "o/r" "td-record/TD-PPagop-26082805"
out="$(run "$config")"; rc=$?
n="$(jq -s 'length' <<<"$out")"
assert_eq "record-before-reservation: exit 0" "0" "$rc"
assert_eq "  ... two lines emitted" "2" "$n"
assert_eq "  ... both reported released" "released
released" "$(jq -r '.action' <<<"$out")"
record_line="$(grep -n 'api -X DELETE repos/o/r/git/refs/heads/td-record/TD-PPagop-26082805' \
  "$tmp_dir/calls" | head -n1 | cut -d: -f1)"
reservation_line="$(grep -n 'api -X DELETE repos/o/r/git/refs/heads/td/TD-PPagop-26082805' \
  "$tmp_dir/calls" | head -n1 | cut -d: -f1)"
if [[ -n "$record_line" && -n "$reservation_line" ]] && (( record_line < reservation_line )); then
  ordering="record-first"
else
  ordering="reservation-first"
fi
assert_eq "  ... td-record/<id> branch deleted before td/<id> branch, despite reservation-first listing" \
  "record-first" "$ordering"

echo
if [[ "$failures" -eq 0 ]]; then
  echo "All tests passed."
  exit 0
else
  echo "$failures test(s) failed."
  exit 1
fi
