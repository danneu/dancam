#!/usr/bin/env bash
# raspi/scripts/reset-data-test.sh -- hardware-free behavioral tests for reset-data.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESET_SCRIPT="${SCRIPT_DIR}/reset-data.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "reset-data-test: $*" >&2
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
  mkdir -p "$CASE_DIR/bin" "$CASE_DIR/data/rec"

  cat >"$CASE_DIR/bin/stat" <<'EOF'
#!/usr/bin/env bash
echo "stat $*" >>"$RESET_TEST_LOG"
if [ "${RESET_STAT_FAIL:-}" = "$3" ]; then exit 1; fi
case "$2:$3" in
  %d:/) echo 10 ;;
  %i:/) echo 100 ;;
  %d:*) echo "${RESET_DATA_DEV:-20}" ;;
  %i:*) echo "${RESET_DATA_INO:-200}" ;;
  *) exit 1 ;;
esac
EOF
  cat >"$CASE_DIR/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "systemctl $*" >>"$RESET_TEST_LOG"
if [ "$1" = stop ] && [ -n "${RESET_SIGNAL:-}" ]; then kill -"$RESET_SIGNAL" "$PPID"; fi
if [ "$1" = start ] && [ "${RESET_START_FAIL:-0}" = 1 ]; then exit 1; fi
EOF
  cat >"$CASE_DIR/bin/find" <<'EOF'
#!/usr/bin/env bash
echo "find $*" >>"$RESET_TEST_LOG"
if [ "${RESET_DELETE_FAIL:-0}" = 1 ]; then exit 23; fi
EOF
  cat >"$CASE_DIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
count_file="${RESET_TEST_LOG}.polls"
count=0
[ ! -f "$count_file" ] || count="$(cat "$count_file")"
count=$((count + 1))
echo "$count" >"$count_file"
echo "curl $count $*" >>"$RESET_TEST_LOG"
case "${RESET_STATUS_KIND:-ready}" in
  malformed) printf 'not json\n' ;;
  missing) printf '{}\n' ;;
  nonboolean) printf '{"recording_readiness":{"ready":"yes"}}\n' ;;
  false) printf '{"recording_readiness":{"ready":false}}\n' ;;
  ready)
    if [ "$count" -lt "${RESET_READY_AFTER:-1}" ]; then
      printf '{"recording_readiness":{"ready":false}}\n'
    else
      printf '{"recording_readiness":{"ready":true}}\n'
    fi
    ;;
esac
EOF
  cat >"$CASE_DIR/bin/date" <<'EOF'
#!/usr/bin/env bash
count_file="${RESET_TEST_LOG}.dates"
value=100
[ ! -f "$count_file" ] || value=$(( $(cat "$count_file") + 1 ))
echo "$value" >"$count_file"
echo "$value"
EOF
  cat >"$CASE_DIR/bin/sleep" <<'EOF'
#!/usr/bin/env bash
:
EOF
  chmod +x "$CASE_DIR/bin/"*
}

run_case() {
  local name="$1"
  shift
  CASE_DIR="$TMP/$name"
  mkdir -p "$CASE_DIR"
  make_mocks
  set +e
  OUTPUT="$(env PATH="$CASE_DIR/bin:$PATH" RESET_TEST_LOG="$CASE_DIR/log" \
    DANCAM_DATA_DIR="$CASE_DIR/data" DANCAM_RECORDING_READINESS_TIMEOUT=5 "$@" \
    bash "$RESET_SCRIPT" 2>&1)"
  STATUS=$?
  set -e
}

mounted_log() {
  printf 'stat -c %%d %s/data\nstat -c %%d /\nstat -c %%i %s/data\nstat -c %%i /' "$CASE_DIR" "$CASE_DIR"
}

run_case success env
[ "$STATUS" -eq 0 ] || fail "successful reset failed: $OUTPUT"
assert_log "$(mounted_log)"$'\nsystemctl stop dancam\nfind '"$CASE_DIR"$'/data/rec -mindepth 1 -delete\nsystemctl start dancam\ncurl 1 -fsS --max-time 5 http://localhost:8080/v1/status'

