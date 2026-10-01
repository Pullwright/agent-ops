#!/usr/bin/env bash
#
# lib/fleet.sh — where the fleet's shared memory lands on disk, and the union
# read over it. Sourced by both pipelines and scripts/state-sync.sh so the
# path convention exists in exactly one place.

# Peers' state trees, one directory per node, materialised by
# `state-sync.sh fetch` from the state repository's nodes/* branches.
fleet_peers_dir() {  # <workspace_root>
  printf '%s/.agent-ops-peers' "$1"
}

# The peers directory's own freshness marker (requirement 2.5, #693/#990):
# `state-sync.sh fetch` writes it after every attempt —
# `{"ok":bool,"ts":…,"last_ok_ts":…|null}`. `ts` is the attempt that
# established the current `ok`; `last_ok_ts` is the last fetch that actually
# succeeded, so a reader can tell a five-minute outage from a three-day one
# even while `ok` stays `false` throughout. A reader that cares whether the
# peer copies it is about to union might be frozen reads this rather than
# trusting a directory that looks populated either way — an absent marker is
# the genuine bootstrap case: no fetch has ever succeeded, because the state
# repository has no node branches yet.
fleet_peers_marker() {  # <peers_dir>
  printf '%s/.last-fetch.json' "$1"
}

# Written whole and renamed into place, for the same reason the peer trees
# beside it are: a reader is a separate process on the same machine, and a
# plain `> marker` truncates the file at redirection and fills it a moment
# later, so a read landing in that window sees an empty file rather than
# either the old answer or the new one.
#
# The transition rule (owner decision, #990, escalation #1065):
#
#   success            — always rewrite: ok:true, ts = last_ok_ts = now.
#   failure, was ok     — rewrite: ok:false, ts = now, last_ok_ts carried
#                          forward from the previous marker's own
#                          last_ok_ts (falling back to its ts when the
#                          previous marker predates this field — a legacy
#                          {ok:true, ts} marker's ts IS the last success).
#   failure, no marker,
#   or an unreadable/    — rewrite: ok:false, ts = now, last_ok_ts = null —
#   zero-byte one          there is no prior success to carry forward.
#   failure, was already — do not touch the file at all, not even with
#   ok:false               identical content: its mtime feeds
#                          scripts/publish-dashboard.sh's
#                          local_state_fingerprint, and moving it every
#                          fetch attempt would rebuild the dashboard once
#                          per attempt for as long as the outage lasts.
fleet_mark_peers() {  # <peers_dir> true|false
  local dir="$1" ok="$2" marker now marker_json prev_ok prev_last_ok
  mkdir -p "$dir"
  marker="$(fleet_peers_marker "$dir")"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [[ "$ok" == "true" ]]; then
    jq -nc --arg ts "$now" '{ok: true, ts: $ts, last_ok_ts: $ts}' > "$marker.tmp" \
      && mv -f "$marker.tmp" "$marker"
    return
  fi

  # `|| true` and the object guard together are what make "unreadable →
  # rewrite" actually reachable: every caller of this function runs under
  # `set -euo pipefail` (scripts/state-sync.sh), and a bare
  # `x="$(jq … )"` over a truncated marker fails the *assignment*, which
  # errexit turns into an abort of the whole fetch before this branch is
  # ever taken — leaving the corrupt marker in place and unwritten for
  # every subsequent failure. `type == "object"` catches the JSON that
  # parses but cannot be indexed (a bare scalar, `null`), which `.ok`
  # would otherwise raise on for the same result.
  marker_json=""
  [[ -s "$marker" ]] && marker_json="$(jq -c 'select(type == "object")' "$marker" 2>/dev/null || true)"
  if [[ -n "$marker_json" ]]; then
    prev_ok="$(jq -r '.ok // false' <<<"$marker_json" 2>/dev/null)"
    [[ "$prev_ok" == "true" ]] || return 0
    prev_last_ok="$(jq -r '.last_ok_ts // empty' <<<"$marker_json" 2>/dev/null)"
    [[ -n "$prev_last_ok" ]] || prev_last_ok="$(jq -r '.ts // empty' <<<"$marker_json" 2>/dev/null)"
  else
    prev_last_ok=""
  fi

  if [[ -n "$prev_last_ok" ]]; then
    jq -nc --arg ts "$now" --arg last_ok "$prev_last_ok" \
      '{ok: false, ts: $ts, last_ok_ts: $last_ok}' > "$marker.tmp" \
      && mv -f "$marker.tmp" "$marker"
  else
    jq -nc --arg ts "$now" '{ok: false, ts: $ts, last_ok_ts: null}' > "$marker.tmp" \
      && mv -f "$marker.tmp" "$marker"
  fi
}

