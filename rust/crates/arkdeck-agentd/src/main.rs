#[cfg(target_os = "macos")]
mod bootstrap_readers;
#[cfg(target_os = "macos")]
mod facade;
#[cfg(target_os = "macos")]
mod facade_owners;
mod host;

use arkdeck_contract::MAX_REQUEST_BYTES;
use arkdeck_control::Control;
use arkdeck_platform::{LocalEndpoint, LocalListener, default_user_endpoint, read_frame};
use std::io::{self, BufReader, Write};
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};
use std::time::Duration;

/// The isolated owner's development HDC, named by
/// `ARKDECK_DEVELOPMENT_HDC_PATH` and pinned by the digest of its bytes at
/// startup. It must be a fixture: a registered HDC executable would address a
/// real server and device, which needs the existing-server identity proof the
/// isolated owner does not have, so one is refused.
#[cfg(target_os = "macos")]
fn development_hdc()
-> Result<Option<arkdeck_provider_hdc::FixtureDispatch>, Box<dyn std::error::Error>> {
    let Some(path) = std::env::var_os("ARKDECK_DEVELOPMENT_HDC_PATH") else {
        return Ok(None);
    };
    let path = std::path::PathBuf::from(path);
    if !path.is_absolute() {
        return Err("ARKDECK_DEVELOPMENT_HDC_PATH must be an explicit absolute path".into());
    }
    let digest = arkdeck_contract::sha256_hex(&std::fs::read(&path)?);
    let registered = arkdeck_platform::VerifiedTool::open(&path, &digest)?;
    if arkdeck_provider_hdc::HdcReadOnlyProvider::new(registered).is_ok() {
        return Err(
            "the isolated Rust development owner runs a fixture HDC only; a registered HDC \
             needs the existing-server identity proof"
                .into(),
        );
    }
    Ok(Some(arkdeck_provider_hdc::FixtureDispatch::new(
        arkdeck_platform::VerifiedTool::open(&path, &digest)?,
    )))
}

