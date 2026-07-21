#!/usr/bin/env bash
# Hardware-free checks for the destructive authority and 95% aligned layout math.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
source "$ROOT/raspi/system/card-layout.env"
source "$ROOT/raspi/image/commission-policy.sh"
ALIGN=$DANCAM_ALIGN_SECTORS

for bytes in 32000000000 64000000000 128000000000 256000000000; do
  total=$((bytes / 512))
  start=10502144
  read -r size end < <(commission_layout "$total" "$start" "$ALIGN")
  tail=$((total - end))
  [ "$((start % ALIGN))" -eq 0 ]
  [ "$((end % ALIGN))" -eq 0 ]
  [ "$end" -le "$((total * DANCAM_DATA_PERCENT / 100))" ]
  [ "$tail" -ge "$((total * (100 - DANCAM_DATA_PERCENT) / 100))" ]
done

if commission_layout "$((DANCAM_MIN_TOTAL_SECTORS - 1))" 10502144 "$ALIGN" >/dev/null; then
  echo "sub-32 GB card was accepted" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
state="$TMP/state.json"
printf '%s\n' '{"state":"complete","reason":null}' > "$state"
if commission_needs_run "$state"; then
  echo "completed commissioning replay was not fenced" >&2
  exit 1
fi

marker="$TMP/marker.json"
envelope="$TMP/envelope.json"
printf '%s\n' '{"image_id":"image-a"}' > "$marker"
printf '%s\n' '{"schema":"dancam-commissioning-v1","image_id":"image-a","unit_id":"0123456789","ssid":"dancam-0123456789","psk":"0123456789012345678901","nonce":"0123456789012345678901"}' > "$envelope"
validate_commissioning_envelope "$marker" "$envelope"
sed -i.bak 's/image-a/image-b/' "$envelope"
if validate_commissioning_envelope "$marker" "$envelope"; then
  echo "mismatched envelope was accepted" >&2
  exit 1
fi

namespace="$TMP/data"
mkdir -p "$namespace/rec/state"
chmod 755 "$namespace/rec" "$namespace/rec/state"
validate_recording_namespace "$namespace" "$(id -u)" "$(id -g)"

if validate_recording_namespace "$namespace" "$(( $(id -u) + 1 ))" "$(id -g)"; then
  echo "incorrect recording namespace owner was accepted" >&2
  exit 1
fi

chmod 555 "$namespace/rec"
if validate_recording_namespace "$namespace" "$(id -u)" "$(id -g)"; then
  echo "non-writable recording namespace was accepted" >&2
  exit 1
fi
chmod 755 "$namespace/rec"

rmdir "$namespace/rec/state"
if validate_recording_namespace "$namespace" "$(id -u)" "$(id -g)"; then
  echo "incomplete recording namespace was accepted" >&2
  exit 1
fi
echo "commissioning geometry and replay tests passed"
