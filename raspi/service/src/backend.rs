use std::{pin::Pin, time::Duration};

use async_trait::async_trait;
use axum::{
    http::StatusCode,
    response::{IntoResponse, Response},
};
use bytes::Bytes;
use tokio::sync::watch;
use tokio_stream::{wrappers::WatchStream, Stream, StreamExt};

use crate::status::{CameraState, Status};

pub type FrameStream = Pin<Box<dyn Stream<Item = Bytes> + Send>>;

const MOCK_FRAME_BYTES: [&[u8]; 12] = [
    include_bytes!("../assets/preview/frame_00.jpg"),
    include_bytes!("../assets/preview/frame_01.jpg"),
    include_bytes!("../assets/preview/frame_02.jpg"),
    include_bytes!("../assets/preview/frame_03.jpg"),
    include_bytes!("../assets/preview/frame_04.jpg"),
    include_bytes!("../assets/preview/frame_05.jpg"),
    include_bytes!("../assets/preview/frame_06.jpg"),
    include_bytes!("../assets/preview/frame_07.jpg"),
    include_bytes!("../assets/preview/frame_08.jpg"),
    include_bytes!("../assets/preview/frame_09.jpg"),
    include_bytes!("../assets/preview/frame_10.jpg"),
    include_bytes!("../assets/preview/frame_11.jpg"),
];

#[async_trait]
pub trait Backend: Send + Sync + 'static {
    fn preview_frames(&self) -> FrameStream;
    async fn start_recording(&self) -> Result<(), BackendError>;
    async fn stop_recording(&self) -> Result<(), BackendError>;
    fn status(&self) -> Status;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BackendError {
    CameraOffline,
    Timeout,
    Channel,
}

impl IntoResponse for BackendError {
    fn into_response(self) -> Response {
        let (status, message) = match self {
            BackendError::CameraOffline => (StatusCode::SERVICE_UNAVAILABLE, "camera offline"),
            BackendError::Timeout => (StatusCode::GATEWAY_TIMEOUT, "camera command timed out"),
            BackendError::Channel => (
                StatusCode::INTERNAL_SERVER_ERROR,
                "camera command channel closed",
            ),
        };

        (status, message).into_response()
    }
}

#[derive(Clone)]
pub struct MockBackend {
    frames_tx: watch::Sender<Option<Bytes>>,
    status_tx: watch::Sender<Status>,
    status_rx: watch::Receiver<Status>,
}

impl MockBackend {
    pub fn new() -> Self {
        let (frames_tx, _) = watch::channel::<Option<Bytes>>(None);
        let (status_tx, status_rx) = watch::channel(Status {
            recording: false,
            camera_state: CameraState::Running,
        });

        spawn_mock_frames(frames_tx.clone());

        Self {
            frames_tx,
            status_tx,
            status_rx,
        }
    }
}

impl Default for MockBackend {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl Backend for MockBackend {
    fn preview_frames(&self) -> FrameStream {
        Box::pin(WatchStream::new(self.frames_tx.subscribe()).filter_map(|frame| frame))
    }

    async fn start_recording(&self) -> Result<(), BackendError> {
        let _ = self.status_tx.send(Status {
            recording: true,
            camera_state: CameraState::Running,
        });
        Ok(())
    }

    async fn stop_recording(&self) -> Result<(), BackendError> {
        let _ = self.status_tx.send(Status {
            recording: false,
            camera_state: CameraState::Running,
        });
        Ok(())
    }

    fn status(&self) -> Status {
        self.status_rx.borrow().clone()
    }
}

fn spawn_mock_frames(frames_tx: watch::Sender<Option<Bytes>>) {
    tokio::spawn(async move {
        let mut frames = MOCK_FRAME_BYTES.iter().cycle();
        let mut interval = tokio::time::interval(Duration::from_millis(100));

        loop {
            interval.tick().await;

            let frame = frames
                .next()
                .expect("cycled mock frames should never be exhausted");

            frames_tx.send_replace(Some(Bytes::from_static(frame)));
        }
    });
}
