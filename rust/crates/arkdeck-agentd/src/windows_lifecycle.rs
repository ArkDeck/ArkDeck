//! The Windows daemon's lifecycle (TASK-XPA-002 S5): which state root it
//! owns, how it becomes the one daemon of that root, what asks it to stop,
//! and what it lets go of once it has drained. The platform decision is in
//! `rust/README.md` (the Windows paragraph) and the S5 run record.
//!
//! Three compositions, decided from the environment before anything is
//! opened:
//!
//! * the account's daemon (no input): `%LOCALAPPDATA%\ArkDeck\Agentd`, its
//!   `instance.lock`, the guard `Local\ArkDeck.Agentd.<user SID>` and the
//!   logon-scoped pipe `\\.\pipe\arkdeck-agentd-<logon SID>`. This is the
//!   daemon decision 11's client starts (`arkdeck_client::start`);
//! * an isolated development root (`ARKDECK_DEVELOPMENT_STATE_ROOT`, an
//!   existing directory outside `%LOCALAPPDATA%\ArkDeck`): its `.owner.lock`,
//!   a guard and a pipe named after the root's file identity. Beside the
//!   lifecycle only the Job store, the Target owners, the Artifact read and
//!   export owner, the workspace project owner and (in a development root)
//!   the Trace cache owner are composed over it (see
//!   [`Authority::compose`]); every input that would compose another owner
//!   on macOS is refused, not ignored, until its store is ported (G01);
//! * a private endpoint (`ARKDECK_ENDPOINT` alone): the read-only foundation
//!   over a pipe the caller names, owning no state root, as the Unix
//!   standalone daemon does (the black-box read-only check runs it).
//!
//! A daemon that owns a root takes, in this order and before anything else
//! is created or probed: the single-instance guard, the owner lock, its
//! named stop event and the pipe (`FILE_FLAG_FIRST_PIPE_INSTANCE`). Then it
//! reads the instance document its predecessor left — the state a restart
//! reads back — and replaces it with its own. A guard or owner lock another
//! daemon holds is answered as Swift's second instance answers: `already
//! running` from that daemon's instance document, exit 0, having composed
//! nothing. A guard its holder died with (`WAIT_ABANDONED`) is taken, named,
//! and the start goes on as the start after a crash that every start already
//! is: nothing is replayed.
//!
//! It stops for its named stop event ([`arkdeck_platform::InstanceScope::request_stop`],
//! SIGTERM's counterpart) or a console Ctrl+C / Ctrl+Break (SIGINT's), and
//! drains as the Unix daemon does (`serve_control`). After a complete drain
//! it releases the owner lock, then the guard, on the thread that took it;
//! after one its deadline cut short it exits holding them, so its successor
//! finds the guard abandoned and starts as after a crash.
use arkdeck_platform::{
    GuardAcquisition, LocalEndpoint, LocalListener, OwnerLock, SingleInstanceGuard, StateRoot,
    StopSignal,
};
use std::ffi::OsStr;
use std::io::Write;
use std::path::Path;
use std::time::Duration;

/// Swift `AgentDaemonServer`'s instance document, the name and shape the
/// macOS composition writes (`production.rs`).
const INSTANCE_DOCUMENT: &str = "instance.json";
const DOCUMENT_LIMIT: u64 = 64 * 1024;

/// Inputs from which the isolated macOS owner composes an owner that this
/// composition does not compose yet: each one set refuses the start.
const NOT_COMPOSED: [&str; 10] = [
    "ARKDECK_DEVELOPMENT_HDC_PATH",
    "ARKDECK_DEVELOPMENT_HDC_SERVER",
    "ARKDECK_DEVELOPMENT_USB_RELATIONS",
    "ARKDECK_DEVELOPMENT_USB_RELATIONS_WITH_REGISTERED_HDC",
    "ARKDECK_DEVELOPMENT_CODE_SIGN_HELPER",
    "ARKDECK_DEVELOPMENT_MUTATION_AUTHORITY",
    "ARKDECK_APP_INGRESS",
    "ARKDECK_ANALYZER_PATH",
    "ARKDECK_ARKTRACE_DESCRIPTOR",
    "ARKDECK_WORKSPACE_INSPECTOR",
];

