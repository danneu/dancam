use std::{convert::Infallible, time::Duration};

use axum::{body::Body, http::Request, routing::get, Router};
use axum_server::Handle;
use bytes::Bytes;
use dancam::{
    backend::{Backend, MockBackend},
    AppState,
};
use http_body_util::BodyExt;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
    sync::Notify,
};
use tokio_util::sync::CancellationToken;
use tower::ServiceExt;

#[tokio::test]
async fn event_and_preview_streams_end_when_service_cancels() {
    let shutdown = CancellationToken::new();
    let backend = MockBackend::new();
    let app = dancam::app(
        AppState::new("shutdown-stream-test".to_string(), backend.clone())
            .with_shutdown(shutdown.clone()),
    );

    let events = app
        .clone()
        .oneshot(
            Request::builder()
                .uri("/v1/events")
                .header("host", "dancam.local:8080")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let preview = app
        .oneshot(
            Request::builder()
                .uri("/v1/preview/live.mjpeg")
                .header("host", "dancam.local:8080")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let mut events = events.into_body();
    let mut preview = preview.into_body();
    assert!(events.frame().await.is_some());
    assert!(preview.frame().await.is_some());

    shutdown.cancel();
    assert!(
        tokio::time::timeout(Duration::from_millis(250), events.frame())
            .await
            .unwrap()
            .is_none()
    );
    assert!(
        tokio::time::timeout(Duration::from_millis(250), preview.frame())
            .await
            .unwrap()
            .is_none()
    );
    backend.shutdown().await.unwrap();
}

#[tokio::test]
async fn server_drains_finite_work_but_bounds_an_unread_connection() {
    let finite_started = std::sync::Arc::new(Notify::new());
    let finite_notice = finite_started.clone();
    let app = Router::new()
        .route(
            "/finite",
            get(move || {
                let finite_notice = finite_notice.clone();
                async move {
                    finite_notice.notify_one();
                    tokio::time::sleep(Duration::from_millis(50)).await;
                    "complete"
                }
            }),
        )
        .route(
            "/stalled",
            get(|| async {
                let chunks = futures_util::stream::repeat(Ok::<Bytes, Infallible>(
                    Bytes::from_static(&[0_u8; 16 * 1024]),
                ));
                Body::from_stream(chunks)
            }),
        );
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let addr = listener.local_addr().unwrap();
    let handle = Handle::new();
    let server = axum_server::from_tcp(listener)
        .unwrap()
        .handle(handle.clone())
        .serve(app.into_make_service());
    let server = tokio::spawn(server);

    let mut finite = TcpStream::connect(addr).await.unwrap();
    finite
        .write_all(b"GET /finite HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        .await
        .unwrap();
    finite_started.notified().await;
    let mut stalled = TcpStream::connect(addr).await.unwrap();
    stalled
        .write_all(b"GET /stalled HTTP/1.1\r\nHost: localhost\r\n\r\n")
        .await
        .unwrap();
    let mut response_head = [0_u8; 256];
    let bytes = stalled.read(&mut response_head).await.unwrap();
    assert!(String::from_utf8_lossy(&response_head[..bytes]).contains("200 OK"));

    handle.graceful_shutdown(Some(Duration::from_millis(150)));
    let mut finite_response = Vec::new();
    finite.read_to_end(&mut finite_response).await.unwrap();
    assert!(String::from_utf8_lossy(&finite_response).ends_with("complete"));
    tokio::time::timeout(Duration::from_secs(1), server)
        .await
        .expect("unread connection held server past its deadline")
        .unwrap()
        .unwrap();

    let mut tail = Vec::new();
    match tokio::time::timeout(Duration::from_millis(500), stalled.read_to_end(&mut tail)).await {
        Ok(Ok(_)) | Ok(Err(_)) => {}
        Err(_) => panic!("stalled socket remained open after server shutdown"),
    }
}
