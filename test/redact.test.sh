#!/usr/bin/env bash
#
# test/redact.test.sh — regression test for lib/redact.sh's
# `redact_add_literal` (issue #1741): it escapes its `VALUE` argument for the
# *pattern* side of the `s#PATTERN#PLACEHOLDER#g` rule it builds
# (`_redact_escape_literal`), but used to splice `PLACEHOLDER` into the
# *replacement* side verbatim. On the replacement side of a sed `s///`
# command, `&` expands to the matched text, `\` escapes the following
# character, and `#` (this rule set's own delimiter) ends the command early —
# so a caller-supplied placeholder containing any of those would either paste
# the masked secret straight back (`&`) or corrupt the rule and every other
# entry REDACT_SED_ARGS shares with it. This pins the fix
# (`_redact_escape_replacement`) against every shape that matters: a
# placeholder containing each special character, and the unaffected default.
#
# No network, no GitHub. Run directly:
#
#   ./test/redact.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
    printf 'FAIL - %s\n     expected to contain: %s\n     actual:              %s\n' \
      "$desc" "$needle" "$haystack"
    failures=$(( failures + 1 ))
  fi
}

# shellcheck source=lib/redact.sh
. "$SCRIPT_DIR/lib/redact.sh"

# --- a placeholder containing `&` masks literally (criterion 1) -------------
REDACT_SED_ARGS=(-E)
redact_add_literal "supersecret123" "[REDACTED&]"
out="$(printf 'leaked: supersecret123 here\n' | redact)"
assert_eq "a placeholder containing & masks with the literal placeholder" \
  "leaked: [REDACTED&] here" "$out"
assert_contains "…and does not re-insert the matched secret" \
  "[REDACTED&]" "$out"
if [[ "$out" == *supersecret123* ]]; then
  printf 'FAIL - %s\n' "the matched secret must not survive in the output"
  failures=$(( failures + 1 ))
fi

# --- a placeholder containing `\` does not corrupt the rule (criterion 2) ---
REDACT_SED_ARGS=(-E)
redact_add_literal "anothersecret" '[MASKED\X]'
out="$(printf 'value: anothersecret end\n' | redact)"
assert_eq "a placeholder containing a backslash masks literally" \
  'value: [MASKED\X] end' "$out"

# --- a placeholder containing `#` (the rule delimiter) does not corrupt it
# (criterion 2), and a later REDACT_SED_ARGS entry keeps working -------------
REDACT_SED_ARGS=(-E)
redact_add_literal "firstsecret" "[HASH#TAG]"
redact_add_literal "secondsecret" "[SECOND]"
out="$(printf 'one: firstsecret two: secondsecret\n' | redact)"
assert_eq "a placeholder containing # masks literally without ending the rule" \
  "one: [HASH#TAG] two: [SECOND]" "$out"

# --- all three specials together --------------------------------------------
REDACT_SED_ARGS=(-E)
redact_add_literal "combosecret" '[A&B\C#D]'
out="$(printf 'x combosecret y\n' | redact)"
assert_eq "&, backslash and # together all mask literally" \
  'x [A&B\C#D] y' "$out"

# --- default-placeholder call sites are unaffected (criterion 3) -----------
REDACT_SED_ARGS=(-E)
redact_add_literal "webhooksecretvalue"
out="$(printf 'posting to webhooksecretvalue failed\n' | redact)"
assert_eq "the default placeholder is used verbatim, unescaped" \
  "posting to [REDACTED-WEBHOOK] failed" "$out"

# --- an empty value is still a no-op regardless of placeholder --------------
REDACT_SED_ARGS=(-E)
redact_add_literal "" "[A&B]"
assert_eq "an empty value registers no rule even with a special placeholder" \
  "1" "${#REDACT_SED_ARGS[@]}"

printf '\n%s\n' "----------------------------------------"
if (( failures == 0 )); then
  printf 'All assertions passed.\n'
  exit 0
fi
printf '%d assertion(s) failed.\n' "$failures"
exit 1
