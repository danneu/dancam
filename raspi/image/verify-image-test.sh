#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
source "$ROOT/raspi/image/verify-image.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p \
  "$TMP/etc/NetworkManager/system-connections" \
  "$TMP/persist/nm/system-connections" \
  "$TMP/persist/dancam" \
  "$TMP/boot/firmware/dancam" \
  "$TMP/data/rec/state" \
  "$TMP/root" "$TMP/home" "$TMP/usr/local"

CMDLINE="$TMP/boot/firmware/cmdline.txt"
printf '%s\n' \
  'console=tty1 root=PARTUUID=041bba91-02 cloud-init=disabled cfg80211.ieee80211_regdom=US' \
  > "$CMDLINE"
verify_boot_command_line "$CMDLINE" 041bba91-02 US
printf '%s\n' \
  'root=PARTUUID=041bba91-02 cloud-init=disabled cloud-init=disabled cfg80211.ieee80211_regdom=US' \
  > "$CMDLINE"
if verify_boot_command_line "$CMDLINE" 041bba91-02 US >/dev/null 2>&1; then
  echo 'duplicate boot command-line token passed release inspection' >&2
  exit 1
fi
printf '%s\n' \
  'root=PARTUUID=041bba91-02 cloud-init=disabled cfg80211.ieee80211_regdom=US\n' \
  > "$CMDLINE"
if verify_boot_command_line "$CMDLINE" 041bba91-02 US >/dev/null 2>&1; then
  echo 'literal newline escape passed release inspection' >&2
  exit 1
fi

verify_absent_release_state "$TMP"
touch "$TMP/persist/dancam/storage-admitted"
if verify_absent_release_state "$TMP" >/dev/null 2>&1; then
  echo 'planted storage-admission marker passed release inspection' >&2
  exit 1
fi

printf '%s\n' 'production image verifier tests passed'
