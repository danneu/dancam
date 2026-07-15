use std::{
    fs,
    path::PathBuf,
    pin::Pin,
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc, Condvar, Mutex,
    },
    time::{Duration, Instant},
};

use async_trait::async_trait;
use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use bytes::Bytes;
use http_body_util::BodyExt;
use serde_json::Value;
use tokio_stream::Stream;
use tower::ServiceExt;

use dancam::{
    backend::{Backend, BackendError, FrameStream},
    event_hub::{EventConnection, EventHub},
    events::Snapshot,
    filesystem_observer::{FilesystemObservation, FilesystemObserver, ObservedSegment},
    recorder::{stamped_segment_filename, RecorderEvent, SegmentFacts, SegmentId},
    storage::StorageCoordinator,
    world::{CameraState, Input},
    AppState, DurationCache,
};

const BOOT_ID: &str = "3f1c0e7a-8f3b-4e15-b196-20e0416af749";

#[derive(Clone)]
struct StubBackend {
    hub: Arc<EventHub>,
    telemetry_updates: Arc<AtomicUsize>,
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

    fn note_clip_removed(&self, _id: SegmentId) {}

    fn clip_durations(&self) -> Arc<DurationCache> {
        Arc::new(DurationCache::default())
    }

    fn set_context(&self, boot_id: Arc<str>, started: Instant) {
        self.hub.set_context(boot_id, started);
    }

    fn update_telemetry(
        &self,
        storage: Option<dancam::sysfacts::DiskUsage>,
        recording_storage_available: bool,
        soc_temp_c: Option<f32>,
        mem: Option<dancam::sysfacts::MemInfo>,
        cpu: dancam::cpu::Cpu,
    ) {
        self.telemetry_updates.fetch_add(1, Ordering::SeqCst);
        self.hub
            .update_telemetry(storage, recording_storage_available, soc_temp_c, mem, cpu);
    }

    fn update_storage(
        &self,
        storage: Option<dancam::sysfacts::DiskUsage>,
        recording_storage_available: bool,
    ) {
        self.hub
            .update_storage(storage, recording_storage_available);
    }
}

fn state(rec_dir: PathBuf, backend: StubBackend) -> AppState {
    AppState::new(BOOT_ID.to_string(), backend)
        .with_storage(Arc::new(StorageCoordinator::new(rec_dir)))
}

#[tokio::test]
async fn status_returns_snapshot_wire_contract() {
    let rec_dir = TempRecDir::new();
    let response = dancam::app(state(rec_dir.path.clone(), StubBackend::idle()))
        .oneshot(status_request())
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        response
            .headers()
            .get("x-dancam-proto")
            .and_then(|value| value.to_str().ok()),
        Some("1")
    );
    assert_eq!(
        response
            .headers()
            .get("x-dancam-boot-id")
            .and_then(|value| value.to_str().ok()),
        Some(BOOT_ID)
    );

    let body = response.into_body().collect().await.unwrap().to_bytes();
    let json: Value = serde_json::from_slice(&body).unwrap();

    assert_eq!(json["recorder"]["phase"], "idle");
    assert_eq!(json["recorder"]["session"], 0);
    assert_eq!(json["recorder"]["current_segment"], Value::Null);
    assert_eq!(json["recorder"]["detail"], Value::Null);
    assert_eq!(json["camera_state"], "running");
    assert_eq!(json["recording_readiness"]["ready"], true);
    assert_eq!(json["recording_readiness"]["reason"], Value::Null);
    assert_eq!(json["boot_id"], BOOT_ID);
    assert!(json["uptime_s"].as_u64().is_some());
    assert!(json["storage"].is_object() || json["storage"].is_null());
    assert!(
        json["temp_c"]["soc"]["current"].is_number() || json["temp_c"]["soc"]["current"].is_null()
    );
    assert!(json["temp_c"]["soc"]["max"].is_number() || json["temp_c"]["soc"]["max"].is_null());
    assert!(
        json["temp_c"]["sensor"]["current"].is_number()
            || json["temp_c"]["sensor"]["current"].is_null()
    );
    assert!(
        json["temp_c"]["sensor"]["max"].is_number() || json["temp_c"]["sensor"]["max"].is_null()
    );
    assert!(json["mem"].is_object() || json["mem"].is_null());
    assert!(json["cpu"]["cores"].is_array());
    assert_eq!(json["time"]["synced"], false);
}

