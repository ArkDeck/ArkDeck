use super::{Owner, Snapshot, State, StoreError};
use arkdeck_platform::HostReadLock;

#[derive(Debug, Clone, Copy)]
pub enum OperationKind {
    Check,
    Download,
    Handoff { explicit_consent: bool },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OperationError {
    Store(StoreError),
    InvalidTransition,
    ExplicitConsentRequired,
    Cancelled,
}
impl From<StoreError> for OperationError {
    fn from(error: StoreError) -> Self {
        Self::Store(error)
    }
}

/// Owns the process lease through network, validation and terminal publication.
/// Dropping an unfinished operation leaves its durable active identity intact;
/// the next owner must recover it, never infer that an external effect happened.
pub struct ActiveOperation<'a> {
    owner: &'a Owner,
    _lease: HostReadLock,
    pub initial: Snapshot,
    id: String,
    minimum_generation: u64,
}

impl Owner {
    pub fn begin(
        &self,
        kind: OperationKind,
        now: &str,
    ) -> Result<ActiveOperation<'_>, OperationError> {
        if matches!(
            kind,
            OperationKind::Handoff {
                explicit_consent: false
            }
        ) {
            return Err(OperationError::ExplicitConsentRequired);
        }
        let lease = self.store.acquire_operation_lease()?;
        let initial = self.store.load(now)?;
        let state = match kind {
            OperationKind::Check => {
                if initial.active_operation_id.is_some() {
                    return Err(StoreError::OperationInProgress.into());
                }
                if !matches!(
                    initial.state,
                    State::Idle {}
                        | State::Available { .. }
                        | State::NoUpdate { .. }
                        | State::Failed { .. }
                        | State::Cancelled {}
                ) {
                    return Err(OperationError::InvalidTransition);
                }
                State::Checking {}
            }
            OperationKind::Download => {
                if initial.active_operation_id.is_some() {
                    return Err(OperationError::InvalidTransition);
                }
                let State::Available { feed } = &initial.state else {
                    return Err(OperationError::InvalidTransition);
                };
                State::Downloading { feed: feed.clone() }
            }
            OperationKind::Handoff { .. } => {
                if initial.active_operation_id.is_some()
                    || !matches!(initial.state, State::AwaitingConsent { .. })
                {
                    return Err(OperationError::InvalidTransition);
                }
                initial.state.clone()
            }
        };
        let id = crate::job_plan::uuid()
            .map_err(|_| StoreError::WriteFailed)?
            .to_ascii_uppercase();
        let active = self
            .store
            .replace(initial.generation, state, Some(id.clone()), false, now)?;
        Ok(ActiveOperation {
            owner: self,
            _lease: lease,
            initial,
            id,
            minimum_generation: active.generation,
        })
    }
}

