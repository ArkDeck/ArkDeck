#[cfg(target_os = "macos")]
mod app_ingress;
#[cfg(target_os = "macos")]
mod bootstrap_readers;
#[cfg(all(test, target_os = "macos"))]
mod cleanup_debt_control;
#[cfg(target_os = "macos")]
mod code_sign_helper;
#[cfg(all(test, target_os = "macos"))]
mod control_action_control;
#[cfg(all(test, target_os = "macos"))]
mod control_action_host_control;
#[cfg(target_os = "macos")]
mod development_mutation;
#[cfg(target_os = "macos")]
mod development_usb;
#[cfg(unix)]
mod drain;
#[cfg(target_os = "macos")]
mod facade;
#[cfg(target_os = "macos")]
mod facade_owners;
#[cfg(all(test, target_os = "macos"))]
mod hdc_status_control;
mod host;
#[cfg(target_os = "macos")]
mod managed_hdc;
#[cfg(all(test, target_os = "macos"))]
mod operation_availability_control;
#[cfg(target_os = "macos")]
mod production;
#[cfg(all(test, target_os = "macos"))]
mod target_observation_control;
#[cfg(all(test, target_os = "macos"))]
mod workspace_project_control;

use arkdeck_contract::MAX_REQUEST_BYTES;
use arkdeck_control::Control;
use arkdeck_platform::{LocalEndpoint, LocalListener, default_user_endpoint, read_frame};
use std::io::{self, BufReader, Write};
use std::sync::{
    Arc,
    atomic::{AtomicUsize, Ordering},
};
use std::time::Duration;

/// Swift `drainAndStop(deadline: 20)`: one cutoff for the frames being
/// answered and the connections still open.
#[cfg(unix)]
const DRAIN_DEADLINE: Duration = Duration::from_secs(20);

/// How long a connection may wait for its next byte.
const CONNECTION_IDLE: Duration = Duration::from_secs(20);

/// The isolated owner's development HDC, as its composition takes it.
#[cfg(target_os = "macos")]
struct DevelopmentHdc {
    dispatch: arkdeck_provider_hdc::ProcessDispatch,
    managed: Option<Arc<managed_hdc::ManagedHdc>>,
    /// Whether its digest is a registered HDC's, which it then is only as
    /// the managed server this owner started.
    registered: bool,
}

