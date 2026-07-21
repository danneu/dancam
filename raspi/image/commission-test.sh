#!/usr/bin/env bash
# Hardware-free checks for the destructive authority and 95% aligned layout math.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
source "$ROOT/raspi/system/card-layout.env"
source "$ROOT/raspi/image/commission-policy.sh"
ALIGN=$DANCAM_ALIGN_SECTORS

for bytes in 32000000000 64000000000 128000000000 256000000000; do
  total=$((bytes / 512))
  start=10502144
  read -r _size end < <(commission_layout "$total" "$start" "$ALIGN")
  tail=$((total - end))
  [ "$((start % ALIGN))" -eq 0 ]
  [ "$((end % ALIGN))" -eq 0 ]
  [ "$end" -le "$((total * DANCAM_DATA_PERCENT / 100))" ]
  [ "$tail" -ge "$((total * (100 - DANCAM_DATA_PERCENT) / 100))" ]
done

if commission_layout "$((DANCAM_MIN_TOTAL_SECTORS - 1))" 10502144 "$ALIGN" >/dev/null; then
  echo "sub-32 GB card was accepted" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
state="$TMP/state.json"
printf '%s\n' '{"state":"complete","reason":null}' > "$state"
if commission_needs_run "$state"; then
  echo "completed commissioning replay was not fenced" >&2
  exit 1
fi

marker="$TMP/marker.json"
envelope="$TMP/envelope.json"
printf '%s\n' '{"image_id":"image-a"}' > "$marker"
printf '%s\n' '{"schema":"dancam-commissioning-v1","image_id":"image-a","unit_id":"0123456789","ssid":"dancam-0123456789","psk":"0123456789012345678901","nonce":"0123456789012345678901"}' > "$envelope"
validate_commissioning_envelope "$marker" "$envelope"
sed -i.bak 's/image-a/image-b/' "$envelope"
if validate_commissioning_envelope "$marker" "$envelope"; then
  echo "mismatched envelope was accepted" >&2
  exit 1
fi

development_marker="$TMP/development-marker.json"
development_envelope="$TMP/development-envelope.json"
authorized_key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEuUXswHZHr/YK+QEu1Q2Zm8Qn9Jm8R7qYINl08PcgWz dev;,$()[]{}'
home_ssid='home;,$()[]{}'
home_psk='home-psk;,$()[]{} sentinel'
ap_psk='ap-psk;,$()[]{} sentinel'
printf '%s\n' '{"schema":"dancam-image-marker-v1","image_id":"image-dev","profile":"development"}' \
  > "$development_marker"
jq -n \
  --arg authorized_key "$authorized_key" \
  --arg home_wifi_ssid "$home_ssid" \
  --arg home_wifi_psk "$home_psk" \
  --arg access_point_psk "$ap_psk" \
  '{schema:"dancam-development-commissioning-v1",image_id:"image-dev",profile:"development",login_user:"dev_user",authorized_key:$authorized_key,home_wifi_ssid:$home_wifi_ssid,home_wifi_psk:$home_wifi_psk,access_point_psk:$access_point_psk,nonce:"0123456789012345678901"}' \
  > "$development_envelope"
validate_development_commissioning_envelope "$development_marker" "$development_envelope"
for invalid_filter in \
  '.image_id = "wrong-image"' \
  '.profile = "production"' \
  '.login_user = "bad user"' \
  '.home_wifi_ssid = ""' \
  '.home_wifi_ssid = "home\n"' \
  '.home_wifi_psk = "short"' \
  '.access_point_psk = "short"'; do
  jq "$invalid_filter" "$development_envelope" > "$TMP/invalid-development-envelope.json"
  if validate_development_commissioning_envelope \
    "$development_marker" "$TMP/invalid-development-envelope.json"; then
    echo "invalid development envelope was accepted: $invalid_filter" >&2
    exit 1
  fi
done

namespace="$TMP/data"
mkdir -p "$namespace/rec/state"
chmod 755 "$namespace/rec" "$namespace/rec/state"
validate_recording_namespace "$namespace" "$(id -u)" "$(id -g)"

if validate_recording_namespace "$namespace" "$(( $(id -u) + 1 ))" "$(id -g)"; then
  echo "incorrect recording namespace owner was accepted" >&2
  exit 1
