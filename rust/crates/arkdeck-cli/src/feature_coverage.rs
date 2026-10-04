//! Swift `CLIMachineContracts.FeatureCoverage` and `appRegistryDocument`: the
//! §14 feature-coverage manifest (`cli-feature-coverage.json`) and the App's
//! capability registry (`app-product-capability-registry.yaml`).
//!
//! Every control method, published Catalog operation, App capability and
//! command leaf is one entry of the manifest, with how the product surface
//! reaches it. The inputs are the registry copy (`command_registry.json`), the
//! App's capability table as published (`app_capability_registry.json`), the
//! compiled contract's methods and Catalog, and the rulings below, which are
//! Swift's.
//!
//! The methods and the Catalog are contract inputs, and a contract view may
//! compile them at an older revision than these rulings. So the manifest takes
//! each method it has a ruling for, and [`problems`] reports a method without
//! one or a ruling for no method, which Swift's `build()` refuses; a
//! checkout's test requires none.
use crate::command_registry;
use crate::machine_contracts::BUNDLE_VERSION;
use arkdeck_contract::{CATALOG_CANONICAL_JSON, CATALOG_DIGEST, METHODS};
use serde_json::{Map, Value, json};
use std::collections::{BTreeMap, BTreeSet};
use std::sync::OnceLock;

/// Swift `featureCoverageSchemaVersion`.
const SCHEMA_VERSION: &str = "arkdeck.cli.feature-coverage/1";
/// Swift `ProductCoverageClassification.allCases`.
const CLASSIFICATIONS: [&str; 8] = [
    "direct",
    "generic",
    "local",
    "presentation",
    "platformService",
    "internal",
    "refused",
    "blocked",
];
const LIFECYCLES: [&str; 4] = ["current", "deprecated", "legacy", "removed"];
const PLATFORMS: [&str; 2] = ["macos", "windows"];

/// A leaf that fronts a control method: its classification and lifecycle
/// come from the leaf unless overridden, and `also` names compatibility
/// leaves that reach the same method under a superseded spelling.
struct Fronted {
    command: &'static str,
    lifecycle: Option<&'static str>,
    note: Option<&'static str>,
    also: &'static [&'static str],
}

const FRONTED: Fronted = Fronted {
    command: "",
    lifecycle: None,
    note: None,
    also: &[],
};

/// Swift `FeatureCoverage.DaemonCoverage`: how the CLI reaches one control
/// method. Swift's table rules no method `refused`, so that case is not
/// ported.
enum Ruling {
    Leaf(Fronted),
    /// Closed protocol plumbing behind a published leaf (§18 `internal`).
    Plumbing {
        behind: &'static str,
        note: &'static str,
    },
}
use Ruling::{Leaf, Plumbing};

const fn leaf(command: &'static str) -> Ruling {
    Leaf(Fronted { command, ..FRONTED })
}

