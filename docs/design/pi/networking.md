# Pi networking

The camera unit provides its own 2.4 GHz Wi-Fi access point so the iPhone can
reach it directly without a router. The Raspberry Pi Zero 2 W has one `wlan0`
radio and no 5 GHz support. The development image switches that radio between
home-client and access-point profiles; it does not attempt concurrent AP and
station operation.

This page owns the Pi's Wi-Fi topology, access-point profile, fixed gateway,
local-name behavior, and safe development toggle. The
[transport boundary](../boundary/transport.md) owns the HTTP and SSE contract
served over the link. Provisioning owns how the profile and Avahi settings are
installed, while the Pi runbook owns the operator commands.

## Access-point profile

NetworkManager owns a hotspot profile named `dancam-ap` on `wlan0`. Its current
settings are:

```text
802-11-wireless.mode                         ap
802-11-wireless.ssid                         dancam-dev
802-11-wireless.band                         bg
802-11-wireless.channel                      1
802-11-wireless-security.key-mgmt            wpa-psk
802-11-wireless-security.proto               rsn
802-11-wireless-security.pairwise            ccmp
802-11-wireless-security.group               ccmp
ipv4.method                                  shared
ipv4.addresses                               10.42.0.1/24
ipv6.method                                  ignore
connection.autoconnect                       no
```

The cipher pins make this WPA2-AES only: no WPA1 and no TKIP. The Ansible
`dev_runtime` role provisions every field except the PSK. The development password is
entered once on the Pi so the secret never enters the repository or playbook. The
shared `dancam-dev` identity is strictly a development profile; production
commissioning uses the per-unit random identity and QR onboarding described below.

NetworkManager shared mode owns connection lifecycle, IPv4 forwarding, DHCP,
and DNS through its private dnsmasq instance. The fixed `10.42.0.1/24` address
gives the app and rescue SSH a stable Pi endpoint. During bring-up, shared-mode
dnsmasq served `10.42.0.10` through `10.42.0.254`.

There is currently no captive-probe NXDOMAIN drop-in under
`/etc/NetworkManager/dnsmasq-shared.d/`. Physical-iPhone leave/rejoin testing
kept the association and restored app traffic without one. Add that lever only
if persistent no-internet joins fail in later on-device testing; it belongs in
NetworkManager's shared dnsmasq, not a separately managed DNS service.

## Radio operating model

The development image keeps its home-Wi-Fi profile as the default autoconnect
connection. Activating `dancam-ap` intentionally tears that client connection
down. Because the AP profile does not autoconnect, a power cycle returns the
development unit to home Wi-Fi.

AP+STA concurrency is excluded. The radio advertises managed plus AP support only
when both share one channel:

```text
* #{ managed } <= 1, #{ AP } <= 1, #{ P2P-client } <= 1, #{ P2P-device } <= 1,
  total <= 4, #channels <= 1
```

Channel-locking the home network and camera AP would make the development link
fragile and provides no benefit in the car. Provisioning therefore runs over
home Wi-Fi, where apt has upstream internet, and AP testing happens afterward.
There is no `10.42.0.1` provisioning path.

The profile pins channel 1. The bring-up environment reported US regulatory
settings with channels 1-11 enabled, no rfkill block, and channel 1 as the
least-congested choice among 1, 6, and 11. A deployment in a different regulatory
domain or RF environment must revalidate that choice rather than treating the
desk scan as universal.

The Ansible production profile prepares persistent NetworkManager state but contains
no AP credential. One-time commissioning creates the distinct persisted `dancam-ap`
profile from the authenticated personalization envelope. Its SSID is
`dancam-<unit-id>`, its WPA2-AES PSK has at least 128 bits of cryptographic entropy,
and it autoconnects because the car has no upstream network. The generic image
contains no production SSID, PSK, or home-Wi-Fi profile. The development profile
remains `dancam-dev`, secret-manual, and non-autoconnecting.

## Local naming

The shared Ansible role owns the hostname `dancam`, installs and enables Avahi in both
profiles, and scopes it to `wlan0` with `allow-interfaces=wlan0` in
`/etc/avahi/avahi-daemon.conf`. The Pi has only one client-facing interface.
Advertising on loopback during early boot allowed Avahi to see its own stale
`dancam.local` publication as a conflict after Wi-Fi appeared, rename the host to
`dancam-2.local`, and leave the intended name unreachable. Scoping publication to
`wlan0` keeps `dancam.local` tied to a reachable address in both home-client and
AP mode.

The app uses `http://dancam.local:8080` on both home Wi-Fi and the AP. The fixed
`http://10.42.0.1:8080` endpoint remains available for operator diagnostics and
rescue access, but it is not the app's configured product endpoint.

## Safe development toggle

Before activating the AP over SSH, schedule a detached NetworkManager revert
owned by systemd:

```sh
sudo systemd-run --unit=dancam-restore-home-wifi --on-active=5min /usr/bin/nmcli connection up <your-home-wifi>
```

The transient timer survives the SSH session disappearing when `wlan0` leaves
home Wi-Fi. A foreground `sleep && nmcli ...` does not. Use a fresh unit name if
the prior transient unit is still loaded, and inspect the return path with:

```sh
journalctl -b -u dancam-restore-home-wifi.service -u dancam-restore-home-wifi.timer
```

Power cycling remains the backstop for the development image. During an
API-backed coding session, do not join `dancam-dev` from the Mac's only Wi-Fi
interface when that interface also carries the session. Use the physical iPhone
or a second Wi-Fi adapter as the AP client.

With the service deployed, the current reachability smoke is an iPhone joined to
`dancam-dev` receiving `200` and the canonical snapshot from:

```text
http://dancam.local:8080/v1/status
```

## Decision log

### 2026-06-25 -- Use a toggleable NetworkManager access point

(absorbed from raspi ADR 06, 2026-06-25)

The first hardware pass needed to prove that an iPhone could reach the camera
directly while preserving a fast home-Wi-Fi deploy loop. Raspberry Pi OS Trixie
already used NetworkManager, so a toggleable `dancam-ap` shared-mode profile was
chosen over replacing the network stack. The proof target was intentionally
narrow: join the AP and receive a successful service response at the Pi's fixed
address.

The fixed `10.42.0.1/24` gateway works with NetworkManager's native `10.42.x.0/24`
shared-mode behavior and prevents the third octet from changing to avoid a route
conflict. This keeps app fallback, rescue SSH, and operator documentation stable.
NetworkManager's own dnsmasq was observed serving `10.42.0.10` through
`10.42.0.254`; client leases included `10.42.0.151` and, in later rejoin testing,
`10.42.0.97`.

The physical iPhone joined `dancam-dev`, Safari fetched the then-current
`/v1/health` response, and the app rendered the same health data from the AP
gateway. An initial captive sign-in sheet could be dismissed, and later leave and
rejoin testing restored the app connection without a captive sheet blocking or
dropping the association. One attempted persistent test instead found the AP
already down after the Pi had returned to home Wi-Fi; that was not evidence about
captive behavior. These results deferred, but did not permanently rule out, a
captive-probe DNS override.

The named systemd revert was validated with the absolute `/usr/bin/nmcli` path:
it deactivated the AP, stopped shared-mode dnsmasq, rejoined the home profile, and
reacquired its LAN address after the initiating SSH connection had disappeared.
A previous failed proof could not be diagnosed because the development image then
lacked previous-boot logs. The power-cycle fallback was retained.

Avahi also exposed a concrete boot race. The Pi advertised as
`dancam-2.local`; restarting Avahi reclaimed `dancam.local`, and scoping it to
`wlan0` made that name survive both reboot and an AP-to-home toggle. This is why
the interface restriction is part of network correctness rather than cosmetic
configuration.

An AP-only car image was rejected for the initial development pass because it
would slow deploy and debugging before the production image existed. AP+STA
concurrency was rejected because the Zero 2 W permits it only on one shared
channel, coupling the camera AP to the home network for no in-car benefit. A
custom hostapd/dnsmasq stack was rejected because NetworkManager shared mode
already owns those functions on Trixie. `192.168.4.1` was rejected because
`10.42.0.1` follows NetworkManager's natural address family instead of fighting
the tool.

The bring-up left discovery, configurable app endpoints, production AP
autoconnect, and per-unit credentials to later product work. The direct fixed-IP
path was sufficient to prove the physical link.

### 2026-06-25 -- Pin the hotspot to WPA2-AES

(amendment absorbed from raspi ADR 06, 2026-06-25)

The original WPA2-PSK profile still advertised TKIP, which caused iOS to label the
network "Weak Security (WPA/WPA2 TKIP)." Pinning RSN protocol with CCMP pairwise
and group ciphers removed WPA1/TKIP from the beacon and cleared the warning.

WPA3-SAE was considered and deferred. It required a separate Zero 2 W AP-mode
validation pass and offered little practical gain for the local preview-and-pull
link compared with a strong WPA2-AES secret. Unique per-unit credentials, not a
WPA2-to-WPA3 switch, remained the more meaningful production hardening.

### 2026-07-15 -- Use canonical status for the AP smoke test

(amendment absorbed from raspi ADR 06, 2026-07-15)

The early proof used `/v1/health`, which was later retired when operational state
converged on the canonical `/v1/status` snapshot. AP reachability verification now
uses `/v1/status`; this changes only the smoke-test route, not the Wi-Fi topology or
profile.

### 2026-07-17 -- Personalize an autoconnecting production AP

Whole-card flashing now creates an independent random identity and WPA2-AES secret
for every card. Commissioning persists that profile and production autoconnects it;
development deliberately keeps the shared, manual, non-autoconnect profile. A shared
production PSK and manual password entry were rejected because either would leave the
one-command card and QR onboarding story incomplete.

### 2026-07-20 -- Make the production image own its mDNS identity

The first production-card bring-up exposed that the image edited Avahi's interface
scope without setting the promised `dancam` hostname or explicitly enabling the
daemon. Neither `dancam.local` nor the inherited `raspberrypi.local` name resolved
from the attached iPhone, even though the fixed gateway served the API. The image
now owns the hostname, enabled daemon, and `wlan0` scope together. The app continues
to use `dancam.local`; the fixed gateway remains a diagnostic and rescue address.
