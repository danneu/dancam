#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
production_role="$ROOT/raspi/ansible/roles/production_image"
cleanup_role="$ROOT/raspi/ansible/roles/release_cleanup"

for forbidden in \
  'ansible.builtin.command:' \
  'ansible.builtin.raw:' \
  'ansible.builtin.shell:' \
  'ansible.builtin.reboot:' \
  'ansible.builtin.script:' \
  'ansible.builtin.service:' \
  'ansible.builtin.service_facts:' \
  'ansible.builtin.systemd_service:' \
  'ansible.posix.mount:' \
  'notify:' \
  'swapoff' \
  '/dev/video' \
  '/proc/device-tree'; do
  if grep -R -Fq -- "$forbidden" "$production_role"; then
    echo "production role contains forbidden live action: $forbidden" >&2
    exit 1
  fi
done

for forbidden in ansible.builtin.command: ansible.builtin.raw: ansible.builtin.shell:; do
  if grep -R -Fq -- "$forbidden" "$cleanup_role"; then
    echo "release cleanup contains forbidden shell mutation: $forbidden" >&2
    exit 1
  fi
done
grep -Fq '/var/cache/apt/archives' "$cleanup_role/tasks/main.yml"
grep -Fq '/var/lib/apt/lists' "$cleanup_role/tasks/main.yml"

grep -Fq 'policy_rc_d: 101' "$production_role/tasks/packages.yml"
grep -Fq 'system_common_unit_enable_mode: offline' "$ROOT/raspi/ansible/production.yml"
common_tasks="$ROOT/raspi/ansible/roles/system_common/tasks/main.yml"
live_modules=$(grep -c 'ansible.builtin.systemd_service:' "$common_tasks")
live_guards=$(grep -c "when: system_common_unit_enable_mode == 'live'" "$common_tasks")
[ "$live_modules" -eq "$live_guards" ] || {
  echo 'a common live systemd action is not fenced from production' >&2
  exit 1
}
for forbidden in ansible.builtin.command: ansible.builtin.shell: ansible.builtin.reboot: \
  ansible.builtin.service: ansible.posix.mount:; do
  if grep -Fq -- "$forbidden" "$common_tasks"; then
    echo "common role contains an unfenced live action: $forbidden" >&2
    exit 1
  fi
done
if grep 'notify:' "$common_tasks" | grep -Fqv 'system_common_'; then
  echo 'common role contains a notification that production cannot suppress' >&2
  exit 1
fi

for competing in apt-get useradd systemctl configure_hostname DANCAM_AVAHI_VERSION; do
  if grep -Fq -- "$competing" "$ROOT/raspi/image/build.sh"; then
    echo "image builder still contains target-system configuration: $competing" >&2
    exit 1
  fi
done
if grep -q '^DANCAM_.*_VERSION=' "$ROOT/raspi/image/inputs.env"; then
  echo 'package pins remain shell-owned image inputs' >&2
  exit 1
fi

converge_line=$(grep -n '^run_production_convergence ' "$ROOT/raspi/image/build.sh" | cut -d: -f1)
cleanup_line=$(grep -n '^run_release_cleanup_convergence ' "$ROOT/raspi/image/build.sh" | cut -d: -f1)
verify_line=$(grep -n '^bash .*verify-image.sh' "$ROOT/raspi/image/build.sh" | cut -d: -f1)
inventory_line=$(grep -n '^PACKAGE_INVENTORY=' "$ROOT/raspi/image/build.sh" | cut -d: -f1)
sign_line=$(grep -n '^minisign ' "$ROOT/raspi/image/build.sh" | cut -d: -f1)
[ "$converge_line" -lt "$verify_line" ]
[ "$converge_line" -lt "$cleanup_line" ]
[ "$cleanup_line" -lt "$verify_line" ]
[ "$verify_line" -lt "$inventory_line" ]
[ "$inventory_line" -lt "$sign_line" ]

printf '%s\n' 'production offline-action policy tests passed'
