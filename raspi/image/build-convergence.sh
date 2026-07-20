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

run_production_convergence() {
  local image_root=$1 service_binary=$2 image_id=$3 root_partuuid=$4
  local wifi_country=$5 persist_label=$6 data_label=$7
  local ansible_dir vars_file first_log second_log changed pass
  ansible_dir="$DANCAM_REPOSITORY_ROOT/raspi/ansible"
  vars_file=$(mktemp)
  first_log=$(mktemp)
  second_log=$(mktemp)

  jq -n \
    --arg service_binary "$service_binary" \
    --arg image_id "$image_id" \
    --arg root_partuuid "$root_partuuid" \
    --arg wifi_country "$wifi_country" \
    --arg persist_label "$persist_label" \
    --arg data_label "$data_label" \
    '{dancam_service_binary:$service_binary,dancam_image_id:$image_id,dancam_root_partuuid:$root_partuuid,dancam_wifi_country:$wifi_country,dancam_persist_label:$persist_label,dancam_data_label:$data_label}' \
    > "$vars_file"

  for pass in first second; do
    local log=$first_log
    [ "$pass" = first ] || log=$second_log
    if ! ANSIBLE_CONFIG="$ansible_dir/ansible.cfg" ANSIBLE_NOCOLOR=1 \
      ansible-playbook \
        -i "$ansible_dir/production-inventory.ini" \
        "$ansible_dir/production.yml" \
        -e "ansible_host=$image_root" \
        -e "@$vars_file" > "$log" 2>&1; then
      cat "$log" >&2
      rm -f "$vars_file" "$first_log" "$second_log"
      return 1
    fi
    cat "$log"
  done

  if ! changed=$(production_recap_changed "$second_log"); then
    echo "raspi-image: could not read the second production-play recap" >&2
    rm -f "$vars_file" "$first_log" "$second_log"
    return 1
  fi
  if [ "$changed" -ne 0 ]; then
    echo "raspi-image: second production play was not idempotent (changed=$changed)" >&2
    rm -f "$vars_file" "$first_log" "$second_log"
    return 1
  fi

  rm -f "$vars_file" "$first_log" "$second_log"
}
