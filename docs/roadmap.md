# dancam roadmap

> Linked from the root `AGENTS.md`. Kept here rather than inline so AGENTS.md stays
> lean -- AGENTS.md is loaded into every agent context, the roadmap is not.

Each **swoop** below is a feature we build to last -- a codenamed unit of work across
the pipeline (Pi -> Wi-Fi -> app). When we build one, we build it forward-thinking,
durable, and robust: the real version, not a transient stub we plan to harden later.
A swoop is "done" only when it is the design we'd defend, so the next swoop builds
*on* it rather than *around* a shortcut. The deep ADRs (storage ring buffer,
crash-safe recording) are the spec we build toward, not a someday-deepening pass.

When we genuinely don't yet know whether an approach works -- a Wi-Fi pinning trick, a
remux path, thermal headroom -- we answer that with a **throwaway spike**: code written
to be deleted, run just far enough to learn the thing. The committed swoop is then
built properly on what the spike taught us. Spikes de-risk; they never ship as the
feature.

This list is **loose and reorderable.** Order is a default, not a contract; near-
term swoops are detailed, later ones are one-liners we'll flesh out when we reach
them. Each swoop carries a short **codename** (a stable handle) instead of a number,
so swoops can be reordered or inserted without renumbering -- list position, not the
name, conveys the default order. Two tracks run in parallel: a **mock Pi** (a small
fake local server with canned status + sample frames/clips) so app work never blocks
on hardware, and the **real Pi** firmware. Each app swoop should pass against the
mock first.

- [x] **Swoop `oak` -- Mock bring-up, no hardware.** Mac-only setup that unblocks
      app work before the Raspberry Pi arrives: make the mock Pi service runnable
      from the dev machine, give agents a documented local command loop, and let
      the app point at that mock service and get a 200 back. _Foundation for
      everything below without needing the Pi on the desk._
      - [x] Mock Pi service runs locally and answers the health endpoint.
      - [x] App can call the mock Pi health endpoint.
- [x] **Swoop `pine` -- Real Pi bring-up.** Hardware track for the same health slice:
      flash Raspberry Pi OS Lite (64-bit, Trixie), bring up the Wi-Fi AP
      (NetworkManager hotspot, 2.4 GHz), get the camera visible/capturing at a
      basic smoke-test level (`camera_auto_detect=0` + `dtoverlay=imx708`),
      deploy/run the Rust service on the Pi, serve real `GET /v1/health` over
      HTTP, and have the app join the AP and get a 200 back. Read-only root can
      wait until hardening; do not block first hardware contact on the final
      car-image layout.
      - [x] Camera is visible to `rpicam` and captures a JPEG after
            `camera_auto_detect=0` + `dtoverlay=imx708`.
      - [x] Rust service deploys to the Pi and serves `GET /v1/health` over home
            Wi-Fi.
      - [x] NetworkManager AP profile `dancam-ap` starts `dancam-dev` on channel 1
            with gateway `10.42.0.1` and shared-mode DHCP.
      - [x] A physical iPhone joins `dancam-dev` and gets health JSON from
            `http://10.42.0.1:8080/v1/health` in Safari.
      - [x] App running on a physical iPhone renders the AP health response.
- [x] **Swoop `fox` -- Live preview on iPhone.** Pi serves
      `GET /v1/preview/live.mjpeg`; for this swoop the real camera backend uses a
      temporary preview-only MJPEG stream from `rpicam-vid`, not the later
      lores-while-recording path. App joins the AP, opens a pinned `NWConnection`,
      parses `multipart/x-mixed-replace`, and shows the live view on screen. _This is
      the first "it works!" moment._ Preview here need not run while recording
      (sidesteps the headline spike); _spike confirmed: `NWConnection` Wi-Fi pinning
      reached the Pi over the no-internet AP with cellular on, and no captive sheet was
      observed._
- [x] **Swoop `jet` -- Recording control + concurrent preview.** Lean end-to-end
      recording control is done: a Picamera2 camera-owner subprocess, supervised
      Rust fan-out, `POST /v1/recording/start|stop`, real `/v1/health.recording`,
      mutation hardening for the new POSTs, and app Record / Stop Recording controls
      on the live-preview screen. Dan confirmed the mock/Xcode path and the real-Pi
      recording path; the real Pi then passed a 30 min desk soak with simulator
      preview open, recording active, clean `.ts` segments, no timestamp warnings,
      stable SoC temperature, and no active swap churn. The richer "live status"
      work was intentionally split out rather than stretched into this slice.
