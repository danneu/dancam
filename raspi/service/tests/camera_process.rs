use std::{
    fs,
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

use axum::{
    body::Body,
    http::{Request, StatusCode},
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
    assert_eq!(backend.snapshot().temp_c.sensor, None);

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
            if backend.snapshot().temp_c.sensor == Some(expected) {
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

    assert_eq!(backend.start_recording().await, Err(BackendError::Storage));
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
    // Witness at u32::MAX - 1 so reserve_start_segment returns u32::MAX (the last legal
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
