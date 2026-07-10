use std::{
    collections::BTreeMap,
    io::{self, SeekFrom},
    path::{Path, PathBuf},
};

use axum::{
    body::Body,
    extract::{Path as PathParam, Query, State},
    http::{header, HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use tokio::{
    fs::File,
    io::{AsyncReadExt, AsyncSeekExt},
};
use tokio_util::io::ReaderStream;

use crate::{
    mutation::{require_mutation_headers, MutationHeaderError},
    recorder::{parse_segment_filename, SegmentFacts, SegmentId},
    storage::SegmentDeleteError,
    time_sync::TimeStore,
    ts_duration::DurationCache,
    AppState,
};

const DEFAULT_LIMIT: usize = 100;
const MAX_LIMIT: usize = DEFAULT_LIMIT;

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct ClipMeta {
    pub id: u32,
    pub boot_tag: Option<String>,
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
    pub server_time_ms: Option<u64>,
    pub next_cursor: Option<String>,
}

#[derive(Clone, Debug)]
pub(crate) struct SegmentCandidate {
    pub(crate) seq: SegmentId,
    pub(crate) bytes: u64,
    pub(crate) path: PathBuf,
    pub(crate) facts: Option<SegmentFacts>,
}

#[derive(Debug, PartialEq, Eq)]
pub(crate) struct ZeroByteRepair {
    pub(crate) fully_empty_ids: Vec<SegmentId>,
    pub(crate) stale_empty_paths: Vec<PathBuf>,
}

#[derive(Debug, serde::Deserialize)]
pub(crate) struct ClipsQuery {
    limit: Option<usize>,
    cursor: Option<String>,
    #[serde(rename = "from")]
    from_ms: Option<String>,
    to: Option<String>,
    order: Option<String>,
}

pub(crate) async fn list_clips(
    State(state): State<AppState>,
    Query(query): Query<ClipsQuery>,
) -> Result<Json<ClipsResponse>, ClipError> {
    if query.from_ms.is_some() || query.to.is_some() {
        return Err(ClipError::BadRequest);
    }
    if query.order.as_deref().is_some_and(|order| order != "desc") {
        return Err(ClipError::BadRequest);
    }

    let cursor = query
        .cursor
        .as_deref()
        .map(str::parse::<SegmentId>)
        .transpose()
        .map_err(|_| ClipError::BadRequest)?;
    let limit = resolve_limit(query.limit);
    let unpullable_from = state.backend.unpullable_from();
    let rec_dir = state.storage.rec_dir();
    let duration_cache = state.clip_durations.clone();
    let time_store = state.time_store.clone();
    let (clips, next_cursor) = tokio::task::spawn_blocking(move || {
        read_finished_clips(
            rec_dir.as_ref(),
            unpullable_from,
            cursor,
            limit,
            duration_cache.as_ref(),
            time_store.as_ref(),
        )
    })
    .await
    .map_err(|error| {
        tracing::error!(%error, "clip listing task failed");
        ClipError::Unavailable
    })?
    .map_err(|error| {
        tracing::error!(%error, "failed to list clips");
        ClipError::Unavailable
    })?;

    Ok(Json(ClipsResponse {
        clips,
        server_time_ms: state.time_store.derived_wall_now_ms(),
        next_cursor: next_cursor.map(|seq| seq.to_string()),
    }))
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

    let rec_dir = state.storage.rec_dir();
    let segment = tokio::task::spawn_blocking(move || resolve_segment(rec_dir.as_ref(), id))
        .await
        .map_err(|error| {
            tracing::error!(%error, "clip resolve task failed");
            ClipError::Unavailable
        })?
        .map_err(|error| {
            tracing::error!(%error, id, "failed to resolve clip");
            ClipError::Unavailable
        })?
        .ok_or(ClipError::NotFound)?;
    let mut file = File::open(segment.path)
        .await
        .map_err(io_error_to_clip_error)?;
    let metadata = file.metadata().await.map_err(io_error_to_clip_error)?;
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
                .map_err(io_error_to_clip_error)?;
            let body = Body::from_stream(ReaderStream::new(file.take(len)));
            Ok(partial_response(body, start, end, total, len, &etag))
        }
        RangeResolution::Unsatisfiable => Err(ClipError::RangeNotSatisfiable { total }),
    }
}