fi

chmod 555 "$namespace/rec"
if validate_recording_namespace "$namespace" "$(id -u)" "$(id -g)"; then
  echo "non-writable recording namespace was accepted" >&2
  exit 1
fi
chmod 755 "$namespace/rec"

rmdir "$namespace/rec/state"
if validate_recording_namespace "$namespace" "$(id -u)" "$(id -g)"; then
  echo "incomplete recording namespace was accepted" >&2
  exit 1
fi

commission_root="$TMP/commission-root"
mock_bin="$TMP/mock-bin"
mock_lib="$TMP/mock-lib"
mkdir -p \
  "$commission_root/boot/firmware/dancam" \
  "$commission_root/persist/dancam" \
  "$commission_root/data/rec/state" \
  "$commission_root/run/dancam-data/rec/state" \
  "$commission_root/etc/ssh/sshd_config.d" \
  "$commission_root/run" \
  "$mock_bin" "$mock_lib"
cp "$ROOT/raspi/system/card-layout.env" "$mock_lib/card-layout.env"
cp "$ROOT/raspi/image/commission-policy.sh" "$mock_lib/commission-policy.sh"
cp "$development_marker" "$commission_root/boot/firmware/dancam/image.json"
cp "$development_envelope" "$commission_root/boot/firmware/dancam/commissioning.json"
printf '%s\n' '{"state":"preparing","reason":null}' \
  > "$commission_root/persist/dancam/commissioning.json"
: > "$commission_root/etc/machine-id"
: > "$commission_root/etc/ssh/sshd_config"

cat > "$mock_bin/install" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o|-g) shift 2 ;;
    *) args+=("$1"); shift ;;
  esac
done
exec /usr/bin/install "${args[@]}"
EOF
cat > "$mock_bin/id" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = -u ] && [ "${2:-}" = dev_user ] && exit 1
exec /usr/bin/id "$@"
EOF
cat > "$mock_bin/useradd" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DANCAM_COMMISSION_TEST_COMMAND_LOG"
mkdir -p "$DANCAM_COMMISSION_ROOT/home/dev_user"
EOF
cat > "$mock_bin/usermod" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DANCAM_COMMISSION_TEST_COMMAND_LOG"
EOF
cat > "$mock_bin/systemd-machine-id-setup" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$DANCAM_COMMISSION_TEST_MACHINE_ID" > "$DANCAM_COMMISSION_ROOT/etc/machine-id"
EOF
cat > "$mock_bin/blockdev" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 125000000
EOF
cat > "$mock_bin/sfdisk" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = --json ]; then
  printf '%s\n' '{"partitiontable":{"partitions":[{},{},{},{"start":10502144}]}}'
else
  cat >> "$DANCAM_COMMISSION_TEST_PARTITION_LOG"
fi
EOF
cat > "$mock_bin/nmcli" <<'EOF'
#!/usr/bin/env bash
{
  printf '<call>\n'
  printf '%s\n' "$@"
  printf '</call>\n'
} >> "$DANCAM_COMMISSION_TEST_NMCLI_ARGUMENTS"
EOF
cat > "$mock_bin/logger" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DANCAM_COMMISSION_TEST_SYSTEM_LOG"
EOF
cat > "$mock_bin/mountpoint" <<'EOF'
#!/usr/bin/env bash
[ -f "$DANCAM_COMMISSION_TEST_DATA_MOUNTED" ]
EOF
cat > "$mock_bin/umount" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "$DANCAM_COMMISSION_ROOT/data" ]; then
  rm -f "$DANCAM_COMMISSION_TEST_DATA_MOUNTED"
fi
EOF
cat > "$mock_bin/mount" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "$DANCAM_COMMISSION_ROOT/data" ]; then
  touch "$DANCAM_COMMISSION_TEST_DATA_MOUNTED"
fi
EOF
for command in flock sync visudo sshd partx udevadm e2fsck resize2fs systemctl chown; do
  cat > "$mock_bin/$command" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
