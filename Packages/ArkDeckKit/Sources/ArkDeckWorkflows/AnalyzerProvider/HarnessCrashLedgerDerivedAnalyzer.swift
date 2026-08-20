// The pinned crash-ledger analyzer executable front-end (TASK-AND-001).
//
// Parsing sits in the runtime-contract layer because two planes consumed it
// when it was placed there — this analyzer and the harness observation
// reader. CHG-2026-064 removed the second, so the primitive now has one
// consumer; it stays below both the engine and this provider because that is
// what keeps either from importing the other. Production reachability and
// ownership live here, beside AnalyzerProvider: bytes enter through the
// one-shot daemon mode and leave as the unchanged canonical analysis payload.

import ArkDeckRuntime
import Foundation

/// Pure deterministic front-end used by the pinned analyzer executable and
/// its contract tests. Invalid input is a structured `unreadable` result,
/// never an empty ledger: downstream evaluation therefore fails closed.
package enum HarnessCrashLedgerDerivedAnalyzer {
  package static func analyze(_ bytes: Data) throws -> Data {
    let analysis: HarnessCrashLedgerAnalysis
    guard let text = String(data: bytes, encoding: .utf8) else {
      analysis = HarnessCrashLedgerAnalysis(
        status: .unreadable, unreadableReason: "invalidEncoding")
      return try analysis.canonicalData()
    }
    switch HarnessFaultLogLedger.readIndex(text) {
    case .answered(let entries):
      analysis = HarnessCrashLedgerAnalysis(status: .answered, entries: entries)
    case .unreadable(let reason):
      analysis = HarnessCrashLedgerAnalysis(
        status: .unreadable, unreadableReason: reason)
    }
    return try analysis.canonicalData()
  }
}
