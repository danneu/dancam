use std::{
    env,
    path::{Path, PathBuf},
    process::Stdio,
    sync::Arc,
    time::{Duration, Instant},
};

use async_trait::async_trait;
use bytes::Bytes;
use tokio::{
    io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWriteExt, BufReader},
    process::{Child, ChildStdout, Command as TokioCommand},
    sync::{mpsc, oneshot, watch},
};
use tokio_stream::{wrappers::WatchStream, StreamExt};

use crate::{
    backend::{Backend, BackendError, FrameStream},
    clips::{clip_meta, ClipMeta},
    cpu::Cpu,
    event_hub::{EventConnection, EventHub},
    events::Event,
    events::Snapshot,
    jpeg::JpegSplitter,
    recorder::{RecorderEvent, RecorderPhase, SegmentId},
    storage::StorageCoordinator,
    sysfacts::{DiskUsage, MemInfo},
    time_sync::TimeStore,
    ts_duration::DurationCache,
    world::{CameraState, Input, LiveStatus},
};

const COMMAND_CAPACITY: usize = 8;
const COMMAND_TIMEOUT: Duration = Duration::from_secs(3);
const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(2);
const BACKOFF_BASE: Duration = Duration::from_millis(250);
const BACKOFF_CAP: Duration = Duration::from_secs(10);
const BACKOFF_RESET_AFTER: Duration = Duration::from_secs(30);

#[derive(Clone, Debug)]
pub struct CameraConfig {
    program: String,
    args: Vec<String>,
    rec_dir: PathBuf,
}

impl CameraConfig {
    pub fn new(
        program: impl Into<String>,
        args: impl IntoIterator<Item = impl Into<String>>,
    ) -> Self {
        let args = args.into_iter().map(Into::into).collect::<Vec<_>>();
        let rec_dir = rec_dir_arg(&args).unwrap_or_else(|| PathBuf::from(crate::DEFAULT_REC_DIR));
        Self {
            program: program.into(),
            args,
            rec_dir,
        }
    }

    pub fn from_env() -> Self {
        if let Ok(raw_command) = env::var("DANCAM_CAMERA_CMD") {
            let mut parts = raw_command.split_whitespace();
            if let Some(program) = parts.next() {
                return Self::new(program, parts);
            }
        }

        let rec_dir =
            env::var("DANCAM_REC_DIR").unwrap_or_else(|_| crate::DEFAULT_REC_DIR.to_string());
        let preview_fps = env::var("DANCAM_PREVIEW_FPS").unwrap_or_else(|_| "10".to_string());
        let mut config = Self::new(
            "python3",
            [
                "/usr/local/lib/dancam/camera.py".to_string(),
                "--rec-dir".to_string(),
                rec_dir.clone(),
                "--preview-fps".to_string(),
                preview_fps,
            ],
        );
        config.rec_dir = PathBuf::from(rec_dir);
        config
    }

    pub fn rec_dir(&self) -> &Path {
        &self.rec_dir
    }
}

fn rec_dir_arg(args: &[String]) -> Option<PathBuf> {
    args.iter()
        .find_map(|arg| arg.strip_prefix("--rec-dir=").map(PathBuf::from))
        .or_else(|| {
            args.windows(2)
                .find_map(|window| (window[0] == "--rec-dir").then(|| PathBuf::from(&window[1])))
        })
}

#[derive(Clone)]
pub struct CameraBackend {
    frames_tx: watch::Sender<Option<Bytes>>,
    hub: Arc<EventHub>,
    storage: Arc<StorageCoordinator>,
    commands_tx: mpsc::Sender<Command>,
    clip_durations: Arc<DurationCache>,
    time_store: Arc<TimeStore>,
}

pub struct CameraProcess;

