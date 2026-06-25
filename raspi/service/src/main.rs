use std::env;

use dancam::{
    app,
    backend::{MockBackend, RpicamBackend},
    resolve_boot_id, AppState,
};
use tokio::net::TcpListener;

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    tracing_subscriber::fmt::init();

    let bind = env::var("DANCAM_BIND").unwrap_or_else(|_| "127.0.0.1:8080".to_string());
    let listener = TcpListener::bind(&bind).await?;
    let local_addr = listener.local_addr()?;
    let boot_id = resolve_boot_id();
    let state = match env::var("DANCAM_BACKEND").as_deref() {
        Ok("camera") => AppState::new(boot_id, RpicamBackend),
        Ok("mock") | Err(_) => AppState::new(boot_id, MockBackend),
        Ok(other) => {
            tracing::error!(backend = other, "unknown DANCAM_BACKEND");
            std::process::exit(1);
        }
    };

    tracing::info!(%local_addr, "listening");

    axum::serve(listener, app(state))
        .with_graceful_shutdown(shutdown_signal())
        .await?;

    Ok(())
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
