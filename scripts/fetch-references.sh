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

# linux: the Raspberry Pi kernel fork, for the bcm2835-codec V4L2 M2M driver (the /dev/video11
# H.264 encoder a Rust camera owner would drive) plus the bcm2835-unicam CSI-2 receiver. See
# docs/research/1-rust-camera-owner.md. The repo is gigabytes, so we sparse-fetch only those two
# driver folders (see LINUX_SPARSE below). Pinned to the stable_YYYYMMDD tag matching the Pi's
# running kernel (uname -r 6.18.34+rpt == tag stable_20260609, kernel 6.18.34, same OS bundle date
# as the libcamera pin); confirm/bump via `just references-pi-version`.
LINUX_REF="${LINUX_REF:-stable_20260609}"
# Space-separated subtrees to check out for linux (only meaningful with a non-empty sparse field).
LINUX_SPARSE="drivers/staging/vc04_services/bcm2835-codec drivers/media/platform/bcm2835"

# Each entry: name|git-url|ref|sparse-paths. An empty sparse field does a normal shallow clone
# (picamera2, libcamera). A non-empty field (space-separated subtrees) does a treeless, sparse,
# shallow clone that fetches only those subtrees -- for repos too large to clone whole (linux).
REFERENCES=(
  "picamera2|https://github.com/raspberrypi/picamera2.git|${PICAMERA2_REF}|"
  "libcamera|https://github.com/raspberrypi/libcamera.git|${LIBCAMERA_REF}|"
  "linux|https://github.com/raspberrypi/linux.git|${LINUX_REF}|${LINUX_SPARSE}"
)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"
mkdir -p references

for entry in "${REFERENCES[@]}"; do
  IFS='|' read -r name url ref sparse <<<"$entry"
  dest="references/$name"
  if [ -d "$dest/.git" ]; then
    echo "==> updating $name -> $ref"
    git -C "$dest" fetch --depth 1 --tags origin "$ref"
    git -C "$dest" checkout --quiet --detach FETCH_HEAD
  elif [ -n "$sparse" ]; then
    # Treeless + sparse + shallow: fetch only the listed subtrees, not the whole (huge) repo.
    echo "==> cloning $name @ $ref (sparse: $sparse)"
    read -ra sparse_paths <<<"$sparse"
    git clone --filter=tree:0 --no-checkout --depth 1 --branch "$ref" "$url" "$dest"
    git -C "$dest" sparse-checkout set --no-cone "${sparse_paths[@]}"
    git -C "$dest" checkout --quiet
  else
    echo "==> cloning $name @ $ref"
    git clone --depth 1 --branch "$ref" "$url" "$dest"
  fi
done

echo "==> references seeded under references/"
