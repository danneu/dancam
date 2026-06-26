# Plan: `lime` resumable ranged clip pull (Pi `206`/Range + app resume loop)

## Context

The `lime` spike (`plans/impl/2026-06-26-1654-lime-swoop-spike.md`) landed the **plain-serve**
`GET /v1/clips/{id}` (full body as `200 application/mp2t`, no Range) and a **finite**
`ClipPullClient` (one-shot `Content-Length` pull to a temp file). Both were deliberately
shaped to grow into resume: the roadmap's "App (riskiest)" step is "a `Range`/`If-Range`/
`Content-Range` loop that streams to a local file and resumes from the last byte across
drops (verify `ETag` before resuming)... a mid-pull drop must resume, never restart."

This plan adds that resume on both sides. It is the immediate next `lime` chunk and it
**closes `opal`** -- `opal`'s last open box ("App: resumable pulls across drops -- ...
Shared with `lime`'s ranged-pull step; land it in whichever swoop reaches it first") is the
same work.

**Gating / sequencing.** The roadmap gates the build on the spike's throughput number, but
the *code* is independent of it: a ~38 MB segment pulls in ~6-26 s over a congested 2.4 GHz
AP, so a drop landing mid-pull is near-certain and resume is the expected go. Only the
retry/backoff constants (B) are informed by the measured numbers; tune them when the spike
write-back lands. Assumes the spike's `serve_clip` plain-serve + `ClipPullClient` seam are
committed first.

**Out of scope (stay deferred, separate roadmap steps):** on-device clip store (id+etag
naming, cross-tap reuse, size cap), `dur_ms` reporting, clip-row poster/created-time. The
resume here is *within a single `pull()` call* (reconnect + append); cross-tap reuse is the
store step.

---

## A. Pi: `Range`/`If-Range` -> `206`/`Content-Range`, `416`, `Accept-Ranges`, `ETag`

File: `raspi/service/src/clips.rs` (+ tests in `raspi/service/tests/clips.rs`). No
`Cargo.toml` change -- `tokio` `io-util`+`fs` and `tokio-util` `io` are already present.

Rework `clips.rs#serve_clip`:

- Add a `headers: HeaderMap` extractor; read the `Range` and `If-Range` request headers.
- Keep the open-segment `404` guard and the file-open/`is_file` `404` guards as-is.
- **Entity-tag wire form (one helper, used everywhere).** RFC 9110 entity-tags are
  *quoted* on the wire and `If-Range` uses a strong octet-for-octet comparison, so a
  raw-vs-quoted mismatch would silently turn every resume into a `200` restart. Define one
  Pi helper `fn http_etag(seq, bytes) -> String` returning the **quoted** form
  `"\"{seq}-{bytes}\""` (i.e. `1-7` on disk -> `"1-7"` on the wire) and use it for *both*
  the `ETag` response header and the `If-Range` comparison. The JSON clips list keeps its
  **raw/unquoted** `{seq}-{bytes}` value (`clips.rs#read_finished_clips`, unchanged contract
  -- the app wraps it to the quoted form when it builds `If-Range`, see B).
- **Always emit** `Accept-Ranges: bytes` and `ETag: <http_etag>` (quoted). `bytes` =
  `metadata.len()`, `seq`/`id` = the path seq. Keep `Content-Type: application/mp2t`.
- **No `Range`, or `If-Range` present and its octets != `http_etag`:** `200` +
  `Content-Length = total` + full `ReaderStream::new(file)` (today's behavior; RFC 9110
  If-Range: a non-matching validator ignores the range and serves the whole representation).
- **`Range` present and (`If-Range` absent or octet-equal to `http_etag`):** resolve against `total`:
  - satisfiable -> `206` + `Content-Range: bytes {start}-{end}/{total}` + `Content-Length =
    {end-start+1}` + sliced body: `file.seek(SeekFrom::Start(start)).await?` then
    `ReaderStream::new(file.take(len))` (`AsyncSeekExt`/`AsyncReadExt` from `io-util`; no
    full-file buffering).
  - unsatisfiable -> `416`.
