pub type SessionId = u64;
pub type SegmentId = u32;

const SEGMENT_FILENAME_WIDTH: usize = 5;
const BOOT_TAG_LEN: usize = 12;

/// Render the flat recording segment filename. The width is a minimum: after
/// `99999`, names grow wider and remain valid.
pub fn segment_filename(seq: SegmentId) -> String {
    format!("seg_{seq:0width$}.ts", width = SEGMENT_FILENAME_WIDTH)
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SegmentFacts {
    pub boot_tag: String,
    pub mono_ms: u64,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParsedSegment {
    pub seq: SegmentId,
    pub facts: Option<SegmentFacts>,
}

pub fn stamped_segment_filename(seq: SegmentId, facts: &SegmentFacts) -> String {
    format!(
        "{}_{}_{}.ts",
        segment_stem(seq),
        facts.boot_tag,
        facts.mono_ms
    )
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
        [seq_digits, boot_tag, mono_digits] => {
            let seq = seq_digits.parse::<SegmentId>().ok()?;
            if !valid_boot_tag(boot_tag) {
                return None;
            }
            let mono_ms = mono_digits.parse::<u64>().ok()?;
            let facts = SegmentFacts {
                boot_tag: (*boot_tag).to_string(),
                mono_ms,
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

        self.session = self.session.saturating_add(1);
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
                if self.phase == RecorderPhase::Starting {
                    self.phase = RecorderPhase::Recording;
                    true
                } else {
                    self.phase == RecorderPhase::Recording
                }
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
                matches!(
                    self.phase,
                    RecorderPhase::Recording | RecorderPhase::Stopping
                )
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
        boot_tag, parse_segment_filename, segment_filename, stamped_segment_filename,
        ParsedSegment, RecorderEvent, RecorderPhase, RecorderState, SegmentFacts,
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
    fn parse_segment_filename_rejects_non_rendered_aliases() {
        for name in [
            "seg_999.ts",
            "seg_000005.ts",
            "seg_+5.ts",
            "seg_.ts",
            "seg_abc.ts",
            "seg_00005.mp4",
            "seg_4294967296.ts",
            "seg_00005_abc123abc123.ts",
            "seg_00005_abc123abc123_.ts",
        ] {
            assert_eq!(parse_segment_filename(name), None, "{name}");
        }
    }

    #[test]
    fn stamped_segment_filename_round_trips_past_the_five_digit_boundary() {
        let facts = SegmentFacts {
            boot_tag: "abc123def456".to_string(),
            mono_ms: 987654321,
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
            "seg_00000_abc123def456_987654321.ts"
        );
        assert_eq!(
            stamped_segment_filename(100000, &facts),
            "seg_100000_abc123def456_987654321.ts"
        );
    }

    #[test]
    fn stamped_segment_filename_rejects_non_rendered_aliases() {
        for name in [
            "seg_999_abc123def456_7.ts",
            "seg_000005_abc123def456_7.ts",
            "seg_00005_ABC123DEF456_7.ts",
            "seg_00005_abc123def45_7.ts",
            "seg_00005_abc123def4567_7.ts",
            "seg_00005_abc123def456_007.ts",
            "seg_00005_abc123def456_+7.ts",
            "seg_00005_abc123def456_7.mp4",
            "seg_00005_abc123xyz456_7.ts",
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

        assert_eq!(recorder.start(43), Some(1));

        let snapshot = recorder.snapshot();
        assert_eq!(snapshot.phase, RecorderPhase::Starting);
        assert_eq!(snapshot.session, 1);
        assert_eq!(snapshot.current_segment, None);
        assert_eq!(recorder.unpullable_from(), Some(43));
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
    fn segment_opened_wins_the_start_race_and_started_preserves_current() {
        let mut recorder = RecorderState::new();
        let session = recorder.start(43).unwrap();

        assert!(recorder.apply(RecorderEvent::SegmentOpened { session, id: 43 }));
        assert_eq!(recorder.snapshot().phase, RecorderPhase::Recording);
        assert_eq!(recorder.snapshot().current_segment.unwrap().id, 43);

        assert!(recorder.apply(RecorderEvent::RecordingStarted { session }));
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
