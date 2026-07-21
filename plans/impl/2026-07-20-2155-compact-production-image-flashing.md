# Compact production image flashing

## Problem and desired outcome

The signed production artifact compresses to about 928 MiB, but its authenticated raw
image is padded to 10 GiB. Flashing therefore writes 10 GiB and reads the same 10 GiB
back even though the finalized root contains only 2.57 GB of files. The fixed image
geometry, not the payload, dominates card-production time.

Production flashing should process about half as many bytes without weakening exact
whole-image authentication, readback verification, bounded resume, or first-boot
commissioning. Writable development cards should retain their current upgrade and
debugging headroom.

## Decision

### Profile-specific geometry

Keep the same MBR, four-partition model, labels, 4 MiB alignment, 32 GB card minimum,
and 5% unpartitioned tail, but stop requiring development and production to use the
same fixed sizes.

- Development remains 512 MiB boot, 8 GiB root, 1 GiB persist, and capacity-sized
  data.
- Production becomes 512 MiB boot, 4 GiB root, 512 MiB persist, and 128 MiB initial
  data.
- The production raw artifact ends at p4 instead of carrying padding to 10 GiB. With
  the current pinned base image, its authenticated raw size is 5,511,315,456 bytes
  (5,256 MiB).
- Commissioning continues growing only p4 to the aligned 95% card boundary.

The production root remains read-only in normal operation. It retains Raspberry Pi
OS, exact runtime packages, the dpkg database, service artifacts, and system
configuration. Recordings stay on `/data`; NetworkManager state, machine identity,
commissioning state, and persistent journals stay on `/persist`; `/tmp` and
`/var/log` remain tmpfs-backed.

### Release cleanup and gates

Remove downloaded package archives and apt repository lists from the production
release after package and system convergence. The cleanup is Ansible-owned target
state, not shell-owned image mutation. Keep the installed-package database so
independent inspection and the signed package inventory remain authoritative.

The build order is load-bearing:

1. converge package and system state twice, requiring `changed=0` on pass two;
2. converge release cleanup twice, requiring `changed=0` on pass two;
3. independently inspect the finalized image; and
4. only then inventory, compress, manifest, and sign it.

The finalized root must expose at least 1 GiB available to non-root callers. A future
package increase that consumes that margin fails the release build instead of
silently producing an undersized root.

### Release and flash compatibility

Keep manifest schema v1, the authenticated raw SHA-256, full raw write/readback, and
the 64 MiB bounded repair model. The writer continues obeying each manifest's
`raw_size`, so existing 10 GiB releases remain flashable and resumable.

Make generated image versions lexically monotonic at second resolution while keeping
the repository revision in the version. Include a fixed-width collision discriminator
and atomically claim each generated release basename, so concurrent same-second builds
from the same commit receive distinct, ordered versions. A new compact release must
sort after legacy same-day artifacts, must not overwrite any existing release output,
and must remain the default selected by `just raspi-flash`. The explicit image-version
override remains supported but fails rather than replacing a pre-existing output path.

### Canonical documentation

Update the OS-image design with the profile-specific partition geometry and compact
production artifact boundary. Update the provisioning design with the separate
release-cleanup convergence phase, its idempotency gate, and the release-space
inspection gate. Append dated Decision log entries to both design pages. Update the
Pi runbook's release-build description and production-card expectations to match the
new build and flash behavior.

## Invariants

- Development partition geometry and existing development cards are unchanged.
- Production root has at least 1 GiB available after all packages and cleanup.
- Production contains no downloaded package archives or apt repository lists.
- Exact package pins, dpkg state, and the signed package inventory remain intact.
- Image signing occurs only after both idempotency gates and independent inspection.
- Release generation never replaces or interleaves files belonging to another build.
- Flashing writes and verifies every authenticated raw byte; omitted extents and stale
  target blocks are not introduced.
- Commissioning still admits `/data` only after authenticated personalization,
  namespace validation, p4 growth, and durable storage identity creation.

## Proof obligations

- Prove development geometry is unchanged and production geometry is aligned, ends
  exactly at p4, and yields the expected current-base raw size.
- Prove both convergence phases reject a non-idempotent second pass and signing remains
  ordered after final inspection.
- Prove inspection rejects apt cache/list contents and a production root below the
  1 GiB available-space floor.
- Prove legacy and compact manifests both drive the writer by authenticated
  `raw_size`, and the new version format selects the newest same-day release.
- Prove two auto-versioned same-commit builds started in the same second cannot claim
  the same release basename, and that auto-generated and explicit versions cannot
  replace pre-existing release output paths.
- Prove the OS-image and provisioning design pages, their dated Decision log entries,
  and the Pi runbook describe the new geometry, release gates, and operator behavior;
  pass the documentation build and link checks.
- Run the existing image-builder, provisioning-lint, commissioning, development
  partition, flash-policy, and documentation gates.
- From a clean candidate commit, complete `just raspi-image`; verify both `changed=0`
  gates, independent inspection, a 5,511,315,456-byte raw manifest for the current
  base, artifact and inventory digests, and the manifest signature.
- Flash the compact image to a real card and prove the writer and verifier each process
  5,256 MiB. Boot a Zero 2 W and verify p4 growth, read-only root/boot, writable
  persist/data, commissioning completion, preview, and recording.

## Rejected direction

Extent-only or sparse flashing is rejected for this change. Skipping zero ranges could
reduce I/O further, but it would leave prior card bytes outside the authenticated
result and require a new manifest, verification, privacy, and resume model. Compact
geometry obtains the immediate speedup while preserving exact whole-image semantics.

## Implementation discretion

- Internal layout-calculation and Ansible task decomposition are implementation
  choices as long as the geometry, ownership, ordering, and proof obligations above
  hold.

## Commit progress

- [x] 1. Compact production image geometry
- [x] 2. Converge release cleanup and enforce finalized-image gates
- [ ] 3. Make release naming collision-safe and complete release proof
