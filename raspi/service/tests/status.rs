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

#[tokio::test]
async fn status_returns_dashboard_wire_contract() {
    let response = dancam::app(state())
        .oneshot(
            Request::builder()
                .uri("/v1/status")
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

    assert_eq!(json["recording"], false);
    assert_eq!(json["camera_state"], "running");
    assert_eq!(json["boot_id"], BOOT_ID);
    assert!(json["uptime_s"].as_u64().is_some());
    assert!(json["storage"].is_object() || json["storage"].is_null());
    assert!(json["temp_c"]["soc"].is_number() || json["temp_c"]["soc"].is_null());
    assert!(json["temp_c"]["sensor"].is_null());
    assert!(json["mem"].is_object() || json["mem"].is_null());
}
