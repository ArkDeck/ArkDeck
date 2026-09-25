//! `runtime service update|install|uninstall`: Swift's
//! `LaunchAgentService.install`/`uninstall` and `RuntimeCLI.runAgentDaemon`'s
//! `update`, `install` and `uninstall` (the `runtime.service` spelling), with
//! the coordinator's rulings for the M5 cutover (协调会话受托裁定
//! 2026-09-24).
//!
//! `update` checks its options as Swift does, validates the helper bundle,
//! HDC, workspace pair, ArkTrace descriptor and ArkForge lane, boots the
//! service out, replaces the helper through a staged copy, renders the plist
//! from Swift's template with CoreFoundation's writer, writes the receipt as
//! Swift's `JSONEncoder` writes it, and bootstraps the service. In addition:
//!
//! - The helper it replaces is kept one generation in
//!   `Helpers/.rollback/ArkDeckAgent.app` (ruling 4); the exchange is one
//!   `renamex_np(RENAME_SWAP)`, so the installed path always holds a bundle.
//! - While an OpenHarmony signing preset is installed it is refused before
//!   anything changes: Swift re-records the replacement daemon's identity in
//!   that receipt before launchd starts it, and this CLI has no signing owner
//!   yet (ruling 3, Q8).
//! - The new helper's daemon is asked for the cutover preflight
//!   (`arkdeck-agentd --cutover-preflight`, read-only): Swift's daemon refuses
//!   the argument as unknown, the Rust daemon answers. An update to the Rust
//!   daemon is the M5 cutover. Its plist's `ARKDECK_ANALYZER_PATH` names that
//!   daemon, so it must answer `--analyze-crash-ledger` as the Runtime runs it
//!   (ruling 2): it is asked to analyze a probe listing as the Runtime's
//!   analyzer child — through the Runtime's own runner, no environment, the
//!   listing's `/.vol` alias — and must print Swift's recorded answer
//!   byte for byte, else the update is refused by name before anything
//!   changes. Past that gate the first preflight pass must be clear, the
//!   service is booted out, a second pass holding the Runtime's instance lock
//!   must be clear too — else the old plist is bootstrapped back unchanged —
//!   its snapshot summary of the old state directory is written to
//!   `LaunchAgent/cutover-snapshots/`, and the plist asks for the production
//!   composition (ruling 1).
//!
//! `install` is Swift's zero-Runtime bootstrap path over the Bootstrap
//! registry (`arkdeck-bootstrap`, the owner the Runtime writes it through
//! too): it pins the exact bundle generation for `installation/
//! runtime-service-installation` and publishes the first HDC selection from
//! the exact tool generation, installs the retained bundle with the selected
//! tool as `update` installs — the signing and analyzer refusals included —
//! and then keeps only that bundle pinned. A failure after the pin leaves it
//! (and the selection) for a retry, never dangling. `uninstall` removes the
//! service as Swift does and then releases the installation's pins; a release
//! that fails is reported after the removal, which is not undone.
use crate::runtime_service::{
    ANALYZER_KEY, ARKFORGE_BUNDLE_KEY, ARKFORGE_CAMPAIGN_KEY, ARKTRACE_DESCRIPTOR_KEY,
    ArkForgeLaneStatus, CodedFailure, DAEMON_EXECUTABLE_NAME, DEVECO_SDK_KEY, HDC_KEY, LABEL,
    PlainFailure, RECEIPT_SCHEMA, SWIFT_SHA256_KEY, ServiceAnswer, ServiceError, ServiceHost,
    ValidatedDescriptor, WATERFLOW_PROJECT_REF, WORKSPACE_ACTIVE_PROJECT_KEY, WORKSPACE_INSPECTOR,
    WORKSPACE_INSPECTOR_KEY, WORKSPACE_PROJECTS_KEY, Workspace, sha256_file, text,
};
use arkdeck_bootstrap::{BundleRegistryReadStore, ReferenceOwner, ToolRegistryStore};
use arkdeck_contract::WireError;
use arkdeck_platform::PropertyListValue;
use arkdeck_platform::launchd;
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::ffi::OsString;
use std::fs;
use std::io::{self, Read, Write};
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

const PREFLIGHT_FLAG: &str = "--cutover-preflight";
const HOLD_FLAG: &str = "--hold-instance-lock";
const PREFLIGHT_SCHEMA: &str = "arkdeck.cutover-preflight/1";
const SNAPSHOT_SCHEMA: &str = "arkdeck.cutover-snapshot/1";
/// What Swift's daemon prints before it exits 64 for an argument it does not
/// take (`ArkDeckAgentDaemonMain`).
const SWIFT_UNKNOWN_ARGUMENT: &str = "unknown argument --cutover-preflight";
const COMPOSITION: &str = "ARKDECK_RUNTIME_COMPOSITION";
/// A preflight answer larger than this is not read: a snapshot lists every
/// file of the state directory.
const PREFLIGHT_OUTPUT_MAXIMUM: u64 = 256 * 1024 * 1024;
const PREFLIGHT_ERROR_MAXIMUM: u64 = 64 * 1024;
const INSTALLATION_SCHEMA: &str = "arkdeck.runtime-service-installation/1";
/// What a refusal before any service change says changed: nothing, for the
/// path installs; the pins and selection kept for a retry, for the typed one.
const NOTHING_CHANGED: &str = "nothing was changed";
const PINS_KEPT: &str =
    "the service was not changed, and the bundle and HDC selection stay pinned for a retry";
/// How many times the held pass is asked while another Runtime still holds
/// the instance lock, one poll interval apart.
const HELD_PASS_ATTEMPTS: u32 = 50;
const ANALYZER_FLAG: &str = "--analyze-crash-ledger";
/// The listing a Rust daemon is asked to analyze before a plist names it as
/// `ARKDECK_ANALYZER_PATH`, and Swift's answer to it: the
/// `runtime-service-probe` case of the recorded Swift oracle
/// (`rust/tests/fixtures/crash-ledger-analyzer/oracle.json`).
pub const ANALYZER_PROBE_LISTING: &[u8] =
    b"Fault log list:\r\n******\r\njscrash-com.example.my-app-20010039-20260924000000\r\n******\r\n";
