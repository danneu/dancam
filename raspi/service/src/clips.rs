use std::{
    io::SeekFrom,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

use axum::{
    body::Body,
    extract::{Path as PathParam, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use tokio::{
    fs::File,
    io::{AsyncReadExt, AsyncSeekExt},
};
use tokio_util::io::ReaderStream;

use crate::{recorder::SegmentId, ts_duration::DurationCache, AppState};

const MAX_CLIPS: usize = 500;

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
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
    let unpullable_from = state.backend.unpullable_from();
    let rec_dir = state.rec_dir.clone();
    let duration_cache = state.clip_durations.clone();
    let clips = match tokio::task::spawn_blocking(move || {
        read_finished_clips(rec_dir.as_ref(), unpullable_from, duration_cache.as_ref())
    })
    .await
    {
        Ok(clips) => clips,
        Err(error) => {
            tracing::error!(%error, "clip listing task failed");
            Vec::new()
        }
    };

    Json(ClipsResponse {
        clips,
        server_time_ms: server_time_ms(),
        next_cursor: None,
    })
}

pub async fn serve_clip(
    State(state): State<AppState>,
    PathParam(id): PathParam<u32>,
    headers: HeaderMap,
) -> Result<Response, ClipError> {
    if state
        .backend
        .unpullable_from()
        .is_some_and(|floor| id >= floor)
    {
        return Err(ClipError::NotFound);
    }

    let path = state.rec_dir.join(format!("seg_{id:05}.ts"));
    let mut file = File::open(path).await.map_err(|_| ClipError::NotFound)?;
    let metadata = file.metadata().await.map_err(|_| ClipError::NotFound)?;
    if !metadata.is_file() {
        return Err(ClipError::NotFound);
    }

    let total = metadata.len();
    let etag = http_etag(id, total);

    let range = header_str(&headers, header::RANGE);
    // RFC 9110: If-Range uses a strong octet-for-octet validator comparison; a
    // non-matching validator means ignore the Range and serve the full body.
    let if_range_blocks = header_str(&headers, header::IF_RANGE).is_some_and(|value| value != etag);

    if range.is_none() || if_range_blocks {
        return Ok(full_response(file, total, &etag));
    }

    match resolve_range(range, total) {
        RangeResolution::Full => Ok(full_response(file, total, &etag)),
        RangeResolution::Partial { start, end } => {
            let len = end - start + 1;
            file.seek(SeekFrom::Start(start))
                .await
                .map_err(|_| ClipError::NotFound)?;
            let body = Body::from_stream(ReaderStream::new(file.take(len)));
            Ok(partial_response(body, start, end, total, len, &etag))
        }
        RangeResolution::Unsatisfiable => Err(ClipError::RangeNotSatisfiable { total }),
    }
}

/// RFC 9110 entity-tag wire form: quoted `"{seq}-{bytes}"`. Used for both the
/// `ETag` response header and the `If-Range` comparison so a raw-vs-quoted
/// mismatch can never silently downgrade a resume to a `200` restart. The JSON
/// clips list keeps the raw/unquoted `{seq}-{bytes}` value; the app quotes it.
fn http_etag(seq: u32, bytes: u64) -> String {
    format!("\"{seq}-{bytes}\"")
}

fn header_str(headers: &HeaderMap, name: header::HeaderName) -> Option<&str> {
    headers.get(name).and_then(|value| value.to_str().ok())
}

fn full_response(file: File, total: u64, etag: &str) -> Response {
    Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "application/mp2t")
        .header(header::CONTENT_LENGTH, total)
        .header(header::ACCEPT_RANGES, "bytes")
        .header(header::ETAG, etag)
        .body(Body::from_stream(ReaderStream::new(file)))
        .expect("clip response headers are always valid")
}

fn partial_response(
    body: Body,
    start: u64,
    end: u64,
    total: u64,
    len: u64,
    etag: &str,
) -> Response {
    Response::builder()
        .status(StatusCode::PARTIAL_CONTENT)
        .header(header::CONTENT_TYPE, "application/mp2t")
        .header(header::CONTENT_LENGTH, len)
        .header(
            header::CONTENT_RANGE,
            format!("bytes {start}-{end}/{total}"),
        )
        .header(header::ACCEPT_RANGES, "bytes")
        .header(header::ETAG, etag)
        .body(body)
        .expect("clip response headers are always valid")
}

/// Resolve a `Range` header against the representation size, mirroring the
/// app-side `HTTPRangeRequest.resolveRange` semantics: single range only
/// (reject a comma), `bytes=` prefix, forms `N-` / `N-M` / suffix `-N`; clamp
/// `end` to `total - 1`; `start >= total` is unsatisfiable.
fn resolve_range(raw: Option<&str>, total: u64) -> RangeResolution {
    let Some(raw) = raw else {
        return RangeResolution::Full;
    };
    if total == 0 {
        return RangeResolution::Unsatisfiable;
    }
    let Some(spec) = raw.strip_prefix("bytes=") else {
        return RangeResolution::Unsatisfiable;
    };
    if spec.contains(',') {
        return RangeResolution::Unsatisfiable;
    }
    let Some((raw_start, raw_end)) = spec.split_once('-') else {
        return RangeResolution::Unsatisfiable;
    };

    if raw_start.is_empty() {
        let Ok(suffix) = raw_end.parse::<u64>() else {
            return RangeResolution::Unsatisfiable;
        };
        if suffix == 0 {
            return RangeResolution::Unsatisfiable;
        }
        let start = total.saturating_sub(suffix);
        return RangeResolution::Partial {
            start,
            end: total - 1,
        };
    }

    let Ok(start) = raw_start.parse::<u64>() else {
        return RangeResolution::Unsatisfiable;
    };
    if start >= total {
        return RangeResolution::Unsatisfiable;
    }

    if raw_end.is_empty() {
        return RangeResolution::Partial {
            start,
            end: total - 1,
        };
    }

    let Ok(requested_end) = raw_end.parse::<u64>() else {
        return RangeResolution::Unsatisfiable;
    };
    if requested_end < start {
        return RangeResolution::Unsatisfiable;
    }

    RangeResolution::Partial {
        start,
        end: requested_end.min(total - 1),
    }
}

#[derive(Debug, PartialEq, Eq)]
enum RangeResolution {
    Full,
    Partial { start: u64, end: u64 },
    Unsatisfiable,
}

pub(crate) fn read_finished_clips(
    rec_dir: &Path,
    unpullable_from: Option<SegmentId>,
    duration_cache: &DurationCache,
) -> Vec<ClipMeta> {
    let candidates = segment_candidates(rec_dir);
    let mut candidates: Vec<_> = candidates
        .into_iter()
        .filter(|(seq, _, _)| unpullable_from.is_none_or(|floor| *seq < floor))
        .collect();

    candidates.sort_by(|(left_seq, _, _), (right_seq, _, _)| right_seq.cmp(left_seq));
    if candidates.len() > MAX_CLIPS {
        tracing::warn!(
            total = candidates.len(),
            returned = MAX_CLIPS,
            "truncating clips list"
        );
        candidates.truncate(MAX_CLIPS);
    }

    candidates
        .into_iter()
        .map(|(seq, bytes, path)| ClipMeta {
            id: seq,
            start_ms: None,
            dur_ms: duration_cache.duration_ms(seq, &path, bytes),
            bytes,
            locked: false,
            etag: format!("{seq}-{bytes}"),
            time_approximate: true,
        })
        .collect()
}

pub(crate) fn open_segment(rec_dir: &Path) -> Option<(u32, PathBuf, u64)> {
    let candidates = segment_candidates(rec_dir);
    let max_seq = max_segment_seq(&candidates)?;

    candidates
        .into_iter()
        .find(|(seq, _, _)| *seq == max_seq)
        .map(|(seq, bytes, path)| (seq, path, bytes))
}

pub(crate) fn max_clip_seq(rec_dir: &Path) -> Option<u32> {
    open_segment(rec_dir).map(|(seq, _, _)| seq)
}

pub(crate) fn clip_meta(
    rec_dir: &Path,
    seq: SegmentId,
    duration_cache: Option<&DurationCache>,
) -> Option<ClipMeta> {
    let path = rec_dir.join(format!("seg_{seq:05}.ts"));
    let metadata = std::fs::metadata(&path).ok()?;
    if !metadata.is_file() {
        return None;
    }
    let bytes = metadata.len();
    Some(ClipMeta {
        id: seq,
        start_ms: None,
        dur_ms: duration_cache.and_then(|cache| cache.duration_ms(seq, &path, bytes)),
        bytes,
        locked: false,
        etag: format!("{seq}-{bytes}"),
        time_approximate: true,
    })
}

fn segment_candidates(rec_dir: &Path) -> Vec<(u32, u64, PathBuf)> {
    let Ok(entries) = std::fs::read_dir(rec_dir) else {
        return Vec::new();
    };

    entries
        .flatten()
        .filter_map(|entry| {
            let path = entry.path();
            let seq = clip_seq(&path)?;
            let metadata = entry.metadata().ok()?;
            metadata.is_file().then_some((seq, metadata.len(), path))
        })
        .collect()
}

fn max_segment_seq(candidates: &[(u32, u64, PathBuf)]) -> Option<u32> {
    candidates.iter().map(|(seq, _, _)| *seq).max()
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

#[derive(Debug)]
pub enum ClipError {
    NotFound,
    RangeNotSatisfiable { total: u64 },
}

impl IntoResponse for ClipError {
    fn into_response(self) -> Response {
        match self {
            ClipError::NotFound => StatusCode::NOT_FOUND.into_response(),
            ClipError::RangeNotSatisfiable { total } => Response::builder()
                .status(StatusCode::RANGE_NOT_SATISFIABLE)
                .header(header::CONTENT_RANGE, format!("bytes */{total}"))
                .body(Body::empty())
                .expect("range-not-satisfiable response headers are always valid"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{http_etag, max_clip_seq, read_finished_clips, resolve_range, RangeResolution};
    use crate::ts_duration::DurationCache;
    use std::{fs, path::Path};

    #[test]
    fn http_etag_quotes_the_seq_bytes_pair() {
        assert_eq!(http_etag(1, 7), "\"1-7\"");
    }

    #[test]
    fn resolve_range_is_full_without_a_header() {
        assert_eq!(resolve_range(None, 10), RangeResolution::Full);
    }

    #[test]
    fn resolve_range_open_ended_runs_to_the_last_byte() {
        assert_eq!(
            resolve_range(Some("bytes=3-"), 10),
            RangeResolution::Partial { start: 3, end: 9 }
        );
    }

    #[test]
    fn resolve_range_closed_range_clamps_end_to_total() {
        assert_eq!(
            resolve_range(Some("bytes=2-5"), 10),
            RangeResolution::Partial { start: 2, end: 5 }
        );
        assert_eq!(
            resolve_range(Some("bytes=2-100"), 10),
            RangeResolution::Partial { start: 2, end: 9 }
        );
    }

    #[test]
    fn resolve_range_suffix_returns_the_tail() {
        assert_eq!(
            resolve_range(Some("bytes=-4"), 10),
            RangeResolution::Partial { start: 6, end: 9 }
        );
    }

    #[test]
    fn resolve_range_suffix_larger_than_total_returns_whole_file() {
        assert_eq!(
            resolve_range(Some("bytes=-100"), 10),
            RangeResolution::Partial { start: 0, end: 9 }
        );
    }

    #[test]
    fn resolve_range_rejects_unsatisfiable_and_garbage() {
        assert_eq!(
            resolve_range(Some("bytes=100-"), 10),
            RangeResolution::Unsatisfiable
        );
        assert_eq!(
            resolve_range(Some("bytes=10-"), 10),
            RangeResolution::Unsatisfiable
        );
        assert_eq!(
            resolve_range(Some("bytes=0-1,3-4"), 10),
            RangeResolution::Unsatisfiable
        );
        assert_eq!(
            resolve_range(Some("bytes=5-2"), 10),
            RangeResolution::Unsatisfiable
        );
        assert_eq!(
            resolve_range(Some("0-3"), 10),
            RangeResolution::Unsatisfiable
        );
        assert_eq!(
            resolve_range(Some("bytes=abc"), 10),
            RangeResolution::Unsatisfiable
        );
        assert_eq!(
            resolve_range(Some("bytes=-0"), 10),
            RangeResolution::Unsatisfiable
        );
        assert_eq!(
            resolve_range(Some("bytes=0-"), 0),
            RangeResolution::Unsatisfiable
        );
    }

    #[test]
    fn read_finished_clips_returns_newest_first_when_not_recording() {
        let rec_dir = temp_rec_dir();
        write_file(&rec_dir.path, "seg_00000.ts", b"zero");
        write_file(&rec_dir.path, "seg_00001.ts", b"one-one");
        write_file(&rec_dir.path, "seg_00002.ts", b"two");
        write_file(&rec_dir.path, "notes.txt", b"ignored");

        let clips = read_finished_clips_for_test(&rec_dir.path, None);

        assert_eq!(
            clips.iter().map(|clip| clip.id).collect::<Vec<_>>(),
            [2, 1, 0]
        );
        assert_eq!(clips[0].bytes, 3);
        assert_eq!(clips[0].etag, "2-3");
    }

    #[test]
    fn read_finished_clips_excludes_segments_at_or_above_floor() {
        let rec_dir = temp_rec_dir();
        write_file(&rec_dir.path, "seg_00000.ts", b"zero");
        write_file(&rec_dir.path, "seg_00001.ts", b"one");
        write_file(&rec_dir.path, "seg_00002.ts", b"two");

        let clips = read_finished_clips_for_test(&rec_dir.path, Some(2));

        assert_eq!(clips.iter().map(|clip| clip.id).collect::<Vec<_>>(), [1, 0]);
    }

    #[test]
    fn read_finished_clips_returns_empty_when_only_reserved_segment_exists() {
        let rec_dir = temp_rec_dir();
        write_file(&rec_dir.path, "seg_00000.ts", b"zero");

        assert!(read_finished_clips_for_test(&rec_dir.path, Some(0)).is_empty());
    }

    #[test]
    fn read_finished_clips_returns_empty_for_missing_dir() {
        let rec_dir = temp_rec_dir();
        let missing = rec_dir.path.join("missing");

        assert!(read_finished_clips_for_test(&missing, None).is_empty());
    }

    #[test]
    fn max_clip_seq_uses_segment_filename_parser() {
        let rec_dir = temp_rec_dir();
        write_file(&rec_dir.path, "seg_00000.ts", b"zero");
        write_file(&rec_dir.path, "seg_00003.ts", b"three");
        write_file(&rec_dir.path, "seg_999.ts", b"ignored");

        assert_eq!(max_clip_seq(&rec_dir.path), Some(3));
    }

    fn write_file(dir: &Path, name: &str, bytes: &[u8]) {
        fs::write(dir.join(name), bytes).unwrap();
    }

    fn read_finished_clips_for_test(
        rec_dir: &Path,
        unpullable_from: Option<u32>,
    ) -> Vec<super::ClipMeta> {
        let duration_cache = DurationCache::new();
        read_finished_clips(rec_dir, unpullable_from, &duration_cache)
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
