# Pi service runtime and request tracing

The camera unit's control and media service is a small Rust program built around
Axum and Tokio. It implements the app-Pi HTTP boundary, coordinates recording and
storage state, and supervises the separate camera owner without putting the camera
stack or a managed runtime inside the API process.

This page owns the service language and runtime, host-to-Pi build and deployment
model, HTTP request tracing, request-id policy, and log-access path. The
[transport boundary](../boundary/transport.md) owns routes and wire semantics;
[recording](recording.md) owns the camera subprocess protocol and supervision;
[storage](storage.md) owns footage and ring state; and
[provisioning](provisioning.md) owns the system user and onboard dependencies.

## Runtime boundary

`raspi/service/` builds the `dancam` Rust binary. Axum provides the HTTP router and
Tokio provides the concurrent runtime for control requests, SSE events, MJPEG
preview, ranged clip pulls, background observation, and camera supervision. The
service can therefore keep the independent control, event, preview, and media planes
responsive without a garbage-collected runtime competing with the camera pipeline on
the Pi Zero 2 W's 512 MB of RAM.

The camera remains out of process. The deployed Rust service starts and supervises
`python3 /usr/local/lib/dancam/camera.py`, which owns Picamera2, libcamera, the
hardware encoders, and PyAV/libav. The service never links libcamera. A camera-stack
crash can interrupt recording, but it cannot take down the HTTP diagnostics and
control process. The stdio protocol and restart behavior are specified by the
[recording design](recording.md#camera-ownership-and-streams).

The original service design expected an `rpicam-vid` child. Concurrent recording
and preview later required one Picamera2 owner and added the Python, Picamera2,
NumPy, and native media runtime stack to the image. This did not change the Rust
service language or the subprocess crash boundary. A future Rust camera owner may
remove that stack, but it remains a separate process.

Local runs default to the mock backend and loopback binding. The deployed unit sets
`DANCAM_BACKEND=camera` and `DANCAM_BIND=[::]:8080` in
`raspi/dancam.service`. The unit runs as the fixed `dancam` system user, starts on
boot, and restarts the Rust service after failures. Recording itself still starts
through the API rather than automatically at service start.

## Lifecycle and bounded shutdown

The service installs fallible SIGINT and SIGTERM monitors before constructing a
backend. One shared cancellation token then connects the signal monitor, HTTP
streams, camera or mock owner, heartbeat, telemetry, and ring GC. A coordinator
owns every long-lived task. A signal or unexpected server completion cancels the
token; cancellation is a clean exit only when the server, backend, and workers all
join successfully.

Cancellation starts teardown branches concurrently. The HTTP branch serves the
Axum router through `axum-server` from the configured dual-stack listener. Its
owned handle gives connections 2 seconds to drain and then closes every remaining
connection. SSE and MJPEG additionally observe the token and normally reach EOF
before that deadline. The camera owner performs strict footage-safe retirement at
the same time, while heartbeat, telemetry, and GC stop scheduling new iterations
and join. The mock backend likewise owns and joins its frame and recording tasks,
flushing an active final segment before success.

Started blocking filesystem work is not abortable. Its owning worker waits for the
operation before joining, and Tokio may likewise wait for request-scoped blocking
work after a force-closed request. A truly stalled filesystem can therefore still
reach systemd's final SIGKILL; the existing abrupt-power-loss storage contract is
the safety boundary for that exceptional case.

## Build and deployment

Release code is cross-compiled on the Apple Silicon development Mac; it is never
built on the 512 MB Pi. The Nix development shell supplies Rust with the
`aarch64-unknown-linux-musl` target, Zig, and `cargo-zigbuild`. The Rust artifact is
a static musl binary, so it has no target glibc coupling and needs no Rust toolchain,
package install, virtual environment, or shared-library setup on the read-only car
image.

`just raspi-deploy` cross-builds the release binary, then ships and installs:

- the Rust binary at `/usr/local/bin/dancam`;
- the camera child at `/usr/local/lib/dancam/camera.py`.

The deploy script restarts the already-provisioned unit and waits for canonical
status and recording readiness. Ansible installs the tracked unit, so unit changes
require a provisioning run; deploy remains the fast binary/camera code-change loop.
The writable development image and read-only car image use the same service artifact
set.

## Request tracing

An outer Axum middleware gives every HTTP request the same structured tracing path,
including normal handlers, router 404s, and host-allowlist 421 responses. It:

- resolves a safe inbound `x-request-id` or generates a local id;
- opens a `request` span containing `request_id`, `method`, and `path`;
- emits an INFO `received` line and an INFO `response` line with `status` and
  `latency_ms`; and
- echoes the resolved id in the response `x-request-id` header.

The span covers handler-future work and the access lines. It does not extend into
work performed later by an SSE or MJPEG response body. For streaming endpoints,
`latency_ms` therefore measures time until the response is ready, effectively time
to first byte, rather than total stream lifetime.

Inbound request ids are accepted only when they are non-empty, at most 128 bytes,
and contain only ASCII letters, digits, `.`, `_`, or `-`. Any other value is ignored
and replaced. This prevents a client from injecting oversized or garbage values into
the journal or response headers while still allowing the app to supply a correlation
id.

## Generated request ids

When no safe inbound id exists, the service stringifies the pre-increment value from
a per-process `AtomicU64` counter stored in `AppState`. The counter starts at `1`;
`fetch_add(1, Ordering::Relaxed)` yields `1`, `2`, `3`, and so on. Relaxed ordering
is sufficient because the counter supplies a unique, roughly monotonic sequence for
one service invocation and does not synchronize any other state.

Generated ids intentionally repeat across service invocations. The visible reset to
`1` marks a process start, whether caused by a boot, `Restart=on-failure`, a deploy,
or a manual restart. When searching persistent logs, correlate a generated id by
time and its neighboring reset marker, or scope journald to the current systemd
invocation:

```sh
journalctl -u dancam \
  _SYSTEMD_INVOCATION_ID="$(systemctl show -p InvocationID --value dancam)"
```

`journalctl -b` and the `x-dancam-boot-id` response header narrow by boot, not by
service invocation, so neither alone disambiguates restarts within one boot. Safe
inbound ids remain unchanged and are not part of the generated counter namespace.

## Log retention and access

The Rust process writes structured `tracing` output to stdout, and systemd stores it
in journald. Persistent journal state lives under `/persist`, so request evidence
survives service restarts and reboots. The operator path is SSH plus journald:

```sh
journalctl -u dancam -f
journalctl -u dancam --grep '<request-id>'
```

There is no `GET /v1/logs` endpoint. Journald remains available when the service is
crashed or wedged, exactly when logs matter most; an in-process HTTP log surface
would not. Add remote log access only when a real non-SSH consumer, such as an
in-app diagnostic view, needs it.

Runtime verbosity uses the existing `RUST_LOG` support in
`tracing_subscriber::fmt::init()`. The current `Targets` filter accepts
`target=level` directives such as `RUST_LOG=dancam=debug`. It deliberately does not
enable the heavier span/field directive and regex machinery from `env-filter`.

## Decision log

### 2026-06-23 -- Write the Pi service in Rust

(absorbed from raspi ADR 05, 2026-06-23)

The camera unit needed one small, long-lived service for control, events, preview,
clip access, camera supervision, and storage coordination. It had to share a 512 MB
board with the camera pipeline and access point, survive abrupt-power recovery, fit a
read-only-root deployment, and cross cleanly from a macOS development host to
aarch64 Linux. A heavy runtime, garbage-collection pressure, target-side build, or
runtime package installation would all consume scarce resources or add failure modes.
At the time, the planned control surface also included incident locking; the later
phone-owned incident design removed that Pi mutation without affecting the runtime
choice.

Rust with Axum and Tokio was selected for a compact non-GC process, compile-time
memory and thread safety, and direct support for the API's awkward concurrent shapes:
MJPEG multipart streaming, SSE, and ranged clip pulls. The intended artifact was one
static `aarch64-unknown-linux-musl` binary cross-built with `cargo-zigbuild` or
`cross`, copied beside a systemd unit, and never compiled on the Pi. Static linking
removed glibc-version coupling and matched a future read-only root.
Keeping the Rust artifact to one inert file was also expected to make atomic swaps
and retaining a previous binary for rollback straightforward.

The camera was deliberately placed behind a supervised subprocess instead of linked
into the service. At the time that child was expected to be `rpicam-vid`, which made
the language choice independent of Python-centric libcamera bindings and kept the
camera stack independently upgradable. Its flag-only camera control was knowingly
coarser than Picamera2, but its surface covered the v1 needs understood at the time.

The expected benefits were RAM headroom for camera and Wi-Fi work, no GC pauses in
streaming paths, a small shared-library surface, and stronger safety for a
crash-critical always-on service. The tradeoffs were a host-side cross toolchain and
a slower build-and-copy inner loop than editing an interpreted program in place.
Incremental builds and a deploy script made that acceptable.

Go was a viable static-binary alternative and its GC pauses would probably have been
fine, but Rust offered a tighter footprint, stronger guarantees, and the owner's
preferred fit. Python plus Picamera2 offered the richest and fastest camera bring-up,
but was rejected for the HTTP service because its interpreter and dependencies had
to be baked into the image and carried more RAM, GC, and runtime failure surface;
Picamera2 later earned a narrower role as the separate camera child. C or C++ linked
directly to libcamera offered maximum control but added needless manual-memory risk
and collapsed the isolation boundary. Node, TypeScript, and other managed runtimes
were rejected for footprint without an offsetting benefit. `tiny_http` remained a
possible lighter Rust HTTP layer only if Axum's dependency or binary cost proved
material.

### 2026-06-25 -- Retain the Rust service around a Picamera2 camera owner

(amendment absorbed from raspi ADR 05, 2026-06-25)

Concurrent recording and preview required one process to own libcamera and emit both
streams. The recording work therefore replaced the preview-only `rpicam-vid` child
with the current Python Picamera2 owner. This partly superseded the original camera
child, not the service-language or process-boundary decision.

The amendment reopened the image cost of Python, Picamera2, NumPy, and ffmpeg. Those
dependencies now have to be baked into the read-only car image unless the planned
all-Rust camera owner replaces them first. Keeping the camera out of process still
protects the Rust control API from a camera-stack failure and preserves a boundary
that a future camera implementation can reuse.

### 2026-07-01 -- Trace every HTTP request through journald

(absorbed from raspi ADR 13, 2026-07-01)

The service already logged lifecycle and failure events, but requests left no
method, path, status, or latency evidence. Even host-allowlist 421 rejections were
silent. Once persistent journald was available on the development image, the missing
access trail made app-Pi correlation and endpoint debugging unnecessarily difficult.

An Axum `from_fn` middleware was added around the whole router. It resolved and
echoed `x-request-id`, created a request span, and recorded response status and
latency through the existing `tracing` stdout path. Making it outermost ensured that
normal handlers, router 404s, and host-policy rejections all received the same header
and log treatment. Safe inbound ids were limited to 128 characters from a small
ASCII set so clients could not inject huge or malformed journal values. The initial
generated fallback was a UUID; the next day's decision replaced only that fallback
format with a counter.

The request span was intentionally limited to the handler future. Extending it over
SSE and MJPEG body work would add machinery for little current debugging value, so a
streaming access line measures response readiness rather than full lifetime.

SSH plus journald was kept as the log-access path. It remains usable when the Rust
process is down, unlike an in-memory buffer or HTTP endpoint. A `GET /v1/logs`
surface was deferred until a non-SSH consumer actually needs it.

Tower HTTP's trace and request-id layers were rejected because the existing Axum
middleware style could provide the behavior without adding `tower-http` and
promoting `tower` to a runtime dependency. An in-memory ring plus `/v1/logs` was
rejected because it disappears with the process. A `journalctl`-backed endpoint was
rejected for Linux-only behavior, poor mock/macOS parity, and a subprocess per
request. The `tracing-subscriber` `env-filter` feature was rejected because the
existing `Targets` filter already supported the required `target=level` control
without span/field parsing and regex machinery.

### 2026-07-02 -- Use short per-process request counters

(absorbed from raspi ADR 14, 2026-07-02)

UUID v4 request ids were correct but visually dominated the journal's access lines.
The main debugging workflow reads one service's time-ordered journal, where a short
local sequence is easier to scan. The relevant lifetime is a service invocation,
not a boot: systemd failure recovery, deployment, and manual restarts can all create
multiple processes before the Pi reboots.

A per-process `AtomicU64` on `AppState` replaced generated UUIDs. It starts at `1`
and uses relaxed `fetch_add`, giving each generated id uniqueness and rough ordering
within that invocation while making resets visually obvious. Safe client-provided
ids continue to pass through unchanged; unsafe values receive a generated counter.

The cost is deliberate per-invocation scope. A blind search for `42` across the
persistent journal can find several service runs, and neither boot-scoped journal
queries nor the boot-id response header distinguishes restarts inside one boot. Time
proximity, the neighboring reset to `1`, or systemd's invocation id provides the
missing scope.

Keeping UUID v4 was rejected because its global uniqueness was not worth 36 noisy
characters on every access line. A short random token was rejected because it gave
neither ordering nor a reset marker. A boot- or invocation-prefixed counter would
disambiguate runs but lengthen the common case; the local workflow preferred the
plain counter and accepted per-run-only uniqueness.

### 2026-07-16 -- Own bounded shutdown in one lifecycle coordinator

Connected SSE and MJPEG responses kept Axum's graceful drain alive indefinitely,
so systemd killed the service after 90 seconds before Rust ever asked the camera
child to finalize. The cgroup-wide SIGTERM could also kill Python first and make
the still-running supervisor respawn it during shutdown.

The service now installs signals before backend side effects and uses one shared
cancellation token. An owned `axum-server` handle provides a testable in-process
connection deadline while camera, mock, and background-worker cleanup begins in
parallel. `KillMode=mixed` leaves SIGTERM with the Rust owner and retains a
cgroup-wide SIGKILL at 10 seconds.

A universal response-body wrapper was rejected because only SSE and MJPEG benefit
from cooperative EOF; the server handle already bounds clips and stalled clients.
Racing Axum's ordinary drain against a timer without `axum-server` was rejected
because residual sockets would survive until process exit rather than close at the
deadline, making the connection bound untestable in process. A global blocking-task
registry was rejected because started blocking work cannot be aborted and its
durability-sensitive owners already await it.
