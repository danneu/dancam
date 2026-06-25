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
#   DANCAM_HOST=dan@192.168.1.50 ./raspi/deploy.sh
#
# Requires: nix (flakes) on the Mac; SSH access to the Pi; passwordless or
# interactive sudo on the Pi (the install step uses `ssh -t` so sudo can prompt).
set -euo pipefail

HOST="${DANCAM_HOST:-dan@dancam.local}"
SSH_KEY="${DANCAM_SSH_KEY:-$HOME/.ssh/id_ed25519_danneu}"
TARGET="${DANCAM_TARGET:-aarch64-unknown-linux-musl}"
PORT="${DANCAM_PORT:-8080}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BIN="raspi/service/target/$TARGET/release/dancam"
UNIT="raspi/dancam.service"

echo "==> cross-building $TARGET release binary"
nix develop -c cargo zigbuild --release --target "$TARGET" \
  --manifest-path raspi/service/Cargo.toml

echo "==> shipping binary + unit to $HOST"
rsync -avz -e "ssh -i $SSH_KEY" "$BIN" "$HOST:/tmp/dancam.new"
rsync -avz -e "ssh -i $SSH_KEY" "$UNIT" "$HOST:/tmp/dancam.service"

echo "==> installing + restarting on $HOST (sudo may prompt)"
ssh -t -i "$SSH_KEY" "$HOST" '
  set -e
  sudo install -m 0755 /tmp/dancam.new /usr/local/bin/dancam
  sudo install -m 0644 /tmp/dancam.service /etc/systemd/system/dancam.service
  sudo systemctl daemon-reload
  sudo systemctl enable dancam
  sudo systemctl restart dancam
  rm -f /tmp/dancam.new /tmp/dancam.service
'

echo "==> health check"
ssh -i "$SSH_KEY" "$HOST" "curl -fsS http://localhost:$PORT/v1/health" && echo
echo "==> deployed."
