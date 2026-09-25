//! `job.plan` of the ArkForge Flash operations through the production Host
//! and Control, in each composition the daemon can start in. The Artifact
//! root and Target store of the Swift Flash plan oracle
//! (`rust/tests/fixtures/flash-plan`) are laid down, so the requests name the
//! flash bundle Swift's Import committed there. Each composition's answer is
//! the one Swift's daemon gives in the same composition; the plans themselves
//! are replayed against Swift in `arkdeck-hoststore` (`tests/flash_plan.rs`).
//! Nothing is admitted: `job.submit` still refuses a Flash operation.
use arkdeck_contract::{CONTRACT_IDENTITY, PROTOCOL_VERSION};
use arkdeck_control::Control;
use arkdeck_hoststore::{
    ArtifactReadStore, FlashHostFacts, FlashPlanning, ImportUploadStore, JobStore,
    NativeRockUsbIdentity, TargetStore,
};
use serde_json::{Value, json};
use std::fs;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
use std::path::{Path, PathBuf};

fn fixtures() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/flash-plan")
}

struct Root(PathBuf);

impl Root {
    /// The oracle's Artifact root and Target store, laid down as Swift left
    /// them, beside an empty Job state.
    fn new() -> Self {
        let root = std::env::temp_dir().canonicalize().unwrap().join(format!(
            "flash-plan-control-{:x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap())
        ));
        for name in ["artifacts", "targets", "state", "jobs"] {
            directory(&root.join(name));
        }
        let cases = cases();
        for input in cases["inputs"].as_array().unwrap() {
            let path = input["path"].as_str().unwrap();
            let (source, destination) = match path.strip_prefix("../targets/") {
                Some(target) => (
                    fixtures().join("inputs/targets").join(target),
                    root.join("targets").join(target),
                ),
                None => (
                    fixtures().join("inputs/artifacts").join(path),
                    root.join("artifacts").join(path),
                ),
            };
            directory(destination.parent().unwrap());
            fs::write(&destination, fs::read(source).unwrap()).unwrap();
            let mode = u32::from_str_radix(input["mode"].as_str().unwrap(), 8).unwrap();
            fs::set_permissions(&destination, fs::Permissions::from_mode(mode)).unwrap();
        }
        Self(root)
    }

    /// The Host every composition below starts from: the Target, Artifact,
    /// Import and Job owners and the planner over the Job state.
    fn host(&self) -> crate::host::Host {
        crate::host::Host::from_environment()
            .with_targets(TargetStore::open(&self.0.join("targets")).unwrap())
            .with_artifacts(ArtifactReadStore::open(&self.0.join("artifacts")).unwrap())
            .with_imports(ImportUploadStore::open(&self.0.join("artifacts")).unwrap())
            .with_jobs(JobStore::open_owner(&self.0.join("jobs")).unwrap())
            .with_planning(&self.0.join("state"), None)
    }

