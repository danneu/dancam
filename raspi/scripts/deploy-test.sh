#!/usr/bin/env bash
# Hardware-free status-parser coverage for deploy.sh's single reachability phase.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_SCRIPT="${SCRIPT_DIR}/../deploy.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "deploy-test: $*" >&2; exit 1; }

make_mocks() {
  mkdir -p "$CASE_DIR/bin"
  for command in nix rsync osascript; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$CASE_DIR/bin/$command"
  done
  cat >"$CASE_DIR/bin/sleep" <<'EOF'
#!/usr/bin/env bash
:
EOF
  cat >"$CASE_DIR/bin/date" <<'EOF'
#!/usr/bin/env bash
value=100
[ ! -f "$DEPLOY_TEST_LOG.dates" ] || value=$(( $(cat "$DEPLOY_TEST_LOG.dates") + 1 ))
echo "$value" >"$DEPLOY_TEST_LOG.dates"
echo "$value"
EOF
  cat >"$CASE_DIR/bin/ssh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *v1/status*)
    count=0
    [ ! -f "$DEPLOY_TEST_LOG.polls" ] || count="$(cat "$DEPLOY_TEST_LOG.polls")"
    count=$((count + 1))
    echo "$count" >"$DEPLOY_TEST_LOG.polls"
    case "${DEPLOY_STATUS_KIND:-true}" in
      malformed) body='not json' ;;
      missing) body='{}' ;;
      nonboolean) body='{"recording_readiness":{"ready":"yes"}}' ;;
      false) body='{"recording_readiness":{"ready":false}}' ;;
      true) body='{"recording_readiness":{"ready":true}}' ;;
      transient)
        if [ "$count" -eq 1 ]; then body='not json'; else body='{"recording_readiness":{"ready":true}}'; fi
        ;;
    esac
    printf '%s' "$body" | python3 -c 'import json, sys; value = json.load(sys.stdin).get("recording_readiness", {}).get("ready"); sys.exit(0 if isinstance(value, bool) else 1)'
    ;;
  *) exit 0 ;;
esac
EOF
  chmod +x "$CASE_DIR/bin/"*
}

run_case() {
  local name="$1" kind="$2" timeout="$3"
  CASE_DIR="$TMP/$name"
  mkdir -p "$CASE_DIR"
  make_mocks
  set +e
  OUTPUT="$(env PATH="$CASE_DIR/bin:$PATH" DEPLOY_TEST_LOG="$CASE_DIR/log" \
    DEPLOY_STATUS_KIND="$kind" DANCAM_STATUS_TIMEOUT="$timeout" \
    bash "$DEPLOY_SCRIPT" 2>&1)"
  STATUS=$?
  set -e
}

for kind in false true; do
  run_case "$kind" "$kind" 0
  [ "$STATUS" -eq 0 ] || fail "valid boolean $kind failed: $OUTPUT"
  [ "$(cat "$CASE_DIR/log.polls")" -eq 1 ] || fail "$kind required extra status polls"
done

for kind in malformed missing nonboolean; do
  run_case "$kind" "$kind" 0
  [ "$STATUS" -ne 0 ] || fail "$kind status passed validation"
  case "$OUTPUT" in *"did not return valid /v1/status"*) ;; *) fail "$kind omitted timeout error" ;; esac
done

run_case transient transient 5
[ "$STATUS" -eq 0 ] || fail "transient status failure did not recover: $OUTPUT"
[ "$(cat "$CASE_DIR/log.polls")" -eq 2 ] || fail "transient case did not poll twice"

echo "deploy status parser tests OK"
