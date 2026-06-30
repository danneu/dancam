# Plan: make the dancam Pi setup forkable (fixed service user + de-personalize)

## Context

The project is about to be published to GitHub so a friend can run it on his own
Raspberry Pi. The literal `<user>` in the Pi-side setup is doing **two unrelated jobs**
that got collapsed into one identity, and they have opposite right answers:

1. **The connection user** -- the SSH/Ansible login Dan typed into Raspberry Pi Imager
   (`ansible_user`, the SSH key, `DANCAM_HOST`, the home Wi-Fi connection). This is
   irreducibly per-machine: it is whatever the forker flashed. It **stays
   parameterized**.
2. **The service user** -- the account the camera process runs as (`User=<user>`,
   recording to `/home/<user>/rec`). This should **not** track the login user at all.
   Coupling the running service to whoever you happen to SSH in as is a footgun, not a
   feature. **Fix it** to a dedicated `dancam` system user with state under
   `/var/lib/dancam`.

On top of those, the SSH key `id_ed25519` and the home Wi-Fi NetworkManager
connection `netplan-wlan0-<name>` are personal. All of these appear across tracked
files: the Ansible inventory + playbook, `deploy.sh` + the systemd unit, the
`Justfile`/`scripts/*`, the Rust service + `camera.py` defaults, the README runbook,
and -- caught on review -- the roadmap, ADR 09, and ten of the thirty-one tracked
`plans/impl/*` records. A forker cannot run any of it without editing tracked files,
and the public repo would ship Dan's identifiers.

Goal, in a single commit: make a fork "copy one file (`.env`), fill in your connection
values, run via `just`," with the **service identity fixed** (no per-account anything in
the unit) and **the three personal connection tokens scrubbed from the published Pi-side
tree** (`<user>`, the SSH key `id_ed25519`, the home Wi-Fi `<home-wifi>` -- the proof's
exact scope; the app's own `com.danneu.*` bundle-id/OSLog namespace stays out of scope
with the rest of the iOS app, see Out of scope + Verification). The split:

- **Connection user stays parameterized, single-source:** the login user, SSH key,
  `DANCAM_HOST`, and home Wi-Fi all live in one gitignored `.env`, seeded from tracked
  `.env.example`. `deploy.sh` and the scripts already read `.env`; the `raspi-provision*`
  recipes pass the login user + key to Ansible via `-e`, sourced from `.env`, exactly as
  they already pass `-e ansible_host`. So `raspi/ansible/inventory.ini` carries no per-user
  data -- it reduces to the shared-constant host line (`dancam ansible_host=dancam.local`)
  and stays tracked. One file to copy, one place to set your identity.
- **Service user is fixed, not parameterized:** the unit statically declares
  `User=dancam`, `StateDirectory=dancam` (systemd auto-creates `/var/lib/dancam` owned
  by `dancam`, correct perms, no mkdir anywhere), and
  `Environment=DANCAM_REC_DIR=/var/lib/dancam/rec`. `deploy.sh` ships that unit verbatim
  -- **no deploy-time render**. The playbook ensures the `dancam` system user exists and
  is in `video`. The unit header already lists "dedicated service user" as a planned
  hardening pass and ADR 11 (this commit) floated `StateDirectory=dancam`; we un-defer
  both, per `AGENTS.md`'s "Optimize for the ideal solution, full stop" -- no hedging on
  commit size or churn, no login-user-follows path kept "just in case." There are no
  shipped users and nothing to migrate: Dan's own dev Pi is disposable and gets reflashed
  onto the new layout (see "After the commit"), so there is no `/home/<user>/rec` ->
  `/var/lib/dancam/rec` migration to reason about.
- **Shared project constants stay hardcoded:** hostname `dancam`/`dancam.local`, AP SSID
  `dancam-dev`, AP gateway `10.42.0.1`. The friend keeps these.

De-personalization spans the **whole Pi-side tracked tree**: live product files (code,
config, scripts, README, AGENTS, roadmap, ADRs) and the ten token-bearing historical
`plans/impl/*` records are all de-identified in place (the iOS app is the one
out-of-scope exclusion -- below). `plans/impl` stays tracked so the `/impl-plan` ->
`/promote-plan` pipeline (which `git add`s `plans/impl/*` without `--force`) keeps
working, and `git grep` over the tracked tree comes back empty with only `app/` excluded
(see Verification). The fixed-service-user reshape *helps* the scrub: it removes
`User=<user>`, `/home/<user>/rec`, and the login-user `video` task from the live config
outright, so most of the remaining `<user>` is prose to redact.

