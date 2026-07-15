use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
    sync::{Arc, Mutex as StdMutex},
    time::Duration,
};

use axum::{
    body::Body,
    http::{header, Request, StatusCode},
};
use bytes::Bytes;
use http_body_util::BodyExt;
use serde_json::Value;
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader, Lines},
    process::{ChildStderr, Command},
    sync::mpsc,
};
use tokio_stream::StreamExt;
use tower::ServiceExt;
use tracing::{field::Visit, Subscriber};
use tracing_subscriber::{
    layer::{Context, SubscriberExt},
    registry::LookupSpan,
    Layer,
};
use uuid::Uuid;

use dancam::{
    backend::{Backend, BackendError},
    camera::{CameraConfig, CameraProcess},
    event_hub::EventConnection,
    events::Event,
    recorder::{parse_segment_filename, RecorderPhase},
    storage::StorageCoordinator,
    world::CameraState,
    AppState,
};

const BOOT_ID: &str = "3f1c0e7a-8f3b-4e15-b196-20e0416af749";

#[derive(Clone, Debug, Default)]
struct CapturedFields(BTreeMap<String, String>);

impl Visit for CapturedFields {
    fn record_debug(&mut self, field: &tracing::field::Field, value: &dyn std::fmt::Debug) {
        self.0
            .insert(field.name().to_string(), format!("{value:?}"));
    }

    fn record_str(&mut self, field: &tracing::field::Field, value: &str) {
        self.0.insert(field.name().to_string(), value.to_string());
    }
}

#[derive(Clone, Debug)]
struct CapturedTraceEvent {
    name: String,
    level: tracing::Level,
    fields: CapturedFields,
    spans: Vec<(String, CapturedFields)>,
}

#[derive(Clone)]
struct CaptureLayer(Arc<StdMutex<Vec<CapturedTraceEvent>>>);

impl<S> Layer<S> for CaptureLayer
where
    S: Subscriber + for<'lookup> LookupSpan<'lookup>,
{
    fn on_new_span(
        &self,
        attributes: &tracing::span::Attributes<'_>,
        id: &tracing::span::Id,
        context: Context<'_, S>,
    ) {
        let mut fields = CapturedFields::default();
        attributes.record(&mut fields);
        if let Some(span) = context.span(id) {
            span.extensions_mut().insert(fields);
        }
    }

    fn on_event(&self, event: &tracing::Event<'_>, context: Context<'_, S>) {
        let mut fields = CapturedFields::default();
        event.record(&mut fields);
        let spans = context
            .event_scope(event)
            .map(|scope| {
                scope
                    .from_root()
                    .map(|span| {
                        (
                            span.name().to_string(),
                            span.extensions()
                                .get::<CapturedFields>()
                                .cloned()
                                .unwrap_or_default(),
                        )
                    })
                    .collect()
            })
            .unwrap_or_default();
        self.0.lock().unwrap().push(CapturedTraceEvent {
            name: event.metadata().name().to_string(),
            level: *event.metadata().level(),
            fields,
            spans,
        });
    }
}

#[derive(Default)]
struct TestJpegSplitter {
    buffer: Vec<u8>,
}

impl TestJpegSplitter {
    fn push(&mut self, bytes: &[u8]) -> Vec<Vec<u8>> {
        self.buffer.extend_from_slice(bytes);

        let mut frames = Vec::new();
        loop {
            let Some(soi) = find_marker(&self.buffer, [0xff, 0xd8], 0) else {
                self.buffer.clear();
                return frames;
            };
            if soi > 0 {
                self.buffer.drain(..soi);
            }

            let Some(eoi) = find_marker(&self.buffer, [0xff, 0xd9], 2) else {
                return frames;
            };
            frames.push(self.buffer.drain(..eoi + 2).collect());
        }
    }
}

fn find_marker(bytes: &[u8], marker: [u8; 2], start: usize) -> Option<usize> {
    bytes
        .windows(2)
        .enumerate()
        .skip(start)
        .find_map(|(index, pair)| (pair == marker).then_some(index))
}

fn camera_script() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../camera/camera.py")
}

fn inline_camera_config(script: &str, rec_dir: &Path, args: &[&Path]) -> CameraConfig {
    let mut command_args = vec!["-u".to_string(), "-c".to_string(), script.to_string()];
    command_args.extend(args.iter().map(|path| path.to_string_lossy().to_string()));
    command_args.push("--rec-dir".to_string());
    command_args.push(rec_dir.to_string_lossy().to_string());
    CameraConfig::new("python3", command_args)
}

async fn process_exists(pid: u32) -> bool {
    Command::new("kill")
        .arg("-0")
        .arg(pid.to_string())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .await
        .is_ok_and(|status| status.success())
}

async fn python3_available() -> bool {
    Command::new("python3")
        .arg("--version")
        .output()
        .await
        .is_ok()
}

fn temp_rec_dir(name: &str) -> PathBuf {
    std::env::temp_dir().join(format!("dancam-{name}-{}", Uuid::new_v4()))
}

async fn wait_for_event(lines: &mut Lines<BufReader<ChildStderr>>, event: &str) -> Value {
    tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            let line = lines
                .next_line()
                .await
                .expect("stderr read should succeed")
                .expect("camera process should keep stderr open");
            if let Ok(value) = serde_json::from_str::<Value>(&line) {
                if value["event"] == event {
                    return value;
                }
            }
        }
    })
    .await
    .expect("timed out waiting for camera event")
}

fn spawn_stdout_drain(mut stdout: tokio::process::ChildStdout) -> mpsc::Receiver<Bytes> {
    let (frames_tx, frames_rx) = mpsc::channel(8);
    tokio::spawn(async move {
        let mut splitter = TestJpegSplitter::default();
        let mut buffer = [0_u8; 8192];

        while let Ok(bytes_read) = stdout.read(&mut buffer).await {
            if bytes_read == 0 {
                return;
            }
            for frame in splitter.push(&buffer[..bytes_read]) {
                if frames_tx.send(Bytes::from(frame)).await.is_err() {
                    return;
                }
            }
        }
    });
    frames_rx
}

async fn send_command(stdin: &mut tokio::process::ChildStdin, cmd: &str) {
    stdin
        .write_all(format!("{{\"cmd\":\"{cmd}\"}}\n").as_bytes())
        .await
        .unwrap();
    stdin.flush().await.unwrap();
}

async fn send_start_command(
    stdin: &mut tokio::process::ChildStdin,
    session_id: u64,
    start_segment_index: u32,
) {
    stdin
        .write_all(
            format!(
                "{{\"cmd\":\"start_recording\",\"session_id\":{session_id},\"start_segment_index\":{start_segment_index}}}\n"
            )
            .as_bytes(),
        )
        .await
        .unwrap();
    stdin.flush().await.unwrap();
}

