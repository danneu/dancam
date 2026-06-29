use std::{
    path::{Path, PathBuf},
    pin::Pin,
    sync::Arc,
    time::Duration,
};

use async_trait::async_trait;
use axum::{
    http::StatusCode,
    response::{IntoResponse, Response},
};
use bytes::Bytes;
use tokio::{
    fs::OpenOptions,
    io::AsyncWriteExt,
    sync::{watch, Mutex},
    task::JoinHandle,
};
use tokio_stream::{wrappers::WatchStream, Stream, StreamExt};

use crate::{
    clips::max_clip_seq,
    status::{CameraState, Status},
};

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
const MOCK_RECORDING_CHUNK: &[u8] = b"dancam mock segment bytes\n";

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
    recorder: Option<MockRecorder>,
}

impl MockBackend {
    pub fn new() -> Self {
        Self::with_recorder(None)
    }

    pub fn recording_to(rec_dir: PathBuf, roll_interval: Duration) -> Self {
        Self::with_recorder(Some(MockRecorder::new(rec_dir, roll_interval)))
    }

    fn with_recorder(recorder: Option<MockRecorder>) -> Self {
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
            recorder,
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
        if let Some(recorder) = &self.recorder {
            recorder.start().await?;
        }

        let _ = self.status_tx.send(Status {
            recording: true,
            camera_state: CameraState::Running,
        });
        Ok(())
    }

    async fn stop_recording(&self) -> Result<(), BackendError> {
        if let Some(recorder) = &self.recorder {
            recorder.stop().await;
        }

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

#[derive(Clone)]
struct MockRecorder {
    rec_dir: Arc<Path>,
    roll_interval: Duration,
    task: Arc<Mutex<Option<JoinHandle<()>>>>,
}

impl MockRecorder {
    fn new(rec_dir: PathBuf, roll_interval: Duration) -> Self {
        let roll_interval = if roll_interval.is_zero() {
            Duration::from_millis(1)
        } else {
            roll_interval
        };

        Self {
            rec_dir: Arc::from(rec_dir.into_boxed_path()),
            roll_interval,
            task: Arc::new(Mutex::new(None)),
        }
    }

    async fn start(&self) -> Result<(), BackendError> {
        if let Err(error) = tokio::fs::create_dir_all(self.rec_dir.as_ref()).await {
            let rec_dir = self.rec_dir.display().to_string();
            tracing::error!(%error, rec_dir, "failed to create mock recording directory");
            return Err(BackendError::Channel);
        }

        let mut guard = self.task.lock().await;
        if guard.as_ref().is_some_and(|task| task.is_finished()) {
            *guard = None;
        }
        if guard.is_some() {
            return Ok(());
        }

        let rec_dir = self.rec_dir.clone();
        let roll_interval = self.roll_interval;
        *guard = Some(tokio::spawn(async move {
            run_mock_recording_writer(rec_dir, roll_interval).await;
        }));

        Ok(())
    }

    async fn stop(&self) {
        let task = {
            let mut guard = self.task.lock().await;
            guard.take()
        };

        if let Some(task) = task {
            task.abort();
            let _ = task.await;
        }
    }
}

async fn run_mock_recording_writer(rec_dir: Arc<Path>, roll_interval: Duration) {
    let mut seq = max_clip_seq(rec_dir.as_ref())
        .map(|seq| seq.saturating_add(1))
        .unwrap_or(0);
    let mut file = match open_mock_segment(rec_dir.as_ref(), seq).await {
        Ok(file) => file,
        Err(error) => {
            tracing::error!(%error, seq, "failed to open mock recording segment");
            return;
        }
    };
    let mut segment_started = tokio::time::Instant::now();
    let mut interval = tokio::time::interval(Duration::from_millis(100));

    loop {
        interval.tick().await;

        if segment_started.elapsed() >= roll_interval {
            if let Err(error) = file.flush().await {
                tracing::error!(%error, seq, "failed to flush mock recording segment");
                return;
            }
            seq = seq.saturating_add(1);
            file = match open_mock_segment(rec_dir.as_ref(), seq).await {
                Ok(file) => file,
                Err(error) => {
                    tracing::error!(%error, seq, "failed to roll mock recording segment");
                    return;
                }
            };
            segment_started = tokio::time::Instant::now();
        }

        if let Err(error) = file.write_all(MOCK_RECORDING_CHUNK).await {
            tracing::error!(%error, seq, "failed to write mock recording segment");
            return;
        }
    }
}

async fn open_mock_segment(rec_dir: &Path, seq: u32) -> std::io::Result<tokio::fs::File> {
    OpenOptions::new()
        .create(true)
        .append(true)
        .open(rec_dir.join(format!("seg_{seq:05}.ts")))
        .await
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