impl CameraProcess {
    pub fn spawn(
        config: CameraConfig,
        storage: Arc<StorageCoordinator>,
    ) -> (CameraBackend, SupervisorControl) {
        let (frames_tx, _) = watch::channel::<Option<Bytes>>(None);
        let hub = Arc::new(EventHub::new(CameraState::Starting));
        let (commands_tx, commands_rx) = mpsc::channel(COMMAND_CAPACITY);
        let (shutdown_tx, shutdown_rx) = oneshot::channel();
        let clip_durations = Arc::new(DurationCache::new());
        let time_store = {
            let mut store = TimeStore::load(config.rec_dir.join("time"));
            if let Some(mountpoint) = storage.required_mountpoint() {
                store = store.with_required_mountpoint(mountpoint.as_ref().to_path_buf());
            }
            Arc::new(store)
        };

        let supervisor = tokio::spawn(supervise(
            config,
            frames_tx.clone(),
            hub.clone(),
            commands_rx,
            shutdown_rx,
            clip_durations.clone(),
            time_store.clone(),
        ));

        let backend = CameraBackend {
            frames_tx,
            hub,
            storage,
            commands_tx,
            clip_durations,
            time_store,
        };
        let control = SupervisorControl {
            shutdown_tx: Some(shutdown_tx),
            supervisor,
        };

        (backend, control)
    }
}

pub struct SupervisorControl {
    shutdown_tx: Option<oneshot::Sender<()>>,
    supervisor: tokio::task::JoinHandle<()>,
}

impl SupervisorControl {
    pub async fn shutdown(mut self) {
        if let Some(shutdown_tx) = self.shutdown_tx.take() {
            let _ = shutdown_tx.send(());
        }

        let _ =
            tokio::time::timeout(SHUTDOWN_TIMEOUT + Duration::from_secs(1), self.supervisor).await;
    }
}

#[async_trait]
impl Backend for CameraBackend {
    fn preview_frames(&self) -> FrameStream {
        Box::pin(WatchStream::new(self.frames_tx.subscribe()).filter_map(|frame| frame))
    }

    async fn start_recording(&self) -> Result<(), BackendError> {
        if self.hub.phase() == RecorderPhase::Recording {
            return Ok(());
        }
        if self.hub.live_status().camera_state != CameraState::Running {
            return Err(BackendError::CameraOffline);
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

        self.command_and_wait(
            ChildCommand::StartRecording {
                session_id: session,
                start_segment_index: start_segment,
            },
            |status| status.phase == RecorderPhase::Recording,
        )
        .await
    }

    async fn stop_recording(&self) -> Result<(), BackendError> {
        if self.hub.phase() == RecorderPhase::Idle {
            return Ok(());
        }
        if self.hub.live_status().camera_state != CameraState::Running {
            return Err(BackendError::CameraOffline);
        }

        let events = self.hub.drive_now(Input::StopCommand);
        if !has_recording_stopping(&events) {
            return Ok(());
        }

        self.command_and_wait(ChildCommand::StopRecording, |status| {
            status.phase == RecorderPhase::Idle
        })
        .await
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
    }

    fn tick(&self) {
        self.hub.tick();
    }

    fn update_telemetry(
        &self,
        storage: Option<DiskUsage>,
        soc_temp_c: Option<f32>,
        mem: Option<MemInfo>,
        cpu: Cpu,
    ) {
        self.hub.update_telemetry(storage, soc_temp_c, mem, cpu);
    }
}

impl CameraBackend {
    async fn command_and_wait(
        &self,
        command: ChildCommand,
        predicate: impl Fn(&LiveStatus) -> bool,
    ) -> Result<(), BackendError> {
        let mut live_rx = self.hub.live_rx();
        if predicate(&live_rx.borrow()) {
            return Ok(());
        }

        if live_rx.borrow().camera_state != CameraState::Running {
            return Err(BackendError::CameraOffline);
        }

        let (ack_tx, ack_rx) = oneshot::channel();
        self.commands_tx
            .send(Command { command, ack_tx })
            .await
            .map_err(|_| BackendError::Channel)?;
        ack_rx.await.map_err(|_| BackendError::Channel)??;
        let status = live_rx.borrow().clone();
        if predicate(&status) {
            return Ok(());
        }
        if command_failed(&status) {
            return Err(BackendError::CameraOffline);
        }

        tokio::time::timeout(COMMAND_TIMEOUT, async {
            loop {
                live_rx.changed().await.map_err(|_| BackendError::Channel)?;
                let status = live_rx.borrow_and_update().clone();
                if predicate(&status) {
                    return Ok(());
                }
                if command_failed(&status) {
                    return Err(BackendError::CameraOffline);
                }
            }
        })
        .await
        .map_err(|_| BackendError::Timeout)?
    }
}

struct Command {
    command: ChildCommand,
    ack_tx: oneshot::Sender<Result<(), BackendError>>,
}

#[derive(Clone, Debug, serde::Serialize)]
#[serde(tag = "cmd", rename_all = "snake_case")]
enum ChildCommand {
    StartRecording {
        session_id: u64,
        start_segment_index: SegmentId,
    },
    StopRecording,
    Shutdown,
}

#[derive(Clone, Debug, serde::Deserialize, PartialEq)]
#[serde(tag = "event", rename_all = "snake_case")]
enum ChildEvent {
    Ready,
    SensorTemp {
        #[serde(deserialize_with = "required_nullable_f32")]
        celsius: Option<f32>,
    },
    RecordingStarted {
        #[serde(rename = "session_id")]
        session: u64,
    },
    SegmentOpened {
        #[serde(rename = "session_id")]
        session: u64,
        id: SegmentId,
    },
    SegmentClosed {
        #[serde(rename = "session_id")]
        session: u64,
        id: SegmentId,
    },
    RecordingStopped {
        #[serde(rename = "session_id")]
        session: u64,
    },
    Error {
        #[serde(default)]
        detail: String,
    },
}

fn required_nullable_f32<'de, D>(deserializer: D) -> Result<Option<f32>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    <Option<f32> as serde::Deserialize>::deserialize(deserializer)
}

