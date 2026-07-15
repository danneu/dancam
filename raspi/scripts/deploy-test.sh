#!/usr/bin/env bash
# Hardware-free coverage for deploy.sh's two status/readiness phases and diagnostics.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT="${SCRIPT_DIR}/../deploy.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "deploy-test: $*" >&2; exit 1; }

make_mocks() {
  mkdir -p "$CASE_DIR/bin"
  for command in nix rsync; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$CASE_DIR/bin/$command"
  done
  cat >"$CASE_DIR/bin/osascript" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DEPLOY_TEST_LOG.notifications"
EOF
  cat >"$CASE_DIR/bin/ssh" <<'EOF'
#!/usr/bin/env bash
log="$DEPLOY_TEST_LOG"
case "$*" in
  *v1/status*)
    count=0
    [ ! -f "$log.polls" ] || count="$(cat "$log.polls")"
    count=$((count + 1))
    echo "$count" >"$log.polls"
    token="$(printf '%s\n' "$DEPLOY_STATUS_SEQUENCE" | cut -d '|' -f "$count")"
    [ -n "$token" ] || token="$(printf '%s\n' "$DEPLOY_STATUS_SEQUENCE" | awk -F '|' '{print $NF}')"
    case "$token" in
      malformed) body='not json' ;;
      missing) body='{}' ;;
      nonboolean) body='{"recording_readiness":{"ready":"yes"}}' ;;
      false_a) body='{"recording_readiness":{"ready":false},"marker":"a"}' ;;
      false_b) body='{"recording_readiness":{"ready":false},"marker":"b"}' ;;
      true) body='{"recording_readiness":{"ready":true},"marker":"ready"}' ;;
      http_fail) exit 22 ;;
      stall)
        echo "$$" >"$log.stalled_poll_pid"
        trap '' TERM
        exec /bin/sleep 30
        ;;
      *) exit 97 ;;
    esac
    printf '%s' "$body" | python3 -c 'import json, sys; value = json.load(sys.stdin).get("recording_readiness", {}).get("ready"); sys.exit(0 if isinstance(value, bool) else 1)' || exit $?
    printf '%s' "$body"
    ;;
  *"systemctl show dancam -p Environment"*)
    echo environment >>"$log.diagnostics"
    [ ! -f "$log.polls" ] || cp "$log.polls" "$log.polls_at_diagnostics"
    [ "${DEPLOY_FAIL_DIAGNOSTIC:-}" != environment ]
    ;;
  *"findmnt /data"*)
    echo findmnt >>"$log.diagnostics"
    if [ "${DEPLOY_STALL_DIAGNOSTIC:-}" = findmnt ]; then
      echo "$$" >"$log.stalled_diagnostic_pid"
      trap '' TERM
      exec /bin/sleep 30
    fi
    ;;
  *"df -B1 /data"*) echo df >>"$log.diagnostics" ;;
  *"journalctl -u dancam -n 50 --no-pager"*)
    echo journal >>"$log.diagnostics"
    echo reached >"$log.late_sentinel"
    ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$CASE_DIR/bin/"*
}

run_case() {
  local name="$1" sequence="$2" status_timeout="$3" readiness_timeout="$4"
  CASE_DIR="$TMP/$name"
  mkdir -p "$CASE_DIR"
  make_mocks
  local started=$SECONDS
  set +e
  OUTPUT="$(env PATH="$CASE_DIR/bin:$PATH" DEPLOY_TEST_LOG="$CASE_DIR/log" \
    DEPLOY_STATUS_SEQUENCE="$sequence" DANCAM_STATUS_TIMEOUT="$status_timeout" \
    DANCAM_RECORDING_READINESS_TIMEOUT="$readiness_timeout" \
    DANCAM_DEPLOY_POLL_INTERVAL="${DEPLOY_TEST_POLL_INTERVAL:-0}" DANCAM_DEPLOY_OPERATION_TIMEOUT=1 \
    DANCAM_DEPLOY_DIAGNOSTIC_TIMEOUT=1 DANCAM_DEPLOY_KILL_GRACE=0 \
    DEPLOY_FAIL_DIAGNOSTIC="${DEPLOY_FAIL_DIAGNOSTIC:-}" \
    DEPLOY_STALL_DIAGNOSTIC="${DEPLOY_STALL_DIAGNOSTIC:-}" \
    bash "$DEPLOY_SCRIPT" 2>&1)"
  STATUS=$?
  set -e
  CASE_ELAPSED=$(( SECONDS - started ))
  unset DEPLOY_FAIL_DIAGNOSTIC DEPLOY_STALL_DIAGNOSTIC DEPLOY_TEST_POLL_INTERVAL
}

assert_no_success_notification() {
  if [ -f "$CASE_DIR/log.notifications" ] && grep -q recording-ready "$CASE_DIR/log.notifications"; then
    fail "$1 emitted a success notification"
  fi
}

