# Plan: target Raspberry Pi OS Trixie + NetworkManager AP tooling on the Zero 2 W

## Context

The camera unit is committed to the **Raspberry Pi Zero 2 W** (board acquired, Arducam
IMX708 confirmed physically connected). The board, its 2.4 GHz-only radio, and the whole
"preview + pull only" link philosophy are unchanged. What this plan updates is the
**OS target and the software/provisioning tooling**, which the docs currently describe
with stale specifics:

- OS is named **Bookworm**; the current Raspberry Pi OS Lite 64-bit is **Trixie (Debian 13)**.
- The access point is described as **hostapd + dnsmasq**; current Raspberry Pi OS defaults
  to **NetworkManager**, whose idiomatic AP is an `nmcli` hotspot.
- First-boot provisioning predates Trixie's **cloud-init** switch (which needs a newer Imager).
- The Arducam enablement config (`camera_auto_detect=0` + `dtoverlay=imx708`) is correct but
  **buried** in the OS-flash block; it needs to be prominent because this is a non-official
  module that is not auto-detected.
- The camera-cable note is **factually backwards** (it claims the bundled cable does not fit
  the Zero 2 W -- contradicted by the camera now being plugged in).

Outcome: the docs read as a correct, current Zero 2 W + Raspberry Pi OS Trixie build, with
the camera-enable step impossible to miss. This is factual retargeting of OS/tooling only --
no architecture change and **no board change**.

## Decisions locked (with the owner)

