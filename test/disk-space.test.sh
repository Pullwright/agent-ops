#!/usr/bin/env bash
#
# test/disk-space.test.sh — regression test for lib/disk-space.sh
# (agent-ops#756): the pure free-space arithmetic doctor.sh's advisory
# warning and agent-cycle.sh's pre-clone stand-down gate (requirement 2.0c)
# share, so the two cannot silently disagree about what "low" means.
#
# test/disk-space-wiring.test.sh covers whether the cycle actually acts on
# these functions' verdicts; this file covers only the functions themselves,
# against a stubbed `df` so no assertion depends on this host's real free
# space.
#
# No test framework is used (none exists elsewhere in this repo); this is a
# plain bash script with hand-rolled assertions. Run it directly:
#
#   ./test/disk-space.test.sh
#
# Exit status is 0 iff every assertion passed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/disk-space.sh
. "$SCRIPT_DIR/lib/disk-space.sh"

failures=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok   - %s\n' "$desc"
  else
    printf 'FAIL - %s (expected %q, got %q)\n' "$desc" "$expected" "$actual"
    failures=$(( failures + 1 ))
  fi
}

stub_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir"' EXIT

# stub_df AVAIL_KB — a `df -Pk` stand-in printing a well-formed two-line
# response whose only figure that matters is the fourth (Available) column,
# the same one the real `df -Pk` reports it at.
stub_df() {
  cat > "$stub_dir/df" <<EOF
#!/usr/bin/env bash
printf 'Filesystem 1024-blocks Used Available Capacity Mounted\n'
printf '/dev/sda1 1000000 1 %s 1%% /\n' "$1"
EOF
  chmod +x "$stub_dir/df"
  PATH="$stub_dir:$PATH"
}

# missing_df — a `df` that always fails, the way an unreadable meter looks.
missing_df() {
  cat > "$stub_dir/df" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$stub_dir/df"
  PATH="$stub_dir:$PATH"
}

# --- disk_space_free_kb -----------------------------------------------------

stub_df 5000000
assert_eq "disk_space_free_kb reads the Available column" \
  "5000000" "$(disk_space_free_kb /some/path)"

missing_df
assert_eq "disk_space_free_kb is empty when df fails, never 0" \
  "" "$(disk_space_free_kb /some/path)"

assert_eq "disk_space_free_kb is empty for an empty path" \
  "" "$(disk_space_free_kb '')"

# --- disk_space_verdict ------------------------------------------------------
# min_bytes is converted to KiB (min_bytes / 1024) for the comparison.

assert_eq "verdict is low when free KiB is below the floor" \
  "low" "$(disk_space_verdict 1000 2097152000)"   # 1000 KiB free, floor ~2 GiB
assert_eq "verdict is ok when free KiB meets the floor exactly" \
  "ok" "$(disk_space_verdict 2048000 2097152000)" # 2048000 KiB == floor/1024
assert_eq "verdict is ok when free KiB is above the floor" \
  "ok" "$(disk_space_verdict 3000000 2097152000)"
assert_eq "verdict is ok when the floor is 0 (check off), however low free space is" \
  "ok" "$(disk_space_verdict 0 0)"
assert_eq "verdict is ok when free KiB is unreadable (empty) — no evidence of a full disk" \
  "ok" "$(disk_space_verdict '' 2097152000)"
assert_eq "verdict is ok when free KiB is non-numeric" \
  "ok" "$(disk_space_verdict 'unknown' 2097152000)"
assert_eq "verdict is low at exactly zero free KiB with a floor set" \
  "low" "$(disk_space_verdict 0 2097152000)"

# --- disk_space_same_filesystem ----------------------------------------------

same_fs_dir_a="$(mktemp -d)"
same_fs_dir_b="$(mktemp -d)"
trap 'rm -rf "$stub_dir" "$same_fs_dir_a" "$same_fs_dir_b"' EXIT

if disk_space_same_filesystem "$same_fs_dir_a" "$same_fs_dir_b"; then
  assert_eq "same_filesystem is true for two directories on the host's own filesystem" "yes" "yes"
