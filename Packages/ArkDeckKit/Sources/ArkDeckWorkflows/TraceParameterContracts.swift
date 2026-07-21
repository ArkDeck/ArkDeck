import ArkDeckCore
import Foundation

public struct TraceDebugParameterDefinition: Equatable, Sendable {
  public let name: String
  public let profileValue: String

  public init(name: String, profileValue: String) {
    self.name = name
    self.profileValue = profileValue
  }
}

public enum TraceDebugParameterCatalog {
  public static let definitions: [TraceDebugParameterDefinition] = [
    .init(name: "persist.ace.trace.syntax.enabled", profileValue: "true"),
    .init(name: "persist.ace.trace.layout.enabled", profileValue: "true"),
    .init(name: "persist.ace.trace.build.enabled", profileValue: "true"),
    .init(name: "persist.ace.trace.measure.debug.enabled", profileValue: "true"),
    .init(name: "persist.ace.trace.sync.debug.enabled", profileValue: "true"),
    .init(name: "persist.ace.debug.enabled", profileValue: "1"),
    .init(name: "persist.ace.performance.monitor.enabled", profileValue: "true"),
    .init(name: "persist.sys.graphic.openDebugTrace", profileValue: "1"),
    .init(name: "persist.rosen.animationtrace.enabled", profileValue: "1"),
  ]

  public static func definition(named name: String) -> TraceDebugParameterDefinition? {
    definitions.first { $0.name == name }
  }

  public static func index(of name: String) -> Int? {
    definitions.firstIndex { $0.name == name }
  }
}

public enum TraceParameterSnapshotState: Equatable, Sendable {
  case missing
  case unreadable(reason: String)
  case value(String)

  public var writableOriginalValue: String? {
    guard case .value(let value) = self else { return nil }
    return value
  }
}

public enum TraceParameterApplicationMode: String, Codable, Equatable, Sendable {
  case temporaryRestore
  case persistentChange
}

public struct TraceParameterModeAvailability: Equatable, Sendable {
  public let temporaryRestoreAvailable: Bool
  public let persistentChangeAvailable: Bool
  public let persistentChangeRequiresExplicitConfirmation: Bool
}

public enum TraceParameterProbeDisposition: String, Codable, CaseIterable, Equatable, Sendable {
  case supported
  case unsupported
  case permissionDenied
  case needsDeveloperMode
  case unknown
}

public enum TraceParameterCapabilityError: Error, Equatable, Sendable {
  case parameterOutsideAttachmentDebugProfile(String)
  case persistentSupportRequiresSupportedDisposition
}

/// A typed per-device probe receipt. It can only be created from a durable binding receipt and
/// a catalog member, so catalog membership by itself is never mutation authority.
public struct TraceParameterCapabilityReceipt: Equatable, Sendable {
  public let bindingReference: DeviceBindingReference
  public let parameterName: String
  public let disposition: TraceParameterProbeDisposition
  public let persistentWriteSupported: Bool
  fileprivate let durableBinding: DurableCurrentDeviceBinding

  fileprivate init(
    durableBinding: DurableCurrentDeviceBinding,
    parameterName: String,
    disposition: TraceParameterProbeDisposition,
    persistentWriteSupported: Bool
  ) {
    bindingReference = durableBinding.reference
    self.parameterName = parameterName
    self.disposition = disposition
    self.persistentWriteSupported = persistentWriteSupported
    self.durableBinding = durableBinding
  }

  public func matches(
    durableBinding: DurableCurrentDeviceBinding,
    parameterName: String
  ) -> Bool {
    self.durableBinding == durableBinding && self.parameterName == parameterName
  }
}

public enum TraceParameterCapabilityProbe {
  public static func record(
    durableBinding: DurableCurrentDeviceBinding,
    parameterName: String,
    disposition: TraceParameterProbeDisposition,
    persistentWriteSupported: Bool = false
  ) throws -> TraceParameterCapabilityReceipt {
    guard TraceDebugParameterCatalog.definition(named: parameterName) != nil else {
      throw TraceParameterCapabilityError.parameterOutsideAttachmentDebugProfile(parameterName)
    }
    guard disposition == .supported || !persistentWriteSupported else {
      throw TraceParameterCapabilityError.persistentSupportRequiresSupportedDisposition
    }
    return TraceParameterCapabilityReceipt(
      durableBinding: durableBinding,
      parameterName: parameterName,
      disposition: disposition,
      persistentWriteSupported: persistentWriteSupported)
  }
}

