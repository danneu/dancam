#!/usr/bin/env bash
# raspi/scripts/reset-data.sh -- safely wipe recording data and restart dancam.
set -euo pipefail

die() {
  echo "ABORT: $*; refusing to touch ${REC_DIR}" >&2
  exit 1
}

DATA_DIR="${DANCAM_DATA_DIR:-/data}"
REC_DIR="${DATA_DIR}/rec"

[ -d "$DATA_DIR" ] || die "${DATA_DIR} missing or not a directory"
data_dev="$(stat -c %d "$DATA_DIR")" || die "cannot stat ${DATA_DIR}"
root_dev="$(stat -c %d /)" || die "cannot stat /"
data_ino="$(stat -c %i "$DATA_DIR")" || die "cannot stat ${DATA_DIR}"
root_ino="$(stat -c %i /)" || die "cannot stat /"
if [ "$data_dev" = "$root_dev" ] && [ "$data_ino" != "$root_ino" ]; then
  die "${DATA_DIR} is not a mounted filesystem (same device as /)"
fi

cleanup() {
  local status=$?
  trap - EXIT

  if ! systemctl start dancam; then
    echo "ERROR: dancam failed to start after reset -- recording is DOWN; restart it manually" >&2
    exit 1
  fi

  # Type=exec: systemctl start returns once the binary execs, not once it serves.
  # A clean reset is complete only when recording can start again.
  local deadline=$(( $(date +%s) + ${DANCAM_RECORDING_READINESS_TIMEOUT:-60} ))
  local status_body
  while :; do
    status_body="$(curl -fsS --max-time 5 "http://localhost:${DANCAM_PORT:-8080}/v1/status" 2>/dev/null || true)"
    if python3 -c 'import json, sys; value = json.load(sys.stdin).get("recording_readiness", {}).get("ready"); sys.exit(0 if value is True else 1)' <<<"$status_body" 2>/dev/null; then
      break
    fi
    if (( $(date +%s) >= deadline )); then
      echo "ERROR: dancam did not become recording-ready after restart -- recording is DOWN; check journalctl -u dancam" >&2
      exit 1
    fi
    sleep 2
  done

  exit "$status"
}

# Install cleanup before stopping the service so every exit path restarts it.
trap cleanup EXIT

systemctl stop dancam
find "$REC_DIR" -mindepth 1 -delete
