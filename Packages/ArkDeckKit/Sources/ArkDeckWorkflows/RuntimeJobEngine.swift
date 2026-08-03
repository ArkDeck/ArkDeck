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
import CryptoKit
import Foundation

public enum RuntimeJobEngineError: Error, Equatable, Sendable {
  case rejected(RuntimeOperationErrorCode, String)
  case idempotencyConflict(String)
  case jobNotFound(String)
  case jobNotRunnable(String)
  case internalFailure(String)
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
/// consumption or provider dispatch, including for E2 operations.
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
  /// How much of this job's device residue is still outstanding. A
  /// `succeeded` job with a non-zero count did what was asked and left the
  /// device dirty; `succeeded` must never be read as "device clean"
  /// (CHG-2026-049 r3). Optional so a status decoded from before r3 keeps
  /// decoding.
  public var outstandingResidueCount: Int?
  public let timeline: [String]
}

public struct RuntimeJobStatusPage: Sendable, Equatable {
  public let jobs: [RuntimeJobStatus]
  public let nextCursor: String?
}

public enum RuntimeEvidenceAuthorityKind: String, Sendable, Equatable, Codable {
  case defaultReadOnlyPolicy
  case runtimeCapability
  case standingAuthorization
  /// Bounded-campaign E2 authority: the request carried an open usage
  /// reservation minted by the campaign admission service, and the engine
  /// re-verified its embedded confirmation pins (POL-AGENT-002 second
  /// branch — this kind is never a standing authorization).
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
  public let reviewDigestSHA256: String
  public let brokerDigestSHA256: String

  public init(
    campaignID: String,
    attemptID: String,
    attemptOrdinal: Int,
    planDigestSHA256: String,
    targetBindingDigestSHA256: String,
    candidateDigestSHA256: String,
    reviewDigestSHA256: String,
    brokerDigestSHA256: String
  ) {
    self.campaignID = campaignID
    self.attemptID = attemptID
    self.attemptOrdinal = attemptOrdinal
    self.planDigestSHA256 = planDigestSHA256
    self.targetBindingDigestSHA256 = targetBindingDigestSHA256
    self.candidateDigestSHA256 = candidateDigestSHA256
    self.reviewDigestSHA256 = reviewDigestSHA256
    self.brokerDigestSHA256 = brokerDigestSHA256
  }
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

  public init(
    kind: RuntimeEvidenceAuthorityKind,
    reference: String,
    admittedAtUTC: String,
    validUntilUTC: String?,
    consumptionFingerprintSHA256: String?,
    campaignCorrelation: RuntimeCampaignEvidenceCorrelation? = nil
  ) {
    self.kind = kind
    self.reference = reference
    self.admittedAtUTC = admittedAtUTC
    self.validUntilUTC = validUntilUTC
    self.consumptionFingerprintSHA256 = consumptionFingerprintSHA256
    self.campaignCorrelation = campaignCorrelation
  }
}

public struct RuntimeEvidencePreflightStep: Sendable, Equatable, Codable {
  public let stepID: String
  public let stepKind: String
  public let outcomeAtUTC: String

  public init(stepID: String, stepKind: String, outcomeAtUTC: String) {
    self.stepID = stepID
    self.stepKind = stepKind
    self.outcomeAtUTC = outcomeAtUTC
  }
}

/// Facts assembled only from the three independently journaled, verified
/// typed preflight outcomes belonging to this same job.
public struct RuntimeEvidenceObservation: Sendable, Equatable, Codable {
  public let targetID: String?
  public let bindingRevision: Int?
  public let stableIdentitySHA256: String?
  public let model: String?
  public let firmware: String?
  public let transport: String?
  public let providerID: String
  public let toolVersion: String
  public let toolSHA256: String
  public let confirmedAtUTC: String?
  public let confirmationMethod: String
  public let preflightSteps: [RuntimeEvidencePreflightStep]

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
  public let stableIdentitySHA256: String
  public let providerID: String
  public let toolVersion: String
  public let toolSHA256: String
  public var transport: String?
  public var confirmedAtUTC: String?
  public var model: String?
  public var firmware: String?
  public var steps: [RuntimeEvidencePreflightStep]

  public var isComplete: Bool {
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
}

public struct RuntimeJobAcceptance: Sendable, Equatable {
  public let jobID: String
  public let deduplicated: Bool
}

/// A non-authoritative, non-installed capability proposal derived from the
/// same fully materialized request that will later execute.
public struct RuntimeCapabilityDraft: Sendable, Equatable, Codable {
  public let capability: RuntimeCapability
  public let requestID: String
  public let idempotencyKey: String
  public let requestFingerprintSHA256: String
  public let operationReference: String
  public let targetID: String
  public let bindingRevision: Int?
  public let stableIdentitySHA256: String?
  public let workspaceIdentitySHA256: String?
  public let workspaceRevision: String?
  public let workspaceFileScopesDigest: String?
  public let materializedPlanDigest: String
  public let catalogDigest: String

  public init(
    capability: RuntimeCapability,
    requestID: String,
    idempotencyKey: String,
    requestFingerprintSHA256: String,
    operationReference: String,
    targetID: String,
    bindingRevision: Int?,
    stableIdentitySHA256: String?,
    workspaceIdentitySHA256: String? = nil,
    workspaceRevision: String? = nil,
    workspaceFileScopesDigest: String? = nil,
    materializedPlanDigest: String,
    catalogDigest: String
  ) {
    self.capability = capability
    self.requestID = requestID
    self.idempotencyKey = idempotencyKey
    self.requestFingerprintSHA256 = requestFingerprintSHA256
    self.operationReference = operationReference
    self.targetID = targetID
    self.bindingRevision = bindingRevision
    self.stableIdentitySHA256 = stableIdentitySHA256
    self.workspaceIdentitySHA256 = workspaceIdentitySHA256
    self.workspaceRevision = workspaceRevision
    self.workspaceFileScopesDigest = workspaceFileScopesDigest
    self.materializedPlanDigest = materializedPlanDigest
    self.catalogDigest = catalogDigest
  }

  enum CodingKeys: String, CodingKey {
    case capability, requestID, idempotencyKey, requestFingerprintSHA256
    case operationReference, targetID, bindingRevision, stableIdentitySHA256
    case workspaceIdentitySHA256, workspaceRevision, workspaceFileScopesDigest
    case materializedPlanDigest, catalogDigest
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    capability = try container.decode(RuntimeCapability.self, forKey: .capability)
    requestID = try container.decode(String.self, forKey: .requestID)
    idempotencyKey = try container.decode(String.self, forKey: .idempotencyKey)
    requestFingerprintSHA256 = try container.decode(
      String.self, forKey: .requestFingerprintSHA256)
    operationReference = try container.decode(String.self, forKey: .operationReference)
    targetID = try container.decode(String.self, forKey: .targetID)
    bindingRevision = try container.decodeIfPresent(Int.self, forKey: .bindingRevision)
    stableIdentitySHA256 = try container.decodeIfPresent(
      String.self, forKey: .stableIdentitySHA256)
    workspaceIdentitySHA256 = try container.decodeIfPresent(
      String.self, forKey: .workspaceIdentitySHA256)
    workspaceRevision = try container.decodeIfPresent(String.self, forKey: .workspaceRevision)
    workspaceFileScopesDigest = try container.decodeIfPresent(
      String.self, forKey: .workspaceFileScopesDigest)
    materializedPlanDigest = try container.decode(String.self, forKey: .materializedPlanDigest)
    catalogDigest = try container.decode(String.self, forKey: .catalogDigest)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(capability, forKey: .capability)
    try container.encode(requestID, forKey: .requestID)
    try container.encode(idempotencyKey, forKey: .idempotencyKey)
    try container.encode(requestFingerprintSHA256, forKey: .requestFingerprintSHA256)
    try container.encode(operationReference, forKey: .operationReference)
    try container.encode(targetID, forKey: .targetID)
    try container.encodeIfPresent(bindingRevision, forKey: .bindingRevision)
    try container.encodeIfPresent(stableIdentitySHA256, forKey: .stableIdentitySHA256)
    try container.encodeIfPresent(workspaceIdentitySHA256, forKey: .workspaceIdentitySHA256)
    try container.encodeIfPresent(workspaceRevision, forKey: .workspaceRevision)
    try container.encodeIfPresent(
      workspaceFileScopesDigest, forKey: .workspaceFileScopesDigest)
    try container.encode(materializedPlanDigest, forKey: .materializedPlanDigest)
    try container.encode(catalogDigest, forKey: .catalogDigest)
  }
}

public enum RuntimeAvailabilityState: String, Sendable, Equatable {
  case available
  case unavailable
}

public struct RuntimeOperationAvailability: Sendable, Equatable {
  public let reference: String
  public let state: RuntimeAvailabilityState
  public let reasons: [String]

