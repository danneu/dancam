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
    AppState::new(BOOT_ID.to_string(), MockBackend)
}

#[tokio::test]
async fn health_returns_wire_contract() {
    let response = dancam::app(state())
        .oneshot(
            Request::builder()
                .uri("/v1/health")
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
    let boot_id_header = response
        .headers()
        .get("x-dancam-boot-id")
        .and_then(|value| value.to_str().ok())
        .unwrap()
        .to_string();
    assert_eq!(boot_id_header, BOOT_ID);

    let body = response.into_body().collect().await.unwrap().to_bytes();
    let json: Value = serde_json::from_slice(&body).unwrap();

    assert_eq!(json["boot_id"], BOOT_ID);
    assert_eq!(json["boot_id"], boot_id_header);
    assert!(json["uptime_s"].as_u64().is_some());
    assert_eq!(json["recording"], false);
    assert!(json["t_ms"].as_u64().is_some_and(|t_ms| t_ms > 0));
}

#[tokio::test]
async fn unknown_path_still_carries_proto_headers() {
    let response = dancam::app(state())
        .oneshot(
            Request::builder()
                .uri("/v1/nope")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::NOT_FOUND);
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
}
