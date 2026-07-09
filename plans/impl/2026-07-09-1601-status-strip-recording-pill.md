# Move the REC indicator into the global status strip

## Context

Today the only always-on recording indicator is a "REC" pill overlaid on the Home
preview's top-right corner. ADR 20 point 6 retained it as answering "is the preview
live" -- but that rationale never matched the implementation: the pill renders
`RecordingFeature.State` (the phone's command state), while `PreviewViewController`
already owns a top-left pill for actual preview liveness (Connecting / Live /
Preview offline). Worse, because command state resets on heartbeat timeout, the
overlay blinks out on Wi-Fi churn -- the exact flap ADR 18 rejects.

For a dashcam, the worst failure is silently not recording. Recording status is
system-level truth and belongs in the shell status strip (ADR 05 anticipated
exactly this: "More status surfaces are coming: recording state, ..."). This change
moves it there as a freshness-typed pill and deletes the overlay.

Decisions settled with Dan interactively:

- **Freshness-typed, 4 states** (not binary REC / Not recording): red REC for
  heartbeat-fresh recording or pending; gray REC for last-known recording; muted
  "Not recording" for known idle (fresh or last-known -- stays visible per ADR 18,
  the adjacent "Not connected" pill signals staleness); pill hidden when
  `RecorderTruth.unknown`.
- **Static, no elapsed, no timer** -- elapsed stays on the Home widget/detail row.
- **Layout: connection pill pinned leading, recording pill pinned trailing.**
- **Fresh REC style: material background + red dot** (red-tinted background stays
  reserved for negative states like "Not connected").
- **One combined equality-gated projection** feeds one shell render pass (ADR 17 /
  ADR 20 point 5 coherence argument), replacing the shell's `\.link` observation.
- **Rename to the status-strip family** -- "Connection" in the names becomes a lie.
- **Record as new ADR 21 + dated note on ADR 20 point 6** (append-only convention).

## Implementation

### 1. Share the pending predicate

- `app/DanCam/DanCam/Networking/Events/CameraEvent.swift`: add
  `RecorderPhase.claimsRecording` (`self == .starting || self == .recording`),
  defined directly beside the existing `RecorderPhase.isActive` (`.starting ||
  .recording || .stopping`). `claimsRecording` is narrower on purpose -- a segment
  closing during `.stopping` is not "recording" for the strip -- and placing it next
  to `isActive` makes the deliberate `.stopping` exclusion visible at the point of
  definition, so the two near-identical phase predicates are not confused or silently
  swapped for one another.
- `app/DanCam/DanCam/Features/Recording/LiveRecordingStatus.swift`: make
  `shouldShowPending(recording:recorder:)` internal (drop `private`) and replace its
  inline `worldStartGap` phase check with `snapshot.phase.claimsRecording`, so the
  start-gap rule has one home.

### 2. StripCoordination (new), ConnectionCoordination (deleted)

New `app/DanCam/DanCam/App/StripCoordination.swift` (shell chrome coordination
lives beside the shell, not under `Features/Connection/`); delete
`app/DanCam/DanCam/Features/Connection/ConnectionCoordination.swift`.

```swift
nonisolated enum StripCoordination {
    enum LinkPhase: Equatable { case connecting, online, offline }   // init(_ link: Link)
    enum Tone: Equatable { case neutral, positive, negative }
    struct ConnectionPill: Equatable { let caption: String; let tone: Tone }
    enum RecordingPill: Equatable { case live, lastKnown, idle }

    struct Projection: Equatable {
        let connection: ConnectionPill
        let recording: RecordingPill?   // nil = hidden (RecorderTruth.unknown)
        let linkPhase: LinkPhase
    }

    static func project(_ state: AppFeature.State) -> Projection
    static func connectionPill(for link: Link) -> ConnectionPill  // body of today's presentation(for:)
    static func recordingPill(recording: RecordingFeature.State, recorder: RecorderTruth) -> RecordingPill?
    static func shouldResumeLiveWork(from: LinkPhase, to: LinkPhase) -> Bool  // offline -> online only
}
```

`recordingPill` mapping (pure, clock-free -- no elapsed, no previous segment):

- `.unknown` -> `nil`
- `.live(snapshot)` -> `.live` if `snapshot.currentSegment != nil` or
  `LiveRecordingStatus.shouldShowPending(recording:recorder:)`; else `.idle`
- `.lastKnown(snapshot)` -> `.lastKnown` if `snapshot.currentSegment != nil ||
  snapshot.phase.claimsRecording` (covers the link-dropped-during-pending edge);
  else `.idle`. Deliberately snapshot-only: tapping Record while offline
  (`.starting` command against `.lastKnown` truth) must not paint gray REC.

The projection selects only derived presentation data + `LinkPhase`, so the
equality gate stops the every-world-delta observer fires the current
`observe(\.link)` suffers (Link embeds World). Resume-edge semantics over phases
are byte-identical to today's Link-case semantics.

### 3. StatusStripView (renamed from ConnectionStatusStripView)

`git mv app/DanCam/DanCam/Views/ConnectionStatusStripView.swift .../StatusStripView.swift`
(project uses fileSystemSynchronizedGroups -- no pbxproj edits for any rename/delete).

- Two `StatusPillView`s: `connectionPill` leading (safe-area + 16, its own
  independent `trailing <= safe-area - 16` -- as today's single-pill strip already
  has -- keeps the existing top/bottom 6 and low-priority >= 28 min-height -- it
  drives strip height), `recordingPill` trailing (safe-area - 16, centerY on
  connectionPill, `leading >= connectionPill.trailing + 8` so they never overlap at
  large type).
- Truncation priority: at large accessibility sizes both captions can be wide
  ("Not connected" + "Not recording"), and the `>= ... + 8` inequality forces one
  pill to truncate. Truncation resistance lives on `StatusPillView`'s internal
  `captionLabel` (default horizontal compression resistance 750), not on the pill
  view (which has no intrinsic size), so add a small hook on `StatusPillView` to
  lower its caption's horizontal compression resistance and apply it to the trailing
  `recordingPill` only. `connectionPill` stays at 750, so the recording caption
  truncates first and the primary connection caption -- already the height-driving
  pill -- stays intact instead of AutoLayout choosing nondeterministically.
- Zero-footprint hide: `isHidden = true` on a plain `UIView` does not remove its
  constraints (only `UIStackView` collapses hidden arranged subviews), so a hidden
  `recordingPill` that still carries its last caption keeps its trailing pin and
  `leading >= connectionPill.trailing + 8` active and goes on reserving trailing
  width -- truncating the connection pill after a visible -> hidden transition. Hold
  the recording pill's own two constraints (its `trailing` pin and the spacing
  inequality) as stored properties and deactivate them whenever `recording == nil`
  (reactivate when visible); with them inactive, the connection pill's independent
  `trailing <= safe-area - 16` lets it reclaim the full width.
