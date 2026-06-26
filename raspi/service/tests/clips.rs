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

#[tokio::test]
async fn clips_route_lists_finished_clips_and_headers() {
    let rec_dir = TempRecDir::new();
    rec_dir.write("seg_00000.ts", b"zero");
    rec_dir.write("seg_00001.ts", b"one-one");
    rec_dir.write("seg_00002.ts", b"two");

    let response = dancam::app(state(rec_dir.path.clone(), true))
        .oneshot(
            Request::builder()
                .uri("/v1/clips")
                .header("Host", "localhost:8080")
                .body(Body::empty())
                .unwrap(),
        )
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
    let clips = json["clips"].as_array().unwrap();

    assert_eq!(clips.len(), 2);
    assert_eq!(clips[0]["id"], 1);
    assert_eq!(clips[0]["bytes"], 7);
    assert_eq!(clips[0]["etag"], "1-7");
    assert_eq!(clips[0]["start_ms"], Value::Null);
    assert_eq!(clips[0]["dur_ms"], Value::Null);
    assert_eq!(clips[0]["locked"], false);
    assert_eq!(clips[0]["time_approximate"], true);
    assert!(json["server_time_ms"].as_u64().is_some_and(|t_ms| t_ms > 0));
    assert_eq!(json["next_cursor"], Value::Null);
}

#[tokio::test]
async fn clips_route_returns_empty_for_missing_dir() {
    let rec_dir = TempRecDir::new();
    let missing = rec_dir.path.join("missing");

    let response = dancam::app(state(missing, false))
        .oneshot(
            Request::builder()
                .uri("/v1/clips")
                .header("Host", "localhost:8080")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let body = response.into_body().collect().await.unwrap().to_bytes();
    let json: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(json["clips"].as_array().unwrap().len(), 0);
    assert!(json["server_time_ms"].as_u64().is_some_and(|t_ms| t_ms > 0));
    assert_eq!(json["next_cursor"], Value::Null);
}

fn state(rec_dir: PathBuf, recording: bool) -> AppState {
    AppState::new(BOOT_ID.to_string(), StubBackend { recording }).with_rec_dir(rec_dir)
}

struct TempRecDir {
    path: PathBuf,
}

impl TempRecDir {
    fn new() -> Self {
        let path =
            std::env::temp_dir().join(format!("dancam-clips-route-{}", uuid::Uuid::new_v4()));
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
