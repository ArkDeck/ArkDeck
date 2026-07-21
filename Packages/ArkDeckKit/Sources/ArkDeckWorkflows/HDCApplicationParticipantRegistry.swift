import ArkDeckOpenHarmony

/// App-root single registration authority for HDC-lifecycle-relevant
/// participants. Production inventory is produced only here, so its
/// enumeration is complete by construction: the App-reachable Workflows API
/// surface exposes no other recipient registration path, and the current M1
/// App registers nothing — the honest production inventory is
/// `.complete([])` until a future feature registers real participants.
package actor HDCApplicationParticipantRegistry {
  package static let shared = HDCApplicationParticipantRegistry()

  private var participants: [HDCServerRecipient: HDCServerCriticalState] = [:]
  private var isConsistent = true

  package init() {}

  /// The only registration path. A duplicate registration is an inventory
  /// inconsistency: completeness can no longer be claimed, so every later
  /// inventory fails closed instead of guessing which entry is real.
  package func register(
    _ recipient: HDCServerRecipient, criticalState: HDCServerCriticalState
  ) {
    if participants[recipient] != nil { isConsistent = false }
    participants[recipient] = criticalState
  }

  /// Critical-state updates are only valid for registered participants; an
  /// unknown recipient invalidates the completeness claim fail-closed.
  package func updateCriticalState(
    _ state: HDCServerCriticalState, for recipient: HDCServerRecipient
  ) {
    guard participants[recipient] != nil else {
      isConsistent = false
      return
    }
    participants[recipient] = state
  }

  /// Constructively complete inventory for one endpoint. Participants bound
  /// to other endpoints are outside that endpoint's host-wide impact scope
  /// and are excluded here; the host still re-validates exact-endpoint and
  /// uniqueness before accepting the inventory.
  package func inventory(
    for endpoint: HDCServerEndpoint
  ) -> HDCApplicationHostImpactInventory {
    guard isConsistent else {
      return .unavailable(
        reason: "The App-root participant registry recorded an inconsistent registration.")
    }
    return .complete(
      participants
        .filter { $0.key.endpoint == endpoint }
        .map { HDCApplicationHostImpactParticipant(recipient: $0.key, criticalState: $0.value) }
        .sorted { $0.recipient.id < $1.recipient.id })
  }
}
