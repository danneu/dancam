#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
source "$ROOT/raspi/image/build-policy.sh"

[ "$(dos_partition_uuid 0x041BBA91 2)" = 041bba91-02 ]
[ "$(dos_partition_uuid d245d549 4)" = d245d549-04 ]

for bad in 0x123 bad-id 0x123456789; do
  if dos_partition_uuid "$bad" 2 >/dev/null 2>&1; then
    echo "invalid DOS label id was accepted: $bad" >&2
    exit 1
  fi
done
if dos_partition_uuid 0x041bba91 0 >/dev/null 2>&1; then
  echo "invalid partition number was accepted" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/etc"
printf '127.0.0.1\tlocalhost\n127.0.1.1\traspberrypi\n' > "$TMP/etc/hosts"
configure_hostname "$TMP" dancam
[ "$(cat "$TMP/etc/hostname")" = dancam ]
[ "$(grep '^127\.0\.1\.1' "$TMP/etc/hosts")" = $'127.0.1.1\tdancam' ]
[ "$(grep -c '^127\.0\.1\.1' "$TMP/etc/hosts")" -eq 1 ]

printf '127.0.0.1\tlocalhost\n' > "$TMP/etc/hosts"
configure_hostname "$TMP" dancam
[ "$(tail -n 1 "$TMP/etc/hosts")" = $'127.0.1.1\tdancam' ]

for bad in DANCAM dancam.local -dancam dancam-; do
  if configure_hostname "$TMP" "$bad" >/dev/null 2>&1; then
    echo "invalid hostname was accepted: $bad" >&2
    exit 1
  fi
done

echo "image build policy tests passed"
