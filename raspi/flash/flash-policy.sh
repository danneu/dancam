#!/usr/bin/env bash

flash_die() { echo "raspi-flash: $*" >&2; return 1; }

select_latest_release_manifest() {
  local release_dir=$1
  find "$release_dir" -name 'dancam-*.img.zst.manifest.json' -type f -print | LC_ALL=C sort | tail -1
}

manifest_raw_size() {
  local manifest=$1 raw_size
  raw_size=$(/usr/bin/plutil -extract raw_size raw -o - "$manifest") || return 1
  [[ "$raw_size" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\n' "$raw_size"
}

transfer_authenticated_image() {
  local operation=$1 artifact=$2 transfer=$3 disk=$4 identity=$5 raw_size=$6 raw_sha=$7
  case "$operation" in
    write-verify|repair-verify) ;;
    *) return 1 ;;
  esac
  zstd -dc "$artifact" | sudo "$transfer" \
    "$operation" "$disk" "$identity" "$raw_size" "$raw_sha"
}

plist_value() {
  /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null
}

validate_flash_target() {
  local plist=$1 expected=$2 system_disk=$3
  local identifier whole internal removable writable size
  identifier=$(plist_value "$plist" DeviceIdentifier) || return 1
  whole=$(plist_value "$plist" WholeDisk) || whole=$(plist_value "$plist" Whole) || return 1
  internal=$(plist_value "$plist" Internal) || return 1
  removable=$(plist_value "$plist" RemovableMedia) || return 1
  writable=$(plist_value "$plist" Writable) || return 1
  size=$(plist_value "$plist" TotalSize) || return 1
  [ "$identifier" = "$expected" ] || { flash_die "disk identifier changed"; return 1; }
  [ "$identifier" != "$system_disk" ] || { flash_die "refusing the macOS system disk"; return 1; }
  [ "$whole" = true ] || { flash_die "target is not a whole disk"; return 1; }
  [ "$internal" = false ] || { flash_die "target is internal storage"; return 1; }
  [ "$removable" = true ] || { flash_die "target is not removable media"; return 1; }
  [ "$writable" = true ] || { flash_die "target is not writable"; return 1; }
  [ "$size" -ge "$DANCAM_MIN_CARD_BYTES" ] || { flash_die "target is smaller than 32 GB"; return 1; }
}

confirmed_disk() {
  [ "$1" = "$2" ] || flash_die "confirmation did not exactly match $2"
}