public enum TraceParameterPolicyError: Error, Equatable, Sendable {
  case parameterOutsideAttachmentDebugProfile(String)
  case duplicateParameter(String)
  case valueDoesNotMatchProfile(name: String, expected: String, actual: String)
  case temporaryRestoreUnavailable(TraceParameterSnapshotState)
  case capabilityReceiptRequired(String)
  case capabilityParameterMismatch(expected: String, actual: String)
  case capabilityBindingMismatch(
    expected: DeviceBindingReference,
    actual: DeviceBindingReference
  )
  case capabilityNotSupported(String, TraceParameterProbeDisposition)
  case persistentWriteUnsupported(String)
  case persistentConfirmationRequired
}

public struct TraceParameterMutationRequest: Equatable, Sendable {
  public let name: String
  public let value: String
  public let mode: TraceParameterApplicationMode

  public init(name: String, value: String, mode: TraceParameterApplicationMode) {
    self.name = name
    self.value = value
    self.mode = mode
  }
}

/// Authorization is minted only after the catalog binding, snapshot state and mode rules pass.
public struct TraceAuthorizedParameterMutation: Equatable, Sendable {
  public let request: TraceParameterMutationRequest
  public let snapshot: TraceParameterSnapshotState
  public let capability: TraceParameterCapabilityReceipt
  public let bindingReference: DeviceBindingReference
  public let persistentConfirmationID: String?

  fileprivate init(
    request: TraceParameterMutationRequest,
    snapshot: TraceParameterSnapshotState,
    capability: TraceParameterCapabilityReceipt,
    persistentConfirmationID: String?
  ) {
    self.request = request
    self.snapshot = snapshot
    self.capability = capability
    bindingReference = capability.bindingReference
    self.persistentConfirmationID = persistentConfirmationID
  }

  public var originalValueForRestore: String? {
    request.mode == .temporaryRestore ? snapshot.writableOriginalValue : nil
  }
}

public enum TraceParameterPolicy {
  public static func availability(
    for name: String,
    snapshot: TraceParameterSnapshotState,
    capability: TraceParameterCapabilityReceipt?,
    durableBinding: DurableCurrentDeviceBinding
  ) -> TraceParameterModeAvailability {
    let known = TraceDebugParameterCatalog.definition(named: name) != nil
    let supported =
      capability?.matches(durableBinding: durableBinding, parameterName: name) == true
      && capability?.disposition == .supported
    return TraceParameterModeAvailability(
      temporaryRestoreAvailable: known && supported && snapshot.writableOriginalValue != nil,
      persistentChangeAvailable: known && supported
        && capability?.persistentWriteSupported == true,
      persistentChangeRequiresExplicitConfirmation: known && supported
        && capability?.persistentWriteSupported == true)
  }

  public static func authorize(
    _ request: TraceParameterMutationRequest,
    snapshot: TraceParameterSnapshotState,
    capability: TraceParameterCapabilityReceipt?,
    durableBinding: DurableCurrentDeviceBinding,
    persistentConfirmationID: String? = nil
  ) throws -> TraceAuthorizedParameterMutation {
    guard let definition = TraceDebugParameterCatalog.definition(named: request.name) else {
      throw TraceParameterPolicyError.parameterOutsideAttachmentDebugProfile(request.name)
    }
    guard request.value == definition.profileValue else {
      throw TraceParameterPolicyError.valueDoesNotMatchProfile(
        name: request.name, expected: definition.profileValue, actual: request.value)
    }
    guard let capability else {
      throw TraceParameterPolicyError.capabilityReceiptRequired(request.name)
    }
    guard capability.parameterName == request.name else {
      throw TraceParameterPolicyError.capabilityParameterMismatch(
        expected: request.name,
        actual: capability.parameterName)
    }
    guard capability.durableBinding == durableBinding else {
      throw TraceParameterPolicyError.capabilityBindingMismatch(
        expected: durableBinding.reference,
        actual: capability.bindingReference)
    }
    guard capability.disposition == .supported else {
      throw TraceParameterPolicyError.capabilityNotSupported(
        request.name,
        capability.disposition)
    }

    switch request.mode {
    case .temporaryRestore:
      guard snapshot.writableOriginalValue != nil else {
        throw TraceParameterPolicyError.temporaryRestoreUnavailable(snapshot)
      }
      return TraceAuthorizedParameterMutation(
        request: request,
        snapshot: snapshot,
        capability: capability,
        persistentConfirmationID: nil)
    case .persistentChange:
      guard capability.persistentWriteSupported else {
        throw TraceParameterPolicyError.persistentWriteUnsupported(request.name)
      }
      guard
        let persistentConfirmationID,
        !persistentConfirmationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw TraceParameterPolicyError.persistentConfirmationRequired
      }
      return TraceAuthorizedParameterMutation(
        request: request,
        snapshot: snapshot,
        capability: capability,
        persistentConfirmationID: persistentConfirmationID)
    }
  }
}

