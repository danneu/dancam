# Plan: make the loopback-bind security test load-bearing

## Context

`LoopbackMediaServer` serves pulled clip media (init/segment/playlist) to AVPlayer
over cleartext HTTP. ADR 08
(`app/docs/design/08-2026-06-27-progressive-fmp4-clip-playback.md`) makes loopback-only
binding a hard security requirement: "Bind **only** to loopback (127.0.0.1 /
`localhost`); never `0.0.0.0`." If the socket bound to `0.0.0.0` / `INADDR_ANY`
instead, pulled clip media would be reachable by anyone on the same Wi-Fi over
cleartext.

The bind is correct today, but the test that exists to guarantee it provides false
assurance. `LoopbackMediaServer.swift#LoopbackMediaServer` declares a decorative
`let bindAddress = "127.0.0.1"`, and the test
`LoopbackMediaServerTests.swift#bindsToLoopbackAndDeletesWorkDirectoryOnShutdown`
asserts that constant. But the real bind path (`makeLoopbackListener`, a `static`
method) hardcodes its own independent literal in
`Darwin.inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)`. The constant is never
read by the bind path. A regression that changed the `inet_pton` argument to
`"0.0.0.0"` would expose clips on the LAN and still pass the entire test suite. (The
`#expect(mediaPlaylistURL.host == "localhost")` line is likewise a hardcoded URL
literal, not the bind.)

Outcome: the security assertion should read the address the kernel actually bound the
socket to, so a regression to a non-loopback bind fails the test.

## Approach: assert the kernel-readback bound address

Read the bound address back from the socket via `getsockname` + `inet_ntop`, expose it
as a real property, delete the decorative constant, and point the test at the readback.
This reads actual kernel state, so it is robust against the `inet_pton` literal
regressing -- a `0.0.0.0` bind makes `getsockname` report `0.0.0.0` and the test fails.

This mirrors an in-repo pattern of reading the kernel-assigned address back from the
socket -- the raspi service reads `listener.local_addr()` after binding
(`raspi/service/src/main.rs#fn main`), there only to log it. (raspi is deliberately
LAN-facing, not loopback-only, so it is the readback technique that transfers here, not
a bind-security assertion.)

### Changes

**1. `app/DanCam/DanCam/Media/Stream/LoopbackMediaServer.swift`**

- Extend the existing `getsockname` reader. `boundPort(for:)` already reads back the
  bound `sockaddr_in` and pulls `sin_port`; the same struct carries `sin_addr`. Rename
  it to `boundEndpoint(for:)` returning both address and port from the single syscall:

  ```swift
  private struct BoundEndpoint {
      var address: String
      var port: UInt16
  }

  private static func boundEndpoint(for fileDescriptor: Int32) throws -> BoundEndpoint {
      var address = sockaddr_in()
      var length = socklen_t(MemoryLayout<sockaddr_in>.size)
      let result = withUnsafeMutablePointer(to: &address) { pointer in
          pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
              Darwin.getsockname(fileDescriptor, socketAddress, &length)
          }
      }
      guard result == 0 else {
          throw LoopbackMediaServerError.listenerFailed(posixErrorDescription())
      }

      var sinAddr = address.sin_addr
      var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
      guard Darwin.inet_ntop(AF_INET, &sinAddr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
          throw LoopbackMediaServerError.listenerFailed(posixErrorDescription())
      }

      return BoundEndpoint(address: String(cString: buffer), port: UInt16(bigEndian: address.sin_port))
  }
  ```

  `Darwin` is already imported, so `inet_ntop` / `INET_ADDRSTRLEN` need no new import.
  `posixErrorDescription(_:)` and the `.listenerFailed(String)` error case already
  exist and are the established channel for socket-syscall failures.

- Replace the decorative constant `let bindAddress = "127.0.0.1"` with a stored
  property populated from the readback: `let boundAddress: String`. The honest name
  signals it is what the kernel reports, not a configured input.

- In `init`, call `boundEndpoint(for:)` instead of `boundPort(for:)`; use
  `endpoint.port` to build `mediaPlaylistURL` (keep host `localhost` -- see note) and
  assign `boundAddress = endpoint.address`. Wrap the readback + URL construction in a
  single `do`/`catch` that closes the listener FD and removes the work directory before
  rethrowing:

  ```swift
  let listener = try Self.makeLoopbackListener()
  let endpoint: BoundEndpoint
  let playlistURL: URL
  do {
      endpoint = try Self.boundEndpoint(for: listener)
      guard let url = URL(string: "http://localhost:\(endpoint.port)\(Self.playlistPath)") else {
          throw URLError(.badURL)
      }
      playlistURL = url
  } catch {
      Darwin.close(listener)
      try? fileManager.removeItem(at: directory)
      throw error
  }
  // then: listenerFileDescriptor = listener; boundAddress = endpoint.address; mediaPlaylistURL = playlistURL
  ```

  Today only the URL-failure `guard` runs that cleanup, so a throw from the socket
  readback (the existing `getsockname`, or the new `inet_ntop`) would leak the listener
  FD. Unifying the cleanup path fixes that pre-existing gap while we are on it. These
  syscall-failure branches are unreachable for a freshly-bound valid FD and need fault
  injection to exercise (like the existing untested `getsockname` branch), so no test is
  added for them.

