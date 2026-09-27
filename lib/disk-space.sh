#!/usr/bin/env bash
#
# lib/disk-space.sh — free space on a directory's filesystem, read and judged
# one way everywhere: `scripts/doctor.sh`'s advisory warning and
# `agent-cycle.sh`'s pre-clone stand-down gate (requirement 2.0c, agent-ops#756)
# share this rather than each doing its own `df` arithmetic, so the two can no
# longer silently disagree about what "low" means.
#
# ## Why this exists
#
# `doctor.sh` has read `workspace_root`'s free space and warned below a fixed
# 2 GiB since before this file existed — "a cycle clones every repository it
# touches" — but that warning only ever reached a human running `doctor.sh` by
# hand. The cycle itself cloned straight into whatever room was actually left.
# On the ockham laptop that ran out, a write truncated mid-flight left
# zero-length git objects in both nodes' state mirrors, permanently disabling
# `git gc` (#604) and leaving 4.2 GB of orphaned clones behind (#605) — a
# failure a gate ahead of the clone would have refused to start into.
#
# ## The floor is derived, not fixed (agent-ops#904, the residual of #756)
#
# A flat `min_free_workspace_bytes` protects a fleet whose repositories stay
# far below it, but says nothing about one whose repository approaches or
# exceeds it — a fixed floor nobody chose for that installation's own clone
# size under-protects silently. `disk_space_largest_footprint` reads the
# largest clone footprint any node has ever recorded (`clone-footprint`
# events, logged once per successful `clone_repo` by agent-cycle.sh and
# review-cycle.sh) back from the fleet's union log — never the network, since
# `df` and this log are both already-local reads — and
# `disk_space_effective_min_bytes` turns that into the threshold this gate
# actually uses: `max(min_free_workspace_bytes, workspace_headroom_factor ×
# largest footprint)`. `min_free_workspace_bytes` is the floor *under* that
# derivation, never a ceiling — the same shape `lock_stale_after`
# (requirement 4f) and the state-sync count keys (requirement 1d) already
# use elsewhere. With no footprint ever recorded — a fleet's first cycle, or
# a union log this node cannot yet read — the floor alone governs, which
# fails in the safe direction the same way `disk_space_verdict`'s own
# "unreadable is not low" already does.

# disk_space_free_kb PATH
# Free space on PATH's filesystem, in KiB (`df -Pk`'s own unit), or empty if
# it cannot be read — PATH does not exist, or `df` itself fails. Never prints
# `0` for "unreadable": a caller must be able to tell "definitely short" from
# "no idea", the same distinction `github_limit_verdict`'s `unknown` already
# draws for the GitHub budget check (lib/github-limit.sh).
disk_space_free_kb() {
  local path="${1:-}" kb
  [[ -n "$path" ]] || return 0
  kb="$(df -Pk "$path" 2>/dev/null | awk 'NR == 2 {print $4}')"
  [[ "$kb" =~ ^[0-9]+$ ]] || return 0
  printf '%s' "$kb"
}

# disk_space_same_filesystem PATH1 PATH2
# True (exit 0) iff PATH1 and PATH2 resolve to the same filesystem, in which
# case a caller judging both against one floor only needs to take one `df`
# reading — the common case, where `state_dir` and `workspace_root` sit under
# one home directory. False (exit 1) if they differ, or if either path's
# device id cannot be read: "cannot tell" is treated the same as "different",
# never as "same" — the cost of a redundant second reading is one extra `df`,
# the cost of wrongly treating two independent disks as one is a shortfall on
# the unread one going unnoticed.
disk_space_same_filesystem() {
  local path1="${1:-}" path2="${2:-}" dev1 dev2
  [[ -n "$path1" && -n "$path2" ]] || return 1
  dev1="$(stat -c %d -- "$path1" 2>/dev/null)" || return 1
  dev2="$(stat -c %d -- "$path2" 2>/dev/null)" || return 1
  [[ -n "$dev1" && "$dev1" == "$dev2" ]]
}

# disk_space_verdict FREE_KB MIN_BYTES
# "low" when FREE_KB (KiB) is below MIN_BYTES (bytes — the config unit) once
# converted to the same one; "ok" otherwise, including when MIN_BYTES is `0`
# (the floor is off) or FREE_KB is empty/unreadable. An unreadable meter is no
# evidence of a full disk — standing down on it would invent a failure mode a
# network blip never had, the same reasoning requirement 2.0's `unknown`
# already rests on.
disk_space_verdict() {
  local free_kb="${1:-}" min_bytes="${2:-0}" min_kb
  [[ "$min_bytes" =~ ^[0-9]+$ ]] || min_bytes=0
  (( min_bytes > 0 )) || { printf 'ok'; return 0; }
  [[ "$free_kb" =~ ^[0-9]+$ ]] || { printf 'ok'; return 0; }
  min_kb=$(( min_bytes / 1024 ))
  if (( free_kb < min_kb )); then
    printf 'low'
  else
    printf 'ok'
  fi
}

