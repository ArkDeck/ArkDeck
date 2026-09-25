//! The Swift Flash `job.plan` oracle (`rust/tests/fixtures/flash-plan`,
//! recorded by `FlashPlanOracleContractTests`) replayed through the Rust
//! planner. The Artifact root Swift's Import left, the flash bundle's lease
//! among it, is laid down as recorded. Each exchange's scripted
//! availability, dispatcher reason, lane toolchain and facts are composed as
//! it names them. Every answer, the plan document's digest included, must be
//! Swift's; so must the reason Swift's own Rockchip dispatcher gives.
#![cfg(target_os = "macos")]

use arkdeck_hoststore::{
    ArtifactReadStore, FlashPlanner, FlashPlanning, ImportUploadStore, JobPlanner,
    NativeRockUsbIdentity, RockchipFacts, rockchip_dispatch_unavailable,
};
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/flash-plan")
}

struct Root(PathBuf);

impl Root {
    fn new() -> Self {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "arkdeck-flash-plan-{:x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        Self(root)
    }
}

impl Drop for Root {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn directory(path: &Path) {
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(path)
        .unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o700)).unwrap();
}

/// The Artifact root and Target store as Swift's Import left them.
fn lay_down(root: &Path, cases: &Value) {
    let artifacts = root.join("artifacts");
    directory(&artifacts);
    for input in cases["inputs"].as_array().unwrap() {
        let path = input["path"].as_str().unwrap();
        let (source, destination) = match path.strip_prefix("../targets/") {
            Some(target) => (
                fixtures().join("inputs/targets").join(target),
                root.join("targets").join(target),
            ),
            None => (
                fixtures().join("inputs/artifacts").join(path),
                artifacts.join(path),
            ),
        };
        directory(destination.parent().unwrap());
        fs::write(&destination, fs::read(source).unwrap()).unwrap();
        let mode = u32::from_str_radix(input["mode"].as_str().unwrap(), 8).unwrap();
        fs::set_permissions(&destination, fs::Permissions::from_mode(mode)).unwrap();
    }
}

/// The exchange's scripted Flash composition.
fn planning(setup: &Value) -> FlashPlanning {
    let text = |value: &Value| value.as_str().map(str::to_owned);
    let dispatch = text(&setup["dispatchUnavailable"]);
    FlashPlanning::new(
        text(&setup["unavailable"]),
        move || dispatch.clone(),
        text(&setup["toolchainSha256"]),
    )
}

/// The exchange's scripted facts port answer.
fn facts(setup: &Value, target: &str) -> Result<RockchipFacts, String> {
    let facts = &setup["facts"];
    if let Some(error) = facts["error"].as_str() {
        return Err(error.to_owned());
    }
    Ok(RockchipFacts {
        target_id: target.to_owned(),
        binding_revision: facts["bindingRevision"].as_i64().unwrap(),
        identity_sha256: facts["deviceIdentitySha256"].as_str().unwrap().into(),
        tool_sha256: facts["toolSha256"].as_str().unwrap().into(),
        execution_connect_key: facts["executionConnectKey"].as_str().unwrap().into(),
        device_mode: "hdc".into(),
        build_fingerprint: None,
        profile_id: "dayu200".into(),
        server_facts: facts["serverFacts"]
            .as_object()
            .unwrap()
            .iter()
            .map(|(key, value)| (key.clone(), value.as_str().unwrap().to_owned()))
            .collect::<BTreeMap<_, _>>(),
    })
}