pub const ANALYZER_PROBE_ANSWER: &[u8] = br#"{"analyzerRef":"crash-signature@1","analyzerVersion":"arkdeck-fault-log-ledger@1","entries":[{"bundle":"com.example.my-app","kind":"jscrash","name":"jscrash-com.example.my-app-20010039-20260924000000","timestamp":"20260924000000","uid":"20010039"}],"schemaVersion":"1.0.0","status":"answered"}"#;
/// The Runtime's own budget for the analyzer (`AnalyzerProfile::crash_signature`).
const ANALYZER_PROBE_TIMEOUT: Duration = Duration::from_secs(30);

fn usage(message: impl Into<String>) -> PlainFailure {
    PlainFailure::new(64, message)
}

fn failed(error: impl Into<ServiceError>) -> PlainFailure {
    PlainFailure::from(error.into())
}

/// Either failure a leaf answers: Swift's plain `CLIError` or its session's
/// coded failure.
enum Failure {
    Plain(PlainFailure),
    Coded(CodedFailure),
}

impl From<PlainFailure> for Failure {
    fn from(failure: PlainFailure) -> Self {
        Self::Plain(failure)
    }
}

impl Failure {
    fn answer(self) -> ServiceAnswer {
        match self {
            Self::Plain(failure) => ServiceAnswer::fail(failure),
            Self::Coded(failure) => ServiceAnswer::refuse(failure),
        }
    }
}

/// Swift `session.fail(code, message, details: ["newDispatchCount": 0])`.
fn coded(code: &'static str, message: impl Into<String>) -> Failure {
    Failure::Coded(CodedFailure {
        code,
        message: message.into(),
        details: Map::from_iter([("newDispatchCount".into(), json!(0))]),
    })
}

/// A registry refusal as Swift's CLI reports it: its code when the error
/// registry has it (else `recordUnreadable`), its words after `prefix`.
fn registry_failure(error: WireError, prefix: &str) -> Failure {
    coded(
        crate::error_registry::code(&error.code).unwrap_or("recordUnreadable"),
        format!("{prefix}{}", error.message),
    )
}

// MARK: - The leaves

/// `runtime service update`: Swift's options and `install`, with the
/// rulings' retention, signing refusal and cutover.
pub fn update_leaf(host: &ServiceHost, options: &Map<String, Value>) -> ServiceAnswer {
    path_leaf(host, options, "update")
}

/// `agentd install`: Swift's compatibility install from path inputs. It is
/// `update`'s path, except that nothing of an installed service is carried
/// over: `--hdc` is required, and an omitted descriptor or ArkForge lane is
/// none.
pub fn path_install_leaf(host: &ServiceHost, options: &Map<String, Value>) -> ServiceAnswer {
    path_leaf(host, options, "install")
}

fn path_leaf(host: &ServiceHost, options: &Map<String, Value>, subcommand: &str) -> ServiceAnswer {
    match update_request(host, options, subcommand).and_then(|request| install(host, request)) {
        Ok(document) => ServiceAnswer::emit(document),
        Err(failure) => ServiceAnswer::fail(failure),
    }
}

/// `runtime service install`: Swift's typed zero-Runtime install. Only with
/// no service installed, loaded or listening, it pins the exact bundle
/// generation for the service installation, publishes the first HDC selection
/// from the exact tool generation, installs the retained bundle with the
/// selected tool, and keeps only that bundle pinned; it answers
/// `arkdeck.runtime-service-installation/1`.
pub fn install_leaf(host: &ServiceHost, options: &Map<String, Value>) -> ServiceAnswer {
    match typed_install(host, options) {
        Ok(document) => ServiceAnswer::emit(document),
        Err(failure) => failure.answer(),
    }
}

/// `runtime service uninstall`: Swift's `uninstall()`, then the service
/// installation's pins released (`releaseAll`).
pub fn uninstall_leaf(host: &ServiceHost) -> ServiceAnswer {
    match uninstall(host) {
        Ok(document) => ServiceAnswer::emit(document),
        Err(failure) => failure.answer(),
    }
}

/// The Bootstrap registry's bundle and tool owners at this home, its missing
/// directories created owner-only as Swift's registry creates them.
fn bootstrap_stores(
    host: &ServiceHost,
) -> Result<(BundleRegistryReadStore, ToolRegistryStore), WireError> {
    let root = &host.paths.bootstrap_registry;
    arkdeck_bootstrap::create_store(root)?;
    let unopened = |_| WireError {
        code: "ioFailure".into(),
        message: "directory is absent or inaccessible".into(),
        details: None,
    };
    let bundles = BundleRegistryReadStore::open_existing(root)
        .map_err(unopened)?
        .with_bundle_validator(host.bundle_trust.clone());
    let mut tools = ToolRegistryStore::open_existing(root).map_err(unopened)?;
    if let Some(identities) = &host.hdc_identities {
        tools = tools.with_published_identities(identities.clone());
    }
    Ok((bundles, tools))
}

/// Swift `runAgentDaemon`'s typed install, in its order.
fn typed_install(host: &ServiceHost, options: &Map<String, Value>) -> Result<Value, Failure> {
    let option = |key: &str| options.get(key).and_then(Value::as_str);
    let command = format!("{} install", host.spelling);
    let existing = host.status().map_err(failed)?;
    if existing.installed || existing.loaded || existing.socket_present {
        return Err(coded(
            "resourceConflict",
            "runtime service install is only the zero-Runtime bootstrap path; use the reviewed \
             service update lifecycle for an existing installation",
        ));
    }
    let (Some(bundle), Some(bundle_generation)) = (option("bundle"), option("bundleGeneration"))
    else {
        return Err(coded(
            "invalidInput",
            format!("{command} requires an exact bundle and bundle generation"),
        ));
    };
    // Ruling 3: nothing is pinned while a signing receipt would need the new
    // daemon's identity re-recorded (Swift does that before `bootstrap`).
    refuse_while_signing(host, &command)?;
    let (bundles, tools) = bootstrap_stores(host).map_err(|error| registry_failure(error, ""))?;
    let installation = ReferenceOwner::service_installation();
    // Pin and revalidate the exact bundle generation before publishing an
    // initial tool selection. A later failure leaves this candidate retained
    // for explicit retry/reconciliation, never dangling.
    let retained = bundles
        .acquire(bundle, bundle_generation, &installation)
        .map_err(|error| registry_failure(error, ""))?;
    let (Some(tool), Some(tool_generation)) = (option("tool"), option("toolGeneration")) else {
        return Err(coded(
            "invalidInput",
            format!("{command} requires an exact tool and tool generation"),
        ));
    };
    let selection = tools
        .initialize_service_selection(tool, tool_generation)
        .map_err(|error| registry_failure(error, ""))?;
    let receipt = install(
        host,
        InstallRequest {
            bundle: text(&retained),
            hdc: text(&selection.executable),
            workspace: None,
            descriptor: None,
            lane: None,
            command,
            unchanged: PINS_KEPT,
        },
    )?;
    bundles
        .retain_only(bundle, &installation)
        .map_err(|error| {
            registry_failure(
                error,
                "service started, but its durable bundle reference could not be finalized: ",
            )
        })?;
    let mut document = json!({
        "schemaVersion": INSTALLATION_SCHEMA,
        "installed": true,
        "bundleRef": bundle,
        "bundleGeneration": bundle_generation,
        "activeToolRef": selection.tool_ref,
        "activeToolSelectionGeneration": selection.active_generation.to_string(),
    });
    // The Rust daemon's cutover summary, as `update` reports it.
    if let Some(cutover) = receipt.get("cutover") {
        document["cutover"] = cutover.clone();
    }
    Ok(document)
}

