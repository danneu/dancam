# Plan: migrate Pi system-layer setup from a manual README runbook to Ansible

## Context

Bringing up the dancam camera unit currently means SSHing into the Pi and running
a sequence of one-off commands -- `apt full-upgrade`, an `apt install` of the
camera-process deps (`python3-picamera2`, `ffmpeg`), `sed` edits to
`/boot/firmware/config.txt` and `/etc/avahi/avahi-daemon.conf`, an `nmcli` AP
profile, `locale-gen`. The root `README.md` (steps 3-8) is the only record of
those commands, so the Pi's real system state lives in prose that drifts from the
box and offers no way to diff "what the docs say" against "what the Pi actually
is." Dan wants that system state expressed declaratively -- one command to
converge a freshly-flashed Pi, re-runnable, idempotent, and reviewable -- without
losing the hard-won field knowledge captured in the README.

Decision (settled with Dan before this plan): use **Ansible**, run from the Mac
over SSH, sourced from the existing Nix flake so it is version-managed like the
Rust toolchain. We stay on Raspberry Pi OS (not NixOS) because the IMX708 /
`rpicam` camera stack -- the system's weak link -- is exactly what Pi OS solves
and what is roughest under NixOS. Ansible owns the **system layer**; the existing
`deploy.sh` keeps owning the **app artifact**; the README becomes a thin
bootstrap/verify/ops **runbook**.