/// Swift `FeatureCoverage.daemonMethodCoverage`, by method.
const RULINGS: &[(&str, Ruling)] = &[
    ("agent.abandon", leaf("agent.abandon")),
    ("agent.list", leaf("agent.list")),
    ("agent.resume", leaf("agent.resume")),
    ("agent.run", leaf("agent.run")),
    ("agent.status", leaf("agent.status")),
    ("artifact.export", leaf("artifact.export")),
    ("artifact.import.abort", leaf("artifact.import.abort")),
    (
        "artifact.import.append",
        Plumbing {
            behind: "artifact.import.hap",
            note: "bounded chunk frame behind `artifact import <kind>`",
        },
    ),
    (
        "artifact.import.begin",
        Plumbing {
            behind: "artifact.import.hap",
            note: "durable import session opening behind `artifact import <kind>`",
        },
    ),
    (
        "artifact.import.commit",
        Plumbing {
            behind: "artifact.import.hap",
            note: "digest-checked commit behind `artifact import <kind>`",
        },
    ),
    ("artifact.import.inspect", leaf("artifact.import.inspect")),
    (
        "artifact.import.inspection",
        Plumbing {
            behind: "artifact.import.hap",
            note: "idempotent re-entry probe behind `artifact import <kind>`",
        },
    ),
    ("artifact.import.list", leaf("artifact.import.list")),
    ("artifact.import.release", leaf("artifact.import.release")),
    ("artifact.inspect", leaf("artifact.inspect")),
    ("artifact.list", leaf("artifact.list")),
    ("artifact.quota", leaf("artifact.quota")),
    ("artifact.read", leaf("artifact.read")),
    ("capability.inspect", leaf("capability.inspect")),
    ("capability.list", leaf("capability.list")),
    (
        "cleanupDebt.continue",
        Leaf(Fronted {
            command: "recovery.cleanup.continue",
            also: &["cleanup-debt.continue"],
            ..FRONTED
        }),
    ),
    (
        "cleanupDebt.list",
        Leaf(Fronted {
            command: "recovery.cleanup.list",
            also: &["cleanup-debt.list"],
            ..FRONTED
        }),
    ),
    ("control-action.list", leaf("control-action.list")),
    ("control-action.reconcile", leaf("control-action.reconcile")),
    ("control-action.show", leaf("control-action.show")),
    (
        "debug.evaluate",
        Leaf(Fronted {
            command: "recovery.flash-invocation.evaluate",
            also: &["debug.evaluate"],
            ..FRONTED
        }),
    ),
    ("debug.probe", leaf("debug.probe")),
    (
        "debug.start",
        Leaf(Fronted {
            command: "recovery.flash-invocation.start",
            also: &["debug.start"],
            ..FRONTED
        }),
    ),
    (
        "debug.status",
        Leaf(Fronted {
            command: "recovery.flash-invocation.status",
            also: &["debug.status"],
            ..FRONTED
        }),
    ),
    (
        "debug.template.run",
        Leaf(Fronted {
            command: "debug.template.run",
            lifecycle: Some("deprecated"),
            note: Some(
                "App direct path; the CLI reaches the same closed template set through Catalog operation debug.template@1",
            ),
            ..FRONTED
        }),
    ),
    (
        "device.display-name.clear",
        leaf("device.display-name.clear"),
    ),
    ("device.display-name.set", leaf("device.display-name.set")),
    (
        "device.observations",
        Leaf(Fronted {
            command: "device.wait",
            note: Some("observation snapshot read by `device wait` and `device list`"),
            also: &["device.list"],
            ..FRONTED
        }),
    ),
    ("doctor", leaf("doctor")),
    ("flash.bind-current-loader", leaf("flash.bind-loader")),
    ("flash.bootloader-status", leaf("flash.bootloader-status")),
    ("flash.device-access", leaf("flash.device-access")),
    ("flash.lanePlanPreview", leaf("flash.lane-preview")),
    ("flash.prerequisites", leaf("flash.prerequisites")),
    ("flash.reconcile-alias", leaf("flash.reconcile-alias")),
    ("health", leaf("runtime.health")),
    ("history.filter.delete", leaf("history.filter.delete")),
    ("history.filter.list", leaf("history.filter.list")),
    ("history.filter.save", leaf("history.filter.save")),
    ("human-action.list", leaf("human-action.list")),
    ("human-action.resume", leaf("human-action.resume")),
    ("human-action.show", leaf("human-action.show")),
    ("job.archive", leaf("job.archive.apply")),
    ("job.archive.preview", leaf("job.archive.preview")),
    ("job.cancel", leaf("job.cancel")),
    ("job.events", leaf("job.events")),
    ("job.evidence", leaf("job.evidence")),
    ("job.list", leaf("job.list")),
    ("job.plan", leaf("job.plan")),
    ("job.reconcile", leaf("job.reconcile")),
    ("job.result", leaf("job.result")),
    ("job.run", leaf("job.run")),
    ("job.show", leaf("job.show")),
    ("job.status", leaf("job.status")),
    (
        "diagnostic.session.status",
        leaf("diagnostics.session.status"),
    ),
    ("diagnostic.session.mark", leaf("diagnostics.session.mark")),
    ("diagnostic.session.stop", leaf("diagnostics.session.stop")),
    ("job.submit", leaf("job.submit")),
    ("job.timeline", leaf("job.timeline")),
    ("operation.describe", leaf("operation.describe")),
    ("operation.list", leaf("operation.list")),
    (
        "recovery.flash-invocation.list",
        leaf("recovery.flash-invocation.list"),
    ),
    ("runtime.bundle.inspect", leaf("runtime.bundle.inspect")),
    ("runtime.bundle.list", leaf("runtime.bundle.list")),
    (
        "runtime.bundle.register",
        Leaf(Fronted {
            command: "runtime.bundle.register",
            note: Some(
                "The Rust CLI uses this typed RPC; the Swift bootstrap CLI retains its local registration owner.",
            ),
            ..FRONTED
        }),
    ),
    ("runtime.bundle.remove", leaf("runtime.bundle.remove")),
    (
        "runtime.hdc.impact-preview",
        leaf("runtime.hdc.impact-preview"),
    ),
    ("runtime.hdc.restart", leaf("runtime.hdc.restart")),
    ("runtime.hdc.status", leaf("runtime.hdc.status")),
    ("runtime.storage.policy", leaf("runtime.storage.policy")),
    ("runtime.storage.root", leaf("runtime.storage.root")),
    ("runtime.storage.status", leaf("runtime.storage.status")),
    ("runtime.tool.inspect", leaf("runtime.tool.inspect")),
    ("runtime.tool.list", leaf("runtime.tool.list")),
    (
        "runtime.tool.register",
        Leaf(Fronted {
            command: "runtime.tool.register",
            note: Some(
                "Only --kind deveco is served by this RPC; --kind hdc retains its in-process Bootstrap registration.",
            ),
            ..FRONTED
        }),
    ),
    ("runtime.tool.remove", leaf("runtime.tool.remove")),
    ("runtime.tool.select", leaf("runtime.tool.select")),
    ("session.cleanup.apply", leaf("session.cleanup.apply")),
    ("session.cleanup.preview", leaf("session.cleanup.preview")),
    ("session.export.apply", leaf("session.export.apply")),
    ("session.export.preview", leaf("session.export.preview")),
    ("session.list", leaf("session.list")),
    ("session.pin", leaf("session.pin")),
    ("session.show", leaf("session.show")),
    ("session.unpin", leaf("session.unpin")),
    ("target.adopt", leaf("target.adopt")),
    ("target.availability", leaf("target.availability")),
    (
        "target.display-name.clear",
        leaf("target.display-name.clear"),
    ),
    ("target.display-name.set", leaf("target.display-name.set")),
    ("target.list", leaf("target.list")),
    ("target.show", leaf("target.show")),
    ("trace.cache.purge", leaf("trace.cache.purge")),
    ("trace.cache.status", leaf("trace.cache.status")),
    ("trace.inspect", leaf("trace.inspect")),
    ("trace.probe", leaf("trace.probe")),
    ("workspace.preset.list", leaf("workspace.preset.list")),
    (
        "workspace.preset.register",
        leaf("workspace.preset.register"),
    ),
    ("workspace.preset.remove", leaf("workspace.preset.remove")),
    ("workspace.preset.show", leaf("workspace.preset.show")),
    ("workspace.preset.update", leaf("workspace.preset.update")),
    ("workspace.project.list", leaf("workspace.project.list")),
    (
        "workspace.project.register",
        leaf("workspace.project.register"),
    ),
    ("workspace.project.remove", leaf("workspace.project.remove")),
    ("workspace.project.show", leaf("workspace.project.show")),
    ("workspace.project.update", leaf("workspace.project.update")),
];

/// Swift `FeatureCoverage.localRoots` and its siblings: the leaves that are
/// §18 `local`, bounded, versioned host-side product resources shared with
/// the App, which never change Runtime authority. Every other executable leaf
/// is `direct`.
const LOCAL_ROOTS: &[&str] = &[
    "help",
    "commands",
    "completion",
    "session",
    "history",
    "agentd",
    "signing",
    "update-feed",
    "maintainer",
];
const LOCAL_RUNTIME_GROUPS: &[&str] = &[
    "storage",
    "update",
    "support-bundle",
    "tool",
    "bundle",
    "service",
    "signing",
];
const LOCAL_COMMANDS: &[&str] = &[
    "trace.cache.status",
    "trace.cache.purge",
    "trace.inspect",
    "trace.export",
    "ui-dump.inspect",
    "ui-dump.hit-test",
    "diagnostics.inspect",
    "diagnostics.session.status",
    "diagnostics.session.mark",
    "diagnostics.session.stop",
    "diagnostics.preview",
    "diagnostics.export",
    "artifact.quota",
    "artifact.list",
    "artifact.inspect",
    "artifact.read",
    "artifact.export",
    "device.display-name.set",
    "device.display-name.clear",
    "target.display-name.set",
    "target.display-name.clear",
    "workspace.continuation.inspect",
    "debug.template.list",
    "legacy.flash.status",
    "legacy.flash.reconcile",
    "flash.status",
    "flash.reconcile",
    "flash.install-binding",
];
const LOCAL_COMMAND_PREFIXES: &[&str] = &["workspace.project.", "workspace.preset."];
/// Runtime-owned selections under an otherwise local group.
const DIRECT_UNDER_LOCAL_GROUPS: &[&str] = &["runtime.tool.select"];

/// Swift `FeatureCoverage.macOSOnlyRoots` and `macOSOnlyRuntimeGroups`: the
/// host-specific families with no Windows form until a Windows profile is
/// ratified (§11).
const MACOS_ONLY_ROOTS: &[&str] = &["legacy", "agentd", "signing", "update-feed", "maintainer"];
// `runtime service` is not one: its Windows counterpart is the
// client-started daemon (maintainer ruling 10, launchd -> client-started
// daemon), whose `status`, `verify`, `restart` and `uninstall` Windows serves;
// `install` and `update` stay refused there (`MACOS_HOST_LEAVES`).
const MACOS_ONLY_RUNTIME_GROUPS: &[&str] = &["signing", "update", "support-bundle"];

