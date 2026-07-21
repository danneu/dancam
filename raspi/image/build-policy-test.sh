#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
source "$ROOT/raspi/system/card-layout.env"
source "$ROOT/raspi/image/build-policy.sh"

[ "$(dos_partition_uuid 0x041BBA91 2)" = 041bba91-02 ]
[ "$(dos_partition_uuid d245d549 4)" = d245d549-04 ]

for bad in 0x123 bad-id 0x123456789; do
  if dos_partition_uuid "$bad" 2 >/dev/null 2>&1; then
    echo "invalid DOS label id was accepted: $bad" >&2
    exit 1
  fi
done
if dos_partition_uuid 0x041bba91 0 >/dev/null 2>&1; then
  echo "invalid partition number was accepted" >&2
  exit 1
fi

[ "$DANCAM_BOOT_SIZE_SECTORS" -eq 1048576 ]
[ "$DANCAM_DEVELOPMENT_ROOT_SIZE_SECTORS" -eq 16777216 ]
[ "$DANCAM_DEVELOPMENT_PERSIST_SIZE_SECTORS" -eq 2097152 ]
read -r dev_p2_end dev_p3_start dev_p3_end dev_p4_start dev_raw_end < <(
  calculate_partition_geometry \
    1064960 \
    "$DANCAM_DEVELOPMENT_ROOT_SIZE_SECTORS" \
    "$DANCAM_DEVELOPMENT_PERSIST_SIZE_SECTORS" \
    "$DANCAM_DEVELOPMENT_INITIAL_DATA_SIZE_SECTORS" \
    "$DANCAM_ALIGN_SECTORS"
)
[ "$dev_p2_end" -eq 17842175 ]
[ "$dev_p3_start" -eq 17842176 ]
[ "$dev_p3_end" -eq 19939327 ]
[ "$dev_p4_start" -eq 19939328 ]
[ "$dev_raw_end" -eq 20201472 ]
[ "$((dev_raw_end * 512))" -eq 10343153664 ]
# The pinned 2026-06-18 base starts root at sector 1,064,960.
read -r p2_end p3_start p3_end p4_start raw_end < <(
  calculate_partition_geometry \
    1064960 \
    "$DANCAM_PRODUCTION_ROOT_SIZE_SECTORS" \
    "$DANCAM_PRODUCTION_PERSIST_SIZE_SECTORS" \
    "$DANCAM_PRODUCTION_INITIAL_DATA_SIZE_SECTORS" \
    "$DANCAM_ALIGN_SECTORS"
)
[ "$p2_end" -eq 9453567 ]
[ "$p3_start" -eq 9453568 ]
[ "$p3_end" -eq 10502143 ]
[ "$p4_start" -eq 10502144 ]
[ "$raw_end" -eq 10764288 ]
[ "$((raw_end * 512))" -eq 5511315456 ]
for start in 8192 1064960 "$p3_start" "$p4_start"; do
  [ $((start % DANCAM_ALIGN_SECTORS)) -eq 0 ]
done
if calculate_partition_geometry 1056769 8388608 1048576 262144 8192 >/dev/null; then
  echo "misaligned production root was accepted" >&2
  exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
printf 'nameserver 192.0.2.1\n' > "$TMP/source-resolv.conf"
umask 077
install_temporary_resolver "$TMP/source-resolv.conf" "$TMP/target-resolv.conf"
cmp "$TMP/source-resolv.conf" "$TMP/target-resolv.conf"
[ "$(find "$TMP/target-resolv.conf" -perm 0644 -print)" = "$TMP/target-resolv.conf" ]

touch "$TMP/partition-1" "$TMP/partition-2"
wait_for_paths 1 0 "$TMP/partition-1" "$TMP/partition-2"
if wait_for_paths 1 0 "$TMP/missing-partition"; then
  echo "missing partition path was accepted" >&2
  exit 1
fi

tracked="$TMP/tracked"
mkdir "$tracked"
git -C "$tracked" init -q
printf 'base\n' > "$tracked/source.txt"
printf 'ignored\n' > "$tracked/untracked.txt"
git -C "$tracked" add source.txt
clean_fingerprint=$(tracked_worktree_fingerprint "$tracked")
printf 'unstaged\n' > "$tracked/source.txt"
unstaged_fingerprint=$(tracked_worktree_fingerprint "$tracked")
[ "$clean_fingerprint" != "$unstaged_fingerprint" ]
git -C "$tracked" add source.txt
[ "$(tracked_worktree_fingerprint "$tracked")" = "$unstaged_fingerprint" ]
printf 'different untracked content\n' > "$tracked/untracked.txt"
[ "$(tracked_worktree_fingerprint "$tracked")" = "$unstaged_fingerprint" ]
rm "$tracked/source.txt"
deleted_fingerprint=$(tracked_worktree_fingerprint "$tracked")
[ "$deleted_fingerprint" != "$unstaged_fingerprint" ]

release_out="$TMP/releases"
mkdir "$release_out"
revision=0123456789abcdef0123456789abcdef01234567
timestamp=20260720T231045Z
claim_generated_release_version "$release_out" "$revision" "$timestamp" > "$TMP/version-1" &
claim_1=$!
claim_generated_release_version "$release_out" "$revision" "$timestamp" > "$TMP/version-2" &
claim_2=$!
wait "$claim_1"
wait "$claim_2"
[ "$(sort "$TMP/version-1" "$TMP/version-2")" = "$(printf '%s\n%s' \
  20260720T231045Z-0123456789ab-0000 \
  20260720T231045Z-0123456789ab-0001)" ]

explicit_version=20260720T231045Z-0123456789ab-release
[ "$(claim_release_version "$release_out" "$explicit_version")" = "$explicit_version" ]
if claim_release_version "$release_out" "$explicit_version" >/dev/null 2>&1; then
  echo "claimed explicit image version was reused" >&2
  exit 1
fi
existing_version=20260720T231045Z-0123456789ab-existing
touch "$release_out/dancam-${existing_version}.img.zst"
if claim_release_version "$release_out" "$existing_version" >/dev/null 2>&1; then
  echo "pre-existing release output was accepted" >&2
  exit 1
fi

auto_collision_out="$TMP/auto-collision"
mkdir "$auto_collision_out"
auto_collision_version=20260720T231045Z-0123456789ab-0000
printf 'existing artifact\n' > "$auto_collision_out/dancam-${auto_collision_version}.img.zst"
[ "$(claim_generated_release_version "$auto_collision_out" "$revision" "$timestamp")" = \
  20260720T231045Z-0123456789ab-0001 ]
[ "$(cat "$auto_collision_out/dancam-${auto_collision_version}.img.zst")" = 'existing artifact' ]

if claim_release_version "$release_out" ../outside >/dev/null 2>&1; then
  echo "unsafe explicit image version was accepted" >&2
  exit 1
fi

echo "image build policy tests passed"
