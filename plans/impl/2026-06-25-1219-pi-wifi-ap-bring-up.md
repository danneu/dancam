# Plan: bring up the Pi's Wi-Fi access point

## Context

The dancam camera unit (Raspberry Pi Zero 2 W) currently joins home Wi-Fi as a
client. The product design has the Pi run its own 2.4 GHz access point with no
router, so the iPhone joins the Pi directly. This plan brings that AP up on real
hardware and proves it end to end. It is the remaining network-layer work for the
`pine` swoop (real Pi bring-up); the rest of `pine` -- camera capture, the Rust
service, and a `200` from `GET /v1/health` over the home LAN -- is already done.

The finish line is narrow and concrete: **an iPhone joins the Pi's AP and gets a
`200` from `/v1/health` over that link** (with the Mac proving the path first).

This is a hardware-first plan. The repo docs prescribe a NetworkManager hotspot
(`nmcli`, `ipv4.method=shared`, 2.4 GHz, NM's own dnsmasq), but that is the
**starting hypothesis, not the spec**. Bring the AP up, observe what the radio and
iOS actually do, then take the ideal path -- and update the ADRs/docs where reality
diverges from what was written ahead of time.

The service needs no change: it already binds `0.0.0.0:8080` via the systemd unit
(`raspi/dancam.service`) and serves `/v1/health`. This is purely network plumbing
plus one app-side base-URL change.

## Decisions locked for this pass

- **Toggleable NM hotspot, client by default.** The AP is a NetworkManager
  connection profile with `connection.autoconnect no`. The Pi stays a home-Wi-Fi
  client for the dev loop; the AP is brought up on demand. This matches the existing
  dev-image-vs-car-image split and makes a power-cycle the instant escape hatch.
- **Single radio: AP replaces client, no concurrency.** The Zero 2 W has one
  2.4 GHz radio; bringing the AP up tears down the home-Wi-Fi association. AP+STA
  concurrency (a virtual `uap0` on brcmfmac) is deliberately skipped -- it is fragile,
  locks both interfaces to one channel, and buys nothing in the car (no home Wi-Fi to
  coexist with). Record the `iw list` interface-combination evidence to justify the
  skip.
- **Rescue path: reboot-revert + join-AP.** No extra hardware. The `autoconnect no`
  AP profile + an `autoconnect yes` home-Wi-Fi profile means a power-cycle always
  returns the Pi to home Wi-Fi. To reach the Pi live while it is in AP mode, the Mac
  joins the Pi's SSID and `ssh <user>@10.42.0.1`. (USB-gadget `g_ether` and serial UART
  remain documented heavier fallbacks if this proves too thin in practice, but are
  not set up now.)
- **Gateway IP: `10.42.0.1`**, pinned via `ipv4.addresses 10.42.0.1/24` on the AP
  profile (kept alongside `ipv4.method shared`). This stays in NetworkManager's native
  shared-mode range rather than fighting the tool to reach `192.168.4.1`, but pins the
  exact address so every fixed `10.42.0.1` reference below (rescue SSH, verification,
  app fallback, ADR note) is accurate. With no address set, NM shared mode picks
  `10.42.x.1/24`, incrementing the third octet to dodge route conflicts, so the subnet
  is not guaranteed -- hence the pin. Append a dated note to ADR 02 correcting its
  `192.168.4.1` example, the Host-allowlist host, and the app's fixed-IP fallback to
  `10.42.0.1`. This is the "take the ideal, keep the ADRs truthful" call.