run_case immediate true 0 0
[ "$STATUS" -eq 0 ] || fail "immediate ready status failed: $OUTPUT"
[ "$(cat "$CASE_DIR/log.polls")" -eq 1 ] || fail "immediate ready fetched status twice"
[ "$(grep -c recording-ready "$CASE_DIR/log.notifications")" -eq 1 ] || fail "immediate ready did not notify exactly once"
case "$OUTPUT" in *"phase 1/2"*"phase 2/2"*"recording-ready"*) ;; *) fail "success omitted phase or readiness copy" ;; esac

run_case eventual 'false_a|false_b|true' 2 2
[ "$STATUS" -eq 0 ] || fail "eventual readiness failed: $OUTPUT"
[ "$(cat "$CASE_DIR/log.polls")" -eq 3 ] || fail "eventual readiness used the wrong number of polls"

for sequence in malformed missing nonboolean http_fail; do
  run_case "phase1-$sequence" "$sequence" 0 4
  [ "$STATUS" -ne 0 ] || fail "$sequence completed phase 1"
  case "$OUTPUT" in *"did not return valid /v1/status"*) ;; *) fail "$sequence omitted phase-1 error" ;; esac
  [ ! -f "$CASE_DIR/log.diagnostics" ] || fail "$sequence ran readiness diagnostics"
  assert_no_success_notification "$sequence"
done

run_case transient 'http_fail|malformed|true' 2 2
[ "$STATUS" -eq 0 ] || fail "transient phase-1 failures did not recover: $OUTPUT"
[ "$(cat "$CASE_DIR/log.polls")" -eq 3 ] || fail "transient phase-1 case did not consume three polls"

DEPLOY_TEST_POLL_INTERVAL=0.1
run_case readiness-timeout 'false_a|false_b' 2 1
[ "$STATUS" -ne 0 ] || fail "readiness timeout succeeded"
[ "$(cat "$CASE_DIR/log.polls")" -gt 1 ] || fail "readiness timeout did not retain a later valid body"
[ "$(cat "$CASE_DIR/log.polls")" -eq "$(cat "$CASE_DIR/log.polls_at_diagnostics")" ] || fail "readiness diagnostics fetched status again"
case "$OUTPUT" in *'"marker":"b"'*"systemctl show dancam -p Environment"*"findmnt /data"*"df -B1 /data"*"journalctl -u dancam -n 50 --no-pager"*) ;; *) fail "readiness timeout omitted final retained status or diagnostics: $OUTPUT" ;; esac
[ "$(wc -l <"$CASE_DIR/log.diagnostics" | tr -d ' ')" -eq 4 ] || fail "readiness timeout did not run all diagnostics"
assert_no_success_notification readiness-timeout

DEPLOY_FAIL_DIAGNOSTIC=environment
run_case diagnostic-failure false_a 1 0
[ "$STATUS" -ne 0 ] || fail "diagnostic failure replaced the readiness error"
case "$OUTPUT" in *"did not become recording-ready"*"diagnostic failed or timed out"*) ;; *) fail "diagnostic failure hid primary or secondary error" ;; esac
[ -f "$CASE_DIR/log.late_sentinel" ] || fail "diagnostic failure stopped later diagnostics"
assert_no_success_notification diagnostic-failure

run_case stalled-poll stall 0 2
[ "$STATUS" -ne 0 ] || fail "stalled phase-1 poll succeeded"
[ "$CASE_ELAPSED" -lt 5 ] || fail "stalled phase-1 poll exceeded its harness deadline"
poll_pid="$(cat "$CASE_DIR/log.stalled_poll_pid")"
kill -0 "$poll_pid" 2>/dev/null && fail "stalled poll child was not reaped"
[ ! -f "$CASE_DIR/log.diagnostics" ] || fail "stalled phase-1 poll ran readiness diagnostics"

DEPLOY_STALL_DIAGNOSTIC=findmnt
run_case stalled-diagnostic false_a 1 0
[ "$STATUS" -ne 0 ] || fail "stalled diagnostic replaced readiness failure"
[ "$CASE_ELAPSED" -lt 5 ] || fail "stalled diagnostic exceeded its harness deadline"
diagnostic_pid="$(cat "$CASE_DIR/log.stalled_diagnostic_pid")"
kill -0 "$diagnostic_pid" 2>/dev/null && fail "stalled diagnostic child was not reaped"
[ -f "$CASE_DIR/log.late_sentinel" ] || fail "stalled diagnostic prevented later sentinel"
case "$OUTPUT" in *"did not become recording-ready"*) ;; *) fail "stalled diagnostic hid primary readiness error" ;; esac
assert_no_success_notification stalled-diagnostic

echo "deploy readiness tests OK"
