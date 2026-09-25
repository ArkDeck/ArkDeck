//! `runtime service status|verify|restart`: the one production Runtime as a
//! user-domain LaunchAgent, read and restarted as Swift's `LaunchAgentService`
//! and `RuntimeCLI.runAgentDaemon` read and restart it. `install`, `update`
//! and `uninstall` are `runtime_service_install.rs`.
//!
//! The service is `com.arkdeck.agentd` in `gui/<uid>`: its plist under
//! `~/Library/LaunchAgents`, the helper bundle, install receipt, logs and
//! state below the account home. `status` validates the plist, the installed
//! helper and the two executable identities against the receipt, asks launchd
//! whether the service is loaded and asks the daemon for `health`. `verify
//! --job` reopens one completed, profiled Job through durable reads only.
//! `restart` proves the service ready, refuses while a current Job is not a
//! closed unknown-outcome recovery lane (the shared preflight table's
//! restart rule), boots the service out and back in, and waits for a new
//! process speaking the same catalog. launchd is reached only through
//! [`arkdeck_platform::launchd`]: fixed argument arrays, one fixed executable.
//!
//! Declared differences from Swift:
//! - Paths are physical. Foundation's `standardizedFileURL` and
//!   `resolvingSymlinksInPath` also drop a leading `/private` whose remainder
//!   exists; this module keeps it, as the Rust daemon's own layout does, so the
//!   two agree. Only paths under `/private` (a relocated test home, a tool
//!   under `/tmp`) spell differently; the account's home never does.
//! - A home relocated with `CFFIXED_USER_HOME` never drives the account's
//!   launchd domain (`launchd.rs`).
//! - `verify` without `--job` runs its fresh `observe.device@1` as a
//!   Runtime-owned `agent run` through the daemon and then reopens the Job it
//!   produced as `verify --job` does, where Swift ran it through its
//!   client-side executor (`AgentRuntimeExecutor`, 协调会话受托裁定
//!   2026-09-24); `runtime` is the reopen report and `agentExecution` the
//!   settled execution.
//! - Human output is the JSON document, as every other leaf of this CLI.
use crate::Invocation;
use crate::runtime_service_install;
use crate::runtime_service_verify::{self, FreshOutcome, ReopenOutcome};
use arkdeck_client::{Client, ClientError};
use arkdeck_contract::arkforge_bundle;
use arkdeck_platform::launchd::{self, LaunchctlOutput, LaunchctlRunner};
use arkdeck_platform::{LocalEndpoint, PropertyListValue, ServerIdentity};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::io;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

pub(crate) const LABEL: &str = launchd::AGENT_LABEL;
pub(crate) const HDC_KEY: &str = "ARKDECK_HDC_PATH";
pub(crate) const WORKSPACE_PROJECTS_KEY: &str = "ARKDECK_WORKSPACE_PROJECTS";
pub(crate) const WORKSPACE_ACTIVE_PROJECT_KEY: &str = "ARKDECK_WORKSPACE_ACTIVE_PROJECT";
pub(crate) const DEVECO_SDK_KEY: &str = "ARKDECK_DEVECO_SDK_HOME";
pub(crate) const ANALYZER_KEY: &str = "ARKDECK_ANALYZER_PATH";
pub(crate) const WORKSPACE_INSPECTOR_KEY: &str = "ARKDECK_WORKSPACE_INSPECTOR";
pub(crate) const WORKSPACE_INSPECTOR: &str = "/usr/bin/grep";
pub(crate) const ARKTRACE_DESCRIPTOR_KEY: &str = "ARKDECK_ARKTRACE_DESCRIPTOR";
pub(crate) const ARKFORGE_BUNDLE_KEY: &str = "ARKDECK_ARKFORGE_BUNDLE_PATH";
pub(crate) const ARKFORGE_CAMPAIGN_KEY: &str = "ARKDECK_ARKFORGE_CAMPAIGN";
const RETIRED_ARKFORGE_KEYS: [&str; 3] = [
    "ARKDECK_ARKFORGED_PATH",
    "ARKDECK_ARKFORGED_SHA256",
    "ARKDECK_ARKFORGE_PROFILE_PATH",
];
pub(crate) const SWIFT_SHA256_KEY: &str = "ARKDECK_SWIFT_SHA256";
pub(crate) const WATERFLOW_PROJECT_REF: &str = "demo-app";
const ARKFORGE_DEVICE_PROFILE: &str = "org.openharmony.dayu200";
pub(crate) const DAEMON_BUNDLE_NAME: &str = "ArkDeckAgent.app";
pub(crate) const DAEMON_EXECUTABLE_NAME: &str = "arkdeck-agentd";
const FACADE_EXECUTABLE_NAME: &str = "arkdeck-facade";
pub(crate) const RECEIPT_SCHEMA: &str = "arkdeck-launchagent-install/v1";
const RESTART_SCHEMA: &str = "arkdeck-launchagent-restart/v1";
const RESTART_PROOF_SCHEMA: &str = "arkdeck-launchagent-restart-proof/v1";
const ARKTRACE_DESCRIPTOR_MAXIMUM: u64 = 16 * 1024;
/// A plist, receipt or instance document larger than this is not read.
pub(crate) const DOCUMENT_MAXIMUM: u64 = 1024 * 1024;
const EIO: i32 = 5;

// MARK: - Paths

// Foundation's path arithmetic, shared with the daemon's ArkForge lane.
pub(crate) use arkdeck_contract::foundation_path::{lexical, resolved};

pub(crate) fn sha256_file(path: &Path) -> io::Result<String> {
    Ok(arkdeck_contract::sha256_hex(&std::fs::read(path)?))
}

pub(crate) fn text(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

pub(crate) use crate::utc_now;

/// Swift `LaunchAgentPaths`: every file of the service below one home.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LaunchAgentPaths {
    pub home: PathBuf,
    pub plist: PathBuf,
    pub installed_daemon_bundle: PathBuf,
    pub installed_daemon: PathBuf,
    pub receipt: PathBuf,
    pub log_directory: PathBuf,
    pub standard_output: PathBuf,
    pub standard_error: PathBuf,
    pub state_directory: PathBuf,
    pub socket: PathBuf,
    /// `Helpers/.rollback/ArkDeckAgent.app`: the helper an `update` replaced,
    /// kept one generation (协调会话受托裁定 2026-09-24).
    pub rollback_bundle: PathBuf,
    /// `LaunchAgent/cutover-snapshots`: one snapshot summary of the old state
    /// directory per M5 cutover.
    pub cutover_snapshots: PathBuf,
    /// Swift `OpenHarmonySigningPresetStore.receiptPath`.
    pub signing_receipt: PathBuf,
    /// `…/ArkDeck/Bootstrap/v1`: the Bootstrap registry whose installation
    /// reference a typed install pins and an uninstall releases.
    pub bootstrap_registry: PathBuf,
}

impl LaunchAgentPaths {
    pub fn for_home(home: &Path) -> Self {
        let home = lexical(home);
        let library = home.join("Library");
        let support = library.join("Application Support/ArkDeck");
        let installed_daemon_bundle = support.join("Helpers").join(DAEMON_BUNDLE_NAME);
        let log_directory = library.join("Logs/ArkDeck");
        let state_directory = support.join("Agentd");
        Self {
            rollback_bundle: support.join("Helpers/.rollback").join(DAEMON_BUNDLE_NAME),
            cutover_snapshots: support.join("LaunchAgent/cutover-snapshots"),
            signing_receipt: support.join("Signing/OpenHarmony/preset-v1.json"),
            bootstrap_registry: support.join("Bootstrap/v1"),
            plist: library.join(format!("LaunchAgents/{LABEL}.plist")),
            installed_daemon: installed_daemon_bundle
                .join(format!("Contents/MacOS/{DAEMON_EXECUTABLE_NAME}")),
            installed_daemon_bundle,
            receipt: support.join("LaunchAgent/install-receipt.json"),
            standard_output: log_directory.join("agentd.log"),
            standard_error: log_directory.join("agentd.error.log"),
            log_directory,
            socket: state_directory.join("agentd.sock"),
            state_directory,
            home,
        }
    }
}

// MARK: - Errors and answers

/// Swift `LaunchAgentServiceError` and the Foundation failures its callers let
/// through; either leaves the CLI at exit 1 with only a stderr diagnostic.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ServiceError {
    InvalidExecutable(String),
    Launchctl(String),
    Configuration(String),
    Other(String),
}

