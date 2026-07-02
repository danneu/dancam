# Fix clip-viewer progress-bar width animation (honest wait UI)

## Context

Opening a clip from Home animates a `pushViewController` into
`ClipViewerViewController`. In `viewDidLoad` the controller immediately enters
`state = .preparing`, whose `render(.preparing)` calls
`progressView.setProgress(1, animated: true)` -- **before the first layout pass and
during the push transition**. At that moment the `UIProgressView` still has its
default pre-layout width, so the fully-blue fill animates against stale bounds: the
bar appears to start at ~half the container width and expand to full width. It happens
on every open, and is most obvious on a cache hit because `viewDidLoad` unconditionally
flashes `.preparing` (animated to 100%) before the async `clipCache.lookup` resolves and
jumps straight to `.playing`.

The root cause is two smells layered together:
1. **A determinate progress animation is started before the view is laid out.**
2. **A determinate bar is used for genuinely indeterminate phases** (the initial
   cache-lookup window, the post-pull remux/insert "Preparing" phase, and a cache hit
   where nothing is pulled at all). Filling a determinate bar to 100% for work that has
   no measurable fraction is dishonest -- ADR 13 explicitly requires the wait UI to
   "stay honest: determinate pull progress, then a short 'Preparing' phase."

**Intended outcome:** the determinate `UIProgressView` is shown *only* during a real,
known-size pull (honest determinate progress). Every indeterminate phase shows an
indeterminate spinner. Determinate animation can never run against pre-layout bounds.
A cache hit never shows the determinate bar at all.

## Design

Reserve the determinate bar for known-size pull; use an indeterminate
`UIActivityIndicatorView` for every indeterminate phase; gate determinate animation on
first layout. No new `ViewerState` case -- the state list stays exactly as ADR 13
documents (`pulling` / `preparing` / `playing` / `failed`).

### Indicator model

Both indicators live inside a single container view that is the one arranged subview
occupying the old `progressView` slot in the stack. Toggling the *inner* views never
collapses the *outer* stack slot, so nothing below reflows.

- `progressContainer: UIView` -- always visible, stable height (>= the spinner's
  height). Holds:
  - `progressView` pinned leading/trailing, centered vertically (stretches with width).
  - `preparingIndicator: UIActivityIndicatorView(style: .medium)`, `hidesWhenStopped =
    true`, pinned centerX/centerY (does not stretch).

### Three render helpers (each sets BOTH indicators, so no branch can leave a stale one)

- `showIndeterminate()` -- `preparingIndicator.startAnimating()`, `progressView.isHidden
  = true`.
- `showDeterminate(_ fraction: Float)` -- `preparingIndicator.stopAnimating()`,
  `progressView.isHidden = false`, `progressView.setProgress(fraction, animated:
  hasCompletedFirstLayout)`.
- `hideProgressIndicators()` -- `preparingIndicator.stopAnimating()`,
  `progressView.isHidden = true`.

### Layout-safe animation gate

```
private var hasCompletedFirstLayout = false
override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    hasCompletedFirstLayout = true
}
```

`showDeterminate` animates only when `hasCompletedFirstLayout` is true. This is the
literal condition the bug violated (first fill ran before first layout), so it is
causally correct and needs no per-pull bookkeeping; retry / cache-hit self-heal /
purged-cache share-tap self-heal all occur well after first layout and animate normally
for free. (Headless tests never force layout, so determinate updates are non-animated
and deterministic there.)

### Initial state: imperative spinner, no `state` assignment (Option C)

Remove `state = .preparing` from `viewDidLoad`. Start the indeterminate UI imperatively
in `configureViews` (call `showIndeterminate()`, set `statusLabel.text = "Preparing"`).
The first `state` assignment is then the first *real* transition:
- Cache hit logs `viewer none -> playing` (honest: nothing was prepared, just looked up).
- Miss logs `none -> pulling -> preparing -> playing` -- exactly one "preparing," and it
  genuinely is the remux window.

