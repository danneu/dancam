use std::{fs, path::PathBuf, pin::Pin, sync::Arc, time::Instant};

use async_trait::async_trait;
use axum::{
    body::Body,
    http::{header, Request, StatusCode},
};
use bytes::Bytes;
use http_body_util::BodyExt;
use serde_json::Value;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use tokio_stream::Stream;
use tower::ServiceExt;

use dancam::{
    backend::{Backend, BackendError, FrameStream},
    event_hub::{EventConnection, EventHub},
    events::{Event, Snapshot},
    recorder::{stamped_segment_filename, RecorderEvent, SegmentFacts, SegmentId},
    storage::StorageCoordinator,
    world::{CameraState, Input},
    AppState,
};

const BOOT_ID: &str = "3f1c0e7a-8f3b-4e15-b196-20e0416af749";
const BOOT_TAG: &str = "3f1c0e7a8f3b";
const VALID_EPOCH_MS: i64 = 1_800_000_000_000;

struct StubBackend {
    hub: Arc<EventHub>,
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

    fn note_clip_removed(&self, id: SegmentId) {
        self.hub.drive_now(Input::ClipRemoved { id });
    }

    fn set_context(&self, boot_id: Arc<str>, started: Instant) {
        self.hub.set_context(boot_id, started);
    }
}

#[tokio::test]
async fn clips_route_lists_finished_clips_and_headers() {
    let rec_dir = TempRecDir::new();
    rec_dir.write("seg_00000.ts", b"zero");
    rec_dir.write("seg_00001.ts", b"one-one");
    rec_dir.write("seg_00002.ts", b"two");

    let response = dancam::app(state(rec_dir.path.clone(), StubBackend::starting_at(2)))
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
    assert_eq!(clips[0]["boot_tag"], Value::Null);
    assert_eq!(clips[0]["start_ms"], Value::Null);
    assert_eq!(clips[0]["dur_ms"], Value::Null);
    assert_eq!(clips[0]["locked"], false);
    assert_eq!(clips[0]["time_approximate"], true);
    assert_eq!(json["server_time_ms"], Value::Null);
    assert_eq!(json["next_cursor"], Value::Null);
}

#[tokio::test]
async fn clips_route_reports_duration_for_real_transport_stream() {
    let rec_dir = TempRecDir::new();
    let fixture = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("assets/clips/seg_00000.ts");
    fs::copy(fixture, rec_dir.path.join("seg_00000.ts")).unwrap();

    let response = dancam::app(state(rec_dir.path.clone(), StubBackend::idle()))
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
    let clips = json["clips"].as_array().unwrap();

    assert_eq!(clips.len(), 1);
    assert_eq!(clips[0]["id"], 0);
    let dur_ms = clips[0]["dur_ms"].as_u64().unwrap();
    assert!(
        (dur_ms as i64 - 30_000).abs() <= 100,
        "duration was {dur_ms} ms"
    );
    assert_eq!(clips[0]["start_ms"], Value::Null);
    assert_eq!(clips[0]["time_approximate"], true);
    assert_eq!(json["server_time_ms"], Value::Null);
}

