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

echo "image build policy tests passed"
