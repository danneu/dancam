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
echo "personalization uniqueness tests passed"