impl std::fmt::Display for ServiceError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidExecutable(detail) => write!(f, "invalid executable: {detail}"),
            Self::Launchctl(detail) => write!(f, "launchctl failed: {detail}"),
            Self::Configuration(detail) => {
                write!(f, "LaunchAgent configuration failed: {detail}")
            }
            Self::Other(detail) => f.write_str(detail),
        }
    }
}

impl From<io::Error> for ServiceError {
    fn from(error: io::Error) -> Self {
        Self::Other(error.to_string())
    }
}

/// Swift's plain `CLIError`: its exit status and a stderr diagnostic, never a
/// machine document.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PlainFailure {
    pub exit_code: u8,
    pub message: String,
}

impl PlainFailure {
    pub(crate) fn new(exit_code: u8, message: impl Into<String>) -> Self {
        Self {
            exit_code,
            message: message.into(),
        }
    }
}

impl From<ServiceError> for PlainFailure {
    fn from(error: ServiceError) -> Self {
        Self::new(1, error.to_string())
    }
}

/// Swift's session failure (`CLIRuntimeSession.fail`): a code of the error
/// registry, its words and details, answered as every coded refusal is — the
/// failure envelope in machine output, `arkdeck: <message>` on stderr
/// otherwise — with the code's exit status.
#[derive(Clone, Debug, PartialEq)]
pub struct CodedFailure {
    pub code: &'static str,
    pub message: String,
    pub details: Map<String, Value>,
}

/// What one `runtime service` invocation answers: the one document it emits,
/// if any, and the failure that follows it, if any. A failure after a
/// document keeps the document and reports itself only on stderr and in the
/// exit status, as Swift's session does once it has emitted.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ServiceAnswer {
    pub document: Option<Value>,
    pub failure: Option<PlainFailure>,
    /// A coded failure in place of a plain one (Swift `session.fail`).
    pub refusal: Option<CodedFailure>,
}

impl ServiceAnswer {
    pub(crate) fn emit(document: Value) -> Self {
        Self {
            document: Some(document),
            ..Self::default()
        }
    }

    pub(crate) fn fail(failure: PlainFailure) -> Self {
        Self {
            failure: Some(failure),
            ..Self::default()
        }
    }

    pub(crate) fn refuse(refusal: CodedFailure) -> Self {
        Self {
            refusal: Some(refusal),
            ..Self::default()
        }
    }

    pub(crate) fn emit_then_fail(document: Value, failure: PlainFailure) -> Self {
        Self {
            document: Some(document),
            failure: Some(failure),
            refusal: None,
        }
    }
}

// MARK: - Receipt and lane facts

/// Swift `LaunchAgentArkTraceDescriptorStatus`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ArkTraceDescriptorStatus {
    pub descriptor_path: String,
    pub descriptor_sha256: String,
    pub descriptor_byte_count: i64,
}

impl ArkTraceDescriptorStatus {
    pub(crate) fn json(&self) -> Value {
        json!({"descriptorPath": self.descriptor_path,
            "descriptorSHA256": self.descriptor_sha256,
            "descriptorByteCount": self.descriptor_byte_count})
    }

    fn decode(value: &Value) -> Option<Self> {
        Some(Self {
            descriptor_path: value.get("descriptorPath")?.as_str()?.to_owned(),
            descriptor_sha256: value.get("descriptorSHA256")?.as_str()?.to_owned(),
            descriptor_byte_count: value.get("descriptorByteCount")?.as_i64()?,
        })
    }
}

/// Swift `LaunchAgentArkForgeLaneStatus`: the one ArkForge release unit the
/// installation pins, with the manifest-derived facts status compares.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ArkForgeLaneStatus {
    pub bundle_path: String,
    pub manifest_sha256: String,
    pub daemon_path: String,
    pub daemon_sha256: String,
    pub device_profile_path: String,
    pub campaign: String,
}

impl ArkForgeLaneStatus {
    pub(crate) fn json(&self) -> Value {
        json!({"bundlePath": self.bundle_path, "manifestSHA256": self.manifest_sha256,
            "daemonPath": self.daemon_path, "daemonSHA256": self.daemon_sha256,
            "deviceProfilePath": self.device_profile_path, "campaign": self.campaign})
    }

    fn decode(value: &Value) -> Option<Self> {
        let text = |key: &str| value.get(key)?.as_str().map(str::to_owned);
        Some(Self {
            bundle_path: text("bundlePath")?,
            manifest_sha256: text("manifestSHA256")?,
            daemon_path: text("daemonPath")?,
            daemon_sha256: text("daemonSHA256")?,
            device_profile_path: text("deviceProfilePath")?,
            campaign: text("campaign")?,
        })
    }

    /// Swift `LaunchAgentArkForgeLaneStatus.measuring`: resolves and
    /// independently verifies every manifest-declared member.
    pub(crate) fn measuring(bundle_path: &str, campaign: &str) -> Result<Self, LaneRefusal> {
        if !bundle_path.starts_with('/') {
            return Err(LaneRefusal::NotAbsolute(bundle_path.to_owned()));
        }
        let bundle = arkforge_bundle::load(Path::new(bundle_path))
            .map_err(|error| LaneRefusal::InvalidBundle(error.to_string()))?;
        let Some(profile) = bundle.profiles.get(ARKFORGE_DEVICE_PROFILE) else {
            return Err(LaneRefusal::MissingProfile(ARKFORGE_DEVICE_PROFILE.into()));
        };
        let daemon_sha256 = sha256_file(&bundle.daemon)
            .map_err(|error| LaneRefusal::InvalidBundle(error.to_string()))?;
        Ok(Self {
            bundle_path: text(&bundle.root),
            manifest_sha256: bundle.manifest_sha256.clone(),
            daemon_path: text(&bundle.daemon),
            daemon_sha256,
            device_profile_path: text(profile),
            campaign: campaign.trim_matches(swift_whitespace).to_owned(),
        })
    }
}

/// Foundation's `CharacterSet.whitespaces`: the space separators (Unicode
/// category Zs) and the tab.
fn swift_whitespace(character: char) -> bool {
    matches!(
        character,
        '\t' | ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200a}' | '\u{202f}' | '\u{205f}' | '\u{3000}'
    )
}

/// Swift `LaunchAgentArkForgeLaneStatus.Refusal`: each names what to fix.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LaneRefusal {
    NotAbsolute(String),
    InvalidBundle(String),
    MissingProfile(String),
    RetiredConfiguration(Vec<String>),
}

impl std::fmt::Display for LaneRefusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotAbsolute(path) => write!(f, "{path} is not an absolute ArkForge.bundle path"),
            Self::InvalidBundle(detail) => write!(f, "ArkForge.bundle is invalid: {detail}"),
            Self::MissingProfile(id) => {
                write!(f, "ArkForge.bundle does not publish required profile {id}")
            }
            Self::RetiredConfiguration(keys) => write!(
                f,
                "{} is retired ArkForge lane configuration. Reconfigure this installation with \
                 `arkdeck runtime service update --arkforge-bundle <absolute ArkForge.bundle>`",
                keys.join(", ")
            ),
        }
    }
}

/// Swift `LaunchAgentInstallReceipt`, as `JSONDecoder` reads it: unknown keys
/// are ignored and an optional key may be absent or null.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InstallReceipt {
    pub schema_version: String,
    pub installed_at_utc: String,
    pub daemon_path: String,
    pub daemon_sha256: String,
    pub hdc_path: String,
    pub hdc_sha256: String,
    pub workspace_project_path: Option<String>,
    pub deveco_sdk_path: Option<String>,
    pub ark_trace_descriptor: Option<ArkTraceDescriptorStatus>,
    pub ark_forge_lane: Option<ArkForgeLaneStatus>,
}

