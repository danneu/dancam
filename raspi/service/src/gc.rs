use std::{env, io, path::Path, sync::Arc, time::Duration};

use tokio::{task::JoinHandle, time::Instant};

use crate::{
    backend::Backend,
    clips::{segment_candidates, SegmentCandidate},
    recorder::SegmentId,
    storage::{SegmentDeleteError, StorageCoordinator},
};

pub const DEFAULT_GC_FLOOR_BYTES: u64 = 2 * 1024 * 1024 * 1024;
pub(crate) const MAX_EVICTIONS_PER_BATCH: usize = 16;
pub(crate) const GC_BACKOFF: Duration = Duration::from_secs(30);

#[derive(Debug, PartialEq)]
pub(crate) struct GcObservation {
    floor_bytes: u64,
    avail_before: Option<u64>,
    avail_after: Option<u64>,
    deleted_ids: Vec<SegmentId>,
}

impl GcObservation {
    fn new(
        floor_bytes: u64,
        avail_before: Option<u64>,
        avail_after: Option<u64>,
        deleted_ids: Vec<SegmentId>,
    ) -> Self {
        Self {
            floor_bytes,
            avail_before,
            avail_after,
            deleted_ids,
        }
    }
}

#[derive(Debug)]
pub(crate) enum GcPass {
    AboveFloor,
    ReachedFloor {
        observation: GcObservation,
    },
    BatchCapped {
        observation: GcObservation,
    },
    Exhausted {
        observation: GcObservation,
    },
    ProbeUnavailable {
        observation: GcObservation,
    },
    Failed {
        observation: GcObservation,
        error: io::Error,
    },
}

pub(crate) fn run_gc_pass(
    storage: &StorageCoordinator,
    floor_bytes: u64,
    max_evictions: usize,
    avail: &dyn Fn() -> Option<u64>,
    live_floor: &dyn Fn() -> Option<SegmentId>,
    on_removed: &mut dyn FnMut(SegmentId),
) -> GcPass {
    let Some(initial_avail) = avail() else {
        return GcPass::ProbeUnavailable {
            observation: GcObservation::new(floor_bytes, None, None, vec![]),
        };
    };
    if initial_avail >= floor_bytes {
        return GcPass::AboveFloor;
    }

    let mut candidates = match segment_candidates(storage.rec_dir().as_ref()) {
        Ok(candidates) => candidates,
        Err(error) => {
            return GcPass::Failed {
                observation: GcObservation::new(floor_bytes, Some(initial_avail), None, vec![]),
                error,
            }
        }
    };
    candidates.sort_by_key(|candidate| candidate.seq);
    candidates.retain(|candidate| evictable(candidate, live_floor()));
    if candidates.is_empty() || max_evictions == 0 {
        return GcPass::Exhausted {
            observation: GcObservation::new(floor_bytes, Some(initial_avail), None, vec![]),
        };
    }

    let scan_max = candidates.last().expect("candidates is not empty").seq;
    let prefix_max = candidates[max_evictions.min(candidates.len()) - 1].seq;
    if let Err(error) = storage.raise_witness_for_batch(prefix_max, scan_max) {
        return GcPass::Failed {
            observation: GcObservation::new(floor_bytes, Some(initial_avail), None, vec![]),
            error,
        };
    }

    let mut deleted = Vec::new();
    let mut last_avail = None;
    for candidate in candidates {
        match storage.delete_finished_segment(candidate.seq, live_floor) {
            Ok(()) => {
                on_removed(candidate.seq);
                deleted.push(candidate.seq);
                match avail() {
                    Some(bytes) if bytes >= floor_bytes => {
                        return GcPass::ReachedFloor {
                            observation: GcObservation::new(
                                floor_bytes,
                                Some(initial_avail),
                                Some(bytes),
                                deleted,
                            ),
                        };
                    }
                    None => {
                        return GcPass::ProbeUnavailable {
                            observation: GcObservation::new(
                                floor_bytes,
                                Some(initial_avail),
                                None,
                                deleted,
                            ),
                        }
                    }
                    Some(bytes) if deleted.len() == max_evictions => {
                        return GcPass::BatchCapped {
                            observation: GcObservation::new(
                                floor_bytes,
                                Some(initial_avail),
                                Some(bytes),
                                deleted,
                            ),
                        };
                    }
                    Some(bytes) => last_avail = Some(bytes),
                }
            }
            Err(SegmentDeleteError::NotFound) => {}
            Err(SegmentDeleteError::Io(error)) => {
                return GcPass::Failed {
                    observation: GcObservation::new(
                        floor_bytes,
                        Some(initial_avail),
                        last_avail,
                        deleted,
                    ),
                    error,
                }
            }
        }
    }
    GcPass::Exhausted {
        observation: GcObservation::new(floor_bytes, Some(initial_avail), last_avail, deleted),
    }
}

