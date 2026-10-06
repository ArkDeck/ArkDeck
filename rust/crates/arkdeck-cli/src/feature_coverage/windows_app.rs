//! Windows App evidence, distinct from a CLI-equivalent leaf's measurement.
//!
//! Maintainer ruling 10 makes these App targets Windows-required. The recorded
//! UIA flows below establish software surfaces, not device acceptance or an
//! installed-MSIX update. The exact registry join refuses an unreviewed new ID.
use serde_json::Value;
use std::collections::BTreeSet;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub(super) enum Status {
    Implemented,
    Partial,
    Deferred,
}

impl Status {
    pub(super) const fn as_str(self) -> &'static str {
        match self {
            Self::Implemented => "implemented",
            Self::Partial => "partial",
            Self::Deferred => "deferred",
        }
    }
}

pub(super) struct Surface {
    pub(super) id: &'static str,
    pub(super) status: Status,
    /// Existing GUI fixture, including its exact test case. A CLI argv fixture
    /// never fills this field. Absent/deferred surfaces have no passing fixture.
    pub(super) fixture: Option<&'static str>,
    pub(super) evidence: &'static str,
    pub(super) detail: &'static str,
}

impl Surface {
    pub(super) fn note(&self, title: &str) -> String {
        let fixture = self.fixture.map_or_else(
            || "No completed Windows GUI fixture for this target.".to_owned(),
            |fixture| format!("Windows GUI fixture: {fixture}."),
        );
        format!(
            "{title}. Windows App: {} {fixture} Evidence: {}. The argv conformance fixture covers the CLI equivalent, not the GUI.",
            self.detail, self.evidence
        )
    }
}

const fn surface(
    id: &'static str,
    status: Status,
    fixture: Option<&'static str>,
    evidence: &'static str,
    detail: &'static str,
) -> Surface {
    Surface {
        id,
        status,
        fixture,
        evidence,
        detail,
    }
}

use Status::{Deferred, Implemented, Partial};

// Paths are written in full in the output, so each claim remains reviewable
// without relying on this generator's comments or a CLI measurement table.
const A11Y: &str = concat!(
    "openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/",
    "TASK-XPA-020/winui-settings-a11y-run.md"
);
const DEVICE: &str = concat!(
    "openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/",
    "TASK-XPA-020/winui-device-trust-run.md"
);
const DEVICE_SCREEN: &str = concat!(
    "openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/",
    "TASK-XPA-020/winui-device-workspace-20261007-run.md"
);
const DEBUG: &str = concat!(
    "openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/",
    "TASK-XPA-020/winui-debug-run.md"
);
const REMOTE: &str = concat!(
    "openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/",
    "TASK-XPA-020/winui-remote-build-sources-run.md"
);
const FLASH: &str = concat!(
    "openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/",
    "TASK-XPA-020/winui-flash-run.md"
);
const TRACE: &str = concat!(
    "openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/",
    "TASK-XPA-021/winui-trace-viewer-run.md"
);
const DIAGNOSTICS: &str = concat!(
    "openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/",
    "TASK-XPA-020/winui-diagnostics-run.md"
);
const DIAGNOSTICS_CAPTURE: &str = concat!(
    "openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/",
    "TASK-XPA-020/windows-diagnostics-capture-20261007-run.md"
);
const TRACE_LICENSES: &str = concat!(
    "openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/",
    "TASK-XPA-020/winui-trace-licenses-20261007-run.md"
);
const TOOLCHAINS: &str = concat!(
    "openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/",
    "TASK-XPA-020/windows-toolchain-inventory-20261007-run.md"
);
const NATIVE_PANELS: &str = concat!(
    "openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/",
    "TASK-XPA-020/winui-native-panels-20261007-run.md"
);
const COMPONENT_MAPPING: &str = concat!(
    "openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/",
    "TASK-XPA-020/windows-component-mapping-20261007-run.md"
);
const HISTORY: &str = concat!(
    "openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/",
    "TASK-XPA-020/winui-history-filters-run.md"
);
const HANDOFF: &str = concat!(
    "openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/",
    "TASK-XPA-020/winui-history-handoff-run.md"
);
const INSPECTOR: &str = concat!(
    "openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/",
    "TASK-XPA-020/winui-job-inspector-run.md"
);
const RECOVERY: &str = concat!(
    "openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/",
    "TASK-XPA-020/winui-job-recovery-run.md"
);
const SCOPE: &str = concat!(
    "openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/",
    "TASK-XPA-020/winui-overview-scope-run.md"
);
const ENVIRONMENT: &str = concat!(
    "openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/",
    "TASK-XPA-020/winui-overview-hdc-run.md"
);
const AGENTS: &str = concat!(
    "openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/",
    "TASK-XPA-020/winui-agent-import-run.md"
);
const LOCAL: &str = concat!(
    "openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/",
    "TASK-XPA-020/winui-settings-local-run.md"
);
const STORAGE: &str = concat!(
    "openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/",
    "TASK-XPA-020/winui-settings-storage-run.md"
);
const KEYBOARD: &str = concat!(
    "openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/",
    "TASK-XPA-020/winui-keyboard-run.md"
);
const SURFACES_RUN: &str = concat!(
    "openspec/changes/chg-2026-074-shared-rust-runtime-core/evidence/runs/",
    "TASK-XPA-020/winui-surfaces-run.md"
);
const VIEWER_DEBT: &str = "openspec/changes/chg-2026-074-shared-rust-runtime-core/proposal.md";

