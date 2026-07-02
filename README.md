# Raspberry Pi setup

Hands-on runbook for bringing up the dancam camera unit -- from flashing the microSD
through serving the health endpoint. These are the concrete steps we ran for the
`pine` swoop. For the design rationale behind each choice, see
[`raspi/AGENTS.md`](raspi/AGENTS.md); this file is just the commands.

Hardware: [Raspberry Pi Zero 2 W](https://www.raspberrypi.com/products/raspberry-pi-zero-2-w/) + [Arducam IMX708 Autofocus Wide](https://www.amazon.com/dp/B0C5D97DRJ), ribbon attached.

OS: Raspberry Pi OS Lite (64-bit) was at release 2026-06-18 as of writing this.

## Configure for your hardware

Create the gitignored local config file once, then run the Pi recipes through
`just` so they load it automatically:

```sh
cp .env.example .env
```

Edit `.env`:

- `DANCAM_HOST=<your-username>@dancam.local` -- the user must match the Raspberry Pi
  Imager username you pick in section 1. When mDNS is flaky, keep the same user and
  replace the host with the Pi's raw LAN IP.
- `DANCAM_SSH_KEY=~/.ssh/id_ed25519` -- the private key whose `.pub` counterpart you
  add in Imager.
- `DANCAM_HOME_WIFI=<your-home-wifi>` -- the Pi's NetworkManager home-Wi-Fi
  connection name, found on the Pi with `nmcli connection show`. Current Raspberry
  Pi OS images often name the Imager-created profile `preconfigured`.

These are connection settings only. The camera service always runs as the fixed
`dancam` system user and records under `/var/lib/dancam/rec`; there is no service
user to configure. `raspi/ansible/inventory.ini` is tracked and contains only the
shared `dancam.local` host constant.

Direct `./raspi/deploy.sh` runs do not auto-load `.env`; either use
`just raspi-deploy` or export the same variables in your shell first.

## 1. Flash Raspberry Pi OS Lite

Flash the microSD with **Raspberry Pi Imager 2.0.10 or newer** (older Imager can't
customize Trixie -- 1.9.x writes the wrong format and 2.0.6-2.0.8 can leave SSH off):

1. **Choose OS:** `Raspberry Pi OS (other)` -> `Raspberry Pi OS Lite (64-bit)`.
2. **Choose storage:** the microSD.
3. **Edit Settings** (the OS-customization step) and set:
   - Hostname: `dancam`
   - Username `<your-username>` + a password
   - Enable SSH -> "Allow public-key authentication only", and add your
     `~/.ssh/<your-key>.pub`
   - Configure wireless LAN: your home Wi-Fi SSID + password (so it joins headless)
4. Write the card, insert it in the Pi, and power on (the `PWR` micro-USB
   port). First boot runs cloud-init -- it creates `<your-username>`, installs your
   key, joins Wi-Fi, and sets the hostname, then reboots once. Give it ~60-90s.

## 2. SSH in

From the Mac over the home LAN (mDNS). `-i` points at the **private** key -- the
counterpart of the `.pub` you added when flashing (omit `-i` if it's a default name
like `id_ed25519`):

```sh
ssh -i ~/.ssh/<your-key> <your-username>@dancam.local
```

Confirm it came up as the 64-bit Trixie kernel (`aarch64` / `v8` = 64-bit):

```sh
uname -a
```

## 3. Provision the system layer (Ansible)

The Pi's onboard system state -- apt upgrade, the IMX708 camera overlay, the camera
process dependencies (`python3-picamera2`, `ffmpeg`), mDNS scoping, the
`en_US.UTF-8` locale, the `dancam-ap` access-point profile (without its password),
the `dancam` service user's `video`-group membership, persistent journald (dev
image), and the on-board hardware watchdog -- is provisioned declaratively with
Ansible. The playbook
(`raspi/ansible/site.yml`) is the source of truth for that state; the *why* behind each
choice lives in its task comments (see also
`raspi/docs/design/09-2026-06-26-pi-system-layer-config-ansible.md`). Run it from the
repo root **over home Wi-Fi** -- it needs internet for apt, and the Pi's AP has no
upstream:

```sh
just raspi-provision          # converge the Pi; reboots itself if a task needs it
```

It prompts once for your sudo password. When mDNS is flaky, target a raw LAN IP:
`just raspi-provision host=192.168.1.50`.

Preview what would change without touching the Pi (the drift detector), or lint the
playbook on the Mac with no Pi connection:

```sh
just raspi-provision-check    # --check --diff: shows pending changes, makes none
just raspi-provision-lint     # --syntax-check + ansible-lint, hardware-free
```

Re-running is idempotent: a converged Pi reports `changed=0` and does not reboot. The
one piece the playbook deliberately leaves unset is the AP password -- that is a
one-time manual step in section 6, so the secret never enters the repo.

Two of these -- persistent journald and the hardware watchdog -- are the freeze-
recovery layer from
[`raspi/docs/design/12-2026-06-30-watchdog-and-persistent-journal.md`](raspi/docs/design/12-2026-06-30-watchdog-and-persistent-journal.md).
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

## 4. Enable the camera (IMX708)

Provisioning (section 3) turned off `camera_auto_detect` and loaded the in-kernel
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

## 5. Verify the camera process dependencies

The production camera owner is a Python Picamera2 subprocess supervised by the Rust
service. Provisioning (section 3) installed Picamera2 and `ffmpeg` from apt (not pip,
so they match the Raspberry Pi OS libcamera stack, and without the desktop GUI
recommends). Confirm the import path works -- the camera overlay from section 4 must
already be enabled before the import/open path is useful on the Pi:

```sh
python3 -c "from picamera2 import Picamera2; print('ok')"
```

## 6. Create the dev access point profile

Provisioning (section 3) created the `dancam-ap` NetworkManager hotspot profile --
SSID `dancam-dev`, WPA2-AES (RSN/CCMP, no TKIP), channel 1, `10.42.0.1/24`, shared
IPv4, `connection.autoconnect no` -- with one field left unset on purpose: the WPA2
password. Set it once by hand on the Pi so the secret never lands in the repo, the
playbook, or shell history (the `read -rsp` prompt keeps it out of history, and
re-running the playbook does not disturb it):

```sh
read -rsp 'dancam-dev WPA2 PSK: ' DANCAM_AP_PSK; echo
sudo nmcli connection modify dancam-ap 802-11-wireless-security.psk "$DANCAM_AP_PSK"
unset DANCAM_AP_PSK
```

A cipher or PSK change only takes effect the next time `dancam-ap` is activated. If
the AP is already up, run `sudo nmcli connection down dancam-ap` and then
`sudo nmcli connection up dancam-ap` (or `sudo nmcli device reapply wlan0`); otherwise
the live beacon can still advertise the old profile and iOS may keep showing the
weak-security warning.

Before flipping the Pi into AP mode over SSH, always arm a systemd-owned return
timer. Replace the home profile name if `nmcli connection show` reports a
different one:

```sh
HOME_WIFI_CONNECTION="${DANCAM_HOME_WIFI:-<your-home-wifi>}"
sudo systemd-run --unit=dancam-restore-home-wifi --on-active=5min /usr/bin/nmcli connection up "$HOME_WIFI_CONNECTION"
sudo nmcli connection up dancam-ap
```

Shortcut: from the Mac (with the Pi still on home Wi-Fi), `just raspi-ap [minutes]`
(default 5) does the arm + flip in one step and then prints a local countdown to the
revert. It differs from the manual block above in one way: it schedules the AP-up as a
detached transient `dancam-go-ap` unit firing ~2s out, so the SSH session returns
cleanly before Wi-Fi drops instead of dying mid-command. The countdown runs on the Mac
(which can no longer see the Pi once the AP is up), so it is a local estimate of the
armed duration, not a probe of the Pi. Override the target/key/home-profile with
`DANCAM_HOST`, `DANCAM_SSH_KEY`, `DANCAM_HOME_WIFI`.

When the timer fires, inspect it with:

```sh
journalctl -b -u dancam-restore-home-wifi.service -u dancam-restore-home-wifi.timer
```

Power cycling also returns this dev image to home Wi-Fi because `dancam-ap` does
not autoconnect. Do not join `dancam-dev` from the Mac during an active remote
LLM session if the Mac's only internet path is your home Wi-Fi; use the iPhone for
AP testing.

## 7. Deploy and run the service

Cross-compile and deploy from the Mac in one command (Nix flake + `deploy.sh`;
details in [`raspi/AGENTS.md`](raspi/AGENTS.md) "Rust dev loop"). From the repo
root:

```sh
just raspi-deploy   # wraps ./raspi/deploy.sh
```

Provision first: the unit runs as `User=dancam`, and `just raspi-provision`
creates that system user before deploy starts the service.

