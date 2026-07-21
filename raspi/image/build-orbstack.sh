#!/usr/bin/env bash
# Run the privileged production image build in a reusable OrbStack ARM64 Linux VM.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
PROFILE=${1:-production}
[ "$#" -le 1 ] || { echo 'usage: build-orbstack.sh [production|development]' >&2; exit 64; }
case "$PROFILE" in
  production|development) ;;
  *) echo "raspi-image: unknown image profile: $PROFILE" >&2; exit 64 ;;
esac
MACHINE=${DANCAM_IMAGE_BUILDER_MACHINE:-dancam-builder}
DISTRO=nixos:25.11
KEY=${DANCAM_IMAGE_SIGNING_KEY:-"$ROOT/secrets/image-release.key"}

die() { echo "raspi-image: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "missing required tool: $1"; }

need orbctl
[ "$(uname -s)" = Darwin ] || die "OrbStack image builds must be launched from macOS"
[ "$(uname -m)" = arm64 ] || die "the OrbStack image builder requires an Apple Silicon Mac"
if [ "$PROFILE" = production ]; then
  [ -f "$KEY" ] || die "missing image signing key: $KEY"
  git -C "$ROOT" diff --quiet || die "tracked source changes must be committed before an image build"
  git -C "$ROOT" diff --cached --quiet || die "staged source changes must be committed before an image build"

  KEY_DIR=$(cd "$(dirname "$KEY")" && pwd -P)
  KEY="$KEY_DIR/$(basename "$KEY")"
  case "$KEY" in
    "$ROOT"/*) KEY_RELATIVE=${KEY#"$ROOT"/} ;;
    *) die "the signing key must be inside the shared checkout (use secrets/)" ;;
  esac
fi

if ! orbctl info "$MACHINE" >/dev/null 2>&1; then
  echo "==> creating OrbStack builder $MACHINE ($DISTRO, arm64)"
  orbctl create --arch arm64 --cpus 4 --memory 8G --disk 64G "$DISTRO" "$MACHINE"
else
  echo "==> reusing OrbStack builder $MACHINE"
fi

GUEST_OS=$(orbctl run --machine "$MACHINE" uname -s)
GUEST_ARCH=$(orbctl run --machine "$MACHINE" uname -m)
[ "$GUEST_OS" = Linux ] || die "$MACHINE is not a Linux machine"
case "$GUEST_ARCH" in
  aarch64|arm64) ;;
  *) die "$MACHINE is not ARM64 (reported $GUEST_ARCH)" ;;
esac

orbctl run --machine "$MACHINE" sh -c \
  'command -v nix >/dev/null && command -v sudo >/dev/null && sudo -n true' \
  || die "$MACHINE lacks Nix or passwordless sudo"

echo "==> building $PROFILE image in OrbStack"
if [ "$PROFILE" = production ]; then
  orbctl run --machine "$MACHINE" --path --workdir "$ROOT" \
    env "DANCAM_IMAGE_SIGNING_KEY=$KEY_RELATIVE" \
    nix --extra-experimental-features 'nix-command flakes' \
    develop -c just _raspi-image-native production
else
  DEVELOPMENT_OUT=${DANCAM_IMAGE_OUT:-"$ROOT/.dancam-development-image"}
  case "$DEVELOPMENT_OUT" in
    "$ROOT"/*) ;;
    *) die "development image output must be inside the shared checkout" ;;
  esac
  orbctl run --machine "$MACHINE" --path --workdir "$ROOT" \
    env "DANCAM_IMAGE_OUT=$DEVELOPMENT_OUT" \
    nix --extra-experimental-features 'nix-command flakes' \
    develop -c just _raspi-image-native development
fi
