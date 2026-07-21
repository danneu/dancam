#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
source "$ROOT/raspi/image/verify-image.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p \
  "$TMP/etc/NetworkManager/system-connections" \
  "$TMP/persist/nm/system-connections" \
  "$TMP/persist/dancam" \
  "$TMP/boot/firmware/dancam" \
  "$TMP/data/rec/state" \
  "$TMP/root" "$TMP/home" "$TMP/usr/local"

DEV="$TMP/development"
mkdir -p \
  "$DEV/etc/NetworkManager/system-connections" \
  "$DEV/etc/sudoers.d" \
  "$DEV/etc/systemd/system/multi-user.target.wants" \
  "$DEV/etc/systemd/system/timers.target.wants" \
  "$DEV/etc/systemd/system/dancam.service.d" \
  "$DEV/etc/systemd/journald.conf.d" \
  "$DEV/etc/systemd/system.conf.d" \
  "$DEV/etc/sysctl.d" \
  "$DEV/etc/ssh" \
  "$DEV/etc/avahi" \
  "$DEV/persist/nm/system-connections" \
  "$DEV/persist/dancam" \
  "$DEV/boot/firmware/dancam" \
  "$DEV/data/rec/state" \
  "$DEV/root" "$DEV/home" "$DEV/usr/local/bin" "$DEV/usr/local/lib/dancam"
printf 'dancam\n' > "$DEV/etc/hostname"
printf '127.0.1.1\tdancam\n' > "$DEV/etc/hosts"
: > "$DEV/etc/machine-id"
printf '[server]\nallow-interfaces=wlan0\n' > "$DEV/etc/avahi/avahi-daemon.conf"
printf 'dancam:x:123:456::/nonexistent:/usr/sbin/nologin\n' > "$DEV/etc/passwd"
printf '%s\n' \
  'LABEL=bootfs /boot/firmware vfat defaults,noatime 0 2' \
  'LABEL=rootfs / ext4 defaults,noatime,errors=remount-ro 0 1' \
  'LABEL=dancam-persist /persist ext4 noatime,errors=remount-ro,nofail,x-systemd.device-timeout=10s 0 2' \
  'LABEL=dancam-data /data ext4 noatime,errors=remount-ro,nofail,x-systemd.device-timeout=10s 0 2' \
  '/persist/journal /var/log/journal none bind,nofail 0 0' > "$DEV/etc/fstab"
printf 'camera_auto_detect=0\ndtoverlay=imx708\n' > "$DEV/boot/firmware/config.txt"
printf '%s\n' \
  'console=tty1 root=PARTUUID=041bba91-02 cloud-init=disabled cfg80211.ieee80211_regdom=US' \
  > "$DEV/boot/firmware/cmdline.txt"
printf '{"schema":"dancam-image-marker-v1","image_id":"image-id","profile":"development"}\n' \
  > "$DEV/boot/firmware/dancam/image.json"
printf '{"state":"preparing","reason":null}\n' > "$DEV/persist/dancam/commissioning.json"
printf '[Service]\nEnvironment=DANCAM_COMMISSIONING_STATE_PATH=/persist/dancam/commissioning.json\n' \
  > "$DEV/etc/systemd/system/dancam.service.d/development.conf"
cp "$ROOT/raspi/camera/camera.py" "$DEV/usr/local/lib/dancam/camera.py"
cp "$ROOT/raspi/dancam.service" "$DEV/etc/systemd/system/dancam.service"
cp "$ROOT/raspi/image/commission.sh" "$DEV/usr/local/lib/dancam/commission.sh"
cp "$ROOT/raspi/image/commission-policy.sh" "$DEV/usr/local/lib/dancam/commission-policy.sh"
cp "$ROOT/raspi/image/commission-led.sh" "$DEV/usr/local/lib/dancam/commission-led.sh"
cp "$ROOT/raspi/system/card-layout.env" "$DEV/usr/local/lib/dancam/card-layout.env"
cp "$ROOT/raspi/image/dancam-commission.service" "$DEV/etc/systemd/system/dancam-commission.service"
cp "$ROOT/raspi/image/dancam-commission-led.service" "$DEV/etc/systemd/system/dancam-commission-led.service"
touch "$DEV/usr/local/bin/dancam"
chmod +x "$DEV/usr/local/bin/dancam"
ln -s /usr/lib/systemd/system/avahi-daemon.service \
  "$DEV/etc/systemd/system/multi-user.target.wants/avahi-daemon.service"
ln -s /etc/systemd/system/dancam.service \
  "$DEV/etc/systemd/system/multi-user.target.wants/dancam.service"
ln -s /etc/systemd/system/dancam-commission.service \
  "$DEV/etc/systemd/system/multi-user.target.wants/dancam-commission.service"
ln -s /etc/systemd/system/dancam-commission-led.service \
  "$DEV/etc/systemd/system/multi-user.target.wants/dancam-commission-led.service"
ln -s /usr/lib/systemd/system/ssh.service \
  "$DEV/etc/systemd/system/multi-user.target.wants/ssh.service"
ln -s /usr/lib/systemd/system/fstrim.timer \
  "$DEV/etc/systemd/system/timers.target.wants/fstrim.timer"

mkdir -p "$TMP/dev-bin"
cat > "$TMP/dev-bin/chroot" <<'EOF'
#!/usr/bin/env bash
printf 'current-version\n'
EOF
cat > "$TMP/dev-bin/stat" <<'EOF'
#!/usr/bin/env bash
printf '123:456:755\n'
EOF
chmod +x "$TMP/dev-bin/chroot" "$TMP/dev-bin/stat"
ORIGINAL_PATH=$PATH
PATH="$TMP/dev-bin:$PATH"
bash "$ROOT/raspi/image/verify-image.sh" development \
  "$DEV" image-id 041bba91-02 US dancam-persist dancam-data >/dev/null