const SNAPSHOT: Option<&str> =
    Some("windows/App.UITests/SemanticSnapshotTests.cs#PagesMatchTheirSemanticSnapshots");
const DEVICE_DETAILS: Option<&str> = Some(
    "windows/App.UITests/DeviceTrustFlowTests.cs#AnUnauthorizedDeviceIsWaitedForUntilItTrustsThisComputer",
);
const DEVICE_SCREEN_FLOW: Option<&str> = Some(
    "windows/App.UITests/DeviceScreenFlowTests.cs#CurrentPictureBecomesStaleAndNativeMovieKeepsMeasuredSpacing",
);
const DEBUG_ARTIFACTS: Option<&str> =
    Some("windows/App.UITests/DebugFlowTests.cs#AHapAndANativeLibraryAreChosenPlannedAndRun");
const DEBUG_LOGS: Option<&str> =
    Some("windows/App.UITests/DebugFlowTests.cs#ALogCaptureAndATemplateRunAsTypedJobs");
const REMOTE_FLOW: Option<&str> =
    Some("windows/App.UITests/RemoteSourcesFlowTests.cs#AServerIsVerifiedSavedBrowsedAndRemoved");
const FLASH_FLOW: Option<&str> = Some(
    "windows/App.UITests/FlashFlowTests.cs#AnArchiveIsReviewedPlannedAndFlashedWithTheOneNamedButton",
);
const VIEWER_FLOW: Option<&str> =
    Some("windows/App.UITests/ViewerFlowTests.cs#AViewIsCapturedAndInspected");
const TRACE_FLOW: Option<&str> =
    Some("windows/App.UITests/TraceFlowTests.cs#ACaptureOpensItsVerifiedTraceInTheViewer");
const TRACE_FILE: Option<&str> =
    Some("windows/App.UITests/TraceFlowTests.cs#ALocalTraceOpensAndJoinsTheRecentList");
const HISTORY_FLOW: Option<&str> = Some(
    "windows/App.UITests/HistoryFilterFlowTests.cs#ARecordShowsItsSummaryJournalCorrelationAndRecovery",
);
const EXPORT_FLOW: Option<&str> =
    Some("windows/App.UITests/SurfaceFlowTests.cs#TheExportPreviewNamesWhatWillBeWritten");
const LOCAL_FLOW: Option<&str> = Some(
    "windows/App.UITests/SettingsLocalFlowTests.cs#TheIconUpdatesAndTheDiagnosticBundleAreLocal",
);

