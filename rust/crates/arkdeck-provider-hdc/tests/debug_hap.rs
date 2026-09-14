//! Swift's `debug.hap@1` oracle (`rust/tests/fixtures/debug-hap`, recorded by
//! `DebugHapOracleContractTests` over the shared fake HDC driver) replayed
//! by `HapAction`: every Job of the oracle is driven step by step, in the
//! order Swift's engine ran it, through the real process dispatch over the
//! same driver with the oracle's own answers fragment and mode, each step's
//! verdict checked against what let Swift's engine continue or made it
//! compensate, and the argv the driver logged compared line for line with
//! the oracle's recorded log — T1 argv parity for eight Jobs and the two
//! cleanup-debt continuations.
#![cfg(target_os = "macos")]

mod common;

use arkdeck_provider_hdc::{
    Action, DEFAULT_HILOG_BUDGET, Expected, FileReceipt, HapAction, HdcDispatch, ImageType,
    Outcome, OwnedRemotePath, Property, ResolvedArtifact, run,
};
use common::{CONNECT_KEY, SharedFake};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

const ENTRY: &str = "ART-ce40ab95d8ec5ac89835a46e2d301004";
const FEATURE: &str = "ART-2ab8ee3a91b3198ef6404e610ed5179f";

fn oracle() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures/debug-hap")
}

fn read_json(path: &Path) -> Value {
    serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
}

fn verified(facts: &[(&str, &str)]) -> Outcome {
    Outcome::Verified(
        facts
            .iter()
            .map(|(key, value)| ((*key).to_owned(), (*value).to_owned()))
            .collect::<BTreeMap<_, _>>(),
    )
}

fn logged(fake: &SharedFake) -> Vec<String> {
    String::from_utf8(fake.invocations())
        .unwrap()
        .lines()
        .map(str::to_owned)
        .collect()
}

/// The device as the oracle left it between Jobs: no bundle installed, no
/// process running (the path markers stay, as they did in the recording).
fn fresh_device(fake: &SharedFake) {
    let _ = fs::remove_file(fake.root.join("device-installed"));
    let _ = fs::remove_file(fake.root.join("device-running"));
}

fn resolved(root: &Path, artifact_id: &str, digest: char) -> ResolvedArtifact {
    ResolvedArtifact {
        artifact_id: artifact_id.to_owned(),
        sha256: digest.to_string().repeat(64),
        path: root.join("artifacts/job-input-hap").join(artifact_id),
    }
}

fn inputs(package_set: bool) -> Map<String, Value> {
    let mut inputs = json!({
        "bundleName": "com.example.demo",
        "abilityName": "EntryAbility",
        "hapArtifactLease": format!("lease-v1:job-input-hap:{ENTRY}"),
    });
    if package_set {
        inputs["additionalHapArtifactLeases"] =
            json!([format!("lease-v1:job-input-hap:{FEATURE}")]);
    }
    inputs.as_object().cloned().unwrap()
}

/// One Job of the oracle: what the fake answers, whether the request staged
/// a set, and which step outcomes Swift's engine saw before it succeeded,
/// compensated or parked.
struct Job<'a> {
    name: &'a str,
    mode: &'a str,
    package_set: bool,
}

struct Device<'a> {
    fake: &'a SharedFake,
    resolved: Vec<ResolvedArtifact>,
    job_id: String,
    inputs: Map<String, Value>,
}