impl InstallReceipt {
    pub fn decode(bytes: &[u8]) -> Result<Self, String> {
        let value: Value = serde_json::from_slice(bytes).map_err(|error| error.to_string())?;
        let fields = value.as_object().ok_or("the receipt is not an object")?;
        let required = |key: &str| {
            fields
                .get(key)
                .and_then(Value::as_str)
                .map(str::to_owned)
                .ok_or_else(|| format!("{key} is missing or not a string"))
        };
        let optional = |key: &str| match fields.get(key) {
            None | Some(Value::Null) => Ok(None),
            Some(Value::String(text)) => Ok(Some(text.clone())),
            Some(_) => Err(format!("{key} is not a string")),
        };
        let nested = |key: &str| -> Result<Option<&Value>, String> {
            match fields.get(key) {
                None | Some(Value::Null) => Ok(None),
                Some(value) => Ok(Some(value)),
            }
        };
        Ok(Self {
            schema_version: required("schemaVersion")?,
            installed_at_utc: required("installedAtUTC")?,
            daemon_path: required("daemonPath")?,
            daemon_sha256: required("daemonSHA256")?,
            hdc_path: required("hdcPath")?,
            hdc_sha256: required("hdcSHA256")?,
            workspace_project_path: optional("workspaceProjectPath")?,
            deveco_sdk_path: optional("devecoSDKPath")?,
            ark_trace_descriptor: nested("arkTraceDescriptor")?
                .map(|value| {
                    ArkTraceDescriptorStatus::decode(value)
                        .ok_or_else(|| "arkTraceDescriptor is malformed".to_owned())
                })
                .transpose()?,
            ark_forge_lane: nested("arkForgeLane")?
                .map(|value| {
                    ArkForgeLaneStatus::decode(value)
                        .ok_or_else(|| "arkForgeLane is malformed".to_owned())
                })
                .transpose()?,
        })
    }
}

/// Swift `LaunchAgentStatus`, encoded as Swift's `JSONEncoder` encodes it: an
/// absent optional is omitted, never `null`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct LaunchAgentStatus {
    pub installed: bool,
    pub loaded: bool,
    pub launch_domain: String,
    pub plist_path: String,
    pub daemon_path: Option<String>,
    pub daemon_sha256: Option<String>,
    pub hdc_path: Option<String>,
    pub hdc_sha256: Option<String>,
    pub workspace_project_path: Option<String>,
    pub deveco_sdk_path: Option<String>,
    pub ark_trace_descriptor: Option<ArkTraceDescriptorStatus>,
    pub ark_forge_lane: Option<ArkForgeLaneStatus>,
    pub socket_path: String,
    pub socket_present: bool,
    pub standard_output_path: String,
    pub standard_error_path: String,
    pub diagnostics: Vec<String>,
    pub ready: bool,
}

impl LaunchAgentStatus {
    pub fn json(&self) -> Value {
        let mut fields = Map::new();
        fields.insert("installed".into(), json!(self.installed));
        fields.insert("loaded".into(), json!(self.loaded));
        fields.insert("launchDomain".into(), json!(self.launch_domain));
        fields.insert("plistPath".into(), json!(self.plist_path));
        for (key, value) in [
            ("daemonPath", &self.daemon_path),
            ("daemonSHA256", &self.daemon_sha256),
            ("hdcPath", &self.hdc_path),
            ("hdcSHA256", &self.hdc_sha256),
            ("workspaceProjectPath", &self.workspace_project_path),
            ("devecoSDKPath", &self.deveco_sdk_path),
        ] {
            if let Some(value) = value {
                fields.insert(key.into(), json!(value));
            }
        }
        if let Some(descriptor) = &self.ark_trace_descriptor {
            fields.insert("arkTraceDescriptor".into(), descriptor.json());
        }
        if let Some(lane) = &self.ark_forge_lane {
            fields.insert("arkForgeLane".into(), lane.json());
        }
        fields.insert("socketPath".into(), json!(self.socket_path));
        fields.insert("socketPresent".into(), json!(self.socket_present));
        fields.insert(
            "standardOutputPath".into(),
            json!(self.standard_output_path),
        );
        fields.insert("standardErrorPath".into(), json!(self.standard_error_path));
        fields.insert("diagnostics".into(), json!(self.diagnostics));
        fields.insert("ready".into(), json!(self.ready));
        Value::Object(fields)
    }
}

/// Swift `LaunchAgentDaemonInstance`: the process that holds the daemon's
/// instance lock, as its `instance.json` names it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DaemonInstance {
    pub pid: i32,
    pub socket_path: String,
    pub protocol_version: String,
    pub started_at_utc: String,
}

impl DaemonInstance {
    fn json(&self) -> Value {
        json!({"pid": self.pid, "socketPath": self.socket_path,
            "protocolVersion": self.protocol_version, "startedAtUTC": self.started_at_utc})
    }
}

/// Swift's `ValidatedArkTraceDescriptor`: its `url` is the status's physical
/// path.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct ValidatedDescriptor {
    pub(crate) status: ArkTraceDescriptorStatus,
}

/// Swift `LaunchAgentWorkspaceConfiguration`, validated.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Workspace {
    pub(crate) project_root: String,
    pub(crate) deveco_sdk_root: String,
}

/// Swift `ConfiguredPaths`: what the live plist configures. The lane is
/// carried rather than thrown, so a retired lane name does not cost the
/// daemon, HDC and ArkTrace facts beside it.
struct ConfiguredPaths {
    daemon: String,
    hdc: String,
    workspace: Option<Workspace>,
    descriptor: Option<ValidatedDescriptor>,
    lane: Result<Option<ArkForgeLaneStatus>, LaneRefusal>,
}

// MARK: - The service manager

/// What a service manager reads and runs through: the paths of one home, the
/// caller's user, launchd, the two signature checks and a clock. Production
/// composes the account's own (`ServiceHost::account`); tests compose fakes.
pub struct ServiceHost<'a> {
    pub paths: LaunchAgentPaths,
    pub uid: u32,
    pub launchctl: &'a dyn LaunchctlRunner,
    /// Swift `validateProductionDaemonBundle`: the canonical bundle, or why not.
    pub validate_daemon_bundle: &'a dyn Fn(&Path) -> Result<PathBuf, String>,
    /// The signature check of a helper's sibling facade.
    pub validate_facade: &'a dyn Fn(&Path) -> Result<(), String>,
    /// The Bootstrap registry's trust in a retained helper bundle (Swift
    /// `validateBundle`): the production helper policy, as for `--daemon`.
    pub bundle_trust: arkdeck_bootstrap::BundleValidator,
    /// The published HDC identities an initial tool selection admits (Swift
    /// `knownIdentity`); `None` is the Runtime's own.
    pub hdc_identities: Option<arkdeck_bootstrap::PublishedIdentities>,
    pub now_utc: &'a dyn Fn() -> String,
    /// How long one Runtime connection may wait.
    pub connection_timeout: Duration,
    /// The pause between polls (Swift `usleep(100_000)`).
    pub poll_interval: Duration,
    /// Swift `defaultAgentDaemonBundlePath()`: the helper an `update` without
    /// `--daemon` installs.
    pub default_daemon_bundle: Option<PathBuf>,
    /// Whether the home is relocated with `CFFIXED_USER_HOME`, which the
    /// cutover preflight is then run with too.
    pub relocated_home: bool,
    /// How long one cutover preflight pass may run.
    pub preflight_timeout: Duration,
    /// The spelling the caller typed, `runtime service` or its superseded
    /// `agentd` (CLI spec §12): Swift writes every diagnostic of these leaves
    /// in it, so a message never names a command the caller did not run.
    pub spelling: &'static str,
}

