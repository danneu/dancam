use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use http_body_util::BodyExt;
use serde_json::Value;
use tower::ServiceExt;

use dancam::{backend::MockBackend, AppState};

const BOOT_ID: &str = "3f1c0e7a-8f3b-4e15-b196-20e0416af749";

fn state() -> AppState {
    AppState::new(BOOT_ID.to_string(), MockBackend::new())
}

fn recording_request(path: &str) -> axum::http::request::Builder {
    Request::builder()
        .method("POST")
        .uri(path)
        .header("Host", "10.42.0.1:8080")
}

#[tokio::test]
async fn start_recording_requires_json_content_type() {
    let response = dancam::app(state())
        .oneshot(
            recording_request("/v1/recording/start")
                .header("Idempotency-Key", "key")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::UNSUPPORTED_MEDIA_TYPE);
}

#[tokio::test]
async fn start_recording_requires_idempotency_key() {
    let response = dancam::app(state())
        .oneshot(
            recording_request("/v1/recording/start")
                .header("Content-Type", "application/json")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
async fn recording_start_and_stop_update_status_recorder_phase() {
    let app = dancam::app(state());

    let response = app
        .clone()
        .oneshot(
            recording_request("/v1/recording/start")
                .header("Content-Type", "application/json")
                .header("Idempotency-Key", "start-1")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    let response = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/v1/status")
                .header("Host", "10.42.0.1:8080")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let body = response.into_body().collect().await.unwrap().to_bytes();
    let json: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(json["recorder"]["phase"], "recording");

    let response = app
        .clone()
        .oneshot(
            recording_request("/v1/recording/stop")
                .header("Content-Type", "application/json")
                .header("Idempotency-Key", "stop-1")
                .body(Body::from("{}"))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);

    let response = app
        .oneshot(
            Request::builder()
                .uri("/v1/status")
                .header("Host", "10.42.0.1:8080")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let body = response.into_body().collect().await.unwrap().to_bytes();
    let json: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(json["recorder"]["phase"], "idle");
}

#[tokio::test]
async fn host_allowlist_allows_expected_hosts() {
    for host in [
        "10.42.0.1:8080",
        "dancam.local:8080",
        "localhost:8080",
        "10.42.0.1",
    ] {
        let response = dancam::app(state())
            .oneshot(
                Request::builder()
                    .uri("/v1/status")
                    .header("Host", host)
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(response.status(), StatusCode::OK, "host {host}");
    }
}

#[tokio::test]
async fn host_allowlist_rejects_missing_bad_and_wrong_port_hosts() {
    let response = dancam::app(state())
        .oneshot(
            Request::builder()
                .uri("/v1/status")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::MISDIRECTED_REQUEST);

    for host in ["evil.example:8080", "10.42.0.1:9999"] {
        let response = dancam::app(state())
            .oneshot(
                Request::builder()
                    .uri("/v1/status")
                    .header("Host", host)
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();

        assert_eq!(
            response.status(),
            StatusCode::MISDIRECTED_REQUEST,
            "host {host}"
        );
    }
}
