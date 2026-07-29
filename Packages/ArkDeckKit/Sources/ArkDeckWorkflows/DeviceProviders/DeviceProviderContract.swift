// Unified Device Provider contract (CHG-2026-047, T05).
//
// One execution boundary for HDC and Rockchip: providers own executable
// discovery, argv lowering, remote paths and semantic parsing; the runtime
// understands only effects, intents, receipts, artifacts and reconcile.
// Actions are a closed typed vocabulary - there is no command-string,
// argv or executable parameter anywhere on this surface, and process plans
// can only be constructed inside this package (providers), never by
// clients. Verification is semantic: there is deliberately no constructor
// from "exit 0" to a verified outcome.

import ArkDeckCore
import Foundation

// MARK: - Typed actions (closed)

/// The closed HDC action vocabulary. MU-2 delivered the observation
/// family; MU-3 (T10) completes the E0 pack. Every payload is a validated
/// typed request - extension is a catalog + provider decision, never a
/// caller-supplied string. Reboot deliberately stays outside E0.
public enum HDCProviderAction: Sendable, Equatable {
  case observeTool
  case observeServer
  case listDeviceCandidates
  case observeDevice(connectKey: String)
  case queryProperty(HDCAllowlistedProperty)
  case captureHilog(HDCHilogCaptureRequest)
  case captureUIDump(HDCUIDumpRequest)
  case captureTrace(HDCTraceCaptureRequest, into: HDCOwnedRemotePath)
  case receiveOwnedArtifact(HDCOwnedRemoteArtifact)
  case cleanupOwnedRemotePath(HDCOwnedRemotePath)
  // E1 mutation family (T13). Success for the mutating members is decided
  // by their paired readback, never by the mutation's own exit code.
  case sendArtifactToStaging(HDCStagedArtifact)
  case installPackage(HDCStagedArtifact, bundle: HDCBundleReference)
  case queryPackageReadback(HDCBundleReference)
  case startAbility(HDCAbilityReference)
  case verifyProcessState(HDCBundleReference)
  case stopAbility(HDCAbilityReference)
  case uninstallPackage(HDCBundleReference)
  case createPortForward(HDCPortForwardSpec)
  case removePortForward(HDCPortForwardSpec)
}

/// Rockchip actions in MU-2: the one adapter-compat action wrapping the
/// existing execution host whole (its internal journal/manifest/recovery
/// semantics stay authoritative during migration).
public enum RockchipProviderAction: Sendable, Equatable {
  case executeFlashPlan(authorizationID: String)
}

public enum TypedProviderAction: Sendable, Equatable {
  case hdc(HDCProviderAction)
  case rockchip(RockchipProviderAction)

  public var effect: WorkflowEffect {
    switch self {
    case .hdc(.observeTool), .hdc(.observeServer):
      return .hostOnly
    case .hdc(.listDeviceCandidates), .hdc(.observeDevice), .hdc(.queryProperty),
      .hdc(.captureHilog), .hdc(.captureUIDump), .hdc(.receiveOwnedArtifact):
      return .readOnly
    case .hdc(.queryPackageReadback), .hdc(.verifyProcessState):
      return .readOnly
    case .hdc(.captureTrace), .hdc(.cleanupOwnedRemotePath),
      .hdc(.sendArtifactToStaging), .hdc(.installPackage), .hdc(.startAbility),
      .hdc(.stopAbility), .hdc(.uninstallPackage), .hdc(.createPortForward),
      .hdc(.removePortForward):
      // Writing/removing the provider-owned remote temp file is a bounded
      // deviceMutation per the step registry; the operation-level effect
      // envelope (capture.diagnostics permitted set) already models it.
      return .deviceMutation
    case .rockchip(.executeFlashPlan):
      return .destructive
    }
  }
}

// MARK: - Facts, plans, receipts, outcomes

public struct ProviderFacts: Sendable, Equatable {
  public let providerID: String
  public let toolVersion: String
  public let toolSHA256: String
  public let serverFacts: [String: String]
  /// Correlation fields are optional for compatibility with pre-V3 fact
  /// producers. Hardware evidence treats every absent field as
  /// incomplete; the runtime never fills one from a target ID or caller
  /// input.
  public let targetID: String?
  public let bindingRevision: Int?
  public let deviceIdentitySHA256: String?
  /// Private execution routing material. This type is deliberately not
  /// Codable so a raw device key cannot leak into a job record, receipt or
  /// evidence artifact by accidental serialization.
  public let executionConnectKey: String?
  public let deviceModel: String?
  public let deviceMode: String?
  public let buildFingerprint: String?
  public let transport: String?
  public let profileID: String
  public let collectedAtUTC: String
  /// Time at which the device facts themselves were read. This is
  /// deliberately separate from `collectedAtUTC`: reopening a cached
  /// target record "now" must not make an old observation fresh.
  public let sourceObservedAtUTC: String?

  public init(
    providerID: String,
    toolVersion: String,
    toolSHA256: String,
    serverFacts: [String: String],
    targetID: String? = nil,
    bindingRevision: Int? = nil,
    deviceIdentitySHA256: String?,
    executionConnectKey: String? = nil,
    deviceModel: String? = nil,
    deviceMode: String?,
    buildFingerprint: String?,
    transport: String? = nil,
    profileID: String,
    collectedAtUTC: String,
    sourceObservedAtUTC: String? = nil
  ) {
    self.providerID = providerID
    self.toolVersion = toolVersion
    self.toolSHA256 = toolSHA256
    self.serverFacts = serverFacts
    self.targetID = targetID
    self.bindingRevision = bindingRevision
    self.deviceIdentitySHA256 = deviceIdentitySHA256
    self.executionConnectKey = executionConnectKey
    self.deviceModel = deviceModel
    self.deviceMode = deviceMode
    self.buildFingerprint = buildFingerprint
    self.transport = transport
    self.profileID = profileID
    self.collectedAtUTC = collectedAtUTC
    self.sourceObservedAtUTC = sourceObservedAtUTC
  }
}

