// Canonical machine-readable Runtime operation failure projection.
//
// This value crosses daemon, GUI, CLI and Agent boundaries. It is deliberately
// small and closed: the diagnostic timeline can keep human-readable detail,
// while recovery decisions consume durable Runtime proof instead of parsing
// that text. Nothing in this projection grants dispatch, retry or recovery
// authority.

import Foundation

public enum RuntimeOperationFailureCode: String, Codable, Sendable, CaseIterable {
  case executionFailed
  case executionConfirmedNotPerformed
  case artifactPublicationFailed
  case artifactFinalizationFailed
  case reconciliationConfirmedNotPerformed
  case outcomeUnknown
  case cancelled
  case interrupted
  case legacyFailure
}

public enum RuntimeOperationFailureCategory: String, Codable, Sendable, CaseIterable {
  case execution
  case externalTool
  case storage
  case cancelled
  case unknownOutcome
  case runtime
}

/// Describes whether another request may be considered. This is informational
/// only: callers must still submit a new typed request through Runtime, whose
/// fresh admission and durable proof remain authoritative.
public enum RuntimeOperationFailureRetryability: String, Codable, Sendable, CaseIterable {
  case notAutomatic
  case runtimeDecisionRequired
}

public enum RuntimeOperationFailureRecovery: String, Codable, Sendable, CaseIterable {
  case none
  case inspectJob
  case awaitRuntimeReconciliation
  case submitNewTypedRequestAfterRuntimeProof
}

public struct RuntimeOperationFailure: Codable, Sendable, Equatable {
  public static let schemaVersion = "1.0.0"

  public let schemaVersion: String
  public let code: RuntimeOperationFailureCode
  public let category: RuntimeOperationFailureCategory
  public let retryability: RuntimeOperationFailureRetryability
  public let recovery: RuntimeOperationFailureRecovery

  public init(
    code: RuntimeOperationFailureCode,
    category: RuntimeOperationFailureCategory,
    retryability: RuntimeOperationFailureRetryability,
    recovery: RuntimeOperationFailureRecovery
  ) {
    schemaVersion = Self.schemaVersion
    self.code = code
    self.category = category
    self.retryability = retryability
    self.recovery = recovery
  }
}
