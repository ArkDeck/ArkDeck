// Production availability and capability adapters for ArkDeckHarness.

import ArkDeckCore
import ArkDeckHarness
import ArkDeckWorkflows
import ArkDeckStorage
import Foundation

package struct RuntimeEngineAvailabilityPort: HarnessOperationAvailabilityPort {
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

package struct RuntimeCapabilityStoreHarnessPort: HarnessCapabilityPort {
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
  package func hasStandingCapability(operationReference: String, targetID: String) async -> Bool {
    await standingCapabilityID(
      operationReference: operationReference, targetID: targetID,
      expectedBindingRevision: nil, inputs: [:]) != nil
  }

  /// The selected grant's id, so a request can name it. Selection is
  /// deterministic — first by expiry, then by id — so two wakes on the same
  /// installed set choose the same grant and a replay stays identical.
  package func standingCapabilityID(
    operationReference: String,
    targetID: String,
    expectedBindingRevision: Int?,
    inputs: [String: JSONValue]
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
        // Runtime-default envelopes are an internal admission product, not
        // standing grants the harness may carry into a later request. In
        // particular, one left by an older Catalog digest can still match
        // target, revision and exact inputs, but the current Runtime must
        // issue/select its own envelope so its policy fingerprint is current.
        // Treating that internal record as caller authority makes the request
        // fail at the final pre-dispatch fingerprint check.
        guard status.capability.issuer.kind == .maintainerMergedPR else {
          return false
        }
        // Revocation is checked first because it is the one condition the
        // remaining fields cannot express: a revoked grant keeps its uses,
        // its lineage and its expiry, so every other test here still passes
        // it. Naming one leaves the engine to refuse it correctly while the
        // task only ever learns that *some* authorization was missing.
        guard case .active = status.capability.revocation else { return false }
        guard status.remainingUses > 0, status.lineageAllowsNewExecution,
          status.capability.expiresAtUTC > now,
          status.capability.effectCeiling >= WorkflowEffect.deviceMutation,
          status.capability.operationScope.contains(where: { $0.reference == operationReference })
        else { return false }
        return Self.canAuthorize(
          status.capability, expectedBindingRevision: expectedBindingRevision, inputs: inputs)
      }
      .sorted {
        ($0.capability.expiresAtUTC, $0.capability.capabilityID)
          < ($1.capability.expiresAtUTC, $1.capability.capabilityID)
      }
      .first?.capability.capabilityID
  }

  /// The pins this side can decide without the device: a grant pinned to a
  /// different binding revision, to a different exact input envelope, or to
  /// an input constraint this request violates cannot authorize the request,
  /// and the engine will say so as an *authorization* refusal — which stops
  /// the task for a human. A reflash leaves grants from the previous binding
  /// revision installed and unexpired, so without this the earliest-expiring
  /// stale grant is named forever and every task on the rebound device stops
  /// before its first mutation.
  ///
  /// Target identity stays out: a capability is scoped by stable physical
  /// identity digest while the harness holds only a target id, so the engine
  /// remains the authority for that one.
  private static func canAuthorize(
    _ capability: RuntimeCapability,
    expectedBindingRevision: Int?,
    inputs: [String: JSONValue]
  ) -> Bool {
    if let pinned = capability.exactBindingRevision, pinned != expectedBindingRevision {
      return false
    }
    if let exactInputs = capability.exactInputs, exactInputs != inputs { return false }
    for (key, constraint) in capability.inputConstraints {
      guard let value = inputs[key], constraint.permits(value) else { return false }
    }
    return true
  }
}
