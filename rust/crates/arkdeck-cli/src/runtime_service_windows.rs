//! The Windows runtime service (TASK-XPA-002, CHG-2026-074 r12 decision 11):
//! no service manager, a daemon its client starts and that is
//! single-instance. The implementation choices below were proposed by the
//! lead for maintainer review (the client-started daemon run record).
//!
//! * Every command that needs the Runtime starts it when its pipe is absent
//!   ([`ensure_runtime`], `arkdeck_client::start`), then connects and checks
//!   the daemon's identity as always; a lost request is never replayed.
//! * `runtime service status`: the installed daemon image, the state root and
//!   the daemon's `health` when its pipe exists; nothing is started.
//! * `runtime service verify`: the installed daemon identity (the pinned path
//!   and its signer certificate or package family) and the state root
//!   (`%LOCALAPPDATA%\ArkDeck\Agentd` from the Known Folder API, owner-only),
//!   and, when a daemon runs, its identity and `health`; nothing is started.
//! * `runtime service restart`: the running daemon's stop is asked for through
//!   its own stop event, its single-instance guard is awaited (bounded), and
//!   the successor is started as a client starts it and proved to be a new
//!   process speaking the same catalog with the same closed Jobs. A drain its
//!   deadline cut short leaves the guard abandoned, which is reported; the
//!   successor then starts as after a crash.
//!
//! The documents follow the macOS leaves' (`runtime_service.rs`): the same
//! members where the fact is the same (`daemonHealth`, `runtime`,
//! `runtimeVerified`, `restartProof`), `daemonService` where macOS has
//! `launchAgent`, and the same exit statuses (64 for an option out of range,
//! 69 for a service that is not ready or a daemon that cannot be proved, 75
//! for a restart refused by current Jobs). `install`, `update` and
//! `uninstall` stay macOS-only (`unsupportedOnPlatform`), as do the retired
//! `agentd` spellings.
use crate::{CliError, Invocation};
use arkdeck_client::start::{StartFailure, StartTarget, Started, connect_verified, ensure_running};
use arkdeck_client::{Client, ClientError};
use arkdeck_platform::{
    GuardAcquisition, GuardObject, ImagePin, LocalConnection, LocalEndpoint, ServerIdentity,
    StateRoot, pipe_present, verify_daemon_image,
};
use serde_json::{Map, Value, json};
use std::ffi::OsString;
use std::path::PathBuf;
use std::time::{Duration, Instant};

const RESTART_SCHEMA: &str = "arkdeck-windows-daemon-restart/v1";
const RESTART_PROOF_SCHEMA: &str = "arkdeck-windows-daemon-restart-proof/v1";
const INSTANCE_DOCUMENT: &str = "instance.json";
const DOCUMENT_LIMIT: u64 = 64 * 1024;
/// How long a command waits for the daemon it started.
pub const START_WAIT: Duration = Duration::from_secs(20);
const CONNECTION_TIMEOUT: Duration = Duration::from_secs(20);

/// Swift's plain `CLIError`: an exit status and a stderr diagnostic.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PlainFailure {
    pub exit_code: u8,
    pub message: String,
}

impl PlainFailure {
    fn new(exit_code: u8, message: impl Into<String>) -> Self {
        Self {
            exit_code,
            message: message.into(),
        }
    }
}

/// A coded refusal (Swift `session.fail`), as `runtime_service::CodedFailure`.
#[derive(Clone, Debug, PartialEq)]
pub struct CodedFailure {
    pub code: &'static str,
    pub message: String,
    pub details: Map<String, Value>,
}

/// One document, if any, and the failure that follows it, if any, as
/// `runtime_service::ServiceAnswer`.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ServiceAnswer {
    pub document: Option<Value>,
    pub failure: Option<PlainFailure>,
    pub refusal: Option<CodedFailure>,
}

impl ServiceAnswer {
    fn emit(document: Value) -> Self {
        Self {
            document: Some(document),
            ..Self::default()
        }
    }
    fn fail(failure: PlainFailure) -> Self {
        Self {
            failure: Some(failure),
            ..Self::default()
        }
    }
    fn emit_then_fail(document: Value, failure: PlainFailure) -> Self {
        Self {
            document: Some(document),
            failure: Some(failure),
            refusal: None,
        }
    }
}

