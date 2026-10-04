#!/usr/bin/env bash
#
# scripts/check-docs.sh — five offline checks on the documentation that
# toc.yml and config-table.yml don't make (issue #2088): only the two
# generated regions are gated today, so nothing notices a broken relative
# link, an anchor that no longer exists, a document missing from
# docs/README.md's map, a file past the size budget docs/README.md's "Size
# budget" section fixed, or code/prompts/docs quoting a section that moved.
#
# 1. Links and anchors — every relative Markdown link, and every x-docs
#    link in config.schema.json, resolves to a file (or directory) that
#    exists; where it carries a #fragment, the fragment matches a heading
#    in the target — using the same GitHub anchor-slug formula
#    scripts/render-toc.sh uses (shared via lib/markdown-scan.sh's
#    `gh_slug`, so the two cannot disagree) — or an explicit
#    `<a id="…">`/`<a name="…">` anchor in it, which GitHub resolves a
#    fragment against just as readily. External links
#    (http:/https:/mailto:) are out of scope by design — this check runs
#    offline, with no network.
# 2. The map — every in-scope Markdown document (tracked, excluding
#    test/fixtures/ and the frozen tech-debt/ archive) is named in
#    docs/README.md's "All documents" section, one row per file except a
#    dated `docs/reviews/project-review-*/` directory, which gets one row
#    for the whole directory (docs/README.md's own convention); and every
#    path that section names exists.
# 3. Size — no in-scope document exceeds the 100,000-byte budget
#    docs/README.md's "Size budget" section fixed, unless it is exempt
#    (CHANGELOG.md, docs/reviews/**, docs/ROADMAP.md — the same exemptions
#    that section lists) or it has an entry in scripts/docs-size-ratchet.tsv
#    naming the issue that will bring it under budget. A ratchet entry may
#    only shrink: the check fails if a listed file grows past its own
#    recorded size, or if a file crosses the budget with no entry at all.
# 4. Section citations — a quoted citation of the form `` `path` §
#    "heading" `` (docs/README.md's own convention), `` `path`, "heading"
#    `` or `` path's "heading" `` (the two forms most of this repository's
#    prose actually uses) names a heading that exists in that file. Covers
#    code, prompts, workflows and documents alike.
# 5. As-built phrasing ratchet — counts "previously", "used to", "no
#    longer", "now uses" and "migration completed" (combined) per as-built
#    document — every in-scope document except records, decision logs and
#    the changelog, which AGENTS.md's documentation principles exempt from
#    the as-built rule outright. Checked against
#    scripts/docs-phrasing-ratchet.tsv, which the count may fall below but
#    never rise past: not a ban (the standing decision of 2026-09-04, #1154,
#    allows a historical aside that passes the deletion test), a ratchet.
#
# With no arguments, or with --check (accepted for symmetry with
# render-toc.sh's and render-config-table.sh's own --check contract), runs
# all five; there is nothing here to render, so both forms do the same
# thing. Prints one diagnostic line per violation to stderr and exits
# non-zero if any check failed.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 1

usage() {
  echo "usage: $(basename "$0") [--check]" >&2
  exit 2
}

case "${1:-}" in
  --check) shift ;;
  "") ;;
  *) usage ;;
