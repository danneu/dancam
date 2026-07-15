use std::time::Duration;

use axum::{
    extract::State,
    response::sse::{Event as SseEvent, Sse},
    Json,
};
use tokio_stream::{wrappers::BroadcastStream, Stream, StreamExt};

use crate::{
    clips::ClipMeta,
    cpu::{Cpu, CpuCore, CpuSampler},
    event_hub::EventConnection,
    recorder::{CurrentSegment, RecorderSnapshot},
    sysfacts::{DiskUsage, MemInfo},
    world::{CameraState, RecordingReadiness, TempC, TempReading},
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
        recording_readiness: RecordingReadiness,
    },
    StorageChanged {
        storage: Option<DiskUsage>,
        recording_readiness: RecordingReadiness,
    },
    TempChanged {
        soc: TempReading,
        sensor: TempReading,
    },
    MemChanged {
        total: u64,
        available: u64,
        swap_total: u64,
        swap_used: u64,
    },
    CpuChanged {
        cores: Vec<CpuCore>,
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
    pub recording_readiness: RecordingReadiness,
    pub boot_id: String,
    pub boot_tag: Option<String>,
    pub uptime_s: u64,
    pub storage: Option<DiskUsage>,
    pub temp_c: TempC,
    pub mem: Option<MemInfo>,
    pub cpu: Cpu,
    pub time: TimeStatus,
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct TimeStatus {
    pub synced: bool,
}

pub async fn status(State(state): State<AppState>) -> Json<Snapshot> {
    Json(materialize_snapshot(&state, || state.backend.snapshot()).await)
}

pub async fn events(
    State(state): State<AppState>,
) -> Sse<impl Stream<Item = Result<SseEvent, axum::Error>>> {
    let connection = materialize_snapshot(&state, || state.backend.connect()).await;
    let snapshot = connection.snapshot;
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
    filesystem: std::sync::Arc<crate::filesystem_observer::FilesystemObserver>,
    interval: Duration,
) {
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(interval);
        let mut cpu_sampler = CpuSampler::new();
        loop {
            interval.tick().await;
            let observation = filesystem
                .observe(None)
                .await
                .unwrap_or_else(|| filesystem.unavailable_observation());
            backend.update_telemetry(
                observation.storage,
                observation.recording_storage_available,
                crate::sysfacts::soc_temp_c(),
                crate::sysfacts::mem_info(),
                cpu_sampler.sample(),
            );
        }
    });
}

pub async fn seed_filesystem_observation(state: &AppState) {
    let observation = state
        .filesystem
        .observe(None)
        .await
        .unwrap_or_else(|| state.filesystem.unavailable_observation());
    state
        .backend
        .update_storage(observation.storage, observation.recording_storage_available);
}

async fn materialize_snapshot<T>(state: &AppState, finalize: impl FnOnce() -> T) -> T
where
    T: SnapshotMaterialization,
{
    let preliminary = state.backend.snapshot();
    let observation = observe_filesystem(state, &preliminary).await;
    let mut materialized = finalize();
    apply_duration(materialized.snapshot_mut(), &observation);
    materialized
}

trait SnapshotMaterialization {
    fn snapshot_mut(&mut self) -> &mut Snapshot;
}

impl SnapshotMaterialization for Snapshot {
    fn snapshot_mut(&mut self) -> &mut Snapshot {
        self
    }
}

impl SnapshotMaterialization for EventConnection {
    fn snapshot_mut(&mut self) -> &mut Snapshot {
        &mut self.snapshot
    }
}

async fn observe_filesystem(
    state: &AppState,
    preliminary: &Snapshot,
) -> crate::filesystem_observer::FilesystemObservation {
    let current_segment = preliminary
        .recorder
        .current_segment
        .as_ref()
        .map(|segment| segment.id);
    let observation = state
        .filesystem
        .observe(current_segment)
        .await
        .unwrap_or_else(|| state.filesystem.unavailable_observation());
    state.backend.update_storage(
        observation.storage.clone(),
        observation.recording_storage_available,
    );
    observation
}

fn apply_duration(
    snapshot: &mut Snapshot,
    observation: &crate::filesystem_observer::FilesystemObservation,
) {
    let Some(current) = snapshot.recorder.current_segment.clone() else {
        return;
    };
    let dur_ms = observation
        .current_segment
        .as_ref()
        .filter(|observed| observed.id == current.id)
        .and_then(|observed| observed.dur_ms);
    snapshot.recorder.current_segment = Some(CurrentSegment { dur_ms, ..current });
}

