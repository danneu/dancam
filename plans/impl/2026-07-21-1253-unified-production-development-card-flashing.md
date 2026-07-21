# Unified production and development card flashing

## Problem and desired outcome

Production cards have a safe one-command Mac workflow, while development cards
still depend on Raspberry Pi Imager followed by live partitioning and provisioning.
Card creation should instead have one explicit entry point for both profiles, and a
new development card should boot onto home Wi-Fi ready for the normal deploy loop.

## Decision

- `just raspi-flash production [manifest]` flashes the supplied or newest signed
  production release. Production authentication, personalization, verification,
  and ejection remain unchanged.
- `just raspi-flash dev` validates local development credentials, builds a fresh
  writable image from the current tracked working-tree content in OrbStack, then
  safely writes, personalizes, verifies, and ejects the card.
- The profile argument is required. Bare or unknown invocations fail before image
  construction or media discovery.
- Resume remains production-only as
  `just raspi-flash-resume production [manifest]`. A failed development flash starts
  again with a fresh build and complete write.
- The Raspberry Pi Imager, live partitioning, and manual development AP setup path
  is retired. Live Ansible provisioning remains available for drift repair.

Development personalization uses the existing `DANCAM_HOST` login user and
`DANCAM_SSH_KEY`, plus these gitignored `.env` values:

- `DANCAM_HOME_WIFI_SSID`
- `DANCAM_HOME_WIFI_PSK`
- `DANCAM_DEV_AP_PSK`

The generated login is SSH-key-only with passwordless sudo. NetworkManager profile
names are fixed as `dancam-home` and `dancam-ap`.

## Invariants

- Production retains its existing source gate: staged or unstaged tracked changes
  are rejected, while unrelated untracked files are not. Development includes the
  staged and unstaged content of tracked source and uses current development
  packages.
- Both profiles share the controlled ARM64 image builder, common Ansible-owned system
  state, removable-media admission, exact erase confirmation, complete write
  verification, personalization readback, and ejection behavior.
- The generic development artifact contains no login or Wi-Fi secrets. The Mac adds
  an image-bound development envelope only after the generic image has been verified
  and written.
- Development retains its 512 MiB boot, 8 GiB writable root, 1 GiB persist, and 5%
  unwritten tail. Its initially small data partition grows to the shared 95% boundary
  during first boot.
- Development first boot validates personalization, creates the developer login and
  both Wi-Fi profiles, generates unique machine and storage identities, admits the
  expanded data filesystem, and records durable completion or failure. `dancam`
  starts normally throughout commissioning so status, events, preview, camera
  supervision, and telemetry remain available; the existing commissioning-readiness
  gate blocks only recording and storage mutations until durable storage admission.
- A successfully commissioned card is reachable through `DANCAM_HOST` on home Wi-Fi.
  `just raspi-deploy` retains its existing build, copy, install, restart, status, and
  recording-readiness behavior without another provisioning step.
- Re-running live development Ansible is idempotent and does not require an
  interactive sudo password on generated cards. `just raspi-ap` switches to the
  configured `dancam-dev` AP and automatically returns to `dancam-home`.
- Development credentials are rejected before media discovery when missing or
  invalid, are not emitted to logs or retained in build artifacts, and cannot alter
  generated NetworkManager or shell syntax through unescaped input.

## Proof obligations

- Hardware-free flash tests prove profile dispatch, credential preflight,
  profile/manifest separation, removable-media safety, full-write verification,
  production signatures, and production-only resume behavior. A tracked-source
  sentinel proves staged and unstaged content reaches the development artifact while
  production rejects the same changes without rejecting unrelated untracked files.
- A black-box credential test uses sentinel and metacharacter-bearing values to prove
  semantic round-trip into the generated account, authorized key, and both network
  profiles, while asserting that secrets do not appear in logs or generic build
  artifacts.
- Mocked end-to-end flashing for both profiles proves personalization is reread after
  remount and successful ejection occurs only after image and personalization
  verification complete.
- Image tests prove development geometry and writable posture, required packages and
  service artifacts, absent credentials and generic identities, and zero changes on
  the second offline Ansible convergence pass. Existing production image claims
  remain covered.
- Commissioning tests prove validated user/key/sudo creation, both Wi-Fi profiles,
  unique identities, idempotent data growth and storage admission, durable failure,
  and refusal of invalid or mismatched envelopes.
- A real-card acceptance pass proves first-boot home-Wi-Fi access, key-only SSH,
  passwordless sudo, expected mounts and geometry, recording readiness,
  `just raspi-deploy`, zero-drift `just raspi-provision-check`, AP switch/revert, and
  return to home Wi-Fi after a power cycle.
- The setup runbook and the owning OS-image, provisioning, and networking design
  pages describe the new present-tense workflow and record the decision in their
  append-only logs.

## Non-goals and accepted risk

- Existing provisioned development cards need no migration and continue to support
  deploy and live provisioning; only creation of new cards changes.
- Production AP identity, setup QR, recovery records, and offline commissioning
  semantics do not change.
- Development Wi-Fi secrets briefly exist on the card's FAT boot partition during
  commissioning. Removing the consumed envelope is logical deletion, not secure
  erasure, so physical possession of a development card remains trusted.

## Implementation discretion

- Internal script, role, manifest, and commissioning decomposition is left to the
  implementation as long as profile separation and the invariants above remain
  independently verifiable.

## Commit progress

- [x] 1. Build and verify generic writable development images
- [x] 2. Personalize and commission development cards on first boot
- [x] 3. Unify profile-explicit flashing and retire manual card creation

## Implementation notes

- Development commissioning generates fresh SSH host keys after the generic image
  verifier requires them to be absent, so cached development artifacts cannot give
  multiple cards the same SSH server identity.

## Follow Up

- Run the real-card acceptance pass in `docs/setup/pi-runbook.md` with a newly
  flashed development card: confirm first-boot home Wi-Fi, key-only SSH, passwordless
  sudo, mounts and geometry, recording readiness, deploy, zero-drift provisioning,
  AP switch and revert, and return to home Wi-Fi after a power cycle.