# disk_space_describe PATH FREE_KB MIN_BYTES [GOVERNED_BY] [REPO] [FOOTPRINT_BYTES] [FACTOR]
# The one-line explanation both the stand-down event and doctor.sh's warning
# use, so the two can never describe the same shortfall differently.
# GOVERNED_BY (agent-ops#904), defaulting to "floor", names which bound
# produced MIN_BYTES: "floor" renders exactly the plain-floor sentence this
# function always rendered, so a caller that never derives anything (or a
# derivation that never rose above the floor) is byte-for-byte unchanged;
# "derived" additionally names REPO and its own recorded FOOTPRINT_BYTES, so
# the sentence says where the figure came from rather than only what it is.
disk_space_describe() {
  local path="${1:-}" free_kb="${2:-0}" min_bytes="${3:-0}" governed_by="${4:-floor}" \
    repo="${5:-}" footprint_bytes="${6:-}" factor="${7:-}" min_mib bound footprint_mib
  [[ "$free_kb" =~ ^[0-9]+$ ]] || free_kb=0
  [[ "$min_bytes" =~ ^[0-9]+$ ]] || min_bytes=0
  min_mib=$(( min_bytes / 1024 / 1024 ))
  if [[ "$governed_by" == "derived" && -n "$repo" && "$footprint_bytes" =~ ^[0-9]+$ ]]; then
    footprint_mib=$(( footprint_bytes / 1024 / 1024 ))
    bound="${min_mib} MiB (${factor}x ${repo}'s ${footprint_mib} MiB recorded clone)"
  else
    bound="${min_mib} MiB"
  fi
  printf '%s has only %d MiB free, below the %s this cycle needs — a cycle writes its clone, its records and its state mirror before it can finish' \
    "$path" $(( free_kb / 1024 )) "$bound"
}

# disk_space_clone_footprint_bytes DIR
# The size of a just-completed clone, in bytes — `du -sb`, the same reading
# `workspace_orphans` (lib/workspace.sh) already takes of a directory under
# `workspace_root` — or empty when DIR does not exist or `du` itself fails.
# Never `0` for "unreadable", the same convention `disk_space_free_kb` uses:
# a caller logging this as a `clone-footprint` event must be able to skip a
# reading it could not take rather than record a real repository as empty.
disk_space_clone_footprint_bytes() {
  local dir="${1:-}" bytes
  [[ -n "$dir" && -e "$dir" ]] || return 0
  bytes="$(du -sb -- "$dir" 2>/dev/null | cut -f1)"
  [[ "$bytes" =~ ^[0-9]+$ ]] || return 0
  printf '%s' "$bytes"
}

# disk_space_largest_footprint  < UNION LOG JSONL on stdin
# The single largest `clone-footprint` event recorded across the fleet's
# union log, as `<bytes>\t<repo>`, or empty when none has ever been recorded
# — the same "read live state off the union log" shape requirement 2.1's own
# `limit_union_record` already uses, so a node that has never itself cloned a
# repository still learns its footprint from a peer that has.
#
# Unfiltered by which repositories are configured *now*: a footprint
# recorded for a repository since dropped from config still describes a
# clone this fleet actually made, and keeping it only ever pushes the
# derived threshold higher, never lower — the safe direction to err in,
# mirroring (in the opposite direction) the "no evidence reads as ok"
# reasoning `disk_space_verdict` already rests on.
#
# Reads line-by-line through `fromjson? // empty` (`jq -Rc`) before slurping,
# the same NUL/truncation-tolerant shape `lib/fleet.sh`'s own readers use,
# rather than `jq -s` straight over the file: a union log a peer's node ran
# `fleet_repair_log` on before this one deployed it, or one holding a line
# from a in-flight write, can still carry one unparseable line, and a single
# bad line must cost this one event, never the whole reduction.
disk_space_largest_footprint() {
  jq -Rc 'fromjson? // empty' 2>/dev/null \
    | jq -rs '[.[] | select(.event == "clone-footprint" and (.bytes | type) == "number" and (.repo // "") != "")]
              | max_by(.bytes) | if . == null then empty else "\(.bytes)\t\(.repo)" end' \
      2>/dev/null || true
}

# disk_space_effective_min_bytes FLOOR_BYTES FACTOR LARGEST_BYTES
# The threshold requirement 2.0c actually gates on (agent-ops#904, the
# residual of #756): `max(FLOOR_BYTES, FACTOR × LARGEST_BYTES)`. FLOOR_BYTES
# (`min_free_workspace_bytes`) is the floor *under* this derivation, never a
# ceiling. A non-numeric or absent FACTOR or LARGEST_BYTES — no footprint has
# ever been recorded, or the factor is off — derives nothing, and the floor
# alone governs, the same as a `0` FACTOR would.
disk_space_effective_min_bytes() {
  local floor="${1:-0}" factor="${2:-0}" largest="${3:-}" derived
  [[ "$floor" =~ ^[0-9]+$ ]] || floor=0
  [[ "$factor" =~ ^[0-9]+$ ]] || factor=0
  if [[ "$largest" =~ ^[0-9]+$ ]] && (( factor > 0 )); then
    derived=$(( factor * largest ))
    if (( derived > floor )); then
      printf '%s' "$derived"
      return 0
    fi
  fi
  printf '%s' "$floor"
}

# disk_space_governed_by FLOOR_BYTES EFFECTIVE_BYTES
# "floor" when disk_space_effective_min_bytes did not raise the threshold
# above FLOOR_BYTES (including when it had nothing to derive from), "derived"
# when it did — the one-word tag the stand-down event and doctor.sh's warning
# both carry, so a reader can tell which bound governed without re-deriving
# it themselves.
disk_space_governed_by() {
  local floor="${1:-0}" effective="${2:-0}"
  [[ "$floor" =~ ^[0-9]+$ ]] || floor=0
  [[ "$effective" =~ ^[0-9]+$ ]] || effective=0
  if (( effective > floor )); then
    printf 'derived'
  else
    printf 'floor'
  fi
}
