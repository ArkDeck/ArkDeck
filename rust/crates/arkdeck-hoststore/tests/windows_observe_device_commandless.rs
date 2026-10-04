//! `observe.device@1` on Windows over a dispatch pinned to the registered
//! Windows HDC tuple (CHG-2026-078 c2, TASK-XPA-005): its `probeHDCServer`
//! step is the commandless server observation (`serverIdentityGeneration`),
//! never `checkserver`, which starts a server when none runs. The plan names
//! no process for the step, the run launches none, and the step verifies the
//! tuple's version as the client's and the server's once the registered
//! executable's own server is observed. Every other step is the macOS one,
//! read by the tuple's own grammars from the redacted c2 capture.
//!
//! An in-process dispatch stands in for the registered `hdc.exe` (a fake can
//! never have its hash, so it names the tuple it is pinned to, as
//! `ProcessDispatch` does for the real one). No process, device or board is
//! involved; the two property answers are the oracle fake's.
#![cfg(windows)]

use arkdeck_hoststore::{
    ArtifactReadStore, HdcComposition, JobAdmitter, JobPlanner, JobRunner, JobStore, TargetStore,
};
use arkdeck_platform::HostDirectory;
use arkdeck_provider_hdc::{
    DispatchFailure, HdcDispatch, ProcessPlan, Receipt, ServerObservation, WindowsHdcTuple,
    windows_tuple,
};
use serde_json::{Value, json};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Duration;

const NOW: &str = "2026-09-14T00:00:00Z";
const QUOTA: u64 = 64 * 1024 * 1024;
const KEY: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const C2_SHA256: &str = "c79518498aaf4e719733961216444e70c3eb53c8ba7006b933e6d7f2e1c6101e";
/// What the call log records for the commandless observation, which runs no
/// process.
const OBSERVED: &str = "<commandless server observation>";

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../tests/fixtures/observe-device")
        .join(name)
}

fn c2(name: &str) -> Vec<u8> {
    fs::read(
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("../../tests/fixtures/hdc-windows/c2")
            .join(name),
    )
    .unwrap()
}

fn document(path: PathBuf) -> Value {
    serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
}

fn now() -> Option<String> {
    Some(NOW.into())
}

/// The registered tuple's `hdc.exe`, replayed: `-v` and `list targets -v`
/// are the c2 capture's bytes, the property reads the oracle fake's, and
/// the server observation what the test sets. Every call is logged.
struct C2 {
    pinned: Option<&'static WindowsHdcTuple>,
    observation: Mutex<ServerObservation>,
    calls: Mutex<Vec<String>>,
}

impl C2 {
    fn new(pinned: bool) -> Self {
        Self {
            pinned: pinned.then(|| windows_tuple(C2_SHA256).unwrap()),
            observation: Mutex::new(ServerObservation::Observed),
            calls: Mutex::default(),
        }
    }

    fn calls(&self) -> Vec<String> {
        std::mem::take(&mut *self.calls.lock().unwrap())
    }
}

impl HdcDispatch for C2 {
    fn registered_windows_tuple(&self) -> Option<&'static WindowsHdcTuple> {
        self.pinned
    }

    fn dispatch(&self, plan: &ProcessPlan) -> Result<Receipt, DispatchFailure> {
        let joined = plan.arguments.join(" ");
        self.calls.lock().unwrap().push(joined.clone());
        let stdout = if joined == "-v" {
            c2("no-board/version.stdout.bin")
        } else if joined == "list targets -v" {
            c2("board-connected/list-targets-board-connected.stdout.bin")
        } else if joined == format!("-t {KEY} shell param get const.product.name") {
            b"OpenHarmony Reference Device\n".to_vec()
        } else if joined == format!("-t {KEY} shell param get const.ohos.fullname") {
            b"OpenHarmony-4.1-release\n".to_vec()
        } else {
            panic!("the registered tuple is never asked {joined:?}");
        };
        Ok(Receipt {
            exit_status: 0,
            stdout,
            stderr: Vec::new(),
            truncated: false,
            duration: Duration::from_millis(5),
        })
    }

    fn observe_server(&self) -> Result<ServerObservation, DispatchFailure> {
        self.calls.lock().unwrap().push(OBSERVED.into());
        Ok(self.observation.lock().unwrap().clone())
    }
}