else
  assert_eq "same_filesystem is true for two directories on the host's own filesystem" "yes" "no"
fi

if disk_space_same_filesystem "$same_fs_dir_a" "$same_fs_dir_a"; then
  assert_eq "same_filesystem is true for one path compared with itself" "yes" "yes"
else
  assert_eq "same_filesystem is true for one path compared with itself" "yes" "no"
fi

if disk_space_same_filesystem "$same_fs_dir_a" "/nonexistent-path-$$"; then
  assert_eq "same_filesystem is false when a path's device id cannot be read" "no" "yes"
else
  assert_eq "same_filesystem is false when a path's device id cannot be read" "no" "no"
fi

if disk_space_same_filesystem '' "$same_fs_dir_a"; then
  assert_eq "same_filesystem is false for an empty path" "no" "yes"
else
  assert_eq "same_filesystem is false for an empty path" "no" "no"
fi

# --- disk_space_describe -----------------------------------------------------

desc="$(disk_space_describe /data/workspace 1024000 2147483648)"
assert_eq "describe names the path" \
  "yes" "$(if [[ "$desc" == "/data/workspace "* ]]; then echo yes; else echo no; fi)"
assert_eq "describe states the free MiB (1024000 KiB = 1000 MiB)" \
  "yes" "$(if [[ "$desc" == *"1000 MiB free"* ]]; then echo yes; else echo no; fi)"
assert_eq "describe states the floor in MiB (2147483648 bytes = 2048 MiB)" \
  "yes" "$(if [[ "$desc" == *"2048 MiB this cycle needs"* ]]; then echo yes; else echo no; fi)"
assert_eq "describe's trailing clause serves both state_dir and workspace_root" \
  "yes" "$(if [[ "$desc" == *"a cycle writes its clone, its records and its state mirror before it can finish" ]]; then echo yes; else echo no; fi)"

# --- disk_space_describe naming which bound governed (agent-ops#904) --------

