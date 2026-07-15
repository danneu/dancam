# ADR: Hardware watchdog and persistent journald

- **Status:** Accepted
- **Date:** 2026-06-30
- **Owner:** raspi
- **Related:** `04-2026-06-23-power-source-and-shutdown.md` (covers *unsignaled
  hardware power loss* and deliberately drops any "watch a signal and act" path --
  this ADR covers the distinct **software-freeze-with-power-present** class it does
  not); [Pi recording](../../../docs/design/pi/recording.md) (the crash-safe layers,
  and the precedent for bundling several layers that serve one goal into a single
  decision);
  `09-2026-06-26-pi-system-layer-config-ansible.md` (the Ansible system-layer
  ownership and dev-image-only scoping these tasks follow);
  `06-2026-06-25-ap-networking-bring-up.md` (the AP failure that "could not be proven
  from logs because the dev image had no previous-boot journal" -- this closes that
  gap)

> **Note (2026-07-04):** `18-2026-07-04-sd-card-layout-and-readonly-root.md`
> supersedes this ADR's deferred car-image journal location. Persistent journald
> relocates to `/persist/journal`, bind-mounted at `/var/log/journal`, not to `/data`.
> `/data` remains the recording partition and the only partition `kelp` formats from
> the app. Append-only per the ADR convention.

## Context

On 2026-06-30 the Pi hard-froze mid-`raspi-deploy`: the ACT LED went to a steady
blink, `dancam.local` stopped resolving, and an in-flight `rsync`/`ssh` hung forever
(no TCP reset). The only fix was a manual power-cycle. Afterward the Pi came back
healthy (`throttled=0x0`, temp 39C, service auto-started), but **we could not learn
why it froze**: `/var/log/journal` exists yet is empty, so journald was logging only
to volatile `/run` and the frozen session's logs died with the reboot.

This is a distinct failure from the one the design already handles. ADR 04 covers
*unsignaled hardware power loss* and deliberately drops any "watch a signal and act"
path. A **software freeze with power still present** -- kernel or userspace wedged,
nothing crashing so `Restart=on-failure` never fires -- is covered nowhere. For a
unit that lives unattended on a windshield, two gaps matter:

1. **Recovery:** a freeze currently requires a human to notice and pull power.
2. **Diagnosability:** even after recovery there is no trail, so the next freeze is
   the same mystery.

The diagnosability gap is already documented elsewhere: `raspi/AGENTS.md` notes
previous-boot logs "are lost after a reset unless persistent journald is enabled
later," and ADR 06 records the AP failure that could not be proven from logs for the
same reason.

## Decision

Arm the on-board BCM2835 hardware watchdog and enable persistent, size-capped
journald. These are the **recover** and **diagnose** halves of one concern -- survive
a software freeze -- so they ship as one ADR, following the recording design's
precedent of bundling layers that serve one goal. Both are provisioned as Ansible tasks in
`raspi/ansible/site.yml` (dev image only), with the rich "why" living as each task's
`#` comment per ADR 09.

1. **`RuntimeWatchdogSec=60s`** (`/etc/systemd/system.conf.d/60-dancam-watchdog.conf`,
   `[Manager]`) arms the on-board BCM2835 watchdog (`/dev/watchdog0`) via PID 1:
   systemd pings it every `RuntimeWatchdogSec/2` (30s), and if PID 1 stops pinging --
   a userspace hang, or a kernel hard-freeze that also stalls the kernel's ping worker
   (power present but wedged, the failure ADR 04 does *not* cover) -- the board resets
   and the dancam service comes back on boot. This is **host/service recovery**;
   recording itself does not auto-resume on the current image (see Consequences). 60s
   is the logical PID-1 deadline; a kernel hard-freeze is bounded regardless by the
   ~16s BCM2835 hardware heartbeat (see the timeout model below).

2. **`Storage=persistent`** (capped) (`/etc/systemd/journald.conf.d/60-dancam-persistent.conf`,
   `[Journal]`) keeps previous-boot logs across the abrupt reboots this unit takes
   (power loss, watchdog resets) so a freeze or AP failure is diagnosable post-mortem
   via `journalctl -b -1`. Paired with `SystemMaxUse=200M` (logs never crowd out
   recordings on the SD card) and `SyncIntervalSec=60s` (shorten journald's default
   5min fsync cadence so a hard freeze loses at most ~60s of the newest logs).

**Timeout model.** The BCM2835 hardware heartbeat maxes at ~16s, but the
`bcm2835_wdt` driver exposes it as `max_hw_heartbeat_ms` (confirmed in the RPi kernel
source, `drivers/watchdog/bcm2835_wdt.c`), *not* a hard `max_timeout`. So the Linux
watchdog core accepts a longer *logical* timeout and re-pings the hardware internally
while PID 1 stays alive -- 60s is a valid `RuntimeWatchdogSec`, not capped or rejected
to ~16s. A kernel hard-freeze stops that kernel worker too, so the hardware then bites
at its ~16s heartbeat regardless of `RuntimeWatchdogSec`; the 60s value therefore
governs only the PID-1-stall case, chosen over an aggressive sub-16s deadline to avoid
false resets when PID 1 is merely slow under transient IO or thermal load (a false
reset interrupts recording).

