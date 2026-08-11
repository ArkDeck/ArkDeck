// What one campaign attempt's job durably journaled (TASK-AIN-019).
//
// Campaign reconciliation reads the usage ledger, and a usage terminal names
// its external intents only by opaque event identifier. That is enough to
// count them and not enough to tell a Loader transition apart from a partition
// write — the distinction every unknown-settling rule turns on. The runtime
// that journaled those intents is the authority on their step identity, so
// this port asks it rather than re-deriving the answer from a second place.
//
// Read-only by construction: it observes an already-finished job's evidence
// and can neither reserve, dispatch nor mutate anything.

import Foundation

package protocol RockchipEvolutionAttemptIntentReading: Sendable {
  /// The workflow step kinds the job journaled a durable intent for, exactly
  /// as the runtime recorded them. Unrecognized raw values are returned
  /// verbatim so the caller can fail closed on them instead of silently
  /// dropping a step it does not understand.
  func journaledStepKinds(jobID: String) throws -> [String]
}

package enum RockchipEvolutionAttemptIntentError: Error, Sendable, Equatable,
  CustomStringConvertible
{
  case unavailable(String)

  public var description: String {
    switch self {
    case .unavailable(let detail):
      return "attempt step kinds are unavailable: \(detail)"
    }
  }
}

/// The default for a host that has not been wired to a runtime. It refuses
/// rather than returning an empty set, because "no kinds" and "we could not
/// ask" must not settle the same way: only the first could ever be a proof.
package struct UnavailableRockchipEvolutionAttemptIntents:
  RockchipEvolutionAttemptIntentReading
{
  public init() {}

  package func journaledStepKinds(jobID: String) throws -> [String] {
    throw RockchipEvolutionAttemptIntentError.unavailable(
      "this campaign host has no runtime evidence reader for job \(jobID)")
  }
}
