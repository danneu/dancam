# Plan: lock the IMX708 lens to infinity focus (disable autofocus)

## Context

The dashcam uses the Arducam IMX708 **Autofocus** Wide. The `jet` Picamera2 migration
(`plans/impl/2026-06-25-2034-picamera2-camera-owner.md`) shipped `raspi/camera/camera.py`
as the single libcamera owner, but it never set any focus control -- the
`create_video_configuration` call passes `controls={"FrameRate": 30}` and nothing else.

That leaves focus at Picamera2's default: a **manual lens parked at an unspecified
default position** (typically ~1 dioptre / ~1 m), *not* infinity. Two problems:

1. Focus is whatever the driver happened to pick, not a deliberate choice -- the road
   (cars, signs, plates, the entire useful range of a dashcam) can sit soft.
2. This is the **recording** path (the `main` 1080p H.264 stream, the system's source of
   truth), so the wrong focus is baked into footage, not just the live preview.

Commercial dashcams avoid windshield-focus entirely by using a fixed-focus lens glued at
the hyperfocal/infinity distance -- no AF element to hunt onto rain, dust, smudges, or
glare on the glass. We make our AF camera behave the same way in software: lock
`AfMode=Manual` at `LensPosition=0.0` (infinity). A 120-deg wide lens at infinity keeps
everything past ~1 m sharp, and the windshield (~10-30 cm away) sits deep in the near-blur
zone where it can never grab focus -- and because focus never moves, it can never hunt.

Decision (confirmed with Dan): **hardcode infinity**, no CLI knob. It's a fixed product
decision, not a runtime setting.

## Change

### 1. `raspi/camera/camera.py` -- set the focus controls (the only code change)

Two edits inside `RealCameraDriver.start()` (the Pi-only path; the Mac mock/`--fake`
paths are untouched):

- **Lazy import block (lines 266-268)** -- add the libcamera controls import alongside the
  existing Picamera2 imports (kept lazy so Mac dev, which has no libcamera, stays
  import-clean):
  ```python
  from picamera2 import Picamera2
  from picamera2.encoders import MJPEGEncoder
  from picamera2.outputs import Output
  from libcamera import controls
  ```

- **Config dict (line 285)** -- add the two focus controls next to `FrameRate`:
  ```python
  controls={
      "FrameRate": 30,
      "AfMode": controls.AfModeEnum.Manual,  # disable autofocus; never hunt onto the windshield
      "LensPosition": 0.0,                    # dioptres: 0.0 = infinity
  },
  ```

  Setting these in the configuration `controls` (not a later `set_controls`) locks the
  lens from the first frame, with no startup AF window. Focus is a sensor/lens-level
  control, independent of the `main`/`lores` split, so both streams share the lock
  automatically -- no interaction with the dual-stream concurrency work.

`AfMode=Manual` is set explicitly (not relied on as a default) precisely because the
default manual position is *not* infinity. `controls.AfModeEnum.Manual` is the documented
Picamera2 idiom; the integer literal `0` is an equivalent fallback if the import is ever a
problem, but the named enum is clearer and `python3-libcamera` is already installed on the
Pi.

### 2. Docs (land with the change, per the project's "write the decision down" rule)

This is a real camera-tuning decision that is currently undocumented. Three small notes:

- **New ADR 08** (`raspi/docs/design/08-2026-06-25-fixed-infinity-focus.md` -- next free
  seq after 07; bump the date if it slips past 2026-06-25). The repo's ADR convention is
  **one decision per file** (`AGENTS.md:142`), so the focus policy gets its **own** ADR
  rather than a note buried in the camera-owner ADR 07 (which would weaken ADR history and
  hide the policy). Status: **Accepted**. Standard ADR shape:
  - **Context** -- IMX708 is an autofocus part; Picamera2's default leaves the lens at an
    unspecified manual position (~1 m), not infinity; AF on glass hunts onto rain/dust/glare;
    the recording `main` stream is the system's source of truth.
  - **Decision** -- lock the lens to infinity (`AfMode=Manual`, `LensPosition=0.0`) in the
    camera-owner config; **hardcoded, no runtime knob** (fixed product decision).
  - **Consequences** -- behaves like the fixed-focus lens commercial dashcams use; no AF
    hunting; both `main` + `lores` streams share the lock; retuning means a one-line edit
    (acceptable -- bring-up can sweep values via the throwaway script in Verification).
  - **Alternatives considered** -- continuous AF (hunts onto glass); one-shot AF at startup
    (can mislock on rain/glare and stay wrong the whole drive); hyperfocal (marginal DoF gain
    over infinity for a 120-deg lens, not worth tuning blind); a `--lens-position` CLI knob
    (rejected with Dan -- product surface without improving the recording path).
  - Run `just adr-check` after (enforces the seq/date/slug naming).
- **`raspi/AGENTS.md`** -- (a) in the **Capture/encode** bullet (lines 67-74), add a
  sentence that the camera-owner locks focus to infinity / disables autofocus for the
  recording and preview streams, citing ADR 08; (b) add an entry for ADR 08 to the
  **Design decisions (ADRs)** list at the bottom of the file.
- **`README.md`** -- in the **Running** section's camera-process description (around lines
  248-250, "That process owns libcamera, ..."), note that it locks the lens to infinity
  (autofocus disabled), pointing to ADR 08. Feature note, not a tuning knob -- no new env
  var or CLI arg to document.

## Tests

No automated test is added. Nothing currently asserts on the `controls` dict, and a test
that checked for specific keys would be structure-sensitive without verifying anything
behavioral -- actual focus can only be confirmed on hardware with a real scene. The
existing camera.py tests (stdout/stderr contract, segment numbering) are unaffected, as
are all Rust/app tests; this is a pure config addition on the Pi-only path.

## Verification

- **No regressions (Mac):** `just raspi-test` stays green; `just raspi-run` (mock backend)
  + the app still previews -- this change doesn't touch the mock/`--fake` paths.
- **Import sanity (Pi):** `python3 -c "from libcamera import controls; print(controls.AfModeEnum.Manual)"`
  on the Pi confirms the enum resolves.
- **Control took effect (Pi):** before trusting the scene, confirm the lens actually
  reached the requested position via Picamera2's `LensPosition` metadata (a control/metadata
  mismatch is invisible to a subjective scene check). Throwaway script on the Pi:
  ```sh
  python3 - <<'PY'
  from picamera2 import Picamera2
  from libcamera import controls
  p = Picamera2()
  p.configure(p.create_video_configuration(
      main={"size": (1920, 1080), "format": "YUV420"},
      controls={"FrameRate": 30, "AfMode": controls.AfModeEnum.Manual, "LensPosition": 0.0}))
  p.start()
  print("LensPosition:", p.capture_metadata().get("LensPosition"))
  p.stop()
  PY
  ```
  Expect `LensPosition` reported near `0.0`. (This same script is the "sweep values"
  bring-up tool referenced in ADR 08 -- vary the requested `LensPosition` to compare.)
- **On-hardware (the real check):** `just raspi-deploy`, then run the README smoke-test
  harness (`README.md` ~lines 282-294: `python3 /usr/local/lib/dancam/camera.py --rec-dir
  ... --preview-fps 10`). With the camera aimed through a windshield (or any glass):
  - Distant objects (road, signs, far cars) are **sharp** in the preview MJPEG and in a
    pulled `.ts` segment (`ffmpeg -v error -i seg_00000.ts -f null -` for integrity;
    eyeball a frame for focus).
  - Nearby glass artifacts (a smudge, a water drop on the windshield) stay **blurred** and
    never pull focus, even when you re-run or wave a hand close to the lens -- because
    focus is fixed, it cannot hunt.
  - Preview still flows and recording still produces clean segments (no regression to the
    `jet` concurrency behavior).
- **ADR hygiene:** `just adr-check` passes after adding ADR 08 (validates seq/date/slug naming).