**Out of scope (explicit):** the iOS app and its Xcode signing/bundle id. Not touched,
not mentioned in this commit. (`AppConfiguration.swift` already defaults to the shared
`http://10.42.0.1:8080` with env/Info.plist overrides, so the app needs no Pi-side
change anyway.) The app also keeps two Xcode `// Created by <user>` author-stamps in its
UITests (`DanCamUITests.swift`, `DanCamUITestsLaunchTests.swift`); those are out of
scope and not Pi config, so the de-personalization proof excludes `app/` (Verification)
rather than touch them. **Same call for the app's `com.danneu.*` namespace** -- the
bundle id (`PRODUCT_BUNDLE_IDENTIFIER = com.danneu.DanCam`) and OSLog subsystem
(`Logger(subsystem: "com.danneu.dancam")`) are pervasive under `app/` and are explicitly
the excluded "Xcode signing/bundle id." Two `plans/impl/2026-06-26-1654-lime-swoop-spike.md`
lines reference that app namespace (`com.danneu.dancam`, `com.danneu.dancam.loopback`)
when describing app internals; they are left intact for the same reason and the proof
deliberately does not match inside `danneu` (genericizing them would drag the app's
bundle id into a commit that excludes it). The proof's guarantee is scoped to the three
connection-token classes, not to the string `danneu` (Verification).

## Non-goals / what deliberately stays hardcoded

- `dancam.local` (mDNS host), `dancam-dev` (AP SSID), `10.42.0.1/24` (AP gateway):
  shared project defaults; the friend flashes hostname `dancam` and keeps the AP
  profile as-is. `raspi/ansible/site.yml#Provision the dancam-ap access point profile`
  is unchanged.
- **The service identity is a fixed project constant, not a per-user value.** The camera
  service always runs as the dedicated `dancam` system user with state under
  `/var/lib/dancam`. A forker does **not** configure this; only the *connection* user is
  per-machine. Decoupling the running service from the SSH login is the whole point.
- The AP-without-PSK design (PSK by hand) is unchanged.
- Git **history** is not rewritten. The proof target is `git grep` over the current
  tracked tree, not the full history (the friend gets history on clone regardless;
  purging it is a separate, out-of-scope operation).

## Changes (one commit)

### 1. Ansible -- inventory becomes a template; playbook ensures the `dancam` service user

- **`raspi/ansible/inventory.ini`** stays tracked and loses all per-user data: delete
  `ansible_user=<user>` and `ansible_ssh_private_key_file=~/.ssh/id_ed25519`, leaving
  only the shared-constant host line `dancam ansible_host=dancam.local`. The login user
  and key now reach Ansible via the `raspi-provision*` recipes' `-e` flags (change 3),
  sourced from `.env` -- so there is no per-user inventory to copy, no
  `inventory.example.ini`, no `git mv`, and no `.gitignore` line. Rewrite the header
  comment to record that the file is now just the shared host constant and that the
  connection identity comes from `.env` via the `raspi-provision*` recipes. No
  `ansible.cfg` change -- it already points at `inventory = inventory.ini`
  (`raspi/ansible/ansible.cfg#[defaults]`), and because the file stays tracked it always
  exists in a fresh clone, so `raspi-provision-lint`/`-check` no longer depend on a copy
  step.
