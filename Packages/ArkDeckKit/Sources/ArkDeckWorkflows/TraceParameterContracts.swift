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

public enum TraceParameterPolicyError: Error, Equatable, Sendable {
  case parameterOutsideAttachmentDebugProfile(String)
  case duplicateParameter(String)
  case valueDoesNotMatchProfile(name: String, expected: String, actual: String)
  case temporaryRestoreUnavailable(TraceParameterSnapshotState)
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
  public let persistentConfirmationID: String?

  fileprivate init(
    request: TraceParameterMutationRequest,
    snapshot: TraceParameterSnapshotState,
    persistentConfirmationID: String?
  ) {
    self.request = request
    self.snapshot = snapshot
    self.persistentConfirmationID = persistentConfirmationID
  }

  public var originalValueForRestore: String? {
    request.mode == .temporaryRestore ? snapshot.writableOriginalValue : nil
  }
}

public enum TraceParameterPolicy {
  public static func availability(
    for name: String,
    snapshot: TraceParameterSnapshotState
  ) -> TraceParameterModeAvailability {
    let known = TraceDebugParameterCatalog.definition(named: name) != nil
    return TraceParameterModeAvailability(
      temporaryRestoreAvailable: known && snapshot.writableOriginalValue != nil,
      persistentChangeAvailable: known,
      persistentChangeRequiresExplicitConfirmation: known)
  }

  public static func authorize(
    _ request: TraceParameterMutationRequest,
    snapshot: TraceParameterSnapshotState,
    persistentConfirmationID: String? = nil
  ) throws -> TraceAuthorizedParameterMutation {
    guard let definition = TraceDebugParameterCatalog.definition(named: request.name) else {
      throw TraceParameterPolicyError.parameterOutsideAttachmentDebugProfile(request.name)
    }
    guard request.value == definition.profileValue else {
      throw TraceParameterPolicyError.valueDoesNotMatchProfile(
        name: request.name, expected: definition.profileValue, actual: request.value)
    }

    switch request.mode {
    case .temporaryRestore:
      guard snapshot.writableOriginalValue != nil else {
        throw TraceParameterPolicyError.temporaryRestoreUnavailable(snapshot)
      }
      return TraceAuthorizedParameterMutation(
        request: request, snapshot: snapshot, persistentConfirmationID: nil)
    case .persistentChange:
      guard
        let persistentConfirmationID,
        !persistentConfirmationID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw TraceParameterPolicyError.persistentConfirmationRequired
      }
      return TraceAuthorizedParameterMutation(
        request: request,
        snapshot: snapshot,
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