    /// Swift's Rockchip facts over this root, the census reading no device.
    fn facts(&self, rockusb: NativeRockUsbIdentity) -> FlashHostFacts {
        FlashHostFacts::new(&self.0, || Ok(Vec::new())).with_rockusb(rockusb)
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

fn cases() -> Value {
    serde_json::from_slice(&fs::read(fixtures().join("cases.json")).unwrap()).unwrap()
}

/// The request the oracle recorded for `exchange`.
fn request(exchange: &str) -> String {
    cases()["exchanges"]
        .as_array()
        .unwrap()
        .iter()
        .find(|recorded| recorded["name"] == exchange)
        .unwrap()["requestJson"]
        .as_str()
        .unwrap()
        .to_owned()
}

fn call(control: &Control<crate::host::Host>, method: &str, request: &str) -> Value {
    serde_json::from_slice(
        &control.handle_frame(
            &serde_json::to_vec(&json!({
                "protocolVersion": PROTOCOL_VERSION, "contractIdentity": CONTRACT_IDENTITY,
                "id": "flash-plan-control", "method": method,
                "params": {"requestJson": request},
            }))
            .unwrap(),
        ),
    )
    .unwrap()
}

/// A refusal before admission: its code and message, and zero dispatch.
fn refused(reply: &Value, code: &str, message: &str) {
    assert_eq!(reply["ok"], false, "{reply}");
    assert_eq!(reply["error"]["code"], code, "{reply}");
    assert_eq!(reply["error"]["message"], message, "{reply}");
    assert_eq!(
        reply["error"]["details"],
        json!({"phase": "preAdmission", "newDispatchCount": 0}),
        "{reply}"
    );
}

/// A lane that may flash, as the daemon composes its planning over the
/// Job state; its toolchain is the oracle's.
fn available(root: &Root, rockusb: &NativeRockUsbIdentity, hdc: bool) -> FlashPlanning {
    crate::arkforge_lane::flash_planning(
        None,
        Some("c".repeat(64)),
        rockusb.clone(),
        &root.0.join("state"),
        hdc,
    )
}

/// A Control over `host`; each composition below drops its own before the
/// next opens the same owners, whose locks are exclusive.
fn control(host: crate::host::Host) -> Control<crate::host::Host> {
    Control::new(host).unwrap()
}

#[test]
fn a_flash_plan_is_answered_as_swifts_daemon_answers_it_in_each_composition() {
    let root = Root::new();
    let canonical = request("canonical.full");
    let alias = request("alias.full");
    let daemon = root.0.join("arkforged");
    fs::write(&daemon, b"#!/bin/sh\nexit 0\n").unwrap();
    fs::set_permissions(&daemon, fs::Permissions::from_mode(0o755)).unwrap();
    let rockusb = NativeRockUsbIdentity::configured(
        Some(daemon.to_string_lossy().into_owned()),
        Some(arkdeck_contract::sha256_hex(b"#!/bin/sh\nexit 0\n")),
    );
    let unconfigured = NativeRockUsbIdentity::unconfigured();

    // No Flash composition: the planner's own refusal, as before.
    {
        let control = control(root.host());
        refused(
            &call(&control, "job.plan", &canonical),
            "rejected",
            "flash.full-restore@1 is not materialized by the Rust Runtime yet",
        );
    }

    // No lane, the environment naming no bundle: Swift's absence, for the
    // canonical operation and for its alias under its own reference.
    {
        let state = root.0.join("state");
        let absent = crate::arkforge_lane::compose(&state, |_| None, None);
        assert!(absent.lane.is_err());
        let control = control(
            root.host()
                .with_flash_planning(absent.planning(&state, false)),
        );
        let absence = arkdeck_provider_arkforge::Absence::NotConfigured;
        refused(
            &call(&control, "job.plan", &canonical),
            "invalidInput",
            &format!("flash.full-restore@1 is runtime unavailable: {absence}"),
        );
        refused(
            &call(&control, "job.plan", &alias),
            "invalidInput",
            &format!("flash.dayu200 is runtime unavailable: {absence}"),
        );
        // An alias request whose partition plan is not the profile's cannot be
        // converted, which fails before anything else is read, as Swift's.
        refused(
            &call(&control, "job.plan", &request("alias.reorderedPlan")),
            "internalError",
            "the Runtime could not complete the Job lifecycle request",
        );
    }

    // A lane that may flash: Swift's dispatcher refuses without the
    // configured `arkforged`, then without a descriptor-bound HDC.
    {
        let control = control(root.host().with_flash_planning(available(
            &root,
            &unconfigured,
            true,
        )));
        refused(
            &call(&control, "job.plan", &canonical),
            "invalidInput",
            "flash.full-restore@1 is runtime unavailable: ArkForge native RockUSB identity is \
             unavailable: failed(\"ArkForge native RockUSB lane is not configured\")",
        );
    }
    {
        let control = control(
            root.host()
                .with_flash_planning(available(&root, &rockusb, false)),
        );
        refused(
            &call(&control, "job.plan", &alias),
            "invalidInput",
            "flash.dayu200 is runtime unavailable: the per-action RockUSB host requires \
             descriptor-bound HDC and a product state directory",
        );
    }
    assert!(!root.0.join("state/rockchip-runtime").exists());

    // With one, the dispatcher prepares its record root beside the Job
    // state; without the facts port, Swift's adapter without one refuses.
    {
        let control = control(
            root.host()
                .with_flash_planning(available(&root, &rockusb, true)),
        );
        refused(
            &call(&control, "job.plan", &canonical),
            "invalidInput",
            "target facts cannot materialize the typed plan before authorization: production \
             ArkForge target facts are not registered",
        );
    }
    let records = fs::symlink_metadata(root.0.join("state/rockchip-runtime")).unwrap();
    assert!(records.is_dir());
    assert_eq!(records.mode() & 0o7777, 0o700);

    // The facts port over the Host's Target store, which measures its own
    // `arkforged`: none configured.
    {
        let control = control(
            root.host()
                .with_flash_planning(available(&root, &rockusb, true))
                .with_flash_host_facts(root.facts(unconfigured.clone())),
        );
        refused(
            &call(&control, "job.plan", &canonical),
            "invalidInput",
            "target facts cannot materialize the typed plan before authorization: ArkForge \
             native RockUSB identity is unavailable: failed(\"ArkForge native RockUSB lane is \
             not configured\")",
        );
    }

    // The configured `arkforged` measured: the facts are the adopted board's,
    // the bundle's lease resolves against them, and the plan stops where
    // Swift's does for a board no Rockchip binding covers, at the post-flash
    // reconnect that has no expectation.
    let control = control(
        root.host()
            .with_flash_planning(available(&root, &rockusb, true))
            .with_flash_host_facts(root.facts(rockusb.clone())),
    );
    for request in [&canonical, &alias] {
        refused(
            &call(&control, "job.plan", request),
            "invalidInput",
            "typed plan preflight failed before authorization: post-flash HDC binding \
             expectation is absent or malformed",
        );
    }

    // Planning a Flash admits nothing: admission still refuses it before it
    // is admitted.
    refused(
        &call(&control, "job.submit", &canonical),
        "rejected",
        "flash.full-restore@1 is not materialized by the Rust Runtime yet",
    );
}
