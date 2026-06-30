use std::{
    env,
    path::PathBuf,
    process::Stdio,
    sync::Arc,
    time::{Duration, Instant},
};

use async_trait::async_trait;
use bytes::Bytes;
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    process::{Child, ChildStderr, ChildStdout, Command as TokioCommand},
    sync::{mpsc, oneshot, watch},
};
use tokio_stream::{wrappers::WatchStream, StreamExt};

use crate::{
    backend::{Backend, BackendError, FrameStream},
    clips::max_clip_seq,
    event_hub::{EventConnection, EventHub},
    events::Snapshot,
    jpeg::JpegSplitter,
    recorder::{RecorderEvent, RecorderPhase, SegmentId},
    sysfacts::{DiskUsage, MemInfo},
    world::{CameraState, Input, LiveStatus, TempC},
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
        Self {
            program: program.into(),
            args: args.into_iter().map(Into::into).collect(),
            rec_dir: PathBuf::from(crate::DEFAULT_REC_DIR),
        }
    }

    pub fn from_env() -> Self {
        if let Ok(raw_command) = env::var("DANCAM_CAMERA_CMD") {
            let mut parts = raw_command.split_whitespace();
            if let Some(program) = parts.next() {
                return Self::new(program, parts);
            }
        }

        let rec_dir = env::var("DANCAM_REC_DIR").unwrap_or_else(|_| "/home/dan/rec".to_string());
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
}

#[derive(Clone)]
pub struct CameraBackend {
    frames_tx: watch::Sender<Option<Bytes>>,
    hub: Arc<EventHub>,
    rec_dir: Arc<std::path::Path>,
    commands_tx: mpsc::Sender<Command>,
}

pub struct CameraProcess;

