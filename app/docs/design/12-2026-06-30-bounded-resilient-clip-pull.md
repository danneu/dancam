# ADR: bounded resilient clip pull

- **Status:** Accepted
- **Date:** 2026-06-30
- **Owner:** app
- **Related:** `app/docs/design/02-2026-06-22-app-pi-transport-and-api.md`;
  `app/docs/design/11-2026-06-30-receive-idle-deadline.md`;
  root `AGENTS.md` (cross-cutting app<->Pi local API principle)

## Context

ADR 02 records that clip resume is the normal case on the Pi's 2.4 GHz link. The
first clip-pull implementation did resume within a single pull, but its retry
budget counted total reconnects. A flaky but progressing pull could drop more
than a handful of times, hit the fixed attempt ceiling, delete the temporary TS
file, and force the user to start again from byte 0.

ADR 11 moved the silent-stall bound into the shared `NWByteStream` transport.
That transport now turns post-connect receive idleness into
`NWByteStreamError.receiveIdleTimedOut`, cancels the underlying connection, and
finishes the byte stream. Clip pull sees that error in the same place it sees any
mid-stream transport drop: inside the attempt's byte-stream loop.

The remaining app-side policy is therefore narrower than an idle-timeout fix:
make clip pull keep retrying while attempts make byte progress, fail in bounded
time when reconnects stop making progress, and reject server responses that
would otherwise make a progress-based budget spin.

## Decision

Change `ClipPullClient` to budget reconnects by progress:

- Track consecutive no-progress reconnects and reset that count whenever an
  attempt writes at least one decoded body byte.
- Keep a separate generous total-reconnect ceiling as a runaway guard for a
  pathological link or server that makes tiny progress forever.
- Report exhaustion as typed structure:
  `ClipPullError.exhausted(.consecutiveStalls)` or
  `ClipPullError.exhausted(.totalReconnects)`.
- Back off from the consecutive-stall count, not the lifetime reconnect count,
  so a progressing link never accumulates long delay. A zero-stall retry uses
  the base backoff instead of shifting by a negative exponent.

The progress signal comes from the attempt itself: `runAttempt` records whether
`writeDecodedChunks` wrote any decoded body byte during that attempt, then
returns `.retry(madeProgress:)` for rideable failures. Connect/open failures,
empty drops, and receive-idle timeouts before body bytes are no-progress
reconnects. Mid-stream drops and receive-idle timeouts after body bytes reset
the stall count.

A local temp-file failure (write/truncate/seek, or the finalizing close that can
report a deferred write error -- disk full, I/O error, revoked sandbox) is
terminal `ClipPullError.file`, never a retry, because reconnecting cannot fix
local storage. Such a failure ends the pull and deletes the partial temp file
rather than re-entering the resume loop.

Harden ranged `200` handling. A `200` response to a ranged `If-Range` resume is
accepted only when it carries an `ETag` different from the validator the app just
sent. That is the validator-change restart case: truncate the temp file, rewrite
from byte 0, emit `.restarted`, and resume later against the new validator. A
ranged `200` with the same validator or no validator is malformed and terminal,
because it would otherwise drive a truncate-rewrite loop that appears to make
progress forever.

Make `ClipPullError` conform to `LocalizedError`. The viewer already renders
`error.localizedDescription`; the error type now owns user-facing copy for HTTP,
malformed response, file, transport, and both typed exhaustion reasons.

## Consequences

Easy:

- A clip pull that keeps advancing bytes is no longer killed by a small fixed
  total-attempt count.
- A dead link still terminates in bounded time because each attempt is already
  bounded by ADR 09's connect deadline and ADR 11's receive-idle deadline, and
  consecutive no-progress reconnects exhaust the clip-pull budget.
- `NWByteStreamError.receiveIdleTimedOut` remains a rideable transport failure
  for clip pull. A stall before body bytes counts as no progress; a stall after
  body bytes resets the stall count.
- The repeated ranged-`200` same-validator loop fails immediately as malformed
  instead of relying on the total-reconnect ceiling.
- Viewer failures show the domain-specific clip-pull message instead of a
  generic bridged NSError string.

Hard or risky:

- A server that invents a genuinely new validator on every reconnect can still
  force repeated restarts. The total-reconnect ceiling bounds that case, but the
  app cannot prove server intent from the wire.
- Cross-pull and cross-launch resume are still out of scope. On terminal
  failure the current temp file is deleted; preserving validators and partial TS
  bytes across viewer instances needs separate persistent-state design.

## Alternatives considered

- **Keep the fixed total-attempt budget.** Rejected. It contradicts ADR 02's
  assumption that resume is normal on this link and discards near-complete files
  even when every reconnect made progress.
- **Infer progress by comparing `bytesWritten` before and after an attempt.**
  Rejected. A legitimate validator-changing `200` truncates and rewrites from
  byte 0, so an attempt can write body bytes while ending below its starting byte
  offset.
- **Add a clip-pull-local idle timer or wrapper.** Rejected. ADR 11 already
  implements the receive-idle deadline once inside `NWByteStream`, where the real
  connection can be cancelled and every transport plane benefits.
- **Keep partial temp files after exhaustion.** Rejected for this change. Without
  cross-pull persistence of validators and partial-file state, keeping the temp
  file does not give the next viewer instance a safe resume point.
