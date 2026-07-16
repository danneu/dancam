pub type SessionId = u64;
pub type SegmentId = u32;

const SEGMENT_FILENAME_WIDTH: usize = 5;
const BOOT_TAG_LEN: usize = 12;
const RECORDING_ARTIFACT_PREFIX: &str = ".dancam-seg_";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RecordingArtifactState {
    Uncommitted,
    CommittedOpen,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RecordingArtifact {
    pub state: RecordingArtifactState,
    pub seq: SegmentId,
    pub facts: SegmentFacts,
}

/// Render the flat recording segment filename. The width is a minimum: after
/// `99999`, names grow wider and remain valid.
pub fn segment_filename(seq: SegmentId) -> String {
    format!("seg_{seq:0width$}.ts", width = SEGMENT_FILENAME_WIDTH)
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SegmentFacts {
    pub boot_tag: String,
    /// Recorder session id, `>= 1` by construction: it is `start_segment + 1` from the
    /// durably reserved start segment, so session 0 never reaches a filename. See
    /// `docs/design/pi/storage.md#segment-and-recording-identity`.
    pub session: SessionId,
    pub mono_ms: u64,
    pub dur_ms: Option<u64>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParsedSegment {
    pub seq: SegmentId,
    pub facts: Option<SegmentFacts>,
}

pub fn stamped_segment_filename(seq: SegmentId, facts: &SegmentFacts) -> String {
    let stamped = format!(
        "{}_{}_{}_{}.ts",
        segment_stem(seq),
        facts.boot_tag,
        facts.session,
        facts.mono_ms
    );
    match facts.dur_ms {
        Some(dur_ms) => format!("{}_{dur_ms}.ts", stamped.trim_end_matches(".ts")),
        None => stamped,
    }
}

pub fn recording_artifact_filename(
    state: RecordingArtifactState,
    seq: SegmentId,
    facts: &SegmentFacts,
) -> String {
    let suffix = match state {
        RecordingArtifactState::Uncommitted => ".pending",
        RecordingArtifactState::CommittedOpen => ".open.ts",
    };
    format!(
        "{RECORDING_ARTIFACT_PREFIX}{seq:0width$}_{}_{}_{}{suffix}",
        facts.boot_tag,
        facts.session,
        facts.mono_ms,
        width = SEGMENT_FILENAME_WIDTH,
    )
}

pub fn parse_recording_artifact_filename(name: &str) -> Option<RecordingArtifact> {
    let (body, state) = if let Some(body) = name
        .strip_prefix(RECORDING_ARTIFACT_PREFIX)
        .and_then(|body| body.strip_suffix(".pending"))
    {
        (body, RecordingArtifactState::Uncommitted)
    } else {
        (
            name.strip_prefix(RECORDING_ARTIFACT_PREFIX)?
                .strip_suffix(".open.ts")?,
            RecordingArtifactState::CommittedOpen,
        )
    };
    let parts = body.split('_').collect::<Vec<_>>();
    let [seq_digits, boot_tag, session_digits, mono_digits] = parts.as_slice() else {
        return None;
    };
    if !valid_boot_tag(boot_tag) {
        return None;
    }
    let seq = seq_digits.parse::<SegmentId>().ok()?;
    let facts = SegmentFacts {
        boot_tag: (*boot_tag).to_string(),
        session: session_digits.parse().ok()?,
        mono_ms: mono_digits.parse().ok()?,
        dur_ms: None,
    };
    (recording_artifact_filename(state, seq, &facts) == name).then_some(RecordingArtifact {
        state,
        seq,
        facts,
    })
}

/// Parse exactly the names this module can render, with no aliases.
pub fn parse_segment_filename(name: &str) -> Option<ParsedSegment> {
    let body = name.strip_prefix("seg_")?.strip_suffix(".ts")?;
    let parts = body.split('_').collect::<Vec<_>>();
    match parts.as_slice() {
        [seq_digits] => {
            let seq = seq_digits.parse::<SegmentId>().ok()?;
            (segment_filename(seq) == name).then_some(ParsedSegment { seq, facts: None })
        }
        [seq_digits, boot_tag, session_digits, mono_digits]
        | [seq_digits, boot_tag, session_digits, mono_digits, _] => {
            let seq = seq_digits.parse::<SegmentId>().ok()?;
            if !valid_boot_tag(boot_tag) {
                return None;
            }
            // Bounding both numeric fields to `u64` before re-rendering is what makes an
            // oversized value reject: Python ints are unbounded, so an out-of-range
            // `sess`/`monoMs` re-renders byte-identically yet must not parse.
            let session = session_digits.parse::<u64>().ok()?;
            let mono_ms = mono_digits.parse::<u64>().ok()?;
            let dur_ms = match parts.as_slice() {
                [_, _, _, _, dur_digits] => Some(dur_digits.parse::<u64>().ok()?),
                _ => None,
            };
            let facts = SegmentFacts {
                boot_tag: (*boot_tag).to_string(),
                session,
                mono_ms,
                dur_ms,
            };
            (stamped_segment_filename(seq, &facts) == name).then_some(ParsedSegment {
                seq,
                facts: Some(facts),
            })
        }
        _ => None,
    }
}

pub fn boot_tag(boot_id: &str) -> Option<String> {
    let stripped = boot_id.replace('-', "").to_ascii_lowercase();
    let tag = stripped.get(..BOOT_TAG_LEN)?;
    valid_boot_tag(tag).then(|| tag.to_string())
}

fn segment_stem(seq: SegmentId) -> String {
    format!("seg_{seq:0width$}", width = SEGMENT_FILENAME_WIDTH)
}

fn valid_boot_tag(tag: &str) -> bool {
    tag.len() == BOOT_TAG_LEN
        && tag
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
}

#[derive(Clone, Copy, Debug, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum RecorderPhase {
    Idle,
    Starting,
    Recording,
    Stopping,
    Error,
}

impl RecorderPhase {
    pub fn is_active(self) -> bool {
        matches!(
            self,
            RecorderPhase::Starting | RecorderPhase::Recording | RecorderPhase::Stopping
        )
    }
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct RecorderSnapshot {
    pub phase: RecorderPhase,
    pub session: SessionId,
    pub current_segment: Option<CurrentSegment>,
    pub detail: Option<String>,
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct CurrentSegment {
    pub id: SegmentId,
    pub dur_ms: Option<u64>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RecorderState {
    phase: RecorderPhase,
    session: SessionId,
    current_segment: Option<SegmentId>,
    start_segment: SegmentId,
    unpullable_floor: Option<SegmentId>,
    detail: Option<String>,
}

impl RecorderState {
    pub fn new() -> Self {
        Self {
            phase: RecorderPhase::Idle,
            session: 0,
            current_segment: None,
            start_segment: 0,
            unpullable_floor: None,
            detail: None,
        }
    }

    pub fn start(&mut self, start_segment: SegmentId) -> Option<SessionId> {
        if !matches!(self.phase, RecorderPhase::Idle | RecorderPhase::Error) {
            return None;
        }

        // Session is derived from the durably reserved start segment, not an
        // in-process counter: `start_segment` is the storage coordinator's monotonic
        // high-water witness, so a same-boot service restart cannot reissue session 1.
        // `start_segment + 1` keeps session `>= 1` (session 0 never reaches a filename).
        self.session = u64::from(start_segment) + 1;
        self.phase = RecorderPhase::Starting;
        self.current_segment = None;
        self.start_segment = start_segment;
        self.unpullable_floor = Some(start_segment);
        self.detail = None;
        Some(self.session)
    }

    pub fn stop(&mut self) -> Option<SessionId> {
        if !matches!(
            self.phase,
            RecorderPhase::Starting | RecorderPhase::Recording
        ) {
            return None;
        }

        self.phase = RecorderPhase::Stopping;
        Some(self.session)
    }

    pub fn apply(&mut self, event: RecorderEvent) -> bool {
        if !self.accepts_session(event.session()) {
            tracing::warn!(
                live_session = self.session,
                event_session = event.session(),
                "dropping stale recorder event"
            );
            return false;
        }

        match event {
            RecorderEvent::RecordingStarted { .. } => {
                // Process readiness is deliberately not recording readiness. Only a
                // durably validated SegmentOpened may complete start.
                false
            }
            RecorderEvent::SegmentOpened { id, .. } => {
                if !self.accepts_segment(id) {
                    tracing::warn!(
                        start_segment = self.start_segment,
                        segment = id,
                        "dropping below-floor segment_opened"
                    );
                    return false;
                }
                if matches!(
                    self.phase,
                    RecorderPhase::Starting | RecorderPhase::Recording
                ) {
                    self.phase = RecorderPhase::Recording;
                    self.current_segment = Some(id);
                    self.unpullable_floor = Some(id);
                    true
                } else {
                    false
                }
            }
            RecorderEvent::SegmentClosed { id, .. } => {
                if !self.accepts_segment(id) {
                    tracing::warn!(
                        start_segment = self.start_segment,
                        segment = id,
                        "dropping below-floor segment_closed"
                    );
                    return false;
                }
                if !matches!(
                    self.phase,
                    RecorderPhase::Recording | RecorderPhase::Stopping
                ) || self.current_segment != Some(id)
                {
                    return false;
                }
                self.current_segment = None;
                self.unpullable_floor = id.checked_add(1);
                true
            }
            RecorderEvent::RecordingStopped { .. } => {
                if self.phase.is_active() {
                    self.phase = RecorderPhase::Idle;
                    self.current_segment = None;
                    self.unpullable_floor = None;
                    self.detail = None;
                    true
                } else {
                    false
                }
            }
        }
    }

    pub fn fail(&mut self, detail: impl Into<String>) -> Option<SessionId> {
        if !self.phase.is_active() {
            return None;
        }

        self.phase = RecorderPhase::Error;
        self.current_segment = None;
        self.detail = Some(detail.into());
        Some(self.session)
    }

    pub fn snapshot(&self) -> RecorderSnapshot {
        RecorderSnapshot {
            phase: self.phase,
            session: self.session,
            current_segment: self
                .current_segment
                .map(|id| CurrentSegment { id, dur_ms: None }),
            detail: self.detail.clone(),
        }
    }

    pub fn phase(&self) -> RecorderPhase {
        self.phase
    }

    pub fn session(&self) -> SessionId {
        self.session
    }

    pub fn current_segment(&self) -> Option<SegmentId> {
        self.current_segment
    }

    pub fn is_active(&self) -> bool {
        self.phase.is_active()
    }

    pub fn unpullable_from(&self) -> Option<SegmentId> {
        self.unpullable_floor
    }

    fn accepts_session(&self, session: SessionId) -> bool {
        session == self.session
    }

    fn accepts_segment(&self, id: SegmentId) -> bool {
        id >= self.start_segment
    }
}

impl Default for RecorderState {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RecorderEvent {
    RecordingStarted { session: SessionId },
    SegmentOpened { session: SessionId, id: SegmentId },
    SegmentClosed { session: SessionId, id: SegmentId },
    RecordingStopped { session: SessionId },
}

impl RecorderEvent {
    fn session(&self) -> SessionId {
        match self {
            RecorderEvent::RecordingStarted { session }
            | RecorderEvent::SegmentOpened { session, .. }
            | RecorderEvent::SegmentClosed { session, .. }
            | RecorderEvent::RecordingStopped { session } => *session,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        boot_tag, parse_recording_artifact_filename, parse_segment_filename,
        recording_artifact_filename, segment_filename, stamped_segment_filename, ParsedSegment,
        RecorderEvent, RecorderPhase, RecorderState, RecordingArtifact, RecordingArtifactState,
        SegmentFacts,
    };

    #[test]
    fn segment_filename_round_trips_past_the_five_digit_boundary() {
        for seq in [0, 5, 99999, 100000, u32::MAX] {
            let name = segment_filename(seq);
            assert_eq!(
                parse_segment_filename(&name),
                Some(ParsedSegment { seq, facts: None })
            );
        }

        assert_eq!(segment_filename(0), "seg_00000.ts");
        assert_eq!(segment_filename(100000), "seg_100000.ts");
        assert_eq!(segment_filename(u32::MAX), "seg_4294967295.ts");
    }

    #[test]
    fn recording_artifact_names_round_trip_exactly() {
        let facts = SegmentFacts {
            boot_tag: "abc123def456".to_string(),
            session: 7,
            mono_ms: 987654321,
            dur_ms: None,
        };
        for state in [
            RecordingArtifactState::Uncommitted,
            RecordingArtifactState::CommittedOpen,
        ] {
            let name = recording_artifact_filename(state, 5, &facts);
            assert_eq!(
                parse_recording_artifact_filename(&name),
                Some(RecordingArtifact {
                    state,
                    seq: 5,
                    facts: facts.clone(),
                })
            );
        }
        assert_eq!(
            recording_artifact_filename(RecordingArtifactState::Uncommitted, 5, &facts),
            ".dancam-seg_00005_abc123def456_7_987654321.pending"
        );
        assert_eq!(
            recording_artifact_filename(RecordingArtifactState::CommittedOpen, 5, &facts),
            ".dancam-seg_00005_abc123def456_7_987654321.open.ts"
        );
        for invalid in [
            ".dancam-seg_00005_ABC123DEF456_7_987654321.open.ts",
            ".dancam-seg_00005_abc123def456_007_987654321.open.ts",
            ".dancam-seg_00005_abc123def456_7_987654321.ts",
            ".dancam-seg_4294967296_abc123def456_7_987654321.pending",
        ] {
            assert_eq!(
                parse_recording_artifact_filename(invalid),
                None,
                "{invalid}"
            );
        }
    }

    #[test]
    fn parse_segment_filename_rejects_non_rendered_aliases() {
        for name in [
            "seg_999.ts",
            "seg_000005.ts",
            "seg_+5.ts",
            "seg_.ts",
            "seg_abc.ts",
            "seg_00005.mp4",
            "seg_4294967296.ts",
            "seg_00005_abc123def456_7.ts",
            "seg_00005_abc123def456_7_.ts",
        ] {
            assert_eq!(parse_segment_filename(name), None, "{name}");
        }
    }

    #[test]
    fn stamped_segment_filename_round_trips_past_the_five_digit_boundary() {
        let facts = SegmentFacts {
            boot_tag: "abc123def456".to_string(),
            session: 7,
            mono_ms: 987654321,
            dur_ms: None,
        };

        for seq in [0, 5, 99999, 100000, u32::MAX] {
            let name = stamped_segment_filename(seq, &facts);
            assert_eq!(
                parse_segment_filename(&name),
                Some(ParsedSegment {
                    seq,
                    facts: Some(facts.clone())
                })
            );
        }

        assert_eq!(
            stamped_segment_filename(0, &facts),
            "seg_00000_abc123def456_7_987654321.ts"
        );
        assert_eq!(
            stamped_segment_filename(100000, &facts),
            "seg_100000_abc123def456_7_987654321.ts"
        );

        // A `u64::MAX` session is a valid parse -- it round-trips byte-for-byte.
        let max_session = SegmentFacts {
            boot_tag: "abc123def456".to_string(),
            session: u64::MAX,
            mono_ms: 987654321,
            dur_ms: None,
        };
        let name = stamped_segment_filename(5, &max_session);
        assert_eq!(
            parse_segment_filename(&name),
            Some(ParsedSegment {
                seq: 5,
                facts: Some(max_session)
            })
        );

        let finalized = SegmentFacts {
            dur_ms: Some(30016),
            ..facts
        };
        let name = stamped_segment_filename(510, &finalized);
        assert_eq!(name, "seg_00510_abc123def456_7_987654321_30016.ts");
        assert_eq!(
            parse_segment_filename(&name),
            Some(ParsedSegment {
                seq: 510,
                facts: Some(finalized)
            })
        );
    }

    #[test]
    fn stamped_segment_filename_rejects_non_rendered_aliases() {
        for name in [
            "seg_999_abc123def456_7_987654321.ts",
            "seg_000005_abc123def456_7_987654321.ts",
            "seg_00005_ABC123DEF456_7_987654321.ts",
            "seg_00005_abc123def45_7_987654321.ts",
            "seg_00005_abc123def4567_7_987654321.ts",
            "seg_00005_abc123def456_007_987654321.ts",
            "seg_00005_abc123def456_+7_987654321.ts",
            "seg_00005_abc123def456_7_007.ts",
            "seg_00005_abc123def456_7_+9.ts",
            "seg_00005_abc123def456_7_987654321.mp4",
            "seg_00005_abc123xyz456_7_987654321.ts",
            "seg_00005_abc123def456_7_987654321_030016.ts",
            "seg_00005_abc123def456_7_987654321_.ts",
            "seg_00005_abc123def456_7_987654321_18446744073709551616.ts",
            // The old 3-part stamped form is rejected outright -- no legacy parse.
            "seg_00005_abc123def456_7.ts",
            // Oversized `sess` / `monoMs` round-trip textually but exceed `u64`, so the
            // range guard, not just re-render, must drop them.
            "seg_00005_abc123def456_18446744073709551616_7.ts",
            "seg_00005_abc123def456_7_18446744073709551616.ts",
        ] {
            assert_eq!(parse_segment_filename(name), None, "{name}");
        }
    }

    #[test]
    fn boot_tag_uses_the_first_twelve_hex_chars_after_dash_stripping() {
        assert_eq!(
            boot_tag("3f1c0e7a-8f3b-4e15-b196-20e0416af749").as_deref(),
            Some("3f1c0e7a8f3b")
        );
        assert_eq!(
            boot_tag("ABCDEF12-3456-7890-abcd-ef1234567890").as_deref(),
            Some("abcdef123456")
        );
        assert_eq!(boot_tag("unknown"), None);
        assert_eq!(boot_tag("abc123"), None);
        assert_eq!(boot_tag("abc123def45z"), None);
    }

    #[test]
    fn start_seeds_session_phase_and_unpullable_floor() {
        let mut recorder = RecorderState::new();

        // Session is `start_segment + 1`, so starting at segment 43 yields session 44.
        assert_eq!(recorder.start(43), Some(44));

        let snapshot = recorder.snapshot();
        assert_eq!(snapshot.phase, RecorderPhase::Starting);
        assert_eq!(snapshot.session, 44);
        assert_eq!(snapshot.current_segment, None);
        assert_eq!(recorder.unpullable_from(), Some(43));
    }

    #[test]
    fn session_derives_from_start_segment_not_an_in_process_counter() {
        // Two *fresh* states stand in for a same-boot service restart: the in-process
        // session field resets to 0 each time, so if session were an in-process counter
        // both would return 1 and two unrelated recordings would merge. Sourcing it from
        // the durably reserved start segment keeps them distinct.
        let mut before_restart = RecorderState::new();
        assert_eq!(before_restart.start(0), Some(1));

        let mut after_restart = RecorderState::new();
        assert_eq!(after_restart.start(41), Some(42));

        assert_ne!(before_restart.session(), after_restart.session());
    }

    #[test]
    fn guards_drop_stale_sessions_and_below_floor_segments() {
        let mut recorder = RecorderState::new();
        let session = recorder.start(43).unwrap();

        assert!(!recorder.apply(RecorderEvent::RecordingStarted {
            session: session + 1
        }));
        assert_eq!(recorder.snapshot().phase, RecorderPhase::Starting);

        assert!(!recorder.apply(RecorderEvent::SegmentOpened { session, id: 42 }));
        assert_eq!(recorder.snapshot().current_segment, None);
        assert_eq!(recorder.unpullable_from(), Some(43));
    }

    #[test]
    fn segment_opened_is_the_only_start_truth_point() {
        let mut recorder = RecorderState::new();
        let session = recorder.start(43).unwrap();

        assert!(recorder.apply(RecorderEvent::SegmentOpened { session, id: 43 }));
        assert_eq!(recorder.snapshot().phase, RecorderPhase::Recording);
        assert_eq!(recorder.snapshot().current_segment.unwrap().id, 43);

        assert!(!recorder.apply(RecorderEvent::RecordingStarted { session }));
        assert_eq!(recorder.snapshot().current_segment.unwrap().id, 43);
    }

    #[test]
    fn rollover_advances_current_and_unpullable_floor() {
        let mut recorder = RecorderState::new();
        let session = recorder.start(43).unwrap();
        recorder.apply(RecorderEvent::RecordingStarted { session });
        recorder.apply(RecorderEvent::SegmentOpened { session, id: 43 });

        assert!(recorder.apply(RecorderEvent::SegmentClosed { session, id: 43 }));
        assert!(recorder.apply(RecorderEvent::SegmentOpened { session, id: 44 }));

        assert_eq!(recorder.snapshot().current_segment.unwrap().id, 44);
        assert_eq!(recorder.unpullable_from(), Some(44));
    }

    #[test]
    fn stop_clears_current_and_floor() {
        let mut recorder = RecorderState::new();
        let session = recorder.start(43).unwrap();
        recorder.apply(RecorderEvent::SegmentOpened { session, id: 43 });

        assert_eq!(recorder.stop(), Some(session));
        assert_eq!(recorder.snapshot().phase, RecorderPhase::Stopping);
        assert!(recorder.apply(RecorderEvent::RecordingStopped { session }));

        assert_eq!(recorder.snapshot().phase, RecorderPhase::Idle);
        assert_eq!(recorder.snapshot().current_segment, None);
        assert_eq!(recorder.unpullable_from(), None);
    }

    #[test]
    fn fail_clears_current_but_preserves_last_opened_floor() {
        let mut recorder = RecorderState::new();
        let session = recorder.start(43).unwrap();
        recorder.apply(RecorderEvent::SegmentOpened { session, id: 43 });
        recorder.apply(RecorderEvent::SegmentClosed { session, id: 43 });
        recorder.apply(RecorderEvent::SegmentOpened { session, id: 44 });

        assert_eq!(recorder.fail("camera process exited"), Some(session));

        let snapshot = recorder.snapshot();
        assert_eq!(snapshot.phase, RecorderPhase::Error);
        assert_eq!(snapshot.current_segment, None);
        assert_eq!(snapshot.detail.as_deref(), Some("camera process exited"));
        assert_eq!(recorder.unpullable_from(), Some(44));
    }

    #[test]
    fn fail_is_noop_when_not_active() {
        let mut recorder = RecorderState::new();

        assert_eq!(recorder.fail("ignored"), None);
        assert_eq!(recorder.snapshot().phase, RecorderPhase::Idle);
        assert_eq!(recorder.unpullable_from(), None);
    }
}
