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
    let (state, supervisor): (AppState, Option<SupervisorControl>) =
        match env::var("DANCAM_BACKEND").as_deref() {
            Ok("camera") => {
                let config = CameraConfig::from_env();
                let storage = Arc::new(storage_coordinator(
                    config.rec_dir().to_path_buf(),
                    required_rec_mountpoint.as_deref(),
                ));
                let (backend, supervisor) = CameraProcess::spawn(config, storage.clone());
                (
                    AppState::new(boot_id, backend).with_storage(storage),
                    Some(supervisor),
                )
            }
            Ok("mock") | Err(_) => {
                let rec_dir = env::var_os("DANCAM_REC_DIR")
                    .map_or_else(|| PathBuf::from(dancam::DEFAULT_REC_DIR), PathBuf::from);
                let storage = Arc::new(storage_coordinator(
                    rec_dir,
                    required_rec_mountpoint.as_deref(),
                ));
                let roll_interval = mock_segment_interval();
                (
                    AppState::new(
                        boot_id,
                        MockBackend::recording_to(storage.clone(), roll_interval),
                    )
                    .with_storage(storage),
                    None,
                )
            }
            Ok(other) => {
                tracing::error!(backend = other, "unknown DANCAM_BACKEND");
                std::process::exit(1);
            }
        };
    let state = state.with_service_port(local_addr.port());

    dancam::events::spawn_heartbeat(state.backend.clone(), Duration::from_secs(2));
    dancam::events::spawn_telemetry(
        state.backend.clone(),
        state.storage.rec_dir(),
        Duration::from_secs(2),
    );

    tracing::info!(%local_addr, "listening");

    axum::serve(listener, app(state))
        .with_graceful_shutdown(shutdown_signal())
        .await?;

    if let Some(supervisor) = supervisor {
        supervisor.shutdown().await;
    }

    Ok(())
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
