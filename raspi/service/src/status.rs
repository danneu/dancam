use axum::{extract::State, Json};

use crate::{
    sysfacts::{self, DiskUsage, MemInfo},
    AppState,
};

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

#[derive(Clone, Debug, serde::Serialize)]
pub struct StatusResponse {
    pub recording: bool,
    pub camera_state: CameraState,
    pub boot_id: String,
    pub uptime_s: u64,
    pub storage: Option<DiskUsage>,
    pub temp_c: TempC,
    pub mem: Option<MemInfo>,
}

#[derive(Clone, Debug, serde::Serialize, PartialEq)]
pub struct TempC {
    pub soc: Option<f32>,
    pub sensor: Option<f32>,
}

pub async fn status(State(state): State<AppState>) -> Json<StatusResponse> {
    let backend_status = state.backend.status();

    Json(StatusResponse {
        recording: backend_status.recording,
        camera_state: backend_status.camera_state,
        boot_id: state.boot_id.to_string(),
        uptime_s: state.started.elapsed().as_secs(),
        storage: sysfacts::disk_usage(&state.rec_dir),
        temp_c: TempC {
            soc: sysfacts::soc_temp_c(),
            sensor: None,
        },
        mem: sysfacts::mem_info(),
    })
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
