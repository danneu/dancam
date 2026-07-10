# Add a `raspi-reset-data` ops task to wipe the Pi's recorded footage

## Context

The "group clips into recordings" plan changed the segment filename grammar from
3-part (`seg_<seq>_<tag>_<mono>.ts`) to 4-part (`seg_<seq>_<tag>_<sess>_<mono>.ts`)
and now carries `session` on the wire. Old-format footage already on a physical Pi's
`/data/rec` is *safe to leave* -- the new parser (`raspi/service/src/recorder.rs#fn
parse_segment_filename`) returns `None` for names it cannot parse, and the durable
witness (`raspi/service/src/storage.rs#fn next_start_segment`) preserves seq
monotonicity regardless -- but those clips become invisible in the app and are never
reclaimed. Clearing the rec dir is therefore a useful, recurring operator action
(after a format change, or just to reclaim the card).

Today there is no built-in way to do it: the `raspi-*` recipes cover
build/deploy/provision/mock/AP only, and `raspi/README.md` has no reset/wipe guidance
at all. This adds a durable `just raspi-reset-data` recipe plus the required README
ops note, so the reset is a first-class, discoverable task rather than a remembered
one-liner.

Scope is deliberately the physical Pi only (no local mock-dir cleanup).

## Facts this relies on (verified)

- Service unit is `dancam` (`raspi/deploy.sh` -> `sudo systemctl ... dancam`); rec dir
  is `/data/rec`, owned by the `dancam` service user, so wiping needs `sudo`.
- `/data` stays writable even on the read-only car image (only `/` is remounted, for
  `/etc`), so the reset needs no remount dance.