/// The Runtime leaves whose every method the Windows daemon answers, measured
/// end to end on Windows: the CLI authenticates a daemon signed with a
/// host-trusted development signer over the named pipe and renders its
/// answer (`check-readonly.py` `signed_windows_matrix`, `tests/
/// windows_signed_runtime.rs`, and the owners' `arkdeck-agentd/tests/
/// windows_*_process.rs` signed-CLI tests, each of which checks that what it
/// measured is `implemented` here; TASK-XPA-018).
const WINDOWS_MEASURED_LEAVES: &[&str] = &[
    "doctor",
    "runtime.health",
    "operation.list",
    // The Catalog reads of one operation (`observe.device@1`); they dispatch
    // nothing.
    "operation.describe",
    "operation.example",
    "operation.validate",
    // The Job store, runner and reconciler over recorded Swift Jobs
    // (TASK-XPA-005; `windows_job_store_process.rs`,
    // `windows_job_runner_process.rs`, `windows_reconcile_agent_process.rs`).
    // Not `job plan`, `job submit` or `job run`: without a registered HDC
    // a new device Job is refused before admission or before its run.
    "job.list",
    "job.show",
    "job.status",
    "job.events",
    "job.timeline",
    "job.result",
    "job.evidence",
    "job.wait",
    "job.cancel",
    "job.reconcile",
    // The agent execution and human-action owners over Swift's
    // physical-assistance records (TASK-XPA-005). Not `agent run`, `agent
    // resume` or `human-action resume`; `agent abandon` is counted. See the
    // GJ-1 leaves below.
    "agent.list",
    "agent.status",
    "human-action.list",
    "human-action.show",
    // The Artifact owner over a recorded Job's Artifacts (TASK-XPA-006;
    // `windows_artifact_owner_process.rs`).
    "artifact.list",
    "artifact.inspect",
    "artifact.read",
    "artifact.export",
    "artifact.quota",
    // The capability store's reads (`windows_mutation_retention_process.rs`,
    // and Swift's capability-read oracle store in
    // `windows_reconcile_agent_process.rs`).
    "capability.list",
    "capability.inspect",
    // The Session and storage owners over recorded Swift Sessions
    // (TASK-XPA-005/014; `windows_session_owner_process.rs`).
    "runtime.storage.status",
    "runtime.storage.policy",
    "runtime.storage.root",
    "session.list",
    "session.show",
    "session.pin",
    "session.unpin",
    "session.export.preview",
    "session.export.apply",
    "session.cleanup.preview",
    "session.cleanup.apply",
    // The Target store (TASK-XPA-004): its reads and display names.
    // `target adopt` and `target availability` are measured below.
    "target.list",
    "target.show",
    "target.display-name.set",
    "target.display-name.clear",
    // The Target observation owner over the registered Windows HDC
    // (CHG-2026-078 c2, TASK-XPA-005): `device candidates` read through the
    // daemon's managed DevEco `hdc.exe` by the Windows registry's grammar,
    // the host's UART rows excluded (`windows_hdc_live_process.rs`, over
    // `ARKDECK_LIVE_WINDOWS_HDC`; the c2 capture replayed in
    // `arkdeck-hoststore/tests/windows_target_owners.rs`), and `target adopt`
    // of the DAYU200 it proves, measured with the board attached on
    // 2026-10-04 through the real CLI and daemon (the same process test).
    "device.candidates",
    "target.adopt",
    // GJ-1's device reads (TASK-XPA-005): the Swift Target adoption oracle
    // replayed through the real CLI against the signed test daemon, over the
    // shared fake HDC and a synthetic census plugging each exchange's boards
    // (`tests/spawning/gj1_device_reads.rs`): every observation, adoption and
    // `target availability` answers as Swift's daemon answered it, and the
    // fake's calls, Target document and display names are Swift's. Then
    // `device wait` proves the adopted board's exact observation (or stops at
    // its own deadline), and `device list` answers the Target list.
    "device.wait",
    "device.list",
    "target.availability",
    // `trace probe` (TASK-XPA-005): the Swift Trace probe oracle replayed
    // through the real CLI against the same signed test daemon, every answer
    // and the fake's reads Swift's (`gj1_device_reads.rs`).
    "trace.probe",
    // The registered Windows HDC's lifecycle (CHG-2026-078, TASK-XPA-005):
    // its status, a restart's impact preview, the restart's approval request
    // and, approved at a real console, the restart itself, then its control
    // action shown, reconciled and listed, by the real CLI against a
    // dev-signed daemon composing the registered DevEco `hdc.exe` as its
    // managed server (`arkdeck-platform/tests/windows_console_restart.rs`,
    // live with `ARKDECK_LIVE_WINDOWS_HDC`, which CI cannot run). Without a
    // live server, CI still runs the union control-action owner over the
    // Windows daemon's pipe (`windows_lifecycle_process.rs`) and the HDC
    // control-action owner's own tests (`arkdeck-hoststore`).
    "runtime.hdc.status",
    "runtime.hdc.impact-preview",
    "runtime.hdc.restart",
    "control-action.show",
    "control-action.reconcile",
    "control-action.list",
    // GJ-1's device leaves (TASK-XPA-005): `target observe`
    // (`observe.device@1`) and `diagnostics capture` (`capture.diagnostics@1`)
    // run end to end through the real signed CLI against a signed test
    // daemon, the production Windows composition with the shared fake HDC
    // in process and a synthetic census naming the oracle's board
    // (`arkdeck-agentd/tests/spawning/gj1_device_leaves.rs`); each Job's calls
    // are the Swift oracle's. A pause is kept and resumed there too.
    "target.observe",
    "diagnostics.capture",
    // The other leaves of `capture.diagnostics@1`, each a preset of its
    // inputs, over the same daemon with the Trace legs' fake: the screen, UI
    // dump and Trace captures (written, read back, received and removed under
    // the Runtime's mutation authority), the component detail and the logs
    // (`gj1_device_leaves.rs`); their legs replay Swift's oracles byte for
    // byte at owner level (`arkdeck-hoststore/tests/windows_gj1_replays.rs`).
    "screen.capture",
    "ui-dump.capture",
    "ui-dump.component-detail",
    "debug.logs",
    "trace.capture",
    // The interactive diagnostic session's live control (TASK-XPA-005):
    // `capture.diagnostic-session@1` submitted and run through the same CLI
    // and signed test daemon while `diagnostics session status|mark|stop`
    // read, mark and stop it, its Job and Artifacts the `diagnostic-session`
    // oracle's, and an unanchored ring's session interrupted
    // (`arkdeck-agentd/tests/spawning/diagnostic_session_cli.rs`). The
    // operation itself is reached through `job submit` alone, a generic
    // leaf.
    "diagnostics.session.status",
    "diagnostics.session.mark",
    "diagnostics.session.stop",
    // Not `agent resume` (nor `human-action resume`), although
    // `gj1_device_leaves.rs` runs it end to end over the Swift human-action
    // oracle's `connect` scenario: once its action resolves, a resume
    // submits the execution's operation through the same admission as
    // `agent run` and `job submit`, so its answer depends on that
    // operation, and these shared generic leaves are not counted until
    // every operation they reach on Windows answers as Swift does (the
    // lead's ruling of 2026-10-04, as for `flash run` below).
    // `agent abandon`, over the Swift human-action oracle's `trust` scenario
    // (`gj1_device_leaves.rs`): an execution paused on the device's trust
    // prompt, abandoned under its current generation (a stale one refused),
    // its expired action then refusing either resume. It is counted because
    // it acts on the existing execution alone: it moves the record to
    // `abandoned` and expires its waiting action, and refuses once the
    // execution owns a Job. It never submits or plans, so its answer does
    // not depend on which operation the execution runs.
    "agent.abandon",
    // The Debug probe over the Target store and the HDC (TASK-XPA-008;
    // `arkdeck-agentd/tests/spawning/debug_leaves_cli.rs`, the real CLI
    // against the signed test daemon over the Swift oracle's answers). Not
    // `debug template run`: it runs the `debug.template@1` Job, whose
    // admission observes the Target, and no Swift oracle records that Job's
    // HDC answers.
    "debug.probe",
    // The workspace registration owner (TASK-XPA-015): registration, the
    // reads, and the updates and removals the Job owner's workspace census
    // admits (`windows_workspace_projects_process.rs`), and the preset
    // registration: a build or test preset pins the host's DevEco toolchain
    // in the daemon's Bootstrap registry, measured over the host's DevEco
    // Studio (`ARKDECK_LIVE_DEVECO_ROOT`); a signing preset's credential
    // owner is composed by the account's daemon, as on macOS.
    "workspace.project.register",
    "workspace.project.list",
    "workspace.project.show",
    "workspace.project.update",
    "workspace.project.remove",
    "workspace.preset.list",
    "workspace.preset.show",
    "workspace.preset.update",
    "workspace.preset.remove",
    "workspace.preset.register",
    // The Trace cache owner's inventory and purge (TASK-XPA-021;
    // `windows_trace_export_process.rs`).
    "trace.cache.status",
    "trace.cache.purge",
    // The client-started service (TASK-XPA-002, decision 11), through the
    // real CLI against a signed daemon it starts itself
    // (`arkdeck-agentd/tests/windows_service_uninstall_process.rs`):
    // `uninstall` is its stop, with `restart`'s current-Job refusal.
    "runtime.service.status",
    "runtime.service.verify",
    "runtime.service.restart",
    "runtime.service.uninstall",
    // The Import owner (TASK-XPA-008; `windows_import_owner_process.rs`):
    // the HAP, native-library, workspace-patch and DAYU200 flash-bundle
    // uploads committed with their exact bytes (the flash bundle judged by
    // the Flash archive reader, TASK-XPA-010), and the Import reads, release
    // and abort.
    "artifact.import.hap",
    "artifact.import.native-library",
    "artifact.import.flash-bundle",
    "artifact.import.workspace-patch",
    "artifact.import.inspect",
    "artifact.import.list",
    "artifact.import.release",
    "artifact.import.abort",
    // The cleanup debt ledger over Swift's recorded debug HAP debts
    // (`windows_cleanup_debt_process.rs`), and its continuation: every debt
    // the Swift debug HAP and native library oracles continued, through both
    // spellings, by the real CLI against the signed test daemon over the
    // shared fake HDC, answered and left as Swift answered and left it
    // (`tests/spawning/gj23_replay.rs`, TASK-XPA-009).
    "recovery.cleanup.list",
    "cleanup-debt.list",
    "recovery.cleanup.continue",
    "cleanup-debt.continue",
    // GJ-2/GJ-3's domain leaves (TASK-XPA-009): `debug hap` and `debug native
    // deploy` observe the board the synthetic census names, submit and run
    // the oracle's first Job, and read its evidence and Artifacts, by the
    // real CLI against the same signed test daemon; the fake HDC receives,
    // after the leaf's observation reads, exactly the oracle Job's calls
    // (`tests/spawning/gj23_replay.rs`).
    "debug.hap",
    "debug.native.deploy",
    // The Bootstrap registry owners (`windows_bootstrap_owners_process.rs`):
    // a release-candidate package tree registered, inspected, listed and
    // retired as a daemon Bundle, and a DevEco toolchain's inspection,
    // listing and retirement. `runtime tool register` is measured below.
    "runtime.bundle.register",
    "runtime.bundle.inspect",
    "runtime.bundle.list",
    "runtime.bundle.remove",
    "runtime.tool.list",
    "runtime.tool.inspect",
    "runtime.tool.remove",
    // `runtime tool register`: the DevEco kind as above, and the HDC kind
    // over the account daemon's composition, an hdc.exe a tuple names
    // registered beside its selection and one no tuple names refused
    // (TASK-XPA-012; `arkdeck-agentd/tests/spawning/account_tool_selection.rs`).
    // Not `runtime tool select`: its impact reads the managed server's health
    // through the HDC lifecycle owner, which no Windows composition proves
    // healthy yet (#2501), so it answers only a drifted action.
    "runtime.tool.register",
    // A diagnostics capture's Artifacts the macOS Runtime recorded, exported
    // (`windows_diagnostics_export_process.rs`).
    "diagnostics.export",
    // The History filter owner over Swift's recorded filters (TASK-XPA-012;
    // `windows_history_filter_process.rs`).
    "history.filter.list",
    "history.filter.save",
    "history.filter.delete",
    // The analyzer provider's host-only analyses (TASK-XPA-011). Not the
    // ArkTrace analyses, which no ArkTrace distribution serves on Windows
    // (TASK-XPA-021).
    "analyze.crash-signature",
    "analyze.hilog-summary",
    // The workspace provider's source inspection (TASK-XPA-011), which needs
    // no profile.
    "workspace.inspect",
    // The profile-served reads, the isolated copy and the sweep (TASK-XPA-011):
    // the code-owned tools of the ruling of 2026-10-04 resolve the profile.
    "workspace.read",
    "workspace.status",
    "workspace.diff",
    "workspace.isolate",
    "workspace.sweep",
    // The workspace mutations on a Runtime-owned copy (TASK-XPA-011), under
    // the Runtime's own capability, through the installed composition.
    "workspace.patch",
    "workspace.revert",
    "workspace.checkpoint",
    // The Hvigor build of a Runtime-owned copy (TASK-XPA-011), with the
    // host's registered DevEco Studio, its search path led by the
    // toolchain's pinned JDK, through the real CLI against a dev-signed
    // installed-mode daemon
    // (`arkdeck-agentd/tests/windows_workspace_hvigor_live_process.rs`, run
    // with `ARKDECK_LIVE_DEVECO_ROOT`).
    "workspace.build",
    // The module's local unit tests in the same copy, through its test
    // preset, reaching the project's `ohpm` dependencies through the in-tree
    // junctions the copy recreates (the same live test).
    "workspace.test",
    // GJ-4 Flash (TASK-XPA-010): `flash.full-restore@1` run to a terminal
    // state through `flash run`, and the Flash host reads over the same
    // composition, by the real CLI against a signed copy of the daemon's test
    // build over its control pipe, with the Swift Flash run oracle's fake lane
    // and Rockchip host and an in-process fake HDC
    // (`tests/spawning/flash_socket_control.rs`). No board is flashed. The
    // shared generic leaves the same test drives (`agent run`, `job plan|
    // submit|run`) are not counted until every operation they reach on
    // Windows answers as Swift does (the lead's ruling of 2026-10-04 for
    // GJ-2/3).
    "flash.run",
    "flash.bootloader-status",
    "flash.prerequisites",
    // The Loader binding coordinator: `flash bind-loader` over the Swift Loader
    // binding oracle's state, by the same CLI against the same signed test
    // daemon (TASK-XPA-010).
    "flash.bind-loader",
    // The protected Flash recovery broker over the Flash invocation owner
    // (TASK-XPA-010): an invocation started, its pinned full restore executed
    // to a terminal state, shown and listed (`recovery flash-invocation …`
    // and `debug …`), by the same CLI against the same signed test daemon. Not `flash reconcile-alias`, whose reconciler the
    // CLI reaches but whose repair no fake lineage exercises there (the
    // flash-host-reads oracle replays it through the Windows Host).
    "recovery.flash-invocation.start",
    "recovery.flash-invocation.evaluate",
    "recovery.flash-invocation.status",
    "recovery.flash-invocation.list",
    // Their `debug start|evaluate|status` spellings, the same handlers.
    "debug.start",
    "debug.evaluate",
    "debug.status",
    // ArkForge's device access and the lane's plan preview (TASK-XPA-010):
    // through the same CLI against the same signed test daemon, over a
    // stand-in for `arkforged`'s public pipe (ArkForge's own codec and
    // transport) and a stand-in plan previewer, both in the test binary.
    "flash.device-access",
    "flash.lane-preview",
];