fn evictable(candidate: &SegmentCandidate, live_floor: Option<SegmentId>) -> bool {
    live_floor.is_none_or(|floor| candidate.seq < floor)
}

pub struct GcConfig {
    pub floor_bytes: u64,
    pub interval: Duration,
    pub probe: Arc<dyn Fn() -> Option<u64> + Send + Sync>,
}

impl GcConfig {
    pub fn from_env(rec_dir: Arc<Path>) -> Self {
        let floor_bytes = parse_floor_bytes(env::var("DANCAM_GC_FLOOR_BYTES").ok().as_deref());
        Self {
            floor_bytes,
            interval: Duration::from_secs(2),
            probe: Arc::new(move || crate::sysfacts::disk_avail(rec_dir.as_ref())),
        }
    }
}

pub(crate) fn parse_floor_bytes(raw: Option<&str>) -> u64 {
    match raw {
        None => DEFAULT_GC_FLOOR_BYTES,
        Some(raw) => raw.parse().unwrap_or_else(|_| {
            tracing::warn!(
                value = raw,
                default = DEFAULT_GC_FLOOR_BYTES,
                "invalid DANCAM_GC_FLOOR_BYTES; using default"
            );
            DEFAULT_GC_FLOOR_BYTES
        }),
    }
}

pub(crate) struct GcBackoff {
    retry_at: Option<Instant>,
}

pub(crate) enum GcStep {
    Continue,
    Wait,
}

impl GcBackoff {
    pub(crate) fn new() -> Self {
        Self { retry_at: None }
    }

    pub(crate) fn ready(&self, now: Instant) -> bool {
        self.retry_at.is_none_or(|retry_at| now >= retry_at)
    }

    pub(crate) fn record(&mut self, outcome: &GcPass, now: Instant) -> GcStep {
        match outcome {
            GcPass::AboveFloor | GcPass::ReachedFloor { .. } => {
                self.retry_at = None;
                GcStep::Wait
            }
            GcPass::BatchCapped { .. } => {
                self.retry_at = None;
                GcStep::Continue
            }
            GcPass::Exhausted { .. } | GcPass::ProbeUnavailable { .. } | GcPass::Failed { .. } => {
                self.retry_at = Some(now + GC_BACKOFF);
                GcStep::Wait
            }
        }
    }
}

pub fn spawn_gc(
    storage: Arc<StorageCoordinator>,
    backend: Arc<dyn Backend>,
    config: GcConfig,
) -> JoinHandle<()> {
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(config.interval);
        let mut backoff = GcBackoff::new();
        loop {
            interval.tick().await;
            if !backoff.ready(Instant::now()) {
                continue;
            }
            loop {
                let storage = storage.clone();
                let backend = backend.clone();
                let probe = config.probe.clone();
                let floor_bytes = config.floor_bytes;
                let result = tokio::task::spawn_blocking(move || {
                    run_gc_pass(
                        storage.as_ref(),
                        floor_bytes,
                        MAX_EVICTIONS_PER_BATCH,
                        probe.as_ref(),
                        &|| backend.unpullable_from(),
                        &mut |id| backend.note_clip_removed(id),
                    )
                })
                .await;
                let outcome = match result {
                    Ok(outcome) => outcome,
                    Err(error) => blocking_failure(floor_bytes, error),
                };
                log_outcome(&outcome);
                if matches!(backoff.record(&outcome, Instant::now()), GcStep::Wait) {
                    break;
                }
            }
        }
    })
}

fn blocking_failure(floor_bytes: u64, error: tokio::task::JoinError) -> GcPass {
    GcPass::Failed {
        observation: GcObservation::new(floor_bytes, None, None, vec![]),
        error: io::Error::other(format!("gc blocking task failed: {error}")),
    }
}

