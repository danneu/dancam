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
use futures_util::FutureExt;
use tokio::{
    io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader},
    process::{Child, ChildStdout, Command as TokioCommand},
    sync::{mpsc, oneshot, watch, Mutex},
};
use tokio_stream::{wrappers::WatchStream, StreamExt};

use crate::{
    backend::{Backend, BackendError, FrameStream},
    clips::{clip_meta_from_candidate, finalize_clip_meta, ClipMeta},
    cpu::Cpu,
    event_hub::{EventConnection, EventHub},
    events::Event,
    events::Snapshot,
    jpeg::JpegSplitter,
    recorder::{RecorderEvent, RecorderPhase, SegmentId},
    storage::StorageCoordinator,
    sysfacts::{DiskUsage, MemInfo},
    time_sync::TimeStore,
    world::{CameraState, Commissioning, CommissioningState, Input},
};

const COMMAND_CAPACITY: usize = 8;
const CHILD_EVENT_CAPACITY: usize = 256;
const ADMISSION_TIMEOUT: Duration = Duration::from_millis(250);
const COMMAND_TIMEOUT: Duration = Duration::from_secs(3);
const SHUTDOWN_TIMEOUT: Duration = Duration::from_secs(2);
const SUPERVISOR_JOIN_TIMEOUT: Duration = Duration::from_secs(8);
const FINAL_METADATA_TIMEOUT: Duration = Duration::from_secs(1);
const BACKOFF_BASE: Duration = Duration::from_millis(250);
const BACKOFF_CAP: Duration = Duration::from_secs(10);
const BACKOFF_RESET_AFTER: Duration = Duration::from_secs(30);

#[derive(Clone, Debug)]
pub struct CameraConfig {
    program: String,
    args: Vec<String>,
    rec_dir: PathBuf,
    #[cfg(test)]
    panic_after_segment_opened: bool,
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
            #[cfg(test)]
            panic_after_segment_opened: false,
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
        let time_store = {
            let mut store = TimeStore::load(config.rec_dir.join("time"));
            if let Some(mountpoint) = storage.required_mountpoint() {
                store = store.with_required_mountpoint(mountpoint.as_ref().to_path_buf());
            }
            Arc::new(store)
        };

