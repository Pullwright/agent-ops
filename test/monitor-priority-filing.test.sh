#!/usr/bin/env bash
#
# test/monitor-priority-filing.test.sh — the Pipeline Monitor's own two
# banded filings actually reach GitHub's `Priority` field
# (agent-ops#2422, requirement 1; docs/spec/monitor.md M13a/M14a).
#
# Every other filer this repository has — lib/pager.sh, lib/merge-budget.sh,
# lib/tech-debt-file.sh, scripts/sweep-decision-vetoes.sh — has a test of its
# own asserting the band it writes. `monitor-cycle.sh` is the one that files
# without going through any of them: `monitor_create_issue` calls
# `issue_priority_apply` directly, and the script's own top-level sources do
# not include lib/issue-priority.sh (lib/pager.sh is the only route to it, and
# sources it lazily too). So the call needs its own lazy-source guard, and
# without one it runs *undefined* — where `>/dev/null 2>&1 || true` swallows
# the `command not found` and both filings land at the unset default with
# nothing in the log saying so. That is a defect with no symptom: the issues
# are filed, the run reports success, and only the backlog's ranking is
# quietly wrong. This file is what makes it visible.
#
# The two filings, and the band each is specified to carry:
#
#   M14a  a mechanical finding — a reasoning or logic defect in the
#         pipeline's own code, caught live — files at `High`.
#   M13a  a finding restated past `monitor_promote_after`, promoted into a
#         pager-invariant proposal — tooling work, not a live defect —
#         files at `Medium`.
#
# Same vehicle as test/monitor-cycle.test.sh: the **real** `monitor-cycle.sh`
# against a shim node of symlinks back into the tree with its own
# `config.json`, with `claude` and `gh` stubbed. The `gh` stub additionally
# answers the two GraphQL calls `issue_priority_apply` makes — the field-id
# introspection and the `setIssueFieldValue` mutation — and records every
# option id the mutation was asked to write, which is what the assertions
# read. Asserting the *mutation* rather than the function's return value is
# deliberate: the undefined-function case returns nothing either way, so only
# the call that would have gone out tells the two apart.
#
# No network: `state_repo` is empty (which makes the slot claim vacuously
# won, lib/claim.sh) and the stubs are ahead of everything on PATH.
#
# Run directly: ./test/monitor-priority-filing.test.sh — exit 0 iff all passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

tmp_dir="${MONITOR_PRIORITY_TEST_TMP:-$(mktemp -d)}"
mkdir -p "$tmp_dir"
[[ -n "${MONITOR_PRIORITY_TEST_TMP:-}" ]] || trap 'rm -rf "$tmp_dir"' EXIT

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
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:   %s\n' \
      "$desc" "$needle" "${haystack:0:600}"
    failures=$(( failures + 1 ))
  fi
}

# --- The shim node ----------------------------------------------------------
# `$2` is a jq filter applied to the shipped config, so each case states only
# its difference and every other required key stays in step with the real
# file — the acceptance-check rule that no test may assert a particular value
# from `config.json`.
make_node() {  # make_node <name> <jq-filter> -> prints its directory
  local name="$1" filter="$2"
  local dir="$tmp_dir/$name"
  mkdir -p "$dir" "$dir/home" "$dir/stub/bodies"
  local item
  for item in lib prompts scripts docs .claude monitor-cycle.sh review-cycle.sh \
              agent-cycle.sh config.schema.json; do
    # `-fn`, not a bare `-s`: a second `ln -s dir existing-symlink-to-dir`
    # follows the existing link and creates the target *inside* it — which,
    # for a symlink pointing back into the checkout, means writing a stray
    # `lib/lib` into the repository itself.
    [[ -e "$SCRIPT_DIR/$item" ]] && ln -sfn "$SCRIPT_DIR/$item" "$dir/$item"
  done
  jq "$filter" "$SCRIPT_DIR/config.json" > "$dir/config.json"

  printf '[]\n'  > "$dir/stub/open-findings.json"
  printf '[]\n'  > "$dir/stub/open-pages.json"
  printf '900\n' > "$dir/stub/next-issue-number"
  : > "$dir/stub/calls.log"
  : > "$dir/stub/priority-mutations.log"

  # The `gh` stub. Beyond the listings and the create that
  # test/monitor-cycle.test.sh's own stub answers, this one answers
  # `issue_priority_apply`'s three calls (lib/issue-priority.sh): the
  # field-id introspection, the issue re-read the ratchet does immediately
  # before writing, and the `setIssueFieldValue` mutation — logging the
  # option id of every write attempt, one per line, as `<slug> <optionId>`.
  cat > "$dir/stub/gh" <<STUB
#!/usr/bin/env bash
set -uo pipefail
D='$dir/stub'
printf '%s\n' "\$*" >> "\$D/calls.log"

args=("\$@")
have() { local n="\$1" a; for a in "\${args[@]}"; do [[ "\$a" == "\$n" ]] && return 0; done; return 1; }
after() { local n="\$1" i; for i in "\${!args[@]}"; do [[ "\${args[\$i]}" == "\$n" ]] && { printf '%s' "\${args[\$(( i + 1 ))]:-}"; return 0; }; done; return 1; }
# The GraphQL calls pass their values as \`-f <name>=<value>\`, so the name is
# a *prefix* of an argument rather than an argument of its own.
valueof() { local p="\$1" a; for a in "\${args[@]}"; do [[ "\$a" == "\$p"* ]] && { printf '%s' "\${a#"\$p"}"; return 0; }; done; return 1; }

# The field the writes target. One field, all four bands — the complete case,
# so nothing here exercises lib/issue-priority.sh's own fallback or
# missing-option branches (test/issue-priority.test.sh owns those).
FIELD_JSON='{"data":{"repository":{"issueFields":{"nodes":[
  {"id":"IFSS_priority","name":"Priority","options":[
    {"id":"OPT_URGENT","name":"Urgent"},{"id":"OPT_HIGH","name":"High"},
    {"id":"OPT_MEDIUM","name":"Medium"},{"id":"OPT_LOW","name":"Low"}]}]}}}}'

