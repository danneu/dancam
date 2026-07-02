use std::{
    fs,
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

use axum::{
    body::Body,
    http::{Request, StatusCode},
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
async fn writer_mock_surfaces_open_segment_rollover_and_stop() {
    let rec_dir = TempRecDir::new();
    let roll_interval = Duration::from_millis(500);
    let storage = storage_for(&rec_dir.path);
    let app = dancam::app(
        AppState::new(
            BOOT_ID.to_string(),
            MockBackend::recording_to(storage.clone(), roll_interval),
        )
        .with_storage(storage),
    );

    let sync = app
        .clone()
        .oneshot(time_request(VALID_EPOCH_MS, "time-1"))
        .await
        .unwrap();
    assert_eq!(sync.status(), StatusCode::OK);

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
    assert!(
        first_clip["start_ms"].as_u64().is_some(),
        "rolled clip start_ms was {}",
        first_clip["start_ms"]
    );
    assert_eq!(first_clip["time_approximate"], false);

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
    assert_new_segments_are_stamped(&rec_dir.path, &[first_segment, rolled_segment]);
    tokio::time::sleep(roll_interval * 2).await;
    assert_eq!(segment_snapshot(&rec_dir.path), snapshot);
}

#[tokio::test]
async fn writer_mock_starts_after_six_digit_existing_segment_without_mutating_it() {
    let rec_dir = TempRecDir::new();
    fs::write(rec_dir.path.join("seg_99999.ts"), b"anchor").unwrap();
    let sentinel = b"existing mock segment 100000";
    fs::write(rec_dir.path.join("seg_100000.ts"), sentinel).unwrap();
    let storage = storage_for(&rec_dir.path);
    let app = dancam::app(
        AppState::new(
            BOOT_ID.to_string(),
            MockBackend::recording_to(storage.clone(), Duration::from_secs(30)),
        )
        .with_storage(storage),
    );

    let start = app
        .clone()
        .oneshot(recording_request("/v1/recording/start", "start-six-digit"))
        .await
        .unwrap();
    assert_eq!(start.status(), StatusCode::OK);

    let first_segment = poll_status_for_segment(app.clone(), None, Duration::from_secs(2)).await;
    assert_eq!(first_segment, 100001);
    assert_new_segments_are_stamped(&rec_dir.path, &[100001]);
    assert_eq!(read_high_water_seq(&rec_dir.path), 100001);
    assert_eq!(
        fs::read(rec_dir.path.join("seg_100000.ts"))
            .unwrap()
            .as_slice(),
        sentinel
    );

    let stop = app
        .oneshot(recording_request("/v1/recording/stop", "stop-six-digit"))
        .await
        .unwrap();
    assert_eq!(stop.status(), StatusCode::OK);
}

#[tokio::test]
async fn writer_mock_start_fails_closed_when_witness_is_corrupt() {
    let rec_dir = TempRecDir::new();
    fs::create_dir(rec_dir.path.join("state")).unwrap();
    fs::write(rec_dir.path.join("state").join("state.json"), b"not json").unwrap();
    let storage = storage_for(&rec_dir.path);
    let app = dancam::app(
        AppState::new(
            BOOT_ID.to_string(),
            MockBackend::recording_to(storage.clone(), Duration::from_secs(30)),
        )
        .with_storage(storage),
    );

    let start = app
        .clone()
        .oneshot(recording_request("/v1/recording/start", "start-corrupt"))
        .await
        .unwrap();
    assert_eq!(start.status(), StatusCode::INTERNAL_SERVER_ERROR);
    assert_eq!(response_text(start).await, "storage allocation failed");

    let status = response_json(app.oneshot(get_request("/v1/status")).await.unwrap()).await;
    assert_eq!(status["recorder"]["phase"], "idle");
    assert_eq!(status["recorder"]["current_segment"], Value::Null);
    assert!(segment_ids(&rec_dir.path).is_empty());
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

async fn response_text(response: axum::http::Response<Body>) -> String {
    let body = response.into_body().collect().await.unwrap().to_bytes();
    String::from_utf8(body.to_vec()).unwrap()
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

fn segment_ids(rec_dir: &Path) -> Vec<u32> {
    let mut ids = fs::read_dir(rec_dir)
        .unwrap()
        .filter_map(|entry| {
            let name = entry.ok()?.file_name().into_string().ok()?;
            parse_segment_filename(&name).map(|parsed| parsed.seq)
        })
        .collect::<Vec<_>>();
    ids.sort();
    ids
}

fn storage_for(rec_dir: &Path) -> Arc<StorageCoordinator> {
    Arc::new(StorageCoordinator::new(rec_dir.to_path_buf()))
}

fn read_high_water_seq(rec_dir: &Path) -> u32 {
    let bytes = fs::read(rec_dir.join("state").join("state.json")).unwrap();
    serde_json::from_slice::<Value>(&bytes).unwrap()["high_water_seq"]
        .as_u64()
        .unwrap() as u32
}

fn assert_new_segments_are_stamped(rec_dir: &Path, expected_ids: &[u32]) {
    let stamped = fs::read_dir(rec_dir)
        .unwrap()
        .filter_map(|entry| {
            let name = entry.ok()?.file_name().into_string().ok()?;
            let parsed = parse_segment_filename(&name)?;
            parsed.facts.map(|_| parsed.seq)
        })
        .collect::<std::collections::BTreeSet<_>>();

    for expected in expected_ids {
        assert!(
            stamped.contains(expected),
            "segment {expected} was not stamped in {stamped:?}"
        );
    }
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
