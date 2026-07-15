use axum::{
    body::Body,
    http::{Request, StatusCode},
};
use tower::ServiceExt;

use dancam::{backend::MockBackend, AppState};

const BOOT_ID: &str = "3f1c0e7a-8f3b-4e15-b196-20e0416af749";

fn state() -> AppState {
    AppState::new(BOOT_ID.to_string(), MockBackend::new())
}

#[tokio::test]
async fn status_is_the_only_operational_probe() {
    for path in ["/v1/health", "/v1/live", "/v1/ready", "/v1/ping"] {
        let response = dancam::app(state())
            .oneshot(
                Request::builder()
                    .uri(path)
                    .header("Host", "localhost:8080")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NOT_FOUND, "{path}");
    }

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
}

#[tokio::test]
async fn unknown_path_still_carries_proto_headers() {
    let response = dancam::app(state())
        .oneshot(
            Request::builder()
                .uri("/v1/nope")
                .header("Host", "localhost:8080")
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