- Add `fn resolve_range(raw: Option<&str>, total: u64) -> RangeResolution` (enum
  `Full | Partial { start, end } | Unsatisfiable`) **mirroring the Swift
  `HTTPRangeRequest.swift#resolveRange`** semantics: single range only (reject a comma),
  `bytes=` prefix, forms `N-`, `N-M`, suffix `-N`; clamp `end` to `total-1`; `start >=
  total` -> unsatisfiable. Pure + unit-tested.
- Change the return type to `Result<Response, ClipError>` (build the three status variants
  with `Response::builder()`); add `ClipError::RangeNotSatisfiable { total }` whose
  `IntoResponse` returns `416` with `Content-Range: bytes */{total}`. Keep
  `ClipError::NotFound` -> `404`.

Tests (mirror `tests/clips.rs` `oneshot` + `StubBackend` + `TempRecDir`, with the
`Host: localhost:8080` header):

- `bytes=3-` -> `206`, `Content-Range: bytes 3-9/10`, `Content-Length: 7`, body == bytes[3..].
- `bytes=2-5` -> `206`, body == bytes[2..6]; suffix `bytes=-4` -> last 4 bytes.
- `If-Range: "{id}-{bytes}"` (quoted, matching) -> `206`; a non-matching `If-Range` (test
  both an *unquoted* `{id}-{bytes}` and a different etag) -> `200` full -- pins the
  quoted-vs-raw contract so a wire-form regression fails here.
- `bytes=100-` on a 10-byte file -> `416` + `Content-Range: bytes */10`.
- plain `200` (no Range) now carries `Accept-Ranges: bytes` + the **quoted**
  `ETag: "{id}-{bytes}"` (assert the exact header octets, quotes included).
- open segment while recording still `404` (unchanged guard).
- `resolve_range` unit tests for each form + the comma/garbage rejection.

curl after deploy: `Range: bytes=N-` -> `206`/`Content-Range`; oversized range -> `416`;
`If-Range` with a wrong etag -> `200`.

---

## B. App: resumable pull loop

Files: `app/DanCam/DanCam/Networking/Clips/ClipPullClient.swift`,
new `app/DanCam/DanCam/Networking/HTTP/HTTPContentRange.swift`,
the viewer call site, and the test files.

**Thread the etag.** Change `ClipPullClient.swift#pull` to
`@Sendable (_ clipID: Int, _ etag: String) -> AsyncThrowingStream<ClipPullEvent, Error>`.
`pull` is a stored function-typed property, so its parameter names are *not* call labels --
**call sites are unlabeled**: `pull(clip.id, clip.etag)` (the `Clip` in `ClipsResponse.swift`
already carries the raw `etag`) and `client.pull(42, "1-7")` in tests. Writing
`pull(clip.id, etag: clip.etag)` is an extraneous-argument-label compile error. Update
`.noop` (`{ _, _ in ... }`), the `ClipViewerViewController` call site, and the existing
`ClipPullClientTests`. `.live(baseURL:pinning:)` / `AppDependencies` wiring is unchanged.

**Entity-tag for `If-Range` (named helper, not bare interpolation).** `clip.etag` is the raw
list value (`1-7`); it must be wrapped in **literal double-quote characters** to become the
quoted entity-tag `"1-7"` that octet-matches the Pi's quoted `ETag` (A). Beware: in Swift
`"\(etag)"` interpolates to `1-7` -- it does **not** add quote characters -- so that bare
form would send an *unquoted* `If-Range` and force a `200` restart on every resume. The
literal that actually embeds the quotes is the escaped `"\"\(etag)\""`. Define a small pure
helper `func httpEntityTag(_ rawETag: String) -> String { "\"\(rawETag)\"" }` and call it
when building the `If-Range` header; it mirrors the Pi `http_etag`. (The first response's
`ETag` should equal the helper's result; log a mismatch -- a mismatch only forces a `200`
restart anyway.)