impl Device<'_> {
    fn preflight(&self) {
        for (action, step) in [
            (Action::ObserveDevice, "confirm-evidence-target"),
            (
                Action::QueryProperty(Property::ProductName),
                "read-evidence-model",
            ),
            (
                Action::QueryProperty(Property::FullBuildVersion),
                "read-evidence-firmware",
            ),
        ] {
            let plan = action.lower(step, Some(CONNECT_KEY)).unwrap();
            let receipt = self.fake.dispatch.dispatch(&plan).unwrap();
            assert!(
                matches!(
                    action.verify(
                        &receipt,
                        Expected {
                            connect_key: Some(CONNECT_KEY),
                            ..Expected::default()
                        }
                    ),
                    Outcome::Verified(_)
                ),
                "{step} verifies over the oracle's fake"
            );
        }
    }

    fn hap(&self, kind: &str, action_id: Option<&str>, step: &str) -> (HapAction, Outcome) {
        let action = HapAction::for_step(
            step,
            kind,
            action_id,
            &self.inputs,
            &self.job_id,
            &self.resolved,
        )
        .unwrap()
        .unwrap();
        let plan = action
            .lower(step, Some(CONNECT_KEY), &self.resolved)
            .unwrap();
        let receipt = run(&plan, &self.fake.dispatch as &dyn HdcDispatch).unwrap();
        let outcome = action.verify(&receipt, Some(&self.resolved[0].sha256));
        (action, outcome)
    }

    fn hilog(&self) -> Outcome {
        let action = Action::capture_hilog(10, Vec::new(), DEFAULT_HILOG_BUDGET).unwrap();
        let plan = action
            .lower("capture-diagnostics", Some(CONNECT_KEY))
            .unwrap();
        let receipt = self.fake.dispatch.dispatch(&plan).unwrap();
        action.verify(&receipt, Expected::default())
    }

    fn staged_path(&self) -> String {
        OwnedRemotePath::stable(&self.job_id, "send-hap", ImageType::Png)
            .unwrap()
            .remote_path
    }

    fn compensate(&self) -> (Outcome, Outcome) {
        let (_, uninstalled) = self.hap("uninstallPackage", None, "cleanup-uninstall");
        let (_, cleaned) = self.hap("cleanupOwnedRemotePath", None, "cleanup-remote-staging");
        (uninstalled, cleaned)
    }

    /// The common opening of every Job: send, install, the package readback.
    fn stage_and_install(&self) -> Outcome {
        let staged = self.staged_path();
        let (_, sent) = self.hap("sendFile", None, "send-hap");
        if self.inputs.contains_key("additionalHapArtifactLeases") {
            let Outcome::Verified(summary) = &sent else {
                panic!("{sent:?}")
            };
            assert_eq!(summary["packageCount"], "2");
        } else {
            assert_eq!(sent, verified(&[("stagedAt", &staged)]));
        }
        let (_, installed) = self.hap("installPackage", None, "install-hap");
        assert_eq!(
            installed,
            Outcome::Unknown("install requires package readback before it can be believed".into())
        );
        self.hap(
            "runApprovedRemoteRead",
            Some("packageInfo"),
            "package-readback",
        )
        .1
    }

    fn start_and_observe(&self) {
        let (_, started) = self.hap("startApplication", None, "start-ability");
        assert_eq!(
            started,
            Outcome::Unknown("start requires process readback before it can be believed".into())
        );
        let (_, running) = self.hap("verifyRemoteState", None, "process-readback");
        assert_eq!(
            running,
            verified(&[("bundleName", "com.example.demo"), ("running", "true")])
        );
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
        108,
        "the oracle's eight Jobs and two continuations"
    );
    let fake = SharedFake::with_answers(&answers, None);
    assert_eq!(
        provenance["root"].as_str().unwrap(),
        fake.root.to_string_lossy(),
        "the oracle was recorded at the shared fake's root"
    );
    let root = fake.root.clone();
    let jobs = [
        Job {
            name: "installed",
            mode: "normal",
            package_set: false,
        },
        Job {
            name: "packageSet",
            mode: "normal",
            package_set: true,
        },
        Job {
            name: "notInstalled",
            mode: "notInstalled",
            package_set: false,
        },
        Job {
            name: "startFailed",
            mode: "startFailed",
            package_set: false,
        },
        Job {
            name: "stillRunning",
            mode: "stillRunning",
            package_set: false,
        },
        Job {
            name: "stillInstalled",
            mode: "stillInstalled",
            package_set: false,
        },
        Job {
            name: "cleanupDebt",
            mode: "cleanupDebt",
            package_set: false,
        },
        Job {
            name: "emptyHilog",
            mode: "emptyHilog",
            package_set: false,
        },
    ];
    let mut cursor = 0;
    let readback_verified = |outcome: &Outcome| {
        let Outcome::Verified(summary) = outcome else {
            panic!("{outcome:?}")
        };
        assert_eq!(summary["installed"], "true");
        assert_eq!(summary["nativeLibraryPath"], "libs/arm64");
        assert_eq!(summary["cpuAbi"], "arm64-v8a");
        assert_eq!(summary["nativeLibraryFileCount"], "1");
    };
    for job in &jobs {
        fake.set_mode(job.mode);
        fresh_device(&fake);
        fake.clear_invocations();
        let job_id = cases["jobs"][job.name].as_str().unwrap().to_owned();
        let mut resolved = vec![resolved(&root, ENTRY, 'a')];
        if job.package_set {
            resolved.push(self::resolved(&root, FEATURE, 'b'));
        }
        let device = Device {
            fake: &fake,
            resolved,
            job_id,
            inputs: inputs(job.package_set),
        };
        device.preflight();
        let readback = device.stage_and_install();
        match job.name {
            "notInstalled" => {
                assert!(
                    matches!(
                        readback,
                        Outcome::Failed {
                            code: "packageNotInstalled",
                            ..
                        }
                    ),
                    "{readback:?}"
                );
                let (uninstalled, cleaned) = device.compensate();
                assert_eq!(
                    uninstalled,
                    verified(&[("uninstalled", "com.example.demo")])
                );
                assert_eq!(cleaned, verified(&[("cleaned", &device.staged_path())]));
            }
            "startFailed" => {
                readback_verified(&readback);
                let (_, started) = device.hap("startApplication", None, "start-ability");
                assert!(
                    matches!(
                        started,
                        Outcome::Failed {
                            code: "startFailed",
                            ..
                        }
                    ),
                    "{started:?}"
                );
                let (uninstalled, cleaned) = device.compensate();
                assert_eq!(
                    uninstalled,
                    verified(&[("uninstalled", "com.example.demo")])
                );
                assert_eq!(cleaned, verified(&[("cleaned", &device.staged_path())]));
            }
            "emptyHilog" => {
                readback_verified(&readback);
                device.start_and_observe();
                assert_eq!(
                    device.hilog(),
                    Outcome::Unknown("empty capture output".into())
                );
            }
            _ => {
                readback_verified(&readback);
                device.start_and_observe();
                let Outcome::Verified(summary) = device.hilog() else {
                    panic!("hilog verifies")
                };
                assert_eq!(summary["byteCount"], "28");
                let (_, stopped) = device.hap("stopApplication", None, "stop-ability");
                if job.name == "stillRunning" {
                    assert!(
                        matches!(
                            stopped,
                            Outcome::Failed {
                                code: "stopIneffective",
                                ..
                            }
                        ),
                        "{stopped:?}"
                    );
                } else {
                    assert_eq!(stopped, verified(&[("stopped", "com.example.demo")]));
                }
                let (_, uninstalled) = device.hap("uninstallPackage", None, "cleanup-uninstall");
                if job.name == "stillInstalled" {
                    assert!(
                        matches!(
                            uninstalled,
                            Outcome::Failed {
                                code: "uninstallIneffective",
                                ..
                            }
                        ),
                        "{uninstalled:?}"
                    );
                } else {
                    assert_eq!(
                        uninstalled,
                        verified(&[("uninstalled", "com.example.demo")])
                    );
                }
                let (_, cleaned) =
                    device.hap("cleanupOwnedRemotePath", None, "cleanup-remote-staging");
                match job.name {
                    "cleanupDebt" => {
                        assert!(
                            matches!(
                                cleaned,
                                Outcome::Failed {
                                    code: "cleanupDebt",
                                    ..
                                }
                            ),
                            "{cleaned:?}"
                        );
                    }
                    "packageSet" => {
                        assert_eq!(
                            cleaned,
                            verified(&[(
                                "cleaned",
                                &format!(
                                    "/data/local/tmp/arkdeck-{}-send-hap-owned-packages",
                                    device.job_id
                                )
                            )])
                        );
                    }
                    _ => assert_eq!(cleaned, verified(&[("cleaned", &device.staged_path())])),
                }
            }
        }
        let lines = logged(&fake);
        let expected = &log[cursor..cursor + lines.len()];
        assert_eq!(
            lines, expected,
            "{}: the argv the driver logged is the oracle's",
            job.name
        );
        assert!(
            log.get(cursor + lines.len())
                .is_none_or(|next| next.starts_with("list\u{1f}targets"))
                || job.name == "emptyHilog",
            "{}: the Job's segment ends where the next begins",
            job.name
        );
        cursor += lines.len();
    }
    // The two cleanup-debt continuations, after the eight Jobs: the bundle
    // debt (a package probe, then the uninstall with its readback) and the
    // path debt (a path probe, then the cleanup), each in the oracle's
    // normal mode over the device as the last Job left it — the bundle the
    // parked Job installed, the staged file the failed cleanup left.
    fake.set_mode("normal");
    fake.clear_invocations();
    let still_installed = cases["jobs"]["stillInstalled"].as_str().unwrap();
    let cleanup_debt = cases["jobs"]["cleanupDebt"].as_str().unwrap();
    let dispatch = &fake.dispatch as &dyn HdcDispatch;
    let uninstall = HapAction::for_step(
        "cleanup-uninstall",
        "uninstallPackage",
        None,
        &inputs(false),
        still_installed,
        &[],
    )
    .unwrap()
    .unwrap();
    let probe = uninstall.readback().unwrap();
    assert_eq!(uninstall.desired_presence(), Some(false));
    let receipt = run(
        &probe
            .lower("cleanupDebt.continue", Some(CONNECT_KEY), &[])
            .unwrap(),
        dispatch,
    )
    .unwrap();
    assert_eq!(
        probe.presence(&receipt),
        Some(true),
        "the bundle is still there before the continuation"
    );
    let receipt: FileReceipt = run(
        &uninstall
            .lower("cleanupDebt.continue", Some(CONNECT_KEY), &[])
            .unwrap(),
        dispatch,
    )
    .unwrap();
    assert_eq!(
        uninstall.verify(&receipt, None),
        verified(&[("uninstalled", "com.example.demo")])
    );
    let cleanup = HapAction::for_step(
        "cleanup-remote-staging",
        "cleanupOwnedRemotePath",
        None,
        &inputs(false),
        cleanup_debt,
        &[],
    )
    .unwrap()
    .unwrap();
    let probe = cleanup.readback().unwrap();
    let receipt = run(
        &probe
            .lower("cleanupDebt.continue", Some(CONNECT_KEY), &[])
            .unwrap(),
        dispatch,
    )
    .unwrap();
    assert_eq!(
        probe.presence(&receipt),
        Some(true),
        "the staged file the failed cleanup left is still there"
    );
    let receipt = run(
        &cleanup
            .lower("cleanupDebt.continue", Some(CONNECT_KEY), &[])
            .unwrap(),
        dispatch,
    )
    .unwrap();
    let staged = OwnedRemotePath::stable(cleanup_debt, "send-hap", ImageType::Png)
        .unwrap()
        .remote_path;
    assert_eq!(
        cleanup.verify(&receipt, None),
        verified(&[("cleaned", &staged)])
    );
    let recorded = &log[cursor..];
    assert_eq!(recorded.len(), 5);
    assert_eq!(
        logged(&fake),
        recorded,
        "the continuations' argv are the oracle's"
    );
}
