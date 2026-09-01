import ArkDeckCore
import ArkDeckRuntime
import Foundation

extension RuntimeAdmissionService {
  private static let workspacePresetInputNames: Set<String> = [
    "buildPresetRef", "testPresetRef", "signingPresetRef", "symbolPresetRef",
  ]

  /// Runs while the registration owner excludes in-flight materialization.
  /// A Job whose initial record is durable is therefore visible here before
  /// its short-lived owner token is released, closing the remove/admit race.
  func requireNoActiveWorkspaceProjectReference(_ projectRef: String) throws {
    try forEachJob { persisted in
      guard let data = persisted.initialRecordData,
        let record = try? JSONDecoder().decode(RuntimeJobRecord.self, from: data),
        record.jobID == persisted.jobID, record.state == persisted.state,
        record.request.idempotencyKey == persisted.idempotencyKey,
        record.hasVerifiedSubmissionFingerprint(persisted.requestHash),
        record.createdAtUTC == persisted.createdAtUTC, persisted.version > 0
      else {
        throw RuntimeWorkspaceProjectFailure(
          "recordUnreadable", "workspace Job references cannot be verified")
      }
      if !record.outcomeUnknown, JobState(rawValue: record.state)?.isTerminal == true { return }
      guard record.catalogDigest == RuntimeOperationCatalog.catalogDigest,
        record.operationReference == record.request.operation.reference,
        let descriptor = RuntimeOperationCatalog.descriptor(reference: record.operationReference)
      else {
        throw RuntimeWorkspaceProjectFailure(
          "recordUnreadable", "active workspace Job has no verifiable Catalog descriptor")
      }
      guard descriptor.provider == .workspace else { return }
      guard descriptor.inputs.contains(where: { $0.name == "projectRef" }) else { return }
      guard case .string(let referencedProject)? = record.request.inputs["projectRef"] else {
        throw RuntimeWorkspaceProjectFailure(
          "recordUnreadable", "active workspace Job has no typed project reference")
      }
      if referencedProject == projectRef {
        throw RuntimeWorkspaceProjectFailure(
          "resourceConflict", "workspace project is referenced by an active or uncertain Job")
      }
    }
  }

  func requireNoActiveWorkspacePresetReference(_ presetRef: String) throws {
    try forEachJob { persisted in
      guard let data = persisted.initialRecordData,
        let record = try? JSONDecoder().decode(RuntimeJobRecord.self, from: data),
        record.jobID == persisted.jobID, record.state == persisted.state,
        record.request.idempotencyKey == persisted.idempotencyKey,
        record.hasVerifiedSubmissionFingerprint(persisted.requestHash),
        record.createdAtUTC == persisted.createdAtUTC, persisted.version > 0
      else {
        throw RuntimeWorkspaceProjectFailure(
          "recordUnreadable", "workspace Job references cannot be verified")
      }
      if !record.outcomeUnknown, JobState(rawValue: record.state)?.isTerminal == true { return }
      guard record.catalogDigest == RuntimeOperationCatalog.catalogDigest,
        record.operationReference == record.request.operation.reference,
        let descriptor = RuntimeOperationCatalog.descriptor(reference: record.operationReference)
      else {
        throw RuntimeWorkspaceProjectFailure(
          "recordUnreadable", "active workspace Job has no verifiable Catalog descriptor")
      }
      guard descriptor.provider == .workspace else { return }
      for input in descriptor.inputs
      where Self.workspacePresetInputNames.contains(input.name) {
        if case .string(let referencedPreset)? = record.request.inputs[input.name],
          referencedPreset == presetRef
        {
          throw RuntimeWorkspaceProjectFailure(
            "resourceConflict", "workspace preset is referenced by an active or uncertain Job")
        }
      }
    }
  }
}