This avoids the misleading double-"preparing" log that reusing `.preparing` for the
pre-lookup window would produce, and adds no enum case.

### State -> render matrix

| State | Indicators | statusLabel | other |
|---|---|---|---|
| (initial, no state) | `showIndeterminate()` | "Preparing" | share disabled |
| `.pulling` known `expected > 0` | `showDeterminate(fraction)` | "N of M" | share disabled |
| `.pulling` unknown/zero `expected` | `showIndeterminate()` | "N pulled" | share disabled |
| `.preparing` | `showIndeterminate()` | "Preparing" | share disabled |
| `.playing` | `hideProgressIndicators()` | "Ready" | share enabled |
| `.failed` | `hideProgressIndicators()` | "Clip failed" | retry shown, share disabled |

Note `.playing` no longer shows a full bar (the embedded player replaces it) -- a
deliberate behavior change; existing tests assert only `statusText == "Ready"`, so it is
free. In `startPull()`, add `progressView.setProgress(0, animated: false)` as a
reset-on-reuse snap so a re-appearing bar (retry / self-heal / a `.restarted` reset)
starts from 0 rather than animating backward from a stale fraction.

Accept-and-note edge case: a `.restarted` pull event resets `bytesWritten` to 0, so the
next determinate render animates the fill downward. Honest (bytes were discarded), minor,
not worth special-casing.

## Files to change

- **`app/DanCam/DanCam/Features/ClipViewer/ClipViewerViewController.swift`** -- the fix.
  Add `preparingIndicator` + `progressContainer` and build them in `configureViews`
  (`ClipViewerViewController.swift#func configureViews`), replacing `progressView` in the
  arranged-subviews list with `progressContainer`. Add `hasCompletedFirstLayout` +
  `viewDidLayoutSubviews`. Add the three render helpers. Rewrite `render(_:)`
  (`#func render`) and `renderProgress(_:)` (`#func renderProgress`) per the matrix.
  Remove `state = .preparing` from `viewDidLoad`. Add the `setProgress(0, animated:
  false)` reset in `startPull()` (`#func startPull`).
- **`app/DanCam/DanCam/Media/ClipRemuxer.swift`** -- no source change; referenced by the
  new test helper.
- **`app/DanCam/DanCamTests/Features/ClipViewer/ClipViewerViewControllerTests.swift`** --
  tests (below).
- **`app/docs/design/13-2026-07-01-durable-clip-cache.md`** -- append a dated note.

## Tests

Expose one semantic test seam rather than raw view flags (survives an indicator-widget
swap and reads as behavior):

```
enum ProgressIndicatorState: Equatable { case hidden, indeterminate, determinate }
var progressIndicatorForTesting: ProgressIndicatorState { /* from spinner.isAnimating + progressView.isHidden */ }
```

The existing suite (`loadViewIfNeeded()` + `waitUntil` polling of terminal state; DI via
`makeController`) needs no rework -- no current test reads `progressFraction` or asserts
`statusText == "Preparing"`, so nothing breaks.

**Coverage contract: every indicator branch this plan changes gets a mandatory
`progressIndicatorForTesting` assertion.** The bar is determinate *only* during a
known-size pull; nothing else may show it. All five branches below are required (not
"recommended") -- without them an implementation could regress `.playing` back to a full
bar (its behavior today) or leave an unknown-size pull showing a zero bar, and still pass.
The assertion is behavioral (which indicator the user sees) and structure-insensitive (it
routes through the semantic enum, not the widget types).

Held-state branches (`.indeterminate` / `.determinate`) are pinned by gating the relevant
dependency on an `AsyncSignal` (mirror of the existing `gatedPullClient`; `AsyncSignal`
lives in `DanCamTests/Support/`) and asserting while held, then signalling + tearing down
via `didMove(toParent: nil)`. Terminal branches (`.hidden`) are folded into the existing
terminal-state tests that already `waitUntil` "Ready" / "Clip failed".