/// Swift `AgentDaemonInstance`: who holds the instance lock. The same
/// document as `production::Instance`, byte for byte.
#[derive(Clone, Debug, PartialEq, Eq, serde::Deserialize, serde::Serialize)]
pub(crate) struct Instance {
    pub(crate) pid: i32,
    #[serde(rename = "protocolVersion")]
    pub(crate) protocol_version: String,
    #[serde(rename = "socketPath")]
    pub(crate) socket_path: String,
    #[serde(rename = "startedAtUTC")]
    pub(crate) started_at_utc: String,
}

impl Instance {
    /// Swift's second instance's line (`main.swift` 1590-1592).
    pub(crate) fn running(&self) -> String {
        format!(
            "arkdeck-agentd already running: pid {}, socket {}, protocol {}",
            self.pid, self.socket_path, self.protocol_version
        )
    }
}

/// What a daemon owning a state root holds while it serves.
pub(crate) struct Authority {
    pub(crate) endpoint: LocalEndpoint,
    /// An isolated development root, whose owners keep the macOS isolated
    /// owner's directory names; otherwise the account's root, whose owners
    /// keep Swift's production layout.
    development: bool,
    // Dropped in this order: the owner lock, then the guard, then the root's
    // pinned directories.
    owner: OwnerLock,
    guard: SingleInstanceGuard,
    root: StateRoot,
}

