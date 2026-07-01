pub type SessionId = u64;
pub type SegmentId = u32;

const SEGMENT_FILENAME_WIDTH: usize = 5;

/// Render the flat recording segment filename. The width is a minimum: after
/// `99999`, names grow wider and remain valid.
pub fn segment_filename(seq: SegmentId) -> String {
    format!("seg_{seq:0width$}.ts", width = SEGMENT_FILENAME_WIDTH)
}

/// Parse exactly the names `segment_filename` can render, with no aliases.
pub fn parse_segment_filename(name: &str) -> Option<SegmentId> {
    let digits = name.strip_prefix("seg_")?.strip_suffix(".ts")?;
    let seq = digits.parse::<SegmentId>().ok()?;
    (segment_filename(seq) == name).then_some(seq)
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
        parse_segment_filename, segment_filename, RecorderEvent, RecorderPhase, RecorderState,
    };

    #[test]
    fn segment_filename_round_trips_past_the_five_digit_boundary() {
        for seq in [0, 5, 99999, 100000, u32::MAX] {
            let name = segment_filename(seq);
            assert_eq!(parse_segment_filename(&name), Some(seq));
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
        ] {
            assert_eq!(parse_segment_filename(name), None, "{name}");
        }
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
