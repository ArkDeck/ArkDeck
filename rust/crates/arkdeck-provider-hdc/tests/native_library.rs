//! Swift's `deploy.native-library.app-owned@1` oracle
//! (`rust/tests/fixtures/deploy-native-library`, recorded by
//! `NativeLibraryOracleContractTests` over the shared fake HDC driver)
//! replayed by `NativeAction`: the five Jobs driven step by step as Swift's
//! engine drove them — the deployment, the loader failure with its rollback
//! and compensation, the missing app-owned directory with its compensation,
//! the unattested publish, the cleanup that leaves debt with its readback —
//! and the debt continuation, every verdict checked and every argv the
//! driver logged compared with the oracle's 225 recorded lines.
#![cfg(target_os = "macos")]

mod common;

use arkdeck_provider_hdc::{
    CodeSignHelper, CodeSignHelperFacts, Deployment, HdcDispatch, NativeAbi, NativeAction, Outcome,
    Reconcile, ResolvedArtifact, run,
};
use common::{CONNECT_KEY, SharedFake};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

const LIBRARY_ARTIFACT: &str = "ART-469c10579b3c5461ab4d0a891c316397";

fn oracle() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/deploy-native-library")
}

fn read_json(path: &Path) -> Value {
    serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
}

fn string(value: &Value, key: &str) -> String {
    value[key].as_str().unwrap().to_owned()
}

fn logged(fake: &SharedFake) -> Vec<String> {
    String::from_utf8(fake.invocations())
        .unwrap()
        .lines()
        .map(str::to_owned)
        .collect()
}

fn verified_summary<'a>(outcome: &'a Outcome, step: &str) -> &'a BTreeMap<String, String> {
    match outcome {
        Outcome::Verified(summary) => summary,
        other => panic!("{step}: expected a verified outcome, got {other:?}"),
    }
}

struct Fixture<'a> {
    fake: &'a SharedFake,
    inputs: Map<String, Value>,
    resolved: ResolvedArtifact,
    library: Vec<u8>,
    helper: CodeSignHelper,
}

impl Fixture<'_> {
    fn deployment(&self, job_id: &str) -> Deployment {
        Deployment::from_inputs(
            &self.inputs,
            job_id,
            Some(&self.resolved),
            &self.library,
            Some(&self.helper),
        )
        .unwrap()
    }

    fn run(&self, action: &NativeAction, step: &str) -> Outcome {
        let plan = action
            .lower(
                step,
                Some(CONNECT_KEY),
                Some(&self.resolved),
                Some(self.library.len() as i64),
                Some(&self.helper),
            )
            .unwrap();
        let receipt = run(&plan, &self.fake.dispatch as &dyn HdcDispatch).unwrap();
        action.verify(&receipt)
    }

    fn step(&self, deployment: &Deployment, step: &str) -> Outcome {
        let action = NativeAction::for_step(step, deployment).unwrap().unwrap();
        self.run(&action, step)
    }
}

