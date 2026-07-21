# Pi provisioning

The camera unit stays on Raspberry Pi OS and is converged with Ansible. Generic
development and production images run Ansible against mounted filesystems through
the chroot connection; writable development cards can re-run Ansible over SSH for
drift repair. Provisioning makes
onboard system state declarative, repeatable, and reviewable without pulling the
fast binary-deploy loop into configuration management.

This page owns the provisioning tool, its execution and idempotency model, the
boundary between system state and deployed artifacts, and the split between
per-machine connection identity and the fixed service identity. The
[OS image design](os-image.md) owns the desired partition, mount, and write
policy; [networking](networking.md) owns the AP and mDNS behavior; and
[recording](recording.md) owns the camera process and media format.

## Ownership boundary

The repository has seven distinct configuration owners:

- `raspi/ansible/development.yml` converges writable cards over SSH. The
  `system_common` role owns shared machine identity, configuration, service unit,
  camera process, and filesystem namespace; `dev_runtime` owns live development
  packages, mounts, checks, handlers, and reboot behavior.
- `raspi/ansible/development-image.yml` converges a generic writable image through
  the chroot connection. It reuses `system_common`; `development_image` owns current
  development packages, the built service binary, writable mounts, generic identity,
  and offline unit enablement. It creates no login or Wi-Fi profile.
- `raspi/ansible/production.yml` converges a mounted image root through Ansible's
  chroot connection. It reuses `system_common`; `production_image` owns exact package
  pins, persistent binds, read-only mount posture, commissioning artifacts, and
  offline unit enablement and masks. `raspi/ansible/release-cleanup.yml` runs only
  after that system state converges; `release_cleanup` removes downloaded package
  archives and apt repository lists without removing the dpkg database.
- `raspi/image/build.sh` owns profile-specific disk assembly from the authenticated
  base, temporary target mounts, generated image facts, independent inspection,
  inventory, compression, manifest creation, and production signing. It does not
  declare target packages, accounts, services, configuration, or ownership.
- `raspi/deploy.sh` owns the cross-built service binary, camera-process refresh,
  and fast restart loop. The tracked systemd unit is Ansible-owned, so unit changes
  require provisioning before deploy.
- `raspi/scripts/partition-card.sh` owns SD-card geometry and filesystem
  creation. The playbook owns the resulting mounts and directory ownership.
- The [Pi setup runbook](../../setup/pi-runbook.md) owns human and runtime
  operations that cannot be expressed as converged system state: flashing,
  first boot, smoke tests, the manual development AP secret, safe AP toggling,
  release publication, and production-card flashing.

A command belongs in the artifact that executes it. The hard-won reason for an
Ansible action belongs in the adjacent task comment, while a concise task or
handler name supplies the operator-facing label. Behavior changes update the
owning artifact, its comment, this page when the provisioning model changes,
and the runbook when operator steps change.

## Convergence model

Provisioning runs from the repository root through Nix-managed Ansible and
ansible-lint:

```sh
just raspi-provision
just raspi-provision-check
just raspi-provision-lint
```

`raspi-provision` converges the writable development image.
`raspi-provision-check` uses `--check --diff` as a non-mutating drift detector,
and `raspi-provision-lint` runs the hardware-free syntax and lint gate on the
Mac for both entry playbooks. A converged development Pi must re-run with
`changed=0`; idempotency is an observed acceptance condition, not an assumption.

Provisioning always runs while the Pi is a client on home Wi-Fi. The apt step
needs upstream internet, and the single-radio design does not run AP and
station modes concurrently. There is no provisioning path through
`10.42.0.1`. The recipe can override the inventory address with a raw LAN IP
when mDNS is unreliable.

The playbook fails before mutating package or configuration state when the card
does not expose the required `dancam-data` partition label. Old expanded-root
cards cannot be shrunk into the current layout and must be reflashed and
partitioned first.

An apt full-upgrade notifies the reboot handler whenever any package changes,
not only for a kernel or firmware upgrade. The unconditional-on-change rule is
simpler and safer than trying to interpret `/run/reboot-required`; a converged
run neither changes packages nor reboots.

