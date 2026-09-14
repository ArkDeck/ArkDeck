//! The Swift `HDCStatusOracleContractTests` oracle
//! (`rust/tests/fixtures/hdc-status`) replayed by `HdcStatusObserver`: the
//! same tool (the shared fake HDC driver at the oracle's fixed root), the
//! same clock, the same seam inputs case by case — the launch record, the
//! identity observation, the managed-process verdict, the disturbance of the
//! tool — through the production signature inspection, and the same bytes
//! answered. Then the production observation pieces on this host: the
//! driver's digest belongs to no identity family, an unsigned tool reads as
//! the oracle's unsigned signature object, and a process that is not the
//! launched server is never managed.
#![cfg(target_os = "macos")]

use arkdeck_platform::ServerIdentityReceipt;
use arkdeck_provider_hdc::{
    CommandlessIdentity, HdcStatusObserver, IdentityObservation, IdentityObserver, ManagedLaunch,
    ManagedProcessVerifier, NativeSignature, SignatureInspector, StartupDiagnostics,
    StatusExecutable, SystemManagedProcess, unconfigured_status,
};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::net::{Ipv4Addr, SocketAddrV4};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

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

/// The oracle's root, recreated with the driver at its path, held under the
/// oracle's lock for the life of the value (the Swift test takes the same
/// lock), and removed afterwards.
struct OracleRoot {
    _lock: File,
    root: PathBuf,
}

impl OracleRoot {
    fn prepare(provenance: &Value) -> Self {
        let root = PathBuf::from(string(provenance, "root"));
        assert!(
            root.starts_with("/private/tmp/"),
            "the oracle root is under /private/tmp"
        );
        let lock = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(format!("{}.lock", root.display()))
            .unwrap();
        lock.lock().unwrap();
        let _ = fs::remove_dir_all(&root);
        fs::create_dir(&root).unwrap();
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        let driver = fs::read(fixtures().join("observe-device/hdc")).unwrap();
        assert_eq!(
            format!("{:x}", Sha256::digest(&driver)),
            string(provenance, "hdcSHA256"),
            "the shared fake HDC driver is the oracle's tool"
        );
        let hdc = root.join("hdc");
        fs::write(&hdc, driver).unwrap();
        fs::set_permissions(&hdc, fs::Permissions::from_mode(0o700)).unwrap();
        assert_eq!(hdc, PathBuf::from(string(provenance, "executablePath")));
        Self { _lock: lock, root }
    }
}

impl Drop for OracleRoot {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
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
    /// Swift's `chmod(path, 0o600); chmod(path, 0o700)`: the bytes and the
    /// mode end as they were, the inode's change time does not.
    fn disturb(&self) {
        fs::set_permissions(&self.tool, fs::Permissions::from_mode(0o600)).unwrap();
        fs::set_permissions(&self.tool, fs::Permissions::from_mode(0o700)).unwrap();
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

/// Every case answered byte for byte as Swift answered it.
#[test]
fn the_observer_answers_every_oracle_case_byte_for_byte() {
    let oracle = fixtures().join("hdc-status");
    let provenance = read_json(&oracle.join("provenance.json"));
    let root = OracleRoot::prepare(&provenance);
    let now_utc = string(&provenance, "nowUTC");
    let now = || now_utc.clone();
    let cases = read_json(&oracle.join("cases.json"));
    let cases = cases.as_array().unwrap();
    assert_eq!(cases.len(), 22);
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
                tool: root.root.join("hdc"),
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
                &NativeSignature,
                &seam,
                &now,
            )
            .snapshot()
        };
        let mut produced = serde_json::to_vec(&answer).unwrap();
        produced.push(b'\n');
        let recorded = fs::read(oracle.join(format!("snapshots/{index:02}-{name}.json"))).unwrap();
        if produced != recorded {
            mismatches.push(format!(
                "{index:02}-{name}\n  recorded {}\n  produced {}",
                String::from_utf8_lossy(&recorded).trim_end(),
                String::from_utf8_lossy(&produced).trim_end()
            ));
        }
    }
    assert!(mismatches.is_empty(), "{}", mismatches.join("\n"));
}

/// The production pieces on this host: the driver's digest has no identity
/// family, so the observation is unsupported before any kernel scan; the
/// unsigned driver reads as the oracle's signature object; a process that
/// did not launch the server is never managed.
#[test]
fn the_production_pieces_answer_for_the_driver_on_this_host() {
    let oracle = fixtures().join("hdc-status");
    let provenance = read_json(&oracle.join("provenance.json"));
    let root = OracleRoot::prepare(&provenance);
    let tool = StatusExecutable {
        path: root.root.join("hdc").to_string_lossy().into_owned(),
        sha256: string(&provenance, "hdcSHA256"),
    };
    let endpoint = "127.0.0.1:8710";
    for family in provenance["registeredIdentities"].as_array().unwrap() {
        let digest = string(family, "executableSHA256");
        assert_ne!(digest, tool.sha256);
        let at = family
            .get("exactEndpoint")
            .and_then(Value::as_str)
            .unwrap_or(endpoint);
        assert_eq!(
            CommandlessIdentity::family(&digest, at),
            Some(string(family, "toolVersion").as_str()),
            "the Rust family table names Swift's registered identities"
        );
    }
    assert!(matches!(
        CommandlessIdentity::default().observe(&tool, endpoint),
        IdentityObservation::Unsupported(_)
    ));
    let signature = NativeSignature
        .inspect(&fs::canonicalize(&tool.path).unwrap())
        .unwrap();
    let managed = read_json(&oracle.join("snapshots/01-observed-managed.json"));
    assert_eq!(signature, managed["signature"]);
    assert_eq!(signature["state"], "unsigned");
    let this = i32::try_from(std::process::id()).unwrap();
    let receipt = ServerIdentityReceipt {
        pid: this,
        start_seconds: 100,
        start_microseconds: 23,
        executable_path: std::env::current_exe().unwrap(),
        executable_sha256: tool.sha256.clone(),
        endpoint: SocketAddrV4::new(Ipv4Addr::LOCALHOST, 8710),
    };
    assert!(!SystemManagedProcess.verifies(&receipt, &["-s".into(), endpoint.into(), "-m".into()]));
}