#[test]
fn every_oracle_job_replays_argv_for_argv_over_the_shared_fake() {
    let oracle = oracle();
    let cases = read_json(&oracle.join("cases.json"));
    let provenance = read_json(&oracle.join("provenance.json"));
    let answers = fs::read_to_string(oracle.join("hdc-answers.sh")).unwrap();
    let log: Vec<String> = fs::read_to_string(oracle.join("hdc-invocations.log"))
        .unwrap()
        .lines()
        .map(str::to_owned)
        .collect();
    assert_eq!(
        log.len(),
        225,
        "the oracle's five Jobs and the continuation"
    );
    let fake = SharedFake::with_answers(&answers, None);
    assert_eq!(
        provenance["root"].as_str().unwrap(),
        fake.root.to_string_lossy(),
        "the oracle was recorded at the shared fake's root"
    );
    // The two host files the argv names: the leased library's bytes as the
    // oracle checked them in, and the helper at the path the oracle used
    // (its bytes are not in the fixture; the fake answers its digest).
    let artifacts = fake.root.join("artifacts/job-input-native-library");
    fs::create_dir_all(&artifacts).unwrap();
    let library_path = artifacts.join(LIBRARY_ARTIFACT);
    fs::copy(
        oracle
            .join("artifacts/job-input-native-library")
            .join(LIBRARY_ARTIFACT),
        &library_path,
    )
    .unwrap();
    let helper_path = PathBuf::from(string(&cases["codeSignHelper"], "path"));
    fs::create_dir_all(helper_path.parent().unwrap()).unwrap();
    fs::write(&helper_path, b"not the helper's bytes").unwrap();
    let library = fs::read(&library_path).unwrap();
    let facts = &cases["library"];
    assert_eq!(library.len() as i64, facts["byteCount"].as_i64().unwrap());
    let fixture = Fixture {
        fake: &fake,
        inputs: json!({
            "libraryArtifactLease": string(&cases, "lease"),
            "targetBundle": "com.example.demo",
            "libraryLogicalName": "libexample.so",
            "expectedABI": "arm64-v8a",
            "restartProfile": "restartAbility",
            "verificationProfile": "hashProcessAndMaps",
            "rollbackPolicy": "autoRollback",
        })
        .as_object()
        .cloned()
        .unwrap(),
        resolved: ResolvedArtifact {
            artifact_id: LIBRARY_ARTIFACT.into(),
            sha256: string(facts, "sha256"),
            path: library_path,
        },
        library,
        helper: CodeSignHelper {
            facts: CodeSignHelperFacts {
                abi: NativeAbi::Arm64,
                build_id: string(&cases["codeSignHelper"], "buildId"),
                sha256: string(&cases["codeSignHelper"], "sha256"),
                byte_count: cases["codeSignHelper"]["byteCount"].as_i64().unwrap(),
            },
            host_path: helper_path,
        },
    };
    let deployed = fixture.deployment("job-0");
    assert_eq!(deployed.artifact_facts.sha256, string(facts, "sha256"));
    assert_eq!(deployed.artifact_facts.build_id, string(facts, "buildId"));
    assert_eq!(deployed.artifact_facts.abi, NativeAbi::Arm64);
    assert!(
        deployed.artifact_facts.code_sign.is_some(),
        "the fixture ELF is code-signed"
    );
    let replaced = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    let mut cursor = 0;
    for (name, mode) in [
        ("deployed", "normal"),
        ("loaderFailure", "loaderFailure"),
        ("targetAbsent", "targetAbsent"),
        ("unattested", "unattested"),
        ("cleanupFailure", "cleanupFailure"),
    ] {
        fake.set_mode(mode);
        for marker in ["device-running", "device-published"] {
            let _ = fs::remove_file(fake.root.join(marker));
        }
        fake.clear_invocations();
        let job_id = string(&cases["jobs"], name);
        let deployment = fixture.deployment(&job_id);
        assert_eq!(
            fixture.step(&deployment, "send-to-staging"),
            Outcome::Unknown("native staging send requires remote hash readback".into())
        );
        let staging = fixture.step(&deployment, "verify-remote-staging");
        let summary = verified_summary(&staging, "verify-remote-staging");
        assert_eq!(summary["remoteSha256"], string(facts, "sha256"));
        assert_eq!(summary["remoteByteCount"], "588");
        let backup = fixture.step(&deployment, "backup-current-version");
        if name == "targetAbsent" {
            assert!(
                matches!(
                    &backup,
                    Outcome::Failed {
                        code: "nativeAppOwnedDirectoryMissing",
                        ..
                    }
                ),
                "{backup:?}"
            );
            let compensation = fixture.step(&deployment, "cleanup-native-library-compensation");
            let summary = verified_summary(&compensation, "compensation");
            assert_eq!(summary["backupRetained"], "false");
        } else {
            let summary = verified_summary(&backup, "backup-current-version");
            assert_eq!(summary["backupSha256"], replaced);
            assert_eq!(summary["backupPath"], deployment.backup_path);
            let publish = fixture.step(&deployment, "atomic-publish");
            let summary = verified_summary(&publish, "atomic-publish");
            assert_eq!(summary["mode"], "-rw-------");
            assert_eq!(summary["uid"], "20010050");
            assert_eq!(summary["gid"], "20010050");
            if name == "unattested" {
                assert_eq!(summary["attestation"], "matchesReplacedFile:none");
                assert!(!summary.contains_key("fsVerityDigest"));
            } else {
                assert_eq!(summary["attestation"], "fsVerity");
                assert_eq!(summary["fsVerityDigest"], replaced);
            }
            let stopped = fixture.step(&deployment, "restart-target");
            assert_eq!(
                verified_summary(&stopped, "restart-target")["stopped"],
                "com.example.demo"
            );
            let started = fixture.step(&deployment, "start-target");
            assert_eq!(
                verified_summary(&started, "start-target")["processIds"],
                "4321"
            );
            let loaded = fixture.step(&deployment, "verify-loaded-library");
            if name == "loaderFailure" {
                assert!(
                    matches!(
                        &loaded,
                        Outcome::Failed {
                            code: "nativeLibraryNotLoaded",
                            ..
                        }
                    ),
                    "{loaded:?}"
                );
                let rollback = fixture.step(&deployment, "rollback-native-library");
                let summary = verified_summary(&rollback, "rollback-native-library");
                assert_eq!(summary["restoredSha256"], replaced);
                assert_eq!(summary["processIds"], "4321");
                let compensation = fixture.step(&deployment, "cleanup-native-library-compensation");
                verified_summary(&compensation, "compensation");
            } else {
                let summary = verified_summary(&loaded, "verify-loaded-library");
                assert_eq!(summary["loaderVerified"], "true");
                assert_eq!(summary["processIds"], "4321");
                assert_eq!(summary["abi"], "arm64-v8a");
                let cleanup = fixture.step(&deployment, "cleanup-staging-and-backup");
                if name == "cleanupFailure" {
                    assert!(
                        matches!(
                            &cleanup,
                            Outcome::Failed {
                                code: "cleanupDebt",
                                ..
                            }
                        ),
                        "{cleanup:?}"
                    );
                    // The engine's reconciliation readback of the failed
                    // cleanup: the paths are still there, so the cleanup is
                    // concluded as not executed.
                    let action = NativeAction::for_step("cleanup-staging-and-backup", &deployment)
                        .unwrap()
                        .unwrap();
                    let readback = action.readback().unwrap();
                    let outcome = fixture.run(&readback, "cleanupDebt.readback");
                    assert!(
                        matches!(
                            &outcome,
                            Outcome::Failed {
                                code: "nativeCleanupIncomplete",
                                ..
                            }
                        ),
                        "{outcome:?}"
                    );
                    assert_eq!(action.reconcile(outcome), Reconcile::ConfirmedNotExecuted);
                } else {
                    let summary = verified_summary(&cleanup, "cleanup-staging-and-backup");
                    assert_eq!(summary["cleaned"], deployment.staging_path);
                }
            }
        }
        let lines = logged(&fake);
        let expected = &log[cursor..cursor + lines.len()];
        assert_eq!(
            lines, expected,
            "{name}: the argv the driver logged is the oracle's"
        );
        cursor += lines.len();
    }
    // The debt continuation: the cleanup run again in the oracle's normal
    // mode over the residue the failed cleanup left.
    fake.set_mode("normal");
    fake.clear_invocations();
    let deployment = fixture.deployment(&string(&cases["jobs"], "cleanupFailure"));
    let cleanup = fixture.step(&deployment, "cleanup-staging-and-backup");
    let summary = verified_summary(&cleanup, "cleanupDebt.continue");
    assert_eq!(summary["cleaned"], deployment.staging_path);
    let recorded = &log[cursor..];
    assert_eq!(recorded.len(), 10);
    assert_eq!(
        logged(&fake),
        recorded,
        "the continuation's argv is the oracle's"
    );
}
