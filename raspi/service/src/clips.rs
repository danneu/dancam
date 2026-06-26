use std::{
    path::Path,
    time::{SystemTime, UNIX_EPOCH},
};

use axum::{extract::State, Json};

use crate::AppState;

const MAX_CLIPS: usize = 500;

#[derive(Clone, Debug, serde::Serialize, PartialEq, Eq)]
pub struct ClipMeta {
    pub id: u32,
    pub start_ms: Option<u64>,
    pub dur_ms: Option<u64>,
    pub bytes: u64,
    pub locked: bool,
    pub etag: String,
    pub time_approximate: bool,
}

#[derive(Clone, Debug, serde::Serialize, PartialEq, Eq)]
pub struct ClipsResponse {
    pub clips: Vec<ClipMeta>,
    pub server_time_ms: u64,
    pub next_cursor: Option<String>,
}

pub async fn list_clips(State(state): State<AppState>) -> Json<ClipsResponse> {
    let recording = state.backend.status().recording;

    Json(ClipsResponse {
        clips: read_finished_clips(&state.rec_dir, recording),
        server_time_ms: server_time_ms(),
        next_cursor: None,
    })
}

pub fn read_finished_clips(rec_dir: &Path, recording: bool) -> Vec<ClipMeta> {
    let Ok(entries) = std::fs::read_dir(rec_dir) else {
        return Vec::new();
    };

    let mut candidates = Vec::new();

    for entry in entries.flatten() {
        let path = entry.path();
        let Some(seq) = clip_seq(&path) else {
            continue;
        };
        let Ok(metadata) = entry.metadata() else {
            continue;
        };
        if !metadata.is_file() {
            continue;
        }

        candidates.push((seq, metadata.len()));
    }

    let max_seq = candidates.iter().map(|(seq, _)| *seq).max();
    let mut clips: Vec<_> = candidates
        .into_iter()
        .filter(|(seq, _)| !recording || Some(*seq) != max_seq)
        .map(|(seq, bytes)| ClipMeta {
            id: seq,
            start_ms: None,
            dur_ms: None,
            bytes,
            locked: false,
            etag: format!("{seq}-{bytes}"),
            time_approximate: true,
        })
        .collect();

    clips.sort_by(|left, right| right.id.cmp(&left.id));
    if clips.len() > MAX_CLIPS {
        tracing::warn!(
            total = clips.len(),
            returned = MAX_CLIPS,
            "truncating clips list"
        );
        clips.truncate(MAX_CLIPS);
    }

    clips
}

fn clip_seq(path: &Path) -> Option<u32> {
    let name = path.file_name()?.to_str()?;
    let seq = name.strip_prefix("seg_")?.strip_suffix(".ts")?;
    if seq.len() != 5 || !seq.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }

    seq.parse().ok()
}

fn server_time_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::read_finished_clips;
    use std::{fs, path::Path};

    #[test]
    fn read_finished_clips_returns_newest_first_when_not_recording() {
        let rec_dir = temp_rec_dir();
        write_file(&rec_dir.path, "seg_00000.ts", b"zero");
        write_file(&rec_dir.path, "seg_00001.ts", b"one-one");
        write_file(&rec_dir.path, "seg_00002.ts", b"two");
        write_file(&rec_dir.path, "notes.txt", b"ignored");

        let clips = read_finished_clips(&rec_dir.path, false);

        assert_eq!(
            clips.iter().map(|clip| clip.id).collect::<Vec<_>>(),
            [2, 1, 0]
        );
        assert_eq!(clips[0].bytes, 3);
        assert_eq!(clips[0].etag, "2-3");
    }

    #[test]
    fn read_finished_clips_excludes_newest_segment_while_recording() {
        let rec_dir = temp_rec_dir();
        write_file(&rec_dir.path, "seg_00000.ts", b"zero");
        write_file(&rec_dir.path, "seg_00001.ts", b"one");
        write_file(&rec_dir.path, "seg_00002.ts", b"two");

        let clips = read_finished_clips(&rec_dir.path, true);

        assert_eq!(clips.iter().map(|clip| clip.id).collect::<Vec<_>>(), [1, 0]);
    }

    #[test]
    fn read_finished_clips_returns_empty_for_single_open_segment() {
        let rec_dir = temp_rec_dir();
        write_file(&rec_dir.path, "seg_00000.ts", b"zero");

        assert!(read_finished_clips(&rec_dir.path, true).is_empty());
    }

    #[test]
    fn read_finished_clips_returns_empty_for_missing_dir() {
        let rec_dir = temp_rec_dir();
        let missing = rec_dir.path.join("missing");

        assert!(read_finished_clips(&missing, false).is_empty());
    }

    fn write_file(dir: &Path, name: &str, bytes: &[u8]) {
        fs::write(dir.join(name), bytes).unwrap();
    }

    struct TempRecDir {
        path: std::path::PathBuf,
    }

    impl Drop for TempRecDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }

    fn temp_rec_dir() -> TempRecDir {
        let path = std::env::temp_dir().join(format!("dancam-clips-{}", uuid::Uuid::new_v4()));
        fs::create_dir(&path).unwrap();
        TempRecDir { path }
    }
}