// MARK: - update's options, as Swift's `runAgentDaemon` reads them

/// What one `update` installs, as the caller named it.
struct InstallRequest {
    bundle: String,
    hdc: String,
    workspace: Option<(String, String)>,
    descriptor: Option<String>,
    lane: Option<ArkForgeLaneStatus>,
    /// The command as the caller typed it, for its diagnostics.
    command: String,
    /// What a refusal before any service change says changed.
    unchanged: &'static str,
}

fn update_request(
    host: &ServiceHost,
    options: &Map<String, Value>,
    subcommand: &str,
) -> Result<InstallRequest, PlainFailure> {
    let command = format!("{} {subcommand}", host.spelling);
    let update = subcommand == "update";
    let option = |key: &str| options.get(key).and_then(Value::as_str);
    let bundle = match option("daemon") {
        Some(bundle) => bundle.to_owned(),
        None => host
            .default_daemon_bundle
            .as_deref()
            .map(text)
            .unwrap_or_else(|| crate::runtime_service::DAEMON_BUNDLE_NAME.to_owned()),
    };
    let previous = if update { host.status().ok() } else { None };
    let hdc = option("hdc")
        .map(str::to_owned)
        .or_else(|| previous.as_ref().and_then(|status| status.hdc_path.clone()))
        .filter(|hdc| hdc.starts_with('/'))
        .ok_or_else(|| {
            usage(format!(
                "{command} requires --hdc with an absolute executable path"
            ))
        })?;
    if !bundle.starts_with('/') {
        return Err(usage(format!(
            "{command} requires an absolute ArkDeckAgent.app path"
        )));
    }
    // The `runtime service` spelling never keeps the legacy pair it omits;
    // the frozen `agentd update` keeps the installed one.
    let preserved = |pick: fn(&crate::runtime_service::LaunchAgentStatus) -> Option<String>| {
        previous
            .as_ref()
            .filter(|_| host.spelling == "agentd")
            .and_then(pick)
    };
    let project = option("workspaceProject")
        .map(str::to_owned)
        .or_else(|| preserved(|status| status.workspace_project_path.clone()));
    let sdk = option("devecoSdk")
        .map(str::to_owned)
        .or_else(|| preserved(|status| status.deveco_sdk_path.clone()));
    let (project, sdk) = (project.as_deref(), sdk.as_deref());
    if project.is_some() != sdk.is_some() {
        return Err(usage(format!(
            "{command} requires --workspace-project and --deveco-sdk together"
        )));
    }
    if project.is_some_and(|project| !project.starts_with('/')) {
        return Err(usage("--workspace-project must be an absolute path"));
    }
    if sdk.is_some_and(|sdk| !sdk.starts_with('/')) {
        return Err(usage("--deveco-sdk must be an absolute path"));
    }
    for (key, flag) in [
        ("sensitiveEvidence", "--sensitive-evidence"),
        ("harnessModelProvider", "--harness-model-provider"),
        ("harnessModelName", "--harness-model-name"),
        ("harnessCli", "--harness-cli"),
        ("harnessCliTimeoutSeconds", "--harness-cli-timeout-seconds"),
    ] {
        if options.contains_key(key) {
            return Err(usage(format!(
                "{flag} was removed by CHG-2026-064: decisions come from external agents \
                 through the published caller surface; re-run without it"
            )));
        }
    }
    let descriptor = match option("arktraceDescriptor") {
        Some("none") => None,
        Some(path) if path.starts_with('/') => Some(path.to_owned()),
        Some(_) => {
            return Err(usage(
                "--arktrace-descriptor must be an absolute path or none",
            ));
        }
        None if update => host
            .ark_trace_descriptor_for_preserving_update()
            .map_err(failed)?,
        None => None,
    };
    for (key, flag) in [
        ("arkforged", "--arkforged"),
        ("arkforgedSha256", "--arkforged-sha256"),
        ("arkforgeProfile", "--arkforge-profile"),
    ] {
        if options.contains_key(key) {
            return Err(usage(format!(
                "{flag} is retired; pass one validated ArkForge.bundle to --arkforge-bundle"
            )));
        }
    }
    let campaign = option("arkforgeCampaign");
    let lane = match option("arkforgeBundle") {
        Some("none") => {
            if campaign.is_some() {
                return Err(usage(
                    "--arkforge-bundle none cannot authorize an ArkForge campaign",
                ));
            }
            None
        }
        Some(bundle) if bundle.starts_with('/') => Some(
            ArkForgeLaneStatus::measuring(bundle, campaign.unwrap_or(""))
                .map_err(|refusal| usage(refusal.to_string()))?,
        ),
        Some(_) => {
            return Err(usage(
                "--arkforge-bundle must be an absolute ArkForge.bundle path or none",
            ));
        }
        None if campaign.is_some() => {
            return Err(usage(
                "--arkforge-campaign requires an explicit --arkforge-bundle",
            ));
        }
        None if update => host
            .ark_forge_lane_for_preserving_update()
            .map_err(|refusal| PlainFailure::new(1, refusal.to_string()))?,
        None => None,
    };
    refuse_while_signing(host, &command)?;
    Ok(InstallRequest {
        bundle,
        hdc,
        workspace: project.zip(sdk).map(|(p, s)| (p.to_owned(), s.to_owned())),
        descriptor,
        lane,
        command,
        unchanged: NOTHING_CHANGED,
    })
}

