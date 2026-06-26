# Raspberry Pi setup

Hands-on runbook for bringing up the dancam camera unit -- from flashing the microSD
through serving the health endpoint. These are the concrete steps we ran for the
`pine` swoop. For the design rationale behind each choice, see
[`raspi/AGENTS.md`](raspi/AGENTS.md); this file is just the commands.

Hardware: [Raspberry Pi Zero 2 W](https://www.raspberrypi.com/products/raspberry-pi-zero-2-w/) + [Arducam IMX708 Autofocus Wide](https://www.amazon.com/dp/B0C5D97DRJ), ribbon attached.

OS: Raspberry Pi OS Lite (64-bit) was at release 2026-06-18 as of writing this.

## 1. Flash Raspberry Pi OS Lite

Flash the microSD with **Raspberry Pi Imager 2.0.10 or newer** (older Imager can't
customize Trixie -- 1.9.x writes the wrong format and 2.0.6-2.0.8 can leave SSH off):

1. **Choose OS:** `Raspberry Pi OS (other)` -> `Raspberry Pi OS Lite (64-bit)`.
2. **Choose storage:** the microSD.
3. **Edit Settings** (the OS-customization step) and set:
   - Hostname: `dancam`
   - Username `dan` + a password
   - Enable SSH -> "Allow public-key authentication only", and add your
     `~/.ssh/<your-key>.pub`
   - Configure wireless LAN: your home Wi-Fi SSID + password (so it joins headless)
4. Write the card, insert it in the Pi, and power on (the `PWR` micro-USB
   port). First boot runs cloud-init -- it creates `dan`, installs your key, joins
   Wi-Fi, and sets the hostname, then reboots once. Give it ~60-90s.

## 2. SSH in

From the Mac over the home LAN (mDNS). `-i` points at the **private** key -- the
counterpart of the `.pub` you added when flashing (omit `-i` if it's a default name
like `id_ed25519`):

```sh
ssh -i ~/.ssh/<your-key> dan@dancam.local
```

Confirm it came up as the 64-bit Trixie kernel (`aarch64` / `v8` = 64-bit):

```sh
uname -a
```

## 3. Update packages

A fresh Lite image is already a bit behind. Refresh the package index, upgrade what's
installed, then add anything you want on the Pi (e.g. `vim`):

```sh
# refresh the package index, then upgrade everything already installed
sudo apt update && sudo apt full-upgrade -y

# install vim, or any other packages you might want on the Pi
sudo apt install -y vim
```

If the upgrade pulls a new kernel/firmware, `sudo reboot` to pick it up.

## 4. Enable the camera (IMX708)

The Arducam IMX708 is not an official module, so it is not auto-detected. Turn
auto-detect off and load the in-kernel overlay in `/boot/firmware/config.txt`:

```sh
sudo sed -i 's/^camera_auto_detect=1/camera_auto_detect=0/' /boot/firmware/config.txt
echo 'dtoverlay=imx708' | sudo tee -a /boot/firmware/config.txt

# verify the two lines look right, then reboot to load the overlay
grep -nE 'camera_auto_detect|imx708' /boot/firmware/config.txt
sudo reboot
```

`dtoverlay=imx708` is appended under the `[all]` section at the end of the file, so
it applies to the Zero 2 W. Do **not** use Arducam's `install_pivariety_pkgs.sh`:
the in-kernel overlay survives `apt upgrade`, the prebuilt-driver script does not.

After the reboot, SSH back in and smoke-test capture:

```sh
rpicam-hello --list-cameras              # should list: 0 : imx708 [4608x2592 ...]
rpicam-jpeg -n -o /tmp/test.jpg -t 2000  # -n = no preview window (headless)
ls -lh /tmp/test.jpg                      # a real ~1-2 MB JPEG => capture works
```

Optionally pull the image to the Mac to eyeball focus/orientation:

```sh
# run on the Mac
scp -i ~/.ssh/<your-key> dan@dancam.local:/tmp/test.jpg ~/Desktop/dancam-test.jpg
```

## 5. Install the camera process dependencies

The production camera owner is a Python Picamera2 subprocess supervised by the
Rust service. Install Picamera2 from apt, not pip, so it matches the Raspberry Pi
OS libcamera stack:

```sh
sudo apt install -y --no-install-recommends python3-picamera2 ffmpeg
python3 -c "from picamera2 import Picamera2; print('ok')"
```

The package pulls the Python libcamera bindings, numpy, and simplejpeg without the
desktop GUI recommends. The camera overlay from section 4 must already be enabled
before the import/open path is useful on the Pi.

## 6. Scope mDNS to Wi-Fi

Keep `dancam.local` tied to the reachable Wi-Fi interface. Without this, Avahi can
publish on loopback before Wi-Fi settles, later detect a stale self-conflict, and
rename the host to `dancam-2.local`.

On the Pi:

```sh
sudo cp /etc/avahi/avahi-daemon.conf /etc/avahi/avahi-daemon.conf.dancam-before-wlan0-only
sudo sed -i 's/^#allow-interfaces=eth0/allow-interfaces=wlan0/' /etc/avahi/avahi-daemon.conf
grep -n '^allow-interfaces=wlan0$' /etc/avahi/avahi-daemon.conf
sudo systemctl restart avahi-daemon
systemctl status avahi-daemon --no-pager
```

The status should show `running [dancam.local]`, not `dancam-2.local`.

## 7. Create the dev access point profile

The dev image normally joins home Wi-Fi for deploy/debug, but it also has a
manual NetworkManager hotspot profile for iPhone testing. Pick a dev WPA2
password and do not commit it anywhere. The profile pins WPA2-AES (RSN/CCMP,
no TKIP) so iOS does not show a weak-security warning.

On the Pi:

```sh
read -rsp 'dancam-dev WPA2 password: ' DANCAM_AP_PSK
echo

sudo nmcli connection add \
  type wifi \
  ifname wlan0 \
  con-name dancam-ap \
  ssid dancam-dev

sudo nmcli connection modify dancam-ap \
  connection.autoconnect no \
  802-11-wireless.mode ap \
  802-11-wireless.band bg \
  802-11-wireless.channel 1 \
  802-11-wireless-security.key-mgmt wpa-psk \
  802-11-wireless-security.psk "$DANCAM_AP_PSK" \
  802-11-wireless-security.proto rsn \
  802-11-wireless-security.pairwise ccmp \
  802-11-wireless-security.group ccmp \
  ipv4.method shared \
  ipv4.addresses 10.42.0.1/24 \
  ipv6.method ignore

unset DANCAM_AP_PSK

nmcli -f connection.id,connection.autoconnect,802-11-wireless.ssid,802-11-wireless.mode,802-11-wireless.band,802-11-wireless.channel,ipv4.method,ipv4.addresses,ipv6.method connection show dancam-ap
nmcli -f 802-11-wireless-security.key-mgmt,802-11-wireless-security.proto,802-11-wireless-security.pairwise,802-11-wireless-security.group connection show dancam-ap
```

Expected profile values:

```text
connection.id:                          dancam-ap
connection.autoconnect:                 no
802-11-wireless.ssid:                   dancam-dev
802-11-wireless.mode:                   ap
802-11-wireless.band:                   bg
802-11-wireless.channel:                1
ipv4.method:                            shared
ipv4.addresses:                         10.42.0.1/24
ipv6.method:                            ignore
```

Expected security values:

```text
802-11-wireless-security.key-mgmt:      wpa-psk
802-11-wireless-security.proto:         rsn
802-11-wireless-security.pairwise:      ccmp
802-11-wireless-security.group:         ccmp
```

The cipher settings take effect the next time `dancam-ap` is activated. If the AP
is already up, run `sudo nmcli connection down dancam-ap` and then
`sudo nmcli connection up dancam-ap` (or `sudo nmcli device reapply wlan0`);
otherwise the live beacon can still advertise the old WPA/WPA2 TKIP-capable
profile and iOS may keep showing the warning.

Before flipping the Pi into AP mode over SSH, always arm a systemd-owned return
timer. Replace the home profile name if `nmcli connection show` reports a
different one:

```sh
HOME_WIFI_CONNECTION=netplan-wlan0-peluchonet
sudo systemd-run --unit=dancam-restore-home-wifi --on-active=5min /usr/bin/nmcli connection up "$HOME_WIFI_CONNECTION"
sudo nmcli connection up dancam-ap
```

When the timer fires, inspect it with:

```sh
journalctl -b -u dancam-restore-home-wifi.service -u dancam-restore-home-wifi.timer
```

Power cycling also returns this dev image to home Wi-Fi because `dancam-ap` does
not autoconnect. Do not join `dancam-dev` from the Mac during an active remote
LLM session if the Mac's only internet path is `peluchonet`; use the iPhone for
AP testing.

## 8. (Optional) Fix the locale warning

My SSH login warned `cannot change locale (UTF-8)` because the fresh Lite image has no
UTF-8 locale generated yet. Uncomment `en_US.UTF-8` in `/etc/locale.gen` and rebuild
the locale database on the Pi:

```sh
sudo sed -i 's/^# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
sudo locale-gen
```

Log out and back in -- the warning is gone.

## 9. Deploy and run the service

Cross-compile and deploy from the Mac in one command (Nix flake + `deploy.sh`;
details in [`raspi/AGENTS.md`](raspi/AGENTS.md) "Rust dev loop"). From the repo
root:

```sh
just raspi-deploy   # wraps ./raspi/deploy.sh
```

This ships a static aarch64 binary, the camera process
(`/usr/local/lib/dancam/camera.py`), and the systemd unit (`dancam.service`),
enables/restarts the service, and curls `/v1/health`. The deployed unit sets:

```ini
Environment=DANCAM_BIND=0.0.0.0:8080
Environment=DANCAM_BACKEND=camera
Environment=DANCAM_REC_DIR=/home/dan/rec
```

`DANCAM_BACKEND=camera` makes the service spawn one long-lived Picamera2 owner
process. That process owns libcamera, emits low-res MJPEG preview on stdout, and
writes H.264 MPEG-TS recording segments under `DANCAM_REC_DIR`. It also locks the
IMX708 lens to infinity with autofocus disabled; see
`raspi/docs/design/08-2026-06-25-fixed-infinity-focus.md`. Local `just raspi-mock`
still defaults to the mock backend and cycles committed test-pattern frames.

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
rm -rf /home/dan/rec-smoke
rm -f /tmp/dancam-camera-commands /tmp/dancam-preview.mjpeg /tmp/dancam-camera-events.log
mkfifo /tmp/dancam-camera-commands
python3 /usr/local/lib/dancam/camera.py \
  --rec-dir /home/dan/rec-smoke \
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
ls -lh /home/dan/rec-smoke/seg_*.ts
ffmpeg -v error -i /home/dan/rec-smoke/seg_00000.ts -f null -
rm -f /tmp/dancam-camera-commands
```

For the real `jet` gate, run a longer room-temperature and warm soak, inspect CPU,
free memory/swap activity, SoC and sensor temperatures, preview smoothness, and
verify the second start/stop cycle continues segment numbering instead of
overwriting the first session.

Because the smoke command runs as the interactive `dan` user but deployment runs
under systemd with no login session, also verify the unit can open the camera:

```sh
id dan
ls -l /dev/video11 /dev/dma_heap/* 2>/dev/null
sudo systemctl restart dancam
journalctl -u dancam -n 80 --no-pager | grep '"ready"'
```

`dan` must have group access to `/dev/video11` for hardware MJPEG and
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

## 10. Smoke-test the AP path

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

In the app, verify that the home screen health fetch succeeds, then open Live preview
and confirm that the camera feed is moving. Stop then Start should resume the stream.
In the 2026-06-25 `fox` spike, this worked over `dancam-dev` with cellular left on; no
captive sheet was observed.