case "\${1:-}" in
  issue)
    case "\${2:-}" in
      list)
        if have --label && [[ "\$(after --label)" == "pw::pager" ]]; then
          cat "\$D/open-pages.json"
        elif have --search && [[ "\$(after --search)" == *monitor-finding-key* ]]; then
          cat "\$D/open-findings.json"
        else
          printf '[]\n'
        fi
        exit 0
        ;;
      create)
        n="\$(cat "\$D/next-issue-number")"
        printf '%s\n' "\$(( n + 1 ))" > "\$D/next-issue-number"
        body_file="\$(after --body-file)"
        title="\$(after --title)"
        repo="\$(after -R)"
        cp "\$body_file" "\$D/bodies/\$n.md"
        printf '%s\n' "\$title" > "\$D/bodies/\$n.title"
        key="\$(grep -oE 'monitor-finding-key: [a-z0-9][a-z0-9-]*' "\$body_file" | head -n1 | awk '{print \$2}')"
        if [[ -n "\$key" ]]; then
          jq --arg k "\$key" --argjson n "\$n" --arg u "https://github.com/\$repo/issues/\$n" \\
             --arg t "\$title" '. + [{key: \$k, number: \$n, url: \$u, title: \$t, body: ("monitor-finding-key: " + \$k)}]' \\
             "\$D/open-findings.json" > "\$D/open-findings.json.tmp" && mv "\$D/open-findings.json.tmp" "\$D/open-findings.json"
        fi
        printf 'https://github.com/%s/issues/%s\n' "\$repo" "\$n"
        exit 0
        ;;
      *) exit 0 ;;
    esac
    ;;
  api)
    case "\${2:-}" in
      graphql)
        query="\$(valueof 'query=' || true)"
        if [[ "\$query" == *setIssueFieldValue* ]]; then
          printf '%s %s\n' "\$(valueof 'issueId=' || true)" "\$(valueof 'optionId=' || true)" \\
            >> "\$D/priority-mutations.log"
          exit 0
        fi
        jq -c "\$(after --jq || printf '.')" <<<"\$FIELD_JSON" 2>/dev/null
        exit 0
        ;;
      repos/*/issues/*)
        # The ratchet's pre-write re-read. \`issue_field_values\` empty — the
        # issue was created moments ago by the same run and carries no band —
        # so every write below is the ratchet's own "no current band, apply"
        # branch rather than a skip. The node id carries the slug so a
        # mutation can be attributed to the issue it targeted.
        slug="\${2#repos/}"; slug="\${slug%%/issues/*}"
        num="\${2##*/}"
        jq -c "\$(after --jq || printf '.')" \\
          <<<"{\"node_id\":\"I_\${slug//\\//__}_\${num}\",\"issue_field_values\":[]}" 2>/dev/null
        exit 0
        ;;
      *) printf '[]\n'; exit 0 ;;
    esac
    ;;
  pr) printf '[]\n'; exit 0 ;;
esac
exit 0
STUB
  chmod +x "$dir/stub/gh"

  # The `claude` stub: emits the stream-json envelope `run_model_stage`
  # truncates to `<stage>.out`, carrying whatever result.json holds as the
  # final message's `result` string.
  cat > "$dir/stub/claude" <<STUB
#!/usr/bin/env bash
set -uo pipefail
D='$dir/stub'
cat > "\$D/prompt.txt"
printf '{"type":"system","subtype":"init"}\n'
jq -c -n --rawfile r "\$D/result.json" \\
  '{type: "result", subtype: "success", is_error: false, num_turns: 1,
    total_cost_usd: 0.01, duration_ms: 10, result: \$r}'
exit 0
STUB
  chmod +x "$dir/stub/claude"
  printf '{"status":"complete","report_markdown":"### What is broken now\\n\\nnothing","findings":[],"page_triage":[]}' \
    > "$dir/stub/result.json"
  printf '%s' "$dir"
}

