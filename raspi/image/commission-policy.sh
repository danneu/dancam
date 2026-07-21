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

validate_single_line_text() {
  local value=$1 minimum=$2 maximum=$3 bytes
  [ -n "$value" ] || return 1
  bytes=$(LC_ALL=C printf '%s' "$value" | wc -c | tr -d ' ')
  [ "$bytes" -ge "$minimum" ] && [ "$bytes" -le "$maximum" ] || return 1
  ! LC_ALL=C printf '%s' "$value" | grep -q '[[:cntrl:]]'
}

validate_wpa_psk() {
  local value=$1 bytes
  bytes=$(LC_ALL=C printf '%s' "$value" | wc -c | tr -d ' ')
  if [ "$bytes" -eq 64 ] && [[ "$value" =~ ^[a-fA-F0-9]{64}$ ]]; then
    return 0
  fi
  validate_single_line_text "$value" 8 63
}

validate_development_commissioning_envelope() {
  local marker=$1 envelope=$2 schema profile image_id login_user authorized_key
  local home_wifi_ssid home_wifi_psk access_point_psk nonce
  jq -e '
    [.schema,.profile,.image_id,.login_user,.authorized_key,.home_wifi_ssid,.home_wifi_psk,.access_point_psk,.nonce]
    | all(.[]; type == "string" and (explode | all(.[]; . >= 32 and . != 127)))
  ' "$envelope" >/dev/null || return 1
  schema=$(jq -er '.schema | select(type == "string")' "$envelope") || return 1
  profile=$(jq -er '.profile | select(type == "string")' "$envelope") || return 1
  image_id=$(jq -er '.image_id | select(type == "string")' "$envelope") || return 1
  login_user=$(jq -er '.login_user | select(type == "string")' "$envelope") || return 1
  authorized_key=$(jq -er '.authorized_key | select(type == "string")' "$envelope") || return 1
  home_wifi_ssid=$(jq -er '.home_wifi_ssid | select(type == "string")' "$envelope") || return 1
  home_wifi_psk=$(jq -er '.home_wifi_psk | select(type == "string")' "$envelope") || return 1
  access_point_psk=$(jq -er '.access_point_psk | select(type == "string")' "$envelope") || return 1
  nonce=$(jq -er '.nonce | select(type == "string")' "$envelope") || return 1

  [ "$schema" = dancam-development-commissioning-v1 ] || return 1
  [ "$profile" = development ] || return 1
  [ "$(jq -er '.profile | select(type == "string")' "$marker")" = development ] || return 1
  [ "$image_id" = "$(jq -er '.image_id | select(type == "string")' "$marker")" ] || return 1
  [[ "$login_user" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || return 1
  validate_single_line_text "$authorized_key" 16 16384 || return 1
  [[ "$authorized_key" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]][A-Za-z0-9+/]+={0,3}([[:space:]].*)?$ ]] || return 1
  validate_single_line_text "$home_wifi_ssid" 1 32 || return 1
  validate_wpa_psk "$home_wifi_psk" || return 1
  validate_wpa_psk "$access_point_psk" || return 1
  validate_single_line_text "$nonce" 22 128
}

validate_recording_namespace() {
  local data_root=$1 owner=$2 group=$3
  local path
  for path in "$data_root/rec" "$data_root/rec/state"; do
    [ "$(find "$path" -prune -type d -user "$owner" -group "$group" -perm 755 -print 2>/dev/null)" = "$path" ] \
      || return 1
  done
}
