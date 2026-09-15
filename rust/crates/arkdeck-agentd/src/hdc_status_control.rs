//! `runtime.hdc.status` through the control layer. Every case of the Swift
//! status oracle (`rust/tests/fixtures/hdc-status`) is observed at request
//! time by `HdcStatusObserver`, behind a host that composes it per request as
//! the daemon composes its observer, and sent as a frame through `Control`:
//! the control layer admits each answer under the method's published schema
//! and returns it byte for byte as the oracle's snapshot. A request naming a
//! parameter is refused with Swift's message before the host is asked, and
//! the daemon's own host, which starts no managed HDC server, answers the
//! oracle's unconfigured status.
use arkdeck_contract::{CONTRACT_IDENTITY, DeviceObservationsResult, PROTOCOL_VERSION, WireError};
use arkdeck_control::{Control, HdcStatus, HostServices};
use arkdeck_platform::ServerIdentityReceipt;
use arkdeck_provider_hdc::{
    HdcStatusObserver, IdentityObservation, IdentityObserver, ManagedLaunch,
    ManagedProcessVerifier, NativeSignature, StartupDiagnostics, StatusExecutable,
    unconfigured_status,
};
use serde_json::{Value, json};
use std::fs::{self, File, OpenOptions};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

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

/// The oracle's root with the shared fake driver at its path, held under the
/// oracle's lock (its Swift producer and the observer's replay take the same
/// lock) for the life of the value, and removed afterwards.
struct OracleRoot {
    _lock: File,
    root: PathBuf,
}

impl OracleRoot {
    fn prepare(provenance: &Value) -> Self {
        let root = PathBuf::from(string(provenance, "root"));
        assert!(root.starts_with("/private/tmp/"));
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
        let hdc = root.join("hdc");
        fs::write(
            &hdc,
            fs::read(fixtures().join("observe-device/hdc")).unwrap(),
        )
        .unwrap();
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

/// The Swift seam of one case: its observation and verdict, with its
/// disturbance of the tool applied where the case applies it.
struct Seam {
    observation: IdentityObservation,
    verified: bool,
    disturbance: String,
    tool: PathBuf,
}

impl Seam {
    /// Swift's `chmod(path, 0o600); chmod(path, 0o700)`.
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

/// A host whose HDC status owner is the current case's observer, composed
/// per request; no other method is served.
struct StatusHost {
    tool: PathBuf,
    now: String,
    case: Arc<Mutex<Value>>,
    asked: Arc<AtomicUsize>,
}

impl HostServices for StatusHost {
    fn runtime_hdc_status(&self) -> Result<Value, WireError> {
        self.asked.fetch_add(1, Ordering::SeqCst);
        let case = self.case.lock().unwrap().clone();
        let daemon_version = case["daemonVersion"].as_str().map(str::to_owned);
        if case["executable"].is_null() {
            return Ok(unconfigured_status(daemon_version.as_deref()));
        }
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
            disturbance: string(&case, "disturbance"),
            tool: self.tool.clone(),
        };
        let launched = launch(&case["launch"]);
        let launches = || launched.clone();
        let now = || self.now.clone();
        Ok(HdcStatusObserver::new(
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
        .snapshot())
    }
    fn observed_at(&self) -> String {
        self.now.clone()
    }
    fn hdc_status(&self, deep: bool) -> HdcStatus {
        HdcStatus::unavailable(deep, "hdc.notConfigured")
    }
    fn observations(&self) -> Result<DeviceObservationsResult, WireError> {
        Err(WireError {
            code: "rejected".into(),
            message: "device observations are not served here".into(),
            details: None,
        })
    }
}

/// A current `runtime.hdc.status` frame, without its LF.
fn frame(id: &str, params: Option<Value>) -> Vec<u8> {
    let mut request = json!({
        "protocolVersion": PROTOCOL_VERSION, "contractIdentity": CONTRACT_IDENTITY,
        "id": id, "method": "runtime.hdc.status",
    });
    if let Some(params) = params {
        request["params"] = params;
    }
    serde_json::to_vec(&request).unwrap()
}

fn reply<H: HostServices>(control: &Control<H>, frame: &[u8]) -> Value {
    serde_json::from_slice(control.handle_frame(frame).trim_ascii_end()).unwrap()
}

/// The answer's result as the oracle's snapshot files hold it.
fn snapshot_bytes(reply: &Value) -> Vec<u8> {
    let mut bytes = serde_json::to_vec(&reply["result"]).unwrap();
    bytes.push(b'\n');
    bytes
}

#[test]
fn the_control_layer_answers_every_status_oracle_case_as_its_snapshot() {
    let oracle = fixtures().join("hdc-status");
    let provenance = read_json(&oracle.join("provenance.json"));
    let root = OracleRoot::prepare(&provenance);
    let cases = read_json(&oracle.join("cases.json"));
    let cases = cases.as_array().unwrap();
    assert_eq!(cases.len(), 22);
    let case = Arc::new(Mutex::new(Value::Null));
    let asked = Arc::new(AtomicUsize::new(0));
    let control = Control::new(StatusHost {
        tool: root.root.join("hdc"),
        now: string(&provenance, "nowUTC"),
        case: case.clone(),
        asked: asked.clone(),
    })
    .unwrap();
    let mut mismatches = Vec::new();
    for (index, recorded) in cases.iter().enumerate() {
        let name = string(recorded, "name");
        *case.lock().unwrap() = recorded.clone();
        let answer = reply(&control, &frame(&format!("status-{index:02}"), None));
        assert!(answer["error"].is_null(), "{name}: {answer}");
        let produced = snapshot_bytes(&answer);
        let expected = fs::read(oracle.join(format!("snapshots/{index:02}-{name}.json"))).unwrap();
        if produced != expected {
            mismatches.push(format!(
                "{index:02}-{name}\n  recorded {}\n  produced {}",
                String::from_utf8_lossy(&expected).trim_end(),
                String::from_utf8_lossy(&produced).trim_end()
            ));
        }
    }
    assert!(mismatches.is_empty(), "{}", mismatches.join("\n"));
    assert_eq!(asked.load(Ordering::SeqCst), 22);

    // A caller's facts are refused before the host is asked.
    let refused = reply(
        &control,
        &frame("status-path", Some(json!({"path": "/tmp/hdc"}))),
    );
    assert_eq!(refused["error"]["code"], "invalidParams");
    assert_eq!(
        refused["error"]["message"],
        "live HDC status does not accept caller facts or paths"
    );
    assert_eq!(asked.load(Ordering::SeqCst), 22);
}

#[test]
fn the_daemon_without_a_managed_server_answers_the_unconfigured_status() {
    let control = Control::new(crate::host::Host::from_environment()).unwrap();
    let answer = reply(&control, &frame("status", None));
    assert_eq!(
        snapshot_bytes(&answer),
        fs::read(fixtures().join("hdc-status/snapshots/00-unconfigured.json")).unwrap()
    );
}
