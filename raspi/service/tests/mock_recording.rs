use std::{
    fs,
    path::{Path, PathBuf},
    time::Duration,
};

use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use http_body_util::BodyExt;
use serde_json::Value;
use tower::ServiceExt;

use dancam::{backend::MockBackend, AppState};

const BOOT_ID: &str = "3f1c0e7a-8f3b-4e15-b196-20e0416af749";

#[tokio::test]
async fn writer_mock_surfaces_open_segment_rollover_and_stop() {
    let rec_dir = TempRecDir::new();
    let roll_interval = Duration::from_millis(500);
    let app = dancam::app(
        AppState::new(
            BOOT_ID.to_string(),
            MockBackend::recording_to(rec_dir.path.clone(), roll_interval),
        )
        .with_rec_dir(rec_dir.path.clone()),
    );

    let start = app
        .clone()
        .oneshot(recording_request("/v1/recording/start", "start-1"))
        .await
        .unwrap();
    assert_eq!(start.status(), StatusCode::OK);

    let first_segment = poll_status_for_segment(app.clone(), None, Duration::from_secs(2)).await;
    assert_eq!(first_segment, 0);

    let rolled_segment =
        poll_status_for_segment(app.clone(), Some(first_segment), Duration::from_secs(3)).await;
    assert!(rolled_segment > first_segment);

    let clips_response = app.clone().oneshot(get_request("/v1/clips")).await.unwrap();
    assert_eq!(clips_response.status(), StatusCode::OK);
    let clips_json = response_json(clips_response).await;
    let clips = clips_json["clips"].as_array().unwrap();
    let first_clip = clips
        .iter()
        .find(|clip| clip["id"].as_u64() == Some(first_segment as u64))
        .unwrap_or_else(|| panic!("finished clips were {clips_json}"));
    // The mock now writes real TS, so the rolled clip carries a non-null duration.
    assert!(
        first_clip["dur_ms"]
            .as_u64()
            .is_some_and(|dur_ms| dur_ms > 0),
        "rolled clip dur_ms was {}",
        first_clip["dur_ms"]
    );

    let stop = app
        .clone()
        .oneshot(recording_request("/v1/recording/stop", "stop-1"))
        .await
        .unwrap();
    assert_eq!(stop.status(), StatusCode::OK);

    let stopped_status = response_json(
        app.clone()
            .oneshot(get_request("/v1/status"))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(stopped_status["recorder"]["phase"], "idle");
    assert_eq!(stopped_status["recorder"]["current_segment"], Value::Null);

    let snapshot = segment_snapshot(&rec_dir.path);
    tokio::time::sleep(roll_interval * 2).await;
    assert_eq!(segment_snapshot(&rec_dir.path), snapshot);
}

async fn poll_status_for_segment(
    app: axum::Router,
    previous: Option<u32>,
    timeout: Duration,
) -> u32 {
    tokio::time::timeout(timeout, async {
        loop {
            let response = app
                .clone()
                .oneshot(get_request("/v1/status"))
                .await
                .unwrap();
            assert_eq!(response.status(), StatusCode::OK);
            let json = response_json(response).await;
            if let Some(id) = json["recorder"]["current_segment"]["id"]
                .as_u64()
                .map(|id| id as u32)
            {
                if previous.is_none_or(|previous| id > previous) {
                    return id;
                }
            }

            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("timed out waiting for mock segment status")
}

async fn response_json(response: axum::http::Response<Body>) -> Value {
    let body = response.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&body).unwrap()
}

fn get_request(uri: &str) -> Request<Body> {
    Request::builder()
        .uri(uri)
        .header("Host", "localhost:8080")
        .body(Body::empty())
        .unwrap()
}

fn recording_request(uri: &str, idempotency_key: &str) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(uri)
        .header("Host", "localhost:8080")
        .header("Content-Type", "application/json")
        .header("Idempotency-Key", idempotency_key)
        .body(Body::from("{}"))
        .unwrap()
}

fn segment_snapshot(rec_dir: &Path) -> Vec<(String, u64)> {
    let mut snapshot: Vec<_> = fs::read_dir(rec_dir)
        .unwrap()
        .flatten()
        .filter_map(|entry| {
            let path = entry.path();
            let name = path.file_name()?.to_str()?.to_string();
            let metadata = entry.metadata().ok()?;
            metadata.is_file().then_some((name, metadata.len()))
        })
        .collect();
    snapshot.sort();
    snapshot
}

struct TempRecDir {
    path: PathBuf,
}

impl TempRecDir {
    fn new() -> Self {
        let path =
            std::env::temp_dir().join(format!("dancam-mock-recording-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&path).unwrap();
        Self { path }
    }
}

impl Drop for TempRecDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}