/// The leaves this CLI refuses off macOS (`unsupportedOnPlatform`; the
/// support bundle's service is `operationUnavailable`), each for the macOS
/// host primitive it needs and Windows does not have yet: the LaunchAgent
/// (`launchctl`), DevEco's password material, the App container's update lifecycle, the
/// diagnostic-bundle publisher, the update-feed artifact measure and the I/O
/// Registry USB census (TASK-XPA-018). The Import uploads are served on
/// Windows through the host store's `HostImportSource` (TASK-XPA-008).
const MACOS_HOST_LEAVES: &[&str] = &[
    // The LaunchAgent's own installation; the client-started daemon has none.
    "runtime.service.install",
    "runtime.service.update",
    "agentd.install",
    "agentd.update",
    "agentd.restart",
    "agentd.status",
    "agentd.verify",
    "agentd.uninstall",
    "runtime.update.check",
    "runtime.update.download",
    "runtime.update.handoff",
    "runtime.update.status",
    "runtime.update.cancel",
    "runtime.update.cleanup",
    "runtime.support-bundle.preview",
    "runtime.support-bundle.export",
    "maintainer.update-feed.prepare",
    "maintainer.update-feed.assemble",
    "update-feed.prepare",
    "update-feed.assemble",
];

/// The App's capability table as published, read once.
fn app_registry() -> &'static Value {
    static REGISTRY: OnceLock<Value> = OnceLock::new();
    REGISTRY.get_or_init(|| {
        serde_json::from_str(include_str!("app_capability_registry.json"))
            .expect("the checked-in App capability registry")
    })
}

