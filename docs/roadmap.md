# dancam roadmap -- breadth-first swoops

> Linked from the root `AGENTS.md`. Kept here rather than inline so AGENTS.md stays
> lean -- AGENTS.md is loaded into every agent context, the roadmap is not.

We build this like sculpting clay, not stacking bricks: **breadth-first swoops**.
Each swoop is a thin slice across the whole pipeline (Pi -> Wi-Fi -> app) that
ends in something we can actually see or use. Later swoops deepen earlier ones
rather than bolting on isolated parts. The deep ADRs (storage ring buffer,
crash-safe recording) are the *north star* for the deepening passes -- not the
spec for the early swoops. Start dumb, get footage moving, harden later.

This list is **loose and reorderable.** Order is a default, not a contract; near-
term swoops are detailed, later ones are one-liners we'll flesh out when we reach
them. Each swoop carries a short **codename** (a stable handle) instead of a number,
so swoops can be reordered or inserted without renumbering -- list position, not the
name, conveys the default order. Two tracks run in parallel: a **mock Pi** (a small
fake local server with canned status + sample frames/clips) so app work never blocks
on hardware, and the **real Pi** firmware. Each app swoop should pass against the
mock first.

- [ ] **Swoop `oak` -- Bring-up + mock.** Real Pi: flash Raspberry Pi OS (64-bit) with
      read-only root, bring up the Wi-Fi AP (hostapd + dnsmasq), get the camera
      capturing, and serve a minimal `GET /v1/health` over HTTP. App: join the AP
      and get a 200 back. Stand up the **mock Pi** server in parallel. (Skip the
      hardware half fast if it's already done.) *Foundation for everything below.*
- [ ] **Swoop `fox` -- Live preview on iPhone.** Pi serves `GET /v1/preview/live.mjpeg`
      (MJPEG from the libcamera lores stream, never the H.264 encoder). App joins
      the AP, opens a pinned `NWConnection`, parses `multipart/x-mixed-replace`,
      and shows the live view on screen. *This is the first "it works!" moment.*
      Preview here need not run while recording (sidesteps the headline spike);
      *spike: confirm `NWConnection` Wi-Fi pinning + no-internet-AP / captive-probe
      handling behaves.*
- [ ] **Swoop `jet` -- Recording control + live status.** Start/stop recording buttons
      in the app (`POST /v1/recording/start|stop`); a status readout (recording
      on/off, storage left, temps) that updates as it changes (SSE
      `GET /v1/events`). *Spike: can MJPEG preview run concurrently with the
      1080p30 H.264 recording? If not, preview falls back to "when stopped."*
- [ ] **Swoop `kelp` -- SD card management.** Pi detects the card and surfaces issues
      (missing / unformatted / wrong filesystem); auto-format on first insert;
      format-from-app with a double-confirm (`POST /v1/storage/format`).
- [ ] **Swoop `lime` -- Watch recorded clips.** Browse a clip list (`GET /v1/clips`),
      pull one with resumable `Range` requests, play it via a local HLS playlist +
      AVPlayer on a loopback server. *The chunky one; now that recording exists, it
      pays off. Spike: 2.4 GHz in-car throughput / pull times.*
- [ ] **Swoop `moss` -- Time provenance.** `POST /v1/time` at handshake (the Pi has no
      RTC); "time unverified" UI until sync; timestamps on clips.
- [ ] **Swoop `nova` -- Incident lock (manual).** A "save this moment" button: Pi
      force-finalizes the open segment and protects the window. Start with a dumb
      hardlink lock; *deepen toward the storage ADR (idempotency, pre-sync holds)
      later.*
- [ ] **Swoop `opal` -- Connection robustness.** Persistent auto-rejoin
      (`NEHotspotConfiguration`, `joinOnce = false`); offline detection via missed
      heartbeats -> alert; back-off reconnect; resume pulls across drops.
- [ ] **Swoop `reef` -- CarPlay auto start/stop** on CarPlay connect/disconnect.
- [ ] **Swoop `sage` -- CarPlay status panel** (Driving Task template). *Gated on the
      Apple entitlement; the product must be useful without it.*
- [ ] **Swoop `tide` -- Export / share.** TS -> MP4 passthrough remux to Photos /
      AirDrop (export-only, off the playback path).
- [ ] **Swoop `vine` -- Power-loss hardening for real.** Power-good GPIO + clean
      shutdown; supercap go/no-go; validate crash recovery in the actual car.
- [ ] **Later / deepening passes.** Thermal-behavior policy (what recording does at
      the sensor's 50 C limit); HDR tuning; auth hardening (token, then pinned-cert
      TLS); GPS time source; parked / sentry mode (gated on a future constant-power
      topology -- v1 power is switched / drive-only, see the power-source ADR).

## Icebox (someday-maybe -- parked, not on the near path)

Whole swoops we've deliberately set aside; we won't think about them until something
changes. Distinct from the deepening passes above (those go deeper on swoops we *will*
build) -- these may or may not ever happen. They keep their codenames so a parked
swoop can drop into the list above unchanged. Unordered.

- [ ] **Swoop `pike` -- CarPlay voice incident-mark.** App Intents "save that clip,"
      hands-free, with queue-and-flush on the cold path. No entitlement needed, but
      **very low priority**: the on-phone "save this moment" button (swoop `nova`)
      already covers the core need, so hands-free voice marking is just convenience on
      top. Revisit only if voice marking proves worth it in the car.