# fleet_peers_stale <peers_dir> [fetch_minutes]
# The one predicate for "is the peers directory's own freshness marker too
# old to trust" (#990) — shared by requirement 38b's `fleet_logs_healthy`
# below and the dashboard's fleet-strip badge, so the two can never disagree
# about what counts as stale. Exit 0 (stale) when the marker says `ok:false`
# (a real failure is in force, however long ago it started), or when it says
# `ok:true` but `ts` is older than the threshold (the fetch cron itself has
# stopped running, without ever logging a failure). Exit 1 (not stale) for a
# fresh `ok:true` marker or an absent one — no marker at all is the bootstrap
# case, not itself a failure, and the union's own emptiness already catches
# that node (`fleet_logs_healthy`'s own header).
#
# FETCH_MINUTES defaults to `schedule.state_sync_fetch_minutes`'s own default
# (7) — this library has no config reader of its own and should not grow one,
# so a caller that already has config in hand (lib/candidate-gather.sh,
# scripts/publish-dashboard.sh) passes the configured value instead. The
# threshold is 3 fetch intervals, capped at LABEL_OWN_GRACE_SECONDS (#1053's
# principle: a staleness bound must never exceed the fault threshold it
# gates) — env-overridable as FLEET_PEERS_STALE_SECONDS, on the same
# `${VAR:-default}` shape LABEL_OWN_GRACE_SECONDS itself uses
# (lib/label-marker.sh), so a test can pin it.
fleet_peers_stale() {  # <peers_dir> [fetch_minutes]
  local dir="$1" fetch_minutes="${2:-7}" marker ok ts threshold cap now then_epoch age
  marker="$(fleet_peers_marker "$dir")"
  [[ -s "$marker" ]] || return 1
  # `|| true` for the same reason `fleet_mark_peers` above needs it: a
  # corrupt marker makes jq exit non-zero, and under a caller's `set -e` a
  # bare assignment from it aborts that caller rather than reaching the
  # "not `true`" branch below, which reads an unreadable marker as stale.
  ok="$(jq -r 'if type == "object" then (.ok // false) else false end' "$marker" 2>/dev/null || true)"
  [[ "$ok" == "true" ]] || return 0

  ts="$(jq -r '.ts // empty' "$marker" 2>/dev/null || true)"
  [[ -n "$ts" ]] || return 0

  threshold="${FLEET_PEERS_STALE_SECONDS:-}"
  if [[ -z "$threshold" ]]; then
    threshold=$(( fetch_minutes * 3 * 60 ))
    cap="${LABEL_OWN_GRACE_SECONDS:-1800}"
    (( threshold > cap )) && threshold="$cap"
  fi

  now="$(date -u +%s)"
  then_epoch="$(date -u -d "$ts" +%s 2>/dev/null)" || return 0
  age=$(( now - then_epoch ))
  (( age > threshold ))
}

