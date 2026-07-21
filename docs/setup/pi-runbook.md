# Raspberry Pi setup

## Flash a card

Card creation does not use Raspberry Pi Imager, live partitioning, or a manual
network bootstrap. On the Apple Silicon Mac, choose the profile explicitly:

```sh
just raspi-flash production                 # newest signed release under dist/
just raspi-flash production path/to/image.img.zst.manifest.json
just raspi-flash dev                        # fresh image from tracked worktree content
```

Bare and unknown profiles fail before building or inspecting removable media.
Production authenticates the supplied or lexically newest release. Development first
validates `.env`, derives the authorized public key from `DANCAM_SSH_KEY`, and builds
a fresh generic writable image from current staged and unstaged tracked content in
the controlled OrbStack builder. Untracked files are excluded.

Both paths list eligible removable whole disks and do not mutate one until the
displayed identifier is typed exactly. They write and verify the complete image, add
an image-bound per-card envelope, remount and verify personalization, and eject the
card. Production also creates the setup QR and recovery record in the current
directory. The
writer holds an exclusive macOS Disk Arbitration claim from image transfer through
readback so the FAT boot volume cannot be auto-mounted and changed between those
phases. If a run is interrupted after the complete image write,
`just raspi-flash-resume production [manifest]` compares every authenticated image
chunk with the card,
repairs and rereads up to 64 MiB of differing chunks, and refuses larger recovery.
Development cannot resume: rerun `just raspi-flash dev` for a fresh build and full
write.

Move the ejected card to the Zero 2 W and power it with upstream networking absent.
In the app, open Settings -> Add Camera and scan the generated QR. Setup status moves
from Preparing to Ready from canonical Pi state. A failure shows a stable recovery
reason; the activity LED blinks slowly while preparing, stays mostly lit when
complete, and blinks rapidly on failure. Do not reinsert or edit a successfully
commissioned card to retry setup; whole-card reflash is the recovery operation and
destroys Pi-local footage and identity.

The production image preserves the base DOS disk identifier so the kernel root
`PARTUUID` continues to resolve after partition-table assembly, and it boots with the
`US` Wi-Fi regulatory domain used by the channel-1 production access point. Its raw
artifact is 5,511,315,456 bytes (5,256 MiB) for the current pinned base: 512 MiB boot,
4 GiB root, 512 MiB persist, and 128 MiB initial data. Flashing writes and reads back
all 5,256 authenticated MiB. On first boot, commissioning grows only data to the
aligned 95% card boundary; root and persist retain their release sizes.

For development, move the ejected card to the Pi and allow first boot to create the
configured login, SSH host keys, `dancam-home` client, `dancam-ap` hotspot, machine
identity, expanded data filesystem, and storage generation. Commissioning removes
the consumed envelope and returns the Pi on home Wi-Fi. Use a whole-card reflash after
a durable commissioning failure.

Release publishers run `just raspi-image` on the Apple Silicon Mac with the protected
minisign secret key at `secrets/image-release.key`, or override that checkout-local path
with `DANCAM_IMAGE_SIGNING_KEY`. The task creates or reuses a dedicated 64 GB ARM64
NixOS OrbStack machine named `dancam-builder`, runs the controlled Linux build there,
and writes the release artifacts back to the Mac checkout under `dist/`. Override the
machine name with `DANCAM_IMAGE_BUILDER_MACHINE` when needed. The build refuses
uncommitted tracked source, verifies the pinned OS digest, converges the mounted image
through the offline Ansible profile twice, then converges Ansible-owned release cleanup
twice. Each second pass must report `changed=0`. Cleanup removes downloaded package
archives and apt repository lists but retains installed-package records. Independent
inspection then requires those payload areas to be empty and at least 1 GiB available
on root to non-root callers before the build can emit the installed-package inventory,
compressed image, manifest, or signature. Flash operators receive only those release
artifacts and trust the public key tracked at `raspi/image/release.pub`.
Automatic release versions contain UTC date and time through seconds, the repository
revision, and a four-digit collision discriminator. Concurrent builds atomically claim
different ordered basenames, and compact versions sort after legacy same-day releases,
so the no-argument flash command selects the newest. Publishers may set
`DANCAM_IMAGE_VERSION` for an explicit version; unsafe names and any version with an
existing claim or output fail instead of replacing files.

