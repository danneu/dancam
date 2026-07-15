#!/usr/bin/env bash
# scripts/references-pi-version.sh -- report the reference tool versions installed on the
# Pi, so the pins in scripts/fetch-references.sh can be confirmed/bumped to match.
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

echo "==> querying libcamera on $HOST"
ssh -i "$SSH_KEY" "$HOST" '
  set -eu
  # The core libcamera shared-library package. Its name carries the soname (libcamera0.5,
  # libcamera0.4, ...), so glob and print every matching package + version. The Debian
  # version maps to the Raspberry Pi fork tag to pin LIBCAMERA_REF against.
  printf "apt:\n"; dpkg-query -W -f="  \${Package} \${Version}\n" "libcamera0*" 2>/dev/null || echo "  (no libcamera0* package found)"
  # Build version string as libcamera itself reports it (best-effort; needs rpicam-apps).
  printf "build:  "; rpicam-hello --version 2>/dev/null | head -n1 || echo "(rpicam-apps not installed)"
'

echo "==> querying kernel on $HOST"
ssh -i "$SSH_KEY" "$HOST" '
  set -eu
  # Running kernel release -- the SUBLEVEL (6.12.95 vs 6.18.x) tells us which raspberrypi/linux
  # maintenance line the bcm2835-codec driver source lives on (rpi-6.12.y, rpi-6.6.y, ...).
  printf "uname:  "; uname -r
  # Installed kernel package(s) as the authoritative version, to pin LINUX_REF against.
  printf "apt:\n"; dpkg-query -W -f="  \${Package} \${Version}\n" "linux-image-*rpi*" 2>/dev/null || echo "  (no linux-image-*rpi* package found)"
'
