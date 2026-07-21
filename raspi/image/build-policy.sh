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

calculate_partition_geometry() {
  local p2_start=$1 root_size=$2 persist_size=$3 data_size=$4 align=$5
  local value p2_end p3_start p3_end p4_start p4_end

  for value in "$p2_start" "$root_size" "$persist_size" "$data_size" "$align"; do
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || return 1
  done
  [ $((p2_start % align)) -eq 0 ] || return 1

  p2_end=$((p2_start + root_size - 1))
  p3_start=$(( ((p2_end + 1 + align - 1) / align) * align ))
  p3_end=$((p3_start + persist_size - 1))
  p4_start=$(( ((p3_end + 1 + align - 1) / align) * align ))
  p4_end=$((p4_start + data_size))
  printf '%s %s %s %s %s\n' "$p2_end" "$p3_start" "$p3_end" "$p4_start" "$p4_end"
}
