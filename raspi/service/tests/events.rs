use std::{fs, path::PathBuf, sync::Arc, time::Duration};

use axum::{
    body::Body,
    http::{header, Request, StatusCode},
};
use http_body_util::BodyExt;
use serde_json::Value;
use tower::ServiceExt;

use dancam::{
    backend::MockBackend, recorder::parse_segment_filename, storage::StorageCoordinator, AppState,
};

const BOOT_ID: &str = "3f1c0e7a-8f3b-4e15-b196-20e0416af749";
const VALID_EPOCH_MS: i64 = 1_800_000_000_000;

#[tokio::test]
async fn events_stream_starts_with_snapshot_and_proto_headers() {
    let rec_dir = TempRecDir::new();
    let storage = storage_for(&rec_dir.path);
    let backend = MockBackend::recording_to(storage.clone(), Duration::from_secs(60));
    let app = dancam::app(state(storage, backend));

    let response = app.oneshot(events_request()).await.unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert!(response
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| value.starts_with("text/event-stream")));
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

    let mut reader = SseReader::new(response.into_body());
    let frame = reader.next().await;
    assert!(frame.id.parse::<u64>().is_ok());
    assert_eq!(frame.json["type"], "snapshot");
    assert_eq!(frame.json["boot_id"], BOOT_ID);
    assert_eq!(frame.json["time"]["synced"], false);
}

#[tokio::test]
async fn events_stream_emits_command_phases_before_child_confirmations() {
    let rec_dir = TempRecDir::new();
    let storage = storage_for(&rec_dir.path);
    let backend = MockBackend::recording_to(storage.clone(), Duration::from_secs(60));
    let app = dancam::app(state(storage, backend));

    let response = app.clone().oneshot(events_request()).await.unwrap();
    let mut reader = SseReader::new(response.into_body());
    assert_eq!(reader.next().await.json["type"], "snapshot");

    let start = app
        .clone()
        .oneshot(recording_request("/v1/recording/start", "start-1"))
        .await
        .unwrap();
    assert_eq!(start.status(), StatusCode::OK);

    let first_after_start = reader.next().await;
    assert_eq!(first_after_start.json["type"], "recording_starting");
    let session = first_after_start.json["session"].as_u64().unwrap();
    assert_eq!(session, 1);

    wait_for_type(&mut reader, "segment_opened", Duration::from_secs(2)).await;

    let stop = app
        .oneshot(recording_request("/v1/recording/stop", "stop-1"))
        .await
        .unwrap();
    assert_eq!(stop.status(), StatusCode::OK);

    let first_after_stop = reader.next().await;
    assert_eq!(first_after_stop.json["type"], "recording_stopping");
    assert_eq!(first_after_stop.json["session"], session);
}

#[tokio::test]
async fn mock_tick_emits_heartbeat_without_a_timer() {
    let rec_dir = TempRecDir::new();
    let storage = storage_for(&rec_dir.path);
    let backend = MockBackend::recording_to(storage.clone(), Duration::from_secs(60));
    let app = dancam::app(state(storage, backend.clone()));

    let response = app.oneshot(events_request()).await.unwrap();
    let mut reader = SseReader::new(response.into_body());
    assert_eq!(reader.next().await.json["type"], "snapshot");

    backend.tick();

    let heartbeat = reader.next().await;
    assert_eq!(heartbeat.json["type"], "heartbeat");
    assert!(heartbeat.json["t_ms"].as_u64().is_some());
}

