#!/usr/bin/env bash
# raspi/scripts/partition-card.sh -- split a freshly flashed Pi card into the
# dancam boot/root/persist/data layout. Geometry and filesystems only: fstab,
# mounts, directories, and ownership belong to the Ansible playbook.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
LAYOUT="$SCRIPT_DIR/../system/card-layout.env"
[ -f "$LAYOUT" ] || LAYOUT="$SCRIPT_DIR/card-layout.env"
source "$LAYOUT"

DEVICE="/dev/mmcblk0"
ALIGN_SECTORS=$DANCAM_ALIGN_SECTORS
MIN_TOTAL_SECTORS=$DANCAM_MIN_TOTAL_SECTORS
ROOT_SIZE_SECTORS=$DANCAM_DEVELOPMENT_ROOT_SIZE_SECTORS
PERSIST_SIZE_SECTORS=$DANCAM_DEVELOPMENT_PERSIST_SIZE_SECTORS
DEFAULT_P2_START=1056768
PERSIST_LABEL=$DANCAM_PERSIST_LABEL
DATA_LABEL=$DANCAM_DATA_LABEL

DRY_RUN=0
TOTAL_SECTORS=""
P2_START_ARG=""

usage() {
  cat <<EOF
Usage: sudo bash raspi/scripts/partition-card.sh [--dry-run]
       bash raspi/scripts/partition-card.sh --dry-run --total-sectors N [--p2-start S]

Partitions ${DEVICE} into:
  p1 existing FAT boot partition, unchanged
  p2 8 GiB ext4 root, grown online from the flashed image
  p3 1 GiB ext4 /persist, label ${PERSIST_LABEL}
  p4 rest minus about 5% tail, ext4 /data, label ${DATA_LABEL}

--total-sectors uses the hardware-free math seam and never touches a device.
EOF
}

die() {
  echo "partition-card: $*" >&2
  exit 1
}

is_uint() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

align_up() {
  local value="$1"
  echo $(( ((value + ALIGN_SECTORS - 1) / ALIGN_SECTORS) * ALIGN_SECTORS ))
}

align_down() {
  local value="$1"
  echo $(( (value / ALIGN_SECTORS) * ALIGN_SECTORS ))
}

require_uint() {
  local name="$1"
  local value="$2"
  is_uint "$value" || die "${name} must be a non-negative integer"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    --total-sectors)
      shift
      [ "$#" -gt 0 ] || die "--total-sectors requires a value"
      TOTAL_SECTORS="$1"
      ;;
    --p2-start)
      shift
      [ "$#" -gt 0 ] || die "--p2-start requires a value"
      P2_START_ARG="$1"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
  shift
done

[ -z "$P2_START_ARG" ] || require_uint "--p2-start" "$P2_START_ARG"
[ -z "$TOTAL_SECTORS" ] || require_uint "--total-sectors" "$TOTAL_SECTORS"
[ -z "$P2_START_ARG" ] || [ -n "$TOTAL_SECTORS" ] || die "--p2-start requires --total-sectors"

compute_layout() {
  local total="$1"
  local p2_start="$2"
  local p2_end
  local p3_end
  local p4_limit

  [ "$total" -ge "$MIN_TOTAL_SECTORS" ] || die "card has ${total} 512-byte sectors; dancam requires a 32 GB or larger high-endurance microSD (at least ${MIN_TOTAL_SECTORS} sectors)"
  [ $((p2_start % ALIGN_SECTORS)) -eq 0 ] || die "root partition start ${p2_start} is not 4 MiB-aligned; reflash via README"

  P2_START="$p2_start"
  P2_SIZE="$ROOT_SIZE_SECTORS"
  p2_end=$((P2_START + P2_SIZE))
  P3_START="$(align_up "$p2_end")"
  P3_SIZE="$PERSIST_SIZE_SECTORS"
  p3_end=$((P3_START + P3_SIZE))
  P4_START="$(align_up "$p3_end")"
  p4_limit="$(align_down "$((total * DANCAM_DATA_PERCENT / 100))")"
  P4_SIZE=$((p4_limit - P4_START))
  TAIL_SECTORS=$((total - p4_limit))

  [ "$P4_SIZE" -gt 0 ] || die "card is too small after fixed boot/root/persist partitions"
}

print_sfdisk_plan() {
  cat <<EOF
# dancam partition layout for ${DEVICE}
# total-sectors=${TOTAL_SECTORS}
# p2 start=${P2_START} size=${P2_SIZE}
# p3 start=${P3_START} size=${P3_SIZE}
# p4 start=${P4_START} size=${P4_SIZE}
# unpartitioned-tail-sectors=${TAIL_SECTORS}
# sfdisk -N 2 --no-reread ${DEVICE}
,${P2_SIZE},L
# sfdisk --append --no-reread ${DEVICE}
${P3_START},${P3_SIZE},L
${P4_START},${P4_SIZE},L
EOF
}

