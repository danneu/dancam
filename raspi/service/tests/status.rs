use std::{fs, path::PathBuf, pin::Pin, sync::Arc, time::Instant};

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
    recorder::{stamped_segment_filename, RecorderEvent, SegmentFacts, SegmentId},
    world::{CameraState, Input},
    AppState, DurationCache,
};

const BOOT_ID: &str = "3f1c0e7a-8f3b-4e15-b196-20e0416af749";

struct StubBackend {
    hub: EventHub,
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

    fn clip_durations(&self) -> Arc<DurationCache> {
        Arc::new(DurationCache::default())
    }

    fn set_context(&self, boot_id: Arc<str>, started: Instant) {
        self.hub.set_context(boot_id, started);
    }
}

fn state(rec_dir: PathBuf, backend: StubBackend) -> AppState {
    AppState::new(BOOT_ID.to_string(), backend).with_rec_dir(rec_dir)
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
    assert_eq!(json["boot_id"], BOOT_ID);
    assert!(json["uptime_s"].as_u64().is_some());
    assert!(json["storage"].is_object() || json["storage"].is_null());
    assert!(json["temp_c"]["soc"].is_number() || json["temp_c"]["soc"].is_null());
    assert!(json["temp_c"]["sensor"].is_null());
    assert!(json["mem"].is_object() || json["mem"].is_null());
    assert_eq!(json["time"]["synced"], false);
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

fn stamped_name(seq: u32) -> String {
    stamped_segment_filename(
        seq,
        &SegmentFacts {
            boot_tag: "abc123def456".to_string(),
            mono_ms: 123456789,
        },
    )
}

impl StubBackend {
    fn idle() -> Self {
        Self {
            hub: EventHub::new(CameraState::Running),
        }
    }

    fn starting_at(start_segment: SegmentId) -> Self {
        let hub = EventHub::new(CameraState::Running);
        hub.drive(Input::StartCommand { start_segment }, 1000);
        Self { hub }
    }

    fn recording_segment(id: SegmentId) -> Self {
        let hub = EventHub::new(CameraState::Running);
        hub.drive(Input::StartCommand { start_segment: id }, 1000);
        hub.drive(
            Input::Recorder(RecorderEvent::SegmentOpened { session: 1, id }),
            1100,
        );
        Self { hub }
    }
}

fn status_request() -> Request<Body> {
    Request::builder()
        .uri("/v1/status")
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
