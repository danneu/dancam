use std::{path::Path, time::Duration};

use axum::{
    extract::State,
    response::sse::{Event as SseEvent, Sse},
    Json,
};
use tokio_stream::{wrappers::BroadcastStream, Stream, StreamExt};

use crate::{
    clips::{resolve_segment, ClipMeta},
    recorder::{CurrentSegment, RecorderSnapshot},
    sysfacts::{DiskUsage, MemInfo},
    world::{CameraState, TempC},
    AppState,
};

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, PartialEq)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Event {
    Snapshot(Snapshot),
    RecordingStarting {
        session: u64,
        at_ms: u64,
    },
    RecordingStarted {
        session: u64,
        at_ms: u64,
    },
    SegmentOpened {
        session: u64,
        id: u32,
        at_ms: u64,
    },
    ClipFinalized(ClipMeta),
    ClipRemoved {
        id: u32,
    },
    RecordingStopping {
        session: u64,
        at_ms: u64,
    },
    RecordingStopped {
        session: u64,
        at_ms: u64,
    },
    RecorderFailed {
        session: u64,
        detail: String,
        at_ms: u64,
    },
    CameraStateChanged {
        state: CameraState,
    },
    StorageChanged {
        used: u64,
        total: u64,
    },
    TempChanged {
        soc: Option<f32>,
        sensor: Option<f32>,
    },
    MemChanged {
        total: u64,
        available: u64,
        swap_total: u64,
        swap_used: u64,
    },
    TimeSynced {
        at_ms: u64,
    },
    Heartbeat {
        t_ms: u64,
    },
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, PartialEq)]
pub struct Snapshot {
    pub recorder: RecorderSnapshot,
    pub camera_state: CameraState,
    pub boot_id: String,
    pub uptime_s: u64,
    pub storage: Option<DiskUsage>,
    pub temp_c: TempC,
    pub mem: Option<MemInfo>,
    pub time: TimeStatus,
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct TimeStatus {
    pub synced: bool,
}

pub async fn status(State(state): State<AppState>) -> Json<Snapshot> {
    Json(enrich_current_segment(state.backend.snapshot(), &state).await)
}

pub async fn events(
    State(state): State<AppState>,
) -> Sse<impl Stream<Item = Result<SseEvent, axum::Error>>> {
    let connection = state.backend.connect();
    let snapshot = enrich_current_segment(connection.snapshot, &state).await;
    let first_event = Event::Snapshot(snapshot);
    tracing::debug!(seq = connection.seq, event = ?first_event, "emit");
    let first = tokio_stream::once(sse_frame(connection.seq, first_event));
    let updates = BroadcastStream::new(connection.rx).map(|event| match event {
        Ok(event) => sse_frame(event.seq, event.event),
        Err(error) => {
            match error {
                tokio_stream::wrappers::errors::BroadcastStreamRecvError::Lagged(skipped) => {
                    tracing::warn!(skipped, "events stream lagged; closing for reconnect");
                }
            }
            Err(axum::Error::new(error))
        }
    });

    Sse::new(first.chain(updates))
}

pub fn spawn_heartbeat(backend: std::sync::Arc<dyn crate::backend::Backend>, interval: Duration) {
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(interval);
        loop {
            interval.tick().await;
            backend.tick();
        }
    });
}

pub fn spawn_telemetry(
    backend: std::sync::Arc<dyn crate::backend::Backend>,
    rec_dir: std::sync::Arc<Path>,
    interval: Duration,
) {
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(interval);
        loop {
            interval.tick().await;
            backend.update_telemetry(
                crate::sysfacts::disk_usage(&rec_dir),
                TempC {
                    soc: crate::sysfacts::soc_temp_c(),
                    sensor: None,
                },
                crate::sysfacts::mem_info(),
            );
        }
    });
}

async fn enrich_current_segment(mut snapshot: Snapshot, state: &AppState) -> Snapshot {
    let Some(current) = snapshot.recorder.current_segment.clone() else {
        return snapshot;
    };

    let rec_dir = state.storage.rec_dir();
    let duration_cache = state.clip_durations.clone();
    let id = current.id;
    let dur_ms = match tokio::task::spawn_blocking(move || {
        let Some(segment) = resolve_segment(rec_dir.as_ref(), id)? else {
            return Ok::<Option<u64>, std::io::Error>(None);
        };
        Ok(duration_cache.duration_ms(id, &segment.path, segment.bytes))
    })
    .await
    {
        Ok(Ok(dur_ms)) => dur_ms,
        Ok(Err(error)) => {
            tracing::debug!(%error, id, "skipping current segment duration enrichment");
            None
        }
        Err(error) => {
            tracing::error!(%error, "current segment duration task failed");
            None
        }
    };

    snapshot.recorder.current_segment = Some(CurrentSegment { dur_ms, ..current });
    snapshot
}

