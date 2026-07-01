use std::{
    collections::HashSet,
    path::{Path, PathBuf},
    sync::Arc,
    time::Instant,
};

use axum::{
    body::Body,
    extract::State,
    http::{header::HOST, HeaderName, HeaderValue, Request, StatusCode},
    middleware::{self, Next},
    response::{IntoResponse, Response},
    routing::{get, post},
    Router,
};

use crate::backend::Backend;

pub mod backend;
pub mod camera;
mod clips;
pub mod event_hub;
pub mod events;
mod health;
mod jpeg;
pub mod preview;
pub mod recorder;
mod recording;
mod sysfacts;
mod ts_duration;
pub mod world;

pub use ts_duration::DurationCache;

// Fallback only. The deployed unit sets DANCAM_REC_DIR to the same path via
// StateDirectory=dancam.
pub const DEFAULT_REC_DIR: &str = "/var/lib/dancam/rec";

#[derive(Clone)]
pub struct AppState {
    pub boot_id: Arc<str>,
    pub started: Instant,
    pub backend: Arc<dyn Backend>,
    pub rec_dir: Arc<Path>,
    pub(crate) clip_durations: Arc<DurationCache>,
    host_policy: Arc<HostPolicy>,
}

impl AppState {
    pub fn new<B>(boot_id: String, backend: B) -> Self
    where
        B: Backend,
    {
        let started = Instant::now();
        let boot_id: Arc<str> = Arc::from(boot_id);
        backend.set_context(boot_id.clone(), started);
        let clip_durations = backend.clip_durations();

        Self {
            boot_id,
            started,
            backend: Arc::new(backend),
            rec_dir: Arc::from(PathBuf::from(DEFAULT_REC_DIR).into_boxed_path()),
            clip_durations,
            host_policy: Arc::new(HostPolicy::default()),
        }
    }

    pub fn with_rec_dir(mut self, rec_dir: PathBuf) -> Self {
        self.rec_dir = Arc::from(rec_dir.into_boxed_path());
        self
    }

    pub fn with_service_port(mut self, port: u16) -> Self {
        self.host_policy = Arc::new(HostPolicy::new(port));
        self
    }
}

pub fn app(state: AppState) -> Router {
    Router::new()
        .route("/v1/health", get(health::health))
        .route("/v1/status", get(events::status))
        .route("/v1/events", get(events::events))
        .route("/v1/clips", get(clips::list_clips))
        .route("/v1/clips/{id}", get(clips::serve_clip))
        .route("/v1/preview/live.mjpeg", get(preview::live_mjpeg))
        .route("/v1/recording/start", post(recording::start))
        .route("/v1/recording/stop", post(recording::stop))
        .layer(middleware::from_fn_with_state(
            state.clone(),
            host_allowlist,
        ))
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

#[derive(Debug)]
struct HostPolicy {
    allowed_hosts: HashSet<&'static str>,
    service_port: u16,
}

impl Default for HostPolicy {
    fn default() -> Self {
        Self::new(8080)
    }
}

async fn host_allowlist(
    State(state): State<AppState>,
    request: Request<Body>,
    next: Next,
) -> Response {
    let Some(host) = request
        .headers()
        .get(HOST)
        .and_then(|value| value.to_str().ok())
    else {
        return StatusCode::MISDIRECTED_REQUEST.into_response();
    };

    if !state.host_policy.allows(host) {
        return StatusCode::MISDIRECTED_REQUEST.into_response();
    }

    next.run(request).await
}

impl HostPolicy {
    fn new(service_port: u16) -> Self {
        Self {
            allowed_hosts: HashSet::from([
                "10.42.0.1",
                "dancam.local",
                "localhost",
                "127.0.0.1",
                "::1",
            ]),
            service_port,
        }
    }

    fn allows(&self, raw_host: &str) -> bool {
        let Some((host, port)) = parse_host_header(raw_host) else {
            return false;
        };

        self.allowed_hosts.contains(host.as_str())
            && port.map(|port| port == self.service_port).unwrap_or(true)
    }
}

fn parse_host_header(raw_host: &str) -> Option<(String, Option<u16>)> {
    let raw_host = raw_host.trim();
    if raw_host.is_empty() {
        return None;
    }

    if let Some(rest) = raw_host.strip_prefix('[') {
        let (host, rest) = rest.split_once(']')?;
        let port = match rest.strip_prefix(':') {
            Some(raw_port) => Some(raw_port.parse().ok()?),
            None if rest.is_empty() => None,
            _ => return None,
        };
        return Some((host.to_ascii_lowercase(), port));
    }

    if raw_host.matches(':').count() == 1 {
        let (host, raw_port) = raw_host.rsplit_once(':')?;
        let port = raw_port.parse().ok()?;
        return Some((host.to_ascii_lowercase(), Some(port)));
    }

    Some((raw_host.to_ascii_lowercase(), None))
}

#[cfg(test)]
mod tests {
    use super::{parse_boot_id, parse_host_header, HostPolicy};

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

    #[test]
    fn host_policy_accepts_allowlisted_hosts_and_matching_ports() {
        let policy = HostPolicy::default();

        assert!(policy.allows("10.42.0.1:8080"));
        assert!(policy.allows("10.42.0.1"));
        assert!(policy.allows("dancam.local:8080"));
        assert!(policy.allows("localhost:8080"));
        assert!(policy.allows("[::1]:8080"));
    }

    #[test]
    fn host_policy_rejects_disallowed_hosts_and_wrong_ports() {
        let policy = HostPolicy::default();

        assert!(!policy.allows("evil.example:8080"));
        assert!(!policy.allows("10.42.0.1:9999"));
        assert!(!policy.allows(""));
    }

    #[test]
    fn host_policy_uses_configured_service_port() {
        let policy = HostPolicy::new(9000);

        assert!(policy.allows("127.0.0.1:9000"));
        assert!(policy.allows("dancam.local:9000"));
        assert!(!policy.allows("127.0.0.1:8080"));
    }

    #[test]
    fn host_header_parser_normalizes_ipv6_brackets() {
        assert_eq!(
            parse_host_header("[::1]:8080"),
            Some(("::1".to_string(), Some(8080)))
        );
        assert_eq!(
            parse_host_header("DANCAM.local"),
            Some(("dancam.local".to_string(), None))
        );
    }
}
