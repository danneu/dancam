#!/usr/bin/env bash
# scripts/references-pi-version.sh -- report the picamera2 version installed on the Pi,
# so the pin in scripts/fetch-references.sh can be confirmed/bumped to match.
set -euo pipefail

HOST="${DANCAM_HOST:-pi@dancam.local}"
SSH_KEY="${DANCAM_SSH_KEY:-$HOME/.ssh/id_ed25519}"
SSH_KEY="${SSH_KEY/#\~/$HOME}"

echo "==> querying python3-picamera2 on $HOST"
ssh -i "$SSH_KEY" "$HOST" '
  set -eu
  # apt package version is authoritative (maps to the upstream git tag); fail if absent.
  printf "apt:    "; dpkg-query -W -f="\${Version}\n" python3-picamera2
  # python dist metadata as a cross-check (best-effort; Debian may omit it).
  printf "python: "; python3 -c "import importlib.metadata as m; print(m.version(\"picamera2\"))" || echo "(unavailable)"
'