#[tokio::test]
async fn python_fake_self_test_passes_without_picamera2() {
    if !python3_available().await {
        return;
    }

    let output = Command::new("python3")
        .arg(camera_script())
        .arg("--self-test")
        .output()
        .await
        .unwrap();

    assert!(output.status.success());
}

#[tokio::test]
async fn python_fake_contract_honors_start_segment_and_emits_lifecycle() {
    if !python3_available().await {
        return;
    }

    let rec_dir = temp_rec_dir("camera-contract");
    let mut child = Command::new("python3")
        .arg(camera_script())
        .arg("--fake")
        .arg("--rec-dir")
        .arg(&rec_dir)
        .arg("--preview-fps")
        .arg("10")
        .arg("--fake-segment-secs")
        .arg("0.2")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .unwrap();

    let mut stdin = child.stdin.take().unwrap();
    let stdout = child.stdout.take().unwrap();
    let stderr = child.stderr.take().unwrap();
    let mut frames = spawn_stdout_drain(stdout);
    let mut lines = BufReader::new(stderr).lines();

    wait_for_event(&mut lines, "ready").await;
    assert!(!rec_dir.exists());

    let frame = tokio::time::timeout(Duration::from_secs(2), frames.recv())
        .await
        .unwrap()
        .unwrap();
    assert!(frame.starts_with(&[0xff, 0xd8]));
    assert!(frame.ends_with(&[0xff, 0xd9]));

    send_start_command(&mut stdin, 99, 5).await;
    let started = wait_for_event(&mut lines, "recording_started").await;
    assert_eq!(started["session_id"], 99);
    assert!(rec_dir.is_dir());
    let opened = wait_for_event(&mut lines, "segment_opened").await;
    assert_eq!(opened["session_id"], 99);
    assert_eq!(opened["id"], 5);
    let closed = wait_for_event(&mut lines, "segment_closed").await;
    assert_eq!(closed["session_id"], 99);
    assert_eq!(closed["id"], 5);
    let rolled = wait_for_event(&mut lines, "segment_opened").await;
    assert_eq!(rolled["session_id"], 99);
    assert_eq!(rolled["id"], 6);
    send_command(&mut stdin, "stop_recording").await;
    let stopped = wait_for_event(&mut lines, "recording_stopped").await;
    assert_eq!(stopped["session_id"], 99);
    send_command(&mut stdin, "shutdown").await;

    let status = tokio::time::timeout(Duration::from_secs(2), child.wait())
        .await
        .unwrap()
        .unwrap();
    assert!(status.success());

    let segments = segment_ids(&rec_dir);
    assert!(segments.contains(&5));
    assert!(segments.contains(&6));
    assert!(!segments.contains(&4));
    // Driving the child directly bypasses the FSM derivation, so both segments carry the
    // commanded session_id 99 for the whole recording.
    assert_new_segments_are_stamped(&rec_dir, &[(5, 99), (6, 99)]);

    let _ = fs::remove_dir_all(rec_dir);
}

#[tokio::test]
async fn python_fake_reaches_ready_when_rec_dir_cannot_be_created() {
    if !python3_available().await {
        return;
    }

    let root = temp_rec_dir("camera-bad-rec-dir");
    fs::create_dir_all(&root).unwrap();
    let parent_file = root.join("not-a-dir");
    fs::write(&parent_file, b"file").unwrap();
    let rec_dir = parent_file.join("rec");
    let mut child = Command::new("python3")
        .arg(camera_script())
        .arg("--fake")
        .arg("--rec-dir")
        .arg(&rec_dir)
        .arg("--preview-fps")
        .arg("10")
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .unwrap();

    let mut stdin = child.stdin.take().unwrap();
    let stdout = child.stdout.take().unwrap();
    let stderr = child.stderr.take().unwrap();
    let mut frames = spawn_stdout_drain(stdout);
    let mut lines = BufReader::new(stderr).lines();

    wait_for_event(&mut lines, "ready").await;
    let frame = tokio::time::timeout(Duration::from_secs(2), frames.recv())
        .await
        .unwrap()
        .unwrap();
    assert!(frame.starts_with(&[0xff, 0xd8]));

    send_start_command(&mut stdin, 99, 5).await;
    let error = wait_for_event(&mut lines, "error").await;
    assert!(
        error["detail"]
            .as_str()
            .is_some_and(|detail| detail.contains("Not a directory")),
        "unexpected error event: {error}"
    );
    let status = tokio::time::timeout(Duration::from_secs(2), child.wait())
        .await
        .unwrap()
        .unwrap();
    assert!(!status.success());

    let _ = fs::remove_dir_all(root);
}

#[tokio::test]
async fn supervisor_confirms_start_stop_and_records_with_idle_preview_subscriber() {
    if !python3_available().await {
        return;
    }

    let rec_dir = temp_rec_dir("supervisor-drain");
    let config = CameraConfig::new(
        "python3",
        [
            camera_script().to_string_lossy().to_string(),
            "--fake".to_string(),
            "--rec-dir".to_string(),
            rec_dir.to_string_lossy().to_string(),
            "--preview-fps".to_string(),
            "10".to_string(),
        ],
    );
    let storage = storage_for(&rec_dir);
    let (backend, control) = CameraProcess::spawn(config, storage);

    wait_for_camera_state(&backend, CameraState::Running).await;

    backend.start_recording().await.unwrap();
    backend.stop_recording().await.unwrap();

    let _preview_subscriber = backend.preview_frames();
    backend.start_recording().await.unwrap();
    backend.stop_recording().await.unwrap();

    assert_eq!(segment_ids(&rec_dir), [0, 1]);
    // Two same-boot recordings, each writing a single segment: run 1 reserves start
    // segment 0 (session 1), run 2 reserves start segment 1 (session 2). Each run's
    // start_segment equals its lone seq here, so the stamped session is `seq + 1` and the
    // two differ -- the end-to-end proof a same-boot restart never reissues session 1.
    let expected: Vec<(u32, u64)> = [0_u32, 1]
        .into_iter()
        .map(|seq| (seq, u64::from(seq) + 1))
        .collect();
    assert_new_segments_are_stamped(&rec_dir, &expected);

    control.shutdown().await;
    let _ = fs::remove_dir_all(rec_dir);
}