1. **Initial cache-lookup window -> `.indeterminate`** (the bug's locus). Gate the
   `ClipCache(lookup:)` closure on an `AsyncSignal`; while held assert `== .indeterminate`.
2. **Known-size pull -> `.determinate`.** Reuse the existing `gatedPullClient` (yields
   `.progress(bytesWritten: 1, expected: 1)` then holds); `waitUntil` the existing
   "1 byte of 1 byte" status text, then assert `== .determinate`.
3. **Remux `.preparing` -> `.indeterminate`.** Add a `gatedRemuxer(allowCompletion:)`
   helper -- `ClipRemuxer { source, _ in await allowCompletion.wait(); return
   ClipRemuxResult(fileURL: source, duration: .zero, bytes: ...) }` (mirror of
   `gatedPullClient`, using `ClipRemuxer` from `ClipRemuxer.swift`). Drive with
   `completedPullEvents` + this remuxer; while held assert `== .indeterminate`, then
   release to `.playing`.
4. **Unknown/zero-expected pull -> `.indeterminate`.** Parameterize the gated pull helper
   with an `expected: UInt64?` (default `1`) so it can yield `.progress(bytesWritten: 5,
   expected: <case>)` then hold. Run the test over **both** boundary values -- `expected:
   nil` *and* `expected: 0` (e.g. Swift Testing `@Test(arguments: [nil, 0] as [UInt64?])`)
   -- because `renderProgress` splits on `expected > 0`, folding both into the
   indeterminate branch; an implementation that guarded only `!= nil` would treat `0` as
   determinate (and divide by zero). For each case, `waitUntil` the "5 bytes pulled" status
   text (both cases produce it), then assert `== .indeterminate` (guards against a stuck
   zero bar).
5. **`.playing` and `.failed` -> `.hidden`.** Extend the existing terminal-state tests:
   in a cache-hit test and the miss->play test, after `statusText == "Ready"` assert
   `== .hidden`; in a failure test (e.g. `remuxFailureShowsErrorAndRetryStartsANewPull`),
   after `statusText == "Clip failed"` assert `== .hidden`. This pins the "player/error
   replaces the bar" contract.

Cache-hit "never shows the determinate bar" additionally holds by invariant: the existing
`cacheHitPlaysLookedUpURLWithoutPulling` asserts `pullCalls.values().isEmpty`, and the
"determinate bar is reached only from `.pulling`" rule makes no-pull imply no-bar. Test 5
turns that from an argument into a checked terminal assertion.

## ADR

Append a dated note to `app/docs/design/13-2026-07-01-durable-clip-cache.md` (matching
its existing `> **Note (YYYY-MM-DD):**` style): indeterminate phases (initial
cache-lookup window, remux/insert "Preparing", unknown-size pull) render an indeterminate
spinner; the determinate `UIProgressView` is reserved for known-size pull; determinate
animation is gated on the first layout pass to avoid animating against pre-layout bounds;
`.playing` no longer shows a full bar; the `ViewerState` enum is unchanged and the initial
pre-lookup window is now stateless (imperative spinner), so a cache hit logs `viewer none
-> playing`.

## Verification

This is a visual/animation defect, so verify by eye plus the suite:

1. **Unit suite:** `just app-test` -- existing tests plus the five render-matrix
   assertions (new + extended terminal-state tests) pass.
2. **Compiler cleanliness:** `just app-lint` (clean build, warnings surfaced).
3. **Run the app** (simulator, via the `run` skill or Xcode) against the mock Pi
   (`just raspi-mock-clips`) so `/v1/clips` serves a finished clip:
   - Tap an **uncached** clip: the determinate bar fills smoothly from the left (0 ->
     100%) with no width/half-to-full artifact, then a brief spinner "Preparing," then
     the player ("Ready"), no bar.
   - Tap the **same clip again** (now cached): straight to the player; at most a brief
     spinner, and the determinate bar never appears.
   - Optionally capture a short screen recording of both taps to confirm the animation is
     gone (the artifact is motion, not a still).
4. **Logs:** `just app-logs` and confirm `viewer none -> playing` on the cached tap and a
   single `-> preparing ->` on the uncached tap.
