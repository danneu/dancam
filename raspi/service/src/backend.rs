use std::{pin::Pin, process::Stdio, time::Duration};

use bytes::Bytes;
use tokio::{io::AsyncReadExt, process::Command, sync::mpsc};
use tokio_stream::{wrappers::ReceiverStream, Stream};

use crate::jpeg::JpegSplitter;

pub type FrameStream = Pin<Box<dyn Stream<Item = Bytes> + Send>>;

const MOCK_FRAME_BYTES: [&[u8]; 12] = [
    include_bytes!("../assets/preview/frame_00.jpg"),
    include_bytes!("../assets/preview/frame_01.jpg"),
    include_bytes!("../assets/preview/frame_02.jpg"),
    include_bytes!("../assets/preview/frame_03.jpg"),
    include_bytes!("../assets/preview/frame_04.jpg"),
    include_bytes!("../assets/preview/frame_05.jpg"),
    include_bytes!("../assets/preview/frame_06.jpg"),
    include_bytes!("../assets/preview/frame_07.jpg"),
    include_bytes!("../assets/preview/frame_08.jpg"),
    include_bytes!("../assets/preview/frame_09.jpg"),
    include_bytes!("../assets/preview/frame_10.jpg"),
    include_bytes!("../assets/preview/frame_11.jpg"),
];

pub trait Backend: Send + Sync + 'static {
    fn recording(&self) -> bool;
    fn preview_frames(&self) -> FrameStream;
}

pub struct MockBackend;

impl Backend for MockBackend {
    fn recording(&self) -> bool {
        false
    }

    fn preview_frames(&self) -> FrameStream {
        let (tx, rx) = mpsc::channel(4);

        tokio::spawn(async move {
            let mut frames = MOCK_FRAME_BYTES.iter().cycle();
            let mut interval = tokio::time::interval(Duration::from_millis(100));

            loop {
                interval.tick().await;

                let frame = frames
                    .next()
                    .expect("cycled mock frames should never be exhausted");

                if tx.send(Bytes::from_static(frame)).await.is_err() {
                    break;
                }
            }
        });

        Box::pin(ReceiverStream::new(rx))
    }
}

pub struct RpicamBackend;

impl Backend for RpicamBackend {
    fn recording(&self) -> bool {
        false
    }

    fn preview_frames(&self) -> FrameStream {
        let (tx, rx) = mpsc::channel(4);

        tokio::spawn(async move {
            let mut child = match Command::new("rpicam-vid")
                .args([
                    "-n",
                    "-t",
                    "0",
                    "--codec",
                    "mjpeg",
                    "--width",
                    "640",
                    "--height",
                    "480",
                    "--framerate",
                    "10",
                    "--quality",
                    "50",
                    "--flush",
                    "-o",
                    "-",
                ])
                .stdout(Stdio::piped())
                .stderr(Stdio::null())
                .kill_on_drop(true)
                .spawn()
            {
                Ok(child) => child,
                Err(error) => {
                    tracing::error!(%error, "failed to start rpicam-vid preview");
                    return;
                }
            };

            let Some(mut stdout) = child.stdout.take() else {
                tracing::error!("rpicam-vid preview stdout was not piped");
                let _ = child.kill().await;
                let _ = child.wait().await;
                return;
            };

            let mut splitter = JpegSplitter::new();
            let mut buffer = [0_u8; 8192];
            let mut receiver_closed = false;

            loop {
                tokio::select! {
                    _ = tx.closed() => {
                        receiver_closed = true;
                    }
                    read_result = stdout.read(&mut buffer) => {
                        match read_result {
                            Ok(0) => break,
                            Ok(bytes_read) => {
                                for frame in splitter.push(&buffer[..bytes_read]) {
                                    if tx.send(Bytes::from(frame)).await.is_err() {
                                        receiver_closed = true;
                                        break;
                                    }
                                }
                            }
                            Err(error) => {
                                tracing::warn!(%error, "failed reading rpicam-vid preview stdout");
                                break;
                            }
                        }
                    }
                }

                if receiver_closed {
                    break;
                }
            }

            let _ = child.kill().await;
            let _ = child.wait().await;
        });

        Box::pin(ReceiverStream::new(rx))
    }
}
