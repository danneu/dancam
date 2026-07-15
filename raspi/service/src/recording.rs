use axum::{
    extract::State,
    http::{HeaderMap, StatusCode},
};

use crate::{
    backend::BackendError,
    mutation::{require_mutation_headers, MutationHeaderError},
    AppState,
};

pub async fn start(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<StatusCode, RecordingRequestError> {
    require_mutation_headers(&headers)?;
    run_command(&state, "start", state.backend.start_recording()).await?;
    Ok(StatusCode::OK)
}

pub async fn stop(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<StatusCode, RecordingRequestError> {
    require_mutation_headers(&headers)?;
    run_command(&state, "stop", state.backend.stop_recording()).await?;
    Ok(StatusCode::OK)
}

async fn run_command(
    state: &AppState,
    command: &'static str,
    result: impl std::future::Future<Output = Result<(), BackendError>>,
) -> Result<(), RecordingRequestError> {
    result.await.map_err(|error| {
        let camera_state = state.backend.snapshot().camera_state;
        match error {
            BackendError::CameraStarting | BackendError::CameraRestarting => tracing::warn!(
                name: "recording_command_rejected",
                command,
                error_code = error.code(),
                camera_state = ?camera_state,
                "recording command rejected"
            ),
            _ => tracing::error!(
                name: "recording_command_rejected",
                command,
                error_code = error.code(),
                camera_state = ?camera_state,
                "recording command rejected"
            ),
        }
        RecordingRequestError::Backend(error)
    })
}

#[derive(Debug)]
pub enum RecordingRequestError {
    MutationHeaders(MutationHeaderError),
    Backend(BackendError),
}

impl axum::response::IntoResponse for RecordingRequestError {
    fn into_response(self) -> axum::response::Response {
        match self {
            RecordingRequestError::MutationHeaders(error) => error.into_response(),
            RecordingRequestError::Backend(error) => error.into_response(),
        }
    }
}

impl From<MutationHeaderError> for RecordingRequestError {
    fn from(error: MutationHeaderError) -> Self {
        Self::MutationHeaders(error)
    }
}