**Resume loop.** Refactor `ClipPullClient.swift#producePull` so its current connect ->
head-parse -> write-body block is one **attempt** inside a bounded retry loop. State that
**persists across attempts**: `outputURL`, the open `FileHandle`, `bytesWritten`,
`expectedBytes` (the whole-file total), a mutable **`resumeETag`** (the quoted validator the
*next* `If-Range` will carry -- see below), and the `clock`/`start` (so throughput covers
total wall time). Per attempt, a fresh `HTTPResponseHeadParser` + `HTTPBodyDecoder`.

- **The per-attempt request depends on progress, not on which attempt it is.** While
  `bytesWritten == 0` (attempt 1, *or* any reconnect before the first body byte lands), send
  a **plain `GET`** -- `HTTPRequestEncoder.get(url:, extraHeaders: [("Connection","close")])`,
  no Range -- and expect `200` (set `expectedBytes = Content-Length`). Once `bytesWritten >
  0`, send `Range: bytes=<bytesWritten>-` + `If-Range: <resumeETag>`.
- **`resumeETag` must always describe the bytes currently on disk.** Initialize it to
  `httpEntityTag(clip.etag)`. Whenever an accepted full-body `200` (re)writes the file from
  byte 0 -- attempt 1's `200`, or a `200`-restart below -- replace `resumeETag` with that
  response's own `ETag` header (already quoted on the wire; fall back to the prior value if
  the header is absent). That way the `If-Range` on the *next* resume validates against the
  representation those on-disk bytes actually came from, not a stale list value that a changed
  validator would reject -- preventing a restart loop where every reconnect re-`200`s.
- **Clean finish (whole-file, not per-response):** a per-attempt decoder reporting
  `isComplete` means only *that response's framed body* arrived -- for a `206` that is just
  the requested range, not the whole file. Emit `.completed` only when the decoder is complete
  **and** `bytesWritten == expectedBytes` (the whole-file total). On the attempt-1 `200` path
  the two coincide; the `206` path must cross-check so a truncated resume can never finish the
  pull. A decoder that completes with `bytesWritten < expectedBytes` is not global completion
  -- with the `206` end-guard above it cannot arise on a conformant exchange, so treat it as
  the same terminal `ClipPullError.malformedResponse` (defense in depth).
- **Retryable failure -- ride it out (this is the `opal` robustness goal):** the byte stream
  throws a non-`CancellationError`, **or** ends before `isComplete` (premature EOF), at *any*
  point -- connection open, head parse, or mid-body. Back off, reconnect, and retry per the
  progress rule above. Note a premature stream end is now **retryable**, *not* the terminal
  `malformedResponse("...ended before Content-Length")` it is today -- a dropped AP link
  surfaces exactly that way, so a pre-body or mid-head drop must reconnect, not fail. Resume-
  response handling once `bytesWritten > 0`:
  - **`206`:** parse `Content-Range` via the new helper; **guard** `start == bytesWritten`
    && `end + 1 == total` && `total == expectedBytes`. The resume request is always the
    open-ended `bytes=<bytesWritten>-`, so a conformant server returns the file's tail
    (`end == total - 1`); a **short `end`** (`end + 1 < total`) is a server bug that would
    otherwise frame a complete-*looking* but truncated body. Any violation is a *terminal*
    `ClipPullError.malformedResponse` (a stale/buggy/short partial must never be appended),
    taking the cleanup path below. On a valid guard, frame the partial body with
    `HTTPBodyDecoder(head:)` (it reads the `206`'s own `Content-Length`) and **append** (the
    handle is at EOF). Progress reports against `expectedBytes` (whole-file total), so the bar
    advances monotonically.
  - **`200`** (`If-Range` didn't match -- immutable segments make this near-impossible, but
    handle it): `fileHandle.truncate(atOffset: 0)` + `seek(toOffset: 0)`, reset `bytesWritten
    = 0`, `expectedBytes = Content-Length`, **set `resumeETag` from this `200`'s `ETag`** (the
    disk now holds *this* representation's bytes), rewrite. Progress legitimately restarts
    from 0; a subsequent drop resumes with the new validator, not the stale one.
  - **`416`** with `bytesWritten == expectedBytes`: the drop landed at EOF; treat as complete.
    Otherwise terminal `ClipPullError.malformedResponse`.
  - any other status -> terminal `ClipPullError.http(status)`.
