# ADR: Pi system-layer configuration via Ansible

- **Status:** Accepted
- **Date:** 2026-06-26
- **Owner:** raspi
- **Related:** root `AGENTS.md` (the README-is-the-runbook convention this revises);
  `06-2026-06-25-ap-networking-bring-up.md` (the AP profile this task automates, **as
  amended 2026-06-25 for the WPA2-AES cipher pin**); `07-2026-06-25-picamera2-camera-owner.md`
  (the camera owner whose apt deps task 3 installs and whose `video` group task 9
  guarantees); `05-2026-06-23-service-language-rust.md` and
  `01-2026-06-22-crash-safe-recording.md` (the read-only-root deploy model this layer
  must respect); `README.md` (the bootstrap/verify/ops runbook)

## Context

Bringing up the dancam camera unit meant SSHing into the Pi and running a sequence of
one-off commands -- `apt full-upgrade`, an `apt install` of the camera-process deps
(`python3-picamera2`, `ffmpeg`), `sed` edits to `/boot/firmware/config.txt` and
`/etc/avahi/avahi-daemon.conf`, an `nmcli` AP profile, `locale-gen`. The root
`README.md` was the only record of those commands, so the Pi's real system state lived
in prose that drifts from the box and offered no way to diff "what the docs say"
against "what the Pi actually is."

We want that system state expressed declaratively: one command to converge a
freshly-flashed Pi, re-runnable, idempotent, and reviewable, without losing the
hard-won field knowledge the README captured. The forces:

- **The camera/`rpicam` stack is the system's weak link**, and Raspberry Pi OS is
  exactly what solves it (in-kernel IMX708 overlay, libcamera, `python3-picamera2`).
  That stack is roughest under NixOS, so switching the whole OS to get declarative
  config would trade the system's hardest-won asset for config purity.
- **The dev loop must stay fast.** `deploy.sh` cross-builds and rsyncs the `dancam`
  binary + systemd unit in seconds; folding that into a provisioning run would wreck
  the inner loop.
- **The AP password is a secret.** It must never enter the repo, the playbook, or
  shell history.
- **Idempotency must be verifiable**, not assumed -- a converged Pi must re-run to
  `changed=0`.

## Decision

Use **Ansible**, run from the Mac over SSH, sourced from the existing Nix flake so it
is version-managed like the Rust toolchain. Stay on Raspberry Pi OS (not NixOS).
Ownership splits three ways with no overlap:

- **Ansible owns the system layer.** A single flat playbook
  (`raspi/ansible/site.yml`, no roles) converges: `apt full-upgrade`; the
  `config.txt` camera overlay (`camera_auto_detect=0` + `dtoverlay=imx708`); the
  camera-process apt deps (`python3-picamera2`, `ffmpeg`); Avahi `wlan0` scoping; the
  `en_US.UTF-8` locale; the `dancam-ap` NetworkManager profile (every setting **except
  the PSK**); and `dan`'s `video`-group membership. Driven by `just raspi-provision`
  (converge), `just raspi-provision-check` (`--check --diff` drift detector), and
  `just raspi-provision-lint` (hardware-free `--syntax-check` + `ansible-lint` gate).
- **`deploy.sh` is untouched.** It still owns the Nix cross-build + rsync of the
  `dancam` binary and the systemd unit, and the fast restart loop. The unit's
  `DANCAM_BACKEND=camera` and `DANCAM_REC_DIR=/home/dan/rec` envs stay the unit's
  (deploy.sh-owned) concern; Ansible deliberately does not manage them. No
  `StateDirectory`/mkdir task owns the rec dir either -- `camera.py` self-creates it
  at startup.
- **The README becomes a thin bootstrap/verify/ops runbook.** It owns what Ansible
  structurally cannot: GUI flash + Imager version traps, first boot, SSH bootstrap,
  the camera smoke-test, the `from picamera2` import-verify (a runtime check under
  `User=dan`, which Ansible cannot make), the AP safe-flip timer procedure, the AP
  smoke-test, and the one deliberate manual secret step below.

**Single docs-split principle: one home per fact.** A command lives where it executes
(the playbook). A hard-won *why* lives as the mandatory `#` comment on the action it
justifies. Every task and handler also carries a concise `name:` -- the *what* and the
run-output label -- which additionally satisfies ansible-lint's `name[missing]` rule.

**Provisioning always runs over home Wi-Fi.** Task 1 (`apt`) needs internet, and the
Pi's AP mode is `ipv4.method shared` with no upstream (ADR 06 rejects AP+STA
concurrency). The AP is for testing the link *after* provisioning, never for running
the play -- there is no `10.42.0.1` provisioning path.