/// The isolated owner's development HDC, named by
/// `ARKDECK_DEVELOPMENT_HDC_PATH`, pinned by the digest of its bytes at
/// startup and dispatched as every HDC plan is (`ProcessDispatch`, with the
/// server port the daemon inherited).
///
/// On its own it must be a fixture: a registered HDC executable would
/// address a real server and device, which needs the existing-server identity
/// proof, so one is refused. `ARKDECK_DEVELOPMENT_HDC_SERVER=managed` is that
/// proof, opted into separately: the owner first starts the executable as its
/// own managed server on the endpoint Swift's selector picks, and the
/// commandless identity proof binds the endpoint's listener to that very
/// launch. A registered HDC is then accepted, and every dispatch addresses
/// that server while it is still the one launched.
///
/// Development USB relations are read beside a fixture; beside a registered
/// HDC only when the owner starts it as its managed server and the caller
/// acknowledges them (`development_usb::admit`). Without them, the owner reads
/// the Runtime's own USB relations beside that registered HDC and none beside
/// a fixture (`development_usb::relation_source`).
#[cfg(target_os = "macos")]
fn development_hdc() -> Result<Option<DevelopmentHdc>, Box<dyn std::error::Error>> {
    let managed = match std::env::var_os("ARKDECK_DEVELOPMENT_HDC_SERVER") {
        None => false,
        Some(mode) if mode == "managed" => true,
        Some(_) => return Err("ARKDECK_DEVELOPMENT_HDC_SERVER accepts only managed".into()),
    };
    let relations = std::env::var_os("ARKDECK_DEVELOPMENT_USB_RELATIONS").is_some();
    let acknowledged = development_usb::acknowledged(
        std::env::var_os(development_usb::REGISTERED_HDC_ACKNOWLEDGMENT).as_deref(),
    )?;
    let Some(path) = std::env::var_os("ARKDECK_DEVELOPMENT_HDC_PATH") else {
        if managed {
            return Err(
                "a managed development HDC server needs ARKDECK_DEVELOPMENT_HDC_PATH".into(),
            );
        }
        development_usb::admit(false, false, relations, acknowledged)?;
        return Ok(None);
    };
    let path = std::path::PathBuf::from(path);
    if !path.is_absolute() {
        return Err("ARKDECK_DEVELOPMENT_HDC_PATH must be an explicit absolute path".into());
    }
    let digest = arkdeck_contract::sha256_hex(&std::fs::read(&path)?);
    let registered = arkdeck_provider_hdc::HdcReadOnlyProvider::new(
        arkdeck_platform::VerifiedTool::open(&path, &digest)?,
    )
    .is_ok();
    if registered && !managed {
        return Err(
            "the isolated Rust development owner runs a fixture HDC only; a registered HDC \
             needs the existing-server identity proof"
                .into(),
        );
    }
    // A harness's relations stand in for the Runtime's own reader beside a
    // fixture. For a registered HDC they would be a trusted fact about a real
    // device that no physical relation proved, so they are refused there
    // unless the owner starts that HDC as its managed server and the caller
    // acknowledges them: the maintainer's option A of 2026-09-19, whose
    // results are development-root evidence, never REAL_DEVICE_PASS. Decided
    // before any server is started.
    development_usb::admit(registered, managed, relations, acknowledged)?;
    let managed = if managed {
        let selection = arkdeck_provider_hdc::EndpointSelection::select(
            std::env::var_os(arkdeck_provider_hdc::SERVER_PORT_VARIABLE)
                .map(|port| port.to_string_lossy().into_owned())
                .as_deref(),
        )?;
        Some(Arc::new(managed_hdc::ManagedHdc::start(
            &arkdeck_platform::VerifiedTool::open(&path, &digest)?,
            &path.to_string_lossy(),
            selection,
        )?))
    } else {
        None
    };
    Ok(Some(DevelopmentHdc {
        dispatch: arkdeck_provider_hdc::ProcessDispatch::new(
            arkdeck_platform::VerifiedTool::open(&path, &digest)?,
            arkdeck_provider_hdc::ProcessDispatch::inherited_server_port().as_deref(),
        ),
        managed,
        registered,
    }))
}

