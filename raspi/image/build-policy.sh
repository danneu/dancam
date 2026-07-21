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

tracked_worktree_fingerprint() {
  local root=$1 path digest
  {
    while IFS= read -r -d '' path; do
      printf '%s\0' "$path"
      if [ -f "$root/$path" ]; then
        digest=$(sha256sum "$root/$path" | cut -d' ' -f1) || return 1
        printf 'file:%s\0' "$digest"
      elif [ -L "$root/$path" ]; then
        printf 'link:%s\0' "$(readlink "$root/$path")"
      else
        printf 'deleted\0'
      fi
    done < <(git -C "$root" ls-files -z --cached)
  } | sha256sum | cut -d' ' -f1
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

release_version_is_valid() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

claim_release_version() {
  local out=$1 version=$2 claim path
  release_version_is_valid "$version" || {
    echo "raspi-image: invalid image version: $version" >&2
    return 1
  }

  claim="$out/.dancam-${version}.claim"
  mkdir "$claim" 2>/dev/null || return 1
  for path in \
    "$out/dancam-${version}.packages.txt" \
    "$out/dancam-${version}.img.zst" \
    "$out/dancam-${version}.img.zst.manifest.json" \
    "$out/dancam-${version}.img.zst.manifest.json.minisig"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      echo "raspi-image: release output already exists: $path" >&2
      return 1
    fi
  done
  printf '%s\n' "$version"
}

claim_generated_release_version() {
  local out=$1 revision=$2 timestamp=$3 discriminator version
  [[ "$revision" =~ ^[0-9a-fA-F]{40}$ ]] || return 1
  [[ "$timestamp" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || return 1

  for ((discriminator = 0; discriminator <= 9999; discriminator++)); do
    printf -v version '%s-%s-%04d' "$timestamp" "${revision:0:12}" "$discriminator"
    if claim_release_version "$out" "$version" >/dev/null 2>&1; then
      printf '%s\n' "$version"
      return 0
    fi
  done
  echo "raspi-image: exhausted release claims for $timestamp and ${revision:0:12}" >&2
  return 1
}
