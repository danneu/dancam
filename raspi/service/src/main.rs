use std::{
    env, io,
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

use axum_server::Handle;
use dancam::{
    app,
    backend::MockBackend,
    camera::{CameraConfig, CameraProcess, SupervisorControl},
    dual_stack_listener, resolve_boot_id,
    storage::StorageCoordinator,
    AppState,
};
use tokio::task::{JoinHandle, JoinSet};
use tokio_util::sync::CancellationToken;

const SERVER_GRACE: Duration = Duration::from_secs(2);
type WorkerOutcome = (&'static str, Result<(), String>);
type WorkerJoinResult = Result<WorkerOutcome, tokio::task::JoinError>;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt::init();

    let shutdown = CancellationToken::new();
    let signals = SignalMonitor::install()?;
    let signal_task = signals.spawn(shutdown.clone());

    let result = run(shutdown.clone()).await;
    shutdown.cancel();
    let signal_result = signal_task
        .await
        .map_err(|error| io::Error::other(format!("signal monitor task failed: {error}")))?;
    signal_result?;
    result.map_err(|error| io::Error::other(error).into())
}

async fn run(shutdown: CancellationToken) -> Result<(), String> {
    if shutdown.is_cancelled() {
        return Ok(());
    }

    let bind = env::var("DANCAM_BIND").unwrap_or_else(|_| "127.0.0.1:8080".to_string());
    let listener = dual_stack_listener(&bind).map_err(|error| error.to_string())?;
    listener
        .set_nonblocking(true)
        .map_err(|error| error.to_string())?;
    let local_addr = listener.local_addr().map_err(|error| error.to_string())?;
    let server = axum_server::from_tcp(listener).map_err(|error| error.to_string())?;
    let boot_id = resolve_boot_id();
    let required_rec_mountpoint = env::var_os("DANCAM_REQUIRE_REC_MOUNT").map(PathBuf::from);

    let (state, mut supervisor, is_mock): (AppState, Option<SupervisorControl>, bool) =
        match env::var("DANCAM_BACKEND").as_deref() {
            Ok("camera") => {
                let config = CameraConfig::from_env();
                let storage = Arc::new(storage_coordinator(
                    config.rec_dir().to_path_buf(),
                    required_rec_mountpoint.as_deref(),
                ));
                if shutdown.is_cancelled() {
                    return Ok(());
                }
                let (backend, supervisor) = CameraProcess::spawn(config, storage.clone());
                (
                    AppState::new(boot_id, backend).with_storage(storage),
                    Some(supervisor),
                    false,
                )
            }
            Ok("mock") | Err(_) => {
                let rec_dir = env::var_os("DANCAM_REC_DIR")
                    .map_or_else(|| PathBuf::from(dancam::DEFAULT_REC_DIR), PathBuf::from);
                let storage = Arc::new(storage_coordinator(
                    rec_dir,
                    required_rec_mountpoint.as_deref(),
                ));
                prepare_recording_storage(storage.as_ref());
                if shutdown.is_cancelled() {
                    return Ok(());
                }
                let roll_interval = mock_segment_interval();
                (
                    AppState::new(
                        boot_id,
                        MockBackend::recording_to(storage.clone(), roll_interval),
                    )
                    .with_storage(storage),
                    None,
                    true,
                )
            }
            Ok(other) => return Err(format!("unknown DANCAM_BACKEND {other:?}")),
        };
    let state = state
        .with_service_port(local_addr.port())
        .with_shutdown(shutdown.clone());
    if shutdown.is_cancelled() {
        return finish_startup_cancellation(state.backend.clone(), supervisor).await;
    }

    let gc = dancam::gc::GcConfig::from_env(state.storage.rec_dir());
    let recording_capacity_override = is_mock
        .then(|| {
            env::var("DANCAM_MOCK_RECORDING_CAPACITY_BYTES")
                .ok()?
                .parse()
                .ok()
        })
        .flatten();
    let state = state.with_filesystem_config(gc.floor_bytes, recording_capacity_override);
    dancam::events::seed_filesystem_observation(&state).await;
    if shutdown.is_cancelled() {
        return finish_startup_cancellation(state.backend.clone(), supervisor).await;
    }

    let heartbeat = dancam::events::spawn_heartbeat(
        state.backend.clone(),
        Duration::from_secs(2),
        shutdown.clone(),
    );
    let telemetry = dancam::events::spawn_telemetry(
        state.backend.clone(),
        state.filesystem.clone(),
        Duration::from_secs(2),
        shutdown.clone(),
    );
    let gc_task = if gc.floor_bytes > 0 {
        tracing::info!(floor_bytes = gc.floor_bytes, "segment gc enabled");
        Some(dancam::gc::spawn_gc(
            state.storage.clone(),
            state.backend.clone(),
            gc,
            shutdown.clone(),
        ))
    } else {
        None
    };
    let mut workers: JoinSet<WorkerOutcome> = JoinSet::new();
    track_worker(&mut workers, "heartbeat", heartbeat);
    track_worker(&mut workers, "telemetry", telemetry);
    if let Some(gc_task) = gc_task {
        track_worker(&mut workers, "ring GC", gc_task);
    }

    tracing::info!(%local_addr, "listening");
    let server_handle = Handle::new();
    let server = server
        .handle(server_handle.clone())
        .serve(app(state.clone()).into_make_service());
    let mut server_task = tokio::spawn(server);
    let mut server_result = None;
    let mut camera_result = None;
    let mut worker_result = None;
    let mut backend_failure_result = None;
    let mut initiating_error = None;
    let lifecycle_backend = state.backend.clone();

    tokio::select! {
        biased;
        _ = shutdown.cancelled() => {}
        result = &mut server_task => {
            server_result = Some(result);
            initiating_error = Some("HTTP server stopped unexpectedly".to_string());
            shutdown.cancel();
        }
        result = wait_for_camera(&mut supervisor), if supervisor.is_some() => {
            camera_result = Some(result);
            supervisor.take();
            initiating_error = Some("camera supervisor stopped unexpectedly".to_string());
            shutdown.cancel();
        }
        result = workers.join_next(), if !workers.is_empty() => {
            worker_result = result;
            initiating_error = Some("background worker stopped unexpectedly".to_string());
            shutdown.cancel();
        }
        result = lifecycle_backend.wait_for_failure() => {
            backend_failure_result = Some(result);
            initiating_error = Some("backend task stopped unexpectedly".to_string());
            shutdown.cancel();
        }
    }

    server_handle.graceful_shutdown(Some(SERVER_GRACE));
    let backend = state.backend.clone();
    let server_join = async {
        match server_result {
            Some(result) => result,
            None => server_task.await,
        }
        .map_err(|error| format!("HTTP server task failed: {error}"))?
        .map_err(|error| format!("HTTP server failed: {error}"))
    };
    let camera_join = async {
        match (camera_result, supervisor) {
            (Some(result), _) => result,
            (None, Some(supervisor)) => supervisor.shutdown().await,
            (None, None) => Ok(()),
        }
    };
    let workers_join = join_workers(workers, worker_result);

    let (server_result, camera_result, backend_result, workers_result) =
        tokio::join!(server_join, camera_join, backend.shutdown(), workers_join,);

    let mut failures = initiating_error.into_iter().collect::<Vec<_>>();
    if let Some(Err(error)) = backend_failure_result {
        failures.push(error);
    }
    for result in [server_result, camera_result, backend_result, workers_result] {
        if let Err(error) = result {
            failures.push(error);
        }
    }
    if failures.is_empty() {
        Ok(())
    } else {
        Err(failures.join("; "))
    }
}

fn track_worker(workers: &mut JoinSet<WorkerOutcome>, name: &'static str, worker: JoinHandle<()>) {
    workers.spawn(async move {
        let result = worker
            .await
            .map_err(|error| format!("{name} task failed: {error}"));
        (name, result)
    });
}

async fn finish_startup_cancellation(
    backend: Arc<dyn dancam::backend::Backend>,
    supervisor: Option<SupervisorControl>,
) -> Result<(), String> {
    let camera = async {
        match supervisor {
            Some(supervisor) => supervisor.shutdown().await,
            None => Ok(()),
        }
    };
    let (camera, backend) = tokio::join!(camera, backend.shutdown());
    camera?;
    backend
}

async fn wait_for_camera(supervisor: &mut Option<SupervisorControl>) -> Result<(), String> {
    match supervisor {
        Some(supervisor) => supervisor.wait().await,
        None => std::future::pending().await,
    }
}

async fn join_workers(
    mut workers: JoinSet<WorkerOutcome>,
    first: Option<WorkerJoinResult>,
) -> Result<(), String> {
    let mut failures = Vec::new();
    if let Some(result) = first {
        collect_worker_result(result, &mut failures);
    }
    while let Some(result) = workers.join_next().await {
        collect_worker_result(result, &mut failures);
    }
    if failures.is_empty() {
        Ok(())
    } else {
        Err(format!("background worker failed: {}", failures.join(", ")))
    }
}

fn collect_worker_result(result: WorkerJoinResult, failures: &mut Vec<String>) {
    match result {
        Ok((_, Ok(()))) => {}
        Ok((name, Err(error))) => failures.push(format!("{name}: {error}")),
        Err(error) => failures.push(error.to_string()),
    }
}

#[cfg(unix)]
struct SignalMonitor {
    interrupt: tokio::signal::unix::Signal,
    terminate: tokio::signal::unix::Signal,
}

#[cfg(unix)]
impl SignalMonitor {
    fn install() -> io::Result<Self> {
        Ok(Self {
            interrupt: tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt())?,
            terminate: tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?,
        })
    }

    fn spawn(mut self, shutdown: CancellationToken) -> JoinHandle<io::Result<()>> {
        tokio::spawn(async move {
            tokio::select! {
                biased;
                _ = shutdown.cancelled() => return Ok(()),
                _ = self.interrupt.recv() => {}
                _ = self.terminate.recv() => {}
            }
            tracing::info!("shutdown signal received");
            shutdown.cancel();
            Ok(())
        })
    }
}

