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
printf 'nameserver 192.0.2.1\n' > "$TMP/source-resolv.conf"
umask 077
install_temporary_resolver "$TMP/source-resolv.conf" "$TMP/target-resolv.conf"
cmp "$TMP/source-resolv.conf" "$TMP/target-resolv.conf"
[ "$(find "$TMP/target-resolv.conf" -perm 0644 -print)" = "$TMP/target-resolv.conf" ]

echo "image build policy tests passed"
