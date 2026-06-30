use std::{
    path::{Path, PathBuf},
    pin::Pin,
    sync::Arc,
    time::{Duration, Instant},
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
    sync::{oneshot, watch, Mutex},
    task::JoinHandle,
};
use tokio_stream::{wrappers::WatchStream, Stream, StreamExt};

use crate::{
    clips::{clip_meta, max_clip_seq},
    event_hub::{EventConnection, EventHub, SeqEvent},
    events::Snapshot,
    recorder::{RecorderEvent, SegmentId},
    sysfacts::{DiskUsage, MemInfo},
    world::{CameraState, Input, TempC},
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
    fn snapshot(&self) -> Snapshot;
    fn connect(&self) -> EventConnection;
    fn unpullable_from(&self) -> Option<SegmentId>;

    fn set_context(&self, _boot_id: Arc<str>, _started: Instant) {}

    fn tick(&self) {}

    fn update_telemetry(&self, _storage: Option<DiskUsage>, _temp_c: TempC, _mem: Option<MemInfo>) {
    }
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
    hub: Arc<EventHub>,
    recorder: Option<MockRecorder>,
}

impl MockBackend {
    pub fn new() -> Self {
        Self::with_recorder(None)
    }

    pub fn recording_to(rec_dir: PathBuf, roll_interval: Duration) -> Self {
        Self::with_recorder(Some((rec_dir, roll_interval)))
    }

    pub fn tick(&self) {
        self.hub.tick();
    }

    fn with_recorder(recorder: Option<(PathBuf, Duration)>) -> Self {
        let (frames_tx, _) = watch::channel::<Option<Bytes>>(None);
        let hub = Arc::new(EventHub::new(CameraState::Running));
        let recorder = recorder
            .map(|(rec_dir, roll_interval)| MockRecorder::new(rec_dir, roll_interval, hub.clone()));

        spawn_mock_frames(frames_tx.clone());

        Self {
            frames_tx,
            hub,
            recorder,
        }
    }

    fn drive_start_without_writer(&self) {
        let events = self.hub.drive_now(Input::StartCommand { start_segment: 0 });
        let Some(session) = starting_session(&events) else {
            return;
        };
        self.hub
            .drive_now(Input::Recorder(RecorderEvent::RecordingStarted { session }));
        self.hub
            .drive_now(Input::Recorder(RecorderEvent::SegmentOpened {
                session,
                id: 0,
            }));
    }

    fn drive_stop_without_writer(&self) {
        let session = self.hub.session();
        self.hub.drive_now(Input::StopCommand);
        self.hub.drive_now(Input::RecordingStopped {
            session,
            finalized: None,
        });
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
            recorder.start().await
        } else {
            self.drive_start_without_writer();
            Ok(())
        }
    }

    async fn stop_recording(&self) -> Result<(), BackendError> {
        if let Some(recorder) = &self.recorder {
            recorder.stop().await
        } else {
            self.drive_stop_without_writer();
            Ok(())
        }
    }

    fn snapshot(&self) -> Snapshot {
        self.hub.snapshot()
    }

    fn connect(&self) -> EventConnection {
        self.hub.connect()
    }

    fn unpullable_from(&self) -> Option<SegmentId> {
        self.hub.unpullable_from()
    }

    fn set_context(&self, boot_id: Arc<str>, started: Instant) {
        self.hub.set_context(boot_id, started);
    }

    fn tick(&self) {
        self.hub.tick();
    }

    fn update_telemetry(&self, storage: Option<DiskUsage>, temp_c: TempC, mem: Option<MemInfo>) {
        self.hub.update_telemetry(storage, temp_c, mem);
    }
}

#[derive(Clone)]
struct MockRecorder {
    rec_dir: Arc<Path>,
    roll_interval: Duration,
    hub: Arc<EventHub>,
    task: Arc<Mutex<Option<MockRecordingTask>>>,
}

struct MockRecordingTask {
    stop_tx: oneshot::Sender<()>,
    handle: JoinHandle<()>,
}