fn sse_frame(seq: u64, event: Event) -> Result<SseEvent, axum::Error> {
    SseEvent::default().id(seq.to_string()).json_data(event)
}

#[cfg(test)]
mod tests {
    use super::{apply_duration, Event, Snapshot, TimeStatus};
    use crate::{
        clips::ClipMeta,
        cpu::{Cpu, CpuCore},
        filesystem_observer::{FilesystemObservation, ObservedSegment},
        recorder::{CurrentSegment, RecorderPhase, RecorderSnapshot},
        sysfacts::{DiskUsage, MemInfo},
        world::{CameraState, RecordingReadiness, TempC, TempReading},
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

    #[test]
    fn duration_observed_for_a_rolled_segment_is_discarded() {
        let Event::Snapshot(mut snapshot) = canonical_events().remove(0) else {
            panic!("first canonical event was not a snapshot");
        };
        apply_duration(
            &mut snapshot,
            &FilesystemObservation {
                storage: None,
                recording_storage_available: true,
                current_segment: Some(ObservedSegment {
                    id: 44,
                    dur_ms: Some(30000),
                }),
            },
        );

        let current = snapshot.recorder.current_segment.unwrap();
        assert_eq!(current.id, 43);
        assert_eq!(current.dur_ms, None);
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
                recording_readiness: RecordingReadiness {
                    ready: true,
                    reason: None,
                },
                boot_id: "7f3a91c2-b0d4-4e15-b196-20e0416af749".to_string(),
                boot_tag: Some("7f3a91c2b0d4".to_string()),
                uptime_s: 120,
                storage: Some(DiskUsage {
                    used: 1_000_000_000,
                    total: 32_000_000_000,
                    recording_capacity_bytes: 29_000_000_000,
                }),
                temp_c: TempC {
                    soc: TempReading {
                        current: Some(51.5),
                        max: Some(62.5),
                    },
                    sensor: TempReading {
                        current: None,
                        max: Some(49.0),
                    },
                },
                mem: Some(MemInfo {
                    total: 512_000_000,
                    available: 256_000_000,
                    swap_total: 134_217_728,
                    swap_used: 0,
                }),
                cpu: Cpu {
                    cores: vec![
                        CpuCore {
                            id: 0,
                            current_pct: Some(98),
                            one_minute_pct: Some(74),
                            five_minute_pct: Some(52),
                            fifteen_minute_pct: Some(40),
                        },
                        CpuCore {
                            id: 2,
                            current_pct: Some(12),
                            one_minute_pct: Some(20),
                            five_minute_pct: Some(30),
                            fifteen_minute_pct: Some(35),
                        },
                    ],
                },
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
                boot_tag: Some("7f3a91c2b0d4".into()),
                session: Some(7),
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
                recording_readiness: RecordingReadiness {
                    ready: true,
                    reason: None,
                },
            },
            Event::StorageChanged {
                storage: Some(DiskUsage {
                    used: 1_000_000_000,
                    total: 32_000_000_000,
                    recording_capacity_bytes: 29_000_000_000,
                }),
                recording_readiness: RecordingReadiness {
                    ready: true,
                    reason: None,
                },
            },
            Event::TempChanged {
                soc: TempReading {
                    current: Some(51.5),
                    max: Some(62.5),
                },
                sensor: TempReading {
                    current: Some(43.5),
                    max: Some(49.0),
                },
            },
            Event::MemChanged {
                total: 512_000_000,
                available: 256_000_000,
                swap_total: 134_217_728,
                swap_used: 0,
            },
            Event::CpuChanged {
                cores: vec![
                    CpuCore {
                        id: 0,
                        current_pct: Some(98),
                        one_minute_pct: Some(74),
                        five_minute_pct: Some(52),
                        fifteen_minute_pct: Some(40),
                    },
                    CpuCore {
                        id: 2,
                        current_pct: None,
                        one_minute_pct: None,
                        five_minute_pct: None,
                        fifteen_minute_pct: None,
                    },
                ],
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
            Event::CpuChanged { .. } => "cpu_changed",
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