# fleet_logs_healthy <state_dir> <peers_dir> <union_log> [fetch_minutes]
# True when UNION_LOG — the snapshot `fleet_logs` above just wrote — is fit to
# read a *negative* off: "no open block exists," not merely "no open block is
# visible from here" (agent-ops#816 review, requirement 38b). `fleet_logs`
# degrades silently, emitting nothing at all when STATE_DIR/log.jsonl is
# absent and PEERS_DIR is empty — a fresh node before its first state-sync, a
# mirror just discarded and rebuilt (requirement 2.5's own corruption path),
# or a fetch cron that has been failing all produce exactly that, and an
# empty union is indistinguishable from "the fleet genuinely has no blocks" to
# a reader that only ever acts on positive log evidence until now. Unhealthy
# in either of two ways this checks in order: the union itself came back
# empty, or `fleet_peers_stale` (above) says the peers directory is stale —
# a real failure in force, or an `ok:true` marker the fetch cron has stopped
# refreshing (#990; a dead cron used to read healthy here as long as it had
# died on a success). FETCH_MINUTES is passed straight through to
# `fleet_peers_stale`; its own default applies when the caller has none to
# give.
fleet_logs_healthy() {  # <state_dir> <peers_dir> <union_log> [fetch_minutes]
  local peers="$2" union_log="$3" fetch_minutes="${4:-7}"
  [[ -s "$union_log" ]] || return 1
  fleet_peers_stale "$peers" "$fetch_minutes" && return 1
  return 0
}

# fleet_ts_field <file>
#
# A one-line JSON file's own top-level `.ts` string field — the shared read
# behind `fleet_publication_status` below, for both call sites: self's
# `.state-sync-published.json` (`{"ts":"…"}`, whole) and a peer's
# `heartbeat.json` (`{"node":…,"role":…,"ts":…,…}`, `ts` mid-object). Every
# writer of either file uses `jq -nc`, whose compact encoding is always one
# line with no inserted whitespace, so a plain prefix match is exact for the
# shape `jq -nc '{ts: $ts}'` itself produces — the fast path below, no fork —
# falling back to an actual jq parse for any other shape (`ts` not first, a
# hand-edited file, a future writer that pretty-prints) so correctness never
# depends on which shape a caller happens to hold. D14: called once per
# fleet-strip row, self included, on both a full and a fast
# publish-dashboard.sh tick, so a jq fork saved here is saved on every tick.
fleet_ts_field() {
  local file="${1:-}" line stripped
  [[ -s "$file" ]] || return 0
  # Not `read ... || return 0`: `read` itself reports failure on a file with
  # no trailing newline (every writer's `jq -nc` output has one; a test
  # fixture built with a bare `printf` does not) even though `line` still
  # holds the whole thing correctly — the read is genuinely done at EOF
  # either way, so only an empty result (an empty file, already excluded
  # above, or truly nothing readable) means bail.
  IFS= read -r line < "$file" 2>/dev/null
  [[ -n "$line" ]] || return 0
  case "$line" in
    '{"ts":"'*)
      stripped="${line#\{\"ts\":\"}"
      stripped="${stripped%%\"*}"
      printf '%s' "$stripped"
      return 0
      ;;
  esac
  # The fallback reads the whole *file*, never the one line the fast-path test
  # above needed: a pretty-printed object's first line is `{` alone, which no
  # jq parse can answer, and answering it with empty would report the node
  # `unknown` — silently stale — on the one page whose job is to be believed
  # about staleness. The fork is spent either way, so parsing all of what is
  # there costs nothing over parsing the first line of it.
  #
  # `|| true` because jq exits 5 on input it cannot parse, and this reader owes
  # its callers "the ts if there is one" rather than a status: every consumer
  # already treats an empty answer as `fleet_publication_status`'s `unknown`,
  # and `scripts/state-sync.sh` — which sources this file — runs under `set -e`,
  # where a corrupt peer heartbeat would otherwise end the run rather than the
  # read.
  jq -r '.ts // empty' < "$file" 2>/dev/null || true
}

