# ADR: Pi service language and runtime (Rust)

- **Status:** Accepted
- **Date:** 2026-06-23
- **Owner:** raspi
- **Related:** root `AGENTS.md`;
  [transport boundary](../../../docs/design/boundary/transport.md) (the wire contract
  this service implements); [Pi recording](../../../docs/design/pi/recording.md) (the
  read-only root the deploy model must respect); [Pi storage](../../../docs/design/pi/storage.md)
  (the in-process storage service this binary hosts)

> **Note (2026-06-25):** The subprocess-boundary decision stands, but the specific
> camera subprocess is **partly superseded by the
> [Pi recording design](../../../docs/design/pi/recording.md)**. `jet` replaces the
> preview-only
> `rpicam-vid` subprocess with a Python Picamera2 camera owner so one process can own
> libcamera and emit concurrent recording + preview streams. The service remains Rust;
> the reopened cost is carrying the Python/Picamera2/numpy stack on the dev image and
> either baking it into the future read-only car image or replacing it with the planned
> all-Rust camera owner first.

## Context

The camera unit runs one small, long-lived service that implements the app<->Pi
contract: a control API (start/stop, settings, time sync, incident lock), an events
stream (SSE), live preview (MJPEG), and clip listing + ranged pull. It also
supervises the camera capture and owns the storage ring buffer. We need to pick the
language and runtime it is written in, and the deploy model that follows from it.

The forces:

- **512 MB RAM, always-on while driving.** The service shares the board with the
  camera pipeline and the Wi-Fi AP. A heavy runtime or GC pressure is a real cost,
  not a rounding error.
- **Read-only root (car image).** The recording design requires a read-only root. That is
  hostile to runtimes that expect to install packages, build venvs, or write
  scratch state at runtime -- whatever the service needs must be baked into the
  image as inert files.
- **Crash-critical.** The unit takes abrupt power loss and must come back cleanly
  and not fall over mid-drive. Fewer runtime failure modes is better.
- **Cross-platform development.** Dan develops on macOS; the target is aarch64
  Linux. The toolchain has to cross the gap cleanly.
- **The camera is consumed as a subprocess, not linked.** Capture is `rpicam-vid`
  (a binary that ships with the OS). The service spawns and supervises it and reads
  its output. This means the service language does **not** need libcamera bindings,
  which frees the choice from the Python-centric camera ecosystem.

## Decision

**Write the Pi service in Rust**, cross-compiled on the dev host to a single static
`aarch64-unknown-linux-musl` binary, deployed as one file under systemd.

1. **Language: Rust.** HTTP via `axum`/`tokio`, which cover the three awkward shapes
   this API needs -- MJPEG `multipart/x-mixed-replace` streaming, SSE, and `Range`
   clip pull. `tiny_http` is an acceptable lighter alternative if dependency/binary
   size becomes a concern.
2. **Camera via subprocess.** The service spawns and supervises `rpicam-vid`
   (`std::process` / tokio) and reads its stdout; it never links libcamera. This
   keeps the camera stack and the service independently upgradable and avoids FFI.
3. **Cross-compile on the dev host; never build on the Pi.** 512 MB cannot build a
   real Rust dependency tree without thrashing or OOM. Tooling: `cargo-zigbuild`
   (Zig as the cross-linker) or `cross` (Docker). Target musl for a fully static
   binary with no glibc-version coupling.
4. **Deploy = one static binary + a systemd unit.** `rsync` the binary, restart the
   unit. A static binary is exactly what a read-only root wants: nothing to install,
   no shared-library surface, atomic to swap and to roll back. This fits the
   dev-image / car-image split (see the Build / run section in `raspi/AGENTS.md`).

## Consequences

- **Fits 512 MB with headroom.** No GC and a small static footprint leave room for
  the camera pipeline and the AP; no GC pauses to perturb streaming.
- **Deploy matches read-only root.** No pip/venv/apt at runtime; the artifact is one
  inert file baked into the image. Trivial rollback (keep the previous binary).
- **Compile-time safety on a crash-critical, always-on service.** Memory/thread
  safety and `tokio` concurrency for the parallel planes (preview + control + pull
  at once) reduce the class of bugs that would strand the unit mid-drive.
- **The dev host becomes part of the toolchain.** On-Pi builds are off the table, so
  a working cross-compile setup (Zig or Docker) is required to ship. Documented in
  Build / run.
- **Slower inner loop than an interpreted language.** Every change is a build +
  copy, not an edit-in-place. Mitigated by incremental builds and a `deploy.sh`;
  acceptable for a service this size.
- **Camera control is coarser than Picamera2's native API.** We drive `rpicam-vid`
  flags rather than call libcamera directly. Accepted: the subprocess boundary is
  the price of decoupling the language from the camera stack, and the flag surface
  covers what v1 needs.

## Alternatives considered

- **Go.** Same static-binary, easy cross-compile, single-artifact virtues, with a
  gentler learning curve; GC pauses are small and would be fine here. Rejected on
  preference and fit -- Rust gives a tighter footprint and stronger guarantees, and
  Dan wants Rust. Either language would have worked; this is not a close
  correctness call.
- **Python + Picamera2.** Fastest path to first-light and the richest camera control
  (native libcamera, no shelling out). Rejected as the *service* language: a CPython
  runtime plus dependencies must be baked onto a read-only root (awkward), it carries
  higher RAM and GC, and it offers no compile-time safety for an always-on process.
  Picamera2 may still earn its keep as a throwaway tool during camera bring-up -- it
  just does not ship in the service.
- **C / C++ against libcamera directly.** Maximum control, no subprocess. Rejected:
  manual memory management on a crash-critical service is needless risk, and the
  subprocess model already gets us libcamera's capability without linking it.
- **Node / TypeScript or another managed runtime.** Heavier runtime and memory on a
  512 MB board with no offsetting benefit here. Rejected on footprint.