/// Ruling 3: Swift re-records the replacement daemon's identity in the
/// signing receipt before launchd starts it (`refreshSigningAccessIfInstalled`);
/// with no Rust signing owner yet, an installed preset refuses the install
/// before anything changes.
fn refuse_while_signing(host: &ServiceHost, command: &str) -> Result<(), PlainFailure> {
    if host.paths.signing_receipt.exists() {
        return Err(PlainFailure::new(
            69,
            format!(
                "{command} is refused while an OpenHarmony signing preset is \
                 installed ({}): the replacement daemon's identity must be re-recorded in that \
                 receipt before launchd starts it, and the Rust CLI has no signing-credential \
                 owner yet (Q8); nothing was changed",
                text(&host.paths.signing_receipt)
            ),
        ));
    }
    Ok(())
}

// MARK: - install, as Swift's `LaunchAgentService.install`

/// Which Runtime a helper bundle's daemon is.
enum Runtime {
    Swift,
    /// The Rust daemon, with its lock-free cutover preflight.
    Rust(Value),
}

fn install(host: &ServiceHost, request: InstallRequest) -> Result<Value, PlainFailure> {
    let source = (host.validate_daemon_bundle)(Path::new(&request.bundle))
        .map_err(|detail| PlainFailure::new(1, detail))?;
    let hdc = host
        .validated_executable(&request.hdc, "HDC")
        .map_err(failed)?;
    let workspace = request
        .workspace
        .map(|(project, sdk)| host.validated_workspace(&project, &sdk))
        .transpose()
        .map_err(failed)?;
    let descriptor = request
        .descriptor
        .map(|path| host.validated_descriptor(&path))
        .transpose()
        .map_err(failed)?;
    let launch_source = host.transport_executable(&source).map_err(failed)?;
    let daemon_sha256 = sha256_file(&launch_source).map_err(failed)?;
    let hdc_sha256 = sha256_file(&hdc).map_err(failed)?;

    let first = match probe(host, &source, false)? {
        Runtime::Swift => None,
        Runtime::Rust(first) => {
            // Ruling 2: the plist names this daemon as its analyzer.
            let daemon = source.join("Contents/MacOS").join(DAEMON_EXECUTABLE_NAME);
            if let Err(reason) = analyzes_crash_ledgers(&daemon) {
                return Err(PlainFailure::new(
                    69,
                    format!(
                        "{} would point the LaunchAgent at the Rust daemon \
                         in {}, whose plist names it as ARKDECK_ANALYZER_PATH, but it does not \
                         answer --analyze-crash-ledger as the Runtime runs its analyzer ({reason}); \
                         the analyzer is never pointed at the Swift daemon or left out; {}",
                        request.command,
                        text(&source),
                        request.unchanged
                    ),
                ));
            }
            if launch_source.file_name() != Some(std::ffi::OsStr::new(DAEMON_EXECUTABLE_NAME)) {
                return Err(PlainFailure::new(
                    69,
                    format!(
                        "a Rust daemon bundle carries no facade; {}",
                        request.unchanged
                    ),
                ));
            }
            refuse_unless_clear(&first, &request.command, request.unchanged)?;
            Some(first)
        }
    };

    for directory in [
        host.paths.plist.parent(),
        host.paths.installed_daemon_bundle.parent(),
        host.paths.receipt.parent(),
        Some(host.paths.log_directory.as_path()),
    ]
    .into_iter()
    .flatten()
    {
        create_owned_directory(directory).map_err(failed)?;
    }
    let loaded = host.is_loaded().map_err(failed)?;
    if loaded {
        let output = host
            .run_launchctl(&launchd::bootout_arguments(&host.launch_domain()))
            .map_err(failed)?;
        ServiceHost::require_success(&output, "bootout").map_err(failed)?;
    }
    let cutover = match first {
        None => None,
        Some(_) => Some(cutover(host, &source, loaded, &request.command)?),
    };

    let rollback = replace_bundle(host, &source).map_err(failed)?;
    (host.validate_daemon_bundle)(&host.paths.installed_daemon_bundle)
        .map_err(|detail| PlainFailure::new(1, detail))?;
    fs::set_permissions(
        &host.paths.installed_daemon,
        fs::Permissions::from_mode(0o700),
    )
    .map_err(failed)?;
    let launch = host
        .transport_executable(&host.paths.installed_daemon_bundle)
        .map_err(failed)?;
    let plist = plist_document(
        host,
        &launch,
        &hdc,
        workspace.as_ref(),
        descriptor.as_ref(),
        request.lane.as_ref(),
        cutover.is_some(),
    )
    .map_err(failed)?;
    let bytes = arkdeck_platform::write_property_list_xml(&plist).map_err(failed)?;
    write_owned_atomically(&host.paths.plist, &bytes).map_err(failed)?;

    let receipt = receipt(
        host,
        &launch,
        &daemon_sha256,
        &hdc,
        &hdc_sha256,
        workspace.as_ref(),
        descriptor.as_ref(),
        request.lane.as_ref(),
    );
    write_owned_atomically(&host.paths.receipt, &foundation_pretty_json(&receipt))
        .map_err(failed)?;
    host.bootstrap().map_err(failed)?;
    let mut document = receipt;
    if let Some(mut cutover) = cutover {
        cutover["rollbackBundlePath"] = json!(rollback.as_deref().map(text));
        document["cutover"] = cutover;
    }
    Ok(document)
}