fn log_outcome(outcome: &GcPass) {
    match outcome {
        GcPass::AboveFloor => {}
        GcPass::ReachedFloor { observation } => log_progress("reached_floor", observation),
        GcPass::BatchCapped { observation } => log_progress("batch_capped", observation),
        GcPass::Exhausted { observation } => log_backoff("exhausted", observation),
        GcPass::ProbeUnavailable { observation } => log_backoff("probe_unavailable", observation),
        GcPass::Failed { observation, error } => {
            tracing::error!(
                name: "ring_gc_outcome",
                outcome = "failed",
                deleted_count = observation.deleted_ids.len(),
                deleted_ids = ?observation.deleted_ids,
                avail_before = ?observation.avail_before,
                avail_after = ?observation.avail_after,
                floor_bytes = observation.floor_bytes,
                retry_after_s = GC_BACKOFF.as_secs(),
                %error,
                "ring_gc_outcome"
            );
        }
    }
}

fn log_progress(outcome: &'static str, observation: &GcObservation) {
    tracing::info!(
        name: "ring_gc_outcome",
        outcome,
        deleted_count = observation.deleted_ids.len(),
        deleted_ids = ?observation.deleted_ids,
        avail_before = ?observation.avail_before,
        avail_after = ?observation.avail_after,
        floor_bytes = observation.floor_bytes,
        "ring_gc_outcome"
    );
}