pub(super) const SURFACES: &[Surface] = &[
    // Shell: the retired plane is a refusal, not a revived Automation route.
    surface(
        "app.shell.navigation",
        Implemented,
        SNAPSHOT,
        A11Y,
        "Navigation has named, invokable UIA surfaces.",
    ),
    surface(
        "app.shell.inspector",
        Implemented,
        Some("windows/App.UITests/JobInspectorFlowTests.cs#TheRelationTheResidueAndTheLogAreShown"),
        INSPECTOR,
        "Inspector chrome and its record details are exercised through UIA.",
    ),
    surface(
        "app.shell.recovery",
        Implemented,
        Some(
            "windows/App.UITests/JobRecoveryFlowTests.cs#RecordsThatNeedAPersonAreShownAndOpenInHistory",
        ),
        RECOVERY,
        "Recovery is rendered from Runtime records and handed to History.",
    ),
    surface(
        "app.automation.retired",
        Implemented,
        Some("windows/App.Tests/ShellContractTests.cs#TheAppHoldsNoRuntimeSemantics"),
        "docs/design/implementation-audit-2026-08-27.md",
        "The retired Automation plane has no App route or executor; the current Agents surface is separate.",
    ),
    surface(
        "app.design.components",
        Implemented,
        Some(
            "windows/App.Tests/WindowsComponentMappingTests.cs#EveryControlledExportAndAll32PreviewsHaveExactNativeProjectionReferences",
        ),
        COMPONENT_MAPPING,
        "All 59 controlled JS exports and 32 independently built previews have closed existing source/fixture mappings under accepted H.1/H.3 native semantic projection. Native accessibility/flow checks remain separate from source-reference closure. Retired Automation and the upstream canvas stay outside native capability claims; no production gallery route, pixel parity, Narrator-by-ear or hardware completion is claimed.",
    ),
    surface(
        "app.system.panels",
        Implemented,
        Some(
            "windows/App.UITests/NativePanelsFlowTests.cs#NativeSaveCancelWritesNothingAndConfirmedExportPreservesWholeArtifact",
        ),
        NATIVE_PANELS,
        "The existing native file-open, actual Save and Folder dialogs are exercised through UIA. Cancellation preserves the destination; confirmed Save matches every source byte and SHA, and explicit support export binds the selected parent and complete approved scope. No picker override or hardware result is claimed.",
    ),
    // Device software UI checks remain distinct from real-device acceptance.
    surface(
        "app.device.details",
        Implemented,
        DEVICE_DETAILS,
        DEVICE,
        "Observed facts and target details have a UIA path.",
    ),
    surface(
        "app.device.rename",
        Implemented,
        Some("windows/App.UITests/SurfaceFlowTests.cs#ATargetIsRenamedAndClearedThroughTheRuntime"),
        SURFACES_RUN,
        "Generation-bound target naming is exercised through the UI.",
    ),
    surface(
        "app.device.trust",
        Implemented,
        DEVICE_DETAILS,
        DEVICE,
        "Trust instructions, bounded wait and fresh observation are exercised through UIA. The adopted App scope keeps Target adoption in its foreground CLI handoff; it adds no GUI identity authority.",
    ),
    surface(
        "app.device.control",
        Implemented,
        DEVICE_SCREEN_FLOW,
        DEVICE_SCREEN,
        "Confirmed-bound pointer and private keyboard input invalidate the current picture; incomplete outcomes never resend. Host Core/UIA checks do not establish hardware acceptance.",
    ),
    surface(
        "app.device.recording",
        Implemented,
        DEVICE_SCREEN_FLOW,
        DEVICE_SCREEN,
        "Whole verified screenshot/sequence readers and measured native Windows Media composition are exercised through Core/UIA; explicit movie export rechecks the whole local derivative.",
    ),
    surface(
        "app.device.events",
        Implemented,
        DEVICE_SCREEN_FLOW,
        DEVICE_SCREEN,
        "Live device-pixel coordinates and confirmed/stale input feedback are rendered in the screen workspace; the UIA flow observes the exact input result and refusal.",
    ),
    // Overview and the Runtime-owned workspaces.
    surface(
        "app.overview.main",
        Implemented,
        Some("windows/App.UITests/OverviewScopeFlowTests.cs#TheOnlineDeviceAndItsServerAreInScope"),
        SCOPE,
        "Current-target scope and next-step presentation are exercised through UIA.",
    ),
    surface(
        "app.overview.environment",
        Implemented,
        Some(
            "windows/App.UITests/OverviewEnvironmentFlowTests.cs#TheEnvironmentShowsTheRuntimesHdcAndTheDeviceInScope",
        ),
        ENVIRONMENT,
        "Runtime/HDC and device environment facts are rendered in scope.",
    ),
    surface(
        "app.overview.resume",
        Implemented,
        Some("windows/App.UITests/AgentImportFlowTests.cs#AHumanActionIsResumedWithOneOfItsValues"),
        AGENTS,
        "The waiting execution is resumed through the Runtime-owned human-action UI.",
    ),
    surface(
        "app.overview.hdcImpact",
        Implemented,
        Some(
            "windows/App.UITests/OverviewEnvironmentFlowTests.cs#TheEnvironmentShowsTheRuntimesHdcAndTheDeviceInScope",
        ),
        ENVIRONMENT,
        "The Runtime impact projection is read and displayed, with no App-owned restart.",
    ),
    surface(
        "app.flash.main",
        Implemented,
        FLASH_FLOW,
        FLASH,
        "Prerequisites and board access are reviewed in the scripted UI flow; this is not hardware acceptance.",
    ),
    surface(
        "app.flash.plan",
        Implemented,
        FLASH_FLOW,
        FLASH,
        "The exact Runtime plan is reviewed in the UI flow.",
    ),
    surface(
        "app.flash.runtime",
        Implemented,
        FLASH_FLOW,
        FLASH,
        "The single named typed action and its timeline are exercised over the fixture provider.",
    ),
    surface(
        "app.debug.artifacts",
        Implemented,
        DEBUG_ARTIFACTS,
        DEBUG,
        "Native import, plan and typed submission are exercised through UIA.",
    ),
    surface(
        "app.debug.plan",
        Implemented,
        DEBUG_ARTIFACTS,
        DEBUG,
        "Deployment plan review is exercised through UIA.",
    ),
    surface(
        "app.debug.apps",
        Implemented,
        DEBUG_ARTIFACTS,
        DEBUG,
        "HAP selection and typed Job submission are exercised through UIA.",
    ),
    surface(
        "app.debug.logs",
        Implemented,
        DEBUG_LOGS,
        DEBUG,
        "The bounded HiLog request and result are exercised through UIA.",
    ),
    surface(
        "app.debug.logConfirm",
        Implemented,
        DEBUG_LOGS,
        DEBUG,
        "The HiLog confirmation is exercised through UIA.",
    ),
    surface(
        "app.debug.commands",
        Implemented,
        DEBUG_LOGS,
        DEBUG,
        "The closed template selection and typed Job are exercised through UIA.",
    ),
    surface(
        "app.debug.network",
        Implemented,
        Some("windows/App.UITests/DebugFlowTests.cs#APortRuleIsAddedAndDeletedThroughTheRuntime"),
        DEBUG,
        "Typed forwarding creation and removal are exercised through UIA.",
    ),
    surface(
        "app.debug.browser",
        Implemented,
        REMOTE_FLOW,
        REMOTE,
        "Remote browsing is exercised with real loopback SSH and Credential Manager, not inferred from import CLI parity.",
    ),
    // UI dump Viewer is implemented; the rich Trace viewer is a different debt.
    surface(
        "app.viewer.main",
        Implemented,
        VIEWER_FLOW,
        TRACE,
        "UI dump capture and its verified host presentation are exercised through UIA.",
    ),
    surface(
        "app.viewer.properties",
        Implemented,
        VIEWER_FLOW,
        TRACE,
        "Node properties are exercised through UIA.",
    ),
    surface(
        "app.viewer.layout",
        Implemented,
        VIEWER_FLOW,
        TRACE,
        "Bounds and hit testing are exercised through UIA.",
    ),
    surface(
        "app.viewer.accessibility",
        Implemented,
        VIEWER_FLOW,
        TRACE,
        "The accessibility tree and inspector are exercised through UIA.",
    ),
    surface(
        "app.viewer.raw",
        Implemented,
        VIEWER_FLOW,
        TRACE,
        "Verified raw dump text is inspected in the UI.",
    ),
    surface(
        "app.viewer.advanced",
        Implemented,
        VIEWER_FLOW,
        TRACE,
        "The component-detail dump and search are exercised through UIA.",
    ),
    surface(
        "app.trace.capture",
        Implemented,
        TRACE_FLOW,
        TRACE,
        "Bounded typed capture and whole-Artifact opening are exercised through UIA.",
    ),
    surface(
        "app.trace.runtime",
        Implemented,
        TRACE_FLOW,
        TRACE,
        "Runtime availability and structured refusal are exercised through UIA.",
    ),
    surface(
        "app.trace.artifact",
        Implemented,
        EXPORT_FLOW,
        SURFACES_RUN,
        "Published Trace Artifacts use History's verified export UI; no separate Trace-page export button is claimed.",
    ),
    surface(
        "app.traceViewer.recent",
        Implemented,
        TRACE_FILE,
        TRACE,
        "Local opening and recent-file maintenance are exercised through UIA.",
    ),
    surface(
        "app.traceViewer.loading",
        Implemented,
        TRACE_FLOW,
        TRACE,
        "Whole-Artifact preparation and explicit parser-unavailable state are implemented.",
    ),
    surface(
        "app.traceViewer.shortcuts",
        Deferred,
        None,
        VIEWER_DEBT,
        "TASK-XPA-021 / accepted decision 5 and Windows ruling 66 defer rich-viewer shortcuts with timeline/search/zoom/annotation. Existing capture/open/reload keyboard commands are measured under their separate delivered menu targets.",
    ),
    surface(
        "app.traceViewer.timeline",
        Deferred,
        None,
        VIEWER_DEBT,
        "TASK-XPA-021 / accepted decision 5 defers rich timeline rendering; capture/inspect/export does not prove it.",
    ),
    surface(
        "app.traceViewer.event",
        Deferred,
        None,
        VIEWER_DEBT,
        "TASK-XPA-021 / accepted decision 5 defers rich Trace event details.",
    ),
    surface(
        "app.traceViewer.range",
        Deferred,
        None,
        VIEWER_DEBT,
        "TASK-XPA-021 / accepted decision 5 defers rich Trace range selection.",
    ),
    surface(
        "app.traceViewer.annotation",
        Deferred,
        None,
        VIEWER_DEBT,
        "TASK-XPA-021 / accepted decision 5 defers rich Trace annotations.",
    ),
    surface(
        "app.menu.trace.capture",
        Implemented,
        Some(
            "windows/App.UITests/KeyboardCommandFlowTests.cs#CtrlFFindsTheSearchAndCtrlNOpensTrace",
        ),
        KEYBOARD,
        "The Windows capture command is wired to the Trace workspace.",
    ),
    surface(
        "app.menu.trace.open",
        Implemented,
        TRACE_FILE,
        TRACE,
        "The Windows open command uses the real file dialog and recent list.",
    ),
    surface(
        "app.menu.trace.reload",
        Implemented,
        Some("windows/App.UITests/KeyboardCommandFlowTests.cs#CtrlRReadsThePageAgain"),
        KEYBOARD,
        "The Windows reload command re-reads the current surface.",
    ),
    surface(
        "app.menu.trace.filterProcesses",
        Deferred,
        None,
        VIEWER_DEBT,
        "TASK-XPA-021 / accepted decision 5 defers the rich process-filter command.",
    ),
    surface(
        "app.menu.trace.searchEvents",
        Deferred,
        None,
        VIEWER_DEBT,
        "TASK-XPA-021 / accepted decision 5 defers the rich event-search command.",
    ),
    surface(
        "app.menu.help.traceShortcuts",
        Deferred,
        None,
        VIEWER_DEBT,
        "TASK-XPA-021 / accepted decision 5 defers the complete rich-viewer shortcuts help.",
    ),
    // The live one-Job flow has its own evidence, separate from saved-record readers.
    surface(
        "app.diagnostics.capture",
        Implemented,
        Some(
            "windows/App.UITests/DiagnosticCaptureFlowTests.cs#OneInteractiveCaptureKeepsItsOwnerAcrossNavigationAndOpensItsOwnHistory",
        ),
        DIAGNOSTICS_CAPTURE,
        "One bounded published capture, Mark/Stop, actual Recording/Closed UIA notifications, owner retention and immutable History are exercised through Core and UIA. These host software checks do not establish hardware acceptance.",
    ),
    surface(
        "app.diagnostics.reader",
        Implemented,
        Some("windows/App.UITests/DiagnosticsFlowTests.cs#ASavedSessionIsOpenedFromHistoryAndRead"),
        DIAGNOSTICS,
        "Saved session marks, timeline and explicit text previews are exercised through UIA.",
    ),
    surface(
        "app.diagnostics.hilogSummary",
        Implemented,
        Some(
            "windows/App.UITests/DiagnosticsFlowTests.cs#ASavedHilogSummaryIsOpenedFromHistoryAndVerified",
        ),
        DIAGNOSTICS,
        "The saved verified HiLog summary and provenance are exercised through UIA.",
    ),
    surface(
        "app.diagnostics.concept",
        Implemented,
        Some("windows/App.UITests/DiagnosticsFlowTests.cs#WithoutARecordThePageSaysHowToOpenOne"),
        DIAGNOSTICS,
        "The no-record concept/next-step presentation is exercised through UIA.",
    ),
    surface(
        "app.history.list",
        Implemented,
        Some(
            "windows/App.UITests/HistoryFilterFlowTests.cs#TheListIsFilteredPagedAndItsFilterSaved",
        ),
        HISTORY,
        "Paged Job history is exercised through UIA.",
    ),
    surface(
        "app.history.filters",
        Implemented,
        Some(
            "windows/App.UITests/HistoryFilterFlowTests.cs#TheListIsFilteredPagedAndItsFilterSaved",
        ),
        HISTORY,
        "Saved filters are exercised through UIA.",
    ),
    surface(
        "app.history.detail",
        Implemented,
        HISTORY_FLOW,
        HISTORY,
        "Summary, evidence and Journal correlation are exercised through UIA.",
    ),
    surface(
        "app.history.export",
        Implemented,
        EXPORT_FLOW,
        SURFACES_RUN,
        "Verified Artifact and preview-bound Session export have UI surfaces; native-picker completeness is tracked separately.",
    ),
    surface(
        "app.history.context",
        Implemented,
        Some(
            "windows/App.UITests/HistoryHandoffFlowTests.cs#ACaptureRecordReopensInTraceAndInDiagnostics",
        ),
        HANDOFF,
        "Workspace context is handed to the actual captured-record readers through UIA.",
    ),
    // Remote sources are delivered (ruling 68), unlike the old architecture row.
    surface(
        "app.settings.general",
        Implemented,
        LOCAL_FLOW,
        LOCAL,
        "App-local icon preferences are exercised through UIA.",
    ),
    surface(
        "app.settings.toolchains",
        Implemented,
        Some(
            "windows/App.UITests/ToolchainInventoryFlowTests.cs#CompleteInventoryShowsBothPagesAndRuntimeSelectedFacts",
        ),
        TOOLCHAINS,
        "Read-only HDC/tool/project/preset and bounded complete Bundle inventory are measured through bilingual UIA, including exact selected facts and honest empty/refused states. Registration, selection and lifecycle remain the existing foreground CLI handoff; displayed trust does not grant authority.",
    ),
    surface(
        "app.settings.servers",
        Implemented,
        REMOTE_FLOW,
        REMOTE,
        "Server verification and persistence are exercised through UIA with real loopback SSH.",
    ),
    surface(
        "app.settings.serverEditor",
        Implemented,
        REMOTE_FLOW,
        REMOTE,
        "Host-key-pinned editing and Credential Manager storage are exercised through UIA.",
    ),
    surface(
        "app.settings.serverDelete",
        Implemented,
        REMOTE_FLOW,
        REMOTE,
        "Remote-source removal is exercised through UIA.",
    ),
    surface(
        "app.settings.storage",
        Implemented,
        Some(
            "windows/App.UITests/SettingsWriteFlowTests.cs#ThePolicyAndThePurgeAreConfirmedAndTheRuntimeAnswers",
        ),
        STORAGE,
        "Generation-bound storage policy/root actions are exercised through UIA.",
    ),
    surface(
        "app.settings.traceCache",
        Implemented,
        Some(
            "windows/App.UITests/SettingsWriteFlowTests.cs#ThePolicyAndThePurgeAreConfirmedAndTheRuntimeAnswers",
        ),
        STORAGE,
        "Inactive derived-cache purge is exercised through UIA.",
    ),
    surface(
        "app.settings.traceLicenses",
        Implemented,
        Some(
            "windows/App.UITests/TraceLicensesFlowTests.cs#TraceLicensesDisplaysAndSelectsFullOriginalLocalTextWithoutWritingIt",
        ),
        TRACE_LICENSES,
        "Lazy local legal resources, complete original CRLF/Unicode text and native selection are measured in isolated App copies; missing Windows ArkTrace release content remains honestly unavailable. Fixtures do not establish bundle provenance.",
    ),
    surface(
        "app.settings.updates",
        Partial,
        LOCAL_FLOW,
        LOCAL,
        "The MSIX update API is implemented, but the measured UI fixture covers only the unpackaged refusal; installed update validation remains open.",
    ),
    surface(
        "app.settings.diagnostics",
        Implemented,
        LOCAL_FLOW,
        LOCAL,
        "Support-bundle preview and approved-scope export are exercised through UIA, excluding device raw.",
    ),
];

