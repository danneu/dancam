//! Single-writer storage coordination for recording-dir mutations.
//!
//! This coordinates start-segment reservation and finished-segment deletion. Every
//! reserved start id is durably written to `state/state.json` as `high_water_seq`
//! before the caller commits the recorder floor, and every delete raises that
//! same witness before unlinking a matching segment file.

use std::{
    fs::{self, File},
    io::{self, ErrorKind},
    os::unix::fs::MetadataExt,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};

use crate::{
    clips::{max_clip_seq, segment_paths_for_id, zero_byte_repair},
    recorder::SegmentId,
};

const STATE_DIR: &str = "state";
const STATE_FILE: &str = "state.json";
const TMP_STATE_FILE: &str = "state.json.tmp";

/// Coordinates recording-dir mutations behind one in-process mutex.
///
/// Start reservation and finished-clip delete run under the same mutation mutex.
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

    pub fn reserve_start_segment<R>(
        &self,
        commit: impl FnOnce(SegmentId) -> R,
    ) -> io::Result<(SegmentId, R)> {
        let _guard = self
            .mutation
            .lock()
            .expect("storage coordinator mutex poisoned");
        self.ensure_rec_mounted()?;
        fs::create_dir_all(self.rec_dir.as_ref())?;
        let next = next_start_segment(self.rec_dir.as_ref())?;

        persist_witness(self.rec_dir.as_ref(), next)?;
        let committed = commit(next);
        Ok((next, committed))
    }

    #[cfg(test)]
    pub fn allocate_start_segment(&self) -> io::Result<SegmentId> {
        self.reserve_start_segment(|_| ()).map(|(id, _)| id)
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

        let existing = read_witness(rec_dir)
            .map_err(SegmentDeleteError::Io)?
            .unwrap_or(0);
        persist_witness(rec_dir, existing.max(id)).map_err(SegmentDeleteError::Io)?;

        for path in paths {
            fs::remove_file(path).map_err(SegmentDeleteError::Io)?;
        }
        fsync_dir(rec_dir).map_err(SegmentDeleteError::Io)?;
        Ok(())
    }

    /// Boot-time repair for unrecoverable zero-byte leftovers from power loss.
    ///
    /// Must run before any recorder session starts. The pass is idempotent: if
    /// power dies after the witness write but before unlink, the next boot sees
    /// the same zero-byte files and retries. Fully empty ids raise the ADR 19
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
            let existing = read_witness(rec_dir)?.unwrap_or(0);
            persist_witness(rec_dir, existing.max(max_deleted))?;
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
}

#[derive(Debug, PartialEq, Eq)]
pub struct ScrubReport {
    pub deleted_ids: Vec<SegmentId>,
    pub repaired_paths: Vec<PathBuf>,
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
    let witness = read_witness(rec_dir)?;
    let scanned = max_clip_seq(rec_dir)?;
    Ok(witness
        .into_iter()
        .chain(scanned)
        .max()
        .map(|seq| seq.saturating_add(1))
        .unwrap_or(0))
}

#[derive(serde::Serialize, serde::Deserialize)]
struct StateWitness {
    high_water_seq: SegmentId,
}

fn read_witness(rec_dir: &Path) -> io::Result<Option<SegmentId>> {
    let path = state_path(rec_dir);
    let bytes = match fs::read(&path) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(corrupt_witness_error(&path, error)),
    };
    let state: StateWitness =
        serde_json::from_slice(&bytes).map_err(|error| corrupt_witness_error(&path, error))?;

    Ok(Some(state.high_water_seq))
}

fn persist_witness(rec_dir: &Path, high_water_seq: SegmentId) -> io::Result<()> {
    let state_dir = rec_dir.join(STATE_DIR);
    fs::create_dir_all(&state_dir)?;
    fsync_dir(rec_dir)?;

    let tmp_path = state_dir.join(TMP_STATE_FILE);
    let final_path = state_dir.join(STATE_FILE);
    let file = File::create(&tmp_path)?;
    serde_json::to_writer(&file, &StateWitness { high_water_seq })?;
    file.sync_all()?;
    drop(file);

    fs::rename(&tmp_path, &final_path)?;
    fsync_dir(&state_dir)?;
    Ok(())
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
        path::{Path, PathBuf},
        sync::{Arc, Barrier},
        thread,
    };

    use super::{state_path, SegmentDeleteError, StorageCoordinator};
    use crate::{
        clips::resolve_segment,
        recorder::{segment_filename, stamped_segment_filename, SegmentFacts, SegmentId},
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
                mono_ms: 123456789,
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
        let bytes = fs::read(state_path(rec_dir)).unwrap();
        serde_json::from_slice::<serde_json::Value>(&bytes)
            .unwrap()
            .get("high_water_seq")
            .unwrap()
            .as_u64()
            .unwrap()
            .try_into()
            .unwrap()
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