#[tokio::test]
async fn clips_route_pages_with_limit_and_cursor() {
    let rec_dir = TempRecDir::new();
    for seq in 0..5 {
        rec_dir.write(&format!("seg_{seq:05}.ts"), b"segment");
    }
    let app = dancam::app(state(rec_dir.path.clone(), StubBackend::idle()));

    let first = response_json(
        app.clone()
            .oneshot(clips_request("/v1/clips?limit=2"))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(
        clip_ids(&first),
        [4, 3],
        "first page should contain the newest two clips"
    );
    assert_eq!(first["next_cursor"], "3");

    let second = response_json(
        app.clone()
            .oneshot(clips_request("/v1/clips?cursor=3&limit=2"))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(
        clip_ids(&second),
        [2, 1],
        "second page should continue strictly below the cursor"
    );
    assert_eq!(second["next_cursor"], "1");

    let terminal = response_json(
        app.oneshot(clips_request("/v1/clips?cursor=1&limit=2"))
            .await
            .unwrap(),
    )
    .await;
    assert_eq!(clip_ids(&terminal), [0]);
    assert_eq!(terminal["next_cursor"], Value::Null);
}

#[tokio::test]
async fn clips_route_lists_mixed_bare_and_stamped_segments_by_seq() {
    let rec_dir = TempRecDir::new();
    rec_dir.write("seg_00001.ts", b"one");
    rec_dir.write(&stamped_name(2), b"two");
    rec_dir.write("seg_00003.ts", b"stale");
    rec_dir.write(&stamped_name(3), b"three");

    let json = response_json(
        dancam::app(state(rec_dir.path.clone(), StubBackend::idle()))
            .oneshot(clips_request("/v1/clips"))
            .await
            .unwrap(),
    )
    .await;

    assert_eq!(clip_ids(&json), [3, 2, 1]);
    let clips = json["clips"].as_array().unwrap();
    assert_eq!(clips[0]["bytes"], 5);
    assert_eq!(clips[0]["etag"], "3-5");
}

#[tokio::test]
async fn clips_route_derives_times_after_sync() {
    let rec_dir = TempRecDir::new();
    rec_dir.write(&stamped_name_for_tag(7, BOOT_TAG, 10), b"stamped");
    let app = dancam::app(state(rec_dir.path.clone(), StubBackend::idle()));

    let sync = app
        .clone()
        .oneshot(time_request(VALID_EPOCH_MS, "time-1"))
        .await
        .unwrap();
    assert_eq!(sync.status(), StatusCode::OK);

    let json = response_json(app.oneshot(clips_request("/v1/clips")).await.unwrap()).await;
    let clip = &json["clips"].as_array().unwrap()[0];

    assert!(clip["start_ms"].as_u64().is_some());
    assert_eq!(clip["boot_tag"], BOOT_TAG);
    assert_eq!(clip["time_approximate"], false);
    assert!(json["server_time_ms"].as_u64().is_some());
}

#[tokio::test]
async fn clips_route_clamps_zero_limit_to_one() {
    let rec_dir = TempRecDir::new();
    for seq in 0..3 {
        rec_dir.write(&format!("seg_{seq:05}.ts"), b"segment");
    }

    let response = dancam::app(state(rec_dir.path.clone(), StubBackend::idle()))
        .oneshot(clips_request("/v1/clips?limit=0"))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    let json = response_json(response).await;
    assert_eq!(clip_ids(&json), [2]);
    assert_eq!(json["next_cursor"], "2");
}

#[tokio::test]
async fn clips_route_rejects_unimplemented_or_invalid_query_params() {
    let rec_dir = TempRecDir::new();
    rec_dir.write("seg_00000.ts", b"zero");
    let app = dancam::app(state(rec_dir.path.clone(), StubBackend::idle()));

    for uri in [
        "/v1/clips?cursor=abc",
        "/v1/clips?limit=abc",
        "/v1/clips?from=0",
        "/v1/clips?to=0",
        "/v1/clips?order=asc",
    ] {
        let response = app.clone().oneshot(clips_request(uri)).await.unwrap();
        assert_eq!(response.status(), StatusCode::BAD_REQUEST, "uri {uri}");
    }

    let accepted = app
        .oneshot(clips_request("/v1/clips?order=desc"))
        .await
        .unwrap();
    assert_eq!(accepted.status(), StatusCode::OK);
}

#[tokio::test]
async fn clips_route_returns_empty_for_missing_dir() {
    let rec_dir = TempRecDir::new();
    let missing = rec_dir.path.join("missing");

    let response = dancam::app(state(missing, StubBackend::idle()))
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
    assert_eq!(json["server_time_ms"], Value::Null);
    assert_eq!(json["next_cursor"], Value::Null);
}

#[cfg(unix)]
#[tokio::test]
async fn clips_route_returns_unavailable_for_unreadable_existing_dir() {
    let rec_dir = TempRecDir::new();
    rec_dir.write("seg_00007.ts", b"clip-bytes");
    fs::set_permissions(&rec_dir.path, fs::Permissions::from_mode(0o000)).unwrap();

    if fs::read_dir(&rec_dir.path).is_ok() {
        fs::set_permissions(&rec_dir.path, fs::Permissions::from_mode(0o700)).unwrap();
        return;
    }

    let response = dancam::app(state(rec_dir.path.clone(), StubBackend::idle()))
        .oneshot(clips_request("/v1/clips"))
        .await
        .unwrap();

    fs::set_permissions(&rec_dir.path, fs::Permissions::from_mode(0o700)).unwrap();
    assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
}

#[tokio::test]
async fn serve_clip_returns_exact_bytes_and_headers() {
    let rec_dir = TempRecDir::new();
    rec_dir.write("seg_00007.ts", b"clip-bytes");

    let response = dancam::app(state(rec_dir.path.clone(), StubBackend::idle()))
        .oneshot(clip_request("/v1/clips/7"))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        response
            .headers()
            .get(header::CONTENT_TYPE)
            .and_then(|value| value.to_str().ok()),
        Some("application/mp2t")
    );
    assert_eq!(
        response
            .headers()
            .get(header::CONTENT_LENGTH)
            .and_then(|value| value.to_str().ok()),
        Some("10")
    );
    assert_eq!(
        header_value(&response, header::ACCEPT_RANGES),
        Some("bytes")
    );
    // Quoted entity-tag, quotes included -- pins the wire form the app octet-matches.
    assert_eq!(header_value(&response, header::ETAG), Some("\"7-10\""));

    let body = response.into_body().collect().await.unwrap().to_bytes();
    assert_eq!(body, Bytes::from_static(b"clip-bytes"));
}

#[tokio::test]
async fn serve_clip_resolves_stamped_segment_by_id() {
    let rec_dir = TempRecDir::new();
    rec_dir.write(&stamped_name(7), b"stamped-bytes");

    let response = dancam::app(state(rec_dir.path.clone(), StubBackend::idle()))
        .oneshot(clip_request("/v1/clips/7"))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(header_value(&response, header::CONTENT_LENGTH), Some("13"));
    assert_eq!(header_value(&response, header::ETAG), Some("\"7-13\""));
    let body = response.into_body().collect().await.unwrap().to_bytes();
    assert_eq!(body, Bytes::from_static(b"stamped-bytes"));
}

#[tokio::test]
async fn list_and_pull_choose_lexicographically_smallest_finalized_duplicate() {
    for reverse in [false, true] {
        let rec_dir = TempRecDir::new();
        let preferred = finalized_name(7, "abc123def456", 300);
        let other = finalized_name(7, "fff123def456", 400);
        let mut entries = [
            (preferred.as_str(), b"preferred".as_slice()),
            (other.as_str(), b"other-longer".as_slice()),
        ];
        if reverse {
            entries.reverse();
        }
        for (name, bytes) in entries {
            rec_dir.write(name, bytes);
        }
        let app = dancam::app(state(rec_dir.path.clone(), StubBackend::idle()));

        let listed = response_json(
            app.clone()
                .oneshot(clips_request("/v1/clips"))
                .await
                .unwrap(),
        )
        .await;
        assert_eq!(listed["clips"][0]["dur_ms"], 300);
        assert_eq!(listed["clips"][0]["bytes"], 9);
        assert_eq!(listed["clips"][0]["etag"], "7-9");

        let response = app.oneshot(clip_request("/v1/clips/7")).await.unwrap();
        assert_eq!(header_value(&response, header::ETAG), Some("\"7-9\""));
        let body = response.into_body().collect().await.unwrap().to_bytes();
        assert_eq!(body, Bytes::from_static(b"preferred"));
    }
}

#[tokio::test]
async fn serve_clip_open_ended_range_returns_partial_content() {
    let rec_dir = TempRecDir::new();
    rec_dir.write("seg_00007.ts", b"clip-bytes");

    let response = dancam::app(state(rec_dir.path.clone(), StubBackend::idle()))
        .oneshot(clip_request_with_headers(
            "/v1/clips/7",
            &[(header::RANGE.as_str(), "bytes=3-")],
        ))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::PARTIAL_CONTENT);
    assert_eq!(
        header_value(&response, header::CONTENT_RANGE),
        Some("bytes 3-9/10")
    );
    assert_eq!(header_value(&response, header::CONTENT_LENGTH), Some("7"));
    assert_eq!(
        header_value(&response, header::ACCEPT_RANGES),
        Some("bytes")
    );
    assert_eq!(header_value(&response, header::ETAG), Some("\"7-10\""));

    let body = response.into_body().collect().await.unwrap().to_bytes();
    assert_eq!(body, Bytes::from_static(b"p-bytes"));
}