impl ServiceHost<'_> {
    pub fn launch_domain(&self) -> String {
        launchd::user_domain(self.uid)
    }

    pub(crate) fn is_loaded(&self) -> Result<bool, ServiceError> {
        Ok(self
            .launchctl
            .run(&launchd::print_arguments(&self.launch_domain()))
            .map_err(|error| ServiceError::Other(format!("launchctl could not run: {error}")))?
            .status
            == 0)
    }

    pub(crate) fn run_launchctl(
        &self,
        arguments: &[String],
    ) -> Result<LaunchctlOutput, ServiceError> {
        self.launchctl
            .run(arguments)
            .map_err(|error| ServiceError::Other(format!("launchctl could not run: {error}")))
    }

    /// Swift `requireSuccess`.
    pub(crate) fn require_success(
        output: &LaunchctlOutput,
        operation: &str,
    ) -> Result<(), ServiceError> {
        if output.status == 0 {
            return Ok(());
        }
        let detail = String::from_utf8_lossy(&output.stderr).trim().to_owned();
        Err(ServiceError::Launchctl(format!(
            "{operation} exited {}{}",
            output.status,
            if detail.is_empty() {
                String::new()
            } else {
                format!(": {detail}")
            }
        )))
    }

    /// Swift `bootstrap()`: `bootout` can report success before launchd has
    /// unregistered the old service, and an immediate `bootstrap` then exits
    /// with EIO; a persistently disabled service reports the same, so after
    /// three consecutive EIO answers the service is enabled once. Only that
    /// exact status is retried, for a bounded twenty attempts.
    pub(crate) fn bootstrap(&self) -> Result<(), ServiceError> {
        let arguments = launchd::bootstrap_arguments(&self.launch_domain(), &self.paths.plist);
        let (maximum, enable_after) = (20, 3);
        let mut enabled = false;
        for attempt in 1..=maximum {
            let output = self.run_launchctl(&arguments)?;
            if output.status == 0 {
                return Ok(());
            }
            if output.status != EIO || attempt == maximum {
                return Self::require_success(&output, "bootstrap");
            }
            if attempt == enable_after && !enabled {
                let enable =
                    self.run_launchctl(&launchd::enable_arguments(&self.launch_domain()))?;
                Self::require_success(&enable, "enable")?;
                enabled = true;
            }
            std::thread::sleep(self.poll_interval);
        }
        Ok(())
    }

    /// Swift `validatedExecutable`: an absolute path whose resolved form is an
    /// existing, executable, non-directory file.
    pub(crate) fn validated_executable(
        &self,
        candidate: &str,
        name: &str,
    ) -> Result<PathBuf, ServiceError> {
        if !candidate.starts_with('/') {
            return Err(ServiceError::InvalidExecutable(format!(
                "{name} path must be absolute"
            )));
        }
        let canonical = resolved(Path::new(candidate));
        let valid = std::fs::metadata(&canonical).is_ok_and(|metadata| !metadata.is_dir())
            && arkdeck_platform::executable_by_caller(&canonical);
        if !valid {
            return Err(ServiceError::InvalidExecutable(format!(
                "{name} is missing, is not a regular file, or is not executable: {}",
                canonical.display()
            )));
        }
        Ok(canonical)
    }

    /// Swift `transportExecutable(in:)`: the signed sibling facade when the
    /// bundle carries one, else the daemon executable.
    pub(crate) fn transport_executable(&self, bundle: &Path) -> Result<PathBuf, ServiceError> {
        let facade = bundle.join(format!("Contents/MacOS/{FACADE_EXECUTABLE_NAME}"));
        if !facade.exists() {
            return Ok(bundle.join(format!("Contents/MacOS/{DAEMON_EXECUTABLE_NAME}")));
        }
        self.validated_executable(&text(&facade), "control-plane facade")?;
        (self.validate_facade)(&facade).map_err(|_| {
            ServiceError::InvalidExecutable(
                "facade signature is invalid; run runtime service update".into(),
            )
        })?;
        Ok(facade)
    }

    /// Swift `validatedWorkspace`.
    pub(crate) fn validated_workspace(
        &self,
        project: &str,
        sdk: &str,
    ) -> Result<Workspace, ServiceError> {
        let directory = |candidate: &str, name: &str| -> Result<PathBuf, ServiceError> {
            if !candidate.starts_with('/') {
                return Err(ServiceError::Configuration(format!(
                    "{name} path must be absolute"
                )));
            }
            let canonical = resolved(Path::new(candidate));
            if !canonical.is_dir() {
                return Err(ServiceError::Configuration(format!(
                    "{name} directory is absent"
                )));
            }
            Ok(canonical)
        };
        let project = directory(project, "WaterFlow project")?;
        let project_text = text(&project);
        for protected in ["Desktop", "Documents", "Downloads"] {
            let root = text(&self.paths.home.join(protected));
            if project_text == root || project_text.starts_with(&format!("{root}/")) {
                return Err(ServiceError::Configuration(
                    "WaterFlow project cannot be under macOS privacy-managed Desktop, Documents \
                     or Downloads; use an absolute path under ~/Developer or another \
                     LaunchAgent-readable directory"
                        .into(),
                ));
            }
        }
        if project_text.contains(',') || project_text.contains('=') {
            return Err(ServiceError::Configuration(
                "WaterFlow project path cannot contain ',' or '='".into(),
            ));
        }
        if !project.join("build-profile.json5").exists()
            || !project.join("entry/src/main/module.json5").exists()
        {
            return Err(ServiceError::Configuration(
                "WaterFlow project is missing build-profile.json5 or entry/src/main/module.json5"
                    .into(),
            ));
        }
        let sdk = directory(sdk, "DevEco SDK")?;
        if !sdk.join("default/openharmony").is_dir() {
            return Err(ServiceError::Configuration(
                "DevEco SDK does not contain default/openharmony".into(),
            ));
        }
        Ok(Workspace {
            project_root: project_text,
            deveco_sdk_root: text(&sdk),
        })
    }

    /// Swift `validatedArkTraceDescriptor`: one bounded, owner-controlled
    /// descriptor read through a single `openat(O_NOFOLLOW)` walk, with the
    /// closed three-member schema.
    pub(crate) fn validated_descriptor(
        &self,
        candidate: &str,
    ) -> Result<ValidatedDescriptor, ServiceError> {
        use arkdeck_platform::OwnerFileRefusal as Refusal;
        let configuration = |detail: &str| {
            ServiceError::Configuration(format!("ArkTrace distribution descriptor {detail}"))
        };
        if !candidate.starts_with('/') {
            return Err(configuration("path must be absolute"));
        }
        // Swift `physicalAbsolutePath`: `/var`, `/tmp` and `/etc` are named
        // by their physical `/private` spelling.
        let physical = if ["/var", "/tmp", "/etc"]
            .iter()
            .any(|root| candidate == *root || candidate.starts_with(&format!("{root}/")))
        {
            format!("/private{candidate}")
        } else {
            candidate.to_owned()
        };
        let components: Vec<&str> = physical.split('/').filter(|c| !c.is_empty()).collect();
        if components.is_empty() || components.iter().any(|c| *c == "." || *c == "..") {
            return Err(configuration("path is invalid"));
        }
        let bytes = arkdeck_platform::read_owner_controlled_file(
            &components,
            ARKTRACE_DESCRIPTOR_MAXIMUM,
            self.uid,
        )
        .map_err(|refusal| {
            configuration(match refusal {
                Refusal::RootUnavailable => "root is unavailable",
                Refusal::AncestorUnavailable => "has an unavailable or symbolic ancestor",
                Refusal::AncestorNotOwnerControlled => "ancestors must be owner-controlled",
                Refusal::NotPhysicalRegularFile => "must be a physical regular file",
                Refusal::NotBoundedOwnerControlled => "must be bounded and owner-controlled",
                Refusal::IncompleteRead => "could not be read completely",
                Refusal::ChangedWhileRead => "changed while it was read",
                Refusal::IdentityChanged => "identity changed while it was read",
            })
        })?;
        let schema_invalid = || configuration("schema is invalid");
        let document = arkdeck_contract::strict_json(&bytes).map_err(|_| schema_invalid())?;
        let fields = document.as_object().ok_or_else(schema_invalid)?;
        let mut keys: Vec<&str> = fields.keys().map(String::as_str).collect();
        keys.sort_unstable();
        let root = fields["distributionRoot"].as_str().unwrap_or_default();
        let manifest = fields["manifestSHA256"].as_str().unwrap_or_default();
        if keys != ["distributionRoot", "formatVersion", "manifestSHA256"]
            || !fields["distributionRoot"].is_string()
            || !root.starts_with('/')
            || root.len() > 4096
            || fields["formatVersion"].as_i64() != Some(1)
            || manifest.len() != 64
            || !manifest
                .bytes()
                .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
        {
            return Err(schema_invalid());
        }
        Ok(ValidatedDescriptor {
            status: ArkTraceDescriptorStatus {
                descriptor_path: physical,
                descriptor_sha256: arkdeck_contract::sha256_hex(&bytes),
                descriptor_byte_count: bytes.len() as i64,
            },
        })
    }

    /// Swift `configuredArkForgeLane`: the retired three-key names are refused
    /// by name; the one bundle key is measured.
    fn configured_lane(
        environment: &BTreeMap<&str, &str>,
    ) -> Result<Option<ArkForgeLaneStatus>, LaneRefusal> {
        let retired: Vec<String> = RETIRED_ARKFORGE_KEYS
            .iter()
            .filter(|key| environment.contains_key(*key))
            .map(|key| (*key).to_owned())
            .collect();
        if !retired.is_empty() {
            return Err(LaneRefusal::RetiredConfiguration(retired));
        }
        let Some(bundle) = environment.get(ARKFORGE_BUNDLE_KEY) else {
            return Ok(None);
        };
        ArkForgeLaneStatus::measuring(
            bundle,
            environment
                .get(ARKFORGE_CAMPAIGN_KEY)
                .copied()
                .unwrap_or(""),
        )
        .map(Some)
    }

    pub(crate) fn read_bounded(path: &Path) -> io::Result<Vec<u8>> {
        use std::io::Read;
        let mut bytes = Vec::new();
        std::fs::File::open(path)?
            .take(DOCUMENT_MAXIMUM + 1)
            .read_to_end(&mut bytes)?;
        if bytes.len() as u64 > DOCUMENT_MAXIMUM {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "the document exceeds its byte bound",
            ));
        }
        Ok(bytes)
    }

    /// Swift `configuredPaths()`.
    fn configured_paths(&self) -> Result<ConfiguredPaths, ServiceError> {
        let bytes = Self::read_bounded(&self.paths.plist)?;
        let document = arkdeck_platform::read_property_list(&bytes)?;
        let shape = || {
            ServiceError::Configuration(
                "plist must keep the user-session lifecycle, Mach service, log paths, one daemon \
                 argument and an explicit ARKDECK_HDC_PATH"
                    .into(),
            )
        };
        let fields = document.as_dictionary().ok_or_else(shape)?;
        let field = |key: &str| fields.get(key);
        let arguments = field("ProgramArguments")
            .and_then(PropertyListValue::as_strings)
            .ok_or_else(shape)?;
        let environment = field("EnvironmentVariables")
            .and_then(PropertyListValue::as_string_dictionary)
            .ok_or_else(shape)?;
        let (Some(daemon), 1) = (arguments.first(), arguments.len()) else {
            return Err(shape());
        };
        let Some(hdc) = environment.get(HDC_KEY) else {
            return Err(shape());
        };
        let standard_output = text(&self.paths.standard_output);
        let standard_error = text(&self.paths.standard_error);
        if field("Label").and_then(PropertyListValue::as_str) != Some(LABEL)
            || field("RunAtLoad").and_then(PropertyListValue::as_bool) != Some(true)
            || field("KeepAlive").and_then(PropertyListValue::as_bool) != Some(true)
            || field("LimitLoadToSessionType").and_then(PropertyListValue::as_str) != Some("Aqua")
            || field("MachServices")
                .and_then(PropertyListValue::as_bool_dictionary)
                .and_then(|services| services.get(LABEL).copied())
                != Some(true)
            || field("StandardOutPath").and_then(PropertyListValue::as_str)
                != Some(standard_output.as_str())
            || field("StandardErrorPath").and_then(PropertyListValue::as_str)
                != Some(standard_error.as_str())
        {
            return Err(shape());
        }
        let installed_daemon = text(&self.paths.installed_daemon);
        if *daemon != installed_daemon {
            let paired = sha256_file(&self.paths.installed_daemon)?;
            if environment.get(SWIFT_SHA256_KEY).copied() != Some(paired.as_str()) {
                return Err(ServiceError::Configuration(
                    "paired Swift daemon identity drifted; run runtime service update".into(),
                ));
            }
        }
        let analyzer = environment.get(ANALYZER_KEY).copied();
        let inspector = environment.get(WORKSPACE_INSPECTOR_KEY).copied();
        // The analyzer and inspector are host facts about this installation,
        // pinned exactly whenever present, and no longer imply a workspace.
        if analyzer.is_some_and(|analyzer| analyzer != installed_daemon) {
            return Err(ServiceError::Configuration(
                "the analyzer path must be this installation's own daemon".into(),
            ));
        }
        if inspector.is_some_and(|inspector| inspector != WORKSPACE_INSPECTOR) {
            return Err(ServiceError::Configuration(
                "the workspace inspector must be the registered host tool".into(),
            ));
        }
        let project_entry = environment.get(WORKSPACE_PROJECTS_KEY).copied();
        let active_project = environment.get(WORKSPACE_ACTIVE_PROJECT_KEY).copied();
        let sdk = environment.get(DEVECO_SDK_KEY).copied();
        let workspace = if project_entry.is_none() && active_project.is_none() && sdk.is_none() {
            None
        } else {
            let prefix = format!("{WATERFLOW_PROJECT_REF}=");
            let project = project_entry
                .and_then(|entry| entry.strip_prefix(prefix.as_str()))
                .filter(|project| !project.is_empty());
            match (project, active_project, sdk) {
                (Some(project), Some(WATERFLOW_PROJECT_REF), Some(sdk))
                    if analyzer == Some(installed_daemon.as_str())
                        && inspector == Some(WORKSPACE_INSPECTOR) =>
                {
                    Some(self.validated_workspace(project, sdk)?)
                }
                _ => {
                    return Err(ServiceError::Configuration(
                        "workspace environment must be the closed demo-app ProjectProfile \
                         configuration"
                            .into(),
                    ));
                }
            }
        };
        let descriptor = environment
            .get(ARKTRACE_DESCRIPTOR_KEY)
            .map(|path| self.validated_descriptor(path))
            .transpose()?;
        Ok(ConfiguredPaths {
            daemon: (*daemon).to_owned(),
            hdc: (*hdc).to_owned(),
            workspace,
            descriptor,
            lane: Self::configured_lane(&environment),
        })
    }

    /// Swift `arkTraceDescriptorForPreservingUpdate()`: the descriptor an
    /// `update` keeps when `--arktrace-descriptor` is not restated, only while
    /// the live plist and descriptor bytes still match the receipt. An
    /// uninstalled service has no plist to read, which fails as in Swift.
    pub(crate) fn ark_trace_descriptor_for_preserving_update(
        &self,
    ) -> Result<Option<String>, ServiceError> {
        let configuration = self.configured_paths()?;
        let receipt =
            InstallReceipt::decode(&Self::read_bounded(&self.paths.receipt)?).map_err(|error| {
                ServiceError::Other(format!("the install receipt is unreadable: {error}"))
            })?;
        let live = configuration
            .descriptor
            .as_ref()
            .map(|descriptor| descriptor.status.clone());
        if receipt.ark_trace_descriptor != live {
            return Err(ServiceError::Configuration(
                "ArkTrace distribution descriptor drifted since installation; pass \
                 --arktrace-descriptor explicitly to select reviewed bytes"
                    .into(),
            ));
        }
        Ok(live.map(|status| status.descriptor_path))
    }

    /// Swift `arkForgeLaneForPreservingUpdate()`: the lane read back from the
    /// live plist, none when there is no readable plist or environment.
    pub(crate) fn ark_forge_lane_for_preserving_update(
        &self,
    ) -> Result<Option<ArkForgeLaneStatus>, LaneRefusal> {
        let Ok(bytes) = Self::read_bounded(&self.paths.plist) else {
            return Ok(None);
        };
        let Ok(document) = arkdeck_platform::read_property_list(&bytes) else {
            return Ok(None);
        };
        let Some(environment) = document
            .as_dictionary()
            .and_then(|fields| fields.get("EnvironmentVariables"))
            .and_then(PropertyListValue::as_string_dictionary)
        else {
            return Ok(None);
        };
        Self::configured_lane(&environment)
    }

    /// Swift `LaunchAgentService.status()`.
    pub fn status(&self) -> Result<LaunchAgentStatus, ServiceError> {
        let installed = self.paths.plist.exists();
        let mut status = LaunchAgentStatus {
            installed,
            launch_domain: self.launch_domain(),
            plist_path: text(&self.paths.plist),
            socket_path: text(&self.paths.socket),
            standard_output_path: text(&self.paths.standard_output),
            standard_error_path: text(&self.paths.standard_error),
            ..LaunchAgentStatus::default()
        };
        let mut diagnostics = Vec::new();
        if installed {
            match self.configured_paths() {
                Err(error) => diagnostics.push(format!("configuration is invalid: {error}")),
                Ok(configuration) => {
                    status.daemon_path = Some(configuration.daemon.clone());
                    status.hdc_path = Some(configuration.hdc.clone());
                    status.workspace_project_path = configuration
                        .workspace
                        .as_ref()
                        .map(|workspace| workspace.project_root.clone());
                    status.deveco_sdk_path = configuration
                        .workspace
                        .as_ref()
                        .map(|workspace| workspace.deveco_sdk_root.clone());
                    status.ark_trace_descriptor = configuration
                        .descriptor
                        .as_ref()
                        .map(|descriptor| descriptor.status.clone());
                    match &configuration.lane {
                        Ok(lane) => status.ark_forge_lane = lane.clone(),
                        Err(refusal) => diagnostics.push(refusal.to_string()),
                    }
                    match (self.validate_daemon_bundle)(&self.paths.installed_daemon_bundle) {
                        Ok(bundle) if bundle != self.paths.installed_daemon_bundle => diagnostics
                            .push("installed daemon helper bundle path is not canonical".into()),
                        Ok(_) => {}
                        Err(error) => diagnostics.push(format!(
                            "installed daemon helper bundle is invalid: {error}"
                        )),
                    }
                    match self.transport_executable(&self.paths.installed_daemon_bundle) {
                        // Swift throws out of the configuration block here, so
                        // the executable checks below it are not reached.
                        Err(error) => {
                            diagnostics.push(format!("configuration is invalid: {error}"));
                        }
                        Ok(transport) => {
                            if configuration.daemon != text(&transport) {
                                diagnostics.push(
                                    "ProgramArguments does not name the ArkDeck-managed daemon \
                                     path"
                                        .into(),
                                );
                            }
                            match self
                                .validated_executable(
                                    &configuration.daemon,
                                    "configured arkdeck-agentd",
                                )
                                .and_then(|daemon| {
                                    if text(&daemon) != configuration.daemon {
                                        diagnostics
                                            .push("configured daemon path is not canonical".into());
                                    }
                                    Ok(sha256_file(&daemon)?)
                                }) {
                                Ok(digest) => status.daemon_sha256 = Some(digest),
                                Err(error) => diagnostics
                                    .push(format!("configured arkdeck-agentd is invalid: {error}")),
                            }
                            match self
                                .validated_executable(&configuration.hdc, "configured HDC")
                                .and_then(|hdc| {
                                    if text(&hdc) != configuration.hdc {
                                        diagnostics
                                            .push("configured HDC path is not canonical".into());
                                    }
                                    Ok(sha256_file(&hdc)?)
                                }) {
                                Ok(digest) => status.hdc_sha256 = Some(digest),
                                Err(error) => {
                                    diagnostics.push(format!("configured HDC is invalid: {error}"))
                                }
                            }
                        }
                    }
                }
            }
            match Self::read_bounded(&self.paths.receipt)
                .map_err(|error| error.to_string())
                .and_then(|bytes| InstallReceipt::decode(&bytes))
                .and_then(|receipt| {
                    if receipt.schema_version == RECEIPT_SCHEMA {
                        Ok(receipt)
                    } else {
                        Err(ServiceError::Configuration(
                            "unsupported install receipt schema".into(),
                        )
                        .to_string())
                    }
                }) {
                Err(error) => diagnostics.push(format!(
                    "install receipt is unavailable or invalid: {error}"
                )),
                Ok(receipt) => {
                    if Some(&receipt.daemon_path) != status.daemon_path.as_ref()
                        || Some(&receipt.daemon_sha256) != status.daemon_sha256.as_ref()
                    {
                        diagnostics
                            .push("arkdeck-agentd identity drifted since installation".into());
                    }
                    if Some(&receipt.hdc_path) != status.hdc_path.as_ref()
                        || Some(&receipt.hdc_sha256) != status.hdc_sha256.as_ref()
                    {
                        diagnostics.push("HDC identity drifted since installation".into());
                    }
                    if receipt.workspace_project_path != status.workspace_project_path
                        || receipt.deveco_sdk_path != status.deveco_sdk_path
                    {
                        diagnostics
                            .push("workspace configuration drifted since installation".into());
                    }
                    if receipt.ark_trace_descriptor != status.ark_trace_descriptor {
                        diagnostics.push(
                            "ArkTrace distribution descriptor drifted since installation".into(),
                        );
                    }
                    if receipt.ark_forge_lane != status.ark_forge_lane {
                        diagnostics
                            .push("ArkForge release bundle drifted since installation".into());
                    }
                }
            }
        } else {
            diagnostics.push("LaunchAgent is not installed".into());
        }
        status.loaded = installed && self.is_loaded()?;
        if installed && !status.loaded {
            diagnostics.push(format!(
                "LaunchAgent is not loaded in {}",
                status.launch_domain
            ));
        }
        status.socket_present = self.paths.socket.exists();
        if installed && status.loaded && !status.socket_present {
            diagnostics.push(
                "daemon socket is absent; service may still be starting; re-run status, then \
                 inspect the LaunchAgent error log"
                    .into(),
            );
        }
        status.ready =
            installed && status.loaded && status.socket_present && diagnostics.is_empty();
        status.diagnostics = diagnostics;
        Ok(status)
    }

    /// Swift `daemonInstance()`: a stale document is possible after a crash,
    /// so it is trusted only beside a successful health answer.
    pub fn daemon_instance(&self) -> Result<DaemonInstance, ServiceError> {
        let unavailable = |detail: String| {
            ServiceError::Configuration(format!(
                "daemon instance document is unavailable or invalid: {detail}"
            ))
        };
        let bytes = Self::read_bounded(&self.paths.state_directory.join("instance.json"))
            .map_err(|error| unavailable(error.to_string()))?;
        let value: Value =
            serde_json::from_slice(&bytes).map_err(|error| unavailable(error.to_string()))?;
        let member = |key: &str| value.get(key).and_then(Value::as_str).map(str::to_owned);
        let (Some(pid), Some(socket_path), Some(protocol_version), Some(started_at_utc)) = (
            value
                .get("pid")
                .and_then(Value::as_i64)
                .and_then(|pid| i32::try_from(pid).ok()),
            member("socketPath"),
            member("protocolVersion"),
            member("startedAtUTC"),
        ) else {
            return Err(unavailable(
                "a member is missing or has the wrong type".into(),
            ));
        };
        if pid <= 0
            || socket_path != text(&self.paths.socket)
            || protocol_version.is_empty()
            || started_at_utc.is_empty()
        {
            return Err(ServiceError::Configuration(
                "daemon instance document does not match the managed LaunchAgent".into(),
            ));
        }
        Ok(DaemonInstance {
            pid,
            socket_path,
            protocol_version,
            started_at_utc,
        })
    }

    /// Swift `LaunchAgentService.restart()`: restarts the ready, identity-
    /// checked service without changing any installed byte or Runtime state.
    pub fn restart_service(&self) -> Result<Value, ServiceError> {
        let before = self.status()?;
        let (true, Some(daemon_path), Some(daemon_sha256), Some(hdc_sha256)) = (
            before.ready,
            before.daemon_path.clone(),
            before.daemon_sha256.clone(),
            before.hdc_sha256.clone(),
        ) else {
            return Err(ServiceError::Configuration(format!(
                "restart requires a ready, identity-checked LaunchAgent: {}",
                before.diagnostics.join("; ")
            )));
        };
        let bootout = self.run_launchctl(&launchd::bootout_arguments(&self.launch_domain()))?;
        Self::require_success(&bootout, "bootout")?;
        self.bootstrap()?;
        Ok(json!({
            "schemaVersion": RESTART_SCHEMA,
            "restartedAtUTC": (self.now_utc)(),
            "launchDomain": self.launch_domain(),
            "plistPath": text(&self.paths.plist),
            "daemonPath": daemon_path,
            "daemonSHA256": daemon_sha256,
            "hdcSHA256": hdc_sha256,
            "preservedStateDirectory": text(&self.paths.state_directory),
            "preservedLogDirectory": text(&self.paths.log_directory),
        }))
    }

    // MARK: Runtime reads

    fn endpoint(&self, socket: &str) -> (LocalEndpoint, ServerIdentity) {
        (
            LocalEndpoint::new(socket),
            ServerIdentity::new(&self.paths.installed_daemon),
        )
    }

    /// One request over its own connection, as Swift's `AgentClient` makes
    /// every request (with its own contract preflight).
    pub(crate) fn request(
        &self,
        socket: &str,
        id: &str,
        method: &str,
        params: Option<Map<String, Value>>,
    ) -> Result<Value, ClientError> {
        let (endpoint, identity) = self.endpoint(socket);
        let mut client = Client::connect(&endpoint, &identity, self.connection_timeout)?;
        if method == "health" {
            client.health(id)
        } else {
            client.request(id, method, params)
        }
    }
}

