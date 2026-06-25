use std::convert::Infallible;

use axum::{
    body::Body,
    extract::State,
    http::{
        header::{CACHE_CONTROL, CONTENT_TYPE},
        HeaderValue, Response,
    },
};
use bytes::{Bytes, BytesMut};
use tokio_stream::StreamExt;

use crate::AppState;

pub const BOUNDARY: &str = "dancamframe";
pub const CONTENT_TYPE_VALUE: &str = "multipart/x-mixed-replace; boundary=dancamframe";

pub async fn live_mjpeg(State(state): State<AppState>) -> Response<Body> {
    let frames = state
        .backend
        .preview_frames()
        .map(|frame| Ok::<Bytes, Infallible>(frame_part(&frame)));

    let mut response = Response::new(Body::from_stream(frames));
    response
        .headers_mut()
        .insert(CONTENT_TYPE, HeaderValue::from_static(CONTENT_TYPE_VALUE));
    response
        .headers_mut()
        .insert(CACHE_CONTROL, HeaderValue::from_static("no-store"));

    response
}

pub fn frame_part(frame: &[u8]) -> Bytes {
    let head = format!(
        "--{BOUNDARY}\r\nContent-Type: image/jpeg\r\nContent-Length: {}\r\n\r\n",
        frame.len()
    );
    let mut part = BytesMut::with_capacity(head.len() + frame.len() + 2);
    part.extend_from_slice(head.as_bytes());
    part.extend_from_slice(frame);
    part.extend_from_slice(b"\r\n");
    part.freeze()
}