pub async fn delete_clip(
    State(state): State<AppState>,
    PathParam(id): PathParam<u32>,
    headers: HeaderMap,
) -> Result<StatusCode, DeleteClipError> {
    require_mutation_headers(&headers)?;

    let storage = state.storage.clone();
    let backend = state.backend.clone();
    tokio::task::spawn_blocking(move || {
        storage.delete_finished_segment(id, || backend.unpullable_from())
    })
    .await
    .map_err(|error| {
        tracing::error!(%error, id, "clip delete task failed");
        ClipError::Unavailable
    })?
    .map_err(segment_delete_to_clip_error)?;

    state.backend.note_clip_removed(id);
    Ok(StatusCode::NO_CONTENT)
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
    cursor: Option<SegmentId>,
    limit: usize,
    duration_cache: &DurationCache,
    time_store: &TimeStore,
) -> io::Result<(Vec<ClipMeta>, Option<SegmentId>)> {
    let candidates = segment_candidates(rec_dir)?;
    let mut candidates: Vec<_> = candidates
        .into_iter()
        .filter(|candidate| unpullable_from.is_none_or(|floor| candidate.seq < floor))
        .filter(|candidate| cursor.is_none_or(|cursor| candidate.seq < cursor))
        .collect();

    candidates.sort_by_key(|candidate| std::cmp::Reverse(candidate.seq));
    let has_more = candidates.len() > limit;
    candidates.truncate(limit);
    let next_cursor = has_more
        .then(|| candidates.last().map(|candidate| candidate.seq))
        .flatten();

    let clips = candidates
        .into_iter()
        .map(|candidate| clip_meta_from_candidate(candidate, Some(duration_cache), time_store))
        .collect();

    Ok((clips, next_cursor))
}

pub(crate) fn resolve_limit(limit: Option<usize>) -> usize {
    limit.unwrap_or(DEFAULT_LIMIT).clamp(1, MAX_LIMIT)
}

pub(crate) fn open_segment(rec_dir: &Path) -> io::Result<Option<(u32, PathBuf, u64)>> {
    let candidates = segment_candidates(rec_dir)?;
    let Some(max_seq) = max_segment_seq(&candidates) else {
        return Ok(None);
    };

    Ok(candidates
        .into_iter()
        .find(|candidate| candidate.seq == max_seq)
        .map(|candidate| (candidate.seq, candidate.path, candidate.bytes)))
}

pub(crate) fn max_clip_seq(rec_dir: &Path) -> io::Result<Option<u32>> {
    open_segment(rec_dir).map(|segment| segment.map(|(seq, _, _)| seq))
}

pub(crate) fn clip_meta(
    rec_dir: &Path,
    seq: SegmentId,
    duration_cache: Option<&DurationCache>,
    time_store: &TimeStore,
) -> io::Result<Option<ClipMeta>> {
    let Some(segment) = resolve_segment(rec_dir, seq)? else {
        return Ok(None);
    };
    let meta = clip_meta_from_candidate(segment.clone(), duration_cache, time_store);
    if !meta.time_approximate || segment.facts.is_none() {
        return Ok(Some(meta));
    }

    let disk_time_store = TimeStore::load(rec_dir.join("time"));
    Ok(Some(clip_meta_from_candidate(
        segment,
        duration_cache,
        &disk_time_store,
    )))
}

pub(crate) fn resolve_segment(
    rec_dir: &Path,
    seq: SegmentId,
) -> io::Result<Option<SegmentCandidate>> {
    Ok(segment_candidates(rec_dir)?
        .into_iter()
        .find(|candidate| candidate.seq == seq))
}

fn segment_candidates(rec_dir: &Path) -> io::Result<Vec<SegmentCandidate>> {
    Ok(dedupe_candidates(raw_segment_candidates(rec_dir)?))
}

pub(crate) fn zero_byte_repair(rec_dir: &Path) -> io::Result<ZeroByteRepair> {
    let mut by_seq = BTreeMap::<SegmentId, Vec<SegmentCandidate>>::new();
    for candidate in raw_segment_candidates(rec_dir)? {
        by_seq.entry(candidate.seq).or_default().push(candidate);
    }

    let mut repair = ZeroByteRepair {
        fully_empty_ids: Vec::new(),
        stale_empty_paths: Vec::new(),
    };

    for (seq, mut candidates) in by_seq {
        candidates.sort_by(|left, right| left.path.cmp(&right.path));
        if candidates.iter().all(|candidate| candidate.bytes == 0) {
            repair.fully_empty_ids.push(seq);
            continue;
        }

        repair.stale_empty_paths.extend(
            candidates
                .into_iter()
                .filter(|candidate| candidate.bytes == 0)
                .map(|candidate| candidate.path),
        );
    }

    repair.stale_empty_paths.sort();
    Ok(repair)
}

