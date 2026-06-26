use std::{
    env,
    process::Stdio,
    time::{Duration, Instant},
};

use async_trait::async_trait;
use bytes::Bytes;
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader},
    process::{Child, ChildStderr, ChildStdout, Command as TokioCommand},
    sync::{broadcast, mpsc, oneshot, watch},
};
use tokio_stream::{wrappers::BroadcastStream, StreamExt};

use crate::{
    backend::{Backend, BackendError, FrameStream},
    jpeg::JpegSplitter,
    status::{CameraState, ChildEvent, Status},
};

const FRAME_CAPACITY: usize = 8;
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
}

impl CameraConfig {
    pub fn new(
        program: impl Into<String>,
        args: impl IntoIterator<Item = impl Into<String>>,
    ) -> Self {
        Self {
            program: program.into(),
            args: args.into_iter().map(Into::into).collect(),
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
        Self::new(
            "python3",
            [
                "/usr/local/lib/dancam/camera.py".to_string(),
                "--rec-dir".to_string(),
                rec_dir,
                "--preview-fps".to_string(),
                preview_fps,
            ],
        )
    }
}

#[derive(Clone)]
pub struct CameraBackend {
    frames_tx: broadcast::Sender<Bytes>,
    status_rx: watch::Receiver<Status>,
    commands_tx: mpsc::Sender<Command>,
}

pub struct CameraProcess;

impl CameraProcess {
    pub fn spawn(config: CameraConfig) -> (CameraBackend, SupervisorControl) {
        let (frames_tx, _) = broadcast::channel(FRAME_CAPACITY);
        let (status_tx, status_rx) = watch::channel(Status::starting());
        let (commands_tx, commands_rx) = mpsc::channel(COMMAND_CAPACITY);
        let (shutdown_tx, shutdown_rx) = oneshot::channel();

        let supervisor = tokio::spawn(supervise(
            config,
            frames_tx.clone(),
            status_tx,
            commands_rx,
            shutdown_rx,
        ));

        let backend = CameraBackend {
            frames_tx,
            status_rx,
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
        Box::pin(BroadcastStream::new(self.frames_tx.subscribe()).filter_map(|result| result.ok()))
    }

    async fn start_recording(&self) -> Result<(), BackendError> {
        self.command_and_wait(CommandKind::StartRecording, |status| status.recording)
            .await
    }

    async fn stop_recording(&self) -> Result<(), BackendError> {
        self.command_and_wait(CommandKind::StopRecording, |status| !status.recording)
            .await
    }

    fn status(&self) -> Status {
        self.status_rx.borrow().clone()
    }
}

impl CameraBackend {
    async fn command_and_wait(
        &self,
        kind: CommandKind,
        predicate: impl Fn(&Status) -> bool,
    ) -> Result<(), BackendError> {
        let mut status_rx = self.status_rx.clone();
        if predicate(&status_rx.borrow()) {
            return Ok(());
        }

        if status_rx.borrow().camera_state != CameraState::Running {
            return Err(BackendError::CameraOffline);
        }

        let (ack_tx, ack_rx) = oneshot::channel();
        self.commands_tx
            .send(Command { kind, ack_tx })
            .await
            .map_err(|_| BackendError::Channel)?;
        ack_rx.await.map_err(|_| BackendError::Channel)??;

        tokio::time::timeout(COMMAND_TIMEOUT, async {
            loop {
                status_rx
                    .changed()
                    .await
                    .map_err(|_| BackendError::Channel)?;
                let status = status_rx.borrow_and_update().clone();
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
    ack_tx: oneshot::Sender<Result<(), BackendError>>,
}

async fn supervise(
    config: CameraConfig,
    frames_tx: broadcast::Sender<Bytes>,
    status_tx: watch::Sender<Status>,
    mut commands_rx: mpsc::Receiver<Command>,
    mut shutdown_rx: oneshot::Receiver<()>,
) {
    let mut backoff = BACKOFF_BASE;

    loop {
        let _ = status_tx.send(Status::starting());
        let started = Instant::now();

        match spawn_child(&config).await {
            Ok(child) => {
                match run_child(
                    child,
                    frames_tx.clone(),
                    status_tx.clone(),
                    &mut commands_rx,
                    &mut shutdown_rx,
                )
                .await
                {
                    ChildOutcome::Shutdown => {
                        let _ = status_tx.send(Status::offline());
                        return;
                    }
                    ChildOutcome::Exited => {
                        let _ = status_tx.send(Status::restarting());
                    }
                }

                if started.elapsed() >= BACKOFF_RESET_AFTER {
                    backoff = BACKOFF_BASE;
                }
            }
            Err(error) => {
                tracing::error!(%error, "failed to start camera child");
                let _ = status_tx.send(Status::restarting());
            }
        }

        tokio::select! {
            _ = tokio::time::sleep(backoff) => {}
            _ = &mut shutdown_rx => {
                let _ = status_tx.send(Status::offline());
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
    frames_tx: broadcast::Sender<Bytes>,
    status_tx: watch::Sender<Status>,
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
    let stderr_task = tokio::spawn(parse_stderr(stderr, status_tx));

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

                let result = write_command(&mut stdin, command.kind).await;
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

async fn drain_stdout(mut stdout: ChildStdout, frames_tx: broadcast::Sender<Bytes>) {
    let mut splitter = JpegSplitter::new();
    let mut buffer = [0_u8; 8192];

    loop {
        match stdout.read(&mut buffer).await {
            Ok(0) => return,
            Ok(bytes_read) => {
                for frame in splitter.push(&buffer[..bytes_read]) {
                    let _ = frames_tx.send(Bytes::from(frame));
                }
            }
            Err(error) => {
                tracing::warn!(%error, "failed reading camera child stdout");
                return;
            }
        }
    }
}

async fn parse_stderr(stderr: ChildStderr, status_tx: watch::Sender<Status>) {
    let mut lines = BufReader::new(stderr).lines();

    while let Ok(Some(line)) = lines.next_line().await {
        match serde_json::from_str::<ChildEvent>(&line) {
            Ok(ChildEvent::Ready) => {
                let _ = status_tx.send(Status::running(false));
            }
            Ok(ChildEvent::RecordingStarted) => {
                patch_status(&status_tx, |status| {
                    status.recording = true;
                    status.camera_state = CameraState::Running;
                });
            }
            Ok(ChildEvent::RecordingStopped) => {
                patch_status(&status_tx, |status| {
                    status.recording = false;
                    status.camera_state = CameraState::Running;
                });
            }
            Ok(ChildEvent::Error { detail }) => {
                tracing::error!(%detail, "camera child error event");
            }
            Err(_) => {
                tracing::info!(line = %line, "camera child stderr");
            }
        }
    }
}

fn patch_status(status_tx: &watch::Sender<Status>, patch: impl FnOnce(&mut Status)) {
    let mut status = status_tx.borrow().clone();
    patch(&mut status);
    let _ = status_tx.send(status);
}
