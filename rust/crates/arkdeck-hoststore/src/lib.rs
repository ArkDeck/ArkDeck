//! Host-store decoders and explicit Rust owners for TASK-XPA-012.
//!
//! Differential adapters consume bounded bytes or read a physical fixture root.
//! HistoryStore is a separate writer, used only by the explicitly configured
//! development daemon. No decoder or inventory comparison performs a write.

// The workspace registration owner (TASK-XPA-015): register, list and show
// a project and read its presets on macOS and Windows. Its dependency owners
// (the DevEco toolchain registry, the signing credential store) and the
// workspace composition stay macOS-only, so on Windows a preset that pins a
// toolchain or credential is refused as Swift refuses it without them.
#[cfg(any(target_os = "macos", windows))]
mod workspace_project;
#[cfg(any(target_os = "macos", windows))]
pub use workspace_project::{
    CredentialAcquire, PinPair, PinningResult, ToolchainAcquire, WorkspaceCredentialPinning,
    WorkspacePresetComposition, WorkspaceProjectStore, WorkspaceReference, WorkspaceStartupRecord,
    WorkspaceToolchainPinning, WorkspaceUse,
};
#[cfg(any(target_os = "macos", windows))]
mod workspace_composition;
#[cfg(any(target_os = "macos", windows))]
pub use workspace_composition::{
    CompositionNotes, ResolvedToolchain, ToolchainResolver, WorkspaceComposition,
};
#[cfg(any(target_os = "macos", windows))]
mod workspace_isolation;
#[cfg(any(target_os = "macos", windows))]
mod workspace_patch;
#[cfg(any(target_os = "macos", windows))]
pub use workspace_patch::{
    ToolFailure, ToolInvocation, ToolReceipt, VerifiedToolDispatch, WorkspaceToolDispatch,
};
#[cfg(any(target_os = "macos", windows))]
mod workspace_profile;
#[cfg(any(target_os = "macos", windows))]
pub use workspace_profile::{
    ProfilePresets, RegisteredBuildPreset, RegisteredKind, RegisteredSymbolPreset,
    SigningPresetRef, VerifiedResource, WorkspaceCommandPreset, WorkspaceProfile,
};
#[cfg(any(target_os = "macos", windows))]
mod crash_symbolizer;
#[cfg(any(target_os = "macos", windows))]
mod workspace_build;
#[cfg(any(target_os = "macos", windows))]
mod workspace_checkpoint;
#[cfg(any(target_os = "macos", windows))]
pub use crash_symbolizer::{SymbolizeError, symbolize_crash};
// The credential pinning of workspace signing presets and the signing
// dispatch (`SigningSetup`) are composed on macOS and Windows (TASK-XPA-011).
#[cfg(any(target_os = "macos", windows))]
mod workspace_signing;
#[cfg(any(target_os = "macos", windows))]
pub use workspace_signing::SigningSetup;
#[cfg(any(target_os = "macos", windows))]
pub use workspace_signing::{credential_pinning, keychain_credential_pinning};
#[cfg(any(target_os = "macos", windows))]
mod workspace_read;
#[cfg(any(target_os = "macos", windows))]
mod workspace_support;
#[cfg(any(target_os = "macos", windows))]
mod workspace_sweep;
#[cfg(any(target_os = "macos", windows))]
mod workspace_tests_symbolize;
#[cfg(any(target_os = "macos", windows))]
pub use workspace_read::Inspector as WorkspaceInspector;

use serde::{Deserialize, Serialize};

