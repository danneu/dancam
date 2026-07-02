use axum::{
    body::Body,
    http::{Request, Response, StatusCode},
};
use tower::ServiceExt;

use dancam::{backend::MockBackend, AppState};

const BOOT_ID: &str = "3f1c0e7a-8f3b-4e15-b196-20e0416af749";

fn state() -> AppState {
    AppState::new(BOOT_ID.to_string(), MockBackend::new())
}

fn get(path: &str) -> axum::http::request::Builder {
    Request::builder()
        .uri(path)
        .header("Host", "localhost:8080")
}

fn request_id(response: &Response<Body>) -> String {
    response
        .headers()
        .get("x-request-id")
        .and_then(|value| value.to_str().ok())
        .expect("response should carry x-request-id")
        .to_string()
}

fn assert_generated_request_id(response: &Response<Body>) {
    let request_id = request_id(response);
    assert!(!request_id.is_empty());
    assert!(request_id.len() <= 128);
    assert!(request_id
        .bytes()
        .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-')));
}

#[tokio::test]
async fn generates_request_id_when_absent() {
    let response = dancam::app(state())
        .oneshot(get("/v1/health").body(Body::empty()).unwrap())
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_generated_request_id(&response);
}

#[tokio::test]
async fn echoes_valid_inbound_request_id() {
    let response = dancam::app(state())
        .oneshot(
            get("/v1/health")
                .header("x-request-id", "corr-123")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(request_id(&response), "corr-123");
}

#[tokio::test]
async fn unknown_path_still_carries_request_id() {
    let response = dancam::app(state())
        .oneshot(get("/v1/nope").body(Body::empty()).unwrap())
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::NOT_FOUND);
    assert_generated_request_id(&response);
}

#[tokio::test]
async fn host_rejection_still_carries_request_id() {
    let response = dancam::app(state())
        .oneshot(
            Request::builder()
                .uri("/v1/health")
                .header("Host", "evil.example:8080")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::MISDIRECTED_REQUEST);
    assert_generated_request_id(&response);
}

#[tokio::test]
async fn rejects_unsafe_inbound_request_id() {
    let unsafe_request_id = "a".repeat(129);

    let response = dancam::app(state())
        .oneshot(
            get("/v1/health")
                .header("x-request-id", unsafe_request_id.as_str())
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_ne!(request_id(&response), unsafe_request_id);
    assert_generated_request_id(&response);
}