# fleet_publication_status <ts> <threshold_s> [now_epoch]
#
# The one verdict over a publication timestamp — self's or a peer's alike
# (agent-ops#602). A node's freshness is a fact about what it last actually
# published into the shared state, never about its own local clock: on
# 2026-08-08 both laptop nodes reported themselves fresh for four days while
# publishing nothing, because the self row used to be built from `date` and
# a hardcoded `false` rather than read back from anywhere. Called once per
# row by both scripts/publish-dashboard.sh (every fleet.nodes[] row, self
# included) and scripts/doctor.sh (this node's own row), so the two can
# never derive it differently (requirement 34a) — a peer's <ts> is its
# heartbeat's own `ts`; self's is `.state-sync-published.json`'s `ts`
# (scripts/state-sync.sh's `do_fetch`, reading back what the shared state
# holds for this node's own branch).
#
#   {ts: null, age_s: null, verdict: "unknown"}
#     <ts> is empty or does not parse — no publication has ever been read
#     back for this node/peer. Not itself a failure: a fresh install, or the
#     short window before a node's first successful push has been fetched
#     back at all.
#   {ts: "…", age_s: N, verdict: "fresh"|"stale"}
#     N seconds have passed since the shared state last held a publication
#     from this node/peer; "stale" once N exceeds <threshold_s>
#     (`node_stale_after_minutes * 60`).
#
# Built with `printf`, not `jq` (D14: called once per fleet-strip row, self
# included, on both a full and a fast publish-dashboard.sh tick, so a jq fork
# here counts directly against #798's fast/full cost ratio) — every field is
# already known safe: <ts> is always machine-generated (`date -u`'s own
# output or a git committer date), never free text, and <age>/verdict are
# ours to choose.
fleet_publication_status() {
  local ts="${1:-}" threshold="${2:-1800}" now="${3:-}" then_epoch age verdict
  [[ -n "$now" ]] || now="$(date -u +%s)"
  if [[ -z "$ts" ]] || ! then_epoch="$(date -u -d "$ts" +%s 2>/dev/null)" \
      || [[ -z "$then_epoch" ]]; then
    printf '{"ts":null,"age_s":null,"verdict":"unknown"}'
    return 0
  fi
  age=$(( now - then_epoch ))
  (( age < 0 )) && age=0
  verdict="fresh"
  (( age > threshold )) && verdict="stale"
  printf '{"ts":"%s","age_s":%s,"verdict":"%s"}' "$ts" "$age" "$verdict"
}

# FLEET_CANDIDATE_AWK — the cheap test, shared by `fleet_logs` and
# `fleet_repair_log` below, for a line that may not be one whole record:
# `fleet_candidate(LINE)` is true for a line that does not open an object, one
# that does not end in `}`, or one that holds `{"ts":"` anywhere past its
# start. Every writer of every log these read (`log.jsonl`, `review-log.jsonl`,
# `monitor-log.jsonl`, `revert-rate.jsonl`, `gh-shim/ledger.ndjson`) appends
# one compact `jq -nc` object per line, opened with its `ts`; so a whole record
# opens with `{` and ends with `}`, a line that does not is a fragment or a
# stump, and a second `{"ts":"` is where a later record was joined on. An
# empty line is not a candidate: it holds nothing to recover. Run under the C
# locale, the test is a byte scan of each line, and on a node's own 25 MB log
# it picks out a dozen or so lines — every damaged one, and the
# `landing-audit-record` events that carry a nested record and parse whole.
# shellcheck disable=SC2016  # awk's own source, not the shell's
FLEET_CANDIDATE_AWK='
  function fleet_candidate(s) {
    if (s == "") return 0
    if (substr(s, 1, 1) != "{" || substr(s, length(s)) != "}") return 1
    return index(substr(s, 2), "{\"ts\":\"") > 0
  }'

