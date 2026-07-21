#!/usr/bin/env bash
# Build/authenticate, write, personalize, verify, and eject one DanCam card.
set -euo pipefail
umask 077

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
source "$ROOT/raspi/system/card-layout.env"
source "$ROOT/raspi/flash/flash-policy.sh"
die() { echo "raspi-flash: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "missing required tool: $1"; }

[ "$#" -ge 1 ] && [ "$#" -le 2 ] || die "usage: just raspi-flash production [manifest] | just raspi-flash dev"
REQUESTED_PROFILE=$1
PROFILE=$(flash_profile "$REQUESTED_PROFILE") || die "unknown flash profile: $REQUESTED_PROFILE"
MANIFEST=${2:-}
RESUME=${DANCAM_FLASH_RESUME:-0}
case "$RESUME" in 0|1) ;; *) die "DANCAM_FLASH_RESUME must be 0 or 1" ;; esac
[ "$PROFILE" = production ] || [ -z "$MANIFEST" ] || die "development flashing does not accept a manifest"
[ "$PROFILE" = production ] || [ "$RESUME" = 0 ] || die "development flashing cannot be resumed; start a fresh flash"

for tool in diskutil shasum swift swiftc zstd; do need "$tool"; done

development_credentials_json() {
  DEVELOPMENT_LOGIN_USER="$DEVELOPMENT_LOGIN_USER" \
  DEVELOPMENT_AUTHORIZED_KEY="$DEVELOPMENT_AUTHORIZED_KEY" \
    jq -n '{
      login_user:env.DEVELOPMENT_LOGIN_USER,
      authorized_key:env.DEVELOPMENT_AUTHORIZED_KEY,
      home_wifi_ssid:env.DANCAM_HOME_WIFI_SSID,
      home_wifi_psk:env.DANCAM_HOME_WIFI_PSK,
      access_point_psk:env.DANCAM_DEV_AP_PSK
    }'
}

