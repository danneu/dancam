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

release_dir="$TMP/releases"
mkdir "$release_dir"
legacy_manifest="$release_dir/dancam-20260720-aaaaaaaaaaaa.img.zst.manifest.json"
compact_manifest="$release_dir/dancam-20260720T000000Z-aaaaaaaaaaaa-0000.img.zst.manifest.json"
printf '{"raw_size":10737418240}\n' > "$legacy_manifest"
printf '{"raw_size":5511315456}\n' > "$compact_manifest"
[ "$(select_latest_release_manifest "$release_dir")" = "$compact_manifest" ]
[ "$(manifest_raw_size "$legacy_manifest")" -eq 10737418240 ]
[ "$(manifest_raw_size "$compact_manifest")" -eq 5511315456 ]

development_dir="$TMP/development"
mkdir "$development_dir"
development_manifest="$development_dir/dancam-development.img.zst.manifest.json"
printf '{}\n' > "$development_manifest"
[ "$(select_only_development_manifest "$development_dir")" = "$development_manifest" ]
printf '{}\n' > "$development_dir/dancam-second.img.zst.manifest.json"
if select_only_development_manifest "$development_dir" >/dev/null 2>&1; then
  echo 'multiple development manifests were accepted' >&2
  exit 1
fi

zstd() {
  [ "$1" = -dc ]
  printf 'authenticated image bytes'
}
sudo() {
  printf '%s\n' "$*" >> "$DANCAM_FLASH_TEST_TRANSFER_LOG"
  cat >/dev/null
}
export DANCAM_FLASH_TEST_TRANSFER_LOG="$TMP/transfer.log"
: > "$DANCAM_FLASH_TEST_TRANSFER_LOG"
transfer_authenticated_image write-verify image.zst media-transfer disk4 identity \
  "$(manifest_raw_size "$legacy_manifest")" legacy-sha
transfer_authenticated_image repair-verify image.zst media-transfer disk4 identity \
  "$(manifest_raw_size "$compact_manifest")" compact-sha
grep -Fq 'media-transfer write-verify disk4 identity 10737418240 legacy-sha' \
  "$DANCAM_FLASH_TEST_TRANSFER_LOG"
grep -Fq 'media-transfer repair-verify disk4 identity 5511315456 compact-sha' \
  "$DANCAM_FLASH_TEST_TRANSFER_LOG"
echo "flash policy tests passed"
