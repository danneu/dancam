use std::{fs, path::PathBuf, sync::Arc, time::Duration};

use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use http_body_util::BodyExt;
use serde_json::Value;
use tower::ServiceExt;

use dancam::{backend::MockBackend, storage::StorageCoordinator, AppState};

const BOOT_ID: &str = "3f1c0e7a-8f3b-4e15-b196-20e0416af749";
const VALID_EPOCH_MS: i64 = 1_800_000_000_000;
const MIN_EPOCH_MS: i64 = 1_767_225_600_000;
const MAX_EPOCH_MS: i64 = 4_102_444_800_000;

#[tokio::test]
async fn time_sync_requires_mutation_headers() {
    let rec_dir = TempRecDir::new();
    let app = dancam::app(state(rec_dir.path.clone()));

    let missing_content_type = app
        .clone()
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/time")
                .header("Host", "localhost:8080")
                .header("Idempotency-Key", "time-1")
                .body(Body::from(format!(r#"{{"epoch_ms":{VALID_EPOCH_MS}}}"#)))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(
        missing_content_type.status(),
        StatusCode::UNSUPPORTED_MEDIA_TYPE
    );

    let missing_idempotency_key = app
        .oneshot(
            Request::builder()
                .method("POST")
                .uri("/v1/time")
                .header("Host", "localhost:8080")
                .header("Content-Type", "application/json")
                .body(Body::from(format!(r#"{{"epoch_ms":{VALID_EPOCH_MS}}}"#)))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(missing_idempotency_key.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn time_sync_rejects_implausible_epochs() {
    let rec_dir = TempRecDir::new();
    let app = dancam::app(state(rec_dir.path.clone()));

    for (epoch_ms, key) in [(MIN_EPOCH_MS - 1, "below"), (MAX_EPOCH_MS + 1, "above")] {
        let response = app
            .clone()
            .oneshot(time_request(epoch_ms, key))
            .await
            .unwrap();
        assert_eq!(
            response.status(),
            StatusCode::BAD_REQUEST,
            "epoch {epoch_ms}"
        );
    }
}

#[tokio::test]
async fn first_sync_writes_file_emits_event_and_updates_snapshot() {
    let rec_dir = TempRecDir::new();
    let app = dancam::app(state(rec_dir.path.clone()));
    let response = app.clone().oneshot(events_request()).await.unwrap();
    let mut reader = SseReader::new(response.into_body());
    let snapshot = reader.next().await;
    assert_eq!(snapshot.json["type"], "snapshot");
    assert_eq!(snapshot.json["time"]["synced"], false);

    let sync = app
        .clone()
        .oneshot(time_request(VALID_EPOCH_MS, "time-1"))
        .await
        .unwrap();
    assert_eq!(sync.status(), StatusCode::OK);
    let body = response_json(sync).await;
    assert_eq!(body["synced"], true);

    let event = wait_for_type(&mut reader, "time_synced", Duration::from_secs(2)).await;
    assert!(event.json["at_ms"].as_u64().is_some());
    assert!(rec_dir
        .path
        .join("time")
        .join(format!("{BOOT_ID}.json"))
        .exists());

    let status = response_json(app.oneshot(status_request()).await.unwrap()).await;
    assert_eq!(status["time"]["synced"], true);
}

#[tokio::test]
async fn repeat_sync_keeps_the_first_offset() {
    let rec_dir = TempRecDir::new();
    let app = dancam::app(state(rec_dir.path.clone()));

    assert_eq!(
        app.clone()
            .oneshot(time_request(VALID_EPOCH_MS, "time-1"))
            .await
            .unwrap()
            .status(),
        StatusCode::OK
    );
    let first = read_record(&rec_dir.path);

    assert_eq!(
        app.oneshot(time_request(VALID_EPOCH_MS + 50_000, "time-2"))
            .await
            .unwrap()
            .status(),
        StatusCode::OK
    );
    let second = read_record(&rec_dir.path);

    assert_eq!(second, first);
}

#[tokio::test]
async fn restart_same_boot_loads_synced_snapshot() {
    let rec_dir = TempRecDir::new();
    let first_app = dancam::app(state(rec_dir.path.clone()));
    assert_eq!(
        first_app
            .oneshot(time_request(VALID_EPOCH_MS, "time-1"))
            .await
            .unwrap()
            .status(),
        StatusCode::OK
    );

    let second_app = dancam::app(state(rec_dir.path.clone()));
    let status = response_json(second_app.oneshot(status_request()).await.unwrap()).await;

    assert_eq!(status["time"]["synced"], true);
}

#[tokio::test]
async fn torn_offset_file_is_ignored_and_boot_can_resync() {
    let rec_dir = TempRecDir::new();
    fs::create_dir_all(rec_dir.path.join("time")).unwrap();
    fs::write(
        rec_dir.path.join("time").join(format!("{BOOT_ID}.json")),
        b"{",
    )
    .unwrap();
    let app = dancam::app(state(rec_dir.path.clone()));

    let initial = response_json(app.clone().oneshot(status_request()).await.unwrap()).await;
    assert_eq!(initial["time"]["synced"], false);

    let sync = app
        .clone()
        .oneshot(time_request(VALID_EPOCH_MS, "time-1"))
        .await
        .unwrap();
    assert_eq!(sync.status(), StatusCode::OK);

    let status = response_json(app.oneshot(status_request()).await.unwrap()).await;
    assert_eq!(status["time"]["synced"], true);
    assert_eq!(read_record(&rec_dir.path)["boot_id"], BOOT_ID);
}

fn state(rec_dir: PathBuf) -> AppState {
    let storage = Arc::new(StorageCoordinator::new(rec_dir));
    AppState::new(
        BOOT_ID.to_string(),
        MockBackend::recording_to(storage.clone(), Duration::from_secs(60)),
    )
    .with_storage(storage)
}

fn time_request(epoch_ms: i64, idempotency_key: &str) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri("/v1/time")
        .header("Host", "localhost:8080")
        .header("Content-Type", "application/json")
        .header("Idempotency-Key", idempotency_key)
        .body(Body::from(format!(r#"{{"epoch_ms":{epoch_ms}}}"#)))
        .unwrap()
}

fn events_request() -> Request<Body> {
    Request::builder()
        .uri("/v1/events")
        .header("Host", "localhost:8080")
        .body(Body::empty())
        .unwrap()
}

fn status_request() -> Request<Body> {
    Request::builder()
        .uri("/v1/status")
        .header("Host", "localhost:8080")
        .body(Body::empty())
        .unwrap()
}

async fn response_json(response: axum::http::Response<Body>) -> Value {
    let body = response.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&body).unwrap()
}

fn read_record(rec_dir: &std::path::Path) -> Value {
    serde_json::from_slice(&fs::read(rec_dir.join("time").join(format!("{BOOT_ID}.json"))).unwrap())
        .unwrap()
}

async fn wait_for_type(reader: &mut SseReader, event_type: &str, timeout: Duration) -> SseFrame {
    tokio::time::timeout(timeout, async {
        loop {
            let frame = reader.next().await;
            if frame.json["type"] == event_type {
                return frame;
            }
        }
    })
    .await
    .unwrap_or_else(|_| panic!("timed out waiting for {event_type}"))
}

struct SseReader {
    body: Body,
    buffer: Vec<u8>,
}

impl SseReader {
    fn new(body: Body) -> Self {
        Self {
            body,
            buffer: Vec::new(),
        }
    }

    async fn next(&mut self) -> SseFrame {
        loop {
            if let Some(index) = find_frame_boundary(&self.buffer) {
                let raw: Vec<_> = self.buffer.drain(..index + 2).collect();
                return parse_sse_frame(&raw[..index]);
            }

            let frame = self
                .body
                .frame()
                .await
                .expect("SSE body ended before next frame")
                .expect("SSE body frame failed");
            if let Ok(data) = frame.into_data() {
                self.buffer.extend_from_slice(&data);
            }
        }
    }
}

#[derive(Debug)]
struct SseFrame {
    json: Value,
}

fn find_frame_boundary(buffer: &[u8]) -> Option<usize> {
    buffer.windows(2).position(|window| window == b"\n\n")
}

fn parse_sse_frame(raw: &[u8]) -> SseFrame {
    let text = std::str::from_utf8(raw).unwrap();
    let mut data = Vec::new();
    for line in text.lines() {
        if let Some(value) = line.strip_prefix("data:") {
            data.push(value.trim());
        }
    }

    SseFrame {
        json: serde_json::from_str(&data.join("\n")).unwrap(),
    }
}

struct TempRecDir {
    path: PathBuf,
}

impl TempRecDir {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!("dancam-time-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&path).unwrap();
        Self { path }
    }
}

impl Drop for TempRecDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}
