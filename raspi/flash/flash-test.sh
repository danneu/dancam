#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"
mkdir -p "$BIN" "$TMP/production-boot" "$TMP/development-boot" "$TMP/recovery"
EVENTS="$TMP/events"
: > "$EVENTS"

cat > "$BIN/diskutil" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'diskutil %s\n' "$*" >> "$DANCAM_FLASH_TEST_EVENTS"
case "$1 $2" in
  'list external') exit 0 ;;
  'mountDisk /dev/disk4')
    if [ -e "$DANCAM_FLASH_TEST_MOUNT_MARKER" ]; then
      [ "${DANCAM_FLASH_TEST_CORRUPT_READBACK:-0}" != 1 ] || \
        printf 'corrupt\n' >> "$DANCAM_FLASH_TEST_BOOT_MOUNT/dancam/commissioning.json"
    else
      touch "$DANCAM_FLASH_TEST_MOUNT_MARKER"
    fi
    ;;
  'info -plist')
    case "$3" in
      /) printf '{"ParentWholeDisk":"disk0"}\n' ;;
      /dev/disk4) printf '{"DeviceIdentifier":"disk4","WholeDisk":true,"Internal":false,"RemovableMedia":true,"Writable":true,"TotalSize":64000000000,"MediaName":"Test Card"}\n' ;;
      /dev/disk4s1) printf '{"MountPoint":"%s"}\n' "$DANCAM_FLASH_TEST_BOOT_MOUNT" ;;
      *) exit 64 ;;
    esac
    ;;
esac
EOF

cat > "$BIN/swift" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  */media-identity.swift)
    printf 'test-media:1:1\n'
    ;;
  */make-development-personalization.swift)
    input=$(mktemp)
    trap 'rm -f "$input"' EXIT
    cat > "$input"
    jq -e '
      (.login_user | test("^[a-z_][a-z0-9_-]{0,31}$")) and
      (.authorized_key | startswith("ssh-ed25519 ")) and
      (.home_wifi_ssid | length >= 1 and length <= 32) and
      (.home_wifi_psk | length >= 8 and length <= 64) and
      (.access_point_psk | length >= 8 and length <= 64)
    ' "$input" >/dev/null
    mkdir -p "$3/dancam"
    jq --arg image_id "$2" \
      '{schema:"dancam-development-commissioning-v1",profile:"development",image_id:$image_id} + .' \
      "$input" > "$3/dancam/commissioning.json"
    printf 'personalize development %s\n' "$2" >> "$DANCAM_FLASH_TEST_EVENTS"
    ;;
  */make-personalization.swift)
    mkdir -p "$3/dancam" "$4"
    jq -n --arg image_id "$2" \
      '{schema:"dancam-commissioning-v1",image_id:$image_id,unit_id:"testunit",ssid:"dancam-testunit",psk:"test-password",nonce:"test-nonce"}' \
      > "$3/dancam/commissioning.json"
    printf 'recovery\n' > "$4/dancam-testunit.txt"
    printf 'qr\n' > "$4/dancam-testunit-setup.png"
    printf 'personalize production %s\n' "$2" >> "$DANCAM_FLASH_TEST_EVENTS"
    printf 'testunit\n'
    ;;
  *) exit 64 ;;
esac
EOF

cat > "$BIN/swiftc" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then
    cp "$DANCAM_FLASH_TEST_TRANSFER" "$2"
    chmod +x "$2"
    exit 0
  fi
  shift
done
exit 64
EOF

cat > "$TMP/transfer" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
printf 'transfer %s\n' "$*" >> "$DANCAM_FLASH_TEST_EVENTS"
EOF

cat > "$BIN/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF

cat > "$BIN/zstd" <<'EOF'
#!/usr/bin/env bash
[ "$1" = -dc ]
cat "$2"
EOF

cat > "$BIN/minisign" <<'EOF'
#!/usr/bin/env bash
printf 'minisign %s\n' "$*" >> "$DANCAM_FLASH_TEST_EVENTS"
[ "${DANCAM_FLASH_TEST_MINISIGN_FAIL:-0}" != 1 ]
EOF

cat > "$BIN/ssh-keygen" <<'EOF'
#!/usr/bin/env bash
printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEuUXswHZHr/YK+QEu1Q2Zm8Qn9Jm8R7qYINl08PcgWz test\n'
EOF

