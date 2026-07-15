use std::{
    env,
    path::{Path, PathBuf},
    pin::Pin,
    process::Stdio,
    sync::Arc,
    time::{Duration, Instant},
};

use async_trait::async_trait;
use bytes::Bytes;
use tokio::{
    io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader},
    process::{Child, ChildStdout, Command as TokioCommand},
    sync::{mpsc, oneshot, watch, Mutex},
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
    world::{CameraState, Input},
};

const COMMAND_CAPACITY: usize = 8;
const CHILD_EVENT_CAPACITY: usize = 256;
const ADMISSION_TIMEOUT: Duration = Duration::from_millis(250);
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
    start_handoff: Arc<Mutex<()>>,
    #[cfg(test)]
    start_handoff_pause: Option<Arc<StartHandoffPause>>,
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
            start_handoff: Arc::new(Mutex::new(())),
            #[cfg(test)]
            start_handoff_pause: None,
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
        self.ensure_camera_running()?;
        if self.hub.phase() == RecorderPhase::Recording {
            return Ok(());
        }

        let _handoff = self.start_handoff.lock().await;
        let storage = self.storage.clone();
        let start_segment = tokio::task::spawn_blocking(move || storage.allocate_start_segment())
            .await
            .map_err(|error| {
                tracing::error!(%error, "start segment allocation task failed");
                BackendError::RecordingStorageUnavailable
            })?
            .map_err(|error| {
                tracing::error!(%error, "start segment allocation failed");
                BackendError::RecordingStorageUnavailable
            })?;

        #[cfg(test)]
        if let Some(pause) = &self.start_handoff_pause {
            pause.after_allocation(start_segment).await;
        }

        let ack_rx = self.admit(CommandIntent::Start { start_segment }).await?;
        drop(_handoff);
        ack_rx.await.map_err(|_| {
            BackendError::camera_command_channel("camera command acknowledgement channel closed")
        })?
    }

    async fn stop_recording(&self) -> Result<(), BackendError> {
        self.ensure_camera_running()?;
        if self.hub.phase() == RecorderPhase::Idle {
            return Ok(());
        }

        self.command_and_wait(CommandIntent::Stop).await
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
        self.clip_durations.forget(id);
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
        recording_storage_available: bool,
        soc_temp_c: Option<f32>,
        mem: Option<MemInfo>,
        cpu: Cpu,
    ) {
        self.hub
            .update_telemetry(storage, recording_storage_available, soc_temp_c, mem, cpu);
    }

    fn update_storage(&self, storage: Option<DiskUsage>, recording_storage_available: bool) {
        self.hub
            .update_storage(storage, recording_storage_available);
    }
}

impl CameraBackend {
    fn ensure_camera_running(&self) -> Result<(), BackendError> {
        match self.hub.live_status().camera_state {
            CameraState::Running => Ok(()),
            CameraState::Starting => Err(BackendError::CameraStarting),
            CameraState::Restarting => Err(BackendError::CameraRestarting),
            CameraState::Offline => Err(BackendError::CameraOffline),
        }
    }

    async fn command_and_wait(&self, intent: CommandIntent) -> Result<(), BackendError> {
        self.admit(intent).await?.await.map_err(|_| {
            BackendError::camera_command_channel("camera command acknowledgement channel closed")
        })?
    }

    async fn admit(
        &self,
        intent: CommandIntent,
    ) -> Result<oneshot::Receiver<Result<(), BackendError>>, BackendError> {
        let (ack_tx, ack_rx) = oneshot::channel();
        let permit = tokio::time::timeout(ADMISSION_TIMEOUT, self.commands_tx.reserve())
            .await
            .map_err(|_| BackendError::CameraCommandTimeout)?
            .map_err(|_| BackendError::camera_command_channel("camera command queue closed"))?;
        permit.send(Command {
            intent,
            deadline: tokio::time::Instant::now() + COMMAND_TIMEOUT,
            ack_tx,
        });
        Ok(ack_rx)
    }
}

struct Command {
    intent: CommandIntent,
    deadline: tokio::time::Instant,
    ack_tx: oneshot::Sender<Result<(), BackendError>>,
}

#[derive(Clone, Copy, Debug)]
enum CommandIntent {
    Start { start_segment: SegmentId },
    Stop,
}

#[cfg(test)]
struct StartHandoffPause {
    reached_tx: mpsc::Sender<SegmentId>,
    release_rx: Mutex<mpsc::Receiver<()>>,
}

#[cfg(test)]
impl StartHandoffPause {
    async fn after_allocation(&self, segment: SegmentId) {
        self.reached_tx.send(segment).await.unwrap();
        self.release_rx.lock().await.recv().await.unwrap();
    }
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
    let mut next_spawn = tokio::time::Instant::now();
    let mut child: Option<RunningChild> = None;
    let mut pending: Option<Command> = None;

