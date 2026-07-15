use std::{
    path::Path,
    sync::Arc,
    time::{Duration, Instant},
};

use tokio::sync::Semaphore;

use crate::{
    clips::resolve_segment, recorder::SegmentId, storage::StorageCoordinator, sysfacts::DiskUsage,
    DurationCache,
};

const OBSERVATION_DEADLINE: Duration = Duration::from_secs(1);

#[derive(Clone, Debug, Default, PartialEq)]
pub struct FilesystemObservation {
    pub storage: Option<DiskUsage>,
    pub recording_storage_available: bool,
    pub current_segment: Option<ObservedSegment>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ObservedSegment {
    pub id: SegmentId,
    pub dur_ms: Option<u64>,
}

pub trait FilesystemProbe: Send + Sync + 'static {
    fn observe(&self, current_segment: Option<SegmentId>) -> FilesystemObservation;
}

impl<F> FilesystemProbe for F
where
    F: Fn(Option<SegmentId>) -> FilesystemObservation + Send + Sync + 'static,
{
    fn observe(&self, current_segment: Option<SegmentId>) -> FilesystemObservation {
        self(current_segment)
    }
}

#[derive(Clone)]
pub struct FilesystemObserver {
    permit: Arc<Semaphore>,
    probe: Arc<dyn FilesystemProbe>,
    recording_mount_required: bool,
}

impl FilesystemObserver {
    pub fn new(
        storage: Arc<StorageCoordinator>,
        duration_cache: Arc<DurationCache>,
        gc_floor_bytes: u64,
        recording_capacity_override: Option<u64>,
    ) -> Self {
        Self::with_probe_and_mount_requirement(
            DefaultProbe {
                rec_dir: storage.rec_dir(),
                storage: storage.clone(),
                duration_cache,
                gc_floor_bytes,
                recording_capacity_override,
            },
            storage.required_mountpoint().is_some(),
        )
    }

    pub fn with_probe(probe: impl FilesystemProbe) -> Self {
        Self::with_probe_and_mount_requirement(probe, false)
    }

    pub fn with_probe_and_mount_requirement(
        probe: impl FilesystemProbe,
        recording_mount_required: bool,
    ) -> Self {
        Self {
            permit: Arc::new(Semaphore::new(1)),
            probe: Arc::new(probe),
            recording_mount_required,
        }
    }

    pub fn unavailable_observation(&self) -> FilesystemObservation {
        FilesystemObservation {
            storage: None,
            recording_storage_available: !self.recording_mount_required,
            current_segment: None,
        }
    }

    pub async fn observe(
        &self,
        current_segment: Option<SegmentId>,
    ) -> Option<FilesystemObservation> {
        let deadline = Instant::now() + OBSERVATION_DEADLINE;
        let permit = tokio::time::timeout_at(deadline.into(), self.permit.clone().acquire_owned())
            .await
            .ok()?
            .ok()?;
        let probe = self.probe.clone();
        let task = tokio::task::spawn_blocking(move || {
            let _permit = permit;
            probe.observe(current_segment)
        });

        match tokio::time::timeout_at(deadline.into(), task).await {
            Ok(Ok(observation)) => Some(observation),
            Ok(Err(error)) => {
                tracing::error!(%error, "filesystem observation task failed");
                None
            }
            Err(_) => None,
        }
    }
}

struct DefaultProbe {
    rec_dir: Arc<Path>,
    storage: Arc<StorageCoordinator>,
    duration_cache: Arc<DurationCache>,
    gc_floor_bytes: u64,
    recording_capacity_override: Option<u64>,
}

impl FilesystemProbe for DefaultProbe {
    fn observe(&self, current_segment: Option<SegmentId>) -> FilesystemObservation {
        let storage =
            crate::sysfacts::disk_usage(&self.rec_dir, self.gc_floor_bytes).map(|mut storage| {
                if let Some(capacity) = self.recording_capacity_override {
                    storage.recording_capacity_bytes = capacity;
                }
                storage
            });
        let current_segment = current_segment.map(|id| ObservedSegment {
            id,
            dur_ms: self.observe_duration(id),
        });

        FilesystemObservation {
            storage,
            recording_storage_available: self.storage.recording_storage_available().is_ok(),
            current_segment,
        }
    }
}

impl DefaultProbe {
    fn observe_duration(&self, id: SegmentId) -> Option<u64> {
        match resolve_segment(&self.rec_dir, id) {
            Ok(Some(segment)) => self
                .duration_cache
                .duration_ms(id, &segment.path, segment.bytes),
            Ok(None) => None,
            Err(error) => {
                tracing::debug!(%error, id, "skipping current segment duration observation");
                None
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{
        atomic::{AtomicBool, AtomicUsize, Ordering},
        Arc, Condvar, Mutex,
    };

    use super::{FilesystemObservation, FilesystemObserver};
    use crate::sysfacts::DiskUsage;

    #[tokio::test]
    async fn stalled_probe_is_single_flight_and_late_result_is_discarded() {
        let entered = Arc::new(AtomicUsize::new(0));
        let first_finished = Arc::new(AtomicBool::new(false));
        let gate = Arc::new((Mutex::new(false), Condvar::new()));
        let observer = Arc::new(FilesystemObserver::with_probe({
            let entered = entered.clone();
            let first_finished = first_finished.clone();
            let gate = gate.clone();
            move |_| {
                let invocation = entered.fetch_add(1, Ordering::SeqCst) + 1;
                if invocation == 1 {
                    let (lock, ready) = &*gate;
                    let mut released = lock.lock().unwrap();
                    while !*released {
                        let (next, timeout) = ready
                            .wait_timeout(released, Duration::from_secs(5))
                            .unwrap();
                        released = next;
                        if timeout.timed_out() {
                            break;
                        }
                    }
                    first_finished.store(true, Ordering::SeqCst);
                    return observation(1);
                }
                observation(2)
            }
        }));

        let first = tokio::spawn({
            let observer = observer.clone();
            async move { observer.observe(None).await }
        });
        wait_until(|| entered.load(Ordering::SeqCst) == 1).await;

        let followers = (0..4).map(|_| {
            let observer = observer.clone();
            tokio::spawn(async move { observer.observe(None).await })
        });
        let mut follower_results = Vec::new();
        for follower in followers {
            follower_results.push(follower.await.unwrap());
        }
        assert_eq!(first.await.unwrap(), None);
        assert!(follower_results.iter().all(Option::is_none));
        assert_eq!(entered.load(Ordering::SeqCst), 1);

        {
            let (lock, ready) = &*gate;
            *lock.lock().unwrap() = true;
            ready.notify_one();
        }
        wait_until(|| first_finished.load(Ordering::SeqCst)).await;

        let fresh = observer.observe(None).await.unwrap();
        assert_eq!(fresh.storage.unwrap().used, 2);
        assert_eq!(entered.load(Ordering::SeqCst), 2);
    }

    fn observation(used: u64) -> FilesystemObservation {
        FilesystemObservation {
            storage: Some(DiskUsage {
                used,
                total: 10,
                recording_capacity_bytes: 10,
            }),
            recording_storage_available: true,
            current_segment: None,
        }
    }

    async fn wait_until(predicate: impl Fn() -> bool) {
        tokio::time::timeout(Duration::from_secs(1), async {
            while !predicate() {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("condition did not become true");
    }

    use std::time::Duration;
}
