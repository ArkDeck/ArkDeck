//! The Swift `HDCStatusOracleContractTests` oracle
//! (`rust/tests/fixtures/hdc-status`) replayed by `HdcStatusObserver` on
//! Windows (TASK-XPA-005), as `hdc_status.rs` replays it on macOS: the same
//! tool bytes (the shared fake HDC driver), the same clock, the same seam
//! inputs case by case, and the same bytes answered.
//!
//! What differs is only what Windows cannot share:
//!
//! * the oracle's root `/private/tmp/arkdeck-hdc-status-oracle` is a fresh
//!   owner's directory below the temporary directory, and every path the
//!   oracle names under it is read as that directory's (a label, in the
//!   cases and in the recorded answers alike);
//! * Swift's disturbance of the tool (`chmod 0600; chmod 0700`: the bytes and
//!   the mode end as they were, the change time does not) is its Windows
//!   counterpart: the bytes stay, the last-write time moves, through a
//!   handle that asks for attributes only, beside the observer's own;
//! * the driver is a POSIX script, which Authenticode cannot read at all, so
//!   the signature member comes from a seam answering the oracle's unsigned
//!   object; the production inspection answers that very object for an
//!   unsigned Windows image (this test binary) below.
//!
//! Then the production pieces on this host: no macOS digest has a Windows
//! identity family, so the observation is unsupported before any kernel
//! scan, and nothing is launched or dispatched.
#![cfg(windows)]

use arkdeck_platform::ServerIdentityReceipt;
use arkdeck_provider_hdc::{
    CommandlessIdentity, HdcStatusObserver, IdentityObservation, IdentityObserver, ManagedLaunch,
    ManagedProcessVerifier, NativeSignature, SignatureInspector, StartupDiagnostics,
    StatusExecutable, unconfigured_status,
};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// The oracle's root, as its cases and answers spell it.
const ORACLE_ROOT: &str = "/private/tmp/arkdeck-hdc-status-oracle";

fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tests/fixtures")
}

fn read_json(path: &Path) -> Value {
    serde_json::from_slice(&fs::read(path).unwrap_or_else(|error| panic!("{path:?}: {error}")))
        .unwrap_or_else(|error| panic!("{path:?}: {error}"))
}

fn string(value: &Value, key: &str) -> String {
    value[key]
        .as_str()
        .unwrap_or_else(|| panic!("{key} is a string"))
        .to_owned()
}

/// A fresh root with the driver at `hdc`, removed afterwards.
struct Root(PathBuf);

