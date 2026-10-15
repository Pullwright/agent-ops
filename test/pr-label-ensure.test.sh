#!/usr/bin/env bash
#
# test/pr-label-ensure.test.sh — regression test for `pr_label_ensure`
# (lib/labels.sh, requirement 17a, agent-ops#2074/#2403): the Script's own
# backstop that applies `pr_label` directly to a pull request the
# Implementer just raised, idempotently, rather than trusting the model's
# own "Label it `pr_label`" step (prompts/implementer.md) to have run.
#
# `gh` is stubbed, recording every invocation, so the assertions are about
# the requests the function actually makes rather than about a copy of its
# logic. No network is used and nothing is created anywhere real.
#
# No test framework is used (none exists elsewhere in this repo); this is a
# plain bash script with hand-rolled assertions. Run it directly:
#
#   ./test/pr-label-ensure.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/labels.sh
. "$SCRIPT_DIR/lib/labels.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

failures=0
pass() { printf 'ok   - %s\n' "$1"; }
assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass "$desc"
  else
    printf 'FAIL - %s\n     expected: %s\n     actual:   %s\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}

# --- The stub: a pull request's current labels, and an --add-label call
#     that appends to them like GitHub's own no-op-on-duplicate add does. ---
cat > "$tmp/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
if [[ "$1" == "pr" && "$2" == "view" ]]; then
  [[ -n "${GH_VIEW_FAILS:-}" ]] && { echo "gh: HTTP 404" >&2; exit 1; }
  cat "$GH_LABELS" 2>/dev/null
  exit 0
fi
if [[ "$1" == "pr" && "$2" == "edit" ]]; then
  number="$3"; shift 3
  repo=""; label=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -R) repo="$2"; shift 2 ;;
      --add-label) label="$2"; shift 2 ;;
      *) shift ;;
    esac
  done
  [[ -n "${GH_EDIT_FAILS:-}" ]] && { echo "gh: HTTP 403" >&2; exit 1; }
  printf '%s\n' "$label" >> "$GH_LABELS"
  printf '%s\t%s\t%s\n' "$repo" "$number" "$label" >> "$GH_APPLY_LOG"
  exit 0
fi
echo "stub gh: unexpected invocation: $*" >&2
exit 64
STUB
chmod +x "$tmp/gh"
export LABELS_GH="$tmp/gh"

reset_stub() {
  : > "$tmp/log"
  : > "$tmp/apply-log"
  export GH_LOG="$tmp/log" GH_APPLY_LOG="$tmp/apply-log"
  unset GH_VIEW_FAILS GH_EDIT_FAILS
  : > "$tmp/labels"
  export GH_LABELS="$tmp/labels"
  [[ $# -eq 0 ]] || printf '%s\n' "$@" > "$tmp/labels"
}

# --- Already present: nothing is touched. ---

reset_stub "complexity:low" "autonomous-agent"
out="$(pr_label_ensure acme/widgets 12 autonomous-agent)"; rc=$?
assert_eq "label already present: prints 'present'" "present" "$out"
assert_eq "  ... exit 0" "0" "$rc"
assert_eq "  ... no --add-label call was ever made" "0" "$(wc -l < "$tmp/apply-log")"

# --- Absent: added directly, GitHub's own no-op-on-duplicate semantics
#     meaning this is the one call that must actually be made. ---

reset_stub "complexity:low"
out="$(pr_label_ensure acme/widgets 12 autonomous-agent)"; rc=$?
assert_eq "label absent: prints 'added'" "added" "$out"
assert_eq "  ... exit 0" "0" "$rc"
assert_eq "  ... --add-label was called against the right repo/number/label" \
  "acme/widgets	12	autonomous-agent" "$(cat "$tmp/apply-log")"

# --- Unreadable list: best-effort add attempted, reported failed. ---

reset_stub
export GH_VIEW_FAILS=1
out="$(pr_label_ensure acme/widgets 12 autonomous-agent)"; rc=$?
assert_eq "labels unreadable: prints 'failed'" "failed" "$out"
assert_eq "  ... exit 1" "1" "$rc"
assert_eq "  ... the add was still attempted, best-effort" \
  "acme/widgets	12	autonomous-agent" "$(cat "$tmp/apply-log")"
unset GH_VIEW_FAILS

# --- Add refused (most often: the label was never created in this repo). ---

reset_stub "complexity:low"
export GH_EDIT_FAILS=1
out="$(pr_label_ensure acme/widgets 12 autonomous-agent)"; rc=$?
assert_eq "add refused: prints 'failed'" "failed" "$out"
assert_eq "  ... exit 1" "1" "$rc"
unset GH_EDIT_FAILS

# --- An empty argument is refused outright, without spending a `gh` call —
#     the same guard refinement_label_project and
#     landing_open_question_label_project carry. ---

reset_stub "complexity:low"
out="$(pr_label_ensure acme/widgets "" autonomous-agent)"; rc=$?
assert_eq "empty pull-request number: prints 'failed'" "failed" "$out"
assert_eq "  ... exit 1" "1" "$rc"
assert_eq "  ... no gh call was made at all" "0" "$(wc -l < "$tmp/log")"

reset_stub "complexity:low"
out="$(pr_label_ensure acme/widgets 12 "")"; rc=$?
assert_eq "empty label: prints 'failed'" "failed" "$out"
assert_eq "  ... no gh call was made at all" "0" "$(wc -l < "$tmp/log")"

echo
if (( failures > 0 )); then
  echo "$failures assertion(s) failed"
  exit 1
fi
echo "all assertions passed"