pub(super) fn for_id(id: &str) -> &'static Surface {
    SURFACES
        .iter()
        .find(|surface| surface.id == id)
        .unwrap_or_else(|| panic!("App capability {id} has no Windows App coverage"))
}

pub(super) fn validate(capabilities: &[Value]) {
    let mut mapped = BTreeSet::new();
    for surface in SURFACES {
        assert!(
            mapped.insert(surface.id),
            "App coverage {} is duplicated",
            surface.id
        );
        assert!(!surface.detail.is_empty() && !surface.evidence.is_empty());
        if surface.status == Implemented {
            assert!(
                surface.fixture.is_some(),
                "{} has no GUI fixture",
                surface.id
            );
        }
        if surface.status == Deferred {
            assert!(
                surface.fixture.is_none(),
                "{} claims a fixture for an absent target",
                surface.id
            );
        }
    }
    let mut registered = BTreeSet::new();
    for capability in capabilities {
        let id = capability["id"].as_str().expect("an App capability ID");
        assert!(registered.insert(id), "App registry {id} is duplicated");
        for_id(id);
    }
    assert_eq!(
        registered, mapped,
        "Windows App coverage has an orphan or missing registry ID"
    );
}

#[cfg(test)]
mod tests {
    use super::{SURFACES, Status, for_id, validate};
    use serde_json::json;

