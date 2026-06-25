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

## 5. (Optional) Fix the locale warning

My SSH login warned `cannot change locale (UTF-8)` because the fresh Lite image has no
UTF-8 locale generated yet. Uncomment `en_US.UTF-8` in `/etc/locale.gen` and rebuild
the locale database on the Pi:

```sh
sudo sed -i 's/^# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
sudo locale-gen
```

Log out and back in -- the warning is gone.

## 6. Deploy and run the service

Cross-compile and deploy from the Mac in one command (Nix flake + `deploy.sh`;
details in [`raspi/AGENTS.md`](raspi/AGENTS.md) "Rust dev loop"). From the repo
root:

```sh
just raspi-deploy   # wraps ./raspi/deploy.sh
```

This ships a static aarch64 binary + the systemd unit (`dancam.service`),
enables/restarts the service, and curls `/v1/health`. Verify from the Mac over the
LAN:

```sh
curl -i http://dancam.local:8080/v1/health   # expect: 200 OK + x-dancam-proto: 1
```

Service management on the Pi:

```sh
systemctl status dancam        # running? enabled for boot?
journalctl -u dancam -f        # live logs
```