cat > "$TMP/development-builder" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = development ]
printf 'build development\n' >> "$DANCAM_FLASH_TEST_EVENTS"
artifact="$DANCAM_IMAGE_OUT/dancam-development.img.zst"
printf 'development tracked-source sentinel\n' > "$artifact"
sha=$(shasum -a 256 "$artifact" | awk '{print $1}')
jq -n --arg artifact "$(basename "$artifact")" --arg artifact_sha256 "$sha" \
  '{schema:"dancam-development-image-manifest-v1",profile:"development",image_id:"development-image",artifact:$artifact,artifact_sha256:$artifact_sha256,raw_sha256:"development-raw-sha",raw_size:4096}' \
  > "$artifact.manifest.json"
EOF

chmod +x "$BIN"/* "$TMP/transfer" "$TMP/development-builder"
touch "$TMP/private-key" "$TMP/release.pub"

production_artifact="$TMP/production.img.zst"
printf 'production image\n' > "$production_artifact"
production_sha=$(shasum -a 256 "$production_artifact" | awk '{print $1}')
production_manifest="$production_artifact.manifest.json"
jq -n --arg artifact "$(basename "$production_artifact")" --arg artifact_sha256 "$production_sha" \
  '{schema:"dancam-image-manifest-v1",image_id:"production-image",artifact:$artifact,artifact_sha256:$artifact_sha256,raw_sha256:"production-raw-sha",raw_size:4096}' \
  > "$production_manifest"
touch "$production_manifest.minisig"

run_flash() {
  local boot=$1
  shift
  rm -f "$boot/.mount-once"
  printf 'disk4\ndisk4\n' | env \
    PATH="$BIN:$PATH" \
    DANCAM_FLASH_TEST_EVENTS="$EVENTS" \
    DANCAM_FLASH_TEST_TRANSFER="$TMP/transfer" \
    DANCAM_FLASH_TEST_BOOT_MOUNT="$boot" \
    DANCAM_FLASH_TEST_MOUNT_MARKER="$boot/.mount-once" \
    DANCAM_IMAGE_PUBLIC_KEY="$TMP/release.pub" \
    DANCAM_RECOVERY_DIR="$TMP/recovery" \
    DANCAM_FLASH_TEST_MODE=1 \
    DANCAM_FLASH_TEST_DEVELOPMENT_IMAGE_BUILDER="$TMP/development-builder" \
    DANCAM_HOST='dev_user@dancam.local' \
    DANCAM_SSH_KEY="$TMP/private-key" \
    DANCAM_HOME_WIFI_SSID='home;,$()[]{}' \
    DANCAM_HOME_WIFI_PSK='home-psk;,$()[]{} sentinel' \
    DANCAM_DEV_AP_PSK='ap-psk;,$()[]{} sentinel' \
    bash "$ROOT/raspi/flash/flash.sh" "$@"
}

run_flash "$TMP/production-boot" production "$production_manifest" > "$TMP/production.out" 2> "$TMP/production.err"
grep -Fq 'minisign -Vm' "$EVENTS"
grep -Fq 'transfer write-verify disk4 test-media:1:1 4096 production-raw-sha' "$EVENTS"
grep -Fq 'personalize production production-image' "$EVENTS"
grep -Fq 'eject /dev/disk4' "$EVENTS"

: > "$EVENTS"
export DANCAM_FLASH_TEST_MINISIGN_FAIL=1
if run_flash "$TMP/production-boot" production "$production_manifest" >/dev/null 2>&1; then
  echo 'invalid production signature was accepted' >&2
  exit 1
fi
unset DANCAM_FLASH_TEST_MINISIGN_FAIL
if grep -Fq 'diskutil list external physical' "$EVENTS"; then
  echo 'media was discovered before production authentication completed' >&2
  exit 1
fi

: > "$EVENTS"
run_flash "$TMP/development-boot" dev > "$TMP/development.out" 2> "$TMP/development.err"
grep -Fq 'build development' "$EVENTS"
grep -Fq 'transfer write-verify disk4 test-media:1:1 4096 development-raw-sha' "$EVENTS"
grep -Fq 'personalize development development-image' "$EVENTS"
grep -Fq 'eject /dev/disk4' "$EVENTS"
[ "$(/usr/bin/plutil -extract login_user raw -o - "$TMP/development-boot/dancam/commissioning.json")" = dev_user ]
[ "$(/usr/bin/plutil -extract home_wifi_ssid raw -o - "$TMP/development-boot/dancam/commissioning.json")" = 'home;,$()[]{}' ]

build_line=$(grep -n '^build development$' "$EVENTS" | cut -d: -f1)
discover_line=$(grep -n '^diskutil list external physical$' "$EVENTS" | cut -d: -f1)
transfer_line=$(grep -n '^transfer ' "$EVENTS" | cut -d: -f1)
personalize_line=$(grep -n '^personalize development development-image$' "$EVENTS" | tail -1 | cut -d: -f1)
eject_line=$(grep -n '^diskutil eject /dev/disk4$' "$EVENTS" | cut -d: -f1)
[ "$build_line" -lt "$discover_line" ]
[ "$discover_line" -lt "$transfer_line" ]
[ "$transfer_line" -lt "$personalize_line" ]
[ "$personalize_line" -lt "$eject_line" ]

if grep -R -F -e 'home-psk;,$()[]{} sentinel' -e 'ap-psk;,$()[]{} sentinel' \
  "$TMP/development.out" "$TMP/development.err" "$EVENTS" "$TMP"/*.img.zst; then
  echo 'development secret leaked into output, event log, or generic image' >&2
  exit 1
fi

for invocation in bare unknown dev-manifest dev-resume missing-credentials invalid-credentials; do
  : > "$EVENTS"
  case "$invocation" in
    bare) args=() ;;
    unknown) args=(unknown) ;;
    dev-manifest) args=(dev "$production_manifest") ;;
    dev-resume) args=(dev) ;;
    missing-credentials) args=(dev) ;;
    invalid-credentials) args=(dev) ;;
  esac
  command=(env PATH="$BIN:$PATH" DANCAM_FLASH_TEST_MODE=1 DANCAM_FLASH_TEST_EVENTS="$EVENTS" DANCAM_FLASH_TEST_TRANSFER="$TMP/transfer" DANCAM_FLASH_TEST_BOOT_MOUNT="$TMP/development-boot" DANCAM_FLASH_TEST_DEVELOPMENT_IMAGE_BUILDER="$TMP/development-builder")
  [ "$invocation" != dev-resume ] || command+=(DANCAM_FLASH_RESUME=1)
  [ "$invocation" != missing-credentials ] || command+=(DANCAM_HOST=)
  [ "$invocation" != invalid-credentials ] || command+=(DANCAM_HOST=dev_user@dancam.local DANCAM_SSH_KEY="$TMP/private-key" DANCAM_HOME_WIFI_SSID=home DANCAM_HOME_WIFI_PSK=short DANCAM_DEV_AP_PSK=valid-ap-password)
  if "${command[@]}" bash "$ROOT/raspi/flash/flash.sh" "${args[@]}" > "$TMP/reject.out" 2> "$TMP/reject.err"; then
    echo "unsafe invocation was accepted: $invocation" >&2
    exit 1
  fi
  if grep -Eq '^(build development|diskutil list external physical)$' "$EVENTS"; then
    echo "unsafe invocation reached build or media discovery: $invocation" >&2
    exit 1
  fi
done

: > "$EVENTS"
printf 'disk4\ndisk4\n' | env PATH="$BIN:$PATH" DANCAM_FLASH_RESUME=1 \
  DANCAM_FLASH_TEST_EVENTS="$EVENTS" DANCAM_FLASH_TEST_TRANSFER="$TMP/transfer" \
  DANCAM_FLASH_TEST_BOOT_MOUNT="$TMP/production-boot" DANCAM_IMAGE_PUBLIC_KEY="$TMP/release.pub" \
  DANCAM_FLASH_TEST_MOUNT_MARKER="$TMP/production-resume.mount" \
  DANCAM_RECOVERY_DIR="$TMP/recovery" \
  bash "$ROOT/raspi/flash/flash.sh" production "$production_manifest" >/dev/null
grep -Fq 'transfer repair-verify disk4 test-media:1:1 4096 production-raw-sha' "$EVENTS"

: > "$EVENTS"
export DANCAM_FLASH_TEST_CORRUPT_READBACK=1
if run_flash "$TMP/production-boot" production "$production_manifest" >/dev/null 2>&1; then
  echo 'corrupt personalization readback was accepted' >&2
  exit 1
fi
unset DANCAM_FLASH_TEST_CORRUPT_READBACK
if grep -Fq 'diskutil eject /dev/disk4' "$EVENTS"; then
  echo 'card was ejected after personalization readback failed' >&2
  exit 1
fi

echo 'flash end-to-end tests passed'
