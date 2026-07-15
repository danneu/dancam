# Hardware

The v1 camera unit uses a Raspberry Pi Zero 2 W and an Arducam IMX708 Autofocus
Wide camera. The selection is tentative until more real-car testing, but these are
the parts and compatibility constraints the current software targets.

## Raspberry Pi Zero 2 W

- [Raspberry Pi Zero 2 W (2021)](https://www.amazon.com/gp/product/B09LH5SBPS),
  approximately 60 USD.
- Quad-core Cortex-A53 at 1 GHz with 512 MB RAM. Memory is tight, so the camera
  stack and service must stay lean.
- 2.4 GHz 802.11 b/g/n Wi-Fi only. There is no 5 GHz radio, which is why the
  system uses low-resolution preview and on-demand footage pulls.
- Hardware H.264 encode is capped at 1080p30. The board cannot hardware-encode
  4K, HEVC, or the camera's higher-rate 1080p modes.
- The board is rated for -20 C to +70 C ambient operation.
- There is no real-time clock; time comes from the phone and may later come from
  a GPS module.
- The 40-pin header is unpopulated from the factory.

## Arducam IMX708 Autofocus Wide

- [Arducam 12MP IMX708 Autofocus Wide](https://www.amazon.com/gp/product/B0C5D97DRJ),
  approximately 30 USD. It is equivalent in sensor and basic capabilities to the
  official Camera Module 3 Wide.
- The camera provides HDR, PDAF autofocus, a Sony IMX708 sensor, and native
  libcamera support.
- Arducam's field-of-view specifications disagree. Its product page says about
  120 deg diagonal, while its wiki says 110 deg diagonal x 100 deg horizontal x
  72 deg vertical. Either set is slightly narrower than the official Camera
  Module 3 Wide's 120 deg diagonal x 102 deg horizontal x 67 deg vertical.
- The included 15-to-22-pin "Standard-Mini" FPC cable has 15 pins at the camera
  and 22 pins at the board. The 22-pin end fits the Zero 2 W mini-CSI connector,
  which is also used by the Pi 5 and Compute Modules. A standard Pi 3 or Pi 4
  would instead need a 15-to-15-pin "Standard-Standard" cable.
- The camera is rated for 0 C to +50 C operation. This is the system's thermal
  weak link; hot-parked operation is bounded by the sensor rather than the Pi.

The camera meets the v1 requirement for roughly 120-140 deg coverage, HDR,
autofocus, and acceptable low-light performance. In this ecosystem, HDR and
autofocus together are available only on the IMX708, and autofocus tops out near
120 deg. Wider options require a fixed-focus M12 lens.

## Raspberry Pi OS compatibility

The current image is Raspberry Pi OS Lite, 64-bit, based on Trixie / Debian 13
(the 2026-06-18 build with the 6.18 LTS kernel). Trixie ships `rpicam-vid` and
the IMX708 driver in the kernel.

The Arducam B0311 is not an official Raspberry Pi module, so it is not
auto-detected. It uses the kernel's in-tree overlay with
`camera_auto_detect=0` and `dtoverlay=imx708` in
`/boot/firmware/config.txt`. The playbook at `raspi/ansible/site.yml` applies
the overlay and reboots. This path needs no install script or separate tuning
file and survives kernel upgrades.

Do not use Arducam's legacy `install_pivariety_pkgs.sh` driver. It installs
prebuilt per-kernel binaries that break on `apt upgrade`, which caused the
reports that a kernel downgrade was required. The official Camera Module 3
would auto-detect without extra configuration if zero camera setup becomes more
important than the current module choice.

Camera and codec buffers come from CMA on this 512 MB board; the old `gpu_mem`
split is obsolete. If `rpicam` reports buffer-allocation failures, raise CMA
with a `/boot/firmware/config.txt` overlay such as
`dtoverlay=cma,cma-size=...`, not `gpu_mem`.

Use Raspberry Pi Imager 2.0.10 or newer and preconfigure the hostname, SSH,
login user, and home Wi-Fi. Trixie images use cloud-init for first-boot
customization. Imager 1.9.x cannot customize Trixie, and releases 2.0.6 through
2.0.8 can leave headless SSH disabled because they emit the deprecated
`enable_ssh` key. The issue was fixed in the 2.0.9 prerelease and is stable in
2.0.10. Editing files on the boot partition is only the legacy fallback.

Follow the [Pi setup runbook](setup/pi-runbook.md) for flashing and bootstrap.
The [Pi OS image design](design/pi/os-image.md) owns the deployed filesystem,
power-loss, and recovery model.