#[tokio::test]
async fn serve_clip_closed_and_suffix_ranges_slice_the_body() {
    let rec_dir = TempRecDir::new();
    rec_dir.write("seg_00007.ts", b"clip-bytes");
    let app = dancam::app(state(rec_dir.path.clone(), StubBackend::idle()));

    let closed = app
        .clone()
        .oneshot(clip_request_with_headers(
            "/v1/clips/7",
            &[(header::RANGE.as_str(), "bytes=2-5")],
        ))
        .await
        .unwrap();
    assert_eq!(closed.status(), StatusCode::PARTIAL_CONTENT);
    assert_eq!(
        header_value(&closed, header::CONTENT_RANGE),
        Some("bytes 2-5/10")
    );
    let closed_body = closed.into_body().collect().await.unwrap().to_bytes();
    assert_eq!(closed_body, Bytes::from_static(b"ip-b"));

    let suffix = app
        .oneshot(clip_request_with_headers(
            "/v1/clips/7",
            &[(header::RANGE.as_str(), "bytes=-4")],
        ))
        .await
        .unwrap();
    assert_eq!(suffix.status(), StatusCode::PARTIAL_CONTENT);
    assert_eq!(
        header_value(&suffix, header::CONTENT_RANGE),
        Some("bytes 6-9/10")
    );
    let suffix_body = suffix.into_body().collect().await.unwrap().to_bytes();
    assert_eq!(suffix_body, Bytes::from_static(b"ytes"));
}

