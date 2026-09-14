//! Swift `HeadlessHDCStatusObserver` (`runtime.hdc.status`): the fresh,
//! commandless status of the selected HDC executable and of the server at
//! the selected endpoint, as the one `arkdeck.runtime-hdc-status/1` object of
//! twenty-three members. Startup readiness stays historical
//! (`startupVersions`) and never becomes current health: `serverHealth` is
//! always `unknown`, `serverVersion` always null and `newDispatchCount`
//! always 0, because a status launches nothing.
//!
//! What needs a live kernel process is the observer's seam, as in Swift: who
//! observes the server identity (`IdentityObserver`), who inspects the tool's
//! signature (`SignatureInspector`), who verifies the managed process
//! (`ManagedProcessVerifier`), what the spawn recorded (`ManagedLaunch`) and
//! what a supervisor holds for the endpoint (`SupervisorState`). The
//! production pieces stand beside the observer: `CommandlessIdentity` (Swift
//! `HDCCommandlessServerIdentity.observe`), `NativeSignature` (Swift
//! `HeadlessHDCStatusObserver.signature`) and `SystemManagedProcess` (Swift
//! `HDCCommandlessServerIdentity.verifiesManagedProcess`).
//!
//! `tests/hdc_status.rs` replays the Swift oracle
//! (`rust/tests/fixtures/hdc-status`) case by case and compares the bytes.
use crate::lifecycle::generation;
use crate::live_mode::sha256_hex;
use crate::provider::registered_version;
use arkdeck_platform::{
    LoopbackServerLease, ServerIdentityReceipt, VerifiedTool, inspect_native_code_signature,
    verifies_managed_process,
};
use serde_json::{Map, Value, json};
use std::io;
use std::net::SocketAddrV4;
use std::path::Path;
use std::sync::mpsc;
use std::time::Duration;

/// The object's `schemaVersion`.
pub const STATUS_SCHEMA_VERSION: &str = "arkdeck.runtime-hdc-status/1";
/// Swift `HDCSupervisorObservationProbeCatalog.exactEndpoint`: the one
/// endpoint the 3.2.0f identity family observes.
const EXACT_ENDPOINT: &str = "127.0.0.1:8710";
/// Swift `HDCSupervisorObservationProbeCatalog.timeoutMilliseconds`.
const OBSERVATION_DEADLINE: Duration = Duration::from_millis(1_000);

/// Swift `ResolvedExecutable`: the configured tool, by the path it was
/// configured with (the object reports that spelling) and its trusted digest.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StatusExecutable {
    pub path: String,
    pub sha256: String,
}

/// Swift `HDCManagedRuntimeDiagnostics`: the path-free facts the daemon
/// established at startup — the digest it verified, the client and server
/// versions `checkserver` answered then, and the endpoint it selected with
/// how it selected it (`default`, `inheritedEnvironment`, `explicit`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StartupDiagnostics {
    pub executable_sha256: String,
    pub client_version: String,
    pub server_version: String,
    pub endpoint: String,
    pub endpoint_source: String,
}

/// Swift `HDCManagedProcessLaunch`: what the identity-bound spawn itself
/// recorded, which no status reader can manufacture from a PID or endpoint.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ManagedLaunch {
    pub pid: i32,
    pub start_seconds: u64,
    pub start_microseconds: u64,
    pub executable_path: String,
    pub executable_sha256: String,
    pub arguments: Vec<String>,
}

impl ManagedLaunch {
    /// Swift `matches`: the observed server is the launched process — by PID,
    /// birth, executable path and digest (its argv is verified separately).
    pub fn matches(&self, receipt: &ServerIdentityReceipt) -> bool {
        self.pid == receipt.pid
            && self.start_seconds == receipt.start_seconds
            && self.start_microseconds == receipt.start_microseconds
            && Path::new(&self.executable_path) == receipt.executable_path
            && self.executable_sha256 == receipt.executable_sha256
    }
}

/// Swift `HDCSupervisorObservationResult`: the classification of one
/// commandless identity observation, with the receipt when one was observed.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum IdentityObservation {
    Observed {
        generation: i64,
        identity: Option<ServerIdentityReceipt>,
    },
    Unavailable(String),
    Unknown(String),
    TimedOut,
    Cancelled,
    Unsupported(String),
}

