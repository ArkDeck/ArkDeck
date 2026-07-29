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
    case .hdc(.captureTrace), .hdc(.cleanupOwnedRemotePath):
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

public struct ProviderFacts: Sendable, Equatable, Codable {
  public let providerID: String
  public let toolVersion: String
  public let toolSHA256: String
  public let serverFacts: [String: String]
  public let deviceIdentitySHA256: String?
  public let deviceMode: String?
  public let buildFingerprint: String?
  public let profileID: String
  public let collectedAtUTC: String

  public init(
    providerID: String,
    toolVersion: String,
    toolSHA256: String,
    serverFacts: [String: String],
    deviceIdentitySHA256: String?,
    deviceMode: String?,
    buildFingerprint: String?,
    profileID: String,
    collectedAtUTC: String
  ) {
    self.providerID = providerID
    self.toolVersion = toolVersion
    self.toolSHA256 = toolSHA256
    self.serverFacts = serverFacts
    self.deviceIdentitySHA256 = deviceIdentitySHA256
    self.deviceMode = deviceMode
    self.buildFingerprint = buildFingerprint
    self.profileID = profileID
    self.collectedAtUTC = collectedAtUTC
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
  public let nowUTC: String

  public init(
    jobID: String, stepID: String, targetID: String, bindingRevision: Int?, nowUTC: String
  ) {
    self.jobID = jobID
    self.stepID = stepID
    self.targetID = targetID
    self.bindingRevision = bindingRevision
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

  public var registeredProviderIDs: [String] {
    providers.keys.sorted()
  }
}