- **WPA2-PSK from the start**, with a manually-entered dev SSID + password for now.
  Per-unit random password + QR-sticker provisioning (ADR 02's trust model) is a
  later hardening concern, not needed to get a `200`.
- **Captive-probe DNS lever: deferred, applied only on evidence.** Its job is to
  stop the iOS Captive Network Assistant (CNA) sheet from hijacking a *persistent*
  join (a later-swoop robustness concern), not to get one `200`. Observe iOS's
  behavior during bring-up; apply the lever only if it actually blocks the fetch.
  Deferring it here does not overturn ADR 02's standing requirement that the lever is
  needed for silent no-internet AP behavior on persistent joins -- this pass only
  proves a one-shot fetch, so it cannot conclude the lever is unnecessary in general.

## Open decisions to resolve on the hardware

- **Regdomain/channel specifics.** Country is `US` (required -- see gotchas); pick a
  pinned 2.4 GHz channel (1/6/11) empirically based on what is least congested.
- **App base-URL target:** default to the pinned `http://10.42.0.1:8080`. ATS does
  not apply to IP-address literals at all (Apple DTS), so a raw IP needs no ATS key
  and -- unlike `.local` -- carries no avahi/mDNS dependency on the critical `200`
  path, making the Mac and iPhone proofs identical. `http://dancam.local:8080` is a
  nicer-URL **follow-up**, adopted only once mDNS is confirmed to resolve reliably over
  the AP *from the iPhone* (Mac-side resolution does not guarantee the iPhone will --
  separate resolvers plus iOS Local Network gating).
- **ADR home for the AP decisions:** a new raspi-side ADR 06 ("AP networking /
  bring-up") is the recommended home, since ADR 02 owns the wire contract, not the
  AP plumbing -- but confirm against the one-decision-per-file convention when
  writing it.

## Bring-up sequence

### Phase 0 -- Baseline and undo (still a home-Wi-Fi client)
- Confirm the known-good world: `ssh <user>@dancam.local` works, `raspi/deploy.sh`
  succeeds, `/v1/health` returns `200` over the LAN. This is the rollback target.
- Deploy the current service now, while still on home Wi-Fi, so the AP phase is
  purely network-layer.
- Snapshot NM/radio state for rollback: `nmcli connection show`, `nmcli device
  status` (note the exact home-Wi-Fi profile name), `iw reg get`, `rfkill list`.

### Phase 1 -- Pre-flight (still a client)
- Set/confirm Wi-Fi country `US` and that wlan is not rfkill soft-blocked
  (`iw reg get`, `rfkill list`). This is the #1 reason an AP fails to start.
- Confirm the interface is `wlan0` under Trixie (`nmcli device`, `ip link`).
- Read radio capabilities: `iw phy` / `iw list` -- confirm AP mode + 2.4 GHz
  channels, and capture the "valid interface combinations" stanza as evidence for the
  no-concurrency decision.

### Phase 2 -- Create the AP profile (down, no autoconnect)
- Create a NetworkManager AP profile: `802-11-wireless.mode ap`, SSID, WPA2-PSK,
  `band bg`, a pinned channel, `ipv4.method shared`, **`ipv4.addresses 10.42.0.1/24`**
  (pin the address -- with none set, NM shared mode picks `10.42.x.1/24`, incrementing
  the third octet to dodge route conflicts, so the exact subnet is not guaranteed),
  `ipv6.method ignore`, `connection.autoconnect no`. NM shared mode then brings up its
  own dnsmasq for DHCP/DNS on `10.42.0.1`.
- Leave it down; review it (`nmcli connection show <ap>`). This profile is the toggle.

### Phase 3 -- First flip, undo ready
- Before flipping, schedule the revert **detached from the SSH session** so it survives
  the dropped link: `sudo systemd-run --on-active=5min nmcli connection up
  "<home-profile>"`. A foreground `sleep`-then-revert does not work -- bringing the AP
  up tears down the STA association and SIGHUPs the SSH session it ran in, killing the
  timer before it fires. The transient timer is owned by PID 1, so it survives (a
  power-cycle remains the backstop via `autoconnect`). Note the transient unit name
  `systemd-run` prints -- you disarm it once the rescue join is proven (Verification
  A2), so it does not fire mid-verification.
- Bring the AP up on demand (`nmcli connection up <ap>`). Expect to lose
  `dancam.local` SSH at this instant (the STA association drops).
- If the AP started, join it from the Mac to debug live (`iw dev`, `nmcli device`,
  `journalctl -u NetworkManager` for wpa_supplicant + dnsmasq; confirm the shared-mode
  dnsmasq serves `10.42.0.1`). If the AP did **not** start, the rescue join is
  unavailable too -- let the scheduled timer (or a power-cycle) restore home Wi-Fi,
  then read `journalctl -u NetworkManager` once the Pi is back. If the AP "starts" but
  no client can see it, suspect regdomain/channel first.

### Phase 4 -- Prove from the Mac -> see Verification A below.
### Phase 5 -- Prove from the iPhone -> see Verification B below.
### Phase 6 -- Capture findings, update docs/ADRs -> see "Docs / ADRs to update" below.

## Minimal app-side change

The smallest change that proves the `200`:

- **Repoint the health client base URL.** In
  `app/DanCam/DanCam/App/AppDependencies.swift`, change
  `health: .live(baseURL: URL(string: "http://macbook.local:9000")!)` to
  `http://10.42.0.1:8080` -- the pinned AP gateway (note the unit listens on `8080`,
  not the mock's `9000`). The raw IP is ATS-exempt and has no mDNS dependency, so it is
  the reliable target for the first `200`. Switching to `http://dancam.local:8080` is a
  **follow-up**, only once mDNS-over-AP is confirmed from the iPhone.
- **No `NSBonjourServices` needed.** A direct `URLSession` fetch to a known host/IP
  does not need it; it is only required once `NWBrowser` discovery of `_dancam._tcp`
  lands (a later swoop). The existing `NSLocalNetworkUsageDescription` is enough to
  drive the Local Network permission prompt.
- **No `NWConnection` Wi-Fi pinning yet.** Default `URLSession.shared` is fine for a
  directly-connected subnet destination. Pinning is a later-swoop concern.
- **Physical iPhone required.** The Simulator shares the Mac's network and cannot
  join a separate AP, so this needs a real device (and therefore a dev signing team
  on the `DanCam` target -- an environmental prerequisite to check).
- Keep the base URL hardcoded for now; "make it configurable" is a follow-up.

## Verification

### A. Prove the AP from the Mac (no phone yet)
1. With the AP up and confirmed live, join the Pi's SSID from the Mac (the Mac drops
   home Wi-Fi for the duration).
2. Confirm a DHCP lease in the `10.42.0.0/24` subnet, `ping 10.42.0.1`, and
   `ssh <user>@10.42.0.1` succeeds. Once the rescue join works you have live control, so
   **disarm the pending revert** (`sudo systemctl stop <transient-unit>.timer`, the
   name from Phase 3) before A3/A4 -- otherwise the 5-minute timer reasserts home Wi-Fi
   mid-test and the AP vanishes, reading as a spurious "AP dropped" failure. The
   power-cycle backstop remains.
3. **Health over the air:** `curl -i http://10.42.0.1:8080/v1/health` from the Mac
   (not via ssh -- this proves the request crossed the Wi-Fi link). Expect `200`,
   JSON `{boot_id, uptime_s, recording, t_ms}`, and headers `x-dancam-proto: 1` +
   `x-dancam-boot-id`.
4. Also try `curl -i http://dancam.local:8080/v1/health` over the AP -- informational
   only, to learn whether mDNS resolves post-association from the Mac. It informs the
   `.local` follow-up, not the first `200`; the app targets the pinned IP regardless,
   and iPhone mDNS must be confirmed separately before adopting `.local` there.

### B. Prove from the iPhone via the app
5. Repoint `AppDependencies.live`, build/run on a physical iPhone.
6. iPhone Settings -> Wi-Fi -> join the Pi's SSID (enter the WPA2 password manually).
   **Observe CNA behavior:** does a "Sign in to network" sheet appear, and does
   dismissing it drop the association?
7. Launch the app, accept the Local Network permission prompt, trigger the health
   fetch. Expect the health view to render a decoded `200` response.
8. Contingency, only if step 7 fails on captive-portal grounds: drop a single
   `/etc/NetworkManager/dnsmasq-shared.d/*.conf` returning NXDOMAIN for Apple's
   captive-probe domains and retry. (No ATS contingency is needed -- the pinned raw IP
   is ATS-exempt.)

**Done when:** step 7 is green (iPhone gets a `200` from `/v1/health` over the Pi's
AP). Step 3 green is the Mac-side milestone that de-risks it.

## Docs / ADRs to update as findings land

Keep the record truthful as hardware reveals reality:

- **`raspi/AGENTS.md`** -- record the concrete AP recipe used (NM profile fields, the
  pinned channel, the `US` regdomain requirement, `10.42.0.1`, the toggle-vs-no-
  concurrency decision with `iw list` evidence, and the WPA2 dev-SSID
  "provisioning-for-now").
- **ADR 02 (`raspi/docs/design/02-...-app-pi-transport-and-api.md`)** -- ADRs are
  append-only: add a **dated note** reconciling the gateway IP to `10.42.0.1`
  (example, Host allowlist, and the app's NWBrowser fixed-IP fallback), and record the
  captive-probe DNS lever's status as either "deferred; not required for this one-shot
  health proof" (do NOT write "not needed" -- that would wrongly weaken ADR 02's
  standing claim that the lever is required for silent no-internet behavior) or
  "applied and verified" if the lever was actually used and confirmed.
- **New ADR 06 (recommended): raspi-side "AP networking / bring-up."** Owns the AP
  plumbing decisions (toggleable hotspot vs AP-only, single-radio rationale, gateway
  IP, channel/regdomain, SSID/password provisioning-for-now, DNS-lever status). Run
  `just adr-check` after adding it.
- **`docs/roadmap.md`** -- check off `pine`'s "bring up the Wi-Fi AP" and "app joins
  the AP and gets a 200" once verified.

## Critical files

- `raspi/AGENTS.md` -- AP recipe, dev-vs-car table, rescue-path docs to update.
- `raspi/docs/design/02-2026-06-22-app-pi-transport-and-api.md` -- gateway-IP
  reconciliation note, captive-probe-lever status.
- `raspi/docs/design/` -- new ADR 06 for AP networking decisions.
- `app/DanCam/DanCam/App/AppDependencies.swift` -- the one app-side base-URL change.
- `raspi/deploy.sh` -- `DANCAM_HOST=<user>@10.42.0.1` override if deploying over the AP.
- `docs/roadmap.md` -- `pine` acceptance criteria to check off.

## Notes

- `plans/wip/peppy-skipping-floyd.md` is a stale/abandoned alternative (it retargets
  to a Pi 3 A+ with 5 GHz). The live hardware decision is the Zero 2 W / 2.4 GHz /
  Trixie / NetworkManager direction; plan against that.
- Root is not yet read-only on `pine`, so writing the AP profile under
  `/etc/NetworkManager/system-connections/` and any dnsmasq drop-in is fine now. When
  root goes read-only in a later hardening pass, those must live in the writable layer
  or be baked into the image -- flag, do not solve here.

## Implementation notes

- Channel 1 was selected for the dev AP after the Pi's Wi-Fi scan showed channel 6
  as the strongest local congestion and channel 1 as the least-bad 1/6/11 option in
  the desk environment.
- The first AP-client proof used a physical iPhone rather than the Mac because joining
  `dancam-dev` from the Mac's only Wi-Fi interface drops `<home-wifi>` and can cut off
  the agent session.
- The captive-probe DNS lever was left unapplied because the one-shot Safari fetch and
  physical app fetch both worked after joining `dancam-dev`; the docs keep it as
  deferred rather than unnecessary.
- Follow-up investigation found no previous-boot journal after reset, so the final
  physical-app restore failure cannot be proven from Pi logs. A controlled current-boot
  test with
  `sudo systemd-run --unit=dancam-restore-home-wifi-test --on-active=90s /usr/bin/nmcli connection up netplan-wlan0-<name>`
  succeeded: the timer fired, NetworkManager deactivated `dancam-ap`, stopped
  shared-mode dnsmasq, rejoined `<home-wifi>`, and got the `192.168.1.160` lease.
  Use the named-unit and absolute-path command form in docs going forward.
- Follow-up persistent-iOS testing found that the iPhone could leave and rejoin
  `dancam-dev`, then reconnect in the app and show camera info without a captive
  sheet blocking or dropping the association. The dnsmasq captive-probe NXDOMAIN
  drop-in remains unapplied. Pi logs showed the iPhone lease at `10.42.0.97`,
  plus DHCP release/reacquisition across the leave/rejoin test. The 12-minute
  named restore timer fired and returned the Pi to `<home-wifi>` at
  `192.168.1.160`.

## Follow Up

- Validate persistent iOS no-internet AP behavior for `dancam-dev`; if the Captive
  Network Assistant blocks or destabilizes reconnects, add and verify a
  `/etc/NetworkManager/dnsmasq-shared.d/` captive-probe NXDOMAIN drop-in. Follow-up:
  iPhone leave/rejoin worked and the app reconnected without captive blocking, so no
  drop-in was applied.
- Investigate why `sudo systemd-run --on-active=5min nmcli connection up
  netplan-wlan0-<name>` did not return the Pi to `<home-wifi>` during the final
  physical-app AP proof; keep power-cycle as the recovery backstop until this is
  understood. Follow-up: previous-boot logs were unavailable after reset, but the
  named-unit absolute-path timer form was verified in the current boot.
- Replace the hardcoded `http://10.42.0.1:8080` health base URL in
  `app/DanCam/DanCam/App/AppDependencies.swift` with the planned discovery/configuration
  path after the first AP health slice. Follow-up: replaced by `AppConfiguration`
  resolving environment, Info.plist, then AP-gateway fallback.