#[tokio::test]
async fn serve_clip_honors_matching_if_range_and_ignores_a_mismatch() {
    let rec_dir = TempRecDir::new();
    rec_dir.write("seg_00007.ts", b"clip-bytes");
    let app = dancam::app(state(rec_dir.path.clone(), StubBackend::idle()));

    // Quoted, matching validator -> the Range is honored (206).
    let matching = app
        .clone()
        .oneshot(clip_request_with_headers(
            "/v1/clips/7",
            &[
                (header::RANGE.as_str(), "bytes=3-"),
                (header::IF_RANGE.as_str(), "\"7-10\""),
            ],
        ))
        .await
        .unwrap();
    assert_eq!(matching.status(), StatusCode::PARTIAL_CONTENT);

    // Unquoted validator (the raw list value) -> octet mismatch -> full 200.
    let unquoted = app
        .clone()
        .oneshot(clip_request_with_headers(
            "/v1/clips/7",
            &[
                (header::RANGE.as_str(), "bytes=3-"),
                (header::IF_RANGE.as_str(), "7-10"),
            ],
        ))
        .await
        .unwrap();
    assert_eq!(unquoted.status(), StatusCode::OK);
    assert_eq!(header_value(&unquoted, header::CONTENT_LENGTH), Some("10"));
    let unquoted_body = unquoted.into_body().collect().await.unwrap().to_bytes();
    assert_eq!(unquoted_body, Bytes::from_static(b"clip-bytes"));

    // A different validator -> full 200.
    let different = app
        .oneshot(clip_request_with_headers(
            "/v1/clips/7",
            &[
                (header::RANGE.as_str(), "bytes=3-"),
                (header::IF_RANGE.as_str(), "\"7-999\""),
            ],
        ))
        .await
        .unwrap();
    assert_eq!(different.status(), StatusCode::OK);
}

#[tokio::test]
async fn serve_clip_unsatisfiable_range_returns_416() {
    let rec_dir = TempRecDir::new();
    rec_dir.write("seg_00007.ts", b"clip-bytes");

    let response = dancam::app(state(rec_dir.path.clone(), StubBackend::idle()))
        .oneshot(clip_request_with_headers(
            "/v1/clips/7",
            &[(header::RANGE.as_str(), "bytes=100-")],
        ))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::RANGE_NOT_SATISFIABLE);
    assert_eq!(
        header_value(&response, header::CONTENT_RANGE),
        Some("bytes */10")
    );
}

