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
    state
        .backend
        .start_recording()
        .await
        .map_err(RecordingRequestError::Backend)?;
    Ok(StatusCode::OK)
}

pub async fn stop(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<StatusCode, RecordingRequestError> {
    require_mutation_headers(&headers)?;
    state
        .backend
        .stop_recording()
        .await
        .map_err(RecordingRequestError::Backend)?;
    Ok(StatusCode::OK)
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
