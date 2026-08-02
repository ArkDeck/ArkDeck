// Crash-ledger analysis wire contract (CHG-2026-055, TASK-HFA-001/005).
//
// These types are the schema shared by three planes: the pinned analyzer
// executable emits `HarnessCrashLedgerAnalysis` bytes, `AnalyzerProvider`
// gates that stdout against the schema, `RuntimeJobEngine` wraps it in the
// `HarnessCrashLedgerDerivedArtifact` provenance envelope it publishes, and
// the harness observation builder verifies the envelope before using the
// entries as measurements. A shared contract must live below every party
// that speaks it, so it lives here in ArkDeckRuntime (runtime contracts) —
// not in ArkDeckHarness, which would force the runtime engine and the
// analyzer provider to import the harness plane. The parsing and judging
// logic that *produces* an analysis stays in
// `ArkDeckHarness/Evaluation/HarnessFaultLogLedger.swift`.
//
// The `Harness` name prefix is retained: renaming a persisted, versioned
// schema type would churn every call site and test without changing a byte
// on the wire.

import Foundation

/// One line of the ledger listing, decomposed. Entry names are
/// `<kind>-<bundle>-<uid>-<yyyyMMddHHmmss>` and are *not* file names: on
/// disk each carries trailing milliseconds and `.log` that the listing
/// omits.
public struct HarnessFaultLogEntry: Codable, Equatable, Sendable {
  public let name: String
  /// `jscrash`, `cppcrash`, `appfreeze`, … Taken from the name rather than
  /// guessed from the body: the kinds carry different judging fields and
  /// nothing may assume there is only one.
  public let kind: String
  public let bundle: String
  public let uid: String
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
/// derived Artifact; the harness consumes this structure and no longer has
/// to parse the raw ledger listing in-process (TASK-HFA-005).
public struct HarnessCrashLedgerAnalysis: Codable, Equatable, Sendable {
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
  public let unreadableReason: String?

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
}

/// Published derived Artifact.  Unlike the analyzer's stdout payload, this
/// envelope carries the immutable source identity and analyzer-output digest
/// that the runtime verified.  Downstream code validates both before using
/// `result`, so a structured-looking document cannot be detached from the
/// bytes and tool that produced it.
public struct HarnessCrashLedgerDerivedArtifact: Codable, Equatable, Sendable {
  public let schemaVersion: String
  public let analyzerRef: String
  public let analyzerVersion: String
  public let sourceArtifactID: String
  public let sourceSHA256: String
  public let sourceByteCount: Int
  public let analyzerOutputSHA256: String
  public let analyzerOutputByteCount: Int
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