    #[test]
    fn every_gui_claim_names_an_exact_windows_fixture_and_record() {
        for surface in SURFACES {
            let evidence = surface.evidence.split('#').next().unwrap();
            assert!(evidence.starts_with("openspec/") || evidence.starts_with("docs/"));
            assert!(!evidence.contains(".."));
            if let Some(fixture) = surface.fixture {
                let (path, case) = fixture.split_once('#').expect("an exact GUI test case");
                assert!(
                    path.starts_with("windows/App.UITests/")
                        || path.starts_with("windows/App.Tests/")
                );
                assert!(path.ends_with(".cs") && !path.contains(".."));
                assert!(
                    !case.is_empty() && case.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
                );
            }
        }
    }

    #[test]
    fn unknown_duplicate_and_orphan_app_ids_are_refused() {
        let registered: Vec<_> = SURFACES
            .iter()
            .map(|surface| json!({"id": surface.id}))
            .collect();
        validate(&registered);
        let mut unknown = registered.clone();
        unknown[0] = json!({"id": "app.unreviewed"});
        assert!(std::panic::catch_unwind(|| validate(&unknown)).is_err());
        let mut duplicate = registered.clone();
        duplicate.push(registered[0].clone());
        assert!(std::panic::catch_unwind(|| validate(&duplicate)).is_err());
        assert!(std::panic::catch_unwind(|| validate(&registered[1..])).is_err());
    }