  public init(reference: String, state: RuntimeAvailabilityState, reasons: [String]) {
    self.reference = reference
    self.state = state
    self.reasons = reasons
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

/// Dispatch port: how a lowered process plan actually runs. Production
/// binds the descriptor-verifying executor (MU-3); tests inject fakes,
/// including crash and hang shapes.
public protocol RuntimeProcessDispatching: Sendable {
  func unavailableReason(providerID: String) -> String?
  func dispatch(_ plan: TypedProcessPlan) async throws -> ProviderProcessReceipt
}

extension RuntimeProcessDispatching {
  public func unavailableReason(providerID: String) -> String? { nil }
}

public enum RuntimeDispatchFailure: Error, Equatable, Sendable {
  /// The dispatcher cannot say whether the external effect happened.
  case outcomeUnknown(String)
  /// Exact provider readback proved that the attempted external effect did
  /// not happen. This remains a failed step, but its durable intent is safe
  /// for a bounded campaign to retry after a fresh reservation/readback.
  case confirmedNotExecuted(String)
  /// Same as `confirmedNotExecuted`, with a closed diagnostic that is safe to
  /// expose through a job timeline to the evolution campaign.  It must never
  /// contain raw subprocess output or device identity.
  case confirmedNotExecutedWithDiagnostic(
    String, diagnostic: RockchipFlashRuntimeDiagnostic)
  case failed(String)
}

private struct RuntimeArtifactPublicationFailure: Error, Sendable {
  let detail: String
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

  public struct Configuration: Sendable {
    public let stateDirectory: URL
    public let defaultReadOnlyPolicy: RuntimeDefaultReadOnlyPolicy
    public let admissionFaultInjector: RuntimeAdmissionFaultInjector

    public init(
      stateDirectory: URL,
      defaultReadOnlyPolicy: RuntimeDefaultReadOnlyPolicy = RuntimeDefaultReadOnlyPolicy(),
      admissionFaultInjector: RuntimeAdmissionFaultInjector = .none
    ) {
      self.stateDirectory = stateDirectory
      self.defaultReadOnlyPolicy = defaultReadOnlyPolicy
      self.admissionFaultInjector = admissionFaultInjector
    }
  }

  private struct JobRuntime {
    var record: RuntimeJobRecord
    var journal: FileDurableJournal
    var nextSequence: Int
    /// Confirmed provider steps reconstructed from the durable journal.
    /// A clean restart resumes after these exact actions instead of
    /// rebuilding progress from the current catalog.
    var completedStepIDs: Set<String> = []
    /// Steps that did not run. A downstream step whose upstream is here
    /// must not run either - otherwise a failed capture could still
    /// "receive" a product and the run would look complete.
    var skippedStepIDs: Set<String> = []
  }

  private struct MaterializedAdmission: Sendable {
    /// Absent for a host-only plan; a device-bound plan always carries both.
    let stableTargetIdentitySHA256: String?
    let bindingRevision: Int?
    let planDigest: String
  }

  private struct PreparedAuthorization: Sendable {
    let reference: RuntimeCapabilityReference?
    let evidence: RuntimeAdmissionEvidence?
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
    let steps: [MaterializedPlanStep]

    enum CodingKeys: String, CodingKey {
      case operationReference
      case catalogDigest
      case inputs
      case targetID
      case stableTargetIdentitySHA256
      case bindingRevision
      case providerID
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
  /// Campaign-lane E2 authority ledger, shared (file plus flock) with the
  /// campaign admission service that mints reservations. Absent means this
  /// runtime cannot honor campaign-reservation requests and refuses them.
  private let agentUsageLedger: AgentAuthorityUsageLedger?
  private let mutationLane = DeviceMutationLaneCoordinator()
  private let admissionService: RuntimeAdmissionService
  private let nowUTC: @Sendable () -> String
  private var jobs: [String: JobRuntime] = [:]
  private var cancellationRequests: Set<String> = []

  public init(
    configuration: Configuration,
    providers: DeviceProviderRegistry,
    dispatcher: any RuntimeProcessDispatching,
    capabilityStore: RuntimeCapabilityStore,
    artifactStore: RuntimeArtifactStore? = nil,
    agentUsageLedger: AgentAuthorityUsageLedger? = nil,
    nowUTC: @escaping @Sendable () -> String
  ) throws {
    self.configuration = configuration
    self.providers = providers
    self.dispatcher = dispatcher
    self.capabilityStore = capabilityStore
    self.artifactStore = artifactStore
    self.agentUsageLedger = agentUsageLedger
    self.nowUTC = nowUTC
    try FileManager.default.createDirectory(
      at: configuration.stateDirectory.appendingPathComponent("jobs", isDirectory: true),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    self.admissionService = try RuntimeAdmissionService(stateDirectory: configuration.stateDirectory)
  }

  public func operationAvailability() -> [RuntimeOperationAvailability] {
    RuntimeOperationCatalog.operations.map { descriptor in
      guard let provider = providers.provider(id: descriptor.provider.rawValue) else {
        return RuntimeOperationAvailability(
          reference: descriptor.reference,
          state: .unavailable,
          reasons: ["provider \(descriptor.provider.rawValue) is not registered"])
      }
      var reasons: [String] = []
      if case .unavailable(let reason) = provider.runtimeAvailability(for: descriptor) {
        reasons.append(reason)
      }
      if let reason = dispatcher.unavailableReason(providerID: descriptor.provider.rawValue) {
        if !reasons.contains(reason) {
          reasons.append(reason)
        }
      }
      if descriptor.reference == "debug.hap@1"
        || descriptor.reference == "deploy.native-library.app-owned@1"
        || descriptor.reference == "flash.dayu200@1"
        || RuntimeArtifactService.workspaceOperationReferences.contains(descriptor.reference),
        artifactStore == nil
      {
        reasons.append("runtime.artifactStoreUnavailable")
      }
      return RuntimeOperationAvailability(
        reference: descriptor.reference,
        state: reasons.isEmpty ? .available : .unavailable,
        reasons: reasons)
    }.sorted { $0.reference < $1.reference }
  }

  /// Materializes the exact typed plan through the same provider, target
  /// facts and Artifact lease path used by admission, then stops. This is the
  /// E2-safe review surface: no capability may be supplied, no Job is
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

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let canonicalRequestData: Data
    do {
      canonicalRequestData = try encoder.encode(request)
    } catch {
      throw RuntimeJobEngineError.internalFailure(
        "cannot canonicalize the typed plan-only request: \(error)")
    }
    let materialized = try await materializeTypedPlanBeforeAuthorization(
      request: request, descriptor: descriptor,
      jobID: Self.authorizationPlanJobID)
    let selectedSteps = descriptor.steps.filter {
      Self.stepIsRequested($0, descriptor: descriptor, inputs: request.inputs)
    }
    return RuntimePlanOnlyPreview(
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
      jobAdmitted: false,
      dispatchDisposition: "notDispatched")
  }

  /// Produces a reviewable authorization envelope without installing a
  /// capability, admitting a Job or dispatching a provider action. Provider
  /// availability, target facts, Artifact leases and every selected typed
  /// plan step must materialize before a draft is returned.
  ///
  /// E1 deviceMutation drafts are standing envelopes: the current plan
  /// digest is returned as a preview, and each later admission binds its
  /// own exact materialized digest in the durable lineage. E2 destructive
  /// drafts are exact-plan, single-use envelopes: the materialized plan
  /// digest is pinned into `exactPlanDigest` and the target must resolve to
  /// a stable physical identity. Either way the draft carries no authority:
  /// its issuer reference is a placeholder that the install gate refuses
  /// until a maintainer-merged PR reference replaces it (the trust root for
  /// E2 issuance is unchanged).
  public func draftCapability(
    _ requestData: Data,
    issuedAtUTC: String,
    expiresAtUTC: String,
    issuerReference: String,
    maximumUses: Int = 1
  ) async throws -> RuntimeCapabilityDraft {
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
    let effect = Self.effectiveEffect(descriptor: descriptor, inputs: request.inputs)
    guard effect == .deviceMutation || effect == .destructive else {
      throw RuntimeJobEngineError.rejected(
        .authorizationRequired,
        "capability drafting is limited to E1 deviceMutation and E2 destructive operations")
    }
    guard (1...32).contains(maximumUses) else {
      throw RuntimeJobEngineError.rejected(
        .invalidInput, "authorization envelope maximumUses must be between 1 and 32")
    }
    if effect == .destructive {
      // Refused before any materialization: the destructive envelope shape
      // is not negotiable, so a bad request must not resolve facts first.
      guard maximumUses == 1 else {
        throw RuntimeJobEngineError.rejected(
          .invalidInput,
          "a destructive exact-plan capability envelope is single-use (maximumUses must be 1)")
      }
    }

    var seed = requestData
    seed.append(Data("\n\(issuedAtUTC)\n\(expiresAtUTC)\n\(maximumUses)".utf8))
    let seedDigest = RuntimeJobRecord.sha256Hex(seed)
    let timestamp = issuedAtUTC.filter {
      $0.isASCII && ($0.isNumber || $0 == "T" || $0 == "Z")
    }
    let capabilityID =
      "CAP-RT-AUTO-\(timestamp)-\(seedDigest.prefix(12).uppercased())"
    let authorizedRequest: RuntimeOperationRequest
    do {
      authorizedRequest = try RuntimeOperationRequest(
        requestID: request.requestID,
        idempotencyKey: request.idempotencyKey,
        target: request.target,
        operation: request.operation,
        inputs: request.inputs,
        requestedOutputs: request.requestedOutputs,
        authorization: RuntimeCapabilityReference(capabilityID: capabilityID),
        clientContext: request.clientContext)
    } catch let rejection as RuntimeOperationRequestRejection {
      throw RuntimeJobEngineError.rejected(rejection.code, rejection.message)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let authorizedData: Data
    do {
      authorizedData = try encoder.encode(authorizedRequest)
    } catch {
      throw RuntimeJobEngineError.internalFailure(
        "cannot encode the materialized authorization request: \(error)")
    }
    let requestFingerprint = Self.fingerprint(of: authorizedData)
    let materialized = try await materializeTypedPlanBeforeAuthorization(
      request: authorizedRequest, descriptor: descriptor,
      jobID: Self.authorizationPlanJobID)
    let query = try authorizationQuery(
      request: authorizedRequest, descriptor: descriptor,
      effect: effect, materialized: materialized)
    let targetScope: RuntimeCapabilityTargetScope
    let draftBindingRevision: Int?
    let draftIdentity: String?
    let workspaceIdentity: String?
    let workspaceRevision: String?
    let workspaceScopes: String?
    if let identity = query.targetStableIdentitySHA256,
      let bindingRevision = query.targetBindingRevision
    {
      targetScope = .stablePhysicalIdentity(sha256: identity)
      draftBindingRevision = bindingRevision
      draftIdentity = identity
      workspaceIdentity = nil
      workspaceRevision = nil
      workspaceScopes = nil
    } else if let identity = query.workspaceIdentitySHA256,
      let revision = query.workspaceRevision,
      let scopes = query.workspaceFileScopesDigest
    {
      guard effect != .destructive else {
        throw RuntimeJobEngineError.rejected(
          .invalidRequest,
          "a destructive capability requires a stable physical device identity, "
            + "not a workspace subject")
      }
      // A standing grant names the tree and its maximum writable scopes, but
      // does not pin the tree to the revision at draft time: patch, build,
      // test and revert each move it. The review payload still carries the
      // observed revision below, and an operation request that declares
      // `expectedWorkspaceRevision` remains exactly constrained by its typed
      // input (TASK-HFA-009 r3).
      targetScope = .workspaceIdentity(
        sha256: identity, expectedWorkspaceRevision: "",
        allowedFileScopesDigest: scopes)
      draftBindingRevision = nil
      draftIdentity = nil
      workspaceIdentity = identity
      workspaceRevision = revision
      workspaceScopes = scopes
    } else {
      throw RuntimeJobEngineError.rejected(
        .invalidRequest,
        "\(descriptor.reference) has neither a device nor a workspace subject "
          + "to scope a capability to")
    }
    let capability: RuntimeCapability
    do {
      capability = try RuntimeCapability(
        capabilityID: capabilityID,
        targetScope: targetScope,
        operationScope: [
          RuntimeCapabilityOperationScope(
            operationID: descriptor.id, version: descriptor.version)
        ],
        effectCeiling: effect,
        inputConstraints: Self.exactCapabilityConstraints(for: request.inputs),
        issuedAtUTC: issuedAtUTC,
        expiresAtUTC: expiresAtUTC,
        maximumUses: maximumUses,
        issuer: RuntimeCapabilityIssuer(
          kind: .maintainerMergedPR, reference: issuerReference),
        exactPlanDigest: effect == .destructive ? materialized.planDigest : nil,
        exactBindingRevision: draftBindingRevision)
    } catch {
      throw RuntimeJobEngineError.rejected(
        .invalidInput, "generated capability would be invalid: \(error)")
    }
    return RuntimeCapabilityDraft(
      capability: capability,
      requestID: request.requestID,
      idempotencyKey: request.idempotencyKey,
      requestFingerprintSHA256: requestFingerprint,
      operationReference: descriptor.reference,
      targetID: request.target.targetID,
      bindingRevision: draftBindingRevision,
      stableIdentitySHA256: draftIdentity,
      workspaceIdentitySHA256: workspaceIdentity,
      workspaceRevision: workspaceRevision,
      workspaceFileScopesDigest: workspaceScopes,
      materializedPlanDigest: materialized.planDigest,
      catalogDigest: RuntimeOperationCatalog.catalogDigest)
  }

  // MARK: Submit

  public func submit(_ requestData: Data) async throws -> RuntimeJobAcceptance {
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

    // A retry/conflict is decided before capability consumption. Otherwise
    // a conflicting request could consume a different capability and then
    // be rejected by the idempotency ledger.
    let canonicalRequestData: Data
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
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
      return RuntimeJobAcceptance(jobID: existingJobID, deduplicated: true)
    case .conflict:
      throw RuntimeJobEngineError.idempotencyConflict(
        "idempotency key reuse with a different request")
    case .admitted:
      break
    }

    // Authorization must reflect what this request will actually do, not
    // the operation's floor. capture.diagnostics@1 is readOnly until the
    // inputs select the remote-file trace and its cleanup, at which point
    // it mutates the device and needs an E1 capability. Charging the
    // minimum effect here would let a mutating plan through on the default
    // read-only policy.
    let effectiveEffect = Self.effectiveEffect(
      descriptor: descriptor, inputs: request.inputs)
    let jobID = Self.stableJobID(
      idempotencyKey: request.idempotencyKey, requestFingerprint: fingerprint)
    let materialized = try await materializeTypedPlanBeforeAuthorization(
      request: request, descriptor: descriptor,
      jobID: Self.authorizationPlanJobID)
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
    record.state = JobState.preflight.rawValue
    record.timeline = ["jobCreated", "queued->preflight"]
    try configuration.admissionFaultInjector.check(.beforeAdmission)
    switch try admissionService.admit(record: record, requestHash: fingerprint) {
    case .duplicate(let existingJobID):
      return RuntimeJobAcceptance(jobID: existingJobID, deduplicated: true)
    case .conflict:
      throw RuntimeJobEngineError.idempotencyConflict(
        "idempotency key reuse with a different request")
    case .admitted:
      break
    }
    try configuration.admissionFaultInjector.check(.afterAdmission)

    let jobDirectory = configuration.stateDirectory
      .appendingPathComponent("jobs", isDirectory: true)
      .appendingPathComponent(jobID, isDirectory: true)
    try FileManager.default.createDirectory(
      at: jobDirectory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let journal = try FileDurableJournal(url: jobDirectory.appendingPathComponent("journal.jsonl"))
    try configuration.admissionFaultInjector.check(.beforeJournalAppend)
    try journal.appendAndSynchronize(
      JournalEvent.jobCreated(
        eventID: "job-created", sequence: 0, sessionID: record.sessionID, jobID: jobID,
        timestamp: timestamp, executionMode: "execute"))
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "to-preflight", sequence: 1, sessionID: record.sessionID, jobID: jobID,
        timestamp: timestamp, from: .queued, to: .preflight, reason: "admitted"))
    try configuration.admissionFaultInjector.check(.afterJournalAppend)
    try configuration.admissionFaultInjector.check(.beforeRecordPersist)
    try persistRuntimeRecord(record)
    try configuration.admissionFaultInjector.check(.afterRecordPersist)
    jobs[jobID] = JobRuntime(record: record, journal: journal, nextSequence: 2)
    try configuration.admissionFaultInjector.check(.beforeResponse)
    return RuntimeJobAcceptance(jobID: jobID, deduplicated: false)
  }

  // MARK: Run

  public func run(jobID: String) async throws -> RuntimeJobStatus {
    guard var runtime = jobs[jobID] else {
      throw RuntimeJobEngineError.jobNotFound(jobID)
    }
    guard
      runtime.record.state == JobState.preflight.rawValue
        || runtime.record.state == JobState.running.rawValue
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
    default:
      throw RuntimeJobEngineError.jobNotRunnable(
        "job \(jobID) is \(runtime.record.state), not runnable")
    }

    let isMutation =
      Self.effectiveEffect(
        descriptor: descriptor, inputs: runtime.record.request.inputs) >= .deviceMutation
    let targetID = runtime.record.request.target.targetID
    do {
      if isMutation {
        let capturedJobID = jobID
        try await mutationLane.withMutationLane(deviceID: targetID, requestID: capturedJobID) {
          [weak self] in
          guard let self else { throw RuntimeJobEngineError.internalFailure("engine gone") }
          try await self.executeSteps(
            jobID: capturedJobID, descriptor: descriptor, provider: provider)
        }
      } else {
        try await executeSteps(jobID: jobID, descriptor: descriptor, provider: provider)
      }
    } catch let failure as RuntimeDispatchFailure {
      var current = jobs[jobID] ?? runtime
      switch failure {
      case .outcomeUnknown(let reason):
        try transition(
          &current, from: .running, to: .waitingForRecovery, reason: "outcomeUnknown: \(reason)")
        current.record.outcomeUnknown = true
        current.record.finishedAtUTC = nowUTC()
        try persistRuntimeRecord(current.record)
        jobs[jobID] = current
        try await recordCapabilityOutcome(
          for: current.record, outcome: .outcomeUnknown,
          state: JobState.waitingForRecovery.rawValue)
        return statusAndReleaseTerminalRuntime(current.record)
      case .confirmedNotExecuted(let reason),
        .confirmedNotExecutedWithDiagnostic(let reason, _),
        .failed(let reason):
        // The state graph routes every terminal outcome through
        // finalizing: a job always gets its wrap-up phase, success or not.
        try transition(&current, from: .running, to: .finalizing, reason: reason)
        try transition(&current, from: .finalizing, to: .failed, reason: reason)
        current.record.finishedAtUTC = nowUTC()
        try persistRuntimeRecord(current.record)
        jobs[jobID] = current
        try await recordCapabilityOutcome(
          for: current.record, outcome: .confirmed,
          state: JobState.failed.rawValue)
        return statusAndReleaseTerminalRuntime(current.record)
      }
    } catch let failure as RuntimeArtifactPublicationFailure {
      var current = jobs[jobID] ?? runtime
      try transition(
        &current, from: .running, to: .finalizing,
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
      return statusAndReleaseTerminalRuntime(current.record)
    }

    var current = jobs[jobID] ?? runtime
    if cancellationRequests.contains(jobID) {
      cancellationRequests.remove(jobID)
      try transition(&current, from: .running, to: .cancelRequested, reason: "client-cancel")
      try transition(
        &current, from: .cancelRequested, to: .cancellingAtSafeBoundary,
        reason: "safe-boundary")
      try transition(
        &current, from: .cancellingAtSafeBoundary, to: .cancelled, reason: "steps-drained")
    } else {
      try transition(&current, from: .running, to: .finalizing, reason: "steps-complete")
      jobs[jobID] = current
      do {
        try await publishFinalizeArtifacts(jobID: jobID, descriptor: descriptor)
      } catch let failure as RuntimeArtifactPublicationFailure {
        current = jobs[jobID] ?? current
        try transition(
          &current, from: .finalizing, to: .failed,
          reason: "artifact finalization failed: \(failure.detail)")
        current.record.finishedAtUTC = nowUTC()
        try persistRuntimeRecord(current.record)
        jobs[jobID] = current
        try await recordCapabilityOutcome(
          for: current.record, outcome: .confirmed,
          state: JobState.failed.rawValue)
        return statusAndReleaseTerminalRuntime(current.record)
      }
      current = jobs[jobID] ?? current
      try transition(&current, from: .finalizing, to: .succeeded, reason: "finalized")
    }
    current.record.finishedAtUTC = nowUTC()
    try persistRuntimeRecord(current.record)
    jobs[jobID] = current
    try await recordCapabilityOutcome(
      for: current.record, outcome: .confirmed, state: current.record.state)
    return statusAndReleaseTerminalRuntime(current.record)
  }

  private func executeSteps(
    jobID: String,
    descriptor: CatalogOperationDescriptor,
    provider: any DeviceProvider
  ) async throws {
    var completedStepIDs = jobs[jobID]?.completedStepIDs ?? []
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
        // The confirmation step used to be a silent no-op. For a
        // destructive plan it is now the in-plan witness that the E2
        // authority doctrine held: the exact-plan capability (or campaign
        // reservation) IS the human confirmation — issued out-of-band by a
        // maintainer merged PR or a bounded campaign assertion — so the
        // step asserts that authority context instead of inventing a
        // second interactive gate (ADR-0004; PRODUCT-LOOP §14 zero-human
        // budget for authorized runs). Reaching it without that context is
        // an engine invariant break: fail closed.
        guard let record = jobs[jobID]?.record else {
          throw RuntimeDispatchFailure.failed("confirm step lost its job record")
        }
        let confirmEffect = Self.effectiveEffect(
          descriptor: descriptor, inputs: record.request.inputs)
        if confirmEffect == .destructive {
          // Consumption happens just before the first mutating step, which
          // is later than this one — so the witness here is the validated,
          // not-yet-consumed authority whose pins name this very plan.
          if let reference = record.request.authorization {
            guard
              let capabilityStatus = try await capabilityStore.inspect(
                capabilityID: reference.capabilityID),
              capabilityStatus.capability.effectCeiling == WorkflowEffect.destructive,
              capabilityStatus.capability.exactPlanDigest == record.materializedPlanDigest
            else {
              throw RuntimeDispatchFailure.failed(
                "confirm step could not re-verify the exact-plan E2 authority")
            }
            appendTimeline(
              jobID: jobID,
              entry:
                "flash intent confirmed by exact-plan capability \(reference.capabilityID)")
          } else if let campaign = record.request.campaignReservation {
            appendTimeline(
              jobID: jobID,
              entry:
                "flash intent confirmed by campaign reservation \(campaign.reservationID)")
          } else {
            throw RuntimeDispatchFailure.failed(
              "confirm step reached without an E2 authority reference")
          }
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
      let resolvedArtifact: ProviderResolvedInputArtifact?
      let additionalArtifacts: [ProviderResolvedInputArtifact]
      do {
        resolvedArtifact =
          step.kind == .sendFile
            // `debug.hap@1` proves the installed package by a later
            // package-readback step.  That step must receive the same
            // engine-resolved immutable Artifact facts as the send/install
            // legs; otherwise the provider can prove only that a bundle name
            // exists and the harness cannot bind deployment to the build
            // digest it just verified.
            || (descriptor.reference == "debug.hap@1"
              && (step.kind == .installPackage
                || step.kind == .runApprovedRemoteRead))
            || step.kind == .flashPartition
            || step.kind == .applyWorkspacePatch
            || step.kind == .symbolizeWorkspaceCrash
            || step.kind == .runDeterministicAnalyzer
            || descriptor.reference == "flash.dayu200@1"
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
        nowUTC: nowUTC(),
        resolvedInputArtifact: resolvedArtifact,
        additionalInputArtifacts: additionalArtifacts)
      let action: TypedProviderAction
      do {
        action = try provider.action(
          for: step, operation: descriptor,
          inputs: jobs[jobID]?.record.request.inputs ?? [:],
          context: context)
      } catch where step.isOptional {
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
        throw failure
      }
    }
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
    let cleanupPolicy: String
    if case .string(let policy)? = runtime.record.request.inputs["cleanupPolicy"] {
      cleanupPolicy = policy
    } else {
      cleanupPolicy = "uninstall"
    }
    if cleanupPolicy == "uninstall", completedStepIDs.contains("install-hap") {
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
  /// unconditionally (measured on the 2026-07-31 window: the harness then
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
  ]

  static let evidenceEligibleOperations: Set<String> = [
    "observe.device@1", "capture.diagnostics@1", "debug.hap@1",
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

  /// A host-only operation must be host-only all the way down. A device step
  /// or an effect above `hostOnly` inside one would reach the device through a
  /// path that skipped facts, binding and identity - so it is refused here,
  /// before anything is materialized, in addition to the generator's static
  /// check.
  static func validateHostOnlyDescriptor(_ descriptor: CatalogOperationDescriptor) throws {
    // A workspace mutation is the one thing without a device binding that may
    // exceed `hostOnly` (CHG-2026-055, TASK-HFA-009 r2). It is the E1 risk
    // class applied to a tree instead of a device, and it is only reachable
    // with a workspace-scoped standing capability. Everything else keeps the
    // original rule.
    let mutatingWorkspace =
      descriptor.provider == .workspace
      && descriptor.permittedEffects.allSatisfy({ $0 <= .deviceMutation })
      && descriptor.authorization[.deviceMutation] == .standingCapability
    guard descriptor.minimumEffect <= .hostOnly
      || (mutatingWorkspace && descriptor.minimumEffect == .deviceMutation)
    else {
      throw RuntimeJobEngineError.rejected(
        .invalidInput,
        "\(descriptor.reference) declares binding none but permits an effect above hostOnly")
    }
    guard descriptor.permittedEffects.allSatisfy({ $0 <= .hostOnly }) || mutatingWorkspace else {
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
      guard step.effect <= .hostOnly || (mutatingWorkspace && step.effect == .deviceMutation)
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
      let names = RuntimeArtifactService.artifactMapping[descriptor.reference]?[step.stepID]
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
    let workflowStep = try Self.journalStep(
      for: step, jobID: jobID, inputs: runtime.record.request.inputs,
      action: action, resolvedInputArtifact: context.resolvedInputArtifact)
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
        ? (runtime.record.request.target.expectedBindingRevision ?? 1) : nil)
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
    do {
      receipt = try await dispatcher.dispatch(plan)
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
            ? Self.confirmedNotExecutedSemanticCode : nil))
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

    let outcome = try provider.verify(receipt: receipt, action: action, context: context)
    var current = jobs[jobID] ?? runtime
    switch outcome {
    case .verified(let summary):
      let outcomeAt = nowUTC()
      try current.journal.appendAndSynchronize(
        JournalEvent.stepOutcome(
          eventID: "outcome-\(step.stepID)", sequence: current.nextSequence,
          sessionID: current.record.sessionID, jobID: jobID, timestamp: outcomeAt,
          stepID: step.stepID, attempt: 1,
          correlatesToIntentEventID: intentEventID,
          result: "succeeded", outcomeCertainty: .confirmed))
      current.nextSequence += 1
      current.record.timeline.append("verified \(step.stepID) \(summary.keys.sorted())")
      current.record.recoveryStepID = nil
      current.record.recoveryIntentEventID = nil
      current.record.recoveryAction = nil
      jobs[jobID] = current
      try captureEvidencePreflightFragmentIfEligible(
        jobID: jobID, step: step, action: action, summary: summary,
        context: context, facts: evidenceFacts, outcomeAtUTC: outcomeAt,
        descriptor: descriptor)
      try await publishDeclaredArtifacts(
        jobID: jobID, step: step, summary: summary, receipt: receipt)
    case .failed(let code, let detail):
      try current.journal.appendAndSynchronize(
        JournalEvent.stepOutcome(
          eventID: "outcome-\(step.stepID)", sequence: current.nextSequence,
          sessionID: current.record.sessionID, jobID: jobID, timestamp: nowUTC(),
          stepID: step.stepID, attempt: 1,
          correlatesToIntentEventID: intentEventID,
          result: "failed", outcomeCertainty: .confirmed))
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
            result: "succeeded", outcomeCertainty: .confirmed))
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
    case ("read-evidence-model", .hdc(.queryProperty(.productModel))):
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
      runtime.record.evidenceObservation = RuntimeEvidenceObservation(
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
        confirmationMethod: "machineReadback",
        preflightSteps: accumulator.steps)
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
    guard let mapping = RuntimeArtifactService.artifactMapping[descriptor.reference]?[step.stepID] else {
      return  // this step owns no declared product
    }
    guard let artifactStore else {
      if descriptor.reference == "flash.dayu200@1" {
        throw RuntimeArtifactPublicationFailure(
          detail: "Artifact store is required for \(descriptor.reference)")
      }
      return
    }
    let binding = RuntimeArtifactService.bindingSnapshot(for: runtime.record)
    for name in mapping {
      guard let declaration = descriptor.artifacts.first(where: { $0.name == name }) else {
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
        if let landed, RuntimeArtifactService.fileBackedArtifacts.contains(name), let sha256 = landed.sha256 {
          metadata = try await artifactStore.publishFile(
            RuntimeArtifactFilePublicationRequest(
              jobID: jobID, sessionID: runtime.record.sessionID, stepID: step.stepID,
              name: name, mediaType: declaration.mediaType, privacy: declaration.privacy,
              retentionClass: declaration.retentionClass,
              sourceOperation: descriptor.reference, providerID: descriptor.provider.rawValue,
              bindingSnapshot: binding, sourceFileURL: landed.localURL,
              expectedByteCount: landed.byteCount, expectedSHA256: sha256))
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
              SHA256.hash(data: received).map({ String(format: "%02x", $0) }).joined()
                == landed.sha256
            else {
              throw RuntimeArtifactPublicationFailure(
                detail: "\(name) changed between receive and publication")
            }
            contents = received
          }
          metadata = try await artifactStore.publish(
            RuntimeArtifactPublicationRequest(
              jobID: jobID, sessionID: runtime.record.sessionID, stepID: step.stepID,
              name: name, mediaType: declaration.mediaType, privacy: declaration.privacy,
              retentionClass: declaration.retentionClass,
              sourceOperation: descriptor.reference, providerID: descriptor.provider.rawValue,
              bindingSnapshot: binding, contents: contents))
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
      let names = RuntimeArtifactService.finalizeArtifacts[descriptor.reference]
    else { return }
    guard let artifactStore else {
      if descriptor.reference == "flash.dayu200@1" {
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
      if descriptor.reference == "flash.dayu200@1" {
        throw RuntimeArtifactPublicationFailure(
          detail: "required Flash artifacts are missing: "
            + missingRequired.map(\.name).sorted().joined(separator: ", "))
      }
    }
  }

  // MARK: Cancel / status / recovery

  public func requestCancel(jobID: String) throws {
    guard jobs[jobID] != nil else { throw RuntimeJobEngineError.jobNotFound(jobID) }
    cancellationRequests.insert(jobID)
  }

  public func status(jobID: String) throws -> RuntimeJobStatus {
    status(of: try recordForRead(jobID: jobID))
  }

  public func evidenceSnapshot(jobID: String) throws -> RuntimeJobEvidenceSnapshot {
    let record = try recordForRead(jobID: jobID)
    return RuntimeJobEvidenceSnapshot(
      jobID: record.jobID,
      operationReference: record.operationReference,
      catalogDigest: record.catalogDigest,
      targetID: record.request.target.targetID,
      bindingRevision: record.request.target.expectedBindingRevision,
      providerID: record.providerID,
      actualEffect: record.actualEffect,
      authority: record.admissionEvidence,
      observation: record.evidenceObservation,
      actualStepKinds: record.actualStepKinds ?? [],
      executionMode: "execute",
      terminalState: record.outcomeUnknown ? "outcomeUnknown" : record.state,
      outcomeUnknown: record.outcomeUnknown,
      startedAtUTC: record.startedAtUTC,
      firstEvidenceStepAtUTC: record.firstEvidenceStepAtUTC,
      finishedAtUTC: record.finishedAtUTC)
  }

  /// Artifact names omitted by the exact materialized request, including
  /// downstream optional products whose upstream was not selected. This
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
    return Set(
      omittedSteps.flatMap {
        RuntimeArtifactService.artifactMapping[descriptor.reference]?[$0] ?? []
      })
  }

  /// Returns both active Runtime snapshots and durable terminal history.  The
  /// latter is projected from SQLite so callers keep the established `job.list`
  /// behaviour without forcing the daemon to retain a journal writer per
  /// completed job.
  public func listJobs() -> [RuntimeJobStatus] {
    var statuses: [String: RuntimeJobStatus] = [:]
    if let persisted = try? admissionService.allJobs() {
      for row in persisted {
        guard let data = row.initialRecordData,
          let record = try? JSONDecoder().decode(RuntimeJobRecord.self, from: data)
        else { continue }
        statuses[record.jobID] = status(of: record)
      }
    }
    // Active snapshots can contain timeline entries accumulated since their
    // last durable projection; they take precedence over the history index.
    for runtime in jobs.values {
      statuses[runtime.record.jobID] = status(of: runtime.record)
    }
    return statuses.values.sorted { $0.jobID < $1.jobID }
  }

  /// Reads compact terminal history from SQLite.  Active jobs still return
  /// their in-memory snapshots above; both views use the same typed status
  /// model and opaque cursor contract.
  public func listJobs(pageSize: Int, cursor: String? = nil) throws -> RuntimeJobStatusPage {
    let page = try admissionService.listJobs(pageSize: pageSize, cursor: cursor)
    let statuses = try page.jobs.map { persisted -> RuntimeJobStatus in
      guard let data = persisted.initialRecordData,
        let record = try? JSONDecoder().decode(RuntimeJobRecord.self, from: data)
      else {
        throw RuntimeJobEngineError.internalFailure(
          "Runtime job history record \(persisted.jobID) is unreadable")
      }
      return status(of: record)
    }
    return RuntimeJobStatusPage(jobs: statuses, nextCursor: page.nextCursor)
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
    _ = try await artifactStore.beginCleanupDebtRetry(
      jobID: jobID, identity: identity)
    let plan = try provider.lower(action: action, context: context)
    guard plan.action == action, plan.action.effect == .deviceMutation else {
      throw RuntimeJobEngineError.internalFailure(
        "cleanup debt did not lower to its exact typed mutation")
    }
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
  private func recover(records persistedJobs: [RuntimePersistedJob]) async throws -> [RuntimeJobStatus] {
    for persisted in persistedJobs {
      try restoreInitialAdmissionProjectionIfNeeded(persisted)
    }
    var recovered: [RuntimeJobStatus] = []
    for persisted in persistedJobs {
      let jobID = persisted.jobID
      if jobs[jobID] != nil { continue }
      let entry = jobDirectory(for: jobID)
      guard var record = try? RuntimeJobRecord.load(from: entry) else {
        throw RuntimeJobEngineError.internalFailure(
          "admitted job \(jobID) has no readable durable record after recovery projection")
      }
      let journalURL = entry.appendingPathComponent("journal.jsonl")
      let journal = try FileDurableJournal(url: journalURL)
      var inspection = try DurableJournalRecovery.inspect(url: journalURL)
      var nextSequence = Int((inspection.lastDurableSequence ?? -1) + 1)

      // A crash after reconcileOutcome may leave its mandatory triggered
      // transition unwritten. Finish that journal-only decision before
      // considering any provider work.
      if let last = inspection.events.last,
        last.kind == .reconcileOutcome,
        case .string(let nextStateRaw)? = last.payload["nextState"],
        let nextState = JobState(rawValue: nextStateRaw)
      {
        try journal.appendAndSynchronize(
          JournalEvent.stateTransition(
            eventID: "recovery-t-\(nextSequence)", sequence: nextSequence,
            sessionID: record.sessionID, jobID: jobID, timestamp: nowUTC(),
            from: .reconciling, to: nextState,
            reason: "complete durable reconcile decision after restart",
            triggerEventID: last.eventID))
        nextSequence += 1
        inspection = try DurableJournalRecovery.inspect(url: journalURL)
      }

      let hasUnresolvedProviderIntent =
        inspection.hasTornTail || !inspection.outstandingIntents.isEmpty
        || !inspection.unknownOutcomes.isEmpty
        || inspection.lastReconcileOutcomeCertainty == .outcomeUnknown
      if hasUnresolvedProviderIntent,
        let currentState = inspection.currentState,
        currentState != .waitingForRecovery,
        currentState != .reconciling,
        JobStateMachine.isAllowedTransition(
          from: currentState, to: .waitingForRecovery, mode: .execute)
      {
        try journal.appendAndSynchronize(
          JournalEvent.stateTransition(
            eventID: "recovery-t-\(nextSequence)", sequence: nextSequence,
            sessionID: record.sessionID, jobID: jobID, timestamp: nowUTC(),
            from: currentState, to: .waitingForRecovery,
            reason: "durably park unresolved provider intent after restart"))
        nextSequence += 1
        inspection = try DurableJournalRecovery.inspect(url: journalURL)
      }

      if hasUnresolvedProviderIntent {
        record.state = (inspection.currentState ?? .waitingForRecovery).rawValue
        record.outcomeUnknown = true
        if record.recoveryStepID == nil {
          record.recoveryStepID =
            inspection.unknownOutcomes.last?.stepID
            ?? inspection.outstandingIntents.last?.stepID
        }
        record.timeline.append("recovered: outstanding intents or unknown outcomes; no redispatch")
      } else {
        // The quiet crash window: a process killed between one durable event
        // and the next leaves a clean journal whose non-terminal state never
        // advances on its own. preflight/running/resumeAtConfirmedSafeBoundary
        // keep their explicit `run` resume lane below, and
        // waitingForRecovery/reconciling keep the reconcile lane. But
        // cancelRequested, cancellingAtSafeBoundary and finalizing have no
        // post-restart lane at all — `run` rejects them and `reconcile` only
        // answers unknown outcomes — so leaving them in place presents a dead
        // run as healthy forever. Each of these states is an already-durable
        // decision, so recovery finishes it journal-only: a clean journal
        // proves no step was in flight, which is exactly the cancel lane's
        // safe boundary; and a job that never durably reached its terminal
        // transition did not complete finalization, which is failed, never
        // succeeded. No dispatch happens in any branch.
        switch inspection.currentState {
        case .cancelRequested, .cancellingAtSafeBoundary:
          if inspection.currentState == .cancelRequested {
            try journal.appendAndSynchronize(
              JournalEvent.stateTransition(
                eventID: "recovery-t-\(nextSequence)", sequence: nextSequence,
                sessionID: record.sessionID, jobID: jobID, timestamp: nowUTC(),
                from: .cancelRequested, to: .cancellingAtSafeBoundary,
                reason: "process loss with no outstanding intent is a confirmed safe boundary"))
            nextSequence += 1
          }
          try journal.appendAndSynchronize(
            JournalEvent.stateTransition(
              eventID: "recovery-t-\(nextSequence)", sequence: nextSequence,
              sessionID: record.sessionID, jobID: jobID, timestamp: nowUTC(),
              from: .cancellingAtSafeBoundary, to: .cancelled,
              reason: "complete durable cancellation after restart"))
          nextSequence += 1
          inspection = try DurableJournalRecovery.inspect(url: journalURL)
          record.finishedAtUTC = nowUTC()
          record.timeline.append(
            "recovered: completed durable cancellation at journal-confirmed safe boundary; no redispatch"
          )
        case .finalizing:
          try journal.appendAndSynchronize(
            JournalEvent.stateTransition(
              eventID: "recovery-t-\(nextSequence)", sequence: nextSequence,
              sessionID: record.sessionID, jobID: jobID, timestamp: nowUTC(),
              from: .finalizing, to: .failed,
              reason: "finalization was interrupted before its terminal transition"))
          nextSequence += 1
          inspection = try DurableJournalRecovery.inspect(url: journalURL)
          record.finishedAtUTC = nowUTC()
          // A clean finalizing journal that carries outcomeUnknown got here
          // through a durable confirmed reconcile decision; mirror the
          // in-session reconcile lane, which clears the flag on this exact
          // finalizing->failed completion.
          if inspection.lastReconcileOutcomeCertainty == .confirmed {
            record.outcomeUnknown = false
            record.recoveryStepID = nil
            record.recoveryIntentEventID = nil
            record.recoveryAction = nil
          }
          record.timeline.append(
            "recovered: finalization interrupted before terminal transition; failed without redispatch"
          )
        default:
          record.timeline.append("recovered: journal clean")
        }
        if let currentState = inspection.currentState {
          record.state = currentState.rawValue
        }
        if inspection.currentState == .resumeAtConfirmedSafeBoundary,
          inspection.lastReconcileOutcomeCertainty == .confirmed
        {
          record.outcomeUnknown = false
          record.recoveryStepID = nil
          record.recoveryIntentEventID = nil
          record.recoveryAction = nil
        }
      }
      try persistRuntimeRecord(record)
      recovered.append(status(of: record))
      jobs[jobID] = JobRuntime(
        record: record, journal: journal,
        nextSequence: nextSequence,
        completedStepIDs: Self.confirmedSucceededStepIDs(in: inspection))
      if record.outcomeUnknown {
        try await recordCapabilityOutcome(
          for: record, outcome: .outcomeUnknown,
          state: JobState.waitingForRecovery.rawValue)
      } else if JobState(rawValue: record.state)?.isTerminal == true {
        try await recordCapabilityOutcome(
          for: record, outcome: .confirmed, state: record.state)
      }
    }
    return recovered
  }

  public func reconcile(jobID: String) async throws -> RuntimeJobStatus {
    guard var runtime = jobs[jobID] else {
      return status(of: try recordForRead(jobID: jobID))
    }
    guard runtime.record.outcomeUnknown else {
      return statusAndReleaseTerminalRuntime(runtime.record)
    }
    let journalURL = jobDirectory(for: jobID).appendingPathComponent("journal.jsonl")
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
        for: runtime.record, outcome: .confirmed,
        state: JobState.failed.rawValue)
      return statusAndReleaseTerminalRuntime(runtime.record)
    }
    guard inspection.unknownOutcomes.isEmpty else {
      runtime.record.timeline.append(
        "reconcile refused: legacy outcomeUnknown event cannot be rewritten; original not resent")
      try persistRuntimeRecord(runtime.record)
      jobs[jobID] = runtime
      return status(of: runtime.record)
    }
    guard let provider = providers.provider(id: runtime.record.providerID) else {
      throw RuntimeJobEngineError.internalFailure("provider vanished for \(jobID)")
    }
    guard let stepID = runtime.record.recoveryStepID,
      let persistedAction = runtime.record.recoveryAction,
      let intentEventID = runtime.record.recoveryIntentEventID
    else {
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
          trigger: "manual"))
      runtime.nextSequence += 1
      runtime.record.timeline.append("reconcile started \(stepID)")
      jobs[jobID] = runtime
      inspection = try DurableJournalRecovery.inspect(url: journalURL)
    }

    // Host-only jobs are not reconciled against a device: there is no readback
    // to perform and no device outcome to confirm, so asking a provider for
    // facts here would be asking it to invent them.
    if let hostOnlyDescriptor = RuntimeOperationCatalog.descriptor(
      reference: runtime.record.request.operation.reference),
      hostOnlyDescriptor.binding == .none
    {
      throw RuntimeJobEngineError.jobNotRunnable(
        "\(jobID) is host-only: it has no device outcome to reconcile")
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
      jobID: jobID, stepID: stepID,
      targetID: runtime.record.request.target.targetID,
      bindingRevision: runtime.record.request.target.expectedBindingRevision,
      connectKey: facts.executionConnectKey,
      expectedIdentitySHA256: facts.deviceIdentitySHA256,
      toolVersion: facts.toolVersion,
      toolSHA256: facts.toolSHA256,
      nowUTC: nowUTC())
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
          nowUTC: context.nowUTC,
          resolvedInputArtifact: context.resolvedInputArtifact)
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
            bindingRevision: facts.bindingRevision)
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
    return try await finishReconcile(
      runtime: &runtime, inspection: inspection,
      intentEventID: intentEventID, stepID: stepID,
      recoveryAttemptID: recoveryAttemptID, outcome: outcome,
      bindingRevision: facts.bindingRevision)
  }