- **Terminal (no retry):** `CancellationError`; a non-`2xx`/unexpected status; a genuine
  head/body **parse** error (`HTTPResponseHeadError`/`HTTPBodyDecodingError` -- a bad status
  line or chunk framing, distinct from a premature EOF); or a `Content-Range` guard violation.
  All take the existing cleanup path.
- **Bounds:** `maxAttempts` ~5-6 with exponential backoff (~0.25 -> 4 s, capped); exhausted
  -> `.transport`. Make the backoff `sleep` injectable on the `.live(...openByteStream:)`
  test seam (tests pass a no-op) so resume tests don't actually sleep. Tune the constants
  once the spike's pull-time write-back lands.
- **Cleanup unchanged:** `CancellationError` and terminal errors close the handle and delete
  the partial temp file unless `shouldKeepOutput`; the unique-per-pull `clip-<id>-<uuid>.ts`
  naming stays (`producePull` keeps one temp file for the whole pull, reused across its own
  reconnects).

**New pure helper** `Networking/HTTP/HTTPContentRange.swift`: `parse(_ value: String) ->
(start: UInt64, end: UInt64, total: UInt64)?` for `"bytes 0-3/12"` (reject `*` total /
malformed). Lives beside the other HTTP primitives; pure -> direct `@Test`s. (The loopback
`HTTPRangeRequest` is request-side/server-side; this is the response-side parser the client
lacks.)

Tests (Swift Testing, the `RequestCapture` + `AsyncStreamHelpers.byteStream` +
`MJPEGWireBuilder` idiom from `ClipPullClientTests`):

- **Resume happy path:** a stateful `openByteStream` returns, on call 1, a `200` head
  carrying `ETag: "<etag>"` (matching the list etag, as an immutable segment does) + the
  first K body bytes then `finish(throwing:)` (simulated drop); on call 2, a `206` with
  `Content-Range: bytes K-N/total` + the remaining bytes. Assert: the **second captured
  request** carries `Range: bytes=<K>-` and the quoted `If-Range: "<etag>"` (`resumeETag`
  unchanged because the `200`'s `ETag` matched); `.progress` events are monotonically
  increasing against the full `expected`; the final on-disk bytes and `result.bytes` equal
  the full body. Guards against regressing to restart-on-drop.
- **Pre-body drop (F3):** call 1 `finish(throwing:)` *before any body byte* (a returned
  stream that drops during / just after the head, `bytesWritten == 0`); call 2 returns a full
  `200`. Assert the pull still **completes**, and the **second request is a plain `GET` with
  no `Range`/`If-Range`** -- pins the "retry from head, not only mid-body" behavior.
- **Connection-open drop:** `openByteStream` itself **throws** on call 1 -- before returning
  any stream (the connect / `NWByteStream.open` failure shape, a *distinct* code path from
  the returned-stream `finish(throwing:)` above, caught by `producePull`'s outer `catch`
  rather than the `for try await`); call 2 returns a full `200`. Assert the pull still
  **completes** and the **second request is a plain `GET` with no `Range`/`If-Range`** --
  pins that the retry loop rides out a pre-stream throw, not only a mid-stream one. (The
  stateful `openByteStream` throws on its first invocation, then yields a stream on the
  second.)
- **Bad-partial guard (F4):** two `206`-violation cases, each asserting a terminal
  `ClipPullError.malformedResponse`, that the pull does **not** complete, and that the partial
  temp file is **removed**. (a) **Mismatched start:** call 2's `206` has `start !=
  bytesWritten` -- rejects a stale/wrong-offset partial. (b) **Short end:** call 2's `206` has
  matching `start`/`total` but a truncated range -- `Content-Range: bytes K-M/total` with
  `M + 1 < total`, paired with a `Content-Length = M - K + 1` so the body decoder *would*
  report `isComplete` -- proves the `end + 1 == total` guard (and the `bytesWritten ==
  expectedBytes` completion check) stop a truncated `206` from finishing the pull with an
  incomplete file.
- **`200`-restart path (validator changed, then a second drop):** call 1 `200` + K bytes
  then drop; call 2's `200` carries a **new** `ETag` (validator changed, `If-Range` ignored)
  + the first M bytes then drops again; call 3 must resume with `Range: bytes=<M>-` and
  `If-Range: <new quoted ETag>` (the call-2 validator, **not** the stale list etag), and a
  `206` completes the file. Assert: the file was truncated+rewritten at the restart (no
  duplicated K bytes), the call-3 `If-Range` equals call-2's `ETag`, final bytes correct.
  Pins that `resumeETag` follows the bytes on disk so a post-restart drop resumes instead of
  restart-looping.
- **Quoted-`If-Range` framing (F1):** two assertions. (1) A *pure* `@Test` on the helper:
  `httpEntityTag("1-7")` equals the exact 5-character string `"1-7"` (the two `"` are part of
  the value) -- a bare-`"\(etag)"`-interpolation regression fails here with no networking.
  (2) End-to-end: the resume request's `If-Range` header value is exactly `"<etag>"` (with
  quotes), not the raw `clip.etag`. Together they pin the wire-form contract app-side.
