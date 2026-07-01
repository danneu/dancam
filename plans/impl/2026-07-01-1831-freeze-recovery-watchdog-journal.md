# Plan: Freeze recovery -- hardware watchdog + persistent journald

## Context

On 2026-06-30 the Pi hard-froze mid-`raspi-deploy`: the ACT LED went to a steady
blink, `dancam.local` stopped resolving, and an in-flight `rsync`/`ssh` hung
forever (no TCP reset). The only fix was a manual power-cycle. Afterward the Pi
came back healthy (`throttled=0x0`, temp 39C, service auto-started), but **we
could not learn why it froze**: `/var/log/journal` exists yet is empty, so
journald was logging only to volatile `/run` and the frozen session's logs died
with the reboot.

This is a distinct failure from the one the design already handles. ADR 04
(power source and shutdown) covers *unsignaled hardware power loss* and
deliberately drops any "watch a signal and act" path. A **software freeze with
power still present** -- kernel/userspace wedged, nothing crashing so
`Restart=on-failure` never fires -- is not covered anywhere. For a unit that
lives unattended on a windshield, two gaps matter:

1. **Recovery:** a freeze currently requires a human to notice and pull power.
2. **Diagnosability:** even after recovery there is no trail, so the next freeze
   is the same mystery.

This change closes both, and closes an already-documented gap: `raspi/AGENTS.md`
notes previous-boot logs "are lost after a reset unless persistent journald is
enabled later," and ADR 06 (AP bring-up) records a failure that "could not be
proven from logs because the dev image had no previous-boot journal."

## Scope

- **In scope (dev image):** enable the on-board BCM2835 hardware watchdog via
  systemd `RuntimeWatchdogSec`; enable persistent, size-capped journald. Both as
  Ansible tasks in `site.yml`, with README + AGENTS sync and a new ADR.
- **Non-goals:**
  - **App-level (process) watchdog.** A hung `dancam` process while PID 1 is
    healthy would need `Type=notify` + `sd_notify(WATCHDOG=1)` in the Rust
    service. The observed incident is *consistent with* a whole-system freeze --
    the class `RuntimeWatchdogSec` covers with zero code -- so the app-level layer
    buys less and is deferred; noted in the ADR. (The incident's exact cause stays
    unproven until persistent logs catch a recurrence -- see the ADR Consequences.)
  - **Car-image logging layout.** Persistent journald writes to `/var/log/journal`
    on the (currently writable) root. The future read-only-overlay car image must
    relocate the journal to the `/data` partition. Deferred, consistent with the
    existing dev-image-only scoping in `site.yml` and ADR 09.
  - **No `config.txt` change.** `/dev/watchdog0` already exists (bcm2835_wdt is
    loaded by default on RPi OS), so the firmware watchdog needs no enabling.

## Ownership (where each piece lives)

Per ADR 09 and root `AGENTS.md#Conventions`, onboard system state lives in Ansible
and any change to it updates the README in the same change:

- **`raspi/ansible/site.yml`** -- source of truth: `community.general.ini_file`
  tasks writing the two drop-ins (the idiom the playbook already uses for Avahi),
  plus handlers, each with a `#` why-comment (the single home of the "why").
- **`README.md` section 3** -- add the two items to what Ansible provisions, plus
  verify commands (matches how config.txt / Avahi are documented).
- **`raspi/AGENTS.md`** -- update the now-stale "enabled later" journald line;
  add a one-line watchdog note; add ADR 12 to the Design-decisions list.
- **New ADR** `raspi/docs/design/12-2026-06-30-watchdog-and-persistent-journal.md`.

## Implementation

### 1. New ADR 12 (raspi)

`raspi/docs/design/12-2026-06-30-watchdog-and-persistent-journal.md`, standard
shape (Title / Status / Context / Decision / Consequences / Alternatives).

- **Status:** Accepted (decided and implemented in this change).
- **Framing:** one ADR for both mechanisms -- they are the recover + diagnose
  halves of one concern (survive a software freeze), following ADR 01's precedent
  of bundling multiple layers that serve one goal into a single decision.