    loop {
        if child.is_none() && tokio::time::Instant::now() >= next_spawn {
            hub.drive_now(Input::CameraState(CameraState::Starting));
            match spawn_running_child(&config, frames_tx.clone()).await {
                Ok(running) => child = Some(running),
                Err(error) => {
                    tracing::error!(%error, "failed to start camera child");
                    frames_tx.send_replace(None);
                    hub.drive_now(Input::CameraState(CameraState::Restarting));
                    next_spawn = tokio::time::Instant::now() + backoff;
                    backoff = (backoff * 2).min(BACKOFF_CAP);
                }
            }
        }

        if pending
            .as_ref()
            .is_some_and(|command| command.deadline <= tokio::time::Instant::now())
        {
            let command = pending.take().expect("pending command checked above");
            let _ = command.ack_tx.send(Err(BackendError::CameraCommandTimeout));
            continue;
        }

        if child.as_ref().is_some_and(|running| running.ready) && pending.is_some() {
            let command = pending.take().expect("pending command checked above");
            let outcome = execute_command(
                child.as_mut().expect("ready child checked above"),
                command,
                &hub,
                Arc::from(config.rec_dir.clone().into_boxed_path()),
                clip_durations.clone(),
                time_store.clone(),
                &mut shutdown_rx,
            )
            .await;
            match outcome {
                ExecuteOutcome::Continue => continue,
                ExecuteOutcome::Retire {
                    started,
                    detail,
                    error,
                    ack_tx,
                } => {
                    retire_child(child.take().expect("executing child exists"), false).await;
                    note_child_lost(&frames_tx, &hub, &detail);
                    let _ = ack_tx.send(Err(error));
                    if started.elapsed() >= BACKOFF_RESET_AFTER {
                        backoff = BACKOFF_BASE;
                    }
                    next_spawn = tokio::time::Instant::now() + backoff;
                    backoff = (backoff * 2).min(BACKOFF_CAP);
                    continue;
                }
                ExecuteOutcome::Exited {
                    started,
                    detail,
                    error,
                    ack_tx,
                } => {
                    finish_child(child.take().expect("executing child exists"));
                    note_child_lost(&frames_tx, &hub, &detail);
                    let _ = ack_tx.send(Err(error));
                    if started.elapsed() >= BACKOFF_RESET_AFTER {
                        backoff = BACKOFF_BASE;
                    }
                    next_spawn = tokio::time::Instant::now() + backoff;
                    backoff = (backoff * 2).min(BACKOFF_CAP);
                    continue;
                }
                ExecuteOutcome::Shutdown {
                    detail,
                    error,
                    ack_tx,
                } => {
                    retire_child(child.take().expect("executing child exists"), false).await;
                    finish_shutdown(&frames_tx, &hub);
                    hub.drive_now(Input::Fail { detail });
                    let _ = ack_tx.send(Err(error));
                    return;
                }
            }
        }

        let pending_deadline = pending
            .as_ref()
            .map(|command| command.deadline)
            .unwrap_or_else(far_future);
        let spawn_deadline = child.as_ref().map(|_| far_future()).unwrap_or(next_spawn);

        tokio::select! {
            command = commands_rx.recv(), if pending.is_none() => {
                match command {
                    Some(command) => pending = Some(command),
                    None => {
                        if let Some(command) = pending.take() {
                            let _ = command.ack_tx.send(Err(
                                BackendError::camera_command_channel("camera command queue closed"),
                            ));
                        }
                        if let Some(running) = child.take() {
                            retire_child(running, true).await;
                        }
                        finish_shutdown(&frames_tx, &hub);
                        return;
                    }
                }
            }
            _ = tokio::time::sleep_until(pending_deadline), if pending.is_some() => {}
            _ = tokio::time::sleep_until(spawn_deadline), if child.is_none() => {}
            signal = next_optional_child_signal(&mut child) => {
                match signal {
                    ChildSignal::Event(event) => {
                        let fatal_detail = match &event {
                            ChildEvent::Error { detail } => Some(detail.clone()),
                            _ => None,
                        };
                        let running = child.as_mut().expect("child branch guarded");
                        apply_child_event(
                            event,
                            &mut running.ready,
                            &mut running.event_state,
                            &hub,
                            Arc::from(config.rec_dir.clone().into_boxed_path()),
                            clip_durations.clone(),
                            time_store.clone(),
                        ).await;
                        if let Some(detail) = fatal_detail {
                            let running = child.take().expect("fatal child exists");
                            let started = running.started;
                            retire_child(running, false).await;
                            note_child_lost(&frames_tx, &hub, &detail);
                            if started.elapsed() >= BACKOFF_RESET_AFTER {
                                backoff = BACKOFF_BASE;
                            }
                            next_spawn = tokio::time::Instant::now() + backoff;
                            backoff = (backoff * 2).min(BACKOFF_CAP);
                        }
                    }
                    ChildSignal::EventsClosed => {}
                    ChildSignal::Exited => {
                        let running = child.take().expect("child branch guarded");
                        let started = running.started;
                        finish_child(running);
                        note_child_lost(&frames_tx, &hub, "camera process exited");
                        if started.elapsed() >= BACKOFF_RESET_AFTER {
                            backoff = BACKOFF_BASE;
                        }
                        next_spawn = tokio::time::Instant::now() + backoff;
                        backoff = (backoff * 2).min(BACKOFF_CAP);
                    }
                }
            }
            _ = &mut shutdown_rx => {
                if let Some(command) = pending.take() {
                    let _ = command.ack_tx.send(Err(
                        BackendError::camera_command_channel("camera supervisor shut down"),
                    ));
                }
                if let Some(running) = child.take() {
                    retire_child(running, true).await;
                }
                finish_shutdown(&frames_tx, &hub);
                return;
            }
        }
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

fn far_future() -> tokio::time::Instant {
    tokio::time::Instant::now() + Duration::from_secs(365 * 24 * 60 * 60)
}

struct RunningChild {
    process: Child,
    stdin: Pin<Box<dyn AsyncWrite + Send>>,
    events_rx: mpsc::Receiver<ChildEvent>,
    events_open: bool,
    stdout_task: tokio::task::JoinHandle<()>,
    stderr_task: tokio::task::JoinHandle<()>,
    ready: bool,
    started: Instant,
    event_state: ChildEventState,
}

#[derive(Default)]
struct ChildEventState {
    last_opened: Option<(u64, SegmentId)>,
    pending_closed: Option<(u64, SegmentId)>,
}

async fn spawn_running_child(
    config: &CameraConfig,
    frames_tx: watch::Sender<Option<Bytes>>,
) -> std::io::Result<RunningChild> {
    let mut child = spawn_child(config).await?;
    let stdout = child
        .stdout
        .take()
        .ok_or_else(|| std::io::Error::other("camera child stdout was not piped"))?;
    let stderr = child
        .stderr
        .take()
        .ok_or_else(|| std::io::Error::other("camera child stderr was not piped"))?;
    let stdin = child
        .stdin
        .take()
        .ok_or_else(|| std::io::Error::other("camera child stdin was not piped"))?;
    let (events_tx, events_rx) = mpsc::channel(CHILD_EVENT_CAPACITY);
    Ok(RunningChild {
        process: child,
        stdin: Box::pin(stdin),
        events_rx,
        events_open: true,
        stdout_task: tokio::spawn(drain_stdout(stdout, frames_tx)),
        stderr_task: tokio::spawn(read_stderr(stderr, events_tx)),
        ready: false,
        started: Instant::now(),
        event_state: ChildEventState::default(),
    })
}

enum ChildSignal {
    Event(ChildEvent),
    EventsClosed,
    Exited,
}

async fn next_child_signal(child: &mut RunningChild) -> ChildSignal {
    tokio::select! {
        event = child.events_rx.recv(), if child.events_open => match event {
            Some(event) => ChildSignal::Event(event),
            None => {
                child.events_open = false;
                ChildSignal::EventsClosed
            }
        },
        result = child.process.wait() => {
            if let Err(error) = result {
                tracing::warn!(%error, "failed waiting for camera child");
            }
            ChildSignal::Exited
        }
    }
}

async fn next_optional_child_signal(child: &mut Option<RunningChild>) -> ChildSignal {
    match child.as_mut() {
        Some(child) => next_child_signal(child).await,
        None => std::future::pending().await,
    }
}

enum ExecuteOutcome {
    Continue,
    Retire {
        started: Instant,
        detail: String,
        error: BackendError,
        ack_tx: oneshot::Sender<Result<(), BackendError>>,
    },
    Exited {
        started: Instant,
        detail: String,
        error: BackendError,
        ack_tx: oneshot::Sender<Result<(), BackendError>>,
    },
    Shutdown {
        detail: String,
        error: BackendError,
        ack_tx: oneshot::Sender<Result<(), BackendError>>,
    },
}

struct ActiveCommand {
    child_command: ChildCommand,
    target: RecorderPhase,
    session: u64,
}

struct EventContext {
    rec_dir: Arc<Path>,
    clip_durations: Arc<DurationCache>,
    time_store: Arc<TimeStore>,
}

async fn execute_command(
    child: &mut RunningChild,
    command: Command,
    hub: &Arc<EventHub>,
    rec_dir: Arc<Path>,
    clip_durations: Arc<DurationCache>,
    time_store: Arc<TimeStore>,
    shutdown_rx: &mut oneshot::Receiver<()>,
) -> ExecuteOutcome {
    if command.deadline <= tokio::time::Instant::now() {
        let _ = command.ack_tx.send(Err(BackendError::CameraCommandTimeout));
        return ExecuteOutcome::Continue;
    }

    let active = match command.intent {
        CommandIntent::Start { start_segment } => {
            let events = hub.drive_now(Input::StartCommand { start_segment });
            starting_session(&events).map(|session| ActiveCommand {
                child_command: ChildCommand::StartRecording {
                    session_id: session,
                    start_segment_index: start_segment,
                },
                target: RecorderPhase::Recording,
                session,
            })
        }
        CommandIntent::Stop => {
            let events = hub.drive_now(Input::StopCommand);
            has_recording_stopping(&events).then(|| ActiveCommand {
                child_command: ChildCommand::StopRecording,
                target: RecorderPhase::Idle,
                session: hub.session(),
            })
        }
    };
    let Some(active) = active else {
        let _ = command.ack_tx.send(Ok(()));
        return ExecuteOutcome::Continue;
    };

    let event_context = EventContext {
        rec_dir,
        clip_durations,
        time_store,
    };
    let failure = match write_until_terminal(
        child,
        &active,
        command.deadline,
        hub,
        &event_context,
        shutdown_rx,
    )
    .await
    {
        Ok(()) => wait_for_target(
            child,
            &active,
            command.deadline,
            hub,
            &event_context,
            shutdown_rx,
        )
        .await
        .err(),
        Err(failure) => Some(CommandFailure::Terminal(failure)),
    };

    let Some(failure) = failure else {
        let _ = command.ack_tx.send(Ok(()));
        return ExecuteOutcome::Continue;
    };

    drain_delivered_events(
        child,
        hub,
        event_context.rec_dir,
        event_context.clip_durations,
        event_context.time_store,
    )
    .await;
    if target_reached(hub, &active) {
        let _ = command.ack_tx.send(Ok(()));
        return ExecuteOutcome::Continue;
    }

    let failure = match failure {
        CommandFailure::RecorderFailed(detail) => {
            let _ = command
                .ack_tx
                .send(Err(BackendError::RecorderFailed(detail)));
            return ExecuteOutcome::Continue;
        }
        CommandFailure::Terminal(failure) => failure,
    };
    let (error, outcome, detail) = match failure {
        TerminalFailure::Timeout => (
            BackendError::CameraCommandTimeout,
            None,
            "camera command timed out".to_string(),
        ),
        TerminalFailure::Write => (
            BackendError::camera_command_channel("camera command write failed"),
            None,
            "camera command write failed".to_string(),
        ),
        TerminalFailure::ChildError(detail) => (
            BackendError::camera_command_channel(detail.clone()),
            None,
            detail,
        ),
        TerminalFailure::Exited => (
            BackendError::camera_command_channel("camera process exited"),
            Some(false),
            "camera process exited".to_string(),
        ),
        TerminalFailure::Shutdown => (
            BackendError::camera_command_channel("camera supervisor shut down"),
            Some(true),
            "camera supervisor shut down".to_string(),
        ),
    };
    match outcome {
        Some(true) => ExecuteOutcome::Shutdown {
            detail,
            error,
            ack_tx: command.ack_tx,
        },
        Some(false) => ExecuteOutcome::Exited {
            started: child.started,
            detail,
            error,
            ack_tx: command.ack_tx,
        },
        None => ExecuteOutcome::Retire {
            started: child.started,
            detail,
            error,
            ack_tx: command.ack_tx,
        },
    }
}

enum TerminalFailure {
    Timeout,
    Write,
    ChildError(String),
    Exited,
    Shutdown,
}

enum CommandFailure {
    Terminal(TerminalFailure),
    RecorderFailed(String),
}

async fn write_until_terminal(
    child: &mut RunningChild,
    active: &ActiveCommand,
    deadline: tokio::time::Instant,
    hub: &Arc<EventHub>,
    event_context: &EventContext,
    shutdown_rx: &mut oneshot::Receiver<()>,
) -> Result<(), TerminalFailure> {
    let write = write_command(&mut child.stdin, &active.child_command);
    tokio::pin!(write);
    loop {
        tokio::select! {
            result = &mut write => return result.map_err(|_| TerminalFailure::Write),
            event = child.events_rx.recv(), if child.events_open => match event {
                Some(event) => {
                    if let Some(detail) = apply_command_event(event, &mut child.ready, &mut child.event_state, hub, event_context.rec_dir.clone(), event_context.clip_durations.clone(), event_context.time_store.clone()).await {
                        return Err(TerminalFailure::ChildError(detail));
                    }
                }
                None => child.events_open = false,
            },
            result = child.process.wait() => {
                if let Err(error) = result { tracing::warn!(%error, "failed waiting for camera child"); }
                return Err(TerminalFailure::Exited);
            }
            _ = tokio::time::sleep_until(deadline) => return Err(TerminalFailure::Timeout),
            _ = &mut *shutdown_rx => return Err(TerminalFailure::Shutdown),
        }
    }
}

async fn wait_for_target(
    child: &mut RunningChild,
    active: &ActiveCommand,
    deadline: tokio::time::Instant,
    hub: &Arc<EventHub>,
    event_context: &EventContext,
    shutdown_rx: &mut oneshot::Receiver<()>,
) -> Result<(), CommandFailure> {
    loop {
        if target_reached(hub, active) {
            return Ok(());
        }
        if hub.live_status().camera_state == CameraState::Running
            && hub.phase() == RecorderPhase::Error
        {
            return Err(CommandFailure::RecorderFailed(
                hub.snapshot()
                    .recorder
                    .detail
                    .unwrap_or_else(|| "recorder failed".to_string()),
            ));
        }
        tokio::select! {
            event = child.events_rx.recv(), if child.events_open => match event {
                Some(event) => {
                    if let Some(detail) = apply_command_event(event, &mut child.ready, &mut child.event_state, hub, event_context.rec_dir.clone(), event_context.clip_durations.clone(), event_context.time_store.clone()).await {
                        return Err(CommandFailure::Terminal(TerminalFailure::ChildError(detail)));
                    }
                }
                None => child.events_open = false,
            },
            result = child.process.wait() => {
                if let Err(error) = result { tracing::warn!(%error, "failed waiting for camera child"); }
                return Err(CommandFailure::Terminal(TerminalFailure::Exited));
            }
            _ = tokio::time::sleep_until(deadline) => return Err(CommandFailure::Terminal(TerminalFailure::Timeout)),
            _ = &mut *shutdown_rx => return Err(CommandFailure::Terminal(TerminalFailure::Shutdown)),
        }
    }
}

async fn apply_command_event(
    event: ChildEvent,
    ready: &mut bool,
    event_state: &mut ChildEventState,
    hub: &Arc<EventHub>,
    rec_dir: Arc<Path>,
    clip_durations: Arc<DurationCache>,
    time_store: Arc<TimeStore>,
) -> Option<String> {
    let detail = match &event {
        ChildEvent::Error { detail } => Some(detail.clone()),
        _ => None,
    };
    apply_child_event(
        event,
        ready,
        event_state,
        hub,
        rec_dir,
        clip_durations,
        time_store,
    )
    .await;
    detail
}

async fn drain_delivered_events(
    child: &mut RunningChild,
    hub: &Arc<EventHub>,
    rec_dir: Arc<Path>,
    clip_durations: Arc<DurationCache>,
    time_store: Arc<TimeStore>,
) {
    while let Ok(event) = child.events_rx.try_recv() {
        apply_child_event(
            event,
            &mut child.ready,
            &mut child.event_state,
            hub,
            rec_dir.clone(),
            clip_durations.clone(),
            time_store.clone(),
        )
        .await;
    }
}

fn target_reached(hub: &EventHub, active: &ActiveCommand) -> bool {
    hub.phase() == active.target && hub.session() == active.session
}

async fn retire_child(mut child: RunningChild, graceful: bool) {
    if graceful {
        let _ = tokio::time::timeout(
            SHUTDOWN_TIMEOUT,
            write_command(&mut child.stdin, &ChildCommand::Shutdown),
        )
        .await;
        if tokio::time::timeout(SHUTDOWN_TIMEOUT, child.process.wait())
            .await
            .is_err()
        {
            let _ = child.process.kill().await;
            let _ = child.process.wait().await;
        }
    } else {
        let _ = child.process.kill().await;
        let _ = child.process.wait().await;
    }
    finish_child(child);
}

fn finish_child(child: RunningChild) {
    child.stdout_task.abort();
    child.stderr_task.abort();
}

fn note_child_lost(frames_tx: &watch::Sender<Option<Bytes>>, hub: &EventHub, detail: &str) {
    frames_tx.send_replace(None);
    hub.drive_now(Input::CameraState(CameraState::Restarting));
    hub.drive_now(Input::Fail {
        detail: detail.to_string(),
    });
}

fn finish_shutdown(frames_tx: &watch::Sender<Option<Bytes>>, hub: &EventHub) {
    frames_tx.send_replace(None);
    hub.drive_now(Input::CameraState(CameraState::Offline));
    hub.drive_now(Input::Fail {
        detail: "camera supervisor shut down".to_string(),
    });
}

async fn read_stderr(
    stderr: impl AsyncRead + Unpin + Send + 'static,
    events_tx: mpsc::Sender<ChildEvent>,
) {
    let mut lines = BufReader::new(stderr).lines();
    while let Ok(Some(line)) = lines.next_line().await {
        match serde_json::from_str::<ChildEvent>(&line) {
            Ok(event) => {
                if events_tx.send(event).await.is_err() {
                    return;
                }
            }
            Err(_) => tracing::info!(line = %line, "camera child stderr"),
        }
    }
}

async fn write_command(
    stdin: &mut (impl AsyncWrite + Unpin + ?Sized),
    command: &ChildCommand,
) -> Result<(), BackendError> {
    let mut line = serde_json::to_vec(command)
        .map_err(|_| BackendError::camera_command_channel("camera command serialization failed"))?;
    line.push(b'\n');
    stdin
        .write_all(&line)
        .await
        .map_err(|_| BackendError::camera_command_channel("camera command write failed"))?;
    stdin
        .flush()
        .await
        .map_err(|_| BackendError::camera_command_channel("camera command flush failed"))
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

async fn apply_child_event(
    event: ChildEvent,
    ready: &mut bool,
    event_state: &mut ChildEventState,
    hub: &Arc<EventHub>,
    rec_dir: Arc<Path>,
    clip_durations: Arc<DurationCache>,
    time_store: Arc<TimeStore>,
) {
    match event {
        ChildEvent::Ready => {
            *ready = true;
            hub.drive_now(Input::CameraState(CameraState::Running));
        }
        ChildEvent::SensorTemp { celsius } => {
            hub.drive_now(Input::SensorTemp {
                celsius: celsius.filter(|value| value.is_finite()),
            });
        }
        ChildEvent::RecordingStarted { session } => {
            hub.drive_now(Input::Recorder(RecorderEvent::RecordingStarted { session }));
        }
        ChildEvent::SegmentOpened { session, id } => {
            if let Some((closed_session, closed_id)) = event_state.pending_closed.take() {
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
                            event_state.last_opened = Some((session, id));
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
                    event_state.last_opened = Some((session, id));
                }
            } else {
                hub.drive_now(Input::Recorder(RecorderEvent::SegmentOpened {
                    session,
                    id,
                }));
                event_state.last_opened = Some((session, id));
            }
        }
        ChildEvent::SegmentClosed { session, id } => {
            event_state.pending_closed = Some((session, id))
        }
        ChildEvent::RecordingStopped { session } => {
            let mut final_stat_failed = false;
            let finalized = match event_state.last_opened {
                Some((opened_session, id)) if opened_session == session => {
                    match finalized_clip_meta(rec_dir, id, clip_durations, time_store).await {
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
            event_state.pending_closed = None;
            event_state.last_opened = None;
        }
        ChildEvent::Error { detail } => {
            tracing::error!(%detail, "camera child error event");
            hub.drive_now(Input::Fail { detail });
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
    use std::{
        fs, io,
        os::unix::fs::PermissionsExt,
        path::PathBuf,
        pin::Pin,
        process::Stdio,
        sync::Arc,
        task::{Context, Poll},
        time::{Duration, SystemTime, UNIX_EPOCH},
    };

    use bytes::Bytes;
    use tokio::{
        io::AsyncWrite,
        process::Command as TokioCommand,
        sync::{mpsc, oneshot, watch, Mutex},
    };

    use super::{
        execute_command, finish_child, note_child_lost, retire_child, supervise, CameraBackend,
        CameraConfig, CameraProcess, ChildCommand, ChildEvent, ChildEventState, Command,
        CommandIntent, ExecuteOutcome, RunningChild, StartHandoffPause,
    };
    use crate::{
        backend::{Backend, BackendError},
        event_hub::EventHub,
        recorder::RecorderPhase,
        storage::StorageCoordinator,
        time_sync::TimeStore,
        ts_duration::DurationCache,
        world::CameraState,
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

    #[tokio::test]
    async fn closed_admission_leaves_recorder_untouched() {
        let (commands_tx, commands_rx) = mpsc::channel(1);
        drop(commands_rx);
        let backend = backend_with_sender(commands_tx);

        assert!(matches!(
            backend
                .admit(CommandIntent::Start { start_segment: 7 })
                .await,
            Err(BackendError::CameraCommandChannel(_))
        ));
        assert_eq!(backend.hub.phase(), crate::recorder::RecorderPhase::Idle);
    }

    #[tokio::test]
    async fn saturated_admission_times_out_before_any_transition() {
        let (commands_tx, _commands_rx) = mpsc::channel(1);
        let (held_ack_tx, _held_ack_rx) = oneshot::channel();
        commands_tx
            .try_send(Command {
                intent: CommandIntent::Stop,
                deadline: tokio::time::Instant::now() + Duration::from_secs(3),
                ack_tx: held_ack_tx,
            })
            .unwrap();
        let backend = backend_with_sender(commands_tx);

        assert!(matches!(
            backend
                .admit(CommandIntent::Start { start_segment: 7 })
                .await,
            Err(BackendError::CameraCommandTimeout)
        ));
        assert_eq!(backend.hub.phase(), crate::recorder::RecorderPhase::Idle);
    }

    #[tokio::test]
    async fn admitted_command_expires_while_spawning_keeps_failing() {
        let (frames_tx, _) = watch::channel::<Option<Bytes>>(None);
        let hub = Arc::new(EventHub::new(CameraState::Starting));
        let (commands_tx, commands_rx) = mpsc::channel(1);
        let (shutdown_tx, shutdown_rx) = oneshot::channel();
        let clip_durations = Arc::new(DurationCache::new());
        let time_store = Arc::new(TimeStore::in_memory());
        let config = CameraConfig::new("/definitely-not-a-camera-program", [] as [&str; 0]);
        let supervisor = tokio::spawn(supervise(
            config,
            frames_tx,
            hub.clone(),
            commands_rx,
            shutdown_rx,
            clip_durations,
            time_store,
        ));
        let (ack_tx, ack_rx) = oneshot::channel();
        commands_tx
            .send(Command {
                intent: CommandIntent::Start { start_segment: 7 },
                deadline: tokio::time::Instant::now() + Duration::from_millis(75),
                ack_tx,
            })
            .await
            .unwrap();

        assert_eq!(
            ack_rx.await.unwrap(),
            Err(BackendError::CameraCommandTimeout)
        );
        assert_eq!(hub.phase(), crate::recorder::RecorderPhase::Idle);
        let _ = shutdown_tx.send(());
        supervisor.await.unwrap();
    }

    #[tokio::test]
    async fn command_expired_in_backoff_is_never_written_to_replacement_child() {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!("dancam-late-command-{nonce}"));
        fs::create_dir_all(&root).unwrap();
        let script_path = root.join("camera-child.sh");
        let marker = root.join("spawned-once");
        let command_log = root.join("commands.log");
        fs::write(
            &script_path,
            format!(
                "#!/bin/sh\nif [ ! -e '{}' ]; then touch '{}'; printf '%s\\n' '{{\"event\":\"ready\"}}' >&2; exit 1; fi\nsleep 0.3\nprintf '%s\\n' '{{\"event\":\"ready\"}}' >&2\nwhile IFS= read -r line; do printf '%s\\n' \"$line\" >> '{}'; case \"$line\" in *shutdown*) exit 0;; esac; done\n",
                marker.display(),
                marker.display(),
                command_log.display(),
            ),
        )
        .unwrap();
        let mut permissions = fs::metadata(&script_path).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&script_path, permissions).unwrap();

        let (frames_tx, _) = watch::channel::<Option<Bytes>>(None);
        let hub = Arc::new(EventHub::new(CameraState::Starting));
        let (commands_tx, commands_rx) = mpsc::channel(1);
        let (shutdown_tx, shutdown_rx) = oneshot::channel();
        let supervisor = tokio::spawn(supervise(
            CameraConfig::new(script_path.to_string_lossy(), [] as [&str; 0]),
            frames_tx,
            hub.clone(),
            commands_rx,
            shutdown_rx,
            Arc::new(DurationCache::new()),
            Arc::new(TimeStore::in_memory()),
        ));
        tokio::time::timeout(Duration::from_secs(2), async {
            while hub.snapshot().camera_state != CameraState::Restarting {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        let (ack_tx, ack_rx) = oneshot::channel();
        commands_tx
            .send(Command {
                intent: CommandIntent::Start { start_segment: 7 },
                deadline: tokio::time::Instant::now() + Duration::from_millis(75),
                ack_tx,
            })
            .await
            .unwrap();

        assert_eq!(
            ack_rx.await.unwrap(),
            Err(BackendError::CameraCommandTimeout)
        );
        tokio::time::timeout(Duration::from_secs(2), async {
            while hub.snapshot().camera_state != CameraState::Running {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        assert!(!command_log.exists());
        assert_eq!(hub.phase(), RecorderPhase::Idle);

        let _ = shutdown_tx.send(());
        supervisor.await.unwrap();
        let _ = fs::remove_dir_all(root);
    }

    #[tokio::test]
    #[allow(clippy::await_holding_lock)]
    async fn blocked_start_allocation_does_not_wedge_supervisor_events() {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let rec_dir = std::env::temp_dir().join(format!("dancam-blocked-allocation-{nonce}"));
        let script = r#"
import json, sys, threading
print(json.dumps({"event":"ready"}), file=sys.stderr, flush=True)
threading.Timer(0.05, lambda: print(json.dumps({"event":"sensor_temp","celsius":42.0}), file=sys.stderr, flush=True)).start()
for line in sys.stdin:
    command = json.loads(line)
    if command["cmd"] == "shutdown":
        sys.exit(0)
    if command["cmd"] == "start_recording":
        print(json.dumps({"event":"recording_started","session_id":command["session_id"]}), file=sys.stderr, flush=True)
"#;
        let config = CameraConfig::new(
            "python3",
            [
                "-u".to_string(),
                "-c".to_string(),
                script.to_string(),
                "--rec-dir".to_string(),
                rec_dir.to_string_lossy().to_string(),
            ],
        );
        let storage = Arc::new(StorageCoordinator::new(rec_dir.clone()));
        let (backend, control) = CameraProcess::spawn(config, storage.clone());
        tokio::time::timeout(Duration::from_secs(2), async {
            while backend.snapshot().camera_state != CameraState::Running {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();

        let mutation_guard = storage.lock_mutation_for_test();
        let first_backend = backend.clone();
        let first = tokio::spawn(async move { first_backend.start_recording().await });
        tokio::task::yield_now().await;
        let second_backend = backend.clone();
        let second = tokio::spawn(async move { second_backend.start_recording().await });

        tokio::time::timeout(Duration::from_secs(1), async {
            while backend.snapshot().temp_c.sensor.current != Some(42.0) {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("supervisor should apply child events while allocation is blocked");
        assert_eq!(backend.snapshot().recorder.phase, RecorderPhase::Idle);
        drop(mutation_guard);

        assert_eq!(first.await.unwrap(), Ok(()));
        assert_eq!(second.await.unwrap(), Ok(()));
        assert_eq!(backend.snapshot().recorder.phase, RecorderPhase::Recording);

        control.shutdown().await;
        let _ = fs::remove_dir_all(rec_dir);
    }

    #[tokio::test]
    async fn start_handoff_gate_preserves_allocation_order() {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let rec_dir = std::env::temp_dir().join(format!("dancam-handoff-order-{nonce}"));
        let (commands_tx, mut commands_rx) = mpsc::channel(2);
        let mut backend = backend_with_sender(commands_tx);
        backend.storage = Arc::new(StorageCoordinator::new(rec_dir.clone()));
        let (reached_tx, mut reached_rx) = mpsc::channel(2);
        let (release_tx, release_rx) = mpsc::channel(2);
        backend.start_handoff_pause = Some(Arc::new(StartHandoffPause {
            reached_tx,
            release_rx: Mutex::new(release_rx),
        }));

        let first_backend = backend.clone();
        let first = tokio::spawn(async move { first_backend.start_recording().await });
        assert_eq!(reached_rx.recv().await, Some(0));
        let second_backend = backend.clone();
        let second = tokio::spawn(async move { second_backend.start_recording().await });
        assert!(
            tokio::time::timeout(Duration::from_millis(75), reached_rx.recv())
                .await
                .is_err(),
            "second start allocated before the first handed off"
        );

        release_tx.send(()).await.unwrap();
        let first_command = commands_rx.recv().await.unwrap();
        assert!(matches!(
            first_command.intent,
            CommandIntent::Start { start_segment: 0 }
        ));
        let _ = first_command
            .ack_tx
            .send(Err(BackendError::camera_command_channel(
                "injected command failure",
            )));

        assert_eq!(reached_rx.recv().await, Some(1));
        release_tx.send(()).await.unwrap();
        let second_command = commands_rx.recv().await.unwrap();
        assert!(matches!(
            second_command.intent,
            CommandIntent::Start { start_segment: 1 }
        ));
        let _ = second_command.ack_tx.send(Ok(()));

        assert_eq!(
            first.await.unwrap(),
            Err(BackendError::camera_command_channel(
                "injected command failure"
            ))
        );
        assert_eq!(second.await.unwrap(), Ok(()));
        let _ = fs::remove_dir_all(rec_dir);
    }

    #[tokio::test]
    async fn stalled_child_write_is_reaped_and_reconciled_before_timeout_ack() {
        let process = TokioCommand::new("sh")
            .arg("-c")
            .arg("sleep 10")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .unwrap();
        let pid = process.id().unwrap();
        let (_events_tx, events_rx) = mpsc::channel(1);
        let mut child = RunningChild {
            process,
            stdin: Box::pin(PendingWriter),
            events_rx,
            events_open: true,
            stdout_task: tokio::spawn(std::future::pending()),
            stderr_task: tokio::spawn(std::future::pending()),
            ready: true,
            started: std::time::Instant::now(),
            event_state: ChildEventState::default(),
        };
        let hub = Arc::new(EventHub::new(CameraState::Running));
        let (shutdown_tx, mut shutdown_rx) = oneshot::channel();
        let (ack_tx, ack_rx) = oneshot::channel();
        let outcome = execute_command(
            &mut child,
            Command {
                intent: CommandIntent::Start { start_segment: 7 },
                deadline: tokio::time::Instant::now() + Duration::from_millis(75),
                ack_tx,
            },
            &hub,
            Arc::from(PathBuf::from(".").into_boxed_path()),
            Arc::new(DurationCache::new()),
            Arc::new(TimeStore::in_memory()),
            &mut shutdown_rx,
        )
        .await;
        drop(shutdown_tx);

        let ExecuteOutcome::Retire {
            detail,
            error,
            ack_tx,
            ..
        } = outcome
        else {
            panic!("stalled write did not retire the child");
        };
        retire_child(child, false).await;
        note_child_lost(&watch::channel::<Option<Bytes>>(None).0, &hub, &detail);
        let _ = ack_tx.send(Err(error));

        assert_eq!(
            ack_rx.await.unwrap(),
            Err(BackendError::CameraCommandTimeout)
        );
        assert_eq!(hub.phase(), RecorderPhase::Error);
        assert!(!process_id_exists(pid).await);
    }

    #[tokio::test]
    async fn delivered_stop_target_wins_terminal_deadline_arbitration() {
        let process = TokioCommand::new("sh")
            .arg("-c")
            .arg("sleep 10")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .unwrap();
        let (events_tx, events_rx) = mpsc::channel(1);
        let mut child = RunningChild {
            process,
            stdin: Box::pin(PendingWriter),
            events_rx,
            events_open: true,
            stdout_task: tokio::spawn(std::future::pending()),
            stderr_task: tokio::spawn(std::future::pending()),
            ready: true,
            started: std::time::Instant::now(),
            event_state: ChildEventState::default(),
        };
        let hub = Arc::new(EventHub::new(CameraState::Running));
        let start_events = hub.drive_now(crate::world::Input::StartCommand { start_segment: 7 });
        let session = super::starting_session(&start_events).unwrap();
        hub.drive_now(crate::world::Input::Recorder(
            crate::recorder::RecorderEvent::RecordingStarted { session },
        ));
        events_tx
            .try_send(ChildEvent::RecordingStopped { session })
            .unwrap();
        let (_shutdown_tx, mut shutdown_rx) = oneshot::channel();
        let (ack_tx, ack_rx) = oneshot::channel();

        let outcome = execute_command(
            &mut child,
            Command {
                intent: CommandIntent::Stop,
                deadline: tokio::time::Instant::now() + Duration::from_millis(75),
                ack_tx,
            },
            &hub,
            Arc::from(PathBuf::from(".").into_boxed_path()),
            Arc::new(DurationCache::new()),
            Arc::new(TimeStore::in_memory()),
            &mut shutdown_rx,
        )
        .await;

        assert!(matches!(outcome, ExecuteOutcome::Continue));
        assert_eq!(ack_rx.await.unwrap(), Ok(()));
        assert_eq!(hub.phase(), RecorderPhase::Idle);
        let _ = child.process.kill().await;
        let _ = child.process.wait().await;
        finish_child(child);
    }

    struct PendingWriter;

    impl AsyncWrite for PendingWriter {
        fn poll_write(
            self: Pin<&mut Self>,
            _cx: &mut Context<'_>,
            _buf: &[u8],
        ) -> Poll<io::Result<usize>> {
            Poll::Pending
        }

        fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
            Poll::Ready(Ok(()))
        }

        fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<io::Result<()>> {
            Poll::Ready(Ok(()))
        }
    }

    async fn process_id_exists(pid: u32) -> bool {
        TokioCommand::new("kill")
            .arg("-0")
            .arg(pid.to_string())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .await
            .is_ok_and(|status| status.success())
    }

    fn backend_with_sender(commands_tx: mpsc::Sender<Command>) -> CameraBackend {
        let (frames_tx, _) = watch::channel(None);
        CameraBackend {
            frames_tx,
            hub: Arc::new(EventHub::new(CameraState::Running)),
            storage: Arc::new(StorageCoordinator::new(PathBuf::from("."))),
            commands_tx,
            start_handoff: Arc::new(Mutex::new(())),
            start_handoff_pause: None,
            clip_durations: Arc::new(DurationCache::new()),
            time_store: Arc::new(TimeStore::in_memory()),
        }
    }
}