fn array(value: &Value) -> &[Value] {
    value.as_array().map_or(&[], Vec::as_slice)
}

fn strings(value: &Value) -> Vec<&str> {
    array(value).iter().filter_map(Value::as_str).collect()
}

fn leaves() -> &'static [Value] {
    array(&command_registry::projection()["commands"])
}

fn command(leaf: &Value) -> &str {
    leaf["command"]
        .as_str()
        .expect("a leaf's canonical command")
}

fn path(leaf: &Value) -> Vec<&str> {
    strings(&leaf["path"])
}

fn executable(leaf: &Value) -> bool {
    leaf["kind"] == "executable"
}

fn ruling(method: &str) -> Option<&'static Ruling> {
    RULINGS
        .iter()
        .find(|(ruled, _)| *ruled == method)
        .map(|(_, ruling)| ruling)
}

/// Swift `LeafIndex.leaf`.
fn leaf_named(name: &str) -> &'static Value {
    leaves()
        .iter()
        .find(|leaf| command(leaf) == name)
        .unwrap_or_else(|| panic!("coverage names an unknown command {name}"))
}

/// Swift `LeafIndex.resolve(pattern:)`: the leaf an argv pattern such as
/// `arkdeck job status --job <id>` names.
fn resolve(pattern: &str) -> &'static Value {
    let mut tokens = pattern.split(' ').filter(|token| !token.is_empty());
    assert!(
        tokens.next() == Some("arkdeck"),
        "argv pattern does not start with arkdeck: {pattern}"
    );
    let mut walked: Vec<&str> = Vec::new();
    for token in tokens {
        if ["-", "<", "(", "["]
            .iter()
            .any(|prefix| token.starts_with(prefix))
            || token == "..."
        {
            break;
        }
        walked.push(token);
        if !leaves().iter().any(|leaf| path(leaf).starts_with(&walked)) {
            walked.pop();
            break;
        }
    }
    leaves()
        .iter()
        .find(|leaf| path(leaf) == walked)
        .unwrap_or_else(|| panic!("argv pattern does not name a command: {pattern}"))
}

/// Swift `FeatureCoverage.isLocal(path:command:)`.
fn is_local(path: &[&str], command: &str) -> bool {
    if DIRECT_UNDER_LOCAL_GROUPS.contains(&command) {
        return false;
    }
    path.first().is_some_and(|root| LOCAL_ROOTS.contains(root))
        || (path.len() > 1 && path[0] == "runtime" && LOCAL_RUNTIME_GROUPS.contains(&path[1]))
        || LOCAL_COMMANDS.contains(&command)
        || LOCAL_COMMAND_PREFIXES
            .iter()
            .any(|prefix| command.starts_with(prefix))
}

/// Swift `FeatureCoverage.classification(path:leaf:)`.
fn classification(leaf: &Value) -> &'static str {
    if !executable(leaf) {
        "refused"
    } else if is_local(&path(leaf), command(leaf)) {
        "local"
    } else {
        "direct"
    }
}

/// Swift `FeatureCoverage.lifecycle(of:)`, which the registry projects.
fn lifecycle(leaf: &Value) -> String {
    leaf["lifecycleStatus"]
        .as_str()
        .expect("a leaf's lifecycle")
        .to_owned()
}

/// Swift `FeatureCoverage.requiredPlatforms(path:leaf:)`.
fn required_platforms(leaf: &Value) -> Vec<&'static str> {
    let path = path(leaf);
    if path
        .first()
        .is_some_and(|root| MACOS_ONLY_ROOTS.contains(root))
        || (path.len() > 1 && path[0] == "runtime" && MACOS_ONLY_RUNTIME_GROUPS.contains(&path[1]))
        || leaf["lifecycleStatus"] == "legacy"
        || leaf["kind"] == "tombstone"
    {
        vec!["macos"]
    } else {
        PLATFORMS.to_vec()
    }
}