/// The held pass, after the old service is booted out: its instance lock
/// taken, the state measured and the facts read again. A refusal starts the
/// old service again from its unchanged plist. The snapshot summary is then
/// written, and the answer's `cutover` member returned.
fn cutover(
    host: &ServiceHost,
    source: &Path,
    loaded: bool,
    command: &str,
) -> Result<Value, PlainFailure> {
    let restore = |failure: PlainFailure| -> PlainFailure {
        if !loaded {
            return PlainFailure::new(
                failure.exit_code,
                format!(
                    "{}; the service was not running and is left stopped",
                    failure.message
                ),
            );
        }
        match host.bootstrap() {
            Ok(()) => PlainFailure::new(
                failure.exit_code,
                format!(
                    "{}; the previous service was started again from its unchanged plist",
                    failure.message
                ),
            ),
            Err(error) => PlainFailure::new(
                failure.exit_code,
                format!(
                    "{}; starting the previous service again failed: {error}",
                    failure.message
                ),
            ),
        }
    };
    // `bootout` can answer before the old daemon has let its instance lock
    // go; a pass refused only for that is asked again for a bounded while.
    let mut attempts = 0;
    let held = loop {
        let held = match probe(host, source, true) {
            Ok(Runtime::Rust(held)) => held,
            Ok(Runtime::Swift) => {
                return Err(restore(PlainFailure::new(
                    69,
                    "the helper's daemon stopped answering the cutover preflight",
                )));
            }
            Err(failure) => return Err(restore(failure)),
        };
        let only_running = held["blocks"].as_array().is_some_and(|blocks| {
            !blocks.is_empty() && blocks.iter().all(|block| block["kind"] == "runtimeRunning")
        });
        attempts += 1;
        if !only_running || attempts >= HELD_PASS_ATTEMPTS {
            break held;
        }
        std::thread::sleep(host.poll_interval);
    };
    refuse_unless_clear(&held, command, "the state was left as it is").map_err(&restore)?;
    let snapshot = &held["snapshot"];
    let present = snapshot["stateDirectoryPresent"].as_bool();
    if snapshot["schemaVersion"] != SNAPSHOT_SCHEMA
        || present.is_none()
        || (present == Some(true) && held["instanceLockHeld"] != true)
        || !snapshot["rootSha256"]
            .as_str()
            .is_some_and(lowercase_sha256)
    {
        return Err(restore(PlainFailure::new(
            69,
            "the held cutover preflight answered no snapshot taken under the instance lock",
        )));
    }
    let path = write_snapshot(host, snapshot).map_err(|error| restore(failed(error)))?;
    Ok(json!({
        "snapshotPath": text(&path),
        "snapshotRootSha256": snapshot["rootSha256"],
        "carriedOver": held["carriedOver"],
    }))
}

/// Refuses unless the preflight document is clear, naming each block.
fn refuse_unless_clear(
    document: &Value,
    command: &str,
    unchanged: &str,
) -> Result<(), PlainFailure> {
    if document["clear"] == true {
        return Ok(());
    }
    let blocks: Vec<String> = document["blocks"]
        .as_array()
        .into_iter()
        .flatten()
        .map(block_text)
        .collect();
    Err(PlainFailure::new(
        75,
        format!(
            "{command} refused: the Runtime state cannot be carried over as it is \
             ({}); {unchanged}",
            blocks.join("; ")
        ),
    ))
}

fn block_text(block: &Value) -> String {
    let field = |key: &str| block[key].as_str().unwrap_or_default().to_owned();
    match block["kind"].as_str().unwrap_or_default() {
        "jobState" => format!("Job {} is {}", field("jobId"), field("state")),
        "unresolvedJournal" => format!("Job {} has an unresolved journal", field("jobId")),
        "activeAgentExecution" => format!(
            "agent execution {} is {}",
            field("executionId"),
            field("state")
        ),
        "unsettledCapabilityUse" => format!(
            "capability {} use {} of Job {} is unsettled",
            field("capabilityId"),
            block["useOrdinal"],
            field("jobId")
        ),
        "pendingToolSelection" => {
            format!("HDC tool selection {} is pending", field("controlActionId"))
        }
        "runtimeRunning" => field("reason"),
        "unreadable" => format!("{} is unreadable: {}", field("source"), field("reason")),
        other => format!("{other}: {block}"),
    }
}

fn lowercase_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| matches!(byte, b'0'..=b'9' | b'a'..=b'f'))
}

/// What `<bundle>/Contents/MacOS/arkdeck-agentd --cutover-preflight` answers:
/// the Rust daemon a canonical document for this home's state directory,
/// Swift's daemon exit 64 for an argument it does not take. Anything else
/// cannot be told apart and is refused.
fn probe(host: &ServiceHost, bundle: &Path, hold: bool) -> Result<Runtime, PlainFailure> {
    let executable = bundle.join("Contents/MacOS").join(DAEMON_EXECUTABLE_NAME);
    let mut arguments = vec![PREFLIGHT_FLAG];
    if hold {
        arguments.push(HOLD_FLAG);
    }
    let mut environment = vec![
        (
            OsString::from("HOME"),
            host.paths.home.clone().into_os_string(),
        ),
        (OsString::from(COMPOSITION), OsString::from("production")),
    ];
    if host.relocated_home {
        environment.push((
            OsString::from("CFFIXED_USER_HOME"),
            host.paths.home.clone().into_os_string(),
        ));
    }
    let finished = run_bounded(
        &executable,
        &arguments,
        &environment,
        host.preflight_timeout,
    )
    .map_err(|error| {
        PlainFailure::new(
            69,
            format!(
                "the cutover preflight of {} could not run: {error}",
                text(&executable)
            ),
        )
    })?;
    let stderr = String::from_utf8_lossy(&finished.stderr).trim().to_owned();
    match finished.status {
        Some(0) => {
            let document = arkdeck_contract::strict_json(&finished.stdout)
                .ok()
                .filter(|document| {
                    document["schemaVersion"] == PREFLIGHT_SCHEMA
                        && document["clear"].is_boolean()
                        && document["blocks"].is_array()
                        && document["instanceLockHeld"].is_boolean()
                })
                .ok_or_else(|| {
                    PlainFailure::new(
                        69,
                        "the cutover preflight answered no arkdeck.cutover-preflight/1 document",
                    )
                })?;
            if document["stateDirectory"] != text(&host.paths.state_directory).as_str() {
                return Err(PlainFailure::new(
                    69,
                    format!(
                        "the cutover preflight read {} instead of this home's state directory",
                        document["stateDirectory"]
                    ),
                ));
            }
            Ok(Runtime::Rust(document))
        }
        Some(64) if stderr.contains(SWIFT_UNKNOWN_ARGUMENT) => Ok(Runtime::Swift),
        status => Err(PlainFailure::new(
            69,
            format!(
                "the helper's daemon neither answers the cutover preflight nor refuses it as \
                 Swift's daemon does ({}): {stderr}",
                status.map_or_else(
                    || "no exit status".to_owned(),
                    |code| format!("exit {code}")
                )
            ),
        )),
    }
}