#[tokio::test]
async fn concurrent_start_and_stop_intents_dispatch_once() {
    if !python3_available().await {
        return;
    }

    let rec_dir = temp_rec_dir("supervisor-duplicates");
    let config = CameraConfig::new(
        "python3",
        [
            camera_script().to_string_lossy().to_string(),
            "--fake".to_string(),
            "--rec-dir".to_string(),
            rec_dir.to_string_lossy().to_string(),
            "--preview-fps".to_string(),
            "10".to_string(),
        ],
    );
    let storage = storage_for(&rec_dir);
    let (backend, control) = CameraProcess::spawn(config, storage.clone());
    wait_for_camera_state(&backend, CameraState::Running).await;

    let first_backend = backend.clone();
    let second_backend = backend.clone();
    let (first_start, second_start) = tokio::join!(
        first_backend.start_recording(),
        second_backend.start_recording()
    );
    assert_eq!(first_start, Ok(()));
    assert_eq!(second_start, Ok(()));

    let first_backend = backend.clone();
    let second_backend = backend.clone();
    let (first_stop, second_stop) = tokio::join!(
        first_backend.stop_recording(),
        second_backend.stop_recording()
    );
    assert_eq!(first_stop, Ok(()));
    assert_eq!(second_stop, Ok(()));
    assert_eq!(segment_ids(&rec_dir), [0]);
    assert_eq!(storage.allocate_start_segment().unwrap(), 2);
    assert_eq!(backend.snapshot().recorder.phase, RecorderPhase::Idle);

    control.shutdown().await;
    let _ = fs::remove_dir_all(rec_dir);
}

#[tokio::test]
async fn recording_http_preflight_reports_each_non_running_camera_state() {
    if !python3_available().await {
        return;
    }

    const DELAYED_READY: &str = r#"
import json, sys, time
time.sleep(10)
print(json.dumps({"event":"ready"}), file=sys.stderr, flush=True)
"#;
    let rec_dir = temp_rec_dir("preflight-starting");
    let storage = storage_for(&rec_dir);
    let (backend, control) = CameraProcess::spawn(
        inline_camera_config(DELAYED_READY, &rec_dir, &[]),
        storage.clone(),
    );
    let captured = Arc::new(StdMutex::new(Vec::new()));
    let subscriber = tracing_subscriber::registry().with(CaptureLayer(captured.clone()));
    let trace_guard = tracing::subscriber::set_default(subscriber);
    assert_recording_preflight(
        &backend,
        storage,
        CameraState::Starting,
        "camera_starting",
        "camera starting",
        Some("1"),
    )
    .await;
    drop(trace_guard);
    {
        let events = captured.lock().unwrap();
        let rejection = events
            .iter()
            .find(|event| {
                event.name == "recording_command_rejected"
                    && event.fields.0.get("command").map(String::as_str) == Some("start")
            })
            .expect("missing structured start rejection event");
        assert_eq!(rejection.level, tracing::Level::WARN);
        assert_eq!(
            rejection.fields.0.get("error_code").map(String::as_str),
            Some("camera_starting")
        );
        assert_eq!(
            rejection.fields.0.get("camera_state").map(String::as_str),
            Some("Starting")
        );
        let request_span = rejection
            .spans
            .iter()
            .find(|(name, _)| name == "request")
            .expect("rejection event was outside the request span");
        assert!(request_span.1 .0.contains_key("request_id"));
        assert!(request_span
            .1
             .0
            .get("path")
            .is_some_and(|path| path.contains("/v1/recording/start")));
    }
    control.shutdown().await;
    let _ = fs::remove_dir_all(rec_dir);

    let rec_dir = temp_rec_dir("preflight-restarting");
    let storage = storage_for(&rec_dir);
    let (backend, control) = CameraProcess::spawn(
        CameraConfig::new("/definitely-not-a-camera-program", [] as [&str; 0]),
        storage.clone(),
    );
    wait_for_camera_state(&backend, CameraState::Restarting).await;
    assert_recording_preflight(
        &backend,
        storage,
        CameraState::Restarting,
        "camera_restarting",
        "camera restarting",
        Some("1"),
    )
    .await;
    control.shutdown().await;
    let _ = fs::remove_dir_all(rec_dir);

    const READY: &str = r#"
import json, sys
print(json.dumps({"event":"ready"}), file=sys.stderr, flush=True)
for line in sys.stdin:
    pass
"#;
    let rec_dir = temp_rec_dir("preflight-offline");
    let storage = storage_for(&rec_dir);
    let (backend, control) =
        CameraProcess::spawn(inline_camera_config(READY, &rec_dir, &[]), storage.clone());
    wait_for_camera_state(&backend, CameraState::Running).await;
    control.shutdown().await;
    assert_recording_preflight(
        &backend,
        storage,
        CameraState::Offline,
        "camera_offline",
        "camera offline",
        None,
    )
    .await;
    let _ = fs::remove_dir_all(rec_dir);
}

async fn assert_recording_preflight(
    backend: &dancam::camera::CameraBackend,
    storage: Arc<StorageCoordinator>,
    expected_state: CameraState,
    code: &str,
    message: &str,
    retry_after: Option<&str>,
) {
    assert_eq!(backend.snapshot().camera_state, expected_state);
    let app =
        dancam::app(AppState::new(BOOT_ID.to_string(), backend.clone()).with_storage(storage));

    for path in ["/v1/recording/start", "/v1/recording/stop"] {
        let response = app.clone().oneshot(recording_request(path)).await.unwrap();
        assert_backend_error_response(
            response,
            StatusCode::SERVICE_UNAVAILABLE,
            code,
            message,
            retry_after,
        )
        .await;
    }
}

async fn assert_backend_error_response(
    response: axum::http::Response<Body>,
    status: StatusCode,
    code: &str,
    message: &str,
    retry_after: Option<&str>,
) {
    assert_eq!(response.status(), status, "code {code}");
    assert_eq!(
        response.headers().get(header::CONTENT_TYPE).unwrap(),
        "application/json",
        "code {code}"
    );
    assert_eq!(
        response
            .headers()
            .get(header::RETRY_AFTER)
            .and_then(|value| value.to_str().ok()),
        retry_after,
        "code {code}"
    );
    let body = response.into_body().collect().await.unwrap().to_bytes();
    let body: Value = serde_json::from_slice(&body).unwrap();
    assert_eq!(body["error"], code);
    assert_eq!(body["message"], message);
}

