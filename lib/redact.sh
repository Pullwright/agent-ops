#!/usr/bin/env bash
#
# lib/redact.sh — the token/home-path patterns scripts/publish-dashboard.sh
# and scripts/state-sync.sh both need before they hand content to a
# less-trusted destination: the dashboard's own published payload (a
# semi-public, Tailscale-exposed surface) and whatever this node pushes to
# the private state-mirror repository (agent-ops#966) — the second
# destination is lower-risk than the first, but carries far more raw
# content (whole transcripts, never rotated), so it gets the same pass
# rather than none at all.
#
# One pattern set in one place: a shape added here to catch a new secret
# reaches both call sites the same day, instead of whichever one someone
# remembers to edit. Not every secret has a shape a fixed pattern can catch —
# a bearer token carried in a webhook URL's own path is indistinguishable
# from the rest of the URL — so redact_add_literal (agent-ops#1721) lets a
# caller register one runtime-supplied value for masking, additive to the
# shape rules below.

REDACT_SED_ARGS=(
  -E
  -e "s#/home/[A-Za-z0-9._-]+#~#g"
  -e "s#/Users/[A-Za-z0-9._-]+#~#g"
  -e "s#gh[pousr]_[A-Za-z0-9]{16,}#[REDACTED-TOKEN]#g"
  -e "s#github_pat_[A-Za-z0-9_]{20,}#[REDACTED-TOKEN]#g"
  -e "s#sk-(ant-|proj-)?[A-Za-z0-9_-]{16,}#[REDACTED-TOKEN]#g"
  -e "s#(Bearer|token) [A-Za-z0-9._~+/-]{16,}#\1 [REDACTED-TOKEN]#g"
)

# redact — filter stdin to stdout, applying the pattern set above.
redact() {
  sed "${REDACT_SED_ARGS[@]}"
}

# redact_file <path> — apply the same pattern set to a file in place. The
# patterns only ever touch path- and token-shaped substrings, never JSON
# syntax, so a JSON/JSON-Lines file staying parseable after this holds for
# every shape these patterns match.
redact_file() {
  sed -i "${REDACT_SED_ARGS[@]}" "$1"
}

# _redact_escape_literal VALUE — VALUE with every character special to the
# `-E`/`#`-delimited rules above (backslash, the extended-regex
# metacharacters, and `#` itself) backslash-escaped, so it can be dropped
# into an `s#PATTERN#…#g` rule as a literal string match rather than a regex.
_redact_escape_literal() {
  printf '%s' "$1" | sed -e 's/[][\.^$*+?(){}|#]/\\&/g'
}

# redact_add_literal VALUE [PLACEHOLDER] — mask one runtime-supplied secret
# that has no fixed shape the patterns above can match (agent-ops#1721): a
# bearer token carried in a webhook URL's *path*, e.g.
# `https://hooks.slack.com/services/T…/B…/…`, rather than as a `gh*_`/
# `Bearer …`-shaped string. Additive to REDACT_SED_ARGS — the fixed shape
# rules are never touched — and a no-op when VALUE is empty, so a caller can
# register unconditionally without an `if`. Also a no-op when VALUE contains
# a newline: a single `-e "s#PATTERN#…#g"` rule cannot span one (sed reads
# the embedded newline as ending the command mid-pattern, "unterminated `s'
# command"), and REDACT_SED_ARGS is shared by every caller, so one such value
# would break every fixed shape rule above too, not just its own — treated
# like an empty value rather than risk that.
redact_add_literal() {
  local value="$1" placeholder="${2:-[REDACTED-WEBHOOK]}"
  [[ -n "$value" && "$value" != *$'\n'* ]] || return 0
  local escaped
  escaped="$(_redact_escape_literal "$value")"
  REDACT_SED_ARGS+=(-e "s#${escaped}#${placeholder}#g")
}
