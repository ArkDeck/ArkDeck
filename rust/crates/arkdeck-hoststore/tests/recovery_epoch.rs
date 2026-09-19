//! Replays the shared superseding-recovery-epoch oracle (`rust/tests/fixtures/
//! recovery-epoch`, recorded by Swift `RecoveryEpochOracleContractTests`)
//! against the Rust store: every step applied as Swift applied it, every
//! answer given as Swift gave it, and after every step the root holding
//! exactly the files Swift left — the same names, modes, link counts, sizes
//! and bytes. Each root is a scratch directory; nothing touches the installed
//! Application Support tree.
#![cfg(target_os = "macos")]

use arkdeck_contract::sha256_hex;
use arkdeck_hoststore::{
    RECOVERY_EPOCH_DOCUMENT, RECOVERY_EPOCH_LOCK, RecoveryEpochDraft, RecoverySource,
    SupersededIntent, append_recovery_epoch, list_recovery_epochs,
};
use arkdeck_platform::{HostDirectory, random_bytes};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::{MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};

fn fixture() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/recovery-epoch")
}

struct Scratch(PathBuf);

impl Scratch {
    fn new() -> Self {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "arkdeck-recovery-epoch-{:032x}",
            u128::from_le_bytes(random_bytes().unwrap())
        ));
        fs::create_dir(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        Self(root)
    }

    fn root(&self, name: &str) -> PathBuf {
        let root = self.0.join(name);
        fs::create_dir(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        root
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn text(value: &Value, key: &str) -> String {
    value[key]
        .as_str()
        .unwrap_or_else(|| panic!("{key} in {value}"))
        .to_owned()
}

fn texts(value: &Value, key: &str) -> Vec<String> {
    value[key]
        .as_array()
        .unwrap_or_else(|| panic!("{key} in {value}"))
        .iter()
        .map(|item| item.as_str().unwrap().to_owned())
        .collect()
}

/// A draft as the oracle spells it.
fn draft(value: &Value) -> RecoveryEpochDraft {
    RecoveryEpochDraft {
        source: match value["source"].as_str().unwrap() {
            "historicalRecognition" => RecoverySource::HistoricalRecognition,
            "distinctRecoveryExecution" => RecoverySource::DistinctRecoveryExecution,
            other => panic!("source {other}"),
        },
        stable_target_identity_sha256: text(value, "stableTargetIdentitySHA256"),
        binding_revision: value["bindingRevision"].as_i64().unwrap(),
        covered_intents: value["coveredIntents"]
            .as_array()
            .unwrap()
            .iter()
            .map(|intent| SupersededIntent {
                job_id: text(intent, "jobID"),
                intent_event_id: text(intent, "intentEventID"),
                operation_reference: text(intent, "operationReference"),
                profile_reference: text(intent, "profileReference"),
                observed_at_utc: text(intent, "observedAtUTC"),
                possible_effects: texts(intent, "possibleEffects"),
            })
            .collect(),
        uncertain_effect_set_sha256: text(value, "uncertainEffectSetSHA256"),
        coverage_contract_version: text(value, "coverageContractVersion"),
        covered_effect_set_sha256: text(value, "coveredEffectSetSHA256"),
        recovery_job_id: text(value, "recoveryJobID"),
        recovery_intent_event_id: text(value, "recoveryIntentEventID"),
        operation_reference: text(value, "operationReference"),
        profile_reference: text(value, "profileReference"),
        materialized_plan_digest_sha256: text(value, "materializedPlanDigestSHA256"),
        artifact_sha256: text(value, "artifactSHA256"),
        provider_executable_sha256: text(value, "providerExecutableSHA256"),
        confirmed_step_ids: texts(value, "confirmedStepIDs"),
        resulting_target_epoch_sha256: text(value, "resultingTargetEpochSHA256"),
        established_at_utc: text(value, "establishedAtUTC"),
    }
}

/// The root's files as the oracle records them.
fn files(root: &Path) -> BTreeMap<String, Value> {
    fs::read_dir(root)
        .unwrap()
        .map(|entry| {
            let entry = entry.unwrap();
            let metadata = fs::symlink_metadata(entry.path()).unwrap();
            let bytes = fs::read(entry.path()).unwrap();
            (
                entry.file_name().into_string().unwrap(),
                json!({
                    "mode": format!("{:o}", metadata.mode() & 0o7777),
                    "links": metadata.nlink(),
                    "bytes": bytes.len(),
                    "sha256": sha256_hex(&bytes),
                }),
            )
        })
        .collect()
}

/// The oracle's record of a step's root, without the path of each stored
/// copy.
fn recorded(step: &Value) -> BTreeMap<String, Value> {
    step["root"]
        .as_object()
        .unwrap()
        .iter()
        .map(|(name, entry)| {
            let mut entry = entry.clone();
            entry.as_object_mut().unwrap().remove("file");
            (name.clone(), entry)
        })
        .collect()
}

fn stored(step: &Value, name: &str) -> Option<Vec<u8>> {
    let path = step["root"][name]["file"].as_str()?;
    Some(fs::read(fixture().join(path)).unwrap())
}

#[test]
fn the_store_answers_and_leaves_the_files_swift_left() {
    let cases: Vec<Value> =
        serde_json::from_slice(&fs::read(fixture().join("cases.json")).unwrap()).unwrap();
    assert!(cases.len() >= 32, "{} steps", cases.len());
    let scratch = Scratch::new();
    let mut roots: BTreeMap<String, PathBuf> = BTreeMap::new();
    for step in &cases {
        let name = text(step, "name");
        let input = &step["input"];
        let store = text(step, "store");
        let seed = &step["seed"];
        let root = if seed.is_null() {
            // The main store, or a root an earlier step seeded.
            roots
                .entry(store.clone())
                .or_insert_with(|| scratch.root(&store))
                .clone()
        } else {
            // A root of its own, seeded as Swift seeded it: the document the
            // named step recorded (a list writes nothing, so a listed step's
            // own record is its seed), then any widened mode, hard link,
            // padding or open lock.
            let root = scratch.root(&store);
            roots.insert(store.clone(), root.clone());
            let source = cases
                .iter()
                .find(|candidate| candidate["name"] == seed["document"])
                .unwrap_or_else(|| panic!("{name}: seed {seed}"));
            let mut bytes = stored(source, RECOVERY_EPOCH_DOCUMENT)
                .unwrap_or_else(|| panic!("{name}: no recorded seed document"));
            if let Some(size) = seed["appendSpacesTo"].as_u64() {
                bytes.resize(size as usize, b' ');
            }
            let document = root.join(RECOVERY_EPOCH_DOCUMENT);
            fs::write(&document, &bytes).unwrap();
            fs::set_permissions(&document, fs::Permissions::from_mode(0o600)).unwrap();
            if let Some(mode) = seed["documentMode"].as_str() {
                let mode = u32::from_str_radix(mode, 8).unwrap();
                fs::set_permissions(&document, fs::Permissions::from_mode(mode)).unwrap();
            }
            if let Some(link) = seed["hardLink"].as_str() {
                fs::hard_link(&document, root.join(link)).unwrap();
            }
            if let Some(mode) = seed["lockMode"].as_str() {
                let lock = root.join(RECOVERY_EPOCH_LOCK);
                fs::write(&lock, b"").unwrap();
                let mode = u32::from_str_radix(mode, 8).unwrap();
                fs::set_permissions(&lock, fs::Permissions::from_mode(mode)).unwrap();
            }
            root
        };
        let directory = HostDirectory::open(&root).unwrap();
        let outcome = match text(step, "operation").as_str() {
            "list" => match list_recovery_epochs(&directory) {
                Ok(epochs) => {
                    json!({"epochs": epochs.iter().map(|epoch| epoch.to_value()).collect::<Vec<_>>()})
                }
                Err(error) => json!({"refused": error.kind()}),
            },
            "append" => match append_recovery_epoch(&directory, &draft(input)) {
                Ok(epoch) => json!({"epoch": epoch.to_value()}),
                Err(arkdeck_hoststore::RecoveryEpochError::ConflictingEpoch(epoch)) => {
                    json!({"refused": "conflictingEpoch", "epochId": epoch})
                }
                Err(error) => json!({"refused": error.kind()}),
            },
            other => panic!("operation {other}"),
        };
        assert_eq!(outcome, step["outcome"], "{name}");
        assert_eq!(files(&root), recorded(step), "{name}");
        for (file, _) in recorded(step) {
            if let Some(bytes) = stored(step, &file) {
                assert_eq!(fs::read(root.join(&file)).unwrap(), bytes, "{name}: {file}");
            }
        }
    }
}

/// The store the Job owner reads: a later reader in another store instance
/// sees the chain as it was written, and appending the same relation to it
/// again writes nothing.
#[test]
fn a_reopened_store_continues_the_chain_it_finds() {
    let cases: Vec<Value> =
        serde_json::from_slice(&fs::read(fixture().join("cases.json")).unwrap()).unwrap();
    let step = |name: &str| {
        cases
            .iter()
            .find(|step| step["name"] == name)
            .unwrap()
            .clone()
    };
    let scratch = Scratch::new();
    let root = scratch.root("reopened");
    let first = draft(&step("append-first")["input"]);
    let second = draft(&step("append-second")["input"]);
    {
        let directory = HostDirectory::open(&root).unwrap();
        append_recovery_epoch(&directory, &first).unwrap();
    }
    let directory = HostDirectory::open(&root).unwrap();
    let chained = append_recovery_epoch(&directory, &second).unwrap();
    assert_eq!(
        json!({"epoch": chained.to_value()}),
        step("append-second")["outcome"]
    );
    let before = fs::read(root.join(RECOVERY_EPOCH_DOCUMENT)).unwrap();
    assert_eq!(
        Some(before.clone()),
        stored(&step("list-two"), RECOVERY_EPOCH_DOCUMENT)
    );
    append_recovery_epoch(&directory, &first).unwrap();
    assert_eq!(
        fs::read(root.join(RECOVERY_EPOCH_DOCUMENT)).unwrap(),
        before
    );
    assert_eq!(list_recovery_epochs(&directory).unwrap().len(), 2);
}
