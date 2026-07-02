use axum::{
    extract::State,
    http::{
        header::{HeaderMap, CONTENT_TYPE},
        StatusCode,
    },
};

use crate::{backend::BackendError, AppState};

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
    MissingJsonContentType,
    MissingIdempotencyKey,
    Backend(BackendError),
}

impl axum::response::IntoResponse for RecordingRequestError {
    fn into_response(self) -> axum::response::Response {
        match self {
            RecordingRequestError::MissingJsonContentType => (
                StatusCode::UNSUPPORTED_MEDIA_TYPE,
                "Content-Type must be application/json",
            )
                .into_response(),
            RecordingRequestError::MissingIdempotencyKey => {
                (StatusCode::BAD_REQUEST, "Idempotency-Key is required").into_response()
            }
            RecordingRequestError::Backend(error) => error.into_response(),
        }
    }
}

pub(crate) fn require_mutation_headers(headers: &HeaderMap) -> Result<(), RecordingRequestError> {
    let content_type = headers
        .get(CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default();
    if !is_json_content_type(content_type) {
        return Err(RecordingRequestError::MissingJsonContentType);
    }

    let idempotency_key = headers
        .get("idempotency-key")
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default()
        .trim();
    if idempotency_key.is_empty() {
        return Err(RecordingRequestError::MissingIdempotencyKey);
    }

    Ok(())
}

fn is_json_content_type(value: &str) -> bool {
    value
        .split(';')
        .next()
        .map(|media_type| media_type.trim().eq_ignore_ascii_case("application/json"))
        .unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use axum::http::{header::CONTENT_TYPE, HeaderMap, HeaderValue};

    use super::{require_mutation_headers, RecordingRequestError};

    #[test]
    fn mutation_headers_require_json_content_type() {
        let mut headers = HeaderMap::new();
        headers.insert("idempotency-key", HeaderValue::from_static("key"));

        assert!(matches!(
            require_mutation_headers(&headers),
            Err(RecordingRequestError::MissingJsonContentType)
        ));
    }

    #[test]
    fn mutation_headers_require_non_empty_idempotency_key() {
        let mut headers = HeaderMap::new();
        headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
        headers.insert("idempotency-key", HeaderValue::from_static(" "));

        assert!(matches!(
            require_mutation_headers(&headers),
            Err(RecordingRequestError::MissingIdempotencyKey)
        ));
    }

    #[test]
    fn mutation_headers_accept_json_with_params() {
        let mut headers = HeaderMap::new();
        headers.insert(
            CONTENT_TYPE,
            HeaderValue::from_static("application/json; charset=utf-8"),
        );
        headers.insert("idempotency-key", HeaderValue::from_static("key"));

        assert!(require_mutation_headers(&headers).is_ok());
    }
}