# FLEET_RECOVER_JQ — the one recovery of a damaged line, shared by
# `fleet_logs` and both of `fleet_repair_log`'s paths so the union and the
# repaired files can never disagree about what a line held (#2037):
#
#   fleet_is_record   whether the line parses whole as an object.
#   fleet_recover     the records the line holds, each as its own raw text.
#                     The line is split at each `{"ts":"` into pieces — the
#                     piece before the first mark may be empty and is then
#                     left out — and walked from the left: at each piece, the
#                     shortest run of consecutive pieces that, joined, parses
#                     as an object is emitted, and the walk resumes after it;
#                     a piece no run starting there parses from is dropped.
#                     `{"ts":"A",…}{"ts":"B",…}` (a cut just before the
#                     newline, or `cat` joining a peer file that lacks its
#                     final newline) yields both A and B; a stump before a
#                     whole record is dropped and the record kept. Only
#                     objects count, so a bare number left in a fragment is
#                     never emitted.
#   fleet_resolve     the line itself when it is a record, and otherwise what
#                     `fleet_recover` makes of it.
#
# The shortest run is the right one: a record's own text is balanced, so a run
# that starts with a stump (an object opened and not closed) cannot balance
# however much of the record after it joins, and a run that is a record cannot
# be cut short at a later mark, which falls inside it. Folded with `reduce`
# rather than `first` or `limit`: under jq 1.6 a `try` swallows the `break`
# those are built on.
# shellcheck disable=SC2016  # jq's own $m/$p/$pc/$n/$i/$j/$s/$hit
FLEET_RECOVER_JQ='
  def fleet_is_record: try (fromjson | type == "object") catch false;
  def fleet_recover:
    "{\"ts\":\"" as $m
    | split($m) as $p
    | ((if $p[0] == "" then [] else [$p[0]] end) + [$p[1:][] | $m + .]) as $pc
    | ($pc | length) as $n
    | def fleet_recover_from($i):
        if $i >= $n then empty
        else
          (reduce range($i; $n) as $j (null;
             if . != null then .
             else ($pc[$i:$j + 1] | join("")) as $s
               | if ($s | fleet_is_record) then {j: $j, s: $s} else null end
             end)) as $hit
          | if $hit == null then fleet_recover_from($i + 1)
            else $hit.s, fleet_recover_from($hit.j + 1) end
        end;
      fleet_recover_from(0);
  def fleet_resolve: if fleet_is_record then . else fleet_recover end;
'

