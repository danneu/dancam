use std::{
    fs,
    path::{Path, PathBuf},
    time::Duration,
};

use bytes::Bytes;
use serde_json::Value;
use tokio::{
    io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader, Lines},
    process::{ChildStderr, Command},
    sync::mpsc,
};
use tokio_stream::StreamExt;
use uuid::Uuid;

use dancam::{
    backend::Backend,
    camera::{CameraConfig, CameraProcess},
    status::CameraState,
};

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
async fn python_fake_contract_creates_rec_dir_and_continues_segments() {
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
    assert!(rec_dir.is_dir());

    let frame = tokio::time::timeout(Duration::from_secs(2), frames.recv())
        .await
        .unwrap()
        .unwrap();
    assert!(frame.starts_with(&[0xff, 0xd8]));
    assert!(frame.ends_with(&[0xff, 0xd9]));

    send_command(&mut stdin, "start_recording").await;
    wait_for_event(&mut lines, "recording_started").await;
    send_command(&mut stdin, "start_recording").await;
    wait_for_event(&mut lines, "recording_started").await;
    send_command(&mut stdin, "stop_recording").await;
    wait_for_event(&mut lines, "recording_stopped").await;

    send_command(&mut stdin, "start_recording").await;
    wait_for_event(&mut lines, "recording_started").await;
    send_command(&mut stdin, "stop_recording").await;
    wait_for_event(&mut lines, "recording_stopped").await;
    send_command(&mut stdin, "shutdown").await;

    let status = tokio::time::timeout(Duration::from_secs(2), child.wait())
        .await
        .unwrap()
        .unwrap();
    assert!(status.success());

    let mut segments = fs::read_dir(&rec_dir)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .collect::<Vec<_>>();
    segments.sort();
    assert_eq!(segments, ["seg_00000.ts", "seg_00001.ts"]);

    let _ = fs::remove_dir_all(rec_dir);
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
    let (backend, control) = CameraProcess::spawn(config);

    wait_for_camera_state(&backend, CameraState::Running).await;

    backend.start_recording().await.unwrap();
    backend.stop_recording().await.unwrap();

    let _preview_subscriber = backend.preview_frames();
    backend.start_recording().await.unwrap();
    backend.stop_recording().await.unwrap();

    let mut segments = fs::read_dir(&rec_dir)
        .unwrap()
        .map(|entry| entry.unwrap().file_name().into_string().unwrap())
        .collect::<Vec<_>>();
    segments.sort();
    assert_eq!(segments, ["seg_00000.ts", "seg_00001.ts"]);

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
    let (backend, control) = CameraProcess::spawn(config);

    wait_for_camera_state(&backend, CameraState::Running).await;
    wait_for_camera_state(&backend, CameraState::Restarting).await;

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
    let (backend, control) = CameraProcess::spawn(config);

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
    let (backend, control) = CameraProcess::spawn(config);

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
            if backend.status().camera_state == expected {
                return;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .unwrap_or_else(|_| panic!("timed out waiting for camera state {expected:?}"));
}
