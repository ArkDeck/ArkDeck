import ArkDeckCore
import ArkDeckStorage
import Foundation

// REQ-FLASH-007/008 safety primitives shared by the native RockUSB Provider.
// Nothing in this file can dispatch a device command, mint Runtime authority, or
// impersonate the broker. Destructive dispatch remains exclusively on the Runtime
// job lane with fresh capability reservation and readback.

// MARK: - Dispatch instrumentation

package enum RockchipExecutionAuthority: String, CaseIterable, Codable, Equatable, Sendable {
  case standardAgent
  case ordinaryCI
  case humanOperator
}

/// Fail-closed authority resolution for the CLI. `humanOperator` requires both an explicit
/// operator identity and an interactive standard input; an environment override can only
/// downgrade, never claim human authority (REQ-FLASH-015: a Task or CI cannot self-upgrade).
package enum RockchipExecutionAuthorityResolver {
  package static func resolve(
    operatorProvided: Bool,
    standardInputIsInteractive: Bool,
    environmentOverride: String?
  ) -> RockchipExecutionAuthority {
    switch environmentOverride {
    case "ordinaryCI", "ci":
      return .ordinaryCI
    case "standardAgent", "agent":
      return .standardAgent
    default:
      break
    }
    if operatorProvided && standardInputIsInteractive {
      return .humanOperator
    }
    return .standardAgent
  }
}

public enum RockchipCriticalWriteBoundaryError: Error, Equatable, Sendable {
  case criticalSectionAlreadyActive(String)
  case noActiveCriticalSection
  case mismatchedCriticalSection(expected: String, actual: String)
  case subsequentStepsBlocked
}

package enum RockchipExitRequestDisposition: String, Codable, Equatable, Sendable {
  case effectiveImmediately
  case deferredUntilSafeBoundary
}

package struct RockchipExitDeferralRecord: Codable, Equatable, Sendable {
  package let requestID: String
  package let activeCriticalStepID: String?
  package let reason: String
  package let timestamp: String
  package let disposition: RockchipExitRequestDisposition

  /// Durable form of the deferral: callers persist this through the session audit store so
  /// the request survives a crash between "exit requested" and "safe boundary reached".
  package func auditRecord(sessionID: String, jobID: String) throws -> SessionAuditRecord {
    try SessionAuditRecord(
      recordID: requestID,
      auditID: "rockusb-exit-coordination",
      correlationID: "rockusb-flash-run",
      sessionID: sessionID,
      jobID: jobID,
      category: .intent,
      timestamp: timestamp,
      details: [
        "kind": .string("exitRequestDeferral"),
        "activeCriticalStepId": activeCriticalStepID.map(JSONValue.string) ?? .null,
        "reason": .string(reason),
        "disposition": .string(disposition.rawValue),
      ])
  }
}

/// Serializes exit coordination around criticalNonInterruptible partition writes: an exit
/// request during a critical write is recorded and deferred; it takes effect only at the
/// step's safe boundary, and then only by blocking subsequent steps — never by killing the
/// in-flight write (REQ-FLASH-008).
package actor RockchipCriticalWriteBoundary {
  package private(set) var activeCriticalStepID: String?
  package private(set) var pendingExitRequest: RockchipExitDeferralRecord?
  package private(set) var subsequentStepsBlocked = false
  private var requestSequence = 0

  package init() {}

  package func beginCriticalWrite(stepID: String) throws {
    if subsequentStepsBlocked {
      throw RockchipCriticalWriteBoundaryError.subsequentStepsBlocked
    }
    if let activeCriticalStepID {
      throw RockchipCriticalWriteBoundaryError.criticalSectionAlreadyActive(activeCriticalStepID)
    }
    activeCriticalStepID = stepID
  }

  package func requestExit(reason: String, timestamp: String) -> RockchipExitDeferralRecord {
    requestSequence += 1
    let record = RockchipExitDeferralRecord(
      requestID: "rockusb-exit-request-\(requestSequence)",
      activeCriticalStepID: activeCriticalStepID,
      reason: reason,
      timestamp: timestamp,
      disposition: activeCriticalStepID == nil
        ? .effectiveImmediately : .deferredUntilSafeBoundary)
    if activeCriticalStepID == nil {
      subsequentStepsBlocked = true
    } else {
      pendingExitRequest = record
    }
    return record
  }

  package func reachSafeBoundary(stepID: String) throws -> RockchipExitDeferralRecord? {
    guard let activeCriticalStepID else {
      throw RockchipCriticalWriteBoundaryError.noActiveCriticalSection
    }
    guard activeCriticalStepID == stepID else {
      throw RockchipCriticalWriteBoundaryError.mismatchedCriticalSection(
        expected: activeCriticalStepID, actual: stepID)
    }
    self.activeCriticalStepID = nil
    guard let pending = pendingExitRequest else { return nil }
    pendingExitRequest = nil
    subsequentStepsBlocked = true
    return pending
  }

  package func mayStartNextStep() -> Bool {
    !subsequentStepsBlocked && activeCriticalStepID == nil
  }
}