#[tokio::test]
async fn start_timeout_reaps_child_before_error_and_retry_recovers() {
    if !python3_available().await {
        return;
    }

    const SCRIPT: &str = r#"
import json, os, sys, time
marker, pid_file = sys.argv[1], sys.argv[2]
session = None
print(json.dumps({"event":"ready"}), file=sys.stderr, flush=True)
for line in sys.stdin:
    command = json.loads(line)
    if command["cmd"] == "shutdown":
        sys.exit(0)
    if command["cmd"] == "start_recording":
        session = command["session_id"]
        if not os.path.exists(marker):
            open(marker, "w").close()
            open(pid_file, "w").write(str(os.getpid()))
            while True:
                time.sleep(1)
        print(json.dumps({"event":"recording_started","session_id":session}), file=sys.stderr, flush=True)
    if command["cmd"] == "stop_recording":
        print(json.dumps({"event":"recording_stopped","session_id":session}), file=sys.stderr, flush=True)
"#;
    let rec_dir = temp_rec_dir("start-timeout-recovery");
    let marker = rec_dir.with_extension("start-once");
    let pid_file = rec_dir.with_extension("start-pid");
    let config = inline_camera_config(SCRIPT, &rec_dir, &[&marker, &pid_file]);
    let storage = storage_for(&rec_dir);
    let (backend, control) = CameraProcess::spawn(config, storage.clone());
    wait_for_camera_state(&backend, CameraState::Running).await;

    let response =
        dancam::app(AppState::new(BOOT_ID.to_string(), backend.clone()).with_storage(storage))
            .oneshot(recording_request("/v1/recording/start"))
            .await
            .unwrap();
    assert_backend_error_response(
        response,
        StatusCode::GATEWAY_TIMEOUT,
        "camera_command_timeout",
        "camera command timed out",
        None,
    )
    .await;
    assert_eq!(backend.snapshot().recorder.phase, RecorderPhase::Error);
    let pid = fs::read_to_string(&pid_file)
        .unwrap()
        .parse::<u32>()
        .unwrap();
    assert!(
        !process_exists(pid).await,
        "timed-out camera child was still alive"
    );

    wait_for_camera_state(&backend, CameraState::Running).await;
    backend.start_recording().await.unwrap();
    assert_eq!(backend.snapshot().recorder.phase, RecorderPhase::Recording);
    backend.stop_recording().await.unwrap();

    control.shutdown().await;
    let _ = fs::remove_file(marker);
    let _ = fs::remove_file(pid_file);
    let _ = fs::remove_dir_all(rec_dir);
}

#[tokio::test]
async fn child_error_reaps_child_before_camera_offline_and_retry_recovers() {
    if !python3_available().await {
        return;
    }

    const SCRIPT: &str = r#"
import json, os, sys, time
marker, pid_file = sys.argv[1], sys.argv[2]
print(json.dumps({"event":"ready"}), file=sys.stderr, flush=True)
for line in sys.stdin:
    command = json.loads(line)
    if command["cmd"] == "shutdown":
        sys.exit(0)
    if command["cmd"] == "start_recording":
        session = command["session_id"]
        if not os.path.exists(marker):
            open(marker, "w").close()
            open(pid_file, "w").write(str(os.getpid()))
            print(json.dumps({"event":"error","detail":"injected failure"}), file=sys.stderr, flush=True)
            while True:
                time.sleep(1)
        print(json.dumps({"event":"recording_started","session_id":session}), file=sys.stderr, flush=True)
"#;
    let rec_dir = temp_rec_dir("child-error-recovery");
    let marker = rec_dir.with_extension("error-once");
    let pid_file = rec_dir.with_extension("error-pid");
    let config = inline_camera_config(SCRIPT, &rec_dir, &[&marker, &pid_file]);
    let storage = storage_for(&rec_dir);
    let (backend, control) = CameraProcess::spawn(config, storage.clone());
    wait_for_camera_state(&backend, CameraState::Running).await;

    let response =
        dancam::app(AppState::new(BOOT_ID.to_string(), backend.clone()).with_storage(storage))
            .oneshot(recording_request("/v1/recording/start"))
            .await
            .unwrap();
    assert_backend_error_response(
        response,
        StatusCode::INTERNAL_SERVER_ERROR,
        "camera_command_channel",
        "injected failure",
        None,
    )
    .await;
    assert_eq!(backend.snapshot().recorder.phase, RecorderPhase::Error);
    let pid = fs::read_to_string(&pid_file)
        .unwrap()
        .parse::<u32>()
        .unwrap();
    assert!(
        !process_exists(pid).await,
        "failed camera child was still alive"
    );

    wait_for_camera_state(&backend, CameraState::Running).await;
    backend.start_recording().await.unwrap();
    assert_eq!(backend.snapshot().recorder.phase, RecorderPhase::Recording);

    control.shutdown().await;
    let _ = fs::remove_file(marker);
    let _ = fs::remove_file(pid_file);
    let _ = fs::remove_dir_all(rec_dir);
}

#[tokio::test]
async fn first_write_failure_reconciles_and_retry_dispatches() {
    if !python3_available().await {
        return;
    }

    const SCRIPT: &str = r#"
import json, os, sys, time
marker, pid_file = sys.argv[1], sys.argv[2]
if not os.path.exists(marker):
    open(marker, "w").close()
    open(pid_file, "w").write(str(os.getpid()))
    os.close(0)
    print(json.dumps({"event":"ready"}), file=sys.stderr, flush=True)
    while True:
        time.sleep(1)
print(json.dumps({"event":"ready"}), file=sys.stderr, flush=True)
for line in sys.stdin:
    command = json.loads(line)
    if command["cmd"] == "shutdown":
        sys.exit(0)
    if command["cmd"] == "start_recording":
        print(json.dumps({"event":"recording_started","session_id":command["session_id"]}), file=sys.stderr, flush=True)
"#;
    let rec_dir = temp_rec_dir("write-failure-recovery");
    let marker = rec_dir.with_extension("write-fail-once");
    let pid_file = rec_dir.with_extension("write-fail-pid");
    let config = inline_camera_config(SCRIPT, &rec_dir, &[&marker, &pid_file]);
    let storage = storage_for(&rec_dir);
    let (backend, control) = CameraProcess::spawn(config, storage.clone());
    wait_for_camera_state(&backend, CameraState::Running).await;

    let response =
        dancam::app(AppState::new(BOOT_ID.to_string(), backend.clone()).with_storage(storage))
            .oneshot(recording_request("/v1/recording/start"))
            .await
            .unwrap();
    assert_backend_error_response(
        response,
        StatusCode::INTERNAL_SERVER_ERROR,
        "camera_command_channel",
        "camera command write failed",
        None,
    )
    .await;
    assert_eq!(backend.snapshot().recorder.phase, RecorderPhase::Error);
    let pid = fs::read_to_string(&pid_file)
        .unwrap()
        .parse::<u32>()
        .unwrap();
    assert!(
        !process_exists(pid).await,
        "write-failed camera child was still alive"
    );

    wait_for_camera_state(&backend, CameraState::Running).await;
    backend.start_recording().await.unwrap();
    assert_eq!(backend.snapshot().recorder.phase, RecorderPhase::Recording);

    control.shutdown().await;
    let _ = fs::remove_file(marker);
    let _ = fs::remove_file(pid_file);
    let _ = fs::remove_dir_all(rec_dir);
}