**`RebootWatchdogSec` is left at its 10min default, not set.** It governs only the
shutdown/reboot phase (systemd arms it by default while rebooting), so hung-reboot
recovery already exists without touching it. Tightening it to 2min buys nothing on an
unattended unit nobody is waiting on, and adds the only real false-trigger risk here:
a legitimately slow shutdown (one hung stop job alone burns `DefaultTimeoutStopSec=90s`
before SIGKILL, plus journald flush and SD unmount) that runs past 2min would take a
hardware reset *mid-unmount* on the writable dev-image root -- the corruption class
the project treats as first-class in the recording design. Keeping the 10min default
preserves that safety net with far more headroom.

**Scope: dev image only.** Persistent journald writes to `/var/log/journal` on the
currently-writable root. The future read-only-overlay car image must relocate the
journal to the `/data` partition; deferred, consistent with the dev-image-only scoping
in `site.yml` and ADR 09.

## Consequences

- **Unattended host recovery.** A hard freeze now auto-reboots instead of waiting for
  a human to pull power; on reboot systemd restarts the dancam service and camera
  backend (subject to the recording-resume caveat below).
- **Previous-boot logs survive.** `journalctl -b -1` now works across the abrupt
  reboots this unit takes, closing the diagnosability gap that made the 2026-06-30
  freeze and the ADR 06 AP failure unprovable.
- **Bounded SD write wear.** The `SystemMaxUse=200M` cap keeps journald from crowding
  out recordings; `SyncIntervalSec=60s` is the deliberate wear-vs-diagnosability
  balance.
- **Car image must move the journal to `/data`** under the read-only root (deferred).

Honest limitations, stated so the "diagnosable" and "recovered" claims are not
oversold:

- **Diagnosability is bounded by the last journald sync.** journald fsyncs the
  persistent store every `SyncIntervalSec` (60s) and flushes immediately only for
  CRIT/ALERT/EMERG; a hard freeze gets no final flush, so `journalctl -b -1` can be
  truncated up to ~60s before the wedge -- possibly right where the smoking gun is.
  Still a strict improvement over volatile logs (which lose the whole session), just
  not a guarantee.
- **Coverage gap 1 (process hang):** does not catch a hung `dancam` process while
  PID 1 is healthy (`Restart=on-failure` only catches exits/crashes).
- **Coverage gap 2 (kernel soft-lock):** `RuntimeWatchdogSec` only fires when PID 1
  stops pinging `/dev/watchdog`; a kernel soft-lock where systemd keeps scheduling
  would not trip it (see the future layer under Alternatives).
- **Recording does not auto-resume (current image).** The watchdog recovers the
  *host*: on reboot systemd restarts the dancam service and camera backend, but the
  recorder comes up `Idle` and records only once `/v1/recording/start` is issued
  (`main.rs` spawns the backend; it does not auto-start recording). So the
  fully-unattended-recovery story is complete only alongside a future
  auto-record-on-boot piece (out of scope here); until then a freeze-reboot restores
  the service and the app resumes recording, rather than recording resuming on its own.
- **Reboot loop:** a deterministic freeze that re-triggers shortly after boot (within
  the ~16s hardware heartbeat for a kernel wedge, or the 60s PID-1 deadline for a
  userspace stall) yields a watchdog reboot loop -- arguably worse than one freeze --
  but persistent journald plus the partial recording each cycle writes make it
  diagnosable rather than silent.
- **Observed-incident coverage is unproven.** The 2026-06-30 freeze's cause was
  unrecoverable (volatile logs), so we cannot prove `RuntimeWatchdogSec` would have
  caught it: it fires only when PID 1 stops pinging the watchdog, not when a subsystem
  (Wi-Fi, storage, SSH) wedges while PID 1 keeps scheduling. Persistent journald
  exists precisely to classify the next occurrence; if it proves a PID-1-alive
  subsystem hang, the deferred app-level/process watchdog becomes the needed layer.

## Alternatives considered

- **App-level `WatchdogSec` + `sd_notify(WATCHDOG=1)`** (a `Type=notify` process
  watchdog in the Rust service). Rejected now: it needs Rust changes and catches only
  the process-hang class (coverage gap 1), while `RuntimeWatchdogSec` covers the
  worse, whole-system freeze for free. Deferred; it becomes the needed layer if
  persistent journald proves a PID-1-alive subsystem hang.
- **External GPIO watchdog.** Unnecessary -- the BCM2835 has one on-board, exposed as
  `/dev/watchdog0` with `bcm2835_wdt` loaded by default (no `config.txt` change).
- **Do nothing / manual power-cycle.** Rejected -- the unit is unattended on a
  windshield; a freeze should not wait for a human.
- **Kernel lockup detector** (`kernel.softlockup_panic=1` / hardlockup -> panic ->
  watchdog reset). A genuine *second* layer for the coverage-gap-2 soft-lock class,
  noted as a future layer but not added here: it is out of scope and unproven against
  the observed whole-system freeze, which `RuntimeWatchdogSec` does cover.
