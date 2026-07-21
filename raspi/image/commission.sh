#!/usr/bin/env bash
# One-time, resumable card commissioning. The generic image marker and matching
# Mac-written envelope are the only authority for identity and storage mutation.
set -euo pipefail
umask 077

ROOT_PREFIX=${DANCAM_COMMISSION_ROOT:-}
root_path() { printf '%s%s\n' "$ROOT_PREFIX" "$1"; }

BOOT=$(root_path /boot/firmware/dancam)
ENVELOPE=$BOOT/commissioning.json
MARKER=$BOOT/image.json
STATE_DIR=$(root_path /persist/dancam)
STATE=$STATE_DIR/commissioning.json
DATA_MOUNT=$(root_path /data)
PRIVATE_DATA_MOUNT=$(root_path /run/dancam-data)
DEVICE=${DANCAM_COMMISSION_DEVICE:-/dev/mmcblk0}
DATA_PART=${DANCAM_COMMISSION_DATA_PART:-${DEVICE}p4}
LIB_ROOT=${DANCAM_COMMISSION_LIB_ROOT:-/usr/local/lib/dancam}
source "$LIB_ROOT/card-layout.env"
ALIGN=$DANCAM_ALIGN_SECTORS
source "$LIB_ROOT/commission-policy.sh"

install -d -m 755 "$(root_path /run)"
exec 9>"$(root_path /run/dancam-commission.lock)"
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

new_uuid() {
  local purpose=$1 variable value
  if [ -n "$ROOT_PREFIX" ]; then
    variable="DANCAM_COMMISSION_TEST_${purpose^^}"
    value=${!variable:-}
    if [ -n "$value" ]; then
      printf '%s\n' "$value"
      return
    fi
  fi
  cat /proc/sys/kernel/random/uuid
}

admit_storage() {
  local profile=$1
  if [ ! -f "$STATE_DIR/storage-admitted" ]; then
    install -m 644 /dev/null "$STATE_DIR/storage-admitted"
    sync -f "$STATE_DIR/storage-admitted"
    sync -f "$STATE_DIR"
  fi
  if [ "$profile" = production ]; then
    if ! systemctl start data.mount; then
      logger -t dancam-commission "commissioning complete but data mount failed"
    fi
  elif ! mountpoint -q "$DATA_MOUNT" && ! mount "$DATA_MOUNT"; then
    logger -t dancam-commission "commissioning complete but data mount failed"
  fi
}

install_production_access_point() {
  local unit_id=$1 ssid=$2 psk=$3 profile tmp
  install -d -m 700 "$(root_path /persist/nm/system-connections)"
  profile=$(root_path /persist/nm/system-connections/dancam-ap.nmconnection)
  tmp=$(mktemp "$(dirname "$profile")/.dancam-ap.XXXXXX")
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
}

validate_authorized_key() {
  local authorized_key=$1 tmp
  tmp=$(mktemp "$STATE_DIR/.authorized-key.XXXXXX")
  printf '%s\n' "$authorized_key" > "$tmp"
  if ! ssh-keygen -l -f "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    return 1
  fi
  rm -f "$tmp"
}

install_development_login() {
  local login_user=$1 authorized_key=$2 home ssh_dir key_file sudoers sshd_config login_marker
  login_marker=$STATE_DIR/development-login
  if [ -f "$login_marker" ]; then
    [ "$(cat "$login_marker")" = "$login_user" ] || fail login_user_mismatch
  else
    if id -u "$login_user" >/dev/null 2>&1; then
      fail login_user_already_exists
    fi
    printf '%s\n' "$login_user" > "$login_marker"
    chmod 600 "$login_marker"
    sync -f "$login_marker"
    sync -f "$STATE_DIR"
  fi
  if ! id -u "$login_user" >/dev/null 2>&1; then
    useradd --create-home --shell /bin/bash --groups sudo "$login_user"
  fi
  usermod --lock "$login_user"
  home=$(root_path "/home/$login_user")
  ssh_dir=$home/.ssh
  key_file=$ssh_dir/authorized_keys
  install -d -o "$login_user" -g "$login_user" -m 700 "$ssh_dir"
  printf '%s\n' "$authorized_key" > "$key_file"
  chown "$login_user:$login_user" "$key_file"
  chmod 600 "$key_file"

  sudoers=$(root_path "/etc/sudoers.d/60-dancam-$login_user")
  install -d -m 755 "$(dirname "$sudoers")"
  printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$login_user" > "$sudoers"
  chmod 440 "$sudoers"
  visudo -cf "$sudoers" >/dev/null

  sshd_config=$(root_path /etc/ssh/sshd_config.d/60-dancam-development.conf)
  install -d -m 755 "$(dirname "$sshd_config")"
  cat > "$sshd_config" <<EOF
Match User $login_user
    AuthenticationMethods publickey
    PasswordAuthentication no
    KbdInteractiveAuthentication no
EOF
  chmod 644 "$sshd_config"
  if [ -n "$ROOT_PREFIX" ]; then
    ssh-keygen -A -f "$ROOT_PREFIX" >/dev/null
  else
    ssh-keygen -A >/dev/null
  fi
  sshd -t -f "$(root_path /etc/ssh/sshd_config)"
  systemctl restart ssh.service
}