#[tokio::test]
async fn status_equals_first_events_snapshot_without_type_discriminator() {
    let rec_dir = TempRecDir::new();
    let app = dancam::app(state(rec_dir.path.clone(), StubBackend::idle()));
    let status = response_json(app.clone().oneshot(status_request()).await.unwrap()).await;
    let mut event = first_sse_json(app.oneshot(events_request()).await.unwrap()).await;
    event.as_object_mut().unwrap().remove("type");
    assert_eq!(status, event);
}

#[tokio::test]
async fn status_reports_each_camera_readiness_reason_with_camera_precedence() {
    for (camera_state, reason) in [
        (CameraState::Starting, "camera_starting"),
        (CameraState::Restarting, "camera_restarting"),
        (CameraState::Offline, "camera_offline"),
    ] {
        let rec_dir = TempRecDir::new();
        let backend = StubBackend::camera(camera_state);
        backend.hub.update_storage(None, false);
        let json = response_json(
            dancam::app(state(rec_dir.path.clone(), backend))
                .oneshot(status_request())
                .await
                .unwrap(),
        )
        .await;
        assert_eq!(json["recording_readiness"]["ready"], false);
        assert_eq!(json["recording_readiness"]["reason"], reason);
    }
}

#[tokio::test]
async fn configured_plain_directory_mount_fails_readiness_without_failing_status() {
    let rec_dir = TempRecDir::new();
    let storage = Arc::new(
        StorageCoordinator::new(rec_dir.path.join("rec"))
            .with_required_mountpoint(rec_dir.path.clone()),
    );
    fs::create_dir(storage.rec_dir()).unwrap();
    let app_state = AppState::new(BOOT_ID.to_string(), StubBackend::idle()).with_storage(storage);

    let response = dancam::app(app_state)
        .oneshot(status_request())
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    let json = response_json(response).await;
    assert_eq!(json["recording_readiness"]["ready"], false);
    assert_eq!(
        json["recording_readiness"]["reason"],
        "recording_storage_unavailable"
    );
}

#[tokio::test]
async fn startup_seed_applies_mount_witness_before_serving() {
    for available in [true, false] {
        let rec_dir = TempRecDir::new();
        let backend = StubBackend::idle();
        let observer = Arc::new(FilesystemObserver::with_probe_and_mount_requirement(
            move |_| FilesystemObservation {
                storage: None,
                recording_storage_available: available,
                current_segment: None,
            },
            true,
        ));
        let state = state(rec_dir.path.clone(), backend.clone()).with_filesystem_observer(observer);

        dancam::events::seed_filesystem_observation(&state).await;

        assert_eq!(backend.snapshot().recording_readiness.ready, available);
    }
}

#[tokio::test]
async fn startup_seed_timeout_continues_failed_closed() {
    let rec_dir = TempRecDir::new();
    let backend = StubBackend::idle();
    let observer = Arc::new(FilesystemObserver::with_probe_and_mount_requirement(
        |_| {
            std::thread::sleep(Duration::from_millis(1_200));
            FilesystemObservation {
                storage: Some(disk_usage(1)),
                recording_storage_available: true,
                current_segment: None,
            }
        },
        true,
    ));
    let state = state(rec_dir.path.clone(), backend.clone()).with_filesystem_observer(observer);

    let started = Instant::now();
    dancam::events::seed_filesystem_observation(&state).await;

    assert!(started.elapsed() < Duration::from_millis(1_100));
    assert!(!backend.snapshot().recording_readiness.ready);
    assert_eq!(backend.snapshot().storage, None);
}

#[tokio::test]
async fn status_reports_null_current_segment_while_starting() {
    let rec_dir = TempRecDir::new();
    rec_dir.write("seg_00042.ts", b"finished");

    let response = dancam::app(state(rec_dir.path.clone(), StubBackend::starting_at(43)))
        .oneshot(status_request())
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let body = response.into_body().collect().await.unwrap().to_bytes();
    let json: Value = serde_json::from_slice(&body).unwrap();

    assert_eq!(json["recorder"]["phase"], "starting");
    assert_eq!(json["recorder"]["current_segment"], Value::Null);
}

#[tokio::test]
async fn status_reports_fsm_owned_open_segment_metadata_while_recording() {
    let rec_dir = TempRecDir::new();
    let fixture = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("assets/clips/seg_00000.ts");
    fs::copy(fixture, rec_dir.path.join(stamped_name(0))).unwrap();

    let response = dancam::app(state(
        rec_dir.path.clone(),
        StubBackend::recording_segment(0),
    ))
    .oneshot(status_request())
    .await
    .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let body = response.into_body().collect().await.unwrap().to_bytes();
    let json: Value = serde_json::from_slice(&body).unwrap();

    assert_eq!(json["recorder"]["phase"], "recording");
    assert_eq!(json["recorder"]["current_segment"]["id"], 0);
    let dur_ms = json["recorder"]["current_segment"]["dur_ms"]
        .as_u64()
        .unwrap();
    assert!(
        (dur_ms as i64 - 30_000).abs() <= 100,
        "duration was {dur_ms} ms"
    );
}