/// Swift `FeatureCoverage.targetCommand(path:leaf:)`: the exact argv that
/// reaches a leaf, its path, its required published options with their
/// placeholders, one member of each exactly-one group and its required
/// positionals.
fn target_command(leaf: &Value) -> String {
    let options = array(&leaf["options"]);
    let placeholder = |option: &Value| {
        (option["form"] == "value").then(|| {
            format!(
                "<{}>",
                option["placeholder"]
                    .as_str()
                    .expect("a value's placeholder")
            )
        })
    };
    let mut tokens: Vec<String> = vec!["arkdeck".into()];
    tokens.extend(path(leaf).into_iter().map(str::to_owned));
    for option in options {
        if option["required"] == true && option["published"] == true {
            tokens.push(option["name"].as_str().expect("an option's name").into());
            tokens.extend(placeholder(option));
        }
    }
    for group in array(&leaf["requiresExactlyOneOf"]) {
        let members: Vec<String> = strings(group)
            .into_iter()
            .map(|name| {
                match options
                    .iter()
                    .find(|option| option["name"] == name)
                    .and_then(placeholder)
                {
                    Some(value) => format!("{name} {value}"),
                    None => name.to_owned(),
                }
            })
            .collect();
        tokens.push(format!("({})", members.join(" | ")));
    }
    for positional in array(&leaf["positionals"]) {
        if positional["required"] == true {
            tokens.push(format!(
                "<{}>",
                positional["name"].as_str().expect("a positional's name")
            ));
        }
    }
    tokens.join(" ")
}

/// Swift `FeatureCoverage.fixture(for:)`.
fn fixture(leaf: &Value) -> String {
    format!("argv/{}.json", command(leaf))
}

/// Swift `FeatureCoverage.Entry`.
struct Entry {
    feature: String,
    source: String,
    classification: String,
    target_classification: String,
    lifecycle: String,
    target_command: Option<String>,
    equivalent_commands: Vec<String>,
    conformance_fixture: Option<String>,
    required_platforms: Vec<&'static str>,
    owner: Option<String>,
    note: Option<String>,
    /// The canonical commands the entry reaches; not written.
    referenced_leaves: Vec<String>,
}

impl Entry {
    /// An entry for a feature a leaf reaches, as the leaf is classified.
    fn of_leaf(feature: &str, source: String, leaf: &Value) -> Self {
        Self {
            feature: feature.into(),
            source,
            classification: classification(leaf).into(),
            target_classification: classification(leaf).into(),
            lifecycle: lifecycle(leaf),
            target_command: Some(target_command(leaf)),
            equivalent_commands: Vec::new(),
            conformance_fixture: Some(fixture(leaf)),
            required_platforms: required_platforms(leaf),
            owner: None,
            note: None,
            referenced_leaves: vec![command(leaf).into()],
        }
    }

    /// §14's closed status set: implemented on macOS, or `partial` where
    /// blocked. On Windows, what this CLI serves there:
    /// - `notImplemented` where a leaf the entry reaches is refused off macOS
    ///   ([`MACOS_HOST_LEAVES`]), or the entry reaches no leaf (a generic
    ///   Catalog operation reaches `job submit`, and is `partial`);
    /// - `implemented` where every leaf it reaches answers without the
    ///   Runtime (the registry's `connectsToRuntime`), as it does on macOS:
    ///   its argv fixtures replay and its answer is rendered alike on Windows;
    ///   or is answered by the Windows daemon and measured end to end there
    ///   ([`WINDOWS_MEASURED_LEAVES`]);
    /// - `partial` otherwise: the leaves parse, send their frames and render
    ///   their envelopes on Windows, but the target rests on a Runtime owner
    ///   the Windows daemon does not yet compose, or whose answer no Windows
    ///   run has yet measured end to end.
    fn implementation_status(&self, platform: &str) -> &'static str {
        match (platform, self.classification.as_str()) {
            ("macos", "blocked") => "partial",
            ("macos", _) => "implemented",
            _ => self.windows_status(),
        }
    }

    fn windows_status(&self) -> &'static str {
        let leaves: Vec<&Value> = self
            .referenced_leaves
            .iter()
            .map(|name| leaf_named(name))
            .collect();
        if leaves
            .iter()
            .any(|leaf| MACOS_HOST_LEAVES.contains(&command(leaf)))
        {
            "notImplemented"
        } else if leaves.is_empty() {
            // A generic Catalog operation is reached through `job submit`.
            if self.classification == "generic" {
                "partial"
            } else {
                "notImplemented"
            }
        } else if self.classification != "blocked"
            && leaves.iter().all(|leaf| {
                leaf["connectsToRuntime"] == false
                    || WINDOWS_MEASURED_LEAVES.contains(&command(leaf))
            })
        {
            "implemented"
        } else {
            "partial"
        }
    }

    fn document(&self) -> Value {
        let statuses: Map<String, Value> = self
            .required_platforms
            .iter()
            .map(|platform| {
                (
                    (*platform).to_owned(),
                    json!(self.implementation_status(platform)),
                )
            })
            .collect();
        let mut fields = json!({
            "feature": self.feature,
            "source": self.source,
            "classification": self.classification,
            "targetClassification": self.target_classification,
            "lifecycle": self.lifecycle,
            "targetCommand": self.target_command,
            "equivalentCommands": self.equivalent_commands,
            "conformanceFixture": self.conformance_fixture,
            "requiredPlatforms": self.required_platforms,
            "implementationStatusByPlatform": statuses,
        });
        if let Some(owner) = &self.owner {
            fields["owner"] = json!(owner);
        }
        if let Some(note) = &self.note {
            fields["note"] = json!(note);
        }
        fields
    }
}

/// Swift `FeatureCoverage.daemonEntry(method:coverage:index:)`.
fn daemon_entry(method: &str, ruling: &Ruling) -> Entry {
    let source = format!("daemon:{method}");
    match ruling {
        Leaf(fronted) => {
            let found = leaf_named(fronted.command);
            assert!(
                executable(found),
                "daemon method {method} is fronted by a non-executable leaf {}",
                fronted.command
            );
            let mut entry = Entry::of_leaf(method, source, found);
            for alias in fronted.also {
                let spelling = leaf_named(alias);
                assert!(
                    executable(spelling) && spelling["lifecycleStatus"] != "current",
                    "daemon method {method} names {alias} as a compatibility spelling, but it is current"
                );
                entry.equivalent_commands.push(target_command(spelling));
                entry.referenced_leaves.push((*alias).to_owned());
            }
            if let Some(lifecycle) = fronted.lifecycle {
                entry.lifecycle = lifecycle.into();
            }
            entry.note = fronted.note.map(str::to_owned);
            entry
        }
        Plumbing { behind, note } => {
            let mut entry = Entry::of_leaf(method, source, leaf_named(behind));
            entry.classification = "internal".into();
            entry.target_classification = "internal".into();
            entry.note = Some((*note).to_owned());
            entry
        }
    }
}

