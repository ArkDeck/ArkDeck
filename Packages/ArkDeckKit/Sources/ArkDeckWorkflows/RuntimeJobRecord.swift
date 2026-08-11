// Durable Runtime job projection.
//
// This model is intentionally separated from RuntimeJobEngine orchestration:
// it owns the JSON snapshot shape and the only durable-record IO boundary,
// while journals remain the authoritative external-effect history.

import ArkDeckCore
import ArkDeckRuntime
import ArkDeckStorage
import CryptoKit
import Foundation

package struct RuntimeJobRecord: Codable, Sendable, Equatable {
  public let jobID: String
  public let request: RuntimeOperationRequest
  public let operationReference: String
  public let catalogDigest: String
  public let providerID: String
  public let createdAtUTC: String
  public let actualEffect: String?
  package var admissionEvidence: RuntimeAdmissionEvidence?
  package let materializedPlanDigest: String?
  package let materializedStableTargetIdentitySHA256: String?
  package let materializedBindingRevision: Int?
  public var state: String = "queued"
  public var outcomeUnknown: Bool = false
  package var recoveryStepID: String?
  var recoveryAction: PersistedTypedProviderAction?
  var recoveryIntentEventID: String?
  public var timeline: [String] = []
  package var evidencePreflight: RuntimeEvidencePreflightAccumulator?
  package var evidenceObservation: RuntimeEvidenceObservation?
  /// Runtime-owned snapshots surrounding one selected Trace leg. These are
  /// captured inside the target's mutation lane, so History never mistakes
  /// a later page refresh for facts belonging to this Job.
  package var traceProbeBefore: TraceRuntimeProbeSnapshot?
  package var traceProbeAfter: TraceRuntimeProbeSnapshot?
  public var actualStepKinds: [String]?
  public var startedAtUTC: String?
  public var firstEvidenceStepAtUTC: String?
  public var finishedAtUTC: String?
  package var skipReasons: [String: String] = [:]
  public var outstandingResidueCount: Int?

  public var sessionID: String { "session-\(jobID)" }

  func persist(into directory: URL) throws {
    try DurableFileWriter.createOrReplaceAtomically(
      destination: directory.appendingPathComponent("job-record.json"), data: try durableData())
  }

  func durableData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    return try encoder.encode(self)
  }

  static func load(from directory: URL) throws -> RuntimeJobRecord {
    try JSONDecoder().decode(
      RuntimeJobRecord.self,
      from: Data(contentsOf: directory.appendingPathComponent("job-record.json")))
  }

  static func sha256Hex(_ data: Data) -> String {
    SHA256Hex.string(of: data)
  }
}
