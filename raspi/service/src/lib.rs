use std::{
    collections::HashSet,
    net::{SocketAddr, TcpListener},
    path::PathBuf,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
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
use socket2::{Domain, Protocol, Socket, Type};
use tracing::Instrument;

use crate::{backend::Backend, storage::StorageCoordinator};

pub mod backend;
pub mod camera;
mod clips;
mod clock;
pub mod event_hub;
pub mod events;
mod health;
mod jpeg;
mod mutation;
pub mod preview;
pub mod recorder;
mod recording;
pub mod storage;
mod sysfacts;
pub mod time_sync;
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
    pub storage: Arc<StorageCoordinator>,
    pub(crate) time_store: Arc<time_sync::TimeStore>,
    pub(crate) clip_durations: Arc<DurationCache>,
    request_seq: Arc<AtomicU64>,
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
        let time_store = backend.time_store();
        time_store.set_boot_id(boot_id.as_ref());
        if time_store.current_boot_synced() {
            backend.mark_time_synced();
        }
        let clip_durations = backend.clip_durations();

        Self {
            boot_id,
            started,
            backend: Arc::new(backend),
            storage: Arc::new(StorageCoordinator::new(PathBuf::from(DEFAULT_REC_DIR))),
            time_store,
            clip_durations,
            request_seq: Arc::new(AtomicU64::new(1)),
            host_policy: Arc::new(HostPolicy::default()),
        }
    }

    pub fn with_storage(mut self, storage: Arc<StorageCoordinator>) -> Self {
        self.storage = storage;
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
        .route(
            "/v1/clips/{id}",
            get(clips::serve_clip).delete(clips::delete_clip),
        )
        .route("/v1/preview/live.mjpeg", get(preview::live_mjpeg))
        .route("/v1/recording/start", post(recording::start))
        .route("/v1/recording/stop", post(recording::stop))
        .route("/v1/time", post(time_sync::sync_time))
        .layer(middleware::from_fn_with_state(
            state.clone(),
            host_allowlist,
        ))
        .layer(middleware::from_fn_with_state(state.clone(), proto_headers))
        .layer(middleware::from_fn_with_state(state.clone(), request_trace))
        .with_state(state)
}

/// Build a listening TCP socket for `bind` (an `IP:port` literal).
///
/// IPv6 sockets are made dual-stack so an IPv6 wildcard also accepts IPv4-mapped
/// clients. The returned listener is blocking; callers that hand it to Tokio must
/// set nonblocking mode first.
pub fn dual_stack_listener(bind: &str) -> std::io::Result<TcpListener> {
    let addr: SocketAddr = bind.parse().map_err(|e| {
        std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            format!("invalid DANCAM_BIND {bind:?}: {e}"),
        )
    })?;

    let socket = Socket::new(Domain::for_address(addr), Type::STREAM, Some(Protocol::TCP))?;
    if addr.is_ipv6() {
        // macOS defaults IPv6 listeners to v6-only; the Pi advertises both families.
        socket.set_only_v6(false)?;
    }
    socket.set_reuse_address(true)?;
    socket.bind(&addr.into())?;
    socket.listen(1024)?;

    Ok(socket.into())
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

async fn request_trace(
    State(state): State<AppState>,
    request: Request<Body>,
    next: Next,
) -> Response {
    let request_id = inbound_request_id(&request).unwrap_or_else(|| {
        state
            .request_seq
            .fetch_add(1, Ordering::Relaxed)
            .to_string()
    });
    let method = request.method().clone();
    let path = request.uri().path().to_owned();
    let started = Instant::now();
    let span = tracing::info_span!("request", %request_id, %method, %path);

    let mut response = async move {
        tracing::info!("received");
        let response = next.run(request).await;
        tracing::info!(
            status = response.status().as_u16(),
            latency_ms = started.elapsed().as_millis() as u64,
            "response",
        );
        response
    }
    .instrument(span)
    .await;

    response.headers_mut().insert(
        HeaderName::from_static("x-request-id"),
        HeaderValue::from_str(&request_id).expect("request_id must be a valid header"),
    );

    response
}

fn inbound_request_id(request: &Request<Body>) -> Option<String> {
    let request_id = request
        .headers()
        .get("x-request-id")
        .and_then(|value| value.to_str().ok())?;

    is_safe_request_id(request_id).then(|| request_id.to_string())
}

fn is_safe_request_id(request_id: &str) -> bool {
    !request_id.is_empty()
        && request_id.len() <= 128
        && request_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
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
    use std::{
        io::ErrorKind,
        net::{TcpListener, TcpStream},
        thread,
        time::{Duration, Instant},
    };

    use super::{dual_stack_listener, parse_boot_id, parse_host_header, HostPolicy};

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
    fn dual_stack_listener_accepts_ipv4_client() {
        let listener = dual_stack_listener("[::]:0").expect("bind [::]:0");

        assert_accepts_ipv4_client(listener);
    }

    #[test]
    fn ipv4_listener_accepts_ipv4_client() {
        let listener = dual_stack_listener("127.0.0.1:0").expect("bind 127.0.0.1:0");

        assert_accepts_ipv4_client(listener);
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

    fn assert_accepts_ipv4_client(listener: TcpListener) {
        let port = listener.local_addr().expect("listener local addr").port();
        listener.set_nonblocking(true).expect("set nonblocking");
        let accept_thread = thread::spawn(move || accept_before_deadline(listener));

        let client = TcpStream::connect(("127.0.0.1", port)).expect("connect IPv4 client");
        drop(client);

        accept_thread
            .join()
            .expect("accept thread panicked")
            .expect("accept IPv4 client");
    }

    fn accept_before_deadline(listener: TcpListener) -> std::io::Result<()> {
        let deadline = Instant::now() + Duration::from_secs(2);

        loop {
            match listener.accept() {
                Ok((_stream, _addr)) => return Ok(()),
                Err(error) if error.kind() == ErrorKind::WouldBlock => {
                    if Instant::now() >= deadline {
                        return Err(std::io::Error::new(
                            ErrorKind::TimedOut,
                            "listener did not accept IPv4 client",
                        ));
                    }
                    thread::sleep(Duration::from_millis(10));
                }
                Err(error) => return Err(error),
            }
        }
    }
}