# The fleet's event stream: this node's own log followed by every peer's,
# sorted into time order (each line begins {"ts":"…", so a plain byte sort is
# a time sort). The consumers that reduce by most-recent-event-wins — the
# blocked and void extractions (requirement 34/34c), the no-op fingerprint
# (3b), the usage-limit cooldown (2.1) — need the order, not the provenance;
# requirement 33 stamps `node` on every event for anything that does. The
# union is advisory speed — a lesson one node learned sparing the rest — and
# the claims of requirement 17a are the lock underneath it.
#
# The sort places a line at its first timestamp, so a damaged line is taken
# apart before the sort, or what it holds lands out of order. A peer copy not
# yet repaired at its source (`fleet_repair_log` below), or history replicated
# before it was, can carry two kinds:
#
#   - a NUL run, where an unclean stop lost the data blocks behind the last few
#     writes. The run ate the newlines inside it too, so it becomes one line
#     break here (`tr -s '\0' '\n'`); a NUL never belongs in JSONL text.
#   - a splice: the head of a record cut off part-way, with no newline, and the
#     whole of a later record on the same line (#2037). A write cut short by a
#     full disk leaves one, and so does the `cat` below when a peer file's last
#     record lacks its newline.
#
# Sorted whole, a spliced line sits at its head's timestamp, and a record
# recovered from it afterwards would sit there too, ahead of records older
# than itself; a reader that takes the most recent event, or the first since a
# clear, would then answer from the wrong one. So each damaged line is split
# here and each record it holds enters the sort on its own: the union holds
# every recoverable record at its own timestamp's place, and no reader repairs
# a snapshot afterwards.
#
# The bulk of the union is never parsed or written anywhere extra. One
# streaming `awk` pass under the C locale sets the candidate lines
# (FLEET_CANDIDATE_AWK) aside in a small file under TMPDIR and passes every
# other line straight to the sort; one `jq` then resolves the candidates
# (FLEET_RECOVER_JQ's `fleet_resolve`) into the same sort. A candidate that
# parses whole passes unchanged, byte for byte.
#
# DAMAGE_FILE, when given, receives the number of candidates that were not
# whole records — the lines this read took apart or dropped. A reader that
# counts what its own parse drops (the dashboard's `log_repair`) adds it,
# since those lines never reach that parse.
#
# Returns non-zero when a stage after the gather fails — `tr`, `awk`, the
# candidate `jq`, or the sort — so that a caller can tell a union that could
# not be built from one that holds nothing, and report it (#2037): an OOM kill
# or a full disk, the conditions that damaged the logs in the first place, are
# exactly what makes a sort fail. A peer file that vanishes between the glob
# and its `cat` is not a failure; the fetch replaces peer trees whole, and the
# next read sees the new one. The body is a subshell so that its `set +e`, its
# variables and its clean-up trap stay its own: the candidate file is removed
# however it ends.
fleet_logs() (  # <state_dir> <peers_dir> [log-basename] [damage-file]
  set +e
  state_dir="$1" peers="$2" name="${3:-log.jsonl}" damage="${4:-}"
  side="$(mktemp "${TMPDIR:-/tmp}/fleet-logs.XXXXXX" 2>/dev/null)" || exit 1
  trap 'rm -f "$side"' EXIT
  {
    {
      [[ -f "$state_dir/$name" ]] && cat "$state_dir/$name"
      for f in "$peers"/*/"$name"; do
        [[ -f "$f" ]] && cat "$f"
      done
    } 2>/dev/null | tr -s '\0' '\n' \
      | LC_ALL=C awk -v side="$side" "$FLEET_CANDIDATE_AWK"'
          fleet_candidate($0) { print > side; next }
          { print }'
    st=("${PIPESTATUS[@]}")
    (( st[1] == 0 && st[2] == 0 )) || exit 1
    if [[ -s "$side" ]]; then
      jq -nRr "$FLEET_RECOVER_JQ"' inputs | fleet_resolve' "$side" || exit 1
    fi
  } | sort
  st=("${PIPESTATUS[@]}")
  (( st[0] == 0 && st[1] == 0 )) || exit 1
  if [[ -n "$damage" ]]; then
    if [[ -s "$side" ]]; then
      jq -nR "$FLEET_RECOVER_JQ"' reduce (inputs | select(fleet_is_record | not)) as $l (0; . + 1)' \
        "$side" > "$damage" 2>/dev/null || : > "$damage"
    else
      printf '0\n' > "$damage"
    fi
  fi
  exit 0
)

# fleet_repair_log <path> <node>
# Repair a node's own log at its source, so the damage stops replicating.
# The launcher (`scripts/publish-dashboard-launcher.sh`) calls it once a window
# on `dashboard.log` and the JSONL logs in `state_dir`; nothing else does, since
# `fleet_logs` takes damaged lines apart as it reads a union.
#
# A container killed mid-append can leave a log's size recorded while the
# data blocks behind the last few writes never reach disk: they read back as
# NUL bytes. One NUL makes the whole file binary to grep, which then stops
# printing matches for everything around it — so the damage is not the lost
# lines but every later read of whatever survived. Strip the NUL run and
# record what was dropped, rather than closing the gap silently: the loss is
# a fact about the node worth keeping.
#
# A JSONL target (PATH ending `.jsonl`) gets a JSON repair record so every
# `fromjson? // empty` reader still sees it; anything else (dashboard.log)
# gets the plain-text line that predates this generalisation. A plain-text
# line appended to a `.jsonl` file would be exactly what those readers
# silently drop, reproducing the same "loss recorded nowhere" failure this
# exists to close. The JSONL repair is `fleet_repair_jsonl` below.
#
# Cost when there is nothing to do (the normal case) is two reads of PATH —
# the NUL count and the candidate scan — and no write. The rewrite relies on
# every writer reopening by name per append, so none holds a descriptor
# across the rename; an append that lands between the read and the rename
# would still go to the old file and be lost (#1196), so the swap is
# abandoned when PATH has changed size since it was read
# (`fleet_repair_swap`), and the next call retries.
#
# Every step is guarded, and the JSONL repair is called in an `||` list as
# well: a caller may run under `set -e`, and a step of this best-effort
# repair that fails must leave the file as it was rather than end the caller.
fleet_repair_log() {
  local target="$1" node="$2" size clean tmp dropped
  [[ -s "$target" ]] || return 0
  size="$(stat -c %s "$target" 2>/dev/null)" || return 0
  clean="$(tr -d '\0' < "$target" 2>/dev/null | wc -c)" || return 0
  [[ "$size" =~ ^[0-9]+$ && "$clean" =~ ^[0-9]+$ ]] || return 0
  dropped=$(( size - clean ))
  if [[ "$target" == *.jsonl ]]; then
    fleet_repair_jsonl "$target" "$node" "$size" "$dropped" || true
    return 0
  fi
  (( dropped > 0 )) || return 0
  tmp="$target.repair.$$"
  tr -d '\0' < "$target" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  printf '%(%Y-%m-%dT%H:%M:%S%z)T repaired: dropped %s NUL byte(s) — an unclean stop lost the log lines in flight\n' \
    -1 "$dropped" >> "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
  fleet_repair_swap "$target" "$tmp" "$size"
  return 0
}

# fleet_repair_jsonl <path> <node> <size> <NUL bytes>
# `fleet_repair_log`'s JSONL case. Each damaged line is replaced, in its place,
# by the records FLEET_RECOVER_JQ's `fleet_recover` splits out of it — none,
# one, or more — and a `log-repaired` record says what happened:
# `dropped_nul_bytes`, `dropped_lines` (the damaged lines taken out) and
# `recovered_records` (the records put back in their place). A line that
# parses whole is never touched, whatever it holds.
#
# With a NUL run (NUL BYTES above zero), the run eats whatever those blocks
# held, the newline separators inside it included: strip the bytes alone and
# what is left is the head of one record spliced onto the whole of a later
# one. So the run becomes a line break (`tr -s '\0' '\n'`; `-s` squeezes the
# run, and a newline it happens to abut, down to the one separator the records
# either side are missing), and every line of the result goes through the
# recovery. That path is rare, so parsing the whole file there is acceptable.
#
# With no NUL byte, the same splice arises from a write a full disk cut short:
# the head of a record with no newline, completed by the next append's whole
# record. Both VM nodes' own logs carried 15 and 18 such lines, and every peer
# copy replicated them (#2037). Only the candidate lines (FLEET_CANDIDATE_AWK)
# reach `jq` there, which keeps the normal case — nothing damaged — to a
# streaming scan: on a 25 MB log it takes about 0.04 s against about 0.8 s for
# a whole-file parse.
#
# On either path, an unterminated last line is left out of the repair: it may
# be an append still being written, and the next append completes it. It is
# copied back byte for byte, without a newline added, after the `log-repaired`
# record, so the file still ends with the line that append will complete; a
# real stump left there becomes a splice that a later call repairs. Nothing
# else in the file waits on it.
fleet_repair_jsonl() {
  local target="$1" node="$2" size="$3" nul="$4" src="$1" split="" all=0 unterm=0
  local plan tmp counts bad recovered
  if (( nul > 0 )); then
    split="$target.split.$$"
    tr -s '\0' '\n' < "$target" > "$split" 2>/dev/null || { rm -f "$split"; return 0; }
    src="$split" all=1
  fi
  if [[ -n "$(tail -c 1 "$src" 2>/dev/null)" ]]; then
    unterm=1
  fi
  # The plan: `<line number>\t<record>` for each record recovered from a
  # damaged line, and `<line number>\t` for a damaged line that yields none.
  # On the NUL path every non-empty line is a candidate. The candidate `awk`
  # holds each candidate back one line, so the last line can be left out when
  # it is unterminated.
  # shellcheck disable=SC2016  # awk's and jq's own source, not the shell's
  plan="$(set -o pipefail
    LC_ALL=C awk -v all="$all" -v unterm="$unterm" "$FLEET_CANDIDATE_AWK"'
        held != "" { print held; held = "" }
        (all && $0 != "") || fleet_candidate($0) { held = FNR "\t" $0; heldn = FNR }
        END { if (held != "" && !(unterm && heldn == NR)) print held }' "$src" 2>/dev/null \
      | jq -nRr "$FLEET_RECOVER_JQ"'
          inputs
          | split("\t") as $f
          | ($f[1:] | join("\t")) as $line
          | select($line | fleet_is_record | not)
          | [$line | fleet_recover] as $r
          | if $r == [] then $f[0] + "\t" else $f[0] + "\t" + $r[] end' 2>/dev/null)" \
    || { rm -f "$split"; return 0; }
  if [[ -z "$plan" ]] && (( nul == 0 )); then
    return 0
  fi
  tmp="$target.repair.$$"
  # Apply the plan, splitting each plan line at its first tab only, since a
  # record may hold one of its own; print every other line as it is (bar the
  # empty lines a NUL run can leave), and leave out an unterminated last line.
  # shellcheck disable=SC2016  # awk's own source
  LC_ALL=C awk -v all="$all" -v unterm="$unterm" '
      function out(n, l) {
        if (n in fix) { if (fix[n] != "") print fix[n]; return }
        if (all && l == "") return
        print l
      }
      NR == FNR {
        i = index($0, "\t"); n = substr($0, 1, i - 1); r = substr($0, i + 1)
        if (!(n in fix)) fix[n] = ""
        if (r != "") fix[n] = (fix[n] == "" ? r : fix[n] "\n" r)
        next
      }
      FNR > 1 { out(FNR - 1, prev) }
      { prev = $0 }
      END { if (FNR > 0 && !unterm) out(FNR, prev) }' - "$src" <<<"$plan" > "$tmp" 2>/dev/null \
    || { rm -f "$split" "$tmp"; return 0; }
  # shellcheck disable=SC2016  # awk's own source
  counts="$(LC_ALL=C awk '
      $0 != "" {
        i = index($0, "\t"); n = substr($0, 1, i - 1)
        if (!(n in seen)) { seen[n] = 1; d++ }
        if (substr($0, i + 1) != "") r++
      }
      END { print d + 0, r + 0 }' <<<"$plan" 2>/dev/null)" \
    || { rm -f "$split" "$tmp"; return 0; }
  bad="${counts% *}" recovered="${counts#* }"
  [[ "$bad" =~ ^[0-9]+$ && "$recovered" =~ ^[0-9]+$ ]] || { rm -f "$split" "$tmp"; return 0; }
  jq -nc --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg node "$node" \
    --argjson nul "$nul" --argjson lines "$bad" --argjson recovered "$recovered" \
    '{ts: $ts, node: $node, event: "log-repaired", dropped_nul_bytes: $nul,
      dropped_lines: $lines, recovered_records: $recovered}' >> "$tmp" 2>/dev/null \
    || { rm -f "$split" "$tmp"; return 0; }
  if (( unterm )); then
    tail -n 1 "$src" >> "$tmp" 2>/dev/null || { rm -f "$split" "$tmp"; return 0; }
  fi
  rm -f "$split"
  fleet_repair_swap "$target" "$tmp" "$size"
  return 0
}

# fleet_repair_swap <path> <repaired copy> <size when read>
# Put a repaired copy in place of PATH, unless PATH has changed size since the
# repair read it. Every writer appends, so a changed size means an append
# landed during the repair — on the file the rename is about to replace — and
# the copy lacks it. Abandoning costs nothing: the file is no worse than it
# was, and the next call retries. It narrows #1196's window to the instant
# between this check and the rename rather than closing it; only a lock both
# sides take would close it.
fleet_repair_swap() {
  local target="$1" tmp="$2" size="$3" now
  now="$(stat -c %s "$target" 2>/dev/null)" || now=""
  if [[ "$now" != "$size" ]]; then
    rm -f "$tmp" 2>/dev/null || true
    return 0
  fi
  mv -f "$tmp" "$target" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  return 0
}