#[tokio::test]
async fn stalled_observation_bounds_status_events_and_telemetry_without_fanout() {
    let rec_dir = TempRecDir::new();
    let backend = StubBackend::recording_segment(0);
    backend
        .hub
        .update_storage(Some(disk_usage(64 * 1024 * 1024)), true);

    let entered = Arc::new(AtomicUsize::new(0));
    let gate = Arc::new((Mutex::new(false), Condvar::new()));
    let observer = Arc::new(FilesystemObserver::with_probe_and_mount_requirement(
        {
            let entered = entered.clone();
            let gate = gate.clone();
            move |current_segment| {
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
                    return filesystem_observation(current_segment, 1, 111);
                }
                filesystem_observation(current_segment, 128 * 1024 * 1024, 222)
            }
        },
        true,
    ));
    let state =
        state(rec_dir.path.clone(), backend.clone()).with_filesystem_observer(observer.clone());
    dancam::events::spawn_telemetry(state.backend.clone(), observer, Duration::from_millis(25));
    let app = dancam::app(state);

    let started = Instant::now();
    let status = tokio::spawn(app.clone().oneshot(status_request()));
    wait_until(|| entered.load(Ordering::SeqCst) == 1).await;
    let repeated_status = app.clone().oneshot(status_request());
    let events = app.clone().oneshot(events_request());
    let (status, repeated_status, events) = tokio::join!(status, repeated_status, events);
    assert!(started.elapsed() < Duration::from_millis(1400));
    assert_eq!(entered.load(Ordering::SeqCst), 1);

    for response in [status.unwrap().unwrap(), repeated_status.unwrap()] {
        let json = response_json(response).await;
        assert_eq!(json["storage"], Value::Null);
        assert_eq!(json["recording_readiness"]["ready"], false);
        assert_eq!(
            json["recording_readiness"]["reason"],
            "recording_storage_unavailable"
        );
        assert_eq!(json["recorder"]["current_segment"]["dur_ms"], Value::Null);
    }
    let event_json = first_sse_json(events.unwrap()).await;
    assert_eq!(event_json["type"], "snapshot");
    assert_eq!(event_json["storage"], Value::Null);
    assert_eq!(event_json["recording_readiness"]["ready"], false);
    assert_eq!(
        event_json["recorder"]["current_segment"]["dur_ms"],
        Value::Null
    );
    wait_until(|| backend.telemetry_updates.load(Ordering::SeqCst) > 0).await;

    {
        let (lock, ready) = &*gate;
        *lock.lock().unwrap() = true;
        ready.notify_one();
    }
    wait_until(|| entered.load(Ordering::SeqCst) >= 2).await;

    let restored = response_json(app.clone().oneshot(status_request()).await.unwrap()).await;
    assert_eq!(restored["storage"]["used"], 128 * 1024 * 1024);
    assert_eq!(restored["recording_readiness"]["ready"], true);
    assert_eq!(restored["recorder"]["current_segment"]["dur_ms"], 222);

    let restored_event = first_sse_json(app.oneshot(events_request()).await.unwrap()).await;
    assert_eq!(restored_event["storage"]["used"], 128 * 1024 * 1024);
    assert_eq!(restored_event["recording_readiness"]["ready"], true);
    assert_eq!(restored_event["recorder"]["current_segment"]["dur_ms"], 222);
}