**Reboot-after-any-upgrade is intentional.** The `apt full-upgrade` task notifies a
`reboot` handler, which fires whenever any package changed (not only on a kernel
bump). This supersedes the README's old "reboot only if a new kernel/firmware" rule:
it is simpler than probing `/run/reboot-required`, and an extra reboot after a
non-kernel upgrade is safe.

**The AP profile is provisioned without its PSK.** Task 8 sets every `dancam-ap`
field except `802-11-wireless-security.psk`. The PSK is set once by hand on the Pi
(README), so the secret never enters the repo or the playbook -- and leaving the
secret field unmanaged is also what keeps the task idempotent, because round-tripping
NetworkManager secret fields (`psk`/`psk-flags`) through the module has known
idempotency gaps. Re-running the playbook does not disturb the hand-set PSK.

Task 8 provisions the **WPA2-AES-pinned** profile from ADR 06 (RSN proto, CCMP
pairwise + group; no TKIP/WPA1) -- the automation of the iOS "Weak Security" fix. The
three cipher props are written as **single-element YAML lists** (`[rsn]`, `[ccmp]`),
not scalars: `community.general.nmcli` marks `proto`/`pairwise`/`group` list-typed and
parses the live value into a list, then does an order-insensitive list compare only
when both sides are lists. A scalar would compare `["rsn"] != "rsn"` and churn every
run, breaking the idempotency test; the single-element list compares equal. Once task
8 owns the profile, the playbook is the only repo home of the weak-security fix, so
its verification asserts the cipher pins.

**Scope: dev image only.** Car-image hardening (read-only overlay root, `/data`
journaled partition, AP autoconnect) stays deferred per `raspi/AGENTS.md`; the
playbook carries a marked "car-image hardening: deferred" comment and no speculative
tasks.

## Consequences

- One command (`just raspi-provision`) converges a freshly-flashed Pi; one command
  (`just raspi-provision-check`) shows drift without touching it; one command (`just
  raspi-provision-lint`) catches YAML/module errors on the Mac before any Pi is
  involved.
- The load-bearing apt deps (`python3-picamera2`, `ffmpeg`) stop being stranded in
  README prose. Their absence used to surface only when the camera service started
  (ImportError / ffmpeg-not-found); now it is declarative system state.
- `ansible` + `ansible-lint` ship in the Nix dev shell, so the provisioning tool is
  version-managed exactly like the Rust toolchain.
- The fast app loop is preserved: `deploy.sh` is untouched and stays seconds, not a
  playbook run.
- One step stays deliberately manual: setting the AP PSK by hand on the Pi. This is
  the price of keeping the secret off the repo; an `ansible-vault` story is deferred
  until unattended reruns need it.
- Risk / fallback: if the `nmcli` task ever churns despite the absent PSK (a stubborn
  cipher-list diff or an unmanaged-field round-trip), fall back to a templated
  `.nmconnection` keyfile dropped in place. Noted here so the fallback is on record.

## Alternatives considered

- **Full NixOS on the Pi.** Rejected: the IMX708/`rpicam`/libcamera camera stack --
  the system's weakest link -- is exactly what Raspberry Pi OS solves and what is
  roughest under NixOS. Config purity is not worth risking the hardest-won asset.
- **A hand-rolled idempotent `provision.sh`.** Rejected: re-implements a fraction of
  Ansible (modules, handlers, change detection) and still has no dry-run/diff. The
  `--check --diff` drift detector is a primary reason to adopt a real config tool.
- **cloud-init / image baking.** Deferred to the car image. It is the right tool for
  an immutable, mass-produced unit, but heavier than needed for iterating on a single
  dev Pi over SSH.
- **Templated `.nmconnection` keyfile for the AP.** Heavier than the `nmcli` module
  for one profile and would still need the PSK handled separately. Kept on record as
  the fallback if the module's cipher-list idempotency proves unreliable on-device.
- **`nmcli` module with the PSK in ansible-vault or a prompt.** Rejected: both are
  heavier than setting the PSK by hand, and managing NM secret fields through the
  module has known idempotency gaps. PSK-by-hand is minimal, idempotent, and keeps the
  secret off the repo.
- **Folding `deploy.sh` into Ansible.** Rejected: the hot dev loop must stay seconds,
  not a playbook run. The binary/unit artifact and the system layer have different
  cadences and stay separate owners.