Single principle for the docs split: **one home per fact.** A command lives where
it executes (the playbook). A hard-won *why* lives as the mandatory comment on the
action it justifies (Dan's "every action needs a comment" rule is the vehicle).
Human-only and runtime-only steps stay in the README.

## Scope and boundaries (three owners, no overlap)

- **Ansible** owns system state: apt, `config.txt` camera overlay, Avahi scoping,
  locale, the `dancam-ap` NetworkManager profile, and `<user>`'s `video`-group
  membership (the camera backend needs it).
- **`deploy.sh` is untouched** -- it owns the Nix cross-build + rsync of the
  `dancam` binary and the systemd unit, and the fast restart loop. Not folded into
  Ansible: the hot dev loop must stay seconds, not a playbook run. The unit now
  carries `Environment=DANCAM_BACKEND=camera` (swoop `fox`, commit `b47a943`) and
  `Environment=DANCAM_REC_DIR=/home/<user>/rec` (swoop `jet`, commit `8eac682`); both
  envs stay the unit's (deploy.sh-owned) concern -- Ansible deliberately does **not**
  manage them, so the boundary is intentional, not an omission. No Ansible
  `StateDirectory`/mkdir task is missing for the rec dir either: `camera.py` creates
  `DANCAM_REC_DIR` itself at startup (`parents=True, exist_ok=True`).
- **README** owns what Ansible structurally cannot: GUI flash + Imager version
  traps, first boot, SSH bootstrap, camera smoke-test, the AP safe-flip timer
  procedure, AP smoke-test, and the one deliberate manual secret step (below).
- **Dev image only.** Car-image hardening (read-only overlay root, `/data`
  partition, AP autoconnect) stays deferred per `raspi/AGENTS.md`; the playbook
  gets a clearly-marked "car-image hardening: deferred" comment, no speculative
  tasks.

## Ansible layout (minimal -- flat playbook, no roles)

```
raspi/ansible/
  ansible.cfg      # interpreter_python=auto_silent; inventory=inventory.ini;
                   # ssh StrictHostKeyChecking=accept-new; pipelining=True
  inventory.ini    # [dancam] dancam ansible_host=dancam.local ansible_user=<user>
                   #          ansible_ssh_private_key_file=~/.ssh/id_ed25519
  site.yml         # one play, hosts: dancam, become: true, tasks + handlers
```

Mirrors `deploy.sh` defaults (`<user>@dancam.local`, key `id_ed25519`). The
host is overridable via the Just recipes' `host` parameter (below) for when mDNS
is flaky and you need to address the Pi at a raw LAN IP. **Provisioning always
runs over home Wi-Fi** -- task 1 (`apt`) needs internet, and the Pi's AP mode is
`ipv4.method shared` with no upstream (ADR 06 rejects AP+STA concurrency). The AP
is for testing the link *after* provisioning (verification step 10), never for
running the play -- there is no `10.42.0.1` provisioning path.

### Tasks (every task carries a justifying comment; this is the whole play)

Every task **and handler** also carries a concise `name:` (the *what*) alongside its
mandatory `#` comment (the *why*). Beyond readability there are two hard reasons: a
`name:` makes `PLAY RECAP` and run output legible (the `#` comment never surfaces in
output), and it satisfies ansible-lint's default `name[missing]` rule -- without
names the verification-step-0 `ansible-lint` gate exits non-zero before any Pi is
touched. So this strengthens "one home per fact" rather than diluting it: the `name:`
is the *what* (also the run-output label), the `#` comment is still the single home
of the *why*. The task lines below list module + args + the `#` why-comment; read
each as also carrying a short `name:` (e.g. `name: Pin WPA2-AES ciphers on dancam-ap`).
The handlers already carry names (the string `notify:` targets them by).

1. `ansible.builtin.apt` -- `update_cache: true`, `upgrade: full`. `notify: reboot host`.
   `# fresh Lite image lags; full == faithful "apt full-upgrade". notify fires only
   when a package actually changed, so this reboots after ANY upgrade -- intentional
   and safe, and simpler than probing /run/reboot-required for kernel-only (the
   README's old rule). See ADR 09.`
2. `ansible.builtin.apt` -- `name: [vim]`, `state: present`.
   `# operator convenience; the only non-load-bearing add (vs. task 3's runtime deps).`
3. `ansible.builtin.apt` -- `name: [python3-picamera2, ffmpeg]`, `state: present`,
   `install_recommends: false`. `notify: reboot host` is **not** set (no kernel/boot
   change). `# LOAD-BEARING runtime deps of jet's camera owner: raspi/camera/camera.py
   imports picamera2 and shells out to ffmpeg (FfmpegOutput) to mux the H.264 MPEG-TS
   recording segments, and the deployed DANCAM_BACKEND=camera service spawns it. Without
   these the Pi converges clean yet the camera dies at runtime (ImportError: picamera2 /
   ffmpeg-not-found) -- exactly the silent, image-dependent drift this migration exists
   to kill, and the apt fact stops being stranded in README prose. libcamera, numpy,
   simplejpeg arrive transitively. install_recommends: false == the README's
   --no-install-recommends, keeping the desktop GUI stack off Lite. See ADR 07 (jet's
   Picamera2 owner).`
4. `ansible.builtin.lineinfile` `/boot/firmware/config.txt` -- `regexp: '^camera_auto_detect='`,
   `line: 'camera_auto_detect=0'`. `notify: reboot host`.
   `# Arducam IMX708 is not an official module, so it is not auto-detected.`
5. `ansible.builtin.lineinfile` `/boot/firmware/config.txt` -- `regexp: '^dtoverlay=imx708$'`,
   `line: 'dtoverlay=imx708'`, `insertafter: '^\[all\]'`. `notify: reboot host`.
   `# in-kernel overlay survives apt upgrade, unlike Arducam's prebuilt-driver
   script. anchored regexp won't touch a commented #dtoverlay; insertafter keeps it
   in [all] scope even if a later section is appended.`
6. `community.general.ini_file` `/etc/avahi/avahi-daemon.conf` -- `section: server`,
   `option: allow-interfaces`, `value: wlan0`, `no_extra_spaces: true`, `backup: true`,
   `mode: '0644'`. `notify: restart avahi-daemon`.
   `# Two DISTINCT failure modes motivate this task; do not conflate them.
   (a) Directive ABSENT: Avahi falls back to all interfaces incl. loopback, can
   self-conflict on a stale loopback publication, and renames the host to
   dancam-2.local -- a boot race, so it flakes (some boots come up fine). This is
   why the directive must exist AND land under [server]: ini_file guarantees the
   section placement regardless of prior content, where lineinfile would EOF-append
   it out of section if the key were ever absent, silently breaking the scoping.
   (b) Directive PRESENT but SPACED: no_extra_spaces is REQUIRED, not cosmetic.
   ini_file defaults to "allow-interfaces = wlan0" (sep " = "), but Avahi's ini
   parser strips only leading whitespace, so the space before = stays glued to the
   key ("allow-interfaces "). That is then an UNKNOWN key, and Avahi treats unknown
   keys as FATAL: load_config_file returns -1 and avahi-daemon refuses to start
   (deterministic on every boot -- status "failed", journal "Invalid configuration
   key"), NOT a silent ignore. no_extra_spaces emits "allow-interfaces=wlan0", the
   exact form the README sed proved working. backup preserves the README step-6
   .conf backup caution. mode '0644' is avahi-daemon.conf's canonical perm and clears
   ansible-lint's default risky-file-permissions rule, which ini_file would otherwise
   trip (it defaults to create: true with no mode).`
7. `community.general.locale_gen` -- `name: en_US.UTF-8`, `state: present`.
   `# silences the "cannot change locale (UTF-8)" SSH login warning on fresh Lite.`
8. `community.general.nmcli` -- the `dancam-ap` AP profile, **every setting except the
   PSK**, `state: present` (created, never activated):
   `conn_name: dancam-ap`, `type: wifi`, `ifname: wlan0`, `ssid: dancam-dev`,
   `autoconnect: false`, `wifi: {mode: ap, band: bg, channel: 1}`,
   `wifi_sec: {key-mgmt: wpa-psk, proto: [rsn], pairwise: [ccmp], group: [ccmp]}`
   (no `psk`), `method4: shared`, `ip4: 10.42.0.1/24`, `method6: ignore`.
   `# AP profile spec per ADR 06 (amended 2026-06-25: WPA2-AES). The cipher pin --
   proto rsn, pairwise ccmp, group ccmp -- removes TKIP/WPA1 from the beacon so iOS
   stops flagging the AP "Weak Security"; without it a fresh provision silently
   regresses that fix. The three cipher props MUST be YAML lists, not scalars:
   community.general.nmcli marks proto/pairwise/group list-typed and always parses
   the live value into a list, but in diff mode leaves the desired value as written,
   then only does an order-insensitive list compare when BOTH sides are lists. A
   scalar "proto: rsn" compares ["rsn"] != "rsn" and churns every run -- breaking
   the changed=0 idempotency test (verification step 6); the single-element list
   "[rsn]" compares equal and is idempotent. key-mgmt is str-typed, so it stays
   scalar. The WPA PSK is omitted on purpose: it is set once by hand on the Pi
   (README) so the secret never enters the repo or the playbook, and leaving the
   secret field unmanaged is also what keeps this task idempotent (round-tripping NM
   secret fields through the module is an unreliable diff). autoconnect=false so
   bringing it up never strands the Mac.`
9. `ansible.builtin.user` -- `name: <user>`, `groups: video`, `append: true`.
   `# jet's Picamera2 camera owner (DANCAM_BACKEND=camera, set on the deployed unit)
   opens the camera under systemd as user <user>, which needs video-group membership to
   reach /dev/video11 (bcm2835-codec, used by the hardware MJPEGEncoder) and
   /dev/dma_heap/* (libcamera buffers). The
   Raspberry Pi Imager default user already gets video, so on the Imager bootstrap
   path this is a no-op -- but guaranteeing it declaratively is the whole point of
   this layer: a re-image or alternate provisioning path where the default user
   lacks video would otherwise provision clean yet fail the camera at runtime.
   append: true so we never strip <user>'s other groups. This is system state, so the
   playbook owns it rather than SupplementaryGroups on the deploy.sh-owned unit.`

Note: tasks 4-5 deliberately stay on `lineinfile` -- `config.txt` is not INI (its
`[all]`/`[pi4]` filters are not INI sections and the default keys live in a
section-less preamble), so `ini_file` would misparse it; `lineinfile` is the
correct tool there. Only the genuinely-INI `avahi-daemon.conf` (task 6) uses
`ini_file`.

### Handlers (defined in this order)

- `restart avahi-daemon` -- `ansible.builtin.service`, `state: restarted`.
- `reboot host` -- `ansible.builtin.reboot` (built-in connection wait). Defined
  last so it runs after other handlers. A handler runs once per play regardless of
  how many tasks notify it; on a clean re-run nothing is notified, so no reboot.

### The one deliberate manual step (stays in the README, by design)

After the first provision run, set the dev AP password once on the Pi. Use the
README's existing prompt pattern (do not pass the PSK as a literal argument -- that
would write it into shell history), and keep the `sudo` the current README uses:

```sh
read -rsp 'dancam-dev WPA2 PSK: ' DANCAM_AP_PSK; echo
sudo nmcli connection modify dancam-ap 802-11-wireless-security.psk "$DANCAM_AP_PSK"
unset DANCAM_AP_PSK
```

This is the only step that touches the secret. It is intentionally manual so the
PSK never lands in the repo, the playbook, or shell history. Re-running the
playbook does not disturb it (the `psk` field is not managed).

## Flake + Justfile

- `flake.nix` (`packages` list -- `flake.nix#packages`): add `pkgs.ansible` and
  `pkgs.ansible-lint`. nixpkgs `ansible` is the batteries-included build that
  bundles `community.general` (provides `nmcli`, `locale_gen`, `ini_file`), so no
  separate collection install; `ansible-lint` powers the hardware-free gate below.
  Now `nix develop` carries both exactly like it carries the Rust toolchain.
- `Justfile`: three new tasks, matching the existing `cd`-into-subdir style
  (`raspi-mock` is the precedent). The two run-recipes take a `host` parameter
  defaulting to `dancam.local`, passed as an Ansible extra var (`-e` outranks the
  inventory's `ansible_host`) so you can target a raw LAN IP when mDNS is flaky:
  - `raspi-provision host='dancam.local'`:
    `nix develop -c bash -c 'cd raspi/ansible && ansible-playbook site.yml -e ansible_host={{host}} --ask-become-pass'`
  - `raspi-provision-check host='dancam.local'`: same with `--check --diff` -- the
    drift detector (shows exactly what is out of sync on the Pi without changing it).
  - `raspi-provision-lint`: the hardware-free gate, no host connection --
    `nix develop -c bash -c 'cd raspi/ansible && ansible-playbook site.yml --syntax-check && ansible-lint site.yml'`.
    Mirrors the `just adr-check` precedent: catch YAML/module errors on the Mac
    before reaching for a Pi. `--syntax-check` is shallow (no module-arg
    validation), so `ansible-lint` carries the real coverage.
  - `--ask-become-pass` because `<user>`'s sudo needs a password (same reason
    `deploy.sh` uses `ssh -t`). All provisioning runs over home Wi-Fi (see the
    inventory note); there is no AP provisioning path.

