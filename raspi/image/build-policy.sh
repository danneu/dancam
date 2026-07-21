#!/usr/bin/env bash

dos_partition_uuid() {
  local id=${1#0x} partition=$2
  [[ "$id" =~ ^[a-fA-F0-9]{8}$ ]] || return 1
  [[ "$partition" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s-%02d\n' "${id,,}" "$partition"
}

install_temporary_resolver() {
  local source=$1 target=$2
  install -m 0644 "$source" "$target"
}

wait_for_paths() {
  local attempts=$1 delay=$2 path missing
  shift 2
  while [ "$attempts" -gt 0 ]; do
    missing=0
    for path in "$@"; do
      [ -e "$path" ] || missing=1
    done
    [ "$missing" -eq 1 ] || return 0
    attempts=$((attempts - 1))
    [ "$attempts" -eq 0 ] || sleep "$delay"
  done
  return 1
}