fn raw_segment_candidates(rec_dir: &Path) -> io::Result<Vec<SegmentCandidate>> {
    let entries = match std::fs::read_dir(rec_dir) {
        Ok(entries) => entries,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error),
    };

    let mut parsed = Vec::new();
    for entry in entries {
        let entry = entry?;
        let path = entry.path();
        let Some(parsed_name) = path
            .file_name()
            .and_then(|name| name.to_str())
            .and_then(parse_segment_filename)
        else {
            continue;
        };
        let metadata = entry.metadata()?;
        if metadata.is_file() {
            parsed.push(SegmentCandidate {
                seq: parsed_name.seq,
                bytes: metadata.len(),
                path,
                facts: parsed_name.facts,
            });
        }
    }

    Ok(parsed)
}

pub(crate) fn segment_paths_for_id(rec_dir: &Path, id: SegmentId) -> io::Result<Vec<PathBuf>> {
    let entries = match std::fs::read_dir(rec_dir) {
        Ok(entries) => entries,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error),
    };

    let mut paths = Vec::new();
    for entry in entries {
        let entry = entry?;
        let path = entry.path();
        let Some(parsed_name) = path
            .file_name()
            .and_then(|name| name.to_str())
            .and_then(parse_segment_filename)
        else {
            continue;
        };
        if parsed_name.seq != id {
            continue;
        }
        let metadata = entry.metadata()?;
        if metadata.is_file() {
            paths.push(path);
        }
    }

    Ok(paths)
}

fn dedupe_candidates(candidates: Vec<SegmentCandidate>) -> Vec<SegmentCandidate> {
    let mut by_seq = BTreeMap::<SegmentId, SegmentCandidate>::new();
    for candidate in candidates {
        match by_seq.get_mut(&candidate.seq) {
            Some(current) if current.facts.is_none() && candidate.facts.is_some() => {
                *current = candidate;
            }
            Some(_) => {}
            None => {
                by_seq.insert(candidate.seq, candidate);
            }
        }
    }
    by_seq.into_values().collect()
}

fn max_segment_seq(candidates: &[SegmentCandidate]) -> Option<u32> {
    candidates.iter().map(|candidate| candidate.seq).max()
}

fn clip_meta_from_candidate(
    candidate: SegmentCandidate,
    duration_cache: Option<&DurationCache>,
    time_store: &TimeStore,
) -> ClipMeta {
    let start_ms = derive_start_ms(candidate.facts.as_ref(), time_store);
    let boot_tag = candidate.facts.as_ref().map(|facts| facts.boot_tag.clone());
    ClipMeta {
        id: candidate.seq,
        boot_tag,
        start_ms,
        dur_ms: duration_cache
            .and_then(|cache| cache.duration_ms(candidate.seq, &candidate.path, candidate.bytes)),
        bytes: candidate.bytes,
        locked: false,
        etag: format!("{}-{}", candidate.seq, candidate.bytes),
        time_approximate: start_ms.is_none(),
    }
}

fn derive_start_ms(facts: Option<&SegmentFacts>, time_store: &TimeStore) -> Option<u64> {
    let facts = facts?;
    let offset = time_store.offset_for_tag(&facts.boot_tag)?;
    let mono_ms = i64::try_from(facts.mono_ms).ok()?;
    let wall_ms = mono_ms.checked_add(offset)?;
    (wall_ms >= 0).then_some(wall_ms as u64)
}