impl ActiveOperation<'_> {
    pub fn cancellation_requested(&self, now: &str) -> bool {
        self.owner.store.load(now).map_or(true, |snapshot| {
            snapshot.active_operation_id.as_deref() != Some(self.id.as_str())
                || snapshot.cancellation_requested
        })
    }

    pub fn finish(&self, result: State, now: &str) -> Result<Snapshot, OperationError> {
        let (snapshot, cancelled) = self
            .owner
            .store
            .complete_operation(&self.id, Some(self.minimum_generation), result, now)?
            .ok_or(StoreError::ResourceConflict)?;
        if cancelled {
            Err(OperationError::Cancelled)
        } else {
            Ok(snapshot)
        }
    }

    pub fn settle_failure(&self, result: State, now: &str) -> Result<(), OperationError> {
        self.owner
            .store
            .complete_operation(&self.id, None, result, now)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runtime_update::{Cache, Failure, NoUpdate, Store};
    use std::path::PathBuf;
    const NOW: &str = "2026-09-26T00:00:00Z";
    struct Root(PathBuf);
    impl Drop for Root {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn setup(name: &str) -> (Root, Owner) {
        let root = Root(std::env::temp_dir().join(format!(
            "arkdeck-update-operation-{}",
            crate::client_frame_id()
        )));
        let owner = Owner {
            store: Store::new(root.0.join("state")),
            cache: Cache::new(root.0.join("cache")),
        };
        let rows: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../tests/fixtures/runtime-update/states.json"
        ))
        .unwrap();
        let row = rows["cases"]
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["name"] == name)
            .unwrap();
        let encoded = row["snapshotBase64"].as_str().unwrap();
        let padding = encoded.bytes().rev().take_while(|b| *b == b'=').count();
        let bytes = arkdeck_contract::decode_import_chunk(
            encoded,
            (encoded.len() / 4 * 3 - padding) as u64,
        )
        .unwrap();
        let snapshot: Snapshot = serde_json::from_slice(&bytes).unwrap();
        owner
            .store
            .replace(0, snapshot.state, None, false, NOW)
            .unwrap();
        (root, owner)
    }

    #[test]
    fn cancellation_is_durable_and_completion_cannot_restore_success() {
        let (_root, owner) = setup("idle");
        let operation = owner.begin(OperationKind::Check, NOW).unwrap();
        assert!(matches!(
            owner.status(NOW).unwrap().state,
            State::Checking {}
        ));
        assert!(matches!(
            owner.begin(OperationKind::Check, NOW),
            Err(OperationError::Store(StoreError::OperationInProgress))
        ));
        owner.cancel(NOW).unwrap();
        assert!(operation.cancellation_requested(NOW));
        assert_eq!(
            operation.finish(
                State::NoUpdate {
                    reason: NoUpdate::CurrentVersion
                },
                NOW
            ),
            Err(OperationError::Cancelled)
        );
        let final_state = owner.store.load(NOW).unwrap();
        assert!(matches!(final_state.state, State::Cancelled {}));
        assert!(final_state.active_operation_id.is_none());
        assert!(!final_state.cancellation_requested);
        assert_eq!(
            operation.finish(State::Idle {}, NOW),
            Err(OperationError::Store(StoreError::ResourceConflict))
        );
    }

    #[test]
    fn unfinished_owner_is_recovered_and_another_identity_is_never_settled() {
        let (_root, owner) = setup("idle");
        let operation = owner.begin(OperationKind::Check, NOW).unwrap();
        drop(operation);
        assert!(matches!(
            owner.status(NOW).unwrap().state,
            State::Cancelled {}
        ));
        let operation = owner.begin(OperationKind::Check, NOW).unwrap();
        let current = owner.store.load(NOW).unwrap();
        let replacement = owner
            .store
            .replace(
                current.generation,
                State::Checking {},
                Some("AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA".into()),
                false,
                NOW,
            )
            .unwrap();
        assert!(operation.cancellation_requested(NOW));
        assert_eq!(
            operation.finish(State::Idle {}, NOW),
            Err(OperationError::Store(StoreError::ResourceConflict))
        );
        operation
            .settle_failure(
                State::Failed {
                    code: Failure::Network,
                },
                NOW,
            )
            .unwrap();
        assert_eq!(owner.store.load(NOW).unwrap(), replacement);
    }

    #[test]
    fn handoff_needs_consent_and_observed_reveal_survives_late_cancel() {
        let (_root, owner) = setup("awaitingConsent");
        let before = owner.store.load(NOW).unwrap();
        assert!(matches!(
            owner.begin(
                OperationKind::Handoff {
                    explicit_consent: false
                },
                NOW
            ),
            Err(OperationError::ExplicitConsentRequired)
        ));
        assert_eq!(owner.store.load(NOW).unwrap(), before);
        let operation = owner
            .begin(
                OperationKind::Handoff {
                    explicit_consent: true,
                },
                NOW,
            )
            .unwrap();
        owner.cancel(NOW).unwrap();
        let result = operation
            .finish(
                State::HandedOff {
                    url: "file:///private/tmp/already-revealed.dmg".into(),
                },
                NOW,
            )
            .unwrap();
        assert!(matches!(result.state, State::HandedOff { .. }));
        assert!(result.active_operation_id.is_none());
        assert!(!result.cancellation_requested);
    }

    #[test]
    fn finish_and_cancel_share_one_linearization_point() {
        for handoff in [false, true] {
            for _ in 0..8 {
                let (_root, owner) = setup(if handoff { "awaitingConsent" } else { "idle" });
                let operation = owner
                    .begin(
                        if handoff {
                            OperationKind::Handoff {
                                explicit_consent: true,
                            }
                        } else {
                            OperationKind::Check
                        },
                        NOW,
                    )
                    .unwrap();
                let barrier = std::sync::Barrier::new(2);
                let result = std::thread::scope(|scope| {
                    let cancel = scope.spawn(|| {
                        barrier.wait();
                        owner.cancel(NOW).unwrap();
                    });
                    barrier.wait();
                    let result = operation.finish(
                        if handoff {
                            State::HandedOff {
                                url: "file:///private/tmp/revealed.dmg".into(),
                            }
                        } else {
                            State::NoUpdate {
                                reason: NoUpdate::CurrentVersion,
                            }
                        },
                        NOW,
                    );
                    cancel.join().unwrap();
                    result
                });
                let snapshot = owner.store.load(NOW).unwrap();
                assert!(snapshot.active_operation_id.is_none());
                assert!(!snapshot.cancellation_requested);
                if handoff {
                    assert!(result.is_ok());
                    assert!(matches!(snapshot.state, State::HandedOff { .. }));
                } else {
                    match result {
                        Ok(returned) => {
                            assert!(matches!(returned.state, State::NoUpdate { .. }));
                            assert_eq!(snapshot, returned);
                        }
                        Err(OperationError::Cancelled) => {
                            assert!(matches!(snapshot.state, State::Cancelled {}))
                        }
                        other => panic!("unexpected completion: {other:?}"),
                    }
                }
            }
        }
    }
}