#[tokio::test]
async fn child_exit_during_command_reconciles_before_ack_and_retry_recovers() {
    if !python3_available().await {
        return;
    }

    const SCRIPT: &str = r#"
import json, os, sys
marker = sys.argv[1]
print(json.dumps({"event":"ready"}), file=sys.stderr, flush=True)
for line in sys.stdin:
    command = json.loads(line)
    if command["cmd"] == "shutdown":
        sys.exit(0)
    if command["cmd"] == "start_recording":
        if not os.path.exists(marker):
            open(marker, "w").close()
            sys.exit(7)
        print(json.dumps({"event":"recording_started","session_id":command["session_id"]}), file=sys.stderr, flush=True)
"#;
    let rec_dir = temp_rec_dir("exit-during-command");
    let marker = rec_dir.with_extension("exit-once");
    let config = inline_camera_config(SCRIPT, &rec_dir, &[&marker]);
    let storage = storage_for(&rec_dir);
    let (backend, control) = CameraProcess::spawn(config, storage.clone());
    wait_for_camera_state(&backend, CameraState::Running).await;

    let response =
        dancam::app(AppState::new(BOOT_ID.to_string(), backend.clone()).with_storage(storage))
            .oneshot(recording_request("/v1/recording/start"))
            .await
            .unwrap();
    assert_backend_error_response(
        response,
        StatusCode::INTERNAL_SERVER_ERROR,
        "camera_command_channel",
        "camera process exited",
        None,
    )
    .await;
    assert_eq!(backend.snapshot().recorder.phase, RecorderPhase::Error);

    wait_for_camera_state(&backend, CameraState::Running).await;
    backend.start_recording().await.unwrap();
    assert_eq!(backend.snapshot().recorder.phase, RecorderPhase::Recording);

    control.shutdown().await;
    let _ = fs::remove_file(marker);
    let _ = fs::remove_dir_all(rec_dir);
}

#[tokio::test]
async fn supervisor_shutdown_terminalizes_inflight_command() {
    if !python3_available().await {
        return;
    }

    const SCRIPT: &str = r#"
import json, sys, time
print(json.dumps({"event":"ready"}), file=sys.stderr, flush=True)
for line in sys.stdin:
    command = json.loads(line)
    if command["cmd"] == "start_recording":
        while True:
            time.sleep(1)
"#;
    let rec_dir = temp_rec_dir("shutdown-inflight");
    let config = inline_camera_config(SCRIPT, &rec_dir, &[]);
    let storage = storage_for(&rec_dir);
    let (backend, control) = CameraProcess::spawn(config, storage.clone());
    wait_for_camera_state(&backend, CameraState::Running).await;

    let app =
        dancam::app(AppState::new(BOOT_ID.to_string(), backend.clone()).with_storage(storage));
    let request = tokio::spawn(async move {
        app.oneshot(recording_request("/v1/recording/start"))
            .await
            .unwrap()
    });
    wait_for_recorder_phase(&backend, RecorderPhase::Starting).await;
    control.shutdown().await;

    assert_backend_error_response(
        request.await.unwrap(),
        StatusCode::INTERNAL_SERVER_ERROR,
        "camera_command_channel",
        "camera supervisor shut down",
        None,
    )
    .await;
    assert_eq!(backend.snapshot().recorder.phase, RecorderPhase::Error);
    assert_eq!(backend.snapshot().camera_state, CameraState::Offline);
    let _ = fs::remove_dir_all(rec_dir);
}

#[tokio::test]
async fn stop_timeout_reaps_child_and_leaves_recoverable_error() {
    if !python3_available().await {
        return;
    }

    const SCRIPT: &str = r#"
import json, os, sys, time
marker, pid_file = sys.argv[1], sys.argv[2]
session = None
print(json.dumps({"event":"ready"}), file=sys.stderr, flush=True)
for line in sys.stdin:
    command = json.loads(line)
    if command["cmd"] == "shutdown":
        sys.exit(0)
    if command["cmd"] == "start_recording":
        session = command["session_id"]
        print(json.dumps({"event":"recording_started","session_id":session}), file=sys.stderr, flush=True)
    if command["cmd"] == "stop_recording":
        if not os.path.exists(marker):
            open(marker, "w").close()
            open(pid_file, "w").write(str(os.getpid()))
            while True:
                time.sleep(1)
        print(json.dumps({"event":"recording_stopped","session_id":session}), file=sys.stderr, flush=True)
"#;
    let rec_dir = temp_rec_dir("stop-timeout-recovery");
    let marker = rec_dir.with_extension("stop-once");
    let pid_file = rec_dir.with_extension("stop-pid");
    let config = inline_camera_config(SCRIPT, &rec_dir, &[&marker, &pid_file]);
    let storage = storage_for(&rec_dir);
    let (backend, control) = CameraProcess::spawn(config, storage.clone());
    wait_for_camera_state(&backend, CameraState::Running).await;
    backend.start_recording().await.unwrap();

    let response =
        dancam::app(AppState::new(BOOT_ID.to_string(), backend.clone()).with_storage(storage))
            .oneshot(recording_request("/v1/recording/stop"))
            .await
            .unwrap();
    assert_backend_error_response(
        response,
        StatusCode::GATEWAY_TIMEOUT,
        "camera_command_timeout",
        "camera command timed out",
        None,
    )
    .await;
    assert_eq!(backend.snapshot().recorder.phase, RecorderPhase::Error);
    let pid = fs::read_to_string(&pid_file)
        .unwrap()
        .parse::<u32>()
        .unwrap();
    assert!(
        !process_exists(pid).await,
        "timed-out camera child was still alive"
    );

    wait_for_camera_state(&backend, CameraState::Running).await;
    backend.start_recording().await.unwrap();
    assert_eq!(backend.snapshot().recorder.phase, RecorderPhase::Recording);

    control.shutdown().await;
    let _ = fs::remove_file(marker);
    let _ = fs::remove_file(pid_file);
    let _ = fs::remove_dir_all(rec_dir);
}

#[tokio::test]
async fn recorder_failure_after_dispatch_has_its_own_http_error() {
    if !python3_available().await {
        return;
    }

    const SCRIPT: &str = r#"
import json, sys
session = None
print(json.dumps({"event":"ready"}), file=sys.stderr, flush=True)
for line in sys.stdin:
    command = json.loads(line)
    if command["cmd"] == "shutdown":
        sys.exit(0)
    if command["cmd"] == "start_recording":
        session = command["session_id"]
        print(json.dumps({"event":"recording_started","session_id":session}), file=sys.stderr, flush=True)
        print(json.dumps({"event":"segment_opened","session_id":session,"id":0}), file=sys.stderr, flush=True)
    if command["cmd"] == "stop_recording":
        print(json.dumps({"event":"recording_stopped","session_id":session}), file=sys.stderr, flush=True)
"#;
    let rec_dir = temp_rec_dir("recorder-failed-command");
    let config = inline_camera_config(SCRIPT, &rec_dir, &[]);
    let storage = storage_for(&rec_dir);
    let (backend, control) = CameraProcess::spawn(config, storage.clone());
    wait_for_camera_state(&backend, CameraState::Running).await;
    backend.start_recording().await.unwrap();
    wait_for_current_segment(&backend, 0).await;

    let response =
        dancam::app(AppState::new(BOOT_ID.to_string(), backend.clone()).with_storage(storage))
            .oneshot(recording_request("/v1/recording/stop"))
            .await
            .unwrap();
    assert_backend_error_response(
        response,
        StatusCode::SERVICE_UNAVAILABLE,
        "recorder_failed",
        "failed to stat final segment 0",
        None,
    )
    .await;
    assert_eq!(backend.snapshot().recorder.phase, RecorderPhase::Error);
    assert_eq!(backend.snapshot().camera_state, CameraState::Running);

    control.shutdown().await;
    let _ = fs::remove_dir_all(rec_dir);
}