impl CameraProcess {
    pub fn spawn(config: CameraConfig) -> (CameraBackend, SupervisorControl) {
        let (frames_tx, _) = watch::channel::<Option<Bytes>>(None);
        let hub = Arc::new(EventHub::new(CameraState::Starting));
        let (commands_tx, commands_rx) = mpsc::channel(COMMAND_CAPACITY);
        let (shutdown_tx, shutdown_rx) = oneshot::channel();
        let rec_dir: Arc<std::path::Path> = Arc::from(config.rec_dir.clone().into_boxed_path());

        let supervisor = tokio::spawn(supervise(
            config,
            frames_tx.clone(),
            hub.clone(),
            commands_rx,
            shutdown_rx,
        ));

        let backend = CameraBackend {
            frames_tx,
            hub,
            rec_dir,
            commands_tx,
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
        let start_segment = max_clip_seq(self.rec_dir.as_ref())
            .map(|seq| seq.saturating_add(1))
            .unwrap_or(0);
        self.command_and_wait(
            CommandKind::StartRecording,
            Some(Input::StartCommand { start_segment }),
            |status| status.phase == RecorderPhase::Recording,
        )
        .await
    }

    async fn stop_recording(&self) -> Result<(), BackendError> {
        if self.hub.phase() == RecorderPhase::Idle {
            return Ok(());
        }
        self.command_and_wait(
            CommandKind::StopRecording,
            Some(Input::StopCommand),
            |status| status.phase == RecorderPhase::Idle,
        )
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

impl CameraBackend {
    async fn command_and_wait(
        &self,
        kind: CommandKind,
        command_input: Option<Input>,
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
        let (permit_tx, permit_rx) = oneshot::channel();
        self.commands_tx
            .send(Command {
                kind,
                permit_rx,
                ack_tx,
            })
            .await
            .map_err(|_| BackendError::Channel)?;
        if let Some(input) = command_input {
            self.hub.drive_now(input);
        }
        let _ = permit_tx.send(());
        ack_rx.await.map_err(|_| BackendError::Channel)??;

        tokio::time::timeout(COMMAND_TIMEOUT, async {
            loop {
                live_rx.changed().await.map_err(|_| BackendError::Channel)?;
                let status = live_rx.borrow_and_update().clone();
                if predicate(&status) {
                    return Ok(());
                }
                if matches!(
                    status.camera_state,
                    CameraState::Restarting | CameraState::Offline
                ) {
                    return Err(BackendError::CameraOffline);
                }
            }
        })
        .await
        .map_err(|_| BackendError::Timeout)?
    }
}

#[derive(Clone, Copy, Debug)]
enum CommandKind {
    StartRecording,
    StopRecording,
    Shutdown,
}

impl CommandKind {
    fn json_line(self) -> &'static [u8] {
        match self {
            CommandKind::StartRecording => b"{\"cmd\":\"start_recording\"}\n",
            CommandKind::StopRecording => b"{\"cmd\":\"stop_recording\"}\n",
            CommandKind::Shutdown => b"{\"cmd\":\"shutdown\"}\n",
        }
    }
}

struct Command {
    kind: CommandKind,
    permit_rx: oneshot::Receiver<()>,
    ack_tx: oneshot::Sender<Result<(), BackendError>>,
}

#[derive(Clone, Debug, serde::Deserialize, PartialEq, Eq)]
#[serde(tag = "event", rename_all = "snake_case")]
enum ChildEvent {
    Ready,
    RecordingStarted,
    RecordingStopped,
    Error {
        #[serde(default)]
        detail: String,
    },
}

async fn supervise(
    config: CameraConfig,
    frames_tx: watch::Sender<Option<Bytes>>,
    hub: Arc<EventHub>,
    mut commands_rx: mpsc::Receiver<Command>,
    mut shutdown_rx: oneshot::Receiver<()>,
) {
    let mut backoff = BACKOFF_BASE;

    loop {
        hub.drive_now(Input::CameraState(CameraState::Starting));
        let started = Instant::now();

        match spawn_child(&config).await {
            Ok(child) => {
                match run_child(
                    child,
                    frames_tx.clone(),
                    hub.clone(),
                    &mut commands_rx,
                    &mut shutdown_rx,
                )
                .await
                {
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

async fn run_child(
    mut child: Child,
    frames_tx: watch::Sender<Option<Bytes>>,
    hub: Arc<EventHub>,
    commands_rx: &mut mpsc::Receiver<Command>,
    shutdown_rx: &mut oneshot::Receiver<()>,
) -> ChildOutcome {
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
    let stderr_task = tokio::spawn(parse_stderr(stderr, hub));

    loop {
        tokio::select! {
            command = commands_rx.recv() => {
                let Some(command) = command else {
                    let _ = write_command(&mut stdin, CommandKind::Shutdown).await;
                    let _ = child.wait().await;
                    stdout_task.abort();
                    stderr_task.abort();
                    return ChildOutcome::Shutdown;
                };

                let result = match command.permit_rx.await {
                    Ok(()) => write_command(&mut stdin, command.kind).await,
                    Err(_) => Err(BackendError::Channel),
                };
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
                let _ = write_command(&mut stdin, CommandKind::Shutdown).await;
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
    kind: CommandKind,
) -> Result<(), BackendError> {
    stdin
        .write_all(kind.json_line())
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

async fn parse_stderr(stderr: ChildStderr, hub: Arc<EventHub>) {
    let mut lines = BufReader::new(stderr).lines();

    while let Ok(Some(line)) = lines.next_line().await {
        match serde_json::from_str::<ChildEvent>(&line) {
            Ok(ChildEvent::Ready) => {
                hub.drive_now(Input::CameraState(CameraState::Running));
            }
            Ok(ChildEvent::RecordingStarted) => {
                let session = hub.session();
                hub.drive_now(Input::Recorder(RecorderEvent::RecordingStarted { session }));
            }
            Ok(ChildEvent::RecordingStopped) => {
                let session = hub.session();
                hub.drive_now(Input::RecordingStopped {
                    session,
                    finalized: None,
                });
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

#[cfg(test)]
mod tests {
    use super::ChildEvent;

    #[test]
    fn child_event_parses_stderr_contract() {
        assert_eq!(
            serde_json::from_str::<ChildEvent>(r#"{"event":"ready"}"#).unwrap(),
            ChildEvent::Ready
        );
        assert_eq!(
            serde_json::from_str::<ChildEvent>(r#"{"event":"error","detail":"camera failed"}"#)
                .unwrap(),
            ChildEvent::Error {
                detail: "camera failed".to_string()
            }
        );
    }
}
