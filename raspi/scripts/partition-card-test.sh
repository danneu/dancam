#!/usr/bin/env bash
# raspi/scripts/partition-card-test.sh -- hardware-free layout regression for
# partition-card.sh. Runs on macOS; no sfdisk, root, or card required.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../system/card-layout.env"
ALIGN_SECTORS=$DANCAM_ALIGN_SECTORS
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cp "$SCRIPT_DIR/partition-card.sh" "$TMP/dancam-partition-card.sh"
cp "$SCRIPT_DIR/../system/card-layout.env" "$TMP/card-layout.env"
PARTITION_SCRIPT="$TMP/dancam-partition-card.sh"

fail() {
  echo "partition-card-test: $*" >&2
  exit 1
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "expected output to contain: $needle" ;;
  esac
}

layout_for() {
  local total="$1"
  bash "$PARTITION_SCRIPT" --dry-run --total-sectors "$total"
}

summary_value() {
  local output="$1"
  local key="$2"
  printf '%s\n' "$output" | awk -F= -v key="# ${key}" '$1 == key { print $2; exit }'
}

partition_start() {
  local output="$1"
  local part="$2"
  printf '%s\n' "$output" |
    awk -v part="$part" '$1 == "#" && $2 == part {
      for (i = 3; i <= NF; i++) {
        if ($i ~ /^start=/) {
          sub(/^start=/, "", $i)
          print $i
          exit
        }
      }
    }'
}

assert_aligned_starts() {
  local output="$1"
  local part
  local start

  for part in p2 p3 p4; do
    start="$(partition_start "$output" "$part")"
    [ -n "$start" ] || fail "missing ${part} start"
    [ $((start % ALIGN_SECTORS)) -eq 0 ] || fail "${part} start ${start} is not 8192-sector aligned"
  done
}

assert_tail_near_five_percent() {
  local output="$1"
  local total="$2"
  local tail
  local basis_points

  tail="$(summary_value "$output" "unpartitioned-tail-sectors")"
  [ -n "$tail" ] || fail "missing tail sector summary"
  basis_points=$((tail * 10000 / total))
  [ "$basis_points" -ge 490 ] || fail "tail ${tail}/${total} is under 4.90%"
  [ "$basis_points" -le 510 ] || fail "tail ${tail}/${total} is over 5.10%"
}

assert_layout() {
  local total="$1"
  local p4_size="$2"
  local tail="$3"
  local output

  output="$(layout_for "$total")"

  assert_contains "$output" "# p2 start=1056768 size=16777216"
  assert_contains "$output" "# p3 start=17833984 size=2097152"
  assert_contains "$output" "# p4 start=19931136 size=${p4_size}"
  assert_contains "$output" "# unpartitioned-tail-sectors=${tail}"
  assert_contains "$output" ",16777216,L"
  assert_contains "$output" "17833984,2097152,L"
  assert_contains "$output" "19931136,${p4_size},L"
  assert_aligned_starts "$output"
  assert_tail_near_five_percent "$output" "$total"
}

assert_minimum_size_guard() {
  local output
  local status

  set +e
  output="$(bash "$PARTITION_SCRIPT" --dry-run --total-sectors "$((DANCAM_MIN_TOTAL_SECTORS - 1))" 2>&1)"
  status="$?"
  set -e

  [ "$status" -ne 0 ] || fail "expected sub-32 GB cards to be refused"
  assert_contains "$output" "requires a 32 GB or larger high-endurance microSD"
}

assert_layout 62500000 39436288 3132576
assert_layout 125000000 98811904 6256960
assert_layout 250000000 217563136 12505728
assert_layout 500000000 455065600 25003264
assert_minimum_size_guard

echo "partition-card layout tests OK"
