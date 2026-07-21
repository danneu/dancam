#!/usr/bin/env bash
# Build a generic, complete DanCam production image in an aarch64 Linux builder.
set -euo pipefail
umask 077

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
source "$ROOT/raspi/image/inputs.env"
source "$ROOT/raspi/image/build-policy.sh"
source "$ROOT/raspi/image/build-convergence.sh"
source "$ROOT/raspi/system/card-layout.env"
export DANCAM_REPOSITORY_ROOT="$ROOT"

die() { echo "raspi-image: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "missing required tool: $1"; }

[ "$(uname -s)" = Linux ] || die "image assembly requires controlled Linux; flashing is the macOS path"
[ "$(uname -m)" = aarch64 ] || die "image assembly requires aarch64 Linux so target packages execute natively"
[ "${EUID}" -eq 0 ] || die "run image assembly as root inside the disposable builder"
[[ "$DANCAM_WIFI_COUNTRY" =~ ^[A-Z]{2}$ ]] || die "DANCAM_WIFI_COUNTRY must be a two-letter uppercase country code"

for tool in ansible-playbook curl sha256sum xz losetup sfdisk partprobe e2fsck resize2fs mkfs.ext4 mount umount chroot zstd minisign jq; do need "$tool"; done

REV=$(git -C "$ROOT" rev-parse HEAD)
git -C "$ROOT" diff --quiet || die "tracked source changes must be committed before an image build"
git -C "$ROOT" diff --cached --quiet || die "staged source changes must be committed before an image build"
VERSION=${DANCAM_IMAGE_VERSION:-"$(date -u +%Y%m%d)-${REV:0:12}"}
IMAGE_ID=$(printf '%s:%s:%s' "$DANCAM_OS_RELEASE" "$REV" "$VERSION" | sha256sum | cut -c1-32)
OUT=${DANCAM_IMAGE_OUT:-"$ROOT/dist"}
SIGNING_KEY=${DANCAM_IMAGE_SIGNING_KEY:-}
SERVICE_BINARY=${DANCAM_SERVICE_BINARY:-}
[ -n "$SIGNING_KEY" ] || die "DANCAM_IMAGE_SIGNING_KEY must name the minisign secret key"
[ -x "$SERVICE_BINARY" ] || die "DANCAM_SERVICE_BINARY must name an executable aarch64 dancam binary"
mkdir -p "$OUT"

WORK=$(mktemp -d)
LOOP=
cleanup() {
  set +e
  mountpoint -q "$WORK/root/data" && umount "$WORK/root/data"
  mountpoint -q "$WORK/root/persist" && umount "$WORK/root/persist"
  mountpoint -q "$WORK/root/dev" && umount -R "$WORK/root/dev"
  mountpoint -q "$WORK/root/sys" && umount -R "$WORK/root/sys"
  mountpoint -q "$WORK/root/proc" && umount "$WORK/root/proc"
  mountpoint -q "$WORK/root/boot/firmware" && umount "$WORK/root/boot/firmware"
  mountpoint -q "$WORK/root" && umount "$WORK/root"
  [ -z "$LOOP" ] || losetup -d "$LOOP"
  rm -rf "$WORK"
}
trap cleanup EXIT

BASE="$WORK/base.img.xz"
curl --fail --location --proto '=https' --tlsv1.2 "$DANCAM_OS_IMAGE_URL" -o "$BASE"
echo "$DANCAM_OS_IMAGE_SHA256  $BASE" | sha256sum --check --status || die "Raspberry Pi OS digest mismatch"

RAW="$WORK/dancam-${VERSION}.img"
xz --decompress --stdout "$BASE" > "$RAW"
BASE_PARTITIONS=$(sfdisk --json "$RAW")
DISK_ID=$(jq -er '.partitiontable.id' <<<"$BASE_PARTITIONS")
ROOT_PARTUUID=$(dos_partition_uuid "$DISK_ID" 2) || die "base image has an invalid DOS label id"
P1_START=$(jq -er '.partitiontable.partitions[0].start' <<<"$BASE_PARTITIONS")
P1_SIZE=$(jq -er '.partitiontable.partitions[0].size' <<<"$BASE_PARTITIONS")
P2_START=$(jq -er '.partitiontable.partitions[1].start' <<<"$BASE_PARTITIONS")
[ "$P1_SIZE" -eq "$DANCAM_BOOT_SIZE_SECTORS" ] || die "base image boot partition is not 512 MiB"
[ $((P1_START % DANCAM_ALIGN_SECTORS)) -eq 0 ] || die "base image boot partition is not 4 MiB-aligned"
read -r P2_END P3_START P3_END P4_START RAW_END_SECTOR < <(
  calculate_partition_geometry \
    "$P2_START" \
    "$DANCAM_PRODUCTION_ROOT_SIZE_SECTORS" \
    "$DANCAM_PRODUCTION_PERSIST_SIZE_SECTORS" \
    "$DANCAM_PRODUCTION_INITIAL_DATA_SIZE_SECTORS" \
    "$DANCAM_ALIGN_SECTORS"
) || die "base image root partition is not valid production geometry"
P4_SIZE=$DANCAM_PRODUCTION_INITIAL_DATA_SIZE_SECTORS
truncate -s "$((RAW_END_SECTOR * 512))" "$RAW"
LOOP=$(losetup --find --show --partscan "$RAW")

cat <<EOF | sfdisk --no-reread --force "$LOOP"
label: dos
label-id: $DISK_ID
unit: sectors

start=$P1_START, size=$P1_SIZE, type=c, bootable
start=$P2_START, size=$((P2_END-P2_START+1)), type=83
start=$P3_START, size=$((P3_END-P3_START+1)), type=83
start=$P4_START, size=$P4_SIZE, type=83
EOF
partprobe "$LOOP"
udevadm settle
wait_for_paths 100 0.1 "${LOOP}p1" "${LOOP}p2" "${LOOP}p3" "${LOOP}p4" \
  || die "partition device nodes did not appear"
for partition in 1 2 3 4; do
  [ -b "${LOOP}p${partition}" ] || die "partition device is not a block device: ${LOOP}p${partition}"
done
e2fsck -fy "${LOOP}p2"
resize2fs "${LOOP}p2"
mkfs.ext4 -F -L "$DANCAM_PERSIST_LABEL" -E lazy_itable_init=0,lazy_journal_init=0 "${LOOP}p3"
mkfs.ext4 -F -L "$DANCAM_DATA_LABEL" -E lazy_itable_init=0,lazy_journal_init=0 "${LOOP}p4"

mkdir -p "$WORK/root"
mount "${LOOP}p2" "$WORK/root"
mkdir -p "$WORK/root/boot/firmware"
# FAT does not persist Unix modes. Present stable 0755 modes during convergence
# instead of inheriting this script's restrictive release-artifact umask.
mount -o umask=0022 "${LOOP}p1" "$WORK/root/boot/firmware"
mkdir -p "$WORK/root/persist" "$WORK/root/data"
mount "${LOOP}p3" "$WORK/root/persist"
mount "${LOOP}p4" "$WORK/root/data"
mkdir -p "$WORK/root/proc" "$WORK/root/sys" "$WORK/root/dev"
mount -t proc proc "$WORK/root/proc"
mount --rbind /sys "$WORK/root/sys"
mount --make-rslave "$WORK/root/sys"
mount --rbind /dev "$WORK/root/dev"
mount --make-rslave "$WORK/root/dev"

# Package convergence needs the builder's DNS only while the chroot is active.
# Restore the base image's resolver artifact before release inspection.
cp -a "$WORK/root/etc/resolv.conf" "$WORK/base-resolv.conf"
rm -f "$WORK/root/etc/resolv.conf"
install_temporary_resolver /etc/resolv.conf "$WORK/root/etc/resolv.conf"

run_production_convergence \
  "$WORK/root" "$SERVICE_BINARY" "$IMAGE_ID" "$ROOT_PARTUUID" \
  "$DANCAM_WIFI_COUNTRY" "$DANCAM_PERSIST_LABEL" "$DANCAM_DATA_LABEL"

rm -f "$WORK/root/etc/resolv.conf"
cp -a "$WORK/base-resolv.conf" "$WORK/root/etc/resolv.conf"

bash "$ROOT/raspi/image/verify-image.sh" \
  "$WORK/root" "$IMAGE_ID" "$ROOT_PARTUUID" "$DANCAM_WIFI_COUNTRY" \
  "$DANCAM_PERSIST_LABEL" "$DANCAM_DATA_LABEL"

PACKAGE_INVENTORY="$OUT/dancam-${VERSION}.packages.txt"
chroot "$WORK/root" /usr/bin/dpkg-query -W -f='${binary:Package}\t${Version}\n' | sort > "$PACKAGE_INVENTORY"
PACKAGE_INVENTORY_SHA=$(sha256sum "$PACKAGE_INVENTORY" | cut -d' ' -f1)
sync
umount "$WORK/root/data"
umount "$WORK/root/persist"
umount -R "$WORK/root/dev"
umount -R "$WORK/root/sys"
umount "$WORK/root/proc"
umount "$WORK/root/boot/firmware"
umount "$WORK/root"
losetup -d "$LOOP"
LOOP=

RAW_SIZE=$(stat -c %s "$RAW")
RAW_SHA=$(sha256sum "$RAW" | cut -d' ' -f1)
ARTIFACT="$OUT/dancam-${VERSION}.img.zst"
zstd -19 --threads=0 "$RAW" -o "$ARTIFACT"
ARTIFACT_SHA=$(sha256sum "$ARTIFACT" | cut -d' ' -f1)

jq -n \
  --arg schema "dancam-image-manifest-v1" \
  --arg version "$VERSION" \
  --arg image_id "$IMAGE_ID" \
  --arg artifact "$(basename "$ARTIFACT")" \
  --arg artifact_sha256 "$ARTIFACT_SHA" \
  --arg raw_sha256 "$RAW_SHA" \
  --argjson raw_size "$RAW_SIZE" \
  --arg os_release "$DANCAM_OS_RELEASE" \
  --arg os_sha256 "$DANCAM_OS_IMAGE_SHA256" \
  --arg repository_revision "$REV" \
  --arg package_inventory "$(basename "$PACKAGE_INVENTORY")" \
  --arg package_inventory_sha256 "$PACKAGE_INVENTORY_SHA" \
  '{schema:$schema,version:$version,image_id:$image_id,artifact:$artifact,artifact_sha256:$artifact_sha256,raw_sha256:$raw_sha256,raw_size:$raw_size,os_release:$os_release,os_sha256:$os_sha256,repository_revision:$repository_revision,package_inventory:$package_inventory,package_inventory_sha256:$package_inventory_sha256}' \
  > "$ARTIFACT.manifest.json"
minisign -Sm "$ARTIFACT.manifest.json" -s "$SIGNING_KEY"
echo "built $ARTIFACT"
