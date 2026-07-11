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

#[derive(Debug)]
pub(crate) enum GcPass {
    AboveFloor,
    ReachedFloor {
        deleted: Vec<SegmentId>,
    },
    BatchCapped {
        deleted: Vec<SegmentId>,
    },
    Exhausted {
        deleted: Vec<SegmentId>,
    },
    ProbeUnavailable {
        deleted: Vec<SegmentId>,
    },
    Failed {
        deleted: Vec<SegmentId>,
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
        return GcPass::ProbeUnavailable { deleted: vec![] };
    };
    if initial_avail >= floor_bytes {
        return GcPass::AboveFloor;
    }

    let mut candidates = match segment_candidates(storage.rec_dir().as_ref()) {
        Ok(candidates) => candidates,
        Err(error) => {
            return GcPass::Failed {
                deleted: vec![],
                error,
            }
        }
    };
    candidates.sort_by_key(|candidate| candidate.seq);
    candidates.retain(|candidate| evictable(candidate, live_floor()));
    if candidates.is_empty() || max_evictions == 0 {
        return GcPass::Exhausted { deleted: vec![] };
    }

    let scan_max = candidates.last().expect("candidates is not empty").seq;
    let prefix_max = candidates[max_evictions.min(candidates.len()) - 1].seq;
    if let Err(error) = storage.raise_witness_for_batch(prefix_max, scan_max) {
        return GcPass::Failed {
            deleted: vec![],
            error,
        };
    }

    let mut deleted = Vec::new();
    for candidate in candidates {
        match storage.delete_finished_segment(candidate.seq, live_floor) {
            Ok(()) => {
                on_removed(candidate.seq);
                deleted.push(candidate.seq);
                match avail() {
                    Some(bytes) if bytes >= floor_bytes => {
                        return GcPass::ReachedFloor { deleted };
                    }
                    None => return GcPass::ProbeUnavailable { deleted },
                    Some(_) if deleted.len() == max_evictions => {
                        return GcPass::BatchCapped { deleted };
                    }
                    Some(_) => {}
                }
            }
            Err(SegmentDeleteError::NotFound) => {}
            Err(SegmentDeleteError::Io(error)) => return GcPass::Failed { deleted, error },
        }
    }
    GcPass::Exhausted { deleted }
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
                    Err(error) => GcPass::Failed {
                        deleted: vec![],
                        error: io::Error::other(format!("gc blocking task failed: {error}")),
                    },
                };
                log_outcome(&outcome);
                if matches!(backoff.record(&outcome, Instant::now()), GcStep::Wait) {
                    break;
                }
            }
        }
    })
}

fn log_outcome(outcome: &GcPass) {
    match outcome {
        GcPass::ReachedFloor { deleted } | GcPass::BatchCapped { deleted }
            if !deleted.is_empty() =>
        {
            tracing::info!(deleted = deleted.len(), "segment gc made progress")
        }
        GcPass::Exhausted { deleted } => tracing::error!(
            deleted = deleted.len(),
            "segment gc below floor with nothing evictable"
        ),
        GcPass::ProbeUnavailable { deleted } => {
            tracing::error!(deleted = deleted.len(), "segment gc disk probe unavailable")
        }
        GcPass::Failed { deleted, error } => {
            tracing::error!(deleted = deleted.len(), %error, "segment gc failed")
        }
        _ => {}
    }
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
        collections::VecDeque,
        fs,
        path::PathBuf,
        pin::Pin,
        sync::atomic::{AtomicUsize, Ordering},
        time::Instant as StdInstant,
    };
    use tokio_stream::Stream;

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
            deleted: vec![],
            error: io::Error::other("test"),
        };
        assert!(matches!(backoff.record(&failed, t0), GcStep::Wait));
        assert!(!backoff.ready(t0));
        assert!(!backoff.ready(t0 + GC_BACKOFF - Duration::from_millis(1)));
        assert!(backoff.ready(t0 + GC_BACKOFF));
        assert!(matches!(
            backoff.record(&GcPass::ReachedFloor { deleted: vec![] }, t0),
            GcStep::Wait
        ));
        assert!(backoff.ready(t0));
        assert!(matches!(
            backoff.record(&GcPass::BatchCapped { deleted: vec![] }, t0),
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
        assert!(matches!(outcome, GcPass::ReachedFloor { ref deleted } if deleted == &[0, 1]));
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
        assert!(matches!(outcome, GcPass::ReachedFloor { ref deleted } if deleted == &[0, 1]));
    }

    #[test]
    fn pass_respects_live_floor_and_reports_exhausted() {
        let dir = TempRecDir::new();
        for id in 0..=3 {
            dir.segment(id);
        }
        let storage = StorageCoordinator::new(dir.0.clone());
        let outcome = run_gc_pass(&storage, 10, 16, &|| Some(0), &|| Some(2), &mut |_| {});
        assert!(matches!(outcome, GcPass::Exhausted { ref deleted } if deleted == &[0, 1]));
        assert!(dir.exists(2));
        assert!(dir.exists(3));
    }

    #[test]
    fn pass_reports_probe_unavailable_after_deletion() {
        let dir = TempRecDir::new();
        dir.segment(0);
        let storage = StorageCoordinator::new(dir.0.clone());
        let probe = scripted([Some(0), None]);
        let outcome = run_gc_pass(&storage, 10, 16, &probe, &|| None, &mut |_| {});
        assert!(matches!(outcome, GcPass::ProbeUnavailable { ref deleted } if deleted == &[0]));
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