// The Job store owner (the SQLite admission index, `jobs/<id>/job-record.json`
// and the Job read resources) on macOS and Windows. Its readers and writers
// that other macOS-only owners call carry the dead-code allowance on Windows.
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod job_owner;
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod recovery_epoch;
#[cfg(any(target_os = "macos", windows))]
pub use recovery_epoch::{
    RECOVERY_EPOCH_DOCUMENT, RECOVERY_EPOCH_LOCK, RecoveryEpoch, RecoveryEpochDraft,
    RecoveryEpochError, RecoverySource, SupersededIntent, append_recovery_epoch,
    list_recovery_epochs,
};
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod job_record;
#[cfg(any(target_os = "macos", windows))]
mod job_record_fields;
// The Job index's SQL, which `job_repository` composes.
#[cfg(any(target_os = "macos", windows))]
mod job_index;
#[cfg(all(test, any(target_os = "macos", windows)))]
mod job_index_tests;
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod job_repository;
// Swift `RuntimeJobEngine.stepSetDigest`, which the Job record's reader
// checks a consumed HAP's correlation with and the planner computes.
#[cfg(any(target_os = "macos", windows))]
mod job_step_digest;
#[cfg(any(target_os = "macos", windows))]
pub use job_owner::HdcLifecycleInterlock;
#[cfg(any(target_os = "macos", windows))]
pub use job_owner::JobStore;
#[cfg(any(target_os = "macos", windows))]
pub use job_record::JobRecord;
#[cfg(any(target_os = "macos", windows))]
pub use job_repository::{AdmissionVerdict, JobWriteError};
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod mutation_execution;
#[cfg(any(target_os = "macos", windows))]
pub use mutation_execution::MutationExecution;
// The planner and the admitter build on Windows too (TASK-XPA-005, GJ-1):
// there no HDC, workspace or analyzer provider, Artifact or Import owner and
// no capability authority is composed yet, so every operation is refused
// before admission as macOS refuses it without that owner.
#[cfg(any(target_os = "macos", windows))]
mod job_plan;
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod operation_availability;
#[cfg(any(target_os = "macos", windows))]
pub use job_plan::AnalyzerProfile;
// The Flash planner on macOS and Windows (TASK-XPA-010).
#[cfg(any(target_os = "macos", windows))]
pub use job_plan::{FlashPlanner, FlashPlanning, RockchipFactsPort, rockchip_dispatch_unavailable};
#[cfg(any(target_os = "macos", windows))]
pub use job_plan::{JobPlanner, PlanRefusal};
// The analyzers a host composes (TASK-XPA-011 on Windows): the crash-ledger
// and HiLog summary analyzers everywhere; the ArkTrace analyzers only where a
// reviewed distribution loads, which is macOS alone (TASK-XPA-021).
#[cfg(any(target_os = "macos", windows))]
mod analyzer_composition;
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod arktrace_pins;
// The analyzer operations' fixed facts, read on every host.
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod analyzer_operations;
#[cfg(target_os = "macos")]
mod arktrace_doctor;
#[cfg(target_os = "macos")]
pub use arktrace_doctor::ProductionDoctorProbe;
// The judges of the ArkTrace CLI's answers and the contract they check,
// which read nothing from the host: the same code decides on Windows, where
// no reviewed distribution exists yet to answer them (TASK-XPA-021), and the
// recorded verdicts replay there. The loader, its trust checker and the
// doctor probe stay macOS-only: the distribution contract they verify is an
// Apple one (Developer ID, code directory hashes, POSIX modes in the tree
// digest).
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod arktrace_analysis;
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod arktrace_envelope;
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod arktrace_summary;
#[cfg(target_os = "macos")]
mod arktrace_trust;
#[cfg(target_os = "macos")]
pub use arktrace_trust::ProductionDistributionTrust;
#[cfg(target_os = "macos")]
mod arktrace_profile;
#[cfg(any(target_os = "macos", windows))]
pub use analyzer_composition::{AnalyzerComposition, AnalyzerProfiles};
#[cfg(target_os = "macos")]
pub use arktrace_profile::{
    ArkTraceContract, ArkTraceLoadError, ArkTraceProfileError, ArkTraceProfileLoader,
    DistributionTrust, DoctorContract, DoctorProbe, LoaderHooks, PinnedFile, PinnedTree,
    ResolvedExecutable, TrustContract, TrustEvidence,
};
#[cfg(any(target_os = "macos", windows))]
pub use operation_availability::{
    OperationAvailabilityContext, hdc_operation_runs, operation_unavailability,
};
#[cfg(target_os = "macos")]
mod debug_read;
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod device_facts;
#[cfg(target_os = "macos")]
mod trace_probe;
#[cfg(any(target_os = "macos", windows))]
pub use device_facts::HdcComposition;
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod capture_documents;
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod cleanup_debt;
#[cfg(any(target_os = "macos", windows))]
pub use cleanup_debt::list_cleanup_debt;
#[cfg(any(target_os = "macos", windows))]
mod cleanup_debt_continue;
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod device_run;
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod device_steps;
#[cfg(any(target_os = "macos", windows))]
mod job_admission;
#[cfg(any(target_os = "macos", windows))]
pub use job_admission::FlashAdmitter;
#[cfg(any(target_os = "macos", windows))]
pub use job_admission::{AdmissionRefusal, JobAdmitter, MutationAuthority, runtime_now};
#[cfg(any(target_os = "macos", windows))]
mod agent_execution;
#[cfg(any(target_os = "macos", windows))]
pub use agent_execution::{
    AgentAdmission, AgentAnswer, AgentEngine, AgentExecutionStore, AgentStart, Observing,
};
#[cfg(any(target_os = "macos", windows))]
mod human_action;
#[cfg(any(target_os = "macos", windows))]
pub use human_action::HumanActionResources;
// The control actions (the HDC lifecycle's and the tool selection's) and
// their durable records, on macOS and Windows (TASK-XPA-005); on Windows no
// owner is composed without a registered HDC tuple (CHG-2026-078).
#[cfg(any(target_os = "macos", windows))]
mod control_action;
#[cfg(any(target_os = "macos", windows))]
pub use control_action::{ControlActionResources, control_action_without_owner};
#[cfg(any(target_os = "macos", windows))]
mod control_action_approval;
#[cfg(any(target_os = "macos", windows))]
pub use control_action_approval::{ImpactApproval, InteractionChallenge, InteractionReceipt};
#[cfg(any(target_os = "macos", windows))]
mod control_action_store;
#[cfg(any(target_os = "macos", windows))]
mod control_action_value;
#[cfg(any(target_os = "macos", windows))]
mod hdc_control_action;
#[cfg(any(target_os = "macos", windows))]
pub use hdc_control_action::{
    HdcControlActions, HdcLifecycleAudit, HdcLifecycleDriver, Impact, ImpactReading, ImpactSource,
    OwnerContext, Record,
};
// Tool selection's records on both; its owner reads the Bootstrap tool
// registry, which is macOS-only (`absent_tool_selection_owner.rs`).
#[cfg(any(target_os = "macos", windows))]
mod tool_selection;
#[cfg(any(target_os = "macos", windows))]
pub use tool_selection::{
    SelectionImpact, ToolFacts, ToolSelectionActions, ToolSelectionDriver, ToolSelectionIntent,
    ToolSelectionRecord, ToolSelectionRecords,
};
#[cfg(target_os = "macos")]
pub use tool_selection::{ToolSelectionAudit, ToolSelectionRegistry};
#[cfg(any(target_os = "macos", windows))]
mod hdc_impact_source;
#[cfg(any(target_os = "macos", windows))]
pub use hdc_impact_source::{CurrentJob, DeviceReading, DeviceRow, ManagedServerImpact};
#[cfg(any(target_os = "macos", windows))]
mod analyzer_output;
#[cfg(any(target_os = "macos", windows))]
mod crash_ledger;
#[cfg(any(target_os = "macos", windows))]
pub use crash_ledger::{analyze_crash_ledger, crash_ledger_source};
#[cfg(any(target_os = "macos", windows))]
mod hilog_summary;
#[cfg(target_os = "macos")]
pub use hilog_summary::profile_path;
#[cfg(any(target_os = "macos", windows))]
pub use hilog_summary::{
    MAXIMUM_INPUT_BYTES as HILOG_MAXIMUM_INPUT_BYTES, analyze_hilog, hilog_source,
};
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod artifact_publication;
#[cfg(any(target_os = "macos", windows))]
pub use artifact_publication::collect_expired_artifacts;
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod job_run;
#[cfg(any(target_os = "macos", windows))]
pub use job_run::{FlashExecution, FlashRunner};
#[cfg(any(target_os = "macos", windows))]
pub use job_run::{JobRunner, RunRefusal, runtime_precise_now};
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod job_result;
#[cfg(any(target_os = "macos", windows))]
pub use job_result::JobResultReader;
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod job_cancel;
#[cfg(any(target_os = "macos", windows))]
pub use job_cancel::{CancelledRun, JobCanceller, RunCancellation, cancel_running};
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod job_recovery;
#[cfg(any(target_os = "macos", windows))]
pub use job_recovery::{RecoveredJobs, RecoveryError, recover_active_jobs, recover_jobs};
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod job_lineage_repair;
#[cfg(any(target_os = "macos", windows))]
mod job_reconcile;
#[cfg(any(target_os = "macos", windows))]
pub use job_reconcile::FlashReconciler;
#[cfg(any(target_os = "macos", windows))]
pub use job_reconcile::JobReconciler;
// The Session publication writer on macOS and Windows. Its callers, the Job
// runners, cancellation and reconciliation, are still macOS-only; on Windows
// the replay of the recorded Swift Sessions drives it
// (`session_publication_windows_tests.rs`).
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod session_publication;
#[cfg(any(target_os = "macos", windows))]
pub use session_publication::{
    PublicationPoint, SessionPublisher, StagedRecovery, StorageClaims, StorageProbe,
    StorageSnapshot, SystemStorageProbe,
};
// The Catalog's operation model, its input matching (with the Catalog's
// pattern subset) and its effect resolution live in `arkdeck-contract`, shared
// with the CLI; `crate::operation_catalog` keeps naming them here.
#[cfg(any(target_os = "macos", windows))]
use arkdeck_contract::operation_catalog;
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod operation_request;
#[cfg(any(target_os = "macos", windows))]
pub use operation_request::{OperationRequest, RequestErrorCode, RequestRejection};
// `artifact.quota`'s walk, on macOS through `ArtifactUsage` and on Windows
// through the Artifact read owner.
#[cfg(any(target_os = "macos", windows))]
mod artifact_quota;
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod capability_policy;
#[cfg(any(target_os = "macos", windows))]
pub use capability_policy::DeviceHolds;
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod capability_store;
// Foundation's JSON member-name and text rules, on the portable host text:
// the Recovery Manifest a Session Manifest carries needs them on Windows too.
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod strict_json;
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod swift_decoding;
#[cfg(any(target_os = "macos", windows))]
pub use capability_store::{
    Capability as RuntimeCapability, CapabilityDenial, CapabilityQuery, CapabilityRefusal,
    CapabilityStore, CapabilityStoreError, ConsumptionReceipt, Effect as WorkflowEffect,
    UseOutcome as CapabilityUseOutcome,
};