esac
if (( $# > 0 )); then
  usage
fi

# shellcheck source=lib/markdown-scan.sh
. "$repo_root/lib/markdown-scan.sh"

SIZE_RATCHET="scripts/docs-size-ratchet.tsv"
PHRASING_RATCHET="scripts/docs-phrasing-ratchet.tsv"
SIZE_BUDGET_BYTES=100000

failed=0
note() { printf 'check-docs: %s\n' "$*"; }
fail() { printf 'check-docs: %s\n' "$*" >&2; failed=1; }

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

# explicit_anchor_ids FILE
# Print the id of every explicit HTML anchor in FILE, one per line, outside
# fenced code. A document whose heading slug is not the anchor it wants to be
# linked by writes one immediately above the heading — `docs/concepts/
# glossary.md` carries `<a id="human-level"></a>` over a heading that slugs to
# `human-merge-autonomy-level` — and GitHub resolves a `#fragment` against it
# exactly as it does against a heading slug. A fragment check that read only
# headings would call those working links broken.
explicit_anchor_ids() {
  markdown_unfenced "$1" | awk '
    {
      line = $0
      while (match(line, /<a[ \t]+(id|name)[ \t]*=[ \t]*"[^"]+"/)) {
        span = substr(line, RSTART, RLENGTH)
        sub(/^[^"]*"/, "", span)   # leading `<a id="`, up to the first quote
        sub(/"$/, "", span)
        print span
        line = substr(line, RSTART + RLENGTH)
      }
    }'
}

# ensure_heading_cache FILE
# Populates SLUG_CACHE[FILE] / HEADING_TEXT_CACHE[FILE] on first reference,
# a file cited by dozens of links or citations (every key's README.md
# anchor, for one) would otherwise re-scan and re-slug it once per
# reference — fine for a single lookup, but README.md alone carries close
# to 200. Must be called as a plain statement, never substituted
# (`x="$(ensure_heading_cache f)"`) — command substitution forks a
# subshell, and the cache assignment below would die with it, silently
# turning every call back into a cache miss.
declare -A SLUG_CACHE=()
declare -A HEADING_TEXT_CACHE=()

ensure_heading_cache() {
  local file="$1"
  if [[ -z "${HEADING_TEXT_CACHE[$file]+x}" ]]; then
    HEADING_TEXT_CACHE["$file"]="$(markdown_heading_texts "$file")"
    # Heading slugs and explicit anchor ids together: both are things a
    # `#fragment` legitimately resolves to on GitHub. Only SLUG_CACHE gets the
    # anchors — HEADING_TEXT_CACHE feeds the citation check, which is about
    # headings alone.
    SLUG_CACHE["$file"]="$(markdown_heading_slugs "$file"; explicit_anchor_ids "$file")"
  fi
}

# Tracked Markdown files this repository's documentation conventions govern:
# every tracked *.md except the fixtures this test suite itself builds to
# break these checks, and tech-debt/'s frozen, never-edited archive
# (AGENTS.md, "Tech debt").
in_scope_md_files() {
  git ls-files '*.md' | grep -v '^test/fixtures/' | grep -v '^tech-debt/'
}

# True for a path inside one of the dated project-review subdirectories,
# which docs/README.md's map covers with one directory entry rather than a
# row per file.
in_project_review_subdir() {
  case "$1" in
    docs/reviews/project-review-*/*) return 0 ;;
    *) return 1 ;;
  esac
}

# A frozen, point-in-time record — docs/README.md's own "Records" and
# "Audits and investigations" sections: "Never updated after filing; new
# findings go in a new record." check_links and check_citations both skip
# these as citing files: a link or citation that drifted since filing is
# left exactly as filed, not fixed to satisfy a check written after the
# fact.
is_frozen_record() {
  case "$1" in
    docs/reviews/*) return 0 ;;
    docs/PHASE-1-POETIC-SPECIFICS-AUDIT.md|docs/VOCABULARY-SWEEP-679-AUDIT.md) return 0 ;;
    docs/PULLWRIGHT-DAY-ONE-AUTONOMY.md|docs/PULLWRIGHT-REHOMING.md) return 0 ;;
    docs/PROVIDER-SEAM-AUDIT.md) return 0 ;;
    *) return 1 ;;
  esac
}

# Extract every `[text](target)` span from stdin, one per line, in order.
extract_md_links() {
  awk '
    {
      line = $0
      while (match(line, /\[[^]]*\]\([^)]*\)/)) {
        print substr(line, RSTART, RLENGTH)
        line = substr(line, RSTART + RLENGTH)
      }
    }'
}

# The target inside a `[text](target)` span.
link_target() {
  local link="$1" target
  target="${link#*](}"
  target="${target%)}"
  echo "$target"
}

# ---------------------------------------------------------------------------
# Check 1: links and anchors
# ---------------------------------------------------------------------------

link_is_external_or_placeholder() {
  case "$1" in
    http://*|https://*|mailto:*|//*) return 0 ;;
    *'<'*) return 0 ;;  # a prose placeholder, e.g. `#extended-notes-<slug>`
    *) return 1 ;;
  esac
}

check_link_target() {
  local citing_file="$1" target="$2" path frag resolved

  link_is_external_or_placeholder "$target" && return 0
  [[ -z "$target" ]] && return 0

  if [[ "$target" == *#* ]]; then
    path="${target%%#*}"
    frag="${target#*#}"
  else
    path="$target"
    frag=""
  fi

  if [[ -z "$path" ]]; then
    resolved="$citing_file"
  else
    resolved="$(realpath -m "$(dirname "$citing_file")/$path" 2>/dev/null)"
    resolved="${resolved#"$repo_root"/}"
  fi

  if [[ ! -e "$resolved" ]]; then
    fail "$citing_file: link target '$target' does not resolve (no such file $resolved)"
    return 1
  fi

  if [[ -n "$frag" && -f "$resolved" ]]; then
    # Matched against a completed string, never piped straight into
    # `grep -q`, which can exit on its first match before the producer
    # finishes writing, SIGPIPE-ing it into a false failure under
    # `set -o pipefail`.
    ensure_heading_cache "$resolved"
    if ! grep -qxF "$frag" <<< "${SLUG_CACHE[$resolved]}"; then
      fail "$citing_file: link '$target' fragment #$frag has no matching heading or anchor in $resolved"
      return 1
    fi
  fi
  return 0
}

check_links_in_file() {
  local file="$1" ok=1 link target
  while IFS= read -r link; do
    [[ -n "$link" ]] || continue
    target="$(link_target "$link")"
    check_link_target "$file" "$target" || ok=0
  done < <(markdown_unfenced "$file" | extract_md_links)
  return $(( ! ok ))
}

schema_x_docs_strings() {
  jq -r '[.. | objects | select(has("x-docs")) | .["x-docs"]] | .. | strings' config.schema.json
}

check_links_in_schema() {
  local ok=1 link target frag combined_slugs
  combined_slugs="$(mktemp)"
  {
    markdown_heading_slugs README.md
    explicit_anchor_ids README.md
    markdown_heading_slugs docs/IMPLEMENTATION-PIPELINE-SPEC.md
    explicit_anchor_ids docs/IMPLEMENTATION-PIPELINE-SPEC.md
    markdown_heading_slugs docs/REVIEW-PIPELINE-SPEC.md
    explicit_anchor_ids docs/REVIEW-PIPELINE-SPEC.md
  } | sort -u > "$combined_slugs"

  while IFS= read -r link; do
    [[ -n "$link" ]] || continue
    target="$(link_target "$link")"
    link_is_external_or_placeholder "$target" && continue
    if [[ "$target" == "#"* ]]; then
      frag="${target#\#}"
      if ! grep -qxF "$frag" "$combined_slugs"; then
        fail "config.schema.json: x-docs link '$target' has no matching heading or anchor in README.md or the specs it renders into"
        ok=0
      fi
    elif [[ -n "$target" ]]; then
      # Not fragment-only: resolve exactly as an ordinary link from the repo
      # root (x-docs text carries no path-only links today, but a future one
      # would still need its target file, and any #fragment on it, checked).
      check_link_target "config.schema.json" "$target" || ok=0
    fi
  done < <(schema_x_docs_strings | extract_md_links)

  rm -f "$combined_slugs"
  return $(( ! ok ))
}

check_links() {
  local ok=1 f
  while IFS= read -r f; do
    is_frozen_record "$f" && continue
    check_links_in_file "$f" || ok=0
  done < <(in_scope_md_files)
  check_links_in_schema || ok=0
  (( ok )) && note "links and anchors: ok"
  return $(( ! ok ))
}

# ---------------------------------------------------------------------------
# Check 2: the map
# ---------------------------------------------------------------------------

check_map() {
  local ok=1 f mapped d
  mapped="$(mktemp)"
  awk '
    match($0, /^\| `[^`]+`/) {
      s = $0
      sub(/^\| `/, "", s)
      sub(/`.*/, "", s)
      print s
    }' docs/README.md | sort -u > "$mapped"

  while IFS= read -r f; do
    in_project_review_subdir "$f" && continue
    if ! grep -qxF "$f" "$mapped"; then
      fail "docs/README.md: $f is not listed in the documentation map"
      ok=0
    fi
  done < <(in_scope_md_files)

  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    if ! grep -qxF "$d" "$mapped"; then
      fail "docs/README.md: $d has no directory entry in the documentation map"
      ok=0
    fi
  done < <(git ls-files 'docs/reviews/project-review-*' | awk -F/ 'NF>=3 {print $1"/"$2"/"$3"/"}' | sort -u)

  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if [[ ! -e "$f" ]]; then
      fail "docs/README.md: mapped path $f does not exist"
      ok=0
    fi
  done < "$mapped"

  rm -f "$mapped"
  (( ok )) && note "the map: ok"
  return $(( ! ok ))
}

# ---------------------------------------------------------------------------
# Check 3: size budget
# ---------------------------------------------------------------------------

is_size_exempt() {
  case "$1" in
    CHANGELOG.md|docs/ROADMAP.md) return 0 ;;
    docs/reviews/*) return 0 ;;
    *) return 1 ;;
  esac
}

check_size() {
  local ok=1 f bytes rpath rbytes rissue
  declare -A ratchet_bytes=() ratchet_issue=()
  while IFS=$'\t' read -r rpath rbytes rissue; do
    [[ -z "$rpath" || "$rpath" == \#* ]] && continue
    ratchet_bytes["$rpath"]="$rbytes"
    ratchet_issue["$rpath"]="$rissue"
  done < "$SIZE_RATCHET"

  while IFS= read -r f; do
    is_size_exempt "$f" && continue
    bytes=$(wc -c < "$f")
    (( bytes <= SIZE_BUDGET_BYTES )) && continue
    if [[ -n "${ratchet_bytes[$f]+x}" ]]; then
      if (( bytes > ratchet_bytes[$f] )); then
        fail "$f: $bytes bytes, grew past its $SIZE_RATCHET entry of ${ratchet_bytes[$f]} bytes (tracked by #${ratchet_issue[$f]}) — a ratchet entry may only shrink"
        ok=0
      fi
    else
      fail "$f: $bytes bytes exceeds the ${SIZE_BUDGET_BYTES}-byte size budget and has no entry in $SIZE_RATCHET"
      ok=0
    fi
  done < <(in_scope_md_files)

  (( ok )) && note "size budget: ok"
  return $(( ! ok ))
}

# ---------------------------------------------------------------------------
# Check 4: section citations
# ---------------------------------------------------------------------------

# flatten_paragraphs [STRIP_COMMENT_MARKER]
# Join each paragraph's soft-wrapped lines into one line, so a citation split
# across a line break (common — this repository wraps prose at ~78 columns)
# still matches as one span. Each line is trimmed before joining: an indented
# continuation (a list item, a blockquote) would otherwise leave its own
# leading spaces embedded mid-paragraph, turning one space into several.
# With STRIP_COMMENT_MARKER set, also strips one leading `#` (plus at most
# one following space) per line first — a shell or YAML comment block is a
# paragraph of lines each independently prefixed with `# `, and without this
# a citation split across two such lines would carry a stray `#` where the
# second line's marker fell in the middle of the joined text.
flatten_paragraphs() {
  local strip_hash="${1:-0}"
  awk -v strip_hash="$strip_hash" '
    {
      line = $0
      gsub(/^[ \t]+/, "", line)
      gsub(/[ \t]+$/, "", line)
      if (strip_hash && line ~ /^#/) { sub(/^#[ \t]?/, "", line) }
      if (line == "") {
        if (para != "") { print para; para = "" }
      } else if (para == "") {
        para = line
      } else if (para ~ /-$/) {
        # A trailing hyphen is always a mid-word wrap in this corpus (clause
        # breaks use an em dash, never a bare "-"), most often a hyphenated
        # filename like FLOW-SCHEMA.md split right at its own hyphen — so no
        # space is inserted, unlike an ordinary word-wrap join.
        para = para line
      } else {
        para = para " " line
      }
    }
    END { if (para != "") print para }'
}

extract_citation_spans() {
  # The path token requires a `.md` extension, not just filename-safe
  # characters: two things this corpus does that a bare extension match
  # would mistake for a citation otherwise — a bare number followed by
  # `, "next field"` in a JSON test fixture (`"duration_ms": 5, "num_turns":
  # 5`), and prose naming a literal string a script uses, e.g.
  # `review-cycle.sh`'s "an implementation cycle is running" reason code
  # (docs/FLOW-SCHEMA.md) — a real citation, by contrast, only ever points
  # at a Markdown document, because only one has headings to name.
  awk '
    {
      line = $0
      while (match(line, /`?[A-Za-z0-9_.\/-]+\.md`?([ \t]{0,3}§[ \t]{0,3}|,[ \t]{0,3}|'"'"'s[ \t]{0,3})"[^"]+"/)) {
        print substr(line, RSTART, RLENGTH)
        line = substr(line, RSTART + RLENGTH)
      }
    }'
}

# normalize_citation_text TEXT
# Lower-cases and strips backticks, so a citation's `code formatting` around
# a bare name never has to match the target heading's own, and a routine
# case difference ("Item lifecycle record" quoting a heading that actually
# reads "The item lifecycle record") never counts as drift.
normalize_citation_text() {
  local text="${1//\`/}"
  printf '%s' "${text,,}"
}

# citation_matches_heading CITATION HEADING
# True when CITATION plausibly names HEADING, both normalized first: exact,
# exact after stripping HEADING's own leading "the "/"a "/"an " (a citation
# routinely drops it to read naturally inside a sentence), or CITATION is a
# prefix of either form (a citation routinely stops before a heading's own
# parenthetical or em-dash suffix — "Output" for a heading "Output — your
# entire final message").
citation_matches_heading() {
  local citation heading heading_norm
  citation="$(normalize_citation_text "$1")"
  heading="$(normalize_citation_text "$2")"
  heading_norm="$heading"
  case "$heading_norm" in
    "the "*) heading_norm="${heading_norm#the }" ;;
    "a "*) heading_norm="${heading_norm#a }" ;;
    "an "*) heading_norm="${heading_norm#an }" ;;
  esac
  [[ "$citation" == "$heading" || "$citation" == "$heading_norm" ]] && return 0
  [[ "$heading" == "$citation"* || "$heading_norm" == "$citation"* ]] && return 0
  return 1
}

any_heading_matches() {
  local citation="$1" headings="$2" h
  while IFS= read -r h; do
    [[ -n "$h" ]] || continue
    citation_matches_heading "$citation" "$h" && return 0
  done <<< "$headings"
  return 1
}

# ensure_body_cache FILE
# Populates BODY_CACHE[FILE] with the path to a scratch copy of its whole
# unfenced, lower-cased, backtick-stripped text on first reference, for
# citation_in_body's fallback search. A scratch *file*, not a bash
# variable: `[[ "$bigstring" == *"$needle"* ]]` on a multi-megabyte string
# (docs/IMPLEMENTATION-PIPELINE-SPEC.md alone unfences to 2.3 MB) measured
# well over a minute per call — bash's own glob matching has no fast
# substring path the way `grep -F` does. Same subshell caveat as
# ensure_heading_cache: call as a plain statement, never substituted.
declare -A BODY_CACHE=()
BODY_CACHE_DIR="$(mktemp -d)"
trap 'rm -rf "$BODY_CACHE_DIR"' EXIT

ensure_body_cache() {
  local file="$1" out
  [[ -n "${BODY_CACHE[$file]+x}" ]] && return
  out="$BODY_CACHE_DIR/$(echo "$file" | tr '/' '_').txt"
  markdown_unfenced "$file" | tr '[:upper:]' '[:lower:]' | tr -d '`' | sed 's/\\|/|/g' > "$out"
  BODY_CACHE["$file"]="$out"
}

# citation_in_body CITATION FILE
# True when CITATION's normalized text appears verbatim in FILE at all —
# not only as a heading. This repository's own citation style quotes
# plenty of things that are not headings: a bullet ("state the constraint"
# — a checklist item, not a heading), a named panel set in bold prose
# ("Revert rate by repository"), a field name. docs/README.md's own "How
# sections are cited" documents the strict path+heading form, but a
# citation that accurately quotes real, current text failing this check
# would be a false positive the strict form never anticipated — so a
# citation that is not a heading match falls back to this wider, still
# meaningful search: the quoted text genuinely still exists in the file.
# Matched with `grep -F` across the whole cached file at once (a citation
# can itself span what were two source lines before flatten_paragraphs
# joined them), never anchored to one line.
citation_in_body() {
  local citation
  citation="$(normalize_citation_text "$1")"
  ensure_body_cache "$2"
  tr '\n' ' ' < "${BODY_CACHE[$2]}" | grep -qF -- "$citation"
}

check_citations_in_file() {
  local file="$1" ok=1 span before path heading strip_hash=0
  case "$file" in
    *.sh|*.yml|*.yaml) strip_hash=1 ;;
  esac
  while IFS= read -r span; do
    [[ -n "$span" ]] || continue
    before="${span%%\"*}"
    # shellcheck disable=SC2016  # \1 is sed's own backreference, not a shell expansion.
    path="$(printf '%s' "$before" | sed -E 's/^`?([A-Za-z0-9_.\/-]+)`?.*$/\1/')"
    heading="${span#*\"}"
    heading="${heading%\"}"
    [[ -z "$path" || -z "$heading" ]] && continue
    # Prose in this repository routinely drops a doc's `docs/` directory
    # when the surrounding sentence already made the directory obvious —
    # tried bare first, since that is what the citation actually said.
    if [[ ! -f "$path" && -f "docs/$path" ]]; then
      path="docs/$path"
    fi
    if [[ ! -f "$path" ]]; then
      fail "$file: cites $path § \"$heading\" but $path does not exist"
      ok=0
      continue
    fi
    ensure_heading_cache "$path"
    if ! any_heading_matches "$heading" "${HEADING_TEXT_CACHE[$path]}" && ! citation_in_body "$heading" "$path"; then
      fail "$file: cites $path § \"$heading\" but that heading does not exist in $path"
      ok=0
    fi
  done < <(markdown_unfenced "$file" | flatten_paragraphs "$strip_hash" | extract_citation_spans)
  return $(( ! ok ))
}

check_citations() {
  local ok=1 f
  while IFS= read -r f; do
    is_frozen_record "$f" && continue
    check_citations_in_file "$f" || ok=0
  done < <(git ls-files '*.md' '*.sh' '*.yml' '*.yaml' \
    | grep -v '^test/fixtures/' \
    | grep -v '^tech-debt/' \
    | grep -v '^test/.*\.test\.sh$')  # a test's own heredoc fixtures are synthetic, not prose to check
  (( ok )) && note "section citations: ok"
  return $(( ! ok ))
}

# ---------------------------------------------------------------------------
# Check 5: as-built phrasing ratchet
# ---------------------------------------------------------------------------

is_as_built() {
  case "$1" in
    CHANGELOG.md) return 1 ;;
    docs/ROADMAP.md|docs/STANDING-DECISIONS.md) return 1 ;;
    *) ! is_frozen_record "$1" ;;
  esac
}

count_phrases_in_file() {
  markdown_unfenced "$1" | tr '[:upper:]' '[:lower:]' | awk '
    BEGIN {
      n = split("previously|used to|no longer|now uses|migration completed", phrases, "|")
      total = 0
    }
    {
      for (p = 1; p <= n; p++) {
        pat = phrases[p]
        pos = 1
        while ((idx = index(substr($0, pos), pat)) > 0) {
          total++
          pos += idx + length(pat) - 1
        }
      }
    }
    END { print total }'
}

check_phrasing() {
  local ok=1 f count rpath rcount
  declare -A ratchet_count=()
  while IFS=$'\t' read -r rpath rcount; do
    [[ -z "$rpath" || "$rpath" == \#* ]] && continue
    ratchet_count["$rpath"]="$rcount"
  done < "$PHRASING_RATCHET"

  while IFS= read -r f; do
    is_as_built "$f" || continue
    in_project_review_subdir "$f" && continue
    count=$(count_phrases_in_file "$f")
    (( count == 0 )) && continue
    if [[ -n "${ratchet_count[$f]+x}" ]]; then
      if (( count > ratchet_count[$f] )); then
        fail "$f: as-built phrasing count rose from ${ratchet_count[$f]} to $count in $PHRASING_RATCHET — a ratchet entry may only fall"
        ok=0
      fi
    else
      fail "$f: as-built phrasing count is $count but has no entry in $PHRASING_RATCHET"
      ok=0
    fi
  done < <(in_scope_md_files)

  (( ok )) && note "as-built phrasing ratchet: ok"
  return $(( ! ok ))
}

# ---------------------------------------------------------------------------

check_links || failed=1
check_map || failed=1
check_size || failed=1
check_citations || failed=1
check_phrasing || failed=1

exit "$failed"
