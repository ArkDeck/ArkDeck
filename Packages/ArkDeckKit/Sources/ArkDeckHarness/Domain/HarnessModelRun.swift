// The audit record for one model call (CHG-2026-055, TASK-HFA-002).
//
// A model call is a fact about this task even when nothing came of it: a
// refused proposal still spent the call, still shipped a context off the
// host, and still has to be answerable later. Without a record, the only
// evidence a call happened at all was a fallback note in task memory, and
// only when the proposal was rejected - a successful call left nothing.
//
// Two things this deliberately does not claim:
//
//   * token counts. The decision port returns bytes; token accounting is
//     an adapter-and-vendor concept the port cannot see. Recording bytes
//     that are truly measured beats recording tokens that are guessed.
//   * a model identity the port cannot supply. `HarnessDecisionGateway`
//     exposes a producer id, so the default descriptor says exactly that
//     and marks the rest unspecified. Real vendor adapters (TASK-HFA-011)
//     override it with what they actually know.

import ArkDeckCore
import Foundation

public struct HarnessModelDescriptor: Equatable, Sendable, Codable {
  public static let unspecified = "unspecified"

  public let provider: String
  public let modelName: String
  public let modelRevision: String?
  public let adapterVersion: String

  public init(
    provider: String,
    modelName: String = HarnessModelDescriptor.unspecified,
    modelRevision: String? = nil,
    adapterVersion: String = HarnessModelDescriptor.unspecified
  ) {
    self.provider = provider
    self.modelName = modelName
    self.modelRevision = modelRevision
    self.adapterVersion = adapterVersion
  }
}

/// Outcome of the strict parse, which is the only thing that turns returned
/// bytes into a proposal.
public enum HarnessModelRunOutcome: Equatable, Sendable, Codable {
  case accepted(decisionID: String)
  case rejected(reasonCode: String)
  case transportFailed(reasonCode: String)

  public var reasonCode: String {
    switch self {
    case .accepted: return "accepted"
    case .rejected(let reasonCode): return "rejected:\(reasonCode)"
    case .transportFailed(let reasonCode): return "transportFailed:\(reasonCode)"
    }
  }

  public var decisionID: String? {
    if case .accepted(let decisionID) = self { return decisionID }
    return nil
  }
}

public struct HarnessModelRun: Equatable, Sendable, Codable {
  public static let documentType = "harness-model-run"
  public static let schemaVersion = "1.0.0"

  public let documentType: String
  public let schemaVersion: String
  package let modelRunID: String
  package let htaskID: String
  public let round: Int
  public let descriptor: HarnessModelDescriptor
  /// The state version the context was assembled at, so a run can be joined
  /// to the decision it produced and to the facts both stood on.
  package let observedStateVersion: Int
  /// Digest of the exact bytes handed to the adapter, computed after
  /// redaction and trimming - so it represents what the model received,
  /// not what the harness knew.
  package let contextDigest: String
  package let contextBytes: Int
  package let responseBytes: Int
  /// A bounded copy of a *refused* response. Only refusals carry it, and only
  /// so the next reader can see what was actually returned: a bare
  /// `malformedJson` with a byte count leaves a maintainer inferring the shape
  /// of a response nobody kept.
  package let rejectedResponseExcerpt: String?
  public let outcome: HarnessModelRunOutcome
  public let startedAtUTC: String
  public let finishedAtUTC: String

  enum CodingKeys: String, CodingKey {
    case documentType
    case schemaVersion
    case modelRunID = "modelRunId"
    case htaskID = "htaskId"
    case round
    case descriptor
    case observedStateVersion
    case contextDigest
    case contextBytes
    case responseBytes
    case rejectedResponseExcerpt
    case outcome
    case startedAtUTC = "startedAtUtc"
    case finishedAtUTC = "finishedAtUtc"
  }

  public init(
    modelRunID: String,
    htaskID: String,
    round: Int,
    descriptor: HarnessModelDescriptor,
    observedStateVersion: Int,
    contextDigest: String,
    contextBytes: Int,
    responseBytes: Int,
    rejectedResponseExcerpt: String? = nil,
    outcome: HarnessModelRunOutcome,
    startedAtUTC: String,
    finishedAtUTC: String
  ) {
    self.documentType = Self.documentType
    self.schemaVersion = Self.schemaVersion
    self.modelRunID = modelRunID
    self.htaskID = htaskID
    self.round = round
    self.descriptor = descriptor
    self.observedStateVersion = observedStateVersion
    self.contextDigest = contextDigest
    self.contextBytes = contextBytes
    self.responseBytes = responseBytes
    // Only a refusal keeps a copy: an accepted response already survives as
    // the Decision it became.
    self.rejectedResponseExcerpt = {
      if case .accepted = outcome { return nil }
      return rejectedResponseExcerpt
    }()
    self.outcome = outcome
    self.startedAtUTC = startedAtUTC
    self.finishedAtUTC = finishedAtUTC
  }
}