This ships a static aarch64 binary, the camera process
(`/usr/local/lib/dancam/camera.py`), and the systemd unit (`dancam.service`),
enables/restarts the service, then waits for `/v1/health` to answer (polling up
to `DANCAM_HEALTH_TIMEOUT`s, default 60) and fires a macOS notification when the
service is ready to test. The deployed unit sets:

```ini
Environment=DANCAM_BIND=[::]:8080
Environment=DANCAM_BACKEND=camera
Environment=DANCAM_REC_DIR=/var/lib/dancam/rec
User=dancam
StateDirectory=dancam
```

`DANCAM_BACKEND=camera` makes the service spawn one long-lived Picamera2 owner
process. That process owns libcamera, emits low-res MJPEG preview on stdout, and
writes H.264 MPEG-TS recording segments under `/var/lib/dancam/rec` as the fixed
`dancam` service user. It also locks the IMX708 lens to infinity with autofocus
disabled; see
`raspi/docs/design/08-2026-06-25-fixed-infinity-focus.md`. Local `just raspi-mock`
still defaults to the mock backend and cycles committed test-pattern frames.

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

Verify from the Mac over the LAN:

```sh
curl -i http://dancam.local:8080/v1/health   # expect: 200 OK + x-dancam-proto: 1
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

Smoke-test the camera owner directly on the Pi before trusting a longer run:

```sh
rm -rf ~/rec-smoke
rm -f /tmp/dancam-camera-commands /tmp/dancam-preview.mjpeg /tmp/dancam-camera-events.log
mkfifo /tmp/dancam-camera-commands
python3 /usr/local/lib/dancam/camera.py \
  --rec-dir ~/rec-smoke \
  --preview-fps 10 \
  < /tmp/dancam-camera-commands \
  > /tmp/dancam-preview.mjpeg \
  2> /tmp/dancam-camera-events.log &
CAMERA_PID=$!
exec 3> /tmp/dancam-camera-commands
printf '{"cmd":"start_recording"}\n' >&3
sleep 35
printf '{"cmd":"stop_recording"}\n' >&3
printf '{"cmd":"start_recording"}\n' >&3
sleep 5
printf '{"cmd":"stop_recording"}\n{"cmd":"shutdown"}\n' >&3
exec 3>&-
wait "$CAMERA_PID"
grep -E '"ready"|"recording_started"|"recording_stopped"' /tmp/dancam-camera-events.log
ls -lh ~/rec-smoke/seg_*.ts
ffmpeg -v error -i ~/rec-smoke/seg_00000.ts -f null -
rm -f /tmp/dancam-camera-commands
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

From the Mac, fetch recent service logs or follow them live over SSH:

```sh
ssh dancam.local 'journalctl -u dancam -n 200 --no-pager'
ssh dancam.local 'journalctl -u dancam -f'
```

Request/response access lines appear in `journalctl -u dancam -f` with an
`x-request-id`; grep the journal for that id to correlate a Pi request. To raise
service verbosity without rebuilding, add `Environment=RUST_LOG=dancam=debug` with
`sudo systemctl edit dancam`, then restart `dancam`.

## 8. Smoke-test the AP path

With the service deployed, arm the home-Wi-Fi restore timer, flip the AP up, join
`dancam-dev` from the iPhone, and fetch:

```text
http://10.42.0.1:8080/v1/health
```

The expected response is the same JSON health payload as the home-LAN
`dancam.local` URL. The iPhone app's first AP health slice also targets
`http://10.42.0.1:8080`.

For app testing from Xcode, install/run the app on the iPhone while the phone is still
on the home Wi-Fi network, then switch only the iPhone to `dancam-dev`. Leave the
shared scheme without a `DANCAM_PIN_WIFI` override for the real AP path: the default
`http://10.42.0.1:8080` base URL derives to Wi-Fi pinning for both health and preview.
Use `DANCAM_PIN_WIFI=0` only for an explicit unpinned diagnostic pass.

The app target also carries `NSAppTransportSecurity` / `NSAllowsLocalNetworking` so
the clip viewer can serve progressive playback fragments over cleartext loopback HLS.
This is app bundle configuration; it does not require Pi provisioning or a router
change.

In the app, verify that the home screen health fetch succeeds, then open Live preview
and confirm that the camera feed is moving. Stop then Start should resume the stream.
In the 2026-06-25 `fox` spike, this worked over `dancam-dev` with cellular left on; no
captive sheet was observed.
