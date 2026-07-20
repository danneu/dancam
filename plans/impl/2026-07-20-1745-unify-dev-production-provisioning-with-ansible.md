# Unify development and production provisioning under Ansible

## Problem and desired outcome

Development system state is converged with Ansible, while the production image
builder independently installs and configures many of the same packages, accounts,
services, mounts, and files. The production hostname and `/data/rec` ownership
failures demonstrate that manually synchronizing these paths is not reliable.

Development and production should have one provisioning authority with two
execution profiles:

- development converges a writable Pi over SSH;
- production converges a mounted Raspberry Pi OS root through Ansible's chroot
  connection during `just raspi-image`.

The image builder remains responsible for disk assembly and release publication.
First-boot commissioning remains responsible only for facts that cannot exist in a
generic image.

## Decision

### One Ansible system declaration

Refactor the flat playbook into three roles:

- `system_common` owns the hostname, package catalog, `dancam` user, Avahi, locale,
  camera overlay, journald, watchdog, writeback policy, service unit, filesystem
  ownership, and common boot-enabled services.
- `dev_runtime` owns the development layout preflight and live mounts, full package
  upgrade, non-autoconnect `dancam-dev` AP, live service transitions, hardware
  checks, handlers, and reboot behavior.
- `production_image` owns exact package pins, read-only root and boot posture,
  persistent binds, conditional `/data` mount, commissioning artifacts, production
  service configuration, maintenance and cloud-init masks, and offline unit
  enablement.

Use separate development and production entry playbooks instead of spreading a
`car_image` condition through one play. Both entrypoints include `system_common`;
profile-specific facts exist only in their owning role.

Keep one package catalog containing each package's profile scope and production
pin. Development installs the declared packages after its full upgrade. Production
installs exact pinned versions without a floating upgrade. Package pins cease to be
shell-owned image inputs.

### Offline image convergence

`just raspi-image` authenticates and unpacks the base OS, creates the partition
layout, and mounts boot, root, `/persist`, and the initialized `/data` filesystem
before invoking the production play through `community.general.chroot`. The builder
passes generated release facts and the built service binary to Ansible.

The production play may install packages and modify the staged filesystems, but it
must not start or restart services, reboot, activate target mounts, manipulate live
swap, inspect builder-host hardware, or otherwise mutate the VM outside the staged
image. Live handlers and runtime checks remain development-only.

Ansible installs the production binary, camera process, tracked service unit,
commissioning scripts and units, and target paths. The builder retains base-image
authentication, partition geometry, loop and filesystem mounting, generated image
metadata, package inventory, compression, manifest creation, and signing. It no
longer contains a competing sequence of package, account, systemd, configuration,
or ownership commands.

### Commissioning and deployment boundaries

The generic p4 contains empty `/data/rec` and `/data/rec/state` directories owned by
`dancam` with mode `0755`, but no storage generation or admission marker.

First-boot commissioning is limited to:

- authenticating the image marker and personalization envelope;
- installing the per-card AP identity and secret;
- creating the per-card machine identity;
- expanding p4 and its existing filesystem;
- minting the recording storage generation; and
- durably completing commissioning and admitting `/data`.

Commissioning validates the baked recording namespace and fails closed if it is
absent or unusable; it does not repair general ownership or system configuration.
The temporary namespace-provisioning helper is removed after Ansible owns that
state.

Ansible installs and enables `dancam.service` in both profiles. `raspi-deploy`
continues cross-building and shipping the binary and camera process, restarts the
already-provisioned unit, and waits for recording readiness. Unit changes require a
provisioning run.

The live `raspi-provision-car` conversion path is removed. Development cards remain
writable; production cards are created only from signed images.

### Release gates

The image build runs the production play twice and fails unless the second pass
reports `changed=0`. It then independently inspects the completed staged image
before generating or signing release artifacts.

Inspection proves the effective hostname, Avahi configuration and enablement,
package pins, service identity and units, camera and regulatory configuration,
journald, watchdog, writeback policy, mount posture, maintenance masks, and recording
namespace ownership. It also proves the generic image contains no production AP
secret, home-Wi-Fi profile, signing key, pre-minted storage generation, or
`/persist/dancam/storage-admitted` marker.

## Invariants

- Every system fact shared by development and production has one Ansible
  declaration.
- Builder shell, deploy, and commissioning contain no competing hostname, account,
  package, Avahi, unit, mount-policy, or directory-ownership configuration.
- Production image convergence cannot perform live runtime actions against the
  builder VM.
- Production remains complete without SSH, home Wi-Fi, upstream internet, Ansible,
  or apt after flashing.
- Production packages remain exactly pinned and recorded in the release inventory.
- `/data` remains unavailable to normal storage work until commissioning durably
  completes.
- Development remains writable, uses its non-autoconnect development AP, and
  converges to `changed=0`.
- Image signing occurs only after Ansible idempotency and independent image
  inspection pass.

## Proof obligations

- Syntax-check and lint both entry playbooks and all roles.
- Prove production-play dispatch, rejection of a non-idempotent second pass,
  offline-action safety, narrowed deploy installation, commissioning refusal of
  an invalid baked namespace, and release-verifier failures including a planted
  storage-admission marker without Pi hardware.
- From a linked worktree at the clean candidate commit, complete a real
  `just raspi-image` build and satisfy both the second-pass `changed=0` gate and
  every independent image inspection.
- From that clean candidate worktree, on a writable development Pi, converge
  twice, deploy through the narrowed path, and verify mDNS, camera readiness,
  preview, and recording. Reboot, then prove the Pi returns over home Wi-Fi, root
  and boot remain writable, and the enabled service becomes recording-ready
  without another deploy.
- Flash the resulting image and boot a real Zero 2 W without upstream networking.
  Verify QR join, `dancam.local`, preview, recording, read-only root and boot,
  writable `/persist` and `/data`, reboot persistence, and unique commissioning and
  storage identity.
- Run the existing image-builder, commissioning, deploy, Pi service, and docs gates.

## Non-goals and accepted differences

- Development and production need not have identical runtime posture or
  operator-only tools. They share common facts through one catalog and express
  genuine differences through profile roles.
- The image builder, flasher, signing model, partition geometry, manifest schema,
  and onboarding contract are unchanged.
- Live conversion of a development card into production posture is no longer a
  supported workflow.
- OTA updates, production SSH maintenance, other distributions, and other Pi models
  remain out of scope.

## Documentation

Update the provisioning, OS-image, service-runtime, networking, setup-runbook,
roadmap, and Pi agent guidance to describe one Ansible authority with two profiles.
Append a decision-log entry explaining that the hostname and recording-namespace
failures invalidated the separate shell-provisioning boundary; preserve older log
entries as history.

Existing unrelated working-tree changes remain untouched. The current shell
hostname and recording-ownership fixes are migrated into Ansible before their
temporary helpers are removed.

## Commit progress

- [x] 1. Establish role-based development provisioning and Ansible-owned service units
- [x] 2. Converge production images with Ansible and enforce offline release gates
- [ ] 3. Narrow commissioning ownership and finish system documentation

## Implementation notes

- The first slice removes the live car-conversion recipe while extracting the
  writable roles. Keeping the recipe after removing its `car_image` tasks would
  silently leave a writable card instead of hardening it; signed images remain the
  production authority until the production Ansible role lands in slice 2.
- The shared package catalog is JSON, which is also valid as an Ansible vars file.
  This lets the independent shell verifier read the exact production pins with
  `jq` instead of duplicating them or adding a second YAML parser to the builder.
