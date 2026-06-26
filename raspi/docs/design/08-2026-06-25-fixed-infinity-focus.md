# ADR: Fixed infinity focus

- **Status:** Accepted
- **Date:** 2026-06-25
- **Owner:** raspi
- **Related:** `01-2026-06-22-crash-safe-recording.md`;
  `07-2026-06-25-picamera2-camera-owner.md`

## Context

The v1 camera is an Arducam IMX708 Autofocus Wide. Autofocus is useful for generic
camera work, but it is a bad fit for a dashcam mounted behind glass: continuous or
startup autofocus can lock onto rain, dust, smudges, glare, or a nearby hand instead
of the road.

The Picamera2 camera owner introduced for `jet` configures both the 1080p H.264
recording stream and the low-res MJPEG preview stream, but it did not set any focus
control. That leaves the lens at Picamera2's default manual position, which is not a
deliberate infinity setting. Because the recording stream is the system of record,
soft focus would be baked into the footage rather than limited to live preview.

## Decision

Lock the IMX708 lens to infinity in the Picamera2 camera-owner configuration by
setting `AfMode` to `Manual` and `LensPosition` to `0.0`.

This is hardcoded. There is no runtime setting, environment variable, or CLI knob for
focus position. The camera unit should behave like a fixed-focus commercial dashcam:
the useful range is the road ahead, and the lens should never hunt onto windshield
artifacts.

## Consequences

- Distant road objects, signs, and vehicles are the deliberate focus target.
- Recording and preview share the same lens position because focus is a sensor/lens
  control, not a per-stream control.
- The camera cannot hunt during a drive, including when glass artifacts or glare move
  through the scene.
- Retuning is a code change. That is acceptable while the focus policy is a fixed
  product decision; bring-up can still sweep candidate values with a throwaway
  Picamera2 script before changing the constant.

## Alternatives considered

- **Continuous autofocus.** Rejected. It can hunt onto windshield artifacts and shift
  focus during recording.
- **One-shot autofocus at startup.** Rejected. It can lock onto rain, glare, or a
  nearby object and then preserve the wrong focus for the whole drive.
- **Tune a hyperfocal lens position.** Rejected for now. A 120-degree wide lens gets
  limited practical depth-of-field benefit over infinity, and tuning it blind is not
  worth adding another variable before road testing.
- **Expose `--lens-position`.** Rejected. Dan confirmed this should be a fixed product
  decision rather than a runtime surface.