done
chmod +x "$mock_bin"/*

export DANCAM_COMMISSION_ROOT="$commission_root"
export DANCAM_COMMISSION_LIB_ROOT="$mock_lib"
export DANCAM_COMMISSION_DEVICE=/dev/mock-card
export DANCAM_COMMISSION_DATA_PART=/dev/mock-card4
DANCAM_COMMISSION_SERVICE_OWNER=$(id -u)
DANCAM_COMMISSION_SERVICE_GROUP=$(id -g)
export DANCAM_COMMISSION_SERVICE_OWNER DANCAM_COMMISSION_SERVICE_GROUP
export DANCAM_COMMISSION_TEST_MACHINE_ID=0123456789abcdef0123456789abcdef
export DANCAM_COMMISSION_TEST_STORAGE_GENERATION=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
export DANCAM_COMMISSION_TEST_COMMAND_LOG="$TMP/commands.log"
export DANCAM_COMMISSION_TEST_NMCLI_ARGUMENTS="$TMP/nmcli-arguments"
export DANCAM_COMMISSION_TEST_SYSTEM_LOG="$TMP/system.log"
export DANCAM_COMMISSION_TEST_PARTITION_LOG="$TMP/partition.log"
export DANCAM_COMMISSION_TEST_DATA_MOUNTED="$TMP/data-mounted"
touch "$DANCAM_COMMISSION_TEST_DATA_MOUNTED"
PATH="$mock_bin:$PATH" bash "$ROOT/raspi/image/commission.sh" \
  > "$TMP/commission-stdout" 2> "$TMP/commission-stderr"

[ "$(jq -r .state "$commission_root/persist/dancam/commissioning.json")" = complete ]
[ -f "$commission_root/persist/dancam/storage-admitted" ]
[ -f "$DANCAM_COMMISSION_TEST_DATA_MOUNTED" ]
[ ! -e "$commission_root/boot/firmware/dancam/commissioning.json" ]
[ "$(cat "$commission_root/etc/machine-id")" = "$DANCAM_COMMISSION_TEST_MACHINE_ID" ]
[ -s "$commission_root/etc/ssh/ssh_host_ed25519_key" ]
[ "$(jq -r .storage_generation "$commission_root/run/dancam-data/rec/state/state.json")" \
  = "$DANCAM_COMMISSION_TEST_STORAGE_GENERATION" ]
[ "$DANCAM_COMMISSION_TEST_MACHINE_ID" \
  != "${DANCAM_COMMISSION_TEST_STORAGE_GENERATION//-/}" ]
[ "$(cat "$commission_root/home/dev_user/.ssh/authorized_keys")" = "$authorized_key" ]
[ "$(stat -f '%Lp' "$commission_root/home/dev_user/.ssh/authorized_keys")" = 600 ]
[ "$(cat "$commission_root/etc/sudoers.d/60-dancam-dev_user")" \
  = 'dev_user ALL=(ALL:ALL) NOPASSWD: ALL' ]
grep -Fqx 'AuthenticationMethods publickey' \
  < <(sed 's/^[[:space:]]*//' "$commission_root/etc/ssh/sshd_config.d/60-dancam-development.conf")
for expected in dancam-home "$home_ssid" "$home_psk" dancam-ap dancam-dev "$ap_psk"; do
  grep -Fqx "$expected" "$TMP/nmcli-arguments"
done
network_secret_reached_profile() {
  local profile=$1 secret=$2
  awk -v wanted_profile="$profile" -v wanted_secret="$secret" '
    $0 == "<call>" { in_call=1; saw_profile=0; saw_secret=0; previous=""; next }
    $0 == "</call>" {
      if (saw_profile && saw_secret) found=1
      in_call=0
      next
    }
    in_call && $0 == wanted_profile { saw_profile=1 }
    in_call && previous == "802-11-wireless-security.psk" && $0 == wanted_secret {
      saw_secret=1
    }
    in_call { previous=$0 }
    END { exit !found }
  ' "$TMP/nmcli-arguments"
}
network_secret_reached_profile dancam-home "$home_psk"
network_secret_reached_profile dancam-ap "$ap_psk"
if grep -F -e "$home_psk" -e "$ap_psk" \
  "$TMP/commission-stdout" "$TMP/commission-stderr" "$TMP/system.log"; then
  echo 'development Wi-Fi secret leaked into commissioning output or logs' >&2
  exit 1