- `func configure(connection: StripCoordination.ConnectionPill, recording: StripCoordination.RecordingPill?)`
  - connection: today's tone -> dot/background mapping, unchanged
  - `.live` -> "REC", `.systemRed` dot, `.material`, a11y "Recording"
  - `.lastKnown` -> "REC", `.systemGray` dot, `.material`, a11y "Last known
    recording" (matches the widget's frozen phrasing and gray badge)
  - `.idle` -> "Not recording", `.secondaryLabel` dot, `.material`
  - `nil` -> hidden and its trailing/spacing constraints deactivated (zero-footprint,
    see above)
- Pitfall: `StatusPillView.configure` resets `accessibilityLabel` to the caption on
  every call (`app/DanCam/DanCam/Views/StatusPillView.swift#func configure`), so
  the REC a11y override must be re-applied per render, not set once.
- `app/DanCam/DanCam/Views/StatusPillView.swift`: add `captionForTesting`
  (a11y label no longer equals caption for REC states, so tests need the caption).
- Testing accessors on the strip: `connectionPillForTesting`,
  `recordingPillForTesting`, `isRecordingPillVisibleForTesting`.
- Strip stays noninteractive; no timers.

### 4. AppShellViewController: one observation, one render

`app/DanCam/DanCam/App/AppShellViewController.swift`:

- `strip` becomes `StatusStripView`; `previousLink: Link?` becomes
  `previousLinkPhase: StripCoordination.LinkPhase?`.
- Replace `store.observe(\.link)` with
  `store.observe(select: StripCoordination.project)`; `render(_:)` configures the
  strip and runs the phase-based resume edge.
- Add `stripForTesting`.
- Coherence is free: `AppFeature.reduce` folds a snapshot into `link` and
  `recording` (via `recorderPhaseObserved`) within one `send` before observers
  fire, so the projection never sees a torn pair.
- `SceneDelegate` needs no changes (verified).

### 5. Home deletions

`app/DanCam/DanCam/Features/Home/HomeViewController.swift`:

- Delete the `recPill` property, its constraints/configure/addSubview wiring, and
  `isRecPillVisibleForTesting`.
- Delete `renderRecording(_:)`; its only remaining job is
  `recordButton.apply(...)` -- call that directly from `renderLiveRecording`.
- Untouched: `liveRecordingWidget`, drive-card REC marker, detail live row, record
  button, `PreviewViewController`'s own liveness pill.
- Remove the empty leftover `app/DanCam/DanCam/Features/Status/` directory if
  present.

### 6. Tests

Move/rename `DanCamTests/Features/Connection/ConnectionCoordinationTests.swift` ->
`DanCamTests/App/StripCoordinationTests.swift`, mirroring its table style:

- `connectionPillMapsCaptionAndTone` -- port of the existing Link table.
- `resumesLiveWorkOnlyFromOfflineToOnline` -- table over `LinkPhase` pairs
  (only `(offline, online)` is true; `(connecting, online)` is false, etc.).