/// Who observes the server identity at the endpoint for the selected tool.
pub trait IdentityObserver {
    fn observe(&self, executable: &StatusExecutable, endpoint: &str) -> IdentityObservation;
}

/// Who reads the tool's native code signature into the object's `signature`
/// member. An error withdraws every tool fact from the status.
pub trait SignatureInspector {
    fn inspect(&self, path: &Path) -> io::Result<Value>;
}

/// Who verifies that the observed process is the launched one, live, with
/// the launch's complete argv and the listener (Swift `validateManagedProcess`).
pub trait ManagedProcessVerifier {
    fn verifies(&self, receipt: &ServerIdentityReceipt, arguments: &[String]) -> bool;
}

/// Swift `HDCServerState` as the ownership decision reads it: the supervisor's
/// record for the endpoint, read before and after the observation and only
/// believed when both reads are equal.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SupervisedServer {
    pub endpoint: String,
    pub healthy: bool,
    pub generation: i64,
    pub ark_deck_managed: bool,
}

/// The host-wide supervisor, when the daemon composes one.
pub trait SupervisorState {
    fn state(&self, endpoint: &str) -> Option<SupervisedServer>;
}

/// The fresh status of the configured tool and its endpoint.
pub struct HdcStatusObserver<'a> {
    executable: StatusExecutable,
    startup: StartupDiagnostics,
    daemon_version: Option<String>,
    managed_launch: &'a dyn Fn() -> Option<ManagedLaunch>,
    supervisor: Option<&'a dyn SupervisorState>,
    identity: &'a dyn IdentityObserver,
    signature: &'a dyn SignatureInspector,
    verifier: &'a dyn ManagedProcessVerifier,
    now_utc: &'a dyn Fn() -> String,
}