/// A fresh owner-only root holding the oracle's Target, adopted over the
/// registered tuple (its tool version `3.2.0g`).
struct Fixture {
    root: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let nonce = u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>().unwrap());
        let temporary = std::env::temp_dir().canonicalize().unwrap();
        let temporary = match temporary
            .to_str()
            .and_then(|text| text.strip_prefix(r"\\?\"))
        {
            Some(plain) => PathBuf::from(plain),
            None => temporary,
        };
        let root = temporary.join(format!("ad-win-commandless-{nonce:032x}"));
        HostDirectory::open_or_create_private(&root).unwrap();
        for name in ["artifacts", "jobs-state", "targets-state"] {
            HostDirectory::open_or_create_private(&root.join(name)).unwrap();
        }
        let targets = String::from_utf8(fs::read(fixture("targets-state/targets.json")).unwrap())
            .unwrap()
            .replace("\"3.2.0d\"", "\"3.2.0g\"");
        HostDirectory::open(&root.join("targets-state"))
            .unwrap()
            .create_document("targets.json", targets.as_bytes())
            .unwrap();
        Self { root }
    }

    fn composition<'a>(&self, targets: &'a TargetStore, hdc: &'a C2) -> HdcComposition<'a> {
        HdcComposition {
            targets,
            dispatch: hdc,
            receive_root: None,
            tool_sha256: C2_SHA256,
            now,
            code_sign_helper: None,
        }
    }

    /// The oracle's observed request, under a fresh idempotency key.
    fn request(key: &str) -> Vec<u8> {
        let mut request = document(fixture(
            "store/jobs/job-0f77f8c52864d676372962eccb17389c/job-record.json",
        ))["originalSubmissionRequest"]
            .clone();
        request["idempotencyKey"] = json!(format!("idem-{key}"));
        request["requestId"] = json!(format!("req-{key}"));
        serde_json::to_vec(&request).unwrap()
    }

    /// The plan digest the planner materializes over `hdc`.
    fn plan(&self, hdc: &C2) -> String {
        let artifacts = ArtifactReadStore::open(&self.root.join("artifacts")).unwrap();
        let targets = TargetStore::open(&self.root.join("targets-state")).unwrap();
        let composition = self.composition(&targets, hdc);
        let planner = JobPlanner {
            imports: None,
            artifacts: Some(&artifacts),
            analyzer: None,
            state_root: &self.root,
            hdc: Some(&composition),
            workspace: None,
        };
        let answer = planner
            .handle(
                json!({"requestJson": String::from_utf8(Self::request("plan")).unwrap()})
                    .as_object()
                    .unwrap(),
            )
            .unwrap();
        answer["materializedPlanDigest"]
            .as_str()
            .unwrap_or_else(|| panic!("{answer}"))
            .to_owned()
    }

    /// An `observe.device@1` Job admitted and run over `hdc`: its run's
    /// answer and its Job record.
    fn run(&self, hdc: &C2, key: &str) -> (Value, Value) {
        let jobs = JobStore::open_owner(&self.root.join("jobs-state")).unwrap();
        let artifacts = ArtifactReadStore::open(&self.root.join("artifacts")).unwrap();
        let targets = TargetStore::open(&self.root.join("targets-state")).unwrap();
        let composition = self.composition(&targets, hdc);
        let job = JobAdmitter {
            authority: None,
            planner: JobPlanner {
                imports: None,
                artifacts: Some(&artifacts),
                analyzer: None,
                state_root: &self.root,
                hdc: Some(&composition),
                workspace: None,
            },
            jobs: &jobs,
            now,
        }
        .submit(&Self::request(key))
        .unwrap()["jobId"]
            .as_str()
            .unwrap()
            .to_owned();
        let answer = JobRunner {
            mutation: None,
            imports: None,
            jobs: &jobs,
            artifacts: &artifacts,
            analyzer: None,
            quota: QUOTA,
            home: r"C:\isolated-test",
            now,
            precise_now: || Some("2026-09-14T00:00:00.000Z".into()),
            sessions: None,
            cancellation: None,
            after_commit: None,
            hdc: Some(&composition),
            workspace: None,
        }
        .handle(json!({"jobId": job}).as_object().unwrap());
        let answer = answer.unwrap_or_else(|refusal| json!({"refused": refusal.message}));
        let record = document(
            self.root
                .join("jobs-state/jobs")
                .join(&job)
                .join("job-record.json"),
        );
        (answer, record)
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn timeline(record: &Value) -> Vec<String> {
    record["timeline"]
        .as_array()
        .unwrap_or_else(|| panic!("{record}"))
        .iter()
        .map(|line| line.as_str().unwrap().to_owned())
        .collect()
}

#[test]
fn the_server_probe_is_the_commandless_observation_on_a_registered_tuple() {
    let fixture = Fixture::new();
    let hdc = C2::new(true);
    let (answer, record) = fixture.run(&hdc, "observed");
    assert_eq!(record["state"], "succeeded", "{answer}\n{record}");
    // No `checkserver`: the probe launched nothing, and every other step is
    // the macOS one, read by the tuple's grammars.
    assert_eq!(
        hdc.calls(),
        [
            "-v",
            OBSERVED,
            "list targets -v",
            &format!("-t {KEY} shell param get const.product.name"),
            &format!("-t {KEY} shell param get const.ohos.fullname"),
        ]
    );
    assert!(
        timeline(&record)
            .contains(&r#"verified probe-hdc-server ["clientVersion", "serverVersion"]"#.into()),
        "{record}"
    );
}

#[test]
fn a_server_the_observation_cannot_prove_stops_the_job_before_the_device() {
    let fixture = Fixture::new();
    let hdc = C2::new(true);
    *hdc.observation.lock().unwrap() =
        ServerObservation::Unknown("no HDC server is observed at 127.0.0.1:8710".into());
    let (answer, record) = fixture.run(&hdc, "unobserved");
    assert_ne!(record["state"], "succeeded", "{answer}\n{record}");
    assert_eq!(hdc.calls(), ["-v", OBSERVED], "nothing reaches the device");
}

#[test]
fn the_plan_names_the_observation_only_on_a_registered_tuple() {
    let fixture = Fixture::new();
    let pinned = fixture.plan(&C2::new(true));
    let unpinned = fixture.plan(&C2::new(false));
    assert_eq!(pinned, fixture.plan(&C2::new(true)), "the plan is stable");
    assert_ne!(
        pinned, unpinned,
        "a registered tuple's plan names no checkserver process"
    );
}
