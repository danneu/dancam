#!/usr/bin/env bash
# raspi/scripts/hdr-set-test.sh -- hardware-free behavioral tests for hdr-set.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HDR_SCRIPT="${SCRIPT_DIR}/hdr-set.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "hdr-set-test: $*" >&2
  exit 1
}

assert_contains() {
  case "$1" in
    *"$2"*) ;;
    *) fail "expected output to contain: $2" ;;
  esac
}

assert_log() {
  local expected="$1"
  local actual
  actual="$(cat "$CASE_DIR/log" 2>/dev/null || true)"
  [ "$actual" = "$expected" ] || fail "expected log [$expected], got [$actual]"
}

make_mocks() {
  mkdir -p "$CASE_DIR/bin" "$CASE_DIR/sysfs/v4l-subdev0"
  printf 'imx708_wide 10-001a\n' >"$CASE_DIR/sysfs/v4l-subdev0/name"

  cat >"$CASE_DIR/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $1 $2" >>"$HDR_TEST_LOG"
if [ "$1" = stop ] && [ "${HDR_INTERRUPT_AT:-}" = stop ]; then kill -"${HDR_SIGNAL:-TERM}" "$PPID"; fi
if [ "$1" = start ] && [ "${HDR_REINTERRUPT:-0}" = 1 ]; then kill -TERM "$PPID"; fi
if [ "$1" = start ] && [ "${HDR_START_FAIL:-0}" = 1 ]; then exit 1; fi
EOF
  cat >"$CASE_DIR/bin/v4l2-ctl" <<'EOF'
#!/usr/bin/env bash
echo "v4l2-ctl $*" >>"$HDR_TEST_LOG"
if [[ "$*" == *--set-ctrl* ]] && [ "${HDR_SET_FAIL:-0}" = 1 ]; then exit 1; fi
if [[ "$*" == *--get-ctrl* ]]; then echo "wide_dynamic_range: ${HDR_EXPECT_VALUE:-0}"; fi
EOF
  cat >"$CASE_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
count_file="${HDR_TEST_LOG}.polls"
count=0
[ ! -f "$count_file" ] || count="$(cat "$count_file")"
count=$((count + 1))
echo "$count" >"$count_file"
echo "curl $count" >>"$HDR_TEST_LOG"
if [ "$count" -ge "${HDR_RUNNING_AFTER:-1}" ]; then
  echo '{ "camera_state" : "running" }'
else
  echo '{"camera_state":"starting"}'
fi
EOF
  chmod +x "$CASE_DIR/bin/systemctl" "$CASE_DIR/bin/v4l2-ctl" "$CASE_DIR/bin/curl"
}

run_case() {
  local name="$1"
  local hdr_args="$2"
  shift 2
  CASE_DIR="$TMP/$name"
  mkdir -p "$CASE_DIR"
  make_mocks
  set +e
  OUTPUT="$(env PATH="$CASE_DIR/bin:$PATH" HDR_TEST_LOG="$CASE_DIR/log" \
    DANCAM_V4L_SYSFS_ROOT="$CASE_DIR/sysfs" DANCAM_HEALTH_TIMEOUT="${HDR_TIMEOUT:-2}" \
    "$@" bash "$HDR_SCRIPT" $hdr_args 2>&1)"
  STATUS=$?
  set -e
}

run_case on on env HDR_EXPECT_VALUE=1
[ "$STATUS" -eq 0 ] || fail "on failed: $OUTPUT"
assert_log $'systemctl stop dancam\nv4l2-ctl -d /dev/v4l-subdev0 --set-ctrl wide_dynamic_range=1\nv4l2-ctl -d /dev/v4l-subdev0 --get-ctrl wide_dynamic_range\nsystemctl start dancam\ncurl 1'

run_case off off env
[ "$STATUS" -eq 0 ] || fail "off failed: $OUTPUT"
assert_contains "$OUTPUT" "wide_dynamic_range: 0"
assert_log $'systemctl stop dancam\nv4l2-ctl -d /dev/v4l-subdev0 --set-ctrl wide_dynamic_range=0\nv4l2-ctl -d /dev/v4l-subdev0 --get-ctrl wide_dynamic_range\nsystemctl start dancam\ncurl 1'

run_case invalid bogus env
[ "$STATUS" -ne 0 ] || fail "invalid mode succeeded"
assert_contains "$OUTPUT" "usage: hdr-set.sh on|off"
assert_log ""

run_case missing "" env
[ "$STATUS" -ne 0 ] || fail "missing mode succeeded"
assert_contains "$OUTPUT" "usage: hdr-set.sh on|off"
assert_log ""

run_case no_sensor on env
rm -rf "$CASE_DIR/sysfs/v4l-subdev0"
: >"$CASE_DIR/log"
set +e
OUTPUT="$(env PATH="$CASE_DIR/bin:$PATH" HDR_TEST_LOG="$CASE_DIR/log" DANCAM_V4L_SYSFS_ROOT="$CASE_DIR/sysfs" bash "$HDR_SCRIPT" on 2>&1)"; STATUS=$?
set -e
[ "$STATUS" -ne 0 ] || fail "missing sensor succeeded"
assert_contains "$OUTPUT" "is the camera detected?"
assert_log ""

run_case set_failure on env HDR_SET_FAIL=1
[ "$STATUS" -ne 0 ] || fail "set failure succeeded"
assert_log $'systemctl stop dancam\nv4l2-ctl -d /dev/v4l-subdev0 --set-ctrl wide_dynamic_range=1\nsystemctl start dancam\ncurl 1'

run_case start_failure on env HDR_START_FAIL=1
[ "$STATUS" -ne 0 ] || fail "start failure succeeded"
assert_contains "$OUTPUT" "recording is DOWN"
assert_log $'systemctl stop dancam\nv4l2-ctl -d /dev/v4l-subdev0 --set-ctrl wide_dynamic_range=1\nv4l2-ctl -d /dev/v4l-subdev0 --get-ctrl wide_dynamic_range\nsystemctl start dancam'

run_case term on env HDR_INTERRUPT_AT=stop HDR_SIGNAL=TERM
[ "$STATUS" -eq 143 ] || fail "SIGTERM returned $STATUS instead of 143: $OUTPUT"
assert_log $'systemctl stop dancam\nsystemctl start dancam\ncurl 1'

run_case int on env HDR_INTERRUPT_AT=stop HDR_SIGNAL=INT
[ "$STATUS" -eq 130 ] || fail "SIGINT returned $STATUS instead of 130: $OUTPUT"
assert_log $'systemctl stop dancam\nsystemctl start dancam\ncurl 1'

run_case reinterrupt on env HDR_INTERRUPT_AT=stop HDR_SIGNAL=TERM HDR_REINTERRUPT=1
[ "$STATUS" -eq 143 ] || fail "re-interrupted recovery returned $STATUS instead of 143: $OUTPUT"
assert_log $'systemctl stop dancam\nsystemctl start dancam\ncurl 1'

run_case readiness_timeout on env DANCAM_HEALTH_TIMEOUT=0 HDR_RUNNING_AFTER=999
[ "$STATUS" -ne 0 ] || fail "readiness timeout succeeded"
assert_contains "$OUTPUT" "recording is DOWN"
assert_log $'systemctl stop dancam\nv4l2-ctl -d /dev/v4l-subdev0 --set-ctrl wide_dynamic_range=1\nv4l2-ctl -d /dev/v4l-subdev0 --get-ctrl wide_dynamic_range\nsystemctl start dancam\ncurl 1'

echo "hdr-set behavioral tests OK"