- Leave the `inet_pton(AF_INET, "127.0.0.1", ...)` literal as-is. Add a one-line
  comment that the test verifies this via the `getsockname` readback (see "Do not
  collapse the literal" below).

**2. `app/DanCam/DanCamTests/Media/Stream/LoopbackMediaServerTests.swift`**

- In `bindsToLoopbackAndDeletesWorkDirectoryOnShutdown`, change
  `#expect(server.bindAddress == "127.0.0.1")` to
  `#expect(server.boundAddress == "127.0.0.1")`. This now asserts kernel state.
- Keep `#expect(server.mediaPlaylistURL.host == "localhost")` as URL-shape
  documentation (it is not the security assertion; the readback is).
- The test name stays accurate; no rename. No new tag/helper plumbing -- it remains a
  `.tags(.networking)` Swift Testing case.

### Why this shape (and not the alternatives the finding listed)

- **Do not collapse the two `"127.0.0.1"` literals into one shared constant.** The
  cross-lane note suggested deduping the bind literal and the asserted constant. That
  is the wrong move here: the test's expected `"127.0.0.1"` is the *spec* ("must be
  loopback") and `inet_pton`'s is the *implementation*. If they shared one constant, a
  regression that changed the constant would change both and the test could not catch
  it. The `getsockname` readback dissolves the original duplication concern correctly:
  there is no longer a decorative input constant -- there is the implementation literal
  and an independent kernel-readback check.
- **Reject a "connect from a LAN/0.0.0.0 address and assert refused" behavioral test.**
  It is environment-fragile: it needs a non-loopback interface, can trip the macOS
  firewall prompt, and may have no usable LAN IP in CI/sandbox. Connecting to
  `0.0.0.0` is not a valid negative either -- it resolves to loopback, so it succeeds
  even for a correctly loopback-bound socket. The readback gives the same assurance
  deterministically. The positive path (loopback is reachable) is already covered: every
  existing test issues real `URLSession` requests against `mediaPlaylistURL`, which
  resolves to loopback -- but those same requests would *also* succeed against a `0.0.0.0`
  bind (loopback traffic reaches an any-interface socket too), so the readback is the
  only assertion that distinguishes loopback-only from any-interface.
- **Reject "make the constant the bind input" (feed `bindAddress` into `inet_pton`).**
  That asserts an input string, not what the socket actually bound to, and reintroduces
  the shared-constant problem above.

### Note on the URL host

`mediaPlaylistURL` keeps host `localhost` while `boundAddress` is `127.0.0.1`; the two
are intentionally different strings (the URL is what AVPlayer dials; `boundAddress` is
what the kernel bound). Nothing depends on the host spelling: `Info.plist` sets
`NSAppTransportSecurity.NSAllowsLocalNetworking = true` (covers cleartext to both
`localhost` and `127.0.0.1`, no per-domain exceptions), and `AppConfiguration.swift#defaultPinning(for:)`
already treats `localhost` / `127.0.0.1` / `::1` identically.

## Out of scope

This plan addresses only F-02 (the loopback-bind assurance gap). The sibling test-coverage
findings in `video-review.xegWVJ/06-test-coverage.md` (F-01 416-at-EOF, F-03 suffix/open-ended
range branches, F-05 backoff schedule, etc.) are separate and not touched here. The raspi
API bind (`raspi/service/src/main.rs`) is intentionally LAN-facing behind a host allowlist
(`raspi/service/src/lib.rs#HostPolicy`) -- a different security model, not a sibling to change.

## Verification

1. **Build:** `just app-build`.
2. **Run the suite:** `just app-test` (or focused:
   `xcodebuild -project app/DanCam/DanCam.xcodeproj -scheme DanCam -destination 'platform=iOS Simulator,OS=26.5,name=iPhone 17' -only-testing:DanCamTests/LoopbackMediaServerTests test`).
   All `LoopbackMediaServerTests` cases pass; `boundAddress` reads `127.0.0.1`.
3. **Prove the assertion is now load-bearing (the whole point):** temporarily change the
   `inet_pton` literal in `makeLoopbackListener` from `"127.0.0.1"` to `"0.0.0.0"`,
   re-run `LoopbackMediaServerTests`, and confirm
   `bindsToLoopbackAndDeletesWorkDirectoryOnShutdown` now FAILS (it passed before this
   change against the same regression). Revert the literal.