- **Decision:** (a) `RuntimeWatchdogSec=60s` arms the on-board BCM2835 watchdog
  via PID 1 so a hard freeze (PID 1 stops pinging `/dev/watchdog`, or the kernel
  wedges) auto-reboots and the dancam service is back on boot -- host/service
  recovery; recording itself does not auto-resume on the current image (the
  recorder boots `Idle`; see Consequences) -- 60s is the logical PID-1 deadline;
  the ~16s BCM2835 hardware heartbeat bounds a kernel hard-freeze regardless (see
  the timeout-model note in section 2); (b) `Storage=persistent`
  (capped) so previous-boot logs survive the reboot for post-mortem via
  `journalctl -b -1`.
- **Consequences:** unattended host recovery (the service is back on boot -- see
  the recording-resume caveat below); bounded SD write wear (SystemMaxUse cap); car
  image must move the journal to `/data` (deferred). Plus these honest limitations,
  stated in Consequences so the "diagnosable"/"recovered" claims aren't oversold:
  - **Diagnosability is bounded by the last journald sync.** journald fsyncs the
    persistent store every `SyncIntervalSec` (we set 60s) and flushes immediately
    only for CRIT/ALERT/EMERG; a hard freeze gets no final flush, so
    `journalctl -b -1` can be truncated up to ~60s before the wedge -- possibly
    right where the smoking gun is. Still a strict improvement over volatile logs
    (which lose the whole session), just not a guarantee.
  - **Coverage gap 1 (process hang):** does not catch a hung `dancam` process
    while PID 1 is healthy (`Restart=on-failure` only catches exits/crashes).
  - **Coverage gap 2 (kernel soft-lock):** `RuntimeWatchdogSec` only fires when
    PID 1 stops pinging `/dev/watchdog`; a kernel soft-lock where systemd keeps
    scheduling would not trip it (see future layer under Alternatives).
  - **Recording does not auto-resume (current image).** The watchdog recovers the
    *host*: on reboot systemd restarts the dancam service and camera backend, but
    the recorder comes up `Idle` and records only once `/v1/recording/start` is
    issued (`main.rs` spawns the backend; it does not auto-start recording). So the
    fully-unattended-recovery story is complete only alongside a future
    auto-record-on-boot piece (out of scope here); until then a freeze-reboot
    restores the service and the app resumes recording, rather than recording
    resuming on its own.
  - **Reboot loop:** a deterministic freeze that re-triggers shortly after boot
    (within the ~16s hardware heartbeat for a kernel wedge, or the 60s PID-1
    deadline for a userspace stall) yields a watchdog reboot loop -- arguably worse
    than one freeze -- but persistent journald + the partial recording each cycle
    writes make it diagnosable rather than silent.
  - **Observed-incident coverage is unproven.** The 2026-06-30 freeze's cause was
    unrecoverable (volatile logs), so we cannot prove `RuntimeWatchdogSec` would
    have caught it: it fires only when PID 1 stops pinging the watchdog, not when a
    subsystem (Wi-Fi, storage, SSH) wedges while PID 1 keeps scheduling. Persistent
    journald exists precisely to classify the next occurrence; if it proves a
    PID-1-alive subsystem hang, the deferred app-level/process watchdog becomes the
    needed layer.
- **Alternatives considered:** app-level `WatchdogSec` + `sd_notify` (rejected
  now -- needs Rust changes; `RuntimeWatchdogSec` covers the worse, whole-system
  failure for free); external GPIO watchdog (unnecessary -- BCM has one); do
  nothing / manual power-cycle (rejected -- unit is unattended). Kernel lockup
  detector (`kernel.softlockup_panic=1` / hardlockup -> panic -> watchdog reset)
  is a genuine *second* layer for the coverage-gap-2 soft-lock class -- noted as a
  future layer, not added here (scope; unproven against the observed whole-system
  freeze, which `RuntimeWatchdogSec` does cover).
- Cross-reference ADR 04 (its power-loss reasoning) and ADR 01 (crash-safe
  layers) in Context so the boundary is explicit.

### 2. Ansible tasks -- `raspi/ansible/site.yml`