impl MockRecorder {
    fn new(rec_dir: PathBuf, roll_interval: Duration, hub: Arc<EventHub>) -> Self {
        let roll_interval = if roll_interval.is_zero() {
            Duration::from_millis(1)
        } else {
            roll_interval
        };

        Self {
            rec_dir: Arc::from(rec_dir.into_boxed_path()),
            roll_interval,
            hub,
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
        if guard.as_ref().is_some_and(|task| task.handle.is_finished()) {
            *guard = None;
        }
        if guard.is_some() {
            return Ok(());
        }

        let start_segment = max_clip_seq(self.rec_dir.as_ref())
            .map(|seq| seq.saturating_add(1))
            .unwrap_or(0);
        let events = self.hub.drive_now(Input::StartCommand { start_segment });
        let Some(session) = starting_session(&events) else {
            return Ok(());
        };

        let (stop_tx, stop_rx) = oneshot::channel();
        let rec_dir = self.rec_dir.clone();
        let roll_interval = self.roll_interval;
        let hub = self.hub.clone();
        let handle = tokio::spawn(async move {
            run_mock_recording_writer(rec_dir, roll_interval, hub, session, start_segment, stop_rx)
                .await;
        });
        *guard = Some(MockRecordingTask { stop_tx, handle });

        Ok(())
    }

    async fn stop(&self) -> Result<(), BackendError> {
        let task = {
            let mut guard = self.task.lock().await;
            guard.take()
        };

        let session = self.hub.session();
        self.hub.drive_now(Input::StopCommand);

        if let Some(task) = task {
            let _ = task.stop_tx.send(());
            let _ = task.handle.await;
        } else {
            self.hub.drive_now(Input::RecordingStopped {
                session,
                finalized: None,
            });
        }

        Ok(())
    }
}

async fn run_mock_recording_writer(
    rec_dir: Arc<Path>,
    roll_interval: Duration,
    hub: Arc<EventHub>,
    session: u64,
    mut seq: SegmentId,
    mut stop_rx: oneshot::Receiver<()>,
) {
    let mut file = match open_mock_segment(rec_dir.as_ref(), seq).await {
        Ok(file) => file,
        Err(error) => {
            tracing::error!(%error, seq, "failed to open mock recording segment");
            hub.drive_now(Input::Fail {
                detail: format!("failed to open mock recording segment {seq}: {error}"),
            });
            return;
        }
    };
    hub.drive_now(Input::Recorder(RecorderEvent::RecordingStarted { session }));
    hub.drive_now(Input::Recorder(RecorderEvent::SegmentOpened {
        session,
        id: seq,
    }));

    let mut segment_started = tokio::time::Instant::now();
    let mut interval = tokio::time::interval(Duration::from_millis(100));

    loop {
        tokio::select! {
            _ = &mut stop_rx => {
                if let Err(error) = file.flush().await {
                    tracing::error!(%error, seq, "failed to flush final mock recording segment");
                }
                let finalized = clip_meta(rec_dir.as_ref(), seq, None);
                hub.drive_now(Input::RecordingStopped { session, finalized });
                return;
            }
            _ = interval.tick() => {
                if segment_started.elapsed() >= roll_interval {
                    if let Err(error) = file.flush().await {
                        tracing::error!(%error, seq, "failed to flush mock recording segment");
                        hub.drive_now(Input::Fail {
                            detail: format!("failed to flush mock recording segment {seq}: {error}"),
                        });
                        return;
                    }
                    let finalized = match clip_meta(rec_dir.as_ref(), seq, None) {
                        Some(meta) => meta,
                        None => {
                            tracing::error!(seq, "failed to stat finalized mock recording segment");
                            hub.drive_now(Input::Fail {
                                detail: format!("failed to stat finalized mock recording segment {seq}"),
                            });
                            return;
                        }
                    };
                    seq = seq.saturating_add(1);
                    file = match open_mock_segment(rec_dir.as_ref(), seq).await {
                        Ok(file) => file,
                        Err(error) => {
                            tracing::error!(%error, seq, "failed to roll mock recording segment");
                            hub.drive_now(Input::Fail {
                                detail: format!("failed to roll mock recording segment {seq}: {error}"),
                            });
                            return;
                        }
                    };
                    hub.drive_now(Input::SegmentRollover {
                        session,
                        finalized,
                        opened: seq,
                    });
                    segment_started = tokio::time::Instant::now();
                }

                if let Err(error) = file.write_all(MOCK_RECORDING_CHUNK).await {
                    tracing::error!(%error, seq, "failed to write mock recording segment");
                    hub.drive_now(Input::Fail {
                        detail: format!("failed to write mock recording segment {seq}: {error}"),
                    });
                    return;
                }
            }
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

fn starting_session(events: &[SeqEvent]) -> Option<u64> {
    events.iter().find_map(|event| match event.event {
        crate::events::Event::RecordingStarting { session, .. } => Some(session),
        _ => None,
    })
}
