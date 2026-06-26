#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
pub struct Status {
    pub recording: bool,
    pub camera_state: CameraState,
}

impl Status {
    pub fn starting() -> Self {
        Self {
            recording: false,
            camera_state: CameraState::Starting,
        }
    }

    pub fn running(recording: bool) -> Self {
        Self {
            recording,
            camera_state: CameraState::Running,
        }
    }

    pub fn restarting() -> Self {
        Self {
            recording: false,
            camera_state: CameraState::Restarting,
        }
    }

    pub fn offline() -> Self {
        Self {
            recording: false,
            camera_state: CameraState::Offline,
        }
    }
}

#[derive(Clone, Debug, serde::Serialize, serde::Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CameraState {
    Starting,
    Running,
    Restarting,
    Offline,
}

#[derive(Clone, Debug, serde::Deserialize, PartialEq, Eq)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum ChildEvent {
    Ready,
    RecordingStarted,
    RecordingStopped,
    Error {
        #[serde(default)]
        detail: String,
    },
}

#[cfg(test)]
mod tests {
    use super::{CameraState, ChildEvent, Status};

    #[test]
    fn status_serializes_as_snake_case() {
        let status = Status {
            recording: true,
            camera_state: CameraState::Running,
        };

        assert_eq!(
            serde_json::to_string(&status).unwrap(),
            r#"{"recording":true,"camera_state":"running"}"#
        );
    }

    #[test]
    fn child_event_parses_stderr_contract() {
        assert_eq!(
            serde_json::from_str::<ChildEvent>(r#"{"event":"ready"}"#).unwrap(),
            ChildEvent::Ready
        );
        assert_eq!(
            serde_json::from_str::<ChildEvent>(r#"{"event":"error","detail":"camera failed"}"#)
                .unwrap(),
            ChildEvent::Error {
                detail: "camera failed".to_string()
            }
        );
    }
}