    #[test]
    fn remote_sources_are_delivered_but_rich_trace_viewer_is_deferred() {
        for id in [
            "app.debug.browser",
            "app.settings.servers",
            "app.settings.serverEditor",
            "app.settings.serverDelete",
        ] {
            assert_eq!(for_id(id).status, Status::Implemented);
            assert!(
                for_id(id)
                    .fixture
                    .unwrap()
                    .contains("RemoteSourcesFlowTests")
            );
        }
        for id in [
            "app.traceViewer.shortcuts",
            "app.traceViewer.timeline",
            "app.traceViewer.event",
            "app.traceViewer.range",
            "app.traceViewer.annotation",
            "app.menu.trace.filterProcesses",
            "app.menu.trace.searchEvents",
            "app.menu.help.traceShortcuts",
        ] {
            assert_eq!(for_id(id).status, Status::Deferred);
            assert!(for_id(id).detail.contains("TASK-XPA-021"));
        }
    }

    #[test]
    fn installed_updates_do_not_claim_gui_completion_from_the_unpackaged_fixture() {
        assert_eq!(for_id("app.settings.updates").status, Status::Partial);
        assert!(
            for_id("app.settings.updates")
                .detail
                .contains("unpackaged refusal")
        );
    }

    #[test]
    fn native_component_mapping_keeps_source_closure_distinct_from_native_acceptance() {
        let entry = for_id("app.design.components");
        assert_eq!(entry.status, Status::Implemented);
        assert!(
            entry
                .fixture
                .unwrap()
                .starts_with("windows/App.Tests/WindowsComponentMappingTests.cs#")
        );
        assert!(entry.detail.contains("source-reference closure"));
        assert!(entry.detail.contains(
            "no production gallery route, pixel parity, Narrator-by-ear or hardware completion"
        ));
    }

