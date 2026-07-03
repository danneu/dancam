//! Single-writer storage coordination for recording-dir mutations.
//!
//! This coordinates start-segment reservation and finished-segment deletion. Every
//! reserved start id is durably written to `state/state.json` as `high_water_seq`
//! before the caller commits the recorder floor, and every delete raises that
//! same witness before unlinking a matching segment file.

use std::{
    fs::{self, File},
    io::{self, ErrorKind},
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
};

use crate::{
    clips::{max_clip_seq, segment_paths_for_id},
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
    mutation: Mutex<()>,
}

impl StorageCoordinator {
    pub fn new(rec_dir: PathBuf) -> Self {
        Self {
            rec_dir: Arc::from(rec_dir.into_boxed_path()),
            mutation: Mutex::new(()),
        }
    }

    pub fn rec_dir(&self) -> Arc<Path> {
        self.rec_dir.clone()
    }

    pub fn reserve_start_segment<R>(
        &self,
        commit: impl FnOnce(SegmentId) -> R,
    ) -> io::Result<(SegmentId, R)> {
        let _guard = self
            .mutation
            .lock()
            .expect("storage coordinator mutex poisoned");
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
}

#[derive(Debug)]
pub enum SegmentDeleteError {
    NotFound,
    Io(io::Error),
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
    use crate::recorder::{segment_filename, SegmentId};

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
        fs::create_dir_all(rec_dir).unwrap();
        fs::write(rec_dir.join(segment_filename(seq)), b"segment").unwrap();
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
