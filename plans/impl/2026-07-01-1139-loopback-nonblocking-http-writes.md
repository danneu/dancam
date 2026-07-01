# Plan: non-blocking loopback HTTP writes (LoopbackMediaServer)

## Context

`app/DanCam/DanCam/Media/Stream/LoopbackMediaServer.swift` is the viewer-scoped
loopback HLS server that AVPlayer reads during progressive clip playback. It runs
everything on one serial `DispatchQueue`: accept, per-connection reads, request
parse, response build, the response **write**, every
`appendInitializationSegment` / `appendMediaSegment` / `publishPlaylistRoute`, and
`shutdown`.

The defect (review finding D-03, independently raised by review lanes D, C, and G):
`LoopbackMediaServer#send` flips the client socket to **blocking**
(`Self.setBlocking`) and writes the whole response in a synchronous
`while bytesWritten < count { Darwin.write(...) }` loop while holding that queue.
While a write is blocked on a full socket send buffer (a multi-MB GOP segment whose
consumer drains slowly, or a peer that stops reading), the queue cannot publish new
segments or update the playlist, and cross-queue `queue.sync` callers stall behind
it:

- `ProgressiveSegmenter.swift#consume` calls `server.checkForFailure()` after
  **every** appended access unit,
- `ProgressiveSegmenter.swift#finishInput` calls `checkForFailure()` +
  `hasFinalizedPlaylist()`,
- `ProgressiveSegmenter.swift#cancel` / `#fail` call `server.shutdown()` (teardown).

All reach the server through `LoopbackMediaServer#performOnQueueSync` ->
`queue.sync`. There is no write timeout. Net effect: HTTP client read speed couples
to media-pipeline progress and teardown latency. In the cooperative case (AVPlayer
drains promptly) this is a transient serialization bottleneck, not a deadlock --
but the code provides no bound, and the blocking flip is the lone exception to the
file's otherwise non-blocking, event-driven socket model.