#[tokio::test]
async fn rollover_clip_is_pullable_when_clip_finalized_is_observed() {
    let rec_dir = TempRecDir::new();
    let storage = storage_for(&rec_dir.path);
    let backend = MockBackend::recording_to(storage.clone(), Duration::from_millis(250));
    let app = dancam::app(state(storage, backend));

    let response = app.clone().oneshot(events_request()).await.unwrap();
    let mut reader = SseReader::new(response.into_body());
    assert_eq!(reader.next().await.json["type"], "snapshot");

    let sync = app
        .clone()
        .oneshot(time_request(VALID_EPOCH_MS, "time-1"))
        .await
        .unwrap();
    assert_eq!(sync.status(), StatusCode::OK);
    wait_for_type(&mut reader, "time_synced", Duration::from_secs(2)).await;
    let synced_listing = response_json(
        app.clone()
            .oneshot(clip_request("/v1/clips"))
            .await
            .unwrap(),
    )
    .await;
    assert!(synced_listing["server_time_ms"].as_u64().is_some());
    assert!(
        rec_dir
            .path
            .join("time")
            .join(format!("{BOOT_ID}.json"))
            .exists(),
        "time dir entries were {:?}",
        segment_snapshot(&rec_dir.path.join("time"))
    );

    let start = app
        .clone()
        .oneshot(recording_request("/v1/recording/start", "start-1"))
        .await
        .unwrap();
    assert_eq!(start.status(), StatusCode::OK);
    assert!(
        rec_dir
            .path
            .join("time")
            .join(format!("{BOOT_ID}.json"))
            .exists(),
        "time dir entries after start were {:?}",
        segment_snapshot(&rec_dir.path.join("time"))
    );

    let finalized = wait_for_type(&mut reader, "clip_finalized", Duration::from_secs(3)).await;
    let finalized_id = finalized.json["id"].as_u64().unwrap();

    // The finalize event carries a real, file-derived duration, not a fabricated one.
    let event_dur_ms = finalized.json["dur_ms"].as_u64();
    assert!(
        event_dur_ms.is_some_and(|dur_ms| dur_ms > 0),
        "clip_finalized dur_ms was {}",
        finalized.json["dur_ms"]
    );
    assert!(
        finalized.json["start_ms"].as_u64().is_some(),
        "clip_finalized start_ms was {}; files were {:?}; time files were {:?}; time was {}",
        finalized.json["start_ms"],
        segment_snapshot(&rec_dir.path),
        segment_snapshot(&rec_dir.path.join("time")),
        time_record(&rec_dir.path)
    );
    assert_eq!(finalized.json["time_approximate"], false);

    // The stamped rollover clip carries the recording's session (start segment 0 -> 1).
    assert_eq!(finalized.json["session"], 1);
    let filename_dur_ms = fs::read_dir(&rec_dir.path)
        .unwrap()
        .filter_map(|entry| {
            let name = entry.ok()?.file_name().into_string().ok()?;
            let parsed = parse_segment_filename(&name)?;
            (u64::from(parsed.seq) == finalized_id)
                .then(|| parsed.facts.and_then(|facts| facts.dur_ms))
                .flatten()
        })
        .next();
    assert_eq!(filename_dur_ms, event_dur_ms);

    // /v1/clips derives dur_ms from the same segment file, so it must agree exactly --
    // a fabricated event duration would diverge here and the value would flicker on
    // refresh.
    let listed = response_json(
        app.clone()
            .oneshot(clip_request("/v1/clips"))
            .await
            .unwrap(),
    )
    .await;
    let listed_dur_ms = listed["clips"]
        .as_array()
        .unwrap()
        .iter()
        .find(|clip| clip["id"].as_u64() == Some(finalized_id))
        .unwrap_or_else(|| panic!("finalized clip {finalized_id} missing from {listed}"))["dur_ms"]
        .as_u64();
    assert_eq!(
        listed_dur_ms, event_dur_ms,
        "event and /v1/clips dur_ms disagree for segment {finalized_id}"
    );

    let pulled = app
        .oneshot(clip_request(&format!("/v1/clips/{finalized_id}")))
        .await
        .unwrap();
    assert_eq!(pulled.status(), StatusCode::OK);
    let body = pulled.into_body().collect().await.unwrap().to_bytes();
    assert!(!body.is_empty());
}

async fn response_json(response: axum::http::Response<Body>) -> Value {
    let body = response.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&body).unwrap()
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

fn state(storage: Arc<StorageCoordinator>, backend: MockBackend) -> AppState {
    AppState::new(BOOT_ID.to_string(), backend).with_storage(storage)
}

fn storage_for(rec_dir: &std::path::Path) -> Arc<StorageCoordinator> {
    Arc::new(StorageCoordinator::new(rec_dir.to_path_buf()))
}

fn events_request() -> Request<Body> {
    Request::builder()
        .uri("/v1/events")
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

fn clip_request(uri: &str) -> Request<Body> {
    Request::builder()
        .uri(uri)
        .header("Host", "localhost:8080")
        .body(Body::empty())
        .unwrap()
}

fn segment_snapshot(rec_dir: &std::path::Path) -> Vec<String> {
    let Ok(entries) = fs::read_dir(rec_dir) else {
        return Vec::new();
    };
    let mut names = entries
        .flatten()
        .filter_map(|entry| entry.file_name().into_string().ok())
        .collect::<Vec<_>>();
    names.sort();
    names
}

fn time_record(rec_dir: &std::path::Path) -> Value {
    fs::read(rec_dir.join("time").join(format!("{BOOT_ID}.json")))
        .ok()
        .and_then(|bytes| serde_json::from_slice(&bytes).ok())
        .unwrap_or(Value::Null)
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
    id: String,
    json: Value,
}

fn find_frame_boundary(buffer: &[u8]) -> Option<usize> {
    buffer.windows(2).position(|window| window == b"\n\n")
}

fn parse_sse_frame(raw: &[u8]) -> SseFrame {
    let text = std::str::from_utf8(raw).unwrap();
    let mut id = None;
    let mut data = Vec::new();
    for line in text.lines() {
        if let Some(value) = line.strip_prefix("id:") {
            id = Some(value.trim().to_string());
        }
        if let Some(value) = line.strip_prefix("data:") {
            data.push(value.trim());
        }
    }

    SseFrame {
        id: id.unwrap(),
        json: serde_json::from_str(&data.join("\n")).unwrap(),
    }
}

struct TempRecDir {
    path: PathBuf,
}

impl TempRecDir {
    fn new() -> Self {
        let path =
            std::env::temp_dir().join(format!("dancam-events-route-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&path).unwrap();
        Self { path }
    }
}

impl Drop for TempRecDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.path);
    }
}
