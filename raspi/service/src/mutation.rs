use axum::{
    http::{
        header::{HeaderMap, CONTENT_TYPE},
        StatusCode,
    },
    response::{IntoResponse, Response},
};

#[derive(Debug, PartialEq, Eq)]
pub enum MutationHeaderError {
    MissingJsonContentType,
    MissingIdempotencyKey,
}

impl IntoResponse for MutationHeaderError {
    fn into_response(self) -> Response {
        match self {
            MutationHeaderError::MissingJsonContentType => (
                StatusCode::UNSUPPORTED_MEDIA_TYPE,
                "Content-Type must be application/json",
            )
                .into_response(),
            MutationHeaderError::MissingIdempotencyKey => {
                (StatusCode::BAD_REQUEST, "Idempotency-Key is required").into_response()
            }
        }
    }
}

pub(crate) fn require_mutation_headers(headers: &HeaderMap) -> Result<(), MutationHeaderError> {
    let content_type = headers
        .get(CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default();
    if !is_json_content_type(content_type) {
        return Err(MutationHeaderError::MissingJsonContentType);
    }

    let idempotency_key = headers
        .get("idempotency-key")
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default()
        .trim();
    if idempotency_key.is_empty() {
        return Err(MutationHeaderError::MissingIdempotencyKey);
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

    use super::{require_mutation_headers, MutationHeaderError};

    #[test]
    fn mutation_headers_require_json_content_type() {
        let mut headers = HeaderMap::new();
        headers.insert("idempotency-key", HeaderValue::from_static("key"));

        assert!(matches!(
            require_mutation_headers(&headers),
            Err(MutationHeaderError::MissingJsonContentType)
        ));
    }

    #[test]
    fn mutation_headers_require_non_empty_idempotency_key() {
        let mut headers = HeaderMap::new();
        headers.insert(CONTENT_TYPE, HeaderValue::from_static("application/json"));
        headers.insert("idempotency-key", HeaderValue::from_static(" "));

        assert!(matches!(
            require_mutation_headers(&headers),
            Err(MutationHeaderError::MissingIdempotencyKey)
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