- `recordingPillMapsAllRecorderTruthStates` -- pure mapping table incl.:
  unknown -> nil; live+segment -> live; command-driven pending (`.starting` /
  `.recording` + live no-segment idle-phase) -> live; world start gap -> live;
  live idle -> idle; live no-segment + phase `.stopping` -> idle; lastKnown+segment
  -> lastKnown; lastKnown no-segment phase-recording/starting -> lastKnown (the
  pending-window edge); lastKnown no-segment + phase `.stopping` -> idle; lastKnown
  idle -> idle; `.starting` + lastKnown idle -> idle (offline optimistic start
  must not claim last-known recording). The two `.stopping` + no-segment rows pin
  that `claimsRecording` excludes `.stopping` -- swapping in `RecorderPhase.isActive`
  (which includes `.stopping`) would fail them, guarding against silently
  reintroducing REC-during-stopping.
- `projectionIgnoresUnrelatedWorldDeltas` -- two online states whose worlds differ
  only in temp/storage/uptime produce equal `Projection`s (pins the
  fires-only-on-meaningful-change property).

Extend `DanCamTests/App/AppShellViewControllerTests.swift` (existing `makeStore`
and `CameraSamples.world(phase:currentSegment:)` suffice; copy the private
`colorMatches` helper -- and its dependency `colorComponents`, which it calls -- from
`HomeViewControllerTests`; the pair always travels together, four test files already
carry both):

- `stripHidesRecordingPillWhileConnecting`
- `stripShowsRedRecordingPillForLiveRecordingSnapshot`
- `stripKeepsGrayRecordingPillAfterHeartbeatTimeout` -- pins the anti-flap fix:
  after `.heartbeatTimedOut`, connection is "Not connected" but REC stays, gray.
- `stripShowsNotRecordingForAffirmativeIdleSnapshot`
- `stripRecordingPillReleasesWidthWhenHidden` -- a direct `StatusStripView` layout
  test (not store-driven): pin a narrow width, `configure` a wide visible recording
  pill ("Not recording") and force layout, then reconfigure with `recording == nil`
  and lay out again; assert the connection pill's laid-out width now equals its width
  from a strip configured with `recording == nil` from the start (same narrow width).
  Equal widths prove the hidden pill reserves zero trailing footprint, pinning the
  visible -> hidden transition the zero-footprint hide guards.
- End store-driving tests with `.streamStopped` (parks the reconnect effect), as
  the existing shell tests do. `resumesTopVCOnReconnectEdge` and
  `firstContactConnectDoesNotResume` stay byte-identical and must keep passing.

`DanCamTests/Features/Home/HomeViewControllerTests.swift`: delete the three
`isRecPillVisibleForTesting` assertions in the freeze/thaw test -- deleted, not
ported; the pill is shell-owned and shell-tested now.

### 7. ADR record

- New `app/docs/design/21-2026-07-09-status-strip-recording-pill.md` (Accepted,
  owner app; related: 06, 10, 17, 18, 20). 06 is the current shell/strip owner (ADR
  05 is Superseded by 06, so cite 05 only for the historical "more status surfaces
  are coming" quote, not as strip authority); 10 establishes heartbeat as connection
  truth, which combined with 18 is the root cause of the flap this fixes. Context:
  overlay rationale never matched implementation; overlay flapped on heartbeat
  timeout (command state resets when `heartbeatTimedOut` drops `Link` offline --
  ADR 10); strip was built for this, quoting ADR 05's "More status surfaces are
  coming: recording state, ...".
  Decision: the 4-state mapping, strip layout, no elapsed/timer, one combined
  projection, `shouldShowPending` reuse. Call out the small behavior delta:
  during `.stopping` with the segment already closed the strip reads "Not
  recording" (the overlay showed REC through `.stopping`) -- the freshness-honest
  reading. Alternatives: keep overlay; elapsed in header; separate observers.
- Amend `app/docs/design/20-2026-07-09-live-recording-surfaces-and-drive-attribution.md`:
  dated blockquote note after the metadata list marking Decision point 6
  superseded by ADR 21 (widget, card marker, detail row stand unchanged). Status
  stays Accepted. Older ADRs referencing the old type names stay untouched
  (append-only history).
- Plain ASCII; `path#identifier` anchors, no line numbers.

## Verification

1. `just app-test` -- full Swift Testing suite (new mapping + shell render tests,
   adapted Home tests, untouched resume tests).
2. `just app-lint` -- clean build, zero warnings (watch for unused bindings in the
   `recordingPill` switch).
3. Manual pass in the simulator against the mock Pi: launch (strip shows
   Connecting, no recording pill) -> connect idle ("Not recording" muted) ->
   start recording (red REC trailing; overlay gone from preview; widget/card/detail
   surfaces unchanged) -> kill the mock Pi mid-recording (connection goes "Not
   connected", REC turns gray and stays) -> restart mock Pi (REC returns red).