/// The daemon image this CLI trusts: `ARKDECK_DAEMON_PATH` or the daemon
/// beside the CLI, with its signer pin or package family.
pub fn installed_identity() -> Option<ServerIdentity> {
    let executable = std::env::var_os("ARKDECK_DAEMON_PATH")
        .map(PathBuf::from)
        .or_else(|| {
            std::env::current_exe()
                .ok()
                .map(|path| path.with_file_name("arkdeck-agentd.exe"))
        })?;
    Some(ServerIdentity {
        executable,
        authenticode_sha256: std::env::var("ARKDECK_DAEMON_SIGNER_SHA256").ok(),
        package_family: std::env::var("ARKDECK_DAEMON_PACKAGE_FAMILY").ok(),
    })
}

/// A start failure in this CLI's words: the Runtime is unavailable, nothing
/// was sent, and the outcome is named in `details.daemonStart`.
pub fn start_error(failure: &StartFailure) -> CliError {
    let mut error = CliError::new("runtimeUnavailable", failure.message.clone());
    error
        .details
        .insert("daemonStart".into(), start_failure_json(failure));
    error
}

fn start_failure_json(failure: &StartFailure) -> Value {
    let mut fields = Map::from_iter([("outcome".into(), json!(failure.refusal.code()))]);
    if let Some(pid) = failure.pid {
        fields.insert("pid".into(), json!(pid));
    }
    if let arkdeck_client::start::StartRefusal::DaemonExited(code) = failure.refusal {
        fields.insert("exitCode".into(), json!(code));
    }
    Value::Object(fields)
}

/// Before a command reaches the Runtime (not for `--socket`): the daemon a
/// client may start for this environment ([`StartTarget::resolve`]) is
/// started if its pipe is absent, and the endpoint to reach is returned. An
/// endpoint no client starts (a private `ARKDECK_ENDPOINT`) is returned as
/// it is, and nothing is started.
pub fn ensure_runtime(
    endpoint: LocalEndpoint,
    identity: &ServerIdentity,
) -> Result<LocalEndpoint, CliError> {
    let named = std::env::var_os("ARKDECK_ENDPOINT");
    let development = std::env::var_os("ARKDECK_DEVELOPMENT_STATE_ROOT");
    let target = StartTarget::resolve(named.as_deref(), development.as_deref(), identity.clone())
        .map_err(|error| {
        CliError::new(
            "runtimeUnavailable",
            format!("the daemon this client would start is unusable: {error}"),
        )
    })?;
    let Some(target) = target else {
        return Ok(endpoint);
    };
    ensure_running(&target, START_WAIT).map_err(|failure| start_error(&failure))?;
    Ok(target.endpoint)
}

// MARK: - Target and status

/// The client-started daemon these leaves manage: the account's, or an
/// isolated development root's (`ARKDECK_DEVELOPMENT_STATE_ROOT`).
pub struct ServiceTarget {
    pub start: StartTarget,
    pub root_path: PathBuf,
}

impl ServiceTarget {
    /// From the process environment. An `ARKDECK_ENDPOINT` must be the
    /// root's own pipe: a private daemon is not the service.
    pub fn from_environment() -> Result<Self, PlainFailure> {
        let identity = installed_identity()
            .ok_or_else(|| PlainFailure::new(1, "the installed daemon identity is unavailable"))?;
        Self::new(
            std::env::var_os("ARKDECK_ENDPOINT"),
            std::env::var_os("ARKDECK_DEVELOPMENT_STATE_ROOT"),
            identity,
        )
    }

    pub fn new(
        endpoint: Option<OsString>,
        development_root: Option<OsString>,
        identity: ServerIdentity,
    ) -> Result<Self, PlainFailure> {
        let root_path = match &development_root {
            Some(root) => PathBuf::from(root),
            None => StateRoot::account_path().map_err(|error| {
                PlainFailure::new(
                    1,
                    format!("the account's state root is unavailable: {error}"),
                )
            })?,
        };
        let start =
            StartTarget::resolve(endpoint.as_deref(), development_root.as_deref(), identity)
                .map_err(|error| {
                    PlainFailure::new(69, format!("the daemon state root is unusable: {error}"))
                })?
                .ok_or_else(|| {
                    PlainFailure::new(
                        69,
                        "ARKDECK_ENDPOINT names a private daemon, not the client-started runtime \
                     service",
                    )
                })?;
        Ok(Self { start, root_path })
    }

    fn development(&self) -> bool {
        self.start.development_root.is_some()
    }