Hands-on runbook for bringing up the dancam camera unit -- from flashing the microSD
through serving canonical operational status. These are the concrete steps we ran for the
`pine` swoop. For the design rationale behind each choice, see
[`AGENTS.md`](../overview.md); this file is just the commands.

Hardware: [Raspberry Pi Zero 2 W](https://www.raspberrypi.com/products/raspberry-pi-zero-2-w/) + [Arducam IMX708 Autofocus Wide](https://www.amazon.com/dp/B0C5D97DRJ), ribbon attached.

OS: Raspberry Pi OS Lite (64-bit), Trixie.

Command context: Mac-side commands that use repo-relative paths (`just ...`,
`cp .env.example .env`, `ffmpeg ... raspi/service/assets/...`) run from the repo
root on the Mac. Pi-side commands (`rpicam-*`, `nmcli`, `systemctl`,
`journalctl`, and the `camera.py` smoke test) run on the Pi over
SSH.

## Configure for your hardware

Create the gitignored local config file once, then run the Pi recipes through
`just` so they load it automatically:

```sh
cp .env.example .env
```

Edit `.env`:

- `DANCAM_HOST=<your-username>@dancam.local` -- first boot creates this key-only
  login. When mDNS is flaky, retain the user and use the Pi's raw LAN IP after boot.
- `DANCAM_SSH_KEY=~/.ssh/id_ed25519` -- flashing derives and installs its public key.
- `DANCAM_HOME_WIFI_SSID` and `DANCAM_HOME_WIFI_PSK` -- the home network stored in
  the fixed `dancam-home` profile.
- `DANCAM_DEV_AP_PSK` -- the WPA2 password stored in the fixed `dancam-ap` profile.

These are connection settings only. The camera service always runs as the fixed
`dancam` system user and records under `/data/rec`; there is no service user to
configure. `raspi/ansible/inventory.ini` is tracked and contains only the shared
`dancam.local` host constant.

Direct `./raspi/deploy.sh` runs do not auto-load `.env`; either use
`just raspi-deploy` or export the same variables in your shell first.

## Connect to a development card

From the Mac over the home LAN (mDNS). `-i` points at the **private** key -- the
key configured by `DANCAM_SSH_KEY` (omit `-i` if it has a default name):

```sh
ssh -i ~/.ssh/<your-key> <your-username>@dancam.local
```

Confirm it came up as the 64-bit Trixie kernel (`aarch64` / `v8` = 64-bit):

```sh
uname -a
```

## Provision the system layer (Ansible)

The Pi's onboard system state -- apt upgrade, the IMX708 camera overlay, the camera
process dependencies (`python3-picamera2`, `python3-av`, plus `ffmpeg` as a media
validator), mDNS scoping, the
`en_US.UTF-8` locale, the commissioned `dancam-ap` access-point profile,
the `dancam` service user's `video`-group membership, `/persist` and `/data` mounts,
persistent journald backed by `/persist/journal`, recording-namespace ownership,
the tracked service unit and camera process, kernel
writeback clamps, weekly `fstrim.timer`, and the on-board hardware watchdog -- is
provisioned declaratively with Ansible. The development entry playbook and its roles
(`raspi/ansible/development.yml`) are the source of truth for that state; the *why* behind each
choice lives in its task comments (see also the
[provisioning design](../design/pi/provisioning.md)). A generated card already has
this state and can go directly to deploy. Re-run live provisioning only for drift
repair, from the repo root **over home Wi-Fi** -- it needs internet for apt, and the
Pi's AP has no upstream:

```sh
just raspi-provision          # converge the Pi; reboots itself if a task needs it
```

Cards created by the development image commissioner use passwordless sudo and do not
prompt. For a legacy manually created card that still requires a become password,
set `DANCAM_ASK_BECOME_PASS=1`. When mDNS is flaky, target a raw LAN IP:
`just raspi-provision host=192.168.1.50`.

Preview what would change without touching the Pi (the drift detector), or lint the
playbook on the Mac with no Pi connection:

```sh
just raspi-provision-check    # --check --diff: shows pending changes, makes none
just raspi-provision-lint     # --syntax-check + ansible-lint, hardware-free
```

Re-running is idempotent: a converged Pi reports `changed=0` and does not reboot. The
playbook fails fast on legacy cards that do not expose
`/dev/disk/by-label/dancam-data`; create a new card with `just raspi-flash dev`.
The playbook preserves the commissioned AP password, so the secret never enters the
repository or Ansible inputs.

Two of these -- persistent journald and the hardware watchdog -- are the freeze-
recovery layer from the
[OS image design](../design/pi/os-image.md#freeze-recovery-and-persistent-logs).
The watchdog drop-in reboots on first apply (arming needs a boot), so verify **after**
the converge reboot. The *effective* value of a journald key is its **last**
uncommented assignment across all drop-ins, so assert that with `tail -n1` rather than
mere presence -- a later-sorting drop-in could otherwise override ours (the `60-`
filename prefix is what stops it; this check confirms it held):

```sh
ssh dancam.local "systemd-analyze cat-config systemd/journald.conf | grep -E '^Storage *=' | tail -n1"          # Storage=persistent
ssh dancam.local "systemd-analyze cat-config systemd/journald.conf | grep -E '^SystemMaxUse *=' | tail -n1"     # SystemMaxUse=200M
ssh dancam.local "systemd-analyze cat-config systemd/journald.conf | grep -E '^SyncIntervalSec *=' | tail -n1"  # SyncIntervalSec=60s
ssh dancam.local journalctl --list-boots                        # >= 2 boots after a reboot: previous boot retained
```

Confirm the storage layout and maintenance timers landed:

```sh
ssh dancam.local 'findmnt /persist && findmnt /data && findmnt /var/log/journal'
ssh dancam.local 'ls -ld /data/rec /persist/journal'
ssh dancam.local 'systemctl is-enabled fstrim.timer'       # enabled
ssh dancam.local 'sysctl vm.dirty_background_bytes vm.dirty_bytes'
```

Confirm the watchdog is actually armed. `journalctl -b _PID=1` carries systemd's
arming line only after the `/dev/watchdog0` ioctl succeeds, and the `1min` value (a
clamp would read ~16s) shows the 60s logical timeout was accepted; `systemctl show`
reports only the *configured* value, so it is a landed-config check, not arming proof:

```sh
ssh dancam.local 'journalctl -b _PID=1 | grep -i watchdog'   # "Watchdog running with a hardware timeout of 1min." (the arming proof)
ssh dancam.local 'journalctl -b -k | grep -i watchdog'       # the bcm2835-wdt driver line (module present)
ssh dancam.local systemctl show -p RuntimeWatchdogUSec       # RuntimeWatchdogUSec=1min (config landed)
```

A watchdog reboot recovers the *service*, not the recording: the recorder comes back
`idle` and records again only when the app re-issues `/v1/recording/start`
(auto-record-on-boot does not yet exist), so a post-boot
`curl -s http://dancam.local:8080/v1/status` showing `recorder.phase` `idle` is
expected, not a failure.

## Enable the camera (IMX708)

Provisioning turned off `camera_auto_detect` and loaded the in-kernel
`dtoverlay=imx708` in `/boot/firmware/config.txt`, then rebooted to apply it (the why
-- not an official module, in-kernel overlay survives `apt upgrade` unlike Arducam's
prebuilt-driver script -- lives in the playbook task comments). SSH back in and
smoke-test capture:

```sh
rpicam-hello --list-cameras              # should list: 0 : imx708 [4608x2592 ...]
rpicam-jpeg -n -o /tmp/test.jpg -t 2000  # -n = no preview window (headless)
ls -lh /tmp/test.jpg                      # a real ~1-2 MB JPEG => capture works
```

Optionally pull the image to the Mac to eyeball focus/orientation:

```sh
# run on the Mac
scp -i ~/.ssh/<your-key> <your-username>@dancam.local:/tmp/test.jpg ~/Desktop/dancam-test.jpg
```

## Verify the camera process dependencies

The production camera owner is a Python Picamera2 subprocess supervised by the Rust
service. Provisioning installed Picamera2 and PyAV from apt, not pip, so
they match the Raspberry Pi OS libcamera/libav stack and omit desktop GUI recommends.
Confirm the exact deployed interpreter initializes both dependencies -- the camera
camera overlay must already be enabled before the camera open path is useful:

```sh
python3 -c "import av; from picamera2 import Picamera2; av.Packet(b''); print('ok')"
sudo -u dancam python3 -c "import av; from picamera2 import Picamera2; av.Packet(b''); print('ok')"
```

## Switch a development card to its access point

First boot creates `dancam-ap` with SSID `dancam-dev`, the configured WPA2 password,
channel 1, gateway `10.42.0.1`, and autoconnect disabled. From the Mac while the Pi is
still on home Wi-Fi, `just raspi-ap [minutes]` (default 5) arms a systemd-owned return
to fixed profile `dancam-home`, then schedules the AP-up as a detached transient unit
about 2 seconds later. The SSH session returns
cleanly before Wi-Fi drops instead of dying mid-command. The countdown runs on the Mac
(which can no longer see the Pi once the AP is up), so it is a local estimate of the
armed duration, not a probe of the Pi. Generated cards use the fixed `dancam-home`
return profile. Override the target/key with `DANCAM_HOST` and `DANCAM_SSH_KEY`;
legacy cards with another home profile can also set `DANCAM_HOME_WIFI`.

When the timer fires, inspect it with:

```sh
journalctl -b -u dancam-restore-home-wifi.service -u dancam-restore-home-wifi.timer
```

Power cycling also returns this dev image to home Wi-Fi because `dancam-ap` does
not autoconnect. Do not join `dancam-dev` from the Mac during an active remote
LLM session if the Mac's only internet path is your home Wi-Fi; use the iPhone for
AP testing.

## Deploy and run the service

Cross-compile and deploy from the Mac in one command (Nix flake + `deploy.sh`;
details in [`AGENTS.md`](../design/pi/service.md) "Rust dev loop"). From the repo
root:

```sh
just raspi-deploy   # wraps ./raspi/deploy.sh
```

Generated cards already contain the fixed `dancam` service user and tracked unit.
Legacy cards must be provisioned before deploy starts the service.

This ships a static aarch64 binary and the camera process
(`/usr/local/lib/dancam/camera.py`), restarts the Ansible-installed
`dancam.service`, then waits in two phases over `/v1/status`. Unit changes require a
provisioning run. Phase 1
waits up to `DANCAM_STATUS_TIMEOUT` (default 60 seconds) for a valid JSON boolean at
`recording_readiness.ready`. Phase 2 immediately evaluates that same response, then
polls until the boolean is true, bounded by `DANCAM_RECORDING_READINESS_TIMEOUT`
(defaulting to `DANCAM_STATUS_TIMEOUT`). Only then does deploy print success and fire
the recording-ready macOS notification.

During phase 2, deploy retains the last full valid status response. If recording
readiness times out, it prints that response without fetching status again, then runs
separately bounded best-effort diagnostics for the service environment, `/data`
mount, `/data` space, and the last 50 service log entries. A stalled or failed
diagnostic does not prevent the later diagnostics from running or replace the primary
readiness failure. The deployed unit sets:

```ini
Environment=DANCAM_BIND=[::]:8080
Environment=DANCAM_BACKEND=camera
Environment=DANCAM_REC_DIR=/data/rec
Environment=DANCAM_REQUIRE_REC_MOUNT=/data
User=dancam
```

`DANCAM_BACKEND=camera` makes the service spawn one long-lived Picamera2 owner
process. That process owns libcamera, emits low-res MJPEG preview on stdout, and
writes H.264 MPEG-TS recording segments under `/data/rec` as the fixed `dancam`
service user. `DANCAM_REQUIRE_REC_MOUNT=/data` makes recording and time-sync writes
fail closed if `/data` is not mounted; status and preview still come up for
diagnosis. The camera process also locks the IMX708 lens to infinity with autofocus
disabled; see the [recording design](../design/pi/recording.md#focus-policy).
Local `just raspi-mock`
still defaults to the mock backend and cycles committed test-pattern frames.

On a car image, `deploy.sh` temporarily remounts `/` read-write for the install block
and remounts it read-only again before exiting. That path is for bench updates only;
normal car runtime keeps root read-only.

For app development against the local mock Pi, run:

```sh
just raspi-mock
```

The recipe binds `127.0.0.1:8080` and sets a writable mock recording directory
(`DANCAM_REC_DIR=.mock-rec`, under `raspi/service/`) plus
`DANCAM_MOCK_SEGMENT_SECS=5`, so tapping Record in the app creates gitignored mock
segments and rolls them quickly enough to watch the live row settle into the Recent
clips list. The mock bytes are not real TS, so finished mock rows may show bytes
without a duration; `just raspi-mock-clips` still points at the committed
`assets/clips` fixture when you need a real finished sample clip.

Ring GC keeps 2 GiB available by default. Set `DANCAM_GC_FLOOR_BYTES=0` to
disable it. To watch GC operate against the mock recorder, run:

```sh
just raspi-mock-gc
```

This recipe pre-creates `.mock-rec` so the startup space probe has a real path,
then sets the floor to an intentionally impossible value above the Mac's
available space. The empty ring first triggers the exhausted warning and a
~30 s backoff. Once recording starts, finished 5 s segments are evicted in
~30 s bursts as each retry handles the accumulated backlog; stopping recording
lets the final open segment become evictable on the next retry. This bursty
cadence is an artifact of the impossible dev floor, not the steady
one-in-one-out drip produced by a realistic floor.

Verify from the Mac over the LAN:

```sh
curl -i http://dancam.local:8080/v1/status   # expect: 200 OK + x-dancam-proto: 1
curl -s http://dancam.local:8080/v1/status | jq .temp_c.sensor  # real IMX708 reading
```

Smoke-test live preview from the Mac:

```sh
curl -i --max-time 2 http://dancam.local:8080/v1/preview/live.mjpeg
```

Expected headers include:

```text
HTTP/1.1 200 OK
content-type: multipart/x-mixed-replace; boundary=dancamframe
cache-control: no-store
x-dancam-proto: 1
```

The stream is unbounded, so `curl --max-time 2` exits by timeout after proving the
headers. To eyeball the real camera feed, open the same URL in a browser or run:

```sh
ffplay http://dancam.local:8080/v1/preview/live.mjpeg
```

Smoke-test the committed transaction through the real Rust service before trusting a
longer run. Each start must return only after the first independently decodable access
unit is durable; `time_total` must remain below 1 second:

```sh
curl -sS -o /dev/null -w 'cold start: %{time_total}s\n' \
  -H 'Content-Type: application/json' -H 'Idempotency-Key: smoke-start-1' \
  -X POST http://127.0.0.1:8080/v1/recording/start
sleep 35
curl -fsS -o /dev/null \
  -H 'Content-Type: application/json' -H 'Idempotency-Key: smoke-stop-1' \
  -X POST http://127.0.0.1:8080/v1/recording/stop
curl -sS -o /dev/null -w 'warm start: %{time_total}s\n' \
  -H 'Content-Type: application/json' -H 'Idempotency-Key: smoke-start-2' \
  -X POST http://127.0.0.1:8080/v1/recording/start
sleep 5
curl -fsS -o /dev/null \
  -H 'Content-Type: application/json' -H 'Idempotency-Key: smoke-stop-2' \
  -X POST http://127.0.0.1:8080/v1/recording/stop
curl -fsS http://127.0.0.1:8080/v1/clips
test -z "$(find /data/rec -maxdepth 1 -type f -name '.dancam-seg_*' -print -quit)"
FIRST_SEGMENT="$(find /data/rec -maxdepth 1 -type f -name 'seg_*.ts' | sort | head -n1)"
ffmpeg -v error -i "$FIRST_SEGMENT" -f null -
```

For the real `jet` gate, run a longer room-temperature and warm soak, inspect CPU,
free memory/swap activity, SoC and sensor temperatures, preview smoothness, and
verify the second start/stop cycle continues segment numbering instead of
overwriting the first session.

The smoke command runs as your interactive login user, but deployment runs as the
fixed `dancam` service user under systemd with no login session. Verify the
service user can open the camera:

```sh
id dancam
ls -l /dev/video11 /dev/dma_heap/* 2>/dev/null
sudo systemctl restart dancam
journalctl -u dancam -n 80 --no-pager | grep '"ready"'
```

`dancam` must have group access to `/dev/video11` for hardware MJPEG and
`/dev/dma_heap/*` for libcamera buffers. The journal check proves the systemd
context, not just an interactive shell, can start the camera process.

To regenerate the local mock preview frames later, run from the repo root:

```sh
ffmpeg -y -f lavfi -i testsrc=size=640x480:rate=10 -frames:v 12 -q:v 8 -pix_fmt yuvj420p -start_number 0 raspi/service/assets/preview/frame_%02d.jpg
```

Service management on the Pi:

```sh
systemctl status dancam        # running? enabled for boot?
journalctl -u dancam -f        # live logs
```

The deployed unit uses `KillMode=mixed` and `TimeoutStopSec=10`. SIGTERM reaches
the Rust owner first; a normal stop must finalize the camera and exit 0, leaving
`inactive (dead)`. The 10 second cgroup SIGKILL is only the final bound for a
wedged process or uninterruptible filesystem operation.

Verify the shutdown acceptance path on the real Pi after changing lifecycle,
camera, HTTP streaming, or unit behavior. Start recording, open the app so SSE and
preview are connected, and also hold one unread response. Then stop the service and
check that it finishes in under 6 seconds, does not initialize libcamera again,
leaves the unit inactive rather than failed, closes all clients, and preserves a
playable final segment:

```sh
curl -sS http://dancam.local:8080/v1/events >/dev/null &
EVENTS_PID=$!
curl -sS http://dancam.local:8080/v1/preview/live.mjpeg >/dev/null &
PREVIEW_PID=$!
python3 -c 'import socket,time; s=socket.create_connection(("dancam.local",8080)); s.sendall(b"GET /v1/preview/live.mjpeg HTTP/1.1\r\nHost: dancam.local:8080\r\n\r\n"); time.sleep(15)' &
UNREAD_PID=$!
ssh dancam.local 'sudo systemd-run --wait --pipe /usr/bin/time -f %e systemctl stop dancam'
wait "$EVENTS_PID" "$PREVIEW_PID" "$UNREAD_PID" || true
ssh dancam.local 'systemctl is-failed dancam; systemctl status dancam --no-pager'
ssh dancam.local 'journalctl -u dancam -n 120 --no-pager | grep -E "shutdown|Camera|libcamera"'
ssh dancam.local 'LAST=$(find /data/rec -maxdepth 1 -type f -name "seg_*.ts" | sort | tail -n1); test -n "$LAST" && ffmpeg -v error -i "$LAST" -f null -'
```

`systemctl is-failed` should print `inactive`, elapsed time must be `< 6`, and the
final ffmpeg command must be silent and successful. Restart with
`ssh dancam.local 'sudo systemctl start dancam'` after the check.

From the Mac, fetch recent service logs or follow them live over SSH:

```sh
ssh dancam.local 'journalctl -u dancam -n 200 --no-pager'
ssh dancam.local 'journalctl -u dancam -f'
```

Request/response access lines appear in `journalctl -u dancam -f` with an
`x-request-id`; grep the journal for that id to correlate a Pi request. Pi-generated
ids are a per-process counter (`1`, `2`, `3`, ...) that resets on each service start,
so a blind grep of a captured generated id is scoped to one service run, not the whole
persistent journal. Use time proximity plus the neighboring reset marker, or narrow to
one systemd invocation with
`journalctl _SYSTEMD_INVOCATION_ID=$(systemctl show -p InvocationID --value dancam)`.
`journalctl -b` narrows to one boot but not to one service run inside that boot. To
raise service verbosity without rebuilding, add `Environment=RUST_LOG=dancam=debug`
with `sudo systemctl edit dancam`, then restart `dancam`; DEBUG includes emitted SSE
events with `seq` and body, and TRACE adds heartbeats.

Reset recorded footage: to clear all recordings from the Pi -- after a filename-format
change, or just to reclaim the card -- use `just raspi-reset-data`. It stops `dancam`,
deletes everything under `/data/rec` (segments plus the witness/time state, so the next
run mints a new storage generation and restarts at seq 0 / session 1), then restarts
the service and waits for
`/v1/status.recording_readiness.ready == true`. Override the 60 second wait with
`DANCAM_RECORDING_READINESS_TIMEOUT`. It refuses to run unless `/data` is a mounted filesystem, and it always
attempts to restart `dancam` even if the wipe or the run is interrupted -- failing loudly
(non-zero, "recording is DOWN") if the service does not become recording-ready,
so a failed or interrupted reset is never mistaken for a clean one. It previews what will
be deleted and prompts first; set `DANCAM_YES=1` to skip the prompt.

```sh
just raspi-reset-data                 # prompts before wiping /data/rec
DANCAM_YES=1 just raspi-reset-data    # unattended
```

Use this reset as the clean-break operation after an incompatible recording-format
change. The service does not migrate old footage during listing; recognized
durationless recovery files remain pullable with unknown duration, while unrecognized
names are ignored. Resetting also clears the sequence witness and time anchors. The
new generation prevents prior phone caches and interrupted media demand from matching
the reset namespace even when sequence and byte counts repeat.

For an A/B picture comparison, `just raspi-hdr on` enables the IMX708's on-sensor
HDR and `just raspi-hdr off` disables it. The command stops `dancam` because the
sensor accepts `wide_dynamic_range` changes only while the camera is closed, writes
the control on the sensor subdevice, restarts the service, and waits until
`/v1/status.recording_readiness.ready` is true. The wait uses
`DANCAM_RECORDING_READINESS_TIMEOUT` (default 60 seconds). HDR caps the sensor mode at
2304x1296@30, which still covers the 1080p30 recording ceiling. The setting resets
to off when the Pi reboots.

## Smoke-test the AP path

With the service deployed, arm the home-Wi-Fi restore timer, flip the AP up, join
`dancam-dev` from the iPhone, and fetch:

```text
http://dancam.local:8080/v1/status
```

The expected response is the canonical status snapshot. The iPhone app targets
`http://dancam.local:8080` on both development and production APs. The fixed
`http://10.42.0.1:8080` gateway remains available for operator diagnostics; on a
production card, requiring it because `dancam.local` does not resolve is an image
defect.

For app testing from Xcode, install/run the app on the iPhone while the phone is still
on the home Wi-Fi network, then switch only the iPhone to `dancam-dev`. Leave the
shared scheme without a `DANCAM_PIN_WIFI` override for the real AP path: the default
`http://dancam.local:8080` base URL derives to Wi-Fi pinning for events and preview.
Use `DANCAM_PIN_WIFI=0` only for an explicit unpinned diagnostic pass.

The app target also carries `NSAppTransportSecurity` / `NSAllowsLocalNetworking` so
the clip viewer can serve progressive playback fragments over cleartext loopback HLS.
This is app bundle configuration; it does not require Pi provisioning or a router
change.

In the app, verify that the event stream connects, then open Live preview and confirm
that the camera feed is moving. Stop then Start should resume the stream.
In the 2026-06-25 `fox` spike, this worked over `dancam-dev` with cellular left on; no
captive sheet was observed.

## Build a production release

Do not convert a writable development card into production posture. Production cards
come only from `just raspi-image` followed by `just raspi-flash production`. The
signed image owns read-only root and boot, persistent state,
offline commissioning, and the production AP; development cards remain writable.
The image already contains the `dancam`-owned recording namespace. Commissioning
validates it, grows p4, mints the storage generation and per-card identity, and admits
`/data`; it does not repair packages, accounts, service configuration, or ownership.