        let supervisor = tokio::spawn(supervise(
            config,
            storage.clone(),
            frames_tx.clone(),
            hub.clone(),
            commands_rx,
            shutdown_rx,
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
    supervisor: tokio::task::JoinHandle<Result<(), String>>,
}

impl SupervisorControl {
    pub async fn wait(&mut self) -> Result<(), String> {
        (&mut self.supervisor)
            .await
            .map_err(|error| format!("camera supervisor task failed: {error}"))?
    }

    pub async fn shutdown(mut self) -> Result<(), String> {
        let request_error = self.shutdown_tx.take().and_then(|shutdown_tx| {
            shutdown_tx
                .send(())
                .err()
                .map(|_| "camera supervisor stopped before shutdown".to_string())
        });

        let supervisor_result =
            match tokio::time::timeout(SUPERVISOR_JOIN_TIMEOUT, self.wait()).await {
                Ok(result) => result,
                Err(_) => {
                    let deadline = "camera supervisor exceeded shutdown deadline";
                    return match self.wait().await {
                        Ok(()) => Err(deadline.to_string()),
                        Err(error) => Err(format!("{deadline}; {error}")),
                    };
                }
            };

        match (request_error, supervisor_result) {
            (None, Ok(())) => Ok(()),
            (Some(error), Ok(())) | (None, Err(error)) => Err(error),
            (Some(request_error), Err(supervisor_error)) => {
                Err(format!("{request_error}; {supervisor_error}"))
            }
        }
    }
}

#[async_trait]
impl Backend for CameraBackend {
    fn preview_frames(&self) -> FrameStream {
        Box::pin(WatchStream::new(self.frames_tx.subscribe()).filter_map(|frame| frame))
    }

    async fn start_recording(&self) -> Result<(), BackendError> {
        if self.hub.snapshot().commissioning.state != CommissioningState::Complete {
            return Err(BackendError::CommissioningIncomplete);
        }
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
        self.hub.drive_now(Input::ClipRemoved { id });
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
        storage_generation: Option<String>,
        soc_temp_c: Option<f32>,
        mem: Option<MemInfo>,
        cpu: Cpu,
    ) {
        self.hub
            .update_telemetry(storage, storage_generation, soc_temp_c, mem, cpu);
    }

    fn update_storage(&self, storage: Option<DiskUsage>, storage_generation: Option<String>) {
        self.hub.update_storage(storage, storage_generation);
    }

    fn update_commissioning(&self, commissioning: Commissioning) {
        self.hub.update_commissioning(commissioning);
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
    AckSegment {
        kind: SegmentAckKind,
        session_id: u64,
        id: SegmentId,
    },
    SegmentReserved {
        session_id: u64,
        id: SegmentId,
    },
    TransactionRejected {
        session_id: u64,
        detail: String,
    },
    Shutdown,
}

#[derive(Clone, Copy, Debug, serde::Serialize)]
#[serde(rename_all = "snake_case")]
enum SegmentAckKind {
    Opened,
    Finalized,
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
        durable_bytes: u64,
    },
    SegmentFinalized {
        #[serde(rename = "session_id")]
        session: u64,
        id: SegmentId,
        dur_ms: u64,
    },
    SegmentNeeded {
        #[serde(rename = "session_id")]
        session: u64,
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
    storage: Arc<StorageCoordinator>,
    frames_tx: watch::Sender<Option<Bytes>>,
    hub: Arc<EventHub>,
    mut commands_rx: mpsc::Receiver<Command>,
    mut shutdown_rx: oneshot::Receiver<()>,
    time_store: Arc<TimeStore>,
) -> Result<(), String> {
    let mut child = None;
    let result = std::panic::AssertUnwindSafe(supervise_loop(
        config.clone(),
        storage.clone(),
        frames_tx.clone(),
        hub.clone(),
        &mut commands_rx,
        &mut shutdown_rx,
        time_store.clone(),
        &mut child,
    ))
    .catch_unwind()
    .await;
    match result {
        Ok(result) => result,
        Err(_) => {
            let mut retirement = match child.take() {
                Some(running) => {
                    retire_child(
                        running,
                        true,
                        Some(RetirementContext {
                            hub: &hub,
                            storage: storage.clone(),
                            time_store: time_store.clone(),
                        }),
                    )
                    .await
                }
                None => Ok(()),
            };
            if let Err(error) = reconcile_after_owner(storage, &hub, time_store).await {
                retirement = Err(match retirement {
                    Ok(()) => error,
                    Err(retirement) => format!("{retirement}; {error}"),
                });
            }
            finish_shutdown(&frames_tx, &hub);
            match retirement {
                Ok(()) => Err("camera supervisor panicked".to_string()),
                Err(error) => Err(format!("camera supervisor panicked; {error}")),
            }
        }
    }
}

#[allow(clippy::too_many_arguments)]
async fn supervise_loop(
    config: CameraConfig,
    storage: Arc<StorageCoordinator>,
    frames_tx: watch::Sender<Option<Bytes>>,
    hub: Arc<EventHub>,
    commands_rx: &mut mpsc::Receiver<Command>,
    shutdown_rx: &mut oneshot::Receiver<()>,
    time_store: Arc<TimeStore>,
    child: &mut Option<RunningChild>,
) -> Result<(), String> {
    let mut backoff = BACKOFF_BASE;
    let mut next_spawn = tokio::time::Instant::now();
    let mut pending: Option<Command> = None;

    loop {
        match shutdown_rx.try_recv() {
            Ok(()) | Err(tokio::sync::oneshot::error::TryRecvError::Closed) => {
                if let Some(command) = pending.take() {
                    let _ = command
                        .ack_tx
                        .send(Err(BackendError::camera_command_channel(
                            "camera supervisor shut down",
                        )));
                }
                let result = match child.take() {
                    Some(running) => {
                        retire_child(
                            running,
                            true,
                            Some(RetirementContext {
                                hub: &hub,
                                storage: storage.clone(),
                                time_store: time_store.clone(),
                            }),
                        )
                        .await
                    }
                    None => Ok(()),
                };
                finish_shutdown(&frames_tx, &hub);
                return result;
            }
            Err(tokio::sync::oneshot::error::TryRecvError::Empty) => {}
        }

        if child.is_none() && tokio::time::Instant::now() >= next_spawn {
            hub.drive_now(Input::CameraState(CameraState::Starting));
            if let Err(error) =
                reconcile_after_owner(storage.clone(), &hub, time_store.clone()).await
            {
                tracing::error!(%error, "recording reconciliation blocked camera replacement");
                hub.drive_now(Input::CameraState(CameraState::Restarting));
                next_spawn = tokio::time::Instant::now() + backoff;
                backoff = (backoff * 2).min(BACKOFF_CAP);
                continue;
            }
            match spawn_running_child(&config, frames_tx.clone()) {
                Ok(running) => *child = Some(running),
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
                storage.clone(),
                time_store.clone(),
                shutdown_rx,
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
                    let _ =
                        retire_child(child.take().expect("executing child exists"), false, None)
                            .await;
                    let detail = match reconcile_after_owner(
                        storage.clone(),
                        &hub,
                        time_store.clone(),
                    )
                    .await
                    {
                        Ok(()) => detail,
                        Err(error) => format!("{detail}; {error}"),
                    };
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
                    let _ =
                        retire_child(child.take().expect("executing child exists"), false, None)
                            .await;
                    let detail = match reconcile_after_owner(
                        storage.clone(),
                        &hub,
                        time_store.clone(),
                    )
                    .await
                    {
                        Ok(()) => detail,
                        Err(error) => format!("{detail}; {error}"),
                    };
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
                    let result = retire_child(
                        child.take().expect("executing child exists"),
                        true,
                        Some(RetirementContext {
                            hub: &hub,
                            storage: storage.clone(),
                            time_store: time_store.clone(),
                        }),
                    )
                    .await;
                    finish_shutdown(&frames_tx, &hub);
                    hub.drive_now(Input::Fail { detail });
                    let _ = ack_tx.send(Err(error));
                    return result;
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
                            let _ = retire_child(running, true, Some(RetirementContext {
                                hub: &hub,
                                storage: storage.clone(),
                                time_store: time_store.clone(),
                            })).await;
                        }
                        finish_shutdown(&frames_tx, &hub);
                        return Err("camera command channel closed".to_string());
                    }
                }
            }
            _ = tokio::time::sleep_until(pending_deadline), if pending.is_some() => {}
            _ = tokio::time::sleep_until(spawn_deadline), if child.is_none() => {}
            signal = next_optional_child_signal(child) => {
                match signal {
                    ChildSignal::Event(event) => {
                        #[cfg(test)]
                        let panic_after_event = config.panic_after_segment_opened
                            && matches!(event, ChildEvent::SegmentOpened { .. });
                        let mut fatal_detail = match &event {
                            ChildEvent::Error { detail } => Some(detail.clone()),
                            _ => None,
                        };
                        let running = child.as_mut().expect("child branch guarded");
                        let response = apply_child_event(
                            event,
                            &mut running.ready,
                            &mut running.event_state,
                            &hub,
                            storage.clone(),
                            time_store.clone(),
                        ).await;
                        if let Some(response) = response {
                            if let Err(error) = write_command(&mut running.stdin, &response).await {
                                tracing::error!(?error, "failed to acknowledge camera lifecycle event");
                                fatal_detail.get_or_insert_with(|| {
                                    "camera lifecycle acknowledgement write failed".to_string()
                                });
                            }
                        }
                        #[cfg(test)]
                        if panic_after_event {
                            panic!("injected supervisor panic after segment opened");
                        }
                        if let Some(detail) = fatal_detail {
                            let running = child.take().expect("fatal child exists");
                            let started = running.started;
                            let _ = retire_child(running, false, None).await;
                            let detail = match reconcile_after_owner(storage.clone(), &hub, time_store.clone()).await {
                                Ok(()) => detail,
                                Err(error) => format!("{detail}; {error}"),
                            };
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
                        let _ = retire_child(running, false, None).await;
                        let detail = match reconcile_after_owner(storage.clone(), &hub, time_store.clone()).await {
                            Ok(()) => "camera process exited".to_string(),
                            Err(error) => format!("camera process exited; {error}"),
                        };
                        note_child_lost(&frames_tx, &hub, &detail);
                        if started.elapsed() >= BACKOFF_RESET_AFTER {
                            backoff = BACKOFF_BASE;
                        }
                        next_spawn = tokio::time::Instant::now() + backoff;
                        backoff = (backoff * 2).min(BACKOFF_CAP);
                    }
                }
            }
            _ = &mut *shutdown_rx => {
                if let Some(command) = pending.take() {
                    let _ = command.ack_tx.send(Err(
                        BackendError::camera_command_channel("camera supervisor shut down"),
                    ));
                }
                if let Some(running) = child.take() {
                    let result = retire_child(running, true, Some(RetirementContext {
                        hub: &hub,
                        storage: storage.clone(),
                        time_store: time_store.clone(),
                    })).await;
                    finish_shutdown(&frames_tx, &hub);
                    return result;
                }
                finish_shutdown(&frames_tx, &hub);
                return Ok(());
            }
        }
    }
}

fn spawn_child(config: &CameraConfig) -> std::io::Result<Child> {
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
    stdout_task: tokio::task::JoinHandle<Result<(), String>>,
    stderr_task: tokio::task::JoinHandle<Result<(), String>>,
    ready: bool,
    started: Instant,
    event_state: ChildEventState,
}

#[derive(Default)]
struct ChildEventState {
    last_opened: Option<(u64, SegmentId)>,
    last_finalized: Option<(u64, SegmentId)>,
    reserved: Option<(u64, SegmentId)>,
}

fn spawn_running_child(
    config: &CameraConfig,
    frames_tx: watch::Sender<Option<Bytes>>,
) -> std::io::Result<RunningChild> {
    let mut child = spawn_child(config)?;
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
    storage: Arc<StorageCoordinator>,
    time_store: Arc<TimeStore>,
}

async fn execute_command(
    child: &mut RunningChild,
    command: Command,
    hub: &Arc<EventHub>,
    storage: Arc<StorageCoordinator>,
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
        storage,
        time_store,
    };
    let failure = match write_until_terminal(child, &active, command.deadline, shutdown_rx).await {
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

    let _delivered_failure =
        drain_delivered_events(child, hub, event_context.storage, event_context.time_store).await;
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
    shutdown_rx: &mut oneshot::Receiver<()>,
) -> Result<(), TerminalFailure> {
    let write = write_command(&mut child.stdin, &active.child_command);
    tokio::pin!(write);
    tokio::select! {
            result = &mut write => result.map_err(|_| TerminalFailure::Write),
            result = child.process.wait() => {
                if let Err(error) = result { tracing::warn!(%error, "failed waiting for camera child"); }
                Err(TerminalFailure::Exited)
            }
            _ = tokio::time::sleep_until(deadline) => Err(TerminalFailure::Timeout),
            _ = &mut *shutdown_rx => Err(TerminalFailure::Shutdown),
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
                    if let Some(detail) = apply_command_event(child, event, hub, event_context.storage.clone(), event_context.time_store.clone()).await {
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
    child: &mut RunningChild,
    event: ChildEvent,
    hub: &Arc<EventHub>,
    storage: Arc<StorageCoordinator>,
    time_store: Arc<TimeStore>,
) -> Option<String> {
    let detail = match &event {
        ChildEvent::Error { detail } => Some(detail.clone()),
        _ => None,
    };
    let response = apply_child_event(
        event,
        &mut child.ready,
        &mut child.event_state,
        hub,
        storage,
        time_store,
    )
    .await;
    if let Some(response) = response {
        if write_command(&mut child.stdin, &response).await.is_err() {
            return Some("camera lifecycle acknowledgement write failed".to_string());
        }
    }
    detail
}

async fn drain_delivered_events(
    child: &mut RunningChild,
    hub: &Arc<EventHub>,
    storage: Arc<StorageCoordinator>,
    time_store: Arc<TimeStore>,
) -> Option<String> {
    let mut failure = None;
    while let Ok(event) = child.events_rx.try_recv() {
        if let ChildEvent::Error { detail } = &event {
            failure.get_or_insert_with(|| detail.clone());
        }
        let _ = apply_child_event(
            event,
            &mut child.ready,
            &mut child.event_state,
            hub,
            storage.clone(),
            time_store.clone(),
        )
        .await;
    }
    failure
}

fn target_reached(hub: &EventHub, active: &ActiveCommand) -> bool {
    hub.phase() == active.target && hub.session() == active.session
}

struct RetirementContext<'a> {
    hub: &'a Arc<EventHub>,
    storage: Arc<StorageCoordinator>,
    time_store: Arc<TimeStore>,
}

async fn retire_child(
    mut child: RunningChild,
    graceful: bool,
    mut context: Option<RetirementContext<'_>>,
) -> Result<(), String> {
    let mut failure = None;
    if graceful {
        match tokio::time::timeout(
            SHUTDOWN_TIMEOUT,
            write_command(&mut child.stdin, &ChildCommand::Shutdown),
        )
        .await
        {
            Ok(Ok(())) => {}
            Ok(Err(error)) => {
                failure = Some(format!(
                    "camera shutdown command failed: {}",
                    error.message()
                ))
            }
            Err(_) => failure = Some("camera shutdown command timed out".to_string()),
        }

        if failure.is_none() {
            let deadline = tokio::time::Instant::now() + SHUTDOWN_TIMEOUT;
            loop {
                tokio::select! {
                    result = child.process.wait() => {
                        match result {
                            Ok(status) if status.success() => {}
                            Ok(status) => failure = Some(format!(
                                "camera child exited unsuccessfully during shutdown: {status}"
                            )),
                            Err(error) => failure = Some(format!("failed to reap camera child: {error}")),
                        }
                        break;
                    }
                    event = child.events_rx.recv(), if child.events_open => match event {
                        Some(event) => {
                            if let Some(context) = context.as_ref() {
                                let response = apply_child_event(
                                    event,
                                    &mut child.ready,
                                    &mut child.event_state,
                                    context.hub,
                                    context.storage.clone(),
                                    context.time_store.clone(),
                                ).await;
                                if let Some(response) = response {
                                    if write_command(&mut child.stdin, &response).await.is_err() {
                                        failure = Some("camera lifecycle acknowledgement failed during shutdown".to_string());
                                        break;
                                    }
                                }
                            }
                        }
                        None => child.events_open = false,
                    },
                    _ = tokio::time::sleep_until(deadline) => {
                        failure = Some("camera child exceeded graceful shutdown deadline".to_string());
                        break;
                    }
                }
            }
        }
    }

    if !graceful || failure.is_some() {
        if let Err(error) = child.process.kill().await {
            if error.kind() != std::io::ErrorKind::InvalidInput && failure.is_none() {
                failure = Some(format!("failed to kill camera child: {error}"));
            }
        }
        if let Err(error) = child.process.wait().await {
            if failure.is_none() {
                failure = Some(format!("failed to reap camera child: {error}"));
            }
        }
        if graceful && failure.is_none() {
            failure = Some("camera shutdown required forced retirement".to_string());
        }
    }

    let stdin = std::mem::replace(&mut child.stdin, Box::pin(tokio::io::sink()));
    drop(stdin);
    if !graceful {
        child.stderr_task.abort();
        child.stdout_task.abort();
    }
    join_reader(&mut child.stderr_task, "stderr", &mut failure).await;
    join_reader(&mut child.stdout_task, "stdout", &mut failure).await;

    if let Some(context) = context.take() {
        if let Some(detail) =
            drain_delivered_events(&mut child, context.hub, context.storage, context.time_store)
                .await
        {
            failure.get_or_insert_with(|| format!("camera shutdown protocol failed: {detail}"));
        }
        if context.hub.phase() != RecorderPhase::Idle {
            failure.get_or_insert_with(|| {
                "camera shutdown completed without terminal recording finalization".to_string()
            });
        }
    }

    match failure {
        Some(error) => Err(error),
        None => Ok(()),
    }
}

async fn join_reader(
    task: &mut tokio::task::JoinHandle<Result<(), String>>,
    name: &str,
    failure: &mut Option<String>,
) {
    match tokio::time::timeout(Duration::from_secs(1), &mut *task).await {
        Ok(Ok(Ok(()))) => {}
        Ok(Ok(Err(error))) => {
            failure.get_or_insert_with(|| format!("camera {name} reader failed: {error}"));
        }
        Ok(Err(error)) if error.is_cancelled() => {}
        Ok(Err(error)) => {
            failure.get_or_insert_with(|| format!("camera {name} reader failed: {error}"));
        }
        Err(_) => {
            task.abort();
            let _ = task.await;
            failure.get_or_insert_with(|| format!("camera {name} reader did not reach EOF"));
        }
    }
}

#[cfg(test)]
fn finish_child(child: RunningChild) {
    child.stdout_task.abort();
    child.stderr_task.abort();
}

async fn reconcile_after_owner(
    storage: Arc<StorageCoordinator>,
    hub: &Arc<EventHub>,
    time_store: Arc<TimeStore>,
) -> Result<(), String> {
    let reconcile_storage = storage.clone();
    let report =
        tokio::task::spawn_blocking(move || reconcile_storage.reconcile_recording_artifacts())
            .await
            .map_err(|error| format!("recording reconciliation task failed: {error}"))?
            .map_err(|error| format!("recording reconciliation failed: {error}"))?;
    let scrub_storage = storage.clone();
    tokio::task::spawn_blocking(move || scrub_storage.scrub_unrecoverable_segments())
        .await
        .map_err(|error| format!("recording scrub task failed: {error}"))?
        .map_err(|error| format!("recording scrub failed: {error}"))?;

    for id in report.finalized {
        let Some(finalized) = finalized_clip_meta(storage.clone(), id, time_store.clone()).await
        else {
            return Err(format!("failed to publish reconciled segment {id}"));
        };
        if hub.current_segment() == Some(id) && hub.session() == finalized.session.unwrap_or(0) {
            hub.drive_now(Input::SegmentFinalized {
                session: hub.session(),
                finalized,
            });
        } else {
            hub.drive_now(Input::RecoveredClip { finalized });
        }
    }
    hub.drive_now(Input::RecordingArtifactsReconciled);
    Ok(())
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
) -> Result<(), String> {
    let mut lines = BufReader::new(stderr).lines();
    loop {
        let line = lines
            .next_line()
            .await
            .map_err(|error| format!("failed reading camera child stderr: {error}"))?;
        let Some(line) = line else {
            return Ok(());
        };
        match classify_stderr_line(&line) {
            Ok(Some(event)) => {
                if events_tx.send(event).await.is_err() {
                    return Ok(());
                }
            }
            Ok(None) => tracing::info!(line = %line, "camera child stderr"),
            Err(detail) => {
                tracing::error!(line = %line, %detail, "invalid camera child event");
                if events_tx.send(ChildEvent::Error { detail }).await.is_err() {
                    return Ok(());
                }
            }
        }
    }
}

fn classify_stderr_line(line: &str) -> Result<Option<ChildEvent>, String> {
    match serde_json::from_str::<serde_json::Value>(line) {
        Ok(value) if value.get("event").is_some() => serde_json::from_value(value)
            .map(Some)
            .map_err(|error| format!("invalid camera event record: {error}")),
        Ok(_) => Ok(None),
        Err(error) if line.contains("\"event\"") => {
            Err(format!("invalid camera event record: {error}"))
        }
        Err(_) => Ok(None),
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

async fn drain_stdout(
    mut stdout: ChildStdout,
    frames_tx: watch::Sender<Option<Bytes>>,
) -> Result<(), String> {
    let mut splitter = JpegSplitter::new();
    let mut buffer = [0_u8; 8192];

    loop {
        match stdout.read(&mut buffer).await {
            Ok(0) => return Ok(()),
            Ok(bytes_read) => {
                for frame in splitter.push(&buffer[..bytes_read]) {
                    frames_tx.send_replace(Some(Bytes::from(frame)));
                }
            }
            Err(error) => {
                tracing::warn!(%error, "failed reading camera child stdout");
                return Err(error.to_string());
            }
        }
    }
}

async fn apply_child_event(
    event: ChildEvent,
    ready: &mut bool,
    event_state: &mut ChildEventState,
    hub: &Arc<EventHub>,
    storage: Arc<StorageCoordinator>,
    time_store: Arc<TimeStore>,
) -> Option<ChildCommand> {
    match event {
        ChildEvent::Ready => {
            *ready = true;
            hub.drive_now(Input::CameraState(CameraState::Running));
            None
        }
        ChildEvent::SensorTemp { celsius } => {
            hub.drive_now(Input::SensorTemp {
                celsius: celsius.filter(|value| value.is_finite()),
            });
            None
        }
        ChildEvent::RecordingStarted { session } => {
            tracing::warn!(session, "ignoring obsolete recording_started truth claim");
            None
        }
        ChildEvent::SegmentOpened {
            session,
            id,
            durable_bytes,
        } => {
            if event_state.last_opened == Some((session, id)) {
                return Some(ChildCommand::AckSegment {
                    kind: SegmentAckKind::Opened,
                    session_id: session,
                    id,
                });
            }
            let expected = event_state
                .reserved
                .map_or_else(|| hub.unpullable_from(), |(_, id)| Some(id));
            if session != hub.session() || expected != Some(id) {
                tracing::warn!(
                    session,
                    id,
                    live_session = hub.session(),
                    ?expected,
                    "dropping unexpected segment_opened"
                );
                return None;
            }
            let check_storage = storage.clone();
            let durable = tokio::task::spawn_blocking(move || {
                check_storage.validate_committed_open(session, id, durable_bytes)
            })
            .await
            .ok()
            .and_then(Result::ok)
            .unwrap_or(false);
            if !durable {
                hub.drive_now(Input::Fail {
                    detail: format!("segment {id} was not durably committed-open"),
                });
                return None;
            }
            let accepted = !hub
                .drive_now(Input::Recorder(RecorderEvent::SegmentOpened {
                    session,
                    id,
                }))
                .is_empty();
            if !accepted {
                return None;
            }
            event_state.last_opened = Some((session, id));
            event_state.reserved = None;
            tracing::info!(
                session,
                id,
                durable_bytes,
                "accepted durable segment_opened"
            );
            Some(ChildCommand::AckSegment {
                kind: SegmentAckKind::Opened,
                session_id: session,
                id,
            })
        }
        ChildEvent::SegmentFinalized {
            session,
            id,
            dur_ms,
        } => {
            if event_state.last_finalized == Some((session, id)) {
                return Some(ChildCommand::AckSegment {
                    kind: SegmentAckKind::Finalized,
                    session_id: session,
                    id,
                });
            }
            if event_state.last_opened != Some((session, id)) || session != hub.session() {
                tracing::warn!(
                    session,
                    id,
                    live_session = hub.session(),
                    "dropping unexpected segment_finalized"
                );
                return None;
            }
            let check_storage = storage.clone();
            let metadata_time_store = time_store.clone();
            let Some((finalized, durable_dur_ms)) = tokio::task::spawn_blocking(move || {
                let Some(candidate) = check_storage.validate_finalized(session, id)? else {
                    return Ok(None);
                };
                let storage_generation = check_storage.storage_generation()?;
                let durable_dur_ms = candidate.facts.as_ref().and_then(|facts| facts.dur_ms);
                let finalized = clip_meta_from_candidate(
                    candidate,
                    &storage_generation,
                    durable_dur_ms,
                    metadata_time_store.as_ref(),
                );
                Ok::<_, std::io::Error>(Some((finalized, durable_dur_ms)))
            })
            .await
            .ok()
            .and_then(Result::ok)
            .flatten() else {
                hub.drive_now(Input::Fail {
                    detail: format!("segment {id} was not durably finalized"),
                });
                return None;
            };
            if durable_dur_ms != Some(dur_ms) {
                hub.drive_now(Input::Fail {
                    detail: format!("segment {id} duration disagreed with durable media"),
                });
                return None;
            }
            let accepted = !hub
                .drive_now(Input::SegmentFinalized { session, finalized })
                .is_empty();
            if !accepted {
                return None;
            }
            event_state.last_finalized = Some((session, id));
            Some(ChildCommand::AckSegment {
                kind: SegmentAckKind::Finalized,
                session_id: session,
                id,
            })
        }
        ChildEvent::SegmentNeeded { session } => {
            if let Some((reserved_session, id)) = event_state.reserved {
                return (reserved_session == session).then_some(ChildCommand::SegmentReserved {
                    session_id: session,
                    id,
                });
            }
            if session != hub.session()
                || hub.phase() != RecorderPhase::Recording
                || hub.snapshot().recorder.current_segment.is_some()
            {
                tracing::warn!(
                    session,
                    live_session = hub.session(),
                    "dropping unexpected segment_needed"
                );
                return None;
            }
            let reserve_storage = storage;
            match tokio::task::spawn_blocking(move || reserve_storage.allocate_start_segment())
                .await
            {
                Ok(Ok(id)) => {
                    event_state.reserved = Some((session, id));
                    Some(ChildCommand::SegmentReserved {
                        session_id: session,
                        id,
                    })
                }
                Ok(Err(error)) => Some(ChildCommand::TransactionRejected {
                    session_id: session,
                    detail: format!("segment reservation failed: {error}"),
                }),
                Err(error) => Some(ChildCommand::TransactionRejected {
                    session_id: session,
                    detail: format!("segment reservation task failed: {error}"),
                }),
            }
        }
        ChildEvent::RecordingStopped { session } => {
            if let Some((opened_session, id)) = event_state.last_opened {
                if opened_session == session && event_state.last_finalized != Some((session, id)) {
                    hub.drive_now(Input::Fail {
                        detail: format!("failed to stat final segment {id}"),
                    });
                    return None;
                }
            }
            hub.drive_now(Input::RecordingStopped {
                session,
                finalized: None,
            });
            event_state.last_opened = None;
            event_state.last_finalized = None;
            event_state.reserved = None;
            None
        }
        ChildEvent::Error { detail } => {
            tracing::error!(%detail, "camera child error event");
            hub.drive_now(Input::Fail { detail });
            None
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
    storage: Arc<StorageCoordinator>,
    seq: SegmentId,
    time_store: Arc<TimeStore>,
) -> Option<ClipMeta> {
    let task = tokio::task::spawn_blocking(move || {
        finalize_clip_meta(storage.as_ref(), seq, time_store.as_ref())
    });
    match tokio::time::timeout(FINAL_METADATA_TIMEOUT, task).await {
        Ok(Ok(Ok(meta))) => meta,
        Ok(Ok(Err(error))) => {
            tracing::error!(%error, seq, "failed to stat finalized camera segment");
            None
        }
        Ok(Err(error)) => {
            tracing::error!(%error, seq, "camera clip metadata task failed");
            None
        }
        Err(_) => {
            tracing::error!(seq, "camera clip metadata task timed out");
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
        apply_child_event, classify_stderr_line, execute_command, finish_child, note_child_lost,
        retire_child, supervise, CameraBackend, CameraConfig, CameraProcess, ChildCommand,
        ChildEvent, ChildEventState, Command, CommandIntent, ExecuteOutcome, RunningChild,
        StartHandoffPause, SupervisorControl,
    };
    use crate::{
        backend::{Backend, BackendError},
        event_hub::EventHub,
        events::Event,
        recorder::{
            recording_artifact_filename, stamped_segment_filename, RecorderPhase,
            RecordingArtifactState, SegmentFacts,
        },
        storage::StorageCoordinator,
        time_sync::TimeStore,
        world::{CameraState, Input},
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
                r#"{"event":"segment_opened","session_id":7,"id":5,"durable_bytes":4096}"#
            )
            .unwrap(),
            ChildEvent::SegmentOpened {
                session: 7,
                id: 5,
                durable_bytes: 4096,
            }
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
        assert_eq!(classify_stderr_line("libcamera diagnostic").unwrap(), None);
        assert!(classify_stderr_line(r#"{"event":"future_event"}"#).is_err());
        assert!(classify_stderr_line(r#"{"event":"ready"#).is_err());
    }

    #[tokio::test]
    async fn lifecycle_event_guards_drop_stale_and_wrong_then_ack_duplicate() {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let rec_dir = std::env::temp_dir().join(format!("dancam-event-guards-{nonce}"));
        fs::create_dir_all(&rec_dir).unwrap();
        let storage = Arc::new(StorageCoordinator::new(rec_dir.clone()));
        let hub = Arc::new(EventHub::new(CameraState::Running));
        hub.drive_now(Input::StartCommand { start_segment: 5 });
        let facts = SegmentFacts {
            boot_tag: "abc123def456".to_string(),
            session: 6,
            mono_ms: 1,
            dur_ms: None,
        };
        let artifact = rec_dir.join(recording_artifact_filename(
            RecordingArtifactState::CommittedOpen,
            5,
            &facts,
        ));
        fs::write(&artifact, b"durable").unwrap();
        let mut ready = true;
        let mut event_state = ChildEventState::default();
        let time_store = Arc::new(TimeStore::in_memory());

        for event in [
            ChildEvent::SegmentOpened {
                session: 7,
                id: 5,
                durable_bytes: 7,
            },
            ChildEvent::SegmentOpened {
                session: 6,
                id: 6,
                durable_bytes: 7,
            },
        ] {
            assert!(apply_child_event(
                event,
                &mut ready,
                &mut event_state,
                &hub,
                storage.clone(),
                time_store.clone(),
            )
            .await
            .is_none());
        }
        assert_eq!(hub.phase(), RecorderPhase::Starting);
        assert_eq!(hub.current_segment(), None);

        for _ in 0..2 {
            let response = apply_child_event(
                ChildEvent::SegmentOpened {
                    session: 6,
                    id: 5,
                    durable_bytes: 7,
                },
                &mut ready,
                &mut event_state,
                &hub,
                storage.clone(),
                time_store.clone(),
            )
            .await;
            assert!(matches!(
                response,
                Some(ChildCommand::AckSegment {
                    kind: super::SegmentAckKind::Opened,
                    session_id: 6,
                    id: 5,
                })
            ));
        }
        assert_eq!(hub.phase(), RecorderPhase::Recording);
        assert_eq!(hub.current_segment(), Some(5));

        let _ = fs::remove_dir_all(rec_dir);
    }

    #[tokio::test]
    async fn accepted_finalization_publishes_validated_facts_once_before_ack() {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let rec_dir = std::env::temp_dir().join(format!("dancam-finalized-facts-{nonce}"));
        fs::create_dir_all(&rec_dir).unwrap();
        let storage = Arc::new(StorageCoordinator::new(rec_dir.clone()));
        let hub = Arc::new(EventHub::new(CameraState::Running));
        hub.drive_now(Input::StartCommand { start_segment: 5 });
        let open_facts = SegmentFacts {
            boot_tag: "abc123def456".to_string(),
            session: 6,
            mono_ms: 1,
            dur_ms: None,
        };
        let open_path = rec_dir.join(recording_artifact_filename(
            RecordingArtifactState::CommittedOpen,
            5,
            &open_facts,
        ));
        fs::write(&open_path, b"durable").unwrap();
        let mut ready = true;
        let mut event_state = ChildEventState::default();
        let time_store = Arc::new(TimeStore::in_memory());
        let opened = apply_child_event(
            ChildEvent::SegmentOpened {
                session: 6,
                id: 5,
                durable_bytes: 7,
            },
            &mut ready,
            &mut event_state,
            &hub,
            storage.clone(),
            time_store.clone(),
        )
        .await;
        assert!(matches!(
            opened,
            Some(ChildCommand::AckSegment {
                kind: super::SegmentAckKind::Opened,
                session_id: 6,
                id: 5,
            })
        ));

        let finalized_facts = SegmentFacts {
            dur_ms: Some(300),
            ..open_facts
        };
        fs::rename(
            open_path,
            rec_dir.join(stamped_segment_filename(5, &finalized_facts)),
        )
        .unwrap();
        let mut events = hub.connect();

        let finalized_ack = apply_child_event(
            ChildEvent::SegmentFinalized {
                session: 6,
                id: 5,
                dur_ms: 300,
            },
            &mut ready,
            &mut event_state,
            &hub,
            storage.clone(),
            time_store.clone(),
        )
        .await;

        assert!(matches!(
            finalized_ack,
            Some(ChildCommand::AckSegment {
                kind: super::SegmentAckKind::Finalized,
                session_id: 6,
                id: 5,
            })
        ));
        let published = events.rx.try_recv().unwrap();
        let Event::ClipFinalized(meta) = published.event else {
            panic!("expected clip_finalized, got {:?}", published.event);
        };
        assert_eq!(meta.id, 5);
        assert_eq!(meta.session, Some(6));
        assert_eq!(meta.bytes, 7);
        assert_eq!(meta.dur_ms, Some(300));
        assert_eq!(meta.etag, format!("{}-5-7", meta.storage_generation));
        assert_eq!(meta.start_ms, None);
        assert!(meta.time_approximate);

        let duplicate_ack = apply_child_event(
            ChildEvent::SegmentFinalized {
                session: 6,
                id: 5,
                dur_ms: 300,
            },
            &mut ready,
            &mut event_state,
            &hub,
            storage,
            time_store,
        )
        .await;
        assert!(matches!(
            duplicate_ack,
            Some(ChildCommand::AckSegment {
                kind: super::SegmentAckKind::Finalized,
                session_id: 6,
                id: 5,
            })
        ));
        assert!(events.rx.try_recv().is_err());

        let _ = fs::remove_dir_all(rec_dir);
    }

    #[tokio::test]
    async fn child_duration_mismatch_fails_without_publication_or_ack() {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let rec_dir = std::env::temp_dir().join(format!("dancam-duration-mismatch-{nonce}"));
        fs::create_dir_all(&rec_dir).unwrap();
        let facts = SegmentFacts {
            boot_tag: "abc123def456".to_string(),
            session: 6,
            mono_ms: 1,
            dur_ms: Some(300),
        };
        fs::write(
            rec_dir.join(stamped_segment_filename(5, &facts)),
            b"durable",
        )
        .unwrap();
        let storage = Arc::new(StorageCoordinator::new(rec_dir.clone()));
        let hub = Arc::new(EventHub::new(CameraState::Running));
        hub.drive_now(Input::StartCommand { start_segment: 5 });
        hub.drive_now(Input::Recorder(
            crate::recorder::RecorderEvent::SegmentOpened { session: 6, id: 5 },
        ));
        let mut event_state = ChildEventState {
            last_opened: Some((6, 5)),
            ..ChildEventState::default()
        };
        let mut ready = true;
        let mut events = hub.connect();

        let response = apply_child_event(
            ChildEvent::SegmentFinalized {
                session: 6,
                id: 5,
                dur_ms: 301,
            },
            &mut ready,
            &mut event_state,
            &hub,
            storage,
            Arc::new(TimeStore::in_memory()),
        )
        .await;

        assert!(response.is_none());
        assert_eq!(hub.phase(), RecorderPhase::Error);
        assert!(events
            .rx
            .try_recv()
            .is_ok_and(|event| matches!(event.event, Event::RecorderFailed { .. })));
        assert!(events.rx.try_recv().is_err());
        assert_eq!(event_state.last_finalized, None);

        let _ = fs::remove_dir_all(rec_dir);
    }

    #[tokio::test]
    async fn shutdown_joins_supervisor_after_request_channel_closes() {
        let (shutdown_tx, shutdown_rx) = oneshot::channel();
        drop(shutdown_rx);
        let (finished_tx, finished_rx) = oneshot::channel();
        let supervisor = tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(25)).await;
            let _ = finished_tx.send(());
            Ok(())
        });
        let control = SupervisorControl {
            shutdown_tx: Some(shutdown_tx),
            supervisor,
        };

        let error = control.shutdown().await.unwrap_err();

        assert!(error.contains("stopped before shutdown"));
        finished_rx
            .await
            .expect("shutdown returned before the supervisor joined");
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
        let time_store = Arc::new(TimeStore::in_memory());
        let config = CameraConfig::new("/definitely-not-a-camera-program", [] as [&str; 0]);
        let supervisor = tokio::spawn(supervise(
            config,
            Arc::new(StorageCoordinator::new(PathBuf::from("."))),
            frames_tx,
            hub.clone(),
            commands_rx,
            shutdown_rx,
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
        let _supervisor_result = supervisor.await.unwrap();
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
            Arc::new(StorageCoordinator::new(root.join("rec"))),
            frames_tx,
            hub.clone(),
            commands_rx,
            shutdown_rx,
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
        let _supervisor_result = supervisor.await.unwrap();
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
from pathlib import Path
print(json.dumps({"event":"ready"}), file=sys.stderr, flush=True)
threading.Timer(0.05, lambda: print(json.dumps({"event":"sensor_temp","celsius":42.0}), file=sys.stderr, flush=True)).start()
for line in sys.stdin:
    command = json.loads(line)
    if command["cmd"] == "shutdown":
        sys.exit(0)
    if command["cmd"] == "start_recording":
        session = command["session_id"]
        seq = command["start_segment_index"]
        path = Path(sys.argv[-1]) / f".dancam-seg_{seq:05d}_abc123def456_{session}_1.open.ts"
        path.write_bytes(b"segment")
        print(json.dumps({"event":"segment_opened","session_id":session,"id":seq,"durable_bytes":7}), file=sys.stderr, flush=True)
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

        let _shutdown_result = control.shutdown().await;
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
            stdout_task: tokio::spawn(std::future::pending::<Result<(), String>>()),
            stderr_task: tokio::spawn(std::future::pending::<Result<(), String>>()),
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
            Arc::new(StorageCoordinator::new(PathBuf::from("."))),
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
        retire_child(child, false, None).await.unwrap();
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
            stdout_task: tokio::spawn(std::future::pending::<Result<(), String>>()),
            stderr_task: tokio::spawn(std::future::pending::<Result<(), String>>()),
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
            Arc::new(StorageCoordinator::new(PathBuf::from("."))),
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

    #[tokio::test]
    async fn supervisor_panic_retains_child_ownership_and_finalizes_recording() {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let rec_dir = std::env::temp_dir().join(format!("dancam-supervisor-panic-{nonce}"));
        fs::create_dir_all(&rec_dir).unwrap();
        let script = r#"
printf '%s\n' '{"event":"ready"}' >&2
while IFS= read -r line; do
  case "$line" in
    *start_recording*)
      cp "$2" "$1/.dancam-seg_00000_abc123def456_1_1.open.ts"
      printf '%s\n' '{"event":"segment_opened","session_id":1,"id":0,"durable_bytes":1}' >&2
      printf '%s\n' '{"event":"segment_opened","session_id":1,"id":0,"durable_bytes":1}' >&2
      ;;
    *shutdown*)
      mv "$1/.dancam-seg_00000_abc123def456_1_1.open.ts" "$1/seg_00000_abc123def456_1_1_30000.ts"
      printf '%s\n' '{"event":"segment_finalized","session_id":1,"id":0,"dur_ms":30000}' >&2
      printf '%s\n' '{"event":"recording_stopped","session_id":1}' >&2
      exit 0
      ;;
  esac
done
"#;
        let mut config = CameraConfig::new(
            "sh",
            [
                "-c".to_string(),
                script.to_string(),
                "camera-test".to_string(),
                rec_dir.to_string_lossy().to_string(),
                PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                    .join("assets/clips/seg_00000.ts")
                    .to_string_lossy()
                    .to_string(),
                "--rec-dir".to_string(),
                rec_dir.to_string_lossy().to_string(),
            ],
        );
        config.panic_after_segment_opened = true;
        let storage = Arc::new(StorageCoordinator::new(rec_dir.clone()));
        let (backend, mut control) = CameraProcess::spawn(config, storage);
        tokio::time::timeout(Duration::from_secs(2), async {
            while backend.snapshot().camera_state != CameraState::Running {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();

        backend.start_recording().await.unwrap();
        let error = control.wait().await.unwrap_err();

        assert!(error.contains("camera supervisor panicked"));
        assert_eq!(backend.snapshot().recorder.phase, RecorderPhase::Idle);
        assert_eq!(backend.snapshot().camera_state, CameraState::Offline);
        assert!(fs::read_dir(&rec_dir).unwrap().any(|entry| {
            let entry = entry.unwrap();
            entry
                .file_name()
                .to_string_lossy()
                .starts_with("seg_00000_")
                && entry.metadata().unwrap().len() > 0
        }));
        let _ = fs::remove_dir_all(rec_dir);
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
            time_store: Arc::new(TimeStore::in_memory()),
        }
    }
}
