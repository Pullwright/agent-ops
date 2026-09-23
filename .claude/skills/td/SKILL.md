---
name: td
description: >-
  Launch an agent to work on a single tech-debt item. Use when the user
  invokes /td <n> — it resolves the pw::type:tech-debt-labelled GitHub issue
  numbered <n> and hands it to a subagent to fix. Searches every repo
  attached to the session (workspace-aware), resolving against origin/main
  via `gh issue view`; if <n> matches such an issue in more than one repo,
  matches none, or is missing/invalid, stop and ask rather than guessing.
---

# Work a tech-debt item (/td)

Parse `/td <n>`. `<n>` is a GitHub issue number. Resolve it to **exactly
one** open, `pw::type:tech-debt`-labelled issue in **exactly one** repo, then
hand that issue to a subagent to fix. Never assume which item is meant when
the result is anything other than a single clean match.

Issue numbers are only unique within one repository: sister repos each
number their own issues from 1, so the same `<n>` can name different items —
or no item at all — in different repos. A match is therefore a **(repo,
issue)** pair, and ambiguity across repos is still ambiguity.

## 1. Determine the candidate repos

- If the session's working directory is inside a git repo and no other repos
  are attached to the session, the candidate set is just that repo.
- Otherwise (a multi-repo workspace: the cwd is not inside a git repo, or the
  session has several working directories), the candidates are every session
  working directory that is a git repo, plus every immediate child directory
  of each working directory that is a git repo.

De-duplicate by `git remote get-url origin` — workspaces often hold more than
one checkout of the same repo; resolve each origin only once.

## 2. Resolve the number to one issue

In each candidate repo, fetch first — never trust a possibly stale local
checkout for the repo slug — then query GitHub's own state directly, rather
than the local checkout, for the issue itself:

```bash
git -C <repo> fetch -q origin main
gh issue view <n> --repo <owner>/<repo> --json number,title,body,labels,state
```

(`<owner>/<repo>` comes from that repo's `origin` remote.) Keep a result only
if `state` is `OPEN` and `labels` includes `pw::type:tech-debt`; anything
else (not found, closed, unlabelled) is not a match in that repo. Collect
every match across all candidate repos as (repo, issue) pairs, then branch:

- **Exactly one (repo, issue) pair.** Proceed to step 3 with that issue and
  its repo.
- **More than one pair** — matches in more than one repo (the same `<n>`
  happens to name a qualifying issue in each). Ambiguous — do NOT pick one.
  Stop and list every match as `<repo> — #<n> — <title>`, and ask the user
  which one they mean. Do not launch an agent.
- **No matches in any repo.** `<n>` did not resolve to an open
  `pw::type:tech-debt` issue in any candidate repo. Stop, say so, and suggest
  the user check the issue number and its labels. Do not launch an agent.
- **Invalid or missing argument** (not a positive integer, or `/td` invoked
  with no argument at all). Stop and ask the user for a valid issue number.
  Do not launch an agent.

## 3. Launch an agent to fix the resolved issue

Once — and only once — a single (repo, issue) is resolved, launch a
`general-purpose` agent to do the work; the agent should be appropriately
spec'd: not too costly yet capable enough to (most likely) do the task
correctly on its first attempt. Put the resolved repo (its `origin` URL) and
the issue's `number`, `title`, and `body` verbatim into its prompt so it has
the full description and the suggested fix, and instruct it to:

1. Make its own dedicated fresh clone of the resolved repo's `origin/main`
   and work only in that clone — never in a checkout shared with the user or
   another agent. Then read that repo's `AGENTS.md` first (its `CLAUDE.md`
   imports it) and follow its conventions (Conventional Commits, the
   changelog rule — D27's `## Changelog` section of the pull-request
   description, or the file's `[Unreleased]` entry where that file still
   says so — the as-built-docs policy, and the tech-debt policy).
2. Before doing anything else, check the issue isn't already being worked:
   skim open pull requests for its number (e.g. `gh pr list --repo
   <owner>/<repo> --search "Fixes #<n>" --state open`). If it looks already
   claimed, stop and report that instead of duplicating work. Otherwise
   create an ordinary feature branch (no special naming requirement — there
   is no claim-branch lock to observe) and open a **draft** pull request
   right away, before implementing, so the claim is visible to anyone else
   scanning open PRs; comment on the issue linking the draft PR.
3. Implement the fix described in the issue's `body`, pushing commits to the
   branch/PR as the work progresses.
4. Run the relevant checks for the area it touched, as that repo's
   `AGENTS.md` lists them (for agent-ops: `./scripts/run-tests.sh`, and
   `scripts/lint-shell.sh` for any `*.sh` touched).
5. Record the changelog entry as that repo's documentation principles
   direct. Under D27 (the file says the entry lives in the pull-request
   description): a `## Changelog` section in the PR body — Keep a Changelog
   category sub-headings with bullets, or `None.` for a routine/patch-level
   fix, which a `fix:` title must still say — and no edit to `CHANGELOG.md`.
   Where the file still says to add an `[Unreleased]` entry to
   `CHANGELOG.md`, do that instead (skipping routine/patch-level fixes, per
   that file's own header).
6. On success, close the loop per `AGENTS.md`'s "Tech debt" section: the PR
   body carries a real GitHub closing keyword (e.g. `Fixes #<n>`) naming the
   resolved issue, plus a fenced `td-record` block —

   ```td-record
   issue: <n>
   title: "<the issue's own title, verbatim>"
   filed: <the issue's own creation date, YYYY-MM-DD>
   summary: "<what the debt was, briefly>"
   resolution: "<what this PR did about it>"
   ```

   — so the squash-merge commit writes a permanent record into `main`'s own
   immutable history. There is no register file to edit and no frontmatter to
   flip, unless the issue's own body's final line reads "Filed as
   `tech-debt/<id>.md`, <date>." — a legacy issue migrated from the frozen
   register — in which case this same pull request must also flip that
   file's frontmatter to a terminal `status:` (`TECH-DEBT.md`'s "Resolution
   and history").
7. Before marking the PR ready for review, update its description
   (`gh pr edit <n> --body ...`) to reflect the finished state: replace the
   "This draft PR claims the item..." line (it's no longer a draft) with a
   summary of what was actually implemented, and append the post-implementation
   information a reviewer needs — results of the checks run in step 4 (test/
   build/lint pass or fail), and anything else worth flagging (files touched
   outside the obvious scope, follow-ups left undone, tech-debt entries added).
   Keep the PR title as-is; only the body changes.
8. Push the final commits and mark the draft PR ready for review — per
   `AGENTS.md`'s branch workflow, agents work autonomously up to the PR
   stage without pausing to ask first. If verification fails and the agent
   can't resolve it, close the draft PR and delete the branch (this releases
   the claim), and report what blocked it instead of leaving a stale claim in
   place.

The agent's final message comes back as the tool result and is not shown to the
user, so relay its outcome (what it changed, test results, the PR URL, and
anything it left for the user to decide).
