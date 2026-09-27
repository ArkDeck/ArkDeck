#![cfg(target_os = "macos")]
//! Actual Swift facade outcomes, replayed through Rust's consumer with the same
//! fixture effect boundaries. No production request or Finder invocation.
use arkdeck_cli::runtime_update::*;
use serde_json::{Value, json};
use std::{
    cell::{Cell, RefCell},
    path::{Path, PathBuf},
};

const NOW: &str = "2026-09-26T00:00:00Z";
struct Root(PathBuf);
impl Drop for Root {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
struct Fixture<'a> {
    owner: &'a Owner,
    scenario: &'a str,
    reveals: Cell<u64>,
    validations: Cell<u64>,
    events: RefCell<Vec<&'static str>>,
}
impl RuntimeUpdateEffects for Fixture<'_> {
    fn attempt(&self, _: &str) -> Result<(), ConsumerError> {
        panic!("no feed check")
    }
    fn check(
        &self,
        _: &ProductIdentity,
        _: &str,
        _: &(dyn Fn() -> bool + Sync),
    ) -> Result<State, ConsumerError> {
        panic!("preseeded available state")
    }
    fn download(
        &self,
        cache: &Cache,
        feed: &Feed,
        cancel: &(dyn Fn() -> bool + Sync),
    ) -> Result<DownloadedArtifact, ConsumerError> {
        assert!(!cancel());
        let mut writer = cache
            .begin_download(feed.payload.artifact.byte_length)
            .map_err(ConsumerError::Download)?;
        match self.scenario {
            "downloadFailure" => {
                return Err(ConsumerError::Network(NetworkError::Transport(-1005)));
            }
            "downloadOverflow" => writer
                .write_chunk(b"abc\0")
                .map_err(ConsumerError::Download)?,
            "downloadCancelled" => {
                self.owner.store.request_cancellation(NOW).unwrap();
                assert!(cancel());
                return Err(OperationError::Cancelled.into());
            }
            _ => writer
                .write_chunk(b"abc")
                .map_err(ConsumerError::Download)?,
        }
        writer
            .seal(&feed.payload.artifact.sha256)
            .map_err(ConsumerError::Download)
    }
    fn validate(
        &self,
        cache: &Cache,
        artifact: &DownloadedArtifact,
    ) -> Result<ValidatedArtifact, ConsumerError> {
        self.validations.set(self.validations.get() + 1);
        if self.scenario == "validationFailure" {
            return Err(ConsumerError::Artifact(ArtifactFailure::ArtifactReplaced));
        }
        cache
            .verify_download(artifact)
            .map_err(ConsumerError::Download)?;
        Ok(ValidatedArtifact {
            downloaded: artifact.clone(),
            team_identifier: "ABCDEFGHIJ".into(),
        })
    }
    fn reveal(&self, path: &Path) -> Result<(), ConsumerError> {
        assert_eq!(std::fs::read(path).unwrap(), b"abc");
        self.reveals.set(self.reveals.get() + 1);
        if self.scenario == "lateCancel" {
            self.owner.store.request_cancellation(NOW).unwrap();
        }
        if self.scenario == "revealFailure" {
            return Err(ConsumerError::Handoff);
        }
        Ok(())
    }
    fn event(&self, event: RuntimeUpdateEvent) {
        self.events.borrow_mut().push(match event {
            RuntimeUpdateEvent::CheckStarted => "checkStarted",
            RuntimeUpdateEvent::Available => "available",
            RuntimeUpdateEvent::NoUpdate => "noUpdate",
            RuntimeUpdateEvent::DownloadStarted => "downloadStarted",
            RuntimeUpdateEvent::VerificationStarted => "verificationStarted",
            RuntimeUpdateEvent::Failed => "failed",
            RuntimeUpdateEvent::Cancelled => "cancelled",
            RuntimeUpdateEvent::HandedOff => "handedOff",
        });
    }
}

#[test]
fn actual_swift_download_handoff_and_no_replay_outcomes() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../tests/fixtures/runtime-update-network/consumer.json"
    ))
    .unwrap();
    let encoded = fixture["feedBase64"].as_str().unwrap();
    let padding = encoded.bytes().rev().take_while(|b| *b == b'=').count();
    let bytes =
        arkdeck_contract::decode_import_chunk(encoded, (encoded.len() / 4 * 3 - padding) as u64)
            .unwrap();
    let feed: Feed = serde_json::from_slice(&bytes).unwrap();
    for row in fixture["cases"].as_array().unwrap() {
        let scenario = row["name"].as_str().unwrap();
        let root = Root(std::env::temp_dir().join(format!(
            "arkdeck-network-oracle-{}",
            arkdeck_cli::client_frame_id()
        )));
        let owner = Owner {
            store: Store::new(root.0.join("state")),
            cache: Cache::new(root.0.join("cache")),
        };
        owner.store.load(NOW).unwrap();
        owner
            .store
            .replace(0, State::Available { feed: feed.clone() }, None, false, NOW)
            .unwrap();
        let effects = Fixture {
            owner: &owner,
            scenario,
            reveals: Cell::new(0),
            validations: Cell::new(0),
            events: RefCell::new(Vec::new()),
        };
        for expected in row["steps"].as_array().unwrap() {
            let action = expected["action"].as_str().unwrap();
            let result = if action == "download" {
                download_update(&owner, &effects, NOW)
            } else {
                handoff_update(&owner, &effects, scenario != "noConsent", NOW)
            };
            let projection = owner.store.load(NOW).unwrap().projection();
            let names: Vec<String> = std::fs::read_dir(root.0.join("cache"))
                .unwrap()
                .map(|e| e.unwrap().file_name().into_string().unwrap())
                .collect();
            let actual = json!({
                "action": action, "succeeded": result.is_ok(),
                "generation": projection["generation"], "phase": projection["phase"],
                "isBusy": projection["isBusy"], "cancellationRequested": projection["cancellationRequested"],
                "failureCode": projection["failureCode"], "updatedAtUtc": projection["updatedAtUtc"],
                "reveals": effects.reveals.get(), "validations": effects.validations.get(),
                "artifacts": names.iter().filter(|n| n.ends_with(".dmg")).count(),
                "partials": names.iter().filter(|n| n.ends_with(".part")).count(),
                "events": *effects.events.borrow(),
            });
            assert_eq!(&actual, expected, "{scenario}/{action}");
        }
    }
}
