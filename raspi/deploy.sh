#!/usr/bin/env bash
#
# Build the dancam Pi service and deploy it to the camera unit.
#
# Cross-compiles a static aarch64 musl binary in the Nix flake dev shell, ships it
# plus the camera owner to the Pi, installs both, and restarts the provisioned
# service unit.
# Idempotent -- safe to re-run on every code change.
#
# Defaults target the dev image (Pi on home Wi-Fi as `dancam.local`). Override via
# env, e.g.:
#   DANCAM_HOST=pi@192.168.1.50 ./raspi/deploy.sh
#   DANCAM_HOST=<user>@10.42.0.1 ./raspi/deploy.sh # while joined to the Pi AP
#   DANCAM_STATUS_TIMEOUT=120 ./raspi/deploy.sh    # valid /v1/status deadline (default 60)
#   DANCAM_RECORDING_READINESS_TIMEOUT=120 ./raspi/deploy.sh # recording-ready deadline (defaults to status deadline)
#
# Requires: nix (flakes) on the Mac; SSH access to the Pi; passwordless or
# interactive sudo on the Pi (the install step uses `ssh -t` so sudo can prompt).
set -euo pipefail

HOST="${DANCAM_HOST:-pi@dancam.local}"
SSH_KEY="${DANCAM_SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_KEY="${SSH_KEY/#\~/$HOME}"
TARGET="${DANCAM_TARGET:-aarch64-unknown-linux-musl}"
PORT="${DANCAM_PORT:-8080}"
STATUS_TIMEOUT="${DANCAM_STATUS_TIMEOUT:-60}"
RECORDING_READINESS_TIMEOUT="${DANCAM_RECORDING_READINESS_TIMEOUT:-$STATUS_TIMEOUT}"
OPERATION_TIMEOUT="${DANCAM_DEPLOY_OPERATION_TIMEOUT:-7}"
DIAGNOSTIC_TIMEOUT="${DANCAM_DEPLOY_DIAGNOSTIC_TIMEOUT:-5}"
OPERATION_KILL_GRACE="${DANCAM_DEPLOY_KILL_GRACE:-1}"
POLL_INTERVAL="${DANCAM_DEPLOY_POLL_INTERVAL:-2}"

# macOS desktop notification on exit, so a long deploy can be backgrounded and
# still ping when it's actually ready to test. The EXIT trap fires once on any
# exit path: a clean finish notifies success, a failed build/rsync/install or a
# status-timeout notifies failure, and a Ctrl-C abort stays silent.
#
# IMPORTANT: `local rc=$?` must be the first statement -- any command before it
# (even `command -v`) clobbers $? to its own status (0), so a *failed* deploy
# would take the success branch, the exact false-"ready" ping this guards against.
notify_done() {
  local rc=$?
  command -v osascript >/dev/null 2>&1 || return 0   # non-macOS: no-op
  (( rc == 130 )) && return 0                         # Ctrl-C abort: stay quiet
  local body sound
  if (( rc == 0 )); then
    body="Up on $HOST -- recording-ready"
    sound="Glass"
  else
    body="FAILED (exit $rc) -- see terminal"
    sound="Basso"
  fi
  osascript -e "display notification \"$body\" with title \"dancam deploy\" sound name \"$sound\""
}
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="raspi/service/target/$TARGET/release/dancam"
CAMERA="raspi/camera/camera.py"

run_bounded_operation() {
  local timeout="$1"
  shift

  "$@" &
  local child=$!
  python3 -c '
import os, signal, sys, time
timeout, grace, child = float(sys.argv[1]), float(sys.argv[2]), int(sys.argv[3])
time.sleep(timeout)
try:
    os.kill(child, signal.SIGTERM)
except ProcessLookupError:
    raise SystemExit(0)
time.sleep(grace)
try:
    os.kill(child, signal.SIGKILL)
except ProcessLookupError:
    pass
' "$timeout" "$OPERATION_KILL_GRACE" "$child" >/dev/null 2>&1 &
  local watchdog=$!

  local rc=0
  wait "$child" || rc=$?
  kill -TERM "$watchdog" 2>/dev/null || true
  local watchdog_rc=0
  wait "$watchdog" 2>/dev/null || watchdog_rc=$?
  (( watchdog_rc == 0 )) && rc=124
  return "$rc"
}

status_operation_timeout() {
  local deadline="$1"
  local remaining=$(( deadline - $(date +%s) ))
  if (( remaining <= 0 )); then
    printf '1\n'
  elif (( remaining < OPERATION_TIMEOUT )); then
    printf '%s\n' "$remaining"
  else
    printf '%s\n' "$OPERATION_TIMEOUT"
  fi
}

fetch_valid_status() {
  local deadline="$1"
  local bound
  bound="$(status_operation_timeout "$deadline")"
  run_bounded_operation "$bound" ssh -i "$SSH_KEY" \
    -o ConnectTimeout=5 -o ServerAliveInterval=2 -o ServerAliveCountMax=2 "$HOST" \
    "body=\"\$(curl -fsS --max-time 5 http://localhost:$PORT/v1/status)\" && printf '%s' \"\$body\" | python3 -c 'import json, sys; value = json.load(sys.stdin).get(\"recording_readiness\", {}).get(\"ready\"); sys.exit(0 if isinstance(value, bool) else 1)' && printf '%s' \"\$body\""
}

status_is_recording_ready() {
  python3 -c 'import json, sys; value = json.load(sys.stdin).get("recording_readiness", {}).get("ready"); sys.exit(0 if value is True else 1)'
}

wait_for_valid_status() {
  local deadline=$(( $(date +%s) + STATUS_TIMEOUT ))
  local body
  echo "==> phase 1/2: waiting up to ${STATUS_TIMEOUT}s for valid dancam /v1/status on $HOST" >&2
  while true; do
    if body="$(fetch_valid_status "$deadline" 2>/dev/null)"; then
      printf '%s' "$body"
      return 0
    fi
    if (( $(date +%s) >= deadline )); then
      echo "!! dancam did not return valid /v1/status within ${STATUS_TIMEOUT}s" >&2
      return 1
    fi
    sleep "$POLL_INTERVAL"
  done
}

run_readiness_diagnostics() {
  local command
  echo "==> bounded recording-readiness diagnostics for $HOST" >&2
  for command in \
    "systemctl show dancam -p Environment" \
    "findmnt /data" \
    "df -B1 /data" \
    "journalctl -u dancam -n 50 --no-pager"; do
    echo "--- $command" >&2
    if ! run_bounded_operation "$DIAGNOSTIC_TIMEOUT" ssh -i "$SSH_KEY" \
      -o ConnectTimeout=5 -o ServerAliveInterval=2 -o ServerAliveCountMax=2 \
      "$HOST" "$command"; then
      echo "!! diagnostic failed or timed out: $command" >&2
    fi
  done
}

wait_for_recording_readiness() {
  local body="$1"
  local deadline=$(( $(date +%s) + RECORDING_READINESS_TIMEOUT ))
  echo "==> phase 2/2: waiting up to ${RECORDING_READINESS_TIMEOUT}s for recording readiness on $HOST" >&2
  while true; do
    if printf '%s' "$body" | status_is_recording_ready; then
      return 0
    fi
    if (( $(date +%s) >= deadline )); then
      echo "!! dancam did not become recording-ready within ${RECORDING_READINESS_TIMEOUT}s" >&2
      echo "==> last valid /v1/status:" >&2
      printf '%s\n' "$body" >&2
      run_readiness_diagnostics
      return 1
    fi
    sleep "$POLL_INTERVAL"
    if body="$(fetch_valid_status "$deadline" 2>/dev/null)"; then
      continue
    fi
  done
}

build_and_install() {
  echo "==> cross-building $TARGET release binary"
  nix develop -c cargo zigbuild --release --target "$TARGET" \
    --manifest-path raspi/service/Cargo.toml

  echo "==> shipping binary + camera process to $HOST"
  rsync -avz -e "ssh -i $SSH_KEY" "$BIN" "$HOST:/tmp/dancam.new"
  rsync -avz -e "ssh -i $SSH_KEY" "$CAMERA" "$HOST:/tmp/dancam-camera.py"

  echo "==> installing + restarting on $HOST (sudo may prompt)"
  ssh -t -i "$SSH_KEY" "$HOST" '
  set -e
  root_options="$(findmnt -no OPTIONS /)"
  remounted_root=false
  case ",$root_options," in
    *,ro,*)
      sudo mount -o remount,rw /
      remounted_root=true
      ;;
  esac
  cleanup() {
    if [ "$remounted_root" = true ]; then
      sudo mount -o remount,ro /
    fi
  }
  trap cleanup EXIT HUP INT TERM

  sudo install -m 0755 /tmp/dancam.new /usr/local/bin/dancam
  sudo install -d /usr/local/lib/dancam
  sudo install -m 0755 /tmp/dancam-camera.py /usr/local/lib/dancam/camera.py
  sudo systemctl restart dancam
  rm -f /tmp/dancam.new /tmp/dancam-camera.py
'
}

main() {
  trap notify_done EXIT
  cd "$REPO_ROOT"
  build_and_install

  local status_body
  status_body="$(wait_for_valid_status)"
  wait_for_recording_readiness "$status_body"
  echo "==> dancam is up and recording-ready on $HOST -- ready to test."
  echo "==> deployed."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