- **`raspi/ansible/site.yml`** -- repoint the video-group task from the login user to
  the fixed `dancam` **service** user, and clear every `<user>` literal in the play:
  - Rename the task `Ensure <user> is in the video group` -> `Ensure the dancam service
    user exists and is in the video group`.
  - Change the module from `ansible.builtin.user: { name: <user>, groups: video,
    append: true }` to create the dedicated user: `name: dancam`, `system: true`,
    `create_home: false` (no home needed -- state lives in `/var/lib/dancam` via the
    unit's `StateDirectory`), `groups: video`, `append: true`.
  - Rewrite the task `#` comment: the `dancam` service user (`User=dancam` on the
    deploy.sh-owned unit) opens the camera under systemd and needs `video` for
    `/dev/video11` (bcm2835-codec / hardware MJPEG) and `/dev/dma_heap/*` (libcamera
    buffers). Note this task is now **load-bearing, not a no-op**: a fresh `dancam`
    system user has no supplementary groups by default (unlike the Imager default user,
    which the old `<user>` task merely re-guaranteed). Keep group membership in the
    playbook (system state -> playbook owns it) rather than `SupplementaryGroups=` on the
    unit, so ADR 09's ownership split stays intact -- we are only swapping the identity.
  - De-`<user>` the file-header comment at the top of the playbook (the "...`<user>`'s video
    group..." ownership-summary line) -> "the `dancam` service user's video group".
  - After this the play has no `<user>` literal. (Connection still uses `ansible_user`, now
    supplied by the `raspi-provision*` recipes via `-e` from `.env` rather than from
    inventory; only the *managed* user is the fixed `dancam`.)

### 2. systemd unit + deploy -- fixed `dancam` service user + StateDirectory (no render)

- **`raspi/dancam.service`**: make the service identity static and self-contained:
  - `User=<user>` -> `User=dancam`.
  - Add `StateDirectory=dancam`. systemd auto-creates `/var/lib/dancam` owned by the
    service user with correct perms on start -- so **no `mkdir`/`install -d` in
    `deploy.sh` and no `StateDirectory`/mkdir task in the playbook**. (`camera.py` still
    self-creates the `rec` subdir under it at startup, as today.)
  - `Environment=DANCAM_REC_DIR=/home/<user>/rec` -> `Environment=DANCAM_REC_DIR=/var/lib/dancam/rec`.
  - Update the adjacent comment to describe the fixed service user + state dir (was
    "dev-image recording directory ... car image later points this at the journaled
    partition"; keep the car-image note, drop the personal path). Update the file-header
    "Hardening (dedicated service user, ...) is a later pass" line: the dedicated service
    user + state dir are now **done**; the remaining hardening (sandboxing, logs off the
    read-only root) stays a later pass.
  - No `<user>`, no `pi`, no per-account anything in the unit. No systemd `%h` (the `%h`
    analysis moves to ADR 11's Alternatives, where the whole login-user-follows approach
    is recorded as rejected).
- **`raspi/deploy.sh`** (`raspi/deploy.sh#HOST`): this shrinks to a pure connection-
  defaults change. **No render step at all** -- the unit ships and installs verbatim
  (`sudo install -m 0644 /tmp/dancam.service /etc/systemd/system/dancam.service` stays
  exactly as-is). Only edits:
  - `HOST="${DANCAM_HOST:-<user>@dancam.local}"` -> default `pi@dancam.local`.
  - `SSH_KEY="${DANCAM_SSH_KEY:-$HOME/.ssh/id_ed25519}"` -> default `id_ed25519`.
  - The two example-override comments near the top (`DANCAM_HOST=<user>@192.168.1.50`,
    `DANCAM_HOST=<user>@10.42.0.1`) -> neutral user (`pi@` / `<user>@`).
  - There is **no** `id -un` / `getent` / `sed` / `.rendered` temp file / extra cleanup
    -- none of that is added. `DANCAM_HOST` stays `user@host` (the connection target).
- **Ordering dependency (note in the README, see change 6):** the unit's `User=dancam`
  requires the `dancam` account to exist, so `just raspi-provision` (which creates it)
  must run before `just raspi-deploy` (which starts the unit). The README already orders
  Provision (sec 3) before Deploy (sec 7), so this is satisfied; the deploy section gets
  a one-line note making the dependency explicit.

### 3. Per-user config via a single `.env` (gitignored) + `.env.example` template

- **New `.env.example`** (tracked) with the three **connection** vars + comments and
  neutral defaults:
  - `DANCAM_HOST=pi@dancam.local` -- `user@host`; the user must match the Imager
    username (it is also what the `raspi-provision*` recipes pass as `ansible_user`).
  - `DANCAM_SSH_KEY=~/.ssh/id_ed25519` -- path to your SSH private key.
  - `DANCAM_HOME_WIFI=preconfigured` -- your home Wi-Fi's NetworkManager connection
    name (find it with `nmcli connection show`; Imager-set Wi-Fi is often
    `preconfigured` on current Pi OS). Used only by the `raspi-ap` safe-flip recipe.
- **`Justfile`**: add `set dotenv-load := true` at the top so every recipe auto-loads
  `.env`.
  - **`raspi-provision` and `raspi-provision-check`**: pass the connection identity to
    Ansible from `.env`, alongside the `-e ansible_host={{host}}` they already pass.
    Derive the login user from `DANCAM_HOST` (strip the `@host`) and the key from
    `DANCAM_SSH_KEY`, both with the same neutral defaults as `deploy.sh` so an
    unconfigured checkout stays inert -- e.g. inside the recipe `HOST="${DANCAM_HOST:-pi@dancam.local}"`,
    then `... -e ansible_user="${HOST%%@*}" -e ansible_ssh_private_key_file="${DANCAM_SSH_KEY:-$HOME/.ssh/id_ed25519}"`.
    `-e` is Ansible's highest-precedence var source, so this cleanly supplies what the
    inventory used to. `raspi-provision-lint` is untouched (it does not connect).
  - **`raspi-ap`**: neutralize the three inline defaults to match `.env.example`
    (`pi@dancam.local`, `id_ed25519`, `preconfigured`).
  - Scrub the standalone `<user>` in the Justfile comments -- the "Prompts once for <user>'s
    sudo password" comment (on `raspi-provision`) -> "your sudo password" -- so the
    broadened proof (Verification) clears the Justfile too, not just its
    `<user>@dancam.local` defaults.
- **`scripts/pi-mem.sh`, `scripts/references-pi-version.sh`**: neutralize their
  `DANCAM_HOST`/`DANCAM_SSH_KEY` defaults the same way. (Both run via `just`, so they
  inherit `.env`.)
- Documented happy path: run via `just` recipes (which load `.env`). Direct
  `./raspi/deploy.sh` invocation needs the vars exported -- note this in the README.

### 4. `.gitignore` -- no change needed (`.env` is already ignored)

The single per-user file, `.env`, is already covered by the existing `# Secrets / local
config` block (`*.local`, `.env`, `secrets/`); `.env.example` stays tracked (it matches
no ignore rule). The pivot to a single `.env` source means there is no longer a
gitignored `inventory.ini` to add -- `inventory.ini` is now a tracked shared constant
(change 1), so `.gitignore` is untouched. Do **not** ignore `plans/`: the `/impl-plan`
-> `/promote-plan` workflow promotes `plans/wip/*` into `plans/impl/*` and `git add`s it
without `--force`, so a `plans/` ignore would break that pipeline (Git stages an ignored
path only with `--force`). The token-bearing `plans/impl/*` records are de-identified in
place instead (change 6), so they stay tracked and grep-clean.

### 5. raspi service -- point the rec-dir fallback default at the fixed state dir

This default is a fallback only (the deployed unit always sets `DANCAM_REC_DIR`; no
test asserts it; the mock backend does not write footage), so it is safe to change. With
the unit now fixed at `/var/lib/dancam/rec`, the code default should **match** it (not a
home path). Replace the literal `/home/<user>/rec` with `/var/lib/dancam/rec` in all three
homes:

- `raspi/service/src/lib.rs#DEFAULT_REC_DIR` (the `const`; `main.rs` and
  `AppState::new()` pick it up). Add a one-line comment: fallback only (used when
  `DANCAM_REC_DIR` is unset); the deployed unit always sets it to `/var/lib/dancam/rec`
  via `StateDirectory=dancam`, and this default now mirrors that exact path.
- `raspi/service/src/camera/mod.rs` -- the `unwrap_or_else(|_| "/home/<user>/rec"...)`
  fallback in `CameraConfig::from_env`.
- `raspi/camera/camera.py` -- the `--rec-dir` argparse default.

### 6. Docs -- a "Configure for your hardware" entry point + scrub personal tokens

- **`README.md`**: add a short **"Configure for your hardware"** section right after
  the intro, before `## 1. Flash`. It is now a single step: `cp .env.example .env` and
  set `DANCAM_HOST` (`user@host` -- the user must match the Raspberry Pi Imager username
  you pick in step 1), `DANCAM_SSH_KEY`, and `DANCAM_HOME_WIFI` (find the Wi-Fi
  connection name with `nmcli connection show`). These are all **connection** values, and
  they flow from this one file to both `deploy.sh` and the `raspi-provision*` recipes --
  the camera service runs as the fixed `dancam` user regardless, nothing to configure
  there. (No separate inventory file to copy or keep in sync: `inventory.ini` is a
  tracked shared constant.) Then scrub inline personal tokens:
  - `<user>@dancam.local` -> `<your-username>@dancam.local`.
  - The deployed-unit prose: drop the rendered-`$HOME/rec` story entirely; the unit now
    flatly records to `/var/lib/dancam/rec` as the `dancam` service user (via
    `StateDirectory=dancam`). Update the `Environment=DANCAM_REC_DIR=/home/<user>/rec`
    example line to `/var/lib/dancam/rec` and `User=<user>` to `User=dancam`.
  - `/home/<user>/rec-smoke` smoke-test paths -> `~/rec-smoke` (the by-hand spike runs as
    your interactive login user; that path is just a scratch dir).
  - `netplan-wlan0-<name>` / `<home-wifi>` -> `$DANCAM_HOME_WIFI` / `<your-home-wifi>`.
  - "`<user>`'s sudo password" -> "your sudo password"; any stray `id_ed25519` ->
    `<your-key>`.
  - **Standalone prose `<user>` the four-token list misses** -- several are live,
    fork-breaking instructions, not passive mentions: the `## 1. Flash` step's "Username
    `<user>`" and "First boot ... it creates `<user>`" -> "Username `<your-username>`" /
    "creates `<your-username>`" (leaving `<user>` here instructs a forker to recreate Dan's
    account -- it defeats forkability, re-leaks the identity, and contradicts the new
    Configure section's "the user must match the Raspberry Pi Imager username").
  - **Reframe the camera-group smoke-test around the `dancam` service user, not the
    login user.** The `## 3. Provision` section's "`<user>`'s `video`-group membership" ->
    "the `dancam` service user's `video`-group membership". In the device-access check:
    the by-hand smoke command runs as "your interactive login user" (Imager's default
    user already has `video`), but the **deployed service runs as `dancam`** under
    systemd -- so the check is on the service user: `id <user>` -> `id dancam`, "`<user>` must
    have group access" -> "`dancam` must have group access", and the `journalctl`
    `ready` check proves the unit (running as `dancam`) can open the camera.
- **`raspi/AGENTS.md`** (live doc -> reflect the *current* state): `ssh <user>@dancam.local`
  (two spots) -> `ssh <your-username>@dancam.local`; the restore-timer example
  `nmcli connection up netplan-wlan0-<name>` -> `$DANCAM_HOME_WIFI`; and the ADR 09
  summary's "`<user>`'s `video` group" -> "the `dancam` service user's `video` group".
- **`docs/roadmap.md`**: in the `loam` swoop's real-Pi regression checklist, change
  `groups <user>` includes `video` -> assert the **`dancam` service user** has `video` /
  the service opens the camera running as `dancam` (the only personal token in the
  roadmap; `git grep` flagged the single line).
- **The ten token-bearing `plans/impl/*.md` records** -- `2026-06-25-1219-pi-wifi-ap-bring-up`,
  `2026-06-25-1711-live-preview-on-iphone`, `2026-06-25-2034-picamera2-camera-owner`,
  `2026-06-26-0917-fetch-references`, `2026-06-26-1015-fern-home-dashboard`,
  `2026-06-26-1214-migrate-pi-setup-to-ansible`, `2026-06-26-1654-lime-swoop-spike`,
  `2026-06-26-1706-preview-watch-conflating-fanout`,
  `2026-06-26-1728-raspi-deploy-ready-notify`, `2026-06-29-1812-live-recording-row`
  -- de-identify the personal tokens in
  place with the placeholder convention (`<your-username>@dancam.local`,
  `/home/<user>/rec`, `<home-wifi>` / `netplan-wlan0-<name>`, `id_ed25519` / `<your-key>`,
  `User=` / `name:` / `groups` of the login user) **plus the standalone prose `<user>`**
  ("as user <user>", "the `<user>` account", "the interactive `<user>`", "`<user>`'s sudo needs a
  password", "never strip <user>'s other groups", etc.). The broadened `\bdan\b` proof
  (Verification) reaches every one of these, so the structured forms alone are not
  enough -- the prose must go too. These are **historical** records redacted for
  publication, not rewritten: keep each record's point-in-time decision intact (they
  describe the login-user-owned rec dir that was true at that swoop); only Dan's
  identifiers become placeholders. The current fixed-`dancam` decision lives in the ADRs
  (append-only), not by editing history. (The grep flagged exactly these ten; the other
  twenty-one tracked plan files carry no tokens and need no edit.) **Leave the app's
  `com.danneu.*` namespace intact:** `2026-06-26-1654-lime-swoop-spike.md` matches the
  proof only via one `\bdan\b` (`/home/<user>/rec` -> `/home/<user>/rec`); its two
  `com.danneu.dancam` / `com.danneu.dancam.loopback` references are the out-of-scope iOS
  app namespace (Out of scope) and stay as-is -- the proof does not match inside `danneu`.
  They stay tracked so the `/promote-plan` pipeline keeps working.
- **`raspi/docs/design/06-2026-06-25-ap-networking-bring-up.md`**: genericize the
  copyable `nmcli connection up netplan-wlan0-<name>` command examples to
  `<your-home-wifi>`, and de-identify the narrative `<home-wifi>` mentions to
  `<home-wifi>`. This is token de-identification, not a decision rewrite, so it respects
  the append-only ADR convention.
- **`raspi/docs/design/09-2026-06-26-pi-system-layer-config-ansible.md`** (append-only:
  de-identify tokens in the body, carry the reshape correction in a dated amendment):
  - Body token de-identification (preserve the original decision, just drop the name):
    `DANCAM_REC_DIR=/home/<user>/rec` -> drop the personal path; the `User=<user>` runtime-check
    mention -> `User=<login user>`; the standalone "`<user>`'s `video`-group membership" ->
    "the login user's `video`-group membership".
  - Add a dated **amendment** note just under the **Status** line (explicit, not a silent
    rewrite): "*Amended 2026-06-30 by ADR 11 (forkable Pi config). Two specifics below
    are superseded: (1) the service no longer runs as the login user -- it runs as a
    dedicated `dancam` system user, so `deploy.sh` does not render or own `User=`/the rec
    dir; the unit statically declares `User=dancam`, `StateDirectory=dancam`, and
    `DANCAM_REC_DIR=/var/lib/dancam/rec`. (2) The "No `StateDirectory`/mkdir task owns the
    rec dir" statement is superseded: the unit now uses `StateDirectory=dancam` (systemd
    creates `/var/lib/dancam`); `camera.py` still self-creates the `rec` subdir. The
    playbook's video-group task now ensures the `dancam` system user exists (was: the
    login user). The system-layer ownership split otherwise stands: the playbook owns
    system state (now incl. the `dancam` user), the unit owns how the service runs (fixed
    user + state dir), `deploy.sh` ships the binary + unit and its de-personalized
    connection defaults.*" Leave the Decision/Consequences prose otherwise intact (the
    amendment header carries the correction, including for the now-stale "deploy.sh is
    untouched" line).
- **New ADR `raspi/docs/design/11-2026-06-30-forkable-pi-config.md`** (next seq is 11;
  date 2026-06-30; owner raspi). One decision: *forkable Pi config -- fixed service user,
  parameterized connection.* Shape per the ADR convention:
  - **Status:** Accepted. **Related:** ADR 09 (the system layer it amends), ADR 06 (the
    AP/PSK secret model it preserves), `07-2026-06-25-picamera2-camera-owner.md` (the
    camera owner whose `video` access the `dancam` user now provides), root `AGENTS.md`
    (the publish-to-GitHub goal + "ideal solution, full stop").
  - **Context:** publishing for forks; the literal `<user>` conflated the per-machine
    *connection* user with the *service* user; per-user values were hardcoded across
    tracked files, so a forker could not run it and the repo shipped personal
    identifiers; secrets must still stay out of the repo.
  - **Decision:** the **service identity is fixed** -- the camera service runs as a
    dedicated `dancam` system user with `StateDirectory=dancam` (`/var/lib/dancam`,
    auto-created by systemd) and `DANCAM_REC_DIR=/var/lib/dancam/rec`, declared
    statically in the unit and fully decoupled from the SSH/login user; the path is the
    deterministic `/var/lib/<StateDirectory>`, so the service does not need to read
    `$STATE_DIRECTORY`. Only **connection** params (login user, SSH key, host, home
    Wi-Fi) are per-user, in a single gitignored `.env` (from `.env.example`), loaded by
    `just` via `set dotenv-load`; `deploy.sh`, the scripts, and the `raspi-provision*`
    recipes all read it (the recipes pass the login user + key to Ansible via `-e`, the
    same idiom as the `-e ansible_host` they already pass). `raspi/ansible/inventory.ini`
    carries no per-user data -- it is a tracked shared-constant host line. The playbook
    ensures the `dancam` system user exists and is in `video`. Shared project constants
    (hostname, AP SSID, gateway) stay hardcoded. Neutral connection fallback defaults
    (`pi@dancam.local`, `id_ed25519`) keep an unconfigured checkout inert rather than
    Dan-specific. Tracked `plans/impl/*` records stay tracked (the `/promote-plan`
    pipeline needs them) and are de-identified in place.
  - **Consequences:** forking = copy one file (`.env`), fill in connection values, run
    via `just`; the service identity needs no configuration, and there is no second
    inventory file to keep in sync. `deploy.sh` ships a **static** unit (no render step --
    simpler than a per-account render). Secrets stay off the repo (PSK by hand per ADR
    06/09; `.env` gitignored, `inventory.ini` carries only the shared host constant). The
    `dancam` user must exist before the unit starts, so provision precedes deploy
    (already the README order). No shipped users, so Dan's dev Pi is reflashed onto the
    new layout rather than migrated in place -- there is no `/home/<user>/rec` footage to
    relocate. ADR 09's "deploy.sh untouched", "unit owns `/home/<user>/rec`", and "no
    `StateDirectory` task" statements are amended.
  - **Alternatives considered:**
    - *Service follows the login user, rendered at deploy from the connected account
      (`id -un` + `getent` home, or systemd `%h`).* **Rejected.** Two reasons: (a) for a
      *system* service systemd `%h` resolves to the service manager's home (`/root`),
      **not** `User=`'s home (systemd.unit(5): the specifier "is not influenced by the
      `User=` setting"), so `%h/rec` would write to `/root/rec`; and more fundamentally
      (b) the goal itself is wrong -- coupling the running service's identity and footage
      ownership to whoever you happened to SSH in as is a forker footgun, adds a
      deploy-time render step, and buys nothing. A service should have its own identity.
    - *`DynamicUser=yes` (transient, systemd-allocated UID).* Considered, not chosen:
      more self-contained/sandboxed, but a transient UID makes footage ownership under
      `StateDirectory` awkward for the README's SSH smoke-tests, where Dan inspects
      `seg_*.ts` files as his login user (systemd remaps the dir to `/var/lib/private/...`
      with a transient owner). A static `dancam` user gives stable, inspectable
      ownership.
    - *A second gitignored `inventory.ini` (from an `inventory.example.ini`) holding
      `ansible_user` + the key.* Rejected: it forces the forker to set the same identity
      in two files and keep them in sync (a desync footgun) and adds a second copy step.
      The provision recipes already pass `-e ansible_host`; passing `-e ansible_user` /
      `-e ansible_ssh_private_key_file` from the single `.env` is the same idiom and
      collapses connection identity to one source, so `inventory.ini` stays a tracked
      shared constant. (This is the pivot away from the original two-example-files shape.)
    - *Committing per-user config.* Rejected: leaks identifiers, un-forkable.
    - *Env-vars with no example file.* Rejected: no discoverability for a forker.

  Write ADR 11 token-clean (generic placeholders only, no `\bdan\b`) so it does not
  itself trip the `git grep` proof.

## Critical files

- New: `.env.example`, `raspi/docs/design/11-2026-06-30-forkable-pi-config.md`.
- Edited: `raspi/ansible/inventory.ini` (drop per-user vars -> shared-constant host line;
  stays tracked), `raspi/ansible/site.yml` (video task -> `dancam` system user),
  `raspi/dancam.service` (`User=dancam` + `StateDirectory=dancam` +
  `/var/lib/dancam/rec`), `raspi/deploy.sh` (connection defaults only -- no render),
  `Justfile` (`set dotenv-load` + provision recipes pass `-e ansible_user`/key from
  `.env`), `scripts/pi-mem.sh`, `scripts/references-pi-version.sh`,
  `raspi/service/src/lib.rs`, `raspi/service/src/camera/mod.rs`,
  `raspi/camera/camera.py`, `README.md`, `raspi/AGENTS.md`, `docs/roadmap.md`,
  `raspi/docs/design/06-2026-06-25-ap-networking-bring-up.md`,
  `raspi/docs/design/09-2026-06-26-pi-system-layer-config-ansible.md`.
- De-identified in place (kept tracked): the ten token-bearing `plans/impl/*.md` records
  listed in change 6.
- Workflow note: this plan is promoted by `impl-plan`, so the promoted copy is also
  de-identified and redacts the exact private tokens. The decision lives in ADR 11 +
  the commit message.
- Unchanged on purpose: `raspi/ansible/ansible.cfg`, the `dancam-ap` task in
  `site.yml`, `raspi/service/src/main.rs` (inherits the const), the `deploy.sh` install
  heredoc (ships the static unit verbatim).

## Commit

One commit, e.g. `refactor(raspi): fix the service user and make Pi setup forkable`.
Body: run the camera service as a dedicated `dancam` system user with
`StateDirectory=dancam` + `DANCAM_REC_DIR=/var/lib/dancam/rec`, decoupling the service
identity from the SSH/login user (the unit is static; `deploy.sh` no longer renders it);
keep only the *connection* user/key/host/Wi-Fi parameterized in a single gitignored
`.env` (seeded from `.env.example`; the `raspi-provision*` recipes pass user/key to
Ansible via `-e`, and `inventory.ini` stays a tracked shared-constant host line); point
the rec-dir code fallback at
`/var/lib/dancam/rec`; de-identify the live docs and the ten token-bearing historical
plan records in place; add ADR 11 (forkable Pi config) and amend ADR 09; add a README
"Configure for your hardware" section.

## After the commit (Dan's one-time local steps)

The dev Pi is treated as **disposable** -- reflash it onto the new layout rather than
migrate stale `/home/<user>` state in place. At this stage there are no shipped users, no
compatibility burden, and no migration-ordering risk to reason about.

1. **Copy off any old footage first, if it matters.** The reflash wipes the card, so pull
   anything worth keeping from the current `/home/<user>/rec` to the Mac (e.g. `rsync`/`scp`)
   before continuing. Skip if the recordings are throwaway.
2. **Reflash the Pi** with Raspberry Pi Imager, setting the generic username + SSH key
   that match the new connection config -- the Imager username must equal `DANCAM_HOST`'s
   user (per the README "Configure for your hardware" section). This
   drops all stale `/home/<user>` state.
3. **Recreate the gitignored `.env` locally** (untracked): `cp .env.example .env`, then
   fill in your real connection values (the `user@host`, key path, and home Wi-Fi
   connection name you actually use). Without it, `just` falls back to the neutral
   defaults and would target `pi@...`. (`inventory.ini` is tracked and needs no copy.)
4. **Provision** so the fixed `dancam` service user and system state are created: `just
   raspi-provision`.
5. **Set the AP PSK by hand** on the Pi (per ADR 06/09 -- the playbook provisions the
   `dancam-ap` profile without its PSK so the secret never enters the repo).
6. **Deploy** so the static unit installs and the service runs as `dancam`: `just
   raspi-deploy`. `StateDirectory=dancam` creates `/var/lib/dancam` and recording lands in
   `/var/lib/dancam/rec`.

## Verification

**Mac-only (no Pi):**
- `just raspi-provision-lint` -- still green; the `dancam` user task (`name: dancam`,
  `system: true`, `create_home: false`, `groups: video`, `append: true`) is valid and
  the play still passes ansible-lint.
- `just raspi-test` -- Rust suite still green after the `DEFAULT_REC_DIR` change (tests
  use temp dirs; none assert the literal).
- `just raspi-mock` comes up and `GET /v1/health` / `GET /v1/status` respond (the
  `/var/lib/dancam/rec` default is inert on the Mac exactly as `/home/<user>/rec` was -- a
  missing rec dir is already tolerated by the status/clips path).
- A **bounded, header-visible `GET /v1/events` smoke** (`curl -siN --max-time 3
  localhost:8080/v1/events`) still serves the live surface after the rec-dir default
  change. Assert: the response headers are `Content-Type: text/event-stream` with
  `x-dancam-proto: 1` and an `x-dancam-boot-id` (the `-i` is what makes these checkable --
  `curl -sN` alone prints only the body); the **first event is a `snapshot`** (match on
  `type`, **not** a fixed `id: 0`); and a later `heartbeat` event arrives with a **greater
  `id`**. The snapshot id is deliberately not pinned: `events.rs#fn events` stamps the first
  frame with `connection.seq` from `event_hub.rs#fn connect`, which is the hub's live
  monotonic seq, and the running mock's heartbeat loop (`spawn_heartbeat`) has already
  advanced it past 0 by the time you curl -- so on a live mock the first frame is a snapshot
  at, say, `id: 4`, then a heartbeat at `id: 5`, never `id: 0`. This surface is unchanged by
  this commit (de-personalization touches no recorder/SSE code); the snapshot-first + proto/
  boot-id contract is pinned by `tests/events.rs#events_stream_starts_with_snapshot_and_proto_headers`
  (which sees `id 0` only because its in-process `oneshot` backend has no heartbeat loop
  ticking the seq), exercised under `just raspi-test`. The smoke just confirms the running
  mock's primary liveness surface (per ADR 10, `recorder-fsm-and-events-sse`) is intact, not
  only the poll routes.
- `just adr-check` -- green: new ADR 11 follows the `{seq}-YYYY-MM-DD-{slug}` convention
  (seq 11 = highest + 1, now that raspi ADR 10 `recorder-fsm-and-events-sse` exists; date
  2026-06-30), and ADR 09's in-place amendment keeps its
  filename.
- **The de-personalization proof (empty over the published Pi-side tree).** Use the
  **`-P` (PCRE) engine**, not `-E`. The promoted plan redacts the exact personal
  token alternations, but the implementation proof uses the concrete local login
  token, private-key token, and home-Wi-Fi token:
  `git grep -nP '<login-token>|<private-key-token>|<home-wifi-token>' -- . ':!app/'`
  returns **nothing** (exit 1) -- *including* the ten now-scrubbed `plans/impl/*`
  records, which are in scope and contribute zero matches. `app/` is the only exclusion.
  This proves exactly the **three personal connection-token classes** are gone (the login
  user, the SSH key, and the home Wi-Fi name); it makes no claim about the string
  `danneu` -- the app's `com.danneu.*` bundle-id/OSLog namespace is out of scope (below).
  Four things this proof encodes, each load-bearing:
  - **`\bdan\b` (case-sensitive) is the primary alternation.** It subsumes every form
    the old four-token list caught (`<user>@`, `/home/<user>`, `User=<user>`, `name: <user>`,
    `groups <user>`) **and** the standalone prose `<user>` those patterns silently missed --
    so the old complementary `ansible_user=<user>|User=<user>|...` grep is now fully redundant
    and is dropped. The key and Wi-Fi names stay as separate alternations because a
    word boundary `\bdan\b` does **not** reach inside `id_ed25519` or
    `<home-wifi>`. Case-sensitivity is deliberate: capital `Dan` (the person, e.g. "Dan
    develops on an M1...") and the brand `dancam` / `DanCam` correctly do **not** match,
    so author and brand references stay intact -- and `dancam` is boundary-safe anyway
    (`\bdan\b` requires a non-word char after `<user>`, but `dancam` has `c`). The new
    `dancam` service user is likewise boundary-safe -- `User=dancam`, `name: dancam`,
    `/var/lib/dancam` all contain no standalone `<user>`.
  - **`-P`, not `-E` -- this is a real trap, not a style choice.** git's `-E`/default
    engine silently does not implement `\b` (verified on this repo: `git grep -E
    '\bdancam\b' -- README.md` matches **zero** lines although README is full of
    `dancam`; `-P` matches). An `-E` proof would pass **vacuously** while every survivor
    remains. The proof MUST be `-P` -- it is the only engine that actually evaluates
    `\b` here.
  - **`':!app/'` excludes the out-of-scope iOS app.** Its UITests carry two Xcode
    `// Created by <user>` author-stamps; the app is explicitly out of scope and not Pi
    config, so the Pi-side proof excludes `app/` rather than touch it.
  - **`com.danneu.*` is intentionally a non-target, not a survivor the proof misses.**
    `\bdan\b` cannot match inside `danneu` (a word char follows `<user>`), and `danneu` is
    not one of the alternations -- by design. `com.danneu.dancam` is the iOS app's bundle
    id / OSLog subsystem (`PRODUCT_BUNDLE_IDENTIFIER = com.danneu.DanCam`), pervasive under
    `app/` and excluded with the rest of the Xcode signing/bundle id. The two
    `plans/impl/2026-06-26-1654-lime-swoop-spike.md` references to it describe app
    internals and stay intact (change 6); scrubbing them would pull the app's bundle id
    into a commit that excludes it. So the proof's guarantee is scoped to the three
    connection-token classes -- it does **not** assert `danneu` is absent, and that is the
    honest claim, not a gap.

  The `.env.example` (neutral defaults like `pi@dancam.local`, `id_ed25519`) and the
  de-identified docs (placeholders like `<your-username>`, `<home-wifi>`) use forms that
  do not match the concrete personal-token proof. Outside `app/`, every standalone login
  token in the tracked tree is a personal-identifier reference this change scrubs, so the
  proof reaches genuinely empty. This promoted plan redacts the exact private token names
  so the workflow artifact can be tracked without reintroducing them.
- `git check-ignore .env` matches; `git check-ignore raspi/ansible/inventory.ini` does
  **not** (it stays tracked); `git ls-files raspi/ansible/` shows `inventory.ini` (now
  just the shared-constant host line) and no `inventory.example.ini`; `git ls-files plans/`
  lists the historical records plus this promoted implementation plan, and the ten scrubbed
  historical records now grep clean.

**On the Pi (Dan's own, proving the fixed-service-user path works):**
- `just raspi-provision` converges and a re-run is idempotent (`changed=0`); the `dancam`
  system user now exists and `id dancam` / `groups dancam` includes `video`. Confirm on
  Trixie that `video` alone covers **both** `/dev/video11` and `/dev/dma_heap/*`, and
  that systemd grants the service that supplementary group from the system group DB for
  `User=dancam` (the same mechanism ADR 09 relied on for `<user>`; the existing plan records
  treat `video` as sufficient).
- `just raspi-deploy` installs the **static** unit (no render step to check):
  `ssh ... systemctl show dancam -p User,Environment` shows `User=dancam` (static, not
  resolved from the login user) and `DANCAM_REC_DIR=/var/lib/dancam/rec`;
  `ssh ... systemctl show dancam -p StateDirectory` shows `dancam`, and
  `ssh ... stat -c '%U' /var/lib/dancam` shows `dancam` (systemd auto-created it). The
  service starts, emits `ready` in `journalctl -u dancam` (it opened the camera running
  as `dancam`), `GET /v1/health` is OK, and recording writes segments under
  `/var/lib/dancam/rec`.
- `just raspi-ap` arms and flips using `$DANCAM_HOME_WIFI` from his `.env`.

## Implementation notes

- The promoted plan is de-identified too, with the exact private token names redacted, so
  the `impl-plan` workflow can commit it without reintroducing the identifiers this change
  removes.
- Scripts and Just recipes expand a leading `~` in `DANCAM_SSH_KEY` after dotenv loading,
  because shell tilde expansion does not happen inside an already-populated variable.