## Docs to write/update (same change, per the working stance)

- **New ADR** `raspi/docs/design/09-2026-06-26-pi-system-layer-config-ansible.md`
  (next seq is 09 -- `jet` took 07 for the Picamera2 owner and the infinity-focus fix
  in commit `da42b79` took 08; `just adr-check` enforces the name. Date the filename
  the day the ADR is actually written -- 2026-06-26 if today, later otherwise). Match ADR 05/06 house
  style: metadata block (`Status: Accepted`, `Date`, `Owner: raspi`, `Related`),
  then `## Context`, `## Decision`, `## Consequences`, `## Alternatives
  considered`. Record: the Ansible decision; the `deploy.sh`/README boundary; the
  dev-only scope with car-image deferred; that provisioning runs over home Wi-Fi
  only (the AP has no upstream); that reboot-after-any-upgrade is intentional and
  safe (simpler than a kernel-only `/run/reboot-required` probe, superseding the
  README's old "kernel/firmware only" rule); the AP-profile-without-PSK choice
  (rationale: secret hygiene first -- the PSK is set by hand on the Pi and never
  enters the repo -- and verified idempotency, since managing NM secret fields like
  `psk`/`psk-flags` through the module has known idempotency gaps).
  Alternatives to document and reject: full NixOS on the Pi (camera/libcamera risk
  on the weakest hardware); a hand-rolled idempotent `provision.sh` (no
  dry-run/diff); cloud-init/image baking (deferred to the car image); the templated
  `.nmconnection` keyfile and the `nmcli`-module-with-PSK-in-vault/prompt variants
  (both heavier; PSK-by-hand is minimal + idempotent + secret-off-repo). Also record
  that task 8 provisions the WPA2-AES-pinned profile (RSN/CCMP, no TKIP/WPA1) and
  the source-verified reason the cipher props must be YAML lists for idempotency.
  Cross-ref ADR 06 **as amended 2026-06-25** (the cipher pin it now automates),
  ADR 07 (`jet`'s Picamera2 owner -- the reason task 3 installs
  `python3-picamera2`/`ffmpeg` and task 9 guarantees `<user>`'s `video` group), and
  ADR 05 / ADR 01 (the read-only-root deploy model it must respect).
- **`README.md`**: replace the command bodies of the system-layer steps -- step 3
  (apt upgrade), step 4's config.txt camera-overlay commands only (the camera
  smoke-test below the overlay stays -- see keep-list), step 5's apt line (the
  `python3-picamera2 ffmpeg` install moves into the new playbook task 3), step 6
  (avahi), step 7's `nmcli` AP-profile body, and step 8 (locale) -- with a single
  "`just raspi-provision`" step plus the one-time manual PSK line in the AP section.
  Keep step 1 (flash + Imager traps), step 2 (SSH + `uname`), the camera smoke-test
  (`rpicam-hello --list-cameras`, `rpicam-jpeg`), step 9 (`just raspi-deploy`), the
  AP safe-flip timer procedure, and step 10 (AP smoke-test). (Section numbers are
  post-`jet`: jet inserted a camera-deps section as step 5, pushing avahi/AP/locale/
  deploy/AP-smoke-test to 6/7/8/9/10.) Three carve-outs from the gutting, all added
  after this plan was drafted: (a) the cipher *values* move into task 8, but the AP
  **reactivation caveat** (in `README.md#7. Create the dev access point profile`: a cipher change only takes effect on
  the next `nmcli connection up`/`device reapply`) is ops prose that **stays** in the
  README runbook; (b) step 5's `python3 -c "from picamera2 import Picamera2"`
  import-verify and the systemd device/group check **stay** as ops prose -- they
  confirm the deployed camera opens under `User=<user>` with no login session, a runtime
  check Ansible structurally cannot make; (c) do **not** clobber the deployed-camera
  material in section 9 (`README.md#9. Deploy and run the service`) when
  trimming -- it documents `jet`'s `DANCAM_BACKEND=camera` Picamera2 owner, the
  `/v1/preview/live.mjpeg` smoke-test, and the `DANCAM_REC_DIR` recording prose
  (`camera.py` self-creates that dir, so no Ansible task owns it), all outside this
  migration's scope.
  **Resulting README structure (pin this -- don't leave section order or stubs to
  chance):** the consolidated `just raspi-provision` step takes over the gutted
  step 3 (apt) slot, so it runs *before* every kept smoke-test/verify -- the camera
  `rpicam-hello` (step 4) and the `from picamera2` import-verify (step 5) both depend
  on provisioned state (overlay + picamera2 + reboot) that the provision run
  establishes. The two sections the playbook absorbs *entirely*, with nothing left to
  keep -- avahi and locale -- are **deleted, not left as empty stubs**, and the README
  is renumbered. Target section list after the edit: 1 Flash, 2 SSH, 3 Provision
  (`just raspi-provision`), 4 Enable camera (smoke-test only -- overlay body gone),
  5 Camera deps (import-verify only -- apt line gone), 6 Create the AP profile
  (one-time manual PSK + reactivation caveat -- `nmcli` body gone), 7 Deploy
  (`just raspi-deploy`), 8 AP smoke-test. (apt/avahi/locale collapse into the provision
  run; old AP/deploy/AP-smoke sections 7/9/10 renumber to 6/7/8.)