if [ "$PROFILE" = development ]; then
  need jq
  need ssh-keygen
  [ -n "${DANCAM_HOST:-}" ] || die "set DANCAM_HOST to login-user@host"
  [[ "$DANCAM_HOST" == *@* ]] || die "DANCAM_HOST must be login-user@host"
  DEVELOPMENT_LOGIN_USER=${DANCAM_HOST%%@*}
  [ -n "${DANCAM_SSH_KEY:-}" ] || die "set DANCAM_SSH_KEY to the private SSH key"
  SSH_KEY=${DANCAM_SSH_KEY/#\~/$HOME}
  [ -f "$SSH_KEY" ] || die "DANCAM_SSH_KEY does not name a file"
  DEVELOPMENT_AUTHORIZED_KEY=$(ssh-keygen -y -f "$SSH_KEY" 2>/dev/null) || die "could not derive the SSH public key"
  : "${DANCAM_HOME_WIFI_SSID:?set DANCAM_HOME_WIFI_SSID}"
  : "${DANCAM_HOME_WIFI_PSK:?set DANCAM_HOME_WIFI_PSK}"
  : "${DANCAM_DEV_AP_PSK:?set DANCAM_DEV_AP_PSK}"

  # Exercise the exact envelope validator before building or discovering media.
  PREFLIGHT_DIR=$(mktemp -d)
  trap 'rm -rf "$PREFLIGHT_DIR"' EXIT
  development_credentials_json | swift \
    "$ROOT/raspi/flash/make-development-personalization.swift" \
    preflight-image "$PREFLIGHT_DIR" || die "invalid development credentials"
  rm -rf "$PREFLIGHT_DIR"
  trap - EXIT

  DEVELOPMENT_OUT_ROOT="$ROOT/.dancam-development-image"
  mkdir -p "$DEVELOPMENT_OUT_ROOT"
  DEVELOPMENT_OUT=$(mktemp -d "$DEVELOPMENT_OUT_ROOT/flash.XXXXXX")
  echo "Building a fresh development image from current tracked source..."
  DEVELOPMENT_IMAGE_BUILDER="$ROOT/raspi/image/build-orbstack.sh"
  if [ "${DANCAM_FLASH_TEST_MODE:-0}" = 1 ]; then
    DEVELOPMENT_IMAGE_BUILDER=${DANCAM_FLASH_TEST_DEVELOPMENT_IMAGE_BUILDER:-$DEVELOPMENT_IMAGE_BUILDER}
  elif [ -n "${DANCAM_FLASH_TEST_DEVELOPMENT_IMAGE_BUILDER:-}" ]; then
    die "test image builder override requires DANCAM_FLASH_TEST_MODE=1"
  fi
  DANCAM_IMAGE_OUT="$DEVELOPMENT_OUT" bash "$DEVELOPMENT_IMAGE_BUILDER" development
  MANIFEST=$(select_only_development_manifest "$DEVELOPMENT_OUT") || die "development build did not produce exactly one manifest"
else
  need minisign
  if [ -z "$MANIFEST" ] && [ -d "$ROOT/dist" ]; then
    MANIFEST=$(select_latest_release_manifest "$ROOT/dist")
  fi
  [ -f "$MANIFEST" ] || die "pass a released .manifest.json path or place one in dist/"
  SIGNATURE="$MANIFEST.minisig"
  PUBLIC_KEY=${DANCAM_IMAGE_PUBLIC_KEY:-"$ROOT/raspi/image/release.pub"}
  [ -f "$SIGNATURE" ] || die "missing manifest signature: $SIGNATURE"
  [ -f "$PUBLIC_KEY" ] || die "missing release public key: $PUBLIC_KEY"
  minisign -Vm "$MANIFEST" -p "$PUBLIC_KEY" >/dev/null
fi

SCHEMA=$(/usr/bin/plutil -extract schema raw -o - "$MANIFEST")
if [ "$PROFILE" = production ]; then
  [ "$SCHEMA" = dancam-image-manifest-v1 ] || die "authenticated manifest has the wrong schema"
else
  [ "$SCHEMA" = dancam-development-image-manifest-v1 ] || die "development manifest has the wrong schema"
  [ "$(/usr/bin/plutil -extract profile raw -o - "$MANIFEST")" = development ] || die "development manifest has the wrong profile"
fi
ARTIFACT_NAME=$(/usr/bin/plutil -extract artifact raw -o - "$MANIFEST")
[ "$(basename "$ARTIFACT_NAME")" = "$ARTIFACT_NAME" ] || die "manifest artifact must be a basename"
ARTIFACT="$(dirname "$MANIFEST")/$ARTIFACT_NAME"
EXPECTED_ARTIFACT_SHA=$(/usr/bin/plutil -extract artifact_sha256 raw -o - "$MANIFEST")
EXPECTED_RAW_SHA=$(/usr/bin/plutil -extract raw_sha256 raw -o - "$MANIFEST")
RAW_SIZE=$(manifest_raw_size "$MANIFEST") || die "manifest raw_size is not a positive integer"
IMAGE_ID=$(/usr/bin/plutil -extract image_id raw -o - "$MANIFEST")
[ -f "$ARTIFACT" ] || die "missing image: $ARTIFACT"
[ "$(shasum -a 256 "$ARTIFACT" | awk '{print $1}')" = "$EXPECTED_ARTIFACT_SHA" ] || die "image digest mismatch"

# Authentication/build and development credential validation are deliberately
# complete before this first removable-media query.
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
  transfer_authenticated_image repair-verify "$ARTIFACT" "$TRANSFER" "$DISK" "$IDENTITY" "$RAW_SIZE" "$EXPECTED_RAW_SHA"
else
  echo "Writing $REQUESTED_PROFILE image to /dev/$DISK..."
  transfer_authenticated_image write-verify "$ARTIFACT" "$TRANSFER" "$DISK" "$IDENTITY" "$RAW_SIZE" "$EXPECTED_RAW_SHA"
fi
same_media

echo "Personalizing card..."
diskutil mountDisk "/dev/$DISK" >/dev/null
same_media
BOOT_MOUNT=$(diskutil info -plist "/dev/${DISK}s1" | /usr/bin/plutil -extract MountPoint raw -o - -)
[ -d "$BOOT_MOUNT" ] || die "written boot partition did not mount"
if [ "$PROFILE" = production ]; then
  RECOVERY_DIR=${DANCAM_RECOVERY_DIR:-"$PWD"}
  UNIT_ID=$(swift "$ROOT/raspi/flash/make-personalization.swift" "$IMAGE_ID" "$BOOT_MOUNT" "$RECOVERY_DIR")
else
  development_credentials_json | swift \
    "$ROOT/raspi/flash/make-development-personalization.swift" "$IMAGE_ID" "$BOOT_MOUNT"
fi
ENVELOPE_SHA=$(shasum -a 256 "$BOOT_MOUNT/dancam/commissioning.json" | awk '{print $1}')
diskutil unmountDisk "/dev/$DISK" >/dev/null
same_media
diskutil mountDisk "/dev/$DISK" >/dev/null
BOOT_MOUNT=$(diskutil info -plist "/dev/${DISK}s1" | /usr/bin/plutil -extract MountPoint raw -o - -)
[ "$(shasum -a 256 "$BOOT_MOUNT/dancam/commissioning.json" | awk '{print $1}')" = "$ENVELOPE_SHA" ] || die "personalization readback verification failed"
same_media
echo "Personalization verified; ejecting /dev/$DISK..."
diskutil eject "/dev/$DISK" >/dev/null
if [ "$PROFILE" = production ]; then
  echo "DanCam card $UNIT_ID verified and ejected. Setup QR and recovery record: $RECOVERY_DIR"
else
  echo "DanCam development card verified and ejected."
fi
