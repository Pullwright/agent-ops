#!/usr/bin/env bash
#
# scripts/is-docs-only.sh — is this set of changed paths prose and nothing else?
#
# Exit 0 when every path handed to it is one that cannot reach a node through
# the image, and non-zero otherwise, printing the paths that forced the "no" so
# the caller's log says which file cost the build.
#
# `.github/workflows/build-image.yml` asks the question to decide whether a
# change needs an image at all. /app inside the image *is* this repository, so
# very little here is incapable of changing what a node does — but a document
# the image is not the delivery path for cannot, and a change confined to those
# is worth neither a build on a pull request nor an image roll across the fleet
# on `main`.
#
# "Cannot reach a node through the image" is the exact test, and it is not the
# same thing as "nobody reads it". A cycle working on *this* repository does
# read its `CLAUDE.md`, its `AGENTS.md` and its `TECH-DEBT.md` — but out of the
# fresh `gh repo clone` in `workspace_root`, which arrives from GitHub
# the moment a pull request merges, with no image in the path, so no build can
# make it arrive sooner and skipping one delays nothing.
#
# What is never read is *those files'* copy at /app. Every `claude -p` in
# agent-cycle.sh and review-cycle.sh runs with its working directory under
# `workspace_root` or `state_dir` (`assert_in_workspace` pins the first of
# those), so /app is neither a working directory nor an ancestor of one, and
# /app/CLAUDE.md and /app/AGENTS.md are never loaded as project memory.
# Moving a stage's cwd would break that, which is why it is written down here.
#
# The test cuts the other way too, which is why several of the cases below
# carve documents *out* of `docs/`. A file the pipeline opens by path, rather
# than inheriting as project memory, is read from /app and from nowhere
# else: `docs/STANDING-DECISIONS.md` (resolved against `$SCRIPT_DIR` and fed
# to the decide-tactical pass) and the four specification files
# monitor-cycle.sh names for the Monitor's known-signatures Gotchas section.
# Only a build and an image roll deliver a change to any of these, so they
# are code here however they read to a human.
#
# Paths on the command line, or one per line on stdin when there are none, an
# optional leading `--skip-suite-only` asking the narrower question instead:
#
#   git diff --no-renames --name-only main...HEAD | ./scripts/is-docs-only.sh
#   git diff --no-renames --name-only main...HEAD | ./scripts/is-docs-only.sh --skip-suite-only
#
# The inert set is an explicit allowlist of paths, deliberately not a rule
# about file extensions, and that is the whole point of this file. The
# `prompts/*.md` are Markdown documents, and they are also the *code* of the
# coordinator, the implementer and the reviewer — the text fed to `claude -p`
# at each stage. Judging by extension would let a change to how a node thinks
# skip the build that deploys it, which is the one failure this must not have.
# `test/fixtures/*.md` and `.claude/skills/**` are Markdown for the same
# not-prose reason.
#
# So anything not named below counts as code. Adding a document is one line
# here, and forgetting to add it costs a build nobody needed — the cheap side
# of the mistake, against a deployment nobody got.
#
# It fails safe in one direction only: no paths at all — an empty diff, or a
# caller that could not work out what changed — is "not documentation-only",
# because "may we skip the build?" must never be answered yes by silence.
#
# `--skip-suite-only` asks a narrower question: does this set of paths need
# the in-image `test/` suite run at all? A path the image delivers to a
# running stage is still code (`is_inert` says so), but `docs/
# STANDING-DECISIONS.md` is read by no test — see is_suite_exempt below for
# which, and why — so a change confined to that file and the inert set still
# needs a build and a publish, just not the ~40 minutes the suite spends
# proving nothing a changed STANDING-DECISIONS.md could break. The four
# specification files stay off this list on purpose: test/monitor-digest.test.sh
# reads their real `## Gotchas` sections, so a change to one of those can
# fail a test and must still run the suite.

set -uo pipefail

mode=inert
if [[ "${1:-}" == --skip-suite-only ]]; then
  mode=skip-suite-only
  shift
fi

# Every pattern anchored whole, so `README.mdx` and `docsy/note.md` are code.
is_inert() {
  case "$1" in
    docs/STANDING-DECISIONS.md) return 1 ;;  # agent-cycle.sh resolves standing_decisions_file against $SCRIPT_DIR (/app in the image) and lib/escalation-autonomy.sh feeds it to decide-tactical as precedents
    # monitor-cycle.sh reads each of these four from $SCRIPT_DIR/docs as the
    # Monitor's own known-signatures Gotchas sections (#2094 split what was
    # four flat docs/*-SPEC.md files into these four paths; a split file
    # these four don't name, e.g. a sibling requirements/*.md, is read only
    # from a fresh clone and is not listed here).
    docs/spec/implementation/gotchas.md) return 1 ;;
    docs/spec/review/README.md) return 1 ;;
    docs/spec/monitor.md) return 1 ;;
    docs/spec/dashboard/README.md) return 1 ;;
    docs/*) return 0 ;;                   # the roadmap and the rest of docs/, read only from a fresh clone
    README.md) return 0 ;;
    CLAUDE.md) return 0 ;;                # a cycle reads the clone's copy, never /app's
    AGENTS.md) return 0 ;;                # likewise
    TECH-DEBT.md) return 0 ;;             # likewise
    LICENCE) return 0 ;;
    deploy/docker/README.md) return 0 ;;  # the node runbook
    site/*) return 0 ;;                   # the public documentation site's own toolchain (#2100) — .dockerignore keeps it out of the image, and .github/workflows/docs-site.yml builds and deploys it on its own, independent of build-image.yml
    *) return 1 ;;
  esac
}

# Paths that reach a node through the image (so is_inert alone calls them
# code), but whose content no test exercises — only consulted under
# --skip-suite-only, never for the docs_only question above. docs/
# STANDING-DECISIONS.md is the only member: test/escalation-autonomy.test.sh
# feeds enabler_decide_precedents a fixture of its own rather than this
# file's real content, and nothing else under test/ reads it at all (the
# guard in test/is-docs-only.test.sh is what keeps that true).
is_suite_exempt() {
  case "$1" in
    docs/STANDING-DECISIONS.md) return 0 ;;
    *) is_inert "$1" ;;
  esac
}

paths=( "$@" )
if (( ${#paths[@]} == 0 )); then
  while IFS= read -r line; do
    [[ -n "$line" ]] && paths+=( "$line" )
  done
fi

if (( ${#paths[@]} == 0 )); then
  echo "is-docs-only: no paths given — treating the change as not documentation-only" >&2
  exit 1
fi

status=0
for path in "${paths[@]}"; do
  if [[ "$mode" == skip-suite-only ]]; then
    is_suite_exempt "$path" || { printf '%s\n' "$path"; status=1; }
  else
    is_inert "$path" || { printf '%s\n' "$path"; status=1; }
  fi
done
exit "$status"