desc_derived="$(disk_space_describe /data/workspace 1024000 4294967296 derived owner/big-repo 2147483648 2)"
assert_eq "describe (derived): names the derived MiB figure" \
  "yes" "$(if [[ "$desc_derived" == *"4096 MiB ("* ]]; then echo yes; else echo no; fi)"
assert_eq "describe (derived): names the factor and repository" \
  "yes" "$(if [[ "$desc_derived" == *"2x owner/big-repo's"* ]]; then echo yes; else echo no; fi)"
assert_eq "describe (derived): names the footprint's own MiB figure (2147483648 bytes = 2048 MiB)" \
  "yes" "$(if [[ "$desc_derived" == *"2048 MiB recorded clone"* ]]; then echo yes; else echo no; fi)"
assert_eq "describe (derived): trailing clause is unchanged" \
  "yes" "$(if [[ "$desc_derived" == *"a cycle writes its clone, its records and its state mirror before it can finish" ]]; then echo yes; else echo no; fi)"

desc_floor_explicit="$(disk_space_describe /data/workspace 1024000 2147483648 floor)"
assert_eq "describe (governed_by floor, explicit): byte-for-byte the plain-floor sentence" \
  "$desc" "$desc_floor_explicit"

# --- disk_space_clone_footprint_bytes ----------------------------------------

footprint_dir="$(mktemp -d)"
trap 'rm -rf "$stub_dir" "$same_fs_dir_a" "$same_fs_dir_b" "$footprint_dir"' EXIT
printf '%s' "0123456789" > "$footprint_dir/file"
assert_eq "clone_footprint_bytes reads a real directory's size in bytes" \
  "yes" "$(if [[ "$(disk_space_clone_footprint_bytes "$footprint_dir")" =~ ^[0-9]+$ ]]; then echo yes; else echo no; fi)"
assert_eq "clone_footprint_bytes is empty for a path that does not exist" \
  "" "$(disk_space_clone_footprint_bytes "/nonexistent-path-$$")"
assert_eq "clone_footprint_bytes is empty for an empty path" \
  "" "$(disk_space_clone_footprint_bytes '')"

# --- disk_space_largest_footprint --------------------------------------------

footprint_line="$(printf '%s\n' \
  '{"ts":"2026-01-01T00:00:00Z","event":"other-event","bytes":999999999}' \
  '{"ts":"2026-01-01T00:00:01Z","event":"clone-footprint","repo":"owner/small","bytes":1000}' \
  '{"ts":"2026-01-01T00:00:02Z","event":"clone-footprint","repo":"owner/big","bytes":5000000}' \
  '{"ts":"2026-01-01T00:00:03Z","event":"clone-footprint","repo":"owner/mid","bytes":2000}' \
  | disk_space_largest_footprint)"
assert_eq "largest_footprint picks the biggest clone-footprint event, ignoring other events" \
  "5000000	owner/big" "$footprint_line"

assert_eq "largest_footprint is empty when the log has no clone-footprint event" \
  "" "$(printf '%s\n' '{"event":"other-event"}' | disk_space_largest_footprint)"
assert_eq "largest_footprint is empty for an empty log" \
  "" "$(printf '' | disk_space_largest_footprint)"
assert_eq "largest_footprint ignores a clone-footprint event with a non-numeric bytes field" \
  "" "$(printf '%s\n' '{"event":"clone-footprint","repo":"owner/x","bytes":"oops"}' | disk_space_largest_footprint)"
assert_eq "largest_footprint ignores a clone-footprint event with no repo" \
  "" "$(printf '%s\n' '{"event":"clone-footprint","bytes":1000}' | disk_space_largest_footprint)"
assert_eq "largest_footprint tolerates an unparseable line rather than failing the whole read" \
  "1000	owner/x" "$(printf '%s\n' 'not json' '{"event":"clone-footprint","repo":"owner/x","bytes":1000}' | disk_space_largest_footprint)"

# --- disk_space_effective_min_bytes ------------------------------------------

assert_eq "effective_min_bytes: floor alone governs when no footprint is given" \
  "2147483648" "$(disk_space_effective_min_bytes 2147483648 2 '')"
assert_eq "effective_min_bytes: floor alone governs when the factor is 0" \
  "2147483648" "$(disk_space_effective_min_bytes 2147483648 0 5000000000)"
assert_eq "effective_min_bytes: floor alone governs when the derivation does not exceed it" \
  "2147483648" "$(disk_space_effective_min_bytes 2147483648 2 1000)"
assert_eq "effective_min_bytes: the derivation governs once it exceeds the floor" \
  "4294967296" "$(disk_space_effective_min_bytes 2147483648 2 2147483648)"
assert_eq "effective_min_bytes: exactly at the floor is still floor-governed (never below the floor)" \
  "2147483648" "$(disk_space_effective_min_bytes 2147483648 1 2147483648)"
assert_eq "effective_min_bytes: a non-numeric floor reads as 0" \
  "10000" "$(disk_space_effective_min_bytes bogus 2 5000)"
assert_eq "effective_min_bytes: a non-numeric largest derives nothing, the floor governs" \
  "2147483648" "$(disk_space_effective_min_bytes 2147483648 2 bogus)"

# --- disk_space_governed_by ---------------------------------------------------

assert_eq "governed_by is \"floor\" when the effective threshold equals the floor" \
  "floor" "$(disk_space_governed_by 2147483648 2147483648)"
assert_eq "governed_by is \"derived\" when the effective threshold exceeds the floor" \
  "derived" "$(disk_space_governed_by 2147483648 4294967296)"
assert_eq "governed_by is \"floor\" for a non-numeric effective value (reads as 0, never above the floor)" \
  "floor" "$(disk_space_governed_by 2147483648 bogus)"

echo
if (( failures == 0 )); then
  echo "All disk-space assertions passed."
  exit 0
else
  echo "$failures disk-space assertion(s) FAILED."
  exit 1
fi