fi
grep -Fq -- '--create-home --shell /bin/bash --groups sudo dev_user' "$TMP/commands.log"
grep -Fqx -- '--lock dev_user' "$TMP/commands.log"
[ "$(wc -l < "$TMP/partition.log" | tr -d ' ')" -eq 1 ]

rm "$commission_root/persist/dancam/storage-admitted"
PATH="$mock_bin:$PATH" bash "$ROOT/raspi/image/commission.sh"
[ "$(wc -l < "$TMP/partition.log" | tr -d ' ')" -eq 1 ]
[ -f "$commission_root/persist/dancam/storage-admitted" ]

jq '.authorized_key = "ssh-ed25519 AAAA invalid"' "$development_envelope" \
  > "$commission_root/boot/firmware/dancam/commissioning.json"
printf '%s\n' '{"state":"preparing","reason":null}' \
  > "$commission_root/persist/dancam/commissioning.json"
if PATH="$mock_bin:$PATH" bash "$ROOT/raspi/image/commission.sh" >/dev/null 2>&1; then
  echo 'cryptographically invalid development SSH key was commissioned' >&2
  exit 1
fi
[ "$(jq -r .state "$commission_root/persist/dancam/commissioning.json")" = failed ]
[ "$(jq -r .reason "$commission_root/persist/dancam/commissioning.json")" \
  = authorized_key_invalid ]

cp "$development_envelope" "$commission_root/boot/firmware/dancam/commissioning.json"
printf '%s\n' '{"state":"preparing","reason":null}' \
  > "$commission_root/persist/dancam/commissioning.json"
jq '.image_id = "different-image"' "$development_marker" \
  > "$commission_root/boot/firmware/dancam/image.json"
if PATH="$mock_bin:$PATH" bash "$ROOT/raspi/image/commission.sh" >/dev/null 2>&1; then
  echo 'mismatched development envelope was commissioned' >&2
  exit 1
fi
[ "$(jq -r .state "$commission_root/persist/dancam/commissioning.json")" = failed ]
[ "$(jq -r .reason "$commission_root/persist/dancam/commissioning.json")" \
  = commissioning_envelope_invalid ]

production_root="$TMP/production-root"
mkdir -p \
  "$production_root/boot/firmware/dancam" \
  "$production_root/persist/dancam" \
  "$production_root/etc" \
  "$production_root/data" \
  "$production_root/run/dancam-data/rec/state"
printf '%s\n' '{"schema":"dancam-image-marker-v1","image_id":"image-production"}' \
  > "$production_root/boot/firmware/dancam/image.json"
printf '%s\n' '{"schema":"dancam-commissioning-v1","image_id":"image-production","unit_id":"0123456789","ssid":"dancam-0123456789","psk":"0123456789012345678901","nonce":"0123456789012345678901"}' \
  > "$production_root/boot/firmware/dancam/commissioning.json"
printf '%s\n' '{"state":"preparing","reason":null}' \
  > "$production_root/persist/dancam/commissioning.json"
: > "$production_root/etc/machine-id"
export DANCAM_COMMISSION_ROOT="$production_root"
export DANCAM_COMMISSION_TEST_MACHINE_ID=fedcba9876543210fedcba9876543210
export DANCAM_COMMISSION_TEST_STORAGE_GENERATION=bbbbbbbb-cccc-4ddd-8eee-ffffffffffff
PATH="$mock_bin:$PATH" bash "$ROOT/raspi/image/commission.sh"
[ "$(jq -r .state "$production_root/persist/dancam/commissioning.json")" = complete ]
[ "$(cat "$production_root/persist/machine-id")" = "$DANCAM_COMMISSION_TEST_MACHINE_ID" ]
[ -f "$production_root/persist/dancam/envelope.json" ]
[ -f "$production_root/boot/firmware/dancam/commissioning.json" ]
production_profile="$production_root/persist/nm/system-connections/dancam-ap.nmconnection"
grep -Fqx 'ssid=dancam-0123456789' "$production_profile"
grep -Fqx 'psk=0123456789012345678901' "$production_profile"
echo "commissioning geometry and replay tests passed"