/// Whether `daemon` answers `--analyze-crash-ledger` as the Runtime's analyzer
/// child: run through the Runtime's own runner (the pinned executable, no
/// environment, the source's `/.vol` alias, the Runtime's budget), it must
/// exit 0 and print Swift's answer to the probe listing byte for byte. The
/// listing is written to a private directory of the account's temporary
/// directory and removed with it; nothing else is written.
fn analyzes_crash_ledgers(daemon: &Path) -> Result<(), String> {
    use arkdeck_platform::{AnalyzerLimits, AnalyzerTermination, VerifiedSource, VerifiedTool};
    let tool = sha256_file(daemon)
        .and_then(|sha256| VerifiedTool::open(daemon, &sha256))
        .map_err(|error| format!("its daemon cannot be pinned: {error}"))?;
    let directory = ProbeDirectory::create()
        .map_err(|error| format!("the probe listing cannot be written: {error}"))?;
    let listing = directory.0.join("crash-index.txt");
    let source = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&listing)
        .and_then(|mut file| file.write_all(ANALYZER_PROBE_LISTING))
        .and_then(|()| {
            VerifiedSource::open(
                &listing,
                &arkdeck_contract::sha256_hex(ANALYZER_PROBE_LISTING),
                ANALYZER_PROBE_LISTING.len() as u64,
            )
        })
        .map_err(|error| format!("the probe listing cannot be written: {error}"))?;
    let arguments = [OsString::from(ANALYZER_FLAG), source.inode_path().into()];
    let limits = AnalyzerLimits {
        timeout: ANALYZER_PROBE_TIMEOUT,
        capture_bytes: 64 * 1024,
    };
    let execution = tool
        .run_analyzer(&arguments, &source, limits, &|| false)
        .map_err(|error| format!("it could not run: {error:?}"))?;
    match execution.termination {
        AnalyzerTermination::Exited(0)
            if !execution.truncated && execution.stdout == ANALYZER_PROBE_ANSWER =>
        {
            Ok(())
        }
        AnalyzerTermination::Exited(0) => Err("it answered other than Swift's analyzer".into()),
        AnalyzerTermination::Exited(status) => Err(format!(
            "exit {status}: {}",
            String::from_utf8_lossy(&execution.stderr)
                .lines()
                .next()
                .unwrap_or_default()
                .trim()
        )),
        AnalyzerTermination::Signalled(signal) => Err(format!("it ended by signal {signal}")),
        AnalyzerTermination::TimedOut => Err(format!(
            "it did not finish within {}s",
            ANALYZER_PROBE_TIMEOUT.as_secs()
        )),
        AnalyzerTermination::Cancelled { .. } => Err("it was cancelled".into()),
    }
}

/// The probe listing's private directory, removed with what it holds.
struct ProbeDirectory(PathBuf);

impl ProbeDirectory {
    fn create() -> io::Result<Self> {
        let name = format!(
            "arkdeck-analyzer-probe-{:032x}",
            u128::from_ne_bytes(arkdeck_platform::random_bytes::<16>()?)
        );
        let path = arkdeck_platform::foundation_temporary_directory().join(name);
        fs::DirBuilder::new().mode(0o700).create(&path)?;
        Ok(Self(path))
    }
}

impl Drop for ProbeDirectory {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

struct Finished {
    status: Option<i32>,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
}

/// Runs `executable` with exactly `environment`, no stdin and both outputs
/// bounded, killing it when `timeout` ends.
fn run_bounded(
    executable: &Path,
    arguments: &[&str],
    environment: &[(OsString, OsString)],
    timeout: Duration,
) -> io::Result<Finished> {
    let mut child = Command::new(executable)
        .args(arguments)
        .env_clear()
        .envs(environment.iter().map(|(key, value)| (key, value)))
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let read = |pipe: Option<Box<dyn Read + Send>>, maximum: u64| {
        std::thread::spawn(move || -> io::Result<Vec<u8>> {
            let mut bytes = Vec::new();
            if let Some(pipe) = pipe {
                pipe.take(maximum + 1).read_to_end(&mut bytes)?;
            }
            Ok(bytes)
        })
    };
    let stdout = read(
        child
            .stdout
            .take()
            .map(|pipe| Box::new(pipe) as Box<dyn Read + Send>),
        PREFLIGHT_OUTPUT_MAXIMUM,
    );
    let stderr = read(
        child
            .stderr
            .take()
            .map(|pipe| Box::new(pipe) as Box<dyn Read + Send>),
        PREFLIGHT_ERROR_MAXIMUM,
    );
    let deadline = Instant::now() + timeout;
    let status = loop {
        if let Some(status) = child.try_wait()? {
            break Some(status);
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            break None;
        }
        std::thread::sleep(Duration::from_millis(10));
    };
    let joined = |reader: std::thread::JoinHandle<io::Result<Vec<u8>>>| {
        reader
            .join()
            .map_err(|_| io::Error::other("an output reader stopped"))?
    };
    let (stdout, stderr) = (joined(stdout)?, joined(stderr)?);
    let Some(status) = status else {
        return Err(io::Error::new(
            io::ErrorKind::TimedOut,
            format!("it did not finish within {}s", timeout.as_secs()),
        ));
    };
    if stdout.len() as u64 > PREFLIGHT_OUTPUT_MAXIMUM {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "its answer exceeds its byte bound",
        ));
    }
    Ok(Finished {
        status: status.code(),
        stdout,
        stderr,
    })
}

/// Writes the held pass's snapshot summary, owner-only, named by the time it
/// was taken and its root digest. The same summary already there is kept.
fn write_snapshot(host: &ServiceHost, snapshot: &Value) -> Result<PathBuf, ServiceError> {
    create_owned_directory(&host.paths.cutover_snapshots)?;
    let taken: String = snapshot["takenAtUtc"]
        .as_str()
        .unwrap_or_default()
        .chars()
        .filter(char::is_ascii_alphanumeric)
        .collect();
    let root = snapshot["rootSha256"].as_str().unwrap_or_default();
    let path = host
        .paths
        .cutover_snapshots
        .join(format!("cutover-{taken}-{}.json", &root[..12]));
    let mut bytes = arkdeck_contract::canonical_json(snapshot)
        .map_err(|error| ServiceError::Other(format!("{error:?}")))?;
    bytes.push(b'\n');
    match fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&path)
    {
        Ok(mut file) => {
            file.write_all(&bytes)?;
            file.sync_all()?;
        }
        Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
            if fs::read(&path)? != bytes {
                return Err(ServiceError::Other(format!(
                    "another cutover snapshot already holds {}",
                    text(&path)
                )));
            }
        }
        Err(error) => return Err(error.into()),
    }
    Ok(path)
}

