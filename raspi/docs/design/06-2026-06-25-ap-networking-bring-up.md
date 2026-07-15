# ADR: AP networking bring-up

- **Status:** Accepted
- **Amended:** 2026-06-25 -- cipher pinned to RSN/CCMP (AES); no TKIP/WPA1.
- **Amended:** 2026-07-15 -- AP reachability smoke now uses canonical
  `/v1/status`; see ADR 24.
- **Date:** 2026-06-25
- **Owner:** raspi
- **Related:** root `AGENTS.md`; `02-2026-06-22-app-pi-transport-and-api.md`
  (the wire contract served over this link); `raspi/AGENTS.md` (operator-facing
  AP recipe)

## Context

The camera unit must run its own 2.4 GHz Wi-Fi access point so the iPhone can
connect directly with no router. The early dev image still joins home Wi-Fi as a
client for build/deploy iteration, so the first AP bring-up needs a toggleable
profile and a recovery path that survives dropping the SSH session.

The hardware is a Raspberry Pi Zero 2 W on Raspberry Pi OS Lite 64-bit Trixie,
using NetworkManager. The real proof target for this pass was intentionally
narrow: an iPhone joins the Pi AP and gets a `200` from `GET /v1/health` at the
Pi's AP address.

## Decision

Use a **toggleable NetworkManager hotspot profile** named `dancam-ap`, disabled
by default:

- `802-11-wireless.mode ap`
- SSID `dancam-dev`
- WPA2-PSK pinned to AES (RSN proto, CCMP pairwise + group; no TKIP/WPA1)
  with a manually-entered dev password:
  - `802-11-wireless-security.key-mgmt wpa-psk`
  - `802-11-wireless-security.proto rsn`
  - `802-11-wireless-security.pairwise ccmp`
  - `802-11-wireless-security.group ccmp`
- `802-11-wireless.band bg`
- pinned channel `1`
- `ipv4.method shared`
- `ipv4.addresses 10.42.0.1/24`
- `ipv6.method ignore`
- `connection.autoconnect no`

The home-Wi-Fi profile, `<home-wifi>`, remains the default
autoconnect profile on the dev image. Bringing `dancam-ap` up intentionally
tears down the home-Wi-Fi client connection; a power cycle returns to home Wi-Fi
because the AP profile does not autoconnect.

Pin the AP gateway to **`10.42.0.1`**. NetworkManager shared mode naturally uses
the `10.42.x.1/24` range and starts its own dnsmasq instance, but without an
explicit address it can choose a different third octet to dodge route conflicts.
Pinning `10.42.0.1/24` keeps rescue SSH, app fallback, and documentation stable.

Skip AP+STA concurrency. The radio advertises AP mode, but its interface
combination stanza allows managed + AP only with `#channels <= 1`:

```
* #{ managed } <= 1, #{ AP } <= 1, #{ P2P-client } <= 1, #{ P2P-device } <= 1,
  total <= 4, #channels <= 1
```

That means a concurrent home-client plus AP setup would be channel-locked and
fragile, and it buys nothing in the car where there is no home Wi-Fi to keep.
For dev, flip between profiles.

The selected regulatory/channel facts from bring-up:

- `iw reg get` reported global country `US`; channels 1-11 were enabled for
  2.4 GHz operation.
- `rfkill list` reported Wireless LAN soft-blocked `no`, hard-blocked `no`.
- The interface is `wlan0`.
- The scan showed channel 6 as the most congested local option; channel 1 was the
  least-bad choice among 1/6/11 for this desk bring-up.

Scope Avahi/mDNS to `wlan0` with `allow-interfaces=wlan0` in
`/etc/avahi/avahi-daemon.conf`. The Pi has only one useful client-facing network
interface, and advertising on loopback during early boot creates a real failure
mode: Avahi can later treat its stale `dancam.local` publication as a conflict
when Wi-Fi comes up, rename the host to `dancam-2.local`, and leave
`dancam.local` unresolved from the Mac. Restricting Avahi to `wlan0` keeps the
published name tied to the reachable Wi-Fi address in both home-client and AP
mode.

Before flipping to AP mode over SSH, schedule a detached NetworkManager revert
owned by systemd:

```sh
sudo systemd-run --unit=dancam-restore-home-wifi --on-active=5min /usr/bin/nmcli connection up <your-home-wifi>
```

Do not rely on a foreground `sleep && nmcli ...` in the SSH session; the session
dies when the radio leaves home Wi-Fi. The transient systemd timer survives the
SSH drop and is the intended automatic return path. Use a fresh `--unit` name if
that unit is already loaded, and inspect the timer/service after return with:

```sh
journalctl -b -u dancam-restore-home-wifi.service -u dancam-restore-home-wifi.timer
```

