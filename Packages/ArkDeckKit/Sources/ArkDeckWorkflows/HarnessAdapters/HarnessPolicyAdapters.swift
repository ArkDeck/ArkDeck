// Production availability and capability adapters for ArkDeckHarness.

import ArkDeckCore
import ArkDeckHarness
import ArkDeckStorage
import Foundation

public struct RuntimeEngineAvailabilityPort: HarnessOperationAvailabilityPort {
  private let engine: RuntimeJobEngine

  public init(engine: RuntimeJobEngine) {
    self.engine = engine
  }

  public func availability(of reference: String) async -> (available: Bool, reason: String) {
    let entries = await engine.operationAvailability()
    guard let match = entries.first(where: { $0.reference == reference }) else {
      return (false, "operation_not_in_catalog")
    }
    switch match.state {
    case .available:
      return (true, "available")
    default:
      return (false, match.reasons.first ?? "unavailable")
    }
  }
}

public struct RuntimeCapabilityStoreHarnessPort: HarnessCapabilityPort {
  private let store: RuntimeCapabilityStore
  private let nowUTC: @Sendable () -> String

  public init(store: RuntimeCapabilityStore, nowUTC: @escaping @Sendable () -> String) {
    self.store = store
    self.nowUTC = nowUTC
  }

  /// Asks only whether an authorization for this operation exists and can
  /// still be consumed. Binding it to the exact device is deliberately *not*
  /// decided here: a capability is scoped by stable physical identity digest
  /// while the harness holds a target id, and the engine's admission remains
  /// the authority that refuses a mismatch. A "yes" here is permission to
  /// *ask*, never permission to execute.
  public func hasStandingCapability(operationReference: String, targetID: String) async -> Bool {
    let installed: [RuntimeCapabilityStatus]
    do {
      installed = try await store.list()
    } catch {
      // Unreadable capability state is "no capability": fail closed.
      return false
    }
    let now = nowUTC()
    for status in installed {
      guard status.remainingUses > 0, status.lineageAllowsNewExecution else { continue }
      guard status.capability.expiresAtUTC > now else { continue }
      guard status.capability.effectCeiling >= WorkflowEffect.deviceMutation else { continue }
      let covers = status.capability.operationScope.contains { scope in
        scope.reference == operationReference
      }
      if covers { return true }
    }
    return false
  }
}
