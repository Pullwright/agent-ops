---
scope: PPagop
---

# Tech debt

Tech debt in agent-ops is filed as GitHub issues labelled
`pw::type:tech-debt`, resolved by closing the issue with a real closing
keyword (e.g. `Fixes #<n>`) in the pull request that fixes it, alongside a
`td-record` block in that pull request's body — the squash-merge commit
then carries the record into `main`'s own immutable history.

`tech-debt/` is a **frozen historical archive**: every record this
repository ever allocated under its `PPagop` scope while debt was tracked
as a per-item register, before that policy changed. No file is added to it,
deleted from it, or renamed within it, and the only edit any of its files
still takes is the terminal-`status:` frontmatter flip below —
`git log --follow tech-debt/<id>.md` remains each one's audit trail. The
frozen format, ID grammar and scope-code
registry are documented in
[docs/TECH-DEBT-REGISTER.md in Poetic-Poems/poetic](https://github.com/Poetic-Poems/poetic/blob/main/docs/TECH-DEBT-REGISTER.md).

## Resolution and history

An issue migrated from the frozen register — its body's final line reading
"Filed as `tech-debt/<id>.md`, <date>." — still names a permanent record in
that archive. The pull request that resolves such an issue must, in the
same diff and alongside the ordinary closing keyword and `td-record` block,
flip the named file's frontmatter to a terminal state: `status: resolved`,
filling `resolved:` (the date) and `ref:` (this pull request), or
`status: not-debt` for an item the resolution concludes was never debt, with
`ref:` pointing at where the content moved. The body stays in place either
way — never delete or rename an item file, and never flip a resolved item
back; re-opening debt means filing a new issue that references the old one.
`scripts/check-closing-keyword.sh` enforces this mechanically.
