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
