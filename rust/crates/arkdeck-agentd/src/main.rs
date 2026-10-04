// The unit tests run in this binary's test build, in parallel, and none of
// them starts a child process: a test that does runs in `tests/spawning`, one
// at a time, because a child keeps descriptors of this process that another
// test's listener or lock needs gone (see there). The modules that binary
// compiles from these sources (`app_ingress`, `bootstrap_readers`, `host`,
// `managed_hdc`) keep no test module beside them;
// their unit tests are declared here.
#[cfg(target_os = "macos")]
mod app_ingress;
#[cfg(all(test, target_os = "macos"))]
#[path = "app_ingress/tests.rs"]
mod app_ingress_tests;
#[cfg(any(target_os = "macos", windows))]
mod arkforge_execution;
#[cfg(any(target_os = "macos", windows))]
mod arkforge_lane;
#[cfg(any(target_os = "macos", windows))]
mod bootstrap_readers;
#[cfg(all(test, any(target_os = "macos", windows)))]
mod cleanup_debt_control;
#[cfg(any(target_os = "macos", windows))]
mod code_sign_helper;
#[cfg(all(test, target_os = "macos"))]
mod control_action_control;
#[cfg(all(test, target_os = "macos"))]
mod control_action_host_control;
#[cfg(any(target_os = "macos", windows))]
mod crash_ledger_analyzer;
#[cfg(target_os = "macos")]
mod crash_symbolizer_mode;
#[cfg(target_os = "macos")]
mod cutover_preflight;
#[cfg(target_os = "macos")]
mod development_admission;
#[cfg(target_os = "macos")]
mod development_mutation;
// The USB relation rule the Target observations read by, on macOS and
// Windows; its development relation file is composed on macOS only.
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(windows, allow(dead_code))]
mod development_usb;
#[cfg(all(test, target_os = "macos"))]
mod hdc_status_control;
#[cfg(any(target_os = "macos", windows))]
mod hilog_summary_analyzer;
mod host;
#[cfg(test)]
mod host_tests;
#[cfg(any(target_os = "macos", windows))]
mod managed_hdc;
#[cfg(all(test, target_os = "macos"))]
mod operation_availability_control;
#[cfg(target_os = "macos")]
mod production;
#[cfg(target_os = "macos")]
mod tool_selection_startup;
#[cfg(all(test, target_os = "macos"))]
mod tool_selection_startup_tests;
#[cfg(windows)]
mod windows_hdc_gate;
#[cfg(windows)]
mod windows_lifecycle;
#[cfg(all(test, target_os = "macos"))]
mod workspace_project_control;

use arkdeck_control::Control;
#[cfg(unix)]
use arkdeck_platform::{LocalEndpoint, LocalListener, default_user_endpoint};
use std::io::{self, Write};
use std::sync::Arc;
use std::time::Duration;

/// Swift `drainAndStop(deadline: 20)`: one cutoff for the frames being
/// answered and the connections still open.
const DRAIN_DEADLINE: Duration = Duration::from_secs(20);

/// How long a connection may wait for its next byte.
const CONNECTION_IDLE: Duration = Duration::from_secs(20);

/// The isolated owner's development HDC, as its composition takes it.
#[cfg(target_os = "macos")]
struct DevelopmentHdc {
    dispatch: arkdeck_provider_hdc::ProcessDispatch,
    /// Its measured digest: the managed-control tool an ArkForge lane binds.
    sha256: String,
    /// The managed server this owner launched, which it stops last.
    managed: Option<managed_hdc::Launched>,
    /// Whether its digest is a registered HDC's, which it then is only as
    /// the managed server this owner started.
    registered: bool,
}

/// The development HDC the admission names, measured and admitted, and not
/// started yet.
#[cfg(target_os = "macos")]
struct MeasuredHdc {
    path: std::path::PathBuf,
    sha256: String,
    registered: bool,
    /// The tool the managed server is launched from, and its endpoint.
    managed: Option<(
        arkdeck_platform::VerifiedTool,
        arkdeck_provider_hdc::EndpointSelection,
    )>,
    dispatch: arkdeck_platform::VerifiedTool,
}