Write both drop-ins with `community.general.ini_file` -- the same idiom the
playbook already uses for `avahi-daemon.conf`. ini_file self-creates the parent
dir in normal mode and, under `--check`, reports would-change *without* creating
the dir or erroring on its absence -- so no separate `file: state=directory` task
is needed and `raspi-provision-check` stays a clean, side-effect-free drift
detector even on a fresh Pi. (`ansible.builtin.copy` with a file dest is *not*
used precisely because it `fail_json`s on a missing parent dir with no check-mode
guard, which would abort the dry-run on a fresh Pi.) Each task sets
`no_extra_spaces: true` and `mode: '0644'`. `no_extra_spaces` writes canonical
`Key=Value` -- matching the Deployed-result blocks below and the existing Avahi
task's style; systemd would tolerate ini_file's default `key = value` spacing too
(it strips whitespace around `=`), so unlike Avahi's fatal-on-space parser this is
a cleanliness choice, not a correctness one, and it does not affect idempotency
(ini_file compares parsed values, not bytes, so `changed=0` on re-run holds either
way). `mode: '0644'` is the systemd drop-in perm and also clears ansible-lint
`risky-file-permissions`, as the Avahi task's `mode` comment documents. Per
ADR 09 the rich rationale lives as the `#` comment on the tasks in `site.yml`; the
deployed file is just its `[section]` + options under the self-identifying
`60-dancam-*` name. The `60-` prefix is deliberate, not cosmetic: systemd merges
drop-ins from `/usr/lib`, `/run`, and `/etc` and applies them in lexicographic
filename order with the **last** assignment winning, so a high prefix keeps the
dancam values above the typical vendor/distro `10-`/`20-`/`50-` range and makes them
the effective assignment rather than a default some later-sorting drop-in could
silently override (a `10-` name would sit *below* such a drop-in and lose).

**Persistent journald** -> `/etc/systemd/journald.conf.d/60-dancam-persistent.conf`,
section `[Journal]`, one `ini_file` task per option (grouped under one why-comment
covering all three):
- `Storage=persistent` -- keep previous-boot logs across the abrupt reboots this
  unit takes (power loss, watchdog resets) so a freeze/AP failure is diagnosable
  post-mortem via `journalctl -b -1`. Dev image only; the car image must relocate
  the journal to the journaled /data partition under read-only root (see ADR 12).
- `SystemMaxUse=200M` -- cap so logs never crowd out recordings on the SD card.
- `SyncIntervalSec=60s` -- shorten journald's default 5min fsync cadence so a hard
  freeze loses at most ~60s of the newest logs (journald flushes immediately only
  for CRIT+, and a freeze gets no final flush): the deliberate
  wear-vs-diagnosability balance.

Deployed result:
```ini
[Journal]
Storage=persistent
SystemMaxUse=200M
SyncIntervalSec=60s
```
Handlers (three, defined in this order and all notified by these tasks):
`Restart systemd-journald` (re-reads the drop-in so `Storage=persistent` takes
effect for the current boot and `/var/log/journal` is created/used), then
`Flush journald` (`journalctl --flush` -- migrate this boot's runtime logs from
`/run` into the persistent store), then `Sync journald` (`journalctl --sync` --
fsync the store). This captures the converge boot durably *before* the watchdog
task's `Reboot host` fires, rather than relying on shutdown-time flush timing --
which matters here because the Pi's `/var/log/journal` already exists yet stayed
volatile (see Context), so an explicit restart+flush is what actually persists the
current boot. The two `journalctl` handlers are `ansible.builtin.command`s with
`changed_when: false` (they flush/sync; they are not config drift), keeping the
`changed=0` idempotency bar on a converged re-run.