- **`HTTPContentRange.parse`** unit tests (valid, `*` total, malformed).
- Keep an updated single-pass test (attempt 1 sends `GET /v1/clips/<id>` + `Connection:
  close` and **no** Range/If-Range).

The `NWListener`/AVPlayer wiring is unchanged; real mid-pull drops are validated on-device
(below), not in unit tests.

---

## C. Mock parity (free)

`serve_clip` reads `rec_dir` regardless of backend, so the mock serves the `Range`/`206`/
`ETag` pulse with **zero mock-code changes** -- the same way it got plain-serve -- using the
spike's existing `raspi/service/assets/clips/seg_00000.ts` fixture. This realizes the
roadmap's "Mock parity" second pulse. Coverage:

- Server side: the Pi integration tests above + `curl -H 'Range: bytes=100-'
  http://127.0.0.1:8080/v1/clips/0` against `DANCAM_REC_DIR=assets/clips just raspi-mock`.
- Client resume: the injected-stream unit tests in B (loopback desk pulls don't drop, so the
  first-attempt `200` path is all the desk exercises end-to-end).
- The real drop -> `Range` resume -> `206` -> append chain is the **on-device AP gate**.

---

## D. Write-back

When green (incl. the on-device drop test), check the roadmap boxes:

- `lime`: **Pi (ranged/resumable)**, **App (riskiest): resumable ranged pull**, **Mock
  parity** (now both pulses landed).
- `opal`: **App: resumable pulls across drops** -- which leaves `opal` fully `[x]`; flip the
  swoop header checkbox too.

Append a note to ADR 02 (`raspi/docs/design/02-2026-06-22-app-pi-transport-and-api.md`) if
the spike shifted resume from optional to mandatory, per the roadmap `lime` write-back rule.

---

## Verification

- **Pi:** `just raspi-test` green (new `206`/`416`/`ETag`/`If-Range` integration tests +
  `resolve_range` unit tests + existing suite). Post-deploy curl: `Range: bytes=N-` ->
  `206` + correct `Content-Range`/`Content-Length`/sliced bytes; oversized -> `416`;
  `If-Range` wrong etag -> `200` full; plain GET carries `Accept-Ranges` + `ETag`.
- **App:** `just app-test` green (`HTTPContentRange` + `httpEntityTag` helper + resume
  happy-path + pre-body-drop + connection-open-drop + bad-partial-guard + `200`-restart +
  quoted-`If-Range` + updated single-pass tests + existing suite); `just app-build` clean.
- **Desk (no Pi):** simulator vs. `DANCAM_REC_DIR=assets/clips just raspi-mock` -- the clip
  lists, taps through, pulls (first-attempt `200`), plays; `curl -H 'Range: ...'` against the
  mock returns `206`.
- **On device (Dan):** join `dancam-dev`, start a pull, induce a drop mid-transfer (step out
  of range / toggle Wi-Fi briefly), and confirm the transfer **resumes from the last byte**
  (progress continues, not restarts) and the clip plays. This is the real resume gate.