fn client_failure(error: &ClientError) -> PlainFailure {
    PlainFailure::new(1, error.to_string())
}

/// Swift `agentdHealthCatalogDigest`.
fn health_catalog_digest(health: &Value) -> Result<String, PlainFailure> {
    let digest = health["catalogDigest"].as_str().unwrap_or_default();
    if health["status"] != "ok"
        || digest.len() != 64
        || !digest
            .bytes()
            .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
    {
        return Err(PlainFailure::new(
            69,
            "daemon health lacks a valid lowercase catalog digest",
        ));
    }
    Ok(digest.to_owned())
}

/// Swift `agentdRestartJobPreflight`: every current Job of one complete
/// `job.list` snapshot, classified by the shared preflight table's restart
/// rule.
fn restart_job_preflight(
    host: &ServiceHost,
    socket: &str,
    id: &str,
) -> Result<arkdeck_contract::RestartPreflight, PlainFailure> {
    let incomplete = || {
        PlainFailure::new(
            69,
            "daemon did not return its complete current Job snapshot",
        )
    };
    let mut cursor: Option<String> = None;
    let mut snapshot: Option<Value> = None;
    let mut seen = std::collections::BTreeSet::new();
    let mut current = Vec::new();
    loop {
        let mut params = Map::from_iter([
            ("pageSize".to_owned(), json!(1000)),
            ("order".to_owned(), json!("createdAtDescJobIdAsc")),
            ("includeTimeline".to_owned(), json!(false)),
            ("includeCurrent".to_owned(), json!(true)),
        ]);
        if let Some(cursor) = &cursor {
            params.insert("cursor".into(), json!(cursor));
        }
        let page = host
            .request(socket, id, "job.list", Some(params))
            .map_err(|error| client_failure(&error))?;
        let (Some(rows), Some(more)) = (page["items"].as_array(), page["hasMore"].as_bool()) else {
            return Err(incomplete());
        };
        if page["schemaVersion"] != "arkdeck.cli.page/1"
            || rows.len() > 1000
            || snapshot
                .as_ref()
                .is_some_and(|revision| *revision != page["snapshotRevision"])
        {
            return Err(incomplete());
        }
        snapshot = Some(page["snapshotRevision"].clone());
        for row in rows {
            let Some(is_current) = row.get("current").and_then(Value::as_bool) else {
                return Err(PlainFailure::new(
                    69,
                    "daemon returned an incomplete Job summary",
                ));
            };
            if is_current {
                current.push(row.clone());
            }
        }
        if more {
            let next = page["nextCursor"].as_str().map(str::to_owned);
            match next {
                Some(next) if !rows.is_empty() && seen.insert(next.clone()) => cursor = Some(next),
                _ => return Err(PlainFailure::new(69, "daemon repeated a Job snapshot page")),
            }
        } else {
            if !page["nextCursor"].is_null() {
                return Err(PlainFailure::new(
                    69,
                    "daemon returned an invalid final Job page",
                ));
            }
            break;
        }
    }
    arkdeck_contract::classify_restart(&current)
        .map_err(|_| PlainFailure::new(69, "daemon returned a malformed current Runtime Job"))
}