impl Authority {
    /// The owners a Windows daemon composes over its root, as the macOS
    /// isolated owner (`targets-state`) or production composition
    /// (`targets`) composes them, in a private child of the root created
    /// owner-only when absent (`StateRoot::private_child`):
    ///
    /// * the Job store (`jobs-state`, [`Self::job_store`]);
    /// * the Target store: `targets.json` and the display names under
    ///   `.targets.lock` and `.target-display-names.lock`, the same bytes
    ///   as on macOS; `target.list`, `target.show`, `target.availability`
    ///   and `target.display-name.*` answer from it, and a restart reads
    ///   back what it holds;
    /// * the Target observation owner over it, with the USB relations the
    ///   macOS rule names (`development_usb::relation_source`): the
    ///   Runtime's own census (`UsbRegistryRelations::system()`, the Windows
    ///   SetupAPI census) only beside a registered HDC this composition
    ///   started as its managed server. No Windows HDC tuple is registered
    ///   yet (its integration change waits for the maintainer's samples),
    ///   so no relation is read, nothing is observed or dispatched, and
    ///   `target.adopt` is refused before admission with zero dispatch;
    /// * the Artifact read and export owner (`ArtifactReadStore`) over the
    ///   root's `artifacts` (the name the macOS isolated owner and production
    ///   composition both give it): the same Job index documents, payloads
    ///   and `artifact.list` snapshot pages as on macOS. Every Artifact
    ///   belongs to a Job, which the Job store above proves before anything
    ///   is read, listed or exported;
    /// * the workspace project owner (`WorkspaceProjectStore`) in
    ///   `workspace-projects`, the name both macOS compositions give it:
    ///   `projects.json` under `.projects.lock`, the same document as on
    ///   macOS, a Windows root pinned by its volume serial and NTFS file
    ///   reference. `workspace.project.register|list|show` and
    ///   `workspace.preset.list|show` answer from it, and a restart reads
    ///   back what it holds. The installed daemon (not the development
    ///   root) pins a preset's signing credential in the account's preset
    ///   root `<LocalAppData>\ArkDeck\Signing\OpenHarmony`, the secrets read
    ///   from Credential Manager bound to this daemon's own image
    ///   (TASK-XPA-011), as the macOS installed daemon does. Neither the
    ///   DevEco toolchain owner nor the workspace composition is composed, so
    ///   a project stays `runtimeRestartRequired`; this composition does not
    ///   yet ask the Job owner whether a workspace Job names a project or
    ///   preset, so every project or preset mutation is refused
    ///   (`recordUnreadable`, no new dispatch);
    /// * in a development root only, the Trace cache owner
    ///   (`TraceCacheStore`) over `trace-cache\traces`, beside its `staging`,
    ///   the layout the macOS isolated owner creates: `trace.cache.status`
    ///   reads the same inventory as on macOS. `trace.cache.purge` is
    ///   refused before admission (`operationUnavailable`, ruling 18), as the
    ///   macOS daemon refuses it without its retention owners: the Job
    ///   owner's active-Session census, which alone proves that no Job's
    ///   Session still needs the derived data, is not asked on Windows yet.
    ///   The account's daemon composes none: on macOS it reads the App's
    ///   cache in the App's container, and the Windows App's cache location
    ///   is not decided yet.
    ///
    /// An existing owner directory is never re-permissioned; one that is not
    /// owner-only is refused when its owner opens it. Composing opens the
    /// stores, which read their documents under their locks; a store it
    /// cannot open or read ends the start, as on macOS.
    pub(crate) fn compose(&self, host: crate::host::Host) -> Result<crate::host::Host, String> {
        use crate::development_usb::{RelationSource, relation_source};
        let host = host.with_jobs(self.job_store()?);
        let name = if self.development {
            "targets-state"
        } else {
            "targets"
        };
        let path = self.root.private_child(name).map_err(|error| {
            format!(
                "the Target store {} is unusable: {error}; nothing was started",
                self.root.path().join(name).display()
            )
        })?;
        let targets = arkdeck_hoststore::TargetStore::open(&path).map_err(|error| {
            format!(
                "the Target store {} is unusable: {error}; nothing was started",
                path.display()
            )
        })?;
        let host = host.with_targets(targets);
        let name = "artifacts";
        let path = self.root.private_child(name).map_err(|error| {
            format!(
                "the Artifact store {} is unusable: {error}; nothing was started",
                self.root.path().join(name).display()
            )
        })?;
        let artifacts = arkdeck_hoststore::ArtifactReadStore::open(&path).map_err(|error| {
            format!(
                "the Artifact store {} is unusable: {error}; nothing was started",
                path.display()
            )
        })?;
        let host = host.with_artifacts(artifacts);
        let name = "workspace-projects";
        let unusable = |path: &Path, error: &dyn std::fmt::Display| {
            format!(
                "the workspace project store {} is unusable: {error}; nothing was started",
                path.display()
            )
        };
        let path = self
            .root
            .private_child(name)
            .map_err(|error| unusable(&self.root.path().join(name), &error))?;
        let projects = arkdeck_hoststore::WorkspaceProjectStore::open(&path)
            .map_err(|error| unusable(&path, &error))?;
        let projects = if self.development {
            projects
        } else {
            projects.with_dependency_pinning(None, Some(credential_pinning()?))
        };
        // Read now, as the macOS start reads it to compose the registered
        // projects: a document it cannot read ends the start.
        projects
            .startup_records()
            .map_err(|error| unusable(&path, &error.message))?;
        let host = host.with_workspace_projects(projects);
        let host = if self.development {
            let name = "trace-cache";
            let unusable = |path: &Path, error: std::io::Error| {
                format!(
                    "the Trace cache {} is unusable: {error}; nothing was started",
                    path.display()
                )
            };
            let parent = self
                .root
                .private_child(name)
                .map_err(|error| unusable(&self.root.path().join(name), error))?;
            let directory = arkdeck_platform::HostDirectory::open(&parent)
                .map_err(|error| unusable(&parent, error))?;
            for child in ["traces", "staging"] {
                directory
                    .private_child(child)
                    .map_err(|error| unusable(&parent.join(child), error))?;
            }
            let traces = parent.join("traces");
            let cache = arkdeck_hoststore::TraceCacheStore::open(&traces)
                .map_err(|error| unusable(&traces, error))?;
            host.with_trace_cache(cache)
        } else {
            host
        };
        // No Windows HDC is registered, so none is managed either.
        let (registered, managed) = (false, false);
        let host = match relation_source(registered, managed, false) {
            RelationSource::Registry => host
                .with_usb_registry_relations(arkdeck_provider_hdc::UsbRegistryRelations::system()),
            RelationSource::File | RelationSource::Nothing => host,
        };
        report(
            "arkdeck-agentd composes no HDC: no Windows HDC tuple is registered; device \
             observation and target adoption are refused before any dispatch",
        );
        report(&format!(
            "arkdeck-agentd owners: {}",
            host.owner_census().join(", ")
        ));
        Ok(host)
    }

