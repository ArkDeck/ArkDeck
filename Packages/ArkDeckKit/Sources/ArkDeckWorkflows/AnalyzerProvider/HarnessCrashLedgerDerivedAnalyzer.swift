// The pinned crash-ledger analyzer executable front-end (TASK-AND-001).
//
// Parsing is a pure runtime-contract primitive because both the analyzer and
// the retiring Harness observation reader consume it. Production reachability
// and ownership live here, beside AnalyzerProvider: bytes enter through the
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