#[tokio::test]
async fn supervisor_tracks_rollover_and_finalizes_last_segment_on_stop() {
    if !python3_available().await {
        return;
    }

    let rec_dir = temp_rec_dir("supervisor-lifecycle");
    fs::create_dir_all(&rec_dir).unwrap();
    fs::write(rec_dir.join("seg_00004.ts"), b"seed").unwrap();
    let config = CameraConfig::new(
        "python3",
        [
            camera_script().to_string_lossy().to_string(),
            "--fake".to_string(),
            "--rec-dir".to_string(),
            rec_dir.to_string_lossy().to_string(),
            "--preview-fps".to_string(),
            "10".to_string(),
            "--fake-segment-secs".to_string(),
            "0.6".to_string(),
        ],
    );
    let storage = storage_for(&rec_dir);
    let (backend, control) = CameraProcess::spawn(config, storage.clone());
    let app =
        dancam::app(AppState::new(BOOT_ID.to_string(), backend.clone()).with_storage(storage));

    wait_for_camera_state(&backend, CameraState::Running).await;

    // Subscribe before recording so the rollover-finalized start segment's
    // clip_finalized is captured: it is the only witness of the camera finalize path's
    // dur_ms (/v1/clips computes duration independently of the event).
    let mut connection = backend.connect();

    let start = app
        .clone()
        .oneshot(recording_request("/v1/recording/start"))
        .await
        .unwrap();
    assert_eq!(start.status(), StatusCode::OK);

    wait_for_current_segment(&backend, 5).await;
    let rolled = wait_for_newer_segment(&backend, 5).await;

    // The first clip_finalized is the rolled start segment (seg 5), emitted when seg 6
    // opens; `rolled` is seg 6, the stop segment.
    let (finalized_id, finalized_dur_ms) = wait_for_clip_finalized(&mut connection).await;
    assert_eq!(
        finalized_id, 5,
        "first clip_finalized should be the rolled start segment"
    );
    assert!(
        finalized_dur_ms.is_some_and(|dur_ms| dur_ms > 0),
        "camera clip_finalized dur_ms was {finalized_dur_ms:?}"
    );

    let stop = app
        .clone()
        .oneshot(recording_request("/v1/recording/stop"))
        .await
        .unwrap();
    assert_eq!(stop.status(), StatusCode::OK);

    let clips_response = app.clone().oneshot(get_request("/v1/clips")).await.unwrap();
    assert_eq!(clips_response.status(), StatusCode::OK);
    let clips_json = response_json(clips_response).await;
    assert!(
        clips_json["clips"]
            .as_array()
            .unwrap()
            .iter()
            .any(|clip| clip["id"].as_u64() == Some(rolled as u64)),
        "clips were {clips_json}"
    );

    // /v1/clips recomputes the same segment's duration from its file, so it agrees with
    // the finalize event exactly.
    let listed_dur_ms = clips_json["clips"]
        .as_array()
        .unwrap()
        .iter()
        .find(|clip| clip["id"].as_u64() == Some(finalized_id as u64))
        .unwrap_or_else(|| panic!("finalized clip {finalized_id} missing from {clips_json}"))
        ["dur_ms"]
        .as_u64();
    assert_eq!(
        listed_dur_ms, finalized_dur_ms,
        "camera event and /v1/clips dur_ms disagree for segment {finalized_id}"
    );

    let pulled = app
        .oneshot(get_request(&format!("/v1/clips/{rolled}")))
        .await
        .unwrap();
    assert_eq!(pulled.status(), StatusCode::OK);
    assert!(!pulled
        .into_body()
        .collect()
        .await
        .unwrap()
        .to_bytes()
        .is_empty());

    control.shutdown().await;
    let _ = fs::remove_dir_all(rec_dir);
}

#[tokio::test]
async fn supervisor_starts_after_six_digit_existing_segment_without_overwrite() {
    if !python3_available().await {
        return;
    }

    let rec_dir = temp_rec_dir("supervisor-six-digit");
    fs::create_dir_all(&rec_dir).unwrap();
    fs::write(rec_dir.join("seg_99999.ts"), b"anchor").unwrap();
    let sentinel = b"existing segment 100000";
    fs::write(rec_dir.join("seg_100000.ts"), sentinel).unwrap();
    let config = CameraConfig::new(
        "python3",
        [
            camera_script().to_string_lossy().to_string(),
            "--fake".to_string(),
            "--rec-dir".to_string(),
            rec_dir.to_string_lossy().to_string(),
            "--preview-fps".to_string(),
            "10".to_string(),
        ],
    );
    let storage = storage_for(&rec_dir);
    let (backend, control) = CameraProcess::spawn(config, storage);

    wait_for_camera_state(&backend, CameraState::Running).await;

    backend.start_recording().await.unwrap();
    wait_for_current_segment(&backend, 100001).await;
    // start_segment 100001 -> session 100002.
    assert_new_segments_are_stamped(&rec_dir, &[(100001, 100002)]);
    assert_eq!(
        fs::read(rec_dir.join("seg_100000.ts")).unwrap().as_slice(),
        sentinel
    );

    backend.stop_recording().await.unwrap();
    control.shutdown().await;
    let _ = fs::remove_dir_all(rec_dir);
}

#[tokio::test]
async fn supervisor_marks_child_restarting_after_crash() {
    if !python3_available().await {
        return;
    }

    let rec_dir = temp_rec_dir("supervisor-restart");
    let config = CameraConfig::new(
        "python3",
        [
            camera_script().to_string_lossy().to_string(),
            "--fake".to_string(),
            "--rec-dir".to_string(),
            rec_dir.to_string_lossy().to_string(),
            "--preview-fps".to_string(),
            "10".to_string(),
            "--fake-crash-after".to_string(),
            "4".to_string(),
        ],
    );
    let storage = storage_for(&rec_dir);
    let (backend, control) = CameraProcess::spawn(config, storage);

    wait_for_camera_state(&backend, CameraState::Running).await;
    backend.start_recording().await.unwrap();
    wait_for_recorder_phase(&backend, RecorderPhase::Error).await;
    let snapshot = backend.snapshot();
    assert_eq!(snapshot.recorder.current_segment, None);
    assert!(snapshot.recorder.detail.is_some());
    wait_for_camera_state(&backend, CameraState::Restarting).await;

    control.shutdown().await;
    let _ = fs::remove_dir_all(rec_dir);
}

