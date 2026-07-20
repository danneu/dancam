#!/usr/bin/env bash
# One-time, resumable production-card commissioning. The authenticated image marker
# and matching Mac-written envelope are its only destructive authority.
set -euo pipefail
umask 077

BOOT=/boot/firmware/dancam
ENVELOPE=$BOOT/commissioning.json
MARKER=$BOOT/image.json
STATE_DIR=/persist/dancam
STATE=$STATE_DIR/commissioning.json
DEVICE=/dev/mmcblk0
DATA_PART=${DEVICE}p4
source /usr/local/lib/dancam/card-layout.env
ALIGN=$DANCAM_ALIGN_SECTORS
source /usr/local/lib/dancam/commission-policy.sh

exec 9>/run/dancam-commission.lock
flock -n 9 || exit 0

durable_state() {
  local state=$1 reason=${2:-null} tmp
  install -d -m 755 "$STATE_DIR"
  tmp=$(mktemp "$STATE_DIR/.commissioning.XXXXXX")
  if [ "$reason" = null ]; then
    jq -n --arg state "$state" '{state:$state,reason:null}' > "$tmp"
  else
    jq -n --arg state "$state" --arg reason "$reason" '{state:$state,reason:$reason}' > "$tmp"
  fi
  chmod 644 "$tmp"
  sync -f "$tmp"
  mv -f "$tmp" "$STATE"
  sync -f "$STATE_DIR"
}

fail() {
  trap - ERR
  durable_state failed "$1"
  logger -t dancam-commission "failed reason=$1"
  exit 1
}
trap 'fail unexpected_commissioning_error' ERR

admit_storage() {
  if [ ! -f "$STATE_DIR/storage-admitted" ]; then
    install -m 644 /dev/null "$STATE_DIR/storage-admitted"
    sync -f "$STATE_DIR/storage-admitted"
    sync -f "$STATE_DIR"
  fi
  if ! systemctl start data.mount; then
    logger -t dancam-commission "commissioning complete but data mount failed"
  fi
}

if ! commission_needs_run "$STATE"; then
  admit_storage
  exit 0
fi
[ -f "$MARKER" ] || fail image_marker_missing
[ -f "$ENVELOPE" ] || fail commissioning_envelope_missing

unit_id=$(jq -er .unit_id "$ENVELOPE") || fail commissioning_envelope_invalid
ssid=$(jq -er .ssid "$ENVELOPE") || fail commissioning_envelope_invalid
psk=$(jq -er .psk "$ENVELOPE") || fail commissioning_envelope_invalid
validate_commissioning_envelope "$MARKER" "$ENVELOPE" || fail commissioning_envelope_invalid

durable_state preparing
install -d -m 700 /persist/nm/system-connections
profile=/persist/nm/system-connections/dancam-ap.nmconnection
tmp=$(mktemp /persist/nm/system-connections/.dancam-ap.XXXXXX)
cat > "$tmp" <<EOF
[connection]
id=dancam-ap
type=wifi
interface-name=wlan0
autoconnect=true

[wifi]
mode=ap
band=bg
channel=1
ssid=$ssid

[wifi-security]
key-mgmt=wpa-psk
proto=rsn;
pairwise=ccmp;
group=ccmp;
psk=$psk

[ipv4]
method=shared
address1=10.42.0.1/24

[ipv6]
method=ignore
EOF
chmod 600 "$tmp"
sync -f "$tmp"
mv -f "$tmp" "$profile"
sync -f "$(dirname "$profile")"
nmcli connection reload
nmcli connection up dancam-ap || fail access_point_start_failed

if [ ! -f /persist/machine-id ]; then
  machine_id=$(cat /proc/sys/kernel/random/uuid)
  machine_id=${machine_id//-/}
  printf '%s\n' "$machine_id" > /persist/.machine-id.new
  chmod 444 /persist/.machine-id.new
  sync -f /persist/.machine-id.new
  mv -f /persist/.machine-id.new /persist/machine-id
  sync -f /persist
fi
mountpoint -q /etc/machine-id || mount --bind /persist/machine-id /etc/machine-id

total=$(blockdev --getsz "$DEVICE")
start=$(sfdisk --json "$DEVICE" | jq -er '.partitiontable.partitions[3].start') || fail data_partition_missing
read -r size limit < <(commission_layout "$total" "$start" "$ALIGN") || fail card_too_small
umount /data 2>/dev/null || true
printf ',%s\n' "$size" | sfdisk --no-reread --force -N 4 "$DEVICE" || fail data_partition_growth_failed
partx -u --nr 4 "$DEVICE" || fail data_partition_growth_failed
udevadm settle
e2fsck -pf "$DATA_PART" || [ "$?" -eq 1 ] || fail data_filesystem_check_failed
resize2fs "$DATA_PART" || fail data_filesystem_growth_failed

install -d -m 755 /run/dancam-data
mount -o noatime,errors=remount-ro "$DATA_PART" /run/dancam-data || fail data_mount_failed
prepare_recording_namespace /run/dancam-data dancam dancam
generation=$(cat /proc/sys/kernel/random/uuid)
printf '{"high_water_seq":0,"storage_generation":"%s"}\n' "$generation" \
  > /run/dancam-data/rec/state/state.json
chown dancam:dancam /run/dancam-data/rec/state/state.json
sync -f /run/dancam-data/rec/state/state.json
sync -f /run/dancam-data/rec/state
sync -f /run/dancam-data/rec
umount /run/dancam-data

install -Dm600 "$ENVELOPE" "$STATE_DIR/envelope.json"
sync -f "$STATE_DIR/envelope.json"
durable_state complete
admit_storage
logger -t dancam-commission "complete unit_id=$unit_id"
trap - ERR
