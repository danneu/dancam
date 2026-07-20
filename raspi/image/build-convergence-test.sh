#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
source "$ROOT/raspi/image/build-convergence.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/image-root"
touch "$TMP/dancam"
chmod +x "$TMP/dancam"

cat > "$TMP/bin/ansible-playbook" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "$DANCAM_CONVERGENCE_TEST_LOG"
printf '\n' >> "$DANCAM_CONVERGENCE_TEST_LOG"
vars_file=
for arg in "$@"; do
  case "$arg" in @*) vars_file=${arg#@} ;; esac
done
[ -n "$vars_file" ]
jq -e '
  (.dancam_service_binary | length > 0) and
  (.dancam_image_id == "image-id") and
  (.dancam_root_partuuid == "01234567-02") and
  (.dancam_wifi_country == "US") and
  (.dancam_persist_label == "dancam-persist") and
  (.dancam_data_label == "dancam-data")
' "$vars_file" >/dev/null
count=0
[ ! -f "$DANCAM_CONVERGENCE_TEST_COUNT" ] || count=$(cat "$DANCAM_CONVERGENCE_TEST_COUNT")
count=$((count + 1))
printf '%s\n' "$count" > "$DANCAM_CONVERGENCE_TEST_COUNT"
changed=0
if [ "${DANCAM_CONVERGENCE_TEST_DIRTY_SECOND:-0}" = 1 ] && [ "$count" -eq 2 ]; then
  changed=1
fi
printf 'PLAY RECAP *********************************************************************\n'
printf 'production-image : ok=40 changed=%s unreachable=0 failed=0 skipped=4 rescued=0 ignored=0\n' "$changed"
EOF
chmod +x "$TMP/bin/ansible-playbook"

export PATH="$TMP/bin:$PATH"
export DANCAM_REPOSITORY_ROOT="$ROOT"
export DANCAM_CONVERGENCE_TEST_LOG="$TMP/dispatch.log"
export DANCAM_CONVERGENCE_TEST_COUNT="$TMP/count"

run_production_convergence \
  "$TMP/image-root" "$TMP/dancam" image-id 01234567-02 US dancam-persist dancam-data \
  >/dev/null
[ "$(cat "$TMP/count")" -eq 2 ]
[ "$(grep -c 'production.yml' "$TMP/dispatch.log")" -eq 2 ]
grep -Fq "ansible_host=$TMP/image-root" "$TMP/dispatch.log"

: > "$TMP/dispatch.log"
printf '0\n' > "$TMP/count"
export DANCAM_CONVERGENCE_TEST_DIRTY_SECOND=1
if run_production_convergence \
  "$TMP/image-root" "$TMP/dancam" image-id 01234567-02 US dancam-persist dancam-data \
  >/dev/null 2>&1; then
  echo "non-idempotent production convergence was accepted" >&2
  exit 1
fi
[ "$(cat "$TMP/count")" -eq 2 ]

printf '%s\n' 'production convergence tests passed'
