// The durable record of a human block (CHG-2026-054, TASK-HTP-003).
//
// A harness stop is not a chat message: it is this record, with the phase to
// resume into, the evidence to look at, and - where the closed
// `HumanActionRequired` category vocabulary genuinely covers the case - the
// typed action document itself, stored verbatim.
//
// `document` is deliberately optional. Two of the four harness block kinds
// (an authorization approval, an unknown outcome) map exactly onto that
// vocabulary. The other two - a strategy that ran out, evidence that failed
// verification - do not, and inventing a category to fill the field would put
// an untrue "minimum human action" into an evidence-grade document. Those
// blocks carry status, reason code and evidence instead, and extending the
// vocabulary is a contract change with its own carrier.
//
// The document is held as JSON rather than as a typed field so this layer
// stays free of a dependency on the workflow module that owns it.

import ArkDeckCore
import ArkDeckRuntime
import Foundation

public struct HarnessStoredHumanAction: Equatable, Sendable, Codable {
  public static let documentType = "harness-human-action"

  public let documentType: String
  public let actionID: String
  public let htaskID: String
  public let block: HarnessHumanBlock
  public let reasonCode: String
  public let round: Int?
  public let jobID: String?
  /// The runtime request identity this block is about when no job exists yet
  /// (an authorization refused before dispatch still names what was refused).
  public let requestID: String?
  /// Verbatim `HumanActionRequired` document, when the category vocabulary
  /// covers this block. Absent means: no closed category describes the human
  /// action, so none was fabricated.
  public let document: JSONValue?
  public let resumeStatus: HarnessTaskLifecycle
  public let resumePhase: HarnessTaskStage
  public let evidenceRefs: [String]
  public let generatedAtUTC: String
  public let resolvedAtUTC: String?
  public let resolution: String?

  enum CodingKeys: String, CodingKey {
    case documentType
    case actionID = "actionId"
    case htaskID = "htaskId"
    case block
    case reasonCode
    case round
    case jobID = "jobId"
    case requestID = "requestId"
    case document
    case resumeStatus
    case resumePhase
    case evidenceRefs
    case generatedAtUTC = "generatedAtUtc"
    case resolvedAtUTC = "resolvedAtUtc"
    case resolution
  }

  public init(
    actionID: String,
    htaskID: String,
    block: HarnessHumanBlock,
    reasonCode: String,
    round: Int?,
    jobID: String?,
    requestID: String?,
    document: JSONValue?,
    resumeStatus: HarnessTaskLifecycle,
    resumePhase: HarnessTaskStage,
    evidenceRefs: [String],
    generatedAtUTC: String,
    resolvedAtUTC: String? = nil,
    resolution: String? = nil
  ) {
    self.documentType = Self.documentType
    self.actionID = actionID
    self.htaskID = htaskID
    self.block = block
    self.reasonCode = reasonCode
    self.round = round
    self.jobID = jobID
    self.requestID = requestID
    self.document = document
    self.resumeStatus = resumeStatus
    self.resumePhase = resumePhase
    self.evidenceRefs = evidenceRefs
    self.generatedAtUTC = generatedAtUTC
    self.resolvedAtUTC = resolvedAtUTC
    self.resolution = resolution
  }

  public var isOpen: Bool { resolvedAtUTC == nil }

  public func resolved(
    at atUTC: String,
    resolution: String,
    document: JSONValue? = nil
  ) -> HarnessStoredHumanAction {
    HarnessStoredHumanAction(
      actionID: actionID, htaskID: htaskID, block: block, reasonCode: reasonCode, round: round,
      jobID: jobID, requestID: requestID, document: document ?? self.document,
      resumeStatus: resumeStatus, resumePhase: resumePhase, evidenceRefs: evidenceRefs,
      generatedAtUTC: generatedAtUTC, resolvedAtUTC: atUTC, resolution: resolution)
  }
}