impl<'a> HdcStatusObserver<'a> {
    /// Swift's designated initializer: the daemon passes its launch record
    /// (`activeLaunch`), its supervisor and its version; the production
    /// observer, signature inspection and process verification are
    /// `CommandlessIdentity`, `NativeSignature` and `SystemManagedProcess`.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        executable: StatusExecutable,
        startup: StartupDiagnostics,
        daemon_version: Option<String>,
        managed_launch: &'a dyn Fn() -> Option<ManagedLaunch>,
        supervisor: Option<&'a dyn SupervisorState>,
        identity: &'a dyn IdentityObserver,
        signature: &'a dyn SignatureInspector,
        verifier: &'a dyn ManagedProcessVerifier,
        now_utc: &'a dyn Fn() -> String,
    ) -> Self {
        Self {
            executable,
            startup,
            daemon_version,
            managed_launch,
            supervisor,
            identity,
            signature,
            verifier,
            now_utc,
        }
    }

    /// Swift `snapshot`: the configured facts first, then everything the
    /// pinned tool, its signature and one identity observation prove. Any
    /// failure of the tool itself — unopenable, not the configured digest,
    /// changed under the observation or under the ownership check, an
    /// unreadable signature — withdraws every tool fact but the configured
    /// ones: `hdc.toolIdentityOrSignatureInvalid`, unavailable.
    pub fn snapshot(&self) -> Value {
        let mut fields = empty(self.daemon_version.as_deref());
        fields.insert("observedAt".into(), Value::String((self.now_utc)()));
        fields.insert("executablePath".into(), json!(self.executable.path));
        fields.insert("executableSource".into(), json!("runtimeConfiguration"));
        fields.insert(
            "configuredExecutableSHA256".into(),
            json!(self.executable.sha256),
        );
        fields.insert("endpoint".into(), json!(self.startup.endpoint));
        fields.insert("endpointSource".into(), json!(self.startup.endpoint_source));
        fields.insert(
            "serverEndpointRef".into(),
            json!(server_endpoint_ref(&self.startup.endpoint)),
        );
        fields.insert(
            "startupVersions".into(),
            json!({"client": self.startup.client_version, "server": self.startup.server_version}),
        );
        if self.observe(&mut fields).is_err() {
            fields.insert("availability".into(), json!("unavailable"));
            fields.insert(
                "reasonCode".into(),
                json!("hdc.toolIdentityOrSignatureInvalid"),
            );
            for key in [
                "executableSHA256",
                "signature",
                "clientVersion",
                "clientVersionSource",
                "generation",
                "processId",
            ] {
                fields.insert(key.into(), Value::Null);
            }
            fields.insert("ownership".into(), json!("unknown"));
        }
        Value::Object(fields)
    }

    fn observe(&self, fields: &mut Map<String, Value>) -> io::Result<()> {
        let pinned = VerifiedTool::open(&self.executable.path, &self.executable.sha256)?;
        let signature = self.signature.inspect(pinned.path())?;
        pinned.revalidate()?;
        let launched_before = (self.managed_launch)();
        let supervised_before = self
            .supervisor
            .and_then(|supervisor| supervisor.state(&self.startup.endpoint));
        let result = self
            .identity
            .observe(&self.executable, &self.startup.endpoint);
        let supervised_after = self
            .supervisor
            .and_then(|supervisor| supervisor.state(&self.startup.endpoint));
        pinned.revalidate()?;
        fields.insert("executableSHA256".into(), json!(self.executable.sha256));
        fields.insert("signature".into(), signature);
        let client_version = registered_version(std::env::consts::OS, &self.executable.sha256);
        fields.insert(
            "clientVersion".into(),
            client_version.map_or(Value::Null, |version| json!(version)),
        );
        fields.insert(
            "clientVersionSource".into(),
            if client_version.is_some() {
                json!("publishedExecutableDigest")
            } else {
                Value::Null
            },
        );
        match result {
            IdentityObservation::Observed {
                generation: observed,
                identity,
            } => {
                // The receipt must be the selected tool at the selected
                // endpoint, born as the generation says; anything else is a
                // mismatch that claims nothing (availability stays unknown).
                let matching = identity.filter(|receipt| {
                    observed > 0
                        && generation(receipt).and_then(|value| i64::try_from(value).ok())
                            == Some(observed)
                        && receipt.executable_sha256 == self.executable.sha256
                        && receipt.executable_path == Path::new(&self.executable.path)
                        && receipt.endpoint.to_string() == self.startup.endpoint
                });
                let Some(receipt) = matching else {
                    fields.insert("reasonCode".into(), json!("hdc.identityMismatch"));
                    return Ok(());
                };
                fields.insert("availability".into(), json!("available"));
                fields.insert("generation".into(), json!(observed.to_string()));
                fields.insert("processId".into(), json!(receipt.pid));
                // Equality with the original spawn receipt, read again on both
                // sides of the verification, not tool path or PID alone; else
                // the supervisor's unchanged, healthy, managed record of this
                // very generation.
                let launched_after = (self.managed_launch)();
                let managed = match &launched_before {
                    Some(launch)
                        if launched_after.as_ref() == Some(launch) && launch.matches(&receipt) =>
                    {
                        self.verifier.verifies(&receipt, &launch.arguments)
                            && (self.managed_launch)().as_ref() == Some(launch)
                    }
                    _ => match &supervised_before {
                        Some(before) => {
                            supervised_after.as_ref() == Some(before)
                                && before.endpoint == self.startup.endpoint
                                && before.healthy
                                && before.generation == observed
                                && before.ark_deck_managed
                        }
                        None => false,
                    },
                };
                pinned.revalidate()?;
                fields.insert(
                    "ownership".into(),
                    json!(if managed { "arkDeckManaged" } else { "unknown" }),
                );
                fields.insert(
                    "reasonCode".into(),
                    json!(if managed {
                        "hdc.identityObserved"
                    } else {
                        "hdc.ownershipUnproven"
                    }),
                );
            }
            IdentityObservation::Unavailable(_) => {
                fields.insert("availability".into(), json!("unavailable"));
                fields.insert("reasonCode".into(), json!("hdc.selectedServerNotObserved"));
            }
            IdentityObservation::Unsupported(_) => {
                fields.insert("availability".into(), json!("unavailable"));
                fields.insert("reasonCode".into(), json!("hdc.identityFamilyUnavailable"));
            }
            IdentityObservation::TimedOut => {
                fields.insert(
                    "reasonCode".into(),
                    json!("hdc.identityObservationTimedOut"),
                );
            }
            IdentityObservation::Cancelled => {
                fields.insert(
                    "reasonCode".into(),
                    json!("hdc.identityObservationCancelled"),
                );
            }
            IdentityObservation::Unknown(_) => {
                fields.insert("reasonCode".into(), json!("hdc.identityUnknown"));
            }
        }
        Ok(())
    }
}