public enum TraceParameterSetCommandOutcome: Equatable, Sendable {
  case succeeded
  case unsupported
  case permissionDenied
  case needsDeveloperMode
  case processFailure(String)
}

public struct TraceParameterAuditEvent: Equatable, Sendable {
  public let code: String
  public let parameterName: String
  public let expectedValue: String
  public let observedValue: String

  public init(
    code: String,
    parameterName: String,
    expectedValue: String,
    observedValue: String
  ) {
    self.code = code
    self.parameterName = parameterName
    self.expectedValue = expectedValue
    self.observedValue = observedValue
  }
}

/// Receipt required by the capture gate. A successful process exit without an exact read-back
/// cannot create one.
public struct TraceVerifiedParameterMutation: Equatable, Sendable {
  public let authorization: TraceAuthorizedParameterMutation
  public let readbackValue: String

  fileprivate init(
    authorization: TraceAuthorizedParameterMutation,
    readbackValue: String
  ) {
    self.authorization = authorization
    self.readbackValue = readbackValue
  }
}

public enum TraceParameterReadbackResult: Equatable, Sendable {
  case verified(TraceVerifiedParameterMutation)
  case blocked(auditEvent: TraceParameterAuditEvent, deviceCaptureDispatchCount: Int)

  public var verifiedMutation: TraceVerifiedParameterMutation? {
    guard case .verified(let mutation) = self else { return nil }
    return mutation
  }
}

public enum TraceParameterReadbackVerifier {
  public static func verify(
    authorization: TraceAuthorizedParameterMutation,
    commandOutcome: TraceParameterSetCommandOutcome,
    readback: TraceParameterSnapshotState
  ) -> TraceParameterReadbackResult {
    let expected = authorization.request.value
    let observed: String
    let code: String

    switch commandOutcome {
    case .succeeded:
      if case .value(let value) = readback, value == expected {
        return .verified(
          TraceVerifiedParameterMutation(authorization: authorization, readbackValue: value))
      }
      code = "trace-parameter-readback-mismatch"
      observed = Self.describe(readback)
    case .unsupported:
      code = "trace-parameter-unsupported"
      observed = "unsupported"
    case .permissionDenied:
      code = "trace-parameter-permission-denied"
      observed = "permissionDenied"
    case .needsDeveloperMode:
      code = "trace-parameter-needs-developer-mode"
      observed = "needsDeveloperMode"
    case .processFailure(let detail):
      code = "trace-parameter-set-process-failure"
      observed = detail
    }

    return .blocked(
      auditEvent: TraceParameterAuditEvent(
        code: code,
        parameterName: authorization.request.name,
        expectedValue: expected,
        observedValue: observed),
      deviceCaptureDispatchCount: 0)
  }

  private static func describe(_ state: TraceParameterSnapshotState) -> String {
    switch state {
    case .missing: "missing"
    case .unreadable(let reason): "unreadable:\(reason)"
    case .value(let value): value
    }
  }
}

public enum TraceParameterRestoreResult: Equatable, Sendable {
  case notRequiredPersistentChange
  case restored
  case needsAttention(TraceParameterAuditEvent)
}

public enum TraceParameterRestoreVerifier {
  public static func verify(
    mutation: TraceVerifiedParameterMutation,
    commandOutcome: TraceParameterSetCommandOutcome,
    readback: TraceParameterSnapshotState
  ) -> TraceParameterRestoreResult {
    guard let original = mutation.authorization.originalValueForRestore else {
      return .notRequiredPersistentChange
    }
    if commandOutcome == .succeeded, readback == .value(original) {
      return .restored
    }
    return .needsAttention(
      TraceParameterAuditEvent(
        code: "trace-parameter-restore-failed",
        parameterName: mutation.authorization.request.name,
        expectedValue: original,
        observedValue: describe(readback)))
  }

  private static func describe(_ state: TraceParameterSnapshotState) -> String {
    switch state {
    case .missing: "missing"
    case .unreadable(let reason): "unreadable:\(reason)"
    case .value(let value): value
    }
  }
}
