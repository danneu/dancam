//! Single-writer storage coordination for recording-dir mutations.
//!
//! This coordinates start-segment allocation and finished-segment deletion. Every
//! allocated start id is durably written to `state/state.json` as `high_water_seq`
//! before it is returned, and every delete raises that same witness before
//! unlinking a matching segment file.

use std::{
    fs::{self, File},
    io::{self, ErrorKind},
    os::unix::fs::MetadataExt,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};

use crate::{
    clips::{max_clip_seq, resolve_segment, segment_paths_for_id, zero_byte_repair},
    recorder::{
        parse_recording_artifact_filename, stamped_segment_filename, RecordingArtifactState,
        SegmentFacts, SegmentId,
    },
};

const STATE_DIR: &str = "state";
const STATE_FILE: &str = "state.json";
const TMP_STATE_FILE: &str = "state.json.tmp";

/// Coordinates recording-dir mutations behind one in-process mutex.
///
/// Start allocation and finished-clip delete run under the same mutation mutex.
/// Any mutation that removes files must raise the durable witness before the
/// first unlink so a removed id cannot be reissued.
#[derive(Debug)]
pub struct StorageCoordinator {
    rec_dir: Arc<Path>,
    required_mountpoint: Option<Arc<Path>>,
    mutation: Mutex<()>,
}

impl StorageCoordinator {
    pub fn new(rec_dir: PathBuf) -> Self {
        Self {
            rec_dir: Arc::from(rec_dir.into_boxed_path()),
            required_mountpoint: None,
            mutation: Mutex::new(()),
        }
    }

    pub fn with_required_mountpoint(mut self, mountpoint: PathBuf) -> Self {
        self.required_mountpoint = Some(Arc::from(mountpoint.into_boxed_path()));
        self
    }

    pub fn rec_dir(&self) -> Arc<Path> {
        self.rec_dir.clone()
    }

    pub fn required_mountpoint(&self) -> Option<Arc<Path>> {
        self.required_mountpoint.clone()
    }