    /// The Job store owner over its private child of the root (created
    /// owner-only when absent, an existing one opened as it is, never
    /// re-permissioned): `runtime-jobs.sqlite3` under `.rust-job-owner.lock`,
    /// `jobs/<id>/job-record.json` and `jobs/<id>/journal.jsonl`, as the macOS
    /// isolated owner keeps them in `jobs-state`. The account's root keeps it
    /// in the same private child rather than beside its other entries (as
    /// Swift's production daemon does): the host store cannot open the
    /// account root itself, whose DACL also grants SYSTEM. `job.status`,
    /// `job.show`, `job.events` and a `job.list` of one page answer from it
    /// (so `runtime service restart` reads the current Jobs), and a restart
    /// reads back what it holds; nothing admits a Job on Windows yet. Opening validates
    /// the index's layout and rows and its files' owner and identity; a
    /// store it cannot open ends the start.
    fn job_store(&self) -> Result<arkdeck_hoststore::JobStore, String> {
        const NAME: &str = "jobs-state";
        let path = self.root.private_child(NAME).map_err(|error| {
            format!(
                "the Job store {} is unusable: {error}; nothing was started",
                self.root.path().join(NAME).display()
            )
        })?;
        arkdeck_hoststore::JobStore::open_owner(&path).map_err(|error| {
            format!(
                "the Job store {} is unusable: {error}; nothing was started",
                path.display()
            )
        })
    }

    /// After a complete drain: the owner lock, then the guard, on the thread
    /// that took the guard.
    pub(crate) fn release(self) {
        let Self {
            owner, guard, root, ..
        } = self;
        drop(owner);
        drop(guard);
        drop(root);
    }
}

/// What serves.
pub(crate) struct Serving {
    pub(crate) stop: StopSignal,
    pub(crate) listener: LocalListener,
    pub(crate) authority: Option<Authority>,
}

pub(crate) enum Start {
    Serve(Serving),
    /// Another daemon owns the root; its instance document names it.
    AlreadyRunning(Instance),
}

fn report(line: &str) {
    println!("{line}");
    let _ = std::io::stdout().flush();
}

/// The instance document a daemon of this root left, if one decodes.
fn read_instance(root: &StateRoot) -> Option<Instance> {
    let bytes = root
        .read_document(INSTANCE_DOCUMENT, DOCUMENT_LIMIT)
        .ok()??;
    serde_json::from_slice(&bytes).ok()
}

fn already_running(root: &StateRoot) -> Result<Start, String> {
    match read_instance(root) {
        Some(instance) => Ok(Start::AlreadyRunning(instance)),
        None => Err(format!(
            "another Runtime holds the state root {} but left no instance document; nothing \
             was started",
            root.path().display()
        )),
    }
}