**Hardware watchdog** -> `/etc/systemd/system.conf.d/60-dancam-watchdog.conf`,
section `[Manager]`, a single `ini_file` task (one option):
- `RuntimeWatchdogSec=60s` -- arms the on-board BCM2835 watchdog (/dev/watchdog0)
  via PID 1: systemd pings it every RuntimeWatchdogSec/2 (30s); if PID 1 stops
  pinging -- a userspace hang, or a kernel hard-freeze that also stalls the
  kernel's ping worker (power present but wedged -- the failure ADR 04 does NOT
  cover) -- the board resets and the dancam service comes back on boot (host
  recovery; the recorder boots `Idle`, so recording resumes when the app re-issues
  `/v1/recording/start` -- auto-record-on-boot does not yet exist). Timeout model: the
  BCM2835 hardware heartbeat maxes at ~16s, but the `bcm2835_wdt` driver exposes it
  as `max_hw_heartbeat_ms` (not a hard `max_timeout`), so the Linux watchdog core
  accepts a longer *logical* timeout and re-pings the hardware internally while
  PID 1 stays alive -- 60s is a valid RuntimeWatchdogSec, NOT capped/rejected to
  ~16s. A kernel hard-freeze stops that kernel worker too, so the hardware then
  bites at its ~16s heartbeat regardless of RuntimeWatchdogSec; the 60s value
  therefore governs only the PID-1-stall case, chosen over an aggressive sub-16s
  deadline to avoid false resets when PID 1 is merely slow under transient
  IO/thermal load (a false reset interrupts recording).
- `RebootWatchdogSec` is deliberately **left at its 10min default**, not set. It
  governs only the *shutdown/reboot* phase (systemd arms it by default while
  rebooting), so hung-reboot recovery already exists without us touching it.
  Tightening it to 2min buys nothing on an unattended unit nobody is waiting on, and
  adds the plan's only real false-trigger risk: a legitimately slow shutdown (one
  hung stop job alone burns `DefaultTimeoutStopSec=90s` before SIGKILL, plus journald
  flush and SD unmount) that runs past 2min would take a hardware reset *mid-unmount*
  on the writable dev-image root -- the corruption class the project treats as
  first-class (ADR 01). Keeping the 10min default preserves that safety net with far
  more headroom, consistent with the same reasoning that picked 60s over an aggressive
  runtime deadline. (This why-not lives here and as the site.yml task comment so the
  knob is not "helpfully" re-added later.)

Deployed result:
```ini
[Manager]
RuntimeWatchdogSec=60s
```
Handler: reuse the existing **Reboot host** handler (like the `config.txt` tasks
do). `RuntimeWatchdogSec` is *manager* config that a live PID 1 does not apply on
`daemon-reload` -- it needs `daemon-reexec` or a boot -- so arming it
authoritatively means rebooting on change, which `Reboot host` already does.
Define the three new journald handlers (`Restart systemd-journald`, `Flush
journald`, `Sync journald`) *before* `Reboot host` in the handler list, preserving
the documented "Reboot host defined last / runs after the other handlers"
invariant -- so on a converge that touches both drop-ins, journald is persisted
and synced first, then the reboot arms the watchdog.

### 3. README.md -- section 3 "Provision the system layer (Ansible)"

- Add "persistent journald (dev image)" and "the on-board hardware watchdog" to
  the sentence enumerating what the playbook provisions.
- Add verify commands in the section's existing smoke-test style (see Verification
  below for the exact commands).

### 4. raspi/AGENTS.md

- Replace the stale line in `### Pointing the app at the unit` -- "...lost after a
  reset unless persistent journald is enabled later" -- with a statement that
  persistent journald is now enabled (dev image), so previous-boot logs survive;
  point to ADR 12.
- Add a one-line watchdog mention (e.g. in `### Running` or `## Constraints`):
  the unit auto-reboots on a hard freeze via the BCM watchdog.
- Add `12-2026-06-30-watchdog-and-persistent-journal.md` to the ADR list, and
  while there reconcile the whole list: it currently omits `06-...-ap-networking-
  bring-up`, `10-...-recorder-fsm-and-events-sse`, and `11-...-forkable-pi-config`
  (all present in `docs/design/` but absent from the index). Restore those three so
  the index matches the directory (AGENTS.md is the source of truth for context).

## Verification

1. **ADR + lint:** `just adr-check` (validates seq 12 / date / format);
   `just raspi-provision-lint` (syntax + ansible-lint -- `mode: '0644'` on each
   ini_file task keeps `risky-file-permissions` green).
2. **Dry run:** `just raspi-provision-check` -- clean, no errors even on a fresh
   Pi: `ini_file` self-creates parents in normal mode and, under `--check`, reports
   would-change without creating the dir or failing on its absence. Expect the 4
   journald/watchdog options reported as would-change (3 journald --
   `Storage`/`SystemMaxUse`/`SyncIntervalSec` -- plus 1 watchdog --
   `RuntimeWatchdogSec`; and `changed=0` on a Pi already converged).