/// Swift `HeadlessHDCStatusObserver.unconfigured`: the daemon without a
/// configured tool — the empty object, unavailable, `hdc.notConfigured`.
pub fn unconfigured_status(daemon_version: Option<&str>) -> Value {
    let mut fields = empty(daemon_version);
    fields.insert("availability".into(), json!("unavailable"));
    Value::Object(fields)
}

/// The object's `serverEndpointRef`: `hdc-endpoint:` and the SHA-256 of the
/// endpoint's spelling.
pub fn server_endpoint_ref(endpoint: &str) -> String {
    format!("hdc-endpoint:{}", sha256_hex(endpoint.as_bytes()))
}

/// Swift `empty`: the twenty-three members and what they are before
/// anything is observed. `snapshot` only overwrites values; no member is
/// ever added or removed.
fn empty(daemon_version: Option<&str>) -> Map<String, Value> {
    let Value::Object(fields) = json!({
        "schemaVersion": STATUS_SCHEMA_VERSION,
        "availability": "unknown",
        "observedAt": null,
        "executablePath": null,
        "executableSource": null,
        "configuredExecutableSHA256": null,
        "executableSHA256": null,
        "signature": null,
        "clientVersion": null,
        "clientVersionSource": null,
        "serverVersion": null,
        "daemonVersion": daemon_version,
        "endpoint": null,
        "endpointSource": null,
        "serverEndpointRef": null,
        "ownership": "unknown",
        "generation": null,
        "processId": null,
        "serverHealth": "unknown",
        "healthReasonCode": "hdc.commandlessIdentityDoesNotProveHealth",
        "startupVersions": null,
        "reasonCode": "hdc.notConfigured",
        "newDispatchCount": 0,
    }) else {
        unreachable!("an object literal")
    };
    fields
}

/// Swift `HDCCommandlessServerIdentity.observe`: the read-only composition of
/// the published identity families. The 3.2.0f catalog observes only at its
/// exact endpoint, the 3.2.0d registry at the selected loopback endpoint;
/// any other tool or endpoint has no family (`Unsupported`). The observation
/// is the kernel proof `LoopbackServerLease::acquire` performs — no connect,
/// no client, not even `checkserver` — raced against the family's deadline,
/// and an observed receipt must still name the selected tool (its canonical
/// path and digest), the endpoint and a representable birth.
///
/// Beyond Swift: the proof refuses a server another user owns (`Unknown`
/// rather than an observed identity), and the deadline abandons the scan
/// rather than cancelling it (`Cancelled` is never produced here).
pub struct CommandlessIdentity {
    deadline: Duration,
}

impl Default for CommandlessIdentity {
    fn default() -> Self {
        Self {
            deadline: OBSERVATION_DEADLINE,
        }
    }
}

impl CommandlessIdentity {
    /// The catalog's deadline is 1000 ms; a test may shorten it.
    pub fn with_deadline(deadline: Duration) -> Self {
        Self { deadline }
    }

    /// Swift's family selection: `3.2.0f` at the exact endpoint, `3.2.0d`
    /// anywhere, nothing otherwise.
    pub fn family(executable_sha256: &str, endpoint: &str) -> Option<&'static str> {
        match registered_version(std::env::consts::OS, executable_sha256) {
            Some("3.2.0f") if endpoint == EXACT_ENDPOINT => Some("3.2.0f"),
            Some("3.2.0d") => Some("3.2.0d"),
            _ => None,
        }
    }
}

