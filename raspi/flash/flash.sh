#!/usr/bin/env bash
# Authenticate, write, personalize, verify, and eject one removable DanCam card.
set -euo pipefail
umask 077

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
source "$ROOT/raspi/system/card-layout.env"
source "$ROOT/raspi/flash/flash-policy.sh"
die() { echo "raspi-flash: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "missing required tool: $1"; }
for tool in diskutil minisign zstd shasum openssl swift swiftc; do need "$tool"; done

RESUME=${DANCAM_FLASH_RESUME:-0}
case "$RESUME" in
  0|1) ;;
  *) die "DANCAM_FLASH_RESUME must be 0 or 1" ;;
esac

MANIFEST=${1:-}
if [ -z "$MANIFEST" ] && [ -d "$ROOT/dist" ]; then
  MANIFEST=$(select_latest_release_manifest "$ROOT/dist")
fi
[ -f "$MANIFEST" ] || die "pass a released .manifest.json path or place one in dist/"
SIGNATURE="$MANIFEST.minisig"
PUBLIC_KEY=${DANCAM_IMAGE_PUBLIC_KEY:-"$ROOT/raspi/image/release.pub"}
[ -f "$SIGNATURE" ] || die "missing manifest signature: $SIGNATURE"
[ -f "$PUBLIC_KEY" ] || die "missing release public key: $PUBLIC_KEY"

# Authentication is deliberately complete before media discovery or mutation.
minisign -Vm "$MANIFEST" -p "$PUBLIC_KEY" >/dev/null
ARTIFACT_NAME=$(/usr/bin/plutil -extract artifact raw -o - "$MANIFEST")
ARTIFACT="$(dirname "$MANIFEST")/$ARTIFACT_NAME"
EXPECTED_ARTIFACT_SHA=$(/usr/bin/plutil -extract artifact_sha256 raw -o - "$MANIFEST")
EXPECTED_RAW_SHA=$(/usr/bin/plutil -extract raw_sha256 raw -o - "$MANIFEST")
RAW_SIZE=$(manifest_raw_size "$MANIFEST") || die "manifest raw_size is not a positive integer"
IMAGE_ID=$(/usr/bin/plutil -extract image_id raw -o - "$MANIFEST")
[ -f "$ARTIFACT" ] || die "missing authenticated image: $ARTIFACT"
[ "$(shasum -a 256 "$ARTIFACT" | awk '{print $1}')" = "$EXPECTED_ARTIFACT_SHA" ] || die "image digest mismatch"

diskutil list external physical
if [ "$RESUME" = 1 ]; then
  read -r -p "Whole removable disk to verify and repair (for example disk4): " DISK
else
  read -r -p "Whole removable disk to erase (for example disk4): " DISK
fi
[[ "$DISK" =~ ^disk[0-9]+$ ]] || die "enter a whole disk identifier such as disk4"
SYSTEM_DISK=$(diskutil info -plist / | /usr/bin/plutil -extract ParentWholeDisk raw -o - -)
INFO=$(mktemp)
TRANSFER_DIR=$(mktemp -d)
TRANSFER="$TRANSFER_DIR/media-transfer"
swiftc "$ROOT/raspi/flash/media-transfer.swift" -o "$TRANSFER"
trap 'rm -f "$INFO"; rm -rf "$TRANSFER_DIR"' EXIT
diskutil info -plist "/dev/$DISK" > "$INFO"
validate_flash_target "$INFO" "$DISK" "$SYSTEM_DISK" || exit 1
IDENTITY=$(swift "$ROOT/raspi/flash/media-identity.swift" "$DISK")
[[ "$IDENTITY" == *:1:1 ]] || die "I/O Registry does not classify $DISK as whole and writable"

if [ "$RESUME" = 1 ]; then
  echo "VERIFY, REPAIR, AND COMPLETE /dev/$DISK ($(plist_value "$INFO" MediaName), $(plist_value "$INFO" TotalSize) bytes)"
  read -r -p "Type $DISK to approve comparison, bounded repair, and personalization: " CONFIRM
else
  echo "ERASE /dev/$DISK ($(plist_value "$INFO" MediaName), $(plist_value "$INFO" TotalSize) bytes)"
  read -r -p "Type $DISK to approve this erase: " CONFIRM
fi
confirmed_disk "$CONFIRM" "$DISK" || exit 1

same_media() {
  [ "$(swift "$ROOT/raspi/flash/media-identity.swift" "$DISK")" = "$IDENTITY" ] || die "approved media disappeared or was replaced"
}
same_media
echo "Unmounting /dev/$DISK..."
diskutil unmountDisk "/dev/$DISK" >/dev/null
same_media
if [ "$RESUME" = 1 ]; then
  echo "Comparing with the authenticated image; at most 64 MiB of differing chunks may be repaired."
  transfer_authenticated_image repair-verify \
    "$ARTIFACT" "$TRANSFER" "$DISK" "$IDENTITY" "$RAW_SIZE" "$EXPECTED_RAW_SHA"
else
  echo "Writing authenticated image to /dev/$DISK..."
  transfer_authenticated_image write-verify \
    "$ARTIFACT" "$TRANSFER" "$DISK" "$IDENTITY" "$RAW_SIZE" "$EXPECTED_RAW_SHA"
fi
same_media

echo "Personalizing card..."
diskutil mountDisk "/dev/$DISK" >/dev/null
same_media
BOOT_MOUNT=$(diskutil info -plist "/dev/${DISK}s1" | /usr/bin/plutil -extract MountPoint raw -o - -)
[ -d "$BOOT_MOUNT" ] || die "written boot partition did not mount"
RECOVERY_DIR=${DANCAM_RECOVERY_DIR:-"$PWD"}
UNIT_ID=$(swift "$ROOT/raspi/flash/make-personalization.swift" "$IMAGE_ID" "$BOOT_MOUNT" "$RECOVERY_DIR")
ENVELOPE_SHA=$(shasum -a 256 "$BOOT_MOUNT/dancam/commissioning.json" | awk '{print $1}')
diskutil unmountDisk "/dev/$DISK" >/dev/null
same_media
diskutil mountDisk "/dev/$DISK" >/dev/null
BOOT_MOUNT=$(diskutil info -plist "/dev/${DISK}s1" | /usr/bin/plutil -extract MountPoint raw -o - -)
[ "$(shasum -a 256 "$BOOT_MOUNT/dancam/commissioning.json" | awk '{print $1}')" = "$ENVELOPE_SHA" ] || die "personalization readback verification failed"
same_media
echo "Personalization verified; ejecting /dev/$DISK..."
diskutil eject "/dev/$DISK" >/dev/null
echo "DanCam card $UNIT_ID verified and ejected. Setup QR and recovery record: $RECOVERY_DIR"