1. **Board stays the Zero 2 W.** Keep every 2.4 GHz reference, the `g_ether`/USB-gadget SSH
   fallback (the Zero 2 W's micro-USB does OTG), the 1 GHz quad-A53 / 512 MB specs, the single
   microSD slot, micro-USB 5V power, and no-RTC notes exactly as written.
2. **OS -> Raspberry Pi OS Lite, 64-bit, Trixie** (Debian 13; the 2026-06-18 build; Linux
   6.18 LTS). Replace "Bookworm".
3. **AP tooling -> NetworkManager hotspot** (`nmcli`, `ipv4.method=shared`, which runs NM's own
   `dnsmasq` for DHCP/DNS), on the **2.4 GHz** band. Replace "hostapd + dnsmasq".
4. **Surface the Arducam enable config** in the camera/hardware section (not only the flash block).
5. **Fix the camera-cable note** to match reality (15-pin camera end, 22-pin Zero 2 W end).
6. **Update the stale `hostapd/dnsmasq` mention** in the already-shipped impl-plan record too.

## Verified facts driving the edits (primary-source confirmed)

- **Raspberry Pi OS Lite 64-bit Trixie** exists: release **2026-06-18**, kernel **6.18 LTS**
  (raspberrypi.com/software/operating-systems).
- **NetworkManager is the default** network stack (since Bookworm, thus on Trixie). An `nmcli`
  hotspot with `ipv4.method=shared` **spins up its own `dnsmasq`** instance for DHCP/DNS --
  so ADR 02's captive-probe DNS lever still applies, just via NM's dnsmasq.
- **Trixie first boot uses cloud-init**; customization needs the **current Raspberry Pi Imager
  (2.0.10 or newer)**. 1.9.x cannot customize Trixie images at all; the **2.0.6-2.0.8 stables emit
  the deprecated cloud-init `enable_ssh` key, which does NOT enable SSH on Trixie** (the fix --
  switching to `systemctl` via `runcmd` -- first shipped in the 2.0.9 prerelease and reached stable
  in 2.0.10), so a too-old Imager yields a headless image with SSH expected but off. Editing files
  on the boot partition is the legacy
  fallback.
- **`rpicam-*` tool names are unchanged** on Trixie (no rename away from `rpicam`).
- **`gpu_mem` is legacy**; on modern Raspberry Pi OS, camera/codec buffers come from **CMA**.
  Tune CMA via a `config.txt` overlay (e.g. `dtoverlay=cma,cma-size=...`), not `gpu_mem`.
- **Arducam IMX708 enable recipe**: `camera_auto_detect=0` + `dtoverlay=imx708` in
  `/boot/firmware/config.txt`. The driver/overlay ship in the Raspberry Pi kernel that Pi OS
  uses; the legacy `install_pivariety_pkgs.sh` is the fragile per-kernel alternative to avoid.
- **Zero 2 W radio is 2.4 GHz 802.11 b/g/n only** (no 5 GHz) -- the 2.4 GHz framing is correct.

## Edits by file

### 1. `raspi/AGENTS.md` (the heaviest file)

**Camera section (L24-32):**
- **Fix the cable note (L27-30).** Replace with: ships a 15-22pin **"Standard-Mini"** FPC
  cable -- **15-pin at the camera, 22-pin at the board**; the 22-pin end plugs into the Zero
  2 W's mini-CSI port (same connector as the Pi 5 and Compute Modules), the 15-pin end into
  the camera. (A standard Pi 3/4's 15-pin CSI port would instead want a 15-15 "Standard-Standard"
  cable.) Remove the incorrect "the included one does not fit them" claim.
- **Add a prominent enable callout.** Under the camera spec add a one-liner: this is **not an
  official module so it is not auto-detected** -- enable it with `camera_auto_detect=0` +
  `dtoverlay=imx708` in `/boot/firmware/config.txt` (full steps in "OS and first flash").

**Constraints / software / AP:**
- **Software-stack OS bullet (L58-60):** note the OS is **Raspberry Pi OS Lite, 64-bit
  (Trixie / Debian 13)** alongside the existing read-only-root description.
- **Access point bullet (L68):** "hostapd + dnsmasq (or equivalent)" -> a **NetworkManager
  hotspot** (`nmcli`, `ipv4.method=shared`, which runs NM's own `dnsmasq` for DHCP/DNS) on the
  **2.4 GHz** band. Add a one-line pointer that ADR 02's captive-probe DNS lever is applied
  through NM's dnsmasq (shared mode), not a hand-run dnsmasq.

**OS / first-flash (L110-138):**
- **Dev-vs-car table, Network row (L115):** "runs the AP (hostapd + dnsmasq)" ->
  "runs the AP (NetworkManager hotspot, 2.4 GHz)".
- **OS Lite block (L125-133):** "Bookworm" -> **"Trixie (Debian 13; the 2026-06-18 build,
  kernel 6.18 LTS)"** in both spots. Keep the `camera_auto_detect=0` + `dtoverlay=imx708`
  recipe and the "do NOT use `install_pivariety_pkgs.sh`" guidance verbatim. Lightly reword
  "the mainline way" -> "the kernel's in-tree overlay" (the overlay ships in the Pi OS kernel;
  full PDAF/HDR support is not in vanilla mainline). Add a brief **CMA note**: on this 512 MB
  board, camera/codec buffers come from CMA -- the `gpu_mem` split is obsolete; if `rpicam`
  reports buffer-allocation failures, raise CMA via a `config.txt` overlay, do not set `gpu_mem`.
- **Imager flash step (L134-136):** add that current Trixie images use **cloud-init**, so flash
  with the **current Raspberry Pi Imager (2.0.10 or newer)** -- older builds either cannot
  customize Trixie (1.9.x) or leave headless SSH off via the deprecated `enable_ssh` key
  (2.0.6-2.0.8 stables; fixed in the 2.0.9 prerelease, stable in 2.0.10); editing the boot
  partition is the legacy fallback.
- **g_ether fallback (L137-138):** **keep as-is** (the Zero 2 W's micro-USB supports gadget mode).
- **Partition layout (L142):** keep "the Zero 2 W has a single slot" as-is.

### 2. `AGENTS.md` (root)

- **Hardware pointer / architecture diagram / Wi-Fi principle:** **no change** (Zero 2 W and
  2.4 GHz are correct).
- **Development environment, Imager note (L51-55):** add a short clause that current Trixie
  images provision via cloud-init, so use the **current Raspberry Pi Imager (2.0.10+)**. Keep root lean -- one
  clause, details live in `raspi/AGENTS.md`.

### 3. `docs/roadmap.md`

- **Swoop `pine` (L30):** "flash Raspberry Pi OS (64-bit), bring up the Wi-Fi AP (hostapd +
  dnsmasq)" -> "flash **Raspberry Pi OS Lite (64-bit, Trixie)**, bring up the Wi-Fi AP
  (**NetworkManager hotspot, 2.4 GHz**)"; add a parenthetical that camera bring-up needs
  `camera_auto_detect=0` + `dtoverlay=imx708`.
- **Swoop `lime` spike (L53):** keep "2.4 GHz in-car throughput / pull times" as-is.

### 4. `plans/impl/2026-06-24-mock-pi-health-service.md`

- **L262:** "hostapd/dnsmasq AP" -> "NetworkManager-hotspot AP" (single-token fix so no doc
  names the old AP tooling).

### 5. raspi ADRs -- no rewrites

- ADR 02's `dnsmasq` captive-probe references (L63, L296, L507) stay: NM "shared" mode *is*
  dnsmasq, so the mechanism description remains correct, and ADRs are append-only. The pointer
  added to `raspi/AGENTS.md` (above) is where the NM-config path is noted.

## Keep as-is / explicitly out of scope (do NOT "fix" these)

- **All 2.4 GHz references** across root/raspi/app/ADR-02 -- the board is 2.4 GHz only.
- **`g_ether` / USB-gadget SSH fallback** -- the Zero 2 W does OTG.
- **Board specs:** 1 GHz quad-A53, 512 MB, single microSD slot, micro-USB 5V power, no RTC.
- **Board operating-temperature line** (`raspi/AGENTS.md:21`, "-20 C to +70 C ambient") -- correct
  per the official Zero 2 W product brief; leave as-is, no future board-facts pass needed here.
- **Rust cross-compile recipe** (aarch64 musl static) -- unaffected by the OS change.
- **The Arducam recipe's substance** (`camera_auto_detect=0` + `dtoverlay=imx708`; avoid
  `install_pivariety_pkgs.sh`) -- keep verbatim, only surface it more prominently.

