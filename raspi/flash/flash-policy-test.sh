#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
source "$ROOT/raspi/system/card-layout.env"
source "$ROOT/raspi/flash/flash-policy.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fixture() {
  cat > "$1" <<EOF
{"DeviceIdentifier":"${2:-disk4}","WholeDisk":${3:-true},"Internal":${4:-false},"RemovableMedia":${5:-true},"Writable":${6:-true},"TotalSize":${7:-64000000000}}
EOF
}
eligible="$TMP/eligible.json"
fixture "$eligible"
validate_flash_target "$eligible" disk4 disk0
confirmed_disk disk4 disk4

for case in wrong internal fixed readonly small system; do
  file="$TMP/$case.json"
  case "$case" in
    wrong) fixture "$file" disk5 ;;
    internal) fixture "$file" disk4 true true ;;
    fixed) fixture "$file" disk4 true false false ;;
    readonly) fixture "$file" disk4 true false true false ;;
    small) fixture "$file" disk4 true false true true "$((DANCAM_MIN_CARD_BYTES - 1))" ;;
    system) fixture "$file" disk0 ;;
  esac
  system=disk0
  [ "$case" = system ] || system=disk0
  if validate_flash_target "$file" disk4 "$system" >/dev/null 2>&1; then
    echo "expected $case target rejection" >&2
    exit 1
  fi
done
if confirmed_disk disk5 disk4 >/dev/null 2>&1; then
  echo "expected mismatched confirmation rejection" >&2
  exit 1
fi
echo "flash policy tests passed"