#[tokio::test]
async fn stalled_telemetry_clears_stale_storage_then_a_fresh_probe_restores_it() {
    let rec_dir = TempRecDir::new();
    let backend = StubBackend::idle();
    backend
        .hub
        .update_storage(Some(disk_usage(64 * 1024 * 1024)), true);
    let entered = Arc::new(AtomicUsize::new(0));
    let gate = Arc::new((Mutex::new(false), Condvar::new()));
    let observer = Arc::new(FilesystemObserver::with_probe({
        let entered = entered.clone();
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
                return filesystem_observation(None, 1, 0);
            }
            filesystem_observation(None, 128 * 1024 * 1024, 0)
        }
    }));
    let state =
        state(rec_dir.path.clone(), backend.clone()).with_filesystem_observer(observer.clone());

    let started = Instant::now();
    dancam::events::spawn_telemetry(state.backend.clone(), observer, Duration::from_millis(25));
    wait_until(|| entered.load(Ordering::SeqCst) == 1).await;
    wait_until(|| backend.telemetry_updates.load(Ordering::SeqCst) > 0).await;
    assert!(started.elapsed() < Duration::from_millis(1400));
    assert_eq!(backend.snapshot().storage, None);
    assert!(backend.snapshot().recording_readiness.ready);
    assert_eq!(entered.load(Ordering::SeqCst), 1);

    {
        let (lock, ready) = &*gate;
        *lock.lock().unwrap() = true;
        ready.notify_one();
    }
    wait_until(|| {
        backend
            .snapshot()
            .storage
            .is_some_and(|storage| storage.used == 128 * 1024 * 1024)
    })
    .await;
}

fn disk_usage(used: u64) -> dancam::sysfacts::DiskUsage {
    dancam::sysfacts::DiskUsage {
        used,
        total: 512 * 1024 * 1024,
        recording_capacity_bytes: 448 * 1024 * 1024,
    }
}

fn filesystem_observation(
    current_segment: Option<SegmentId>,
    used: u64,
    dur_ms: u64,
) -> FilesystemObservation {
    FilesystemObservation {
        storage: Some(disk_usage(used)),
        recording_storage_available: true,
        current_segment: current_segment.map(|id| ObservedSegment {
            id,
            dur_ms: Some(dur_ms),
        }),
    }
}

async fn response_json(response: axum::response::Response) -> Value {
    let body = response.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&body).unwrap()
}

async fn first_sse_json(response: axum::response::Response) -> Value {
    let mut body = response.into_body();
    let frame = tokio::time::timeout(Duration::from_secs(1), body.frame())
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    let data = frame.into_data().unwrap();
    let text = std::str::from_utf8(&data).unwrap();
    let data = text
        .lines()
        .find_map(|line| line.strip_prefix("data:").map(str::trim_start))
        .expect("SSE frame omitted data");
    serde_json::from_str(data).unwrap()
}

async fn wait_until(predicate: impl Fn() -> bool) {
    tokio::time::timeout(Duration::from_secs(2), async {
        while !predicate() {
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("condition did not become true");
}

fn stamped_name(seq: u32) -> String {
    stamped_segment_filename(
        seq,
        &SegmentFacts {
            boot_tag: "abc123def456".to_string(),
            session: 1,
            mono_ms: 123456789,
        },
    )
}

impl StubBackend {
    fn camera(state: CameraState) -> Self {
        Self {
            hub: Arc::new(EventHub::new(state)),
            telemetry_updates: Arc::new(AtomicUsize::new(0)),
        }
    }

    fn idle() -> Self {
        Self::camera(CameraState::Running)
    }

    fn starting_at(start_segment: SegmentId) -> Self {
        let hub = Arc::new(EventHub::new(CameraState::Running));
        hub.drive(Input::StartCommand { start_segment }, 1000);
        Self {
            hub,
            telemetry_updates: Arc::new(AtomicUsize::new(0)),
        }
    }

    fn recording_segment(id: SegmentId) -> Self {
        let hub = Arc::new(EventHub::new(CameraState::Running));
        hub.drive(Input::StartCommand { start_segment: id }, 1000);
        // Session derives from the start segment: start_segment `id` -> session `id + 1`.
        let session = u64::from(id) + 1;
        hub.drive(
            Input::Recorder(RecorderEvent::SegmentOpened { session, id }),
            1100,
        );
        Self {
            hub,
            telemetry_updates: Arc::new(AtomicUsize::new(0)),
        }
    }
}

fn status_request() -> Request<Body> {
    Request::builder()
        .uri("/v1/status")
        .header("Host", "localhost:8080")
        .body(Body::empty())
        .unwrap()
}

fn events_request() -> Request<Body> {
    Request::builder()
        .uri("/v1/events")
        .header("Host", "localhost:8080")
        .body(Body::empty())
        .unwrap()
}

struct TempRecDir {
    path: PathBuf,
}

impl TempRecDir {
    fn new() -> Self {
        let path =
            std::env::temp_dir().join(format!("dancam-status-route-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&path).unwrap();
        Self { path }
    }

    fn write(&self, name: &str, bytes: &[u8]) {
        fs::write(self.path.join(name), bytes).unwrap();
    }
}

impl Drop for TempRecDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}
