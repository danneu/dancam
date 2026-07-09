use std::{
    sync::{Arc, Mutex},
    time::Instant,
};

use tokio::sync::{broadcast, watch};

use crate::{
    events::{Event, Snapshot},
    recorder::{RecorderPhase, SegmentId, SessionId},
    world::{CameraState, Input, LiveStatus, TempC, World},
};

pub const EVENT_CHANNEL_CAPACITY: usize = 256;

#[derive(Clone, Debug, PartialEq)]
pub struct SeqEvent {
    pub seq: u64,
    pub event: Event,
}

pub struct EventConnection {
    pub snapshot: Snapshot,
    pub seq: u64,
    pub rx: broadcast::Receiver<SeqEvent>,
}

#[derive(Debug)]
pub struct EventHub {
    inner: Mutex<Inner>,
    events_tx: broadcast::Sender<SeqEvent>,
    live_tx: watch::Sender<LiveStatus>,
}

#[derive(Debug)]
struct Inner {
    world: World,
    seq: u64,
    boot_id: Arc<str>,
    started: Instant,
}

impl EventHub {
    pub fn new(camera_state: CameraState) -> Self {
        let world = World::new(camera_state);
        let live = world.live_status();
        let (events_tx, _) = broadcast::channel(EVENT_CHANNEL_CAPACITY);
        let (live_tx, _) = watch::channel(live);

        Self {
            inner: Mutex::new(Inner {
                world,
                seq: 0,
                boot_id: Arc::from("unknown"),
                started: Instant::now(),
            }),
            events_tx,
            live_tx,
        }
    }

    pub fn set_context(&self, boot_id: Arc<str>, started: Instant) {
        let mut inner = self.inner.lock().expect("event hub mutex poisoned");
        inner.boot_id = boot_id;
        inner.started = started;
    }

    pub fn drive_now(&self, input: Input) -> Vec<SeqEvent> {
        self.drive(input, self.now_ms())
    }

    pub fn drive(&self, input: Input, now_ms: u64) -> Vec<SeqEvent> {
        let mut inner = self.inner.lock().expect("event hub mutex poisoned");
        let events = inner.world.apply(input, now_ms);
        let mut seq_events = Vec::with_capacity(events.len());
        for event in events {
            inner.seq = inner.seq.saturating_add(1);
            let seq_event = SeqEvent {
                seq: inner.seq,
                event,
            };
            // Heartbeat is pure liveness and fires every tick; state changes are
            // the useful debug trail for what the server emitted.
            if matches!(seq_event.event, Event::Heartbeat { .. }) {
                tracing::trace!(seq = seq_event.seq, event = ?seq_event.event, "emit");
            } else {
                tracing::debug!(seq = seq_event.seq, event = ?seq_event.event, "emit");
            }
            let _ = self.events_tx.send(seq_event.clone());
            seq_events.push(seq_event);
        }
        self.publish_live_status(inner.world.live_status());
        seq_events
    }

    pub fn connect(&self) -> EventConnection {
        let inner = self.inner.lock().expect("event hub mutex poisoned");
        let rx = self.events_tx.subscribe();
        let snapshot = inner.snapshot();
        let seq = inner.seq;
        EventConnection { snapshot, seq, rx }
    }

    pub fn snapshot(&self) -> Snapshot {
        self.inner
            .lock()
            .expect("event hub mutex poisoned")
            .snapshot()
    }

    pub fn live_status(&self) -> LiveStatus {
        self.inner
            .lock()
            .expect("event hub mutex poisoned")
            .world
            .live_status()
    }

    pub fn live_rx(&self) -> watch::Receiver<LiveStatus> {
        self.live_tx.subscribe()
    }

    pub fn phase(&self) -> RecorderPhase {
        self.inner
            .lock()
            .expect("event hub mutex poisoned")
            .world
            .phase()
    }

    pub fn session(&self) -> SessionId {
        self.inner
            .lock()
            .expect("event hub mutex poisoned")
            .world
            .session()
    }

    pub fn current_segment(&self) -> Option<SegmentId> {
        self.inner
            .lock()
            .expect("event hub mutex poisoned")
            .world
            .current_segment()
    }

    pub fn unpullable_from(&self) -> Option<SegmentId> {
        self.inner
            .lock()
            .expect("event hub mutex poisoned")
            .world
            .unpullable_from()
    }

    pub fn update_telemetry(
        &self,
        storage: Option<crate::sysfacts::DiskUsage>,
        temp_c: TempC,
        mem: Option<crate::sysfacts::MemInfo>,
    ) {
        self.drive_now(Input::Telemetry {
            storage,
            temp_c,
            mem,
        });
    }

