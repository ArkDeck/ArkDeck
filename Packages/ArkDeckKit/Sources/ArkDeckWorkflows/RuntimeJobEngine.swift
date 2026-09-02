// Durable Runtime Job Engine (CHG-2026-047, T08).
//
// Reuses the proven primitives - JobStateMachine's transition graph via the
// journal's own cross-validation, FileDurableJournal (F_FULLFSYNC, torn-tail
// semantics), DurableJournalRecovery replay and DeviceMutationLaneCoordinator
// - and adds the three missing pieces: a durable idempotency ledger, the
// WriteAheadIntentGate as the production dispatch path, and restart
// recovery that never blind-redispatches. Unknown outcomes park in
// waitingForRecovery; there is no automatic replay anywhere in this file.

import ArkDeckCore
import ArkDeckRuntime
import ArkDeckStorage
import ArkForgeClient
import ArkForgeProtocol
import CryptoKit
import Dispatch
import Foundation

public enum RuntimeJobEngineError: Error, Equatable, Sendable {
  case rejected(RuntimeOperationErrorCode, String)
  case idempotencyConflict(String)
  case jobNotFound(String)
  case jobRecordUnreadable(String)
  case jobNotRunnable(String)
  case internalFailure(String)
}

/// Opaque ownership token for the narrow host-wide HDC lifecycle window. It
/// carries no process, endpoint, Job or capability authority.
package struct RuntimeHDCLifecycleInterlockLease: Sendable, Equatable {
  fileprivate let id: UUID
}

/// Closed caller-authority boundary shared by admission and its contract tests.
/// A Runtime-owned policy never accepts a capability reference selected by a
/// caller; only protected Runtime may issue and attach that exact capability.
package enum RuntimeCallerAuthorityBoundary {
  package static func validate(
    policy: RuntimeOperationAuthorizationPolicy,
    hasCallerSuppliedAuthorization: Bool
  ) throws {
    if policy == .runtimeCapability, hasCallerSuppliedAuthorization {
      throw RuntimeJobEngineError.rejected(
        .authorizationRequired,
        "caller-supplied capabilities cannot admit a Runtime-owned policy")
    }
  }
}

/// The request envelope this runtime accepts, forwarded from the wire model
/// that defines it.
///
/// `ArkDeckAgentDaemon` publishes this on `doctor` but may not import
/// `ArkDeckRuntime` (docs/ArchitectureRules.md §2: it sees Core, Storage and
/// Workflows only). Forwarding here runs with the dependency arrows rather
/// than against them, and keeps one definition: spelling `"2.0.0"` a second
/// time in the daemon would put the envelope contract in two places that
/// nothing compares.
public enum RuntimeRequestEnvelope {
  public static let schemaVersion = RuntimeOperationRequest.schemaVersion

  /// A complete, decodable request for this operation, with every required
  /// input present.
  ///
  /// Built from the descriptor rather than written down. A hand-kept example
  /// is a second statement of the contract and drifts from it; this one cannot
  /// say anything the catalog does not, and a contract test requires it to
  /// survive the real decode path — so an example that stopped being valid
  /// fails here rather than in a caller's first submit.
  ///
  /// It is a shape, not a submittable document: identifiers, artifact leases
  /// and pattern-constrained names are placeholders the caller replaces. What
  /// it is authoritative about is the envelope — which is the part that cost a
  /// round trip per field to discover.
  /// The same example as a JSON document, for callers that may not import the
  /// runtime contract layer — `ArkDeckAgentDaemon` publishes this and sees
  /// Core, Storage and Workflows only (docs/ArchitectureRules.md §2).
  public static func exampleRequestJSON(
    for descriptor: CatalogOperationDescriptor
  ) -> JSONValue? {
    guard let request = example(for: descriptor),
      let encoded = try? RuntimeOperationCodec.encodeRequest(request)
    else { return nil }
    return try? JSONDecoder().decode(JSONValue.self, from: encoded)
  }

  package static func example(
    for descriptor: CatalogOperationDescriptor
  ) -> RuntimeOperationRequest? {
    var inputs: [String: JSONValue] = [:]
    for field in descriptor.inputs where field.isRequired {
      inputs[field.name] = placeholder(for: field)
    }
    return try? RuntimeOperationRequest.operatorFlagForm(
      targetID: "TGT-REPLACE-ME",
      expectedBindingRevision: descriptor.binding == .confirmedDevice ? 1 : nil,
      operationID: descriptor.id,
      version: descriptor.version,
      inputs: inputs,
      requestID: "req-example",
      idempotencyKey: "idem-example-0001")
  }

  private static func placeholder(for field: CatalogFieldDescriptor) -> JSONValue {
    if let declared = field.defaultValue { return declared }
    if let first = field.enumValues?.first { return .string(first) }
    switch field.type {
    case .string:
      return .string("REPLACE_ME")
    case .integer:
      return .integer(Int64(field.minimum ?? 1))
    case .boolean:
      return .bool(false)
    case .stringArray:
      return .array([.string("REPLACE_ME")])
    case .artifactLease, .artifactReference:
      // Spelled out rather than elided: the lease grammar is the other thing
      // a caller could not discover without reading the source.
      return .string("lease-v1:JOB-REPLACE-ME:ART-REPLACE-ME")
    case .artifactLeaseArray:
      return .array([.string("lease-v1:JOB-REPLACE-ME:ART-REPLACE-ME")])
    }
  }
}

public struct RuntimePlanOnlyStep: Sendable, Equatable, Codable {
  public let stepID: String
  public let kind: String
  public let effect: String
  public let cancellation: String
  public let binding: String
  public let isOptional: Bool

  public init(
    stepID: String, kind: String, effect: String, cancellation: String,
    binding: String, isOptional: Bool
  ) {
    self.stepID = stepID
    self.kind = kind
    self.effect = effect
    self.cancellation = cancellation
    self.binding = binding
    self.isOptional = isOptional
  }
}

/// A fully materialized Runtime preview. It is deliberately not a Job or a
/// capability document: producing it performs no admission, authorization
/// consumption or provider dispatch, including for destructive operations.
public struct RuntimePlanOnlyPreview: Sendable, Equatable, Codable {
  public let executionMode: String
  public let operationReference: String
  public let targetID: String
  public let bindingRevision: Int?
  public let stableIdentitySHA256: String?
  public let providerID: String
  public let catalogDigest: String
  public let requestFingerprintSHA256: String
  public let materializedPlanDigest: String
  public let inputs: [String: JSONValue]
  public let steps: [RuntimePlanOnlyStep]
  /// The effect these exact inputs select, not the operation's floor.
  ///
  /// `capture.diagnostics@1` is `readOnly` until `traceCategories`,
  /// `uiScreenshot` or `uiComponentTree` selects a file-producing leg, at
  /// which point it mutates the device and needs a capability. That is
  /// decided here from the same rule admission uses, so a caller can see the
  /// escalation its own inputs caused before submitting anything.
  public let effectiveEffect: String
  /// Which authorization the catalog attaches to that effect —
  /// `defaultReadOnly`, `standingCapability` or `runtimeCapability`. Absent
  /// when the catalog declares none, which is itself a refusal at submit.
  public let authorizationPolicy: String?
  /// A provider prerequisite that would refuse this plan before any
  /// capability is issued, read from the same resolved facts admission reads.
  /// Absent means the provider raised none at preview time; it is not a
  /// promise about a later submit, because facts are re-read then.
  public let providerAdmissionBlocker: String?
  public let jobAdmitted: Bool
  public let dispatchDisposition: String
}

/// Presented status: the persisted JobStateMachine state plus the
/// waitingForHuman view (open human action against a non-terminal job).
/// The persisted 18-state graph is unchanged.
public struct RuntimeJobStatus: Sendable, Equatable, Codable {
  public let jobID: String
  public let operationReference: String
  public let targetID: String
  public let state: String
  public let waitingForHuman: Bool
  public let outcomeUnknown: Bool
  /// Machine-readable terminal or unresolved failure facts. This projection
  /// is diagnostic only and never authorizes retry, dispatch or recovery.
  public let operationFailure: RuntimeOperationFailure?
  /// How much of this job's device residue is still outstanding. A
  /// `succeeded` job with a non-zero count did what was asked and left the
  /// device dirty; `succeeded` must never be read as "device clean"
  /// (CHG-2026-049 r3). Optional so a status decoded from before r3 keeps
  /// decoding.
  public var outstandingResidueCount: Int?
  public let timeline: [String]
  /// Replaceable observational progress for the process step that is
  /// currently executing. It is never authority for dispatch, success,
  /// retry, or recovery; the durable journal remains authoritative.
  public let processProgress: RuntimeJobProcessProgress?
  /// Read-only History facts. Runtime jobs are execute records today, but the
  /// optional wire shape preserves honest compatibility with older daemons
  /// and leaves room for a future persisted simulated mode without guessing.
  public let executionMode: String?
  public let sessionID: String?
  /// The run-grouping thread the submitting workspace filed this Job under,
  /// projected out of the request's non-authoritative client provenance.
  /// Display and audit only: History groups by it, nothing decides by it.
  /// Distinct from `sessionID`, which is this Job's own storage identity.
  public let threadID: String?
  /// Presentation-only origin projected from the persisted operation, typed
  /// inputs, and client provenance. It never participates in Runtime policy.
  public let workspaceKind: RuntimeWorkspaceKind?
  public let actualEffect: String?
  public let createdAtUTC: String?
  public let startedAtUTC: String?
  public let finishedAtUTC: String?
  /// A later complete-overwrite epoch can establish the current target state
  /// without rewriting this Job's unknown outcome.
  public let supersededByRecoveryEpochID: String?
  /// Present on the distinct recovery Job that established the epoch.
  public let recoveryEpochID: String?
  /// A later complete Flash proved that this Job's historical target was an
  /// HDC alias of the canonical Loader-bound target. The outcome remains
  /// unknown; this independent relation proves only the current target epoch.
  public let resolvedByTargetAliasResolutionID: String?

  public init(
    jobID: String,
    operationReference: String,
    targetID: String,
    state: String,
    waitingForHuman: Bool,
    outcomeUnknown: Bool,
    operationFailure: RuntimeOperationFailure? = nil,
    outstandingResidueCount: Int?,
    timeline: [String],
    processProgress: RuntimeJobProcessProgress? = nil,
    executionMode: String? = nil,
    sessionID: String? = nil,
    threadID: String? = nil,
    workspaceKind: RuntimeWorkspaceKind? = nil,
    actualEffect: String? = nil,
    createdAtUTC: String? = nil,
    startedAtUTC: String? = nil,
    finishedAtUTC: String? = nil,
    supersededByRecoveryEpochID: String? = nil,
    recoveryEpochID: String? = nil,
    resolvedByTargetAliasResolutionID: String? = nil
  ) {
    self.jobID = jobID
    self.operationReference = operationReference
    self.targetID = targetID
    self.state = state
    self.waitingForHuman = waitingForHuman
    self.outcomeUnknown = outcomeUnknown
    self.operationFailure = operationFailure
    self.outstandingResidueCount = outstandingResidueCount
    self.timeline = timeline
    self.processProgress = processProgress
    self.executionMode = executionMode
    self.sessionID = sessionID
    self.threadID = threadID
    self.workspaceKind = workspaceKind
    self.actualEffect = actualEffect
    self.createdAtUTC = createdAtUTC
    self.startedAtUTC = startedAtUTC
    self.finishedAtUTC = finishedAtUTC
    self.supersededByRecoveryEpochID = supersededByRecoveryEpochID
    self.recoveryEpochID = recoveryEpochID
    self.resolvedByTargetAliasResolutionID = resolvedByTargetAliasResolutionID
  }
}

public struct RuntimeJobStatusPage: Sendable, Equatable {
  public let jobs: [RuntimeJobStatus]
  package let nextCursor: String?
}

public enum RuntimeEvidenceAuthorityKind: String, Sendable, Equatable, Codable {
  case defaultReadOnlyPolicy
  case runtimeCapability
  /// Historical evidence only. New Runtime admission never produces this
  /// kind, but old Job records remain decodable and exportable.
  case standingAuthorization
  /// Historical campaign evidence only. New Runtime admission rejects the
  /// corresponding reservation before any Job or dispatch is created.
  case evolutionCampaignConfirmation
}

/// Campaign correlation copied only from the broker-owned durable reservation
/// after its fresh pre-mutation verification. It is evidence provenance and
/// cannot be converted into a live campaign capability.
public struct RuntimeCampaignEvidenceCorrelation: Sendable, Equatable, Codable {
  public let campaignID: String
  public let attemptID: String
  public let attemptOrdinal: Int
  public let planDigestSHA256: String
  public let targetBindingDigestSHA256: String
  public let candidateDigestSHA256: String
  /// Present only when projecting a historical review-bearing campaign.
  public let reviewDigestSHA256: String?
  public let brokerDigestSHA256: String

  public init(
    campaignID: String,
    attemptID: String,
    attemptOrdinal: Int,
    planDigestSHA256: String,
    targetBindingDigestSHA256: String,
    candidateDigestSHA256: String,
    brokerDigestSHA256: String
  ) {
    self.init(
      campaignID: campaignID, attemptID: attemptID, attemptOrdinal: attemptOrdinal,
      planDigestSHA256: planDigestSHA256, targetBindingDigestSHA256: targetBindingDigestSHA256,
      candidateDigestSHA256: candidateDigestSHA256, historicalReviewDigestSHA256: nil,
      brokerDigestSHA256: brokerDigestSHA256)
  }

  public init(
    campaignID: String,
    attemptID: String,
    attemptOrdinal: Int,
    planDigestSHA256: String,
    targetBindingDigestSHA256: String,
    candidateDigestSHA256: String,
    historicalReviewDigestSHA256: String?,
    brokerDigestSHA256: String
  ) {
    self.campaignID = campaignID
    self.attemptID = attemptID
    self.attemptOrdinal = attemptOrdinal
    self.planDigestSHA256 = planDigestSHA256
    self.targetBindingDigestSHA256 = targetBindingDigestSHA256
    self.candidateDigestSHA256 = candidateDigestSHA256
    self.reviewDigestSHA256 = historicalReviewDigestSHA256
    self.brokerDigestSHA256 = brokerDigestSHA256
  }
}

/// Durable correlation for a Runtime-owned capability use. Optional on the
/// admission envelope only so pre-V5 Job records remain decodable.
public struct RuntimeCapabilityEvidenceCorrelation: Sendable, Equatable, Codable {
  public let reservationID: String
  public let useOrdinal: Int
  public let planDigestSHA256: String
  public let stepSetDigestSHA256: String
  public let targetBindingDigestSHA256: String
  public let artifactSHA256: String?

  public init(
    reservationID: String, useOrdinal: Int, planDigestSHA256: String,
    stepSetDigestSHA256: String, targetBindingDigestSHA256: String,
    artifactSHA256: String?
  ) {
    self.reservationID = reservationID
    self.useOrdinal = useOrdinal
    self.planDigestSHA256 = planDigestSHA256
    self.stepSetDigestSHA256 = stepSetDigestSHA256
    self.targetBindingDigestSHA256 = targetBindingDigestSHA256
    self.artifactSHA256 = artifactSHA256
  }
}

struct RuntimeCompleteOverwriteRecoveryContext: Codable, Sendable, Equatable {
  let coveredIntents: [SupersededRecoveryIntent]
  let uncertainEffectSetSHA256: String
  let coverageContractVersion: String
  let coveredEffectSetSHA256: String
  let profileReference: String
  let destructiveEpochOrdinal: Int
}

/// The admission decision actually consumed by this job. This record is
/// audit provenance only: reading or projecting it cannot mint an
/// authority or reach the dispatch port.
public struct RuntimeAdmissionEvidence: Sendable, Equatable, Codable {
  public let kind: RuntimeEvidenceAuthorityKind
  public let reference: String
  public let admittedAtUTC: String
  public let validUntilUTC: String?
  public let consumptionFingerprintSHA256: String?
  /// Optional only for old persisted jobs. New campaign admissions fill this
  /// exclusively from the protected broker reservation.
  public let campaignCorrelation: RuntimeCampaignEvidenceCorrelation?
  public let runtimeCapabilityCorrelation: RuntimeCapabilityEvidenceCorrelation?
  /// Runtime-internal recovery proof captured at the last safe boundary.
  /// It remains inside the persisted admission envelope so old Job record
  /// schema stays frozen and a process restart cannot lose recovery identity.
  var completeOverwriteRecovery: RuntimeCompleteOverwriteRecoveryContext?
  var recoveryProviderExecutableSHA256: String?

  public init(
    kind: RuntimeEvidenceAuthorityKind,
    reference: String,
    admittedAtUTC: String,
    validUntilUTC: String?,
    consumptionFingerprintSHA256: String?,
    campaignCorrelation: RuntimeCampaignEvidenceCorrelation? = nil,
    runtimeCapabilityCorrelation: RuntimeCapabilityEvidenceCorrelation? = nil
  ) {
    self.kind = kind
    self.reference = reference
    self.admittedAtUTC = admittedAtUTC
    self.validUntilUTC = validUntilUTC
    self.consumptionFingerprintSHA256 = consumptionFingerprintSHA256
    self.campaignCorrelation = campaignCorrelation
    self.runtimeCapabilityCorrelation = runtimeCapabilityCorrelation
    self.completeOverwriteRecovery = nil
    self.recoveryProviderExecutableSHA256 = nil
  }
}

public struct RuntimeEvidencePreflightStep: Sendable, Equatable, Codable {
  public let stepID: String
  package let stepKind: String
  package let outcomeAtUTC: String
  /// When set, this fragment was not read from the device for this job: it
  /// was carried from the session's own earlier readback, taken at this
  /// time. Nil means the device answered it during this job. The two are
  /// never merged into one word, because a fact read four minutes ago and a
  /// fact read just now are different claims.
  public var carriedFromUTC: String?

  public init(
    stepID: String, stepKind: String, outcomeAtUTC: String,
    carriedFromUTC: String? = nil
  ) {
    self.stepID = stepID
    self.stepKind = stepKind
    self.outcomeAtUTC = outcomeAtUTC
    self.carriedFromUTC = carriedFromUTC
  }
}

/// Facts assembled only from the three independently journaled, verified
/// typed preflight outcomes belonging to this same job.
public struct RuntimeEvidenceObservation: Sendable, Equatable, Codable {
  public let targetID: String?
  public let bindingRevision: Int?
  package let stableIdentitySHA256: String?
  public let model: String?
  public let firmware: String?
  public let transport: String?
  public let providerID: String
  public let toolVersion: String
  package let toolSHA256: String
  public let confirmedAtUTC: String?
  package let confirmationMethod: String
  package let preflightSteps: [RuntimeEvidencePreflightStep]

  public init(
    targetID: String?,
    bindingRevision: Int?,
    stableIdentitySHA256: String?,
    model: String?,
    firmware: String?,
    transport: String?,
    providerID: String,
    toolVersion: String,
    toolSHA256: String,
    confirmedAtUTC: String?,
    confirmationMethod: String,
    preflightSteps: [RuntimeEvidencePreflightStep]
  ) {
    self.targetID = targetID
    self.bindingRevision = bindingRevision
    self.stableIdentitySHA256 = stableIdentitySHA256
    self.model = model
    self.firmware = firmware
    self.transport = transport
    self.providerID = providerID
    self.toolVersion = toolVersion
    self.toolSHA256 = toolSHA256
    self.confirmedAtUTC = confirmedAtUTC
    self.confirmationMethod = confirmationMethod
    self.preflightSteps = preflightSteps
  }
}

/// Durable, job-local assembly state. It is never exported as evidence
/// until all three fragments are present and correlated.
public struct RuntimeEvidencePreflightAccumulator: Sendable, Equatable, Codable {
  public let targetID: String
  public let bindingRevision: Int
  package let stableIdentitySHA256: String
  public let providerID: String
  public let toolVersion: String
  package let toolSHA256: String
  public var transport: String?
  public var confirmedAtUTC: String?
  public var model: String?
  public var firmware: String?
  public var steps: [RuntimeEvidencePreflightStep]

  package var isComplete: Bool {
    transport != nil && confirmedAtUTC != nil && model != nil && firmware != nil
      && steps.map(\.stepID)
        == ["confirm-evidence-target", "read-evidence-model", "read-evidence-firmware"]
  }
}

/// Product-owned durable facts exposed through the daemon's read-only
/// evidence query. It intentionally contains no claim metadata such as
/// evidence ID or Acceptance IDs.
public struct RuntimeJobEvidenceSnapshot: Sendable, Equatable, Codable {
  public let jobID: String
  public let operationReference: String
  public let catalogDigest: String
  public let targetID: String
  public let bindingRevision: Int?
  public let providerID: String
  public let actualEffect: String?
  public let authority: RuntimeAdmissionEvidence?
  public let observation: RuntimeEvidenceObservation?
  public let actualStepKinds: [String]
  public let executionMode: String
  public let terminalState: String
  public let outcomeUnknown: Bool
  public let startedAtUTC: String?
  public let firstEvidenceStepAtUTC: String?
  public let finishedAtUTC: String?
  package let recoveryEpoch: SupersedingRecoveryEpoch?
  package var traceProbeBefore: TraceRuntimeProbeSnapshot? = nil
  package var traceProbeAfter: TraceRuntimeProbeSnapshot? = nil
  /// Persisted typed inputs for the read-only History parameter inspector.
  /// They remain structured JSON values; no executable or argv can be
  /// reconstructed from this projection.
  public var inputs: [String: JSONValue]? = nil
}

public struct RuntimeJobAcceptance: Sendable, Equatable {
  public let jobID: String
  public let deduplicated: Bool
}

public enum RuntimeAvailabilityState: String, Sendable, Equatable {
  case available
  case unavailable
}

public struct RuntimeOperationAvailability: Sendable, Equatable {
  public let reference: String
  public let state: RuntimeAvailabilityState
  /// Prose, for a person. Positionally paired with `reasonCodes`.
  public let reasons: [String]
  /// The machine-readable half PRODUCT-LOOP §8 requires, in the same order as
  /// `reasons`. `reasons` alone carried four naming conventions at once, so a
  /// caller deciding whether to wait or stop could only substring-match
  /// English prose that reworded silently.
  public let reasonCodes: [RuntimeAvailabilityReasonCode]

  public init(
    reference: String,
    state: RuntimeAvailabilityState,
    reasons: [String],
    reasonCodes: [RuntimeAvailabilityReasonCode]
  ) {
    self.reference = reference
    self.state = state
    self.reasons = reasons
    self.reasonCodes = reasonCodes
  }
}

public enum RuntimeCleanupDebtState: String, Sendable, Equatable {
  case outstanding
  case settled
  case outcomeUnknown
}

public struct RuntimeCleanupDebtContinuation: Sendable, Equatable {
  public let jobID: String
  /// The ledger key that was settled or left outstanding: a remote path,
  /// or `bundle:<name>` for an installed-bundle residue.
  public let identity: String
  public let state: RuntimeCleanupDebtState
  public let detail: String
}

private struct RuntimeHostDispatchCancellation: Error {}

/// A cancellation receipt from the process boundary.  Only the positive
/// `drained` case is strong enough to close an Analyzer intent as cancelled;
/// an unconfirmed process-group teardown remains an unknown external outcome.
enum RuntimeDispatchCancellationResolution: Error, Sendable, Equatable {
  case drained
  case unconfirmed
}

private enum ActiveRuntimeDispatchCancellationMode: Sendable {
  /// The Analyzer child may still be cancelled and drained immediately.
  case immediateAnalyzerOpen
  /// A verified Analyzer result has crossed the success/publication
  /// linearization point. A later request cannot turn a committed success
  /// into a cancelled Job with a published Artifact.
  case analyzerCommitLinearized
  /// Catalog safe-boundary actions record the request durably but finish the
  /// current external step without Task cancellation.
  case safeBoundary
}

private struct ActiveRuntimeDispatch: Sendable {
  let id: UUID
  var cancellationMode: ActiveRuntimeDispatchCancellationMode
  let task: Task<ProviderProcessReceipt, Error>
}

/// Dispatch port: how a lowered process plan actually runs. Production
/// binds the descriptor-verifying executor (MU-3); tests inject fakes,
/// including crash and hang shapes.
public protocol RuntimeProcessDispatching: Sendable {
  func unavailableReason(providerID: String) -> String?
  func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt
  func dispatch(
    _ plan: TypedProcessPlan,
    progress: @escaping RuntimeProcessProgressHandler
  ) async throws -> ProviderProcessReceipt
}

extension RuntimeProcessDispatching {
  package func unavailableReason(providerID: String) -> String? { nil }

  public func dispatch(
    _ plan: TypedProcessPlan,
    progress _: @escaping RuntimeProcessProgressHandler
  ) async throws -> ProviderProcessReceipt {
    try await dispatch(plan)
  }
}

public enum RuntimeProcessProgressPhase: String, Sendable, Equatable, Codable {
  case staging
  case writing
}

/// Wire-safe projection of one active process step's observational progress.
/// The step identity keeps consumers from applying provider progress to a
/// different operation phase after a status refresh.
public struct RuntimeJobProcessProgress: Sendable, Equatable, Codable {
  public let stepID: String
  public let phase: RuntimeProcessProgressPhase
  public let unitName: String?
  public let completedUnitCount: Int
  public let totalUnitCount: Int
  public let currentUnitPercent: Int?

  public init(
    stepID: String,
    phase: RuntimeProcessProgressPhase,
    unitName: String? = nil,
    completedUnitCount: Int,
    totalUnitCount: Int,
    currentUnitPercent: Int? = nil
  ) {
    self.stepID = stepID
    self.phase = phase
    self.unitName = unitName
    self.completedUnitCount = completedUnitCount
    self.totalUnitCount = totalUnitCount
    self.currentUnitPercent = currentUnitPercent
  }

  package init(stepID: String, progress: RuntimeProcessProgress) {
    self.init(
      stepID: stepID,
      phase: progress.phase,
      unitName: progress.unitName,
      completedUnitCount: progress.completedUnitCount,
      totalUnitCount: progress.totalUnitCount,
      currentUnitPercent: progress.currentUnitPercent)
  }
}

/// Closed, observational progress from inside one already-admitted provider
/// action. It cannot select an action, widen a plan, or claim success; Runtime
/// exposes it only as a replaceable status projection while the outer durable
/// intent remains authoritative.
public struct RuntimeProcessProgress: Sendable, Equatable {
  public let phase: RuntimeProcessProgressPhase
  public let unitName: String?
  public let completedUnitCount: Int
  public let totalUnitCount: Int
  public let currentUnitPercent: Int?

  public init(
    phase: RuntimeProcessProgressPhase,
    unitName: String? = nil,
    completedUnitCount: Int,
    totalUnitCount: Int,
    currentUnitPercent: Int? = nil
  ) {
    self.phase = phase
    self.unitName = unitName
    self.completedUnitCount = completedUnitCount
    self.totalUnitCount = totalUnitCount
    self.currentUnitPercent = currentUnitPercent
  }
}

public typealias RuntimeProcessProgressHandler =
  @Sendable (RuntimeProcessProgress) async -> Void

public enum RuntimeDispatchFailure: Error, Equatable, Sendable {
  /// The dispatcher cannot say whether the external effect happened.
  case outcomeUnknown(String)
  /// Exact provider readback proved that the attempted external effect did
  /// not happen. This remains a failed step; only current Runtime policy and
  /// fresh facts may decide whether a later operation is safe.
  case confirmedNotExecuted(String)
  /// Same as `confirmedNotExecuted`, with a closed diagnostic that is safe to
  /// expose through a job timeline to the operator. It must never
  /// contain raw subprocess output or device identity.
  case confirmedNotExecutedWithDiagnostic(
    String, diagnostic: RockchipFlashRuntimeDiagnostic)
  case failed(String)
}

private struct RuntimeArtifactPublicationFailure: Error, Sendable {
  let detail: String
}

/// One-entry cache for the complete Flash profile derived from an exact
/// Runtime-owned Artifact lease. Every caller still resolves that lease
/// through the Artifact store first, which re-hashes and revalidates the
/// controlled bytes at the existing admission and pre-dispatch boundaries.
/// The cache exists only for one RuntimeJobEngine process lifetime and never
/// crosses a lease, artifact identity, path, digest, size or board.
struct RuntimeFlashArchiveProfileCache {
  private struct Key: Equatable {
    let artifactLeaseID: String
    let artifactID: String
    let path: String
    let sha256: String
    let byteCount: Int
    let boardReference: String
  }

  private struct Entry {
    let key: Key
    let profile: RockchipFlashProfile
  }

  private var entry: Entry?

  mutating func resolve(
    artifactLeaseID: String,
    artifact: ProviderResolvedInputArtifact,
    board: RockchipFlashProfile,
    reader: () throws -> RockchipFlashProfile
  ) throws -> RockchipFlashProfile {
    let key = Key(
      artifactLeaseID: artifactLeaseID,
      artifactID: artifact.artifactID,
      path: artifact.fileURL.standardizedFileURL.path,
      sha256: artifact.sha256,
      byteCount: artifact.byteCount,
      boardReference: board.catalogReference)
    if let entry, entry.key == key { return entry.profile }

    let profile = try reader()
    guard profile.catalogReference == board.catalogReference,
      profile.archiveSHA256 == artifact.sha256,
      profile.archiveSizeBytes == Int64(artifact.byteCount)
    else {
      throw RuntimeDispatchFailure.failed(
        "derived Flash profile drifted from its exact Artifact lease")
    }
    entry = Entry(key: key, profile: profile)
    return profile
  }
}

// MARK: - Admission fault injection

/// Crash-consistency test seam. Production uses `.none`; tests inject an
/// error immediately after the named durable boundary, discard the engine and
/// reopen it exactly as a process restart would.
public enum RuntimeAdmissionFaultPoint: String, CaseIterable, Sendable {
  case beforeAdmission
  case afterAdmission
  case beforeJournalAppend
  case afterJournalAppend
  case beforeRecordPersist
  case afterRecordPersist
  case beforeResponse
}

public struct RuntimeAdmissionFaultInjector: @unchecked Sendable {
  private let body: (RuntimeAdmissionFaultPoint) throws -> Void

  public init(_ body: @escaping (RuntimeAdmissionFaultPoint) throws -> Void) {
    self.body = body
  }

  public func check(_ point: RuntimeAdmissionFaultPoint) throws { try body(point) }

  public static let none = RuntimeAdmissionFaultInjector { _ in }
}

// MARK: - Engine

public actor RuntimeJobEngine {
  private static let confirmedNotExecutedSemanticCode = "confirmedNotExecuted"
  /// A confirmed Runtime step whose truth came from one completed ArkForge
  /// plan, not from a process exit string or an ArkDeck provider action.
  ///
  /// Complete-overwrite finalization requires this code on every delegated
  /// recovery step.  That keeps a generic `result=succeeded` row from being
  /// promoted into coverage proof after the mechanics moved behind the
  /// ArkForge authority boundary.
  package static let arkForgePlanCompletionSemanticCode = "arkForgePlanCompletion"

  /// The route a delegated step takes instead of an ArkDeck provider action.
  ///
  /// Injected rather than constructed here: building one needs a running
  /// `arkforged`, a pairing secret and an approved plan, none of which the
  /// engine owns. Absent means this build cannot perform those steps, and the
  /// engine says so at the step rather than pretending otherwise.
  package protocol ArkForgeLane: Sendable {
    /// Exact backend digest this lane was composed against. Immutable and
    /// nonisolated on the production actor so materialization can bind the
    /// StepPermit before any lane call or external effect.
    var toolchainSHA256: String { get }

    /// Makes immutable archive bytes available to the daemon after Runtime
    /// admission, while the engine is still doing host-only work.
    ///
    /// This may mutate only ArkForge's content-addressed host store. It has no
    /// device binding or authority and therefore cannot materialize or start a
    /// device execution. `prepareExecution` still owns those boundaries.
    func prewarmArtifact(
      jobID: String, artifact: ArkForgeLaneArtifact
    ) async throws -> ArkForgeLaneArtifactPrewarmReceipt

    /// Releases only the lane's per-Job preparation bookkeeping. Immutable
    /// content already admitted to ArkForge's content store remains available
    /// for its normal content-addressed reuse.
    func finishArtifactPrewarm(jobID: String) async

    /// Materializes and creates the daemon job, but does not watch it or sign
    /// a permit. Runtime durably records the returned join before calling
    /// `performPrepared`; a crash in this window may orphan a no-effect daemon
    /// job, but can never lose correlation to an external effect.
    func prepareExecution(
      jobID: String, artifact: ArkForgeLaneArtifact,
      binding: ArkForgeLaneDeviceBinding, executionPurpose: String
    ) async throws -> RuntimeArkForgeLaneExecution

    /// Performs one already-correlated delegated step and returns the daemon's semantic receipt.
    ///
    /// Throwing here is a dispatch failure like any other. What must never
    /// happen is returning a receipt the daemon did not publish — the receipt
    /// is the evidence, and inventing one would make a write look confirmed.
    ///
    /// The plan identity is carried by `execution`: it came from ArkForge's
    /// own materialization and daemon job reply, not from ArkDeck's separate
    /// provider plan. Runtime has already persisted and revalidated that join.
    func performPrepared(
      stepID: String, execution: RuntimeArkForgeLaneExecution,
      artifact: ArkForgeLaneArtifact, binding: ArkForgeLaneDeviceBinding
    ) async throws -> ArkForgeActionReceiptSummary

    /// Passively reads an existing daemon job. It never answers admissions,
    /// submits control receipts or creates a replacement job.
    func observeTerminal(
      execution: RuntimeArkForgeLaneExecution
    ) async throws -> ArkForgeFlashSession.Outcome?

    /// The terminal receipt of this job's *completed* lane run, if it ran.
    ///
    /// The delegated postflight still owes the engine's catalog its declared
    /// product; the facts it is built from live in this receipt. A safe
    /// cancellation or unknown terminal is deliberately absent: neither is a
    /// completed plan and neither may satisfy a recovery verification step.
    func completedPlanReceipt(jobID: String) async -> ArkForgeActionReceiptSummary?
  }

  private typealias ArkForgeArtifactPrewarmTask = Task<
    ArkForgeLaneArtifactPrewarmReceipt, Error
  >

  public struct Configuration: Sendable {
    package struct TestHooks: Sendable {
      package let beforeDispatchInstall: (@Sendable (String, String) async -> Void)?
      package let afterAnalyzerCommitLinearization: (@Sendable (String, String) async -> Void)?
      package let afterAnalyzerArtifactPublication: (@Sendable (String, String) async -> Void)?
      package let beforeMutationCapabilityCommit: (@Sendable (String) async -> Void)?

      package init(
        beforeDispatchInstall: (@Sendable (String, String) async -> Void)? = nil,
        afterAnalyzerCommitLinearization:
          (@Sendable (String, String) async -> Void)? = nil,
        afterAnalyzerArtifactPublication:
          (@Sendable (String, String) async -> Void)? = nil,
        beforeMutationCapabilityCommit: (@Sendable (String) async -> Void)? = nil
      ) {
        self.beforeDispatchInstall = beforeDispatchInstall
        self.afterAnalyzerCommitLinearization = afterAnalyzerCommitLinearization
        self.afterAnalyzerArtifactPublication = afterAnalyzerArtifactPublication
        self.beforeMutationCapabilityCommit = beforeMutationCapabilityCommit
      }

      package static let none = TestHooks()
    }

    public let stateDirectory: URL
    public let defaultReadOnlyPolicy: RuntimeDefaultReadOnlyPolicy
    public let admissionFaultInjector: RuntimeAdmissionFaultInjector
    package let testHooks: TestHooks
    /// Absent in every build that has not composed one. A delegated step then
    /// refuses by name instead of failing somewhere less legible.
    package let arkForgeLane: (any ArkForgeLane)?
    /// The exact `id@version` selector `arkforged` filed its DeviceProfile under.
    ///
    /// `materializePlan` looks a profile up by both fields the document
    /// declares, so this travels with the lane rather than being derived from
    /// a path. Composed together with the lane, and empty exactly when the lane
    /// is absent.
    package let arkForgeDeviceProfileID: String?
    /// Exact backend digest selected by the composed ArkForge lane. `nil`
    /// means no delegated step can be materialized or dispatched.
    package let arkForgeToolchainSHA256: String?

    public init(
      stateDirectory: URL,
      defaultReadOnlyPolicy: RuntimeDefaultReadOnlyPolicy = RuntimeDefaultReadOnlyPolicy(),
      admissionFaultInjector: RuntimeAdmissionFaultInjector = .none
    ) {
      self.stateDirectory = stateDirectory
      self.defaultReadOnlyPolicy = defaultReadOnlyPolicy
      self.admissionFaultInjector = admissionFaultInjector
      self.testHooks = .none
      self.arkForgeLane = nil
      self.arkForgeDeviceProfileID = nil
      self.arkForgeToolchainSHA256 = nil
    }

    package init(
      stateDirectory: URL,
      defaultReadOnlyPolicy: RuntimeDefaultReadOnlyPolicy = RuntimeDefaultReadOnlyPolicy(),
      admissionFaultInjector: RuntimeAdmissionFaultInjector = .none,
      testHooks: TestHooks = .none,
      arkForgeLane: (any ArkForgeLane)? = nil,
      arkForgeDeviceProfileID: String? = nil
    ) {
      self.stateDirectory = stateDirectory
      self.defaultReadOnlyPolicy = defaultReadOnlyPolicy
      self.admissionFaultInjector = admissionFaultInjector
      self.testHooks = testHooks
      self.arkForgeLane = arkForgeLane
      self.arkForgeDeviceProfileID = arkForgeDeviceProfileID
      self.arkForgeToolchainSHA256 = arkForgeLane?.toolchainSHA256
    }
  }

  private struct JobRuntime {
    var record: RuntimeJobRecord
    var journal: FileDurableJournal
    var nextSequence: Int
    /// ArkForge-only sidecar loaded from the owning job directory. Keeping
    /// this out of the generic Runtime snapshot preserves the integration
    /// boundary while retaining correlation-before-intent ordering.
    var arkForgeState: ArkForgeRuntimeJobState = .init()
    /// Confirmed provider steps reconstructed from the durable journal.
    /// A clean restart resumes after these exact actions instead of
    /// rebuilding progress from the current catalog.
    var completedStepIDs: Set<String> = []
    /// Steps that did not run. A downstream step whose upstream is here
    /// must not run either - otherwise a failed capture could still
    /// "receive" a product and the run would look complete.
    var skippedStepIDs: Set<String> = []
  }

  private struct ProcessProgressKey: Hashable {
    let jobID: String
    let stepID: String
  }

  private struct MaterializedAdmission: Sendable {
    /// Absent for a host-only plan; a device-bound plan always carries both.
    let stableTargetIdentitySHA256: String?
    let bindingRevision: Int?
    let planDigest: String
    let artifactFacts: [String: String]
    let providerFacts: ProviderFacts?
  }

  private struct PreparedAuthorization: Sendable {
    let reference: RuntimeCapabilityReference?
    let evidence: RuntimeAdmissionEvidence?
    let completeOverwriteRecovery: RuntimeCompleteOverwriteRecoveryContext?
    let recognizedRecoveryEpochID: String?
  }

  /// The steps `arkforged` performs under a StepPermit rather than ArkDeck
  /// dispatching them itself (CHG-2026-059).
  ///
  /// Named here rather than inferred from the step kind: `flashPartition` and
  /// `verifyRemoteState` are catalog kinds other operations also use, and
  /// delegating by kind would silently move somebody else's step to a daemon
  /// that knows nothing about it.
  package static let arkForgeDispatchedSteps: Set<String> = [
    "flash-partitions", "verify-flash-readback",
  ]

  /// The HDC-to-Loader transition ArkDeck performs itself **only** when no
  /// ArkForge lane owns the write.
  ///
  /// `arkforged`'s own plan opens with an `enter-updater` managed control whose
  /// `expected_mode_before` is normal, and it drives that back through ArkDeck's
  /// control port — so with a lane configured the transition still happens here,
  /// just under the plan that owns the write rather than beside it.
  ///
  /// Running this group first consumed the transition: measured 2026-08-18, the
  /// board was already in Loader by the time the lane asked, and the ArkForge
  /// job parked at `permitConsuming` waiting on a control receipt for a
  /// transition that could no longer be observed. Nothing was written.
  package static let arkForgeOwnedModeSteps: Set<String> = [
    "enter-loader-mode", "wait-loader-disconnect", "wait-loader-reconnect",
    "rebind-loader-identity",
    // The lane's plan owns the way back out as well as the way in: its own
    // steps reset the device through the daemon's native RockUSB backend,
    // wait out the first boot, and verify identity plus the published build
    // through the managed-control postflight — all receipted before the lane
    // returns. Running the engine's copies afterwards is not redundancy but
    // failure: `reboot-device` demands a Loader readback from a board the
    // plan already reset to normal (measured 2026-08-18, on the first run
    // whose lane ever completed). Diagnostics capture stays engine-run — the
    // lane's plan has no hilog step.
    "reboot-device", "wait-for-hdc", "rebind-and-verify-build",
  ]

  /// Engine steps that occur after the one ArkForge run has returned.
  ///
  /// Unlike the pre-write Loader bookkeeping above, these are part of the
  /// complete-overwrite recovery contract. They therefore need their own
  /// durable Runtime intents and outcomes, sourced from the completed plan's
  /// terminal semantic receipt, before an epoch can be established.
  package static let arkForgePlanCompletionSteps: Set<String> = [
    "verify-flash-readback", "reboot-device", "wait-for-hdc", "rebind-and-verify-build",
  ]

  /// The `processKind` those steps carry in a materialized plan.
  package static let arkForgeDispatchKind = "arkforgeStepPermit"

  package static func arkForgeStepPermitDescriptor(
    toolchainSHA256: String
  ) -> String {
    "arkforge.stepPermit#toolchain-sha256:\(toolchainSHA256)"
  }

  private struct MaterializedPlanStep: Codable {
    let stepID: String
    let kind: String
    let effect: String
    let cancellation: String
    let binding: String
    let isOptional: Bool
    let journalArguments: [String: JSONValue]?
    let processKind: String
    let executableSHA256: String?
    let argumentZero: String?
    let workingDirectory: String?
    let argumentSummary: [String]?
    let processInvocations: [MaterializedProcessInvocation]?
    let timeoutSeconds: Int?
    let hostManagedDescriptor: String?
  }

  private struct MaterializedProcessInvocation: Codable {
    let arguments: [String]
    let timeoutSeconds: Int?
    let continueAfterNonZero: Bool
  }

  private struct MaterializedPlanDocument: Codable {
    let operationReference: String
    let catalogDigest: String
    let inputs: [String: JSONValue]
    let targetID: String
    /// Absent for a host-only plan: there is no device to identify, and
    /// omitting the field is what keeps the digest honest. Device-bound plans
    /// still carry both, and `encodeIfPresent` leaves their bytes - and their
    /// digests - unchanged.
    let stableTargetIdentitySHA256: String?
    let bindingRevision: Int?
    let providerID: String
    /// Present only for a Runtime-owned debug attempt. These pins make the
    /// candidate's effect-level broker action part of the authorized
    /// materialized plan; ordinary Jobs retain their existing digest bytes.
    let runtimeDebugInvocationID: String?
    let runtimeDebugCandidateActionSHA256: String?
    let steps: [MaterializedPlanStep]

    enum CodingKeys: String, CodingKey {
      case operationReference
      case catalogDigest
      case inputs
      case targetID
      case stableTargetIdentitySHA256
      case bindingRevision
      case providerID
      case runtimeDebugInvocationID
      case runtimeDebugCandidateActionSHA256
      case steps
    }

    func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: CodingKeys.self)
      try container.encode(operationReference, forKey: .operationReference)
      try container.encode(catalogDigest, forKey: .catalogDigest)
      try container.encode(inputs, forKey: .inputs)
      try container.encode(targetID, forKey: .targetID)
      try container.encodeIfPresent(
        stableTargetIdentitySHA256, forKey: .stableTargetIdentitySHA256)
      try container.encodeIfPresent(bindingRevision, forKey: .bindingRevision)
      try container.encode(providerID, forKey: .providerID)
      try container.encodeIfPresent(
        runtimeDebugInvocationID, forKey: .runtimeDebugInvocationID)
      try container.encodeIfPresent(
        runtimeDebugCandidateActionSHA256, forKey: .runtimeDebugCandidateActionSHA256)
      try container.encode(steps, forKey: .steps)
    }
  }

  /// Authorization binds the typed plan template, not the per-execution
  /// Job identifier embedded in owned temporary paths. Runtime dispatch
  /// still materializes each path with its real Job ID, preserving
  /// isolation; this stable context lets the same reviewed envelope cover
  /// repeated executions of the unchanged semantic plan.
  private static let authorizationPlanJobID = "job-authorization-envelope"

  private let configuration: Configuration
  private let providers: DeviceProviderRegistry
  private let dispatcher: any RuntimeProcessDispatching
  private let capabilityStore: RuntimeCapabilityStore
  private let artifactStore: RuntimeArtifactStore?
  private let workspaceProjectStore: RuntimeWorkspaceProjectStore?
  private let traceRuntimeProbe: (any TraceRuntimeProbing)?
  /// Present in the production daemon. A lease spans only an actively
  /// executing real Job and prevents idle *system* sleep; display sleep,
  /// screen lock, lid closure and explicit sleep remain unaffected.
  private let powerActivityController: PowerActivityController?
  /// Campaign-lane E2 authority ledger, shared (file plus flock) with the
  /// campaign admission service that mints reservations. Absent means this
  /// runtime cannot honor campaign-reservation requests and refuses them.
  private let agentUsageLedger: AgentAuthorityUsageLedger?
  private let mutationLane = DeviceMutationLaneCoordinator()
  private let admissionService: RuntimeAdmissionService
  private let nowUTC: @Sendable () -> String
  /// The same instant at whatever finer resolution the composition root can
  /// offer. It defaults to `nowUTC`, so a test pinning the clock still gets a
  /// pinned - and therefore comparable - observation window.
  private let nowPreciseUTC: @Sendable () -> String
  private var jobs: [String: JobRuntime] = [:]
  private var jobRuns: [String: Task<RuntimeJobStatus, Error>] = [:]
  private var hdcLifecycleInterlockID: UUID?
  private var cancellationRequests: Set<String> = []
  private var activeDispatches: [String: ActiveRuntimeDispatch] = [:]
  private var flashArchiveProfileCache = RuntimeFlashArchiveProfileCache()
  private var activeProcessProgressKeys: Set<ProcessProgressKey> = []
  private var latestProcessProgress: [ProcessProgressKey: RuntimeProcessProgress] = [:]
  private var latestSucceededDeviceObservationCache: [String: RuntimeEvidenceObservation]?

  public init(
    configuration: Configuration,
    providers: DeviceProviderRegistry,
    dispatcher: any RuntimeProcessDispatching,
    capabilityStore: RuntimeCapabilityStore,
    artifactStore: RuntimeArtifactStore? = nil,
    workspaceProjectStore: RuntimeWorkspaceProjectStore? = nil,
    traceRuntimeProbe: (any TraceRuntimeProbing)? = nil,
    powerActivityController: PowerActivityController? = nil,
    agentUsageLedger: AgentAuthorityUsageLedger? = nil,
    nowUTC: @escaping @Sendable () -> String,
    nowPreciseUTC: (@Sendable () -> String)? = nil
  ) throws {
    self.configuration = configuration
    self.providers = providers
    self.dispatcher = dispatcher
    self.capabilityStore = capabilityStore
    self.artifactStore = artifactStore
    self.workspaceProjectStore = workspaceProjectStore
    self.traceRuntimeProbe = traceRuntimeProbe
    self.powerActivityController = powerActivityController
    self.agentUsageLedger = agentUsageLedger
    self.nowUTC = nowUTC
    self.nowPreciseUTC = nowPreciseUTC ?? nowUTC
    try FileManager.default.createDirectory(
      at: configuration.stateDirectory.appending(path: "jobs", directoryHint: .isDirectory),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    self.admissionService = try RuntimeAdmissionService(
      stateDirectory: configuration.stateDirectory)
  }

  public func operationAvailability() -> [RuntimeOperationAvailability] {
    RuntimeOperationCatalog.operations.map { descriptor in
      guard let provider = providers.provider(id: descriptor.provider.rawValue) else {
        return RuntimeOperationAvailability(
          reference: descriptor.reference,
          state: .unavailable,
          reasons: ["provider \(descriptor.provider.rawValue) is not registered"],
          reasonCodes: [.providerNotRegistered])
      }
      var reasons: [String] = []
      var reasonCodes: [RuntimeAvailabilityReasonCode] = []
      if case .unavailable(let code, let reason) = provider.runtimeAvailability(for: descriptor) {
        reasons.append(reason)
        reasonCodes.append(code)
      }
      if let reason = dispatcher.unavailableReason(providerID: descriptor.provider.rawValue) {
        if !reasons.contains(reason) {
          reasons.append(reason)
          // Every dispatcher answers this the same way: the executable, the
          // bundled component or the host record root it needs is missing or
          // unreadable. None of them reports a drifted identity — the identity
          // checks live in the providers above.
          reasonCodes.append(.providerToolUnavailable)
        }
      }
      if RuntimeArtifactService.requiresArtifactStore(reference: descriptor.reference),
        artifactStore == nil
      {
        reasons.append("runtime.artifactStoreUnavailable")
        reasonCodes.append(.artifactStoreUnavailable)
      }
      return RuntimeOperationAvailability(
        reference: descriptor.reference,
        state: reasons.isEmpty ? .available : .unavailable,
        reasons: reasons,
        reasonCodes: reasonCodes)
    }.sorted { $0.reference < $1.reference }
  }

  /// Materializes the exact typed plan through the same provider, target
  /// facts and Artifact lease path used by admission, then stops. This is the
  /// Effect-safe inspection surface: no capability may be supplied, no Job is
  /// admitted, and no dispatcher method is called.
  public func planOnly(_ requestData: Data) async throws -> RuntimePlanOnlyPreview {
    let request: RuntimeOperationRequest
    do {
      request = try RuntimeOperationCodec.decodeRequest(requestData)
    } catch let rejection as RuntimeOperationRequestRejection {
      throw RuntimeJobEngineError.rejected(rejection.code, rejection.message)
    }
    guard request.authorization == nil else {
      throw RuntimeJobEngineError.rejected(
        .invalidRequest,
        "planOnly does not accept or consume a Runtime capability")
    }
    guard
      let descriptor = RuntimeOperationCatalog.descriptor(
        id: request.operation.id, version: request.operation.version)
    else {
      throw RuntimeJobEngineError.rejected(
        .unknownOperation, "operation \(request.operation.reference) is not in the catalog")
    }
    try validateInputs(request.inputs, against: descriptor)
    try validateSupportedPlanInputs(request.inputs, descriptor: descriptor)

    let encoder = CanonicalJSONEncoders.canonical()
    let canonicalRequestData: Data
    do {
      canonicalRequestData = try encoder.encode(request)
    } catch {
      throw RuntimeJobEngineError.internalFailure(
        "cannot canonicalize the typed plan-only request: \(error)")
    }
    let importUse = try await acquireImportInputs(request.inputs, descriptor: descriptor)
    let workspaceUse: RuntimeWorkspaceProjectUseToken?
    do {
      workspaceUse = try acquireWorkspaceProjectInput(
        request.inputs, descriptor: descriptor)
    } catch {
      if let importUse, let artifactStore { await artifactStore.endImportUse(importUse) }
      throw error
    }
    do {
      let materialized = try await materializeTypedPlanBeforeAuthorization(
        request: request, descriptor: descriptor,
        jobID: Self.authorizationPlanJobID)
      let selectedSteps = descriptor.steps.filter {
        Self.stepIsRequested($0, descriptor: descriptor, inputs: request.inputs)
      }
      // What this plan would need, answered without acquiring any of it.
      //
      // `planOnly` stops before `preauthorize` on purpose and still does: the
      // three values below are read from what materialization already produced.
      // Nothing here reserves, consumes, issues or looks up a capability, and
      // no lineage or ledger row is written — the preview only reports which
      // gate a submit would meet, which is the question a caller previously had
      // to answer by submitting.
      let effectiveEffect = Self.effectiveEffect(
        descriptor: descriptor, inputs: request.inputs)
      let providerBlocker: String? = {
        guard let facts = materialized.providerFacts,
          let provider = providers.provider(id: descriptor.provider.rawValue)
        else { return nil }
        return provider.executionAdmissionBlocker(for: descriptor, facts: facts)
      }()
      let preview = RuntimePlanOnlyPreview(
        executionMode: "planOnly",
        operationReference: descriptor.reference,
        targetID: request.target.targetID,
        bindingRevision: materialized.bindingRevision,
        stableIdentitySHA256: materialized.stableTargetIdentitySHA256,
        providerID: descriptor.provider.rawValue,
        catalogDigest: RuntimeOperationCatalog.catalogDigest,
        requestFingerprintSHA256: Self.fingerprint(of: canonicalRequestData),
        materializedPlanDigest: materialized.planDigest,
        inputs: request.inputs,
        steps: selectedSteps.map {
          RuntimePlanOnlyStep(
            stepID: $0.stepID, kind: $0.kind.rawValue,
            effect: $0.effect.rawValue,
            cancellation: $0.cancellation.rawValue,
            binding: $0.binding.rawValue, isOptional: $0.isOptional)
        },
        effectiveEffect: effectiveEffect.rawValue,
        authorizationPolicy: descriptor.authorization[effectiveEffect]?.rawValue,
        providerAdmissionBlocker: providerBlocker,
        jobAdmitted: false,
        dispatchDisposition: "notDispatched")
      if let importUse, let artifactStore { await artifactStore.endImportUse(importUse) }
      if let workspaceUse { workspaceProjectStore?.endUse(workspaceUse) }
      return preview
    } catch {
      if let importUse, let artifactStore { await artifactStore.endImportUse(importUse) }
      if let workspaceUse { workspaceProjectStore?.endUse(workspaceUse) }
      throw error
    }
  }

  private func acquireImportInputs(_ inputs: [String: JSONValue], descriptor: CatalogOperationDescriptor) async throws -> RuntimeImportUseToken? {
    let references: [RuntimeImportLeaseReference]
    do { references = try RuntimeImportLeaseReference.inputs(inputs, descriptor: descriptor) }
    catch { throw RuntimeJobEngineError.rejected(.invalidInput, "Import input references are malformed") }
    return try await artifactStore?.acquireImportInputs(references)
  }

  private func acquireWorkspaceProjectInput(
    _ inputs: [String: JSONValue], descriptor: CatalogOperationDescriptor
  ) throws -> RuntimeWorkspaceProjectUseToken? {
    guard descriptor.provider == .workspace, let workspaceProjectStore else { return nil }
    // The isolation-store sweep intentionally has no projectRef: its subject
    // is Runtime-owned derived copies as a whole. All per-project operations
    // declare the typed field and must acquire the exact registration below.
    guard descriptor.inputs.contains(where: { $0.name == "projectRef" }) else { return nil }
    guard case .string(let projectRef)? = inputs["projectRef"] else {
      throw RuntimeJobEngineError.rejected(
        .invalidInput, "workspace operation requires a registered projectRef")
    }
    let presetInputNames: Set<String> = [
      "buildPresetRef", "testPresetRef", "signingPresetRef", "symbolPresetRef",
    ]
    let presetRefs = descriptor.inputs.compactMap { input -> String? in
      guard presetInputNames.contains(input.name),
        case .string(let value)? = inputs[input.name]
      else { return nil }
      return value
    }
    do {
      return try workspaceProjectStore.acquireUse(
        projectRef: projectRef, presetRefs: presetRefs)
    }
    catch let failure as RuntimeWorkspaceProjectFailure {
      let code: RuntimeOperationErrorCode
      switch failure.code {
      case "workspaceReferenceNotFound": code = .invalidInput
      case "operationUnavailable": code = .unsupportedProfile
      default: code = .conflict
      }
      throw RuntimeJobEngineError.rejected(
        code, failure.message)
    }
  }

  package func workspaceProjectList() throws -> [RuntimeWorkspaceProjectResource] {
    guard let workspaceProjectStore else {
      throw AgentExecutionControlFailure(
        "operationUnavailable", "workspace project registration owner is unavailable")
    }
    return try workspaceProjectStore.list()
  }

  package func workspaceProjectInspect(
    projectRef: String
  ) throws -> RuntimeWorkspaceProjectResource {
    guard let workspaceProjectStore else {
      throw AgentExecutionControlFailure(
        "operationUnavailable", "workspace project registration owner is unavailable")
    }
    return try workspaceProjectStore.inspect(projectRef)
  }

  package func workspaceProjectRegister(
    requestID: String, kind: String, rootPath: String
  ) throws -> RuntimeWorkspaceProjectResource {
    guard let workspaceProjectStore else {
      throw AgentExecutionControlFailure(
        "operationUnavailable", "workspace project registration owner is unavailable")
    }
    return try workspaceProjectStore.register(
      requestID: requestID, kind: kind, rootPath: rootPath)
  }

  package func workspaceProjectUpdate(
    projectRef: String, expectedGeneration: UInt64, kind: String, rootPath: String
  ) throws -> RuntimeWorkspaceProjectResource {
    guard let workspaceProjectStore else {
      throw AgentExecutionControlFailure(
        "operationUnavailable", "workspace project registration owner is unavailable")
    }
    return try workspaceProjectStore.update(
      projectRef: projectRef, expectedGeneration: expectedGeneration,
      kind: kind, rootPath: rootPath,
      requireNoActiveReference: admissionService.requireNoActiveWorkspaceProjectReference)
  }

  package func workspaceProjectRemove(
    projectRef: String, expectedGeneration: UInt64
  ) throws -> RuntimeWorkspaceProjectResource {
    guard let workspaceProjectStore else {
      throw AgentExecutionControlFailure(
        "operationUnavailable", "workspace project registration owner is unavailable")
    }
    return try workspaceProjectStore.remove(
      projectRef: projectRef, expectedGeneration: expectedGeneration,
      requireNoActiveReference: admissionService.requireNoActiveWorkspaceProjectReference)
  }

  package func workspacePresetList(
    projectRef: String, kind: String?
  ) throws -> [RuntimeWorkspacePresetResource] {
    guard let workspaceProjectStore else {
      throw AgentExecutionControlFailure(
        "operationUnavailable", "workspace preset registration owner is unavailable")
    }
    return try workspaceProjectStore.listPresets(projectRef: projectRef, kind: kind)
  }

  package func workspacePresetInspect(
    projectRef: String, presetRef: String
  ) throws -> RuntimeWorkspacePresetResource {
    guard let workspaceProjectStore else {
      throw AgentExecutionControlFailure(
        "operationUnavailable", "workspace preset registration owner is unavailable")
    }
    return try workspaceProjectStore.inspectPreset(
      projectRef: projectRef, presetRef: presetRef)
  }

  package func workspacePresetRegister(
    requestID: String, projectRef: String, kind: String, templateRef: String,
    toolchainRef: String?, toolchainGeneration: UInt64?, credentialRef: String?,
    timeoutSeconds: Int, constraints: RuntimeWorkspacePresetConstraints
  ) throws -> RuntimeWorkspacePresetResource {
    guard let workspaceProjectStore else {
      throw AgentExecutionControlFailure(
        "operationUnavailable", "workspace preset registration owner is unavailable")
    }
    return try workspaceProjectStore.registerPreset(
      requestID: requestID, projectRef: projectRef, kind: kind, templateRef: templateRef,
      toolchainRef: toolchainRef, toolchainGeneration: toolchainGeneration,
      credentialRef: credentialRef, timeoutSeconds: timeoutSeconds, constraints: constraints)
  }

  package func workspacePresetUpdate(
    requestID: String, projectRef: String, presetRef: String,
    expectedGeneration: UInt64, kind: String, templateRef: String,
    toolchainRef: String?, toolchainGeneration: UInt64?, credentialRef: String?,
    timeoutSeconds: Int, constraints: RuntimeWorkspacePresetConstraints
  ) throws -> RuntimeWorkspacePresetResource {
    guard let workspaceProjectStore else {
      throw AgentExecutionControlFailure(
        "operationUnavailable", "workspace preset registration owner is unavailable")
    }
    return try workspaceProjectStore.updatePreset(
      requestID: requestID, projectRef: projectRef, presetRef: presetRef,
      expectedGeneration: expectedGeneration, kind: kind, templateRef: templateRef,
      toolchainRef: toolchainRef, toolchainGeneration: toolchainGeneration,
      credentialRef: credentialRef, timeoutSeconds: timeoutSeconds, constraints: constraints,
      requireNoActiveReference: admissionService.requireNoActiveWorkspacePresetReference)
  }

  package func workspacePresetRemove(
    requestID: String, projectRef: String, presetRef: String,
    expectedGeneration: UInt64
  ) throws -> RuntimeWorkspacePresetResource {
    guard let workspaceProjectStore else {
      throw AgentExecutionControlFailure(
        "operationUnavailable", "workspace preset registration owner is unavailable")
    }
    return try workspaceProjectStore.removePreset(
      requestID: requestID, projectRef: projectRef, presetRef: presetRef,
      expectedGeneration: expectedGeneration,
      requireNoActiveReference: admissionService.requireNoActiveWorkspacePresetReference)
  }

  package func releaseImport(id: String, generation: Int) async throws -> JSONValue {
    guard let artifactStore else { throw AgentExecutionControlFailure("operationUnavailable", "Import store is unavailable") }
    let admission = admissionService
    return try await artifactStore.releaseImport(id: id, generation: generation) { id in
      try admission.requireNoActiveImportReference(id)
    }
  }

  package func inspectImportReferences(id: String?, requestID: String?) async throws -> JSONValue {
    guard let artifactStore else { throw AgentExecutionControlFailure("operationUnavailable", "Import store is unavailable") }
    let admission = admissionService
    return try await artifactStore.inspectImportReferences(id: id, requestID: requestID) { id in
      try admission.activeImportReferenceJobs(id)
    }
  }

  // MARK: Submit

  public func submit(_ requestData: Data) async throws -> RuntimeJobAcceptance {
    try await submitOwned(requestData, beforeAdmission: nil)
  }

  /// The negotiated control owner needs the same typed reviewed-plan refusal
  /// as AgentExecution, without gaining orchestration authority. The empty
  /// callback changes no plan or deadline; its presence only asks
  /// `submitOwned` to surface a reviewed-plan mismatch as the stable
  /// `reviewedPlanMismatch` control reason instead of the frozen 1.x
  /// `rejected(.conflict)` shape.
  package func submitForTargetControl(
    _ requestData: Data
  ) async throws -> RuntimeJobAcceptance {
    try await submitOwned(requestData, beforeAdmission: {})
  }

  /// The Runtime orchestration owner may impose an additional deadline on
  /// *creating* a Job. It cannot relax any admission rule, supply facts, or
  /// change the operation/plan/capability budget of an accepted Job.
  package func submitForAgent(
    _ requestData: Data, beforeAdmission: @escaping @Sendable () throws -> Void
  ) async throws -> RuntimeJobAcceptance {
    try await submitOwned(requestData, beforeAdmission: beforeAdmission)
  }

  /// Validate declared inputs before creating physical-assistance resources.
  /// This shares the admission validator without reading facts or admitting a Job.
  package func validateAgentIntent(_ intent: AgentExecutionIntent) throws {
    guard let descriptor = RuntimeOperationCatalog.descriptor(reference: intent.operationReference) else {
      throw RuntimeJobEngineError.rejected(.unknownOperation, "operation is not published")
    }
    try validateInputs(intent.inputs, against: descriptor)
    try validateSupportedPlanInputs(intent.inputs, descriptor: descriptor)
  }

  /// Reconcile the acceptance-to-owner-publication crash window without
  /// admitting anything. The exact original request is required; an ID alone
  /// is never permission to attach an unrelated Job to an execution.
  package func acceptedJobForAgent(_ requestData: Data) throws -> RuntimeJobAcceptance? {
    let request = try RuntimeOperationCodec.decodeRequest(requestData)
    let fingerprint = Self.fingerprint(of: try CanonicalJSONEncoders.canonical().encode(request))
    switch try admissionService.lookup(idempotencyKey: request.idempotencyKey, requestHash: fingerprint) {
    case .duplicate(let jobID):
      if let digest = try Self.reviewedPlanDigest(in: requestData),
        try recordForRead(jobID: jobID).materializedPlanDigest != digest {
        throw AgentExecutionControlFailure("reviewedPlanMismatch", "the recovered Job differs from the immutable reviewed plan")
      }
      return RuntimeJobAcceptance(jobID: jobID, deduplicated: true)
    case .conflict: throw RuntimeJobEngineError.idempotencyConflict("execution submission identity changed")
    case .admitted: return nil
    }
  }

  private func submitOwned(
    _ requestData: Data, beforeAdmission: (@Sendable () throws -> Void)?
  ) async throws -> RuntimeJobAcceptance {
    let request: RuntimeOperationRequest
    do {
      request = try RuntimeOperationCodec.decodeRequest(requestData)
    } catch let rejection as RuntimeOperationRequestRejection {
      throw RuntimeJobEngineError.rejected(rejection.code, rejection.message)
    }
    guard
      let descriptor = RuntimeOperationCatalog.descriptor(
        id: request.operation.id, version: request.operation.version)
    else {
      throw RuntimeJobEngineError.rejected(
        .unknownOperation, "operation \(request.operation.reference) is not in the catalog")
    }
    try validateInputs(request.inputs, against: descriptor)
    try validateSupportedPlanInputs(request.inputs, descriptor: descriptor)
    let reviewedPlanDigest = try Self.reviewedPlanDigest(in: requestData)

    // A retry/conflict is decided before capability consumption. Otherwise
    // a conflicting request could consume a different capability and then
    // be rejected by the idempotency ledger.
    let canonicalRequestData: Data
    do {
      let encoder = CanonicalJSONEncoders.canonical()
      canonicalRequestData = try encoder.encode(request)
    } catch {
      throw RuntimeJobEngineError.internalFailure(
        "cannot canonicalize the typed request: \(error)")
    }
    let fingerprint = Self.fingerprint(of: canonicalRequestData)
    switch try admissionService.lookup(
      idempotencyKey: request.idempotencyKey, requestHash: fingerprint)
    {
    case .duplicate(let existingJobID):
      if let reviewedPlanDigest {
        let existing = try recordForRead(jobID: existingJobID)
        guard existing.materializedPlanDigest == reviewedPlanDigest else {
          if beforeAdmission != nil {
            throw AgentExecutionControlFailure("reviewedPlanMismatch", "the existing Job differs from the immutable reviewed plan")
          }
          throw RuntimeJobEngineError.rejected(
            .conflict,
            "deduplicated job plan digest differs from the reviewed plan; zero new dispatch")
        }
      }
      return RuntimeJobAcceptance(jobID: existingJobID, deduplicated: true)
    case .conflict:
      throw RuntimeJobEngineError.idempotencyConflict(
        "idempotency key reuse with a different request")
    case .admitted:
      break
    }

    guard hdcLifecycleInterlockID == nil else {
      throw RuntimeJobEngineError.rejected(
        .conflict,
        "a confirmed host-wide HDC lifecycle action currently blocks new Job admission")
    }

    // Authorization must reflect what this request will actually do, not
    // the operation's floor. capture.diagnostics@1 is readOnly until the
    // inputs select the remote-file trace and its cleanup, at which point
    // it mutates the device and needs an E1 capability. Charging the
    // minimum effect here would let a mutating plan through on the default
    // read-only policy.
    let effectiveEffect = Self.effectiveEffect(
      descriptor: descriptor, inputs: request.inputs)
    if effectiveEffect >= .deviceMutation,
      let bindingRevision = request.target.expectedBindingRevision
    {
      try await repairProvablyTerminalCapabilityOutcomeGaps(
        targetID: request.target.targetID,
        bindingRevision: bindingRevision)
    }
    let jobID = Self.stableJobID(
      idempotencyKey: request.idempotencyKey, requestFingerprint: fingerprint)
    let importUse = try await acquireImportInputs(request.inputs, descriptor: descriptor)
    let workspaceUse: RuntimeWorkspaceProjectUseToken?
    do {
      workspaceUse = try acquireWorkspaceProjectInput(
        request.inputs, descriptor: descriptor)
    } catch {
      if let importUse, let artifactStore { await artifactStore.endImportUse(importUse) }
      throw error
    }
    do {
      try beforeAdmission?()
      let materialized = try await materializeTypedPlanBeforeAuthorization(
        request: request, descriptor: descriptor,
        jobID: Self.authorizationPlanJobID)
      if let reviewedPlanDigest {
        guard materialized.planDigest == reviewedPlanDigest else {
          if beforeAdmission != nil {
            throw AgentExecutionControlFailure("reviewedPlanMismatch", "the fresh materialized plan differs from the immutable reviewed plan")
          }
          throw RuntimeJobEngineError.rejected(
            .conflict,
            "materialized plan digest changed after review; zero admission and zero dispatch")
        }
      }
      let preparedAuthorization = try await preauthorize(
        request: request, descriptor: descriptor, effect: effectiveEffect,
        materialized: materialized)
      let persistedRequest: RuntimeOperationRequest
      if preparedAuthorization.reference == request.authorization {
        persistedRequest = request
      } else {
        do {
          persistedRequest = try RuntimeOperationRequest(
            requestID: request.requestID,
            idempotencyKey: request.idempotencyKey,
            target: request.target,
            operation: request.operation,
            inputs: request.inputs,
            requestedOutputs: request.requestedOutputs,
            authorization: preparedAuthorization.reference,
            clientContext: request.clientContext)
        } catch let rejection as RuntimeOperationRequestRejection {
          throw RuntimeJobEngineError.rejected(rejection.code, rejection.message)
        }
      }

      let timestamp = nowUTC()
      var record = RuntimeJobRecord(
        jobID: jobID,
        request: persistedRequest,
        operationReference: descriptor.reference,
        catalogDigest: RuntimeOperationCatalog.catalogDigest,
        providerID: descriptor.provider.rawValue,
        createdAtUTC: timestamp,
        actualEffect: effectiveEffect.rawValue,
        admissionEvidence: preparedAuthorization.evidence,
        materializedPlanDigest: materialized.planDigest,
        materializedStableTargetIdentitySHA256:
          materialized.stableTargetIdentitySHA256,
        materializedBindingRevision: materialized.bindingRevision)
      record.originalSubmissionRequest = request
      record.state = JobState.preflight.rawValue
      record.timeline = ["jobCreated", "queued->preflight"]
      if let recovery = preparedAuthorization.completeOverwriteRecovery {
        record.timeline.append(
          "complete-overwrite recovery classified epoch \(recovery.destructiveEpochOrdinal); "
            + "covered intents \(recovery.coveredIntents.count)")
      }
      if let epochID = preparedAuthorization.recognizedRecoveryEpochID {
        record.timeline.append(
          "recognized durable complete-overwrite supersession \(epochID); device dispatch 0")
      }
      // The Import hold prevents release throughout materialization and
      // admission. Keep SQLite admission, journal initialization and Runtime
      // residency synchronous: a concurrent retry cannot see an accepted Job
      // before it is runnable. Only then return the hold to the Artifact actor,
      // where durable Job references continue to block release across restart.
      try beforeAdmission?()
      guard hdcLifecycleInterlockID == nil else {
        throw RuntimeJobEngineError.rejected(
          .conflict,
          "a confirmed host-wide HDC lifecycle action currently blocks new Job admission")
      }
      try configuration.admissionFaultInjector.check(.beforeAdmission)
      let verdict = try admissionService.admit(record: record, requestHash: fingerprint)
      switch verdict {
      case .duplicate(let existingJobID):
        if let reviewedPlanDigest {
          let existing = try recordForRead(jobID: existingJobID)
          guard existing.materializedPlanDigest == reviewedPlanDigest else {
            throw RuntimeJobEngineError.rejected(
              .conflict,
              "concurrent duplicate plan digest differs from the reviewed plan; zero new dispatch")
          }
        }
        if let importUse, let artifactStore { await artifactStore.endImportUse(importUse) }
        if let workspaceUse { workspaceProjectStore?.endUse(workspaceUse) }
        return RuntimeJobAcceptance(jobID: existingJobID, deduplicated: true)
      case .conflict:
        throw RuntimeJobEngineError.idempotencyConflict(
          "idempotency key reuse with a different request")
      case .admitted:
        break
      }
      try configuration.admissionFaultInjector.check(.afterAdmission)

      let jobDirectory = configuration.stateDirectory
        .appending(path: "jobs", directoryHint: .isDirectory)
        .appending(path: jobID, directoryHint: .isDirectory)
      try FileManager.default.createDirectory(
        at: jobDirectory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      let journal = try FileDurableJournal(url: jobDirectory.appending(path: "journal.jsonl"))
      try configuration.admissionFaultInjector.check(.beforeJournalAppend)
      try journal.appendAndSynchronize(
        JournalEvent.jobCreated(
          eventID: "job-created", sequence: 0, sessionID: record.sessionID, jobID: jobID,
          timestamp: timestamp, executionMode: "execute",
          schemaVersion: Self.journalSchemaVersion(of: record)))
      try journal.appendAndSynchronize(
        JournalEvent.stateTransition(
          eventID: "to-preflight", sequence: 1, sessionID: record.sessionID, jobID: jobID,
          timestamp: timestamp, from: .queued, to: .preflight, reason: "admitted",
          schemaVersion: Self.journalSchemaVersion(of: record)))
      try configuration.admissionFaultInjector.check(.afterJournalAppend)
      try configuration.admissionFaultInjector.check(.beforeRecordPersist)
      try persistRuntimeRecord(record)
      try configuration.admissionFaultInjector.check(.afterRecordPersist)
      jobs[jobID] = JobRuntime(record: record, journal: journal, nextSequence: 2)
      try configuration.admissionFaultInjector.check(.beforeResponse)
      if let importUse, let artifactStore { await artifactStore.endImportUse(importUse) }
      if let workspaceUse { workspaceProjectStore?.endUse(workspaceUse) }
      return RuntimeJobAcceptance(jobID: jobID, deduplicated: false)
    } catch {
      if let importUse, let artifactStore { await artifactStore.endImportUse(importUse) }
      if let workspaceUse { workspaceProjectStore?.endUse(workspaceUse) }
      throw error
    }
  }

  // MARK: Run

  public func run(jobID: String) async throws -> RuntimeJobStatus {
    if let existing = jobRuns[jobID] { return try await existing.value }
    // All callers join the same driver. Actor reentrancy during provider
    // awaits must not let Agent recovery and a control request run one Job's
    // confirmed boundary twice. Client cancellation does not cancel the Job.
    let task = Task {
      defer { jobRuns.removeValue(forKey: jobID) }
      return try await runOwned(jobID: jobID)
    }
    jobRuns[jobID] = task
    return try await task.value
  }

  /// The negotiated control owner needs an exact pre-dispatch answer when a
  /// Job is absent or already terminal. The generic `run` error cannot carry
  /// that phase: the same `jobNotFound` case may also surface after provider
  /// work has begun. This check runs inside the engine actor immediately
  /// before joining/starting the one shared driver, so only this wrapper may
  /// publish zero-new-dispatch evidence for those initial states.
  package func runForTargetControl(jobID: String) async throws -> RuntimeJobStatus {
    if jobs[jobID] == nil, jobRuns[jobID] == nil {
      do {
        let persisted = try recordForRead(jobID: jobID)
        throw AgentExecutionControlFailure(
          "resourceConflict", "job \(jobID) is \(persisted.state), not runnable",
          details: [
            "jobId": .string(jobID), "phase": .string("preAdmission"),
            "newDispatchCount": .integer(0),
          ])
      } catch RuntimeJobEngineError.jobNotFound {
        throw AgentExecutionControlFailure(
          "resourceNotFound", "the referenced Job does not exist",
          details: [
            "jobId": .string(jobID), "phase": .string("preAdmission"),
            "newDispatchCount": .integer(0),
          ])
      } catch RuntimeJobEngineError.jobRecordUnreadable {
        throw AgentExecutionControlFailure(
          "recordUnreadable", "the referenced Job record is unreadable",
          details: [
            "jobId": .string(jobID), "phase": .string("preAdmission"),
            "newDispatchCount": .integer(0),
          ])
      }
    }
    return try await run(jobID: jobID)
  }

  private func runOwned(jobID: String) async throws -> RuntimeJobStatus {
    guard var runtime = jobs[jobID] else {
      throw RuntimeJobEngineError.jobNotFound(jobID)
    }
    guard
      runtime.record.state == JobState.preflight.rawValue
        || runtime.record.state == JobState.running.rawValue
        || runtime.record.state == JobState.recoveringByCompleteOverwrite.rawValue
        || runtime.record.state == JobState.resumeAtConfirmedSafeBoundary.rawValue
    else {
      throw RuntimeJobEngineError.jobNotRunnable(
        "job \(jobID) is \(runtime.record.state), not runnable")
    }
    guard
      let descriptor = RuntimeOperationCatalog.descriptor(
        reference: runtime.record.operationReference),
      let provider = providers.provider(id: runtime.record.providerID)
    else {
      throw RuntimeJobEngineError.internalFailure("catalog or provider vanished for \(jobID)")
    }
    guard runtime.record.catalogDigest == RuntimeOperationCatalog.catalogDigest else {
      throw RuntimeJobEngineError.jobNotRunnable(
        "job \(jobID) was materialized against a different catalog digest")
    }

    // Acquire before the running transition or any external dispatch. If the
    // host cannot create the assertion the Job stays at its current durable
    // safe boundary and may be retried; it never silently runs sleep-prone.
    // Process-scoped assertions are also released by macOS on a hard crash.
    let powerLease: PowerActivityLease?
    do {
      powerLease = try powerActivityController?.acquire(
        reason: "ArkDeck Runtime Job \(jobID) (\(descriptor.reference))")
    } catch {
      throw RuntimeJobEngineError.jobNotRunnable(
        "idle-system-sleep assertion unavailable; zero dispatch: \(error)")
    }
    defer { powerLease?.end() }

    if runtime.record.startedAtUTC == nil {
      runtime.record.startedAtUTC = nowUTC()
    }
    switch JobState(rawValue: runtime.record.state) {
    case .preflight:
      try transition(&runtime, from: .preflight, to: .running, reason: "steps-start")
    case .resumeAtConfirmedSafeBoundary:
      try transition(
        &runtime, from: .resumeAtConfirmedSafeBoundary, to: .running,
        reason: "resume confirmed durable provider boundary")
    case .running:
      runtime.record.timeline.append("resumed: journal-confirmed provider boundary")
      jobs[jobID] = runtime
    case .recoveringByCompleteOverwrite:
      runtime.record.timeline.append(
        "resumed: journal-confirmed complete-overwrite recovery boundary")
      jobs[jobID] = runtime
    default:
      throw RuntimeJobEngineError.jobNotRunnable(
        "job \(jobID) is \(runtime.record.state), not runnable")
    }

    let isMutation =
      Self.effectiveEffect(
        descriptor: descriptor, inputs: runtime.record.request.inputs) >= .deviceMutation
    let targetID = runtime.record.request.target.targetID
    do {
      try await executeAdmittedSteps(
        jobID: jobID, descriptor: descriptor, provider: provider,
        isMutation: isMutation, targetID: targetID)
    } catch is RuntimeHostDispatchCancellation {
      let current = jobs[jobID] ?? runtime
      cancellationRequests.remove(jobID)
      guard current.record.state == JobState.cancelled.rawValue else {
        throw RuntimeJobEngineError.internalFailure(
          "analyzer cancellation returned without a durable cancelled state")
      }
      jobs[jobID] = current
      try await recordCapabilityOutcome(
        for: current.record, outcome: .confirmed,
        state: JobState.cancelled.rawValue)
      return statusAndReleaseTerminalRuntime(current.record, provider: provider)
    } catch let failure as RuntimeDispatchFailure {
      var current = jobs[jobID] ?? runtime
      let executionState = Self.executionState(of: current.record)
      switch failure {
      case .outcomeUnknown(let reason):
        current.record.operationFailure = RuntimeOperationFailure(
          code: .outcomeUnknown, category: .unknownOutcome,
          retryability: .runtimeDecisionRequired,
          recovery: .awaitRuntimeReconciliation)
        try transition(
          &current, from: executionState, to: .waitingForRecovery,
          reason: "outcomeUnknown: \(reason)")
        current.record.outcomeUnknown = true
        current.record.finishedAtUTC = nowUTC()
        try persistRuntimeRecord(current.record)
        jobs[jobID] = current
        try await recordCapabilityOutcome(
          for: current.record, outcome: .outcomeUnknown,
          state: JobState.waitingForRecovery.rawValue)
        return statusAndReleaseTerminalRuntime(current.record, provider: provider)
      case .confirmedNotExecuted(let reason),
        .confirmedNotExecutedWithDiagnostic(let reason, _):
        current.record.operationFailure = RuntimeOperationFailure(
          code: .executionConfirmedNotPerformed, category: .externalTool,
          retryability: .runtimeDecisionRequired,
          recovery: .submitNewTypedRequestAfterRuntimeProof)
        // The state graph routes every terminal outcome through
        // finalizing: a job always gets its wrap-up phase, success or not.
        try transition(&current, from: executionState, to: .finalizing, reason: reason)
        // `executionState` distinguishes a new recovery epoch from an
        // ordinary workflow; neither branch reuses the predecessor intent.
        try transition(&current, from: .finalizing, to: .failed, reason: reason)
        current.record.finishedAtUTC = nowUTC()
        try persistRuntimeRecord(current.record)
        jobs[jobID] = current
        try await recordCapabilityOutcome(
          for: current.record, outcome: .safeToReflash,
          state: JobState.failed.rawValue)
        return statusAndReleaseTerminalRuntime(current.record, provider: provider)
      case .failed(let reason):
        current.record.operationFailure = RuntimeOperationFailure(
          code: .executionFailed, category: .execution,
          retryability: .runtimeDecisionRequired, recovery: .inspectJob)
        try transition(&current, from: executionState, to: .finalizing, reason: reason)
        try transition(&current, from: .finalizing, to: .failed, reason: reason)
        current.record.finishedAtUTC = nowUTC()
        try persistRuntimeRecord(current.record)
        jobs[jobID] = current
        try await recordCapabilityOutcome(
          for: current.record, outcome: .confirmed,
          state: JobState.failed.rawValue)
        return statusAndReleaseTerminalRuntime(current.record, provider: provider)
      }
    } catch let failure as RuntimeArtifactPublicationFailure {
      var current = jobs[jobID] ?? runtime
      current.record.operationFailure = RuntimeOperationFailure(
        code: .artifactPublicationFailed, category: .storage,
        retryability: .notAutomatic, recovery: .inspectJob)
      try transition(
        &current, from: Self.executionState(of: current.record), to: .finalizing,
        reason: "artifact publication failed: \(failure.detail)")
      try transition(
        &current, from: .finalizing, to: .failed,
        reason: "artifact publication failed: \(failure.detail)")
      current.record.finishedAtUTC = nowUTC()
      try persistRuntimeRecord(current.record)
      jobs[jobID] = current
      try await recordCapabilityOutcome(
        for: current.record, outcome: .confirmed,
        state: JobState.failed.rawValue)
      return statusAndReleaseTerminalRuntime(current.record, provider: provider)
    }

    var current = jobs[jobID] ?? runtime
    var establishedRecoveryEpochID: String?
    let executionState = Self.executionState(of: current.record)
    if cancellationRequests.contains(jobID) {
      cancellationRequests.remove(jobID)
      if current.record.state != JobState.cancelRequested.rawValue {
        try transition(
          &current, from: executionState, to: .cancelRequested, reason: "client-cancel")
      }
      try transition(
        &current, from: .cancelRequested, to: .cancellingAtSafeBoundary,
        reason: "safe-boundary")
      try transition(
        &current, from: .cancellingAtSafeBoundary, to: .cancelled, reason: "steps-drained")
      current.record.operationFailure = RuntimeOperationFailure(
        code: .cancelled, category: .cancelled,
        retryability: .notAutomatic, recovery: .none)
      // Close the capability use here, exactly as the analyzer's own
      // cancellation closes its one. Draining to `cancelled` without recording
      // an outcome leaves the use `pending`, and the target-lineage guard then
      // refuses *every* later destructive job on that binding with "unresolved
      // capability … outcome pending" — measured 2026-08-18, where one
      // cancelled DAYU200 flash left the board unflashable by any new job.
      //
      // `.confirmed` is the honest outcome, for the reason the rollover comment
      // gives: a drained cancellation is one the engine proved did not
      // dispatch, which is a stronger statement than `succeeded` makes.
      try await recordCapabilityOutcome(
        for: current.record, outcome: .confirmed,
        state: JobState.cancelled.rawValue)
    } else {
      try transition(
        &current, from: executionState, to: .finalizing, reason: "steps-complete")
      jobs[jobID] = current
      do {
        try await publishFinalizeArtifacts(jobID: jobID, descriptor: descriptor)
      } catch let failure as RuntimeArtifactPublicationFailure {
        current = jobs[jobID] ?? current
        current.record.operationFailure = RuntimeOperationFailure(
          code: .artifactFinalizationFailed, category: .storage,
          retryability: .notAutomatic, recovery: .inspectJob)
        try transition(
          &current, from: .finalizing, to: .failed,
          reason: "artifact finalization failed: \(failure.detail)")
        current.record.finishedAtUTC = nowUTC()
        try persistRuntimeRecord(current.record)
        jobs[jobID] = current
        try await recordCapabilityOutcome(
          for: current.record, outcome: .confirmed,
          state: JobState.failed.rawValue)
        return statusAndReleaseTerminalRuntime(current.record, provider: provider)
      }
      current = jobs[jobID] ?? current
      current.record.operationFailure = nil
      if current.record.admissionEvidence?.completeOverwriteRecovery != nil {
        let epoch = try await establishSupersedingRecoveryEpoch(
          runtime: &current, descriptor: descriptor)
        establishedRecoveryEpochID = epoch.epochID
        current.record.timeline.append(
          "superseding recovery epoch \(epoch.epochID) established; original outcomes remain unknown"
        )
        try persistRuntimeRecord(current.record)
        jobs[jobID] = current
        try transition(
          &current, from: .finalizing, to: .recovered,
          reason: "complete overwrite, readback, reboot, rebind and postflight confirmed")
      } else {
        try transition(&current, from: .finalizing, to: .succeeded, reason: "finalized")
      }
    }
    current.record.finishedAtUTC = nowUTC()
    try persistRuntimeRecord(current.record)
    jobs[jobID] = current
    updateLatestSucceededDeviceObservationCache(from: current.record)
    try await recordCapabilityOutcome(
      for: current.record, outcome: .confirmed, state: current.record.state)
    return statusAndReleaseTerminalRuntime(
      current.record, recoveryEpochID: establishedRecoveryEpochID, provider: provider)
  }

  /// Runs the admitted step loop with a prewarm task whose lifetime cannot
  /// escape the Job run.
  ///
  /// Cancellation is cooperative, while ArkForge's synchronous import is
  /// bounded by its materialization timeout. Joining the task on every exit
  /// means a host-step failure or an early cancellation cannot leave a hidden
  /// archive upload running after Runtime has made the Job terminal.
  private func executeAdmittedSteps(
    jobID: String, descriptor: CatalogOperationDescriptor,
    provider: any DeviceProvider, isMutation: Bool, targetID: String
  ) async throws {
    // Admission and the running transition are durable before this helper is
    // called. Starting the host-store import here lets it overlap mutation-
    // lane contention and the operation's host-only verification steps, while
    // planOnly never reaches this path. The first delegated write awaits the
    // result before capability consumption.
    let arkForgeArtifactPrewarm = try await beginArkForgeArtifactPrewarmIfNeeded(
      jobID: jobID, descriptor: descriptor)
    do {
      if isMutation {
        try await mutationLane.withMutationLane(deviceID: targetID, requestID: jobID) {
          [weak self] in
          guard let self else { throw RuntimeJobEngineError.internalFailure("engine gone") }
          try await self.executeStepsWithTraceEvidence(
            jobID: jobID, descriptor: descriptor, provider: provider,
            arkForgeArtifactPrewarm: arkForgeArtifactPrewarm)
        }
      } else {
        try await executeStepsWithTraceEvidence(
          jobID: jobID, descriptor: descriptor, provider: provider,
          arkForgeArtifactPrewarm: arkForgeArtifactPrewarm)
      }
    } catch {
      arkForgeArtifactPrewarm?.cancel()
      if let arkForgeArtifactPrewarm {
        _ = try? await arkForgeArtifactPrewarm.value
      }
      await configuration.arkForgeLane?.finishArtifactPrewarm(jobID: jobID)
      throw error
    }
    arkForgeArtifactPrewarm?.cancel()
    if let arkForgeArtifactPrewarm {
      _ = try? await arkForgeArtifactPrewarm.value
    }
    await configuration.arkForgeLane?.finishArtifactPrewarm(jobID: jobID)
  }

  /// Starts the only host-side mutation allowed before a delegated flash: an
  /// idempotent put/inspect in ArkForge's content-addressed archive store.
  ///
  /// This is called only from `run`, after the admitted record and running
  /// transition are durable. `planOnly` and `submit` cannot reach it. The
  /// returned task is joined by the admitted execution scope on every exit
  /// and awaited immediately before the destructive capability is consumed.
  private func beginArkForgeArtifactPrewarmIfNeeded(
    jobID: String, descriptor: CatalogOperationDescriptor
  ) async throws -> ArkForgeArtifactPrewarmTask? {
    guard
      descriptor.steps.contains(where: {
        Self.arkForgeDispatchedSteps.contains($0.stepID)
      }), let lane = configuration.arkForgeLane,
      let profileID = configuration.arkForgeDeviceProfileID,
      !profileID.isEmpty
    else { return nil }

    let resolved: ProviderResolvedInputArtifact
    do {
      guard let artifact = try await resolvedInputArtifact(jobID: jobID) else {
        throw RuntimeDispatchFailure.confirmedNotExecuted(
          "admitted ArkForge flash Job has no resolved input Artifact; nothing was dispatched "
            + "and the device was not touched")
      }
      resolved = artifact
    } catch {
      throw RuntimeDispatchFailure.confirmedNotExecuted(
        "input Artifact lease became unreadable before ArkForge prewarm; nothing was "
          + "dispatched and the device was not touched: \(error)")
    }
    let artifact = ArkForgeLaneArtifact(
      fileURL: resolved.fileURL, sha256: resolved.sha256, profileID: profileID)
    appendTimeline(
      jobID: jobID,
      entry: "ArkForge artifact prewarm started after durable admission")
    return Task {
      try await lane.prewarmArtifact(jobID: jobID, artifact: artifact)
    }
  }

  /// A selected trace leg is bracketed by two Runtime-owned read snapshots.
  /// Both reads run inside the same target mutation lane as the trace itself;
  /// no other ArkDeck mutation can slip between `before`, the capture, and
  /// `after`. The snapshots are durable Job facts, not caller-provided input.
  private func executeStepsWithTraceEvidence(
    jobID: String,
    descriptor: CatalogOperationDescriptor,
    provider: any DeviceProvider,
    arkForgeArtifactPrewarm: ArkForgeArtifactPrewarmTask?
  ) async throws {
    guard descriptor.reference == "capture.diagnostics@1",
      case .array(let requestedTagValues)? = jobs[jobID]?.record.request.inputs["traceCategories"],
      !requestedTagValues.isEmpty
    else {
      try await executeSteps(
        jobID: jobID, descriptor: descriptor, provider: provider,
        arkForgeArtifactPrewarm: arkForgeArtifactPrewarm)
      return
    }
    guard let traceRuntimeProbe else {
      throw RuntimeDispatchFailure.failed(
        "Trace parameter evidence probe is not configured; refusing before capture")
    }
    let requestedTags = requestedTagValues.compactMap { value -> String? in
      guard case .string(let tag) = value else { return nil }
      return tag
    }
    guard requestedTags.count == requestedTagValues.count else {
      throw RuntimeDispatchFailure.failed("Trace tag request lost its typed string shape")
    }
    let targetID = jobs[jobID]?.record.request.target.targetID ?? ""
    let expectedRevision = jobs[jobID]?.record.request.target.expectedBindingRevision
    do {
      let before = try await traceRuntimeProbe.probeTraceRuntime(targetID: targetID)
      try Self.validateTraceRuntimeProbe(
        before, targetID: targetID, bindingRevision: expectedRevision,
        requestedTags: requestedTags)
      guard var runtime = jobs[jobID] else {
        throw RuntimeJobEngineError.jobNotFound(jobID)
      }
      runtime.record.traceProbeBefore = before
      runtime.record.timeline.append("trace parameters snapshotted before capture")
      try persistRuntimeRecord(runtime.record)
      jobs[jobID] = runtime
    } catch let error as RuntimeDispatchFailure {
      throw error
    } catch {
      throw RuntimeDispatchFailure.failed("Trace before snapshot failed: \(error)")
    }

    do {
      try await executeSteps(
        jobID: jobID, descriptor: descriptor, provider: provider,
        arkForgeArtifactPrewarm: arkForgeArtifactPrewarm)
    } catch {
      let executionFailure = error
      do {
        try await captureTraceAfterSnapshot(
          jobID: jobID, probe: traceRuntimeProbe, targetID: targetID,
          expectedRevision: expectedRevision, requestedTags: requestedTags)
      } catch {
        appendTimeline(
          jobID: jobID,
          entry: "Trace after snapshot unavailable after execution failure: \(error)")
      }
      throw executionFailure
    }

    do {
      try await captureTraceAfterSnapshot(
        jobID: jobID, probe: traceRuntimeProbe, targetID: targetID,
        expectedRevision: expectedRevision, requestedTags: requestedTags)
    } catch let error as RuntimeDispatchFailure {
      if cancellationRequests.contains(jobID) {
        appendTimeline(jobID: jobID, entry: "Trace after snapshot unavailable during cancellation")
        return
      }
      throw error
    } catch {
      if cancellationRequests.contains(jobID) {
        appendTimeline(
          jobID: jobID, entry: "Trace after snapshot unavailable during cancellation: \(error)")
        return
      }
      throw RuntimeDispatchFailure.failed("Trace after snapshot failed: \(error)")
    }
  }

  private func captureTraceAfterSnapshot(
    jobID: String,
    probe: any TraceRuntimeProbing,
    targetID: String,
    expectedRevision: Int?,
    requestedTags: [String]
  ) async throws {
    let after = try await probe.probeTraceRuntime(targetID: targetID)
    try Self.validateTraceRuntimeProbe(
      after, targetID: targetID, bindingRevision: expectedRevision,
      requestedTags: requestedTags)
    guard var runtime = jobs[jobID] else {
      throw RuntimeJobEngineError.jobNotFound(jobID)
    }
    runtime.record.traceProbeAfter = after
    runtime.record.timeline.append("trace parameters snapshotted after capture")
    try persistRuntimeRecord(runtime.record)
    jobs[jobID] = runtime
  }

  private static func validateTraceRuntimeProbe(
    _ snapshot: TraceRuntimeProbeSnapshot,
    targetID: String,
    bindingRevision: Int?,
    requestedTags: [String]
  ) throws {
    guard snapshot.targetID == targetID,
      bindingRevision == snapshot.bindingRevision,
      snapshot.adapterDisposition == "captureEligible",
      snapshot.tool == "hitrace",
      snapshot.family != nil,
      !snapshot.supportedTags.isEmpty,
      requestedTags.allSatisfy(snapshot.supportedTags.contains),
      snapshot.parameters.count == TraceDebugParameterCatalog.definitions.count,
      Set(snapshot.parameters.map(\.name))
        == Set(TraceDebugParameterCatalog.definitions.map(\.name))
    else {
      throw RuntimeDispatchFailure.failed(
        "Trace probe facts do not match target, binding, adapter, tags, or parameter catalog")
    }
  }

  private func executeSteps(
    jobID: String,
    descriptor: CatalogOperationDescriptor,
    provider: any DeviceProvider,
    arkForgeArtifactPrewarm: ArkForgeArtifactPrewarmTask?
  ) async throws {
    var completedStepIDs = jobs[jobID]?.completedStepIDs ?? []
    var arkForgePrewarmConfirmed = false
    let flashArtifactLeaseID = Self.flashArtifactLeaseID(
      in: jobs[jobID]?.record.request.inputs)
    for step in descriptor.steps {
      if jobs[jobID].map({ cancellationRequests.contains($0.record.jobID) }) == true {
        return  // safe boundary between steps; run() records the transitions
      }
      if completedStepIDs.contains(step.stepID) {
        appendTimeline(
          jobID: jobID,
          entry: "resume skipped journal-confirmed step \(step.stepID)")
        continue
      }
      // Whoever owns the write owns the transition into Loader. With a lane
      // configured for this operation, that is `arkforged`'s plan, and doing it
      // here as well leaves the lane asking for a transition already spent.
      if Self.arkForgeOwnedModeSteps.contains(step.stepID),
        let lane = configuration.arkForgeLane,
        descriptor.steps.contains(where: {
          Self.arkForgeDispatchedSteps.contains($0.stepID)
        })
      {
        appendTimeline(
          jobID: jobID,
          entry: "delegated \(step.stepID) to the ArkForge lane's own plan")
        if Self.arkForgePlanCompletionSteps.contains(step.stepID) {
          // The first dispatched ArkForge step does not return until the
          // daemon's whole plan is terminal. These later catalog steps are
          // therefore not new dispatches; they are Runtime projections of
          // that one completed plan. Persist each projection as its own WAL
          // intent/outcome so complete-overwrite finalization has exact typed
          // proof instead of a timeline string.
          if step.stepID == "rebind-and-verify-build" {
            // Delegation moves the verification, not the obligation: this
            // step owes the catalog `post-flash-facts.json`. Publish it before
            // closing the step outcome; a crash can then safely revisit this
            // read-only projection, while a confirmed step can never point at
            // a product that was not made durable.
            try await publishLanePostflightFacts(jobID: jobID, step: step, lane: lane)
          }
          try await journalArkForgePlanCompletion(
            jobID: jobID, step: step, descriptor: descriptor, lane: lane)
        }
        completedStepIDs.insert(step.stepID)
        if var runtime = jobs[jobID] {
          runtime.completedStepIDs = completedStepIDs
          jobs[jobID] = runtime
        }
        continue
      }
      switch step.kind {
      case .preflightHostStorage:
        guard let artifactStore, let runtime = jobs[jobID] else {
          throw RuntimeArtifactPublicationFailure(
            detail: "host storage preflight requires the Artifact store")
        }
        let requestedBytes: Int
        if case .integer(let requested)? =
          runtime.record.request.inputs["totalArtifactByteBudget"]
        {
          requestedBytes = Int(requested)
        } else {
          requestedBytes = descriptor.outputByteBudget
        }
        do {
          try await artifactStore.preflightAdditionalBytes(requestedBytes)
        } catch {
          throw RuntimeArtifactPublicationFailure(
            detail: "host storage preflight refused collection: \(error)")
        }
        appendTimeline(jobID: jobID, entry: "host-step \(step.stepID)")
        continue
      case .verifyArtifact, .hashFile:
        try await verifyHostInputArtifact(
          jobID: jobID, descriptor: descriptor, step: step)
        appendTimeline(jobID: jobID, entry: "host-step \(step.stepID)")
        continue
      case .requestConfirmation:
        // The published `requestConfirmation` identifier is retained on the wire. Its active
        // behavior is an in-plan witness that the protected Runtime generated an exact
        // destructive capability. UI
        // acknowledgement is UX only; no human/campaign authority is read.
        guard let record = jobs[jobID]?.record else {
          throw RuntimeDispatchFailure.failed("confirm step lost its job record")
        }
        let confirmEffect = Self.effectiveEffect(
          descriptor: descriptor, inputs: record.request.inputs)
        if confirmEffect == .destructive {
          guard let reference = record.request.authorization,
            let capabilityStatus = try await capabilityStore.inspect(
              capabilityID: reference.capabilityID),
            capabilityStatus.capability.issuer.kind == .runtimeDefaultPolicy,
            capabilityStatus.capability.effectCeiling == WorkflowEffect.destructive,
            capabilityStatus.capability.exactPlanDigest == record.materializedPlanDigest
          else {
            throw RuntimeDispatchFailure.failed(
              "destructive intent step has no matching Runtime-owned capability")
          }
          appendTimeline(
            jobID: jobID,
            entry: "destructive intent bound to Runtime capability \(reference.capabilityID)")
        } else {
          appendTimeline(jobID: jobID, entry: "host-step \(step.stepID)")
        }
        continue
      case .postprocessArtifact, .finalizeSession:
        // Remaining engine-internal host steps do not dispatch a provider.
        appendTimeline(jobID: jobID, entry: "host-step \(step.stepID)")
        continue
      default:
        break
      }
      // Optional steps are the partial-success surface: when one cannot
      // run or fails, the job continues and the products it owned are
      // recorded as missing with a reason. A required step failing still
      // fails the job.
      // `isOptionalStepSelected` also answers for the mandatory steps a typed
      // input can switch off (today: `stop-ability`). Keeping the optionality
      // check out of this condition is the point: such a step is never
      // *tolerated* when it fails, it is only sometimes not asked for.
      if !isOptionalStepSelected(step, jobID: jobID, descriptor: descriptor) {
        // Name the real cause: "its upstream failed" and "you did not ask
        // for it" are different facts, and evidence must not blur them.
        let reason: String
        if let upstream = Self.optionalStepUpstream[descriptor.reference]?[step.stepID],
          let upstreamReason = jobs[jobID]?.record.skipReasons[upstream]
        {
          reason = "upstream \(upstream) did not run: \(upstreamReason)"
        } else {
          reason = "step not selected by the request inputs"
        }
        try await recordSkippedOptionalStep(
          jobID: jobID, step: step, descriptor: descriptor, reason: reason)
        continue
      }
      // A session-scoped gesture asks the device who it is every time, but it
      // does not re-ask what model and firmware it runs: those cost a device
      // round trip each and cannot have changed under an identity that just
      // re-confirmed. This is the difference between a gesture that answers
      // in a moment and one that does not, and the identity check above is
      // what keeps it honest.
      if ingestCarriedEvidenceFragment(jobID: jobID, step: step, descriptor: descriptor) {
        continue
      }
      let resolvedArtifact: ProviderResolvedInputArtifact?
      let additionalArtifacts: [ProviderResolvedInputArtifact]
      do {
        resolvedArtifact =
          step.kind == .sendFile
            // `debug.hap@1` proves the installed package by a later
            // package-readback step.  That step must receive the same
            // engine-resolved immutable Artifact facts as the send/install
            // legs; otherwise the provider can prove only that a bundle name
            // exists and no caller can bind deployment to the build
            // digest it just verified.
            || (descriptor.reference == "debug.hap@1"
              && (step.kind == .installPackage
                || step.kind == .runApprovedRemoteRead))
            || step.kind == .flashPartition
            || step.kind == .applyWorkspacePatch
            || step.kind == .signWorkspaceOpenHarmonyHap
            || step.kind == .symbolizeWorkspaceCrash
            || step.kind == .runDeterministicAnalyzer
            || ArkForgeFlashOperation.contains(descriptor.reference)
            || descriptor.reference == "deploy.native-library.app-owned@1"
          ? try await resolvedInputArtifact(jobID: jobID) : nil
        additionalArtifacts =
          step.kind == .sendFile ? try await resolvedAdditionalInputArtifacts(jobID: jobID) : []
      } catch let rejection as RuntimeJobEngineError {
        throw RuntimeDispatchFailure.failed("\(rejection)")
      } catch {
        throw RuntimeDispatchFailure.failed(
          "input Artifact lease became unreadable before \(step.stepID): \(error)")
      }
      let targetID = jobs[jobID]?.record.request.target.targetID ?? ""
      let expectedBinding = jobs[jobID]?.record.request.target.expectedBindingRevision
      var resolvedFacts: ProviderFacts?
      if step.binding == .confirmedDevice {
        do {
          resolvedFacts = try await providers.resolveFacts(
            providerID: descriptor.provider.rawValue, targetID: targetID)
        } catch {
          if Self.requiresEvidencePreflight(descriptor),
            Self.isEvidencePreflightStep(step)
          {
            throw RuntimeDispatchFailure.failed(
              "evidenceIncomplete: descriptor-bound target facts unavailable: \(error)")
          }
          appendTimeline(jobID: jobID, entry: "target facts unavailable: \(error)")
        }
      }
      if step.effect >= .deviceMutation, let resolvedFacts,
        let blocker = provider.executionAdmissionBlocker(
          for: descriptor, facts: resolvedFacts)
      {
        throw RuntimeDispatchFailure.failed(
          "provider execution prerequisite blocked before external effect: \(blocker)")
      }
      if Self.requiresEvidencePreflight(descriptor), Self.isEvidencePreflightStep(step) {
        try Self.validateEvidenceFacts(
          resolvedFacts, targetID: targetID, bindingRevision: expectedBinding,
          providerID: descriptor.provider.rawValue)
      } else if Self.requiresEvidencePreflight(descriptor),
        step.binding == .confirmedDevice
      {
        try requireCompleteEvidencePreflight(jobID: jobID, beforeStepID: step.stepID)
      }
      if descriptor.reference == "deploy.native-library.app-owned@1",
        step.binding == .confirmedDevice
      {
        try Self.validateMaterializedTargetFacts(
          resolvedFacts, record: jobs[jobID]?.record,
          providerID: descriptor.provider.rawValue)
      }
      let context = ProviderExecutionContext(
        jobID: jobID, stepID: step.stepID,
        targetID: targetID,
        bindingRevision: expectedBinding,
        connectKey: resolvedFacts?.executionConnectKey,
        expectedIdentitySHA256: resolvedFacts?.deviceIdentitySHA256,
        toolVersion: resolvedFacts?.toolVersion,
        toolSHA256: resolvedFacts?.toolSHA256,
        serverFacts: resolvedFacts?.serverFacts ?? [:],
        nowUTC: nowUTC(),
        resolvedInputArtifact: resolvedArtifact,
        additionalInputArtifacts: additionalArtifacts,
        expectedRuntimeBuildVersion: declaredRuntimeBuildVersion(
          for: descriptor, artifact: resolvedArtifact,
          artifactLeaseID: flashArtifactLeaseID))
      // A delegated step never reaches the provider: arkforged performs it
      // under a StepPermit this authority signs, and asking ArkDeck for an
      // action it deliberately no longer has would only produce the removal's
      // error message in a place that cannot act on it.
      if Self.arkForgeDispatchedSteps.contains(step.stepID) {
        if !arkForgePrewarmConfirmed, let arkForgeArtifactPrewarm {
          let prewarm: ArkForgeLaneArtifactPrewarmReceipt
          let consumeWaitStarted = DispatchTime.now().uptimeNanoseconds
          do {
            prewarm = try await arkForgeArtifactPrewarm.value
          } catch {
            throw RuntimeDispatchFailure.confirmedNotExecuted(
              "arkforged artifact prewarm failed before capability consumption; nothing was "
                + "dispatched and the device was not touched: \(error)")
          }
          guard let profileID = configuration.arkForgeDeviceProfileID,
            let currentArtifact = resolvedArtifact,
            prewarm.artifactSHA256 == currentArtifact.sha256,
            prewarm.profileID == profileID
          else {
            throw RuntimeDispatchFailure.confirmedNotExecuted(
              "arkforged artifact prewarm identity drifted before capability consumption; "
                + "nothing was dispatched and the device was not touched")
          }
          let consumeWaitMilliseconds =
            (DispatchTime.now().uptimeNanoseconds &- consumeWaitStarted) / 1_000_000
          appendTimeline(
            jobID: jobID,
            entry:
              "ArkForge artifact prewarm ready (\(prewarm.imported ? "imported" : "store-hit"), "
              + "total \(prewarm.durationMilliseconds) ms, consume wait "
              + "\(consumeWaitMilliseconds) ms)")
          arkForgePrewarmConfirmed = true
        }
        // The daemon executes both delegated catalog steps as one plan. Once
        // its canonical terminal receipt is durable, every later obligation
        // is a projection of that proof — including after the lane actor was
        // recreated. Calling `performPrepared` here would ask a fresh actor to
        // drive an already-terminal job and used to start/lose a second path.
        if step.stepID != "flash-partitions",
          jobs[jobID]?.arkForgeState.planCompletionReceipt != nil,
          let lane = configuration.arkForgeLane
        {
          try await journalArkForgePlanCompletion(
            jobID: jobID, step: step, descriptor: descriptor, lane: lane)
          completedStepIDs.insert(step.stepID)
          if var runtime = jobs[jobID] {
            runtime.completedStepIDs = completedStepIDs
            jobs[jobID] = runtime
          }
          continue
        }
        if step.effect >= .deviceMutation {
          // The capability is consumed before the write, exactly as on the
          // local path. Delegating the mechanics does not delegate admission.
          try await consumeCapabilityBeforeMutation(
            jobID: jobID, descriptor: descriptor,
            effect: Self.effectiveEffect(
              descriptor: descriptor,
              inputs: jobs[jobID]?.record.request.inputs ?? [:]),
            validatedFacts: resolvedFacts)
        }
        try await dispatchThroughArkForge(
          jobID: jobID, step: step, descriptor: descriptor, context: context)
        completedStepIDs.insert(step.stepID)
        if var runtime = jobs[jobID] {
          runtime.completedStepIDs = completedStepIDs
          jobs[jobID] = runtime
        }
        continue
      }
      let action: TypedProviderAction
      do {
        let operation =
          ArkForgeFlashOperation.canonicalDescriptor(for: descriptor.reference) ?? descriptor
        let inputs = try ArkForgeFlashRequest.canonicalInputs(
          submittedReference: descriptor.reference,
          inputs: jobs[jobID]?.record.request.inputs ?? [:])
        action = try provider.action(
          for: step, operation: operation, inputs: inputs,
          context: context)
      } catch  where step.isOptional {
        try await recordSkippedOptionalStep(
          jobID: jobID, step: step, descriptor: descriptor,
          reason: "provider has no action for this step")
        continue
      }
      let plan: TypedProcessPlan
      do {
        plan = try provider.lower(action: action, context: context)
      } catch {
        if Self.requiresEvidencePreflight(descriptor),
          Self.isEvidencePreflightStep(step)
        {
          throw RuntimeDispatchFailure.failed(
            "evidenceIncomplete: typed preflight could not be lowered: \(error)")
        }
        throw error
      }
      do {
        if step.effect >= .deviceMutation {
          try await consumeCapabilityBeforeMutation(
            jobID: jobID, descriptor: descriptor,
            effect: Self.effectiveEffect(
              descriptor: descriptor,
              inputs: jobs[jobID]?.record.request.inputs ?? [:]),
            validatedFacts: resolvedFacts)
        }
        try await dispatchWithWAL(
          jobID: jobID, step: step, action: action, plan: plan, provider: provider,
          context: context, descriptor: descriptor, evidenceFacts: resolvedFacts)
        completedStepIDs.insert(step.stepID)
        if var runtime = jobs[jobID] {
          runtime.completedStepIDs = completedStepIDs
          jobs[jobID] = runtime
        }
      } catch let failure as RuntimeDispatchFailure {
        // An unknown outcome always halts, optional or not: we cannot
        // continue past an effect whose result we do not know.
        if case .outcomeUnknown = failure { throw failure }
        if step.isOptional {
          try await recordSkippedOptionalStep(
            jobID: jobID, step: step, descriptor: descriptor, reason: "\(failure)")
          // The gate is what the step was trying to remove, not whether
          // that happened to be a remote path: an optional cleanup that ran
          // and failed owes a record either way.
          if let artifactStore, let residue = Self.cleanupResidue(for: action) {
            try? await artifactStore.recordCleanupDebt(
              jobID: jobID, stepID: step.stepID, residue: residue,
              reason: "\(failure)", action: action)
            await refreshResidueCount(jobID: jobID)
          }
          continue
        }
        if descriptor.reference == "debug.hap@1",
          Self.debugHAPNeedsCompensation(completedStepIDs: completedStepIDs)
        {
          try await compensateDebugHAP(
            jobID: jobID, descriptor: descriptor, provider: provider,
            completedStepIDs: completedStepIDs, failedStepID: step.stepID)
        }
        if descriptor.reference == "deploy.native-library.app-owned@1",
          let deployment = Self.nativeDeployment(from: action)
        {
          try await compensateNativeLibrary(
            jobID: jobID, descriptor: descriptor, provider: provider,
            deployment: deployment, completedStepIDs: completedStepIDs,
            failedStepID: step.stepID, originalFailure: failure)
        }
        if let mutationStepID = Self.portForwardMutationStepID(
          for: descriptor.reference),
          completedStepIDs.contains(mutationStepID),
          let spec = Self.portForwardSpec(from: action)
            ?? Self.portForwardSpec(
              from: jobs[jobID]?.record.request.inputs ?? [:])
        {
          try await compensatePortForward(
            jobID: jobID, originalDescriptor: descriptor,
            provider: provider, spec: spec)
        }
        throw failure
      }
    }
  }

  /// Restores the exact port-rule state after a confirmed failure that occurs
  /// after the mutation. The inverse operation is closed over the original
  /// typed pair; neither caller input nor a shell fragment is introduced on
  /// the compensation path. A second readback is mandatory so a successful
  /// process exit can never be mistaken for restored state.
  private func compensatePortForward(
    jobID: String,
    originalDescriptor: CatalogOperationDescriptor,
    provider: any DeviceProvider,
    spec: HDCPortForwardSpec
  ) async throws {
    guard let runtime = jobs[jobID] else {
      throw RuntimeJobEngineError.jobNotFound(jobID)
    }
    let compensatingReference: String
    let mutationKind: WorkflowStepKind
    let mutationAction: TypedProviderAction
    switch originalDescriptor.reference {
    case "port-forward.create@1":
      compensatingReference = "port-forward.remove@1"
      mutationKind = .removePortForward
      mutationAction = .hdc(.removePortForward(spec))
    case "port-forward.remove@1":
      compensatingReference = "port-forward.create@1"
      mutationKind = .createPortForward
      mutationAction = .hdc(.createPortForward(spec))
    default:
      return
    }
    guard
      let compensatingDescriptor = RuntimeOperationCatalog.descriptor(
        reference: compensatingReference)
    else {
      throw RuntimeJobEngineError.internalFailure(
        "missing published compensation operation \(compensatingReference)")
    }
    let facts = try await providers.resolveFacts(
      providerID: originalDescriptor.provider.rawValue,
      targetID: runtime.record.request.target.targetID)
    try Self.validateMaterializedTargetFacts(
      facts, record: runtime.record,
      providerID: originalDescriptor.provider.rawValue)

    let mutationStep = CatalogStepDescriptor(
      stepID: "compensate-port-rule",
      kind: mutationKind,
      effect: .deviceMutation,
      cancellation: .atSafeBoundary,
      binding: .confirmedDevice,
      isOptional: false,
      compensation: .none)
    let mutationContext = ProviderExecutionContext(
      jobID: jobID, stepID: mutationStep.stepID,
      targetID: runtime.record.request.target.targetID,
      bindingRevision: runtime.record.request.target.expectedBindingRevision,
      connectKey: facts.executionConnectKey,
      expectedIdentitySHA256: facts.deviceIdentitySHA256,
      toolVersion: facts.toolVersion,
      toolSHA256: facts.toolSHA256,
      serverFacts: facts.serverFacts,
      nowUTC: nowUTC())
    let mutationPlan = try provider.lower(
      action: mutationAction, context: mutationContext)
    do {
      try await dispatchWithWAL(
        jobID: jobID, step: mutationStep, action: mutationAction,
        plan: mutationPlan, provider: provider, context: mutationContext,
        descriptor: compensatingDescriptor, evidenceFacts: facts)

      let verifyStep = CatalogStepDescriptor(
        stepID: "verify-port-rule-compensation",
        kind: .verifyRemoteState,
        effect: .readOnly,
        cancellation: .immediate,
        binding: .confirmedDevice,
        isOptional: false,
        compensation: .none)
      let verifyContext = ProviderExecutionContext(
        jobID: jobID, stepID: verifyStep.stepID,
        targetID: runtime.record.request.target.targetID,
        bindingRevision: runtime.record.request.target.expectedBindingRevision,
        connectKey: facts.executionConnectKey,
        expectedIdentitySHA256: facts.deviceIdentitySHA256,
        toolVersion: facts.toolVersion,
        toolSHA256: facts.toolSHA256,
        serverFacts: facts.serverFacts,
        nowUTC: nowUTC())
      let verifyAction = TypedProviderAction.hdc(.readPortForwardPresence(spec))
      let verifyPlan = try provider.lower(
        action: verifyAction, context: verifyContext)
      try await dispatchWithWAL(
        jobID: jobID, step: verifyStep, action: verifyAction,
        plan: verifyPlan, provider: provider, context: verifyContext,
        descriptor: compensatingDescriptor, evidenceFacts: facts)
      appendTimeline(
        jobID: jobID,
        entry: "compensated port rule to \(compensatingReference)")
    } catch let compensationFailure as RuntimeDispatchFailure {
      appendTimeline(
        jobID: jobID,
        entry: "port-rule compensation failed closed: \(compensationFailure)")
      throw compensationFailure
    }
  }

  private static func portForwardMutationStepID(
    for operationReference: String
  ) -> String? {
    switch operationReference {
    case "port-forward.create@1": return "create-port-rule"
    case "port-forward.remove@1": return "remove-port-rule"
    default: return nil
    }
  }

  private static func portForwardSpec(
    from action: TypedProviderAction
  ) -> HDCPortForwardSpec? {
    switch action {
    case .hdc(.createPortForward(let spec)),
      .hdc(.removePortForward(let spec)),
      .hdc(.readPortForwardPresence(let spec)):
      return spec
    default:
      return nil
    }
  }

  /// A later host-only failure no longer carries the mutation action, so the
  /// compensation path must be able to recover the same closed rule from the
  /// immutable request. This accepts only the Catalog-shaped fields and the
  /// same bounded port vocabulary as provider lowering.
  private static func portForwardSpec(
    from inputs: [String: JSONValue]
  ) -> HDCPortForwardSpec? {
    guard case .string(let directionValue)? = inputs["direction"],
      let direction = HDCPortForwardDirection(rawValue: directionValue),
      case .integer(let localPort)? = inputs["localPort"],
      case .integer(let remotePort)? = inputs["remotePort"],
      localPort >= 1_024, localPort <= 65_535,
      remotePort >= 1_024, remotePort <= 65_535
    else { return nil }
    return try? HDCPortForwardSpec(
      direction: direction,
      localPort: Int(localPort), remotePort: Int(remotePort))
  }

  private func compensateNativeLibrary(
    jobID: String,
    descriptor: CatalogOperationDescriptor,
    provider: any DeviceProvider,
    deployment: HDCAppOwnedNativeLibraryDeployment,
    completedStepIDs: Set<String>,
    failedStepID: String,
    originalFailure: RuntimeDispatchFailure
  ) async throws {
    guard let runtime = jobs[jobID] else {
      throw RuntimeJobEngineError.jobNotFound(jobID)
    }
    let facts = try await providers.resolveFacts(
      providerID: descriptor.provider.rawValue,
      targetID: runtime.record.request.target.targetID)
    try Self.validateMaterializedTargetFacts(
      facts, record: runtime.record, providerID: descriptor.provider.rawValue)
    let publishIndex =
      descriptor.steps.firstIndex(where: { $0.stepID == "atomic-publish" })
    let failedIndex =
      descriptor.steps.firstIndex(where: { $0.stepID == failedStepID })
    let publishWasAttempted =
      completedStepIDs.contains("atomic-publish")
      || (publishIndex != nil && failedIndex != nil && failedIndex! >= publishIndex!)

    if publishWasAttempted {
      let step = CatalogStepDescriptor(
        stepID: "rollback-native-library",
        kind: .runApprovedRemoteMutation,
        effect: .deviceMutation,
        cancellation: .atSafeBoundary,
        binding: .confirmedDevice,
        isOptional: false,
        compensation: .none)
      let context = ProviderExecutionContext(
        jobID: jobID, stepID: step.stepID,
        targetID: runtime.record.request.target.targetID,
        bindingRevision: runtime.record.request.target.expectedBindingRevision,
        connectKey: facts.executionConnectKey,
        expectedIdentitySHA256: facts.deviceIdentitySHA256,
        toolVersion: facts.toolVersion,
        toolSHA256: facts.toolSHA256,
        serverFacts: facts.serverFacts,
        nowUTC: nowUTC())
      let action = TypedProviderAction.hdc(.rollbackNativeLibrary(deployment))
      let plan = try provider.lower(action: action, context: context)
      do {
        try await dispatchWithWAL(
          jobID: jobID, step: step, action: action, plan: plan,
          provider: provider, context: context, descriptor: descriptor,
          evidenceFacts: facts)
        appendTimeline(
          jobID: jobID,
          entry: "native deployment failure restored previous library")
      } catch let failure as RuntimeDispatchFailure {
        appendTimeline(
          jobID: jobID, entry: "native rollback failed closed: \(failure)")
        throw failure
      }
    }

    let cleanupStep = CatalogStepDescriptor(
      stepID: "cleanup-native-library-compensation",
      kind: .cleanupOwnedRemotePath,
      effect: .deviceMutation,
      cancellation: .atSafeBoundary,
      binding: .confirmedDevice,
      isOptional: true,
      compensation: .bestEffortCleanup)
    let cleanupContext = ProviderExecutionContext(
      jobID: jobID, stepID: cleanupStep.stepID,
      targetID: runtime.record.request.target.targetID,
      bindingRevision: runtime.record.request.target.expectedBindingRevision,
      connectKey: facts.executionConnectKey,
      expectedIdentitySHA256: facts.deviceIdentitySHA256,
      toolVersion: facts.toolVersion,
      toolSHA256: facts.toolSHA256,
      serverFacts: facts.serverFacts,
      nowUTC: nowUTC())
    let cleanupAction = TypedProviderAction.hdc(.cleanupNativeLibrary(deployment))
    let cleanupPlan = try provider.lower(action: cleanupAction, context: cleanupContext)
    do {
      try await dispatchWithWAL(
        jobID: jobID, step: cleanupStep, action: cleanupAction,
        plan: cleanupPlan, provider: provider, context: cleanupContext,
        descriptor: descriptor, evidenceFacts: facts)
      appendTimeline(jobID: jobID, entry: "native compensation cleanup complete")
    } catch let cleanupFailure as RuntimeDispatchFailure {
      if let artifactStore {
        try? await artifactStore.recordCleanupDebt(
          jobID: jobID, stepID: cleanupStep.stepID,
          residue: .remotePath(deployment.stagingPath),
          reason: "\(cleanupFailure)", action: cleanupAction)
        await refreshResidueCount(jobID: jobID)
      }
      appendTimeline(
        jobID: jobID, entry: "native compensation cleanup debt: \(cleanupFailure)")
      if case .outcomeUnknown = cleanupFailure {
        throw cleanupFailure
      }
    }
    if case .failed(let reason) = originalFailure {
      appendTimeline(jobID: jobID, entry: "native deployment failed: \(reason)")
    }
  }

  private static func nativeDeployment(
    from action: TypedProviderAction
  ) -> HDCAppOwnedNativeLibraryDeployment? {
    switch action {
    case .hdc(.sendNativeLibraryToStaging(let deployment)),
      .hdc(.backupNativeLibrary(let deployment)),
      .hdc(.publishNativeLibrary(let deployment)),
      .hdc(.stopNativeTarget(let deployment)),
      .hdc(.startNativeTarget(let deployment)),
      .hdc(.cleanupNativeLibrary(let deployment)),
      .hdc(.rollbackNativeLibrary(let deployment)),
      .hdc(.inspectNativeLibrary(let deployment, _)):
      return deployment
    default:
      return nil
    }
  }

  /// Recomputes this job's outstanding residue from the ledger, which is
  /// the authority. Deliberately not incremented in place: the count must
  /// agree with what `cleanup-debt list` shows, not with the engine's idea
  /// of how many times it recorded something.
  private func refreshResidueCount(jobID: String) async {
    guard let artifactStore, var runtime = jobs[jobID] else { return }
    let outstanding = (try? await artifactStore.outstandingCleanupDebt()) ?? []
    runtime.record.outstandingResidueCount =
      outstanding.filter { $0.jobID == jobID }.count
    jobs[jobID] = runtime
    try? persistRuntimeRecord(runtime.record)
  }

  /// What this action was supposed to remove, when it is a cleanup-class
  /// action. `nil` means the action leaves nothing to owe.
  ///
  /// `uninstallPackage` joined the list in r3: an uninstall that ran and
  /// did not take effect leaves an installed bundle behind, which is the
  /// same class of fact as an un-removed remote path. Keying the ledger by
  /// path was the whole of D12 — a bundle simply had nowhere to be
  /// recorded, so a job could report success with a device it had dirtied.
  private static func cleanupResidue(
    for action: TypedProviderAction
  ) -> CleanupResidue? {
    switch action {
    case .hdc(.cleanupOwnedRemotePath(let path)):
      return .remotePath(path.remotePath)
    case .hdc(.cleanupNativeLibrary(let deployment)):
      return .remotePath(deployment.stagingPath)
    case .hdc(.uninstallPackage(let bundle)):
      return .installedBundle(bundle.bundleName)
    default:
      return nil
    }
  }

  private func compensateDebugHAP(
    jobID: String,
    descriptor: CatalogOperationDescriptor,
    provider: any DeviceProvider,
    completedStepIDs: Set<String>,
    failedStepID: String
  ) async throws {
    guard let runtime = jobs[jobID] else {
      throw RuntimeJobEngineError.jobNotFound(jobID)
    }
    var compensationStepIDs: [String] = []
    if completedStepIDs.contains("start-ability") {
      compensationStepIDs.append("stop-ability")
    }
    // Which cleanup this job asked for, read the same way admission read it:
    // the input if it gave one, otherwise the catalog's declared default.
    // Restating "uninstall" here made compensation depend on a value the
    // catalog also declares, with nothing comparing the two.
    let cleanupPolicy =
      CatalogOperationEffectResolver.resolvedInputValue(
        "cleanupPolicy", descriptor: descriptor, inputs: runtime.record.request.inputs)
    if cleanupPolicy == .string("uninstall"), completedStepIDs.contains("install-hap") {
      compensationStepIDs.append("cleanup-uninstall")
    }
    if completedStepIDs.contains("send-hap") {
      compensationStepIDs.append("cleanup-remote-staging")
    }

    for stepID in compensationStepIDs where stepID != failedStepID {
      guard let step = descriptor.steps.first(where: { $0.stepID == stepID }) else {
        throw RuntimeJobEngineError.internalFailure(
          "debug.hap compensation step \(stepID) is absent from the catalog")
      }
      let facts = try await providers.resolveFacts(
        providerID: descriptor.provider.rawValue,
        targetID: runtime.record.request.target.targetID)
      try Self.validateEvidenceFacts(
        facts,
        targetID: runtime.record.request.target.targetID,
        bindingRevision: runtime.record.request.target.expectedBindingRevision,
        providerID: descriptor.provider.rawValue)
      let context = ProviderExecutionContext(
        jobID: jobID, stepID: step.stepID,
        targetID: runtime.record.request.target.targetID,
        bindingRevision: runtime.record.request.target.expectedBindingRevision,
        connectKey: facts.executionConnectKey,
        expectedIdentitySHA256: facts.deviceIdentitySHA256,
        toolVersion: facts.toolVersion,
        toolSHA256: facts.toolSHA256,
        serverFacts: facts.serverFacts,
        nowUTC: nowUTC())
      let action = try provider.action(
        for: step, operation: descriptor, inputs: runtime.record.request.inputs,
        context: context)
      let plan = try provider.lower(action: action, context: context)
      do {
        try await dispatchWithWAL(
          jobID: jobID, step: step, action: action, plan: plan,
          provider: provider, context: context, descriptor: descriptor,
          evidenceFacts: facts)
        appendTimeline(jobID: jobID, entry: "compensated \(step.stepID)")
      } catch let failure as RuntimeDispatchFailure {
        if case .outcomeUnknown = failure { throw failure }
        appendTimeline(
          jobID: jobID,
          entry: "compensation failed \(step.stepID): \(failure)")
        // Same gate on the compensation path, which matters more: it runs
        // precisely when something else already went wrong, and before r3
        // a failed uninstall here left no record at all.
        if let artifactStore, let residue = Self.cleanupResidue(for: action) {
          try? await artifactStore.recordCleanupDebt(
            jobID: jobID, stepID: step.stepID, residue: residue,
            reason: "\(failure)", action: action)
          await refreshResidueCount(jobID: jobID)
        }
      }
    }
    if Self.requiresEvidencePreflight(descriptor) {
      try requireCompleteEvidencePreflight(
        jobID: jobID, beforeStepID: "finish-operation")
    }
  }

  private static func debugHAPNeedsCompensation(
    completedStepIDs: Set<String>
  ) -> Bool {
    !completedStepIDs.isDisjoint(with: [
      "send-hap", "install-hap", "start-ability",
    ])
  }

  /// The effect this request will actually reach: the maximum effect over
  /// the steps its inputs select. Optional steps that will not run do not
  /// raise the bar, and steps that will run cannot duck under it.
  static func effectiveEffect(
    descriptor: CatalogOperationDescriptor, inputs: [String: JSONValue]
  ) -> WorkflowEffect {
    CatalogOperationEffectResolver.effectiveEffect(descriptor: descriptor, inputs: inputs)
  }

  /// Whether the request asks for this step at all.
  ///
  /// Two rules, deliberately separate. A step declared `optional` is one whose
  /// *failure* the run tolerates - the engine records it as skipped and carries
  /// on. A step switched off by a typed input is not the same thing: it never
  /// runs, but if it does run and fails, the job fails.
  ///
  /// `stop-ability` is the case that forced the distinction. GJ-5 needs the
  /// application under debug to still be alive while something else observes
  /// it, and no request could leave it that way, because this step ran
  /// unconditionally (measured on the 2026-07-31 window: the debug loop then
  /// measured "liveness" on a device whose application was not running).
  /// Declaring it `optional` did switch it off - and also made a stop that
  /// reported `stopIneffective` a tolerable skip, so a job that left a process
  /// running reported success. The contract test for that caught it. So the
  /// step stays mandatory and the input decides only whether it is requested.
  ///
  /// Success path only: `compensateDebugHAP` still stops an ability it started
  /// when the job then failed. A request may keep an application running when
  /// the run worked, never as the residue of a failure.
  static func stepIsRequested(
    _ step: CatalogStepDescriptor,
    descriptor: CatalogOperationDescriptor,
    inputs: [String: JSONValue]
  ) -> Bool {
    CatalogOperationEffectResolver.stepIsSelected(
      step, descriptor: descriptor, inputs: inputs)
  }

  /// Pure selection rule, shared by authorization (before a job exists)
  /// and execution (after it does), so the two can never disagree about
  /// which steps count.
  static func optionalStepIsSelected(
    _ step: CatalogStepDescriptor,
    descriptor: CatalogOperationDescriptor,
    inputs: [String: JSONValue]
  ) -> Bool {
    CatalogOperationEffectResolver.optionalStepIsSelected(
      step, descriptor: descriptor, inputs: inputs)
  }

  /// Steps whose success is decided by a paired readback rather than by
  /// their own result. The readback step is required, so nothing here can
  /// let an unverified mutation pass as success - it only moves the
  /// judgement to the step that can actually make it.
  static func awaitsReadback(
    step: CatalogStepDescriptor, descriptor: CatalogOperationDescriptor
  ) -> Bool {
    guard let readbackStepID = readbackPairs[descriptor.reference]?[step.stepID] else {
      return false
    }
    return descriptor.steps.contains { $0.stepID == readbackStepID && !$0.isOptional }
  }

  static let readbackPairs: [String: [String: String]] = [
    "debug.hap@1": [
      "install-hap": "package-readback",
      "start-ability": "process-readback",
    ],
    "deploy.native-library.app-owned@1": [
      "send-to-staging": "verify-remote-staging"
    ],
    "port-forward.create@1": [
      "create-port-rule": "verify-port-rule"
    ],
    "port-forward.remove@1": [
      "remove-port-rule": "verify-port-rule"
    ],
  ]

  static let evidenceEligibleOperations: Set<String> = [
    "observe.device@1", "capture.diagnostics@1", "debug.hap@1",
    "port-forward.create@1", "port-forward.remove@1",
    "input.tap@1", "input.long-press@1", "input.swipe@1",
  ]

  static func requiresEvidencePreflight(_ descriptor: CatalogOperationDescriptor) -> Bool {
    evidenceEligibleOperations.contains(descriptor.reference)
  }

  static func isEvidencePreflightStep(_ step: CatalogStepDescriptor) -> Bool {
    switch step.stepID {
    case "confirm-evidence-target":
      return step.kind == .probeDevice
    case "read-evidence-model":
      return step.kind == .runApprovedRemoteRead
        && step.actionReference?.catalogID == "arkdeck-remote-operations"
        && step.actionReference?.actionID == "deviceModel"
    case "read-evidence-firmware":
      return step.kind == .runApprovedRemoteRead
        && step.actionReference?.catalogID == "arkdeck-remote-operations"
        && step.actionReference?.actionID == "firmwareBuild"
    default:
      return false
    }
  }

  /// An unbound operation must be host-only all the way down unless it is one
  /// of the two reviewed workspace mutation authorities below. A device step
  /// or an unrelated effect above `hostOnly` would reach the device through a
  /// path that skipped facts, binding and identity - so it is refused here,
  /// before anything is materialized, in addition to the generator's static
  /// check.
  static func validateHostOnlyDescriptor(_ descriptor: CatalogOperationDescriptor) throws {
    // Source-changing workspace mutations remain reachable only with a
    // workspace-scoped standing capability (TASK-HFA-009 r2). The sole
    // Runtime-owned exception is the source-preserving checkpoint operation:
    // its one step writes a provider-owned rollback object/archive, never a
    // ref, index, worktree or declared source byte (TASK-HFA-009 r4).
    let standingWorkspaceMutation =
      descriptor.provider == .workspace
      && descriptor.permittedEffects.allSatisfy({ $0 <= .deviceMutation })
      && descriptor.authorization[.deviceMutation] == .standingCapability
    let runtimeCheckpoint =
      descriptor.reference == "workspace.create-checkpoint@1"
      && descriptor.provider == .workspace
      && descriptor.minimumEffect == .deviceMutation
      && descriptor.permittedEffects == [.deviceMutation]
      && descriptor.authorization[.deviceMutation] == .runtimeCapability
      && descriptor.defaultPolicyIssuanceEnabled
      && descriptor.concurrencyKey == .hostExclusive
      && descriptor.steps.count == 1
      && descriptor.steps[0].kind == .createWorkspaceCheckpoint
      && descriptor.steps[0].effect == .deviceMutation
      && descriptor.steps[0].binding == .none
    let unboundWorkspaceMutation = standingWorkspaceMutation || runtimeCheckpoint
    guard
      descriptor.minimumEffect <= .hostOnly
        || (unboundWorkspaceMutation && descriptor.minimumEffect == .deviceMutation)
    else {
      throw RuntimeJobEngineError.rejected(
        .invalidInput,
        "\(descriptor.reference) declares binding none but permits an effect above hostOnly")
    }
    guard
      descriptor.permittedEffects.allSatisfy({ $0 <= .hostOnly }) || unboundWorkspaceMutation
    else {
      throw RuntimeJobEngineError.rejected(
        .invalidInput,
        "\(descriptor.reference) declares binding none but permits an effect above hostOnly")
    }
    for step in descriptor.steps {
      // Unchanged, and the part that actually protects a device: nothing
      // inside an unbound operation may require a device binding.
      guard step.binding == .none else {
        throw RuntimeJobEngineError.rejected(
          .invalidInput,
          "\(descriptor.reference) is host-only but step \(step.stepID) requires a device binding")
      }
      guard step.effect <= .hostOnly || (unboundWorkspaceMutation && step.effect == .deviceMutation)
      else {
        throw RuntimeJobEngineError.rejected(
          .invalidInput,
          "\(descriptor.reference) is host-only but step \(step.stepID) declares effect "
            + step.effect.rawValue)
      }
    }
  }

  private static func validateEvidenceFacts(
    _ facts: ProviderFacts?,
    targetID: String,
    bindingRevision: Int?,
    providerID: String
  ) throws {
    guard let facts,
      facts.targetID == targetID,
      let expectedBinding = bindingRevision,
      facts.bindingRevision == expectedBinding,
      facts.providerID == providerID,
      let connectKey = facts.executionConnectKey,
      !connectKey.isEmpty,
      let identity = facts.deviceIdentitySHA256,
      isLowercaseSHA256(identity),
      !facts.toolVersion.isEmpty,
      isLowercaseSHA256(facts.toolSHA256)
    else {
      throw RuntimeDispatchFailure.failed(
        "evidenceIncomplete: target/binding/routing/tool facts are absent or mismatched")
    }
  }

  private static func validateMaterializedTargetFacts(
    _ facts: ProviderFacts?,
    record: RuntimeJobRecord?,
    providerID: String
  ) throws {
    guard let record else {
      throw RuntimeDispatchFailure.failed(
        "materialized target binding is unavailable")
    }
    try validateEvidenceFacts(
      facts,
      targetID: record.request.target.targetID,
      bindingRevision: record.request.target.expectedBindingRevision,
      providerID: providerID)
    guard let facts,
      let materializedIdentity =
        record.materializedStableTargetIdentitySHA256,
      let materializedRevision = record.materializedBindingRevision,
      facts.deviceIdentitySHA256 == materializedIdentity,
      facts.bindingRevision == materializedRevision
    else {
      throw RuntimeDispatchFailure.failed(
        "target identity or binding revision drifted after plan materialization")
    }
  }

  private func requireCompleteEvidencePreflight(
    jobID: String, beforeStepID: String
  ) throws {
    guard let record = jobs[jobID]?.record,
      record.evidencePreflight?.isComplete == true,
      record.evidenceObservation != nil
    else {
      throw RuntimeDispatchFailure.failed(
        "evidenceIncomplete: three-step typed preflight is incomplete before \(beforeStepID)")
    }
  }

  /// Optional steps are selected by the inputs that make them meaningful -
  /// e.g. a trace capture only runs when trace categories were requested.
  private func isOptionalStepSelected(
    _ step: CatalogStepDescriptor, jobID: String, descriptor: CatalogOperationDescriptor
  ) -> Bool {
    // A step whose upstream never ran cannot run either: receiving a trace
    // that was never captured would publish a product out of thin air and
    // make a partial run look whole.
    if let upstream = Self.optionalStepUpstream[descriptor.reference]?[step.stepID],
      jobs[jobID]?.skippedStepIDs.contains(upstream) == true
    {
      return false
    }
    let inputs = jobs[jobID]?.record.request.inputs ?? [:]
    return Self.stepIsRequested(step, descriptor: descriptor, inputs: inputs)
  }

  /// Which optional step depends on which. Kept explicit rather than
  /// inferred from step order so a reordering cannot silently change what
  /// runs after a failure.
  static let optionalStepUpstream: [String: [String: String]] = [
    "capture.diagnostics@1": [
      "receive-trace-artifact": "capture-trace",
      "cleanup-remote-temp": "capture-trace",
      // r2 added the tree legs and missed this table, so a failed
      // `capture-ui-tree` still ran its receive. Registering a new file leg
      // here is not optional bookkeeping: it is what stops a product being
      // published out of thin air.
      "receive-ui-tree": "capture-ui-tree",
      "cleanup-ui-tree-temp": "capture-ui-tree",
      "receive-screenshot": "capture-screenshot",
      "cleanup-screenshot-temp": "capture-screenshot",
    ]
  ]

  /// Records every product an unrun optional step owned as missing, with
  /// the reason. This is what keeps a partial capture honest.
  private func recordSkippedOptionalStep(
    jobID: String, step: CatalogStepDescriptor, descriptor: CatalogOperationDescriptor,
    reason: String
  ) async throws {
    appendTimeline(jobID: jobID, entry: "skipped \(step.stepID): \(reason)")
    if var runtime = jobs[jobID] {
      runtime.skippedStepIDs.insert(step.stepID)
      runtime.record.skipReasons[step.stepID] = reason
      jobs[jobID] = runtime
    }
    guard let artifactStore, let runtime = jobs[jobID],
      let names = RuntimeArtifactService.artifacts(
        reference: descriptor.reference, stepID: step.stepID)
    else { return }
    let binding = RuntimeArtifactService.bindingSnapshot(for: runtime.record)
    for name in names {
      guard let declaration = descriptor.artifacts.first(where: { $0.name == name }) else {
        continue
      }
      _ = try? await artifactStore.recordMissing(
        jobID: jobID, sessionID: runtime.record.sessionID, stepID: step.stepID, name: name,
        mediaType: declaration.mediaType, privacy: declaration.privacy,
        retentionClass: declaration.retentionClass, sourceOperation: descriptor.reference,
        providerID: descriptor.provider.rawValue, bindingSnapshot: binding, reason: reason)
    }
  }

  /// Hands one delegated step to `arkforged` and records what came back.
  ///
  /// The receipt is the daemon's, unchanged. This method does not judge it: a
  /// disposition of `outcomeUnknown` is journalled as such rather than retried,
  /// because a write whose outcome is unknown is precisely what must not be
  /// replayed (ArkForge `architecture.md` 14.1).
  private func dispatchThroughArkForge(
    jobID: String, step: CatalogStepDescriptor,
    descriptor: CatalogOperationDescriptor, context: ProviderExecutionContext
  ) async throws {
    guard let lane = configuration.arkForgeLane else {
      // Named rather than generic. This build simply has no route to the
      // daemon, which is a composition fact an operator can act on — unlike
      // "dispatch failed", which sends them looking at the device.
      throw RuntimeJobEngineError.rejected(
        .invalidInput,
        "\(step.stepID) is performed by arkforged under a StepPermit, and this build has no "
          + "ArkForge lane composed; nothing was dispatched and the device was not touched "
          + "(CHG-2026-059)")
    }
    guard let runtime = jobs[jobID] else {
      throw RuntimeJobEngineError.jobNotFound(jobID)
    }
    // The binding travels with the call rather than being resolved by the
    // lane. The engine already holds it — it is the context this very step was
    // admitted against — and having the lane look it up again would let the
    // two disagree about which device is under the write.
    guard let connectKey = context.connectKey, let identity = context.expectedIdentitySHA256
    else {
      throw RuntimeJobEngineError.internalFailure(
        "\(step.stepID) reached the ArkForge lane without a descriptor-bound device")
    }
    // The artifact this engine already resolved and measured. Passed rather
    // than re-resolved for the same reason as the binding: two resolutions
    // could disagree about which image is under the write.
    guard let resolved = context.resolvedInputArtifact else {
      throw RuntimeJobEngineError.internalFailure(
        "\(step.stepID) reached the ArkForge lane with no resolved input artifact; arkforged "
          + "materializes the plan from the archive, so there is nothing to materialize from")
    }
    guard let profileID = configuration.arkForgeDeviceProfileID, !profileID.isEmpty else {
      throw RuntimeJobEngineError.rejected(
        .invalidInput,
        "\(step.stepID) needs the exact DeviceProfile id@version arkforged loaded, and this "
          + "build composed a "
          + "lane without one; nothing was dispatched and the device was not touched")
    }
    // The port path this job's device was confirmed at, named by the constant
    // the producer publishes rather than by a literal.
    //
    // It used to read `serverFacts["usbTopology"]`, a key nothing writes —
    // `RockchipRuntimeComposition` publishes it as
    // `dayu200HDCNormalAliasUSBTopology` — and `?? ""` turned that miss into an
    // empty string. The lane then refused, correctly, but only after the job
    // had put the board in Loader: a spelling mistake surfaced as a device left
    // in the wrong mode. Missing is now a refusal here, before anything moves.
    //
    // The value survives the mode change on purpose. It is the alias confirmed
    // while the device was in hdc-normal, held in the binding store, so it is
    // still answerable once the device is in Loader and no longer enumerating
    // as itself.
    guard
      let topology = context.serverFacts[
        TargetStoreRockchipRuntimeFactsPort.hdcAliasTopologyServerFactKey],
      !topology.isEmpty
    else {
      throw RuntimeJobEngineError.internalFailure(
        "\(step.stepID) reached the ArkForge lane without the confirmed HDC-normal USB "
          + "topology (\(TargetStoreRockchipRuntimeFactsPort.hdcAliasTopologyServerFactKey)); the lane "
          + "identifies the board by that port path and will not guess one. Nothing was "
          + "dispatched and the device was not touched")
    }
    let laneArtifact = ArkForgeLaneArtifact(
      fileURL: resolved.fileURL, sha256: resolved.sha256, profileID: profileID)
    let laneBinding = ArkForgeLaneDeviceBinding(
      connectKey: connectKey, stableIdentitySHA256: identity,
      targetID: runtime.record.request.target.targetID,
      bindingRevision: runtime.record.request.target.expectedBindingRevision ?? 1,
      usbTopology: topology)
    let executionPurpose =
      runtime.record.admissionEvidence?.completeOverwriteRecovery == nil
      ? "primaryFlash" : "supersedingRecovery"

    // `startExecution` cannot touch the device. Its returned identity is the
    // first durable half of the cross-process join and must land before the
    // ArkDeck intent that authorizes `performPrepared` to sign a permit.
    let execution: RuntimeArkForgeLaneExecution
    if let persisted = runtime.arkForgeState.execution {
      execution = persisted
    } else {
      execution = try await lane.prepareExecution(
        jobID: jobID, artifact: laneArtifact, binding: laneBinding,
        executionPurpose: executionPurpose)
      guard var refreshed = jobs[jobID] else {
        throw RuntimeJobEngineError.jobNotFound(jobID)
      }
      try Self.validateArkForgeLaneExecution(
        execution, jobID: jobID, artifact: laneArtifact, binding: laneBinding,
        executionPurpose: executionPurpose, toolchainSHA256: lane.toolchainSHA256)
      refreshed.arkForgeState.execution = execution
      try persistArkForgeRuntimeJobState(refreshed.arkForgeState, jobID: jobID)
      jobs[jobID] = refreshed
    }
    try Self.validateArkForgeLaneExecution(
      execution, jobID: jobID, artifact: laneArtifact, binding: laneBinding,
      executionPurpose: executionPurpose, toolchainSHA256: lane.toolchainSHA256)

    guard var current = jobs[jobID] else {
      throw RuntimeJobEngineError.jobNotFound(jobID)
    }
    if cancellationRequests.contains(jobID)
      || current.record.state == JobState.cancelRequested.rawValue
    {
      try completeCancellationAtSafeBoundary(
        jobID: jobID, baseline: current, step: nil, intentEventID: nil,
        reason: "client-cancel before ArkForge permit admission")
      throw RuntimeHostDispatchCancellation()
    }
    let workflowStep = try Self.journalStep(
      for: step, jobID: jobID, inputs: current.record.request.inputs,
      action: nil, resolvedInputArtifact: context.resolvedInputArtifact,
      operationReference: descriptor.reference)
    let intentEventID = "intent-\(step.stepID)"
    let isDeviceBound = step.binding == .confirmedDevice
    let journalIdentity = context.expectedIdentitySHA256 ?? String(repeating: "0", count: 64)
    try current.journal.appendAndSynchronize(
      try JournalEvent.stepIntent(
        eventID: intentEventID, sequence: current.nextSequence,
        sessionID: current.record.sessionID, jobID: jobID, timestamp: nowUTC(),
        step: workflowStep,
        target: JournalTarget(
          scope: isDeviceBound ? "device" : "host",
          targetID: current.record.request.target.targetID,
          connectKey: isDeviceBound ? "sha256:\(journalIdentity)" : nil,
          identitySnapshotHash: isDeviceBound ? journalIdentity : nil),
        attempt: 1,
        bindingRevision: isDeviceBound
          ? (current.record.request.target.expectedBindingRevision ?? 1) : nil,
        schemaVersion: Self.journalSchemaVersion(of: current.record)))
    current.nextSequence += 1
    current.record.recoveryStepID = step.stepID
    current.record.recoveryIntentEventID = intentEventID
    current.record.timeline.append(
      "intent \(step.stepID) correlated daemon-job=\(execution.daemonJobID)")
    try persistRuntimeRecord(current.record)
    jobs[jobID] = current

    let receipt: ArkForgeActionReceiptSummary
    do {
      receipt = try await lane.performPrepared(
        stepID: step.stepID, execution: execution,
        artifact: laneArtifact, binding: laneBinding)
    } catch let failure as RuntimeDispatchFailure {
      var failed = jobs[jobID] ?? current
      switch failure {
      case .outcomeUnknown:
        // Preserve the one outstanding intent. Reconciliation observes the
        // exact daemon job or reads the device; it never creates a new job or
        // signs this capability again.
        failed.record.timeline.append(
          "outcomeUnknown \(step.stepID); correlated daemon job retained")
        failed.record.recoveryStepID = step.stepID
        failed.record.recoveryIntentEventID = intentEventID
        try persistRuntimeRecord(failed.record)
        jobs[jobID] = failed
        throw failure
      case .confirmedNotExecuted, .confirmedNotExecutedWithDiagnostic, .failed:
        let confirmedNotExecuted: Bool
        switch failure {
        case .confirmedNotExecuted, .confirmedNotExecutedWithDiagnostic:
          confirmedNotExecuted = true
        default:
          confirmedNotExecuted = false
        }
        try failed.journal.appendAndSynchronize(
          JournalEvent.stepOutcome(
            eventID: "outcome-\(step.stepID)", sequence: failed.nextSequence,
            sessionID: failed.record.sessionID, jobID: jobID, timestamp: nowUTC(),
            stepID: step.stepID, attempt: 1,
            correlatesToIntentEventID: intentEventID,
            result: "failed", outcomeCertainty: .confirmed,
            semanticCode: confirmedNotExecuted
              ? Self.confirmedNotExecutedSemanticCode : nil,
            schemaVersion: Self.journalSchemaVersion(of: failed.record)))
        failed.nextSequence += 1
        failed.record.recoveryStepID = nil
        failed.record.recoveryIntentEventID = nil
        try persistRuntimeRecord(failed.record)
        jobs[jobID] = failed
        throw failure
      }
    } catch {
      var unknown = jobs[jobID] ?? current
      unknown.record.timeline.append(
        "outcomeUnknown \(step.stepID); correlated daemon observation failed: \(error)")
      try persistRuntimeRecord(unknown.record)
      jobs[jobID] = unknown
      throw RuntimeDispatchFailure.outcomeUnknown(
        "lost the terminal state of correlated arkforged job \(execution.daemonJobID): \(error)")
    }

    // Persist the exact typed terminal receipt before the ArkDeck outcome.
    // A crash can leave a completed receipt beside an outstanding intent; the
    // passive recovery path can close that pair. The inverse (success without
    // durable evidence) is impossible.
    let durableReceipt = RuntimeArkForgePlanCompletionReceipt(receipt)
    do {
      try Self.validateArkForgePlanCompletionReceipt(
        durableReceipt, jobID: jobID, execution: execution)
    } catch {
      var unknown = jobs[jobID] ?? current
      unknown.record.timeline.append(
        "outcomeUnknown \(step.stepID); daemon terminal receipt failed canonical validation")
      try persistRuntimeRecord(unknown.record)
      jobs[jobID] = unknown
      throw RuntimeDispatchFailure.outcomeUnknown("\(error)")
    }
    current = jobs[jobID] ?? current
    current.arkForgeState.planCompletionReceipt = durableReceipt
    try persistArkForgeRuntimeJobState(current.arkForgeState, jobID: jobID)
    try current.journal.appendAndSynchronize(
      JournalEvent.stepOutcome(
        eventID: "outcome-\(step.stepID)", sequence: current.nextSequence,
        sessionID: current.record.sessionID, jobID: jobID, timestamp: nowUTC(),
        stepID: step.stepID, attempt: 1,
        correlatesToIntentEventID: intentEventID,
        result: "succeeded", outcomeCertainty: .confirmed,
        semanticCode: Self.arkForgePlanCompletionSemanticCode,
        summary: Self.arkForgePlanCompletionSummary(durableReceipt),
        schemaVersion: Self.journalSchemaVersion(of: current.record)))
    current.nextSequence += 1
    current.record.recoveryStepID = nil
    current.record.recoveryIntentEventID = nil
    try persistRuntimeRecord(current.record)
    jobs[jobID] = current
  }

  /// Closes one ArkDeck catalog step from the already-completed ArkForge plan.
  ///
  /// This method performs no device action and never calls `lane.perform`.
  /// The only accepted source is the terminal receipt cached after the one
  /// ArkForge execution completed.  Each catalog obligation still gets its
  /// own WAL pair so recovery finalization can require exact typed outcomes.
  private func journalArkForgePlanCompletion(
    jobID: String, step: CatalogStepDescriptor,
    descriptor: CatalogOperationDescriptor, lane: any ArkForgeLane
  ) async throws {
    guard Self.arkForgePlanCompletionSteps.contains(step.stepID) else {
      throw RuntimeJobEngineError.internalFailure(
        "\(step.stepID) is not an ArkForge plan-completion projection")
    }
    guard let receipt = await arkForgePlanCompletionReceipt(jobID: jobID, lane: lane) else {
      throw RuntimeDispatchFailure.failed(
        "\(step.stepID) cannot be confirmed: ArkForge has no completed-plan receipt for \(jobID)")
    }
    try Self.validateArkForgePlanCompletionReceipt(
      receipt, jobID: jobID,
      execution: jobs[jobID]?.arkForgeState.execution)
    guard var current = jobs[jobID] else {
      throw RuntimeJobEngineError.jobNotFound(jobID)
    }
    let workflowStep = try Self.journalStep(
      for: step, jobID: jobID, inputs: current.record.request.inputs,
      action: nil, resolvedInputArtifact: nil,
      operationReference: descriptor.reference,
      delegatedArkForgePlanCompletion: true)
    let intentEventID = "intent-\(step.stepID)"
    guard let stableIdentity = current.record.materializedStableTargetIdentitySHA256,
      Self.isLowercaseSHA256(stableIdentity),
      let bindingRevision = current.record.materializedBindingRevision,
      bindingRevision > 0
    else {
      throw RuntimeJobEngineError.internalFailure(
        "\(step.stepID) has no immutable Runtime target binding for its ArkForge proof")
    }
    try current.journal.appendAndSynchronize(
      try JournalEvent.stepIntent(
        eventID: intentEventID, sequence: current.nextSequence,
        sessionID: current.record.sessionID, jobID: jobID, timestamp: nowUTC(),
        step: workflowStep,
        target: JournalTarget(
          scope: "device", targetID: current.record.request.target.targetID,
          connectKey: "sha256:\(stableIdentity)",
          identitySnapshotHash: stableIdentity),
        attempt: 1, bindingRevision: bindingRevision,
        schemaVersion: Self.journalSchemaVersion(of: current.record)))
    current.nextSequence += 1
    current.record.recoveryStepID = step.stepID
    current.record.recoveryIntentEventID = intentEventID
    try persistRuntimeRecord(current.record)
    try current.journal.appendAndSynchronize(
      JournalEvent.stepOutcome(
        eventID: "outcome-\(step.stepID)", sequence: current.nextSequence,
        sessionID: current.record.sessionID, jobID: jobID, timestamp: nowUTC(),
        stepID: step.stepID, attempt: 1,
        correlatesToIntentEventID: intentEventID,
        result: "succeeded", outcomeCertainty: .confirmed,
        semanticCode: Self.arkForgePlanCompletionSemanticCode,
        summary: Self.arkForgePlanCompletionSummary(receipt),
        schemaVersion: Self.journalSchemaVersion(of: current.record)))
    current.nextSequence += 1
    jobs[jobID] = current
  }

  /// Validates the terminal managed-control receipt that subsumes the ordered
  /// reboot/reconnect/postflight tail of an ArkForge plan.
  ///
  /// The evidence digest is recomputed over the exact typed facts rather than
  /// accepted as an opaque 32-byte value. Required postflight facts keep a
  /// write receipt, a typed skip, or an arbitrary success string from being
  /// repurposed as plan-completion evidence.
  private static func validateArkForgePlanCompletionReceipt(
    _ receipt: RuntimeArkForgePlanCompletionReceipt, jobID: String,
    execution: RuntimeArkForgeLaneExecution? = nil
  ) throws {
    let facts = Dictionary(
      receipt.facts.map { ($0.key, $0.value) },
      uniquingKeysWith: { first, _ in first })
    let matchesExecution =
      execution.map { correlated in
        receipt.jobID == correlated.daemonJobID && receipt.planID == correlated.planID
          && facts["usbTopology"] == correlated.usbTopology
      } ?? true
    guard facts.count == receipt.facts.count,
      receipt.jobID.hasPrefix("JOB-"), receipt.planID.hasPrefix("PLAN-"),
      receipt.stepID.hasPrefix("STEP-"), !receipt.permitID.isEmpty,
      receipt.disposition == "semanticSuccess",
      receipt.evidenceSHA256.count == 32,
      receipt.evidenceSHA256
        == ArkForgeManagedControlPort.canonicalFactsDigest(facts),
      facts["const.product.model"]?.isEmpty == false,
      facts["const.ohos.fullname"]?.isEmpty == false,
      facts["usbTopology"]?.isEmpty == false,
      matchesExecution
    else {
      throw RuntimeDispatchFailure.outcomeUnknown(
        "ArkForge returned no canonical completed-plan postflight receipt for \(jobID)")
    }
  }

  private static func arkForgePlanCompletionSummary(
    _ receipt: RuntimeArkForgePlanCompletionReceipt
  ) -> String {
    let evidence = receipt.evidenceSHA256.map { String(format: "%02x", $0) }.joined()
    return
      "arkforge-plan=\(receipt.planID); daemon-job=\(receipt.jobID); "
      + "terminal-step=\(receipt.stepID); evidence-sha256=\(evidence)"
  }

  private func arkForgePlanCompletionReceipt(
    jobID: String, lane: any ArkForgeLane
  ) async -> RuntimeArkForgePlanCompletionReceipt? {
    if let durable = jobs[jobID]?.arkForgeState.planCompletionReceipt {
      return durable
    }
    guard let live = await lane.completedPlanReceipt(jobID: jobID) else { return nil }
    return RuntimeArkForgePlanCompletionReceipt(live)
  }

  private static func validateArkForgeLaneExecution(
    _ execution: RuntimeArkForgeLaneExecution, jobID: String,
    artifact: ArkForgeLaneArtifact, binding: ArkForgeLaneDeviceBinding,
    executionPurpose: String, toolchainSHA256: String
  ) throws {
    guard execution.arkDeckJobID == jobID,
      !execution.daemonJobID.isEmpty, !execution.planID.isEmpty,
      isLowercaseSHA256(execution.planSHA256),
      execution.executionPurpose == executionPurpose,
      execution.artifactSHA256 == artifact.sha256.lowercased(),
      execution.artifactProfileID == artifact.profileID,
      execution.targetID == binding.targetID,
      execution.bindingRevision == binding.bindingRevision,
      execution.stableIdentitySHA256 == binding.stableIdentitySHA256.lowercased(),
      execution.usbTopology == binding.usbTopology,
      !execution.observationMode.isEmpty,
      execution.toolchainSHA256 == toolchainSHA256.lowercased()
    else {
      throw RuntimeDispatchFailure.confirmedNotExecuted(
        "persisted ArkForge execution correlation does not match the admitted Runtime attempt; "
          + "no permit was signed by this call")
    }
  }

  private func dispatchWithWAL(
    jobID: String,
    step: CatalogStepDescriptor,
    action: TypedProviderAction,
    plan: TypedProcessPlan,
    provider: any DeviceProvider,
    context: ProviderExecutionContext,
    descriptor: CatalogOperationDescriptor,
    evidenceFacts: ProviderFacts?
  ) async throws {
    guard var runtime = jobs[jobID] else {
      throw RuntimeJobEngineError.jobNotFound(jobID)
    }
    let isImmediateAnalyzer: Bool = {
      guard step.cancellation == .immediate else { return false }
      if case .analyzer = action { return true }
      return false
    }()
    if let beforeDispatchInstall = configuration.testHooks.beforeDispatchInstall {
      await beforeDispatchInstall(jobID, step.stepID)
      guard let refreshed = jobs[jobID] else {
        throw RuntimeJobEngineError.jobNotFound(jobID)
      }
      runtime = refreshed
    }
    // All production awaits that resolve Artifact/fact inputs happen before
    // this method.  The package-only hook above makes that reentrancy window
    // deterministic in the cancellation contract test.
    // Recheck the actor-owned durable cancellation decision at the last
    // synchronous boundary before an intent or child Task can be installed.
    if cancellationRequests.contains(jobID)
      || runtime.record.state == JobState.cancelRequested.rawValue
    {
      try completeCancellationAtSafeBoundary(
        jobID: jobID, baseline: runtime, step: nil, intentEventID: nil,
        reason: isImmediateAnalyzer
          ? "client-cancel before analyzer dispatch"
          : "client-cancel before the next Catalog safe boundary")
      throw RuntimeHostDispatchCancellation()
    }
    let workflowStep = try Self.journalStep(
      for: step, jobID: jobID, inputs: runtime.record.request.inputs,
      action: action, resolvedInputArtifact: context.resolvedInputArtifact,
      operationReference: descriptor.reference)
    let intentEventID = "intent-\(step.stepID)"
    // Journal target evidence mirrors the descriptor-bound facts without
    // persisting the raw connect key.
    let isDeviceBound = step.binding == .confirmedDevice
    let journalIdentity = context.expectedIdentitySHA256 ?? String(repeating: "0", count: 64)
    let intent = try JournalEvent.stepIntent(
      eventID: intentEventID, sequence: runtime.nextSequence,
      sessionID: runtime.record.sessionID, jobID: jobID,
      timestamp: nowUTC(), step: workflowStep,
      target: JournalTarget(
        scope: isDeviceBound ? "device" : "host",
        targetID: runtime.record.request.target.targetID,
        connectKey: isDeviceBound ? "sha256:\(journalIdentity)" : nil,
        identitySnapshotHash: isDeviceBound ? journalIdentity : nil),
      attempt: 1,
      bindingRevision: isDeviceBound
        ? (runtime.record.request.target.expectedBindingRevision ?? 1) : nil,
      schemaVersion: Self.journalSchemaVersion(of: runtime.record))
    runtime.record.recoveryStepID = step.stepID
    runtime.record.recoveryIntentEventID = intentEventID
    runtime.record.recoveryAction = try PersistedTypedProviderAction(action)
    // Persist the exact typed action before the write-ahead intent can
    // become dispatchable. A crash can leave an unused pending record, but
    // it can never leave a durable external intent whose action recovery
    // must guess from a later catalog.
    try persistRuntimeRecord(runtime.record)
    jobs[jobID] = runtime
    // The write-ahead gate is the production dispatch path: the closure is
    // unreachable unless the intent is durable.
    let gate = WriteAheadIntentGate(journal: runtime.journal)
    do {
      try gate.dispatch(intent: intent) { () }
    } catch {
      runtime.record.recoveryStepID = nil
      runtime.record.recoveryIntentEventID = nil
      runtime.record.recoveryAction = nil
      try? persistRuntimeRecord(runtime.record)
      jobs[jobID] = runtime
      throw error
    }
    runtime.nextSequence += 1
    runtime.record.timeline.append("intent \(step.stepID)")
    if runtime.record.actualStepKinds?.contains(step.kind.rawValue) != true {
      var kinds = runtime.record.actualStepKinds ?? []
      kinds.append(step.kind.rawValue)
      runtime.record.actualStepKinds = kinds
    }
    if runtime.record.firstEvidenceStepAtUTC == nil,
      step.binding == .confirmedDevice,
      !Self.isEvidencePreflightStep(step)
    {
      runtime.record.firstEvidenceStepAtUTC = context.nowUTC
    }
    jobs[jobID] = runtime

    let receipt: ProviderProcessReceipt
    let progressKey = ProcessProgressKey(jobID: jobID, stepID: step.stepID)
    activeProcessProgressKeys.insert(progressKey)
    defer {
      activeProcessProgressKeys.remove(progressKey)
      latestProcessProgress.removeValue(forKey: progressKey)
    }
    let progressHandler: RuntimeProcessProgressHandler = { [weak self] progress in
      await self?.recordProcessProgress(
        progress, jobID: jobID, stepID: step.stepID)
    }
    // What the host can actually observe about when a step reached the
    // device: the interval it was dispatching in. A screenshot's shutter
    // opened somewhere inside this, and that is as precise as anything here
    // can honestly be.
    let dispatchOpenedAt = nowPreciseUTC()
    let dispatchTask = Task { [dispatcher, progressHandler] in
      try await dispatcher.dispatch(plan, progress: progressHandler)
    }
    let activeDispatchID = UUID()
    activeDispatches[jobID] = ActiveRuntimeDispatch(
      id: activeDispatchID,
      cancellationMode: isImmediateAnalyzer ? .immediateAnalyzerOpen : .safeBoundary,
      task: dispatchTask)
    defer {
      if activeDispatches[jobID]?.id == activeDispatchID {
        activeDispatches.removeValue(forKey: jobID)
      }
    }
    do {
      receipt = try await dispatchTask.value
      // The window closes where the dispatch returned, and stays with the
      // step so whatever it publishes can say when it was observed.
      stepObservationWindows["\(jobID)|\(step.stepID)"] = ArtifactObservationWindow(
        startUTC: dispatchOpenedAt, endUTC: nowPreciseUTC())
      if cancellationRequests.contains(jobID), isImmediateAnalyzer {
        // The task completed without a cancellation receipt.  Do not infer
        // descendant cleanup from a leader/result race; preserve the intent
        // for explicit recovery instead of publishing a cancelled success.
        var current = jobs[jobID] ?? runtime
        current.record.timeline.append(
          "analyzer cancellation raced completion without process-group drain proof")
        jobs[jobID] = current
        throw RuntimeDispatchFailure.outcomeUnknown(
          "analyzer cancellation lacks process-group drain proof")
      }
    } catch let resolution as RuntimeDispatchCancellationResolution {
      guard cancellationRequests.contains(jobID), isImmediateAnalyzer else {
        throw RuntimeDispatchFailure.outcomeUnknown(
          "process cancellation occurred without an admitted immediate cancellation")
      }
      switch resolution {
      case .drained:
        try completeCancellationAtSafeBoundary(
          jobID: jobID, baseline: runtime, step: step,
          intentEventID: intentEventID,
          reason: "client-cancel after analyzer process-group drain")
        throw RuntimeHostDispatchCancellation()
      case .unconfirmed:
        var current = jobs[jobID] ?? runtime
        current.record.timeline.append(
          "analyzer cancellation process-group drain unconfirmed; intent retained")
        jobs[jobID] = current
        throw RuntimeDispatchFailure.outcomeUnknown(
          "analyzer process-group drain unconfirmed")
      }
    } catch is CancellationError {
      throw RuntimeDispatchFailure.outcomeUnknown(
        "dispatch task cancellation carried no process-group drain proof")
    } catch let failure as RuntimeDispatchFailure {
      var current = jobs[jobID] ?? runtime
      let confirmedNotExecuted: Bool
      let diagnostic: RockchipFlashRuntimeDiagnostic?
      switch failure {
      case .outcomeUnknown:
        // The intent is durable, but there is deliberately no invented
        // outcome. Recovery must resolve this exact outstanding intent by
        // readback; recording an outcomeUnknown stepOutcome would make the
        // journal permanently non-resumable.
        current.record.timeline.append(
          "outcomeUnknown \(step.stepID); durable intent left outstanding")
        current.record.recoveryStepID = step.stepID
        jobs[jobID] = current
        throw failure
      case .confirmedNotExecuted:
        confirmedNotExecuted = true
        diagnostic = nil
      case .confirmedNotExecutedWithDiagnostic(_, let value):
        confirmedNotExecuted = true
        diagnostic = value
      case .failed:
        confirmedNotExecuted = false
        diagnostic = nil
      }
      try current.journal.appendAndSynchronize(
        JournalEvent.stepOutcome(
          eventID: "outcome-\(step.stepID)", sequence: current.nextSequence,
          sessionID: current.record.sessionID, jobID: jobID, timestamp: nowUTC(),
          stepID: step.stepID, attempt: 1,
          correlatesToIntentEventID: intentEventID,
          result: "failed",
          outcomeCertainty: .confirmed,
          semanticCode: confirmedNotExecuted
            ? Self.confirmedNotExecutedSemanticCode : nil,
          schemaVersion: Self.journalSchemaVersion(of: current.record)))
      current.nextSequence += 1
      if confirmedNotExecuted {
        let suffix = diagnostic.map { " [diagnostic=\($0.rawValue)]" } ?? ""
        current.record.timeline.append("confirmed not executed \(step.stepID)\(suffix)")
      } else {
        current.record.timeline.append("failed \(step.stepID)")
      }
      current.record.recoveryStepID = nil
      current.record.recoveryIntentEventID = nil
      current.record.recoveryAction = nil
      jobs[jobID] = current
      throw failure
    }

    let providerOutcome = try provider.verify(receipt: receipt, action: action, context: context)
    let outcome: ProviderSemanticOutcome
    if step.stepID == "verify-port-rule"
      || step.stepID == "verify-port-rule-compensation",
      case .verified(let summary) = providerOutcome,
      let rawPresent = summary["present"],
      let present = Bool(rawPresent)
    {
      let expectedPresent = descriptor.reference == "port-forward.create@1"
      outcome =
        present == expectedPresent
        ? providerOutcome
        : .failed(
          code: "portForwardReadbackMismatch",
          detail: expectedPresent
            ? "the exact typed rule is absent after create"
            : "the exact typed rule remains after remove")
    } else {
      outcome = providerOutcome
    }
    var current = jobs[jobID] ?? runtime
    switch outcome {
    case .verified(let summary):
      if isImmediateAnalyzer,
        var active = activeDispatches[jobID], active.id == activeDispatchID
      {
        active.cancellationMode = .analyzerCommitLinearized
        activeDispatches[jobID] = active
        if let hook = configuration.testHooks.afterAnalyzerCommitLinearization {
          await hook(jobID, step.stepID)
        }
        // A cancellation accepted before this linearization would already
        // have cancelled the dispatch Task or set the durable state. Never
        // publish across that boundary.
        guard !cancellationRequests.contains(jobID),
          jobs[jobID]?.record.state != JobState.cancelRequested.rawValue
        else {
          throw RuntimeDispatchFailure.outcomeUnknown(
            "analyzer cancellation crossed the success commit boundary")
        }
      }
      let publishesBeforeOutcome = [
        AnalyzerProvider.traceSummary, AnalyzerProvider.traceAnalysis,
      ].contains(descriptor.reference)
      if publishesBeforeOutcome {
        // The exact validated Analyzer bytes become durable before the
        // journal can call the step succeeded. A crash may therefore leave
        // an honest outstanding read-only intent with a complete Artifact,
        // but can never leave a durable success whose required Artifact is
        // absent and whose stdout was lost.
        try await publishDeclaredArtifacts(
          jobID: jobID, step: step, summary: summary, receipt: receipt)
        if let hook = configuration.testHooks.afterAnalyzerArtifactPublication {
          await hook(jobID, step.stepID)
        }
      }
      let outcomeAt = nowUTC()
      try current.journal.appendAndSynchronize(
        JournalEvent.stepOutcome(
          eventID: "outcome-\(step.stepID)", sequence: current.nextSequence,
          sessionID: current.record.sessionID, jobID: jobID, timestamp: outcomeAt,
          stepID: step.stepID, attempt: 1,
          correlatesToIntentEventID: intentEventID,
          result: "succeeded", outcomeCertainty: .confirmed,
          schemaVersion: Self.journalSchemaVersion(of: current.record)))
      current.nextSequence += 1
      current.record.timeline.append("verified \(step.stepID) \(summary.keys.sorted())")
      if let anchor = summary["coverageAnchor"], let held = summary["ringHeldCoverageAnchor"] {
        current.record.ringCoverage = RuntimeRingCoverage(
          anchor: anchor, ringHeldAnchor: held == "true")
      }
      // The timeline keeps which facts were verified, not their values, so a
      // run of stills would otherwise lose the only measurements anyone can
      // lay a timeline out from.
      if let requested = summary["requestedFrameCount"].flatMap(Int.init),
        let captured = summary["capturedFrameCount"].flatMap(Int.init)
      {
        current.record.screenSequence = RuntimeScreenSequence(
          requestedFrameCount: requested, capturedFrameCount: captured,
          frameDurationsSeconds: (summary["frameDurationsSeconds"] ?? "")
            .split(separator: ",").compactMap { Double($0) })
      }
      current.record.recoveryStepID = nil
      current.record.recoveryIntentEventID = nil
      current.record.recoveryAction = nil
      jobs[jobID] = current
      try captureEvidencePreflightFragmentIfEligible(
        jobID: jobID, step: step, action: action, summary: summary,
        context: context, facts: evidenceFacts, outcomeAtUTC: outcomeAt,
        descriptor: descriptor)
      if !publishesBeforeOutcome {
        try await publishDeclaredArtifacts(
          jobID: jobID, step: step, summary: summary, receipt: receipt)
      }
    case .failed(let code, let detail):
      try current.journal.appendAndSynchronize(
        JournalEvent.stepOutcome(
          eventID: "outcome-\(step.stepID)", sequence: current.nextSequence,
          sessionID: current.record.sessionID, jobID: jobID, timestamp: nowUTC(),
          stepID: step.stepID, attempt: 1,
          correlatesToIntentEventID: intentEventID,
          result: "failed", outcomeCertainty: .confirmed,
          schemaVersion: Self.journalSchemaVersion(of: current.record)))
      current.nextSequence += 1
      current.record.recoveryStepID = nil
      current.record.recoveryIntentEventID = nil
      current.record.recoveryAction = nil
      current.record.timeline.append(
        "failed \(step.stepID): \(code): \(detail)")
      jobs[jobID] = current
      if RuntimeArtifactService.failedDiagnosticArtifactOperations.contains(descriptor.reference) {
        try await publishDeclaredArtifacts(
          jobID: jobID, step: step,
          summary: [
            "failureCode": code,
            "failureDetail": detail,
          ],
          receipt: receipt)
      }
      throw RuntimeDispatchFailure.failed("\(code): \(detail)")
    case .unknown(let reason), .unsupported(let reason):
      // A mutation whose truth is delegated to a paired readback is not an
      // unknown *external outcome*: the effect either happened or did not,
      // and the very next required step is about to determine which. The
      // job continues to that readback; if the readback fails, the job
      // fails. Any other unknown still halts with zero replay.
      if Self.awaitsReadback(step: step, descriptor: descriptor) {
        try current.journal.appendAndSynchronize(
          JournalEvent.stepOutcome(
            eventID: "outcome-\(step.stepID)", sequence: current.nextSequence,
            sessionID: current.record.sessionID, jobID: jobID, timestamp: nowUTC(),
            stepID: step.stepID, attempt: 1,
            correlatesToIntentEventID: intentEventID,
            result: "succeeded", outcomeCertainty: .confirmed,
            schemaVersion: Self.journalSchemaVersion(of: current.record)))
        current.nextSequence += 1
        current.record.timeline.append("dispatched \(step.stepID); awaiting readback")
        current.record.recoveryStepID = nil
        current.record.recoveryIntentEventID = nil
        current.record.recoveryAction = nil
        jobs[jobID] = current
        return
      }
      // Keep the exact intent outstanding. Reconciliation writes the one
      // definitive correlated outcome after a dedicated readback; it
      // never creates a second intent or resends this action.
      current.record.timeline.append(
        "outcomeUnknown \(step.stepID); durable intent left outstanding")
      current.record.recoveryStepID = step.stepID
      jobs[jobID] = current
      throw RuntimeDispatchFailure.outcomeUnknown(reason)
    }
  }

  /// Closes the outstanding Analyzer intent only after its cancelled process
  /// task has returned. Analyzer execution has no external write effect; the
  /// Runtime is the sole publisher, and this correlated failed outcome is
  /// persisted before control can reach publication.
  private func completeCancellationAtSafeBoundary(
    jobID: String,
    baseline: JobRuntime,
    step: CatalogStepDescriptor?,
    intentEventID: String?,
    reason: String
  ) throws {
    var current = jobs[jobID] ?? baseline
    if let step, let intentEventID {
      try current.journal.appendAndSynchronize(
        JournalEvent.stepOutcome(
          eventID: "outcome-\(step.stepID)", sequence: current.nextSequence,
          sessionID: current.record.sessionID, jobID: jobID, timestamp: nowUTC(),
          stepID: step.stepID, attempt: 1,
          correlatesToIntentEventID: intentEventID,
          result: "failed", outcomeCertainty: .confirmed,
          semanticCode: "cancelled",
          schemaVersion: Self.journalSchemaVersion(of: current.record)))
      current.nextSequence += 1
      current.record.timeline.append(
        "cancelled \(step.stepID); dispatch reached a confirmed safe boundary before publication")
    }
    current.record.recoveryStepID = nil
    current.record.recoveryIntentEventID = nil
    current.record.recoveryAction = nil
    if current.record.state != JobState.cancelRequested.rawValue {
      let state = Self.executionState(of: current.record)
      try transition(
        &current, from: state, to: .cancelRequested,
        reason: "durable \(reason)")
    }
    try transition(
      &current, from: .cancelRequested, to: .cancellingAtSafeBoundary,
      reason: "dispatch has a confirmed safe boundary")
    try transition(
      &current, from: .cancellingAtSafeBoundary, to: .cancelled,
      reason: "cancelled intent closed without publication")
    current.record.operationFailure = RuntimeOperationFailure(
      code: .cancelled, category: .cancelled,
      retryability: .notAutomatic, recovery: .none)
    current.record.finishedAtUTC = nowUTC()
    try persistRuntimeRecord(current.record)
    jobs[jobID] = current
  }

  /// Returns the actor's current Job projection at an external-effect safe
  /// boundary. Callers use this after their last `await` and before a
  /// capability use, WAL intent, or child installation, so an older local
  /// projection can never overwrite a durable cancellation decision.
  private func refreshedRuntimeAtCancellationSafeBoundary(
    jobID: String,
    reason: String
  ) throws -> JobRuntime {
    guard let current = jobs[jobID] else {
      throw RuntimeJobEngineError.jobNotFound(jobID)
    }
    if cancellationRequests.contains(jobID)
      || current.record.state == JobState.cancelRequested.rawValue
    {
      try completeCancellationAtSafeBoundary(
        jobID: jobID, baseline: current, step: nil, intentEventID: nil,
        reason: reason)
      throw RuntimeHostDispatchCancellation()
    }
    return current
  }

  /// Consumes a fragment only after its successful outcome is durable.
  /// Failure to correlate or persist any fragment fails closed before a
  /// capture or mutation can be dispatched.
  private func captureEvidencePreflightFragmentIfEligible(
    jobID: String,
    step: CatalogStepDescriptor,
    action: TypedProviderAction,
    summary: [String: String],
    context: ProviderExecutionContext,
    facts: ProviderFacts?,
    outcomeAtUTC: String,
    descriptor: CatalogOperationDescriptor
  ) throws {
    guard Self.requiresEvidencePreflight(descriptor),
      Self.isEvidencePreflightStep(step)
    else { return }
    try Self.validateEvidenceFacts(
      facts, targetID: context.targetID, bindingRevision: context.bindingRevision,
      providerID: descriptor.provider.rawValue)
    guard let facts,
      let bindingRevision = facts.bindingRevision,
      let identity = facts.deviceIdentitySHA256
    else {
      throw RuntimeDispatchFailure.failed(
        "evidenceIncomplete: validated preflight facts disappeared")
    }
    guard var runtime = jobs[jobID] else {
      throw RuntimeJobEngineError.jobNotFound(jobID)
    }

    var accumulator =
      runtime.record.evidencePreflight
      ?? RuntimeEvidencePreflightAccumulator(
        targetID: context.targetID,
        bindingRevision: bindingRevision,
        stableIdentitySHA256: identity,
        providerID: facts.providerID,
        toolVersion: facts.toolVersion,
        toolSHA256: facts.toolSHA256,
        transport: nil,
        confirmedAtUTC: nil,
        model: nil,
        firmware: nil,
        steps: [])
    guard accumulator.targetID == context.targetID,
      accumulator.bindingRevision == bindingRevision,
      accumulator.stableIdentitySHA256 == identity,
      accumulator.providerID == facts.providerID,
      accumulator.toolVersion == facts.toolVersion,
      accumulator.toolSHA256 == facts.toolSHA256
    else {
      throw RuntimeDispatchFailure.failed(
        "evidenceIncomplete: preflight fragments do not share one target/tool correlation")
    }

    let expectedStepIDs = [
      "confirm-evidence-target", "read-evidence-model", "read-evidence-firmware",
    ]
    guard accumulator.steps.count < expectedStepIDs.count,
      expectedStepIDs[accumulator.steps.count] == step.stepID
    else {
      throw RuntimeDispatchFailure.failed(
        "evidenceIncomplete: preflight outcome is duplicated or out of order")
    }
    switch (step.stepID, action) {
    case ("confirm-evidence-target", .hdc(.observeDevice)):
      guard let observedIdentity = summary["deviceIdentitySHA256"],
        observedIdentity == identity,
        let transport = summary["transport"],
        ["usb", "tcp", "uart"].contains(transport)
      else {
        throw RuntimeDispatchFailure.failed(
          "evidenceIncomplete: target confirmation summary is incomplete or mismatched")
      }
      accumulator.transport = transport
    case ("read-evidence-model", .hdc(.queryProperty(.productName))):
      guard let value = summary["value"], !value.isEmpty else {
        throw RuntimeDispatchFailure.failed(
          "evidenceIncomplete: model readback is empty")
      }
      accumulator.model = value
    case ("read-evidence-firmware", .hdc(.queryProperty(.fullBuildVersion))):
      guard let value = summary["value"], !value.isEmpty else {
        throw RuntimeDispatchFailure.failed(
          "evidenceIncomplete: firmware readback is empty")
      }
      accumulator.firmware = value
      // The evidence confirmation becomes fresh only when the complete
      // required prefix is durable, not when its first fragment was read.
      accumulator.confirmedAtUTC = outcomeAtUTC
    default:
      throw RuntimeDispatchFailure.failed(
        "evidenceIncomplete: preflight action does not match its catalog step")
    }
    accumulator.steps.append(
      RuntimeEvidencePreflightStep(
        stepID: step.stepID, stepKind: step.kind.rawValue, outcomeAtUTC: outcomeAtUTC))
    runtime.record.evidencePreflight = accumulator
    runtime.record.timeline.append("evidence-preflight \(step.stepID)")

    if accumulator.isComplete {
      rememberCarriableEvidence(
        accumulator: accumulator, descriptor: descriptor,
        inputs: runtime.record.request.inputs, outcomeAtUTC: outcomeAtUTC)
      runtime.record.evidenceObservation = Self.evidenceObservation(from: accumulator)
      // observe.device publishes its evidence-bearing products from the
      // final preflight outcome itself; the other operations set this at
      // their first post-preflight device step.
      if descriptor.reference == "observe.device@1",
        runtime.record.firstEvidenceStepAtUTC == nil
      {
        runtime.record.firstEvidenceStepAtUTC = outcomeAtUTC
      }
    }
    do {
      try persistRuntimeRecord(runtime.record)
      jobs[jobID] = runtime
    } catch {
      throw RuntimeDispatchFailure.failed(
        "evidenceIncomplete: could not persist preflight fragment: \(error)")
    }
  }

  /// Publishes the products a verified step is responsible for. The
  /// mapping is declared in the catalog, so a step cannot invent an
  /// artifact and a declared artifact cannot silently vanish - anything
  /// the step could not produce is recorded with its reason instead.
  /// Publishes the delegated postflight's declared product from the lane's
  /// terminal receipt.
  ///
  /// The receipt's facts are the daemon's verified observation — the bound
  /// identity, the exact product model and build — so they become the
  /// record's evidence observation, and the catalog artifact is built from
  /// that record the same way the engine-run step would have built it.
  private func publishLanePostflightFacts(
    jobID: String,
    step: CatalogStepDescriptor,
    lane: any ArkForgeLane
  ) async throws {
    guard let receipt = await arkForgePlanCompletionReceipt(jobID: jobID, lane: lane) else {
      // No lane run has happened for this job, so nothing verified anything:
      // the required product cannot be built from facts nobody produced.
      throw RuntimeDispatchFailure.failed(
        "\(step.stepID) was delegated but the lane holds no completed-plan receipt for \(jobID)")
    }
    try Self.validateArkForgePlanCompletionReceipt(
      receipt, jobID: jobID,
      execution: jobs[jobID]?.arkForgeState.execution)
    let facts = Dictionary(
      receipt.facts.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
    if var runtime = jobs[jobID] {
      let confirmedAtUTC = nowUTC()
      runtime.record.evidenceObservation = RuntimeEvidenceObservation(
        targetID: runtime.record.request.target.targetID,
        bindingRevision: runtime.record.request.target.expectedBindingRevision,
        stableIdentitySHA256: facts["stableIdentitySHA256"]
          ?? runtime.record.materializedStableTargetIdentitySHA256,
        model: facts["const.product.model"],
        firmware: facts["const.ohos.fullname"],
        // A completed ArkForge receipt is accepted above only when it carries
        // a verified USB topology. `hdc` names the postflight tool, not the
        // physical transport, and is outside the hardware-evidence contract.
        transport: "usb",
        providerID: runtime.record.providerID,
        toolVersion: ArkForgeNativeRockUSBToolchain.reportedVersion,
        toolSHA256: lane.toolchainSHA256,
        confirmedAtUTC: confirmedAtUTC,
        confirmationMethod: "machineReadback",
        preflightSteps: [])
      runtime.record.firstEvidenceStepAtUTC = confirmedAtUTC
      try persistRuntimeRecord(runtime.record)
      jobs[jobID] = runtime
    }
    try await publishDeclaredArtifacts(
      jobID: jobID, step: step, summary: facts,
      receipt: ProviderProcessReceipt(
        exitStatus: 0, stdout: Data(), stderr: Data(), stdoutTruncated: false,
        durationSeconds: 0, hostManagedRecordID: nil,
        hostManagedSummary: facts, landedArtifact: nil))
  }

  private func publishDeclaredArtifacts(
    jobID: String,
    step: CatalogStepDescriptor,
    summary: [String: String],
    receipt: ProviderProcessReceipt
  ) async throws {
    guard let runtime = jobs[jobID],
      let descriptor = RuntimeOperationCatalog.descriptor(
        reference: runtime.record.operationReference)
    else { return }
    guard
      let mapping = RuntimeArtifactService.artifacts(
        reference: descriptor.reference, stepID: step.stepID)
    else {
      return  // this step owns no declared product
    }
    guard let artifactStore else {
      // Reaching a mapped step without a store can never be success: the
      // Catalog product is part of that step's durable result, not optional
      // telemetry. In particular, trace-summary writes its exact validated
      // bytes before the correlated succeeded outcome; a nil store must not
      // turn that commit into a no-op followed by false success.
      throw RuntimeArtifactPublicationFailure(
        detail: "Artifact store is required for \(descriptor.reference)")
    }
    let binding: ArtifactBindingSnapshot
    if descriptor.reference == OpenHarmonyLocalSigning.operationReference,
      case .string(let sourceLease)? =
        runtime.record.request.inputs["unsignedHapArtifactLease"]
    {
      // Signing is host-only, but its product remains the exact immutable
      // device-bound build product that entered the signer. Preserve that
      // provenance instead of relabelling the HAP as an unbound host file.
      let source = try await artifactStore.resolveLease(sourceLease)
      guard source.bindingSnapshot.targetID == runtime.record.request.target.targetID else {
        throw RuntimeArtifactPublicationFailure(
          detail: "signed HAP source target no longer matches the request")
      }
      binding = source.bindingSnapshot
    } else {
      binding = RuntimeArtifactService.bindingSnapshot(for: runtime.record)
    }
    // Two encodings of one product are not two products: the screenshot leg
    // publishes the one it received and the other is simply not what this
    // capture took. A step that genuinely owns several products - signing,
    // which writes a HAP and a report - still publishes all of them.
    let publishable = RuntimeArtifactService.publishableArtifacts(
      mapping: mapping, requestInputs: runtime.record.request.inputs)
    for name in publishable {
      guard let declaration = descriptor.artifacts.first(where: { $0.name == name }) else {
        continue
      }
      if RuntimeArtifactService.fileBackedArtifacts.contains(name),
        receipt.landedArtifact == nil, !declaration.isRequired
      {
        // Optional ProjectProfile products are absent by contract when that
        // profile declares no output path. Do not fabricate bytes from stdout
        // and do not turn the required build log into a failure.
        continue
      }
      // A received product is the received bytes or it is nothing. The
      // receipt's stdout for a receive step is hdc's progress line, so
      // falling back to it would publish a transfer banner under the
      // artifact's name.
      var landed: ProviderLandedArtifact?
      if RuntimeArtifactService.fileBackedArtifacts.contains(name)
        || RuntimeArtifactService.receivedRedactedArtifacts.contains(name)
      {
        guard let received = receipt.landedArtifact, received.sha256 != nil else {
          let detail = "\(name) has no received host file to publish"
          _ = try? await artifactStore.recordMissing(
            jobID: jobID, sessionID: runtime.record.sessionID,
            stepID: step.stepID, name: name,
            mediaType: declaration.mediaType, privacy: declaration.privacy,
            retentionClass: declaration.retentionClass,
            sourceOperation: descriptor.reference,
            providerID: descriptor.provider.rawValue,
            bindingSnapshot: binding, reason: detail)
          throw RuntimeArtifactPublicationFailure(detail: detail)
        }
        landed = received
      }
      // Sized before it is read: a received file's byte count is already
      // known from the receive, so the budget guard below runs without
      // pulling the bytes into memory first.
      var contents =
        landed == nil
        ? RuntimeArtifactService.artifactContents(
          name: name, summary: summary, receipt: receipt, descriptor: descriptor,
          record: runtime.record)
        : Data()
      let payloadByteCount = landed?.byteCount ?? contents.count
      if descriptor.reference == "capture.diagnostics@1" {
        let budget: Int
        if case .integer(let requested)? =
          runtime.record.request.inputs["totalArtifactByteBudget"]
        {
          budget = Int(requested)
        } else {
          budget = 128 * 1024 * 1024
        }
        let recorded: [RuntimeArtifactMetadata]
        do {
          recorded = try await artifactStore.list(jobID: jobID)
        } catch {
          throw RuntimeArtifactPublicationFailure(
            detail: "cannot inspect job byte budget before \(name): \(error)")
        }
        let used = recorded.filter { $0.status.isPublished }
          .reduce(0) { $0 + $1.byteCount }
        guard used <= budget, payloadByteCount <= budget - used else {
          let detail =
            "job byte budget \(budget) exceeded while publishing \(name)"
          _ = try? await artifactStore.recordMissing(
            jobID: jobID, sessionID: runtime.record.sessionID,
            stepID: step.stepID, name: name,
            mediaType: declaration.mediaType, privacy: declaration.privacy,
            retentionClass: declaration.retentionClass,
            sourceOperation: descriptor.reference,
            providerID: descriptor.provider.rawValue,
            bindingSnapshot: binding, reason: detail)
          throw RuntimeArtifactPublicationFailure(detail: detail)
        }
      }
      do {
        let metadata: RuntimeArtifactMetadata
        if let landed, RuntimeArtifactService.fileBackedArtifacts.contains(name),
          let sha256 = landed.sha256
        {
          metadata = try await artifactStore.publishFile(
            RuntimeArtifactFilePublicationRequest(
              jobID: jobID, sessionID: runtime.record.sessionID, stepID: step.stepID,
              name: name, mediaType: declaration.mediaType, privacy: declaration.privacy,
              retentionClass: declaration.retentionClass,
              sourceOperation: descriptor.reference, providerID: descriptor.provider.rawValue,
              bindingSnapshot: binding, sourceFileURL: landed.localURL,
              expectedByteCount: landed.byteCount, expectedSHA256: sha256,
              observationWindow: observationWindow(
                jobID: jobID, stepID: step.stepID, descriptor: descriptor)))
          // The store now owns the bytes; the staging copy is sensitive
          // capture data and does not outlive the publication.
          try? FileManager.default.removeItem(at: landed.localURL)
        } else {
          if let landed {
            // A received product whose media type carries text goes through
            // the redacting publish path — `publishFile` refuses text/JSON
            // precisely because it skips redaction, and this tree carries
            // on-screen strings. Re-hashed after the read: the bytes that
            // get published must be the bytes the dispatcher measured.
            let received = try Data(contentsOf: landed.localURL, options: [.uncached])
            guard received.count == landed.byteCount,
              SHA256Hex.string(of: received)
                == landed.sha256
            else {
              throw RuntimeArtifactPublicationFailure(
                detail: "\(name) changed between receive and publication")
            }
            contents = received
          }
          let traceDerivation =
            RuntimeArtifactService.traceSummaryDerivation(
              name: name, descriptor: descriptor, summary: summary)
            ?? RuntimeArtifactService.traceAnalysisDerivation(
              name: name, descriptor: descriptor, summary: summary)
          metadata = try await artifactStore.publish(
            RuntimeArtifactPublicationRequest(
              jobID: jobID, sessionID: runtime.record.sessionID, stepID: step.stepID,
              name: name, mediaType: declaration.mediaType, privacy: declaration.privacy,
              retentionClass: declaration.retentionClass,
              sourceOperation: descriptor.reference, providerID: descriptor.provider.rawValue,
              bindingSnapshot: binding, contents: contents,
              derivation: traceDerivation,
              preservesValidatedMachineBytes: traceDerivation != nil,
              observationWindow: observationWindow(
                jobID: jobID, stepID: step.stepID, descriptor: descriptor)))
          if let landed { try? FileManager.default.removeItem(at: landed.localURL) }
        }
        appendTimeline(jobID: jobID, entry: "artifact \(name) -> \(metadata.artifactID)")
      } catch {
        // A publication failure is recorded, never swallowed: the index
        // keeps the declared product with its reason.
        _ = try? await artifactStore.recordMissing(
          jobID: jobID, sessionID: runtime.record.sessionID, stepID: step.stepID,
          name: name, mediaType: declaration.mediaType, privacy: declaration.privacy,
          retentionClass: declaration.retentionClass,
          sourceOperation: descriptor.reference, providerID: descriptor.provider.rawValue,
          bindingSnapshot: binding, reason: "\(error)")
        appendTimeline(jobID: jobID, entry: "artifact \(name) missing: \(error)")
        throw RuntimeArtifactPublicationFailure(
          detail: "\(name) could not be published: \(error)")
      }
    }
  }

  /// Writes the run-level index and summary. The summary states every
  /// declared product and its final status, so a caller reading only the
  /// summary still learns that (say) the trace is missing - a partial
  /// capture can never present itself as complete.
  private func publishFinalizeArtifacts(
    jobID: String, descriptor: CatalogOperationDescriptor
  ) async throws {
    guard let runtime = jobs[jobID],
      let names = RuntimeArtifactService.finalArtifacts(reference: descriptor.reference)
    else { return }
    guard let artifactStore else {
      if ArkForgeFlashOperation.contains(descriptor.reference) {
        throw RuntimeArtifactPublicationFailure(
          detail: "Artifact store is required for \(descriptor.reference)")
      }
      return
    }
    let binding = RuntimeArtifactService.bindingSnapshot(for: runtime.record)

    // Backstop: every declared product that never reached the index gets
    // recorded as missing here, whichever step should have produced it.
    // Relying on the step->artifact map alone would let a product vanish
    // silently when an upstream step is the one that failed.
    var recorded: [RuntimeArtifactMetadata]
    do {
      recorded = try await artifactStore.list(jobID: jobID)
    } catch {
      throw RuntimeArtifactPublicationFailure(
        detail: "cannot inspect Artifact index during finalization: \(error)")
    }
    for declaration in descriptor.artifacts
    where !names.contains(declaration.name)
      && !recorded.contains(where: { $0.name == declaration.name })
    {
      do {
        _ = try await artifactStore.recordMissing(
          jobID: jobID, sessionID: runtime.record.sessionID, stepID: "finalize-session",
          name: declaration.name, mediaType: declaration.mediaType,
          privacy: declaration.privacy, retentionClass: declaration.retentionClass,
          sourceOperation: descriptor.reference, providerID: descriptor.provider.rawValue,
          bindingSnapshot: binding,
          reason: "no step produced this declared artifact")
      } catch {
        throw RuntimeArtifactPublicationFailure(
          detail: "cannot record missing product \(declaration.name): \(error)")
      }
    }
    do {
      recorded = try await artifactStore.list(jobID: jobID)
    } catch {
      throw RuntimeArtifactPublicationFailure(
        detail: "cannot reopen Artifact index during finalization: \(error)")
    }

    let missingRequired = descriptor.artifacts.filter { declaration in
      guard declaration.isRequired, !names.contains(declaration.name) else { return false }
      return recorded.first { $0.name == declaration.name }?.status.isPublished != true
    }

    for name in names {
      guard let declaration = descriptor.artifacts.first(where: { $0.name == name }) else {
        continue
      }
      let contents: Data
      do {
        contents = try RuntimeArtifactService.finalArtifactContents(
          name: name, descriptor: descriptor, record: runtime.record,
          recorded: recorded, finalizeArtifactNames: names,
          completedStepIDs: runtime.completedStepIDs)
      } catch {
        throw RuntimeArtifactPublicationFailure(
          detail: "cannot encode final Artifact \(name): \(error)")
      }
      if descriptor.reference == "capture.diagnostics@1" {
        let budget: Int
        if case .integer(let requested)? =
          runtime.record.request.inputs["totalArtifactByteBudget"]
        {
          budget = Int(requested)
        } else {
          budget = 128 * 1024 * 1024
        }
        let current: [RuntimeArtifactMetadata]
        do {
          current = try await artifactStore.list(jobID: jobID)
        } catch {
          throw RuntimeArtifactPublicationFailure(
            detail: "cannot inspect final Artifact budget before \(name): \(error)")
        }
        let used = current.filter { $0.status.isPublished }
          .reduce(0) { $0 + $1.byteCount }
        guard used <= budget, contents.count <= budget - used else {
          throw RuntimeArtifactPublicationFailure(
            detail: "job byte budget \(budget) exceeded while finalizing \(name)")
        }
      }
      do {
        _ = try await artifactStore.publish(
          RuntimeArtifactPublicationRequest(
            jobID: jobID, sessionID: runtime.record.sessionID, stepID: "finalize-session",
            name: name, mediaType: declaration.mediaType, privacy: declaration.privacy,
            retentionClass: declaration.retentionClass, sourceOperation: descriptor.reference,
            providerID: descriptor.provider.rawValue, bindingSnapshot: binding,
            contents: contents))
      } catch {
        throw RuntimeArtifactPublicationFailure(
          detail: "cannot publish final Artifact \(name): \(error)")
      }
    }
    if !missingRequired.isEmpty {
      appendTimeline(
        jobID: jobID,
        entry: "incomplete: missing required \(missingRequired.map(\.name).sorted())")
      if ArkForgeFlashOperation.contains(descriptor.reference) {
        throw RuntimeArtifactPublicationFailure(
          detail: "required Flash artifacts are missing: "
            + missingRequired.map(\.name).sorted().joined(separator: ", "))
      }
    }
  }

  // MARK: Cancel / status / recovery

  public func requestCancel(jobID: String) throws {
    guard var runtime = jobs[jobID] else {
      // Absent from memory is not absent. A job whose outcome is known and
      // terminal is released from `jobs` and served from SQLite from then on,
      // so reading residency as existence makes the answer depend on how long
      // ago the job finished. Cancelling a terminal job is already a silent
      // no-op while it is still resident; answering `notFound` for the same
      // job once released contradicts `job.status` on the same daemon and
      // tells the caller its effects never happened. `reconcile` and `status`
      // both read through to the record, and now so does this. A job that is
      // genuinely absent still raises `jobNotFound`, from `recordForRead`.
      let record = try recordForRead(jobID: jobID)
      guard JobState(rawValue: record.state)?.isTerminal == true, !record.outcomeUnknown
      else {
        // Exactly the condition the two eviction sites require, so anything
        // else means a live job went missing from memory while restart
        // recovery is supposed to reload every active one. Nothing would
        // carry out a cancellation for it, so say so instead of returning a
        // success the caller cannot rely on.
        throw RuntimeJobEngineError.internalFailure(
          "job \(jobID) is \(record.state) but is not resident, so its cancellation "
            + "cannot be carried out")
      }
      return
    }

    guard let currentState = JobState(rawValue: runtime.record.state),
      !currentState.isTerminal,
      currentState != .finalizing
    else {
      return
    }
    // The verified Analyzer receipt and the Runtime-owned publication form
    // one success commit. Once that point is crossed, a later request cannot
    // rewrite the Job as cancelled while the exact Artifact is committed.
    if activeDispatches[jobID]?.cancellationMode == .analyzerCommitLinearized {
      return
    }

    // A submitted Job has no provider intent and no external effect yet. It
    // therefore has no executing run() task that could ever consume an
    // in-memory cancellation request. Complete this zero-dispatch decision
    // durably now; otherwise an abandoned App submission remains `preflight`
    // forever and every daemon restart replays it as an active clean journal.
    if runtime.record.state == JobState.preflight.rawValue {
      try transition(
        &runtime, from: .preflight, to: .cancelRequested,
        reason: "client-cancel before execution")
      try transition(
        &runtime, from: .cancelRequested, to: .cancellingAtSafeBoundary,
        reason: "no provider intent was dispatched")
      try transition(
        &runtime, from: .cancellingAtSafeBoundary, to: .cancelled,
        reason: "never-started job closed with zero dispatch")
      runtime.record.operationFailure = RuntimeOperationFailure(
        code: .cancelled, category: .cancelled,
        retryability: .notAutomatic, recovery: .none)
      runtime.record.finishedAtUTC = nowUTC()
      try persistRuntimeRecord(runtime.record)
      jobs[jobID] = runtime
      // Capability consumption happens only immediately before the first
      // mutation. A preflight cancellation therefore has no lineage use to
      // settle and must not spend or fabricate one.
      if let provider = providers.provider(id: runtime.record.providerID) {
        _ = statusAndReleaseTerminalRuntime(runtime.record, provider: provider)
      } else {
        _ = statusAndReleaseTerminalRuntime(runtime.record)
      }
      return
    }

    // An executing Job observes this request at its next Catalog-declared
    // safe boundary. Unknown/outstanding-effect states are never rewritten
    // into a certain terminal outcome merely because a client asked to stop.
    cancellationRequests.insert(jobID)
    if let state = JobState(rawValue: runtime.record.state),
      state != .cancelRequested,
      state != .cancellingAtSafeBoundary,
      !state.isTerminal,
      JobStateMachine.isAllowedTransition(from: state, to: .cancelRequested, mode: .execute)
    {
      try transition(
        &runtime, from: state, to: .cancelRequested,
        reason: "durable client cancellation intent")
      try persistRuntimeRecord(runtime.record)
      jobs[jobID] = runtime
    }
    if activeDispatches[jobID]?.cancellationMode == .immediateAnalyzerOpen {
      activeDispatches[jobID]?.task.cancel()
    }
  }

  /// Bounded metadata projection of the retained WAL. Looking up the exact
  /// record first preserves resourceNotFound after whole-Job reclamation.
  package func eventPage(jobID: String, afterCursor: String?, pageSize: Int) throws -> JSONValue {
    let record = try recordForRead(jobID: jobID)
    return try JournalEventPages.page(
      directory: jobDirectory(for: record.jobID), jobID: record.jobID,
      sessionID: record.sessionID, afterCursor: afterCursor, pageSize: pageSize)
  }

  /// Stable read resource; the exact record and its status share one capture
  /// after async recovery-index discovery. No provider or Job driver is called.
  package func jobReadSnapshot(jobID: String) async throws -> (record: RuntimeJobRecord, status: RuntimeJobStatus) {
    let indexes = await recoveryEpochIndexes()
    let record: RuntimeJobRecord
    if let current = jobs[jobID]?.record { record = current }
    else {
      guard let persisted = try admissionService.boundedJob(jobID: jobID) else { throw RuntimeJobEngineError.jobNotFound(jobID) }
      record = try decodePersistedRecord(persisted)
      guard record.state == persisted.state, record.createdAtUTC == persisted.createdAtUTC,
        record.request.idempotencyKey == persisted.idempotencyKey, persisted.version > 0
      else { throw RuntimeJobEngineError.jobRecordUnreadable(jobID) }
    }
    return (record, status(of: record,
      supersededByRecoveryEpochID: indexes.supersededByJobID[jobID],
      recoveryEpochID: indexes.establishedByJobID[jobID],
      resolvedByTargetAliasResolutionID: indexes.resolvedAliasByJobID[jobID]))
  }

  package func jobListSnapshot(_ query: RuntimeJobListQuery) async throws -> JSONValue {
    let pager = try RuntimeSnapshotPager(directory: configuration.stateDirectory.appending(path: "cli-job-snapshots"))
    // A continuation reads only its original projection, never today's Jobs.
    if query.cursor != nil {
      return try pager.page(method: "job.list", filters: query.filters, order: query.order,
        pageSize: query.pageSize, cursor: query.cursor, items: { [] })
    }
    let indexes = await recoveryEpochIndexes()
    return try pager.page(method: "job.list", filters: query.filters, order: query.order,
      pageSize: query.pageSize, cursor: nil) {
      var captured: [(date: Date, id: String, value: JSONValue)] = []
      var seen: Set<String> = []
      var size = 0
      func append(_ record: RuntimeJobRecord) throws {
        guard let created = ISO8601Timestamps.parse(record.createdAtUTC) else {
          throw RuntimeJobEngineError.jobRecordUnreadable(record.jobID)
        }
        let value = status(of: record,
          supersededByRecoveryEpochID: indexes.supersededByJobID[record.jobID],
          recoveryEpochID: indexes.establishedByJobID[record.jobID],
          resolvedByTargetAliasResolutionID: indexes.resolvedAliasByJobID[record.jobID])
        guard query.matches(value) else { return }
        guard seen.insert(record.jobID).inserted else { throw RuntimeJobEngineError.jobRecordUnreadable(record.jobID) }
        let projection = try RuntimeJobReadProjection.history(value, current: Self.isCurrentJob(value), includeTimeline: query.includeTimeline)
        size += try PortableCanonicalJSON.canonicalBytes(projection).count
        guard size <= 16 * 1024 * 1024 else {
          throw AgentExecutionControlFailure("operationUnavailable", "Job snapshot exceeds its storage bound; narrow the query")
        }
        captured.append((created, record.jobID, projection))
      }
      try admissionService.forEachJob { persisted in
        let durable = try decodePersistedRecord(persisted)
        guard durable.state == persisted.state, durable.createdAtUTC == persisted.createdAtUTC,
          durable.request.idempotencyKey == persisted.idempotencyKey, persisted.version > 0
        else { throw RuntimeJobEngineError.jobRecordUnreadable(persisted.jobID) }
        // The default is durable history, including nonterminal records.
        // includeCurrent overlays the Runtime's current in-memory snapshots,
        // including live progress/timeline not yet in the durable projection.
        try append(query.includeCurrent ? jobs[persisted.jobID]?.record ?? durable : durable)
      }
      if query.includeCurrent {
        for current in jobs.values where !seen.contains(current.record.jobID) { try append(current.record) }
      }
      captured.sort {
        if $0.date != $1.date { return query.order == "createdAtDescJobIdAsc" ? $0.date > $1.date : $0.date < $1.date }
        return $0.id.utf8.lexicographicallyPrecedes($1.id.utf8)
      }
      return captured.map(\.value)
    }
  }

  package func jobTimelineSnapshot(jobID: String, pageSize: Int, cursor: String?) async throws -> JSONValue {
    let pager = try RuntimeSnapshotPager(directory: configuration.stateDirectory.appending(path: "cli-job-snapshots"))
    let filters: [String: JSONValue] = ["jobId": .string(jobID)]
    if cursor != nil {
      // Still require a retained Job; its explicit removal cannot be hidden
      // by a leftover presentation snapshot.
      _ = try await jobReadSnapshot(jobID: jobID)
      return try pager.page(method: "job.timeline", filters: filters, order: "entryIndexAscPartIndexAsc",
        pageSize: pageSize, cursor: cursor, items: { [] })
    }
    let snapshot = try await jobReadSnapshot(jobID: jobID)
    return try pager.page(method: "job.timeline", filters: filters, order: "entryIndexAscPartIndexAsc",
      pageSize: pageSize, cursor: nil) {
      RuntimeJobReadProjection.timelineRows(snapshot.record.timeline)
    }
  }

  public func status(jobID: String) async throws -> RuntimeJobStatus {
    let record = try recordForRead(jobID: jobID)
    let indexes = await recoveryEpochIndexes()
    return status(
      of: record,
      supersededByRecoveryEpochID: indexes.supersededByJobID[record.jobID],
      recoveryEpochID: indexes.establishedByJobID[record.jobID],
      resolvedByTargetAliasResolutionID: indexes.resolvedAliasByJobID[record.jobID])
  }

  /// Classifies one debug attempt from the Job plus the exact durable
  /// RuntimeCapability lineage node. A failed Job is not assumed retryable:
  /// only the provider's confirmed-not-executed outcome opens the next
  /// ordinary destructive epoch.
  public func runtimeDebugExecutionOutcome(
    jobID: String
  ) async throws -> RuntimeDebugExecutionOutcome {
    let record = try recordForRead(jobID: jobID)
    if record.state == JobState.succeeded.rawValue
      || record.state == JobState.recovered.rawValue
    {
      return .succeeded
    }
    if record.outcomeUnknown || record.state == JobState.waitingForRecovery.rawValue {
      return .outcomeUnknown
    }
    if record.state == JobState.failed.rawValue {
      let replay = try DurableJournalRecovery.inspect(
        url: jobDirectory(for: jobID).appending(path: "journal.jsonl"))
      let intents = replay.events.filter { $0.kind == .stepIntent }
      if intents.allSatisfy({ $0.stepEffect != nil })
        && !intents.contains(where: { $0.stepEffect! >= .deviceMutation })
      {
        // Typed-only execution and intent-before-effect make this a general
        // proof, independent of the failure reason: no device effect could
        // have been dispatched. A materially different candidate may stay in
        // the same invocation instead of opening a PR for the new reason.
        return .safeToReflash
      }
    }
    guard let capabilityID = record.admissionEvidence?.reference,
      let capability = try await capabilityStore.inspect(capabilityID: capabilityID),
      let use = capability.lineage.last(where: { $0.jobID == jobID })
    else {
      return .failedKnown
    }
    switch use.outcome {
    case .safeToReflash: return .safeToReflash
    case .outcomeUnknown, .pending: return .outcomeUnknown
    case .confirmed: return .failedKnown
    }
  }

  public func evidenceSnapshot(jobID: String) async throws -> RuntimeJobEvidenceSnapshot {
    let record = try recordForRead(jobID: jobID)
    let epochs = try await RuntimeSupersedingRecoveryStore(
      stateDirectory: configuration.stateDirectory
    ).list()
    let recoveryEpoch = epochs.last(where: { $0.recoveryJobID == record.jobID })
    let observation =
      record.evidenceObservation
      ?? RockchipRuntimeActionRecordStore(
        rootURL: configuration.stateDirectory.appending(
          path:
            "rockchip-runtime", directoryHint: .isDirectory)
      ).flashPostflightObservation(for: record)
    let actualStepKinds = try durableActualStepKinds(for: record)
    return RuntimeJobEvidenceSnapshot(
      jobID: record.jobID,
      operationReference: record.operationReference,
      catalogDigest: record.catalogDigest,
      targetID: record.request.target.targetID,
      bindingRevision: record.request.target.expectedBindingRevision,
      providerID: record.providerID,
      actualEffect: record.actualEffect,
      authority: record.admissionEvidence,
      observation: observation,
      actualStepKinds: actualStepKinds,
      executionMode: "execute",
      terminalState: record.outcomeUnknown ? "outcomeUnknown" : record.state,
      outcomeUnknown: record.outcomeUnknown,
      startedAtUTC: record.startedAtUTC,
      firstEvidenceStepAtUTC: record.firstEvidenceStepAtUTC,
      finishedAtUTC: record.finishedAtUTC,
      recoveryEpoch: recoveryEpoch,
      traceProbeBefore: record.traceProbeBefore,
      traceProbeAfter: record.traceProbeAfter,
      inputs: record.request.inputs)
  }

  /// ArkForge owns one native plan while ArkDeck retains one confirmed WAL
  /// pair for every published Flash obligation that the terminal daemon
  /// receipt closes. Older records therefore contain only the separately
  /// dispatched diagnostics kind in `actualStepKinds`, even though their
  /// journal durably proves the destructive write and required postflight.
  ///
  /// Reopening evidence must project those already-confirmed journal steps;
  /// it must never mutate the record or ask the provider to run again. Scope
  /// this compatibility projection to the reviewed ArkForge operation so an
  /// unrelated historical Job cannot acquire step claims from catalog text.
  private func durableActualStepKinds(for record: RuntimeJobRecord) throws -> [String] {
    let storedKinds = record.actualStepKinds ?? []
    guard ArkForgeFlashOperation.contains(record.operationReference) else {
      return storedKinds
    }
    guard let descriptor = RuntimeOperationCatalog.descriptor(
      reference: record.operationReference)
    else {
      throw RuntimeJobEngineError.internalFailure(
        "persisted Flash operation \(record.operationReference) is unavailable")
    }
    let replay = try DurableJournalRecovery.inspect(
      url: jobDirectory(for: record.jobID).appending(path: "journal.jsonl"))
    guard replay.outstandingIntents.isEmpty, replay.unknownOutcomes.isEmpty else {
      throw RuntimeJobEngineError.internalFailure(
        "persisted Flash journal is not closed for \(record.jobID)")
    }
    let confirmedStepIDs = Self.confirmedSucceededStepIDs(in: replay)
    let provenKinds = Set(storedKinds).union(
      descriptor.steps.compactMap { step in
        confirmedStepIDs.contains(step.stepID) ? step.kind.rawValue : nil
      })

    var ordered: [String] = []
    for step in descriptor.steps where provenKinds.contains(step.kind.rawValue) {
      if !ordered.contains(step.kind.rawValue) {
        ordered.append(step.kind.rawValue)
      }
    }
    for kind in storedKinds where !ordered.contains(kind) {
      ordered.append(kind)
    }
    return ordered
  }

  /// Artifact names omitted by the exact materialized request, including
  /// downstream optional products and unselected alternative encodings. This
  /// is derived from the persisted typed inputs, not from artifact status
  /// text, so an artifact that was selected but failed remains an evidence
  /// blocker.
  public func intentionallyOmittedArtifactNames(jobID: String) throws -> Set<String> {
    let record = try recordForRead(jobID: jobID)
    guard
      let descriptor = RuntimeOperationCatalog.descriptor(
        reference: record.operationReference)
    else {
      throw RuntimeJobEngineError.internalFailure(
        "persisted operation \(record.operationReference) is unavailable")
    }
    let inputs = record.request.inputs
    var omittedSteps: Set<String> = []
    for step in descriptor.steps where step.isOptional {
      if let upstream = Self.optionalStepUpstream[descriptor.reference]?[step.stepID],
        omittedSteps.contains(upstream)
      {
        omittedSteps.insert(step.stepID)
      } else if !Self.optionalStepIsSelected(step, descriptor: descriptor, inputs: inputs) {
        omittedSteps.insert(step.stepID)
      }
    }
    var omittedNames: Set<String> = []
    for step in descriptor.steps {
      let mapping = RuntimeArtifactService.artifacts(
        reference: descriptor.reference, stepID: step.stepID) ?? []
      if omittedSteps.contains(step.stepID) {
        omittedNames.formUnion(mapping)
      } else {
        // A PNG request owes one PNG, not both encodings. Use the same typed
        // selection as publication; an absent selected product still blocks.
        let selected = RuntimeArtifactService.publishableArtifacts(
          mapping: mapping, requestInputs: inputs)
        omittedNames.formUnion(Set(mapping).subtracting(selected))
      }
    }
    return omittedNames
  }

  /// Returns both active Runtime snapshots and durable terminal history.  The
  /// latter is projected from SQLite so callers keep the established `job.list`
  /// behaviour without forcing the daemon to retain a journal writer per
  /// completed job.
  public func listJobs() async throws -> [RuntimeJobStatus] {
    let indexes = await recoveryEpochIndexes()
    let statuses = try allJobStatuses(indexes: indexes)
    return statuses.values.sorted { $0.jobID < $1.jobID }
  }

  /// Returns the small current-work set that must never disappear behind a
  /// newest-first History page. This includes every non-terminal or unknown
  /// future state plus terminal Jobs whose unresolved outcome, human wait, or
  /// cleanup residue still needs operator visibility. A Runtime-established
  /// current epoch settles only the historical unknown/wait signal; it does
  /// not hide a still-active Job or outstanding cleanup residue.
  public func listCurrentJobs() async throws -> [RuntimeJobStatus] {
    let indexes = await recoveryEpochIndexes()
    let statuses = try allJobStatuses(indexes: indexes)
    return statuses.values.filter(Self.isCurrentJob).sorted { $0.jobID < $1.jobID }
  }

  /// Freezes the admission side of the host-wide HDC participant inventory.
  /// The flag is installed before the current-Job read because that read may
  /// suspend while deriving recovery indexes. A submit that was already
  /// materializing must pass the same flag again immediately before durable
  /// admission, closing both sides of the actor-reentrancy window.
  package func acquireHDCLifecycleInterlock() async throws
    -> RuntimeHDCLifecycleInterlockLease
  {
    guard hdcLifecycleInterlockID == nil else {
      throw AgentExecutionControlFailure(
        "resourceConflict", "another HDC lifecycle action owns the final Job interlock")
    }
    let lease = RuntimeHDCLifecycleInterlockLease(id: UUID())
    hdcLifecycleInterlockID = lease.id
    do {
      let current = try await listCurrentJobs()
      guard hdcLifecycleInterlockID == lease.id, current.isEmpty else {
        if hdcLifecycleInterlockID == lease.id { hdcLifecycleInterlockID = nil }
        throw AgentExecutionControlFailure(
          "factsDrifted", "current Runtime Jobs block the HDC lifecycle action")
      }
      return lease
    } catch {
      if hdcLifecycleInterlockID == lease.id { hdcLifecycleInterlockID = nil }
      throw error
    }
  }

  package func releaseHDCLifecycleInterlock(
    _ lease: RuntimeHDCLifecycleInterlockLease
  ) throws {
    guard hdcLifecycleInterlockID == lease.id else {
      throw AgentExecutionControlFailure(
        "resourceConflict", "HDC lifecycle interlock ownership changed")
    }
    hdcLifecycleInterlockID = nil
  }

  private func allJobStatuses(
    indexes: RecoveryEpochIndexes
  ) throws -> [String: RuntimeJobStatus] {
    var statuses: [String: RuntimeJobStatus] = [:]
    let persisted: [RuntimePersistedJob]
    do {
      persisted = try admissionService.allJobs()
    } catch {
      throw RuntimeJobEngineError.internalFailure(
        "Runtime job history index is unreadable: \(error)")
    }
    for row in persisted {
      let record = try decodePersistedRecord(row)
      statuses[record.jobID] = status(
        of: record,
        supersededByRecoveryEpochID: indexes.supersededByJobID[record.jobID],
        recoveryEpochID: indexes.establishedByJobID[record.jobID],
        resolvedByTargetAliasResolutionID: indexes.resolvedAliasByJobID[record.jobID])
    }
    // Active snapshots can contain timeline entries accumulated since their
    // last durable projection; they take precedence over the history index.
    for runtime in jobs.values {
      statuses[runtime.record.jobID] = status(
        of: runtime.record,
        supersededByRecoveryEpochID: indexes.supersededByJobID[runtime.record.jobID],
        recoveryEpochID: indexes.establishedByJobID[runtime.record.jobID],
        resolvedByTargetAliasResolutionID: indexes.resolvedAliasByJobID[
          runtime.record.jobID])
    }
    return statuses
  }

  private static func isCurrentJob(_ status: RuntimeJobStatus) -> Bool {
    if (status.outstandingResidueCount ?? 0) > 0 { return true }
    let hasEstablishedCurrentEpoch =
      status.supersededByRecoveryEpochID != nil
      || status.resolvedByTargetAliasResolutionID != nil
    if !hasEstablishedCurrentEpoch && (status.outcomeUnknown || status.waitingForHuman) {
      return true
    }
    guard let state = JobState(rawValue: status.state) else { return true }
    return !state.isTerminal
  }

  /// Session retention treats every nonterminal or outcome-unknown Runtime
  /// Job as an active lease. The Session identifier is returned without any
  /// filesystem path and is re-read for both preview and apply.
  package func activeSessionIDsForRetention() -> Set<String> {
    Set(jobs.values.compactMap { runtime in
      let record = runtime.record
      if record.outcomeUnknown { return record.sessionID }
      guard let state = JobState(rawValue: record.state), state.isTerminal else {
        return record.sessionID
      }
      return nil
    })
  }

  /// Reads one compact history page from SQLite. Current work that may sit
  /// outside this page is exposed separately by `listCurrentJobs()`; both
  /// views use the same typed status model and opaque cursor contract.
  public func listJobs(
    pageSize: Int, cursor: String? = nil, newestFirst: Bool = false
  ) async throws -> RuntimeJobStatusPage {
    let indexes = await recoveryEpochIndexes()
    let page = try admissionService.listJobs(
      pageSize: pageSize, cursor: cursor, newestFirst: newestFirst)
    let statuses = try page.jobs.map { persisted -> RuntimeJobStatus in
      let record = try decodePersistedRecord(persisted)
      return status(
        of: record,
        supersededByRecoveryEpochID: indexes.supersededByJobID[record.jobID],
        recoveryEpochID: indexes.establishedByJobID[record.jobID],
        resolvedByTargetAliasResolutionID: indexes.resolvedAliasByJobID[record.jobID])
    }
    return RuntimeJobStatusPage(jobs: statuses, nextCursor: page.nextCursor)
  }

  /// Returns the latest verified `observe.device@1` facts per target without
  /// constructing full History status or artifact projections. The App's
  /// startup device projection needs only these compact, durable facts; using
  /// the evidence endpoint for every row would add separate XPC round trips
  /// and artifact verification to the cold-start path.
  public func latestSucceededDeviceObservations(
    pageSize: Int = 250
  ) throws -> [String: RuntimeEvidenceObservation] {
    let usesStartupCache = pageSize == 250
    if usesStartupCache, let latestSucceededDeviceObservationCache {
      return latestSucceededDeviceObservationCache
    }
    let page = try admissionService.listJobs(
      pageSize: pageSize, cursor: nil, newestFirst: true)
    var observations: [String: RuntimeEvidenceObservation] = [:]
    for persisted in page.jobs {
      let record = try decodePersistedRecord(persisted)
      let targetID = record.request.target.targetID
      guard observations[targetID] == nil,
        record.operationReference == "observe.device@1",
        record.state == JobState.succeeded.rawValue,
        !record.outcomeUnknown,
        let observation = record.evidenceObservation,
        observation.targetID == targetID
      else { continue }
      observations[targetID] = observation
    }
    if usesStartupCache {
      latestSucceededDeviceObservationCache = observations
    }
    return observations
  }

  private func updateLatestSucceededDeviceObservationCache(
    from record: RuntimeJobRecord
  ) {
    guard var cache = latestSucceededDeviceObservationCache,
      record.operationReference == "observe.device@1",
      record.state == JobState.succeeded.rawValue,
      !record.outcomeUnknown,
      let observation = record.evidenceObservation,
      let targetID = observation.targetID,
      targetID == record.request.target.targetID
    else { return }
    cache[targetID] = observation
    latestSucceededDeviceObservationCache = cache
  }

  public func listCleanupDebt() async throws -> [CleanupDebtRecord] {
    guard let artifactStore else {
      throw RuntimeJobEngineError.internalFailure("Artifact store is not configured")
    }
    return try await artifactStore.outstandingCleanupDebt()
      .sorted {
        ($0.jobID, $0.remotePath, $0.recordedAtUTC)
          < ($1.jobID, $1.remotePath, $1.recordedAtUTC)
      }
  }

  /// Explicitly continues one cleanup debt. The debt ledger is the WAL for
  /// this bounded retry. If the retry becomes unobservable, later calls may
  /// only run the read-only path judgement and must never resend cleanup.
  ///
  /// The debt outlives the Job that recorded it. A Job goes terminal, its
  /// runtime is released (`statusAndReleaseTerminalRuntime`), and the daemon
  /// launches with `recoverActiveJobs()` — so the residue's own Job is exactly
  /// the one not resident. This is the only route to `settleCleanupDebt`, so
  /// requiring residency meant a finished Job's residue could never be
  /// settled: listed forever, and the owned remote path left on the device.
  /// One durable record is loaded on demand for that case and released again
  /// below; that is a single replay for an operator-initiated call, not the
  /// launch-time cost `recoverActiveJobs()` exists to avoid.
  public func continueCleanupDebt(
    jobID: String, identity: String
  ) async throws -> RuntimeCleanupDebtContinuation {
    guard let artifactStore else {
      throw RuntimeJobEngineError.internalFailure("Artifact store is not configured")
    }
    guard
      let debt = try await artifactStore.outstandingCleanupDebt().first(where: {
        $0.jobID == jobID && $0.identity == identity
      })
    else {
      throw RuntimeJobEngineError.jobNotFound("cleanup-debt:\(jobID):\(identity)")
    }
    var loadedForThisCall = false
    if jobs[jobID] == nil, let persistedJob = try admissionService.job(jobID: jobID) {
      _ = try await recover(records: [persistedJob])
      loadedForThisCall = jobs[jobID] != nil
    }
    defer {
      // Put the memory posture back exactly as it was found. Terminal history
      // stays a SQLite query.
      if loadedForThisCall, let loaded = jobs[jobID], !loaded.record.outcomeUnknown,
        JobState(rawValue: loaded.record.state)?.isTerminal == true
      {
        jobs.removeValue(forKey: jobID)
      }
    }
    guard let runtime = jobs[jobID] else {
      throw RuntimeJobEngineError.jobNotFound(jobID)
    }
    guard !runtime.record.outcomeUnknown else {
      return RuntimeCleanupDebtContinuation(
        jobID: jobID, identity: identity, state: .outcomeUnknown,
        detail: "job has an unresolved outcome; cleanup mutation is not resent")
    }
    guard let persisted = debt.persistedAction else {
      throw RuntimeJobEngineError.internalFailure(
        "cleanup debt has no persisted exact typed action")
    }
    let action = try persisted.materialize()
    guard Self.cleanupResidue(for: action)?.identity == identity
    else {
      throw RuntimeJobEngineError.internalFailure(
        "cleanup debt action does not match its recorded residue")
    }
    guard let provider = providers.provider(id: runtime.record.providerID) else {
      throw RuntimeJobEngineError.internalFailure(
        "provider \(runtime.record.providerID) is unavailable")
    }
    let facts = try await providers.resolveFacts(
      providerID: runtime.record.providerID,
      targetID: runtime.record.request.target.targetID)
    try Self.validateEvidenceFacts(
      facts,
      targetID: runtime.record.request.target.targetID,
      bindingRevision: runtime.record.request.target.expectedBindingRevision,
      providerID: runtime.record.providerID)
    let context = ProviderExecutionContext(
      jobID: jobID, stepID: debt.stepID,
      targetID: runtime.record.request.target.targetID,
      bindingRevision: runtime.record.request.target.expectedBindingRevision,
      connectKey: facts.executionConnectKey,
      expectedIdentitySHA256: facts.deviceIdentitySHA256,
      toolVersion: facts.toolVersion,
      toolSHA256: facts.toolSHA256,
      serverFacts: facts.serverFacts,
      nowUTC: nowUTC())
    let reference = ProviderDurableIntentReference(
      jobID: jobID, stepID: debt.stepID,
      intentEventID: "cleanup-debt-\(debt.stepID)", action: action)

    guard
      let readback = try provider.reconciliationReadback(
        intent: reference, context: context),
      readback.action.effect <= .readOnly
    else {
      throw RuntimeJobEngineError.internalFailure(
        "cleanup debt has no dedicated read-only path judgement")
    }
    do {
      let receipt = try await dispatcher.dispatch(readback)
      switch try provider.verifyReconciliationReadback(
        receipt: receipt, intent: reference, context: context)
      {
      case .confirmedCompleted:
        try await artifactStore.settleCleanupDebt(jobID: jobID, identity: identity)
        await refreshResidueCount(jobID: jobID)
        return RuntimeCleanupDebtContinuation(
          jobID: jobID, identity: identity, state: .settled,
          detail: "readback confirmed the owned path is already absent")
      case .confirmedNotExecuted:
        break  // path still exists; an initial confirmed-failure debt may retry below
      case .stillUnknown(let reason):
        return RuntimeCleanupDebtContinuation(
          jobID: jobID, identity: identity, state: .outstanding,
          detail: "path readback inconclusive: \(reason)")
      }
    } catch {
      return RuntimeCleanupDebtContinuation(
        jobID: jobID, identity: identity, state: .outstanding,
        detail: "path readback failed: \(error)")
    }

    if debt.retryOutcomeUnknown == true || debt.retryAttemptStartedAtUTC != nil {
      return RuntimeCleanupDebtContinuation(
        jobID: jobID, identity: identity, state: .outcomeUnknown,
        detail: "earlier cleanup retry is outcomeUnknown; mutation resend is forbidden")
    }
    let plan = try provider.lower(action: action, context: context)
    guard plan.action == action, plan.action.effect == .deviceMutation else {
      throw RuntimeJobEngineError.internalFailure(
        "cleanup debt did not lower to its exact typed mutation")
    }
    // A device mutation, and it used to reach the transport with no authority
    // check of any kind — this whole function named `capability` nowhere.
    //
    // The residue belongs to a Job that already consumed a capability for this
    // exact target and plan, so this is the "this Job already owns that use"
    // path (`persistedEvidence`): no second capability is consumed, and the
    // gate re-proves what may have drifted since — the persisted evidence
    // still matches the Job's authorization, the plan still materializes to
    // the same digest, and fresh facts still put the same device on the same
    // binding. A Job that never held a runtime capability fails closed here.
    guard
      let descriptor = RuntimeOperationCatalog.descriptor(
        reference: runtime.record.request.operation.reference)
    else {
      throw RuntimeJobEngineError.internalFailure(
        "catalog operation vanished for \(jobID)")
    }
    try await consumeCapabilityBeforeMutation(
      jobID: jobID, descriptor: descriptor, effect: .deviceMutation,
      validatedFacts: facts)
    // Only now is the retry durable. Ordered after the gate on purpose: the
    // ledger refuses a second attempt once `retryAttemptStartedAtUTC` is set,
    // so opening it before an authority refusal would spend the one retry on a
    // dispatch that never happened.
    _ = try await artifactStore.beginCleanupDebtRetry(
      jobID: jobID, identity: identity)
    do {
      let receipt = try await dispatcher.dispatch(plan)
      switch try provider.verify(receipt: receipt, action: action, context: context) {
      case .verified:
        try await artifactStore.settleCleanupDebt(jobID: jobID, identity: identity)
        await refreshResidueCount(jobID: jobID)
        return RuntimeCleanupDebtContinuation(
          jobID: jobID, identity: identity, state: .settled,
          detail: "exact typed cleanup completed")
      case .failed(let code, let detail):
        try await artifactStore.completeCleanupDebtRetry(
          jobID: jobID, identity: identity, outcomeUnknown: false)
        return RuntimeCleanupDebtContinuation(
          jobID: jobID, identity: identity, state: .outstanding,
          detail: "\(code): \(detail)")
      case .unknown(let reason), .unsupported(let reason):
        try await artifactStore.completeCleanupDebtRetry(
          jobID: jobID, identity: identity, outcomeUnknown: true)
        return RuntimeCleanupDebtContinuation(
          jobID: jobID, identity: identity, state: .outcomeUnknown,
          detail: "\(reason); mutation resend is forbidden")
      }
    } catch let failure as RuntimeDispatchFailure {
      let unknown: Bool
      if case .outcomeUnknown = failure { unknown = true } else { unknown = false }
      try await artifactStore.completeCleanupDebtRetry(
        jobID: jobID, identity: identity, outcomeUnknown: unknown)
      return RuntimeCleanupDebtContinuation(
        jobID: jobID, identity: identity,
        state: unknown ? .outcomeUnknown : .outstanding,
        detail: "\(failure)")
    }
  }

  /// Explicit full recovery for diagnostics and migration.  Production
  /// daemon launch uses `recoverActiveJobs()` so terminal history remains a
  /// SQLite query instead of thousands of journal replays.
  public func recoverPersistedJobs() async throws -> [RuntimeJobStatus] {
    try await recover(records: try admissionService.allJobs())
  }

  /// Restart recovery for the daemon hot path.  Only non-terminal jobs can
  /// need a recovery decision, therefore terminal rows are not reopened,
  /// parsed, or retained in `jobs`.  `status` and `listJobs(pageSize:cursor:)`
  /// continue to project those records directly from SQLite.
  public func recoverActiveJobs() async throws -> [RuntimeJobStatus] {
    try await recover(records: try admissionService.activeJobs())
  }

  /// Reopen the supplied authoritative job set, replay each journal and park
  /// unknowns. Clean journals retain their exact confirmed provider boundary
  /// and can be resumed explicitly. Recovery itself never dispatches.
  private func recover(records persistedJobs: [RuntimePersistedJob]) async throws
    -> [RuntimeJobStatus]
  {
    let recoveryService = RuntimeRecoveryService(
      stateDirectory: configuration.stateDirectory, nowUTC: nowUTC)
    for persisted in persistedJobs {
      try recoveryService.restoreInitialAdmissionProjectionIfNeeded(persisted)
    }
    var recovered: [RuntimeJobStatus] = []
    for persisted in persistedJobs {
      if jobs[persisted.jobID] != nil { continue }
      let replayed = try await recoveryService.replay(persisted)
      let arkForgeState = try ArkForgeRuntimeJobState.load(
        from: jobDirectory(for: persisted.jobID))
      try persistRuntimeRecord(replayed.record)
      recovered.append(status(of: replayed.record))
      jobs[persisted.jobID] = JobRuntime(
        record: replayed.record, journal: replayed.journal,
        nextSequence: replayed.nextSequence,
        arkForgeState: arkForgeState,
        completedStepIDs: replayed.completedStepIDs)
      if replayed.record.outcomeUnknown {
        try await recordCapabilityOutcome(
          for: replayed.record, outcome: .outcomeUnknown,
          state: JobState.waitingForRecovery.rawValue)
      } else if JobState(rawValue: replayed.record.state)?.isTerminal == true {
        try await recordCapabilityOutcome(
          for: replayed.record, outcome: .confirmed, state: replayed.record.state)
      }
    }
    return recovered
  }

  /// Returns the one unresolved DAYU200 enter-Loader intent that a fresh,
  /// user-selected Loader binding may close. This performs no write and is
  /// intentionally stricter than ordinary reconciliation: an explicit
  /// outcomeUnknown row, a torn journal, a destructive intent or more than
  /// one candidate can never be converted into a confirmed transition.
  public func loaderTransitionAwaitingBinding(
    targetID: String,
    expectedBindingRevision: Int
  ) throws -> String? {
    let candidates = jobs.values.filter { runtime in
      Self.isDayu200Flash(runtime.record)
        && runtime.record.request.target.targetID == targetID
        && runtime.record.request.target.expectedBindingRevision == expectedBindingRevision
        && runtime.record.state == JobState.waitingForRecovery.rawValue
        && runtime.record.outcomeUnknown
        && runtime.record.recoveryStepID == "enter-loader-mode"
        && runtime.record.recoveryIntentEventID != nil
    }
    guard candidates.count <= 1 else {
      throw RuntimeJobEngineError.jobNotRunnable(
        "multiple unresolved Loader transitions cover target \(targetID)")
    }
    guard let candidate = candidates.first else { return nil }
    _ = try pendingLoaderTransition(
      jobID: candidate.record.jobID,
      targetID: targetID,
      expectedBindingRevision: expectedBindingRevision)
    return candidate.record.jobID
  }

  /// Closes only an outstanding enter-Loader intent after Runtime has
  /// durably advanced the selected target from the old HDC personality to a
  /// freshly observed, unique Loader personality. The old Job never resumes:
  /// it becomes a certain failed Job at a confirmed safe boundary, forcing a
  /// newly materialized plan against the new binding revision.
  public func settleLoaderTransitionAfterBinding(
    jobID: String,
    targetID: String,
    previousBindingRevision: Int,
    currentBindingRevision: Int,
    selectionEvidenceSHA256: String
  ) async throws -> RuntimeJobStatus {
    guard
      currentBindingRevision == previousBindingRevision
        || currentBindingRevision == previousBindingRevision + 1,
      Self.isLowercaseSHA256(selectionEvidenceSHA256)
    else {
      throw RuntimeJobEngineError.jobNotRunnable(
        "Loader binding settlement requires the selected or one adjacent revision and canonical evidence"
      )
    }
    guard var runtime = jobs[jobID] else {
      throw RuntimeJobEngineError.jobNotFound(jobID)
    }
    let pending = try pendingLoaderTransition(
      jobID: jobID,
      targetID: targetID,
      expectedBindingRevision: previousBindingRevision)
    let attemptID = "loader-binding-\(jobID)-\(runtime.nextSequence)"
    try transition(
      &runtime,
      from: .waitingForRecovery,
      to: .reconciling,
      reason: "begin Runtime Loader binding settlement")
    try runtime.journal.appendAndSynchronize(
      JournalEvent.reconcileStarted(
        eventID: "reconcile-start-\(runtime.nextSequence)",
        sequence: runtime.nextSequence,
        sessionID: runtime.record.sessionID,
        jobID: jobID,
        timestamp: nowUTC(),
        recoveryAttemptID: attemptID,
        sourceState: .waitingForRecovery,
        lastDurableSequence: pending.inspection.lastDurableSequence ?? 0,
        trigger: "deviceReturned",
        schemaVersion: Self.journalSchemaVersion(of: runtime.record)))
    runtime.nextSequence += 1
    try runtime.journal.appendAndSynchronize(
      JournalEvent.stepOutcome(
        eventID: "loader-binding-outcome-\(runtime.nextSequence)",
        sequence: runtime.nextSequence,
        sessionID: runtime.record.sessionID,
        jobID: jobID,
        timestamp: nowUTC(),
        stepID: pending.intent.stepID,
        attempt: pending.intent.attempt,
        correlatesToIntentEventID: pending.intent.eventID,
        result: "succeeded",
        outcomeCertainty: .confirmed,
        summary: "unique Loader observed and bound to the selected Runtime target",
        schemaVersion: Self.journalSchemaVersion(of: runtime.record),
        authorizationRef: pending.intent.authorizationReference,
        agentAuthorizationRef: pending.intent.agentExecutionAuthorityReference,
        usageReservationID: pending.intent.usageReservationID))
    runtime.nextSequence += 1
    let reconcileOutcome = try JournalEvent.reconcileOutcome(
      eventID: "reconcile-outcome-\(runtime.nextSequence)",
      sequence: runtime.nextSequence,
      sessionID: runtime.record.sessionID,
      jobID: jobID,
      timestamp: nowUTC(),
      bindingRevision: currentBindingRevision,
      recoveryAttemptID: attemptID,
      result: "finalizeConfirmedFailure",
      nextState: .finalizing,
      outcomeCertainty: .confirmed,
      safeBoundaryConfirmed: true,
      evidence: [
        "runtime-loader-binding-sha256=\(selectionEvidenceSHA256)",
        "binding-revision=\(previousBindingRevision)->\(currentBindingRevision)",
      ],
      schemaVersion: Self.journalSchemaVersion(of: runtime.record))
    try runtime.journal.appendAndSynchronize(reconcileOutcome)
    runtime.nextSequence += 1
    try transition(
      &runtime,
      from: .reconciling,
      to: .finalizing,
      reason: "Loader transition confirmed; binding changed; fresh plan required",
      triggerEventID: reconcileOutcome.eventID)
    try transition(
      &runtime,
      from: .finalizing,
      to: .failed,
      reason: "old Flash Job closed at Loader boundary; fresh plan required")
    runtime.record.outcomeUnknown = false
    runtime.record.recoveryStepID = nil
    runtime.record.recoveryIntentEventID = nil
    runtime.record.recoveryAction = nil
    runtime.record.finishedAtUTC = nowUTC()
    runtime.record.timeline.append(
      "reconciled: Loader bound at revision \(currentBindingRevision); original action not replayed"
    )
    try persistRuntimeRecord(runtime.record)
    jobs[jobID] = runtime
    try await recordCapabilityOutcome(
      for: runtime.record,
      outcome: .confirmed,
      state: JobState.failed.rawValue)
    return statusAndReleaseTerminalRuntime(runtime.record)
  }

  private func pendingLoaderTransition(
    jobID: String,
    targetID: String,
    expectedBindingRevision: Int
  ) throws -> (intent: OutstandingJournalIntent, inspection: JournalReplay) {
    guard let runtime = jobs[jobID],
      Self.isDayu200Flash(runtime.record),
      runtime.record.request.target.targetID == targetID,
      runtime.record.request.target.expectedBindingRevision == expectedBindingRevision,
      runtime.record.state == JobState.waitingForRecovery.rawValue,
      runtime.record.outcomeUnknown,
      runtime.record.recoveryStepID == "enter-loader-mode",
      let recoveryIntentID = runtime.record.recoveryIntentEventID
    else {
      throw RuntimeJobEngineError.jobNotRunnable(
        "Job \(jobID) is not an unresolved enter-Loader transition for the selected target")
    }
    let inspection = try DurableJournalRecovery.inspect(
      url: jobDirectory(for: jobID).appending(path: "journal.jsonl"))
    guard !inspection.hasTornTail,
      inspection.currentState == .waitingForRecovery,
      inspection.unknownOutcomes.isEmpty,
      inspection.outstandingIntents.count == 1,
      let intent = inspection.outstandingIntents.first,
      intent.eventID == recoveryIntentID,
      intent.stepID == "enter-loader-mode",
      intent.attempt > 0,
      intent.effect == .deviceMutation,
      intent.bindingRevision == expectedBindingRevision,
      !inspection.events.contains(where: {
        $0.kind == .stepIntent && ($0.stepEffect ?? .hostOnly) >= .destructive
      })
    else {
      throw RuntimeJobEngineError.jobNotRunnable(
        "Loader transition journal is ambiguous, destructive or already outcomeUnknown")
    }
    return (intent, inspection)
  }

  public func reconcile(jobID: String) async throws -> RuntimeJobStatus {
    guard var runtime = jobs[jobID] else {
      let record = try recordForRead(jobID: jobID)
      try await repairTerminalSafeToReflashLineageIfNeeded(for: record)
      try await repairTerminalCancelledLineageIfNeeded(for: record)
      return status(of: record)
    }
    guard let provider = providers.provider(id: runtime.record.providerID) else {
      throw RuntimeJobEngineError.internalFailure("provider vanished for \(jobID)")
    }
    // A cancellation whose executor no longer exists is settled here.
    //
    // `requestCancel` on a running job records the intent and leaves the
    // running `run()` to carry it to a terminal at its next safe boundary.
    // That works while the executor is alive. It is not: a job recovered from
    // its journal after a daemon restart has a rebuilt in-memory runtime and
    // no task advancing it, so the intent is durable and nothing will ever act
    // on it. The job stays `cancelRequested` forever, and — because the
    // capability lineage was already consumed before the first mutation — it
    // holds that generation open, which refuses every later destructive job on
    // the same policy.
    //
    // Measured 2026-08-17 on job-a6e76b6af6f8198cdd7ae788609e104f: its
    // timeline reads `… wait-loader-reconnect ✓ / recovered: journal clean /
    // running->cancelRequested`, and repeated `reconcile` calls returned its
    // status unchanged because `outcomeUnknown` is false and the guard below
    // returns early.
    //
    // Settling needs no device work. `outcomeUnknown == false` is the engine's
    // own statement that nothing uncertain happened, and reconcile is an
    // operator asking for exactly this. A job whose outcome *is* unknown falls
    // through to the reconciliation below and is never closed this way,
    // because a write of unknown outcome must be reconciled against the
    // device, not declared cancelled.
    if !runtime.record.outcomeUnknown,
      let stuck = JobState(rawValue: runtime.record.state),
      stuck == .cancelRequested || stuck == .cancellingAtSafeBoundary
    {
      if stuck == .cancelRequested {
        try transition(
          &runtime, from: .cancelRequested, to: .cancellingAtSafeBoundary,
          reason: "cancellation executor did not survive; settling on reconcile")
      }
      try transition(
        &runtime, from: .cancellingAtSafeBoundary, to: .cancelled,
        reason: "no executor remains to carry the durable cancellation intent")
      runtime.record.operationFailure = RuntimeOperationFailure(
        code: .cancelled, category: .cancelled,
        retryability: .notAutomatic, recovery: .none)
      runtime.record.finishedAtUTC = nowUTC()
      try persistRuntimeRecord(runtime.record)
      jobs[jobID] = runtime
      try await repairTerminalSafeToReflashLineageIfNeeded(for: runtime.record)
      return statusAndReleaseTerminalRuntime(runtime.record, provider: provider)
    }
    guard runtime.record.outcomeUnknown else {
      try await repairTerminalSafeToReflashLineageIfNeeded(for: runtime.record)
      return statusAndReleaseTerminalRuntime(runtime.record, provider: provider)
    }
    let journalURL = jobDirectory(for: jobID).appending(path: "journal.jsonl")
    var inspection = try DurableJournalRecovery.inspect(url: journalURL)

    // Finish a reconcile decision that was already durable when the
    // process stopped. No readback and no original action dispatch is
    // needed in this window.
    if let last = inspection.events.last,
      last.kind == .reconcileOutcome,
      case .string(let nextStateRaw)? = last.payload["nextState"],
      let nextState = JobState(rawValue: nextStateRaw)
    {
      try transition(
        &runtime, from: .reconciling, to: nextState,
        reason: "complete durable reconcile decision",
        triggerEventID: last.eventID)
      inspection = try DurableJournalRecovery.inspect(url: journalURL)
    }
    if inspection.currentState == .resumeAtConfirmedSafeBoundary,
      inspection.lastReconcileOutcomeCertainty == .confirmed
    {
      runtime.record.outcomeUnknown = false
      runtime.record.recoveryStepID = nil
      runtime.record.recoveryIntentEventID = nil
      runtime.record.recoveryAction = nil
      runtime.record.state = JobState.resumeAtConfirmedSafeBoundary.rawValue
      runtime.completedStepIDs = Self.confirmedSucceededStepIDs(in: inspection)
      runtime.record.timeline.append("reconciled: durable confirmed completion")
      try persistRuntimeRecord(runtime.record)
      jobs[jobID] = runtime
      return status(of: runtime.record)
    }
    if inspection.currentState == .finalizing,
      inspection.lastReconcileOutcomeCertainty == .confirmed
    {
      try transition(
        &runtime, from: .finalizing, to: .failed,
        reason: "reconciliation confirmed the original action did not complete")
      runtime.record.outcomeUnknown = false
      runtime.record.recoveryStepID = nil
      runtime.record.recoveryIntentEventID = nil
      runtime.record.recoveryAction = nil
      runtime.record.finishedAtUTC = nowUTC()
      try persistRuntimeRecord(runtime.record)
      jobs[jobID] = runtime
      try await recordCapabilityOutcome(
        for: runtime.record, outcome: .safeToReflash,
        state: JobState.failed.rawValue)
      return statusAndReleaseTerminalRuntime(runtime.record, provider: provider)
    }
    guard inspection.unknownOutcomes.isEmpty else {
      runtime.record.timeline.append(
        "reconcile refused: legacy outcomeUnknown event cannot be rewritten; original not resent")
      try persistRuntimeRecord(runtime.record)
      jobs[jobID] = runtime
      return status(of: runtime.record)
    }
    guard let stepID = runtime.record.recoveryStepID,
      let persistedAction = runtime.record.recoveryAction,
      let intentEventID = runtime.record.recoveryIntentEventID
    else {
      // A lane-dispatched flash persists no exact typed action: its writes ran
      // in `arkforged` under step permits, and their receipts live in that
      // daemon's journal — not this engine's to parse. The device itself is
      // the ground truth such a job reconciles against.
      if ArkForgeFlashOperation.containsDurableRecordReference(
        runtime.record.operationReference)
      {
        if let execution = runtime.arkForgeState.execution,
          let lane = configuration.arkForgeLane,
          let settled = try await reconcileLaneAgainstDaemonTerminal(
            runtime: &runtime, inspection: inspection, execution: execution,
            lane: lane, provider: provider)
        {
          return settled
        }
        return try await reconcileLaneFlashAgainstDevice(
          runtime: &runtime, inspection: inspection, provider: provider)
      }
      throw RuntimeJobEngineError.internalFailure(
        "unknown outcome has no persisted exact typed action for \(jobID)")
    }

    guard
      inspection.currentState == .waitingForRecovery
        || inspection.currentState == .reconciling
    else {
      throw RuntimeJobEngineError.internalFailure(
        "unknown outcome journal is \(inspection.currentState?.rawValue ?? "missing"), "
          + "not at a recovery boundary")
    }
    if inspection.currentState == .waitingForRecovery {
      try transition(
        &runtime, from: .waitingForRecovery, to: .reconciling,
        reason: "begin exact typed provider reconciliation")
      inspection = try DurableJournalRecovery.inspect(url: journalURL)
    }
    let unfinishedAttemptID: String? = {
      var completed = Set<String>()
      for event in inspection.events where event.kind == .reconcileOutcome {
        if case .string(let attempt)? = event.payload["recoveryAttemptId"] {
          completed.insert(attempt)
        }
      }
      for event in inspection.events.reversed() where event.kind == .reconcileStarted {
        if case .string(let attempt)? = event.payload["recoveryAttemptId"],
          !completed.contains(attempt)
        {
          return attempt
        }
      }
      return nil
    }()
    let recoveryAttemptID: String
    if let unfinishedAttemptID {
      recoveryAttemptID = unfinishedAttemptID
    } else {
      recoveryAttemptID = "recovery-\(jobID)-\(runtime.nextSequence)"
      try runtime.journal.appendAndSynchronize(
        JournalEvent.reconcileStarted(
          eventID: "reconcile-start-\(runtime.nextSequence)",
          sequence: runtime.nextSequence,
          sessionID: runtime.record.sessionID,
          jobID: jobID,
          timestamp: nowUTC(),
          recoveryAttemptID: recoveryAttemptID,
          sourceState: .waitingForRecovery,
          lastDurableSequence: inspection.lastDurableSequence ?? 0,
          trigger: "manual",
          schemaVersion: Self.journalSchemaVersion(of: runtime.record)))
      runtime.nextSequence += 1
      runtime.record.timeline.append("reconcile started \(stepID)")
      jobs[jobID] = runtime
      inspection = try DurableJournalRecovery.inspect(url: journalURL)
    }

    guard
      let descriptor = RuntimeOperationCatalog.descriptor(
        reference: runtime.record.request.operation.reference)
    else {
      throw RuntimeJobEngineError.internalFailure(
        "catalog operation vanished for \(jobID)")
    }
    // Host-only reconciliation asks the provider to inspect only its durable
    // Job-owned output; it must not invent device facts. Device-bound actions
    // retain the existing fresh-facts gate.
    let facts: ProviderFacts?
    if descriptor.binding == .none {
      facts = nil
    } else {
      let resolved = try await providers.resolveFacts(
        providerID: runtime.record.providerID,
        targetID: runtime.record.request.target.targetID)
      try Self.validateEvidenceFacts(
        resolved,
        targetID: runtime.record.request.target.targetID,
        bindingRevision: runtime.record.request.target.expectedBindingRevision,
        providerID: runtime.record.providerID)
      facts = resolved
    }
    let reconciledInputArtifact = try await resolvedInputArtifact(jobID: jobID)
    let context = ProviderExecutionContext(
      jobID: jobID, stepID: stepID,
      targetID: runtime.record.request.target.targetID,
      bindingRevision: runtime.record.request.target.expectedBindingRevision,
      connectKey: facts?.executionConnectKey,
      expectedIdentitySHA256: facts?.deviceIdentitySHA256,
      toolVersion: facts?.toolVersion,
      toolSHA256: facts?.toolSHA256,
      serverFacts: facts?.serverFacts ?? [:],
      nowUTC: nowUTC(), resolvedInputArtifact: reconciledInputArtifact,
      expectedRuntimeBuildVersion: declaredRuntimeBuildVersion(
        for: descriptor, artifact: reconciledInputArtifact,
        artifactLeaseID: Self.flashArtifactLeaseID(
          in: runtime.record.request.inputs)))
    let action = try persistedAction.materialize()
    let reference = ProviderDurableIntentReference(
      jobID: jobID, stepID: stepID,
      intentEventID: intentEventID, action: action)
    var outcome: ProviderReconcileOutcome
    let durableResolution = inspection.events.last { event in
      event.kind == .stepOutcome && event.correlatedIntentEventID == intentEventID
        && event.payload["outcomeCertainty"] == .string(JournalOutcomeCertainty.confirmed.rawValue)
    }
    if let durableResolution {
      outcome =
        durableResolution.payload["result"] == .string("succeeded")
        ? .confirmedCompleted(summary: ["source": "durableReconcileOutcome"])
        : .confirmedNotExecuted
    } else if action.effect >= .deviceMutation {
      do {
        let readbackContext = ProviderExecutionContext(
          jobID: context.jobID,
          stepID: Self.reconciliationStepID(
            originalStepID: stepID,
            recoveryAttemptID: recoveryAttemptID),
          targetID: context.targetID,
          bindingRevision: context.bindingRevision,
          connectKey: context.connectKey,
          expectedIdentitySHA256: context.expectedIdentitySHA256,
          toolVersion: context.toolVersion,
          toolSHA256: context.toolSHA256,
          serverFacts: context.serverFacts,
          nowUTC: context.nowUTC,
          resolvedInputArtifact: context.resolvedInputArtifact,
          // A reconciliation readback derives from the same context it is
          // recovering, so it inherits the same resolved facts rather than
          // re-deriving any of them.
          expectedRuntimeBuildVersion: context.expectedRuntimeBuildVersion)
        guard
          let readback = try provider.reconciliationReadback(
            intent: reference, context: readbackContext)
        else {
          outcome = .stillUnknown(
            reason: "mutation has no dedicated readback; original not resent")
          return try await finishReconcile(
            runtime: &runtime, inspection: inspection,
            intentEventID: intentEventID, stepID: stepID,
            recoveryAttemptID: recoveryAttemptID, outcome: outcome,
            bindingRevision: facts?.bindingRevision, provider: provider)
        }
        guard readback.action.effect <= .readOnly else {
          throw RuntimeJobEngineError.internalFailure(
            "mutation reconciliation produced a non-read-only plan")
        }
        let receipt = try await dispatcher.dispatch(readback)
        outcome = try provider.verifyReconciliationReadback(
          receipt: receipt, intent: reference, context: readbackContext)
      } catch {
        outcome = .stillUnknown(
          reason: "dedicated readback failed: \(error); original not resent")
      }
    } else {
      outcome = try await provider.reconcile(intent: reference, context: context)
    }
    if case .workspace(.signOpenHarmonyHap(let signingAction)) = action,
      case .confirmedCompleted = outcome
    {
      // A reconciled producer must republish the exact verified bytes before
      // its step is marked complete. Otherwise resume would skip the step and
      // finalize a Job with no signed lease.
      let recovered = try await OpenHarmonySigningWorkspaceDispatcher.recoveredReceipt(
        action: signingAction)
      guard let step = descriptor.steps.first(where: { $0.stepID == stepID }) else {
        throw RuntimeJobEngineError.internalFailure(
          "reconciled signing step vanished from the catalog")
      }
      try await publishDeclaredArtifacts(
        jobID: jobID, step: step, summary: recovered.summary,
        receipt: recovered.receipt)
      outcome = .confirmedCompleted(summary: recovered.summary)
    }
    return try await finishReconcile(
      runtime: &runtime, inspection: inspection,
      intentEventID: intentEventID, stepID: stepID,
      recoveryAttemptID: recoveryAttemptID, outcome: outcome,
      bindingRevision: facts?.bindingRevision, provider: provider)
  }

  private func finishReconcile(
    runtime: inout JobRuntime,
    inspection: JournalReplay,
    intentEventID: String,
    stepID: String,
    recoveryAttemptID: String,
    outcome: ProviderReconcileOutcome,
    bindingRevision: Int?,
    provider: any DeviceProvider,
    successSemanticCode: String? = nil,
    successSummary: String? = nil
  ) async throws -> RuntimeJobStatus {
    let jobID = runtime.record.jobID
    let hasDurableResolution = inspection.events.contains { event in
      event.kind == .stepOutcome && event.correlatedIntentEventID == intentEventID
        && event.payload["outcomeCertainty"] == .string(JournalOutcomeCertainty.confirmed.rawValue)
    }
    let nextState: JobState
    let reconcileResult: String
    let certainty: JournalOutcomeCertainty
    let safeBoundary: Bool
    let reconcileBindingRevision: Int?
    let detail: String

    switch outcome {
    case .confirmedCompleted(let summary):
      if !hasDurableResolution {
        try runtime.journal.appendAndSynchronize(
          JournalEvent.stepOutcome(
            eventID: "reconciled-outcome-\(runtime.nextSequence)",
            sequence: runtime.nextSequence,
            sessionID: runtime.record.sessionID,
            jobID: jobID,
            timestamp: nowUTC(),
            stepID: stepID,
            attempt: 1,
            correlatesToIntentEventID: intentEventID,
            result: "succeeded",
            outcomeCertainty: .confirmed,
            semanticCode: successSemanticCode,
            summary: successSummary,
            schemaVersion: Self.journalSchemaVersion(of: runtime.record)))
        runtime.nextSequence += 1
      }
      nextState = .resumeAtConfirmedSafeBoundary
      reconcileResult =
        bindingRevision == nil
        ? "resumeHostOnlyAtConfirmedSafeBoundary"
        : "resumeAtConfirmedSafeBoundary"
      certainty = .confirmed
      safeBoundary = true
      reconcileBindingRevision = bindingRevision
      detail = "confirmed completed \(summary.keys.sorted())"
    case .confirmedNotExecuted:
      if !hasDurableResolution {
        try runtime.journal.appendAndSynchronize(
          JournalEvent.stepOutcome(
            eventID: "reconciled-outcome-\(runtime.nextSequence)",
            sequence: runtime.nextSequence,
            sessionID: runtime.record.sessionID,
            jobID: jobID,
            timestamp: nowUTC(),
            stepID: stepID,
            attempt: 1,
            correlatesToIntentEventID: intentEventID,
            result: "failed",
            outcomeCertainty: .confirmed,
            // The semantic code is what makes this a *proof* rather than just
            // a failure: `mutationIntentEvidence` recognizes a proven
            // non-execution by this code alone. Without it the dedicated
            // readback established that a destructive step never ran, but a
            // historical usage terminal could not carry that proof and stayed
            // `unsafePartial` — the product throwing away the strongest
            // evidence it owns (TASK-AIN-020).
            semanticCode: Self.confirmedNotExecutedSemanticCode,
            schemaVersion: Self.journalSchemaVersion(of: runtime.record)))

        runtime.nextSequence += 1
      }
      // An unknown action is never resent automatically, even when it was
      // read-only. A confirmed non-execution is a definitive failed step.
      nextState = .finalizing
      reconcileResult =
        bindingRevision == nil
        ? "finalizeHostOnlyConfirmedFailure"
        : "finalizeConfirmedFailure"
      certainty = .confirmed
      safeBoundary = true
      reconcileBindingRevision = bindingRevision
      detail = "confirmed not executed; original not resent"
    case .stillUnknown(let reason):
      nextState = .waitingForRecovery
      reconcileResult = "waitingForRecovery"
      certainty = .outcomeUnknown
      safeBoundary = false
      reconcileBindingRevision = nil
      detail = reason
    }

    let reconcileOutcome = try JournalEvent.reconcileOutcome(
      eventID: "reconcile-outcome-\(runtime.nextSequence)",
      sequence: runtime.nextSequence,
      sessionID: runtime.record.sessionID,
      jobID: jobID,
      timestamp: nowUTC(),
      bindingRevision: reconcileBindingRevision,
      recoveryAttemptID: recoveryAttemptID,
      result: reconcileResult,
      nextState: nextState,
      outcomeCertainty: certainty,
      safeBoundaryConfirmed: safeBoundary,
      evidence: [detail],
      schemaVersion: Self.journalSchemaVersion(of: runtime.record))
    try runtime.journal.appendAndSynchronize(reconcileOutcome)
    runtime.nextSequence += 1
    try transition(
      &runtime, from: .reconciling, to: nextState,
      reason: "persist exact typed reconcile decision: \(detail)",
      triggerEventID: reconcileOutcome.eventID)

    switch outcome {
    case .confirmedCompleted:
      runtime.completedStepIDs.insert(stepID)
      runtime.record.outcomeUnknown = false
      runtime.record.operationFailure = nil
      runtime.record.recoveryStepID = nil
      runtime.record.recoveryIntentEventID = nil
      runtime.record.recoveryAction = nil
      runtime.record.finishedAtUTC = nil
      runtime.record.timeline.append("reconciled: confirmed completed \(stepID)")
    case .confirmedNotExecuted:
      try transition(
        &runtime, from: .finalizing, to: .failed,
        reason: "reconciliation confirmed \(stepID) did not complete")
      runtime.record.outcomeUnknown = false
      runtime.record.operationFailure = RuntimeOperationFailure(
        code: .executionConfirmedNotPerformed, category: .externalTool,
        retryability: .runtimeDecisionRequired,
        recovery: .submitNewTypedRequestAfterRuntimeProof)
      runtime.record.recoveryStepID = nil
      runtime.record.recoveryIntentEventID = nil
      runtime.record.recoveryAction = nil
      runtime.record.finishedAtUTC = nowUTC()
      runtime.record.timeline.append("reconciled: confirmed not executed \(stepID)")
    case .stillUnknown:
      runtime.record.outcomeUnknown = true
      runtime.record.timeline.append("reconcile inconclusive: \(detail)")
    }
    try persistRuntimeRecord(runtime.record)
    jobs[jobID] = runtime
    switch outcome {
    case .confirmedNotExecuted:
      try await recordCapabilityOutcome(
        for: runtime.record, outcome: .safeToReflash,
        state: JobState.failed.rawValue)
    case .stillUnknown:
      try await recordCapabilityOutcome(
        for: runtime.record, outcome: .outcomeUnknown,
        state: JobState.waitingForRecovery.rawValue)
    case .confirmedCompleted:
      // This Job still owns the same reservation and must finish the
      // remaining plan before its lineage node can authorize another Job.
      break
    }
    return statusAndReleaseTerminalRuntime(runtime.record, provider: provider)
  }

  /// First recovery source for a delegated job: the exact daemon job Runtime
  /// durably correlated before any permit could be signed.
  ///
  /// This path is passive. It accepts either the already-persisted canonical
  /// receipt (the crash window between receipt persistence and step outcome)
  /// or a terminal event observed from that exact daemon job. It never starts
  /// execution or answers an admission. Inconclusive/failed daemon terminals
  /// fall through to the independent read-only device reconciliation below.
  private func reconcileLaneAgainstDaemonTerminal(
    runtime: inout JobRuntime,
    inspection initialInspection: JournalReplay,
    execution: RuntimeArkForgeLaneExecution,
    lane: any ArkForgeLane,
    provider: any DeviceProvider
  ) async throws -> RuntimeJobStatus? {
    let jobID = runtime.record.jobID
    guard let stepID = runtime.record.recoveryStepID,
      let intentEventID = runtime.record.recoveryIntentEventID,
      initialInspection.unknownOutcomes.isEmpty,
      initialInspection.outstandingIntents.contains(where: {
        $0.eventID == intentEventID && $0.stepID == stepID
      })
    else {
      return nil
    }

    var durableReceipt = runtime.arkForgeState.planCompletionReceipt
    var cancelledSafe = false
    if durableReceipt == nil {
      do {
        switch try await lane.observeTerminal(execution: execution) {
        case .completed(let receipts):
          durableReceipt = receipts.last.map(RuntimeArkForgePlanCompletionReceipt.init)
        case .cancelledSafe:
          cancelledSafe = true
        case .confirmedFailed(let reason, _):
          runtime.record.timeline.append(
            "correlated arkforged terminal is confirmedFailed; device readback required: \(reason)")
        case .outcomeUnknown(let reason, _):
          runtime.record.timeline.append(
            "correlated arkforged terminal remains unknown: \(reason)")
        case nil:
          runtime.record.timeline.append(
            "correlated arkforged job \(execution.daemonJobID) has no terminal yet")
        }
      } catch {
        runtime.record.timeline.append(
          "could not observe correlated arkforged job \(execution.daemonJobID): \(error)")
      }
    }

    if let durableReceipt {
      do {
        try Self.validateArkForgePlanCompletionReceipt(
          durableReceipt, jobID: jobID, execution: execution)
      } catch {
        runtime.record.timeline.append(
          "correlated arkforged completion receipt is non-canonical; device readback required")
        try persistRuntimeRecord(runtime.record)
        jobs[jobID] = runtime
        return nil
      }
      // Receipt before outcome: preserve the same crash invariant as live
      // dispatch. Re-entering this method after a crash simply reuses it.
      runtime.arkForgeState.planCompletionReceipt = durableReceipt
      try persistArkForgeRuntimeJobState(runtime.arkForgeState, jobID: jobID)
    } else if !cancelledSafe {
      try persistRuntimeRecord(runtime.record)
      jobs[jobID] = runtime
      return nil
    }

    var inspection = initialInspection
    let journalURL = jobDirectory(for: jobID).appending(path: "journal.jsonl")
    if inspection.currentState == .waitingForRecovery {
      try transition(
        &runtime, from: .waitingForRecovery, to: .reconciling,
        reason: "begin passive correlated ArkForge reconciliation")
      inspection = try DurableJournalRecovery.inspect(url: journalURL)
    }
    guard inspection.currentState == .reconciling else { return nil }

    let unfinishedAttemptID: String? = {
      var completed = Set<String>()
      for event in inspection.events where event.kind == .reconcileOutcome {
        if case .string(let attempt)? = event.payload["recoveryAttemptId"] {
          completed.insert(attempt)
        }
      }
      for event in inspection.events.reversed() where event.kind == .reconcileStarted {
        if case .string(let attempt)? = event.payload["recoveryAttemptId"],
          !completed.contains(attempt)
        {
          return attempt
        }
      }
      return nil
    }()
    let recoveryAttemptID: String
    if let unfinishedAttemptID {
      recoveryAttemptID = unfinishedAttemptID
    } else {
      recoveryAttemptID = "arkforge-terminal-recovery-\(jobID)-\(runtime.nextSequence)"
      try runtime.journal.appendAndSynchronize(
        JournalEvent.reconcileStarted(
          eventID: "reconcile-start-\(runtime.nextSequence)",
          sequence: runtime.nextSequence,
          sessionID: runtime.record.sessionID,
          jobID: jobID,
          timestamp: nowUTC(),
          recoveryAttemptID: recoveryAttemptID,
          sourceState: .waitingForRecovery,
          lastDurableSequence: inspection.lastDurableSequence ?? 0,
          trigger: "manual",
          schemaVersion: Self.journalSchemaVersion(of: runtime.record)))
      runtime.nextSequence += 1
      runtime.record.timeline.append(
        "reconcile observed exact daemon job \(execution.daemonJobID)")
      jobs[jobID] = runtime
      inspection = try DurableJournalRecovery.inspect(url: journalURL)
    }

    if cancelledSafe {
      return try await finishReconcile(
        runtime: &runtime, inspection: inspection,
        intentEventID: intentEventID, stepID: stepID,
        recoveryAttemptID: recoveryAttemptID,
        outcome: .confirmedNotExecuted,
        bindingRevision: runtime.record.materializedBindingRevision,
        provider: provider)
    }
    guard let receipt = runtime.arkForgeState.planCompletionReceipt else { return nil }
    return try await finishReconcile(
      runtime: &runtime, inspection: inspection,
      intentEventID: intentEventID, stepID: stepID,
      recoveryAttemptID: recoveryAttemptID,
      outcome: .confirmedCompleted(summary: [
        "source": "correlatedArkForgeTerminal",
        "daemonJobID": execution.daemonJobID,
        "planID": execution.planID,
      ]),
      bindingRevision: runtime.record.materializedBindingRevision,
      provider: provider,
      successSemanticCode: Self.arkForgePlanCompletionSemanticCode,
      successSummary: Self.arkForgePlanCompletionSummary(receipt))
  }

  /// Reconciles an unknown ArkForge-lane flash against the device itself.
  ///
  /// A lane job has no persisted exact typed action to re-verify: the writes
  /// ran in `arkforged` under step permits, and their receipts live in that
  /// daemon's journal — which is arkforged's private record, not this
  /// engine's to parse. What this authority *can* establish on its own is the
  /// device's post-flash truth, and it is the same fact the plan's postflight
  /// asserts: exactly one bound HDC identity at the recorded alias topology
  /// answering the exact product model and build the job's bundle declares.
  ///
  /// If the device answers, the flash as a whole demonstrably took effect —
  /// the job settles `recovered` and its capability use closes `.confirmed`,
  /// which lets the generation roll. If it does not answer, nothing is
  /// invented: the job returns to `waitingForRecovery` with the reason on its
  /// timeline, and the use stays unknown.
  ///
  /// Measured 2026-08-18 on job-fb3da3c21320542f4fe82e2e82c589d5: all nine
  /// partitions carried semantic receipts in arkforged's journal and the
  /// device answered `const.ohos.fullname=OpenHarmony-7.0.0.37` by hand,
  /// while `reconcile` could only throw "no persisted exact typed action" and
  /// the unknown use held the destructive lineage shut.
  private func reconcileLaneFlashAgainstDevice(
    runtime: inout JobRuntime,
    inspection initialInspection: JournalReplay,
    provider: any DeviceProvider
  ) async throws -> RuntimeJobStatus {
    let jobID = runtime.record.jobID
    var inspection = initialInspection
    guard
      inspection.currentState == .waitingForRecovery
        || inspection.currentState == .reconciling
    else {
      throw RuntimeJobEngineError.internalFailure(
        "unknown outcome journal is \(inspection.currentState?.rawValue ?? "missing"), "
          + "not at a recovery boundary")
    }
    let journalURL = jobDirectory(for: jobID).appending(path: "journal.jsonl")
    if inspection.currentState == .waitingForRecovery {
      try transition(
        &runtime, from: .waitingForRecovery, to: .reconciling,
        reason: "begin lane postflight reconciliation")
      inspection = try DurableJournalRecovery.inspect(url: journalURL)
    }
    // Attempt bookkeeping identical to the exact-typed path: an attempt that
    // stopped between start and outcome is resumed, never duplicated.
    let unfinishedAttemptID: String? = {
      var completed = Set<String>()
      for event in inspection.events where event.kind == .reconcileOutcome {
        if case .string(let attempt)? = event.payload["recoveryAttemptId"] {
          completed.insert(attempt)
        }
      }
      for event in inspection.events.reversed() where event.kind == .reconcileStarted {
        if case .string(let attempt)? = event.payload["recoveryAttemptId"],
          !completed.contains(attempt)
        {
          return attempt
        }
      }
      return nil
    }()
    let recoveryAttemptID: String
    if let unfinishedAttemptID {
      recoveryAttemptID = unfinishedAttemptID
    } else {
      recoveryAttemptID = "lane-recovery-\(jobID)-\(runtime.nextSequence)"
      try runtime.journal.appendAndSynchronize(
        JournalEvent.reconcileStarted(
          eventID: "reconcile-start-\(runtime.nextSequence)",
          sequence: runtime.nextSequence,
          sessionID: runtime.record.sessionID,
          jobID: jobID,
          timestamp: nowUTC(),
          recoveryAttemptID: recoveryAttemptID,
          sourceState: .waitingForRecovery,
          lastDurableSequence: inspection.lastDurableSequence ?? 0,
          trigger: "manual",
          schemaVersion: Self.journalSchemaVersion(of: runtime.record)))
      runtime.nextSequence += 1
      runtime.record.timeline.append(
        "reconcile started rebind-and-verify-build (lane postflight)")
      jobs[jobID] = runtime
      inspection = try DurableJournalRecovery.inspect(url: journalURL)
    }

    guard
      let descriptor = RuntimeOperationCatalog.descriptor(
        reference: runtime.record.request.operation.reference),
      let verifyStep = descriptor.steps.first(where: {
        $0.stepID == "rebind-and-verify-build"
      })
    else {
      throw RuntimeJobEngineError.internalFailure(
        "ArkForge Flash operation lost its rebind-and-verify-build step")
    }

    var verified = false
    var detail = ""
    do {
      let facts = try await providers.resolveFacts(
        providerID: runtime.record.providerID,
        targetID: runtime.record.request.target.targetID)
      try Self.validateEvidenceFacts(
        facts,
        targetID: runtime.record.request.target.targetID,
        bindingRevision: runtime.record.request.target.expectedBindingRevision,
        providerID: runtime.record.providerID)
      let artifact = try await resolvedInputArtifact(jobID: jobID)
      let context = ProviderExecutionContext(
        jobID: jobID,
        stepID: Self.reconciliationStepID(
          originalStepID: "rebind-and-verify-build",
          recoveryAttemptID: recoveryAttemptID),
        targetID: runtime.record.request.target.targetID,
        bindingRevision: runtime.record.request.target.expectedBindingRevision,
        connectKey: facts.executionConnectKey,
        expectedIdentitySHA256: facts.deviceIdentitySHA256,
        toolVersion: facts.toolVersion,
        toolSHA256: facts.toolSHA256,
        serverFacts: facts.serverFacts,
        nowUTC: nowUTC(),
        resolvedInputArtifact: artifact,
        expectedRuntimeBuildVersion: declaredRuntimeBuildVersion(
          for: descriptor, artifact: artifact,
          artifactLeaseID: Self.flashArtifactLeaseID(
            in: runtime.record.request.inputs)))
      let action = try provider.action(
        for: verifyStep,
        operation: ArkForgeFlashOperation.canonicalDescriptor(
          for: descriptor.reference) ?? descriptor,
        inputs: try ArkForgeFlashRequest.canonicalInputs(
          submittedReference: descriptor.reference,
          inputs: runtime.record.request.inputs),
        context: context)
      guard action.effect <= .readOnly else {
        throw RuntimeJobEngineError.internalFailure(
          "lane postflight reconciliation produced a non-read-only action")
      }
      let plan = try provider.lower(action: action, context: context)
      _ = try await dispatcher.dispatch(plan)
      verified = true
      detail = "the bound device answers the declared build"
    } catch {
      verified = false
      detail = "lane postflight did not verify: \(error)"
    }

    let nextState: JobState = verified ? .finalizing : .waitingForRecovery
    let reconcileOutcome = try JournalEvent.reconcileOutcome(
      eventID: "reconcile-outcome-\(runtime.nextSequence)",
      sequence: runtime.nextSequence,
      sessionID: runtime.record.sessionID,
      jobID: jobID,
      timestamp: nowUTC(),
      bindingRevision: verified ? runtime.record.materializedBindingRevision : nil,
      recoveryAttemptID: recoveryAttemptID,
      result: verified ? "finalizeLanePostflightRecovered" : "waitingForRecovery",
      nextState: nextState,
      outcomeCertainty: verified ? .confirmed : .outcomeUnknown,
      safeBoundaryConfirmed: verified,
      evidence: [detail],
      schemaVersion: Self.journalSchemaVersion(of: runtime.record))
    try runtime.journal.appendAndSynchronize(reconcileOutcome)
    runtime.nextSequence += 1
    try transition(
      &runtime, from: .reconciling, to: nextState,
      reason: "persist lane postflight reconcile decision: \(detail)",
      triggerEventID: reconcileOutcome.eventID)

    if verified {
      try transition(
        &runtime, from: .finalizing, to: .recovered,
        reason: "lane postflight verified the flashed device")
      runtime.record.outcomeUnknown = false
      runtime.record.operationFailure = nil
      runtime.record.finishedAtUTC = nowUTC()
      runtime.record.timeline.append(
        "reconciled: lane postflight verified the flashed device")
      try persistRuntimeRecord(runtime.record)
      jobs[jobID] = runtime
      try await recordCapabilityOutcome(
        for: runtime.record, outcome: .confirmed,
        state: JobState.recovered.rawValue)
    } else {
      runtime.record.outcomeUnknown = true
      runtime.record.timeline.append("reconcile inconclusive: \(detail)")
      try persistRuntimeRecord(runtime.record)
      jobs[jobID] = runtime
      try await recordCapabilityOutcome(
        for: runtime.record, outcome: .outcomeUnknown,
        state: JobState.waitingForRecovery.rawValue)
    }
    return statusAndReleaseTerminalRuntime(runtime.record, provider: provider)
  }

  /// The twin of the repair below, for a Job that reached `cancelled` while its
  /// capability use stayed `pending`.
  ///
  /// The drained-cancel path never recorded an outcome until 2026-08-18, so a
  /// job cancelled by that code holds its use open forever and the
  /// target-lineage guard then refuses *every* later destructive job on that
  /// binding. The cancel path records it now; this closes the ones already
  /// stranded, which is exactly what an operator means by reconciling a
  /// terminal job. Nothing here touches a device.
  ///
  /// `.confirmed` for the reason the generation-rollover comment gives: a
  /// drained cancellation is one the engine proved did not dispatch. A job whose
  /// outcome *is* unknown is excluded — that is a write to reconcile against the
  /// device, never a cancellation to declare closed.
  private func repairTerminalCancelledLineageIfNeeded(
    for record: RuntimeJobRecord
  ) async throws {
    guard !record.outcomeUnknown,
      record.state == JobState.cancelled.rawValue,
      let evidence = record.admissionEvidence,
      evidence.kind == .runtimeCapability || evidence.kind == .standingAuthorization,
      let status = try await capabilityStore.inspect(capabilityID: evidence.reference),
      status.lineage.contains(where: {
        $0.jobID == record.jobID && $0.outcome == .pending
      })
    else { return }
    try await recordCapabilityOutcome(
      for: record, outcome: .confirmed, state: JobState.cancelled.rawValue)
  }

  /// A confirmed-not-executed decision and terminal Job record become durable
  /// before the capability lineage is appended. If the daemon stops or that
  /// final append fails, a later explicit reconcile must be able to finish the
  /// bookkeeping without dispatching a Provider readback (and never the
  /// original mutation) again.
  private func repairTerminalSafeToReflashLineageIfNeeded(
    for record: RuntimeJobRecord
  ) async throws {
    guard !record.outcomeUnknown,
      record.state == JobState.failed.rawValue,
      record.admissionEvidence?.kind == .runtimeCapability
        || record.admissionEvidence?.kind == .standingAuthorization
    else { return }

    let replay = try DurableJournalRecovery.inspect(
      url: jobDirectory(for: record.jobID).appending(path: "journal.jsonl"))
    guard replay.currentState == .failed,
      let provenNonExecution = replay.events.last(where: {
        $0.kind == .stepOutcome
          && $0.payload["semanticCode"]
            == .string(Self.confirmedNotExecutedSemanticCode)
          && $0.payload["outcomeCertainty"]
            == .string(JournalOutcomeCertainty.confirmed.rawValue)
      }),
      let intentID = provenNonExecution.correlatedIntentEventID,
      replay.events.contains(where: {
        $0.kind == .stepIntent && $0.eventID == intentID
          && ($0.stepEffect ?? .hostOnly) >= .deviceMutation
      }),
      !replay.events.contains(where: {
        $0.sequence > provenNonExecution.sequence && $0.kind == .stepIntent
          && ($0.stepEffect ?? .hostOnly) >= .deviceMutation
      })
    else { return }

    if let reconcileOutcome = replay.events.last(where: {
      $0.kind == .reconcileOutcome && $0.sequence > provenNonExecution.sequence
    }) {
      guard replay.lastReconcileOutcomeCertainty == .confirmed,
        reconcileOutcome.payload["result"] == .string("finalizeConfirmedFailure"),
        reconcileOutcome.payload["nextState"] == .string(JobState.finalizing.rawValue),
        reconcileOutcome.payload["safeBoundaryConfirmed"] == .bool(true)
      else { return }
    }

    try await recordCapabilityOutcome(
      for: record, outcome: .safeToReflash,
      state: JobState.failed.rawValue)
  }

  /// Repairs only lineage gaps whose owning Job already carries a complete,
  /// journal-confirmed terminal non-execution proof. The Job record becomes
  /// durable before the independently durable capability outcome, so ENOSPC
  /// or process loss can leave the former complete and the latter pending.
  ///
  /// This runs before expensive mutation plan materialization. Missing,
  /// malformed, non-terminal, unknown or differently bound records remain
  /// untouched and the normal lineage gate still rejects them fail-closed.
  private func repairProvablyTerminalCapabilityOutcomeGaps(
    targetID: String,
    bindingRevision: Int
  ) async throws {
    let unresolvedJobIDs = Set(
      try await capabilityStore.list().flatMap { status in
        status.lineage.compactMap { entry -> String? in
          guard entry.bindingRevision == bindingRevision,
            entry.outcome == .pending || entry.outcome == .outcomeUnknown
          else { return nil }
          return entry.jobID
        }
      })
    for jobID in unresolvedJobIDs.sorted() {
      guard let record = try? recordForRead(jobID: jobID),
        record.request.target.targetID == targetID,
        record.request.target.expectedBindingRevision == bindingRevision
      else { continue }
      try await repairTerminalSafeToReflashLineageIfNeeded(for: record)
    }
  }

  // MARK: Helpers

  private static func executionState(of record: RuntimeJobRecord) -> JobState {
    switch JobState(rawValue: record.state) {
    case .recoveringByCompleteOverwrite:
      return .recoveringByCompleteOverwrite
    case .cancelRequested:
      return .cancelRequested
    case .cancellingAtSafeBoundary:
      return .cancellingAtSafeBoundary
    default:
      return .running
    }
  }

  static func isDayu200Flash(_ record: RuntimeJobRecord) -> Bool {
    // operationReference is durable presentation data and may contain the pre-singleton "@1" alias.
    // The typed request operation ID is the stable identity for recovery and journal compatibility.
    ArkForgeFlashOperation.containsDurableRecordReference(
      record.request.operation.reference)
  }

  static func journalSchemaVersion(of record: RuntimeJobRecord) -> String {
    isDayu200Flash(record)
      ? JournalEvent.completeOverwriteRecoverySchemaVersion : JournalEvent.schemaVersion
  }

  private func establishSupersedingRecoveryEpoch(
    runtime: inout JobRuntime,
    descriptor: CatalogOperationDescriptor
  ) async throws -> SupersedingRecoveryEpoch {
    guard let recovery = runtime.record.admissionEvidence?.completeOverwriteRecovery,
      let contract = descriptor.completeOverwriteRecovery,
      contract.contractVersion == recovery.coverageContractVersion,
      let profileContract = contract.profile(reference: recovery.profileReference),
      Self.effectSetDigest(profileContract.coveredEffects)
        == recovery.coveredEffectSetSHA256,
      let stableIdentity = runtime.record.materializedStableTargetIdentitySHA256,
      let bindingRevision = runtime.record.materializedBindingRevision,
      let planDigest = runtime.record.materializedPlanDigest,
      let artifactSHA256 = runtime.record.admissionEvidence?
        .runtimeCapabilityCorrelation?.artifactSHA256,
      let providerSHA256 = runtime.record.admissionEvidence?
        .recoveryProviderExecutableSHA256,
      Self.isLowercaseSHA256(artifactSHA256),
      Self.isLowercaseSHA256(providerSHA256)
    else {
      throw RuntimeJobEngineError.internalFailure(
        "complete-overwrite terminal lacks immutable coverage, target, Artifact or tool facts")
    }
    let replay = try DurableJournalRecovery.inspect(
      url: jobDirectory(for: runtime.record.jobID)
        .appending(path: "journal.jsonl"))
    guard !replay.hasTornTail, replay.outstandingIntents.isEmpty,
      replay.unknownOutcomes.isEmpty
    else {
      throw RuntimeJobEngineError.internalFailure(
        "complete-overwrite terminal has unresolved recovery intent")
    }
    let requiredSteps = [contract.overwriteStepID] + contract.verificationStepIDs
    var confirmedIntentByStep: [String: JournalEvent] = [:]
    var confirmedStepIDs: [String] = []
    var seenConfirmedStepIDs: Set<String> = []
    for outcome in replay.events where outcome.kind == .stepOutcome {
      guard let stepID = outcome.stepID,
        outcome.payload["result"] == .string("succeeded"),
        outcome.payload["outcomeCertainty"] == .string("confirmed"),
        let intentEventID = outcome.correlatedIntentEventID,
        let intent = replay.events.first(where: {
          $0.kind == .stepIntent && $0.eventID == intentEventID
            && $0.stepID == stepID
        })
      else { continue }
      if seenConfirmedStepIDs.insert(stepID).inserted {
        confirmedStepIDs.append(stepID)
      }
      if requiredSteps.contains(stepID),
        outcome.payload["semanticCode"]
          == .string(Self.arkForgePlanCompletionSemanticCode)
      {
        confirmedIntentByStep[stepID] = intent
      }
    }
    guard Set(requiredSteps).isSubset(of: Set(confirmedIntentByStep.keys)),
      let recoveryIntent = confirmedIntentByStep[contract.overwriteStepID]
    else {
      throw RuntimeJobEngineError.internalFailure(
        "complete-overwrite terminal lacks all write/readback/postflight outcomes")
    }
    let resultingEpoch = RuntimeJobRecord.sha256Hex(
      Data(
        [
          stableIdentity, String(bindingRevision), runtime.record.jobID,
          planDigest, artifactSHA256, requiredSteps.joined(separator: ","),
        ].joined(separator: "\n").utf8))
    return try await RuntimeSupersedingRecoveryStore(
      stateDirectory: configuration.stateDirectory
    ).append(
      SupersedingRecoveryEpochDraft(
        source: .distinctRecoveryExecution,
        stableTargetIdentitySHA256: stableIdentity,
        bindingRevision: bindingRevision,
        coveredIntents: recovery.coveredIntents,
        uncertainEffectSetSHA256: recovery.uncertainEffectSetSHA256,
        coverageContractVersion: recovery.coverageContractVersion,
        coveredEffectSetSHA256: recovery.coveredEffectSetSHA256,
        recoveryJobID: runtime.record.jobID,
        recoveryIntentEventID: recoveryIntent.eventID,
        operationReference: runtime.record.operationReference,
        profileReference: recovery.profileReference,
        materializedPlanDigestSHA256: planDigest,
        artifactSHA256: artifactSHA256,
        providerExecutableSHA256: providerSHA256,
        confirmedStepIDs: confirmedStepIDs,
        resultingTargetEpochSHA256: resultingEpoch,
        establishedAtUTC: nowUTC()))
  }

  private static func effectSetDigest(_ effects: [String]) -> String {
    RuntimeJobRecord.sha256Hex(
      Data(Array(Set(effects)).sorted().joined(separator: "\n").utf8))
  }

  private static func reconciliationStepID(
    originalStepID: String,
    recoveryAttemptID: String
  ) -> String {
    let attemptDigest = SHA256Hex.string(of: Data(recoveryAttemptID.utf8))
    return
      "reconcile-\(originalStepID.prefix(72))-\(attemptDigest.prefix(32))"
  }

  private func verifyHostInputArtifact(
    jobID: String,
    descriptor: CatalogOperationDescriptor,
    step: CatalogStepDescriptor
  ) async throws {
    if ArkForgeFlashOperation.contains(descriptor.reference) {
      guard let runtime = jobs[jobID],
        let artifactLeaseID = ArkForgeFlashRequest.artifactLeaseID(
          submittedReference: descriptor.reference,
          inputs: runtime.record.request.inputs),
        let resolved = try await resolvedInputArtifact(jobID: jobID)
      else {
        throw RuntimeDispatchFailure.failed(
          "flash host verification cannot resolve its typed imageBundleLease")
      }
      let board = RockchipFlashProfile.dayu200
      guard
        let profileReference = ArkForgeFlashRequest.profileReference(
          submittedReference: descriptor.reference,
          inputs: runtime.record.request.inputs),
        RockchipFlashProfile.board(reference: profileReference) != nil
      else {
        throw RuntimeDispatchFailure.failed(
          "flash request names no published DAYU200 board profile")
      }
      // `resolvedInputArtifact` has just revalidated the exact lease. Reuse
      // the derived profile only after that fresh boundary; a cache miss reads
      // the archive, and a daemon restart intentionally starts empty.
      let profile: RockchipFlashProfile
      do {
        profile = try resolvedFlashArchiveProfile(
          artifactLeaseID: artifactLeaseID, artifact: resolved, board: board)
      } catch {
        throw RuntimeDispatchFailure.failed(
          "flash bundle is not a usable DAYU200 images archive: \(error)")
      }
      appendTimeline(
        jobID: jobID,
        entry:
          "\(step.stepID) profile=\(profileReference) build=\(profile.runtimeBuildVersion) "
          + "sha256=\(profile.archiveSHA256)")
      return
    }
    guard descriptor.reference == "deploy.native-library.app-owned@1" else {
      return
    }
    guard let runtime = jobs[jobID],
      case .string(let abiValue)? = runtime.record.request.inputs["expectedABI"],
      let expectedABI = HDCNativeLibraryABI(rawValue: abiValue),
      let resolved = try await resolvedInputArtifact(jobID: jobID)
    else {
      throw RuntimeDispatchFailure.failed(
        "native host verification cannot resolve its typed Artifact lease")
    }
    let bytes: Data
    do {
      bytes = try Data(contentsOf: resolved.fileURL, options: [.mappedIfSafe])
    } catch {
      throw RuntimeDispatchFailure.failed(
        "native host verification cannot read the leased ELF: \(error)")
    }
    let facts: HDCNativeLibraryArtifactFacts
    do {
      facts = try NativeLibraryArtifactValidator.validate(
        bytes, expectedABI: expectedABI,
        requireOpenHarmonyCodeSignature: true)
    } catch {
      throw RuntimeDispatchFailure.failed(
        "native host verification rejected the leased ELF: \(error)")
    }
    guard facts.sha256 == resolved.sha256,
      facts.byteCount == resolved.byteCount
    else {
      throw RuntimeDispatchFailure.failed(
        "native Artifact bytes drifted from the leased hash/size")
    }
    appendTimeline(
      jobID: jobID,
      entry: "\(step.stepID) abi=\(facts.abi.rawValue) "
        + "buildId=\(facts.buildID) sha256=\(facts.sha256)")
  }

  /// The additional packages of a multi-package install, in the order the
  /// caller listed them. Each one goes through the same lease resolution and
  /// the same binding validation as the entry package — a set is not a
  /// weaker check, it is the same check N times (CHG-2026-049 r4).
  private func resolvedAdditionalInputArtifacts(jobID: String) async throws
    -> [ProviderResolvedInputArtifact]
  {
    guard let runtime = jobs[jobID], let artifactStore,
      runtime.record.operationReference == "debug.hap@1",
      case .array(let raw)? = runtime.record.request.inputs["additionalHapArtifactLeases"]
    else {
      return []
    }
    var resolved: [ProviderResolvedInputArtifact] = []
    for value in raw {
      guard case .string(let lease) = value else {
        throw RuntimeJobEngineError.rejected(
          .invalidInput, "additionalHapArtifactLeases must be artifact leases")
      }
      let artifact = try await artifactStore.resolveLease(lease)
      try Self.validateArtifactBinding(
        artifact.bindingSnapshot, request: runtime.record.request,
        materializedStableIdentitySHA256:
          runtime.record.materializedStableTargetIdentitySHA256)
      resolved.append(
        ProviderResolvedInputArtifact(
          artifactID: artifact.artifactID, fileURL: artifact.fileURL,
          sha256: artifact.sha256, byteCount: artifact.byteCount))
    }
    return resolved
  }

  private func resolvedInputArtifact(jobID: String) async throws
    -> ProviderResolvedInputArtifact?
  {
    guard let runtime = jobs[jobID], let artifactStore else {
      return nil
    }
    let lease: String
    switch runtime.record.operationReference {
    case "debug.hap@1":
      guard
        case .string(let value)? =
          runtime.record.request.inputs["hapArtifactLease"]
      else { return nil }
      lease = value
    case "deploy.native-library.app-owned@1":
      guard
        case .string(let value)? =
          runtime.record.request.inputs["libraryArtifactLease"]
      else { return nil }
      lease = value
    case let reference where ArkForgeFlashOperation.contains(reference):
      guard
        let value = ArkForgeFlashRequest.artifactLeaseID(
          submittedReference: reference, inputs: runtime.record.request.inputs)
      else { return nil }
      lease = value
    case "workspace.apply-patch@1":
      guard
        case .string(let value)? =
          runtime.record.request.inputs["patchArtifactRef"]
      else { return nil }
      lease = value
    case "workspace.symbolize-crash@1":
      guard
        case .string(let value)? =
          runtime.record.request.inputs["dumpArtifactRef"]
      else { return nil }
      lease = value
    case OpenHarmonyLocalSigning.operationReference:
      guard
        case .string(let value)? =
          runtime.record.request.inputs["unsignedHapArtifactLease"]
      else { return nil }
      lease = value
    case "analyzer.extract-crash-signature@1", "analyzer.summarize-hilog@1",
      "analyzer.summarize-trace@1", "analyzer.analyze-trace@1":
      guard
        case .string(let value)? =
          runtime.record.request.inputs["sourceArtifactRef"]
      else { return nil }
      lease = value
    default:
      return nil
    }
    let resolved = try await artifactStore.resolveLease(lease)
    try Self.validateArtifactBinding(
      resolved.bindingSnapshot, request: runtime.record.request,
      materializedStableIdentitySHA256:
        runtime.record.materializedStableTargetIdentitySHA256,
      allowDeviceBoundHostSource: Self.consumesTargetScopedHostArtifact(
        provider: runtime.record.providerID,
        reference: runtime.record.operationReference))
    return ProviderResolvedInputArtifact(
      artifactID: resolved.artifactID, fileURL: resolved.fileURL,
      sha256: resolved.sha256, byteCount: resolved.byteCount)
  }

  /// Host-only operations that read an Artifact collected from, or imported
  /// against, a durable device target. Analyzers read device evidence; local
  /// signing reads a build output; `workspace.apply-patch@1` reads a patch
  /// that `artifact import workspace-patch` bound to the target it was
  /// imported for. Such a request names that target as its scope and pins no
  /// binding revision; the lease's own provenance stays intact.
  static func consumesTargetScopedHostArtifact(
    provider: String, reference: String
  ) -> Bool {
    provider == CatalogProvider.analyzer.rawValue
      || reference == OpenHarmonyLocalSigning.operationReference
      || reference == "workspace.apply-patch@1"
  }

  private static func validateArtifactBinding(
    _ binding: ArtifactBindingSnapshot,
    request: RuntimeOperationRequest,
    materializedStableIdentitySHA256: String?,
    allowDeviceBoundHostSource: Bool = false
  ) throws {
    if allowDeviceBoundHostSource,
      request.target.expectedBindingRevision == nil,
      binding.targetID == request.target.targetID
    {
      // These operations are host-only and cannot act on the device. They may read
      // an immutable Artifact that was collected from that exact target;
      // the source's binding revision and identity remain in its provenance
      // rather than being erased to make the host-only request look bound.
      return
    }
    guard binding.targetID == request.target.targetID,
      binding.bindingRevision == request.target.expectedBindingRevision
    else {
      throw RuntimeJobEngineError.rejected(
        .invalidInput,
        "Artifact lease target/binding/identity does not match the materialized request")
    }
    if let expectedIdentity = materializedStableIdentitySHA256 {
      guard binding.stableIdentitySHA256 == expectedIdentity else {
        throw RuntimeJobEngineError.rejected(
          .invalidInput,
          "Artifact lease target/binding/identity does not match the materialized request")
      }
    } else {
      guard request.target.expectedBindingRevision == nil,
        binding.stableIdentitySHA256 == nil
      else {
        throw RuntimeJobEngineError.rejected(
          .invalidInput,
          "host-only Artifact lease must not claim a device binding or identity")
      }
    }
  }

  private func materializeTypedPlanBeforeAuthorization(
    request: RuntimeOperationRequest,
    descriptor: CatalogOperationDescriptor,
    jobID: String
  ) async throws -> MaterializedAdmission {
    let implementationDescriptor =
      ArkForgeFlashOperation.canonicalDescriptor(for: descriptor.reference) ?? descriptor
    let implementationInputs = try ArkForgeFlashRequest.canonicalInputs(
      submittedReference: descriptor.reference, inputs: request.inputs)
    guard let provider = providers.provider(id: descriptor.provider.rawValue) else {
      throw RuntimeJobEngineError.rejected(
        .invalidInput, "provider \(descriptor.provider.rawValue) is not registered")
    }
    if case .unavailable(_, let reason) = provider.runtimeAvailability(for: descriptor) {
      throw RuntimeJobEngineError.rejected(
        .invalidInput, "\(descriptor.reference) is runtime unavailable: \(reason)")
    }
    if let reason = dispatcher.unavailableReason(providerID: descriptor.provider.rawValue) {
      throw RuntimeJobEngineError.rejected(
        .invalidInput, "\(descriptor.reference) is runtime unavailable: \(reason)")
    }
    if RuntimeArtifactService.requiresArtifactStore(reference: descriptor.reference),
      artifactStore == nil
    {
      throw RuntimeJobEngineError.rejected(
        .invalidInput,
        "\(descriptor.reference) is runtime unavailable: runtime.artifactStoreUnavailable")
    }
    let selectedSteps = descriptor.steps.filter { step in
      Self.stepIsRequested(step, descriptor: descriptor, inputs: request.inputs)
    }
    // A host-only operation has no device: no connect key, no identity digest,
    // no binding revision. Resolving device facts for it would mean inventing
    // them, so the admission path branches instead - and the branch is only
    // reachable for a descriptor that declares `binding: none`, with the
    // device-bound path below unchanged (CHG-2026-054 TASK-HTP-007).
    let facts: ProviderFacts?
    if descriptor.binding == .none {
      try Self.validateHostOnlyDescriptor(descriptor)
      guard request.target.expectedBindingRevision == nil else {
        throw RuntimeJobEngineError.rejected(
          .invalidRequest,
          "\(descriptor.reference) is host-only: a request must not pin a binding revision")
      }
      facts = nil
    } else {
      do {
        let resolved = try await providers.resolveFacts(
          providerID: descriptor.provider.rawValue,
          targetID: request.target.targetID)
        try Self.validateEvidenceFacts(
          resolved,
          targetID: request.target.targetID,
          bindingRevision: request.target.expectedBindingRevision,
          providerID: descriptor.provider.rawValue)
        facts = resolved
      } catch {
        throw RuntimeJobEngineError.rejected(
          .invalidInput,
          "target facts cannot materialize the typed plan before authorization: \(error)")
      }
    }
    let resolved: ProviderResolvedInputArtifact?
    var resolvedArtifactLeaseID: String?
    let leaseInputName: String?
    let artifactLabel: String
    switch descriptor.reference {
    case "debug.hap@1":
      leaseInputName = "hapArtifactLease"
      artifactLabel = "HAP"
    case "deploy.native-library.app-owned@1":
      leaseInputName = "libraryArtifactLease"
      artifactLabel = "native library"
    case let reference where ArkForgeFlashOperation.contains(reference):
      leaseInputName =
        reference == ArkForgeFlashOperation.canonicalReference
        ? "artifactLease" : "imageBundleLease"
      artifactLabel = "flash bundle"
    case "workspace.apply-patch@1":
      leaseInputName = "patchArtifactRef"
      artifactLabel = "workspace patch"
    case "workspace.symbolize-crash@1":
      leaseInputName = "dumpArtifactRef"
      artifactLabel = "workspace crash dump"
    case OpenHarmonyLocalSigning.operationReference:
      leaseInputName = "unsignedHapArtifactLease"
      artifactLabel = "unsigned HAP"
    case "analyzer.extract-crash-signature@1", "analyzer.summarize-hilog@1",
      "analyzer.summarize-trace@1", "analyzer.analyze-trace@1":
      leaseInputName = "sourceArtifactRef"
      artifactLabel = "analyzer source artifact"
    default:
      leaseInputName = nil
      artifactLabel = "input"
    }
    if let leaseInputName {
      guard let artifactStore,
        case .string(let lease)? = request.inputs[leaseInputName]
      else {
        throw RuntimeJobEngineError.rejected(
          .invalidInput,
          "\(descriptor.reference) requires a configured Artifact lease store")
      }
      do {
        let artifact = try await artifactStore.resolveLease(lease)
        try Self.validateArtifactBinding(
          artifact.bindingSnapshot, request: request,
          materializedStableIdentitySHA256: facts?.deviceIdentitySHA256,
          allowDeviceBoundHostSource: Self.consumesTargetScopedHostArtifact(
            provider: descriptor.provider.rawValue,
            reference: descriptor.reference))
        resolved = ProviderResolvedInputArtifact(
          artifactID: artifact.artifactID, fileURL: artifact.fileURL,
          sha256: artifact.sha256, byteCount: artifact.byteCount)
        resolvedArtifactLeaseID = lease
      } catch {
        throw RuntimeJobEngineError.rejected(
          .invalidInput, "\(artifactLabel) Artifact lease is not resolvable: \(error)")
      }
    } else {
      resolved = nil
      resolvedArtifactLeaseID = nil
    }
    // Multi-package: the additional leases are resolved and bound-checked
    // here too, so a lease belonging to another target is refused before
    // authorization — no capability is consumed and nothing reaches the
    // device (CHG-2026-049 r4).
    var additionalResolved: [ProviderResolvedInputArtifact] = []
    if descriptor.reference == "debug.hap@1",
      case .array(let rawLeases)? = request.inputs["additionalHapArtifactLeases"],
      !rawLeases.isEmpty
    {
      guard let artifactStore else {
        throw RuntimeJobEngineError.rejected(
          .invalidInput, "additional HAP leases require a configured Artifact lease store")
      }
      for value in rawLeases {
        guard case .string(let lease) = value else {
          throw RuntimeJobEngineError.rejected(
            .invalidInput, "additionalHapArtifactLeases must be artifact leases")
        }
        do {
          let artifact = try await artifactStore.resolveLease(lease)
          try Self.validateArtifactBinding(
            artifact.bindingSnapshot, request: request,
            materializedStableIdentitySHA256: facts?.deviceIdentitySHA256)
          additionalResolved.append(
            ProviderResolvedInputArtifact(
              artifactID: artifact.artifactID, fileURL: artifact.fileURL,
              sha256: artifact.sha256, byteCount: artifact.byteCount))
        } catch {
          throw RuntimeJobEngineError.rejected(
            .invalidInput, "additional HAP Artifact lease is not resolvable: \(error)")
        }
      }
    }
    do {
      let runtimeDebugPermit = try RuntimeDebugAttemptPermitStore.loadExact(
        stateDirectory: configuration.stateDirectory, request: request,
        nowUTC: nowUTC())
      var materializedSteps: [MaterializedPlanStep] = []
      for step in selectedSteps {
        switch step.kind {
        case .preflightHostStorage, .postprocessArtifact, .finalizeSession, .hashFile,
          .verifyArtifact, .requestConfirmation:
          materializedSteps.append(
            MaterializedPlanStep(
              stepID: step.stepID, kind: step.kind.rawValue,
              effect: step.effect.rawValue, cancellation: step.cancellation.rawValue,
              binding: step.binding.rawValue, isOptional: step.isOptional,
              journalArguments: nil, processKind: "engine",
              executableSHA256: nil, argumentZero: nil, workingDirectory: nil,
              argumentSummary: nil,
              processInvocations: nil, timeoutSeconds: nil,
              hostManagedDescriptor: nil))
          continue
        default:
          break
        }
        let context = ProviderExecutionContext(
          jobID: jobID, stepID: step.stepID,
          targetID: request.target.targetID,
          bindingRevision: request.target.expectedBindingRevision,
          connectKey: facts?.executionConnectKey,
          expectedIdentitySHA256: facts?.deviceIdentitySHA256,
          toolVersion: facts?.toolVersion,
          toolSHA256: facts?.toolSHA256,
          serverFacts: facts?.serverFacts ?? [:],
          nowUTC: nowUTC(), resolvedInputArtifact: resolved,
          additionalInputArtifacts: additionalResolved,
          expectedRuntimeBuildVersion: declaredRuntimeBuildVersion(
            for: descriptor, artifact: resolved,
            artifactLeaseID: resolvedArtifactLeaseID))
        // Steps arkforged performs have no ArkDeck action to ask for — that
        // lowering was removed in CHG-2026-059 — so they are materialized
        // directly. The step set, its effect, its cancellation class and its
        // journalled arguments are unchanged (AFA-REQ-004); what changes is
        // only who performs it, and the plan digest records that rather than
        // hiding it.
        if Self.arkForgeDispatchedSteps.contains(step.stepID) {
          guard let toolchainSHA256 = configuration.arkForgeToolchainSHA256 else {
            throw RuntimeJobEngineError.rejected(
              .invalidInput,
              "\(descriptor.reference) is runtime unavailable: ArkForge lane is not configured")
          }
          let workflowStep = try Self.journalStep(
            for: step, jobID: context.jobID, inputs: implementationInputs,
            action: nil, resolvedInputArtifact: resolved,
            operationReference: implementationDescriptor.reference)
          materializedSteps.append(
            MaterializedPlanStep(
              stepID: step.stepID, kind: step.kind.rawValue,
              effect: step.effect.rawValue, cancellation: step.cancellation.rawValue,
              binding: step.binding.rawValue, isOptional: step.isOptional,
              journalArguments: workflowStep.arguments,
              processKind: Self.arkForgeDispatchKind,
              executableSHA256: nil, argumentZero: nil, workingDirectory: nil,
              argumentSummary: nil, processInvocations: nil, timeoutSeconds: nil,
              // Names the toolchain the permit will be bound to. A plan
              // materialized for one tool and executed against another is a
              // maturity combination nobody published, and the daemon refuses
              // it at startExecution — this is so the digest disagrees first.
              hostManagedDescriptor: Self.arkForgeStepPermitDescriptor(
                toolchainSHA256: toolchainSHA256)))
          continue
        }
        let action = try provider.action(
          for: step, operation: implementationDescriptor, inputs: implementationInputs,
          context: context)
        guard action.effect == step.effect else {
          throw RuntimeJobEngineError.internalFailure(
            "\(step.stepID) action effect \(action.effect.rawValue) "
              + "does not match catalog \(step.effect.rawValue)")
        }
        let plan = try provider.lower(action: action, context: context)
        guard plan.action == action else {
          throw RuntimeJobEngineError.internalFailure(
            "\(step.stepID) lowering returned a plan for a different typed action")
        }
        let workflowStep = try Self.journalStep(
          for: step, jobID: context.jobID, inputs: implementationInputs,
          action: action, resolvedInputArtifact: resolved,
          operationReference: implementationDescriptor.reference)
        switch plan.kind {
        case .process(let executableSHA256, let argumentSummary, let timeoutSeconds):
          materializedSteps.append(
            MaterializedPlanStep(
              stepID: step.stepID, kind: step.kind.rawValue,
              effect: step.effect.rawValue, cancellation: step.cancellation.rawValue,
              binding: step.binding.rawValue, isOptional: step.isOptional,
              journalArguments: workflowStep.arguments, processKind: "process",
              executableSHA256: executableSHA256,
              argumentZero: plan.argumentZero,
              workingDirectory: plan.workingDirectory,
              argumentSummary: argumentSummary, processInvocations: nil,
              timeoutSeconds: timeoutSeconds,
              hostManagedDescriptor: nil))
        case .processSequence(let executableSHA256, let invocations):
          materializedSteps.append(
            MaterializedPlanStep(
              stepID: step.stepID, kind: step.kind.rawValue,
              effect: step.effect.rawValue, cancellation: step.cancellation.rawValue,
              binding: step.binding.rawValue, isOptional: step.isOptional,
              journalArguments: workflowStep.arguments, processKind: "processSequence",
              executableSHA256: executableSHA256, argumentZero: plan.argumentZero,
              workingDirectory: plan.workingDirectory,
              argumentSummary: nil,
              processInvocations: invocations.map {
                MaterializedProcessInvocation(
                  arguments: $0.arguments,
                  timeoutSeconds: $0.timeoutSeconds,
                  continueAfterNonZero: $0.continueAfterNonZero)
              },
              timeoutSeconds: nil, hostManagedDescriptor: nil))
        case .hostManaged(let descriptor):
          materializedSteps.append(
            MaterializedPlanStep(
              stepID: step.stepID, kind: step.kind.rawValue,
              effect: step.effect.rawValue, cancellation: step.cancellation.rawValue,
              binding: step.binding.rawValue, isOptional: step.isOptional,
              journalArguments: workflowStep.arguments, processKind: "hostManaged",
              executableSHA256: descriptor.providerExecutableSHA256,
              argumentZero: nil, workingDirectory: nil,
              argumentSummary: nil, processInvocations: nil,
              timeoutSeconds: nil,
              hostManagedDescriptor:
                "\(descriptor.identifier)#action-sha256:\(descriptor.actionSHA256)"))
        case .hostWorkspace(let descriptor):
          materializedSteps.append(
            MaterializedPlanStep(
              stepID: step.stepID, kind: step.kind.rawValue,
              effect: step.effect.rawValue, cancellation: step.cancellation.rawValue,
              binding: step.binding.rawValue, isOptional: step.isOptional,
              journalArguments: workflowStep.arguments, processKind: "hostWorkspace",
              executableSHA256: nil,
              argumentZero: nil, workingDirectory: nil,
              argumentSummary: nil, processInvocations: nil,
              timeoutSeconds: nil,
              hostManagedDescriptor:
                "\(descriptor.identifier)#action-sha256:\(descriptor.actionSHA256)"))
        }
      }
      if descriptor.reference == "deploy.native-library.app-owned@1" {
        guard
          let publishStep = descriptor.steps.first(where: {
            $0.stepID == "atomic-publish"
          })
        else {
          throw RuntimeJobEngineError.internalFailure(
            "native deployment catalog has no atomic publish step")
        }
        // Device-bound by declaration, so facts exist here; state it rather
        // than force-unwrapping, so a future host-only operation reaching this
        // block fails closed instead of trapping.
        guard let facts else {
          throw RuntimeJobEngineError.internalFailure(
            "\(descriptor.reference) requires device facts to materialize its rollback")
        }
        let rollbackStep = CatalogStepDescriptor(
          stepID: "rollback-native-library",
          kind: .runApprovedRemoteMutation,
          effect: .deviceMutation,
          cancellation: .atSafeBoundary,
          binding: .confirmedDevice,
          isOptional: false,
          compensation: .none)
        let context = ProviderExecutionContext(
          jobID: jobID, stepID: rollbackStep.stepID,
          targetID: request.target.targetID,
          bindingRevision: request.target.expectedBindingRevision,
          connectKey: facts.executionConnectKey,
          expectedIdentitySHA256: facts.deviceIdentitySHA256,
          toolVersion: facts.toolVersion,
          toolSHA256: facts.toolSHA256,
          serverFacts: facts.serverFacts,
          nowUTC: nowUTC(), resolvedInputArtifact: resolved,
          expectedRuntimeBuildVersion: declaredRuntimeBuildVersion(
            for: descriptor, artifact: resolved,
            artifactLeaseID: resolvedArtifactLeaseID))
        let publishAction = try provider.action(
          for: publishStep, operation: descriptor, inputs: request.inputs,
          context: context)
        guard let deployment = Self.nativeDeployment(from: publishAction) else {
          throw RuntimeJobEngineError.internalFailure(
            "native deployment provider did not materialize its rollback payload")
        }
        let rollbackAction =
          TypedProviderAction.hdc(.rollbackNativeLibrary(deployment))
        let rollbackPlan = try provider.lower(
          action: rollbackAction, context: context)
        guard rollbackPlan.action == rollbackAction else {
          throw RuntimeJobEngineError.internalFailure(
            "native rollback lowering returned a different typed action")
        }
        let workflowStep = try Self.journalStep(
          for: rollbackStep, jobID: context.jobID, inputs: request.inputs,
          action: rollbackAction, resolvedInputArtifact: resolved,
          operationReference: descriptor.reference)
        guard
          case .processSequence(
            let executableSHA256, let invocations) = rollbackPlan.kind
        else {
          throw RuntimeJobEngineError.internalFailure(
            "native rollback did not lower to an exact process sequence")
        }
        materializedSteps.append(
          MaterializedPlanStep(
            stepID: rollbackStep.stepID, kind: rollbackStep.kind.rawValue,
            effect: rollbackStep.effect.rawValue,
            cancellation: rollbackStep.cancellation.rawValue,
            binding: rollbackStep.binding.rawValue,
            isOptional: rollbackStep.isOptional,
            journalArguments: workflowStep.arguments,
            processKind: "processSequence",
            executableSHA256: executableSHA256,
            argumentZero: rollbackPlan.argumentZero,
            workingDirectory: rollbackPlan.workingDirectory, argumentSummary: nil,
            processInvocations: invocations.map {
              MaterializedProcessInvocation(
                arguments: $0.arguments,
                timeoutSeconds: $0.timeoutSeconds,
                continueAfterNonZero: $0.continueAfterNonZero)
            },
            timeoutSeconds: nil, hostManagedDescriptor: nil))
      }
      let stableIdentity: String?
      let bindingRevision: Int?
      if let facts {
        guard let identity = facts.deviceIdentitySHA256, let revision = facts.bindingRevision
        else {
          throw RuntimeJobEngineError.internalFailure(
            "validated target facts lost identity or binding revision")
        }
        stableIdentity = identity
        bindingRevision = revision
      } else {
        // Host-only: nothing to bind, and nothing is claimed.
        stableIdentity = nil
        bindingRevision = nil
      }
      let document = MaterializedPlanDocument(
        operationReference: implementationDescriptor.reference,
        catalogDigest: RuntimeOperationCatalog.catalogDigest,
        inputs: implementationInputs,
        targetID: request.target.targetID,
        stableTargetIdentitySHA256: stableIdentity,
        bindingRevision: bindingRevision,
        providerID: implementationDescriptor.provider.rawValue,
        runtimeDebugInvocationID: runtimeDebugPermit?.invocationID,
        runtimeDebugCandidateActionSHA256: runtimeDebugPermit?.candidateActionSHA256,
        steps: materializedSteps)
      let encoder = CanonicalJSONEncoders.canonical()
      let encoded = try encoder.encode(document)
      return MaterializedAdmission(
        stableTargetIdentitySHA256: stableIdentity,
        bindingRevision: bindingRevision,
        planDigest: RuntimeJobRecord.sha256Hex(encoded),
        artifactFacts: resolved.map {
          [
            "artifactId": $0.artifactID,
            "artifactSha256": $0.sha256,
            "artifactByteCount": String($0.byteCount),
          ]
        } ?? [:],
        providerFacts: facts)
    } catch let error as RuntimeJobEngineError {
      throw error
    } catch {
      throw RuntimeJobEngineError.rejected(
        .invalidInput, "typed plan preflight failed before authorization: \(error)")
    }
  }

  private func validateSupportedPlanInputs(
    _ inputs: [String: JSONValue],
    descriptor: CatalogOperationDescriptor
  ) throws {
    if descriptor.reference == AnalyzerProvider.traceAnalysis {
      do {
        _ = try AnalyzerProvider.analysisRequest(inputs)
      } catch {
        throw RuntimeJobEngineError.rejected(
          .invalidInput,
          "ArkTrace analysis request violates its closed cross-field contract")
      }
      return
    }
    if descriptor.reference == "capture.diagnostics@1" {
      // The trace leg used to be refused here because neither half of its
      // verification existed. Both are published now: `capture-trace` is
      // judged by a device-side `ls -l` readback of the file hitrace was
      // asked to write, and `receive-trace-artifact` by the size/SHA-256 of
      // the bytes that landed on the host. Neither can reach `.verified`
      // without evidence, and an unrecognised landing leaves the job
      // outstanding for reconcile rather than publishing something false —
      // which is what makes running it before the DHA-HW device window
      // honest rather than optimistic. DHA-CAP-001 specifies this
      // orchestration; the E1 capability, not this refusal, is what gates
      // the device mutation.
      if inputs["bundleName"] == nil,
        ["abilityName", "processName", "expectedDeployedArtifactDigest"].contains(where: {
          inputs[$0] != nil
        })
      {
        throw RuntimeJobEngineError.rejected(
          .invalidInput,
          "application liveness fields require bundleName; refusing before authorization")
      }
      return
    }
  }

  /// Builds the single authorization subject used by drafting, submit-time
  /// validation and dispatch-time revalidation. Keeping the device/workspace
  /// split in one place prevents the operator draft surface from lagging the
  /// admission surface again (TASK-HFA-009 r3).
  private func authorizationQuery(
    request: RuntimeOperationRequest,
    descriptor: CatalogOperationDescriptor,
    effect: WorkflowEffect,
    materialized: MaterializedAdmission
  ) throws -> RuntimeCapabilityAuthorizationQuery {
    if let identity = materialized.stableTargetIdentitySHA256,
      let bindingRevision = materialized.bindingRevision
    {
      return RuntimeCapabilityAuthorizationQuery(
        operationID: descriptor.id,
        operationVersion: descriptor.version,
        effect: effect,
        // Decided from the request, once, and carried. Both this site and the
        // consume below have to reach the same answer from the same inputs,
        // or the fingerprint they compute will not be the same fingerprint.
        sessionScoped: Self.isSessionScoped(descriptor: descriptor, inputs: request.inputs),
        targetStableIdentitySHA256: identity,
        targetBindingRevision: bindingRevision,
        // The digest travels even for a session-scoped subject: the consume
        // record has to say which exact plan each individual use authorized.
        // What the session scope drops is the digest's influence on *which*
        // capability record the gesture lands on, and that is decided in the
        // scope fingerprint, not here.
        planDigest: materialized.planDigest,
        inputs: Self.sessionScopedAuthorizationSubject(
          descriptor: descriptor, inputs: request.inputs),
        artifactFacts: materialized.artifactFacts)
    }

    // A workspace mutation above read-only has no device to name. The
    // provider owns the tree identity, current revision and maximum writable
    // scopes; an absent fact is a refusal, never a generic host grant.
    guard let provider = providers.provider(id: descriptor.provider.rawValue),
      let workspace = try provider.workspaceAuthorizationFacts(
        for: descriptor, inputs: request.inputs)
    else {
      throw RuntimeJobEngineError.rejected(
        .authorizationRequired,
        "\(descriptor.reference) has neither a device binding nor workspace facts "
          + "to authorize effect \(effect.rawValue)")
    }
    return RuntimeCapabilityAuthorizationQuery(
      operationID: descriptor.id,
      operationVersion: descriptor.version,
      effect: effect,
      targetStableIdentitySHA256: nil,
      targetBindingRevision: nil,
      planDigest: materialized.planDigest,
      inputs: request.inputs,
      artifactFacts: materialized.artifactFacts,
      workspaceIdentitySHA256: workspace.identitySHA256,
      workspaceRevision: workspace.revision,
      workspaceFileScopesDigest: workspace.fileScopesDigest,
      workspaceIsIsolatedTaskCopy: workspace.isolatedTaskCopy)
  }

  /// Performs every pure authorization check at submit, after the complete
  /// typed plan has materialized. Published mutation/destructive operations
  /// with Runtime issuance enabled receive a deterministic Runtime-owned
  /// capability. Mutation uses are deliberately not consumed here:
  /// the job's descriptor-bound preflight must first execute through the
  /// durable write-ahead journal. Consumption happens at the last safe
  /// boundary immediately before the first mutation dispatch.
  private func preauthorize(
    request: RuntimeOperationRequest,
    descriptor: CatalogOperationDescriptor,
    effect: WorkflowEffect,
    materialized: MaterializedAdmission
  ) async throws -> PreparedAuthorization {
    let admittedAt = nowUTC()
    // Before anything is authorized: is somebody else already working this
    // device? A refusal here is the whole point of the check - queueing the
    // request would be safe and silent, and silence is what a diagnostic
    // session cannot survive.
    try admitAgainstDeviceHold(
      request: request, descriptor: descriptor, effect: effect,
      deviceIdentity: materialized.stableTargetIdentitySHA256)
    if request.campaignReservation != nil {
      throw RuntimeJobEngineError.rejected(
        .authorizationRequired,
        "legacy campaign reservations are decode/export-only and cannot admit a new execution")
    }
    if effect <= .readOnly {
      guard descriptor.authorization[effect] == .defaultReadOnly else {
        throw RuntimeJobEngineError.rejected(
          .authorizationRequired,
          "catalog has no default read-only policy for \(descriptor.reference)")
      }
      let decision = configuration.defaultReadOnlyPolicy.evaluate(
        effect: effect,
        timeoutSeconds: descriptor.timeoutSeconds,
        outputByteBudget: descriptor.outputByteBudget)
      guard decision == .allowed else {
        throw RuntimeJobEngineError.rejected(
          .authorizationRequired, "default read-only policy denied: \(decision)")
      }
      return PreparedAuthorization(
        reference: request.authorization,
        evidence: RuntimeAdmissionEvidence(
          kind: .defaultReadOnlyPolicy,
          reference: "default-read-only-policy",
          admittedAtUTC: admittedAt,
          validUntilUTC: nil,
          consumptionFingerprintSHA256: nil),
        completeOverwriteRecovery: nil,
        recognizedRecoveryEpochID: nil)
    }

    guard let policy = descriptor.authorization[effect] else {
      throw RuntimeJobEngineError.rejected(
        .authorizationRequired,
        "catalog has no authorization policy for effect \(effect.rawValue)")
    }
    if let facts = materialized.providerFacts,
      let provider = providers.provider(id: descriptor.provider.rawValue),
      let blocker = provider.executionAdmissionBlocker(
        for: descriptor, facts: facts)
    {
      throw RuntimeJobEngineError.rejected(
        .authorizationRequired,
        "provider execution prerequisite blocked before capability issuance: \(blocker)")
    }
    let query = try authorizationQuery(
      request: request, descriptor: descriptor,
      effect: effect, materialized: materialized)

    let recoveryAdmission: RuntimeCompleteOverwriteAdmissionResult
    if effect == .destructive {
      guard let identity = materialized.stableTargetIdentitySHA256,
        let bindingRevision = materialized.bindingRevision
      else {
        throw RuntimeJobEngineError.rejected(
          .authorizationRequired,
          "complete-overwrite admission requires stable target identity and binding")
      }
      do {
        recoveryAdmission = try await RuntimeRecoveryService(
          stateDirectory: configuration.stateDirectory,
          capabilityStore: capabilityStore,
          nowUTC: nowUTC
        ).completeOverwriteAdmission(
          request: request, descriptor: descriptor,
          stableIdentitySHA256: identity, bindingRevision: bindingRevision)
      } catch let error as RuntimeCompleteOverwriteRecoveryError {
        throw RuntimeJobEngineError.rejected(
          .authorizationRequired,
          "non-overridable recovery blocker: \(error)")
      }
    } else {
      recoveryAdmission = .noRecovery
    }

    let authorization: RuntimeCapabilityReference
    if policy == .runtimeCapability {
      try RuntimeCallerAuthorityBoundary.validate(
        policy: policy, hasCallerSuppliedAuthorization: request.authorization != nil)
      guard descriptor.defaultPolicyIssuanceEnabled else {
        throw RuntimeJobEngineError.rejected(
          .authorizationRequired,
          "catalog disabled Runtime capability issuance for \(descriptor.reference)")
      }
      authorization = try await automaticRuntimeCapability(
        descriptor: descriptor, query: query,
        recoveryContext: recoveryAdmission.recoveryContext)
    } else if let supplied = request.authorization {
      authorization = supplied
    } else if effect == .deviceMutation,
      policy == .standingCapability,
      // Two automatic lanes, and the line between them is who owns the thing
      // being changed.
      //
      // A device is shared and physical: the catalog decides per operation
      // whether the runtime may issue for it at all.
      //
      // A workspace that is a *task-owned isolated copy* is neither. Nothing
      // in it reaches the repository except through a promotion a person
      // merges, so requiring a separately issued grant per copy adds a human
      // step that guards a scratch directory while the real gate — the pull
      // request — stays exactly where it was. Worse, the grant has to name a
      // workspace that does not exist until the task creates it, so the step
      // can only ever happen mid-run, and a task that is resubmitted needs
      // another one.
      //
      // A workspace a person works in is still off limits: that one keeps
      // requiring a grant issued against this tree, this revision and these
      // writable scopes (CHG-2026-055 TASK-HFA-009 r2, HTP-INV-6).
      query.workspaceIdentitySHA256 == nil
        ? descriptor.defaultPolicyIssuanceEnabled
        : query.workspaceIsIsolatedTaskCopy
    {
      authorization = try await automaticRuntimeCapability(
        descriptor: descriptor, query: query,
        recoveryContext: recoveryAdmission.recoveryContext)
    } else {
      throw RuntimeJobEngineError.rejected(
        .authorizationRequired,
        "effect \(effect.rawValue) requires an explicit runtime capability")
    }
    do {
      try await capabilityStore.validateNewExecution(
        capabilityID: authorization.capabilityID,
        query: query,
        nowUTC: nowUTC())
      return PreparedAuthorization(
        reference: authorization, evidence: nil,
        completeOverwriteRecovery: recoveryAdmission.recoveryContext,
        recognizedRecoveryEpochID: recoveryAdmission.recognizedEpoch?.epochID)
    } catch let error as RuntimeCapabilityStoreError {
      throw RuntimeJobEngineError.rejected(
        .authorizationRequired,
        "capability denied \(Self.capabilityDenialMarker)\(Self.denialCode(of: error))]: "
          + "\(error)")
    }
  }

  /// Opens the machine-readable half of a capability rejection message, closed
  /// by `]`. External callers parse it as a machine token from the refusal;
  /// the two planes are deliberately decoupled and cannot share a constant, so
  /// a contract test pins them to each other instead.
  static let capabilityDenialMarker = "[denial:"

  /// Why the capability layer refused *this* execution, as a stable
  /// identifier. `"\(error)"` alone carries the reason only inside Swift's
  /// reflected description, which is an implementation detail and not a
  /// contract — so a caller wanting the reason must scrape prose, and a caller
  /// that declines to scrape reports every refusal as the same generic
  /// "authorization required". Only decisions are named: a store that could
  /// not be read is an environment fault, not a verdict on the grant.
  static func denialCode(of error: RuntimeCapabilityStoreError) -> String {
    switch error {
    case .denied(let denial): return denial.reason.rawValue
    case .lineageBlocked: return "lineageBlocked"
    case .capabilityNotFound: return "capabilityNotFound"
    case .capabilityAlreadyInstalled, .reservationConflict, .outcomeConflict,
      .storeCorrupted, .ioFailure:
      return "unclassified"
    }
  }

  /// Resolves the published Runtime policy into a durable capability envelope.
  /// The identifier is stable for the catalog, operation, target, binding and
  /// typed inputs, so daemon restart preserves lineage and an outcomeUnknown
  /// use blocks later automatic execution of the same mutation scope.
  private func automaticRuntimeCapability(
    descriptor: CatalogOperationDescriptor,
    query: RuntimeCapabilityAuthorizationQuery,
    recoveryContext: RuntimeCompleteOverwriteRecoveryContext?
  ) async throws -> RuntimeCapabilityReference {
    let issuedAtUTC = nowUTC()
    let sessionScoped = query.sessionScoped
    guard
      let expiresAtUTC = Self.automaticCapabilityExpiry(
        issuedAtUTC: issuedAtUTC, effect: query.effect, sessionScoped: sessionScoped)
    else {
      throw RuntimeJobEngineError.rejected(
        .authorizationRequired,
        "automatic Runtime policy cannot verify the runtime clock")
    }
    do {
      try await validateNoUnresolvedMutationLineage(
        stableIdentitySHA256: query.targetStableIdentitySHA256 ?? "",
        bindingRevision: query.targetBindingRevision ?? 0,
        reservationID: nil,
        jobID: nil,
        recoveryContext: recoveryContext)
    } catch let error as RuntimeCapabilityStoreError {
      throw RuntimeJobEngineError.rejected(
        .authorizationRequired,
        "automatic Runtime target lineage is blocked: \(error)")
    }
    let policyFingerprint = Self.automaticCapabilityPolicyFingerprint(
      query: query, recoveryContext: recoveryContext)

    // Destructive envelopes are one-shot. A failed use advances only when
    // provider outcome/readback durably classified it safeToReflash. Known
    // unsafe failure and unknown lineage return the exhausted envelope so the
    // normal store validation fails closed. Success starts a later invocation;
    // a safe continuation stays within sixteen serial uses and four hours.
    var destructiveAttemptCount = 0
    var destructiveInvocationStartedAt: Date?
    let admittedDate = ISO8601Timestamps.parse(issuedAtUTC)
    for generation in 1...100_000 {
      let capabilityID =
        "CAP-RT-POLICY-\(policyFingerprint.prefix(40))-G\(generation)"
      if let existing = try await capabilityStore.inspect(
        capabilityID: capabilityID)
      {
        if query.effect == .destructive {
          if existing.remainingUses > 0,
            existing.capability.expiresAtUTC > issuedAtUTC,
            existing.lineageAllowsNewExecution
          {
            return RuntimeCapabilityReference(capabilityID: capabilityID)
          }
          guard let terminal = existing.lineage.last?.outcomeHistory.last else {
            // An unused expired generation may roll to a fresh short-lived
            // envelope. It has no intent and therefore no replay ambiguity.
            continue
          }
          switch terminal.outcome {
          case .pending, .outcomeUnknown:
            return RuntimeCapabilityReference(capabilityID: capabilityID)
          case .confirmed:
            // A confirmed terminal closes this generation and lets the next one
            // open. Four states qualify, and the last two were each found by
            // the same denial on a bench.
            //
            // `succeeded` and `recovered` are the obvious ones. `cancelled` is
            // the third: a confirmed-cancelled job is one the engine proved did
            // not dispatch — `outcomeUnknown` is false, which is a stronger
            // statement than `succeeded` makes, since a job that succeeded at
            // least wrote something. Withholding rollover from it does not
            // protect a device; it strands the lineage.
            //
            // Measured 2026-08-17: a DAYU200 flash was cancelled after
            // refusing at the lane, having written nothing. It reconciled to
            // `outcome: confirmed, terminalState: cancelled`, and from then on
            // every destructive attempt on that policy was answered
            // `capability denied [denial:exhausted]` — the cancellation had
            // permanently closed the lane it was supposed to leave open.
            //
            // `failed` is the fourth, by the same argument from the other
            // side: a *confirmed* failure is one whose recorder vouched the
            // device state is known (`outcomeUnknown` is false — a genuinely
            // ambiguous write arrives as `.outcomeUnknown` below and is
            // refused). What follows a known failure is a fresh attempt under
            // a fresh generation; refusing that does not protect the device,
            // it just answers every retry `denial:exhausted` forever.
            // Measured 2026-08-18, where exactly that had wedged the bench.
            //
            // An unconfirmed cancellation is untouched: it arrives as
            // `.pending` or `.outcomeUnknown` above and still returns the spent
            // capability, because a write whose outcome is unknown must not be
            // replayed.
            guard
              terminal.terminalState == JobState.succeeded.rawValue
                || terminal.terminalState == JobState.recovered.rawValue
                || terminal.terminalState == JobState.cancelled.rawValue
                || terminal.terminalState == JobState.failed.rawValue
            else {
              return RuntimeCapabilityReference(capabilityID: capabilityID)
            }
            destructiveAttemptCount = 0
            destructiveInvocationStartedAt = nil
            continue
          case .safeToReflash:
            let generationStart = ISO8601Timestamps.parse(
              existing.capability.issuedAtUTC)
            if destructiveInvocationStartedAt == nil {
              destructiveInvocationStartedAt = generationStart
            }
            if let admittedDate, let invocationStart = destructiveInvocationStartedAt,
              admittedDate.timeIntervalSince(invocationStart) > 4 * 60 * 60
            {
              // The prior invocation is durably closed by expiry. A fresh
              // request starts a new bounded window and will re-read all facts.
              destructiveAttemptCount = 0
              destructiveInvocationStartedAt = nil
              continue
            }
            destructiveAttemptCount += 1
            guard destructiveAttemptCount < 16 else {
              return RuntimeCapabilityReference(capabilityID: capabilityID)
            }
            continue
          }
        }
        // A spent generation is skipped so the next one is created; a revoked
        // lineage is not.
        //
        // These are different facts and only one of them is a person's answer.
        // Exhaustion and expiry mean this bounded window closed — the policy's
        // whole shape is one window per destructive attempt, since
        // `maximumUses` is 1 whenever the plan digest is pinned. Revocation
        // means somebody withdrew the lineage, and rolling that forward would
        // reissue what they withdrew.
        //
        // This used to read `lineageAllowsNewExecution && (spent || expired)`,
        // which could never hold for an exhausted capability: exhausting it is
        // exactly what clears `lineageAllowsNewExecution`
        // (`lineageBlocker: maximumUses exhausted`). So the engine returned the
        // spent capability instead of rolling over, and every destructive
        // operation after the first was refused with
        // `capability denied [denial:exhausted]` — measured 2026-08-17, where
        // it stopped a DAYU200 flash whose first attempt had written nothing.
        let spent =
          existing.remainingUses == 0
          || existing.capability.expiresAtUTC <= issuedAtUTC
        let revoked: Bool = {
          if case .revoked = existing.capability.revocation { return true }
          return false
        }()
        if spent && !revoked {
          continue
        }
        return RuntimeCapabilityReference(capabilityID: capabilityID)
      }

      let capability: RuntimeCapability
      // The envelope is scoped to whatever this plan actually addresses. A
      // workspace plan carries no device identity, so scoping it by one would
      // pin the empty string and match nothing.
      let targetScope: RuntimeCapabilityTargetScope
      if let workspaceIdentity = query.workspaceIdentitySHA256 {
        targetScope = .workspaceIdentity(
          sha256: workspaceIdentity,
          expectedWorkspaceRevision: query.workspaceRevision ?? "",
          allowedFileScopesDigest: query.workspaceFileScopesDigest ?? "")
      } else {
        targetScope = .stablePhysicalIdentity(
          sha256: query.targetStableIdentitySHA256 ?? "")
      }
      let pinsExactPlan =
        query.effect == .destructive
        || descriptor.authorization[query.effect] == .runtimeCapability
      do {
        capability = try RuntimeCapability(
          capabilityID: capabilityID,
          targetScope: targetScope,
          operationScope: [
            RuntimeCapabilityOperationScope(
              operationID: descriptor.id, version: descriptor.version)
          ],
          effectCeiling: query.effect,
          inputConstraints: Self.exactCapabilityConstraints(for: query.inputs),
          exactInputs: query.inputs,
          exactArtifactFacts: query.effect == .destructive ? query.artifactFacts : nil,
          issuedAtUTC: issuedAtUTC,
          expiresAtUTC: expiresAtUTC,
          maximumUses: pinsExactPlan
            ? 1 : (sessionScoped ? Self.sessionScopedInputMaximumUses : 10_000),
          issuer: RuntimeCapabilityIssuer(
            kind: .runtimeDefaultPolicy,
            reference:
              "catalog:\(RuntimeOperationCatalog.catalogDigest):\(descriptor.reference)"),
          exactPlanDigest: pinsExactPlan ? query.planDigest : nil,
          exactBindingRevision: query.targetBindingRevision)
      } catch {
        throw RuntimeJobEngineError.rejected(
          .authorizationRequired,
          "automatic Runtime policy could not create a bounded capability: \(error)")
      }
      do {
        try await capabilityStore.install(capability)
      } catch let error as RuntimeCapabilityStoreError {
        throw RuntimeJobEngineError.rejected(
          .authorizationRequired,
          "automatic Runtime capability could not become durable: \(error)")
      }
      return RuntimeCapabilityReference(capabilityID: capabilityID)
    }
    throw RuntimeJobEngineError.rejected(
      .authorizationRequired,
      "automatic Runtime capability generations are exhausted")
  }

  private static func automaticCapabilityPolicyFingerprint(
    query: RuntimeCapabilityAuthorizationQuery,
    recoveryContext: RuntimeCompleteOverwriteRecoveryContext?
  ) -> String {
    let scopeFingerprint = authorizationScopeFingerprint(of: query)
    let recoveryFingerprint =
      recoveryContext.map {
        "\($0.uncertainEffectSetSHA256)\n\($0.coverageContractVersion)\n"
          + "\($0.coveredEffectSetSHA256)\n\($0.destructiveEpochOrdinal)"
      } ?? "ordinary"
    return RuntimeJobRecord.sha256Hex(
      Data(
        "\(RuntimeOperationCatalog.catalogDigest)\n\(scopeFingerprint)\n"
          .appending(recoveryFingerprint).utf8)
    ).uppercased()
  }

  /// Prevents a caller from bypassing an unknown mutation by changing typed
  /// inputs and therefore selecting a different automatic capability scope.
  /// A crash-recovered pending reservation may continue only for its exact
  /// original Job; outcomeUnknown nodes never do.
  private func validateNoUnresolvedMutationLineage(
    stableIdentitySHA256: String,
    bindingRevision: Int,
    reservationID: String?,
    jobID: String?,
    recoveryContext: RuntimeCompleteOverwriteRecoveryContext? = nil
  ) async throws {
    let epochs = try await RuntimeSupersedingRecoveryStore(
      stateDirectory: configuration.stateDirectory
    ).list()
    let supersededJobIDs = Set(
      epochs.filter {
        $0.stableTargetIdentitySHA256 == stableIdentitySHA256
          && $0.bindingRevision == bindingRevision
      }.flatMap { $0.coveredIntents.map(\.jobID) }
    )
    .union(recoveryContext.map { Set($0.coveredIntents.map(\.jobID)) } ?? [])
    for status in try await capabilityStore.list() {
      for entry in status.lineage
      where entry.targetStableIdentitySHA256 == stableIdentitySHA256
        && entry.bindingRevision == bindingRevision
        && entry.outcome != .confirmed
        && entry.outcome != .safeToReflash
      {
        if supersededJobIDs.contains(entry.jobID) { continue }
        if entry.outcome == .pending,
          entry.reservationID == reservationID,
          entry.jobID == jobID
        {
          continue
        }
        throw RuntimeCapabilityStoreError.lineageBlocked(
          "target binding has unresolved capability \(status.capability.capabilityID) "
            + "use \(entry.ordinal) outcome \(entry.outcome.rawValue)")
      }
    }
  }

  private func freshCompleteOverwriteRecoveryProof(
    runtime: JobRuntime,
    descriptor: CatalogOperationDescriptor,
    effect: WorkflowEffect,
    validatedFacts: ProviderFacts?,
    deviceLineage: (identity: String, bindingRevision: Int)?
  ) async throws -> (
    context: RuntimeCompleteOverwriteRecoveryContext?, providerSHA256: String?
  ) {
    guard effect == .destructive, descriptor.completeOverwriteRecovery != nil else {
      return (nil, nil)
    }
    guard let facts = validatedFacts,
      let identity = facts.deviceIdentitySHA256,
      let bindingRevision = facts.bindingRevision,
      identity == deviceLineage?.identity,
      bindingRevision == deviceLineage?.bindingRevision,
      Self.isLowercaseSHA256(facts.toolSHA256),
      !facts.toolVersion.isEmpty,
      facts.deviceMode != nil
    else {
      throw RuntimeDispatchFailure.failed(
        "completeOverwriteRecovery.freshTargetTopologyOrToolMissing")
    }
    let admission: RuntimeCompleteOverwriteAdmissionResult
    do {
      admission = try await RuntimeRecoveryService(
        stateDirectory: configuration.stateDirectory,
        capabilityStore: capabilityStore,
        nowUTC: nowUTC
      ).completeOverwriteAdmission(
        request: runtime.record.request, descriptor: descriptor,
        stableIdentitySHA256: identity, bindingRevision: bindingRevision)
    } catch let error as RuntimeCompleteOverwriteRecoveryError {
      throw RuntimeDispatchFailure.failed(
        "non-overridable recovery blocker: \(error)")
    }
    guard let context = admission.recoveryContext else { return (nil, nil) }
    guard admission.recognizedEpoch == nil else {
      throw RuntimeDispatchFailure.failed(
        "completeOverwriteRecovery.freshProofDrifted")
    }
    return (context, facts.toolSHA256)
  }

  private func consumeCapabilityBeforeMutation(
    jobID: String,
    descriptor: CatalogOperationDescriptor,
    effect: WorkflowEffect,
    validatedFacts: ProviderFacts?
  ) async throws {
    var runtime = try refreshedRuntimeAtCancellationSafeBoundary(
      jobID: jobID,
      reason: "client-cancel before capability verification")
    let persistedEvidence = runtime.record.admissionEvidence
    if let evidence = persistedEvidence {
      guard
        evidence.kind == .runtimeCapability,
        evidence.reference == runtime.record.request.authorization?.capabilityID
      else {
        throw RuntimeDispatchFailure.failed(
          "authorizationRequired: persisted admission evidence does not match the mutation")
      }
    }
    if runtime.record.request.campaignReservation != nil {
      throw RuntimeDispatchFailure.failed(
        "authorizationRequired: legacy campaign records cannot dispatch a new mutation")
    }
    guard let authorization = runtime.record.request.authorization else {
      throw RuntimeDispatchFailure.failed(
        "authorizationRequired: mutation has no runtime capability reference")
    }
    guard let planDigest = runtime.record.materializedPlanDigest,
      Self.isLowercaseSHA256(planDigest)
    else {
      throw RuntimeDispatchFailure.failed(
        "authorizationRequired: materialized plan or verified target binding is absent or drifted")
    }
    // Re-materialize the entire typed plan immediately before the external
    // effect. This re-reads the immutable Artifact lease, target/binding/tool
    // facts and Runtime-owned debug tuning. A candidate digest never stands
    // in for this proof, and a changed lowering cannot consume the admitted
    // capability merely because the earlier plan digest is still persisted.
    let freshMaterialized: MaterializedAdmission
    do {
      freshMaterialized = try await materializeTypedPlanBeforeAuthorization(
        request: runtime.record.request,
        descriptor: descriptor,
        jobID: Self.authorizationPlanJobID)
    } catch {
      throw RuntimeDispatchFailure.failed(
        "authorizationRequired: fresh typed plan could not be materialized: \(error)")
    }
    runtime = try refreshedRuntimeAtCancellationSafeBoundary(
      jobID: jobID,
      reason: "client-cancel after mutation plan materialization")
    guard freshMaterialized.planDigest == planDigest,
      freshMaterialized.stableTargetIdentitySHA256
        == runtime.record.materializedStableTargetIdentitySHA256,
      freshMaterialized.bindingRevision == runtime.record.materializedBindingRevision
    else {
      throw RuntimeDispatchFailure.failed(
        "authorizationRequired: fresh typed plan, target or binding drifted before dispatch")
    }
    let resolvedArtifact = try await resolvedInputArtifact(jobID: jobID)
    runtime = try refreshedRuntimeAtCancellationSafeBoundary(
      jobID: jobID,
      reason: "client-cancel after Artifact lease resolution")
    let artifactFacts: [String: String] =
      resolvedArtifact.map {
        [
          "artifactId": $0.artifactID,
          "artifactSha256": $0.sha256,
          "artifactByteCount": String($0.byteCount),
        ]
      } ?? [:]
    // The subject is re-established here, at the moment of the effect, not
    // trusted from admission. A device mutation re-proves identity and
    // binding; a workspace mutation re-reads the tree, so a workspace that
    // moved between admission and dispatch is caught here rather than
    // changed anyway (CHG-2026-055, TASK-HFA-009 r2).
    let query: RuntimeCapabilityAuthorizationQuery
    var deviceLineage: (identity: String, bindingRevision: Int)?
    if descriptor.binding == .confirmedDevice {
      guard
        let stableIdentity = runtime.record.materializedStableTargetIdentitySHA256,
        Self.isLowercaseSHA256(stableIdentity),
        let bindingRevision = runtime.record.materializedBindingRevision,
        bindingRevision > 0,
        runtime.record.request.target.expectedBindingRevision == bindingRevision,
        validatedFacts?.targetID == runtime.record.request.target.targetID,
        validatedFacts?.bindingRevision == bindingRevision,
        validatedFacts?.deviceIdentitySHA256 == stableIdentity,
        validatedFacts?.providerID == descriptor.provider.rawValue
      else {
        throw RuntimeDispatchFailure.failed(
          "authorizationRequired: materialized plan or verified target binding is absent or drifted"
        )
      }
      deviceLineage = (stableIdentity, bindingRevision)
      query = RuntimeCapabilityAuthorizationQuery(
        operationID: descriptor.id,
        operationVersion: descriptor.version,
        effect: effect,
        sessionScoped: Self.isSessionScoped(
          descriptor: descriptor, inputs: runtime.record.request.inputs),
        targetStableIdentitySHA256: stableIdentity,
        targetBindingRevision: bindingRevision,
        planDigest: planDigest,
        inputs: Self.sessionScopedAuthorizationSubject(
          descriptor: descriptor, inputs: runtime.record.request.inputs),
        artifactFacts: artifactFacts)
    } else {
      guard let provider = providers.provider(id: descriptor.provider.rawValue),
        let workspace = try provider.workspaceAuthorizationFacts(
          for: descriptor, inputs: runtime.record.request.inputs)
      else {
        throw RuntimeDispatchFailure.failed(
          "authorizationRequired: no workspace subject to authorize this mutation against")
      }
      query = RuntimeCapabilityAuthorizationQuery(
        operationID: descriptor.id,
        operationVersion: descriptor.version,
        effect: effect,
        targetStableIdentitySHA256: nil,
        targetBindingRevision: nil,
        planDigest: planDigest,
        inputs: runtime.record.request.inputs,
        artifactFacts: artifactFacts,
        workspaceIdentitySHA256: workspace.identitySHA256,
        workspaceRevision: workspace.revision,
        workspaceFileScopesDigest: workspace.fileScopesDigest,
        workspaceIsIsolatedTaskCopy: workspace.isolatedTaskCopy)
    }
    do {
      let liveRecovery = try await freshCompleteOverwriteRecoveryProof(
        runtime: runtime, descriptor: descriptor, effect: effect,
        validatedFacts: validatedFacts, deviceLineage: deviceLineage)
      runtime = try refreshedRuntimeAtCancellationSafeBoundary(
        jobID: jobID,
        reason: "client-cancel after complete-overwrite proof")
      if let evidence = persistedEvidence {
        guard evidence.completeOverwriteRecovery == liveRecovery.context else {
          throw RuntimeDispatchFailure.failed(
            "completeOverwriteRecovery.freshProofDrifted")
        }
        if let recovery = liveRecovery.context {
          guard
            runtime.record.state == JobState.running.rawValue
              || runtime.record.state == JobState.recoveringByCompleteOverwrite.rawValue
          else {
            throw RuntimeDispatchFailure.failed(
              "completeOverwriteRecovery.invalidPersistedState")
          }
          if runtime.record.state == JobState.running.rawValue {
            try transition(
              &runtime, from: .running, to: .recoveringByCompleteOverwrite,
              reason:
                "resume distinct complete-overwrite capability; original intents not replayed")
            runtime.record.timeline.append(
              "recovery coverage \(recovery.coveredEffectSetSHA256) for "
                + "\(recovery.coveredIntents.count) unknown intent(s)")
            try persistRuntimeRecord(runtime.record)
            jobs[jobID] = runtime
          }
        } else if runtime.record.state == JobState.recoveringByCompleteOverwrite.rawValue {
          throw RuntimeDispatchFailure.failed(
            "completeOverwriteRecovery.persistedContextMissing")
        }
        return
      }
      if let deviceLineage {
        // Cross-Job lineage is checked once, before authority consumption.
        // Persisted evidence means this exact Job already owns that use; its
        // journal-confirmed reconcile continuation must not be mistaken for a
        // second mutation Job.
        try await validateNoUnresolvedMutationLineage(
          stableIdentitySHA256: deviceLineage.identity,
          bindingRevision: deviceLineage.bindingRevision,
          reservationID: runtime.record.request.idempotencyKey,
          jobID: jobID,
          recoveryContext: liveRecovery.context)
        runtime = try refreshedRuntimeAtCancellationSafeBoundary(
          jobID: jobID,
          reason: "client-cancel after mutation-lineage validation")
      }
      guard
        let status = try await capabilityStore.inspect(
          capabilityID: authorization.capabilityID)
      else {
        throw RuntimeCapabilityStoreError.capabilityNotFound(authorization.capabilityID)
      }
      runtime = try refreshedRuntimeAtCancellationSafeBoundary(
        jobID: jobID,
        reason: "client-cancel after capability inspection")
      if status.capability.issuer.kind == .runtimeDefaultPolicy {
        let fingerprint = Self.automaticCapabilityPolicyFingerprint(
          query: query, recoveryContext: liveRecovery.context)
        guard
          authorization.capabilityID.hasPrefix(
            "CAP-RT-POLICY-\(fingerprint.prefix(40))-G")
        else {
          throw RuntimeDispatchFailure.failed(
            "completeOverwriteRecovery.freshProofDrifted")
        }
      }
      if let hook = configuration.testHooks.beforeMutationCapabilityCommit {
        await hook(jobID)
      }
      runtime = try refreshedRuntimeAtCancellationSafeBoundary(
        jobID: jobID,
        reason: "client-cancel at final capability-consumption boundary")
      let consumption = try await capabilityStore.consume(
        capabilityID: authorization.capabilityID,
        reservationID: runtime.record.request.idempotencyKey,
        jobID: jobID,
        query: query,
        nowUTC: nowUTC())
      let targetBindingDigest = RuntimeJobRecord.sha256Hex(
        Data(
          "\(query.targetStableIdentitySHA256 ?? "-")\n"
            .appending("\(query.targetBindingRevision.map(String.init) ?? "-")").utf8))
      let correlation = RuntimeCapabilityEvidenceCorrelation(
        reservationID: consumption.reservationID,
        useOrdinal: consumption.ordinal,
        planDigestSHA256: planDigest,
        stepSetDigestSHA256: Self.stepSetDigest(
          descriptor: descriptor, inputs: runtime.record.request.inputs),
        targetBindingDigestSHA256: targetBindingDigest,
        artifactSHA256: artifactFacts["artifactSha256"])
      var admissionEvidence = RuntimeAdmissionEvidence(
        kind: .runtimeCapability,
        reference: authorization.capabilityID,
        admittedAtUTC: consumption.consumedAtUTC,
        validUntilUTC: status.capability.expiresAtUTC,
        consumptionFingerprintSHA256: consumption.queryFingerprintSHA256,
        runtimeCapabilityCorrelation: correlation)
      admissionEvidence.completeOverwriteRecovery = liveRecovery.context
      admissionEvidence.recoveryProviderExecutableSHA256 = liveRecovery.providerSHA256
      guard let latestAfterConsumption = jobs[jobID] else {
        throw RuntimeJobEngineError.jobNotFound(jobID)
      }
      runtime = latestAfterConsumption
      runtime.record.admissionEvidence = admissionEvidence
      runtime.record.timeline.append(
        "capability consumed before first mutation")
      // The consumed authority and its exact recovery proof become durable
      // before the recovery-only state is entered. A restart can therefore
      // re-prove and resume this boundary without replaying old intent.
      jobs[jobID] = runtime
      try persistRuntimeRecord(runtime.record)
      if cancellationRequests.contains(jobID)
        || runtime.record.state == JobState.cancelRequested.rawValue
      {
        try completeCancellationAtSafeBoundary(
          jobID: jobID, baseline: runtime, step: nil, intentEventID: nil,
          reason: "client-cancel after durable capability consumption but before dispatch")
        throw RuntimeHostDispatchCancellation()
      }
      if let recovery = liveRecovery.context {
        try transition(
          &runtime, from: .running, to: .recoveringByCompleteOverwrite,
          reason: "distinct complete-overwrite capability reserved; original intents not replayed")
        runtime.record.timeline.append(
          "recovery coverage \(recovery.coveredEffectSetSHA256) for "
            + "\(recovery.coveredIntents.count) unknown intent(s)")
        try persistRuntimeRecord(runtime.record)
        jobs[jobID] = runtime
      }
    } catch is RuntimeHostDispatchCancellation {
      throw RuntimeHostDispatchCancellation()
    } catch let error as RuntimeCapabilityStoreError {
      throw RuntimeDispatchFailure.failed(
        "authorizationRequired: capability denied before mutation: \(error)")
    } catch let failure as RuntimeDispatchFailure {
      throw failure
    } catch {
      throw RuntimeDispatchFailure.failed(
        "authorizationRequired: capability admission could not become durable: \(error)")
    }
  }

  /// Completes terminal bookkeeping for a campaign reservation persisted by
  /// an older release. New requests carrying these references are rejected
  /// before admission and cannot reach dispatch. Write-once with racer grace:
  /// an existing terminal from recovery or a concurrent closer stands.
  private func closeHistoricalCampaignReservation(
    for record: RuntimeJobRecord,
    outcome: RuntimeCapabilityUseOutcome,
    state: String
  ) async throws {
    guard let evidence = record.admissionEvidence,
      evidence.kind == .evolutionCampaignConfirmation,
      let ledger = agentUsageLedger
    else { return }
    let status: AuthorizationUsageTerminalStatus
    switch outcome {
    case .confirmed:
      status = state == JobState.succeeded.rawValue ? .succeeded : .failed
    case .safeToReflash:
      status = .failed
    case .outcomeUnknown:
      status = .outcomeUnknown
    case .pending:
      return
    }
    let intents = try mutationIntentEvidence(
      for: record.jobID, operationReference: record.operationReference)
    do {
      _ = try ledger.close(
        reservationID: evidence.reference,
        terminal: try AgentAuthorityUsageTerminal(
          status: status, closedAt: nowUTC(),
          externalIntentEventIDs: intents.all,
          confirmedNotExecutedIntentEventIDs: intents.confirmedNotExecuted,
          completedIntentEventIDs: intents.completed))
    } catch AuthorizationUsageLedgerError.reservationConflict {
      let existing = try? ledger.load().reservations.first {
        $0.reservationID == evidence.reference
      }
      guard existing?.terminal != nil else {
        throw RuntimeJobEngineError.internalFailure(
          "historical reservation race left no terminal on \(evidence.reference)")
      }
    } catch let error as AuthorizationUsageLedgerError {
      throw RuntimeJobEngineError.internalFailure(
        "historical reservation lineage could not become durable: \(error)")
    }
  }

  /// The mutating intents this job durably journaled — what a historical
  /// reservation terminal must carry.
  ///
  /// Three resolutions per intent: journaled at all (`all`), proven not to
  /// have happened (`confirmedNotExecuted`), and completed with its own
  /// verified outcome (`completed`). A step whose truth is delegated to a
  /// paired readback journals a succeeded outcome at dispatch, before
  /// anything proved the effect — so those steps are excluded from
  /// `completed` no matter what their outcome row says: their completion is
  /// only as good as the readback, and the readback may legitimately have
  /// been skipped.
  private func mutationIntentEvidence(
    for jobID: String, operationReference: String
  ) throws -> (all: [String], confirmedNotExecuted: [String], completed: [String]) {
    let journalURL = jobDirectory(for: jobID).appending(path: "journal.jsonl")
    let replay: JournalReplay
    do {
      replay = try DurableJournalRecovery.inspect(url: journalURL)
    } catch {
      throw RuntimeJobEngineError.internalFailure(
        "historical reservation journal is unavailable for \(jobID): \(error)")
    }
    var identifiers: [String] = []
    var stepIDByIntent: [String: String] = [:]
    for event in replay.events where event.kind == .stepIntent {
      guard let step = event.workflowStep, step.effect >= .deviceMutation else { continue }
      identifiers.append(event.eventID)
      if let stepID = event.stepID {
        stepIDByIntent[event.eventID] = stepID
      }
    }
    let confirmed = Set(
      replay.events.compactMap { event -> String? in
        guard event.kind == .stepOutcome,
          event.payload["semanticCode"]
            == .string(Self.confirmedNotExecutedSemanticCode)
        else { return nil }
        return event.correlatedIntentEventID
      })
    let succeeded = Set(
      replay.events.compactMap { event -> String? in
        guard event.kind == .stepOutcome,
          event.payload["result"] == .string("succeeded")
        else { return nil }
        return event.correlatedIntentEventID
      })
    let readbackDelegated = Set((Self.readbackPairs[operationReference] ?? [:]).keys)
    let completed = identifiers.filter { intentID in
      guard succeeded.contains(intentID), !confirmed.contains(intentID),
        let stepID = stepIDByIntent[intentID]
      else { return false }
      return !readbackDelegated.contains(stepID)
    }
    return (identifiers, identifiers.filter(confirmed.contains), completed)
  }

  private func recordCapabilityOutcome(
    for record: RuntimeJobRecord,
    outcome: RuntimeCapabilityUseOutcome,
    state: String
  ) async throws {
    if record.admissionEvidence?.kind == .evolutionCampaignConfirmation {
      try await closeHistoricalCampaignReservation(
        for: record, outcome: outcome, state: state)
      return
    }
    guard let evidence = record.admissionEvidence,
      evidence.kind == .runtimeCapability || evidence.kind == .standingAuthorization
    else {
      return
    }
    do {
      try await capabilityStore.recordOutcome(
        capabilityID: evidence.reference,
        reservationID: record.request.idempotencyKey,
        jobID: record.jobID,
        outcome: outcome,
        terminalState: state,
        atUTC: nowUTC())
    } catch let error as RuntimeCapabilityStoreError {
      throw RuntimeJobEngineError.internalFailure(
        "authorization lineage could not become durable: \(error)")
    }
  }

  private func validateInputs(
    _ inputs: [String: JSONValue], against descriptor: CatalogOperationDescriptor
  ) throws {
    let fieldTable = Dictionary(
      uniqueKeysWithValues: descriptor.inputs.map { ($0.name, $0) })
    for field in descriptor.inputs where field.isRequired {
      guard inputs[field.name] != nil else {
        throw RuntimeJobEngineError.rejected(
          .invalidInput, "required input \(field.name) is absent")
      }
    }
    for (key, value) in inputs {
      guard let field = fieldTable[key] else {
        throw RuntimeJobEngineError.rejected(
          .invalidInput, "input \(key) is not declared by \(descriptor.reference)")
      }
      let matches: Bool
      switch (field.type, value) {
      case (.string, .string), (.artifactLease, .string), (.artifactReference, .string):
        matches = true
      case (.integer, .integer), (.integer, .unsignedInteger):
        matches = true
      case (.boolean, .bool):
        matches = true
      case (.stringArray, .array(let items)), (.artifactLeaseArray, .array(let items)):
        matches = items.allSatisfy {
          if case .string = $0 { return true }
          return false
        }
      default:
        matches = false
      }
      guard matches else {
        throw RuntimeJobEngineError.rejected(
          .invalidInput, "input \(key) has the wrong type for \(descriptor.reference)")
      }
      if let allowed = field.enumValues, case .string(let raw) = value,
        !allowed.contains(raw)
      {
        throw RuntimeJobEngineError.rejected(
          .invalidInput, "input \(key) value is outside its enum")
      }
      switch value {
      case .string(let text):
        if let maximum = field.maxLength, text.utf8.count > maximum {
          throw RuntimeJobEngineError.rejected(
            .invalidInput, "input \(key) exceeds maxLength \(maximum)")
        }
        if let pattern = field.pattern,
          text.range(of: pattern, options: .regularExpression) == nil
        {
          throw RuntimeJobEngineError.rejected(
            .invalidInput, "input \(key) does not match its catalog pattern")
        }
      case .array(let values):
        if let maximum = field.maxItems, values.count > maximum {
          throw RuntimeJobEngineError.rejected(
            .invalidInput, "input \(key) exceeds maxItems \(maximum)")
        }
        if let maximum = field.maxLength {
          for case .string(let item) in values where item.utf8.count > maximum {
            throw RuntimeJobEngineError.rejected(
              .invalidInput, "input \(key) contains an item exceeding maxLength \(maximum)")
          }
        }
        // A pattern declared on an array field used to apply to nothing: only
        // the scalar branch read it. That is a trap for whoever declares one,
        // because the catalog says the values are constrained and the runtime
        // admits anything. It constrains each item, which is the only reading
        // a per-item `maxLength` on the same field already had.
        if let pattern = field.pattern {
          for case .string(let item) in values
          where item.range(of: pattern, options: .regularExpression) == nil {
            throw RuntimeJobEngineError.rejected(
              .invalidInput, "input \(key) contains an item outside its catalog pattern")
          }
        }
      case .integer(let raw):
        try validateInteger(raw, field: field)
      case .unsignedInteger(let raw):
        guard let signed = Int64(exactly: raw) else {
          throw RuntimeJobEngineError.rejected(
            .invalidInput, "input \(key) is outside the supported integer range")
        }
        try validateInteger(signed, field: field)
      default:
        break
      }
    }
  }

  private func validateInteger(_ raw: Int64, field: CatalogFieldDescriptor) throws {
    if let minimum = field.minimum, raw < Int64(minimum) {
      throw RuntimeJobEngineError.rejected(
        .invalidInput, "input \(field.name) is below minimum \(minimum)")
    }
    if let maximum = field.maximum, raw > Int64(maximum) {
      throw RuntimeJobEngineError.rejected(
        .invalidInput, "input \(field.name) exceeds maximum \(maximum)")
    }
  }

  private func transition(
    _ runtime: inout JobRuntime,
    from: JobState,
    to: JobState,
    reason: String,
    triggerEventID: String? = nil
  ) throws {
    try runtime.journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "t-\(runtime.nextSequence)", sequence: runtime.nextSequence,
        sessionID: runtime.record.sessionID, jobID: runtime.record.jobID,
        timestamp: nowUTC(), from: from, to: to, reason: reason,
        triggerEventID: triggerEventID,
        schemaVersion: Self.journalSchemaVersion(of: runtime.record)))
    runtime.nextSequence += 1
    runtime.record.state = to.rawValue
    runtime.record.timeline.append("\(from.rawValue)->\(to.rawValue)")
    runtime.record.timeline.append("reason: \(reason)")
    jobs[runtime.record.jobID] = runtime
  }

  private func appendTimeline(jobID: String, entry: String) {
    guard var runtime = jobs[jobID] else { return }
    runtime.record.timeline.append(entry)
    jobs[jobID] = runtime
  }

  private func recordProcessProgress(
    _ progress: RuntimeProcessProgress,
    jobID: String,
    stepID: String
  ) {
    let key = ProcessProgressKey(jobID: jobID, stepID: stepID)
    guard activeProcessProgressKeys.contains(key),
      progress.totalUnitCount > 0,
      progress.completedUnitCount >= 0,
      progress.completedUnitCount <= progress.totalUnitCount,
      progress.currentUnitPercent.map({ (0...100).contains($0) }) ?? true,
      progress.unitName.map(Self.isSafeProgressUnitName) ?? true,
      shouldAcceptProcessProgress(progress, after: latestProcessProgress[key]),
      var runtime = jobs[jobID]
    else { return }

    latestProcessProgress[key] = progress
    var fields = [
      "progress", stepID, "phase=\(progress.phase.rawValue)",
      "completed=\(progress.completedUnitCount)",
      "total=\(progress.totalUnitCount)",
    ]
    if let unitName = progress.unitName { fields.append("unit=\(unitName)") }
    if let percent = progress.currentUnitPercent { fields.append("percent=\(percent)") }
    let entry = fields.joined(separator: " ")
    let prefix = "progress \(stepID) "
    if runtime.record.timeline.last?.hasPrefix(prefix) == true {
      runtime.record.timeline[runtime.record.timeline.count - 1] = entry
    } else {
      runtime.record.timeline.append(entry)
    }
    jobs[jobID] = runtime
    // Live progress is observational. A transient status-persistence failure
    // must never interrupt an already-dispatched destructive child; the
    // durable outer intent/outcome path remains unchanged and authoritative.
    try? persistRuntimeRecord(runtime.record)
  }

  private func shouldAcceptProcessProgress(
    _ progress: RuntimeProcessProgress,
    after previous: RuntimeProcessProgress?
  ) -> Bool {
    guard let previous else { return true }
    if previous.phase == .staging { return progress.phase == .writing }
    guard progress.phase == .writing,
      progress.totalUnitCount == previous.totalUnitCount,
      progress.completedUnitCount >= previous.completedUnitCount
    else { return false }
    if progress.completedUnitCount > previous.completedUnitCount { return true }
    if progress.unitName == previous.unitName {
      return (progress.currentUnitPercent ?? 0) >= (previous.currentUnitPercent ?? 0)
    }
    return previous.currentUnitPercent == 100
  }

  private static func isSafeProgressUnitName(_ value: String) -> Bool {
    !value.isEmpty
      && value.utf8.allSatisfy {
        (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
          || $0 == 45 || $0 == 46 || $0 == 95
      }
  }

  private func jobDirectory(for jobID: String) -> URL {
    configuration.stateDirectory
      .appending(path: "jobs", directoryHint: .isDirectory)
      .appending(path: jobID, directoryHint: .isDirectory)
  }

  private func persistRuntimeRecord(_ record: RuntimeJobRecord) throws {
    try record.persist(into: jobDirectory(for: record.jobID))
    try admissionService.persist(record, at: nowUTC())
  }

  private func persistArkForgeRuntimeJobState(
    _ state: ArkForgeRuntimeJobState, jobID: String
  ) throws {
    try state.persist(into: jobDirectory(for: jobID))
  }

  /// Terminal jobs have no further dispatch or recovery path.  Their durable
  /// record and SQLite row remain queryable, so retaining a FileDurableJournal
  /// and detailed runtime projection in the daemon only makes memory grow with
  /// history.  Outcome-unknown jobs are deliberately excluded: they remain
  /// active until an explicit reconciliation reaches a certain terminal state.
  private func statusAndReleaseTerminalRuntime(
    _ record: RuntimeJobRecord,
    recoveryEpochID: String? = nil
  ) -> RuntimeJobStatus {
    let jobStatus = status(of: record, recoveryEpochID: recoveryEpochID)
    if !record.outcomeUnknown, JobState(rawValue: record.state)?.isTerminal == true {
      jobs.removeValue(forKey: record.jobID)
      cancellationRequests.remove(record.jobID)
    }
    return jobStatus
  }

  private func statusAndReleaseTerminalRuntime(
    _ record: RuntimeJobRecord,
    recoveryEpochID: String? = nil,
    provider: any DeviceProvider
  ) -> RuntimeJobStatus {
    if !record.outcomeUnknown, JobState(rawValue: record.state)?.isTerminal == true {
      provider.cleanupTerminalJob(jobID: record.jobID)
    }
    return statusAndReleaseTerminalRuntime(record, recoveryEpochID: recoveryEpochID)
  }

  /// Terminal history is read from its durable SQLite projection after the
  /// in-memory runtime has been released.  A missing or malformed projection
  /// is never guessed at as a status because doing so could hide an unknown
  /// external-effect outcome.
  private func recordForRead(jobID: String) throws -> RuntimeJobRecord {
    if let runtime = jobs[jobID] { return runtime.record }
    let persisted: RuntimePersistedJob?
    do {
      persisted = try admissionService.job(jobID: jobID)
    } catch {
      throw RuntimeJobEngineError.internalFailure(
        "Runtime job history index is unreadable for \(jobID): \(error)")
    }
    guard let persisted else { throw RuntimeJobEngineError.jobNotFound(jobID) }
    return try decodePersistedRecord(persisted)
  }

  private func decodePersistedRecord(_ persisted: RuntimePersistedJob) throws -> RuntimeJobRecord {
    guard let data = persisted.initialRecordData,
      let record = try? JSONDecoder().decode(RuntimeJobRecord.self, from: data),
      record.jobID == persisted.jobID
    else {
      throw RuntimeJobEngineError.jobRecordUnreadable(persisted.jobID)
    }
    return record
  }

  private func status(
    of record: RuntimeJobRecord,
    supersededByRecoveryEpochID: String? = nil,
    recoveryEpochID: String? = nil,
    resolvedByTargetAliasResolutionID: String? = nil
  ) -> RuntimeJobStatus {
    RuntimeJobStatus(
      jobID: record.jobID,
      operationReference: record.operationReference,
      targetID: record.request.target.targetID,
      state: record.state,
      // Uncertain effects are resolved by Runtime proof. Eligible recovery is
      // automatic; ineligible recovery is a non-overridable diagnostic, never
      // a request for approval.
      waitingForHuman: false,
      outcomeUnknown: record.outcomeUnknown,
      operationFailure: Self.projectedOperationFailure(for: record),
      outstandingResidueCount: record.outstandingResidueCount,
      timeline: record.timeline,
      processProgress: liveProcessProgress(for: record.jobID),
      executionMode: "execute",
      sessionID: record.sessionID,
      threadID: record.request.clientContext?.threadID,
      workspaceKind: RuntimeWorkspaceKindProjection.kind(
        forOperation: record.operationReference,
        inputs: record.request.inputs,
        clientName: record.request.clientContext?.clientName),
      actualEffect: record.actualEffect,
      createdAtUTC: record.createdAtUTC,
      startedAtUTC: record.startedAtUTC,
      finishedAtUTC: record.finishedAtUTC,
      supersededByRecoveryEpochID: supersededByRecoveryEpochID,
      recoveryEpochID: recoveryEpochID,
      resolvedByTargetAliasResolutionID: resolvedByTargetAliasResolutionID)
  }

  private static func projectedOperationFailure(
    for record: RuntimeJobRecord
  ) -> RuntimeOperationFailure? {
    if let failure = record.operationFailure { return failure }
    if record.outcomeUnknown || record.state == JobState.waitingForRecovery.rawValue {
      return RuntimeOperationFailure(
        code: .outcomeUnknown, category: .unknownOutcome,
        retryability: .runtimeDecisionRequired,
        recovery: .awaitRuntimeReconciliation)
    }
    switch JobState(rawValue: record.state) {
    case .failed:
      return RuntimeOperationFailure(
        code: .legacyFailure, category: .runtime,
        retryability: .runtimeDecisionRequired, recovery: .inspectJob)
    case .cancelled:
      return RuntimeOperationFailure(
        code: .cancelled, category: .cancelled,
        retryability: .notAutomatic, recovery: .none)
    case .interrupted:
      return RuntimeOperationFailure(
        code: .interrupted, category: .runtime,
        retryability: .runtimeDecisionRequired, recovery: .inspectJob)
    default:
      return nil
    }
  }

  private func liveProcessProgress(for jobID: String) -> RuntimeJobProcessProgress? {
    let active: [RuntimeJobProcessProgress] = latestProcessProgress.compactMap {
      key, progress in
      guard key.jobID == jobID, activeProcessProgressKeys.contains(key) else { return nil }
      return RuntimeJobProcessProgress(stepID: key.stepID, progress: progress)
    }
    // Runtime executes provider steps serially per Job. If that invariant is
    // ever broken, omit this observational projection instead of choosing an
    // arbitrary process and presenting misleading progress.
    return active.count == 1 ? active[0] : nil
  }

  private struct RecoveryEpochIndexes {
    var supersededByJobID: [String: String] = [:]
    var establishedByJobID: [String: String] = [:]
    var resolvedAliasByJobID: [String: String] = [:]
  }

  private func recoveryEpochIndexes() async -> RecoveryEpochIndexes {
    var indexes = RecoveryEpochIndexes()
    if let store = try? RuntimeSupersedingRecoveryStore(
      stateDirectory: configuration.stateDirectory),
      let epochs = try? await store.list()
    {
      for epoch in epochs {
        indexes.establishedByJobID[epoch.recoveryJobID] = epoch.epochID
        for intent in epoch.coveredIntents {
          indexes.supersededByJobID[intent.jobID] = epoch.epochID
        }
      }
    }
    if let targetStore = try? RuntimeTargetStore(
      directoryURL: configuration.stateDirectory.appending(
        path:
          "targets", directoryHint: .isDirectory)),
      let resolutions = try? targetStore.aliasResolutions()
    {
      for resolution in resolutions {
        for intent in resolution.coveredUnknownIntents {
          indexes.resolvedAliasByJobID[intent.jobID] = resolution.resolutionID
        }
      }
    }
    return indexes
  }

  private static func fingerprint(of data: Data) -> String {
    RuntimeJobRecord.sha256Hex(data)
  }

  private static func exactCapabilityConstraints(
    for inputs: [String: JSONValue]
  ) -> [String: RuntimeCapabilityInputConstraint] {
    var constraints: [String: RuntimeCapabilityInputConstraint] = [:]
    for (key, value) in inputs {
      switch value {
      case .string(let text):
        constraints[key] = .exactString(text)
      case .integer(let raw):
        if let exact = Int(exactly: raw) {
          constraints[key] = .integerRange(minimum: exact, maximum: exact)
        }
      case .unsignedInteger(let raw):
        if let exact = Int(exactly: raw) {
          constraints[key] = .integerRange(minimum: exact, maximum: exact)
        }
      case .number(let raw) where raw.isFinite && raw.rounded(.towardZero) == raw:
        if let exact = Int(exactly: raw) {
          constraints[key] = .integerRange(minimum: exact, maximum: exact)
        }
      default:
        break
      }
    }
    return constraints
  }

  /// Operations whose authorized subject is the control session, not the one
  /// gesture. The scope fingerprint hashes both `inputs` and the materialized
  /// plan digest, and both change with every pointer coordinate, so scoping a
  /// gesture individually mints one permanent capability record per screen
  /// position. Measured on the production store 2026-08-25: 318 records in a
  /// single 1.29 MB document that is rewritten whole on every issue and every
  /// consume, so an interactive session would degrade quadratically and never
  /// reclaim the records (chg-2026-071 evidence
  /// `TASK-IDC-002/data/capability-store-growth.json`).
  ///
  /// Reducing the subject to target + binding + gesture kind bounds the record
  /// count at three per bound device. It does not weaken what the runtime can
  /// prove about an individual input: every gesture still materializes its own
  /// plan, writes its own durable intent before dispatch, and records its own
  /// outcome, so intent-before-effect and the no-replay rule are untouched.
  static let sessionScopedInputOperations: Set<String> = [
    "input.tap@1", "input.long-press@1", "input.swipe@1",
  ]

  /// The two preflight fragments a session may carry rather than re-read.
  /// `confirm-evidence-target` is deliberately absent: it is the step that
  /// re-reads the device identity, it costs a host-side query rather than a
  /// device round trip, and it is what makes carrying the other two sound.
  static let sessionCarriableEvidenceStepIDs: Set<String> = [
    "read-evidence-model", "read-evidence-firmware",
  ]

  /// The legs a screenshot needs and nothing else.
  static let screenshotOnlyCaptureStepIDs: Set<String> = [
    "capture-screenshot", "receive-screenshot", "cleanup-screenshot-temp",
  ]

  /// Whether a request is one a control session owns.
  ///
  /// A gesture always is. A capture is only when the legs it chose to run are
  /// a screenshot and nothing else.
  ///
  /// Only optional steps are consulted, because a step that is not optional
  /// runs for the largest capture too and therefore distinguishes nothing.
  /// Reading the catalog's own selection rather than re-listing the inputs
  /// that turn legs on is what stops a new leg joining a session's envelope
  /// by being added to the operation - and a hand-kept list of the steps that
  /// always run is exactly the thing that goes stale. It already did: the
  /// first version of this omitted `postprocess-index` and refused every
  /// screenshot-only capture.
  static func isSessionScoped(
    descriptor: CatalogOperationDescriptor, inputs: [String: JSONValue]
  ) -> Bool {
    if sessionScopedInputOperations.contains(descriptor.reference) { return true }
    guard descriptor.reference == "capture.diagnostics@1" else { return false }
    var sawScreenshot = false
    for step in descriptor.steps where step.isOptional {
      guard CatalogOperationEffectResolver.stepIsSelected(
        step, descriptor: descriptor, inputs: inputs)
      else { continue }
      guard screenshotOnlyCaptureStepIDs.contains(step.stepID) else { return false }
      sawScreenshot = true
    }
    return sawScreenshot
  }

  /// Model and firmware, remembered from the readback that did reach the
  /// device, together with the identity they were read under.
  ///
  /// Neither property can change on a device that stays continuously
  /// connected: changing either requires a reboot or a reflash, which drops
  /// the connection. A gesture that re-confirms the same identity is
  /// therefore looking at the same device in the same state that answered
  /// these questions. If the identity differs, or the record has aged past
  /// the session lifetime, it is discarded and the device is asked again.
  struct CarriedDeviceEvidence: Sendable, Equatable {
    let stableIdentitySHA256: String
    let model: String
    let firmware: String
    let readAtUTC: String
  }

  /// Keyed by device, not by operation: a tap, a long press and a swipe in
  /// one session are the same person working on the same device, and the
  /// facts they would each re-read are identical.
  var carriedDeviceEvidence: [String: CarriedDeviceEvidence] = [:]

  /// Who is working this device right now.
  ///
  /// A session is one person with one device: they arm a capture, reproduce
  /// something, mark it, look at it. While that is happening, another client's
  /// mutation is not a queueing problem to be smoothed over - it is a second
  /// pair of hands on the same screen. The lane already serialises such things
  /// safely; what it cannot do is say so, and a gesture that lands silently in
  /// the middle of someone's capture is exactly what a diagnostic session
  /// cannot survive.
  struct DeviceSessionHold: Sendable, Equatable {
    let clientName: String
    let heldSinceUTC: String
    var lastActedUTC: String
  }

  /// How long a hold outlives its last act. A session is interactive; two
  /// minutes without one is somebody having walked away, and the device
  /// belongs to whoever asks next.
  package static let deviceSessionHoldIdleTimeout: TimeInterval = 120

  var deviceSessionHolds: [String: DeviceSessionHold] = [:]

  /// Records that this client is working the device, or refuses because
  /// somebody else is.
  ///
  /// Only a session-scoped request takes a hold. Ordinary work neither claims
  /// the device nor is refused for lack of a claim - it is refused only while
  /// somebody else's session is live.
  func admitAgainstDeviceHold(
    request: RuntimeOperationRequest,
    descriptor: CatalogOperationDescriptor,
    effect: WorkflowEffect,
    deviceIdentity: String?
  ) throws {
    guard let deviceIdentity, effect >= .deviceMutation else { return }
    let client = request.clientContext?.clientName ?? "anonymous"
    let now = nowUTC()
    if let held = deviceSessionHolds[deviceIdentity] {
      let expired =
        ISO8601Timestamps.parse(held.lastActedUTC).map { last in
          ISO8601Timestamps.parse(now).map {
            $0.timeIntervalSince(last) > Self.deviceSessionHoldIdleTimeout
          } ?? false
        } ?? true
      if expired {
        deviceSessionHolds[deviceIdentity] = nil
      } else if held.clientName != client {
        throw RuntimeJobEngineError.rejected(
          .deviceBusyBySession,
          "a control session opened by \(held.clientName) holds this device since "
            + "\(held.heldSinceUTC); it was not queued behind that session")
      }
    }
    guard Self.isSessionScoped(descriptor: descriptor, inputs: request.inputs) else { return }
    if var held = deviceSessionHolds[deviceIdentity], held.clientName == client {
      held.lastActedUTC = now
      deviceSessionHolds[deviceIdentity] = held
    } else {
      deviceSessionHolds[deviceIdentity] = DeviceSessionHold(
        clientName: client, heldSinceUTC: now, lastActedUTC: now)
    }
  }

  /// The window that matters for a received product belongs to the step that
  /// produced the file, not the one that fetched it.
  ///
  /// A screenshot is published by `receive-screenshot`, whose window is a file
  /// transfer - measured on the device at 91-118 ms, and once 781 ms. The
  /// shutter opened during `capture-screenshot`. Publishing the receive window
  /// as the shutter window would have been a precise-looking number for the
  /// wrong event, which is worse than the second-granularity value it replaced.
  func observationWindow(
    jobID: String, stepID: String, descriptor: CatalogOperationDescriptor
  ) -> ArtifactObservationWindow? {
    let producing = Self.optionalStepUpstream[descriptor.reference]?[stepID] ?? stepID
    return stepObservationWindows["\(jobID)|\(producing)"]
      ?? stepObservationWindows["\(jobID)|\(stepID)"]
  }

  /// When each step was reaching the device, keyed by job and step, so a
  /// product can say when it was observed rather than only when it was filed.
  var stepObservationWindows: [String: ArtifactObservationWindow] = [:]

  /// Reads one step's observed window. A seam for the test that pins which
  /// step's window a received product carries.
  package func observationWindowForTesting(
    jobID: String, stepID: String
  ) -> ArtifactObservationWindow? {
    stepObservationWindows["\(jobID)|\(stepID)"]
  }

  static func carriedEvidenceKey(stableIdentitySHA256: String, bindingRevision: Int) -> String {
    "\(stableIdentitySHA256)\n\(bindingRevision)"
  }

  /// The one place a complete accumulator becomes an exported observation, so
  /// a fresh preflight and a session-carried one cannot drift into describing
  /// themselves differently.
  static func evidenceObservation(
    from accumulator: RuntimeEvidencePreflightAccumulator
  ) -> RuntimeEvidenceObservation {
    let carried = accumulator.steps.contains { $0.carriedFromUTC != nil }
    return RuntimeEvidenceObservation(
      targetID: accumulator.targetID,
      bindingRevision: accumulator.bindingRevision,
      stableIdentitySHA256: accumulator.stableIdentitySHA256,
      model: accumulator.model,
      firmware: accumulator.firmware,
      transport: accumulator.transport,
      providerID: accumulator.providerID,
      toolVersion: accumulator.toolVersion,
      toolSHA256: accumulator.toolSHA256,
      confirmedAtUTC: accumulator.confirmedAtUTC,
      // A carried observation is not the same claim as a wholly fresh one and
      // does not get the same word. The hardware-evidence contract admits
      // only `machineReadback`, so naming this honestly is also what stops a
      // carried observation being projected as hardware evidence.
      confirmationMethod: carried ? "machineReadbackSessionCarried" : "machineReadback",
      preflightSteps: accumulator.steps)
  }

  /// Remembers a wholly fresh session-scoped readback so a later gesture may
  /// carry it. A run that already carried anything is not remembered again:
  /// the record must always trace back to a readback that reached the device.
  private func rememberCarriableEvidence(
    accumulator: RuntimeEvidencePreflightAccumulator,
    descriptor: CatalogOperationDescriptor,
    inputs: [String: JSONValue],
    outcomeAtUTC: String
  ) {
    guard Self.isSessionScoped(descriptor: descriptor, inputs: inputs),
      !accumulator.steps.contains(where: { $0.carriedFromUTC != nil }),
      let model = accumulator.model, let firmware = accumulator.firmware
    else { return }
    carriedDeviceEvidence[
      Self.carriedEvidenceKey(
        stableIdentitySHA256: accumulator.stableIdentitySHA256,
        bindingRevision: accumulator.bindingRevision)
    ] = CarriedDeviceEvidence(
      stableIdentitySHA256: accumulator.stableIdentitySHA256,
      model: model, firmware: firmware,
      readAtUTC: accumulator.confirmedAtUTC ?? outcomeAtUTC)
  }

  /// Answers one carriable preflight fragment from the session's own earlier
  /// readback instead of the device, saving a device round trip per gesture.
  /// Returns false whenever anything is missing or mismatched, and the step
  /// then runs against the device exactly as before.
  private func ingestCarriedEvidenceFragment(
    jobID: String, step: CatalogStepDescriptor,
    descriptor: CatalogOperationDescriptor
  ) -> Bool {
    guard Self.sessionCarriableEvidenceStepIDs.contains(step.stepID),
      var runtime = jobs[jobID],
      // Only a request a session owns may carry what the session read. Losing
      // this guard let every operation on the device skip its own model and
      // firmware readback - including ones whose evidence has to be a fresh
      // machine readback to mean anything.
      Self.isSessionScoped(descriptor: descriptor, inputs: runtime.record.request.inputs),
      var accumulator = runtime.record.evidencePreflight,
      // Nothing is carried into a job that has not re-read the identity for
      // itself. That readback is the entire reason carrying is sound, and it
      // has already thrown if the device answered with a different identity.
      accumulator.steps.contains(where: { $0.stepID == "confirm-evidence-target" }),
      let carried = carriedDeviceEvidence[
        Self.carriedEvidenceKey(
          stableIdentitySHA256: accumulator.stableIdentitySHA256,
          bindingRevision: accumulator.bindingRevision)],
      carried.stableIdentitySHA256 == accumulator.stableIdentitySHA256
    else { return false }
    let now = nowUTC()
    // Carried facts never outlive the session envelope that authorized the
    // gestures carrying them.
    guard let readAt = ISO8601Timestamps.parse(carried.readAtUTC),
      let current = ISO8601Timestamps.parse(now),
      case let age = current.timeIntervalSince(readAt),
      age >= 0, age < Self.sessionScopedInputLifetime
    else { return false }
    let expectedStepIDs = [
      "confirm-evidence-target", "read-evidence-model", "read-evidence-firmware",
    ]
    guard accumulator.steps.count < expectedStepIDs.count,
      expectedStepIDs[accumulator.steps.count] == step.stepID
    else { return false }
    if step.stepID == "read-evidence-model" {
      accumulator.model = carried.model
    } else {
      accumulator.firmware = carried.firmware
      accumulator.confirmedAtUTC = now
    }
    accumulator.steps.append(
      RuntimeEvidencePreflightStep(
        stepID: step.stepID, stepKind: step.kind.rawValue,
        outcomeAtUTC: now, carriedFromUTC: carried.readAtUTC))
    runtime.record.evidencePreflight = accumulator
    runtime.record.timeline.append(
      "evidence-preflight \(step.stepID) carried from session readback at \(carried.readAtUTC)")
    if accumulator.isComplete {
      runtime.record.evidenceObservation = Self.evidenceObservation(from: accumulator)
      runtime.record.timeline.append("evidence-preflight complete")
    }
    jobs[jobID] = runtime
    return true
  }

  /// The projection has to be applied identically where a capability is issued
  /// and where it is consumed, or the consume would look up an ID the issue
  /// never wrote. One helper serves both call sites for exactly that reason.
  static func sessionScopedAuthorizationSubject(
    descriptor: CatalogOperationDescriptor,
    inputs: [String: JSONValue]
  ) -> [String: JSONValue] {
    guard isSessionScoped(descriptor: descriptor, inputs: inputs) else {
      return inputs
    }
    // A session screenshot has no coordinates to drop: what it is authorized
    // against is the device and the session, which the query already carries.
    guard sessionScopedInputOperations.contains(descriptor.reference) else { return [:] }
    // The frame a gesture was mapped against stays part of the authorized
    // subject; the coordinates inside that frame do not. A rotation or a
    // resolution change therefore produces a different subject, so a mapping
    // computed against the old frame cannot reuse this session's
    // authorization — drift fails closed by construction rather than by a
    // check someone has to remember to run.
    var reduced: [String: JSONValue] = [:]
    for key in ["displayId", "displayWidth", "displayHeight"] {
      if let value = inputs[key] { reduced[key] = value }
    }
    return reduced
  }

  private static func authorizationScopeFingerprint(
    of query: RuntimeCapabilityAuthorizationQuery
  ) -> String {
    var components: [String] = [
      "operation=\(query.operationReference)",
      "effect=\(query.effect.rawValue)",
      "target=\(query.targetStableIdentitySHA256 ?? "-")",
      "bindingRevision=\(query.targetBindingRevision.map(String.init) ?? "-")",
      // A session-scoped gesture must not land on a different capability
      // record for every coordinate, and the materialized plan digest moves
      // with each one. Excluding it here is what bounds the record count; the
      // digest itself still reaches the consume record through the query.
      "planDigest="
        + (query.sessionScoped ? "session-scoped" : (query.planDigest ?? "-")),
    ]
    let encoder = CanonicalJSONEncoders.canonical()
    guard
      let inputs = try? encoder.encode(query.inputs),
      let text = String(data: inputs, encoding: .utf8)
    else {
      preconditionFailure("validated runtime inputs must encode canonically")
    }
    components.append("inputs=\(text)")
    for (key, value) in query.artifactFacts.sorted(by: { $0.key < $1.key }) {
      components.append("artifact.\(key)=\(value)")
    }
    return RuntimeJobRecord.sha256Hex(
      Data(components.joined(separator: "\n").utf8))
  }

  /// The exact step-set digest the runtime pins into a RuntimeCapability's
  /// correlation and the review presents (CHG-2026-066): one implementation,
  /// authorization and presentation can never disagree.
  static func stepSetDigest(
    descriptor: CatalogOperationDescriptor,
    inputs: [String: JSONValue]
  ) -> String {
    let lines = descriptor.steps
      .filter { stepIsRequested($0, descriptor: descriptor, inputs: inputs) }
      .map {
        "\($0.stepID)|\($0.kind.rawValue)|\($0.effect.rawValue)|"
          + "\($0.cancellation.rawValue)|\($0.binding.rawValue)"
      }
    return RuntimeJobRecord.sha256Hex(Data(lines.joined(separator: "\n").utf8))
  }

  /// A control session's envelope is short by design: it authorizes gestures a
  /// person is sending right now, so it expires on the order of one sitting
  /// rather than inheriting the thirty-day standing lifetime that suits a
  /// repeatable, exactly-scoped mutation.
  static let sessionScopedInputLifetime: TimeInterval = 60 * 60
  /// The session budget. Every gesture consumes one use, so this bounds how
  /// much a single unattended envelope can do before a fresh authorization is
  /// required — the "budget" half of the session envelope.
  static let sessionScopedInputMaximumUses = 2_000

  private static func automaticCapabilityExpiry(
    issuedAtUTC: String,
    effect: WorkflowEffect,
    sessionScoped: Bool = false
  ) -> String? {
    guard let issued = ISO8601Timestamps.parse(issuedAtUTC) else { return nil }
    let lifetime: TimeInterval =
      sessionScoped
      ? sessionScopedInputLifetime
      : (effect == .destructive ? 4 * 60 * 60 : 30 * 24 * 60 * 60)
    return ISO8601Timestamps.string(from: issued.addingTimeInterval(lifetime))
  }

  private static func stableJobID(
    idempotencyKey: String, requestFingerprint: String
  ) -> String {
    let material = Data(
      "\(idempotencyKey)\n\(requestFingerprint)".utf8)
    return "job-\(RuntimeJobRecord.sha256Hex(material).prefix(32))"
  }

  private static func confirmedSucceededStepIDs(in replay: JournalReplay) -> Set<String> {
    Set(
      replay.events.compactMap { event in
        guard event.kind == .stepOutcome,
          case .string("confirmed")? = event.payload["outcomeCertainty"],
          case .string("succeeded")? = event.payload["result"]
        else { return nil }
        return event.stepID
      })
  }

  private static func isLowercaseSHA256(_ value: String) -> Bool {
    SHA256Hex.isLowercaseSHA256(value)
  }

  /// `reviewedPlanDigest` is a forward-compatible request-envelope
  /// precondition, not an operation input and never an authority source. The
  /// typed v2 decoder deliberately ignores unknown minor-version keys, while
  /// the engine checks this fail-closed constraint against the freshly
  /// materialized plan before preauthorization or admission. Canonical
  /// persistence and idempotency continue to use the decoded typed request, so
  /// the precondition cannot change operation semantics or become durable
  /// authority.
  private static func reviewedPlanDigest(in requestData: Data) throws -> String? {
    let envelope: [String: JSONValue]
    do {
      envelope = try JSONDecoder().decode([String: JSONValue].self, from: requestData)
    } catch {
      // RuntimeOperationCodec has already proven this is a duplicate-free JSON
      // object. Keep a defensive error here in case that contract changes.
      throw RuntimeJobEngineError.rejected(
        .invalidRequest, "could not read the typed request envelope")
    }
    guard let value = envelope["reviewedPlanDigest"] else { return nil }
    guard case .string(let digest) = value, isLowercaseSHA256(digest) else {
      throw RuntimeJobEngineError.rejected(
        .invalidRequest,
        "reviewedPlanDigest must be a lowercase SHA-256 precondition")
    }
    return digest
  }

  /// Journal-grade WorkflowStep for the kinds the engine exercises in MU-2.
  /// Argument tables are the registry's required keys with deterministic,
  /// audit-honest values.
  static func journalStep(
    for step: CatalogStepDescriptor,
    jobID: String,
    inputs: [String: JSONValue] = [:],
    action: TypedProviderAction? = nil,
    resolvedInputArtifact: ProviderResolvedInputArtifact? = nil,
    operationReference: String? = nil,
    delegatedArkForgePlanCompletion: Bool = false
  ) throws -> WorkflowStep {
    var bundleName: String?
    if case .string(let value)? = inputs["bundleName"] { bundleName = value }
    var abilityName: String?
    if case .string(let value)? = inputs["abilityName"] { abilityName = value }
    let arguments: [String: JSONValue]
    switch step.kind {
    case .probeHostTool:
      arguments = [
        "toolIdentity": .string("hdc"),
        "candidatePath": .string("resolved-by-provider"),
      ]
    case .probeHDCServer:
      arguments = [
        "endpoint": .string("resolved-by-provider"),
        "clientIdentity": .string("arkdeck-agentd"),
      ]
    case .probeDevice:
      if delegatedArkForgePlanCompletion,
        operationReference.map(ArkForgeFlashOperation.contains) == true,
        step.stepID == "rebind-and-verify-build"
      {
        arguments = ["evidencePolicy": .string("postFlashBuild")]
      } else {
        switch action {
        case .rockchip(.rebindLoader):
          arguments = ["evidencePolicy": .string("rockusbLoaderIdentity")]
        case .rockchip(.verifyBoundBuild):
          arguments = ["evidencePolicy": .string("postFlashBuild")]
        default:
          arguments = ["evidencePolicy": .string("coreMinimum")]
        }
      }
    case .waitForDisconnect:
      guard case .rockchip(.waitForHDCDisconnect)? = action else {
        throw RuntimeJobEngineError.internalFailure(
          "\(step.stepID) has no exact HDC disconnect action")
      }
      arguments = [
        "deadlineMilliseconds": .integer(15_000),
        "reason": .string("enterLoader"),
      ]
    case .waitForReconnect:
      if delegatedArkForgePlanCompletion,
        operationReference.map(ArkForgeFlashOperation.contains) == true,
        step.stepID == "wait-for-hdc"
      {
        arguments = [
          "deadlineMilliseconds": .integer(120_000),
          "reason": .string("normalModeReconnect"),
        ]
      } else {
        switch action {
        case .rockchip(.waitForLoader):
          arguments = [
            "deadlineMilliseconds": .integer(45_000),
            "reason": .string("loaderReconnect"),
          ]
        case .rockchip(.waitForHDCReconnect), .rockchip(.waitForBoundHDCReconnect):
          arguments = [
            "deadlineMilliseconds": .integer(120_000),
            "reason": .string("normalModeReconnect"),
          ]
        default:
          throw RuntimeJobEngineError.internalFailure(
            "\(step.stepID) has no exact reconnect action")
        }
      }
    case .preflightDeviceStorage:
      if case .hdc(.observeStorage(let request))? = action {
        arguments = [
          "remotePath": .string(HDCStoragePreflightRequest.remotePath),
          "requiredBytes": .integer(Int64(request.requiredBytes)),
        ]
      } else {
        arguments = [
          "remotePath": .string(HDCStoragePreflightRequest.remotePath),
          "requiredBytes": .integer(1_048_576),
        ]
      }
    case .captureRemoteStdout:
      // The action identity comes from the catalog's own actionRef, never
      // from a guess here. CHG-2026-050 exists because an earlier version
      // of this table labelled the HiLog step with a UI-dump action: the
      // journal would then have recorded an intent the step never had,
      // which is fabricated evidence rather than a naming slip.
      guard let reference = step.actionReference else {
        throw RuntimeJobEngineError.internalFailure(
          "\(step.stepID) captures stdout but declares no catalog action; "
            + "refusing to invent one for the durable intent")
      }
      var parameters: [String: JSONValue] = [:]
      switch reference.actionID {
      case "boundedHilog":
        var duration = 30
        if case .integer(let requested)? = inputs["durationSeconds"] {
          duration = max(1, min(Int(requested), 600))
        } else if case .integer(let requested)? = inputs["diagnosticsDurationSeconds"] {
          duration = max(1, min(Int(requested), 600))
        }
        var filters: [JSONValue] = []
        if case .array(let requested)? = inputs["hilogFilters"] {
          filters = requested.filter {
            if case .string = $0 { return true }
            return false
          }
        }
        var budget = 16 * 1024 * 1024
        if case .integer(let requested)? = inputs["totalArtifactByteBudget"] {
          budget = max(1024, min(Int(requested), 134_217_728))
        }
        parameters = [
          "durationSeconds": .integer(Int64(duration)),
          "filters": .array(Array(filters.prefix(16))),
          "byteBudget": .integer(Int64(budget)),
        ]
      case "componentTree", "windowInventory", "crashIndex":
        parameters = ["byteBudget": .integer(8 * 1024 * 1024)]
      case "componentDetail":
        guard case .string(let windowID)? = inputs["windowId"],
          case .string(let componentID)? = inputs["componentId"]
        else {
          throw RuntimeJobEngineError.internalFailure(
            "component detail step selected without windowId and componentId")
        }
        parameters = [
          "windowId": .string(windowID),
          "componentId": .string(componentID),
          "byteBudget": .integer(8 * 1024 * 1024),
        ]
      case "crashLog":
        guard case .string(let name)? = inputs["crashLogName"] else {
          throw RuntimeJobEngineError.internalFailure(
            "crash log step selected without its entry name")
        }
        parameters = [
          "byteBudget": .integer(8 * 1024 * 1024),
          "faultLogName": .string(name),
        ]
      default:
        throw RuntimeJobEngineError.internalFailure(
          "unregistered stdout action \(reference.actionID) for \(step.stepID)")
      }
      arguments = [
        "catalogId": .string(reference.catalogID),
        "actionId": .string(reference.actionID),
        "parameters": .object(parameters),
        "artifactId": .string("artifact-\(step.stepID)"),
      ]
    case .captureRemoteFile:
      if case .hdc(.captureScreenSequence(let request, let frames, let path))? = action {
        arguments = [
          "catalogId": .string("trace-presets"),
          "actionId": .string("custom"),
          "parameters": .object([
            "frameCount": .integer(Int64(request.frameCount)),
            "imageType": .string(request.imageType.rawValue),
            "framesDirectory": .string(frames.remotePath),
          ]),
          "artifactId": .string("artifact-\(step.stepID)"),
          "ownedRemotePath": .string(path.remotePath),
        ]
      } else if case .hdc(.captureScreenshot(_, let path))? = action {
        arguments = [
          "catalogId": .string("trace-presets"),
          "actionId": .string("custom"),
          "parameters": .object([:]),
          "artifactId": .string("artifact-\(step.stepID)"),
          "ownedRemotePath": .string(path.remotePath),
        ]
      } else if case .hdc(.captureComponentTree(let path))? = action {
        arguments = [
          "catalogId": .string("trace-presets"),
          "actionId": .string("custom"),
          "parameters": .object([:]),
          "artifactId": .string("artifact-\(step.stepID)"),
          "ownedRemotePath": .string(path.remotePath),
        ]
      } else if case .hdc(.captureTrace(let request, let path))? = action {
        arguments = [
          "catalogId": .string("trace-presets"),
          "actionId": .string("custom"),
          "parameters": .object([
            "durationSeconds": .integer(Int64(request.durationSeconds)),
            "categories": .array(request.categories.map(JSONValue.string)),
            "bufferKB": .integer(Int64(request.bufferKB)),
          ]),
          "artifactId": .string("artifact-\(step.stepID)"),
          "ownedRemotePath": .string(path.remotePath),
        ]
      } else {
        arguments = [
          "catalogId": .string("trace-presets"),
          "actionId": .string("custom"),
          "parameters": .object([:]),
          "artifactId": .string("artifact-\(step.stepID)"),
          "ownedRemotePath": .string(
            "/data/local/tmp/arkdeck-\(jobID)-capture-trace-owned.htrace"),
        ]
      }
    case .receiveFile:
      let localName: String
      switch step.stepID {
      case "receive-ui-tree": localName = "ui-tree.json"
      case "receive-screenshot":
        // The landing name carries the encoding, because a `.png` holding
        // JFIF bytes is a file nothing downstream can read for what it says
        // it is.
        if case .hdc(.receiveOwnedArtifact(let artifact))? = action,
          artifact.path.remotePath.hasSuffix(".jpeg")
        {
          localName = "screenshot.jpeg"
        } else {
          localName = "screenshot.png"
        }
      case "receive-screen-sequence": localName = "frames.tar"
      default: localName = "trace.htrace"
      }
      if case .hdc(.receiveOwnedArtifact(let artifact))? = action {
        var exact: [String: JSONValue] = [
          "remotePath": .string(artifact.path.remotePath),
          "artifactId": .string("artifact-\(step.stepID)"),
          "localRelativePath": .string("artifacts/raw/\(localName)"),
        ]
        if let expected = artifact.expectedSHA256 {
          exact["expectedSha256"] = .string(expected)
        }
        arguments = exact
      } else {
        arguments = [
          "remotePath": .string(
            "/data/local/tmp/arkdeck-\(jobID)-capture-trace-owned.htrace"),
          "artifactId": .string("artifact-\(step.stepID)"),
          "localRelativePath": .string("artifacts/raw/\(localName)"),
        ]
      }
    case .cleanupOwnedRemotePath:
      let path: String
      if case .hdc(.cleanupScreenSequence(_, let frames, let archive))? = action {
        // Two owned things, not one: the archive and the directory the frames
        // were written into. The journal names both so a residue record can
        // be acted on without re-deriving either.
        arguments = [
          "remotePath": .string(archive.remotePath),
          "framesDirectory": .string(frames.remotePath),
          "ownershipEvidenceId": .string("owned-\(jobID)"),
        ]
        break
      } else if case .hdc(.cleanupOwnedRemotePath(let owned))? = action {
        path = owned.remotePath
      } else if case .hdc(.cleanupNativeLibrary(let deployment))? = action {
        path = deployment.stagingPath
      } else {
        let ownerStep: String
        switch step.stepID {
        case "cleanup-remote-staging": ownerStep = "send-hap"
        case "cleanup-ui-tree-temp": ownerStep = "capture-ui-tree"
        case "cleanup-screenshot-temp": ownerStep = "capture-screenshot"
        default: ownerStep = "capture-trace"
        }
        let suffix: String
        switch ownerStep {
        case "send-hap": suffix = ".hap"
        case "capture-ui-tree": suffix = ".json"
        case "capture-screenshot": suffix = ".png"
        default: suffix = ".htrace"
        }
        path = "/data/local/tmp/arkdeck-\(jobID)-\(ownerStep)-owned\(suffix)"
      }
      arguments = [
        "remotePath": .string(path),
        "ownershipEvidenceId": .string("owned-\(jobID)"),
      ]
    case .sendFile:
      if case .hdc(.sendArtifactToStaging(let staged))? = action,
        let resolvedInputArtifact
      {
        arguments = [
          "sourceArtifactId": .string(resolvedInputArtifact.artifactID),
          "remotePath": .string(staged.path.remotePath),
          "sourceSha256": .string(resolvedInputArtifact.sha256),
        ]
      } else if case .hdc(.sendNativeLibraryToStaging(let deployment))? = action,
        let resolvedInputArtifact
      {
        arguments = [
          "sourceArtifactId": .string(resolvedInputArtifact.artifactID),
          "remotePath": .string(deployment.stagingPath),
          "sourceSha256": .string(resolvedInputArtifact.sha256),
        ]
      } else {
        arguments = [
          "sourceArtifactId": .string("hap-artifact"),
          "remotePath": .string("/data/local/tmp/arkdeck-\(jobID)-send-hap-owned.hap"),
          "sourceSha256": .string(String(repeating: "0", count: 64)),
        ]
      }
    case .installPackage:
      let packageArtifactID: String
      if case .hdc(.installPackage(let staged, _))? = action,
        let identifier = staged.artifactLeaseID.split(separator: ":").last
      {
        packageArtifactID = String(identifier)
      } else {
        packageArtifactID = "hap-artifact"
      }
      arguments = [
        "packageArtifactId": .string(packageArtifactID),
        "packageName": .string(bundleName ?? "com.example.app"),
        "replacePolicy": .string("allow"),
      ]
    case .uninstallPackage:
      arguments = ["packageName": .string(bundleName ?? "com.example.app")]
    case .startApplication, .stopApplication:
      if case .hdc(.startNativeTarget(let deployment))? = action {
        arguments = [
          "bundleName": .string(deployment.bundle.bundleName),
          "abilityName": .string(HDCAppOwnedNativeLibraryDeployment.entryAbility),
        ]
      } else if case .hdc(.stopNativeTarget(let deployment))? = action {
        arguments = [
          "bundleName": .string(deployment.bundle.bundleName),
          "abilityName": .string(HDCAppOwnedNativeLibraryDeployment.entryAbility),
        ]
      } else {
        arguments = [
          "bundleName": .string(bundleName ?? "com.example.app"),
          "abilityName": .string(abilityName ?? "EntryAbility"),
        ]
      }
    case .createPortForward:
      guard case .hdc(.createPortForward(let spec))? = action else {
        throw RuntimeJobEngineError.internalFailure(
          "\(step.stepID) has no exact typed port-forward create action")
      }
      arguments = [
        "forwardId": .string(
          "port_forward_\(spec.direction.rawValue)_\(spec.localPort)_\(spec.remotePort)"),
        "hostEndpoint": .string("tcp:\(spec.localPort)"),
        "deviceEndpoint": .string("tcp:\(spec.remotePort)"),
      ]
    case .injectPointerInput:
      guard case .hdc(.injectPointerInput(let spec))? = action else {
        throw RuntimeJobEngineError.internalFailure(
          "\(step.stepID) has no exact typed pointer-input action")
      }
      var pointer: [String: JSONValue] = [
        "gesture": .string(spec.gesture.rawValue),
        "pointerX": .integer(Int64(spec.x)),
        "pointerY": .integer(Int64(spec.y)),
      ]
      if let toX = spec.toX { pointer["pointerToX"] = .integer(Int64(toX)) }
      if let toY = spec.toY { pointer["pointerToY"] = .integer(Int64(toY)) }
      if let durationMs = spec.durationMs {
        pointer["durationMs"] = .integer(Int64(durationMs))
      }
      if let displayID = spec.displayID {
        pointer["displayId"] = .integer(Int64(displayID))
      }
      // The frame the gesture was mapped against belongs in the durable
      // intent: a later reader has to be able to tell what the coordinates
      // meant, not just what they were.
      pointer["displayWidth"] = .integer(Int64(spec.displayWidth))
      pointer["displayHeight"] = .integer(Int64(spec.displayHeight))
      arguments = pointer
    case .removePortForward:
      guard case .hdc(.removePortForward(let spec))? = action else {
        throw RuntimeJobEngineError.internalFailure(
          "\(step.stepID) has no exact typed port-forward remove action")
      }
      arguments = [
        "forwardId": .string(
          "port_forward_\(spec.direction.rawValue)_\(spec.localPort)_\(spec.remotePort)")
      ]
    case .runApprovedRemoteRead:
      if case .hdc(.runDebugTemplate(let template))? = action {
        // The template identity is the whole parameter set; the durable
        // intent names it so replay and reconciliation see which closed
        // command ran, never the tokens as free text.
        arguments = [
          "catalogId": .string("arkdeck-remote-operations"),
          "actionId": .string("debugTemplate"),
          "parameters": .object(["templateId": .string(template.rawValue)]),
          "artifactId": .string("template-output"),
        ]
        break
      }
      if case .hdc(.inspectNativeLibrary(let deployment, let expectation))? = action {
        arguments = [
          "catalogId": .string("arkdeck-remote-operations"),
          "actionId": .string("nativeLibraryInspection"),
          "parameters": .object([
            "expectation": .string(expectation.rawValue),
            "targetPath": .string(deployment.targetPath),
            "expectedSha256": .string(deployment.artifactFacts.sha256),
            "buildId": .string(deployment.artifactFacts.buildID),
          ]),
          "artifactId": .string("native-library-readback"),
        ]
        break
      }
      guard let reference = step.actionReference,
        reference.catalogID == "arkdeck-remote-operations"
      else {
        throw RuntimeJobEngineError.internalFailure(
          "\(step.stepID) has no arkdeck-remote-operations actionRef")
      }
      var parameters: [String: JSONValue] = [:]
      if case .hdc(.queryPackageReadback(let bundle))? = action {
        parameters["bundleName"] = .string(bundle.bundleName)
      }
      arguments = [
        "catalogId": .string(reference.catalogID),
        "actionId": .string(reference.actionID),
        "parameters": .object(parameters),
        "artifactId": .string("artifact-\(step.stepID)"),
      ]
    case .runApprovedRemoteMutation:
      let deployment: HDCAppOwnedNativeLibraryDeployment
      let actionID: String
      switch action {
      case .hdc(.backupNativeLibrary(let value)):
        deployment = value
        actionID = "nativeLibraryBackup"
      case .hdc(.publishNativeLibrary(let value)):
        deployment = value
        actionID = "nativeLibraryAtomicPublish"
      case .hdc(.rollbackNativeLibrary(let value)):
        deployment = value
        actionID = "nativeLibraryRollback"
      default:
        throw RuntimeJobEngineError.internalFailure(
          "\(step.stepID) has no exact typed native mutation action")
      }
      arguments = [
        "catalogId": .string("arkdeck-remote-operations"),
        "actionId": .string(actionID),
        "parameters": .object([
          "targetPath": .string(deployment.targetPath),
          "stagingPath": .string(deployment.stagingPath),
          "backupPath": .string(deployment.backupPath),
          "rollbackStagingPath": .string(deployment.rollbackStagingPath),
          "expectedSha256": .string(deployment.artifactFacts.sha256),
          "buildId": .string(deployment.artifactFacts.buildID),
        ]),
        "artifactId": .string("native-library-mutation"),
        "confirmationId": .string("runtime-capability-admission"),
      ]
    case .verifyRemoteState:
      let probeID: String
      // The readback's expected state is the archive the plan was built for.
      // It used to be read off the provider action; that action moved to
      // arkforged with the lowering, so the identity now comes from the
      // resolved input artifact instead. Same bytes, same digest, same
      // journalled argument — only the source changed (CHG-2026-059 §5.1).
      if step.stepID == "verify-flash-readback", let artifact = resolvedInputArtifact {
        arguments = [
          "probeId": .string("rockusb-partition-readback"),
          "expectedState": .string("mapped-set:\(artifact.sha256)"),
        ]
        break
      } else if case .hdc(.verifyProcessState(let bundle))? = action {
        probeID = "process.\(bundle.bundleName)"
      } else if case .hdc(.readPortForwardPresence(let spec))? = action {
        arguments = [
          "probeId": .string(
            "port-forward.\(spec.direction.rawValue).\(spec.localPort).\(spec.remotePort)"),
          "expectedState": .string(
            operationReference == "port-forward.remove@1" ? "absent" : "present"),
        ]
        break
      } else if case .hdc(.inspectNativeLibrary(let deployment, .targetLoaded))? = action {
        arguments = [
          "probeId": .string("native-library-loader"),
          "expectedState": .string(
            "loaded:\(deployment.artifactFacts.sha256)"),
        ]
        break
      } else {
        probeID = "process-state"
      }
      arguments = [
        "probeId": .string(probeID),
        "expectedState": .string("running"),
      ]
    case .enterUpdater:
      guard case .rockchip(.enterLoader)? = action else {
        throw RuntimeJobEngineError.internalFailure(
          "\(step.stepID) has no exact Loader transition action")
      }
      arguments = [
        "providerOperationId": .string("rockusb.enter-loader"),
        "expectedMode": .string("Loader"),
        "reconnectDeadlineMilliseconds": .integer(45_000),
      ]
    case .flashPartition:
      // Same move as the readback above: the write's identity is the resolved
      // artifact, not a provider action this authority no longer owns. The
      // journalled arguments — including the confirmation and safe-boundary
      // ids the authorization judgement reads — are unchanged.
      guard let artifact = resolvedInputArtifact else {
        throw RuntimeJobEngineError.internalFailure(
          "\(step.stepID) has no resolved flash artifact")
      }
      arguments = [
        // Renamed from the vendor command name "rockusb.wl-write" with
        // CHG-2026-066: the write is the ArkForge lane's native WRITE_LBA
        // over the mapped set. Journalled label only — no test or reader
        // pins the old value, and each job's plan digest is its own.
        "providerOperationId": .string("arkforge.write-partitions"),
        "partition": .string("dayu200_mapped_set"),
        "imageArtifactId": .string(artifact.artifactID),
        "imageSha256": .string(artifact.sha256),
        "imageSize": .integer(Int64(artifact.byteCount)),
        "confirmationId": .string("runtimeE2Admission"),
        "safeBoundaryId": .string("perPartitionWriteBoundary"),
      ]
    case .rebootDevice:
      guard
        (delegatedArkForgePlanCompletion
          && operationReference.map(ArkForgeFlashOperation.contains) == true
          && step.stepID == "reboot-device")
          || {
            if case .rockchip(.rebootToNormal)? = action { return true }
            return false
          }()
      else {
        throw RuntimeJobEngineError.internalFailure(
          "\(step.stepID) has no exact Rockchip reboot action")
      }
      arguments = [
        "targetMode": .string("normal"),
        "reason": .string("rockusbResetAfterFlash"),
      ]
    case .runDeterministicAnalyzer:
      guard case .analyzer(.analyze(let invocation))? = action else {
        throw RuntimeJobEngineError.internalFailure(
          "\(step.stepID) requires a deterministic analyzer action")
      }
      arguments = [
        "analyzerRef": .string(invocation.analyzerRef),
        "inputArtifactId": .string(invocation.sourceArtifactID),
        "artifactId": .string(AnalyzerProvider.derivedArtifactName(invocation.analyzerRef)),
      ]
    case .inspectWorkspaceSource:
      // The journal records the declared inputs and the artifact they land in.
      // The resolved project root is deliberately absent: it is host-private,
      // and the durable record names what was inspected, not where this
      // machine keeps it (CHG-2026-054 TASK-HTP-007).
      guard case .workspace(.inspectSource(let inspection))? = action else {
        throw RuntimeJobEngineError.internalFailure(
          "\(step.stepID) requires a workspace inspection action")
      }
      arguments = [
        "projectRef": .string(inspection.projectRef),
        "symbol": .string(inspection.symbol),
        "fileScope": .string(inspection.fileScope),
        "artifactId": .string("source-inspection.txt"),
      ]
    // The three read-only workspace observations below follow
    // `inspectWorkspaceSource` exactly: the journal records the declared
    // inputs and the artifact they land in, and never the resolved project
    // root, which is host-private. Their step kinds, argument contracts
    // (`WorkflowStep.swift`) and provider lowering all shipped, but this table
    // was never given an arm, so every one of them reached the `default` below
    // and threw `internalFailure` — a published operation that could not be
    // dispatched (PRODUCT-LOOP §8).
    case .inspectWorkspaceGitStatus:
      guard case .string(let projectRef)? = inputs["projectRef"] else {
        throw RuntimeJobEngineError.internalFailure(
          "\(step.stepID) has incomplete workspace git-status inputs")
      }
      arguments = [
        "projectRef": .string(projectRef),
        "artifactId": .string("git-status.txt"),
      ]
    case .inspectWorkspaceDiff:
      guard case .string(let projectRef)? = inputs["projectRef"],
        case .string(let baseRevision)? = inputs["baseRevision"],
        case .string(let pathScope)? = inputs["pathScope"]
      else {
        throw RuntimeJobEngineError.internalFailure(
          "\(step.stepID) has incomplete workspace diff inputs")
      }
      arguments = [
        "projectRef": .string(projectRef),
        "baseRevision": .string(baseRevision),
        "pathScope": .string(pathScope),
        "artifactId": .string("diff-summary.txt"),
      ]
    case .readWorkspaceSourceRange:
      guard case .string(let projectRef)? = inputs["projectRef"],
        case .string(let filePath)? = inputs["filePath"],
        case .integer(let lineStart)? = inputs["lineStart"],
        case .integer(let lineEnd)? = inputs["lineEnd"]
      else {
        throw RuntimeJobEngineError.internalFailure(
          "\(step.stepID) has incomplete workspace source-range inputs")
      }
      arguments = [
        "projectRef": .string(projectRef),
        "filePath": .string(filePath),
        "lineStart": .integer(lineStart),
        "lineEnd": .integer(lineEnd),
        "artifactId": .string("source-range.txt"),
      ]
    case .prepareWorkspaceIsolation:
      guard case .workspace(.prepareIsolatedCopy(let isolation))? = action else {
        throw RuntimeJobEngineError.internalFailure(
          "\(step.stepID) has no exact typed workspace isolation action")
      }
      arguments = [
        "sourceProjectRef": .string(isolation.sourceProjectRef),
        "expectedWorkspaceRevision": .string(isolation.expectedWorkspaceRevision),
        "workspaceRevision": .string(isolation.isolatedWorkspaceRevision),
        "allowedFileScopesDigest": .string(isolation.allowedFileScopesDigest),
        "workspaceProjectRef": .string(isolation.workspaceProjectRef),
        "artifactId": .string("isolated-workspace.json"),
      ]
    case .sweepWorkspaceIsolation:
      guard case .workspace(.sweepIsolatedCopies(let sweep))? = action else {
        throw RuntimeJobEngineError.internalFailure(
          "\(step.stepID) has no exact typed workspace sweep action")
      }
      arguments = [
        "retainLatestCount": .integer(Int64(sweep.retainLatestCount)),
        "minimumQuiescentSeconds": .integer(Int64(sweep.minimumQuiescentSeconds)),
        "dryRun": .string(String(sweep.dryRun)),
        "artifactId": .string("sweep-findings.json"),
      ]
    case .createWorkspaceCheckpoint:
      let projectRef: String
      switch action {
      case .workspace(.createCheckpoint(let invocation)):
        projectRef = invocation.projectRef
      case .workspace(.createArchiveCheckpoint(let checkpoint)):
        projectRef = checkpoint.invocation.projectRef
      default:
        throw RuntimeJobEngineError.internalFailure(
          "\(step.stepID) has no exact typed workspace checkpoint action")
      }
      arguments = [
        "projectRef": .string(projectRef),
        "artifactId": .string("checkpoint.txt"),
      ]
    case .applyWorkspacePatch:
      guard case .workspace(.applyPatch(let patch))? = action else {
        throw RuntimeJobEngineError.internalFailure(
          "\(step.stepID) has no exact typed workspace patch action")
      }
      arguments = [
        "projectRef": .string(patch.invocation.projectRef),
        "patchArtifactId": .string(patch.patchArtifactID),
        "patchSha256": .string(patch.patchSHA256),
        "allowedFileGlobs": .array(patch.allowedFileGlobs.map(JSONValue.string)),
        "patchAttemptRef": .string(patch.patchAttemptRef),
      ]
    case .buildWorkspaceOpenHarmony:
      guard case .string(let projectRef)? = inputs["projectRef"],
        case .string(let preset)? = inputs["buildPresetRef"]
      else {
        throw RuntimeJobEngineError.internalFailure(
          "\(step.stepID) has incomplete workspace build inputs")
      }
      arguments = [
        "projectRef": .string(projectRef),
        "buildPresetRef": .string(preset),
      ]
    case .signWorkspaceOpenHarmonyHap:
      guard case .workspace(.signOpenHarmonyHap(let signing))? = action,
        let resolvedInputArtifact
      else {
        throw RuntimeJobEngineError.internalFailure(
          "\(step.stepID) has no exact typed OpenHarmony signing action")
      }
      arguments = [
        "projectRef": .string(signing.projectRef),
        "signingPresetRef": .string(signing.selectedSigningPresetRef),
        "inputArtifactId": .string(resolvedInputArtifact.artifactID),
        "inputSha256": .string(resolvedInputArtifact.sha256),
      ]
    case .runWorkspaceTests:
      guard case .string(let projectRef)? = inputs["projectRef"],
        case .string(let preset)? = inputs["testPresetRef"]
      else {
        throw RuntimeJobEngineError.internalFailure(
          "\(step.stepID) has incomplete workspace test inputs")
      }
      arguments = [
        "projectRef": .string(projectRef),
        "testPresetRef": .string(preset),
      ]
    case .symbolizeWorkspaceCrash:
      guard case .string(let projectRef)? = inputs["projectRef"],
        case .string(let preset)? = inputs["symbolPresetRef"],
        let resolvedInputArtifact
      else {
        throw RuntimeJobEngineError.internalFailure(
          "\(step.stepID) has incomplete workspace symbolization inputs")
      }
      arguments = [
        "projectRef": .string(projectRef),
        "dumpArtifactId": .string(resolvedInputArtifact.artifactID),
        "dumpSha256": .string(resolvedInputArtifact.sha256),
        "symbolPresetRef": .string(preset),
      ]
    case .revertWorkspacePatch:
      guard case .string(let projectRef)? = inputs["projectRef"],
        case .string(let reference)? = inputs["patchAttemptRef"]
      else {
        throw RuntimeJobEngineError.internalFailure(
          "\(step.stepID) has incomplete workspace revert inputs")
      }
      arguments = [
        "projectRef": .string(projectRef),
        "patchAttemptRef": .string(reference),
      ]
    default:
      throw RuntimeJobEngineError.internalFailure(
        "no journal argument table for \(step.kind.rawValue)")
    }
    return try WorkflowStep(
      id: step.stepID,
      kind: step.kind,
      declaredEffect: step.effect,
      declaredCancellation: step.cancellation,
      declaredBindingRequirement: step.binding,
      arguments: arguments)
  }

  private static func flashArtifactLeaseID(
    in inputs: [String: JSONValue]?
  ) -> String? {
    guard let inputs else { return nil }
    if case .string(let lease)? = inputs["artifactLease"], !lease.isEmpty { return lease }
    if case .string(let lease)? = inputs["imageBundleLease"], !lease.isEmpty { return lease }
    return nil
  }

  /// Returns the complete board profile derived from one exact, already
  /// resolved lease. Cache hits are possible only after the caller has gone
  /// through `resolveLease` again; this helper never substitutes for fresh
  /// Artifact validation.
  private func resolvedFlashArchiveProfile(
    artifactLeaseID: String,
    artifact: ProviderResolvedInputArtifact,
    board: RockchipFlashProfile
  ) throws -> RockchipFlashProfile {
    try flashArchiveProfileCache.resolve(
      artifactLeaseID: artifactLeaseID, artifact: artifact, board: board
    ) {
      let summary = try GzipTarArchiveReader.summarize(
        fileAt: artifact.fileURL,
        derivation: RockchipImageArchiveIntrospection.derivationRequest(board: board))
      let build = try RockchipImageArchiveIntrospection.describe(
        summary: summary, board: board)
      return try board.forBuild(build)
    }
  }

  /// The build version the image bundle for this job declares, or nil when the
  /// job does not carry one. Every caller supplies facts from a fresh lease
  /// resolution; the daemon-lifetime cache only avoids repeating the expensive
  /// archive description for that exact lease.
  private func declaredRuntimeBuildVersion(
    for descriptor: CatalogOperationDescriptor,
    artifact: ProviderResolvedInputArtifact?,
    artifactLeaseID: String?
  ) -> String? {
    guard ArkForgeFlashOperation.contains(descriptor.reference), let artifact,
      let artifactLeaseID
    else { return nil }
    return try? resolvedFlashArchiveProfile(
      artifactLeaseID: artifactLeaseID,
      artifact: artifact,
      board: RockchipFlashProfile.dayu200
    ).runtimeBuildVersion
  }

}

extension RuntimeJobEngine.ArkForgeLane {
  /// Compatibility default for scripted lanes that do not model host-store
  /// preparation. Production `ArkForgeLaneHost` overrides this to perform the
  /// actual early import before execution preparation.
  package func prewarmArtifact(
    jobID _: String, artifact: ArkForgeLaneArtifact
  ) async throws -> ArkForgeLaneArtifactPrewarmReceipt {
    ArkForgeLaneArtifactPrewarmReceipt(
      artifactSHA256: artifact.sha256, profileID: artifact.profileID,
      imported: false, durationMilliseconds: 0)
  }

  package func finishArtifactPrewarm(jobID _: String) async {}
}

/// What the runtime's own durable ledger can say about the jobs referencing
/// one Runtime-owned isolated workspace: how many reference it, whether every
/// one of them is terminal, and the newest transition among them. The sweep
/// dispatcher composes its quiescence testimony exclusively from this —
/// callers have no field through which to supply or bias it (CHG-2026-067
/// RWL-REQ-002).
public struct WorkspaceReferenceLedgerFacts: Sendable, Equatable {
  public let referencingJobCount: Int
  public let allTerminal: Bool
  public let newestTransitionUTC: String?

  public init(referencingJobCount: Int, allTerminal: Bool, newestTransitionUTC: String?) {
    self.referencingJobCount = referencingJobCount
    self.allTerminal = allTerminal
    self.newestTransitionUTC = newestTransitionUTC
  }
}

public protocol WorkspaceReferenceLedgerReading: Sendable {
  func referenceFacts(
    prepareRuntimeOwnerID: String, derivedProjectRef: String
  ) async throws -> WorkspaceReferenceLedgerFacts
}

extension RuntimeJobEngine: WorkspaceReferenceLedgerReading {
  /// Terminality comes from the repository's own active-set filter rather
  /// than from re-parsing state strings; a job is a reference if it created
  /// the workspace or if its persisted typed request names the derived
  /// projectRef in its inputs.
  public func referenceFacts(
    prepareRuntimeOwnerID: String, derivedProjectRef: String
  ) async throws -> WorkspaceReferenceLedgerFacts {
    let prepareJobID =
      prepareRuntimeOwnerID.hasPrefix("runtime-")
      ? String(prepareRuntimeOwnerID.dropFirst("runtime-".count))
      : prepareRuntimeOwnerID
    let all = try admissionService.allJobs()
    let active = Set(try admissionService.activeJobs().map(\.jobID))
    var count = 0
    var allTerminal = true
    var newest: String?
    for job in all {
      let references: Bool
      if job.jobID == prepareJobID {
        references = true
      } else if let data = job.initialRecordData,
        let record = try? JSONDecoder().decode(RuntimeJobRecord.self, from: data),
        case .string(derivedProjectRef)? = record.request.inputs["projectRef"]
      {
        references = true
      } else {
        references = false
      }
      guard references else { continue }
      count += 1
      if active.contains(job.jobID) {
        allTerminal = false
      } else if newest.map({ job.updatedAtUTC > $0 }) ?? true {
        newest = job.updatedAtUTC
      }
    }
    return WorkspaceReferenceLedgerFacts(
      referencingJobCount: count, allTerminal: allTerminal,
      newestTransitionUTC: newest)
  }
}
