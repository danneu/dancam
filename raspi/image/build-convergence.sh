#!/usr/bin/env bash

production_recap_changed() {
  local log=$1 values
  values=$(awk '
    $1 == "production-image" {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^changed=[0-9]+$/) {
          sub(/^changed=/, "", $i)
          print $i
        }
      }
    }
  ' "$log")
  [ "$(printf '%s\n' "$values" | sed '/^$/d' | wc -l | tr -d ' ')" -eq 1 ] || return 1
  printf '%s\n' "$values"
}

run_production_play_twice() {
  local image_root=$1 playbook=$2 vars_file=$3 phase=$4
  local ansible_dir ansible_playbook chroot_exe chroot_wrapper
  local first_log second_log changed pass
  ansible_dir="$DANCAM_REPOSITORY_ROOT/raspi/ansible"
  ansible_playbook=$(command -v ansible-playbook)
  chroot_exe=$(command -v chroot)
  chroot_wrapper="$DANCAM_REPOSITORY_ROOT/raspi/image/chroot-with-target-path.sh"
  first_log=$(mktemp)
  second_log=$(mktemp)

  for pass in first second; do
    local log=$first_log
    [ "$pass" = first ] || log=$second_log
    local -a extra_vars=()
    [ -z "$vars_file" ] || extra_vars=(-e "@$vars_file")
    if ! ANSIBLE_CONFIG="$ansible_dir/ansible.cfg" ANSIBLE_NOCOLOR=1 \
      DANCAM_CHROOT_EXE="$chroot_exe" \
      "$ansible_playbook" \
        -i "$ansible_dir/production-inventory.ini" \
        "$ansible_dir/$playbook" \
        -e "ansible_host=$image_root" \
        -e "ansible_chroot_exe=$chroot_wrapper" \
        "${extra_vars[@]}" > "$log" 2>&1; then
      cat "$log" >&2
      rm -f "$first_log" "$second_log"
      return 1
    fi
    cat "$log"
  done

  if ! changed=$(production_recap_changed "$second_log"); then
    echo "raspi-image: could not read the second $phase recap" >&2
    rm -f "$first_log" "$second_log"
    return 1
  fi
  if [ "$changed" -ne 0 ]; then
    echo "raspi-image: second $phase pass was not idempotent (changed=$changed)" >&2
    rm -f "$first_log" "$second_log"
    return 1
  fi

  rm -f "$first_log" "$second_log"
}

run_production_convergence() {
  local image_root=$1 service_binary=$2 image_id=$3 root_partuuid=$4
  local wifi_country=$5 persist_label=$6 data_label=$7
  local vars_file
  vars_file=$(mktemp)

  jq -n \
    --arg service_binary "$service_binary" \
    --arg image_id "$image_id" \
    --arg root_partuuid "$root_partuuid" \
    --arg wifi_country "$wifi_country" \
    --arg persist_label "$persist_label" \
    --arg data_label "$data_label" \
    '{dancam_service_binary:$service_binary,dancam_image_id:$image_id,dancam_root_partuuid:$root_partuuid,dancam_wifi_country:$wifi_country,dancam_persist_label:$persist_label,dancam_data_label:$data_label}' \
    > "$vars_file"

  if ! run_production_play_twice \
    "$image_root" production.yml "$vars_file" 'production convergence'; then
    rm -f "$vars_file"
    return 1
  fi
  rm -f "$vars_file"
}

run_release_cleanup_convergence() {
  local image_root=$1
  run_production_play_twice "$image_root" release-cleanup.yml '' 'release cleanup'
}