  private func finishReconcile(
    runtime: inout JobRuntime,
    inspection: JournalReplay,
    intentEventID: String,
    stepID: String,
    recoveryAttemptID: String,
    outcome: ProviderReconcileOutcome,
    bindingRevision: Int?
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
            outcomeCertainty: .confirmed))
        runtime.nextSequence += 1
      }
      nextState = .resumeAtConfirmedSafeBoundary
      reconcileResult = "resumeAtConfirmedSafeBoundary"
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
            outcomeCertainty: .confirmed))
        runtime.nextSequence += 1
      }
      // An unknown action is never resent automatically, even when it was
      // read-only. A confirmed non-execution is a definitive failed step.
      nextState = .finalizing
      reconcileResult = "finalizeConfirmedFailure"
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
      evidence: [detail])
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
      runtime.record.recoveryStepID = nil
      runtime.record.recoveryIntentEventID = nil
      runtime.record.recoveryAction = nil
      runtime.record.timeline.append("reconciled: confirmed completed \(stepID)")
    case .confirmedNotExecuted:
      try transition(
        &runtime, from: .finalizing, to: .failed,
        reason: "reconciliation confirmed \(stepID) did not complete")
      runtime.record.outcomeUnknown = false
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
        for: runtime.record, outcome: .confirmed,
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
    return statusAndReleaseTerminalRuntime(runtime.record)
  }

  // MARK: Helpers

  private static func reconciliationStepID(
    originalStepID: String,
    recoveryAttemptID: String
  ) -> String {
    let attemptDigest = SHA256.hash(data: Data(recoveryAttemptID.utf8))
      .map { String(format: "%02x", $0) }.joined()
    return
      "reconcile-\(originalStepID.prefix(72))-\(attemptDigest.prefix(32))"
  }

  private func verifyHostInputArtifact(
    jobID: String,
    descriptor: CatalogOperationDescriptor,
    step: CatalogStepDescriptor
  ) async throws {
    if descriptor.reference == "flash.dayu200@1" {
      guard let resolved = try await resolvedInputArtifact(jobID: jobID) else {
        throw RuntimeDispatchFailure.failed(
          "flash host verification cannot resolve its typed imageBundleLease")
      }
      let summary: GzipTarArchiveSummary
      do {
        summary = try GzipTarArchiveReader.summarize(fileAt: resolved.fileURL)
      } catch {
        throw RuntimeDispatchFailure.failed(
          "flash host verification cannot read the leased archive: \(error)")
      }
      guard summary.archiveSHA256 == resolved.sha256,
        summary.archiveSizeBytes == Int64(resolved.byteCount)
      else {
        throw RuntimeDispatchFailure.failed(
          "flash bundle bytes drifted from the leased hash/size")
      }
      guard case .string(let profileReference)? =
        jobs[jobID]?.record.request.inputs["deviceProfile"],
        let profile = RockchipFlashProfile.profile(reference: profileReference)
      else {
        throw RuntimeDispatchFailure.failed(
          "flash request has no published versioned DAYU200 profile")
      }
      switch profile.validate(summary.archiveObservation()) {
      case .valid:
        appendTimeline(
          jobID: jobID,
          entry:
            "\(step.stepID) profile=\(profile.catalogReference) "
            + "sha256=\(summary.archiveSHA256)")
        return
      case .blocked(let violations):
        throw RuntimeDispatchFailure.failed(
          "flash bundle violates the pinned DAYU200 profile: "
            + violations.map(\.description).joined(separator: "; "))
      }
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
      guard case .string(let value)? =
        runtime.record.request.inputs["hapArtifactLease"]
      else { return nil }
      lease = value
    case "deploy.native-library.app-owned@1":
      guard case .string(let value)? =
        runtime.record.request.inputs["libraryArtifactLease"]
      else { return nil }
      lease = value
    case "flash.dayu200@1":
      guard case .string(let value)? =
        runtime.record.request.inputs["imageBundleLease"]
      else { return nil }
      lease = value
    case "workspace.apply-patch@1":
      guard case .string(let value)? =
        runtime.record.request.inputs["patchArtifactRef"]
      else { return nil }
      lease = value
    case "workspace.symbolize-crash@1":
      guard case .string(let value)? =
        runtime.record.request.inputs["dumpArtifactRef"]
      else { return nil }
      lease = value
    case "analyzer.extract-crash-signature@1", "analyzer.summarize-hilog@1",
      "analyzer.summarize-trace@1":
      guard case .string(let value)? =
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
      allowDeviceBoundAnalyzerSource: runtime.record.providerID == CatalogProvider.analyzer.rawValue)
    return ProviderResolvedInputArtifact(
      artifactID: resolved.artifactID, fileURL: resolved.fileURL,
      sha256: resolved.sha256, byteCount: resolved.byteCount)
  }

  private static func validateArtifactBinding(
    _ binding: ArtifactBindingSnapshot,
    request: RuntimeOperationRequest,
    materializedStableIdentitySHA256: String?,
    allowDeviceBoundAnalyzerSource: Bool = false
  ) throws {
    if allowDeviceBoundAnalyzerSource,
      request.target.expectedBindingRevision == nil,
      binding.targetID == request.target.targetID
    {
      // The analyzer is host-only and cannot act on the device. It may read
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
    guard let provider = providers.provider(id: descriptor.provider.rawValue) else {
      throw RuntimeJobEngineError.rejected(
        .invalidInput, "provider \(descriptor.provider.rawValue) is not registered")
    }
    if case .unavailable(let reason) = provider.runtimeAvailability(for: descriptor) {
      throw RuntimeJobEngineError.rejected(
        .invalidInput, "\(descriptor.reference) is runtime unavailable: \(reason)")
    }
    if let reason = dispatcher.unavailableReason(providerID: descriptor.provider.rawValue) {
      throw RuntimeJobEngineError.rejected(
        .invalidInput, "\(descriptor.reference) is runtime unavailable: \(reason)")
    }
    if RuntimeArtifactService.workspaceOperationReferences.contains(descriptor.reference),
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
    let leaseInputName: String?
    let artifactLabel: String
    switch descriptor.reference {
    case "debug.hap@1":
      leaseInputName = "hapArtifactLease"
      artifactLabel = "HAP"
    case "deploy.native-library.app-owned@1":
      leaseInputName = "libraryArtifactLease"
      artifactLabel = "native library"
    case "flash.dayu200@1":
      leaseInputName = "imageBundleLease"
      artifactLabel = "flash bundle"
    case "workspace.apply-patch@1":
      leaseInputName = "patchArtifactRef"
      artifactLabel = "workspace patch"
    case "workspace.symbolize-crash@1":
      leaseInputName = "dumpArtifactRef"
      artifactLabel = "workspace crash dump"
    case "analyzer.extract-crash-signature@1", "analyzer.summarize-hilog@1",
      "analyzer.summarize-trace@1":
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
          allowDeviceBoundAnalyzerSource: descriptor.provider == .analyzer)
        resolved = ProviderResolvedInputArtifact(
          artifactID: artifact.artifactID, fileURL: artifact.fileURL,
          sha256: artifact.sha256, byteCount: artifact.byteCount)
      } catch {
        throw RuntimeJobEngineError.rejected(
          .invalidInput, "\(artifactLabel) Artifact lease is not resolvable: \(error)")
      }
    } else {
      resolved = nil
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
          nowUTC: nowUTC(), resolvedInputArtifact: resolved,
          additionalInputArtifacts: additionalResolved)
        let action = try provider.action(
          for: step, operation: descriptor, inputs: request.inputs,
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
          for: step, jobID: context.jobID, inputs: request.inputs,
          action: action, resolvedInputArtifact: resolved)
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
        }
      }
      if descriptor.reference == "deploy.native-library.app-owned@1" {
        guard let publishStep = descriptor.steps.first(where: {
          $0.stepID == "atomic-publish"
        }) else {
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
          nowUTC: nowUTC(), resolvedInputArtifact: resolved)
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
          action: rollbackAction, resolvedInputArtifact: resolved)
        guard case .processSequence(
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
        operationReference: descriptor.reference,
        catalogDigest: RuntimeOperationCatalog.catalogDigest,
        inputs: request.inputs,
        targetID: request.target.targetID,
        stableTargetIdentitySHA256: stableIdentity,
        bindingRevision: bindingRevision,
        providerID: descriptor.provider.rawValue,
        steps: materializedSteps)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      let encoded = try encoder.encode(document)
      return MaterializedAdmission(
        stableTargetIdentitySHA256: stableIdentity,
        bindingRevision: bindingRevision,
        planDigest: RuntimeJobRecord.sha256Hex(encoded))
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
      if inputs["redactionProfile"] == .string("strict") {
        throw RuntimeJobEngineError.rejected(
          .invalidInput,
          "strict redaction has no published implementation; refusing before authorization")
      }
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
    if descriptor.reference == "deploy.native-library.app-owned@1" {
      if case .string(let profile)? = inputs["restartProfile"],
        profile != HDCNativeRestartProfile.restartAbility.rawValue
      {
        throw RuntimeJobEngineError.rejected(
          .invalidInput,
          "\(profile) has no complete app-owned restart/readback plan; "
            + "refusing before authorization")
      }
      return
    }
    guard descriptor.reference == "debug.hap@1" else { return }
    if inputs["installPolicy"] == .string("installFresh") {
      throw RuntimeJobEngineError.rejected(
        .invalidInput,
        "installFresh has no published pre-install absence readback; refusing before authorization")
    }
    if inputs["cleanupPolicy"] == .string("restorePrevious") {
      throw RuntimeJobEngineError.rejected(
        .invalidInput,
        "restorePrevious has no published snapshot/restore step; refusing before authorization")
    }
    if inputs["portForwardProfile"] == .string("debugger-default") {
      throw RuntimeJobEngineError.rejected(
        .invalidInput,
        "debugger-default has no published port-forward steps; refusing before authorization")
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
        targetStableIdentitySHA256: identity,
        targetBindingRevision: bindingRevision,
        planDigest: materialized.planDigest,
        inputs: request.inputs)
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
      workspaceIdentitySHA256: workspace.identitySHA256,
      workspaceRevision: workspace.revision,
      workspaceFileScopesDigest: workspace.fileScopesDigest)
  }

  /// Performs every pure authorization check at submit, after the complete
  /// typed plan has materialized. Published E1 operations with default policy
  /// issuance enabled receive a deterministic runtime-owned capability when
  /// the caller supplies none. E1/E2 uses are deliberately not consumed here:
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
          consumptionFingerprintSHA256: nil))
    }

    guard let policy = descriptor.authorization[effect] else {
      throw RuntimeJobEngineError.rejected(
        .authorizationRequired,
        "catalog has no authorization policy for effect \(effect.rawValue)")
    }
    let query = try authorizationQuery(
      request: request, descriptor: descriptor,
      effect: effect, materialized: materialized)

    if let campaign = request.campaignReservation {
      try validateCampaignReservation(
        campaign, effect: effect, descriptor: descriptor, query: query,
        admittedAtUTC: admittedAt)
      // Evidence is recorded at consume time, mirroring the capability lane:
      // admission validates, the moment before the first mutation binds.
      return PreparedAuthorization(reference: nil, evidence: nil)
    }

    let authorization: RuntimeCapabilityReference
    if let supplied = request.authorization {
      authorization = supplied
    } else if effect == .deviceMutation,
      policy == .standingCapability,
      descriptor.defaultPolicyIssuanceEnabled,
      // Automatic issuance is a *device* policy. A workspace mutation must
      // carry a grant a maintainer issued against this tree, this revision and
      // these writable scopes (CHG-2026-055 TASK-HFA-009 r2, HTP-INV-6): a
      // runtime that mints its own workspace capability is a gate authorizing
      // itself. Without this clause the path below would try, and would only
      // fail because the device identity it needs happens to be empty.
      query.workspaceIdentitySHA256 == nil
    {
      authorization = try await automaticE1Capability(
        descriptor: descriptor, query: query)
    } else {
      throw RuntimeJobEngineError.rejected(
        .authorizationRequired,
        "effect \(effect.rawValue) requires an explicit runtime capability")
    }
    do {
      try await capabilityStore.validateNewExecution(
        capabilityID: authorization.capabilityID,
        query: query,
        nowUTC: admittedAt)
      return PreparedAuthorization(reference: authorization, evidence: nil)
    } catch let error as RuntimeCapabilityStoreError {
      throw RuntimeJobEngineError.rejected(
        .authorizationRequired,
        "capability denied \(Self.capabilityDenialMarker)\(Self.denialCode(of: error))]: "
          + "\(error)")
    }
  }

  /// Opens the machine-readable half of a capability rejection message, closed
  /// by `]`. Its counterpart is `HarnessTaskCoordinator.capabilityDenialMarker`;
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

  /// Re-verifies a campaign reservation's embedded confirmation pins against
  /// this request's materialized facts. The reservation is the single-use
  /// marker (one open reservation per target, ledger-enforced); the engine
  /// never reserves here — the campaign admission service did, after its own
  /// nine-gate check — and the engine closes it with the job's terminal.
  private func validateCampaignReservation(
    _ campaign: RuntimeCampaignReservationReference,
    effect: WorkflowEffect,
    descriptor: CatalogOperationDescriptor,
    query: RuntimeCapabilityAuthorizationQuery,
    admittedAtUTC: String
  ) throws {
    guard let ledger = agentUsageLedger else {
      throw RuntimeJobEngineError.rejected(
        .authorizationRequired,
        "campaign authority is unavailable in this runtime (no usage ledger)")
    }
    guard effect == .destructive else {
      throw RuntimeJobEngineError.rejected(
        .authorizationRequired,
        "a campaign reservation only authorizes a destructive flash, not \(effect.rawValue)")
    }
    guard
      descriptor.reference == RockchipEvolutionCampaignConfirmationAssertion.operationReference
    else {
      throw RuntimeJobEngineError.rejected(
        .authorizationRequired,
        "campaign confirmations pin \(RockchipEvolutionCampaignConfirmationAssertion.operationReference), "
          + "not \(descriptor.reference)")
    }
    guard
      let reservation = try ledger.load().reservations.first(where: {
        $0.reservationID == campaign.reservationID
      })
    else {
      throw RuntimeJobEngineError.rejected(
        .authorizationRequired,
        "campaign reservation \(campaign.reservationID) does not exist")
    }
    guard reservation.terminal == nil else {
      throw RuntimeJobEngineError.rejected(
        .authorizationRequired,
        "campaign reservation \(campaign.reservationID) is already terminal")
    }
    guard
      case .evolutionCampaignConfirmation(
        _, _, _, _, _, let targetStableIdentitySHA256, let bindingLineageRootRevision,
        let confirmedAt, let validUntil, let maximumAttempts) = reservation.authorizationRef
    else {
      throw RuntimeJobEngineError.rejected(
        .authorizationRequired,
        "reservation \(campaign.reservationID) does not carry a campaign confirmation")
    }
    let formatter = ISO8601DateFormatter()
    guard let admitted = formatter.date(from: admittedAtUTC),
      let windowStart = formatter.date(from: confirmedAt),
      let windowEnd = formatter.date(from: validUntil),
      admitted >= windowStart, admitted <= windowEnd
    else {
      throw RuntimeJobEngineError.rejected(
        .authorizationRequired,
        "campaign confirmation validity window refused \(admittedAtUTC)")
    }
    guard reservation.ordinal <= maximumAttempts else {
      throw RuntimeJobEngineError.rejected(
        .authorizationRequired,
        "campaign attempt ordinal \(reservation.ordinal) exceeds \(maximumAttempts)")
    }
    guard let identity = query.targetStableIdentitySHA256,
      identity == targetStableIdentitySHA256
    else {
      throw RuntimeJobEngineError.rejected(
        .authorizationRequired,
        "campaign confirmation pins a different stable device identity")
    }
    guard let bindingRevision = query.targetBindingRevision,
      bindingRevision >= bindingLineageRootRevision
    else {
      throw RuntimeJobEngineError.rejected(
        .authorizationRequired,
        "target binding revision precedes the campaign's lineage root")
    }
  }

  /// Resolves the published E1 policy into a durable capability envelope.
  /// The identifier is stable for the catalog, operation, target, binding and
  /// typed inputs, so daemon restart preserves lineage and an outcomeUnknown
  /// use blocks later automatic execution of the same mutation scope.
  private func automaticE1Capability(
    descriptor: CatalogOperationDescriptor,
    query: RuntimeCapabilityAuthorizationQuery
  ) async throws -> RuntimeCapabilityReference {
    let issuedAtUTC = nowUTC()
    guard let expiresAtUTC = Self.automaticE1Expiry(issuedAtUTC: issuedAtUTC) else {
      throw RuntimeJobEngineError.rejected(
        .authorizationRequired,
        "automatic E1 policy cannot verify the runtime clock")
    }
    do {
      try await validateNoUnresolvedMutationLineage(
        stableIdentitySHA256: query.targetStableIdentitySHA256 ?? "",
        bindingRevision: query.targetBindingRevision ?? 0,
        reservationID: nil,
        jobID: nil)
    } catch let error as RuntimeCapabilityStoreError {
      throw RuntimeJobEngineError.rejected(
        .authorizationRequired,
        "automatic E1 target lineage is blocked: \(error)")
    }
    let scopeFingerprint = Self.authorizationScopeFingerprint(of: query)
    let policyFingerprint =
      RuntimeJobRecord.sha256Hex(
        Data("\(RuntimeOperationCatalog.catalogDigest)\n\(scopeFingerprint)".utf8)
      )
      .uppercased()

    // A generation carries 10,000 confirmed uses. Exhausted generations roll
    // forward automatically; unresolved lineage never rolls forward.
    for generation in 1...100_000 {
      let capabilityID =
        "CAP-RT-POLICY-\(policyFingerprint.prefix(40))-G\(generation)"
      if let existing = try await capabilityStore.inspect(
        capabilityID: capabilityID)
      {
        let renewable =
          existing.lineageAllowsNewExecution
          && {
            if case .revoked = existing.capability.revocation { return false }
            return existing.remainingUses == 0
              || existing.capability.expiresAtUTC <= issuedAtUTC
          }()
        if renewable {
          continue
        }
        return RuntimeCapabilityReference(capabilityID: capabilityID)
      }

      let capability: RuntimeCapability
      do {
        capability = try RuntimeCapability(
          capabilityID: capabilityID,
          targetScope: .stablePhysicalIdentity(
            sha256: query.targetStableIdentitySHA256 ?? ""),
          operationScope: [
            RuntimeCapabilityOperationScope(
              operationID: descriptor.id, version: descriptor.version)
          ],
          effectCeiling: .deviceMutation,
          inputConstraints: Self.exactCapabilityConstraints(for: query.inputs),
          exactInputs: query.inputs,
          issuedAtUTC: issuedAtUTC,
          expiresAtUTC: expiresAtUTC,
          maximumUses: 10_000,
          issuer: RuntimeCapabilityIssuer(
            kind: .runtimeDefaultPolicy,
            reference:
              "catalog:\(RuntimeOperationCatalog.catalogDigest):\(descriptor.reference)"),
          exactPlanDigest: nil,
          exactBindingRevision: query.targetBindingRevision)
      } catch {
        throw RuntimeJobEngineError.rejected(
          .authorizationRequired,
          "automatic E1 policy could not create a bounded capability: \(error)")
      }
      do {
        try await capabilityStore.install(capability)
      } catch let error as RuntimeCapabilityStoreError {
        throw RuntimeJobEngineError.rejected(
          .authorizationRequired,
          "automatic E1 capability could not become durable: \(error)")
      }
      return RuntimeCapabilityReference(capabilityID: capabilityID)
    }
    throw RuntimeJobEngineError.rejected(
      .authorizationRequired,
      "automatic E1 capability generations are exhausted")
  }

  /// Prevents a caller from bypassing an unknown mutation by changing typed
  /// inputs and therefore selecting a different automatic capability scope.
  /// A crash-recovered pending reservation may continue only for its exact
  /// original Job; outcomeUnknown and legacy-unverified nodes never do.
  private func validateNoUnresolvedMutationLineage(
    stableIdentitySHA256: String,
    bindingRevision: Int,
    reservationID: String?,
    jobID: String?
  ) async throws {
    for status in try await capabilityStore.list() {
      for entry in status.lineage
      where entry.targetStableIdentitySHA256 == stableIdentitySHA256
        && entry.bindingRevision == bindingRevision
        && entry.outcome != .confirmed
      {
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

  private func consumeCapabilityBeforeMutation(
    jobID: String,
    descriptor: CatalogOperationDescriptor,
    effect: WorkflowEffect,
    validatedFacts: ProviderFacts?
  ) async throws {
    guard var runtime = jobs[jobID] else {
      throw RuntimeDispatchFailure.failed("job disappeared before capability consumption")
    }
    if let evidence = runtime.record.admissionEvidence {
      if evidence.kind == .evolutionCampaignConfirmation {
        guard
          evidence.reference == runtime.record.request.campaignReservation?.reservationID
        else {
          throw RuntimeDispatchFailure.failed(
            "authorizationRequired: persisted campaign evidence does not match the mutation")
        }
        return
      }
      guard
        evidence.kind == (effect == .destructive
          ? RuntimeEvidenceAuthorityKind.standingAuthorization
          : RuntimeEvidenceAuthorityKind.runtimeCapability),
        evidence.reference == runtime.record.request.authorization?.capabilityID
      else {
        throw RuntimeDispatchFailure.failed(
          "authorizationRequired: persisted admission evidence does not match the mutation")
      }
      return
    }
    if let campaign = runtime.record.request.campaignReservation {
      try await verifyCampaignReservationBeforeMutation(
        campaign, runtime: &runtime, jobID: jobID, descriptor: descriptor,
        effect: effect, validatedFacts: validatedFacts)
      return
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
        targetStableIdentitySHA256: stableIdentity,
        targetBindingRevision: bindingRevision,
        planDigest: planDigest,
        inputs: runtime.record.request.inputs)
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
        workspaceIdentitySHA256: workspace.identitySHA256,
        workspaceRevision: workspace.revision,
        workspaceFileScopesDigest: workspace.fileScopesDigest)
    }
    do {
      if let deviceLineage {
        // Device lineage guards one device against a second mutation while an
        // earlier one is unresolved. A workspace has no device to protect, and
        // the capability record's own lineage check still applies to both.
        try await validateNoUnresolvedMutationLineage(
          stableIdentitySHA256: deviceLineage.identity,
          bindingRevision: deviceLineage.bindingRevision,
          reservationID: runtime.record.request.idempotencyKey,
          jobID: jobID)
      }
      guard
        let status = try await capabilityStore.inspect(
          capabilityID: authorization.capabilityID)
      else {
        throw RuntimeCapabilityStoreError.capabilityNotFound(authorization.capabilityID)
      }
      let consumption = try await capabilityStore.consume(
        capabilityID: authorization.capabilityID,
        reservationID: runtime.record.request.idempotencyKey,
        jobID: jobID,
        query: query,
        nowUTC: nowUTC())
      runtime.record.admissionEvidence = RuntimeAdmissionEvidence(
        kind: effect == .destructive ? .standingAuthorization : .runtimeCapability,
        reference: authorization.capabilityID,
        admittedAtUTC: consumption.consumedAtUTC,
        validUntilUTC: status.capability.expiresAtUTC,
        consumptionFingerprintSHA256: consumption.queryFingerprintSHA256)
      runtime.record.timeline.append(
        "capability consumed before first mutation")
      // Keep the consumed evidence in the actor snapshot before the disk
      // write. If that write fails, run() can still persist the same
      // evidence while finalizing the fail-closed job; after a process
      // crash, the store's reservation-idempotent receipt reconstructs it.
      jobs[jobID] = runtime
      try persistRuntimeRecord(runtime.record)
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

  /// Consume-time verification for the campaign lane: re-checks the open
  /// reservation and every re-checkable confirmation pin against the freshly
  /// re-established subject, then persists the admission evidence. No ledger
  /// write happens here — the open reservation is the single-use marker and
  /// the job's terminal closes it.
  private func verifyCampaignReservationBeforeMutation(
    _ campaign: RuntimeCampaignReservationReference,
    runtime: inout JobRuntime,
    jobID: String,
    descriptor: CatalogOperationDescriptor,
    effect: WorkflowEffect,
    validatedFacts: ProviderFacts?
  ) async throws {
    guard let ledger = agentUsageLedger else {
      throw RuntimeDispatchFailure.failed(
        "authorizationRequired: campaign authority is unavailable in this runtime")
    }
    guard
      let openReservation = try? ledger.load().reservations.first(where: {
        $0.reservationID == campaign.reservationID
      }), openReservation.terminal == nil
    else {
      throw RuntimeDispatchFailure.failed(
        "authorizationRequired: campaign reservation is absent or already terminal")
    }
    guard
      case .evolutionCampaignConfirmation(
        let campaignDigestSHA256, _, _, let archiveDigestSHA256,
        _, let targetStableIdentitySHA256, _, let confirmedAt, let validUntil, _) =
        openReservation.authorizationRef,
      let campaignProvenance = openReservation.campaignEvidenceProvenance
    else {
      throw RuntimeDispatchFailure.failed(
        "authorizationRequired: reservation does not carry a campaign confirmation")
    }
    let formatter = ISO8601DateFormatter()
    let consumeAt = nowUTC()
    guard let moment = formatter.date(from: consumeAt),
      let windowStart = formatter.date(from: confirmedAt),
      let windowEnd = formatter.date(from: validUntil),
      moment >= windowStart, moment <= windowEnd
    else {
      throw RuntimeDispatchFailure.failed(
        "authorizationRequired: campaign confirmation validity window refused the mutation")
    }
    // The subject is the freshly re-proved one, never the admission-time
    // snapshot.
    guard let freshIdentity = validatedFacts?.deviceIdentitySHA256,
      freshIdentity == targetStableIdentitySHA256
    else {
      throw RuntimeDispatchFailure.failed(
        "authorizationRequired: fresh device identity drifted from the campaign pin")
    }
    guard let resolved = try await resolvedInputArtifact(jobID: jobID),
      resolved.sha256 == archiveDigestSHA256
    else {
      throw RuntimeDispatchFailure.failed(
        "authorizationRequired: leased archive digest drifted from the campaign pin")
    }
    guard let planDigest = runtime.record.materializedPlanDigest else {
      throw RuntimeDispatchFailure.failed(
        "authorizationRequired: campaign mutation has no materialized plan digest")
    }
    let correlation = RuntimeCampaignEvidenceCorrelation(
      campaignID: "ECAMP-\(campaignDigestSHA256.prefix(24).uppercased())",
      attemptID: openReservation.reservationID,
      attemptOrdinal: openReservation.ordinal,
      planDigestSHA256: planDigest,
      targetBindingDigestSHA256: openReservation.targetDigestSHA256,
      candidateDigestSHA256: campaignProvenance.candidateDigestSHA256,
      reviewDigestSHA256: campaignProvenance.reviewDigestSHA256,
      brokerDigestSHA256: campaignProvenance.brokerDigestSHA256)
    runtime.record.admissionEvidence = RuntimeAdmissionEvidence(
      kind: .evolutionCampaignConfirmation,
      reference: campaign.reservationID,
      admittedAtUTC: consumeAt,
      validUntilUTC: validUntil,
      consumptionFingerprintSHA256: planDigest,
      campaignCorrelation: correlation)
    runtime.record.timeline.append(
      "campaign reservation verified before first mutation")
    try persistRuntimeRecord(runtime.record)
    jobs[jobID] = runtime
  }

  /// Closes the campaign reservation with the job's terminal — the write the
  /// campaign executor would have made, carrying the mutating intents this
  /// engine journaled. Write-once with racer grace: an existing terminal
  /// (recovery replay, concurrent closer) stands.
  private func recordCampaignOutcome(
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
    case .outcomeUnknown:
      status = .outcomeUnknown
    case .pending, .legacyUnverified:
      return
    }
    let intents = try mutationIntentEvidence(for: record.jobID)
    do {
      _ = try ledger.close(
        reservationID: evidence.reference,
        terminal: try AgentAuthorityUsageTerminal(
          status: status, closedAt: nowUTC(),
          externalIntentEventIDs: intents.all,
          confirmedNotExecutedIntentEventIDs: intents.confirmedNotExecuted))
    } catch AuthorizationUsageLedgerError.reservationConflict {
      let existing = try? ledger.load().reservations.first {
        $0.reservationID == evidence.reference
      }
      guard existing?.terminal != nil else {
        throw RuntimeJobEngineError.internalFailure(
          "campaign terminal race left no terminal on \(evidence.reference)")
      }
    } catch let error as AuthorizationUsageLedgerError {
      throw RuntimeJobEngineError.internalFailure(
        "campaign authority lineage could not become durable: \(error)")
    }
  }

  /// The mutating intents this job durably journaled — what the campaign
  /// terminal must carry.
  private func mutationIntentEvidence(
    for jobID: String
  ) throws -> (all: [String], confirmedNotExecuted: [String]) {
    let journalURL = jobDirectory(for: jobID).appendingPathComponent("journal.jsonl")
    let replay: JournalReplay
    do {
      replay = try DurableJournalRecovery.inspect(url: journalURL)
    } catch {
      throw RuntimeJobEngineError.internalFailure(
        "campaign mutation journal is unavailable for \(jobID): \(error)")
    }
    var identifiers: [String] = []
    for event in replay.events where event.kind == .stepIntent {
      guard let step = event.workflowStep, step.effect >= .deviceMutation else { continue }
      identifiers.append(event.eventID)
    }
    let confirmed = Set(
      replay.events.compactMap { event -> String? in
        guard event.kind == .stepOutcome,
          event.payload["semanticCode"]
            == .string(Self.confirmedNotExecutedSemanticCode)
        else { return nil }
        return event.correlatedIntentEventID
      })
    return (identifiers, identifiers.filter(confirmed.contains))
  }

  private func recordCapabilityOutcome(
    for record: RuntimeJobRecord,
    outcome: RuntimeCapabilityUseOutcome,
    state: String
  ) async throws {
    if record.admissionEvidence?.kind == .evolutionCampaignConfirmation {
      try await recordCampaignOutcome(for: record, outcome: outcome, state: state)
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
      // Legacy adapter annotations are tolerated and ignored by execution.
      if key.hasPrefix("legacy") { continue }
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
        triggerEventID: triggerEventID))
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

  private func jobDirectory(for jobID: String) -> URL {
    configuration.stateDirectory
      .appendingPathComponent("jobs", isDirectory: true)
      .appendingPathComponent(jobID, isDirectory: true)
  }

  /// Recreates only the wholly absent projection left by a process loss after
  /// the SQLite admission commit and before the first journal append.  A
  /// partial projection is never guessed at: it is an attributable durable
  /// corruption because it could otherwise hide an external-effect history.
  private func restoreInitialAdmissionProjectionIfNeeded(_ persisted: RuntimePersistedJob) throws {
    let directory = jobDirectory(for: persisted.jobID)
    let recordURL = directory.appendingPathComponent("job-record.json")
    let journalURL = directory.appendingPathComponent("journal.jsonl")
    let hasRecord = FileManager.default.fileExists(atPath: recordURL.path)
    let hasJournal = FileManager.default.fileExists(atPath: journalURL.path)
    if hasRecord && hasJournal { return }
    guard let data = persisted.initialRecordData else {
      throw RuntimeJobEngineError.internalFailure(
        "admitted job \(persisted.jobID) has no recoverable initial record")
    }
    let record: RuntimeJobRecord
    do {
      record = try JSONDecoder().decode(RuntimeJobRecord.self, from: data)
    } catch {
      throw RuntimeJobEngineError.internalFailure(
        "admitted job \(persisted.jobID) has an invalid initial record: \(error)")
    }
    guard record.jobID == persisted.jobID, record.state == JobState.preflight.rawValue else {
      throw RuntimeJobEngineError.internalFailure(
        "admitted job \(persisted.jobID) initial record does not match its transactional identity")
    }
    if hasJournal {
      let inspection = try DurableJournalRecovery.inspect(url: journalURL)
      if !hasRecord, inspection.events.isEmpty {
        // The writer creates and fsyncs an empty journal inode before its
        // first append.  A loss in that exact interval is still a committed
        // admission with zero effect history, so complete the initial pair
        // instead of classifying it as a corrupted partial projection.
        let journal = try FileDurableJournal(url: journalURL)
        try journal.appendAndSynchronize(
          JournalEvent.jobCreated(
            eventID: "job-created", sequence: 0, sessionID: record.sessionID,
            jobID: record.jobID, timestamp: record.createdAtUTC, executionMode: "execute"))
        try journal.appendAndSynchronize(
          JournalEvent.stateTransition(
            eventID: "to-preflight", sequence: 1, sessionID: record.sessionID,
            jobID: record.jobID, timestamp: record.createdAtUTC,
            from: .queued, to: .preflight, reason: "recovered committed admission"))
        try record.persist(into: directory)
        return
      }
      guard
        !hasRecord,
        inspection.events.count == 2,
        inspection.events[0].kind == .jobCreated,
        inspection.events[0].jobID == record.jobID,
        inspection.events[1].kind == .stateTransition,
        inspection.events[1].stateTransition?.from == .queued,
        inspection.events[1].stateTransition?.to == .preflight
      else {
        throw RuntimeJobEngineError.internalFailure(
          "admitted job \(persisted.jobID) has a partial durable projection")
      }
      try record.persist(into: directory)
      return
    }
    guard !hasRecord else {
      throw RuntimeJobEngineError.internalFailure(
        "admitted job \(persisted.jobID) has a partial durable projection")
    }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let journal = try FileDurableJournal(url: journalURL)
    try journal.appendAndSynchronize(
      JournalEvent.jobCreated(
        eventID: "job-created", sequence: 0, sessionID: record.sessionID,
        jobID: record.jobID, timestamp: record.createdAtUTC, executionMode: "execute"))
    try journal.appendAndSynchronize(
      JournalEvent.stateTransition(
        eventID: "to-preflight", sequence: 1, sessionID: record.sessionID,
        jobID: record.jobID, timestamp: record.createdAtUTC,
        from: .queued, to: .preflight, reason: "recovered committed admission"))
    try record.persist(into: directory)
  }

  private func persistRuntimeRecord(_ record: RuntimeJobRecord) throws {
    try record.persist(into: jobDirectory(for: record.jobID))
    try admissionService.persist(record, at: nowUTC())
  }

  /// Terminal jobs have no further dispatch or recovery path.  Their durable
  /// record and SQLite row remain queryable, so retaining a FileDurableJournal
  /// and detailed runtime projection in the daemon only makes memory grow with
  /// history.  Outcome-unknown jobs are deliberately excluded: they remain
  /// active until an explicit reconciliation reaches a certain terminal state.
  private func statusAndReleaseTerminalRuntime(_ record: RuntimeJobRecord) -> RuntimeJobStatus {
    let jobStatus = status(of: record)
    if !record.outcomeUnknown, JobState(rawValue: record.state)?.isTerminal == true {
      jobs.removeValue(forKey: record.jobID)
      cancellationRequests.remove(record.jobID)
    }
    return jobStatus
  }

  /// Terminal history is read from its durable SQLite projection after the
  /// in-memory runtime has been released.  A missing or malformed projection
  /// is never guessed at as a status because doing so could hide an unknown
  /// external-effect outcome.
  private func recordForRead(jobID: String) throws -> RuntimeJobRecord {
    if let runtime = jobs[jobID] { return runtime.record }
    guard
      let persisted = try admissionService.job(jobID: jobID),
      let data = persisted.initialRecordData,
      let record = try? JSONDecoder().decode(RuntimeJobRecord.self, from: data)
    else { throw RuntimeJobEngineError.jobNotFound(jobID) }
    return record
  }

  private func status(of record: RuntimeJobRecord) -> RuntimeJobStatus {
    RuntimeJobStatus(
      jobID: record.jobID,
      operationReference: record.operationReference,
      targetID: record.request.target.targetID,
      state: record.state,
      waitingForHuman: record.state == "waitingForRecovery",
      outcomeUnknown: record.outcomeUnknown,
      outstandingResidueCount: record.outstandingResidueCount,
      timeline: record.timeline)
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

  private static func authorizationScopeFingerprint(
    of query: RuntimeCapabilityAuthorizationQuery
  ) -> String {
    var components: [String] = [
      "operation=\(query.operationID)@\(query.operationVersion)",
      "effect=\(query.effect.rawValue)",
      "target=\(query.targetStableIdentitySHA256 ?? "-")",
      "bindingRevision=\(query.targetBindingRevision.map(String.init) ?? "-")",
    ]
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard
      let inputs = try? encoder.encode(query.inputs),
      let text = String(data: inputs, encoding: .utf8)
    else {
      preconditionFailure("validated runtime inputs must encode canonically")
    }
    components.append("inputs=\(text)")
    return RuntimeJobRecord.sha256Hex(
      Data(components.joined(separator: "\n").utf8))
  }

  private static func automaticE1Expiry(issuedAtUTC: String) -> String? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    guard let issued = formatter.date(from: issuedAtUTC) else { return nil }
    return formatter.string(
      from: issued.addingTimeInterval(30 * 24 * 60 * 60))
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
    value.count == 64
      && value.allSatisfy {
        ("0"..."9").contains(String($0)) || ("a"..."f").contains(String($0))
      }
  }

  /// Journal-grade WorkflowStep for the kinds the engine exercises in MU-2.
  /// Argument tables are the registry's required keys with deterministic,
  /// audit-honest values.
  static func journalStep(
    for step: CatalogStepDescriptor,
    jobID: String,
    inputs: [String: JSONValue] = [:],
    action: TypedProviderAction? = nil,
    resolvedInputArtifact: ProviderResolvedInputArtifact? = nil
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
      switch action {
      case .rockchip(.rebindLoader):
        arguments = ["evidencePolicy": .string("rockusbLoaderIdentity")]
      case .rockchip(.verifyBuild):
        arguments = ["evidencePolicy": .string("postFlashBuild")]
      default:
        arguments = ["evidencePolicy": .string("coreMinimum")]
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
      switch action {
      case .rockchip(.waitForLoader):
        arguments = [
          "deadlineMilliseconds": .integer(45_000),
          "reason": .string("loaderReconnect"),
        ]
      case .rockchip(.waitForHDCReconnect):
        arguments = [
          "deadlineMilliseconds": .integer(120_000),
          "reason": .string("normalModeReconnect"),
        ]
      default:
        throw RuntimeJobEngineError.internalFailure(
          "\(step.stepID) has no exact reconnect action")
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
      if case .hdc(.captureScreenshot(let path))? = action {
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
      case "receive-screenshot": localName = "screenshot.png"
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
      if case .hdc(.cleanupOwnedRemotePath(let owned))? = action {
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
    case .runApprovedRemoteRead:
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
      if case .rockchip(.verifyFlashReadback(let bundle))? = action {
        arguments = [
          "probeId": .string("rockusb-partition-readback"),
          "expectedState": .string("mapped-set:\(bundle.sha256)"),
        ]
        break
      } else if case .hdc(.verifyProcessState(let bundle))? = action {
        probeID = "process.\(bundle.bundleName)"
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
      guard case .rockchip(.flashPartitions(let bundle))? = action else {
        throw RuntimeJobEngineError.internalFailure(
          "\(step.stepID) has no exact Rockchip flash action")
      }
      arguments = [
        "providerOperationId": .string("rockusb.wlx-write"),
        "partition": .string("dayu200_mapped_set"),
        "imageArtifactId": .string(bundle.artifactID),
        "imageSha256": .string(bundle.sha256),
        "imageSize": .integer(Int64(bundle.byteCount)),
        "confirmationId": .string("runtimeE2Admission"),
        "safeBoundaryId": .string("perPartitionWriteBoundary"),
      ]
    case .rebootDevice:
      guard case .rockchip(.rebootToNormal)? = action else {
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
}