/// Swift `waitForRestart`: polls until the service is ready again with a new
/// daemon process speaking the same catalog.
fn wait_for_restart(
    host: &ServiceHost,
    id: &str,
    previous_pid: i32,
    expected_digest: &str,
    maximum_wait_seconds: u64,
) -> Result<(LaunchAgentStatus, DaemonInstance, Value, String), PlainFailure> {
    let deadline = Instant::now() + Duration::from_secs(maximum_wait_seconds);
    loop {
        let attempt =
            (|| -> Result<Option<(LaunchAgentStatus, DaemonInstance, Value, String)>, String> {
                let status = host.status().map_err(|error| error.to_string())?;
                if !status.ready {
                    return Err(status.diagnostics.join("; "));
                }
                let instance = host.daemon_instance().map_err(|error| error.to_string())?;
                if instance.pid == previous_pid {
                    return Err("daemon instance PID has not changed".into());
                }
                let health = host
                    .request(&status.socket_path, id, "health", None)
                    .map_err(|error| error.to_string())?;
                let digest = health_catalog_digest(&health).map_err(|failure| failure.message)?;
                if digest != expected_digest {
                    return Ok(None);
                }
                Ok(Some((status, instance, health, digest)))
            })();
        let detail = match attempt {
            Ok(Some(ready)) => return Ok(ready),
            Ok(None) => {
                return Err(PlainFailure::new(
                    69,
                    "daemon catalog changed across a configuration-preserving restart",
                ));
            }
            Err(detail) => detail,
        };
        if Instant::now() >= deadline {
            return Err(PlainFailure::new(
                69,
                format!(
                    "replacement daemon did not become ready within {maximum_wait_seconds}s: \
                     {detail}"
                ),
            ));
        }
        std::thread::sleep(host.poll_interval);
    }
}