/// Swift `copyItem` into a staging name beside the installed helper, then
/// `replaceItemAt`: one exchange, so the installed path always holds a bundle.
/// The helper replaced is kept one generation in `Helpers/.rollback`, and its
/// path answered; there is none when nothing was installed or the source is
/// the installed helper itself.
fn replace_bundle(host: &ServiceHost, source: &Path) -> Result<Option<PathBuf>, ServiceError> {
    let installed = &host.paths.installed_daemon_bundle;
    if text(source) == text(installed) {
        return Ok(None);
    }
    let helpers = installed
        .parent()
        .ok_or_else(|| ServiceError::Other("the helper bundle has no parent".into()))?;
    let identity = crate::job_plan::uuid()
        .map_err(|error| ServiceError::Other(error.message))?
        .to_uppercase();
    let staging = helpers.join(format!(".arkdeck-agentd-{identity}.app"));
    let discard = |error: io::Error| {
        let _ = fs::remove_dir_all(&staging);
        ServiceError::from(error)
    };
    arkdeck_platform::clone_tree(source, &staging).map_err(discard)?;
    if fs::symlink_metadata(installed).is_err() {
        fs::rename(&staging, installed).map_err(discard)?;
        return Ok(None);
    }
    arkdeck_platform::exchange_paths(&staging, installed).map_err(discard)?;
    // `staging` now holds the helper that was installed.
    let rollback = &host.paths.rollback_bundle;
    if let Some(parent) = rollback.parent() {
        create_owned_directory(parent)?;
    }
    remove_if_present(rollback)?;
    fs::rename(&staging, rollback)?;
    Ok(Some(rollback.clone()))
}

/// Swift `renderTemplate`: the bundled template's fixed keys, the three
/// placeholders replaced, and the environment Swift writes. The production
/// composition is asked for only on the Rust daemon's cutover.
fn plist_document(
    host: &ServiceHost,
    launch: &Path,
    hdc: &Path,
    workspace: Option<&Workspace>,
    descriptor: Option<&ValidatedDescriptor>,
    lane: Option<&ArkForgeLaneStatus>,
    production: bool,
) -> Result<PropertyListValue, ServiceError> {
    let string = |value: &str| PropertyListValue::String(value.to_owned());
    let installed = &host.paths.installed_daemon;
    let mut environment = BTreeMap::new();
    environment.insert(HDC_KEY.to_owned(), string(&text(hdc)));
    // The analyzer is this daemon in one-shot mode; the inspector a fixed host
    // tool. Neither depends on the retired project/SDK pair.
    environment.insert(ANALYZER_KEY.to_owned(), string(&text(installed)));
    if text(launch) != text(installed) {
        environment.insert(
            SWIFT_SHA256_KEY.to_owned(),
            string(&sha256_file(installed)?),
        );
    }
    environment.insert(
        WORKSPACE_INSPECTOR_KEY.to_owned(),
        string(WORKSPACE_INSPECTOR),
    );
    if let Some(workspace) = workspace {
        environment.insert(
            WORKSPACE_PROJECTS_KEY.to_owned(),
            string(&format!(
                "{WATERFLOW_PROJECT_REF}={}",
                workspace.project_root
            )),
        );
        environment.insert(
            WORKSPACE_ACTIVE_PROJECT_KEY.to_owned(),
            string(WATERFLOW_PROJECT_REF),
        );
        environment.insert(
            DEVECO_SDK_KEY.to_owned(),
            string(&workspace.deveco_sdk_root),
        );
    }
    if let Some(descriptor) = descriptor {
        environment.insert(
            ARKTRACE_DESCRIPTOR_KEY.to_owned(),
            string(&descriptor.status.descriptor_path),
        );
    }
    if let Some(lane) = lane {
        environment.insert(ARKFORGE_BUNDLE_KEY.to_owned(), string(&lane.bundle_path));
        // Written only when authorized: an empty value would read as an
        // unnamed campaign.
        if !lane.campaign.is_empty() {
            environment.insert(ARKFORGE_CAMPAIGN_KEY.to_owned(), string(&lane.campaign));
        }
    }
    if production {
        environment.insert(COMPOSITION.to_owned(), string("production"));
    }
    let document = BTreeMap::from([
        ("Label".to_owned(), string(LABEL)),
        (
            "ProgramArguments".to_owned(),
            PropertyListValue::Array(vec![string(&text(launch))]),
        ),
        (
            "EnvironmentVariables".to_owned(),
            PropertyListValue::Dictionary(environment),
        ),
        (
            "MachServices".to_owned(),
            PropertyListValue::Dictionary(BTreeMap::from([(
                LABEL.to_owned(),
                PropertyListValue::Boolean(true),
            )])),
        ),
        ("RunAtLoad".to_owned(), PropertyListValue::Boolean(true)),
        ("KeepAlive".to_owned(), PropertyListValue::Boolean(true)),
        ("LimitLoadToSessionType".to_owned(), string("Aqua")),
        ("ProcessType".to_owned(), string("Standard")),
        ("ThrottleInterval".to_owned(), PropertyListValue::Integer(5)),
        ("Umask".to_owned(), PropertyListValue::Integer(63)),
        (
            "StandardOutPath".to_owned(),
            string(&text(&host.paths.standard_output)),
        ),
        (
            "StandardErrorPath".to_owned(),
            string(&text(&host.paths.standard_error)),
        ),
    ]);
    Ok(PropertyListValue::Dictionary(document))
}

