use std::pin::Pin;

use axum::{
    body::Body,
    http::{header, Request, StatusCode},
};
use bytes::Bytes;
use http_body_util::BodyExt;
use tokio_stream::Stream;
use tower::ServiceExt;

use dancam::{
    backend::{Backend, FrameStream},
    preview::frame_part,
    AppState,
};

const BOOT_ID: &str = "3f1c0e7a-8f3b-4e15-b196-20e0416af749";

struct StubBackend {
    frames: Vec<Bytes>,
}

impl Backend for StubBackend {
    fn recording(&self) -> bool {
        false
    }

    fn preview_frames(&self) -> FrameStream {
        let frames = self.frames.clone();
        Box::pin(tokio_stream::iter(frames)) as Pin<Box<dyn Stream<Item = Bytes> + Send>>
    }
}

fn state(frames: Vec<Bytes>) -> AppState {
    AppState::new(BOOT_ID.to_string(), StubBackend { frames })
}

#[tokio::test]
async fn live_mjpeg_streams_multipart_frames_in_order() {
    let f0 = Bytes::from_static(b"frame-zero");
    let f1 = Bytes::from_static(b"frame-one");

    let response = dancam::app(state(vec![f0.clone(), f1.clone()]))
        .oneshot(
            Request::builder()
                .uri("/v1/preview/live.mjpeg")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(
        response
            .headers()
            .get(header::CONTENT_TYPE)
            .and_then(|value| value.to_str().ok()),
        Some("multipart/x-mixed-replace; boundary=dancamframe")
    );

    let body = response.into_body().collect().await.unwrap().to_bytes();
    let mut expected = Vec::new();
    expected.extend_from_slice(&frame_part(&f0));
    expected.extend_from_slice(&frame_part(&f1));
    assert_eq!(body.as_ref(), expected.as_slice());
}

#[tokio::test]
async fn live_mjpeg_carries_proto_headers() {
    let response = dancam::app(state(vec![Bytes::from_static(b"frame")]))
        .oneshot(
            Request::builder()
                .uri("/v1/preview/live.mjpeg")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();

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
    assert_eq!(
        response
            .headers()
            .get(header::CACHE_CONTROL)
            .and_then(|value| value.to_str().ok()),
        Some("no-store")
    );
}