partition_line() {
  local dump="$1"
  local part="$2"
  printf '%s\n' "$dump" | awk -v part="${DEVICE}p${part}" '$1 == part && $2 == ":" { print; exit }'
}

partition_field() {
  local dump="$1"
  local part="$2"
  local field="$3"
  local line
  local value

  line="$(partition_line "$dump" "$part")"
  [ -n "$line" ] || die "${DEVICE}p${part} was not found in the partition table"
  value="$(printf '%s\n' "$line" | sed -E "s/.*${field}= *([0-9]+).*/\\1/")"
  is_uint "$value" || die "could not parse ${field} for ${DEVICE}p${part}"
  echo "$value"
}

partition_count() {
  local dump="$1"
  printf '%s\n' "$dump" | awk -v device="$DEVICE" 'index($1, device "p") == 1 && $2 == ":" { count++ } END { print count + 0 }'
}

labels_resolve() {
  blkid -L "$PERSIST_LABEL" >/dev/null 2>&1 && blkid -L "$DATA_LABEL" >/dev/null 2>&1
}

apply_layout() {
  local root_part="${DEVICE}p2"
  local persist_part="${DEVICE}p3"
  local data_part="${DEVICE}p4"

  print_sfdisk_plan

  echo "==> resizing ${root_part} to 8 GiB"
  printf ',%s,L\n' "$P2_SIZE" | sfdisk -N 2 --no-reread "$DEVICE"
  partx -u -n 2 "$DEVICE"
  resize2fs "$root_part"

  echo "==> appending ${persist_part} and ${data_part}"
  printf '%s,%s,L\n%s,%s,L\n' "$P3_START" "$P3_SIZE" "$P4_START" "$P4_SIZE" |
    sfdisk --append --no-reread "$DEVICE"
  if ! partx -u "$DEVICE"; then
    partx -a -n 3:4 "$DEVICE"
  fi
  if [ ! -b "$persist_part" ] || [ ! -b "$data_part" ]; then
    partx -a -n 3:4 "$DEVICE"
  fi
  if command -v udevadm >/dev/null 2>&1; then
    udevadm settle
  fi
  [ -b "$persist_part" ] || die "${persist_part} did not appear after partition table update"
  [ -b "$data_part" ] || die "${data_part} did not appear after partition table update"

  echo "==> creating ext4 filesystems"
  mkfs.ext4 -F -L "$PERSIST_LABEL" -E lazy_itable_init=0,lazy_journal_init=0 "$persist_part"
  mkfs.ext4 -F -L "$DATA_LABEL" -E lazy_itable_init=0,lazy_journal_init=0 "$data_part"

  echo "==> partitioning complete; fstab, mounts, and directories are provisioned later"
}

if [ -n "$TOTAL_SECTORS" ]; then
  P2_START_ARG="${P2_START_ARG:-$DEFAULT_P2_START}"
  compute_layout "$TOTAL_SECTORS" "$P2_START_ARG"
  print_sfdisk_plan
  exit 0
fi

[ "$EUID" -eq 0 ] || die "must run as root on the Pi; use: sudo bash /tmp/dancam-partition-card.sh"
[ -b "$DEVICE" ] || die "expected ${DEVICE}; this script only partitions the Pi microSD card"

DUMP="$(sfdisk --dump "$DEVICE")"
LABEL="$(printf '%s\n' "$DUMP" | awk -F': ' '$1 == "label" { print $2; exit }')"
[ "$LABEL" = "dos" ] || die "expected ${DEVICE} to use an MBR/dos partition table; found '${LABEL:-unknown}'"

if [ "$(partition_count "$DUMP")" -eq 4 ] && labels_resolve; then
  echo "partition-card: ${DEVICE} already has 4 partitions and labels ${PERSIST_LABEL}/${DATA_LABEL}; nothing to do"
  exit 0
fi

TOTAL_SECTORS="$(blockdev --getsz "$DEVICE")"
[ "$TOTAL_SECTORS" -ge "$MIN_TOTAL_SECTORS" ] || die "card has ${TOTAL_SECTORS} 512-byte sectors; dancam requires a 32 GB or larger high-endurance microSD (at least ${MIN_TOTAL_SECTORS} sectors)"
[ "$(partition_count "$DUMP")" -eq 2 ] || die "${DEVICE} is not the freshly flashed 2-partition image; reflash via README before partitioning"
P2_CURRENT_SIZE="$(partition_field "$DUMP" 2 size)"
[ "$P2_CURRENT_SIZE" -le "$ROOT_SIZE_SECTORS" ] || die "root already expanded -- reflash via README before running just raspi-partition"
compute_layout "$TOTAL_SECTORS" "$(partition_field "$DUMP" 2 start)"

if [ "$DRY_RUN" -eq 1 ]; then
  print_sfdisk_plan
  exit 0
fi

apply_layout