/// The Catalog's operations as Swift names them (`reference`, and the
/// operation an alias stands for), in reference order.
fn operations() -> Vec<(String, Option<String>)> {
    let catalog: Value =
        serde_json::from_str(CATALOG_CANONICAL_JSON).expect("the compiled Catalog");
    let mut operations: Vec<(String, Option<String>)> = array(&catalog)
        .iter()
        .map(|operation| {
            let id = operation["id"].as_str().expect("an operation's id");
            let reference = match operation["version"].as_u64() {
                Some(version) => format!("{id}@{version}"),
                None => id.to_owned(),
            };
            (reference, operation["aliasFor"].as_str().map(str::to_owned))
        })
        .collect();
    operations.sort();
    operations
}

/// Swift `FeatureCoverage.build()` over the control methods `methods`, in
/// feature order.
fn entries(methods: &[&str]) -> Vec<Entry> {
    let mut entries = Vec::new();
    // Daemon control methods.
    let mut methods = methods.to_vec();
    methods.sort_unstable();
    for method in methods {
        if let Some(ruling) = ruling(method) {
            entries.push(daemon_entry(method, ruling));
        }
    }
    // Published Catalog operations.
    let submit = leaf_named("job.submit");
    for (reference, alias) in operations() {
        let fronting: Vec<&Value> = leaves()
            .iter()
            .filter(|leaf| leaf["catalogOperation"] == reference.as_str())
            .collect();
        let source = format!("catalog:{reference}");
        let mut entry = match fronting.split_first() {
            Some((first, rest)) => {
                let mut entry = Entry::of_leaf(&reference, source, first);
                entry.equivalent_commands = rest.iter().map(|leaf| target_command(leaf)).collect();
                entry
                    .referenced_leaves
                    .extend(rest.iter().map(|leaf| command(leaf).to_owned()));
                entry
            }
            None => {
                for option in ["--operation", "--inputs-file"] {
                    assert!(
                        array(&submit["options"])
                            .iter()
                            .any(|declared| declared["name"] == option),
                        "job submit no longer accepts {option}; generic coverage is unreachable"
                    );
                }
                Entry {
                    feature: reference.clone(),
                    source,
                    classification: "generic".into(),
                    target_classification: "generic".into(),
                    lifecycle: "current".into(),
                    target_command: Some(format!(
                        "arkdeck job submit --operation {reference} --inputs-file <path>"
                    )),
                    equivalent_commands: Vec::new(),
                    conformance_fixture: Some(fixture(submit)),
                    required_platforms: PLATFORMS.to_vec(),
                    owner: None,
                    note: None,
                    referenced_leaves: Vec::new(),
                }
            }
        };
        if let Some(alias) = alias {
            entry.note = Some(format!("alias of {alias}"));
        }
        entries.push(entry);
    }
    // App product capabilities.
    let mut capabilities: Vec<&Value> = array(&app_registry()["capabilities"]).iter().collect();
    capabilities.sort_by_key(|capability| capability["id"].as_str());
    for capability in capabilities {
        let text = |key: &str| {
            capability[key]
                .as_str()
                .unwrap_or_else(|| panic!("an App capability's {key}"))
                .to_owned()
        };
        let patterns: Vec<String> = strings(&capability["cliEquivalent"])
            .into_iter()
            .map(str::to_owned)
            .collect();
        let resolved: Vec<&Value> = patterns.iter().map(|pattern| resolve(pattern)).collect();
        entries.push(Entry {
            feature: text("id"),
            source: format!("app:{}", text("surface")),
            classification: text("classification"),
            target_classification: text("classification"),
            lifecycle: "current".into(),
            target_command: patterns.first().cloned(),
            equivalent_commands: patterns.iter().skip(1).cloned().collect(),
            conformance_fixture: resolved.first().map(|leaf| fixture(leaf)),
            required_platforms: vec!["macos"],
            owner: Some(text("owner")),
            note: Some(text("title")),
            referenced_leaves: resolved
                .iter()
                .map(|leaf| command(leaf).to_owned())
                .collect(),
        });
    }
    // Leaves nothing above reaches: features in their own right.
    let referenced: BTreeSet<String> = entries
        .iter()
        .flat_map(|entry| entry.referenced_leaves.iter().cloned())
        .collect();
    for leaf in leaves() {
        let name = command(leaf);
        if referenced.contains(name) {
            continue;
        }
        let mut entry = Entry::of_leaf(name, format!("cli:{name}"), leaf);
        let text = |key: &str| leaf[key].as_str().map(str::to_owned);
        entry.note = match leaf["kind"].as_str() {
            Some("tombstone") => text("replacementArgvPattern")
                .map(|pattern| format!("replaced by `{pattern}`"))
                .or_else(|| text("replacementReason")),
            Some("refused") => text("refusalReason"),
            _ => text("replacementArgvPattern").map(|pattern| format!("superseded by `{pattern}`")),
        };
        entries.push(entry);
    }
    validate(&entries);
    entries.sort_by(|left, right| left.feature.cmp(&right.feature));
    entries
}

/// Swift `FeatureCoverage.validate(_:index:)`.
fn validate(entries: &[Entry]) {
    let mut features = BTreeSet::new();
    for entry in entries {
        assert!(
            features.insert(entry.feature.as_str()),
            "feature {} is covered twice",
            entry.feature
        );
        assert!(
            CLASSIFICATIONS.contains(&entry.classification.as_str())
                && CLASSIFICATIONS.contains(&entry.target_classification.as_str()),
            "feature {} uses an unknown classification",
            entry.feature
        );
        assert!(
            LIFECYCLES.contains(&entry.lifecycle.as_str()),
            "feature {} uses an unknown lifecycle {}",
            entry.feature,
            entry.lifecycle
        );
        assert!(
            entry.classification == entry.target_classification
                || entry.classification == "blocked",
            "feature {} claims a target it has not reached",
            entry.feature
        );
        for pattern in entry
            .target_command
            .iter()
            .chain(&entry.equivalent_commands)
        {
            resolve(pattern);
        }
        for name in &entry.referenced_leaves {
            leaf_named(name);
        }
    }
    for name in MACOS_HOST_LEAVES {
        leaf_named(name);
    }
    for name in WINDOWS_MEASURED_LEAVES {
        assert!(
            !MACOS_HOST_LEAVES.contains(name),
            "{name} is refused off macOS"
        );
        leaf_named(name);
    }
    let referenced: BTreeSet<&str> = entries
        .iter()
        .flat_map(|entry| entry.referenced_leaves.iter().map(String::as_str))
        .collect();
    for leaf in leaves() {
        assert!(
            referenced.contains(command(leaf)),
            "leaf {} is not covered",
            command(leaf)
        );
    }
}

/// Swift `FeatureCoverage.document(for:)`.
pub(crate) fn document() -> Value {
    document_for(METHODS)
}