    /// The root as it is now, never created.
    fn open_root(&self) -> std::io::Result<Option<StateRoot>> {
        match &self.start.development_root {
            Some(root) => StateRoot::development(root).map(Some),
            None => StateRoot::existing_account(),
        }
    }
}

/// What `status` and `verify` read, starting nothing.
#[derive(Clone, Debug, PartialEq)]
pub struct ServiceStatus {
    pub document: Value,
    pub socket_path: String,
    pub socket_present: bool,
    pub instance: Option<Value>,
    pub diagnostics: Vec<String>,
    pub ready: bool,
}

/// The installed daemon, the state root and the pipe, as they are.
pub fn inspect(target: &ServiceTarget) -> ServiceStatus {
    let mut diagnostics = Vec::new();
    let identity = &target.start.identity;
    let image = match verify_daemon_image(identity) {
        Ok(pin) => json!({"verified": true, "pin": match pin {
            ImagePin::Signer => "signer",
            ImagePin::PackageFamily => "packageFamily",
        }}),
        Err(error) => {
            diagnostics.push(format!("installed daemon image refused: {error}"));
            json!({"verified": false, "pin": null, "detail": error.to_string()})
        }
    };
    let mut root = Map::from_iter([
        (
            "kind".into(),
            json!(if target.development() {
                "development"
            } else {
                "account"
            }),
        ),
        ("path".into(), json!(target.root_path.display().to_string())),
    ]);
    let mut instance = None;
    match target.open_root() {
        Ok(None) => {
            // The first start creates it owner-only.
            root.insert("present".into(), json!(false));
        }
        Ok(Some(opened)) => {
            root.insert("present".into(), json!(true));
            root.insert("ownedByUser".into(), json!(true));
            match opened.access_findings() {
                Ok(findings) => {
                    root.insert("ownerOnly".into(), json!(findings.is_empty()));
                    // The daemon refuses an account root that is not
                    // owner-only; a development root is the developer's.
                    if !target.development() && !findings.is_empty() {
                        diagnostics.push(format!(
                            "the account's state root is not owner-only: {}; {}",
                            findings.join("; "),
                            arkdeck_platform::OWNER_ONLY_REMEDY
                        ));
                    }
                    root.insert("accessFindings".into(), json!(findings));
                }
                Err(error) => diagnostics.push(format!("state root access unreadable: {error}")),
            }
            instance = opened
                .read_document(INSTANCE_DOCUMENT, DOCUMENT_LIMIT)
                .ok()
                .flatten()
                .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
                .filter(Value::is_object);
        }
        Err(error) => {
            root.insert("present".into(), json!(true));
            diagnostics.push(format!("the daemon state root is unusable: {error}"));
        }
    }
    let socket_path = target.start.endpoint.as_path().display().to_string();
    let socket_present = match pipe_present(&target.start.endpoint) {
        Ok(present) => present,
        Err(error) => {
            diagnostics.push(format!("the daemon's pipe cannot be looked at: {error}"));
            false
        }
    };
    let ready = diagnostics.is_empty();
    let mut document = Map::from_iter([
        ("startMode".into(), json!("clientStarted")),
        (
            "daemonPath".into(),
            json!(identity.executable.display().to_string()),
        ),
    ]);
    if let Some(pin) = &identity.authenticode_sha256 {
        document.insert("daemonSignerSHA256".into(), json!(pin));
    }
    if let Some(family) = &identity.package_family {
        document.insert("daemonPackageFamily".into(), json!(family));
    }
    document.insert("daemonImage".into(), image);
    document.insert("stateRoot".into(), Value::Object(root));
    document.insert("socketPath".into(), json!(socket_path));
    document.insert("socketPresent".into(), json!(socket_present));
    if let Some(instance) = &instance {
        document.insert("instance".into(), instance.clone());
    }
    document.insert("diagnostics".into(), json!(diagnostics));
    document.insert("ready".into(), json!(ready));
    ServiceStatus {
        document: Value::Object(document),
        socket_path,
        socket_present,
        instance,
        diagnostics,
        ready,
    }
}