#[cfg(not(unix))]
struct SignalMonitor;

#[cfg(not(unix))]
impl SignalMonitor {
    fn install() -> io::Result<Self> {
        Ok(Self)
    }

    fn spawn(self, shutdown: CancellationToken) -> JoinHandle<io::Result<()>> {
        tokio::spawn(async move {
            tokio::select! {
                biased;
                _ = shutdown.cancelled() => return Ok(()),
                result = tokio::signal::ctrl_c() => result?,
            }
            tracing::info!("shutdown signal received");
            shutdown.cancel();
            Ok(())
        })
    }
}

fn prepare_recording_storage(storage: &StorageCoordinator) {
    match storage.reconcile_recording_artifacts() {
        Ok(transactions)
            if !transactions.removed_uncommitted.is_empty()
                || !transactions.finalized.is_empty() =>
        {
            tracing::info!(
                removed_uncommitted = transactions.removed_uncommitted.len(),
                finalized = ?transactions.finalized,
                "reconciled recording artifacts before readiness"
            );
        }
        Ok(_) => {}
        Err(error) => tracing::error!(
            %error,
            "recording transaction reconciliation failed"
        ),
    }
    match storage.scrub_unrecoverable_segments() {
        Ok(report) if !report.deleted_ids.is_empty() => {
            tracing::info!(
                deleted = ?report.deleted_ids,
                repaired = report.repaired_paths.len(),
                "scrubbed unrecoverable zero-byte segments left by power loss"
            );
        }
        Ok(report) if !report.repaired_paths.is_empty() => {
            tracing::info!(
                repaired = report.repaired_paths.len(),
                "removed zero-byte duplicate paths; preserved recoverable footage"
            );
        }
        Ok(_) => {}
        Err(error) => tracing::error!(
            %error,
            "recording startup scrub failed"
        ),
    }
}

fn storage_coordinator(rec_dir: PathBuf, required_mountpoint: Option<&Path>) -> StorageCoordinator {
    let storage = StorageCoordinator::new(rec_dir);
    if let Some(mountpoint) = required_mountpoint {
        storage.with_required_mountpoint(mountpoint.to_path_buf())
    } else {
        storage
    }
}

fn mock_segment_interval() -> Duration {
    let seconds = env::var("DANCAM_MOCK_SEGMENT_SECS")
        .ok()
        .and_then(|raw| raw.parse::<u64>().ok())
        .filter(|seconds| *seconds > 0)
        .unwrap_or(5);

    Duration::from_secs(seconds)
}