impl IdentityObserver for CommandlessIdentity {
    fn observe(&self, executable: &StatusExecutable, endpoint: &str) -> IdentityObservation {
        if Self::family(&executable.sha256, endpoint).is_none() {
            return IdentityObservation::Unsupported(
                "selected executable or endpoint has no published commandless identity family"
                    .to_owned(),
            );
        }
        let Ok(address) = endpoint.parse::<SocketAddrV4>() else {
            return IdentityObservation::Unknown(
                "selected endpoint is not an IPv4 socket address".to_owned(),
            );
        };
        let (sender, receiver) = mpsc::channel();
        let path = executable.path.clone();
        let sha256 = executable.sha256.clone();
        std::thread::spawn(move || {
            let outcome = VerifiedTool::open(&path, &sha256).and_then(|tool| {
                LoopbackServerLease::acquire(&tool, address).map(|lease| lease.identity().clone())
            });
            let _ = sender.send(outcome);
        });
        let receipt = match receiver.recv_timeout(self.deadline) {
            Err(mpsc::RecvTimeoutError::Timeout) => return IdentityObservation::TimedOut,
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                return IdentityObservation::Unknown(
                    "identity observation produced no result".to_owned(),
                );
            }
            Ok(Err(error)) if error.kind() == io::ErrorKind::NotFound => {
                return IdentityObservation::Unavailable(error.to_string());
            }
            Ok(Err(error)) => return IdentityObservation::Unknown(error.to_string()),
            Ok(Ok(receipt)) => receipt,
        };
        let selected = std::fs::canonicalize(&executable.path).ok();
        let generation = generation(&receipt).and_then(|value| i64::try_from(value).ok());
        match generation {
            Some(generation)
                if receipt.pid > 0
                    && receipt.start_microseconds < 1_000_000
                    && receipt.endpoint == address
                    && receipt.executable_sha256 == executable.sha256
                    && selected.as_deref() == Some(receipt.executable_path.as_path()) =>
            {
                IdentityObservation::Observed {
                    generation,
                    identity: Some(receipt),
                }
            }
            _ => IdentityObservation::Unknown(
                "observed identity does not match the selected tool and endpoint".to_owned(),
            ),
        }
    }
}

/// Swift `HeadlessHDCStatusObserver.signature`: the static signing facts of
/// the tool (`state`, `identifier`, `teamIdentifier`) with the two constants
/// that say what this reading is not — no platform trust was established and
/// no execution assessment was performed. Reading fails when the signature
/// is invalid or its metadata is unreadable or out of bounds.
pub struct NativeSignature;

impl SignatureInspector for NativeSignature {
    fn inspect(&self, path: &Path) -> io::Result<Value> {
        let signature = inspect_native_code_signature(path)?;
        Ok(json!({
            "state": signature.signature,
            "identifier": signature.identifier,
            "teamIdentifier": signature.team_identifier,
            "platformTrust": "unverified",
            "executionAssessment": "notPerformed",
        }))
    }
}

/// Swift `HDCCommandlessServerIdentity.verifiesManagedProcess` over the
/// kernel: `arkdeck_platform::verifies_managed_process`.
pub struct SystemManagedProcess;