Keep the power-cycle backstop: it always returns this dev image to the autoconnect
home profile. In follow-up on 2026-06-25, the earlier physical-app proof failure
could not be proven from logs because the dev image had no previous-boot journal
after reset. A controlled current-boot test using the named unit and absolute
`/usr/bin/nmcli` path did succeed: systemd fired the timer, NetworkManager
deactivated `dancam-ap`, stopped the shared-mode dnsmasq, rejoined `<home-wifi>`,
and reacquired `192.168.1.160`.

Verification from this bring-up:

- NetworkManager started hotspot `dancam-dev` on channel 1.
- NM shared-mode dnsmasq served DHCP range `10.42.0.10` through
  `10.42.0.254`.
- A client lease was observed at `10.42.0.151`.
- An iPhone joined `dancam-dev` and Safari fetched
  `http://10.42.0.1:8080/v1/health`, receiving the service's JSON health
  response.
- After the app health client was repointed at `http://10.42.0.1:8080`, the app
  running on a physical iPhone also rendered the health response while joined to
  `dancam-dev`.
- iOS showed a captive sign-in sheet naming `xfinity` during the test, but
  dismissing it, reconnecting to `dancam-dev`, and fetching the fixed IP worked.
  The captive-probe DNS lever remains deferred; this one-shot proof did not need
  it, but it does not disprove ADR 02's requirement for robust persistent
  no-internet joins.
- A later attempted persistent-iOS test found `dancam-dev` unavailable because the
  Pi had already reset back to home Wi-Fi; that is not evidence about captive
  behavior.
- Follow-up persistent-iOS testing on 2026-06-25 found that a physical iPhone
  running the latest app could leave and rejoin `dancam-dev`, reconnect to the
  app, and fetch camera health info without a captive sheet blocking or dropping
  the association. NetworkManager's shared dnsmasq logged the client lease at
  `10.42.0.97`, then a DHCP release and reacquisition during the leave/rejoin
  test. Therefore no `/etc/NetworkManager/dnsmasq-shared.d/` captive-probe
  NXDOMAIN drop-in is applied in this dev image yet.
- Follow-up mDNS testing on 2026-06-25 found the Pi advertising as
  `dancam-2.local` after a boot-time Avahi conflict. `dancam-2.local` resolved
  and served `/v1/health`, while `dancam.local` timed out. Restarting Avahi
  reclaimed `dancam.local`; adding `allow-interfaces=wlan0` made the fix survive
  a reboot and a `dancam-ap` -> `<home-wifi>` toggle. After the change,
  `curl http://dancam.local:8080/v1/health` returned `200` and Avahi stayed
  `running [dancam.local]` with no conflict retry.

During an API-backed coding session, do not use the Mac's only Wi-Fi interface
as the AP client. Joining `dancam-dev` from the Mac drops `<home-wifi>` and can
cut off the agent session. Use a physical iPhone or a second Wi-Fi adapter for
AP client verification.

## Consequences

- The dev loop stays simple: deploy over home Wi-Fi, flip the AP only when
  testing the direct link, then use the systemd timer or power-cycle backstop to
  return to home Wi-Fi.
- App and operator docs can target the stable AP gateway
  `http://10.42.0.1:8080`.
- Amendment record, 2026-06-25: pinning CCMP-only removes TKIP from the AP
  beacon, which clears iOS's "Weak Security (WPA/WPA2 TKIP)" warning.
- WPA3-SAE was considered and deferred. It is out of scope for this warning fix,
  would need a separate AP-mode validation pass on the Zero 2 W, and adds
  negligible practical gain for this local preview-and-pull link with a strong
  WPA2-AES PSK.
- The AP profile is not the final provisioning story. Per-unit random SSID/PSK
  plus QR-based onboarding remains a later hardening pass.
- Persistent no-internet behavior is still open. The dnsmasq captive-probe lever
  should be applied only if future persistent join tests show it is needed, and
  then verified on-device. The current physical iPhone reconnect test did not
  require it.
- The current app health slice targets the AP gateway directly. Discovery,
  per-unit provisioning, and a configurable base URL remain later app work.

## Alternatives considered

- **AP-only car image from the start.** Rejected for this pass because it would
  make early deploy/debug loops harder. The toggleable dev profile gives the same
  AP behavior while preserving home-Wi-Fi recovery.
- **AP+STA concurrency.** Rejected because the Zero 2 W radio only allows managed
  + AP with `#channels <= 1`; channel-locking the home client and the AP is
  fragile and irrelevant in the car.
- **A custom hostapd/dnsmasq setup.** Rejected for now. NetworkManager shared mode
  already starts dnsmasq and owns the connection lifecycle on Trixie.
- **`192.168.4.1` as the AP address.** Rejected because NetworkManager shared mode
  naturally operates in `10.42.x.0/24`; using `10.42.0.1` works with the tool
  instead of fighting it.
