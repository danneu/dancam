#!/usr/bin/env bash
#
# Build the dancam Pi service and deploy it to the camera unit.
#
# Cross-compiles a static aarch64 musl binary in the Nix flake dev shell, ships it
# plus the systemd unit to the Pi, installs both, and (re)starts the service.
# Idempotent -- safe to re-run on every code change.
#
# Defaults target the dev image (Pi on home Wi-Fi as `dancam.local`). Override via
# env, e.g.:
#   DANCAM_HOST=pi@192.168.1.50 ./raspi/deploy.sh
#   DANCAM_HOST=<user>@10.42.0.1 ./raspi/deploy.sh # while joined to the Pi AP
#   DANCAM_STATUS_TIMEOUT=120 ./raspi/deploy.sh    # seconds to wait for valid /v1/status after restart (default 60)
#
# Requires: nix (flakes) on the Mac; SSH access to the Pi; passwordless or
# interactive sudo on the Pi (the install step uses `ssh -t` so sudo can prompt).
set -euo pipefail

HOST="${DANCAM_HOST:-pi@dancam.local}"
SSH_KEY="${DANCAM_SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_KEY="${SSH_KEY/#\~/$HOME}"
TARGET="${DANCAM_TARGET:-aarch64-unknown-linux-musl}"
PORT="${DANCAM_PORT:-8080}"

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
    body="Up on $HOST -- ready to test"
    sound="Glass"
  else
    body="FAILED (exit $rc) -- see terminal"
    sound="Basso"
  fi
  osascript -e "display notification \"$body\" with title \"dancam deploy\" sound name \"$sound\""
}
trap notify_done EXIT

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BIN="raspi/service/target/$TARGET/release/dancam"
UNIT="raspi/dancam.service"
CAMERA="raspi/camera/camera.py"

echo "==> cross-building $TARGET release binary"
nix develop -c cargo zigbuild --release --target "$TARGET" \
  --manifest-path raspi/service/Cargo.toml

echo "==> shipping binary + unit + camera process to $HOST"
rsync -avz -e "ssh -i $SSH_KEY" "$BIN" "$HOST:/tmp/dancam.new"
rsync -avz -e "ssh -i $SSH_KEY" "$UNIT" "$HOST:/tmp/dancam.service"
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
  sudo install -m 0644 /tmp/dancam.service /etc/systemd/system/dancam.service
  sudo systemctl daemon-reload
  sudo systemctl enable dancam
  sudo systemctl restart dancam
  rm -f /tmp/dancam.new /tmp/dancam.service /tmp/dancam-camera.py
'

STATUS_TIMEOUT="${DANCAM_STATUS_TIMEOUT:-60}"
echo "==> waiting up to ${STATUS_TIMEOUT}s for valid dancam /v1/status on $HOST"
deadline=$(( $(date +%s) + STATUS_TIMEOUT ))
until ssh -i "$SSH_KEY" -o ConnectTimeout=5 "$HOST" \
        "curl -fsS --max-time 5 http://localhost:$PORT/v1/status | python3 -c 'import json, sys; value = json.load(sys.stdin).get(\"recording_readiness\", {}).get(\"ready\"); sys.exit(0 if isinstance(value, bool) else 1)'" 2>/dev/null; do
  if (( $(date +%s) >= deadline )); then
    echo "!! dancam did not return valid /v1/status within ${STATUS_TIMEOUT}s" >&2
    exit 1
  fi
  sleep 2
done
echo "==> dancam is up and serving on $HOST -- ready to test."
echo "==> deployed."