fn serve() -> Result<(), Box<dyn std::error::Error>> {
    let development = std::env::var_os("ARKDECK_DEVELOPMENT_STATE_ROOT");
    // The production composition is asked for explicitly, and refuses every
    // other composition's input before one is read (`production.rs`).
    #[cfg(target_os = "macos")]
    let production = production::requested(std::env::var_os(production::COMPOSITION).as_deref())?;
    #[cfg(target_os = "macos")]
    if production {
        production::refuse_other_compositions(
            &|name| std::env::var_os(name).is_some(),
            facade::swift_executable().is_some(),
        )?;
    }
    #[cfg(not(target_os = "macos"))]
    if std::env::var_os("ARKDECK_RUNTIME_COMPOSITION").is_some() {
        return Err("the production composition is composed only on macOS".into());
    }
    #[cfg(target_os = "macos")]
    let app_ingress = app_ingress::Configuration::from_environment(development.as_deref())?;
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
    if development.is_none()
        && [
            "ARKDECK_DEVELOPMENT_HDC_PATH",
            "ARKDECK_DEVELOPMENT_HDC_SERVER",
        ]
        .iter()
        .any(|key| std::env::var_os(key).is_some())
    {
        return Err("a development HDC is configured only for an isolated development root".into());
    }
    // The standalone daemon and the facade never read development relations,
    // acknowledged or not.
    if development.is_none()
        && std::env::var_os("ARKDECK_DEVELOPMENT_USB_RELATIONS_WITH_REGISTERED_HDC").is_some()
    {
        return Err(
            "development USB relations beside a registered HDC are acknowledged only for an \
             isolated development root"
                .into(),
        );
    }
    if std::env::var_os("ARKDECK_DEVELOPMENT_USB_RELATIONS").is_some()
        && std::env::var_os("ARKDECK_DEVELOPMENT_HDC_PATH").is_none()
    {
        return Err("development USB relations are configured only with a development HDC".into());
    }
    // The standalone daemon and the facade compose the helper their own
    // bundle holds, never one a caller names.
    #[cfg(target_os = "macos")]
    if development.is_none() && std::env::var_os(code_sign_helper::DEVELOPMENT_HELPER).is_some() {
        return Err(
            "a development code-sign helper is named only for an isolated development root".into(),
        );
    }
    // The standalone daemon and the facade prove a device mutation's state
    // continuity against the installed Runtime's own root, and never take a
    // development authority, acknowledged or not.
    #[cfg(target_os = "macos")]
    if development.is_none() && std::env::var_os(development_mutation::ACKNOWLEDGMENT).is_some() {
        return Err(
            "a development mutation authority is acknowledged only for an isolated development \
             root"
                .into(),
        );
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
    // As Swift's daemon, before anything it owns is started: SIGTERM and
    // SIGINT are recorded, and the serving loop drains and stops for them.
    #[cfg(unix)]
    let stop = arkdeck_platform::StopSignal::install()?;
    // The managed server the isolated owner starts, which it stops last.
    #[cfg(target_os = "macos")]
    let mut managed_hdc = None;
    let endpoint = match std::env::var_os("ARKDECK_ENDPOINT") {
        Some(path) => LocalEndpoint::new(path),
        None => default_user_endpoint()?,
    };
    let host = host::Host::from_environment();
    // Swift's `HDCNativeCodeSignHelperArtifact.bundled()`: the helper this
    // bundle holds, verified. Without one, a native deployment stays
    // unavailable with the reason the availability answer carries; a helper
    // that is there and does not verify is reported and the daemon serves.
    #[cfg(target_os = "macos")]
    let host = match code_sign_helper::bundled() {
        Ok(Some(helper)) => host.with_code_sign_helper(helper),
        Ok(None) => host,
        Err(reason) => {
            println!("native deployment stays unavailable: {reason}");
            let _ = io::stdout().flush();
            host
        }
    };
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
            "human-action-snapshots",
            "workspace-projects",
            // Swift's union control-action owner pages here. Its HDC owner's
            // `hdc-control-actions` exists only beside a managed HDC server.
            "control-action-snapshots",
        ] {
            directory.private_child(name)?;
        }
        // The managed HDC server this owner is asked to start, whose HDC
        // control-action owner keeps its actions in `hdc-control-actions`.
        let managed_server = std::env::var_os("ARKDECK_DEVELOPMENT_HDC_SERVER")
            .is_some_and(|mode| mode == "managed");
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
                root.join("human-action-snapshots"),
                root.join("control-action-snapshots"),
            ]
            .into_iter()
            .chain(managed_server.then(|| root.join("hdc-control-actions")))
            .collect(),
        )?;
        let host = host
            .with_targets(arkdeck_hoststore::TargetStore::open(
                &root.join("targets-state"),
            )?)
            .with_history(arkdeck_hoststore::HistoryStore::open(&root)?)
            // A preset's toolchain is pinned in this owner's own bootstrap
            // registry, as Swift pins it in its DevEco registry. No signing
            // credential owner is composed yet, so a preset that pins a
            // credential is refused as Swift's store refuses it without one.
            .with_workspace_projects(
                arkdeck_hoststore::WorkspaceProjectStore::open(&root.join("workspace-projects"))?
                    .with_dependency_pinning(Some(host::toolchain_pinning(&bootstrap)?), None),
            )
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
            // Swift's combined human-action owner pages the executions' actions,
            // and the approvals of the control-action owner below, in its own
            // directory beside them.
            .with_human_actions(arkdeck_hoststore::HumanActionResources::open(
                &root.join("human-action-snapshots"),
            )?)
            // Swift's union control-action owner, over no tool-selection
            // owner, and over the HDC control-action owner only with the
            // managed HDC server this owner starts below (a failed start ends
            // the daemon).
            .with_control_actions({
                let resources = arkdeck_hoststore::ControlActionResources::open(
                    &root.join("control-action-snapshots"),
                )?;
                if managed_server {
                    let actions = directory.private_child("hdc-control-actions")?;
                    actions.validate_path(&root.join("hdc-control-actions"))?;
                    resources.with_hdc(arkdeck_hoststore::HdcControlActions::open(
                        &root.join("hdc-control-actions"),
                        arkdeck_hoststore::OwnerContext::production()
                            .map_err(|error| error.message)?,
                    )?)
                } else {
                    resources
                }
            })
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
                        arkdeck_hoststore::AnalyzerProfile::crash_signature(std::path::Path::new(
                            &path,
                        ))
                    })
                    .transpose()?,
            );
        let development_hdc = development_hdc()?;
        let (registered, managed) = development_hdc.as_ref().map_or((false, false), |hdc| {
            (hdc.registered, hdc.managed.is_some())
        });
        let host = match development_hdc {
            Some(DevelopmentHdc {
                dispatch,
                managed: Some(managed),
                ..
            }) => {
                managed.monitor_foreground_exit()?;
                managed_hdc = Some(Arc::clone(&managed));
                host.with_managed_development_hdc(dispatch, managed)
            }
            Some(DevelopmentHdc { dispatch, .. }) => host.with_development_hdc(Some(dispatch)),
            None => host.with_development_hdc(None),
        };
        // The USB relations the Target observations read
        // (`development_usb::relation_source`): the file the caller names,
        // beside the fixture or acknowledged beside the registered HDC
        // (`development_hdc`); without one, beside the registered HDC this
        // owner started as its managed server, the Runtime's own census of the
        // host's I/O Registry, Swift's source (the maintainer's decision Q1=B
        // of 2026-09-24); otherwise none.
        let file = development_usb::DevelopmentUsbRelations::from_environment()?;
        let host = match development_usb::relation_source(registered, managed, file.is_some()) {
            development_usb::RelationSource::File => host.with_usb_relations(Arc::new(
                file.ok_or("development USB relations are unavailable")?,
            )),
            development_usb::RelationSource::Registry => host
                .with_usb_registry_relations(arkdeck_provider_hdc::UsbRegistryRelations::system()),
            development_usb::RelationSource::Nothing => host,
        };
        // Acknowledged, and with the development HDC started as the managed
        // server, this owner proves a device mutation's state continuity
        // against its own Job state instead of the installed Runtime's root,
        // which it can never be (maintainer decision 2026-09-20, as option A
        // of 2026-09-19). Everything else about that proof, the capability and
        // the device hold is unchanged, and what it proves about a real device
        // is development-root evidence, never REAL_DEVICE_PASS.
        // An isolated development root may name the helper outright; its
        // bytes are verified here, so the facts a deployment carries are
        // exactly this file's. A named helper that does not verify fails
        // startup rather than leaving the operation quietly unavailable.
        let host = match code_sign_helper::development(
            std::env::var_os(code_sign_helper::DEVELOPMENT_HELPER).as_deref(),
        )? {
            Some(path) => host.with_code_sign_helper(code_sign_helper::verified(&path)?),
            None => host,
        };
        if development_mutation::admit(
            true,
            managed_server,
            development_mutation::acknowledged(
                std::env::var_os(development_mutation::ACKNOWLEDGMENT).as_deref(),
            )?,
        )? {
            host.with_development_mutation_root(root.join("jobs-state"))
        } else {
            host
        }
    } else {
        host
    };
    // The production composition over the account's own state root
    // (`production.rs`): its claim holds Swift's instance lock and the
    // installed socket before any store is created or probed, and both stay
    // held until this process exits.
    #[cfg(target_os = "macos")]
    let (host, app_ingress, _instance_lock, production_socket) = if production {
        let layout = production::Layout::account()?;
        let inputs = production::Inputs::from_environment()?;
        let now = host::utc_now();
        let authority = match production::claim(&layout, &now)? {
            production::Claim::Owned(authority) => authority,
            // As Swift's second instance: the Runtime serving keeps serving.
            production::Claim::AlreadyRunning(instance) => {
                production::report(&instance.running());
                return Ok(());
            }
        };
        development_listener = Some(authority.listener);
        production::report(&format!(
            "arkdeck-agentd production composition over {}",
            layout.state.display()
        ));
        let composition = production::compose(&layout, &inputs, host, &now)?;
        for omitted in &composition.omitted {
            production::report(&format!("arkdeck-agentd composes no {omitted}"));
        }
        production::report(&format!(
            "arkdeck-agentd owners: {}",
            composition.host.owner_census().join(", ")
        ));
        if let Some(managed) = composition.managed {
            managed_hdc = Some(managed);
        }
        (
            composition.host,
            composition.ingress,
            Some(authority.instance),
            Some(layout.socket),
        )
    } else {
        (host, app_ingress, None, None)
    };
    #[cfg(not(target_os = "macos"))]
    if development.is_some() {
        return Err("development host-store owner is not yet supported on this platform".into());
    }
    // Swift `recoverActiveJobs()` before the daemon serves: the isolated or
    // the production owner reopens its active Jobs, parks every unresolved
    // intent and dispatches nothing. A Job it cannot read, or whose recovery
    // needs state it does not hold, is named here and left as it is; a
    // recovery that fails stops the start, as Swift's does.
    #[cfg(target_os = "macos")]
    if let Some(recovered) = host.recover_active_jobs()? {
        if !recovered.statuses.is_empty() {
            println!(
                "recovered {} active job(s); unknown outcomes parked",
                recovered.statuses.len()
            );
            let _ = io::stdout().flush();
        }
        for (job, reason) in &recovered.quarantined {
            eprintln!(
                "arkdeck-agentd: job {job} is quarantined: {reason}; it will not run and its \
                 record was not modified"
            );
        }
        if !recovered.quarantined.is_empty() {
            eprintln!(
                "arkdeck-agentd: {} Job record(s) this build cannot read; every mutation they \
                 could affect stays refused",
                recovered.quarantined.len()
            );
        }
        for (job, reason) in &recovered.refused {
            eprintln!("arkdeck-agentd: job {job} was not recovered: {reason}");
        }
    }
    // As Swift's daemon, once, before serving and after its Job recovery
    // above: expired Artifacts are reclaimed; the sweep's census keeps every
    // Job not proven settled. A failure is reported and never stops the
    // daemon, since an un-reclaimable store is what the sweep exists to make
    // visible.
    #[cfg(target_os = "macos")]
    if let Some(sweep) = host.collect_expired_artifacts() {
        match sweep {
            Ok(reclaimed) if reclaimed.is_empty() => {}
            Ok(reclaimed) => println!("reclaimed {} expired artifact(s)", reclaimed.len()),
            Err(error) => {
                println!(
                    "artifact retention sweep failed; the store may approach its quota: {error}"
                )
            }
        }
        let _ = io::stdout().flush();
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
    #[cfg(target_os = "macos")]
    if let Some(configuration) = app_ingress {
        // The isolated or the production composition, which owns no Swift
        // process. Both local transports use the very same Control and owners.
        configuration.listen(Arc::clone(&control))?;
        if production_socket.is_some() {
            production::report("arkdeck-agentd App ingress: com.arkdeck.agentd");
        }
    }
    // As Swift's server announces it, once recovery is done and serving
    // starts.
    #[cfg(target_os = "macos")]
    if let Some(socket) = &production_socket {
        production::report(&format!("arkdeck-agentd listening on {}", socket.display()));
    }
    let active = Arc::new(AtomicUsize::new(0));
    #[cfg(unix)]
    let serving = Arc::new(drain::Serving::new()?);
    loop {
        #[cfg(unix)]
        let accepted = listener.accept_until(&stop);
        #[cfg(not(unix))]
        let accepted = listener.accept().map(Some);
        let connection = match accepted {
            Ok(Some(connection)) => connection,
            // A stop was requested: nothing more is accepted.
            Ok(None) => break,
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
        #[cfg(unix)]
        let Some(registered) = serving.register(&connection) else {
            active.fetch_sub(1, Ordering::AcqRel);
            continue;
        };
        let control = Arc::clone(&control);
        let active = Arc::clone(&active);
        #[cfg(unix)]
        let serving = Arc::clone(&serving);
        std::thread::spawn(move || {
            struct Active(Arc<AtomicUsize>);
            impl Drop for Active {
                fn drop(&mut self) {
                    self.0.fetch_sub(1, Ordering::AcqRel);
                }
            }
            let _active = Active(active);
            #[cfg(unix)]
            let _registered = registered;
            if connection.set_read_timeout(Some(CONNECTION_IDLE)).is_err()
                || connection.set_write_timeout(Some(CONNECTION_IDLE)).is_err()
            {
                return;
            }
            let mut reader = BufReader::new(connection);
            // Bound a connection's work without rejecting the required health
            // followed by business exchange. A new connection reauthenticates.
            for _ in 0..128 {
                // The start of the next frame, or the drain ending this
                // connection (see `drain`), or the idle timeout.
                #[cfg(unix)]
                if reader.buffer().is_empty()
                    && !matches!(
                        reader
                            .get_ref()
                            .wait_readable(serving.closing(), CONNECTION_IDLE),
                        Ok(arkdeck_platform::Readiness::Readable)
                    )
                {
                    return;
                }
                let frame = match read_frame(&mut reader, MAX_REQUEST_BYTES) {
                    Ok(frame) => frame,
                    Err(error) if error.kind() == io::ErrorKind::InvalidData => {
                        #[cfg(unix)]
                        let _request = serving.request();
                        let _ = reader.get_mut().write_all(&control.handle_frame(&[]));
                        return;
                    }
                    Err(_) => return,
                };
                #[cfg(unix)]
                let _request = serving.request();
                #[cfg(target_os = "macos")]
                let foreground_console = reader
                    .get_ref()
                    .origin()
                    .is_ok_and(|peer| peer.foreground_console);
                #[cfg(not(target_os = "macos"))]
                let foreground_console = false;
                let reply = control.handle_frame_with_console(&frame, foreground_console);
                if reader.get_mut().write_all(&reply).is_err() || reader.get_mut().flush().is_err()
                {
                    return;
                }
            }
        });
    }
    // Swift `drainAndStop`: the socket is closed and its name removed, the
    // frames being answered finish, then every connection is ended, within
    // one deadline. Jobs running in the background are neither awaited nor
    // cancelled; the App ingress is not drained.
    #[cfg(unix)]
    {
        let _lock = listener.stop_listening();
        serving.drain(std::time::Instant::now() + DRAIN_DEADLINE);
        // Swift stops its HDC host next. Unlike Swift, which lets go of its
        // instance lock at the end of the drain, the transport directory and
        // every store stay owned until the process ends, so a successor never
        // meets this server on the endpoint. Unlike Swift's, the stop also
        // ends the replacement a confirmed restart proved (`ManagedHdc::stop`).
        #[cfg(target_os = "macos")]
        if let Some(managed) = managed_hdc
            && let Some(stopped) = managed.stop()
        {
            use managed_hdc::ReplacementStop;
            if let Err(error) = &stopped.server {
                eprintln!("arkdeck-agentd: the managed HDC server's stop failed: {error}");
            }
            match stopped.replacement {
                ReplacementStop::None => {}
                ReplacementStop::Ended => eprintln!(
                    "arkdeck-agentd: ended the replacement HDC server a confirmed restart proved"
                ),
                ReplacementStop::Uncertain => eprintln!(
                    "arkdeck-agentd: an HDC restart's outcome is uncertain; whatever it left on \
                     the endpoint was not stopped"
                ),
                ReplacementStop::Unproved(reason) | ReplacementStop::Survived(reason) => {
                    eprintln!("arkdeck-agentd: {reason}")
                }
            }
        }
        println!("arkdeck-agentd stopped");
        let _ = io::stdout().flush();
        std::process::exit(0);
    }
    #[cfg(not(unix))]
    unreachable!("only a stop request ends accepting");
}

fn main() {
    if let Err(error) = serve() {
        eprintln!("arkdeck-agentd: {error}");
        std::process::exit(69);
    }
}

#[cfg(all(test, target_os = "macos"))]
mod debug_read_control;
#[cfg(all(test, target_os = "macos"))]
mod trace_probe_control;