async fn supervise(
    config: CameraConfig,
    frames_tx: watch::Sender<Option<Bytes>>,
    hub: Arc<EventHub>,
    mut commands_rx: mpsc::Receiver<Command>,
    mut shutdown_rx: oneshot::Receiver<()>,
    clip_durations: Arc<DurationCache>,
    time_store: Arc<TimeStore>,
) {
    let mut backoff = BACKOFF_BASE;

    loop {
        hub.drive_now(Input::CameraState(CameraState::Starting));
        let started = Instant::now();

        match spawn_child(&config).await {
            Ok(child) => {
                let runtime = ChildRuntime {
                    frames_tx: frames_tx.clone(),
                    hub: hub.clone(),
                    rec_dir: Arc::from(config.rec_dir.clone().into_boxed_path()),
                    clip_durations: clip_durations.clone(),
                    time_store: time_store.clone(),
                };
                match run_child(child, runtime, &mut commands_rx, &mut shutdown_rx).await {
                    ChildOutcome::Shutdown => {
                        frames_tx.send_replace(None);
                        hub.drive_now(Input::CameraState(CameraState::Offline));
                        hub.drive_now(Input::Fail {
                            detail: "camera supervisor shut down".to_string(),
                        });
                        return;
                    }
                    ChildOutcome::Exited => {
                        frames_tx.send_replace(None);
                        hub.drive_now(Input::CameraState(CameraState::Restarting));
                        hub.drive_now(Input::Fail {
                            detail: "camera process exited".to_string(),
                        });
                    }
                }

                if started.elapsed() >= BACKOFF_RESET_AFTER {
                    backoff = BACKOFF_BASE;
                }
            }
            Err(error) => {
                tracing::error!(%error, "failed to start camera child");
                frames_tx.send_replace(None);
                hub.drive_now(Input::CameraState(CameraState::Restarting));
                hub.drive_now(Input::Fail {
                    detail: format!("failed to start camera child: {error}"),
                });
            }
        }

        tokio::select! {
            _ = tokio::time::sleep(backoff) => {}
            _ = &mut shutdown_rx => {
                hub.drive_now(Input::CameraState(CameraState::Offline));
                hub.drive_now(Input::Fail {
                    detail: "camera supervisor shut down".to_string(),
                });
                return;
            }
        }
        backoff = (backoff * 2).min(BACKOFF_CAP);
    }
}

async fn spawn_child(config: &CameraConfig) -> std::io::Result<Child> {
    TokioCommand::new(&config.program)
        .args(&config.args)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
}

