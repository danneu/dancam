use std::{
    collections::{HashMap, HashSet},
    fs::{self, File},
    io,
    path::{Path, PathBuf},
    sync::Mutex,
};

use axum::{
    body::Bytes,
    extract::State,
    http::{HeaderMap, StatusCode},
    response::{IntoResponse, Response},
    Json,
};

use crate::{
    clock,
    mutation::{require_mutation_headers, MutationHeaderError},
    recorder::boot_tag,
    storage::ensure_required_mountpoint,
    AppState,
};

const MIN_EPOCH_MS: i64 = 1_767_225_600_000;
const MAX_EPOCH_MS: i64 = 4_102_444_800_000;

#[derive(Debug)]
pub struct TimeStore {
    dir: Option<PathBuf>,
    required_mountpoint: Option<PathBuf>,
    inner: Mutex<TimeState>,
}

#[derive(Debug, Default)]
struct TimeState {
    boot_id: Option<String>,
    loaded_boot_ids: HashSet<String>,
    by_tag: HashMap<String, TagOffset>,
    current: Option<OffsetRecord>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum TagOffset {
    Unique(i64),
    Ambiguous,
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct OffsetRecord {
    pub boot_id: String,
    pub offset_ms: i64,
    pub source: String,
    pub synced_at_mono_ms: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SyncOutcome {
    Recorded,
    AlreadySynced,
}

impl TimeStore {
    pub fn load(dir: impl Into<PathBuf>) -> Self {
        let dir = dir.into();
        let mut state = TimeState::default();
        for record in load_records(&dir) {
            insert_record(&mut state, record);
        }

        Self {
            dir: Some(dir),
            required_mountpoint: None,
            inner: Mutex::new(state),
        }
    }

    pub fn in_memory() -> Self {
        Self {
            dir: None,
            required_mountpoint: None,
            inner: Mutex::new(TimeState::default()),
        }
    }

    pub fn with_required_mountpoint(mut self, mountpoint: PathBuf) -> Self {
        self.required_mountpoint = Some(mountpoint);
        self
    }

    pub fn set_boot_id(&self, boot_id: impl Into<String>) {
        let boot_id = boot_id.into();
        let current = self
            .dir
            .as_ref()
            .map(|dir| dir.join(record_filename(&boot_id)))
            .and_then(|path| read_offset_record(&path))
            .filter(|record| record.boot_id == boot_id);

        let mut state = self.inner.lock().expect("time store mutex poisoned");
        state.boot_id = Some(boot_id);
        state.current = current;
    }

    pub fn current_boot_synced(&self) -> bool {
        let state = self.inner.lock().expect("time store mutex poisoned");
        match (&state.boot_id, &state.current) {
            (Some(boot_id), Some(current)) => current.boot_id == *boot_id,
            _ => false,
        }
    }

    pub fn offset_for_tag(&self, tag: &str) -> Option<i64> {
        let mut state = self.inner.lock().expect("time store mutex poisoned");
        if !matches!(state.by_tag.get(tag), Some(TagOffset::Unique(_))) {
            if let Some(dir) = &self.dir {
                for record in load_records(dir) {
                    insert_record(&mut state, record);
                }
            }
        }

        match state.by_tag.get(tag) {
            Some(TagOffset::Unique(offset)) => Some(*offset),
            Some(TagOffset::Ambiguous) | None => None,
        }
    }

    pub fn derived_wall_now_ms(&self) -> Option<u64> {
        let offset = {
            let state = self.inner.lock().expect("time store mutex poisoned");
            state.current.as_ref()?.offset_ms
        };
        checked_wall_ms(clock::boottime_ms(), offset)
    }

    pub fn sync(&self, epoch_ms: i64) -> io::Result<SyncOutcome> {
        let mut state = self.inner.lock().expect("time store mutex poisoned");
        let boot_id = state
            .boot_id
            .clone()
            .unwrap_or_else(|| "unknown".to_string());

        if state
            .current
            .as_ref()
            .is_some_and(|record| record.boot_id == boot_id)
        {
            return Ok(SyncOutcome::AlreadySynced);
        }

        if let Some(path) = self
            .dir
            .as_ref()
            .map(|dir| dir.join(record_filename(&boot_id)))
        {
            if let Some(record) =
                read_offset_record(&path).filter(|record| record.boot_id == boot_id)
            {
                insert_record(&mut state, record.clone());
                state.current = Some(record);
                return Ok(SyncOutcome::AlreadySynced);
            }
        }

        let synced_at_mono_ms = clock::boottime_ms();
        let mono_i64 = i64::try_from(synced_at_mono_ms).unwrap_or(i64::MAX);
        let record = OffsetRecord {
            boot_id,
            offset_ms: epoch_ms - mono_i64,
            source: "app".to_string(),
            synced_at_mono_ms,
        };

        if let Some(dir) = &self.dir {
            if let Some(mountpoint) = &self.required_mountpoint {
                ensure_required_mountpoint(mountpoint)?;
            }
            persist_record(dir, &record)?;
        }

        insert_record(&mut state, record.clone());
        state.current = Some(record);
        Ok(SyncOutcome::Recorded)
    }
}

pub async fn sync_time(
    State(state): State<AppState>,
    headers: HeaderMap,
    body: Bytes,
) -> Result<Json<TimeSyncResponse>, TimeSyncError> {
    require_mutation_headers(&headers)?;
    let request: TimeSyncRequest =
        serde_json::from_slice(&body).map_err(|_| TimeSyncError::InvalidJson)?;
    if !(MIN_EPOCH_MS..=MAX_EPOCH_MS).contains(&request.epoch_ms) {
        return Err(TimeSyncError::ImplausibleEpoch);
    }

    let state_store = state.time_store.clone();
    let backend_store = state.backend.time_store();
    tokio::task::spawn_blocking(move || {
        state_store.sync(request.epoch_ms)?;
        backend_store.sync(request.epoch_ms)?;
        Ok::<(), std::io::Error>(())
    })
    .await
    .map_err(|error| {
        tracing::error!(%error, "time sync task failed");
        TimeSyncError::Unavailable
    })?
    .map_err(|error| {
        tracing::error!(%error, "failed to persist time sync");
        TimeSyncError::Unavailable
    })?;

    state.backend.mark_time_synced();
    Ok(Json(TimeSyncResponse { synced: true }))
}

#[derive(Debug, serde::Deserialize)]
struct TimeSyncRequest {
    epoch_ms: i64,
}

#[derive(Debug, serde::Serialize)]
pub struct TimeSyncResponse {
    synced: bool,
}

#[derive(Debug)]
pub enum TimeSyncError {
    MutationHeaders(MutationHeaderError),
    InvalidJson,
    ImplausibleEpoch,
    Unavailable,
}

impl From<MutationHeaderError> for TimeSyncError {
    fn from(error: MutationHeaderError) -> Self {
        Self::MutationHeaders(error)
    }
}

impl IntoResponse for TimeSyncError {
    fn into_response(self) -> Response {
        match self {
            TimeSyncError::MutationHeaders(error) => error.into_response(),
            TimeSyncError::InvalidJson => {
                (StatusCode::BAD_REQUEST, "invalid JSON body").into_response()
            }
            TimeSyncError::ImplausibleEpoch => {
                (StatusCode::BAD_REQUEST, "epoch_ms outside plausible range").into_response()
            }
            TimeSyncError::Unavailable => {
                (StatusCode::SERVICE_UNAVAILABLE, "time sync unavailable").into_response()
            }
        }
    }
}

fn load_records(dir: &Path) -> Vec<OffsetRecord> {
    let Ok(entries) = fs::read_dir(dir) else {
        return Vec::new();
    };

    entries
        .flatten()
        .filter_map(|entry| {
            let path = entry.path();
            (path.extension().and_then(|ext| ext.to_str()) == Some("json"))
                .then(|| read_offset_record(&path))
                .flatten()
        })
        .collect()
}

fn read_offset_record(path: &Path) -> Option<OffsetRecord> {
    let bytes = fs::read(path).ok()?;
    serde_json::from_slice(&bytes).ok()
}

fn persist_record(dir: &Path, record: &OffsetRecord) -> io::Result<()> {
    fs::create_dir_all(dir)?;
    let path = dir.join(record_filename(&record.boot_id));
    if read_offset_record(&path)
        .as_ref()
        .is_some_and(|stored| stored.boot_id == record.boot_id)
    {
        return Ok(());
    }

    let tmp = dir.join(format!("{}.tmp", record_filename(&record.boot_id)));
    let file = File::create(&tmp)?;
    serde_json::to_writer(&file, record)?;
    file.sync_all()?;
    drop(file);

    fs::rename(&tmp, &path)?;
    fsync_dir(dir);
    Ok(())
}

fn fsync_dir(dir: &Path) {
    if let Ok(file) = File::open(dir) {
        let _ = file.sync_all();
    }
}

fn record_filename(boot_id: &str) -> String {
    format!("{boot_id}.json")
}

fn insert_record(state: &mut TimeState, record: OffsetRecord) {
    if !state.loaded_boot_ids.insert(record.boot_id.clone()) {
        return;
    }

    let Some(tag) = boot_tag(&record.boot_id) else {
        return;
    };

    match state.by_tag.get_mut(&tag) {
        Some(offset) => {
            *offset = TagOffset::Ambiguous;
        }
        None => {
            state
                .by_tag
                .insert(tag, TagOffset::Unique(record.offset_ms));
        }
    }
}

fn checked_wall_ms(mono_ms: u64, offset_ms: i64) -> Option<u64> {
    let mono_ms = i64::try_from(mono_ms).ok()?;
    let wall_ms = mono_ms.checked_add(offset_ms)?;
    (wall_ms >= 0).then_some(wall_ms as u64)
}

#[cfg(test)]
mod tests {
    use std::{
        fs,
        sync::{Arc, Barrier},
        thread,
    };

    use super::{OffsetRecord, SyncOutcome, TimeStore};

    const BOOT_A: &str = "aaaaaaaa-aaaa-4000-8000-000000000001";
    const BOOT_A_COLLISION: &str = "aaaaaaaa-aaaa-4000-8000-000000000002";
    const BOOT_B: &str = "bbbbbbbb-bbbb-4000-8000-000000000001";
    const VALID_EPOCH_MS: i64 = 1_800_000_000_000;

    #[test]
    fn offset_record_round_trips_through_the_file() {
        let dir = TempDir::new("time-store-roundtrip");
        let store = TimeStore::load(dir.path.clone());
        store.set_boot_id(BOOT_A);

        assert_eq!(store.sync(VALID_EPOCH_MS).unwrap(), SyncOutcome::Recorded);
        let reloaded = TimeStore::load(dir.path.clone());
        reloaded.set_boot_id(BOOT_A);

        assert!(reloaded.current_boot_synced());
        assert!(reloaded.offset_for_tag("aaaaaaaaaaaa").is_some());
        let record = read_record(&dir.path, BOOT_A);
        assert_eq!(record.boot_id, BOOT_A);
        assert_eq!(record.source, "app");
    }

    #[test]
    fn load_skips_torn_files_and_resyncs_the_boot() {
        let dir = TempDir::new("time-store-torn");
        fs::create_dir_all(&dir.path).unwrap();
        fs::write(dir.path.join(format!("{BOOT_A}.json")), b"{").unwrap();

        let store = TimeStore::load(dir.path.clone());
        store.set_boot_id(BOOT_A);
        assert!(!store.current_boot_synced());

        assert_eq!(store.sync(VALID_EPOCH_MS).unwrap(), SyncOutcome::Recorded);
        assert!(store.current_boot_synced());
        assert_eq!(read_record(&dir.path, BOOT_A).boot_id, BOOT_A);
    }

    #[test]
    fn sync_is_write_once_per_boot() {
        let dir = TempDir::new("time-store-write-once");
        let store = TimeStore::load(dir.path.clone());
        store.set_boot_id(BOOT_A);

        assert_eq!(store.sync(VALID_EPOCH_MS).unwrap(), SyncOutcome::Recorded);
        let first = read_record(&dir.path, BOOT_A);
        assert_eq!(
            store.sync(VALID_EPOCH_MS + 50_000).unwrap(),
            SyncOutcome::AlreadySynced
        );
        let second = read_record(&dir.path, BOOT_A);

        assert_eq!(second, first);
    }

    #[test]
    fn required_mountpoint_rejects_plain_dir_without_creating_time_record() {
        let rec_dir = TempDir::new("time-store-required-mount");
        let time_dir = rec_dir.path.join("time");
        let store =
            TimeStore::load(time_dir.clone()).with_required_mountpoint(rec_dir.path.clone());
        store.set_boot_id(BOOT_A);

        let error = store.sync(VALID_EPOCH_MS).unwrap_err();

        assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
        let message = error.to_string();
        assert!(message.contains("not a mounted filesystem"), "{message}");
        assert!(message.contains("findmnt"), "{message}");
        assert!(!time_dir.exists());
        assert!(!time_dir.join(format!("{BOOT_A}.json")).exists());
    }

    #[test]
    fn concurrent_first_syncs_leave_one_offset_file() {
        let dir = TempDir::new("time-store-concurrent");
        let store = Arc::new(TimeStore::load(dir.path.clone()));
        store.set_boot_id(BOOT_A);
        let barrier = Arc::new(Barrier::new(8));

        let handles = (0..8)
            .map(|index| {
                let store = store.clone();
                let barrier = barrier.clone();
                thread::spawn(move || {
                    barrier.wait();
                    store.sync(VALID_EPOCH_MS + index).unwrap()
                })
            })
            .collect::<Vec<_>>();
        let outcomes = handles
            .into_iter()
            .map(|handle| handle.join().unwrap())
            .collect::<Vec<_>>();

        assert_eq!(
            outcomes
                .iter()
                .filter(|outcome| **outcome == SyncOutcome::Recorded)
                .count(),
            1
        );
        let files = fs::read_dir(&dir.path)
            .unwrap()
            .flatten()
            .collect::<Vec<_>>();
        assert_eq!(files.len(), 1);
        let expected_name = format!("{BOOT_A}.json");
        assert_eq!(files[0].file_name().to_str(), Some(expected_name.as_str()));
    }

    #[test]
    fn ambiguous_boottag_resolves_to_none() {
        let dir = TempDir::new("time-store-ambiguous");
        write_record(&dir.path, BOOT_A, 1000);
        write_record(&dir.path, BOOT_A_COLLISION, 2000);

        let store = TimeStore::load(dir.path.clone());

        assert_eq!(store.offset_for_tag("aaaaaaaaaaaa"), None);
    }

    #[test]
    fn derived_wall_now_requires_current_boot_sync() {
        let store = TimeStore::in_memory();
        store.set_boot_id(BOOT_A);
        assert_eq!(store.derived_wall_now_ms(), None);

        store.sync(VALID_EPOCH_MS).unwrap();

        assert!(store.derived_wall_now_ms().is_some());
    }

    #[test]
    fn offset_lookup_keys_by_segment_boottag() {
        let dir = TempDir::new("time-store-tags");
        write_record(&dir.path, BOOT_A, 111);
        write_record(&dir.path, BOOT_B, 222);

        let store = TimeStore::load(dir.path.clone());
        store.set_boot_id(BOOT_B);

        assert_eq!(store.offset_for_tag("aaaaaaaaaaaa"), Some(111));
        assert_eq!(store.offset_for_tag("bbbbbbbbbbbb"), Some(222));
    }

    fn write_record(dir: &std::path::Path, boot_id: &str, offset_ms: i64) {
        fs::create_dir_all(dir).unwrap();
        let record = OffsetRecord {
            boot_id: boot_id.to_string(),
            offset_ms,
            source: "app".to_string(),
            synced_at_mono_ms: 123,
        };
        fs::write(
            dir.join(format!("{boot_id}.json")),
            serde_json::to_vec(&record).unwrap(),
        )
        .unwrap();
    }

    fn read_record(dir: &std::path::Path, boot_id: &str) -> OffsetRecord {
        serde_json::from_slice(&fs::read(dir.join(format!("{boot_id}.json"))).unwrap()).unwrap()
    }

    struct TempDir {
        path: std::path::PathBuf,
    }

    impl TempDir {
        fn new(prefix: &str) -> Self {
            let path = std::env::temp_dir().join(format!("{prefix}-{}", uuid::Uuid::new_v4()));
            fs::create_dir(&path).unwrap();
            Self { path }
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }
}
