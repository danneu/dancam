#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for card in one two; do
  mkdir -p "$TMP/$card/boot" "$TMP/$card/recovery"
  swift -module-cache-path "$TMP/module-cache" \
    "$ROOT/raspi/flash/make-personalization.swift" image-a \
    "$TMP/$card/boot" "$TMP/$card/recovery" > "$TMP/$card/unit-id"
done

one_id=$(cat "$TMP/one/unit-id")
two_id=$(cat "$TMP/two/unit-id")
[[ "$one_id" =~ ^[a-f0-9]{10}$ ]]
[[ "$two_id" =~ ^[a-f0-9]{10}$ ]]
[ "$one_id" != "$two_id" ]

value() {
  /usr/bin/plutil -extract "$2" raw -o - "$1"
}
one_envelope="$TMP/one/boot/dancam/commissioning.json"
two_envelope="$TMP/two/boot/dancam/commissioning.json"
[ "$(value "$one_envelope" image_id)" = image-a ]
[ "$(value "$one_envelope" ssid)" = "dancam-$one_id" ]
[ "$(value "$two_envelope" ssid)" = "dancam-$two_id" ]
one_psk=$(value "$one_envelope" psk)
two_psk=$(value "$two_envelope" psk)
[ "${#one_psk}" -ge 22 ]
[ "${#two_psk}" -ge 22 ]
[ "$one_psk" != "$two_psk" ]
[ "$(value "$one_envelope" nonce)" != "$(value "$two_envelope" nonce)" ]

for card in one two; do
  id=$(cat "$TMP/$card/unit-id")
  [ -s "$TMP/$card/recovery/dancam-$id.txt" ]
  [ -s "$TMP/$card/recovery/dancam-$id-setup.png" ]
done

development_boot="$TMP/development/boot"
mkdir -p "$development_boot"
login_user='dev_user'
home_ssid='home;,$()[]{}'
home_psk='home-psk;,$()[]{} sentinel'
ap_psk='ap-psk;,$()[]{} sentinel'
authorized_key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEuUXswHZHr/YK+QEu1Q2Zm8Qn9Jm8R7qYINl08PcgWz dev;,$()[]{}'
jq -n \
  --arg login_user "$login_user" \
  --arg authorized_key "$authorized_key" \
  --arg home_wifi_ssid "$home_ssid" \
  --arg home_wifi_psk "$home_psk" \
  --arg access_point_psk "$ap_psk" \
  '{login_user:$login_user,authorized_key:$authorized_key,home_wifi_ssid:$home_wifi_ssid,home_wifi_psk:$home_wifi_psk,access_point_psk:$access_point_psk}' \
  > "$TMP/development-input.json"
swift -module-cache-path "$TMP/module-cache" \
  "$ROOT/raspi/flash/make-development-personalization.swift" image-a \
  "$development_boot" < "$TMP/development-input.json" \
  > "$TMP/development-stdout" 2> "$TMP/development-stderr"
[ ! -s "$TMP/development-stdout" ]
[ ! -s "$TMP/development-stderr" ]
development_envelope="$development_boot/dancam/commissioning.json"
[ "$(value "$development_envelope" schema)" = dancam-development-commissioning-v1 ]
[ "$(value "$development_envelope" image_id)" = image-a ]
[ "$(value "$development_envelope" profile)" = development ]
[ "$(value "$development_envelope" login_user)" = "$login_user" ]
[ "$(value "$development_envelope" authorized_key)" = "$authorized_key" ]
[ "$(value "$development_envelope" home_wifi_ssid)" = "$home_ssid" ]
[ "$(value "$development_envelope" home_wifi_psk)" = "$home_psk" ]
[ "$(value "$development_envelope" access_point_psk)" = "$ap_psk" ]
[ "${#home_psk}" -gt 0 ]
[ "${#ap_psk}" -gt 0 ]
if grep -R -F -e "$home_psk" -e "$ap_psk" \
  "$TMP/development-stdout" "$TMP/development-stderr" "$TMP/one" "$TMP/two"; then
  echo 'development Wi-Fi secret leaked outside its per-card envelope' >&2
  exit 1
fi

jq '.home_wifi_psk = "short"' "$TMP/development-input.json" > "$TMP/invalid-input.json"
if swift -module-cache-path "$TMP/module-cache" \
  "$ROOT/raspi/flash/make-development-personalization.swift" image-a \
  "$TMP/invalid-boot" < "$TMP/invalid-input.json" \
  > "$TMP/invalid-stdout" 2> "$TMP/invalid-stderr"; then
  echo 'invalid development Wi-Fi credential was accepted' >&2
  exit 1
fi
[ ! -s "$TMP/invalid-stdout" ]
if grep -Fq short "$TMP/invalid-stderr"; then
  echo 'invalid credential value leaked into validation diagnostics' >&2
  exit 1
fi
echo "personalization uniqueness tests passed"