#[cfg(target_os = "macos")]
mod cutover_facts;
// The Job's Journal owners stand on the durable host store (`HostJournal`,
// `HostJournalAppender`) and the portable host text and calendar, which macOS
// and Windows both have. The Job events reader's caller, `JobStore::events`,
// sits on the SQLite Job index and is still macOS-only.
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod job_events;
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod job_failure;
#[cfg(all(test, any(target_os = "macos", windows)))]
mod test_private;
#[cfg(target_os = "macos")]
pub use cutover_facts::{
    CutoverFacts, CutoverRoots, MISSING_RECORD, RetainedSessionsRefusal, UNREADABLE_RECORD,
    UnreadableSource, cutover_facts, cutover_retained_sessions,
};
#[cfg(any(target_os = "macos", windows))]
mod job_journal;
#[cfg(any(target_os = "macos", windows))]
pub use job_journal::{JOURNAL_KINDS, JournalEvent};
#[cfg(any(target_os = "macos", windows))]
pub mod job_journal_events;
#[cfg(any(target_os = "macos", windows))]
mod job_journal_replay;
#[cfg(any(target_os = "macos", windows))]
mod job_journal_writer;
#[cfg(any(target_os = "macos", windows))]
pub use job_journal_replay::{AbandonmentFact, IntentFact, ReplayFacts, UnknownFact};
#[cfg(any(target_os = "macos", windows))]
pub use job_journal_writer::{JournalWriteError, JournalWriter, inspect_journal};

