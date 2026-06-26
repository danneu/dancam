# Plan: notify when `raspi-deploy` is actually ready to test

## Context

`just raspi-deploy` (which shells out to `raspi/deploy.sh`) cross-builds the
service, ships it to the Pi, restarts `dancam`, and does a **one-shot**
`curl /v1/health`. It can take a while (Nix cross-build + rsync + restart), so
Dan switches to something else and misses when it finishes.

Two problems to solve:

1. **No "done" ping.** Add a macOS desktop notification when the deploy
   finishes (Dan's only dev box is an M1 Mac, so `osascript` is the natural fit).
2. **The current end-of-run signal is unreliable.** The health step is
   `ssh ... "curl -fsS .../v1/health" && echo` -- a single attempt, and because
   it sits in an `&&` list, `set -e` does **not** fail the script if the service
   isn't answering yet (the `==> health check` block in `raspi/deploy.sh`). So a
   naive "notify on exit" would fire **too soon** -- before the restarted service
   is actually serving.

The notification must mean **"the service is back up; go test it."** Per the
explore, `/v1/health` only confirms the HTTP server is up (returns `uptime_s`,
`boot_id`, `recording`); it does **not** report camera warm-up
(`raspi/service/src/health.rs#health`). Dan confirmed that gating on
`/v1/health` returning 200 is the right "ready" bar. The deploy restarts the
`dancam` *service*, not the whole Pi (`Type=exec`, `Restart=on-failure` in
`raspi/dancam.service`) -- but a poll-until-healthy loop covers both a plain
service restart and a full reboot identically: in both cases it just waits until
the endpoint answers again.

## Approach

All changes are in **`raspi/deploy.sh`** (the `raspi-deploy` Just task already
just calls it, so it needs no edit -- and direct `./raspi/deploy.sh` runs benefit
too). No Pi-side / onboard state changes.

### 1. macOS notification helper + EXIT trap

Add near the top (after the `HOST`/`SSH_KEY`/`PORT` vars):

- A `notify_done()` function whose **first statement is `local rc=$?`** -- before
  the `osascript` guard or any other command. (Verified empirically: if anything,
  even `command -v osascript`, runs first, `$?` is clobbered to that command's
  status -- `0` on Dan's Mac -- so a *failed* deploy would take the success
  branch, the exact false-"ready" ping this plan exists to kill.) Then, via
  `osascript`, show a notification titled `dancam deploy`:
  - cancel (`rc == 130`, Ctrl-C): `return 0` without notifying -- a user abort
    (typically during the long Nix build) is not a broken deploy, so stay quiet.
  - success (`rc == 0`): body `"Up on $HOST -- ready to test"`, sound `Glass`.
  - failure (other non-zero `rc`): body `"FAILED (exit $rc) -- see terminal"`,
    sound `Basso`.
  - No-op (`return 0`) when `osascript` is absent (non-macOS); place the
    `command -v osascript` guard *after* `local rc=$?`.
- `trap notify_done EXIT`.

Because `deploy.sh` is `set -euo pipefail`, the EXIT trap fires exactly once on
any exit path: a clean finish notifies success; a failed build/rsync/install or
a health-timeout (below) exits non-zero and notifies failure (a broken deploy
also pings Dan back). The one carve-out is a Ctrl-C cancel (`rc == 130`), which
stays silent per the `notify_done` bullet above.

### 2. Replace the one-shot health check with poll-until-healthy

Replace the current `==> health check` block (the one-shot curl) with a bounded
retry loop, run **Mac-side** so it survives the Pi being unreachable (covers the
full-reboot reading of the request, not just a service bounce):

```bash
HEALTH_TIMEOUT="${DANCAM_HEALTH_TIMEOUT:-60}"
echo "==> waiting up to ${HEALTH_TIMEOUT}s for dancam to answer /v1/health on $HOST"
deadline=$(( $(date +%s) + HEALTH_TIMEOUT ))
until ssh -i "$SSH_KEY" -o ConnectTimeout=5 "$HOST" \
        "curl -fsS --max-time 5 -o /dev/null http://localhost:$PORT/v1/health" 2>/dev/null; do
  if (( $(date +%s) >= deadline )); then
    echo "!! dancam did not answer /v1/health within ${HEALTH_TIMEOUT}s" >&2
    exit 1
  fi
  sleep 2
done
echo "==> dancam is up and serving on $HOST -- ready to test."
echo "==> deployed."
```

Notes:
- The `until <cmd>; do ...; done` condition is allowed to fail under `set -e`, so
  failing probes don't abort the script -- only the explicit timeout `exit 1`
  (which the EXIT trap turns into a failure notification) does.
- `-o ConnectTimeout=5` bounds SSH *connection* setup and `--max-time 5` bounds
  the *HTTP response*, so a probe that connects but stalls without replying can't
  outlast the deadline (which is only re-checked *between* probes) -- the
  `HEALTH_TIMEOUT` guarantee actually holds. `2>/dev/null` keeps the probe quiet
  while the Pi/service is still coming back. Each probe is the same Pi-side
  `curl localhost` idiom the script already used.
- The check runs **after** the install+restart SSH block returns, so a 200 means
  the freshly-restarted instance is answering (the old process is already gone).

### 3. Document the new knob

- In `deploy.sh`'s header comment, add `DANCAM_HEALTH_TIMEOUT` (default `60`,
  seconds to wait for `/v1/health` after restart) to the list of overridable env
  vars alongside `DANCAM_HOST` etc.