#[test]
fn every_flash_plan_is_swifts() {
    let cases: Value =
        serde_json::from_slice(&fs::read(fixtures().join("cases.json")).unwrap()).unwrap();
    let root = Root::new();
    lay_down(&root.0, &cases);
    let artifacts = ArtifactReadStore::open(&root.0.join("artifacts")).unwrap();
    let imports = ImportUploadStore::open(&root.0.join("artifacts")).unwrap();
    let state = root.0.join("state");
    directory(&state);
    let target = cases["targetId"].as_str().unwrap();
    let exchanges = cases["exchanges"].as_array().unwrap();
    assert_eq!(exchanges.len(), 23);
    for exchange in exchanges {
        let name = exchange["name"].as_str().unwrap();
        let flash = planning(&exchange["setup"]);
        let port = |_: &str| facts(&exchange["setup"], target);
        let planner = FlashPlanner {
            planner: JobPlanner {
                artifacts: Some(&artifacts),
                imports: Some(&imports),
                analyzer: None,
                state_root: &state,
                hdc: None,
                workspace: None,
            },
            flash: Some(&flash),
            facts: Some(&port),
        };
        let answer = match planner.plan(exchange["requestJson"].as_str().unwrap().as_bytes()) {
            Ok(mut result) => {
                // The additive step-set provenance (#2121) is not in the
                // retained Swift wire answer; its helper is checked apart.
                let digest = result
                    .as_object_mut()
                    .unwrap()
                    .remove("stepSetDigestSHA256")
                    .unwrap();
                assert!(
                    digest.as_str().is_some_and(|digest| digest.len() == 64
                        && digest
                            .bytes()
                            .all(|b| b.is_ascii_hexdigit() && !b.is_ascii_uppercase())),
                    "{name}"
                );
                json!({"ok": true, "result": result})
            }
            Err(refusal) => json!({"ok": false, "error": {
                "code": refusal.code, "message": refusal.message}}),
        };
        let recorded = &exchange["answer"];
        if recorded["ok"] == true {
            assert_eq!(answer, *recorded, "{name}");
        } else {
            assert_eq!(answer["error"]["code"], recorded["error"]["code"], "{name}");
            assert_eq!(
                answer["error"]["message"], recorded["error"]["message"],
                "{name}"
            );
        }
    }
}

/// Swift's Rockchip dispatcher (`dispatch.json`) replayed through the Rust
/// port over the same record-root states: every reason, and an absent root
/// created owner-only.
///
/// `records.privatePrefix` is the declared difference. Swift's canonical
/// check standardizes an existing `/private/tmp/…` path to `/tmp/…` and so
/// refuses an owner-only root there once it exists; this Runtime judges the
/// path's own components and accepts it, which an isolated owner below
/// `/private/tmp` needs from its second plan on.
#[test]
fn every_dispatcher_reason_is_swifts() {
    let cases: Value =
        serde_json::from_slice(&fs::read(fixtures().join("dispatch.json")).unwrap()).unwrap();
    let root = Root::new();
    let daemon = root.0.join("arkforged");
    let bytes = b"#!/bin/sh\nexit 0\n";
    fs::write(&daemon, bytes).unwrap();
    fs::set_permissions(&daemon, fs::Permissions::from_mode(0o755)).unwrap();
    let configured = NativeRockUsbIdentity::configured(
        Some(daemon.to_string_lossy().into_owned()),
        Some(arkdeck_contract::sha256_hex(bytes)),
    );
    let cases = cases.as_array().unwrap();
    assert_eq!(cases.len(), 10);
    for case in cases {
        let name = case["name"].as_str().unwrap();
        let identity = if case["identityConfigured"] == true {
            configured.clone()
        } else {
            NativeRockUsbIdentity::unconfigured()
        };
        let records = case["records"].as_str().map(|records| {
            let state = root.0.join(name);
            if records != "stateMissing" {
                fs::DirBuilder::new().mode(0o700).create(&state).unwrap();
            }
            let path = state.join("rockchip-runtime");
            match records {
                "ownerOnly" | "groupReadable" => {
                    fs::DirBuilder::new().mode(0o700).create(&path).unwrap();
                    let mode = if records == "ownerOnly" { 0o700 } else { 0o750 };
                    fs::set_permissions(&path, fs::Permissions::from_mode(mode)).unwrap();
                }
                "symlink" => {
                    let elsewhere = state.join("elsewhere");
                    fs::DirBuilder::new()
                        .mode(0o700)
                        .create(&elsewhere)
                        .unwrap();
                    std::os::unix::fs::symlink(&elsewhere, &path).unwrap();
                }
                "file" | "ownerOnlyFile" => {
                    fs::write(&path, b"not a directory").unwrap();
                    if records == "ownerOnlyFile" {
                        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
                    }
                }
                _ => {}
            }
            path
        });
        let reason = rockchip_dispatch_unavailable(&identity, records.as_deref());
        if name == "records.privatePrefix" {
            assert!(root.0.starts_with("/private/"), "{}", root.0.display());
            assert_eq!(
                case["reason"],
                "durable Rockchip host record root is unavailable: \
                 failed(\"Rockchip record path is not canonical\")"
            );
            assert_eq!(reason, None, "{name}");
            continue;
        }
        assert_eq!(reason.as_deref(), case["reason"].as_str(), "{name}");
        if let Some(mode) = case["createdMode"].as_str() {
            let metadata = fs::symlink_metadata(records.unwrap()).unwrap();
            assert!(metadata.is_dir(), "{name}");
            assert_eq!(format!("{:o}", metadata.mode() & 0o7777), mode, "{name}");
        }
    }
}