enum ChildOutcome {
    Exited,
    Shutdown,
}

struct ChildRuntime {
    frames_tx: watch::Sender<Option<Bytes>>,
    hub: Arc<EventHub>,
    rec_dir: Arc<Path>,
    clip_durations: Arc<DurationCache>,
    time_store: Arc<TimeStore>,
}

async fn run_child(
    mut child: Child,
    runtime: ChildRuntime,
    commands_rx: &mut mpsc::Receiver<Command>,
    shutdown_rx: &mut oneshot::Receiver<()>,
) -> ChildOutcome {
    let ChildRuntime {
        frames_tx,
        hub,
        rec_dir,
        clip_durations,
        time_store,
    } = runtime;

    let Some(stdout) = child.stdout.take() else {
        tracing::error!("camera child stdout was not piped");
        let _ = child.kill().await;
        let _ = child.wait().await;
        return ChildOutcome::Exited;
    };
    let Some(stderr) = child.stderr.take() else {
        tracing::error!("camera child stderr was not piped");
        let _ = child.kill().await;
        let _ = child.wait().await;
        return ChildOutcome::Exited;
    };
    let Some(mut stdin) = child.stdin.take() else {
        tracing::error!("camera child stdin was not piped");
        let _ = child.kill().await;
        let _ = child.wait().await;
        return ChildOutcome::Exited;
    };

    let stdout_task = tokio::spawn(drain_stdout(stdout, frames_tx));
    let stderr_task = tokio::spawn(parse_stderr(
        stderr,
        hub,
        rec_dir,
        clip_durations,
        time_store,
    ));

    loop {
        tokio::select! {
            command = commands_rx.recv() => {
                let Some(command) = command else {
                    let _ = write_command(&mut stdin, &ChildCommand::Shutdown).await;
                    let _ = child.wait().await;
                    stdout_task.abort();
                    stderr_task.abort();
                    return ChildOutcome::Shutdown;
                };

                let result = write_command(&mut stdin, &command.command).await;
                let _ = command.ack_tx.send(result);
            }
            wait_result = child.wait() => {
                if let Err(error) = wait_result {
                    tracing::warn!(%error, "failed waiting for camera child");
                }
                stdout_task.abort();
                stderr_task.abort();
                return ChildOutcome::Exited;
            }
            _ = &mut *shutdown_rx => {
                let _ = write_command(&mut stdin, &ChildCommand::Shutdown).await;
                if tokio::time::timeout(SHUTDOWN_TIMEOUT, child.wait()).await.is_err() {
                    let _ = child.kill().await;
                    let _ = child.wait().await;
                }
                stdout_task.abort();
                stderr_task.abort();
                return ChildOutcome::Shutdown;
            }
        }
    }
}

async fn write_command(
    stdin: &mut tokio::process::ChildStdin,
    command: &ChildCommand,
) -> Result<(), BackendError> {
    let mut line = serde_json::to_vec(command).map_err(|_| BackendError::Channel)?;
    line.push(b'\n');
    stdin
        .write_all(&line)
        .await
        .map_err(|_| BackendError::CameraOffline)?;
    stdin.flush().await.map_err(|_| BackendError::CameraOffline)
}

async fn drain_stdout(mut stdout: ChildStdout, frames_tx: watch::Sender<Option<Bytes>>) {
    let mut splitter = JpegSplitter::new();
    let mut buffer = [0_u8; 8192];

    loop {
        match stdout.read(&mut buffer).await {
            Ok(0) => return,
            Ok(bytes_read) => {
                for frame in splitter.push(&buffer[..bytes_read]) {
                    frames_tx.send_replace(Some(Bytes::from(frame)));
                }
            }
            Err(error) => {
                tracing::warn!(%error, "failed reading camera child stdout");
                return;
            }
        }
    }
}