/// The isolated owner's development HDC, named by
/// `ARKDECK_DEVELOPMENT_HDC_PATH` (`development_admission`), pinned by the
/// digest of its bytes at startup and dispatched as every HDC plan is
/// (`ProcessDispatch`, with the server port the daemon inherited).
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
/// acknowledges them (`development_usb::admit`): a harness's relations would
/// otherwise be a trusted fact about a real device that no physical relation
/// proved (the maintainer's option A of 2026-09-19, whose results are
/// development-root evidence, never REAL_DEVICE_PASS). Without them, the
/// owner reads the Runtime's own USB relations beside that registered HDC
/// and none beside a fixture (`development_usb::relation_source`).
///
/// All of it is decided here, before anything is launched: whatever could
/// refuse the HDC refuses it, and every tool it needs is verified, so that
/// only the launch itself ([`MeasuredHdc::start`]) remains.
#[cfg(target_os = "macos")]
fn measured_hdc(
    admission: &development_admission::Admission,
) -> Result<Option<MeasuredHdc>, Box<dyn std::error::Error>> {
    let Some(hdc) = &admission.hdc else {
        return Ok(None);
    };
    let sha256 = arkdeck_contract::sha256_hex(&std::fs::read(&hdc.path)?);
    let tool = || arkdeck_platform::VerifiedTool::open(&hdc.path, &sha256);
    let registered = arkdeck_provider_hdc::HdcReadOnlyProvider::new(tool()?).is_ok();
    admission.admit_registration(registered)?;
    let managed = match hdc.managed {
        Some(selection) => Some((tool()?, selection)),
        None => None,
    };
    let dispatch = tool()?;
    Ok(Some(MeasuredHdc {
        path: hdc.path.clone(),
        sha256,
        registered,
        managed,
        dispatch,
    }))
}

