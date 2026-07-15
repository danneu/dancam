# Pi provisioning

The camera unit stays on Raspberry Pi OS and is converged from the Mac with
Ansible. Provisioning makes onboard system state declarative, repeatable, and
reviewable without pulling the fast binary-deploy loop into configuration
management.

This page owns the provisioning tool, its execution and idempotency model, the
boundary between system state and deployed artifacts, and the split between
per-machine connection identity and the fixed service identity. The
[OS image design](os-image.md) owns the desired partition, mount, and write
policy; [networking](networking.md) owns the AP and mDNS behavior; and
[recording](recording.md) owns the camera process and media format.

## Ownership boundary

The repository has four distinct configuration owners:

- `raspi/ansible/site.yml` owns onboard system state. It is one flat playbook,
  with no roles, run against Raspberry Pi OS over SSH.
- `raspi/deploy.sh` and `raspi/dancam.service` own the cross-built service
  binary, systemd unit, deploy paths, service environment, and fast restart
  loop. Provisioning does not render or deploy the unit.
- `raspi/scripts/partition-card.sh` owns SD-card geometry and filesystem
  creation. The playbook owns the resulting mounts and directory ownership.
- `raspi/README.md` owns human and runtime operations that cannot be expressed
  as converged system state: flashing, first boot, smoke tests, the manual AP
  secret, safe AP toggling, and car-image sequencing.

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
Mac. A converged Pi must re-run with `changed=0`; idempotency is an observed
acceptance condition, not an assumption.

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

The final car-image pass is explicit:

```sh
just raspi-provision-car
```

It sets the playbook's `car_image` variable and applies the read-only-root
posture only after the shared development layout is proven. The runbook owns
the preconditions and maintenance sequence.

## Managed system state

The development and car images share a base convergence layer. It includes:

- the required card-layout gate, apt full-upgrade, Picamera2/ffmpeg/v4l2
  runtime packages, and the IMX708 device-tree configuration;
- Avahi scoping, the `en_US.UTF-8` locale, and the full `dancam-ap`
  NetworkManager profile except its PSK;
- the fixed `dancam` system user and its `video` supplementary group;
- `/persist` and `/data` mounts, the `/persist/journal` bind, and
  playbook-owned `/data/rec` ownership;
- persistent bounded journald, the hardware watchdog, recording-oriented dirty
  writeback limits, and weekly filesystem trimming.

The `car_image` layer persists NetworkManager and systemd-timesync state under
`/persist`, adds the required bind and tmpfs mounts, makes root and
`/boot/firmware` read-only on the next boot, disables unattended package
maintenance, rejects file-backed or write-backed zram swap, and installs the
boot storage-health witness. The [OS image design](os-image.md) is authoritative
for why those states exist; the playbook is authoritative for how they are
installed.

## Connection and service identities

A person flashing a Pi chooses the SSH login user. The camera daemon does not
inherit that identity. Ansible creates a project-owned, non-login `dancam`
system user and grants it `video` access for the camera and DMA devices. The
static unit declares `User=dancam`, and the playbook creates `/data/rec` owned by
that user. Provisioning therefore precedes the first deploy on a fresh card.

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

The AP PSK never enters the repository, `.env`, or Ansible. The playbook manages
every non-secret field of `dancam-ap`; the operator enters the PSK once on the Pi.
Leaving the secret field unmanaged both protects it and avoids NetworkManager
module churn around `psk` and `psk-flags`. The car-image layer seeds and bind
mounts NetworkManager state under `/persist` so the hand-entered secret survives
the read-only root.

The WPA2-AES values `proto`, `pairwise`, and `group` are expressed as
single-element YAML lists (`[rsn]`, `[ccmp]`, `[ccmp]`). The
`community.general.nmcli` module parses live values as lists and performs its
order-insensitive comparison only when desired values are also lists. Scalars
would compare unequal on every run and violate the `changed=0` gate.

If the NetworkManager module eventually churns despite the absent PSK and list
shape, the recorded fallback is a templated `.nmconnection` keyfile. It is not
used while the simpler module remains idempotent.

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