3. **Converge:** `just raspi-provision`. The watchdog drop-in notifies **Reboot
   host**, so a first apply reboots the Pi (the reboot module waits for reconnect)
   -- that boot is what actually arms the watchdog and starts journald persistent.
   Then re-run `just raspi-provision-check` -> `changed=0` (the idempotency bar
   the repo already holds Avahi/AP to).
4. **Persistent journald -- reboot proof + effective config:** with the unit up
   post-converge, `ssh dancam.local sudo reboot`; wait ~40s; reconnect.
   - `ssh dancam.local journalctl --list-boots` -> **>= 2 boots** (previous boot
     retained -- proves persistence across a reboot; the `Flush`/`Sync` handlers
     ran on converge, so the pre-reboot boot is durably captured, not reliant on
     shutdown-time flush timing).
   - `ssh dancam.local 'journalctl --disk-usage; ls /var/log/journal/*/'` ->
     non-empty persistent store.
   - Effective-config, last-wins values (not mere presence): `systemd-analyze
     cat-config systemd/journald.conf` concatenates the main file and every drop-in
     in application order, so the *effective* value of a key is its **last
     uncommented** assignment. Presence alone -- even exact-value presence via
     `grep -Fxq` -- does not prove ours wins: a later-sorting drop-in could reassign
     the key below our line and `-Fxq` would still pass. So assert the last
     uncommented assignment per key equals the dancam value:
     - `ssh dancam.local "systemd-analyze cat-config systemd/journald.conf | grep -E '^Storage *=' | tail -n1"` -> `Storage=persistent`
     - same with `'^SystemMaxUse *='` -> `SystemMaxUse=200M`
     - same with `'^SyncIntervalSec *='` -> `SyncIntervalSec=60s`

     The `^Key *=` anchor drops the shipped *commented* defaults (`#Storage=auto`,
     `#SystemMaxUse=`, ...) that a name-only `grep -E 'Storage'` would false-pass on,
     and `tail -n1` collapses to the winning assignment -- proving both that our value
     is active AND that nothing later overrides it (that override risk is exactly what
     the `60-` filename prefix defends against; this check confirms it held). This is
     the coverage `--disk-usage` misses: a store exists (and boots are retained) even
     if `SystemMaxUse`/`SyncIntervalSec` were silently dropped or overridden. (The
     watchdog side needs no equivalent check -- step 5's `systemctl show -p ...USec`
     already reads systemd's own resolved manager property, which *is* the effective
     last-wins value.)