// The History filter owner (`history.filter.*`), on macOS and Windows.
#[cfg(any(target_os = "macos", windows))]
mod history_owner;
#[cfg(any(target_os = "macos", windows))]
pub use history_owner::HistoryStore;
// The Session storage owner (`runtime.storage.*`, `session.list`, `show`,
// `pin`, `unpin`, `session.cleanup.*`, `session.export.*`) and the storage
// hold a publication registers under, on macOS and Windows.
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod session_owner;
// The private snapshot pages `artifact.list`, `job.list`, `job.timeline` and
// `session.list` keep (and every other macOS pager), on the durable host
// store both OSes have.
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod snapshot_pager;
#[cfg(any(target_os = "macos", windows))]
pub use session_owner::ActiveSessions;
#[cfg(any(target_os = "macos", windows))]
pub use session_owner::SessionStore;
#[cfg(any(target_os = "macos", windows))]
mod session_cleanup_plan;
#[cfg(any(target_os = "macos", windows))]
pub use session_cleanup_plan::{CleanupCandidate, CleanupPlan, plan_session_cleanup};
#[cfg(any(target_os = "macos", windows))]
mod session_cleanup_records;
#[cfg(any(target_os = "macos", windows))]
pub use session_cleanup_records::{
    CleanupRecord, CleanupState, SessionCleanupRecords, SessionExportRecords,
};
// Its physical-path rule serves the Artifact export on macOS and Windows; the
// Session export facts are still macOS-only.
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod session_export_destination;
#[cfg(any(target_os = "macos", windows))]
pub use session_export_destination::session_export_destination_facts;
#[cfg(any(target_os = "macos", windows))]
pub use session_inventory::{CleanupSession, CleanupSnapshot, session_cleanup_snapshot};
#[cfg(any(target_os = "macos", windows))]
pub use session_inventory::{SessionExportSnapshot, session_export_snapshot};
// The Artifact index decoder the read owner shares, and the usage owner a
// Session publication reads and `runtime.storage.*` carries; its quota
// answer is still macOS-only.
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod artifact_usage;
#[cfg(any(target_os = "macos", windows))]
pub use artifact_usage::ArtifactUsage;

