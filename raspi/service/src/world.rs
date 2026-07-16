use crate::{
    clips::ClipMeta,
    cpu::Cpu,
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

#[derive(Clone, Copy, Debug, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct RecordingReadiness {
    pub ready: bool,
    pub reason: Option<RecordingReadinessReason>,
}

#[derive(Clone, Copy, Debug, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RecordingReadinessReason {
    CameraStarting,
    CameraRestarting,
    CameraOffline,
    RecordingStorageUnavailable,
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, PartialEq)]
pub struct TempReading {
    pub current: Option<f32>,
    pub max: Option<f32>,
}

impl TempReading {
    pub fn empty() -> Self {
        Self {
            current: None,
            max: None,
        }
    }

    pub fn observe(&mut self, sample: Option<f32>) -> bool {
        let current = sample.map(quantize_temp_value);
        if self.current == current {
            return false;
        }

        self.current = current;
        if let Some(current) = current {
            self.max = Some(self.max.map_or(current, |max| max.max(current)));
        }
        true
    }

    pub fn clear_current(&mut self) -> bool {
        self.current.take().is_some()
    }
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, PartialEq)]
pub struct TempC {
    pub soc: TempReading,
    pub sensor: TempReading,
}

impl TempC {
    pub fn empty() -> Self {
        Self {
            soc: TempReading::empty(),
            sensor: TempReading::empty(),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct World {
    recorder: RecorderState,
    camera_state: CameraState,
    storage: Option<DiskUsage>,
    recording_storage_available: bool,
    temp_c: TempC,
    mem: Option<MemInfo>,
    cpu: Cpu,
    time_synced: bool,
}

impl World {
    pub fn new(camera_state: CameraState) -> Self {
        Self {
            recorder: RecorderState::new(),
            camera_state,
            storage: None,
            recording_storage_available: true,
            temp_c: TempC::empty(),
            mem: None,
            cpu: Cpu::empty(),
            time_synced: false,
        }
    }

    pub fn snapshot(&self, boot_id: &str, uptime_s: u64) -> Snapshot {
        Snapshot {
            recorder: self.recorder.snapshot(),
            camera_state: self.camera_state,
            recording_readiness: self.recording_readiness(),
            boot_id: boot_id.to_string(),
            boot_tag: crate::recorder::boot_tag(boot_id),
            uptime_s,
            storage: self.storage.clone(),
            temp_c: self.temp_c.clone(),
            mem: self.mem.clone(),
            cpu: self.cpu.clone(),
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
            Input::SegmentFinalized { session, finalized } => {
                self.apply_segment_finalized(session, finalized)
            }
            Input::RecoveredClip { finalized } => vec![Event::ClipFinalized(finalized)],
            Input::RecordingArtifactsReconciled => {
                self.recorder.owner_reconciled();
                Vec::new()
            }
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
                    let mut events = vec![Event::CameraStateChanged {
                        state,
                        recording_readiness: self.recording_readiness(),
                    }];
                    if state != CameraState::Running && self.temp_c.sensor.clear_current() {
                        events.push(Event::TempChanged {
                            soc: self.temp_c.soc.clone(),
                            sensor: self.temp_c.sensor.clone(),
                        });
                    }
                    events
                }
            }
            Input::Telemetry {
                storage,
                recording_storage_available,
                soc_temp_c,
                mem,
                cpu,
            } => self.apply_telemetry(storage, recording_storage_available, soc_temp_c, mem, cpu),
            Input::Storage {
                storage,
                recording_storage_available,
            } => self.apply_storage(storage, recording_storage_available),
            Input::SensorTemp { celsius } => self.apply_sensor_temp(celsius),
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

    fn apply_segment_finalized(&mut self, session: SessionId, finalized: ClipMeta) -> Vec<Event> {
        self.recorder
            .apply(RecorderEvent::SegmentClosed {
                session,
                id: finalized.id,
            })
            .then_some(Event::ClipFinalized(finalized))
            .into_iter()
            .collect()
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
        recording_storage_available: bool,
        soc_temp_c: Option<f32>,
        mem: Option<MemInfo>,
        cpu: Cpu,
    ) -> Vec<Event> {
        let mut events = self.apply_storage(storage, recording_storage_available);
        if self.temp_c.soc.observe(soc_temp_c) {
            events.push(Event::TempChanged {
                soc: self.temp_c.soc.clone(),
                sensor: self.temp_c.sensor.clone(),
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

        if self.cpu != cpu {
            self.cpu = cpu.clone();
            events.push(Event::CpuChanged { cores: cpu.cores });
        }

        events
    }

    fn apply_storage(
        &mut self,
        storage: Option<DiskUsage>,
        recording_storage_available: bool,
    ) -> Vec<Event> {
        let storage = storage.map(quantize_storage);
        let prior_readiness = self.recording_readiness();
        self.recording_storage_available = recording_storage_available;
        let readiness = self.recording_readiness();
        if self.storage == storage && prior_readiness == readiness {
            return Vec::new();
        }

        self.storage = storage.clone();
        vec![Event::StorageChanged {
            storage,
            recording_readiness: readiness,
        }]
    }

    fn recording_readiness(&self) -> RecordingReadiness {
        let reason = match self.camera_state {
            CameraState::Starting => Some(RecordingReadinessReason::CameraStarting),
            CameraState::Restarting => Some(RecordingReadinessReason::CameraRestarting),
            CameraState::Offline => Some(RecordingReadinessReason::CameraOffline),
            CameraState::Running if !self.recording_storage_available => {
                Some(RecordingReadinessReason::RecordingStorageUnavailable)
            }
            CameraState::Running => None,
        };
        RecordingReadiness {
            ready: reason.is_none(),
            reason,
        }
    }

    fn apply_sensor_temp(&mut self, celsius: Option<f32>) -> Vec<Event> {
        if self.camera_state != CameraState::Running {
            return Vec::new();
        }

        if !self.temp_c.sensor.observe(celsius) {
            return Vec::new();
        }

        vec![Event::TempChanged {
            soc: self.temp_c.soc.clone(),
            sensor: self.temp_c.sensor.clone(),
        }]
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
    SegmentFinalized {
        session: SessionId,
        finalized: ClipMeta,
    },
    RecoveredClip {
        finalized: ClipMeta,
    },
    RecordingArtifactsReconciled,
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
        recording_storage_available: bool,
        soc_temp_c: Option<f32>,
        mem: Option<MemInfo>,
        cpu: Cpu,
    },
    Storage {
        storage: Option<DiskUsage>,
        recording_storage_available: bool,
    },
    SensorTemp {
        celsius: Option<f32>,
    },
    TimeSynced,
    Tick,
}

pub(crate) const MEM_QUANTUM: u64 = 16 * 1024 * 1024;
pub(crate) const STORAGE_QUANTUM: u64 = 64 * 1024 * 1024;

fn quantize_storage(storage: DiskUsage) -> DiskUsage {
    DiskUsage {
        used: round_down(storage.used, STORAGE_QUANTUM),
        total: round_down(storage.total, STORAGE_QUANTUM),
        recording_capacity_bytes: storage.recording_capacity_bytes,
    }
}

fn quantize_temp_value(value: f32) -> f32 {
    (value * 2.0).round() / 2.0
}

fn quantize_mem(mem: MemInfo) -> MemInfo {
    MemInfo {
        total: round_down(mem.total, MEM_QUANTUM),
        available: round_down(mem.available, MEM_QUANTUM),
        swap_total: round_down(mem.swap_total, MEM_QUANTUM),
        swap_used: round_down(mem.swap_used, MEM_QUANTUM),
    }
}

fn round_down(value: u64, quantum: u64) -> u64 {
    value / quantum * quantum
}

#[cfg(test)]
mod tests {
    use super::{CameraState, Input, TempC, TempReading, World, MEM_QUANTUM, STORAGE_QUANTUM};
    use crate::{
        clips::ClipMeta,
        cpu::Cpu,
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
                session: 44,
                at_ms: 5000
            }]
        );
        assert_eq!(world.phase(), RecorderPhase::Starting);
        assert_eq!(world.unpullable_from(), Some(43));

        assert_eq!(
            world.apply(Input::StopCommand, 6000),
            vec![Event::RecordingStopping {
                session: 44,
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
            Input::Recorder(RecorderEvent::SegmentOpened {
                session: 44,
                id: 43,
            }),
            5200,
        );

        assert_eq!(
            world.apply(Input::CameraState(CameraState::Offline), 9000),
            vec![Event::CameraStateChanged {
                state: CameraState::Offline,
                recording_readiness: super::RecordingReadiness {
                    ready: false,
                    reason: Some(super::RecordingReadinessReason::CameraOffline),
                },
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
                session: 44,
                detail: "camera process exited".to_string(),
                at_ms: 9001
            }]
        );
        assert_eq!(world.phase(), RecorderPhase::Error);
        assert_eq!(world.current_segment(), None);
        assert_eq!(world.unpullable_from(), Some(43));
    }

    #[test]
    fn readiness_is_atomic_and_mount_only_changes_emit_storage_delta() {
        let mut world = World::new(CameraState::Running);
        let storage = Some(sample_storage());
        world.apply(
            Input::Storage {
                storage: storage.clone(),
                recording_storage_available: true,
            },
            1,
        );

        let events = world.apply(
            Input::Storage {
                storage,
                recording_storage_available: false,
            },
            2,
        );
        assert_eq!(events.len(), 1);
        let Event::StorageChanged {
            recording_readiness,
            ..
        } = &events[0]
        else {
            panic!("mount-only transition did not emit storage_changed");
        };
        assert_eq!(
            recording_readiness.reason,
            Some(super::RecordingReadinessReason::RecordingStorageUnavailable)
        );

        let events = world.apply(Input::CameraState(CameraState::Restarting), 3);
        let Event::CameraStateChanged {
            recording_readiness,
            ..
        } = &events[0]
        else {
            panic!("camera transition did not emit camera_state_changed");
        };
        assert_eq!(
            recording_readiness.reason,
            Some(super::RecordingReadinessReason::CameraRestarting)
        );
    }

    #[test]
    fn recorder_error_does_not_block_readiness_when_camera_and_storage_are_ready() {
        let mut world = World::new(CameraState::Running);
        world.apply(Input::StartCommand { start_segment: 1 }, 1);
        world.apply(
            Input::Fail {
                detail: "retryable".to_string(),
            },
            2,
        );

        assert_eq!(world.phase(), RecorderPhase::Error);
        assert!(world.snapshot("boot", 1).recording_readiness.ready);
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
    fn finalization_makes_old_segment_pullable_before_successor_opens() {
        let mut world = World::new(CameraState::Running);
        world.apply(Input::StartCommand { start_segment: 43 }, 5000);
        world.apply(
            Input::Recorder(RecorderEvent::SegmentOpened {
                session: 44,
                id: 43,
            }),
            5200,
        );

        let events = world.apply(
            Input::SegmentFinalized {
                session: 44,
                finalized: clip(43),
            },
            8000,
        );

        assert_eq!(events, vec![Event::ClipFinalized(clip(43))]);
        assert_eq!(world.current_segment(), None);
        assert_eq!(world.unpullable_from(), Some(44));
    }

    #[test]
    fn clip_removed_emits_without_mutating_recorder_state() {
        let mut world = World::new(CameraState::Running);
        world.apply(Input::StartCommand { start_segment: 43 }, 5000);
        world.apply(
            Input::Recorder(RecorderEvent::SegmentOpened {
                session: 44,
                id: 43,
            }),
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
            Input::Recorder(RecorderEvent::SegmentOpened {
                session: 44,
                id: 43,
            }),
            5200,
        );
        world.apply(Input::StopCommand, 6000);

        assert_eq!(
            world.apply(
                Input::RecordingStopped {
                    session: 44,
                    finalized: Some(clip(43)),
                },
                6100,
            ),
            vec![
                Event::ClipFinalized(clip(43)),
                Event::RecordingStopped {
                    session: 44,
                    at_ms: 6100
                }
            ]
        );
        assert_eq!(world.phase(), RecorderPhase::Idle);
        assert_eq!(world.unpullable_from(), None);
    }

    #[test]
    fn telemetry_first_sample_emits_quantized_payloads() {
        let mut world = World::new(CameraState::Running);

        let events = world.apply(
            Input::Telemetry {
                recording_storage_available: true,
                storage: Some(sample_storage()),
                soc_temp_c: Some(sample_soc_temp()),
                mem: Some(sample_mem()),
                cpu: Cpu::empty(),
            },
            1000,
        );

        assert_eq!(
            events,
            vec![
                Event::StorageChanged {
                    storage: Some(DiskUsage {
                        used: 149 * STORAGE_QUANTUM,
                        total: 476 * STORAGE_QUANTUM,
                        recording_capacity_bytes: sample_storage().recording_capacity_bytes,
                    }),
                    recording_readiness: super::RecordingReadiness {
                        ready: true,
                        reason: None,
                    },
                },
                Event::TempChanged {
                    soc: reading(Some(51.5), Some(51.5)),
                    sensor: reading(None, None),
                },
                Event::MemChanged {
                    total: 30 * MEM_QUANTUM,
                    available: 15 * MEM_QUANTUM,
                    swap_total: 8 * MEM_QUANTUM,
                    swap_used: 0,
                },
            ]
        );

        let snapshot = world.snapshot("boot", 12);
        assert_eq!(
            snapshot.storage,
            Some(DiskUsage {
                used: 149 * STORAGE_QUANTUM,
                total: 476 * STORAGE_QUANTUM,
                recording_capacity_bytes: sample_storage().recording_capacity_bytes,
            })
        );
        assert_eq!(
            snapshot.temp_c,
            TempC {
                soc: reading(Some(51.5), Some(51.5)),
                sensor: reading(None, None),
            }
        );
        assert_eq!(
            snapshot.mem,
            Some(MemInfo {
                total: 30 * MEM_QUANTUM,
                available: 15 * MEM_QUANTUM,
                swap_total: 8 * MEM_QUANTUM,
                swap_used: 0,
            })
        );
    }

    #[test]
    fn telemetry_probe_failure_clears_storage_and_emits_null_replacement() {
        let mut world = World::new(CameraState::Running);
        world.apply(
            Input::Telemetry {
                recording_storage_available: true,
                storage: Some(sample_storage()),
                soc_temp_c: None,
                mem: None,
                cpu: Cpu::empty(),
            },
            1000,
        );

        assert_eq!(
            world.apply(
                Input::Telemetry {
                    recording_storage_available: true,
                    storage: None,
                    soc_temp_c: None,
                    mem: None,
                    cpu: Cpu::empty(),
                },
                1100,
            ),
            vec![Event::StorageChanged {
                storage: None,
                recording_readiness: super::RecordingReadiness {
                    ready: true,
                    reason: None,
                },
            }]
        );
        assert_eq!(world.snapshot("boot", 1).storage, None);
    }

    #[test]
    fn telemetry_sub_quantum_jitter_emits_nothing() {
        let mut world = World::new(CameraState::Running);
        world.apply(
            Input::Telemetry {
                recording_storage_available: true,
                storage: Some(sample_storage()),
                soc_temp_c: Some(sample_soc_temp()),
                mem: Some(sample_mem()),
                cpu: Cpu::empty(),
            },
            1000,
        );

        assert!(world
            .apply(
                Input::Telemetry {
                    recording_storage_available: true,
                    storage: Some(DiskUsage {
                        used: 149 * STORAGE_QUANTUM + 60_012_345,
                        total: 476 * STORAGE_QUANTUM + 1,
                        recording_capacity_bytes: sample_storage().recording_capacity_bytes,
                    }),
                    soc_temp_c: Some(51.7),
                    mem: Some(MemInfo {
                        available: 256_999_500,
                        ..sample_mem()
                    }),
                    cpu: Cpu::empty(),
                },
                1100,
            )
            .is_empty());
    }

    #[test]
    fn cpu_replaces_full_slice_only_when_reported_value_changes() {
        let mut world = World::new(CameraState::Running);
        let baseline = Cpu {
            cores: vec![crate::cpu::CpuCore {
                id: 2,
                current_pct: None,
                one_minute_pct: None,
                five_minute_pct: None,
                fifteen_minute_pct: None,
            }],
        };
        let input = |cpu| Input::Telemetry {
            recording_storage_available: true,
            storage: None,
            soc_temp_c: None,
            mem: None,
            cpu,
        };
        assert_eq!(
            world.apply(input(baseline.clone()), 1),
            vec![Event::CpuChanged {
                cores: baseline.cores.clone()
            }]
        );
        assert!(world.apply(input(baseline.clone()), 2).is_empty());
        assert_eq!(world.snapshot("boot", 1).cpu, baseline);
        let populated = Cpu {
            cores: vec![crate::cpu::CpuCore {
                id: 2,
                current_pct: Some(50),
                one_minute_pct: Some(50),
                five_minute_pct: Some(50),
                fifteen_minute_pct: Some(50),
            }],
        };
        assert_eq!(
            world.apply(input(populated.clone()), 3),
            vec![Event::CpuChanged {
                cores: populated.cores.clone()
            }]
        );
        assert_eq!(
            world.apply(input(Cpu::empty()), 4),
            vec![Event::CpuChanged { cores: vec![] }]
        );
        assert_eq!(world.snapshot("boot", 1).cpu, Cpu::empty());
    }

    #[test]
    fn telemetry_bucket_crossings_emit_quantized_values() {
        let mut world = World::new(CameraState::Running);
        world.apply(
            Input::Telemetry {
                recording_storage_available: true,
                storage: Some(sample_storage()),
                soc_temp_c: Some(sample_soc_temp()),
                mem: Some(sample_mem()),
                cpu: Cpu::empty(),
            },
            1000,
        );

        assert_eq!(
            world.apply(
                Input::Telemetry {
                    recording_storage_available: true,
                    storage: Some(DiskUsage {
                        used: 152 * STORAGE_QUANTUM + 7,
                        total: 476 * STORAGE_QUANTUM + 1,
                        recording_capacity_bytes: sample_storage().recording_capacity_bytes,
                    }),
                    soc_temp_c: Some(51.8),
                    mem: Some(MemInfo {
                        available: 17 * MEM_QUANTUM + 9,
                        ..sample_mem()
                    }),
                    cpu: Cpu::empty(),
                },
                1100,
            ),
            vec![
                Event::StorageChanged {
                    storage: Some(DiskUsage {
                        used: 152 * STORAGE_QUANTUM,
                        total: 476 * STORAGE_QUANTUM,
                        recording_capacity_bytes: sample_storage().recording_capacity_bytes,
                    }),
                    recording_readiness: super::RecordingReadiness {
                        ready: true,
                        reason: None,
                    },
                },
                Event::TempChanged {
                    soc: reading(Some(52.0), Some(52.0)),
                    sensor: reading(None, None),
                },
                Event::MemChanged {
                    total: 30 * MEM_QUANTUM,
                    available: 17 * MEM_QUANTUM,
                    swap_total: 8 * MEM_QUANTUM,
                    swap_used: 0,
                },
            ]
        );
    }

    #[test]
    fn soc_max_rises_and_survives_a_current_drop() {
        let mut world = World::new(CameraState::Running);
        for current in [51.5, 62.0] {
            world.apply(
                Input::Telemetry {
                    recording_storage_available: true,
                    storage: None,
                    soc_temp_c: Some(current),
                    mem: None,
                    cpu: Cpu::empty(),
                },
                1000,
            );
        }

        assert_eq!(
            world.apply(
                Input::Telemetry {
                    recording_storage_available: true,
                    storage: None,
                    soc_temp_c: Some(51.5),
                    mem: None,
                    cpu: Cpu::empty(),
                },
                1100,
            ),
            vec![Event::TempChanged {
                soc: reading(Some(51.5), Some(62.0)),
                sensor: reading(None, None),
            }]
        );
        assert_eq!(
            world.snapshot("boot", 12).temp_c.soc,
            reading(Some(51.5), Some(62.0))
        );
    }

    #[test]
    fn first_sensor_sample_emits_and_projects_into_snapshot() {
        let mut world = World::new(CameraState::Running);

        assert_eq!(
            world.apply(
                Input::SensorTemp {
                    celsius: Some(40.3),
                },
                1000,
            ),
            vec![Event::TempChanged {
                soc: reading(None, None),
                sensor: reading(Some(40.5), Some(40.5)),
            }]
        );
        assert_eq!(
            world.snapshot("boot", 12).temp_c.sensor,
            reading(Some(40.5), Some(40.5))
        );
    }

    #[test]
    fn sensor_sub_quantum_jitter_emits_nothing() {
        let mut world = World::new(CameraState::Running);
        world.apply(
            Input::SensorTemp {
                celsius: Some(40.3),
            },
            1000,
        );

        assert!(world
            .apply(
                Input::SensorTemp {
                    celsius: Some(40.4),
                },
                1100,
            )
            .is_empty());
    }

    #[test]
    fn sensor_bucket_crossing_emits_merged_pair_with_soc_preserved() {
        let mut world = World::new(CameraState::Running);
        world.apply(
            Input::Telemetry {
                recording_storage_available: true,
                storage: None,
                soc_temp_c: Some(51.5),
                mem: None,
                cpu: Cpu::empty(),
            },
            1000,
        );
        world.apply(
            Input::SensorTemp {
                celsius: Some(40.3),
            },
            1001,
        );

        assert_eq!(
            world.apply(
                Input::SensorTemp {
                    celsius: Some(40.8),
                },
                1100,
            ),
            vec![Event::TempChanged {
                soc: reading(Some(51.5), Some(51.5)),
                sensor: reading(Some(41.0), Some(41.0)),
            }]
        );
    }

    #[test]
    fn null_sensor_sample_clears_value() {
        let mut world = World::new(CameraState::Running);
        world.apply(
            Input::SensorTemp {
                celsius: Some(43.5),
            },
            1000,
        );

        assert_eq!(
            world.apply(Input::SensorTemp { celsius: None }, 1100),
            vec![Event::TempChanged {
                soc: reading(None, None),
                sensor: reading(None, Some(43.5)),
            }]
        );
    }

    #[test]
    fn sensor_sample_while_camera_is_not_running_is_ignored() {
        let mut world = World::new(CameraState::Starting);

        assert!(world
            .apply(
                Input::SensorTemp {
                    celsius: Some(40.3),
                },
                1000,
            )
            .is_empty());
        assert_eq!(
            world.snapshot("boot", 12).temp_c.sensor,
            reading(None, None)
        );
    }

    #[test]
    fn camera_leaving_running_clears_sensor_after_state_event() {
        let mut world = World::new(CameraState::Running);
        world.apply(
            Input::SensorTemp {
                celsius: Some(40.3),
            },
            1000,
        );

        assert_eq!(
            world.apply(Input::CameraState(CameraState::Restarting), 1100),
            vec![
                Event::CameraStateChanged {
                    state: CameraState::Restarting,
                    recording_readiness: super::RecordingReadiness {
                        ready: false,
                        reason: Some(super::RecordingReadinessReason::CameraRestarting),
                    },
                },
                Event::TempChanged {
                    soc: reading(None, None),
                    sensor: reading(None, Some(40.5)),
                },
            ]
        );
        assert_eq!(
            world.snapshot("boot", 12).temp_c.sensor,
            reading(None, Some(40.5))
        );
    }

    #[test]
    fn sensor_max_survives_camera_restart_and_resumed_samples() {
        let mut world = World::new(CameraState::Running);
        world.apply(
            Input::SensorTemp {
                celsius: Some(43.5),
            },
            1000,
        );
        world.apply(Input::CameraState(CameraState::Restarting), 1100);
        world.apply(Input::CameraState(CameraState::Running), 1200);

        assert_eq!(
            world.apply(
                Input::SensorTemp {
                    celsius: Some(41.0),
                },
                1300,
            ),
            vec![Event::TempChanged {
                soc: reading(None, None),
                sensor: reading(Some(41.0), Some(43.5)),
            }]
        );
        assert_eq!(
            world.apply(
                Input::SensorTemp {
                    celsius: Some(44.0),
                },
                1400,
            ),
            vec![Event::TempChanged {
                soc: reading(None, None),
                sensor: reading(Some(44.0), Some(44.0)),
            }]
        );
    }

    #[test]
    fn camera_state_change_without_sensor_emits_no_temp_event() {
        let mut world = World::new(CameraState::Running);

        assert_eq!(
            world.apply(Input::CameraState(CameraState::Restarting), 1100),
            vec![Event::CameraStateChanged {
                state: CameraState::Restarting,
                recording_readiness: super::RecordingReadiness {
                    ready: false,
                    reason: Some(super::RecordingReadinessReason::CameraRestarting),
                },
            }]
        );
    }

    #[test]
    fn tick_emits_heartbeat_and_never_mutates() {
        let mut world = World::new(CameraState::Running);
        world.apply(
            Input::Telemetry {
                recording_storage_available: true,
                storage: Some(sample_storage()),
                soc_temp_c: Some(sample_soc_temp()),
                mem: Some(sample_mem()),
                cpu: Cpu::empty(),
            },
            1000,
        );

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
            Input::Recorder(RecorderEvent::SegmentOpened {
                session: 44,
                id: 43,
            }),
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
            session: None,
            start_ms: None,
            dur_ms: None,
            bytes: 7,
            locked: false,
            etag: format!("{id}-7"),
            time_approximate: true,
        }
    }

    fn reading(current: Option<f32>, max: Option<f32>) -> TempReading {
        TempReading { current, max }
    }

    fn sample_storage() -> DiskUsage {
        DiskUsage {
            used: 149 * STORAGE_QUANTUM + 12_345,
            total: 476 * STORAGE_QUANTUM + 1,
            recording_capacity_bytes: 400 * STORAGE_QUANTUM + 123,
        }
    }

    fn sample_soc_temp() -> f32 {
        51.5
    }

    fn sample_mem() -> MemInfo {
        MemInfo {
            total: 512_000_123,
            available: 256_999_999,
            swap_total: 134_217_728,
            swap_used: 1,
        }
    }
}