#[cfg(target_os = "macos")]
impl MeasuredHdc {
    /// Launches the managed server, if the admission names one: the first
    /// thing an isolated start launches. From here the start owns it
    /// (`managed_hdc::Launched`), and a start that fails stops it.
    fn start(self) -> Result<DevelopmentHdc, Box<dyn std::error::Error>> {
        let managed = match self.managed {
            Some((tool, selection)) => Some(managed_hdc::Launched::new(
                managed_hdc::ManagedHdc::start(&tool, &self.path.to_string_lossy(), selection)?,
            )),
            None => None,
        };
        Ok(DevelopmentHdc {
            dispatch: arkdeck_provider_hdc::ProcessDispatch::new(
                self.dispatch,
                arkdeck_provider_hdc::ProcessDispatch::inherited_server_port().as_deref(),
            ),
            sha256: self.sha256,
            managed,
            registered: self.registered,
        })
    }
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
            production::runs_as_retired_facade(),
        )?;
    }
    // The transport facade that paired this daemon with Swift's is retired
    // (TASK-XPA-017): no composition forwards to a Swift daemon, whatever
    // the executable is named or the environment pairs.
    #[cfg(target_os = "macos")]
    production::refuse_retired_facade(
        &|name| std::env::var_os(name).is_some(),
        production::runs_as_retired_facade(),
    )?;
    #[cfg(not(target_os = "macos"))]
    if std::env::var_os("ARKDECK_RUNTIME_COMPOSITION").is_some() {
        return Err("the production composition is composed only on macOS".into());
    }
    #[cfg(target_os = "macos")]
    let app_ingress = app_ingress::Configuration::from_environment(development.as_deref())?;
    #[cfg(target_os = "macos")]
    let mut development_listener = None;
    if development.is_some()
        && ["ARKDECK_HDC_PATH", "ARKDECK_HDC_SHA256"]
            .iter()
            .any(|key| std::env::var_os(key).is_some())
    {
        return Err("the isolated Rust development owner cannot configure HDC".into());
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
    // The standalone and production daemons never read development relations,
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
    // The standalone and production daemons compose the helper their own
    // bundle holds, never one a caller names.
    #[cfg(any(target_os = "macos", windows))]
    if development.is_none() && std::env::var_os(code_sign_helper::DEVELOPMENT_HELPER).is_some() {
        return Err(
            "a development code-sign helper is named only for an isolated development root".into(),
        );
    }
    // The standalone and production daemons prove a device mutation's state
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
    // The isolated owner's state root and its development inputs, every
    // value and every combination of which is decided here, from the
    // environment, before anything is opened or started: a start they refuse
    // launches nothing (`development_admission.rs`).
    #[cfg(target_os = "macos")]
    let isolated = match &development {
        Some(root) => Some((
            root.clone(),
            development_admission::admit(&|name| std::env::var_os(name))?,
        )),
        None => None,
    };
    if std::env::args_os().len() != 1 {
        return Err("arkdeck-agentd takes no device, command, path or authority arguments; configure the local host environment".into());
    }
    // As Swift's daemon, before anything it owns is started: SIGTERM and
    // SIGINT are recorded, and the serving loop drains and stops for them.
    #[cfg(unix)]
    let stop = arkdeck_platform::StopSignal::install()?;
    // The Windows daemon's state root, single-instance guard, owner lock,
    // stop request and pipe, all taken before anything else is started, or
    // the answer that another daemon owns the root (`windows_lifecycle.rs`).
    #[cfg(windows)]
    let windows_lifecycle::Serving {
        stop,
        listener,
        authority,
    } = match windows_lifecycle::start(
        development.as_deref(),
        std::env::var_os("ARKDECK_ENDPOINT").as_deref(),
        &host::utc_now(),
        &|name| std::env::var_os(name),
    )? {
        windows_lifecycle::Start::Serve(serving) => serving,
        // As Swift's second instance: the Runtime serving keeps serving.
        windows_lifecycle::Start::AlreadyRunning(instance) => {
            println!("{}", instance.running());
            let _ = std::io::Write::flush(&mut std::io::stdout());
            return Ok(());
        }
    };
    // The ArkForge lane either owner composes, whose daemon it stops after
    // its drain and before the managed server. A start that fails once it is
    // composed stops it on the way out, after the managed server
    // (`arkforge_lane::Composed`), in the order of Swift's failed start
    // (`main.swift` 1595-1602): declared first, it is dropped last.
    #[cfg(any(target_os = "macos", windows))]
    #[cfg_attr(windows, allow(unused_mut))]
    let mut arkforge: Option<arkforge_lane::Composed> = None;
    // The managed server the isolated or the production owner starts (on
    // Windows, a development root's registered HDC: `windows_lifecycle`),
    // which it stops last after its drain; any failure once it is started
    // stops it on the way out, first (`managed_hdc::Launched`).
    #[cfg(any(target_os = "macos", windows))]
    let mut managed_hdc: Option<managed_hdc::Launched> = None;
    #[cfg(unix)]
    let endpoint = match std::env::var_os("ARKDECK_ENDPOINT") {
        Some(path) => LocalEndpoint::new(path),
        None => default_user_endpoint()?,
    };
    let host = host::Host::from_environment();
    // Swift's `HDCNativeCodeSignHelperArtifact.bundled()`: the helper this
    // bundle holds, verified. Without one, a native deployment stays
    // unavailable with the reason the availability answer carries; a helper
    // that is there and does not verify is reported and the daemon serves.
    // The Windows packages carry it beside the daemon (the xcopy and RC
    // scripts), and it is composed before the owners, so the census the
    // composition reports names it: no Windows HDC tuple is registered yet,
    // so there it only stands ready for the native deployment the tuple
    // will make available.
    #[cfg(any(target_os = "macos", windows))]
    let host = match code_sign_helper::bundled() {
        Ok(Some(helper)) => host.with_code_sign_helper(helper),
        Ok(None) => host,
        Err(reason) => {
            println!("native deployment stays unavailable: {reason}");
            let _ = io::stdout().flush();
            host
        }
    };
    // The owners a Windows daemon of a state root composes over it
    // (`windows_lifecycle::Authority::compose`); the private-endpoint
    // foundation owns no root and composes none.
    #[cfg(windows)]
    let host = match &authority {
        Some(authority) => {
            let (host, composed, managed) = authority.compose(host)?;
            arkforge = Some(composed);
            managed_hdc = managed;
            host
        }
        None => host,
    };
    #[cfg(target_os = "macos")]
    let host = if let Some((root, admission)) = isolated {
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
        let managed_server = admission.managed();
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
                root.join("evolution-workspaces"),
            ]
            .into_iter()
            .chain(managed_server.then(|| root.join("hdc-control-actions")))
            .collect(),
        )?;
        // Swift's start-up Rockchip reconciliation over this owner's Target
        // store, its Job state standing for Swift's state directory: a custom
        // state directory's, so no Loader binding lineage is followed and no
        // recovery proof is kept, and only a post-flash alias proved from its
        // own terminal Flash history is appended.
        let targets = arkdeck_hoststore::TargetStore::open(&root.join("targets-state"))?;
        for line in
            arkdeck_hoststore::reconcile_rockchip_startup(&targets, &root.join("jobs-state"))?.lines
        {
            println!("{line}");
        }
        let _ = io::stdout().flush();
        let host = host
            .with_targets(targets)
            .with_history(arkdeck_hoststore::HistoryStore::open(&root)?)
            // A preset's toolchain is pinned in this owner's own bootstrap
            // registry, as Swift pins it in its DevEco registry. An isolated
            // root composes no signing credential owner: Swift's private
            // `--state-dir` daemon shares the account's signing material,
            // which a development root must not read, pin or release. A
            // preset that pins a credential is refused, as Swift's store
            // refuses it without an owner, and nothing is signed.
            .with_workspace_projects(
                arkdeck_hoststore::WorkspaceProjectStore::open(&root.join("workspace-projects"))?
                    .with_dependency_pinning(Some(host::toolchain_pinning(&bootstrap)?), None),
            )
            // Swift composes the registered projects over its state directory,
            // whose `evolution-workspaces` holds the Runtime-owned copies.
            .with_workspace_operations(
                &root,
                &bootstrap,
                None,
                std::env::var_os("ARKDECK_WORKSPACE_INSPECTOR").as_deref(),
                // As Swift's daemon feeds its WaterFlow symbolizer.
                std::env::var_os("ARKDECK_ANALYZER_PATH").as_deref(),
            )?
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
            // Swift's Flash invocation owner keeps its documents in the state
            // directory its engine plans in, and creates their directories at
            // its start: the recovery broker writes an attempt's permit there
            // and the planner below reads it from there, as in production.
            .with_flash_invocations(arkdeck_hoststore::FlashInvocations::open(&root)?)
            // As the Swift daemon: an analyzer is configured only by naming its
            // executable, and a named path that is not one fails startup.
            .with_planning(
                &root,
                hilog_summary_analyzer::composed(
                    std::env::var_os("ARKDECK_ANALYZER_PATH")
                        .as_deref()
                        .map(std::path::Path::new),
                    std::env::var_os("ARKDECK_ARKTRACE_DESCRIPTOR").as_deref(),
                    &root,
                )?,
            );
        // What the development inputs' files decide, before anything is
        // launched: the HDC's registration against what the admission allows,
        // and a helper the caller names, whose bytes fail the start if they do
        // not verify rather than leave native deployment quietly unavailable
        // (its facts are then exactly this file's).
        let development_hdc = measured_hdc(&admission)?;
        let code_sign_helper = admission
            .code_sign_helper
            .as_deref()
            .map(code_sign_helper::verified)
            .transpose()?;
        // The managed server, the first thing this owner launches. Nothing
        // after it refuses an input; a start that fails after it (its Job
        // recovery, say) stops it on the way out.
        let development_hdc = development_hdc.map(MeasuredHdc::start).transpose()?;
        let (registered, managed) = development_hdc.as_ref().map_or((false, false), |hdc| {
            (hdc.registered, hdc.managed.is_some())
        });
        let hdc_sha256 = development_hdc.as_ref().map(|hdc| hdc.sha256.clone());
        let host = match development_hdc {
            Some(DevelopmentHdc {
                dispatch,
                managed: Some(managed),
                ..
            }) => {
                let server = Arc::clone(managed.server());
                managed_hdc = Some(managed);
                server.monitor_foreground_exit()?;
                host.with_managed_development_hdc(dispatch, server)
            }
            Some(DevelopmentHdc { dispatch, .. }) => host.with_development_hdc(Some(dispatch)),
            None => host.with_development_hdc(None),
        };
        // The USB relations the Target observations read
        // (`development_usb::relation_source`): the file the caller names,
        // beside the fixture or acknowledged beside the registered HDC
        // (`measured_hdc`); without one, beside the registered HDC this
        // owner started as its managed server, the Runtime's own census of the
        // host's I/O Registry, Swift's source (the maintainer's decision Q1=B
        // of 2026-09-24); otherwise none.
        let file = admission
            .relations
            .clone()
            .map(|path| Arc::new(development_usb::DevelopmentUsbRelations::at(path)));
        let source = development_usb::relation_source(registered, managed, file.is_some());
        let host = match source {
            development_usb::RelationSource::File => host.with_usb_relations(
                file.clone()
                    .ok_or("development USB relations are unavailable")?,
            ),
            development_usb::RelationSource::Registry => host
                .with_usb_registry_relations(arkdeck_provider_hdc::UsbRegistryRelations::system()),
            development_usb::RelationSource::Nothing => host,
        };
        // Swift's post-flash alias reconciler over the Application Support
        // root, which the isolated owner's root stands for (the parent of its
        // Job state, as Swift's is its state directory's parent). It reads the
        // board from the same source as the Target observations, so a
        // fixture's board is never proved by the host's devices: the census of
        // the host's I/O Registry beside the managed registered HDC, the
        // harness's file where one is named, and no device otherwise.
        let host = host.with_flash_alias_reconciler(arkdeck_hoststore::FlashAliasReconciler::new(
            &root,
            development_usb::flash_census(source, file.clone()),
            host::utc_now,
        ));
        // Swift's ArkForge lane beside the Job state, `root/jobs-state/arkforge`:
        // the one `arkforged` generation a validated bundle names, paired and
        // proved ready, or why there is none. Its device access observer and
        // the facts' Loader observation read that directory's public socket
        // whether or not a lane runs; the facts measure the bundle's daemon.
        let composed = arkforge_lane::compose(
            &root.join("jobs-state"),
            |key| std::env::var(key).ok(),
            hdc_sha256.as_deref(),
        );
        composed.report();
        let host = host
            // Swift's Flash planning over that lane, its record root beside
            // the Job state, which stands for Swift's state directory.
            .with_flash_planning(composed.planning(&root.join("jobs-state"), hdc_sha256.is_some()))
            // Swift's bootloader status observer and Rockchip facts over the
            // same root and census.
            .with_flash_host_facts(
                arkdeck_hoststore::FlashHostFacts::new(
                    &root,
                    development_usb::flash_census(source, file.clone()),
                )
                .with_rockusb(composed.rockusb())
                .with_arkforge_loader(&composed.runtime_directory),
            )
            .with_device_access(arkdeck_provider_arkforge::DeviceAccessObserver::new(
                &composed.runtime_directory,
            ))
            .with_lane_plan_preview(composed.lane_plan_preview())
            // Swift's Loader binding coordinator over the same root, census
            // and lane directory, with the Runtime's records below the root.
            .with_loader_binding(arkdeck_hoststore::LoaderBinding::new(
                &root,
                development_usb::flash_census(source, file.clone()),
                arkdeck_hoststore::ArkForgeLoader::new(
                    development_usb::flash_census(source, file.clone()),
                    &composed.runtime_directory,
                ),
            ));
        let host = arkforge_execution::install(
            host,
            &composed,
            &root.join("jobs-state"),
            &root,
            development_usb::flash_census(source, file.clone()),
        );
        arkforge = Some(composed);
        // The helper an isolated development root names outright, verified
        // above, in place of the bundle's.
        let host = match code_sign_helper {
            Some(helper) => host.with_code_sign_helper(helper),
            None => host,
        };
        // Acknowledged, and with the development HDC started as the managed
        // server (`development_admission`), this owner proves a device
        // mutation's state continuity against its own Job state instead of
        // the installed Runtime's root, which it can never be (maintainer
        // decision 2026-09-20, as option A of 2026-09-19). Everything else
        // about that proof, the capability and the device hold is unchanged,
        // and what it proves about a real device is development-root
        // evidence, never REAL_DEVICE_PASS.
        if admission.mutation_authority {
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
    let (host, app_ingress, _instance_lock, production_socket, rockchip) = if production {
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
        composition.arkforge.report();
        arkforge = Some(composition.arkforge);
        (
            composition.host,
            composition.ingress,
            Some(authority.instance),
            Some(layout.socket),
            composition.rockchip,
        )
    } else {
        (
            host,
            app_ingress,
            None,
            None,
            arkdeck_hoststore::RockchipStartup::default(),
        )
    };
    #[cfg(all(unix, not(target_os = "macos")))]
    if development.is_some() {
        return Err("development host-store owner is not yet supported on this platform".into());
    }
    // Swift `recoverActiveJobs()` before the daemon serves: the isolated or
    // the production owner reopens its active Jobs, parks every unresolved
    // intent and dispatches nothing. A Job it cannot read, or whose recovery
    // needs state it does not hold, is named here and left as it is; a
    // recovery that fails stops the start, as Swift's does.
    #[cfg(any(target_os = "macos", windows))]
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
    // A publication a crash stopped between writing its Session aside and
    // renaming it left it in staging: removed once it is proved this
    // Runtime's, kept and named otherwise, and never published again. A
    // failure is reported and never stops the start: nothing reads staging.
    #[cfg(any(target_os = "macos", windows))]
    if let Some(staged) = host.recover_staged_sessions() {
        for (entry, job) in &staged.removed {
            println!(
                "removed staged Session {entry} of job {job}, which a stopped publication left"
            );
        }
        for (entry, reason) in &staged.kept {
            eprintln!("arkdeck-agentd: staged Session {entry} is kept as it is: {reason}");
        }
        let _ = std::io::Write::flush(&mut std::io::stdout());
    }
    // As Swift's engine then does with the recovery proof of the binding its
    // start carried the Target to (`main.swift` 1342–1356): the enter-Loader
    // transition awaiting that binding, which this Runtime names and does not
    // settle yet; two or more stop the start.
    #[cfg(target_os = "macos")]
    if let Some(line) = host.loader_transition_awaiting(&rockchip)? {
        println!("{line}");
        let _ = io::stdout().flush();
    }
    // As Swift's daemon, once, before serving and after its Job recovery
    // above: expired Artifacts are reclaimed; the sweep's census keeps every
    // Job not proven settled. A failure is reported and never stops the
    // daemon, since an un-reclaimable store is what the sweep exists to make
    // visible.
    #[cfg(any(target_os = "macos", windows))]
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
    let listener = if let Some(listener) = development_listener {
        listener
    } else {
        LocalListener::bind(&endpoint)?
    };
    #[cfg(all(unix, not(target_os = "macos")))]
    let listener = LocalListener::bind(&endpoint)?;
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
    #[cfg(windows)]
    if let Some(authority) = &authority {
        println!(
            "arkdeck-agentd listening on {}",
            authority.endpoint.as_path().display()
        );
        let _ = std::io::Write::flush(&mut std::io::stdout());
    }
    let socket_drain = arkdeck_agentd::serve_control(
        listener,
        Arc::clone(&control),
        |listener| listener.accept_until(&stop),
        CONNECTION_IDLE,
        DRAIN_DEADLINE,
    )?;
    // Swift `drainAndStop`: the socket is closed and its name removed, the
    // frames being answered finish, then every connection is ended, within
    // one deadline. Jobs running in the background are neither awaited nor
    // cancelled; the App ingress is not drained.
    #[cfg(unix)]
    {
        let _lock = socket_drain.listener_lock;
        // Swift stops its ArkForge daemon next (`main.swift` 1624-1627).
        #[cfg(target_os = "macos")]
        if let Some(arkforge) = &arkforge {
            arkforge.stop();
        }
        #[cfg(target_os = "macos")]
        let recompose = managed_hdc
            .as_ref()
            .is_some_and(|h| h.server().requires_recomposition());
        #[cfg(not(target_os = "macos"))]
        let recompose = false;
        // Swift stops its HDC host next. Unlike Swift, which lets go of its
        // instance lock at the end of the drain, the transport directory and
        // every store stay owned until the process ends, so a successor never
        // meets this server on the endpoint. Unlike Swift's, the stop also
        // ends the replacement a confirmed restart proved (`ManagedHdc::stop`).
        #[cfg(target_os = "macos")]
        if let Some(managed) = managed_hdc
            && let Some(stopped) = managed.stop()
        {
            for line in stopped.report(true) {
                eprintln!("arkdeck-agentd: {line}");
            }
        }
        println!("arkdeck-agentd stopped");
        let _ = io::stdout().flush();
        std::process::exit(if recompose { 70 } else { 0 });
    }
    // The same drain on Windows: the pipe is closed, the frames being
    // answered finish, then every connection is ended, within one deadline.
    // A complete drain lets go of the owner lock and then the
    // single-instance guard, on the thread that took it; one the deadline
    // cut short exits holding them, and its successor finds the guard
    // abandoned and starts as after a crash (`windows_lifecycle.rs`).
    #[cfg(windows)]
    {
        drop(socket_drain.listener_lock);
        // The lane's daemon next, as on macOS (`main.swift` 1624-1627).
        if let Some(arkforge) = &arkforge {
            arkforge.stop();
        }
        // Then the managed server, as on macOS, while the root is still
        // owned, so a successor never meets it on the endpoint; a server the
        // owner must be recomposed after exits 70, as there.
        let recompose = managed_hdc
            .as_ref()
            .is_some_and(|h| h.server().requires_recomposition());
        if let Some(managed) = managed_hdc
            && let Some(stopped) = managed.stop()
        {
            for line in stopped.report(true) {
                eprintln!("arkdeck-agentd: {line}");
            }
        }
        if socket_drain.complete
            && let Some(authority) = authority
        {
            authority.release();
        }
        println!("arkdeck-agentd stopped");
        let _ = std::io::Write::flush(&mut std::io::stdout());
        std::process::exit(if recompose { 70 } else { 0 });
    }
}