install_development_networks() {
  local home_ssid=$1 home_psk=$2 access_point_psk=$3
  nmcli --wait 10 connection delete dancam-home >/dev/null 2>&1 || true
  nmcli connection add type wifi ifname wlan0 con-name dancam-home ssid "$home_ssid"
  nmcli connection modify dancam-home \
    connection.autoconnect yes \
    802-11-wireless.mode infrastructure \
    802-11-wireless.band bg \
    802-11-wireless-security.key-mgmt wpa-psk \
    802-11-wireless-security.psk "$home_psk" \
    ipv4.method auto \
    ipv6.method auto

  nmcli --wait 10 connection delete dancam-ap >/dev/null 2>&1 || true
  nmcli connection add type wifi ifname wlan0 con-name dancam-ap ssid dancam-dev
  nmcli connection modify dancam-ap \
    connection.autoconnect no \
    802-11-wireless.mode ap \
    802-11-wireless.band bg \
    802-11-wireless.channel 1 \
    802-11-wireless-security.key-mgmt wpa-psk \
    802-11-wireless-security.proto rsn \
    802-11-wireless-security.pairwise ccmp \
    802-11-wireless-security.group ccmp \
    802-11-wireless-security.psk "$access_point_psk" \
    ipv4.method shared \
    ipv4.addresses 10.42.0.1/24 \
    ipv6.method ignore
  nmcli connection up dancam-home || fail home_wifi_start_failed
}

