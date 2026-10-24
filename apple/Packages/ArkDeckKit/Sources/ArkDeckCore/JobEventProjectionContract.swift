/// Closed wire vocabulary for metadata-only Job event projection. Kept in Core
/// so CLI consumers do not depend on the Storage/WAL implementation. Contract
/// tests require every accepted journal kind to have exactly one projection.
package enum JobEventProjectionContract {
  package static let journalKinds: Set<String> = [
    "jobCreated", "stateTransition", "stepIntent", "stepOutcome",
    "compensationIntent", "compensationOutcome", "bindingCandidate", "bindingConfirmed",
    "bindingRejected", "serverGenerationChanged", "sleep", "wake", "reconcileStarted",
    "reconcileOutcome", "abandonIntent", "abandonOutcome", "warning", "error", "finalized",
  ]

  package static func eventType(forJournalKind kind: String) -> String? {
    guard journalKinds.contains(kind) else { return nil }
    return kind == "stateTransition" ? "stateChanged" : "journalEvent"
  }
}