fn sse_frame(seq: u64, event: Event) -> Result<SseEvent, axum::Error> {
    SseEvent::default().id(seq.to_string()).json_data(event)
}

#[cfg(test)]
mod tests {
    use super::{Event, Snapshot, TimeStatus};
    use crate::{
        clips::ClipMeta,
        recorder::{CurrentSegment, RecorderPhase, RecorderSnapshot},
        sysfacts::{DiskUsage, MemInfo},
        world::{CameraState, TempC},
    };

    #[test]
    fn events_match_the_golden_corpus() {
        for event in canonical_events() {
            let fixture = fixture(canonical_name(&event));
            let serialized = serde_json::to_value(&event).unwrap();
            let expected: serde_json::Value = serde_json::from_str(&fixture).unwrap();
            assert_eq!(serialized, expected, "{}", canonical_name(&event));

            let decoded: Event = serde_json::from_str(&fixture).unwrap();
            assert_eq!(decoded, event, "{}", canonical_name(&event));
        }
    }

    fn canonical_events() -> Vec<Event> {
        vec![
            Event::Snapshot(Snapshot {
                recorder: RecorderSnapshot {
                    phase: RecorderPhase::Recording,
                    session: 7,
                    current_segment: Some(CurrentSegment {
                        id: 43,
                        dur_ms: Some(12000),
                    }),
                    detail: None,
                },
                camera_state: CameraState::Running,
                boot_id: "boot-7f3a91c2".to_string(),
                uptime_s: 120,
                storage: Some(DiskUsage {
                    used: 1_000_000_000,
                    total: 32_000_000_000,
                }),
                temp_c: TempC {
                    soc: Some(51.5),
                    sensor: None,
                },
                mem: Some(MemInfo {
                    total: 512_000_000,
                    available: 256_000_000,
                    swap_total: 134_217_728,
                    swap_used: 0,
                }),
                time: TimeStatus { synced: true },
            }),
            Event::RecordingStarting {
                session: 7,
                at_ms: 5000,
            },
            Event::RecordingStarted {
                session: 7,
                at_ms: 5200,
            },
            Event::SegmentOpened {
                session: 7,
                id: 43,
                at_ms: 5400,
            },
            Event::ClipFinalized(ClipMeta {
                id: 42,
                start_ms: None,
                dur_ms: Some(30000),
                bytes: 1_048_576,
                locked: false,
                etag: "42-1048576".to_string(),
                time_approximate: true,
            }),
            Event::ClipRemoved { id: 42 },
            Event::RecordingStopping {
                session: 7,
                at_ms: 60000,
            },
            Event::RecordingStopped {
                session: 7,
                at_ms: 62000,
            },
            Event::RecorderFailed {
                session: 7,
                detail: "camera process exited".to_string(),
                at_ms: 9400,
            },
            Event::CameraStateChanged {
                state: CameraState::Running,
            },
            Event::StorageChanged {
                used: 1_000_000_000,
                total: 32_000_000_000,
            },
            Event::TempChanged {
                soc: Some(51.5),
                sensor: None,
            },
            Event::MemChanged {
                total: 512_000_000,
                available: 256_000_000,
                swap_total: 134_217_728,
                swap_used: 0,
            },
            Event::TimeSynced { at_ms: 7000 },
            Event::Heartbeat { t_ms: 12000 },
        ]
    }

    fn canonical_name(event: &Event) -> &'static str {
        match event {
            Event::Snapshot(_) => "snapshot",
            Event::RecordingStarting { .. } => "recording_starting",
            Event::RecordingStarted { .. } => "recording_started",
            Event::SegmentOpened { .. } => "segment_opened",
            Event::ClipFinalized(_) => "clip_finalized",
            Event::ClipRemoved { .. } => "clip_removed",
            Event::RecordingStopping { .. } => "recording_stopping",
            Event::RecordingStopped { .. } => "recording_stopped",
            Event::RecorderFailed { .. } => "recorder_failed",
            Event::CameraStateChanged { .. } => "camera_state_changed",
            Event::StorageChanged { .. } => "storage_changed",
            Event::TempChanged { .. } => "temp_changed",
            Event::MemChanged { .. } => "mem_changed",
            Event::TimeSynced { .. } => "time_synced",
            Event::Heartbeat { .. } => "heartbeat",
        }
    }

    fn fixture(name: &str) -> String {
        std::fs::read_to_string(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../contract/events")
                .join(format!("{name}.json")),
        )
        .unwrap()
    }
}
