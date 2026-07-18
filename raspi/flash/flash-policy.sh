#!/usr/bin/env bash

flash_die() { echo "raspi-flash: $*" >&2; return 1; }

plist_value() {
  /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null
}

validate_flash_target() {
  local plist=$1 expected=$2 system_disk=$3
  local identifier whole internal removable writable size
  identifier=$(plist_value "$plist" DeviceIdentifier) || return 1
  whole=$(plist_value "$plist" Whole) || return 1
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
