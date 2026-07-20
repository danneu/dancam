#!/usr/bin/env bash

commission_needs_run() {
  [ ! -f "$1" ] || [ "$(jq -r .state "$1" 2>/dev/null)" != complete ]
}

commission_layout() {
  local total=$1 start=$2 align=${3:-$DANCAM_ALIGN_SECTORS} limit size
  [ "$total" -ge "$DANCAM_MIN_TOTAL_SECTORS" ] || return 1
  limit=$(( (total * DANCAM_DATA_PERCENT / 100 / align) * align ))
  size=$((limit - start))
  [ "$size" -gt 0 ] || return 1
  printf '%s %s\n' "$size" "$limit"
}

validate_commissioning_envelope() {
  local marker=$1 envelope=$2 schema image_id unit_id ssid psk nonce
  schema=$(jq -er .schema "$envelope") || return 1
  image_id=$(jq -er .image_id "$envelope") || return 1
  unit_id=$(jq -er .unit_id "$envelope") || return 1
  ssid=$(jq -er .ssid "$envelope") || return 1
  psk=$(jq -er .psk "$envelope") || return 1
  nonce=$(jq -er .nonce "$envelope") || return 1
  [ "$schema" = dancam-commissioning-v1 ] || return 1
  [ "$image_id" = "$(jq -er .image_id "$marker")" ] || return 1
  [[ "$unit_id" =~ ^[a-f0-9]{10}$ ]] || return 1
  [ "$ssid" = "dancam-$unit_id" ] || return 1
  [ "${#psk}" -ge 22 ] || return 1
  [ "${#nonce}" -ge 22 ] || return 1
}

prepare_recording_namespace() {
  local data_root=$1 owner=$2 group=$3
  install -d -o "$owner" -g "$group" -m 755 "$data_root/rec"
  install -d -o "$owner" -g "$group" -m 755 "$data_root/rec/state"
}
