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
