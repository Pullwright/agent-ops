## What does this change do, and why?

## Changelog

<!-- For a type that owes no entry (chore, docs, refactor, test, build, ci,
     style, revert), leave this section as it is or delete it: a section
     holding only this comment counts as absent. A feat, fix or perf title,
     or a breaking change, must fill it: one or more of `### Added`,
     `### Changed`, `### Deprecated`, `### Removed`, `### Fixed` and
     `### Security`, each with `- ` bullets written for this repository's
     changelog audience, or the single line `None.` if the change is not
     notable. The squash merge carries it onto main; the release pull
     request assembles CHANGELOG.md from it, so do not edit that file
     (requirement 25c, D27). -->

## Checklist

- [ ] The PR title follows [Conventional Commits](https://www.conventionalcommits.org/)
      (`<type>[(scope)][!]: <description>`) — squash-merge uses it as the
      commit message on `main`, and CI checks both the title and every
      commit on the branch.
- [ ] If this changes pipeline behaviour, the matching as-built spec under
      `docs/` is updated in this same PR (see `CLAUDE.md`, "As-built
      specifications").
- [ ] Any deferred work or known shortcut is filed as a `pw::type:tech-debt`
      issue and referenced with a `Defers: #n` line, per `TECH-DEBT.md`.