There is no live conversion from a writable card to production posture.
Production cards come only from the authenticated image build and flash path.
For either image profile, the builder mounts boot, root, `/persist`, and `/data`, then
runs the matching offline play twice and requires `changed=0` on the second pass.
Development follows current packages and includes staged and unstaged tracked source;
untracked files do not enter its source fingerprint. Production rejects any tracked
tree change before build, then
runs the release-cleanup play twice and requires `changed=0` on that second pass too.
The production roles use no service start/restart, reboot, live target mount, swap,
or hardware-inspection action. After both idempotency gates, a separate shell verifier
requires empty apt archive and repository-list areas and at least 1 GiB available on
root to non-root callers. Package inventory, compression, manifest creation, and
signing cannot begin until that independent inspection passes.

## Managed system state

The shared `system_common` role declares:

- the IMX708 device-tree configuration, Avahi scoping, and the `en_US.UTF-8` locale;
- the fixed `dancam` system user and its `video` supplementary group;
- playbook-owned `/data/rec` and `/data/rec/state` directory ownership;
- persistent bounded journald, the hardware watchdog, recording-oriented dirty
  writeback limits, weekly filesystem trimming, and the tracked service artifacts.

One package catalog records profile membership and every exact production pin.
The offline development image performs a full upgrade, installs its current
Picamera2/PyAV/ffmpeg/v4l2 packages and the worktree-built service, and leaves both
network profiles for per-card commissioning. Live development convergence retains
the card-layout preflight, mounts, interpreter validation, and drift repair. Production
installs its exact package set without a floating upgrade, then declares the
persistent binds, conditional `/data` mount, read-only root/boot posture, generic
image marker, commissioning state, service environment, and maintenance masks.
Release cleanup is a distinct Ansible-owned target-state phase after package and
system convergence. It removes only downloaded apt payload and repository indexes;
installed package records under `/var/lib/dpkg` remain available for inspection and
the signed inventory.

## Connection and service identities

A person flashing a Pi chooses the SSH login user. The camera daemon does not
inherit that identity. Ansible creates a project-owned, non-login `dancam`
system user and grants it `video` access for the camera and DMA devices. The
static unit declares `User=dancam`, and the playbook creates the recording namespace
owned by that user. Provisioning therefore precedes the first deploy on a fresh card.

Only per-machine connection settings are configurable. Copy `.env.example` to
the gitignored `.env` and set:

- `DANCAM_HOST`, including the Raspberry Pi Imager login user and SSH target;
- `DANCAM_SSH_KEY`, the private key used for SSH and Ansible; and
- `DANCAM_HOME_WIFI`, the NetworkManager home-profile name used by the safe AP
  return path.

The root Justfile loads `.env` for all recipes. The provisioning recipes split
the user from `DANCAM_HOST` and pass the user and key to Ansible as extra vars,
alongside the existing host-address override. The tracked
`raspi/ansible/inventory.ini` contains only the shared host constant
`dancam ansible_host=dancam.local`.

Other project constants remain tracked: hostname `dancam`, development AP SSID
`dancam-dev`, AP profile `dancam-ap`, and gateway `10.42.0.1`. A fork configures
how its workstation reaches the Pi; it does not choose a service identity or
duplicate connection settings in another inventory.

There is no migration path for cards that used a login-user recording directory
or the earlier `/var/lib/dancam/rec` layout. The project has no shipped units, so
development cards are reflashed onto the current partition and ownership model.

## AP secret and idempotency

The development AP PSK never enters the repository, `.env`, or Ansible. `dev_runtime`
manages every non-secret field of `dancam-ap`; the operator enters the PSK once on the Pi.
Leaving the secret field unmanaged both protects it and avoids NetworkManager
module churn around `psk` and `psk-flags`. Production AP identity is instead
installed from the authenticated per-card personalization envelope.

The WPA2-AES values `proto`, `pairwise`, and `group` are expressed as
single-element YAML lists (`[rsn]`, `[ccmp]`, `[ccmp]`). The
`community.general.nmcli` module parses live values as lists and performs its
order-insensitive comparison only when desired values are also lists. Scalars
would compare unequal on every run and violate the `changed=0` gate.

If the NetworkManager module eventually churns despite the absent PSK and list
shape, the recorded fallback is a templated `.nmconnection` keyfile. It is not
used while the simpler module remains idempotent.

## Development and production split

Ansible is the convergence authority for both profiles. Development runs it live over
SSH and keeps the home-Wi-Fi provision, partition, deploy, AP-toggle, and `changed=0`
loop. Production runs it offline inside the image builder, with target service
actions forbidden and exact packages installed before the remaining system state.
The deployed production Pi contains neither Ansible nor an apt dependency: it boots
complete without SSH, a home network, a package repository, or a workstation.

