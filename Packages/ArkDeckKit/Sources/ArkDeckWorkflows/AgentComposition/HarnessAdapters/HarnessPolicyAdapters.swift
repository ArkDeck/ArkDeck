// Production availability and capability adapters for ArkDeckHarness.

import ArkDeckCore
import ArkDeckHarness
import ArkDeckWorkflows
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
  ///
  /// Answered by naming a grant rather than by a second scan of its own. The
  /// guard asks this before dispatch and the dispatcher then asks for the id;
  /// two independent scans could answer "yes" and "none", which is how a task
  /// dispatches a request naming a grant that cannot authorize it.
  public func hasStandingCapability(operationReference: String, targetID: String) async -> Bool {
    await standingCapabilityID(
      operationReference: operationReference, targetID: targetID) != nil
  }

  /// The selected grant's id, so a request can name it. Selection is
  /// deterministic — first by expiry, then by id — so two wakes on the same
  /// installed set choose the same grant and a replay stays identical.
  public func standingCapabilityID(
    operationReference: String, targetID: String
  ) async -> String? {
    let installed: [RuntimeCapabilityStatus]
    do {
      installed = try await store.list()
    } catch {
      // Unreadable capability state is "no capability": fail closed.
      return nil
    }
    let now = nowUTC()
    return installed
      .filter { status in
        // Revocation is checked first because it is the one condition the
        // remaining fields cannot express: a revoked grant keeps its uses,
        // its lineage and its expiry, so every other test here still passes
        // it. Naming one leaves the engine to refuse it correctly while the
        // task only ever learns that *some* authorization was missing.
        guard case .active = status.capability.revocation else { return false }
        return status.remainingUses > 0 && status.lineageAllowsNewExecution
          && status.capability.expiresAtUTC > now
          && status.capability.effectCeiling >= WorkflowEffect.deviceMutation
          && status.capability.operationScope.contains { $0.reference == operationReference }
      }
      .sorted {
        ($0.capability.expiresAtUTC, $0.capability.capabilityID)
          < ($1.capability.expiresAtUTC, $1.capability.capabilityID)
      }
      .first?.capability.capabilityID
  }
}
