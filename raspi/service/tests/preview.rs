use std::pin::Pin;

use async_trait::async_trait;
use axum::{
    body::Body,
    http::{header, Request, StatusCode},
};
use bytes::Bytes;
use http_body_util::BodyExt;
use tokio_stream::Stream;
use tower::ServiceExt;

use dancam::{
    backend::{Backend, BackendError, FrameStream},
    event_hub::{EventConnection, EventHub},
    events::Snapshot,
    preview::frame_part,
    recorder::SegmentId,
    world::CameraState,
    AppState,
};

const BOOT_ID: &str = "3f1c0e7a-8f3b-4e15-b196-20e0416af749";

struct StubBackend {
    frames: Vec<Bytes>,
    hub: EventHub,
}

#[async_trait]
impl Backend for StubBackend {
    fn preview_frames(&self) -> FrameStream {
        let frames = self.frames.clone();
        Box::pin(tokio_stream::iter(frames)) as Pin<Box<dyn Stream<Item = Bytes> + Send>>
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
        None
    }

    fn note_clip_removed(&self, _id: SegmentId) {}
}

fn state(frames: Vec<Bytes>) -> AppState {
    AppState::new(
        BOOT_ID.to_string(),
        StubBackend {
            frames,
            hub: EventHub::new(CameraState::Running),
        },
    )
}

#[tokio::test]
async fn live_mjpeg_streams_multipart_frames_in_order() {
    let f0 = Bytes::from_static(b"frame-zero");
    let f1 = Bytes::from_static(b"frame-one");

    let response = dancam::app(state(vec![f0.clone(), f1.clone()]))
        .oneshot(
            Request::builder()
                .uri("/v1/preview/live.mjpeg")
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
                .header("Host", "localhost:8080")
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