/// Decides the composition and, for one that owns a state root, takes it
/// (see the module's documentation).
pub(crate) fn start(
    development: Option<&OsStr>,
    endpoint: Option<&OsStr>,
    started_at_utc: &str,
    is_set: &dyn Fn(&str) -> bool,
) -> Result<Start, String> {
    if let (None, Some(endpoint)) = (development, endpoint) {
        let stop = StopSignal::install(None).map_err(|error| error.to_string())?;
        let listener = LocalListener::bind(&LocalEndpoint::new(endpoint))
            .map_err(|error| error.to_string())?;
        return Ok(Start::Serve(Serving {
            stop,
            listener,
            authority: None,
        }));
    }
    if development.is_some()
        && let Some(input) = NOT_COMPOSED.iter().find(|name| is_set(name))
    {
        return Err(format!(
            "{input} is not composed by the Windows development root yet; nothing was started"
        ));
    }
    let root = match development {
        Some(root) => StateRoot::development(Path::new(root)),
        None => StateRoot::account(),
    }
    .map_err(|error| format!("the daemon state root is unusable: {error}"))?;
    let unusable = |what: &str, error: std::io::Error| {
        format!("{what} of {} is unusable: {error}", root.path().display())
    };
    let scope = root
        .scope()
        .map_err(|error| unusable("the instance scope", error))?;
    let expected = root
        .endpoint()
        .map_err(|error| unusable("the endpoint", error))?;
    if let Some(endpoint) = endpoint
        && Path::new(endpoint) != expected.as_path()
    {
        return Err(format!(
            "a development root's endpoint is named after the root: {}",
            expected.as_path().display()
        ));
    }
    let (guard, abandoned) = match SingleInstanceGuard::acquire(&scope, Duration::ZERO)
        .map_err(|error| unusable("the single-instance guard", error))?
    {
        GuardAcquisition::Owned { guard, abandoned } => (guard, abandoned),
        GuardAcquisition::Held => return already_running(&root),
    };
    let Some(owner) = root
        .lock_owner()
        .map_err(|error| unusable("the owner lock", error))?
    else {
        return already_running(&root);
    };
    if abandoned {
        report(
            "arkdeck-agentd: the previous daemon of this state root ended holding its \
             single-instance guard; starting as after a crash",
        );
    }
    let stop =
        StopSignal::install(Some(&scope)).map_err(|error| unusable("the stop event", error))?;
    let listener = LocalListener::bind(&expected).map_err(|error| {
        format!(
            "the endpoint {} is not this Runtime's: {error}; nothing was started",
            expected.as_path().display()
        )
    })?;
    // The state a restart reads back: what its predecessor left.
    if let Some(previous) = read_instance(&root) {
        report(&format!(
            "arkdeck-agentd previous instance: pid {}, started {}",
            previous.pid, previous.started_at_utc
        ));
    }
    let document = Instance {
        pid: i32::try_from(std::process::id()).map_err(|_| "the process id is unrepresentable")?,
        protocol_version: arkdeck_contract::PROTOCOL_VERSION.into(),
        socket_path: expected.as_path().to_string_lossy().into_owned(),
        started_at_utc: started_at_utc.into(),
    };
    let bytes = serde_json::to_vec(&document).map_err(|error| error.to_string())?;
    root.publish_document(INSTANCE_DOCUMENT, &bytes)
        .map_err(|error| unusable("the instance document", error))?;
    report(&format!(
        "arkdeck-agentd state root {}",
        root.path().display()
    ));
    Ok(Start::Serve(Serving {
        stop,
        listener,
        authority: Some(Authority {
            endpoint: expected,
            development: development.is_some(),
            owner,
            guard,
            root,
        }),
    }))
}

/// The installed daemon's credential pinning: the account's signing preset
/// root and the Credential Manager secrets bound to this process's own image,
/// in its canonical `X:\…` spelling (the spelling a receipt's identity is
/// computed over).
fn credential_pinning() -> Result<arkdeck_hoststore::WorkspaceCredentialPinning, String> {
    let root = arkdeck_platform::arkdeck_application_support_root()
        .ok_or("this account has no local application data for the signing preset")?
        .join("Signing")
        .join("OpenHarmony");
    let image = std::env::current_exe()
        .and_then(|image| image.canonicalize())
        .map_err(|error| format!("this daemon's image cannot be named: {error}"))?;
    let image = image
        .to_str()
        .ok_or("this daemon's image path is not text")?;
    let image = std::path::PathBuf::from(image.strip_prefix(r"\\?\").unwrap_or(image));
    arkdeck_hoststore::keychain_credential_pinning(root, image)
        .map_err(|error| format!("the signing credential store is unusable: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_instance_document_keeps_swift_s_shape() {
        let instance = Instance {
            pid: 7,
            protocol_version: "p".into(),
            socket_path: r"\\.\pipe\arkdeck-agentd-x".into(),
            started_at_utc: "t".into(),
        };
        assert_eq!(
            serde_json::to_string(&instance).unwrap(),
            r#"{"pid":7,"protocolVersion":"p","socketPath":"\\\\.\\pipe\\arkdeck-agentd-x","startedAtUTC":"t"}"#
        );
        assert_eq!(
            instance.running(),
            r"arkdeck-agentd already running: pid 7, socket \\.\pipe\arkdeck-agentd-x, protocol p"
        );
    }

    #[test]
    fn a_development_root_refuses_an_input_it_does_not_compose() {
        for input in NOT_COMPOSED {
            let refused = start(Some(OsStr::new(r"C:\unused")), None, "t", &|name| {
                name == input
            });
            assert!(
                matches!(&refused, Err(message) if message.starts_with(input)),
                "{input}"
            );
        }
    }
}
