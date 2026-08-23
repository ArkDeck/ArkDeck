// ArkForge-specific durable state for one Runtime job.
//
// This sidecar deliberately lives beside, rather than inside, the generic
// RuntimeJobRecord. It keeps the cross-process correlation and terminal
// receipt on the ArkForge-owned surface while preserving the same atomic
// ordering: correlation before intent, receipt before outcome.

import ArkDeckStorage
import ArkForgeProtocol
import Foundation

/// Durable join between one ArkDeck attempt and the already-created ArkForge
/// job that owns its external effects. `startExecution` itself cannot touch the
/// device; this value is persisted before ArkDeck writes its own step intent
/// and before any permit is signed.
package struct RuntimeArkForgeLaneExecution: Codable, Sendable, Equatable {
  package let arkDeckJobID: String
  package let daemonJobID: String
  package let planID: String
  package let planSHA256: String
  package let executionPurpose: String
  package let artifactSHA256: String
  package let artifactProfileID: String
  package let targetID: String
  package let bindingRevision: Int
  package let stableIdentitySHA256: String
  package let usbTopology: String
  package let observationMode: String
  package let toolchainSHA256: String

  package init(
    arkDeckJobID: String, daemonJobID: String, planID: String, planSHA256: String,
    executionPurpose: String, artifactSHA256: String, artifactProfileID: String,
    targetID: String, bindingRevision: Int, stableIdentitySHA256: String,
    usbTopology: String, observationMode: String, toolchainSHA256: String
  ) {
    self.arkDeckJobID = arkDeckJobID
    self.daemonJobID = daemonJobID
    self.planID = planID
    self.planSHA256 = planSHA256
    self.executionPurpose = executionPurpose
    self.artifactSHA256 = artifactSHA256
    self.artifactProfileID = artifactProfileID
    self.targetID = targetID
    self.bindingRevision = bindingRevision
    self.stableIdentitySHA256 = stableIdentitySHA256
    self.usbTopology = usbTopology
    self.observationMode = observationMode
    self.toolchainSHA256 = toolchainSHA256
  }
}

package struct RuntimeArkForgeReceiptFact: Codable, Sendable, Equatable {
  package let key: String
  package let value: String
}

/// Codable copy of the daemon's terminal postflight receipt.
///
/// The protobuf SDK model deliberately owns wire coding rather than JSON
/// persistence. Runtime stores this closed copy so a later catalog projection
/// can prove completion after the ArkDeck process — and its lane actor cache —
/// has gone away.
package struct RuntimeArkForgePlanCompletionReceipt: Codable, Sendable, Equatable {
  package let jobID: String
  package let planID: String
  package let stepID: String
  package let actionID: String
  package let attemptID: String
  package let permitID: String
  package let disposition: String
  package let evidenceSHA256: [UInt8]
  package let verificationOutcome: String
  package let verificationStrength: String
  package let verifiedRangeStart: UInt64
  package let verifiedRangeLength: UInt64
  package let typedSkipReason: String
  package let failureClassification: String
  package let facts: [RuntimeArkForgeReceiptFact]

  package init(_ receipt: ArkForgeActionReceiptSummary) {
    jobID = receipt.jobID
    planID = receipt.planID
    stepID = receipt.stepID
    actionID = receipt.actionID
    attemptID = receipt.attemptID
    permitID = receipt.permitID
    disposition = receipt.disposition
    evidenceSHA256 = receipt.evidenceSHA256
    verificationOutcome = receipt.verificationOutcome
    verificationStrength = receipt.verificationStrength
    verifiedRangeStart = receipt.verifiedRangeStart
    verifiedRangeLength = receipt.verifiedRangeLength
    typedSkipReason = receipt.typedSkipReason
    failureClassification = receipt.failureClassification
    facts = receipt.facts.map { RuntimeArkForgeReceiptFact(key: $0.key, value: $0.value) }
  }
}

package enum ArkForgeRuntimeJobStateError: Error, Equatable {
  case unsupportedSchemaVersion(String)
}

/// Atomically persisted ArkForge-only projection under the owning Runtime job.
/// A missing file is the legacy/no-lane state; malformed or future bytes fail
/// recovery closed rather than discarding the exact daemon correlation.
package struct ArkForgeRuntimeJobState: Codable, Sendable, Equatable {
  private static let currentSchemaVersion = "arkdeck-arkforge-runtime-state/v1"
  private static let fileName = "arkforge-runtime-state.json"

  package let schemaVersion: String
  package var execution: RuntimeArkForgeLaneExecution?
  package var planCompletionReceipt: RuntimeArkForgePlanCompletionReceipt?

  package init(
    execution: RuntimeArkForgeLaneExecution? = nil,
    planCompletionReceipt: RuntimeArkForgePlanCompletionReceipt? = nil
  ) {
    self.schemaVersion = Self.currentSchemaVersion
    self.execution = execution
    self.planCompletionReceipt = planCompletionReceipt
  }

  package func persist(into directory: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    try DurableFileWriter.createOrReplaceAtomically(
      destination: directory.appending(path: Self.fileName), data: try encoder.encode(self))
  }

  package static func load(from directory: URL) throws -> Self {
    let url = directory.appending(path: fileName)
    guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
    let state = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
    guard state.schemaVersion == currentSchemaVersion else {
      throw ArkForgeRuntimeJobStateError.unsupportedSchemaVersion(state.schemaVersion)
    }
    return state
  }
}