The release publisher supplies the minisign secret key only to the controlled image
build. The key is never stored in the image or repository. Flash consumers trust the
tracked release public key and never need publisher authority.

## Decision log

### 2026-06-26 -- Converge the Pi system layer with Ansible

(absorbed from raspi ADR 09, 2026-06-26)

Initial camera bring-up was a sequence of SSH commands: full-upgrade apt,
install camera dependencies, edit `config.txt` and Avahi configuration, create
the AP profile, and generate the locale. Those commands lived in prose, so the
actual Pi could drift from the repository with no reviewable declaration or
dry-run comparison.

Ansible was chosen to preserve Raspberry Pi OS while making that system layer
one-command, re-runnable, idempotent, and diffable. Raspberry Pi OS remained
important because its in-kernel IMX708 overlay, libcamera, and Picamera2 stack
solved the riskiest hardware integration. Switching to NixOS for configuration
purity would have moved the system's weakest link onto its roughest-supported
platform.

The first ownership split made the playbook responsible for packages, the
camera overlay, Avahi, locale, AP profile without its PSK, and camera-device
group membership. Deploy retained the binary and unit so an inner-loop change
did not require a provisioning run, and the runbook retained GUI, runtime, and
secret-bearing operations. The initial scope deliberately stopped at the
writable development image; later OS image work added the explicit car-image
layer. The initial version still tied camera access and recording-directory
details to the login user; the 2026-06-30 decision below removed that coupling
without changing the three-way ownership model. Later OS image work also moved
recording to the dedicated data partition.

The playbook's acceptance proof was a second converged run reporting
`changed=0`. This caught a concrete NetworkManager trap: desired cipher scalars
were compared with live lists and caused perpetual change. Using single-element
lists made the profile genuinely idempotent. The AP PSK stayed manual because
putting it in the playbook or a prompt was unnecessary for one development unit,
would risk repository or shell-history exposure, and encountered secret-field
round-trip gaps.

Rebooting after any apt upgrade was accepted over probing only for kernel or
firmware changes. The extra reboot is safe and easier to reason about. The AP
was explicitly excluded as a provisioning transport because it has no upstream
internet and the radio does not provide an independent simultaneous client
channel.

A hand-rolled idempotent shell script was rejected because it would rebuild a
small subset of Ansible without modules, handlers, or `--check --diff`.
Cloud-init or image baking was deferred to immutable-image work because it was
too heavy for one rapidly changing desk unit. A templated NetworkManager
keyfile was retained only as a fallback for module idempotency. Folding deploy
into Ansible was rejected because system configuration and service artifacts
change at different cadences.

### 2026-06-30 -- Separate workstation connection identity from service identity

(absorbed from raspi ADR 11 and its amendment to raspi ADR 09, 2026-06-30)

Preparing the repository for public forks exposed two identities that the
initial setup had conflated. The SSH/Ansible user belongs to the person and card
created through Raspberry Pi Imager; the camera-service user owns a project
daemon and its recording state. A forker should configure only the former.

The service moved to a fixed `dancam` system user, while `DANCAM_HOST`,
`DANCAM_SSH_KEY`, and `DANCAM_HOME_WIFI` moved into one gitignored `.env` seeded
from `.env.example`. Loading that file in the root Justfile gave deploy,
provisioning, and helper recipes one connection source. The tracked inventory
kept only `dancam.local`, while the recipes passed user and key as Ansible extra
vars. Shared product constants stayed in tracked configuration.

The original form of this decision used `StateDirectory=dancam` and
`/var/lib/dancam/rec`, with the camera process creating the `rec` subdirectory.
The later four-partition OS design moved footage to `/data/rec`, removed the
unit's `StateDirectory`, and made Ansible create the directory after mounting
`/data`. The load-bearing result of this decision remains: `User=dancam` is
static, the playbook owns that account and its device access, and neither deploy
nor a fork renders a personal service identity.

Existing cards were deliberately reflashed rather than migrated. There were no
shipped users, and retaining a compatibility path for login-user recordings
would have preserved the coupling the change removed.

The same publication preparation kept promoted implementation plans tracked so
the plan pipeline continued to work, while personal identifiers in historical
records were de-identified in place rather than replaced with a fork-specific
configuration mechanism.

