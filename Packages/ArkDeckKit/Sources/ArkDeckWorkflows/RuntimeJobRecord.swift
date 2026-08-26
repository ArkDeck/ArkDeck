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

/// The coverage a ring capture proved for itself.
public struct RuntimeRingCoverage: Codable, Sendable, Equatable {
  public let anchor: String
  /// Whether the device's ring answered that it was holding the anchor when
  /// the capture armed it. False means the snapshot has no coverage to speak
  /// of, which is a different thing from a snapshot nobody checked.
  public let ringHeldAnchor: Bool

  public init(anchor: String, ringHeldAnchor: Bool) {
    self.anchor = anchor
    self.ringHeldAnchor = ringHeldAnchor
  }
}

/// What a bounded run of stills actually achieved.
///
/// Kept on the record for the same reason `RuntimeRingCoverage` is: the
/// timeline records which facts a step verified, not their values, so a value
/// somebody downstream needs has to be named here or it is gone. Nothing else
/// can reconstruct these - the device's wall clock reads years off the host's,
/// and there is no recorder to ask.
public struct RuntimeScreenSequence: Codable, Sendable, Equatable {
  public let requestedFrameCount: Int
  /// How many frames actually landed. A frame that failed is a gap in the run,
  /// not the end of it, so this can be smaller than what was asked for.
  public let capturedFrameCount: Int
  /// Each frame's own observed span, in capture order. The composed movie is
  /// laid out from these rather than from an average, because at the rate this
  /// achieves the spacing is uneven enough to see.
  public let frameDurationsSeconds: [Double]

  public init(
    requestedFrameCount: Int, capturedFrameCount: Int, frameDurationsSeconds: [Double]
  ) {
    self.requestedFrameCount = requestedFrameCount
    self.capturedFrameCount = capturedFrameCount
    self.frameDurationsSeconds = frameDurationsSeconds
  }

  /// Frames over the span they covered. Reported, never promised: the ceiling
  /// is the device's display readback, measured at about 1.8 a second.
  public var framesPerSecond: Double {
    let elapsed = frameDurationsSeconds.reduce(0, +)
    return elapsed > 0 ? Double(capturedFrameCount) / elapsed : 0
  }
}

public struct RuntimeJobRecord: Codable, Sendable, Equatable {
  public let jobID: String
  public let request: RuntimeOperationRequest
  public let operationReference: String
  public let catalogDigest: String
  public let providerID: String
  public let createdAtUTC: String
  public let actualEffect: String?
  public var admissionEvidence: RuntimeAdmissionEvidence?
  public let materializedPlanDigest: String?
  public let materializedStableTargetIdentitySHA256: String?
  public let materializedBindingRevision: Int?
  public var state: String = "queued"
  public var outcomeUnknown: Bool = false
  /// Durable machine-readable failure facts. Older records decode this as
  /// nil and receive a conservative state-based compatibility projection;
  /// no caller needs to parse `timeline` to classify the outcome.
  public var operationFailure: RuntimeOperationFailure?
  public var recoveryStepID: String?
  var recoveryAction: PersistedTypedProviderAction?
  var recoveryIntentEventID: String?
  public var timeline: [String] = []
  public var evidencePreflight: RuntimeEvidencePreflightAccumulator?
  public var evidenceObservation: RuntimeEvidenceObservation?
  /// Runtime-owned snapshots surrounding one selected Trace leg. These are
  /// captured inside the target's mutation lane, so History never mistakes
  /// a later page refresh for facts belonging to this Job.
  public var traceProbeBefore: TraceRuntimeProbeSnapshot?
  public var traceProbeAfter: TraceRuntimeProbeSnapshot?
  public var actualStepKinds: [String]?
  public var startedAtUTC: String?
  public var firstEvidenceStepAtUTC: String?
  public var finishedAtUTC: String?
  /// What a ring capture established about its own coverage anchor. The
  /// verdict already checked whether the ring was holding it, and a reader
  /// should not be asked to redo a check the runtime performed - so the fact
  /// travels rather than the invitation to verify it.
  public var ringCoverage: RuntimeRingCoverage?
  public var screenSequence: RuntimeScreenSequence?
  public var skipReasons: [String: String] = [:]
  public var outstandingResidueCount: Int?

  public var sessionID: String { "session-\(jobID)" }

  func persist(into directory: URL) throws {
    try DurableFileWriter.createOrReplaceAtomically(
      destination: directory.appending(path: "job-record.json"), data: try durableData())
  }

  func durableData() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    return try encoder.encode(self)
  }

  static func load(from directory: URL) throws -> RuntimeJobRecord {
    try JSONDecoder().decode(
      RuntimeJobRecord.self,
      from: Data(contentsOf: directory.appending(path: "job-record.json")))
  }

  static func sha256Hex(_ data: Data) -> String {
    SHA256Hex.string(of: data)
  }
}
