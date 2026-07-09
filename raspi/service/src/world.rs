use crate::{
    clips::ClipMeta,
    events::{Event, Snapshot, TimeStatus},
    recorder::{RecorderEvent, RecorderPhase, RecorderState, SegmentId, SessionId},
    sysfacts::{DiskUsage, MemInfo},
};

#[derive(Clone, Copy, Debug, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CameraState {
    Starting,
    Running,
    Restarting,
    Offline,
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, PartialEq)]
pub struct TempC {
    pub soc: Option<f32>,
    pub sensor: Option<f32>,
}

impl TempC {
    pub fn empty() -> Self {
        Self {
            soc: None,
            sensor: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct World {
    recorder: RecorderState,
    camera_state: CameraState,
    storage: Option<DiskUsage>,
    temp_c: TempC,
    mem: Option<MemInfo>,
    time_synced: bool,
}

impl World {
    pub fn new(camera_state: CameraState) -> Self {
        Self {
            recorder: RecorderState::new(),
            camera_state,
            storage: None,
            temp_c: TempC::empty(),
            mem: None,
            time_synced: false,
        }
    }

    pub fn snapshot(&self, boot_id: &str, uptime_s: u64) -> Snapshot {
        Snapshot {
            recorder: self.recorder.snapshot(),
            camera_state: self.camera_state,
            boot_id: boot_id.to_string(),
            boot_tag: crate::recorder::boot_tag(boot_id),
            uptime_s,
            storage: self.storage.clone(),
            temp_c: self.temp_c.clone(),
            mem: self.mem.clone(),
            time: TimeStatus {
                synced: self.time_synced,
            },
        }
    }

    pub fn apply(&mut self, input: Input, now_ms: u64) -> Vec<Event> {
        match input {
            Input::StartCommand { start_segment } => self
                .recorder
                .start(start_segment)
                .map(|session| Event::RecordingStarting {
                    session,
                    at_ms: now_ms,
                })
                .into_iter()
                .collect(),
            Input::StopCommand => self
                .recorder
                .stop()
                .map(|session| Event::RecordingStopping {
                    session,
                    at_ms: now_ms,
                })
                .into_iter()
                .collect(),
            Input::Recorder(event) => self.apply_recorder_event(event, now_ms),
            Input::SegmentRollover {
                session,
                finalized,
                opened,
            } => self.apply_segment_rollover(session, finalized, opened, now_ms),
            Input::ClipRemoved { id } => vec![Event::ClipRemoved { id }],
            Input::RecordingStopped { session, finalized } => {
                self.apply_recording_stopped(session, finalized, now_ms)
            }
            Input::Fail { detail } => self
                .recorder
                .fail(detail.clone())
                .map(|session| Event::RecorderFailed {
                    session,
                    detail,
                    at_ms: now_ms,
                })
                .into_iter()
                .collect(),
            Input::CameraState(state) => {
                if self.camera_state == state {
                    Vec::new()
                } else {
                    self.camera_state = state;
                    vec![Event::CameraStateChanged { state }]
                }
            }
            Input::Telemetry {
                storage,
                temp_c,
                mem,
            } => self.apply_telemetry(storage, temp_c, mem),
            Input::TimeSynced => {
                if self.time_synced {
                    Vec::new()
                } else {
                    self.time_synced = true;
                    vec![Event::TimeSynced { at_ms: now_ms }]
                }
            }
            Input::Tick => vec![Event::Heartbeat { t_ms: now_ms }],
        }
    }

    pub fn live_status(&self) -> LiveStatus {
        LiveStatus {
            phase: self.recorder.phase(),
            camera_state: self.camera_state,
        }
    }

    pub fn phase(&self) -> RecorderPhase {
        self.recorder.phase()
    }

    pub fn session(&self) -> SessionId {
        self.recorder.session()
    }

    pub fn current_segment(&self) -> Option<SegmentId> {
        self.recorder.current_segment()
    }

    pub fn unpullable_from(&self) -> Option<SegmentId> {
        self.recorder.unpullable_from()
    }

    fn apply_recorder_event(&mut self, event: RecorderEvent, now_ms: u64) -> Vec<Event> {
        let wire = match &event {
            RecorderEvent::RecordingStarted { session } => Event::RecordingStarted {
                session: *session,
                at_ms: now_ms,
            },
            RecorderEvent::SegmentOpened { session, id } => Event::SegmentOpened {
                session: *session,
                id: *id,
                at_ms: now_ms,
            },
            RecorderEvent::SegmentClosed { .. } => return Vec::new(),
            RecorderEvent::RecordingStopped { session } => Event::RecordingStopped {
                session: *session,
                at_ms: now_ms,
            },
        };

        self.recorder
            .apply(event)
            .then_some(wire)
            .into_iter()
            .collect()
    }

    fn apply_segment_rollover(
        &mut self,
        session: SessionId,
        finalized: ClipMeta,
        opened: SegmentId,
        now_ms: u64,
    ) -> Vec<Event> {
        let closed = RecorderEvent::SegmentClosed {
            session,
            id: finalized.id,
        };
        if !self.recorder.apply(closed) {
            return Vec::new();
        }

        let opened_event = RecorderEvent::SegmentOpened {
            session,
            id: opened,
        };
        if !self.recorder.apply(opened_event) {
            return Vec::new();
        }

        vec![
            Event::ClipFinalized(finalized),
            Event::SegmentOpened {
                session,
                id: opened,
                at_ms: now_ms,
            },
        ]
    }

    fn apply_recording_stopped(
        &mut self,
        session: SessionId,
        finalized: Option<ClipMeta>,
        now_ms: u64,
    ) -> Vec<Event> {
        if !self
            .recorder
            .apply(RecorderEvent::RecordingStopped { session })
        {
            return Vec::new();
        }

        let mut events = Vec::new();
        if let Some(finalized) = finalized {
            events.push(Event::ClipFinalized(finalized));
        }
        events.push(Event::RecordingStopped {
            session,
            at_ms: now_ms,
        });
        events
    }

    fn apply_telemetry(
        &mut self,
        storage: Option<DiskUsage>,
        temp_c: TempC,
        mem: Option<MemInfo>,
    ) -> Vec<Event> {
        let mut events = Vec::new();
        if self.storage != storage {
            self.storage = storage.clone();
            if let Some(storage) = storage {
                events.push(Event::StorageChanged {
                    used: storage.used,
                    total: storage.total,
                });
            }
        }
        if self.temp_c != temp_c {
            self.temp_c = temp_c.clone();
            events.push(Event::TempChanged {
                soc: temp_c.soc,
                sensor: temp_c.sensor,
            });
        }

        let quantized_mem = mem.map(quantize_mem);
        if self.mem != quantized_mem {
            self.mem = quantized_mem.clone();
            if let Some(mem) = quantized_mem {
                events.push(Event::MemChanged {
                    total: mem.total,
                    available: mem.available,
                    swap_total: mem.swap_total,
                    swap_used: mem.swap_used,
                });
            }
        }

        events
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LiveStatus {
    pub phase: RecorderPhase,
    pub camera_state: CameraState,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Input {
    StartCommand {
        start_segment: SegmentId,
    },
    StopCommand,
    Recorder(RecorderEvent),
    SegmentRollover {
        session: SessionId,
        finalized: ClipMeta,
        opened: SegmentId,
    },
    ClipRemoved {
        id: SegmentId,
    },
    RecordingStopped {
        session: SessionId,
        finalized: Option<ClipMeta>,
    },
    Fail {
        detail: String,
    },
    CameraState(CameraState),
    Telemetry {
        storage: Option<DiskUsage>,
        temp_c: TempC,
        mem: Option<MemInfo>,
    },
    TimeSynced,
    Tick,
}

fn quantize_mem(mem: MemInfo) -> MemInfo {
    const QUANTUM: u64 = 1024 * 1024;

    MemInfo {
        total: round_down(mem.total, QUANTUM),
        available: round_down(mem.available, QUANTUM),
        swap_total: round_down(mem.swap_total, QUANTUM),
        swap_used: round_down(mem.swap_used, QUANTUM),
    }
}

fn round_down(value: u64, quantum: u64) -> u64 {
    value / quantum * quantum
}

#[cfg(test)]
mod tests {
    use super::{CameraState, Input, TempC, World};
    use crate::{
        clips::ClipMeta,
        events::Event,
        recorder::{RecorderEvent, RecorderPhase},
        sysfacts::{DiskUsage, MemInfo},
    };

    #[test]
    fn command_transitions_emit_starting_and_stopping() {
        let mut world = World::new(CameraState::Running);

        assert_eq!(
            world.apply(Input::StartCommand { start_segment: 43 }, 5000),
            vec![Event::RecordingStarting {
                session: 1,
                at_ms: 5000
            }]
        );
        assert_eq!(world.phase(), RecorderPhase::Starting);
        assert_eq!(world.unpullable_from(), Some(43));

        assert_eq!(
            world.apply(Input::StopCommand, 6000),
            vec![Event::RecordingStopping {
                session: 1,
                at_ms: 6000
            }]
        );
        assert_eq!(world.phase(), RecorderPhase::Stopping);
        assert!(world.apply(Input::StopCommand, 7000).is_empty());
    }

    #[test]
    fn fail_is_separate_from_camera_state_changes() {
        let mut world = World::new(CameraState::Running);
        world.apply(Input::StartCommand { start_segment: 43 }, 5000);
        world.apply(
            Input::Recorder(RecorderEvent::SegmentOpened { session: 1, id: 43 }),
            5200,
        );

        assert_eq!(
            world.apply(Input::CameraState(CameraState::Offline), 9000),
            vec![Event::CameraStateChanged {
                state: CameraState::Offline
            }]
        );
        assert_eq!(
            world.apply(
                Input::Fail {
                    detail: "camera process exited".to_string()
                },
                9001
            ),
            vec![Event::RecorderFailed {
                session: 1,
                detail: "camera process exited".to_string(),
                at_ms: 9001
            }]
        );
        assert_eq!(world.phase(), RecorderPhase::Error);
        assert_eq!(world.current_segment(), None);
        assert_eq!(world.unpullable_from(), Some(43));
    }

    #[test]
    fn child_error_does_not_emit_camera_state_change() {
        let mut world = World::new(CameraState::Running);
        world.apply(Input::StartCommand { start_segment: 43 }, 5000);

        let events = world.apply(
            Input::Fail {
                detail: "camera error".to_string(),
            },
            5100,
        );

        assert_eq!(events.len(), 1);
        assert!(matches!(events[0], Event::RecorderFailed { .. }));
    }

    #[test]
    fn rollover_finalizes_and_advances_floor_atomically() {
        let mut world = World::new(CameraState::Running);
        world.apply(Input::StartCommand { start_segment: 43 }, 5000);
        world.apply(
            Input::Recorder(RecorderEvent::SegmentOpened { session: 1, id: 43 }),
            5200,
        );

        let events = world.apply(
            Input::SegmentRollover {
                session: 1,
                finalized: clip(43),
                opened: 44,
            },
            8000,
        );

        assert_eq!(
            events,
            vec![
                Event::ClipFinalized(clip(43)),
                Event::SegmentOpened {
                    session: 1,
                    id: 44,
                    at_ms: 8000
                }
            ]
        );
        assert_eq!(world.current_segment(), Some(44));
        assert_eq!(world.unpullable_from(), Some(44));
    }

    #[test]
    fn clip_removed_emits_without_mutating_recorder_state() {
        let mut world = World::new(CameraState::Running);
        world.apply(Input::StartCommand { start_segment: 43 }, 5000);
        world.apply(
            Input::Recorder(RecorderEvent::SegmentOpened { session: 1, id: 43 }),
            5200,
        );
        let before = world.clone();

        assert_eq!(
            world.apply(Input::ClipRemoved { id: 42 }, 8000),
            vec![Event::ClipRemoved { id: 42 }]
        );
        assert_eq!(world, before);
    }

    #[test]
    fn stop_finalizes_before_recording_stopped_and_clears_floor() {
        let mut world = World::new(CameraState::Running);
        world.apply(Input::StartCommand { start_segment: 43 }, 5000);
        world.apply(
            Input::Recorder(RecorderEvent::SegmentOpened { session: 1, id: 43 }),
            5200,
        );
        world.apply(Input::StopCommand, 6000);

        assert_eq!(
            world.apply(
                Input::RecordingStopped {
                    session: 1,
                    finalized: Some(clip(43)),
                },
                6100,
            ),
            vec![
                Event::ClipFinalized(clip(43)),
                Event::RecordingStopped {
                    session: 1,
                    at_ms: 6100
                }
            ]
        );
        assert_eq!(world.phase(), RecorderPhase::Idle);
        assert_eq!(world.unpullable_from(), None);
    }

    #[test]
    fn telemetry_emits_only_changed_quantized_values_and_tick_never_mutates() {
        let mut world = World::new(CameraState::Running);
        let mem = MemInfo {
            total: 512_000_123,
            available: 256_999_999,
            swap_total: 134_217_728,
            swap_used: 1,
        };

        let events = world.apply(
            Input::Telemetry {
                storage: Some(DiskUsage {
                    used: 1_000,
                    total: 2_000,
                }),
                temp_c: TempC {
                    soc: Some(51.5),
                    sensor: None,
                },
                mem: Some(mem.clone()),
            },
            1000,
        );

        assert_eq!(events.len(), 3);
        assert!(matches!(events[0], Event::StorageChanged { .. }));
        assert!(matches!(events[1], Event::TempChanged { .. }));
        assert!(matches!(events[2], Event::MemChanged { .. }));
        assert!(world
            .apply(
                Input::Telemetry {
                    storage: Some(DiskUsage {
                        used: 1_000,
                        total: 2_000,
                    }),
                    temp_c: TempC {
                        soc: Some(51.5),
                        sensor: None,
                    },
                    mem: Some(MemInfo {
                        available: 256_999_500,
                        ..mem
                    }),
                },
                1100,
            )
            .is_empty());

        let before = world.clone();
        assert_eq!(
            world.apply(Input::Tick, 1200),
            vec![Event::Heartbeat { t_ms: 1200 }]
        );
        assert_eq!(world, before);
    }

    #[test]
    fn time_sync_flips_once_and_projects_into_snapshot() {
        let mut world = World::new(CameraState::Running);
        assert!(!world.snapshot("boot", 12).time.synced);

        assert_eq!(
            world.apply(Input::TimeSynced, 7000),
            vec![Event::TimeSynced { at_ms: 7000 }]
        );
        assert!(world.snapshot("boot", 12).time.synced);
        assert!(world.apply(Input::TimeSynced, 8000).is_empty());
    }

    #[test]
    fn snapshot_projects_boot_epoch_and_recorder_state() {
        let mut world = World::new(CameraState::Running);
        world.apply(Input::StartCommand { start_segment: 43 }, 5000);
        world.apply(
            Input::Recorder(RecorderEvent::SegmentOpened { session: 1, id: 43 }),
            5200,
        );

        let snapshot = world.snapshot("boot", 12);

        assert_eq!(snapshot.boot_id, "boot");
        assert_eq!(snapshot.boot_tag.as_deref(), None);
        assert_eq!(snapshot.uptime_s, 12);
        assert_eq!(snapshot.recorder.phase, RecorderPhase::Recording);
        assert_eq!(snapshot.recorder.current_segment.as_ref().unwrap().id, 43);

        let tagged_snapshot = world.snapshot("7f3a91c2-b0d4-4e15-b196-20e0416af749", 12);
        assert_eq!(tagged_snapshot.boot_tag.as_deref(), Some("7f3a91c2b0d4"));
    }

    fn clip(id: u32) -> ClipMeta {
        ClipMeta {
            id,
            boot_tag: None,
            start_ms: None,
            dur_ms: None,
            bytes: 7,
            locked: false,
            etag: format!("{id}-7"),
            time_approximate: true,
        }
    }
}