- Every `/data/rec` mutation must first prove `/data` is a real mount. `/data` is mounted
  `nofail`, so a bad card boots with `/data` *absent*; the service therefore runs with
  `DANCAM_REQUIRE_REC_MOUNT=/data` and a stat-based witness
  (`raspi/service/src/storage.rs#fn ensure_required_mountpoint`) that refuses to record,
  allocate, or delete unless `/data` is mounted
  (`raspi/docs/design/18-2026-07-04-sd-card-layout-and-readonly-root.md`, "Recording
  partition and witness"). A footage-wiping recipe must inherit the *same* guard, or on a
  missing `/data` it would delete the root filesystem's `/data/rec`. The exact shell analog
  is a `stat` device/inode comparison, not `mountpoint -q`: the Rust witness treats `/data`
  as mounted iff `dev(/data) != dev(/) || ino(/data) == ino(/)`, whereas modern util-linux
  `mountpoint` consults mount metadata (`statmount(2)`/libmount) and so *accepts* a
  same-device bind mount that the Rust witness *rejects* -- a divergence that could wipe a
  root-fs directory bind-mounted at `/data`. So the recipe replicates the predicate with
  `stat -c %d`/`%i` (coreutils, always present): it aborts iff
  `dev(/data) == dev(/) && ino(/data) != ino(/)`, the exact complement of the witness's
  "mounted" test.
- Deleting the *contents* of `/data/rec` (segments + the `state/`/`time/` subdirs, i.e.
  the witness) makes the next run restart at seq 0 / session 1. Keeping the `/data/rec`
  dir itself preserves its provisioned ownership.
- The service is `Type=exec` with `Restart=on-failure` (`raspi/dancam.service`): a
  `systemctl start` returns as soon as the binary *execs*, not when it is serving, so a
  unit that binds-fails and crash-loops still passes `systemctl start` while `/v1/health`
  never answers. `raspi/deploy.sh` therefore treats readiness as a bounded
  `curl .../v1/health` poll (`DANCAM_HEALTH_TIMEOUT`, default 60s; `DANCAM_PORT`, default
  8080), not as `systemctl start` returning. The reset reuses that exact readiness
  definition before it may report a restart as verified.
- Recipe host/key wiring matches every other Pi recipe:
  `HOST="${DANCAM_HOST:-pi@dancam.local}"`, `SSH_KEY="${DANCAM_SSH_KEY:-$HOME/.ssh/id_ed25519}"`
  with the `~` expansion line (see `Justfile#raspi-partition`).
- No recipe index needs updating -- discovery is `just --list`, self-documented by the
  `#` comment above each recipe (root `AGENTS.md#Conventions`). The only doc that must
  move in the same change is `raspi/README.md` (root `AGENTS.md` Raspberry Pi setup
  runbook rule; `raspi/AGENTS.md` README-in-sync rule).

## Change 1: add the recipe to `Justfile`

Add a new `raspi-reset-data` recipe alongside the other Pi recipes (natural spot: right
after `raspi-deploy`, since resets pair with deploys). It follows the shebang-script
form used by `raspi-partition`/`raspi-ap`: prove `/data` is mounted and preview what
will be deleted, confirm locally (bypassable for scripting), then stop/delete/restart --
with the mount witness, a fail-closed stat guard, and an EXIT-trap cleanup that restarts
and health-checks the service, all inherited from the service's own invariants.

```make
# Wipe recorded footage on the Pi: refuse unless /data is a real mount, then stop dancam,
# delete everything under /data/rec (segments + witness/time state, so the next run
# restarts at seq 0 / session 1), and always restart dancam and wait for it to answer
# /v1/health -- failing loudly if it does not come back. Destructive; prompts unless
# DANCAM_YES=1. Override host with DANCAM_HOST=...
raspi-reset-data:
    #!/usr/bin/env bash
    set -euo pipefail
    HOST="${DANCAM_HOST:-pi@dancam.local}"
    SSH_KEY="${DANCAM_SSH_KEY:-$HOME/.ssh/id_ed25519}"
    SSH_KEY="${SSH_KEY/#\~/$HOME}"
    PORT="${DANCAM_PORT:-8080}"
    HEALTH_TIMEOUT="${DANCAM_HEALTH_TIMEOUT:-60}"
    # Mount witness identical to the service's stat-based ensure_required_mountpoint:
    # /data is mounted iff dev(/data) != dev(/) OR ino(/data) == ino(/); abort on the
    # complement. Each stat is captured in its own fail-closed assignment (a stat that
    # fails aborts under set -e -- it never leaves an empty value that a bare `$(stat)`
    # inside the `if` condition could let slip past the guard). Defined once and
    # interpolated into both SSH sessions so they stay in lockstep.
    WITNESS='
      [ -d /data ] || { echo "ABORT: /data missing or not a directory; refusing to touch /data/rec" >&2; exit 1; }
      data_dev=$(stat -c %d /data) || { echo "ABORT: cannot stat /data; refusing to touch /data/rec" >&2; exit 1; }
      root_dev=$(stat -c %d /)     || { echo "ABORT: cannot stat /; refusing to touch /data/rec" >&2; exit 1; }
      data_ino=$(stat -c %i /data) || { echo "ABORT: cannot stat /data; refusing to touch /data/rec" >&2; exit 1; }
      root_ino=$(stat -c %i /)     || { echo "ABORT: cannot stat /; refusing to touch /data/rec" >&2; exit 1; }
      if [ "$data_dev" = "$root_dev" ] && [ "$data_ino" != "$root_ino" ]; then
        echo "ABORT: /data is not a mounted filesystem (same device as /); refusing to touch /data/rec" >&2
        exit 1
      fi'
    echo "==> current footage on $HOST:"
    ssh -t -i "$SSH_KEY" "$HOST" "
      set -euo pipefail
      $WITNESS
      sudo du -sh /data/rec 2>/dev/null || true
      printf 'entries: '; sudo find /data/rec -mindepth 1 2>/dev/null | wc -l
    "
    if [ "${DANCAM_YES:-}" != "1" ]; then
      read -r -p "Delete ALL of /data/rec on $HOST? [y/N] " ans
      case "$ans" in y | Y) ;; *) echo "aborted"; exit 1 ;; esac
    fi
    ssh -t -i "$SSH_KEY" "$HOST" "
      set -euo pipefail
      $WITNESS
      # Cleanup runs on EVERY exit path -- normal, a set -e failure, or an untrapped fatal
      # signal (Ctrl-C / dropped SSH link), for which bash still runs the EXIT trap and then
      # exits 128+signum. Trapping ONLY EXIT is deliberate: an explicit INT/TERM/HUP handler
      # would begin with whatever \$? happened to be (possibly 0) and could report an
      # interrupted wipe as success. Installed BEFORE stop so no interruption window leaves
      # dancam down.
      cleanup() {
        status=\$?
        trap - EXIT
        if ! sudo systemctl start dancam; then
          echo 'ERROR: dancam failed to start after reset -- recording is DOWN; restart it manually' >&2
          exit 1
        fi
        # Type=exec: systemctl start returns once the binary execs, not once it serves.
        # Confirm dancam actually answers /v1/health (the same bounded poll as deploy.sh) so
        # a crash-looping unit is never reported as a clean restart.
        deadline=\$(( \$(date +%s) + $HEALTH_TIMEOUT ))
        until curl -fsS --max-time 5 -o /dev/null http://localhost:$PORT/v1/health 2>/dev/null; do
          if (( \$(date +%s) >= deadline )); then
            echo 'ERROR: dancam did not answer /v1/health after restart -- recording is DOWN; check journalctl -u dancam' >&2
            exit 1
          fi
          sleep 2
        done
        exit \$status
      }
      trap cleanup EXIT
      sudo systemctl stop dancam
      sudo find /data/rec -mindepth 1 -delete
    "
    echo "==> /data/rec cleared; dancam restarted and answering /v1/health (next run: seq 0 / session 1)"
```

Design notes:
- **Mount witness (`$WITNESS`, a `stat` device/inode predicate)** mirrors the service's own
  `DANCAM_REQUIRE_REC_MOUNT=/data` guard (ADR 18, "Recording partition and witness") *byte
  for byte*: mounted iff `dev(/data) != dev(/) || ino(/data) == ino(/)`, so it aborts iff
  `dev(/data) == dev(/) && ino(/data) != ino(/)`. It deliberately is **not** `mountpoint -q`,
  which consults mount metadata and would accept a same-device bind mount the Rust witness
  rejects. The four `stat` reads are **captured in standalone fail-closed assignments**
  (`data_dev=$(stat ...) || exit 1`, ...) *before* the comparison, not inlined as `$(stat)`
  inside the `if` condition: a command substitution that fails inside a test condition is not
  caught by `set -e` and yields an empty string, and an empty `dev`/`ino` could make the
  same-device test evaluate false and *skip* the abort -- a failed `stat` silently passing the
  destructive guard. Capturing first means any `stat` failure aborts outright and the compare
  only ever runs on real numbers. `/data` is mounted `nofail`, so a bad card boots with
  `/data` absent; without this the recipe would delete the *root filesystem's* `/data/rec`. It
  runs first in both the preview and the mutation session and aborts *before* `systemctl stop`,
  so a not-mounted (or same-device) `/data` leaves the unit fully untouched (service still
  `active`); the mutation session re-checks so there is no time-of-check/time-of-use gap
  between prompt and delete.
- **Restart cleanup (`cleanup` on `EXIT` only, installed *before* `stop`)** guarantees dancam
  is brought back on every exit path *and* never reports success over a down service. Three
  deliberate choices: (1) installed before `systemctl stop`, so an interruption between stop
  and delete cannot leave the unit down; (2) trapped on **`EXIT` alone, not `INT`/`TERM`/`HUP`**
  -- an untrapped fatal signal still runs the `EXIT` trap and then terminates the shell with
  `128+signum`, so an interrupted run reports non-zero, whereas an explicit signal handler would
  begin with whatever `$?` happened to be (possibly `0` if the last command succeeded) and could
  exit `0`, reporting an interrupted wipe as clean; (3) it captures `status=$?` first, disarms
  itself (`trap - EXIT`) against re-entrancy, and -- because `Type=exec` makes `systemctl start`
  return *before* the service serves -- it both checks `systemctl start` *and then* polls
  `/v1/health` on a bounded deadline (the `deploy.sh` pattern, `DANCAM_HEALTH_TIMEOUT`), printing
  a loud "recording is DOWN" and `exit 1` if the start fails *or* the service does not answer in
  time. On the happy path it exits with the original status; the final host-side line's "restarted
  and answering /v1/health" claim is therefore substantiated by a probe, not assumed from
  `systemctl start`.
- `find /data/rec -mindepth 1 -delete` deletes depth-first (handles `state/`/`time/`
  subdirs) and keeps `/data/rec` itself with its ownership; on an empty dir it is a
  no-op.
- The preview is a separate read-only `ssh` before the local prompt, so the operator
  sees the size/entry count before deciding, and its witness aborts before the prompt
  when `/data` is not mounted. Cost: a second `sudo` (hence a possible second password
  prompt). Acceptable and matches how deploy already prompts; not worth consolidating.
- Both remote payloads are double-quoted so `$WITNESS` and the locally-resolved
  `$PORT`/`$HEALTH_TIMEOUT` interpolate on the Mac, while the cleanup's own runtime values
  (`$?`, `$status`, `$(date +%s)`, `$deadline`) are escaped (`\$`) to stay the *remote*
  shell's; the witness is defined once and reused, keeping the two sessions in exact lockstep.
- `DANCAM_YES=1` skips the prompt for unattended use; `set -euo pipefail` and the
  `[y/N]`-default-abort keep an accidental Enter safe.

## Change 2: README ops note

Add a short note at the **tail of `## 8. Deploy and run the service`** in
`raspi/README.md`, immediately after the existing `Service management on the Pi:` block
and its `journalctl`/`RUST_LOG` paragraph, before `## 9. Smoke-test the AP path`. Match
the file's flat style (no `###`): a colon-terminated lead-in sentence introducing a
fenced `sh` block, recipe referenced as `just raspi-reset-data`.

Proposed prose:

```markdown
Reset recorded footage: to clear all recordings from the Pi -- after a filename-format
change, or just to reclaim the card -- use `just raspi-reset-data`. It stops `dancam`,
deletes everything under `/data/rec` (segments plus the witness/time state, so the next
run restarts at seq 0 / session 1), then restarts the service and waits for it to answer
`/v1/health`. It refuses to run unless `/data` is a mounted filesystem, and it always
attempts to restart `dancam` even if the wipe or the run is interrupted -- failing loudly
(non-zero, "recording is DOWN") if the service does not come back and answer `/v1/health`,
so a failed or interrupted reset is never mistaken for a clean one. It previews what will
be deleted and prompts first; set `DANCAM_YES=1` to skip the prompt.

```sh
just raspi-reset-data                 # prompts before wiping /data/rec
DANCAM_YES=1 just raspi-reset-data    # unattended
```

Leaving old-format segments in place is harmless -- the service ignores names it cannot
parse and the seq witness stays monotonic -- so this reset reclaims space and clears
stale footage; it is not required for correctness.
```

## Verification

Hardware-free (on the Mac, no Pi):
- `just --list | grep raspi-reset-data` shows the recipe with its `#` doc comment.
- `just --dry-run raspi-reset-data` prints the recipe body without executing it,
  confirming the `Justfile` parses and the recipe renders. (It does not run the shell, so
  it does not exercise the runtime `HOST`/`SSH_KEY` expansion -- that is covered by the
  physical-Pi runs below.)
- Skim `raspi/README.md` section 8 to confirm the note sits after `Service management on
  the Pi:` and before `## 9`, and renders as valid Markdown (nested fence closes).

With a physical Pi (physical-Pi-only -- the local `just raspi-mock` is an HTTP service on
the Mac with no sshd/systemd/`dancam` unit, so it cannot exercise this recipe; do not
point `DANCAM_HOST` at an unrelated SSH host):
- With footage present, run `just raspi-reset-data`; confirm the preview prints a
  non-zero size/entry count, answer `y`.
- Afterward: `ssh dancam.local 'ls -la /data/rec'` shows the dir empty (no `state/`),
  and `ssh dancam.local 'systemctl is-active dancam'` reports `active`.
- Record a short clip, then pull the clip list and confirm the new segment starts at
  `seq 0` / `session 1` (fresh witness), proving the reset cleared the high-water.
- Re-run against an already-empty `/data/rec` to confirm the `-delete` no-op and the
  restart still succeed.
- Confirm the `[y/N]` default: run and press Enter -> prints `aborted`, exits non-zero,
  and the Pi is untouched (`systemctl is-active dancam` still `active`, footage intact).
- **Mount-witness abort, not-mounted (F1):** with `/data` not mounted (temporarily
  `sudo umount /data`, or a bench box where `/data` is a plain dir on `/`), run
  `just raspi-reset-data`; confirm it prints the `ABORT: /data is not a mounted
  filesystem` message, exits non-zero, never runs `systemctl stop` (service stays
  `active`), and `/data/rec` is untouched. Remount `/data` afterward.
- **Mount-witness abort, same-device bind mount (F1 -- the case `mountpoint -q` would
  miss):** with the real `/data` unmounted, bind-mount a root-fs directory there
  (`sudo mount --bind /var/tmp /data`) so it is a genuine mount entry but shares `/`'s
  device; run the recipe and confirm it still aborts on the `same device as /` branch (the
  `stat` predicate rejects it even though `mountpoint -q /data` would return success).
  `sudo umount /data` and remount the real partition afterward.
- **Restart-on-delete-failure, loud (F2):** make one entry undeletable
  (`sudo chattr +i /data/rec/<file>`), run the recipe and answer `y`; confirm
  `find -delete` fails, the recipe exits non-zero, and `systemctl is-active dancam` still
  reports `active` -- the cleanup restarted the service. Clean up with `sudo chattr -i`.
- **Restart-on-interruption (F2):** during the delete, Ctrl-C the recipe (or drop the SSH
  link); confirm the cleanup still runs and `systemctl is-active dancam` returns to `active`,
  *and* that the recipe **exits non-zero and does NOT print the `==> /data/rec cleared ...`
  success line** -- proving an interrupted run is reported as a failure, not a clean reset
  (the `EXIT`-only trap terminates with `128+signum`, so the interruption is never masked by
  a `$?` that happened to be `0`).
- **Restart health-check failure, loud (F3):** force dancam to start but never serve, so
  `systemctl start` succeeds while `/v1/health` stays unreachable -- e.g. add a drop-in that
  points the bind at an unassignable address (`sudo systemctl edit dancam` with a `[Service]`
  / `Environment=DANCAM_BIND=192.0.2.1:8080` stanza, TEST-NET-1) so every restart execs but
  the process exits with a bind error and crash-loops. Run
  `DANCAM_HEALTH_TIMEOUT=10 just raspi-reset-data` and answer `y`; confirm it waits ~10s,
  prints `dancam did not answer /v1/health`, and exits non-zero (the wipe still happened --
  this is a test box). Then `sudo systemctl revert dancam && sudo systemctl daemon-reload`,
  start dancam, and re-run to confirm a clean, health-verified reset.
