#!/usr/bin/env bash

dos_partition_uuid() {
  local id=${1#0x} partition=$2
  [[ "$id" =~ ^[a-fA-F0-9]{8}$ ]] || return 1
  [[ "$partition" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s-%02d\n' "${id,,}" "$partition"
}

configure_hostname() {
  local root=$1 hostname=$2 hosts=$1/etc/hosts
  [[ "$hostname" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1

  printf '%s\n' "$hostname" > "$root/etc/hostname"
  if grep -qE '^127\.0\.1\.1[[:space:]]' "$hosts"; then
    sed -i -E "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t$hostname/" "$hosts"
  else
    printf '127.0.1.1\t%s\n' "$hostname" >> "$hosts"
  fi
}
