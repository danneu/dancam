# Upstream source references

`references/` holds gitignored, read-only clones of the upstream source dancam
builds against. Keeping the source locally lets implementation target the exact
API and platform behavior installed on the Pi.

Seed or refresh the clones with `just fetch-references`. Pins live in
`scripts/fetch-references.sh` and match the versions the Pi runs. Before setting
or changing a pin, run `just references-pi-version` to confirm the installed
Pi versions.

- **picamera2** -- `references/picamera2/` contains the Raspberry Pi camera
  stack imported by `raspi/camera/camera.py`. It is pinned to the
  `python3-picamera2` version on Raspberry Pi OS Trixie. Upstream:
  [raspberrypi/picamera2](https://github.com/raspberrypi/picamera2).
- **libcamera** -- `references/libcamera/` contains the Raspberry Pi fork, not
  upstream linuxtv. This is the implementation that runs on the Pi, including
  the `rpi` pipeline handlers and IPA tuning used below picamera2. Its pin tracks
  the fork branch or tag matching the Pi's installed libcamera. Read the
  [Rust camera owner research](research/1-rust-camera-owner.md) before using it
  for a future all-Rust camera owner. Fork:
  [raspberrypi/libcamera](https://github.com/raspberrypi/libcamera).
- **Linux** -- `references/linux/` contains a sparse checkout of the Raspberry
  Pi kernel fork. It includes only
  `drivers/staging/vc04_services/bcm2835-codec/`, which implements the
  `/dev/video11` H.264 M2M encoder, and
  `drivers/media/platform/bcm2835/`, which implements the `bcm2835-unicam`
  CSI-2 receiver. These are the sources for the encoder and capture wrappers a
  future Rust camera owner would drive. The pin tracks the `stable_YYYYMMDD` tag
  matching the Pi's running kernel. Read the
  [Rust camera owner research](research/1-rust-camera-owner.md) for that work.
  Fork: [raspberrypi/linux](https://github.com/raspberrypi/linux).
