use std::{
    path::Path,
    pin::Pin,
    sync::{Arc, Mutex as StdMutex},
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
    clips::{clip_meta, ClipMeta},
    clock,
    event_hub::{EventConnection, EventHub, SeqEvent},
    events::Snapshot,
    recorder::{
        boot_tag, segment_filename, stamped_segment_filename, RecorderEvent, SegmentFacts,
        SegmentId,
    },
    storage::StorageCoordinator,
    sysfacts::{DiskUsage, MemInfo},
    time_sync::TimeStore,
    ts_duration::{ts_pts_packet, DurationCache},
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
/// 90 kHz PTS ticks per mock packet -- one packet stands in for one 100 ms tick at the
/// TS clock rate, so a segment's PTS span tracks the wall-clock time it stayed open.
const MOCK_PTS_TICKS_PER_PACKET: u64 = 9000;

#[async_trait]
pub trait Backend: Send + Sync + 'static {
    fn preview_frames(&self) -> FrameStream;
    async fn start_recording(&self) -> Result<(), BackendError>;
    async fn stop_recording(&self) -> Result<(), BackendError>;
    fn snapshot(&self) -> Snapshot;
    fn connect(&self) -> EventConnection;
    fn unpullable_from(&self) -> Option<SegmentId>;
    fn note_clip_removed(&self, id: SegmentId);

    /// The cache the finalize path and `/v1/clips` share so a finished segment's
    /// `dur_ms` is computed once from its file and reused, not recomputed at list time.
    fn clip_durations(&self) -> Arc<DurationCache>;

    fn time_store(&self) -> Arc<TimeStore> {
        Arc::new(TimeStore::in_memory())
    }

    fn mark_time_synced(&self) {}

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
    Storage,
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
            BackendError::Storage => (
                StatusCode::INTERNAL_SERVER_ERROR,
                "storage allocation failed",
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
    clip_durations: Arc<DurationCache>,
    time_store: Arc<TimeStore>,
    boot_tag: Arc<StdMutex<Option<String>>>,
}

impl MockBackend {
    pub fn new() -> Self {
        Self::with_recorder(None)
    }

    pub fn recording_to(storage: Arc<StorageCoordinator>, roll_interval: Duration) -> Self {
        Self::with_recorder(Some((storage, roll_interval)))
    }

    pub fn tick(&self) {
        self.hub.tick();
    }

    fn with_recorder(recorder: Option<(Arc<StorageCoordinator>, Duration)>) -> Self {
        let (frames_tx, _) = watch::channel::<Option<Bytes>>(None);
        let hub = Arc::new(EventHub::new(CameraState::Running));
        let clip_durations = Arc::new(DurationCache::new());
        let time_store = Arc::new(
            recorder
                .as_ref()
                .map(|(storage, _)| TimeStore::load(storage.rec_dir().join("time")))
                .unwrap_or_else(TimeStore::in_memory),
        );
        let boot_tag = Arc::new(StdMutex::new(None));
        let recorder = recorder.map(|(storage, roll_interval)| {
            MockRecorder::new(
                storage,
                roll_interval,
                hub.clone(),
                clip_durations.clone(),
                time_store.clone(),
                boot_tag.clone(),
            )
        });

        spawn_mock_frames(frames_tx.clone());

        Self {
            frames_tx,
            hub,
            recorder,
            clip_durations,
            time_store,
            boot_tag,
        }
    }

    fn drive_start_without_writer(&self) {
        // Recorder-less mock state has no recording directory and performs no storage mutation.
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

    fn note_clip_removed(&self, id: SegmentId) {
        self.hub.drive_now(Input::ClipRemoved { id });
    }

    fn clip_durations(&self) -> Arc<DurationCache> {
        self.clip_durations.clone()
    }

    fn time_store(&self) -> Arc<TimeStore> {
        self.time_store.clone()
    }

    fn mark_time_synced(&self) {
        self.hub.drive_now(Input::TimeSynced);
    }

    fn set_context(&self, boot_id: Arc<str>, started: Instant) {
        self.hub.set_context(boot_id, started);
        self.time_store
            .set_boot_id(self.hub.snapshot().boot_id.as_str());
        *self.boot_tag.lock().expect("mock boot_tag mutex poisoned") =
            boot_tag(self.hub.snapshot().boot_id.as_str());
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
    storage: Arc<StorageCoordinator>,
    rec_dir: Arc<Path>,
    roll_interval: Duration,
    hub: Arc<EventHub>,
    clip_durations: Arc<DurationCache>,
    time_store: Arc<TimeStore>,
    boot_tag: Arc<StdMutex<Option<String>>>,
    task: Arc<Mutex<Option<MockRecordingTask>>>,
}

struct MockRecordingTask {
    stop_tx: oneshot::Sender<()>,
    handle: JoinHandle<()>,
}

struct MockRecordingContext {
    rec_dir: Arc<Path>,
    roll_interval: Duration,
    hub: Arc<EventHub>,
    clip_durations: Arc<DurationCache>,
    time_store: Arc<TimeStore>,
    boot_tag: Arc<StdMutex<Option<String>>>,
    session: u64,
    start_segment: SegmentId,
}

impl MockRecorder {
    fn new(
        storage: Arc<StorageCoordinator>,
        roll_interval: Duration,
        hub: Arc<EventHub>,
        clip_durations: Arc<DurationCache>,
        time_store: Arc<TimeStore>,
        boot_tag: Arc<StdMutex<Option<String>>>,
    ) -> Self {
        let roll_interval = if roll_interval.is_zero() {
            Duration::from_millis(1)
        } else {
            roll_interval
        };

        let rec_dir = storage.rec_dir();
        Self {
            storage,
            rec_dir,
            roll_interval,
            hub,
            clip_durations,
            time_store,
            boot_tag,
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

        let (start_segment, events) = self
            .storage
            .reserve_start_segment(|seg| {
                self.hub
                    .drive_now(Input::StartCommand { start_segment: seg })
            })
            .map_err(|error| {
                tracing::error!(%error, "start segment allocation failed");
                BackendError::Storage
            })?;
        let Some(session) = starting_session(&events) else {
            return Ok(());
        };

        let (stop_tx, stop_rx) = oneshot::channel();
        let rec_dir = self.rec_dir.clone();
        let roll_interval = self.roll_interval;
        let hub = self.hub.clone();
        let clip_durations = self.clip_durations.clone();
        let time_store = self.time_store.clone();
        let boot_tag = self.boot_tag.clone();
        let context = MockRecordingContext {
            rec_dir,
            roll_interval,
            hub,
            clip_durations,
            time_store,
            boot_tag,
            session,
            start_segment,
        };
        let handle = tokio::spawn(async move {
            run_mock_recording_writer(context, stop_rx).await;
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
    context: MockRecordingContext,
    mut stop_rx: oneshot::Receiver<()>,
) {
    let MockRecordingContext {
        rec_dir,
        roll_interval,
        hub,
        clip_durations,
        time_store,
        boot_tag,
        session,
        start_segment,
    } = context;
    let mut seq = start_segment;
    let mut file = match open_mock_segment(rec_dir.as_ref(), seq, boot_tag.as_ref()).await {
        Ok(file) => file,
        Err(error) => {
            tracing::error!(%error, seq, "failed to open mock recording segment");
            hub.drive_now(Input::Fail {
                detail: format!("failed to open mock recording segment {seq}: {error}"),
            });
            return;
        }
    };
    // Monotonic across the whole writer lifetime, so every packet's PTS strictly
    // increases regardless of tick scheduling: any segment with >= 2 packets has a
    // positive span by construction (a wall-clock PTS would collapse burst-fired ticks
    // onto one value). The open-time packet is each segment's first.
    let mut packet_index: u64 = 0;
    if let Err(error) = write_mock_packet(&mut file, &mut packet_index).await {
        tracing::error!(%error, seq, "failed to write mock recording segment");
        hub.drive_now(Input::Fail {
            detail: format!("failed to write mock recording segment {seq}: {error}"),
        });
        return;
    }
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
                let finalized =
                    finalized_clip_meta(rec_dir.clone(), seq, clip_durations.clone(), time_store.clone())
                        .await;
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
                    let finalized = match finalized_clip_meta(
                        rec_dir.clone(),
                        seq,
                        clip_durations.clone(),
                        time_store.clone(),
                    )
                    .await
                    {
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
                    file = match open_mock_segment(rec_dir.as_ref(), seq, boot_tag.as_ref()).await {
                        Ok(file) => file,
                        Err(error) => {
                            tracing::error!(%error, seq, "failed to roll mock recording segment");
                            hub.drive_now(Input::Fail {
                                detail: format!("failed to roll mock recording segment {seq}: {error}"),
                            });
                            return;
                        }
                    };
                    if let Err(error) = write_mock_packet(&mut file, &mut packet_index).await {
                        tracing::error!(%error, seq, "failed to write mock recording segment");
                        hub.drive_now(Input::Fail {
                            detail: format!("failed to write mock recording segment {seq}: {error}"),
                        });
                        return;
                    }
                    hub.drive_now(Input::SegmentRollover {
                        session,
                        finalized,
                        opened: seq,
                    });
                    segment_started = tokio::time::Instant::now();
                }

                if let Err(error) = write_mock_packet(&mut file, &mut packet_index).await {
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

/// Append one PTS-bearing TS packet and advance the lifetime packet counter, so each
/// write lands a strictly larger PTS than the last.
async fn write_mock_packet(
    file: &mut tokio::fs::File,
    packet_index: &mut u64,
) -> std::io::Result<()> {
    let packet = ts_pts_packet(*packet_index * MOCK_PTS_TICKS_PER_PACKET);
    file.write_all(&packet).await?;
    *packet_index += 1;
    Ok(())
}

async fn finalized_clip_meta(
    rec_dir: Arc<Path>,
    seq: SegmentId,
    clip_durations: Arc<DurationCache>,
    time_store: Arc<TimeStore>,
) -> Option<ClipMeta> {
    match tokio::task::spawn_blocking(move || {
        clip_meta(
            rec_dir.as_ref(),
            seq,
            Some(clip_durations.as_ref()),
            time_store.as_ref(),
        )
    })
    .await
    {
        Ok(Ok(meta)) => meta,
        Ok(Err(error)) => {
            tracing::error!(%error, seq, "failed to stat finalized mock recording segment");
            None
        }
        Err(error) => {
            tracing::error!(%error, seq, "mock clip metadata task failed");
            None
        }
    }
}

async fn open_mock_segment(
    rec_dir: &Path,
    seq: u32,
    boot_tag: &StdMutex<Option<String>>,
) -> std::io::Result<tokio::fs::File> {
    let filename = boot_tag
        .lock()
        .expect("mock boot_tag mutex poisoned")
        .clone()
        .map(|boot_tag| {
            stamped_segment_filename(
                seq,
                &SegmentFacts {
                    boot_tag,
                    mono_ms: clock::boottime_ms(),
                },
            )
        })
        .unwrap_or_else(|| segment_filename(seq));

    OpenOptions::new()
        .create(true)
        .append(true)
        .open(rec_dir.join(filename))
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