#[tokio::test]
async fn serve_clip_excludes_open_segment_while_recording() {
    let rec_dir = TempRecDir::new();
    rec_dir.write("seg_00006.ts", b"finished");
    rec_dir.write("seg_00007.ts", b"open");
    let app = dancam::app(state(
        rec_dir.path.clone(),
        StubBackend::recording_segment(7),
    ));

    let open_response = app
        .clone()
        .oneshot(clip_request("/v1/clips/7"))
        .await
        .unwrap();
    assert_eq!(open_response.status(), StatusCode::NOT_FOUND);

    let finished_response = app.oneshot(clip_request("/v1/clips/6")).await.unwrap();
    assert_eq!(finished_response.status(), StatusCode::OK);
    let body = finished_response
        .into_body()
        .collect()
        .await
        .unwrap()
        .to_bytes();
    assert_eq!(body, Bytes::from_static(b"finished"));
}

#[tokio::test]
async fn clips_exclude_reserved_start_segment_before_open_ack() {
    let rec_dir = TempRecDir::new();
    rec_dir.write("seg_00042.ts", b"finished");
    rec_dir.write("seg_00043.ts", b"partial");
    let app = dancam::app(state(rec_dir.path.clone(), StubBackend::starting_at(43)));

    let clips_response = app
        .clone()
        .oneshot(clips_request("/v1/clips"))
        .await
        .unwrap();
    assert_eq!(clips_response.status(), StatusCode::OK);
    let clips_json = response_json(clips_response).await;
    let clips = clips_json["clips"].as_array().unwrap();
    assert_eq!(
        clips
            .iter()
            .map(|clip| clip["id"].as_u64())
            .collect::<Vec<_>>(),
        [Some(42)]
    );

    let partial_response = app.oneshot(clip_request("/v1/clips/43")).await.unwrap();
    assert_eq!(partial_response.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn clips_keep_finalized_rollover_visible_after_failure() {
    let rec_dir = TempRecDir::new();
    rec_dir.write("seg_00043.ts", b"finalized");
    rec_dir.write("seg_00044.ts", b"partial");
    let app = dancam::app(state(
        rec_dir.path.clone(),
        StubBackend::failed_after_roll(43, 44),
    ));

    let clips_response = app
        .clone()
        .oneshot(clips_request("/v1/clips"))
        .await
        .unwrap();
    assert_eq!(clips_response.status(), StatusCode::OK);
    let clips_json = response_json(clips_response).await;
    let clips = clips_json["clips"].as_array().unwrap();
    assert_eq!(
        clips
            .iter()
            .map(|clip| clip["id"].as_u64())
            .collect::<Vec<_>>(),
        [Some(43)]
    );

    let partial_response = app
        .clone()
        .oneshot(clip_request("/v1/clips/44"))
        .await
        .unwrap();
    assert_eq!(partial_response.status(), StatusCode::NOT_FOUND);
    let finalized_response = app.oneshot(clip_request("/v1/clips/43")).await.unwrap();
    assert_eq!(finalized_response.status(), StatusCode::OK);
}

#[tokio::test]
async fn serve_clip_returns_not_found_for_missing_id() {
    let rec_dir = TempRecDir::new();
    rec_dir.write("seg_00007.ts", b"clip-bytes");

    let response = dancam::app(state(rec_dir.path.clone(), StubBackend::idle()))
        .oneshot(clip_request("/v1/clips/8"))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

#[cfg(unix)]
#[tokio::test]
async fn serve_clip_returns_unavailable_for_permission_denied_file() {
    let rec_dir = TempRecDir::new();
    let clip_path = rec_dir.path.join("seg_00007.ts");
    rec_dir.write("seg_00007.ts", b"clip-bytes");
    fs::set_permissions(&clip_path, fs::Permissions::from_mode(0o000)).unwrap();

    if fs::File::open(&clip_path).is_ok() {
        fs::set_permissions(&clip_path, fs::Permissions::from_mode(0o600)).unwrap();
        return;
    }

    let response = dancam::app(state(rec_dir.path.clone(), StubBackend::idle()))
        .oneshot(clip_request("/v1/clips/7"))
        .await
        .unwrap();

    fs::set_permissions(&clip_path, fs::Permissions::from_mode(0o600)).unwrap();
    assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
}

#[tokio::test]
async fn serve_clip_returns_not_found_for_directory_named_like_clip() {
    let rec_dir = TempRecDir::new();
    fs::create_dir(rec_dir.path.join("seg_00009.ts")).unwrap();

    let response = dancam::app(state(rec_dir.path.clone(), StubBackend::idle()))
        .oneshot(clip_request("/v1/clips/9"))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

#[cfg(unix)]
#[tokio::test]
async fn serve_clip_returns_unavailable_for_unreadable_existing_dir() {
    let rec_dir = TempRecDir::new();
    rec_dir.write("seg_00007.ts", b"clip-bytes");
    fs::set_permissions(&rec_dir.path, fs::Permissions::from_mode(0o000)).unwrap();

    if fs::read_dir(&rec_dir.path).is_ok() {
        fs::set_permissions(&rec_dir.path, fs::Permissions::from_mode(0o700)).unwrap();
        return;
    }

    let response = dancam::app(state(rec_dir.path.clone(), StubBackend::idle()))
        .oneshot(clip_request("/v1/clips/7"))
        .await
        .unwrap();

    fs::set_permissions(&rec_dir.path, fs::Permissions::from_mode(0o700)).unwrap();
    assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
}

#[tokio::test]
async fn delete_clip_removes_existing_clip_and_serves_not_found_afterward() {
    let rec_dir = TempRecDir::new();
    let clip_path = rec_dir.path.join("seg_00007.ts");
    rec_dir.write("seg_00007.ts", b"clip-bytes");
    let app = dancam::app(state(rec_dir.path.clone(), StubBackend::idle()));

    let response = app
        .clone()
        .oneshot(delete_request("/v1/clips/7"))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::NO_CONTENT);
    assert!(!clip_path.exists());
    let get = app.oneshot(clip_request("/v1/clips/7")).await.unwrap();
    assert_eq!(get.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn delete_clip_resolves_stamped_only_segment_by_id() {
    let rec_dir = TempRecDir::new();
    let name = stamped_name(7);
    let clip_path = rec_dir.path.join(&name);
    rec_dir.write(&name, b"stamped");

    let response = dancam::app(state(rec_dir.path.clone(), StubBackend::idle()))
        .oneshot(delete_request("/v1/clips/7"))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::NO_CONTENT);
    assert!(!clip_path.exists());
}

#[tokio::test]
async fn delete_clip_removes_bare_and_stamped_duplicates() {
    let rec_dir = TempRecDir::new();
    let stamped = stamped_name(7);
    let bare_path = rec_dir.path.join("seg_00007.ts");
    let stamped_path = rec_dir.path.join(&stamped);
    rec_dir.write("seg_00007.ts", b"bare");
    rec_dir.write(&stamped, b"stamped");
    let app = dancam::app(state(rec_dir.path.clone(), StubBackend::idle()));

    let response = app
        .clone()
        .oneshot(delete_request("/v1/clips/7"))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::NO_CONTENT);
    assert!(!bare_path.exists());
    assert!(!stamped_path.exists());
    let get = app.oneshot(clip_request("/v1/clips/7")).await.unwrap();
    assert_eq!(get.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn delete_clip_returns_not_found_for_missing_id() {
    let rec_dir = TempRecDir::new();
    rec_dir.write("seg_00007.ts", b"clip-bytes");

    let response = dancam::app(state(rec_dir.path.clone(), StubBackend::idle()))
        .oneshot(delete_request("/v1/clips/8"))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn delete_clip_excludes_open_segment_while_recording() {
    let rec_dir = TempRecDir::new();
    let clip_path = rec_dir.path.join("seg_00007.ts");
    rec_dir.write("seg_00007.ts", b"clip-bytes");

    let response = dancam::app(state(
        rec_dir.path.clone(),
        StubBackend::recording_segment(7),
    ))
    .oneshot(delete_request("/v1/clips/7"))
    .await
    .unwrap();

    assert_eq!(response.status(), StatusCode::NOT_FOUND);
    assert!(clip_path.exists());
}

#[tokio::test]
async fn delete_clip_returns_not_found_for_directory_named_like_clip() {
    let rec_dir = TempRecDir::new();
    fs::create_dir(rec_dir.path.join("seg_00009.ts")).unwrap();

    let response = dancam::app(state(rec_dir.path.clone(), StubBackend::idle()))
        .oneshot(delete_request("/v1/clips/9"))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

#[cfg(unix)]
#[tokio::test]
async fn delete_clip_returns_unavailable_for_unreadable_rec_dir() {
    let rec_dir = TempRecDir::new();
    rec_dir.write("seg_00007.ts", b"clip-bytes");
    fs::set_permissions(&rec_dir.path, fs::Permissions::from_mode(0o000)).unwrap();

    if fs::read_dir(&rec_dir.path).is_ok() {
        fs::set_permissions(&rec_dir.path, fs::Permissions::from_mode(0o700)).unwrap();
        return;
    }

    let response = dancam::app(state(rec_dir.path.clone(), StubBackend::idle()))
        .oneshot(delete_request("/v1/clips/7"))
        .await
        .unwrap();

    fs::set_permissions(&rec_dir.path, fs::Permissions::from_mode(0o700)).unwrap();
    assert_eq!(response.status(), StatusCode::SERVICE_UNAVAILABLE);
}

#[tokio::test]
async fn delete_clip_requires_mutation_headers() {
    let rec_dir = TempRecDir::new();
    rec_dir.write("seg_00007.ts", b"clip-bytes");
    let app = dancam::app(state(rec_dir.path.clone(), StubBackend::idle()));

    let missing_key = app
        .clone()
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri("/v1/clips/7")
                .header("Host", "localhost:8080")
                .header("Content-Type", "application/json")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(missing_key.status(), StatusCode::BAD_REQUEST);

    let missing_content_type = app
        .oneshot(
            Request::builder()
                .method("DELETE")
                .uri("/v1/clips/7")
                .header("Host", "localhost:8080")
                .header("Idempotency-Key", "delete-7")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(
        missing_content_type.status(),
        StatusCode::UNSUPPORTED_MEDIA_TYPE
    );
}

#[tokio::test]
async fn delete_clip_emits_clip_removed_after_durable_delete() {
    let rec_dir = TempRecDir::new();
    rec_dir.write("seg_00007.ts", b"clip-bytes");
    let stub = StubBackend::idle();
    let mut connection = stub.hub().connect();
    let app = dancam::app(state(rec_dir.path.clone(), stub));

    let response = app.oneshot(delete_request("/v1/clips/7")).await.unwrap();

    assert_eq!(response.status(), StatusCode::NO_CONTENT);
    let event = connection.rx.recv().await.unwrap();
    assert_eq!(event.event, Event::ClipRemoved { id: 7 });
}

#[tokio::test]
async fn concurrent_deletes_raise_witness_monotonically() {
    let rec_dir = TempRecDir::new();
    for seq in 0..=11 {
        rec_dir.write(&format!("seg_{seq:05}.ts"), b"segment");
    }
    let (state, coordinator) = state_with_storage(rec_dir.path.clone(), StubBackend::idle());
    let app = dancam::app(state);

    let delete_11 = tokio::spawn(app.clone().oneshot(delete_request("/v1/clips/11")));
    let delete_10 = tokio::spawn(app.clone().oneshot(delete_request("/v1/clips/10")));

    let response_11 = delete_11.await.unwrap().unwrap();
    let response_10 = delete_10.await.unwrap().unwrap();

    assert_eq!(response_11.status(), StatusCode::NO_CONTENT);
    assert_eq!(response_10.status(), StatusCode::NO_CONTENT);
    assert!(!rec_dir.path.join("seg_00011.ts").exists());
    assert!(!rec_dir.path.join("seg_00010.ts").exists());
    let next = coordinator.allocate_start_segment().unwrap();
    assert!(next >= 12, "next segment id was {next}");
}

fn state(rec_dir: PathBuf, backend: StubBackend) -> AppState {
    state_with_storage(rec_dir, backend).0
}

fn state_with_storage(
    rec_dir: PathBuf,
    backend: StubBackend,
) -> (AppState, Arc<StorageCoordinator>) {
    let storage = Arc::new(StorageCoordinator::new(rec_dir));
    let state = AppState::new(BOOT_ID.to_string(), backend).with_storage(storage.clone());
    (state, storage)
}

impl StubBackend {
    fn idle() -> Self {
        Self {
            hub: Arc::new(EventHub::new(CameraState::Running)),
        }
    }

    fn starting_at(start_segment: SegmentId) -> Self {
        let hub = Arc::new(EventHub::new(CameraState::Running));
        hub.drive(Input::StartCommand { start_segment }, 1000);
        Self { hub }
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
        Self { hub }
    }

    fn failed_after_roll(start: SegmentId, open: SegmentId) -> Self {
        let hub = Arc::new(EventHub::new(CameraState::Running));
        hub.drive(
            Input::StartCommand {
                start_segment: start,
            },
            1000,
        );
        let session = u64::from(start) + 1;
        hub.drive(
            Input::Recorder(RecorderEvent::SegmentOpened { session, id: start }),
            1100,
        );
        hub.drive(
            Input::Recorder(RecorderEvent::SegmentClosed { session, id: start }),
            1200,
        );
        hub.drive(
            Input::Recorder(RecorderEvent::SegmentOpened { session, id: open }),
            1300,
        );
        hub.drive(
            Input::Fail {
                detail: "camera process exited".to_string(),
            },
            1400,
        );
        Self { hub }
    }

    fn hub(&self) -> Arc<EventHub> {
        self.hub.clone()
    }
}

fn clip_request(uri: &str) -> Request<Body> {
    clip_request_with_headers(uri, &[])
}

fn delete_request(uri: &str) -> Request<Body> {
    Request::builder()
        .method("DELETE")
        .uri(uri)
        .header("Host", "localhost:8080")
        .header("Content-Type", "application/json")
        .header("Idempotency-Key", "delete")
        .body(Body::empty())
        .unwrap()
}

fn clips_request(uri: &str) -> Request<Body> {
    Request::builder()
        .uri(uri)
        .header("Host", "localhost:8080")
        .body(Body::empty())
        .unwrap()
}

async fn response_json(response: axum::http::Response<Body>) -> Value {
    let body = response.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&body).unwrap()
}

fn clip_ids(json: &Value) -> Vec<u64> {
    json["clips"]
        .as_array()
        .unwrap()
        .iter()
        .map(|clip| clip["id"].as_u64().unwrap())
        .collect()
}

fn clip_request_with_headers(uri: &str, headers: &[(&str, &str)]) -> Request<Body> {
    let mut builder = Request::builder().uri(uri).header("Host", "localhost:8080");
    for (name, value) in headers {
        builder = builder.header(*name, *value);
    }
    builder.body(Body::empty()).unwrap()
}

fn header_value(response: &axum::http::Response<Body>, name: header::HeaderName) -> Option<&str> {
    response
        .headers()
        .get(name)
        .and_then(|value| value.to_str().ok())
}

fn stamped_name(seq: u32) -> String {
    stamped_name_for_tag(seq, "abc123def456", 123456789)
}

fn stamped_name_for_tag(seq: u32, boot_tag: &str, mono_ms: u64) -> String {
    stamped_segment_filename(
        seq,
        &SegmentFacts {
            boot_tag: boot_tag.to_string(),
            session: 1,
            mono_ms,
            dur_ms: None,
        },
    )
}

fn finalized_name(seq: u32, boot_tag: &str, dur_ms: u64) -> String {
    stamped_segment_filename(
        seq,
        &SegmentFacts {
            boot_tag: boot_tag.to_string(),
            session: 1,
            mono_ms: 123456789,
            dur_ms: Some(dur_ms),
        },
    )
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
