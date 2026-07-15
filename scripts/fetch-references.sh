#!/usr/bin/env bash
# scripts/fetch-references.sh -- seed/refresh third-party source clones under references/.
#
# Clones each reference at a pinned version (git tag/branch/commit) so the source we read
# matches the tool we actually run. references/ is git-ignored; re-run any time to reseed.
# Confirm/bump the pins against the Pi with `just references-pi-version`.
set -euo pipefail

# picamera2: match the python3-picamera2 version apt installs on Raspberry Pi OS Trixie.
PICAMERA2_REF="${PICAMERA2_REF:-v0.3.36}"

# libcamera: the Raspberry Pi FORK (not upstream) -- it is what runs on the Pi, and it
# carries the rpi pipeline handlers (src/libcamera/pipeline/rpi/{vc4,pisp}) and the IPA
# tuning (src/ipa/rpi/) that a Rust camera owner would keep. See
# docs/research/1-rust-camera-owner.md. Pinned to the fork tag matching the Pi's installed
# libcamera0.7 apt package (0.7.1+rpt20260609-1); confirm/bump via `just references-pi-version`.
LIBCAMERA_REF="${LIBCAMERA_REF:-v0.7.1+rpt20260609}"

# Each entry: name|git-url|ref. Add a line to register a new reference.
REFERENCES=(
  "picamera2|https://github.com/raspberrypi/picamera2.git|${PICAMERA2_REF}"
  "libcamera|https://github.com/raspberrypi/libcamera.git|${LIBCAMERA_REF}"
)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
mkdir -p references

for entry in "${REFERENCES[@]}"; do
  IFS='|' read -r name url ref <<<"$entry"
  dest="references/$name"
  if [ -d "$dest/.git" ]; then
    echo "==> updating $name -> $ref"
    git -C "$dest" fetch --depth 1 --tags origin "$ref"
    git -C "$dest" checkout --quiet --detach FETCH_HEAD
  else
    echo "==> cloning $name @ $ref"
    git clone --depth 1 --branch "$ref" "$url" "$dest"
  fi
done

echo "==> references seeded under references/"
