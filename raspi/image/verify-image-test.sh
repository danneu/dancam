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

verify_absent_release_state "$TMP"
touch "$TMP/persist/dancam/storage-admitted"
if verify_absent_release_state "$TMP" >/dev/null 2>&1; then
  echo 'planted storage-admission marker passed release inspection' >&2
  exit 1
fi

printf '%s\n' 'production image verifier tests passed'