#[tokio::test]
async fn supervisor_clears_sensor_temp_after_crash() {
    if !python3_available().await {
        return;
    }

    let rec_dir = temp_rec_dir("sensor-temp-restart");
    let config = CameraConfig::new(
        "python3",
        [
            camera_script().to_string_lossy().to_string(),
            "--fake".to_string(),
            "--rec-dir".to_string(),
            rec_dir.to_string_lossy().to_string(),
            "--preview-fps".to_string(),
            "10".to_string(),
            "--fake-crash-after".to_string(),
            "4".to_string(),
        ],
    );
    let storage = storage_for(&rec_dir);
    let (backend, control) = CameraProcess::spawn(config, storage);

    wait_for_camera_state(&backend, CameraState::Running).await;
    wait_for_sensor_temp(&backend, 40.0).await;
    wait_for_camera_state(&backend, CameraState::Restarting).await;
    let sensor = backend.snapshot().temp_c.sensor;
    assert_eq!(sensor.current, None);
    assert!(sensor.max.is_some_and(|max| max >= 40.0));

    control.shutdown().await;
    let _ = fs::remove_dir_all(rec_dir);
}

#[tokio::test]
async fn preview_subscriber_gets_cached_latest_frame_on_connect() {
    if !python3_available().await {
        return;
    }

    let rec_dir = temp_rec_dir("preview-cached-frame");
    let config = CameraConfig::new(
        "python3",
        [
            camera_script().to_string_lossy().to_string(),
            "--fake".to_string(),
            "--rec-dir".to_string(),
            rec_dir.to_string_lossy().to_string(),
            "--preview-fps".to_string(),
            "0.2".to_string(),
        ],
    );
    let storage = storage_for(&rec_dir);
    let (backend, control) = CameraProcess::spawn(config, storage);

    wait_for_camera_state(&backend, CameraState::Running).await;

    // The fake camera emits its first preview frame at startup (~coincident with
    // Running) and the next only ~5 s later (--preview-fps 0.2). Sleep ~1 s with no
    // subscriber: long enough that the immediate first frame is produced and stored,
    // far short of the ~5 s gap to the next tick.
    tokio::time::sleep(Duration::from_secs(1)).await;

    // Attach ~4 s before the next live tick. A broadcast channel never replays
    // pre-subscribe frames, so it would deliver nothing until that tick and blow the
    // deadline; the watch slot returns the cached latest frame at once. Passing proves
    // both no-subscriber production is retained (send_replace, not send) and a new
    // subscriber gets the cached latest immediately (WatchStream::new).
    let mut frames = backend.preview_frames();
    let frame = tokio::time::timeout(Duration::from_millis(400), frames.next())
        .await
        .expect("cached latest frame should arrive immediately")
        .expect("preview stream should yield a frame");
    assert!(frame.starts_with(&[0xff, 0xd8]));

    control.shutdown().await;
    let _ = fs::remove_dir_all(rec_dir);
}

#[tokio::test]
async fn preview_slot_cleared_while_child_restarting() {
    if !python3_available().await {
        return;
    }

    let rec_dir = temp_rec_dir("preview-clear-on-restart");
    let config = CameraConfig::new(
        "python3",
        [
            camera_script().to_string_lossy().to_string(),
            "--fake".to_string(),
            "--rec-dir".to_string(),
            rec_dir.to_string_lossy().to_string(),
            "--preview-fps".to_string(),
            "10".to_string(),
            "--fake-crash-after".to_string(),
            "4".to_string(),
        ],
    );
    let storage = storage_for(&rec_dir);
    let (backend, control) = CameraProcess::spawn(config, storage);

    wait_for_camera_state(&backend, CameraState::Running).await;

    // The child emits a preview frame at startup, so the slot is Some before it
    // crashes. Confirm a frame is produced (this read lands on the first child's cached
    // frame, or -- if it races the fast crash -- the next child's frame; either proves
    // the producer ran and the slot was populated).
    let mut frames = backend.preview_frames();
    let frame = tokio::time::timeout(Duration::from_secs(2), frames.next())
        .await
        .expect("preview slot should yield a produced frame")
        .expect("preview stream should yield a frame");
    assert!(frame.starts_with(&[0xff, 0xd8]));

    // After the crash the ChildOutcome::Exited arm clears the slot to None before the
    // backoff sleep, so by the time Restarting is observable the slot is empty.
    wait_for_camera_state(&backend, CameraState::Restarting).await;

    // A fresh subscriber during the restart backoff window must not be handed the stale
    // pre-crash frame: the slot is None, so it pends until the next child produces a
    // frame (>= the 250 ms backoff away), well past this 150 ms deadline. Without the
    // clear, WatchStream::new would hand it the stale frame at ~0 ms and this would fail.
    let mut probe = backend.preview_frames();
    assert!(
        tokio::time::timeout(Duration::from_millis(150), probe.next())
            .await
            .is_err(),
        "restart-window subscriber must not receive the stale pre-crash frame"
    );

    control.shutdown().await;
    let _ = fs::remove_dir_all(rec_dir);
}

