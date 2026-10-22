#!/usr/bin/env bash
#
# test/dashboard-blocked-enrichment-wiring.test.sh — regression test for the
# `blocked-enrichment` union-reader in scripts/publish-dashboard.sh
# (agent-ops#2548).
#
# `blocked_json` (the rows) arrives canonical: it is `open_blocked_items`'
# own output, already resolved through `$repo_slug_aliases_json`. But the
# `escalated`/`enabler-examined` events it joins against are raw union-log
# records, never themselves resolved — so a block recorded under a repo's
# old slug would never pick up an escalation or an Enabler verdict logged
# under the slug the repository has now, or the mirror, unless each event's
# own `repo` is canonicalized before the comparison.
#
# The block is lifted whole out of scripts/publish-dashboard.sh by its own
# `# union-reader: blocked-enrichment` / `# union-reader-end:` markers — the
# same technique test/stranded-legacy-blocked-wiring.test.sh and
# test/issues-excluded-wiring.test.sh use — so a change to the real jq
# program is what this suite tests, not a reimplementation of it.
#
# No test framework is used (none exists elsewhere in this repo); this is a
# plain bash script with hand-rolled assertions. Run it directly:
#
#   ./test/dashboard-blocked-enrichment-wiring.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=lib/union-stream.sh
. "$SCRIPT_DIR/lib/union-stream.sh"

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

# --- Lift the block under test whole out of scripts/publish-dashboard.sh ----
enrichment_src="$(awk '
  $0 == "# union-reader: blocked-enrichment" { on = 1; next }
  $0 == "# union-reader-end: blocked-enrichment" { exit }
  on { print }
' "$SCRIPT_DIR/scripts/publish-dashboard.sh")"
if [[ "$enrichment_src" != *'canon_repo'* || "$enrichment_src" != *'escalation_issue'* \
   || "$enrichment_src" != *'enabler_outcome'* ]]; then
  printf 'FAIL - could not extract the blocked-enrichment block from scripts/publish-dashboard.sh (moved or reworded?)\n'
  exit 1
fi

# --- The surroundings the block reads ----------------------------------------
blocked_rows_file="$tmp_dir/blocked-rows.json"
events_file="$tmp_dir/blocked-enrichment.jsonl"
# shellcheck disable=SC2034  # read by the lifted block, invisible to a static reader
union_kept_dir="$tmp_dir"  # the lifted block reads "$union_kept_dir/blocked-enrichment.jsonl"

run_enrichment() { eval "$enrichment_src"; }

# =============================================================================
# A block recorded under a repo's old slug still picks up an escalation and
# an Enabler verdict logged under the slug the repository has now, and the
# mirror (an escalation logged under the old slug reaching a block already
# read back under the new one).
# =============================================================================
# shellcheck disable=SC2034  # read by the lifted block, invisible to a static reader
repo_slug_aliases_json='{"o/old":"o/r"}'

jq -nc '[{repo: "o/r", item: "500", ts: "2026-10-01T00:00:00Z", detail: "d", stage: "coordinator", kind: "needs-refinement"},
         {repo: "o/r", item: "501", ts: "2026-10-01T00:00:00Z", detail: "d", stage: "coordinator", kind: "needs-refinement"}]' \
  > "$blocked_rows_file"
# The closing `{"span": ...}` line is `union_partition`'s own protocol
# (UNION_STREAM_JQ, lib/union-stream.sh): the real reader file always ends
# with one, and `union_split_span` treats the last record as it rather than
# as a kept event.
cat > "$events_file" <<'EOF'
{"ts":"2026-10-02T00:00:00Z","event":"escalated","repo":"o/old","item":"500","issue_number":77,"issue_url":"https://example/77"}
{"ts":"2026-10-02T00:00:00Z","event":"enabler-examined","repo":"o/old","item":"501","outcome":"blocked"}
{"span":{"lo":"2026-10-02T00:00:00Z","hi":"2026-10-02T00:00:00Z"}}
EOF

run_enrichment

# shellcheck disable=SC2154  # assigned by the lifted block, invisible to a static reader
assert_eq "an escalation logged under the repo's old slug still attaches to a block read back under the new one" \
  "77" "$(jq -r '.[] | select(.item == "500") | .escalation_issue' <<<"$blocked_json")"
assert_eq "...and carries its own issue_url" \
  "https://example/77" "$(jq -r '.[] | select(.item == "500") | .escalation_url' <<<"$blocked_json")"
assert_eq "an Enabler verdict logged under the repo's old slug still attaches the same way" \
  "blocked" "$(jq -r '.[] | select(.item == "501") | .enabler_outcome' <<<"$blocked_json")"

# =============================================================================
# With no aliases map, the rename splits the join: nothing attaches.
# =============================================================================
# shellcheck disable=SC2034  # read by the lifted block, invisible to a static reader
repo_slug_aliases_json='{}'
run_enrichment
assert_eq "...with no aliases map, the old-slug event never reaches the new-slug row" \
  "null" "$(jq -r '.[] | select(.item == "500") | .escalation_issue // "null"' <<<"$blocked_json")"
assert_eq "  ... nor does the Enabler verdict" \
  "null" "$(jq -r '.[] | select(.item == "501") | .enabler_outcome // "null"' <<<"$blocked_json")"

if (( failures == 0 )); then
  echo "All dashboard-blocked-enrichment-wiring assertions passed."
  exit 0
fi
echo "$failures dashboard-blocked-enrichment-wiring assertion(s) FAILED." >&2
exit 1
