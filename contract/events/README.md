# `/v1/events` Contract

`GET /v1/events` is a `text/event-stream` endpoint. Every frame uses the SSE
`id:` line for the per-boot sequence number and one `data:` line containing a
single JSON event object:

```text
id: 42
data: {"type":"heartbeat","t_ms":12000}

```

There is no SSE `event:` discriminator and no JSON frame envelope. The JSON
object is the tagged event, keyed by `type`; the files in this
directory are the canonical event bodies that cross the wire in `data:`.

The first frame on every connection is `snapshot`, followed by ordered delta
events and periodic `heartbeat` events. Reconnects ignore `Last-Event-ID` and
start with a fresh snapshot, because any gap is resolved by replacing local
state with the new snapshot and then folding subsequent deltas.

`GET /v1/status` is a one-shot read of the same `snapshot` event body, without
SSE framing.

## Event Rules

- `seq` is not in JSON. It is carried only by the SSE `id:` line.
- `at_ms` and `t_ms` are milliseconds since Pi boot, paired with `boot_id`.
  They are display and ordering aids, not wall-clock evidence.
- A recording is identified by the pair (`boot_tag`, `session`). Finished
  clips carry both as nullable fields -- present together for a stamped
  segment, both null for a bare one. The snapshot pairs its top-level
  `boot_tag` with `recorder.session` to name the recording being written.
- Authoritative event order is the SSE `id:` sequence.
- `segment_opened` and `clip_finalized` are separate events. Rollover emits
  `clip_finalized` for the old segment and `segment_opened` for the new one.
- `clip_removed` is the symmetric list-removal delta for a finished clip that
  has been durably deleted from the Pi.
- `recording_starting` and `recording_stopping` are authoritative accepted
  command transitions, not just local app optimism.
- Clients must ignore unknown event `type` values.

## Recorder Snapshot

The recorder slice is the source of truth for the live row:

```json
{
  "phase": "recording",
  "session": 7,
  "current_segment": {
    "id": 43,
    "dur_ms": 12000
  },
  "detail": null
}
```

`current_segment` is `null` until a real segment is observed open, and is
cleared on stop or failure. `detail` is populated only for the error phase.
