# ADR: Forkable Pi config

- **Status:** Accepted
- **Date:** 2026-06-30
- **Owner:** raspi
- **Related:** root `AGENTS.md`; `06-2026-06-25-ap-networking-bring-up.md`;
  `07-2026-06-25-picamera2-camera-owner.md`;
  `09-2026-06-26-pi-system-layer-config-ansible.md`

## Context

The repo is being prepared for public forks. The old Pi setup conflated two
identities:

- the SSH/Ansible connection user, which is per machine because it is created by
  Raspberry Pi Imager and selected by the person flashing the card;
- the service user, which owns the running camera process and recording state.

Those should not be the same decision. A forker should configure only how their
laptop connects to their Pi. The service should have a stable project-owned
identity, independent of whoever logs in over SSH. Per-user connection values and
home-Wi-Fi profile names also do not belong in tracked config or docs.

## Decision

Run the camera service as a fixed `dancam` system user. The systemd unit declares
`User=dancam`, `StateDirectory=dancam`, and
`DANCAM_REC_DIR=/var/lib/dancam/rec`. systemd creates `/var/lib/dancam` for the
service user, and the camera process creates the `rec` subdirectory. The service
does not need to read `$STATE_DIRECTORY` because the deterministic path is exactly
`/var/lib/<StateDirectory>`.

Keep only connection parameters configurable:

- `DANCAM_HOST` for the SSH target, including the login user;
- `DANCAM_SSH_KEY` for the private key;
- `DANCAM_HOME_WIFI` for the NetworkManager home-Wi-Fi profile used by the AP
  safe-flip recipe.

These live in a single gitignored `.env`, seeded from `.env.example`. The root
`Justfile` loads `.env` with `set dotenv-load := true`, so `deploy.sh`, helper
scripts, and `raspi-provision*` recipes all share the same connection source. The
provision recipes pass `ansible_user` and `ansible_ssh_private_key_file` to Ansible
with `-e`, matching the existing `-e ansible_host` override pattern.

Keep `raspi/ansible/inventory.ini` tracked as a shared host constant only:
`dancam ansible_host=dancam.local`. Shared project constants also stay hardcoded:
hostname `dancam`, AP SSID `dancam-dev`, and AP gateway `10.42.0.1`.

The playbook ensures the `dancam` system user exists and belongs to `video`, because
the camera service needs access to `/dev/video11` and `/dev/dma_heap/*`. The unit is
static and ships verbatim; `deploy.sh` does not render user names or paths.

Tracked implementation plans stay tracked so the plan promotion pipeline keeps
working. Historical records are de-identified in place for publication.

## Consequences

A fork starts with one local copy step: `cp .env.example .env`, then fill in the
connection values and run the documented `just` recipes. There is no second
inventory file to keep in sync and no service identity for a forker to choose.

Secrets and personal identifiers stay out of the tracked tree. The AP PSK remains a
manual Pi-side secret per ADR 06 and ADR 09; `.env` is gitignored; the inventory
contains only the shared host constant.

Provisioning must happen before deploy on a fresh Pi because the unit starts as the
`dancam` user. This matches the README order: provision first, then deploy.

There are no shipped users, so existing development cards are reflashed onto the new
layout rather than migrated in place. No compatibility path is kept for old
recordings under a login user's home directory.

ADR 09's claims that `deploy.sh` is untouched, the unit owns a login-user recording
directory, and no `StateDirectory` mechanism exists are superseded by this ADR.

## Alternatives considered

- **Service follows the login user, rendered during deploy.** Rejected. It couples
  recording ownership to whichever account was used for SSH, adds a render step to a
  static unit, and keeps the footgun this decision removes.
- **Use systemd `%h` for the recording directory.** Rejected. For system services,
  `%h` is not influenced by `User=`, so it does not reliably mean the service user's
  home directory. More importantly, following a login user's home is the wrong model
  for a camera daemon.
- **`DynamicUser=yes`.** Considered, but a static user keeps recording ownership
  stable and inspectable during SSH smoke-tests. Dynamic users can push state through
  private remapped directories, which is more indirection than this early hardware
  loop needs.
- **A gitignored Ansible inventory copied from an example.** Rejected. It would make
  fork setup require the same connection identity in two files. Passing the user and
  key from `.env` with `-e` keeps one source of truth.
- **Commit per-user config.** Rejected because it leaks identifiers and makes forks
  edit tracked files before first use.
- **Environment variables without an example file.** Rejected because it hides the
  required setup from a forker.
