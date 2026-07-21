#!/usr/bin/env bash
# Inspect the staged filesystems independently of the Ansible declarations that
# created them. This must pass before package inventory or release signing.
set -euo pipefail

SCRIPT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

verify_die() { echo "raspi-image verify: $*" >&2; return 1; }

verify_file() {
  [ -f "$1" ] || verify_die "missing file: $1"
}

verify_symlink() {
  local path=$1 target=$2
  [ -L "$path" ] || verify_die "missing symlink: $path"
  [ "$(readlink "$path")" = "$target" ] || verify_die "wrong symlink target: $path"
}

verify_line() {
  local path=$1 line=$2
  grep -qxF "$line" "$path" || verify_die "missing exact line in $path: $line"
}

verify_ini_value() {
  local path=$1 section=$2 option=$3 expected=$4 actual
  actual=$(awk -F= -v wanted_section="[$section]" -v wanted_option="$option" '
    /^\[/ { in_section = ($0 == wanted_section) }
    in_section && $1 == wanted_option { print substr($0, index($0, "=") + 1) }
  ' "$path")
  [ "$actual" = "$expected" ] || \
    verify_die "wrong [$section] $option value in $path"
}

verify_boot_command_line() {
  local path=$1 root_partuuid=$2 wifi_country=$3 token count
  if grep -Fq '\n' "$path"; then
    verify_die 'boot command line contains a literal newline escape'
    return 1
  fi
  for token in \
    "root=PARTUUID=$root_partuuid" \
    cloud-init=disabled \
    "cfg80211.ieee80211_regdom=$wifi_country"; do
    count=$(tr ' ' '\n' < "$path" | grep -cxF "$token" || true)
    if [ "$count" -ne 1 ]; then
      verify_die "boot command line token count is not one: $token"
      return 1
    fi
  done
  if tr ' ' '\n' < "$path" | grep -qxF resize; then
    verify_die 'base-image resize action remains enabled'
    return 1
  fi
}

verify_absent_release_state() {
  local image_root=$1 connection_root connection_persist signing_secret
  connection_root="$image_root/etc/NetworkManager/system-connections"
  connection_persist="$image_root/persist/nm/system-connections"

  if [ -e "$image_root/persist/dancam/storage-admitted" ]; then
    verify_die 'generic image contains a storage-admission marker'
    return 1
  fi
  if [ -e "$image_root/boot/firmware/dancam/commissioning.json" ]; then
    verify_die 'generic image contains a per-card commissioning envelope'
    return 1
  fi
  if [ -e "$image_root/data/rec/state/state.json" ]; then
    verify_die 'generic image contains a pre-minted storage generation'
    return 1
  fi
  if [ -e "$image_root/persist/machine-id" ]; then
    verify_die 'generic image contains a per-card machine identity'
    return 1
  fi
  if [ -n "$(find "$connection_root" "$connection_persist" -type f -print -quit)" ]; then
    verify_die 'generic image contains a Wi-Fi connection profile'
    return 1
  fi
  signing_secret=$(grep -RIl --exclude='*.pub' 'minisign encrypted secret key' \
    "$image_root/root" "$image_root/home" "$image_root/persist" \
    "$image_root/boot/firmware" "$image_root/usr/local" 2>/dev/null || true)
  if [ -n "$signing_secret" ]; then
    verify_die 'generic image contains a release signing key'
    return 1
  fi
}

verify_production_image() {
  local image_root=$1 image_id=$2 root_partuuid=$3 wifi_country=$4
  local persist_label=$5 data_label=$6 catalog package pin installed uid gid unit

  catalog="$SCRIPT_ROOT/raspi/ansible/roles/system_common/vars/packages.json"

  verify_file "$image_root/etc/hostname"
  [ "$(cat "$image_root/etc/hostname")" = dancam ] || verify_die 'hostname is not dancam'
  [ ! -s "$image_root/etc/machine-id" ] || verify_die 'generic root machine identity is not empty'
  verify_line "$image_root/etc/hosts" $'127.0.1.1\tdancam'
  verify_ini_value "$image_root/etc/avahi/avahi-daemon.conf" server allow-interfaces wlan0
  verify_symlink "$image_root/etc/systemd/system/multi-user.target.wants/avahi-daemon.service" \
    /usr/lib/systemd/system/avahi-daemon.service

  while IFS=$'\t' read -r package pin; do
    installed=$(chroot "$image_root" /usr/bin/dpkg-query -W -f='${Version}' "$package") || \
      verify_die "production package is absent: $package"
    [ "$installed" = "$pin" ] || \
      verify_die "production package pin mismatch: $package=$installed, expected $pin"
  done < <(jq -r '.system_common_package_catalog[] | select(.production_pin != null) | [.name,.production_pin] | @tsv' "$catalog")

  verify_file "$image_root/usr/local/bin/dancam"
  [ -x "$image_root/usr/local/bin/dancam" ] || verify_die 'service binary is not executable'
  cmp -s "$image_root/usr/local/lib/dancam/camera.py" "$SCRIPT_ROOT/raspi/camera/camera.py" || \
    verify_die 'camera owner does not match the tracked source'
  cmp -s "$image_root/etc/systemd/system/dancam.service" "$SCRIPT_ROOT/raspi/dancam.service" || \
    verify_die 'service unit does not match the tracked source'
  verify_line "$image_root/etc/systemd/system/dancam.service" 'User=dancam'
  verify_symlink "$image_root/etc/systemd/system/multi-user.target.wants/dancam.service" \
    /etc/systemd/system/dancam.service
  verify_symlink "$image_root/etc/systemd/system/timers.target.wants/fstrim.timer" \
    /usr/lib/systemd/system/fstrim.timer
  verify_line "$image_root/etc/systemd/system/dancam.service.d/production.conf" \
    'Environment=DANCAM_COMMISSIONING_STATE_PATH=/persist/dancam/commissioning.json'
  cmp -s "$image_root/etc/systemd/system/dancam-commission.service" \
    "$SCRIPT_ROOT/raspi/image/dancam-commission.service" || \
    verify_die 'commissioning unit does not match the tracked source'
  cmp -s "$image_root/etc/systemd/system/dancam-commission-led.service" \
    "$SCRIPT_ROOT/raspi/image/dancam-commission-led.service" || \
    verify_die 'commissioning LED unit does not match the tracked source'
  verify_symlink "$image_root/etc/systemd/system/multi-user.target.wants/dancam-commission.service" \
    /etc/systemd/system/dancam-commission.service
  verify_symlink "$image_root/etc/systemd/system/multi-user.target.wants/dancam-commission-led.service" \
    /etc/systemd/system/dancam-commission-led.service

  verify_line "$image_root/boot/firmware/config.txt" 'camera_auto_detect=0'
  verify_line "$image_root/boot/firmware/config.txt" 'dtoverlay=imx708'
  verify_boot_command_line "$image_root/boot/firmware/cmdline.txt" "$root_partuuid" "$wifi_country"

  verify_line "$image_root/etc/systemd/journald.conf.d/60-dancam-persistent.conf" 'Storage=persistent'
  verify_line "$image_root/etc/systemd/journald.conf.d/60-dancam-persistent.conf" 'SystemMaxUse=200M'
  verify_line "$image_root/etc/systemd/journald.conf.d/60-dancam-persistent.conf" 'SyncIntervalSec=60s'
  verify_line "$image_root/etc/systemd/system.conf.d/60-dancam-watchdog.conf" 'RuntimeWatchdogSec=60s'
  verify_line "$image_root/etc/sysctl.d/60-dancam-writeback.conf" 'vm.dirty_background_bytes=16777216'
  verify_line "$image_root/etc/sysctl.d/60-dancam-writeback.conf" 'vm.dirty_bytes=67108864'

  verify_line "$image_root/etc/fstab" 'LABEL=bootfs /boot/firmware vfat ro,noatime 0 2'
  verify_line "$image_root/etc/fstab" 'LABEL=rootfs / ext4 ro,noatime,errors=remount-ro 0 1'
  verify_line "$image_root/etc/fstab" "LABEL=$persist_label /persist ext4 noatime,errors=remount-ro,nofail,x-systemd.device-timeout=10s 0 2"
  verify_line "$image_root/etc/fstab" '/persist/nm/system-connections /etc/NetworkManager/system-connections none bind,nofail 0 0'
  verify_line "$image_root/etc/fstab" '/persist/nm/var-lib /var/lib/NetworkManager none bind,nofail 0 0'
  verify_line "$image_root/etc/fstab" '/persist/timesync /var/lib/systemd/timesync none bind,nofail 0 0'
  verify_line "$image_root/etc/fstab" '/persist/journal /var/log/journal none bind,nofail 0 0'
  verify_line "$image_root/etc/fstab" '/persist/machine-id /etc/machine-id none bind,nofail 0 0'
  verify_line "$image_root/etc/fstab" 'tmpfs /tmp tmpfs rw,nosuid,nodev,noatime,mode=1777,size=64M 0 0'
  verify_line "$image_root/etc/fstab" 'tmpfs /var/log tmpfs rw,nosuid,nodev,noatime,mode=0755,size=32M 0 0'
  verify_line "$image_root/etc/systemd/system/data.mount" "What=/dev/disk/by-label/$data_label"
  verify_line "$image_root/etc/systemd/system/data.mount" \
    'ConditionPathExists=/persist/dancam/storage-admitted'
  verify_symlink "$image_root/etc/systemd/system/local-fs.target.wants/data.mount" \
    /etc/systemd/system/data.mount

  for unit in apt-daily.timer apt-daily-upgrade.timer man-db.timer dpkg-db-backup.timer \
    unattended-upgrades.service cloud-init.target cloud-init-local.service \
    cloud-init-network.service cloud-config.service cloud-final.service \
    cloud-init-hotplugd.socket; do
    verify_symlink "$image_root/etc/systemd/system/$unit" /dev/null
  done

  uid=$(awk -F: '$1 == "dancam" { print $3 }' "$image_root/etc/passwd")
  gid=$(awk -F: '$1 == "dancam" { print $4 }' "$image_root/etc/passwd")
  [ -n "$uid" ] && [ -n "$gid" ] || verify_die 'dancam service identity is absent'
  for unit in "$image_root/data/rec" "$image_root/data/rec/state"; do
    [ "$(stat -c '%u:%g:%a' "$unit")" = "$uid:$gid:755" ] || \
      verify_die "recording namespace ownership or mode is wrong: $unit"
  done
  [ -z "$(find "$image_root/data/rec/state" -mindepth 1 -print -quit)" ] || \
    verify_die 'generic recording state directory is not empty'

  [ "$(jq -r .schema "$image_root/boot/firmware/dancam/image.json")" = dancam-image-marker-v1 ] || \
    verify_die 'image marker schema is wrong'
  [ "$(jq -r .image_id "$image_root/boot/firmware/dancam/image.json")" = "$image_id" ] || \
    verify_die 'image marker identity is wrong'
  verify_absent_release_state "$image_root"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  [ "$#" -eq 6 ] || {
    echo 'usage: verify-image.sh ROOT IMAGE_ID ROOT_PARTUUID WIFI_COUNTRY PERSIST_LABEL DATA_LABEL' >&2
    exit 64
  }
  verify_production_image "$@"
  printf '%s\n' 'production image inspection passed'
fi