fn io_error_to_clip_error(error: io::Error) -> ClipError {
    match error.kind() {
        io::ErrorKind::NotFound => ClipError::NotFound,
        _ => ClipError::Unavailable,
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum ClipError {
    BadRequest,
    NotFound,
    Unavailable,
    RangeNotSatisfiable { total: u64 },
}

impl IntoResponse for ClipError {
    fn into_response(self) -> Response {
        match self {
            ClipError::BadRequest => StatusCode::BAD_REQUEST.into_response(),
            ClipError::NotFound => StatusCode::NOT_FOUND.into_response(),
            ClipError::Unavailable => StatusCode::SERVICE_UNAVAILABLE.into_response(),
            ClipError::RangeNotSatisfiable { total } => Response::builder()
                .status(StatusCode::RANGE_NOT_SATISFIABLE)
                .header(header::CONTENT_RANGE, format!("bytes */{total}"))
                .body(Body::empty())
                .expect("range-not-satisfiable response headers are always valid"),
        }
    }
}

#[derive(Debug)]
pub enum DeleteClipError {
    MutationHeaders(MutationHeaderError),
    Clip(ClipError),
}

impl From<MutationHeaderError> for DeleteClipError {
    fn from(error: MutationHeaderError) -> Self {
        Self::MutationHeaders(error)
    }
}

impl From<ClipError> for DeleteClipError {
    fn from(error: ClipError) -> Self {
        Self::Clip(error)
    }
}

impl IntoResponse for DeleteClipError {
    fn into_response(self) -> Response {
        match self {
            DeleteClipError::MutationHeaders(error) => error.into_response(),
            DeleteClipError::Clip(error) => error.into_response(),
        }
    }
}

fn segment_delete_to_clip_error(error: SegmentDeleteError) -> ClipError {
    match error {
        SegmentDeleteError::NotFound => ClipError::NotFound,
        SegmentDeleteError::Io(error) => {
            tracing::error!(%error, "failed to delete clip");
            ClipError::Unavailable
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        http_etag, io_error_to_clip_error, max_clip_seq, read_finished_clips, resolve_limit,
        resolve_range, resolve_segment, segment_paths_for_id, zero_byte_repair, ClipError,
        RangeResolution, DEFAULT_LIMIT, MAX_LIMIT,
    };
    use crate::recorder::{stamped_segment_filename, SegmentFacts};
    use crate::time_sync::{OffsetRecord, TimeStore};
    use crate::ts_duration::DurationCache;
    #[cfg(unix)]
    use std::os::unix::fs::PermissionsExt;
    use std::{
        fs, io,
        path::{Path, PathBuf},
    };

    const BOOT_ABC: &str = "abc123de-f456-4000-8000-000000000001";
    const BOOT_DEF: &str = "def456ab-c123-4000-8000-000000000001";

    #[test]
    fn http_etag_quotes_the_seq_bytes_pair() {
        assert_eq!(http_etag(1, 7), "\"1-7\"");
    }

    #[test]
    fn io_error_to_clip_error_preserves_not_found_and_retries_other_io() {
        assert_eq!(
            io_error_to_clip_error(io::Error::from(io::ErrorKind::NotFound)),
            ClipError::NotFound
        );
        assert_eq!(
            io_error_to_clip_error(io::Error::from(io::ErrorKind::PermissionDenied)),
            ClipError::Unavailable
        );
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

        let (clips, next_cursor) = read_finished_clips_for_test(&rec_dir.path, None, None, 10);

        assert_eq!(
            clips.iter().map(|clip| clip.id).collect::<Vec<_>>(),
            [2, 1, 0]
        );
        assert_eq!(next_cursor, None);
        assert_eq!(clips[0].bytes, 3);
        assert_eq!(clips[0].etag, "2-3");
    }

    #[test]
    fn read_finished_clips_excludes_segments_at_or_above_floor() {
        let rec_dir = temp_rec_dir();
        write_file(&rec_dir.path, "seg_00000.ts", b"zero");
        write_file(&rec_dir.path, "seg_00001.ts", b"one");
        write_file(&rec_dir.path, "seg_00002.ts", b"two");

        let (clips, next_cursor) = read_finished_clips_for_test(&rec_dir.path, Some(2), None, 10);

        assert_eq!(clips.iter().map(|clip| clip.id).collect::<Vec<_>>(), [1, 0]);
        assert_eq!(next_cursor, None);
    }

    #[test]
    fn read_finished_clips_returns_empty_when_only_reserved_segment_exists() {
        let rec_dir = temp_rec_dir();
        write_file(&rec_dir.path, "seg_00000.ts", b"zero");

        let (clips, next_cursor) = read_finished_clips_for_test(&rec_dir.path, Some(0), None, 10);

        assert!(clips.is_empty());
        assert_eq!(next_cursor, None);
    }

    #[test]
    fn read_finished_clips_returns_empty_for_missing_dir() {
        let rec_dir = temp_rec_dir();
        let missing = rec_dir.path.join("missing");

        let (clips, next_cursor) = read_finished_clips_for_test(&missing, None, None, 10);

        assert!(clips.is_empty());
        assert_eq!(next_cursor, None);
    }

    #[cfg(unix)]
    #[test]
    fn read_finished_clips_fails_closed_for_unreadable_existing_dir() {
        let rec_dir = temp_rec_dir();
        write_file(&rec_dir.path, "seg_00000.ts", b"zero");
        fs::set_permissions(&rec_dir.path, fs::Permissions::from_mode(0o000)).unwrap();

        let duration_cache = DurationCache::new();
        let time_store = TimeStore::in_memory();
        let result =
            read_finished_clips(&rec_dir.path, None, None, 10, &duration_cache, &time_store);

        fs::set_permissions(&rec_dir.path, fs::Permissions::from_mode(0o700)).unwrap();
        if result.is_ok() {
            return;
        }
        assert_eq!(result.unwrap_err().kind(), io::ErrorKind::PermissionDenied);
    }

    #[test]
    fn max_clip_seq_uses_segment_filename_parser() {
        let rec_dir = temp_rec_dir();
        write_file(&rec_dir.path, "seg_00000.ts", b"zero");
        write_file(&rec_dir.path, "seg_00003.ts", b"three");
        write_file(&rec_dir.path, "seg_999.ts", b"ignored");

        assert_eq!(max_clip_seq(&rec_dir.path).unwrap(), Some(3));
    }

    #[test]
    fn max_clip_seq_sees_six_digit_segments() {
        let rec_dir = temp_rec_dir();
        write_file(&rec_dir.path, "seg_99999.ts", b"almost");
        write_file(&rec_dir.path, "seg_100000.ts", b"crossed");

        assert_eq!(max_clip_seq(&rec_dir.path).unwrap(), Some(100000));
    }

    #[test]
    fn max_clip_seq_parses_stamped_segments() {
        let rec_dir = temp_rec_dir();
        write_file(&rec_dir.path, "seg_00099.ts", b"bare");
        write_file(&rec_dir.path, &stamped_name(100), b"stamped");

        assert_eq!(max_clip_seq(&rec_dir.path).unwrap(), Some(100));
    }

    #[test]
    fn resolve_segment_prefers_stamped_over_bare_duplicate() {
        let rec_dir = temp_rec_dir();
        write_file(&rec_dir.path, "seg_00007.ts", b"bare");
        write_file(&rec_dir.path, &stamped_name(7), b"stamped");

        let segment = resolve_segment(&rec_dir.path, 7).unwrap().unwrap();

        assert_eq!(segment.seq, 7);
        assert_eq!(segment.bytes, 7);
        assert!(segment.facts.is_some());
        let expected = stamped_name(7);
        assert_eq!(
            segment.path.file_name().and_then(|name| name.to_str()),
            Some(expected.as_str())
        );
    }

    #[test]
    fn segment_paths_for_id_collects_duplicates_and_excludes_non_files() {
        let rec_dir = temp_rec_dir();
        write_file(&rec_dir.path, "seg_00007.ts", b"bare");
        let stamped = stamped_name(7);
        write_file(&rec_dir.path, &stamped, b"stamped");
        write_file(&rec_dir.path, &stamped_name(8), b"other");
        fs::create_dir(rec_dir.path.join("seg_00009.ts")).unwrap();

        let mut paths = segment_paths_for_id(&rec_dir.path, 7)
            .unwrap()
            .into_iter()
            .map(|path| path.file_name().unwrap().to_str().unwrap().to_string())
            .collect::<Vec<_>>();
        paths.sort();

        assert_eq!(paths, ["seg_00007.ts".to_string(), stamped]);
        assert_eq!(segment_paths_for_id(&rec_dir.path, 8).unwrap().len(), 1);
        assert!(segment_paths_for_id(&rec_dir.path, 9).unwrap().is_empty());
    }

    #[test]
    fn zero_byte_repair_marks_bare_only_zero_byte_segment_fully_empty() {
        let rec_dir = temp_rec_dir();
        write_file(&rec_dir.path, "seg_00007.ts", b"");

        let repair = zero_byte_repair(&rec_dir.path).unwrap();

        assert_eq!(repair.fully_empty_ids, [7]);
        assert!(repair.stale_empty_paths.is_empty());
    }

    #[test]
    fn zero_byte_repair_ignores_bare_only_nonzero_segment() {
        let rec_dir = temp_rec_dir();
        write_file(&rec_dir.path, "seg_00007.ts", b"video");

        let repair = zero_byte_repair(&rec_dir.path).unwrap();

        assert!(repair.fully_empty_ids.is_empty());
        assert!(repair.stale_empty_paths.is_empty());
    }

    #[test]
    fn zero_byte_repair_marks_all_zero_duplicates_fully_empty() {
        let rec_dir = temp_rec_dir();
        write_file(&rec_dir.path, "seg_00007.ts", b"");
        write_file(&rec_dir.path, &stamped_name(7), b"");

        let repair = zero_byte_repair(&rec_dir.path).unwrap();

        assert_eq!(repair.fully_empty_ids, [7]);
        assert!(repair.stale_empty_paths.is_empty());
    }

    #[test]
    fn zero_byte_repair_preserves_nonzero_bare_twin_when_stamped_is_empty() {
        let rec_dir = temp_rec_dir();
        write_file(&rec_dir.path, "seg_00007.ts", b"video");
        let stamped = stamped_name(7);
        write_file(&rec_dir.path, &stamped, b"");

        let repair = zero_byte_repair(&rec_dir.path).unwrap();

        assert!(repair.fully_empty_ids.is_empty());
        assert_eq!(path_names(&repair.stale_empty_paths), [stamped]);
    }

    #[test]
    fn zero_byte_repair_preserves_nonzero_stamped_twin_when_bare_is_empty() {
        let rec_dir = temp_rec_dir();
        write_file(&rec_dir.path, "seg_00007.ts", b"");
        write_file(&rec_dir.path, &stamped_name(7), b"video");

        let repair = zero_byte_repair(&rec_dir.path).unwrap();

        assert!(repair.fully_empty_ids.is_empty());
        assert_eq!(
            path_names(&repair.stale_empty_paths),
            ["seg_00007.ts".to_string()]
        );
    }

    #[test]
    fn zero_byte_repair_returns_empty_for_missing_rec_dir() {
        let rec_dir = temp_rec_dir();
        let missing = rec_dir.path.join("missing");

        let repair = zero_byte_repair(&missing).unwrap();

        assert!(repair.fully_empty_ids.is_empty());
        assert!(repair.stale_empty_paths.is_empty());
    }

    #[test]
    fn read_finished_clips_dedupes_same_seq_segments() {
        let rec_dir = temp_rec_dir();
        write_file(&rec_dir.path, "seg_00007.ts", b"bare");
        write_file(&rec_dir.path, &stamped_name(7), b"stamped");
        write_file(&rec_dir.path, "seg_00008.ts", b"newer");

        let (clips, next_cursor) = read_finished_clips_for_test(&rec_dir.path, None, None, 10);

        assert_eq!(clips.iter().map(|clip| clip.id).collect::<Vec<_>>(), [8, 7]);
        assert_eq!(clips[1].bytes, 7);
        assert_eq!(clips[1].etag, "7-7");
        assert_eq!(next_cursor, None);
    }

    #[test]
    fn read_finished_clips_lists_six_digit_segments_in_numeric_order() {
        let rec_dir = temp_rec_dir();
        write_file(&rec_dir.path, "seg_99999.ts", b"almost");
        write_file(&rec_dir.path, "seg_100000.ts", b"crossed");
        write_file(&rec_dir.path, "seg_999.ts", b"ignored");

        let (clips, next_cursor) = read_finished_clips_for_test(&rec_dir.path, None, None, 10);

        assert_eq!(
            clips.iter().map(|clip| clip.id).collect::<Vec<_>>(),
            [100000, 99999]
        );
        assert_eq!(next_cursor, None);
    }

    #[test]
    fn read_finished_clips_pages_newest_first_with_boundaries() {
        let rec_dir = temp_rec_dir();
        for seq in 0..5 {
            write_file(&rec_dir.path, &format!("seg_{seq:05}.ts"), b"segment");
        }

        let (first, first_cursor) = read_finished_clips_for_test(&rec_dir.path, None, None, 2);
        let (second, second_cursor) =
            read_finished_clips_for_test(&rec_dir.path, None, first_cursor, 2);
        let (third, third_cursor) =
            read_finished_clips_for_test(&rec_dir.path, None, second_cursor, 2);

        assert_eq!(first.iter().map(|clip| clip.id).collect::<Vec<_>>(), [4, 3]);
        assert_eq!(first_cursor, Some(3));
        assert_eq!(
            second.iter().map(|clip| clip.id).collect::<Vec<_>>(),
            [2, 1]
        );
        assert_eq!(second_cursor, Some(1));
        assert_eq!(third.iter().map(|clip| clip.id).collect::<Vec<_>>(), [0]);
        assert_eq!(third_cursor, None);

        let all_ids = first
            .iter()
            .chain(second.iter())
            .chain(third.iter())
            .map(|clip| clip.id)
            .collect::<Vec<_>>();
        assert_eq!(all_ids, [4, 3, 2, 1, 0]);
    }

    #[test]
    fn read_finished_clips_cursor_is_stable_when_newer_segments_arrive() {
        let rec_dir = temp_rec_dir();
        for seq in 0..5 {
            write_file(&rec_dir.path, &format!("seg_{seq:05}.ts"), b"segment");
        }
        let (_, cursor) = read_finished_clips_for_test(&rec_dir.path, None, None, 2);

        write_file(&rec_dir.path, "seg_00005.ts", b"newer");
        let (page, next_cursor) = read_finished_clips_for_test(&rec_dir.path, None, cursor, 2);

        assert_eq!(page.iter().map(|clip| clip.id).collect::<Vec<_>>(), [2, 1]);
        assert_eq!(next_cursor, Some(1));
    }

    #[test]
    fn read_finished_clips_applies_floor_on_every_page() {
        let rec_dir = temp_rec_dir();
        for seq in 0..5 {
            write_file(&rec_dir.path, &format!("seg_{seq:05}.ts"), b"segment");
        }

        let (first, first_cursor) = read_finished_clips_for_test(&rec_dir.path, Some(4), None, 2);
        let (second, second_cursor) =
            read_finished_clips_for_test(&rec_dir.path, Some(4), first_cursor, 2);

        assert_eq!(first.iter().map(|clip| clip.id).collect::<Vec<_>>(), [3, 2]);
        assert_eq!(first_cursor, Some(2));
        assert_eq!(
            second.iter().map(|clip| clip.id).collect::<Vec<_>>(),
            [1, 0]
        );
        assert_eq!(second_cursor, None);
    }

    #[test]
    fn read_finished_clips_derives_start_ms_from_facts_and_offset() {
        let rec_dir = temp_rec_dir();
        let time_dir = temp_rec_dir();
        write_file(
            &rec_dir.path,
            &stamped_name_with_mono(7, "abc123def456", 9000),
            b"clip",
        );
        write_offset(&time_dir.path, BOOT_ABC, 1000);
        let time_store = TimeStore::load(time_dir.path.clone());
        time_store.set_boot_id(BOOT_ABC);
        let duration_cache = DurationCache::new();

        let (clips, next_cursor) =
            read_finished_clips(&rec_dir.path, None, None, 10, &duration_cache, &time_store)
                .unwrap();

        assert_eq!(next_cursor, None);
        assert_eq!(clips.len(), 1);
        assert_eq!(clips[0].boot_tag.as_deref(), Some("abc123def456"));
        assert_eq!(clips[0].start_ms, Some(10_000));
        assert!(!clips[0].time_approximate);
    }

    #[test]
    fn read_finished_clips_reports_boot_tag_for_stamped_segments_only() {
        let rec_dir = temp_rec_dir();
        let time_dir = temp_rec_dir();
        write_file(&rec_dir.path, "seg_00007.ts", b"bare");
        write_file(
            &rec_dir.path,
            &stamped_name_with_mono(8, "abc123def456", 9000),
            b"stamped",
        );
        let time_store = TimeStore::load(time_dir.path.clone());
        let duration_cache = DurationCache::new();

        let (clips, _) =
            read_finished_clips(&rec_dir.path, None, None, 10, &duration_cache, &time_store)
                .unwrap();

        assert_eq!(clips.iter().map(|clip| clip.id).collect::<Vec<_>>(), [8, 7]);
        assert_eq!(clips[0].boot_tag.as_deref(), Some("abc123def456"));
        assert_eq!(clips[1].boot_tag, None);
    }

    #[test]
    fn read_finished_clips_stays_approximate_without_facts_or_offset() {
        let rec_dir = temp_rec_dir();
        let time_dir = temp_rec_dir();
        write_file(&rec_dir.path, "seg_00007.ts", b"bare");
        write_file(
            &rec_dir.path,
            &stamped_name_with_mono(8, "abc123def456", 9000),
            b"stamped",
        );
        write_offset(&time_dir.path, BOOT_DEF, 1000);
        let time_store = TimeStore::load(time_dir.path.clone());
        time_store.set_boot_id(BOOT_DEF);
        let duration_cache = DurationCache::new();

        let (clips, _) =
            read_finished_clips(&rec_dir.path, None, None, 10, &duration_cache, &time_store)
                .unwrap();

        assert_eq!(clips.iter().map(|clip| clip.id).collect::<Vec<_>>(), [8, 7]);
        for clip in clips {
            assert_eq!(clip.start_ms, None);
            assert!(clip.time_approximate);
        }
    }

    #[test]
    fn read_finished_clips_degrades_to_approximate_when_mono_overflows_i64() {
        let rec_dir = temp_rec_dir();
        let time_dir = temp_rec_dir();
        write_file(
            &rec_dir.path,
            &stamped_name_with_mono(7, "abc123def456", u64::MAX),
            b"clip",
        );
        write_offset(&time_dir.path, BOOT_ABC, 1000);
        let time_store = TimeStore::load(time_dir.path.clone());
        time_store.set_boot_id(BOOT_ABC);
        let duration_cache = DurationCache::new();

        let (clips, _) =
            read_finished_clips(&rec_dir.path, None, None, 10, &duration_cache, &time_store)
                .unwrap();

        assert_eq!(clips[0].start_ms, None);
        assert!(clips[0].time_approximate);
    }

    #[test]
    fn read_finished_clips_keys_offsets_by_segment_boottag() {
        let rec_dir = temp_rec_dir();
        let time_dir = temp_rec_dir();
        write_file(
            &rec_dir.path,
            &stamped_name_with_mono(7, "abc123def456", 50),
            b"clip",
        );
        write_offset(&time_dir.path, BOOT_ABC, 1000);
        write_offset(&time_dir.path, BOOT_DEF, 2000);
        let time_store = TimeStore::load(time_dir.path.clone());
        time_store.set_boot_id(BOOT_DEF);
        let duration_cache = DurationCache::new();

        let (clips, _) =
            read_finished_clips(&rec_dir.path, None, None, 10, &duration_cache, &time_store)
                .unwrap();

        assert_eq!(clips[0].start_ms, Some(1050));
        assert!(!clips[0].time_approximate);
    }

    #[test]
    fn read_finished_clips_requires_the_segment_boot_offset() {
        let rec_dir = temp_rec_dir();
        let time_dir = temp_rec_dir();
        write_file(
            &rec_dir.path,
            &stamped_name_with_mono(7, "abc123def456", 50),
            b"clip",
        );
        write_offset(&time_dir.path, BOOT_DEF, 2000);
        let time_store = TimeStore::load(time_dir.path.clone());
        time_store.set_boot_id(BOOT_DEF);
        let duration_cache = DurationCache::new();

        let (clips, _) =
            read_finished_clips(&rec_dir.path, None, None, 10, &duration_cache, &time_store)
                .unwrap();

        assert_eq!(clips[0].start_ms, None);
        assert!(clips[0].time_approximate);
    }

    #[test]
    fn resolve_limit_uses_default_and_clamps_bounds() {
        assert_eq!(resolve_limit(None), DEFAULT_LIMIT);
        assert_eq!(resolve_limit(Some(0)), 1);
        assert_eq!(resolve_limit(Some(MAX_LIMIT + 1)), MAX_LIMIT);
        assert_eq!(resolve_limit(Some(50)), 50);
    }

    fn write_file(dir: &Path, name: &str, bytes: &[u8]) {
        fs::write(dir.join(name), bytes).unwrap();
    }

    fn path_names(paths: &[PathBuf]) -> Vec<String> {
        paths
            .iter()
            .map(|path| path.file_name().unwrap().to_str().unwrap().to_string())
            .collect()
    }

    fn stamped_name(seq: u32) -> String {
        stamped_name_with_mono(seq, "abc123def456", 123456789)
    }

    fn stamped_name_with_mono(seq: u32, boot_tag: &str, mono_ms: u64) -> String {
        stamped_segment_filename(
            seq,
            &SegmentFacts {
                boot_tag: boot_tag.to_string(),
                session: 1,
                mono_ms,
            },
        )
    }

    fn write_offset(dir: &Path, boot_id: &str, offset_ms: i64) {
        let record = OffsetRecord {
            boot_id: boot_id.to_string(),
            offset_ms,
            source: "app".to_string(),
            synced_at_mono_ms: 123,
        };
        write_file(
            dir,
            &format!("{boot_id}.json"),
            &serde_json::to_vec(&record).unwrap(),
        );
    }

    fn read_finished_clips_for_test(
        rec_dir: &Path,
        unpullable_from: Option<u32>,
        cursor: Option<u32>,
        limit: usize,
    ) -> (Vec<super::ClipMeta>, Option<u32>) {
        let duration_cache = DurationCache::new();
        let time_store = TimeStore::in_memory();
        read_finished_clips(
            rec_dir,
            unpullable_from,
            cursor,
            limit,
            &duration_cache,
            &time_store,
        )
        .unwrap()
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