touch "$DEV/etc/ssh/ssh_host_ed25519_key"
if bash "$ROOT/raspi/image/verify-image.sh" development \
  "$DEV" image-id 041bba91-02 US dancam-persist dancam-data >/dev/null 2>&1; then
  echo 'development image with a generic SSH host identity passed inspection' >&2
  exit 1
fi
rm "$DEV/etc/ssh/ssh_host_ed25519_key"
printf '# sentinel drift\n' >> "$DEV/usr/local/lib/dancam/camera.py"
if bash "$ROOT/raspi/image/verify-image.sh" development \
  "$DEV" image-id 041bba91-02 US dancam-persist dancam-data >/dev/null 2>&1; then
  echo 'development image with stale tracked source passed inspection' >&2
  exit 1
fi
PATH=$ORIGINAL_PATH

CMDLINE="$TMP/boot/firmware/cmdline.txt"
printf '%s\n' \
  'console=tty1 root=PARTUUID=041bba91-02 cloud-init=disabled cfg80211.ieee80211_regdom=US' \
  > "$CMDLINE"
verify_boot_command_line "$CMDLINE" 041bba91-02 US
printf '%s\n' \
  'root=PARTUUID=041bba91-02 cloud-init=disabled cloud-init=disabled cfg80211.ieee80211_regdom=US' \
  > "$CMDLINE"
if verify_boot_command_line "$CMDLINE" 041bba91-02 US >/dev/null 2>&1; then
  echo 'duplicate boot command-line token passed release inspection' >&2
  exit 1
fi
printf '%s\n' \
  'root=PARTUUID=041bba91-02 cloud-init=disabled cfg80211.ieee80211_regdom=US\n' \
  > "$CMDLINE"
if verify_boot_command_line "$CMDLINE" 041bba91-02 US >/dev/null 2>&1; then
  echo 'literal newline escape passed release inspection' >&2
  exit 1
fi

verify_absent_release_state "$TMP"
touch "$TMP/persist/dancam/storage-admitted"
if verify_absent_release_state "$TMP" >/dev/null 2>&1; then
  echo 'planted storage-admission marker passed release inspection' >&2
  exit 1
fi

rm "$TMP/persist/dancam/storage-admitted"
printf '[wifi]\nssid=sentinel\n' > "$TMP/etc/NetworkManager/system-connections/dancam-home.nmconnection"
if verify_absent_release_state "$TMP" >/dev/null 2>&1; then
  echo 'planted development Wi-Fi profile passed generic-image inspection' >&2
  exit 1
fi
rm "$TMP/etc/NetworkManager/system-connections/dancam-home.nmconnection"

mkdir -p "$TMP/home/developer/.ssh" "$TMP/etc/sudoers.d"
printf '%s\n' 'ssh-ed25519 sentinel' > "$TMP/home/developer/.ssh/authorized_keys"
if verify_absent_development_access "$TMP" >/dev/null 2>&1; then
  echo 'planted authorized key passed generic-image inspection' >&2
  exit 1
fi
rm "$TMP/home/developer/.ssh/authorized_keys"
printf '%s\n' 'developer ALL=(ALL:ALL) NOPASSWD: ALL' > "$TMP/etc/sudoers.d/developer"
if verify_absent_development_access "$TMP" >/dev/null 2>&1; then
  echo 'planted passwordless sudo grant passed generic-image inspection' >&2
  exit 1
fi
rm "$TMP/etc/sudoers.d/developer"

printf 'minisign encrypted secret key\n' > "$TMP/home/release.key"
if verify_absent_release_state "$TMP" >/dev/null 2>&1; then
  echo 'planted signing key passed generic-image inspection' >&2
  exit 1
fi
rm "$TMP/home/release.key"

mkdir -p "$TMP/var/cache/apt/archives" "$TMP/var/lib/apt/lists"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/stat" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${DANCAM_VERIFY_TEST_AVAILABLE_BLOCKS:?} 4096"
EOF
chmod +x "$TMP/bin/stat"
TEST_PATH=$PATH
PATH="$TMP/bin:$PATH"
export DANCAM_VERIFY_TEST_AVAILABLE_BLOCKS=262144
verify_release_cleanup "$TMP"

touch "$TMP/var/cache/apt/archives/package.deb"
if verify_release_cleanup "$TMP" >/dev/null 2>&1; then
  echo 'downloaded package archive passed release inspection' >&2
  exit 1
fi
rm "$TMP/var/cache/apt/archives/package.deb"

touch "$TMP/var/lib/apt/lists/repository-list"
if verify_release_cleanup "$TMP" >/dev/null 2>&1; then
  echo 'apt repository list passed release inspection' >&2
  exit 1
fi
rm "$TMP/var/lib/apt/lists/repository-list"

rmdir "$TMP/var/lib/apt/lists"
if verify_release_cleanup "$TMP" >/dev/null 2>&1; then
  echo 'missing apt cleanup path passed release inspection' >&2
  exit 1
fi
mkdir -p "$TMP/var/lib/apt/lists"

export DANCAM_VERIFY_TEST_AVAILABLE_BLOCKS=262143
if verify_release_cleanup "$TMP" >/dev/null 2>&1; then
  echo 'production root below the available-space floor passed release inspection' >&2
  exit 1
fi
PATH=$TEST_PATH

printf '%s\n' 'production image verifier tests passed'