    pub fn tick(&self) {
        self.drive_now(Input::Tick);
    }

    pub fn now_ms(&self) -> u64 {
        let inner = self.inner.lock().expect("event hub mutex poisoned");
        inner.started.elapsed().as_millis() as u64
    }

    fn publish_live_status(&self, status: LiveStatus) {
        self.live_tx.send_if_modified(|live| {
            if *live == status {
                false
            } else {
                *live = status;
                true
            }
        });
    }
}

impl Inner {
    fn snapshot(&self) -> Snapshot {
        self.world
            .snapshot(&self.boot_id, self.started.elapsed().as_secs())
    }
}

impl Default for EventHub {
    fn default() -> Self {
        Self::new(CameraState::Running)
    }
}

#[cfg(test)]
mod tests {
    use std::{sync::Arc, time::Instant};

    use super::EventHub;
    use crate::{
        events::Event,
        recorder::{RecorderEvent, RecorderPhase},
        sysfacts::DiskUsage,
        world::{CameraState, Input, TempC, STORAGE_QUANTUM},
    };

    #[test]
    fn connect_after_drive_sees_event_in_snapshot_not_receiver() {
        let hub = EventHub::new(CameraState::Running);
        hub.drive(Input::StartCommand { start_segment: 43 }, 1000);
        hub.drive(
            Input::Recorder(RecorderEvent::SegmentOpened { session: 1, id: 43 }),
            1100,
        );

        let mut connection = hub.connect();

        assert_eq!(connection.snapshot.recorder.phase, RecorderPhase::Recording);
        assert_eq!(connection.snapshot.recorder.current_segment.unwrap().id, 43);
        assert_eq!(connection.seq, 2);
        assert!(connection.rx.try_recv().is_err());
    }

    #[test]
    fn connect_before_drive_receives_event_after_snapshot() {
        let hub = EventHub::new(CameraState::Running);
        let mut connection = hub.connect();
        assert_eq!(connection.snapshot.recorder.phase, RecorderPhase::Idle);

        hub.drive(Input::StartCommand { start_segment: 43 }, 1000);
        let event = connection.rx.try_recv().unwrap();

        assert_eq!(event.seq, connection.seq + 1);
        assert!(matches!(event.event, Event::RecordingStarting { .. }));
    }

    #[tokio::test]
    async fn lagged_receiver_reports_gap_so_handler_can_reconnect() {
        let hub = Arc::new(EventHub::new(CameraState::Running));
        let mut connection = hub.connect();

        for ms in 0..(super::EVENT_CHANNEL_CAPACITY + 2) as u64 {
            hub.drive(Input::Tick, ms);
        }

        assert!(matches!(
            connection.rx.recv().await,
            Err(tokio::sync::broadcast::error::RecvError::Lagged(_))
        ));
    }

    #[tokio::test]
    async fn concurrent_connects_fold_to_final_projection_without_duplicate_ids() {
        let hub = Arc::new(EventHub::new(CameraState::Running));
        let mut pre = hub.connect();
        let driver_hub = hub.clone();
        let driver = tokio::spawn(async move {
            for used in 1..=100 {
                driver_hub.drive(
                    Input::Telemetry {
                        storage: Some(DiskUsage {
                            used: used * STORAGE_QUANTUM,
                            total: 100 * STORAGE_QUANTUM,
                        }),
                        temp_c: TempC::empty(),
                        mem: None,
                    },
                    used,
                );
                tokio::task::yield_now().await;
            }
        });

        let mut connections = Vec::new();
        for _ in 0..50 {
            connections.push(hub.connect());
            tokio::task::yield_now().await;
        }
        driver.await.unwrap();

        let mut pre_deltas = 0;
        while let Ok(seq_event) = pre.rx.try_recv() {
            if matches!(seq_event.event, Event::StorageChanged { .. }) {
                pre_deltas += 1;
            }
        }
        assert_eq!(pre_deltas, 100);

        let final_storage = hub.snapshot().storage;
        for mut connection in connections {
            let mut folded_storage = connection.snapshot.storage;
            let snapshot_seq = connection.seq;
            while let Ok(seq_event) = connection.rx.try_recv() {
                assert!(seq_event.seq > snapshot_seq);
                if let Event::StorageChanged { used, total } = seq_event.event {
                    folded_storage = Some(DiskUsage { used, total });
                }
            }
            assert_eq!(folded_storage, final_storage);
        }
    }

    #[test]
    fn set_context_updates_snapshot_boot_epoch() {
        let hub = EventHub::new(CameraState::Running);
        hub.set_context(Arc::from("boot"), Instant::now());

        assert_eq!(hub.snapshot().boot_id, "boot");
    }
}