fn log_backoff(outcome: &'static str, observation: &GcObservation) {
    tracing::error!(
        name: "ring_gc_outcome",
        outcome,
        deleted_count = observation.deleted_ids.len(),
        deleted_ids = ?observation.deleted_ids,
        avail_before = ?observation.avail_before,
        avail_after = ?observation.avail_after,
        floor_bytes = observation.floor_bytes,
        retry_after_s = GC_BACKOFF.as_secs(),
        "ring_gc_outcome"
    );
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        backend::{BackendError, FrameStream},
        event_hub::{EventConnection, EventHub},
        events::Snapshot,
        ts_duration::DurationCache,
        world::{CameraState, Input},
    };
    use async_trait::async_trait;
    use bytes::Bytes;
    use std::{
        cell::RefCell,
        collections::{BTreeMap, VecDeque},
        fs,
        path::PathBuf,
        pin::Pin,
        sync::{
            atomic::{AtomicUsize, Ordering},
            Mutex as StdMutex,
        },
        time::Instant as StdInstant,
    };
    use tokio_stream::Stream;
    use tracing::{field::Visit, Subscriber};
    use tracing_subscriber::{
        layer::{Context, SubscriberExt},
        registry::LookupSpan,
        Layer,
    };

    struct TempRecDir(PathBuf);

    impl TempRecDir {
        fn new() -> Self {
            let path = env::temp_dir().join(format!("dancam-gc-{}", uuid::Uuid::new_v4()));
            fs::create_dir(&path).unwrap();
            Self(path)
        }

        fn segment(&self, id: SegmentId) {
            fs::write(
                self.0.join(crate::recorder::segment_filename(id)),
                b"segment",
            )
            .unwrap();
        }

        fn exists(&self, id: SegmentId) -> bool {
            self.0.join(crate::recorder::segment_filename(id)).exists()
        }
    }

    impl Drop for TempRecDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    struct StubBackend {
        hub: Arc<EventHub>,
        durations: Arc<DurationCache>,
    }

    impl StubBackend {
        fn new() -> Self {
            Self {
                hub: Arc::new(EventHub::new(CameraState::Running)),
                durations: Arc::new(DurationCache::new()),
            }
        }
    }

    #[async_trait]
    impl Backend for StubBackend {
        fn preview_frames(&self) -> FrameStream {
            Box::pin(tokio_stream::empty()) as Pin<Box<dyn Stream<Item = Bytes> + Send>>
        }
        async fn start_recording(&self) -> Result<(), BackendError> {
            Ok(())
        }
        async fn stop_recording(&self) -> Result<(), BackendError> {
            Ok(())
        }
        fn snapshot(&self) -> Snapshot {
            self.hub.snapshot()
        }
        fn connect(&self) -> EventConnection {
            self.hub.connect()
        }
        fn unpullable_from(&self) -> Option<SegmentId> {
            self.hub.unpullable_from()
        }
        fn note_clip_removed(&self, id: SegmentId) {
            self.durations.forget(id);
            self.hub.drive_now(Input::ClipRemoved { id });
        }
        fn clip_durations(&self) -> Arc<DurationCache> {
            self.durations.clone()
        }
        fn set_context(&self, boot_id: Arc<str>, started: StdInstant) {
            self.hub.set_context(boot_id, started);
        }
    }

    fn scripted(values: impl IntoIterator<Item = Option<u64>>) -> impl Fn() -> Option<u64> {
        let values = RefCell::new(values.into_iter().collect::<VecDeque<_>>());
        move || values.borrow_mut().pop_front().unwrap_or(Some(0))
    }

    fn observation(outcome: &GcPass) -> &GcObservation {
        match outcome {
            GcPass::AboveFloor => panic!("above-floor pass has no observation"),
            GcPass::ReachedFloor { observation }
            | GcPass::BatchCapped { observation }
            | GcPass::Exhausted { observation }
            | GcPass::ProbeUnavailable { observation }
            | GcPass::Failed { observation, .. } => observation,
        }
    }

    fn assert_observation(
        outcome: &GcPass,
        floor_bytes: u64,
        avail_before: Option<u64>,
        avail_after: Option<u64>,
        deleted_ids: &[SegmentId],
    ) {
        assert_eq!(
            observation(outcome),
            &GcObservation::new(floor_bytes, avail_before, avail_after, deleted_ids.to_vec(),)
        );
    }

    #[test]
    fn parse_floor_values() {
        assert_eq!(parse_floor_bytes(None), DEFAULT_GC_FLOOR_BYTES);
        assert_eq!(parse_floor_bytes(Some("0")), 0);
        assert_eq!(parse_floor_bytes(Some("123")), 123);
        assert_eq!(parse_floor_bytes(Some("garbage")), DEFAULT_GC_FLOOR_BYTES);
    }

    #[tokio::test(start_paused = true)]
    async fn backoff_policy_holds_until_deadline_and_progress_clears_it() {
        let t0 = Instant::now();
        let mut backoff = GcBackoff::new();
        let failed = GcPass::Failed {
            observation: GcObservation::new(10, Some(0), None, vec![]),
            error: io::Error::other("test"),
        };
        assert!(matches!(backoff.record(&failed, t0), GcStep::Wait));
        assert!(!backoff.ready(t0));
        assert!(!backoff.ready(t0 + GC_BACKOFF - Duration::from_millis(1)));
        assert!(backoff.ready(t0 + GC_BACKOFF));
        assert!(matches!(
            backoff.record(
                &GcPass::ReachedFloor {
                    observation: GcObservation::new(10, Some(0), Some(10), vec![0]),
                },
                t0
            ),
            GcStep::Wait
        ));
        assert!(backoff.ready(t0));
        assert!(matches!(
            backoff.record(
                &GcPass::BatchCapped {
                    observation: GcObservation::new(10, Some(0), Some(9), vec![0]),
                },
                t0
            ),
            GcStep::Continue
        ));
    }

    #[test]
    fn pass_is_noop_at_or_above_floor() {
        let dir = TempRecDir::new();
        dir.segment(0);
        let storage = StorageCoordinator::new(dir.0.clone());
        let mut removed = vec![];
        assert!(matches!(
            run_gc_pass(&storage, 10, 16, &|| Some(10), &|| None, &mut |id| removed
                .push(id)),
            GcPass::AboveFloor
        ));
        assert!(dir.exists(0));
        assert!(removed.is_empty());
    }

    #[test]
    fn pass_evicts_oldest_first_and_stops_at_floor() {
        let dir = TempRecDir::new();
        for id in 0..=2 {
            dir.segment(id);
        }
        let storage = StorageCoordinator::new(dir.0.clone());
        let probe = scripted([Some(0), Some(0), Some(10)]);
        let mut removed = vec![];
        let outcome = run_gc_pass(&storage, 10, 16, &probe, &|| None, &mut |id| {
            removed.push(id)
        });
        assert!(matches!(outcome, GcPass::ReachedFloor { .. }));
        assert_observation(&outcome, 10, Some(0), Some(10), &[0, 1]);
        assert_eq!(removed, [0, 1]);
        assert!(!dir.exists(0));
        assert!(!dir.exists(1));
        assert!(dir.exists(2));
    }

    #[test]
    fn pass_cap_th_deletion_reaching_floor_returns_reached_floor() {
        let dir = TempRecDir::new();
        for id in 0..=2 {
            dir.segment(id);
        }
        let storage = StorageCoordinator::new(dir.0.clone());
        let probe = scripted([Some(0), Some(0), Some(10)]);
        let outcome = run_gc_pass(&storage, 10, 2, &probe, &|| None, &mut |_| {});
        assert!(matches!(outcome, GcPass::ReachedFloor { .. }));
        assert_observation(&outcome, 10, Some(0), Some(10), &[0, 1]);
    }

    #[test]
    fn pass_cap_th_deletion_below_floor_returns_batch_capped() {
        let dir = TempRecDir::new();
        for id in 0..=2 {
            dir.segment(id);
        }
        let storage = StorageCoordinator::new(dir.0.clone());
        let probe = scripted([Some(0), Some(4), Some(9)]);
        let outcome = run_gc_pass(&storage, 10, 2, &probe, &|| None, &mut |_| {});
        assert!(matches!(outcome, GcPass::BatchCapped { .. }));
        assert_observation(&outcome, 10, Some(0), Some(9), &[0, 1]);
    }

    #[test]
    fn pass_reports_exhausted_before_delete_without_after_value() {
        let dir = TempRecDir::new();
        dir.segment(0);
        let storage = StorageCoordinator::new(dir.0.clone());
        let outcome = run_gc_pass(&storage, 10, 16, &|| Some(2), &|| Some(0), &mut |_| {});
        assert!(matches!(outcome, GcPass::Exhausted { .. }));
        assert_observation(&outcome, 10, Some(2), None, &[]);
    }

    #[test]
    fn pass_respects_live_floor_and_reports_last_availability_when_exhausted() {
        let dir = TempRecDir::new();
        for id in 0..=3 {
            dir.segment(id);
        }
        let storage = StorageCoordinator::new(dir.0.clone());
        let probe = scripted([Some(0), Some(3), Some(6)]);
        let outcome = run_gc_pass(&storage, 10, 16, &probe, &|| Some(2), &mut |_| {});
        assert!(matches!(outcome, GcPass::Exhausted { .. }));
        assert_observation(&outcome, 10, Some(0), Some(6), &[0, 1]);
        assert!(dir.exists(2));
        assert!(dir.exists(3));
    }

    #[test]
    fn initial_and_post_delete_probe_loss_have_distinct_observations() {
        let empty_dir = TempRecDir::new();
        let empty_storage = StorageCoordinator::new(empty_dir.0.clone());
        let initial = run_gc_pass(&empty_storage, 10, 16, &|| None, &|| None, &mut |_| {});
        assert!(matches!(initial, GcPass::ProbeUnavailable { .. }));
        assert_observation(&initial, 10, None, None, &[]);

        let dir = TempRecDir::new();
        dir.segment(0);
        let storage = StorageCoordinator::new(dir.0.clone());
        let probe = scripted([Some(0), None]);
        let outcome = run_gc_pass(&storage, 10, 16, &probe, &|| None, &mut |_| {});
        assert!(matches!(outcome, GcPass::ProbeUnavailable { .. }));
        assert_observation(&outcome, 10, Some(0), None, &[0]);
    }

    #[test]
    fn scan_and_witness_failures_do_not_invent_after_values_or_deletions() {
        let scan_path = env::temp_dir().join(format!("dancam-gc-file-{}", uuid::Uuid::new_v4()));
        fs::write(&scan_path, b"not a directory").unwrap();
        let scan_storage = StorageCoordinator::new(scan_path.clone());
        let scan = run_gc_pass(&scan_storage, 10, 16, &|| Some(1), &|| None, &mut |_| {});
        assert!(matches!(scan, GcPass::Failed { .. }));
        assert_observation(&scan, 10, Some(1), None, &[]);
        fs::remove_file(scan_path).unwrap();

        let dir = TempRecDir::new();
        dir.segment(0);
        fs::write(dir.0.join("state"), b"blocks witness directory").unwrap();
        let storage = StorageCoordinator::new(dir.0.clone());
        let witness = run_gc_pass(&storage, 10, 16, &|| Some(1), &|| None, &mut |_| {});
        assert!(matches!(witness, GcPass::Failed { .. }));
        assert_observation(&witness, 10, Some(1), None, &[]);
        assert!(dir.exists(0));
    }

    #[test]
    fn in_pass_delete_failure_retains_only_prior_post_delete_probe() {
        let dir = TempRecDir::new();
        dir.segment(0);
        dir.segment(1);
        let storage = StorageCoordinator::new(dir.0.clone());
        let probe = scripted([Some(0), Some(4)]);
        let rec_dir = dir.0.clone();
        let outcome = run_gc_pass(&storage, 10, 16, &probe, &|| None, &mut |_| {
            fs::remove_dir_all(&rec_dir).unwrap();
            fs::write(&rec_dir, b"not a directory").unwrap();
        });
        assert!(matches!(outcome, GcPass::Failed { .. }));
        assert_observation(&outcome, 10, Some(0), Some(4), &[0]);
        fs::remove_file(&dir.0).unwrap();
        fs::create_dir(&dir.0).unwrap();
    }

    #[test]
    fn first_delete_failure_has_no_after_value_or_deleted_ids() {
        let dir = TempRecDir::new();
        dir.segment(0);
        let storage = StorageCoordinator::new(dir.0.clone());
        let rec_dir = dir.0.clone();
        let live_floor_calls = RefCell::new(0);
        let live_floor = || {
            let mut calls = live_floor_calls.borrow_mut();
            *calls += 1;
            if *calls == 2 {
                fs::remove_dir_all(&rec_dir).unwrap();
                fs::write(&rec_dir, b"not a directory").unwrap();
            }
            None
        };
        let outcome = run_gc_pass(&storage, 10, 16, &|| Some(0), &live_floor, &mut |_| {});
        assert!(matches!(outcome, GcPass::Failed { .. }));
        assert_observation(&outcome, 10, Some(0), None, &[]);
        fs::remove_file(&dir.0).unwrap();
        fs::create_dir(&dir.0).unwrap();
    }

    #[tokio::test]
    async fn blocking_failure_has_no_filesystem_observation() {
        let join_error = tokio::spawn(async { panic!("gc test panic") })
            .await
            .unwrap_err();
        let outcome = blocking_failure(10, join_error);
        assert!(matches!(outcome, GcPass::Failed { .. }));
        assert_observation(&outcome, 10, None, None, &[]);
    }

    #[derive(Clone, Debug, Default)]
    struct CapturedFields(BTreeMap<String, String>);

    impl Visit for CapturedFields {
        fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
            self.0
                .insert(field.name().to_string(), format!("{value:?}"));
        }

        fn record_str(&mut self, field: &tracing::field::Field, value: &str) {
            self.0.insert(field.name().to_string(), value.to_string());
        }
    }

    #[derive(Clone, Debug)]
    struct CapturedEvent {
        name: String,
        level: tracing::Level,
        fields: CapturedFields,
    }

    #[derive(Clone)]
    struct CaptureLayer(Arc<StdMutex<Vec<CapturedEvent>>>);

    impl<S> Layer<S> for CaptureLayer
    where
        S: Subscriber + for<'lookup> LookupSpan<'lookup>,
    {
        fn on_event(&self, event: &tracing::Event<'_>, _context: Context<'_, S>) {
            let mut fields = CapturedFields::default();
            event.record(&mut fields);
            self.0.lock().unwrap().push(CapturedEvent {
                name: event.metadata().name().to_string(),
                level: *event.metadata().level(),
                fields,
            });
        }
    }

    #[test]
    fn gc_outcome_logs_are_structured_and_decision_complete() {
        let captured = Arc::new(StdMutex::new(Vec::new()));
        let subscriber = tracing_subscriber::registry().with(CaptureLayer(captured.clone()));
        let cases = [
            GcPass::ReachedFloor {
                observation: GcObservation::new(100, Some(20), Some(100), vec![2, 4]),
            },
            GcPass::BatchCapped {
                observation: GcObservation::new(100, Some(20), Some(80), vec![2, 4]),
            },
            GcPass::Exhausted {
                observation: GcObservation::new(100, Some(20), Some(40), vec![2]),
            },
            GcPass::ProbeUnavailable {
                observation: GcObservation::new(100, Some(20), None, vec![2]),
            },
            GcPass::Failed {
                observation: GcObservation::new(100, Some(20), Some(30), vec![2]),
                error: io::Error::other("test failure"),
            },
        ];
        tracing::subscriber::with_default(subscriber, || {
            for outcome in &cases {
                log_outcome(outcome);
            }
        });

        let events = captured.lock().unwrap();
        assert_eq!(events.len(), 5);
        for (index, expected_outcome) in [
            "reached_floor",
            "batch_capped",
            "exhausted",
            "probe_unavailable",
            "failed",
        ]
        .into_iter()
        .enumerate()
        {
            let event = &events[index];
            assert_eq!(event.name, "ring_gc_outcome");
            assert_eq!(event.fields.0["outcome"], expected_outcome);
            assert_eq!(event.fields.0["floor_bytes"], "100");
            assert_eq!(event.fields.0["avail_before"], "Some(20)");
            assert_eq!(
                event.fields.0["deleted_ids"],
                if index < 2 { "[2, 4]" } else { "[2]" }
            );
            assert_eq!(
                event.fields.0["deleted_count"],
                if index < 2 { "2" } else { "1" }
            );
            if index < 2 {
                assert_eq!(event.level, tracing::Level::INFO);
                assert!(!event.fields.0.contains_key("retry_after_s"));
            } else {
                assert_eq!(event.level, tracing::Level::ERROR);
                assert_eq!(event.fields.0["retry_after_s"], "30");
            }
        }
        assert_eq!(events[0].fields.0["avail_after"], "Some(100)");
        assert_eq!(events[1].fields.0["avail_after"], "Some(80)");
        assert_eq!(events[2].fields.0["avail_after"], "Some(40)");
        assert_eq!(events[3].fields.0["avail_after"], "None");
        assert_eq!(events[4].fields.0["avail_after"], "Some(30)");
        assert_eq!(events[4].fields.0["error"], "test failure");
    }

    #[test]
    fn above_floor_emits_no_gc_outcome_event() {
        let captured = Arc::new(StdMutex::new(Vec::new()));
        let subscriber = tracing_subscriber::registry().with(CaptureLayer(captured.clone()));
        tracing::subscriber::with_default(subscriber, || log_outcome(&GcPass::AboveFloor));
        assert!(captured.lock().unwrap().is_empty());
    }

    #[tokio::test(start_paused = true)]
    async fn gc_worker_panic_arms_backoff_then_retries_after_deadline() {
        let dir = TempRecDir::new();
        let storage = Arc::new(StorageCoordinator::new(dir.0.clone()));
        let backend: Arc<dyn Backend> = Arc::new(StubBackend::new());
        let calls = Arc::new(AtomicUsize::new(0));
        let probe_calls = calls.clone();
        let task = spawn_gc(
            storage,
            backend,
            GcConfig {
                floor_bytes: 10,
                interval: Duration::from_secs(2),
                probe: Arc::new(move || {
                    if probe_calls.fetch_add(1, Ordering::SeqCst) == 0 {
                        panic!("probe panic");
                    }
                    Some(10)
                }),
            },
        );
        for _ in 0..10_000 {
            tokio::task::yield_now().await;
            if calls.load(Ordering::SeqCst) == 1 {
                break;
            }
        }
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        for _ in 0..1_000 {
            tokio::task::yield_now().await;
        }
        tokio::time::advance(GC_BACKOFF - Duration::from_millis(1)).await;
        tokio::task::yield_now().await;
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        tokio::time::advance(Duration::from_millis(1)).await;
        for _ in 0..10_000 {
            tokio::task::yield_now().await;
            if calls.load(Ordering::SeqCst) == 2 {
                break;
            }
        }
        assert_eq!(calls.load(Ordering::SeqCst), 2);
        assert!(!task.is_finished());
        task.abort();
    }

    #[tokio::test(start_paused = true)]
    async fn gc_worker_drains_multiple_capped_batches_in_one_startup_turn() {
        let dir = TempRecDir::new();
        for id in 0..20 {
            dir.segment(id);
        }
        let storage = Arc::new(StorageCoordinator::new(dir.0.clone()));
        let backend: Arc<dyn Backend> = Arc::new(StubBackend::new());
        let path = dir.0.clone();
        let task = spawn_gc(
            storage,
            backend,
            GcConfig {
                floor_bytes: 1,
                interval: Duration::from_secs(60),
                probe: Arc::new(move || {
                    let remaining = segment_candidates(&path).unwrap().len();
                    Some(u64::from(remaining == 0))
                }),
            },
        );
        for _ in 0..1_000_000 {
            tokio::task::yield_now().await;
            if !dir.exists(19) {
                break;
            }
        }
        assert!((0..20).all(|id| !dir.exists(id)));
        task.abort();
    }
}