    #[cfg(test)]
    pub(crate) fn lock_mutation_for_test(&self) -> std::sync::MutexGuard<'_, ()> {
        self.mutation
            .lock()
            .expect("storage coordinator mutex poisoned")
    }

    pub fn allocate_start_segment(&self) -> io::Result<SegmentId> {
        let _guard = self
            .mutation
            .lock()
            .expect("storage coordinator mutex poisoned");
        self.ensure_rec_mounted()?;
        fs::create_dir_all(self.rec_dir.as_ref())?;
        let next = next_start_segment(self.rec_dir.as_ref())?;

        update_witness(self.rec_dir.as_ref(), |witness| {
            witness.high_water_seq = next;
        })?;
        Ok(next)
    }

    pub fn validate_committed_open(&self, session: u64, id: SegmentId) -> io::Result<bool> {
        let _guard = self
            .mutation
            .lock()
            .expect("storage coordinator mutex poisoned");
        self.ensure_rec_mounted()?;
        let mut matched = false;
        for entry in match fs::read_dir(self.rec_dir.as_ref()) {
            Ok(entries) => entries,
            Err(error) if error.kind() == ErrorKind::NotFound => return Ok(false),
            Err(error) => return Err(error),
        } {
            let entry = entry?;
            let Some(name) = entry.file_name().to_str().map(str::to_owned) else {
                continue;
            };
            let Some(artifact) = parse_recording_artifact_filename(&name) else {
                continue;
            };
            if artifact.state == RecordingArtifactState::CommittedOpen
                && artifact.seq == id
                && artifact.facts.session == session
            {
                if matched || !entry.file_type()?.is_file() || entry.metadata()?.len() == 0 {
                    return Ok(false);
                }
                matched = true;
            }
        }
        Ok(matched)
    }

    pub fn validate_finalized(&self, session: u64, id: SegmentId) -> io::Result<bool> {
        let _guard = self
            .mutation
            .lock()
            .expect("storage coordinator mutex poisoned");
        self.ensure_rec_mounted()?;
        let Some(candidate) = resolve_segment(self.rec_dir.as_ref(), id)? else {
            return Ok(false);
        };
        Ok(candidate.bytes > 0
            && candidate
                .facts
                .is_some_and(|facts| facts.session == session && facts.dur_ms.is_some()))
    }

    /// Reconcile the recording directory after its owning Python process is gone.
    /// Pending artifacts were never published and are removed. Committed-open
    /// artifacts already crossed the durable publication point, so they become
    /// ordinary finalized segments even when their duration cannot be recovered.
    pub fn reconcile_recording_artifacts(&self) -> io::Result<RecordingReconcileReport> {
        let _guard = self
            .mutation
            .lock()
            .expect("storage coordinator mutex poisoned");
        self.ensure_rec_mounted()?;
        let rec_dir = self.rec_dir.as_ref();
        let entries = match fs::read_dir(rec_dir) {
            Ok(entries) => entries,
            Err(error) if error.kind() == ErrorKind::NotFound => {
                return Ok(RecordingReconcileReport::default())
            }
            Err(error) => return Err(error),
        };

        let mut artifacts = Vec::new();
        for entry in entries {
            let entry = entry?;
            let Some(name) = entry.file_name().to_str().map(str::to_owned) else {
                continue;
            };
            if let Some(artifact) = parse_recording_artifact_filename(&name) {
                artifacts.push((entry.path(), artifact));
            }
        }
        artifacts.sort_by(|left, right| left.0.cmp(&right.0));
        if let Some(max_id) = artifacts.iter().map(|(_, artifact)| artifact.seq).max() {
            raise_witness_at_least(rec_dir, max_id)?;
        }

        let mut report = RecordingReconcileReport::default();
        for (path, artifact) in artifacts {
            match artifact.state {
                RecordingArtifactState::Uncommitted => {
                    fs::remove_file(&path)?;
                    report.removed_uncommitted.push(path);
                }
                RecordingArtifactState::CommittedOpen => {
                    let destination = rec_dir.join(stamped_segment_filename(
                        artifact.seq,
                        &SegmentFacts {
                            dur_ms: None,
                            ..artifact.facts
                        },
                    ));
                    if destination.exists() {
                        return Err(io::Error::new(
                            ErrorKind::AlreadyExists,
                            format!(
                                "cannot reconcile {}: finalized destination {} already exists",
                                path.display(),
                                destination.display()
                            ),
                        ));
                    }
                    fs::rename(&path, &destination)?;
                    report.finalized.push(artifact.seq);
                }
            }
        }
        if !report.removed_uncommitted.is_empty() || !report.finalized.is_empty() {
            fsync_dir(rec_dir)?;
        }
        Ok(report)
    }

    pub fn delete_finished_segment(
        &self,
        id: SegmentId,
        live_floor: impl FnOnce() -> Option<SegmentId>,
    ) -> Result<(), SegmentDeleteError> {
        let _guard = self
            .mutation
            .lock()
            .expect("storage coordinator mutex poisoned");
        let rec_dir = self.rec_dir.as_ref();
        self.ensure_rec_mounted().map_err(SegmentDeleteError::Io)?;

        if live_floor().is_some_and(|floor| id >= floor) {
            return Err(SegmentDeleteError::NotFound);
        }

        let paths = segment_paths_for_id(rec_dir, id).map_err(SegmentDeleteError::Io)?;
        if paths.is_empty() {
            return Err(SegmentDeleteError::NotFound);
        }

        raise_witness_at_least(rec_dir, id).map_err(SegmentDeleteError::Io)?;

        for path in paths {
            remove_segment_file(&path).map_err(SegmentDeleteError::Io)?;
        }
        fsync_dir(rec_dir).map_err(SegmentDeleteError::Io)?;
        Ok(())
    }

    /// Persist a finalized segment's measured duration in its filename.
    ///
    /// Callers must only pass ids whose writer has moved on. There is deliberately
    /// no live-floor check here because finalize runs while the protective floor still
    /// equals the id being finalized.
    pub fn persist_segment_duration(
        &self,
        id: SegmentId,
        dur_ms: u64,
    ) -> io::Result<DurationPersist> {
        let _guard = self
            .mutation
            .lock()
            .expect("storage coordinator mutex poisoned");
        self.ensure_rec_mounted()?;
        let Some(candidate) = resolve_segment(self.rec_dir.as_ref(), id)? else {
            return Ok(DurationPersist::Vanished);
        };
        let Some(mut facts) = candidate.facts else {
            return Ok(DurationPersist::NoStampedPath);
        };
        if facts.dur_ms.is_some() {
            return Ok(DurationPersist::AlreadyPersisted);
        }

        facts.dur_ms = Some(dur_ms);
        let destination = self.rec_dir.join(stamped_segment_filename(id, &facts));
        match fs::rename(&candidate.path, destination) {
            Ok(()) => fsync_dir(self.rec_dir.as_ref())?,
            Err(error) if error.kind() == ErrorKind::NotFound => {
                tracing::debug!(id, "segment vanished while persisting duration");
                return Ok(DurationPersist::Vanished);
            }
            Err(error) => return Err(error),
        }
        Ok(DurationPersist::Renamed)
    }

    pub(crate) fn raise_witness_for_batch(
        &self,
        batch_max: SegmentId,
        ceiling: SegmentId,
    ) -> io::Result<()> {
        let _guard = self
            .mutation
            .lock()
            .expect("storage coordinator mutex poisoned");
        self.ensure_rec_mounted()?;
        let rec_dir = self.rec_dir.as_ref();
        if read_witness_state(rec_dir)?.is_some_and(|witness| witness.high_water_seq >= batch_max) {
            return Ok(());
        }
        raise_witness_at_least(rec_dir, ceiling)
    }

    /// Boot-time repair for unrecoverable zero-byte leftovers from power loss.
    ///
    /// Must run before any recorder session starts. The pass is idempotent: if
    /// power dies after the witness write but before unlink, the next boot sees
    /// the same zero-byte files and retries. Fully empty ids raise the high-water
    /// witness before unlink; mixed duplicate groups only remove their zero-byte
    /// paths, preserving nonzero footage and letting the surviving file define
    /// the canonical ETag.
    pub fn scrub_unrecoverable_segments(&self) -> io::Result<ScrubReport> {
        let _guard = self
            .mutation
            .lock()
            .expect("storage coordinator mutex poisoned");
        let rec_dir = self.rec_dir.as_ref();
        self.ensure_rec_mounted()?;

        let repair = zero_byte_repair(rec_dir)?;
        if repair.fully_empty_ids.is_empty() && repair.stale_empty_paths.is_empty() {
            return Ok(ScrubReport {
                deleted_ids: Vec::new(),
                repaired_paths: Vec::new(),
            });
        }

        let mut deleted_ids = repair.fully_empty_ids;
        deleted_ids.sort_unstable();
        let mut repaired_paths = repair.stale_empty_paths;
        repaired_paths.sort();

        if let Some(max_deleted) = deleted_ids.iter().copied().max() {
            raise_witness_at_least(rec_dir, max_deleted)?;
        }

        for id in &deleted_ids {
            for path in segment_paths_for_id(rec_dir, *id)? {
                fs::remove_file(path)?;
            }
        }
        for path in &repaired_paths {
            fs::remove_file(path)?;
        }
        fsync_dir(rec_dir)?;

        Ok(ScrubReport {
            deleted_ids,
            repaired_paths,
        })
    }

    fn ensure_rec_mounted(&self) -> io::Result<()> {
        if let Some(mountpoint) = &self.required_mountpoint {
            ensure_required_mountpoint(mountpoint.as_ref())?;
        }
        Ok(())
    }

    /// Read-only form of the authoritative recording mount witness used by
    /// mutations. An unconfigured witness succeeds by definition.
    pub fn recording_storage_available(&self) -> io::Result<()> {
        self.ensure_rec_mounted()
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DurationPersist {
    Renamed,
    AlreadyPersisted,
    NoStampedPath,
    Vanished,
}

#[derive(Debug, PartialEq, Eq)]
pub struct ScrubReport {
    pub deleted_ids: Vec<SegmentId>,
    pub repaired_paths: Vec<PathBuf>,
}

#[derive(Debug, Default, PartialEq, Eq)]
pub struct RecordingReconcileReport {
    pub removed_uncommitted: Vec<PathBuf>,
    pub finalized: Vec<SegmentId>,
}

#[derive(Debug)]
pub enum SegmentDeleteError {
    NotFound,
    Io(io::Error),
}

pub fn ensure_required_mountpoint(mountpoint: &Path) -> io::Result<()> {
    if !mountpoint.is_absolute() {
        return Err(mount_witness_error(
            mountpoint,
            "required mountpoint path must be absolute",
        ));
    }

    let metadata = fs::metadata(mountpoint)
        .map_err(|error| mount_witness_error(mountpoint, format!("failed to stat: {error}")))?;
    if !metadata.is_dir() {
        return Err(mount_witness_error(mountpoint, "path is not a directory"));
    }

    let parent = mountpoint.parent().unwrap_or(mountpoint);
    let parent_metadata = fs::metadata(parent).map_err(|error| {
        mount_witness_error(
            mountpoint,
            format!("failed to stat parent {}: {error}", parent.display()),
        )
    })?;
    if metadata.dev() != parent_metadata.dev() || metadata.ino() == parent_metadata.ino() {
        return Ok(());
    }

    Err(mount_witness_error(mountpoint, "same device as its parent"))
}

fn mount_witness_error(mountpoint: &Path, detail: impl std::fmt::Display) -> io::Error {
    io::Error::new(
        ErrorKind::InvalidData,
        format!(
            "{} is not a mounted filesystem for recordings ({detail}); check 'findmnt {}', /etc/fstab, and dmesg before retrying.",
            mountpoint.display(),
            mountpoint.display()
        ),
    )
}

fn next_start_segment(rec_dir: &Path) -> io::Result<SegmentId> {
    let witness = read_witness_state(rec_dir)?.map(|state| state.high_water_seq);
    let scanned = max_clip_seq(rec_dir)?;
    match witness.into_iter().chain(scanned).max() {
        // Fail closed at the ceiling rather than reissuing `u32::MAX` (which would mint a
        // same-seq stamped twin and, via `start_segment + 1`, reissue the session). The
        // storage design requires allocation to stay strictly monotonic and never repeat
        // an id. `u32::MAX` itself is the last legal reservation; the *next* start fails.
        Some(seq) if seq == SegmentId::MAX => Err(segment_ceiling_error()),
        Some(seq) => Ok(seq + 1),
        None => Ok(0),
    }
}

fn segment_ceiling_error() -> io::Error {
    io::Error::new(
        ErrorKind::InvalidData,
        "segment id space exhausted: high-water is u32::MAX, so start allocation would reissue an id; recorder stays idle.",
    )
}

#[derive(serde::Serialize, serde::Deserialize)]
struct StateWitness {
    high_water_seq: SegmentId,
    #[serde(flatten)]
    extra: serde_json::Map<String, serde_json::Value>,
}

fn read_witness_state(rec_dir: &Path) -> io::Result<Option<StateWitness>> {
    let path = state_path(rec_dir);
    let bytes = match fs::read(&path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(corrupt_witness_error(&path, error)),
    };
    let state: StateWitness =
        serde_json::from_slice(&bytes).map_err(|error| corrupt_witness_error(&path, error))?;

    Ok(Some(state))
}

fn update_witness(rec_dir: &Path, mutate: impl FnOnce(&mut StateWitness)) -> io::Result<()> {
    let mut state = read_witness_state(rec_dir)?.unwrap_or_else(|| StateWitness {
        high_water_seq: 0,
        extra: serde_json::Map::new(),
    });
    mutate(&mut state);

    let state_dir = rec_dir.join(STATE_DIR);
    fs::create_dir_all(&state_dir)?;
    fsync_dir(rec_dir)?;

    let tmp_path = state_dir.join(TMP_STATE_FILE);
    let final_path = state_dir.join(STATE_FILE);
    let file = File::create(&tmp_path)?;
    serde_json::to_writer(&file, &state)?;
    file.sync_all()?;
    drop(file);

    fs::rename(&tmp_path, &final_path)?;
    fsync_dir(&state_dir)?;
    Ok(())
}

/// Write-ahead raise: durably ensure high_water_seq >= floor before any unlink.
/// No-ops (no write, no fsync) when the committed witness already covers it --
/// GC deletes oldest ids, so at steady state this saves an fsync per eviction.
fn raise_witness_at_least(rec_dir: &Path, floor: SegmentId) -> io::Result<()> {
    if read_witness_state(rec_dir)?.is_some_and(|witness| witness.high_water_seq >= floor) {
        return Ok(());
    }

    update_witness(rec_dir, |witness| {
        witness.high_water_seq = witness.high_water_seq.max(floor);
    })
}

fn remove_segment_file(path: &Path) -> io::Result<()> {
    #[cfg(test)]
    if fail_unlink_now() {
        return Err(io::Error::other("injected segment unlink failure"));
    }
    fs::remove_file(path)
}

#[cfg(test)]
thread_local! {
    static FAIL_UNLINK_AFTER: std::cell::Cell<Option<usize>> = const { std::cell::Cell::new(None) };
}

#[cfg(test)]
fn fail_unlink_now() -> bool {
    FAIL_UNLINK_AFTER.with(|counter| match counter.get() {
        Some(1) => {
            counter.set(None);
            true
        }
        Some(n) => {
            counter.set(Some(n - 1));
            false
        }
        None => false,
    })
}

fn fsync_dir(dir: &Path) -> io::Result<()> {
    File::open(dir)?.sync_all()
}

fn state_path(rec_dir: &Path) -> PathBuf {
    rec_dir.join(STATE_DIR).join(STATE_FILE)
}

fn corrupt_witness_error(path: &Path, source: impl std::fmt::Display) -> io::Error {
    io::Error::new(
        ErrorKind::InvalidData,
        format!(
            "{} is corrupt or unreadable ({source}); delete state.json to recover. Footage is untouched; only the segment id floor is lost.",
            path.display()
        ),
    )
}

#[cfg(test)]
mod tests {
    use std::{
        collections::HashSet,
        fs,
        os::unix::fs::PermissionsExt,
        path::{Path, PathBuf},
        sync::{Arc, Barrier},
        thread,
    };

    use super::{state_path, DurationPersist, SegmentDeleteError, StorageCoordinator, STATE_DIR};
    use crate::{
        clips::resolve_segment,
        recorder::{
            recording_artifact_filename, segment_filename, stamped_segment_filename,
            RecordingArtifactState, SegmentFacts, SegmentId,
        },
    };

    #[test]
    fn absent_witness_allocates_from_empty_dir_and_file_scan() {
        let rec_dir = TempRecDir::new();
        let coordinator = StorageCoordinator::new(rec_dir.path.clone());

        assert_eq!(coordinator.allocate_start_segment().unwrap(), 0);
        assert_eq!(read_high_water_seq(&rec_dir.path), 0);

        write_segment(&rec_dir.path, 5);
        assert_eq!(coordinator.allocate_start_segment().unwrap(), 6);
        assert_eq!(read_high_water_seq(&rec_dir.path), 6);
    }

    #[test]
    fn reconciliation_removes_uncommitted_and_finalizes_committed_open() {
        let rec_dir = TempRecDir::new();
        let pending_facts = SegmentFacts {
            boot_tag: "abc123def456".to_string(),
            session: 5,
            mono_ms: 100,
            dur_ms: None,
        };
        let open_facts = SegmentFacts {
            session: 6,
            mono_ms: 200,
            ..pending_facts.clone()
        };
        let pending = rec_dir.path.join(recording_artifact_filename(
            RecordingArtifactState::Uncommitted,
            4,
            &pending_facts,
        ));
        let open = rec_dir.path.join(recording_artifact_filename(
            RecordingArtifactState::CommittedOpen,
            5,
            &open_facts,
        ));
        fs::write(&pending, b"not published").unwrap();
        fs::write(&open, b"durable media").unwrap();
        let coordinator = StorageCoordinator::new(rec_dir.path.clone());

        let report = coordinator.reconcile_recording_artifacts().unwrap();

        assert_eq!(report.removed_uncommitted, [pending]);
        assert_eq!(report.finalized, [5]);
        assert!(!open.exists());
        let finalized = rec_dir.path.join(stamped_segment_filename(5, &open_facts));
        assert_eq!(fs::read(finalized).unwrap(), b"durable media");
        assert!(read_high_water_seq(&rec_dir.path) >= 5);
        assert_eq!(coordinator.allocate_start_segment().unwrap(), 6);
        assert_eq!(
            coordinator.reconcile_recording_artifacts().unwrap(),
            super::RecordingReconcileReport::default()
        );
    }

    #[test]
    fn committed_open_validation_requires_exact_session_and_nonempty_bytes() {
        let rec_dir = TempRecDir::new();
        let facts = SegmentFacts {
            boot_tag: "abc123def456".to_string(),
            session: 9,
            mono_ms: 100,
            dur_ms: None,
        };
        let path = rec_dir.path.join(recording_artifact_filename(
            RecordingArtifactState::CommittedOpen,
            8,
            &facts,
        ));
        fs::write(&path, b"").unwrap();
        let coordinator = StorageCoordinator::new(rec_dir.path.clone());

        assert!(!coordinator.validate_committed_open(9, 8).unwrap());
        fs::write(path, b"durable").unwrap();
        assert!(coordinator.validate_committed_open(9, 8).unwrap());
        assert!(!coordinator.validate_committed_open(10, 8).unwrap());
        assert!(!coordinator.validate_committed_open(9, 7).unwrap());
    }

    #[test]
    fn absent_rec_dir_is_created_by_the_coordinator() {
        let root = TempRecDir::new();
        let rec_dir = root.path.join("rec");
        let coordinator = StorageCoordinator::new(rec_dir.clone());

        assert_eq!(coordinator.allocate_start_segment().unwrap(), 0);
        assert!(rec_dir.is_dir());
        assert_eq!(read_high_water_seq(&rec_dir), 0);
    }

    #[test]
    fn required_mountpoint_rejects_plain_dir_without_creating_rec_dir() {
        let mountpoint = TempRecDir::new();
        let rec_dir = mountpoint.path.join("rec");
        let coordinator = StorageCoordinator::new(rec_dir.clone())
            .with_required_mountpoint(mountpoint.path.clone());

        let error = coordinator.allocate_start_segment().unwrap_err();

        assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
        let message = error.to_string();
        assert!(message.contains("not a mounted filesystem"), "{message}");
        assert!(message.contains("findmnt"), "{message}");
        assert!(!rec_dir.exists());
        assert!(!state_path(&rec_dir).exists());
    }

    #[test]
    fn root_required_mountpoint_allows_allocation() {
        let root = TempRecDir::new();
        let rec_dir = root.path.join("rec");
        let coordinator =
            StorageCoordinator::new(rec_dir.clone()).with_required_mountpoint(PathBuf::from("/"));

        assert_eq!(coordinator.allocate_start_segment().unwrap(), 0);
        assert!(rec_dir.is_dir());
        assert_eq!(read_high_water_seq(&rec_dir), 0);
    }

    #[test]
    fn absent_witness_with_existing_files_allocates_after_the_scan() {
        let rec_dir = TempRecDir::new();
        write_segment(&rec_dir.path, 5);

        let coordinator = StorageCoordinator::new(rec_dir.path.clone());

        assert_eq!(coordinator.allocate_start_segment().unwrap(), 6);
        assert_eq!(read_high_water_seq(&rec_dir.path), 6);
    }

    #[test]
    fn valid_witness_above_files_wins() {
        let rec_dir = TempRecDir::new();
        write_witness(&rec_dir.path, 10);
        write_segment(&rec_dir.path, 5);

        let coordinator = StorageCoordinator::new(rec_dir.path.clone());

        assert_eq!(coordinator.allocate_start_segment().unwrap(), 11);
        assert_eq!(read_high_water_seq(&rec_dir.path), 11);
    }

    #[test]
    fn intact_witness_keeps_deleted_highest_segment_from_reusing_ids() {
        let rec_dir = TempRecDir::new();
        write_segment(&rec_dir.path, 7);
        let coordinator = StorageCoordinator::new(rec_dir.path.clone());

        assert_eq!(coordinator.allocate_start_segment().unwrap(), 8);
        fs::remove_file(rec_dir.path.join(segment_filename(7))).unwrap();

        assert_eq!(coordinator.allocate_start_segment().unwrap(), 9);
        assert_eq!(read_high_water_seq(&rec_dir.path), 9);
    }

    #[test]
    fn delete_raises_witness_and_prevents_id_reuse() {
        let rec_dir = TempRecDir::new();
        for seq in 0..=2 {
            write_segment(&rec_dir.path, seq);
        }
        let coordinator = StorageCoordinator::new(rec_dir.path.clone());

        coordinator.delete_finished_segment(2, || None).unwrap();

        assert!(!rec_dir.path.join(segment_filename(2)).exists());
        assert!(read_high_water_seq(&rec_dir.path) >= 2);
        assert!(coordinator.allocate_start_segment().unwrap() >= 3);
    }

    #[test]
    fn delete_below_witness_skips_rewrite() {
        let rec_dir = TempRecDir::new();
        write_witness(&rec_dir.path, 9);
        write_segment(&rec_dir.path, 2);
        let coordinator = StorageCoordinator::new(rec_dir.path.clone());
        let state_dir = rec_dir.path.join(STATE_DIR);
        let original_permissions = fs::metadata(&state_dir).unwrap().permissions();
        fs::set_permissions(&state_dir, fs::Permissions::from_mode(0o555)).unwrap();

        let result = coordinator.delete_finished_segment(2, || None);

        fs::set_permissions(&state_dir, original_permissions).unwrap();
        result.unwrap();
        assert!(!rec_dir.path.join(segment_filename(2)).exists());
        assert_eq!(read_high_water_seq(&rec_dir.path), 9);
        assert_eq!(coordinator.allocate_start_segment().unwrap(), 10);
    }

    #[test]
    fn gc_style_delete_of_highest_remaining_id_prevents_reuse() {
        let rec_dir = TempRecDir::new();
        for seq in 0..=3 {
            write_segment(&rec_dir.path, seq);
        }
        let coordinator = StorageCoordinator::new(rec_dir.path.clone());

        for seq in (0..=3).rev() {
            coordinator.delete_finished_segment(seq, || None).unwrap();
        }

        for seq in 0..=3 {
            assert!(!rec_dir.path.join(segment_filename(seq)).exists());
        }
        assert_eq!(coordinator.allocate_start_segment().unwrap(), 4);
    }

    #[test]
    fn scrub_removes_zero_byte_segment_and_prevents_id_reuse() {
        let rec_dir = TempRecDir::new();
        write_segment(&rec_dir.path, 3);
        write_empty_segment(&rec_dir.path, 4);
        let coordinator = StorageCoordinator::new(rec_dir.path.clone());

        let report = coordinator.scrub_unrecoverable_segments().unwrap();

        assert_eq!(report.deleted_ids, [4]);
        assert!(report.repaired_paths.is_empty());
        assert!(!rec_dir.path.join(segment_filename(4)).exists());
        assert!(rec_dir.path.join(segment_filename(3)).exists());
        assert!(read_high_water_seq(&rec_dir.path) >= 4);
        assert_eq!(coordinator.allocate_start_segment().unwrap(), 5);
    }

    #[test]
    fn scrub_multiple_zero_byte_segments_raises_witness_to_max_before_unlink() {
        let rec_dir = TempRecDir::new();
        write_empty_segment(&rec_dir.path, 2);
        write_segment(&rec_dir.path, 4);
        write_empty_segment(&rec_dir.path, 6);
        let coordinator = StorageCoordinator::new(rec_dir.path.clone());

        let report = coordinator.scrub_unrecoverable_segments().unwrap();

        assert_eq!(report.deleted_ids, [2, 6]);
        assert!(report.repaired_paths.is_empty());
        assert!(!rec_dir.path.join(segment_filename(2)).exists());
        assert!(!rec_dir.path.join(segment_filename(6)).exists());
        assert!(rec_dir.path.join(segment_filename(4)).exists());
        assert!(read_high_water_seq(&rec_dir.path) >= 6);
        assert_eq!(coordinator.allocate_start_segment().unwrap(), 7);
    }

    #[test]
    fn scrub_deletes_all_paths_for_an_all_empty_id() {
        let rec_dir = TempRecDir::new();
        let bare = rec_dir.path.join(segment_filename(4));
        let stamped = rec_dir.path.join(stamped_name(4));
        write_empty_segment(&rec_dir.path, 4);
        write_empty_stamped_segment(&rec_dir.path, 4);
        let coordinator = StorageCoordinator::new(rec_dir.path.clone());

        let report = coordinator.scrub_unrecoverable_segments().unwrap();

        assert_eq!(report.deleted_ids, [4]);
        assert!(report.repaired_paths.is_empty());
        assert!(!bare.exists());
        assert!(!stamped.exists());
        assert!(read_high_water_seq(&rec_dir.path) >= 4);
    }

    #[test]
    fn scrub_preserves_nonzero_bytes_in_mixed_duplicate_group() {
        let rec_dir = TempRecDir::new();
        write_segment(&rec_dir.path, 3);
        write_segment(&rec_dir.path, 4);
        let stamped = rec_dir.path.join(stamped_name(4));
        write_empty_stamped_segment(&rec_dir.path, 4);
        let coordinator = StorageCoordinator::new(rec_dir.path.clone());

        let report = coordinator.scrub_unrecoverable_segments().unwrap();

        assert!(report.deleted_ids.is_empty());
        assert_eq!(
            report.repaired_paths.as_slice(),
            std::slice::from_ref(&stamped)
        );
        assert!(rec_dir.path.join(segment_filename(4)).exists());
        assert!(!stamped.exists());
        let segment = resolve_segment(&rec_dir.path, 4).unwrap().unwrap();
        assert_eq!(segment.bytes, 7);
        assert_eq!(
            segment.path.file_name().unwrap(),
            segment_filename(4).as_str()
        );
        assert!(!state_path(&rec_dir.path).exists());
        assert_eq!(coordinator.allocate_start_segment().unwrap(), 5);
    }

    #[test]
    fn scrub_leaves_segment_with_healthy_stamped_canonical() {
        let rec_dir = TempRecDir::new();
        write_segment(&rec_dir.path, 4);
        write_stamped_segment(&rec_dir.path, 4);
        let coordinator = StorageCoordinator::new(rec_dir.path.clone());

        let report = coordinator.scrub_unrecoverable_segments().unwrap();

        assert!(report.deleted_ids.is_empty());
        assert!(report.repaired_paths.is_empty());
        assert!(rec_dir.path.join(segment_filename(4)).exists());
        assert!(rec_dir.path.join(stamped_name(4)).exists());
        assert!(!state_path(&rec_dir.path).exists());
    }

    #[test]
    fn scrub_noop_leaves_witness_untouched() {
        let rec_dir = TempRecDir::new();
        let coordinator = StorageCoordinator::new(rec_dir.path.clone());

        let report = coordinator.scrub_unrecoverable_segments().unwrap();

        assert!(report.deleted_ids.is_empty());
        assert!(report.repaired_paths.is_empty());
        assert!(!state_path(&rec_dir.path).exists());

        let missing = rec_dir.path.join("missing");
        let missing_coordinator = StorageCoordinator::new(missing.clone());
        let missing_report = missing_coordinator.scrub_unrecoverable_segments().unwrap();

        assert!(missing_report.deleted_ids.is_empty());
        assert!(missing_report.repaired_paths.is_empty());
        assert!(!missing.exists());
        assert!(!state_path(&missing).exists());
    }

    #[test]
    fn scrub_fails_closed_on_corrupt_witness() {
        let rec_dir = TempRecDir::new();
        write_empty_segment(&rec_dir.path, 4);
        write_raw_witness(&rec_dir.path, "not json");
        let coordinator = StorageCoordinator::new(rec_dir.path.clone());

        let error = coordinator.scrub_unrecoverable_segments().unwrap_err();

        assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
        assert!(rec_dir.path.join(segment_filename(4)).exists());
        assert_eq!(
            fs::read_to_string(state_path(&rec_dir.path)).unwrap(),
            "not json"
        );
    }

    #[test]
    fn scrub_fails_closed_when_required_mountpoint_is_plain_dir() {
        let mountpoint = TempRecDir::new();
        let rec_dir = mountpoint.path.join("rec");
        write_empty_segment(&rec_dir, 4);
        let coordinator = StorageCoordinator::new(rec_dir.clone())
            .with_required_mountpoint(mountpoint.path.clone());

        let error = coordinator.scrub_unrecoverable_segments().unwrap_err();

        assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
        let message = error.to_string();
        assert!(message.contains("not a mounted filesystem"), "{message}");
        assert!(message.contains("findmnt"), "{message}");
        assert!(rec_dir.join(segment_filename(4)).exists());
        assert!(!state_path(&rec_dir).exists());
    }

    #[test]
    fn scrub_is_idempotent_after_witness_only_crash() {
        let rec_dir = TempRecDir::new();
        write_witness(&rec_dir.path, 9);
        write_empty_segment(&rec_dir.path, 4);
        let coordinator = StorageCoordinator::new(rec_dir.path.clone());

        let report = coordinator.scrub_unrecoverable_segments().unwrap();

        assert_eq!(report.deleted_ids, [4]);
        assert!(report.repaired_paths.is_empty());
        assert!(!rec_dir.path.join(segment_filename(4)).exists());
        assert_eq!(read_high_water_seq(&rec_dir.path), 9);
    }

    #[test]
    fn scrub_below_witness_skips_rewrite() {
        let rec_dir = TempRecDir::new();
        write_witness(&rec_dir.path, 9);
        write_empty_segment(&rec_dir.path, 2);
        let coordinator = StorageCoordinator::new(rec_dir.path.clone());
        let state_dir = rec_dir.path.join(STATE_DIR);
        let original_permissions = fs::metadata(&state_dir).unwrap().permissions();
        fs::set_permissions(&state_dir, fs::Permissions::from_mode(0o555)).unwrap();

        let result = coordinator.scrub_unrecoverable_segments();

        fs::set_permissions(&state_dir, original_permissions).unwrap();
        let report = result.unwrap();
        assert_eq!(report.deleted_ids, [2]);
        assert!(!rec_dir.path.join(segment_filename(2)).exists());
        assert_eq!(read_high_water_seq(&rec_dir.path), 9);
    }

    #[test]
    fn corrupt_witness_fails_delete_before_unlinking() {
        for body in [
            "not json",
            "{}",
            r#"{"high_water_seq":"7"}"#,
            r#"{"high_water_seq":-1}"#,
        ] {
            let rec_dir = TempRecDir::new();
            write_segment(&rec_dir.path, 2);
            write_raw_witness(&rec_dir.path, body);
            let coordinator = StorageCoordinator::new(rec_dir.path.clone());

            let error = coordinator.delete_finished_segment(2, || None).unwrap_err();

            match error {
                SegmentDeleteError::Io(error) => {
                    assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
                }
                SegmentDeleteError::NotFound => panic!("corrupt witness must be an IO error"),
            }
            assert!(rec_dir.path.join(segment_filename(2)).exists());
            assert_eq!(fs::read_to_string(state_path(&rec_dir.path)).unwrap(), body);
        }
    }

    #[test]
    fn required_mountpoint_fails_delete_before_unlink_or_witness() {
        let mountpoint = TempRecDir::new();
        let rec_dir = mountpoint.path.join("rec");
        write_segment(&rec_dir, 2);
        let coordinator = StorageCoordinator::new(rec_dir.clone())
            .with_required_mountpoint(mountpoint.path.clone());

        let error = coordinator.delete_finished_segment(2, || None).unwrap_err();

        match error {
            SegmentDeleteError::Io(error) => {
                assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
                let message = error.to_string();
                assert!(message.contains("not a mounted filesystem"), "{message}");
                assert!(message.contains("findmnt"), "{message}");
            }
            SegmentDeleteError::NotFound => panic!("mount witness failure must be an IO error"),
        }
        assert!(rec_dir.join(segment_filename(2)).exists());
        assert!(!state_path(&rec_dir).exists());
    }

    #[test]
    fn hand_written_witness_allocates_in_an_empty_dir() {
        let rec_dir = TempRecDir::new();
        write_witness(&rec_dir.path, 42);
        let coordinator = StorageCoordinator::new(rec_dir.path.clone());

        assert_eq!(coordinator.allocate_start_segment().unwrap(), 43);
        assert_eq!(read_high_water_seq(&rec_dir.path), 43);
    }

    #[test]
    fn corrupt_witness_fails_closed() {
        for body in [
            "not json",
            "{}",
            r#"{"high_water_seq":"7"}"#,
            r#"{"high_water_seq":-1}"#,
        ] {
            let rec_dir = TempRecDir::new();
            write_raw_witness(&rec_dir.path, body);
            let coordinator = StorageCoordinator::new(rec_dir.path.clone());

            let error = coordinator.allocate_start_segment().unwrap_err();

            assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
            let message = error.to_string();
            assert!(message.contains("state/state.json"), "{message}");
            assert!(message.contains("delete state.json"), "{message}");
        }
    }

    #[test]
    fn witness_tolerates_unknown_extra_keys() {
        let rec_dir = TempRecDir::new();
        write_raw_witness(&rec_dir.path, r#"{"high_water_seq":10,"future":true}"#);
        let coordinator = StorageCoordinator::new(rec_dir.path.clone());

        assert_eq!(coordinator.allocate_start_segment().unwrap(), 11);
        assert_eq!(read_high_water_seq(&rec_dir.path), 11);
    }

    #[test]
    fn witness_writer_preserves_unknown_fields_on_reserve() {
        let rec_dir = TempRecDir::new();
        write_raw_witness(&rec_dir.path, r#"{"high_water_seq":10,"future":true}"#);
        let coordinator = StorageCoordinator::new(rec_dir.path.clone());

        assert_eq!(coordinator.allocate_start_segment().unwrap(), 11);

        let witness = read_witness_json(&rec_dir.path);
        assert_eq!(witness["high_water_seq"], 11);
        assert_eq!(witness["future"], true);
    }

    #[test]
    fn witness_writer_preserves_unknown_fields_on_delete() {
        let rec_dir = TempRecDir::new();
        write_segment(&rec_dir.path, 12);
        write_raw_witness(&rec_dir.path, r#"{"high_water_seq":10,"future":true}"#);
        let coordinator = StorageCoordinator::new(rec_dir.path.clone());

        coordinator.delete_finished_segment(12, || None).unwrap();

        let witness = read_witness_json(&rec_dir.path);
        assert_eq!(witness["high_water_seq"], 12);
        assert_eq!(witness["future"], true);
    }

    #[test]
    fn witness_writer_preserves_unknown_fields_on_scrub() {
        let rec_dir = TempRecDir::new();
        write_empty_segment(&rec_dir.path, 12);
        write_raw_witness(&rec_dir.path, r#"{"high_water_seq":10,"future":true}"#);
        let coordinator = StorageCoordinator::new(rec_dir.path.clone());

        coordinator.scrub_unrecoverable_segments().unwrap();

        let witness = read_witness_json(&rec_dir.path);
        assert_eq!(witness["high_water_seq"], 12);
        assert_eq!(witness["future"], true);
    }

    #[test]
    fn sequential_and_concurrent_allocations_are_serialized() {
        let rec_dir = TempRecDir::new();
        let coordinator = Arc::new(StorageCoordinator::new(rec_dir.path.clone()));

        assert_eq!(coordinator.allocate_start_segment().unwrap(), 0);
        assert_eq!(coordinator.allocate_start_segment().unwrap(), 1);

        let barrier = Arc::new(Barrier::new(8));
        let mut ids = Vec::new();
        thread::scope(|scope| {
            let handles = (0..8)
                .map(|_| {
                    let coordinator = coordinator.clone();
                    let barrier = barrier.clone();
                    scope.spawn(move || {
                        barrier.wait();
                        coordinator.allocate_start_segment().unwrap()
                    })
                })
                .collect::<Vec<_>>();

            for handle in handles {
                ids.push(handle.join().unwrap());
            }
        });

        let unique = ids.iter().copied().collect::<HashSet<_>>();
        assert_eq!(unique.len(), ids.len());
        assert_eq!(
            read_high_water_seq(&rec_dir.path),
            *ids.iter().max().unwrap()
        );
    }

    #[test]
    fn witness_survives_restart_without_segment_files() {
        let rec_dir = TempRecDir::new();

        let coordinator = StorageCoordinator::new(rec_dir.path.clone());
        assert_eq!(coordinator.allocate_start_segment().unwrap(), 0);
        drop(coordinator);

        let restarted = StorageCoordinator::new(rec_dir.path.clone());
        assert_eq!(restarted.allocate_start_segment().unwrap(), 1);
        assert_eq!(read_high_water_seq(&rec_dir.path), 1);
    }

    #[test]
    fn allocate_fails_closed_when_witness_is_at_the_u32_ceiling() {
        let rec_dir = TempRecDir::new();
        write_witness(&rec_dir.path, SegmentId::MAX);
        let coordinator = StorageCoordinator::new(rec_dir.path.clone());

        let error = coordinator.allocate_start_segment().unwrap_err();

        assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
        assert!(error.to_string().contains("exhausted"), "{error}");
    }

    #[test]
    fn allocate_fails_closed_when_scan_max_is_at_the_u32_ceiling() {
        let rec_dir = TempRecDir::new();
        write_segment(&rec_dir.path, SegmentId::MAX);
        let coordinator = StorageCoordinator::new(rec_dir.path.clone());

        let error = coordinator.allocate_start_segment().unwrap_err();

        assert_eq!(error.kind(), std::io::ErrorKind::InvalidData);
    }

    #[test]
    fn allocate_yields_the_last_legal_id_then_fails_closed() {
        let rec_dir = TempRecDir::new();
        write_witness(&rec_dir.path, SegmentId::MAX - 1);
        let coordinator = StorageCoordinator::new(rec_dir.path.clone());

        assert_eq!(
            coordinator.allocate_start_segment().unwrap(),
            SegmentId::MAX
        );
        assert_eq!(read_high_water_seq(&rec_dir.path), SegmentId::MAX);
        assert!(coordinator.allocate_start_segment().is_err());
    }

    #[test]
    fn leftover_tmp_witness_garbage_is_inert() {
        let rec_dir = TempRecDir::new();
        write_raw_tmp_witness(&rec_dir.path, "not json");
        let coordinator = StorageCoordinator::new(rec_dir.path.clone());

        assert_eq!(coordinator.allocate_start_segment().unwrap(), 0);
        assert_eq!(read_high_water_seq(&rec_dir.path), 0);
    }

    #[test]
    fn leftover_tmp_witness_does_not_raise_the_id() {
        let rec_dir = TempRecDir::new();
        write_witness(&rec_dir.path, 3);
        write_raw_tmp_witness(&rec_dir.path, r#"{"high_water_seq":99}"#);
        let coordinator = StorageCoordinator::new(rec_dir.path.clone());

        assert_eq!(coordinator.allocate_start_segment().unwrap(), 4);
        assert_eq!(read_high_water_seq(&rec_dir.path), 4);
    }

    #[test]
    fn raise_witness_for_batch_jumps_to_ceiling_when_below() {
        let rec_dir = TempRecDir::new();
        write_witness(&rec_dir.path, 0);
        let coordinator = StorageCoordinator::new(rec_dir.path.clone());

        coordinator.raise_witness_for_batch(3, 20).unwrap();

        assert_eq!(read_high_water_seq(&rec_dir.path), 20);
        assert_eq!(coordinator.allocate_start_segment().unwrap(), 21);
    }

    #[test]
    fn raise_witness_for_batch_fails_closed_on_corrupt_witness() {
        let rec_dir = TempRecDir::new();
        write_raw_witness(&rec_dir.path, "garbage");
        let coordinator = StorageCoordinator::new(rec_dir.path.clone());

        assert_eq!(
            coordinator
                .raise_witness_for_batch(3, 20)
                .unwrap_err()
                .kind(),
            std::io::ErrorKind::InvalidData
        );
    }

    #[test]
    fn raise_witness_for_batch_fails_closed_on_missing_mount() {
        let rec_dir = TempRecDir::new();
        let mount = TempRecDir::new();
        let coordinator = StorageCoordinator::new(rec_dir.path.clone())
            .with_required_mountpoint(mount.path.clone());

        assert_eq!(
            coordinator
                .raise_witness_for_batch(3, 20)
                .unwrap_err()
                .kind(),
            std::io::ErrorKind::InvalidData
        );
        assert!(!state_path(&rec_dir.path).exists());
    }

    #[test]
    fn persist_segment_duration_renames_idempotently_and_handles_missing_forms() {
        let rec_dir = TempRecDir::new();
        write_stamped_segment(&rec_dir.path, 7);
        let coordinator = StorageCoordinator::new(rec_dir.path.clone());

        assert_eq!(
            coordinator.persist_segment_duration(7, 300).unwrap(),
            DurationPersist::Renamed
        );
        assert!(rec_dir.path.join(finalized_name(7, 300)).is_file());
        assert_eq!(
            coordinator.persist_segment_duration(7, 999).unwrap(),
            DurationPersist::AlreadyPersisted
        );
        assert_eq!(
            coordinator.persist_segment_duration(8, 300).unwrap(),
            DurationPersist::Vanished
        );
        write_segment(&rec_dir.path, 9);
        assert_eq!(
            coordinator.persist_segment_duration(9, 300).unwrap(),
            DurationPersist::NoStampedPath
        );
    }

    #[test]
    fn persist_segment_duration_prefers_existing_finalized_duplicate() {
        let rec_dir = TempRecDir::new();
        write_stamped_segment(&rec_dir.path, 7);
        fs::write(rec_dir.path.join(finalized_name(7, 400)), b"final").unwrap();
        let coordinator = StorageCoordinator::new(rec_dir.path.clone());

        assert_eq!(
            coordinator.persist_segment_duration(7, 300).unwrap(),
            DurationPersist::AlreadyPersisted
        );
        assert!(rec_dir.path.join(stamped_name(7)).is_file());
        assert!(rec_dir.path.join(finalized_name(7, 400)).is_file());
    }

    #[test]
    fn persist_segment_duration_checks_required_mount_before_rename() {
        let rec_dir = TempRecDir::new();
        let mount = TempRecDir::new();
        write_stamped_segment(&rec_dir.path, 7);
        let coordinator = StorageCoordinator::new(rec_dir.path.clone())
            .with_required_mountpoint(mount.path.clone());

        assert_eq!(
            coordinator
                .persist_segment_duration(7, 300)
                .unwrap_err()
                .kind(),
            std::io::ErrorKind::InvalidData
        );
        assert!(rec_dir.path.join(stamped_name(7)).is_file());
    }

    fn write_segment(rec_dir: &Path, seq: SegmentId) {
        write_segment_bytes(rec_dir, seq, b"segment");
    }

    fn write_empty_segment(rec_dir: &Path, seq: SegmentId) {
        write_segment_bytes(rec_dir, seq, b"");
    }

    fn write_segment_bytes(rec_dir: &Path, seq: SegmentId, bytes: &[u8]) {
        fs::create_dir_all(rec_dir).unwrap();
        fs::write(rec_dir.join(segment_filename(seq)), bytes).unwrap();
    }

    fn write_stamped_segment(rec_dir: &Path, seq: SegmentId) {
        write_stamped_segment_bytes(rec_dir, seq, b"segment");
    }

    fn write_empty_stamped_segment(rec_dir: &Path, seq: SegmentId) {
        write_stamped_segment_bytes(rec_dir, seq, b"");
    }

    fn write_stamped_segment_bytes(rec_dir: &Path, seq: SegmentId, bytes: &[u8]) {
        fs::create_dir_all(rec_dir).unwrap();
        fs::write(rec_dir.join(stamped_name(seq)), bytes).unwrap();
    }

    fn stamped_name(seq: SegmentId) -> String {
        stamped_segment_filename(
            seq,
            &SegmentFacts {
                boot_tag: "abc123def456".to_string(),
                session: 1,
                mono_ms: 123456789,
                dur_ms: None,
            },
        )
    }

    fn finalized_name(seq: SegmentId, dur_ms: u64) -> String {
        stamped_segment_filename(
            seq,
            &SegmentFacts {
                boot_tag: "abc123def456".to_string(),
                session: 1,
                mono_ms: 123456789,
                dur_ms: Some(dur_ms),
            },
        )
    }

    fn write_witness(rec_dir: &Path, high_water_seq: SegmentId) {
        write_raw_witness(
            rec_dir,
            &format!(r#"{{"high_water_seq":{high_water_seq}}}"#),
        );
    }

    fn write_raw_witness(rec_dir: &Path, body: &str) {
        let path = state_path(rec_dir);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, body).unwrap();
    }

    fn write_raw_tmp_witness(rec_dir: &Path, body: &str) {
        let state_dir = rec_dir.join("state");
        fs::create_dir_all(&state_dir).unwrap();
        fs::write(state_dir.join("state.json.tmp"), body).unwrap();
    }

    fn read_high_water_seq(rec_dir: &Path) -> SegmentId {
        read_witness_json(rec_dir)
            .get("high_water_seq")
            .unwrap()
            .as_u64()
            .unwrap()
            .try_into()
            .unwrap()
    }

    fn read_witness_json(rec_dir: &Path) -> serde_json::Value {
        let bytes = fs::read(state_path(rec_dir)).unwrap();
        serde_json::from_slice(&bytes).unwrap()
    }

    struct TempRecDir {
        path: PathBuf,
    }

    impl TempRecDir {
        fn new() -> Self {
            let path =
                std::env::temp_dir().join(format!("dancam-storage-{}", uuid::Uuid::new_v4()));
            fs::create_dir(&path).unwrap();
            Self { path }
        }
    }

    impl Drop for TempRecDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }
}
