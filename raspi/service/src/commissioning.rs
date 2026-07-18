use std::{path::PathBuf, sync::Arc, time::Duration};

use tokio_util::sync::CancellationToken;

use crate::{backend::Backend, world::Commissioning};

pub const DEFAULT_STATE_PATH: &str = "/persist/dancam/commissioning.json";

pub fn parse_mock_override(value: &str) -> Result<Commissioning, String> {
    match value {
        "preparing" => Ok(Commissioning {
            state: crate::world::CommissioningState::Preparing,
            reason: None,
        }),
        "complete" => Ok(Commissioning::complete()),
        value if value.starts_with("failed:") && value.len() > "failed:".len() => {
            Ok(Commissioning {
                state: crate::world::CommissioningState::Failed,
                reason: Some(value["failed:".len()..].to_string()),
            })
        }
        _ => Err("expected preparing, complete, or failed:<reason>".to_string()),
    }
}

pub fn load(path: &std::path::Path) -> Result<Commissioning, String> {
    let bytes = std::fs::read(path)
        .map_err(|error| format!("read commissioning state {}: {error}", path.display()))?;
    let state: Commissioning = serde_json::from_slice(&bytes)
        .map_err(|error| format!("decode commissioning state {}: {error}", path.display()))?;
    match (&state.state, &state.reason) {
        (crate::world::CommissioningState::Failed, Some(reason)) if !reason.is_empty() => Ok(state),
        (crate::world::CommissioningState::Failed, _) => {
            Err("failed commissioning state requires a non-empty reason".to_string())
        }
        (_, None) => Ok(state),
        (_, Some(_)) => Err("only failed commissioning state may carry a reason".to_string()),
    }
}

pub fn spawn_watcher(
    backend: Arc<dyn Backend>,
    path: PathBuf,
    interval: Duration,
    shutdown: CancellationToken,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut last = backend.snapshot().commissioning;
        let mut cadence = tokio::time::interval(interval);
        cadence.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
        loop {
            tokio::select! {
                biased;
                _ = shutdown.cancelled() => return,
                _ = cadence.tick() => {}
            }

            match load(&path) {
                Ok(next) if next != last => {
                    backend.update_commissioning(next.clone());
                    last = next;
                }
                Ok(_) => {}
                Err(error) => {
                    tracing::warn!(%error, "commissioning state unavailable");
                    let failed = Commissioning {
                        state: crate::world::CommissioningState::Failed,
                        reason: Some("commissioning_state_unavailable".to_string()),
                    };
                    if last != failed {
                        backend.update_commissioning(failed.clone());
                        last = failed;
                    }
                }
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::{load, parse_mock_override};
    use crate::world::{Commissioning, CommissioningState};

    #[test]
    fn failed_state_requires_actionable_reason() {
        let dir =
            std::env::temp_dir().join(format!("dancam-commissioning-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&dir).unwrap();
        let path = dir.join("commissioning.json");
        std::fs::write(&path, br#"{"state":"failed","reason":null}"#).unwrap();
        assert!(load(&path).unwrap_err().contains("non-empty reason"));

        std::fs::write(
            &path,
            br#"{"state":"failed","reason":"data_partition_growth_failed"}"#,
        )
        .unwrap();
        assert_eq!(
            load(&path).unwrap(),
            Commissioning {
                state: CommissioningState::Failed,
                reason: Some("data_partition_growth_failed".to_string()),
            }
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn mock_override_carries_failure_reason() {
        assert_eq!(
            parse_mock_override("failed:data_partition_growth_failed").unwrap(),
            Commissioning {
                state: CommissioningState::Failed,
                reason: Some("data_partition_growth_failed".to_string()),
            }
        );
        assert!(parse_mock_override("failed:").is_err());
    }
}