async fn wait_for_camera_state(backend: &impl Backend, expected: CameraState) {
    tokio::time::timeout(Duration::from_secs(4), async {
        loop {
            if backend.snapshot().camera_state == expected {
                return;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .unwrap_or_else(|_| panic!("timed out waiting for camera state {expected:?}"));
}

async fn wait_for_sensor_temp(backend: &impl Backend, expected: f32) {
    tokio::time::timeout(Duration::from_secs(4), async {
        loop {
            if backend.snapshot().temp_c.sensor.current == Some(expected) {
                return;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .unwrap_or_else(|_| panic!("timed out waiting for sensor temperature {expected}"));
}

async fn wait_for_recorder_phase(backend: &impl Backend, expected: RecorderPhase) {
    tokio::time::timeout(Duration::from_secs(4), async {
        loop {
            if backend.snapshot().recorder.phase == expected {
                return;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .unwrap_or_else(|_| panic!("timed out waiting for recorder phase {expected:?}"));
}

async fn wait_for_current_segment(backend: &impl Backend, expected: u32) {
    tokio::time::timeout(Duration::from_secs(4), async {
        loop {
            if backend
                .snapshot()
                .recorder
                .current_segment
                .as_ref()
                .is_some_and(|segment| segment.id == expected)
            {
                return;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .unwrap_or_else(|_| panic!("timed out waiting for segment {expected}"));
}

async fn wait_for_newer_segment(backend: &impl Backend, previous: u32) -> u32 {
    tokio::time::timeout(Duration::from_secs(4), async {
        loop {
            if let Some(segment) = backend.snapshot().recorder.current_segment {
                if segment.id > previous {
                    return segment.id;
                }
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .unwrap_or_else(|_| panic!("timed out waiting for segment newer than {previous}"))
}

async fn wait_for_clip_finalized(connection: &mut EventConnection) -> (u32, Option<u64>) {
    tokio::time::timeout(Duration::from_secs(4), async {
        loop {
            match connection.rx.recv().await {
                Ok(seq_event) => {
                    if let Event::ClipFinalized(meta) = seq_event.event {
                        return (meta.id, meta.dur_ms);
                    }
                }
                Err(error) => panic!("event stream closed before clip_finalized: {error}"),
            }
        }
    })
    .await
    .expect("timed out waiting for clip_finalized")
}

fn segment_ids(rec_dir: &Path) -> Vec<u32> {
    let mut ids = fs::read_dir(rec_dir)
        .unwrap()
        .filter_map(|entry| {
            let name = entry.ok()?.file_name().into_string().ok()?;
            parse_segment_filename(&name).map(|parsed| parsed.seq)
        })
        .collect::<Vec<_>>();
    ids.sort();
    ids
}

fn storage_for(rec_dir: &Path) -> Arc<StorageCoordinator> {
    Arc::new(StorageCoordinator::new(rec_dir.to_path_buf()))
}

fn assert_new_segments_are_stamped(rec_dir: &Path, expected: &[(u32, u64)]) {
    let stamped = stamped_sessions(rec_dir);

    for (seq, session) in expected {
        assert_eq!(
            stamped.get(seq),
            Some(session),
            "segment {seq} was not stamped with session {session} in {stamped:?}"
        );
    }
}

/// Map of every stamped segment's seq to the session it was stamped with, read straight
/// from the raw directory names (the parser filters out any out-of-range overflow file).
fn stamped_sessions(rec_dir: &Path) -> std::collections::BTreeMap<u32, u64> {
    fs::read_dir(rec_dir)
        .unwrap()
        .filter_map(|entry| {
            let name = entry.ok()?.file_name().into_string().ok()?;
            let parsed = parse_segment_filename(&name)?;
            parsed.facts.map(|facts| (parsed.seq, facts.session))
        })
        .collect()
}

async fn response_json(response: axum::http::Response<Body>) -> Value {
    let body = response.into_body().collect().await.unwrap().to_bytes();
    serde_json::from_slice(&body).unwrap()
}

fn get_request(uri: &str) -> Request<Body> {
    Request::builder()
        .uri(uri)
        .header("Host", "localhost:8080")
        .body(Body::empty())
        .unwrap()
}

fn recording_request(uri: &str) -> Request<Body> {
    Request::builder()
        .method("POST")
        .uri(uri)
        .header("Host", "localhost:8080")
        .header("Content-Type", "application/json")
        .header("Idempotency-Key", Uuid::new_v4().to_string())
        .body(Body::from("{}"))
        .unwrap()
}

#[tokio::test]
async fn supervisor_start_fails_closed_when_witness_is_corrupt() {
    if !python3_available().await {
        return;
    }

    let rec_dir = temp_rec_dir("supervisor-corrupt-witness");
    fs::create_dir_all(rec_dir.join("state")).unwrap();
    fs::write(rec_dir.join("state").join("state.json"), b"not json").unwrap();
    let config = CameraConfig::new(
        "python3",
        [
            camera_script().to_string_lossy().to_string(),
            "--fake".to_string(),
            "--rec-dir".to_string(),
            rec_dir.to_string_lossy().to_string(),
            "--preview-fps".to_string(),
            "10".to_string(),
        ],
    );
    let storage = storage_for(&rec_dir);
    let (backend, control) = CameraProcess::spawn(config, storage);

    wait_for_camera_state(&backend, CameraState::Running).await;

    assert_eq!(
        backend.start_recording().await,
        Err(BackendError::RecordingStorageUnavailable)
    );
    let snapshot = backend.snapshot();
    assert_eq!(snapshot.recorder.phase, RecorderPhase::Idle);
    assert_eq!(snapshot.recorder.current_segment, None);
    assert!(segment_ids(&rec_dir).is_empty());

    control.shutdown().await;
    let _ = fs::remove_dir_all(rec_dir);
}

/// End-to-end proof of the fake driver's seq-ceiling guard: a within-recording rollover
/// at `u32::MAX` must drive the recorder to Error (child `error` -> `Input::Fail`) and
/// write neither a same-seq twin nor an out-of-range overflow file. This is the
/// fake-driver counterpart to `writer_mock_start_at_ceiling_fails_closed_on_rollover`.
#[tokio::test]
async fn supervisor_fake_driver_fails_closed_at_seq_ceiling() {
    if !python3_available().await {
        return;
    }

    let rec_dir = temp_rec_dir("supervisor-seq-ceiling");
    fs::create_dir_all(rec_dir.join("state")).unwrap();
    // Witness at u32::MAX - 1 so allocation returns u32::MAX (the last legal
    // id -- start succeeds); its next rollover would reissue u32::MAX.
    fs::write(
        rec_dir.join("state").join("state.json"),
        format!(r#"{{"high_water_seq":{}}}"#, u32::MAX - 1),
    )
    .unwrap();
    let config = CameraConfig::new(
        "python3",
        [
            camera_script().to_string_lossy().to_string(),
            "--fake".to_string(),
            "--rec-dir".to_string(),
            rec_dir.to_string_lossy().to_string(),
            "--preview-fps".to_string(),
            "10".to_string(),
            "--fake-segment-secs".to_string(),
            "0.6".to_string(),
        ],
    );
    let storage = storage_for(&rec_dir);
    let (backend, control) = CameraProcess::spawn(config, storage);

    wait_for_camera_state(&backend, CameraState::Running).await;

    backend.start_recording().await.unwrap();
    wait_for_current_segment(&backend, u32::MAX).await;

    // The ceiling rollover makes the child emit an error, which the supervisor turns into
    // Input::Fail -> RecorderPhase::Error.
    wait_for_recorder_phase(&backend, RecorderPhase::Error).await;

    // start_segment u32::MAX -> session u32::MAX + 1, stamped onto the one legal segment.
    let stamped = stamped_sessions(&rec_dir);
    assert_eq!(stamped.get(&u32::MAX), Some(&(u64::from(u32::MAX) + 1)));

    // Inspect raw names (segment_ids parses and would filter an overflow file out):
    // exactly one u32::MAX segment (no same-seq twin) and no `seg_4294967296.ts`.
    let raw_names: Vec<String> = fs::read_dir(&rec_dir)
        .unwrap()
        .filter_map(|entry| entry.ok()?.file_name().into_string().ok())
        .collect();
    let ceiling_files: Vec<&String> = raw_names
        .iter()
        .filter(|name| name.starts_with("seg_4294967295"))
        .collect();
    assert_eq!(
        ceiling_files.len(),
        1,
        "expected exactly one u32::MAX segment file, got {ceiling_files:?}"
    );
    assert!(
        !raw_names
            .iter()
            .any(|name| name.starts_with("seg_4294967296")),
        "an out-of-range overflow segment was written: {raw_names:?}"
    );

    control.shutdown().await;
    let _ = fs::remove_dir_all(rec_dir);
}