impl Root {
    fn prepare(provenance: &Value) -> Self {
        let temporary = std::env::temp_dir().canonicalize().unwrap();
        let temporary = temporary
            .to_str()
            .and_then(|text| text.strip_prefix(r"\\?\"))
            .map_or(temporary.clone(), PathBuf::from);
        let nonce = u128::from_le_bytes(arkdeck_platform::random_bytes().unwrap());
        let root = temporary.join(format!("arkdeck-hdc-status-oracle-{nonce:032x}"));
        fs::create_dir(&root).unwrap();
        let driver = fs::read(fixtures().join("observe-device/hdc")).unwrap();
        assert_eq!(
            format!("{:x}", Sha256::digest(&driver)),
            string(provenance, "hdcSHA256"),
            "the shared fake HDC driver is the oracle's tool"
        );
        fs::write(root.join("hdc"), driver).unwrap();
        assert_eq!(
            string(provenance, "executablePath"),
            format!("{ORACLE_ROOT}/hdc")
        );
        Self(root)
    }

    /// `text` with every oracle path read as this root's, JSON-escaped as
    /// the text spells strings.
    fn relabel(&self, text: &str) -> String {
        let mut text = text.to_owned();
        for name in ["hdc", "absent-hdc", "other-hdc"] {
            let here = serde_json::to_string(&self.0.join(name).to_str().unwrap()).unwrap();
            text = text.replace(&format!("\"{ORACLE_ROOT}/{name}\""), &here);
        }
        assert!(
            !text.contains(ORACLE_ROOT),
            "an oracle path is left: {text}"
        );
        text
    }
}

impl Drop for Root {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// The Swift seam: the case's observation and verdict, with the case's
/// disturbance of the tool applied where the case applies it.
struct Seam {
    observation: IdentityObservation,
    verified: bool,
    disturbance: String,
    tool: PathBuf,
}

impl Seam {
    /// The bytes stay and the last-write time moves on, through a handle
    /// that asks for attributes only (the observer's handle shares no write
    /// of the data).
    fn disturb(&self) {
        use std::os::windows::fs::OpenOptionsExt;
        const FILE_WRITE_ATTRIBUTES: u32 = 0x0100;
        let file = fs::OpenOptions::new()
            .access_mode(FILE_WRITE_ATTRIBUTES)
            .share_mode(0x7)
            .open(&self.tool)
            .unwrap();
        let modified = fs::metadata(&self.tool).unwrap().modified().unwrap();
        file.set_modified(modified + Duration::from_secs(2))
            .unwrap();
    }
}

impl IdentityObserver for Seam {
    fn observe(&self, _: &StatusExecutable, _: &str) -> IdentityObservation {
        if self.disturbance == "duringObservation" {
            self.disturb();
        }
        self.observation.clone()
    }
}

impl ManagedProcessVerifier for Seam {
    fn verifies(&self, _: &ServerIdentityReceipt, _: &[String]) -> bool {
        if self.disturbance == "duringOwnership" {
            self.disturb();
        }
        self.verified
    }
}

/// The oracle's signature object for its unsigned tool.
struct Unsigned(Value);

impl SignatureInspector for Unsigned {
    fn inspect(&self, _: &Path) -> std::io::Result<Value> {
        Ok(self.0.clone())
    }
}

fn receipt(value: &Value) -> ServerIdentityReceipt {
    ServerIdentityReceipt {
        pid: i32::try_from(value["pid"].as_i64().unwrap()).unwrap(),
        start_seconds: value["startSeconds"].as_u64().unwrap(),
        start_microseconds: value["startMicroseconds"].as_u64().unwrap(),
        executable_path: PathBuf::from(string(value, "executablePath")),
        executable_sha256: string(value, "executableSHA256"),
        endpoint: string(value, "endpoint").parse().unwrap(),
    }
}

fn observation(value: &Value) -> IdentityObservation {
    let reason = || string(value, "reason");
    match string(value, "classification").as_str() {
        "observed" => IdentityObservation::Observed {
            generation: value["generation"].as_i64().unwrap(),
            identity: value["identity"]
                .as_object()
                .map(|_| receipt(&value["identity"])),
        },
        "unavailable" => IdentityObservation::Unavailable(reason()),
        "unknown" => IdentityObservation::Unknown(reason()),
        "unsupported" => IdentityObservation::Unsupported(reason()),
        "timedOut" => IdentityObservation::TimedOut,
        "cancelled" => IdentityObservation::Cancelled,
        other => panic!("unknown classification {other}"),
    }
}

fn launch(value: &Value) -> Option<ManagedLaunch> {
    value.as_object().map(|_| ManagedLaunch {
        pid: i32::try_from(value["pid"].as_i64().unwrap()).unwrap(),
        start_seconds: value["startSeconds"].as_u64().unwrap(),
        start_microseconds: value["startMicroseconds"].as_u64().unwrap(),
        executable_path: string(value, "executablePath"),
        executable_sha256: string(value, "executableSHA256"),
        arguments: value["arguments"]
            .as_array()
            .unwrap()
            .iter()
            .map(|argument| argument.as_str().unwrap().to_owned())
            .collect(),
    })
}

/// Every case answered byte for byte as Swift answered it, its paths read
/// as this root's.
#[test]
fn the_observer_answers_every_oracle_case_byte_for_byte() {
    let oracle = fixtures().join("hdc-status");
    let provenance = read_json(&oracle.join("provenance.json"));
    let root = Root::prepare(&provenance);
    let now_utc = string(&provenance, "nowUTC");
    let now = || now_utc.clone();
    let cases: Value = serde_json::from_str(
        &root.relabel(&fs::read_to_string(oracle.join("cases.json")).unwrap()),
    )
    .unwrap();
    let cases = cases.as_array().unwrap();
    assert_eq!(cases.len(), 22);
    let signature = Unsigned(
        read_json(&oracle.join("snapshots/01-observed-managed.json"))["signature"].clone(),
    );
    let mut mismatches = Vec::new();
    for (index, case) in cases.iter().enumerate() {
        let name = string(case, "name");
        let daemon_version = case["daemonVersion"].as_str().map(str::to_owned);
        let answer = if case["executable"].is_null() {
            unconfigured_status(daemon_version.as_deref())
        } else {
            let executable = StatusExecutable {
                path: string(&case["executable"], "path"),
                sha256: string(&case["executable"], "sha256"),
            };
            let startup = StartupDiagnostics {
                executable_sha256: string(&case["startup"], "executableSHA256"),
                client_version: string(&case["startup"], "clientVersion"),
                server_version: string(&case["startup"], "serverVersion"),
                endpoint: string(&case["startup"], "endpoint"),
                endpoint_source: string(&case["startup"], "endpointSource"),
            };
            let seam = Seam {
                observation: observation(&case["observation"]),
                verified: case["managedProcessVerified"].as_bool().unwrap(),
                disturbance: string(case, "disturbance"),
                tool: root.0.join("hdc"),
            };
            let launched = launch(&case["launch"]);
            let launches = || launched.clone();
            HdcStatusObserver::new(
                executable,
                startup,
                daemon_version,
                &launches,
                None,
                &seam,
                &signature,
                &seam,
                &now,
            )
            .snapshot()
        };
        let mut produced = serde_json::to_vec(&answer).unwrap();
        produced.push(b'\n');
        let recorded = root.relabel(
            &fs::read_to_string(oracle.join(format!("snapshots/{index:02}-{name}.json"))).unwrap(),
        );
        if produced != recorded.as_bytes() {
            mismatches.push(format!(
                "{index:02}-{name}\n  recorded {}\n  produced {}",
                recorded.trim_end(),
                String::from_utf8_lossy(&produced).trim_end()
            ));
        }
    }
    assert!(mismatches.is_empty(), "{}", mismatches.join("\n"));
    // The disturbances moved only the tool's last-write time: its bytes are
    // the driver's still.
    assert_eq!(
        format!(
            "{:x}",
            Sha256::digest(fs::read(root.0.join("hdc")).unwrap())
        ),
        string(&provenance, "hdcSHA256")
    );
}

/// The production pieces on this host: no registered macOS digest has a
/// Windows identity family, so the observation is unsupported before any
/// kernel scan; an unsigned Windows image reads as the oracle's unsigned
/// signature object.
#[test]
fn the_production_pieces_answer_on_this_host() {
    let oracle = fixtures().join("hdc-status");
    let provenance = read_json(&oracle.join("provenance.json"));
    let root = Root::prepare(&provenance);
    let tool = StatusExecutable {
        path: root.0.join("hdc").to_str().unwrap().to_owned(),
        sha256: string(&provenance, "hdcSHA256"),
    };
    let endpoint = "127.0.0.1:8710";
    for family in provenance["registeredIdentities"].as_array().unwrap() {
        let digest = string(family, "executableSHA256");
        let at = family
            .get("exactEndpoint")
            .and_then(Value::as_str)
            .unwrap_or(endpoint);
        assert_eq!(
            CommandlessIdentity::family(&digest, at),
            None,
            "a macOS registered identity has no Windows family"
        );
    }
    assert!(matches!(
        CommandlessIdentity::default().observe(&tool, endpoint),
        IdentityObservation::Unsupported(_)
    ));
    // This test binary is an unsigned Windows image.
    let image = std::env::current_exe().unwrap().canonicalize().unwrap();
    let signature = NativeSignature.inspect(&image).unwrap();
    let managed = read_json(&oracle.join("snapshots/01-observed-managed.json"));
    assert_eq!(signature, managed["signature"]);
    assert_eq!(
        signature,
        json!({"executionAssessment": "notPerformed", "identifier": null,
            "platformTrust": "unverified", "state": "unsigned", "teamIdentifier": null})
    );
}
