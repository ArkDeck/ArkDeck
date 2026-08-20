// Crash-ledger analysis wire contract (CHG-2026-055, TASK-HFA-001/005).
//
// These types are the schema shared along one chain: the pinned analyzer
// executable emits `HarnessCrashLedgerAnalysis` bytes, `AnalyzerProvider`
// gates that stdout against the schema, and `RuntimeJobEngine` wraps it in
// the `HarnessCrashLedgerDerivedArtifact` provenance envelope it publishes.
// A fourth party used to sit at the end of that chain — the harness
// observation builder, which verified the envelope before treating the
// entries as measurements — and CHG-2026-064 removed it along with the rest
// of the in-process decision plane. Whoever consumes the published envelope
// now is an external agent reading an Artifact, which is not a party to this
// schema's placement.
//
// A shared contract must live below every party that speaks it, so it lives
// here in ArkDeckRuntime (runtime contracts): the runtime engine and the
// analyzer provider both reach it without either importing the other. The
// parsing primitive lives beside this contract for the same reason; the
// executable producer lives beside Workflows/AnalyzerProvider.
//
// The `Harness` name prefix is retained: renaming a persisted, versioned
// schema type would churn every call site and test without changing a byte
// on the wire.

import ArkDeckCore
import Foundation

/// One line of the ledger listing, decomposed. Entry names are
/// `<kind>-<bundle>-<uid>-<yyyyMMddHHmmss>` and are *not* file names: on
/// disk each carries trailing milliseconds and `.log` that the listing
/// omits.
package struct HarnessFaultLogEntry: Codable, Equatable, Sendable {
  public let name: String
  /// `jscrash`, `cppcrash`, `appfreeze`, … Taken from the name rather than
  /// guessed from the body: the kinds carry different judging fields and
  /// nothing may assume there is only one.
  public let kind: String
  public let bundle: String
  package let uid: String
  /// `yyyyMMddHHmmss`, device-local. Fixed width, so lexicographic order is
  /// chronological order and no date parsing (or timezone) is needed.
  public let timestamp: String

  public init(name: String, kind: String, bundle: String, uid: String, timestamp: String) {
    self.name = name
    self.kind = kind
    self.bundle = bundle
    self.uid = uid
    self.timestamp = timestamp
  }
}

/// Stable payload emitted by the pinned crash-ledger analyzer.  The runtime
/// wraps these bytes with source-artifact provenance before publishing the
/// derived Artifact, which is where any reader picks it up. TASK-HFA-005
/// introduced it so the in-process harness would stop parsing the raw ledger
/// listing itself; CHG-2026-064 then removed that reader entirely, and the
/// structure kept its value for the reason it was worth having — the parse
/// happens once, in a pinned executable, with provenance attached.
package struct HarnessCrashLedgerAnalysis: Codable, Equatable, Sendable {
  public static let schemaVersion = "1.0.0"
  public static let analyzerRef = "crash-signature@1"
  public static let analyzerVersion = "arkdeck-fault-log-ledger@1"

  public enum Status: String, Codable, Equatable, Sendable {
    case answered
    case unreadable
  }

  public let schemaVersion: String
  public let analyzerRef: String
  public let analyzerVersion: String
  public let status: Status
  public let entries: [HarnessFaultLogEntry]
  package let unreadableReason: String?

  public init(
    status: Status,
    entries: [HarnessFaultLogEntry] = [],
    unreadableReason: String? = nil
  ) {
    self.schemaVersion = Self.schemaVersion
    self.analyzerRef = Self.analyzerRef
    self.analyzerVersion = Self.analyzerVersion
    self.status = status
    self.entries = entries
    self.unreadableReason = unreadableReason
  }

  /// The exact analyzer bytes recorded in the derived envelope. Keeping the
  /// encoder at the wire-contract layer lets every consumer recompute the
  /// digest without depending on the executable producer.
  package func canonicalData() throws -> Data {
    try CanonicalJSONEncoders.canonical().encode(self)
  }
}

/// Published derived Artifact.  Unlike the analyzer's stdout payload, this
/// envelope carries the immutable source identity and analyzer-output digest
/// that the runtime verified.  Downstream code validates both before using
/// `result`, so a structured-looking document cannot be detached from the
/// bytes and tool that produced it.
package struct HarnessCrashLedgerDerivedArtifact: Codable, Equatable, Sendable {
  public let schemaVersion: String
  public let analyzerRef: String
  public let analyzerVersion: String
  public let sourceArtifactID: String
  public let sourceSHA256: String
  public let sourceByteCount: Int
  package let analyzerOutputSHA256: String
  package let analyzerOutputByteCount: Int
  public let result: HarnessCrashLedgerAnalysis

  public init(
    analyzerRef: String,
    analyzerVersion: String,
    sourceArtifactID: String,
    sourceSHA256: String,
    sourceByteCount: Int,
    analyzerOutputSHA256: String,
    analyzerOutputByteCount: Int,
    result: HarnessCrashLedgerAnalysis
  ) {
    self.schemaVersion = HarnessCrashLedgerAnalysis.schemaVersion
    self.analyzerRef = analyzerRef
    self.analyzerVersion = analyzerVersion
    self.sourceArtifactID = sourceArtifactID
    self.sourceSHA256 = sourceSHA256
    self.sourceByteCount = sourceByteCount
    self.analyzerOutputSHA256 = analyzerOutputSHA256
    self.analyzerOutputByteCount = analyzerOutputByteCount
    self.result = result
  }
}