/// A lowered plan. `process` carries a concrete child-process invocation
/// (descriptor-bound); `hostManaged` marks an adapter-compat execution the
/// provider runs under its own proven host (Rockchip migration mode).
/// Construction is package-only: clients cannot mint plans.
public struct TypedProcessPlan: Sendable, Equatable {
  public enum Kind: Sendable, Equatable {
    case process(executableSHA256: String, argumentSummary: [String], timeoutSeconds: Int?)
    case hostManaged(descriptor: String)
  }

  public let action: TypedProviderAction
  public let kind: Kind

  package init(action: TypedProviderAction, kind: Kind) {
    self.action = action
    self.kind = kind
  }
}

public struct ProviderProcessReceipt: Sendable, Equatable {
  public let exitStatus: Int32?
  public let stdout: Data
  public let stderr: Data
  public let stdoutTruncated: Bool
  public let durationSeconds: Double
  /// Present when the plan was host-managed: an opaque reference to the
  /// provider-owned durable record (e.g. Rockchip session manifest ID).
  public let hostManagedRecordID: String?

  public init(
    exitStatus: Int32?,
    stdout: Data,
    stderr: Data,
    stdoutTruncated: Bool,
    durationSeconds: Double,
    hostManagedRecordID: String? = nil
  ) {
    self.exitStatus = exitStatus
    self.stdout = stdout
    self.stderr = stderr
    self.stdoutTruncated = stdoutTruncated
    self.durationSeconds = durationSeconds
    self.hostManagedRecordID = hostManagedRecordID
  }
}

/// Closed semantic verdicts. `verified` requires a parsed summary - the
/// type system offers no path from a bare exit code to success.
public enum ProviderSemanticOutcome: Sendable, Equatable {
  case verified(summary: [String: String])
  case failed(code: String, detail: String)
  case unknown(reason: String)
  case unsupported(reason: String)
}

public enum ProviderReconcileOutcome: Sendable, Equatable {
  case confirmedCompleted(summary: [String: String])
  case confirmedNotExecuted
  case stillUnknown(reason: String)
}

public struct ProviderExecutionContext: Sendable, Equatable {
  public let jobID: String
  public let stepID: String
  public let targetID: String
  public let bindingRevision: Int?
  /// Provider-private routing and correlation facts resolved from the
  /// adopted target. They never originate in request inputs.
  public let connectKey: String?
  public let expectedIdentitySHA256: String?
  public let toolVersion: String?
  public let toolSHA256: String?
  public let nowUTC: String

  public init(
    jobID: String,
    stepID: String,
    targetID: String,
    bindingRevision: Int?,
    connectKey: String? = nil,
    expectedIdentitySHA256: String? = nil,
    toolVersion: String? = nil,
    toolSHA256: String? = nil,
    nowUTC: String
  ) {
    self.jobID = jobID
    self.stepID = stepID
    self.targetID = targetID
    self.bindingRevision = bindingRevision
    self.connectKey = connectKey
    self.expectedIdentitySHA256 = expectedIdentitySHA256
    self.toolVersion = toolVersion
    self.toolSHA256 = toolSHA256
    self.nowUTC = nowUTC
  }
}

public struct ProviderDurableIntentReference: Sendable, Equatable {
  public let jobID: String
  public let stepID: String
  public let intentEventID: String
  public let action: TypedProviderAction

  public init(jobID: String, stepID: String, intentEventID: String, action: TypedProviderAction) {
    self.jobID = jobID
    self.stepID = stepID
    self.intentEventID = intentEventID
    self.action = action
  }
}

public enum DeviceProviderError: Error, Equatable, Sendable {
  case unsupportedAction(String)
  case unsupportedStepKind(String)
  case factsUnavailable(String)
}

// MARK: - The provider protocol

public protocol DeviceProvider: Sendable {
  var providerID: String { get }

  func resolveFacts(targetID: String) async throws -> ProviderFacts

  /// Maps a catalog step (closed kind vocabulary) to this provider's typed
  /// action. Unknown/unsupported kinds must throw, never guess.
  func action(
    for step: CatalogStepDescriptor,
    operation: CatalogOperationDescriptor,
    inputs: [String: JSONValue]
  ) throws -> TypedProviderAction

  func lower(
    action: TypedProviderAction,
    context: ProviderExecutionContext
  ) throws -> TypedProcessPlan

  func verify(
    receipt: ProviderProcessReceipt,
    action: TypedProviderAction,
    context: ProviderExecutionContext
  ) throws -> ProviderSemanticOutcome

  func reconcile(
    intent: ProviderDurableIntentReference,
    context: ProviderExecutionContext
  ) async throws -> ProviderReconcileOutcome
}

/// Closed provider registry keyed by providerID ("hdc", "rockchip").
public struct DeviceProviderRegistry: Sendable {
  private let providers: [String: any DeviceProvider]

  public init(providers: [any DeviceProvider]) {
    var table: [String: any DeviceProvider] = [:]
    for provider in providers {
      table[provider.providerID] = provider
    }
    self.providers = table
  }

  public func provider(id: String) -> (any DeviceProvider)? {
    providers[id]
  }

  public func resolveFacts(
    providerID: String, targetID: String
  ) async throws -> ProviderFacts {
    guard let provider = providers[providerID] else {
      throw DeviceProviderError.factsUnavailable("provider \(providerID) is not registered")
    }
    return try await provider.resolveFacts(targetID: targetID)
  }

  public var registeredProviderIDs: [String] {
    providers.keys.sorted()
  }
}