RC=0
run_monitor() {  # run_monitor <dir> [args...] -> prints stdout+stderr, sets RC
  local dir="$1"; shift
  local out
  out="$(env HOME="$dir/home" AGENT_OPS_ROLE=active NODE_NAME="$(basename "$dir")" \
    PATH="$dir/stub:$PATH" LABELS_GH="$dir/stub/gh" CLAIM_GH="$dir/stub/gh" \
    TOGGLE_GH="$dir/stub/gh" \
    timeout 180 "$dir/monitor-cycle.sh" "$@" 2>&1)"
  RC=$?
  printf '%s' "$out"
}

state_of() { printf '%s' "$1/home/.local/state/poetic-agents"; }
report_of() { cat "$(state_of "$1")/monitor/$(date -u +%Y-%m-%d)/report.md" 2>/dev/null || true; }
# `grep -c` prints 0 *and* exits 1 when nothing matches, so a `|| printf 0`
# here would emit two zeroes and every comparison against it would fail while
# looking right.
mutations_of() {
  local n
  n="$(grep -c . "$1/stub/priority-mutations.log" 2>/dev/null)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  printf '%s' "$n"
}
mutation_band_for() {  # mutation_band_for <dir> <node-id-fragment>
  awk -v frag="$2" '$1 ~ frag { print $2 }' "$1/stub/priority-mutations.log" 2>/dev/null | tail -n1
}

BASE='.state_repo = ""
      | .repos = [{slug: "o/target", sources: ["issues:medium", "tech-debt", "abandoned-drafts"]}]
      | .crash_loop_repo = "o/ops"
      | .pager_repo = "o/ops"
      | .enabler_assignee = "someone"'

# ============================================================================
# 1. A mechanical finding files at High (M14a, requirement 1)
# ============================================================================
# `monitor_promote_after = 0` disables promotion, so this run's single filing
# is the mechanical one and nothing else — the band read back is unambiguously
# M14a's.
d="$(make_node mechanical "$BASE | .monitor_promote_after = 0")"
cat > "$d/stub/result.json" <<'EOF'
{"status":"complete",
 "report_markdown":"### What is broken now\n\none mechanical fault\n\n### What limited throughput\n\nnothing\n\n### What is new\n\nnothing\n\n### Pages\n\nnone open",
 "findings":[
   {"key":"banded-fault","class":"mechanical","title":"A mechanical fault","body":"what/why/where/fix","repo":"o/target"}],
 "page_triage":[]}
EOF
out="$(run_monitor "$d" --once)"
assert_eq "the run ends 0" "0" "$RC"
assert_contains "the mechanical finding is filed" "\`banded-fault\` | filed" "$(report_of "$d")"
# The assertion this file exists for: without the lazy-source guard in
# `monitor_create_issue`, `issue_priority_apply` is undefined here and no
# mutation goes out at all, so this reads 0.
assert_eq "its band is actually written — one setIssueFieldValue mutation went out" \
  "1" "$(mutations_of "$d")"
assert_eq "and the band written is High, per M14a" \
  "OPT_HIGH" "$(mutation_band_for "$d" 'o__target')"

# ============================================================================
# 2. A promoted pager-invariant proposal files at Medium (M13a, requirement 1)
# ============================================================================
d="$(make_node promotion "$BASE | .monitor_promote_after = 2")"

# Run 1: an ordinary mechanical finding — the repeat count starts here, and
# this filing is the `High` one again.
cat > "$d/stub/result.json" <<'EOF'
{"status":"complete",
 "report_markdown":"### What is broken now\n\na recurring thing\n\n### What limited throughput\n\nnothing\n\n### What is new\n\nnothing\n\n### Pages\n\nnone",
 "findings":[
   {"key":"repeat-thing","class":"mechanical","title":"A thing that keeps recurring","body":"report one's own evidence","repo":"o/target"}],
 "page_triage":[]}
EOF
out="$(run_monitor "$d" --once)"
assert_eq "run one's mechanical filing bands at High" \
  "OPT_HIGH" "$(mutation_band_for "$d" 'o__target')"

# Run 2: the same key, restated. The threshold is met, so the Script promotes
# it into a pager-invariant proposal in the *pager* repository instead of
# filing the finding again — and that proposal is the `Medium` one.
cat > "$d/stub/result.json" <<'EOF'
{"status":"complete",
 "report_markdown":"### What is broken now\n\nstill the recurring thing\n\n### What limited throughput\n\nnothing\n\n### What is new\n\nnothing\n\n### Pages\n\nnone",
 "findings":[
   {"key":"repeat-thing","class":"mechanical","title":"A thing that keeps recurring","body":"report two's own evidence","repo":"o/target"}],
 "page_triage":[]}
EOF
out="$(run_monitor "$d" --once)"
assert_contains "run two promotes the restated finding" \
  "\`repeat-thing\` | promoted" "$(report_of "$d")"
assert_eq "the promotion's own band is written too" "2" "$(mutations_of "$d")"
assert_eq "and it is Medium, per M13a — tooling work, not a live defect" \
  "OPT_MEDIUM" "$(mutation_band_for "$d" 'o__ops')"

if (( failures )); then
  printf '%d assertion(s) failed\n' "$failures"
  exit 1
fi
printf 'all assertions passed\n'