**Intended outcome:** HTTP serving never blocks the serial queue on socket
backpressure. Segment publication, playlist updates, `checkForFailure`, and
`shutdown` stay responsive regardless of how slowly (or whether) a loopback reader
drains. This honors ADR 08's intent
(`app/docs/design/08-2026-06-27-progressive-fmp4-clip-playback.md` -- "All loopback
server state is confined to one serial domain ... The blocking demux -> assemble ->
writer append pipeline runs on a separate dedicated serial `DispatchQueue`"): the
fix keeps all server *state* on the one serial queue while removing blocking I/O
from it.

## Approach (the ideal solution)

Replace the blocking write with a **per-connection, non-blocking, event-driven
write** that mirrors the file's existing read-source pattern and stays entirely on
the one serial `queue`:

- The client socket is already non-blocking (`configureClientSocket` ->
  `setNonBlocking`); `send` stops flipping it to blocking.
- `send` stashes the response bytes + a write offset on the `ClientConnection`,
  cancels the read source (one request per connection; every response carries
  `Connection: close`), and attempts an **immediate inline flush**.
- The flush writes as much as the kernel accepts. If it fully drains, close the
  connection. If it hits `EWOULDBLOCK`/`EAGAIN`, arm a per-connection
  `DispatchSource.makeWriteSource` **targeting the same serial `queue`** and return
  -- the queue is freed. The write source re-enters the flush when the socket is
  writable again, continuing from the saved offset.

This is the "inline-flush, arm-a-write-source-only-on-backpressure" shape: the
common case (small responses -- playlist, init, small segments -- that fit the send
buffer) allocates no source and just writes-then-closes; only large/stalled
responses arm a source, and they never block the queue.

Because this introduces a **second fd-backed dispatch source per connection**, the
fix also takes correct file-descriptor ownership: every per-connection source (read
and write) gets a cancellation handler, and the socket fd is closed **only from the
last cancellation handler to run**, never inline after `cancel()`. This is mandated
by libdispatch's documented contract (`dispatch/source.h`: "Source cancellation and
a cancellation handler are required for file descriptor ... based sources in order
to safely close the descriptor. Closing the descriptor ... before the cancellation
handler is invoked may result in a race condition" if the fd number is reused; the
handler runs only "once the system has released all references to the source's
underlying handle"). The current code closes the fd inline right after `cancel()`,
and a second source per fd would double that unsupported surface -- so this fix
folds in the fd-lifetime correctness rather than deferring it. (This also resolves
the separate review finding about closing the fd before the cancellation handler.)

Why not the alternatives: offloading the blocking write to a separate concurrent
queue reintroduces cross-queue file-descriptor and `state.connections` lifetime
hazards (a write in flight on another queue racing `shutdown`'s `Darwin.close`);
bounding the blocking write with `SO_SNDTIMEO` only caps the stall instead of
removing it. Keeping all socket I/O on the one serial queue is the file's core
invariant and the robust choice.

## Implementation

All in `app/DanCam/DanCam/Media/Stream/LoopbackMediaServer.swift` unless noted. The
change is **purely internal to `LoopbackMediaServer`** -- it does not touch
`FMP4SegmentSink`, `FMP4Segmenter`, or `ProgressiveSegmenter`. Follow the file's
conventions: every type `nonisolated`; reference types guarded by the queue are
`@unchecked Sendable`; all POSIX calls `Darwin.`-qualified; private queue-only
helpers are unsuffixed (the `...OnQueue` suffix is used only to disambiguate a
public async method from its on-queue body, which these helpers are not).

### 1. `ClientConnection` -- add outbound + lifecycle state

Add five fields, all touched only on the serial queue (so `@unchecked Sendable`
stays sound). `pendingResponse` is written once in `send` and read-only thereafter;
only `writeOffset` mutates across write-source firings. `activeSourceCount` /
`isClosing` drive fd ownership (section 6).

```swift
var pendingResponse = Data()        // set once in send(); stable afterward
var writeOffset = 0                 // advances as bytes drain
var writeSource: DispatchSourceWrite?
var activeSourceCount = 0           // created+resumed sources not yet cancel-delivered
var isClosing = false               // set by closeConnection; gates the fd close
```

### 2. Outcome enum (nested, near `State`/`Route`)

```swift
private enum WriteOutcome { case drained, wouldBlock, failed }
```

### 3. Rewrite `send` -- stash + immediate flush, never block

```swift
private func send(response: Data, to id: UUID) {
    guard let connection = state.connections[id] else { return }
    connection.readSource?.cancel()
    connection.pendingResponse = response
    connection.writeOffset = 0
    flushPendingWrite(for: id)
}
```

### 4. `flushPendingWrite(for:)` + `writeRemainingBytes(of:)` -- the loop

Teardown happens **outside** `withUnsafeBytes`. `writeRemainingBytes` only reads the
buffer and mutates `writeOffset` (an `Int`); it never cancels a source, closes an
fd, or mutates `state.connections`. This structurally avoids freeing the buffer
while an unsafe pointer into it is live.

```swift
private func flushPendingWrite(for id: UUID) {
    guard let connection = state.connections[id] else { return }
    switch writeRemainingBytes(of: connection) {
    case .drained, .failed: closeConnection(id)
    case .wouldBlock:       ensureWriteSource(for: id, connection: connection)
    }
}

private func writeRemainingBytes(of connection: ClientConnection) -> WriteOutcome {
    let response = connection.pendingResponse
    let count = response.count
    if connection.writeOffset >= count { return .drained }   // also covers empty
    return response.withUnsafeBytes { raw -> WriteOutcome in
        guard let base = raw.baseAddress else { return .drained }
        while connection.writeOffset < count {
            let result = Darwin.write(
                connection.fileDescriptor,
                base.advanced(by: connection.writeOffset),
                count - connection.writeOffset
            )
            if result > 0 { connection.writeOffset += result; continue }
            if result < 0 && (errno == EWOULDBLOCK || errno == EAGAIN) { return .wouldBlock }
            return .failed   // result == 0, or EPIPE/ECONNRESET/EINTR/other (fatal-for-connection)
        }
        return .drained
    }
}
```

Errno handling mirrors the inbound read path (`readAvailableData`): `EWOULDBLOCK`/
`EAGAIN` means "stop, come back"; any other errno is fatal-for-connection. Because
`SO_NOSIGPIPE` is set, a dead peer surfaces as `EPIPE`/`ECONNRESET` here (not a
signal). `result == 0` is treated as failed to forbid an infinite spin.

### 5. `ensureWriteSource(for:connection:)` -- create-once, resume-once

```swift
private func ensureWriteSource(for id: UUID, connection: ClientConnection) {
    if connection.writeSource != nil { return }              // already armed
    let source = DispatchSource.makeWriteSource(
        fileDescriptor: connection.fileDescriptor, queue: queue)
    source.setEventHandler { [weak self] in self?.flushPendingWrite(for: id) }
    source.setCancelHandler(handler: sourceCancelHandler(for: connection))  // section 6
    connection.writeSource = source
    connection.activeSourceCount += 1
    source.resume()
}
```

The cancel handler + `activeSourceCount += 1` give the write source correct fd
ownership (section 6). The event handler captures the value-type `id` and re-fetches
the connection, mirroring `readAvailableData(from:)`. The source is resumed exactly
once and cancelled exactly once (in `closeConnection`); it is never suspended/resumed
mid-write, avoiding unbalanced-resume crashes.

### 6. File-descriptor ownership via cancellation handlers

The per-connection fd must be closed only from a cancellation handler (see Approach
and `dispatch/source.h`). With two sources possible per fd, close it when the **last**
source's cancellation handler runs. A shared handler decrements the count and closes
the fd exactly once, gated on `isClosing` so the read source's *transition* cancel in
`send` (where a write source is taking over) does not close a still-needed fd:

```swift
private func sourceCancelHandler(for connection: ClientConnection) -> @Sendable () -> Void {
    { [connection] in                                  // runs on the serial queue
        connection.activeSourceCount -= 1
        if connection.isClosing && connection.activeSourceCount == 0 {
            Darwin.close(connection.fileDescriptor)     // exactly once, last handler
        }
    }
}
```

Both creation sites set this handler (before `resume()`) and increment the count:

- **Read source** (`acceptAvailableConnections`, previously had no cancel handler):
  `source.setCancelHandler(handler: sourceCancelHandler(for: connection))` and
  `connection.activeSourceCount += 1` before `source.resume()`.
- **Write source** (`ensureWriteSource`, section 5): same.

`closeConnection` now requests teardown and cancels both sources, but does **not**
close the fd inline -- the last cancellation handler does:

```swift
private func closeConnection(_ id: UUID) {
    guard let connection = state.connections.removeValue(forKey: id) else { return }
    connection.isClosing = true
    connection.readSource?.cancel()
    connection.writeSource?.cancel()
    // fd closed by the last cancellation handler (activeSourceCount -> 0), not here.
}
```

Why the count never rests at 0 outside teardown: dispatch cancellation handlers are
submitted as **separate queue blocks** (they run only after the current block
returns), so within a single `send` block the write source is created (count
incremented) before the read source's cancel handler can run. Thus `activeSourceCount`
reaches 0 only after `closeConnection` has set `isClosing` -- the fd closes exactly
once, only during teardown, only from a cancellation handler. `removeValue` keeps
`closeConnection` idempotent. The handlers capture `connection` strongly; the
transient cycle (source -> handler -> connection -> source) is broken when GCD
releases the handler after it runs, so connections and the `queue` deallocate cleanly
even on server `deinit`. The listener accept source already follows this pattern (its
cancel handler closes the listener fd) and is unchanged.

### 7. Delete `setBlocking`

`LoopbackMediaServer#setBlocking` has exactly one call site (the `send` write flip),
removed by this change. Delete the method -- no dead code. (`setNonBlocking` stays;
it is still used by the listener and `configureClientSocket`.)

### 8. ADR + doc note

Update `app/docs/design/08-2026-06-27-progressive-fmp4-clip-playback.md` in the same
change (per the repo's "write it down" discipline -- this records a load-bearing
invariant, not a decision pivot). Do **not** rewrite the Decision-section prose in
place: ADR 08 already records post-acceptance refinements as dated notes (its
"2026-06-30 update:" bullet in Consequences) and root `AGENTS.md#Design decisions
(ADRs)` is append-only ("never silently rewrite"). So:

- Add a dated update note in the **Consequences** section, matching the existing
  "2026-06-30 update:" bullet style: HTTP response writes are non-blocking and
  event-driven (per-connection write sources on the server's serial queue), so a slow
  or stuck loopback reader cannot stall segment publication, playlist updates, or
  teardown. Leave the original "All loopback server state is confined to one serial
  domain" Decision paragraph unedited.
- Extend the Mitigations "Tests cover ..." sentence to include non-blocking serving
  under reader backpressure -- that list is a living inventory, so editing it in place
  is fine.

No README change (no Pi/provisioning impact). No new ADR (`just adr-check` unaffected
-- ADR gains a dated note plus a test-inventory line, no new file).

## Concurrency safety (why this is correct)

Single serial `queue` + write source targeting that same `queue` => no two of these
blocks ever run concurrently; "races" collapse to ordering of serialized blocks.

- **Shutdown/close during a pending or armed write:** `shutdown` and the write-source
  handler are both blocks on the one queue, so they are mutually exclusive. A handler
  GCD already enqueued before `cancel()` still bails on
  `guard let connection = state.connections[id]` after `removeValue`. The fix also
  removes the old coupling where `shutdown`'s own `queue.sync` blocked behind a
  stalled write.
- **Write source on an fd whose read source was just cancelled:** sound -- read/write
  sources register distinct kqueue filters (`EVFILT_READ` vs `EVFILT_WRITE`), and the
  fd is **not** closed when the read source is cancelled (it closes only when the last
  source's cancellation handler runs -- section 6), so the fd stays valid while the
  write source takes over.
- **fd reuse vs cancellation (fixed, not deferred):** the fd is closed only from a
  cancellation handler, after libdispatch has released its reference to the handle
  (`dispatch/source.h`). This eliminates the use-after-close / fd-reuse race that the
  old inline `Darwin.close(fd)` after `cancel()` risked -- a race the SDK header
  explicitly warns about, and that a second fd-backed source per connection would
  otherwise compound. `activeSourceCount` + the `isClosing` gate guarantee the fd is
  closed exactly once, only after both sources have delivered cancellation, only
  during teardown.
- **No busy-loop:** a level-triggered write source stays quiet while the send buffer
  is full and fires only when writable; each firing drains as much as the kernel
  accepts before returning.

## Out of scope (deliberately)

- **Per-request disk re-read** (`response(for:)` -> `RouteBody.load()` ->
  `Data(contentsOf:)`): defer. `.file`-backed routes are disk-backed on purpose to
  bound memory across long EVENT playlists; caching bytes in `Route` reintroduces
  unbounded memory growth. The read is a page-cache hit on a just-written temp file
  (bounded, sub-ms), categorically different from the unbounded socket-write stall
  this fix targets. Revisit only with profiling evidence (then: bounded LRU or
  off-queue read).
- **Server-side read-idle timeout** for partial-request connections that never send
  `\r\n\r\n`: pre-existing, low exposure (viewer-scoped, single AVPlayer client),
  unchanged by this fix.

Socket-write failures stay **connection-local**: `.failed` routes only to
`closeConnection`, never to `fail(...)`/`state.failure`. `LoopbackMediaServerError
.writeFailed` remains used only for disk-write failures in the append paths. A
broken client connection must never fail the whole server. No memory regression:
`response(for:)` already materialized the full response in memory; we hold that same
`Data` in `pendingResponse` until the async drain (one response in flight, released
when the connection closes) instead of draining it synchronously.

## Verification

Add tests in `app/DanCam/DanCamTests/Media/Stream/LoopbackMediaServerTests.swift`,
reusing `.tags(.networking)` and `.timeLimit(.minutes(1))`.

Tests B and D bound a server call that, under the *old* blocking code, parks in a
non-cancellable `queue.sync` (`checkForFailure` / `shutdown` -> `performOnQueueSync`
-> `queue.sync`). **Do not** use the task-group `withTimeout` from
`NWByteStreamTests.swift` for these: when its timeout child fires it calls
`group.cancelAll()` and rethrows, but `withThrowingTaskGroup` then *joins* (implicitly
awaits) the operation child before returning -- and a `queue.sync` block observes no
cancellation, so the helper is pinned past the 2 s deadline until the
`.timeLimit(.minutes(1))` fires. That would make the intended "fail fast against the
old behavior" probe hang for a minute and never reach the `defer` that closes the
client fd. Instead add a small deadline-bounded watchdog whose wait returns at the
deadline regardless of the operation's state (detached task + `DispatchSemaphore`):

    // Runs `operation` (which may block synchronously in queue.sync) on a detached
    // task; returns its result, or nil if it did not finish within `seconds`. The
    // semaphore's timed wait returns at the deadline independent of the operation --
    // unlike a task group, which would join the still-blocked child.
    private func resultWithin<T: Sendable>(
        _ seconds: Double, _ operation: @escaping @Sendable () -> T
    ) -> T? {
        let done = DispatchSemaphore(value: 0)
        let box = Box<T>()                          // read only after `done` signals
        Task.detached { box.value = operation(); done.signal() }
        return done.wait(timeout: .now() + seconds) == .success ? box.value : nil
    }

where `Box` is a tiny file-scope `@unchecked Sendable` reference holding a `var
value: T?`. The semaphore signal -> wait edge orders the `box` write before the read,
so no lock is needed on the read path. On timeout the helper returns `nil`, the test
asserts that failure, and its `defer` then closes the client fd; the resulting `EPIPE`
unblocks the abandoned detached task, which self-completes -- no async join (which a
non-async `defer` could not do anyway) is required. `TestTimeoutError` and the
task-group `withTimeout` are not needed by any of these tests, so nothing is copied
from `NWByteStreamTests.swift`. Existing tests
(`servesInitAndMediaRoutesWithHeadAndRanges`,
`servesGrowingEventPlaylistWithFrozenTargetDuration`,
`assignsContiguousSegmentIndicesUnderConcurrentAppends`,
`bindsToLoopbackAndDeletesWorkDirectoryOnShutdown`, ...) are the regression contract
and must still pass unchanged (each response fully delivered, then connection
closes).

New tests:

- **A. Large-body integrity over `URLSession` (core).** Append init + one ~8 MB
  media segment of deterministic content; `GET /seg0.m4s` via the existing
  `request(...)` helper; assert `200`, correct `Content-Length`, and **byte-for-byte**
  body. Exercises the offset-advance loop and (opportunistically) the
  `EWOULDBLOCK -> arm -> resume` cycle through the production-shaped client stack.

- **B. Publication not stalled by a partial (stop-reading) reader (core -- the
  regression guard).** `URLSession` cannot express "read a little, then stop", so add a
  small private raw-socket helper (`socket` / `setsockopt(SO_RCVBUF)` / `connect` /
  blocking-send-all / read loop / `close`), reused by tests C, D, and E. It supports
  the read modes each test needs: read a small fixed prefix (a few KB) then stop and
  hold the connection open (B, D), slow-drain the whole body (C), and read a prefix
  then close/RST (E). Steps: append init + a several-MB `seg0`;
  open a raw TCP socket to
  `127.0.0.1:<port>` (port from `URLComponents(url: server.mediaPlaylistURL)`), set a
  small client `SO_RCVBUF` (~8 KB) before `connect`, send
  `GET /seg0.m4s HTTP/1.1\r\n\r\n`, **read a small fixed prefix (a few KB), then stop
  reading** and hold the connection open; then
  call `resultWithin(2) { appendMediaSegment(seg1); try? checkForFailure(); finish();
  return hasFinalizedPlaylist() }` and assert the result is `true` (finished in time
  and finalized). With the old blocking code the queue is stuck in the `seg0` write,
  the detached operation parks in `queue.sync`, and `resultWithin` returns `nil` at the
  deadline (the assertion fails, flagging the regression); with the fix it returns
  `true` promptly. Determinism, without a wall-clock settle: **receiving the prefix is
  a happens-after proof that the server's `send` is already executing on the serial
  queue**, and the small client `SO_RCVBUF` + unread multi-MB remainder force the very
  next writes to hit `EWOULDBLOCK` (fix: arm the write source, free the queue) or a
  blocked `Darwin.write` (old code: parked queue) -- far below any plausible loopback
  buffer sum. So a reintroduced blocking write parks the queue regardless of wall-clock
  timing (guard fires), and the fix passes regardless (CI-stable), without depending on
  a fixed sleep.
  `defer` closes the raw client fd **first**, then `server.shutdown()`; on the old-code
  path that `EPIPE` is what unblocks the still-parked detached operation (and the
  orphaned `shutdown`), so the test tears down cleanly instead of leaking a stuck task
  or hanging to the time limit. Document inline: bump the payload if a future OS
  massively enlarges loopback buffers.

- **C. Slow-draining reader, byte-for-byte integrity under forced backpressure
  (core).** Raw client with a small `SO_RCVBUF` reads a few KB, sleeps briefly, and
  repeats over a multi-MB body, asserting it ultimately receives the segment
  **byte-for-byte**. This is the integrity guard for the new resume logic: small
  `SO_RCVBUF` + multi-MB body + slow reads *deterministically* drive many
  `EWOULDBLOCK -> arm write source -> become writable -> resume from `writeOffset` ->
  drain` cycles, and the exact-bytes assertion verifies no byte is dropped,
  duplicated, or reordered across them. Required, not optional: Test A only hits
  backpressure opportunistically (`URLSession` drains promptly, so the resume path
  may never run) and Test B proves liveness while reading only a small prefix (it never
  verifies the full body) -- so a broken resume offset would truncate/corrupt a real
  slow-reader response while A and B still pass. Only C closes that gap. Cannot deadlock (the client always makes
  progress, so the server always eventually drains); ~1-2 s runtime, well under the
  `timeLimit`.

- **D. Shutdown stays responsive under backpressure (core).** The fix's *teardown*
  claim (shutdown no longer blocks behind a stalled write) needs its own test --
  Test B closes its client *before* its cleanup shutdown, so B never exercises
  shutdown under backpressure. Append init + a several-MB `seg0`; open a raw client
  (small `SO_RCVBUF`, send the GET), **read a small fixed prefix (a few KB) then stop
  reading**, and **keep the connection open** -- receiving the prefix proves the
  server's `send` is executing on the serial queue (no wall-clock settle), and the
  unread multi-MB remainder keeps it stalled/armed on the `seg0` write; then
  call `resultWithin(2) { server.shutdown(); return true }` and assert it is non-`nil`
  (shutdown returned before the deadline) **and**
  `FileManager.default.fileExists(atPath: server.workDirectory.path) == false`
  (shutdown removes the work directory synchronously -- same assertion as the existing
  `bindsToLoopbackAndDeletesWorkDirectoryOnShutdown`). Close the raw client fd only in
  `defer` (cleanup), *after* the assertions -- so even an old-code regression, where
  `shutdown`'s `queue.sync` blocks behind the stuck write and `resultWithin` returns
  `nil` at the deadline (both assertions fail, flagging the regression), still tears
  down cleanly: the deferred client close `EPIPE`s the stuck write, freeing the queue
  so the abandoned `shutdown` self-completes. With the old blocking code `resultWithin`
  times out; with the fix `shutdown` returns promptly.

- **E. A broken client connection stays connection-local (core).** The fix adds a new
  write-error path (`WriteOutcome.failed` -> `closeConnection`, never
  `fail(...)`/`state.failure`), and the plan leans on it as a safety claim ("a broken
  client connection must never fail the whole server") -- but A-D never observe it: B
  and D abort their clients only in `defer`, *after* their health assertions, so the
  `.failed` path runs unobserved during teardown. Drive it directly: append init + a
  several-MB `seg0`; open the raw client, **read a small fixed prefix (a few KB), then
  close/RST** the socket (the helper's prefix-then-close mode). Because MBs remain
  unread, the server's next write to the now-dead fd returns `EPIPE`/`ECONNRESET`
  (`SO_NOSIGPIPE` => errno, not a signal) -> `.failed` -> `closeConnection`. Allow a
  brief settle so that write-source firing is processed before asserting -- unlike B
  and D (whose guard validity must not lean on a sleep), this is a fix-behavior test,
  so a short settle here is sound: it only ensures the async `.failed` has actually run
  (otherwise the test could pass vacuously without exercising the path). Then
  assert the failure stayed connection-local and the server still serves:
  `try? checkForFailure()` does **not** throw, and a subsequent
  `appendMediaSegment(seg1)` + `finish()` yields `hasFinalizedPlaylist() == true`. A
  `.failed` wrongly routed to `fail()` would set `state.failure`, so `checkForFailure()`
  would throw and `hasFinalizedPlaylist()` would return `false` -- this test fails
  loudly on that miswiring or on an errno-classification slip. `defer` closes the raw
  client fd (idempotent if already closed) and calls `server.shutdown()`.

Commands:

- Build: `just app-build`
- Full suite: `just app-test`
- Scoped (faster iteration): append the selector to the `app-test` xcodebuild
  invocation, e.g. `-only-testing:DanCamTests/LoopbackMediaServerTests`
  (destination `platform=iOS Simulator,OS=26.5,name=iPhone 17`).

Manual sanity (optional): run a progressive clip playback in the app and confirm
first-frame latency and swap behavior are unchanged.

## Suggested commit

Single coherent change:
`fix(app): serve loopback HTTP non-blocking off the serial queue` -- body explaining
that blocking writes on the server's serial queue coupled HTTP read speed to segment
publication / `checkForFailure` / teardown, replaced with per-connection write
sources on the same queue; and that the per-connection fd is now closed only from
each source's cancellation handler (per libdispatch), fixing the related
close-before-cancel-handler race. References finding D-03 and ADR 08.

## Implementation notes

- The raw test client (`RawLoopbackClient`) adds two socket options beyond the plan's
  sketch. `SO_RCVTIMEO` (5 s) so a blocking client read can never hang the suite past
  the `.timeLimit` backstop if the server unexpectedly sends nothing. `SO_LINGER {1,0}`
  in the prefix-then-close path (`closeWithReset`, used by test E) to force an immediate
  RST, so the server's next write deterministically observes `EPIPE`/`ECONNRESET`
  (`.failed`) rather than relying on the OS's implicit "close with unread data -> RST".
- Full-suite validation (`just app-test`) surfaced two flaky tests; confirmed
  pre-existing and unrelated (see Follow Up), so the change ships against a scoped-green
  `LoopbackMediaServerTests` (11/11) plus a full run whose only reds are those two.

## Follow Up

- Two tests are pre-existing flakes, not caused by this change: on clean master
  (`fbaaea4`, this change absent) they failed 2 of 4 full-suite runs, on exactly these
  two, under parallel-scheduling load. Both should be hardened separately:
  - `app/DanCam/DanCamTests/Networking/Preview/PreviewClientTests.swift#realHyperChunkedFixtureDecodesMockFrameSequence`
    -- the frame stream uses `.bufferingNewest(1)` (`app/DanCam/DanCam/Networking/Preview/PreviewClient.swift#produceFrames`),
    so a scheduling-starved consumer drops a frame, but the test asserts all four frames
    arrive in order (observed sequence `[0, 2, 3]`). Harden by buffering the test's frame
    stream unbounded, or asserting a subsequence rather than strict `[0,1,2,3]`.
  - `app/DanCam/DanCamTests/Features/ClipViewer/ClipViewerViewControllerTests.swift#completedProgressivePullSwapsToDurableMP4PreservingPlaybackPosition`
    -- under load AVPlayer does not reach `isCurrentPlayerPlaying` before the test's
    wait-for-condition deadline. Harden the wait (longer/adaptive deadline) or serialize
    the AVPlayer-driven viewer tests.
