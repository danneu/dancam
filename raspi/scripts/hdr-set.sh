#!/usr/bin/env bash
# raspi/scripts/hdr-set.sh -- toggle IMX708 on-sensor HDR while dancam is closed.
set -euo pipefail

usage() {
  echo "usage: hdr-set.sh on|off" >&2
}

die() {
  echo "hdr-set: $*" >&2
  exit 1
}

case "${1:-}" in
  on) VALUE=1 ;;
  off) VALUE=0 ;;
  *)
    usage
    exit 1
    ;;
esac
[ "$#" -eq 1 ] || { usage; exit 1; }

command -v v4l2-ctl >/dev/null 2>&1 || die "v4l2-ctl is required; provision the Pi with just raspi-provision"

# The override is a hardware-free test seam; production uses the kernel sysfs tree.
SYSFS_ROOT="${DANCAM_V4L_SYSFS_ROOT:-/sys/class/video4linux}"
SUBDEV=""
for name_file in "$SYSFS_ROOT"/v4l-subdev*/name; do
  [ -f "$name_file" ] || continue
  if grep -Eq '^imx708' "$name_file"; then
    SUBDEV="/dev/$(basename "$(dirname "$name_file")")"
    break
  fi
done
[ -n "$SUBDEV" ] || die "IMX708 sensor subdevice not found; is the camera detected?"

cleanup() {
  local rc=$?
  trap - EXIT
  trap '' INT TERM HUP

  if ! systemctl start dancam; then
    echo "ERROR: dancam failed to start after HDR toggle -- recording is DOWN; restart it manually" >&2
    exit 1
  fi

  local deadline=$((SECONDS + ${DANCAM_HEALTH_TIMEOUT:-60}))
  local status
  while :; do
    status="$(curl -fsS --max-time 5 "http://localhost:${DANCAM_PORT:-8080}/v1/status" 2>/dev/null || true)"
    if grep -Eq '"camera_state"[[:space:]]*:[[:space:]]*"running"' <<<"$status"; then
      exit "$rc"
    fi
    if (( SECONDS >= deadline )); then
      echo "ERROR: dancam camera did not reach running after HDR toggle -- recording is DOWN; check journalctl -u dancam" >&2
      exit 1
    fi
    sleep 1
  done
}

signal_exit() {
  exit "$1"
}

trap cleanup EXIT
trap 'signal_exit 130' INT
trap 'signal_exit 143' TERM
trap 'signal_exit 129' HUP

systemctl stop dancam
v4l2-ctl -d "$SUBDEV" --set-ctrl "wide_dynamic_range=$VALUE"
v4l2-ctl -d "$SUBDEV" --get-ctrl wide_dynamic_range
