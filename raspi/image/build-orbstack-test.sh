#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd -P)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/checkout/secrets"
touch "$TMP/checkout/secrets/release.key"

cat > "$TMP/bin/uname" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  -s) echo Darwin ;;
  -m) echo arm64 ;;
  *) exit 64 ;;
esac
EOF

cat > "$TMP/bin/orbctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%q ' "$@" >> "$ORB_TEST_LOG"
printf '\n' >> "$ORB_TEST_LOG"
case "$1" in
  info) [ -f "$ORB_TEST_EXISTS" ] ;;
  create) touch "$ORB_TEST_EXISTS" ;;
  run)
    case " $* " in
      *" uname -s "*) echo Linux ;;
      *" uname -m "*) echo aarch64 ;;
    esac
    ;;
  *) exit 64 ;;
esac
EOF
chmod +x "$TMP/bin/uname" "$TMP/bin/orbctl"

# Run a checkout-local copy so signing-key containment is exercised without using
# or exposing the developer's real key.
mkdir -p "$TMP/checkout/raspi/image"
printf 'secrets/\n' > "$TMP/checkout/.gitignore"
cp "$ROOT/raspi/image/build-orbstack.sh" "$TMP/checkout/raspi/image/"
git -C "$TMP/checkout" init -q
git -C "$TMP/checkout" add .gitignore raspi/image/build-orbstack.sh
git -C "$TMP/checkout" -c user.name=test -c user.email=test@example.com \
  commit -qm 'test fixture'

export PATH="$TMP/bin:$PATH"
export ORB_TEST_LOG="$TMP/orb.log"
export ORB_TEST_EXISTS="$TMP/machine-exists"
export DANCAM_IMAGE_SIGNING_KEY="$TMP/checkout/secrets/release.key"

bash "$TMP/checkout/raspi/image/build-orbstack.sh"
grep -q '^create --arch arm64 --cpus 4 --memory 8G --disk 64G nixos:25.11 dancam-builder ' "$ORB_TEST_LOG"
grep -q 'DANCAM_IMAGE_SIGNING_KEY=secrets/release.key' "$ORB_TEST_LOG"
grep -Fq 'nix --extra-experimental-features nix-command\ flakes develop -c just _raspi-image-native' \
  "$ORB_TEST_LOG"

: > "$ORB_TEST_LOG"
bash "$TMP/checkout/raspi/image/build-orbstack.sh"
if grep -q '^create ' "$ORB_TEST_LOG"; then
  echo "existing OrbStack builder was recreated" >&2
  exit 1
fi
grep -q '^info dancam-builder ' "$ORB_TEST_LOG"

echo "OrbStack image builder tests passed"

printf '\n# dirty\n' >> "$TMP/checkout/raspi/image/build-orbstack.sh"
: > "$ORB_TEST_LOG"
if bash "$TMP/checkout/raspi/image/build-orbstack.sh" >/dev/null 2>&1; then
  echo "dirty tracked source was accepted" >&2
  exit 1
fi
[ ! -s "$ORB_TEST_LOG" ] || {
  echo "OrbStack was contacted before the clean-tree preflight" >&2
  exit 1
}
