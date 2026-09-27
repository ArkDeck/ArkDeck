//! Whole-operation lifecycle with the same dependency-injection seam as the
//! Swift facade. The executable chooses the closed production assembly;
//! test implementations exercise ordering without a network or Finder effect.
use super::{
    ArtifactFailure, Cache, DownloadFailure, DownloadedArtifact, Failure, OperationError,
    OperationKind, Owner, ProductIdentity, Snapshot, State, ValidatedArtifact,
};
use std::path::Path;

#[derive(Debug)]
pub enum ConsumerError {
    Operation(OperationError),
    Network(super::NetworkError),
    Feed(&'static str),
    Download(arkdeck_platform::UpdateDownloadError),
    Artifact(ArtifactFailure),
    ArtifactChanged,
    Handoff,
    Host,
}
impl From<OperationError> for ConsumerError {
    fn from(value: OperationError) -> Self {
        Self::Operation(value)
    }
}
impl From<DownloadFailure> for ConsumerError {
    fn from(value: DownloadFailure) -> Self {
        match value {
            DownloadFailure::Network(e) => Self::Network(e),
            DownloadFailure::Artifact(e) => Self::Download(e),
            DownloadFailure::Cancelled => Self::Operation(OperationError::Cancelled),
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Event {
    CheckStarted,
    Available,
    NoUpdate,
    DownloadStarted,
    VerificationStarted,
    Failed,
    Cancelled,
    HandedOff,
}

pub trait Effects {
    fn attempt(&self, now: &str) -> Result<(), ConsumerError>;
    fn check(
        &self,
        identity: &ProductIdentity,
        now: &str,
        cancel: &(dyn Fn() -> bool + Sync),
    ) -> Result<State, ConsumerError>;
    fn download(
        &self,
        cache: &Cache,
        feed: &super::Feed,
        cancel: &(dyn Fn() -> bool + Sync),
    ) -> Result<DownloadedArtifact, ConsumerError>;
    fn validate(
        &self,
        cache: &Cache,
        artifact: &DownloadedArtifact,
    ) -> Result<ValidatedArtifact, ConsumerError>;
    fn reveal(&self, path: &Path) -> Result<(), ConsumerError>;
    fn event(&self, event: Event);
}

fn cancelled(error: &ConsumerError) -> bool {
    matches!(error, ConsumerError::Operation(OperationError::Cancelled))
}
fn failure_code(error: &ConsumerError, default: Failure) -> Failure {
    match error {
        ConsumerError::Network(_) => Failure::Network,
        ConsumerError::Feed(_) => Failure::Feed,
        ConsumerError::Download(_) | ConsumerError::Artifact(ArtifactFailure::File(_)) => {
            Failure::Download
        }
        ConsumerError::Artifact(_) => Failure::Artifact,
        _ => default,
    }
}
fn check_cancel(cancel: &dyn Fn() -> bool) -> Result<(), ConsumerError> {
    if cancel() {
        Err(OperationError::Cancelled.into())
    } else {
        Ok(())
    }
}
fn remove(cache: &Cache, artifact: &DownloadedArtifact) {
    cache.remove_interrupted(&State::Verifying {
        artifact: artifact.clone(),
    });
}

pub fn check(
    owner: &Owner,
    effects: &impl Effects,
    identity: &ProductIdentity,
    now: &str,
) -> Result<Snapshot, ConsumerError> {
    owner.recover(now).map_err(OperationError::from)?;
    let operation = owner.begin(OperationKind::Check, now)?;
    let cancel = || operation.cancellation_requested(now);
    let result = (|| {
        effects.attempt(now)?;
        effects.event(Event::CheckStarted);
        let result = effects.check(identity, now, &cancel)?;
        check_cancel(&cancel)?;
        effects.event(if matches!(result, State::Available { .. }) {
            Event::Available
        } else {
            Event::NoUpdate
        });
        Ok(result)
    })();
    match result {
        Ok(state) => operation.finish(state, now).map_err(Into::into),
        Err(error) => {
            effects.event(if cancelled(&error) {
                Event::Cancelled
            } else {
                Event::Failed
            });
            let state = if cancelled(&error) {
                State::Cancelled {}
            } else {
                State::Failed {
                    code: failure_code(&error, Failure::Feed),
                }
            };
            operation.settle_failure(state, now)?;
            Err(error)
        }
    }
}

pub fn download(
    owner: &Owner,
    effects: &impl Effects,
    now: &str,
) -> Result<Snapshot, ConsumerError> {
    owner.recover(now).map_err(OperationError::from)?;
    let operation = owner.begin(OperationKind::Download, now)?;
    let State::Available { feed } = &operation.initial.state else {
        unreachable!("begin checks transition");
    };
    let cancel = || operation.cancellation_requested(now);
    effects.event(Event::DownloadStarted);
    let mut downloaded = None;
    let result = (|| {
        let artifact = effects.download(&owner.cache, feed, &cancel)?;
        downloaded = Some(artifact.clone());
        check_cancel(&cancel)?;
        effects.event(Event::VerificationStarted);
        let validated = effects.validate(&owner.cache, &artifact)?;
        check_cancel(&cancel)?;
        Ok(State::AwaitingConsent {
            feed: feed.clone(),
            artifact: validated,
        })
    })();
    match result {
        Ok(state) => {
            let result = operation.finish(state, now).map_err(ConsumerError::from);
            if matches!(&result, Err(error) if cancelled(error))
                && let Some(artifact) = downloaded
            {
                remove(&owner.cache, &artifact);
            }
            // An uncertain state write is not retried or rolled back. The next
            // owner recovers the still-active operation and its orphan cache.
            result
        }
        Err(error) => {
            if let Some(artifact) = downloaded {
                remove(&owner.cache, &artifact);
            }
            effects.event(if cancelled(&error) {
                Event::Cancelled
            } else {
                Event::Failed
            });
            let state = if cancelled(&error) {
                State::Cancelled {}
            } else {
                State::Failed {
                    code: failure_code(&error, Failure::Download),
                }
            };
            operation.settle_failure(state, now)?;
            Err(error)
        }
    }
}

pub fn handoff(
    owner: &Owner,
    effects: &impl Effects,
    consent: bool,
    now: &str,
) -> Result<Snapshot, ConsumerError> {
    // CLI consent denial precedes even recovery, matching the published seam.
    if !consent {
        return Err(OperationError::ExplicitConsentRequired.into());
    }
    owner.recover(now).map_err(OperationError::from)?;
    let operation = owner.begin(
        OperationKind::Handoff {
            explicit_consent: true,
        },
        now,
    )?;
    let State::AwaitingConsent {
        artifact: approved, ..
    } = &operation.initial.state
    else {
        unreachable!("begin checks transition");
    };
    let cancel = || operation.cancellation_requested(now);
    let result = (|| {
        check_cancel(&cancel)?;
        let revalidated = effects.validate(&owner.cache, &approved.downloaded)?;
        if revalidated != *approved {
            return Err(ConsumerError::ArtifactChanged);
        }
        owner
            .cache
            .verify_download(&revalidated.downloaded)
            .map_err(ConsumerError::Download)?;
        let path = owner
            .cache
            .artifact_path(&revalidated.downloaded)
            .map_err(ConsumerError::Download)?;
        check_cancel(&cancel)?;
        effects.reveal(&path)?;
        effects.event(Event::HandedOff);
        Ok(State::HandedOff {
            url: revalidated.downloaded.url,
        })
    })();
    match result {
        // After observed reveal, late cancellation cannot erase the effect.
        // Publication failure returns directly; reveal is never replayed.
        Ok(state) => operation.finish(state, now).map_err(Into::into),
        Err(error) => {
            remove(&owner.cache, &approved.downloaded);
            effects.event(if cancelled(&error) {
                Event::Cancelled
            } else {
                Event::Failed
            });
            operation.settle_failure(
                if cancelled(&error) {
                    State::Cancelled {}
                } else {
                    State::Failed {
                        code: Failure::Handoff,
                    }
                },
                now,
            )?;
            Err(error)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::super::{Feed, NoUpdate, Store};
    use super::*;
    use std::{
        cell::{Cell, RefCell},
        path::PathBuf,
    };
    const NOW: &str = "2026-09-26T00:00:00Z";
    struct Root(PathBuf);
    impl Drop for Root {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    fn setup() -> (Root, Owner) {
        let root = Root(
            std::env::temp_dir().join(format!("arkdeck-consumer-{}", crate::client_frame_id())),
        );
        let owner = Owner {
            store: Store::new(root.0.join("state")),
            cache: Cache::new(root.0.join("cache")),
        };
        (root, owner)
    }
    fn feed() -> Feed {
        let rows: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../tests/fixtures/runtime-update/states.json"
        ))
        .unwrap();
        for row in rows["cases"].as_array().unwrap() {
            let encoded = row["snapshotBase64"].as_str().unwrap();
            let padding = encoded.bytes().rev().take_while(|b| *b == b'=').count();
            let bytes = arkdeck_contract::decode_import_chunk(
                encoded,
                (encoded.len() / 4 * 3 - padding) as u64,
            )
            .unwrap();
            let snapshot: Snapshot = serde_json::from_slice(&bytes).unwrap();
            if let State::Available { feed } = snapshot.state {
                return feed;
            }
        }
        panic!("actual Swift fixture has available state");
    }
    fn available(owner: &Owner) {
        owner
            .store
            .replace(0, State::Available { feed: feed() }, None, false, NOW)
            .unwrap();
    }
    struct FixtureEffects<'a> {
        owner: &'a Owner,
        events: RefCell<Vec<Event>>,
        reveals: Cell<usize>,
        validate_calls: Cell<usize>,
        cancel_after_download: bool,
        cancel_in_validation: bool,
        cancel_in_reveal: bool,
        fail_validation: bool,
        fail_reveal: bool,
        fail_check: bool,
        remove_state_after_reveal: bool,
        clock: Option<std::sync::Arc<std::sync::atomic::AtomicU64>>,
    }
    impl<'a> FixtureEffects<'a> {
        fn new(owner: &'a Owner) -> Self {
            Self {
                owner,
                events: RefCell::new(Vec::new()),
                reveals: Cell::new(0),
                validate_calls: Cell::new(0),
                cancel_after_download: false,
                cancel_in_validation: false,
                cancel_in_reveal: false,
                fail_validation: false,
                fail_reveal: false,
                fail_check: false,
                remove_state_after_reveal: false,
                clock: None,
            }
        }
    }
    impl Effects for FixtureEffects<'_> {
        fn attempt(&self, _: &str) -> Result<(), ConsumerError> {
            Ok(())
        }
        fn check(
            &self,
            _: &ProductIdentity,
            _: &str,
            cancel: &(dyn Fn() -> bool + Sync),
        ) -> Result<State, ConsumerError> {
            assert!(!cancel());
            if self.fail_check {
                return Err(ConsumerError::Network(
                    super::super::NetworkError::Transport(-1005),
                ));
            }
            Ok(State::NoUpdate {
                reason: NoUpdate::CurrentVersion,
            })
        }
        fn download(
            &self,
            cache: &Cache,
            _: &Feed,
            cancel: &(dyn Fn() -> bool + Sync),
        ) -> Result<DownloadedArtifact, ConsumerError> {
            assert!(!cancel());
            let mut writer = cache.begin_download(3).map_err(ConsumerError::Download)?;
            writer
                .write_chunk(b"abc")
                .map_err(ConsumerError::Download)?;
            let artifact = writer
                .seal(&arkdeck_contract::sha256_hex(b"abc"))
                .map_err(ConsumerError::Download)?;
            if self.cancel_after_download {
                self.owner.store.request_cancellation(NOW).unwrap();
            }
            if let Some(clock) = &self.clock {
                clock.store(1, std::sync::atomic::Ordering::SeqCst);
            }
            Ok(artifact)
        }
        fn validate(
            &self,
            cache: &Cache,
            artifact: &DownloadedArtifact,
        ) -> Result<ValidatedArtifact, ConsumerError> {
            self.validate_calls.set(self.validate_calls.get() + 1);
            cache
                .verify_download(artifact)
                .map_err(ConsumerError::Download)?;
            if self.cancel_in_validation {
                self.owner.store.request_cancellation(NOW).unwrap();
            }
            if self.fail_validation {
                return Err(ConsumerError::Artifact(ArtifactFailure::DifferentTeam));
            }
            Ok(ValidatedArtifact {
                downloaded: artifact.clone(),
                team_identifier: "ABCDEFGHIJ".into(),
            })
        }
        fn reveal(&self, path: &Path) -> Result<(), ConsumerError> {
            assert_eq!(std::fs::read(path).unwrap(), b"abc");
            self.reveals.set(self.reveals.get() + 1);
            if let Some(clock) = &self.clock {
                clock.store(3, std::sync::atomic::Ordering::SeqCst);
            }
            if self.fail_reveal {
                return Err(ConsumerError::Handoff);
            }
            if self.cancel_in_reveal {
                self.owner.store.request_cancellation(NOW).unwrap();
            }
            if self.remove_state_after_reveal {
                std::fs::remove_file(self.owner.store.directory().join("state-v1.json")).unwrap();
            }
            if let Some(clock) = &self.clock {
                assert_eq!(
                    self.owner.store.load(NOW).unwrap().updated_at_utc,
                    "2026-09-26T00:00:03Z"
                );
                clock.store(4, std::sync::atomic::Ordering::SeqCst);
            }
            Ok(())
        }
        fn event(&self, event: Event) {
            self.events.borrow_mut().push(event);
        }
    }
    #[test]
    fn check_settles_success_and_network_failure_with_path_free_state() {
        let (_root, owner) = setup();
        let mut effects = FixtureEffects::new(&owner);
        let identity = ProductIdentity {
            app_version: "1.0.0".into(),
            system_version: "14.0.0".into(),
            architecture: "arm64".into(),
        };
        let snapshot = check(&owner, &effects, &identity, NOW).unwrap();
        assert!(matches!(snapshot.state, State::NoUpdate { .. }));
        assert!(snapshot.active_operation_id.is_none());
        assert_eq!(
            *effects.events.borrow(),
            [Event::CheckStarted, Event::NoUpdate]
        );
        effects.fail_check = true;
        assert!(matches!(
            check(&owner, &effects, &identity, NOW),
            Err(ConsumerError::Network(_))
        ));
        assert!(matches!(
            owner.store.load(NOW).unwrap().state,
            State::Failed {
                code: Failure::Network
            }
        ));
    }
    #[test]
    fn download_cancellation_or_invalid_signature_removes_materialized_artifact() {
        for phase in ["download", "validation", "invalid"] {
            let (root, owner) = setup();
            available(&owner);
            let mut effects = FixtureEffects::new(&owner);
            effects.cancel_after_download = phase == "download";
            effects.cancel_in_validation = phase == "validation";
            effects.fail_validation = phase == "invalid";
            assert!(download(&owner, &effects, NOW).is_err());
            let snapshot = owner.store.load(NOW).unwrap();
            if phase == "invalid" {
                assert!(matches!(
                    snapshot.state,
                    State::Failed {
                        code: Failure::Artifact
                    }
                ));
            } else {
                assert!(matches!(snapshot.state, State::Cancelled {}));
            }
            assert!(snapshot.active_operation_id.is_none());
            assert_eq!(std::fs::read_dir(root.0.join("cache")).unwrap().count(), 0);
            assert_eq!(effects.reveals.get(), 0);
        }
    }
    #[test]
    fn consent_and_cancellation_gates_precede_reveal_and_late_cancel_preserves_handoff() {
        for phase in [
            "noConsent",
            "cancel",
            "invalid",
            "revealError",
            "lateCancel",
            "success",
        ] {
            let (root, owner) = setup();
            available(&owner);
            let mut effects = FixtureEffects::new(&owner);
            assert!(matches!(
                download(&owner, &effects, NOW).unwrap().state,
                State::AwaitingConsent { .. }
            ));
            effects.cancel_in_validation = phase == "cancel";
            effects.fail_validation = phase == "invalid";
            effects.cancel_in_reveal = phase == "lateCancel";
            effects.fail_reveal = phase == "revealError";
            let before = owner.store.load(NOW).unwrap();
            let result = handoff(&owner, &effects, phase != "noConsent", NOW);
            let after = owner.store.load(NOW).unwrap();
            if matches!(phase, "success" | "lateCancel") {
                assert!(matches!(result.unwrap().state, State::HandedOff { .. }));
                assert!(matches!(after.state, State::HandedOff { .. }));
                assert!(!after.cancellation_requested);
                assert_eq!(effects.reveals.get(), 1);
            } else {
                assert!(result.is_err());
                assert_eq!(effects.reveals.get(), usize::from(phase == "revealError"));
                if phase == "noConsent" {
                    assert_eq!(before, after);
                } else if phase == "cancel" {
                    assert!(matches!(after.state, State::Cancelled {}));
                } else {
                    assert!(matches!(
                        after.state,
                        State::Failed {
                            code: Failure::Handoff
                        }
                    ));
                }
                if phase == "revealError" {
                    assert_eq!(std::fs::read_dir(root.0.join("cache")).unwrap().count(), 0);
                    assert!(handoff(&owner, &effects, true, NOW).is_err());
                    assert_eq!(effects.reveals.get(), 1);
                }
            }
        }
    }
    #[test]
    fn long_download_and_late_handoff_cancel_use_write_time_not_request_time() {
        use std::sync::{
            Arc,
            atomic::{AtomicU64, Ordering},
        };
        let (_root, mut owner) = setup();
        let tick = Arc::new(AtomicU64::new(0));
        let tick_read = tick.clone();
        owner.store = owner.store.with_clock(move || {
            format!("2026-09-26T00:00:{:02}Z", tick_read.load(Ordering::SeqCst))
        });
        available(&owner);
        let mut effects = FixtureEffects::new(&owner);
        effects.clock = Some(tick.clone());
        let downloaded = download(&owner, &effects, NOW).unwrap();
        assert_eq!(downloaded.updated_at_utc, "2026-09-26T00:00:01Z");
        tick.store(2, Ordering::SeqCst);
        effects.cancel_in_reveal = true;
        let handed_off = handoff(&owner, &effects, true, NOW).unwrap();
        assert!(matches!(handed_off.state, State::HandedOff { .. }));
        assert_eq!(handed_off.updated_at_utc, "2026-09-26T00:00:04Z");
        assert_eq!(owner.store.load(NOW).unwrap(), handed_off);
        assert_eq!(effects.reveals.get(), 1);
    }

    #[test]
    fn lost_state_after_observed_reveal_does_not_replay_external_effect() {
        let (_root, owner) = setup();
        available(&owner);
        let mut effects = FixtureEffects::new(&owner);
        download(&owner, &effects, NOW).unwrap();
        effects.remove_state_after_reveal = true;
        assert!(matches!(
            handoff(&owner, &effects, true, NOW),
            Err(ConsumerError::Operation(OperationError::Store(
                super::super::StoreError::RecordUnreadable
            )))
        ));
        assert_eq!(effects.reveals.get(), 1);
        assert!(handoff(&owner, &effects, true, NOW).is_err());
        assert_eq!(effects.reveals.get(), 1);
    }
}