async fn parse_stderr(
    stderr: impl AsyncRead + Unpin + Send + 'static,
    hub: Arc<EventHub>,
    rec_dir: Arc<Path>,
    clip_durations: Arc<DurationCache>,
    time_store: Arc<TimeStore>,
) {
    let mut lines = BufReader::new(stderr).lines();
    let mut last_opened: Option<(u64, SegmentId)> = None;
    let mut pending_closed: Option<(u64, SegmentId)> = None;

    while let Ok(Some(line)) = lines.next_line().await {
        match serde_json::from_str::<ChildEvent>(&line) {
            Ok(ChildEvent::Ready) => {
                hub.drive_now(Input::CameraState(CameraState::Running));
            }
            Ok(ChildEvent::SensorTemp { celsius }) => {
                hub.drive_now(Input::SensorTemp {
                    celsius: celsius.filter(|value| value.is_finite()),
                });
            }
            Ok(ChildEvent::RecordingStarted { session }) => {
                hub.drive_now(Input::Recorder(RecorderEvent::RecordingStarted { session }));
            }
            Ok(ChildEvent::SegmentOpened { session, id }) => {
                if let Some((closed_session, closed_id)) = pending_closed.take() {
                    if closed_session == session {
                        match finalized_clip_meta(
                            rec_dir.clone(),
                            closed_id,
                            clip_durations.clone(),
                            time_store.clone(),
                        )
                        .await
                        {
                            Some(finalized) => {
                                hub.drive_now(Input::SegmentRollover {
                                    session,
                                    finalized,
                                    opened: id,
                                });
                                last_opened = Some((session, id));
                            }
                            None => {
                                hub.drive_now(Input::Fail {
                                    detail: format!("failed to stat finalized segment {closed_id}"),
                                });
                            }
                        }
                    } else {
                        tracing::warn!(
                            closed_session,
                            opened_session = session,
                            "dropping cross-session segment rollover"
                        );
                        hub.drive_now(Input::Recorder(RecorderEvent::SegmentOpened {
                            session,
                            id,
                        }));
                        last_opened = Some((session, id));
                    }
                } else {
                    hub.drive_now(Input::Recorder(RecorderEvent::SegmentOpened {
                        session,
                        id,
                    }));
                    last_opened = Some((session, id));
                }
            }
            Ok(ChildEvent::SegmentClosed { session, id }) => {
                pending_closed = Some((session, id));
            }
            Ok(ChildEvent::RecordingStopped { session }) => {
                let mut final_stat_failed = false;
                let finalized = match last_opened {
                    Some((opened_session, id)) if opened_session == session => {
                        match finalized_clip_meta(
                            rec_dir.clone(),
                            id,
                            clip_durations.clone(),
                            time_store.clone(),
                        )
                        .await
                        {
                            Some(finalized) => Some(finalized),
                            None => {
                                final_stat_failed = true;
                                hub.drive_now(Input::Fail {
                                    detail: format!("failed to stat final segment {id}"),
                                });
                                None
                            }
                        }
                    }
                    _ => None,
                };
                if !final_stat_failed {
                    hub.drive_now(Input::RecordingStopped { session, finalized });
                }
                pending_closed = None;
                last_opened = None;
            }
            Ok(ChildEvent::Error { detail }) => {
                tracing::error!(%detail, "camera child error event");
                hub.drive_now(Input::Fail { detail });
            }
            Err(_) => {
                tracing::info!(line = %line, "camera child stderr");
            }
        }
    }
}

fn starting_session(events: &[crate::event_hub::SeqEvent]) -> Option<u64> {
    events.iter().find_map(|event| match event.event {
        Event::RecordingStarting { session, .. } => Some(session),
        _ => None,
    })
}

fn has_recording_stopping(events: &[crate::event_hub::SeqEvent]) -> bool {
    events
        .iter()
        .any(|event| matches!(event.event, Event::RecordingStopping { .. }))
}