Rendering the unit with the login user was rejected because it coupled daemon
ownership to SSH and made a static artifact machine-specific. systemd `%h` was
rejected because it does not reliably mean the configured service user's home
for a system service and because a login home was the wrong model. A dynamic
user was rejected in favor of stable, inspectable ownership during hardware
smoke tests. A second gitignored inventory was rejected because it would
duplicate connection identity, and tracked per-user config was rejected because
it would leak identifiers and force every fork to edit shared files. Omitting an
example environment file was rejected because it would hide required setup.

### 2026-07-02 -- Keep the operator runbook at the Pi entry point

(amendment absorbed from raspi ADR 09, 2026-07-02)

The bootstrap, verification, and operations guide moved to `raspi/README.md` so
the Pi directory had an obvious hands-on entry point. The relocation did not
change the ownership split: Ansible still owns converged system state, deploy
owns service artifacts, and the runbook owns human-only and runtime-only steps.
The runbook will move into the book in a later migration commit; until then this
page links to its current location.

### 2026-07-15 -- Move the operator runbook into the book

The bootstrap, verification, and operations guide moved to the book's
[Pi setup runbook](../../setup/pi-runbook.md) chapter so operators and readers
have one browsable documentation site. `raspi/README.md` remains a short pointer
from the Pi entry point rather than a second copy that could drift.

### 2026-07-16 -- Converge distro PyAV as a camera runtime

Direct per-segment PyAV replaced the FFmpeg recording subprocess, so an ambient or
pip-installed binding would make camera readiness depend on image history. The
playbook now installs distro `python3-av` beside Picamera2 and runs both imports
through the deployed `python3` interpreter on every converge. Keeping ffmpeg as an
operator media validator does not put it back on the recording path.

### 2026-07-17 -- Separate release image assembly from development convergence

The production topology has no upstream network, so deployed Ansible and apt cannot
be part of commissioning. Image assembly now resolves and pins those inputs in a
controlled Linux environment, while the Mac flash path consumes an authenticated
artifact. Development cards retain Ansible because its writable convergence and
`changed=0` proof remain the faster inner loop.

### 2026-07-20 -- Make Ansible the single system declaration

The separately maintained production builder reproduced development provisioning in
shell. Production images consequently shipped with a stale hostname and later with
an incorrectly owned recording namespace even though the development playbook held
the intended state. Those failures disproved the assumption that a small duplicated
shell path could stay synchronized with Ansible through review alone.

Ansible therefore becomes the authority for shared development and production
system facts. The flat playbook is split into shared, writable-development, and
offline-production roles; the image builder retains disk and release mechanics but
invokes the production role for target state. Live handlers and hardware checks stay
out of the offline profile. The tracked service unit also moves under provisioning,
while deploy keeps the fast binary/camera refresh and restart loop.

Keeping the shell builder as a second declaration was rejected because that is the
failed boundary this decision removes. Spreading a `car_image` conditional through
the writable play was rejected because it makes offline safety an emergent property
of individual task guards. Live conversion was removed entirely: development cards
stay writable, and production cards come only from authenticated signed images.

### 2026-07-20 -- Gate releases on converged cleanup and root headroom

The compact production root needs an explicit capacity margin rather than an
assumption based on one successful build. Image assembly now separates package and
system convergence from release cleanup, runs each phase twice, and rejects a
non-idempotent second pass. Cleanup remains Ansible-owned desired state, so downloaded
package archives and repository lists cannot drift back into releases through an
unreviewed shell mutation.

An independent inspection after both phases rejects any remaining apt payload and
requires at least 1 GiB available to non-root callers. The dpkg database is retained
because installed-package inspection and the signed package inventory are part of the
release proof. Cleaning dpkg state for a smaller image was rejected because it would
trade a modest size reduction for weaker auditability.

### 2026-07-21 -- Converge generic development images offline

New development cards need the same reproducible starting point as production while
still following current packages and the developer's tracked working-tree content.
The builder therefore gained a separate offline development play: it reuses the
shared system role, installs writable-profile state and the freshly built service,
runs twice to prove idempotency, and passes an independent profile verifier before an
unsigned development artifact is published to an ignored local build directory. It
never shares the signed production release namespace under `dist/`.

Reusing the live development play inside chroot was rejected because its hardware
checks, NetworkManager activation, service transitions, and reboot handlers are
meaningful only on a running Pi. Adding credentials to Ansible was also rejected;
the offline role deliberately creates neither login access nor network profiles.
