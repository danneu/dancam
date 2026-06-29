use std::{fs, path::PathBuf, pin::Pin};

use async_trait::async_trait;
use axum::{
    body::Body,
    http::{header, Request, StatusCode},
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
async fn clips_route_reports_duration_for_real_transport_stream() {
    let rec_dir = TempRecDir::new();
    let fixture = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("assets/clips/seg_00000.ts");
    fs::copy(fixture, rec_dir.path.join("seg_00000.ts")).unwrap();

    let response = dancam::app(state(rec_dir.path.clone(), false))
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

#[tokio::test]
async fn serve_clip_returns_exact_bytes_and_headers() {
    let rec_dir = TempRecDir::new();
    rec_dir.write("seg_00007.ts", b"clip-bytes");

    let response = dancam::app(state(rec_dir.path.clone(), false))
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
async fn serve_clip_open_ended_range_returns_partial_content() {
    let rec_dir = TempRecDir::new();
    rec_dir.write("seg_00007.ts", b"clip-bytes");

    let response = dancam::app(state(rec_dir.path.clone(), false))
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
    let app = dancam::app(state(rec_dir.path.clone(), false));

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
    let app = dancam::app(state(rec_dir.path.clone(), false));

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

    let response = dancam::app(state(rec_dir.path.clone(), false))
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
    let app = dancam::app(state(rec_dir.path.clone(), true));

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
async fn serve_clip_returns_not_found_for_missing_id() {
    let rec_dir = TempRecDir::new();
    rec_dir.write("seg_00007.ts", b"clip-bytes");

    let response = dancam::app(state(rec_dir.path.clone(), false))
        .oneshot(clip_request("/v1/clips/8"))
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::NOT_FOUND);
}

fn state(rec_dir: PathBuf, recording: bool) -> AppState {
    AppState::new(BOOT_ID.to_string(), StubBackend { recording }).with_rec_dir(rec_dir)
}

fn clip_request(uri: &str) -> Request<Body> {
    clip_request_with_headers(uri, &[])
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
