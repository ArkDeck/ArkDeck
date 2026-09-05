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
  /// Exact caller intent before Runtime-owned authorization is materialized.
  /// The admission index hashes this request, not the execution request above.
  package var originalSubmissionRequest: RuntimeOperationRequest?
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
  /// Durable machine-readable failure facts, absent until the Job has a failure.
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

  /// Authorization enrichment must not make an unchanged Artifact input look
  /// corrupt. Every accepted reconstruction still matches the original durable
  /// fingerprint and all execution fields except the Runtime authorization.
  func hasVerifiedSubmissionFingerprint(_ fingerprint: String) -> Bool {
    do {
      let submitted: RuntimeOperationRequest
      if let originalSubmissionRequest {
        submitted = originalSubmissionRequest
      } else {
        // No reconstruction of historical pre-authorization requests. An
        // absent snapshot can prove only an exact match to the stored request.
        return SHA256Hex.string(of: try CanonicalJSONEncoders.canonical().encode(request))
          == fingerprint
      }
      guard SHA256Hex.string(of: try CanonicalJSONEncoders.canonical().encode(submitted)) == fingerprint else { return false }
      let execution = try RuntimeOperationRequest(
        requestID: submitted.requestID, idempotencyKey: submitted.idempotencyKey,
        target: submitted.target, operation: submitted.operation, inputs: submitted.inputs,
        requestedOutputs: submitted.requestedOutputs, authorization: request.authorization,
        clientContext: submitted.clientContext)
      return execution == request
    } catch { return false }
  }

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
    let bytes = try Data(contentsOf: directory.appending(path: "job-record.json"))
    var validator = StrictJSONDuplicateValidator(data: bytes)
    try validator.validate()
    return try JSONDecoder().decode(RuntimeJobRecord.self, from: bytes)
  }

  static func sha256Hex(_ data: Data) -> String {
    SHA256Hex.string(of: data)
  }
}

extension RuntimeJobRecord {
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.jobID = try container.decode(String.self, forKey: .jobID)
    self.request = try container.decode(RuntimeOperationRequest.self, forKey: .request)
    self.originalSubmissionRequest = try container.decodeIfPresent(
      RuntimeOperationRequest.self, forKey: .originalSubmissionRequest)
    self.operationReference = try container.decode(String.self, forKey: .operationReference)
    self.catalogDigest = try container.decode(String.self, forKey: .catalogDigest)
    self.providerID = try container.decode(String.self, forKey: .providerID)
    self.createdAtUTC = try container.decode(String.self, forKey: .createdAtUTC)
    self.actualEffect = try container.decodeIfPresent(String.self, forKey: .actualEffect)
    self.admissionEvidence = try container.decodeIfPresent(
      RuntimeAdmissionEvidence.self, forKey: .admissionEvidence)
    self.materializedPlanDigest = try container.decodeIfPresent(
      String.self, forKey: .materializedPlanDigest)
    self.materializedStableTargetIdentitySHA256 = try container.decodeIfPresent(
      String.self, forKey: .materializedStableTargetIdentitySHA256)
    self.materializedBindingRevision = try container.decodeIfPresent(
      Int.self, forKey: .materializedBindingRevision)
    self.state = try container.decode(String.self, forKey: .state)
    self.outcomeUnknown = try container.decode(Bool.self, forKey: .outcomeUnknown)
    self.operationFailure = try container.decodeIfPresent(
      RuntimeOperationFailure.self, forKey: .operationFailure)
    self.recoveryStepID = try container.decodeIfPresent(String.self, forKey: .recoveryStepID)
    self.recoveryAction = try container.decodeIfPresent(
      PersistedTypedProviderAction.self, forKey: .recoveryAction)
    self.recoveryIntentEventID = try container.decodeIfPresent(
      String.self, forKey: .recoveryIntentEventID)
    self.timeline = try container.decode([String].self, forKey: .timeline)
    self.evidencePreflight = try container.decodeIfPresent(
      RuntimeEvidencePreflightAccumulator.self, forKey: .evidencePreflight)
    self.evidenceObservation = try container.decodeIfPresent(
      RuntimeEvidenceObservation.self, forKey: .evidenceObservation)
    self.traceProbeBefore = try container.decodeIfPresent(
      TraceRuntimeProbeSnapshot.self, forKey: .traceProbeBefore)
    self.traceProbeAfter = try container.decodeIfPresent(
      TraceRuntimeProbeSnapshot.self, forKey: .traceProbeAfter)
    self.actualStepKinds = try container.decodeIfPresent([String].self, forKey: .actualStepKinds)
    self.startedAtUTC = try container.decodeIfPresent(String.self, forKey: .startedAtUTC)
    self.firstEvidenceStepAtUTC = try container.decodeIfPresent(
      String.self, forKey: .firstEvidenceStepAtUTC)
    self.finishedAtUTC = try container.decodeIfPresent(String.self, forKey: .finishedAtUTC)
    self.ringCoverage = try container.decodeIfPresent(
      RuntimeRingCoverage.self, forKey: .ringCoverage)
    self.screenSequence = try container.decodeIfPresent(
      RuntimeScreenSequence.self, forKey: .screenSequence)
    self.skipReasons = try container.decode([String: String].self, forKey: .skipReasons)
    self.outstandingResidueCount = try container.decodeIfPresent(
      Int.self, forKey: .outstandingResidueCount)
    let supplied = try JSONValue(from: decoder)
    let current = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(self))
    guard supplied == current else {
      throw DecodingError.dataCorrupted(
        .init(
          codingPath: decoder.codingPath, debugDescription: "unsupported durable Job field shape"))
    }
    guard request.authorization == nil || originalSubmissionRequest != nil else {
      throw DecodingError.dataCorrupted(.init(
        codingPath: decoder.codingPath,
        debugDescription: "authorized Job lacks its original submission"))
    }
    if let evidence = admissionEvidence {
      let hasCapability = evidence.kind == .runtimeCapability
      guard hasCapability == (evidence.runtimeCapabilityCorrelation != nil),
        hasCapability == (evidence.consumptionFingerprintSHA256 != nil),
        !hasCapability || evidence.validUntilUTC != nil,
        !hasCapability || originalSubmissionRequest != nil
      else {
        throw DecodingError.dataCorrupted(
          .init(
            codingPath: decoder.codingPath,
            debugDescription: "incomplete current Runtime admission correlation"))
      }
      if let correlation = evidence.runtimeCapabilityCorrelation {
        func digest(_ value: String) -> Bool {
          value.utf8.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
          }
        }
        let bindingDigest = Self.sha256Hex(Data(
          "\(materializedStableTargetIdentitySHA256 ?? "-")\n\(materializedBindingRevision.map(String.init) ?? "-")".utf8))
        guard evidence.reference == request.authorization?.capabilityID,
          correlation.reservationID == request.idempotencyKey,
          correlation.useOrdinal > 0,
          correlation.planDigestSHA256 == materializedPlanDigest,
          digest(correlation.planDigestSHA256), digest(correlation.stepSetDigestSHA256),
          correlation.targetBindingDigestSHA256 == bindingDigest,
          correlation.artifactSHA256.map(digest) ?? true,
          evidence.consumptionFingerprintSHA256.map(digest) == true
        else {
          throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "Runtime admission correlation does not match its Job"))
        }
      }
    }
  }
}