- [x] **Swoop `fern` -- Home camera dashboard.** Make the app's first screen the
      operational surface instead of a health/check screen: live preview is always on
      top when connected, recording state + one Start/Stop control sit with the
      preview, and a simple non-interactive list of finished segment files appears
      below. Drive the API from that UI; keep `/v1/health` small and boring as a
      cheap liveness probe, not a user screen.
      - [x] Replace the health-first root with a home dashboard that starts preview
            immediately and keeps recording controls on that same screen.
      - [x] Add `GET /v1/status` for dashboard facts: recording state, camera state,
            boot/uptime, rec-dir storage, SoC temperature, memory/swap headroom, and
            sensor temperature when Picamera2 metadata is surfaced.
      - [x] Add the smallest useful `GET /v1/clips` metadata list for finished `.ts`
            segments: filename/id, bytes, and best-effort time/duration when cheap.
      - [x] Render the finished-segment list below preview as read-only rows; playback,
            thumbnails, selection, and pull/download stay in `lime`.
      - [x] Deepening: Recent clips now shows the Pi recorder state machine's open
            segment as a synthetic live status row with a `REC` badge and count-up,
            while the Pi keeps the open segment unlisted and unpullable.
      - [x] Started with polling `status`/`clips`; `pulse` replaced live state polling
            with snapshot-first `GET /v1/events`, while `/v1/status` and `/v1/clips`
            remain one-shot reads.
- [x] **Swoop `loam` -- Declarative Pi provisioning.** Replace the manual README
      bring-up runbook (the apt / config.txt / avahi / locale / nmcli steps `pine`
      established by hand) with one idempotent Ansible playbook, run from the Nix
      shell over SSH. `just raspi-provision` converges a freshly-flashed Pi to the
      full system state; `deploy.sh` keeps owning the fast app loop; the README drops
      to a thin bootstrap/verify/ops runbook. _Deepens `pine`: its hand-built
      foundation becomes declarative, re-runnable, and diffable (`--check --diff`).
      The "it works" moment is a re-run printing `changed=0`._
      - [x] Ansible ships in the Nix shell (`nix develop -c ansible --version`) and
            the `raspi-provision` / `-check` / `-lint` Just recipes exist.
      - [x] Flat playbook (`raspi/ansible/site.yml`, 8 tasks + 2 handlers) passes the
            Mac-only gate: `just raspi-provision-lint` green (syntax-check + ansible-lint).
      - [x] One `just raspi-provision` converges a fresh Pi (apt, camera overlay, mDNS
            scope, locale, AP profile, `video` group) + one reboot; a re-run prints
            `changed=0` (idempotency gate -- catches the nmcli cipher-list churn).
      - [x] Real-Pi regression checks pass: picamera2 imports, `allow-interfaces=wlan0`
            (no spaces), AP cipher pins `rsn`/`ccmp`/`ccmp`, iPhone joins `dancam-dev`,
            `dancam` service user has `video`, and the service opens the camera as
            `dancam`.
      - [x] Docs land in lockstep: ADR 09 (`just adr-check` green), README renumbered to
            the pinned 8-section runbook, `raspi/AGENTS.md` flipped to "playbook is the
            source of truth."
- [x] **Swoop `opal` -- Connection robustness.** Keep the app usable across a flaky
      2.4 GHz link: detect drops fast, ride them out in place, and recover without a
      manual rejoin. _App-side ambient UX and resumable pulls have landed; measured
      pull UX now continues in `lime`._
      - [x] **App:** scene-scoped `/v1/status` monitor -- debounced liveness owned by the
            scene (not the home dashboard), preserving last-known status so screens ride
            out drops in place.
      - [x] **App:** missed-heartbeat offline detection -- a missed `/v1/status` heartbeat
            flips to offline after the debounce window.
      - [x] **App:** persistent connection status strip in the root shell, so pushed
            screens inherit it without nav-bar re-parenting.
      - [x] **App:** foreground/reconnect recovery -- foreground and reconnect hooks
            refresh the visible screen without tearing down navigation state.
      - [x] **App:** preview back-off reconnect -- preview reconnects independently with
            bounded backoff; each attempt bumps `streamGeneration` so decode resets stay
            observable.
      - [x] **App:** domain root store -- connection/recording/clips coordination moves
            into `AppFeature` with equality-gated scoped observation, cutting poll-driven
            wakeups.
      - [x] **App:** resumable pulls across drops -- a `Range`/`If-Range` clip pull that
            resumes from the last byte rather than restarting. _Shared with `lime`'s
            ranged-pull step; land it in whichever swoop reaches it first._
      - Note: app-driven AP join (`NEHotspotConfiguration`, `joinOnce = false`) is *not* an
        opal item -- a manually-saved `dancam-dev` already auto-rejoins at the OS level.
        The programmatic provisioning that drops the manual Settings join (per-unit
        SSID/PSK from the QR sticker) is owned by `wren`, gated on a production image plus
        the Hotspot Configuration entitlement.