    #[test]
    fn native_panels_name_actual_dialog_and_whole_artifact_proof() {
        let entry = for_id("app.system.panels");
        assert_eq!(entry.status, Status::Implemented);
        assert!(entry.fixture.unwrap().contains("NativePanelsFlowTests"));
        assert!(entry.detail.contains("actual Save and Folder dialogs"));
        assert!(
            entry
                .detail
                .contains("No picker override or hardware result")
        );
    }

    #[test]
    fn delivered_consumers_do_not_claim_hardware_or_bundle_provenance() {
        for id in [
            "app.device.trust",
            "app.diagnostics.capture",
            "app.settings.traceLicenses",
        ] {
            assert_eq!(for_id(id).status, Status::Implemented);
            assert!(for_id(id).fixture.is_some());
        }
        assert!(
            for_id("app.device.trust")
                .detail
                .contains("foreground CLI handoff")
        );
        assert!(
            for_id("app.diagnostics.capture")
                .detail
                .contains("do not establish hardware acceptance")
        );
        assert!(
            for_id("app.settings.traceLicenses")
                .detail
                .contains("do not establish bundle provenance")
        );
    }

    #[test]
    fn the_retired_automation_claim_is_absence_not_a_cli_execution_equivalent() {
        let entry = for_id("app.automation.retired");
        assert_eq!(entry.status, Status::Implemented);
        assert!(entry.detail.contains("no App route or executor"));
        assert_eq!(
            entry.fixture,
            Some("windows/App.Tests/ShellContractTests.cs#TheAppHoldsNoRuntimeSemantics")
        );
    }
}
