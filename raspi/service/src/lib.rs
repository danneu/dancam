use std::{sync::Arc, time::Instant};

use axum::{
    body::Body,
    extract::State,
    http::{HeaderName, HeaderValue, Request},
    middleware::{self, Next},
    response::Response,
    routing::get,
    Router,
};

use crate::backend::Backend;

pub mod backend;
mod health;
mod jpeg;
pub mod preview;

#[derive(Clone)]
pub struct AppState {
    pub boot_id: Arc<str>,
    pub started: Instant,
    pub backend: Arc<dyn Backend>,
}

impl AppState {
    pub fn new<B>(boot_id: String, backend: B) -> Self
    where
        B: Backend,
    {
        Self {
            boot_id: Arc::from(boot_id),
            started: Instant::now(),
            backend: Arc::new(backend),
        }
    }
}

pub fn app(state: AppState) -> Router {
    Router::new()
        .route("/v1/health", get(health::health))
        .route("/v1/preview/live.mjpeg", get(preview::live_mjpeg))
        .layer(middleware::from_fn_with_state(state.clone(), proto_headers))
        .with_state(state)
}

pub fn resolve_boot_id() -> String {
    #[cfg(target_os = "linux")]
    {
        if let Ok(raw) = std::fs::read_to_string("/proc/sys/kernel/random/boot_id") {
            let boot_id = parse_boot_id(&raw);
            if !boot_id.is_empty() {
                return boot_id;
            }
        }
    }

    uuid::Uuid::new_v4().to_string()
}

pub fn parse_boot_id(raw: &str) -> String {
    raw.trim().to_string()
}

async fn proto_headers(
    State(state): State<AppState>,
    request: Request<Body>,
    next: Next,
) -> Response {
    let mut response = next.run(request).await;

    response.headers_mut().insert(
        HeaderName::from_static("x-dancam-proto"),
        HeaderValue::from_static("1"),
    );
    response.headers_mut().insert(
        HeaderName::from_static("x-dancam-boot-id"),
        HeaderValue::from_str(state.boot_id.as_ref()).expect("boot_id must be a valid header"),
    );

    response
}

#[cfg(test)]
mod tests {
    use super::parse_boot_id;

    #[test]
    fn parse_boot_id_trims_procfs_newline() {
        assert_eq!(
            parse_boot_id("3f1c0e7a-8f3b-4e15-b196-20e0416af749\n"),
            "3f1c0e7a-8f3b-4e15-b196-20e0416af749"
        );
        assert_eq!(
            parse_boot_id("3f1c0e7a-8f3b-4e15-b196-20e0416af749"),
            "3f1c0e7a-8f3b-4e15-b196-20e0416af749"
        );
    }
}
