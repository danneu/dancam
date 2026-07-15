use std::{
    env,
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

use dancam::{
    app,
    backend::MockBackend,
    camera::{CameraConfig, CameraProcess, SupervisorControl},
    dual_stack_listener, resolve_boot_id,
    storage::StorageCoordinator,
    AppState,
};
use tokio::net::TcpListener;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt::init();

    let bind = env::var("DANCAM_BIND").unwrap_or_else(|_| "127.0.0.1:8080".to_string());
    let std_listener = dual_stack_listener(&bind)?;
    std_listener.set_nonblocking(true)?;
    let listener = TcpListener::from_std(std_listener)?;
    let local_addr = listener.local_addr()?;
    let boot_id = resolve_boot_id();
    let required_rec_mountpoint = env::var_os("DANCAM_REQUIRE_REC_MOUNT").map(PathBuf::from);
    log_required_mountpoint(required_rec_mountpoint.as_deref());
    let (state, supervisor, is_mock): (AppState, Option<SupervisorControl>, bool) =
        match env::var("DANCAM_BACKEND").as_deref() {
            Ok("camera") => {
                let config = CameraConfig::from_env();
                let storage = Arc::new(storage_coordinator(
                    config.rec_dir().to_path_buf(),
                    required_rec_mountpoint.as_deref(),
                ));
                scrub_unrecoverable_leftovers(storage.as_ref());
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
                scrub_unrecoverable_leftovers(storage.as_ref());
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
            Ok(other) => {
                tracing::error!(backend = other, "unknown DANCAM_BACKEND");
                std::process::exit(1);
            }
        };
    let state = state.with_service_port(local_addr.port());

    dancam::events::spawn_heartbeat(state.backend.clone(), Duration::from_secs(2));
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
    dancam::events::spawn_telemetry(
        state.backend.clone(),
        state.filesystem.clone(),
        Duration::from_secs(2),
    );
    if gc.floor_bytes > 0 {
        tracing::info!(floor_bytes = gc.floor_bytes, "segment gc enabled");
        dancam::gc::spawn_gc(state.storage.clone(), state.backend.clone(), gc);
    }

    tracing::info!(%local_addr, "listening");

    axum::serve(listener, app(state))
        .with_graceful_shutdown(shutdown_signal())
        .await?;

    if let Some(supervisor) = supervisor {
        supervisor.shutdown().await;
    }

    Ok(())
}

fn scrub_unrecoverable_leftovers(storage: &StorageCoordinator) {
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
        Err(error) => {
            tracing::error!(
                %error,
                "boot scrub of unrecoverable segments failed; continuing startup"
            );
        }
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

fn log_required_mountpoint(required_mountpoint: Option<&Path>) {
    let Some(mountpoint) = required_mountpoint else {
        return;
    };

    if let Err(error) = dancam::storage::ensure_required_mountpoint(mountpoint) {
        tracing::error!(%error, mountpoint = %mountpoint.display(), "required recording mountpoint is unhealthy");
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

async fn shutdown_signal() {
    let ctrl_c = async {
        tokio::signal::ctrl_c()
            .await
            .expect("failed to install Ctrl+C handler");
    };

    #[cfg(unix)]
    {
        let terminate = async {
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                .expect("failed to install SIGTERM handler")
                .recv()
                .await;
        };

        tokio::select! {
            _ = ctrl_c => {}
            _ = terminate => {}
        }
    }

    #[cfg(not(unix))]
    {
        ctrl_c.await;
    }

    tracing::info!("shutdown signal received");
}
