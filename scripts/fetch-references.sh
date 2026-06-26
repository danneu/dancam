#!/usr/bin/env bash
# scripts/fetch-references.sh -- seed/refresh third-party source clones under references/.
#
# Clones each reference at a pinned version (git tag/branch/commit) so the source we read
# matches the tool we actually run. references/ is git-ignored; re-run any time to reseed.
# Confirm/bump the pins against the Pi with `just references-pi-version`.
set -euo pipefail

# picamera2: match the python3-picamera2 version apt installs on Raspberry Pi OS Trixie.
PICAMERA2_REF="${PICAMERA2_REF:-v0.3.36}"

# Each entry: name|git-url|ref. Add a line to register a new reference.
REFERENCES=(
  "picamera2|https://github.com/raspberrypi/picamera2.git|${PICAMERA2_REF}"
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
