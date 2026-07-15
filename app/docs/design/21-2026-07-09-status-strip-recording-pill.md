# ADR: status-strip recording pill

- **Status:** Accepted
- **Date:** 2026-07-09
- **Owner:** app
- **Related:** [app architecture](../../../docs/design/app/architecture.md);
  `18-2026-07-08-heartbeat-fresh-present-tense.md`;
  `20-2026-07-09-live-recording-surfaces-and-drive-attribution.md`

## Context

ADR 20 retained the Home preview's top-right REC overlay as if it answered "is
the preview live," but the implementation did not read preview liveness. It read
`RecordingFeature.State`, the phone-side command state. `PreviewViewController`
already owns the preview-liveness pill for Connecting, Live, and Preview offline.

That made the overlay both misplaced and fragile. The app architecture made heartbeat
presence the connection truth, and ADR 18 requires stale recorder state to remain
visible as last-known instead of pretending it is live. When heartbeat timed out,
`AppFeature` reset `RecordingFeature.State` to `.unknown`, so the overlay blinked
out during Wi-Fi churn even if the last-known recorder snapshot said the Pi was
recording.

The app shell status strip was built for system-level state. ADR 05 described
"More status surfaces are coming: recording state, ..." and the app architecture kept
the shell strip as the persistent app chrome. Recording status is a system-level
dashcam fact, so it belongs in that strip rather than over Home's preview.

## Decision

Move recording status into the shell status strip as a second trailing pill and
delete the Home preview REC overlay.

The strip renders four freshness-typed states:

- Hidden when `RecorderTruth` is `.unknown`.
- Red REC when the heartbeat-fresh recorder snapshot has a current segment, when
  the phone has a pending start/record command against a fresh no-segment
  snapshot, or when the fresh snapshot phase claims recording before the first
  segment opens.
- Gray REC when the last-known recorder snapshot has a current segment or a
  `.starting`/`.recording` phase.
- Muted "Not recording" when recorder truth is known and idle, whether fresh or
  last-known. The adjacent connection pill carries freshness by saying
  "Connected" or "Not connected."

Do not show elapsed time or run a timer in the strip. Elapsed recording detail
stays in the Home widget and drive detail surfaces from ADR 20.

Lay out the shell strip with the connection pill pinned leading and the
recording pill pinned trailing. The connection pill remains the primary
height-driving status. The recording pill truncates first at large content sizes,
and when hidden it deactivates its trailing and spacing constraints so it
reserves no trailing width.

Feed the shell with one equality-gated projection containing the derived
connection pill, derived recording pill, and coarse link phase. This keeps the app
architecture's "observe view state, not source state" model and avoids waking the
shell on unrelated `World` deltas such as temperature, storage, memory, or uptime.
The same projection's link phase preserves the architecture's offline-to-online
live-work resume edge.

Reuse `LiveRecordingStatus.shouldShowPending(recording:recorder:)` for the fresh
pending-start rule, backed by a shared `RecorderPhase.claimsRecording` predicate.
`claimsRecording` intentionally excludes `.stopping`: once the segment is closed,
the strip should read "Not recording" even if the command state is still
stopping.

## Consequences

Easy:

- Recording status is visible in persistent app chrome instead of only on Home.
- A heartbeat timeout no longer makes REC disappear; it changes from red to gray
  while the connection pill changes to "Not connected."
- Home preview chrome now reflects preview liveness only. Recording status
  remains in the widget, drive card, drive detail, and shell strip.
- The shell no longer observes the whole `Link`, so telemetry-only world changes
  do not trigger strip renders.

Hard or risky:

- The strip now has two independently laid-out pills, so hidden state must
  release constraints rather than relying on `isHidden`.
- REC accessibility labels no longer match their visible caption, so tests and
  callers that need the visible text must read an explicit caption accessor.
- `.stopping` is a small behavior change from the deleted overlay: with no open
  segment, the strip says "Not recording" instead of keeping REC through the
  stop command.

Mitigations:

- Coordination tests cover connection pill mapping, resume-edge phases,
  recording-pill mapping for unknown, fresh, last-known, idle, pending, and
  `.stopping` states, plus projection equality across unrelated world deltas.
- Shell tests cover the hidden connecting state, red live REC, gray REC after
  heartbeat timeout, affirmative idle "Not recording," and hidden-pill width
  release.
- Existing Home tests continue covering the widget, drive-card marker, detail
  row, and record button after deleting only overlay-specific assertions.

## Alternatives considered

- **Keep the Home preview overlay.** Rejected. It was driven by command state,
  not preview liveness, and it flapped away on heartbeat timeout.
- **Add elapsed time to the status strip.** Rejected. The strip is global chrome;
  elapsed detail belongs in the recording widget and detail surfaces.
- **Use separate connection and recording observers.** Rejected. A single
  projection keeps the shell coherent and equality-gated. Split observations
  could render adjacent pills from different moments in one reducer update.