## Watch items (non-blocking)

- **overlayfs on Trixie** may need an initramfs nudge (`overlay` module + `update-initramfs`)
  before read-only-root mode works -- but read-only root is a later hardening pass, so this is a
  note, not a change here.
- **Interface naming** under systemd 257 -- verify `wlan0` before scripting the AP.

## Verification

1. `just adr-check` -- stays green (no ADR filename changes).
2. Residual-reference sweep (review aid, not a zero-hits gate). Scope to the touched canonical
   docs + the one touched impl record; **exclude `plans/wip/`** (the in-progress plan drafts
   reference the old terms while describing the change, so they are expected hits, not failures):
   `rg -in 'bookworm|hostapd' AGENTS.md raspi/ docs/ plans/impl/2026-06-24-mock-pi-health-service.md`
   -> expect **zero** hits.
   `rg -in 'gpu_mem' raspi/` -> only the new "use CMA, not `gpu_mem`" note.
   `rg -in '2\.4 ghz|g_ether|gadget mode' raspi/ AGENTS.md` -> **still present** (must NOT be removed).
   `rg -in 'trixie|networkmanager|nmcli|cloud-init|cma|2\.0\.10' AGENTS.md raspi/ docs/` -> new tooling landed.
3. Read each touched file end-to-end: confirm the OS/tooling rationale reads coherently and the
   camera-enable callout is discoverable from the camera/hardware section.
4. Confirm cross-references still agree: root principles <-> `raspi/AGENTS.md` <-> ADR 02 all
   describe **"2.4 GHz, preview + pull only"** and the captive-probe DNS lever (now via NM's dnsmasq).

## Commit guidance

One `docs:` commit (or split root vs raspi if preferred). Suggested subject:
`docs(raspi): target Raspberry Pi OS Trixie and NetworkManager AP tooling`. Body can note the
camera-cable correction and the prominent Arducam enable callout. Do not commit/push unless asked.
