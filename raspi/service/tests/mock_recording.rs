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
    backend::{Backend, BackendError, MockBackend},
    recorder::{parse_segment_filename, segment_filename, stamped_segment_filename, SegmentFacts},
    storage::StorageCoordinator,
    AppState,
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
    // The recording started at segment 0, so its session is `0 + 1 = 1` for every segment.
    assert_new_segments_are_stamped(&rec_dir.path, &[(first_segment, 1), (rolled_segment, 1)]);
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
    // start_segment 100001 -> session 100002.
    assert_new_segments_are_stamped(&rec_dir.path, &[(100001, 100002)]);
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
    assert_eq!(start.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(
        response_json(start).await,
        serde_json::json!({
            "error": "recording_storage_unavailable",
            "message": "recording storage unavailable"
        })
    );

    let status = response_json(app.oneshot(get_request("/v1/status")).await.unwrap()).await;
    assert_eq!(status["recorder"]["phase"], "idle");
    assert_eq!(status["recorder"]["current_segment"], Value::Null);
    assert!(segment_ids(&rec_dir.path).is_empty());
}

#[tokio::test]
async fn writer_mock_start_fails_closed_when_segment_ids_are_exhausted() {
    let rec_dir = TempRecDir::new();
    // Witness already at the u32 ceiling: the next start would reissue u32::MAX.
    write_witness(&rec_dir.path, u32::MAX);
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
        .oneshot(recording_request("/v1/recording/start", "start-exhausted"))
        .await
        .unwrap();
    assert_eq!(start.status(), StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(
        response_json(start).await,
        serde_json::json!({
            "error": "recording_storage_unavailable",
            "message": "recording storage unavailable"
        })
    );

    let status = response_json(app.oneshot(get_request("/v1/status")).await.unwrap()).await;
    assert_eq!(status["recorder"]["phase"], "idle");
    assert_eq!(status["recorder"]["current_segment"], Value::Null);
    assert!(segment_ids(&rec_dir.path).is_empty());
}

#[tokio::test]
async fn writer_mock_start_at_ceiling_fails_closed_on_rollover() {
    let rec_dir = TempRecDir::new();
    // Reserve the *last legal* id: witness at u32::MAX - 1 means start reserves u32::MAX,
    // so allocation succeeds and the recording opens seg u32::MAX. Its next rollover would
    // reissue u32::MAX, and the writer must fail closed there instead.
    write_witness(&rec_dir.path, u32::MAX - 1);
    let roll_interval = Duration::from_millis(300);
    let storage = storage_for(&rec_dir.path);
    let app = dancam::app(
        AppState::new(
            BOOT_ID.to_string(),
            MockBackend::recording_to(storage.clone(), roll_interval),
        )
        .with_storage(storage),
    );

    let start = app
        .clone()
        .oneshot(recording_request("/v1/recording/start", "start-ceiling"))
        .await
        .unwrap();
    assert_eq!(start.status(), StatusCode::OK);

    let first_segment = poll_status_for_segment(app.clone(), None, Duration::from_secs(2)).await;
    assert_eq!(first_segment, u32::MAX);

    poll_status_for_recorder_phase(app.clone(), "error", Duration::from_secs(3)).await;

    // Exactly one stamped seg u32::MAX (start_segment u32::MAX -> session u32::MAX + 1),
    // no same-seq twin, and no out-of-range overflow file.
    let stamped = stamped_sessions(&rec_dir.path);
    assert_eq!(stamped.get(&u32::MAX), Some(&(u64::from(u32::MAX) + 1)));
    assert_eq!(segment_ids(&rec_dir.path), vec![u32::MAX]);
    assert!(!rec_dir.path.join("seg_4294967296.ts").exists());
}

/// A same-boot service restart must not merge two recordings: the second recording's
/// session must be distinct from the first (which is session 1). This drives the real
/// composition seam -- a *brand-new* `StorageCoordinator` + `MockBackend` + `AppState`
/// against the same rec dir and the same `BOOT_ID` -- so it passes only because the
/// rebuilt coordinator re-reads the durable witness and feeds the correct reservation
/// into a fresh `RecorderState` whose in-process session field has reset to 0.
#[tokio::test]
async fn same_boot_service_restart_does_not_reissue_session_one() {
    let rec_dir = TempRecDir::new();
    let roll_interval = Duration::from_millis(300);

    drive_one_recording(&rec_dir.path, roll_interval, "restart-run-1").await;
    assert_eq!(
        newest_stamped_session(&rec_dir.path),
        1,
        "first recording starts at segment 0, so its session is 1"
    );

    drive_one_recording(&rec_dir.path, roll_interval, "restart-run-2").await;
    let second = newest_stamped_session(&rec_dir.path);
    assert!(
        second > 1,
        "a same-boot service restart must not reissue session 1 (was {second})"
    );
}

async fn drive_one_recording(rec_dir: &Path, roll_interval: Duration, key: &str) {
    let storage = storage_for(rec_dir);
    let app = dancam::app(
        AppState::new(
            BOOT_ID.to_string(),
            MockBackend::recording_to(storage.clone(), roll_interval),
        )
        .with_storage(storage),
    );

    let start = app
        .clone()
        .oneshot(recording_request("/v1/recording/start", key))
        .await
        .unwrap();
    assert_eq!(start.status(), StatusCode::OK);

    poll_status_for_segment(app.clone(), None, Duration::from_secs(2)).await;

    let stop = app
        .oneshot(recording_request(
            "/v1/recording/stop",
            &format!("{key}-stop"),
        ))
        .await
        .unwrap();
    assert_eq!(stop.status(), StatusCode::OK);
}

fn newest_stamped_session(rec_dir: &Path) -> u64 {
    stamped_sessions(rec_dir)
        .into_iter()
        .max_by_key(|(seq, _)| *seq)
        .map(|(_, session)| session)
        .expect("expected at least one stamped segment")
}

#[tokio::test]
async fn writer_mock_start_fails_closed_when_required_mountpoint_is_plain_dir() {
    let mountpoint = TempRecDir::new();
    let rec_dir = mountpoint.path.join("rec");
    let storage = Arc::new(
        StorageCoordinator::new(rec_dir.clone()).with_required_mountpoint(mountpoint.path.clone()),
    );
    let backend = MockBackend::recording_to(storage, Duration::from_secs(30));

    let error = backend.start_recording().await.unwrap_err();

    assert_eq!(error, BackendError::RecordingStorageUnavailable);
    assert!(!rec_dir.exists());
}

#[tokio::test]
async fn writer_mock_scrubs_zero_byte_leftover_and_records_above_it() {
    let rec_dir = TempRecDir::new();
    fs::write(rec_dir.path.join(segment_filename(23)), b"previous").unwrap();
    fs::write(rec_dir.path.join(segment_filename(24)), b"").unwrap();
    let storage = storage_for(&rec_dir.path);

    let report = storage.scrub_unrecoverable_segments().unwrap();

    assert_eq!(report.deleted_ids, [24]);
    assert!(!rec_dir.path.join(segment_filename(24)).exists());
    assert_eq!(read_high_water_seq(&rec_dir.path), 24);

    let app = dancam::app(
        AppState::new(
            BOOT_ID.to_string(),
            MockBackend::recording_to(storage.clone(), Duration::from_secs(30)),
        )
        .with_storage(storage),
    );
    let clips_response = app.clone().oneshot(get_request("/v1/clips")).await.unwrap();
    assert_eq!(clips_response.status(), StatusCode::OK);
    let clips_json = response_json(clips_response).await;
    assert_eq!(clip_ids(&clips_json), [23]);

    let start = app
        .clone()
        .oneshot(recording_request(
            "/v1/recording/start",
            "start-after-scrub",
        ))
        .await
        .unwrap();
    assert_eq!(start.status(), StatusCode::OK);

    let first_segment = poll_status_for_segment(app.clone(), None, Duration::from_secs(2)).await;
    assert_eq!(first_segment, 25);
    assert!(!rec_dir.path.join(segment_filename(24)).exists());

    let stop = app
        .oneshot(recording_request("/v1/recording/stop", "stop-after-scrub"))
        .await
        .unwrap();
    assert_eq!(stop.status(), StatusCode::OK);
}

#[tokio::test]
async fn writer_mock_preserves_nonzero_footage_in_mixed_duplicate_group() {
    let rec_dir = TempRecDir::new();
    let fixture = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("assets/clips/seg_00000.ts");
    let fixture_bytes = fs::read(fixture).unwrap();
    fs::write(rec_dir.path.join(segment_filename(24)), &fixture_bytes).unwrap();
    let stamped = rec_dir.path.join(stamped_name(24));
    fs::write(&stamped, b"").unwrap();
    let storage = storage_for(&rec_dir.path);

    let report = storage.scrub_unrecoverable_segments().unwrap();

    assert!(report.deleted_ids.is_empty());
    assert_eq!(
        report.repaired_paths.as_slice(),
        std::slice::from_ref(&stamped)
    );
    assert!(!stamped.exists());

    let app = dancam::app(
        AppState::new(
            BOOT_ID.to_string(),
            MockBackend::recording_to(storage.clone(), Duration::from_secs(30)),
        )
        .with_storage(storage),
    );
    let clips_response = app.clone().oneshot(get_request("/v1/clips")).await.unwrap();
    assert_eq!(clips_response.status(), StatusCode::OK);
    let clips_json = response_json(clips_response).await;
    let clip = clips_json["clips"]
        .as_array()
        .unwrap()
        .iter()
        .find(|clip| clip["id"].as_u64() == Some(24))
        .unwrap_or_else(|| panic!("clips were {clips_json}"));
    assert_eq!(clip["bytes"], fixture_bytes.len() as u64);

    let pull = app.oneshot(get_request("/v1/clips/24")).await.unwrap();
    assert_eq!(pull.status(), StatusCode::OK);
    let body = pull.into_body().collect().await.unwrap().to_bytes();
    assert_eq!(body.as_ref(), fixture_bytes.as_slice());
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

async fn poll_status_for_recorder_phase(app: axum::Router, phase: &str, timeout: Duration) {
    tokio::time::timeout(timeout, async {
        loop {
            let json = response_json(
                app.clone()
                    .oneshot(get_request("/v1/status"))
                    .await
                    .unwrap(),
            )
            .await;
            if json["recorder"]["phase"] == phase {
                return;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .unwrap_or_else(|_| panic!("timed out waiting for recorder phase {phase}"));
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

fn clip_ids(json: &Value) -> Vec<u64> {
    json["clips"]
        .as_array()
        .unwrap()
        .iter()
        .map(|clip| clip["id"].as_u64().unwrap())
        .collect()
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

fn assert_new_segments_are_stamped(rec_dir: &Path, expected: &[(u32, u64)]) {
    let stamped = stamped_sessions(rec_dir);

    for (seq, session) in expected {
        assert_eq!(
            stamped.get(seq),
            Some(session),
            "segment {seq} was not stamped with session {session} in {stamped:?}"
        );
    }
}

/// Map of every stamped segment's seq to the session it was stamped with.
fn stamped_sessions(rec_dir: &Path) -> std::collections::BTreeMap<u32, u64> {
    fs::read_dir(rec_dir)
        .unwrap()
        .filter_map(|entry| {
            let name = entry.ok()?.file_name().into_string().ok()?;
            let parsed = parse_segment_filename(&name)?;
            parsed.facts.map(|facts| (parsed.seq, facts.session))
        })
        .collect()
}

fn write_witness(rec_dir: &Path, high_water_seq: u32) {
    let state_dir = rec_dir.join("state");
    fs::create_dir_all(&state_dir).unwrap();
    fs::write(
        state_dir.join("state.json"),
        format!(r#"{{"high_water_seq":{high_water_seq}}}"#),
    )
    .unwrap();
}

fn stamped_name(seq: u32) -> String {
    stamped_segment_filename(
        seq,
        &SegmentFacts {
            boot_tag: "abc123def456".to_string(),
            session: 1,
            mono_ms: 123456789,
            dur_ms: None,
        },
    )
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
