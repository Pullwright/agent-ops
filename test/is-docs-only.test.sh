#!/usr/bin/env bash
#
# test/is-docs-only.test.sh — self-contained regression test for
# scripts/is-docs-only.sh, the classifier that lets a documentation-only change
# skip the image build (docs/IMPLEMENTATION-PIPELINE-SPEC.md acceptance check
# 1b).
#
# What is really being pinned here is the direction of the mistakes. Calling
# code "prose" means a change to what a node runs never reaches a node; calling
# prose "code" costs a build nobody needed. So most of the assertions below are
# about the first kind — `prompts/*.md` above all, which are Markdown documents
# and are also the pipeline's operating instructions.
#
# No test framework is used (none exists elsewhere in this repo); this is a
# plain bash script with hand-rolled assertions. Run it directly:
#
#   ./test/is-docs-only.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLASSIFY="$SCRIPT_DIR/scripts/is-docs-only.sh"

failures=0
pass() { printf 'ok   - %s\n' "$1"; }
fail() {
  printf 'FAIL - %s\n' "$1"
  shift
  (( $# )) && printf '     %s\n' "$@"
  failures=$(( failures + 1 ))
}

# Paths as arguments. The stdin form is exercised separately below, on the
# grounds that the workflow uses it and an interactive run uses the other.
assert_docs_only() {
  local desc="$1"; shift
  local out
  if out="$("$CLASSIFY" "$@" 2>/dev/null)"; then
    pass "$desc"
  else
    fail "$desc" "expected documentation-only; it objected to: ${out:-<nothing>}"
  fi
}

assert_not_docs_only() {
  local desc="$1"; shift
  if "$CLASSIFY" "$@" >/dev/null 2>&1; then
    fail "$desc" "expected a build; it called the change documentation-only"
  else
    pass "$desc"
  fi
}

# --- Prose: the whole inert set, each on its own, then together. ---
assert_docs_only "the roadmap is documentation" docs/ROADMAP.md
assert_docs_only "anything nested under docs/ is documentation" docs/notes/adr/0001-thing.md
assert_docs_only "the README is documentation" README.md
assert_docs_only "CLAUDE.md is documentation" CLAUDE.md
assert_docs_only "AGENTS.md is documentation" AGENTS.md
assert_docs_only "TECH-DEBT.md is documentation" TECH-DEBT.md
assert_docs_only "the licence is documentation" LICENCE
assert_docs_only "the node runbook is documentation" deploy/docker/README.md
assert_docs_only "the whole inert set at once is documentation" \
  docs/ROADMAP.md README.md CLAUDE.md AGENTS.md \
  TECH-DEBT.md LICENCE deploy/docker/README.md
assert_not_docs_only "a frozen register item file is not documentation" \
  tech-debt/TD-PPagop-26073101.md

# --- Documents under docs/ that the image delivers to a running stage are
#     code, not prose, however they read to a human: a change to either kind
#     below reaches a node through the image the moment it merges. ---
assert_not_docs_only "the standing decisions file is read at /app by agent-cycle.sh" \
  docs/STANDING-DECISIONS.md
assert_not_docs_only "the implementation pipeline spec's Gotchas feed the Monitor" \
  docs/IMPLEMENTATION-PIPELINE-SPEC.md
assert_not_docs_only "the review pipeline spec's Gotchas feed the Monitor" \
  docs/REVIEW-PIPELINE-SPEC.md
assert_not_docs_only "the monitor pipeline spec's Gotchas feed the Monitor" \
  docs/MONITOR-PIPELINE-SPEC.md
assert_not_docs_only "the dashboard spec's Gotchas feed the Monitor" \
  docs/DASHBOARD-SPEC.md
assert_not_docs_only "a spec-named file nested under docs/ is still code" \
  docs/notes/FOO-SPEC.md

# --- Markdown that is not prose. These are the assertions that matter: each
#     one is a file whose contents change what a node does. ---
assert_not_docs_only "prompts/coordinator.md is the coordinator's code" prompts/coordinator.md
assert_not_docs_only "prompts/implementer.md is the implementer's code" prompts/implementer.md
assert_not_docs_only "prompts/reviewer.md is the reviewer's code" prompts/reviewer.md
assert_not_docs_only "prompts/enabler.md is the enabler's code" prompts/enabler.md
assert_not_docs_only "prompts/project-reviewer.md is the review pipeline's code" \
  prompts/project-reviewer.md
assert_not_docs_only "a test fixture is not documentation" \
  test/fixtures/tech-debt-items-drifted/tech-debt/TD-PPtest-26071501.md
assert_not_docs_only "a repository skill is not documentation" \
  .claude/skills/td/SKILL.md

# --- Everything else that reaches the image, or decides how it is built. ---
assert_not_docs_only "a pipeline is not documentation" agent-cycle.sh
assert_not_docs_only "a library is not documentation" lib/version.sh
assert_not_docs_only "the config is not documentation" config.json
assert_not_docs_only "the Dockerfile is not documentation" deploy/docker/Dockerfile
assert_not_docs_only "the compose file is not documentation" deploy/docker/compose.yaml
assert_not_docs_only "the dashboard page is not documentation" dashboard/index.html
assert_not_docs_only "this very workflow is not documentation" \
  .github/workflows/build-image.yml
assert_not_docs_only "CODEOWNERS is not documentation" CODEOWNERS

# --- Patterns are anchored whole: a path that merely looks like a document's
#     is code, because the allowlist is the only thing standing between a code
#     change and a skipped deployment. ---
assert_not_docs_only "a path that only starts with docs/ is not documentation" \
  docsy/note.md
assert_not_docs_only "a path that only starts with README.md is not documentation" \
  README.mdx
assert_not_docs_only "a README elsewhere in the tree is not documentation" \
  dashboard/README.md
assert_not_docs_only "a spec-like name outside docs/ is not documentation" \
  IMPLEMENTATION-PIPELINE-SPEC.md

# --- One code path among any number of documents still means build. ---
assert_not_docs_only "one script among the documents forces a build" \
  docs/ROADMAP.md README.md lib/model-id.sh TECH-DEBT.md

out="$("$CLASSIFY" docs/ROADMAP.md lib/model-id.sh prompts/reviewer.md 2>/dev/null)"
if [[ "$out" == $'lib/model-id.sh\nprompts/reviewer.md' ]]; then
  pass "it names exactly the paths that forced the build"
else
  fail "it names exactly the paths that forced the build" "actual: ${out//$'\n'/, }"
fi

# --- Silence is never consent: nothing to classify means build. ---
if printf '' | "$CLASSIFY" >/dev/null 2>&1; then
  fail "an empty change is not documentation-only"
else
  pass "an empty change is not documentation-only"
fi

if "$CLASSIFY" </dev/null >/dev/null 2>&1; then
  fail "no arguments and no stdin is not documentation-only"
else
  pass "no arguments and no stdin is not documentation-only"
fi

# --- The stdin form is what the workflow pipes a `git diff` into, and it must
#     agree with the argument form — blank lines and all. ---
if printf 'docs/ROADMAP.md\nREADME.md\n' | "$CLASSIFY" >/dev/null 2>&1; then
  pass "documents on stdin are documentation-only"
else
  fail "documents on stdin are documentation-only"
fi

if printf 'docs/ROADMAP.md\n\nprompts/coordinator.md\n' | "$CLASSIFY" >/dev/null 2>&1; then
  fail "a prompt on stdin forces a build"
else
  pass "a prompt on stdin forces a build"
fi

if printf '\n\n' | "$CLASSIFY" >/dev/null 2>&1; then
  fail "blank lines alone on stdin are not documentation-only"
else
  pass "blank lines alone on stdin are not documentation-only"
fi

# --- The allowlist is only true of the tree it describes: a document that has
#     been moved or renamed leaves an entry matching nothing, and the change
#     that moved it would then be classified by its new path alone. Checked
#     against the filesystem, so it holds in a checkout and inside the image
#     alike (both carry these files; only the checkout carries .git). ---
for doc in README.md CLAUDE.md AGENTS.md TECH-DEBT.md LICENCE deploy/docker/README.md docs; do
  if [[ -e "$SCRIPT_DIR/$doc" ]]; then
    pass "the allowlist's $doc still exists"
  else
    fail "the allowlist's $doc still exists" "it is gone — remove or repoint the entry"
  fi
done

# --- The set of documents the pipeline actually reads at run time, derived
#     from the code rather than hand-maintained here, so the next machine-read
#     document is caught the moment it is added without being classified.
#     "The entry points" means the three top-level cycles the crontab invokes
#     directly (agent-cycle.sh, review-cycle.sh, monitor-cycle.sh); a script
#     under scripts/ that only a human or a schedule other than those three
#     runs is out of scope here, the same way issue #2085 scoped it. ---
derived_docs=()
while IFS= read -r path; do
  [[ -n "$path" ]] && derived_docs+=( "$path" )
done < <(
  grep -hoE '\$SCRIPT_DIR/docs/[A-Za-z0-9_./-]+' \
    "$SCRIPT_DIR/agent-cycle.sh" "$SCRIPT_DIR/review-cycle.sh" "$SCRIPT_DIR/monitor-cycle.sh" \
    "$SCRIPT_DIR"/lib/*.sh 2>/dev/null \
    | sed 's#^\$SCRIPT_DIR/##' \
    | sort -u
)

standing_decisions="$(jq -r '.standing_decisions_file // empty' "$SCRIPT_DIR/config.json" 2>/dev/null)"
[[ -n "$standing_decisions" ]] && derived_docs+=( "$standing_decisions" )

if (( ${#derived_docs[@]} == 0 )); then
  fail "the derived set of run-time-read documents is non-empty" \
    "found none — the grep/jq above no longer matches the code"
else
  pass "the derived set of run-time-read documents is non-empty (${#derived_docs[@]} found)"
fi

for doc in "${derived_docs[@]}"; do
  assert_not_docs_only "the derived run-time document $doc is classified as code" "$doc"
done

echo
if (( failures == 0 )); then
  echo "All is-docs-only assertions passed."
  exit 0
else
  echo "$failures is-docs-only assertion(s) FAILED."
  exit 1
fi