// MARK: - Leaves

/// `runtime service status`: the LaunchAgent and, when its socket exists, the
/// daemon's own `health` answer.
pub fn status_leaf(host: &ServiceHost, id: &str) -> ServiceAnswer {
    let status = match host.status() {
        Ok(status) => status,
        Err(error) => return ServiceAnswer::fail(error.into()),
    };
    let health = if status.socket_present {
        host.request(&status.socket_path, id, "health", None)
            .unwrap_or_else(|error| json!({"status": "unreachable", "detail": error.to_string()}))
    } else {
        json!({"status": "socket_absent"})
    };
    ServiceAnswer::emit(json!({"launchAgent": status.json(), "daemonHealth": health}))
}

/// `runtime service restart`: maintenance, never a way to interrupt a Job. A
/// current Job blocks it unless it is a closed unknown-outcome recovery lane,
/// which a restart cannot make known and never redispatches.
pub fn restart_leaf(
    host: &ServiceHost,
    id: &str,
    maximum_wait_seconds: Option<u64>,
) -> ServiceAnswer {
    let maximum_wait_seconds = maximum_wait_seconds.unwrap_or(30);
    if !(1..=300).contains(&maximum_wait_seconds) {
        return ServiceAnswer::fail(PlainFailure::new(
            64,
            format!(
                "{} restart --maximum-wait-seconds must be between 1 and 300",
                host.spelling
            ),
        ));
    }
    let run = || -> Result<Value, PlainFailure> {
        let before = host.status().map_err(PlainFailure::from)?;
        if !before.ready {
            return Err(PlainFailure::new(
                69,
                format!(
                    "LaunchAgent is not ready: {}",
                    before.diagnostics.join("; ")
                ),
            ));
        }
        let health = host
            .request(&before.socket_path, id, "health", None)
            .map_err(|error| client_failure(&error))?;
        let digest_before = health_catalog_digest(&health)?;
        let instance_before = host.daemon_instance().map_err(PlainFailure::from)?;
        let jobs_before = restart_job_preflight(host, &before.socket_path, id)?;
        if !jobs_before.blocking_job_ids.is_empty() {
            return Err(PlainFailure::new(
                75,
                format!(
                    "{} restart refused while Runtime Jobs are active or unclosed: {}",
                    host.spelling,
                    jobs_before.blocking_job_ids.join(", ")
                ),
            ));
        }
        let receipt = host.restart_service().map_err(PlainFailure::from)?;
        let (status, instance_after, health_after, digest_after) = wait_for_restart(
            host,
            id,
            instance_before.pid,
            &digest_before,
            maximum_wait_seconds,
        )?;
        let jobs_after = restart_job_preflight(host, &status.socket_path, id)?;
        if !jobs_after.blocking_job_ids.is_empty()
            || jobs_after.preserved_unknown_job_ids != jobs_before.preserved_unknown_job_ids
        {
            return Err(PlainFailure::new(
                69,
                "Runtime current Job closure changed across daemon restart",
            ));
        }
        Ok(json!({
            "restart": receipt,
            "restartProof": {
                "schemaVersion": RESTART_PROOF_SCHEMA,
                "beforeInstance": instance_before.json(),
                "afterInstance": instance_after.json(),
                "catalogDigestBefore": digest_before,
                "catalogDigestAfter": digest_after,
                "blockingJobCountBefore": 0,
                "preservedUnknownJobIds": jobs_before.preserved_unknown_job_ids,
            },
            "launchAgent": status.json(),
            "daemonHealth": health_after,
        }))
    };
    match run() {
        Ok(document) => ServiceAnswer::emit(document),
        Err(failure) => ServiceAnswer::fail(failure),
    }
}

