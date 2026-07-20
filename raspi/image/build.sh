#!/usr/bin/env bash
# Build a generic, complete DanCam production image in an aarch64 Linux builder.
set -euo pipefail
umask 077

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
source "$ROOT/raspi/image/inputs.env"
source "$ROOT/raspi/image/build-policy.sh"
source "$ROOT/raspi/system/card-layout.env"

die() { echo "raspi-image: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "missing required tool: $1"; }

[ "$(uname -s)" = Linux ] || die "image assembly requires controlled Linux; flashing is the macOS path"
[ "$(uname -m)" = aarch64 ] || die "image assembly requires aarch64 Linux so target packages execute natively"
[ "${EUID}" -eq 0 ] || die "run image assembly as root inside the disposable builder"
[[ "$DANCAM_WIFI_COUNTRY" =~ ^[A-Z]{2}$ ]] || die "DANCAM_WIFI_COUNTRY must be a two-letter uppercase country code"

for tool in curl sha256sum xz losetup sfdisk partprobe e2fsck resize2fs mkfs.ext4 mount umount chroot zstd minisign jq; do need "$tool"; done

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
  mountpoint -q "$WORK/persist" && umount "$WORK/persist"
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
truncate -s 10737418240 "$RAW"
LOOP=$(losetup --find --show --partscan "$RAW")

DISK_ID=$(sfdisk --json "$LOOP" | jq -er '.partitiontable.id')
ROOT_PARTUUID=$(dos_partition_uuid "$DISK_ID" 2) || die "base image has an invalid DOS label id"
P1_START=$(sfdisk --json "$LOOP" | jq -r '.partitiontable.partitions[0].start')
P1_SIZE=$(sfdisk --json "$LOOP" | jq -r '.partitiontable.partitions[0].size')
P2_START=$(sfdisk --json "$LOOP" | jq -r '.partitiontable.partitions[1].start')
P2_END=$((P2_START + DANCAM_ROOT_SIZE_SECTORS - 1))
P3_START=$(( ((P2_END + 1 + DANCAM_ALIGN_SECTORS - 1) / DANCAM_ALIGN_SECTORS) * DANCAM_ALIGN_SECTORS ))
P3_END=$((P3_START + DANCAM_PERSIST_SIZE_SECTORS - 1))
P4_START=$(( ((P3_END + 1 + DANCAM_ALIGN_SECTORS - 1) / DANCAM_ALIGN_SECTORS) * DANCAM_ALIGN_SECTORS ))
P4_SIZE=$DANCAM_INITIAL_DATA_SIZE_SECTORS

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
e2fsck -fy "${LOOP}p2"
resize2fs "${LOOP}p2"
mkfs.ext4 -F -L "$DANCAM_PERSIST_LABEL" -E lazy_itable_init=0,lazy_journal_init=0 "${LOOP}p3"
mkfs.ext4 -F -L "$DANCAM_DATA_LABEL" -E lazy_itable_init=0,lazy_journal_init=0 "${LOOP}p4"

mkdir -p "$WORK/root"
mount "${LOOP}p2" "$WORK/root"
mkdir -p "$WORK/root/boot/firmware"
mount "${LOOP}p1" "$WORK/root/boot/firmware"
mkdir -p "$WORK/root/proc" "$WORK/root/sys" "$WORK/root/dev"
mount -t proc proc "$WORK/root/proc"
mount --rbind /sys "$WORK/root/sys"
mount --make-rslave "$WORK/root/sys"
mount --rbind /dev "$WORK/root/dev"
mount --make-rslave "$WORK/root/dev"

install -Dm755 "$SERVICE_BINARY" "$WORK/root/usr/local/bin/dancam"
install -Dm755 "$ROOT/raspi/camera/camera.py" "$WORK/root/usr/local/lib/dancam/camera.py"
install -Dm755 "$ROOT/raspi/image/commission.sh" "$WORK/root/usr/local/lib/dancam/commission.sh"
install -Dm755 "$ROOT/raspi/image/commission-policy.sh" "$WORK/root/usr/local/lib/dancam/commission-policy.sh"
install -Dm644 "$ROOT/raspi/system/card-layout.env" "$WORK/root/usr/local/lib/dancam/card-layout.env"
install -Dm755 "$ROOT/raspi/image/commission-led.sh" "$WORK/root/usr/local/lib/dancam/commission-led.sh"
install -Dm644 "$ROOT/raspi/dancam.service" "$WORK/root/etc/systemd/system/dancam.service"
install -Dm644 "$ROOT/raspi/image/dancam-commission.service" "$WORK/root/etc/systemd/system/dancam-commission.service"
install -Dm644 "$ROOT/raspi/image/dancam-commission-led.service" "$WORK/root/etc/systemd/system/dancam-commission-led.service"
sed "s/@DANCAM_DATA_LABEL@/$DANCAM_DATA_LABEL/" "$ROOT/raspi/image/data.mount.in" \
  > "$WORK/root/etc/systemd/system/data.mount"
chmod 644 "$WORK/root/etc/systemd/system/data.mount"
mkdir -p "$WORK/root/etc/systemd/system/dancam.service.d"
cat > "$WORK/root/etc/systemd/system/dancam.service.d/production.conf" <<'EOF'
[Service]
Environment=DANCAM_COMMISSIONING_STATE_PATH=/persist/dancam/commissioning.json
EOF
mkdir -p "$WORK/root/boot/firmware/dancam"
jq -n --arg schema dancam-image-marker-v1 --arg image_id "$IMAGE_ID" \
  '{schema:$schema,image_id:$image_id}' > "$WORK/root/boot/firmware/dancam/image.json"

cp /etc/resolv.conf "$WORK/root/etc/resolv.conf"
export DANCAM_PYTHON3_PICAMERA2_VERSION DANCAM_PYTHON3_AV_VERSION DANCAM_FFMPEG_VERSION DANCAM_JQ_VERSION
chroot "$WORK/root" /bin/bash -eux <<'CHROOT'
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  "python3-picamera2=$DANCAM_PYTHON3_PICAMERA2_VERSION" \
  "python3-av=$DANCAM_PYTHON3_AV_VERSION" \
  "ffmpeg=$DANCAM_FFMPEG_VERSION" \
  "jq=$DANCAM_JQ_VERSION"
useradd --system --no-create-home --groups video dancam || true
systemctl enable dancam.service dancam-commission.service dancam-commission-led.service fstrim.timer
systemctl mask apt-daily.timer apt-daily-upgrade.timer man-db.timer dpkg-db-backup.timer unattended-upgrades.service
systemctl mask cloud-init.target cloud-init-local.service cloud-init-network.service cloud-config.service cloud-final.service cloud-init-hotplugd.socket
rm -rf /var/lib/apt/lists/*
CHROOT

mkdir -p \
  "$WORK/root/etc/NetworkManager/system-connections" \
  "$WORK/root/var/lib/NetworkManager" \
  "$WORK/root/var/lib/systemd/timesync" \
  "$WORK/root/var/log/journal" \
  "$WORK/root/etc/systemd/journald.conf.d" \
  "$WORK/root/etc/systemd/system.conf.d" \
  "$WORK/root/etc/sysctl.d"
cat > "$WORK/root/etc/systemd/journald.conf.d/60-dancam-persistent.conf" <<'EOF'
[Journal]
Storage=persistent
SystemMaxUse=200M
SyncIntervalSec=60s
EOF
cat > "$WORK/root/etc/systemd/system.conf.d/60-dancam-watchdog.conf" <<'EOF'
[Manager]
RuntimeWatchdogSec=60s
EOF
cat > "$WORK/root/etc/sysctl.d/60-dancam-writeback.conf" <<'EOF'
vm.dirty_background_bytes=16777216
vm.dirty_bytes=67108864
EOF
sed -i 's/^#\?allow-interfaces=.*/allow-interfaces=wlan0/' "$WORK/root/etc/avahi/avahi-daemon.conf"

sed -i 's/^camera_auto_detect=.*/camera_auto_detect=0/' "$WORK/root/boot/firmware/config.txt"
grep -qxF 'dtoverlay=imx708' "$WORK/root/boot/firmware/config.txt" || echo 'dtoverlay=imx708' >> "$WORK/root/boot/firmware/config.txt"
sed -i -E 's/(^| )resize( |$)/ /g; s/  +/ /g; s/^ //; s/ $//' "$WORK/root/boot/firmware/cmdline.txt"
sed -i 's/$/ cloud-init=disabled/' "$WORK/root/boot/firmware/cmdline.txt"
grep -qw "root=PARTUUID=$ROOT_PARTUUID" "$WORK/root/boot/firmware/cmdline.txt" || \
  die "boot root PARTUUID does not match the preserved DOS label id"
grep -qw "cfg80211.ieee80211_regdom=$DANCAM_WIFI_COUNTRY" "$WORK/root/boot/firmware/cmdline.txt" || \
  sed -i "s/$/ cfg80211.ieee80211_regdom=$DANCAM_WIFI_COUNTRY/" "$WORK/root/boot/firmware/cmdline.txt"
: > "$WORK/root/etc/machine-id"
cat > "$WORK/root/etc/fstab" <<EOF
proc /proc proc defaults 0 0
LABEL=bootfs /boot/firmware vfat ro,noatime 0 2
LABEL=rootfs / ext4 ro,noatime,errors=remount-ro 0 1
LABEL=$DANCAM_PERSIST_LABEL /persist ext4 noatime,errors=remount-ro,nofail,x-systemd.device-timeout=10s 0 2
/persist/nm/system-connections /etc/NetworkManager/system-connections none bind,nofail 0 0
/persist/nm/var-lib /var/lib/NetworkManager none bind,nofail 0 0
/persist/timesync /var/lib/systemd/timesync none bind,nofail 0 0
/persist/journal /var/log/journal none bind,nofail 0 0
/persist/machine-id /etc/machine-id none bind,nofail 0 0
tmpfs /tmp tmpfs rw,nosuid,nodev,noatime,mode=1777,size=64M 0 0
tmpfs /var/log tmpfs rw,nosuid,nodev,noatime,mode=0755,size=32M 0 0
EOF
mkdir -p "$WORK/root/persist" "$WORK/root/data" "$WORK/root/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/dancam-commission.service "$WORK/root/etc/systemd/system/multi-user.target.wants/dancam-commission.service"
mkdir -p "$WORK/root/etc/systemd/system/local-fs.target.wants"
ln -sf /etc/systemd/system/data.mount "$WORK/root/etc/systemd/system/local-fs.target.wants/data.mount"

mkdir -p "$WORK/persist"
mount "${LOOP}p3" "$WORK/persist"
install -d -m 755 "$WORK/persist/dancam" "$WORK/persist/nm" "$WORK/persist/nm/var-lib" "$WORK/persist/timesync" "$WORK/persist/journal"
install -d -m 700 "$WORK/persist/nm/system-connections"
printf '%s\n' '{"state":"preparing","reason":null}' > "$WORK/persist/dancam/commissioning.json"
chmod 644 "$WORK/persist/dancam/commissioning.json"
timesync_uid=$(awk -F: '$1 == "systemd-timesync" { print $3 }' "$WORK/root/etc/passwd")
timesync_gid=$(awk -F: '$1 == "systemd-timesync" { print $4 }' "$WORK/root/etc/passwd")
chown "$timesync_uid:$timesync_gid" "$WORK/persist/timesync"
sync -f "$WORK/persist/dancam/commissioning.json"
sync -f "$WORK/persist/dancam"
umount "$WORK/persist"

PACKAGE_INVENTORY="$OUT/dancam-${VERSION}.packages.txt"
chroot "$WORK/root" /usr/bin/dpkg-query -W -f='${binary:Package}\t${Version}\n' | sort > "$PACKAGE_INVENTORY"
PACKAGE_INVENTORY_SHA=$(sha256sum "$PACKAGE_INVENTORY" | cut -d' ' -f1)
sync
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
