use std::{fs, path::PathBuf, pin::Pin};

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
    status::{CameraState, Status},
    AppState,
};

const BOOT_ID: &str = "3f1c0e7a-8f3b-4e15-b196-20e0416af749";

struct StubBackend {
    recording: bool,
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

    fn status(&self) -> Status {
        Status {
            recording: self.recording,
            camera_state: CameraState::Running,
        }
    }
}

fn state(rec_dir: PathBuf, recording: bool) -> AppState {
    AppState::new(BOOT_ID.to_string(), StubBackend { recording }).with_rec_dir(rec_dir)
}

#[tokio::test]
async fn status_returns_dashboard_wire_contract() {
    let rec_dir = TempRecDir::new();
    let response = dancam::app(state(rec_dir.path.clone(), false))
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

    assert_eq!(json["recording"], false);
    assert_eq!(json["current_segment_id"], Value::Null);
    assert_eq!(json["current_segment_dur_ms"], Value::Null);
    assert_eq!(json["camera_state"], "running");
    assert_eq!(json["boot_id"], BOOT_ID);
    assert!(json["uptime_s"].as_u64().is_some());
    assert!(json["storage"].is_object() || json["storage"].is_null());
    assert!(json["temp_c"]["soc"].is_number() || json["temp_c"]["soc"].is_null());
    assert!(json["temp_c"]["sensor"].is_null());
    assert!(json["mem"].is_object() || json["mem"].is_null());
}

#[tokio::test]
async fn status_reports_open_segment_metadata_while_recording() {
    let rec_dir = TempRecDir::new();
    let fixture = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("assets/clips/seg_00000.ts");
    fs::copy(fixture, rec_dir.path.join("seg_00000.ts")).unwrap();

    let response = dancam::app(state(rec_dir.path.clone(), true))
        .oneshot(status_request())
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let body = response.into_body().collect().await.unwrap().to_bytes();
    let json: Value = serde_json::from_slice(&body).unwrap();

    assert_eq!(json["recording"], true);
    assert_eq!(json["current_segment_id"], 0);
    let dur_ms = json["current_segment_dur_ms"].as_u64().unwrap();
    assert!(
        (dur_ms as i64 - 30_000).abs() <= 100,
        "duration was {dur_ms} ms"
    );
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
}

impl Drop for TempRecDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}