/// A connection to the daemon serving the target's pipe, once it proved the
/// installed identity, and that daemon's process id.
fn connect(target: &ServiceTarget) -> Result<(Client<LocalConnection>, u32), String> {
    let deadline = Instant::now() + CONNECTION_TIMEOUT;
    let connection = connect_verified(&target.start.endpoint, &target.start.identity, deadline)
        .map_err(|error| format!("the daemon did not prove the installed identity: {error}"))?;
    let pid = connection.authenticated_peer_pid();
    connection
        .set_read_timeout(Some(CONNECTION_TIMEOUT))
        .and_then(|()| connection.set_write_timeout(Some(CONNECTION_TIMEOUT)))
        .map_err(|error| error.to_string())?;
    Ok((Client::new(connection), pid))
}

/// Swift `agentdHealthCatalogDigest`, as `runtime_service.rs` reads it.
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

/// The current Jobs' restart decision (`runtime_service.rs`
/// `restart_job_preflight`, one complete `job.list` snapshot), or `None` for
/// a daemon that composes no Job owner and so has no Job at all.
fn job_preflight(
    client: &mut Client<LocalConnection>,
    id: &str,
) -> Result<Option<arkdeck_contract::RestartPreflight>, PlainFailure> {
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
        let page = match client.request(id, "job.list", Some(params)) {
            Ok(page) => page,
            // The foundation's answer when no Job owner is composed
            // (`arkdeck-control`'s `job_resource`); anything else is not
            // read as "no Jobs".
            Err(ClientError::Remote(wire))
                if cursor.is_none()
                    && wire.code == "rejected"
                    && wire.message == "The Job owner is not configured" =>
            {
                return Ok(None);
            }
            Err(error) => return Err(PlainFailure::new(1, error.to_string())),
        };
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
            match page["nextCursor"].as_str().map(str::to_owned) {
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
        .map(Some)
        .map_err(|_| PlainFailure::new(69, "daemon returned a malformed current Runtime Job"))
}

// MARK: - Leaves

/// `runtime service status`: the service as it is and, when its pipe exists,
/// the daemon's `health` over a connection that proved its identity.
pub fn status_leaf(target: &ServiceTarget, id: &str) -> ServiceAnswer {
    let status = inspect(target);
    let health = if status.socket_present {
        connect(target)
            .and_then(|(mut client, _)| client.health(id).map_err(|error| error.to_string()))
            .unwrap_or_else(|detail| json!({"status": "unreachable", "detail": detail}))
    } else {
        json!({"status": "socket_absent"})
    };
    ServiceAnswer::emit(json!({"daemonService": status.document, "daemonHealth": health}))
}

/// `runtime service verify`: the installed identity and the state root and,
/// when a daemon runs, that it proves the installed identity and answers
/// `health`. Nothing is started; `runtime` is `null` when no daemon runs.
pub fn verify_leaf(
    target: &ServiceTarget,
    id: &str,
    options: &Map<String, Value>,
) -> ServiceAnswer {
    if let Some(option) = ["jobId", "targetId", "executionId", "maximumWaitSeconds"]
        .into_iter()
        .find(|key| options.contains_key(*key))
    {
        return ServiceAnswer {
            refusal: Some(CodedFailure {
                code: "unsupportedOnPlatform",
                message: format!(
                    "runtime service verify {} is not served on Windows yet: it verifies the \
                     installed daemon and its state root",
                    match option {
                        "jobId" => "--job",
                        "targetId" => "--target",
                        "executionId" => "--execution-id",
                        _ => "--maximum-wait-seconds",
                    }
                ),
                details: Map::new(),
            }),
            ..ServiceAnswer::default()
        };
    }
    let status = inspect(target);
    if !status.ready {
        return ServiceAnswer::emit_then_fail(
            json!({"daemonService": status.document, "runtime": null, "runtimeVerified": false}),
            PlainFailure::new(
                69,
                format!(
                    "daemon service is not ready: {}",
                    status.diagnostics.join("; ")
                ),
            ),
        );
    }
    if !status.socket_present {
        return ServiceAnswer::emit(
            json!({"daemonService": status.document, "runtime": null, "runtimeVerified": true}),
        );
    }
    let proved = connect(target).and_then(|(mut client, pid)| {
        client
            .health(id)
            .map(|health| (pid, health))
            .map_err(|error| error.to_string())
    });
    match proved {
        Ok((pid, health)) => ServiceAnswer::emit(json!({
            "daemonService": status.document,
            "runtime": {"pid": pid, "identityVerified": true, "daemonHealth": health},
            "runtimeVerified": true,
        })),
        Err(detail) => ServiceAnswer::emit_then_fail(
            json!({"daemonService": status.document,
                "runtime": {"identityVerified": false, "detail": detail},
                "runtimeVerified": false}),
            PlainFailure::new(69, detail),
        ),
    }
}

/// How the predecessor let its single-instance guard go.
enum Drain {
    Complete,
    /// Its drain deadline elapsed and it exited holding the guard; the guard
    /// is left abandoned again for the successor.
    DeadlineElapsed,
}

/// Waits at most `wait` for the scope's single-instance guard on a thread of
/// its own; `None` if it is still held then. A guard found abandoned is left
/// abandoned: the thread ends holding it, and its handle stays open for the
/// life of this process, so the successor this process starts sees it.
fn await_guard(
    scope: &arkdeck_platform::InstanceScope,
    wait: Duration,
) -> Result<Option<Drain>, String> {
    let guard = GuardObject::open(scope).map_err(|error| error.to_string())?;
    std::thread::scope(|threads| {
        threads
            .spawn(move || match guard.acquire(wait) {
                Ok(GuardAcquisition::Held) => Ok(None),
                Ok(GuardAcquisition::Owned {
                    guard,
                    abandoned: false,
                }) => {
                    drop(guard);
                    Ok(Some(Drain::Complete))
                }
                Ok(GuardAcquisition::Owned {
                    guard,
                    abandoned: true,
                }) => {
                    std::mem::forget(guard);
                    Ok(Some(Drain::DeadlineElapsed))
                }
                Err(error) => Err(error.to_string()),
            })
            .join()
            .unwrap_or_else(|_| Err("the guard wait ended abnormally".into()))
    })
}

/// `runtime service restart`: maintenance, never a way to interrupt a Job,
/// with the macOS leaf's refusals; see the module's documentation.
pub fn restart_leaf(
    target: &ServiceTarget,
    id: &str,
    maximum_wait_seconds: Option<u64>,
) -> ServiceAnswer {
    let maximum_wait_seconds = maximum_wait_seconds.unwrap_or(30);
    if !(1..=300).contains(&maximum_wait_seconds) {
        return ServiceAnswer::fail(PlainFailure::new(
            64,
            "runtime service restart --maximum-wait-seconds must be between 1 and 300",
        ));
    }
    let wait = Duration::from_secs(maximum_wait_seconds);
    let run = || -> Result<Value, PlainFailure> {
        let before = inspect(target);
        if !before.ready {
            return Err(PlainFailure::new(
                69,
                format!(
                    "daemon service is not ready: {}",
                    before.diagnostics.join("; ")
                ),
            ));
        }
        if !before.socket_present {
            return Err(PlainFailure::new(
                69,
                format!(
                    "no daemon serves {}; nothing was stopped or started (any command that needs \
                     the Runtime starts it)",
                    before.socket_path
                ),
            ));
        }
        let (mut client, pid_before) =
            connect(target).map_err(|detail| PlainFailure::new(69, detail))?;
        let health = client
            .health(id)
            .map_err(|error| PlainFailure::new(1, error.to_string()))?;
        let digest_before = health_catalog_digest(&health)?;
        let instance_before = before
            .instance
            .clone()
            .filter(|instance| instance["pid"] == json!(pid_before))
            .ok_or_else(|| {
                PlainFailure::new(
                    69,
                    format!(
                        "the state root's instance document does not name the daemon serving \
                         the pipe (pid {pid_before})"
                    ),
                )
            })?;
        let jobs_before = job_preflight(&mut client, id)?;
        if let Some(jobs) = &jobs_before
            && !jobs.blocking_job_ids.is_empty()
        {
            return Err(PlainFailure::new(
                75,
                format!(
                    "runtime service restart refused while Runtime Jobs are active or unclosed: {}",
                    jobs.blocking_job_ids.join(", ")
                ),
            ));
        }
        drop(client);
        let deadline = Instant::now() + wait;
        target
            .start
            .scope
            .request_stop(pid_before)
            .map_err(|error| {
                PlainFailure::new(
                    69,
                    format!("the daemon (pid {pid_before}) could not be asked to stop: {error}"),
                )
            })?;
        let drain = await_guard(&target.start.scope, wait)
            .map_err(|detail| {
                PlainFailure::new(
                    69,
                    format!("the daemon's single-instance guard is unusable: {detail}"),
                )
            })?
            .ok_or_else(|| {
                PlainFailure::new(
                    69,
                    format!(
                        "the daemon (pid {pid_before}) did not release its single-instance guard \
                         within {maximum_wait_seconds}s of its stop request; nothing was started"
                    ),
                )
            })?;
        let remaining = deadline
            .checked_duration_since(Instant::now())
            .filter(|left| !left.is_zero())
            .unwrap_or(Duration::from_millis(1));
        let started = ensure_running(&target.start, remaining).map_err(|failure| {
            PlainFailure::new(
                69,
                format!(
                    "replacement daemon did not become ready within {maximum_wait_seconds}s: {}",
                    failure.message
                ),
            )
        })?;
        let (mut client, pid_after) =
            connect(target).map_err(|detail| PlainFailure::new(69, detail))?;
        if pid_after == pid_before {
            return Err(PlainFailure::new(69, "daemon instance PID has not changed"));
        }
        let health_after = client
            .health(id)
            .map_err(|error| PlainFailure::new(1, error.to_string()))?;
        let digest_after = health_catalog_digest(&health_after)?;
        if digest_after != digest_before {
            return Err(PlainFailure::new(
                69,
                "daemon catalog changed across a configuration-preserving restart",
            ));
        }
        let jobs_after = job_preflight(&mut client, id)?;
        let closed = |jobs: &Option<arkdeck_contract::RestartPreflight>| {
            jobs.as_ref()
                .map(|jobs| jobs.preserved_unknown_job_ids.clone())
        };
        if jobs_after
            .as_ref()
            .is_some_and(|jobs| !jobs.blocking_job_ids.is_empty())
            || closed(&jobs_after) != closed(&jobs_before)
        {
            return Err(PlainFailure::new(
                69,
                "Runtime current Job closure changed across daemon restart",
            ));
        }
        let after = inspect(target);
        let instance_after = after
            .instance
            .clone()
            .filter(|instance| instance["pid"] == json!(pid_after))
            .ok_or_else(|| {
                PlainFailure::new(
                    69,
                    format!(
                        "the state root's instance document does not name the replacement \
                         daemon (pid {pid_after})"
                    ),
                )
            })?;
        Ok(json!({
            "restart": {
                "schemaVersion": RESTART_SCHEMA,
                "stoppedPid": pid_before,
                "stopRequest": "stopEvent",
                "drain": match drain {
                    Drain::Complete => "complete",
                    Drain::DeadlineElapsed => "deadlineElapsed",
                },
                "start": started.outcome(),
                "startedPid": match started {
                    Started::Launched { pid } => json!(pid),
                    _ => Value::Null,
                },
            },
            "restartProof": {
                "schemaVersion": RESTART_PROOF_SCHEMA,
                "beforeInstance": instance_before,
                "afterInstance": instance_after,
                "catalogDigestBefore": digest_before,
                "catalogDigestAfter": digest_after,
                "blockingJobCountBefore": 0,
                "preservedUnknownJobIds": closed(&jobs_before).unwrap_or_default(),
                "jobOwner": jobs_before.is_some(),
            },
            "daemonService": after.document,
            "daemonHealth": health_after,
        }))
    };
    match run() {
        Ok(document) => ServiceAnswer::emit(document),
        Err(failure) => ServiceAnswer::fail(failure),
    }
}

/// The Windows service leaves; the others are macOS-only.
pub fn run(invocation: &Invocation, id: &str) -> ServiceAnswer {
    let empty = Map::new();
    let options = invocation.params.as_ref().unwrap_or(&empty);
    if !matches!(
        invocation.command,
        "runtime.service.status" | "runtime.service.verify" | "runtime.service.restart"
    ) {
        return ServiceAnswer {
            refusal: Some(CodedFailure {
                code: "unsupportedOnPlatform",
                message: "the runtime service is the macOS user-domain LaunchAgent".into(),
                details: Map::new(),
            }),
            ..ServiceAnswer::default()
        };
    }
    let target = match ServiceTarget::from_environment() {
        Ok(target) => target,
        Err(failure) => return ServiceAnswer::fail(failure),
    };
    match invocation.command {
        "runtime.service.status" => status_leaf(&target, id),
        "runtime.service.verify" => verify_leaf(&target, id, options),
        _ => restart_leaf(
            &target,
            id,
            options
                .get("maximumWaitSeconds")
                .and_then(Value::as_str)
                .and_then(|raw| raw.parse().ok()),
        ),
    }
}