fn serve() -> Result<(), Box<dyn std::error::Error>> {
    let development = std::env::var_os("ARKDECK_DEVELOPMENT_STATE_ROOT");
    #[cfg(target_os = "macos")]
    let mut development_listener = None;
    if development.is_some()
        && [
            "ARKDECK_SWIFT_DAEMON",
            "ARKDECK_HDC_PATH",
            "ARKDECK_HDC_SHA256",
        ]
        .iter()
        .any(|key| std::env::var_os(key).is_some())
    {
        return Err(
            "the isolated Rust development owner cannot pair a Swift daemon or configure HDC"
                .into(),
        );
    }
    if development.is_none() && std::env::var_os("ARKDECK_DEVELOPMENT_HDC_PATH").is_some() {
        return Err("a development HDC is configured only for an isolated development root".into());
    }
    #[cfg(target_os = "macos")]
    if development.is_none()
        && let Some(swift) = facade::swift_executable()
    {
        return facade::serve(swift);
    }
    if std::env::args_os().len() != 1 {
        return Err("arkdeck-agentd takes no device, command, path or authority arguments; configure the local host environment".into());
    }
    let endpoint = match std::env::var_os("ARKDECK_ENDPOINT") {
        Some(path) => LocalEndpoint::new(path),
        None => default_user_endpoint()?,
    };
    let host = host::Host::from_environment();
    #[cfg(target_os = "macos")]
    let host = if let Some(root) = development {
        let root = std::path::PathBuf::from(root);
        // LocalListener already authenticates the same-user peer. Require a
        // separate socket beside the explicit development document, never the
        // installed service endpoint or a caller-provided request path.
        if endpoint.as_path().parent() != Some(root.as_path()) {
            return Err("development endpoint must be directly inside its state root".into());
        }
        let installed =
            std::path::PathBuf::from(std::env::var_os("HOME").ok_or("HOME unavailable")?)
                .join("Library/Application Support/ArkDeck");
        if root.starts_with(&installed) {
            return Err("development state must be separate from installed ArkDeck state".into());
        }
        let directory = arkdeck_platform::HostDirectory::open(&root)?;
        // Own the whole development root before creating or probing any store.
        // A second daemon must not perturb a live owner's census on startup.
        development_listener = Some(LocalListener::bind_facade(&endpoint)?);
        for name in [
            "session-state",
            "sessions",
            "artifacts",
            "trace-cache",
            "bootstrap",
            "jobs-state",
            "targets-state",
            "agent-executions",
        ] {
            directory.private_child(name)?;
        }
        directory.validate_path(&root)?;
        let artifacts = root.join("artifacts");
        let trace_parent = directory.child("trace-cache")?;
        trace_parent.private_child("traces")?;
        trace_parent.private_child("staging")?;
        let trace_cache = root.join("trace-cache/traces");
        let bootstrap = root.join("bootstrap");
        let sessions = arkdeck_hoststore::SessionStore::open(
            &root.join("session-state"),
            &root.join("sessions"),
        )?
        .isolated(
            &root,
            vec![
                artifacts.clone(),
                root.join("trace-cache"),
                bootstrap.clone(),
                root.join("jobs-state"),
                root.join("targets-state"),
                root.join("agent-executions"),
            ],
        )?;
        host.with_targets(arkdeck_hoststore::TargetStore::open(
            &root.join("targets-state"),
        )?)
        .with_history(arkdeck_hoststore::HistoryStore::open(&root)?)
        .with_imports(arkdeck_hoststore::ImportUploadStore::open(&artifacts)?)
        .with_artifacts(arkdeck_hoststore::ArtifactReadStore::open(&artifacts)?)
        .with_trace_cache(arkdeck_hoststore::TraceCacheStore::open(&trace_cache)?)
        .with_storage(
            sessions,
            arkdeck_hoststore::ArtifactUsage::open(&artifacts, host::ARTIFACT_QUOTA)?,
        )
        .with_bootstrap(&bootstrap)?
        // The isolated owner admits Jobs, so it holds the Job owner connection.
        .with_jobs(arkdeck_hoststore::JobStore::open_owner(
            &root.join("jobs-state"),
        )?)
        // Beside the Job state, as the Swift daemon keeps its agent
        // executions; each owns a Job of this owner.
        .with_agent_executions(arkdeck_hoststore::AgentExecutionStore::open(
            &root.join("agent-executions"),
        )?)
        // Beside the Job state, as the Swift engine keeps it: read only.
        .with_capabilities(arkdeck_hoststore::CapabilityStore::open(
            &root.join("jobs-state").join("capabilities"),
        )?)
        // As the Swift daemon: an analyzer is configured only by naming its
        // executable, and a named path that is not one fails startup.
        .with_planning(
            &root,
            std::env::var_os("ARKDECK_ANALYZER_PATH")
                .map(|path| {
                    arkdeck_hoststore::AnalyzerProfile::crash_signature(std::path::Path::new(&path))
                })
                .transpose()?,
        )
        .with_development_hdc(development_hdc()?)
    } else {
        host
    };
    #[cfg(not(target_os = "macos"))]
    if development.is_some() {
        return Err("development host-store owner is not yet supported on this platform".into());
    }
    let control = Arc::new(Control::new(host)?);
    #[cfg(target_os = "macos")]
    let mut listener = if let Some(listener) = development_listener {
        listener
    } else {
        LocalListener::bind(&endpoint)?
    };
    #[cfg(not(target_os = "macos"))]
    let mut listener = LocalListener::bind(&endpoint)?;
    let active = Arc::new(AtomicUsize::new(0));
    loop {
        let connection = match listener.accept() {
            Ok(connection) => connection,
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::Interrupted | io::ErrorKind::PermissionDenied
                ) =>
            {
                continue;
            }
            Err(error) => return Err(error.into()),
        };
        if active.fetch_add(1, Ordering::AcqRel) >= 16 {
            active.fetch_sub(1, Ordering::AcqRel);
            continue;
        }
        let control = Arc::clone(&control);
        let active = Arc::clone(&active);
        std::thread::spawn(move || {
            struct Active(Arc<AtomicUsize>);
            impl Drop for Active {
                fn drop(&mut self) {
                    self.0.fetch_sub(1, Ordering::AcqRel);
                }
            }
            let _active = Active(active);
            if connection
                .set_read_timeout(Some(Duration::from_secs(20)))
                .is_err()
                || connection
                    .set_write_timeout(Some(Duration::from_secs(20)))
                    .is_err()
            {
                return;
            }
            let mut reader = BufReader::new(connection);
            // Bound a connection's work without rejecting the required health
            // followed by business exchange. A new connection reauthenticates.
            for _ in 0..128 {
                let frame = match read_frame(&mut reader, MAX_REQUEST_BYTES) {
                    Ok(frame) => frame,
                    Err(error) if error.kind() == io::ErrorKind::InvalidData => {
                        let _ = reader.get_mut().write_all(&control.handle_frame(&[]));
                        return;
                    }
                    Err(_) => return,
                };
                let reply = control.handle_frame(&frame);
                if reader.get_mut().write_all(&reply).is_err() || reader.get_mut().flush().is_err()
                {
                    return;
                }
            }
        });
    }
}

fn main() {
    if let Err(error) = serve() {
        eprintln!("arkdeck-agentd: {error}");
        std::process::exit(69);
    }
}