---

## Critical files

New:
- `app/DanCam/DanCam/Networking/HTTP/HTTPContentRange.swift` (+ its test)

Edit:
- `raspi/service/src/clips.rs` (`serve_clip` Range/If-Range/ETag/Accept-Ranges + `206`/`416`,
  new `resolve_range`, `ClipError::RangeNotSatisfiable`, return type -> `Result<Response, _>`)
- `raspi/service/tests/clips.rs` (Range/If-Range/416/headers tests)
- `app/DanCam/DanCam/Networking/Clips/ClipPullClient.swift` (etag param + resume loop)
- `app/DanCam/DanCam/Features/ClipViewer/ClipViewerViewController.swift` (call site
  `pull(clip.id, clip.etag)` -- unlabeled)
- `app/DanCam/DanCamTests/Networking/Clips/ClipPullClientTests` (resume + restart + updated
  single-pass)
- `docs/roadmap.md` + ADR 02 (write-back, step D)

Reused unchanged: `HTTPRequestEncoder.swift` (`extraHeaders` carries `Range`/`If-Range`),
`HTTPResponseHead.swift` (`headerValue` reads `Content-Range`/`ETag`), `HTTPBodyDecoder.swift`
(content-length mode frames the `206` body), `NWByteStream.swift`, the loopback server.
File-system-synchronized Xcode groups mean the new `.swift` files need no `project.pbxproj`
edits.

## Suggested build order

1. Pi `serve_clip` Range/`206`/`416`/`ETag` + `resolve_range` + tests -- curl-verifiable
   immediately, unblocks the on-device drop test.
2. `HTTPContentRange` helper + unit tests.
3. `ClipPullClient` resume loop + etag param + viewer call site + resume/restart tests.
4. Desk mock-first check; hand to Dan for the on-device drop test; then the step-D write-back.

## Implementation notes

- `httpEntityTag` lives in the new `HTTPContentRange.swift` (beside the response-side
  parser, the natural home for the request/response HTTP wire helpers) as a
  `nonisolated` free function so the detached pull producer can call it under the
  module's `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`; called unqualified per the plan.
- Backoff constants landed as `maxAttempts = 6` with `0.25 s -> 4 s` exponential cap
  (`ClipPullClient.swift#backoffDuration`); the `sleep` is injected through a new
  `.live(baseURL:pinning:sleep:openByteStream:)` seam (default real `Task.sleep`, tests
  pass a no-op). Tune once the spike's pull-time write-back lands.
- Resume tests use distinct clip ids (101-106) so the shared-temp-dir
  `clip-<id>-*.ts` prefix cleanup in `prepareOutputURL` can't collide across Swift
  Testing's parallel execution.
- Part C (mock parity) needed zero mock code: `serve_clip` is backend-agnostic, so the
  mock served `Range`/`206`/`416`/`ETag` for free. Curl-verified against
  `DANCAM_REC_DIR=assets/clips` (200 + quoted `ETag`/`Accept-Ranges`; `bytes=0-9` ->
  `206`/`Content-Range`/10 bytes; oversized -> `416` `bytes */1012756`; wrong `If-Range`
  -> `200`).

## Follow Up

- Step D (write-back) is deferred -- it is gated on Dan's on-device drop test (the real
  resume gate), which an agent cannot perform. When that is green, check the roadmap
  boxes for `lime` (Pi ranged/resumable, App riskiest resumable pull, Mock parity) and
  `opal` (App resumable pulls across drops -- leaves `opal` fully `[x]`, so flip the
  swoop header too), and append the ADR 02
  (`raspi/docs/design/02-2026-06-22-app-pi-transport-and-api.md`) note if the spike
  shifted resume from optional to mandatory.
- Pre-existing clippy warnings remain in `raspi/service/src` outside this change's scope:
  `recording.rs` `is_json_content_type(...) == false` (bool_comparison) and
  `clips.rs#read_finished_clips` `sort_by` (suggests `sort_by_key`/`Reverse`). Untouched
  here; worth a separate lint-cleanup pass.