#[cfg(any(target_os = "macos", windows))]
mod session_export_artifacts;
#[cfg(any(target_os = "macos", windows))]
pub use session_export_artifacts::{
    ExportArtifactMeasurement, PlannedExportArtifact, PreparedSessionExport,
};
#[cfg(any(target_os = "macos", windows))]
mod session_export_manifest;
#[cfg(any(target_os = "macos", windows))]
pub use session_export_manifest::{RedactedSessionManifest, redact_session_manifest_fields};
mod session_export_redaction;
pub use session_export_redaction::SessionExportRedactor;

// The Target owners (TASK-XPA-004) on macOS and Windows: the same
// `targets.json` bytes under the same `.targets.lock` on both. Off macOS
// only some members of theirs are used; the Job, Import and Rockchip
// consumers of the rest are composed on macOS only.
#[cfg(any(target_os = "macos", windows))]
mod device_lane;
#[cfg(any(target_os = "macos", windows))]
pub use device_lane::{LaneState, MutationLane};
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(windows, allow(dead_code))]
mod target_document;
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(windows, allow(dead_code))]
mod target_owner;
#[cfg(any(target_os = "macos", windows))]
pub use target_owner::{ObservationReference, TargetStore};
#[cfg(any(target_os = "macos", windows))]
mod target_observation;
#[cfg(any(target_os = "macos", windows))]
pub use target_observation::{
    Adopted, Observation, ObservationError, Snapshot, Sources, TargetObservations, adoption_answer,
    parse_reference,
};
#[cfg(any(target_os = "macos", windows))]
mod post_flash_alias;
#[cfg(any(target_os = "macos", windows))]
mod post_flash_alias_store;
#[cfg(any(target_os = "macos", windows))]
pub use post_flash_alias::{
    LiveTarget, ObservedHdc, PostFlashAliasError, PostFlashBinding, Publication, Reconciliation,
    SCHEMA_VERSION as POST_FLASH_ALIAS_SCHEMA_VERSION, admit as admit_post_flash_alias, is_sha256,
    reissue as reissue_post_flash_alias, resolve as resolve_post_flash_alias,
};
#[cfg(any(target_os = "macos", windows))]
pub use post_flash_alias_store::PostFlashAliasStore;
#[cfg(any(target_os = "macos", windows))]
mod flash_alias_reconcile;
#[cfg(any(target_os = "macos", windows))]
pub use flash_alias_reconcile::{FlashAliasReconciler, UsbCensus};
#[cfg(any(target_os = "macos", windows))]
mod debug_attempt_permit;
#[cfg(any(target_os = "macos", windows))]
mod flash_invocations;
#[cfg(any(target_os = "macos", windows))]
pub use flash_invocations::{
    DriverResult, FlashInvocations, InvocationBroker, MAXIMUM_DESTRUCTIVE_EPOCHS,
    debug_execution_outcome,
};
#[cfg(any(target_os = "macos", windows))]
mod rockchip_binding;
#[cfg(any(target_os = "macos", windows))]
pub use rockchip_binding::{
    BindingError, BindingEvidence, BindingInstallation, BindingSnapshot, BoundTarget,
    LineageAdvance, RecoveryProof, RockchipBindingStore, install_current_target,
};
#[cfg(any(target_os = "macos", windows))]
mod rockchip_action;
#[cfg(any(target_os = "macos", windows))]
pub use rockchip_action::{CaptureRequest, Expectation, RockchipAction};
#[cfg(any(target_os = "macos", windows))]
mod rockchip_records;
#[cfg(any(target_os = "macos", windows))]
pub use rockchip_records::{
    DurableRockchipHost, ExecutionResult, RefusingRockchipHost, RockchipActionExecutor,
    RockchipActionHosting, RockchipRecordStore,
};
#[cfg(any(target_os = "macos", windows))]
mod rockchip_executor;
#[cfg(any(target_os = "macos", windows))]
pub use rockchip_executor::{HdcResolver, RockchipExecutor};
#[cfg(any(target_os = "macos", windows))]
mod rockchip_dispatcher;
#[cfg(any(target_os = "macos", windows))]
pub use rockchip_dispatcher::NativeRockchipDispatcher;
#[cfg(any(target_os = "macos", windows))]
mod control_performer;
#[cfg(any(target_os = "macos", windows))]
pub use control_performer::{ArkForgeControlPerformer, ControlBinding};
#[cfg(any(target_os = "macos", windows))]
mod rockchip_reactivation;
#[cfg(any(target_os = "macos", windows))]
pub use rockchip_reactivation::{ReactivationProof, ReactivationProofSource};
#[cfg(any(target_os = "macos", windows))]
mod loader_binding;
#[cfg(any(target_os = "macos", windows))]
pub use loader_binding::LoaderBinding;
#[cfg(any(target_os = "macos", windows))]
mod rockchip_startup;
#[cfg(any(target_os = "macos", windows))]
pub use rockchip_startup::{RockchipStartup, reconcile_rockchip_startup};
// The Flash archive reader, which the Flash planner and the flash-bundle
// Import validator read a bundle through (macOS and Windows, TASK-XPA-010).
#[cfg(any(target_os = "macos", windows))]
mod flash_archive;
#[cfg(any(target_os = "macos", windows))]
mod flash_facts;
#[cfg(any(target_os = "macos", windows))]
pub use flash_facts::{
    ArkForgeLoader, FlashHostFacts, LanePreview, NATIVE_ROCKUSB_TOOLCHAIN, NativeRockUsbIdentity,
    NoArkForgeLane, RockchipFacts, RockchipUsbProbe, lane_plan_preview, preview_before_lane,
};
mod display_names;
mod format_time;
pub use display_names::decode_display_names;
mod session_json;
pub use session_json::decode_session_json;
mod session_time;
pub use session_time::decode_session_timestamp;
mod session;
pub use session::decode_session_configuration;
// The Bootstrap registry's index codecs and the frozen-document codec the
// host store's other decoders share live with its file owners.
use arkdeck_bootstrap::roundtrip;
pub use arkdeck_bootstrap::{
    DecodeError, DecodedStore, decode_bundles, decode_tool_identity, decode_tools,
};
use serde_json::{Value, json};

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct HistoryQuery {
    search: String,
    status: String,
    mode: String,
    #[serde(rename = "sessionID", skip_serializing_if = "Option::is_none")]
    session_id: Option<String>,
    #[serde(rename = "targetID", skip_serializing_if = "Option::is_none")]
    target_id: Option<String>,
    #[serde(rename = "timeRange")]
    time_range: String,
    activity: String,
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct HistoryDocument {
    #[serde(rename = "schemaVersion")]
    schema_version: String,
    generation: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    query: Option<HistoryQuery>,
    #[serde(rename = "updatedAtUTC", skip_serializing_if = "Option::is_none")]
    updated_at_utc: Option<String>,
}

// Foundation String equality is canonically equivalent, so comparing a string
// to its NFC spelling does not reject decomposed spellings. Preserve their bytes.
// The character sets and NFC are the platform's pinned Foundation tables on
// every host, never another platform's own Unicode data.
fn valid_host_text(value: &str, trimmed: bool, allow_tab: bool) -> bool {
    use arkdeck_platform::{host_control_character, host_whitespace_or_newline};
    (!trimmed
        || (value
            .chars()
            .next()
            .is_none_or(|c| !host_whitespace_or_newline(c))
            && value
                .chars()
                .next_back()
                .is_none_or(|c| !host_whitespace_or_newline(c))))
        && value
            .chars()
            .all(|c| !host_control_character(c) || (allow_tab && c == '\t'))
}

fn canonical_host_text(value: &str) -> Result<String, DecodeError> {
    arkdeck_platform::host_canonical_text(value).ok_or(DecodeError::Shape)
}

/// Decode the frozen field set, re-encode durable bytes, and derive the list
/// projection. Both outputs are checked against the real Swift owner by the
/// differential harness, not against a second handwritten expected projection.
pub fn decode_history(bytes: &[u8]) -> Result<DecodedStore, DecodeError> {
    let (doc, document) = roundtrip::<HistoryDocument>(bytes, 64 * 1024, true)?;
    if doc.schema_version != "arkdeck.history-filter-store/1"
        || doc.generation == 0
        || doc.generation > i64::MAX as u64
        || (doc.generation == 1 && doc.query.is_some())
        || (doc.updated_at_utc.is_none() != (doc.generation == 1))
        || doc
            .updated_at_utc
            .as_ref()
            .is_some_and(|v| !format_time::valid_format_timestamp(v))
    {
        return Err(DecodeError::Header);
    }
    if let Some(q) = &doc.query
        && (q.search.len() > 512
            || ![
                "all",
                "active",
                "needsAttention",
                "succeeded",
                "failed",
                "interrupted",
                "cancelled",
            ]
            .contains(&q.status.as_str())
            || !["all", "execute", "planned", "simulated", "unknown"].contains(&q.mode.as_str())
            || !["anyTime", "lastHour", "lastDay", "lastWeek"].contains(&q.time_range.as_str())
            || ![
                "all",
                "flash",
                "viewer",
                "trace",
                "diagnostics",
                "debug",
                "device",
                "other",
            ]
            .contains(&q.activity.as_str())
            || !valid_host_text(&q.search, false, true)
            || [&q.session_id, &q.target_id]
                .into_iter()
                .flatten()
                .any(|s| s.is_empty() || s.len() > 256 || !valid_host_text(s, true, false)))
    {
        return Err(DecodeError::Shape);
    }
    let query = doc.query.as_ref().map(|q| {
        json!({"search": q.search, "status": q.status, "mode": q.mode,
            "sessionId": q.session_id, "targetId": q.target_id,
            "timeRange": q.time_range, "activity": q.activity})
    });
    let generation = doc.generation.to_string();
    let filters: Vec<Value> = query
        .into_iter()
        .map(|q| {
            json!({
                "schemaVersion": "arkdeck.history-filter/1", "generation": generation,
                "query": q, "updatedAtUtc": doc.updated_at_utc
            })
        })
        .collect();
    Ok(DecodedStore {
        document,
        projection: json!({"schemaVersion": "arkdeck.history-filter-list/1",
            "generation": generation, "filters": filters, "updatedAtUtc": doc.updated_at_utc}),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const EMPTY: &[u8] =
        b"{\"generation\":1,\"schemaVersion\":\"arkdeck.history-filter-store/1\"}\n";

    #[test]
    fn empty_and_tombstone_preserve_generation_without_inventing_optional_keys() {
        let empty = decode_history(EMPTY).unwrap();
        assert_eq!(empty.document, EMPTY);
        assert_eq!(empty.projection["filters"], json!([]));
        let tombstone = b"{\"generation\":9223372036854775807,\"schemaVersion\":\"arkdeck.history-filter-store/1\",\"updatedAtUTC\":\"2026-09-10T01:00:00.000Z\"}\n";
        let decoded = decode_history(tombstone).unwrap();
        assert_eq!(decoded.document, tombstone);
        assert_eq!(decoded.projection["generation"], "9223372036854775807");
    }

    #[test]
    fn refuses_extra_keys_null_keys_duplicate_fields_and_invalid_generations() {
        for bytes in [
            br#"{"generation":1,"schemaVersion":"arkdeck.history-filter-store/1","extra":true}"#.as_slice(),
            br#"{"generation":1,"schemaVersion":"arkdeck.history-filter-store/1","query":null}"#,
            br#"{"generation":1,"generation":2,"schemaVersion":"arkdeck.history-filter-store/1"}"#,
            br#"{"generation":0,"schemaVersion":"arkdeck.history-filter-store/1"}"#,
            br#"{"generation":9223372036854775808,"schemaVersion":"arkdeck.history-filter-store/1"}"#,
            br#"{"generation":2,"schemaVersion":"arkdeck.history-filter-store/1"}"#,
            br#"{"generation":"1","schemaVersion":"arkdeck.history-filter-store/1"}"#,
        ] {
            assert!(decode_history(bytes).is_err());
        }
        assert_eq!(
            decode_history(&vec![b' '; 65537]).err(),
            Some(DecodeError::Size)
        );
    }
}

#[cfg(any(target_os = "macos", windows))]
mod trace;
#[cfg(any(target_os = "macos", windows))]
pub use trace::trace_inventory;
#[cfg(any(target_os = "macos", windows))]
mod trace_maintenance;
#[cfg(any(target_os = "macos", windows))]
mod trace_owner;
#[cfg(any(target_os = "macos", windows))]
pub use trace_owner::TraceCacheStore;

#[cfg(any(target_os = "macos", windows))]
mod recovery_manifest;
mod session_graphemes;
// Its readers, the ArkTrace profile and the Rockchip records, are built on
// macOS and Windows.
#[cfg(any(target_os = "macos", windows))]
mod swift_hex;
// The Session census and retention catalog the storage owner and the
// publication writer read and register in, on macOS and Windows.
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod session_inventory;
// The Session Manifest decoder serves the Journal's closed format and the
// Session census and publication, on macOS and Windows.
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod session_manifest;
#[cfg(any(target_os = "macos", windows))]
mod session_step_arguments;
#[cfg(any(target_os = "macos", windows))]
pub use recovery_manifest::{
    RecoveryManifest, RecoveryManifestAbandonConfirmation, RecoveryManifestDeviceMode,
    RecoveryManifestError, RecoveryManifestGuide, RecoveryManifestHazard,
};
pub use session_graphemes::decode_graphemes;
#[cfg(any(target_os = "macos", windows))]
pub use session_inventory::{session_inventory, session_inventory_owned};

// The Bootstrap registry's bundle and HDC tool file owners are
// `arkdeck-bootstrap`, which the CLI's zero-Runtime install shares; the
// Runtime composes its paged inventories and the DevEco toolchain registry
// over them here, on macOS and Windows (where no Bundle or HDC content policy
// exists yet, so their registries hold nothing the owners admit).
#[cfg(target_os = "macos")]
pub use arkdeck_bootstrap::tool_macho;
#[cfg(any(target_os = "macos", windows))]
pub use arkdeck_bootstrap::{
    BundleRegistryReadStore, DurableSelectionOutcome, PublishedIdentities, SelectionCandidate,
    SelectionSnapshot, StartupSelection, ToolContent, ToolDependency, ToolRegistryStore,
    bundle_content, inspect_tool_content,
};
#[cfg(any(target_os = "macos", windows))]
mod bundle_list_owner;
#[cfg(any(target_os = "macos", windows))]
pub use bundle_list_owner::BootstrapListPage;
#[cfg(any(target_os = "macos", windows))]
mod tool_list_owner;
#[cfg(any(target_os = "macos", windows))]
mod tool_retirement;

// Portable: the product and SDK manifest facts, the same format on macOS
// and Windows (TASK-XPA-011, G15). The DevEco registry and its owner are
// built on macOS and Windows: on Windows node and hvigor register as the
// child roles of one content-addressed toolchain, node's Authenticode
// signature and the DevEco launcher's publisher (G12) in place of the macOS
// bundle signature and resource envelope.
mod deveco_manifest;
pub use deveco_manifest::{
    DevEcoLaunchHost, DevEcoManifestError, DevEcoManifestFacts, parse_deveco_manifests,
};
#[cfg(any(target_os = "macos", windows))]
mod deveco_registry;
#[cfg(any(target_os = "macos", windows))]
pub use deveco_registry::decode_deveco_toolchains;
#[cfg(any(target_os = "macos", windows))]
mod deveco_content;
#[cfg(any(target_os = "macos", windows))]
mod deveco_registry_owner;
#[cfg(any(target_os = "macos", windows))]
pub use deveco_registry_owner::DevEcoRegistryStore;

// The Artifact read, inspect, list and export owners (TASK-XPA-006), on the
// durable host store's export, file-export and payload-cache primitives,
// which macOS and Windows both have.
#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod artifact_read_owner;
#[cfg(any(target_os = "macos", windows))]
pub use artifact_read_owner::{
    ArtifactPublicationFault, ArtifactReadPage, ArtifactReadRange, ArtifactReadSnapshot,
    ArtifactReadStore, MAX_ARTIFACT_READ_BYTES,
};

#[cfg(any(target_os = "macos", windows))]
mod artifact_projection;
#[cfg(any(target_os = "macos", windows))]
pub use artifact_projection::{ArtifactInspectRequest, ArtifactReadRequest};

#[cfg(any(target_os = "macos", windows))]
mod artifact_resources;

// The Import owner (`artifact.import.*`) on macOS and Windows, a flash
// bundle validated at publication through the Flash archive reader on both
// (TASK-XPA-010).
#[cfg(any(target_os = "macos", windows))]
mod import_upload;
#[cfg(any(target_os = "macos", windows))]
pub use import_upload::{ImportBinding, ImportUploadFault, ImportUploadStore};

#[cfg(any(target_os = "macos", windows))]
mod artifact_export;
#[cfg(any(target_os = "macos", windows))]
pub use artifact_export::ArtifactExportRequest;

#[cfg(any(target_os = "macos", windows))]
#[cfg_attr(windows, allow(dead_code))]
mod catalog_review;
#[cfg(target_os = "macos")]
pub use catalog_review::flash_catalog_review;