install_machine_identity() {
  local profile=$1 machine_id target tmp
  if [ "$profile" = production ]; then
    target=$(root_path /persist/machine-id)
    if [ ! -f "$target" ]; then
      machine_id=$(new_uuid machine_id)
      machine_id=${machine_id//-/}
      tmp=$(root_path /persist/.machine-id.new)
      printf '%s\n' "$machine_id" > "$tmp"
      chmod 444 "$tmp"
      sync -f "$tmp"
      mv -f "$tmp" "$target"
      sync -f "$(root_path /persist)"
    fi
    mountpoint -q "$(root_path /etc/machine-id)" || \
      mount --bind "$target" "$(root_path /etc/machine-id)"
  else
    target=$(root_path /etc/machine-id)
    if [ ! -s "$target" ]; then
      if [ -n "$ROOT_PREFIX" ]; then
        systemd-machine-id-setup --root="$ROOT_PREFIX" >/dev/null
      else
        systemd-machine-id-setup --commit >/dev/null
      fi
    fi
  fi
  machine_id=$(tr -d '\n' < "$target")
  [[ "$machine_id" =~ ^[a-f0-9]{32}$ ]] || fail machine_identity_invalid
  COMMISSION_MACHINE_ID=$machine_id
}

grow_and_initialize_storage() {
  local machine_id=$1 total start size _limit generation
  total=$(blockdev --getsz "$DEVICE")
  start=$(sfdisk --json "$DEVICE" | jq -er '.partitiontable.partitions[3].start') \
    || fail data_partition_missing
  read -r size _limit < <(commission_layout "$total" "$start" "$ALIGN") || fail card_too_small
  if mountpoint -q "$DATA_MOUNT"; then
    umount "$DATA_MOUNT" || fail data_unmount_failed
  fi
  printf ',%s\n' "$size" | sfdisk --no-reread --force -N 4 "$DEVICE" \
    || fail data_partition_growth_failed
  partx -u --nr 4 "$DEVICE" || fail data_partition_growth_failed
  udevadm settle
  e2fsck -pf "$DATA_PART" || [ "$?" -eq 1 ] || fail data_filesystem_check_failed
  resize2fs "$DATA_PART" || fail data_filesystem_growth_failed

  install -d -m 755 "$PRIVATE_DATA_MOUNT"
  mount -o noatime,errors=remount-ro "$DATA_PART" "$PRIVATE_DATA_MOUNT" || fail data_mount_failed
  validate_recording_namespace "$PRIVATE_DATA_MOUNT" \
    "${DANCAM_COMMISSION_SERVICE_OWNER:-dancam}" \
    "${DANCAM_COMMISSION_SERVICE_GROUP:-dancam}" \
    || fail recording_namespace_invalid
  generation=$(new_uuid storage_generation)
  [[ "$generation" =~ ^[a-f0-9]{8}-[a-f0-9]{4}-[1-5][a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$ ]] \
    || fail storage_generation_invalid
  [ "${generation//-/}" != "$machine_id" ] || fail storage_generation_not_unique
  printf '{"high_water_seq":0,"storage_generation":"%s"}\n' "$generation" \
    > "$PRIVATE_DATA_MOUNT/rec/state/state.json"
  chown "${DANCAM_COMMISSION_SERVICE_OWNER:-dancam}:${DANCAM_COMMISSION_SERVICE_GROUP:-dancam}" \
    "$PRIVATE_DATA_MOUNT/rec/state/state.json"
  sync -f "$PRIVATE_DATA_MOUNT/rec/state/state.json"
  sync -f "$PRIVATE_DATA_MOUNT/rec/state"
  sync -f "$PRIVATE_DATA_MOUNT/rec"
  umount "$PRIVATE_DATA_MOUNT"
}

if ! commission_needs_run "$STATE"; then
  replay_profile=production
  [ ! -f "$STATE_DIR/development-login" ] || replay_profile=development
  admit_storage "$replay_profile"
  exit 0
fi
[ -f "$MARKER" ] || fail image_marker_missing
profile=$(jq -er '.profile // "production"' "$MARKER") || fail image_marker_invalid
case "$profile" in production|development) ;; *) fail image_marker_invalid ;; esac
[ -f "$ENVELOPE" ] || fail commissioning_envelope_missing

case "$profile" in
  production)
    unit_id=$(jq -er .unit_id "$ENVELOPE") || fail commissioning_envelope_invalid
    ssid=$(jq -er .ssid "$ENVELOPE") || fail commissioning_envelope_invalid
    psk=$(jq -er .psk "$ENVELOPE") || fail commissioning_envelope_invalid
    validate_commissioning_envelope "$MARKER" "$ENVELOPE" \
      || fail commissioning_envelope_invalid
    durable_state preparing
    install_production_access_point "$unit_id" "$ssid" "$psk"
    ;;
  development)
    validate_development_commissioning_envelope "$MARKER" "$ENVELOPE" \
      || fail commissioning_envelope_invalid
    login_user=$(jq -er .login_user "$ENVELOPE")
    authorized_key=$(jq -er .authorized_key "$ENVELOPE")
    home_wifi_ssid=$(jq -er .home_wifi_ssid "$ENVELOPE")
    home_wifi_psk=$(jq -er .home_wifi_psk "$ENVELOPE")
    access_point_psk=$(jq -er .access_point_psk "$ENVELOPE")
    validate_authorized_key "$authorized_key" || fail authorized_key_invalid
    durable_state preparing
    install_development_login "$login_user" "$authorized_key"
    install_development_networks "$home_wifi_ssid" "$home_wifi_psk" "$access_point_psk"
    ;;
esac

COMMISSION_MACHINE_ID=
install_machine_identity "$profile"
grow_and_initialize_storage "$COMMISSION_MACHINE_ID"

if [ "$profile" = production ]; then
  install -Dm600 "$ENVELOPE" "$STATE_DIR/envelope.json"
  sync -f "$STATE_DIR/envelope.json"
fi
durable_state complete
admit_storage "$profile"
if [ "$profile" = development ]; then
  rm -f "$ENVELOPE"
  sync -f "$BOOT"
  logger -t dancam-commission "complete profile=development login_user=$login_user"
else
  logger -t dancam-commission "complete unit_id=$unit_id"
fi
trap - ERR