- Update **`README.md`** section "7. Deploy and run the service": change the
  "enables/restarts the service, and curls `/v1/health`" sentence to reflect that
  it now **waits for** `/v1/health` to answer (up to `DANCAM_HEALTH_TIMEOUT`s) and
  fires a macOS notification when ready. This is required because the README
  documents the deploy step's behavior.

## Files

- `raspi/deploy.sh` -- notification helper + EXIT trap, header-comment env knob,
  poll-until-healthy loop replacing the one-shot curl. (primary)
- `README.md` -- one-sentence accuracy update in section 7. (docs)
- `Justfile` / `raspi/dancam.service` / Pi config -- **unchanged**.

## Out of scope

- Waiting for the camera to emit its first preview frame (Dan chose the
  `/v1/health` bar; camera warm-up isn't separately observable via the API
  today).
- Cross-platform notifications (Mac-only dev box; helper no-ops elsewhere).

## Verification

1. **Happy path:** `just raspi-deploy` with the Pi on home Wi-Fi. Expect the new
   `==> waiting ...` line, then `==> dancam is up and serving ... ready to test`,
   and a macOS banner `dancam deploy / Up on dan@dancam.local -- ready to test`
   with the `Glass` sound. Confirm the banner appears only after the health line,
   not before.
2. **Slow/again:** re-run immediately (idempotent) -- the probe should succeed on
   the first iteration and still notify.
3. **Failure ping:** simulate a non-coming-back service, e.g.
   `DANCAM_HEALTH_TIMEOUT=6 DANCAM_PORT=9 just raspi-deploy` (wrong port so
   `/v1/health` never answers). Expect the timeout message, a non-zero exit, and
   a `dancam deploy / FAILED (exit 1)` banner with the `Basso` sound.
4. **Cancel stays quiet:** Ctrl-C during the build/wait. Expect **no** banner
   (the `rc == 130` carve-out), confirming a deliberate abort isn't reported as a
   failed deploy.
5. **Static check:** `bash -n raspi/deploy.sh` parses clean; eyeball that
   `set -euo pipefail` + the `until` loop don't abort on probe failures, and that
   `local rc=$?` is the first line of `notify_done`.
6. No Pi onboard state changed, so no `just raspi-provision` re-run is needed.