fn document_for(methods: &[&str]) -> Value {
    let entries = entries(methods);
    let mut by_classification: BTreeMap<&str, u64> = BTreeMap::new();
    let mut by_source: BTreeMap<&str, u64> = BTreeMap::new();
    for entry in &entries {
        *by_classification.entry(&entry.classification).or_default() += 1;
        let kind = entry.source.split(':').next().unwrap_or_default();
        *by_source.entry(kind).or_default() += 1;
    }
    let blocked: Vec<&str> = entries
        .iter()
        .filter(|entry| entry.classification == "blocked")
        .map(|entry| entry.feature.as_str())
        .collect();
    json!({
        "schemaVersion": SCHEMA_VERSION,
        "bundleVersion": BUNDLE_VERSION,
        "cliVersion": crate::CLI_VERSION,
        "catalogDigest": CATALOG_DIGEST,
        "commandRegistrySchemaVersion":
            command_registry::projection()["commandRegistrySchemaVersion"],
        "appCapabilityRegistrySchemaVersion":
            app_registry()["appCapabilityRegistrySchemaVersion"],
        "classificationVocabulary": CLASSIFICATIONS,
        "lifecycleVocabulary": LIFECYCLES,
        "platformVocabulary": PLATFORMS,
        "summary": {
            "entries": entries.len(),
            "byClassification": by_classification,
            "bySource": by_source,
            "blocked": blocked,
            "fullFunction": blocked.is_empty(),
        },
        "entries": entries.iter().map(Entry::document).collect::<Vec<_>>(),
    })
}

/// Swift `appRegistryDocument`: the App's capability table with the bundle's
/// versions and the classification vocabulary.
pub(crate) fn app_registry_document() -> Value {
    let registry = app_registry();
    json!({
        "schemaVersion": registry["appCapabilityRegistrySchemaVersion"],
        "bundleVersion": BUNDLE_VERSION,
        "cliVersion": crate::CLI_VERSION,
        "classificationVocabulary": CLASSIFICATIONS,
        "capabilities": registry["capabilities"],
    })
}

/// What keeps the manifest from covering the compiled methods exactly: a
/// method without a ruling, or a ruling for no method.
pub(crate) fn problems() -> Vec<String> {
    problems_for(METHODS)
}

fn problems_for(methods: &[&str]) -> Vec<String> {
    let mut problems: Vec<String> = methods
        .iter()
        .filter(|method| ruling(method).is_none())
        .map(|method| format!("daemon method {method} has no coverage ruling"))
        .collect();
    problems.extend(
        RULINGS
            .iter()
            .filter(|(method, _)| !methods.contains(method))
            .map(|(method, _)| {
                format!("coverage names a daemon method the registry does not classify: {method}")
            }),
    );
    problems
}

#[cfg(test)]
mod tests {
    use super::{METHODS, document, document_for, problems_for};
    use serde_json::Value;

    fn windows(document: &Value, feature: &str) -> Value {
        document["entries"]
            .as_array()
            .unwrap()
            .iter()
            .find(|entry| entry["feature"] == feature)
            .unwrap_or_else(|| panic!("no entry {feature}"))["implementationStatusByPlatform"]
            ["windows"]
            .clone()
    }

    /// Windows' status is what this CLI serves there: a leaf without the
    /// Runtime is implemented, one whose target rests on a Runtime owner is
    /// partial, one refused off macOS is not implemented, and a macOS-only
    /// family has no Windows status.
    #[test]
    fn windows_status_follows_what_this_cli_serves_there() {
        let document = document();
        for (feature, status) in [
            ("commands", "implemented"),
            ("doctor", "implemented"),
            ("operation.list", "implemented"),
            ("target.show", "implemented"),
            ("workspace.project.register", "implemented"),
            ("trace.cache.status", "implemented"),
            ("health", "implemented"),
            ("job.status", "implemented"),
            ("session.cleanup.apply", "implemented"),
            // Measured over the registered Windows HDC (CHG-2026-078).
            ("target.adopt", "implemented"),
            // Measured over the Swift Target adoption oracle (TASK-XPA-005).
            ("target.availability", "implemented"),
            ("workspace.project.update", "implemented"),
            ("workspace.preset.register", "implemented"),
            ("trace.cache.purge", "implemented"),
            ("diagnostics.export", "implemented"),
            ("trace.inspect", "partial"),
            ("device.observations", "implemented"),
            ("job.submit", "partial"),
            ("agent.run", "partial"),
            ("agent.resume", "partial"),
            ("runtime.storage.root", "implemented"),
            ("help", "implemented"),
            ("completion", "implemented"),
            ("capability.install", "implemented"),
            ("artifact.import.list", "implemented"),
            ("artifact.import.release", "implemented"),
            ("human-action.resume", "partial"),
            ("agent.abandon", "implemented"),
            // A generic Catalog operation reached through `job submit`.
            ("flash.dayu200", "partial"),
            ("artifact.import.begin", "implemented"),
            ("artifact.import.workspace-patch", "implemented"),
            ("artifact.import.flash-bundle", "implemented"),
        ] {
            assert_eq!(windows(&document, feature), status, "{feature}");
        }
        // The client-started service: served but for its installation.
        for (feature, status) in [
            ("runtime.service.status", "implemented"),
            ("runtime.service.verify", "implemented"),
            ("runtime.service.restart", "implemented"),
            ("runtime.service.uninstall", "implemented"),
            ("runtime.service.install", "notImplemented"),
            ("runtime.service.update", "notImplemented"),
        ] {
            assert_eq!(windows(&document, feature), status, "{feature}");
        }
        // The retired spellings stay a macOS-only family.
        assert_eq!(windows(&document, "agentd.status"), Value::Null);
        for entry in document["entries"].as_array().unwrap() {
            let statuses = &entry["implementationStatusByPlatform"];
            if statuses["windows"] == "implemented" {
                assert_eq!(entry["classification"], entry["targetClassification"]);
                assert_eq!(statuses["macos"], "implemented");
            }
        }
    }

    /// A contract view may compile another method set than the rulings: the
    /// manifest covers methods it has a ruling for. Missing published methods
    /// and the deliberately altered pair are reported exactly, never hidden.
    #[test]
    fn another_method_set_is_covered_where_ruled_and_reported() {
        let mut methods: Vec<&str> = METHODS
            .iter()
            .copied()
            .filter(|method| *method != "job.status")
            .collect();
        methods.push("job.unruled");
        let document = document_for(&methods);
        let features: Vec<&str> = document["entries"]
            .as_array()
            .unwrap()
            .iter()
            .map(|entry| entry["feature"].as_str().unwrap())
            .collect();
        assert!(!features.contains(&"job.unruled"));
        assert_eq!(
            document["summary"]["bySource"]["daemon"],
            serde_json::json!(METHODS.len() - 1)
        );
        let mut expected = vec!["daemon method job.unruled has no coverage ruling".to_owned()];
        for method in [
            "job.archive",
            "job.archive.preview",
            "job.status",
            "diagnostic.session.status",
            "diagnostic.session.mark",
            "diagnostic.session.stop",
        ] {
            if !methods.contains(&method) {
                expected.push(format!(
                    "coverage names a daemon method the registry does not classify: {method}"
                ));
            }
        }
        assert_eq!(problems_for(&methods), expected);
    }
}