run_case missing env
rm -rf "$CASE_DIR/data"
: >"$CASE_DIR/log"
set +e
OUTPUT="$(env PATH="$CASE_DIR/bin:$PATH" RESET_TEST_LOG="$CASE_DIR/log" DANCAM_DATA_DIR="$CASE_DIR/data" bash "$RESET_SCRIPT" 2>&1)"; STATUS=$?
set -e
[ "$STATUS" -ne 0 ] || fail "missing data directory succeeded"
assert_contains "$OUTPUT" "missing or not a directory"
assert_log ""

run_case nondirectory env
rm -rf "$CASE_DIR/data"
: >"$CASE_DIR/data"
: >"$CASE_DIR/log"
set +e
OUTPUT="$(env PATH="$CASE_DIR/bin:$PATH" RESET_TEST_LOG="$CASE_DIR/log" DANCAM_DATA_DIR="$CASE_DIR/data" bash "$RESET_SCRIPT" 2>&1)"; STATUS=$?
set -e
[ "$STATUS" -ne 0 ] || fail "non-directory data path succeeded"
assert_contains "$OUTPUT" "missing or not a directory"
assert_log ""

run_case plain_directory env RESET_DATA_DEV=10 RESET_DATA_INO=200
[ "$STATUS" -ne 0 ] || fail "plain directory passed mount witness"
assert_contains "$OUTPUT" "is not a mounted filesystem"
assert_log "$(mounted_log)"

run_case stat_failure env RESET_STAT_FAIL="$TMP/stat_failure/data"
[ "$STATUS" -ne 0 ] || fail "stat failure passed mount witness"
assert_contains "$OUTPUT" "cannot stat"
assert_log "$(printf 'stat -c %%d %s/data' "$CASE_DIR")"

run_case delete_failure env RESET_DELETE_FAIL=1
[ "$STATUS" -eq 23 ] || fail "delete failure returned $STATUS instead of 23: $OUTPUT"
assert_log "$(mounted_log)"$'\nsystemctl stop dancam\nfind '"$CASE_DIR"$'/data/rec -mindepth 1 -delete\nsystemctl start dancam\ncurl 1 -fsS --max-time 5 http://localhost:8080/v1/status'

run_case interrupted env RESET_SIGNAL=TERM
[ "$STATUS" -eq 143 ] || fail "SIGTERM returned $STATUS instead of 143: $OUTPUT"
assert_log "$(mounted_log)"$'\nsystemctl stop dancam\nsystemctl start dancam\ncurl 1 -fsS --max-time 5 http://localhost:8080/v1/status'

run_case transient_readiness env RESET_READY_AFTER=3
[ "$STATUS" -eq 0 ] || fail "transient readiness failures did not recover: $OUTPUT"
[ "$(cat "$CASE_DIR/log.polls")" -eq 3 ] || fail "expected three readiness polls"
assert_contains "$(cat "$CASE_DIR/log")" "curl 3"

for kind in malformed missing nonboolean false; do
  run_case "${kind}_timeout" env DANCAM_RECORDING_READINESS_TIMEOUT=0 RESET_STATUS_KIND="$kind"
  [ "$STATUS" -ne 0 ] || fail "$kind readiness input succeeded"
done

run_case readiness_timeout env DANCAM_RECORDING_READINESS_TIMEOUT=0 RESET_READY_AFTER=999
[ "$STATUS" -ne 0 ] || fail "readiness timeout succeeded"
assert_contains "$OUTPUT" "recording is DOWN"
[ "$(cat "$CASE_DIR/log.polls")" -eq 1 ] || fail "readiness timeout was not bounded"

run_case start_failure env RESET_START_FAIL=1
[ "$STATUS" -ne 0 ] || fail "restart failure succeeded"
assert_contains "$OUTPUT" "restart it manually"
[ ! -f "$CASE_DIR/log.polls" ] || fail "readiness polling ran after restart failure"

echo "reset-data behavioral tests OK"
