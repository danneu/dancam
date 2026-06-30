use std::time::{SystemTime, UNIX_EPOCH};

use axum::{extract::State, Json};

use crate::AppState;

#[derive(serde::Serialize)]
pub struct HealthResponse {
    pub boot_id: String,
    pub uptime_s: u64,
    pub recording: bool,
    pub t_ms: u64,
}

pub async fn health(State(state): State<AppState>) -> Json<HealthResponse> {
    let t_ms = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis() as u64)
        .unwrap_or(0);

    Json(HealthResponse {
        boot_id: state.boot_id.to_string(),
        uptime_s: state.started.elapsed().as_secs(),
        recording: state.backend.snapshot().recorder.phase.is_active(),
        t_ms,
    })
}
