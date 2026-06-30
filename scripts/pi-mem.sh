#!/usr/bin/env bash
# scripts/pi-mem.sh -- report what's using the camera unit's RAM: overall split,
# top processes by resident memory, the GPU/CMA reservations, and swap usage.
# Useful for spotting leaks (a process that grows over time) or confirming the box
# is healthy. The Pi Zero 2 W only has 512MB, so this is worth checking often.
set -euo pipefail

HOST="${DANCAM_HOST:-pi@dancam.local}"
SSH_KEY="${DANCAM_SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_KEY="${SSH_KEY/#\~/$HOME}"

echo "==> memory report from $HOST"
ssh -i "$SSH_KEY" "$HOST" '
  set -eu
  echo "===== free -h ====="
  free -h
  echo
  echo "===== top 15 processes by resident memory ====="
  ps axo pid,ppid,%mem,rss,comm --sort=-%mem | head -16
  echo
  echo "===== GPU / CMA reservations ====="
  # arm/gpu split is carved out by the firmware before Linux boots; CMA is the
  # contiguous DMA pool the camera pipeline allocates buffers from.
  vcgencmd get_mem arm 2>/dev/null || echo "vcgencmd unavailable"
  vcgencmd get_mem gpu 2>/dev/null || true
  grep -i cma /proc/meminfo
  echo
  echo "===== swap ====="
  cat /proc/swaps
'