fn command_failed(status: &LiveStatus) -> bool {
    matches!(
        status.camera_state,
        CameraState::Restarting | CameraState::Offline
    ) || status.phase == RecorderPhase::Error
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
            tracing::error!(%error, seq, "failed to stat finalized camera segment");
            None
        }
        Err(error) => {
            tracing::error!(%error, seq, "camera clip metadata task failed");
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use std::{io::Cursor, path::Path, sync::Arc};

    use super::{parse_stderr, ChildCommand, ChildEvent};
    use crate::{
        event_hub::EventHub, time_sync::TimeStore, ts_duration::DurationCache, world::CameraState,
    };

    #[test]
    fn child_event_parses_stderr_contract() {
        assert_eq!(
            serde_json::from_str::<ChildEvent>(r#"{"event":"ready"}"#).unwrap(),
            ChildEvent::Ready
        );
        assert_eq!(
            serde_json::from_str::<ChildEvent>(r#"{"event":"sensor_temp","celsius":43.2}"#)
                .unwrap(),
            ChildEvent::SensorTemp {
                celsius: Some(43.2)
            }
        );
        assert_eq!(
            serde_json::from_str::<ChildEvent>(r#"{"event":"sensor_temp","celsius":null}"#)
                .unwrap(),
            ChildEvent::SensorTemp { celsius: None }
        );
        assert!(serde_json::from_str::<ChildEvent>(r#"{"event":"sensor_temp"}"#).is_err());
        let overflow =
            serde_json::from_str::<ChildEvent>(r#"{"event":"sensor_temp","celsius":1e39}"#)
                .unwrap();
        assert!(matches!(
            overflow,
            ChildEvent::SensorTemp {
                celsius: Some(value)
            } if !value.is_finite()
        ));
        assert_eq!(
            serde_json::from_str::<ChildEvent>(r#"{"event":"recording_started","session_id":7}"#)
                .unwrap(),
            ChildEvent::RecordingStarted { session: 7 }
        );
        assert_eq!(
            serde_json::from_str::<ChildEvent>(
                r#"{"event":"segment_opened","session_id":7,"id":5}"#
            )
            .unwrap(),
            ChildEvent::SegmentOpened { session: 7, id: 5 }
        );
        assert_eq!(
            serde_json::from_str::<ChildEvent>(
                r#"{"event":"segment_closed","session_id":7,"id":5}"#
            )
            .unwrap(),
            ChildEvent::SegmentClosed { session: 7, id: 5 }
        );
        assert_eq!(
            serde_json::from_str::<ChildEvent>(r#"{"event":"recording_stopped","session_id":7}"#)
                .unwrap(),
            ChildEvent::RecordingStopped { session: 7 }
        );
        assert_eq!(
            serde_json::from_str::<ChildEvent>(r#"{"event":"error","detail":"camera failed"}"#)
                .unwrap(),
            ChildEvent::Error {
                detail: "camera failed".to_string()
            }
        );
    }

    #[tokio::test]
    async fn stderr_sensor_temp_filters_non_finite_and_projects_each_sample() {
        let hub = Arc::new(EventHub::new(CameraState::Starting));

        drive_stderr_line(hub.clone(), r#"{"event":"ready"}"#).await;
        assert_eq!(hub.snapshot().camera_state, CameraState::Running);

        drive_stderr_line(hub.clone(), r#"{"event":"sensor_temp","celsius":1e39}"#).await;
        assert_eq!(hub.snapshot().temp_c.sensor.current, None);

        drive_stderr_line(hub.clone(), r#"{"event":"sensor_temp","celsius":43.2}"#).await;
        assert_eq!(hub.snapshot().temp_c.sensor.current, Some(43.0));

        drive_stderr_line(hub.clone(), r#"{"event":"sensor_temp","celsius":null}"#).await;
        assert_eq!(hub.snapshot().temp_c.sensor.current, None);
    }

    async fn drive_stderr_line(hub: Arc<EventHub>, line: &str) {
        parse_stderr(
            Cursor::new(format!("{line}\n").into_bytes()),
            hub,
            Arc::<Path>::from(Path::new(".").to_path_buf().into_boxed_path()),
            Arc::new(DurationCache::new()),
            Arc::new(TimeStore::in_memory()),
        )
        .await;
    }

    #[test]
    fn child_command_serializes_start_payload() {
        assert_eq!(
            serde_json::to_string(&ChildCommand::StartRecording {
                session_id: 7,
                start_segment_index: 5
            })
            .unwrap(),
            r#"{"cmd":"start_recording","session_id":7,"start_segment_index":5}"#
        );
    }
}