/// `runtime service verify`: anchored to the installed, loaded and identity-
/// checked LaunchAgent, then only the socket that service owns is opened.
pub fn verify_leaf(host: &ServiceHost, id: &str, options: &Map<String, Value>) -> ServiceAnswer {
    let job = options.get("jobId").and_then(Value::as_str);
    if job.is_some()
        && ["targetId", "maximumWaitSeconds", "executionId"]
            .iter()
            .any(|key| options.contains_key(*key))
    {
        return ServiceAnswer::fail(PlainFailure::new(
            64,
            format!(
                "{} verify --job cannot be combined with execution options",
                host.spelling
            ),
        ));
    }
    if let Some(raw) = options.get("maximumWaitSeconds") {
        let within = raw
            .as_str()
            .and_then(|raw| raw.parse::<u64>().ok())
            .is_some_and(|seconds| (1..=300).contains(&seconds));
        if !within {
            return ServiceAnswer::fail(PlainFailure::new(
                64,
                format!(
                    "{} verify --maximum-wait-seconds must be between 1 and 300",
                    host.spelling
                ),
            ));
        }
    }
    let status = match host.status() {
        Ok(status) => status,
        Err(error) => return ServiceAnswer::fail(error.into()),
    };
    if !status.ready {
        return ServiceAnswer::emit_then_fail(
            json!({"launchAgent": status.json(), "runtime": null, "runtimeVerified": false}),
            PlainFailure::new(
                69,
                format!(
                    "LaunchAgent is not ready: {}",
                    status.diagnostics.join("; ")
                ),
            ),
        );
    }
    let request = |method: &str, params: Option<Map<String, Value>>| {
        host.request(&status.socket_path, id, method, params)
            .map_err(|error| error.to_string())
    };
    let Some(job) = job else {
        return verify_fresh(host, &status, options, &request);
    };
    match runtime_service_verify::verify_persisted_job(job, &request) {
        Err(message) => ServiceAnswer::fail(PlainFailure::new(1, message)),
        Ok(ReopenOutcome::Verified(report)) => ServiceAnswer::emit(json!({
            "launchAgent": status.json(), "runtime": report, "runtimeVerified": true,
        })),
        Ok(ReopenOutcome::Failed { reason, report }) => ServiceAnswer::emit_then_fail(
            json!({"launchAgent": status.json(), "runtime": report, "runtimeVerified": false}),
            PlainFailure::new(1, reason),
        ),
    }
}

/// `runtime service verify` without `--job`: a fresh `observe.device@1` run
/// by the daemon as an agent execution, then the reopen of its Job. The
/// document keeps Swift's members (`launchAgent`, `runtime`,
/// `runtimeVerified`; `humanAction` and `runtimeReceipt` while a person is
/// needed) and adds the settled `agentExecution`.
fn verify_fresh<F>(
    host: &ServiceHost,
    status: &LaunchAgentStatus,
    options: &Map<String, Value>,
    request: &F,
) -> ServiceAnswer
where
    F: Fn(&str, Option<Map<String, Value>>) -> Result<Value, String>,
{
    let text = |key: &str| options.get(key).and_then(Value::as_str);
    let seconds = text("maximumWaitSeconds")
        .and_then(|raw| raw.parse().ok())
        .unwrap_or(90);
    let execution = match text("executionId") {
        Some(id) => id.to_owned(),
        None => match crate::job_plan::uuid() {
            Ok(id) => id,
            Err(error) => return ServiceAnswer::fail(PlainFailure::new(1, error.message)),
        },
    };
    let outcome = runtime_service_verify::verify_observe_device(
        text("targetId"),
        seconds,
        &execution,
        host.poll_interval,
        request,
    );
    match outcome {
        Err(message) => ServiceAnswer::fail(PlainFailure::new(1, message)),
        Ok(FreshOutcome::Reopened {
            execution,
            outcome: ReopenOutcome::Verified(report),
        }) => ServiceAnswer::emit(json!({
            "launchAgent": status.json(), "agentExecution": execution,
            "runtime": report, "runtimeVerified": true,
        })),
        Ok(FreshOutcome::Reopened {
            execution,
            outcome: ReopenOutcome::Failed { reason, report },
        }) => ServiceAnswer::emit_then_fail(
            json!({"launchAgent": status.json(), "agentExecution": execution,
                "runtime": report, "runtimeVerified": false}),
            PlainFailure::new(1, reason),
        ),
        Ok(FreshOutcome::AwaitingHuman { execution }) => {
            let reference = execution["humanAction"]["resumeReference"]
                .as_str()
                .unwrap_or_default()
                .to_owned();
            ServiceAnswer::emit_then_fail(
                json!({"humanAction": execution["humanAction"], "launchAgent": status.json(),
                    "runtimeReceipt": execution, "runtimeVerified": false}),
                PlainFailure::new(
                    75,
                    format!(
                        "paused for physical assistance; resume with: arkdeck agent resume \
                         --resume-reference {reference}"
                    ),
                ),
            )
        }
        Ok(FreshOutcome::Failed { reason, execution }) => ServiceAnswer::emit_then_fail(
            json!({"launchAgent": status.json(), "agentExecution": execution,
                "runtime": null, "runtimeVerified": false}),
            PlainFailure::new(1, reason),
        ),
    }
}

/// Swift `defaultAgentDaemonBundlePath()`: the helper inside the app that
/// holds this executable, else the one beside it.
fn default_daemon_bundle() -> Option<PathBuf> {
    let executable = std::env::current_exe().ok()?;
    let directory = executable.parent()?;
    let contents = directory.parent().filter(|_| directory.ends_with("MacOS"));
    if let Some(contents) = contents.filter(|contents| contents.ends_with("Contents"))
        && contents
            .parent()
            .is_some_and(|app| app.extension().is_some_and(|extension| extension == "app"))
    {
        return Some(contents.join("Helpers").join(DAEMON_BUNDLE_NAME));
    }
    Some(directory.join(DAEMON_BUNDLE_NAME))
}

/// The account's own service manager: its home, its user, `/bin/launchctl`
/// (or, for a relocated home, only the executable named for it) and the
/// production signature checks.
pub fn run(invocation: &Invocation, id: &str) -> ServiceAnswer {
    let Some(home) = arkdeck_platform::runtime_home() else {
        return ServiceAnswer::fail(PlainFailure::new(1, "the account home is unavailable"));
    };
    let launchctl = launchd::account_launchctl_from_environment();
    let validate_daemon_bundle = |bundle: &Path| {
        arkdeck_platform::validate_production_daemon_bundle(bundle)
            .map_err(|error| error.to_string())
    };
    let validate_facade = |facade: &Path| {
        arkdeck_platform::validate_facade_signature(facade).map_err(|error| error.to_string())
    };
    let host = ServiceHost {
        paths: LaunchAgentPaths::for_home(Path::new(&home)),
        uid: arkdeck_platform::effective_user_id(),
        launchctl: &launchctl,
        validate_daemon_bundle: &validate_daemon_bundle,
        validate_facade: &validate_facade,
        bundle_trust: std::sync::Arc::new(arkdeck_platform::validate_production_daemon_bundle),
        hdc_identities: None,
        now_utc: &utc_now,
        connection_timeout: Duration::from_secs(20),
        poll_interval: Duration::from_millis(100),
        default_daemon_bundle: default_daemon_bundle(),
        relocated_home: std::env::var_os("CFFIXED_USER_HOME").is_some_and(|home| !home.is_empty()),
        preflight_timeout: Duration::from_secs(600),
        spelling: if invocation.command.starts_with("agentd.") {
            "agentd"
        } else {
            "runtime service"
        },
    };
    let empty = Map::new();
    let options = invocation.params.as_ref().unwrap_or(&empty);
    match invocation.command {
        "runtime.service.update" | "agentd.update" => {
            runtime_service_install::update_leaf(&host, options)
        }
        "runtime.service.install" => runtime_service_install::install_leaf(&host, options),
        // Swift's compatibility install from path inputs, never the typed
        // bootstrap: `update`'s path without what an update carries over.
        "agentd.install" => runtime_service_install::path_install_leaf(&host, options),
        "runtime.service.uninstall" | "agentd.uninstall" => {
            runtime_service_install::uninstall_leaf(&host)
        }
        "runtime.service.status" | "agentd.status" => status_leaf(&host, id),
        "runtime.service.verify" | "agentd.verify" => verify_leaf(&host, id, options),
        "runtime.service.restart" | "agentd.restart" => restart_leaf(
            &host,
            id,
            options
                .get("maximumWaitSeconds")
                .and_then(Value::as_str)
                .and_then(|raw| raw.parse().ok()),
        ),
        _ => ServiceAnswer::fail(PlainFailure::new(
            64,
            format!("unsupported {} subcommand", host.spelling),
        )),
    }
}