5. **Watchdog armed (run AFTER the reboot so it reflects a real boot, not a
   pre-arm read):**
   - `ssh dancam.local systemctl show -p RuntimeWatchdogUSec` -> `1min` (60s). This
     is a **config-landed check only, NOT proof the hardware is armed**: the D-Bus
     getter returns systemd's *configured* value (`manager_get_watchdog(m,
     WATCHDOG_RUNTIME)`), never a read-back of the kernel-accepted timeout, so it
     reports `1min` even if `/dev/watchdog0` were absent or the driver had rejected
     60s. So `1min` here proves only that the drop-in parsed and the manager holds
     the value; the actual arming proof is the PID-1 journal line below.
   - `ssh dancam.local 'journalctl -b -k | grep -i watchdog'` -> the `bcm2835-wdt`
     kernel driver line (also proves the "watchdog hardware present / module
     auto-loaded" premise).
   - `ssh dancam.local 'journalctl -b _PID=1 | grep -i watchdog'` -> systemd's arming
     line, **the actual armed-at-60s proof**. On Trixie's systemd (v257) this reads
     `Watchdog running with a hardware timeout of 1min.` (older systemd worded it
     `Set hardware watchdog to ...`; `grep -i watchdog` catches either). systemd emits
     this line only on the success path *after* the `/dev/watchdog0`
     `WDIOC_SETTIMEOUT` ioctl returns, so its presence proves the device opened and
     took the timeout -- and the `1min` value (a clamp would report `~16s` here) shows
     the 60s logical timeout was accepted, the runtime corroboration that the
     `max_hw_heartbeat_ms` extension held (the authoritative basis is the kernel
     source cited in Risks/notes). It is a PID 1 userspace message, so `-k`
     (kernel-only) hides it -- hence the two separate greps; the `-k` grep above still
     independently proves the `bcm2835-wdt` module is present.
6. **Service healthy + explicit recorder state:** `curl -i
   http://dancam.local:8080/v1/health` -> 200, and `curl -s
   http://dancam.local:8080/v1/status` -> the snapshot's `recorder.phase` is
   `idle` on the current image (the reboot recovers the *service*, not the
   recording -- see the recording-resume Consequence; this asserts the real
   post-boot state rather than implying recording resumed). To confirm recording still
   works end to end, optionally start it -- but `/v1/recording/start` requires
   mutation headers (`require_mutation_headers` in `raspi/service/src/recording.rs`
   returns 415 without `Content-Type: application/json` and 400 without a non-empty
   `Idempotency-Key`), so a bare `POST` fails before touching the recorder. Use the
   exact form (the handler ignores the body, so `-d '{}'` is just a well-formed empty
   JSON payload and the explicit `-H` overrides curl's default form content-type):
   ```
   curl -i -X POST http://dancam.local:8080/v1/recording/start \
     -H 'Content-Type: application/json' \
     -H 'Idempotency-Key: verify-1' \
     -d '{}'
   ```
   -> 200, then re-read `/v1/status` for a non-idle `recorder.phase`
   (`starting`/`recording`).
7. **Optional / destructive (not required):** proving the watchdog actually bites
   a real freeze needs a controlled hang (e.g. sysrq), which risks the SD. Steps
   4-5 are sufficient proof for this change; skip the live-hang test unless wanted.

## Risks / notes

- **Watchdog timeout model.** The BCM2835 hardware heartbeat maxes at ~16s, but
  the `bcm2835_wdt` driver exposes it as `max_hw_heartbeat_ms` (confirmed in the
  RPi kernel source, `drivers/watchdog/bcm2835_wdt.c`), so systemd's
  `RuntimeWatchdogSec=60s` is a valid *logical* timeout -- the kernel watchdog core
  re-pings the hardware internally while PID 1 feeds it. 60s is NOT capped or
  rejected. A kernel hard-freeze still recovers at the ~16s hardware bound
  regardless (the core's ping worker stalls with the kernel); 60s governs only the
  PID-1-stall deadline.
- **Spurious reboots** only if PID 1 itself stalls >60s (severe overload) -- which
  is the intended recovery trigger, not a false positive. 60s (vs an aggressive
  sub-16s deadline) is chosen precisely to keep this a real signal, not IO/thermal
  jitter. Low risk in practice.
- **Arming requires a boot.** `RuntimeWatchdogSec` is manager config a live PID 1
  won't apply on `daemon-reload`, so the watchdog drop-in reboots on change (via
  the existing Reboot host handler), exactly like the config.txt tasks. A first
  apply of this change therefore reboots the Pi -- expected, not a surprise.
- **Freeze log tail can still be lost.** journald fsyncs every `SyncIntervalSec`
  (set to 60s) and can't flush on a freeze, so `journalctl -b -1` may be truncated
  up to ~60s before the wedge. Persistence is a strict improvement, not a guarantee.
- **SD wear** from journald is bounded by the `SystemMaxUse=200M` cap; recordings
  stay the priority for card space.

## Files touched

- NEW `raspi/docs/design/12-2026-06-30-watchdog-and-persistent-journal.md`
- EDIT `raspi/ansible/site.yml` (per-option `community.general.ini_file` tasks for
  the two drop-ins -- no separate dir task; 3 new handlers -- `Restart
  systemd-journald`, `Flush journald`, `Sync journald` -- defined before `Reboot
  host`; watchdog reuses the existing `Reboot host` handler; the rich why lives as
  the tasks' `#` comments)
- EDIT `README.md` (section 3: enumeration + verify commands)
- EDIT `raspi/AGENTS.md` (stale journald line; watchdog note; ADR list entry)