- [x] **Swoop `pulse` -- Event-folded recorder state.** Replace the poll-era status
      and clips loops with the realized `/v1/events` plane: the Pi owns recorder phase,
      session, current segment, and clips exclusion; the app folds snapshot-first SSE
      into one `Link` world and treats heartbeat presence as connection truth.
      _Deepens `fern` and `opal`: the dashboard row and connection strip now ride the
      same recorder-owned event stream instead of filesystem guesses and status-poll
      debounce._
      - [x] `GET /v1/events` streams snapshot, ordered deltas, and 2 second heartbeats;
            `GET /v1/status` remains a one-shot `Snapshot`.
      - [x] Recorder lifecycle transitions are first-class events, including command
            phases, segment opens, clip finalization, failure, and telemetry deltas.
      - [x] The camera child protocol carries Rust-owned `session_id` and
            `start_segment_index`, plus session-echoing segment lifecycle events.
      - [x] App connection state is `Link`, with offline detection after about 6 seconds
            of missed heartbeats and fresh snapshot recovery on reconnect.
      - [x] Recent clips keep a live row only when the Pi recorder snapshot reports a
            current segment; finalized clips merge from `clip_finalized` events.
- [x] **Swoop `lime` -- Watch recorded clips.** Browse the clip list, pull a finished
      segment with resumable `Range` requests, remux it to a local `.mp4`, and play it
      with AVPlayer. _The chunky one; the first time footage is
      watchable on the phone. A full 30 s segment is ~38 MB (10 Mbps CBR, confirmed on
      real `seg_*.ts`), so the pull -- not the UI -- is the weight here._
      - [x] **Spike first (real Pi):** Dan confirmed real ~38 MB `seg_*.ts` pulls over
            the `dancam-dev` AP feel acceptable, including desk and in-car checks with
            and without live preview running concurrently (spike 2); pulled `.ts` files
            remux to playable, seekable `.mp4` files on a physical iPhone (spike 5a).
            ADR 13 later removed the progressive local fMP4 path after remux measured
            cheap; cached fast-start MP4 is now the sole playback artifact.
      - [x] **Pi (plain serve):** `GET /v1/clips/{id}` serves a finished segment's raw
            `.ts` as a plain `200` (`application/mp2t`); never serves the open segment
            (matches the list). The dumbest end-to-end that proves tap -> pull -> play; no
            ranged-pull surface until the app step below needs it.
      - [x] **Pi (ranged/resumable):** add `Accept-Ranges: bytes`, `ETag` (reuse the
            list's `{seq}-{bytes}`), `Range`/`If-Range` -> `206`/`Content-Range`, and
            `416` on unsatisfiable range -- pulled in by the app's progress + mid-pull
            resume step below, not before.
      - [x] **Pi:** report `dur_ms` from an exact cached TS-PTS duration span
            (`(maxPTS - minPTS) + frame_interval`) for each finished segment, pivoting
            from the earlier cadence-constant/ffprobe sketch; `start_ms` and real
            provenance stay deferred to `moss`.
      - [x] **Pi/App:** Pi paginates `/v1/clips` by descending `seq`; the app pages
            older clips in on scroll so the home "Recent clips" list can reach beyond
            the first server page.
      - [x] **Mock parity:** mock Pi serves a real sample `.ts` for `GET /v1/clips/{id}`,
            tracking the Pi in the same two pulses -- plain `200` first, then `Range`/`ETag`
            -- so the app pull + playback path runs against the mock first at each step.
      - [x] **App (riskiest):** resumable ranged pull on the pinned `NWConnection` -- a
            `Range`/`If-Range`/`Content-Range` loop that streams to a local file and
            resumes from the last byte across drops (verify `ETag` before resuming). At
            ~38 MB over a congested 2.4 GHz link a pull is ~6-26 s, so a mid-pull drop
            must resume, never restart.
      - [x] **App:** durable clip cache -- fast-start MP4s named by clip id + resolved
            etag, reused on replay (never re-pull 38 MB), with an mtime-LRU size cap.
            The cached MP4 is reused later by `tide` export.
      - [x] **App:** download-then-play -- remux the pulled `.ts` to a local
            passthrough `.mp4`, commit it to the clip cache, and play it directly with
            AVPlayer; keeps AVPlayer on a local file (no-internet AP + future-TLS) and
            gives the player an MP4 sample table for scrubbing.
      - [x] **App:** tapping a clip pushes a viewer screen (AVPlayer + transport
            controls) into the existing nav, showing pull **progress** (a 6-26 s silent
            spinner reads as a hang), a short preparing phase, and then the cached MP4;
            handles pull failure / resume, cache-insert failure, playback failure, and
            manual Retry.
      - [x] **App:** clip rows show duration + best-effort created time + a real first-frame
            thumbnail generated on the phone (app ADR 16): cache-first
            memory/disk/free-cached-MP4/ranged-prefix pipeline. Watched clips are free (the
            phone has the bytes); not-yet-watched clips ranged-*read* a ~2 MB prefix -- no Pi
            writes, no `/thumb` endpoint.
      - Scope fence: one finished segment per clip (no multi-segment timeline), no export
        (`tide`), no real timestamps (`moss`), no locked/incident clips (`nova`). Thumbnails
        are generated client-side per app ADR 16, which supersedes ADR 02's Pi-generated
        `/thumb` (and the cached `seg-<seq>.jpg` in raspi ADR 03) for both the pulled and
        not-yet-pulled cases -- no server-side browse thumbnails.
- [x] **Swoop `ebb` -- Delete recorded clips.** Let the app remove a single finished
      clip from the Pi via Home swipe-to-delete or the clip-viewer Delete button, with a
      destructive confirmation and optimistic row removal. Builds on `lime`'s browse/watch
      UI and ADR 16's storage coordinator: the Pi serves `DELETE /v1/clips/{id}`, refuses
      active/below-floor violations, write-ahead-raises `state/state.json`
      `high_water_seq` before unlinking every path for the id, and emits `clip_removed`
      after durable success so every connected client reconciles. This is clip-level
      footage removal, not `kelp`'s card-level format/SD-management work.
- [ ] **Swoop `dune` -- SD card layout migration.** Move the Pi onto the final
      crash-safe card layout before `kelp`: four MBR partitions, a plain read-only root
      for the car image, `/persist` for OS state, `/data` for the recording ring, and
      no overlayfs or consumer-card PLP assumptions. _This is the storage foundation
      that makes later card formatting safe instead of a directory cleanup._
      - [ ] Service durability + mount witness: fsync closed segments before events,
            fdatasync the in-flight segment every ~2 s and scrub unrecoverable
            zero-byte leftovers at boot witness-first (ADR 19), add mock parity, and
            gate recording/time-sync mutations on a mounted `/data`.
      - [ ] Partition tooling: on-Pi `sfdisk`/`resize2fs` script, Mac regression for
            the sector math, Just recipes, and README bring-up steps.
      - [ ] Dev-shared adoption: Ansible mounts `/persist`, `/data`, and the journald
            bind; deploys `/data/rec` with `DANCAM_REQUIRE_REC_MOUNT=/data`; enables
            fstrim and dirty-page clamps; reflashes the current dev card.
      - [ ] Car-image hardening: `car_image`-gated read-only root/boot, tmpfs and
            `/persist` binds for writable OS state, read-only-root-aware deploy, and
            bench power-cut validation.
- [ ] **Swoop `kelp` -- SD card management.** Pi detects `/data` issues and surfaces
      them to the app (missing / unformatted / wrong filesystem); auto-format on first
      insert; format-from-app with a double-confirm (`POST /v1/storage/format`). After
      `dune`, "format the SD" means mkfs of `/data` only -- never the OS or `/persist`.
      The app-facing storage/card-health UI belongs here; `dune` only provides the
      lower-level layout and fail-closed mount witness.
- [x] **Swoop `moss` -- Time provenance.** The Pi has no RTC, so clip timestamps are
      derived from immutable segment facts plus a per-boot phone-clock offset rather
      than stored as wall-clock conclusions. This makes pre-sync and power-cut
      segments resolve once the boot offset is known.
      - [x] **Pi:** stamp segment filenames with `(seq, boottag, monoMs)` facts at
            segment open, parse bare and stamped names everywhere, and keep next-seq /
            list / pull / status resolution scan-based so stamped footage is never
            overwritten or hidden.
      - [x] **Pi:** add the write-once per-boot offset store and `POST /v1/time`; derive
            clip `start_ms`, `time_approximate`, `server_time_ms`, snapshot
            `time.synced`, and `time_synced` events from the offset.
      - [x] **App:** POST the phone's current epoch on unsynced snapshots, retry while
            connected and unsynced, reload clips on `time_synced`, and show "Time
            unverified" until the world reports synced.
      - [x] **Mock parity:** both the Rust mock backend and Python fake camera exercise
            stamped segment names so Mac-only tests cover the production path before
            real-Pi validation.
      - Scope fence: no GPS source, no correction/rebind after the first accepted
        per-boot offset, no multi-segment timeline, and no incident pre-sync holds
        until `nova`.
- [ ] **Swoop `sift` -- Find clips in the Recent list.** Make the finished-clip list
      navigable when the user knows roughly when footage happened, building on
      `moss` time provenance and the existing `/v1/clips` listing rather than adding a
      new browsing surface.
      - [x] Group Recent clips under sticky day headers, with undated footage kept in
            in-place "Date unknown" runs.
      - [x] Group clips by drive using a boottag exposed in `/v1/clips`.
      - [x] Attribute the active recording to its drive: snapshot `boot_tag`, a live
            widget under the record button, a REC marker on the recording drive's card,
            and a live row atop that drive's detail (ADR 20).
      - [ ] Add a calendar jump backed by the reserved `from`/`to` window params.
      - [ ] Add a locked/incidents filter after `nova` defines incident state.
- [ ] **Swoop `nova` -- Incident lock (manual).** A "save this moment" button: Pi
      force-finalizes the open segment and protects the window, built to the storage
      ADR (idempotency, pre-sync holds) rather than a throwaway lock we'd redo later.
- [ ] **Swoop `reef` -- CarPlay auto start/stop** on CarPlay connect/disconnect.
- [ ] **Swoop `sage` -- CarPlay status panel** (Driving Task template). _Gated on the
      Apple entitlement; the product must be useful without it._
- [x] **Swoop `tide` -- Export / share.** Save-to-Photos, AirDrop, and Save to Files
      through the system share sheet over the cached `.mp4`; auto-save incidents is
      deferred to `nova`.
- [ ] **Swoop `vine` -- Power-loss hardening for real.** Power-good GPIO + clean
      shutdown; supercap go/no-go; validate crash recovery in the actual car.
- [ ] **Later / follow-on passes.** Thermal-behavior policy (what recording does at
      the sensor's 50 C limit); replace the Python Picamera2 camera owner with an
      all-Rust camera binary before or during the read-only car-image pass; HDR tuning;
      auth hardening (token, then pinned-cert TLS); GPS
      time source; parked / sentry
      mode (gated on a future constant-power topology -- v1 power is switched /
      drive-only, see the power-source ADR).

## Icebox (someday-maybe -- parked, not on the near path)

Whole swoops we've deliberately set aside; we won't think about them until something
changes. Distinct from the follow-on passes above (further work on swoops we _will_
build) -- these may or may not ever happen. They keep their codenames so a parked
swoop can drop into the list above unchanged. Unordered.

- [ ] **Swoop `pike` -- CarPlay voice incident-mark.** App Intents "save that clip,"
      hands-free, with queue-and-flush on the cold path. No entitlement needed, but
      **very low priority**: the on-phone "save this moment" button (swoop `nova`)
      already covers the core need, so hands-free voice marking is just convenience on
      top. Revisit only if voice marking proves worth it in the car.
- [ ] **Swoop `lark` -- GPS-driven recording overlay.** Use the iPhone's GPS (speed,
      heading, coordinates, plus a verified clock) and burn/show an info overlay on the
      recorded video and the live preview. Open questions for when we get here: overlay
      on the Pi (burned into footage, survives export, but the Pi has no GPS so the phone
      must push location to it over the link) vs. on the phone (drawn at playback/preview
      only, easy but not in the saved file); what fields to show; and how to fold in the
      `moss` time provenance and a future GPS time source. Flesh out at implementation time.
- [ ] **Swoop `wren` -- Per-unit AP security provisioning.** Replace the single
      hand-typed dev PSK with a per-unit random SSID/PSK generated at provisioning
      time, delivered to the phone via QR-based onboarding
      (`NEHotspotConfiguration`), so every unit ships with a unique strong secret
      instead of a shared dev password. This -- not WPA2-vs-WPA3 -- is the real
      security win for the link (ADR 02's v1 trust boundary; ADR 06 Consequences
      already flags it as a later hardening pass). It is also where app-driven
      auto-rejoin lands: `joinOnce = false` persists the config so the phone
      re-associates without a manual Settings join -- a manually-saved AP already
      auto-rejoins today, so the win is dropping the manual step, not the behavior.
      Parked until there is a
      production/car image to provision; the dev AP's WPA2-AES + manual PSK is
      sufficient for the dev loop.