/// Swift `LaunchAgentInstallReceipt`, an absent optional omitted.
#[allow(clippy::too_many_arguments)]
fn receipt(
    host: &ServiceHost,
    launch: &Path,
    daemon_sha256: &str,
    hdc: &Path,
    hdc_sha256: &str,
    workspace: Option<&Workspace>,
    descriptor: Option<&ValidatedDescriptor>,
    lane: Option<&ArkForgeLaneStatus>,
) -> Value {
    let mut fields = Map::new();
    fields.insert("schemaVersion".into(), json!(RECEIPT_SCHEMA));
    fields.insert("installedAtUTC".into(), json!((host.now_utc)()));
    fields.insert("daemonPath".into(), json!(text(launch)));
    fields.insert("daemonSHA256".into(), json!(daemon_sha256));
    fields.insert("hdcPath".into(), json!(text(hdc)));
    fields.insert("hdcSHA256".into(), json!(hdc_sha256));
    if let Some(workspace) = workspace {
        fields.insert("workspaceProjectPath".into(), json!(workspace.project_root));
        fields.insert("devecoSDKPath".into(), json!(workspace.deveco_sdk_root));
    }
    if let Some(descriptor) = descriptor {
        fields.insert("arkTraceDescriptor".into(), descriptor.status.json());
    }
    if let Some(lane) = lane {
        fields.insert("arkForgeLane".into(), lane.json());
    }
    Value::Object(fields)
}

/// Foundation `JSONEncoder` with `[.sortedKeys, .prettyPrinted,
/// .withoutEscapingSlashes]`: two-space indentation, `" : "` between a key and
/// its value, no final newline. serde escapes what Foundation escapes here
/// and leaves the solidus alone.
pub(crate) fn foundation_pretty_json(value: &Value) -> Vec<u8> {
    fn line(output: &mut Vec<u8>, depth: usize) {
        output.push(b'\n');
        output.resize(output.len() + 2 * depth, b' ');
    }
    fn write(value: &Value, depth: usize, output: &mut Vec<u8>) {
        match value {
            Value::Object(fields) => {
                let mut keys: Vec<&String> = fields.keys().collect();
                keys.sort_unstable();
                output.push(b'{');
                for (index, key) in keys.iter().enumerate() {
                    if index > 0 {
                        output.push(b',');
                    }
                    line(output, depth + 1);
                    output.extend(serde_json::to_vec(key).expect("a JSON string"));
                    output.extend_from_slice(b" : ");
                    write(&fields[key.as_str()], depth + 1, output);
                }
                if fields.is_empty() {
                    output.push(b'\n');
                }
                line(output, depth);
                output.push(b'}');
            }
            Value::Array(values) => {
                output.push(b'[');
                for (index, value) in values.iter().enumerate() {
                    if index > 0 {
                        output.push(b',');
                    }
                    line(output, depth + 1);
                    write(value, depth + 1, output);
                }
                if values.is_empty() {
                    output.push(b'\n');
                }
                line(output, depth);
                output.push(b']');
            }
            other => output.extend(serde_json::to_vec(other).expect("a JSON value")),
        }
    }
    let mut output = Vec::new();
    write(value, 0, &mut output);
    output
}

/// Swift `createOwnedDirectory`: created owner-only with its missing parents;
/// an existing directory is left as it is.
fn create_owned_directory(path: &Path) -> io::Result<()> {
    fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(path)
}

/// Swift's `.atomic` write followed by its `chmod 0600`.
fn write_owned_atomically(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::other("the document has no parent"))?;
    let name = path
        .file_name()
        .ok_or_else(|| io::Error::other("the document has no name"))?
        .to_string_lossy();
    let identity = crate::job_plan::uuid().map_err(|error| io::Error::other(error.message))?;
    let temporary = parent.join(format!(".{name}.{identity}"));
    let written = (|| {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temporary)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        fs::rename(&temporary, path)
    })();
    if written.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    written?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))
}

/// Swift `removeIfPresent`: whether anything was there to remove.
fn remove_if_present(path: &Path) -> io::Result<bool> {
    let Ok(metadata) = fs::symlink_metadata(path) else {
        return Ok(false);
    };
    if metadata.is_dir() {
        fs::remove_dir_all(path)?;
    } else {
        fs::remove_file(path)?;
    }
    Ok(true)
}

// MARK: - uninstall

/// Swift `uninstall()`, then `releaseAll` of the service installation's pins
/// once the service is confirmed removed. A release that fails is reported
/// after the removal, which is not undone; the pins stay for a retry.
fn uninstall(host: &ServiceHost) -> Result<Value, Failure> {
    if host.is_loaded().map_err(failed)? {
        let output = host
            .run_launchctl(&launchd::bootout_arguments(&host.launch_domain()))
            .map_err(failed)?;
        ServiceHost::require_success(&output, "bootout").map_err(failed)?;
    }
    let removed_plist = remove_if_present(&host.paths.plist).map_err(failed)?;
    let removed_daemon = remove_if_present(&host.paths.installed_daemon_bundle).map_err(failed)?;
    let removed_receipt = remove_if_present(&host.paths.receipt).map_err(failed)?;
    let removal = json!({
        "removedPlist": removed_plist,
        "removedDaemon": removed_daemon,
        "removedReceipt": removed_receipt,
        "preservedStateDirectory": text(&host.paths.state_directory),
        "preservedLogDirectory": text(&host.paths.log_directory),
    });
    bootstrap_stores(host)
        .and_then(|(bundles, _)| bundles.release_all(&ReferenceOwner::service_installation()))
        .map_err(|error| {
            registry_failure(
                error,
                "service was removed, but its durable bundle references could not be released: ",
            )
        })?;
    Ok(removal)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Printed by Foundation `JSONEncoder([.sortedKeys, .prettyPrinted,
    /// .withoutEscapingSlashes])` for a receipt of this shape.
    #[test]
    fn a_receipt_is_written_as_foundation_writes_it() {
        let value = json!({
            "schemaVersion": "arkdeck-launchagent-install/v1",
            "installedAtUTC": "2026-09-24T00:00:00Z",
            "daemonPath": "/a/b",
            "daemonSHA256": "00",
            "arkTraceDescriptor": {"descriptorPath": "/d", "descriptorByteCount": 3},
        });
        assert_eq!(
            String::from_utf8(foundation_pretty_json(&value)).unwrap(),
            "{\n  \"arkTraceDescriptor\" : {\n    \"descriptorByteCount\" : 3,\n    \
             \"descriptorPath\" : \"/d\"\n  },\n  \"daemonPath\" : \"/a/b\",\n  \
             \"daemonSHA256\" : \"00\",\n  \
             \"installedAtUTC\" : \"2026-09-24T00:00:00Z\",\n  \
             \"schemaVersion\" : \"arkdeck-launchagent-install/v1\"\n}"
        );
    }
}