fn main() {
    // Four one-shot modes are answered before any composition is considered:
    // Swift's HiLog summary and crash-ledger analyzers, which the Runtime runs
    // as its analyzer children (`hilog_summary_analyzer.rs`,
    // `crash_ledger_analyzer.rs`), its ArkTS crash symbolizer, which a symbol
    // preset runs (`crash_symbolizer_mode.rs`), and the M5 cutover preflight,
    // a read of the production layout (`cutover_preflight.rs`).
    #[cfg(target_os = "macos")]
    {
        let arguments: Vec<std::ffi::OsString> = std::env::args_os().skip(1).collect();
        let first = arguments.first();
        if first.is_some_and(|argument| argument == hilog_summary_analyzer::FLAG) {
            std::process::exit(hilog_summary_analyzer::run(&arguments));
        }
        if first.is_some_and(|argument| argument == crash_ledger_analyzer::FLAG) {
            std::process::exit(crash_ledger_analyzer::run(&arguments));
        }
        if first.is_some_and(|argument| argument == crash_symbolizer_mode::FLAG) {
            std::process::exit(crash_symbolizer_mode::run(&arguments));
        }
        if first.is_some_and(|argument| argument == cutover_preflight::FLAG) {
            std::process::exit(cutover_preflight::run(&arguments));
        }
    }
    // The two analyzer modes on Windows too (TASK-XPA-011).
    #[cfg(windows)]
    {
        let arguments: Vec<std::ffi::OsString> = std::env::args_os().skip(1).collect();
        let first = arguments.first();
        if first.is_some_and(|argument| argument == hilog_summary_analyzer::FLAG) {
            std::process::exit(hilog_summary_analyzer::run(&arguments));
        }
        if first.is_some_and(|argument| argument == crash_ledger_analyzer::FLAG) {
            std::process::exit(crash_ledger_analyzer::run(&arguments));
        }
    }
    if let Err(error) = serve() {
        eprintln!("arkdeck-agentd: {error}");
        std::process::exit(69);
    }
}

#[cfg(all(test, target_os = "macos"))]
mod debug_invocation_control;
#[cfg(all(test, target_os = "macos"))]
mod device_access_control;
#[cfg(all(test, target_os = "macos"))]
mod flash_host_reads_control;
#[cfg(all(test, target_os = "macos"))]
mod flash_plan_control;
#[cfg(all(test, any(target_os = "macos", windows)))]
mod loader_binding_control;
