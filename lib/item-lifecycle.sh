#!/usr/bin/env bash
#
# lib/item-lifecycle.sh — the item-lifecycle record (docs/FLOW-SCHEMA.md,
# requirement 49, issue #595): one durable record per work item, folded from
# the union log's own item-scoped events, ending in an explicit terminal
# fate. A pure derivation, on the same terms `lib/rework.sh`'s `rework_fields`
# and `lib/cycle-state.sh`'s extracts already are — reads the log, touches no
# lock, writes no event.
#
# Reuses `lib/cycle-state.sh`'s own `blocked_items`/`void_items`/
# `draft_obsolete_flags` for the set/clear resolution (a currently-blocked or
# currently-void item, and a flagged-obsolete draft) rather than re-deriving
# that logic a second time — the drift requirement 34a already warns against,
# generalised here to a third reader. Callers must source `lib/cycle-state.sh`
# before this file; production always does (agent-cycle.sh sources every
# lib/*.sh file, requirement 4a), and `test/item-lifecycle.test.sh` sources it
# explicitly.
#
# Sourced, never executed: no shell options are set here, matching every
# other lib/*.sh — the caller owns those.

# The {repo, item} join key, identical to every other reader of this log
# (lib/cycle-state.sh, scripts/pickup-metrics.sh): item coerced with
# `tostring` so a numeric and a string item id are the same key.
# shellcheck disable=SC2016  # jq's own def, not the shell's.
ITEM_LIFECYCLE_KEY_JQ='
  def item_key: ((.repo // "") | tostring) + "|" + ((.item // "") | tostring);
'

# The first-seen -> selection pairing `scripts/pickup-metrics.sh` originally
# derived inline (TD-PPagop-26081405, issue #248 acceptance 4), moved here so
# it is one fold with one set of readers rather than a copy kept in sync by
# hand. Unchanged in substance from pickup-metrics.sh's own prior version:
# first-wins-by-ts per {repo, item}, a bootstrap-flagged first-seen excluded
# from the latency sample but still counted, and an unpaired half reported
# under `coverage` rather than silently shrinking the count.
#
# requirement 54 (issue #613): a paired item whose `first-seen` carries
# `forge_created_at` (lib/candidate-select.sh's `emit_first_seen`, set when
# the source's own candidate has a `created_at`) additionally contributes to
# `pickup_latency_forge_anchored` — the same fleet/by_node shape as
# `pickup_latency`, but the gap from the forge's own creation timestamp to
# `selection`, not from this fleet's own poll-driven `first-seen`. The two
# are deliberately separate fields, never blended into one: `pickup_latency`
# answers "how long since this fleet noticed", which a poll-driven wake
# necessarily shortens by moving `first-seen` earlier; `pickup_latency_
# forge_anchored` answers "how long since the item actually appeared on the
# forge", which is what a wake mechanism's own improvement has to be judged
# against (wake-poll's own header explains why the first figure cannot).
# `coverage.forge_anchored` counts how many paired items had a usable
# `forge_created_at` — most sources have none yet, so this starts well below
# `coverage.paired` and is not a defect. `try … catch null` guards the one
# field whose value crosses a trust boundary (an external `created_at`
# string, not this pipeline's own `ts`): a single malformed value degrades
# that one item's forge measurement to uncounted, never aborts the whole
# fold the way an unguarded `fromdateiso8601` failure would (jq errors here
# are not local — see the ITEM_LIFECYCLE_FOLD_JQ comment below on the same
# risk).
# shellcheck disable=SC2016  # jq's own $since/$all/etc, not the shell's.
ITEM_LIFECYCLE_PICKUP_PAIRS_JQ='
  '"$ITEM_LIFECYCLE_KEY_JQ"'
  def percentile($p; $arr):
    ($arr | sort) as $s
    | ($s | length) as $n
    | if $n == 0 then null
      else
        (($n - 1) * $p) as $idx
        | ($idx | floor) as $lo
        | ($idx | ceil) as $hi
        | if $lo == $hi then $s[$lo]
          else $s[$lo] + ($idx - $lo) * ($s[$hi] - $s[$lo])
          end
      end;
  def latency_stats($arr):
    {count: ($arr | length), median_seconds: percentile(0.5; $arr), p90_seconds: percentile(0.9; $arr)};
  def keyed($e):
    select(.event == $e
           and (((.repo // "") | tostring) != "")
           and (((.item // "") | tostring) != ""));
  def first_per_key:
    group_by(item_key) | map(sort_by(.ts) | first);

  ($all | map(select(type == "object")) | map(select($since == "" or (.ts // "") >= $since))) as $ev
  | ($ev | map(keyed("first-seen")) | first_per_key) as $fs_list
  | ($ev | map(keyed("selection"))  | first_per_key) as $sel_list
  | ($fs_list  | map({key: item_key, value: .}) | from_entries) as $fs_by_key
  | ($sel_list | map({key: item_key, value: .}) | from_entries) as $sel_by_key
  | ($fs_list  | map(item_key)) as $fs_keys
  | ($sel_list | map(item_key)) as $sel_keys
  | ([$fs_keys[]  | select(. as $k | $sel_by_key | has($k))])         as $paired_keys
  | ([$fs_keys[]  | select(. as $k | ($sel_by_key | has($k)) | not)]) as $fs_only_keys
  | ([$sel_keys[] | select(. as $k | ($fs_by_key  | has($k)) | not)]) as $sel_only_keys
  | ($paired_keys | map(
       $fs_by_key[.] as $fs | $sel_by_key[.] as $sel
       | {node: $sel.node, bootstrap: ($fs.bootstrap // false),
          latency_seconds: (($sel.ts | fromdateiso8601) - ($fs.ts | fromdateiso8601)),
          forge_latency_seconds: (
            if ($fs.forge_created_at // "") == "" then null
            else (try (($sel.ts | fromdateiso8601) - ($fs.forge_created_at | fromdateiso8601)) catch null)
            end)}
     )) as $paired
  | ($paired | map(select(.bootstrap | not))) as $measured
  | ($paired | map(select(.bootstrap)) | length) as $bootstrap_excluded_count
  | ($measured | map(select(((.node // "") | tostring) != "")) | group_by(.node)
       | map({key: .[0].node, value: (map(.latency_seconds) | latency_stats(.))})
       | from_entries) as $by_node
  | ($measured | map(select(.forge_latency_seconds != null))) as $forge_measured
  | ($forge_measured | map(select(((.node // "") | tostring) != "")) | group_by(.node)
       | map({key: .[0].node, value: (map(.forge_latency_seconds) | latency_stats(.))})
       | from_entries) as $forge_by_node
  | {
      coverage: {
        paired: ($paired_keys | length),
        first_seen_only: ($fs_only_keys | length),
        selection_only: ($sel_only_keys | length),
        forge_anchored: ($forge_measured | length)
      },
      pickup_latency: {
        bootstrap_excluded_count: $bootstrap_excluded_count,
        fleet: ($measured | map(.latency_seconds) | latency_stats(.)),
        by_node: $by_node
      },
      pickup_latency_forge_anchored: {
        fleet: ($forge_measured | map(.forge_latency_seconds) | latency_stats(.)),
        by_node: $forge_by_node
      }
    }
'

# item_lifecycle_pickup_pairs SINCE [LOG_FILE]
# Print `{coverage, pickup_latency, pickup_latency_forge_anchored}` — the
# shape `scripts/pickup-metrics.sh` merges into its own report — folded from
# LOG_FILE (or stdin, "-" or omitted). Always succeeds, printing the
# all-empty shape for a missing, empty or unreadable log, on the same terms
# every reader in lib/cycle-state.sh does.
item_lifecycle_pickup_pairs() {
  local since="${1:-}" src="${2:--}" all_json="" out=""
  if [[ "$src" == "-" ]]; then
    all_json="$(jq -c -R 'fromjson? // empty' 2>/dev/null | jq -sc '.' 2>/dev/null || true)"
  elif [[ -s "$src" ]]; then
    all_json="$(jq -c -R 'fromjson? // empty' "$src" 2>/dev/null | jq -sc '.' 2>/dev/null || true)"
  fi
  [[ -n "$all_json" ]] || all_json='[]'
  out="$(jq -nc --arg since "$since" 'input as $all | ('"$ITEM_LIFECYCLE_PICKUP_PAIRS_JQ"')' \
    <<<"$all_json" 2>/dev/null || true)"
  [[ -n "$out" ]] || out='{"coverage":{"paired":0,"first_seen_only":0,"selection_only":0,"forge_anchored":0},"pickup_latency":{"bootstrap_excluded_count":0,"fleet":{"count":0,"median_seconds":null,"p90_seconds":null},"by_node":{}},"pickup_latency_forge_anchored":{"fleet":{"count":0,"median_seconds":null,"p90_seconds":null},"by_node":{}}}'
  printf '%s' "$out"
}

# The main fold (docs/FLOW-SCHEMA.md's "Item lifecycle record"). $all/$void/
# $blocked/$obsolete arrive on stdin as four documents, bound positionally by
# the caller (requirement 4g — big things travel on stdin, never argv):
#
#   $all      every parsed event this run can see, unfiltered.
#   $void     `void_items`'s own output — the currently-void {repo, item}
#             pairs, each carrying the winning item-void's own `ts`.
#   $blocked  `blocked_items`'s own output — the currently-blocked pairs.
#   $obsolete `draft_obsolete_flags`'s own output — every
#             draft-obsolete-flagged event ever logged (the source function
#             does no repo/item filtering of its own, by design — see its
#             header); the fold matches it to `{$r, $i}` itself, the same
#             `resolved()` lookup $void and $blocked already go through.
#
# `orphan-branch-released` carries no `item` field of its own (out of this
# item's scope — `scripts/sweep-orphan-branches.sh` is not one of the sites
# requirement 49 touches), so a `reason: "superseded"` entry is matched back
# to its item the same way `scripts/sweep-closed-issues.sh` already resolves
# one from a branch: a head of exactly `agent/<N>`, the name this pipeline
# mints only for an issue- or tech-debt-sourced work order. An entry whose
# branch does not match that shape names no item this fold can key on, and is
# silently excluded from consideration for `superseded` — never guessed at.
#
# `$since` bounds the *population* — which items appear in `records[]` at all
# is decided by `group_by(item_key)` over `$ev`, the `$all2` events at or
# after `$since` — never the *fate* of an item that does appear. `landed` and
# `superseded` are read off `$full_by_key`, an unwindowed per-item index built
# from `$all2` before `$since` is applied, on the same terms `$void`/
# `$blocked`/`$obsolete` already are (each computed by the caller from the
# whole raw log, not from `$ev`). So an item entering the population because
# of one recent event still reports its true current fate even when the
# evidence that decides it — an older merge, an older void, an older block —
# sits before the window: "fate is current state; `--since` bounds only the
# population," never "fate is what the window alone can see." (`instants`,
# `first_seen` and `source` are the one place the window still shows through:
# they are windowed by design, so they answer "what did this run see for this
# item," not "everything this item ever did.")
#
# Both sides of that index — building it and reading it — go through
# `item_key` itself rather than concatenating the record's own `repo`/`item`,
# so a line whose `repo` is a number rather than a string keys identically on
# both sides. Concatenating instead would be a type error on the lookup, and
# jq errors here are not local: one such line aborts the whole program and
# the fold degrades to its all-zero fallback, exactly the failure the
# object-type guard above exists to prevent.
#
# Fate is assigned by one strict priority, each rule checked only once every
# rule ahead of it has failed to match:
#
#   1. landed       — a `merge-observed` or `issue-closed-post-merge` event
#                     exists for this item. The strongest possible evidence
#                     (a real merge was observed) outranks every other mark,
#                     including a stale void.
#   2. voided       — `void_items` still carries this pair (latest
#                     `item-void`, no later `unvoided`).
#   3. superseded   — an `orphan-branch-released {reason: "superseded"}`
#                     resolves to this item (see above).
#   4. blocked      — `blocked_items` still carries this pair: a currently-
#                     blocked item is demonstrably still in the system, which
#                     outranks the merely uncorroborated intent below.
#   5. abandoned    — a `draft-obsolete-flagged` event exists for this item:
#                     the pipeline's own recorded intent to abandon a draft,
#                     pending the human corroboration (`lib/void-guard.sh`)
#                     that would otherwise retire it as `voided` on a later
#                     fold. A standing block is stronger evidence than this
#                     uncorroborated intent, hence rule 4 above it.
#   6. open         — none of the above: the item has entered (some event
#                     names it) but nothing yet says it has left.
#
# An item resolving to `landed` under rule 1 additionally carries
# `reworked_after_landed: {since, event}` — additive, alongside `fate`, never
# changing which rule wins — when its own full event history holds an
# item-scoped event later than the earliest landing evidence, naming the
# earliest such event. Further landing evidence itself (a second
# `merge-observed`/`issue-closed-post-merge`) is excluded from consideration:
# multiple merges is not rework. The field is omitted entirely, never
# `false`/`null`, when no such later event exists (docs/FLOW-SCHEMA.md,
# issue #1181).
#
# One case is deliberately not folded into the priority order above:
# `unaccounted`. An item is `unaccounted`, not `landed`, when it is *also*
# void *and* that void's own `ts` is later than the earliest landing
# evidence — a human or the Enabler recorded "no work exists" for an item
# that, on the log's own evidence, had already merged. That is a
# contradiction this fold does not resolve by guessing which side is right;
# it is surfaced, with the reason, for a human to read (the same discipline
# `docs/ROADMAP.md`'s D21 states for the flow account generally: "a second,
# a token or an item that cannot be classified lands in an explicit
# unaccounted bucket and is never dropped"). An unaccounted item still
# appears in `records[]`, `fate: "unaccounted"`, exactly as every other item
# does — `unaccounted[]` is a convenience projection of the same records,
# carrying the reason, never a second population.
#
# The invariant (`balanced`) holds by construction — fate is a total
# function over the entered set, into exactly one of seven buckets — and is
# still computed and printed rather than merely asserted in prose: a future
# change that lets an item fall through every rule above (or match two) is
# exactly the defect this field exists to catch.
# shellcheck disable=SC2016  # jq's own $all/$void/$blocked/$obsolete/etc, not the shell's.
ITEM_LIFECYCLE_FOLD_JQ='
  '"$ITEM_LIFECYCLE_KEY_JQ"'
  def resolved($set_json; $r; $i):
    $set_json | any(.repo == $r and ((.item // "") | tostring) == $i);
  def resolved_ts($set_json; $r; $i):
    ($set_json | map(select(.repo == $r and ((.item // "") | tostring) == $i)) | first | .ts) // null;

  ($all
   | map(select(type == "object"))
   | map(if (.event == "orphan-branch-released" and (.reason // "") == "superseded"
             and ((.item // "") == "") and ((.branch // "") | test("^agent/[0-9]+$")))
         then . + {item: (.branch | capture("^agent/(?<n>[0-9]+)$").n)}
         else . end)
  ) as $all2
  | ($all2 | map(select(((.repo // "") | tostring) != "" and ((.item // "") | tostring) != ""))
     | group_by(item_key) | map({key: (.[0] | item_key), value: .}) | from_entries) as $full_by_key
  | ($all2 | map(select($since == "" or (.ts // "") >= $since))) as $ev
  | ($ev | map(.ts // "") | map(select(. != "")) | sort) as $ts_all
  | {from: (if ($ts_all | length) == 0 then null else $ts_all[0] end),
     to:   (if ($ts_all | length) == 0 then null else $ts_all[-1] end)} as $window

  | ($ev | map(select(((.repo // "") | tostring) != "" and ((.item // "") | tostring) != "")))
  | group_by(item_key)
  | map(
      . as $sorted_input
      | ($sorted_input | sort_by(.ts // "")) as $sorted
      | ($sorted[0].repo) as $r
      | ($sorted[0].item | tostring) as $i
      | ($sorted | map({event, ts: (.ts // ""), node: (.node // null), cycle: (.cycle // null),
                         fields: (del(.event,.ts,.node,.cycle,.repo,.item))})) as $instants
      | ([$sorted[] | select(.event == "first-seen") | (.ts // "")] | map(select(. != "")) | sort | first) as $first_seen_ts
      | ([$sorted[] | select(.event == "selection")] | sort_by(.ts // "") | last | .source) as $source
      | ($full_by_key[$sorted[0] | item_key] // []) as $full_events
      | ([$full_events[] | select(.event == "merge-observed" or .event == "issue-closed-post-merge") | (.ts // "")]
          | map(select(. != "")) | sort | first) as $landed_ts
      | ($landed_ts != null) as $landed
      | (if $landed then
           ([$full_events[] | select((.event != "merge-observed" and .event != "issue-closed-post-merge")
                                       and ((.ts // "") > $landed_ts))]
             | sort_by(.ts // "") | first)
         else null end) as $earliest_rework
      | ([$full_events[] | select(.event == "orphan-branch-released" and (.reason // "") == "superseded")] | length > 0) as $superseded_evidence
      | (resolved($obsolete; $r; $i)) as $abandoned_evidence
      | (resolved($void; $r; $i)) as $voided
      | (resolved_ts($void; $r; $i)) as $void_ts
      | (resolved($blocked; $r; $i)) as $blocked_flag
      | ($landed and $voided and $void_ts != null and $void_ts > $landed_ts) as $contradictory
      | (if $contradictory then
           {fate: "unaccounted",
            reason: ("voided (at " + $void_ts + ") after merge evidence at " + $landed_ts
                      + " — contradictory, not resolved automatically")}
         elif $landed then
           {fate: "landed"}
           + (if $earliest_rework != null
              then {reworked_after_landed: {since: $earliest_rework.ts, event: $earliest_rework.event}}
              else {} end)
         elif $voided then {fate: "voided"}
         elif $superseded_evidence then {fate: "superseded"}
         elif $blocked_flag then {fate: "blocked"}
         elif $abandoned_evidence then {fate: "abandoned"}
         else {fate: "open"}
         end) as $fate_obj
      | {repo: $r, item: $i, source: $source, first_seen: $first_seen_ts, instants: $instants}
        + $fate_obj
    ) as $records
  | ($records | map(select(.fate == "landed"))      | length) as $n_landed
  | ($records | map(select(.fate == "voided"))      | length) as $n_voided
  | ($records | map(select(.fate == "superseded"))  | length) as $n_superseded
  | ($records | map(select(.fate == "abandoned"))   | length) as $n_abandoned
  | ($records | map(select(.fate == "blocked"))     | length) as $n_blocked
  | ($records | map(select(.fate == "open"))        | length) as $n_open
  | ($records | map(select(.fate == "unaccounted")) | length) as $n_unaccounted
  | ($records | length) as $n_entered
  | {
      window: $window,
      totals: {
        entered: $n_entered,
        leaving: ($n_landed + $n_voided + $n_superseded + $n_abandoned),
        in_progress: ($n_blocked + $n_open),
        unaccounted: $n_unaccounted,
        balanced: (($n_landed + $n_voided + $n_superseded + $n_abandoned
                     + $n_blocked + $n_open + $n_unaccounted) == $n_entered)
      },
      fates: {landed: $n_landed, voided: $n_voided, superseded: $n_superseded,
              abandoned: $n_abandoned, blocked: $n_blocked, open: $n_open},
      unaccounted: ($records | map(select(.fate == "unaccounted")) | map({repo, item, reason})),
      records: ($records | map(del(.reason)))
    }
'

# item_lifecycle_fold LOG_FILE [SINCE]
# Print the item-lifecycle report — `window`, `totals` (the flow invariant),
# `fates`, `unaccounted[]` and `records[]` — folded from LOG_FILE, or stdin if
# it is "-". Requires `lib/cycle-state.sh` (`blocked_items`, `void_items`,
# `draft_obsolete_flags`) already sourced.
#
# Always succeeds, printing the all-empty shape for a missing, empty or
# unreadable log, on the same terms `blocked_items`/`void_items` already do:
# a caller running under `set -e` must not be killed by one, and a log that
# cannot be read enters nothing.
item_lifecycle_fold() {
  local src="${1:--}" since="${2:-}" log_file="" tmp_log="" all_json_file="" \
        void_file="" blocked_file="" obsolete_file="" out_file="" f=""
  # Nothing that scales with the log is ever held in a bash variable
  # (agent-ops#1620): a variable that size is copied by every subshell forked
  # afterwards, which is what pushed the publisher over its cgroup ceiling.
  # That rule covers this function's four jq inputs *and* its own output —
  # `records[]` carries one entry per item the log has ever seen, so the
  # result is itself log-scale (36 MB on a 43 MB log) and is streamed from a
  # temp file rather than captured. `void_items`/`blocked_items`/
  # `draft_obsolete_flags` already read a file argument directly, so the only
  # read this function must materialise itself is stdin's own one-shot stream
  # — spooled to a temp file so it, too, can be read more than once.
  if [[ "$src" == "-" ]]; then
    tmp_log="$(mktemp 2>/dev/null)" && { cat > "$tmp_log" 2>/dev/null; log_file="$tmp_log"; }
  elif [[ -s "$src" ]]; then
    log_file="$src"
  fi

  all_json_file="$(mktemp 2>/dev/null)" || true
  void_file="$(mktemp 2>/dev/null)" || true
  blocked_file="$(mktemp 2>/dev/null)" || true
  obsolete_file="$(mktemp 2>/dev/null)" || true
  out_file="$(mktemp 2>/dev/null)" || true
  if [[ -n "$log_file" && -n "$all_json_file" && -n "$void_file" \
        && -n "$blocked_file" && -n "$obsolete_file" ]]; then
    jq -c -R 'fromjson? // empty' "$log_file" 2>/dev/null | jq -sc '.' > "$all_json_file" 2>/dev/null
    void_items "$log_file" > "$void_file" 2>/dev/null || true
    blocked_items "$log_file" > "$blocked_file" 2>/dev/null || true
    draft_obsolete_flags "$log_file" > "$obsolete_file" 2>/dev/null || true
  fi
  for f in "$all_json_file" "$void_file" "$blocked_file" "$obsolete_file"; do
    [[ -n "$f" && -s "$f" ]] || { [[ -n "$f" ]] && printf '[]' > "$f" 2>/dev/null; }
  done

  # `-j` (with `-n`) writes the compact object with no trailing newline, which
  # is what the `printf '%s' "$(…)"` this replaced produced — callers compare
  # this output byte for byte.
  if [[ -n "$all_json_file" && -n "$void_file" && -n "$blocked_file" \
        && -n "$obsolete_file" && -n "$out_file" ]]; then
    jq -n -j -c --arg since "$since" \
        'input as $all | input as $void | input as $blocked | input as $obsolete | ('"$ITEM_LIFECYCLE_FOLD_JQ"')' \
        "$all_json_file" "$void_file" "$blocked_file" "$obsolete_file" \
        > "$out_file" 2>/dev/null || true
  fi

  if [[ -n "$out_file" && -s "$out_file" ]]; then
    cat "$out_file" 2>/dev/null || true
  else
    printf '%s' '{"window":{"from":null,"to":null},"totals":{"entered":0,"leaving":0,"in_progress":0,"unaccounted":0,"balanced":true},"fates":{"landed":0,"voided":0,"superseded":0,"abandoned":0,"blocked":0,"open":0},"unaccounted":[],"records":[]}'
  fi
  rm -f "$tmp_log" "$all_json_file" "$void_file" "$blocked_file" "$obsolete_file" "$out_file" 2>/dev/null
}