impl ManagedProcessVerifier for SystemManagedProcess {
    fn verifies(&self, receipt: &ServerIdentityReceipt, arguments: &[String]) -> bool {
        verifies_managed_process(receipt, arguments)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sha2::{Digest, Sha256};
    use std::cell::Cell;
    use std::net::Ipv4Addr;

    /// A tool the runner may pin: root-owned, not group/world-writable.
    fn shell() -> StatusExecutable {
        let path = std::fs::canonicalize("/bin/sh").unwrap();
        let sha256 = format!("{:x}", Sha256::digest(std::fs::read(&path).unwrap()));
        StatusExecutable {
            path: path.to_string_lossy().into_owned(),
            sha256,
        }
    }

    fn startup(executable: &StatusExecutable) -> StartupDiagnostics {
        StartupDiagnostics {
            executable_sha256: executable.sha256.clone(),
            client_version: "cached-client".into(),
            server_version: "cached-server".into(),
            endpoint: EXACT_ENDPOINT.into(),
            endpoint_source: "default".into(),
        }
    }

    fn receipt(executable: &StatusExecutable) -> ServerIdentityReceipt {
        ServerIdentityReceipt {
            pid: 42,
            start_seconds: 100,
            start_microseconds: 23,
            executable_path: executable.path.clone().into(),
            executable_sha256: executable.sha256.clone(),
            endpoint: SocketAddrV4::new(Ipv4Addr::LOCALHOST, 8710),
        }
    }

    fn launch(executable: &StatusExecutable) -> ManagedLaunch {
        ManagedLaunch {
            pid: 42,
            start_seconds: 100,
            start_microseconds: 23,
            executable_path: executable.path.clone(),
            executable_sha256: executable.sha256.clone(),
            arguments: vec!["-s".into(), EXACT_ENDPOINT.into(), "-m".into()],
        }
    }

    struct Observed(IdentityObservation);
    impl IdentityObserver for Observed {
        fn observe(&self, _: &StatusExecutable, _: &str) -> IdentityObservation {
            self.0.clone()
        }
    }
    struct Signed;
    impl SignatureInspector for Signed {
        fn inspect(&self, _: &Path) -> io::Result<Value> {
            Ok(json!({"state": "testOnly"}))
        }
    }
    struct Verified(bool);
    impl ManagedProcessVerifier for Verified {
        fn verifies(&self, _: &ServerIdentityReceipt, arguments: &[String]) -> bool {
            self.0 && arguments == ["-s", EXACT_ENDPOINT, "-m"]
        }
    }
    struct Supervised(Vec<Option<SupervisedServer>>, Cell<usize>);
    impl SupervisorState for Supervised {
        fn state(&self, _: &str) -> Option<SupervisedServer> {
            let index = self.1.get();
            self.1.set(index + 1);
            self.0[index.min(self.0.len() - 1)].clone()
        }
    }

    fn observed(executable: &StatusExecutable) -> Observed {
        Observed(IdentityObservation::Observed {
            generation: 100_000_023,
            identity: Some(receipt(executable)),
        })
    }

    fn snapshot(
        executable: &StatusExecutable,
        launches: &dyn Fn() -> Option<ManagedLaunch>,
        supervisor: Option<&dyn SupervisorState>,
        identity: &dyn IdentityObserver,
        verifier: &dyn ManagedProcessVerifier,
    ) -> Map<String, Value> {
        let now = || "2026-09-14T00:00:00Z".to_owned();
        let observer = HdcStatusObserver::new(
            executable.clone(),
            startup(executable),
            Some("test-daemon".into()),
            launches,
            supervisor,
            identity,
            &Signed,
            verifier,
            &now,
        );
        let Value::Object(fields) = observer.snapshot() else {
            panic!("an object")
        };
        fields
    }

    #[test]
    fn the_empty_object_has_its_twenty_three_members_and_unconfigured_is_unavailable() {
        assert_eq!(empty(None).len(), 23);
        let Value::Object(fields) = unconfigured_status(None) else {
            panic!("an object")
        };
        assert_eq!(fields["availability"], "unavailable");
        assert_eq!(fields["reasonCode"], "hdc.notConfigured");
        assert_eq!(fields["daemonVersion"], Value::Null);
        assert_eq!(fields["newDispatchCount"], 0);
        assert_eq!(
            unconfigured_status(Some("1.0"))["daemonVersion"],
            json!("1.0")
        );
        assert_eq!(
            server_endpoint_ref(EXACT_ENDPOINT),
            "hdc-endpoint:a29f70813dca5c16bc287e590177e3b9da8354d2d3409abcede8b1c0d0bd420e"
        );
    }

    /// The launch route: the same launch on all three reads, matching the
    /// receipt, verified live — managed. A launch that changes between the
    /// reads, or a verification that fails, leaves ownership unproven while
    /// the identity stays available.
    #[test]
    fn ownership_is_managed_only_through_an_unchanged_verified_launch() {
        let tool = shell();
        let launch = launch(&tool);
        let same = || Some(launch.clone());
        let managed = snapshot(&tool, &same, None, &observed(&tool), &Verified(true));
        assert_eq!(managed["ownership"], "arkDeckManaged");
        assert_eq!(managed["reasonCode"], "hdc.identityObserved");
        assert_eq!(managed["availability"], "available");
        assert_eq!(managed["generation"], "100000023");
        assert_eq!(managed["processId"], 42);
        assert_eq!(managed["executableSHA256"], json!(tool.sha256));
        assert_eq!(managed["signature"], json!({"state": "testOnly"}));
        assert_eq!(managed["daemonVersion"], "test-daemon");
        assert_eq!(managed["clientVersion"], Value::Null);
        assert_eq!(managed["serverVersion"], Value::Null);
        assert_eq!(managed["serverHealth"], "unknown");
        let unverified = snapshot(&tool, &same, None, &observed(&tool), &Verified(false));
        assert_eq!(unverified["ownership"], "unknown");
        assert_eq!(unverified["reasonCode"], "hdc.ownershipUnproven");
        assert_eq!(unverified["availability"], "available");
        let reads = Cell::new(0);
        let changing = || {
            reads.set(reads.get() + 1);
            let mut launch = launch.clone();
            if reads.get() == 3 {
                launch.start_seconds = 101;
            }
            Some(launch)
        };
        let changed = snapshot(&tool, &changing, None, &observed(&tool), &Verified(true));
        assert_eq!(changed["ownership"], "unknown");
        assert_eq!(changed["reasonCode"], "hdc.ownershipUnproven");
        let none = || None;
        let unowned = snapshot(&tool, &none, None, &observed(&tool), &Verified(true));
        assert_eq!(unowned["ownership"], "unknown");
        assert_eq!(unowned["generation"], "100000023");
    }

    /// The supervisor route: the record read before and after must be equal,
    /// healthy, managed and of the observed generation; another generation
    /// or a record that changed proves nothing.
    #[test]
    fn ownership_is_managed_through_an_unchanged_healthy_supervisor_record() {
        let tool = shell();
        let none = || None;
        let state = |generation: i64| SupervisedServer {
            endpoint: EXACT_ENDPOINT.into(),
            healthy: true,
            generation,
            ark_deck_managed: true,
        };
        let steady = Supervised(vec![Some(state(100_000_023))], Cell::new(0));
        let managed = snapshot(
            &tool,
            &none,
            Some(&steady),
            &observed(&tool),
            &Verified(true),
        );
        assert_eq!(managed["ownership"], "arkDeckManaged");
        assert_eq!(managed["reasonCode"], "hdc.identityObserved");
        let other = Supervised(vec![Some(state(7))], Cell::new(0));
        let unproven = snapshot(
            &tool,
            &none,
            Some(&other),
            &observed(&tool),
            &Verified(true),
        );
        assert_eq!(unproven["ownership"], "unknown");
        let changed = Supervised(
            vec![Some(state(100_000_023)), Some(state(100_000_024))],
            Cell::new(0),
        );
        let drifted = snapshot(
            &tool,
            &none,
            Some(&changed),
            &observed(&tool),
            &Verified(true),
        );
        assert_eq!(drifted["ownership"], "unknown");
        let unhealthy = Supervised(
            vec![Some(SupervisedServer {
                healthy: false,
                ..state(100_000_023)
            })],
            Cell::new(0),
        );
        let sick = snapshot(
            &tool,
            &none,
            Some(&unhealthy),
            &observed(&tool),
            &Verified(true),
        );
        assert_eq!(sick["ownership"], "unknown");
    }

    /// The families: only the two registered digests, the 3.2.0f one only
    /// at its exact endpoint. A digest outside them is unsupported before
    /// any kernel scan.
    #[test]
    fn the_identity_families_are_the_registered_digests() {
        let f = "05b2bf7ad30201c082da336db28f8856952a2b2f49ac3404b96fdb4bf1a68f83";
        let d = "48395ba8d87115dffca47df2a640a6c868bc9a2bd4eb49611e4138ff88d8d260";
        assert_eq!(
            CommandlessIdentity::family(f, EXACT_ENDPOINT),
            Some("3.2.0f")
        );
        assert_eq!(CommandlessIdentity::family(f, "127.0.0.1:8711"), None);
        assert_eq!(
            CommandlessIdentity::family(d, "127.0.0.1:8711"),
            Some("3.2.0d")
        );
        assert_eq!(
            CommandlessIdentity::family(&"0".repeat(64), EXACT_ENDPOINT),
            None
        );
        let tool = shell();
        assert!(matches!(
            CommandlessIdentity::default().observe(&tool, EXACT_ENDPOINT),
            IdentityObservation::Unsupported(_)
        ));
    }
}