- **`raspi/AGENTS.md`**: flip the paragraph beginning "The root `README.md` is the
  fresh-Pi setup runbook" (under `raspi/AGENTS.md#Build / run`) to "the
  Ansible playbook is the source of truth for onboard system state; update
  `site.yml` and its comment in the same change; the README is the
  bootstrap/verify/ops runbook." Update the Software-stack AP bullet to note the
  profile is provisioned declaratively via Ansible (PSK set by hand). Add ADR 09
  to the ADR list (ADR 08, infinity-focus, is already listed). Note in the
  Rust-dev-loop/flake text that `ansible` now ships in the Nix shell.

## Critical files

- `raspi/ansible/site.yml`, `raspi/ansible/inventory.ini`, `raspi/ansible/ansible.cfg` (new)
- `flake.nix` (add `pkgs.ansible` + `pkgs.ansible-lint`)
- `Justfile` (add `raspi-provision`, `raspi-provision-check`, `raspi-provision-lint`)
- `README.md` (gut system-layer command bodies, steps 3-8; steps 4-5 partial -- step 4
  keeps the camera smoke-test below its overlay commands, step 5 keeps the import-verify)
- `raspi/AGENTS.md` (source-of-truth paragraph, AP bullet, ADR list)
- `raspi/docs/design/09-2026-06-26-pi-system-layer-config-ansible.md` (new ADR)
- Reference for exact values/regexps (anchored to README section headings, which
  survive renumbering; per the repo's no-line-numbers convention the prior `jet`
  line refs are dropped): `README.md#4. Enable the camera (IMX708)` (the
  `camera_auto_detect=0` / `dtoverlay=imx708` config.txt edits), `README.md#5. Install
  the camera process dependencies` (the `python3-picamera2 ffmpeg` apt line moves to
  task 3; the `from picamera2` import-verify stays), `README.md#6. Scope mDNS to Wi-Fi`
  (the `allow-interfaces=wlan0` avahi edit), `README.md#7. Create the dev access point
  profile` (the `nmcli ... modify` AP block incl. the proto/pairwise/group cipher pins,
  the `nmcli ... show` security assertion + expected `wpa-psk`/`rsn`/`ccmp`/`ccmp` values
  that feed verification step 9, and the reactivation caveat that stays in the README),
  `README.md#8. (Optional) Fix the locale warning` (the locale edit), `README.md#9. Deploy
  and run the service` (`jet`'s deployed-camera prose -- do not clobber);
  `raspi/docs/design/06-2026-06-25-ap-networking-bring-up.md` (locked profile spec,
  **amended 2026-06-25 for the cipher pin**); `raspi/deploy.sh` (host/key defaults
  to mirror); `raspi/dancam.service` (now carries `DANCAM_BACKEND=camera` and
  `DANCAM_REC_DIR=/home/<user>/rec`, both stay deploy.sh's).

## Verification

Steps 0-1 are Mac-only (no Pi); steps 2-12 are end to end on the real Pi.

0. **(Mac-only, no hardware)** `just raspi-provision-lint` -- `--syntax-check` and
   `ansible-lint` pass, catching YAML/module errors before any Pi is involved. This
   passes only because every task/handler is named (else the default `name[missing]`
   rule fails the gate) and the avahi `ini_file` task sets `mode: '0644'` (else the
   default `risky-file-permissions` rule does) -- both are designed in above, not
   afterthoughts to discover on the gate's first run.
1. `nix develop -c ansible --version` and `nix develop -c ansible-galaxy collection
   list community.general` -- Ansible comes from the flake AND the collection that
   tasks 6-8 (`ini_file`, `locale_gen`, `nmcli`) depend on actually resolves.
2. `just adr-check` -- ADR 09 is well-formed (contiguous, dated, kebab slug).
3. On a freshly-flashed Pi at "step 2 done" state: `just raspi-provision-check`
   lists pending changes without touching the Pi (proves the drift detector).
4. `just raspi-provision` converges in one invocation, including the reboot.
5. One-time: perform the README manual PSK step (the `read -rsp` / `sudo nmcli ...
   "$DANCAM_AP_PSK"` / `unset` pattern -- never a literal PSK on the command line).
6. **Idempotency acceptance test:** re-run `just raspi-provision` -> `PLAY RECAP`
   shows `changed=0` and no reboot. This explicitly covers task 8 after the cipher
   pins land -- a `changed` on the `nmcli` task would mean the scalar-vs-list churn
   the task 8 comment warns about, or an unmanaged-field diff. It doubles as the
   on-device confirmation the wpa2-aes plan flagged as still provisional (whether
   the module renders the list ciphers cleanly was unobserved). If the `nmcli` task
   churns despite the absent PSK or a stubborn cipher-list diff, fall back to the
   templated `.nmconnection` keyfile -- noted in ADR 09.)
7. Camera: `rpicam-hello --list-cameras` lists `imx708`, and `jet`'s camera-process
   deps (task 3) resolve -- `python3 -c "from picamera2 import Picamera2; print('ok')"`
   prints `ok` and `command -v ffmpeg` succeeds. This is the regression test for the
   new load-bearing apt task: it fails iff `python3-picamera2`/`ffmpeg` did not install,
   which is the runtime drift (ImportError / ffmpeg-not-found) that task otherwise
   leaves to surface only when the camera service starts.
8. mDNS -- three assertions, one per distinct failure mode (see task 6's comment):
   (a) the rendered file contains the exact line `allow-interfaces=wlan0` (no
   spaces); (b) `journalctl -u avahi-daemon` shows no "Invalid configuration key"
   line; (c) `systemctl status avahi-daemon` shows `running [dancam.local]` (not
   `dancam-2.local`) and `dancam.local` resolves from the Mac. (a) and (b) catch a
   `no_extra_spaces` regression: a spaced key is unknown to Avahi and FATAL, so the
   daemon refuses to start -- that fails deterministically every boot (status would
   be `failed`, journal would carry "Invalid configuration key"), so (b)/(c) catch
   it loudly rather than flaking. (c)'s `dancam-2.local` guard covers the *other*
   mode -- the directive going absent, which lets Avahi bind loopback and rename in
   a boot race; that one is race-prone, which is exactly why (a)'s deterministic
   file assertion backs it up.
9. AP profile: `nmcli connection show dancam-ap` matches the ADR 06 spec table and
   is **not** active. Also assert the WPA2-AES cipher pins with the exact
   security-show that moves out of the README (Section 7):
   `nmcli -f 802-11-wireless-security.key-mgmt,802-11-wireless-security.proto,802-11-wireless-security.pairwise,802-11-wireless-security.group connection show dancam-ap`
   -> expect `wpa-psk` / `rsn` / `ccmp` / `ccmp`. Once task 8 owns the profile the
   playbook is the *only* repo home of the iOS weak-security fix, so this is its
   regression test; without it a dropped or scalar-churned pin would ship the
   warning undetected.
10. AP path (existing runbook): arm the home-Wi-Fi restore timer, bring `dancam-ap`
    up, join `dancam-dev` from the iPhone, fetch `http://10.42.0.1:8080/v1/health`.
11. `just raspi-deploy` still works unchanged (binary + unit).
12. Camera permissions (task 9): `groups <user>` includes `video`, so the deployed
    `DANCAM_BACKEND=camera` service can open the camera under systemd. (No-op on an
    Imager-flashed Pi where `<user>` already has it; the task guarantees it regardless.)

## Out of scope / deferred

- Car-image hardening: read-only overlay root, `/data` journaled partition, AP
  autoconnect. A future swoop; the playbook leaves a marked placeholder, no tasks.
- ansible-vault / unattended reruns: not needed while the PSK is set by hand.
- Folding `deploy.sh` into Ansible: deliberately kept separate (fast app loop).

## Implementation notes

- Handler `name:` values are capitalized ("Reboot host", "Restart avahi-daemon") and
  the `notify:` references match, instead of the lowercase strings the plan's prose
  used. ansible-lint's default `name[casing]` rule flags lowercase names and would have
  failed the verification-step-0 gate; capitalizing both the handler `name:` and its
  `notify:` target preserves the notify-matches-handler contract while keeping the gate
  green. The gate confirms it: `ansible-lint` passed with 0 failures at the `production`
  profile.
- The inventory uses group `[dancam]` plus host `dancam` exactly as the plan specifies.
  Ansible emits a benign "Found both group and host with same name: dancam" warning on
  every run; left as-is because it is the plan's literal spec and the `-e ansible_host`
  override (the Just recipes' `host=` param) targets the host by that name.
- ansible-lint logs one ignored internal exception ("File name too long") while trying
  to schema-validate the long nmcli task args; this only means that one rule was skipped
  for that task, not a failure. `--syntax-check` covers the task's well-formedness and
  the module validates the args at runtime.

## Follow Up

- `raspi/AGENTS.md#OS and first flash (once)` still narrates the `config.txt` IMX708
  camera overlay and the Avahi `allow-interfaces=wlan0` scoping as manual post-boot
  steps. Now that `raspi/ansible/site.yml` owns that system state, that rationale prose
  could be aligned to point at the playbook in a later pass. (This change deliberately
  scoped the `raspi/AGENTS.md` edits to the source-of-truth paragraph, the AP bullet,
  the ADR list, and the flake note.)
